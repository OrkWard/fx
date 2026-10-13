const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

const poll_ms: i32 = 100;
const socket_timeout_seconds: i64 = 30;
const silence_ms: i64 = 250;
const max_accepts_per_poll: usize = 16;

pub const Response = enum {
    ok,
    failed,
    unrelated,
};

pub fn ParseResult(comptime Callback: type) type {
    return union(enum) {
        accepted: Callback,
        unrelated,
        failed: anyerror,
    };
}

pub fn Accepted(comptime Callback: type) type {
    return struct {
        stream: std.Io.net.Stream,
        callback: Callback,
        cors_origin: ?[]const u8 = null,

        pub fn deinit(self: *@This()) void {
            self.stream.close(io_mod.getIo());
            self.* = undefined;
        }

        pub fn respond(self: *@This(), outcome: Response) !void {
            try writeResponse(self.stream, outcome, self.cors_origin);
        }
    };
}

/// Drains the listener's queued connections and returns the first callback the
/// provider accepts, or null when no callback is ready during this poll.
///
/// Browsers may open an idle speculative connection or request unrelated paths
/// before sending the redirect. Those connections must not close the listener
/// or hold the real callback in the accept queue. Provider-specific parsing and
/// error classification stay in the adapter passed by the caller.
pub fn await(
    comptime Callback: type,
    comptime parse: fn (?*anyopaque, Allocator, []const u8) ParseResult(Callback),
    alloc: Allocator,
    listener: *std.Io.net.Server,
    parser_context: ?*anyopaque,
    cancel_flag: *std.atomic.Value(bool),
    allowed_cors_origin: ?[]const u8,
) !?Accepted(Callback) {
    return await_request(Callback, parse, alloc, listener, parser_context, .{ .caller = cancel_flag }, allowed_cors_origin, null);
}

/// Accept a browser form POST from one exact HTTPS bridge origin.
pub fn await_form(
    comptime Callback: type,
    comptime parse: fn (?*anyopaque, Allocator, []const u8) ParseResult(Callback),
    alloc: Allocator,
    listener: *std.Io.net.Server,
    parser_context: ?*anyopaque,
    cancel_flag: ?*const std.atomic.Value(bool),
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
    origin: []const u8,
) !?Accepted(Callback) {
    return await_request(Callback, parse, alloc, listener, parser_context, .{ .caller = cancel_flag, .runtime = lifecycle_cancel_flag }, null, origin);
}

const Cancellation = struct {
    caller: ?*const std.atomic.Value(bool) = null,
    runtime: ?*const std.atomic.Value(bool) = null,

    fn cancelled(self: Cancellation) bool {
        return (if (self.caller) |flag| flag.load(.acquire) else false) or
            (if (self.runtime) |flag| flag.load(.acquire) else false);
    }
};

fn await_request(
    comptime Callback: type,
    comptime parse: fn (?*anyopaque, Allocator, []const u8) ParseResult(Callback),
    alloc: Allocator,
    listener: *std.Io.net.Server,
    parser_context: ?*anyopaque,
    cancel_flag: Cancellation,
    allowed_cors_origin: ?[]const u8,
    form_origin: ?[]const u8,
) !?Accepted(Callback) {
    var accepts: usize = 0;
    while (accepts < max_accepts_per_poll) : (accepts += 1) {
        if (!try listenerReady(listener, cancel_flag)) return null;
        var stream = listener.accept(io_mod.getIo()) catch |err| switch (err) {
            error.ConnectionAborted, error.WouldBlock => continue,
            else => return err,
        };
        var handed_off = false;
        defer if (!handed_off) stream.close(io_mod.getIo());
        setSocketTimeouts(stream.socket.handle);

        const maybe_request = readRequest(alloc, stream, cancel_flag, allowed_cors_origin, form_origin, listener.socket.address.getPort()) catch |err| switch (err) {
            error.Cancelled => return err,
            error.InvalidOAuthCallbackRequest, error.OAuthCallbackRequestTooLarge => {
                writeResponse(stream, .unrelated, null) catch {};
                continue;
            },
            else => return err,
        };
        var request = maybe_request orelse continue;
        defer request.deinit(alloc);
        switch (request.kind) {
            .preflight => {
                writePreflightResponse(stream, allowed_cors_origin.?) catch {};
                continue;
            },
            .unrelated => {
                writeResponse(stream, .unrelated, null) catch {};
                continue;
            },
            .callback => {},
        }

        const parsed = parse(parser_context, alloc, request.target);
        switch (parsed) {
            .accepted => |callback| {
                handed_off = true;
                return .{
                    .stream = stream,
                    .callback = callback,
                    .cors_origin = request.cors_origin,
                };
            },
            .unrelated => {
                writeResponse(stream, .unrelated, request.cors_origin) catch {};
                continue;
            },
            .failed => |err| {
                writeResponse(stream, .failed, request.cors_origin) catch {};
                return err;
            },
        }
    }
    return null;
}

const RequestKind = enum {
    callback,
    preflight,
    unrelated,
};

const Request = struct {
    kind: RequestKind,
    target: []u8,
    cors_origin: ?[]const u8 = null,

    fn deinit(self: *Request, alloc: Allocator) void {
        alloc.free(self.target);
        self.* = undefined;
    }
};

fn listenerReady(
    listener: *std.Io.net.Server,
    cancel_flag: Cancellation,
) !bool {
    if (cancel_flag.cancelled()) return error.Cancelled;
    var fds = [_]std.posix.pollfd{.{
        .fd = listener.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, poll_ms);
    if (cancel_flag.cancelled()) return error.Cancelled;
    if (ready == 0) return false;
    if ((fds[0].revents & std.posix.POLL.IN) == 0) {
        return error.OAuthCallbackListenerFailed;
    }
    return true;
}

fn requestReadable(
    socket: std.posix.socket_t,
    cancel_flag: Cancellation,
    deadline_ms: i64,
) !bool {
    while (true) {
        if (cancel_flag.cancelled()) return error.Cancelled;
        const remaining_ms = deadline_ms - io_mod.milliTimestamp();
        const wait_ms: i32 = if (remaining_ms <= 0)
            0
        else
            @intCast(@min(remaining_ms, poll_ms));
        var fds = [_]std.posix.pollfd{.{
            .fd = socket,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, wait_ms);
        if (cancel_flag.cancelled()) return error.Cancelled;
        if (ready != 0) return true;
        if (remaining_ms <= 0) return false;
    }
}

/// Reads one bounded HTTP request, or returns null when the connection remains
/// silent for the speculative-preconnect budget.
fn readRequest(
    alloc: Allocator,
    stream: std.Io.net.Stream,
    cancel_flag: Cancellation,
    allowed_cors_origin: ?[]const u8,
    form_origin: ?[]const u8,
    port: u16,
) !?Request {
    const deadline_ms = io_mod.milliTimestamp() + silence_ms;
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &socket_buffer);
    var request_bytes: [16 * 1024]u8 = undefined;
    var request_len: usize = 0;
    var found_terminator = false;
    while (request_len < request_bytes.len) {
        if (reader.interface.bufferedLen() == 0 and
            !try requestReadable(stream.socket.handle, cancel_flag, deadline_ms))
        {
            return null;
        }
        request_bytes[request_len] = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return if (request_len == 0)
                null
            else
                error.InvalidOAuthCallbackRequest,
            error.ReadFailed => switch (reader.err orelse return error.ReadFailed) {
                error.ConnectionResetByPeer => return null,
                else => |read_err| return read_err,
            },
        };
        request_len += 1;
        if (std.mem.endsWith(u8, request_bytes[0..request_len], "\r\n\r\n")) {
            found_terminator = true;
            break;
        }
    }
    if (!found_terminator) return error.OAuthCallbackRequestTooLarge;
    const line_end = std.mem.find(u8, request_bytes[0..request_len], "\r\n") orelse
        return error.InvalidOAuthCallbackRequest;
    const request_line = request_bytes[0..line_end];
    const method_end = std.mem.findScalar(u8, request_line, ' ') orelse
        return error.InvalidOAuthCallbackRequest;
    const target_start = method_end + 1;
    const target_end = std.mem.findScalarPos(u8, request_line, target_start, ' ') orelse
        return error.InvalidOAuthCallbackRequest;
    const method = request_line[0..method_end];
    const target = request_line[target_start..target_end];
    const origin = requestHeaderValue(request_bytes[line_end + 2 .. request_len], "origin");
    if (form_origin) |required_origin| {
        var host_buf: [32]u8 = undefined;
        const expected_host = try std.mem.print(&host_buf, "127.0.0.1:{d}", .{port});
        const headers = request_bytes[line_end + 2 .. request_len];
        const content_type = unique_header(headers, "content-type") orelse return error.InvalidOAuthCallbackRequest;
        const host_header = unique_header(headers, "host") orelse return error.InvalidOAuthCallbackRequest;
        const form_request_origin = unique_header(headers, "origin") orelse return error.InvalidOAuthCallbackRequest;
        if (!std.mem.eql(u8, method, "POST") or !std.mem.eql(u8, target, "/slack/oauth/callback") or
            !std.mem.eql(u8, form_request_origin, required_origin) or !std.mem.eql(u8, host_header, expected_host) or
            !std.mem.eql(u8, std.mem.trim(u8, std.mem.sliceTo(content_type, ';'), " "), "application/x-www-form-urlencoded") or
            requestHeaderValue(headers, "transfer-encoding") != null) return error.InvalidOAuthCallbackRequest;
        const length_header = unique_header(headers, "content-length") orelse return error.InvalidOAuthCallbackRequest;
        const length = std.fmt.parseInt(usize, length_header, 10) catch return error.InvalidOAuthCallbackRequest;
        if (length == 0 or length > 8192) return error.OAuthCallbackRequestTooLarge;
        const body = try alloc.alloc(u8, length);
        defer alloc.free(body);
        for (body) |*byte| {
            if (reader.interface.bufferedLen() == 0 and !try requestReadable(stream.socket.handle, cancel_flag, deadline_ms)) return null;
            byte.* = reader.interface.takeByte() catch return error.InvalidOAuthCallbackRequest;
        }
        return .{ .kind = .callback, .target = try alloc.dupe(u8, body) };
    }
    const cors_origin = allowed_cors_origin orelse {
        if (!std.mem.eql(u8, method, "GET")) return error.InvalidOAuthCallbackRequest;
        return .{
            .kind = .callback,
            .target = try alloc.dupe(u8, target),
        };
    };
    const origin_allowed = if (origin) |value| std.mem.eql(u8, value, cors_origin) else false;

    if (std.mem.eql(u8, method, "OPTIONS")) {
        const requested_method = requestHeaderValue(
            request_bytes[line_end + 2 .. request_len],
            "access-control-request-method",
        );
        const callback_path = std.mem.eql(u8, target, "/callback") or
            std.mem.startsWith(u8, target, "/callback?");
        const valid = origin_allowed and
            requested_method != null and
            std.ascii.eqlIgnoreCase(requested_method.?, "GET") and
            callback_path;
        return .{
            .kind = if (valid) .preflight else .unrelated,
            .target = try alloc.dupe(u8, target),
        };
    }
    if (!std.mem.eql(u8, method, "GET")) return error.InvalidOAuthCallbackRequest;
    return .{
        .kind = if (origin == null or origin_allowed) .callback else .unrelated,
        .target = try alloc.dupe(u8, target),
        .cors_origin = if (origin_allowed) cors_origin else null,
    };
}

fn unique_header(headers: []const u8, name: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        if (result != null) return null;
        result = std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return result;
}

fn requestHeaderValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn callbackPage(comptime title: []const u8, comptime detail: []const u8) []const u8 {
    return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<title>fx</title><style>" ++
        ":root{color-scheme:light dark}" ++
        "body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;" ++
        "background:#fff;color:#111;" ++
        "font:15px/1.6 ui-sans-serif,-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif}" ++
        "@media(prefers-color-scheme:dark){body{background:#0b0b0c;color:#f4f4f5}}" ++
        "main{text-align:center;padding:2rem;max-width:26rem}" ++
        "h1{margin:0 0 .5rem;font-size:1.125rem;font-weight:600;letter-spacing:-.01em}" ++
        "p{margin:0;font-size:.875rem;opacity:.62}" ++
        "</style></head><body><main><h1>" ++ title ++ "</h1><p>" ++ detail ++ "</p></main></body></html>";
}

pub fn writeResponse(stream: std.Io.net.Stream, outcome: Response, cors_origin: ?[]const u8) !void {
    const reply: struct { status: []const u8, body: []const u8 } = switch (outcome) {
        .ok => .{
            .status = "200 OK",
            .body = comptime callbackPage(
                "Authorization complete",
                "Returning you to fx. You can close this tab.",
            ),
        },
        .failed => .{
            .status = "400 Bad Request",
            .body = comptime callbackPage(
                "Authorization failed",
                "Return to fx for details.",
            ),
        },
        .unrelated => .{
            .status = "404 Not Found",
            .body = "<!doctype html><title>Not found</title>Not found.",
        },
    };
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &buffer);
    try writer.interface.print("HTTP/1.1 {s}\r\n", .{reply.status});
    if (cors_origin) |origin| {
        try writer.interface.print("Access-Control-Allow-Origin: {s}\r\nVary: Origin\r\n", .{origin});
    }
    try writer.interface.print(
        "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ reply.body.len, reply.body },
    );
    try writer.interface.flush();
}

fn writePreflightResponse(stream: std.Io.net.Stream, origin: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &buffer);
    try writer.interface.print(
        "HTTP/1.1 204 No Content\r\n" ++
            "Access-Control-Allow-Origin: {s}\r\n" ++
            "Access-Control-Allow-Methods: GET\r\n",
        .{origin},
    );
    try writer.interface.writeAll(
        "Access-Control-Allow-Private-Network: true\r\n" ++
            "Vary: Origin, Access-Control-Request-Method, Access-Control-Request-Private-Network\r\n" ++
            "Content-Length: 0\r\nConnection: close\r\n\r\n",
    );
    try writer.interface.flush();
}

fn setSocketTimeouts(socket: std.posix.socket_t) void {
    const timeout = std.posix.timeval{ .sec = socket_timeout_seconds, .usec = 0 };
    const receive_rc = std.c.setsockopt(
        socket,
        std.c.SOL.SOCKET,
        std.c.SO.RCVTIMEO,
        &timeout,
        @sizeOf(std.posix.timeval),
    );
    if (receive_rc != 0) {
        const err = std.posix.errno(receive_rc);
        debug_trace.logf("auth", "OAuth callback receive timeout setup failed errno={s}", .{@tagName(err)});
    }
    const send_rc = std.c.setsockopt(
        socket,
        std.c.SOL.SOCKET,
        std.c.SO.SNDTIMEO,
        &timeout,
        @sizeOf(std.posix.timeval),
    );
    if (send_rc != 0) {
        const err = std.posix.errno(send_rc);
        debug_trace.logf("auth", "OAuth callback send timeout setup failed errno={s}", .{@tagName(err)});
    }
}

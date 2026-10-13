const std = @import("std");
const text_utils = @import("text_utils.zig");

const Allocator = std.mem.Allocator;
const max_published_error_bytes: usize = 1024;
const max_recovery_diagnostic_bytes: usize = 600;

pub fn formatHttpErrorMessage(alloc: Allocator, status: std.http.Status, detail: []const u8) ![]u8 {
    const status_code = @backingInt(status);
    const title = if (status_code == 401 or status_code == 403)
        "API access denied"
    else
        "API request failed";
    return formatHttpDiagnostic(alloc, status, detail, title, max_published_error_bytes);
}

pub fn formatHttpRecoveryDiagnostic(alloc: Allocator, status: std.http.Status, detail: []const u8) ![]u8 {
    return formatHttpDiagnostic(alloc, status, detail, null, max_recovery_diagnostic_bytes);
}

fn formatHttpDiagnostic(
    alloc: Allocator,
    status: std.http.Status,
    detail: []const u8,
    title: ?[]const u8,
    max_bytes: usize,
) ![]u8 {
    if (detail.len == 0) return alloc.print("HTTP {d}", .{@backingInt(status)});

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, detail, .{}) catch
        return formatFallbackBounded(alloc, status, detail, max_bytes);
    defer parsed.deinit();

    const root = objectValue(parsed.value) orelse
        return formatFallbackBounded(alloc, status, detail, max_bytes);
    const error_value = root.get("error") orelse
        return formatFallbackBounded(alloc, status, detail, max_bytes);
    const error_object = objectValue(error_value) orelse
        return formatFallbackBounded(alloc, status, detail, max_bytes);
    const param_object = if (error_object.get("param")) |param_value| objectValue(param_value) else null;
    const code = stringField(error_object, "code") orelse
        stringField(error_object, "type") orelse
        if (param_object) |param| stringField(param, "name") else null;
    const message = stringField(error_object, "message") orelse if (param_object) |param| stringField(param, "message") else null;
    const provider = stringField(error_object, "provider") orelse providerFromGatewayMessage(message);

    const raw = try formatParsedHttpMessage(
        alloc,
        title,
        @backingInt(status),
        provider,
        code,
        message,
    );
    defer alloc.free(raw);
    return sanitizeExternalText(alloc, raw, max_bytes);
}

fn formatParsedHttpMessage(
    alloc: Allocator,
    title: ?[]const u8,
    status_code: u16,
    provider: ?[]const u8,
    code: ?[]const u8,
    message: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    if (title) |title_text| {
        try out.writer.print("{s} · ", .{title_text});
    }
    try out.writer.print("HTTP {d}", .{status_code});

    if (provider) |provider_text| {
        try out.writer.print(" · Provider: {s}", .{provider_text});
    }
    if (code) |code_text| {
        try out.writer.print(" · {s}", .{code_text});
        if (message) |message_text| {
            if (!std.mem.eql(u8, code_text, message_text)) {
                try out.writer.print(": {s}", .{message_text});
            }
        }
    } else if (message) |message_text| {
        try out.writer.print(" · {s}", .{message_text});
    }
    return out.toOwnedSlice();
}

fn formatFallbackBounded(
    alloc: Allocator,
    status: std.http.Status,
    detail: []const u8,
    max_bytes: usize,
) ![]u8 {
    if (detail.len == 0) return alloc.print("HTTP {d}", .{@backingInt(status)});
    const raw = try alloc.print("HTTP {d}: {s}", .{ @backingInt(status), detail });
    defer alloc.free(raw);
    return sanitizeExternalText(alloc, raw, max_bytes);
}

fn sanitizeExternalText(alloc: Allocator, raw: []const u8, max_bytes: usize) ![]u8 {
    const masked = try text_utils.maskSecrets(alloc, raw);
    defer if (masked.ptr != raw.ptr) alloc.free(masked);

    const encoded = try text_utils.encodeTerminalSafe(alloc, masked, max_bytes);
    return encoded.bytes;
}

fn objectValue(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn providerFromGatewayMessage(message: ?[]const u8) ?[]const u8 {
    const text = message orelse return null;
    const marker = "Providers considered: ";
    const start = std.mem.find(u8, text, marker) orelse return null;
    const provider_text = trimBreakWhitespace(text[start + marker.len ..]);
    var end: usize = 0;
    while (end < provider_text.len) : (end += 1) {
        switch (provider_text[end]) {
            '.', '\n', '\r', '\t' => break,
            else => {},
        }
    }
    if (end == 0) return null;
    return provider_text[0..end];
}

fn trimBreakWhitespace(text: []const u8) []const u8 {
    var index: usize = 0;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}
    return text[index..];
}

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const secret = @import("../core/auth/secret.zig");
const agent_stream_provider = @import("../core/agent/stream_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const http_pool = @import("../core/shared/http_pool.zig");
const io_mod = @import("../core/shared/io.zig");
const mem_utils = @import("../core/shared/mem_utils.zig");
const types = @import("../core/shared/types.zig");
const json_comparison = @import("../core/shared/json_comparison.zig");
const sse = @import("sse.zig");
const text_utils = @import("../core/shared/text_utils.zig");

pub fn isRetryableGatewayError(err: anyerror) bool {
    return err == error.HttpConnectionClosing or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionTimedOut;
}

pub fn networkFailureEvidence(
    err: anyerror,
    delivery: DeliveryCertainty.State,
) ?agent_stream_provider.NetworkFailureEvidence {
    const cause: agent_stream_provider.NetworkFailureCause = if (err == error.SystemResumed)
        .system_resumed
    else if (err == error.StreamStalled)
        .stream_stalled
    else if (isConnectivityFailure(err))
        .connectivity_lost
    else if (isRetryableAgentNetworkError(err))
        .transport_interrupted
    else
        return null;
    return .{ .cause = cause, .delivery = delivery };
}

/// Errors that prove the network path itself is down: nothing reached a
/// server, so no request was sent and no generation exists. Distinct from
/// connected-but-failed errors (reset mid-stream, closed connection), which
/// carry delivery ambiguity and belong to the retry class.
pub fn isConnectivityFailure(err: anyerror) bool {
    return err == error.UnknownHostName or
        err == error.NameServerFailure or
        err == error.NoAddressReturned or
        err == error.DetectingNetworkConfigurationFailed or
        err == error.AddressUnavailable or
        err == error.ConnectionRefused or
        err == error.ConnectionTimedOut or
        err == error.HostUnreachable or
        err == error.NetworkUnreachable or
        err == error.NetworkDown;
}

fn isRetryableAgentNetworkError(err: anyerror) bool {
    return err == error.TlsInitializationFailed or
        err == error.ConnectionSetupTimedOut or
        err == error.UnknownHostName or
        err == error.NameServerFailure or
        err == error.NoAddressReturned or
        err == error.DetectingNetworkConfigurationFailed or
        err == error.AddressUnavailable or
        err == error.ConnectionPending or
        err == error.ConnectionRefused or
        err == error.HostUnreachable or
        err == error.NetworkUnreachable or
        err == error.NetworkDown or
        err == error.Timeout or
        err == error.WouldBlock or
        err == error.WriteFailed or
        err == error.ReadFailed or
        isRetryableGatewayError(err);
}

fn connectedIoFailure(
    cancelled: bool,
    system_resumed: bool,
    transport_error: anyerror,
) anyerror {
    if (cancelled) return error.Cancelled;
    if (system_resumed) return error.SystemResumed;
    return transport_error;
}

fn connectedIoFailureWithWatch(
    watch: ?*ConnectedRequestWatch,
    cancelled: bool,
    system_resumed: bool,
    transport_error: anyerror,
) anyerror {
    const mapped = connectedIoFailure(cancelled, system_resumed, transport_error);
    return if (watch) |state| state.finish_error(mapped) else mapped;
}

const HttpResult = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *HttpResult, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

pub const PostResult = HttpResult;
pub const GetResult = HttpResult;

pub const GatewayJsonResult = union(enum) {
    /// Owned response body; the caller frees it with the request allocator.
    success: []u8,
    http_status: std.http.Status,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        switch (self.*) {
            .success => |body| alloc.free(body),
            .http_status => {},
        }
        self.* = undefined;
    }
};

pub const StreamCallback = agent_stream_provider.StreamCallback;
pub const ToolStartCallback = agent_stream_provider.ToolStartCallback;

const gateway_retry_base_delay_ns: u64 = 150 * std.time.ns_per_ms;
/// Max time the post-stream body drain may take before the pooled connection
/// is abandoned instead of reused. The response is already complete at this
/// point; only connection reuse is at stake.
const pool_drain_budget_ms: i64 = 2_000;
const gateway_connection_setup_timeout_ms: i64 = 30_000;
const gateway_retry_after_max_ns: u64 = 5 * std.time.ns_per_s;
const gateway_transfer_buffer_bytes: usize = 256 * 1024;
const provider_failure_detail_max_bytes: usize = 600;
const generation_response_max_bytes: usize = 128 * 1024;
const generation_lookup_timeout_ms: i64 = 30_000;
// Covers a 4 MiB string at worst-case JSON escaping plus SSE framing.
const max_sse_event_line_bytes: usize = 32 * 1024 * 1024;
const e2e_gateway_chat_url_env = "FX_E2E_GATEWAY_CHAT_URL";
const e2e_gateway_models_url_env = "FX_E2E_GATEWAY_MODELS_URL";
const e2e_gateway_credits_url_env = "FX_E2E_GATEWAY_CREDITS_URL";
const default_gateway_base_url = "https://ai-gateway.vercel.sh";
pub const vercel_ai_gateway_team_header = "x-vercel-ai-gateway-team";
pub const vercel_gateway_extended_time_header = "x-vercel-gateway-extended-time";
pub const vercel_gateway_extended_time_value = "true";
/// Identifies fx on every AI Gateway request; the zig std.http default
/// (`zig/<version> (std.http)`) is never sent to the gateway.
pub const user_agent = "fx/" ++ build_options.app_version;
var resolved_model_trace_emitted = std.atomic.Value(bool).init(false);
var test_cancel_watcher_spawn_error: ?anyerror = null;

pub const StreamResult = struct {
    status: std.http.Status,
    completion: types.ModelCompletion = .{},
    err_body: ?[]u8 = null,
    retry_after_seconds: ?u64 = null,

    /// Frees all owned response buffers allocated for this stream result.
    pub fn deinit(self: *StreamResult, alloc: std.mem.Allocator) void {
        if (self.err_body) |body| alloc.free(body);
        deinitGatewayCompletion(alloc, &self.completion);
        const status = self.status;
        self.* = .{ .status = status };
    }
};

/// Possibly-sent model requests are retried by the agent so transport retries
/// cannot multiply the logical response budget. Other gateway consumers keep
/// their existing bounded transport retry behavior.
pub const ProviderAttemptOwner = enum {
    transport,
    agent,
};

pub fn fetchGatewayJson(
    alloc: std.mem.Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    url: []const u8,
) !GatewayJsonResult {
    var result = try fetchGatewayGetAtUrl(alloc, api_key, gateway_team, url, e2e_gateway_models_url_env);
    if (failedGatewayJsonStatus(result.status)) |status| {
        result.deinit(alloc);
        return .{ .http_status = status };
    }

    return .{ .success = result.body };
}

pub fn fetchGatewayGetResult(alloc: std.mem.Allocator, api_key: ?[]const u8, path: []const u8) !GetResult {
    return fetchGatewayGet(alloc, api_key, null, path, e2e_gateway_credits_url_env);
}

pub fn fetchGatewayGenerationResult(
    alloc: std.mem.Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    gateway_origin: []const u8,
    generation_id: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !GetResult {
    if (!types.validGatewayGenerationId(generation_id)) return error.InvalidGenerationId;
    var operation = GenerationLookupOperation{
        .alloc = alloc,
        .api_key = api_key,
        .gateway_team = gateway_team,
        .gateway_origin = gateway_origin,
        .generation_id = generation_id,
    };
    return runBoundedHttpOperation(
        GetResult,
        alloc,
        cancel_flag,
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(generation_lookup_timeout_ms),
        }),
        &operation,
    );
}

const GenerationLookupOperation = struct {
    alloc: std.mem.Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    gateway_origin: []const u8,
    generation_id: []const u8,

    fn run(self: *@This()) !GetResult {
        const path = try self.alloc.print(
            "/v1/generation?id={s}",
            .{self.generation_id},
        );
        defer self.alloc.free(path);
        const url = try self.alloc.print(
            "{s}{s}",
            .{ self.gateway_origin, path },
        );
        defer self.alloc.free(url);
        const uri = try std.Uri.parse(url);

        var client: std.http.Client = .{
            .allocator = self.alloc,
            .io = io_mod.getIo(),
        };
        defer client.deinit();
        var auth_header: ?[]u8 = null;
        defer if (auth_header) |value| secret.zeroAndFree(self.alloc, value);
        var headers: std.http.Client.Request.Headers = .{
            .accept_encoding = .omit,
            .user_agent = .{ .override = user_agent },
        };
        if (self.api_key) |api_key| {
            auth_header = try self.alloc.print("Bearer {s}", .{api_key});
            headers.authorization = .{ .override = auth_header.? };
        }
        var extra_headers_buf: [1]std.http.Header = undefined;
        const extra_headers = gatewayModelCatalogExtraHeaders(
            &extra_headers_buf,
            self.gateway_team,
        );
        var req = try client.request(.GET, uri, .{
            .headers = headers,
            .extra_headers = extra_headers,
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();
        try req.sendBodiless();
        if (req.connection) |conn| try conn.flush();

        var response = try req.receiveHead(&.{});
        var transfer_buffer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        const body = reader.allocRemaining(
            self.alloc,
            .limited(generation_response_max_bytes),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.GatewayGenerationResponseTooLarge,
            else => return err,
        };
        return .{ .status = response.head.status, .body = body };
    }
};

fn fetchGatewayGet(alloc: std.mem.Allocator, api_key: ?[]const u8, gateway_team: ?[]const u8, path: []const u8, e2e_url_env: []const u8) !GetResult {
    const default_url = try alloc.print("{s}{s}", .{ gatewayBaseUrl(), path });
    defer alloc.free(default_url);

    return fetchGatewayGetAtUrl(alloc, api_key, gateway_team, default_url, e2e_url_env);
}

fn fetchGatewayGetAtUrl(alloc: std.mem.Allocator, api_key: ?[]const u8, gateway_team: ?[]const u8, default_url: []const u8, e2e_url_env: []const u8) !GetResult {
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    const url = try resolveE2eGatewayUrl(e2e_url_env, default_url);

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |value| secret.zeroAndFree(alloc, value);

    var headers: std.http.Client.Request.Headers = .{};
    headers.user_agent = .{ .override = user_agent };
    if (api_key) |key| {
        auth_header = try alloc.print("Bearer {s}", .{key});
        headers.authorization = .{ .override = auth_header.? };
    }
    var extra_headers_buf: [1]std.http.Header = undefined;
    const extra_headers = gatewayModelCatalogExtraHeaders(&extra_headers_buf, gateway_team);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = headers,
        .extra_headers = extra_headers,
        .response_writer = &out.writer,
        .redirect_behavior = .unhandled,
    });

    return .{
        .status = result.status,
        .body = try out.toOwnedSlice(),
    };
}

pub fn fetchGatewayJsonCancellable(
    alloc: std.mem.Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    url: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !GatewayJsonResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    const request_url = try resolveE2eGatewayUrl(e2e_gateway_models_url_env, url);
    return fetchGatewayJsonAtUrlCancellable(alloc, api_key, gateway_team, request_url, cancel_flag);
}

fn fetchGatewayJsonAtUrlCancellable(
    alloc: std.mem.Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    url: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !GatewayJsonResult {
    var operation = GatewayJsonFetchOperation{
        .alloc = alloc,
        .api_key = api_key,
        .gateway_team = gateway_team,
        .url = url,
        .cancel_flag = cancel_flag,
    };
    return runCancellableGatewayJsonFetch(alloc, cancel_flag, &operation);
}

const GatewayJsonFetchOperation = struct {
    alloc: std.mem.Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    url: []const u8,
    cancel_flag: *std.atomic.Value(bool),

    fn run(self: *@This()) !GatewayJsonResult {
        return fetchGatewayJsonAtUrlCore(
            self.alloc,
            self.api_key,
            self.gateway_team,
            self.url,
            self.cancel_flag,
        );
    }
};

fn runCancellableGatewayJsonFetch(
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    operation: *GatewayJsonFetchOperation,
) !GatewayJsonResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    const Event = union(enum) {
        request: anyerror!GatewayJsonResult,
        watch: anyerror!BoundedRequestWatch.Outcome,
    };
    const Runner = struct {
        fn run(value: *GatewayJsonFetchOperation) anyerror!GatewayJsonResult {
            return value.run();
        }
    };
    const Cleanup = struct {
        fn drain(result_alloc: std.mem.Allocator, select: *std.Io.Select(Event), watch: *BoundedRequestWatch) void {
            watch.stopped.set(select.io);
            while (select.cancel()) |item| switch (item) {
                .request => |request_result| {
                    var late_result = request_result catch continue;
                    late_result.deinit(result_alloc);
                },
                .watch => {},
            };
        }
    };

    var watch: BoundedRequestWatch = .{};
    var select_buffer: [2]Event = undefined;
    var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
    select.concurrent(.watch, BoundedRequestWatch.run, .{ &watch, cancel_flag, null }) catch |err| return err;
    select.concurrent(.request, Runner.run, .{operation}) catch |err| {
        watch.finish(&select);
        return err;
    };

    const event = select.await() catch |err| {
        Cleanup.drain(alloc, &select, &watch);
        return err;
    };
    switch (event) {
        .request => |request_result| {
            watch.finish(&select);
            if (cancel_flag.load(.seq_cst)) {
                var result = request_result catch return error.Cancelled;
                result.deinit(alloc);
                return error.Cancelled;
            }
            return request_result;
        },
        .watch => |watch_result| {
            Cleanup.drain(alloc, &select, &watch);
            _ = try watch_result;
            return error.Cancelled;
        },
    }
}

fn fetchGatewayJsonAtUrlCore(
    alloc: std.mem.Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    url: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !GatewayJsonResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |value| secret.zeroAndFree(alloc, value);

    var headers: std.http.Client.Request.Headers = .{};
    headers.accept_encoding = .omit;
    headers.user_agent = .{ .override = user_agent };
    if (api_key) |key| {
        auth_header = try alloc.print("Bearer {s}", .{key});
        headers.authorization = .{ .override = auth_header.? };
    }
    var extra_headers_buf: [1]std.http.Header = undefined;
    const extra_headers = gatewayModelCatalogExtraHeaders(&extra_headers_buf, gateway_team);

    var req = client.request(.GET, uri, .{
        .headers = headers,
        .extra_headers = extra_headers,
        .redirect_behavior = .unhandled,
    }) catch |err| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
    defer req.deinit();
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (req.connection) |conn|
        try spawn_gateway_cancel_watcher(&cancel_watch_done, cancel_flag, null, null, null, conn.stream_writer.stream)
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    req.sendBodiless() catch |err| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (req.connection) |conn| {
        conn.flush() catch |err| {
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            return err;
        };
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = req.receiveHead(&.{}) catch |err| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (failedGatewayJsonStatus(response.head.status)) |status| return .{ .http_status = status };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var transfer_buffer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    _ = reader.streamRemaining(&out.writer) catch |err| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    return .{ .success = try out.toOwnedSlice() };
}

fn failedGatewayJsonStatus(status: std.http.Status) ?std.http.Status {
    return if (status == .ok) null else status;
}

fn gatewayBaseUrl() []const u8 {
    const override = io_mod.getenv("FX_GATEWAY_BASE_URL") orelse return default_gateway_base_url;
    // The base URL carries the bearer token; only a loopback HTTP override is
    // trusted for local testing.
    if (!isLoopbackHttpUrl(override)) {
        debug_trace.logf("stream", "ignoring FX_GATEWAY_BASE_URL: not loopback http", .{});
        return default_gateway_base_url;
    }
    return override;
}

pub fn generationBaseUrl() []const u8 {
    return std.mem.trimEnd(u8, gatewayBaseUrl(), "/");
}

pub fn isTrustedGenerationOrigin(origin: []const u8) bool {
    return std.mem.eql(u8, origin, default_gateway_base_url) or
        isLoopbackHttpUrl(origin);
}

pub fn postGatewayCompletion(
    alloc: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
) !PostResult {
    const request_url = try resolveE2eGatewayUrl(e2e_gateway_chat_url_env, chat_url);
    var attempt: usize = 0;
    while (attempt < retry_count) : (attempt += 1) {
        debug_trace.logf("stream", "open attempt={d}/{d} url={s} payload_bytes={d}", .{ attempt + 1, retry_count, request_url, payload.len });
        var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
        defer client.deinit();

        const auth_header = try alloc.print("Bearer {s}", .{api_key});
        defer secret.zeroAndFree(alloc, auth_header);

        const extra_headers = [_]std.http.Header{
            .{ .name = "HTTP-Referer", .value = "https://github.com/vercel-labs/fx" },
            .{ .name = "X-Title", .value = "fx" },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = vercel_gateway_extended_time_header, .value = vercel_gateway_extended_time_value },
            .{ .name = "ai-gateway-protocol-version", .value = "0.0.1" },
            .{ .name = "ai-language-model-specification-version", .value = "4" },
            .{ .name = "ai-language-model-id", .value = model },
            .{ .name = "ai-language-model-streaming", .value = "false" },
        };

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const result = client.fetch(.{
            .location = .{ .url = request_url },
            .method = .POST,
            .payload = payload,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = user_agent },
            },
            .extra_headers = &extra_headers,
            .response_writer = &out.writer,
        }) catch |err| {
            if (isRetryableGatewayError(err) and attempt + 1 < retry_count) {
                io_mod.sleep((attempt + 1) * 150 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };

        if (isRetryableGatewayStatus(result.status) and attempt + 1 < retry_count) {
            const delay_ns = retryBackoffDelayNs(attempt);
            debug_trace.logf("stream", "retrying status={d} attempt={d} delay_ms={d}", .{ @backingInt(result.status), attempt + 1, delay_ns / std.time.ns_per_ms });
            io_mod.sleep(delay_ns);
            continue;
        }

        return .{
            .status = result.status,
            .body = try out.toOwnedSlice(),
        };
    }

    return error.HttpConnectionClosing;
}

/// Monotonic request-delivery evidence. It becomes possibly sent before the
/// first body write so any later transport failure is treated as potentially billed.
pub const DeliveryCertainty = agent_stream_provider.DeliveryCertainty;

const ConnectionSetupOutcome = union(enum) {
    request_succeeded,
    request_failed: anyerror,
};

const ConnectionSetupAction = union(enum) {
    succeed,
    retry,
    fail: anyerror,
    cancelled,
};

const ConnectionSetupSnapshot = struct {
    attempt: usize,
    attempt_limit: usize,
    now: std.Io.Clock.Timestamp,
    deadline: std.Io.Clock.Timestamp,
    cancelled: bool,
    delivery: DeliveryCertainty.State,
    outcome: ConnectionSetupOutcome,
};

const ConnectionSetupDecision = struct {
    action: ConnectionSetupAction,
};

fn decideConnectionSetup(snapshot: ConnectionSetupSnapshot) ConnectionSetupDecision {
    if (snapshot.cancelled) return .{ .action = .cancelled };
    if (!std.Io.Clock.Timestamp.compare(snapshot.now, .lt, snapshot.deadline)) {
        return .{ .action = .{ .fail = error.ConnectionSetupTimedOut } };
    }

    return switch (snapshot.outcome) {
        .request_succeeded => .{ .action = .succeed },
        .request_failed => |err| if (isRetryableConnectionSetupError(err) and
            snapshot.delivery == .definitely_unsent and
            snapshot.attempt < snapshot.attempt_limit)
            .{ .action = .retry }
        else
            .{ .action = .{ .fail = err } },
    };
}

fn isRetryableConnectionSetupError(err: anyerror) bool {
    return err == error.TlsInitializationFailed or isRetryableGatewayError(err);
}

/// std.http.Client does not mark a connection closing when the body write or
/// flush fails, so deinit would release a poisoned connection (with possibly
/// buffered unsent bytes) back to the pool. Mark it ourselves so a send
/// failure can never hand a dirty connection to the next borrower.
fn markPooledConnectionClosing(req: *std.http.Client.Request, request: StreamRequest) void {
    if (request.shared_pool == null) return;
    if (req.connection) |conn| conn.closing = true;
}

const ConnectionSetupTiming = struct {
    timeout_ms: i64 = gateway_connection_setup_timeout_ms,
};

const ResponseHeadTiming = struct {
    timeout_ms: i64 = 120_000,
    /// Patient head-wait (agent streaming path): a long-thinking model and a
    /// hung gateway are byte-identical on the wire, and the gateway sends no
    /// heartbeat. Never abort a sent request on head silence alone; only a dead
    /// socket, cancellation, or a system resume ends the wait.
    patient: bool = false,
    /// Mid-stream stall watchdog: once the head has arrived, a stream that
    /// produces no bytes for this long is treated as dead (positive evidence,
    /// unlike silence before the head).
    stall_timeout_ms: i64 = 60_000,
};

const ConnectionSetupEpoch = struct {
    deadline: std.Io.Clock.Timestamp,

    fn init(timing: ConnectionSetupTiming) ConnectionSetupEpoch {
        const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        return .{
            .deadline = .{
                .clock = .awake,
                .raw = started.raw.addDuration(.fromMilliseconds(timing.timeout_ms)),
            },
        };
    }
};

const RequestOpenOverride = struct {
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        client: *std.http.Client,
        method: std.http.Method,
        uri: std.Uri,
        options: std.http.Client.RequestOptions,
    ) anyerror!std.http.Client.Request,
};

const StreamCoreOptions = struct {
    setup_timing: ConnectionSetupTiming = .{},
    response_head_timing: ResponseHeadTiming = .{},
    request_open_override: ?RequestOpenOverride = null,
};

const ConnectedRequestWatch = struct {
    const Phase = enum(u8) {
        sending,
        awaiting_head,
        streaming,
        completed,
        timed_out,
        cancelled,
        system_resumed,
        stalled,
    };

    phase: std.atomic.Value(Phase) = .init(.sending),
    response_head_deadline: std.Io.Clock.Timestamp = undefined,
    /// Last byte progress in the streaming phase (awake clock, ms). Written by
    /// the consume loop, read by the watcher thread. Millisecond precision is ample for second-scale stall thresholds.
    last_progress_ms: std.atomic.Value(i64) = .init(0),
    timing: ResponseHeadTiming,

    fn init(timing: ResponseHeadTiming) ConnectedRequestWatch {
        return .{ .timing = timing };
    }

    fn arm_response_head(self: *ConnectedRequestWatch) ?anyerror {
        self.response_head_deadline = std.Io.Clock.Timestamp.fromNow(
            io_mod.getIo(),
            .{
                .clock = .awake,
                .raw = .fromMilliseconds(self.timing.timeout_ms),
            },
        );
        if (self.phase.cmpxchgStrong(
            .sending,
            .awaiting_head,
            .seq_cst,
            .seq_cst,
        )) |winner| return phase_error(winner);
        return null;
    }

    fn commit_response_head(self: *ConnectedRequestWatch) ?anyerror {
        if (self.phase.cmpxchgStrong(
            .awaiting_head,
            .streaming,
            .seq_cst,
            .seq_cst,
        )) |winner| return phase_error(winner);
        self.markStreamProgress();
        return null;
    }

    fn finish(self: *ConnectedRequestWatch) ?anyerror {
        var current = self.phase.load(.seq_cst);
        while (is_active(current)) {
            if (self.phase.cmpxchgWeak(
                current,
                .completed,
                .seq_cst,
                .seq_cst,
            )) |observed| {
                current = observed;
                continue;
            }
            return null;
        }
        return phase_error(current);
    }

    fn finish_error(
        self: *ConnectedRequestWatch,
        transport_error: anyerror,
    ) anyerror {
        return self.finish() orelse transport_error;
    }

    fn win(self: *ConnectedRequestWatch, winner: Phase) bool {
        std.debug.assert(!is_active(winner));
        std.debug.assert(winner != .completed);
        var current = self.phase.load(.seq_cst);
        while (is_active(current)) {
            if (self.phase.cmpxchgWeak(
                current,
                winner,
                .seq_cst,
                .seq_cst,
            )) |observed| {
                current = observed;
                continue;
            }
            return true;
        }
        return false;
    }

    fn win_response_head_timeout(self: *ConnectedRequestWatch) bool {
        return self.phase.cmpxchgStrong(
            .awaiting_head,
            .timed_out,
            .seq_cst,
            .seq_cst,
        ) == null;
    }

    fn markStreamProgress(self: *ConnectedRequestWatch) void {
        // Both writer and reader use the monotonic awake clock; mixing in the
        // wall clock would make the elapsed subtraction permanently negative.
        const now_ns = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake).raw.toNanoseconds();
        self.last_progress_ms.store(@intCast(@divFloor(now_ns, std.time.ns_per_ms)), .seq_cst);
    }

    /// Positive-evidence stall: the head arrived, then the stream went silent
    /// past the stall threshold. Wins `.stalled` so the caller can distinguish
    /// it from a pre-head timeout (which stays patient).
    fn stream_stall_expired(
        self: *const ConnectedRequestWatch,
        now: std.Io.Clock.Timestamp,
    ) bool {
        if (self.phase.load(.seq_cst) != .streaming) return false;
        const last = self.last_progress_ms.load(.seq_cst);
        if (last == 0) return false;
        const now_ms: i64 = @intCast(@divFloor(now.raw.toNanoseconds(), std.time.ns_per_ms));
        const elapsed = now_ms - last;
        return elapsed >= self.timing.stall_timeout_ms;
    }

    fn win_stall_timeout(self: *ConnectedRequestWatch) bool {
        return self.phase.cmpxchgStrong(
            .streaming,
            .stalled,
            .seq_cst,
            .seq_cst,
        ) == null;
    }

    fn response_head_expired(
        self: *ConnectedRequestWatch,
        now: std.Io.Clock.Timestamp,
    ) bool {
        if (self.timing.patient) {
            // Patient head-wait never aborts. The wait ends only with data,
            // a dead socket, cancel, or system resume.
            if (self.phase.load(.seq_cst) != .awaiting_head) return false;
            if (std.Io.Clock.Timestamp.compare(now, .lt, self.response_head_deadline)) return false;
            return false;
        }
        if (self.phase.load(.seq_cst) != .awaiting_head) return false;
        return !std.Io.Clock.Timestamp.compare(
            now,
            .lt,
            self.response_head_deadline,
        );
    }

    fn is_active(phase: Phase) bool {
        return switch (phase) {
            .sending, .awaiting_head, .streaming => true,
            .completed, .timed_out, .cancelled, .system_resumed, .stalled => false,
        };
    }

    fn phase_error(phase: Phase) ?anyerror {
        return switch (phase) {
            .timed_out => error.Timeout,
            .cancelled => error.Cancelled,
            .system_resumed => error.SystemResumed,
            .stalled => error.StreamStalled,
            .sending, .awaiting_head, .streaming, .completed => null,
        };
    }
};

const RequestOpenOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    options: std.http.Client.RequestOptions,
    request_open_override: ?RequestOpenOverride,

    fn run(self: *@This()) anyerror!std.http.Client.Request {
        if (self.request_open_override) |request_open| {
            return request_open.run(
                request_open.ctx,
                self.client,
                .POST,
                self.uri,
                self.options,
            );
        }
        return self.client.request(.POST, self.uri, self.options);
    }
};

fn openGatewayRequestBounded(
    client: *std.http.Client,
    uri: std.Uri,
    options: std.http.Client.RequestOptions,
    request_open_override: ?RequestOpenOverride,
    epoch: *ConnectionSetupEpoch,
    cancel_flag: *std.atomic.Value(bool),
) anyerror!std.http.Client.Request {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    if (!std.Io.Clock.Timestamp.compare(now, .lt, epoch.deadline)) {
        return error.ConnectionSetupTimedOut;
    }

    const Event = union(enum) {
        request: anyerror!std.http.Client.Request,
        watch: anyerror!BoundedRequestWatch.Outcome,
    };
    const Cleanup = struct {
        fn drain(select: *std.Io.Select(Event), watch: *BoundedRequestWatch) void {
            watch.stopped.set(select.io);
            while (select.cancel()) |item| switch (item) {
                .request => |request_result| {
                    var late_request = request_result catch continue;
                    late_request.deinit();
                },
                .watch => {},
            };
        }
    };

    var operation = RequestOpenOperation{
        .client = client,
        .uri = uri,
        .options = options,
        .request_open_override = request_open_override,
    };
    var watch: BoundedRequestWatch = .{};
    var select_buffer: [2]Event = undefined;
    var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
    select.concurrent(.watch, BoundedRequestWatch.run, .{ &watch, cancel_flag, epoch.deadline }) catch |err| return err;
    select.concurrent(.request, RequestOpenOperation.run, .{&operation}) catch |err| {
        watch.finish(&select);
        return err;
    };

    const event = select.await() catch |err| {
        Cleanup.drain(&select, &watch);
        return err;
    };
    switch (event) {
        .request => |request_result| {
            watch.finish(&select);
            if (cancel_flag.load(.seq_cst)) {
                var cancelled_request = request_result catch return error.Cancelled;
                cancelled_request.deinit();
                return error.Cancelled;
            }

            var owned_request = request_result catch |request_err| return request_err;
            const result_now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
            if (!std.Io.Clock.Timestamp.compare(result_now, .lt, epoch.deadline)) {
                owned_request.deinit();
                return error.ConnectionSetupTimedOut;
            }
            return owned_request;
        },
        .watch => |watch_result| {
            Cleanup.drain(&select, &watch);
            const outcome = try watch_result;
            if (outcome == .cancelled or cancel_flag.load(.seq_cst)) return error.Cancelled;
            return error.ConnectionSetupTimedOut;
        },
    }
}

fn sleepGatewaySetupRetry(
    delay_ns: u64,
    epoch: *ConnectionSetupEpoch,
    cancel_flag: *std.atomic.Value(bool),
) anyerror!void {
    const retry_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromNanoseconds(@intCast(delay_ns)),
    });

    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        if (!std.Io.Clock.Timestamp.compare(now, .lt, epoch.deadline)) {
            return error.ConnectionSetupTimedOut;
        }
        if (!std.Io.Clock.Timestamp.compare(now, .lt, retry_deadline)) return;

        var sleep_ns: i96 = 10 * std.time.ns_per_ms;
        sleep_ns = @min(sleep_ns, now.raw.durationTo(retry_deadline.raw).toNanoseconds());
        sleep_ns = @min(sleep_ns, now.raw.durationTo(epoch.deadline.raw).toNanoseconds());
        if (sleep_ns <= 0) continue;
        try io_mod.getIo().sleep(.fromNanoseconds(sleep_ns), .awake);
    }
}

pub const StreamRequest = struct {
    api_key: ?[]const u8,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    team: ?[]const u8 = null,
    /// Borrowed until `streamGatewayCompletion` returns.
    session_id: ?[]const u8 = null,
    trace_ctx: debug_trace.TraceContext = .{},
    content_capture_limit: ?usize = null,
    delivery: ?*DeliveryCertainty = null,
    admission: ?agent_stream_provider.Admission = null,
    on_reasoning_chunk: ?StreamCallback = null,
    on_tool_input_chunk: ?StreamCallback = null,
    provider_attempt_owner: ProviderAttemptOwner = .transport,
    /// Long-lived pooled HTTP client owned by the provider runtime. When set,
    /// requests reuse pooled keep-alive connections instead of dialing per
    /// attempt. Borrowed; must outlive every in-flight stream.
    shared_pool: ?*http_pool.HttpPool = null,
};

pub fn streamGatewayCompletion(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const expected_provider_tool_name = try expectedProviderToolName(alloc, request.payload);
    return streamGatewayCompletionCore(
        alloc,
        request,
        callback_ctx,
        on_content_chunk,
        on_tool_start,
        cancel_flag,
        expected_provider_tool_name,
        true,
    );
}

pub fn streamGatewayCompletionBounded(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const expected_provider_tool_name = try expectedProviderToolName(alloc, request.payload);
    var operation = BoundedStreamingGatewayOperation{
        .alloc = alloc,
        .request = request,
        .callback_ctx = callback_ctx,
        .on_content_chunk = on_content_chunk,
        .on_tool_start = on_tool_start,
        .expected_provider_tool_name = expected_provider_tool_name,
        .cancel_flag = cancel_flag,
    };
    return runBoundedStreamOperation(alloc, cancel_flag, deadline, &operation);
}

fn expectedProviderToolName(alloc: std.mem.Allocator, payload: []const u8) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const tools = parsed.value.object.get("tools") orelse return null;
    if (tools != .array) return null;

    for (tools.array.items) |tool| {
        if (tool != .object) continue;
        const tool_type = tool.object.get("type") orelse continue;
        const id = tool.object.get("id") orelse continue;
        const name = tool.object.get("name") orelse continue;
        if (tool_type != .string or id != .string or name != .string) continue;
        if (std.mem.eql(u8, tool_type.string, "provider") and
            std.mem.eql(u8, id.string, "gateway.exa_search") and
            std.mem.eql(u8, name.string, "exa_search"))
        {
            return "exa_search";
        }
        if (std.mem.eql(u8, tool_type.string, "provider") and
            std.mem.eql(u8, id.string, "gateway.perplexity_search") and
            std.mem.eql(u8, name.string, "perplexity_search"))
        {
            return "perplexity_search";
        }
        if (std.mem.eql(u8, tool_type.string, "provider") and
            std.mem.eql(u8, id.string, "gateway.parallel_search") and
            std.mem.eql(u8, name.string, "parallel_search"))
        {
            return "parallel_search";
        }
    }
    return null;
}

pub fn streamGatewayRequiredToolCompletionBounded(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    return runBoundedCompletion(alloc, request, null, deadline, cancel_flag);
}

/// Use only when the request advertises the named tool as provider-executed.
pub fn streamGatewayProviderToolCompletionBounded(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    expected_provider_tool_name: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    return runBoundedCompletion(alloc, request, expected_provider_tool_name, deadline, cancel_flag);
}

fn runBoundedCompletion(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    expected_provider_tool_name: ?[]const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    var operation = BoundedGatewayOperation{
        .alloc = alloc,
        .request = request,
        .expected_provider_tool_name = expected_provider_tool_name,
        .cancel_flag = cancel_flag,
    };
    return runBoundedStreamOperation(alloc, cancel_flag, deadline, &operation);
}

const BoundedGatewayOperation = struct {
    alloc: std.mem.Allocator,
    request: StreamRequest,
    expected_provider_tool_name: ?[]const u8,
    cancel_flag: *std.atomic.Value(bool),

    fn run(self: *@This()) !StreamResult {
        return streamGatewayCompletionCore(
            self.alloc,
            self.request,
            @ptrCast(&bounded_stream_discard_ctx),
            discardBoundedContent,
            null,
            self.cancel_flag,
            self.expected_provider_tool_name,
            false,
        );
    }
};

const BoundedStreamingGatewayOperation = struct {
    alloc: std.mem.Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    expected_provider_tool_name: ?[]const u8,
    cancel_flag: *std.atomic.Value(bool),

    fn run(self: *@This()) !StreamResult {
        return streamGatewayCompletionCore(
            self.alloc,
            self.request,
            self.callback_ctx,
            self.on_content_chunk,
            self.on_tool_start,
            self.cancel_flag,
            self.expected_provider_tool_name,
            true,
        );
    }
};

var bounded_stream_discard_ctx: u8 = 0;

fn discardBoundedContent(_: *anyopaque, _: []const u8) void {}

fn streamGatewayCompletionCore(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    cancel_flag: *std.atomic.Value(bool),
    expected_provider_tool_name: ?[]const u8,
    watch_connected_socket: bool,
) !StreamResult {
    return streamGatewayCompletionCoreWithOptions(
        alloc,
        request,
        callback_ctx,
        on_content_chunk,
        on_tool_start,
        cancel_flag,
        expected_provider_tool_name,
        watch_connected_socket,
        .{
            .response_head_timing = .{
                // The agent path waits patiently for long-thinking models: head
                // silence alone never aborts a sent request. Mid-stream stalls
                // still get positive-evidence detection via the stall watchdog.
                .patient = true,
                .stall_timeout_ms = agent_stream_stall_timeout_ms,
            },
        },
    );
}

/// Mid-stream stall patience on the agent streaming path. The gateway sends no
/// heartbeat while a model thinks, so silence is ambiguous for every model,
/// not just known long-thinking classes: any model can go quiet for minutes on
/// a hard prompt. Treat all models with the same ten-minute window instead of
/// classifying by name.
const agent_stream_stall_timeout_ms: i64 = 600_000;

fn streamGatewayCompletionCoreWithOptions(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    cancel_flag: *std.atomic.Value(bool),
    expected_provider_tool_name: ?[]const u8,
    watch_connected_socket: bool,
    core_options: StreamCoreOptions,
) !StreamResult {
    const model = request.model;
    const payload = request.payload;
    const retry_count = switch (request.provider_attempt_owner) {
        .agent => 1,
        .transport => request.retry_count,
    };
    const trace_ctx = request.trace_ctx;
    const request_url = try resolveE2eGatewayUrl(e2e_gateway_chat_url_env, request.chat_url);
    const uri = try std.Uri.parse(request_url);

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |value| secret.zeroAndFree(alloc, value);
    var request_headers: std.http.Client.Request.Headers = .{
        .content_type = .{ .override = "application/json" },
        .accept_encoding = .omit,
        .user_agent = .{ .override = user_agent },
    };
    if (request.api_key) |api_key| {
        auth_header = try alloc.print("Bearer {s}", .{api_key});
        request_headers.authorization = .{ .override = auth_header.? };
    }

    var extra_headers_buf: [10]std.http.Header = undefined;
    const extra_headers = gatewayExtraHeaders(
        &extra_headers_buf,
        model,
        request.team,
        request.session_id,
    );

    if (request.admission) |admission| try admission.admit();
    var attempt: usize = 0;
    var delivery_ambiguous = false;
    var request_body_possibly_sent = false;
    var setup_epoch: ?ConnectionSetupEpoch = null;
    while (attempt < retry_count) : (attempt += 1) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        var local_client: std.http.Client = undefined;
        const client: *std.http.Client = if (request.shared_pool) |pool|
            pool.clientFor(request_url)
        else blk: {
            local_client = .{ .allocator = alloc, .io = io_mod.getIo() };
            break :blk &local_client;
        };
        defer if (request.shared_pool == null) local_client.deinit();
        if (request.shared_pool) |pool| {
            debug_trace.eventf("gateway", "pool_borrow", trace_ctx, "attempt={d} free_connections={d}", .{ attempt + 1, pool.freeConnectionCount() });
        }

        if (setup_epoch == null) {
            setup_epoch = ConnectionSetupEpoch.init(core_options.setup_timing);
        }
        const epoch = &setup_epoch.?;
        const setup_delivery: DeliveryCertainty.State = if (request_body_possibly_sent)
            .possibly_sent
        else if (request.delivery) |delivery|
            delivery.load()
        else
            .definitely_unsent;

        debug_trace.eventf("gateway", "before_http_open_connect", trace_ctx, "attempt={d} attempt_limit={d} retries_used={d}", .{ attempt + 1, retry_count, attempt });
        debug_trace.eventf("gateway", "before_request_open", trace_ctx, "attempt={d} attempt_limit={d} retries_used={d} payload_bytes={d}", .{ attempt + 1, retry_count, attempt, payload.len });
        var req = openGatewayRequestBounded(client, uri, .{
            .headers = request_headers,
            .extra_headers = extra_headers,
            .keep_alive = request.shared_pool != null,
            .redirect_behavior = .unhandled,
        }, core_options.request_open_override, epoch, cancel_flag) catch |err| {
            debug_trace.eventf("gateway", "http_open_connect_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            const decision = decideConnectionSetup(.{
                .attempt = attempt + 1,
                .attempt_limit = retry_count,
                .now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
                .deadline = epoch.deadline,
                .cancelled = cancel_flag.load(.seq_cst),
                .delivery = setup_delivery,
                .outcome = .{ .request_failed = err },
            });
            switch (decision.action) {
                .retry => {
                    sleepGatewaySetupRetry(
                        (attempt + 1) * gateway_retry_base_delay_ns,
                        epoch,
                        cancel_flag,
                    ) catch |sleep_err| return @as(anyerror!StreamResult, sleep_err);
                    continue;
                },
                .fail => |terminal_err| return @as(anyerror!StreamResult, terminal_err),
                .cancelled => return error.Cancelled,
                .succeed => unreachable,
            }
        };
        const setup_success = decideConnectionSetup(.{
            .attempt = attempt + 1,
            .attempt_limit = retry_count,
            .now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
            .deadline = epoch.deadline,
            .cancelled = cancel_flag.load(.seq_cst),
            .delivery = setup_delivery,
            .outcome = .request_succeeded,
        });
        switch (setup_success.action) {
            .succeed => {},
            .fail => |terminal_err| {
                req.deinit();
                return @as(anyerror!StreamResult, terminal_err);
            },
            .cancelled => {
                req.deinit();
                return error.Cancelled;
            },
            .retry => unreachable,
        }
        setup_epoch = null;
        defer req.deinit();
        debug_trace.eventf("gateway", "after_http_open_connect", trace_ctx, "attempt={d}", .{attempt + 1});
        debug_trace.eventf("gateway", "after_request_open", trace_ctx, "attempt={d}", .{attempt + 1});

        var cancel_watch_done = std.atomic.Value(bool).init(false);
        var system_resumed = std.atomic.Value(bool).init(false);
        var connected_watch = ConnectedRequestWatch.init(core_options.response_head_timing);
        const cancel_watcher = if (watch_connected_socket)
            if (req.connection) |conn|
                spawn_gateway_cancel_watcher(&cancel_watch_done, cancel_flag, &system_resumed, null, &connected_watch, conn.stream_writer.stream) catch |err| {
                    debug_trace.eventf("gateway", "cancel_watcher_spawn_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
                    return @as(anyerror!StreamResult, err);
                }
            else
                null
        else
            null;
        const active_connected_watch: ?*ConnectedRequestWatch = if (cancel_watcher != null)
            &connected_watch
        else
            null;
        defer {
            cancel_watch_done.store(true, .seq_cst);
            if (cancel_watcher) |thread| thread.join();
        }
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        req.transfer_encoding = .{ .content_length = payload.len };
        var send_buf: [8192]u8 = undefined;
        debug_trace.eventf("gateway", "before_request_send", trace_ctx, "attempt={d} payload_bytes={d}", .{ attempt + 1, payload.len });
        request_body_possibly_sent = true;
        if (request.delivery) |delivery| delivery.markPossiblySent();
        var body_writer = req.sendBodyUnflushed(&send_buf) catch |err| {
            debug_trace.eventf("gateway", "request_send_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            markPooledConnectionClosing(&req, request);
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        body_writer.writer.writeAll(payload) catch |err| {
            debug_trace.eventf("gateway", "request_send_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            markPooledConnectionClosing(&req, request);
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        body_writer.end() catch |err| {
            debug_trace.eventf("gateway", "request_send_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            markPooledConnectionClosing(&req, request);
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        req.connection.?.flush() catch |err| {
            debug_trace.eventf("gateway", "request_send_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            markPooledConnectionClosing(&req, request);
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        debug_trace.eventf("gateway", "after_request_send", trace_ctx, "attempt={d} payload_bytes={d}", .{ attempt + 1, payload.len });
        debug_trace.eventf("gateway", "after_send", trace_ctx, "attempt={d} payload_bytes={d}", .{ attempt + 1, payload.len });

        if (active_connected_watch) |watch| {
            if (watch.arm_response_head()) |err| {
                markPooledConnectionClosing(&req, request);
                return @as(anyerror!StreamResult, err);
            }
        }
        debug_trace.eventf("gateway", "before_receive_head", trace_ctx, "attempt={d}", .{attempt + 1});
        var response = req.receiveHead(&.{}) catch |err| {
            debug_trace.eventf("gateway", "receive_head_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            const mapped = connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            );
            if (mapped == error.Cancelled or mapped == error.SystemResumed) {
                return @as(anyerror!StreamResult, mapped);
            }
            if (request.provider_attempt_owner == .transport and
                isRetryableGatewayError(mapped) and attempt + 1 < retry_count)
            {
                delivery_ambiguous = true;
                try sleepGatewayRetry((attempt + 1) * 150 * std.time.ns_per_ms, cancel_flag);
                continue;
            }
            return @as(anyerror!StreamResult, mapped);
        };
        if (active_connected_watch) |watch| {
            if (watch.commit_response_head()) |err| return @as(anyerror!StreamResult, err);
        }
        debug_trace.eventf("gateway", "after_receive_head", trace_ctx, "attempt={d} status={d}", .{ attempt + 1, @backingInt(response.head.status) });
        const resolved_model_seen_in_head = traceResolvedModelHeader(response.head, model, trace_ctx);

        if (response.head.status != .ok) {
            const status = response.head.status;
            if (@backingInt(status) >= 500) delivery_ambiguous = true;
            const retry_after_seconds = retryAfterSeconds(response.head);
            const retry_delay_ns = if (request.provider_attempt_owner == .transport and
                isRetryableGatewayStatus(status) and attempt + 1 < retry_count)
                retryDelayNsForResponse(response.head, attempt)
            else
                null;
            debug_trace.logf("stream", "http status={d} attempt={d}", .{ @backingInt(status), attempt + 1 });
            var err_out: std.Io.Writer.Allocating = .init(alloc);
            defer err_out.deinit();
            var err_buf: [4096]u8 = undefined;
            const err_reader = response.reader(&err_buf);
            _ = err_reader.streamRemaining(&err_out.writer) catch {};
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            if (retry_delay_ns) |delay_ns| {
                debug_trace.eventf("gateway", "http_status_retry", trace_ctx, "attempt={d} status={d} delay_ms={d}", .{
                    attempt + 1,
                    @backingInt(status),
                    delay_ns / std.time.ns_per_ms,
                });
                try sleepGatewayRetry(delay_ns, cancel_flag);
                continue;
            }
            return .{
                .status = status,
                .err_body = err_out.toOwnedSlice() catch null,
                .retry_after_seconds = retry_after_seconds,
                .completion = .{
                    .delivery_ambiguous = delivery_ambiguous,
                },
            };
        }

        var transfer_buf: [gateway_transfer_buffer_bytes]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        debug_trace.eventf("gateway", "before_sse_consume", trace_ctx, "attempt={d}", .{attempt + 1});
        var completion = consumeSseStreamTraced(
            alloc,
            body_reader,
            callback_ctx,
            on_content_chunk,
            on_tool_start,
            request.on_reasoning_chunk,
            request.on_tool_input_chunk,
            cancel_flag,
            .{ .requested_model = model, .ctx = trace_ctx },
            expected_provider_tool_name,
            request.content_capture_limit,
            active_connected_watch,
        ) catch |err| {
            debug_trace.eventf("gateway", "sse_consume_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        if (request.shared_pool != null) {
            // SSE consumption stops at the terminal event, which can leave
            // the HTTP body unread; std's Request.deinit marks body-ful
            // requests closing unless the body drains to the end. Drain so a
            // cleanly finished stream returns its connection to the pool.
            // The drain is bounded: a server that never terminates the body
            // must not hang an already-completed request. The watcher's
            // deadline shuts the socket, turning the hang into a drain error;
            // only reuse is lost, never the response.
            const drain_started = io_mod.milliTimestamp();
            var drain_watch_done = std.atomic.Value(bool).init(false);
            const drain_deadline = std.Io.Clock.Timestamp{
                .clock = .awake,
                .raw = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake).raw.addDuration(.fromMilliseconds(pool_drain_budget_ms)),
            };
            const drain_thread = if (req.connection) |conn|
                spawn_gateway_cancel_watcher(&drain_watch_done, cancel_flag, null, drain_deadline, null, conn.stream_writer.stream) catch null
            else
                null;
            const drain_ok = if (body_reader.discardRemaining()) |drained_bytes| blk: {
                debug_trace.eventf("gateway", "pool_body_drain", trace_ctx, "attempt={d} result=ok bytes={d} elapsed_ms={d}", .{ attempt + 1, drained_bytes, io_mod.milliTimestamp() - drain_started });
                break :blk true;
            } else |err| blk: {
                debug_trace.eventf("gateway", "pool_body_drain", trace_ctx, "attempt={d} result=error err={s}", .{ attempt + 1, @errorName(err) });
                break :blk false;
            };
            drain_watch_done.store(true, .seq_cst);
            if (drain_thread) |thread| thread.join();
            // The connection returns to the pool NOW, at stream end — the
            // TTL invariant requires last_activity to track the freshest
            // return, so stamp only on a clean return.
            if (drain_ok) request.shared_pool.?.noteActivity();
        }
        if (active_connected_watch) |watch| {
            if (watch.finish()) |err| {
                deinitGatewayCompletion(alloc, &completion);
                return @as(anyerror!StreamResult, err);
            }
        }
        if (cancel_flag.load(.seq_cst)) {
            deinitGatewayCompletion(alloc, &completion);
            return error.Cancelled;
        }
        if (system_resumed.load(.seq_cst)) {
            deinitGatewayCompletion(alloc, &completion);
            return error.SystemResumed;
        }
        completion.delivery_ambiguous = delivery_ambiguous;
        if (!resolved_model_seen_in_head) traceResolvedModelMissingOnce(model, trace_ctx);
        debug_trace.eventf("gateway", "after_sse_consume", trace_ctx, "attempt={d} finish_reason={s} content_bytes={d} tool_call_count={d}", .{
            attempt + 1,
            finish_reason_label(completion.finish_reason),
            if (completion.content) |content| content.len else 0,
            completion.tool_calls.len,
        });
        debug_trace.logf(
            "stream",
            "completed attempt={d} finish_reason={s} content_bytes={d} tool_calls={d}",
            .{
                attempt + 1,
                finish_reason_label(completion.finish_reason),
                if (completion.content) |content| content.len else 0,
                completion.tool_calls.len,
            },
        );
        debug_trace.eventf(
            "gateway",
            "stream_complete",
            trace_ctx,
            "attempt={d} finish_reason={s} content_bytes={d} tool_call_count={d} tool_calls={d}",
            .{
                attempt + 1,
                finish_reason_label(completion.finish_reason),
                if (completion.content) |content| content.len else 0,
                completion.tool_calls.len,
                completion.tool_calls.len,
            },
        );

        return .{
            .status = .ok,
            .completion = completion,
        };
    }

    return error.HttpConnectionClosing;
}

fn gatewayExtraHeaders(
    buf: []std.http.Header,
    model: []const u8,
    team: ?[]const u8,
    session_id: ?[]const u8,
) []const std.http.Header {
    std.debug.assert(buf.len >= 10);
    var len: usize = 0;
    buf[len] = .{ .name = "HTTP-Referer", .value = "https://github.com/vercel-labs/fx" };
    len += 1;
    buf[len] = .{ .name = "X-Title", .value = "fx" };
    len += 1;
    buf[len] = .{ .name = vercel_gateway_extended_time_header, .value = vercel_gateway_extended_time_value };
    len += 1;
    buf[len] = .{ .name = "ai-gateway-protocol-version", .value = "0.0.1" };
    len += 1;
    buf[len] = .{ .name = "ai-language-model-specification-version", .value = "4" };
    len += 1;
    buf[len] = .{ .name = "ai-language-model-id", .value = model };
    len += 1;
    buf[len] = .{ .name = "ai-language-model-streaming", .value = "true" };
    len += 1;
    if (team) |gateway_team| {
        if (gateway_team.len > 0) {
            buf[len] = .{ .name = vercel_ai_gateway_team_header, .value = gateway_team };
            len += 1;
        }
    }
    if (session_id) |id| {
        if (id.len > 0) {
            buf[len] = .{ .name = "x-session-id", .value = id };
            len += 1;
            buf[len] = .{ .name = "x-session-affinity", .value = id };
            len += 1;
        }
    }
    return buf[0..len];
}

fn gatewayModelCatalogExtraHeaders(buf: []std.http.Header, team: ?[]const u8) []const std.http.Header {
    std.debug.assert(buf.len >= 1);
    var len: usize = 0;
    if (team) |gateway_team| {
        if (gateway_team.len > 0) {
            buf[len] = .{ .name = vercel_ai_gateway_team_header, .value = gateway_team };
            len += 1;
        }
    }
    return buf[0..len];
}

fn sleepGatewayRetry(delay_ns: u64, cancel_flag: *std.atomic.Value(bool)) (std.Io.Cancelable || error{Cancelled})!void {
    var remaining_ns = delay_ns;
    while (remaining_ns > 0) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const sleep_ns = @min(remaining_ns, 10 * std.time.ns_per_ms);
        try io_mod.getIo().sleep(.fromNanoseconds(@intCast(sleep_ns)), .awake);
        remaining_ns -= sleep_ns;
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
}

fn runBoundedStreamOperation(
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    operation: anytype,
) !StreamResult {
    return runBoundedHttpOperation(
        StreamResult,
        alloc,
        cancel_flag,
        deadline,
        operation,
    );
}

pub fn runBoundedHttpOperation(
    comptime Result: type,
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    operation: anytype,
) !Result {
    if (cancel_flag.load(.seq_cst)) {
        debug_trace.logf("stream", "bounded termination cause=cancellation phase=admission", .{});
        return error.Cancelled;
    }
    std.debug.assert(deadline.clock == .awake);

    const zio = io_mod.getIo();
    const now = std.Io.Clock.Timestamp.now(zio, .awake);
    if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) {
        debug_trace.logf("stream", "bounded termination cause=deadline phase=admission", .{});
        return error.Timeout;
    }

    const Event = union(enum) {
        request: anyerror!Result,
        watch: anyerror!BoundedRequestWatch.Outcome,
    };
    const Operation = @TypeOf(operation);
    const Runner = struct {
        fn run(value: Operation) anyerror!Result {
            return value.run();
        }
    };
    const Cleanup = struct {
        fn drain(result_alloc: std.mem.Allocator, select: *std.Io.Select(Event), watch: *BoundedRequestWatch) void {
            watch.stopped.set(select.io);
            while (select.cancel()) |item| switch (item) {
                .request => |request_result| {
                    var late_result = request_result catch continue;
                    late_result.deinit(result_alloc);
                },
                .watch => {},
            };
        }
    };

    var watch: BoundedRequestWatch = .{};
    var select_buffer: [2]Event = undefined;
    var select: std.Io.Select(Event) = .init(zio, &select_buffer);
    select.concurrent(.watch, BoundedRequestWatch.run, .{ &watch, cancel_flag, deadline }) catch |err| {
        return err;
    };
    select.concurrent(.request, Runner.run, .{operation}) catch |err| {
        watch.finish(&select);
        return err;
    };

    const event = select.await() catch |err| {
        Cleanup.drain(alloc, &select, &watch);
        return err;
    };
    switch (event) {
        .request => |request_result| {
            watch.finish(&select);
            if (cancel_flag.load(.seq_cst)) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=request_result", .{});
                var owned_result = request_result catch return error.Cancelled;
                owned_result.deinit(alloc);
                return error.Cancelled;
            }
            return request_result;
        },
        .watch => |watch_result| {
            Cleanup.drain(alloc, &select, &watch);
            const outcome = try watch_result;
            if (outcome == .cancelled) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=control", .{});
                return error.Cancelled;
            }
            if (cancel_flag.load(.seq_cst)) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=deadline_cleanup", .{});
                return error.Cancelled;
            }
            debug_trace.logf("stream", "bounded termination cause=deadline phase=control", .{});
            return error.Timeout;
        },
    }
}

/// Watches one bounded request for cancellation and its deadline. The request
/// owner stops it with `finish` instead of cancelling it: in Zig 0.17 a cancel
/// can interrupt whatever task the watch's worker thread runs next, and an
/// interrupted connect then fails with ISCONN.
const BoundedRequestWatch = struct {
    stopped: std.Io.Event = .unset,

    const Outcome = enum { stopped, cancelled, deadline };

    fn run(
        watch: *BoundedRequestWatch,
        cancel_flag: *std.atomic.Value(bool),
        deadline: ?std.Io.Clock.Timestamp,
    ) anyerror!Outcome {
        const zio = io_mod.getIo();
        while (true) {
            if (cancel_flag.load(.seq_cst)) return .cancelled;
            if (deadline) |limit| {
                const now = std.Io.Clock.Timestamp.now(zio, .awake);
                if (!std.Io.Clock.Timestamp.compare(now, .lt, limit)) return .deadline;
            }
            watch.stopped.waitTimeout(zio, .{ .duration = .{
                .raw = .fromMilliseconds(5),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => continue,
                else => |e| return e,
            };
            return .stopped;
        }
    }

    /// Stops the watch and waits for its event, then releases the select.
    /// Call only when the watch event is the one still outstanding.
    fn finish(watch: *BoundedRequestWatch, select: anytype) void {
        watch.stopped.set(select.io);
        const event = select.queue.getOneUncancelable(select.io) catch |err| switch (err) {
            // Only Select.cancel closes the queue, so nothing is outstanding.
            error.Closed => return,
        };
        std.debug.assert(event == .watch);
        std.debug.assert(select.cancel() == null);
    }
};

const GatewayCancelWatcher = struct {
    fn run(
        done: *std.atomic.Value(bool),
        cancel_flag: *std.atomic.Value(bool),
        system_resumed: ?*std.atomic.Value(bool),
        deadline: ?std.Io.Clock.Timestamp,
        connected_watch: ?*ConnectedRequestWatch,
        stream: std.Io.net.Stream,
    ) void {
        var previous = SuspendClockSample.now();
        while (!done.load(.seq_cst)) {
            if (cancel_flag.load(.seq_cst)) {
                if (connected_watch == null or connected_watch.?.win(.cancelled)) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                }
                return;
            }
            const current = SuspendClockSample.now();
            if (system_resumed != null and suspendGapDetected(previous, current)) {
                if (cancel_flag.load(.seq_cst)) {
                    if (connected_watch == null or connected_watch.?.win(.cancelled)) {
                        stream.shutdown(io_mod.getIo(), .both) catch {};
                    }
                    return;
                }
                if (connected_watch == null or connected_watch.?.win(.system_resumed)) {
                    system_resumed.?.store(true, .seq_cst);
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                }
                return;
            }
            if (deadline) |limit| {
                const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
                if (!std.Io.Clock.Timestamp.compare(now, .lt, limit)) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                    return;
                }
            }
            if (connected_watch) |watch| {
                const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
                if (watch.response_head_expired(now) and watch.win_response_head_timeout()) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                    return;
                }
                if (watch.stream_stall_expired(now) and watch.win_stall_timeout()) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                    return;
                }
                if (watch.phase.load(.seq_cst) == .completed) return;
            }
            previous = current;
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
    }
};

const suspend_gap_tolerance_ns: i128 = 100 * std.time.ns_per_ms;

const SuspendClockSample = struct {
    awake_ns: i128,
    boot_ns: i128,

    fn now() SuspendClockSample {
        const io = io_mod.getIo();
        return .{
            .awake_ns = @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds()),
            .boot_ns = @intCast(std.Io.Clock.Timestamp.now(io, .boot).raw.toNanoseconds()),
        };
    }
};

fn suspendGapDetected(previous: SuspendClockSample, current: SuspendClockSample) bool {
    const awake_elapsed = current.awake_ns - previous.awake_ns;
    const boot_elapsed = current.boot_ns - previous.boot_ns;
    if (awake_elapsed < 0 or boot_elapsed < 0) return false;
    return boot_elapsed - awake_elapsed > suspend_gap_tolerance_ns;
}

pub fn spawnHttpCancelWatcher(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    stream: std.Io.net.Stream,
) !std.Thread {
    return spawn_gateway_cancel_watcher(done, cancel_flag, null, null, null, stream);
}

pub fn spawnHttpCancelWatcherBounded(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    stream: std.Io.net.Stream,
) !std.Thread {
    return spawn_gateway_cancel_watcher(done, cancel_flag, null, deadline, null, stream);
}

/// One shared concrete opener result so every backend reuses the same
/// bounded-operation instantiation instead of specializing per file.
pub const OpenedPost = struct {
    request: ?std.http.Client.Request,

    pub fn deinit(self: *OpenedPost, _: std.mem.Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }

    pub fn take(self: *OpenedPost) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

pub const PostOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    authorization: ?[]const u8,
    extra_headers: []const std.http.Header = &.{},

    pub fn run(self: *PostOperation) !OpenedPost {
        var headers: std.http.Client.Request.Headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .user_agent = .{ .override = user_agent },
        };
        if (self.authorization) |value| headers.authorization = .{ .override = value };
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = headers,
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

pub fn openBoundedPost(
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    operation: *PostOperation,
) !OpenedPost {
    return runBoundedHttpOperation(OpenedPost, alloc, cancel_flag, deadline, operation);
}

pub const CancelWatch = struct {
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn start(self: *CancelWatch, cancel: *std.atomic.Value(bool), deadline: ?std.Io.Clock.Timestamp, connection: std.Io.net.Stream) !void {
        self.done.store(false, .seq_cst);
        self.thread = if (deadline) |limit|
            try spawnHttpCancelWatcherBounded(&self.done, cancel, limit, connection)
        else
            try spawnHttpCancelWatcher(&self.done, cancel, connection);
    }

    pub fn stop(self: *CancelWatch) void {
        self.done.store(true, .seq_cst);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
};

fn spawn_gateway_cancel_watcher(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    system_resumed: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
    connected_watch: ?*ConnectedRequestWatch,
    stream: std.Io.net.Stream,
) !std.Thread {
    if (builtin.is_test) {
        if (test_cancel_watcher_spawn_error) |err| return err;
    }
    return std.Thread.spawn(.{}, GatewayCancelWatcher.run, .{
        done,
        cancel_flag,
        system_resumed,
        deadline,
        connected_watch,
        stream,
    });
}

fn resolveE2eGatewayUrl(env_name: []const u8, default_url: []const u8) ![]const u8 {
    return selectE2eGatewayUrl(io_mod.getenv(env_name), default_url);
}

/// Chat URL exactly as the request path resolves it, including the E2E
/// loopback override. Invalid overrides fall back to the default so launch
/// warming never fails on configuration.
pub fn resolveChatUrlForWarmup(default_url: []const u8) []const u8 {
    return resolveE2eGatewayUrl(e2e_gateway_chat_url_env, default_url) catch default_url;
}

fn selectE2eGatewayUrl(override_url: ?[]const u8, default_url: []const u8) ![]const u8 {
    const override = override_url orelse return default_url;
    if (!isLoopbackHttpUrl(override)) return error.InvalidE2EGatewayUrl;
    return override;
}

pub fn isLoopbackHttpUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        uri.user != null or
        uri.password != null or
        uri.port == null)
    {
        return false;
    }

    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

const HeaderMatch = struct {
    name: []const u8,
    value: []const u8,
};

fn isRetryableGatewayStatus(status: std.http.Status) bool {
    return switch (status) {
        .too_many_requests,
        .internal_server_error,
        .bad_gateway,
        .service_unavailable,
        .gateway_timeout,
        => true,
        else => false,
    };
}

fn retryDelayNsForResponse(head: std.http.Client.Response.Head, attempt: usize) u64 {
    if (retryAfterDelayNs(head)) |delay_ns| return delay_ns;
    return retryBackoffDelayNs(attempt);
}

fn retryBackoffDelayNs(attempt: usize) u64 {
    const multiplier: u64 = @intCast(attempt + 1);
    return multiplier * gateway_retry_base_delay_ns;
}

fn retryAfterDelayNs(head: std.http.Client.Response.Head) ?u64 {
    const seconds = retryAfterSeconds(head) orelse return null;
    const delay = std.math.mul(u64, seconds, std.time.ns_per_s) catch gateway_retry_after_max_ns;
    return @min(delay, gateway_retry_after_max_ns);
}

fn retryAfterSeconds(head: std.http.Client.Response.Head) ?u64 {
    const raw = findHeaderValue(head, "retry-after") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u64, trimmed, 10) catch |err| switch (err) {
        error.Overflow => std.math.maxInt(u64),
        error.InvalidCharacter => null,
    };
}

fn findHeaderValue(head: std.http.Client.Response.Head, name: []const u8) ?[]const u8 {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn traceResolvedModelHeader(head: std.http.Client.Response.Head, requested_model: []const u8, trace_ctx: debug_trace.TraceContext) bool {
    if (findResolvedModelHeader(head)) |header| {
        traceResolvedModelOnce(requested_model, header.name, header.value, trace_ctx);
        return true;
    }
    return false;
}

fn traceResolvedModelOnce(requested_model: []const u8, source: []const u8, resolved_model: []const u8, trace_ctx: debug_trace.TraceContext) void {
    if (resolved_model_trace_emitted.swap(true, .acq_rel)) return;

    debug_trace.eventf(
        "gateway",
        "resolved_model",
        trace_ctx,
        "requested_model={s} source={s} resolved_model={s}",
        .{ requested_model, source, resolved_model },
    );
}

fn traceResolvedModelMissingOnce(requested_model: []const u8, trace_ctx: debug_trace.TraceContext) void {
    if (resolved_model_trace_emitted.swap(true, .acq_rel)) return;

    debug_trace.eventf(
        "gateway",
        "resolved_model_missing",
        trace_ctx,
        "requested_model={s}",
        .{requested_model},
    );
}

fn findResolvedModelHeader(head: std.http.Client.Response.Head) ?HeaderMatch {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (isResolvedModelHeaderName(header.name)) {
            return .{
                .name = header.name,
                .value = std.mem.trim(u8, header.value, " \t\r\n"),
            };
        }
    }
    return null;
}

fn isResolvedModelHeaderName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "x-vercel-ai-gateway-model") or
        std.ascii.eqlIgnoreCase(name, "x-vercel-ai-gateway-model-id") or
        std.ascii.eqlIgnoreCase(name, "x-ai-gateway-model") or
        std.ascii.eqlIgnoreCase(name, "ai-gateway-model") or
        std.ascii.eqlIgnoreCase(name, "ai-language-model-id");
}

const StreamedToolInputState = enum {
    open,
    ended,
    finalized,
};

const GatewayReplayBuilder = struct {
    const max_bytes = types.ProviderReplay.max_bytes;
    const Kind = enum { text, reasoning, tool_call };
    const Part = struct {
        kind: Kind,
        id: []u8,
        text: std.ArrayList(u8) = .empty,
        offset: usize = 0,
        length: usize = 0,
        metadata: ?[]u8 = null,
        has_provider_metadata: bool = false,
        ended: bool = false,

        fn deinit(self: *Part, alloc: std.mem.Allocator) void {
            alloc.free(self.id);
            self.text.deinit(alloc);
            if (self.metadata) |value| alloc.free(value);
        }
    };

    alloc: std.mem.Allocator,
    parts: std.ArrayList(Part) = .empty,
    retained_bytes: usize = 0,
    needed: bool = false,

    fn deinit(self: *GatewayReplayBuilder) void {
        for (self.parts.items) |*part| part.deinit(self.alloc);
        self.parts.deinit(self.alloc);
    }

    fn reserve(self: *GatewayReplayBuilder, bytes: usize) !void {
        if (bytes > max_bytes - self.retained_bytes) return error.ProviderStateTooLarge;
        self.retained_bytes += bytes;
    }

    fn findPart(parts: []const Part, kind: Kind, id: []const u8, starts_segment: bool) ?usize {
        for (0..parts.len) |offset| {
            const index = if (kind == .tool_call) offset else parts.len - 1 - offset;
            const part = parts[index];
            if (part.kind != kind or !std.mem.eql(u8, part.id, id)) continue;
            // Provider continuations can restart a text or reasoning ID within one response.
            if (kind != .tool_call and starts_segment and part.ended) return null;
            return index;
        }
        return null;
    }

    fn observe(self: *GatewayReplayBuilder, root: std.json.Value, content_offset: usize) !void {
        const event = root.object.get("type").?.string;
        const kind: Kind = if (std.mem.startsWith(u8, event, "reasoning-"))
            .reasoning
        else if (std.mem.startsWith(u8, event, "text-"))
            .text
        else if (std.mem.startsWith(u8, event, "tool-input-") or std.mem.eql(u8, event, "tool-call"))
            .tool_call
        else
            return;
        if (kind == .reasoning and !std.mem.eql(u8, event, "reasoning-start") and
            !std.mem.eql(u8, event, "reasoning-delta") and !std.mem.eql(u8, event, "reasoning-end")) return;
        const id_value = root.object.get(if (std.mem.eql(u8, event, "tool-call")) "toolCallId" else "id");
        const id: []const u8 = if (id_value) |value| if (value == .string) value.string else "" else "";
        // Canonical admission owns rejection of malformed tool identities.
        if (kind == .tool_call and types.ConversationIdentity.invalidReason(id) != null) return;
        if (id.len > types.ConversationIdentity.max_bytes) return error.ProviderStateTooLarge;
        var index = findPart(self.parts.items, kind, id, std.mem.eql(u8, event, "text-start") or
            std.mem.eql(u8, event, "reasoning-start"));
        if (index == null) {
            try self.reserve(@sizeOf(Part) + id.len);
            const owned_id = try self.alloc.dupe(u8, id);
            errdefer self.alloc.free(owned_id);
            try self.parts.append(self.alloc, .{ .kind = kind, .id = owned_id, .offset = content_offset });
            index = self.parts.items.len - 1;
        }
        const part = &self.parts.items[index.?];
        if (kind == .reasoning) self.needed = true;
        if (std.mem.endsWith(u8, event, "-delta") and kind != .tool_call) {
            const delta = root.object.get("delta") orelse return;
            if (delta != .string) return error.InvalidProviderState;
            if (part.ended) return error.InvalidProviderState;
            if (kind == .reasoning) {
                try self.reserve(delta.string.len);
                try part.text.appendSlice(self.alloc, delta.string);
            } else {
                const end = std.math.add(usize, part.offset, part.length) catch return error.ProviderStateTooLarge;
                if (content_offset != end) return error.InvalidProviderState;
                part.length = std.math.add(usize, part.length, delta.string.len) catch return error.ProviderStateTooLarge;
            }
        }
        if (std.mem.endsWith(u8, event, "-end") or std.mem.eql(u8, event, "tool-call")) part.ended = true;
        if (root.object.get("providerMetadata")) |metadata| {
            if (metadata != .object) return error.InvalidProviderState;
            for (metadata.object.values()) |options| if (options != .object) return error.InvalidProviderState;
            for (metadata.object.keys()) |key| {
                if (!std.mem.eql(u8, key, "gateway")) {
                    self.needed = true;
                    part.has_provider_metadata = true;
                }
            }
            if (part.has_provider_metadata and id.len == 0) return error.InvalidProviderState;
            const merged = try mergeReplayMetadata(self.alloc, part.metadata, metadata);
            errdefer self.alloc.free(merged);
            const previous_len = if (part.metadata) |previous| previous.len else 0;
            if (merged.len > previous_len) try self.reserve(merged.len - previous_len);
            if (merged.len < previous_len) self.retained_bytes -= previous_len - merged.len;
            if (part.metadata) |previous| self.alloc.free(previous);
            part.metadata = merged;
        }
    }

    fn finish(self: *GatewayReplayBuilder, content: []const u8, calls: []const types.ToolCall) !?[]u8 {
        if (!self.needed) return null;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer out.deinit();
        try out.writer.writeByte('[');
        var emitted = false;
        parts: for (self.parts.items, 0..) |part, index| {
            var metadata: ?[]const u8 = part.metadata;
            var merged_metadata: ?[]u8 = null;
            defer if (merged_metadata) |owned| self.alloc.free(owned);
            var canonical_call: ?types.ToolCall = null;
            if (part.kind == .tool_call) {
                for (calls) |call| {
                    if (partMatchesCall(part, call)) {
                        canonical_call = call;
                        break;
                    }
                }
                const call = canonical_call orelse {
                    if (part.has_provider_metadata) return error.InvalidProviderState;
                    continue;
                };
                for (self.parts.items[0..index]) |prior| {
                    if (partMatchesCall(prior, call)) continue :parts;
                }
                for (self.parts.items[index + 1 ..]) |later| {
                    if (!partMatchesCall(later, call)) continue;
                    const next = later.metadata orelse continue;
                    const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, next, .{});
                    defer parsed.deinit();
                    const merged = try mergeReplayMetadata(self.alloc, metadata, parsed.value);
                    if (merged_metadata) |owned| self.alloc.free(owned);
                    merged_metadata = merged;
                    metadata = merged;
                }
            }
            if (emitted) try out.writer.writeByte(',');
            switch (part.kind) {
                .reasoning => {
                    if (!part.ended and part.metadata != null) return error.InvalidProviderState;
                    try out.writer.writeAll("{\"type\":\"reasoning\",\"text\":");
                    try std.json.Stringify.value(part.text.items, .{}, &out.writer);
                },
                .text => {
                    if (part.offset > content.len or part.length > content.len - part.offset) return error.InvalidProviderState;
                    try out.writer.print("{{\"type\":\"text\",\"offset\":{d},\"length\":{d}", .{ part.offset, part.length });
                },
                .tool_call => {
                    try out.writer.writeAll("{\"type\":\"tool-call\",\"toolCallId\":");
                    try std.json.Stringify.value(canonical_call.?.id, .{}, &out.writer);
                },
            }
            if (metadata) |value| {
                try out.writer.writeAll(",\"providerOptions\":");
                try out.writer.writeAll(value);
            }
            try out.writer.writeByte('}');
            emitted = true;
            if (out.written().len > max_bytes) return error.ProviderStateTooLarge;
        }
        try out.writer.writeByte(']');
        if (out.written().len > max_bytes) return error.ProviderStateTooLarge;
        return try out.toOwnedSlice();
    }

    fn partMatchesCall(part: Part, call: types.ToolCall) bool {
        return part.kind == .tool_call and (std.mem.eql(u8, part.id, call.id) or
            if (call.provisional_id) |id| std.mem.eql(u8, part.id, id) else false);
    }
};

fn mergeReplayMetadata(alloc: std.mem.Allocator, previous: ?[]const u8, next: std.json.Value) ![]u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var merged = if (previous) |bytes|
        try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{})
    else
        std.json.Value{ .object = .empty };
    try mergeReplayObject(arena, &merged, next);
    return stringifyJsonValueOwned(alloc, merged);
}

fn mergeReplayObject(alloc: std.mem.Allocator, target: *std.json.Value, next: std.json.Value) !void {
    const Merge = struct { target: *std.json.Value, source: std.json.Value };
    var pending: std.ArrayList(Merge) = .empty;
    defer pending.deinit(alloc);
    try pending.append(alloc, .{ .target = target, .source = next });
    while (pending.pop()) |entry| {
        if (entry.target.* != .object or entry.source != .object) {
            entry.target.* = entry.source;
            continue;
        }
        const capacity = std.math.add(usize, entry.target.object.count(), entry.source.object.count()) catch return error.ProviderStateTooLarge;
        try entry.target.object.ensureTotalCapacity(alloc, capacity);
        var fields = entry.source.object.iterator();
        while (fields.next()) |field| {
            const slot = entry.target.object.getOrPutAssumeCapacity(field.key_ptr.*);
            if (slot.found_existing) {
                try pending.append(alloc, .{ .target = slot.value_ptr, .source = field.value_ptr.* });
            } else {
                slot.value_ptr.* = field.value_ptr.*;
            }
        }
    }
}

const SseStreamedToolInput = struct {
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    arguments: std.ArrayList(u8),
    state: StreamedToolInputState = .open,
    label_sent: bool = false,

    fn deinit(self: *SseStreamedToolInput, alloc: std.mem.Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

const ProviderResultState = enum {
    none,
    preliminary,
    final,
};

const SseToolCallAccumulator = struct {
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    arguments: std.ArrayList(u8),
    provisional_id: std.ArrayList(u8) = .empty,
    argument_integrity: types.ToolArgumentIntegrity = .valid,
    argument_diagnostic: ?types.ToolArgumentDiagnostic = null,
    provider_result: ?[]u8 = null,
    provider_result_state: ProviderResultState = .none,
    final_identity: types.FinalToolIdentity = .valid,
    provenance: types.ToolExecutionProvenance = .fx_local,

    fn deinit(self: *SseToolCallAccumulator, alloc: std.mem.Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.provisional_id.deinit(alloc);
        if (self.provider_result) |result| alloc.free(result);
        self.* = undefined;
    }
};

const ResolvedModelTrace = struct {
    requested_model: []const u8,
    ctx: debug_trace.TraceContext,
};

const StreamStateAnomaly = enum {
    invalid_start,
    conflicting_start,
    late_start,
    unmatched_or_late_delta,
    unmatched_or_duplicate_end,
};

var test_force_sse_preview_failure = false;

fn traceStreamStateAnomaly(reason: StreamStateAnomaly) void {
    debug_trace.logf("sse", "event=stream_state_anomaly reason={s}", .{@tagName(reason)});
}

fn canonicalSseEventType(event_type: []const u8) []const u8 {
    inline for (.{
        "response-metadata",
        "text-start",
        "text-delta",
        "text-end",
        "reasoning-start",
        "reasoning-delta",
        "reasoning-end",
        "tool-input-start",
        "tool-input-delta",
        "tool-input-end",
        "tool-call",
        "tool-result",
        "source",
        "file",
        "raw",
        "error",
        "start",
        "start-step",
        "finish-step",
        "finish",
    }) |known| {
        if (std.mem.eql(u8, event_type, known)) return known;
    }
    return "unknown";
}

fn traceParsedSseEvent(alloc: std.mem.Allocator, root: std.json.Value, json_bytes: usize) void {
    if (!debug_trace.isScopeEnabled("sse")) return;

    const event_type = if (root == .object)
        if (root.object.get("type")) |type_value|
            if (type_value == .string)
                canonicalSseEventType(type_value.string)
            else
                "invalid"
        else
            "invalid"
    else
        "invalid";

    if (builtin.is_test and test_force_sse_preview_failure) {
        debug_trace.logf("sse", "event type={s} bytes={d} preview=<preview-error>", .{
            event_type,
            json_bytes,
        });
        return;
    }

    const preview_text = debug_trace.keylessJsonValuePreview(alloc, root) catch {
        debug_trace.logf("sse", "event type={s} bytes={d} preview=<preview-error>", .{
            event_type,
            json_bytes,
        });
        return;
    };
    defer alloc.free(preview_text);
    debug_trace.logf("sse", "event type={s} bytes={d} preview={s}", .{
        event_type,
        json_bytes,
        preview_text,
    });
}

fn traceMalformedSseEvent(json_bytes: usize) void {
    debug_trace.logf("sse", "event type=invalid bytes={d} preview=<invalid-json>", .{json_bytes});
}

fn setProviderResultFailure(
    failure: *?types.ProviderResultIdentityFailure,
    value: types.ProviderResultIdentityFailure,
) void {
    if (failure.* == null) failure.* = value;
}

fn findStreamedToolInput(records: []const SseStreamedToolInput, id: []const u8) ?usize {
    for (records, 0..) |record, i| {
        if (std.mem.eql(u8, record.id.items, id)) return i;
    }
    return null;
}

fn findEquivalentEndedStreamedToolInput(
    alloc: std.mem.Allocator,
    records: []const SseStreamedToolInput,
    final_name: []const u8,
    final_arguments: []const u8,
) std.mem.Allocator.Error!?usize {
    if (final_name.len == 0) return null;

    for (records, 0..) |record, i| {
        if (record.state != .ended) continue;
        if (!std.mem.eql(u8, record.name.items, final_name)) continue;
        if (try json_comparison.serializedEqual(alloc, record.arguments.items, final_arguments)) return i;
    }
    return null;
}

fn initStreamedToolInput(
    alloc: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
) !SseStreamedToolInput {
    var record: SseStreamedToolInput = .{
        .id = .empty,
        .name = .empty,
        .arguments = .empty,
    };
    errdefer record.deinit(alloc);
    try record.id.appendSlice(alloc, id);
    try record.name.appendSlice(alloc, name);
    return record;
}

fn streamedToolInputId(
    root: std.json.Value,
    anomaly: StreamStateAnomaly,
) ?[]const u8 {
    const id_value = root.object.get("id") orelse {
        traceStreamStateAnomaly(anomaly);
        return null;
    };
    if (id_value != .string or id_value.string.len == 0) {
        traceStreamStateAnomaly(anomaly);
        return null;
    }
    return id_value.string;
}

const ToolArgumentSource = enum {
    final_string,
    streamed_fallback,
};

const FinalToolInputState = enum {
    absent,
    valid,
    malformed,
};

const ClassifiedToolArguments = struct {
    integrity: types.ToolArgumentIntegrity,
    diagnostic: ?types.ToolArgumentDiagnostic = null,
};

fn appendSerializedToolArguments(
    alloc: std.mem.Allocator,
    destination: *std.ArrayList(u8),
    serialized: []const u8,
    call_id: []const u8,
    tool_name: []const u8,
    source: ToolArgumentSource,
) !ClassifiedToolArguments {
    const integrity = try types.ToolArgumentIntegrity.classifySerialized(alloc, serialized);
    if (integrity == .valid) {
        try destination.appendSlice(alloc, serialized);
        return .{ .integrity = .valid };
    }

    // The raw bytes are replaced below; keep what the model needs to repair them.
    const diagnostic = try types.ToolArgumentDiagnostic.diagnose(alloc, serialized);
    try destination.appendSlice(alloc, "{}");
    debug_trace.logf(
        "sse",
        "event=tool_argument_integrity call_id={s} tool_name={s} source={s} bytes={d} failure=malformed_json diagnosis={s} error_offset={?d}",
        .{ call_id, tool_name, @tagName(source), serialized.len, @tagName(diagnostic.failure), diagnostic.error_offset },
    );
    return .{ .integrity = .malformed_json, .diagnostic = diagnostic };
}

fn appendSupportedFinalInput(
    alloc: std.mem.Allocator,
    destination: *std.ArrayList(u8),
    input: std.json.Value,
    call_id: []const u8,
    tool_name: []const u8,
) !ClassifiedToolArguments {
    switch (input) {
        .string => |value| {
            return try appendSerializedToolArguments(
                alloc,
                destination,
                value,
                call_id,
                tool_name,
                .final_string,
            );
        },
        .object, .array => {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            std.json.Stringify.value(input, .{}, &out.writer) catch return error.OutOfMemory;
            try destination.appendSlice(alloc, out.written());
            return .{ .integrity = .valid };
        },
        else => {
            try destination.appendSlice(alloc, "{}");
            debug_trace.logf(
                "sse",
                "event=tool_argument_integrity call_id={s} tool_name={s} source=final_value input_kind={s} failure=malformed_json",
                .{ call_id, tool_name, @tagName(input) },
            );
            return .{ .integrity = .malformed_json };
        },
    }
}

fn stringifyJsonValueOwned(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn deinitGatewayCompletion(alloc: std.mem.Allocator, completion: *types.ModelCompletion) void {
    if (completion.content) |content| alloc.free(content);
    if (completion.generation_id) |id| alloc.free(id);
    if (completion.resolved_provider) |provider| alloc.free(@constCast(provider));
    if (completion.billing) |billing| alloc.free(@constCast(billing.model));
    for (completion.tool_calls) |call| {
        alloc.free(call.id);
        alloc.free(call.name);
        alloc.free(call.arguments_json);
        if (call.provisional_id) |provisional_id| alloc.free(provisional_id);
        if (call.provider_result) |provider_result| alloc.free(provider_result);
    }
    if (completion.tool_calls.len > 0) alloc.free(completion.tool_calls);
    if (completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
    if (completion.provider_state_json) |state| alloc.free(state);
    completion.* = .{};
}

fn clippedDupe(alloc: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    const clipped = trimmed[0..@min(trimmed.len, max_bytes)];
    return try alloc.dupe(u8, clipped);
}

fn replaceProviderFailureDetail(alloc: std.mem.Allocator, current: *?[]u8, text: []const u8) !void {
    if (text.len == 0) return;
    const owned = try clippedDupe(alloc, text, provider_failure_detail_max_bytes);
    if (owned.len == 0) {
        alloc.free(owned);
        return;
    }
    if (current.*) |old| alloc.free(old);
    current.* = owned;
}

fn replaceProviderFailureMessage(
    alloc: std.mem.Allocator,
    current: *?[]u8,
    text: []const u8,
) !void {
    const combined = try alloc.print("provider_error: {s}", .{text});
    defer alloc.free(combined);
    try replaceProviderFailureDetail(alloc, current, combined);
}

fn jsonValueString(value: std.json.Value) ?[]const u8 {
    return if (value == .string and value.string.len > 0) value.string else null;
}

fn isGatewayStreamTimeoutCode(value: std.json.Value) bool {
    const text = jsonValueString(value) orelse return false;
    return std.mem.eql(u8, text, "gateway_stream_timeout");
}

fn objectHasGatewayStreamTimeout(object: std.json.ObjectMap) bool {
    if (object.get("code")) |value| {
        if (isGatewayStreamTimeoutCode(value)) return true;
    }
    if (object.get("type")) |value| {
        if (isGatewayStreamTimeoutCode(value)) return true;
    }
    return false;
}

fn providerFailureCause(root: std.json.Value) ?types.ProviderFailureCause {
    if (root != .object) return null;
    const object = root.object;
    if (objectHasGatewayStreamTimeout(object)) return .gateway_stream_timeout;

    inline for (.{ "error", "providerError" }) |key| {
        if (object.get(key)) |value| {
            if (value == .object and objectHasGatewayStreamTimeout(value.object)) {
                return .gateway_stream_timeout;
            }
        }
    }
    if (object.get("finishReason")) |value| {
        if (value == .object) {
            if (value.object.get("raw")) |raw| {
                if (isGatewayStreamTimeoutCode(raw)) return .gateway_stream_timeout;
            }
        }
    }
    return null;
}

fn captureProviderFailureObject(
    alloc: std.mem.Allocator,
    current: *?[]u8,
    object: std.json.ObjectMap,
    include_type: bool,
) !bool {
    const code = if (object.get("code")) |value|
        jsonValueString(value)
    else if (include_type)
        if (object.get("type")) |value| jsonValueString(value) else null
    else
        null;
    const message = if (object.get("message")) |value| jsonValueString(value) else null;
    if (code) |code_text| {
        if (message) |message_text| {
            const combined = try alloc.print("{s}: {s}", .{ code_text, message_text });
            defer alloc.free(combined);
            try replaceProviderFailureDetail(alloc, current, combined);
            return true;
        }
    }

    const message_keys = [_][]const u8{ "message", "detail", "details", "reason" };
    for (&message_keys) |key| {
        if (object.get(key)) |value| {
            if (jsonValueString(value)) |text| {
                try replaceProviderFailureMessage(alloc, current, text);
                return true;
            }
        }
    }
    if (code) |code_text| {
        try replaceProviderFailureDetail(alloc, current, code_text);
        return true;
    }
    return false;
}

fn captureProviderFailureDetail(alloc: std.mem.Allocator, current: *?[]u8, root: std.json.Value) !void {
    if (root != .object or current.* != null) return;
    if (try captureProviderFailureObject(alloc, current, root.object, false)) return;
    if (root.object.get("error")) |value| {
        if (jsonValueString(value)) |text| {
            try replaceProviderFailureMessage(alloc, current, text);
            return;
        }
        if (value == .object) {
            if (try captureProviderFailureObject(alloc, current, value.object, true)) return;
            const rendered = try stringifyJsonValueOwned(alloc, value);
            defer alloc.free(rendered);
            try replaceProviderFailureDetail(alloc, current, rendered);
            return;
        }
    }
    if (root.object.get("providerError")) |value| {
        if (jsonValueString(value)) |text| {
            try replaceProviderFailureMessage(alloc, current, text);
            return;
        }
        if (value == .object) {
            if (try captureProviderFailureObject(alloc, current, value.object, true)) return;
        }
        const rendered = try stringifyJsonValueOwned(alloc, value);
        defer alloc.free(rendered);
        try replaceProviderFailureDetail(alloc, current, rendered);
    }
}

fn materializeToolCalls(
    alloc: std.mem.Allocator,
    accumulators: []const SseToolCallAccumulator,
) ![]const types.ToolCall {
    if (accumulators.len == 0) return &.{};

    const calls = try alloc.alloc(types.ToolCall, accumulators.len);
    var initialized: usize = 0;
    errdefer {
        for (calls[0..initialized]) |call| {
            alloc.free(call.id);
            alloc.free(call.name);
            alloc.free(call.arguments_json);
            if (call.provisional_id) |provisional_id| alloc.free(provisional_id);
            if (call.provider_result) |provider_result| alloc.free(provider_result);
        }
        alloc.free(calls);
    }

    for (accumulators, 0..) |acc, i| {
        const id = try alloc.dupe(u8, acc.id.items);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, acc.name.items);
        errdefer alloc.free(name);
        const arguments = try alloc.dupe(u8, acc.arguments.items);
        errdefer alloc.free(arguments);
        const provisional_id = if (acc.provisional_id.items.len > 0)
            try alloc.dupe(u8, acc.provisional_id.items)
        else
            null;
        errdefer if (provisional_id) |value| alloc.free(value);
        const provider_result = if (acc.provider_result_state == .final)
            if (acc.provider_result) |result| try alloc.dupe(u8, result) else null
        else
            null;
        errdefer if (provider_result) |result| alloc.free(result);

        calls[i] = .{
            .id = id,
            .name = name,
            .arguments_json = arguments,
            .argument_integrity = acc.argument_integrity,
            .argument_diagnostic = acc.argument_diagnostic,
            .provisional_id = provisional_id,
            .provider_result = provider_result,
            .final_identity = acc.final_identity,
            .provenance = acc.provenance,
        };
        initialized += 1;
    }

    return calls;
}

fn extractFirstJsonStringValue(args: []const u8) ?[]const u8 {
    const colon = std.mem.findScalar(u8, args, ':') orelse return null;
    var i = colon + 1;
    while (i < args.len and args[i] == ' ') : (i += 1) {}
    if (i >= args.len or args[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < args.len) : (i += 1) {
        if (args[i] == '\\') {
            i += 1;
            continue;
        }
        if (args[i] == '"') return args[start..i];
    }
    return null;
}

fn finish_reason_label(finish_reason: ?types.ProviderFinishReason) []const u8 {
    return if (finish_reason) |reason| reason.label() else "(none)";
}

fn traceSseTermination(trace: ?ResolvedModelTrace, cause: []const u8, finish_reason: ?types.ProviderFinishReason) void {
    debug_trace.logf("stream", "termination cause={s} finish_reason={s}", .{
        cause,
        finish_reason_label(finish_reason),
    });
    if (trace) |resolved| {
        debug_trace.eventf("gateway", "sse_termination", resolved.ctx, "cause={s} finish_reason={s}", .{
            cause,
            finish_reason_label(finish_reason),
        });
    }
}

const SseFinishEvent = struct {
    finish_reason: types.ProviderFinishReason,
    usage: types.Usage = .{},
};

const SseFinishParseError = error{
    InvalidProviderFinishReason,
    UnknownProviderFinishReason,
};

fn parseSseFinishEvent(
    alloc: std.mem.Allocator,
    root: std.json.Value,
    provider_failure_detail: *?[]u8,
) !SseFinishEvent {
    const finish_reason = try parseSseFinishReason(root);
    if (finish_reason == .provider_error) {
        try captureProviderFailureDetail(alloc, provider_failure_detail, root);
    }
    return .{
        .finish_reason = finish_reason,
        .usage = parseSseUsage(root),
    };
}

fn parseSseFinishReason(root: std.json.Value) SseFinishParseError!types.ProviderFinishReason {
    if (root != .object) return error.InvalidProviderFinishReason;
    const finish_reason_value = root.object.get("finishReason") orelse
        return error.InvalidProviderFinishReason;
    if (finish_reason_value != .object) return error.InvalidProviderFinishReason;
    const unified_value = finish_reason_value.object.get("unified") orelse
        return error.InvalidProviderFinishReason;
    if (unified_value != .string) return error.InvalidProviderFinishReason;
    return types.ProviderFinishReason.parse_unified(unified_value.string) orelse
        error.UnknownProviderFinishReason;
}

fn parseSseUsage(root: std.json.Value) types.Usage {
    if (root != .object) return .{};
    const usage_value = root.object.get("usage") orelse return .{};
    if (usage_value != .object) return .{};
    return .{
        .input_tokens = parseSseTokenTotal(usage_value, "inputTokens"),
        .output_tokens = parseSseTokenTotal(usage_value, "outputTokens"),
        .reasoning_tokens = parseSseTokenDetail(usage_value, "outputTokens", "reasoning"),
    };
}

fn parseSseTokenDetail(usage_value: std.json.Value, section: []const u8, key: []const u8) ?u64 {
    const section_value = usage_value.object.get(section) orelse return null;
    if (section_value != .object) return null;
    const detail = section_value.object.get(key) orelse return null;
    if (detail != .integer or detail.integer < 0) return null;
    return @intCast(detail.integer);
}

fn parseSseTokenTotal(usage_value: std.json.Value, key: []const u8) ?u64 {
    if (usage_value != .object) return null;
    const token_value = usage_value.object.get(key) orelse return null;
    if (token_value != .object) return null;
    const total_value = token_value.object.get("total") orelse return null;
    if (total_value != .integer or total_value.integer < 0) return null;
    return @intCast(total_value.integer);
}

const SseBillingParseError = std.mem.Allocator.Error || error{InvalidSseBilling};

fn parseSseBilling(
    alloc: std.mem.Allocator,
    root: std.json.Value,
    created_at_ms: ?i64,
    tools: []const SseToolCallAccumulator,
) SseBillingParseError!types.ProviderBilling {
    const timestamp = created_at_ms orelse return error.InvalidSseBilling;
    const usage = if (root == .object)
        root.object.get("usage") orelse return error.InvalidSseBilling
    else
        return error.InvalidSseBilling;
    if (usage != .object) return error.InvalidSseBilling;
    const input = usage.object.get("inputTokens") orelse
        return error.InvalidSseBilling;
    const output = usage.object.get("outputTokens") orelse
        return error.InvalidSseBilling;
    if (input != .object or output != .object) return error.InvalidSseBilling;

    const provider_metadata = root.object.get("providerMetadata") orelse
        return error.InvalidSseBilling;
    if (provider_metadata != .object) return error.InvalidSseBilling;
    const gateway = provider_metadata.object.get("gateway") orelse
        return error.InvalidSseBilling;
    if (gateway != .object) return error.InvalidSseBilling;
    const routing = gateway.object.get("routing") orelse
        return error.InvalidSseBilling;
    if (routing != .object) return error.InvalidSseBilling;
    const model_value = routing.object.get("canonicalSlug") orelse
        return error.InvalidSseBilling;
    if (model_value != .string or
        model_value.string.len == 0 or
        model_value.string.len > 1024)
    {
        return error.InvalidSseBilling;
    }
    for (model_value.string) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidSseBilling;
    }

    const cost_value = gateway.object.get("cost") orelse
        return error.InvalidSseBilling;
    if (cost_value != .string) return error.InvalidSseBilling;
    const total_cost = std.fmt.parseFloat(f64, cost_value.string) catch
        return error.InvalidSseBilling;
    if (!std.math.isFinite(total_cost) or total_cost < 0) {
        return error.InvalidSseBilling;
    }

    var billable_web_search_calls: u64 = 0;
    for (tools) |tool| {
        if (tool.provenance != .provider_executed) continue;
        if (!std.mem.eql(u8, tool.name.items, "web_search") and
            !std.mem.endsWith(u8, tool.name.items, "_search"))
        {
            continue;
        }
        billable_web_search_calls = std.math.add(
            u64,
            billable_web_search_calls,
            1,
        ) catch return error.InvalidSseBilling;
    }

    const input_tokens = try parseBillingInteger(input.object.get("total"));
    const output_tokens = try parseBillingInteger(output.object.get("total"));
    const cache_read_tokens = try parseOptionalBillingInteger(
        input.object.get("cacheRead"),
    );
    const cache_write_tokens = try parseOptionalBillingInteger(
        input.object.get("cacheWrite"),
    );
    const reasoning_tokens = try parseOptionalNullableBillingInteger(
        output.object.get("reasoning"),
    );
    if (cache_read_tokens > input_tokens or
        cache_write_tokens > input_tokens or
        (reasoning_tokens != null and reasoning_tokens.? > output_tokens))
    {
        return error.InvalidSseBilling;
    }

    return .{
        .created_at_ms = timestamp,
        .model = try alloc.dupe(u8, model_value.string),
        .total_cost = total_cost,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_read_tokens = cache_read_tokens,
        .cache_write_tokens = cache_write_tokens,
        .reasoning_tokens = reasoning_tokens,
        .billable_web_search_calls = billable_web_search_calls,
    };
}

fn parseBillingInteger(value: ?std.json.Value) error{InvalidSseBilling}!u64 {
    const actual = value orelse return error.InvalidSseBilling;
    if (actual != .integer or actual.integer < 0) {
        return error.InvalidSseBilling;
    }
    return @intCast(actual.integer);
}

fn parseOptionalBillingInteger(
    value: ?std.json.Value,
) error{InvalidSseBilling}!u64 {
    return if (value) |actual| try parseBillingInteger(actual) else 0;
}

fn parseOptionalNullableBillingInteger(
    value: ?std.json.Value,
) error{InvalidSseBilling}!?u64 {
    return if (value) |actual|
        if (actual == .null) null else try parseBillingInteger(actual)
    else
        null;
}

/// Extracts the gateway's resolved provider slug from finish routing
/// metadata. Display-only: absent or malformed routing never fails the
/// stream, it just leaves the completion without routing detail.
fn parseSseResolvedProvider(alloc: std.mem.Allocator, root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const provider_metadata = root.object.get("providerMetadata") orelse return null;
    if (provider_metadata != .object) return null;
    const gateway = provider_metadata.object.get("gateway") orelse return null;
    if (gateway != .object) return null;
    const routing = gateway.object.get("routing") orelse return null;
    if (routing != .object) return null;
    const provider_value = routing.object.get("finalProvider") orelse
        routing.object.get("resolvedProvider") orelse return null;
    if (provider_value != .string or provider_value.string.len == 0 or
        provider_value.string.len > 128) return null;
    for (provider_value.string) |byte| {
        if (byte < 0x21 or byte > 0x7e) return null;
    }
    return alloc.dupe(u8, provider_value.string) catch null;
}

/// Extracts the Gateway-confirmed applied service tier from terminal metadata.
/// Request options and provider-specific metadata are intentionally ignored.
fn parseSseServiceTier(root: std.json.Value) ?types.ProviderServiceTier {
    if (root != .object) return null;
    const provider_metadata = root.object.get("providerMetadata") orelse
        root.object.get("provider_metadata") orelse return null;
    if (provider_metadata != .object) return null;
    const gateway = provider_metadata.object.get("gateway") orelse return null;
    if (gateway != .object) return null;
    const service_tier = gateway.object.get("serviceTier") orelse return null;
    if (service_tier != .string) return null;
    return types.ProviderServiceTier.parse(service_tier.string);
}

fn captureGenerationMetadata(
    alloc: std.mem.Allocator,
    root: std.json.Value,
    generation_id: *?[]u8,
    invalid: *bool,
) !void {
    if (root != .object) return;
    const provider_metadata = root.object.get("providerMetadata") orelse return;
    if (provider_metadata != .object) {
        invalid.* = true;
        return;
    }
    const gateway = provider_metadata.object.get("gateway") orelse return;
    if (gateway != .object) {
        invalid.* = true;
        return;
    }
    const generation_value = gateway.object.get("generationId") orelse return;
    if (generation_value != .string or !types.validGatewayGenerationId(generation_value.string)) {
        invalid.* = true;
        return;
    }
    if (generation_id.*) |existing| {
        if (!std.mem.eql(u8, existing, generation_value.string)) invalid.* = true;
        return;
    }
    generation_id.* = try alloc.dupe(u8, generation_value.string);
}

/// Decodes an AI Gateway SSE response from a transport-owned reader.
///
/// The returned completion and every populated child buffer are owned by
/// `alloc`. This is the shared protocol boundary used by native HTTP and web
/// host transports; transports remain responsible for status and headers.
pub fn consumeGatewaySseStream(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    on_reasoning_chunk: ?StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.ModelCompletion {
    return consumeSseStreamTraced(
        alloc,
        reader,
        callback_ctx,
        on_content_chunk,
        on_tool_start,
        on_reasoning_chunk,
        null,
        cancel_flag,
        null,
        null,
        content_capture_limit,
        null,
    );
}

fn consumeSseStreamTraced(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    on_reasoning_chunk: ?StreamCallback,
    on_tool_input_chunk: ?StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    resolved_model_trace: ?ResolvedModelTrace,
    expected_provider_tool_name: ?[]const u8,
    content_capture_limit: ?usize,
    progress_watch: ?*ConnectedRequestWatch,
) !types.ModelCompletion {
    var content_buf: std.ArrayList(u8) = .empty;
    defer content_buf.deinit(alloc);
    var replay = GatewayReplayBuilder{ .alloc = alloc };
    defer replay.deinit();
    // Reuse event storage instead of pinning old response buffers in the caller's arena.
    var event_arena = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(event_arena);

    var streamed_tool_inputs: std.ArrayList(SseStreamedToolInput) = .empty;
    defer {
        for (streamed_tool_inputs.items) |*record| record.deinit(alloc);
        streamed_tool_inputs.deinit(alloc);
    }

    var tool_accumulators: std.ArrayList(SseToolCallAccumulator) = .empty;
    defer {
        for (tool_accumulators.items) |*acc| acc.deinit(alloc);
        tool_accumulators.deinit(alloc);
    }

    var finish_reason_holder: ?types.ProviderFinishReason = null;
    var finish_usage: types.Usage = .{};
    var finish_resolved_provider: ?[]const u8 = null;
    defer if (finish_resolved_provider) |provider| alloc.free(@constCast(provider));
    var finish_billing: ?types.ProviderBilling = null;
    defer if (finish_billing) |billing| alloc.free(@constCast(billing.model));
    var finish_service_tier: ?types.ProviderServiceTier = null;
    var generation_id: ?[]u8 = null;
    defer if (generation_id) |id| alloc.free(id);
    var resolved_model: ?[]u8 = null;
    defer if (resolved_model) |model| alloc.free(model);
    var response_timestamp_ms: ?i64 = null;
    var response_timestamp_invalid = false;
    var generation_metadata_invalid = false;
    var provider_result_identity_failure: ?types.ProviderResultIdentityFailure = null;
    var provider_failure_cause: ?types.ProviderFailureCause = null;
    var provider_failure_detail: ?[]u8 = null;
    defer if (provider_failure_detail) |detail| alloc.free(detail);
    var data_event_count: usize = 0;

    var event_reader = sse.Reader{ .max_event_bytes = max_sse_event_line_bytes };
    defer event_reader.deinit(alloc);

    while (true) {
        if (cancel_flag.load(.seq_cst)) {
            traceSseTermination(resolved_model_trace, "cancellation", finish_reason_holder);
            break;
        }

        const payload = event_reader.next(alloc, reader, cancel_flag) catch |err| switch (err) {
            error.EventTooLarge => return error.GatewaySseEventTooLarge,
            error.Cancelled => {
                traceSseTermination(resolved_model_trace, "cancellation", finish_reason_holder);
                break;
            },
            error.ReadFailed => {
                if (cancel_flag.load(.seq_cst)) {
                    traceSseTermination(resolved_model_trace, "cancellation", finish_reason_holder);
                    break;
                }
                traceSseTermination(resolved_model_trace, "read_failure", finish_reason_holder);
                return error.ReadFailed;
            },
            else => return err,
        };
        const json_text = payload orelse {
            traceSseTermination(resolved_model_trace, "eof_without_finish", finish_reason_holder);
            break;
        };
        if (progress_watch) |watch| watch.markStreamProgress();
        if (std.mem.eql(u8, json_text, "[DONE]")) {
            traceSseTermination(resolved_model_trace, "done_without_finish", finish_reason_holder);
            break;
        }
        data_event_count += 1;

        defer _ = event_arena.reset(.retain_capacity);
        const root = std.json.parseFromSliceLeaky(std.json.Value, event_arena.allocator(), json_text, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            traceMalformedSseEvent(json_text.len);
            return error.InvalidGatewaySseEvent;
        };
        traceParsedSseEvent(alloc, root, json_text.len);
        if (root != .object) continue;
        try captureGenerationMetadata(
            alloc,
            root,
            &generation_id,
            &generation_metadata_invalid,
        );

        const type_val = root.object.get("type") orelse continue;
        if (type_val != .string) continue;
        const event_type = type_val.string;

        if (content_capture_limit == null) try replay.observe(root, content_buf.items.len);

        if (std.mem.eql(u8, event_type, "response-metadata")) {
            if (root.object.get("timestamp")) |timestamp_value| {
                if (timestamp_value == .string) {
                    const timestamp = types.parseGatewayTimestamp(
                        timestamp_value.string,
                    ) catch null;
                    if (timestamp) |valid_timestamp| {
                        if (response_timestamp_ms) |existing| {
                            if (existing != valid_timestamp) {
                                response_timestamp_invalid = true;
                                response_timestamp_ms = null;
                            }
                        } else if (!response_timestamp_invalid) {
                            response_timestamp_ms = valid_timestamp;
                        }
                    } else {
                        response_timestamp_invalid = true;
                        response_timestamp_ms = null;
                    }
                } else {
                    response_timestamp_invalid = true;
                    response_timestamp_ms = null;
                }
            }
            if (root.object.get("modelId")) |model_val| {
                if (model_val == .string and model_val.string.len > 0 and model_val.string.len <= 128) {
                    if (resolved_model) |existing| {
                        if (!std.mem.eql(u8, existing, model_val.string)) {
                            generation_metadata_invalid = true;
                        }
                    } else {
                        resolved_model = try alloc.dupe(u8, model_val.string);
                    }
                } else {
                    generation_metadata_invalid = true;
                }
            }
            if (resolved_model_trace) |trace| {
                if (root.object.get("modelId")) |model_val| {
                    if (model_val == .string and model_val.string.len > 0) {
                        traceResolvedModelOnce(trace.requested_model, "sse.response-metadata.modelId", model_val.string, trace.ctx);
                    }
                }
            }
        } else if (std.mem.eql(u8, event_type, "error")) {
            provider_failure_cause = provider_failure_cause orelse providerFailureCause(root);
            try captureProviderFailureDetail(alloc, &provider_failure_detail, root);
        } else if (std.mem.eql(u8, event_type, "text-delta")) {
            if (root.object.get("delta")) |delta_val| {
                if (delta_val == .string and delta_val.string.len > 0) {
                    const retained = if (content_capture_limit) |limit|
                        delta_val.string[0..@min(delta_val.string.len, limit -| content_buf.items.len)]
                    else
                        delta_val.string;
                    try content_buf.appendSlice(alloc, retained);
                    on_content_chunk(callback_ctx, delta_val.string);
                }
            }
        } else if (std.mem.eql(u8, event_type, "reasoning-delta")) {
            if (on_reasoning_chunk) |callback| {
                if (root.object.get("delta")) |delta_val| {
                    if (delta_val == .string and delta_val.string.len > 0) {
                        callback(callback_ctx, delta_val.string);
                    }
                }
            }
        } else if (std.mem.eql(u8, event_type, "tool-input-start")) {
            const id = streamedToolInputId(root, .invalid_start) orelse continue;
            const name = if (root.object.get("toolName")) |name_value|
                if (name_value == .string) name_value.string else ""
            else
                "";

            if (findStreamedToolInput(streamed_tool_inputs.items, id)) |index| {
                const existing = &streamed_tool_inputs.items[index];
                if (existing.state != .open) {
                    traceStreamStateAnomaly(.late_start);
                } else if (!std.mem.eql(u8, existing.name.items, name)) {
                    traceStreamStateAnomaly(.conflicting_start);
                }
                continue;
            }

            var record = try initStreamedToolInput(alloc, id, name);
            streamed_tool_inputs.append(alloc, record) catch |err| {
                record.deinit(alloc);
                return err;
            };
            if (name.len > 0) {
                if (on_tool_start) |cb| cb(callback_ctx, id, name, null, null);
            }
        } else if (std.mem.eql(u8, event_type, "tool-input-delta") or
            std.mem.eql(u8, event_type, "tool-input-end"))
        {
            const is_delta = std.mem.eql(u8, event_type, "tool-input-delta");
            const anomaly: StreamStateAnomaly = if (is_delta)
                .unmatched_or_late_delta
            else
                .unmatched_or_duplicate_end;
            const id = streamedToolInputId(root, anomaly) orelse continue;
            const index = findStreamedToolInput(streamed_tool_inputs.items, id) orelse {
                traceStreamStateAnomaly(anomaly);
                continue;
            };
            const record = &streamed_tool_inputs.items[index];
            if (record.state != .open) {
                traceStreamStateAnomaly(anomaly);
                continue;
            }
            if (is_delta) {
                const delta_value = root.object.get("delta") orelse continue;
                if (delta_value != .string) continue;
                try record.arguments.appendSlice(alloc, delta_value.string);
                if (on_tool_input_chunk) |callback| callback(callback_ctx, delta_value.string);
            } else {
                record.state = .ended;
            }
        } else if (std.mem.eql(u8, event_type, "tool-call")) {
            var acc: SseToolCallAccumulator = .{
                .id = .empty,
                .name = .empty,
                .arguments = .empty,
            };
            var acc_owned = true;
            defer if (acc_owned) acc.deinit(alloc);

            acc.final_identity = finalToolIdentity(root.object.get("toolCallId"));
            if (acc.final_identity == .valid) {
                try acc.id.appendSlice(alloc, root.object.get("toolCallId").?.string);
            }

            var duplicate_final_id = false;
            if (acc.final_identity == .valid) {
                for (tool_accumulators.items) |prior| {
                    if (prior.final_identity == .valid and
                        std.mem.eql(u8, prior.id.items, acc.id.items))
                    {
                        duplicate_final_id = true;
                        break;
                    }
                }
            }

            var stream_index = if (acc.final_identity == .valid)
                findStreamedToolInput(streamed_tool_inputs.items, acc.id.items)
            else
                null;

            const final_name_value = root.object.get("toolName");
            if (final_name_value) |name_val| {
                if (name_val == .string) try acc.name.appendSlice(alloc, name_val.string);
            }
            if (acc.name.items.len == 0 and final_name_value == null) {
                if (stream_index) |index| {
                    try acc.name.appendSlice(alloc, streamed_tool_inputs.items[index].name.items);
                }
            }

            var final_name_compatible = true;
            if (stream_index) |index| {
                if (final_name_value) |name_value| {
                    const record = &streamed_tool_inputs.items[index];
                    if (name_value != .string or
                        !std.mem.eql(u8, name_value.string, record.name.items))
                    {
                        final_name_compatible = false;
                        setProviderResultFailure(
                            &provider_result_identity_failure,
                            .conflicting_tool_name,
                        );
                    }
                }
            }

            const final_input_state = if (root.object.get("input")) |input_value| blk: {
                const classified = try appendSupportedFinalInput(
                    alloc,
                    &acc.arguments,
                    input_value,
                    acc.id.items,
                    acc.name.items,
                );
                acc.argument_integrity = classified.integrity;
                acc.argument_diagnostic = classified.diagnostic;
                break :blk if (classified.integrity == .valid)
                    FinalToolInputState.valid
                else
                    FinalToolInputState.malformed;
            } else FinalToolInputState.absent;
            if (stream_index == null and
                final_input_state == .valid and
                final_name_compatible and
                acc.final_identity == .valid and
                !duplicate_final_id)
            {
                stream_index = try findEquivalentEndedStreamedToolInput(
                    alloc,
                    streamed_tool_inputs.items,
                    acc.name.items,
                    acc.arguments.items,
                );
            }
            if (final_input_state == .absent and
                final_name_compatible and
                acc.final_identity == .valid and
                !duplicate_final_id)
            {
                if (stream_index) |index| {
                    const record = &streamed_tool_inputs.items[index];
                    switch (record.state) {
                        .ended => {
                            const classified = try appendSerializedToolArguments(
                                alloc,
                                &acc.arguments,
                                record.arguments.items,
                                acc.id.items,
                                acc.name.items,
                                .streamed_fallback,
                            );
                            acc.argument_integrity = classified.integrity;
                            acc.argument_diagnostic = classified.diagnostic;
                        },
                        .open => setProviderResultFailure(
                            &provider_result_identity_failure,
                            .incomplete_streamed_input,
                        ),
                        .finalized => setProviderResultFailure(
                            &provider_result_identity_failure,
                            .invalid_tool_input,
                        ),
                    }
                } else {
                    setProviderResultFailure(
                        &provider_result_identity_failure,
                        .invalid_tool_input,
                    );
                }
            }

            if (root.object.get("providerExecuted")) |provider_value| {
                if (provider_value == .bool) {
                    if (provider_value.bool) acc.provenance = .provider_executed;
                } else {
                    setProviderResultFailure(
                        &provider_result_identity_failure,
                        .malformed_provider_executed,
                    );
                }
            } else if (expected_provider_tool_name) |expected_name| {
                if (final_name_compatible and
                    std.mem.eql(u8, acc.name.items, expected_name))
                {
                    acc.provenance = .provider_executed;
                }
            }

            if (stream_index) |index| {
                const record = &streamed_tool_inputs.items[index];
                if (!std.mem.eql(u8, record.id.items, acc.id.items)) {
                    try acc.provisional_id.appendSlice(alloc, record.id.items);
                }
                if (final_name_compatible and
                    !record.label_sent and
                    acc.argument_integrity == .valid)
                {
                    if (on_tool_start) |cb| {
                        record.label_sent = true;
                        cb(callback_ctx, record.id.items, record.name.items, extractFirstJsonStringValue(acc.arguments.items), acc.arguments.items);
                    }
                }
            }

            try tool_accumulators.append(alloc, acc);
            acc_owned = false;
            if (stream_index) |index| {
                streamed_tool_inputs.items[index].state = .finalized;
            }
        } else if (std.mem.eql(u8, event_type, "tool-result")) {
            const result_identity = finalToolIdentity(root.object.get("toolCallId"));
            if (result_identity != .valid) {
                setProviderResultFailure(
                    &provider_result_identity_failure,
                    switch (result_identity) {
                        .absent => .absent,
                        .empty => .empty,
                        .wrong_type => .wrong_type,
                        .valid => unreachable,
                    },
                );
                continue;
            }

            const result_id = root.object.get("toolCallId").?.string;
            var matched_index: ?usize = null;
            var match_count: usize = 0;
            for (tool_accumulators.items, 0..) |candidate, i| {
                if (candidate.final_identity == .valid and std.mem.eql(u8, candidate.id.items, result_id)) {
                    match_count += 1;
                    matched_index = i;
                }
            }
            if (match_count != 1) {
                setProviderResultFailure(
                    &provider_result_identity_failure,
                    if (match_count == 0) .unmatched else .ambiguous,
                );
                continue;
            }

            const acc = &tool_accumulators.items[matched_index.?];
            if (acc.provenance != .provider_executed) {
                setProviderResultFailure(
                    &provider_result_identity_failure,
                    .provenance_contradiction,
                );
                continue;
            }
            if (acc.provider_result_state == .final) {
                setProviderResultFailure(
                    &provider_result_identity_failure,
                    .duplicate_result,
                );
                continue;
            }

            const preliminary = if (root.object.get("preliminary")) |preliminary_value| blk: {
                if (preliminary_value != .bool) {
                    setProviderResultFailure(
                        &provider_result_identity_failure,
                        .malformed_preliminary,
                    );
                    continue;
                }
                break :blk preliminary_value.bool;
            } else false;

            const result_value = root.object.get("result") orelse {
                setProviderResultFailure(
                    &provider_result_identity_failure,
                    .missing_result,
                );
                continue;
            };
            if (result_value == .null) {
                setProviderResultFailure(
                    &provider_result_identity_failure,
                    .missing_result,
                );
                continue;
            }

            const owned_result = try stringifyJsonValueOwned(alloc, result_value);
            if (acc.provider_result) |old_result| alloc.free(old_result);
            acc.provider_result = owned_result;
            acc.provider_result_state = if (preliminary) .preliminary else .final;
        } else if (std.mem.eql(u8, event_type, "finish")) {
            provider_failure_cause = provider_failure_cause orelse providerFailureCause(root);
            const finish_event = parseSseFinishEvent(alloc, root, &provider_failure_detail) catch |err| {
                switch (err) {
                    error.UnknownProviderFinishReason => {
                        traceSseTermination(resolved_model_trace, "invalid_finish", null);
                        return error.InvalidProviderFinishReason;
                    },
                    else => return err,
                }
            };
            finish_reason_holder = finish_event.finish_reason;
            finish_usage = finish_event.usage;
            finish_resolved_provider = parseSseResolvedProvider(alloc, root);
            finish_service_tier = parseSseServiceTier(root);
            finish_billing = parseSseBilling(
                alloc,
                root,
                if (response_timestamp_invalid) null else response_timestamp_ms,
                tool_accumulators.items,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidSseBilling => invalid: {
                    debug_trace.logf(
                        "sse",
                        "stream billing ignored reason=invalid_terminal_metadata",
                        .{},
                    );
                    break :invalid null;
                },
            };
            traceSseTermination(resolved_model_trace, "valid_finish", finish_reason_holder);
            break;
        }
    }

    var completion: types.ModelCompletion = .{};
    errdefer deinitGatewayCompletion(alloc, &completion);

    if (content_buf.items.len > 0) {
        completion.content = try content_buf.toOwnedSlice(alloc);
    }

    completion.tool_calls = try materializeToolCalls(alloc, tool_accumulators.items);
    if (finish_reason_holder == .stop or finish_reason_holder == .tool_calls) {
        completion.provider_state_json = try replay.finish(completion.content orelse "", completion.tool_calls);
    }

    completion.provider_result_identity_failure = provider_result_identity_failure;
    completion.provider_failure_cause = provider_failure_cause;
    completion.provider_failure_detail = provider_failure_detail;
    provider_failure_detail = null;
    completion.generation_id = generation_id;
    generation_id = null;
    completion.resolved_provider = finish_resolved_provider;
    finish_resolved_provider = null;
    completion.billing = finish_billing;
    finish_billing = null;
    completion.service_tier = finish_service_tier;
    completion.generation_metadata_invalid = generation_metadata_invalid;
    completion.finish_reason = finish_reason_holder;
    completion.usage = finish_usage;

    debug_trace.logf(
        "stream",
        "sse summary events={d} finish_reason={s}",
        .{
            data_event_count,
            finish_reason_label(completion.finish_reason),
        },
    );

    return completion;
}

fn finalToolIdentity(value: ?std.json.Value) types.FinalToolIdentity {
    const actual = value orelse return .absent;
    if (actual != .string) return .wrong_type;
    return if (actual.string.len == 0) .empty else .valid;
}

const LoopbackGatewayMode = enum {
    reset_on_accept,
    tls_handshake_stall,
    request_send_stall,
    response_head_stall,
    response_body_stall,
    response_body_delayed_success,
    response_body_progress,
    retry_once,
    retry_once_then_success,
    success,
    success_capture,
    model_catalog_success,
    private_model_catalog_success,
    keep_alive_reuse,
    keep_alive_close_after_response,
    reset_mid_request,
    reset_after_head_read,
    slow_terminal_chunk,
    never_terminating_body,
};

const LoopbackGatewayFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    mode: LoopbackGatewayMode,
    hold_ms: u64,
    thread: ?std.Thread = null,
    server_open: bool = true,
    accept_started: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    accepted: std.atomic.Value(bool) = .init(false),
    accepted_count: std.atomic.Value(usize) = .init(0),
    requests_served: std.atomic.Value(usize) = .init(0),
    reached_stage: std.atomic.Value(bool) = .init(false),
    request_headers: [16 * 1024]u8 = undefined,
    request_headers_len: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,

    fn init(mode: LoopbackGatewayMode, hold_ms: u64) !@This() {
        var fixture: @This() = .{
            .server = undefined,
            .mode = mode,
            .hold_ms = hold_ms,
        };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn start(self: *@This()) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *@This()) void {
        if (!self.server_open) return;

        const zio = self.io();
        self.stopping.store(true, .seq_cst);
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(zio, .both) catch {};
            self.wakeAccept();
            thread.join();
            self.thread = null;
        }
        self.server.deinit(zio);
        self.server_open = false;
    }

    fn port(self: *@This()) u16 {
        return self.server.socket.address.getPort();
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn waitForAcceptStart(self: *@This(), timeout_ms: u64) bool {
        return self.waitForSignal(&self.accept_started, timeout_ms);
    }

    fn waitForStageOrDone(self: *@This(), request_done: *std.atomic.Value(bool)) bool {
        while (!self.reached_stage.load(.seq_cst)) {
            if (request_done.load(.seq_cst) or self.stopping.load(.seq_cst)) return false;
            sleepBlocking(1);
        }
        return true;
    }

    fn waitForSignal(self: *@This(), signal: *std.atomic.Value(bool), timeout_ms: u64) bool {
        var remaining_ms = timeout_ms;
        while (remaining_ms > 0) : (remaining_ms -= 1) {
            if (signal.load(.seq_cst)) return true;
            if (self.stopping.load(.seq_cst)) return false;
            sleepBlocking(1);
        }
        return signal.load(.seq_cst);
    }

    fn wakeAccept(self: *@This()) void {
        var wake_io_backend: std.Io.Threaded = .init_single_threaded;
        const zio = wake_io_backend.io();
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
        var stream = address.connect(zio, .{
            .mode = .stream,
        }) catch return;
        stream.close(zio);
    }

    fn sleepBlocking(milliseconds: u64) void {
        var sleep_io_backend: std.Io.Threaded = .init_single_threaded;
        sleep_io_backend.io().sleep(.fromMilliseconds(@intCast(milliseconds)), .real) catch {};
    }

    fn hold(self: *@This()) void {
        var remaining_ms = self.hold_ms;
        while (remaining_ms > 0 and !self.stopping.load(.seq_cst)) {
            const sleep_ms: u64 = @min(remaining_ms, 10);
            sleepBlocking(sleep_ms);
            remaining_ms -= sleep_ms;
        }
    }

    fn markStage(self: *@This()) void {
        self.reached_stage.store(true, .seq_cst);
    }

    fn captureRequestHeaders(self: *@This(), headers: []const u8) void {
        const len = @min(headers.len, self.request_headers.len);
        @memcpy(self.request_headers[0..len], headers[0..len]);
        self.request_headers_len.store(len, .seq_cst);
    }

    fn capturedHeaderValue(self: *@This(), name: []const u8) ?[]const u8 {
        const len = self.request_headers_len.load(.seq_cst);
        if (len == 0) return null;
        return rawHeaderValue(self.request_headers[0..len], name);
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (self.stopping.load(.seq_cst) and err == error.SocketNotListening) return;
            self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        const zio = self.io();
        self.accept_started.store(true, .seq_cst);
        var stream = try self.server.accept(zio);
        defer stream.close(zio);
        if (self.stopping.load(.seq_cst)) return;
        self.accepted.store(true, .seq_cst);
        _ = self.accepted_count.fetchAdd(1, .seq_cst);

        switch (self.mode) {
            .reset_on_accept => {
                const reset_on_close: std.posix.linger = .{
                    .onoff = 1,
                    .linger = 0,
                };
                try std.posix.setsockopt(
                    stream.socket.handle,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.LINGER,
                    std.mem.asBytes(&reset_on_close),
                );
                self.markStage();
            },
            .tls_handshake_stall => {
                self.markStage();
                self.hold();
            },
            .request_send_stall => {
                const receive_buffer: c_int = 1024;
                std.posix.setsockopt(
                    stream.socket.handle,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.RCVBUF,
                    std.mem.asBytes(&receive_buffer),
                ) catch {};
                self.markStage();
                self.hold();
            },
            .response_head_stall => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                self.hold();
            },
            .response_body_stall => {
                try readLoopbackGatewayRequest(zio, stream, self);
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"type\":\"text-delta\",\"id\":\"partial\",\"delta\":\"partial\"}\n\n",
                );
                self.markStage();
                self.hold();
            },
            .response_body_delayed_success => {
                try readLoopbackGatewayRequest(zio, stream, self);
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n",
                );
                self.markStage();
                self.hold();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "data: {\"type\":\"text-delta\",\"id\":\"answer\",\"delta\":\"ok\"}\n\n" ++
                        "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\"}}\n\n",
                );
            },
            .response_body_progress => {
                try readLoopbackGatewayRequest(zio, stream, self);
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n",
                );
                self.markStage();
                for (0..30) |_| {
                    if (self.stopping.load(.seq_cst)) return;
                    writeLoopbackGatewayBytes(zio, stream, ": progress\n\n") catch return;
                    sleepBlocking(20);
                }
                self.hold();
            },
            .retry_once => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 503 Service Unavailable\r\n" ++
                        "Content-Length: 0\r\n" ++
                        "Connection: close\r\n\r\n",
                );
            },
            .retry_once_then_success => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 503 Service Unavailable\r\n" ++
                        "Content-Length: 0\r\n" ++
                        "Connection: close\r\n\r\n",
                );

                var recovered_stream = try self.server.accept(zio);
                defer recovered_stream.close(zio);
                _ = self.accepted_count.fetchAdd(1, .seq_cst);
                try readLoopbackGatewayRequest(zio, recovered_stream, self);
                try writeLoopbackGatewayBytes(
                    zio,
                    recovered_stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"type\":\"text-delta\",\"id\":\"answer\",\"delta\":\"ok\"}\n\n" ++
                        "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\"}}\n\n",
                );
            },
            .success => {
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"type\":\"text-delta\",\"id\":\"answer\",\"delta\":\"ok\"}\n\n" ++
                        "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\"}}\n\n",
                );
                self.hold();
            },
            .success_capture => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"type\":\"text-delta\",\"id\":\"answer\",\"delta\":\"ok\"}\n\n" ++
                        "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\"}}\n\n",
                );
            },
            .model_catalog_success => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: application/json\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        loopback_model_catalog_json,
                );
            },
            .private_model_catalog_success => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: application/json\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        loopback_private_model_catalog_json,
                );
            },
            .keep_alive_reuse => {
                self.markStage();
                self.serveKeepAliveLoop(zio, stream);
            },
            .keep_alive_close_after_response => {
                self.markStage();
                // Serve once, then drop the connection without a
                // Connection: close header, simulating an edge idle timeout:
                // the client pools the dead connection and discovers it on
                // the next borrow.
                self.serveKeepAliveOnce(zio, stream);
                stream.shutdown(zio, .both) catch {};
                var recovered = try self.server.accept(zio);
                defer recovered.close(zio);
                _ = self.accepted_count.fetchAdd(1, .seq_cst);
                self.serveKeepAliveOnce(zio, recovered);
            },
            .reset_mid_request => {
                // Read one byte, then RST: the client fails mid-send or at
                // head read; either way the connection must not be pooled.
                var one: [1]u8 = undefined;
                var reader = stream.reader(zio, &one);
                _ = reader.interface.takeByte() catch {};
                const rst: std.posix.linger = .{ .onoff = 1, .linger = 0 };
                try std.posix.setsockopt(
                    stream.socket.handle,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.LINGER,
                    std.mem.asBytes(&rst),
                );
                self.markStage();
            },
            .reset_after_head_read => {
                // Read only the request head, wait for the client to block
                // mid-body against full kernel buffers, then RST: the client
                // fails inside the send path, and the connection must never
                // reach the pool.
                var socket_buffer: [4096]u8 = undefined;
                var reader = stream.reader(zio, &socket_buffer);
                var header_buf: [512]u8 = undefined;
                var header_len: usize = 0;
                while (header_len < header_buf.len) {
                    header_buf[header_len] = reader.interface.takeByte() catch break;
                    header_len += 1;
                    if (std.mem.endsWith(u8, header_buf[0..header_len], "\r\n\r\n")) break;
                }
                sleepBlocking(200);
                const rst: std.posix.linger = .{ .onoff = 1, .linger = 0 };
                try std.posix.setsockopt(
                    stream.socket.handle,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.LINGER,
                    std.mem.asBytes(&rst),
                );
                self.markStage();
            },
            .slow_terminal_chunk => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                var frame_buf: [512]u8 = undefined;
                const partial = try std.mem.print(
                    &frame_buf,
                    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n",
                    .{ keep_alive_sse_payload.len, keep_alive_sse_payload },
                );
                try writeLoopbackGatewayBytes(zio, stream, partial);
                self.hold();
                try writeLoopbackGatewayBytes(zio, stream, "0\r\n\r\n");
            },
            .never_terminating_body => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                var frame_buf: [512]u8 = undefined;
                const partial = try std.mem.print(
                    &frame_buf,
                    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n",
                    .{ keep_alive_sse_payload.len, keep_alive_sse_payload },
                );
                try writeLoopbackGatewayBytes(zio, stream, partial);
                // The terminal chunk never comes; keep the body open with
                // one-byte chunks until teardown.
                while (!self.stopping.load(.seq_cst)) {
                    writeLoopbackGatewayBytes(zio, stream, "1\r\n:\r\n") catch return;
                    sleepBlocking(50);
                }
            },
        }
    }

    fn serveKeepAliveLoop(self: *@This(), zio: std.Io, stream: std.Io.net.Stream) void {
        var socket_buffer: [4096]u8 = undefined;
        var reader = stream.reader(zio, &socket_buffer);
        while (!self.stopping.load(.seq_cst)) {
            readKeepAliveRequest(&reader.interface) catch return;
            _ = self.requests_served.fetchAdd(1, .seq_cst);
            writeKeepAliveResponse(zio, stream) catch return;
        }
    }

    fn serveKeepAliveOnce(self: *@This(), zio: std.Io, stream: std.Io.net.Stream) void {
        var socket_buffer: [4096]u8 = undefined;
        var reader = stream.reader(zio, &socket_buffer);
        readKeepAliveRequest(&reader.interface) catch return;
        _ = self.requests_served.fetchAdd(1, .seq_cst);
        writeKeepAliveResponse(zio, stream) catch return;
    }
};

const loopback_model_catalog_json =
    "{\"data\":[{\"id\":\"openai/gpt-5\",\"type\":\"language\",\"tags\":[\"reasoning\",\"tool-use\",\"vision\",\"file-input\",\"web-search\",\"explicit-caching\",\"implicit-caching\"],\"context_window\":256000,\"max_tokens\":32000},{\"id\":\"anthropic/claude-opus-4\",\"type\":\"language\",\"tags\":[\"tool-use\"],\"context_window\":200000},{\"id\":\"anthropic/claude-sonnet-4\",\"type\":\"language\",\"tags\":[\"tool-use\"],\"context_window\":200000}]}";

const loopback_private_model_catalog_json =
    "{\"data\":[{\"id\":\"openai/gpt-5\",\"type\":\"language\",\"tags\":[\"reasoning\",\"tool-use\",\"vision\",\"file-input\",\"web-search\",\"explicit-caching\",\"implicit-caching\"],\"context_window\":256000,\"max_tokens\":32000},{\"id\":\"anthropic/claude-opus-4\",\"type\":\"language\",\"tags\":[\"tool-use\"],\"context_window\":200000},{\"id\":\"anthropic/claude-sonnet-4\",\"type\":\"language\",\"tags\":[\"tool-use\"],\"context_window\":200000},{\"id\":\"private/blue-hornbill\",\"type\":\"language\",\"tags\":[\"tool-use\"],\"context_window\":200000}]}";

pub const TestModelCatalogFixture = struct {
    fixture: LoopbackGatewayFixture,

    pub fn init() !@This() {
        return .{ .fixture = try LoopbackGatewayFixture.init(.model_catalog_success, 0) };
    }

    pub fn initPrivate() !@This() {
        return .{ .fixture = try LoopbackGatewayFixture.init(.private_model_catalog_success, 0) };
    }

    pub fn start(self: *@This()) !void {
        try self.fixture.start();
    }

    pub fn deinit(self: *@This()) void {
        self.fixture.deinit();
    }

    pub fn port(self: *@This()) u16 {
        return self.fixture.port();
    }

    pub fn waitForAcceptStart(self: *@This(), timeout_ms: u64) bool {
        return self.fixture.waitForAcceptStart(timeout_ms);
    }

    pub fn failure(self: *@This()) ?anyerror {
        return self.fixture.failure;
    }

    pub fn capturedHeaderValue(self: *@This(), name: []const u8) ?[]const u8 {
        return self.fixture.capturedHeaderValue(name);
    }
};

fn readLoopbackGatewayRequest(zio: std.Io, stream: std.Io.net.Stream, fixture: *LoopbackGatewayFixture) !void {
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(zio, &socket_buffer);
    var request: [16 * 1024]u8 = undefined;
    var header_len: usize = 0;

    while (header_len < request.len) {
        request[header_len] = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.TestRequestClosedEarly,
            else => return err,
        };
        header_len += 1;
        if (!std.mem.endsWith(u8, request[0..header_len], "\r\n\r\n")) continue;

        const headers = request[0 .. header_len - 4];
        fixture.captureRequestHeaders(headers);
        if (loopbackContentLength(headers)) |content_length| {
            reader.interface.discardAll(content_length) catch |err| switch (err) {
                error.EndOfStream => return error.TestRequestClosedEarly,
                else => return err,
            };
        }
        return;
    }

    return error.TestRequestTooLarge;
}

fn rawHeaderValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon_index = std.mem.findScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon_index], " \t");
        if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
        return std.mem.trim(u8, line[colon_index + 1 ..], " \t");
    }
    return null;
}

const keep_alive_sse_payload =
    "data: {\"type\":\"text-delta\",\"id\":\"answer\",\"delta\":\"ok\"}\n\n" ++
    "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\"}}\n\n";

/// Larger than the client's transfer buffer, so it cannot all be read ahead
/// while the terminal SSE event is parsed.
const keep_alive_padding = text_utils.repeat(":", 66 * 1024);

fn readKeepAliveRequest(reader: *std.Io.Reader) !void {
    var header_buf: [16 * 1024]u8 = undefined;
    var header_len: usize = 0;
    while (header_len < header_buf.len) {
        header_buf[header_len] = try reader.takeByte();
        header_len += 1;
        if (std.mem.endsWith(u8, header_buf[0..header_len], "\r\n\r\n")) break;
    } else {
        return error.TestRequestTooLarge;
    }
    if (loopbackContentLength(header_buf[0 .. header_len - 4])) |content_length| {
        try reader.discardAll(content_length);
    }
}

fn writeKeepAliveResponse(zio: std.Io, stream: std.Io.net.Stream) !void {
    var head_buf: [512]u8 = undefined;
    const head_events = try std.mem.print(
        &head_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n",
        .{ keep_alive_sse_payload.len, keep_alive_sse_payload },
    );
    try writeLoopbackGatewayBytes(zio, stream, head_events);
    // Trailing padding arrives late and exceeds the client's transfer
    // buffer, so the body is provably unread when SSE consumption finishes:
    // only the client-side drain can return this connection to the pool.
    io_mod.sleep(150 * std.time.ns_per_ms);
    var tail_head_buf: [64]u8 = undefined;
    const tail_head = try std.mem.print(&tail_head_buf, "{x}\r\n", .{keep_alive_padding.len});
    try writeLoopbackGatewayBytes(zio, stream, tail_head);
    try writeLoopbackGatewayBytes(zio, stream, keep_alive_padding);
    try writeLoopbackGatewayBytes(zio, stream, "\r\n0\r\n\r\n");
}

fn loopbackContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const name = "content-length:";
        if (line.len < name.len or !std.ascii.eqlIgnoreCase(line[0..name.len], name)) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[name.len..], " \t"), 10) catch null;
    }
    return null;
}

fn writeLoopbackGatewayBytes(zio: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(zio, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

const std = @import("std");
const debug_trace = @import("../core/shared/debug_trace.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const grok_session = @import("../core/auth/grok_session.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const responses_protocol = @import("responses_protocol.zig");
const sse_stream = @import("sse.zig");

const Allocator = std.mem.Allocator;
const endpoint = "https://cli-chat-proxy.grok.com/v1/responses";
// The proxy gates this as Grok wire compatibility; fx identifies itself separately below.
const version_lookup = @import("provider_versions.zig");
const e2e_endpoint_env = "FX_E2E_XAI_GROK_RESPONSES_URL";
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const max_provider_state_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
    .build_request_fn = buildRequestForProvider,
    .project_replay_fn = responses_protocol.selectReplayParts,
};

/// Rejects a model id that could not travel in a request header.
pub fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 256) return error.InvalidXaiGrokModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidXaiGrokModel;
    }
}

pub fn buildRequest(
    alloc: Allocator,
    request: stream_provider.RequestData,
) ![]u8 {
    try request.validatePrompt();
    try validateModel(request.model);
    const budget: image_attachments.CaptureBudget = if (request.budget) |value|
        .{ .deadline = value.deadline, .cancel_flag = value.cancel_flag }
    else
        .{};
    try budget.check();
    const projected = try types.projectProviderReplay(alloc, request.messages, .{ .provider = .grok, .model = request.model });
    defer if (projected) |messages| alloc.free(messages);
    if (projected != null) debug_trace.logf("gateway", "provider_replay_omitted provider=grok reason=source_mismatch", .{});

    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    for (request.instructions) |instruction| {
        const text = instruction.content.?;
        if (text.len == 0) continue;
        if (instructions.written().len > 0) try instructions.writer.writeAll("\n\n");
        try instructions.writer.writeAll(text);
    }
    if (instructions.written().len == 0) try instructions.writer.writeAll("You are a helpful assistant.");

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"store\":false,\"stream\":true,\"instructions\":");
    try std.json.Stringify.value(instructions.written(), .{}, writer);
    try writer.writeAll(",\"input\":[");
    try writeResponsesInput(writer, std.heap.c_allocator, projected orelse request.messages, request.verified_images, budget);
    try writer.writeByte(']');

    const tool_count = try responses_protocol.writeTools(writer, alloc, request.tools);
    if (tool_count > 0) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
        try writer.writeAll(",\"parallel_tool_calls\":true");
    }
    try writer.writeAll(",\"include\":[\"reasoning.encrypted_content\"]");
    try writer.writeAll(",\"text\":{\"verbosity\":\"low\"");
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"format\":{\"type\":\"json_schema\",\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll(",\"strict\":true}");
    }
    try writer.writeByte('}');

    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
        try writer.writeAll(",\"summary\":\"auto\"}");
    }
    // xAI exposes Fast mode as its priority service tier; the subscription
    // proxy accepts the parameter endpoint-wide, independent of the model.
    if (request.provider_options.fast) try writer.writeAll(",\"service_tier\":\"priority\"");
    if (request.max_output_tokens) |limit| try writer.print(",\"max_output_tokens\":{d}", .{limit});
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn buildRequestForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.RequestData,
) anyerror![]u8 {
    return buildRequest(alloc, request);
}

fn writeResponsesInput(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    images: ?[]const image_attachments.VerifiedSnapshot,
    budget: image_attachments.CaptureBudget,
) !void {
    return responses_protocol.writeInput(writer, alloc, messages, images, .{
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    }, budget) catch |err| switch (err) {
        error.ProviderStateTooLarge => error.XaiGrokProviderStateTooLarge,
        error.InvalidProviderState => error.InvalidXaiGrokProviderState,
        error.ToolCallLimitExceeded => error.XaiGrokToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.XaiGrokToolArgumentsTooLarge,
        else => err,
    };
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    if (!acceptsCredential(request.credential)) {
        return stream_provider.failResult(error.GrokSubscriptionCredentialRequired);
    }
    if (request.credential.credentialSource() != .host_managed) {
        const account_id = request.credential.accountId() orelse
            return stream_provider.failResult(error.GrokSubscriptionAccountRequired);
        if (!grok_session.validAccountId(account_id)) {
            return stream_provider.failResult(error.InvalidGrokSubscriptionAccount);
        }
    }
    try validateModel(request.model);
    const payload = request.prepared_request_body orelse
        try buildRequest(alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    var result = streamPrepared(alloc, request, payload) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
        if (requestDeadlineExpired(request)) return stream_provider.failResult(error.Timeout);
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
    if (requestDeadlineExpired(request)) {
        result.deinit(alloc);
        return stream_provider.failResult(error.Timeout);
    }
    return result;
}

fn requestDeadlineExpired(request: stream_provider.ModelRequest) bool {
    const deadline = request.deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

/// True for the credentials a Grok request may use: a Grok subscription, or a
/// host that authorizes the request itself.
pub fn acceptsCredential(lease: stream_provider.CredentialLease) bool {
    const source = lease.credentialSource() orelse return false;
    return source == .grok_subscription or source == .host_managed;
}

/// The Responses endpoint, or a loopback test endpoint from the environment.
/// Borrowed; static or environment-owned.
pub fn responsesEndpoint() error{InvalidE2EXaiGrokEndpoint}![]const u8 {
    const override = io_mod.getenv(e2e_endpoint_env) orelse return endpoint;
    if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EXaiGrokEndpoint;
    return override;
}

pub const max_extra_headers = 8;

pub const HeaderOptions = struct {
    /// Sends the subscription proxy's token-auth headers.
    subscription: bool,
    client_version: ?[]const u8 = null,
    /// Omitted when the host adds the account along with its credentials.
    account_id: ?[]const u8 = null,
    model: []const u8,
    session_id: ?[]const u8 = null,
};

/// Writes the Grok headers other than authorization and content type into
/// `buf` and returns the used prefix. Values are borrowed from `options`.
pub fn extraHeaders(buf: *[max_extra_headers]std.http.Header, options: HeaderOptions) []std.http.Header {
    var count: usize = 0;
    buf[count] = .{ .name = "accept", .value = "text/event-stream" };
    count += 1;
    if (options.subscription) {
        buf[count] = .{ .name = "X-XAI-Token-Auth", .value = "xai-grok-cli" };
        count += 1;
        buf[count] = .{ .name = "x-authenticateresponse", .value = "authenticate-response" };
        count += 1;
    }
    if (options.client_version) |version| {
        buf[count] = .{ .name = "x-grok-client-version", .value = version };
        count += 1;
    }
    buf[count] = .{ .name = "x-grok-client-identifier", .value = "fx" };
    count += 1;
    buf[count] = .{ .name = "x-grok-model-override", .value = options.model };
    count += 1;
    if (options.account_id) |account_id| {
        buf[count] = .{ .name = "x-grok-user-id", .value = account_id };
        count += 1;
    }
    if (options.session_id) |session_id| if (session_id.len > 0) {
        buf[count] = .{ .name = "x-grok-conv-id", .value = session_id };
        count += 1;
    };
    return buf[0..count];
}

const RequestAuthHeaders = struct {
    authorization: ?[]u8 = null,
    account_id: ?[]const u8 = null,
    include_subscription_headers: bool = false,

    fn deinit(self: *RequestAuthHeaders, alloc: Allocator) void {
        if (self.authorization) |value| secret.zeroAndFree(alloc, value);
        self.* = .{};
    }
};

fn requestAuthHeaders(alloc: Allocator, auth: stream_provider.CredentialLease) !RequestAuthHeaders {
    return switch (auth) {
        .host_managed => .{},
        .direct => |direct| .{
            .authorization = try alloc.print("Bearer {s}", .{direct.secret_bytes}),
            .account_id = direct.account_id,
            .include_subscription_headers = true,
        },
    };
}

pub fn streamPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    var auth_headers = try requestAuthHeaders(alloc, request.credential);
    defer auth_headers.deinit(alloc);
    const request_endpoint = responsesEndpoint() catch |err| return stream_provider.failResult(err);
    const uri = try std.Uri.parse(request_endpoint);
    const compatibility = if (auth_headers.include_subscription_headers)
        try version_lookup.resolve(alloc, .grok, request.cancel_flag, request.deadline)
    else
        null;

    var extra_headers_buf: [max_extra_headers]std.http.Header = undefined;
    const extra_headers = extraHeaders(&extra_headers_buf, .{
        .subscription = auth_headers.include_subscription_headers,
        .client_version = if (compatibility) |*version| version.slice() else null,
        .account_id = auth_headers.account_id,
        .model = request.model,
        .session_id = request.session_id,
    });

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = gateway_client.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = auth_headers.authorization,
        .extra_headers = extra_headers,
    };
    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    if (request.deadline) |deadline| {
        if (std.Io.Clock.Timestamp.compare(deadline, .lt, connect_deadline)) {
            connect_deadline = deadline;
        }
    }
    try request.admission.admit();
    var opened = try gateway_client.openBoundedPost(
        alloc,
        request.cancel_flag,
        connect_deadline,
        &open_operation,
    );
    var http_request = opened.take();
    defer http_request.deinit();
    var cancel_watch: gateway_client.CancelWatch = .{};
    defer cancel_watch.stop();
    if (http_request.connection) |connection|
        try cancel_watch.start(request.cancel_flag, request.deadline, connection.stream_writer.stream);
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const bounded_body = reader.allocRemaining(alloc, .limited(max_error_body_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "xAI Grok error response exceeded the local limit"),
            else => return err,
        };
        const body = if (bounded_body.len > max_error_body_bytes) body: {
            alloc.free(bounded_body);
            break :body try alloc.dupe(u8, "xAI Grok error response exceeded the local limit");
        } else bounded_body;
        return .{ .failed = .{
            .kind = failureKind(response.head.status),
            .detail = body,
            .ownership = .owned,
        } };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    return completeFromStream(alloc, request, response.reader(&transfer_buffer));
}

/// Parses one successful Grok event stream into a completion with its
/// subscription usage. The result owns the completion.
pub fn completeFromStream(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    reader: *std.Io.Reader,
) !stream_provider.Result {
    var events = request.events;
    var completion = try consumeSse(
        alloc,
        reader,
        &events,
        EventBridge.content,
        EventBridge.toolStart,
        EventBridge.reasoning,
        EventBridge.toolInput,
        request.cancel_flag,
        request.content_capture_limit,
    );
    errdefer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = completion,
            .ownership = .owned,
        } };
        owned.deinit(alloc);
    }
    const usage_outcome: stream_provider.UsageOutcome = usage: {
        if (completion.generation_id == null) {
            break :usage .{ .unavailable = .possibly_billed };
        }
        completion.billing = try responses_protocol.buildSubscriptionBilling(
            alloc,
            .grok,
            request.model,
            @max(io_mod.milliTimestamp(), 0),
            completion.usage,
        ) orelse break :usage .{ .unavailable = .possibly_billed };
        break :usage .{ .exact = .grok };
    };
    return .{ .completed = .{
        .completion = completion,
        .usage = usage_outcome,
        .ownership = .owned,
    } };
}

const EventBridge = struct {
    fn sink(raw: *anyopaque) *stream_provider.EventSink {
        return @ptrCast(@alignCast(raw));
    }

    fn content(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .content_delta = chunk });
    }

    fn reasoning(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .reasoning_delta = chunk });
    }

    fn toolInput(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .tool_input_delta = chunk });
    }

    fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8, arguments_json: ?[]const u8) void {
        sink(raw).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label, .arguments_json = arguments_json } });
    }
};

pub fn failureKind(status: std.http.Status) stream_provider.FailureKind {
    return switch (status) {
        .bad_request => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

fn consumeSse(
    alloc: Allocator,
    reader: *std.Io.Reader,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.ModelCompletion {
    var reducer = responses_protocol.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var sse: sse_stream.Reader = .{ .max_event_bytes = max_sse_line_bytes, .max_total_bytes = max_sse_aggregate_bytes };
    defer sse.deinit(alloc);
    const callbacks = responses_protocol.StreamCallbacks{
        .context = callback_ctx,
        .on_content = on_content_chunk,
        .on_tool_start = on_tool_start,
        .on_reasoning = on_reasoning_chunk,
        .on_tool_input = on_tool_input_chunk,
    };
    const stream_limits = responses_protocol.StreamLimits{
        .aggregate_bytes = max_sse_aggregate_bytes,
        .count_json_bytes = false,
        .events = max_sse_events,
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    };
    while (sse.next(alloc, reader, cancel_flag) catch |err| return mapReducerError(err)) |json_text| {
        if (std.mem.eql(u8, json_text, "[DONE]")) break;
        if (reducer.applyJson(
            alloc,
            json_text,
            callbacks,
            cancel_flag,
            content_capture_limit,
            stream_limits,
        ) catch |err| return mapReducerError(err)) break;
    }
    return reducer.finish(alloc, cancel_flag, stream_limits) catch |err|
        return mapReducerError(err);
}

fn mapReducerError(err: anyerror) anyerror {
    return switch (err) {
        error.EventTooLarge => error.XaiGrokSseEventTooLarge,
        error.StreamTooLarge => error.XaiGrokResourceLimitExceeded,
        error.InvalidEvent => error.InvalidXaiGrokSseEvent,
        error.StreamIncomplete => error.XaiGrokStreamIncomplete,
        error.ToolCallLimitExceeded => error.XaiGrokToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.XaiGrokToolArgumentsTooLarge,
        error.ResourceLimitExceeded => error.XaiGrokResourceLimitExceeded,
        else => err,
    };
}

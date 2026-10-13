const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const types = @import("../../shared/types.zig");
const session_usage = @import("../../session/session_usage.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const io_mod = @import("../../shared/io.zig");
const runtime_telemetry = @import("telemetry.zig");

const Allocator = std.mem.Allocator;
const TraceContext = debug_trace.TraceContext;

pub const DeliveryCertainty = agent_stream_provider.DeliveryCertainty;
pub const AttemptEvidence = agent_stream_provider.AttemptEvidence;

pub const StreamResult = agent_stream_provider.Result;

const InvocationAdmission = struct {
    usage: ?*session_usage.Usage,
    attempt_evidence: *AttemptEvidence,
    trace_ctx: TraceContext,
    model: []const u8,
    caller_admission: agent_stream_provider.Admission,
    observation: ?session_usage.InvocationObservation = null,

    fn admit(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.observation != null) return error.ProviderAdmissionRepeated;
        self.observation = try session_usage.InvocationObservation.begin(self.usage);
        if (self.caller_admission.admit_fn != null) {
            try self.caller_admission.admit();
        }
        self.attempt_evidence.provider_admitted = true;
        debug_trace.eventf(
            "agent",
            "provider_admitted",
            self.trace_ctx,
            "model={s}",
            .{self.model},
        );
    }
};

pub fn streamModelCompletion(
    provider: agent_stream_provider.Provider,
    alloc: Allocator,
    request_value: agent_stream_provider.ModelRequest,
    usage: ?*session_usage.Usage,
    usage_allocator: Allocator,
) !StreamResult {
    if (request_value.cancel_flag.load(.seq_cst)) {
        return agent_stream_provider.failResult(error.Cancelled);
    }
    const started_at_ms = io_mod.milliTimestamp();
    var admission = InvocationAdmission{
        .usage = usage,
        .attempt_evidence = request_value.attempt_evidence,
        .trace_ctx = request_value.trace_ctx,
        .model = request_value.model,
        .caller_admission = request_value.admission,
    };
    var request = request_value;
    request.admission = .{ .context = &admission, .admit_fn = InvocationAdmission.admit };
    // Only the owned result escapes. HTTP and parser scratch is released after
    // every attempt, including transport failure and cancellation.
    var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch.deinit();
    const request_alloc = scratch.allocator();
    var result = provider.stream(request_alloc, request) catch |err| {
        runtime_telemetry.recordGatewayCallMetric(request.model, started_at_ms, 0, 0, 0, 0, request.trace_ctx.turn_id, request.trace_ctx.step_id, request.trace_ctx.subagent_id, @errorName(err), "");
        if (admission.observation) |observation| try observation.fail(
            if (request.delivery.load() == .possibly_sent) .ambiguous_delivery else .unbilled,
        );
        return err;
    };
    defer result.deinit(request_alloc);
    const observation = admission.observation orelse
        return agent_stream_provider.failResult(error.ProviderAdmissionMissing);

    recordProviderResultMetric(request.model, started_at_ms, result, request.trace_ctx);
    switch (result) {
        .failed => try observation.fail(.unbilled),
        .completed => |completed| {
            try observation.complete(
                usage_allocator,
                completed.completion,
                completed.usage,
            );
            {
                if (std.meta.activeTag(completed.usage) == .deferred) if (usage) |ledger| {
                    if (request.credential.secret()) |credential| {
                        ledger.startDeferredReconciliation(
                            usage_allocator,
                            completed.usage.deferred,
                            credential,
                        );
                    } else if (request.credential.credentialSource() == .host_managed) {
                        ledger.startHostManagedDeferredReconciliation(
                            usage_allocator,
                            completed.usage.deferred,
                        );
                    }
                };
            }
        },
    }
    return switch (result) {
        .completed => |value| if (value.ownership == .borrowed) result else try result.dupe(alloc),
        .failed => |value| if (value.ownership == .borrowed) result else try result.dupe(alloc),
    };
}

fn recordProviderResultMetric(
    model: []const u8,
    started_at_ms: i64,
    result: agent_stream_provider.Result,
    trace_ctx: TraceContext,
) void {
    const completion: types.ModelCompletion = switch (result) {
        .completed => |value| value.completion,
        .failed => .{},
    };
    const failure = switch (result) {
        .completed => null,
        .failed => |value| value,
    };
    var response_bytes: u64 = 0;
    if (completion.content) |content| response_bytes += content.len;
    if (completion.provider_state_json) |state| response_bytes += state.len;
    for (completion.tool_calls) |call| {
        response_bytes += call.id.len + call.name.len + call.arguments_json.len;
        if (call.provider_result) |pr| response_bytes += pr.len;
    }
    if (failure) |value| {
        if (value.detail) |detail| response_bytes += detail.len;
    }
    const truncated_bytes: u32 = @intCast(@min(response_bytes, std.math.maxInt(u32)));
    const input_tokens = clampTokenCount(completion.usage.input_tokens);
    const output_tokens = clampTokenCount(completion.usage.output_tokens);
    const terminal_stop_reason = if (completion.finish_reason) |reason| reason.label() else "";

    runtime_telemetry.recordGatewayCallMetricWithDiagnostics(
        model,
        started_at_ms,
        if (failure) |value| failureMetricCode(value.kind) else 200,
        truncated_bytes,
        input_tokens,
        output_tokens,
        trace_ctx.turn_id,
        trace_ctx.step_id,
        trace_ctx.subagent_id,
        "",
        terminal_stop_reason,
        .{
            .schema = if (failure) |value| value.diagnostics.schema orelse "" else "",
            .request_shape = if (failure) |value| value.diagnostics.request_shape orelse "" else "",
        },
    );
}

fn failureMetricCode(kind: agent_stream_provider.FailureKind) u16 {
    return switch (kind) {
        .invalid_request => 400,
        .unauthorized => 401,
        .forbidden => 403,
        .request_too_large => 413,
        .rate_limited => 429,
        .server_error => 500,
        .bad_gateway => 502,
        .unavailable => 503,
        .gateway_timeout => 504,
        .provider_error => 520,
    };
}

fn clampTokenCount(value: ?u64) u32 {
    const t = value orelse return 0;
    return @intCast(@min(t, std.math.maxInt(u32)));
}

pub const VisionToolMode = agent_stream_provider.VisionMode;

pub const ToolImageProjection = struct {
    messages: []const types.ChatMessage,
    /// True when at least one stored tool image was withheld from the request.
    stripped: bool,
};

/// Projects stored tool images into the request only when the model accepts
/// inline image input. Otherwise the images stay in the session image store
/// and the tool message explains exactly why they were withheld and what the
/// model can do instead, so the next step is never a dead end.
pub fn projectToolImageMessages(
    alloc: Allocator,
    messages: []const types.ChatMessage,
    image_input_support: model_capabilities.ImageInputSupport,
    vision_fallback_available: bool,
    text_limit: usize,
) !ToolImageProjection {
    if (image_input_support == .native) return .{ .messages = messages, .stripped = false };
    const has_images = for (messages) |message| {
        if (message.tool_result_memory) |memory| if (memory.tool_images.len > 0 or memory.tool_image_handle != null) break true;
    } else false;
    if (!has_images) return .{ .messages = messages, .stripped = false };
    const notice: []const u8 = switch (image_input_support) {
        .native => unreachable,
        .non_native => if (vision_fallback_available)
            "[Tool images were retained but not sent: this model receives image input through the vision tool, not inline. Call vision with the image file's local path to inspect it.]\n"
        else
            "[Tool images were retained but not sent: this model does not accept inline images and no vision fallback is available. Ask the user to attach the image directly or switch to a vision-capable model.]\n",
        .unknown => "[Tool images were retained but not sent: fx could not confirm image input support for this model (the model is not listed in the model catalog, or the catalog is unavailable). This can recover later in the session, so a retry may succeed; otherwise ask the user to attach the image directly.]\n",
    };
    const projected = try alloc.dupe(types.ChatMessage, messages);
    for (projected) |*message| {
        if (message.tool_result_memory) |*memory| {
            if (memory.tool_images.len == 0 and memory.tool_image_handle == null) continue;
            memory.tool_images = &.{};
            const content = message.content orelse "";
            const keep = @import("../../config/context_limits.zig").utf8PrefixLength(content, text_limit -| notice.len);
            memory.truncated = memory.truncated or keep < content.len;
            message.content = try std.mem.concat(alloc, u8, &.{ notice[0..@min(notice.len, text_limit)], content[0..keep] });
        }
    }
    return .{ .messages = projected, .stripped = true };
}

pub fn gatewayHttpErrorDetail(
    alloc: Allocator,
    status: std.http.Status,
    detail: []const u8,
    model: []const u8,
    capabilities: model_capabilities.Capabilities,
) ![]const u8 {
    if (@backingInt(status) != 413) return detail;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (detail.len > 0) try out.writer.print("{s}\n\n", .{detail});
    try out.writer.print("prompt_too_long=true\nmodel={s}\n", .{model});
    if (capabilities.context_window) |context_window| {
        try out.writer.print("context_window_tokens={d}\n", .{context_window});
    }
    if (capabilities.max_output_tokens) |max_output_tokens| {
        try out.writer.print("max_output_tokens={d}\n", .{max_output_tokens});
    }
    try out.writer.writeAll("Provider rejected the prompt as too large. Latest local tool evidence remains in session history/result handles; no local tool actions were replayed.");
    return out.toOwnedSlice();
}

const std = @import("std");
const gateway_client = @import("../../gateway/client.zig");
const permission_auto_classifier = @import("../../core/permissions/auto_classifier.zig");
const session_usage = @import("../../core/session/session_usage.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");
const stream_provider = @import("../../core/agent/stream_provider.zig");
const credential_authority = @import("../../core/auth/credential_authority.zig");
const vercel_protocol = @import("../../gateway/vercel_protocol.zig");
const typesafe_permission_reviewer = @import("typesafe_permission_reviewer.zig");

const Allocator = std.mem.Allocator;

const single_transport_attempt: usize = 1;
const reviewer_model = "openai/gpt-5.6-luna";

const StreamFn = *const fn (
    *anyopaque,
    Allocator,
    []const u8,
    ?[]const u8,
    []const u8,
    usize,
    []const u8,
    []const u8,
    std.Io.Clock.Timestamp,
    *gateway_client.DeliveryCertainty,
    *std.atomic.Value(bool),
) anyerror!gateway_client.StreamResult;

var default_stream_ctx: u8 = 0;

const GatewayConfig = struct {
    api_key: ?[]const u8,
    credential_source: ?types.CredentialSource = null,
    team: ?[]const u8 = null,
    chat_url: []const u8,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    stream_ctx: *anyopaque = @ptrCast(&default_stream_ctx),
    stream_fn: StreamFn = streamGatewayReviewer,
};

pub const provider = permission_auto_classifier.Provider{ .review_fn = reviewGateway };

fn reviewGateway(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) anyerror!permission_auto_classifier.ParseOutcome {
    // The review_model setting (or FX_REVIEW_MODEL) overrides the reviewer
    // model. typesafeai/jev selects the TypeSafe System One reviewer; any
    // other value stays on this gateway chat path with that model id. Every
    // composition site selects this provider, so the override covers
    // interactive, ask, and subagent reviews uniformly.
    const selected = if (input.reviewer_model.len > 0) input.reviewer_model else reviewer_model;
    if (typesafe_permission_reviewer.isJevModelId(selected)) {
        debug_trace.logf("permission", "event=auto_review_provider_selected provider={s}", .{typesafe_permission_reviewer.review_model_id});
        return typesafe_permission_reviewer.review(null, alloc, input, request);
    }
    return reviewGatewayConfig(.{
        .api_key = if (input.credential_source == .host_managed) null else input.credential,
        .credential_source = input.credential_source,
        .team = input.tenant,
        .chat_url = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .usage = input.usage,
        .usage_allocator = input.usage_allocator,
    }, alloc, request, selected);
}

fn reviewGatewayConfig(
    config: GatewayConfig,
    alloc: Allocator,
    request: permission_auto_classifier.ReviewRequest,
    model: []const u8,
) !permission_auto_classifier.ParseOutcome {
    var local = config;
    return permission_auto_classifier.Reviewer.withTransportModel(
        .{
            .context = @ptrCast(&local),
            .send_fn = sendGatewayReview,
            .build_fn = buildGatewayReview,
        },
        local.cancel_flag,
        permission_auto_classifier.Reviewer.default_timeout_ms,
        model,
    ).review(alloc, request);
}

fn buildGatewayReview(
    _: *anyopaque,
    alloc: Allocator,
    _: []const u8,
    tools_json: []const u8,
    instructions: []const types.ChatMessage,
    messages: []const types.ChatMessage,
    target_call_id: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) ![]u8 {
    return vercel_protocol.buildGatewayPendingToolReviewRequestBodyWithMaxOutputTokens(
        alloc,
        tools_json,
        instructions,
        messages,
        target_call_id,
        .{},
        2048,
        deadline,
        cancel_flag,
    );
}

const OwnedStream = struct {
    stream: gateway_client.StreamResult,
};

fn deinitOwnedStream(raw_ctx: *anyopaque, alloc: Allocator) void {
    const owned: *OwnedStream = @ptrCast(@alignCast(raw_ctx));
    owned.stream.deinit(alloc);
    alloc.destroy(owned);
}

fn sendGatewayReview(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    model: []const u8,
    payload: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) error{OutOfMemory}!permission_auto_classifier.TransportOutcome {
    const config: *GatewayConfig = @ptrCast(@alignCast(raw_ctx));
    debug_trace.logf(
        "permission",
        "event=auto_review_transport_start model={s} retry_count={d}",
        .{ model, single_transport_attempt },
    );
    if (cancel_flag.load(.seq_cst)) return .cancelled;
    if ((config.api_key == null and config.credential_source != .host_managed) or config.chat_url.len == 0) {
        debug_trace.logf("permission", "event=auto_review_transport result=permanent_failure reason=missing_gateway_config", .{});
        return .permanent_failure;
    }

    const usage_observation = session_usage.InvocationObservation.begin(config.usage) catch |err| {
        debug_trace.logf(
            "permission",
            "event=auto_review_usage result=permanent_failure phase=begin reason={s}",
            .{@errorName(err)},
        );
        return .permanent_failure;
    };
    var delivery = gateway_client.DeliveryCertainty.init();
    var stream = config.stream_fn(
        config.stream_ctx,
        alloc,
        config.api_key orelse "",
        config.team,
        model,
        single_transport_attempt,
        config.chat_url,
        payload,
        deadline,
        &delivery,
        cancel_flag,
    ) catch |err| {
        usage_observation.fail(if (delivery.load() == .possibly_sent)
            .ambiguous_delivery
        else
            .unbilled) catch |usage_err| {
            debug_trace.logf(
                "permission",
                "event=auto_review_usage result=permanent_failure phase=transport_failure reason={s}",
                .{@errorName(usage_err)},
            );
            return .permanent_failure;
        };
        return mapTransportError(err, cancel_flag);
    };
    var stream_owned = true;
    defer if (stream_owned) stream.deinit(alloc);
    const usage_outcome = usageOutcome(config, stream.completion);
    (if (stream.status == .ok)
        usage_observation.complete(
            config.usage_allocator,
            stream.completion,
            usage_outcome,
        )
    else
        usage_observation.fail(.unbilled)) catch |err| {
        debug_trace.logf(
            "permission",
            "event=auto_review_usage result=permanent_failure phase=completion reason={s}",
            .{@errorName(err)},
        );
        return .permanent_failure;
    };
    if (stream.status == .ok and std.meta.activeTag(usage_outcome) == .deferred) if (config.usage) |ledger| {
        if (config.api_key) |api_key| {
            ledger.startDeferredReconciliation(
                config.usage_allocator,
                usage_outcome.deferred,
                api_key,
            );
        } else if (config.credential_source == .host_managed) {
            ledger.startHostManagedDeferredReconciliation(
                config.usage_allocator,
                usage_outcome.deferred,
            );
        }
    };

    if (cancel_flag.load(.seq_cst)) {
        return .cancelled;
    }
    if (stream.status != .ok) {
        const outcome = mapHttpStatus(stream.status);
        debug_trace.logf(
            "permission",
            "event=auto_review_transport result={s} http_status={d}",
            .{ @tagName(std.meta.activeTag(outcome)), @backingInt(stream.status) },
        );
        return outcome;
    }
    if (stream.completion.finish_reason) |reason| switch (reason) {
        .provider_error => {
            debug_trace.logf(
                "permission",
                "event=auto_review_transport result=transient_failure reason=provider_error",
                .{},
            );
            return .transient_failure;
        },
        .content_filter => {
            debug_trace.logf(
                "permission",
                "event=auto_review_transport result=permanent_failure reason=content_filter",
                .{},
            );
            return .permanent_failure;
        },
        .stop, .length, .tool_calls, .other => {},
    };
    debug_trace.logf(
        "permission",
        "event=auto_review_transport result=completion finish_reason={s} tool_calls={d} content_bytes={d}",
        .{
            if (stream.completion.finish_reason) |reason| @tagName(reason) else "absent",
            stream.completion.tool_calls.len,
            if (stream.completion.content) |content| content.len else 0,
        },
    );

    const owned = try alloc.create(OwnedStream);
    owned.* = .{ .stream = stream };
    stream_owned = false;
    return .{ .completion = .{
        .completion = owned.stream.completion,
        .context = @ptrCast(owned),
        .deinit_fn = deinitOwnedStream,
    } };
}

fn usageOutcome(
    config: *const GatewayConfig,
    completion: types.ModelCompletion,
) stream_provider.UsageOutcome {
    const generation_id = completion.generation_id orelse
        return .{ .unavailable = .possibly_billed };
    const source = config.credential_source orelse .ai_gateway_api_key;
    const reference = stream_provider.DeferredUsageReference{
        .provider = .gateway,
        .generation_id = generation_id,
        .scope = gateway_client.generationBaseUrl(),
        .tenant = config.team,
        .credential_source = source,
        .credential_identity = credential_authority.derive(
            source,
            null,
        ),
    };
    return if (completion.billing != null)
        .{ .exact = .gateway }
    else
        .{ .deferred = reference };
}

fn mapTransportError(
    err: anyerror,
    cancel_flag: *std.atomic.Value(bool),
) error{OutOfMemory}!permission_auto_classifier.TransportOutcome {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const outcome: permission_auto_classifier.TransportOutcome =
        if (err == error.Cancelled or cancel_flag.load(.seq_cst))
            .cancelled
        else if (err == error.Timeout)
            .timed_out
        else if (gateway_client.isRetryableGatewayError(err))
            .transient_failure
        else
            .permanent_failure;
    debug_trace.logf(
        "permission",
        "event=auto_review_transport result={s} reason=transport_error error={s}",
        .{ @tagName(std.meta.activeTag(outcome)), @errorName(err) },
    );
    return outcome;
}

fn mapHttpStatus(status: std.http.Status) permission_auto_classifier.TransportOutcome {
    const code: u16 = @backingInt(status);
    if (code == 408 or code == 425 or code == 429 or code >= 500) {
        return .transient_failure;
    }
    return .permanent_failure;
}

fn streamGatewayReviewer(
    _: *anyopaque,
    alloc: Allocator,
    api_key: []const u8,
    team: ?[]const u8,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    deadline: std.Io.Clock.Timestamp,
    delivery: *gateway_client.DeliveryCertainty,
    cancel_flag: *std.atomic.Value(bool),
) !gateway_client.StreamResult {
    return gateway_client.streamGatewayRequiredToolCompletionBounded(
        alloc,
        .{
            .api_key = if (api_key.len > 0) api_key else null,
            .team = team,
            .model = model,
            .retry_count = retry_count,
            .chat_url = chat_url,
            .payload = payload,
            .delivery = delivery,
        },
        deadline,
        cancel_flag,
    );
}

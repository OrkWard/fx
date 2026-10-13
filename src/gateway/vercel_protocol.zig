const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const io_mod = @import("../core/shared/io.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const types = @import("../core/shared/types.zig");
const tool_call_ids = @import("tool_call_ids.zig");

pub const ChatRole = types.ChatRole;
pub const ChatMessage = types.ChatMessage;
pub const GatewayCompletion = types.ModelCompletion;
pub const ToolCall = types.ToolCall;

pub const StructuredResponseFormat = struct {
    name: []const u8,
    description: []const u8,
    schema: std.json.Value,
};

const pending_tool_review_result_text = "Tool call has not executed; it is pending permission review.";

pub fn roleName(role: ChatRole) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

pub fn buildGatewayRequestBody(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
) ![]u8 {
    return buildGatewayRequestBodyWithOptions(alloc, tools_json, messages, .{}, .auto);
}

pub fn buildGatewayRequestBodyWithOptions(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
) ![]u8 {
    return buildGatewayRequestBodyWithOptionsAndOutputLimit(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice,
        null,
    );
}

pub fn buildGatewayRequestBodyWithOptionsAndOutputLimit(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
    max_output_tokens: ?u32,
) ![]u8 {
    return buildGatewayRequestBodyWithSettings(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice.label(),
        max_output_tokens,
    );
}

pub fn buildGatewayRequestBodyWithOptionsAndBudget(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
    max_output_tokens: ?u32,
    budget: BuildBudget,
) ![]u8 {
    try validateToolMessageHistory(alloc, messages);
    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice.label(),
        max_output_tokens,
        budget,
        null,
        null,
    );
}

pub fn buildGatewayRequestBodyWithVerifiedImagesAndBudget(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    verified_images: []const image_attachments.VerifiedSnapshot,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
    response_format: StructuredResponseFormat,
    budget: BuildBudget,
) ![]u8 {
    if (messages.len == 0 or messages[messages.len - 1].role != .user) {
        return error.InvalidGatewayHistory;
    }
    if (messages[messages.len - 1].images.len != 0) {
        return error.InvalidGatewayHistory;
    }
    try validateToolMessageHistory(alloc, messages);
    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice.label(),
        null,
        budget,
        response_format,
        .{
            .message_index = messages.len - 1,
            .images = verified_images,
        },
    );
}

pub fn buildGatewayRequiredToolRequestBodyWithOptionsAndOutputLimit(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32,
) ![]u8 {
    return buildGatewayRequestBodyWithSettings(
        alloc,
        tools_json,
        messages,
        options,
        "required",
        max_output_tokens,
    );
}

pub fn buildGatewayRequiredToolRequestBodyWithOptionsAndBudget(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32,
    budget: BuildBudget,
) ![]u8 {
    try validateToolMessageHistory(alloc, messages);
    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        messages,
        options,
        "required",
        max_output_tokens,
        budget,
        null,
        null,
    );
}

pub fn buildGatewayRequiredToolRequestBodyWithMaxOutputTokens(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    max_output_tokens: u32,
) ![]u8 {
    return buildGatewayRequestBodyWithSettings(alloc, tools_json, messages, .{}, "required", max_output_tokens);
}

pub fn buildGatewayPendingToolReviewRequestBodyWithMaxOutputTokens(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    instructions: []const ChatMessage,
    messages: []const ChatMessage,
    target_call_id: []const u8,
    options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: u32,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) ![]u8 {
    const budget = BuildBudget{ .deadline = deadline, .cancel_flag = cancel_flag };
    stream_provider.validate_prompt_lanes(instructions, messages) catch
        return error.InvalidGatewayHistory;
    const expanded = try expandPendingToolReviewMessages(
        alloc,
        messages,
        target_call_id,
        deadline,
        cancel_flag,
    );
    defer alloc.free(expanded);

    const prompt_len = try std.math.add(usize, instructions.len, expanded.len);
    const prompt = try alloc.alloc(ChatMessage, prompt_len);
    defer alloc.free(prompt);
    @memcpy(prompt[0..instructions.len], instructions);
    @memcpy(prompt[instructions.len..], expanded);

    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        prompt,
        options,
        "required",
        max_output_tokens,
        budget,
        null,
        null,
    );
}

/// Returns an owned message slice that closes the pending tool call. Message
/// contents remain borrowed from `messages`.
pub fn expandPendingToolReviewMessages(
    alloc: std.mem.Allocator,
    messages: []const ChatMessage,
    target_call_id: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) ![]ChatMessage {
    const budget = BuildBudget{ .deadline = deadline, .cancel_flag = cancel_flag };
    try budget.check();
    try validatePendingToolReviewMessages(alloc, messages, target_call_id, budget);
    try budget.check();

    const pending_index = messages.len - 1;
    const pending = messages[pending_index];
    const expanded_len = try std.math.add(usize, messages.len, pending.tool_calls.len);
    const expanded = try alloc.alloc(ChatMessage, expanded_len);
    errdefer alloc.free(expanded);

    @memcpy(expanded[0..messages.len], messages);
    for (pending.tool_calls, 0..) |call, i| {
        try budget.check();
        expanded[messages.len + i] = .{
            .role = .tool,
            .content = pending_tool_review_result_text,
            .tool_call_id = call.id,
            .tool_name = call.name,
        };
    }
    try budget.check();
    try validateToolMessageHistory(alloc, expanded);
    try budget.check();
    return expanded;
}

fn buildGatewayRequestBodyWithSettings(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: []const u8,
    max_output_tokens: ?u32,
) ![]u8 {
    try validateToolMessageHistory(alloc, messages);
    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice,
        max_output_tokens,
        null,
        null,
        null,
    );
}

pub const BuildBudget = struct {
    deadline: ?std.Io.Clock.Timestamp = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,

    pub fn check(self: BuildBudget) error{ Cancelled, TimedOut }!void {
        if (self.cancel_flag) |flag| {
            if (flag.load(.seq_cst)) return error.Cancelled;
        }
        if (self.deadline) |deadline| {
            const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
            if (now.raw.nanoseconds >= deadline.raw.nanoseconds) return error.TimedOut;
        }
    }
};

/// The language-model route validates reasoning effort against its own tier
/// names and rejects "max", which the model catalog still advertises for some
/// models. Map it to the highest accepted tier.
fn reasoningWireValue(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "max")) return "xhigh";
    return label;
}

fn buildGatewayRequestBodyValidated(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: []const u8,
    max_output_tokens: ?u32,
    budget: ?BuildBudget,
    response_format: ?StructuredResponseFormat,
    verified_image_override: ?VerifiedImageOverride,
) ![]u8 {
    if (budget) |active| try active.check();
    var saw_conversation = false;
    for (messages) |message| {
        if (message.role == .system) {
            if (saw_conversation) return error.InvalidGatewayHistory;
        } else {
            saw_conversation = true;
        }
    }

    var ids = try tool_call_ids.Projection.init(alloc, messages);
    defer ids.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"prompt\":[");
    var i: usize = 0;
    while (i < messages.len) {
        const message = messages[i];
        if (budget) |active| try active.check();
        if (i > 0) try out.writer.writeByte(',');
        if (message.role == .tool) {
            const results = tool_result_prefix(messages[i..]);
            try write_tool_result_group(alloc, &out.writer, results, budget, &ids);
            i += results.len;
            try write_tool_image_user_message(&out.writer, results, budget);
            if (budget) |active| try active.check();
            continue;
        }
        const verified_images = if (verified_image_override) |override|
            if (override.message_index == i) override.images else null
        else
            null;
        try writeChatMessageJsonInner(
            std.heap.c_allocator,
            &out.writer,
            message,
            budget,
            verified_images,
            &ids,
        );
        if (budget) |active| try active.check();
        i += 1;
    }
    try out.writer.writeAll("],\"tools\":");
    try out.writer.writeAll(tools_json);
    try out.writer.writeAll(",\"toolChoice\":{\"type\":");
    try std.json.Stringify.value(tool_choice, .{}, &out.writer);
    try out.writer.writeByte('}');

    if (response_format) |format| {
        try writeStructuredResponseFormat(alloc, &out.writer, format);
    }

    if (max_output_tokens) |value| {
        try out.writer.print(",\"maxOutputTokens\":{d}", .{value});
    }

    if (options.reasoning) |*reasoning| {
        try out.writer.writeAll(",\"reasoning\":");
        try std.json.Stringify.value(reasoningWireValue(reasoning.label()), .{}, &out.writer);
    }
    try writeProviderOptions(&out.writer, options);

    try out.writer.writeByte('}');
    if (budget) |active| try active.check();
    return try out.toOwnedSlice();
}

/// Returns a new request body with the provider-visible user agent added.
/// The caller retains ownership of `body` and owns the returned slice.
pub fn withRequestUserAgent(
    alloc: std.mem.Allocator,
    body: []const u8,
    user_agent: []const u8,
) ![]u8 {
    if (body.len == 0 or body[body.len - 1] != '}') return error.InvalidGatewayRequestBody;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(body[0 .. body.len - 1]);
    try out.writer.writeAll(",\"headers\":{\"user-agent\":");
    try std.json.Stringify.value(user_agent, .{}, &out.writer);
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn writeStructuredResponseFormat(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    format: StructuredResponseFormat,
) !void {
    _ = alloc;
    if (format.schema != .object) return error.InvalidStructuredResponseSchema;

    try writer.writeAll(",\"responseFormat\":{\"type\":\"json\",\"name\":");
    try std.json.Stringify.value(format.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(format.description, .{}, writer);
    try writer.writeAll(",\"schema\":");
    try std.json.Stringify.value(format.schema, .{}, writer);
    try writer.writeByte('}');
}

const VerifiedImageOverride = struct {
    message_index: usize,
    images: []const image_attachments.VerifiedSnapshot,
};

fn validatePendingToolReviewMessages(
    alloc: std.mem.Allocator,
    messages: []const ChatMessage,
    target_call_id: []const u8,
    budget: BuildBudget,
) !void {
    try budget.check();
    if (messages.len < 1 or target_call_id.len == 0) return error.InvalidGatewayHistory;
    const pending = messages[messages.len - 1];
    if (pending.role != .assistant or pending.tool_calls.len == 0) return error.InvalidGatewayHistory;
    try validateToolMessageHistory(alloc, messages[0 .. messages.len - 1]);
    try budget.check();
    try validateAssistantToolCalls(alloc, pending.tool_calls);
    try budget.check();

    var target_matches: usize = 0;
    for (pending.tool_calls) |call| {
        try budget.check();
        if (std.mem.eql(u8, call.id, target_call_id)) target_matches += 1;
    }
    if (target_matches != 1) return error.InvalidGatewayHistory;
}

pub fn writeProviderOptions(writer: *std.Io.Writer, options: model_capabilities.ResolvedProviderOptions) !void {
    const routing = options.provider_order.len > 0;
    if (options.ultrafast and options.provider_strict and routing) {
        var allows_openai = false;
        for (options.provider_order) |provider| {
            if (std.mem.eql(u8, provider, "openai")) allows_openai = true;
        }
        if (!allows_openai) return error.UltrafastProviderRestricted;
    }
    const gateway_options = options.fast or options.ultrafast or options.prompt_caching or routing;
    if (!gateway_options and options.parallel_tool_calls == null) return;

    try writer.writeAll(",\"providerOptions\":{");
    if (gateway_options) {
        try writer.writeAll("\"gateway\":{");
        var needs_comma = false;
        if (options.fast and !options.ultrafast) {
            try writer.writeAll("\"speed\":\"fast\"");
            needs_comma = true;
        }
        if (options.prompt_caching) {
            if (needs_comma) try writer.writeByte(',');
            try writer.writeAll("\"caching\":\"auto\"");
            needs_comma = true;
        }
        if (options.ultrafast) {
            if (needs_comma) try writer.writeByte(',');
            try writer.writeAll("\"only\":[\"openai\"]");
        } else if (routing) {
            if (needs_comma) try writer.writeByte(',');
            try writer.writeAll(if (options.provider_strict) "\"only\":[" else "\"order\":[");
            for (options.provider_order, 0..) |slug, index| {
                if (index > 0) try writer.writeByte(',');
                try std.json.Stringify.value(slug, .{}, writer);
            }
            try writer.writeByte(']');
        }
        try writer.writeByte('}');
    }
    if (options.ultrafast) {
        try writer.writeAll(",\"openai\":{\"serviceTier\":\"ultrafast\"}");
    }
    if (options.parallel_tool_calls) |parallel_tool_calls| {
        if (gateway_options) try writer.writeByte(',');
        try writer.writeAll("\"xai\":{\"parallelToolCalls\":");
        try writer.writeAll(if (parallel_tool_calls) "true" else "false");
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
}

pub fn validateToolMessageHistory(alloc: std.mem.Allocator, messages: []const ChatMessage) !void {
    var i: usize = 0;
    while (i < messages.len) {
        const msg = messages[i];
        if (msg.role == .tool) return error.InvalidGatewayHistory;
        if (msg.role != .assistant or msg.tool_calls.len == 0) {
            i += 1;
            continue;
        }

        try validateAssistantToolCalls(alloc, msg.tool_calls);
        const seen = try alloc.alloc(bool, msg.tool_calls.len);
        defer alloc.free(seen);

        i = try validateAssistantToolResultBlock(messages, i + 1, msg.tool_calls, seen);
    }
}

fn validateAssistantToolResultBlock(
    messages: []const ChatMessage,
    start_index: usize,
    calls: []const ToolCall,
    seen: []bool,
) !usize {
    @memset(seen, false);

    var result_count: usize = 0;
    var j = start_index;
    while (result_count < calls.len) : (j += 1) {
        if (j >= messages.len) return error.InvalidGatewayHistory;
        const result = messages[j];
        if (result.role != .tool) return error.InvalidGatewayHistory;
        const tool_call_id = result.tool_call_id orelse return error.InvalidGatewayHistory;
        const tool_name = result.tool_name orelse return error.InvalidGatewayHistory;
        if (result.content == null) return error.InvalidGatewayHistory;

        const matched_index = findToolCallIndex(calls, tool_call_id) orelse return error.InvalidGatewayHistory;
        if (seen[matched_index]) return error.InvalidGatewayHistory;
        if (!std.mem.eql(u8, calls[matched_index].name, tool_name)) return error.InvalidGatewayHistory;
        seen[matched_index] = true;
        result_count += 1;
    }
    return j;
}

fn validateAssistantToolCalls(alloc: std.mem.Allocator, calls: []const ToolCall) !void {
    for (calls, 0..) |call, i| {
        if (call.id.len == 0 or call.name.len == 0 or call.arguments_json.len == 0) return error.InvalidGatewayHistory;
        const integrity = if (call.provenance == .provider_executed)
            try types.ToolArgumentIntegrity.classifySerialized(alloc, call.arguments_json)
        else
            try types.ToolArgumentIntegrity.classifyFunctionInput(alloc, call.arguments_json);
        if (integrity != .valid) {
            return error.InvalidGatewayHistory;
        }
        var j = i + 1;
        while (j < calls.len) : (j += 1) {
            if (std.mem.eql(u8, call.id, calls[j].id)) return error.InvalidGatewayHistory;
        }
    }
}

fn findToolCallIndex(calls: []const ToolCall, id: []const u8) ?usize {
    for (calls, 0..) |call, i| {
        if (std.mem.eql(u8, call.id, id)) return i;
    }
    return null;
}

const max_prompt_shape_entries: usize = 12;

fn tool_result_prefix(messages: []const ChatMessage) []const ChatMessage {
    var end: usize = 0;
    while (end < messages.len and messages[end].role == .tool) : (end += 1) {}
    return messages[0..end];
}

fn write_tool_result_group(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    results: []const ChatMessage,
    budget: ?BuildBudget,
    ids: *const tool_call_ids.Projection,
) !void {
    try writer.writeAll("{\"role\":\"tool\",\"content\":[");
    for (results, 0..) |result, index| {
        if (budget) |active| try active.check();
        if (index > 0) try writer.writeByte(',');
        try write_tool_result_part(alloc, writer, result, ids);
    }
    try writer.writeAll("]}");
}

const tool_image_followup_text = "Attached image(s) from the tool result.";

// Retained tool images ride in a user message following the contiguous tool
// run: user-position file parts are the one image position every gateway
// provider route renders as vision input, while tool-result-position images
// are ignored by several routes (and the legacy "image-data" part type was
// removed from the gateway spec). Writes nothing when the run has no images.
fn write_tool_image_user_message(writer: *std.Io.Writer, results: []const ChatMessage, budget: ?BuildBudget) !void {
    var has_images = false;
    for (results) |result| {
        const memory = result.tool_result_memory orelse continue;
        if (memory.tool_images.len == 0) continue;
        const failed = if (result.tool_result_status) |status| status == .failure else false;
        if (failed and tool_result_errors.toolPermissionDenialReason(result.content orelse "") != null) continue;
        has_images = true;
        break;
    }
    if (!has_images) return;
    try writer.writeAll(",{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(tool_image_followup_text, .{}, writer);
    try writer.writeByte('}');
    for (results) |result| {
        // Mirror the tool-result gate: images from permission-denied results
        // never leave the process.
        const failed = if (result.tool_result_status) |status| status == .failure else false;
        if (failed and tool_result_errors.toolPermissionDenialReason(result.content orelse "") != null) continue;
        const memory = result.tool_result_memory orelse continue;
        for (memory.tool_images) |image| {
            if (budget) |active| try active.check();
            try writer.writeAll(",{\"type\":\"file\",\"mediaType\":");
            try std.json.Stringify.value(image.mime_type, .{}, writer);
            try writer.writeAll(",\"data\":{\"type\":\"data\",\"data\":");
            try std.json.Stringify.value(image.data, .{}, writer);
            try writer.writeAll("}}");
        }
    }
    try writer.writeAll("]}");
}

fn write_tool_result_part(scratch_alloc: std.mem.Allocator, writer: *std.Io.Writer, message: ChatMessage, ids: *const tool_call_ids.Projection) !void {
    try writer.writeAll("{\"type\":\"tool-result\",\"toolCallId\":");
    try std.json.Stringify.value(ids.resolve(message.tool_call_id orelse ""), .{}, writer);
    try writer.writeAll(",\"toolName\":");
    try std.json.Stringify.value(message.tool_name orelse "unknown", .{}, writer);
    const content = message.content orelse "";
    const failed = if (message.tool_result_status) |status|
        status == .failure
    else
        false;
    const denied = failed and tool_result_errors.toolPermissionDenialReason(content) != null;
    const tool_images = if (message.tool_result_memory) |memory| memory.tool_images else &.{};
    if (tool_images.len > 0 and !denied) {
        // Retained tool images are delivered in a follow-up user message (see
        // write_tool_image_user_message). Tool-result-position image parts are
        // ignored by several gateway provider routes, so only the text
        // acknowledgment stays here.
        try writer.writeAll(",\"output\":{\"type\":\"content\",\"value\":[");
        const text = if (failed) try scratch_alloc.print("Tool error: {s}", .{content}) else content;
        defer if (failed) scratch_alloc.free(text);
        try writer.writeAll("{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(text, .{}, writer);
        try writer.writeAll("}]}}");
        return;
    }
    if (denied) {
        try writer.writeAll(",\"output\":{\"type\":\"execution-denied\",\"reason\":");
    } else if (failed) {
        try writer.writeAll(",\"output\":{\"type\":\"error-text\",\"value\":");
    } else {
        try writer.writeAll(",\"output\":{\"type\":\"text\",\"value\":");
    }
    try std.json.Stringify.value(content, .{}, writer);
    try writer.writeAll("}}");
}

fn writeChatMessageJsonInner(
    scratch_alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: ChatMessage,
    budget: ?BuildBudget,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    ids: *const tool_call_ids.Projection,
) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(roleName(message.role), .{}, writer);

    if (message.role == .assistant) if (message.provider_replay) |replay| {
        try writeReplayContent(scratch_alloc, writer, message, replay, ids, budget);
        try writer.writeByte('}');
        return;
    };

    switch (message.role) {
        .system => {
            try writer.writeAll(",\"content\":");
            if (message.content) |content| {
                try std.json.Stringify.value(content, .{}, writer);
            } else {
                try writer.writeAll("\"\"");
            }
        },
        .user => {
            try writer.writeAll(",\"content\":[");
            var wrote_part = false;
            if (message.content) |content| {
                if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    wrote_part = true;
                }
            }
            if (verified_images) |snapshots| {
                for (snapshots) |snapshot| {
                    if (wrote_part) try writer.writeByte(',');
                    try image_attachments.writeVerifiedImageFilePartJsonWithBudget(
                        writer,
                        snapshot,
                        .{
                            .deadline = if (budget) |active| active.deadline else null,
                            .cancel_flag = if (budget) |active| active.cancel_flag else null,
                        },
                    );
                    wrote_part = true;
                }
            } else {
                for (message.images) |image| {
                    if (wrote_part) try writer.writeByte(',');
                    if (budget) |active| {
                        try image_attachments.writeImageFilePartJsonWithBudget(
                            scratch_alloc,
                            writer,
                            image,
                            .{
                                .deadline = active.deadline,
                                .cancel_flag = active.cancel_flag,
                            },
                        );
                    } else {
                        try image_attachments.writeImageFilePartJson(scratch_alloc, writer, image);
                    }
                    wrote_part = true;
                }
            }
            try writer.writeByte(']');
        },
        .assistant => {
            try writer.writeAll(",\"content\":[");
            var wrote_part = false;
            if (message.content) |content| {
                if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    wrote_part = true;
                }
            }
            for (message.tool_calls) |tool_call| {
                if (wrote_part) try writer.writeByte(',');
                try writeToolCallPart(writer, tool_call, null, ids);
                wrote_part = true;
            }
            try writer.writeByte(']');
        },
        .tool => {
            try writer.writeAll(",\"content\":[");
            try write_tool_result_part(scratch_alloc, writer, message, ids);
            try writer.writeByte(']');
        },
    }

    try writer.writeAll("}");
}

fn writeToolCallPart(writer: *std.Io.Writer, call: ToolCall, metadata: ?std.json.Value, ids: *const tool_call_ids.Projection) !void {
    try writer.writeAll("{\"type\":\"tool-call\",\"toolCallId\":");
    try std.json.Stringify.value(ids.resolve(call.id), .{}, writer);
    try writer.writeAll(",\"toolName\":");
    try std.json.Stringify.value(call.name, .{}, writer);
    try writer.writeAll(",\"input\":");
    try writer.writeAll(call.arguments_json);
    try writeReplayMetadata(writer, metadata);
    try writer.writeByte('}');
}

fn writeReplayMetadata(writer: *std.Io.Writer, metadata: ?std.json.Value) !void {
    const value = metadata orelse return;
    if (value != .object) return error.InvalidProviderState;
    for (value.object.values()) |options| if (options != .object) return error.InvalidProviderState;
    try writer.writeAll(",\"providerOptions\":");
    try std.json.Stringify.value(value, .{}, writer);
}

/// Borrows unchanged replay, otherwise uses the caller's request arena. Selects
/// metadata for the assistant unit after core splits a provider-executed reply.
pub fn selectReplayParts(
    arena: std.mem.Allocator,
    replay: ?types.ProviderReplay,
    calls: []const ToolCall,
    include_text: bool,
    include_reasoning: bool,
) !?types.ProviderReplay {
    const source = replay orelse return null;
    if (source.source.provider != .gateway) return error.InvalidProviderState;
    if (source.parts_json.len > types.ProviderReplay.max_bytes) return error.ProviderStateTooLarge;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, source.parts_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidProviderState,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidProviderState;
    var selected: std.ArrayList(std.json.Value) = .empty;
    defer selected.deinit(arena);
    for (parsed.value.array.items) |part| {
        if (part != .object) return error.InvalidProviderState;
        const kind = part.object.get("type") orelse return error.InvalidProviderState;
        if (kind != .string) return error.InvalidProviderState;
        const keep = if (std.mem.eql(u8, kind.string, "text")) include_text else if (std.mem.eql(u8, kind.string, "reasoning")) include_reasoning else if (std.mem.eql(u8, kind.string, "tool-call")) blk: {
            const id = part.object.get("toolCallId") orelse return error.InvalidProviderState;
            if (id != .string) return error.InvalidProviderState;
            break :blk findToolCallIndex(calls, id.string) != null;
        } else return error.InvalidProviderState;
        if (keep) try selected.append(arena, part);
    }
    if (selected.items.len == 0) return null;
    if (selected.items.len == parsed.value.array.items.len) return source;
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    try std.json.Stringify.value(selected.items, .{}, &out.writer);
    return .{ .source = source.source, .parts_json = try out.toOwnedSlice() };
}

fn writeReplayContent(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: ChatMessage,
    replay: types.ProviderReplay,
    ids: *const tool_call_ids.Projection,
    budget: ?BuildBudget,
) !void {
    if (replay.source.provider != .gateway) return error.InvalidProviderState;
    if (replay.parts_json.len > types.ProviderReplay.max_bytes) return error.ProviderStateTooLarge;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, replay.parts_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidProviderState,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidProviderState;
    const seen_calls = try alloc.alloc(bool, message.tool_calls.len);
    defer alloc.free(seen_calls);
    @memset(seen_calls, false);
    const content = message.content orelse "";
    var text_end: usize = 0;
    var wrote_part = false;
    try writer.writeAll(",\"content\":[");
    for (parsed.value.array.items) |part| {
        if (budget) |active| try active.check();
        if (part != .object) return error.InvalidProviderState;
        const kind = part.object.get("type") orelse return error.InvalidProviderState;
        if (kind != .string) return error.InvalidProviderState;
        if (wrote_part) try writer.writeByte(',');
        const metadata = part.object.get("providerOptions");
        if (std.mem.eql(u8, kind.string, "reasoning")) {
            const text_value = part.object.get("text") orelse return error.InvalidProviderState;
            if (text_value != .string) return error.InvalidProviderState;
            try writer.writeAll("{\"type\":\"reasoning\",\"text\":");
            try std.json.Stringify.value(text_value.string, .{}, writer);
            try writeReplayMetadata(writer, metadata);
            try writer.writeByte('}');
        } else if (std.mem.eql(u8, kind.string, "text")) {
            const offset_value = part.object.get("offset") orelse return error.InvalidProviderState;
            const length_value = part.object.get("length") orelse return error.InvalidProviderState;
            if (offset_value != .integer or length_value != .integer) return error.InvalidProviderState;
            const offset = std.math.cast(usize, offset_value.integer) orelse return error.InvalidProviderState;
            const length = std.math.cast(usize, length_value.integer) orelse return error.InvalidProviderState;
            if (offset != text_end or offset > content.len or length > content.len - offset) return error.InvalidProviderState;
            text_end = offset + length;
            try writer.writeAll("{\"type\":\"text\",\"text\":");
            try std.json.Stringify.value(content[offset..text_end], .{}, writer);
            try writeReplayMetadata(writer, metadata);
            try writer.writeByte('}');
        } else if (std.mem.eql(u8, kind.string, "tool-call")) {
            const call_id = part.object.get("toolCallId") orelse return error.InvalidProviderState;
            if (call_id != .string) return error.InvalidProviderState;
            const index = findToolCallIndex(message.tool_calls, call_id.string) orelse return error.InvalidProviderState;
            if (seen_calls[index]) return error.InvalidProviderState;
            seen_calls[index] = true;
            try writeToolCallPart(writer, message.tool_calls[index], metadata, ids);
        } else return error.InvalidProviderState;
        wrote_part = true;
    }
    if (text_end < content.len) {
        if (wrote_part) try writer.writeByte(',');
        try writer.writeAll("{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(content[text_end..], .{}, writer);
        try writer.writeByte('}');
        wrote_part = true;
    }
    for (message.tool_calls, seen_calls) |call, seen| {
        if (seen) continue;
        if (wrote_part) try writer.writeByte(',');
        try writeToolCallPart(writer, call, null, ids);
        wrote_part = true;
    }
    try writer.writeByte(']');
}

pub fn formatGatewayRequestShapeSummary(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.print("bytes={d}", .{payload.len});

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |err| {
        try out.writer.print(" parse_error={s}", .{@errorName(err)});
        return try out.toOwnedSlice();
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try out.writer.print(" root={s}", .{jsonKindName(parsed.value)});
        return try out.toOwnedSlice();
    }

    if (parsed.value.object.get("prompt")) |prompt| {
        if (prompt == .array) {
            try out.writer.print(" prompt_count={d}", .{prompt.array.items.len});
            const limit = @min(prompt.array.items.len, max_prompt_shape_entries);
            for (prompt.array.items[0..limit], 0..) |entry, i| {
                try out.writer.print(" prompt.{d}", .{i});
                if (entry == .object) {
                    if (entry.object.get("role")) |role_value| {
                        try out.writer.writeAll(" role=");
                        if (role_value == .string) {
                            try appendSafeShapeToken(&out.writer, role_value.string);
                        } else {
                            try out.writer.writeAll(jsonKindName(role_value));
                        }
                    } else {
                        try out.writer.writeAll(" role=missing");
                    }
                    if (entry.object.get("content")) |content_value| {
                        try out.writer.print(" content={s}", .{jsonKindName(content_value)});
                        if (content_value == .array) try out.writer.print(" parts={d}", .{content_value.array.items.len});
                    } else {
                        try out.writer.writeAll(" content=missing");
                    }
                } else {
                    try out.writer.print(" entry={s}", .{jsonKindName(entry)});
                }
            }
            if (prompt.array.items.len > limit) {
                try out.writer.print(" prompt_omitted={d}", .{prompt.array.items.len - limit});
            }
        } else {
            try out.writer.print(" prompt={s}", .{jsonKindName(prompt)});
        }
    } else {
        try out.writer.writeAll(" prompt=missing");
    }

    if (parsed.value.object.get("tools")) |tools| {
        try out.writer.print(" tools={s}", .{jsonKindName(tools)});
        if (tools == .array) try out.writer.print(" tools_count={d}", .{tools.array.items.len});
    }

    if (parsed.value.object.get("toolChoice")) |tool_choice| {
        if (tool_choice == .object) {
            if (tool_choice.object.get("type")) |type_value| {
                try out.writer.writeAll(" toolChoice=");
                if (type_value == .string) {
                    try appendSafeShapeToken(&out.writer, type_value.string);
                } else {
                    try out.writer.writeAll(jsonKindName(type_value));
                }
            } else {
                try out.writer.writeAll(" toolChoice=object");
            }
        } else {
            try out.writer.print(" toolChoice={s}", .{jsonKindName(tool_choice)});
        }
    }

    if (parsed.value.object.get("providerOptions")) |provider_options| {
        try out.writer.print(" providerOptions={s}", .{jsonKindName(provider_options)});
        if (provider_options == .object) try out.writer.print(" providerOptions_count={d}", .{provider_options.object.count()});
    }

    return try out.toOwnedSlice();
}

fn appendSafeShapeToken(writer: *std.Io.Writer, raw: []const u8) !void {
    var wrote = false;
    var last_was_underscore = false;
    for (raw) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', '[', ']' => {
                try writer.writeByte(c);
                wrote = true;
                last_was_underscore = c == '_';
            },
            else => {
                if (!last_was_underscore) {
                    try writer.writeByte('_');
                    wrote = true;
                    last_was_underscore = true;
                }
            },
        }
    }
    if (!wrote) try writer.writeAll("unknown");
}

fn jsonKindName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "bool",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

pub fn parseGatewayCompletion(alloc: std.mem.Allocator, body: []const u8) !GatewayCompletion {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidGatewayResponse;

    const choices = root.object.get("choices") orelse return error.InvalidGatewayResponse;
    if (choices != .array or choices.array.items.len == 0) return error.InvalidGatewayResponse;

    const choice = choices.array.items[0];
    if (choice != .object) return error.InvalidGatewayResponse;

    const message_value = choice.object.get("message") orelse return error.InvalidGatewayResponse;
    if (message_value != .object) return error.InvalidGatewayResponse;

    var output: GatewayCompletion = .{};
    if (message_value.object.get("content")) |content| {
        if (content == .string) output.content = try alloc.dupe(u8, content.string);
    }
    errdefer freeGatewayCompletion(alloc, output);

    if (choice.object.get("finish_reason")) |finish_reason| {
        if (finish_reason == .string and finish_reason.string.len > 0) {
            output.finish_reason = types.ProviderFinishReason.parse_legacy(finish_reason.string) orelse
                return error.InvalidGatewayResponse;
        }
    }

    if (message_value.object.get("tool_calls")) |tool_calls| {
        if (tool_calls == .array and tool_calls.array.items.len > 0) {
            const buffer = try alloc.alloc(ToolCall, tool_calls.array.items.len);
            var count: usize = 0;
            errdefer {
                for (buffer[0..count]) |tool_call| {
                    alloc.free(tool_call.id);
                    alloc.free(tool_call.name);
                    alloc.free(tool_call.arguments_json);
                }
                alloc.free(buffer);
            }

            for (tool_calls.array.items) |item| {
                if (item != .object) continue;
                const id = item.object.get("id") orelse continue;
                if (id != .string) continue;
                const fn_value = item.object.get("function") orelse continue;
                if (fn_value != .object) continue;
                const name = fn_value.object.get("name") orelse continue;
                const args = fn_value.object.get("arguments") orelse continue;
                if (name != .string or args != .string) continue;
                if (try types.ToolArgumentIntegrity.classifySerialized(alloc, args.string) == .malformed_json) {
                    return error.InvalidGatewayResponse;
                }
                const id_copy = try alloc.dupe(u8, id.string);
                errdefer alloc.free(id_copy);
                const name_copy = try alloc.dupe(u8, name.string);
                errdefer alloc.free(name_copy);
                const arguments_copy = try alloc.dupe(u8, args.string);
                errdefer alloc.free(arguments_copy);

                buffer[count] = .{
                    .id = id_copy,
                    .name = name_copy,
                    .arguments_json = arguments_copy,
                };
                count += 1;
            }
            if (count == 0) {
                alloc.free(buffer);
            } else if (count < buffer.len) {
                output.tool_calls = try alloc.dupe(ToolCall, buffer[0..count]);
                alloc.free(buffer);
            } else {
                output.tool_calls = buffer;
            }
        }
    }

    return output;
}

pub fn freeGatewayCompletion(alloc: std.mem.Allocator, completion: GatewayCompletion) void {
    if (completion.content) |content| alloc.free(content);
    for (completion.tool_calls) |tool_call| {
        alloc.free(tool_call.id);
        alloc.free(tool_call.name);
        alloc.free(tool_call.arguments_json);
    }
    if (completion.tool_calls.len > 0) alloc.free(completion.tool_calls);
    if (completion.provider_state_json) |state| alloc.free(state);
}

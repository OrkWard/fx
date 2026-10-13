const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");

pub const ChatMessage = types.ChatMessage;
pub const ToolCall = types.ToolCall;

pub const StructuredResponseFormat = struct {
    name: []const u8,
    description: []const u8,
    schema: std.json.Value,
};

const pending_tool_review_result_text = "Tool call has not executed; it is pending permission review.";

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

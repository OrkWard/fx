//! Which part of the conversation fx-compactor compacts. The newest turns
//! stay unchanged within a share of the room the request aims for right
//! after compaction; everything older is compacted. The compacted part keeps
//! every user message and final reply, so a long session may need more than
//! that room.

const std = @import("std");
const settings = @import("settings.zig");
const history_range = @import("../shared/history_range.zig");
const token_estimate = @import("../shared/token_estimate.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const trace = @import("trace.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const HistoryTurn = types.HistoryTurn;

/// Right after compaction the whole request aims for at most this share of
/// the usable input, and at most half of the compaction point.
const after_percent: usize = 20;
/// Of the room the compacted conversation gets, the newest turns kept
/// unchanged may use this share.
const kept_percent: usize = 40;
const max_kept_turns: usize = 4;

/// How large the conversation is and may be, in estimated tokens.
pub const Size = struct {
    /// Where automatic compaction starts, when the model's size is known.
    compact_at_tokens: ?usize,
    /// The model's usable input, when known.
    usable_tokens: ?usize,
    /// The request that needs the room, when there is one.
    request_tokens: ?usize = null,
    /// What compaction cannot shrink: the request's instructions and tool
    /// definitions, measured like the request. When unknown, half of the
    /// room after compaction is set aside for it.
    fixed_tokens: ?usize = null,
    /// How far fx's token estimate ran from the provider's count on a recent
    /// request. The compactor measures text with that estimate, so its room
    /// is scaled by the same ratio.
    correction: ?Correction = null,
    /// The provider rejected that request as too large, so the estimate was
    /// wrong and the room after compaction is bounded by the request instead.
    overflow: bool = false,

    /// The provider counted `measured` tokens for a request estimated at
    /// `estimated`.
    pub const Correction = struct { estimated: usize, measured: usize };

    /// `tokens` as the provider counts them, in fx's estimate.
    fn estimate(self: Size, tokens: usize) usize {
        const correction = self.correction orelse return tokens;
        if (correction.estimated == 0 or correction.measured == 0 or tokens == std.math.maxInt(usize)) return tokens;
        return std.math.cast(usize, @as(u128, tokens) * correction.estimated / correction.measured) orelse std.math.maxInt(usize);
    }

    /// The sizes for a model, compacting automatically at `percent` of its
    /// usable input.
    pub fn of(capabilities: model_capabilities.Capabilities, percent: u8) Size {
        return .{
            .compact_at_tokens = compactAtTokens(capabilities, percent),
            .usable_tokens = usableInputTokens(capabilities),
        };
    }

    /// Estimated tokens one summary request may use: the model's usable
    /// input. After the provider rejected a request as too large, estimates
    /// ran low, so a summary request stays well below the rejected one.
    pub fn summaryRequestTokens(self: Size) usize {
        var room = self.usable_tokens orelse std.math.maxInt(usize);
        if (self.overflow) if (self.request_tokens) |rejected| {
            room = @min(room, rejected / 4 * 3);
        };
        return self.estimate(room);
    }

    /// Estimated tokens a notes request may use when sent right after the
    /// conversation of `request_tokens`. Null when either size is unknown,
    /// nothing is left, or the provider rejected that conversation as too
    /// large.
    pub fn roomAfterConversation(self: Size) ?usize {
        const usable = self.usable_tokens orelse return null;
        const conversation = self.request_tokens orelse return null;
        if (self.overflow or conversation >= usable) return null;
        return self.estimate(usable - conversation);
    }

    /// Estimated tokens the whole request may use right after compaction.
    pub fn afterTokens(self: Size) usize {
        const point = self.compact_at_tokens orelse self.request_tokens orelse return std.math.maxInt(usize);
        var after = point / 2;
        if (self.usable_tokens) |usable| after = @min(after, percentOf(usable, after_percent));
        if (self.overflow) if (self.request_tokens) |rejected| {
            after = @min(after, percentOf(rejected, after_percent));
        };
        return after;
    }

    /// Estimated tokens the compacted conversation may use: the room after
    /// compaction less the fixed part. Never below a quarter of that room,
    /// so compaction still keeps something when the fixed part alone fills
    /// it.
    fn conversationTokens(self: Size) usize {
        const after = self.afterTokens();
        if (after == std.math.maxInt(usize)) return after;
        const fixed = self.fixed_tokens orelse after / 2;
        return self.estimate(@max(after -| fixed, after / 4));
    }

    /// Estimated tokens the compacted text may use so compaction still frees
    /// at least half the room: half the compaction point less the fixed part
    /// and `kept_used`, the turns kept unchanged. Past it, the conversation
    /// would compact again right away and soon not fit at all.
    pub fn compactedTokens(self: Size, kept_used: usize) usize {
        const point = self.compact_at_tokens orelse self.request_tokens orelse return std.math.maxInt(usize);
        var most = point / 2;
        if (self.overflow) if (self.request_tokens) |rejected| {
            most = @min(most, rejected / 2);
        };
        const fixed = self.fixed_tokens orelse most / 4;
        return self.estimate(@max(most -| fixed, most / 4)) -| kept_used;
    }

    /// The request has reached the automatic compaction point.
    pub fn due(self: Size) bool {
        const at = self.compact_at_tokens orelse return false;
        const request = self.request_tokens orelse return false;
        return request >= at;
    }

    /// Compaction must free room: without it the request cannot be sent.
    fn required(self: Size) bool {
        const request = self.request_tokens orelse return self.overflow;
        return self.overflow or request > (self.usable_tokens orelse std.math.maxInt(usize));
    }
};

/// Request size, in tokens, at which automatic compaction starts: `percent`
/// of the model's usable input.
fn compactAtTokens(capabilities: model_capabilities.Capabilities, percent: u8) ?usize {
    const usable = usableInputTokens(capabilities) orelse return null;
    return percentOf(usable, @min(settings.max_percent, @max(settings.min_percent, percent)));
}

fn percentOf(tokens: usize, percent: usize) usize {
    return tokens / 100 * percent + tokens % 100 * percent / 100;
}

/// The model's input room: its context window less the room it keeps for
/// output.
fn usableInputTokens(capabilities: model_capabilities.Capabilities) ?usize {
    const context_window = capabilities.context_window orelse return null;
    const context_tokens: usize = @intCast(context_window);
    // Reserve exactly what the request asks for; that limit is always below the window.
    const output_tokens: usize = model_capabilities.requestOutputTokens(capabilities) orelse return context_tokens;
    return context_tokens - output_tokens;
}

const textTokens = token_estimate.textTokens;

/// Where the kept part starts, and its estimated tokens.
const Recent = struct { cut: types.ContextHistoryCut, tokens: usize = 0 };

/// Where the kept part starts: the newest complete execution steps within
/// `target` tokens and `max_turns` turns. A newest step larger than `target`
/// is not kept. Payloads are measured, never shortened.
fn selectRecentContext(
    history: []const HistoryTurn,
    target: usize,
    input_capacity: ?usize,
    provider: ?model_provider.ProviderSelection,
    max_turns: usize,
) Recent {
    var raw_count = history_range.rawHistoryTurnCount(history);
    var selected = Recent{ .cut = .{ .turns = raw_count } };
    var total: usize = 0;
    var selected_any = false;
    var turns_used: usize = 0;
    var index = history.len;
    history_scan: while (index > 0) {
        index -= 1;
        const turn = history[index];
        if (turn == .compacted_summary) continue;
        if (selected_any and turns_used >= max_turns) break;
        raw_count -= 1;
        const user = switch (turn) {
            .assistant => |entry| entry.user.text,
            .interrupted => |entry| entry.user.text,
            .compacted_summary => unreachable,
        };
        const reply = switch (turn) {
            .assistant => |entry| entry.assistant,
            .interrupted => |entry| entry.assistant orelse "",
            .compacted_summary => unreachable,
        };
        const execution = switch (turn) {
            .assistant => |entry| entry.execution,
            .interrupted => |entry| entry.execution,
            .compacted_summary => unreachable,
        };
        const replay = switch (turn) {
            .assistant => |entry| entry.provider_replay,
            .interrupted => null,
            .compacted_summary => unreachable,
        };
        var base = textTokens(user) +| textTokens(reply) +| replay_tokens(replay, provider) +| 8;
        var steering_index = execution.steering.len;
        var step_index = execution.tool_steps.len;
        if (step_index == 0) {
            for (execution.steering) |entry| {
                base +|= textTokens(entry.text);
                if (entry.assistant_prefix) |prefix| base +|= textTokens(prefix);
            }
            if (input_capacity) |capacity| {
                if (!selected_any and base >= capacity) break :history_scan;
            }
            if (selected_any and (raw_count == 0 or total +| base > target)) break;
            total +|= base;
            selected = .{ .cut = .{ .turns = raw_count }, .tokens = total };
            selected_any = true;
            turns_used += 1;
            continue;
        }
        var turn_counted = false;
        while (step_index > 0) {
            step_index -= 1;
            var cost = base +| executionStepTokens(execution.tool_steps[step_index], provider);
            var next_steering = steering_index;
            while (next_steering > 0 and execution.steering[next_steering - 1].after_tool_step_count >= step_index) {
                next_steering -= 1;
                cost +|= textTokens(execution.steering[next_steering].text);
                if (execution.steering[next_steering].assistant_prefix) |prefix| cost +|= textTokens(prefix);
            }
            if (!selected_any and cost > target) break :history_scan;
            if (input_capacity) |capacity| {
                if (!selected_any and cost >= capacity) break :history_scan;
            }
            if (selected_any and ((raw_count == 0 and step_index == 0) or total +| cost > target)) return selected;
            total +|= cost;
            selected = .{ .cut = .{ .turns = raw_count, .tool_steps = step_index, .steering = next_steering }, .tokens = total };
            selected_any = true;
            if (!turn_counted) turns_used += 1;
            turn_counted = true;
            steering_index = next_steering;
            base = 0;
        }
    }
    return selected;
}

fn replay_tokens(replay: ?types.ProviderReplay, provider: ?model_provider.ProviderSelection) usize {
    const value = replay orelse return 0;
    if (provider) |route| if (!value.matches(route)) return 0;
    return textTokens(value.parts_json);
}

fn executionStepTokens(step: types.ToolExecutionStep, provider: ?model_provider.ProviderSelection) usize {
    var total: usize = 8 +| replay_tokens(step.provider_replay, provider);
    if (step.assistant) |text| total +|= textTokens(text);
    for (step.tool_calls) |call| {
        total +|= textTokens(call.id) +| textTokens(call.name) +| textTokens(call.arguments_json) +| 8;
    }
    for (step.tool_results) |result| {
        total +|= textTokens(result.tool_call_id) +| textTokens(result.tool_name) +| textTokens(result.output) +| 8;
    }
    return total;
}

pub const Window = struct {
    /// The newest checkpoint before `older`.
    earlier: ?[]const u8,
    /// Raw turns to compact, oldest first.
    older: []HistoryTurn,
    /// The raw part that stays after the checkpoint.
    retained_history: []HistoryTurn,
    /// What stays in the conversation after the cut: `retained_history` and
    /// the rest of the turn in progress, which lives outside the history.
    kept: []HistoryTurn,
    cut: types.ContextHistoryCut,
    /// Token budget of the part kept unchanged.
    kept_tokens: usize,
    /// Estimated tokens of the part kept unchanged.
    kept_used: usize = 0,

    /// True when the cut falls inside a turn: that turn's user message stays
    /// with the part kept after the checkpoint.
    pub fn splitsLastTurn(self: Window) bool {
        return self.older.len > 0 and (self.cut.tool_steps > 0 or self.cut.steering > 0);
    }
};

/// Chooses what to compact. Null when nothing needs compacting. When the
/// request cannot be sent otherwise, compacts everything before giving up
/// with `ContextCapacityExceeded`. Slices are arena-owned.
pub fn choose(
    arena: Allocator,
    history: []const HistoryTurn,
    active: ?types.AssistantHistoryTurn,
    size: Size,
    route: model_provider.ProviderSelection,
    trace_ctx: debug_trace.TraceContext,
) !?Window {
    var kept = percentOf(size.conversationTokens(), kept_percent);
    while (true) {
        const window = try split(arena, history, active, kept, size.usable_tokens, route);
        if (window.older.len > 0) return window;
        if (!size.required()) return null;
        if (kept == 0) {
            trace.failure(trace_ctx, .retention_exhausted, "estimated_tokens={d}", .{size.request_tokens orelse 0});
            return error.ContextCapacityExceeded;
        }
        trace.failure(trace_ctx, .retention_forced_zero, "estimated_tokens={d} kept_tokens={d}", .{ size.request_tokens orelse 0, kept });
        kept = 0;
    }
}

/// Splits the context: the newest turns stay unchanged, at most
/// `max_kept_turns` of them within `kept_tokens`; everything older is
/// compacted. `kept_tokens == 0` keeps nothing.
fn split(
    arena: Allocator,
    history: []const HistoryTurn,
    active: ?types.AssistantHistoryTurn,
    kept_tokens: usize,
    input_capacity: ?usize,
    route: model_provider.ProviderSelection,
) !Window {
    var combined: std.ArrayList(HistoryTurn) = .empty;
    try combined.appendSlice(arena, history);
    if (active) |turn| try combined.append(arena, .{ .assistant = turn });
    const recent: Recent = if (kept_tokens == 0)
        .{ .cut = .{ .turns = history_range.rawHistoryTurnCount(combined.items) } }
    else
        selectRecentContext(combined.items, kept_tokens, input_capacity, route, max_kept_turns);
    var cut = recent.cut;
    if (active) |turn| {
        // The unfinished turn lives outside `history`; compacting all of it
        // means cutting after its last completed exchange.
        const active_index = history_range.rawHistoryTurnCount(history);
        if (cut.turns > active_index) cut = .{
            .turns = active_index,
            .tool_steps = turn.execution.tool_steps.len,
            .steering = turn.execution.steering.len,
        };
    }
    var earlier: ?[]const u8 = null;
    for (history) |turn| {
        if (turn == .compacted_summary) earlier = turn.compacted_summary.summary;
    }
    return .{
        .earlier = earlier,
        .older = try history_range.contextHistoryRange(arena, combined.items, .{}, cut),
        .retained_history = try history_range.contextHistoryRange(arena, history, cut, null),
        .kept = try history_range.contextHistoryRange(arena, combined.items, cut, null),
        .cut = cut,
        .kept_tokens = kept_tokens,
        .kept_used = recent.tokens,
    };
}

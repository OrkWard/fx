const std = @import("std");
const types = @import("../../shared/types.zig");
const runtime_prompt_context = @import("prompt_context.zig");
const debug_trace = @import("../../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

/// The provider-neutral state for one conversation. Product session metadata,
/// persistence, permissions, credentials, and host effects live outside it.
pub const Agent = struct {
    history: std.ArrayList(types.HistoryTurn) = .empty,
    turn_usage: types.Usage = .{},
    fresh: bool = true,
    /// Last exact provider input-token usage paired with the measured request
    /// it came from. Carried across turns so the first request of a new turn
    /// calibrates from real usage instead of the raw serialization estimate.
    /// Plain value state: no allocation, no deinit work.
    request_token_calibration: ?RequestTokenCalibrationState = null,
    /// Estimated tokens of the last request's instructions and tool
    /// definitions, which compaction cannot shrink. Manual compaction sizes
    /// its result with it.
    request_fixed_tokens: ?usize = null,
    /// A request size limit learned from a provider rejection, kept for later
    /// requests to the same model in this conversation. Plain value state.
    request_byte_limit: ?RequestByteLimitState = null,

    pub fn deinit(self: *Agent, alloc: Allocator) void {
        self.clearHistory(alloc);
        self.history.deinit(alloc);
        self.* = undefined;
    }

    pub fn startTurn(self: *Agent) void {
        self.fresh = false;
        self.turn_usage = .{};
    }

    pub fn observeUsage(self: *Agent, usage: types.Usage) void {
        addOptional(&self.turn_usage.input_tokens, usage.input_tokens);
        addOptional(&self.turn_usage.output_tokens, usage.output_tokens);
        addOptional(&self.turn_usage.cache_read_tokens, usage.cache_read_tokens);
        addOptional(&self.turn_usage.cache_write_tokens, usage.cache_write_tokens);
        addOptional(&self.turn_usage.reasoning_tokens, usage.reasoning_tokens);
    }

    pub fn appendHistoryEntry(
        self: *Agent,
        alloc: Allocator,
        turn: types.HistoryTurn,
    ) Allocator.Error!void {
        const copy = try types.dupeHistoryTurn(alloc, turn);
        errdefer types.freeHistoryTurn(alloc, copy);
        try self.history.append(alloc, copy);
        self.fresh = false;
    }

    pub fn clearHistory(self: *Agent, alloc: Allocator) void {
        for (self.history.items) |turn| types.freeHistoryTurn(alloc, turn);
        self.history.clearRetainingCapacity();
        // Cleared history no longer resembles the calibrated request.
        self.request_token_calibration = null;
        self.request_byte_limit = null;
    }

    /// Returns the learned request size limit for `model`, if any.
    pub fn requestByteLimit(self: *const Agent, model: []const u8) ?usize {
        const state = self.request_byte_limit orelse return null;
        if (!std.mem.eql(u8, state.modelSlice(), model)) return null;
        return state.bytes;
    }

    /// Lowers the learned limit for `model` to `bytes`. A limit learned for
    /// another model is replaced, and an unmatchable model id is ignored.
    pub fn lowerRequestByteLimit(self: *Agent, model: []const u8, bytes: usize) void {
        if (model.len == 0 or model.len > max_request_calibration_model_bytes) {
            debug_trace.logf("agent", "request size limit not learned: unmatchable model id len={d}", .{model.len});
            return;
        }
        const limit = if (self.requestByteLimit(model)) |current| @min(current, bytes) else bytes;
        var state = RequestByteLimitState{ .model_len = model.len, .bytes = limit };
        @memcpy(state.model[0..model.len], model);
        self.request_byte_limit = state;
    }

    /// Records the calibration for later turns. An empty or oversized model
    /// id clears instead of storing a value that could never be matched.
    pub fn storeRequestTokenCalibration(
        self: *Agent,
        model: []const u8,
        cost: runtime_prompt_context.RequestTokenCalibration,
    ) void {
        if (model.len == 0 or model.len > max_request_calibration_model_bytes) {
            if (self.request_token_calibration != null)
                debug_trace.logf("agent", "dropping request token calibration: unmatchable model id len={d}", .{model.len});
            self.request_token_calibration = null;
            return;
        }
        var state = RequestTokenCalibrationState{ .model_len = model.len, .cost = cost };
        @memcpy(state.model[0..model.len], model);
        self.request_token_calibration = state;
    }

    pub fn snapshotHistory(
        self: *const Agent,
        alloc: Allocator,
    ) Allocator.Error![]types.HistoryTurn {
        const copy = try alloc.alloc(types.HistoryTurn, self.history.items.len);
        var copied: usize = 0;
        errdefer {
            for (copy[0..copied]) |turn| types.freeHistoryTurn(alloc, turn);
            alloc.free(copy);
        }
        for (self.history.items, 0..) |turn, index| {
            copy[index] = try types.dupeHistoryTurn(alloc, turn);
            copied += 1;
        }
        return copy;
    }
};

pub const RequestByteLimitState = struct {
    model: [max_request_calibration_model_bytes]u8 = undefined,
    model_len: usize = 0,
    bytes: usize = 0,

    pub fn modelSlice(self: *const RequestByteLimitState) []const u8 {
        return self.model[0..self.model_len];
    }
};

const max_request_calibration_model_bytes: usize = 128;

pub const RequestTokenCalibrationState = struct {
    model: [max_request_calibration_model_bytes]u8 = undefined,
    model_len: usize = 0,
    cost: runtime_prompt_context.RequestTokenCalibration = .{
        .request = .{ .serialized_bytes = 0, .text_tokens = 0, .estimated_input_tokens = 0 },
        .exact_input_tokens = 0,
    },

    pub fn modelSlice(self: *const RequestTokenCalibrationState) []const u8 {
        return self.model[0..self.model_len];
    }
};

fn addOptional(total: *?u64, value: ?u64) void {
    const amount = value orelse return;
    total.* = std.math.add(u64, total.* orelse 0, amount) catch std.math.maxInt(u64);
}

// In-memory ring buffer of recent gateway HTTP calls. Used by /trace
// to surface latency / error patterns without forcing a persistent trace
// log. Process-wide and lock-protected: callers do not need to plumb the
// buffer through their context.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const max_model_len: usize = 64;
pub const max_error_len: usize = 48;
pub const max_stop_reason_len: usize = 48;
pub const max_gateway_schema_diagnostic_len: usize = 160;
pub const max_gateway_request_shape_len: usize = 512;
pub const ring_capacity: usize = 32;

pub const NetworkCallKind = enum {
    gateway,
    web_search,
    web_fetch_target,
};

pub const NetworkCall = struct {
    kind: NetworkCallKind = .gateway,
    started_at_ms: i64 = 0,
    duration_ms: u32 = 0,
    status: u16 = 0,
    response_bytes: u32 = 0,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    is_web_search: bool = false,
    web_search_requests: u32 = 0,
    turn_id: u64 = 0,
    step_id: u64 = 0,
    subagent_id: u64 = 0,
    model_buf: [max_model_len]u8 = @splat(0),
    model_len: u8 = 0,
    error_buf: [max_error_len]u8 = @splat(0),
    error_len: u8 = 0,
    stop_reason_buf: [max_stop_reason_len]u8 = @splat(0),
    stop_reason_len: u8 = 0,
    gateway_schema_diagnostic_buf: [max_gateway_schema_diagnostic_len]u8 = @splat(0),
    gateway_schema_diagnostic_len: u16 = 0,
    gateway_request_shape_buf: [max_gateway_request_shape_len]u8 = @splat(0),
    gateway_request_shape_len: u16 = 0,

    pub fn model(self: *const NetworkCall) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    pub fn errorName(self: *const NetworkCall) []const u8 {
        return self.error_buf[0..self.error_len];
    }

    pub fn terminalStopReason(self: *const NetworkCall) []const u8 {
        return self.stop_reason_buf[0..self.stop_reason_len];
    }

    pub fn gatewaySchemaDiagnostic(self: *const NetworkCall) []const u8 {
        return self.gateway_schema_diagnostic_buf[0..self.gateway_schema_diagnostic_len];
    }

    pub fn gatewayRequestShape(self: *const NetworkCall) []const u8 {
        return self.gateway_request_shape_buf[0..self.gateway_request_shape_len];
    }

    pub fn setModel(self: *NetworkCall, name: []const u8) void {
        const n = @min(name.len, max_model_len);
        @memcpy(self.model_buf[0..n], name[0..n]);
        self.model_len = @intCast(n);
    }

    pub fn setError(self: *NetworkCall, name: []const u8) void {
        const n = @min(name.len, max_error_len);
        @memcpy(self.error_buf[0..n], name[0..n]);
        self.error_len = @intCast(n);
    }

    pub fn setTerminalStopReason(self: *NetworkCall, reason: []const u8) void {
        const n = @min(reason.len, max_stop_reason_len);
        @memcpy(self.stop_reason_buf[0..n], reason[0..n]);
        self.stop_reason_len = @intCast(n);
    }

    pub fn setGatewaySchemaDiagnostic(self: *NetworkCall, diagnostic: []const u8) void {
        const n = @min(diagnostic.len, max_gateway_schema_diagnostic_len);
        @memcpy(self.gateway_schema_diagnostic_buf[0..n], diagnostic[0..n]);
        self.gateway_schema_diagnostic_len = @intCast(n);
    }

    pub fn setGatewayRequestShape(self: *NetworkCall, shape: []const u8) void {
        const n = @min(shape.len, max_gateway_request_shape_len);
        @memcpy(self.gateway_request_shape_buf[0..n], shape[0..n]);
        self.gateway_request_shape_len = @intCast(n);
    }

    /// Failure predicate shared by the /trace renderer and the lifetime
    /// counters so the window and the session totals never disagree.
    pub fn isError(self: *const NetworkCall) bool {
        return self.error_len > 0 or (self.status != 0 and self.status >= 400);
    }
};

var mutex: std.Io.Mutex = .init;
var ring: [ring_capacity]NetworkCall = @splat(.{});
var head: usize = 0;
var stored: usize = 0;

/// Session-wide totals, reset on session transitions via
/// `diagnostics.resetSession()`. Unlike the ring, these never evict: the
/// /trace report must answer "did anything fail all session" even after the
/// window slides.
pub const LifetimeStats = struct {
    total_calls: u64 = 0,
    ok_calls: u64 = 0,
    error_calls: u64 = 0,
    total_duration_ms: u64 = 0,
    /// Turn buckets dropped to make room for newer ones. Zero means the
    /// rendered turns list covers every tagged turn in the session.
    evicted_turns: u64 = 0,
};

/// Bounded per-turn accounting for model calls. Turn ids increase
/// monotonically within a process, so a full table evicts the coldest turn.
pub const turn_rollup_capacity: usize = 16;

pub const TurnRollup = struct {
    turn_id: u64 = 0,
    calls: u32 = 0,
    error_calls: u32 = 0,
    subagent_calls: u32 = 0,
    total_duration_ms: u64 = 0,
    first_started_at_ms: i64 = 0,
};

var lifetime: LifetimeStats = .{};
var turn_rollups: [turn_rollup_capacity]TurnRollup = @splat(.{});
var turn_rollup_count: usize = 0;

pub fn record(call: NetworkCall) void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    ring[head] = call;
    head = (head + 1) % ring_capacity;
    if (stored < ring_capacity) stored += 1;
    recordLifetime(call);
}

fn recordLifetime(call: NetworkCall) void {
    lifetime.total_calls += 1;
    if (call.isError()) lifetime.error_calls += 1 else lifetime.ok_calls += 1;
    lifetime.total_duration_ms += call.duration_ms;
    if (call.turn_id == 0) return;
    const rollup = turnRollupFor(call.turn_id);
    rollup.calls += 1;
    if (call.isError()) rollup.error_calls += 1;
    if (call.subagent_id != 0) rollup.subagent_calls += 1;
    rollup.total_duration_ms += call.duration_ms;
    if (call.started_at_ms > 0 and
        (rollup.first_started_at_ms == 0 or call.started_at_ms < rollup.first_started_at_ms))
    {
        rollup.first_started_at_ms = call.started_at_ms;
    }
}

fn turnRollupFor(turn_id: u64) *TurnRollup {
    var oldest: usize = 0;
    var i: usize = 0;
    while (i < turn_rollup_count) : (i += 1) {
        if (turn_rollups[i].turn_id == turn_id) return &turn_rollups[i];
        if (turn_rollups[i].turn_id < turn_rollups[oldest].turn_id) oldest = i;
    }
    if (turn_rollup_count < turn_rollup_capacity) {
        defer turn_rollup_count += 1;
        turn_rollups[turn_rollup_count] = .{ .turn_id = turn_id };
        return &turn_rollups[turn_rollup_count];
    }
    lifetime.evicted_turns += 1;
    turn_rollups[oldest] = .{ .turn_id = turn_id };
    return &turn_rollups[oldest];
}

pub fn lifetimeStats() LifetimeStats {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    return lifetime;
}

/// Copies up to `out.len` most recent turn rollups, ascending by turn id.
pub fn snapshotTurnRollups(out: []TurnRollup) usize {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    var all: [turn_rollup_capacity]TurnRollup = turn_rollups;
    const count = turn_rollup_count;
    var index: usize = 1;
    while (index < count) : (index += 1) {
        const candidate = all[index];
        var insertion = index;
        while (insertion > 0 and candidate.turn_id < all[insertion - 1].turn_id) : (insertion -= 1) {
            all[insertion] = all[insertion - 1];
        }
        all[insertion] = candidate;
    }
    const n = @min(count, out.len);
    @memcpy(out[0..n], all[count - n .. count]);
    return n;
}

pub fn snapshot(out: []NetworkCall) usize {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const n = @min(stored, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = (head + ring_capacity - n + i) % ring_capacity;
        out[i] = ring[idx];
    }
    return n;
}

pub fn reset() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    head = 0;
    stored = 0;
    lifetime = .{};
    turn_rollups = @as([turn_rollup_capacity]TurnRollup, @splat(.{}));
    turn_rollup_count = 0;
}

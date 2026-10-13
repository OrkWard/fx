//! Bounded, always-on model-catalog breadcrumbs for the user-initiated
//! /trace report. Records catalog load outcomes, capability lookup misses, and
//! image gate rejections so a shared trace explains why fx could not verify a
//! model's capabilities even when FX_TRACE is off. Callers supply model slugs,
//! enum names, and internal counters only, never credentials or user prompts.
const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const ring_capacity = 32;
const max_detail_bytes = 256;

pub const Kind = enum {
    load,
    lookup,
    image_gate,
};

pub const Event = struct {
    sequence: u64 = 0,
    timestamp_ms: i64 = 0,
    failed: bool = false,
    kind: Kind = .load,
    detail_len: u16 = 0,
    truncated: bool = false,
    detail_buf: [max_detail_bytes]u8 = @splat(0),

    pub fn name(self: *const Event) []const u8 {
        return @tagName(self.kind);
    }

    pub fn detail(self: *const Event) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    fn matches(self: *const Event, kind: Kind, event_detail: []const u8, failed: bool) bool {
        return self.failed == failed and
            self.kind == kind and
            std.mem.eql(u8, self.detail(), event_detail);
    }
};

const Ring = struct {
    events: [ring_capacity]Event = std.mem.zeroes([ring_capacity]Event),
    head: usize = 0,
    stored: usize = 0,
    total: u64 = 0,

    fn append(self: *Ring, event: Event) void {
        self.total +|= 1;
        self.events[self.head] = event;
        self.events[self.head].sequence = self.total;
        self.head = (self.head + 1) % ring_capacity;
        self.stored = @min(self.stored + 1, ring_capacity);
    }

    fn newest(self: *const Ring) ?*const Event {
        if (self.stored == 0) return null;
        return &self.events[(self.head + ring_capacity - 1) % ring_capacity];
    }

    fn snapshot(self: *const Ring, out: []Event) usize {
        const count = @min(self.stored, out.len);
        for (out[0..count], 0..) |*event, index| {
            event.* = self.events[(self.head + ring_capacity - count + index) % ring_capacity];
        }
        return count;
    }
};

var mutex: std.Io.Mutex = .init;
// Zero-initialized storage stays in .bss; unused slots are never read.
var ring: Ring = std.mem.zeroes(Ring);

/// Records one catalog event. Consecutive identical events collapse into the
/// newest slot so a per-turn lookup miss cannot evict rarer load and rejection
/// evidence from the bounded ring.
pub fn record(kind: Kind, failed: bool, comptime fmt: []const u8, args: anytype) void {
    var event: Event = .{
        .timestamp_ms = io_mod.milliTimestamp(),
        .failed = failed,
        .kind = kind,
    };
    var writer: std.Io.Writer = .fixed(&event.detail_buf);
    writer.print(fmt, args) catch {
        event.truncated = true;
    };
    event.detail_len = @intCast(writer.buffered().len);
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (ring.newest()) |last| {
        if (last.matches(event.kind, event.detail(), event.failed)) return;
    }
    ring.append(event);
}

pub fn snapshot(out: []Event) usize {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return ring.snapshot(out);
}

pub fn reset() void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ring.head = 0;
    ring.stored = 0;
    ring.total = 0;
}

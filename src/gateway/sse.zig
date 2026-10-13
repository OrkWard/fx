const std = @import("std");

const Error = error{ OutOfMemory, ReadFailed, Cancelled, EventTooLarge, StreamTooLarge };

const Line = union(enum) { boundary, data: []const u8, ignored };

fn classify(line: []const u8) Line {
    if (line.len == 0) return .boundary;
    const colon = std.mem.findScalar(u8, line, ':') orelse line.len;
    if (!std.mem.eql(u8, line[0..colon], "data")) return .ignored;
    var value = if (colon < line.len) line[colon + 1 ..] else "";
    if (value.len > 0 and value[0] == ' ') value = value[1..];
    return .{ .data = value };
}

fn line_end(bytes: []const u8) usize {
    var offset: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |width| {
        const Vector = @Vector(width, u8);
        while (bytes.len - offset >= width) : (offset += width) {
            const chunk: Vector = bytes[offset..][0..width].*;
            const matches = @select(bool, chunk == @as(Vector, @splat('\r')), @as(@Vector(width, bool), @splat(true)), chunk == @as(Vector, @splat('\n')));
            if (std.simd.firstTrue(matches)) |index| return offset + index;
        }
    }
    for (bytes[offset..], offset..) |byte, index| {
        if (byte == '\r' or byte == '\n') return index;
    }
    return bytes.len;
}

/// Request-local SSE framing. The caller owns the source and all allocations.
/// Returned data is borrowed until the next next() call or deinit().
pub const Reader = struct {
    max_event_bytes: usize,
    max_total_bytes: ?usize = null,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    total_bytes: usize = 0,
    first_line: bool = true,
    skip_lf: bool = false,

    pub fn deinit(self: *Reader, alloc: std.mem.Allocator) void {
        self.line.deinit(alloc);
        self.data.deinit(alloc);
        self.* = undefined;
    }

    /// Reads through one blank-line delimiter without waiting for the next event.
    /// Cancellation is checked before reads; blocked I/O remains source-owned.
    pub fn next(self: *Reader, alloc: std.mem.Allocator, source: *std.Io.Reader, cancelled: *const std.atomic.Value(bool)) Error!?[]const u8 {
        self.data.clearRetainingCapacity();
        var saw_data = false;
        while (try self.read_line(alloc, source, cancelled)) |raw| {
            const line = if (self.first_line and std.mem.startsWith(u8, raw, "\xef\xbb\xbf")) raw[3..] else raw;
            self.first_line = false;
            switch (classify(line)) {
                .ignored => {},
                .boundary => if (saw_data) return self.data.items,
                .data => |value| {
                    if (saw_data) {
                        if (self.data.items.len == self.max_event_bytes) return error.EventTooLarge;
                        try self.data.append(alloc, '\n');
                    }
                    if (value.len > self.max_event_bytes - self.data.items.len) return error.EventTooLarge;
                    if (!saw_data and self.line.items.len > 0) {
                        // Reuse owned split-line storage instead of retaining a second large payload.
                        @memmove(self.line.items[0..value.len], value);
                        self.line.items.len = value.len;
                        std.mem.swap(std.ArrayList(u8), &self.line, &self.data);
                    } else try self.data.appendSlice(alloc, value);
                    saw_data = true;
                },
            }
        }
        // EOF is not an event delimiter; consumers still require terminal proof.
        return null;
    }

    fn consume(self: *Reader, source: *std.Io.Reader, count: usize) Error!void {
        if (self.max_total_bytes) |limit| {
            if (count > limit - self.total_bytes) return error.StreamTooLarge;
            self.total_bytes += count;
        }
        source.toss(count);
    }

    fn read_line(self: *Reader, alloc: std.mem.Allocator, source: *std.Io.Reader, cancelled: *const std.atomic.Value(bool)) Error!?[]const u8 {
        self.line.clearRetainingCapacity();
        while (true) {
            if (cancelled.load(.seq_cst)) return error.Cancelled;
            var bytes = source.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return null,
                error.ReadFailed => return error.ReadFailed,
            };
            if (cancelled.load(.seq_cst)) return error.Cancelled;
            if (self.skip_lf) {
                self.skip_lf = false;
                if (bytes[0] == '\n') {
                    try self.consume(source, 1);
                    bytes = bytes[1..];
                    if (bytes.len == 0) continue;
                }
            }
            const end = line_end(bytes);
            if (end > self.max_event_bytes - self.line.items.len) return error.EventTooLarge;
            if (end < bytes.len) {
                self.skip_lf = bytes[end] == '\r';
                try self.consume(source, end + 1);
                if (self.line.items.len == 0) return bytes[0..end];
                try self.line.appendSlice(alloc, bytes[0..end]);
                return self.line.items;
            }
            try self.consume(source, end);
            try self.line.appendSlice(alloc, bytes);
        }
    }
};

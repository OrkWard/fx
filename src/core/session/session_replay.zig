const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_codec = @import("session_codec.zig");
const session_event = @import("session_event.zig");

const Allocator = std.mem.Allocator;
const Identifier = session_event.Identifier;

pub const CommitPosition = struct {
    log_generation: Identifier,
    through_seq: u64,
    through_event_id: Identifier,
    through_event_log_bytes: u64,
};

pub const LineRead = struct {
    bytes: []u8,
    next_offset: u64,
};

/// Returns an owned line, borrowing the caller's positional reader and buffer.
/// Read-ahead stays within the supplied committed boundary.
pub fn readBufferedLine(
    alloc: Allocator,
    reader: *std.Io.File.Reader,
    max_end: u64,
    cancelled: ?*const std.atomic.Value(bool),
) !?LineRead {
    if (cancelled) |stop| if (stop.load(.acquire)) return error.Cancelled;
    if (reader.logicalPos() >= max_end) return null;
    std.debug.assert(reader.interface.buffer.len > 0);
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    while (reader.logicalPos() < max_end) {
        if (cancelled) |stop| if (stop.load(.acquire)) return error.Cancelled;
        if (reader.interface.bufferedLen() == 0) {
            const buffer = reader.interface.buffer;
            reader.interface = std.Io.File.Reader.initInterface(buffer[0..@intCast(@min(
                buffer.len,
                max_end - reader.logicalPos(),
            ))]);
            defer reader.interface.buffer = buffer;
            reader.interface.fill(1) catch |err| switch (err) {
                error.EndOfStream => {
                    if (line.items.len == 0) return null;
                    return error.TruncatedEventFrame;
                },
                error.ReadFailed => return reader.err orelse error.ReadFailed,
            };
        }
        const buffered = reader.interface.buffered();
        const bytes = buffered[0..@intCast(@min(buffered.len, max_end - reader.logicalPos()))];
        const newline = std.mem.findScalar(u8, bytes, '\n');
        const count = if (newline) |end| end + 1 else bytes.len;
        try line.appendSlice(alloc, bytes[0..count]);
        reader.interface.toss(count);
        if (line.items.len > session_event.event_frame_max_bytes) return error.EventFrameTooLarge;
        if (newline != null) return .{
            .bytes = try line.toOwnedSlice(alloc),
            .next_offset = reader.logicalPos(),
        };
    }
    return error.TruncatedEventFrame;
}

pub fn readLineAt(
    alloc: Allocator,
    file: std.Io.File,
    offset: u64,
    max_end: u64,
) !?LineRead {
    return readLineAtWithCancellation(alloc, file, offset, max_end, null);
}

fn readLineAtWithCancellation(
    alloc: Allocator,
    file: std.Io.File,
    offset: u64,
    max_end: u64,
    cancelled: ?*const std.atomic.Value(bool),
) !?LineRead {
    if (cancelled) |stop| {
        if (stop.load(.acquire)) return error.Cancelled;
    }
    if (offset >= max_end) return null;
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    var cursor = offset;
    var chunk: [8192]u8 = undefined;
    while (cursor < max_end) {
        if (cancelled) |stop| {
            if (stop.load(.acquire)) return error.Cancelled;
        }
        const limit = @min(@as(u64, chunk.len), max_end - cursor);
        const count = try file.readPositionalAll(
            io_mod.getIo(),
            chunk[0..@intCast(limit)],
            cursor,
        );
        if (count == 0) {
            if (line.items.len == 0) return null;
            return error.TruncatedEventFrame;
        }
        if (std.mem.findScalar(u8, chunk[0..count], '\n')) |newline| {
            try line.appendSlice(alloc, chunk[0 .. newline + 1]);
            cursor += newline + 1;
            if (line.items.len > session_event.event_frame_max_bytes) {
                return error.EventFrameTooLarge;
            }
            return .{
                .bytes = try line.toOwnedSlice(alloc),
                .next_offset = cursor,
            };
        }
        try line.appendSlice(alloc, chunk[0..count]);
        if (line.items.len > session_event.event_frame_max_bytes) {
            return error.EventFrameTooLarge;
        }
        cursor += count;
    }
    return error.TruncatedEventFrame;
}

pub fn readFirstGeneration(alloc: Allocator, file: std.Io.File) !Identifier {
    var envelope = try readSessionStarted(alloc, file);
    defer envelope.deinit(alloc);
    return envelope.log_generation;
}

/// Reads the child identity only when the first event ends within
/// `max_bytes` of the log start. A real first event arrives in one positional
/// read, so the cost never grows with the log; a longer or unterminated first
/// line fails with `error.TruncatedEventFrame`.
pub fn readSubagentChildIdentityWithin(
    alloc: Allocator,
    file: std.Io.File,
    max_bytes: usize,
) !bool {
    const buffer = try alloc.alloc(u8, max_bytes);
    defer alloc.free(buffer);
    var filled: usize = 0;
    const line_end: ?usize = while (filled < buffer.len) {
        const count = try file.readPositional(io_mod.getIo(), &.{buffer[filled..]}, filled);
        if (count == 0) break null;
        const start = filled;
        filled += count;
        if (std.mem.findScalar(u8, buffer[start..filled], '\n')) |newline| break start + newline + 1;
    } else null;
    const end = line_end orelse {
        if (filled == 0) return error.InvalidSessionFormat;
        return error.TruncatedEventFrame;
    };
    var envelope = try decodeSessionStarted(alloc, buffer[0..end]);
    defer envelope.deinit(alloc);
    return envelope.event.session_started.subagent_child;
}

fn readSessionStarted(alloc: Allocator, file: std.Io.File) !session_event.Envelope {
    const length = try file.length(io_mod.getIo());
    const first = try readLineAt(alloc, file, 0, length) orelse
        return error.InvalidSessionFormat;
    defer alloc.free(first.bytes);
    return decodeSessionStarted(alloc, first.bytes);
}

fn decodeSessionStarted(alloc: Allocator, bytes: []const u8) !session_event.Envelope {
    var envelope = session_event.decodeFrame(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedEventSchema => return error.UnsupportedSessionSchema,
        else => return error.InvalidSessionFormat,
    };
    errdefer envelope.deinit(alloc);
    if (envelope.seq != 1 or envelope.kind() != .session_started) {
        return error.InvalidSessionFormat;
    }
    return envelope;
}

/// Owns `state`; callers must call `deinit` or transfer it with `takeState`.
pub const ExactReplay = struct {
    state: session_codec.DurableSessionState,
    position: CommitPosition,

    pub fn deinit(self: *ExactReplay, alloc: Allocator) void {
        self.state.deinit(alloc);
        self.* = undefined;
    }

    pub fn takeState(self: *ExactReplay) session_codec.DurableSessionState {
        const state = self.state;
        self.* = undefined;
        return state;
    }
};

inline fn failExactReplay(err: anytype) @TypeOf(err)!ExactReplay {
    return @errorCast(failExactReplayDynamic(err));
}

noinline fn failExactReplayDynamic(err: anyerror) anyerror!ExactReplay {
    return err;
}

/// Replays an explicitly committed prefix while ignoring later bytes. This is
/// used only by the read-only legacy importer; current sessions never need a
/// watermark or a generation boundary.
pub fn replayCommittedPrefix(
    alloc: Allocator,
    file: std.Io.File,
    expected_generation: Identifier,
    expected_seq: u64,
    expected_bytes: u64,
) !ExactReplay {
    return replayPosition(
        alloc,
        file,
        expected_generation,
        expected_seq,
        expected_bytes,
        false,
    );
}

fn replayPosition(
    alloc: Allocator,
    file: std.Io.File,
    expected_generation: Identifier,
    expected_seq: u64,
    expected_bytes: u64,
    require_exact_length: bool,
) !ExactReplay {
    const file_bytes = try file.length(io_mod.getIo());
    if (expected_bytes == 0 or file_bytes < expected_bytes or
        (require_exact_length and file_bytes != expected_bytes))
    {
        return failExactReplay(error.InvalidSessionFormat);
    }
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io_mod.getIo(), &file_buffer);
    var limit_buffer: [4096]u8 = undefined;
    var limited = file_reader.interface.limited(
        .limited64(expected_bytes),
        &limit_buffer,
    );
    var reduction = session_event.reduceJsonl(
        alloc,
        &limited.interface,
        null,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.ReadFailed => return err,
        error.UnsupportedEventSchema => return failExactReplay(error.UnsupportedSessionSchema),
        else => return failExactReplay(error.InvalidSessionFormat),
    };
    errdefer reduction.deinit(alloc);
    const through = reduction.through orelse return failExactReplay(error.InvalidSessionFormat);
    if (reduction.truncate_from != null or
        reduction.bytes_consumed != expected_bytes or
        through.byte_offset != expected_bytes or
        through.seq != expected_seq or
        !std.mem.eql(u8, &through.log_generation, &expected_generation))
    {
        return failExactReplay(error.InvalidSessionFormat);
    }
    const state = reduction.state;
    reduction.state = undefined;
    return .{
        .state = state,
        .position = .{
            .log_generation = through.log_generation,
            .through_seq = through.seq,
            .through_event_id = through.event_id,
            .through_event_log_bytes = through.byte_offset,
        },
    };
}

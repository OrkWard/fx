//! Program Status Protocol (OSC 7501) reports for the interactive shell.
//!
//! fx tells the terminal whether it is idle, working, waiting on the user,
//! finished, or failed. Terminals that do not implement the protocol ignore
//! the sequence, so reports need no feature detection. Specification:
//! https://www.superlogical.com/rex/docs/build/program-status

const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const compaction_activity = @import("../../core/output/compaction_activity.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const types = @import("../../core/shared/types.zig");

/// Removes every record on the terminal, not only fx's. fx reports on the
/// root record while it owns the terminal, and writes this when it exits or
/// suspends.
pub const clear_sequence = prefix ++ "state=clear" ++ terminator;

const prefix = "\x1b]7501;";
const terminator = "\x1b\\";
const app_name = "fx";
/// Keeps `msg` to one short line. The protocol allows 2048 decoded bytes.
const max_message_bytes = 256;
const base64 = std.base64.standard.Encoder;
const max_report_bytes = prefix.len +
    "state=blocked:kind=permission:app=".len + app_name.len + ":msg=".len +
    base64.calcSize(max_message_bytes) + terminator.len;

const BlockedKind = enum { permission, question };

pub const Activity = union(enum) {
    /// Waiting on the user. `message` borrows untrusted text for this call
    /// and is reduced to one line without control characters before encoding.
    blocked: struct { kind: BlockedKind, message: []const u8 },
    working,
    /// Nothing is running; the last finished turn decides what to report.
    settled,
};

const Settled = enum { idle, done, @"error" };

/// Owned by the UI thread. Keeps the last report so unchanged activity is
/// not written to the terminal again on every loop iteration.
pub const Reporter = struct {
    settled: Settled = .idle,
    /// Set once a settled report carried `settled`. Work that starts no turn,
    /// such as `/compact`, then settles as idle instead of repeating a result
    /// the user already saw.
    settled_reported: bool = false,
    /// The activity snapshot keeps a settled `/compact` until the footer
    /// dismisses it, so each operation's result is noted once.
    noted_compaction: ?compaction_activity.OperationId = null,
    last: [max_report_bytes]u8 = undefined,
    last_len: usize = 0,

    /// A new turn must not report an earlier turn's result once it settles.
    pub fn noteTurnStarted(self: *Reporter) void {
        self.settle(.idle);
    }

    pub fn noteTurnFinished(self: *Reporter, outcome: types.TurnPresentationOutcome) void {
        self.settle(switch (outcome) {
            .completed => .done,
            .failed => .@"error",
            // A cancelled or paused turn, usually paused by the user during a
            // recovery, waits for the next instruction. The protocol reports
            // that as idle.
            .interrupted, .paused => .idle,
        });
    }

    /// Records a request failure that ended without a turn outcome.
    pub fn noteFailure(self: *Reporter) void {
        self.settle(.@"error");
    }

    /// Records the result of a manual `/compact`, which runs without a turn.
    /// Compaction inside a turn is part of that turn's outcome.
    pub fn noteCompaction(self: *Reporter, snapshot: compaction_activity.Snapshot) void {
        const operation = snapshot.operation orelse return;
        if (operation.origin != .manual) return;
        const feedback = switch (operation.phase) {
            .terminal => |value| value,
            .preparing, .running, .stopping => return,
        };
        if (self.noted_compaction == operation.id) return;
        self.noted_compaction = operation.id;
        switch (feedback.outcome) {
            .succeeded => self.settle(.done),
            .failed => self.settle(.@"error"),
            .cancelled => self.settle(.idle),
            // Nothing ran, so there is no result to report.
            .no_op, .busy => {},
        }
    }

    /// Sends the next report even when it matches the last one, for example
    /// after the terminal dropped fx's record while fx was suspended. A
    /// result that was already reported comes back as idle.
    pub fn invalidate(self: *Reporter) void {
        self.last_len = 0;
        if (self.settled_reported) self.settle(.idle);
    }

    /// Returns the report to write when it differs from the last one. The
    /// slice borrows `self` until the next call.
    pub fn update(self: *Reporter, activity: Activity) ?[]const u8 {
        // A new result is news even when it matches the last report, such as
        // a second failure in a row.
        var new_result = false;
        switch (activity) {
            .settled => {
                new_result = !self.settled_reported and self.settled != .idle;
                self.settled_reported = true;
            },
            .working, .blocked => if (self.settled_reported) self.settle(.idle),
        }
        var buffer: [max_report_bytes]u8 = undefined;
        const report = encode(&buffer, activity, self.settled) orelse {
            debug_trace.logf("program_status", "report dropped activity={s} reason=too_long", .{@tagName(activity)});
            return null;
        };
        if (!new_result and std.mem.eql(u8, self.last[0..self.last_len], report)) return null;
        @memcpy(self.last[0..report.len], report);
        self.last_len = report.len;
        return self.last[0..self.last_len];
    }

    fn settle(self: *Reporter, next: Settled) void {
        self.settled = next;
        self.settled_reported = false;
    }
};

/// Returns null when the report does not fit `max_report_bytes`.
fn encode(buffer: *[max_report_bytes]u8, activity: Activity, settled: Settled) ?[]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writeReport(&writer, activity, settled) catch return null;
    return writer.buffered();
}

fn writeReport(w: *std.Io.Writer, activity: Activity, settled: Settled) std.Io.Writer.Error!void {
    try w.writeAll(prefix ++ "state=");
    switch (activity) {
        .blocked => |blocked| try w.print("blocked:kind={s}", .{@tagName(blocked.kind)}),
        .working => try w.writeAll("working"),
        .settled => try w.writeAll(@tagName(settled)),
    }
    // Each report replaces its record, so every report repeats `app`.
    try w.writeAll(":app=" ++ app_name);
    if (activity == .blocked) {
        var message_buffer: [max_message_bytes]u8 = undefined;
        const message = oneLineMessage(activity.blocked.message, &message_buffer);
        if (message.len > 0) {
            var encoded: [base64.calcSize(max_message_bytes)]u8 = undefined;
            try w.writeAll(":msg=");
            try w.writeAll(base64.encode(&encoded, message));
        }
    }
    try w.writeAll(terminator);
}

/// Terminals discard a report whose message contains a control character, so
/// whitespace and control runs collapse to one space and invalid UTF-8 is
/// dropped. Long text ends with "..." within `max_message_bytes`.
fn oneLineMessage(raw: []const u8, buffer: *[max_message_bytes]u8) []const u8 {
    const marker = "...";
    var written: usize = 0;
    var space_pending = false;
    var index: usize = 0;
    while (index < raw.len) {
        const sequence_len: usize = std.unicode.utf8ByteSequenceLength(raw[index]) catch {
            index += 1;
            continue;
        };
        if (raw.len - index < sequence_len) break;
        const sequence = raw[index .. index + sequence_len];
        const codepoint = display_width.decodeUtf8Sequence(sequence) catch {
            index += 1;
            continue;
        };
        index += sequence_len;
        if (codepoint <= ' ' or (codepoint >= 0x7f and codepoint <= 0x9f)) {
            space_pending = written > 0;
            continue;
        }
        const separator_len: usize = @intFromBool(space_pending);
        if (written + separator_len + sequence_len > buffer.len) {
            written = text_utils.utf8BackwardBoundary(buffer[0..written], buffer.len - marker.len);
            @memcpy(buffer[written .. written + marker.len], marker);
            written += marker.len;
            break;
        }
        if (space_pending) {
            buffer[written] = ' ';
            written += 1;
            space_pending = false;
        }
        @memcpy(buffer[written .. written + sequence_len], sequence);
        written += sequence_len;
    }
    return buffer[0..written];
}

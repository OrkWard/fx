const debug_trace = @import("../core/shared/debug_trace.zig");
const record_tape = @import("../core/workspace/record_tape.zig");

pub const EventLoopCallbacks = struct {
    ctx: *anyopaque,
    collect_facts: *const fn (*anyopaque) anyerror!void,
    next_collected_byte: *const fn (*anyopaque) ?u8,
    handle_byte: *const fn (*anyopaque, u8) anyerror!void,
    settle_delivery_epoch: *const fn (*anyopaque) anyerror!void,
    commit_frame: *const fn (*anyopaque) anyerror!void,
    poll_timeout_ms: ?*const fn (*anyopaque, i32) i32 = null,
};

const max_input_reads_per_fact_collection = 32;

fn attemptFinalFrameCommit(callbacks: EventLoopCallbacks, reason: []const u8) void {
    callbacks.commit_frame(callbacks.ctx) catch |err| debug_trace.logf(
        "event_loop",
        "final_frame_commit_failed reason={s} err={s}",
        .{ reason, @errorName(err) },
    );
}

pub const ExitCause = enum {
    requested_exit,
    input_closed,
};

pub fn run(terminal: anytype, should_exit: *bool, poll_timeout_ms: i32, callbacks: EventLoopCallbacks) !ExitCause {
    var buf: [128]u8 = undefined;

    while (!should_exit.*) {
        try callbacks.collect_facts(callbacks.ctx);
        if (should_exit.*) return .requested_exit;

        while (callbacks.next_collected_byte(callbacks.ctx)) |byte| {
            try callbacks.handle_byte(callbacks.ctx, byte);
            if (should_exit.*) return .requested_exit;
        }

        const timeout_ms = if (callbacks.poll_timeout_ms) |resolve|
            resolve(callbacks.ctx, poll_timeout_ms)
        else
            poll_timeout_ms;
        var poll_result = try terminal.pollInput(timeout_ms);
        var input_reads: usize = 0;
        while (poll_result.readable and input_reads < max_input_reads_per_fact_collection) : (input_reads += 1) {
            const read_len = try terminal.read(&buf);
            if (read_len == 0) {
                if (input_reads > 0) attemptFinalFrameCommit(callbacks, "eof");
                return .input_closed;
            }

            record_tape.recordStdin(buf[0..read_len]);
            for (buf[0..read_len]) |byte| {
                try callbacks.handle_byte(callbacks.ctx, byte);
                if (should_exit.*) return .requested_exit;
            }
            poll_result = try terminal.pollInput(0);
        }

        if (poll_result.readable) {
            try callbacks.commit_frame(callbacks.ctx);
            continue;
        }
        if (poll_result.closed()) {
            if (input_reads > 0) attemptFinalFrameCommit(callbacks, "hangup");
            return .input_closed;
        }

        try callbacks.settle_delivery_epoch(callbacks.ctx);
        try callbacks.commit_frame(callbacks.ctx);
    }
    return .requested_exit;
}

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const command_contract = @import("command_contract.zig");
const command_environment = @import("command_environment.zig");
const process_tree = @import("process_tree.zig");
const io_mod = @import("../shared/io.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const self_exe = @import("../shared/self_exe.zig");
const config_runtime = @import("../config/config_runtime.zig");
const session_child_store = @import("../session/session_child_store.zig");
const artifact_digest = @import("../session/artifact_digest.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");
const shell_snapshot = @import("../terminal/shell_snapshot.zig");
const darwin_process_spawn = @import("../shared/darwin_process_spawn.zig");

const Allocator = std.mem.Allocator;
pub const CommandOutputStream = command_contract.CommandOutputStream;
pub const CommandOutputCallback = command_contract.CommandOutputCallback;
pub const CommandExecutionResult = command_contract.RunCommandResult;

/// Foreground command execution configuration. Borrowed slices and callbacks
/// must remain valid for the duration of executeCommand.
pub const Config = struct {
    max_command_output_bytes: usize,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    force_cancel_flag: ?*std.atomic.Value(bool) = null,
    output_chunk_lifecycle_id: ?types.ToolLifecycleId = null,
    output_chunk_ctx: ?*anyopaque = null,
    on_output_chunk: ?CommandOutputCallback = null,
    accepted_output_chunk_ctx: ?*anyopaque = null,
    on_accepted_output_chunk: ?CommandOutputCallback = null,
    callback_projection: CallbackProjection = .model_safe,
    timeout_ms: ?usize = null,
    timeout_started_ms: ?i64 = null,
    command_artifact_capability: ?*session_child_store.SessionChildCapability = null,
    command_artifact_dir: ?[]const u8 = null,
    /// Shell snapshot epoch of the remembered grant that admitted a `user`
    /// profile command, or null when it was not admitted by a grant.
    shell_grant_epoch: ?u64 = null,
};

const ai_agent_env = "AI_AGENT";
const ai_agent_name = "fx";

pub fn applyAgentEnvironment(environment: *std.process.Environ.Map) !void {
    try environment.put(ai_agent_env, ai_agent_name);
}

pub const CallbackProjection = enum {
    model_safe,
    raw,
};

const command_artifact_file_prefix = "fx-command-";
const command_artifact_fallback_dir_name = "fx-command-output";
const command_artifact_log_suffix = ".log";
const command_artifact_stdout_suffix = ".stdout.log";
const command_artifact_stderr_suffix = ".stderr.log";
const pending_output_flush_bytes: usize = 4096;
/// Idle wait between stop checks while capturing output. Reads return as soon
/// as output arrives, so this bounds only how long a silent command takes to
/// observe a cancel or force-kill request.
const capture_stop_poll_ms: i64 = 20;
/// After a command finishes on its own, capture keeps reading its leftover
/// output until it has waited this long in total for more. Leftover output is
/// already in the pipes and reads without waiting, so time spent delivering it
/// never ends the drain. Only a detached daemon that kept a pipe open can keep
/// the pipes from reaching end of file, and this bounds waiting on it.
const natural_completion_wait_ms: i64 = 1_000;
/// Live delivery of drained output ends this long after a natural completion,
/// so a reader too slow to keep up with a detached writer cannot hold the
/// call. Capture keeps reading and collecting the output after that.
const natural_completion_live_ms: i64 = 10_000;
/// Most output capture reads after a natural completion. A finished command
/// leaves at most one pipe buffer per stream behind, and Linux lets a pipe
/// buffer grow to 1 MiB by default, so reading this much means the command's
/// own output is done and a detached process is still writing.
const natural_completion_drain_max_bytes: usize = 2 * 1024 * 1024;
pub const termination_settle_timeout_ms: i64 = 5_000;
pub const supports_foreground_session = builtin.link_libc and
    std.process.can_spawn and
    std.process.can_replace and
    builtin.target.os.tag != .windows and
    builtin.target.os.tag != .wasi;
const foreground_session_token = "__fx_foreground_session__";
const foreground_session_ready_byte: u8 = 0x1e;
const foreground_session_release_byte: u8 = 0x06;
const foreground_session_setup_timeout_ms: i64 = 5000;
const foreground_target_termination_grace_ms: i64 = 700;
const foreground_target_cleanup_wait_ms: i64 = 250;
const foreground_supervisor_handoff_ms: i64 = 200;
const foreground_session_replace_failure_exit_code: u8 = 125;
const foreground_session_failure_nonce_bytes: usize = 16;
const foreground_session_failure_nonce_hex_bytes: usize = foreground_session_failure_nonce_bytes * 2;
const foreground_session_script_length_bytes = @sizeOf(u64);
const foreground_session_release_index = foreground_session_failure_nonce_hex_bytes;
const foreground_session_script_length_index = foreground_session_release_index + 1;
const foreground_session_control_bytes = foreground_session_script_length_index +
    foreground_session_script_length_bytes;
const foreground_session_replace_failure_prefix = "\x00FX_FOREGROUND_EXEC_FAILED:";
const foreground_session_replace_failure_marker_bytes =
    foreground_session_replace_failure_prefix.len +
    foreground_session_failure_nonce_hex_bytes + 1;
const foreground_session_force_signal = std.posix.SIG.USR1;
const ForegroundSessionTerminationRequest = enum(std.c.sig_atomic_t) {
    none,
    graceful,
    force,
};
var foreground_session_termination_request: std.c.sig_atomic_t =
    @backingInt(ForegroundSessionTerminationRequest.none);
const foreground_session_replace_error_name_bytes = blk: {
    var max_len: usize = 0;
    for (@typeInfo(std.process.ReplaceError).error_set.error_names.?) |error_name| {
        max_len = @max(max_len, error_name.len);
    }
    break :blk max_len;
};
const script_from_stdin_launcher =
    "script=$(command cat; command printf .)\n" ++
    "script=${script%.}\n" ++
    "eval \"$script\" </dev/null";

pub fn isForegroundSessionInvocation(args: []const [:0]const u8) bool {
    if (comptime !supports_foreground_session) return false;
    return args.len > 0 and std.mem.eql(u8, args[0], foreground_session_token);
}

fn readForegroundSessionInputExact(buffer: []u8) !void {
    const zio = io_mod.getIo();
    var offset: usize = 0;
    while (offset < buffer.len) {
        const read_len = std.Io.File.stdin().readStreaming(
            zio,
            &.{buffer[offset..]},
        ) catch |err| switch (err) {
            error.EndOfStream => return error.InvalidForegroundSessionRelease,
            else => |read_err| return read_err,
        };
        if (read_len == 0) return error.InvalidForegroundSessionRelease;
        offset += read_len;
    }
}

pub fn runForegroundSessionBootstrap(args: []const [:0]const u8) !void {
    if (comptime !supports_foreground_session) {
        return error.OperationUnsupported;
    }
    if (!isForegroundSessionInvocation(args) or args.len < 3) {
        return error.InvalidForegroundSessionInvocation;
    }
    const deadline_ms = if (std.mem.eql(u8, args[1], "none"))
        null
    else
        std.fmt.parseInt(i64, args[1], 10) catch
            return error.InvalidForegroundSessionInvocation;
    const command_session = std.c.setsid();
    if (command_session == -1) return error.ForegroundSessionSetupFailed;

    const zio = io_mod.getIo();
    try std.Io.File.stderr().writeStreamingAll(
        zio,
        &.{foreground_session_ready_byte},
    );

    var control: [foreground_session_control_bytes]u8 = undefined;
    try readForegroundSessionInputExact(&control);
    const failure_nonce = control[0..foreground_session_failure_nonce_hex_bytes];
    if (control[foreground_session_release_index] != foreground_session_release_byte) {
        return error.InvalidForegroundSessionRelease;
    }
    const script_len = std.math.cast(usize, std.mem.readInt(
        u64,
        control[foreground_session_script_length_index..][0..foreground_session_script_length_bytes],
        .little,
    )) orelse {
        writeForegroundSessionReplaceFailure(
            failure_nonce,
            error.InvalidForegroundSessionScriptLength,
        );
        std.process.exit(foreground_session_replace_failure_exit_code);
    };
    const script = std.heap.page_allocator.alloc(u8, script_len) catch |err| {
        writeForegroundSessionReplaceFailure(failure_nonce, err);
        std.process.exit(foreground_session_replace_failure_exit_code);
    };
    defer std.heap.page_allocator.free(script);
    readForegroundSessionInputExact(script) catch |err| {
        writeForegroundSessionReplaceFailure(failure_nonce, err);
        std.process.exit(foreground_session_replace_failure_exit_code);
    };

    @as(*volatile std.c.sig_atomic_t, &foreground_session_termination_request).* =
        @backingInt(ForegroundSessionTerminationRequest.none);
    const supervisor_action: std.posix.Sigaction = .{
        .handler = .{ .handler = recordForegroundSessionTermination },
        .mask = foregroundSupervisorSignalMask(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &supervisor_action, null);
    std.posix.sigaction(foreground_session_force_signal, &supervisor_action, null);
    if (comptime builtin.target.os.tag == .linux) {
        _ = try std.posix.prctl(.SET_CHILD_SUBREAPER, .{@as(usize, 1)});
    }
    var process_witness: ?process_tree.DarwinProcessWitness =
        if (comptime builtin.target.os.tag == .macos)
            try .init()
        else
            null;
    defer if (process_witness) |*witness| witness.deinit();
    const spawn_options: std.process.SpawnOptions = .{
        .argv = args[2..],
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
        .start_suspended = builtin.target.os.tag == .macos,
    };
    var target = (if (comptime builtin.target.os.tag == .macos)
        darwin_process_spawn.spawn_inheriting_fd(
            zio,
            spawn_options,
            process_witness.?.childFd(),
        )
    else
        std.process.spawn(zio, spawn_options)) catch |err| {
        writeForegroundSessionReplaceFailure(failure_nonce, err);
        std.process.exit(foreground_session_replace_failure_exit_code);
    };
    if (process_witness) |*witness| witness.closeChildCopy();
    var target_input = target.stdin orelse {
        target.kill(zio);
        writeForegroundSessionReplaceFailure(
            failure_nonce,
            error.ForegroundTargetInputMissing,
        );
        std.process.exit(foreground_session_replace_failure_exit_code);
    };
    target.stdin = null;
    var script_writer: ?std.Thread = null;
    if (script.len <= foreground_session_inline_script_bytes) {
        target_input.writeStreamingAll(zio, script) catch |err| {
            target_input.close(zio);
            target.kill(zio);
            writeForegroundSessionReplaceFailure(failure_nonce, err);
            std.process.exit(foreground_session_replace_failure_exit_code);
        };
        target_input.close(zio);
    } else {
        // A large script can exceed the pipe buffer, and on macOS the target
        // stays suspended until waitForForegroundTarget resumes it, so it is
        // written while the target runs. The target already exec'd with the
        // default SIGPIPE disposition; ignoring it here only keeps a target
        // that stops reading from killing the supervisor.
        const ignore_action: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.PIPE, &ignore_action, null);
        script_writer = std.Thread.spawn(
            .{},
            writeForegroundTargetScript,
            .{ target_input, script },
        ) catch |err| {
            target_input.close(zio);
            target.kill(zio);
            writeForegroundSessionReplaceFailure(failure_nonce, err);
            std.process.exit(foreground_session_replace_failure_exit_code);
        };
    }
    const term = waitForForegroundTarget(
        &target,
        if (process_witness) |*witness| witness else null,
        deadline_ms,
        command_session,
    ) catch |err| {
        target.kill(zio);
        writeForegroundSessionReplaceFailure(failure_nonce, err);
        std.process.exit(foreground_session_replace_failure_exit_code);
    };
    // The target has exited, so the writer finished or saw a broken pipe.
    if (script_writer) |writer| writer.join();
    exitForegroundSessionSupervisor(term);
}

/// Scripts up to this size fit in any pipe buffer, so they are written before
/// the target is resumed.
const foreground_session_inline_script_bytes: usize = 4096;

fn writeForegroundTargetScript(target_input: std.Io.File, script: []const u8) void {
    const zio = io_mod.getIo();
    target_input.writeStreamingAll(zio, script) catch |err| {
        debug_trace.logf("core", "foreground session script write stopped err={s}", .{@errorName(err)});
    };
    target_input.close(zio);
}

fn recordForegroundSessionTermination(signal: std.posix.SIG) callconv(.c) void {
    const request = @as(*volatile std.c.sig_atomic_t, &foreground_session_termination_request);
    request.* = @backingInt(mergeForegroundSessionTerminationRequest(
        @fromBackingInt(@intCast(request.*)),
        signal,
    ));
}

fn foregroundSupervisorSignalMask() std.posix.sigset_t {
    var mask = std.posix.sigemptyset();
    std.posix.sigaddset(&mask, std.posix.SIG.TERM);
    std.posix.sigaddset(&mask, foreground_session_force_signal);
    return mask;
}

fn mergeForegroundSessionTerminationRequest(
    current: ForegroundSessionTerminationRequest,
    signal: std.posix.SIG,
) ForegroundSessionTerminationRequest {
    if (current == .force or signal == foreground_session_force_signal) return .force;
    if (current == .none and signal == std.posix.SIG.TERM) return .graceful;
    return current;
}

fn foregroundSessionTerminationRequest() ForegroundSessionTerminationRequest {
    return @fromBackingInt(@intCast(
        @as(*volatile std.c.sig_atomic_t, &foreground_session_termination_request).*,
    ));
}

const ForegroundTerminationAction = enum {
    none,
    begin_graceful,
    force,
};

fn decideForegroundTerminationAction(
    request: ForegroundSessionTerminationRequest,
    termination_started_ms: ?i64,
    forced: bool,
    now_ms: i64,
) ForegroundTerminationAction {
    if (forced or request == .none) return .none;
    if (request == .force) return .force;
    const started_ms = termination_started_ms orelse return .begin_graceful;
    if (now_ms >= started_ms and
        now_ms - started_ms >= foreground_target_termination_grace_ms)
    {
        return .force;
    }
    return .none;
}

fn foregroundRequestAtDeadline(
    observed: ForegroundSessionTerminationRequest,
    owner_alive: bool,
    deadline_ms: ?i64,
    now_ms: i64,
) ForegroundSessionTerminationRequest {
    if (!owner_alive) return .force;
    if (observed != .none) return observed;
    const deadline = deadline_ms orelse return .none;
    return if (now_ms >= deadline) .force else .none;
}

fn foregroundSessionOwnerAlive() bool {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    return (std.posix.poll(&poll_fds, 0) catch return false) == 0;
}

const ChildWaiter = struct {
    child: *std.process.Child,
    io: std.Io,
    ready: std.atomic.Value(bool) = .init(false),
    result: std.process.Child.WaitError!std.process.Child.Term = undefined,
    /// When the wait returned. Valid once `ready` is observed.
    completed_ms: i64 = 0,
    future: ?std.Io.Future(void) = null,

    fn init(child: *std.process.Child) ChildWaiter {
        return .{
            .child = child,
            .io = io_mod.getIo(),
        };
    }

    fn start(self: *ChildWaiter) !void {
        self.future = try std.Io.concurrent(
            self.io,
            ChildWaiter.waitMain,
            .{self},
        );
    }

    fn waitMain(self: *ChildWaiter) void {
        self.result = self.child.wait(self.io);
        self.completed_ms = io_mod.milliTimestamp();
        self.ready.store(true, .release);
    }

    fn isReady(self: *const ChildWaiter) bool {
        return self.ready.load(.acquire);
    }

    fn awaitReady(self: *ChildWaiter) !std.process.Child.Term {
        std.debug.assert(self.isReady());
        var future = &self.future.?;
        future.await(self.io);
        return try self.result;
    }

    fn awaitDiscard(self: *ChildWaiter) void {
        var future = &self.future.?;
        future.await(self.io);
    }

    fn abort(self: *ChildWaiter, pid: std.posix.pid_t) void {
        if (self.isReady()) {
            self.awaitDiscard();
            return;
        }
        signalProcess(pid, std.posix.SIG.KILL) catch {};
        self.awaitDiscard();
    }
};

fn waitForForegroundTarget(
    target: *std.process.Child,
    process_witness: ?*const process_tree.DarwinProcessWitness,
    deadline_ms: ?i64,
    command_session: std.posix.pid_t,
) !std.process.Child.Term {
    const target_pid = target.id orelse return error.ForegroundTargetMissing;
    var descendants = try process_tree.Tracker.init(std.heap.page_allocator);
    defer descendants.deinit();
    if (process_witness) |witness| {
        descendants.bindProcessWitness(witness);
    }
    if (comptime builtin.target.os.tag == .macos) {
        try descendants.refresh(target_pid);
        try std.posix.kill(target_pid, std.posix.SIG.CONT);
    }
    var waiter = ChildWaiter.init(target);
    try waiter.start();
    var wait_pending = true;
    defer if (wait_pending) waiter.abort(target_pid);
    var termination_started_ms: ?i64 = null;
    var forced = false;
    var owner_alive = true;

    while (true) {
        const now_ms = io_mod.milliTimestamp();
        if (owner_alive and !foregroundSessionOwnerAlive()) {
            owner_alive = false;
            debug_trace.logf(
                "core",
                "captured command owner liveness closed; forcing process tree cleanup",
                .{},
            );
        }
        const request = foregroundRequestAtDeadline(
            foregroundSessionTerminationRequest(),
            owner_alive,
            deadline_ms,
            now_ms,
        );
        if (request == .force) {
            @as(*volatile std.c.sig_atomic_t, &foreground_session_termination_request).* =
                @backingInt(ForegroundSessionTerminationRequest.force);
        }
        try refreshForegroundTargetTree(&descendants, target_pid);
        advanceForegroundTargetTermination(
            &descendants,
            request,
            now_ms,
            &termination_started_ms,
            &forced,
        );

        if (waiter.isReady()) {
            wait_pending = false;
            const term = try waiter.awaitReady();
            try refreshForegroundTargetTree(&descendants, target_pid);
            advanceForegroundTargetTermination(
                &descendants,
                foregroundSessionTerminationRequest(),
                io_mod.milliTimestamp(),
                &termination_started_ms,
                &forced,
            );
            if (termination_started_ms) |started_ms| {
                try waitForForegroundTargetDescendants(
                    &descendants,
                    target_pid,
                    started_ms,
                    &forced,
                );
                return term;
            }
            const cleanup = try cleanupCompletedForegroundTarget(
                &descendants,
                target_pid,
                command_session,
            );
            if (cleanup.terminated > 0 or cleanup.kept_detached > 0 or cleanup.incomplete) {
                debug_trace.logf(
                    "core",
                    "captured command target completed; tracked descendants terminated count={d} detached daemons kept count={d} incomplete={s}",
                    .{
                        cleanup.terminated,
                        cleanup.kept_detached,
                        if (cleanup.incomplete) "true" else "false",
                    },
                );
            }
            return term;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
}

const CompletedTargetCleanup = struct {
    terminated: usize = 0,
    kept_detached: usize = 0,
    /// The latest pass could not inspect or signal every tracked process.
    incomplete: bool = false,

    fn record(self: *CompletedTargetCleanup, delivery: process_tree.CompletionDelivery) void {
        self.terminated += delivery.delivery.delivered;
        self.kept_detached = delivery.kept_detached;
        self.incomplete = delivery.delivery.incomplete;
    }
};

/// Stops what a naturally completed command left in its session. Daemons
/// that moved to their own session keep running, so background servers that
/// tools start survive between calls. Cancellation, timeout, and owner loss
/// still stop them.
fn cleanupCompletedForegroundTarget(
    descendants: *process_tree.Tracker,
    target_pid: std.posix.pid_t,
    command_session: std.posix.pid_t,
) !CompletedTargetCleanup {
    const started_ms = io_mod.milliTimestamp();
    var cleanup: CompletedTargetCleanup = .{};
    var empty_scans: u8 = 0;
    while (io_mod.milliTimestamp() - started_ms <
        foreground_target_cleanup_wait_ms)
    {
        try refreshForegroundTargetTree(descendants, target_pid);
        cleanup.record(descendants.signalAttached(std.posix.SIG.KILL, command_session));
        if (descendants.anyAttachedAlive(command_session)) {
            empty_scans = 0;
        } else {
            empty_scans += 1;
            if (empty_scans >= 2) return cleanup;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
    try refreshForegroundTargetTree(descendants, target_pid);
    cleanup.record(descendants.signalAttached(std.posix.SIG.KILL, command_session));
    return cleanup;
}

fn refreshForegroundTargetTree(
    descendants: *process_tree.Tracker,
    target_pid: std.posix.pid_t,
) !void {
    try descendants.refresh(target_pid);
    if (comptime builtin.target.os.tag == .linux) {
        try descendants.refreshAdditionalRoot(std.c.getpid());
    }
    if (comptime builtin.target.os.tag == .macos) {
        if (foregroundSessionTerminationRequest() != .none) {
            try descendants.refreshLineageProcesses();
        }
    }
}

fn advanceForegroundTargetTermination(
    descendants: *process_tree.Tracker,
    request: ForegroundSessionTerminationRequest,
    now_ms: i64,
    termination_started_ms: *?i64,
    forced: *bool,
) void {
    switch (decideForegroundTerminationAction(
        request,
        termination_started_ms.*,
        forced.*,
        now_ms,
    )) {
        .none => {},
        .begin_graceful => {
            termination_started_ms.* = now_ms;
            const count = descendants.signalOutsideProcessGroup(
                std.posix.SIG.TERM,
                std.c.getpid(),
            );
            debug_trace.logf(
                "core",
                "captured command termination reached tracked descendants count={d}",
                .{count},
            );
        },
        .force => {
            if (termination_started_ms.* == null) termination_started_ms.* = now_ms;
            forced.* = true;
            forceKillForegroundTargetDescendants(descendants);
        },
    }
}

fn waitForForegroundTargetDescendants(
    descendants: *process_tree.Tracker,
    target_pid: std.posix.pid_t,
    termination_started_ms: i64,
    forced: *bool,
) !void {
    var empty_scans: u8 = 0;
    while (true) {
        try refreshForegroundTargetTree(descendants, target_pid);
        const now_ms = io_mod.milliTimestamp();
        if (!forced.* and
            now_ms - termination_started_ms >= foreground_target_termination_grace_ms)
        {
            forced.* = true;
            forceKillForegroundTargetDescendants(descendants);
        }
        if (forced.*) {
            _ = descendants.signalAll(std.posix.SIG.KILL);
        }
        if (descendants.anyAlive()) {
            empty_scans = 0;
        } else {
            empty_scans += 1;
            if (empty_scans >= 2) return;
        }
        if (forced.* and
            now_ms - termination_started_ms >=
                foreground_target_termination_grace_ms + foreground_target_cleanup_wait_ms)
        {
            return;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
}

fn forceKillForegroundTargetDescendants(
    descendants: *process_tree.Tracker,
) void {
    const count = descendants.signalAll(std.posix.SIG.KILL);
    debug_trace.logf(
        "core",
        "captured command force-killed tracked descendants count={d}",
        .{count},
    );
}

fn writeForegroundSessionReplaceFailure(
    nonce: []const u8,
    err: anyerror,
) void {
    var buffer: [256]u8 = undefined;
    const message = std.mem.print(
        &buffer,
        foreground_session_replace_failure_prefix ++ "{s}:{s}\n",
        .{ nonce, @errorName(err) },
    ) catch foreground_session_replace_failure_prefix ++ "unknown\n";
    std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), message) catch {};
}

fn exitForegroundSessionSupervisor(term: std.process.Child.Term) noreturn {
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal => |signal| {
            if (signal != std.posix.SIG.KILL and signal != std.posix.SIG.STOP) {
                const default_action: std.posix.Sigaction = .{
                    .handler = .{ .handler = std.posix.SIG.DFL },
                    .mask = std.posix.sigemptyset(),
                    .flags = 0,
                };
                std.posix.sigaction(signal, &default_action, null);
            }
            var signal_mask = std.posix.sigemptyset();
            std.posix.sigaddset(&signal_mask, signal);
            std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &signal_mask, null);
            std.posix.raise(signal) catch {};
            std.process.exit(128 + @as(u8, @truncate(@backingInt(signal))));
        },
        .stopped, .unknown => std.process.exit(127),
    }
}

/// Executes one command and returns an owned formatted result.
pub fn executeCommand(
    cfg: Config,
    arena: Allocator,
    command: []const u8,
    cwd: []const u8,
) !command_contract.RunCommandResult {
    var scratch_state = std.heap.ArenaAllocator.init(arena);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    var effective_cfg = cfg;
    if (effective_cfg.timeout_started_ms == null) effective_cfg.timeout_started_ms = io_mod.milliTimestamp();
    try ExecutionControl.init(effective_cfg).check();
    return executeRawBash(arena, scratch, effective_cfg, command, cwd);
}

pub fn executeCommandInEnvironment(
    cfg: Config,
    arena: Allocator,
    command: []const u8,
    cwd: []const u8,
    environment: command_environment.Environment,
) !command_contract.RunCommandResult {
    switch (environment) {
        .legacy => return executeCommand(cfg, arena, command, cwd),
        .workspace_clean => return error.InvalidCommandEnvironment,
        .clean, .user => {},
    }

    var scratch_state = std.heap.ArenaAllocator.init(arena);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    var effective_cfg = cfg;
    if (effective_cfg.timeout_started_ms == null) effective_cfg.timeout_started_ms = io_mod.milliTimestamp();
    try ExecutionControl.init(effective_cfg).check();
    switch (environment) {
        .user => |shell_path| if (snapshotEligible(shell_path, command)) {
            if (try executeWithSnapshot(arena, scratch, effective_cfg, command, cwd, shell_path)) |result| {
                return result;
            }
        },
        else => {},
    }
    const invocation = try shell_resolver.capturedInvocation(scratch, environment, command);
    debug_trace.logf(
        "core",
        "command runner explicit environment={s} shell={s}",
        .{ @tagName(std.meta.activeTag(environment)), invocation.path },
    );
    return executeRawInvocation(
        arena,
        scratch,
        effective_cfg,
        command,
        cwd,
        &invocation,
    );
}

fn snapshotEligible(shell_path: []const u8, command: []const u8) bool {
    if (comptime !shell_snapshot.isSupported() or !supports_foreground_session) return false;
    // A NUL cannot travel through the stdin script; keep today's argv path,
    // which rejects it at spawn.
    return shell_resolver.shellKind(shell_path) != null and
        std.mem.findScalar(u8, command, 0) == null;
}

/// The result for a command whose remembered approval predates a shell
/// refresh. Nothing ran; requesting the command again asks for approval.
fn approvalResetResult(
    arena: Allocator,
    command: []const u8,
    cwd: []const u8,
) !command_contract.RunCommandResult {
    debug_trace.logf("core", "command runner rejected stale shell approval", .{});
    return formatOutputWithStatus(
        arena,
        command,
        cwd,
        .{ .exit_code = 126 },
        "",
        "fx did not run this command: the shell startup files changed after it was approved. Request it again to ask for approval.\n",
        null,
        false,
    );
}

/// Runs a `user` profile command in a clean shell restored from the process
/// snapshot. Returns null when the command must use full startup instead:
/// no snapshot is available, or its replay failed before the command started.
fn executeWithSnapshot(
    arena: Allocator,
    scratch: Allocator,
    cfg: Config,
    command: []const u8,
    cwd: []const u8,
    shell_path: []const u8,
) !?command_contract.RunCommandResult {
    const owner = shell_snapshot.processOwner();
    const acquired = owner.acquire(shell_path, cwd, .{
        .cancel_flag = cfg.cancel_flag,
        .deadline_ms = ExecutionControl.init(cfg).deadlineMs(),
    }) catch |err| return switch (err) {
        error.Cancelled => error.CancelledBeforeExecution,
        error.TimeoutExpired => error.TimeoutExpired,
    };
    const lease = switch (acquired) {
        .snapshot => |value| value,
        .full_startup => {
            if (cfg.shell_grant_epoch) |epoch| {
                if (epoch != owner.approvalEpoch()) return try approvalResetResult(arena, command, cwd);
            }
            return null;
        },
    };
    defer lease.release();
    const generation = lease.generation;
    if (cfg.shell_grant_epoch) |epoch| {
        if (epoch != generation.epoch) return try approvalResetResult(arena, command, cwd);
    }

    var nonce_raw: [foreground_session_failure_nonce_bytes]u8 = undefined;
    io_mod.getIo().random(&nonce_raw);
    const nonce = std.fmt.bytesToHex(nonce_raw, .lower);
    const failure_marker = try std.mem.concat(scratch, u8, &.{
        shell_resolver.snapshot_replay_failure_prefix,
        &nonce,
    });
    const invocation = try shell_resolver.snapshotInvocation(scratch, generation.shell_path, failure_marker);
    const script = try shell_resolver.snapshotScript(scratch, generation.replay, command);
    debug_trace.logf(
        "core",
        "command runner snapshot generation={d} shell={s} replay_bytes={d}",
        .{ generation.id, generation.shell_path, generation.replay.len },
    );
    const result = try executeProcessWithScript(
        scratch,
        cfg,
        invocation.argv(),
        cwd,
        script,
        &generation.environ,
    );
    if (snapshotReplayFailed(result, failure_marker)) {
        // The replay stopped before the command started, so the command has
        // not run. Fail this snapshot and let the caller run it once with
        // full startup.
        debug_trace.logf(
            "core",
            "command runner snapshot replay failed generation={d}; rerunning with full startup",
            .{generation.id},
        );
        owner.markReplayFailed(generation);
        return null;
    }
    return try formatCollectedOutput(arena, command, cwd, result);
}

fn snapshotReplayFailed(result: CollectedProcess, failure_marker: []const u8) bool {
    return switch (result.status) {
        .exit_code => |code| code == shell_snapshot_replay_failure_exit_code and
            std.mem.find(u8, result.stderr, failure_marker) != null,
        else => false,
    };
}

const shell_snapshot_replay_failure_exit_code: i64 = 125;

const ExecutionControl = struct {
    cancel_flag: ?*std.atomic.Value(bool),
    timeout_ms: ?usize,
    started_ms: i64,

    fn init(cfg: Config) ExecutionControl {
        return .{
            .cancel_flag = cfg.cancel_flag,
            .timeout_ms = cfg.timeout_ms,
            .started_ms = cfg.timeout_started_ms orelse io_mod.milliTimestamp(),
        };
    }

    fn check(self: ExecutionControl) !void {
        if (cancelRequested(self.cancel_flag)) return error.CancelledBeforeExecution;
        if (self.timeout_ms) |timeout_ms| {
            const now_ms = io_mod.milliTimestamp();
            const elapsed_ms: u64 = if (now_ms > self.started_ms) @intCast(now_ms - self.started_ms) else 0;
            if (elapsed_ms >= timeout_ms) return error.TimeoutExpired;
        }
    }

    fn deadlineMs(self: ExecutionControl) ?i64 {
        const timeout_ms = self.timeout_ms orelse return null;
        const timeout_i64 = std.math.cast(i64, timeout_ms) orelse return std.math.maxInt(i64);
        const sum = @addWithOverflow(self.started_ms, timeout_i64);
        return if (sum[1] == 0) sum[0] else std.math.maxInt(i64);
    }
};

fn foreground_supervisor_fallback_deadline_ms(deadline_ms: ?i64) ?i64 {
    const deadline = deadline_ms orelse return null;
    return deadline +| foreground_supervisor_handoff_ms;
}

fn cancelRequested(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.seq_cst) else false;
}

fn emitAcceptedOutputChunk(
    cfg: Config,
    stream: CommandOutputStream,
    bytes: []const u8,
) !void {
    if (bytes.len == 0) return;
    const ctx = cfg.accepted_output_chunk_ctx orelse return;
    const callback = cfg.on_accepted_output_chunk orelse return;
    try callback(ctx, cfg.output_chunk_lifecycle_id, stream, bytes);
}

const CollectedProcess = struct {
    status: command_contract.CommandStatus,
    output_incomplete: bool = false,
    stdout: []const u8,
    stderr: []const u8,
    stdout_bytes: usize,
    stderr_bytes: usize,
    duration_ms: ?u64 = null,
    truncated: bool = false,
    output_file: ?[]const u8 = null,
    stdout_file: ?[]const u8 = null,
    stderr_file: ?[]const u8 = null,
    stdout_preview: StreamPreviewSnapshot = .{},
    stderr_preview: StreamPreviewSnapshot = .{},
    cancelled: bool = false,
};

const StreamPreviewSnapshot = struct {
    head: []const u8 = "",
    tail: []const u8 = "",
    total_bytes: usize = 0,
    max_bytes: usize = 0,
};

const StreamPreview = struct {
    max_bytes: usize,
    head_limit: usize,
    tail_limit: usize,
    total_bytes: usize = 0,
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,

    fn init(max_bytes: usize) StreamPreview {
        const head_limit = if (max_bytes == 0) 0 else (max_bytes + 1) / 2;
        return .{
            .max_bytes = max_bytes,
            .head_limit = head_limit,
            .tail_limit = if (max_bytes > head_limit) max_bytes - head_limit else 0,
        };
    }

    fn deinit(self: *StreamPreview, alloc: Allocator) void {
        self.head.deinit(alloc);
        self.tail.deinit(alloc);
        self.* = undefined;
    }

    fn append(self: *StreamPreview, alloc: Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        self.total_bytes += bytes.len;

        if (self.head.items.len < self.head_limit) {
            const take = @min(self.head_limit - self.head.items.len, bytes.len);
            try self.head.appendSlice(alloc, bytes[0..take]);
        }

        if (self.tail_limit == 0) return;
        try self.appendTail(alloc, bytes);
    }

    fn appendTail(self: *StreamPreview, alloc: Allocator, bytes: []const u8) !void {
        if (bytes.len >= self.tail_limit) {
            self.tail.clearRetainingCapacity();
            try self.tail.appendSlice(alloc, bytes[bytes.len - self.tail_limit ..]);
            return;
        }

        if (self.tail.items.len + bytes.len > self.tail_limit) {
            const drop = self.tail.items.len + bytes.len - self.tail_limit;
            const keep = self.tail.items.len - drop;
            @memmove(self.tail.items[0..keep], self.tail.items[drop..]);
            self.tail.items.len = keep;
        }
        try self.tail.appendSlice(alloc, bytes);
    }

    fn snapshot(self: *StreamPreview, alloc: Allocator) !StreamPreviewSnapshot {
        return .{
            .head = try self.head.toOwnedSlice(alloc),
            .tail = try self.tail.toOwnedSlice(alloc),
            .total_bytes = self.total_bytes,
            .max_bytes = self.max_bytes,
        };
    }
};

const ArtifactFile = union(enum) {
    external: std.Io.File,
    managed: session_child_store.ManagedFile,

    fn writeAll(self: *ArtifactFile, bytes: []const u8) !void {
        switch (self.*) {
            .external => |file| try file.writeStreamingAll(io_mod.getIo(), bytes),
            .managed => |*file| try file.writeAll(bytes),
        }
    }

    fn sync(self: *ArtifactFile) !void {
        switch (self.*) {
            .external => |file| try file.sync(io_mod.getIo()),
            .managed => |*file| try file.sync(),
        }
    }

    fn close(self: *ArtifactFile) void {
        switch (self.*) {
            .external => |file| file.close(io_mod.getIo()),
            .managed => |*file| file.deinit(),
        }
    }
};

const CommandArtifact = struct {
    output_file: []const u8,
    stdout_file: []const u8,
    stderr_file: []const u8,
    output: ArtifactFile,
    stdout: ArtifactFile,
    stderr: ArtifactFile,
    managed_capability: ?*session_child_store.SessionChildCapability = null,
    output_hasher: std.crypto.hash.sha2.Sha256 =
        std.crypto.hash.sha2.Sha256.init(.{}),

    fn append(self: *CommandArtifact, stream: CommandOutputStream, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.output.writeAll(bytes);
        switch (stream) {
            .stdout => try self.stdout.writeAll(bytes),
            .stderr => try self.stderr.writeAll(bytes),
        }
        self.output_hasher.update(bytes);
    }

    fn close(self: *CommandArtifact) void {
        self.output.close();
        self.stdout.close();
        self.stderr.close();
    }

    fn sync(self: *CommandArtifact) !void {
        try self.output.sync();
        try self.stdout.sync();
        try self.stderr.sync();
    }

    fn contentAddressManagedOutput(
        self: *CommandArtifact,
        alloc: Allocator,
    ) !void {
        const capability = self.managed_capability orelse return;
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        var hasher = self.output_hasher;
        hasher.final(&digest);
        const source_handle = std.Io.Dir.path.basename(self.output_file);
        const target_handle = try artifact_digest.contentAddressedHandle(
            alloc,
            source_handle,
            command_artifact_log_suffix,
            digest,
        );
        defer alloc.free(target_handle);
        const parent = std.Io.Dir.path.dirname(self.output_file) orelse
            return error.InvalidCommandArtifactPath;
        const target_path = try std.Io.Dir.path.join(
            alloc,
            &.{ parent, target_handle },
        );
        errdefer alloc.free(target_path);
        capability.rename(
            .command_artifacts,
            source_handle,
            target_handle,
        ) catch |err| {
            if (err == error.SessionChildCommitIndeterminate and
                try capability.confirmIndeterminateEntry(
                    .command_artifacts,
                    target_handle,
                ))
            {
                self.output_file = target_path;
                debug_trace.logf(
                    "core",
                    "command artifact rename durability confirmed handle={s}",
                    .{target_handle},
                );
                return;
            }
            return err;
        };
        self.output_file = target_path;
    }
};

const OutputCollector = struct {
    alloc: Allocator,
    cfg: Config,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_preview: StreamPreview,
    stderr_preview: StreamPreview,
    stdout_bytes: usize = 0,
    stderr_bytes: usize = 0,
    artifact: ?CommandArtifact = null,

    fn init(alloc: Allocator, cfg: Config) OutputCollector {
        const preview_limit = streamPreviewLimit(cfg.max_command_output_bytes);
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .stdout_preview = StreamPreview.init(preview_limit),
            .stderr_preview = StreamPreview.init(preview_limit),
        };
    }

    fn deinit(self: *OutputCollector) void {
        if (self.artifact) |*artifact| artifact.close();
        self.stdout.deinit(self.alloc);
        self.stderr.deinit(self.alloc);
        self.stdout_preview.deinit(self.alloc);
        self.stderr_preview.deinit(self.alloc);
        self.* = undefined;
    }

    fn append(self: *OutputCollector, stream: CommandOutputStream, bytes: []const u8) !void {
        if (bytes.len == 0) return;

        switch (stream) {
            .stdout => {
                self.stdout_bytes += bytes.len;
                try self.stdout_preview.append(self.alloc, bytes);
            },
            .stderr => {
                self.stderr_bytes += bytes.len;
                try self.stderr_preview.append(self.alloc, bytes);
            },
        }

        if (self.artifact) |*artifact| {
            try artifact.append(stream, bytes);
            return;
        }

        switch (stream) {
            .stdout => try self.stdout.appendSlice(self.alloc, bytes),
            .stderr => try self.stderr.appendSlice(self.alloc, bytes),
        }

        if (self.totalBytes() > self.cfg.max_command_output_bytes) {
            try self.startArtifact();
        }
    }

    fn finish(
        self: *OutputCollector,
        status: command_contract.CommandStatus,
        output_incomplete: bool,
    ) !CollectedProcess {
        if (self.artifact) |*artifact| {
            try artifact.sync();
            try artifact.contentAddressManagedOutput(self.alloc);
            const truncated = self.totalBytes() > self.cfg.max_command_output_bytes;
            return .{
                .status = status,
                .output_incomplete = output_incomplete,
                .stdout = "",
                .stderr = "",
                .stdout_bytes = self.stdout_bytes,
                .stderr_bytes = self.stderr_bytes,
                .truncated = truncated,
                .output_file = artifact.output_file,
                .stdout_file = artifact.stdout_file,
                .stderr_file = artifact.stderr_file,
                .stdout_preview = if (truncated) try self.stdout_preview.snapshot(self.alloc) else .{},
                .stderr_preview = if (truncated) try self.stderr_preview.snapshot(self.alloc) else .{},
            };
        }

        return .{
            .status = status,
            .output_incomplete = output_incomplete,
            .stdout = try self.stdout.toOwnedSlice(self.alloc),
            .stderr = try self.stderr.toOwnedSlice(self.alloc),
            .stdout_bytes = self.stdout_bytes,
            .stderr_bytes = self.stderr_bytes,
        };
    }

    fn totalBytes(self: OutputCollector) usize {
        return self.stdout_bytes + self.stderr_bytes;
    }

    fn startArtifact(self: *OutputCollector) !void {
        if (self.artifact != null) return;
        var artifact = try createCommandArtifact(
            self.alloc,
            self.cfg.command_artifact_capability,
            self.cfg.command_artifact_dir,
        );
        errdefer artifact.close();
        try artifact.append(.stdout, self.stdout.items);
        try artifact.append(.stderr, self.stderr.items);
        debug_trace.logf(
            "core",
            "command output artifact created output_file={s} stdout_file={s} stderr_file={s} stdout_bytes={d} stderr_bytes={d}",
            .{ artifact.output_file, artifact.stdout_file, artifact.stderr_file, self.stdout_bytes, self.stderr_bytes },
        );
        self.stdout.clearRetainingCapacity();
        self.stderr.clearRetainingCapacity();
        self.artifact = artifact;
    }
};

fn finishCollectedProcess(
    output: *OutputCollector,
    status: command_contract.CommandStatus,
    output_incomplete: bool,
    duration_ms: u64,
    source: TerminationSource,
    preserve_cancelled_status: bool,
) !CollectedProcess {
    switch (source) {
        .timed_out => return error.TimeoutExpired,
        .natural => {},
        .cancelled => {
            if (!preserve_cancelled_status and output.totalBytes() == 0) {
                return error.Cancelled;
            }
            if (output.totalBytes() != 0 and output.artifact == null) {
                output.startArtifact() catch |err| {
                    debug_trace.logf("core", "cancelled command artifact promotion failed err={s}", .{@errorName(err)});
                    return error.Cancelled;
                };
            }
        },
    }

    var result = output.finish(status, output_incomplete) catch |err| {
        if (source != .cancelled) return err;
        debug_trace.logf("core", "cancelled command artifact finalization failed err={s}", .{@errorName(err)});
        return error.Cancelled;
    };
    result.duration_ms = duration_ms;
    result.cancelled = source == .cancelled;
    return result;
}

fn executeProcess(scratch: Allocator, cfg: Config, argv: []const []const u8, cwd: []const u8) !CollectedProcess {
    return executeProcessWithInput(scratch, cfg, argv, cwd, false, true);
}

fn executeProcessWithInput(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
    closed_input: bool,
    isolate_process_group: bool,
) !CollectedProcess {
    const started_ms = io_mod.milliTimestamp();
    var environment = try io_mod.cloneEnvironMap(scratch);
    defer environment.deinit();
    try applyAgentEnvironment(&environment);
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = if (closed_input) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = cwd },
        .environ_map = &environment,
        .pgid = if (isolate_process_group and builtin.target.os.tag != .windows) 0 else null,
    });
    if (child.stdin) |input| {
        input.close(io_mod.getIo());
        child.stdin = null;
    }

    var output = OutputCollector.init(scratch, cfg);
    defer output.deinit();

    var child_needs_cleanup = true;
    errdefer if (child_needs_cleanup) cleanupChild(&child);

    const process_group_id = if (isolate_process_group and builtin.target.os.tag != .windows)
        child.id
    else
        null;
    child_needs_cleanup = false;
    const collected = try collectSpawnedProcess(
        scratch,
        &child,
        &output,
        cfg,
        null,
        process_group_id,
        .process_group,
    );
    const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());

    return finishCollectedProcess(
        &output,
        collected.status,
        collected.output_incomplete,
        duration_ms,
        collected.source,
        cfg.force_cancel_flag != null,
    );
}

/// `environ_map` replaces the inherited environment for the command when set.
fn executeProcessWithScript(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
    script: []const u8,
    environ_map: ?*const std.process.Environ.Map,
) !CollectedProcess {
    var environment = if (environ_map) |map|
        try map.clone(scratch)
    else
        try io_mod.cloneEnvironMap(scratch);
    defer environment.deinit();
    try applyAgentEnvironment(&environment);
    if (comptime supports_foreground_session) {
        return executeProcessWithDetachedSession(
            scratch,
            cfg,
            argv,
            cwd,
            script,
            &environment,
        );
    }
    return executeProcessWithScriptUnisolated(
        scratch,
        cfg,
        argv,
        cwd,
        script,
        &environment,
    );
}

const ForegroundSessionPhase = enum {
    pre_ready,
    group_ready,
};

fn executeProcessWithDetachedSession(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
    script: []const u8,
    environ_map: ?*const std.process.Environ.Map,
) !CollectedProcess {
    const executable = try foregroundSessionExecutable(scratch);
    var nonce_bytes: [foreground_session_failure_nonce_bytes]u8 = undefined;
    io_mod.getIo().random(&nonce_bytes);
    const nonce = std.fmt.bytesToHex(nonce_bytes, .lower);
    var failure_marker: [foreground_session_replace_failure_marker_bytes]u8 = undefined;
    @memcpy(
        failure_marker[0..foreground_session_replace_failure_prefix.len],
        foreground_session_replace_failure_prefix,
    );
    @memcpy(
        failure_marker[foreground_session_replace_failure_prefix.len..][0..nonce.len],
        &nonce,
    );
    failure_marker[failure_marker.len - 1] = ':';

    var helper_argv: std.ArrayList([]const u8) = .empty;
    try helper_argv.append(scratch, executable);
    try helper_argv.append(scratch, foreground_session_token);
    const deadline_ms = ExecutionControl.init(cfg).deadlineMs();
    const supervisor_deadline_ms = foreground_supervisor_fallback_deadline_ms(deadline_ms);
    const deadline_text = if (supervisor_deadline_ms) |value|
        try scratch.print("{d}", .{value})
    else
        "none";
    try helper_argv.append(scratch, deadline_text);
    try helper_argv.appendSlice(scratch, argv);

    const started_ms = io_mod.milliTimestamp();
    // The supervisor passes its environment through to the target shell.
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = helper_argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = cwd },
        .environ_map = environ_map,
    });

    var output = OutputCollector.init(scratch, cfg);
    defer output.deinit();

    var phase: ForegroundSessionPhase = .pre_ready;
    var child_needs_cleanup = true;
    errdefer if (child_needs_cleanup) {
        cleanupForegroundSessionChild(&child, phase);
    };

    try waitForForegroundSessionReady(&child, cfg);
    phase = .group_ready;
    try ExecutionControl.init(cfg).check();

    const script_write = child.stdin orelse return error.SpawnFailed;
    child.stdin = null;
    defer script_write.close(io_mod.getIo());

    var script_length: [foreground_session_script_length_bytes]u8 = undefined;
    std.mem.writeInt(u64, &script_length, @intCast(script.len), .little);
    try script_write.writeStreamingAll(io_mod.getIo(), &nonce);
    try script_write.writeStreamingAll(
        io_mod.getIo(),
        &.{foreground_session_release_byte},
    );
    try script_write.writeStreamingAll(io_mod.getIo(), &script_length);
    try script_write.writeStreamingAll(io_mod.getIo(), script);

    var launch_failure_probe = ForegroundLaunchFailureProbe.init(&failure_marker);
    const process_group_id = child.id;
    child_needs_cleanup = false;
    var collected = try collectSpawnedProcess(
        scratch,
        &child,
        &output,
        cfg,
        &launch_failure_probe,
        process_group_id,
        .foreground_supervisor,
    );
    // Judge the deadline at the supervisor's exit, not after the output drain.
    collected.source = reconcileForegroundTerminationSource(
        collected.source,
        deadline_ms,
        collected.natural_completion_ms orelse io_mod.milliTimestamp(),
    );
    const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());

    if (foregroundSessionReplacementError(
        collected.status,
        launch_failure_probe,
    )) |launch_err| return launch_err;
    return finishCollectedProcess(
        &output,
        collected.status,
        collected.output_incomplete,
        duration_ms,
        collected.source,
        cfg.force_cancel_flag != null,
    );
}

/// Starts `argv` in a new session through the foreground supervisor, so it
/// has no controlling terminal: an interactive login shell can neither stop
/// on nor draw over the terminal fx runs in. The target's stdin is empty;
/// stdout and stderr are pipes. `child.stdin` stays open as the supervisor's
/// lifeline: closing it ends the session. The caller owns the child and its
/// process group.
pub fn spawnDetachedSession(
    scratch: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    environ_map: ?*const std.process.Environ.Map,
) !std.process.Child {
    if (comptime !supports_foreground_session) return error.OperationUnsupported;
    const executable = try foregroundSessionExecutable(scratch);
    var helper_argv: std.ArrayList([]const u8) = .empty;
    try helper_argv.appendSlice(scratch, &.{ executable, foreground_session_token, "none" });
    try helper_argv.appendSlice(scratch, argv);
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = helper_argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = cwd },
        .environ_map = environ_map,
    });
    var phase: ForegroundSessionPhase = .pre_ready;
    errdefer cleanupForegroundSessionChild(&child, phase);
    try waitForForegroundSessionReady(&child, .{ .max_command_output_bytes = 0 });
    phase = .group_ready;

    const input = child.stdin orelse return error.SpawnFailed;
    var nonce_bytes: [foreground_session_failure_nonce_bytes]u8 = undefined;
    io_mod.getIo().random(&nonce_bytes);
    const nonce = std.fmt.bytesToHex(nonce_bytes, .lower);
    var control: [foreground_session_control_bytes]u8 = undefined;
    @memcpy(control[0..nonce.len], &nonce);
    control[foreground_session_release_index] = foreground_session_release_byte;
    std.mem.writeInt(
        u64,
        control[foreground_session_script_length_index..][0..foreground_session_script_length_bytes],
        0,
        .little,
    );
    try input.writeStreamingAll(io_mod.getIo(), &control);
    return child;
}

fn foregroundSessionExecutable(scratch: Allocator) ![]const u8 {
    return self_exe.pathForReexec(scratch);
}

fn waitForForegroundSessionReady(
    child: *std.process.Child,
    cfg: Config,
) !void {
    const ready_read = child.stderr orelse return error.SpawnFailed;
    const setup_started_ms = io_mod.milliTimestamp();
    const control = ExecutionControl.init(cfg);

    while (true) {
        try control.check();
        const now_ms = io_mod.milliTimestamp();
        const setup_elapsed_ms = if (now_ms > setup_started_ms)
            now_ms - setup_started_ms
        else
            0;
        if (setup_elapsed_ms >= foreground_session_setup_timeout_ms) {
            return error.ForegroundSessionSetupTimedOut;
        }

        const remaining_ms = foreground_session_setup_timeout_ms - setup_elapsed_ms;
        const poll_timeout_ms: i32 = @intCast(@min(@as(i64, 50), remaining_ms));
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = ready_read.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, poll_timeout_ms) == 0) continue;

        const revents = poll_fds[0].revents;
        if ((revents & std.posix.POLL.IN) != 0) {
            var marker: [1]u8 = undefined;
            const marker_len = try std.posix.read(ready_read.handle, &marker);
            if (marker_len == 0) return error.ForegroundSessionSetupFailed;
            if (marker[0] != foreground_session_ready_byte) {
                return error.InvalidForegroundSessionReady;
            }
            return;
        }
        if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            return error.ForegroundSessionSetupFailed;
        }
    }
}

fn cleanupForegroundSessionChild(
    child: *std.process.Child,
    phase: ForegroundSessionPhase,
) void {
    if (comptime !supports_foreground_session) {
        cleanupChild(child);
        return;
    }
    const pid = child.id orelse return;
    const target_pid = switch (phase) {
        .pre_ready => pid,
        .group_ready => -pid,
    };
    std.posix.kill(target_pid, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => debug_trace.logf(
            "core",
            "foreground session cleanup kill failed phase={s} err={s}",
            .{ @tagName(phase), @errorName(err) },
        ),
    };
    _ = child.wait(io_mod.getIo()) catch |err| {
        debug_trace.logf(
            "core",
            "foreground session cleanup wait failed phase={s} err={s}",
            .{ @tagName(phase), @errorName(err) },
        );
    };
}

fn foregroundSessionReplacementError(
    status: command_contract.CommandStatus,
    probe: ForegroundLaunchFailureProbe,
) ?(std.process.ReplaceError || error{CommandLaunchFailed}) {
    switch (status) {
        .exit_code => |code| if (code != foreground_session_replace_failure_exit_code) return null,
        else => return null,
    }
    if (probe.status != .failed) return null;
    return probe.replacement_error orelse error.CommandLaunchFailed;
}

fn executeProcessWithScriptUnisolated(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
    script: []const u8,
    environ_map: ?*const std.process.Environ.Map,
) !CollectedProcess {
    const started_ms = io_mod.milliTimestamp();
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = cwd },
        .pgid = if (builtin.target.os.tag != .windows) 0 else null,
        .environ_map = environ_map,
    });

    var output = OutputCollector.init(scratch, cfg);
    defer output.deinit();

    var child_needs_cleanup = true;
    errdefer if (child_needs_cleanup) cleanupChild(&child);

    var script_write = child.stdin orelse return error.SpawnFailed;
    child.stdin = null;
    var script_write_open = true;
    errdefer if (script_write_open) script_write.close(io_mod.getIo());
    try script_write.writeStreamingAll(io_mod.getIo(), script);
    script_write.close(io_mod.getIo());
    script_write_open = false;

    const process_group_id = child.id;
    child_needs_cleanup = false;
    const collected = try collectSpawnedProcess(
        scratch,
        &child,
        &output,
        cfg,
        null,
        process_group_id,
        .process_group,
    );
    const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());

    return finishCollectedProcess(
        &output,
        collected.status,
        collected.output_incomplete,
        duration_ms,
        collected.source,
        cfg.force_cancel_flag != null,
    );
}

fn streamPreviewLimit(max_command_output_bytes: usize) usize {
    if (max_command_output_bytes == 0) return 0;
    return @max(@as(usize, 1), max_command_output_bytes / 2);
}

fn createCommandArtifact(
    alloc: Allocator,
    capability: ?*session_child_store.SessionChildCapability,
    preferred_dir: ?[]const u8,
) !CommandArtifact {
    if (capability) |managed| {
        return createManagedCommandArtifact(alloc, managed);
    }
    if (preferred_dir) |dir| {
        if (createCommandArtifactInDir(alloc, dir)) |artifact| {
            return artifact;
        } else |err| {
            debug_trace.logf("core", "command artifact preferred dir failed dir={s} err={s}", .{ dir, @errorName(err) });
        }
    }

    const fallback_dir = try fallbackCommandArtifactDir(alloc);
    defer alloc.free(fallback_dir);
    return createCommandArtifactInDir(alloc, fallback_dir);
}

fn createManagedCommandArtifact(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
) !CommandArtifact {
    const stem = try alloc.print(
        "{s}{d}-{d}",
        .{
            command_artifact_file_prefix,
            io_mod.milliTimestamp(),
            io_mod.nanoTimestamp(),
        },
    );
    defer alloc.free(stem);
    const output_name = try artifactName(
        alloc,
        stem,
        command_artifact_log_suffix,
    );
    defer alloc.free(output_name);
    const stdout_name = try artifactName(
        alloc,
        stem,
        command_artifact_stdout_suffix,
    );
    defer alloc.free(stdout_name);
    const stderr_name = try artifactName(
        alloc,
        stem,
        command_artifact_stderr_suffix,
    );
    defer alloc.free(stderr_name);

    var output = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        output_name,
    );
    errdefer {
        output.deinit();
        capability.delete(.command_artifacts, output_name) catch {};
    }
    var stdout = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        stdout_name,
    );
    errdefer {
        stdout.deinit();
        capability.delete(.command_artifacts, stdout_name) catch {};
    }
    var stderr = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        stderr_name,
    );
    errdefer {
        stderr.deinit();
        capability.delete(.command_artifacts, stderr_name) catch {};
    }
    const output_file = try alloc.dupe(u8, output.displayPath().?);
    errdefer alloc.free(output_file);
    const stdout_file = try alloc.dupe(u8, stdout.displayPath().?);
    errdefer alloc.free(stdout_file);
    const stderr_file = try alloc.dupe(u8, stderr.displayPath().?);
    errdefer alloc.free(stderr_file);

    return .{
        .output_file = output_file,
        .stdout_file = stdout_file,
        .stderr_file = stderr_file,
        .output = .{ .managed = output },
        .stdout = .{ .managed = stdout },
        .stderr = .{ .managed = stderr },
        .managed_capability = capability,
    };
}

fn createCommandArtifactInDir(alloc: Allocator, dir: []const u8) !CommandArtifact {
    try config_runtime.makeAbsolutePath(dir);

    const stem = try alloc.print(
        "{s}{d}-{d}",
        .{ command_artifact_file_prefix, io_mod.milliTimestamp(), io_mod.nanoTimestamp() },
    );
    defer alloc.free(stem);

    const output_file = try artifactPath(alloc, dir, stem, command_artifact_log_suffix);
    errdefer alloc.free(output_file);
    const stdout_file = try artifactPath(alloc, dir, stem, command_artifact_stdout_suffix);
    errdefer alloc.free(stdout_file);
    const stderr_file = try artifactPath(alloc, dir, stem, command_artifact_stderr_suffix);
    errdefer alloc.free(stderr_file);

    const zio = io_mod.getIo();
    var output = try std.Io.Dir.createFileAbsolute(zio, output_file, .{ .truncate = true });
    errdefer output.close(zio);
    var stdout = try std.Io.Dir.createFileAbsolute(zio, stdout_file, .{ .truncate = true });
    errdefer stdout.close(zio);
    var stderr = try std.Io.Dir.createFileAbsolute(zio, stderr_file, .{ .truncate = true });
    errdefer stderr.close(zio);

    return .{
        .output_file = output_file,
        .stdout_file = stdout_file,
        .stderr_file = stderr_file,
        .output = .{ .external = output },
        .stdout = .{ .external = stdout },
        .stderr = .{ .external = stderr },
    };
}

fn artifactName(
    alloc: Allocator,
    stem: []const u8,
    suffix: []const u8,
) ![]u8 {
    return alloc.print("{s}{s}", .{ stem, suffix });
}

fn artifactPath(alloc: Allocator, dir: []const u8, stem: []const u8, suffix: []const u8) ![]u8 {
    const name = try alloc.print("{s}{s}", .{ stem, suffix });
    defer alloc.free(name);
    return std.Io.Dir.path.join(alloc, &.{ dir, name });
}

fn fallbackCommandArtifactDir(alloc: Allocator) ![]u8 {
    const temp_root = io_mod.getenv("TMPDIR") orelse "/tmp";
    const pid_text = try alloc.print("{d}", .{currentProcessId()});
    defer alloc.free(pid_text);
    return std.Io.Dir.path.join(alloc, &.{ temp_root, command_artifact_fallback_dir_name, pid_text });
}

fn currentProcessId() u64 {
    return @intCast(std.c.getpid());
}

fn elapsedMs(started_ms: i64, finished_ms: i64) u64 {
    return if (finished_ms > started_ms) @intCast(finished_ms - started_ms) else 0;
}

fn executeRawBash(
    alloc: Allocator,
    scratch: Allocator,
    cfg: Config,
    command: []const u8,
    cwd: []const u8,
) !command_contract.RunCommandResult {
    return executeRawBashWithResultCommand(
        alloc,
        scratch,
        cfg,
        command,
        command,
        cwd,
    );
}

fn executeRawBashWithResultCommand(
    alloc: Allocator,
    scratch: Allocator,
    cfg: Config,
    execution_command: []const u8,
    result_command: []const u8,
    cwd: []const u8,
) !command_contract.RunCommandResult {
    if (builtin.target.os.tag == .windows) {
        const argv = [_][]const u8{ "cmd", "/C", execution_command };
        const result = try executeProcess(scratch, cfg, &argv, cwd);
        return formatCollectedOutput(alloc, result_command, cwd, result);
    }

    const argv = [_][]const u8{
        "sh",
        "-lc",
        script_from_stdin_launcher,
    };
    const result = try executeProcessWithScript(
        scratch,
        cfg,
        &argv,
        cwd,
        execution_command,
        null,
    );
    return formatCollectedOutput(alloc, result_command, cwd, result);
}

fn executeRawInvocation(
    alloc: Allocator,
    scratch: Allocator,
    cfg: Config,
    command: []const u8,
    cwd: []const u8,
    invocation: *const shell_resolver.Invocation,
) !command_contract.RunCommandResult {
    if (builtin.target.os.tag == .windows) {
        return error.InvalidCommandEnvironment;
    }
    const result = try executeProcessWithScript(
        scratch,
        cfg,
        invocation.argv(),
        cwd,
        "",
        null,
    );
    return formatCollectedOutput(alloc, command, cwd, result);
}

fn formatOutputWithStatus(
    alloc: Allocator,
    command: []const u8,
    cwd: []const u8,
    status: command_contract.CommandStatus,
    stdout_raw: []const u8,
    stderr_raw: []const u8,
    duration_ms: ?u64,
    output_incomplete: bool,
) !command_contract.RunCommandResult {
    return command_contract.formatCommandResult(alloc, .{
        .command = command,
        .cwd = cwd,
        .status = status,
        .stdout_display = stdout_raw,
        .stderr_display = stderr_raw,
        .stdout_bytes = stdout_raw.len,
        .stderr_bytes = stderr_raw.len,
        .output_incomplete = output_incomplete,
        .duration_ms = duration_ms,
    });
}

fn commandStatusFromTerm(term: std.process.Child.Term) command_contract.CommandStatus {
    return switch (term) {
        .exited => |code| .{ .exit_code = @intCast(code) },
        .signal => |sig| .{ .signal = @backingInt(sig) },
        .stopped, .unknown => .indeterminate,
    };
}

fn formatCollectedOutput(alloc: Allocator, command: []const u8, cwd: []const u8, result: CollectedProcess) !command_contract.RunCommandResult {
    return formatCollectedOutputValue(alloc, command, cwd, result) catch |err| {
        if (!result.cancelled) return err;
        debug_trace.logf("core", "cancelled command result formatting failed err={s}", .{@errorName(err)});
        return error.Cancelled;
    };
}

fn formatCollectedOutputValue(alloc: Allocator, command: []const u8, cwd: []const u8, result: CollectedProcess) !command_contract.RunCommandResult {
    if (result.output_file == null) return formatOutputWithStatus(
        alloc,
        command,
        cwd,
        result.status,
        result.stdout,
        result.stderr,
        result.duration_ms,
        result.output_incomplete,
    );

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try command_contract.writeStatusLine(&out.writer, result.status);
    try out.writer.print("truncated={s}\n", .{if (result.truncated) "true" else "false"});
    try out.writer.print("stdout_bytes={d}\n", .{result.stdout_bytes});
    try out.writer.print("stderr_bytes={d}\n", .{result.stderr_bytes});
    if (result.output_file) |path| try out.writer.print("output_file={s}\n", .{path});
    if (result.stdout_file) |path| try out.writer.print("stdout_file={s}\n", .{path});
    if (result.stderr_file) |path| try out.writer.print("stderr_file={s}\n", .{path});
    if (result.truncated) {
        try writePreviewEnvelope(alloc, &out.writer, "stdout", result.stdout_preview);
        try writePreviewEnvelope(alloc, &out.writer, "stderr", result.stderr_preview);
    }
    const output = try out.toOwnedSlice();
    const status = command_contract.projectStatus(result.status);
    return .{
        .output = output,
        .cancelled = result.cancelled,
        .command_result = .{
            .command = command,
            .cwd = cwd,
            .exit_code = status.exit_code,
            .signal = status.signal,
            .termination_indeterminate = status.termination_indeterminate,
            .output_incomplete = result.output_incomplete,
            .duration_ms = result.duration_ms,
            .stdout_bytes = result.stdout_bytes,
            .stderr_bytes = result.stderr_bytes,
            .truncated = result.truncated,
            .output_file = metadataField(output, "output_file="),
            .stdout_file = metadataField(output, "stdout_file="),
            .stderr_file = metadataField(output, "stderr_file="),
        },
    };
}

fn writePreviewEnvelope(alloc: Allocator, writer: *std.Io.Writer, label: []const u8, preview: StreamPreviewSnapshot) !void {
    if (preview.total_bytes == 0) return;

    try writer.print("<{s}>\n", .{label});
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    if (preview.total_bytes <= preview.max_bytes) {
        var full: std.Io.Writer.Allocating = .init(scratch);
        defer full.deinit();
        try full.writer.writeAll(preview.head);
        const overlap = if (preview.head.len + preview.tail.len > preview.total_bytes)
            preview.head.len + preview.tail.len - preview.total_bytes
        else
            0;
        if (preview.tail.len > overlap) try full.writer.writeAll(preview.tail[overlap..]);
        const safe = try text_utils.sanitizeModelText(scratch, full.writer.buffered());
        try writer.writeAll(safe);
        if (!std.mem.endsWith(u8, safe, "\n")) try writer.writeByte('\n');
        try writer.print("</{s}>\n", .{label});
        return;
    }

    const safe_head = try text_utils.sanitizeModelText(scratch, preview.head);
    const safe_tail = try text_utils.sanitizeModelText(scratch, preview.tail);
    const omitted = preview.total_bytes - preview.max_bytes;
    if (safe_head.len > 0) {
        try writer.writeAll(safe_head);
        if (!std.mem.endsWith(u8, safe_head, "\n")) try writer.writeByte('\n');
    }
    try writer.print("[... {d} bytes truncated ...]\n", .{omitted});
    if (safe_tail.len > 0) {
        try writer.writeAll(safe_tail);
        if (!std.mem.endsWith(u8, safe_tail, "\n")) try writer.writeByte('\n');
    }
    try writer.print("</{s}>\n", .{label});
}

const TerminationSource = enum {
    natural,
    cancelled,
    timed_out,
};

const CollectedOutput = struct {
    source: TerminationSource,
    output_incomplete: bool = false,
    /// When the leader was seen exiting on its own, before any output drain.
    natural_completion_ms: ?i64 = null,
};

fn reconcileForegroundTerminationSource(
    source: TerminationSource,
    deadline_ms: ?i64,
    now_ms: i64,
) TerminationSource {
    if (source != .natural) return source;
    const deadline = deadline_ms orelse return .natural;
    return if (now_ms >= deadline) .timed_out else .natural;
}

const TerminationProtocol = enum {
    process_group,
    foreground_supervisor,
};

const TerminationIntent = enum {
    cooperative,
    force,
};

fn pending_termination_source(
    protocol: TerminationProtocol,
    cancel_requested: bool,
    deadline_ms: ?i64,
    now_ms: i64,
) TerminationSource {
    if (protocol == .foreground_supervisor) {
        if (foreground_supervisor_fallback_deadline_ms(deadline_ms)) |fallback_deadline_ms| {
            if (now_ms >= fallback_deadline_ms) return .timed_out;
        }
    }
    if (cancel_requested) return .cancelled;
    const deadline = deadline_ms orelse return .natural;
    return if (now_ms >= deadline) .timed_out else .natural;
}

const TerminationSignalPlan = struct {
    scope: enum { process_group, supervisor },
    signal: std.posix.SIG,
};

fn terminationSignalPlan(
    protocol: TerminationProtocol,
    intent: TerminationIntent,
) TerminationSignalPlan {
    return switch (protocol) {
        .process_group => .{
            .scope = .process_group,
            .signal = if (intent == .force) std.posix.SIG.KILL else std.posix.SIG.TERM,
        },
        .foreground_supervisor => switch (intent) {
            .cooperative => .{
                .scope = .process_group,
                .signal = std.posix.SIG.TERM,
            },
            .force => .{
                .scope = .supervisor,
                .signal = foreground_session_force_signal,
            },
        },
    };
}

const OutputChunkEmitter = struct {
    stdout_pending: std.ArrayList(u8) = .empty,
    stderr_pending: std.ArrayList(u8) = .empty,
    presentation_suppressed: bool = false,
    /// Set during the drain after a natural completion. Live delivery ends at
    /// this time or on a cancel, while the output is still collected.
    live_until_ms: ?i64 = null,

    fn deinit(self: *@This(), arena: Allocator) void {
        self.stdout_pending.deinit(arena);
        self.stderr_pending.deinit(arena);
    }

    fn append(
        self: *@This(),
        arena: Allocator,
        output: *OutputCollector,
        stream: CommandOutputStream,
        bytes: []const u8,
        cfg: Config,
    ) !void {
        try output.append(stream, bytes);
        try emitAcceptedOutputChunk(cfg, stream, bytes);
        self.emitPending(arena, self.pendingFor(stream), stream, bytes, cfg, false);
    }

    fn flush(self: *@This(), arena: Allocator, cfg: Config) void {
        self.emitPending(arena, &self.stdout_pending, .stdout, "", cfg, true);
        self.emitPending(arena, &self.stderr_pending, .stderr, "", cfg, true);
    }

    fn pendingFor(self: *@This(), stream: CommandOutputStream) *std.ArrayList(u8) {
        return switch (stream) {
            .stdout => &self.stdout_pending,
            .stderr => &self.stderr_pending,
        };
    }

    fn emitPending(
        self: *@This(),
        arena: Allocator,
        pending: *std.ArrayList(u8),
        stream: CommandOutputStream,
        new_bytes: []const u8,
        cfg: Config,
        flush_remainder: bool,
    ) void {
        if (self.presentation_suppressed) return;
        const ctx = cfg.output_chunk_ctx orelse return;
        const callback = cfg.on_output_chunk orelse return;
        if (new_bytes.len > 0) pending.appendSlice(arena, new_bytes) catch |err| {
            self.suppressPresentation(err);
            return;
        };

        var line_start: usize = 0;
        while (std.mem.findScalarPos(u8, pending.items, line_start, '\n')) |newline_index| {
            if (self.liveDeliveryEnded(cfg)) {
                self.suppressPresentation(error.OutputDrainInterrupted);
                return;
            }
            const line = pending.items[line_start .. newline_index + 1];
            emitOutputChunk(ctx, callback, cfg.output_chunk_lifecycle_id, stream, line, cfg.callback_projection) catch |err| {
                self.suppressPresentation(err);
                return;
            };
            line_start = newline_index + 1;
        }
        if (line_start > 0) {
            const remaining = pending.items.len - line_start;
            @memmove(pending.items[0..remaining], pending.items[line_start..]);
            pending.items.len = remaining;
        }
        // The final flush always delivers the last partial line. It is one
        // callback, so it cannot stretch the drain.
        if (!flush_remainder and pending.items.len > 0 and self.liveDeliveryEnded(cfg)) {
            self.suppressPresentation(error.OutputDrainInterrupted);
            return;
        }

        if (!flush_remainder and pending.items.len >= pending_output_flush_bytes) {
            emitOutputChunk(ctx, callback, cfg.output_chunk_lifecycle_id, stream, pending.items, cfg.callback_projection) catch |err| {
                self.suppressPresentation(err);
                return;
            };
            pending.clearRetainingCapacity();
        }

        if (flush_remainder and pending.items.len > 0) {
            emitOutputChunk(ctx, callback, cfg.output_chunk_lifecycle_id, stream, pending.items, cfg.callback_projection) catch |err| {
                self.suppressPresentation(err);
                return;
            };
            pending.clearRetainingCapacity();
        }
    }

    fn liveDeliveryEnded(self: *const @This(), cfg: Config) bool {
        const until_ms = self.live_until_ms orelse return false;
        return cancelRequested(cfg.cancel_flag) or io_mod.milliTimestamp() >= until_ms;
    }

    fn suppressPresentation(self: *@This(), err: anyerror) void {
        debug_trace.logf(
            "core",
            "command output presentation suppressed err={s}",
            .{@errorName(err)},
        );
        self.presentation_suppressed = true;
        self.stdout_pending.clearRetainingCapacity();
        self.stderr_pending.clearRetainingCapacity();
    }
};

const ForegroundLaunchFailureProbe = struct {
    const Status = enum {
        matching,
        passthrough,
        failed,
    };

    expected: []const u8,
    status: Status = .matching,
    pending: [foreground_session_replace_failure_marker_bytes]u8 = undefined,
    pending_len: usize = 0,
    error_name: [foreground_session_replace_error_name_bytes]u8 = undefined,
    error_name_len: usize = 0,
    error_name_done: bool = false,
    error_name_invalid: bool = false,
    replacement_error: ?std.process.ReplaceError = null,

    fn init(expected: []const u8) @This() {
        std.debug.assert(expected.len <= foreground_session_replace_failure_marker_bytes);
        return .{ .expected = expected };
    }

    fn append(
        self: *@This(),
        arena: Allocator,
        emitter: *OutputChunkEmitter,
        output: *OutputCollector,
        bytes: []const u8,
        cfg: Config,
    ) !void {
        switch (self.status) {
            .passthrough => return emitter.append(
                arena,
                output,
                .stderr,
                bytes,
                cfg,
            ),
            .failed => return self.appendErrorName(bytes),
            .matching => {},
        }

        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            self.pending[self.pending_len] = bytes[index];
            self.pending_len += 1;

            if (!std.mem.eql(
                u8,
                self.pending[0..self.pending_len],
                self.expected[0..self.pending_len],
            )) {
                self.status = .passthrough;
                try emitter.append(
                    arena,
                    output,
                    .stderr,
                    self.pending[0..self.pending_len],
                    cfg,
                );
                if (index + 1 < bytes.len) {
                    try emitter.append(
                        arena,
                        output,
                        .stderr,
                        bytes[index + 1 ..],
                        cfg,
                    );
                }
                return;
            }
            if (self.pending_len == self.expected.len) {
                self.status = .failed;
                if (index + 1 < bytes.len) {
                    self.appendErrorName(bytes[index + 1 ..]);
                }
                return;
            }
        }
    }

    fn appendErrorName(self: *@This(), bytes: []const u8) void {
        if (self.error_name_done) return;
        for (bytes) |byte| {
            if (byte == '\n') {
                self.error_name_done = true;
                if (!self.error_name_invalid) {
                    self.replacement_error = parseReplaceError(self.error_name[0..self.error_name_len]);
                }
                return;
            }
            if (self.error_name_len == self.error_name.len) {
                self.error_name_invalid = true;
                continue;
            }
            self.error_name[self.error_name_len] = byte;
            self.error_name_len += 1;
        }
    }

    fn flush(
        self: *@This(),
        arena: Allocator,
        emitter: *OutputChunkEmitter,
        output: *OutputCollector,
        cfg: Config,
    ) !void {
        if (self.status != .matching or self.pending_len == 0) return;
        self.status = .passthrough;
        try emitter.append(
            arena,
            output,
            .stderr,
            self.pending[0..self.pending_len],
            cfg,
        );
    }
};

fn parseReplaceError(name: []const u8) ?std.process.ReplaceError {
    inline for (comptime @typeInfo(std.process.ReplaceError).error_set.error_names.?) |error_name| {
        if (std.mem.eql(u8, name, error_name)) {
            return @field(std.process.ReplaceError, error_name);
        }
    }
    return null;
}

const ProcessObserver = struct {
    waiter: ChildWaiter,
    process_id: std.process.Child.Id,
    stdout: std.Io.File,
    stderr: std.Io.File,
    detached_pipes: bool = false,

    fn init(child: *std.process.Child) !ProcessObserver {
        const process_id = child.id orelse return error.SpawnFailed;
        const stdout = child.stdout orelse return error.SpawnFailed;
        const stderr = child.stderr orelse return error.SpawnFailed;
        const detached_pipes = comptime builtin.target.os.tag != .windows and
            builtin.target.os.tag != .wasi;
        if (detached_pipes) {
            child.stdout = null;
            child.stderr = null;
        }
        return .{
            .waiter = ChildWaiter.init(child),
            .process_id = process_id,
            .stdout = stdout,
            .stderr = stderr,
            .detached_pipes = detached_pipes,
        };
    }

    fn deinit(self: *ProcessObserver) void {
        if (self.detached_pipes) {
            self.stdout.close(self.waiter.io);
            self.stderr.close(self.waiter.io);
        }
        self.* = undefined;
    }

    fn start(self: *ProcessObserver) !void {
        if (comptime builtin.target.os.tag == .windows) return;
        try self.waiter.start();
    }

    fn observe(self: *ProcessObserver) ?command_contract.CommandStatus {
        if (comptime builtin.target.os.tag == .windows) return null;
        if (!self.waiter.isReady()) return null;
        const term = self.waiter.awaitReady() catch |err| {
            return indeterminateStatus(err);
        };
        return statusFromTerm(term);
    }

    fn awaitTermination(
        self: *ProcessObserver,
        source: TerminationSource,
    ) !command_contract.CommandStatus {
        if (comptime builtin.target.os.tag != .windows) {
            self.waiter.awaitDiscard();
            return self.observe().?;
        }
        const term = self.waiter.child.wait(self.waiter.io) catch |err| {
            return switch (source) {
                .natural => blk: {
                    break :blk indeterminateStatus(err);
                },
                .cancelled, .timed_out => mapTerminationError(
                    source,
                    null,
                    "process wait",
                    err,
                ),
            };
        };
        return statusFromTerm(term);
    }

    fn statusFromTerm(
        term: std.process.Child.Term,
    ) command_contract.CommandStatus {
        if (io_mod.getenv("FX_COMMAND_TEST_INDETERMINATE_AFTER_EXIT") != null) {
            debug_trace.logf(
                "core",
                "command termination became indeterminate reason=injected_after_exit",
                .{},
            );
            return .indeterminate;
        }
        const status = commandStatusFromTerm(term);
        switch (status) {
            .indeterminate => debug_trace.logf(
                "core",
                "command termination became indeterminate boundary=child_term term={s}",
                .{@tagName(std.meta.activeTag(term))},
            ),
            .exit_code, .signal, .finished => {},
        }
        return status;
    }

    fn indeterminateStatus(
        err: anyerror,
    ) command_contract.CommandStatus {
        debug_trace.logf(
            "core",
            "command termination became indeterminate boundary=process_wait err={s}",
            .{@errorName(err)},
        );
        return .indeterminate;
    }

    fn signal(
        self: *ProcessObserver,
        process_group_id: ?std.posix.pid_t,
        protocol: TerminationProtocol,
        intent: TerminationIntent,
    ) !void {
        if (builtin.target.os.tag == .windows) {
            self.waiter.child.kill(self.waiter.io);
            return;
        }
        const target_pid = process_group_id orelse self.process_id;
        const plan = terminationSignalPlan(protocol, intent);
        return switch (plan.scope) {
            .process_group => signalProcessGroup(target_pid, plan.signal),
            .supervisor => signalProcess(target_pid, plan.signal),
        };
    }

    fn abort(self: *ProcessObserver, process_group_id: ?std.posix.pid_t) void {
        if (builtin.target.os.tag == .windows) {
            cleanupChild(self.waiter.child);
            return;
        }
        if (self.waiter.isReady()) {
            self.waiter.awaitDiscard();
            return;
        }
        const pid = process_group_id orelse self.process_id;
        signalProcessGroup(pid, std.posix.SIG.KILL) catch |err| {
            debug_trace.logf(
                "core",
                "command observer cleanup kill failed err={s}",
                .{@errorName(err)},
            );
        };
        self.waiter.awaitDiscard();
    }
};

fn termination_settle_expired(
    signal_started_ms: ?i64,
    force_kill_sent: bool,
    now_ms: i64,
) bool {
    const started_ms = signal_started_ms orelse return false;
    return force_kill_sent and
        now_ms >= started_ms and
        now_ms - started_ms >= termination_settle_timeout_ms;
}

fn collectOutput(
    arena: Allocator,
    observer: *ProcessObserver,
    output: *OutputCollector,
    cfg: Config,
    source: *TerminationSource,
    launch_failure_probe: ?*ForegroundLaunchFailureProbe,
    process_group_id: ?std.posix.pid_t,
    termination_protocol: TerminationProtocol,
    leader_status: *?command_contract.CommandStatus,
) !CollectedOutput {
    const zio = io_mod.getIo();
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(arena, zio, multi_reader_buffer.toStreams(), &.{ observer.stdout, observer.stderr });
    defer multi_reader.deinit();

    const stdout_r = multi_reader.reader(0);
    const stderr_r = multi_reader.reader(1);

    var emitter: OutputChunkEmitter = .{};
    defer emitter.deinit(arena);

    const control = ExecutionControl.init(cfg);
    const started_ms = control.started_ms;
    const deadline_ms = control.deadlineMs();
    var signal_started_ms: ?i64 = null;
    var force_kill_sent = false;
    var streams_finished = false;
    var output_incomplete = false;
    var natural_drain: ?NaturalDrain = null;

    while (true) {
        // Observe the leader before any deadline or cancel so a command that
        // already exited on its own is never signaled or reclassified.
        if (leader_status.* == null) {
            if (observer.observe()) |status| {
                leader_status.* = status;
                if (source.* == .natural) {
                    const drain: NaturalDrain = .{ .completed_ms = observer.waiter.completed_ms };
                    emitter.live_until_ms = drain.liveUntilMs(deadline_ms);
                    natural_drain = drain;
                }
                if (process_group_id) |pid| {
                    if (source.* == .natural) {
                        terminateRemainingProcessGroup(pid);
                        debug_trace.logf(
                            "core",
                            "captured command leader completed; remaining process group terminated",
                            .{},
                        );
                    } else {
                        debug_trace.logf(
                            "core",
                            "captured command leader completed during {s}; termination cleanup continuing",
                            .{@tagName(source.*)},
                        );
                    }
                }
            }
        }
        if (natural_drain == null) {
            try updateTerminationSignal(
                observer,
                process_group_id,
                termination_protocol,
                cfg,
                started_ms,
                source,
                &signal_started_ms,
                &force_kill_sent,
            );
        }

        const now_ms = io_mod.milliTimestamp();
        if (termination_settle_expired(
            signal_started_ms,
            force_kill_sent,
            now_ms,
        )) {
            debug_trace.logf(
                "core",
                "command termination settlement expired boundary=post_force source={s} wait_ready={s}",
                .{
                    @tagName(source.*),
                    if (observer.waiter.isReady()) "true" else "false",
                },
            );
            recordOutputDrainFailure(
                &output_incomplete,
                "termination_settle_deadline",
                error.Timeout,
            );
            break;
        }
        if (natural_drain) |*drain| drain_stop: {
            if (streams_finished) break :drain_stop;
            const reason = drain.stop(
                now_ms,
                cancelRequested(cfg.cancel_flag),
                deadline_ms,
            ) orelse break :drain_stop;
            const cuts_output = drain.cutsCommandOutput(reason);
            if (cuts_output and !drain.confirming) {
                // One more read shows whether the command's own output is
                // still waiting or has all been read.
                drain.confirming = true;
                break :drain_stop;
            }
            debug_trace.logf(
                "core",
                "captured command output drain stopped after natural completion reason={s} bytes={d} waited_ms={d} output_cut={s}",
                .{
                    @tagName(reason),
                    drain.bytes,
                    @divTrunc(drain.waited_ns, std.time.ns_per_ms),
                    if (cuts_output) "true" else "false",
                },
            );
            if (cuts_output) {
                recordOutputDrainFailure(
                    &output_incomplete,
                    @tagName(reason),
                    error.OutputDrainInterrupted,
                );
            }
            break;
        }

        if (streams_finished) {
            if (source.* == .natural or
                signal_started_ms == null or
                force_kill_sent or
                !remainingProcessGroupAlive(process_group_id))
            {
                break;
            }
            io_mod.sleep(10 * std.time.ns_per_ms);
            continue;
        }

        const fill_started_ns = io_mod.nanoTimestamp();
        var fill_timed_out = false;
        const keep_reading = if (multi_reader.fill(4096, .{ .duration = .{ .raw = .{ .nanoseconds = capture_stop_poll_ms * std.time.ns_per_ms }, .clock = .awake } }))
            true
        else |err| switch (err) {
            error.EndOfStream => false,
            error.Timeout => blk: {
                fill_timed_out = true;
                break :blk true;
            },
            else => |e| blk: {
                if (source.* != .natural or
                    (natural_drain == null and cancelRequested(cfg.cancel_flag)))
                {
                    return e;
                }
                recordOutputDrainFailure(
                    &output_incomplete,
                    "reader_coordination",
                    e,
                );
                break :blk false;
            },
        };

        const stdout_buf = stdout_r.buffered();
        const stderr_buf = stderr_r.buffered();
        if (natural_drain) |*drain| {
            drain.record(
                stdout_buf.len + stderr_buf.len,
                fill_timed_out,
                io_mod.nanoTimestamp() - fill_started_ns,
            );
        }
        if (stdout_buf.len > 0) {
            try emitter.append(arena, output, .stdout, stdout_buf, cfg);
            stdout_r.tossBuffered();
        }
        if (stderr_buf.len > 0) {
            if (launch_failure_probe) |probe| {
                try probe.append(arena, &emitter, output, stderr_buf, cfg);
            } else {
                try emitter.append(arena, output, .stderr, stderr_buf, cfg);
            }
            stderr_r.tossBuffered();
        }
        if (natural_drain == null and emitter.presentation_suppressed and
            cancelRequested(cfg.cancel_flag))
        {
            return error.Cancelled;
        }
        if (source.* == .natural) {
            recordMultiReaderFailure(&multi_reader, &output_incomplete);
            if (output_incomplete) break;
        }

        if (!keep_reading) {
            streams_finished = true;
            if (source.* == .natural or
                signal_started_ms == null or
                force_kill_sent or
                !remainingProcessGroupAlive(process_group_id))
            {
                break;
            }
        }
    }

    if (launch_failure_probe) |probe| {
        try probe.flush(arena, &emitter, output, cfg);
    }
    emitter.flush(arena, cfg);
    if (source.* == .natural) {
        recordMultiReaderFailure(&multi_reader, &output_incomplete);
    }
    return .{
        .source = source.*,
        .output_incomplete = output_incomplete,
        .natural_completion_ms = if (natural_drain) |drain| drain.completed_ms else null,
    };
}

/// Leftover-output drain after a command finishes on its own.
const NaturalDrain = struct {
    completed_ms: i64,
    waited_ns: i128 = 0,
    bytes: usize = 0,
    /// A read that found nothing for a whole poll shows the command's own
    /// leftover output has all been read. Later output is a daemon's.
    leftover_read: bool = false,
    /// One more read is confirming whether a stop would cut command output.
    confirming: bool = false,

    const Stop = enum {
        wait_limit,
        cancelled,
        deadline,
        byte_limit,
    };

    /// Records one read. Every wait counts, because leftover output reads
    /// without waiting and only a detached writer makes capture wait.
    fn record(self: *NaturalDrain, read_len: usize, timed_out: bool, waited_ns: i128) void {
        self.bytes +|= read_len;
        self.waited_ns +|= @max(waited_ns, 0);
        if (timed_out) self.leftover_read = true;
        // A read that returns nothing without timing out ended one stream,
        // which settles nothing about the other, so confirmation starts over.
        if (read_len == 0) self.confirming = false;
    }

    /// Reading ends at end of file, at the wait limit, on a cancel, at the
    /// deadline, or once the byte budget shows a detached writer.
    fn stop(
        self: NaturalDrain,
        now_ms: i64,
        cancel_requested: bool,
        deadline_ms: ?i64,
    ) ?Stop {
        if (cancel_requested) return .cancelled;
        if (deadline_ms) |deadline| {
            if (now_ms >= deadline) return .deadline;
        }
        if (self.bytes >= natural_completion_drain_max_bytes) return .byte_limit;
        if (self.waited_ns >= natural_completion_wait_ms * std.time.ns_per_ms) return .wait_limit;
        return null;
    }

    /// Whether stopping now can drop the command's own output. The wait limit
    /// and the byte budget are reached only after that output was read.
    fn cutsCommandOutput(self: NaturalDrain, reason: Stop) bool {
        return switch (reason) {
            .cancelled, .deadline => !self.leftover_read,
            .wait_limit, .byte_limit => false,
        };
    }

    /// When live delivery of drained output ends, so a slow reader cannot
    /// hold the drain past its deadline or live limit.
    fn liveUntilMs(self: NaturalDrain, deadline_ms: ?i64) i64 {
        const limit_ms = self.completed_ms + natural_completion_live_ms;
        const deadline = deadline_ms orelse return limit_ms;
        return @min(deadline, limit_ms);
    }
};

fn recordMultiReaderFailure(
    multi_reader: *const std.Io.File.MultiReader,
    output_incomplete: *bool,
) void {
    multi_reader.checkAnyError() catch |err| {
        recordOutputDrainFailure(output_incomplete, "stream_read", err);
    };
}

fn recordOutputDrainFailure(
    output_incomplete: *bool,
    reason: []const u8,
    err: anyerror,
) void {
    if (output_incomplete.*) return;
    output_incomplete.* = true;
    debug_trace.logf(
        "core",
        "command output drain incomplete reason={s} err={s}",
        .{ reason, @errorName(err) },
    );
}

fn collectOutputForProcess(
    arena: Allocator,
    observer: *ProcessObserver,
    output: *OutputCollector,
    cfg: Config,
    launch_failure_probe: ?*ForegroundLaunchFailureProbe,
    process_group_id: ?std.posix.pid_t,
    termination_protocol: TerminationProtocol,
    leader_status: *?command_contract.CommandStatus,
) !CollectedOutput {
    var source: TerminationSource = .natural;
    return collectOutput(
        arena,
        observer,
        output,
        cfg,
        &source,
        launch_failure_probe,
        process_group_id,
        termination_protocol,
        leader_status,
    ) catch |err|
        return mapTerminationError(source, cfg.cancel_flag, "output collection", err);
}

fn waitForCollectedProcess(
    observer: *ProcessObserver,
    source: TerminationSource,
    process_group_id: ?std.posix.pid_t,
    leader_status: ?command_contract.CommandStatus,
) !command_contract.CommandStatus {
    if (leader_status) |status| {
        if (comptime builtin.target.os.tag != .windows) {
            observer.waiter.awaitDiscard();
        }
        return status;
    }
    const status = try observer.awaitTermination(source);
    if (process_group_id) |pid| {
        terminateRemainingProcessGroup(pid);
    }
    return status;
}

const CollectedTermination = struct {
    source: TerminationSource,
    status: command_contract.CommandStatus,
    output_incomplete: bool = false,
    natural_completion_ms: ?i64 = null,
};

fn collectSpawnedProcess(
    arena: Allocator,
    child: *std.process.Child,
    output: *OutputCollector,
    cfg: Config,
    launch_failure_probe: ?*ForegroundLaunchFailureProbe,
    process_group_id: ?std.posix.pid_t,
    termination_protocol: TerminationProtocol,
) !CollectedTermination {
    var observer = ProcessObserver.init(child) catch |err| {
        cleanupChild(child);
        return err;
    };
    defer observer.deinit();
    observer.start() catch |err| {
        debug_trace.logf(
            "core",
            "command wait authority unavailable after spawn err={s}",
            .{@errorName(err)},
        );
        cleanupChild(child);
        return .{
            .source = .natural,
            .status = .indeterminate,
        };
    };

    var wait_pending = true;
    defer if (wait_pending) observer.abort(process_group_id);

    var leader_status: ?command_contract.CommandStatus = null;
    const collected_output = try collectOutputForProcess(
        arena,
        &observer,
        output,
        cfg,
        launch_failure_probe,
        process_group_id,
        termination_protocol,
        &leader_status,
    );
    if (collected_output.output_incomplete and leader_status == null) {
        debug_trace.logf(
            "core",
            "command output drain failed before process status; aborting command",
            .{},
        );
        observer.abort(process_group_id);
        wait_pending = false;
        return .{
            .source = collected_output.source,
            .status = .indeterminate,
            .output_incomplete = true,
        };
    }
    const status = try waitForCollectedProcess(
        &observer,
        collected_output.source,
        process_group_id,
        leader_status,
    );
    wait_pending = false;
    var output_incomplete = collected_output.output_incomplete;
    if (io_mod.getenv("FX_COMMAND_TEST_OUTPUT_INCOMPLETE_AFTER_EXIT") != null) {
        recordOutputDrainFailure(
            &output_incomplete,
            "injected_after_exit",
            error.Unexpected,
        );
    }
    return .{
        .source = collected_output.source,
        .status = status,
        .output_incomplete = output_incomplete,
        .natural_completion_ms = collected_output.natural_completion_ms,
    };
}

fn mapTerminationError(
    source: TerminationSource,
    cancel_flag: ?*std.atomic.Value(bool),
    phase: []const u8,
    err: anyerror,
) anyerror {
    const effective_source: TerminationSource = if (source == .natural and cancelRequested(cancel_flag))
        .cancelled
    else
        source;
    return switch (effective_source) {
        .natural => err,
        .cancelled => blk: {
            debug_trace.logf("core", "cancelled command {s} failed err={s}", .{ phase, @errorName(err) });
            break :blk error.Cancelled;
        },
        .timed_out => blk: {
            debug_trace.logf("core", "timed out command {s} failed err={s}", .{ phase, @errorName(err) });
            break :blk error.TimeoutExpired;
        },
    };
}

fn updateTerminationSignal(
    observer: *ProcessObserver,
    process_group_id: ?std.posix.pid_t,
    termination_protocol: TerminationProtocol,
    cfg: Config,
    started_ms: i64,
    source: *TerminationSource,
    signal_started_ms: *?i64,
    force_kill_sent: *bool,
) !void {
    const now_ms = io_mod.milliTimestamp();
    if (signal_started_ms.* == null) {
        const control = ExecutionControl{
            .cancel_flag = cfg.cancel_flag,
            .timeout_ms = cfg.timeout_ms,
            .started_ms = started_ms,
        };
        source.* = pending_termination_source(
            termination_protocol,
            cancelRequested(cfg.cancel_flag),
            control.deadlineMs(),
            now_ms,
        );
        switch (source.*) {
            .natural => {},
            .cancelled => {
                const force = cancelRequested(cfg.force_cancel_flag);
                try observer.signal(
                    process_group_id,
                    termination_protocol,
                    if (force) .force else .cooperative,
                );
                force_kill_sent.* = force;
                debug_trace.logf(
                    "core",
                    "command termination requested source=cancelled force={s}",
                    .{if (force) "true" else "false"},
                );
                signal_started_ms.* = now_ms;
            },
            .timed_out => {
                try observer.signal(process_group_id, termination_protocol, .force);
                force_kill_sent.* = true;
                debug_trace.logf("core", "command termination requested source=timeout", .{});
                signal_started_ms.* = now_ms;
            },
        }
    }

    if (signal_started_ms.*) |sent_ms| {
        if (!force_kill_sent.*) {
            // A force request (process exit) escalates a cooperative stop
            // that is still inside its grace window.
            const grace_expired = now_ms - sent_ms >= 800;
            if (grace_expired or cancelRequested(cfg.force_cancel_flag)) {
                try observer.signal(process_group_id, termination_protocol, .force);
                debug_trace.logf(
                    "core",
                    "command force-killed reason={s}",
                    .{if (grace_expired) "termination_grace_expired" else "force_cancel"},
                );
                force_kill_sent.* = true;
            }
        }
    }
}

fn emitOutputChunk(
    ctx: *anyopaque,
    callback: CommandOutputCallback,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: CommandOutputStream,
    chunk: []const u8,
    projection: CallbackProjection,
) !void {
    if (chunk.len == 0) return;
    if (projection == .model_safe and !text_utils.isModelSafeText(chunk)) return;
    try callback(ctx, lifecycle_id, stream, chunk);
}

fn signalProcess(pid: std.posix.pid_t, signal: std.posix.SIG) !void {
    std.posix.kill(pid, signal) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => return err,
    };
}

fn signalProcessGroup(pid: std.posix.pid_t, signal: std.posix.SIG) !void {
    return signalProcess(-pid, signal);
}

fn terminateRemainingProcessGroup(pid: std.posix.pid_t) void {
    signalProcessGroup(pid, std.posix.SIG.KILL) catch |err| {
        debug_trace.logf(
            "core",
            "remaining captured process group cleanup failed err={s}",
            .{@errorName(err)},
        );
    };
}

fn remainingProcessGroupAlive(process_group_id: ?std.posix.pid_t) bool {
    if (comptime builtin.target.os.tag == .windows) return false;
    const pid = process_group_id orelse return false;
    std.posix.kill(-pid, @fromBackingInt(@intCast(0))) catch |err| return switch (err) {
        error.ProcessNotFound => false,
        else => true,
    };
    return true;
}

fn cleanupChild(child: *std.process.Child) void {
    if (child.id == null) {
        closeChildPipes(child);
        return;
    }
    if (builtin.target.os.tag == .windows) {
        child.kill(io_mod.getIo());
        return;
    }
    const pid = child.id orelse return;
    std.posix.kill(-pid, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => debug_trace.logf("core", "command cleanup kill failed err={s}", .{@errorName(err)}),
    };
    _ = child.wait(io_mod.getIo()) catch |err| {
        debug_trace.logf("core", "command cleanup wait failed err={s}", .{@errorName(err)});
    };
}

fn closeChildPipes(child: *std.process.Child) void {
    if (child.stdin) |input| {
        input.close(io_mod.getIo());
        child.stdin = null;
    }
    if (child.stdout) |output| {
        output.close(io_mod.getIo());
        child.stdout = null;
    }
    if (child.stderr) |output| {
        output.close(io_mod.getIo());
        child.stderr = null;
    }
}

fn metadataField(output: []const u8, prefix: []const u8) ?[]const u8 {
    var remaining = output;
    while (remaining.len > 0) {
        const line_end = std.mem.findScalar(u8, remaining, '\n') orelse remaining.len;
        const line = remaining[0..line_end];
        if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
        if (line_end == remaining.len) break;
        remaining = remaining[line_end + 1 ..];
    }
    return null;
}

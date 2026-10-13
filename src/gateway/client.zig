const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const agent_stream_provider = @import("../core/agent/stream_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");

pub fn isRetryableGatewayError(err: anyerror) bool {
    return err == error.HttpConnectionClosing or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionTimedOut;
}

pub fn networkFailureEvidence(
    err: anyerror,
    delivery: DeliveryCertainty.State,
) ?agent_stream_provider.NetworkFailureEvidence {
    const cause: agent_stream_provider.NetworkFailureCause = if (err == error.SystemResumed)
        .system_resumed
    else if (err == error.StreamStalled)
        .stream_stalled
    else if (isConnectivityFailure(err))
        .connectivity_lost
    else if (isRetryableAgentNetworkError(err))
        .transport_interrupted
    else
        return null;
    return .{ .cause = cause, .delivery = delivery };
}

/// Errors that prove the network path itself is down: nothing reached a
/// server, so no request was sent and no generation exists. Distinct from
/// connected-but-failed errors (reset mid-stream, closed connection), which
/// carry delivery ambiguity and belong to the retry class.
pub fn isConnectivityFailure(err: anyerror) bool {
    return err == error.UnknownHostName or
        err == error.NameServerFailure or
        err == error.NoAddressReturned or
        err == error.DetectingNetworkConfigurationFailed or
        err == error.AddressUnavailable or
        err == error.ConnectionRefused or
        err == error.ConnectionTimedOut or
        err == error.HostUnreachable or
        err == error.NetworkUnreachable or
        err == error.NetworkDown;
}

fn isRetryableAgentNetworkError(err: anyerror) bool {
    return err == error.TlsInitializationFailed or
        err == error.ConnectionSetupTimedOut or
        err == error.UnknownHostName or
        err == error.NameServerFailure or
        err == error.NoAddressReturned or
        err == error.DetectingNetworkConfigurationFailed or
        err == error.AddressUnavailable or
        err == error.ConnectionPending or
        err == error.ConnectionRefused or
        err == error.HostUnreachable or
        err == error.NetworkUnreachable or
        err == error.NetworkDown or
        err == error.Timeout or
        err == error.WouldBlock or
        err == error.WriteFailed or
        err == error.ReadFailed or
        isRetryableGatewayError(err);
}

pub const StreamCallback = agent_stream_provider.StreamCallback;
pub const ToolStartCallback = agent_stream_provider.ToolStartCallback;

/// Identifies fx on every provider request instead of the zig std.http default.
pub const user_agent = "fx/" ++ build_options.app_version;
var test_cancel_watcher_spawn_error: ?anyerror = null;

pub const StreamResult = struct {
    status: std.http.Status,
    completion: types.ModelCompletion = .{},
    err_body: ?[]u8 = null,
    retry_after_seconds: ?u64 = null,

    /// Frees all owned response buffers allocated for this stream result.
    pub fn deinit(self: *StreamResult, alloc: std.mem.Allocator) void {
        if (self.err_body) |body| alloc.free(body);
        deinitGatewayCompletion(alloc, &self.completion);
        const status = self.status;
        self.* = .{ .status = status };
    }
};

/// Monotonic request-delivery evidence. It becomes possibly sent before the
/// first body write so any later transport failure is treated as potentially billed.
pub const DeliveryCertainty = agent_stream_provider.DeliveryCertainty;

const ResponseHeadTiming = struct {
    timeout_ms: i64 = 120_000,
    /// Patient head-wait (agent streaming path): a long-thinking model and a
    /// hung gateway are byte-identical on the wire, and the gateway sends no
    /// heartbeat. Never abort a sent request on head silence alone; only a dead
    /// socket, cancellation, or a system resume ends the wait.
    patient: bool = false,
    /// Mid-stream stall watchdog: once the head has arrived, a stream that
    /// produces no bytes for this long is treated as dead (positive evidence,
    /// unlike silence before the head).
    stall_timeout_ms: i64 = 60_000,
};

const ConnectedRequestWatch = struct {
    const Phase = enum(u8) {
        sending,
        awaiting_head,
        streaming,
        completed,
        timed_out,
        cancelled,
        system_resumed,
        stalled,
    };

    phase: std.atomic.Value(Phase) = .init(.sending),
    response_head_deadline: std.Io.Clock.Timestamp = undefined,
    /// Last byte progress in the streaming phase (awake clock, ms). Written by
    /// the consume loop, read by the watcher thread. Millisecond precision is ample for second-scale stall thresholds.
    last_progress_ms: std.atomic.Value(i64) = .init(0),
    timing: ResponseHeadTiming,

    fn init(timing: ResponseHeadTiming) ConnectedRequestWatch {
        return .{ .timing = timing };
    }

    fn arm_response_head(self: *ConnectedRequestWatch) ?anyerror {
        self.response_head_deadline = std.Io.Clock.Timestamp.fromNow(
            io_mod.getIo(),
            .{
                .clock = .awake,
                .raw = .fromMilliseconds(self.timing.timeout_ms),
            },
        );
        if (self.phase.cmpxchgStrong(
            .sending,
            .awaiting_head,
            .seq_cst,
            .seq_cst,
        )) |winner| return phase_error(winner);
        return null;
    }

    fn commit_response_head(self: *ConnectedRequestWatch) ?anyerror {
        if (self.phase.cmpxchgStrong(
            .awaiting_head,
            .streaming,
            .seq_cst,
            .seq_cst,
        )) |winner| return phase_error(winner);
        self.markStreamProgress();
        return null;
    }

    fn finish(self: *ConnectedRequestWatch) ?anyerror {
        var current = self.phase.load(.seq_cst);
        while (is_active(current)) {
            if (self.phase.cmpxchgWeak(
                current,
                .completed,
                .seq_cst,
                .seq_cst,
            )) |observed| {
                current = observed;
                continue;
            }
            return null;
        }
        return phase_error(current);
    }

    fn finish_error(
        self: *ConnectedRequestWatch,
        transport_error: anyerror,
    ) anyerror {
        return self.finish() orelse transport_error;
    }

    fn win(self: *ConnectedRequestWatch, winner: Phase) bool {
        std.debug.assert(!is_active(winner));
        std.debug.assert(winner != .completed);
        var current = self.phase.load(.seq_cst);
        while (is_active(current)) {
            if (self.phase.cmpxchgWeak(
                current,
                winner,
                .seq_cst,
                .seq_cst,
            )) |observed| {
                current = observed;
                continue;
            }
            return true;
        }
        return false;
    }

    fn win_response_head_timeout(self: *ConnectedRequestWatch) bool {
        return self.phase.cmpxchgStrong(
            .awaiting_head,
            .timed_out,
            .seq_cst,
            .seq_cst,
        ) == null;
    }

    fn markStreamProgress(self: *ConnectedRequestWatch) void {
        // Both writer and reader use the monotonic awake clock; mixing in the
        // wall clock would make the elapsed subtraction permanently negative.
        const now_ns = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake).raw.toNanoseconds();
        self.last_progress_ms.store(@intCast(@divFloor(now_ns, std.time.ns_per_ms)), .seq_cst);
    }

    /// Positive-evidence stall: the head arrived, then the stream went silent
    /// past the stall threshold. Wins `.stalled` so the caller can distinguish
    /// it from a pre-head timeout (which stays patient).
    fn stream_stall_expired(
        self: *const ConnectedRequestWatch,
        now: std.Io.Clock.Timestamp,
    ) bool {
        if (self.phase.load(.seq_cst) != .streaming) return false;
        const last = self.last_progress_ms.load(.seq_cst);
        if (last == 0) return false;
        const now_ms: i64 = @intCast(@divFloor(now.raw.toNanoseconds(), std.time.ns_per_ms));
        const elapsed = now_ms - last;
        return elapsed >= self.timing.stall_timeout_ms;
    }

    fn win_stall_timeout(self: *ConnectedRequestWatch) bool {
        return self.phase.cmpxchgStrong(
            .streaming,
            .stalled,
            .seq_cst,
            .seq_cst,
        ) == null;
    }

    fn response_head_expired(
        self: *ConnectedRequestWatch,
        now: std.Io.Clock.Timestamp,
    ) bool {
        if (self.timing.patient) {
            // Patient head-wait never aborts. The wait ends only with data,
            // a dead socket, cancel, or system resume.
            if (self.phase.load(.seq_cst) != .awaiting_head) return false;
            if (std.Io.Clock.Timestamp.compare(now, .lt, self.response_head_deadline)) return false;
            return false;
        }
        if (self.phase.load(.seq_cst) != .awaiting_head) return false;
        return !std.Io.Clock.Timestamp.compare(
            now,
            .lt,
            self.response_head_deadline,
        );
    }

    fn is_active(phase: Phase) bool {
        return switch (phase) {
            .sending, .awaiting_head, .streaming => true,
            .completed, .timed_out, .cancelled, .system_resumed, .stalled => false,
        };
    }

    fn phase_error(phase: Phase) ?anyerror {
        return switch (phase) {
            .timed_out => error.Timeout,
            .cancelled => error.Cancelled,
            .system_resumed => error.SystemResumed,
            .stalled => error.StreamStalled,
            .sending, .awaiting_head, .streaming, .completed => null,
        };
    }
};

pub fn runBoundedHttpOperation(
    comptime Result: type,
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    operation: anytype,
) !Result {
    if (cancel_flag.load(.seq_cst)) {
        debug_trace.logf("stream", "bounded termination cause=cancellation phase=admission", .{});
        return error.Cancelled;
    }
    std.debug.assert(deadline.clock == .awake);

    const zio = io_mod.getIo();
    const now = std.Io.Clock.Timestamp.now(zio, .awake);
    if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) {
        debug_trace.logf("stream", "bounded termination cause=deadline phase=admission", .{});
        return error.Timeout;
    }

    const Event = union(enum) {
        request: anyerror!Result,
        watch: anyerror!BoundedRequestWatch.Outcome,
    };
    const Operation = @TypeOf(operation);
    const Runner = struct {
        fn run(value: Operation) anyerror!Result {
            return value.run();
        }
    };
    const Cleanup = struct {
        fn drain(result_alloc: std.mem.Allocator, select: *std.Io.Select(Event), watch: *BoundedRequestWatch) void {
            watch.stopped.set(select.io);
            while (select.cancel()) |item| switch (item) {
                .request => |request_result| {
                    var late_result = request_result catch continue;
                    late_result.deinit(result_alloc);
                },
                .watch => {},
            };
        }
    };

    var watch: BoundedRequestWatch = .{};
    var select_buffer: [2]Event = undefined;
    var select: std.Io.Select(Event) = .init(zio, &select_buffer);
    select.concurrent(.watch, BoundedRequestWatch.run, .{ &watch, cancel_flag, deadline }) catch |err| {
        return err;
    };
    select.concurrent(.request, Runner.run, .{operation}) catch |err| {
        watch.finish(&select);
        return err;
    };

    const event = select.await() catch |err| {
        Cleanup.drain(alloc, &select, &watch);
        return err;
    };
    switch (event) {
        .request => |request_result| {
            watch.finish(&select);
            if (cancel_flag.load(.seq_cst)) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=request_result", .{});
                var owned_result = request_result catch return error.Cancelled;
                owned_result.deinit(alloc);
                return error.Cancelled;
            }
            return request_result;
        },
        .watch => |watch_result| {
            Cleanup.drain(alloc, &select, &watch);
            const outcome = try watch_result;
            if (outcome == .cancelled) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=control", .{});
                return error.Cancelled;
            }
            if (cancel_flag.load(.seq_cst)) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=deadline_cleanup", .{});
                return error.Cancelled;
            }
            debug_trace.logf("stream", "bounded termination cause=deadline phase=control", .{});
            return error.Timeout;
        },
    }
}

/// Watches one bounded request for cancellation and its deadline. The request
/// owner stops it with `finish` instead of cancelling it: in Zig 0.17 a cancel
/// can interrupt whatever task the watch's worker thread runs next, and an
/// interrupted connect then fails with ISCONN.
const BoundedRequestWatch = struct {
    stopped: std.Io.Event = .unset,

    const Outcome = enum { stopped, cancelled, deadline };

    fn run(
        watch: *BoundedRequestWatch,
        cancel_flag: *std.atomic.Value(bool),
        deadline: ?std.Io.Clock.Timestamp,
    ) anyerror!Outcome {
        const zio = io_mod.getIo();
        while (true) {
            if (cancel_flag.load(.seq_cst)) return .cancelled;
            if (deadline) |limit| {
                const now = std.Io.Clock.Timestamp.now(zio, .awake);
                if (!std.Io.Clock.Timestamp.compare(now, .lt, limit)) return .deadline;
            }
            watch.stopped.waitTimeout(zio, .{ .duration = .{
                .raw = .fromMilliseconds(5),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => continue,
                else => |e| return e,
            };
            return .stopped;
        }
    }

    /// Stops the watch and waits for its event, then releases the select.
    /// Call only when the watch event is the one still outstanding.
    fn finish(watch: *BoundedRequestWatch, select: anytype) void {
        watch.stopped.set(select.io);
        const event = select.queue.getOneUncancelable(select.io) catch |err| switch (err) {
            // Only Select.cancel closes the queue, so nothing is outstanding.
            error.Closed => return,
        };
        std.debug.assert(event == .watch);
        std.debug.assert(select.cancel() == null);
    }
};

const GatewayCancelWatcher = struct {
    fn run(
        done: *std.atomic.Value(bool),
        cancel_flag: *std.atomic.Value(bool),
        system_resumed: ?*std.atomic.Value(bool),
        deadline: ?std.Io.Clock.Timestamp,
        connected_watch: ?*ConnectedRequestWatch,
        stream: std.Io.net.Stream,
    ) void {
        var previous = SuspendClockSample.now();
        while (!done.load(.seq_cst)) {
            if (cancel_flag.load(.seq_cst)) {
                if (connected_watch == null or connected_watch.?.win(.cancelled)) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                }
                return;
            }
            const current = SuspendClockSample.now();
            if (system_resumed != null and suspendGapDetected(previous, current)) {
                if (cancel_flag.load(.seq_cst)) {
                    if (connected_watch == null or connected_watch.?.win(.cancelled)) {
                        stream.shutdown(io_mod.getIo(), .both) catch {};
                    }
                    return;
                }
                if (connected_watch == null or connected_watch.?.win(.system_resumed)) {
                    system_resumed.?.store(true, .seq_cst);
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                }
                return;
            }
            if (deadline) |limit| {
                const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
                if (!std.Io.Clock.Timestamp.compare(now, .lt, limit)) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                    return;
                }
            }
            if (connected_watch) |watch| {
                const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
                if (watch.response_head_expired(now) and watch.win_response_head_timeout()) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                    return;
                }
                if (watch.stream_stall_expired(now) and watch.win_stall_timeout()) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                    return;
                }
                if (watch.phase.load(.seq_cst) == .completed) return;
            }
            previous = current;
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
    }
};

const suspend_gap_tolerance_ns: i128 = 100 * std.time.ns_per_ms;

const SuspendClockSample = struct {
    awake_ns: i128,
    boot_ns: i128,

    fn now() SuspendClockSample {
        const io = io_mod.getIo();
        return .{
            .awake_ns = @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds()),
            .boot_ns = @intCast(std.Io.Clock.Timestamp.now(io, .boot).raw.toNanoseconds()),
        };
    }
};

fn suspendGapDetected(previous: SuspendClockSample, current: SuspendClockSample) bool {
    const awake_elapsed = current.awake_ns - previous.awake_ns;
    const boot_elapsed = current.boot_ns - previous.boot_ns;
    if (awake_elapsed < 0 or boot_elapsed < 0) return false;
    return boot_elapsed - awake_elapsed > suspend_gap_tolerance_ns;
}

pub fn spawnHttpCancelWatcher(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    stream: std.Io.net.Stream,
) !std.Thread {
    return spawn_gateway_cancel_watcher(done, cancel_flag, null, null, null, stream);
}

pub fn spawnHttpCancelWatcherBounded(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    stream: std.Io.net.Stream,
) !std.Thread {
    return spawn_gateway_cancel_watcher(done, cancel_flag, null, deadline, null, stream);
}

/// One shared concrete opener result so every backend reuses the same
/// bounded-operation instantiation instead of specializing per file.
pub const OpenedPost = struct {
    request: ?std.http.Client.Request,

    pub fn deinit(self: *OpenedPost, _: std.mem.Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }

    pub fn take(self: *OpenedPost) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

pub const PostOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    authorization: ?[]const u8,
    extra_headers: []const std.http.Header = &.{},

    pub fn run(self: *PostOperation) !OpenedPost {
        var headers: std.http.Client.Request.Headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .user_agent = .{ .override = user_agent },
        };
        if (self.authorization) |value| headers.authorization = .{ .override = value };
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = headers,
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

pub fn openBoundedPost(
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    operation: *PostOperation,
) !OpenedPost {
    return runBoundedHttpOperation(OpenedPost, alloc, cancel_flag, deadline, operation);
}

pub const CancelWatch = struct {
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn start(self: *CancelWatch, cancel: *std.atomic.Value(bool), deadline: ?std.Io.Clock.Timestamp, connection: std.Io.net.Stream) !void {
        self.done.store(false, .seq_cst);
        self.thread = if (deadline) |limit|
            try spawnHttpCancelWatcherBounded(&self.done, cancel, limit, connection)
        else
            try spawnHttpCancelWatcher(&self.done, cancel, connection);
    }

    pub fn stop(self: *CancelWatch) void {
        self.done.store(true, .seq_cst);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
};

fn spawn_gateway_cancel_watcher(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    system_resumed: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
    connected_watch: ?*ConnectedRequestWatch,
    stream: std.Io.net.Stream,
) !std.Thread {
    if (builtin.is_test) {
        if (test_cancel_watcher_spawn_error) |err| return err;
    }
    return std.Thread.spawn(.{}, GatewayCancelWatcher.run, .{
        done,
        cancel_flag,
        system_resumed,
        deadline,
        connected_watch,
        stream,
    });
}

pub fn isLoopbackHttpUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        uri.user != null or
        uri.password != null or
        uri.port == null)
    {
        return false;
    }

    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

fn deinitGatewayCompletion(alloc: std.mem.Allocator, completion: *types.ModelCompletion) void {
    if (completion.content) |content| alloc.free(content);
    if (completion.generation_id) |id| alloc.free(id);
    if (completion.resolved_provider) |provider| alloc.free(@constCast(provider));
    if (completion.billing) |billing| alloc.free(@constCast(billing.model));
    for (completion.tool_calls) |call| {
        alloc.free(call.id);
        alloc.free(call.name);
        alloc.free(call.arguments_json);
        if (call.provisional_id) |provisional_id| alloc.free(provisional_id);
        if (call.provider_result) |provider_result| alloc.free(provider_result);
    }
    if (completion.tool_calls.len > 0) alloc.free(completion.tool_calls);
    if (completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
    if (completion.provider_state_json) |state| alloc.free(state);
    completion.* = .{};
}

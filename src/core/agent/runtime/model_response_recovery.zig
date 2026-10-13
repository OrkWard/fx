const std = @import("std");

pub const default_max_provider_attempts: usize = 10;
pub const max_retry_after_seconds: u64 = 30;
/// Past this much total recovery time, billable retries throttle to once a
/// minute and the UI shows a patient "still trying" state instead of attempt
/// counters. The turn never dies from transient failure.
const billable_retry_window_ns: u64 = 15 * 60 * std.time.ns_per_s;
const throttled_retry_delay_ns: u64 = 60 * std.time.ns_per_s;

pub const FailureCause = enum {
    /// The network path is provably down (connection refused, unreachable,
    /// DNS failure, dead socket after wake). Nothing was or can be sent.
    connectivity_lost,
    transport_interrupted,
    response_interrupted,
    provider_stream_timeout,
    provider_unavailable,
    rate_limited,
    system_resumed,
    compaction_prepared,
    authentication,
    request_limit_reached,
    content_filter,
};

pub const Delivery = enum {
    definitely_unsent,
    possibly_sent,
};

pub const OutputEvidence = enum {
    none,
    partial,
};

pub const ToolEvidence = enum {
    none,
    proven_unexecuted,
    confirmed,
    uncertain,
};

/// Whether attempts keep making forward progress. A stall (the same failure at
/// the same progress point, repeatedly) is a broken response, not a network
/// problem; retrying it forever is the failure mode budgets used to mask.
pub const Progress = enum {
    unknown,
    advancing,
    stalled,
};

pub const AttemptState = struct {
    consumed: usize,
    limit: usize = default_max_provider_attempts,
};

/// Ephemeral backoff state. AttemptState remains the durable diagnostic budget;
/// exhaustion no longer terminates the turn.
pub const RetryPacingState = union(enum) {
    idle,
    implicit: struct {
        cause: FailureCause,
        attempt: usize,
    },

    fn afterFailure(
        self: RetryPacingState,
        cause: FailureCause,
        retry_after_seconds: ?u64,
    ) RetryPacingState {
        // A zero or missing server hint carries no useful information; a
        // failing endpoint saying "retry instantly" must not disable backoff.
        if (retry_after_seconds != null and retry_after_seconds.? > 0) return .idle;
        return switch (self) {
            .idle => .{ .implicit = .{ .cause = cause, .attempt = 1 } },
            .implicit => |previous| if (previous.cause == cause)
                .{ .implicit = .{
                    .cause = cause,
                    .attempt = previous.attempt +| 1,
                } }
            else
                .{ .implicit = .{ .cause = cause, .attempt = 1 } },
        };
    }
};

pub const Strategy = enum {
    retry_request,
    continue_response,
    regenerate_tool,
    continue_after_confirmed_tool,
    reconcile_tool,
    /// Park the turn and probe connectivity until the path returns. Never
    /// consumes the attempt budget: probes transmit nothing.
    wait_for_connectivity,
    /// Silence is ambiguous (a thinking model and a hung gateway are identical
    /// on the wire). Probe the liveness channel; never retry on silence alone.
    probe_liveness,
    pause,
    stop,
};

pub const RequiredAction = enum {
    none,
    continue_later,
    inspect_uncertain_tool,
    change_request,
    /// The same failure repeated at the same progress point. Surface it as a
    /// broken response instead of restarting forever.
    surface_stall,
};

pub const Evidence = struct {
    cause: FailureCause,
    delivery: Delivery,
    attempts: AttemptState,
    output: OutputEvidence = .none,
    tool: ToolEvidence = .none,
    pacing: RetryPacingState = .idle,
    retry_after_seconds: ?u64 = null,
    cancelled: bool = false,
    progress: Progress = .unknown,
    /// Total wall-clock time spent recovering this turn, when known.
    recovery_elapsed_ns: ?u64 = null,
};

pub const Decision = struct {
    strategy: Strategy,
    delay_ns: u64 = 0,
    next_pacing: RetryPacingState = .idle,
    reserve_provider_attempt: bool = false,
    required_action: RequiredAction = .none,
    /// True once recovery runs longer than the billable window: delays floor at
    /// one minute so billable retransmission throttles without the turn dying.
    throttled: bool = false,

    /// The turn keeps working without asking anyone. Probes and connectivity
    /// waits transmit nothing, so they recover without spending the attempt
    /// budget; ordinary retries reserve one.
    pub fn autoRecovers(self: Decision) bool {
        return self.reserve_provider_attempt or
            self.strategy == .wait_for_connectivity or
            self.strategy == .probe_liveness;
    }
};

/// Pure model-response policy. It describes the next effect but never sleeps,
/// sends, mutates stream state, or persists a checkpoint.
pub noinline fn decide(evidence: Evidence) Decision {
    if (evidence.cancelled) return .{ .strategy = .stop };

    switch (evidence.cause) {
        .content_filter => return .{
            .strategy = .stop,
            .required_action = .change_request,
        },
        // The provider's own request limit does not recover by retrying within
        // this turn. Stop honestly instead of pausing for a manual /continue.
        .request_limit_reached => return .{
            .strategy = .stop,
            .required_action = .continue_later,
        },
        else => {},
    }

    // Connectivity loss waits indefinitely; probes transmit nothing, so there
    // is nothing to budget and nothing to bill. The cadence ramps 1s, 2s, then
    // a 5s cap so a down network is polled gently, not hammered.
    if (evidence.cause == .connectivity_lost) {
        const next_pacing = evidence.pacing.afterFailure(.connectivity_lost, null);
        const probe_attempt = switch (next_pacing) {
            .idle => 1,
            .implicit => |pacing| pacing.attempt,
        };
        return .{
            .strategy = .wait_for_connectivity,
            .delay_ns = connectivityProbeDelayNs(probe_attempt),
            .next_pacing = next_pacing,
            .required_action = .none,
        };
    }

    // A stalled exchange (identical failure, identical progress, repeatedly) is
    // a broken response, not a flaky network. Stop instead of restarting the
    // same failure forever. Scoped to stream evidence: bare status failures
    // (5xx) carry no progress information and keep retrying patiently. Checked
    // before the silence probe: repeated hangs at the same byte offset are not
    // ambiguous, so probing them forever would defeat the stall detector.
    if (evidence.progress == .stalled) {
        return .{
            .strategy = .stop,
            .required_action = .surface_stall,
        };
    }

    // Silence is never a retry trigger. Probe the liveness channel first, on a
    // paced cadence so a provider that always times out cannot hot-loop.
    if (evidence.cause == .provider_stream_timeout) {
        const next_pacing = evidence.pacing.afterFailure(.provider_stream_timeout, null);
        const probe_attempt = switch (next_pacing) {
            .idle => 1,
            .implicit => |pacing| pacing.attempt,
        };
        return .{
            .strategy = .probe_liveness,
            .delay_ns = retryDelayNs(probe_attempt),
            .next_pacing = next_pacing,
            .required_action = if (evidence.tool == .uncertain)
                .inspect_uncertain_tool
            else
                .none,
        };
    }

    const strategy: Strategy = if (evidence.delivery == .definitely_unsent)
        .retry_request
    else switch (evidence.tool) {
        .proven_unexecuted => .regenerate_tool,
        .confirmed => .continue_after_confirmed_tool,
        .uncertain => .reconcile_tool,
        .none => if (evidence.output == .partial)
            .continue_response
        else
            .retry_request,
    };
    const next_pacing = evidence.pacing.afterFailure(
        evidence.cause,
        evidence.retry_after_seconds,
    );
    const throttled = evidence.recovery_elapsed_ns orelse 0 > billable_retry_window_ns;
    // A positive server hint bounds the wait from below, but never below the
    // throttled floor: a misbehaving endpoint retrying "in 1s" forever must
    // not defeat the billable-spend throttle.
    const delay_ns = if (evidence.retry_after_seconds) |seconds| blk: {
        if (seconds == 0) break :blk switch (next_pacing) {
            .idle => unreachable,
            .implicit => |pacing| retryDelayNs(pacing.attempt),
        };
        const bounded_seconds: u64 = @min(seconds, max_retry_after_seconds);
        const hinted_ns = bounded_seconds * std.time.ns_per_s;
        break :blk if (throttled) @max(hinted_ns, throttled_retry_delay_ns) else hinted_ns;
    } else if (throttled)
        throttled_retry_delay_ns
    else switch (next_pacing) {
        .idle => unreachable,
        .implicit => |pacing| retryDelayNs(pacing.attempt),
    };
    return .{
        .strategy = strategy,
        .delay_ns = delay_ns,
        .next_pacing = next_pacing,
        .reserve_provider_attempt = true,
        .throttled = throttled,
    };
}

/// Connectivity probe cadence after `attempt` consecutive connectivity
/// failures: 1 s, 2 s, then 5 s flat. Probes transmit nothing, so the cadence
/// exists to keep the UI calm and the loop cheap, not to protect a provider.
fn connectivityProbeDelayNs(attempt: usize) u64 {
    if (attempt <= 1) return std.time.ns_per_s;
    if (attempt == 2) return 2 * std.time.ns_per_s;
    return 5 * std.time.ns_per_s;
}

/// Delay before the next provider request after `attempt` consecutive implicit
/// backoffs: 250 ms,
/// 1 s, then exponential growth capped at 30 s.
pub fn retryDelayNs(attempt: usize) u64 {
    if (attempt == 0) return 0;
    if (attempt == 1) return 250 * std.time.ns_per_ms;

    var seconds: u64 = 1;
    var current: usize = 2;
    while (current < attempt and seconds < max_retry_after_seconds) : (current += 1) {
        seconds = @min(seconds * 2, max_retry_after_seconds);
    }
    return seconds * std.time.ns_per_s;
}

/// Fast is an optimization, not a recovery requirement. A replay-safe
/// provider outage may fall back to the canonical route without changing the
/// semantic request budget.
pub fn shouldDisableFastRoute(
    fast_mode: bool,
    cause: FailureCause,
    replay_safe: bool,
) bool {
    return fast_mode and cause == .provider_unavailable and replay_safe;
}

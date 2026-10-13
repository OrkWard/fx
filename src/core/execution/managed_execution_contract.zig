const command_contract = @import("command_contract.zig");

pub const max_live_entries: usize = 64;
pub const max_tombstones: usize = 32;
pub const default_yield_time_ms: u32 = 30_000;
pub const max_yield_time_ms: u32 = 30_000;
pub const default_wait_ceiling_ms: u32 = 5_000;
pub const max_wait_ceiling_ms: u32 = 300_000;

pub const Backend = enum {
    captured,
    tty,
};

pub const Persistence = enum {
    process,
    session,
};

pub const TerminalState = enum {
    completed,
    stopped,
    lost,
};

pub const State = union(enum) {
    starting,
    running,
    stopping,
    completed: command_contract.CommandStatus,
    stopped: ?command_contract.CommandStatus,
    lost,

    pub fn isTerminal(self: State) bool {
        return switch (self) {
            .completed, .stopped, .lost => true,
            .starting, .running, .stopping => false,
        };
    }
};

pub const Event = union(enum) {
    child_started,
    stop_requested,
    process_terminated: command_contract.CommandStatus,
    output_drained,
    backend_lost,
};

pub const CompletionBarrier = struct {
    status: ?command_contract.CommandStatus = null,
    output_drained: bool = false,

    pub fn observe(self: CompletionBarrier, event: Event) CompletionBarrier {
        var next = self;
        switch (event) {
            .process_terminated => |status| next.status = status,
            .output_drained => next.output_drained = true,
            .child_started, .stop_requested, .backend_lost => {},
        }
        return next;
    }

    pub fn completedStatus(self: CompletionBarrier) ?command_contract.CommandStatus {
        if (!self.output_drained) return null;
        return self.status;
    }
};

pub const Transition = struct {
    state: State,
    barrier: CompletionBarrier,
};

pub fn transition(
    state: State,
    barrier: CompletionBarrier,
    event: Event,
) Transition {
    if (state.isTerminal()) return .{ .state = state, .barrier = barrier };

    const next_barrier = barrier.observe(event);
    if (next_barrier.completedStatus()) |status| {
        return .{
            .state = switch (state) {
                .stopping => .{ .stopped = status },
                .starting, .running => .{ .completed = status },
                .completed, .stopped, .lost => unreachable,
            },
            .barrier = next_barrier,
        };
    }

    return .{
        .state = switch (event) {
            .child_started => switch (state) {
                .starting => .running,
                .running, .stopping => state,
                .completed, .stopped, .lost => unreachable,
            },
            .stop_requested => switch (state) {
                .starting, .running => .stopping,
                .stopping => .stopping,
                .completed, .stopped, .lost => unreachable,
            },
            .backend_lost => .lost,
            .process_terminated, .output_drained => state,
        },
        .barrier = next_barrier,
    };
}

pub const Admission = enum {
    admit,
    capacity_exhausted,
};

pub fn decideAdmission(live_count: usize) Admission {
    return if (live_count < max_live_entries) .admit else .capacity_exhausted;
}

pub const Presentation = enum {
    observe_initially,
    return_running,
};

pub fn initialPresentation(yield_time_ms: u32) Presentation {
    return if (yield_time_ms == 0) .return_running else .observe_initially;
}

pub const CancellationPoint = enum {
    before_spawn,
    after_spawn_before_publication,
    published_wait,
};

pub const CancellationDecision = enum {
    no_process_effect,
    stop_and_join_unpublished,
    detach_waiter,
};

pub fn cancellationDecision(point: CancellationPoint) CancellationDecision {
    return switch (point) {
        .before_spawn => .no_process_effect,
        .after_spawn_before_publication => .stop_and_join_unpublished,
        .published_wait => .detach_waiter,
    };
}

pub const OutputRange = struct {
    start: u64,
    end: u64,
};

pub const Reservation = struct {
    waiter_id: u64,
    range: OutputRange,
};

pub const DeliveryState = struct {
    committed: u64 = 0,
    reservation: ?Reservation = null,

    pub fn prepare(
        self: DeliveryState,
        waiter_id: u64,
        observed_end: u64,
    ) error{ ExecutionBusy, InvalidOutputRange }!DeliveryState {
        if (self.reservation != null) return error.ExecutionBusy;
        if (observed_end < self.committed) return error.InvalidOutputRange;
        var next = self;
        next.reservation = .{
            .waiter_id = waiter_id,
            .range = .{ .start = self.committed, .end = observed_end },
        };
        return next;
    }

    pub fn commit(
        self: DeliveryState,
        waiter_id: u64,
    ) error{UnknownReservation}!DeliveryState {
        const reservation = self.reservation orelse return error.UnknownReservation;
        if (reservation.waiter_id != waiter_id) return error.UnknownReservation;
        return .{ .committed = reservation.range.end };
    }

    pub fn cancel(
        self: DeliveryState,
        waiter_id: u64,
    ) error{UnknownReservation}!DeliveryState {
        const reservation = self.reservation orelse return error.UnknownReservation;
        if (reservation.waiter_id != waiter_id) return error.UnknownReservation;
        return .{ .committed = self.committed };
    }
};

pub const Tombstone = struct {
    terminal_state: TerminalState,
    status: ?command_contract.CommandStatus,
    delivered_output_end: u64,
};

pub fn toTombstone(
    state: State,
    delivery: DeliveryState,
) error{ NotTerminal, DeliveryPending }!Tombstone {
    if (delivery.reservation != null) return error.DeliveryPending;
    return switch (state) {
        .completed => |status| .{
            .terminal_state = .completed,
            .status = status,
            .delivered_output_end = delivery.committed,
        },
        .stopped => |status| .{
            .terminal_state = .stopped,
            .status = status,
            .delivered_output_end = delivery.committed,
        },
        .lost => .{
            .terminal_state = .lost,
            .status = null,
            .delivered_output_end = delivery.committed,
        },
        .starting, .running, .stopping => error.NotTerminal,
    };
}

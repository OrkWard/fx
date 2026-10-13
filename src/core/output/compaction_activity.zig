const std = @import("std");

/// Process-local identity, distinct from a turn: one turn can compact repeatedly.
pub const OperationId = enum(u64) { _ };
pub const Origin = enum { manual, automatic, provider_overflow };
pub const Stage = enum { preparation, summary, publication };
pub const Publication = enum { not_published, committed, uncertain };
pub const Outcome = enum { succeeded, no_op, busy, cancelled, failed };

pub const Feedback = struct {
    outcome: Outcome,
    stage: Stage = .preparation,
    publication: Publication = .not_published,
    /// Deliberately retains the original erased host/provider error, not text.
    err: ?anyerror = null,
};

pub fn failure(err: anyerror, stage: Stage, cancelled: bool) Feedback {
    return .{
        .outcome = if (err == error.Cancelled or (cancelled and err == error.Aborted)) .cancelled else .failed,
        .stage = stage,
        .publication = if (err == error.SessionPersistenceUncertain) .uncertain else .not_published,
        .err = err,
    };
}

/// Carried only along the error return that actually escaped compaction.
/// It is not inferred from a previous failed operation or from error text.
pub const ErrorProvenance = struct {
    operation_id: OperationId,
    turn_id: ?u64,
    err: anyerror,
};

pub const Phase = union(enum) {
    preparing,
    running: Stage,
    stopping: Stage,
    terminal: Feedback,
};

pub const Operation = struct {
    id: OperationId,
    turn_id: ?u64,
    origin: Origin,
    phase: Phase = .preparing,
    /// Manual admission resets this when queued; automatic consumers use the turn clock.
    started_at_ms: i64,
    expires_at_ms: ?i64 = null,
    dismissed: bool = false,

    pub fn visible(self: Operation, now_ms: i64) bool {
        if (self.dismissed) return false;
        if (self.expires_at_ms) |expiry| if (now_ms >= expiry) return false;
        return switch (self.phase) {
            .terminal => |feedback| feedback.outcome != .succeeded,
            .preparing, .running, .stopping => true,
        };
    }

    pub fn active(self: Operation) bool {
        return self.phase != .terminal;
    }

    pub fn stage(self: Operation) Stage {
        return switch (self.phase) {
            .preparing => .preparation,
            .running, .stopping => |value| value,
            .terminal => |feedback| feedback.stage,
        };
    }
};

/// Fixed-size, allocation-free copy. No borrowed mutable storage or permission snapshot.
pub const Snapshot = struct {
    revision: u64 = 0,
    operation: ?Operation = null,
};

/// Owned exclusively by WorkerRuntime under worker_mutex. Clock inputs are explicit.
pub const State = struct {
    snapshot: Snapshot = .{},
    next_id: u64 = 1,

    pub fn begin(self: *State, origin: Origin, turn_id: ?u64, now_ms: i64) OperationId {
        const id: OperationId = @fromBackingInt(@intCast(self.next_id));
        // Neither counter is reused within a worker lifetime.
        self.next_id += 1;
        self.snapshot.operation = .{ .id = id, .turn_id = turn_id, .origin = origin, .started_at_ms = now_ms };
        self.snapshot.revision += 1;
        return id;
    }

    pub fn queued(self: *State, id: OperationId, turn_id: u64, now_ms: i64) void {
        const op = self.match(id) orelse return;
        if (!op.active()) return;
        op.turn_id = turn_id;
        op.started_at_ms = now_ms;
        self.snapshot.revision += 1;
    }

    pub fn running(self: *State, id: OperationId, stage: Stage) void {
        const op = self.match(id) orelse return;
        if (!op.active()) return;
        const next: Phase = if (op.phase == .stopping) .{ .stopping = stage } else .{ .running = stage };
        if (std.meta.eql(op.phase, next)) return;
        op.phase = next;
        self.snapshot.revision += 1;
    }

    pub fn stopping(self: *State, id: OperationId) void {
        const op = self.match(id) orelse return;
        if (!op.active() or op.phase == .stopping) return;
        op.phase = .{ .stopping = op.stage() };
        self.snapshot.revision += 1;
    }

    pub fn settle(self: *State, id: OperationId, feedback: Feedback, now_ms: i64) void {
        const op = self.match(id) orelse return;
        if (!op.active()) return;
        op.phase = .{ .terminal = feedback };
        op.expires_at_ms = switch (feedback.outcome) {
            .no_op, .busy => now_ms +| 1500,
            .succeeded, .cancelled, .failed => null,
        };
        self.snapshot.revision += 1;
    }

    /// Dismisses only the terminal feedback observed by the caller, never newer work.
    pub fn dismiss(self: *State, id: OperationId, revision: u64) bool {
        if (revision != self.snapshot.revision) return false;
        const op = self.match(id) orelse return false;
        if (op.active() or op.dismissed) return false;
        op.dismissed = true;
        self.snapshot.revision += 1;
        return true;
    }

    pub fn expire(self: *State, id: OperationId, revision: u64, now_ms: i64) bool {
        const op = self.match(id) orelse return false;
        const expiry = op.expires_at_ms orelse return false;
        if (now_ms < expiry) return false;
        return self.dismiss(id, revision);
    }

    fn match(self: *State, id: OperationId) ?*Operation {
        const op = if (self.snapshot.operation) |*value| value else return null;
        return if (op.id == id) op else null;
    }
};

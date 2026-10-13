const std = @import("std");
const approval_registry = @import("approval_registry.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const execution = @import("execution.zig");
const live_metrics = @import("live_metrics.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const permission_request = @import("../permissions/permission_request.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const StartResult = enum { started, already_running };
pub const StartError = error{ OutOfMemory, OwnerClosed, ChildUnavailable, ThreadSpawnFailed };
pub const WaitError = error{ OutOfMemory, ChildUnavailable, StateUnavailable };
pub const CancelError = error{ChildUnavailable};

pub const Observation = struct {
    phase: child_state.Phase,
    outcome: ?child_state.Outcome = null,
    failure: ?types.ModelFailureDiagnostic = null,
    metrics: live_metrics.Snapshot = .{},
};

const Slot = struct {
    owner: *Owner,
    child_id: []u8,
    metrics: live_metrics.LiveMetrics = .{},
    cancel: std.atomic.Value(bool) = .init(false),
    shutdown: std.atomic.Value(bool) = .init(false),
    worker: ?*worker_runtime.WorkerRuntime = null,
    work_id: ?[]const u8 = null,
    route_refs: usize = 0,
    waiters: usize = 0,
    route_changed: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    completion: union(enum) { running, published: Observation, unpublished } = .running,
    done: std.Io.Event = .unset,
};

pub const FeedbackResult = union(enum) {
    receipt: types.SteeringDelivery,
    waiting,
    unavailable,
    cancelled,
    conflict,
    capacity,
};

const Feedback = struct {
    child_id: []u8,
    operation_id: []u8,
    fingerprint: [32]u8,
    receipt: worker_runtime.SteeringReceipt = .{},
    reported: types.SteeringDelivery = .queued,

    fn create(alloc: Allocator, child_id: []const u8, operation_id: []const u8, fingerprint: [32]u8) !*Feedback {
        const item = try alloc.create(Feedback);
        errdefer alloc.destroy(item);
        const child = try alloc.dupe(u8, child_id);
        errdefer alloc.free(child);
        const operation = try alloc.dupe(u8, operation_id);
        item.* = .{ .child_id = child, .operation_id = operation, .fingerprint = fingerprint, .receipt = .{ .operation_id = operation } };
        return item;
    }

    fn deinit(self: *Feedback, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.operation_id);
        alloc.destroy(self);
    }
};

pub const FeedbackUpdate = struct {
    child_id: []const u8,
    operation_id: []const u8,
    delivery: types.SteeringDelivery,
};

pub const Owner = struct {
    alloc: Allocator,
    backend: child_state.Backend,
    state_store: child_state.Store,
    services: execution.Services,
    authority_resolver: *authority.Resolver,
    approvals: *approval_registry.Registry,
    max_history_turns: usize = 8,
    mutex: std.Io.Mutex = .init,
    waiters_changed: std.Io.Condition = .init,
    slots: std.ArrayList(*Slot) = .empty,
    feedback: std.ArrayList(*Feedback) = .empty,
    closed: bool = false,

    fn feedbackReplayLocked(self: *Owner, operation_id: []const u8, fingerprint: [32]u8) ?FeedbackResult {
        for (self.feedback.items) |item| {
            if (!std.mem.eql(u8, item.operation_id, operation_id)) continue;
            return if (std.mem.eql(u8, &item.fingerprint, &fingerprint))
                .{ .receipt = item.receipt.state.load(.seq_cst) }
            else
                .conflict;
        }
        return null;
    }

    pub fn feedbackReplay(self: *Owner, operation_id: []const u8, fingerprint: [32]u8) ?FeedbackResult {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.feedbackReplayLocked(operation_id, fingerprint);
    }

    pub fn steer(
        self: *Owner,
        child_id: []const u8,
        work_id: []const u8,
        operation_id: []const u8,
        fingerprint: [32]u8,
        text: []const u8,
    ) Allocator.Error!FeedbackResult {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return .unavailable;
        if (self.feedbackReplayLocked(operation_id, fingerprint)) |replay| return replay;
        var target: ?*Slot = null;
        for (self.slots.items) |slot| {
            if (std.mem.eql(u8, slot.child_id, child_id)) {
                target = slot;
                break;
            }
        }
        const slot = target orelse {
            const observation = self.observe(child_id) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => .unavailable,
            };
            return if (observation.phase == .running or observation.phase == .awaiting_approval) .unavailable else .waiting;
        };
        if (slot.cancel.load(.seq_cst) or slot.shutdown.load(.seq_cst)) return .cancelled;
        if (slot.completion != .running) return if (slot.completion == .published) .waiting else .unavailable;
        const worker = slot.worker orelse return .waiting;
        if (!std.mem.eql(u8, slot.work_id orelse return .waiting, work_id)) return .waiting;
        if (self.feedback.items.len >= 64) return .capacity;
        try self.feedback.ensureUnusedCapacity(self.alloc, 1);
        const item = try Feedback.create(self.alloc, child_id, operation_id, fingerprint);
        var accepted = false;
        defer if (!accepted) item.deinit(self.alloc);
        const prompt = worker_runtime.QueuedPrompt{
            .prompt = try self.alloc.dupe(u8, text),
            .images = &.{},
            .model = &.{},
            .api_key = &.{},
            .permission_mode = .ask,
            .history = &.{},
            .grants = &.{},
            .steering_receipt = &item.receipt,
        };
        defer if (!accepted) {
            item.receipt.state.store(.not_applied, .seq_cst);
            worker_runtime.freeQueuedPrompt(self.alloc, prompt);
        };
        accepted = try worker.admitActiveSteering(self.alloc, prompt);
        if (!accepted) return .waiting;
        self.feedback.appendAssumeCapacity(item);
        debug_trace.eventf("subagent", "feedback_queued", .{}, "child_id={s} work_id={s} operation={s}", .{ child_id, work_id, operation_id });
        return .{ .receipt = .queued };
    }

    pub fn feedbackUpdates(self: *Owner, arena: Allocator) ![]FeedbackUpdate {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var updates: std.ArrayList(FeedbackUpdate) = .empty;
        for (self.feedback.items) |item| {
            const delivery = item.receipt.state.load(.seq_cst);
            if (delivery == item.reported) continue;
            try updates.append(arena, .{
                .child_id = try arena.dupe(u8, item.child_id),
                .operation_id = try arena.dupe(u8, item.operation_id),
                .delivery = delivery,
            });
        }
        return updates.toOwnedSlice(arena);
    }

    pub fn acknowledgeFeedback(self: *Owner, child_id: []const u8, operation_id: []const u8, delivery: types.SteeringDelivery) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.feedback.items) |item| {
            if (std.mem.eql(u8, item.child_id, child_id) and std.mem.eql(u8, item.operation_id, operation_id)) {
                if (item.receipt.state.load(.seq_cst) == delivery) item.reported = delivery;
                return;
            }
        }
    }

    pub fn hasRunningChild(self: *Owner, child_id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (std.mem.eql(u8, slot.child_id, child_id)) return slot.completion == .running;
        }
        return false;
    }

    pub fn start(self: *Owner, child_id: []const u8) StartError!StartResult {
        start_attempt: while (true) {
            const finished = blk: {
                self.mutex.lockUncancelable(io_mod.getIo());
                defer self.mutex.unlock(io_mod.getIo());
                if (self.closed) return error.OwnerClosed;
                for (self.slots.items, 0..) |slot, index| {
                    if (!std.mem.eql(u8, slot.child_id, child_id)) continue;
                    if (slot.completion == .running) return .already_running;
                    if (slot.waiters != 0) {
                        self.waiters_changed.waitUncancelable(io_mod.getIo(), &self.mutex);
                        continue :start_attempt;
                    }
                    break :blk self.slots.swapRemove(index);
                }
                var feedback_index: usize = 0;
                while (feedback_index < self.feedback.items.len) {
                    const item = self.feedback.items[feedback_index];
                    if (std.mem.eql(u8, item.child_id, child_id) and item.receipt.state.load(.seq_cst) != .queued and item.reported == item.receipt.state.load(.seq_cst)) {
                        _ = self.feedback.swapRemove(feedback_index);
                        item.deinit(self.alloc);
                    } else feedback_index += 1;
                }
                const slot = try self.alloc.create(Slot);
                errdefer self.alloc.destroy(slot);
                slot.* = .{
                    .owner = self,
                    .child_id = try self.alloc.dupe(u8, child_id),
                };
                errdefer self.alloc.free(slot.child_id);
                try self.slots.append(self.alloc, slot);
                errdefer _ = self.slots.pop();
                slot.thread = std.Thread.spawn(.{}, slotMain, .{slot}) catch
                    return error.ThreadSpawnFailed;
                return .started;
            };
            destroySlot(self, finished);
        }
    }

    pub fn wait(
        self: *Owner,
        child_id: []const u8,
        duration: std.Io.Clock.Duration,
    ) WaitError!Observation {
        self.mutex.lockUncancelable(io_mod.getIo());
        var slot: ?*Slot = null;
        for (self.slots.items) |candidate| {
            if (std.mem.eql(u8, candidate.child_id, child_id)) {
                slot = candidate;
                break;
            }
        }
        const active = slot orelse {
            self.mutex.unlock(io_mod.getIo());
            return self.observe(child_id);
        };
        active.waiters += 1;
        self.mutex.unlock(io_mod.getIo());
        active.done.waitTimeout(io_mod.getIo(), .{ .duration = duration }) catch |err| switch (err) {
            error.Timeout, error.Canceled => {},
        };
        self.mutex.lockUncancelable(io_mod.getIo());
        // A finished slot's observation must not follow the registry into a new turn.
        const unpublished = active.completion == .unpublished;
        var observation: WaitError!Observation = switch (active.completion) {
            .published => |completed| completed,
            .unpublished => error.StateUnavailable,
            .running => self.observe(child_id),
        };
        if (observation) |*observed| observed.metrics = active.metrics.snapshot() else |_| {}
        active.waiters -= 1;
        self.waiters_changed.broadcast(io_mod.getIo());
        const reaped = !self.closed and self.takeCompletedSlotLocked(active);
        self.mutex.unlock(io_mod.getIo());
        if (reaped) destroySlot(self, active);
        if (unpublished) return error.StateUnavailable;
        return observation;
    }

    pub fn cancel(self: *Owner, child_id: []const u8) CancelError!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (!std.mem.eql(u8, slot.child_id, child_id)) continue;
            if (slot.completion != .running) return;
            slot.cancel.store(true, .seq_cst);
            if (slot.worker) |worker| worker.requestCancel();
            return;
        }
        return error.ChildUnavailable;
    }

    /// The parent drains tool callers before releasing its borrowed context.
    pub fn cancelAndJoin(self: *Owner, child_id: []const u8) void {
        const slot = blk: {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            for (self.slots.items) |candidate| {
                if (!std.mem.eql(u8, candidate.child_id, child_id)) continue;
                if (candidate.completion == .running) {
                    candidate.cancel.store(true, .seq_cst);
                    // Stop approval waits without changing explicit cancellation to interruption.
                    if (candidate.worker) |worker| worker.requestShutdown();
                }
                candidate.waiters += 1;
                break :blk candidate;
            }
            return;
        };
        debug_trace.eventf("subagent", "steering_child_join_started", .{}, "child_id={s}", .{child_id});
        if (slot.thread) |thread| {
            thread.join();
        }
        self.mutex.lockUncancelable(io_mod.getIo());
        slot.thread = null;
        slot.waiters -= 1;
        self.waiters_changed.broadcast(io_mod.getIo());
        const unpublished = slot.completion == .unpublished;
        const reaped = self.takeCompletedSlotLocked(slot);
        self.mutex.unlock(io_mod.getIo());
        if (reaped) destroySlot(self, slot);
        if (unpublished) debugFailure(child_id, "cancel_join", error.StateUnavailable);
        debug_trace.eventf("subagent", "steering_child_join_finished", .{}, "child_id={s}", .{child_id});
    }

    pub fn recoverInterrupted(self: *Owner) !void {
        var observed = try self.state_store.load(self.alloc);
        defer observed.deinit(self.alloc);
        if (observed.children.len == 0) return;

        var lock = try self.state_store.acquireLock(self.alloc);
        defer lock.release();
        var registry = try self.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const generation = registry.generation;
        registry.interruptActive(self.alloc);
        if (registry.generation != generation) try self.state_store.save(self.alloc, registry);
    }

    pub fn deinit(self: *Owner) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.closed = true;
        for (self.slots.items) |slot| {
            slot.shutdown.store(true, .seq_cst);
            slot.cancel.store(true, .seq_cst);
            if (slot.worker) |worker| worker.requestShutdown();
        }
        self.mutex.unlock(io_mod.getIo());

        for (self.slots.items) |slot| {
            destroySlot(self, slot);
        }
        self.slots.deinit(self.alloc);
        for (self.feedback.items) |item| item.deinit(self.alloc);
        self.feedback.deinit(self.alloc);
        self.* = undefined;
    }

    fn takeCompletedSlotLocked(self: *Owner, slot: *Slot) bool {
        for (self.slots.items, 0..) |candidate, candidate_index| {
            if (candidate == slot and candidate.completion != .running and candidate.waiters == 0) {
                _ = self.slots.swapRemove(candidate_index);
                return true;
            }
        }
        return false;
    }

    fn observe(self: *Owner, child_id: []const u8) WaitError!Observation {
        var lock = self.state_store.acquireLock(self.alloc) catch
            return error.StateUnavailable;
        defer lock.release();
        var registry = self.state_store.load(self.alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.StateUnavailable,
        };
        defer registry.deinit(self.alloc);
        const child = registry.findById(child_id) orelse return error.ChildUnavailable;
        return .{ .phase = child.phase, .outcome = child.last_outcome, .failure = child.last_failure };
    }

    fn phaseTransition(
        raw: *anyopaque,
        child_id: []const u8,
        work_id: []const u8,
        phase: child_state.Phase,
    ) !void {
        const self: *Owner = @ptrCast(@alignCast(raw));
        var lock = try self.state_store.acquireLock(self.alloc);
        defer lock.release();
        var registry = try self.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const child = registry.findById(child_id) orelse return error.ChildUnavailable;
        const active = child.active orelse return error.StaleWork;
        if (!std.mem.eql(u8, active.id, work_id)) return error.StaleWork;
        child.phase = phase;
        registry.generation +|= 1;
        try self.state_store.save(self.alloc, registry);
    }

    fn finish(
        self: *Owner,
        child_id: []const u8,
        work_id: []const u8,
        outcome: child_state.Outcome,
        failure: ?types.ModelFailureDiagnostic,
    ) ?Observation {
        var lock = self.state_store.acquireLock(self.alloc) catch |err| {
            debugFailure(child_id, "state_lock", err);
            return null;
        };
        defer lock.release();
        var registry = self.state_store.load(self.alloc) catch |err| {
            debugFailure(child_id, "state_load", err);
            return null;
        };
        defer registry.deinit(self.alloc);
        registry.finish(self.alloc, child_id, work_id, outcome, failure) catch |err| {
            debugFailure(child_id, "state_finish", err);
            return null;
        };
        self.state_store.save(self.alloc, registry) catch |err| {
            debugFailure(child_id, "state_save", err);
            return null;
        };
        const child = registry.findById(child_id) orelse return null;
        return .{ .phase = child.phase, .outcome = child.last_outcome, .failure = child.last_failure };
    }
};

fn destroySlot(owner: *Owner, slot: *Slot) void {
    if (slot.thread) |thread| thread.join();
    owner.mutex.lockUncancelable(io_mod.getIo());
    while (slot.waiters != 0) owner.waiters_changed.waitUncancelable(io_mod.getIo(), &owner.mutex);
    owner.mutex.unlock(io_mod.getIo());
    std.debug.assert(slot.route_refs == 0);
    owner.alloc.free(slot.child_id);
    owner.alloc.destroy(slot);
}

fn slotMain(slot: *Slot) void {
    const owner = slot.owner;
    const outcome = runOne(slot);
    // Startup must not inspect the old slot between saved and in-memory completion.
    // Take owner before registry, matching cancellation and approval lock ordering.
    owner.mutex.lockUncancelable(io_mod.getIo());
    const completed = owner.finish(slot.child_id, outcome.work_id, outcome.outcome, outcome.failure);
    slot.completion = if (completed) |value| .{ .published = value } else .unpublished;
    slot.done.set(io_mod.getIo());
    owner.mutex.unlock(io_mod.getIo());
    outcome.deinit(owner.alloc);
}

const OneOutcome = struct {
    work_id: []u8,
    outcome: child_state.Outcome,
    failure: ?types.ModelFailureDiagnostic = null,

    fn deinit(self: OneOutcome, alloc: Allocator) void {
        alloc.free(self.work_id);
    }
};

fn runOne(slot: *Slot) OneOutcome {
    const owner = slot.owner;
    var snapshot = loadRunSnapshot(owner, slot.child_id) catch |err| {
        debugFailure(slot.child_id, "run_snapshot", err);
        return fallbackOutcome(owner.alloc, "unknown", .failed);
    };
    defer snapshot.deinit(owner.alloc);
    const work_id = owner.alloc.dupe(u8, snapshot.active.id) catch
        return fallbackOutcome(owner.alloc, "unknown", .failed);

    var child = OpenChild.open(owner, slot.child_id, snapshot.instructions) catch |err|
        return failedOutcome(work_id, "session_resume", err);
    defer child.close(owner.alloc);
    var turn = child.turn(owner.alloc, owner.max_history_turns) catch |err|
        return failedOutcome(work_id, "turn_initialization", err);
    defer turn.deinit();
    turn.live_authority = owner.authority_resolver;
    turn.approval_registry = owner.approvals;
    turn.child_id = slot.child_id;
    turn.active_work_id = snapshot.active.id;
    turn.phase_context = owner;
    turn.phase_fn = Owner.phaseTransition;
    turn.live_metrics = &slot.metrics;
    owner.mutex.lockUncancelable(io_mod.getIo());
    slot.worker = turn.workerRuntime();
    slot.work_id = turn.active_work_id;
    if (slot.cancel.load(.seq_cst)) slot.worker.?.requestShutdown();
    owner.mutex.unlock(io_mod.getIo());
    turn.approval_worker_route = workerRoute(slot);
    defer detachWorker(slot);

    var message = snapshot.active.queuedMessage(
        owner.alloc,
        owner.state_store.parent_id,
        child.overlayInstructions(snapshot.instructions),
    ) catch |err| return failedOutcome(work_id, "message_preparation", err);
    defer message.deinit(owner.alloc);
    const admission = owner.services.capture(owner.alloc, .{
        .child_id = slot.child_id,
        .parent_id = owner.state_store.parent_id,
        .source_id = owner.state_store.parent_id,
        .preferences = turnPreferencesForDurable(child.preferences()),
    }) catch |err| return if (err == error.Cancelled) .{
        .work_id = work_id,
        .outcome = .cancelled,
    } else failedOutcome(work_id, "admission", err);
    @import("../shared/debug_trace.zig").logf(
        "subagent",
        "child turn admitted child_id={s} work_id={s} provider={s} model={s} effort={s}",
        .{
            slot.child_id,
            work_id,
            @tagName(admission.provider),
            admission.model,
            admission.effort.label(),
        },
    );
    var owned_admission = admission;
    defer owned_admission.deinit(owner.alloc);
    const result = owner.services.run(
        &turn,
        message,
        admission,
        &slot.cancel,
    ) catch |err| {
        const outcome: child_state.Outcome = if (slot.shutdown.load(.seq_cst))
            .interrupted
        else if (slot.cancel.load(.seq_cst) or err == error.Cancelled)
            .cancelled
        else
            .failed;
        return .{
            .work_id = work_id,
            .outcome = outcome,
            .failure = if (outcome == .failed)
                turn.failureDiagnostic() orelse execution.failureDiagnosticValue("agent_execution", @errorName(err))
            else
                null,
        };
    };
    if (slot.shutdown.load(.seq_cst)) return .{
        .work_id = work_id,
        .outcome = .interrupted,
    };
    if (slot.cancel.load(.seq_cst)) return .{
        .work_id = work_id,
        .outcome = .cancelled,
    };
    return .{
        .work_id = work_id,
        .outcome = switch (result) {
            .completed => .completed,
            .awaiting_approval, .paused => .interrupted,
        },
    };
}

/// The child session one work item runs in.
const OpenChild = union(enum) {
    v1: session_store.LoadedWritableSession,

    fn open(owner: *Owner, child_id: []const u8, instructions: []const u8) !OpenChild {
        _ = instructions;
        switch (owner.backend) {
            .v1 => |sessions| return .{ .v1 = try sessions.resumeTargetForWrite(
                owner.alloc,
                .{ .id = child_id },
                sessions.workspace_root,
                .{},
            ) },
        }
    }

    fn close(self: *OpenChild, alloc: Allocator) void {
        switch (self.*) {
            .v1 => |*loaded| {
                loaded.log.park();
                loaded.deinit(alloc);
            },
        }
    }

    fn turn(self: *OpenChild, alloc: Allocator, max_history_turns: usize) !execution.TurnContext {
        return switch (self.*) {
            .v1 => |*loaded| execution.TurnContext.init(alloc, loaded, max_history_turns),
        };
    }

    fn preferences(self: *const OpenChild) session_codec.DurableSessionPreferences {
        return switch (self.*) {
            .v1 => |*loaded| loaded.state.preferences,
        };
    }

    /// Instructions live in `children.json`.
    fn overlayInstructions(self: *const OpenChild, registry_instructions: []const u8) []const u8 {
        return switch (self.*) {
            .v1 => registry_instructions,
        };
    }
};

fn workerRoute(slot: *Slot) approval_registry.WorkerRoute {
    return .{
        .context = slot,
        .submit_fn = submitWorkerApproval,
        .cancel_fn = cancelWorkerApproval,
        .pin_fn = pinWorkerRoute,
        .release_fn = releaseWorkerRoute,
    };
}

fn submitWorkerApproval(
    raw: *anyopaque,
    request_id: u64,
    response: permission_request.OwnedPermissionResponse,
    commit: ?worker_runtime.WorkerRuntime.PermissionCommit,
) worker_runtime.WorkerRuntime.PermissionCommitError!worker_runtime.PermissionSubmissionResult {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    const worker = slot.worker orelse {
        var owned = response;
        owned.deinit();
        return .no_pending;
    };
    return worker.submitPermissionResponseAfterCommit(
        request_id,
        response,
        commit,
    );
}

fn cancelWorkerApproval(raw: *anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    if (slot.worker) |worker| worker.cancelApprovalTurn();
}

fn pinWorkerRoute(raw: *anyopaque) bool {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    if (slot.worker == null) return false;
    slot.route_refs += 1;
    return true;
}

fn releaseWorkerRoute(raw: *anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    std.debug.assert(slot.route_refs > 0);
    slot.route_refs -= 1;
    if (slot.route_refs == 0) slot.route_changed.broadcast(io_mod.getIo());
}

fn detachWorker(slot: *Slot) void {
    const owner = slot.owner;
    _ = owner.approvals.invalidateChild(slot.child_id) catch |err|
        debugFailure(slot.child_id, "approval_invalidate", err);
    owner.mutex.lockUncancelable(io_mod.getIo());
    while (slot.route_refs > 0) {
        slot.route_changed.waitUncancelable(io_mod.getIo(), &owner.mutex);
    }
    slot.worker = null;
    slot.work_id = null;
    owner.mutex.unlock(io_mod.getIo());
}

const RunSnapshot = struct {
    active: child_state.ActiveWork,
    instructions: []u8,

    fn deinit(self: *RunSnapshot, alloc: Allocator) void {
        self.active.deinit(alloc);
        if (self.instructions.len > 0) alloc.free(self.instructions);
        self.* = undefined;
    }
};

fn loadRunSnapshot(owner: *Owner, child_id: []const u8) !RunSnapshot {
    var lock = try owner.state_store.acquireLock(owner.alloc);
    defer lock.release();
    var registry = try owner.state_store.load(owner.alloc);
    defer registry.deinit(owner.alloc);
    const child = registry.findById(child_id) orelse return error.ChildUnavailable;
    const active = child.active orelse return error.ChildUnavailable;
    const owned_active = try active.clone(owner.alloc);
    errdefer {
        var value = owned_active;
        value.deinit(owner.alloc);
    }
    const instructions: []u8 = if (child.instructions().len == 0)
        &.{}
    else
        try owner.alloc.dupe(u8, child.instructions());
    return .{
        .active = owned_active,
        .instructions = instructions,
    };
}

/// Borrows the child's durable preferences; a persisted disable stays disabled.
fn turnPreferencesForDurable(
    preferences: session_codec.DurableSessionPreferences,
) execution.TurnPreferences {
    return .{
        .provider = preferences.provider,
        .model = preferences.model,
        .effort = preferences.effort,
    };
}

fn fallbackOutcome(alloc: Allocator, work_id: []const u8, outcome: child_state.Outcome) OneOutcome {
    return .{
        .work_id = alloc.dupe(u8, work_id) catch &.{},
        .outcome = outcome,
    };
}

fn failedOutcome(work_id: []u8, stage: []const u8, err: anyerror) OneOutcome {
    return .{
        .work_id = work_id,
        .outcome = .failed,
        .failure = execution.failureDiagnosticValue(stage, @errorName(err)),
    };
}

fn debugFailure(child_id: []const u8, stage: []const u8, err: anyerror) void {
    @import("../shared/debug_trace.zig").logf(
        "subagent",
        "managed child state update failed child_id={s} stage={s} err={s}",
        .{ child_id, stage, @errorName(err) },
    );
}

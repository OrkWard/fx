const std = @import("std");
const approval_registry = @import("approval_registry.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const managed_owner = @import("managed_owner.zig");
const live_metrics = @import("live_metrics.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const model_contract = @import("model_contract.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const model_provider = @import("../config/model_provider.zig");
const permissions = @import("../permissions/permissions.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
/// Bounds how long a parent wait takes to observe cancellation or steering,
/// and how long the polling loops take to see a child change. The terminal
/// result wait also wakes on child state changes. Status publishing is rate
/// limited separately, so a short pulse only adds cheap wakeups.
const terminal_wait_pulse_ms: u64 = 20;

pub const Defaults = struct {
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool = false,
    ultrafast_mode: bool = false,
    conversation_language: session.ConversationLanguage,
};

pub const ChildRunner = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (
        ?*anyopaque,
        *execution.TurnContext,
        domain.QueuedMessage,
        domain.AdmissionSnapshot,
        *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome = unavailableChildRun,
};

fn unavailableChildRun(
    _: ?*anyopaque,
    _: *execution.TurnContext,
    _: domain.QueuedMessage,
    _: domain.AdmissionSnapshot,
    _: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    return error.ProviderFailed;
}

pub const ProgressSink = struct {
    context: *anyopaque,
    publish_fn: *const fn (*anyopaque, types.SubagentStatus) void,

    pub fn publish(self: ProgressSink, status: types.SubagentStatus) void {
        self.publish_fn(self.context, status);
    }
};

/// Resolves a creation-time model override against the host's model catalog.
/// Returned slices are allocated from the passed allocator and must remain
/// valid for the duration of the `executeManaged` call.
pub const ModelOverrideResolver = struct {
    context: ?*anyopaque = null,
    resolve_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
    ) Allocator.Error!model_contract.ModelCatalogMatch,

    pub fn resolve(
        self: ModelOverrideResolver,
        alloc: Allocator,
        raw_model: []const u8,
    ) Allocator.Error!model_contract.ModelCatalogMatch {
        return self.resolve_fn(self.context, alloc, raw_model);
    }
};

pub const ExecuteOptions = struct {
    caller_id: []const u8,
    invocation_id: []const u8,
    parent_permission_mode: types.PermissionMode = .yolo,
    root_user_intent_context: []const u8 = "",
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    defaults: Defaults,
    max_result_bytes: usize,
    timestamp_ms: i64,
    identity_epoch: u64 = 0,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    steering_worker: ?*worker_runtime.WorkerRuntime = null,
    progress: ?ProgressSink = null,
    model_capability_resolver: ?model_capabilities.Resolver = null,
    model_override_resolver: ?ModelOverrideResolver = null,
};

pub const ManagedExecutionResult = struct {
    success: bool,
    body: []u8,
    /// The final status model is owned by the result allocator.
    final_status: ?types.SubagentStatus = null,
};

pub const ApprovalResolveOptions = struct {
    request_id: []const u8,
    child_id: []const u8,
    decision: types.ToolPermissionDecision,
    feedback: ?[]const u8 = null,
    timestamp_ms: i64,
};

pub const Runtime = struct {
    alloc: Allocator,
    backend: child_state.Backend,
    root_id: []u8,
    host_authority: authority.HostResolver,
    child_runner: ChildRunner,
    approvals: approval_registry.Registry,
    authority_resolver: authority.Resolver,
    managed: managed_owner.Owner,
    admission_mutex: std.Io.Mutex = .init,
    yielded_mutex: std.Io.Mutex = .init,
    yielded: std.ArrayList(YieldedWork) = .empty,

    const YieldedWork = struct { child_id: []u8, work_id: []u8, max_result_bytes: usize, result: ?ManagedExecutionResult = null, delivered: bool = false };
    pub const YieldedResult = struct { child_id: []const u8, work_id: []const u8, body: []const u8, max_result_bytes: usize, delivered: bool, receipt_sequence: u64 = 0 };

    /// Returns a host only after abandoned child work has been recovered.
    /// Borrows the store and callback contexts until deinit.
    pub fn create(
        alloc: Allocator,
        sessions: *session_store.Store,
        root_id: []const u8,
        host_authority: authority.HostResolver,
        child_runner: ChildRunner,
    ) !*Runtime {
        return createWith(alloc, .{ .v1 = sessions }, root_id, host_authority, child_runner);
    }

    fn createWith(
        alloc: Allocator,
        backend: child_state.Backend,
        root_id: []const u8,
        host_authority: authority.HostResolver,
        child_runner: ChildRunner,
    ) !*Runtime {
        try domain.validateId(root_id);
        const runtime = try alloc.create(Runtime);
        errdefer alloc.destroy(runtime);
        const owned_root = try alloc.dupe(u8, root_id);
        errdefer alloc.free(owned_root);
        runtime.* = .{
            .alloc = alloc,
            .backend = backend,
            .root_id = owned_root,
            .host_authority = host_authority,
            .child_runner = child_runner,
            .approvals = undefined,
            .authority_resolver = undefined,
            .managed = undefined,
        };
        runtime.approvals = .{
            .alloc = alloc,
        };
        runtime.authority_resolver = .{
            .backend = backend,
            .root_id = runtime.root_id,
            .host = host_authority,
        };
        runtime.managed = runtime.managedOwnerValue();
        errdefer runtime.approvals.deinit();
        errdefer runtime.managed.deinit();
        try runtime.managed.recoverInterrupted();
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        self.cancelYielded();
        self.yielded.deinit(self.alloc);
        self.managed.deinit();
        self.approvals.deinit();
        self.alloc.free(self.root_id);
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    pub fn rebind(
        self: *Runtime,
        sessions: *session_store.Store,
        child_runner_context: ?*anyopaque,
        host_authority: authority.HostResolver,
    ) void {
        self.backend = .{ .v1 = sessions };
        self.rebindHost(child_runner_context, host_authority);
    }

    /// Points the host's callbacks at a host context that moved; the
    /// backend stays as it is.
    pub fn rebindHost(
        self: *Runtime,
        child_runner_context: ?*anyopaque,
        host_authority: authority.HostResolver,
    ) void {
        self.host_authority = host_authority;
        self.child_runner.context = child_runner_context;
        self.authority_resolver.backend = self.backend;
        self.authority_resolver.root_id = self.root_id;
        self.authority_resolver.host = host_authority;
        self.managed.backend = self.backend;
        self.managed.state_store.backend = self.backend;
        self.managed.services.context = self;
        self.managed.authority_resolver = &self.authority_resolver;
        self.managed.approvals = &self.approvals;
    }

    pub fn pendingApprovalRequest(
        self: *Runtime,
        alloc: Allocator,
    ) !?approval_registry.PendingRequest {
        return self.approvals.firstPendingRequest(alloc, self.root_id);
    }

    pub fn resolveApproval(
        self: *Runtime,
        options: ApprovalResolveOptions,
    ) approval_registry.Error!approval_registry.ResolveResult {
        return switch (try self.approvals.resolve(
            options.request_id,
            options.child_id,
            options.decision,
            options.feedback,
            options.timestamp_ms,
        )) {
            .accepted => .accepted,
            .rejected => .rejected,
        };
    }

    pub fn issueOperationIdentity(
        self: *Runtime,
        invocation_id: []const u8,
    ) u64 {
        _ = self;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("model");
        hash.update(&.{0});
        hash.update(invocation_id);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return std.mem.readInt(u64, digest[0..8], .little) | 1;
    }

    pub fn executeManaged(
        self: *Runtime,
        alloc: Allocator,
        request: *model_contract.Request,
        options: ExecuteOptions,
    ) !ManagedExecutionResult {
        const identity_epoch = if (options.identity_epoch != 0)
            options.identity_epoch
        else
            self.issueOperationIdentity(options.invocation_id);
        const operation_id = try operationIdAlloc(
            alloc,
            options.invocation_id,
            identity_epoch,
        );
        defer alloc.free(operation_id);

        return switch (request.*) {
            .run, .message => blk: {
                if (!std.mem.eql(u8, options.caller_id, self.root_id)) {
                    break :blk self.encodeManaged(alloc, .{
                        .ok = false,
                        .error_code = "caller_unavailable",
                    });
                }
                const resolved_model: ?[]const u8 = switch (try resolveOverrideModel(alloc, request.override(), options)) {
                    .rejected => |failure| break :blk try self.encodeManaged(alloc, failure),
                    .accepted => |model| model,
                };
                var admission_arena = std.heap.ArenaAllocator.init(self.alloc);
                defer admission_arena.deinit();
                var queued_receipt: ?ManagedExecutionResult = null;
                defer if (queued_receipt) |queued| alloc.free(queued.body);
                while (true) {
                    _ = admission_arena.reset(.retain_capacity);
                    const admission_alloc = admission_arena.allocator();
                    if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
                    if (self.managed.feedbackReplay(operation_id, model_contract.requestFingerprint(request.*))) |replay| {
                        break :blk try self.encodeManaged(alloc, switch (replay) {
                            .receipt => |delivery| model_contract.feedbackResult(delivery),
                            else => .{ .ok = false, .error_code = "operation_conflict" },
                        });
                    }
                    var admitted = try self.admitAndStartManagedWork(
                        admission_alloc,
                        request.*,
                        operation_id,
                        options,
                        resolved_model,
                    );
                    defer admitted.deinit(admission_alloc);
                    switch (admitted) {
                        .feedback => |target| {
                            // Allocate the receipt before handing any text to the worker.
                            if (queued_receipt == null) queued_receipt = try self.encodeManaged(alloc, model_contract.feedbackResult(.queued));
                            const result = steer: {
                                self.admission_mutex.lockUncancelable(io_mod.getIo());
                                defer self.admission_mutex.unlock(io_mod.getIo());
                                if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
                                break :steer try self.managed.steer(target.child_id, target.work_id, operation_id, model_contract.requestFingerprint(request.*), request.message.message);
                            };
                            switch (result) {
                                .receipt => |delivery| {
                                    if (delivery == .queued) {
                                        const queued = queued_receipt.?;
                                        queued_receipt = null;
                                        break :blk queued;
                                    }
                                    break :blk try self.encodeManaged(alloc, model_contract.feedbackResult(delivery));
                                },
                                .waiting => {
                                    io_mod.sleep(terminal_wait_pulse_ms * std.time.ns_per_ms);
                                    continue;
                                },
                                .unavailable, .cancelled, .conflict, .capacity => break :blk try self.encodeManaged(alloc, .{
                                    .ok = false,
                                    .error_code = switch (result) {
                                        .unavailable => "state_unavailable",
                                        .cancelled => "child_cancelled",
                                        .conflict => "operation_conflict",
                                        .capacity => "feedback_capacity",
                                        else => unreachable,
                                    },
                                }),
                            }
                        },
                        .rejected => |failure| {
                            break :blk self.encodeManaged(alloc, .{
                                .ok = false,
                                .error_code = failure.code,
                            });
                        },
                        .ready => |ready| {
                            const result = try self.observeManagedState(
                                alloc,
                                ready.child_id,
                                operation_id,
                                effectiveDefaults(options.defaults, request.override(), resolved_model),
                                options.progress,
                                options.cancel_flag,
                                options.steering_worker,
                                options.model_capability_resolver,
                            );
                            break :blk result;
                        },
                        .completed => |completed| break :blk self.completeManagedResult(
                            alloc,
                            completed.child_id,
                            operation_id,
                            completed.observation,
                        ),
                    }
                }
            },
        };
    }

    const OverrideModelResolution = union(enum) {
        /// Resolved canonical catalog ID, or null to keep the raw override.
        accepted: ?[]const u8,
        rejected: model_contract.Result,
    };

    /// Resolves a creation-time model override against the model catalog before
    /// any child session exists, so an unknown or ambiguous name fails fast
    /// with actionable guidance instead of dying in the child after a wasted
    /// gateway request. Without a resolver (or a ready catalog) the raw
    /// override passes through and the gateway remains the final arbiter.
    fn resolveOverrideModel(
        alloc: Allocator,
        override: model_contract.Override,
        options: ExecuteOptions,
    ) !OverrideModelResolution {
        const raw_model = override.model orelse return .{ .accepted = null };
        // Only the gateway catalog is an authoritative model list. Configured
        // providers (OpenAI-compatible endpoints) accept arbitrary model IDs,
        // so overrides for those children pass through to the provider.
        if (options.defaults.provider != .gateway) {
            debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=non_gateway_provider", .{raw_model});
            return .{ .accepted = null };
        }
        const resolver = options.model_override_resolver orelse {
            debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=no_resolver", .{raw_model});
            return .{ .accepted = null };
        };
        switch (try resolver.resolve(alloc, raw_model)) {
            .no_catalog => {
                debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=no_catalog", .{raw_model});
                return .{ .accepted = null };
            },
            .matched => |id| {
                if (!std.mem.eql(u8, id, raw_model)) {
                    debug_trace.logf(
                        "subagent",
                        "model override resolved raw={s} resolved={s}",
                        .{ raw_model, id },
                    );
                }
                return .{ .accepted = id };
            },
            .ambiguous => |candidates| {
                debug_trace.logf(
                    "subagent",
                    "model override rejected raw={s} code=ambiguous_model candidates={d}",
                    .{ raw_model, candidates.len },
                );
                return .{ .rejected = .{
                    .ok = false,
                    .error_code = "ambiguous_model",
                    .result = try modelOverrideFailureMessage(alloc, .ambiguous, raw_model, candidates),
                } };
            },
            .unknown => |candidates| {
                debug_trace.logf(
                    "subagent",
                    "model override rejected raw={s} code=unknown_model candidates={d}",
                    .{ raw_model, candidates.len },
                );
                return .{ .rejected = .{
                    .ok = false,
                    .error_code = "unknown_model",
                    .result = try modelOverrideFailureMessage(alloc, .unknown, raw_model, candidates),
                } };
            },
        }
    }

    fn managedOwnerValue(self: *Runtime) managed_owner.Owner {
        return .{
            .alloc = self.alloc,
            .backend = self.backend,
            .state_store = self.childStateStore(),
            .services = .{
                .context = self,
                .capture_fn = captureAdmission,
                .run_fn = runChild,
            },
            .authority_resolver = &self.authority_resolver,
            .approvals = &self.approvals,
        };
    }

    fn childStateStore(self: *Runtime) child_state.Store {
        return .{
            .backend = self.backend,
            .parent_id = self.root_id,
        };
    }

    const ManagedAdmission = union(enum) {
        ready: struct { child_id: []u8 },
        feedback: struct { child_id: []u8, work_id: []u8 },
        completed: struct {
            child_id: []u8,
            observation: managed_owner.Observation,
        },
        rejected: struct {
            child_id: ?[]u8 = null,
            code: []const u8,
        },

        fn deinit(self: *ManagedAdmission, alloc: Allocator) void {
            switch (self.*) {
                .ready => |ready| alloc.free(ready.child_id),
                .feedback => |value| {
                    alloc.free(value.child_id);
                    alloc.free(value.work_id);
                },
                .completed => |completed| alloc.free(completed.child_id),
                .rejected => |failure| if (failure.child_id) |child_id| {
                    alloc.free(child_id);
                },
            }
            self.* = undefined;
        }
    };

    fn admitAndStartManagedWork(
        self: *Runtime,
        alloc: Allocator,
        request: model_contract.Request,
        operation_id: []const u8,
        options: ExecuteOptions,
        resolved_model: ?[]const u8,
    ) !ManagedAdmission {
        // A running registry entry must not be exposed before its Slot exists.
        // Release the registry lock before taking the managed-owner lock.
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
        var admitted = try self.admitManagedWork(alloc, request, operation_id, options, resolved_model);
        errdefer admitted.deinit(alloc);
        if (admitted == .ready) {
            const child_id = admitted.ready.child_id;
            try self.retainYielded(child_id, operation_id, options.max_result_bytes, if (options.steering_worker != null) 64 else child_state.max_children);
            _ = self.managed.start(child_id) catch |err| {
                debug_trace.eventf("subagent", "steering_wait_registration_dropped", .{}, "child_id={s} work_id={s} reason=start_failed error={s}", .{ child_id, operation_id, @errorName(err) });
                self.removeYielded(child_id, operation_id);
                return err;
            };
        }
        return admitted;
    }

    fn admitManagedWork(
        self: *Runtime,
        alloc: Allocator,
        request: model_contract.Request,
        operation_id: []const u8,
        options: ExecuteOptions,
        resolved_model: ?[]const u8,
    ) !ManagedAdmission {
        const fingerprint = model_contract.requestFingerprint(request);
        const defaults = effectiveDefaults(options.defaults, request.override(), resolved_model);
        debug_trace.logf(
            "subagent",
            "admission requested operation={s} action={s} agent={s} override={s}",
            .{
                operation_id,
                @tagName(request.action()),
                request.agentName() orelse "none",
                if (request.override().present()) "yes" else "no",
            },
        );
        var lock = try self.managed.state_store.acquireLock(alloc);
        defer lock.release();
        var registry = try self.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        if (registry.findByOperation(operation_id)) |existing| {
            const observed = child_state.Registry.operationFingerprint(
                existing.*,
                operation_id,
            ) orelse return managedAdmissionRejected(
                alloc,
                existing.id,
                "operation_conflict",
            );
            if (!std.mem.eql(u8, &observed, &fingerprint)) {
                debug_trace.logf(
                    "subagent",
                    "admission rejected operation={s} child_id={s} code=operation_conflict",
                    .{ operation_id, existing.id },
                );
                return managedAdmissionRejected(
                    alloc,
                    existing.id,
                    "operation_conflict",
                );
            }
            try self.ensureManagedChildSession(
                alloc,
                existing.id,
                operation_id,
                defaults,
            );
            if (existing.last_work_id) |work_id| {
                if (std.mem.eql(u8, work_id, operation_id)) return .{ .completed = .{
                    .child_id = try alloc.dupe(u8, existing.id),
                    .observation = .{
                        .phase = existing.phase,
                        .outcome = existing.last_outcome,
                        .failure = existing.last_failure,
                    },
                } };
            }
            return managedAdmissionReady(alloc, existing.id);
        }

        var active = try makeManagedWork(
            alloc,
            operation_id,
            fingerprint,
            request,
            options,
        );
        defer active.deinit(alloc);
        switch (request) {
            .run => {
                const child_id = try session_store.generateSessionId(alloc);
                defer alloc.free(child_id);
                try registry.appendOneOff(alloc, child_id, active);
                try self.managed.state_store.save(alloc, registry);
                try self.ensureManagedChildSession(
                    alloc,
                    child_id,
                    active.id,
                    defaults,
                );
                return managedAdmissionReady(
                    alloc,
                    registry.children[registry.children.len - 1].id,
                );
            },
            .message => |message| {
                if (registry.findPersistent(message.agent)) |child| {
                    if (request.override().present()) {
                        debug_trace.logf(
                            "subagent",
                            "admission rejected operation={s} child_id={s} agent={s} code=override_after_create",
                            .{ operation_id, child.id, message.agent },
                        );
                        return managedAdmissionRejected(
                            alloc,
                            child.id,
                            "override_after_create",
                        );
                    }
                    switch (model_contract.plan(request, .{ .kind = .persistent, .phase = child.phase })) {
                        .steer_persistent => {
                            const active_work = child.active orelse return managedAdmissionRejected(alloc, child.id, "state_unavailable");
                            const id = try alloc.dupe(u8, child.id);
                            errdefer alloc.free(id);
                            return .{ .feedback = .{ .child_id = id, .work_id = try alloc.dupe(u8, active_work.id) } };
                        },
                        .reject => |code| return managedAdmissionRejected(alloc, child.id, @tagName(code)),
                        .continue_persistent => {},
                        .create_one_off, .create_persistent => unreachable,
                    }
                    if (self.hasYieldedChild(child.id)) try self.capturePriorYielded(child.*);
                    const started = try registry.startPersistentWork(
                        alloc,
                        message.agent,
                        message.instructions,
                        active,
                    );
                    try self.managed.state_store.save(alloc, registry);
                    return managedAdmissionReady(alloc, started.id);
                }
                const child_id = try session_store.generateSessionId(alloc);
                defer alloc.free(child_id);
                try registry.appendPersistent(
                    alloc,
                    child_id,
                    message.agent,
                    message.instructions orelse "",
                    active,
                );
                try self.managed.state_store.save(alloc, registry);
                try self.ensureManagedChildSession(
                    alloc,
                    child_id,
                    active.id,
                    defaults,
                );
                return managedAdmissionReady(
                    alloc,
                    registry.children[registry.children.len - 1].id,
                );
            },
        }
    }

    fn ensureManagedChildSession(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        defaults: Defaults,
    ) !void {
        const sessions = switch (self.backend) {
            .v1 => |value| value,
        };
        var state = try freshChildState(
            alloc,
            child_id,
            sessions.workspace_root,
            work_id,
            defaults,
        );
        defer state.deinit(alloc);
        if (sessions.startWritableSession(alloc, state)) |writable_value| {
            var writable = writable_value;
            writable.log.park();
            writable.deinit(alloc);
            debug_trace.logf(
                "subagent",
                "child session created child_id={s} work_id={s} provider={s} model={s} effort={s} fast_mode={} ultrafast_mode={}",
                .{
                    child_id,
                    work_id,
                    @tagName(state.preferences.provider),
                    state.preferences.model,
                    state.preferences.effort.label(),
                    state.preferences.fast_mode,
                    state.preferences.ultrafast_mode,
                },
            );
        } else |err| switch (err) {
            error.SessionAlreadyExists => {},
            else => return err,
        }
        try self.childStateStore().markChildSession(alloc, child_id);
    }

    fn observeManagedState(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        fallback_defaults: Defaults,
        progress: ?ProgressSink,
        cancel_flag: ?*std.atomic.Value(bool),
        steering_worker: ?*worker_runtime.WorkerRuntime,
        model_capability_resolver: ?model_capabilities.Resolver,
    ) !ManagedExecutionResult {
        var status = self.startStatusPublisher(alloc, child_id, fallback_defaults, progress, model_capability_resolver) catch StatusPublisher{
            .model = fallback_defaults.model,
            .effort = fallback_defaults.effort,
        };
        defer status.deinit(alloc);
        status.tick(.{}, io_mod.milliTimestamp());
        while (true) {
            if (cancel_flag) |flag| {
                if (flag.load(.seq_cst)) {
                    debug_trace.eventf("subagent", "parent_cancel_propagated", .{}, "child_id={s} work_id={s}", .{ child_id, work_id });
                    self.managed.cancel(child_id) catch |err| switch (err) {
                        error.ChildUnavailable => {},
                    };
                    return error.Cancelled;
                }
            }
            if (try self.takeCapturedResult(alloc, child_id, work_id)) |result| return result;
            const observation = self.managed.wait(child_id, .{
                .clock = .awake,
                .raw = .fromMilliseconds(terminal_wait_pulse_ms),
            }) catch |err| {
                if (try self.takeCapturedResult(alloc, child_id, work_id)) |result| return result;
                if (!self.managed.hasRunningChild(child_id)) {
                    // A timed-out observation can leave a completed slot to drain.
                    self.managed.cancelAndJoin(child_id);
                    debug_trace.eventf("subagent", "steering_wait_registration_dropped", .{}, "child_id={s} work_id={s} reason=observation_failed_no_runner error={s}", .{ child_id, work_id, @errorName(err) });
                    self.removeYielded(child_id, work_id);
                }
                return self.encodeManaged(alloc, .{
                    .ok = false,
                    .error_code = switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ChildUnavailable => "child_unavailable",
                        error.StateUnavailable => "state_unavailable",
                    },
                });
            };
            if (try self.takeCapturedResult(alloc, child_id, work_id)) |result| return result;
            switch (observation.phase) {
                .running, .awaiting_approval => {
                    status.tick(observation.metrics, io_mod.milliTimestamp());
                    if (steering_worker) |worker| {
                        if (worker.hasPendingPlainSteering()) {
                            debug_trace.eventf("subagent", "steering_wait_yielded", .{}, "child_id={s} work_id={s} child_cancelled=false", .{ child_id, work_id });
                            const pending_text = try alloc.print("{s}\nchild_id={s} work_id={s}", .{ model_contract.steering_pending_result, child_id, work_id });
                            defer alloc.free(pending_text);
                            var pending = try self.encodeManaged(alloc, .{ .ok = true, .pending = true, .result = pending_text });
                            if (status.sink != null) attachStatusPresentation(alloc, &pending, status.current(observation.metrics));
                            return pending;
                        }
                    }
                    continue;
                },
                .idle, .finished, .interrupted => {},
            }
            var result = try self.completeManagedResult(alloc, child_id, work_id, observation);
            if (status.sink != null) attachStatusPresentation(alloc, &result, status.current(observation.metrics));
            self.removeYielded(child_id, work_id);
            return result;
        }
    }

    fn hasYieldedChild(self: *Runtime, child_id: []const u8) bool {
        self.yielded_mutex.lockUncancelable(io_mod.getIo());
        defer self.yielded_mutex.unlock(io_mod.getIo());
        for (self.yielded.items) |item| if (!item.delivered and std.mem.eql(u8, item.child_id, child_id)) return true;
        return false;
    }

    // Registry is held by admission. Preserve the old work's result before a
    // newer generation can become observable through this child ID.
    fn capturePriorYielded(self: *Runtime, child: child_state.Child) !void {
        self.yielded_mutex.lockUncancelable(io_mod.getIo());
        defer self.yielded_mutex.unlock(io_mod.getIo());
        for (self.yielded.items) |*item| {
            if (item.delivered or item.result != null or !std.mem.eql(u8, item.child_id, child.id)) continue;
            if (!std.mem.eql(u8, item.work_id, child.last_work_id orelse return error.StaleWork)) return error.StaleWork;
            item.result = try self.completeManagedResult(self.alloc, child.id, item.work_id, .{
                .phase = child.phase,
                .outcome = child.last_outcome,
                .failure = child.last_failure,
            });
        }
    }

    fn takeCapturedResult(self: *Runtime, alloc: Allocator, child_id: []const u8, work_id: []const u8) !?ManagedExecutionResult {
        self.yielded_mutex.lockUncancelable(io_mod.getIo());
        defer self.yielded_mutex.unlock(io_mod.getIo());
        for (self.yielded.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item.child_id, child_id) or !std.mem.eql(u8, item.work_id, work_id)) continue;
            const stored = item.result orelse return null;
            const result = ManagedExecutionResult{ .success = stored.success, .body = try alloc.dupe(u8, stored.body) };
            _ = self.yielded.orderedRemove(index);
            self.alloc.free(item.child_id);
            self.alloc.free(item.work_id);
            self.alloc.free(stored.body);
            return result;
        }
        return null;
    }

    fn retainYielded(self: *Runtime, child_id: []const u8, work_id: []const u8, max_result_bytes: usize, capacity: usize) !void {
        self.yielded_mutex.lockUncancelable(io_mod.getIo());
        defer self.yielded_mutex.unlock(io_mod.getIo());
        for (self.yielded.items) |item| if (std.mem.eql(u8, item.work_id, work_id)) return;
        if (self.yielded.items.len >= capacity) return error.TooManyYieldedChildren;
        const child = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(child);
        const work = try self.alloc.dupe(u8, work_id);
        errdefer self.alloc.free(work);
        try self.yielded.append(self.alloc, .{ .child_id = child, .work_id = work, .max_result_bytes = max_result_bytes });
        debug_trace.eventf("subagent", "steering_wait_registered", .{}, "child_id={s} work_id={s} tracked={d}", .{ child_id, work_id, self.yielded.items.len });
    }

    /// Main-loop-only; callers finish tool dispatch before inspecting completions.
    /// Returned values belong to arena. Acknowledged results remain context until
    /// the main execution ends; they are not delivered as a second tool response.
    pub fn prepareYielded(self: *Runtime, arena: Allocator) ![]YieldedResult {
        var results: std.ArrayList(YieldedResult) = .empty;
        for (self.yielded.items) |*item| {
            if (item.result == null) {
                const state = try self.managed.wait(item.child_id, .{ .clock = .awake, .raw = .fromMilliseconds(0) });
                if (state.phase == .running or state.phase == .awaiting_approval) continue;
                item.result = try self.completeManagedResult(self.alloc, item.child_id, item.work_id, state);
                debug_trace.eventf("subagent", "steering_result_captured", .{}, "child_id={s} work_id={s} phase={s} result_bytes={d}", .{ item.child_id, item.work_id, @tagName(state.phase), item.result.?.body.len });
            }
            try results.append(arena, .{
                .child_id = try arena.dupe(u8, item.child_id),
                .work_id = try arena.dupe(u8, item.work_id),
                .body = try arena.dupe(u8, item.result.?.body),
                .max_result_bytes = item.max_result_bytes,
                .delivered = item.delivered,
            });
        }
        for (try self.managed.feedbackUpdates(arena)) |update| {
            try results.append(arena, .{
                .child_id = update.child_id,
                .work_id = update.operation_id,
                .body = try model_contract.encodeResultAlloc(arena, model_contract.feedbackResult(update.delivery)),
                .max_result_bytes = tool_result_limits.min_configured_tool_result_bytes,
                .delivered = false,
                .receipt_sequence = @as(u64, @backingInt(update.delivery)) + 1,
            });
        }
        return results.toOwnedSlice(arena);
    }

    pub fn acknowledgeFeedback(self: *Runtime, child_id: []const u8, operation_id: []const u8, sequence: u64) void {
        const delivery = std.enums.fromInt(types.SteeringDelivery, sequence -| 1) orelse return;
        self.managed.acknowledgeFeedback(child_id, operation_id, delivery);
    }

    pub fn acknowledgeYielded(self: *Runtime, child_id: []const u8, work_id: []const u8) void {
        for (self.yielded.items) |*item| {
            if (item.delivered or !std.mem.eql(u8, item.child_id, child_id) or !std.mem.eql(u8, item.work_id, work_id)) continue;
            item.delivered = true;
            debug_trace.eventf("subagent", "steering_result_delivered", .{}, "child_id={s} work_id={s}", .{ child_id, work_id });
            return;
        }
    }

    fn removeYielded(self: *Runtime, child_id: []const u8, work_id: []const u8) void {
        self.yielded_mutex.lockUncancelable(io_mod.getIo());
        defer self.yielded_mutex.unlock(io_mod.getIo());
        for (self.yielded.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item.child_id, child_id) or !std.mem.eql(u8, item.work_id, work_id)) continue;
            _ = self.yielded.orderedRemove(index);
            self.alloc.free(item.child_id);
            self.alloc.free(item.work_id);
            if (item.result) |result| self.alloc.free(result.body);
            return;
        }
    }

    /// Main-loop-only after tool dispatch drains; completed but undelivered work counts.
    pub fn hasPendingYielded(self: *const Runtime) bool {
        for (self.yielded.items) |item| {
            if (!item.delivered) return true;
        }
        return false;
    }

    pub fn waitYielded(self: *Runtime, worker: *worker_runtime.WorkerRuntime) !bool {
        if (!self.hasPendingYielded()) return false;
        debug_trace.eventf("subagent", "steering_parent_waiting", .{}, "pending={d}", .{self.yielded.items.len});
        while (true) {
            const cancelled = worker.worker_cancel_requested.load(.seq_cst);
            const steering = worker.hasPendingPlainSteering();
            if (cancelled or steering) {
                debug_trace.eventf("subagent", "steering_parent_woken", .{ .turn_id = worker.activeTurnId() }, "cancel_requested={} plain_steering={}", .{ cancelled, steering });
                return true;
            }
            for (self.yielded.items) |item| {
                if (item.delivered) continue;
                const state = try self.managed.wait(item.child_id, .{ .clock = .awake, .raw = .fromMilliseconds(0) });
                if (state.phase != .running and state.phase != .awaiting_approval) {
                    debug_trace.eventf("subagent", "steering_parent_woken", .{ .turn_id = worker.activeTurnId() }, "child_id={s} work_id={s} phase={s}", .{ item.child_id, item.work_id, @tagName(state.phase) });
                    return true;
                }
            }
            io_mod.sleep(terminal_wait_pulse_ms * std.time.ns_per_ms);
        }
    }

    /// Drain before the main execution releases context borrowed by child runners.
    pub fn cancelYielded(self: *Runtime) void {
        for (self.yielded.items) |item| {
            if (item.delivered) continue;
            self.managed.cancel(item.child_id) catch |err| debug_trace.logf("subagent", "steering cancellation child_id={s} error={s}", .{ item.child_id, @errorName(err) });
        }
        for (self.yielded.items) |item| {
            if (!item.delivered) self.managed.cancelAndJoin(item.child_id);
            if (item.result) |result| self.alloc.free(result.body);
            debug_trace.eventf("subagent", "steering_continuation_released", .{}, "child_id={s} work_id={s} delivered={} reason=parent_turn_end", .{ item.child_id, item.work_id, item.delivered });
            self.alloc.free(item.child_id);
            self.alloc.free(item.work_id);
        }
        self.yielded.clearRetainingCapacity();
    }

    fn completeManagedResult(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        observation: managed_owner.Observation,
    ) !ManagedExecutionResult {
        const result = try self.managedResultText(alloc, child_id, work_id);
        defer if (result) |text| alloc.free(text);
        const failure_text = if (observation.outcome == .failed)
            try formatFailedResult(alloc, if (observation.failure) |*failure| failure.view() else null, result)
        else
            null;
        defer if (failure_text) |text| alloc.free(text);
        return self.encodeManaged(alloc, terminalResult(observation, failure_text orelse result));
    }

    fn managedResultText(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
    ) !?[]u8 {
        switch (self.backend) {
            .v1 => |sessions| {
                var state = sessions.loadReadOnly(alloc, child_id) catch return null;
                defer state.deinit(alloc);
                const text = assistantTextForWork(state.history, work_id) orelse return null;
                return @as(?[]u8, try alloc.dupe(u8, text));
            },
        }
    }

    /// A child's saved preferences, read without opening it. Caller owns.
    fn childPreferences(self: *Runtime, alloc: Allocator, child_id: []const u8) !session_codec.DurableSessionPreferences {
        switch (self.backend) {
            .v1 => |sessions| {
                var state = try sessions.loadReadOnly(alloc, child_id);
                defer state.deinit(alloc);
                const model = try alloc.dupe(u8, state.preferences.model);
                var preferences = state.preferences;
                preferences.model = model;
                return preferences;
            },
        }
    }

    fn encodeManaged(
        self: *Runtime,
        alloc: Allocator,
        result: model_contract.Result,
    ) !ManagedExecutionResult {
        _ = self;
        return .{
            .success = result.ok,
            .body = try model_contract.encodeResultAlloc(alloc, result),
        };
    }

    fn startStatusPublisher(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        fallback: Defaults,
        sink: ?ProgressSink,
        model_capability_resolver: ?model_capabilities.Resolver,
    ) Allocator.Error!StatusPublisher {
        var model: []u8 = undefined;
        var effort: types.ReasoningEffort = undefined;
        if (self.childPreferences(alloc, child_id)) |loaded| {
            var preferences = loaded;
            defer preferences.deinit(alloc);
            model = try alloc.dupe(u8, preferences.model);
            effort = preferences.effort;
        } else |err| {
            debug_trace.eventf("subagent", "status_publisher_fallback", .{}, "child_id={s} reason=session_load_failed error={s}", .{ child_id, @errorName(err) });
            model = try alloc.dupe(u8, fallback.model);
            effort = fallback.effort;
        }
        var context_window: ?u32 = null;
        if (model_capability_resolver) |resolver| {
            var resolve_arena = std.heap.ArenaAllocator.init(alloc);
            defer resolve_arena.deinit();
            if (resolver.resolve(resolve_arena.allocator(), model)) |caps| {
                context_window = caps.context_window;
            } else |_| {}
        }
        return .{
            .sink = sink,
            .model = model,
            .owns_model = true,
            .effort = effort,
            .context_window = context_window,
        };
    }
};

const StatusPublisher = struct {
    sink: ?ProgressSink = null,
    model: []const u8,
    owns_model: bool = false,
    effort: types.ReasoningEffort,
    context_window: ?u32 = null,
    last_publish_ms: ?i64 = null,
    last_metrics: ?live_metrics.Snapshot = null,

    fn deinit(self: *StatusPublisher, alloc: Allocator) void {
        if (self.owns_model) alloc.free(@constCast(self.model));
        self.* = undefined;
    }

    fn current(self: *const StatusPublisher, metrics: live_metrics.Snapshot) types.SubagentStatus {
        return .{
            .model = self.model,
            .effort = self.effort,
            .input_tokens = metrics.input_tokens,
            .context_window = self.context_window,
        };
    }

    fn tick(self: *StatusPublisher, metrics: live_metrics.Snapshot, now_ms: i64) void {
        const changed = if (self.last_metrics) |last| !std.meta.eql(metrics, last) else true;
        if (!shouldPublish(self.last_publish_ms, now_ms, changed)) return;
        if (self.sink) |sink| sink.publish(self.current(metrics));
        self.last_publish_ms = now_ms;
        self.last_metrics = metrics;
    }
};

fn attachStatusPresentation(
    alloc: Allocator,
    result: *ManagedExecutionResult,
    status: types.SubagentStatus,
) void {
    const model = alloc.dupe(u8, status.model) catch return;
    result.final_status = .{
        .model = model,
        .effort = status.effort,
        .input_tokens = status.input_tokens,
        .context_window = status.context_window,
    };
}

const status_min_publish_interval_ms: i64 = 250;

fn shouldPublish(last_publish_ms: ?i64, now_ms: i64, changed: bool) bool {
    const last = last_publish_ms orelse return true;
    if (now_ms < last) return false;
    return changed and now_ms - last >= status_min_publish_interval_ms;
}

fn operationIdAlloc(
    alloc: Allocator,
    invocation_id: []const u8,
    epoch: u64,
) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(invocation_id, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.print("fxop:2:m:{d}:{s}", .{ epoch, &hex });
}

fn formatFailedResult(alloc: Allocator, failure: ?[]const u8, partial: ?[]const u8) ![]u8 {
    const reason = failure orelse "failure reason unavailable";
    const text = partial orelse "";
    return alloc.print("Subagent failed: {s}. Earlier tool calls may have completed; their effects are not rolled back.{s}{s}", .{
        reason,
        if (text.len > 0) "\n\nPartial result:\n" else "",
        text,
    });
}

fn terminalResult(
    observation: managed_owner.Observation,
    result: ?[]const u8,
) model_contract.Result {
    return switch (observation.outcome orelse return .{
        .ok = false,
        .result = result,
        .error_code = "child_result_unavailable",
    }) {
        .completed => if (result != null) .{
            .ok = true,
            .result = result,
        } else .{
            .ok = false,
            .error_code = "child_result_unavailable",
        },
        .failed => .{
            .ok = false,
            .result = result,
            .error_code = "child_failed",
        },
        .cancelled => .{
            .ok = false,
            .result = result,
            .error_code = "child_cancelled",
        },
        .interrupted => .{
            .ok = false,
            .result = result,
            .error_code = "child_interrupted",
        },
        .lost => .{
            .ok = false,
            .result = result orelse lost_result,
            .error_code = "child_lost",
        },
    };
}

/// A crash lost the work before the child started it (D33).
const lost_result = "fx stopped before this message reached the subagent, so it never ran. Send it again if it is still needed.";

fn managedAdmissionReady(
    alloc: Allocator,
    child_id: []const u8,
) !Runtime.ManagedAdmission {
    return .{ .ready = .{ .child_id = try alloc.dupe(u8, child_id) } };
}

fn managedAdmissionRejected(
    alloc: Allocator,
    child_id: ?[]const u8,
    code: []const u8,
) !Runtime.ManagedAdmission {
    return .{ .rejected = .{
        .child_id = if (child_id) |value| try alloc.dupe(u8, value) else null,
        .code = code,
    } };
}

fn makeManagedWork(
    alloc: Allocator,
    operation_id: []const u8,
    request_fingerprint: [32]u8,
    request: model_contract.Request,
    options: ExecuteOptions,
) !child_state.ActiveWork {
    const message = switch (request) {
        .run => |value| value.task,
        .message => |value| value.message,
    };
    const id = try alloc.dupe(u8, operation_id);
    errdefer alloc.free(id);
    const owned_message = try alloc.dupe(u8, message);
    errdefer alloc.free(owned_message);
    const root_context = if (options.root_user_intent_context.len == 0)
        &.{}
    else
        try alloc.dupe(u8, options.root_user_intent_context);
    errdefer if (root_context.len > 0) alloc.free(root_context);
    return .{
        .id = id,
        .request_fingerprint = request_fingerprint,
        .message = owned_message,
        .root_user_intent_context = @constCast(root_context),
        .root_user_messages = try cloneStrings(alloc, options.root_user_messages),
        .root_user_evidence_complete = options.root_user_evidence_complete,
        .permission_mode = options.parent_permission_mode,
        .created_at_ms = options.timestamp_ms,
    };
}

fn assistantTextForWork(
    history: []const types.HistoryTurn,
    work_id: []const u8,
) ?[]const u8 {
    var index = history.len;
    while (index > 0) {
        index -= 1;
        const candidate = history[index];
        const candidate_work_id = session.historyTurnWorkId(candidate) orelse continue;
        if (!std.mem.eql(u8, candidate_work_id, work_id)) continue;
        return switch (candidate) {
            .assistant => |value| value.assistant,
            .interrupted => |value| value.assistant orelse "",
            .compacted_summary => null,
        };
    }
    return null;
}

/// Builds the parent-facing guidance for a rejected model override.
fn modelOverrideFailureMessage(
    alloc: Allocator,
    comptime kind: enum { ambiguous, unknown },
    raw_model: []const u8,
    candidates: []const []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    switch (kind) {
        .ambiguous => {
            try writer.print("model override '{s}' matches multiple catalog models: ", .{raw_model});
            for (candidates, 0..) |candidate, index| {
                if (index > 0) try writer.writeAll(", ");
                try writer.writeAll(candidate);
            }
            try writer.writeAll(". Retry with an exact catalog model ID.");
        },
        .unknown => {
            try writer.print("unknown model override '{s}'", .{raw_model});
            if (candidates.len > 0) {
                try writer.writeAll(". Closest catalog matches: ");
                for (candidates, 0..) |candidate, index| {
                    if (index > 0) try writer.writeAll(", ");
                    try writer.writeAll(candidate);
                }
                try writer.writeByte('.');
            } else {
                try writer.writeAll("; no catalog model names match it.");
            }
            try writer.writeAll(" Use an exact catalog model ID, or omit model to inherit the parent's model.");
        },
    }
    return out.toOwnedSlice();
}

/// Resolves the defaults used to seed a new child session. When the override
/// passed catalog resolution, `resolved_model` is the canonical catalog ID and
/// wins over the raw override text. The returned value borrows the override or
/// resolved model; the request, the resolved model, and the original defaults
/// must outlive the result.
fn effectiveDefaults(
    defaults: Defaults,
    override: model_contract.Override,
    resolved_model: ?[]const u8,
) Defaults {
    var resolved = defaults;
    if (override.model) |model| resolved.model = resolved_model orelse model;
    if (override.effort) |effort| resolved.effort = effort;
    return resolved;
}

fn freshChildState(
    alloc: Allocator,
    child_id: []const u8,
    workspace_root: []const u8,
    work_id: []const u8,
    defaults: Defaults,
) !session_codec.DurableSessionState {
    const now = io_mod.milliTimestamp();
    const id = try alloc.dupe(u8, child_id);
    errdefer alloc.free(id);
    const origin = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(workspace);
    const model = try alloc.dupe(u8, defaults.model);
    errdefer alloc.free(model);
    const last_subagent_work_id = try alloc.dupe(u8, work_id);
    errdefer alloc.free(last_subagent_work_id);
    return .{
        .id = id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = now,
        .updated_at_ms = now,
        .conversation_language = defaults.conversation_language,
        .preferences = .{
            .provider = defaults.provider,
            .model = model,
            .effort = defaults.effort,
            .fast_mode = defaults.fast_mode,
            .ultrafast_mode = defaults.ultrafast_mode,
        },
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .last_subagent_work_id = last_subagent_work_id,
        .subagent_child = true,
    };
}

fn captureAdmission(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: execution.CaptureRequest,
) execution.ServiceError!domain.AdmissionSnapshot {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    var snapshot = self.authority_resolver.resolve(alloc, request.child_id) catch
        return error.AdmissionFailed;
    defer snapshot.deinit(alloc);
    return domain.captureAdmission(alloc, .{
        .parent_id = request.parent_id,
        .source_id = request.source_id,
        .model = request.preferences.model,
        .provider = request.preferences.provider,
        .effort = request.preferences.effort,
        .ultrafast_mode = request.preferences.ultrafast_mode,
        .permission_mode = snapshot.permission_mode,
        .tool_names = snapshot.tools,
        .rules = snapshot.rules,
        .grants = snapshot.grants,
        .permission_state = snapshot.permission_state,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.AdmissionFailed,
    };
}

fn runChild(
    raw: ?*anyopaque,
    turn: *execution.TurnContext,
    message: domain.QueuedMessage,
    admission: domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    return self.child_runner.run_fn(
        self.child_runner.context,
        turn,
        message,
        admission,
        cancel,
    );
}

fn cloneStrings(
    alloc: Allocator,
    source: []const []const u8,
) ![][]u8 {
    const result = try alloc.alloc([]u8, source.len);
    var built: usize = 0;
    errdefer {
        for (result[0..built]) |value| alloc.free(value);
        alloc.free(result);
    }
    for (source) |value| {
        result[built] = try alloc.dupe(u8, value);
        built += 1;
    }
    return result;
}

pub const ModePolicy = union(enum) {
    full,
    active: struct {
        registry: mode_registry.Registry,
        id: []const u8,
    },

    fn allows(
        self: ModePolicy,
        tool_set: tool_set_contract.ToolSet,
        tool_name: []const u8,
    ) bool {
        return switch (self) {
            .full => true,
            .active => |active| active.registry.toolAllowed(
                tool_set,
                active.id,
                tool_name,
            ),
        };
    }
};

pub const CapabilityPolicy = struct {
    tool_set: tool_set_contract.ToolSet,
    mode: ModePolicy,
};

pub fn captureHostAuthority(
    alloc: Allocator,
    policy: CapabilityPolicy,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_state: session_permission_state.State,
) !authority.HostAuthority {
    var tool_names: std.ArrayList([]const u8) = .empty;
    defer tool_names.deinit(alloc);
    for (policy.tool_set.registry.tools) |registered_tool| {
        if (!policy.mode.allows(policy.tool_set, registered_tool.name)) continue;
        if (permissions.rulesDenyAllTargetsForTool(rules, registered_tool.name)) continue;
        try tool_names.append(alloc, registered_tool.name);
    }
    return authority.HostAuthority.captureWithPermissionState(
        alloc,
        tool_names.items,
        rules,
        grants,
        permission_state,
    );
}

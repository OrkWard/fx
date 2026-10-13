const std = @import("std");
const permission_auto_classifier = @import("../../permissions/auto_classifier.zig");
const command_admission = @import("../../permissions/command_admission.zig");
const permissions = @import("../../permissions/permissions.zig");
const shell_snapshot = @import("../../terminal/shell_snapshot.zig");
const types = @import("../../shared/types.zig");
const pathing = @import("../../workspace/pathing.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const file_mutation_contract = @import("../../tooling/file_mutation_contract.zig");
const tooling_tool_admission = @import("../../tooling/tool_admission.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");

const runtime_deps = @import("deps.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const ToolPermissionDecision = types.ToolPermissionDecision;
const TraceContext = debug_trace.TraceContext;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

const TerminalValidationDigest = [std.crypto.hash.sha2.Sha256.digest_length]u8;
const PermissionActionId = [std.crypto.hash.sha2.Sha256.digest_length]u8;
const max_turn_review_holds: usize = 64;
const max_turn_unavailable_attempts: usize = 64;
const max_consecutive_malformed_argument_batches: usize = 3;

const CachedReviewHold = struct {
    exact_id: PermissionActionId,
    detail: union(enum) {
        caution: struct {
            risk: permission_auto_classifier.Risk,
            rationale: []u8,
        },
        evidence_incomplete,
    },
};

pub const TurnReviewCache = struct {
    holds: std.ArrayList(CachedReviewHold) = .empty,
    /// Exact actions that already spent one unavailable reviewer attempt this
    /// turn. This is an I/O budget, not a cached security decision.
    unavailable_attempts: std.ArrayList(PermissionActionId) = .empty,
    unavailable_budget_exhausted: bool = false,

    pub fn deinit(self: *TurnReviewCache, alloc: Allocator) void {
        for (self.holds.items) |entry| switch (entry.detail) {
            .caution => |caution| alloc.free(caution.rationale),
            .evidence_incomplete => {},
        };
        self.holds.deinit(alloc);
        self.unavailable_attempts.deinit(alloc);
        self.* = .{};
    }

    pub fn remember(
        self: *TurnReviewCache,
        alloc: Allocator,
        call: ToolCall,
        outcome: command_admission.PermissionOutcome,
    ) Allocator.Error!void {
        const denial_reason = outcome.denial_reason orelse return;
        switch (denial_reason) {
            .review_caution, .review_evidence_incomplete => {},
            .review_unavailable => {
                if (outcome.auto_review_failure == null) return;
                if (self.unavailable_budget_exhausted) return;
                const exact_id = permissionActionId(call);
                for (self.unavailable_attempts.items) |entry| {
                    if (std.mem.eql(u8, &entry, &exact_id)) return;
                }
                if (self.unavailable_attempts.items.len == max_turn_unavailable_attempts) return;
                try self.unavailable_attempts.append(alloc, exact_id);
                self.unavailable_budget_exhausted =
                    self.unavailable_attempts.items.len == max_turn_unavailable_attempts;
                return;
            },
            .user_denied, .auto_denied, .policy_denied, .permission_required => return,
        }
        const exact_id = permissionActionId(call);
        for (self.holds.items) |entry| {
            if (std.mem.eql(u8, &entry.exact_id, &exact_id)) return;
        }
        if (self.holds.items.len == max_turn_review_holds) return;

        switch (denial_reason) {
            .review_caution => {
                const review = outcome.auto_review_result orelse return;
                if (review.decision != .caution) return;
                const rationale = try alloc.dupe(u8, review.rationale);
                errdefer alloc.free(rationale);
                try self.holds.append(alloc, .{
                    .exact_id = exact_id,
                    .detail = .{ .caution = .{
                        .risk = review.risk,
                        .rationale = rationale,
                    } },
                });
            },
            .review_evidence_incomplete => try self.holds.append(alloc, .{
                .exact_id = exact_id,
                .detail = .evidence_incomplete,
            }),
            .user_denied, .auto_denied, .review_unavailable, .policy_denied, .permission_required => unreachable,
        }
    }

    pub fn reviewAttemptAvailable(self: *const TurnReviewCache, call: ToolCall) bool {
        if (self.unavailable_budget_exhausted) return false;
        const exact_id = permissionActionId(call);
        for (self.unavailable_attempts.items) |entry| {
            if (std.mem.eql(u8, &entry, &exact_id)) return false;
        }
        return true;
    }

    pub fn cached(
        self: *const TurnReviewCache,
        call: ToolCall,
    ) ?command_admission.PermissionOutcome {
        const exact_id = permissionActionId(call);
        for (self.holds.items) |entry| {
            if (!std.mem.eql(u8, &entry.exact_id, &exact_id)) continue;
            return switch (entry.detail) {
                .caution => |caution| .{
                    .decision = .deny,
                    .denial_reason = .review_caution,
                    .auto_review_result = .{
                        .risk = caution.risk,
                        .decision = .caution,
                        .rationale = caution.rationale,
                    },
                },
                .evidence_incomplete => .{
                    .decision = .deny,
                    .denial_reason = .review_evidence_incomplete,
                },
            };
        }
        return null;
    }
};

fn permissionActionId(call: ToolCall) PermissionActionId {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.permission-action.v1\x00");
    hash.update(call.name);
    hash.update("\x00");
    hash.update(call.arguments_json);
    return hash.finalResult();
}

const TerminalValidationDigestDecision = struct {
    append_current: bool,
    repeated: bool,
};

fn containsTerminalValidationDigest(
    digests: []const TerminalValidationDigest,
    wanted: TerminalValidationDigest,
) bool {
    for (digests) |digest| {
        if (std.mem.eql(u8, digest[0..], wanted[0..])) return true;
    }
    return false;
}

fn terminalValidationDigestDecision(
    previous: []const TerminalValidationDigest,
    current: []const TerminalValidationDigest,
    digest: TerminalValidationDigest,
) TerminalValidationDigestDecision {
    return .{
        .append_current = !containsTerminalValidationDigest(current, digest),
        .repeated = containsTerminalValidationDigest(previous, digest),
    };
}

pub const TerminalValidationRetryState = struct {
    previous: std.ArrayList(TerminalValidationDigest) = .empty,
    current: std.ArrayList(TerminalValidationDigest) = .empty,
    stop_after_batch: bool = false,

    pub fn deinit(self: *TerminalValidationRetryState, alloc: Allocator) void {
        self.previous.deinit(alloc);
        self.current.deinit(alloc);
        self.* = .{};
    }

    pub fn beginBatch(self: *TerminalValidationRetryState) void {
        self.current.clearRetainingCapacity();
        self.stop_after_batch = false;
    }

    pub fn observe(
        self: *TerminalValidationRetryState,
        alloc: Allocator,
        call: ToolCall,
        model_output: []const u8,
    ) Allocator.Error!void {
        if (!std.mem.eql(u8, call.name, "shell")) return;
        if (try tool_result_errors.inspectTerminalActionFieldCorrection(
            alloc,
            model_output,
        ) == null) return;

        var digest: TerminalValidationDigest = undefined;
        std.crypto.hash.sha2.Sha256.hash(model_output, &digest, .{});
        const decision = terminalValidationDigestDecision(
            self.previous.items,
            self.current.items,
            digest,
        );
        if (decision.append_current) try self.current.append(alloc, digest);
        self.stop_after_batch = self.stop_after_batch or decision.repeated;
    }

    pub fn finishBatch(self: *TerminalValidationRetryState) bool {
        if (self.stop_after_batch) return true;
        const previous = self.previous;
        self.previous = self.current;
        self.current = previous;
        self.current.clearRetainingCapacity();
        return false;
    }
};

pub const ShellExecutionFailureRetryState = struct {
    previous: std.ArrayList(TerminalValidationDigest) = .empty,
    current: std.ArrayList(TerminalValidationDigest) = .empty,
    stop_after_batch: bool = false,

    pub fn deinit(self: *ShellExecutionFailureRetryState, alloc: Allocator) void {
        self.previous.deinit(alloc);
        self.current.deinit(alloc);
        self.* = .{};
    }

    pub fn beginBatch(self: *ShellExecutionFailureRetryState) void {
        self.current.clearRetainingCapacity();
        self.stop_after_batch = false;
    }

    pub fn observe(
        self: *ShellExecutionFailureRetryState,
        alloc: Allocator,
        call: ToolCall,
        execution: ToolExecutionResult,
    ) Allocator.Error!void {
        if (!std.mem.eql(u8, call.name, "shell") or execution.status != .failure) {
            return;
        }
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("fx.shell-execution-failure.v1\x00");
        hash.update(call.arguments_json);
        const digest = hash.finalResult();
        const decision = terminalValidationDigestDecision(
            self.previous.items,
            self.current.items,
            digest,
        );
        if (decision.append_current) try self.current.append(alloc, digest);
        self.stop_after_batch = self.stop_after_batch or decision.repeated;
    }

    pub fn finishBatch(self: *ShellExecutionFailureRetryState) bool {
        if (self.stop_after_batch) return true;
        const previous = self.previous;
        self.previous = self.current;
        self.current = previous;
        self.current.clearRetainingCapacity();
        return false;
    }
};

/// Turn-scoped tracker that detects the same tool call (name + arguments)
/// failing repeatedly. The batch-scoped retry states above cannot see
/// degenerate loops that alternate single-call steps (a read between two
/// identical failing edits never produces an all-failed batch), so repeat
/// detection for content failures lives at turn scope.
pub const IdenticalFailureEscalationState = struct {
    const FailureCount = struct {
        digest: [32]u8,
        count: u32,
    };

    counts: std.ArrayList(FailureCount) = .empty,

    pub fn deinit(self: *IdenticalFailureEscalationState, alloc: Allocator) void {
        self.counts.deinit(alloc);
        self.* = .{};
    }

    fn failureDigest(call: ToolCall) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("fx.identical-failure.v1\x00");
        hash.update(call.name);
        hash.update("\x00");
        hash.update(call.arguments_json);
        return hash.finalResult();
    }

    /// Records a failed execution and returns how many times this exact call
    /// has failed this turn, including the current one. Successes and
    /// provider-supplied results return 0: they never escalate and never
    /// disturb an existing count.
    pub fn observe(
        self: *IdenticalFailureEscalationState,
        alloc: Allocator,
        call: ToolCall,
        failed: bool,
    ) Allocator.Error!u32 {
        if (call.provider_result != null) return 0;
        if (!failed) return 0;
        const digest = failureDigest(call);
        for (self.counts.items) |*item| {
            if (std.mem.eql(u8, item.digest[0..], digest[0..])) {
                item.count += 1;
                return item.count;
            }
        }
        try self.counts.append(alloc, .{ .digest = digest, .count = 1 });
        return 1;
    }
};

/// Appends escalation guidance to a repeated identical failure's
/// model-visible output. Guidance only: the tool already ran, and the model
/// keeps authority for retrying with changed arguments.
pub fn appendIdenticalFailureEscalation(
    alloc: Allocator,
    model_output: []const u8,
    failure_count: u32,
) Allocator.Error![]const u8 {
    return alloc.print(
        "{s}\n\nThis exact call has already failed {d} times this turn with the same arguments. Do not retry it unchanged.",
        .{ model_output, failure_count },
    );
}

pub const MalformedArgumentsRetryState = struct {
    consecutive_malformed_batches: usize = 0,
    current_call_count: usize = 0,
    current_malformed_count: usize = 0,

    pub fn beginBatch(self: *MalformedArgumentsRetryState) void {
        self.current_call_count = 0;
        self.current_malformed_count = 0;
    }

    pub fn observe(self: *MalformedArgumentsRetryState, call: ToolCall) void {
        self.current_call_count += 1;
        if (call.argument_integrity == .valid) return;
        self.current_malformed_count += 1;
    }

    pub fn finishBatch(self: *MalformedArgumentsRetryState) bool {
        const all_malformed = self.current_call_count > 0 and
            self.current_call_count == self.current_malformed_count;
        if (!all_malformed) {
            self.consecutive_malformed_batches = 0;
            return false;
        }
        if (self.consecutive_malformed_batches < max_consecutive_malformed_argument_batches) {
            self.consecutive_malformed_batches += 1;
        }
        return self.consecutive_malformed_batches == max_consecutive_malformed_argument_batches;
    }
};

/// Human denials retained only for the current agent turn. Entries use the
/// canonical external file action rather than the provider's tool-call ID.
pub const TurnFileMutationDenials = struct {
    identities: std.ArrayList(
        tooling_tool_admission.FileMutationActionIdentity,
    ) = .empty,

    pub noinline fn deinit(self: *TurnFileMutationDenials, alloc: Allocator) void {
        self.identities.deinit(alloc);
        self.* = .{};
    }

    pub fn rememberHumanDenial(
        self: *TurnFileMutationDenials,
        alloc: Allocator,
        identity: tooling_tool_admission.FileMutationActionIdentity,
        outcome: command_admission.PermissionOutcome,
    ) Allocator.Error!void {
        const reason = outcome.denial_reason orelse
            outcome.decision.denialReason() orelse return;
        if (outcome.decision != .deny or reason != .user_denied) return;
        if (self.preservedOutcome(identity) != null) return;
        try self.identities.append(alloc, identity);
    }

    pub fn preservedOutcome(
        self: TurnFileMutationDenials,
        identity: tooling_tool_admission.FileMutationActionIdentity,
    ) ?command_admission.PermissionOutcome {
        for (self.identities.items) |denied| {
            if (denied.eql(identity)) {
                return .{
                    .decision = .deny,
                    .denial_reason = .user_denied,
                };
            }
        }
        return null;
    }
};

pub fn deferVisibleLifecycleUntilAfterPermission(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "web_fetch") or
        file_mutation_contract.isToolName(tool_name);
}

pub fn deferCapturedCommandLifecycleForAutoPermissionNotice(
    registry: tool_dispatch.Registry,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    interactive_presentation: bool,
) !bool {
    return interactive_presentation and
        permission_mode == .auto and
        try tooling_tool_admission.callUsesCommandAuthority(
            registry,
            arena,
            call,
        );
}

pub fn requestToolPermissionTraced(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    review_turn: permission_auto_classifier.ReviewTurnContext,
    mode: PermissionMode,
    local_grants: []const PermissionGrant,
    live_authority: ?runtime_tool_contracts.LiveToolAuthority,
    revalidation: ?runtime_tool_contracts.LivePermissionRevalidation,
    workspace_root: []const u8,
    ctx: TraceContext,
) !command_admission.PermissionOutcome {
    const target_class = classifyPermissionTarget(hooks, arena, call, workspace_root);
    tracePermissionRequest(call, mode, local_grants.len, target_class, ctx);
    const outcome = hooks.request_tool_permission(hooks.ctx, arena, call, review_turn, mode, local_grants, live_authority, revalidation) catch |err| {
        return permissionErrorOutcome(arena, call, mode, err, target_class, ctx);
    };
    tracePermissionOutcome(call, mode, local_grants.len, target_class, ctx, outcome);
    return outcome;
}

pub fn requestPreparedFileMutationPermissionTraced(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    prepared: *tooling_tool_admission.PreparedFileMutationCall,
    review_turn: permission_auto_classifier.ReviewTurnContext,
    mode: PermissionMode,
    local_grants: []const PermissionGrant,
    live_authority: ?runtime_tool_contracts.LiveToolAuthority,
    workspace_root: []const u8,
    ctx: TraceContext,
) !command_admission.PermissionOutcome {
    const target_class = classifyPermissionTarget(hooks, arena, call, workspace_root);
    tracePermissionRequest(call, mode, local_grants.len, target_class, ctx);
    const request = hooks.request_prepared_file_mutation_permission orelse {
        return permissionErrorOutcome(
            arena,
            call,
            mode,
            error.PreparedFileMutationPermissionUnavailable,
            target_class,
            ctx,
        );
    };
    const outcome = request(hooks.ctx, arena, call, prepared, review_turn, mode, local_grants, live_authority) catch |err| {
        return permissionErrorOutcome(arena, call, mode, err, target_class, ctx);
    };
    tracePermissionOutcome(call, mode, local_grants.len, target_class, ctx, outcome);
    return outcome;
}

fn tracePermissionRequest(
    call: ToolCall,
    mode: PermissionMode,
    local_grant_count: usize,
    target_class: []const u8,
    ctx: TraceContext,
) void {
    debug_trace.eventf("permission", "before_permission_wait", ctx, "call_id={s} tool_name={s} permission_mode={s} local_grants={d} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), local_grant_count, target_class });
    debug_trace.eventf("permission", "permission_requested", ctx, "call_id={s} tool_name={s} permission_mode={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), target_class });
}

fn permissionErrorOutcome(
    arena: Allocator,
    call: ToolCall,
    mode: PermissionMode,
    err: anyerror,
    target_class: []const u8,
    ctx: TraceContext,
) anyerror!command_admission.PermissionOutcome {
    if (try tooling_tool_admission.permissionTargetResolutionFailureMessage(arena, call, err)) |failure| {
        debug_trace.eventf("permission", "permission_target_resolution_error", ctx, "call_id={s} tool_name={s} permission_mode={s} err={s} outside_workspace={s} approval_source=tool_layer", .{ call.id, call.name, @tagName(mode), @errorName(err), target_class });
        return .{ .tool_failure = failure };
    }
    debug_trace.eventf("permission", "permission_error", ctx, "call_id={s} tool_name={s} permission_mode={s} err={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), @errorName(err), target_class });
    return err;
}

fn tracePermissionOutcome(
    call: ToolCall,
    mode: PermissionMode,
    local_grant_count: usize,
    target_class: []const u8,
    ctx: TraceContext,
    outcome: command_admission.PermissionOutcome,
) void {
    const source = permissionOutcomeSource(outcome, mode, local_grant_count);
    if (outcome.tool_failure) |failure| {
        debug_trace.eventf("permission", "after_permission_decision", ctx, "call_id={s} tool_name={s} permission_mode={s} decision=tool_failure approval_source={s} outside_workspace={s} model_output_bytes={d}", .{ call.id, call.name, @tagName(mode), source, target_class, failure.len });
        debug_trace.eventf("permission", "permission_decision", ctx, "call_id={s} tool_name={s} permission_mode={s} decision=tool_failure approval_source={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), source, target_class });
    } else {
        debug_trace.eventf("permission", "after_permission_decision", ctx, "call_id={s} tool_name={s} permission_mode={s} decision={s} approval_source={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), permissionDecisionName(outcome.decision), source, target_class });
        debug_trace.eventf("permission", "permission_decision", ctx, "call_id={s} tool_name={s} permission_mode={s} decision={s} approval_source={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), permissionDecisionName(outcome.decision), source, target_class });
    }
}

fn classifyPermissionTarget(hooks: *const AgentRuntimeDeps, arena: Allocator, call: ToolCall, workspace_root: []const u8) []const u8 {
    if (file_mutation_contract.isToolName(call.name)) return "unknown";
    const target = hooks.permission_target_for_call(hooks.ctx, arena, call) catch |err| {
        return if (err == error.PathOutsideWorkspace) "true" else "unknown";
    };
    const path_part = if (std.mem.find(u8, target, "::")) |sep| target[0..sep] else target;
    if (!std.Io.Dir.path.isAbsolute(path_part)) return "not_path";
    return if (pathing.pathInside(workspace_root, path_part)) "false" else "true";
}

fn permissionOutcomeSource(
    outcome: command_admission.PermissionOutcome,
    mode: PermissionMode,
    local_grant_count: usize,
) []const u8 {
    if (outcome.tool_failure != null) return "tool_failure";
    if (outcome.decision.isDenied()) return "denied";
    if (outcome.execution_authority) |authority| {
        switch (authority) {
            .ordinary => {},
            .run_command => |command_authority| switch (command_authority) {
                .direct_only => return "direct_only",
                .shell_allowed => |shell| return @tagName(shell.source),
            },
            .file_mutation => return "file_mutation",
            .vision_paths => return "vision_paths",
        }
    }
    if (local_grant_count > 0) return "session_grant_or_rule";
    return switch (mode) {
        .auto => "auto_or_rule",
        .ask => "interactive_or_rule",
        .yolo => "yolo",
    };
}

pub noinline fn permissionDeniedStatusLabel(reason: types.ToolPermissionDenialReason) []const u8 {
    return switch (reason) {
        .user_denied => "Denied",
        .auto_denied => "Denied by auto agent",
        .review_caution => "Safety caution",
        .review_evidence_incomplete => "Review evidence incomplete",
        .review_unavailable => "Review unavailable",
        .policy_denied => "Denied",
        .permission_required => "Permission required",
    };
}

fn permissionDecisionName(decision: ToolPermissionDecision) []const u8 {
    return @tagName(decision);
}

fn appendLocalGrant(arena: Allocator, grants: *std.ArrayList(PermissionGrant), grant: PermissionGrant) !void {
    if (permissions.sessionGrantAllowed(grants.items, grant.tool_name, grant.target_path)) return;
    try grants.append(arena, grant);
}

pub fn applyInitialSessionGrants(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    local_grants: *std.ArrayList(PermissionGrant),
    workspace_root: []const u8,
    call: ToolCall,
    target_path: []const u8,
) !void {
    const command_call = try tooling_tool_admission.callUsesCommandAuthority(
        hooks.tool_registry,
        arena,
        call,
    );
    const permission_name = if (command_call) "run_command" else call.name;
    const target_kind = if (command_call)
        tool_dispatch.PermissionTargetKind.command_cwd
    else if (hooks.tool_registry.lookup(call.name)) |tool|
        tool.permission_target_kind
    else
        .none;
    const grants = try permissions.suggestedSessionGrants(
        arena,
        workspace_root,
        permission_name,
        target_path,
        target_kind,
    );
    for (grants) |grant| {
        if (std.mem.eql(u8, permissions.permissionNameForTool(grant.tool_name), "bash")) {
            shell_snapshot.processOwner().recordShellGrant(grant.target_path);
        }
        try appendLocalGrant(arena, local_grants, grant);
        try propagateGrant(hooks, grant);
    }
}

pub fn applyFrozenFileMutationSessionGrants(
    arena: Allocator,
    hooks: *const AgentRuntimeDeps,
    local_grants: *std.ArrayList(PermissionGrant),
    frozen_grants: []const PermissionGrant,
) !void {
    for (frozen_grants) |grant| {
        const existed = permissions.sessionGrantAllowed(
            local_grants.items,
            grant.tool_name,
            grant.target_path,
        );
        try appendLocalGrant(arena, local_grants, grant);
        if (!existed) try propagateGrant(hooks, grant);
    }
}

pub fn appendFrozenFileMutationGrants(
    arena: Allocator,
    grants: *std.ArrayList(PermissionGrant),
    frozen_grants: []const PermissionGrant,
) !void {
    for (frozen_grants) |grant| {
        try appendLocalGrant(arena, grants, grant);
    }
}

fn propagateGrant(hooks: *const AgentRuntimeDeps, grant: PermissionGrant) !void {
    try hooks.propagate_grant(hooks.ctx, grant.tool_name, grant.target_path);
    try hooks.push_event(hooks.ctx, .{ .session_grant = .{
        .tool_name = try std.heap.c_allocator.dupe(u8, grant.tool_name),
        .target_path = try std.heap.c_allocator.dupe(u8, grant.target_path),
    } });
}

pub fn registeredToolValidationFailure(hooks: *const AgentRuntimeDeps, arena: Allocator, call: ToolCall) !?ToolExecutionResult {
    return switch (try toolCallValidation(hooks, arena, call)) {
        .not_registered => null,
        .valid => null,
        .failure => |reason| .{ .model_output = reason, .status = .failure },
    };
}

pub fn toolCallValidation(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
) !runtime_tool_contracts.ToolCallValidationResult {
    if (call.provider_result != null) return .{ .valid = .{} };
    const validate = hooks.validate_tool_call orelse return .{ .valid = .{} };
    return validate(hooks.ctx, arena, call);
}

pub fn toolAvailabilityFailure(hooks: *const AgentRuntimeDeps, arena: Allocator, call: ToolCall) !?ToolExecutionResult {
    if (call.provider_result != null) return null;
    const check = hooks.check_tool_availability orelse return null;
    const reason = try check(hooks.ctx, arena, call) orelse return null;
    return .{ .model_output = reason, .status = .failure };
}

pub noinline fn recordRejectedToolCall(
    deps: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const record = deps.record_tool_call_rejected orelse return;
    try record(deps.ctx, arena, call, model_output, command_result_json);
}

/// Records a call that failed the tool's own preflight or content checks
/// (for example a file-mutation prepare that found no matching old_string).
/// These are tool failures in diagnostics, not permission rejections.
pub noinline fn recordFailedToolCall(
    deps: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const record = deps.record_tool_call_failed orelse return;
    try record(deps.ctx, arena, call, model_output, command_result_json);
}

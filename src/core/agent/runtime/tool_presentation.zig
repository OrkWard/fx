const std = @import("std");
const command_admission = @import("../../permissions/command_admission.zig");
const managed_execution = @import("../../execution/managed_execution.zig");
const types = @import("../../shared/types.zig");
const shared_theme = @import("../../shared/theme.zig");
const text_utils = @import("../../shared/text_utils.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_args = @import("../../tooling/tool_args.zig");
const tooling_presentation = @import("../../tooling/tool_presentation.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const diff = @import("../../output/diff.zig");
const file_mutation_contract = @import("../../tooling/file_mutation_contract.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");

const runtime_deps = @import("deps.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const DiffEntryPayload = runtime_tool_contracts.DiffEntryPayload;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

pub fn isProviderSearchAlias(tool_name: []const u8) bool {
    return tooling_presentation.isProviderSearchAlias(tool_name);
}

pub fn streamStartMayHaveExecutedAtProvider(
    registry: tool_dispatch.Registry,
    tool_name: []const u8,
) bool {
    if (isProviderSearchAlias(tool_name)) return true;
    const spec = registry.lookup(tool_name) orelse return false;
    return spec.provider_executed;
}

fn fallbackToolDisplay(
    registry: tool_dispatch.Registry,
    tool_name: []const u8,
) []const u8 {
    // Provider-executed search backends are never registered locally; their
    // stream names (exa_search, ...) are internal identifiers, not display copy.
    if (tooling_presentation.isProviderSearchAlias(tool_name)) return "web search";
    const lookup_name = if (std.mem.eql(u8, tool_name, "run_command"))
        "shell"
    else
        tool_name;
    return if (registry.lookup(lookup_name) != null) "tool call" else tool_name;
}

pub const ProvisionalToolStatuses = struct {
    const TrackedStatus = struct {
        id: []u8,
        tool_name: []u8,
        label_value: ?[]u8,

        fn deinit(self: *TrackedStatus, alloc: Allocator) void {
            alloc.free(self.id);
            alloc.free(self.tool_name);
            if (self.label_value) |value| alloc.free(value);
            self.* = undefined;
        }
    };

    tracked: std.ArrayList(TrackedStatus) = .empty,
    terminal_ids: std.ArrayList([]u8) = .empty,
    presentation_group_id: ?types.ToolPresentationGroupId = null,

    pub const StartPreflight = union(enum) {
        ineligible,
        eligible: struct {
            action_label: []const u8,
            activity_kind: types.ToolActivityKind,
        },
    };

    pub fn deinit(self: *ProvisionalToolStatuses, alloc: Allocator) void {
        for (self.tracked.items) |*status| status.deinit(alloc);
        self.tracked.deinit(alloc);
        for (self.terminal_ids.items) |id| alloc.free(id);
        self.terminal_ids.deinit(alloc);
    }

    pub fn preflight(registry: tool_dispatch.Registry, tool_name: []const u8) ?StartPreflight {
        if (tooling_presentation.isProviderSearchAlias(tool_name)) {
            return .{ .eligible = .{
                .action_label = "Searching",
                .activity_kind = .read,
            } };
        }
        const lookup_name = if (std.mem.eql(u8, tool_name, "run_command"))
            "shell"
        else
            tool_name;
        const spec = registry.lookup(lookup_name) orelse return null;
        if (spec.executor_kind == .terminal) return .ineligible;
        return switch (spec.activity_kind) {
            .ask, .write, .edit => .ineligible,
            else => .{ .eligible = .{
                .action_label = spec.action_label,
                .activity_kind = spec.activity_kind,
            } },
        };
    }

    pub fn publish(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        turn_id: u64,
        tool_id: []const u8,
        tool_name: []const u8,
        activity_kind: types.ToolActivityKind,
        action_label: []const u8,
        label_value: ?[]const u8,
        arguments_json: ?[]const u8,
    ) !void {
        if (tool_id.len == 0) {
            debug_trace.logf(
                "ui_activity",
                "suppressed provisional lifecycle with missing identity turn_id={d}",
                .{turn_id},
            );
            return;
        }

        var buf: [512]u8 = undefined;
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const is_skill = std.mem.eql(u8, tool_name, "skill");
        var observed_label = if (is_skill) null else label_value;
        var observed_kind = activity_kind;
        const resource_label: ?[]const u8 = if (is_skill) resource: {
            const json = arguments_json orelse break :resource null;
            const args = tool_args.parseToolArgsObject(scratch.allocator(), json) catch break :resource null;
            const spec = hooks.tool_registry.lookup(tool_name) orelse break :resource null;
            const presentation = tool_dispatch.presentationForArgs(spec.*, args);
            if (presentation.label_arg_kind != .resource) break :resource null;
            const value = tool_dispatch.presentationLabelValue(presentation, args) orelse break :resource null;
            const encoded = text_utils.encodeTerminalSafe(scratch.allocator(), value, buf.len) catch break :resource null;
            if (encoded.truncated) break :resource null;
            const formatted = formatProvisionalProgressLabel(&buf, presentation.action_label, encoded.bytes) catch break :resource null;
            observed_label = value;
            observed_kind = presentation.activity_kind;
            break :resource formatted;
        } else null;
        const label = resource_label orelse try formatProvisionalProgressLabel(&buf, action_label, observed_label);
        const recorded = try self.recordTracked(
            alloc,
            tool_id,
            tool_name,
            observed_label,
        );
        hooks.push_tool_lifecycle(hooks.ctx, .{
            .provisional = .{
                .id = .{ .turn_id = turn_id, .call_id = tool_id },
                .presentation_group_id = self.presentation_group_id,
                .tool_name = tool_name,
                .activity_kind = observed_kind,
            },
        }) catch |err| {
            if (recorded) self.forget(alloc, tool_id);
            return err;
        };
        hooks.push_tool_lifecycle(hooks.ctx, .{
            .progress = .{
                .id = .{ .turn_id = turn_id, .call_id = tool_id },
                .text = label,
            },
        }) catch {};
    }

    pub fn finishMalformedToolArguments(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
    ) !void {
        const call_id = self.visibleId(call) orelse return;
        const summary = try arena.print(
            "{s} failed: {s}",
            .{ fallbackToolDisplay(hooks.tool_registry, call.name), if (call.argument_integrity == .non_object_json) "non-object arguments" else "invalid JSON arguments" },
        );
        try hooks.push_tool_lifecycle(hooks.ctx, .{
            .terminal = .{
                .id = .{ .turn_id = turn_id, .call_id = call_id },
                .outcome = .{ .kind = .failed, .summary = summary },
            },
        });
    }

    pub fn finishMalformedProviderToolArguments(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        calls: []const ToolCall,
    ) !void {
        for (calls) |call| {
            if (call.provenance != .provider_executed or call.argument_integrity != .malformed_json) continue;
            try self.finishMalformedToolArguments(hooks, arena, turn_id, call);
        }
    }

    pub fn finishRejectedCompletions(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        calls: []const ToolCall,
    ) !void {
        for (calls) |call| {
            if (!self.has(call.id)) continue;
            try finishDeniedToolStatus(
                hooks,
                arena,
                turn_id,
                call,
                true,
                null,
                "Failed",
            );
        }
    }

    /// Settles one admitted call against its tracked final or provisional id.
    /// The tracked id is consumed only after terminal publication succeeds.
    pub fn settleAdmittedCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        label: []const u8,
    ) !bool {
        return self.finishDeniedCall(
            hooks,
            alloc,
            arena,
            turn_id,
            call,
            false,
            null,
            label,
        );
    }

    pub fn settleDeferredCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
    ) !bool {
        const recorded_terminal = try self.recordTerminal(alloc, call.id);
        if (!recorded_terminal) return false;
        errdefer self.forgetTerminal(alloc, call.id);
        const target = try self.ensureTerminalTarget(
            hooks,
            arena,
            turn_id,
            call,
            false,
            null,
        ) orelse {
            self.forgetTerminal(alloc, call.id);
            return false;
        };
        try finishDeferredToolStatus(
            hooks,
            arena,
            turn_id,
            target.call,
        );
        if (target.tracked_id) |tracked_id| self.forget(alloc, tracked_id);
        return true;
    }

    pub fn finishDeniedCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        authoritative_started: bool,
        display_target: ?[]const u8,
        label: []const u8,
    ) !bool {
        const recorded_terminal = try self.recordTerminal(alloc, call.id);
        if (!recorded_terminal) return false;
        errdefer self.forgetTerminal(alloc, call.id);
        const target = try self.ensureTerminalTarget(
            hooks,
            arena,
            turn_id,
            call,
            authoritative_started,
            display_target,
        ) orelse {
            self.forgetTerminal(alloc, call.id);
            return false;
        };
        try finishDeniedToolStatus(
            hooks,
            arena,
            turn_id,
            target.call,
            true,
            display_target,
            label,
        );
        if (target.tracked_id) |tracked_id| self.forget(alloc, tracked_id);
        return true;
    }

    pub fn finishExecutedCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        authoritative_started: bool,
        display_target: ?[]const u8,
        result: ToolExecutionResult,
        safe_result: []const u8,
        result_memory: types.ToolResultMemory,
        diff_entry: ?DiffEntryPayload,
    ) !bool {
        const recorded_terminal = try self.recordTerminal(alloc, call.id);
        if (!recorded_terminal) return false;
        errdefer self.forgetTerminal(alloc, call.id);
        const target = try self.ensureTerminalTarget(
            hooks,
            arena,
            turn_id,
            call,
            authoritative_started,
            display_target,
        ) orelse {
            self.forgetTerminal(alloc, call.id);
            return false;
        };
        try finishExecutedToolStatus(
            hooks,
            arena,
            turn_id,
            target.call,
            true,
            display_target,
            result,
            safe_result,
            result_memory,
            diff_entry,
        );
        if (target.tracked_id) |tracked_id| self.forget(alloc, tracked_id);
        return true;
    }

    pub fn finishCancelledCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        authoritative_started: bool,
        display_target: ?[]const u8,
        result: ToolExecutionResult,
    ) !bool {
        const recorded_terminal = try self.recordTerminal(alloc, call.id);
        if (!recorded_terminal) return false;
        errdefer self.forgetTerminal(alloc, call.id);
        const target = try self.ensureTerminalTarget(
            hooks,
            arena,
            turn_id,
            call,
            authoritative_started,
            display_target,
        ) orelse {
            self.forgetTerminal(alloc, call.id);
            return false;
        };
        try finishCancelledToolStatus(
            hooks,
            arena,
            turn_id,
            target.call,
            true,
            display_target,
            result,
        );
        if (target.tracked_id) |tracked_id| self.forget(alloc, tracked_id);
        return true;
    }

    pub fn finishTrackedCancelled(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
    ) !void {
        while (self.tracked.items.len > 0) {
            const status = &self.tracked.items[self.tracked.items.len - 1];
            if (self.hasTerminal(status.id)) {
                self.forget(alloc, status.id);
                continue;
            }
            const recorded_terminal = try self.recordTerminal(alloc, status.id);
            if (!recorded_terminal) {
                self.forget(alloc, status.id);
                continue;
            }
            errdefer self.forgetTerminal(alloc, status.id);
            const detail = status.label_value orelse
                fallbackToolDisplay(hooks.tool_registry, status.tool_name);
            const encoded = try text_utils.encodeTerminalSafe(
                arena,
                detail,
                diff.max_encoded_label_bytes,
            );
            const summary = try arena.print("Cancelled {s}", .{encoded.bytes});
            try hooks.push_tool_lifecycle(hooks.ctx, .{ .terminal = .{
                .id = .{ .turn_id = turn_id, .call_id = status.id },
                .outcome = .{ .kind = .cancelled, .summary = summary },
            } });
            self.forget(alloc, status.id);
        }
    }

    /// Settles provisional starts from an interrupted, proven-unexecuted
    /// stream unless the recovered completion retained their identity.
    pub fn finishUnmatchedRecoveryStarts(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        recovered_calls: []const ToolCall,
    ) !void {
        var index = self.tracked.items.len;
        while (index > 0) {
            index -= 1;
            const status = &self.tracked.items[index];
            if (trackedStatusMatchesCalls(status.*, recovered_calls)) continue;
            if (streamStartMayHaveExecutedAtProvider(
                hooks.tool_registry,
                status.tool_name,
            )) continue;
            if (self.hasTerminal(status.id)) {
                self.forget(alloc, status.id);
                continue;
            }
            const recorded_terminal = try self.recordTerminal(alloc, status.id);
            if (!recorded_terminal) {
                self.forget(alloc, status.id);
                continue;
            }
            errdefer self.forgetTerminal(alloc, status.id);
            const detail = status.label_value orelse
                fallbackToolDisplay(hooks.tool_registry, status.tool_name);
            const encoded = try text_utils.encodeTerminalSafe(
                arena,
                detail,
                diff.max_encoded_label_bytes,
            );
            const summary = try arena.print(
                "Connection interrupted before {s} ran",
                .{encoded.bytes},
            );
            try hooks.push_tool_lifecycle(hooks.ctx, .{ .terminal = .{
                .id = .{ .turn_id = turn_id, .call_id = status.id },
                .outcome = .{ .kind = .failed, .summary = summary },
            } });
            self.forget(alloc, status.id);
        }
    }

    pub fn visibleId(self: *const ProvisionalToolStatuses, call: ToolCall) ?[]const u8 {
        if (self.has(call.id)) return call.id;
        if (call.provisional_id) |provisional_id| {
            if (self.has(provisional_id)) return provisional_id;
        }
        return null;
    }

    fn record(self: *ProvisionalToolStatuses, alloc: Allocator, id: []const u8) !bool {
        return self.recordTracked(alloc, id, "", null);
    }

    fn recordTracked(
        self: *ProvisionalToolStatuses,
        alloc: Allocator,
        id: []const u8,
        tool_name: []const u8,
        label_value: ?[]const u8,
    ) !bool {
        if (id.len == 0) return false;
        if (self.findTracked(id)) |index| {
            const status = &self.tracked.items[index];
            if (label_value) |value| {
                const owned_value = try alloc.dupe(u8, value);
                if (status.label_value) |prior| alloc.free(prior);
                status.label_value = owned_value;
            }
            return false;
        }
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_tool_name = try alloc.dupe(u8, tool_name);
        errdefer alloc.free(owned_tool_name);
        const owned_label_value = if (label_value) |value| try alloc.dupe(u8, value) else null;
        errdefer if (owned_label_value) |value| alloc.free(value);
        try self.tracked.append(alloc, .{
            .id = owned_id,
            .tool_name = owned_tool_name,
            .label_value = owned_label_value,
        });
        return true;
    }

    fn has(self: *const ProvisionalToolStatuses, id: []const u8) bool {
        return self.findTracked(id) != null;
    }

    fn findTracked(self: *const ProvisionalToolStatuses, id: []const u8) ?usize {
        for (self.tracked.items, 0..) |status, i| {
            if (std.mem.eql(u8, status.id, id)) return i;
        }
        return null;
    }

    fn trackedStatusMatchesCalls(
        status: TrackedStatus,
        calls: []const ToolCall,
    ) bool {
        for (calls) |call| {
            if (std.mem.eql(u8, status.id, call.id)) return true;
            if (call.provisional_id) |provisional_id| {
                if (std.mem.eql(u8, status.id, provisional_id)) return true;
            }
        }
        return false;
    }

    fn recordTerminal(self: *ProvisionalToolStatuses, alloc: Allocator, id: []const u8) !bool {
        if (id.len == 0 or self.hasTerminal(id)) return false;
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        try self.terminal_ids.append(alloc, owned_id);
        return true;
    }

    fn hasTerminal(self: *const ProvisionalToolStatuses, id: []const u8) bool {
        for (self.terminal_ids.items) |existing| {
            if (std.mem.eql(u8, existing, id)) return true;
        }
        return false;
    }

    const TerminalTarget = struct {
        call: ToolCall,
        tracked_id: ?[]const u8,
    };

    fn terminalTarget(
        self: *const ProvisionalToolStatuses,
        call: ToolCall,
        authoritative_started: bool,
    ) ?TerminalTarget {
        const visible_id = self.visibleId(call);
        if (authoritative_started) {
            return .{ .call = call, .tracked_id = visible_id };
        }
        const provisional_id = visible_id orelse return null;
        var visible_call = call;
        visible_call.id = provisional_id;
        return .{ .call = visible_call, .tracked_id = provisional_id };
    }

    fn ensureTerminalTarget(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        authoritative_started: bool,
        display_target: ?[]const u8,
    ) !?TerminalTarget {
        if (self.terminalTarget(call, authoritative_started)) |target| return target;
        const started = try startToolVisibleLifecycle(
            hooks,
            arena,
            turn_id,
            self.presentation_group_id,
            call,
            display_target,
        );
        if (!started) return null;
        return .{ .call = call, .tracked_id = null };
    }

    fn forget(self: *ProvisionalToolStatuses, alloc: Allocator, id: []const u8) void {
        const index = self.findTracked(id) orelse return;
        self.tracked.items[index].deinit(alloc);
        _ = self.tracked.swapRemove(index);
    }

    fn forgetTerminal(self: *ProvisionalToolStatuses, alloc: Allocator, id: []const u8) void {
        for (self.terminal_ids.items, 0..) |existing, i| {
            if (!std.mem.eql(u8, existing, id)) continue;
            alloc.free(existing);
            _ = self.terminal_ids.swapRemove(i);
            return;
        }
    }
};

pub const ToolPresentationGroupObservation = struct {
    has_visible_tool_calls: bool,
    has_visible_text: bool,
    saw_tool_start: bool,
    saw_visible_text_after_tool_start: bool,
};

pub const ToolPresentationGroupTransition = struct {
    tool_group_id: ?types.ToolPresentationGroupId,
    active_group_id: ?types.ToolPresentationGroupId,
};

pub fn presentationGroupForStep(
    active_group_id: ?types.ToolPresentationGroupId,
    turn_id: u64,
    step_id: u64,
) types.ToolPresentationGroupId {
    if (active_group_id) |group_id| {
        if (group_id.turn_id == turn_id) return group_id;
    }
    return .{ .turn_id = turn_id, .anchor_step_id = step_id };
}

pub fn transitionPresentationGroup(
    active_group_id: ?types.ToolPresentationGroupId,
    tool_group_id: ?types.ToolPresentationGroupId,
    turn_id: u64,
    step_id: u64,
    observation: ToolPresentationGroupObservation,
) ToolPresentationGroupTransition {
    var resolved_tool_group_id = tool_group_id;
    if (observation.has_visible_tool_calls and
        (resolved_tool_group_id == null or
            (!observation.saw_tool_start and observation.has_visible_text)))
    {
        resolved_tool_group_id = .{
            .turn_id = turn_id,
            .anchor_step_id = step_id,
        };
    }

    var next_active_group_id = active_group_id;
    if (observation.has_visible_tool_calls) {
        next_active_group_id = resolved_tool_group_id;
    }
    if (observation.saw_visible_text_after_tool_start or
        (observation.has_visible_text and !observation.has_visible_tool_calls))
    {
        next_active_group_id = null;
    }
    return .{
        .tool_group_id = resolved_tool_group_id,
        .active_group_id = next_active_group_id,
    };
}

pub fn activityKind(registry: tool_dispatch.Registry, tool_name: []const u8) types.ToolActivityKind {
    if (tooling_presentation.isProviderSearchAlias(tool_name)) return .read;
    return tool_dispatch.toolActivityKind(registry, tool_name);
}

pub fn activityKindForCall(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) types.ToolActivityKind {
    if (tooling_presentation.isProviderSearchAlias(call.name)) return .read;
    return tool_dispatch.toolActivityKindForCall(alloc, registry, call);
}

fn formatProvisionalProgressLabel(
    buf: []u8,
    action_label: []const u8,
    label_value: ?[]const u8,
) ![]const u8 {
    if (label_value) |value| {
        return std.mem.print(buf, "● {s}\x1b[0m {s}{s}\x1b[0m", .{ action_label, shared_theme.current().tool_stdout_style, value });
    }
    return std.mem.print(buf, "● {s}\x1b[0m", .{action_label});
}

pub fn fileMutationDisplayPath(
    arena: Allocator,
    authority: command_admission.ToolExecutionAuthority,
) !?[]const u8 {
    return switch (authority) {
        .file_mutation => |file_authority| if (file_authority.prepared) |prepared|
            prepared.display_path
        else blk: {
            const encoded = try text_utils.encodeTerminalSafe(
                arena,
                file_authority.input.path(),
                diff.max_encoded_label_bytes,
            );
            break :blk encoded.bytes;
        },
        else => null,
    };
}

pub noinline fn startToolVisibleLifecycle(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    presentation_group_id: ?types.ToolPresentationGroupId,
    call: ToolCall,
    display_target: ?[]const u8,
) !bool {
    const activity_kind = activityKindForCall(arena, hooks.tool_registry, call);
    if (activity_kind == .ask) return false;
    const redacted_arguments = try text_utils.maskSecrets(arena, call.arguments_json);
    const activity_line = if (call.argument_integrity == .valid) try hooks.describe_tool_action(
        hooks.ctx,
        arena,
        call,
        display_target,
    ) else null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .presentation_group_id = presentation_group_id,
        .reconciles_provisional_call_id = call.provisional_id,
        .tool_name = call.name,
        .activity_kind = activity_kind,
        .arguments_json = redacted_arguments,
        .place_after_current_transcript = false,
    } });
    if (activity_line) |line| {
        try hooks.push_tool_lifecycle(hooks.ctx, .{ .progress = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .text = line,
        } });
    }
    return true;
}

pub fn finishDeniedToolStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    label: []const u8,
) !void {
    return finishDeniedToolStatusInternal(
        hooks,
        arena,
        turn_id,
        call,
        status_started,
        display_target,
        label,
        null,
        null,
        null,
    );
}

fn finishDeferredToolStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
) !void {
    const line = try hooks.describe_tool_action_denied(
        hooks.ctx,
        arena,
        call,
        null,
        types.context_deferred_tool_status_label,
    );
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .terminal = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .outcome = .{
            .kind = .deferred,
            .summary = line,
        },
    } });
}

fn finishDeniedToolStatusInternal(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    label: []const u8,
    safe_result: ?[]const u8,
    result_memory: ?types.ToolResultMemory,
    command_result_json: ?[]const u8,
) !void {
    if (!status_started) return;
    const denied_line = try hooks.describe_tool_action_denied(
        hooks.ctx,
        arena,
        call,
        display_target,
        label,
    );
    const command_artifact_handle = if (activityKindForCall(arena, hooks.tool_registry, call) == .command)
        try commandArtifactHandle(arena, command_result_json)
    else
        null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{
        .terminal = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .outcome = .{
                .kind = if (std.mem.eql(u8, label, "Cancelled"))
                    .cancelled
                else if (std.mem.eql(u8, label, "Failed"))
                    .failed
                else
                    .denied,
                .summary = denied_line,
            },
            .result = safe_result,
            .result_memory = result_memory,
            .command_artifact_handle = command_artifact_handle,
        },
    });
}

pub fn finishCancelledToolStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    result: ToolExecutionResult,
) !void {
    if (!status_started) return;
    const label = if (try isShellWaitCall(arena, call))
        "Stopped waiting for"
    else
        "Cancelled";
    const line = try hooks.describe_tool_action_denied(
        hooks.ctx,
        arena,
        call,
        display_target,
        label,
    );
    const command_activity = activityKindForCall(
        arena,
        hooks.tool_registry,
        call,
    ) == .command;
    const shell_command = command_activity and std.mem.eql(u8, call.name, "shell");
    const command_artifact_handle = if (command_activity and !shell_command)
        commandArtifactHandle(arena, result.command_result_json) catch |err| blk: {
            debug_trace.logf("tool", "cancelled command artifact handle omitted err={s}", .{@errorName(err)});
            break :blk null;
        }
    else
        null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .terminal = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .outcome = .{
            .kind = .cancelled,
            .summary = line,
        },
        .result_memory = result.tool_result_memory,
        .command_artifact_handle = command_artifact_handle,
    } });
}

fn isShellWaitCall(arena: Allocator, call: ToolCall) Allocator.Error!bool {
    if (!std.mem.eql(u8, call.name, "shell")) return false;
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        arena,
        call.arguments_json,
        .{},
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => false,
    };
    defer parsed.deinit();
    const outer = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const object = if (outer.get("request")) |request| switch (request) {
        .object => |value| value,
        else => return false,
    } else outer;
    const action = switch (object.get("action") orelse return false) {
        .string => |value| value,
        else => return false,
    };
    return std.mem.eql(u8, action, "wait");
}

pub fn publishSubagentCompletionPreview(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    result: ToolExecutionResult,
) !bool {
    if (!std.mem.eql(u8, call.name, "subagent")) return false;
    const base_line = if (try tooling_presentation.subagentStatusLine(
        arena,
        call,
        result.model_output,
    )) |line|
        try arena.print("● {s}", .{line})
    else switch (result.status) {
        .success => try hooks.describe_tool_action_completed(
            hooks.ctx,
            arena,
            call,
            null,
        ),
        .failure => try hooks.describe_tool_action_denied(
            hooks.ctx,
            arena,
            call,
            null,
            try tooling_presentation.subagentFailureLabel(
                arena,
                call,
                result.model_output,
            ),
        ),
    };
    const line = if (result.subagent_completion) |status|
        renderedSubagentSummary(hooks, arena, base_line, status)
    else
        base_line;
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .progress = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .text = line,
    } });
    return true;
}

pub fn finishExecutedToolStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    result: ToolExecutionResult,
    safe_result: []const u8,
    result_memory: types.ToolResultMemory,
    diff_entry: ?DiffEntryPayload,
) !void {
    if (!status_started) return;
    const activity_kind = activityKindForCall(arena, hooks.tool_registry, call);
    const command_decision = if (activity_kind == .command)
        try commandOutcomeDecision(arena, result_memory.command_process_presentation)
    else
        null;
    const terminal_action_decision = if (std.mem.eql(u8, call.name, "shell"))
        try terminalActionOutcomeDecision(arena, result_memory.terminal_action_presentation)
    else
        null;
    const outcome_decision = command_decision orelse terminal_action_decision;
    const base_line = if (try tooling_presentation.subagentStatusLine(arena, call, result.model_output)) |line|
        line
    else if (outcome_decision) |decision| blk: {
        const base = try hooks.describe_tool_action_denied(
            hooks.ctx,
            arena,
            call,
            display_target,
            decision.label,
        );
        break :blk if (decision.detail) |detail|
            try arena.print("{s}: {s}", .{ base, detail })
        else
            base;
    } else switch (result.status) {
        .success => if (file_mutation_contract.resultIsNoop(call.name, result.model_output))
            result.model_output
        else
            try hooks.describe_tool_action_completed(
                hooks.ctx,
                arena,
                call,
                display_target,
            ),
        .failure => blk: {
            const base = try hooks.describe_tool_action_denied(
                hooks.ctx,
                arena,
                call,
                display_target,
                try tooling_presentation.subagentFailureLabel(arena, call, safe_result),
            );
            if (std.mem.eql(u8, call.name, "shell")) {
                if (try tool_result_errors.isTerminalEndedFailure(arena, safe_result)) {
                    break :blk try arena.print("{s} · ended when fx exited", .{base});
                }
                if (try tool_result_errors.inspectTerminalActionFieldCorrection(
                    arena,
                    safe_result,
                )) |correction| {
                    break :blk try arena.print(
                        "{s} · {d} invalid field{s}",
                        .{
                            base,
                            correction.invalid_field_count,
                            if (correction.invalid_field_count == 1) "" else "s",
                        },
                    );
                }
            }
            const detail = (try failureStatusDetail(
                arena,
                call,
                result,
                safe_result,
            )) orelse break :blk base;
            if (detail.len == 0) break :blk base;
            break :blk try arena.print("{s}: {s}", .{ base, detail });
        },
    };
    const summary_line = if (result.web_fetch_completion) |completion|
        try formatWebFetchCompletion(arena, base_line, completion)
    else if (result.subagent_completion) |status|
        renderedSubagentSummary(hooks, arena, base_line, status)
    else
        base_line;
    const line = if (diff_entry) |payload| blk: {
        break :blk try formatToolStatusWithStats(arena, summary_line, payload.additions, payload.deletions, hooks.diff_marker_styles);
    } else summary_line;
    const shell_command = activity_kind == .command and
        std.mem.eql(u8, call.name, "shell");
    const presentation_result = try presentedToolResult(
        arena,
        call,
        activity_kind,
        if (shell_command) result.model_output else safe_result,
    );
    var presentation_memory = result_memory;
    if (shell_command) {
        presentation_memory.output_handle = null;
        presentation_memory.preview = presentation_result;
    }
    const command_artifact_handle = if (activity_kind == .command and
        !shell_command)
        try commandArtifactHandle(arena, result.command_result_json)
    else
        null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{
        .terminal = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .outcome = .{
                .kind = if (outcome_decision) |decision|
                    decision.outcome
                else if (result.status == .success)
                    .completed
                else
                    .failed,
                .summary = line,
            },
            .result = presentation_result,
            .result_memory = presentation_memory,
            .command_artifact_handle = command_artifact_handle,
        },
    });
}

fn presentedToolResult(
    arena: Allocator,
    call: ToolCall,
    activity_kind: types.ToolActivityKind,
    safe_result: []const u8,
) Allocator.Error![]const u8 {
    if (activity_kind != .command or !std.mem.eql(u8, call.name, "shell")) {
        return safe_result;
    }
    return try managed_execution.modelOutputDelta(arena, safe_result) orelse
        safe_result;
}

pub const ToolOutcomeDecision = struct {
    outcome: types.ToolOutcomeKind,
    label: []const u8,
    detail: ?[]const u8 = null,
};

pub fn commandOutcomeDecision(
    arena: Allocator,
    presentation: ?types.CommandProcessPresentation,
) !?ToolOutcomeDecision {
    const value = presentation orelse return null;
    return switch (value) {
        .exit_code => |code| if (code == 0)
            .{ .outcome = .completed, .label = "Ran" }
        else
            .{
                .outcome = .failed,
                .label = try arena.print("Exited {d}", .{code}),
            },
        .signal => |signal| .{
            .outcome = .failed,
            .label = try arena.print("Signaled {d}", .{signal}),
        },
        .timed_out => .{ .outcome = .failed, .label = "Timed out" },
        .output_capture_failed => .{
            .outcome = .failed,
            .label = "Output capture failed",
        },
    };
}

pub fn terminalActionOutcomeDecision(
    arena: Allocator,
    presentation: ?types.TerminalActionPresentation,
) !?ToolOutcomeDecision {
    const value = presentation orelse return null;
    return switch (value) {
        .returned => |returned| switch (returned) {
            .started => .{ .outcome = .completed, .label = "Started" },
            .condition_met => .{ .outcome = .completed, .label = "Condition met for" },
            .safety_ceiling => .{ .outcome = .completed, .label = "Wait limit reached for" },
            .cancelled => .{ .outcome = .cancelled, .label = "Cancelled" },
            .exited => |code| .{
                .outcome = if (code == 0) .completed else .failed,
                .label = try arena.print("Exited {d}", .{code}),
            },
            .signal => |signal| .{
                .outcome = .failed,
                .label = try arena.print("Terminated by signal {d}", .{signal}),
            },
        },
        .failed => |failed| if (failed == .cancelled)
            .{ .outcome = .cancelled, .label = "Cancelled" }
        else
            .{
                .outcome = .failed,
                .label = "Failed",
                .detail = failed.detail(),
            },
    };
}

fn failureStatusDetail(
    arena: Allocator,
    call: ToolCall,
    result: ToolExecutionResult,
    safe_result: []const u8,
) !?[]const u8 {
    switch (call.argument_integrity) {
        .malformed_json => return "invalid JSON arguments",
        .non_object_json => return "non-object arguments",
        .valid => {},
    }
    if (result.status_detail) |detail| {
        if (!std.mem.eql(u8, detail, "preflight failed")) return detail;

        if (file_mutation_contract.isToolName(call.name) and
            std.mem.startsWith(u8, safe_result, call.name))
        {
            const failure_prefix = " failed: ";
            const remainder = safe_result[call.name.len..];
            if (std.mem.startsWith(u8, remainder, failure_prefix)) {
                const actionable = remainder[failure_prefix.len..];
                if (actionable.len > 0 and
                    std.mem.findScalar(u8, actionable, '\n') == null and
                    std.mem.findScalar(u8, actionable, '\r') == null)
                {
                    const masked = try text_utils.maskSecrets(arena, actionable);
                    const encoded = try text_utils.encodeTerminalSafeInline(arena, masked, 256);
                    return if (encoded.bytes.len == 0) detail else encoded.bytes;
                }
            }
        }

        if (safe_result.len == 0) return detail;
        const masked = try text_utils.maskSecrets(arena, safe_result);
        const encoded = try text_utils.encodeTerminalSafeInline(arena, masked, 256);
        return if (encoded.bytes.len == 0) detail else encoded.bytes;
    }

    return null;
}

fn commandArtifactHandle(
    arena: Allocator,
    command_result_json: ?[]const u8,
) !?[]const u8 {
    const json = command_result_json orelse return null;
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return null,
    };
    const kind = switch (object.get("kind") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    if (!std.mem.eql(u8, kind, "command") and
        !std.mem.eql(u8, kind, "foreground")) return null;
    const output_file = switch (object.get("output_file") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    const handle = std.Io.Dir.path.basename(output_file);
    if (!std.mem.startsWith(u8, handle, "fx-command-") or
        !std.mem.endsWith(u8, handle, ".log") or
        std.mem.endsWith(u8, handle, ".stdout.log") or
        std.mem.endsWith(u8, handle, ".stderr.log")) return null;
    const owned: []const u8 = try arena.dupe(u8, handle);
    return owned;
}

pub fn finishCommittedFileStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    preview: diff.FileChangePreview,
) !void {
    if (!status_started) return;
    const base_line = try hooks.describe_tool_action_completed(
        hooks.ctx,
        arena,
        call,
        display_target,
    );
    const line = try formatToolStatusWithStats(
        arena,
        base_line,
        preview.additions,
        preview.deletions,
        hooks.diff_marker_styles,
    );
    try hooks.push_tool_lifecycle(hooks.ctx, .{
        .terminal = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .outcome = .{
                .kind = .completed,
                .summary = line,
            },
        },
    });
}

fn renderedSubagentSummary(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    base: []const u8,
    status: types.SubagentStatus,
) []const u8 {
    const renderer = hooks.subagent_status_renderer orelse return base;
    var buf: [256]u8 = undefined;
    const status_line = renderer.render(&buf, status);
    if (status_line.len == 0) return base;
    return arena.print("{s}\n  {s}", .{ base, status_line }) catch base;
}

fn formatWebFetchCompletion(arena: Allocator, base: []const u8, completion: types.WebFetchCompletion) ![]const u8 {
    const cache = if (completion.cache_hit) "cache hit" else "fetched";
    const artifact = switch (completion.artifact_state) {
        .none => "",
        .stored => " | artifact stored",
        .unavailable => " | artifact unavailable",
    };
    return arena.print(
        "{s} \x1b[38;5;245m| {s} | {d} bytes | HTTP {d} | {d}ms | {s}{s}\x1b[0m",
        .{ base, completion.url(), completion.bytes, completion.status, completion.duration_ms, cache, artifact },
    );
}

pub fn formatToolStatusWithStats(
    arena: Allocator,
    base: []const u8,
    additions: usize,
    deletions: usize,
    markers: runtime_deps.DiffMarkerStyles,
) ![]const u8 {
    const accent = "\x1b[38;5;252m";
    const dim = "\x1b[38;5;245m";
    const reset = "\x1b[0m";
    // Fall back to the neutral accent when no marker color is supplied.
    const add_style = if (markers.added.len != 0) markers.added else accent;
    const rem_style = if (markers.removed.len != 0) markers.removed else accent;
    if (additions > 0 and deletions > 0) {
        return arena.print("{s} {s}+{d}{s} {s}/{s} {s}-{d}{s}", .{ base, add_style, additions, reset, dim, reset, rem_style, deletions, reset });
    } else if (additions > 0) {
        return arena.print("{s} {s}+{d}{s}", .{ base, add_style, additions, reset });
    } else if (deletions > 0) {
        return arena.print("{s} {s}-{d}{s}", .{ base, rem_style, deletions, reset });
    }
    return base;
}

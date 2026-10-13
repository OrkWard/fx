const std = @import("std");
const skill_contract = @import("../../skills/skill_contract.zig");
const types = @import("../../shared/types.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const io_mod = @import("../../shared/io.zig");

const runtime_deps = @import("deps.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const PermissionGrant = types.PermissionGrant;
const ToolCall = types.ToolCall;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

pub fn isReadOnlyCall(registry: tool_dispatch.Registry, call: ToolCall) bool {
    if (call.provider_result != null) return false;

    const tool = registry.lookup(call.name) orelse return false;
    return switch (tool.executor_kind) {
        .glob_files => tool.activity_kind == .list,
        .read_file,
        .read_tool_result,
        .grep_files,
        .skill,
        .web_fetch,
        .web_search,
        => tool.activity_kind == .read,
        else => false,
    };
}

pub fn parallelReadOnlyPrefixLen(registry: tool_dispatch.Registry, calls: []const ToolCall) usize {
    var len: usize = 0;
    while (len < calls.len and isReadOnlyCall(registry, calls[len])) : (len += 1) {}
    return len;
}

fn isSubagentCall(registry: tool_dispatch.Registry, call: ToolCall) bool {
    if (call.provider_result != null) return false;
    const tool = registry.lookup(call.name) orelse return false;
    return tool.executor_kind == .subagent and tool.activity_kind == .subagent;
}

fn parallelSubagentPrefixLen(registry: tool_dispatch.Registry, calls: []const ToolCall) usize {
    var len: usize = 0;
    while (len < calls.len and isSubagentCall(registry, calls[len])) : (len += 1) {}
    return len;
}

pub const GroupKind = enum { none, read_only, subagent };

pub const LeadingGroup = struct {
    kind: GroupKind = .none,
    len: usize = 0,
};

pub fn leadingParallelGroup(
    registry: tool_dispatch.Registry,
    calls: []const ToolCall,
) LeadingGroup {
    const read_only_len = parallelReadOnlyPrefixLen(registry, calls);
    if (read_only_len > 0) return .{ .kind = .read_only, .len = read_only_len };
    const subagent_len = parallelSubagentPrefixLen(registry, calls);
    if (subagent_len > 0) return .{ .kind = .subagent, .len = subagent_len };
    return .{};
}

pub const ParallelToolResult = struct {
    call_id: []const u8,
    tool_name: []const u8,
    execution: ToolExecutionResult,
};

pub const ParallelToolAttempt = union(enum) {
    completed: ParallelToolResult,
    cancelled,
};

pub const ParallelRunResult = struct {
    attempts: []ParallelToolAttempt,
    first_cancelled_index: ?usize = null,

    pub fn deinit(self: *ParallelRunResult, alloc: Allocator) void {
        for (self.attempts) |attempt| freeParallelToolAttempt(alloc, attempt);
        alloc.free(self.attempts);
        self.* = undefined;
    }
};

pub const ParallelHookExecContext = struct {
    skill_locations: ?*const skill_contract.Locations = null,
    hooks: *const AgentRuntimeDeps,
    turn_id: u64,
    root_user_intent_context: []const u8,
    current_turn_messages: []const ChatMessage,
    session_grants: []const PermissionGrant,
    permission_mode: types.PermissionMode,
    max_tool_result_bytes: usize,
    classification_complete: []const bool = &.{},
};

const ParallelExecuteFn = *const fn (*anyopaque, Allocator, ToolCall, usize) anyerror!ToolExecutionResult;
const ParallelFormatErrorFn = *const fn (*anyopaque, Allocator, []const u8, anyerror) anyerror![]const u8;
const ParallelAttemptObserverFn = *const fn (*anyopaque, Allocator, ToolCall, ParallelToolAttempt, usize) void;

pub const ParallelAttemptObserver = struct {
    ctx: *anyopaque,
    notify: ParallelAttemptObserverFn,
};

pub const ParallelRunOptions = struct {
    exec_ctx: *anyopaque,
    execute: ParallelExecuteFn,
    format_ctx: *anyopaque,
    format_error: ParallelFormatErrorFn,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    attempt_observer: ?ParallelAttemptObserver = null,
};

const ParallelCompletionState = struct {
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
};

const ParallelWorkerSlot = struct {
    arena_state: std.heap.ArenaAllocator,
    thread: ?std.Thread = null,
    result: ?ToolExecutionResult = null,
    err: ?anyerror = null,
    owner_cancelled_at_error: bool = false,
    completed: bool = false,
    observed: bool = false,
};

pub fn runSequentialCalls(
    alloc: Allocator,
    calls: []const ToolCall,
    options: ParallelRunOptions,
) Allocator.Error!ParallelRunResult {
    const attempts = try alloc.alloc(ParallelToolAttempt, calls.len);
    var initialized: usize = 0;
    errdefer {
        for (attempts[0..initialized]) |attempt| freeParallelToolAttempt(alloc, attempt);
        alloc.free(attempts);
    }

    var first_cancelled_index: ?usize = null;
    for (calls, 0..) |call, index| {
        const attempt: ParallelToolAttempt = if (cancelRequested(options.cancel_flag)) cancelled: {
            if (first_cancelled_index == null) first_cancelled_index = index;
            break :cancelled .cancelled;
        } else completed: {
            const execution = options.execute(options.exec_ctx, alloc, call, index) catch |err| blk: {
                const output = options.format_error(options.format_ctx, alloc, call.name, err) catch
                    try alloc.print("Tool execution failed: {s}", .{@errorName(err)});
                defer alloc.free(output);
                break :blk ToolExecutionResult{
                    .status = .failure,
                    .model_output = output,
                };
            };
            break :completed .{
                .completed = try duplicateParallelToolResult(alloc, call, execution),
            };
        };
        attempts[index] = attempt;
        initialized += 1;
        observeParallelAttempt(options, alloc, call, attempt, index);
    }
    return .{ .attempts = attempts, .first_cancelled_index = first_cancelled_index };
}

pub fn runParallelCalls(
    alloc: Allocator,
    calls: []const ToolCall,
    options: ParallelRunOptions,
) Allocator.Error!ParallelRunResult {
    var completion_state = ParallelCompletionState{};
    const slots = try alloc.alloc(ParallelWorkerSlot, calls.len);
    defer alloc.free(slots);
    for (slots) |*slot| {
        slot.* = .{ .arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator) };
    }
    defer {
        for (slots) |*slot| {
            if (slot.thread) |thread| thread.join();
            slot.arena_state.deinit();
        }
    }

    const initialized = try alloc.alloc(bool, calls.len);
    defer alloc.free(initialized);
    @memset(initialized, false);
    const attempts = try alloc.alloc(ParallelToolAttempt, calls.len);
    errdefer {
        for (attempts, initialized) |attempt, is_initialized| {
            if (is_initialized) freeParallelToolAttempt(alloc, attempt);
        }
        alloc.free(attempts);
    }

    var started: usize = 0;
    for (calls, 0..) |call, index| {
        slots[index].thread = std.Thread.spawn(.{}, parallelWorkerMain, .{ &completion_state, &slots[index], options, call, index }) catch |err| {
            for (slots[0..started]) |*slot| {
                if (slot.thread) |thread| thread.join();
                slot.thread = null;
            }
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.OutOfMemory,
            };
        };
        started += 1;
    }

    var completed_count: usize = 0;
    var first_cancelled_index: ?usize = null;
    while (completed_count < started) : (completed_count += 1) {
        const index = waitForCompletedSlot(&completion_state, slots);
        const slot = &slots[index];
        if (slot.thread) |thread| {
            thread.join();
            slot.thread = null;
        }
        const attempt = try materializeParallelAttempt(alloc, calls[index], slot, options);
        attempts[index] = attempt;
        initialized[index] = true;
        if (attempt == .cancelled) {
            first_cancelled_index = if (first_cancelled_index) |current|
                @min(current, index)
            else
                index;
        }
        observeParallelAttempt(options, alloc, calls[index], attempt, index);
    }

    return .{
        .attempts = attempts,
        .first_cancelled_index = first_cancelled_index,
    };
}

fn parallelWorkerMain(
    completion_state: *ParallelCompletionState,
    slot: *ParallelWorkerSlot,
    options: ParallelRunOptions,
    call: ToolCall,
    index: usize,
) void {
    defer markParallelWorkerCompleted(completion_state, slot);
    if (cancelRequested(options.cancel_flag)) {
        slot.err = error.Cancelled;
        slot.owner_cancelled_at_error = true;
        return;
    }
    const worker_alloc = slot.arena_state.allocator();
    slot.result = options.execute(options.exec_ctx, worker_alloc, call, index) catch |err| {
        slot.err = err;
        slot.owner_cancelled_at_error =
            err == error.Cancelled and cancelRequested(options.cancel_flag);
        return;
    };
}

fn markParallelWorkerCompleted(state: *ParallelCompletionState, slot: *ParallelWorkerSlot) void {
    const io = io_mod.getIo();
    state.mutex.lockUncancelable(io);
    slot.completed = true;
    state.changed.broadcast(io);
    state.mutex.unlock(io);
}

fn waitForCompletedSlot(state: *ParallelCompletionState, slots: []ParallelWorkerSlot) usize {
    const io = io_mod.getIo();
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    while (true) {
        for (slots, 0..) |*slot, index| {
            if (!slot.completed or slot.observed) continue;
            slot.observed = true;
            return index;
        }
        state.changed.waitUncancelable(io, &state.mutex);
    }
}

fn materializeParallelAttempt(
    alloc: Allocator,
    call: ToolCall,
    slot: *const ParallelWorkerSlot,
    options: ParallelRunOptions,
) !ParallelToolAttempt {
    if (slot.err) |err| {
        if (err == error.Cancelled and slot.owner_cancelled_at_error) return .cancelled;
    }

    var formatted_failure: ?[]const u8 = null;
    defer if (formatted_failure) |output| alloc.free(output);
    const execution: ToolExecutionResult = if (slot.err) |err| .{
        .status = .failure,
        .model_output = blk: {
            const output = options.format_error(options.format_ctx, alloc, call.name, err) catch |format_err| try alloc.print(
                "Tool execution failed: {s}; additionally failed to format error: {s}",
                .{ @errorName(err), @errorName(format_err) },
            );
            formatted_failure = output;
            break :blk output;
        },
    } else slot.result.?;
    return .{ .completed = try duplicateParallelToolResult(alloc, call, execution) };
}

fn observeParallelAttempt(
    options: ParallelRunOptions,
    alloc: Allocator,
    call: ToolCall,
    attempt: ParallelToolAttempt,
    index: usize,
) void {
    const observer = options.attempt_observer orelse return;
    observer.notify(observer.ctx, alloc, call, attempt, index);
}

fn cancelRequested(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.seq_cst) else false;
}

pub fn parallelHookExecute(ctx: *anyopaque, alloc: Allocator, call: ToolCall, index: usize) !ToolExecutionResult {
    const exec_ctx: *ParallelHookExecContext = @ptrCast(@alignCast(ctx));
    return exec_ctx.hooks.execute_tool_call(exec_ctx.hooks.ctx, .{
        .skill_locations = exec_ctx.skill_locations,
        .call_allocator = alloc,
        .result_allocator = alloc,
        .call = call,
        .authority = .ordinary,
        .permission_mode = exec_ctx.permission_mode,
        .root_user_intent_context = exec_ctx.root_user_intent_context,
        .current_turn_messages = exec_ctx.current_turn_messages,
        .session_grants = exec_ctx.session_grants,
        .max_tool_result_bytes = exec_ctx.max_tool_result_bytes,
        .classification_complete = index < exec_ctx.classification_complete.len and
            exec_ctx.classification_complete[index],
        .lifecycle_id = .{ .turn_id = exec_ctx.turn_id, .call_id = call.id },
    });
}

pub fn parallelHookFormatError(ctx: *anyopaque, alloc: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    const exec_ctx: *ParallelHookExecContext = @ptrCast(@alignCast(ctx));
    return exec_ctx.hooks.format_tool_execution_error(exec_ctx.hooks.ctx, alloc, tool_name, err);
}

fn duplicateParallelToolResult(alloc: Allocator, call: ToolCall, execution: ToolExecutionResult) Allocator.Error!ParallelToolResult {
    const call_id = try alloc.dupe(u8, call.id);
    errdefer alloc.free(call_id);
    const tool_name = try alloc.dupe(u8, call.name);
    errdefer alloc.free(tool_name);

    if (execution.diff_entry != null or
        execution.finish_turn or
        execution.tool_result_memory_prepared or
        execution.committed_file_handoff != null or
        execution.deferred_tool_completion != null)
    {
        return .{
            .call_id = call_id,
            .tool_name = tool_name,
            .execution = .{
                .status = .failure,
                .model_output = try alloc.dupe(u8, "Parallel tool returned an unsupported side-effect payload."),
            },
        };
    }
    var duplicated_execution: ToolExecutionResult = .{
        .model_content_kind = execution.model_content_kind,
        .status = execution.status,
        .model_output = try alloc.dupe(u8, execution.model_output),
        .web_search_completion = execution.web_search_completion,
        .web_fetch_completion = execution.web_fetch_completion,
        .inner_usage = execution.inner_usage,
    };
    errdefer freeOwnedToolExecutionResult(alloc, duplicated_execution);
    if (execution.status_detail) |detail| {
        duplicated_execution.status_detail = try alloc.dupe(u8, detail);
    }
    if (execution.system_notice) |notice| {
        duplicated_execution.system_notice = try alloc.dupe(u8, notice);
    }
    if (execution.interactive_notice) |notice| {
        duplicated_execution.interactive_notice = try types.dupeSemanticNotice(alloc, notice);
    }
    duplicated_execution.context_notices = try duplicateContextNotices(alloc, execution.context_notices);
    if (execution.command_result_json) |json| {
        duplicated_execution.command_result_json = try alloc.dupe(u8, json);
    }
    duplicated_execution.tool_result_memory = try duplicateToolResultMemory(
        alloc,
        execution.tool_result_memory,
    );
    if (execution.subagent_completion) |status| {
        duplicated_execution.subagent_completion = try duplicateSubagentStatus(alloc, status);
    }

    return .{
        .call_id = call_id,
        .tool_name = tool_name,
        .execution = duplicated_execution,
    };
}

fn duplicateToolResultMemory(
    alloc: Allocator,
    source: ?types.ToolResultMemory,
) Allocator.Error!?types.ToolResultMemory {
    const memory = source orelse return null;
    return try types.dupeToolResultMemory(alloc, memory);
}

fn duplicateSubagentStatus(
    alloc: Allocator,
    status: types.SubagentStatus,
) Allocator.Error!types.SubagentStatus {
    const model = try alloc.dupe(u8, status.model);
    errdefer alloc.free(model);
    const session_title = if (status.session_title) |title|
        try alloc.dupe(u8, title)
    else
        null;
    return .{
        .session_title = session_title,
        .model = model,
        .effort = status.effort,
        .input_tokens = status.input_tokens,
        .context_window = status.context_window,
    };
}

pub fn reportInnerToolUsage(hooks: *const AgentRuntimeDeps, tool_name: []const u8, execution: ToolExecutionResult) void {
    const usage = execution.inner_usage orelse return;
    const report = hooks.report_inner_tool_usage orelse return;
    report(hooks.ctx, tool_name, usage);
}

fn freeParallelToolAttempt(alloc: Allocator, attempt: ParallelToolAttempt) void {
    switch (attempt) {
        .completed => |result| freeParallelToolResult(alloc, result),
        .cancelled => {},
    }
}

fn freeParallelToolResult(alloc: Allocator, result: ParallelToolResult) void {
    alloc.free(result.call_id);
    alloc.free(result.tool_name);
    freeOwnedToolExecutionResult(alloc, result.execution);
}

fn freeOwnedToolExecutionResult(alloc: Allocator, result: ToolExecutionResult) void {
    alloc.free(result.model_output);
    if (result.status_detail) |value| alloc.free(value);
    if (result.system_notice) |value| alloc.free(value);
    if (result.interactive_notice) |notice| types.freeSemanticNotice(alloc, notice);
    freeContextNotices(alloc, result.context_notices);
    if (result.command_result_json) |value| alloc.free(value);
    if (result.tool_result_memory) |memory| types.freeToolResultMemory(alloc, memory);
    if (result.subagent_completion) |status| {
        alloc.free(status.model);
        if (status.session_title) |title| alloc.free(title);
    }
}

fn duplicateContextNotices(alloc: Allocator, notices: []const []const u8) Allocator.Error![]const []const u8 {
    if (notices.len == 0) return &.{};

    const duplicated = try alloc.alloc([]const u8, notices.len);
    var copied: usize = 0;
    errdefer {
        for (duplicated[0..copied]) |notice| alloc.free(notice);
        alloc.free(duplicated);
    }
    for (notices, 0..) |notice, i| {
        duplicated[i] = try alloc.dupe(u8, notice);
        copied += 1;
    }
    return duplicated;
}

fn freeContextNotices(alloc: Allocator, notices: []const []const u8) void {
    for (notices) |notice| alloc.free(notice);
    if (notices.len > 0) alloc.free(notices);
}

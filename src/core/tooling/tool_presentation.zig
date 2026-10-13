const std = @import("std");
const command_policy = @import("command_policy.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("tool_args.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const terminal_ui_projection = @import("../terminal/ui_projection.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const max_run_command_activity_bytes = 120;
const max_run_command_activity_source_bytes = max_run_command_activity_bytes * max_run_command_activity_bytes;
pub const max_run_command_reflow_bytes = max_run_command_activity_source_bytes;

pub const ToolActionInput = struct {
    tool_registry: tool_dispatch.Registry,
    call: ToolCall,
    workspace_root: []const u8 = "",
    display_target: ?[]const u8 = null,
};

pub const SubagentActionState = union(enum) {
    identity,
    active,
    pending,
    completed,
    feedback: types.SteeringDelivery,
    stopped: []const u8,
};

pub const SubagentAction = struct {
    label: []u8,
    detail: []u8,

    pub fn deinit(self: SubagentAction, alloc: Allocator) void {
        alloc.free(self.label);
        alloc.free(self.detail);
    }
};

/// The caller owns the returned label and detail. Invalid requests have no projection.
pub fn subagentAction(
    alloc: Allocator,
    call: ToolCall,
    state: SubagentActionState,
) Allocator.Error!?SubagentAction {
    if (!std.mem.eql(u8, call.name, "subagent")) return null;
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();
    const outer = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    const args = if (outer.get("request")) |request| switch (request) {
        .object => |object| object,
        else => return null,
    } else outer;
    const action = tool_args.optionalStringArg(args, "action") orelse return null;
    const named = std.mem.eql(u8, action, "message");
    if (!named and !std.mem.eql(u8, action, "run")) return null;
    if (state == .feedback and !named) return null;
    const raw_name = if (named) tool_args.optionalStringArg(args, "agent") orelse return null else "Subagent";
    const raw_preview = tool_args.optionalStringArg(args, if (named) "message" else "task") orelse return null;
    const name = try text_utils.encodeTerminalSafe(scratch, raw_name, 64);
    const preview = try subagentPreview(scratch, raw_preview);
    const label = switch (state) {
        .identity => try alloc.dupe(u8, name.bytes),
        .active => try alloc.print("{s} working", .{name.bytes}),
        .pending => try alloc.print("{s} still running", .{name.bytes}),
        .completed => try alloc.print("{s} {s}", .{ name.bytes, if (named) "replied" else "finished" }),
        .feedback => |delivery| try alloc.print("{s} feedback {s}", .{ name.bytes, switch (delivery) {
            .queued => "queued",
            .applied => "applied",
            .not_applied => "not applied",
        } }),
        .stopped => |reason| if (std.mem.eql(u8, reason, "Failed"))
            try alloc.print("{s} failed", .{name.bytes})
        else if (std.mem.eql(u8, reason, "Busy"))
            try alloc.print("{s} busy; message not sent", .{name.bytes})
        else if (std.mem.eql(u8, reason, "Cancelled") or std.mem.eql(u8, reason, "Interrupted"))
            try alloc.print("{s} interrupted", .{name.bytes})
        else
            try alloc.print("{s} {s}", .{ reason, name.bytes }),
    };
    errdefer alloc.free(label);
    const detail = if (preview.len == 0)
        try alloc.dupe(u8, "")
    else
        try alloc.print("· {s}", .{preview});
    return .{ .label = label, .detail = detail };
}

fn subagentPreview(alloc: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var buffer: [124]u8 = undefined;
    var len: usize = 0;
    var pending_space = false;
    // Bound scanning even when a large request contains only whitespace.
    const source = raw[0..text_utils.utf8BackwardBoundary(raw, @min(raw.len, 16 * 1024))];
    for (source) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = len > 0;
            continue;
        }
        if (pending_space) {
            buffer[len] = ' ';
            len += 1;
            pending_space = false;
        }
        if (len == buffer.len) break;
        buffer[len] = byte;
        len += 1;
        if (len == buffer.len) break;
    }
    const encoded = try text_utils.encodeTerminalSafe(alloc, buffer[0..len], 120);
    return encoded.bytes;
}

pub fn subagentStatusLine(alloc: Allocator, call: ToolCall, output: []const u8) Allocator.Error!?[]u8 {
    if (!std.mem.eql(u8, call.name, "subagent")) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, output, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (tool_args.optionalStringArg(parsed.value.object, "delivery")) |value| {
        const delivery = std.meta.stringToEnum(types.SteeringDelivery, value) orelse return null;
        const ok = parsed.value.object.get("ok") orelse return null;
        if (ok != .bool or ok.bool != (delivery != .not_applied)) return null;
        return formatSubagentPlainAction(alloc, call, .{ .feedback = delivery });
    }
    const pending = parsed.value.object.get("pending") orelse return null;
    if (pending != .bool or !pending.bool) return null;
    const ok = parsed.value.object.get("ok") orelse return null;
    if (ok != .bool or !ok.bool) return null;
    return formatSubagentPlainAction(alloc, call, .pending);
}

/// Only structured child terminal failures change the failure label.
pub fn subagentFailureLabel(alloc: Allocator, call: ToolCall, output: []const u8) Allocator.Error![]const u8 {
    if (!std.mem.eql(u8, call.name, "subagent")) return "Failed";
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, output, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => "Failed",
    };
    defer parsed.deinit();
    if (parsed.value != .object) return "Failed";
    const ok = parsed.value.object.get("ok") orelse return "Failed";
    if (ok != .bool or ok.bool) return "Failed";
    const code = tool_args.optionalStringArg(parsed.value.object, "error_code") orelse return "Failed";
    if (std.mem.eql(u8, code, "child_busy")) return "Busy";
    for ([_][]const u8{ "feedback_capacity", "operation_conflict", "override_after_create" }) |rejection| {
        if (std.mem.eql(u8, code, rejection)) return "Message not sent to";
    }
    return if (std.mem.eql(u8, code, "child_cancelled") or std.mem.eql(u8, code, "child_interrupted") or std.mem.eql(u8, code, "child_lost")) "Interrupted" else "Failed";
}

/// The caller owns the returned plain subagent row.
pub fn formatSubagentPlainAction(alloc: Allocator, call: ToolCall, state: SubagentActionState) Allocator.Error!?[]u8 {
    const action = try subagentAction(alloc, call, state) orelse return null;
    defer action.deinit(alloc);
    return try alloc.print("{s}{s}{s}", .{ action.label, if (action.detail.len == 0) "" else " ", action.detail });
}

pub const RunCommandActivity = struct {
    detail: []const u8,
    compatibility_tool: ?*const tool_dispatch.Tool,
};

pub fn isProviderSearchAlias(name: []const u8) bool {
    return std.mem.eql(u8, name, "exa_search") or
        std.mem.eql(u8, name, "perplexity_search") or
        std.mem.eql(u8, name, "parallel_search");
}

fn projectRunCommandActivitySource(
    command: []const u8,
    workspace_root_input: []const u8,
    storage: []u8,
) []const u8 {
    const display_command = stripNoopCurrentDirectoryPrefix(command);
    var workspace_root_end = workspace_root_input.len;
    while (workspace_root_end > 1 and workspace_root_input[workspace_root_end - 1] == '/') {
        workspace_root_end -= 1;
    }
    const workspace_root = workspace_root_input[0..workspace_root_end];
    const can_abbreviate_workspace = workspace_root.len > 1 and workspace_root[0] == '/';
    const source_limit = @min(display_command.len, max_run_command_activity_source_bytes);
    var source_index: usize = 0;
    var projected_len: usize = 0;
    var line_boundary_pending = false;

    while (source_index < source_limit) {
        const byte = display_command[source_index];
        if (byte == '\r' or byte == '\n') {
            line_boundary_pending = true;
            source_index += 1;
            continue;
        }
        if (line_boundary_pending and (byte == ' ' or byte == '\t')) {
            source_index += 1;
            continue;
        }
        if (line_boundary_pending) {
            line_boundary_pending = false;
            if (projected_len > 0) {
                storage[projected_len] = ' ';
                projected_len += 1;
                if (projected_len == storage.len) break;
            }
        }

        if (can_abbreviate_workspace and
            workspace_root.len <= source_limit - source_index and
            workspaceRootMatchesAt(display_command, workspace_root, source_index))
        {
            storage[projected_len] = '.';
            projected_len += 1;
            if (projected_len == storage.len) break;
            source_index += workspace_root.len;
            continue;
        }

        storage[projected_len] = byte;
        projected_len += 1;
        if (projected_len == storage.len) break;
        source_index += 1;
    }

    return storage[0..projected_len];
}

fn stripNoopCurrentDirectoryPrefix(command: []const u8) []const u8 {
    const prefix = "cd . &&";
    if (!std.mem.startsWith(u8, command, prefix)) return command;
    if (command.len == prefix.len or !std.ascii.isWhitespace(command[prefix.len])) return command;

    const remainder = std.mem.trimStart(u8, command[prefix.len..], " \t\r\n");
    return if (remainder.len > 0) remainder else command;
}

fn workspaceRootMatchesAt(command: []const u8, workspace_root: []const u8, index: usize) bool {
    if (!std.mem.startsWith(u8, command[index..], workspace_root)) return false;
    if (index > 0 and isPathTokenByte(command[index - 1])) return false;

    const next_index = index + workspace_root.len;
    if (next_index == command.len) return true;
    return command[next_index] == '/' or !isPathTokenByte(command[next_index]);
}

fn containsUnresolvedAbsolutePath(command: []const u8) bool {
    for (command, 0..) |byte, index| {
        if (byte != '/' or (index > 0 and isPathTokenByte(command[index - 1]))) continue;
        const suffix = command[index..];
        if (std.mem.startsWith(u8, suffix, "/dev/null") and
            (suffix.len == "/dev/null".len or !isPathTokenByte(suffix["/dev/null".len])))
        {
            continue;
        }
        return true;
    }
    return false;
}

fn isPathTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '/', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatRunCommandPermissionLabel(
    alloc: Allocator,
    command: []const u8,
) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();
    const encoded = try text_utils.encodeTerminalSafe(
        scratch,
        command,
        max_run_command_activity_bytes,
    );
    const suffix = try commandApprovalLabelSuffix(scratch, "shell", command);
    return alloc.print("shell.run {s}{s}", .{ encoded.bytes, suffix });
}

/// Returns a borrowed static label when the call is a captured command.
pub fn runCommandCompletedActionLabel(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object or !isCapturedCommandCall(registry, call, parsed.value.object)) return null;
    const command = tool_args.optionalStringArg(parsed.value.object, "command") orelse return null;
    return if (try tool_dispatch.matchRunCommandCompatibility(registry, command)) |matched|
        matched.tool.completed_action_label
    else
        "Ran";
}

pub fn formatRunCommandActivity(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    call: ToolCall,
) !?RunCommandActivity {
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch return null;
    if (!isCapturedCommandCall(registry, call, args)) return null;
    const command = tool_args.optionalStringArg(args, "command") orelse return null;
    const detail = (try formatRunCommandDetailBounded(
        alloc,
        command,
        workspace_root,
        max_run_command_activity_bytes,
    )) orelse return null;
    return .{
        .detail = detail,
        .compatibility_tool = if (try tool_dispatch.matchRunCommandCompatibility(registry, command)) |matched| matched.tool else null,
    };
}

/// Formats a session launch command with the live terminal display target
/// projection's 120-byte budget, for replayed history where the live session
/// rows no longer exist. Returns null when `workspace_root` is empty and the
/// command contains an unresolved absolute path, matching the historical
/// command display guard; the caller falls back to the raw session id.
/// The caller owns the returned allocation.
pub fn formatHistoricalTerminalDisplayTarget(
    alloc: Allocator,
    command: []const u8,
    workspace_root: []const u8,
) !?[]u8 {
    return formatRunCommandDetailBounded(alloc, command, workspace_root, max_run_command_activity_bytes);
}

pub fn formatRunCommandDetailBounded(
    alloc: Allocator,
    command: []const u8,
    workspace_root: []const u8,
    max_encoded_bytes: usize,
) !?[]u8 {
    if (max_encoded_bytes == 0) return try alloc.dupe(u8, "");
    if (workspace_root.len == 0 and containsUnresolvedAbsolutePath(command)) return null;

    const effective_max = @min(max_encoded_bytes, max_run_command_activity_source_bytes - 1);
    const projected_storage = try alloc.alloc(u8, effective_max + 1);
    defer alloc.free(projected_storage);
    const projected = projectRunCommandActivitySource(command, workspace_root, projected_storage);
    const encoded = try text_utils.encodeTerminalSafe(alloc, projected, effective_max);
    return encoded.bytes;
}

fn terminalDisplayTargetSessionId(
    scratch: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) ?[]const u8 {
    const spec = registry.lookup(call.name) orelse return null;
    if (spec.executor_kind != .terminal) return null;
    const args = tool_args.parseToolArgsObject(
        scratch,
        call.arguments_json,
    ) catch return null;
    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    if (presentation.label_arg_kind != .session_id) return null;
    return tool_args.optionalStringArg(args, "session_id");
}

/// The caller owns the returned allocation and must free it with `alloc`.
fn resolveTerminalSessionTargetFromRows(
    alloc: Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    rows: []const terminal_ui_projection.Row,
    max_encoded_bytes: usize,
) ![]const u8 {
    for (rows) |row| {
        if (!std.mem.eql(u8, row.session_id, session_id)) continue;
        if (row.label.len == 0 or std.mem.eql(u8, row.label, session_id)) break;
        return try formatTerminalDisplayTarget(
            alloc,
            workspace_root,
            row.label,
            max_encoded_bytes,
        );
    }

    var encoded = try text_utils.encodeTerminalSafe(
        alloc,
        session_id,
        max_encoded_bytes -| "session ".len,
    );
    defer encoded.deinit(alloc);
    return try alloc.print("session {s}", .{encoded.bytes});
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn resolveTerminalDisplayTarget(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    terminal_client: ?*terminal_client_runtime.Runtime,
    managed_executions: ?*managed_execution.Runtime,
    call: ToolCall,
) !?[]const u8 {
    return resolveTerminalDisplayTargetBounded(
        alloc,
        registry,
        workspace_root,
        terminal_client,
        managed_executions,
        call,
        max_run_command_activity_bytes,
    );
}

/// Resolves the session launch command at a caller-chosen storage bound. The
/// status line keeps the compact activity bound; the transcript stores the
/// reflow-bound variant so group projection can reclip to the live width.
/// The caller owns the returned allocation and must free it with `alloc`.
pub fn resolveTerminalDisplayTargetBounded(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    terminal_client: ?*terminal_client_runtime.Runtime,
    managed_executions: ?*managed_execution.Runtime,
    call: ToolCall,
    max_encoded_bytes: usize,
) !?[]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer mem_utils.deinit_arena(scratch_state);
    const session_id = terminalDisplayTargetSessionId(
        scratch_state.allocator(),
        registry,
        call,
    ) orelse return null;
    if (managed_executions) |executions| {
        if (try executions.captured_command_alloc(alloc, session_id)) |command| {
            defer alloc.free(command);
            if (command.len != 0) return try formatTerminalDisplayTarget(alloc, workspace_root, command, max_encoded_bytes);
        }
    }
    const runtime = terminal_client orelse return @as(?[]const u8, try resolveTerminalSessionTargetFromRows(
        alloc,
        workspace_root,
        session_id,
        &.{},
        max_encoded_bytes,
    ));
    var snapshot = try runtime.terminalProjection(std.heap.c_allocator);
    defer snapshot.deinit();
    return @as(?[]const u8, try resolveTerminalSessionTargetFromRows(
        alloc,
        workspace_root,
        session_id,
        snapshot.rows,
        max_encoded_bytes,
    ));
}

/// Returns the completed-action label a terminal-session call (interact,
/// stop) will use on its settled status line, or null when the call does not
/// present a session target. Borrows registry storage; no free needed.
pub fn terminalSessionCompletedActionLabel(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) !?[]const u8 {
    const spec = registry.lookup(call.name) orelse return null;
    if (spec.executor_kind != .terminal) return null;
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const args = tool_args.parseToolArgsObject(scratch_state.allocator(), call.arguments_json) catch return null;
    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    if (presentation.label_arg_kind != .session_id) return null;
    return presentation.completed_action_label;
}

/// The caller owns the returned allocation and must free it with `alloc`.
fn formatTerminalDisplayTarget(
    alloc: Allocator,
    workspace_root: []const u8,
    raw: []const u8,
    max_encoded_bytes: usize,
) ![]u8 {
    if (max_encoded_bytes == 0) return try alloc.dupe(u8, "");
    const effective_max = @min(max_encoded_bytes, max_run_command_activity_source_bytes - 1);
    const projected_storage = try alloc.alloc(u8, effective_max + 1);
    defer alloc.free(projected_storage);
    const projected = projectRunCommandActivitySource(
        raw,
        workspace_root,
        projected_storage,
    );
    const encoded = try text_utils.encodeTerminalSafe(
        alloc,
        projected,
        effective_max,
    );
    return encoded.bytes;
}

/// Borrows the name from the prepared action without replacing resource labels.
pub fn resolvedSkillName(call: ToolCall, presentation: tool_dispatch.CallPresentation) ?[]const u8 {
    if (presentation.label_arg_kind != .name) return null;
    const selected = call.resolved_skill orelse return null;
    return selected.skill.name;
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatPlainAction(alloc: Allocator, input: ToolActionInput) ![]const u8 {
    const call = input.call;
    if (input.tool_registry.lookup(call.name) != null) {
        if (try formatSubagentPlainAction(alloc, call, .active)) |line| return line;
    }
    if (file_mutation_contract.isToolName(call.name)) {
        const spec = input.tool_registry.lookup(call.name) orelse
            return alloc.print("Working: {s}", .{call.name});
        return alloc.print(
            "{s} {s}",
            .{ spec.action_label, input.display_target orelse spec.label_arg_default },
        );
    }

    if (try formatRunCommandActivity(alloc, input.tool_registry, input.workspace_root, call)) |activity| {
        defer alloc.free(activity.detail);
        const action_label = if (activity.compatibility_tool) |tool| tool.action_label else "Running";
        return alloc.print("{s} {s}", .{ action_label, activity.detail });
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    const spec = input.tool_registry.lookup(call.name) orelse {
        if (isProviderSearchAlias(call.name)) {
            const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
                return alloc.print("Searching web", .{});
            };
            return alloc.print("Searching {s}", .{try formatWebSearchActionDetail(scratch, args)});
        }
        return alloc.print("Working: {s}", .{call.name});
    };
    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
        return alloc.print("Working: {s}", .{call.name});
    };

    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    if (spec.executor_kind == .web_search) {
        return alloc.print("{s} {s}", .{ presentation.action_label, try formatWebSearchActionDetail(scratch, args) });
    }
    const value = input.display_target orelse
        resolvedSkillName(call, presentation) orelse
        tool_dispatch.presentationLabelValue(presentation, args) orelse
        presentation.label_arg_default;
    return alloc.print("{s} {s}", .{ presentation.action_label, value });
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatPermissionLabel(alloc: Allocator, registry: tool_dispatch.Registry, call: ToolCall) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    if (try runCommandCompatibilitySource(scratch, registry, call)) |source| {
        return alloc.print("{s} {s}", .{ source.tool.name, source.command });
    }
    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
        return try alloc.dupe(u8, call.name);
    };
    if (isCapturedCommandCall(registry, call, args)) {
        const command = tool_args.optionalStringArg(args, "command") orelse
            return try alloc.dupe(u8, call.name);
        return formatRunCommandPermissionLabel(alloc, command);
    }
    const spec = registry.lookup(call.name) orelse return try alloc.dupe(u8, call.name);
    if (file_mutation_contract.isToolName(call.name)) {
        return alloc.print(
            "{s} {s}",
            .{ call.name, spec.label_arg_default },
        );
    }
    const value = tool_dispatch.toolLabelValue(spec.*, args) orelse return try alloc.dupe(u8, call.name);

    if (spec.label_arg_kind == .command) {
        const suffix = try commandApprovalLabelSuffix(scratch, call.name, value);
        if (tool_args.optionalStringArg(args, "cwd")) |cwd| {
            return alloc.print("{s} {s} @ {s}{s}", .{ call.name, value, cwd, suffix });
        }
        return alloc.print("{s} {s}{s}", .{ call.name, value, suffix });
    }

    return alloc.print("{s} {s}", .{ call.name, value });
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebSearchActionDetail(alloc: Allocator, args: std.json.ObjectMap) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var label_buf: [160]u8 = undefined;
    const query = tool_args.optionalStringArg(args, "query") orelse "web";
    try out.writer.writeAll(text_utils.clippedLabel(&label_buf, query, 120));
    try appendWebSearchDomains(&out.writer, "allowed", args.get("allowed_domains"));
    try appendWebSearchDomains(&out.writer, "blocked", args.get("blocked_domains"));
    return try out.toOwnedSlice();
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebSearchProgressPlain(alloc: Allocator, progress: types.WebSearchProgress) ![]u8 {
    var query_buf: [160]u8 = undefined;
    return switch (progress) {
        .query_started => |query| alloc.print(
            "Searching {s}",
            .{text_utils.clippedLabel(&query_buf, query, 120)},
        ),
        .results_received => |entry| alloc.print(
            "Found {d} result{s} for {s}",
            .{ entry.result_count, if (entry.result_count == 1) "" else "s", text_utils.clippedLabel(&query_buf, entry.query, 120) },
        ),
    };
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebFetchProgressPlain(alloc: Allocator, progress: types.WebFetchProgress) ![]u8 {
    var url_buf: [types.WebFetchCompletion.max_url_len]u8 = undefined;
    return switch (progress) {
        .fetching => |url| alloc.print("Fetching {s}", .{text_utils.clippedLabel(&url_buf, url, 96)}),
        .converting => |url| alloc.print("Converting {s}", .{text_utils.clippedLabel(&url_buf, url, 96)}),
    };
}

fn appendWebSearchDomains(writer: *std.Io.Writer, label: []const u8, value: ?std.json.Value) !void {
    const array = value orelse return;
    if (array != .array or array.array.items.len == 0) return;
    try writer.print(" | {s}: ", .{label});
    var domain_buf: [64]u8 = undefined;
    const shown = @min(array.array.items.len, 3);
    for (array.array.items[0..shown], 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");
        if (item != .string) {
            try writer.writeAll("?");
            continue;
        }
        try writer.writeAll(text_utils.clippedLabel(&domain_buf, item.string, 48));
    }
    if (array.array.items.len > shown) try writer.print(" +{d}", .{array.array.items.len - shown});
}

fn commandApprovalLabelSuffix(alloc: Allocator, tool_name: []const u8, command: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, tool_name, "run_command") and
        !std.mem.eql(u8, tool_name, "terminal") and
        !std.mem.eql(u8, tool_name, "shell")) return "";
    const risk = command_policy.command_risk_note_for(command);
    const safer = command_policy.command_safer_alternative_for(command);
    if (risk == null and safer == null) return "";
    const risk_text = if (risk) |note| stripNotePrefix(note) else null;
    if (risk_text) |note| {
        if (safer) |alternative| {
            return alloc.print(" (risk: {s}; {s})", .{ note, alternative });
        }
        return alloc.print(" (risk: {s})", .{note});
    }
    if (safer) |alternative| {
        return alloc.print(" ({s})", .{alternative});
    }
    return "";
}

fn stripNotePrefix(note: []const u8) []const u8 {
    const prefix = "note: ";
    if (std.mem.startsWith(u8, note, prefix)) return note[prefix.len..];
    return note;
}

const RunCommandCompatibilitySource = struct {
    tool: *const tool_dispatch.Tool,
    command: []const u8,
};

fn runCommandCompatibilitySource(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) !?RunCommandCompatibilitySource {
    const args = tool_args.parseToolArgsObject(alloc, call.arguments_json) catch return null;
    if (!isCapturedCommandCall(registry, call, args)) return null;
    const command = tool_args.optionalStringArg(args, "command") orelse return null;
    const matched = (try tool_dispatch.matchRunCommandCompatibility(registry, command)) orelse return null;
    return .{ .tool = matched.tool, .command = command };
}

fn isCapturedCommandCall(
    registry: tool_dispatch.Registry,
    call: ToolCall,
    args: std.json.ObjectMap,
) bool {
    // Historical sessions retain their original tool name. Presentation may
    // interpret those records, but execution remains unavailable because the
    // registry no longer contains a `run_command` tool.
    if (std.mem.eql(u8, call.name, "run_command")) return true;
    const tool = registry.lookup(call.name) orelse return false;
    if (tool.executor_kind == .run_command) return true;
    const expected = tool.captured_command_action orelse return false;
    const action = tool_args.optionalStringArg(args, "action") orelse return false;
    return std.mem.eql(u8, action, expected);
}

const std = @import("std");
const builtin_skills = @import("../../builtins/skills.zig");
const skill_invocation = @import("../../core/skills/skill_invocation.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const skill_contract = @import("../../core/skills/skill_contract.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const context_limits = @import("../../core/config/context_limits.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    name: ?[]u8 = null,
    location: ?[]u8 = null,
    resource: ?[]u8 = null,
    offset: usize = 0,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        if (self.name) |name| alloc.free(name);
        if (self.location) |location| alloc.free(location);
        if (self.resource) |resource| alloc.free(resource);
        self.* = .{};
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "skill arguments must be valid JSON") },
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill arguments must be an object") };
    }

    const name_value = parsed.value.object.get("name");
    if (name_value) |value| if (value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"name\" must be a string") };
    };
    const location_value = parsed.value.object.get("location");
    if (name_value == null and location_value == null) {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill requires an advertised location") };
    }
    if (location_value) |value| {
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"location\" must be a string") };
        }
    }
    const resource_value = parsed.value.object.get("resource");
    if (resource_value) |value| {
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"resource\" must be a string") };
        }
    }
    const offset_value = parsed.value.object.get("offset");
    if (name_value == null and offset_value != null) {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill offset requires the legacy named resource form") };
    }
    if (offset_value) |value| {
        if (value != .integer or value.integer < 0) {
            return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"offset\" must be a non-negative integer") };
        }
    }

    const name = if (name_value) |value| try ctx.allocator.dupe(u8, value.string) else null;
    errdefer if (name) |value| ctx.allocator.free(value);
    const location = if (location_value) |value| try ctx.allocator.dupe(u8, value.string) else null;
    errdefer if (location) |value| ctx.allocator.free(value);
    const resource = if (resource_value) |value| try ctx.allocator.dupe(u8, value.string) else null;
    errdefer if (resource) |value| ctx.allocator.free(value);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .name = name,
        .location = location,
        .resource = resource,
        .offset = if (offset_value) |value| std.math.cast(usize, value.integer) orelse return error.InvalidToolArguments else 0,
    };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const resource = skill_contract.resource_path_or_main(if (args.get("resource")) |value| resource: {
        if (value != .string) return null;
        break :resource value.string;
    } else null);
    const offset = if (args.get("offset")) |value| offset: {
        if (value != .integer or value.integer < 0) return null;
        break :offset std.math.cast(usize, value.integer) orelse return null;
    } else 0;
    if (offset == 0 and std.mem.eql(u8, resource, "SKILL.md")) return null;
    return .{
        .activity_kind = .read,
        .action_label = "Reading skill resource",
        .completed_action_label = "Read skill resource",
        .label_arg_kind = if (std.mem.eql(u8, resource, "SKILL.md")) .none else .resource,
        .label_arg_default = "SKILL.md",
    };
}

pub fn prepare(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!skill_contract.CallPreparation {
    const decoded = try decode(ctx, args_json);
    const input = switch (decoded) {
        .failure => |reason| return .{ .failure = .{ .model_output = reason } },
        .input => |value| value,
    };
    defer input.deinit(ctx.allocator);
    return prepareInput(ctx, input.as(Input)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return error.Cancelled,
        else => return .{ .failure = .{ .model_output = try ctx.allocator.print("skill failed: {s}. Refresh available skills and retry with an exact advertised location.", .{@errorName(err)}) } },
    };
}

fn prepareInput(ctx: tool_dispatch.DispatchContext, input: *const Input) !skill_contract.CallPreparation {
    if (ctx.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    const locations = if (ctx.skill_locations) |value| value.* else skill_contract.Locations{};
    const location = if (input.location) |value| try locations.resolve(ctx.allocator, value) else null;
    defer if (location) |value| ctx.allocator.free(value);
    if (location) |path| {
        for (locations.skills) |skill| {
            if (!std.mem.eql(u8, skill.path, path)) continue;
            return skill_invocation.prepareIdentity(ctx.allocator, .{ .skills = locations.skills, .diagnostics = locations.diagnostics }, input.name, path, ctx.max_tool_result_bytes);
        }
        if (std.mem.startsWith(u8, input.location.?, "skill:")) {
            return skill_invocation.prepareIdentity(ctx.allocator, .{ .skills = locations.skills, .diagnostics = locations.diagnostics }, input.name, path, ctx.max_tool_result_bytes);
        }
    }
    var discovery = try builtin_skills.loadVisibleSkillsForTool(ctx.allocator, ctx.workspace_root, ctx.skills_dir);
    defer discovery.deinit(ctx.allocator);
    skill_runtime.traceDiagnostics("skill_tool", discovery.diagnostics);
    return skill_invocation.prepareIdentity(ctx.allocator, .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics }, input.name, location, ctx.max_tool_result_bytes);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const result = loadInput(ctx, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return error.Cancelled,
        else => return .{ .failure = try ctx.allocator.print("skill failed: {s}", .{@errorName(err)}) },
    };
    errdefer skill_invocation.freeExecuteResult(ctx.allocator, result);
    if (result.contextNotice()) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
    if (result.diagnosticNotice()) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
    if (result == .loaded and result.loaded.complete) {
        if (ctx.model_content_kind_sink) |kind| kind.* = .complete_skill;
    }
    return switch (result) {
        .failure => .{ .failure = skill_invocation.takeModelOutput(ctx.allocator, result) },
        .loaded => .{ .success = skill_invocation.takeModelOutput(ctx.allocator, result) },
    };
}

fn loadInput(ctx: tool_dispatch.DispatchContext, input: *const Input) !skill_invocation.ExecuteResult {
    if (ctx.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    if (ctx.resolved_skill) |skill| return loadSelected(ctx, input, skill.*);
    const preparation = try prepareInput(ctx, input);
    return switch (preparation) {
        .failure => |output| .{ .failure = output },
        .selected => |skill| selected: {
            defer skill_invocation.freeCallPreparation(ctx.allocator, preparation);
            break :selected try loadSelected(ctx, input, skill);
        },
    };
}

fn loadSelected(ctx: tool_dispatch.DispatchContext, input: *const Input, prepared: skill_contract.PreparedSkill) !skill_invocation.ExecuteResult {
    const skill = prepared.skill;
    const catalog: skill_invocation.Catalog = .{ .skills = &.{skill}, .diagnostics = prepared.diagnostics };
    if (input.name != null) {
        return skill_invocation.loadByIdentity(ctx.allocator, catalog, skill.name, skill.path, input.resource, input.offset, ctx.context_limits, ctx.max_tool_result_bytes);
    }
    return skill_invocation.loadWholeByLocation(ctx.allocator, catalog, skill.path, input.resource, ctx.context_limits, ctx.max_tool_result_bytes, ctx.cancel_flag);
}

pub fn execute(arena: Allocator, workspace_root: []const u8, skills_dir: []const u8, args_json: []const u8) ![]u8 {
    const result = try executeForSession(arena, workspace_root, skills_dir, args_json);
    return skill_invocation.takeModelOutput(arena, result);
}

pub fn executeForSession(
    arena: Allocator,
    workspace_root: []const u8,
    skills_dir: []const u8,
    args_json: []const u8,
) !skill_invocation.ExecuteResult {
    const args = try tool_args.parseToolArgsObject(arena, args_json);
    const name = try tool_args.requiredStringArg(args, "name");
    const location = if (args.get("location")) |value| blk: {
        if (value != .string) return error.InvalidToolArguments;
        break :blk value.string;
    } else null;
    const resource = if (args.get("resource")) |value| blk: {
        if (value != .string) return error.InvalidToolArguments;
        break :blk value.string;
    } else null;
    const offset = if (args.get("offset")) |value| blk: {
        if (value != .integer or value.integer < 0) return error.InvalidToolArguments;
        break :blk std.math.cast(usize, value.integer) orelse return error.InvalidToolArguments;
    } else 0;
    return loadByIdentity(
        arena,
        workspace_root,
        skills_dir,
        name,
        location,
        resource,
        offset,
        .{},
        tool_result_limits.default_max_tool_result_bytes,
    );
}

fn loadByIdentity(
    alloc: Allocator,
    workspace_root: []const u8,
    skills_dir: []const u8,
    name: []const u8,
    location: ?[]const u8,
    resource: ?[]const u8,
    offset: usize,
    limits: context_limits.Values,
    max_tool_result_bytes: ?usize,
) !skill_invocation.ExecuteResult {
    var discovery = try builtin_skills.loadVisibleSkillsForTool(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    skill_runtime.traceDiagnostics("skill_tool", discovery.diagnostics);
    return skill_invocation.loadByIdentity(
        alloc,
        .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics },
        name,
        location,
        resource,
        offset,
        limits,
        max_tool_result_bytes,
    );
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

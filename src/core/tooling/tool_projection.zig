const std = @import("std");
const model_tool_schema = @import("model_tool_schema.zig");
const permissions = @import("../permissions/permissions.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_set_contract = @import("tool_set.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    permission_mode: types.PermissionMode = .auto,
    permission_rules: types.PermissionRuleSet = .{},
    subagent_available: bool = false,
};

const BuildKind = enum { full, read_only };

/// Owns the selected registry names and any separate guidance required by
/// included provider-executed tools. The caller must deinitialize the result
/// with the allocator passed to the builder.
pub const EffectiveToolProjection = struct {
    /// Borrowed registry names selected for model advertisement. The slice
    /// storage is owned by this projection.
    advertised_names: []const []const u8,
    /// Exact borrowed built-in schemas selected for model advertisement. The
    /// slice storage is owned by this projection.
    advertised_functions: []const model_tool_schema.FunctionSchema,
    custom_guidance: []u8,

    pub fn deinit(self: *EffectiveToolProjection, alloc: Allocator) void {
        alloc.free(self.advertised_names);
        alloc.free(self.advertised_functions);
        alloc.free(self.custom_guidance);
        self.* = undefined;
    }
};

pub fn containsName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
    return false;
}

pub fn buildModelToolProjectionForSet(alloc: Allocator, tool_set: tool_set_contract.ToolSet, options: Options) !EffectiveToolProjection {
    return buildToolProjection(alloc, tool_set, .full, options);
}

pub fn buildReadOnlyModelToolProjectionForSet(alloc: Allocator, tool_set: tool_set_contract.ToolSet, options: Options) !EffectiveToolProjection {
    return buildToolProjection(alloc, tool_set, .read_only, options);
}

fn buildToolProjection(alloc: Allocator, tool_set: tool_set_contract.ToolSet, kind: BuildKind, options: Options) !EffectiveToolProjection {
    var advertised_names: std.ArrayList([]const u8) = .empty;
    errdefer advertised_names.deinit(alloc);
    var advertised_functions: std.ArrayList(model_tool_schema.FunctionSchema) = .empty;
    errdefer advertised_functions.deinit(alloc);
    var guidance_out: std.Io.Writer.Allocating = .init(alloc);
    errdefer guidance_out.deinit();

    var first_custom_guidance = true;

    for (tool_set.order) |tool_name| {
        const tool = tool_set.registry.lookup(tool_name) orelse continue;
        try appendBuiltinTool(alloc, &advertised_names, &advertised_functions, &guidance_out.writer, &first_custom_guidance, tool.*, kind, tool_set, options);
    }

    if (kind == .full) {
        for (tool_set.registry.tools) |tool| {
            if (isCanonicalToolName(tool_set, tool.name)) continue;
            try appendBuiltinTool(alloc, &advertised_names, &advertised_functions, &guidance_out.writer, &first_custom_guidance, tool, kind, tool_set, options);
        }
    }

    const custom_guidance = try guidance_out.toOwnedSlice();
    errdefer alloc.free(custom_guidance);
    const names = try advertised_names.toOwnedSlice(alloc);
    errdefer alloc.free(names);
    const functions = try advertised_functions.toOwnedSlice(alloc);
    return .{
        .advertised_names = names,
        .advertised_functions = functions,
        .custom_guidance = custom_guidance,
    };
}
fn appendBuiltinTool(
    alloc: Allocator,
    advertised_names: *std.ArrayList([]const u8),
    advertised_functions: *std.ArrayList(model_tool_schema.FunctionSchema),
    guidance_writer: *std.Io.Writer,
    first_custom_guidance: *bool,
    tool: tool_dispatch.Tool,
    kind: BuildKind,
    tool_set: tool_set_contract.ToolSet,
    options: Options,
) !void {
    if (!tool.model_visible) return;
    if (!includeBuiltinForKind(tool.name, kind, tool_set)) return;
    if (std.mem.eql(u8, tool.name, "subagent") and !options.subagent_available) return;
    if (std.mem.eql(u8, tool.name, "vision")) return;
    if (options.permission_mode != .yolo) {
        if (tool.provider_executed and !providerExecutionIsAllowed(tool.name, options.permission_rules)) return;
        if (permissions.rulesDenyAllTargetsForTool(options.permission_rules, tool.name)) return;
    }
    try advertised_names.append(alloc, tool.name);
    if (!tool.provider_executed and tool.write_provider_advertisement_fn == null) {
        try advertised_functions.append(alloc, tool.model_schema);
    }
    if (tool.write_provider_advertisement_fn != null) {
        if (first_custom_guidance.*) {
            first_custom_guidance.* = false;
        } else {
            try guidance_writer.writeAll("\n\n");
        }
        try guidance_writer.writeAll(tool.description);
    }
}

/// A provider-executed tool is never dispatched locally, so an unsettled `ask`
/// hides it exactly like a `deny`. The tool name doubles as the target pattern
/// because the provider owns the call and fx never sees its arguments.
fn providerExecutionIsAllowed(tool_name: []const u8, rules: types.PermissionRuleSet) bool {
    const permission = permissions.permissionNameForTool(tool_name);
    return switch (permissions.ruleDecisionForPermissionPattern(rules, permission, tool_name, .none)) {
        .none, .allow => true,
        .ask, .deny => false,
    };
}

fn includeBuiltinForKind(tool_name: []const u8, kind: BuildKind, tool_set: tool_set_contract.ToolSet) bool {
    const names = builtinNamesForKind(kind, tool_set) orelse return true;
    return toolNameInSet(names, tool_name);
}

fn builtinNamesForKind(kind: BuildKind, tool_set: tool_set_contract.ToolSet) ?[]const []const u8 {
    return switch (kind) {
        .full => null,
        .read_only => tool_set.read_only_tool_names,
    };
}

fn toolNameInSet(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn isCanonicalToolName(tool_set: tool_set_contract.ToolSet, name: []const u8) bool {
    for (tool_set.order) |tool_name| {
        if (std.mem.eql(u8, tool_name, name)) return true;
    }
    return false;
}

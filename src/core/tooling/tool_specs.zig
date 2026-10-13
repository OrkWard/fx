const std = @import("std");
const tool_dispatch = @import("tool_dispatch.zig");

// Generic aliases and helpers shared by registered tool specifications.

pub const ExecutorKind = tool_dispatch.ExecutorKind;
pub const PermissionTargetKind = tool_dispatch.PermissionTargetKind;
pub const ToolSpec = tool_dispatch.Tool;

pub fn toolLabelValue(spec: ToolSpec, args: std.json.ObjectMap) ?[]const u8 {
    return tool_dispatch.toolLabelValue(spec, args);
}

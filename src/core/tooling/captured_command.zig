const std = @import("std");

const Allocator = std.mem.Allocator;

/// Classifies command-shaped tool calls that use captured execution rather
/// than a durable terminal session. Historical `run_command` records remain
/// presentation-compatible even though that tool is no longer executable.
pub fn isToolCall(
    alloc: Allocator,
    tool_name: []const u8,
    arguments_json: []const u8,
) Allocator.Error!bool {
    if (std.mem.eql(u8, tool_name, "run_command")) return true;
    const legacy_terminal = std.mem.eql(u8, tool_name, "terminal");
    const shell = std.mem.eql(u8, tool_name, "shell");
    if (!legacy_terminal and !shell) return false;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const action = parsed.value.object.get("action") orelse return false;
    if (action != .string) return false;
    if (legacy_terminal) return std.mem.eql(u8, action.string, "exec");
    if (!std.mem.eql(u8, action.string, "run")) return false;
    const tty = parsed.value.object.get("tty") orelse return true;
    return tty == .null or (tty == .bool and !tty.bool);
}

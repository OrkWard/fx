const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const command_contract = @import("../execution/command_contract.zig");
const io_mod = @import("../shared/io.zig");
const tool_contracts = @import("../agent/runtime/tool_contracts.zig");
const tool_result_errors = @import("tool_result_errors.zig");

const Allocator = std.mem.Allocator;
const ToolExecutionResult = tool_contracts.ToolExecutionResult;

pub const Command = struct {
    pub fn cancelledFailure(
        arena: Allocator,
        result: command_contract.RunCommandResult,
    ) !?ToolExecutionResult {
        if (!result.cancelled) return null;
        const command_result_json: ?[]const u8 = if (result.command_result) |command_result|
            command_result.toJson(arena) catch |err| blk: {
                debug_trace.logf("tool", "cancelled command result metadata omitted err={s}", .{@errorName(err)});
                break :blk null;
            }
        else
            null;
        return .{
            .status = .failure,
            .cancelled = true,
            .model_output = "command cancelled\n",
            .command_result_json = command_result_json,
        };
    }

    pub fn nonZeroFailure(
        arena: Allocator,
        result: command_contract.RunCommandResult,
    ) !?ToolExecutionResult {
        const command_result = result.command_result orelse return null;
        const command = command_result;
        if (command.termination_indeterminate) {
            const details = [_]tool_result_errors.Detail{
                .{ .name = "command", .value = .{ .string = command.command } },
                .{ .name = "cwd", .value = .{ .string = command.cwd } },
                .{ .name = "termination_indeterminate", .value = .{ .boolean = true } },
            };
            return .{
                .status = .failure,
                .model_output = try tool_result_errors.toolExecutionFailureJson(arena, .{
                    .tool_name = "shell",
                    .message = "Command started, but its final process status could not be confirmed",
                    .details = &details,
                    .suggestion = "Do not retry the command unchanged because its side effects may already exist. Inspect the resulting state first.",
                }),
                .command_result_json = try command_result.toJson(arena),
            };
        }
        if ((command.exit_code == null or command.exit_code.? == 0) and
            command.signal == null and
            !command.timed_out) return null;

        var details: [6]tool_result_errors.Detail = undefined;
        var count: usize = 0;
        details[count] = .{ .name = "command", .value = .{ .string = command.command } };
        count += 1;
        details[count] = .{ .name = "cwd", .value = .{ .string = command.cwd } };
        count += 1;
        if (command.exit_code) |code| {
            details[count] = .{ .name = "exit_code", .value = .{ .integer = code } };
            count += 1;
        }
        if (command.signal) |signal| {
            details[count] = .{ .name = "signal", .value = .{ .unsigned = signal } };
            count += 1;
        }
        const stderr_text = extractEnvelope(result.output, "<stderr>\n", "\n</stderr>");
        if (stderr_text.len > 0) {
            details[count] = .{ .name = "stderr", .value = .{ .string = stderr_text } };
            count += 1;
        }

        return .{
            .status = .failure,
            .model_output = try tool_result_errors.toolExecutionFailureJson(arena, .{
                .tool_name = "shell",
                .message = if (command.exit_code != null) "Command exited with non-zero status" else "Command terminated before completing successfully",
                .details = details[0..count],
                .suggestion = "Inspect stderr and the command context, then fix the command or explain the blocker rather than retrying unchanged.",
            }),
            .command_result_json = try command_result.toJson(arena),
        };
    }

    pub fn timeoutFailure(
        arena: Allocator,
        command: []const u8,
        cwd: []const u8,
        timeout_ms: ?usize,
        started_ms: ?i64,
    ) !ToolExecutionResult {
        const cleanup =
            "cleanup_scope=process_group_and_tracked_descendants\n" ++
            "cleanup_guarantee=best_effort\n" ++
            "message=command timed out; cleanup was attempted for the process group and tracked descendants, but fully detached descendants may remain\n";
        const output = if (timeout_ms) |ms|
            try arena.print(
                "timeout=true\ntimeout_ms={d}\n" ++ cleanup,
                .{ms},
            )
        else
            try arena.dupe(u8, "timeout=true\n" ++ cleanup);
        return .{
            .status = .failure,
            .model_output = output,
            .command_result_json = try (command_contract.CommandResult{
                .command = command,
                .cwd = cwd,
                .timed_out = true,
                .duration_ms = if (started_ms) |started| elapsedMs(started, io_mod.milliTimestamp()) else null,
            }).toJson(arena),
            .tool_result_memory = .{
                .command_process_presentation = .timed_out,
            },
        };
    }

    pub fn outputCaptureFailure(arena: Allocator) !ToolExecutionResult {
        const details = [_]tool_result_errors.Detail{
            .{ .name = "output_capture_failed", .value = .{ .boolean = true } },
        };
        return .{
            .status = .failure,
            .model_output = try tool_result_errors.toolExecutionFailureJson(arena, .{
                .tool_name = "shell",
                .message = "Command output could not be retained",
                .details = &details,
                .suggestion = "Do not retry unchanged. Inspect available command evidence, free storage if needed, or explain that complete output capture failed.",
            }),
            .tool_result_memory = .{
                .command_process_presentation = .output_capture_failed,
            },
        };
    }
};

fn extractEnvelope(output: []const u8, open: []const u8, close: []const u8) []const u8 {
    const start = std.mem.find(u8, output, open) orelse return "";
    const body = output[start + open.len ..];
    const end = std.mem.find(u8, body, close) orelse return "";
    return body[0..end];
}

fn elapsedMs(started_ms: i64, finished_ms: i64) u64 {
    return if (finished_ms > started_ms) @intCast(finished_ms - started_ms) else 0;
}

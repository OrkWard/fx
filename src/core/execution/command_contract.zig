const std = @import("std");
const command_output_content = @import("../tooling/command_output_content.zig");

pub const CommandOutputStream = command_output_content.Stream;
pub const CommandOutputCallback = command_output_content.Callback;

pub const CommandResult = struct {
    command: []const u8,
    cwd: []const u8,
    exit_code: ?i64 = null,
    signal: ?u32 = null,
    timed_out: bool = false,
    termination_indeterminate: bool = false,
    output_incomplete: bool = false,
    duration_ms: ?u64 = null,
    stdout_bytes: usize = 0,
    stderr_bytes: usize = 0,
    truncated: bool = false,
    output_file: ?[]const u8 = null,
    stdout_file: ?[]const u8 = null,
    stderr_file: ?[]const u8 = null,

    pub fn writeJson(self: CommandResult, writer: *std.Io.Writer) !void {
        try writeCommandJson(self, writer);
    }

    pub fn toJson(self: CommandResult, alloc: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }
};

pub const RunCommandResult = struct {
    output: []const u8,
    command_result: ?CommandResult = null,
    cancelled: bool = false,
};

pub const CommandStatus = union(enum) {
    exit_code: i64,
    signal: u32,
    finished,
    indeterminate,
};

pub const CommandResultSnapshot = struct {
    command: []const u8,
    cwd: []const u8,
    status: CommandStatus,
    stdout_display: []const u8,
    stderr_display: []const u8,
    stdout_bytes: usize,
    stderr_bytes: usize,
    output_incomplete: bool = false,
    duration_ms: ?u64 = null,
};

pub const StatusProjection = struct {
    exit_code: ?i64,
    signal: ?u32,
    termination_indeterminate: bool,
};

pub fn formatCommandResult(
    alloc: std.mem.Allocator,
    snapshot: CommandResultSnapshot,
) !RunCommandResult {
    const stdout_text = std.mem.trim(u8, snapshot.stdout_display, " \r\n\t");
    const stderr_text = std.mem.trim(u8, snapshot.stderr_display, " \r\n\t");

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeStatusLine(&out.writer, snapshot.status);
    try writeOutputEnvelopes(&out.writer, stdout_text, stderr_text);
    const status = projectStatus(snapshot.status);

    return .{
        .output = try out.toOwnedSlice(),
        .command_result = .{
            .command = snapshot.command,
            .cwd = snapshot.cwd,
            .exit_code = status.exit_code,
            .signal = status.signal,
            .termination_indeterminate = status.termination_indeterminate,
            .output_incomplete = snapshot.output_incomplete,
            .duration_ms = snapshot.duration_ms,
            .stdout_bytes = snapshot.stdout_bytes,
            .stderr_bytes = snapshot.stderr_bytes,
        },
    };
}

pub fn writeStatusLine(writer: *std.Io.Writer, status: CommandStatus) !void {
    switch (status) {
        .exit_code => |code| try writer.print("exit_code={d}\n", .{code}),
        .signal => |signal| try writer.print("signal={d}\n", .{signal}),
        .finished => try writer.writeAll("process finished\n"),
        .indeterminate => try writer.writeAll(
            "termination_indeterminate=true\n" ++
                "message=the command was started, but fx could not confirm its final process status; do not retry unchanged because side effects may already exist\n",
        ),
    }
}

fn writeOutputEnvelopes(writer: *std.Io.Writer, stdout_text: []const u8, stderr_text: []const u8) !void {
    if (stdout_text.len > 0) {
        try writer.writeAll("<stdout>\n");
        try writer.writeAll(stdout_text);
        try writer.writeAll("\n</stdout>\n");
    }
    if (stderr_text.len > 0) {
        try writer.writeAll("<stderr>\n");
        try writer.writeAll(stderr_text);
        try writer.writeAll("\n</stderr>\n");
    }
    if (stdout_text.len == 0 and stderr_text.len == 0) {
        try writer.writeAll("(no output)\n");
    }
}

pub fn projectStatus(
    status: CommandStatus,
) StatusProjection {
    return switch (status) {
        .exit_code => |code| .{
            .exit_code = code,
            .signal = null,
            .termination_indeterminate = false,
        },
        .signal => |signal| .{
            .exit_code = null,
            .signal = signal,
            .termination_indeterminate = false,
        },
        .finished => .{
            .exit_code = null,
            .signal = null,
            .termination_indeterminate = false,
        },
        .indeterminate => .{
            .exit_code = null,
            .signal = null,
            .termination_indeterminate = true,
        },
    };
}

fn writeCommandJson(result: CommandResult, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"kind\":\"command\"");
    try writeStringField(writer, "command", result.command);
    try writeStringField(writer, "cwd", result.cwd);
    try writeOptionalIntField(writer, "exit_code", result.exit_code);
    try writeOptionalIntField(writer, "signal", result.signal);
    try writeBoolField(writer, "timed_out", result.timed_out);
    if (result.termination_indeterminate) {
        try writeBoolField(writer, "termination_indeterminate", true);
    }
    if (result.output_incomplete) {
        try writeBoolField(writer, "output_incomplete", true);
    }
    try writeOptionalIntField(writer, "duration_ms", result.duration_ms);
    try writeIntField(writer, "stdout_bytes", result.stdout_bytes);
    try writeIntField(writer, "stderr_bytes", result.stderr_bytes);
    try writeBoolField(writer, "truncated", result.truncated);
    try writeOptionalStringField(writer, "output_file", result.output_file);
    try writeOptionalStringField(writer, "stdout_file", result.stdout_file);
    try writeOptionalStringField(writer, "stderr_file", result.stderr_file);
    try writer.writeByte('}');
}

fn writeStringField(writer: *std.Io.Writer, comptime name: []const u8, value: []const u8) !void {
    try writer.writeAll(",\"" ++ name ++ "\":");
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeOptionalStringField(writer: *std.Io.Writer, comptime name: []const u8, value: ?[]const u8) !void {
    try writer.writeAll(",\"" ++ name ++ "\":");
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

fn writeBoolField(writer: *std.Io.Writer, comptime name: []const u8, value: bool) !void {
    try writer.writeAll(",\"" ++ name ++ "\":");
    try writer.writeAll(if (value) "true" else "false");
}

fn writeIntField(writer: *std.Io.Writer, comptime name: []const u8, value: anytype) !void {
    try writer.writeAll(",\"" ++ name ++ "\":");
    try writer.print("{d}", .{value});
}

fn writeOptionalIntField(writer: *std.Io.Writer, comptime name: []const u8, value: anytype) !void {
    try writer.writeAll(",\"" ++ name ++ "\":");
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

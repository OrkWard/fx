const std = @import("std");
const mem_utils = @import("../shared/mem_utils.zig");
const types = @import("../shared/types.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");

const Allocator = std.mem.Allocator;
const legacy_schema_v1: i64 = 1;
const legacy_schema_v2: i64 = 2;

pub const LegacySchemaVersion = enum(u8) {
    v1 = 1,
    v2 = 2,
};

/// Renders one session record as JSON; caller owns the returned slice and frees with allocator.free.
pub const SessionTokenUsage = struct {
    input: u64 = 0,
    output: u64 = 0,
    web_search_requests: u64 = 0,
};

pub noinline fn renderSessionJson(
    alloc: Allocator,
    active_id: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    language: session.ConversationLanguage,
    workspace_root: []const u8,
    history: []const session.HistoryTurn,
    token_usage: SessionTokenUsage,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"schema_version\":1,\"id\":");
    try std.json.Stringify.value(active_id, .{}, &out.writer);
    try out.writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{ created_at_ms, updated_at_ms });
    try out.writer.writeAll(",\"workspace_root\":");
    try std.json.Stringify.value(workspace_root, .{}, &out.writer);
    try out.writer.writeAll(",\"conversation_language\":");
    try std.json.Stringify.value(language.view(), .{}, &out.writer);
    if (token_usage.input > 0 or token_usage.output > 0) {
        try out.writer.print(",\"total_input_tokens\":{d},\"total_output_tokens\":{d}", .{ token_usage.input, token_usage.output });
    }
    if (token_usage.web_search_requests > 0) {
        try out.writer.print(",\"total_web_search_requests\":{d}", .{token_usage.web_search_requests});
    }
    try out.writer.print(",\"history_len\":{d},\"history\":[", .{history.len});

    for (history, 0..) |turn, i| {
        if (i > 0) try out.writer.writeByte(',');
        try writeHistoryTurnJson(&out.writer, turn);
    }

    try out.writer.writeAll("]}");
    return try out.toOwnedSlice();
}

fn writeHistoryTurnJson(writer: *std.Io.Writer, turn: session.HistoryTurn) !void {
    switch (turn) {
        .compacted_summary => |entry| {
            try writer.writeAll("{\"kind\":\"compacted_summary\",\"summary\":");
            try std.json.Stringify.value(entry.summary, .{}, writer);
            try writer.print(",\"removed_turn_count\":{d},\"compaction_count\":{d}", .{ entry.removed_turn_count, entry.compaction_count });
            try writer.writeByte('}');
        },
        .assistant => |entry| {
            try writer.writeAll("{\"kind\":\"assistant\",\"user\":");
            try writeUserTurnJson(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            try std.json.Stringify.value(entry.assistant, .{}, writer);
            if (!entry.execution.isEmpty()) {
                try writer.writeAll(",\"execution\":");
                try writeExecutionMemoryJson(writer, entry.execution);
            }
            try writer.writeByte('}');
        },
        .interrupted => |entry| {
            try writer.writeAll("{\"kind\":\"interrupted\",\"user\":");
            try writeUserTurnJson(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            if (entry.assistant) |assistant| {
                try std.json.Stringify.value(assistant, .{}, writer);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"tool_call\":");
            if (entry.tool_call) |tool_call| {
                try writeToolCallJson(writer, tool_call);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"completed_tool_names\":");
            try writeStringArrayJson(writer, entry.completed_tool_names);
            try writer.writeAll(",\"terminal_reason\":");
            try std.json.Stringify.value(@tagName(entry.terminal_reason), .{}, writer);
            if (entry.cancellation_origin == .compaction) {
                try writer.writeAll(",\"cancellation_origin\":\"compaction\"");
            }
            if (!entry.execution.isEmpty()) {
                try writer.writeAll(",\"execution\":");
                try writeExecutionMemoryJson(writer, entry.execution);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeToolCallJson(writer: *std.Io.Writer, tool_call: session.ToolCall) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(tool_call.id, .{}, writer);
    try writer.writeAll(",\"name\":");
    try std.json.Stringify.value(tool_call.name, .{}, writer);
    try writer.writeAll(",\"arguments_json\":");
    try std.json.Stringify.value(tool_call.arguments_json, .{}, writer);
    try writer.writeAll(",\"provider_result\":");
    if (tool_call.provider_result) |provider_result| {
        try std.json.Stringify.value(provider_result, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

pub fn writeExecutionMemoryJson(writer: *std.Io.Writer, execution: session.ExecutionMemory) !void {
    try session_codec.writeExecutionMemoryJson(writer, execution, .presentation);
}

fn writeUserTurnJson(writer: *std.Io.Writer, user: session.UserTurn) !void {
    try writer.writeAll("{\"text\":");
    try std.json.Stringify.value(user.text, .{}, writer);
    try writer.writeAll(",\"images\":[");
    for (user.images, 0..) |image, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try std.json.Stringify.value(image.path, .{}, writer);
        try writer.writeAll(",\"media_type\":");
        try std.json.Stringify.value(image.media_type, .{}, writer);
        try writer.writeAll(",\"snapshot_path\":");
        try writeImageSnapshotLocatorJson(writer, image.snapshot_path);
        try writer.writeAll(",\"snapshot_sha256\":");
        try std.json.Stringify.value(image.snapshot_sha256, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn writeImageSnapshotLocatorJson(writer: *std.Io.Writer, value: ?[]const u8) !void {
    const path = value orelse {
        try writer.writeAll("null");
        return;
    };
    var locator_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const locator = try session.projectSnapshotLocator(&locator_buffer, path);
    try std.json.Stringify.value(locator, .{}, writer);
}

fn writeStringArrayJson(writer: *std.Io.Writer, items: anytype) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try std.json.Stringify.value(item, .{}, writer);
    }
    try writer.writeByte(']');
}

/// Parses a session summary; caller owns returned fields and frees with SessionSummary.deinit.
pub fn parseSessionSummary(comptime SessionSummary: type, alloc: Allocator, json_text: []const u8) !SessionSummary {
    var source = std.Io.Reader.fixed(json_text);
    return parseLegacySummaryStreaming(SessionSummary, alloc, &source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedSessionSchema => return error.UnsupportedSessionSchema,
        else => return error.InvalidSessionFormat,
    };
}

pub fn parseLegacySummaryStreaming(
    comptime LegacySummary: type,
    alloc: Allocator,
    source: *std.Io.Reader,
) !LegacySummary {
    return parseLegacySummaryStreamingImpl(LegacySummary, alloc, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => return error.ReadFailed,
        error.UnsupportedSessionSchema => return error.UnsupportedSessionSchema,
        else => return error.InvalidSessionFormat,
    };
}

fn parseLegacySummaryStreamingImpl(
    comptime LegacySummary: type,
    alloc: Allocator,
    source: *std.Io.Reader,
) !LegacySummary {
    var reader = std.json.Reader.init(alloc, source);
    defer reader.deinit();
    try expectToken(try reader.next(), .object_begin);

    var schema_version: ?i64 = null;
    var id: ?[]u8 = null;
    errdefer if (id) |owned| mem_utils.free(alloc, owned);
    var workspace_root: ?[]u8 = null;
    errdefer if (workspace_root) |owned| mem_utils.free(alloc, owned);
    var workspace_root_seen = false;
    var created_at_ms: ?i64 = null;
    var updated_at_ms: ?i64 = null;
    var conversation_language: ?session.ConversationLanguage = null;
    var history_len: ?usize = null;

    while (true) {
        const token = try reader.nextAllocMax(alloc, .alloc_if_needed, 64);
        defer freeToken(alloc, token);
        if (token == .object_end) break;
        const key = switch (token) {
            .string => |value| value,
            .allocated_string => |value| value,
            else => return error.InvalidSessionFormat,
        };

        if (std.mem.eql(u8, key, "history")) {
            if (summaryComplete(
                schema_version,
                id,
                created_at_ms,
                updated_at_ms,
                conversation_language,
                history_len,
            )) {
                try requireLegacySchema(schema_version.?);
                var result: LegacySummary = .{
                    .id = id.?,
                    .workspace_root = workspace_root,
                    .created_at_ms = created_at_ms.?,
                    .updated_at_ms = updated_at_ms.?,
                    .conversation_language = conversation_language.?,
                    .history_len = history_len.?,
                };
                if (@hasField(LegacySummary, "schema_version")) {
                    @field(result, "schema_version") = try legacySchemaVersion(schema_version.?);
                }
                return result;
            }
            try reader.skipValue();
            continue;
        }
        if (std.mem.eql(u8, key, "schema_version")) {
            if (schema_version != null) return error.InvalidSessionFormat;
            schema_version = try readI64Token(&reader, alloc);
        } else if (std.mem.eql(u8, key, "id")) {
            if (id != null) return error.InvalidSessionFormat;
            id = try readStringOwned(&reader, alloc, 255);
        } else if (std.mem.eql(u8, key, "workspace_root")) {
            if (workspace_root_seen) return error.InvalidSessionFormat;
            workspace_root_seen = true;
            workspace_root = try readOptionalStringOwned(
                &reader,
                alloc,
                std.Io.Dir.max_path_bytes,
            );
        } else if (std.mem.eql(u8, key, "created_at_ms")) {
            if (created_at_ms != null) return error.InvalidSessionFormat;
            created_at_ms = try readI64Token(&reader, alloc);
        } else if (std.mem.eql(u8, key, "updated_at_ms")) {
            if (updated_at_ms != null) return error.InvalidSessionFormat;
            updated_at_ms = try readI64Token(&reader, alloc);
        } else if (std.mem.eql(u8, key, "conversation_language")) {
            if (conversation_language != null) return error.InvalidSessionFormat;
            const raw = try readStringOwned(
                &reader,
                alloc,
                session.ConversationLanguage.max_len,
            );
            defer alloc.free(raw);
            conversation_language = try parseConversationLanguage(raw);
        } else if (std.mem.eql(u8, key, "history_len")) {
            if (history_len != null) return error.InvalidSessionFormat;
            const value = try readU64Token(&reader, alloc);
            if (value > std.math.maxInt(usize)) return error.InvalidSessionFormat;
            history_len = @intCast(value);
        } else {
            try reader.skipValue();
        }
    }

    if (!summaryComplete(
        schema_version,
        id,
        created_at_ms,
        updated_at_ms,
        conversation_language,
        history_len,
    )) return error.InvalidSessionFormat;
    try requireLegacySchema(schema_version.?);
    try expectToken(try reader.next(), .end_of_document);
    var result: LegacySummary = .{
        .id = id.?,
        .workspace_root = workspace_root,
        .created_at_ms = created_at_ms.?,
        .updated_at_ms = updated_at_ms.?,
        .conversation_language = conversation_language.?,
        .history_len = history_len.?,
    };
    if (@hasField(LegacySummary, "schema_version")) {
        @field(result, "schema_version") = try legacySchemaVersion(schema_version.?);
    }
    return result;
}

/// Parses a full stored session; caller owns returned fields and frees with StoredSession.deinit.
pub noinline fn parseStoredSession(comptime StoredSession: type, alloc: Allocator, json_text: []const u8) !StoredSession {
    return parseLegacyExact(StoredSession, alloc, json_text);
}

pub fn parseLegacyExact(
    comptime LegacySession: type,
    alloc: Allocator,
    json_text: []const u8,
) !LegacySession {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();

    const root = try requireObject(parsed.value);
    try requireSchemaVersion(root);

    const history_value = root.get("history") orelse return error.InvalidSessionFormat;
    if (history_value != .array) return error.InvalidSessionFormat;

    const history: []session.HistoryTurn = if (history_value.array.items.len > 0)
        try alloc.alloc(session.HistoryTurn, history_value.array.items.len)
    else
        &.{};
    errdefer if (history.len > 0) mem_utils.free(alloc, history);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) session.freeHistoryTurn(alloc, history[i]);
    }
    for (history_value.array.items, 0..) |entry, i| {
        history[i] = try parseLegacyHistoryTurn(alloc, entry);
        parsed_count += 1;
    }

    if (try requireUsize(root, "history_len") != history.len) return error.InvalidSessionFormat;
    const id = try alloc.dupe(u8, try requireString(root, "id"));
    errdefer mem_utils.free(alloc, id);
    const workspace_root = try optionalStringDup(alloc, root.get("workspace_root"));
    errdefer if (workspace_root) |wr| mem_utils.free(alloc, wr);
    const language = try parseConversationLanguage(try requireString(root, "conversation_language"));

    const total_input_tokens: u64 = if (root.get("total_input_tokens")) |v| blk: {
        if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
        break :blk 0;
    } else 0;
    const total_output_tokens: u64 = if (root.get("total_output_tokens")) |v| blk: {
        if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
        break :blk 0;
    } else 0;
    const total_web_search_requests: u64 = if (root.get("total_web_search_requests")) |v| blk: {
        if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
        break :blk 0;
    } else 0;

    return .{
        .id = id,
        .workspace_root = workspace_root,
        .created_at_ms = try requireI64(root, "created_at_ms"),
        .updated_at_ms = try requireI64(root, "updated_at_ms"),
        .conversation_language = language,
        .history = history,
        .total_input_tokens = total_input_tokens,
        .total_output_tokens = total_output_tokens,
        .total_web_search_requests = total_web_search_requests,
    };
}

pub fn parseLegacySchemaVersion(
    alloc: Allocator,
    json_text: []const u8,
) !LegacySchemaVersion {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        json_text,
        .{},
    ) catch return error.InvalidSessionFormat;
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    return legacySchemaVersion(try requireI64(root, "schema_version"));
}

fn formatLegacyBackgroundAssistant(
    alloc: Allocator,
    assistant: ?[]const u8,
    log_path: []const u8,
    url: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    if (assistant) |text| {
        if (text.len != 0) {
            try out.writer.writeAll(text);
            if (!std.mem.endsWith(u8, text, "\n")) try out.writer.writeByte('\n');
        }
    }
    try out.writer.writeAll(
        "[Historical command record: fx no longer owns or controls this process",
    );
    if (log_path.len != 0) try out.writer.print("; former log={s}", .{log_path});
    if (url) |value| try out.writer.print("; recorded url={s}", .{value});
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn parseLegacyHistoryTurn(alloc: Allocator, value: std.json.Value) !session.HistoryTurn {
    const object = try requireObject(value);
    const kind = try requireString(object, "kind");

    if (std.mem.eql(u8, kind, "compacted_summary")) {
        const root_user_messages: [][]u8 = if (object.get("root_user_messages")) |messages_value| blk: {
            if (messages_value != .array) return error.InvalidSessionFormat;
            const messages = try alloc.alloc([]u8, messages_value.array.items.len);
            errdefer mem_utils.free(alloc, messages);
            var copied: usize = 0;
            errdefer for (messages[0..copied]) |message| mem_utils.free(alloc, message);
            for (messages_value.array.items, 0..) |item, index| {
                if (item != .string) return error.InvalidSessionFormat;
                messages[index] = try alloc.dupe(u8, item.string);
                copied += 1;
            }
            break :blk messages;
        } else &.{};
        errdefer session.freeCompletedToolNames(alloc, root_user_messages);
        const permission_feedback = try parseOptionalStringArray(
            alloc,
            object.get("permission_feedback"),
        );
        errdefer types.freePermissionFeedback(alloc, permission_feedback);
        const removed_turn_count = try requireUsize(object, "removed_turn_count");
        return .{ .compacted_summary = .{
            .summary = try alloc.dupe(u8, try requireString(object, "summary")),
            .removed_turn_count = removed_turn_count,
            .compaction_count = try requireUsize(object, "compaction_count"),
            .root_user_messages = root_user_messages,
            .root_user_messages_complete = if (object.get("root_user_messages_complete") != null)
                try requireBool(object, "root_user_messages_complete")
            else
                object.get("root_user_messages") != null or removed_turn_count == 0,
            .permission_feedback = permission_feedback,
            .permission_feedback_complete = if (object.get("permission_feedback_complete") != null)
                try requireBool(object, "permission_feedback_complete")
            else
                removed_turn_count == 0,
        } };
    }
    if (std.mem.eql(u8, kind, "assistant")) {
        const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
        errdefer session.freeUserTurn(alloc, user);
        const assistant = try alloc.dupe(u8, try requireString(object, "assistant"));
        errdefer mem_utils.free(alloc, assistant);
        const execution = try parseOptionalExecutionMemory(alloc, object.get("execution"));
        errdefer session.freeExecutionMemory(alloc, execution);
        return .{ .assistant = .{
            .user = user,
            .assistant = assistant,
            .execution = execution,
        } };
    }
    if (std.mem.eql(u8, kind, "background_command")) {
        const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
        errdefer session.freeUserTurn(alloc, user);
        const legacy_assistant = try optionalStringDup(alloc, object.get("assistant"));
        defer if (legacy_assistant) |text| alloc.free(text);
        const execution = try parseOptionalExecutionMemory(alloc, object.get("execution"));
        errdefer session.freeExecutionMemory(alloc, execution);
        const log_path = try alloc.dupe(u8, try requireString(object, "log_path"));
        defer alloc.free(log_path);
        const url = try optionalStringDup(alloc, object.get("url"));
        defer if (url) |value_copy| alloc.free(value_copy);
        _ = try requireBool(object, "expect_url");
        _ = try parseOptionalBackgroundRecordId(
            object.get("background_record_id"),
        );
        const assistant = try formatLegacyBackgroundAssistant(
            alloc,
            legacy_assistant,
            log_path,
            url,
        );
        return .{ .assistant = .{
            .user = user,
            .assistant = assistant,
            .execution = execution,
        } };
    }
    if (std.mem.eql(u8, kind, "interrupted")) {
        const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
        errdefer session.freeUserTurn(alloc, user);
        const assistant = try optionalStringDup(alloc, object.get("assistant"));
        errdefer if (assistant) |text| mem_utils.free(alloc, text);
        const tool_call = try parseOptionalToolCall(alloc, object.get("tool_call"));
        errdefer if (tool_call) |call| session.freeToolCall(alloc, call);
        const completed_tool_names = try parseOptionalStringArray(alloc, object.get("completed_tool_names"));
        errdefer session.freeCompletedToolNames(alloc, completed_tool_names);
        const terminal_reason = try parseLegacyInterruptedTerminalReason(object.get("terminal_reason"));
        const cancellation_origin: types.CancellationOrigin = if (object.get("cancellation_origin")) |origin| blk: {
            if (origin != .string) return error.InvalidSessionFormat;
            break :blk std.meta.stringToEnum(types.CancellationOrigin, origin.string) orelse
                return error.InvalidSessionFormat;
        } else .turn;
        const execution = try parseOptionalExecutionMemory(alloc, object.get("execution"));
        return .{ .interrupted = .{
            .user = user,
            .assistant = assistant,
            .tool_call = tool_call,
            .completed_tool_names = completed_tool_names,
            .execution = execution,
            .terminal_reason = terminal_reason,
            .cancellation_origin = cancellation_origin,
        } };
    }

    return error.InvalidSessionFormat;
}

fn parseLegacyInterruptedTerminalReason(
    value: ?std.json.Value,
) !session.InterruptedTerminalReason {
    const raw = value orelse return .cancelled;
    if (raw != .string) return error.InvalidSessionFormat;
    if (std.mem.eql(u8, raw.string, "cancelled")) return .cancelled;
    if (std.mem.eql(u8, raw.string, "failed")) return .failed;
    return error.InvalidSessionFormat;
}

fn parseOptionalToolCall(alloc: Allocator, maybe_value: ?std.json.Value) !?session.ToolCall {
    const value = maybe_value orelse return null;
    var call: ?session.ToolCall = switch (value) {
        .null => null,
        .object => try parseToolCall(alloc, value),
        else => return error.InvalidSessionFormat,
    };
    errdefer if (call) |owned| session.freeToolCall(alloc, owned);
    if (call) |*parsed| {
        try session.repairPersistedInterruptedToolArguments(alloc, parsed, .legacy);
    }
    return call;
}

fn parseToolCall(alloc: Allocator, value: std.json.Value) !session.ToolCall {
    const object = try requireObject(value);
    const id = try alloc.dupe(u8, try requireString(object, "id"));
    errdefer mem_utils.free(alloc, id);
    const name = try alloc.dupe(u8, try requireString(object, "name"));
    errdefer mem_utils.free(alloc, name);
    const raw_arguments_json = try requireString(object, "arguments_json");
    const argument_integrity = try types.ToolArgumentIntegrity.classifyFunctionInput(alloc, raw_arguments_json);
    const arguments_json = try alloc.dupe(u8, if (argument_integrity == .malformed_json) "{}" else raw_arguments_json);
    errdefer mem_utils.free(alloc, arguments_json);
    const provider_result = try optionalStringDup(alloc, object.get("provider_result"));
    errdefer if (provider_result) |result| mem_utils.free(alloc, result);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
        .argument_integrity = argument_integrity,
        .provider_result = provider_result,
    };
}

fn parseOptionalExecutionMemory(alloc: Allocator, maybe_value: ?std.json.Value) !session.ExecutionMemory {
    const value = maybe_value orelse return .{};
    if (value == .null) return .{};
    const object = try requireObject(value);
    const schema_version: i64 = if (object.get("schema_version")) |version| blk: {
        if (version != .integer or version.integer < 1 or version.integer > 3) {
            return error.InvalidSessionFormat;
        }
        break :blk version.integer;
    } else 1;
    const tool_steps = try parseToolExecutionSteps(
        alloc,
        object.get("tool_steps"),
        schema_version,
    );
    errdefer session.freeExecutionMemory(alloc, .{ .tool_steps = tool_steps });
    const steering = try parseOptionalSteering(
        alloc,
        object.get("steering"),
        schema_version,
        tool_steps.len,
    );
    errdefer types.freePersistedSteering(alloc, steering);
    const files = try parseFileEvidenceSlice(alloc, object.get("files"));
    return .{ .tool_steps = tool_steps, .files = files, .steering = steering };
}

fn parseOptionalSteering(
    alloc: Allocator,
    maybe_value: ?std.json.Value,
    schema_version: i64,
    tool_step_count: usize,
) ![]types.PersistedSteering {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const steering = try alloc.alloc(types.PersistedSteering, value.array.items.len);
    errdefer mem_utils.free(alloc, steering);
    var parsed_count: usize = 0;
    errdefer for (steering[0..parsed_count]) |item| {
        alloc.free(item.text);
        if (item.assistant_prefix) |prefix| alloc.free(prefix);
    };
    var prior_tool_step_count: usize = 0;
    for (value.array.items, 0..) |item, index| {
        const parsed = if (schema_version <= 2)
            types.PersistedSteering{
                .text = try alloc.dupe(u8, if (item == .string) item.string else return error.InvalidSessionFormat),
                .after_tool_step_count = tool_step_count,
            }
        else blk: {
            const object = try requireObject(item);
            const after_tool_step_count = try requireUsize(object, "after_tool_step_count");
            if (after_tool_step_count > tool_step_count or
                (index > 0 and after_tool_step_count < prior_tool_step_count))
            {
                return error.InvalidSessionFormat;
            }
            const text = try alloc.dupe(u8, try requireString(object, "text"));
            const assistant_prefix = optionalStringDup(
                alloc,
                object.get("assistant_prefix"),
            ) catch |err| {
                alloc.free(text);
                return err;
            };
            break :blk types.PersistedSteering{
                .text = text,
                .assistant_prefix = assistant_prefix,
                .after_tool_step_count = after_tool_step_count,
            };
        };
        steering[index] = parsed;
        parsed_count += 1;
        prior_tool_step_count = parsed.after_tool_step_count;
    }
    return steering;
}

fn parseToolExecutionSteps(
    alloc: Allocator,
    maybe_value: ?std.json.Value,
    schema_version: i64,
) ![]session.ToolExecutionStep {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};

    const steps = try alloc.alloc(session.ToolExecutionStep, value.array.items.len);
    errdefer mem_utils.free(alloc, steps);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) freeParsedToolExecutionStep(alloc, steps[i]);
    }

    for (value.array.items, 0..) |item, i| {
        const object = try requireObject(item);
        const assistant = try optionalStringDup(alloc, object.get("assistant"));
        errdefer if (assistant) |text| mem_utils.free(alloc, text);
        const tool_calls = try parseToolCallArray(alloc, object.get("tool_calls"));
        errdefer session.freeToolCallSlice(alloc, tool_calls);
        const tool_results = try parsePersistedToolResultArray(
            alloc,
            object.get("tool_results"),
            schema_version,
        );
        errdefer session.freePersistedToolResults(alloc, tool_results);
        try session.repairPersistedToolArguments(alloc, tool_calls, tool_results, .legacy);
        steps[i] = .{
            .assistant = assistant,
            .tool_calls = tool_calls,
            .tool_results = tool_results,
        };
        parsed_count += 1;
    }
    return steps;
}

fn parseToolCallArray(alloc: Allocator, maybe_value: ?std.json.Value) ![]session.ToolCall {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};

    const calls = try alloc.alloc(session.ToolCall, value.array.items.len);
    errdefer mem_utils.free(alloc, calls);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) session.freeToolCall(alloc, calls[i]);
    }

    for (value.array.items, 0..) |item, i| {
        calls[i] = try parseToolCall(alloc, item);
        parsed_count += 1;
    }
    return calls;
}

fn parsePersistedToolResultArray(
    alloc: Allocator,
    maybe_value: ?std.json.Value,
    schema_version: i64,
) ![]session.PersistedToolResult {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};

    const results = try alloc.alloc(session.PersistedToolResult, value.array.items.len);
    errdefer mem_utils.free(alloc, results);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) freeParsedPersistedToolResult(alloc, results[i]);
    }

    for (value.array.items, 0..) |item, i| {
        results[i] = try parsePersistedToolResult(alloc, item, schema_version);
        parsed_count += 1;
    }
    return results;
}

fn parsePersistedToolResult(
    alloc: Allocator,
    value: std.json.Value,
    schema_version: i64,
) !session.PersistedToolResult {
    const object = try requireObject(value);
    const tool_call_id = try alloc.dupe(u8, try requireString(object, "tool_call_id"));
    errdefer mem_utils.free(alloc, tool_call_id);
    const tool_name = try alloc.dupe(u8, try requireString(object, "tool_name"));
    errdefer mem_utils.free(alloc, tool_name);
    const output = try alloc.dupe(u8, try requireString(object, "output"));
    errdefer mem_utils.free(alloc, output);
    const output_handle = try optionalStringDup(alloc, object.get("output_handle"));
    errdefer if (output_handle) |handle| mem_utils.free(alloc, handle);
    const preview = try optionalStringDup(alloc, object.get("preview"));
    errdefer if (preview) |text| mem_utils.free(alloc, text);
    const permission_feedback: [][]u8 = if (schema_version == 1)
        &.{}
    else blk: {
        const feedback_value = object.get("permission_feedback") orelse return error.InvalidSessionFormat;
        if (feedback_value != .array) return error.InvalidSessionFormat;
        break :blk try parseOptionalStringArray(alloc, feedback_value);
    };
    errdefer types.freePermissionFeedback(alloc, permission_feedback);
    const committed_file_presentation = if (object.get("committed_file_presentation")) |presentation_value|
        try parseCommittedFilePresentation(alloc, presentation_value)
    else
        null;
    errdefer if (committed_file_presentation) |presentation| {
        types.freeCommittedFilePresentation(alloc, presentation);
    };
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .status = try parsePersistedToolStatus(try requireString(object, "status")),
        .output = output,
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = try requireUsize(object, "output_bytes"),
        .stored_output_bytes = try requireUsize(object, "stored_output_bytes"),
        .truncated = try requireBool(object, "truncated"),
        .provider_native = try requireBool(object, "provider_native"),
        .created_at_ms = try requireI64(object, "created_at_ms"),
        .permission_feedback = permission_feedback,
        .committed_file_presentation = committed_file_presentation,
    };
}

fn parseCommittedFilePresentation(
    alloc: Allocator,
    value: std.json.Value,
) !types.CommittedFilePresentation {
    const object = try requireObject(value);
    const path = try alloc.dupe(u8, try requireString(object, "path"));
    errdefer mem_utils.free(alloc, path);
    const lines = try parseCommittedFilePresentationLines(alloc, object.get("lines"));
    errdefer {
        for (lines) |line| alloc.free(@constCast(line.text));
        if (lines.len > 0) alloc.free(@constCast(lines));
    }
    const previous_content = try optionalStringDup(alloc, object.get("previous_content"));
    errdefer if (previous_content) |content| mem_utils.free(alloc, content);
    const after_content = try optionalStringDup(alloc, object.get("after_content"));
    errdefer if (after_content) |content| mem_utils.free(alloc, content);
    const lifecycle_id = try parseOptionalLifecycleId(alloc, object.get("lifecycle_id"));
    errdefer if (lifecycle_id) |id| mem_utils.free(alloc, @constCast(id.call_id));
    const content_handle = try optionalStringDup(alloc, object.get("content_handle"));
    errdefer if (content_handle) |handle| mem_utils.free(alloc, handle);
    const presentation = types.CommittedFilePresentation{
        .path = path,
        .kind = try parseCommittedFilePresentationKind(try requireString(object, "kind")),
        .lines = lines,
        .additions = try requireUsize(object, "additions"),
        .deletions = try requireUsize(object, "deletions"),
        .truncated = try requireBool(object, "truncated"),
        .previous_content = previous_content,
        .after_content = after_content,
        .lifecycle_id = lifecycle_id,
        .content_handle = content_handle,
    };
    if (!types.committedFilePresentationContentSourceValid(presentation)) {
        return error.InvalidSessionFormat;
    }
    return presentation;
}

fn parseCommittedFilePresentationLines(
    alloc: Allocator,
    maybe_value: ?std.json.Value,
) ![]types.CommittedFilePresentationLine {
    const value = maybe_value orelse return error.InvalidSessionFormat;
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const lines = try alloc.alloc(types.CommittedFilePresentationLine, value.array.items.len);
    errdefer mem_utils.free(alloc, lines);
    var parsed_count: usize = 0;
    errdefer for (lines[0..parsed_count]) |line| mem_utils.free(alloc, @constCast(line.text));
    for (value.array.items, 0..) |item, index| {
        const object = try requireObject(item);
        lines[index] = .{
            .kind = try parseCommittedFilePresentationLineKind(try requireString(object, "kind")),
            .old_line = try optionalU32(object.get("old_line")),
            .new_line = try optionalU32(object.get("new_line")),
            .text = try alloc.dupe(u8, try requireString(object, "text")),
        };
        parsed_count += 1;
    }
    return lines;
}

fn parseOptionalLifecycleId(
    alloc: Allocator,
    maybe_value: ?std.json.Value,
) !?types.ToolLifecycleId {
    const value = maybe_value orelse return null;
    if (value == .null) return null;
    const object = try requireObject(value);
    const call_id = try alloc.dupe(u8, try requireString(object, "call_id"));
    errdefer mem_utils.free(alloc, call_id);
    return .{
        .turn_id = @intCast(try requireUsize(object, "turn_id")),
        .call_id = call_id,
    };
}

fn optionalU32(maybe_value: ?std.json.Value) !?u32 {
    const value = maybe_value orelse return error.InvalidSessionFormat;
    if (value == .null) return null;
    if (value != .integer or value.integer < 0) return error.InvalidSessionFormat;
    return std.math.cast(u32, value.integer) orelse error.InvalidSessionFormat;
}

fn parseCommittedFilePresentationKind(
    value: []const u8,
) !types.CommittedFilePresentationKind {
    if (std.mem.eql(u8, value, "added")) return .added;
    if (std.mem.eql(u8, value, "edited")) return .edited;
    return error.InvalidSessionFormat;
}

fn parseCommittedFilePresentationLineKind(
    value: []const u8,
) !types.CommittedFilePresentationLineKind {
    if (std.mem.eql(u8, value, "context")) return .context;
    if (std.mem.eql(u8, value, "addition")) return .addition;
    if (std.mem.eql(u8, value, "deletion")) return .deletion;
    if (std.mem.eql(u8, value, "elision")) return .elision;
    if (std.mem.eql(u8, value, "notice")) return .notice;
    return error.InvalidSessionFormat;
}

fn parseFileEvidenceSlice(alloc: Allocator, maybe_value: ?std.json.Value) ![]session.FileEvidence {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};

    const files = try alloc.alloc(session.FileEvidence, value.array.items.len);
    errdefer mem_utils.free(alloc, files);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) freeParsedFileEvidence(alloc, files[i]);
    }

    for (value.array.items, 0..) |item, i| {
        files[i] = try parseFileEvidence(alloc, item);
        parsed_count += 1;
    }
    return files;
}

fn parseFileEvidence(alloc: Allocator, value: std.json.Value) !session.FileEvidence {
    const object = try requireObject(value);
    const path = try alloc.dupe(u8, try requireString(object, "path"));
    errdefer mem_utils.free(alloc, path);
    const new_path = try optionalStringDup(alloc, object.get("new_path"));
    errdefer if (new_path) |path_copy| mem_utils.free(alloc, path_copy);
    const tool_call_id = try alloc.dupe(u8, try requireString(object, "tool_call_id"));
    errdefer mem_utils.free(alloc, tool_call_id);
    const tool_name = try alloc.dupe(u8, try requireString(object, "tool_name"));
    errdefer mem_utils.free(alloc, tool_name);
    return .{
        .path = path,
        .new_path = new_path,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .action = try parseFileEvidenceAction(try requireString(object, "action")),
        .status = try parsePersistedToolStatus(try requireString(object, "status")),
        .model_view_covers_full_file = try requireBool(object, "model_view_covers_full_file"),
        .stale = try requireBool(object, "stale"),
    };
}

fn parsePersistedToolStatus(value: []const u8) !session.PersistedToolStatus {
    if (std.mem.eql(u8, value, "success")) return .success;
    if (std.mem.eql(u8, value, "failure")) return .failure;
    return error.InvalidSessionFormat;
}

fn parseFileEvidenceAction(value: []const u8) !session.FileEvidenceAction {
    if (std.mem.eql(u8, value, "read")) return .read;
    if (std.mem.eql(u8, value, "write")) return .write;
    if (std.mem.eql(u8, value, "edit")) return .edit;
    if (std.mem.eql(u8, value, "delete")) return .delete;
    if (std.mem.eql(u8, value, "rename")) return .rename;
    if (std.mem.eql(u8, value, "copy")) return .copy;
    if (std.mem.eql(u8, value, "search")) return .search;
    if (std.mem.eql(u8, value, "list")) return .list;
    if (std.mem.eql(u8, value, "unknown")) return .unknown;
    return error.InvalidSessionFormat;
}

fn freeParsedToolExecutionStep(alloc: Allocator, step: session.ToolExecutionStep) void {
    if (step.assistant) |assistant| alloc.free(assistant);
    session.freeToolCallSlice(alloc, step.tool_calls);
    session.freePersistedToolResults(alloc, step.tool_results);
}

fn freeParsedPersistedToolResult(alloc: Allocator, result: session.PersistedToolResult) void {
    alloc.free(result.tool_call_id);
    alloc.free(result.tool_name);
    alloc.free(result.output);
    if (result.output_handle) |handle| alloc.free(handle);
    if (result.preview) |preview| alloc.free(preview);
    types.freePermissionFeedback(alloc, result.permission_feedback);
    if (result.committed_file_presentation) |presentation| {
        types.freeCommittedFilePresentation(alloc, presentation);
    }
}

fn freeParsedFileEvidence(alloc: Allocator, file: session.FileEvidence) void {
    alloc.free(file.path);
    if (file.new_path) |new_path| alloc.free(new_path);
    alloc.free(file.tool_call_id);
    alloc.free(file.tool_name);
}

fn parseUserTurn(alloc: Allocator, value: std.json.Value) !session.UserTurn {
    const object = try requireObject(value);
    const text = try alloc.dupe(u8, try requireString(object, "text"));
    errdefer mem_utils.free(alloc, text);
    const images = try validateImagesArray(alloc, object.get("images"));
    errdefer session.freeImageAttachmentSlice(alloc, images);
    return .{ .text = text, .images = images };
}

fn parseConversationLanguage(raw: []const u8) !session.ConversationLanguage {
    return session.ConversationLanguage.fromSlice(raw) catch error.InvalidSessionFormat;
}

/// Parses only the workspace_root field; caller owns a returned string and frees with allocator.free.
pub fn parseWorkspaceRoot(alloc: Allocator, json_text: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return error.InvalidSessionFormat;
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    return try optionalStringDup(alloc, root.get("workspace_root"));
}

fn validateImagesArray(alloc: Allocator, maybe_value: ?std.json.Value) ![]session.ImageAttachment {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};

    const images = try alloc.alloc(session.ImageAttachment, value.array.items.len);
    errdefer mem_utils.free(alloc, images);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) {
            types.freeImageAttachment(alloc, images[i]);
        }
    }

    for (value.array.items, 0..) |entry, i| {
        const object = try requireObject(entry);
        const snapshot_path = try optionalStringDup(alloc, object.get("snapshot_path"));
        var owns_snapshot_path = true;
        errdefer if (owns_snapshot_path) {
            if (snapshot_path) |path| alloc.free(path);
        };
        const snapshot_sha256 = try optionalStringDup(alloc, object.get("snapshot_sha256"));
        var owns_snapshot_sha256 = true;
        errdefer if (owns_snapshot_sha256) {
            if (snapshot_sha256) |sha256| alloc.free(sha256);
        };
        if ((snapshot_path == null) != (snapshot_sha256 == null)) return error.InvalidSessionFormat;
        images[i] = try dupeParsedImageAttachment(
            alloc,
            if (object.get("id") != null) try requireUsize(object, "id") else 0,
            try requireString(object, "path"),
            try requireString(object, "media_type"),
            snapshot_path,
            snapshot_sha256,
        );
        owns_snapshot_path = false;
        owns_snapshot_sha256 = false;
        parsed_count += 1;
    }
    return images;
}

fn dupeParsedImageAttachment(
    alloc: Allocator,
    id: usize,
    path_src: []const u8,
    media_type_src: []const u8,
    snapshot_path_src: ?[]u8,
    snapshot_sha256_src: ?[]u8,
) !session.ImageAttachment {
    const path = try alloc.dupe(u8, path_src);
    errdefer mem_utils.free(alloc, path);
    const media_type = try alloc.dupe(u8, media_type_src);
    errdefer mem_utils.free(alloc, media_type);
    return .{
        .id = id,
        .path = path,
        .media_type = media_type,
        .snapshot_path = snapshot_path_src,
        .snapshot_sha256 = snapshot_sha256_src,
    };
}

fn requireSchemaVersion(object: std.json.ObjectMap) !void {
    try requireLegacySchema(try requireI64(object, "schema_version"));
}

fn requireLegacySchema(version: i64) !void {
    _ = try legacySchemaVersion(version);
}

fn legacySchemaVersion(version: i64) !LegacySchemaVersion {
    return switch (version) {
        legacy_schema_v1 => .v1,
        legacy_schema_v2 => .v2,
        else => error.UnsupportedSessionSchema,
    };
}

fn summaryComplete(
    schema_version: ?i64,
    id: ?[]u8,
    created_at_ms: ?i64,
    updated_at_ms: ?i64,
    conversation_language: ?session.ConversationLanguage,
    history_len: ?usize,
) bool {
    return schema_version != null and id != null and created_at_ms != null and
        updated_at_ms != null and conversation_language != null and history_len != null;
}

fn readStringOwned(
    reader: *std.json.Reader,
    alloc: Allocator,
    max_len: usize,
) ![]u8 {
    const token = try reader.nextAllocMax(alloc, .alloc_always, max_len);
    return switch (token) {
        .allocated_string => |value| value,
        .string => |value| try alloc.dupe(u8, value),
        else => {
            freeToken(alloc, token);
            return error.InvalidSessionFormat;
        },
    };
}

fn readOptionalStringOwned(
    reader: *std.json.Reader,
    alloc: Allocator,
    max_len: usize,
) !?[]u8 {
    const token = try reader.nextAllocMax(alloc, .alloc_always, max_len);
    return switch (token) {
        .null => null,
        .allocated_string => |value| value,
        .string => |value| try alloc.dupe(u8, value),
        else => {
            freeToken(alloc, token);
            return error.InvalidSessionFormat;
        },
    };
}

fn readI64Token(reader: *std.json.Reader, alloc: Allocator) !i64 {
    const token = try reader.nextAllocMax(alloc, .alloc_if_needed, 32);
    defer freeToken(alloc, token);
    const raw = switch (token) {
        .number => |value| value,
        .allocated_number => |value| value,
        else => return error.InvalidSessionFormat,
    };
    return std.fmt.parseInt(i64, raw, 10) catch error.InvalidSessionFormat;
}

fn readU64Token(reader: *std.json.Reader, alloc: Allocator) !u64 {
    const token = try reader.nextAllocMax(alloc, .alloc_if_needed, 32);
    defer freeToken(alloc, token);
    const raw = switch (token) {
        .number => |value| value,
        .allocated_number => |value| value,
        else => return error.InvalidSessionFormat,
    };
    return std.fmt.parseUnsigned(u64, raw, 10) catch error.InvalidSessionFormat;
}

fn expectToken(actual: std.json.Token, comptime expected: std.meta.Tag(std.json.Token)) !void {
    if (std.meta.activeTag(actual) != expected) return error.InvalidSessionFormat;
}

fn freeToken(alloc: Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number => |value| alloc.free(value),
        .allocated_string => |value| alloc.free(value),
        else => {},
    }
}

fn parseOptionalBackgroundRecordId(
    maybe_value: ?std.json.Value,
) !?[16]u8 {
    const value = maybe_value orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len != 32) return error.InvalidSessionFormat;
    var id: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&id, value.string) catch return error.InvalidSessionFormat;
    const canonical = std.fmt.bytesToHex(id, .lower);
    if (!std.mem.eql(u8, &canonical, value.string)) return error.InvalidSessionFormat;
    return id;
}

noinline fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidSessionFormat;
    return value.object;
}

noinline fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .string) return error.InvalidSessionFormat;
    return value.string;
}

fn requireBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .bool) return error.InvalidSessionFormat;
    return value.bool;
}

noinline fn requireI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .integer) return error.InvalidSessionFormat;
    if (value.integer < std.math.minInt(i64) or value.integer > std.math.maxInt(i64)) {
        return error.InvalidSessionFormat;
    }
    return @intCast(value.integer);
}

noinline fn requireUsize(object: std.json.ObjectMap, key: []const u8) !usize {
    const value = try requireI64(object, key);
    if (value < 0) return error.InvalidSessionFormat;
    return @intCast(value);
}

noinline fn optionalStringDup(alloc: Allocator, maybe_value: ?std.json.Value) !?[]u8 {
    const value = maybe_value orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| try alloc.dupe(u8, text),
        else => error.InvalidSessionFormat,
    };
}

fn parseOptionalStringArray(alloc: Allocator, maybe_value: ?std.json.Value) ![][]u8 {
    const value = maybe_value orelse return &.{};
    if (value == .null) return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};

    const items = try alloc.alloc([]u8, value.array.items.len);
    errdefer mem_utils.free(alloc, items);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) alloc.free(items[i]);
    }

    for (value.array.items, 0..) |entry, i| {
        if (entry != .string) return error.InvalidSessionFormat;
        items[i] = try alloc.dupe(u8, entry.string);
        parsed_count += 1;
    }
    return items;
}

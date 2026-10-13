const std = @import("std");
const image_attachments = @import("../images/image_attachments.zig");
const image_data = @import("../images/image_data.zig");
const session = @import("session.zig");
const session_usage = @import("session_usage.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const types = @import("../shared/types.zig");
const captured_command = @import("../tooling/captured_command.zig");
const model_provider = @import("../config/model_provider.zig");
const context_limits = @import("../config/context_limits.zig");
const credential_authority = @import("../auth/credential_authority.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const DurableSessionPreferences = struct {
    provider: model_provider.ProviderId = .codex,
    model: []u8,
    effort: types.ReasoningEffort,
    fast_mode: bool,

    pub fn deinit(self: *DurableSessionPreferences, alloc: Allocator) void {
        alloc.free(self.model);
        self.* = undefined;
    }

    pub fn dupe(self: DurableSessionPreferences, alloc: Allocator) !DurableSessionPreferences {
        return .{
            .provider = self.provider,
            .model = try alloc.dupe(u8, self.model),
            .effort = self.effort,
            .fast_mode = self.fast_mode,
        };
    }
};

/// Decodes persisted preferences; the caller owns the returned model.
pub fn parse_preferences(alloc: Allocator, value: std.json.Value) !DurableSessionPreferences {
    const raw = try requireObject(value);
    const legacy = raw.contains("connection_id") or raw.contains("model_id");
    const object = if (legacy)
        try exactObject(value, &.{ "connection_id", "model_id", "effort", "fast_mode" })
    else if (raw.contains("provider"))
        try exactObject(value, &.{ "provider", "model", "effort", "fast_mode" })
    else
        try exactObject(value, &.{ "model", "effort", "fast_mode" });
    if (legacy or !object.contains("provider")) return error.InvalidDurableField;
    const provider = model_provider.parse_saved(object.get("provider").?) catch return error.InvalidDurableField;
    const model = try requireString(object, if (legacy) "model_id" else "model");
    try validateModel(model);
    const effort = types.ReasoningEffort.parse(try requireString(object, "effort")) orelse return error.InvalidDurableField;
    const fast_mode = try requireBool(object, "fast_mode");
    return .{ .provider = provider, .model = try alloc.dupe(u8, model), .effort = effort, .fast_mode = fast_mode };
}

pub const RecoveryToolState = enum {
    none,
    proven_unexecuted,
    confirmed,
    uncertain,
};

pub const TurnAuthority = struct {
    provider: model_provider.ProviderId,
    model: []u8,
    credential_source: ?types.CredentialSource = null,
    credential_identity: ?credential_authority.Identity = null,

    pub fn deinit(self: *TurnAuthority, alloc: Allocator) void {
        alloc.free(self.model);
        self.* = undefined;
    }

    pub fn dupe(self: TurnAuthority, alloc: Allocator) !TurnAuthority {
        return .{
            .provider = self.provider,
            .model = try alloc.dupe(u8, self.model),
            .credential_source = self.credential_source,
            .credential_identity = self.credential_identity,
        };
    }
};

pub const RecoveryCheckpoint = struct {
    version: u8 = 2,
    disposition: enum { continuable, history_only } = .continuable,
    turn_id: u64,
    user: session.UserTurn,
    assistant_source: []u8,
    execution: session.ExecutionMemory = .{},
    cause: types.ModelRecoveryCause,
    action: types.ModelRecoveryAction,
    tool_state: RecoveryToolState = .none,
    authority: TurnAuthority,
    requested_fast_mode: bool,
    fast_mode: bool,
    max_provider_attempts: usize,
    consumed_provider_attempts: usize,
    outstanding_reservation: bool = false,

    /// Borrows the checkpoint's exact user and uncommitted response suffix.
    pub fn interruptedTurn(self: RecoveryCheckpoint) types.HistoryTurn {
        return .{ .interrupted = .{
            .user = self.user,
            .assistant = if (self.assistant_source.len > 0) self.assistant_source else null,
            .execution = self.execution,
            .terminal_reason = .failed,
        } };
    }

    pub fn deinit(self: *RecoveryCheckpoint, alloc: Allocator) void {
        session.freeUserTurn(alloc, self.user);
        alloc.free(self.assistant_source);
        session.freeExecutionMemory(alloc, self.execution);
        self.authority.deinit(alloc);
        self.* = undefined;
    }

    pub fn dupe(self: RecoveryCheckpoint, alloc: Allocator) !RecoveryCheckpoint {
        const user = try session.dupeUserTurn(alloc, self.user);
        errdefer session.freeUserTurn(alloc, user);
        const assistant_source = try alloc.dupe(u8, self.assistant_source);
        errdefer alloc.free(assistant_source);
        const execution = try types.dupeExecutionMemory(alloc, self.execution);
        errdefer session.freeExecutionMemory(alloc, execution);
        const authority = try self.authority.dupe(alloc);
        return .{
            .version = self.version,
            .disposition = self.disposition,
            .turn_id = self.turn_id,
            .user = user,
            .assistant_source = assistant_source,
            .execution = execution,
            .cause = self.cause,
            .action = self.action,
            .tool_state = self.tool_state,
            .authority = authority,
            .requested_fast_mode = self.requested_fast_mode,
            .fast_mode = self.fast_mode,
            .max_provider_attempts = self.max_provider_attempts,
            .consumed_provider_attempts = self.consumed_provider_attempts,
            .outstanding_reservation = self.outstanding_reservation,
        };
    }
};

pub const DurableSessionState = struct {
    id: []u8,
    origin_workspace_root: []u8,
    workspace_root: []u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    conversation_language: session.ConversationLanguage,
    preferences: DurableSessionPreferences,
    history: []session.HistoryTurn,
    context_history_start: usize = 0,
    total_input_tokens: u64,
    total_output_tokens: u64,
    permission_state: session_permission_state.State = .{},
    /// Last ordinary history commit correlated to durable subagent work. This
    /// control-only marker is not included in model history.
    last_subagent_work_id: ?[]u8 = null,
    /// True only for a parent-owned subagent session. This durable identity
    /// keeps the session private even if owner sidecar publication is
    /// interrupted immediately after creation.
    subagent_child: bool = false,
    /// Null only for sessions written before durable usage accounting.
    usage: ?session_usage.Snapshot = null,
    /// Active control state. It is never projected into model history and a
    /// restored checkpoint requires explicit host authority before any send.
    recovery_checkpoint: ?RecoveryCheckpoint = null,

    pub fn deinit(self: *DurableSessionState, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.origin_workspace_root);
        alloc.free(self.workspace_root);
        self.preferences.deinit(alloc);
        session.freeHistoryTurnSlice(alloc, self.history);
        self.permission_state.deinit(alloc);
        if (self.last_subagent_work_id) |id| alloc.free(id);
        if (self.usage) |*usage| usage.deinit(alloc);
        if (self.recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
        self.* = undefined;
    }

    /// Retains legacy recovery evidence without granting permission to replay its route.
    pub fn archive_legacy_recovery(self: *DurableSessionState, alloc: Allocator) !bool {
        const checkpoint = if (self.recovery_checkpoint) |*value| value else return false;
        if (checkpoint.disposition != .history_only) return false;
        const turn = try session.dupeHistoryTurn(alloc, checkpoint.interruptedTurn());
        errdefer session.freeHistoryTurn(alloc, turn);
        const len = try std.math.add(usize, self.history.len, 1);
        self.history = try alloc.realloc(self.history, len);
        self.history[len - 1] = turn;
        checkpoint.deinit(alloc);
        self.recovery_checkpoint = null;
        return true;
    }

    pub fn dupe(self: DurableSessionState, alloc: Allocator) !DurableSessionState {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        const origin_workspace_root = try alloc.dupe(u8, self.origin_workspace_root);
        errdefer alloc.free(origin_workspace_root);
        const workspace_root = try alloc.dupe(u8, self.workspace_root);
        errdefer alloc.free(workspace_root);
        const preferences = try self.preferences.dupe(alloc);
        errdefer {
            var owned_preferences = preferences;
            owned_preferences.deinit(alloc);
        }
        const history = try dupeHistory(alloc, self.history);
        errdefer session.freeHistoryTurnSlice(alloc, history);
        const last_subagent_work_id = if (self.last_subagent_work_id) |work_id|
            try alloc.dupe(u8, work_id)
        else
            null;
        errdefer if (last_subagent_work_id) |work_id| alloc.free(work_id);
        var usage = if (self.usage) |snapshot|
            try session_usage.dupeSnapshotOwned(alloc, snapshot)
        else
            null;
        errdefer if (usage) |*snapshot| snapshot.deinit(alloc);
        const recovery_checkpoint = if (self.recovery_checkpoint) |checkpoint|
            try checkpoint.dupe(alloc)
        else
            null;
        const permission_state = try session_permission_state.dupe(
            alloc,
            self.permission_state,
        );

        return .{
            .id = id,
            .origin_workspace_root = origin_workspace_root,
            .workspace_root = workspace_root,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
            .conversation_language = self.conversation_language,
            .preferences = preferences,
            .history = history,
            .context_history_start = self.context_history_start,
            .total_input_tokens = self.total_input_tokens,
            .total_output_tokens = self.total_output_tokens,
            .permission_state = permission_state,
            .last_subagent_work_id = last_subagent_work_id,
            .subagent_child = self.subagent_child,
            .usage = usage,
            .recovery_checkpoint = recovery_checkpoint,
        };
    }
};

pub const session_metadata_schema_version: u8 = 4;
pub const max_session_metadata_bytes: usize = 64 * 1024;
pub const max_session_title_bytes: usize = 240;

pub const SessionMetadata = struct {
    schema_version: u8 = session_metadata_schema_version,
    id: []const u8,
    origin_workspace_root: []const u8,
    workspace_root: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    conversation_language: []const u8,
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: []const u8,
    fast_mode: bool,
    /// Omitted when false so schema-v4 headers remain readable by old binaries.
    title: ?[]const u8 = null,
    subagent_child: bool = false,
};

pub const DecodedSessionMetadata = std.json.Parsed(SessionMetadata);
pub const max_permission_state_bytes: usize = 1024 * 1024;
pub const max_recovery_checkpoint_bytes: usize = context_limits.emergency_ceiling_bytes;

pub fn encodeSessionMetadata(
    alloc: Allocator,
    metadata: SessionMetadata,
) ![]u8 {
    try validateSessionMetadata(metadata);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(
        metadata,
        .{ .emit_null_optional_fields = false },
        &out.writer,
    );
    if (out.written().len == 0 or out.written().len > max_session_metadata_bytes) {
        return error.SessionMetadataTooLarge;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn decodeSessionMetadata(
    alloc: Allocator,
    bytes: []const u8,
) !DecodedSessionMetadata {
    if (bytes.len == 0 or bytes.len > max_session_metadata_bytes) {
        return error.SessionMetadataTooLarge;
    }
    var parsed = std.json.parseFromSlice(SessionMetadata, alloc, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_session_metadata_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionMetadata,
    };
    errdefer parsed.deinit();
    validateSessionMetadata(parsed.value) catch return error.InvalidSessionMetadata;
    return parsed;
}

pub fn encodePermissionState(
    alloc: Allocator,
    state: session_permission_state.State,
) ![]u8 {
    try session_permission_state.validate(state);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writePermissionState(&out.writer, state);
    if (out.written().len == 0 or out.written().len > max_permission_state_bytes) {
        return error.PermissionStateTooLarge;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn decodePermissionState(
    alloc: Allocator,
    bytes: []const u8,
) !session_permission_state.State {
    if (bytes.len == 0 or bytes.len > max_permission_state_bytes) {
        return error.PermissionStateTooLarge;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .max_value_len = max_permission_state_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPermissionState,
    };
    defer parsed.deinit();
    return parsePermissionState(alloc, parsed.value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPermissionState,
    };
}

pub fn encodeRecoveryCheckpoint(
    alloc: Allocator,
    checkpoint: RecoveryCheckpoint,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeRecoveryCheckpoint(&out.writer, checkpoint);
    if (out.written().len == 0 or out.written().len > max_recovery_checkpoint_bytes) {
        return error.RecoveryCheckpointTooLarge;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn validateSessionMetadata(metadata: SessionMetadata) !void {
    if (metadata.schema_version != session_metadata_schema_version) {
        return error.UnsupportedSessionSchema;
    }
    try validateSessionId(metadata.id);
    try validateWorkspaceRoot(metadata.origin_workspace_root);
    try validateWorkspaceRoot(metadata.workspace_root);
    if (metadata.created_at_ms < 0 or metadata.updated_at_ms < metadata.created_at_ms) {
        return error.InvalidSessionMetadata;
    }
    try validateConversationLanguageBytes(metadata.conversation_language);
    if (metadata.provider == .configured and metadata.provider.configured.binding == null) return error.InvalidSessionMetadata;
    try validateModel(metadata.model);
    if (types.ReasoningEffort.parse(metadata.effort) == null) {
        return error.InvalidSessionMetadata;
    }
    if (metadata.title) |title| {
        if (title.len == 0 or
            title.len > max_session_title_bytes or
            !std.unicode.utf8ValidateSlice(title))
        {
            return error.InvalidSessionMetadata;
        }
    }
}

pub const EncodeSummary = struct {
    encoded_bytes: u64,
    sha256: [Sha256.digest_length]u8,
};

pub const DecodeLimits = struct {
    max_history_turns: usize = std.math.maxInt(usize),
    max_value_bytes: usize = std.math.maxInt(usize) / 2,
};

const CountingSha256 = struct {
    sha256: Sha256 = Sha256.init(.{}),
    bytes: u64 = 0,

    pub fn update(self: *CountingSha256, bytes: []const u8) void {
        self.sha256.update(bytes);
        self.bytes += bytes.len;
    }
};

pub fn writeDurableBytes(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return writeJsonString(writer, bytes);
    }

    try writer.writeAll("{\"encoding\":\"base64\",\"data\":\"");
    try std.base64.standard.Encoder.encodeWriter(writer, bytes);
    try writer.writeAll("\"}");
}

pub fn parseDurableBytes(alloc: Allocator, value: std.json.Value) ![]u8 {
    switch (value) {
        .string => |text| return try alloc.dupe(u8, text),
        .object => |object| {
            if (object.count() != 2) return error.InvalidDurableBytes;
            var iterator = object.iterator();
            const encoding_entry = iterator.next() orelse return error.InvalidDurableBytes;
            const data_entry = iterator.next() orelse return error.InvalidDurableBytes;
            if (!std.mem.eql(u8, encoding_entry.key_ptr.*, "encoding") or
                !std.mem.eql(u8, data_entry.key_ptr.*, "data"))
            {
                return error.InvalidDurableBytes;
            }
            if (encoding_entry.value_ptr.* != .string or
                !std.mem.eql(u8, encoding_entry.value_ptr.string, "base64") or
                data_entry.value_ptr.* != .string)
            {
                return error.InvalidDurableBytes;
            }

            const encoded = data_entry.value_ptr.string;
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
                return error.InvalidDurableBytes;
            const decoded = try alloc.alloc(u8, decoded_len);
            errdefer alloc.free(decoded);
            std.base64.standard.Decoder.decode(decoded, encoded) catch
                return error.InvalidDurableBytes;
            if (std.unicode.utf8ValidateSlice(decoded)) return error.InvalidDurableBytes;

            return decoded;
        },
        else => return error.InvalidDurableBytes,
    }
}

pub fn encodeState(state: DurableSessionState, writer: *std.Io.Writer) !EncodeSummary {
    try validateState(state);

    var hash_buffer: [4096]u8 = undefined;
    var hashed = std.Io.Writer.hashed(writer, CountingSha256{}, &hash_buffer);
    try writeState(&hashed.writer, state);
    try hashed.writer.flush();

    return .{
        .encoded_bytes = hashed.hasher.bytes,
        .sha256 = hashed.hasher.sha256.finalResult(),
    };
}

/// Reads an old persisted state without requiring modern cache-token totals.
/// Caller owns the state; all non-usage validation remains unchanged.
pub fn decodeLegacyState(alloc: Allocator, source: *std.Io.Reader, limits: DecodeLimits) !DurableSessionState {
    return decodeStateWithUsageContract(alloc, source, limits, true);
}

fn decodeStateWithUsageContract(alloc: Allocator, source: *std.Io.Reader, limits: DecodeLimits, legacy_usage: bool) !DurableSessionState {
    return decodeStateImpl(alloc, source, limits, legacy_usage) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidDurableField => return error.InvalidDurableField,
        error.InvalidDurableBytes => return error.InvalidDurableBytes,
        else => return error.InvalidSessionFormat,
    };
}

pub fn writeHistoryTurn(writer: *std.Io.Writer, turn: session.HistoryTurn) !void {
    switch (turn) {
        .compacted_summary => |entry| {
            try writer.writeAll("{\"kind\":\"compacted_summary\",\"summary\":");
            try writeDurableBytes(writer, entry.summary);
            try writer.print(",\"removed_turn_count\":{d},\"compaction_count\":{d}", .{
                entry.removed_turn_count,
                entry.compaction_count,
            });
            try writer.writeByte('}');
        },
        .assistant => |entry| {
            try writer.writeAll("{\"kind\":\"assistant\",\"user\":");
            try writeUserTurn(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            try writeDurableBytes(writer, entry.assistant);
            try writer.writeAll(",\"provider_replay\":");
            try std.json.Stringify.value(entry.provider_replay, .{}, writer);
            try writer.writeAll(",\"execution\":");
            try writeExecutionMemoryJson(writer, entry.execution, .durable);
            try writer.writeByte('}');
        },
        .interrupted => |entry| {
            try writer.writeAll("{\"kind\":\"interrupted\",\"user\":");
            try writeUserTurn(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            try writeOptionalDurableBytes(writer, entry.assistant);
            try writer.writeAll(",\"tool_call\":");
            if (entry.tool_call) |tool_call| {
                try writeExecutionToolCall(writer, tool_call, .durable);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"completed_tool_names\":[");
            for (entry.completed_tool_names, 0..) |name, i| {
                if (i > 0) try writer.writeByte(',');
                try writeDurableBytes(writer, name);
            }
            try writer.writeByte(']');
            try writer.writeAll(",\"terminal_reason\":");
            try writeJsonString(writer, @tagName(entry.terminal_reason));
            if (entry.cancellation_origin == .compaction) {
                try writer.writeAll(",\"cancellation_origin\":\"compaction\"");
            }
            if (hasDurableExecutionMemory(entry.execution)) {
                try writer.writeAll(",\"execution\":");
                try writeExecutionMemoryJson(writer, entry.execution, .durable);
            }
            if (entry.cancelled_command) |presentation| {
                try writer.writeAll(",\"cancelled_command\":");
                try writeCancelledCommandPresentation(writer, presentation);
            }
            try writer.writeByte('}');
        },
    }
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
    try out.writer.writeAll("]");
    return out.toOwnedSlice();
}

pub fn parseHistoryTurn(alloc: Allocator, value: std.json.Value) !session.HistoryTurn {
    const kind = try requireString(try requireObject(value), "kind");
    if (std.mem.eql(u8, kind, "compacted_summary")) {
        const raw_object = try requireObject(value);
        const has_root_user_messages = raw_object.get("root_user_messages") != null;
        const has_completeness = raw_object.get("root_user_messages_complete") != null;
        const has_permission_feedback = raw_object.get("permission_feedback") != null;
        const has_feedback_completeness = raw_object.get("permission_feedback_complete") != null;
        if (has_permission_feedback != has_feedback_completeness) {
            return error.InvalidSessionFormat;
        }
        const object = if (has_feedback_completeness)
            try exactObject(value, &.{ "kind", "summary", "removed_turn_count", "compaction_count", "root_user_messages", "root_user_messages_complete", "permission_feedback", "permission_feedback_complete" })
        else if (has_completeness)
            try exactObject(value, &.{ "kind", "summary", "removed_turn_count", "compaction_count", "root_user_messages", "root_user_messages_complete" })
        else if (has_root_user_messages)
            try exactObject(value, &.{ "kind", "summary", "removed_turn_count", "compaction_count", "root_user_messages" })
        else
            try exactObject(value, &.{ "kind", "summary", "removed_turn_count", "compaction_count" });
        const summary = try parseRequiredDurableBytes(alloc, object, "summary");
        errdefer mem_utils.free(alloc, summary);
        const root_user_messages: [][]u8 = if (has_root_user_messages)
            try parseDurableBytesArray(
                alloc,
                object.get("root_user_messages") orelse return error.InvalidSessionFormat,
            )
        else
            &.{};
        errdefer types.freeCompletedToolNames(alloc, root_user_messages);
        const permission_feedback: [][]u8 = if (has_permission_feedback)
            try parseDurableBytesArray(
                alloc,
                object.get("permission_feedback") orelse return error.InvalidSessionFormat,
            )
        else
            &.{};
        errdefer types.freePermissionFeedback(alloc, permission_feedback);
        const removed_turn_count = try requireUsize(object, "removed_turn_count");
        return .{ .compacted_summary = .{
            .summary = summary,
            .removed_turn_count = removed_turn_count,
            .compaction_count = try requireUsize(object, "compaction_count"),
            .root_user_messages = root_user_messages,
            .root_user_messages_complete = if (has_completeness)
                try requireBool(object, "root_user_messages_complete")
            else
                has_root_user_messages or removed_turn_count == 0,
            .permission_feedback = permission_feedback,
            .permission_feedback_complete = if (has_feedback_completeness)
                try requireBool(object, "permission_feedback_complete")
            else
                removed_turn_count == 0,
        } };
    }
    if (std.mem.eql(u8, kind, "assistant")) {
        const shape = try exactVariantObject(value, &.{ "kind", "user", "assistant", "execution" }, &.{ "kind", "user", "assistant", "execution", "provider_replay" });
        const object = shape.object;
        const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
        errdefer session.freeUserTurn(alloc, user);
        const assistant = try parseRequiredDurableBytes(alloc, object, "assistant");
        errdefer mem_utils.free(alloc, assistant);
        const execution = try parseExecutionMemory(alloc, object.get("execution") orelse return error.InvalidSessionFormat);
        errdefer session.freeExecutionMemory(alloc, execution);
        const replay = try parseProviderReplay(alloc, object.get("provider_replay") orelse .null);
        return .{ .assistant = .{
            .user = user,
            .assistant = assistant,
            .execution = execution,
            .provider_replay = replay,
        } };
    }
    if (std.mem.eql(u8, kind, "background_command")) {
        const shape = try exactVariantObject(
            value,
            &.{ "kind", "user", "log_path", "expect_url", "url", "background_record_id" },
            &.{ "kind", "user", "log_path", "expect_url", "url", "background_record_id", "assistant", "execution" },
        );
        const object = shape.object;
        const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
        errdefer session.freeUserTurn(alloc, user);
        const legacy_assistant = if (shape.extended)
            try parseOptionalDurableBytes(alloc, object.get("assistant") orelse return error.InvalidSessionFormat)
        else
            null;
        defer if (legacy_assistant) |owned| mem_utils.free(alloc, owned);
        const execution = if (shape.extended)
            try parseExecutionMemory(alloc, object.get("execution") orelse return error.InvalidSessionFormat)
        else
            session.ExecutionMemory{};
        errdefer session.freeExecutionMemory(alloc, execution);
        const log_path = try parseRequiredDurableBytes(alloc, object, "log_path");
        defer mem_utils.free(alloc, log_path);
        const url = try parseOptionalDurableBytes(alloc, object.get("url") orelse return error.InvalidSessionFormat);
        defer if (url) |owned| mem_utils.free(alloc, owned);
        _ = try requireBool(object, "expect_url");
        _ = try parseOptionalIdentifier(object.get("background_record_id") orelse return error.InvalidSessionFormat);
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
        const source = try requireObject(value);
        const has_execution = source.get("execution") != null;
        const has_presentation = source.get("cancelled_command") != null;
        const has_terminal_reason = source.get("terminal_reason") != null;
        const has_cancellation_origin = source.get("cancellation_origin") != null;
        const object = try exactInterruptedHistoryObject(
            value,
            has_execution,
            has_presentation,
            has_terminal_reason,
            has_cancellation_origin,
        );
        const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
        errdefer session.freeUserTurn(alloc, user);
        const assistant = try parseOptionalDurableBytes(alloc, object.get("assistant") orelse return error.InvalidSessionFormat);
        errdefer if (assistant) |owned| mem_utils.free(alloc, owned);
        const tool_call = try parseOptionalToolCall(alloc, object.get("tool_call") orelse return error.InvalidSessionFormat);
        errdefer if (tool_call) |call| session.freeToolCall(alloc, call);
        const completed_tool_names = try parseDurableBytesArray(
            alloc,
            object.get("completed_tool_names") orelse return error.InvalidSessionFormat,
        );
        errdefer session.freeCompletedToolNames(alloc, completed_tool_names);
        const terminal_reason = if (has_terminal_reason)
            try parseInterruptedTerminalReason(object, "terminal_reason")
        else
            types.InterruptedTerminalReason.cancelled;
        const cancellation_origin: types.CancellationOrigin = if (has_cancellation_origin)
            std.meta.stringToEnum(types.CancellationOrigin, try requireString(object, "cancellation_origin")) orelse
                return error.InvalidSessionFormat
        else
            .turn;
        const execution = if (has_execution)
            try parseExecutionMemory(alloc, object.get("execution") orelse return error.InvalidSessionFormat)
        else
            session.ExecutionMemory{};
        errdefer session.freeExecutionMemory(alloc, execution);
        const cancelled_command = if (has_presentation)
            try parseCancelledCommandPresentation(
                alloc,
                object.get("cancelled_command") orelse return error.InvalidSessionFormat,
            )
        else
            null;
        errdefer if (cancelled_command) |presentation| {
            types.freeCancelledCommandPresentation(alloc, presentation);
        };
        if (cancelled_command != null and
            (terminal_reason != .cancelled or
                tool_call == null or
                !try isCapturedCommandToolCall(alloc, tool_call.?)))
        {
            return error.InvalidSessionFormat;
        }
        return .{ .interrupted = .{
            .user = user,
            .assistant = assistant,
            .tool_call = tool_call,
            .completed_tool_names = completed_tool_names,
            .execution = execution,
            .cancelled_command = cancelled_command,
            .terminal_reason = terminal_reason,
            .cancellation_origin = cancellation_origin,
        } };
    }
    return error.InvalidSessionFormat;
}

fn isCapturedCommandToolCall(alloc: Allocator, call: types.ToolCall) !bool {
    return captured_command.isToolCall(alloc, call.name, call.arguments_json);
}

pub fn validateState(state: DurableSessionState) !void {
    return validateStateWithPermissionMigration(state, false);
}

fn validateStateWithPermissionMigration(
    state: DurableSessionState,
    allow_legacy_permission_state: bool,
) !void {
    try validateSessionId(state.id);
    try validateWorkspaceRoot(state.origin_workspace_root);
    try validateWorkspaceRoot(state.workspace_root);
    if (state.created_at_ms < 0 or state.updated_at_ms < 0) return error.InvalidDurableField;
    try validateConversationLanguage(state.conversation_language);
    try validateModel(state.preferences.model);
    if (state.context_history_start > state.history.len) return error.InvalidDurableField;
    if (state.last_subagent_work_id) |id| {
        session.validateWorkId(id) catch return error.InvalidDurableField;
    }
    for (state.history) |turn| {
        if (session.historyTurnWorkId(turn)) |id| {
            session.validateWorkId(id) catch return error.InvalidDurableField;
        }
        if (types.historyTurnSummary(turn)) |summary| {
            if (summary.started_at_ms < 0 or
                summary.completed_at_ms < summary.started_at_ms)
            {
                return error.InvalidDurableField;
            }
        }
    }
    if (state.usage) |usage| try session_usage.validateSnapshot(usage);
    if (allow_legacy_permission_state and state.permission_state.version == 1) {
        session_permission_state.validateSchema(state.permission_state, 1) catch
            return error.InvalidDurableField;
    } else {
        session_permission_state.validate(state.permission_state) catch
            return error.InvalidDurableField;
    }
    if (state.recovery_checkpoint) |checkpoint| {
        if (checkpoint.version != 2 or
            checkpoint.turn_id == 0 or
            checkpoint.max_provider_attempts == 0 or
            checkpoint.consumed_provider_attempts > checkpoint.max_provider_attempts or
            (checkpoint.outstanding_reservation and
                checkpoint.consumed_provider_attempts >= checkpoint.max_provider_attempts))
        {
            return error.InvalidDurableField;
        }
        try validateModel(checkpoint.authority.model);
        if (checkpoint.authority.credential_identity != null and
            checkpoint.authority.credential_source == null)
        {
            return error.InvalidDurableField;
        }
        if (checkpoint.authority.credential_source) |source| {
            if (!model_provider.authorizesCredential(checkpoint.authority.provider, source)) {
                return error.InvalidDurableField;
            }
        }
    }
}

pub fn parseConversationLanguage(raw: []const u8) !session.ConversationLanguage {
    try validateConversationLanguageBytes(raw);
    return session.ConversationLanguage.fromSlice(raw) catch error.InvalidDurableField;
}

fn writeState(writer: *std.Io.Writer, state: DurableSessionState) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, state.id);
    try writer.writeAll(",\"origin_workspace_root\":");
    try writeJsonString(writer, state.origin_workspace_root);
    try writer.writeAll(",\"workspace_root\":");
    try writeJsonString(writer, state.workspace_root);
    try writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{
        state.created_at_ms,
        state.updated_at_ms,
    });
    try writer.writeAll(",\"conversation_language\":");
    try writeJsonString(writer, state.conversation_language.view());
    try writer.writeAll(",\"preferences\":{\"model\":");
    try writeJsonString(writer, state.preferences.model);
    try writer.writeAll(",\"effort\":");
    try writeJsonString(writer, state.preferences.effort.label());
    try writer.print(",\"fast_mode\":{s}", .{
        if (state.preferences.fast_mode) "true" else "false",
    });
    try writer.writeAll(",\"provider\":");
    try std.json.Stringify.value(state.preferences.provider, .{}, writer);
    try writer.writeAll("},\"history\":[");
    for (state.history, 0..) |turn, i| {
        if (i > 0) try writer.writeByte(',');
        try writeHistoryTurn(writer, turn);
    }
    try writer.print("],\"total_input_tokens\":{d},\"total_output_tokens\":{d},\"context_history_start\":{d}", .{
        state.total_input_tokens,
        state.total_output_tokens,
        state.context_history_start,
    });
    try writer.writeAll(",\"permission_state\":");
    try writePermissionState(writer, state.permission_state);
    if (state.usage) |usage| {
        try writer.writeAll(",\"usage\":");
        try session_usage.writeSnapshot(writer, usage);
    }
    if (state.last_subagent_work_id) |id| {
        try writer.writeAll(",\"last_subagent_work_id\":");
        try writeJsonString(writer, id);
    }
    if (state.subagent_child) {
        try writer.writeAll(",\"subagent_child\":true");
    }
    if (state.recovery_checkpoint) |checkpoint| {
        try writer.writeAll(",\"recovery_checkpoint\":");
        try writeRecoveryCheckpoint(writer, checkpoint);
    }
    try writer.writeByte('}');
}

fn writePermissionState(
    writer: *std.Io.Writer,
    state: session_permission_state.State,
) !void {
    try writer.print("{{\"schema_version\":{d},\"next_generation\":{d},\"rules\":[", .{
        state.version,
        state.next_generation,
    });
    for (state.rules.items, 0..) |rule, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"kind\":", .{rule.id.value});
        try writeJsonString(writer, @tagName(rule.key.kind));
        try writer.writeAll(",\"canonical\":");
        try writeDurableBytes(writer, rule.key.canonical);
        try writer.writeAll(",\"display_identity\":");
        try writeDurableBytes(writer, rule.display_identity);
        try writer.writeAll(",\"decision\":");
        try writeJsonString(writer, @tagName(rule.decision));
        try writer.print(",\"generation\":{d}}}", .{rule.generation});
    }
    try writer.writeAll("]}");
}

fn parsePermissionState(
    alloc: Allocator,
    value: std.json.Value,
) !session_permission_state.State {
    const object = try exactObject(value, &.{
        "schema_version",
        "next_generation",
        "rules",
    });
    const version = std.math.cast(
        u8,
        try requireU64(object, "schema_version"),
    ) orelse return error.InvalidDurableField;
    const rules_value = object.get("rules") orelse
        return error.InvalidSessionFormat;
    if (rules_value != .array) return error.InvalidSessionFormat;

    var state: session_permission_state.State = .{
        .version = version,
        .next_generation = try requireU64(object, "next_generation"),
    };
    errdefer state.deinit(alloc);
    try state.rules.ensureTotalCapacity(
        alloc,
        @min(rules_value.array.items.len, session_permission_state.max_rules),
    );
    for (rules_value.array.items) |rule_value| {
        if (state.rules.items.len == session_permission_state.max_rules) {
            return error.InvalidDurableField;
        }
        const rule_object = try exactObject(rule_value, &.{
            "id",
            "kind",
            "canonical",
            "display_identity",
            "decision",
            "generation",
        });
        const kind = std.meta.stringToEnum(
            session_permission_state.RuleKey.Kind,
            try requireString(rule_object, "kind"),
        ) orelse return error.InvalidDurableField;
        const canonical = try parseRequiredDurableBytes(
            alloc,
            rule_object,
            "canonical",
        );
        errdefer alloc.free(canonical);
        const key = session_permission_state.RuleKey.init(
            kind,
            canonical,
        ) catch return error.InvalidDurableField;
        const display_identity = try parseRequiredDurableBytes(
            alloc,
            rule_object,
            "display_identity",
        );
        errdefer alloc.free(display_identity);
        const decision = std.meta.stringToEnum(
            session_permission_state.Decision,
            try requireString(rule_object, "decision"),
        ) orelse return error.InvalidDurableField;
        try state.rules.append(alloc, .{
            .id = .{ .value = try requireU64(rule_object, "id") },
            .key = key,
            .display_identity = display_identity,
            .decision = decision,
            .generation = try requireU64(rule_object, "generation"),
        });
    }
    session_permission_state.validateSchema(state, version) catch
        return error.InvalidDurableField;
    return state;
}

pub fn writeRecoveryCheckpoint(writer: *std.Io.Writer, checkpoint: RecoveryCheckpoint) !void {
    if (checkpoint.disposition == .history_only) return error.InvalidDurableField;
    try writer.print("{{\"version\":{d},\"turn_id\":{d},\"user\":", .{
        checkpoint.version,
        checkpoint.turn_id,
    });
    try writeUserTurn(writer, checkpoint.user);
    try writer.writeAll(",\"assistant_source\":");
    try writeDurableBytes(writer, checkpoint.assistant_source);
    try writer.writeAll(",\"execution\":");
    try writeExecutionMemoryJson(writer, checkpoint.execution, .durable);
    try writer.writeAll(",\"cause\":");
    try writeJsonString(writer, @tagName(checkpoint.cause));
    try writer.writeAll(",\"action\":");
    try writeJsonString(writer, @tagName(checkpoint.action));
    try writer.writeAll(",\"tool_state\":");
    try writeJsonString(writer, @tagName(checkpoint.tool_state));
    try writer.writeAll(",\"authority\":{\"provider\":");
    try std.json.Stringify.value(checkpoint.authority.provider, .{}, writer);
    try writer.writeAll(",\"model\":");
    try writeDurableBytes(writer, checkpoint.authority.model);
    try writer.writeAll(",\"credential_source\":");
    if (checkpoint.authority.credential_source) |source| {
        try writeJsonString(writer, @tagName(source));
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"credential_identity\":");
    if (checkpoint.authority.credential_identity) |identity| {
        const hex = std.fmt.bytesToHex(identity.bytes, .lower);
        try writeJsonString(writer, &hex);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
    try writer.print(",\"requested_fast_mode\":{s},\"fast_mode\":{s}", .{
        if (checkpoint.requested_fast_mode) "true" else "false",
        if (checkpoint.fast_mode) "true" else "false",
    });
    try writer.print(",\"max_provider_attempts\":{d},\"consumed_provider_attempts\":{d},\"outstanding_reservation\":{s}}}", .{
        checkpoint.max_provider_attempts,
        checkpoint.consumed_provider_attempts,
        if (checkpoint.outstanding_reservation) "true" else "false",
    });
}

const DecodedStateTail = struct {
    total_input_tokens: u64,
    total_output_tokens: u64,
    context_history_start: usize,
    permission_state: session_permission_state.State,
    usage: ?session_usage.Snapshot,
    last_subagent_work_id: ?[]u8,
    subagent_child: bool,
    recovery_checkpoint: ?RecoveryCheckpoint,

    fn deinit(self: *DecodedStateTail, alloc: Allocator) void {
        if (self.recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
        if (self.last_subagent_work_id) |work_id| mem_utils.free(alloc, work_id);
        if (self.usage) |*snapshot| snapshot.deinit(alloc);
        self.permission_state.deinit(alloc);
        self.* = undefined;
    }
};

fn decodeHistory(
    alloc: Allocator,
    json_reader: *std.json.Reader,
    limits: DecodeLimits,
) ![]session.HistoryTurn {
    try expectKey(json_reader, alloc, "history");
    try expectToken(try json_reader.next(), .array_begin);
    var history: std.ArrayList(session.HistoryTurn) = .empty;
    errdefer {
        for (history.items) |turn| session.freeHistoryTurn(alloc, turn);
        mem_utils.deinitList(alloc, &history);
    }
    while (try json_reader.peekNextTokenType() != .array_end) {
        if (history.items.len == limits.max_history_turns) {
            return error.InvalidSessionFormat;
        }
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const value = try std.json.Value.jsonParse(arena.allocator(), json_reader, .{
            .max_value_len = limits.max_value_bytes,
            .allocate = .alloc_always,
            .parse_numbers = false,
        });
        const turn = try parseHistoryTurn(alloc, value);
        errdefer session.freeHistoryTurn(alloc, turn);
        try history.append(alloc, turn);
    }
    try expectToken(try json_reader.next(), .array_end);
    return history.toOwnedSlice(alloc);
}

fn decodeStateTail(
    alloc: Allocator,
    json_reader: *std.json.Reader,
    limits: DecodeLimits,
    legacy_usage: bool,
) !DecodedStateTail {
    try expectKey(json_reader, alloc, "total_input_tokens");
    const total_input_tokens = try readU64(json_reader, alloc);
    try expectKey(json_reader, alloc, "total_output_tokens");
    const total_output_tokens = try readU64(json_reader, alloc);
    var context_history_start: usize = 0;
    var context_seen = false;
    var permission_state: session_permission_state.State = .{};
    errdefer permission_state.deinit(alloc);
    var permission_state_seen = false;
    var usage: ?session_usage.Snapshot = null;
    errdefer if (usage) |*snapshot| snapshot.deinit(alloc);
    var usage_seen = false;
    var last_subagent_work_id: ?[]u8 = null;
    errdefer if (last_subagent_work_id) |work_id| mem_utils.free(alloc, work_id);
    var subagent_child = false;
    var subagent_child_seen = false;
    var recovery_checkpoint: ?RecoveryCheckpoint = null;
    errdefer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
    while (try json_reader.peekNextTokenType() != .object_end) {
        const key = try readStringOwned(json_reader, alloc, 64);
        defer mem_utils.free(alloc, key);
        if (std.mem.eql(u8, key, "context_history_start")) {
            if (context_seen or permission_state_seen or usage_seen or last_subagent_work_id != null or subagent_child_seen or recovery_checkpoint != null) {
                return error.InvalidSessionFormat;
            }
            const raw = try readU64(json_reader, alloc);
            context_history_start = std.math.cast(usize, raw) orelse
                return error.InvalidSessionFormat;
            context_seen = true;
        } else if (std.mem.eql(u8, key, "permission_state")) {
            if (permission_state_seen or usage_seen or last_subagent_work_id != null or subagent_child_seen or recovery_checkpoint != null) {
                return error.InvalidSessionFormat;
            }
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const value = try std.json.Value.jsonParse(arena.allocator(), json_reader, .{
                .max_value_len = limits.max_value_bytes,
                .allocate = .alloc_always,
                .parse_numbers = false,
            });
            permission_state = try parsePermissionState(alloc, value);
            permission_state_seen = true;
        } else if (std.mem.eql(u8, key, "usage")) {
            if (usage_seen or last_subagent_work_id != null or subagent_child_seen or recovery_checkpoint != null) return error.InvalidSessionFormat;
            const parse_limit = @min(
                limits.max_value_bytes,
                session_usage.max_snapshot_bytes,
            );
            const parse_buffer = try alloc.alloc(u8, parse_limit);
            defer mem_utils.free(alloc, parse_buffer);
            var fixed = std.heap.FixedBufferAllocator.init(parse_buffer);
            const value = try std.json.Value.jsonParse(fixed.allocator(), json_reader, .{
                .max_value_len = parse_limit,
                .allocate = .alloc_always,
                .parse_numbers = false,
            });
            usage = if (legacy_usage)
                try session_usage.parseLegacySnapshotValue(alloc, value)
            else
                try session_usage.parseSnapshotValue(alloc, value);
            usage_seen = true;
        } else if (std.mem.eql(u8, key, "last_subagent_work_id")) {
            if (last_subagent_work_id != null or subagent_child_seen or recovery_checkpoint != null) return error.InvalidSessionFormat;
            last_subagent_work_id = try readStringOwned(json_reader, alloc, 128);
        } else if (std.mem.eql(u8, key, "subagent_child")) {
            if (subagent_child_seen or recovery_checkpoint != null) return error.InvalidSessionFormat;
            subagent_child = try readBool(json_reader);
            if (!subagent_child) return error.InvalidDurableField;
            subagent_child_seen = true;
        } else if (std.mem.eql(u8, key, "recovery_checkpoint")) {
            if (recovery_checkpoint != null) return error.InvalidSessionFormat;
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const value = try std.json.Value.jsonParse(arena.allocator(), json_reader, .{
                .max_value_len = limits.max_value_bytes,
                .allocate = .alloc_always,
                .parse_numbers = false,
            });
            recovery_checkpoint = try parseRecoveryCheckpoint(alloc, value);
        } else return error.InvalidSessionFormat;
    }
    try expectToken(try json_reader.next(), .object_end);
    try expectToken(try json_reader.next(), .end_of_document);
    return .{
        .total_input_tokens = total_input_tokens,
        .total_output_tokens = total_output_tokens,
        .context_history_start = context_history_start,
        .permission_state = permission_state,
        .usage = usage,
        .last_subagent_work_id = last_subagent_work_id,
        .subagent_child = subagent_child,
        .recovery_checkpoint = recovery_checkpoint,
    };
}

fn decodeStateImpl(alloc: Allocator, source: *std.Io.Reader, limits: DecodeLimits, legacy_usage: bool) !DurableSessionState {
    var json_reader = std.json.Reader.init(alloc, source);
    defer json_reader.deinit();

    try expectToken(try json_reader.next(), .object_begin);
    try expectKey(&json_reader, alloc, "id");
    const id = try readStringOwned(&json_reader, alloc, 255);
    errdefer mem_utils.free(alloc, id);
    try expectKey(&json_reader, alloc, "origin_workspace_root");
    const origin_workspace_root = try readStringOwned(&json_reader, alloc, std.Io.Dir.max_path_bytes);
    errdefer mem_utils.free(alloc, origin_workspace_root);
    try expectKey(&json_reader, alloc, "workspace_root");
    const workspace_root = try readStringOwned(&json_reader, alloc, std.Io.Dir.max_path_bytes);
    errdefer mem_utils.free(alloc, workspace_root);
    try expectKey(&json_reader, alloc, "created_at_ms");
    const created_at_ms = try readI64(&json_reader, alloc);
    try expectKey(&json_reader, alloc, "updated_at_ms");
    const updated_at_ms = try readI64(&json_reader, alloc);
    try expectKey(&json_reader, alloc, "conversation_language");
    const language_raw = try readStringOwned(&json_reader, alloc, session.ConversationLanguage.max_len);
    defer mem_utils.free(alloc, language_raw);
    const conversation_language = try parseConversationLanguage(language_raw);

    try expectKey(&json_reader, alloc, "preferences");
    var preferences = preferences: {
        var buffer: [8 * 1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        const value = std.json.Value.jsonParse(fixed.allocator(), &json_reader, .{
            .max_value_len = 1024,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.InvalidSessionFormat,
            else => return err,
        };
        break :preferences try parse_preferences(alloc, value);
    };
    errdefer preferences.deinit(alloc);

    const history = try decodeHistory(alloc, &json_reader, limits);
    errdefer session.freeHistoryTurnSlice(alloc, history);
    var tail = try decodeStateTail(alloc, &json_reader, limits, legacy_usage);
    errdefer tail.deinit(alloc);
    const state = DurableSessionState{
        .id = id,
        .origin_workspace_root = origin_workspace_root,
        .workspace_root = workspace_root,
        .created_at_ms = created_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = conversation_language,
        .preferences = preferences,
        .history = history,
        .context_history_start = tail.context_history_start,
        .total_input_tokens = tail.total_input_tokens,
        .total_output_tokens = tail.total_output_tokens,
        .permission_state = tail.permission_state,
        .last_subagent_work_id = tail.last_subagent_work_id,
        .subagent_child = tail.subagent_child,
        .usage = tail.usage,
        .recovery_checkpoint = tail.recovery_checkpoint,
    };
    try validateStateWithPermissionMigration(state, true);
    return state;
}

pub fn parseRecoveryCheckpoint(alloc: Allocator, value: std.json.Value) !RecoveryCheckpoint {
    const raw_object = try requireObject(value);
    const version = try requireU64(raw_object, "version");
    const legacy_route = raw_object.contains("route_identity");
    const object = if (legacy_route) legacy: {
        try validate_legacy_recovery_route(raw_object.get("route_identity").?, version);
        const delivery = try requireString(raw_object, "delivery");
        if (!std.mem.eql(u8, delivery, "possibly_sent") and !std.mem.eql(u8, delivery, "definitely_unsent")) return error.InvalidDurableField;
        break :legacy try exactObject(value, &.{
            "version",                    "route_identity",          "delivery",   "turn_id",     "user",                "assistant_source", "execution",
            "cause",                      "action",                  "tool_state", "route_model", "requested_fast_mode", "fast_mode",        "max_provider_attempts",
            "consumed_provider_attempts", "outstanding_reservation",
        });
    } else switch (version) {
        1 => if (raw_object.get("route_provider") != null)
            try exactObject(value, &.{
                "version",             "turn_id",   "user",                  "assistant_source",           "execution",
                "cause",               "action",    "tool_state",            "route_model",                "route_provider",
                "requested_fast_mode", "fast_mode", "max_provider_attempts", "consumed_provider_attempts", "outstanding_reservation",
            })
        else
            try exactObject(value, &.{
                "version",   "turn_id",               "user",                       "assistant_source",        "execution",
                "cause",     "action",                "tool_state",                 "route_model",             "requested_fast_mode",
                "fast_mode", "max_provider_attempts", "consumed_provider_attempts", "outstanding_reservation",
            }),
        2 => try exactObject(value, &.{
            "version",   "turn_id",               "user",                       "assistant_source",        "execution",
            "cause",     "action",                "tool_state",                 "authority",               "requested_fast_mode",
            "fast_mode", "max_provider_attempts", "consumed_provider_attempts", "outstanding_reservation",
        }),
        else => return error.InvalidDurableField,
    };
    const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
    errdefer session.freeUserTurn(alloc, user);
    const assistant_source = try parseDurableBytes(alloc, object.get("assistant_source") orelse return error.InvalidSessionFormat);
    errdefer alloc.free(assistant_source);
    const execution = try parseExecutionMemory(alloc, object.get("execution") orelse return error.InvalidSessionFormat);
    errdefer session.freeExecutionMemory(alloc, execution);
    if (legacy_route) return error.InvalidSessionFormat;
    const authority = if (version == 1) legacy: {
        const model = try parseDurableBytes(alloc, object.get("route_model") orelse return error.InvalidSessionFormat);
        break :legacy TurnAuthority{
            .provider = if (object.get("route_provider")) |provider_value| blk: {
                if (provider_value != .string) return error.InvalidDurableField;
                break :blk model_provider.parse(provider_value.string) orelse return error.InvalidDurableField;
            } else return error.InvalidDurableField,
            .model = model,
        };
    } else try parseTurnAuthority(alloc, object.get("authority") orelse return error.InvalidSessionFormat);
    errdefer {
        var owned_authority = authority;
        owned_authority.deinit(alloc);
    }
    const max_provider_attempts = std.math.cast(usize, try requireU64(object, "max_provider_attempts")) orelse
        return error.InvalidDurableField;
    const consumed_provider_attempts = std.math.cast(usize, try requireU64(object, "consumed_provider_attempts")) orelse
        return error.InvalidDurableField;
    return .{
        .version = 2,
        .disposition = if (legacy_route) .history_only else .continuable,
        .turn_id = try requireU64(object, "turn_id"),
        .user = user,
        .assistant_source = assistant_source,
        .execution = execution,
        .cause = std.meta.stringToEnum(types.ModelRecoveryCause, try requireString(object, "cause")) orelse
            return error.InvalidDurableField,
        .action = std.meta.stringToEnum(types.ModelRecoveryAction, try requireString(object, "action")) orelse
            return error.InvalidDurableField,
        .tool_state = std.meta.stringToEnum(RecoveryToolState, try requireString(object, "tool_state")) orelse
            return error.InvalidDurableField,
        .authority = authority,
        .requested_fast_mode = try requireBool(object, "requested_fast_mode"),
        .fast_mode = try requireBool(object, "fast_mode"),
        .max_provider_attempts = max_provider_attempts,
        .consumed_provider_attempts = consumed_provider_attempts,
        .outstanding_reservation = try requireBool(object, "outstanding_reservation"),
    };
}

fn validate_legacy_recovery_route(value: std.json.Value, version: u64) !void {
    const object = switch (version) {
        2 => try exactObject(value, &.{ "connection_id", "adapter_kind", "permission_review_model_id" }),
        3 => try exactObject(value, &.{ "connection_id", "adapter_kind", "permission_review_model_id", "vision_model_id", "subagent_model_id" }),
        4 => try exactObject(value, &.{ "version", "connection_id", "adapter_kind", "endpoint", "protocol", "credential_ref", "permission_review_model_id", "vision_model_id", "subagent_model_id" }),
        else => return error.InvalidDurableField,
    };
    if (!std.mem.eql(u8, try requireString(object, "connection_id"), "vercel") or
        !std.mem.eql(u8, try requireString(object, "adapter_kind"), "vercel_ai_gateway")) return error.InvalidDurableField;
    if (version == 4 and (try requireU64(object, "version") != 1 or
        !std.mem.eql(u8, try requireString(object, "protocol"), "vercel_ai_gateway"))) return error.InvalidDurableField;
    var fields = object.iterator();
    while (fields.next()) |field| {
        if (std.mem.eql(u8, field.key_ptr.*, "version")) continue;
        if (field.value_ptr.* != .string or field.value_ptr.string.len > 4096 or
            !std.unicode.utf8ValidateSlice(field.value_ptr.string)) return error.InvalidDurableField;
    }
}

fn parseTurnAuthority(alloc: Allocator, value: std.json.Value) !TurnAuthority {
    const object = try exactObject(value, &.{
        "provider",
        "model",
        "credential_source",
        "credential_identity",
    });
    const provider = model_provider.parse_saved(object.get("provider").?) catch return error.InvalidDurableField;
    const model = try parseDurableBytes(alloc, object.get("model") orelse return error.InvalidSessionFormat);
    errdefer alloc.free(model);
    const credential_source = if (object.get("credential_source")) |source| switch (source) {
        .null => null,
        .string => |text| types.parseRuntimeCredentialSource(text) orelse return error.InvalidDurableField,
        else => return error.InvalidDurableField,
    } else return error.InvalidSessionFormat;
    const credential_identity = if (object.get("credential_identity")) |identity| switch (identity) {
        .null => null,
        .string => |hex| identity: {
            var bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidDurableField;
            const canonical = std.fmt.bytesToHex(bytes, .lower);
            if (!std.mem.eql(u8, &canonical, hex)) return error.InvalidDurableField;
            break :identity credential_authority.Identity{ .bytes = bytes };
        },
        else => return error.InvalidDurableField,
    } else return error.InvalidSessionFormat;
    if (credential_identity != null and credential_source == null) {
        return error.InvalidDurableField;
    }
    return .{
        .provider = provider,
        .model = model,
        .credential_source = credential_source,
        .credential_identity = credential_identity,
    };
}

fn writeUserTurn(writer: *std.Io.Writer, user: session.UserTurn) !void {
    try writer.writeAll("{\"text\":");
    try writeDurableBytes(writer, user.text);
    try writer.writeAll(",\"images\":[");
    for (user.images, 0..) |image, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"path\":", .{image.id});
        try writeDurableBytes(writer, image.path);
        try writer.writeAll(",\"media_type\":");
        try writeDurableBytes(writer, image.media_type);
        try writer.writeAll(",\"snapshot_path\":");
        try writeSnapshotLocator(writer, image.snapshot_path);
        try writer.writeAll(",\"snapshot_sha256\":");
        try writeOptionalDurableBytes(writer, image.snapshot_sha256);
        // Inline image bytes appear only for sessions without a filesystem
        // snapshot backend, so durable sessions keep their exact format.
        if (image.inline_data) |inline_data| {
            try writer.writeAll(",\"inline_data\":");
            try writeDurableBytes(writer, inline_data);
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
    if (user.work_id) |work_id| {
        try writer.writeAll(",\"work_id\":");
        try writeJsonString(writer, work_id);
    }
    try writer.writeByte('}');
}

fn writeSnapshotLocator(writer: *std.Io.Writer, value: ?[]const u8) !void {
    const path = value orelse {
        try writer.writeAll("null");
        return;
    };
    var locator_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const locator = try session.projectSnapshotLocator(&locator_buffer, path);
    try writeDurableBytes(writer, locator);
}

pub const ExecutionMemoryJsonFormat = enum {
    durable,
    presentation,
};

pub noinline fn writeExecutionMemoryJson(
    writer: *std.Io.Writer,
    execution: session.ExecutionMemory,
    format: ExecutionMemoryJsonFormat,
) !void {
    try writer.writeAll(if (format == .durable)
        "{\"schema_version\":10,\"tool_steps\":["
    else
        "{\"schema_version\":3,\"tool_steps\":[");
    for (execution.tool_steps, 0..) |step, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"assistant\":");
        try writeOptionalExecutionBytes(writer, step.assistant, format);
        if (format == .durable) {
            try writer.writeAll(",\"provider_replay\":");
            try std.json.Stringify.value(step.provider_replay, .{}, writer);
        }
        try writer.writeAll(",\"tool_calls\":[");
        for (step.tool_calls, 0..) |tool_call, call_index| {
            if (call_index > 0) try writer.writeByte(',');
            try writeExecutionToolCall(writer, tool_call, format);
        }
        try writer.writeAll("],\"tool_results\":[");
        for (step.tool_results, 0..) |result, result_index| {
            if (result_index > 0) try writer.writeByte(',');
            try writeExecutionToolResult(writer, result, format);
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("],\"files\":[");
    for (execution.files, 0..) |file, i| {
        if (i > 0) try writer.writeByte(',');
        try writeExecutionFileEvidence(writer, file, format);
    }
    try writer.writeAll("],\"steering\":[");
    for (execution.steering, 0..) |steering, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"text\":");
        try writeExecutionBytes(writer, steering.text, format);
        try writer.writeAll(",\"assistant_prefix\":");
        try writeOptionalExecutionBytes(writer, steering.assistant_prefix, format);
        try writer.print(",\"after_tool_step_count\":{d}}}", .{steering.after_tool_step_count});
    }
    if (format == .durable) {
        try writer.writeAll("],\"turn_summary\":");
        if (execution.turn_summary) |summary| {
            try writeTurnSummary(writer, summary);
        } else {
            try writer.writeAll("null");
        }
    } else {
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

fn hasDurableExecutionMemory(execution: session.ExecutionMemory) bool {
    return !execution.isEmpty() or execution.turn_summary != null;
}

fn writeTurnSummary(writer: *std.Io.Writer, summary: types.TurnSummary) !void {
    try writer.print(
        "{{\"started_at_ms\":{d},\"completed_at_ms\":{d},\"thinking_duration_ms\":{d},\"turn_duration_ms\":{d},\"token_progress\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"input_exact\":{s},\"output_exact\":{s}}}}}",
        .{
            summary.started_at_ms,
            summary.completed_at_ms,
            summary.thinking_duration_ms,
            summary.turn_duration_ms,
            summary.token_progress.input_tokens,
            summary.token_progress.output_tokens,
            if (summary.token_progress.input_exact) "true" else "false",
            if (summary.token_progress.output_exact) "true" else "false",
        },
    );
}

fn writeExecutionBytes(
    writer: *std.Io.Writer,
    bytes: []const u8,
    format: ExecutionMemoryJsonFormat,
) !void {
    if (format == .durable) {
        try writeDurableBytes(writer, bytes);
    } else {
        try writeJsonString(writer, bytes);
    }
}

fn writeOptionalExecutionBytes(
    writer: *std.Io.Writer,
    value: ?[]const u8,
    format: ExecutionMemoryJsonFormat,
) !void {
    if (value) |bytes| {
        try writeExecutionBytes(writer, bytes, format);
    } else {
        try writer.writeAll("null");
    }
}

fn writeExecutionToolCall(
    writer: *std.Io.Writer,
    tool_call: session.ToolCall,
    format: ExecutionMemoryJsonFormat,
) !void {
    try writer.writeAll("{\"id\":");
    try writeExecutionBytes(writer, tool_call.id, format);
    try writer.writeAll(",\"name\":");
    try writeExecutionBytes(writer, tool_call.name, format);
    try writer.writeAll(",\"arguments_json\":");
    try writeExecutionBytes(writer, tool_call.arguments_json, format);
    try writer.writeAll(",\"provider_result\":");
    try writeOptionalExecutionBytes(writer, tool_call.provider_result, format);
    try writer.writeByte('}');
}

fn writeExecutionToolResult(
    writer: *std.Io.Writer,
    result: session.PersistedToolResult,
    format: ExecutionMemoryJsonFormat,
) !void {
    if (format == .durable and
        result.review_feedback and
        (result.status != .failure or result.provider_native))
    {
        return error.InvalidSessionFormat;
    }
    try writer.writeAll("{\"tool_call_id\":");
    try writeExecutionBytes(writer, result.tool_call_id, format);
    try writer.writeAll(",\"tool_name\":");
    try writeExecutionBytes(writer, result.tool_name, format);
    try writer.writeAll(",\"status\":");
    try writeJsonString(writer, @tagName(result.status));
    try writer.writeAll(",\"output\":");
    try writeExecutionBytes(writer, result.output, format);
    if (format == .durable or result.output_handle != null) {
        try writer.writeAll(",\"output_handle\":");
        try writeOptionalExecutionBytes(writer, result.output_handle, format);
    }
    if (format == .durable or result.preview != null) {
        try writer.writeAll(",\"preview\":");
        try writeOptionalExecutionBytes(writer, result.preview, format);
    }
    try writer.print(
        ",\"output_bytes\":{d},\"stored_output_bytes\":{d},\"truncated\":{s},\"provider_native\":{s}",
        .{
            result.output_bytes,
            result.stored_output_bytes,
            if (result.truncated) "true" else "false",
            if (result.provider_native) "true" else "false",
        },
    );
    if (format == .durable) {
        try writer.print(",\"review_feedback\":{s}", .{if (result.review_feedback) "true" else "false"});
    }
    try writer.print(",\"created_at_ms\":{d}", .{result.created_at_ms});
    try writer.writeAll(",\"permission_feedback\":[");
    for (result.permission_feedback, 0..) |feedback, i| {
        if (i > 0) try writer.writeByte(',');
        try writeExecutionBytes(writer, feedback, format);
    }
    if (result.committed_file_presentation) |presentation| {
        try writer.writeAll("],\"committed_file_presentation\":");
        try writeExecutionFilePresentation(writer, presentation, format);
    } else if (format == .durable) {
        try writer.writeAll("],\"committed_file_presentation\":null");
    } else {
        try writer.writeByte(']');
    }
    if (format == .durable) {
        try writer.writeAll(",\"command_output_replay\":");
        try writeOptionalCommandOutputReplay(writer, result.command_output_replay);
        try writer.writeAll(",\"command_process_presentation\":");
        try writeOptionalCommandProcessPresentation(
            writer,
            result.command_process_presentation,
        );
        try writer.writeAll(",\"terminal_action_presentation\":");
        try writeOptionalTerminalActionPresentation(
            writer,
            result.terminal_action_presentation,
        );
        if (result.tool_image_handle) |handle| {
            try writer.writeAll(",\"tool_image_handle\":");
            try writeDurableBytes(writer, handle);
        } else if (result.tool_images.len > 0) {
            try writer.writeAll(",\"tool_images\":");
            writePersistedToolImages(writer, result.tool_images) catch |err| switch (err) {
                error.InvalidImage => return error.InvalidSessionFormat,
                else => |write_err| return write_err,
            };
        }
    }
    try writer.writeByte('}');
}

fn writeCancelledCommandPresentation(
    writer: *std.Io.Writer,
    presentation: session.CancelledCommandPresentation,
) !void {
    try writer.writeAll("{\"output_replay\":");
    try writeOptionalCommandOutputReplay(writer, presentation.output_replay);
    try writer.writeAll(",\"command_artifact_handle\":");
    try writeOptionalDurableBytes(writer, presentation.command_artifact_handle);
    try writer.writeByte('}');
}

fn parseCancelledCommandPresentation(
    alloc: Allocator,
    value: std.json.Value,
) !session.CancelledCommandPresentation {
    const object = try exactObject(value, &.{
        "output_replay",
        "command_artifact_handle",
    });
    const output_replay = try parseOptionalCommandOutputReplay(
        alloc,
        object.get("output_replay") orelse return error.InvalidSessionFormat,
    );
    errdefer if (output_replay) |replay| types.freeCommandOutputReplay(alloc, replay);
    return .{
        .output_replay = output_replay,
        .command_artifact_handle = try parseOptionalDurableBytes(
            alloc,
            object.get("command_artifact_handle") orelse return error.InvalidSessionFormat,
        ),
    };
}

fn writeOptionalCommandOutputReplay(
    writer: *std.Io.Writer,
    replay: ?types.CommandOutputReplay,
) !void {
    const value = replay orelse {
        try writer.writeAll("null");
        return;
    };
    switch (value) {
        .available => |descriptor| {
            try writer.writeAll("{\"kind\":\"available\",\"handle\":");
            try writeDurableBytes(writer, descriptor.handle);
            try writer.print(",\"framed_bytes\":{d}}}", .{descriptor.framed_bytes});
        },
        .unavailable => try writer.writeAll("{\"kind\":\"unavailable\"}"),
    }
}

fn writeOptionalCommandProcessPresentation(
    writer: *std.Io.Writer,
    presentation: ?types.CommandProcessPresentation,
) !void {
    const value = presentation orelse {
        try writer.writeAll("null");
        return;
    };
    switch (value) {
        .exit_code => |exit_code| try writer.print(
            "{{\"kind\":\"exit_code\",\"value\":{d}}}",
            .{exit_code},
        ),
        .signal => |signal| try writer.print(
            "{{\"kind\":\"signal\",\"value\":{d}}}",
            .{signal},
        ),
        .timed_out => try writer.writeAll("{\"kind\":\"timed_out\",\"value\":null}"),
        .output_capture_failed => try writer.writeAll("{\"kind\":\"output_capture_failed\",\"value\":null}"),
    }
}

fn writeOptionalTerminalActionPresentation(
    writer: *std.Io.Writer,
    presentation: ?types.TerminalActionPresentation,
) !void {
    const value = presentation orelse {
        try writer.writeAll("null");
        return;
    };
    switch (value) {
        .returned => |returned| {
            try writer.writeAll("{\"kind\":\"returned\",\"outcome\":");
            try writeTerminalReturnPresentation(writer, returned);
            try writer.writeByte('}');
        },
        .failed => |failed| {
            try writer.writeAll("{\"kind\":\"failed\",\"code\":");
            try writeJsonString(writer, @tagName(failed));
            try writer.writeByte('}');
        },
    }
}

fn writeTerminalReturnPresentation(
    writer: *std.Io.Writer,
    outcome: types.TerminalReturnPresentation,
) !void {
    switch (outcome) {
        .started, .condition_met, .safety_ceiling, .cancelled => {
            try writer.writeAll("{\"kind\":");
            try writeJsonString(writer, @tagName(outcome));
            try writer.writeAll(",\"value\":null}");
        },
        .exited => |code| try writer.print(
            "{{\"kind\":\"exited\",\"value\":{d}}}",
            .{code},
        ),
        .signal => |signal| try writer.print(
            "{{\"kind\":\"signal\",\"value\":{d}}}",
            .{signal},
        ),
    }
}

fn writeExecutionFilePresentation(
    writer: *std.Io.Writer,
    presentation: types.CommittedFilePresentation,
    format: ExecutionMemoryJsonFormat,
) !void {
    if (!types.committedFilePresentationContentSourceValid(presentation)) {
        return error.InvalidSessionFormat;
    }
    try writer.writeAll("{\"path\":");
    try writeExecutionBytes(writer, presentation.path, format);
    try writer.writeAll(",\"kind\":");
    try writeJsonString(writer, @tagName(presentation.kind));
    try writer.writeAll(",\"lines\":[");
    for (presentation.lines, 0..) |line, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"kind\":");
        try writeJsonString(writer, @tagName(line.kind));
        try writer.writeAll(",\"old_line\":");
        try writeOptionalU32(writer, line.old_line);
        try writer.writeAll(",\"new_line\":");
        try writeOptionalU32(writer, line.new_line);
        try writer.writeAll(",\"text\":");
        try writeExecutionBytes(writer, line.text, format);
        try writer.writeByte('}');
    }
    try writer.print(
        "],\"additions\":{d},\"deletions\":{d},\"truncated\":{s},\"previous_content\":",
        .{
            presentation.additions,
            presentation.deletions,
            if (presentation.truncated) "true" else "false",
        },
    );
    try writeOptionalExecutionBytes(writer, presentation.previous_content, format);
    try writer.writeAll(",\"after_content\":");
    try writeOptionalExecutionBytes(writer, presentation.after_content, format);
    try writer.writeAll(",\"lifecycle_id\":");
    if (presentation.lifecycle_id) |lifecycle_id| {
        try writer.print("{{\"turn_id\":{d},\"call_id\":", .{lifecycle_id.turn_id});
        try writeExecutionBytes(writer, lifecycle_id.call_id, format);
        try writer.writeByte('}');
    } else {
        try writer.writeAll("null");
    }
    // Durable records omit an absent handle for compatibility with the
    // shipped 9-key shape. Presentation JSON always includes the key.
    if (presentation.content_handle) |handle| {
        try writer.writeAll(",\"content_handle\":");
        try writeExecutionBytes(writer, handle, format);
    } else if (format == .presentation) {
        try writer.writeAll(",\"content_handle\":null");
    }
    try writer.writeByte('}');
}

fn writeExecutionFileEvidence(
    writer: *std.Io.Writer,
    file: session.FileEvidence,
    format: ExecutionMemoryJsonFormat,
) !void {
    try writer.writeAll("{\"path\":");
    try writeExecutionBytes(writer, file.path, format);
    try writer.writeAll(",\"new_path\":");
    try writeOptionalExecutionBytes(writer, file.new_path, format);
    try writer.writeAll(",\"tool_call_id\":");
    try writeExecutionBytes(writer, file.tool_call_id, format);
    try writer.writeAll(",\"tool_name\":");
    try writeExecutionBytes(writer, file.tool_name, format);
    try writer.writeAll(",\"action\":");
    try writeJsonString(writer, @tagName(file.action));
    try writer.writeAll(",\"status\":");
    try writeJsonString(writer, @tagName(file.status));
    try writer.print(",\"model_view_covers_full_file\":{s},\"stale\":{s}", .{
        if (file.model_view_covers_full_file) "true" else "false",
        if (file.stale) "true" else "false",
    });
    try writer.writeByte('}');
}

fn parseUserTurn(alloc: Allocator, value: std.json.Value) !session.UserTurn {
    const source = try requireObject(value);
    const object = if (source.count() == 2)
        try exactObject(value, &.{ "text", "images" })
    else
        try exactObject(value, &.{ "text", "images", "work_id" });
    const text = try parseRequiredDurableBytes(alloc, object, "text");
    errdefer mem_utils.free(alloc, text);
    const work_id = if (object.get("work_id")) |_|
        try alloc.dupe(u8, try requireString(object, "work_id"))
    else
        null;
    errdefer if (work_id) |id| mem_utils.free(alloc, id);
    if (work_id) |id| session.validateWorkId(id) catch return error.InvalidSessionFormat;
    const images_value = object.get("images") orelse return error.InvalidSessionFormat;
    if (images_value != .array) return error.InvalidSessionFormat;
    if (images_value.array.items.len == 0) return .{ .text = text, .work_id = work_id };

    const images = try alloc.alloc(session.ImageAttachment, images_value.array.items.len);
    errdefer mem_utils.free(alloc, images);
    var parsed_count: usize = 0;
    errdefer {
        for (images[0..parsed_count]) |image| {
            types.freeImageAttachment(alloc, image);
        }
    }
    for (images_value.array.items, 0..) |image_value, i| {
        const image = try imageAttachmentObject(image_value);
        const path = try parseRequiredDurableBytes(alloc, image, "path");
        errdefer mem_utils.free(alloc, path);
        const media_type = try parseRequiredDurableBytes(alloc, image, "media_type");
        errdefer mem_utils.free(alloc, media_type);
        const snapshot_path = try parseOptionalDurableBytes(
            alloc,
            image.get("snapshot_path") orelse .null,
        );
        errdefer if (snapshot_path) |path_bytes| mem_utils.free(alloc, path_bytes);
        const snapshot_sha256 = try parseOptionalDurableBytes(
            alloc,
            image.get("snapshot_sha256") orelse .null,
        );
        errdefer if (snapshot_sha256) |sha256_bytes| mem_utils.free(alloc, sha256_bytes);
        const inline_data = try parseOptionalDurableBytes(alloc, image.get("inline_data") orelse .null);
        errdefer if (inline_data) |inline_bytes| mem_utils.free(alloc, inline_bytes);
        if (inline_data) |inline_bytes| {
            // Inline images carry their own bytes: no snapshot file, but the
            // digest stays so request-time verification is unchanged.
            if (snapshot_path != null or snapshot_sha256 == null) return error.InvalidSessionFormat;
            try validateInlineImageBytes(inline_bytes, media_type);
        } else if ((snapshot_path == null) != (snapshot_sha256 == null)) return error.InvalidSessionFormat;
        images[i] = .{
            .id = try requireUsize(image, "id"),
            .path = path,
            .media_type = media_type,
            .snapshot_path = snapshot_path,
            .snapshot_sha256 = snapshot_sha256,
            .inline_data = inline_data,
        };
        parsed_count += 1;
    }
    return .{ .text = text, .images = images, .work_id = work_id };
}

fn imageAttachmentObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidSessionFormat;
    var has_id = false;
    var has_path = false;
    var has_media_type = false;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "id")) {
            has_id = true;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "path")) {
            has_path = true;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "media_type")) {
            has_media_type = true;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "snapshot_path") or
            std.mem.eql(u8, entry.key_ptr.*, "snapshot_sha256") or
            std.mem.eql(u8, entry.key_ptr.*, "inline_data"))
        {
            continue;
        } else {
            return error.InvalidSessionFormat;
        }
    }
    if (!has_id or !has_path or !has_media_type) return error.InvalidSessionFormat;
    return value.object;
}

/// Format-level validation for image bytes embedded in a checkpoint or host
/// session: bounded, non-empty, and sniffing to the declared media type.
/// Content integrity beyond the payload envelope is verified at request time
/// by `loadVerifiedSnapshot`.
fn validateInlineImageBytes(bytes: []const u8, media_type: []const u8) !void {
    if (bytes.len == 0 or bytes.len > image_attachments.max_image_bytes) {
        return error.InvalidSessionFormat;
    }
    const detected = image_data.detectMediaTypeFromBytes(bytes) orelse
        return error.InvalidSessionFormat;
    if (!std.mem.eql(u8, detected, media_type)) return error.InvalidSessionFormat;
}

fn parseExecutionMemory(alloc: Allocator, value: std.json.Value) !session.ExecutionMemory {
    const source = try requireObject(value);
    const schema_version = try requireU64(source, "schema_version");
    const object = switch (schema_version) {
        1...4 => try exactObject(value, &.{ "schema_version", "tool_steps", "files" }),
        5 => try exactObject(value, &.{ "schema_version", "tool_steps", "files", "turn_summary" }),
        6 => try exactObject(value, &.{ "schema_version", "tool_steps", "files", "steering", "turn_summary" }),
        7...10 => try exactObject(value, &.{ "schema_version", "tool_steps", "files", "steering", "turn_summary" }),
        else => return error.InvalidSessionFormat,
    };
    const tool_steps = try parseToolSteps(
        alloc,
        object.get("tool_steps") orelse return error.InvalidSessionFormat,
        schema_version,
    );
    errdefer session.freeExecutionMemory(alloc, .{ .tool_steps = tool_steps });
    const files = try parseFiles(alloc, object.get("files") orelse return error.InvalidSessionFormat);
    errdefer types.freeFileEvidenceSlice(alloc, files);
    const steering: []types.PersistedSteering = if (schema_version >= 6)
        try parsePersistedSteering(
            alloc,
            object.get("steering") orelse return error.InvalidSessionFormat,
            schema_version,
            tool_steps.len,
        )
    else
        &.{};
    errdefer types.freePersistedSteering(alloc, steering);
    const turn_summary = if (schema_version >= 5)
        try parseOptionalTurnSummary(object.get("turn_summary").?)
    else
        null;
    return .{
        .tool_steps = tool_steps,
        .files = files,
        .steering = steering,
        .turn_summary = turn_summary,
    };
}

fn parsePersistedSteering(
    alloc: Allocator,
    value: std.json.Value,
    schema_version: u64,
    tool_step_count: usize,
) ![]types.PersistedSteering {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const steering = try alloc.alloc(types.PersistedSteering, value.array.items.len);
    errdefer alloc.free(steering);
    var parsed_count: usize = 0;
    errdefer for (steering[0..parsed_count]) |item| {
        alloc.free(item.text);
        if (item.assistant_prefix) |prefix| alloc.free(prefix);
    };
    var prior_tool_step_count: usize = 0;
    for (value.array.items, 0..) |item, index| {
        const parsed = if (schema_version == 6)
            types.PersistedSteering{
                .text = try parseDurableBytes(alloc, item),
                .after_tool_step_count = tool_step_count,
            }
        else blk: {
            const object = try exactObject(item, &.{ "text", "assistant_prefix", "after_tool_step_count" });
            const after_tool_step_count = try requireUsize(object, "after_tool_step_count");
            if (after_tool_step_count > tool_step_count or
                (index > 0 and after_tool_step_count < prior_tool_step_count))
            {
                return error.InvalidSessionFormat;
            }
            const text = try parseDurableBytes(
                alloc,
                object.get("text") orelse return error.InvalidSessionFormat,
            );
            const assistant_prefix = parseOptionalDurableBytes(
                alloc,
                object.get("assistant_prefix") orelse return error.InvalidSessionFormat,
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

fn parseOptionalTurnSummary(value: std.json.Value) !?types.TurnSummary {
    if (value == .null) return null;
    const object = try exactObject(value, &.{
        "started_at_ms",
        "completed_at_ms",
        "thinking_duration_ms",
        "turn_duration_ms",
        "token_progress",
    });
    const token_progress = try exactObject(
        object.get("token_progress") orelse return error.InvalidSessionFormat,
        &.{ "input_tokens", "output_tokens", "input_exact", "output_exact" },
    );
    const summary = types.TurnSummary{
        .started_at_ms = try requireI64(object, "started_at_ms"),
        .completed_at_ms = try requireI64(object, "completed_at_ms"),
        .thinking_duration_ms = try requireU64(object, "thinking_duration_ms"),
        .turn_duration_ms = try requireU64(object, "turn_duration_ms"),
        .token_progress = .{
            .input_tokens = try requireU64(token_progress, "input_tokens"),
            .output_tokens = try requireU64(token_progress, "output_tokens"),
            .input_exact = try requireBool(token_progress, "input_exact"),
            .output_exact = try requireBool(token_progress, "output_exact"),
        },
    };
    if (summary.started_at_ms < 0 or
        summary.completed_at_ms < summary.started_at_ms)
    {
        return error.InvalidSessionFormat;
    }
    return summary;
}

fn parseToolSteps(
    alloc: Allocator,
    value: std.json.Value,
    schema_version: u64,
) ![]session.ToolExecutionStep {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const steps = try alloc.alloc(session.ToolExecutionStep, value.array.items.len);
    errdefer mem_utils.free(alloc, steps);
    var parsed_count: usize = 0;
    errdefer for (steps[0..parsed_count]) |step| {
        if (step.assistant) |assistant| mem_utils.free(alloc, assistant);
        if (step.provider_replay) |replay| types.freeProviderReplay(alloc, replay);
        session.freeToolCallSlice(alloc, step.tool_calls);
        session.freePersistedToolResults(alloc, step.tool_results);
    };
    for (value.array.items, 0..) |step_value, i| {
        const object = if (schema_version >= 9)
            try exactObject(step_value, &.{ "assistant", "tool_calls", "tool_results", "provider_replay" })
        else
            try exactObject(step_value, &.{ "assistant", "tool_calls", "tool_results" });
        const assistant = try parseOptionalDurableBytes(alloc, object.get("assistant") orelse return error.InvalidSessionFormat);
        errdefer if (assistant) |owned| mem_utils.free(alloc, owned);
        const tool_calls = try parseToolCalls(alloc, object.get("tool_calls") orelse return error.InvalidSessionFormat);
        errdefer session.freeToolCallSlice(alloc, tool_calls);
        const tool_results = try parseToolResults(
            alloc,
            object.get("tool_results") orelse return error.InvalidSessionFormat,
            schema_version,
        );
        errdefer session.freePersistedToolResults(alloc, tool_results);
        try session.repairPersistedToolArguments(alloc, tool_calls, tool_results, .schema_v3);
        const replay = try parseProviderReplay(alloc, object.get("provider_replay") orelse .null);
        steps[i] = .{
            .assistant = assistant,
            .provider_replay = replay,
            .tool_calls = tool_calls,
            .tool_results = tool_results,
        };
        parsed_count += 1;
    }
    return steps;
}

fn parseProviderReplay(alloc: Allocator, value: std.json.Value) !?types.ProviderReplay {
    if (value == .null) return null;
    const parsed = std.json.parseFromValue(types.ProviderReplay, alloc, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const replay = parsed.value;
    if (types.ConversationIdentity.invalidReason(replay.source.model) != null or
        replay.parts_json.len == 0 or replay.parts_json.len > types.ProviderReplay.max_bytes or
        !std.unicode.utf8ValidateSlice(replay.parts_json)) return error.InvalidSessionFormat;
    return try types.dupeProviderReplay(alloc, replay);
}

/// Parses the array `writeToolCalls` writes. The caller owns the result.
pub fn parseToolCalls(alloc: Allocator, value: std.json.Value) ![]session.ToolCall {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const calls = try alloc.alloc(session.ToolCall, value.array.items.len);
    errdefer mem_utils.free(alloc, calls);
    var parsed_count: usize = 0;
    errdefer for (calls[0..parsed_count]) |call| session.freeToolCall(alloc, call);
    for (value.array.items, 0..) |call_value, i| {
        calls[i] = try parseToolCall(alloc, call_value);
        parsed_count += 1;
    }
    return calls;
}

fn parseToolCall(alloc: Allocator, value: std.json.Value) !session.ToolCall {
    const object = try exactObject(value, &.{
        "id",
        "name",
        "arguments_json",
        "provider_result",
    });
    const id = try parseRequiredDurableBytes(alloc, object, "id");
    errdefer mem_utils.free(alloc, id);
    const name = try parseRequiredDurableBytes(alloc, object, "name");
    errdefer mem_utils.free(alloc, name);
    var arguments_json = try parseRequiredDurableBytes(alloc, object, "arguments_json");
    errdefer mem_utils.free(alloc, arguments_json);
    const argument_integrity = try types.ToolArgumentIntegrity.classifyFunctionInput(alloc, arguments_json);
    if (argument_integrity == .malformed_json) {
        const safe_arguments = try alloc.dupe(u8, "{}");
        mem_utils.free(alloc, arguments_json);
        arguments_json = safe_arguments;
    }
    const provider_result = try parseOptionalDurableBytes(
        alloc,
        object.get("provider_result") orelse return error.InvalidSessionFormat,
    );
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
        .argument_integrity = argument_integrity,
        .provider_result = provider_result,
    };
}

fn parseOptionalToolCall(alloc: Allocator, value: std.json.Value) !?session.ToolCall {
    return switch (value) {
        .null => null,
        .object => blk: {
            var call = try parseToolCall(alloc, value);
            errdefer session.freeToolCall(alloc, call);
            try session.repairPersistedInterruptedToolArguments(alloc, &call, .schema_v3);
            break :blk call;
        },
        else => error.InvalidSessionFormat,
    };
}

fn parseToolResults(
    alloc: Allocator,
    value: std.json.Value,
    schema_version: u64,
) ![]session.PersistedToolResult {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const results = try alloc.alloc(session.PersistedToolResult, value.array.items.len);
    errdefer mem_utils.free(alloc, results);
    var parsed_count: usize = 0;
    errdefer for (results[0..parsed_count]) |result| {
        mem_utils.free(alloc, result.tool_call_id);
        mem_utils.free(alloc, result.tool_name);
        mem_utils.free(alloc, result.output);
        types.freeToolImages(alloc, result.tool_images);
        if (result.tool_image_handle) |handle| mem_utils.free(alloc, handle);
        if (result.output_handle) |handle| mem_utils.free(alloc, handle);
        if (result.preview) |preview| mem_utils.free(alloc, preview);
        types.freePermissionFeedback(alloc, result.permission_feedback);
        if (result.committed_file_presentation) |presentation| {
            types.freeCommittedFilePresentation(alloc, presentation);
        }
        if (result.command_output_replay) |replay| {
            types.freeCommandOutputReplay(alloc, replay);
        }
    };
    for (value.array.items, 0..) |result_value, i| {
        results[i] = try parseToolResult(alloc, result_value, schema_version);
        parsed_count += 1;
    }
    return results;
}

fn parseToolResult(
    alloc: Allocator,
    value: std.json.Value,
    schema_version: u64,
) !session.PersistedToolResult {
    const v1_keys = &.{
        "tool_call_id",
        "tool_name",
        "status",
        "output",
        "output_handle",
        "preview",
        "output_bytes",
        "stored_output_bytes",
        "truncated",
        "provider_native",
        "created_at_ms",
    };
    const v2_keys = &.{
        "tool_call_id",
        "tool_name",
        "status",
        "output",
        "output_handle",
        "preview",
        "output_bytes",
        "stored_output_bytes",
        "truncated",
        "provider_native",
        "created_at_ms",
        "permission_feedback",
    };
    const v2_extended_keys = &.{
        "tool_call_id",
        "tool_name",
        "status",
        "output",
        "output_handle",
        "preview",
        "output_bytes",
        "stored_output_bytes",
        "truncated",
        "provider_native",
        "created_at_ms",
        "permission_feedback",
        "committed_file_presentation",
    };
    const v3_keys = &.{
        "tool_call_id",
        "tool_name",
        "status",
        "output",
        "output_handle",
        "preview",
        "output_bytes",
        "stored_output_bytes",
        "truncated",
        "provider_native",
        "created_at_ms",
        "permission_feedback",
        "committed_file_presentation",
        "command_output_replay",
        "command_process_presentation",
    };
    const v4_keys = &[_][]const u8{
        "tool_call_id",
        "tool_name",
        "status",
        "output",
        "output_handle",
        "preview",
        "output_bytes",
        "stored_output_bytes",
        "truncated",
        "provider_native",
        "created_at_ms",
        "permission_feedback",
        "committed_file_presentation",
        "command_output_replay",
        "command_process_presentation",
        "terminal_action_presentation",
    };
    const result_shape: ExactVariantObject = switch (schema_version) {
        1 => .{ .object = try exactObject(value, v1_keys), .extended = false },
        2 => try exactVariantObject(value, v2_keys, v2_extended_keys),
        3 => .{ .object = try exactObject(value, v3_keys), .extended = true },
        4, 5, 6, 7 => .{ .object = try exactObject(value, v4_keys), .extended = true },
        8, 9 => .{ .object = if (value == .object and value.object.contains("tool_images"))
            try exactObject(value, &(v4_keys.* ++ [_][]const u8{"tool_images"}))
        else if (value == .object and value.object.contains("tool_image_handle"))
            try exactObject(value, &(v4_keys.* ++ [_][]const u8{"tool_image_handle"}))
        else
            try exactObject(value, v4_keys), .extended = true },
        10 => blk: {
            const keys = v4_keys.* ++ [_][]const u8{"review_feedback"};
            break :blk .{ .object = if (value == .object and value.object.contains("tool_images"))
                try exactObject(value, &(keys ++ [_][]const u8{"tool_images"}))
            else if (value == .object and value.object.contains("tool_image_handle"))
                try exactObject(value, &(keys ++ [_][]const u8{"tool_image_handle"}))
            else
                try exactObject(value, &keys), .extended = true };
        },
        else => return error.InvalidSessionFormat,
    };
    const object = result_shape.object;
    const status = std.meta.stringToEnum(
        session.PersistedToolStatus,
        try requireString(object, "status"),
    ) orelse return error.InvalidSessionFormat;
    const provider_native = try requireBool(object, "provider_native");
    const review_feedback = if (schema_version >= 10) try requireBool(object, "review_feedback") else false;
    if (review_feedback and (status != .failure or provider_native)) return error.InvalidSessionFormat;
    var text = try parseToolResultText(alloc, object, schema_version);
    errdefer text.deinit(alloc);
    var presentations = try parseToolResultPresentations(
        alloc,
        object,
        schema_version,
        result_shape.extended,
    );
    errdefer presentations.deinit(alloc);
    var images = try parseToolResultImages(alloc, object, &text.output);
    errdefer images.deinit(alloc);
    return .{
        .tool_images = images.items,
        .tool_image_handle = images.handle,
        .tool_call_id = text.tool_call_id,
        .tool_name = text.tool_name,
        .status = status,
        .output = text.output,
        .output_handle = text.output_handle,
        .preview = text.preview,
        .output_bytes = try requireUsize(object, "output_bytes"),
        .stored_output_bytes = try requireUsize(object, "stored_output_bytes"),
        .truncated = try requireBool(object, "truncated"),
        .provider_native = provider_native,
        .review_feedback = review_feedback,
        .created_at_ms = try requireI64(object, "created_at_ms"),
        .permission_feedback = text.permission_feedback,
        .committed_file_presentation = presentations.committed_file,
        .command_output_replay = presentations.command_output_replay,
        .command_process_presentation = presentations.command_process,
        .terminal_action_presentation = presentations.terminal_action,
    };
}

const ParsedToolResultText = struct {
    tool_call_id: []u8,
    tool_name: []u8,
    output: []u8,
    output_handle: ?[]u8,
    preview: ?[]u8,
    permission_feedback: [][]u8,

    fn deinit(self: *ParsedToolResultText, alloc: Allocator) void {
        types.freePermissionFeedback(alloc, self.permission_feedback);
        if (self.preview) |preview| mem_utils.free(alloc, preview);
        if (self.output_handle) |handle| mem_utils.free(alloc, handle);
        mem_utils.free(alloc, self.output);
        mem_utils.free(alloc, self.tool_name);
        mem_utils.free(alloc, self.tool_call_id);
        self.* = undefined;
    }
};

fn parseToolResultText(
    alloc: Allocator,
    object: std.json.ObjectMap,
    schema_version: u64,
) !ParsedToolResultText {
    const tool_call_id = try parseRequiredDurableBytes(alloc, object, "tool_call_id");
    errdefer mem_utils.free(alloc, tool_call_id);
    const tool_name = try parseRequiredDurableBytes(alloc, object, "tool_name");
    errdefer mem_utils.free(alloc, tool_name);
    const output = try parseRequiredDurableBytes(alloc, object, "output");
    errdefer mem_utils.free(alloc, output);
    const output_handle = try parseOptionalDurableBytes(
        alloc,
        object.get("output_handle") orelse return error.InvalidSessionFormat,
    );
    errdefer if (output_handle) |owned| mem_utils.free(alloc, owned);
    const preview = try parseOptionalDurableBytes(
        alloc,
        object.get("preview") orelse return error.InvalidSessionFormat,
    );
    errdefer if (preview) |owned| mem_utils.free(alloc, owned);
    const permission_feedback: [][]u8 = if (schema_version == 1)
        &.{}
    else
        try parseDurableBytesArray(
            alloc,
            object.get("permission_feedback") orelse return error.InvalidSessionFormat,
        );
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .output = output,
        .output_handle = output_handle,
        .preview = preview,
        .permission_feedback = permission_feedback,
    };
}

const ParsedToolResultPresentations = struct {
    committed_file: ?types.CommittedFilePresentation,
    command_output_replay: ?types.CommandOutputReplay,
    command_process: ?types.CommandProcessPresentation,
    terminal_action: ?types.TerminalActionPresentation,

    fn deinit(self: *ParsedToolResultPresentations, alloc: Allocator) void {
        if (self.command_output_replay) |replay| {
            types.freeCommandOutputReplay(alloc, replay);
        }
        if (self.committed_file) |presentation| {
            types.freeCommittedFilePresentation(alloc, presentation);
        }
        self.* = undefined;
    }
};

fn parseToolResultPresentations(
    alloc: Allocator,
    object: std.json.ObjectMap,
    schema_version: u64,
    extended: bool,
) !ParsedToolResultPresentations {
    const committed_file = if (extended)
        try parseOptionalCommittedFilePresentation(
            alloc,
            object.get("committed_file_presentation") orelse return error.InvalidSessionFormat,
        )
    else
        null;
    errdefer if (committed_file) |presentation| {
        types.freeCommittedFilePresentation(alloc, presentation);
    };
    const command_output_replay = if (schema_version >= 3)
        try parseOptionalCommandOutputReplay(
            alloc,
            object.get("command_output_replay") orelse return error.InvalidSessionFormat,
        )
    else
        null;
    errdefer if (command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    };
    return .{
        .committed_file = committed_file,
        .command_output_replay = command_output_replay,
        .command_process = if (schema_version >= 3)
            try parseOptionalCommandProcessPresentation(
                object.get("command_process_presentation") orelse return error.InvalidSessionFormat,
            )
        else
            null,
        .terminal_action = if (schema_version >= 4)
            try parseOptionalTerminalActionPresentation(
                object.get("terminal_action_presentation") orelse return error.InvalidSessionFormat,
            )
        else
            null,
    };
}

/// Writes typed image blocks.
pub fn writePersistedToolImages(writer: *std.Io.Writer, images: []const types.ToolImage) !void {
    try writer.writeByte('[');
    for (images, 0..) |image, index| {
        if (index > 0) try writer.writeByte(',');
        if (image.data.len == 0) return error.InvalidImage;
        try writer.writeAll("{\"type\":\"image\",\"mimeType\":");
        try writeJsonString(writer, image.mime_type);
        try writer.writeAll(",\"data\":");
        try writeJsonString(writer, image.data);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

/// Caller owns the images. Shared image admission keeps its byte, count, and
/// media-type checks.
pub fn parsePersistedToolImages(alloc: Allocator, content: []const std.json.Value) ![]types.ToolImage {
    if (content.len > image_data.max_tool_images) return error.ImageLimitExceeded;
    for (content) |item| {
        if (item != .object) return error.InvalidImage;
    }
    return image_data.parseToolImages(alloc, content);
}

const ParsedToolResultImages = struct {
    handle: ?[]u8,
    items: []types.ToolImage,

    fn deinit(self: *ParsedToolResultImages, alloc: Allocator) void {
        types.freeToolImages(alloc, self.items);
        if (self.handle) |handle| mem_utils.free(alloc, handle);
        self.* = undefined;
    }
};

fn parseToolResultImages(
    alloc: Allocator,
    object: std.json.ObjectMap,
    output: *[]u8,
) !ParsedToolResultImages {
    const handle = if (object.get("tool_image_handle")) |value|
        try parseOptionalDurableBytes(alloc, value)
    else
        null;
    errdefer if (handle) |owned| mem_utils.free(alloc, owned);
    const items = if (object.get("tool_images")) |images| items: {
        if (images != .array) return error.InvalidSessionFormat;
        const parsed = parsePersistedToolImages(alloc, images.array.items) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const notice = try alloc.print(
                "{s}\n[Saved tool image unavailable: {s}]",
                .{ output.*, @errorName(err) },
            );
            mem_utils.free(alloc, output.*);
            output.* = notice;
            break :items try alloc.alloc(types.ToolImage, 0);
        };
        if (parsed.len != images.array.items.len) {
            types.freeToolImages(alloc, parsed);
            const notice = try alloc.print(
                "{s}\n[Saved tool image unavailable: unsupported content]",
                .{output.*},
            );
            mem_utils.free(alloc, output.*);
            output.* = notice;
            break :items try alloc.alloc(types.ToolImage, 0);
        }
        break :items parsed;
    } else try alloc.alloc(types.ToolImage, 0);
    return .{ .handle = handle, .items = items };
}

fn parseOptionalCommandOutputReplay(
    alloc: Allocator,
    value: std.json.Value,
) !?types.CommandOutputReplay {
    if (value == .null) return null;
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidSessionFormat,
    };
    const kind = try requireString(object, "kind");
    if (std.mem.eql(u8, kind, "unavailable")) {
        _ = try exactObject(value, &.{"kind"});
        return .unavailable;
    }
    if (!std.mem.eql(u8, kind, "available")) return error.InvalidSessionFormat;
    const exact = try exactObject(value, &.{ "kind", "handle", "framed_bytes" });
    const handle = try parseRequiredDurableBytes(alloc, exact, "handle");
    errdefer alloc.free(handle);
    return .{ .available = .{
        .handle = handle,
        .framed_bytes = try requireUsize(exact, "framed_bytes"),
    } };
}

fn parseOptionalCommandProcessPresentation(
    value: std.json.Value,
) !?types.CommandProcessPresentation {
    if (value == .null) return null;
    const object = try exactObject(value, &.{ "kind", "value" });
    const kind = try requireString(object, "kind");
    if (std.mem.eql(u8, kind, "exit_code")) {
        return .{ .exit_code = try requireI64(object, "value") };
    }
    if (std.mem.eql(u8, kind, "signal")) {
        const signal = try requireU64(object, "value");
        return .{ .signal = std.math.cast(u32, signal) orelse
            return error.InvalidSessionFormat };
    }
    if (std.mem.eql(u8, kind, "timed_out")) {
        if (object.get("value").? != .null) return error.InvalidSessionFormat;
        return .timed_out;
    }
    if (std.mem.eql(u8, kind, "output_capture_failed")) {
        if (object.get("value").? != .null) return error.InvalidSessionFormat;
        return .output_capture_failed;
    }
    return error.InvalidSessionFormat;
}

fn parseOptionalTerminalActionPresentation(
    value: std.json.Value,
) !?types.TerminalActionPresentation {
    if (value == .null) return null;
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidSessionFormat,
    };
    const kind = try requireString(object, "kind");
    if (std.mem.eql(u8, kind, "returned")) {
        _ = try exactObject(value, &.{ "kind", "outcome" });
        return .{ .returned = try parseTerminalReturnPresentation(
            object.get("outcome") orelse return error.InvalidSessionFormat,
        ) };
    }
    if (std.mem.eql(u8, kind, "failed")) {
        _ = try exactObject(value, &.{ "kind", "code" });
        const code = std.meta.stringToEnum(
            types.TerminalFailurePresentation,
            try requireString(object, "code"),
        ) orelse return error.InvalidSessionFormat;
        return .{ .failed = code };
    }
    return error.InvalidSessionFormat;
}

fn parseTerminalReturnPresentation(
    value: std.json.Value,
) !types.TerminalReturnPresentation {
    const object = try exactObject(value, &.{ "kind", "value" });
    const kind = try requireString(object, "kind");
    if (std.mem.eql(u8, kind, "started") or
        std.mem.eql(u8, kind, "condition_met") or
        std.mem.eql(u8, kind, "safety_ceiling") or
        std.mem.eql(u8, kind, "cancelled"))
    {
        if (object.get("value").? != .null) return error.InvalidSessionFormat;
        if (std.mem.eql(u8, kind, "started")) return .started;
        if (std.mem.eql(u8, kind, "condition_met")) return .condition_met;
        if (std.mem.eql(u8, kind, "safety_ceiling")) return .safety_ceiling;
        return .cancelled;
    }
    if (std.mem.eql(u8, kind, "exited")) {
        return .{ .exited = std.math.cast(i32, try requireI64(object, "value")) orelse
            return error.InvalidSessionFormat };
    }
    if (std.mem.eql(u8, kind, "signal")) {
        return .{ .signal = std.math.cast(u32, try requireU64(object, "value")) orelse
            return error.InvalidSessionFormat };
    }
    return error.InvalidSessionFormat;
}

fn parseOptionalCommittedFilePresentation(
    alloc: Allocator,
    value: std.json.Value,
) !?types.CommittedFilePresentation {
    return switch (value) {
        .null => null,
        .object => try parseCommittedFilePresentation(alloc, value),
        else => error.InvalidSessionFormat,
    };
}

fn parseCommittedFilePresentation(
    alloc: Allocator,
    value: std.json.Value,
) !types.CommittedFilePresentation {
    const presentation_legacy_keys = [_][]const u8{
        "path",
        "kind",
        "lines",
        "additions",
        "deletions",
        "truncated",
        "previous_content",
        "after_content",
        "lifecycle_id",
    };
    const presentation_extended_keys = presentation_legacy_keys ++ [_][]const u8{"content_handle"};
    const object = (try exactVariantObject(
        value,
        &presentation_legacy_keys,
        &presentation_extended_keys,
    )).object;
    const path = try parseRequiredDurableBytes(alloc, object, "path");
    errdefer mem_utils.free(alloc, path);
    const lines = try parseCommittedFilePresentationLines(
        alloc,
        object.get("lines") orelse return error.InvalidSessionFormat,
    );
    errdefer freeCommittedFilePresentationLines(alloc, lines);
    const previous_content = try parseOptionalDurableBytes(
        alloc,
        object.get("previous_content") orelse return error.InvalidSessionFormat,
    );
    errdefer if (previous_content) |content| mem_utils.free(alloc, content);
    const after_content = try parseOptionalDurableBytes(
        alloc,
        object.get("after_content") orelse return error.InvalidSessionFormat,
    );
    errdefer if (after_content) |content| mem_utils.free(alloc, content);
    const lifecycle_id = try parseOptionalToolLifecycleId(
        alloc,
        object.get("lifecycle_id") orelse return error.InvalidSessionFormat,
    );
    errdefer if (lifecycle_id) |id| mem_utils.free(alloc, id.call_id);
    // Older records predate externalized diff snapshots and carry no key.
    const content_handle = if (object.get("content_handle")) |handle_value|
        try parseOptionalDurableBytes(alloc, handle_value)
    else
        null;
    errdefer if (content_handle) |handle| mem_utils.free(alloc, handle);
    const presentation = types.CommittedFilePresentation{
        .path = path,
        .kind = std.meta.stringToEnum(
            types.CommittedFilePresentationKind,
            try requireString(object, "kind"),
        ) orelse return error.InvalidSessionFormat,
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
    value: std.json.Value,
) ![]types.CommittedFilePresentationLine {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const lines = try alloc.alloc(types.CommittedFilePresentationLine, value.array.items.len);
    var parsed_count: usize = 0;
    errdefer {
        for (lines[0..parsed_count]) |line| mem_utils.free(alloc, @constCast(line.text));
        mem_utils.free(alloc, lines);
    }
    for (value.array.items, 0..) |line_value, index| {
        const object = try exactObject(line_value, &.{ "kind", "old_line", "new_line", "text" });
        const text = try parseRequiredDurableBytes(alloc, object, "text");
        errdefer mem_utils.free(alloc, text);
        lines[index] = .{
            .kind = std.meta.stringToEnum(
                types.CommittedFilePresentationLineKind,
                try requireString(object, "kind"),
            ) orelse return error.InvalidSessionFormat,
            .old_line = try parseOptionalU32(object.get("old_line") orelse return error.InvalidSessionFormat),
            .new_line = try parseOptionalU32(object.get("new_line") orelse return error.InvalidSessionFormat),
            .text = text,
        };
        parsed_count += 1;
    }
    return lines;
}

fn freeCommittedFilePresentationLines(
    alloc: Allocator,
    lines: []const types.CommittedFilePresentationLine,
) void {
    for (lines) |line| mem_utils.free(alloc, @constCast(line.text));
    if (lines.len > 0) mem_utils.free(alloc, @constCast(lines));
}

fn parseOptionalToolLifecycleId(
    alloc: Allocator,
    value: std.json.Value,
) !?types.ToolLifecycleId {
    return switch (value) {
        .null => null,
        .object => {
            const object = try exactObject(value, &.{ "turn_id", "call_id" });
            const call_id = try parseRequiredDurableBytes(alloc, object, "call_id");
            errdefer mem_utils.free(alloc, call_id);
            return .{
                .turn_id = try requireU64(object, "turn_id"),
                .call_id = call_id,
            };
        },
        else => error.InvalidSessionFormat,
    };
}

fn parseFiles(alloc: Allocator, value: std.json.Value) ![]session.FileEvidence {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const files = try alloc.alloc(session.FileEvidence, value.array.items.len);
    errdefer mem_utils.free(alloc, files);
    var parsed_count: usize = 0;
    errdefer for (files[0..parsed_count]) |file| {
        mem_utils.free(alloc, file.path);
        if (file.new_path) |new_path| mem_utils.free(alloc, new_path);
        mem_utils.free(alloc, file.tool_call_id);
        mem_utils.free(alloc, file.tool_name);
    };
    for (value.array.items, 0..) |file_value, i| {
        files[i] = try parseFile(alloc, file_value);
        parsed_count += 1;
    }
    return files;
}

fn parseFile(alloc: Allocator, value: std.json.Value) !session.FileEvidence {
    const object = try exactObject(value, &.{
        "path",
        "new_path",
        "tool_call_id",
        "tool_name",
        "action",
        "status",
        "model_view_covers_full_file",
        "stale",
    });
    const path = try parseRequiredDurableBytes(alloc, object, "path");
    errdefer mem_utils.free(alloc, path);
    const new_path = try parseOptionalDurableBytes(
        alloc,
        object.get("new_path") orelse return error.InvalidSessionFormat,
    );
    errdefer if (new_path) |owned| mem_utils.free(alloc, owned);
    const tool_call_id = try parseRequiredDurableBytes(alloc, object, "tool_call_id");
    errdefer mem_utils.free(alloc, tool_call_id);
    const tool_name = try parseRequiredDurableBytes(alloc, object, "tool_name");
    errdefer mem_utils.free(alloc, tool_name);
    return .{
        .path = path,
        .new_path = new_path,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .action = std.meta.stringToEnum(
            session.FileEvidenceAction,
            try requireString(object, "action"),
        ) orelse return error.InvalidSessionFormat,
        .status = std.meta.stringToEnum(
            session.PersistedToolStatus,
            try requireString(object, "status"),
        ) orelse return error.InvalidSessionFormat,
        .model_view_covers_full_file = try requireBool(object, "model_view_covers_full_file"),
        .stale = try requireBool(object, "stale"),
    };
}

fn parseDurableBytesArray(alloc: Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const items = try alloc.alloc([]u8, value.array.items.len);
    errdefer alloc.free(items);
    var parsed_count: usize = 0;
    errdefer for (items[0..parsed_count]) |item| alloc.free(item);
    for (value.array.items, 0..) |item, i| {
        items[i] = try parseDurableBytes(alloc, item);
        parsed_count += 1;
    }
    return items;
}

noinline fn parseRequiredDurableBytes(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    return parseDurableBytes(alloc, object.get(key) orelse return error.InvalidSessionFormat);
}

noinline fn parseOptionalDurableBytes(alloc: Allocator, value: std.json.Value) !?[]u8 {
    return switch (value) {
        .null => null,
        .string, .object => try parseDurableBytes(alloc, value),
        else => error.InvalidSessionFormat,
    };
}

fn parseOptionalIdentifier(value: std.json.Value) !?[16]u8 {
    return switch (value) {
        .null => null,
        .string => |hex| try parseHexIdentifier(hex),
        else => error.InvalidSessionFormat,
    };
}

fn parseHexIdentifier(hex: []const u8) ![16]u8 {
    if (hex.len != 32) return error.InvalidSessionFormat;
    var result: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, hex) catch return error.InvalidSessionFormat;
    const canonical = std.fmt.bytesToHex(result, .lower);
    if (!std.mem.eql(u8, &canonical, hex)) return error.InvalidSessionFormat;
    return result;
}

noinline fn writeOptionalDurableBytes(writer: *std.Io.Writer, value: anytype) !void {
    if (value) |bytes| {
        try writeDurableBytes(writer, bytes);
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalU32(writer: *std.Io.Writer, value: ?u32) !void {
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

noinline fn writeJsonString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try std.json.Stringify.value(bytes, .{}, writer);
}

noinline fn validateSessionId(value: []const u8) !void {
    if (value.len == 0 or value.len > 255 or
        std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, ".."))
    {
        return error.InvalidDurableField;
    }
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return error.InvalidDurableField;
        }
    }
}

fn validateWorkspaceRoot(value: []const u8) !void {
    if (value.len == 0 or value.len > std.Io.Dir.max_path_bytes or
        !std.unicode.utf8ValidateSlice(value) or !std.Io.Dir.path.isAbsolute(value))
    {
        return error.InvalidDurableField;
    }
}

fn validateModel(value: []const u8) !void {
    if (value.len == 0 or value.len > 1024 or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidDurableField;
    }
    if (std.ascii.isWhitespace(value[0]) or std.ascii.isWhitespace(value[value.len - 1])) {
        return error.InvalidDurableField;
    }
    for (value) |byte| if (std.ascii.isControl(byte)) return error.InvalidDurableField;
}

fn validateConversationLanguage(language: session.ConversationLanguage) !void {
    try validateConversationLanguageBytes(language.view());
}

fn validateConversationLanguageBytes(value: []const u8) !void {
    if (value.len == 0 or value.len > session.ConversationLanguage.max_len or
        !std.unicode.utf8ValidateSlice(value) or
        !std.mem.eql(u8, value, std.mem.trim(u8, value, " \t\r\n")))
    {
        return error.InvalidDurableField;
    }
    for (value) |byte| if (std.ascii.isControl(byte)) return error.InvalidDurableField;
}

fn dupeHistory(alloc: Allocator, history: []const session.HistoryTurn) ![]session.HistoryTurn {
    if (history.len == 0) return &.{};
    const copy = try alloc.alloc(session.HistoryTurn, history.len);
    errdefer alloc.free(copy);
    var copied: usize = 0;
    errdefer for (copy[0..copied]) |turn| session.freeHistoryTurn(alloc, turn);
    for (history, 0..) |turn, i| {
        copy[i] = try session.dupeHistoryTurn(alloc, turn);
        copied += 1;
    }
    return copy;
}

fn expectKey(reader: *std.json.Reader, alloc: Allocator, expected: []const u8) !void {
    const token = try reader.nextAllocMax(alloc, .alloc_if_needed, 64);
    defer freeToken(alloc, token);
    const actual = switch (token) {
        .string => |value| value,
        .allocated_string => |value| value,
        else => return error.InvalidSessionFormat,
    };
    if (!std.mem.eql(u8, actual, expected)) return error.InvalidSessionFormat;
}

fn readStringOwned(reader: *std.json.Reader, alloc: Allocator, max_len: usize) ![]u8 {
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

fn readI64(reader: *std.json.Reader, alloc: Allocator) !i64 {
    const token = try reader.nextAllocMax(alloc, .alloc_if_needed, 32);
    defer freeToken(alloc, token);
    const raw = switch (token) {
        .number => |value| value,
        .allocated_number => |value| value,
        else => return error.InvalidSessionFormat,
    };
    return std.fmt.parseInt(i64, raw, 10) catch error.InvalidSessionFormat;
}

fn readU64(reader: *std.json.Reader, alloc: Allocator) !u64 {
    const token = try reader.nextAllocMax(alloc, .alloc_if_needed, 32);
    defer freeToken(alloc, token);
    const raw = switch (token) {
        .number => |value| value,
        .allocated_number => |value| value,
        else => return error.InvalidSessionFormat,
    };
    return std.fmt.parseUnsigned(u64, raw, 10) catch error.InvalidSessionFormat;
}

fn readBool(reader: *std.json.Reader) !bool {
    return switch (try reader.next()) {
        .true => true,
        .false => false,
        else => error.InvalidSessionFormat,
    };
}

fn freeToken(alloc: Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number => |value| alloc.free(value),
        .allocated_string => |value| alloc.free(value),
        else => {},
    }
}

fn expectToken(actual: std.json.Token, comptime expected: std.meta.Tag(std.json.Token)) !void {
    if (std.meta.activeTag(actual) != expected) return error.InvalidSessionFormat;
}

noinline fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidSessionFormat;
    return value.object;
}

pub fn exactObject(value: std.json.Value, keys: []const []const u8) !std.json.ObjectMap {
    const object = try requireObject(value);
    if (object.count() != keys.len) return error.InvalidSessionFormat;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (keys) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidSessionFormat;
    }
    return object;
}

fn exactInterruptedHistoryObject(
    value: std.json.Value,
    has_execution: bool,
    has_presentation: bool,
    has_terminal_reason: bool,
    has_cancellation_origin: bool,
) !std.json.ObjectMap {
    var keys: [9][]const u8 = undefined;
    keys[0] = "kind";
    keys[1] = "user";
    keys[2] = "assistant";
    keys[3] = "tool_call";
    keys[4] = "completed_tool_names";
    var len: usize = 5;
    if (has_execution) {
        keys[len] = "execution";
        len += 1;
    }
    if (has_presentation) {
        keys[len] = "cancelled_command";
        len += 1;
    }
    if (has_terminal_reason) {
        keys[len] = "terminal_reason";
        len += 1;
    }
    if (has_cancellation_origin) {
        keys[len] = "cancellation_origin";
        len += 1;
    }
    return exactObject(value, keys[0..len]);
}

fn parseInterruptedTerminalReason(
    object: std.json.ObjectMap,
    key: []const u8,
) !types.InterruptedTerminalReason {
    const raw = try requireString(object, key);
    if (std.mem.eql(u8, raw, "cancelled")) return .cancelled;
    if (std.mem.eql(u8, raw, "failed")) return .failed;
    return error.InvalidSessionFormat;
}

const ExactVariantObject = struct {
    object: std.json.ObjectMap,
    extended: bool,
};

fn exactVariantObject(
    value: std.json.Value,
    legacy_keys: []const []const u8,
    extended_keys: []const []const u8,
) !ExactVariantObject {
    const object = try requireObject(value);
    if (object.count() == legacy_keys.len) {
        return .{
            .object = try exactObject(value, legacy_keys),
            .extended = false,
        };
    }
    if (object.count() == extended_keys.len) {
        return .{
            .object = try exactObject(value, extended_keys),
            .extended = true,
        };
    }
    return error.InvalidSessionFormat;
}

pub fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .string) return error.InvalidSessionFormat;
    return value.string;
}

fn requireBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .bool) return error.InvalidSessionFormat;
    return value.bool;
}

fn requireI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    return switch (value) {
        .integer => |number| number,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch error.InvalidSessionFormat,
        else => error.InvalidSessionFormat,
    };
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidSessionFormat,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch error.InvalidSessionFormat,
        else => error.InvalidSessionFormat,
    };
}

noinline fn requireUsize(object: std.json.ObjectMap, key: []const u8) !usize {
    const number = try requireU64(object, key);
    if (number > std.math.maxInt(usize)) return error.InvalidSessionFormat;
    return @intCast(number);
}

fn parseOptionalU32(value: std.json.Value) !?u32 {
    const number: u64 = switch (value) {
        .null => return null,
        .integer => |integer| if (integer >= 0) @intCast(integer) else return error.InvalidSessionFormat,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch return error.InvalidSessionFormat,
        else => return error.InvalidSessionFormat,
    };
    if (number > std.math.maxInt(u32)) return error.InvalidSessionFormat;
    return @intCast(number);
}

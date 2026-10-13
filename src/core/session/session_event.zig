const std = @import("std");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_usage = @import("session_usage.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const context_limits = @import("../config/context_limits.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const event_frame_max_bytes: usize = context_limits.emergency_ceiling_bytes;
pub const raw_state_chunk_bytes: usize = 4 * 1024 * 1024;
pub const Identifier = [16]u8;
pub const Digest = [Sha256.digest_length]u8;

// Version 3 adds CommittedFilePresentation.content_handle on tool_result
// frames: previous/after snapshots may live in a result-store artifact with
// only the handle inline. Version 1 and 2 frames never carry the field and
// remain readable.
pub const conversation_schema_version: u8 = 3;

/// Every historical frame version a reader must still accept. Writers always
/// emit conversation_schema_version.
fn supportedConversationSchema(version: u8) bool {
    return version >= 1 and version <= conversation_schema_version;
}
pub const max_conversation_text_bytes: usize = event_frame_max_bytes;
pub const max_conversation_identity_bytes: usize = types.ConversationIdentity.max_bytes;
pub const max_conversation_arguments_bytes: usize = event_frame_max_bytes;
pub const max_conversation_preview_bytes: usize = 4 * 1024;

pub const ArtifactCompleteness = enum {
    complete,
    partial,
    unknown,
};

pub const ConversationText = struct {
    text: []const u8,
};

pub const ConversationAssistant = struct {
    text: []const u8,
    provider_replay: ?types.ProviderReplay = null,
    standalone_response: bool = false,
};

pub const ConversationUser = struct {
    text: []const u8,
    images: []const types.ImageAttachment = &.{},
    work_id: ?[]const u8 = null,
};

pub const ConversationToolCall = struct {
    call_id: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    argument_integrity: types.ToolArgumentIntegrity = .valid,
    provisional_id: ?[]const u8 = null,
    provider_result: ?[]const u8 = null,
    final_identity: types.FinalToolIdentity = .valid,
    provenance: types.ToolExecutionProvenance = .fx_local,
};

pub const ConversationToolResult = struct {
    call_id: []const u8,
    tool_name: []const u8,
    status: types.PersistedToolStatus,
    artifact_ref: []const u8,
    tool_image_handle: ?[]const u8 = null,
    output_bytes: ?u64 = null,
    stored_bytes: u64,
    completeness: ArtifactCompleteness,
    preview: ?[]const u8 = null,
    provider_native: bool = false,
    review_feedback: bool = false,
    created_at_ms: i64 = 0,
    permission_feedback: []const []const u8 = &.{},
    committed_file_presentation: ?types.CommittedFilePresentation = null,
    command_replay_ref: ?[]const u8 = null,
    command_replay_bytes: ?u64 = null,
    command_process_presentation: ?types.CommandProcessPresentation = null,
    terminal_action_presentation: ?types.TerminalActionPresentation = null,

    pub fn jsonStringify(self: ConversationToolResult, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(ConversationToolResult).@"struct".field_names) |field_name| {
            if (!std.mem.eql(u8, field_name, "review_feedback") or self.review_feedback) {
                try writer.objectField(field_name);
                try writer.write(@field(self, field_name));
            }
        }
        try writer.endObject();
    }
};

pub const ConversationInterruption = struct {
    reason: session.InterruptedTerminalReason,
    partial_text: ?[]const u8 = null,
    command_replay_ref: ?[]const u8 = null,
    command_replay_bytes: ?u64 = null,
    command_artifact_ref: ?[]const u8 = null,
    files: []const types.FileEvidence = &.{},
    turn_summary: ?types.TurnSummary = null,
    cancellation_origin: types.CancellationOrigin = .turn,

    pub fn jsonParse(alloc: Allocator, source: anytype, options: std.json.ParseOptions) !ConversationInterruption {
        const Wire = struct {
            reason: session.InterruptedTerminalReason,
            partial_text: ?[]const u8 = null,
            command_replay_ref: ?[]const u8 = null,
            command_replay_bytes: ?u64 = null,
            command_artifact_ref: ?[]const u8 = null,
            files: []const types.FileEvidence = &.{},
            turn_summary: ?types.TurnSummary = null,
            cancellation_origin: std.json.Value = .{ .string = "turn" },
        };
        const wire = try std.json.innerParse(Wire, alloc, source, options);
        // The default enum decoder also accepts numeric tags, not just names.
        if (wire.cancellation_origin != .string) return error.UnexpectedToken;
        const origin = std.meta.stringToEnum(types.CancellationOrigin, wire.cancellation_origin.string) orelse
            return error.InvalidEnumTag;
        return .{
            .reason = wire.reason,
            .partial_text = wire.partial_text,
            .command_replay_ref = wire.command_replay_ref,
            .command_replay_bytes = wire.command_replay_bytes,
            .command_artifact_ref = wire.command_artifact_ref,
            .files = wire.files,
            .turn_summary = wire.turn_summary,
            .cancellation_origin = origin,
        };
    }

    // Keep ordinary record bytes unchanged. Older strict readers reject the
    // optional compaction origin; they cannot safely replay those records.
    pub fn jsonStringify(self: ConversationInterruption, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        try writer.objectField("reason");
        try writer.write(self.reason);
        try writer.objectField("partial_text");
        try writer.write(self.partial_text);
        try writer.objectField("command_replay_ref");
        try writer.write(self.command_replay_ref);
        try writer.objectField("command_replay_bytes");
        try writer.write(self.command_replay_bytes);
        try writer.objectField("command_artifact_ref");
        try writer.write(self.command_artifact_ref);
        try writer.objectField("files");
        try writer.write(self.files);
        try writer.objectField("turn_summary");
        try writer.write(self.turn_summary);
        if (self.cancellation_origin == .compaction) {
            try writer.objectField("cancellation_origin");
            try writer.write(self.cancellation_origin);
        }
        try writer.endObject();
    }
};

pub const ConversationTurnCompleted = struct {
    files: []const types.FileEvidence = &.{},
    turn_summary: ?types.TurnSummary = null,
};

pub const ConversationCheckpoint = struct {
    covers_through_seq: u64,
    summary: []const u8,
};

pub const ConversationEvent = union(enum) {
    user: ConversationUser,
    assistant: ConversationAssistant,
    tool_call: ConversationToolCall,
    tool_result: ConversationToolResult,
    steering: ConversationText,
    turn_completed: ConversationTurnCompleted,
    interrupted: ConversationInterruption,
    context_checkpoint: ConversationCheckpoint,
};

pub const ConversationEnvelope = struct {
    schema_version: u8 = conversation_schema_version,
    seq: u64,
    timestamp_ms: i64,
    event: ConversationEvent,
};

pub const DecodedConversationFrame = std.json.Parsed(ConversationEnvelope);

pub const PendingToolCall = struct {
    call_id: []const u8,
    tool_name: []const u8,
    seq: u64,
};

pub const ConversationStateView = struct {
    last_seq: u64 = 0,
    latest_checkpoint_coverage: u64 = 0,
    pending_tool_calls: []const PendingToolCall = &.{},
};

pub const ConversationTransitionError = error{
    UnsupportedConversationSchema,
    OutOfOrderConversationEvent,
    InvalidConversationEvent,
    DuplicateToolCall,
    OrphanToolResult,
    ToolIdentityMismatch,
    InvalidCheckpointCoverage,
    UnresolvedToolCall,
};

pub fn validateConversationTransition(
    state: ConversationStateView,
    envelope: ConversationEnvelope,
) ConversationTransitionError!void {
    if (!supportedConversationSchema(envelope.schema_version)) {
        return error.UnsupportedConversationSchema;
    }
    const expected_seq = std.math.add(u64, state.last_seq, 1) catch
        return error.OutOfOrderConversationEvent;
    if (envelope.seq != expected_seq) return error.OutOfOrderConversationEvent;
    if (envelope.timestamp_ms < 0) return rejectInvalidConversationEvent("envelope-timestamp");
    try validateConversationEventShape(envelope.event, envelope.schema_version);

    switch (envelope.event) {
        .tool_call => |call| {
            for (state.pending_tool_calls) |pending| {
                if (std.mem.eql(u8, pending.call_id, call.call_id)) {
                    return error.DuplicateToolCall;
                }
            }
        },
        .tool_result => |result| {
            const pending = findPendingToolCall(state.pending_tool_calls, result.call_id) orelse
                return error.OrphanToolResult;
            if (!std.mem.eql(u8, pending.tool_name, result.tool_name)) {
                return error.ToolIdentityMismatch;
            }
        },
        .context_checkpoint => |checkpoint| {
            if (checkpoint.covers_through_seq < state.latest_checkpoint_coverage or
                checkpoint.covers_through_seq > state.last_seq)
            {
                return error.InvalidCheckpointCoverage;
            }
            for (state.pending_tool_calls) |pending| {
                if (pending.seq <= checkpoint.covers_through_seq) {
                    return error.UnresolvedToolCall;
                }
            }
        },
        .turn_completed => if (state.pending_tool_calls.len != 0) {
            return error.UnresolvedToolCall;
        },
        .user, .assistant, .steering, .interrupted => {},
    }
}

/// Validation rejects with the same bare error at every site, which leaves
/// persistence failures undiagnosable. Name the rule so the trace log (and
/// /trace reports) identify the exact rejected invariant without content.
fn rejectInvalidConversationEvent(comptime rule: []const u8) ConversationTransitionError {
    debug_trace.logf("session", "conversation event rejected rule={s}", .{rule});
    return error.InvalidConversationEvent;
}

pub fn validateConversationEventShape(event: ConversationEvent, schema_version: u8) ConversationTransitionError!void {
    switch (event) {
        .user => |value| {
            try validateConversationText(value.text);
            if (value.images.len > 128) return rejectInvalidConversationEvent("user-images-count");
            for (value.images) |image| {
                if (image.path.len == 0 or
                    image.path.len > std.Io.Dir.max_path_bytes or
                    image.media_type.len == 0 or
                    image.media_type.len > max_conversation_identity_bytes or
                    !std.unicode.utf8ValidateSlice(image.path) or
                    !std.unicode.utf8ValidateSlice(image.media_type))
                {
                    return rejectInvalidConversationEvent("user-image-field");
                }
            }
            if (value.work_id) |work_id| try validateConversationIdentity(work_id);
        },
        .assistant => |value| {
            if (schema_version == 1 and (value.text.len == 0 or value.provider_replay != null)) return rejectInvalidConversationEvent("assistant-schema-v1");
            try validateOptionalConversationText(value.text);
            if (value.provider_replay) |replay| {
                try validateConversationIdentity(replay.source.model);
                if (replay.parts_json.len == 0 or replay.parts_json.len > types.ProviderReplay.max_bytes or
                    !std.unicode.utf8ValidateSlice(replay.parts_json)) return rejectInvalidConversationEvent("assistant-replay-parts");
            }
        },
        .steering => |value| try validateConversationText(value.text),
        .tool_call => |call| {
            try validateConversationIdentity(call.call_id);
            try validateConversationIdentity(call.tool_name);
            if (call.arguments_json.len == 0 or
                call.arguments_json.len > max_conversation_arguments_bytes or
                !std.unicode.utf8ValidateSlice(call.arguments_json))
            {
                return rejectInvalidConversationEvent("tool-call-arguments");
            }
            if (call.provisional_id) |value| try validateConversationIdentity(value);
            if (call.provider_result) |value| {
                if (value.len > max_conversation_arguments_bytes or
                    !std.unicode.utf8ValidateSlice(value))
                {
                    return rejectInvalidConversationEvent("tool-call-provider-result");
                }
            }
        },
        .tool_result => |result| {
            if (result.review_feedback and (result.status != .failure or result.provider_native)) {
                return rejectInvalidConversationEvent("tool-result-review-feedback");
            }
            try validateConversationIdentity(result.call_id);
            try validateConversationIdentity(result.tool_name);
            if (result.artifact_ref.len == 0 or
                result.artifact_ref.len > max_conversation_identity_bytes or
                !std.unicode.utf8ValidateSlice(result.artifact_ref))
            {
                return rejectInvalidConversationEvent("tool-result-artifact-ref");
            }
            if (result.preview) |preview| {
                if (preview.len > max_conversation_preview_bytes or
                    !std.unicode.utf8ValidateSlice(preview))
                {
                    return rejectInvalidConversationEvent("tool-result-preview");
                }
            }
            if (result.tool_image_handle) |handle| {
                try validateConversationIdentity(handle);
            }
            if (result.created_at_ms < 0) return rejectInvalidConversationEvent("tool-result-created-at");
            for (result.permission_feedback) |feedback| {
                try validateOptionalConversationText(feedback);
            }
            if (result.committed_file_presentation) |presentation| {
                if (!types.committedFilePresentationContentSourceValid(presentation)) {
                    return rejectInvalidConversationEvent("tool-result-file-presentation-source");
                }
                try validateConversationPath(presentation.path);
                for (presentation.lines) |line| {
                    try validateOptionalConversationText(line.text);
                }
                if (presentation.previous_content) |content| {
                    try validateOptionalConversationText(content);
                }
                if (presentation.after_content) |content| {
                    try validateOptionalConversationText(content);
                }
                if (presentation.lifecycle_id) |lifecycle_id| {
                    try validateConversationIdentity(lifecycle_id.call_id);
                }
                if (presentation.content_handle) |handle| {
                    try validateConversationIdentity(handle);
                }
            }
            if ((result.command_replay_ref == null) !=
                (result.command_replay_bytes == null))
            {
                return rejectInvalidConversationEvent("tool-result-command-replay-pair");
            }
            if (result.command_replay_ref) |handle| {
                try validateConversationIdentity(handle);
            }
        },
        .interrupted => |interrupted| {
            if (interrupted.partial_text) |text| try validateOptionalConversationText(text);
            if ((interrupted.command_replay_ref == null) !=
                (interrupted.command_replay_bytes == null))
            {
                return rejectInvalidConversationEvent("interrupted-command-replay-pair");
            }
            if (interrupted.command_replay_ref) |handle| {
                try validateConversationIdentity(handle);
            }
            if (interrupted.command_artifact_ref) |handle| {
                try validateConversationIdentity(handle);
            }
            try validateConversationFiles(interrupted.files);
        },
        .context_checkpoint => |checkpoint| try validateConversationText(checkpoint.summary),
        .turn_completed => |completed| try validateConversationFiles(completed.files),
    }
}

fn validateConversationFiles(files: []const types.FileEvidence) ConversationTransitionError!void {
    for (files) |file| {
        try validateConversationPath(file.path);
        if (file.new_path) |path| try validateConversationPath(path);
        try validateConversationIdentity(file.tool_call_id);
        try validateConversationIdentity(file.tool_name);
    }
}

fn validateConversationPath(path: []const u8) ConversationTransitionError!void {
    if (path.len == 0 or
        path.len > std.Io.Dir.max_path_bytes or
        !std.unicode.utf8ValidateSlice(path))
    {
        return rejectInvalidConversationEvent("file-path");
    }
}

fn validateConversationText(text: []const u8) ConversationTransitionError!void {
    if (text.len == 0) return rejectInvalidConversationEvent("text-empty");
    return validateOptionalConversationText(text);
}

fn validateOptionalConversationText(text: []const u8) ConversationTransitionError!void {
    if (text.len > max_conversation_text_bytes or !std.unicode.utf8ValidateSlice(text)) {
        return rejectInvalidConversationEvent("text-field");
    }
}

fn validateConversationIdentity(value: []const u8) ConversationTransitionError!void {
    if (types.ConversationIdentity.invalidReason(value) != null) {
        return rejectInvalidConversationEvent("identity");
    }
}

fn findPendingToolCall(
    pending_calls: []const PendingToolCall,
    call_id: []const u8,
) ?PendingToolCall {
    for (pending_calls) |pending| {
        if (std.mem.eql(u8, pending.call_id, call_id)) return pending;
    }
    return null;
}

pub fn encodeConversationFrame(
    alloc: Allocator,
    envelope: ConversationEnvelope,
) ![]u8 {
    if (envelope.schema_version != conversation_schema_version or
        envelope.seq == 0 or
        envelope.timestamp_ms < 0)
    {
        return rejectInvalidConversationEvent("envelope-header");
    }
    try validateConversationEventShape(envelope.event, envelope.schema_version);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(envelope, .{}, &out.writer);
    try out.writer.writeByte('\n');
    if (out.written().len > event_frame_max_bytes) return error.EventFrameTooLarge;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn decodeConversationFrame(
    alloc: Allocator,
    bytes: []const u8,
) !DecodedConversationFrame {
    if (bytes.len == 0 or bytes.len > event_frame_max_bytes or bytes[bytes.len - 1] != '\n') {
        return error.InvalidConversationFrame;
    }
    var parsed = std.json.parseFromSlice(ConversationEnvelope, alloc, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = event_frame_max_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConversationFrame,
    };
    errdefer parsed.deinit();
    if (!supportedConversationSchema(parsed.value.schema_version) or
        parsed.value.seq == 0 or
        parsed.value.timestamp_ms < 0)
    {
        return error.InvalidConversationFrame;
    }
    validateConversationEventShape(parsed.value.event, parsed.value.schema_version) catch
        return error.InvalidConversationFrame;
    return parsed;
}

/// Appends borrowed conversational events for one canonical history turn.
/// The caller owns only the destination list storage; event payloads remain
/// valid for the lifetime of `turn`.
pub fn appendHistoryTurnConversationEvents(
    alloc: Allocator,
    events: *std.ArrayList(ConversationEvent),
    turn: types.HistoryTurn,
) !void {
    const initial_len = events.items.len;
    errdefer events.shrinkRetainingCapacity(initial_len);
    switch (turn) {
        .assistant => |entry| {
            try events.append(alloc, .{ .user = .{
                .text = entry.user.text,
                .images = entry.user.images,
                .work_id = entry.user.work_id,
            } });
            try appendExecutionConversationEvents(alloc, events, entry.execution);
            const follows_standalone = entry.execution.tool_steps.len > 0 and
                entry.execution.tool_steps[entry.execution.tool_steps.len - 1].tool_calls.len == 0;
            if (entry.assistant.len > 0 or entry.provider_replay != null or follows_standalone) {
                try events.append(alloc, .{ .assistant = .{ .text = entry.assistant, .provider_replay = entry.provider_replay } });
            }
            try events.append(alloc, .{ .turn_completed = .{
                .files = entry.execution.files,
                .turn_summary = entry.execution.turn_summary,
            } });
        },
        .interrupted => |entry| {
            try events.append(alloc, .{ .user = .{
                .text = entry.user.text,
                .images = entry.user.images,
                .work_id = entry.user.work_id,
            } });
            try appendExecutionConversationEvents(alloc, events, entry.execution);
            if (entry.tool_call) |call| {
                if (entry.execution.tool_steps.len > 0 and
                    entry.execution.tool_steps[entry.execution.tool_steps.len - 1].tool_calls.len == 0)
                {
                    try events.append(alloc, .{ .assistant = .{ .text = "" } });
                }
                try events.append(alloc, .{ .tool_call = .{
                    .call_id = call.id,
                    .tool_name = call.name,
                    .arguments_json = call.arguments_json,
                    .argument_integrity = call.argument_integrity,
                    .provisional_id = call.provisional_id,
                    .provider_result = call.provider_result,
                    .final_identity = call.final_identity,
                    .provenance = call.provenance,
                } });
            }
            try events.append(alloc, .{ .interrupted = .{
                .reason = entry.terminal_reason,
                .cancellation_origin = entry.cancellation_origin,
                .partial_text = entry.assistant,
                .command_replay_ref = interruptedCommandReplayRef(entry),
                .command_replay_bytes = interruptedCommandReplayBytes(entry),
                .command_artifact_ref = if (entry.cancelled_command) |presentation|
                    presentation.command_artifact_handle
                else
                    null,
                .files = entry.execution.files,
                .turn_summary = entry.execution.turn_summary,
            } });
        },
        .compacted_summary => return error.ConversationCheckpointRequiresSequence,
    }
}

fn interruptedCommandReplayRef(
    entry: types.InterruptedHistoryTurn,
) ?[]const u8 {
    const replay = (entry.cancelled_command orelse return null).output_replay orelse
        return null;
    return switch (replay) {
        .available => |descriptor| descriptor.handle,
        .unavailable => null,
    };
}

fn interruptedCommandReplayBytes(
    entry: types.InterruptedHistoryTurn,
) ?u64 {
    const replay = (entry.cancelled_command orelse return null).output_replay orelse
        return null;
    return switch (replay) {
        .available => |descriptor| @intCast(descriptor.framed_bytes),
        .unavailable => null,
    };
}

pub fn appendExecutionConversationEvents(
    alloc: Allocator,
    events: *std.ArrayList(ConversationEvent),
    execution: types.ExecutionMemory,
) !void {
    var steering_index: usize = 0;
    while (steering_index < execution.steering.len and
        execution.steering[steering_index].after_tool_step_count == 0)
    {
        try appendSteeringConversationEvents(alloc, events, execution.steering[steering_index]);
        steering_index += 1;
    }
    for (execution.tool_steps, 0..) |step, step_index| {
        const assistant: []const u8 = step.assistant orelse "";
        const follows_standalone = step_index > 0 and execution.tool_steps[step_index - 1].tool_calls.len == 0;
        if (assistant.len > 0 or step.provider_replay != null or follows_standalone) {
            try events.append(alloc, .{ .assistant = .{
                .text = assistant,
                .provider_replay = step.provider_replay,
                .standalone_response = step.tool_calls.len == 0,
            } });
        }
        for (step.tool_calls) |call| {
            try events.append(alloc, .{ .tool_call = .{
                .call_id = call.id,
                .tool_name = call.name,
                .arguments_json = call.arguments_json,
                .argument_integrity = call.argument_integrity,
                .provisional_id = call.provisional_id,
                .provider_result = call.provider_result,
                .final_identity = call.final_identity,
                .provenance = call.provenance,
            } });
        }
        for (step.tool_results) |result| {
            const artifact_ref = resultArtifactRef(result) orelse
                return error.ConversationArtifactRequired;
            if (result.tool_images.len > 0 and result.tool_image_handle == null) {
                return error.ConversationArtifactRequired;
            }
            try events.append(alloc, .{ .tool_result = .{
                .call_id = result.tool_call_id,
                .tool_name = result.tool_name,
                .status = result.status,
                .artifact_ref = artifact_ref,
                .tool_image_handle = result.tool_image_handle,
                .output_bytes = std.math.cast(u64, result.output_bytes) orelse
                    return rejectInvalidConversationEvent("tool-result-output-bytes"),
                .stored_bytes = std.math.cast(u64, result.stored_output_bytes) orelse
                    return rejectInvalidConversationEvent("tool-result-stored-bytes"),
                .completeness = if (result.truncated) .partial else .complete,
                .preview = result.preview orelse if (result.output.len <= max_conversation_preview_bytes)
                    result.output
                else
                    null,
                .provider_native = result.provider_native,
                .review_feedback = result.review_feedback,
                .created_at_ms = result.created_at_ms,
                .permission_feedback = result.permission_feedback,
                .committed_file_presentation = result.committed_file_presentation,
                .command_replay_ref = resultCommandReplayRef(result),
                .command_replay_bytes = resultCommandReplayBytes(result),
                .command_process_presentation = result.command_process_presentation,
                .terminal_action_presentation = result.terminal_action_presentation,
            } });
        }
        const completed_steps = step_index + 1;
        while (steering_index < execution.steering.len and
            execution.steering[steering_index].after_tool_step_count == completed_steps)
        {
            try appendSteeringConversationEvents(alloc, events, execution.steering[steering_index]);
            steering_index += 1;
        }
    }
    if (steering_index != execution.steering.len) {
        return rejectInvalidConversationEvent("steering-boundary");
    }
}

fn appendSteeringConversationEvents(
    alloc: Allocator,
    events: *std.ArrayList(ConversationEvent),
    steering: types.PersistedSteering,
) !void {
    if (steering.assistant_prefix) |assistant| {
        if (assistant.len > 0) try events.append(alloc, .{ .assistant = .{ .text = assistant } });
    }
    if (steering.text.len > 0) {
        try events.append(alloc, .{ .steering = .{ .text = steering.text } });
    }
}

fn resultArtifactRef(result: types.PersistedToolResult) ?[]const u8 {
    if (result.output_handle) |handle| return handle;
    const replay = result.command_output_replay orelse return null;
    return switch (replay) {
        .available => |descriptor| descriptor.handle,
        .unavailable => null,
    };
}

fn resultCommandReplayRef(result: types.PersistedToolResult) ?[]const u8 {
    const replay = result.command_output_replay orelse return null;
    return switch (replay) {
        .available => |descriptor| descriptor.handle,
        .unavailable => null,
    };
}

fn resultCommandReplayBytes(result: types.PersistedToolResult) ?u64 {
    const replay = result.command_output_replay orelse return null;
    return switch (replay) {
        .available => |descriptor| @intCast(descriptor.framed_bytes),
        .unavailable => null,
    };
}

pub const Kind = enum {
    session_started,
    preferences_changed,
    workspace_rebound,
    history_turn_committed,
    usage_checkpointed,
    recovery_checkpoint_set,
    recovery_checkpoint_cleared,
    state_replacement_started,
    state_replacement_chunk,
    state_replacement_committed,
};

pub const ReplacementReason = enum {
    compaction,
    migration,
    recovery,
    log_compaction,
};

pub const SessionStarted = struct {
    id: []u8,
    created_at_ms: i64,
    origin_workspace_root: []u8,
    workspace_root: []u8,
    conversation_language: session.ConversationLanguage,
    preferences: session_codec.DurableSessionPreferences,
    usage: ?session_usage.Snapshot = null,
    subagent_child: bool = false,

    fn deinit(self: *SessionStarted, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.origin_workspace_root);
        alloc.free(self.workspace_root);
        self.preferences.deinit(alloc);
        if (self.usage) |*usage| usage.deinit(alloc);
        self.* = undefined;
    }
};

pub const PreferencesChanged = struct {
    provider: ?model_provider.ProviderId = null,
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,
    fast_mode: ?bool = null,

    fn deinit(self: *PreferencesChanged, alloc: Allocator) void {
        if (self.model) |model| alloc.free(model);
        self.* = undefined;
    }
};

pub const WorkspaceRebound = struct {
    previous_workspace_root: []u8,
    workspace_root: []u8,

    fn deinit(self: *WorkspaceRebound, alloc: Allocator) void {
        alloc.free(self.previous_workspace_root);
        alloc.free(self.workspace_root);
        self.* = undefined;
    }
};

pub const HistoryTurnCommitted = struct {
    conversation_language: session.ConversationLanguage,
    total_input_tokens: u64,
    total_output_tokens: u64,
    work_id: ?[]u8 = null,
    turn: session.HistoryTurn,

    fn deinit(self: *HistoryTurnCommitted, alloc: Allocator) void {
        if (self.work_id) |id| alloc.free(id);
        session.freeHistoryTurn(alloc, self.turn);
        self.* = undefined;
    }
};

pub const UsageCheckpointed = struct {
    /// Full cumulative replacement; reducers must not add it to prior usage.
    usage: session_usage.Snapshot,

    fn deinit(self: *UsageCheckpointed, alloc: Allocator) void {
        self.usage.deinit(alloc);
        self.* = undefined;
    }
};

pub const RecoveryCheckpointSet = struct {
    checkpoint: session_codec.RecoveryCheckpoint,

    fn deinit(self: *RecoveryCheckpointSet, alloc: Allocator) void {
        self.checkpoint.deinit(alloc);
        self.* = undefined;
    }
};

pub const RecoveryCheckpointCleared = struct {};

pub const StateReplacementStarted = struct {
    replacement_id: Identifier,
    reason: ReplacementReason,
    encoded_bytes: u64,
    sha256: Digest,
    chunk_count: u64,
};

pub const StateReplacementChunk = struct {
    replacement_id: Identifier,
    chunk_index: u64,
    raw_bytes: u64,
    chunk_sha256: Digest,
    bytes: []u8,

    fn deinit(self: *StateReplacementChunk, alloc: Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

pub const StateReplacementCommitted = struct {
    replacement_id: Identifier,
    encoded_bytes: u64,
    sha256: Digest,
    chunk_count: u64,
};

pub const Event = union(Kind) {
    session_started: SessionStarted,
    preferences_changed: PreferencesChanged,
    workspace_rebound: WorkspaceRebound,
    history_turn_committed: HistoryTurnCommitted,
    usage_checkpointed: UsageCheckpointed,
    recovery_checkpoint_set: RecoveryCheckpointSet,
    recovery_checkpoint_cleared: RecoveryCheckpointCleared,
    state_replacement_started: StateReplacementStarted,
    state_replacement_chunk: StateReplacementChunk,
    state_replacement_committed: StateReplacementCommitted,

    fn deinit(self: *Event, alloc: Allocator) void {
        switch (self.*) {
            .session_started => |*payload| payload.deinit(alloc),
            .preferences_changed => |*payload| payload.deinit(alloc),
            .workspace_rebound => |*payload| payload.deinit(alloc),
            .history_turn_committed => |*payload| payload.deinit(alloc),
            .usage_checkpointed => |*payload| payload.deinit(alloc),
            .recovery_checkpoint_set => |*payload| payload.deinit(alloc),
            .recovery_checkpoint_cleared => {},
            .state_replacement_chunk => |*payload| payload.deinit(alloc),
            .state_replacement_started, .state_replacement_committed => {},
        }
        self.* = undefined;
    }
};

pub const Envelope = struct {
    log_generation: Identifier,
    seq: u64,
    event_id: Identifier,
    timestamp_ms: i64,
    event: Event,

    pub fn kind(self: Envelope) Kind {
        return std.meta.activeTag(self.event);
    }

    pub fn deinit(self: *Envelope, alloc: Allocator) void {
        self.event.deinit(alloc);
        self.* = undefined;
    }
};

pub const SequenceValidator = struct {
    generation: ?Identifier = null,
    next_seq: u64 = 1,

    pub fn validate(self: *SequenceValidator, envelope: Envelope) !void {
        if (envelope.seq != self.next_seq) return error.NonContiguousSequence;
        if (self.generation) |generation| {
            if (!std.mem.eql(u8, &generation, &envelope.log_generation)) {
                return error.GenerationChanged;
            }
        } else {
            self.generation = envelope.log_generation;
        }
        self.next_seq = std.math.add(u64, self.next_seq, 1) catch
            return error.NonContiguousSequence;
    }
};

pub const ReductionStart = struct {
    generation: ?Identifier = null,
    next_seq: u64 = 1,
};

pub const ReductionBoundary = struct {
    log_generation: Identifier,
    seq: u64,
    event_id: Identifier,
    byte_offset: u64,
};

pub const Reduction = struct {
    state: session_codec.DurableSessionState,
    truncate_from: ?u64 = null,
    through: ?ReductionBoundary = null,
    bytes_consumed: u64 = 0,

    pub fn deinit(self: *Reduction, alloc: Allocator) void {
        self.state.deinit(alloc);
        self.* = undefined;
    }
};

inline fn failEnvelope(err: anytype) @TypeOf(err)!Envelope {
    return @errorCast(failEnvelopeDynamic(err));
}

noinline fn failEnvelopeDynamic(err: anyerror) anyerror!Envelope {
    return err;
}

pub fn decodeFrame(alloc: Allocator, line: []const u8) !Envelope {
    if (line.len > event_frame_max_bytes) return failEnvelope(error.EventFrameTooLarge);
    if (line.len == 0 or line[line.len - 1] != '\n') {
        return failEnvelope(error.InvalidEventFrame);
    }
    if (std.mem.findScalar(u8, line[0 .. line.len - 1], '\n') != null) {
        return failEnvelope(error.InvalidEventFrame);
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line[0 .. line.len - 1], .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return failEnvelope(error.OutOfMemory),
        else => return failEnvelope(error.InvalidEventFrame),
    };
    defer parsed.deinit();
    const root = try exactObject(parsed.value, &.{
        "schema_version",
        "log_generation",
        "seq",
        "event_id",
        "timestamp_ms",
        "kind",
        "payload",
    });
    if (try requireU64(root, "schema_version") != 1) return failEnvelope(error.UnsupportedEventSchema);
    const kind = std.meta.stringToEnum(Kind, try requireString(root, "kind")) orelse
        return failEnvelope(error.InvalidEventFrame);
    var envelope = Envelope{
        .log_generation = try parseIdentifier(try requireString(root, "log_generation")),
        .seq = try requireU64(root, "seq"),
        .event_id = try parseIdentifier(try requireString(root, "event_id")),
        .timestamp_ms = try requireI64(root, "timestamp_ms"),
        .event = try parsePayload(alloc, kind, root.get("payload") orelse return failEnvelope(error.InvalidEventFrame)),
    };
    errdefer envelope.deinit(alloc);
    try validateEnvelope(envelope);
    return envelope;
}

pub fn reduceJsonl(
    alloc: Allocator,
    source: *std.Io.Reader,
    initial: ?session_codec.DurableSessionState,
) !Reduction {
    return reduceJsonlFrom(alloc, source, initial, .{});
}

inline fn failReduction(err: anytype) @TypeOf(err)!Reduction {
    return @errorCast(failReductionDynamic(err));
}

noinline fn failReductionDynamic(err: anyerror) anyerror!Reduction {
    return err;
}

pub fn reduceJsonlFrom(
    alloc: Allocator,
    source: *std.Io.Reader,
    initial: ?session_codec.DurableSessionState,
    start: ReductionStart,
) !Reduction {
    var state = initial;
    errdefer if (state) |*owned| owned.deinit(alloc);
    if (start.next_seq == 0 or
        (state == null and (start.generation != null or start.next_seq != 1)))
    {
        return failReduction(error.InvalidReductionStart);
    }
    var validator = SequenceValidator{
        .generation = start.generation,
        .next_seq = start.next_seq,
    };
    var byte_offset: u64 = 0;
    var through: ?ReductionBoundary = null;

    while (true) {
        const line = readFrameLine(alloc, source) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        defer alloc.free(line);
        const frame_start = byte_offset;
        byte_offset += line.len;

        var envelope = try decodeFrame(alloc, line);
        defer envelope.deinit(alloc);
        try validator.validate(envelope);

        if (envelope.kind() == .state_replacement_started) {
            if (state == null) return failReduction(error.InvalidReplacement);
            const replacement = try reduceReplacement(
                alloc,
                source,
                &validator,
                &byte_offset,
                envelope,
                state.?,
            );
            if (replacement.state) |next| {
                state.?.deinit(alloc);
                state = next;
                through = replacement.through;
            } else {
                return .{
                    .state = state.?,
                    .truncate_from = frame_start,
                    .through = through,
                    .bytes_consumed = byte_offset,
                };
            }
            continue;
        }
        if (envelope.kind() == .state_replacement_chunk or
            envelope.kind() == .state_replacement_committed)
        {
            return failReduction(error.InvalidReplacement);
        }
        try applyDelta(alloc, &state, envelope);
        through = reductionBoundary(envelope, byte_offset);
    }

    return .{
        .state = state orelse return failReduction(error.MissingSessionStarted),
        .through = through,
        .bytes_consumed = byte_offset,
    };
}

const ReplacementOutcome = struct {
    state: ?session_codec.DurableSessionState,
    through: ?ReductionBoundary = null,
};

fn reduceReplacement(
    alloc: Allocator,
    source: *std.Io.Reader,
    validator: *SequenceValidator,
    byte_offset: *u64,
    start_envelope: Envelope,
    prior: session_codec.DurableSessionState,
) !ReplacementOutcome {
    const start = start_envelope.event.state_replacement_started;
    var chunk_reader: ReplacementStateReader = undefined;
    try chunk_reader.init(
        alloc,
        source,
        validator,
        byte_offset,
        start_envelope.log_generation,
        start,
    );
    defer chunk_reader.deinit();

    var decoded = session_codec.decodeLegacyState(alloc, &chunk_reader.interface, .{}) catch |err| {
        if (chunk_reader.truncated) return .{ .state = null };
        if (chunk_reader.failure) |failure| return failure;
        return err;
    };
    errdefer decoded.deinit(alloc);
    try chunk_reader.finish();

    const commit_line = readFrameLine(alloc, source) catch |err| switch (err) {
        error.EndOfStream, error.TruncatedEventFrame => {
            decoded.deinit(alloc);
            return .{ .state = null };
        },
        else => return err,
    };
    defer alloc.free(commit_line);
    byte_offset.* += commit_line.len;
    var commit_envelope = try decodeFrame(alloc, commit_line);
    defer commit_envelope.deinit(alloc);
    try validator.validate(commit_envelope);
    if (commit_envelope.kind() != .state_replacement_committed) return error.InvalidReplacement;
    const commit = commit_envelope.event.state_replacement_committed;
    if (!std.mem.eql(u8, &commit.replacement_id, &start.replacement_id) or
        commit.encoded_bytes != start.encoded_bytes or
        commit.chunk_count != start.chunk_count or
        !std.mem.eql(u8, &commit.sha256, &start.sha256))
    {
        return error.InvalidReplacement;
    }

    if (!std.mem.eql(u8, decoded.id, prior.id) or
        decoded.created_at_ms != prior.created_at_ms or
        !std.mem.eql(u8, decoded.origin_workspace_root, prior.origin_workspace_root) or
        !std.mem.eql(u8, decoded.workspace_root, prior.workspace_root) or
        decoded.updated_at_ms != commit_envelope.timestamp_ms)
    {
        return error.ImmutableSessionIdentity;
    }
    if (start.reason == .log_compaction and
        commit_envelope.timestamp_ms != prior.updated_at_ms)
    {
        return error.InvalidReplacement;
    }
    return .{
        .state = decoded,
        .through = reductionBoundary(commit_envelope, byte_offset.*),
    };
}

fn reductionBoundary(envelope: Envelope, byte_offset: u64) ReductionBoundary {
    return .{
        .log_generation = envelope.log_generation,
        .seq = envelope.seq,
        .event_id = envelope.event_id,
        .byte_offset = byte_offset,
    };
}

const ReplacementStateReader = struct {
    alloc: Allocator,
    source: *std.Io.Reader,
    validator: *SequenceValidator,
    byte_offset: *u64,
    generation: Identifier,
    start: StateReplacementStarted,
    chunk_index: u64 = 0,
    raw_total: u64 = 0,
    overall_sha256: Sha256 = Sha256.init(.{}),
    current: ?Envelope = null,
    current_offset: usize = 0,
    truncated: bool = false,
    failure: ?anyerror = null,
    buffer: [4096]u8 = undefined,
    interface: std.Io.Reader = undefined,

    fn init(
        self: *ReplacementStateReader,
        alloc: Allocator,
        source: *std.Io.Reader,
        validator: *SequenceValidator,
        byte_offset: *u64,
        generation: Identifier,
        start: StateReplacementStarted,
    ) !void {
        if (start.encoded_bytes == 0 or start.chunk_count == 0 or
            start.chunk_count != @divCeil(start.encoded_bytes, @as(u64, raw_state_chunk_bytes)))
        {
            return error.InvalidReplacement;
        }
        self.* = .{
            .alloc = alloc,
            .source = source,
            .validator = validator,
            .byte_offset = byte_offset,
            .generation = generation,
            .start = start,
        };
        self.interface = .{
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
    }

    fn deinit(self: *ReplacementStateReader) void {
        if (self.current) |*envelope| envelope.deinit(self.alloc);
        self.* = undefined;
    }

    fn finish(self: *ReplacementStateReader) !void {
        if (self.chunk_index != self.start.chunk_count or
            self.raw_total != self.start.encoded_bytes or
            !std.mem.eql(u8, &self.overall_sha256.finalResult(), &self.start.sha256))
        {
            return error.InvalidReplacement;
        }
    }

    fn readVec(reader: *std.Io.Reader, destinations: [][]u8) std.Io.Reader.Error!usize {
        const self: *ReplacementStateReader = @alignCast(@fieldParentPtr("interface", reader));
        for (destinations) |destination| {
            if (destination.len == 0) continue;
            return self.copyInto(destination) catch |err| {
                if (err == error.EndOfStream) return error.EndOfStream;
                self.failure = err;
                return error.ReadFailed;
            };
        }
        const destination = reader.buffer[reader.end..];
        if (destination.len == 0) return 0;
        const count = self.copyInto(destination) catch |err| {
            if (err == error.EndOfStream) return error.EndOfStream;
            self.failure = err;
            return error.ReadFailed;
        };
        reader.end += count;
        return 0;
    }

    fn copyInto(self: *ReplacementStateReader, destination: []u8) !usize {
        if (self.currentBytes().len == 0) try self.loadChunk();
        const available = self.currentBytes();
        const count = @min(destination.len, available.len);
        @memcpy(destination[0..count], available[0..count]);
        self.current_offset += count;
        return count;
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const destination = limit.slice(try writer.writableSliceGreedy(1));
        var destinations = [1][]u8{destination};
        const count = readVec(reader, &destinations) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        writer.advance(count);
        return count;
    }

    fn currentBytes(self: *ReplacementStateReader) []const u8 {
        const envelope = self.current orelse return &.{};
        const bytes = envelope.event.state_replacement_chunk.bytes;
        return bytes[self.current_offset..];
    }

    fn loadChunk(self: *ReplacementStateReader) !void {
        if (self.current) |*envelope| {
            envelope.deinit(self.alloc);
            self.current = null;
        }
        self.current_offset = 0;
        if (self.chunk_index == self.start.chunk_count) return error.EndOfStream;

        const line = readFrameLine(self.alloc, self.source) catch |err| switch (err) {
            error.EndOfStream, error.TruncatedEventFrame => {
                self.truncated = true;
                return error.EndOfStream;
            },
            else => return err,
        };
        defer self.alloc.free(line);
        self.byte_offset.* += line.len;
        var envelope = try decodeFrame(self.alloc, line);
        errdefer envelope.deinit(self.alloc);
        try self.validator.validate(envelope);
        if (!std.mem.eql(u8, &envelope.log_generation, &self.generation) or
            envelope.kind() != .state_replacement_chunk)
        {
            return error.InvalidReplacement;
        }
        const chunk = envelope.event.state_replacement_chunk;
        const final = self.chunk_index + 1 == self.start.chunk_count;
        const expected_raw: u64 = if (final)
            self.start.encoded_bytes - self.raw_total
        else
            raw_state_chunk_bytes;
        if (!std.mem.eql(u8, &chunk.replacement_id, &self.start.replacement_id) or
            chunk.chunk_index != self.chunk_index or
            chunk.raw_bytes != expected_raw or
            chunk.bytes.len != expected_raw or
            (!final and chunk.raw_bytes != raw_state_chunk_bytes) or
            (final and (chunk.raw_bytes == 0 or chunk.raw_bytes > raw_state_chunk_bytes)) or
            !std.mem.eql(u8, &sha256(chunk.bytes), &chunk.chunk_sha256))
        {
            return error.InvalidReplacement;
        }
        self.overall_sha256.update(chunk.bytes);
        self.raw_total += chunk.raw_bytes;
        self.chunk_index += 1;
        self.current = envelope;
    }
};

fn applyDelta(
    alloc: Allocator,
    state: *?session_codec.DurableSessionState,
    envelope: Envelope,
) !void {
    switch (envelope.event) {
        .session_started => |payload| {
            if (state.* != null) {
                return error.ImmutableSessionIdentity;
            }
            var next = session_codec.DurableSessionState{
                .id = try alloc.dupe(u8, payload.id),
                .origin_workspace_root = undefined,
                .workspace_root = undefined,
                .created_at_ms = payload.created_at_ms,
                .updated_at_ms = envelope.timestamp_ms,
                .conversation_language = payload.conversation_language,
                .preferences = undefined,
                .history = &.{},
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .subagent_child = payload.subagent_child,
            };
            errdefer alloc.free(next.id);
            next.origin_workspace_root = try alloc.dupe(u8, payload.origin_workspace_root);
            errdefer alloc.free(next.origin_workspace_root);
            next.workspace_root = try alloc.dupe(u8, payload.workspace_root);
            errdefer alloc.free(next.workspace_root);
            next.preferences = try payload.preferences.dupe(alloc);
            errdefer next.preferences.deinit(alloc);
            next.usage = if (payload.usage) |snapshot|
                try session_usage.dupeSnapshotOwned(alloc, snapshot)
            else
                null;
            errdefer if (next.usage) |*usage| usage.deinit(alloc);
            try session_codec.validateState(next);
            state.* = next;
        },
        .preferences_changed => |payload| {
            var current = &(state.* orelse return error.MissingSessionStarted);
            var proposed = current.*;
            if (payload.provider) |provider| proposed.preferences.provider = provider;
            if (payload.model) |model| proposed.preferences.model = model;
            if (payload.effort) |effort| proposed.preferences.effort = effort;
            if (payload.fast_mode) |fast_mode| proposed.preferences.fast_mode = fast_mode;
            proposed.updated_at_ms = envelope.timestamp_ms;
            try session_codec.validateState(proposed);
            const model_copy = if (payload.model) |model|
                try alloc.dupe(u8, model)
            else
                null;
            if (model_copy) |copy| {
                alloc.free(current.preferences.model);
                current.preferences.model = copy;
            }
            if (payload.provider) |provider| current.preferences.provider = provider;
            if (payload.effort) |effort| current.preferences.effort = effort;
            if (payload.fast_mode) |fast_mode| current.preferences.fast_mode = fast_mode;
            current.updated_at_ms = envelope.timestamp_ms;
        },
        .workspace_rebound => |payload| {
            var current = &(state.* orelse return error.MissingSessionStarted);
            if (!std.mem.eql(u8, payload.previous_workspace_root, current.workspace_root) or
                std.mem.eql(u8, payload.workspace_root, current.workspace_root))
            {
                return error.ImmutableSessionIdentity;
            }
            var proposed = current.*;
            proposed.workspace_root = payload.workspace_root;
            proposed.updated_at_ms = envelope.timestamp_ms;
            try session_codec.validateState(proposed);
            const copy = try alloc.dupe(u8, payload.workspace_root);
            alloc.free(current.workspace_root);
            current.workspace_root = copy;
            current.updated_at_ms = envelope.timestamp_ms;
        },
        .history_turn_committed => |payload| {
            var current = &(state.* orelse return error.MissingSessionStarted);
            const association = session.decideWorkIdAssociation(
                payload.turn,
                payload.work_id,
            ) catch return error.InvalidEventFrame;
            var turn = try session.dupeHistoryTurn(alloc, payload.turn);
            errdefer session.freeHistoryTurn(alloc, turn);
            if (association == .copy_event) {
                session.copyWorkIdToTurn(alloc, &turn, payload.work_id.?) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidWorkId, error.ConflictingWorkId => return error.InvalidEventFrame,
                };
            }
            const work_id = if (payload.work_id) |id| try alloc.dupe(u8, id) else null;
            errdefer if (work_id) |id| alloc.free(id);
            if (current.history.len == 0) {
                current.history = try alloc.alloc(session.HistoryTurn, 1);
            } else {
                current.history = try alloc.realloc(current.history, current.history.len + 1);
            }
            current.history[current.history.len - 1] = turn;
            if (payload.turn == .compacted_summary) {
                current.context_history_start = current.history.len - 1;
            }
            current.conversation_language = payload.conversation_language;
            current.total_input_tokens = payload.total_input_tokens;
            current.total_output_tokens = payload.total_output_tokens;
            if (work_id) |id| {
                if (current.last_subagent_work_id) |old| alloc.free(old);
                current.last_subagent_work_id = id;
            }
            // A session owns at most one active model turn. Clearing its
            // checkpoint in the same reduction as the history commit closes
            // the crash window between durable completion and a later clear.
            if (current.recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
            current.recovery_checkpoint = null;
            current.updated_at_ms = envelope.timestamp_ms;
        },
        .usage_checkpointed => |payload| {
            var current = &(state.* orelse return error.MissingSessionStarted);
            const usage = try session_usage.dupeSnapshotOwned(alloc, payload.usage);
            if (current.usage) |*old| old.deinit(alloc);
            current.usage = usage;
            current.updated_at_ms = envelope.timestamp_ms;
        },
        .recovery_checkpoint_set => |payload| {
            var current = &(state.* orelse return error.MissingSessionStarted);
            const checkpoint = try payload.checkpoint.dupe(alloc);
            if (current.recovery_checkpoint) |*old| old.deinit(alloc);
            current.recovery_checkpoint = checkpoint;
            current.updated_at_ms = envelope.timestamp_ms;
        },
        .recovery_checkpoint_cleared => {
            var current = &(state.* orelse return error.MissingSessionStarted);
            if (current.recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
            current.recovery_checkpoint = null;
            current.updated_at_ms = envelope.timestamp_ms;
        },
        .state_replacement_started, .state_replacement_chunk, .state_replacement_committed => {
            return error.InvalidReplacement;
        },
    }
}

fn validateEnvelope(envelope: Envelope) !void {
    if (envelope.seq == 0 or envelope.timestamp_ms < 0) return error.InvalidEventFrame;
    switch (envelope.event) {
        .session_started => |payload| {
            const state = session_codec.DurableSessionState{
                .id = payload.id,
                .origin_workspace_root = payload.origin_workspace_root,
                .workspace_root = payload.workspace_root,
                .created_at_ms = payload.created_at_ms,
                .updated_at_ms = envelope.timestamp_ms,
                .conversation_language = payload.conversation_language,
                .preferences = payload.preferences,
                .history = &.{},
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .usage = payload.usage,
                .subagent_child = payload.subagent_child,
            };
            try session_codec.validateState(state);
        },
        .preferences_changed => |payload| {
            if (payload.provider == null and payload.model == null and payload.effort == null and payload.fast_mode == null) {
                return error.InvalidEventFrame;
            }
            if (payload.model) |model| {
                const state = session_codec.DurableSessionState{
                    .id = @constCast("validation"),
                    .origin_workspace_root = @constCast("/"),
                    .workspace_root = @constCast("/"),
                    .created_at_ms = 0,
                    .updated_at_ms = 0,
                    .conversation_language = session.ConversationLanguage.literal("en"),
                    .preferences = .{
                        .model = model,
                        .effort = .auto,
                        .fast_mode = false,
                    },
                    .history = &.{},
                    .total_input_tokens = 0,
                    .total_output_tokens = 0,
                };
                try session_codec.validateState(state);
            }
        },
        .workspace_rebound => |payload| {
            if (payload.previous_workspace_root.len == 0 or payload.workspace_root.len == 0) {
                return error.InvalidEventFrame;
            }
        },
        .history_turn_committed => |payload| _ = session.decideWorkIdAssociation(
            payload.turn,
            payload.work_id,
        ) catch return error.InvalidEventFrame,
        .usage_checkpointed => |payload| try session_usage.validateSnapshot(payload.usage),
        .recovery_checkpoint_set => |payload| {
            const state = session_codec.DurableSessionState{
                .id = @constCast("validation"),
                .origin_workspace_root = @constCast("/"),
                .workspace_root = @constCast("/"),
                .created_at_ms = 0,
                .updated_at_ms = 0,
                .conversation_language = session.ConversationLanguage.literal("en"),
                .preferences = .{
                    .model = @constCast("test/model"),
                    .effort = .auto,
                    .fast_mode = false,
                },
                .history = &.{},
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .recovery_checkpoint = payload.checkpoint,
            };
            try session_codec.validateState(state);
        },
        .recovery_checkpoint_cleared => {},
        .state_replacement_started => |payload| {
            if (payload.encoded_bytes == 0 or payload.chunk_count == 0) {
                return error.InvalidReplacement;
            }
        },
        .state_replacement_chunk => |payload| {
            if (payload.raw_bytes == 0 or payload.raw_bytes > raw_state_chunk_bytes or
                payload.bytes.len != payload.raw_bytes or
                !std.mem.eql(u8, &sha256(payload.bytes), &payload.chunk_sha256))
            {
                return error.InvalidReplacement;
            }
        },
        .state_replacement_committed => |payload| {
            if (payload.encoded_bytes == 0 or payload.chunk_count == 0) {
                return error.InvalidReplacement;
            }
        },
    }
}

fn parsePayload(alloc: Allocator, kind: Kind, value: std.json.Value) !Event {
    return switch (kind) {
        .session_started => blk: {
            const source = try requireObject(value);
            if (source.count() < 6 or source.count() > 8) {
                return error.InvalidEventFrame;
            }
            try rejectUnknownKeys(source, &.{
                "id",
                "created_at_ms",
                "origin_workspace_root",
                "workspace_root",
                "conversation_language",
                "preferences",
                "usage",
                "subagent_child",
            });
            const object = source;
            const id = try dupeString(alloc, object, "id");
            errdefer alloc.free(id);
            const origin = try dupeString(alloc, object, "origin_workspace_root");
            errdefer alloc.free(origin);
            const current = try dupeString(alloc, object, "workspace_root");
            errdefer alloc.free(current);
            const preferences = try parsePreferences(
                alloc,
                object.get("preferences") orelse return error.InvalidEventFrame,
            );
            errdefer {
                var owned = preferences;
                owned.deinit(alloc);
            }
            var usage = if (object.get("usage")) |usage_value|
                session_usage.parseLegacySnapshotValue(alloc, usage_value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidEventFrame,
                }
            else
                null;
            errdefer if (usage) |*snapshot| snapshot.deinit(alloc);
            const subagent_child = if (object.get("subagent_child")) |raw|
                if (raw == .bool and raw.bool)
                    true
                else
                    return error.InvalidEventFrame
            else
                false;
            break :blk .{ .session_started = .{
                .id = id,
                .created_at_ms = try requireI64(object, "created_at_ms"),
                .origin_workspace_root = origin,
                .workspace_root = current,
                .conversation_language = parseLanguage(
                    try requireString(object, "conversation_language"),
                ) catch return error.InvalidEventFrame,
                .preferences = preferences,
                .usage = usage,
                .subagent_child = subagent_child,
            } };
        },
        .preferences_changed => blk: {
            const object = try requireObject(value);
            if (object.count() == 0 or object.count() > 4) return error.InvalidEventFrame;
            try rejectUnknownKeys(object, &.{ "provider", "model", "effort", "fast_mode" });
            const provider = if (object.get("provider")) |provider_value| provider_blk: {
                break :provider_blk model_provider.parse_saved(provider_value) catch return error.InvalidEventFrame;
            } else null;
            const model = if (object.get("model")) |_| try dupeString(alloc, object, "model") else null;
            errdefer if (model) |owned| alloc.free(owned);
            const effort = if (object.get("effort")) |_|
                types.ReasoningEffort.parse(try requireString(object, "effort")) orelse
                    return error.InvalidEventFrame
            else
                null;
            const fast_mode = if (object.get("fast_mode")) |_| try requireBool(object, "fast_mode") else null;
            break :blk .{ .preferences_changed = .{
                .provider = provider,
                .model = model,
                .effort = effort,
                .fast_mode = fast_mode,
            } };
        },
        .workspace_rebound => blk: {
            const object = try exactObject(value, &.{ "previous_workspace_root", "workspace_root" });
            const previous = try dupeString(alloc, object, "previous_workspace_root");
            errdefer alloc.free(previous);
            break :blk .{ .workspace_rebound = .{
                .previous_workspace_root = previous,
                .workspace_root = try dupeString(alloc, object, "workspace_root"),
            } };
        },
        .history_turn_committed => blk: {
            const source = try requireObject(value);
            const object = if (source.count() == 4)
                try exactObject(value, &.{
                    "conversation_language",
                    "total_input_tokens",
                    "total_output_tokens",
                    "turn",
                })
            else
                try exactObject(value, &.{
                    "conversation_language",
                    "total_input_tokens",
                    "total_output_tokens",
                    "turn",
                    "work_id",
                });
            const turn = try session_codec.parseHistoryTurn(
                alloc,
                object.get("turn") orelse return error.InvalidEventFrame,
            );
            errdefer session.freeHistoryTurn(alloc, turn);
            const work_id = if (object.get("work_id")) |_| try dupeString(alloc, object, "work_id") else null;
            errdefer if (work_id) |id| alloc.free(id);
            break :blk .{ .history_turn_committed = .{
                .conversation_language = parseLanguage(
                    try requireString(object, "conversation_language"),
                ) catch return error.InvalidEventFrame,
                .total_input_tokens = try requireU64(object, "total_input_tokens"),
                .total_output_tokens = try requireU64(object, "total_output_tokens"),
                .work_id = work_id,
                .turn = turn,
            } };
        },
        .usage_checkpointed => blk: {
            const object = try exactObject(value, &.{"usage"});
            var usage = session_usage.parseLegacySnapshotValue(
                alloc,
                object.get("usage") orelse return error.InvalidEventFrame,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidEventFrame,
            };
            errdefer usage.deinit(alloc);
            break :blk .{ .usage_checkpointed = .{ .usage = usage } };
        },
        .recovery_checkpoint_set => blk: {
            const object = try exactObject(value, &.{"checkpoint"});
            const checkpoint = session_codec.parseRecoveryCheckpoint(
                alloc,
                object.get("checkpoint") orelse return error.InvalidEventFrame,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidEventFrame,
            };
            break :blk .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } };
        },
        .recovery_checkpoint_cleared => blk: {
            _ = try exactObject(value, &.{});
            break :blk .{ .recovery_checkpoint_cleared = .{} };
        },
        .state_replacement_started => blk: {
            const object = try exactObject(value, &.{
                "replacement_id",
                "reason",
                "encoded_bytes",
                "sha256",
                "chunk_count",
            });
            break :blk .{ .state_replacement_started = .{
                .replacement_id = try parseIdentifier(try requireString(object, "replacement_id")),
                .reason = std.meta.stringToEnum(
                    ReplacementReason,
                    try requireString(object, "reason"),
                ) orelse return error.InvalidEventFrame,
                .encoded_bytes = try requireU64(object, "encoded_bytes"),
                .sha256 = try parseDigest(try requireString(object, "sha256")),
                .chunk_count = try requireU64(object, "chunk_count"),
            } };
        },
        .state_replacement_chunk => blk: {
            const object = try exactObject(value, &.{
                "replacement_id",
                "chunk_index",
                "raw_bytes",
                "chunk_sha256",
                "base64",
            });
            const encoded = try requireString(object, "base64");
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
                return error.InvalidEventFrame;
            const bytes = try alloc.alloc(u8, decoded_len);
            errdefer alloc.free(bytes);
            std.base64.standard.Decoder.decode(bytes, encoded) catch return error.InvalidEventFrame;
            break :blk .{ .state_replacement_chunk = .{
                .replacement_id = try parseIdentifier(try requireString(object, "replacement_id")),
                .chunk_index = try requireU64(object, "chunk_index"),
                .raw_bytes = try requireU64(object, "raw_bytes"),
                .chunk_sha256 = try parseDigest(try requireString(object, "chunk_sha256")),
                .bytes = bytes,
            } };
        },
        .state_replacement_committed => blk: {
            const object = try exactObject(value, &.{
                "replacement_id",
                "encoded_bytes",
                "sha256",
                "chunk_count",
            });
            break :blk .{ .state_replacement_committed = .{
                .replacement_id = try parseIdentifier(try requireString(object, "replacement_id")),
                .encoded_bytes = try requireU64(object, "encoded_bytes"),
                .sha256 = try parseDigest(try requireString(object, "sha256")),
                .chunk_count = try requireU64(object, "chunk_count"),
            } };
        },
    };
}

fn readFrameLine(alloc: Allocator, source: *std.Io.Reader) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    _ = source.streamDelimiterLimit(
        &out.writer,
        '\n',
        .limited(event_frame_max_bytes),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.EventFrameTooLarge,
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.OutOfMemory,
    };
    const next = source.takeByte() catch |err| switch (err) {
        error.EndOfStream => {
            if (out.written().len == 0) return error.EndOfStream;
            return error.TruncatedEventFrame;
        },
        else => return err,
    };
    if (next != '\n') return error.InvalidEventFrame;
    try out.writer.writeByte('\n');
    return try out.toOwnedSlice();
}

fn parsePreferences(alloc: Allocator, value: std.json.Value) !session_codec.DurableSessionPreferences {
    return session_codec.parse_preferences(alloc, value) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidEventFrame,
    };
}

fn exactObject(value: std.json.Value, keys: []const []const u8) !std.json.ObjectMap {
    const object = try requireObject(value);
    if (object.count() != keys.len) return error.InvalidEventFrame;
    try rejectUnknownKeys(object, keys);
    return object;
}

fn rejectUnknownKeys(object: std.json.ObjectMap, keys: []const []const u8) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (keys) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidEventFrame;
    }
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidEventFrame;
    return value.object;
}

fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidEventFrame;
    if (value != .string) return error.InvalidEventFrame;
    return value.string;
}

fn dupeString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    return try alloc.dupe(u8, try requireString(object, key));
}

fn requireBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidEventFrame;
    if (value != .bool) return error.InvalidEventFrame;
    return value.bool;
}

fn requireI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidEventFrame;
    return switch (value) {
        .integer => |number| number,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch
            error.InvalidEventFrame,
        else => error.InvalidEventFrame,
    };
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidEventFrame;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidEventFrame,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch
            error.InvalidEventFrame,
        else => error.InvalidEventFrame,
    };
}

fn parseLanguage(raw: []const u8) !session.ConversationLanguage {
    return session_codec.parseConversationLanguage(raw);
}

fn parseIdentifier(hex: []const u8) !Identifier {
    return parseHex(Identifier, hex);
}

fn parseDigest(hex: []const u8) !Digest {
    return parseHex(Digest, hex);
}

fn parseHex(comptime T: type, hex: []const u8) !T {
    if (hex.len != @sizeOf(T) * 2) return error.InvalidEventFrame;
    var value: T = undefined;
    _ = std.fmt.hexToBytes(&value, hex) catch return error.InvalidEventFrame;
    const canonical = std.fmt.bytesToHex(value, .lower);
    if (!std.mem.eql(u8, &canonical, hex)) return error.InvalidEventFrame;
    return value;
}

fn sha256(bytes: []const u8) Digest {
    var hash: Digest = undefined;
    Sha256.hash(bytes, &hash, .{});
    return hash;
}

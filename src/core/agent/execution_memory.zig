const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const message = @import("../shared/message.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;

pub fn makePersistedToolResult(
    alloc: Allocator,
    tool_call_id_src: []const u8,
    tool_name_src: []const u8,
    status: types.PersistedToolStatus,
    output_src: []const u8,
    memory: ?types.ToolResultMemory,
) !types.PersistedToolResult {
    const tool_call_id = try durableIdentifier(alloc, tool_call_id_src);
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, tool_name_src);
    errdefer alloc.free(tool_name);
    const output = try alloc.dupe(u8, output_src);
    errdefer alloc.free(output);
    const output_handle = if (memory) |info| if (info.output_handle) |handle| try alloc.dupe(u8, handle) else null else null;
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = if (memory) |info| if (info.preview) |text| try alloc.dupe(u8, text) else null else null;
    errdefer if (preview) |text| alloc.free(text);
    const command_output_replay = if (memory) |info| if (info.command_output_replay) |replay|
        try types.dupeCommandOutputReplay(alloc, replay)
    else
        null else null;
    errdefer if (command_output_replay) |replay| types.freeCommandOutputReplay(alloc, replay);
    const tool_image_handle = if (memory) |info| if (info.tool_image_handle) |handle| try alloc.dupe(u8, handle) else null else null;
    errdefer if (tool_image_handle) |handle| alloc.free(handle);
    const tool_images = if (memory) |info| if (tool_image_handle == null) try types.dupeToolImages(alloc, info.tool_images) else try alloc.alloc(types.ToolImage, 0) else try alloc.alloc(types.ToolImage, 0);
    errdefer types.freeToolImages(alloc, tool_images);
    var result: types.PersistedToolResult = .{
        .tool_images = tool_images,
        .tool_image_handle = tool_image_handle,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .status = status,
        .output = output,
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = if (memory) |info| info.output_bytes else output_src.len,
        .stored_output_bytes = if (memory) |info| info.stored_output_bytes else output.len,
        .truncated = if (memory) |info| info.truncated else false,
        .provider_native = false,
        .review_feedback = if (memory) |info| info.review_feedback else false,
        .created_at_ms = io_mod.milliTimestamp(),
        .command_output_replay = command_output_replay,
        .command_process_presentation = if (memory) |info| info.command_process_presentation else null,
        .terminal_action_presentation = if (memory) |info| info.terminal_action_presentation else null,
    };
    if (memory) |info| {
        if (info.committed_file_presentation) |presentation| {
            result.committed_file_presentation = dupeCommittedFilePresentation(
                alloc,
                presentation,
            ) catch |err| blk: {
                debug_trace.logf(
                    "session",
                    "committed file resume presentation unavailable call_id={s} err={s}",
                    .{ tool_call_id_src, @errorName(err) },
                );
                break :blk null;
            };
        }
    }
    return result;
}

pub fn buildNormalChatExecutionMemory(
    alloc: Allocator,
    messages: []const types.ChatMessage,
) !types.ExecutionMemory {
    return buildNormalExecutionMemory(ChatMessageAdapter, alloc, messages);
}

pub fn buildNormalMessageExecutionMemory(
    alloc: Allocator,
    messages: []const message.Message,
) !types.ExecutionMemory {
    return buildNormalExecutionMemory(MessageAdapter, alloc, messages);
}

pub fn dupeCompletedPersistedToolCalls(
    alloc: Allocator,
    calls: []const ToolCall,
    results: []const types.PersistedToolResult,
) ![]ToolCall {
    if (calls.len == 0 or results.len == 0) return &.{};

    var copy: std.ArrayList(ToolCall) = .empty;
    errdefer {
        for (copy.items) |call| types.freeToolCall(alloc, call);
        copy.deinit(alloc);
    }
    for (calls) |call| {
        const completed = blk: {
            const durable_id = try durableIdentifier(alloc, call.id);
            defer alloc.free(durable_id);
            break :blk hasPersistedResultForCall(results, durable_id);
        };
        if (!completed) continue;

        const duplicated = try dupePersistedToolCall(alloc, call);
        copy.append(alloc, duplicated) catch |err| {
            types.freeToolCall(alloc, duplicated);
            return err;
        };
    }
    return copy.toOwnedSlice(alloc);
}

/// Display-only projection: masks secret-shaped spans and returns an owned
/// copy. Persisted history must use verbatim copies instead.
pub fn maskTextForDisplay(alloc: Allocator, text: []const u8) ![]u8 {
    const masked = text_utils.maskSecrets(alloc, text) catch
        return error.OutOfMemory;
    if (masked.ptr == text.ptr) return alloc.dupe(u8, text);
    return @constCast(masked);
}

fn dupeCommittedFilePresentation(
    alloc: Allocator,
    presentation: types.CommittedFilePresentation,
) !types.CommittedFilePresentation {
    const path = try alloc.dupe(u8, presentation.path);
    errdefer alloc.free(path);
    const lines = try alloc.alloc(types.CommittedFilePresentationLine, presentation.lines.len);
    errdefer alloc.free(lines);
    var copied_lines: usize = 0;
    errdefer {
        for (lines[0..copied_lines]) |line| alloc.free(@constCast(line.text));
    }
    for (presentation.lines, 0..) |line, index| {
        lines[index] = .{
            .kind = line.kind,
            .old_line = line.old_line,
            .new_line = line.new_line,
            .text = try alloc.dupe(u8, line.text),
        };
        copied_lines += 1;
    }
    const previous_content = if (presentation.previous_content) |content|
        try alloc.dupe(u8, content)
    else
        null;
    errdefer if (previous_content) |content| alloc.free(content);
    const after_content = if (presentation.after_content) |content|
        try alloc.dupe(u8, content)
    else
        null;
    errdefer if (after_content) |content| alloc.free(content);
    const lifecycle_id: ?types.ToolLifecycleId = if (presentation.lifecycle_id) |id| .{
        .turn_id = id.turn_id,
        .call_id = try durableIdentifier(alloc, id.call_id),
    } else null;
    errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    const content_handle = if (presentation.content_handle) |handle|
        try alloc.dupe(u8, handle)
    else
        null;
    errdefer if (content_handle) |handle| alloc.free(handle);
    return .{
        .path = path,
        .kind = presentation.kind,
        .lines = lines,
        .additions = presentation.additions,
        .deletions = presentation.deletions,
        .truncated = presentation.truncated,
        .previous_content = previous_content,
        .after_content = after_content,
        .lifecycle_id = lifecycle_id,
        .content_handle = content_handle,
    };
}

pub fn appendFileEvidenceForTool(
    alloc: Allocator,
    files: *std.ArrayList(types.FileEvidence),
    call: ToolCall,
    status: types.PersistedToolStatus,
    memory: ?types.ToolResultMemory,
) !void {
    const action = fileEvidenceActionForTool(call.name);
    if (action == .unknown) return;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const object = parsed.value.object;

    const path = switch (action) {
        .search => non_empty_string_field(object, "path") orelse
            non_empty_string_field(object, "directory") orelse
            non_empty_string_field(object, "query") orelse
            ".",
        else => non_empty_string_field(object, "path") orelse return,
    };

    const evidence = try makeFileEvidence(
        alloc,
        call,
        path,
        action,
        status,
        memory,
    );
    var owns_evidence = true;
    errdefer if (owns_evidence) freeTransientFileEvidence(alloc, evidence);
    try files.append(alloc, evidence);
    owns_evidence = false;
}

pub fn markStaleFileEvidence(files: []types.FileEvidence) void {
    for (files, 0..) |file, i| {
        if (file.status != .success or !isMutationFileAction(file.action)) continue;
        var prior_index: usize = 0;
        while (prior_index < i) : (prior_index += 1) {
            if (files[prior_index].action != .read) continue;
            if (std.mem.eql(u8, files[prior_index].path, file.path)) {
                files[prior_index].stale = true;
            }
        }
    }
}

pub fn findToolCallById(calls: []const ToolCall, id: []const u8) ?ToolCall {
    for (calls) |call| {
        if (std.mem.eql(u8, call.id, id)) return call;
    }
    return null;
}

const ChatMessageAdapter = struct {
    fn standalone(value: Message) bool {
        return value.standalone_response or value.provider_replay != null;
    }
    pub const Message = types.ChatMessage;

    fn providerReplay(value: Message) ?types.ProviderReplay {
        return value.provider_replay;
    }

    fn isAssistant(value: Message) bool {
        return value.role == .assistant;
    }

    fn isTool(value: Message) bool {
        return value.role == .tool;
    }

    fn isUser(value: Message) bool {
        return value.role == .user;
    }

    fn isPermissionFeedback(value: Message) bool {
        return value.role == .user and value.permission_feedback;
    }

    fn toolCalls(value: Message) []const ToolCall {
        return value.tool_calls;
    }

    fn toolCallId(value: Message) ?[]const u8 {
        return value.tool_call_id;
    }

    fn toolName(value: Message) ?[]const u8 {
        return value.tool_name;
    }

    fn toolResultStatus(value: Message) ?types.PersistedToolStatus {
        return value.tool_result_status;
    }

    fn toolResultMemory(value: Message) ?types.ToolResultMemory {
        return value.tool_result_memory;
    }

    fn content(value: Message) ?[]const u8 {
        return value.content;
    }
};

const MessageAdapter = struct {
    fn standalone(_: Message) bool {
        return false;
    }
    pub const Message = message.Message;

    fn providerReplay(_: Message) ?types.ProviderReplay {
        return null;
    }

    fn isAssistant(value: Message) bool {
        return value.role == .assistant;
    }

    fn isTool(value: Message) bool {
        return value.role == .tool;
    }

    fn isUser(value: Message) bool {
        return value.role == .user;
    }

    fn isPermissionFeedback(value: Message) bool {
        return value.role == .user and value.permission_feedback;
    }

    fn toolCalls(value: Message) []const ToolCall {
        return value.tool_calls;
    }

    fn toolCallId(value: Message) ?[]const u8 {
        return value.tool_call_id;
    }

    fn toolName(value: Message) ?[]const u8 {
        return value.tool_name;
    }

    fn toolResultStatus(value: Message) ?types.PersistedToolStatus {
        return value.tool_result_status;
    }

    fn toolResultMemory(value: Message) ?types.ToolResultMemory {
        return value.tool_result_memory;
    }

    fn content(value: Message) ?[]const u8 {
        return if (value.content) |content_value| content_value.asText() else null;
    }
};

fn buildNormalExecutionMemory(
    comptime Adapter: type,
    alloc: Allocator,
    messages: []const Adapter.Message,
) !types.ExecutionMemory {
    var tool_steps: std.ArrayList(types.ToolExecutionStep) = .empty;
    errdefer {
        for (tool_steps.items) |step| {
            freeTransientToolExecutionStep(alloc, step);
        }
        tool_steps.deinit(alloc);
    }
    var files: std.ArrayList(types.FileEvidence) = .empty;
    errdefer {
        for (files.items) |file| {
            freeTransientFileEvidence(alloc, file);
        }
        files.deinit(alloc);
    }

    var i: usize = 0;
    while (i < messages.len) {
        const msg = messages[i];
        const tool_calls = Adapter.toolCalls(msg);
        if (!Adapter.isAssistant(msg)) {
            i += 1;
            continue;
        }
        if (tool_calls.len == 0) {
            if (Adapter.standalone(msg)) {
                const assistant = if (Adapter.content(msg)) |content| try alloc.dupe(u8, content) else null;
                errdefer if (assistant) |text| alloc.free(text);
                const replay = try dupeUnchangedProviderReplay(alloc, Adapter.providerReplay(msg), Adapter.content(msg), assistant, &.{}, &.{});
                errdefer if (replay) |value| types.freeProviderReplay(alloc, value);
                try tool_steps.append(alloc, .{ .assistant = assistant, .provider_replay = replay });
            }
            i += 1;
            continue;
        }

        var results: std.ArrayList(types.PersistedToolResult) = .empty;
        errdefer {
            for (results.items) |result| {
                freeTransientPersistedToolResult(alloc, result);
            }
            results.deinit(alloc);
        }
        var result_source_call_ids: std.ArrayList([]const u8) = .empty;
        defer result_source_call_ids.deinit(alloc);

        var j = i + 1;
        var last_result_index: ?usize = null;
        while (j < messages.len and Adapter.isTool(messages[j])) : (j += 1) {
            const result_msg = messages[j];
            const tool_call_id = Adapter.toolCallId(result_msg) orelse continue;
            const call = findToolCallById(tool_calls, tool_call_id) orelse continue;
            const output = Adapter.content(result_msg) orelse "";
            const status = Adapter.toolResultStatus(result_msg) orelse
                return error.MissingToolResultStatus;
            const result_memory = Adapter.toolResultMemory(result_msg);
            const record = try makePersistedToolResult(
                alloc,
                tool_call_id,
                Adapter.toolName(result_msg) orelse call.name,
                status,
                output,
                result_memory,
            );
            var owns_record = true;
            errdefer if (owns_record) {
                freeTransientPersistedToolResult(alloc, record);
            };
            try results.append(alloc, record);
            owns_record = false;
            try result_source_call_ids.append(alloc, tool_call_id);
            last_result_index = results.items.len - 1;
            try appendFileEvidenceForTool(
                alloc,
                &files,
                call,
                status,
                result_memory,
            );
        }

        while (j < messages.len and Adapter.isUser(messages[j])) : (j += 1) {
            const feedback_msg = messages[j];
            if (!Adapter.isPermissionFeedback(feedback_msg)) continue;
            const text = Adapter.content(feedback_msg) orelse
                return error.MissingPermissionFeedbackContent;
            const index = if (Adapter.toolCallId(feedback_msg)) |tool_call_id|
                findResultIndexBySourceCallId(result_source_call_ids.items, tool_call_id) orelse continue
            else
                last_result_index orelse return error.PermissionFeedbackWithoutResult;
            try appendPersistedPermissionFeedback(alloc, &results.items[index], text);
        }

        if (results.items.len == 0) {
            results.deinit(alloc);
            i = j;
            continue;
        }

        const assistant = if (Adapter.content(msg)) |content|
            try alloc.dupe(u8, content)
        else
            null;
        errdefer if (assistant) |text| alloc.free(text);
        const persisted_calls = try dupeCompletedPersistedToolCalls(
            alloc,
            tool_calls,
            results.items,
        );
        errdefer types.freeToolCallSlice(alloc, persisted_calls);
        const replay = try dupeUnchangedProviderReplay(alloc, Adapter.providerReplay(msg), Adapter.content(msg), assistant, tool_calls, persisted_calls);
        errdefer if (replay) |value| types.freeProviderReplay(alloc, value);
        const owned_results = try results.toOwnedSlice(alloc);
        errdefer types.freePersistedToolResults(alloc, owned_results);
        const step = types.ToolExecutionStep{
            .assistant = assistant,
            .provider_replay = replay,
            .tool_calls = persisted_calls,
            .tool_results = owned_results,
        };
        try tool_steps.append(alloc, step);
        i = j;
    }

    const owned_files = try files.toOwnedSlice(alloc);
    errdefer types.freeFileEvidenceSlice(alloc, owned_files);
    markStaleFileEvidence(owned_files);
    return .{
        .tool_steps = try tool_steps.toOwnedSlice(alloc),
        .files = owned_files,
    };
}

fn hasPersistedResultForCall(
    results: []const types.PersistedToolResult,
    call_id: []const u8,
) bool {
    for (results) |result| {
        if (std.mem.eql(u8, result.tool_call_id, call_id)) return true;
    }
    return false;
}

fn findResultIndexBySourceCallId(
    source_call_ids: []const []const u8,
    call_id: []const u8,
) ?usize {
    for (source_call_ids, 0..) |source_call_id, index| {
        if (std.mem.eql(u8, source_call_id, call_id)) return index;
    }
    return null;
}

pub fn freeTransientToolExecutionStep(
    alloc: Allocator,
    step: types.ToolExecutionStep,
) void {
    if (step.assistant) |assistant| alloc.free(assistant);
    if (step.provider_replay) |replay| types.freeProviderReplay(alloc, replay);
    types.freeToolCallSlice(alloc, step.tool_calls);
    types.freePersistedToolResults(alloc, step.tool_results);
}

/// Caller owns the copy. Never bind signed metadata to incomplete history.
pub fn dupeUnchangedProviderReplay(
    alloc: Allocator,
    replay: ?types.ProviderReplay,
    source_text: ?[]const u8,
    stored_text: ?[]const u8,
    source_calls: []const ToolCall,
    stored_calls: []const ToolCall,
) !?types.ProviderReplay {
    const value = replay orelse return null;
    var unchanged = std.mem.eql(u8, source_text orelse "", stored_text orelse "") and source_calls.len == stored_calls.len;
    if (unchanged) for (source_calls, stored_calls) |source, stored| {
        if (!std.mem.eql(u8, source.id, stored.id) or !std.mem.eql(u8, source.name, stored.name) or
            !try @import("../shared/json_comparison.zig").serializedEqual(alloc, source.arguments_json, stored.arguments_json))
        {
            unchanged = false;
            break;
        }
    };
    if (!unchanged) {
        debug_trace.logf("session", "provider replay omitted reason=incomplete_association", .{});
        return null;
    }
    return try types.dupeProviderReplay(alloc, value);
}

pub fn freeTransientPersistedToolResult(
    alloc: Allocator,
    result: types.PersistedToolResult,
) void {
    alloc.free(result.tool_call_id);
    alloc.free(result.tool_name);
    alloc.free(result.output);
    types.freeToolImages(alloc, result.tool_images);
    if (result.tool_image_handle) |handle| alloc.free(handle);
    if (result.output_handle) |handle| alloc.free(handle);
    if (result.preview) |preview| alloc.free(preview);
    types.freePermissionFeedback(alloc, result.permission_feedback);
    if (result.committed_file_presentation) |presentation| {
        types.freeCommittedFilePresentation(alloc, presentation);
    }
    if (result.command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    }
}

fn appendPersistedPermissionFeedback(
    alloc: Allocator,
    result: *types.PersistedToolResult,
    text: []const u8,
) !void {
    const owned = try alloc.dupe(u8, text);
    errdefer alloc.free(owned);

    const prior = result.permission_feedback;
    const appended = try alloc.alloc([]u8, prior.len + 1);
    errdefer alloc.free(appended);
    @memcpy(appended[0..prior.len], prior);
    appended[prior.len] = owned;
    if (prior.len > 0) alloc.free(prior);
    result.permission_feedback = appended;
}

pub fn freeTransientFileEvidence(
    alloc: Allocator,
    file: types.FileEvidence,
) void {
    alloc.free(file.path);
    if (file.new_path) |new_path| alloc.free(new_path);
    alloc.free(file.tool_call_id);
    alloc.free(file.tool_name);
}

pub fn dupePersistedToolCall(alloc: Allocator, call: ToolCall) !ToolCall {
    const id = try durableIdentifier(alloc, call.id);
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, call.name);
    errdefer alloc.free(name);
    const arguments_json = try alloc.dupe(u8, call.arguments_json);
    errdefer alloc.free(arguments_json);
    const provisional_id = if (call.provisional_id) |value| try durableIdentifier(alloc, value) else null;
    errdefer if (provisional_id) |value| alloc.free(value);
    const provider_result = if (call.provider_result) |result| try alloc.dupe(u8, result) else null;
    errdefer if (provider_result) |result| alloc.free(result);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
        .provisional_id = provisional_id,
        .provider_result = provider_result,
        .final_identity = call.final_identity,
        .provenance = call.provenance,
    };
}

fn makeFileEvidence(
    alloc: Allocator,
    call: ToolCall,
    path_src: []const u8,
    action: types.FileEvidenceAction,
    status: types.PersistedToolStatus,
    memory: ?types.ToolResultMemory,
) !types.FileEvidence {
    const path = try alloc.dupe(u8, path_src);
    errdefer alloc.free(path);
    const tool_call_id = try durableIdentifier(alloc, call.id);
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, call.name);
    errdefer alloc.free(tool_name);
    const model_view_covers_full_file = if (memory) |info|
        (info.model_view_covers_full_file orelse false) and
            !info.truncated
    else
        false;
    return .{
        .path = path,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .action = action,
        .status = status,
        .model_view_covers_full_file = status == .success and
            action == .read and
            model_view_covers_full_file,
        .stale = false,
    };
}

fn fileEvidenceActionForTool(tool_name: []const u8) types.FileEvidenceAction {
    if (std.mem.eql(u8, tool_name, "read_file")) return .read;
    if (std.mem.eql(u8, tool_name, "write_file")) return .write;
    if (std.mem.eql(u8, tool_name, "edit_file")) return .edit;
    if (std.mem.eql(u8, tool_name, "grep_files")) return .search;
    if (std.mem.eql(u8, tool_name, "glob_files")) return .search;
    return .unknown;
}

fn non_empty_string_field(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn isMutationFileAction(action: types.FileEvidenceAction) bool {
    return switch (action) {
        .write, .edit => true,
        else => false,
    };
}

fn durableIdentifier(alloc: Allocator, value: []const u8) ![]u8 {
    const masked = text_utils.maskSecrets(alloc, value) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    if (masked.ptr == value.ptr) return alloc.dupe(u8, value);
    defer alloc.free(@constCast(masked));

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..12].*, .lower);
    return alloc.print("redacted-{s}", .{&hex});
}

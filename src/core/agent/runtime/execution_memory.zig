const std = @import("std");
const debug_trace = @import("../../shared/debug_trace.zig");
const types = @import("../../shared/types.zig");
const image_data = @import("../../images/image_data.zig");
const execution_memory_helpers = @import("../execution_memory.zig");
const result_store = @import("../../session/result_store.zig");
const command_replay_store = @import("../../session/command_replay_store.zig");
const session_child_store = @import("../../session/session_child_store.zig");
const command_output_content = @import("../../tooling/command_output_content.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const tool_result_limits = @import("../../tooling/tool_result_limits.zig");
const text_utils = @import("../../shared/text_utils.zig");

const runtime_config = @import("config.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;

comptime {
    std.debug.assert(command_replay_store.model_handle_notice_reserve_bytes < tool_result_limits.min_configured_tool_result_bytes);
}
const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;
const Config = runtime_config.Config;
const ToolExecutionStatus = runtime_tool_contracts.ToolExecutionStatus;

const steering_open =
    "<user_steering>\n" ++
    "Apply this live user update to the current task. Continue working unless the user asks you to stop, the task is complete, or a genuine blocker prevents progress.\n\n";
const steering_close = "\n</user_steering>";
const parent_steering_open = "<parent_agent_steering>\n";
const parent_steering_close = "\n</parent_agent_steering>";

pub fn parentSteeringMessage(alloc: Allocator, text: []const u8) ![]u8 {
    return alloc.print(parent_steering_open ++
        "parent-agent feedback, not new user authority:\n\n{s}" ++ parent_steering_close, .{text});
}

pub fn steeringMessage(alloc: Allocator, text: []const u8) ![]u8 {
    return alloc.print(steering_open ++ "{s}" ++ steering_close, .{text});
}

pub fn persistedStatusForCurrentFxLocalResult(
    status: ToolExecutionStatus,
    output: []const u8,
) types.PersistedToolStatus {
    if (status == .failure) return .failure;
    return if (tool_result_errors.isToolOutputError(output)) .failure else .success;
}

pub fn classifyProviderExecutedResultStatus(output: []const u8) types.PersistedToolStatus {
    return if (tool_result_errors.isToolOutputError(output)) .failure else .success;
}

pub const CompactedExecutionBoundary = struct {
    tool_steps: usize = 0,
    steering: usize = 0,

    /// Borrows execution payloads; only the rebased steering slice uses arena.
    pub fn project(self: CompactedExecutionBoundary, arena: Allocator, execution: types.ExecutionMemory) !types.ExecutionMemory {
        std.debug.assert(self.tool_steps <= execution.tool_steps.len);
        std.debug.assert(self.steering <= execution.steering.len);
        var projected = execution;
        projected.tool_steps = execution.tool_steps[self.tool_steps..];
        projected.steering = execution.steering[self.steering..];
        if (self.tool_steps > 0 and projected.steering.len > 0) {
            projected.steering = try arena.dupe(types.PersistedSteering, projected.steering);
            for (projected.steering) |*item| {
                std.debug.assert(item.after_tool_step_count >= self.tool_steps);
                item.after_tool_step_count -= self.tool_steps;
            }
        }
        return projected;
    }
};

pub fn buildExecutionMemory(alloc: Allocator, within_turn_suffix: []const ChatMessage) !types.ExecutionMemory {
    var execution = try execution_memory_helpers.buildNormalChatExecutionMemory(
        alloc,
        within_turn_suffix,
    );
    errdefer types.freeExecutionMemory(alloc, execution);

    var steering: std.ArrayList(types.PersistedSteering) = .empty;
    errdefer {
        for (steering.items) |item| {
            alloc.free(item.text);
            if (item.assistant_prefix) |prefix| alloc.free(prefix);
        }
        steering.deinit(alloc);
    }
    var tool_step_count: usize = 0;
    var assistant_prefix: ?[]const u8 = null;
    for (within_turn_suffix, 0..) |message, index| {
        if (startsPersistedToolStep(within_turn_suffix, index)) {
            tool_step_count += 1;
            assistant_prefix = null;
        } else if (message.role == .assistant) {
            assistant_prefix = message.content;
        }
        if (message.role != .user) continue;
        const content = message.content orelse continue;
        const text = if (message.restored_steering)
            content
        else
            steeringText(content) orelse {
                assistant_prefix = null;
                continue;
            };
        const copy = try alloc.dupe(u8, text);
        const prefix_copy = if (assistant_prefix) |prefix|
            alloc.dupe(u8, prefix) catch |err| {
                alloc.free(copy);
                return err;
            }
        else
            null;
        steering.append(alloc, .{
            .text = copy,
            .assistant_prefix = prefix_copy,
            .after_tool_step_count = tool_step_count,
        }) catch |err| {
            alloc.free(copy);
            if (prefix_copy) |prefix| alloc.free(prefix);
            return err;
        };
        assistant_prefix = null;
    }
    std.debug.assert(tool_step_count == execution.tool_steps.len);
    execution.steering = try steering.toOwnedSlice(alloc);
    return execution;
}

fn startsPersistedToolStep(messages: []const ChatMessage, assistant_index: usize) bool {
    const assistant = messages[assistant_index];
    if (assistant.role != .assistant) return false;
    if (assistant.tool_calls.len == 0) return assistant.provider_replay != null or assistant.standalone_response;
    var result_index = assistant_index + 1;
    while (result_index < messages.len and messages[result_index].role == .tool) : (result_index += 1) {
        const result_call_id = messages[result_index].tool_call_id orelse continue;
        for (assistant.tool_calls) |call| {
            if (std.mem.eql(u8, call.id, result_call_id)) return true;
        }
    }
    return false;
}

/// Locate the same complete-exchange cut in the original wire messages. Do not
/// rebuild retained tool results: their content and metadata remain untouched.
pub fn retainedMessageOffset(messages: []const ChatMessage, cut: CompactedExecutionBoundary) !usize {
    if (cut.tool_steps == 0 and cut.steering == 0) return 0;
    var steps: usize = 0;
    var steering: usize = 0;
    var prefix_start: usize = 0;
    for (messages, 0..) |message, index| {
        if (startsPersistedToolStep(messages, index)) {
            if (steps == cut.tool_steps and steering == cut.steering) return prefix_start;
            steps += 1;
            // Keep following continuation prompts, but not the completed reply.
            if (message.tool_calls.len == 0) prefix_start = index + 1;
        } else if (message.role == .user and message.content != null and
            (message.restored_steering or steeringText(message.content.?) != null))
        {
            if (steps == cut.tool_steps and steering == cut.steering) return prefix_start;
            steering += 1;
            prefix_start = index + 1;
        }
        if (message.role == .tool) prefix_start = index + 1;
    }
    if (steps != cut.tool_steps or steering != cut.steering) return error.InvalidContextHistoryStart;
    return messages.len;
}

/// Steering the user typed during the turn, which a cancelled turn keeps.
fn isSteering(message: ChatMessage) bool {
    if (message.restored_steering) return true;
    const content = message.content orelse return false;
    return steeringText(content) != null;
}

fn steeringText(content: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, content, parent_steering_open) and std.mem.endsWith(u8, content, parent_steering_close)) {
        // Keep the sender label in persisted text and ordinary history replay.
        return content[parent_steering_open.len .. content.len - parent_steering_close.len];
    }
    if (!std.mem.startsWith(u8, content, steering_open) or !std.mem.endsWith(u8, content, steering_close)) return null;
    return content[steering_open.len .. content.len - steering_close.len];
}

pub fn buildInterruptedExecutionMemory(
    alloc: Allocator,
    current_turn_messages: []const ChatMessage,
    active_tool_call: ?ToolCall,
) !types.ExecutionMemory {
    var filtered: std.ArrayList(ChatMessage) = .empty;
    defer filtered.deinit(alloc);
    try filtered.ensureTotalCapacity(alloc, current_turn_messages.len);
    var allocated_call_slices: std.ArrayList([]ToolCall) = .empty;
    defer {
        for (allocated_call_slices.items) |calls| alloc.free(calls);
        allocated_call_slices.deinit(alloc);
    }

    var active_group_index: ?usize = null;
    if (active_tool_call) |active| {
        for (current_turn_messages, 0..) |message, index| {
            for (message.tool_calls) |call| {
                if (std.mem.eql(u8, call.id, active.id)) active_group_index = index;
            }
        }
    }
    var i: usize = 0;
    while (i < current_turn_messages.len) {
        const item = current_turn_messages[i];
        if (item.role != .assistant or item.tool_calls.len == 0) {
            try filtered.append(alloc, item);
            i += 1;
            continue;
        }

        var result_end = i + 1;
        while (result_end < current_turn_messages.len and
            current_turn_messages[result_end].role == .tool) : (result_end += 1)
        {}
        const result_messages = current_turn_messages[i + 1 .. result_end];
        var user_tail_end = result_end;
        while (user_tail_end < current_turn_messages.len and
            current_turn_messages[user_tail_end].role == .user) : (user_tail_end += 1)
        {}
        const user_tail = current_turn_messages[result_end..user_tail_end];

        var completed_count: usize = 0;
        for (item.tool_calls) |call| {
            if (active_tool_call) |active| {
                if (active_group_index == i and std.mem.eql(u8, call.id, active.id)) continue;
            }
            if (hasToolResultForCall(result_messages, call.id)) {
                completed_count += 1;
            }
        }

        if (item.provider_replay != null and completed_count != item.tool_calls.len) {
            debug_trace.logf("session", "provider replay omitted reason=interrupted_incomplete_association source_calls={d} completed_calls={d}", .{ item.tool_calls.len, completed_count });
        }
        if (completed_count > 0) {
            const calls = try alloc.alloc(ToolCall, completed_count);
            errdefer alloc.free(calls);
            try allocated_call_slices.append(alloc, calls);

            var completed_index: usize = 0;
            for (item.tool_calls) |call| {
                if (active_tool_call) |active| {
                    if (active_group_index == i and std.mem.eql(u8, call.id, active.id)) continue;
                }
                if (!hasToolResultForCall(result_messages, call.id)) continue;
                calls[completed_index] = call;
                completed_index += 1;
            }

            var projected = item;
            projected.tool_calls = calls;
            if (completed_count != item.tool_calls.len) projected.provider_replay = null;
            filtered.appendAssumeCapacity(projected);
            for (result_messages) |result| {
                const result_call_id = result.tool_call_id orelse continue;
                if (execution_memory_helpers.findToolCallById(
                    calls,
                    result_call_id,
                ) != null) {
                    filtered.appendAssumeCapacity(result);
                }
            }
            for (user_tail) |entry| {
                if (!entry.permission_feedback and !isSteering(entry)) continue;
                if (entry.tool_call_id) |source_tool_call_id| {
                    if (execution_memory_helpers.findToolCallById(calls, source_tool_call_id) == null) {
                        continue;
                    }
                }
                filtered.appendAssumeCapacity(entry);
            }
        }
        i = user_tail_end;
    }

    return buildExecutionMemory(alloc, filtered.items);
}

pub fn retainCancelledCommandReplay(
    arena: Allocator,
    result_memory: ?types.ToolResultMemory,
    capture: ?*command_replay_store.Capture,
) ?types.CancelledCommandPresentation {
    if (capture) |candidate| {
        const replay: ?types.CommandOutputReplay = switch (candidate.policy()) {
            .required => blk: {
                const descriptor = candidate.retainRequired(arena) catch |err| {
                    debug_trace.logf(
                        "session",
                        "cancelled command replay retention unavailable err={s}",
                        .{@errorName(err)},
                    );
                    break :blk .unavailable;
                } orelse break :blk null;
                break :blk .{ .available = descriptor };
            },
            .best_effort => candidate.retain(arena),
        };
        if (replay) |retained| return .{ .output_replay = retained };
    }
    const replay = if (result_memory) |memory|
        memory.command_output_replay
    else
        null;
    return if (replay) |value| .{ .output_replay = value } else null;
}

fn hasToolResultForCall(
    result_messages: []const ChatMessage,
    call_id: []const u8,
) bool {
    for (result_messages) |result| {
        if (result.tool_call_id) |result_call_id| {
            if (std.mem.eql(u8, result_call_id, call_id)) return true;
        }
    }
    return false;
}

pub fn prepareToolExecutionOutput(
    arena: Allocator,
    config: Config,
    tool_call: ToolCall,
    execution: runtime_tool_contracts.ToolExecutionResult,
    capture: ?*command_replay_store.Capture,
) !result_store.PreparedResult {
    if (execution.model_content_kind != .complete_skill or execution.status != .success) {
        return prepareCapturedToolModelOutput(arena, config, tool_call, execution.model_output, capture);
    }
    if (capture != null) return error.InvalidSkillContentResult;
    const full = try tool_result_limits.prepareSanitizedOutput(arena, execution.model_output);
    errdefer arena.free(full);
    if (full.len > config.max_tool_result_bytes) return error.SkillContentLimitExceeded;
    var prepared = try prepareCapturedToolModelOutput(arena, config, tool_call, full, null);
    arena.free(prepared.model_output);
    prepared.model_output = full;
    prepared.memory.truncated = false;
    return prepared;
}

pub fn prepareToolModelOutput(
    arena: Allocator,
    config: Config,
    tool_call: ToolCall,
    raw_output: []const u8,
) !result_store.PreparedResult {
    return prepareCapturedToolModelOutput(
        arena,
        config,
        tool_call,
        raw_output,
        null,
    );
}

pub fn prepareCapturedToolModelOutput(
    arena: Allocator,
    config: Config,
    tool_call: ToolCall,
    raw_output: []const u8,
    capture: ?*command_replay_store.Capture,
) !result_store.PreparedResult {
    if (std.mem.eql(u8, tool_call.name, "read_tool_result")) {
        const prepared = try tool_result_limits.prepareModelOutputWithTruncation(
            arena,
            tool_call.name,
            raw_output,
            config.max_tool_result_bytes,
        );
        errdefer arena.free(prepared.model_output);
        var memory: types.ToolResultMemory = .{
            .output_bytes = raw_output.len,
            .stored_output_bytes = prepared.model_output.len,
            .truncated = prepared.truncated,
        };
        if (prepared.truncated and
            (config.session_child_capability != null or config.tool_result_dir != null))
        {
            const complete_output = try text_utils.sanitizeModelText(arena, raw_output);
            defer if (complete_output.ptr != raw_output.ptr) arena.free(complete_output);
            memory.output_handle = if (config.session_child_capability) |capability|
                try result_store.storeLargeResultManaged(arena, capability, tool_call.id, tool_call.name, complete_output)
            else
                try result_store.storeLargeResult(arena, config.tool_result_dir.?, tool_call.id, tool_call.name, complete_output);
            memory.stored_output_bytes = complete_output.len;
        }
        return .{
            .model_output = prepared.model_output,
            .memory = memory,
        };
    }
    const required_command_replay = if (capture) |candidate|
        candidate.policy() == .required
    else
        false;
    if (!required_command_replay and
        (config.session_child_capability != null or config.tool_result_dir != null))
    {
        const sanitized_output = try tool_result_limits.prepareSanitizedOutput(
            arena,
            raw_output,
        );
        if (config.session_child_capability != null) {
            return result_store.prepareManaged(
                arena,
                config.session_child_capability,
                tool_call.id,
                tool_call.name,
                raw_output.len,
                sanitized_output,
                config.max_tool_result_bytes,
            );
        }
        return result_store.prepare(
            arena,
            config.tool_result_dir,
            tool_call.id,
            tool_call.name,
            raw_output.len,
            sanitized_output,
            config.max_tool_result_bytes,
        );
    }
    const model_output_budget = if (required_command_replay)
        config.max_tool_result_bytes -| command_replay_store.model_handle_notice_reserve_bytes
    else
        config.max_tool_result_bytes;
    const prepared = try tool_result_limits.prepareModelOutputWithTruncation(
        arena,
        tool_call.name,
        raw_output,
        model_output_budget,
    );
    return .{
        .model_output = prepared.model_output,
        .memory = .{
            .output_bytes = raw_output.len,
            .stored_output_bytes = prepared.model_output.len,
            .truncated = prepared.truncated,
        },
    };
}

/// Retains the original tool images so later requests can project a safe view.
pub fn retainToolImages(arena: Allocator, config: Config, call: ToolCall, prepared: *result_store.PreparedResult) !void {
    const memory = &prepared.memory;
    if (memory.tool_images.len == 0 or memory.tool_image_handle != null) return;
    const capability = config.session_child_capability orelse return;
    const handle = result_store.storeToolImages(arena, capability, call.id, call.name, memory.tool_images) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("session", "tool images remain inline because artifact storage failed call_id={s} err={s}", .{ call.id, @errorName(err) });
        return;
    };
    memory.tool_image_handle = handle;
    const notice = try arena.print("Saved images: {s}. Use read_tool_result with this handle to load them again.\n", .{handle});
    const limit = config.max_tool_result_bytes -| notice.len;
    const keep = @import("../../config/context_limits.zig").utf8PrefixLength(prepared.model_output, limit);
    if (keep < prepared.model_output.len) memory.truncated = true;
    prepared.model_output = try std.mem.concat(arena, u8, &.{ notice, prepared.model_output[0..keep] });
}

fn needsImageMaterialization(messages: []const ChatMessage) bool {
    for (messages) |message| {
        const memory = message.tool_result_memory orelse continue;
        if (memory.tool_images.len == 0 and memory.tool_image_handle != null) return true;
    }
    return false;
}

/// Loads stored tool images for a request without changing session history.
pub fn materializeToolImages(arena: Allocator, config: Config, messages: []const ChatMessage) ![]const ChatMessage {
    if (!needsImageMaterialization(messages)) return messages;
    const materialized = try arena.dupe(ChatMessage, messages);
    for (materialized) |*message| {
        if (message.tool_result_memory) |*memory| {
            if (memory.tool_images.len == 0) {
                const handle = memory.tool_image_handle orelse continue;
                const capability = config.session_child_capability orelse {
                    message.content = try prependImageNotice(arena, "[Stored tool image is unavailable in this session.]\n", message.content orelse "", config.max_tool_result_bytes);
                    continue;
                };
                memory.tool_images = result_store.loadToolImages(arena, capability, handle) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    const notice = try arena.print("[Stored tool image unavailable: {s}]\n", .{@errorName(err)});
                    message.content = try prependImageNotice(arena, notice, message.content orelse "", config.max_tool_result_bytes);
                    continue;
                };
            }
        }
    }
    return materialized;
}

fn requestToolImageFits(image: types.ToolImage, max_dimension: u32) bool {
    const dimensions = image_data.encodedImageDimensions(image.data) orelse return false;
    return !dimensions.exceeds(max_dimension) and
        image.data.len <= image_data.max_encoded_image_bytes and
        image_data.supportedMediaType(image.mime_type);
}

/// Builds a safe request view without changing the tool images saved in history.
pub fn withholdRequestToolImages(arena: Allocator, messages: []const ChatMessage, max_dimension: u32, text_limit: usize) ![]const ChatMessage {
    var projected: ?[]ChatMessage = null;
    for (messages, 0..) |message, index| {
        const memory = message.tool_result_memory orelse continue;
        const has_unsafe = for (memory.tool_images) |image| {
            if (!requestToolImageFits(image, max_dimension)) break true;
        } else false;
        if (!has_unsafe) continue;
        var kept: std.ArrayList(types.ToolImage) = try .initCapacity(arena, memory.tool_images.len);
        var notice: std.Io.Writer.Allocating = .init(arena);
        for (memory.tool_images) |image| {
            if (requestToolImageFits(image, max_dimension)) {
                kept.appendAssumeCapacity(image);
                continue;
            }
            const dimensions = image_data.encodedImageDimensions(image.data);
            if (dimensions) |size| {
                try notice.writer.print("[Image not sent: {s} is {d}x{d} pixels; this request permits at most {d} per side and 5 MiB encoded per image. ", .{ image.mime_type, size.width, size.height, max_dimension });
            } else {
                try notice.writer.writeAll("[Image not sent: its dimensions could not be verified. ");
            }
            try notice.writer.writeAll("If this tool result names a local file, use an available image tool to save a smaller copy, then read_file the copy. If no tool or path is available, ask the user; ask before installing software.]\n");
        }
        if (kept.items.len == memory.tool_images.len) continue;
        const output = projected orelse try arena.dupe(ChatMessage, messages);
        projected = output;
        output[index].tool_result_memory.?.tool_images = kept.items;
        output[index].content = try prependImageNotice(arena, notice.written(), message.content orelse "", text_limit);
    }
    return projected orelse messages;
}

fn prependImageNotice(alloc: Allocator, notice: []const u8, content: []const u8, limit: usize) Allocator.Error![]u8 {
    const utf8_prefix_length = @import("../../config/context_limits.zig").utf8PrefixLength;
    const notice_keep = utf8_prefix_length(notice, limit);
    const keep = utf8_prefix_length(content, limit -| notice.len);
    return std.mem.concat(alloc, u8, &.{ notice[0..notice_keep], content[0..keep] });
}

pub fn applyToolResultMemory(
    prepared: *types.ToolResultMemory,
    source: ?types.ToolResultMemory,
) void {
    const source_memory = source orelse return;
    prepared.review_feedback = source_memory.review_feedback;
    prepared.tool_images = source_memory.tool_images;
    prepared.tool_image_handle = source_memory.tool_image_handle;
    prepared.command_output_replay = source_memory.command_output_replay;
    prepared.command_process_presentation = source_memory.command_process_presentation;
    prepared.terminal_action_presentation = source_memory.terminal_action_presentation;
    const source_covers_full_file =
        source_memory.model_view_covers_full_file orelse return;
    prepared.model_view_covers_full_file =
        source_covers_full_file and
        !source_memory.truncated and
        source_memory.output_handle == null and
        !prepared.truncated;
}

/// Finalizes tentative command capture after bounded model output is prepared.
/// Required native exec always retains one authoritative replay and publishes
/// its handle; legacy exact round trips keep the existing discard optimization.
pub fn finalizeCommandReplay(
    arena: Allocator,
    tool_call: ToolCall,
    prepared: *result_store.PreparedResult,
    session_child_capability: ?*session_child_store.SessionChildCapability,
    capture: ?*command_replay_store.Capture,
) !void {
    const candidate = capture orelse return;
    if (!candidate.hasOutput()) {
        candidate.discard(arena);
        return;
    }
    if (candidate.policy() == .required) {
        const descriptor = (try candidate.retainRequired(arena)) orelse return;
        prepared.memory.command_output_replay = .{ .available = descriptor };
        prepared.model_output = try command_replay_store.appendModelHandleNotice(
            arena,
            prepared.model_output,
            descriptor.handle,
        );
        prepared.memory.stored_output_bytes = prepared.model_output.len;
        return;
    }
    var captured = candidate.canonicalizeForComparison(arena) catch |err| {
        debug_trace.logf(
            "session",
            "command replay comparison unavailable call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    } orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer captured.deinit(arena);

    const source = selectedCommandSource(
        arena,
        prepared.*,
        session_child_capability,
        candidate.comparisonLimit(),
    ) catch |err| {
        debug_trace.logf(
            "session",
            "command replay source comparison failed call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    } orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer arena.free(source);
    var ordinary = (command_output_content.canonicalizeForegroundResult(
        arena,
        source,
    ) catch |err| {
        debug_trace.logf(
            "session",
            "command replay envelope comparison failed call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    }) orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer ordinary.deinit(arena);

    if (command_output_content.eql(captured, ordinary)) {
        candidate.discard(arena);
        return;
    }
    retainCommandReplay(arena, candidate, &prepared.memory);
}

fn selectedCommandSource(
    arena: Allocator,
    prepared: result_store.PreparedResult,
    session_child_capability: ?*session_child_store.SessionChildCapability,
    comparison_limit: usize,
) !?[]u8 {
    const source_limit = std.math.add(
        usize,
        comparison_limit,
        command_output_content.max_foreground_result_envelope_bytes,
    ) catch return null;
    if (prepared.memory.output_handle) |handle| {
        const capability = session_child_capability orelse return null;
        var reader = try result_store.openReaderManaged(arena, capability, handle);
        defer reader.deinit();
        if (reader.size != prepared.memory.stored_output_bytes or
            reader.size > source_limit) return null;

        const source = try arena.alloc(u8, reader.size);
        errdefer arena.free(source);
        var offset: usize = 0;
        while (offset < source.len) {
            const page_len = @min(source.len - offset, 4 * 1024);
            const page = try reader.readPage(arena, offset, page_len);
            defer arena.free(page);
            if (page.len != page_len) return error.UnexpectedEndOfResult;
            @memcpy(source[offset..][0..page.len], page);
            offset += page.len;
        }
        return source;
    }
    if (prepared.model_output.len > source_limit) return null;
    const source = try arena.dupe(u8, prepared.model_output);
    if (source.len > source_limit) {
        arena.free(source);
        return null;
    }
    return source;
}

fn retainCommandReplay(
    arena: Allocator,
    candidate: *command_replay_store.Capture,
    memory: *types.ToolResultMemory,
) void {
    memory.command_output_replay = candidate.retain(arena);
}

pub fn captureCommittedFilePresentation(
    alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) !types.CommittedFilePresentation {
    const path = try alloc.dupe(u8, handoff.preview.path);
    errdefer alloc.free(path);
    const lines = try alloc.alloc(types.CommittedFilePresentationLine, handoff.preview.lines.len);
    errdefer alloc.free(lines);
    var copied_lines: usize = 0;
    errdefer {
        for (lines[0..copied_lines]) |line| alloc.free(@constCast(line.text));
    }
    for (handoff.preview.lines, 0..) |line, index| {
        lines[index] = .{
            .kind = switch (line.op) {
                .context => .context,
                .addition => .addition,
                .deletion => .deletion,
                .elision => .elision,
                .notice => .notice,
            },
            .old_line = line.old_line,
            .new_line = line.new_line,
            .text = try alloc.dupe(u8, line.text),
        };
        copied_lines += 1;
    }
    const full_view = handoff.full_view;
    const previous_content = if (full_view != null) if (handoff.tracker.previous_content) |content|
        try alloc.dupe(u8, content)
    else
        null else null;
    errdefer if (previous_content) |content| alloc.free(content);
    const after_content = if (full_view) |full|
        try alloc.dupe(u8, full.after_content)
    else
        null;
    errdefer if (after_content) |content| alloc.free(content);
    const lifecycle_id: ?types.ToolLifecycleId = if (full_view) |full| .{
        .turn_id = full.lifecycle_id.turn_id,
        .call_id = try alloc.dupe(u8, full.lifecycle_id.call_id),
    } else null;
    errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    return .{
        .path = path,
        .kind = switch (handoff.tracker.kind) {
            .write => .added,
            .edit => .edited,
        },
        .lines = lines,
        .additions = handoff.preview.additions,
        .deletions = handoff.preview.deletions,
        .truncated = handoff.preview.truncated,
        .previous_content = previous_content,
        .after_content = after_content,
        .lifecycle_id = lifecycle_id,
    };
}

const std = @import("std");
const result_store = @import("../../core/session/result_store.zig");
const command_replay_store = @import("../../core/session/command_replay_store.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const compactor = @import("../../core/compactor/compactor.zig");

const Allocator = std.mem.Allocator;

const HandleNormalization = struct {
    trimmed: []const u8,
    suffix: []const u8,
};

pub const Input = struct {
    handle: []u8,
    selector: union(enum) {
        range: struct {
            start_byte: usize = 1,
            byte_count: usize = result_store.read_default_bytes,
        },
        query: []u8,
        /// Searches every turn, tool call and earlier compaction saved by
        /// context compaction.
        search: [][]u8,
    } = .{ .range = .{} },

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.handle);
        switch (self.selector) {
            .range => {},
            .query => |query| alloc.free(query),
            .search => |phrases| {
                for (phrases) |phrase| alloc.free(phrase);
                alloc.free(phrases);
            },
        }
        self.* = .{ .handle = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result arguments must be an object") };
    }
    const args = if (parsed.value.object.get("request")) |request| blk: {
        if (request != .object) {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"request\" must be an object") };
        }
        break :blk request.object;
    } else parsed.value.object;
    if (args.get("search")) |value| return decodeSearch(ctx.allocator, value);
    const handle_value = args.get("handle") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result requires string field \"handle\"") };
    };
    if (handle_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"handle\" must be a string") };
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .handle = try ctx.allocator.dupe(u8, handle_value.string) };
    errdefer input.deinit(ctx.allocator);

    if (args.get("start_byte")) |value| {
        const start_byte = parsePositiveInteger(value) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"start_byte\" must be a positive integer") };
        };
        input.selector.range.start_byte = @intCast(start_byte);
    }
    if (args.get("byte_count")) |value| {
        const byte_count = parsePositiveInteger(value) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"byte_count\" must be a positive integer") };
        };
        input.selector.range.byte_count = @intCast(@min(byte_count, result_store.read_max_bytes));
    }
    if (args.get("query")) |value| {
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"query\" must be a string") };
        }
        if (value.string.len > 0) {
            input.selector = .{ .query = try ctx.allocator.dupe(u8, value.string) };
        }
    }

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn decodeSearch(alloc: Allocator, value: std.json.Value) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const invalid = std.fmt.comptimePrint("read_tool_result field \"search\" must be 1 to {d} non-empty strings", .{compactor.max_search_phrases});
    const items: []const std.json.Value = switch (value) {
        .string => (&value)[0..1],
        .array => |array| array.items,
        else => return .{ .failure = try alloc.dupe(u8, invalid) },
    };
    if (items.len == 0 or items.len > compactor.max_search_phrases) return .{ .failure = try alloc.dupe(u8, invalid) };
    for (items) |item| {
        if (item != .string or std.mem.trim(u8, item.string, " \t\r\n").len == 0) return .{ .failure = try alloc.dupe(u8, invalid) };
    }
    const input = try alloc.create(Input);
    errdefer alloc.destroy(input);
    input.* = .{ .handle = &.{} };
    const phrases = try alloc.alloc([]u8, items.len);
    var copied: usize = 0;
    errdefer {
        for (phrases[0..copied]) |phrase| alloc.free(phrase);
        alloc.free(phrases);
    }
    for (items, phrases) |item, *phrase| {
        phrase.* = try alloc.dupe(u8, item.string);
        copied += 1;
    }
    input.selector = .{ .search = phrases };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn parsePositiveInteger(value: std.json.Value) ?i64 {
    if (value != .integer or value.integer < 1) return null;
    return value.integer;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn classifyHandleNormalization(handle: []const u8) HandleNormalization {
    const trimmed = std.mem.trim(u8, handle, " \t\r\n");
    const suffix = if ((std.mem.startsWith(u8, trimmed, "result-") or result_store.isImageHandle(trimmed)) and
        std.mem.findScalar(u8, trimmed, '.') == null)
        ".txt"
    else
        "";
    return .{ .trimmed = trimmed, .suffix = suffix };
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (input.selector == .search) return null;
    const normalization = classifyHandleNormalization(input.handle);
    if (normalization.trimmed.len == 0) return try ctx.allocator.dupe(u8, "read_tool_result field \"handle\" must not be empty");
    var record_buffer: compactor.RecordFileBuffer = undefined;
    if (compactor.recordFile(&record_buffer, normalization.trimmed)) |file| {
        // A turn, tool call or earlier compaction saved by compaction, opened
        // by its ID (M12, T12, L2).
        const owned = try ctx.allocator.dupe(u8, file);
        ctx.allocator.free(input.handle);
        input.handle = owned;
        return null;
    }
    if (normalization.suffix.len > 0 or !std.mem.eql(u8, input.handle, normalization.trimmed)) {
        const owned = try std.mem.concat(ctx.allocator, u8, &.{ normalization.trimmed, normalization.suffix });
        ctx.allocator.free(input.handle);
        input.handle = owned;
    }
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    if (input.selector == .search) {
        const capability = ctx.session_child_capability orelse return .{
            .failure = try ctx.allocator.dupe(u8, "Nothing is saved: this session has no tool-result store."),
        };
        const queries: []const []const u8 = input.selector.search;
        const output = compactor.search(ctx.allocator, result_store.compactorStore(capability), queries) catch |err| return .{
            .failure = try ctx.allocator.print("Searching saved turns, tool calls and earlier compactions failed: {s}", .{@errorName(err)}),
        };
        return .{ .success = output };
    }
    if (result_store.isImageHandle(input.handle)) {
        const capability = ctx.session_child_capability orelse return .{
            .failure = try ctx.allocator.dupe(u8, "No active session image store is available."),
        };
        if (input.selector == .query or input.selector.range.start_byte != 1) return .{
            .failure = try ctx.allocator.dupe(u8, "Stored images are read as complete images. Use the handle without a query or byte offset."),
        };
        const images = result_store.loadToolImages(ctx.allocator, capability, input.handle) catch |err| return .{
            .failure = try formatReadFailure(ctx.allocator, input.handle, err),
        };
        errdefer @import("../../core/shared/types.zig").freeToolImages(ctx.allocator, images);
        return .{ .rich = .{
            .text = try ctx.allocator.dupe(u8, "Stored tool images attached to this result. They are sent to the model with your next request when this model accepts image input; when they cannot be sent, that request notes why and what to do instead."),
            .images = images,
            .is_error = false,
        } };
    }
    if (ctx.session_child_capability == null and
        ctx.ephemeral_command_replay == null and
        ctx.tool_result_dir == null)
    {
        return .{ .failure = try ctx.allocator.dupe(u8, "No active session tool-result store is available.") };
    }

    const output = readOutput(ctx, input) catch |err| {
        return .{ .failure = try formatReadFailure(ctx.allocator, input.handle, err) };
    };
    return .{ .success = output };
}

fn readOutput(ctx: tool_dispatch.DispatchContext, input: *Input) ![]u8 {
    if (ctx.session_child_capability) |capability| {
        const ordinary = switch (input.selector) {
            .query => |query| result_store.searchByQueryManaged(ctx.allocator, capability, input.handle, query),
            .range => |range| result_store.readByRangeManaged(ctx.allocator, capability, input.handle, range.start_byte, range.byte_count),
            .search => unreachable,
        };
        return ordinary catch |err| switch (err) {
            error.ResultHandleNotFound => switch (input.selector) {
                .query => |query| command_replay_store.searchAgentQueryManaged(
                    ctx.allocator,
                    capability,
                    input.handle,
                    query,
                    result_store.read_max_bytes,
                ),
                .range => |range| command_replay_store.readAgentPageManaged(
                    ctx.allocator,
                    capability,
                    input.handle,
                    range.start_byte,
                    range.byte_count,
                ),
                .search => unreachable,
            },
            else => return err,
        };
    }

    if (ctx.ephemeral_command_replay) |store| {
        return switch (input.selector) {
            .query => |query| command_replay_store.searchAgentQueryEphemeral(
                ctx.allocator,
                store,
                input.handle,
                query,
                result_store.read_max_bytes,
            ),
            .range => |range| command_replay_store.readAgentPageEphemeral(
                ctx.allocator,
                store,
                input.handle,
                range.start_byte,
                range.byte_count,
            ),
            .search => unreachable,
        };
    }

    const dir = ctx.tool_result_dir.?;
    return switch (input.selector) {
        .query => |query| result_store.searchByQuery(ctx.allocator, dir, input.handle, query),
        .range => |range| result_store.readByRange(ctx.allocator, dir, input.handle, range.start_byte, range.byte_count),
        .search => unreachable,
    };
}

fn formatReadFailure(alloc: Allocator, handle: []const u8, err: anyerror) ![]u8 {
    if (err == error.ResultHandleNotFound) {
        return alloc.print(
            "read_tool_result failed for handle {s}: ResultHandleNotFound. No exact match exists in the active tool-result store; handles are session-scoped and must be copied exactly from the tool result preview.",
            .{handle},
        );
    }
    return alloc.print("read_tool_result failed for handle {s}: {s}", .{ handle, @errorName(err) });
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

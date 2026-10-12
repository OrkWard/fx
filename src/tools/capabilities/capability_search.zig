const std = @import("std");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const lexical_relevance = @import("../../core/shared/lexical_relevance.zig");
const result_store = @import("../../core/session/result_store.zig");
const capability_retrieval = @import("../../core/tooling/capability_retrieval.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const skill_search = @import("../skills/skill_search.zig");

const Allocator = std.mem.Allocator;
const Input = struct {
    query: []u8,
    prepared: lexical_relevance.PreparedQuery,

    fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.query);
        self.* = undefined;
    }

    fn request(self: *const Input) capability_retrieval.Request {
        return .{
            .query = &self.prepared,
            .limit = capability_retrieval.default_limit,
            .relevance_policy = .intent,
        };
    }
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(ctx.allocator, "capability_search arguments must be valid JSON"),
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return failure(ctx.allocator, "capability_search arguments must be an object");
    }
    const query_value = parsed.value.object.get("query") orelse
        return failure(ctx.allocator, "capability_search field \"query\" is required");
    if (query_value != .string) {
        return failure(ctx.allocator, "capability_search field \"query\" must be a string");
    }
    if (query_value.string.len == 0) {
        return failure(ctx.allocator, "capability_search field \"query\" must not be empty");
    }
    if (query_value.string.len > lexical_relevance.max_query_bytes) {
        return failure(ctx.allocator, "capability_search query must not exceed 4096 bytes");
    }

    const query = try ctx.allocator.dupe(u8, query_value.string);
    errdefer ctx.allocator.free(query);
    const prepared = lexical_relevance.prepare(query) catch |err| switch (err) {
        error.QueryTooLong => unreachable,
    };
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .query = query,
        .prepared = prepared,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const output_cap = @min(
        ctx.max_tool_result_bytes,
        result_store.large_result_threshold_bytes,
    );
    var skill_result = skill_search.searchRequest(ctx, input.request(), output_cap) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return executionFailure(ctx.allocator, "skill", err),
    };
    defer skill_result.deinit(ctx.allocator);

    const output = renderProjected(ctx.allocator, &skill_result, output_cap) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return executionFailure(ctx.allocator, "skill", err),
    };
    return .{ .success = output };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn failure(alloc: Allocator, message: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, message) };
}

fn executionFailure(
    alloc: Allocator,
    domain: []const u8,
    err: anyerror,
) Allocator.Error!tool_dispatch.ToolResult {
    return .{ .failure = try alloc.print(
        "capability_search {s} search failed: {s}",
        .{ domain, @errorName(err) },
    ) };
}

fn renderProjected(
    alloc: Allocator,
    skill_result: *const skill_search.SearchResult,
    max_bytes: usize,
) ![]u8 {
    const output = renderSkills(
        alloc,
        skill_result.itemsJson(),
        skill_result.count,
        skill_result.total_matches,
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    if (output.len <= max_bytes) return output;
    alloc.free(output);
    return error.CapabilitySearchResultLimitTooSmall;
}

fn renderSkills(
    alloc: Allocator,
    skills_json: []const u8,
    count: usize,
    total_matches: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"skills\":[");
    try out.writer.writeAll(skills_json);
    try out.writer.print("],\"count\":{d},\"total_matches\":{d}", .{ count, total_matches });
    if (total_matches == 0) try out.writer.writeAll(",\"state\":\"no_match\"");
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

test "capability search decoder owns one bounded prepared query" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"query\":\"send an email\"}");
    switch (decoded) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const value = input.as(Input);
            try std.testing.expectEqualStrings("send an email", value.prepared.raw);
            try std.testing.expectEqual(@as(usize, 3), value.prepared.token_count);
        },
    }
}

test "capability search decoder rejects a missing or empty task" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "{}", "{\"query\":\"\"}" }) |args| {
        const decoded = try decode(.{ .allocator = alloc }, args);
        switch (decoded) {
            .failure => |message| {
                defer alloc.free(message);
                try std.testing.expect(std.mem.find(u8, message, "query") != null);
            },
            .input => |input| {
                input.deinit(alloc);
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "capability search projects bounded skill results" {
    const alloc = std.testing.allocator;
    const skills =
        "{\"skills\":[{\"name\":\"mail-helper\",\"description\":\"Send email\",\"location\":\"/skills/mail-helper\"}],\"count\":1,\"total_matches\":2,\"more_available\":true,\"next_cursor\":\"c1:s:1:1:1\"}";
    const skill_result = testSkillResult(skills, 1, 2);
    const output = try renderProjected(alloc, &skill_result, 4096);
    defer alloc.free(output);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{});
    defer parsed.deinit();
    const skill_items = parsed.value.object.get("skills").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), skill_items.len);
    try std.testing.expectEqualStrings("mail-helper", skill_items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("total_matches").?.integer);
    try std.testing.expect(parsed.value.object.get("more_available") == null);
    try std.testing.expect(parsed.value.object.get("next_cursor") == null);

    const projected_again = try tool_result_limits.prepareModelOutput(
        alloc,
        "capability_search",
        output,
        output.len,
    );
    defer alloc.free(@constCast(projected_again));
    try std.testing.expectEqualStrings(output, projected_again);

    try std.testing.expectError(
        error.CapabilitySearchResultLimitTooSmall,
        renderProjected(alloc, &skill_result, output.len - 1),
    );
}

test "capability search projection releases every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const skills =
                "{\"skills\":[{\"name\":\"mail-helper\",\"description\":\"Send email\",\"location\":\"/skills/mail-helper\"}],\"count\":1,\"total_matches\":1,\"more_available\":false,\"next_cursor\":null}";
            const skill_result = testSkillResult(skills, 1, 1);
            const output = try renderProjected(alloc, &skill_result, 1024);
            alloc.free(output);
        }
    };
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, Case.run, .{});
}

test "capability search marks an empty search as terminal" {
    const alloc = std.testing.allocator;
    const skills =
        "{\"skills\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null}";
    const skill_result = testSkillResult(skills, 0, 0);
    const output = try renderProjected(alloc, &skill_result, 4096);
    defer alloc.free(output);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "no_match",
        parsed.value.object.get("state").?.string,
    );
    try std.testing.expectEqual(@as(usize, 4), parsed.value.object.count());
}

fn testSkillResult(output: []const u8, count: usize, total_matches: usize) skill_search.SearchResult {
    const items_start = "{\"skills\":[".len;
    const items_end = std.mem.find(u8, output, "],\"count\":") orelse unreachable;
    return .{
        .model_output = @constCast(output),
        .items_start = items_start,
        .items_end = items_end,
        .count = count,
        .total_matches = total_matches,
    };
}

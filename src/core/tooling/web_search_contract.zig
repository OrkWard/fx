const std = @import("std");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Request = struct {
    query: []const u8,
    allowed_domains: ?[]const []const u8 = null,
    blocked_domains: ?[]const []const u8 = null,
};

pub const Progress = union(enum) {
    query_update: []const u8,
    results_received: struct {
        query: []const u8,
        result_count: usize,
    },
};

pub const Source = struct {
    title: []const u8,
    url: []const u8,

    pub fn deinit(self: Source, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.url);
    }
};

pub const SearchBlock = struct {
    tool_use_id: []const u8,
    content: []const Source,

    pub fn deinit(self: SearchBlock, alloc: Allocator) void {
        alloc.free(self.tool_use_id);
        for (self.content) |source| source.deinit(alloc);
        alloc.free(self.content);
    }
};

pub const TerminalIncomplete = struct {
    stop_reason: []const u8,
    message: []const u8,

    pub fn deinit(self: TerminalIncomplete, alloc: Allocator) void {
        alloc.free(self.stop_reason);
        alloc.free(self.message);
    }
};

pub const ResultItem = union(enum) {
    commentary: []const u8,
    search: SearchBlock,
    error_text: []const u8,
    terminal_incomplete: TerminalIncomplete,

    pub fn deinit(self: ResultItem, alloc: Allocator) void {
        switch (self) {
            .commentary => |text| alloc.free(text),
            .search => |search| search.deinit(alloc),
            .error_text => |text| alloc.free(text),
            .terminal_incomplete => |incomplete| incomplete.deinit(alloc),
        }
    }
};

/// Search output with a borrowed query and owned result allocations. The
/// caller must call `deinit` with the allocator that received the output.
pub const Output = struct {
    query: []const u8,
    results: []const ResultItem,
    incomplete: bool = false,
    duration_ms: u64,
    web_search_requests: u32,

    pub fn deinit(self: *Output, alloc: Allocator) void {
        deinitItems(alloc, self.results);
        self.results = &.{};
    }
};

/// Executor output whose result allocations are owned by the caller.
pub const ExecutionOutput = struct {
    output: Output,
    inner_usage: ?types.ToolUsage = null,

    pub fn deinit(self: *ExecutionOutput, alloc: Allocator) void {
        self.output.deinit(alloc);
        self.* = undefined;
    }
};

fn deinitItems(alloc: Allocator, items: []const ResultItem) void {
    for (items) |item| item.deinit(alloc);
    if (items.len > 0) alloc.free(items);
}

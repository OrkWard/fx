const std = @import("std");
const types = @import("session_store_types.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;
const SessionSummary = types.SessionSummary;
const ResumableSessionContinuation = types.ResumableSessionContinuation;
const ResumableSessionPage = types.ResumableSessionPage;

pub fn freeSummaries(
    alloc: Allocator,
    sessions: *std.ArrayList(SessionSummary),
) void {
    for (sessions.items) |*summary| summary.deinit(alloc);
    sessions.deinit(alloc);
}

pub fn cloneSessionSummary(
    alloc: Allocator,
    source: SessionSummary,
) !SessionSummary {
    const id = try alloc.dupe(u8, source.id);
    errdefer alloc.free(id);
    const workspace_root = if (source.workspace_root) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (workspace_root) |value| alloc.free(value);
    const origin_workspace_root = if (source.origin_workspace_root) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (origin_workspace_root) |value| alloc.free(value);
    const title = if (source.title) |value| try alloc.dupe(u8, value) else null;
    errdefer if (title) |value| alloc.free(value);
    const preview = if (source.preview) |value| try alloc.dupe(u8, value) else null;
    errdefer if (preview) |value| alloc.free(value);
    return .{
        .id = id,
        .workspace_root = workspace_root,
        .origin_workspace_root = origin_workspace_root,
        .title = title,
        .preview = preview,
        .display_metadata_present = source.display_metadata_present,
        .created_at_ms = source.created_at_ms,
        .updated_at_ms = source.updated_at_ms,
        .conversation_language = source.conversation_language,
        .history_len = source.history_len,
        .has_checkpoint = source.has_checkpoint,
        .has_managed_children = source.has_managed_children,
    };
}

pub fn resumablePageFromSummaries(
    alloc: Allocator,
    summaries: []const SessionSummary,
    workspace_root: ?[]const u8,
    active_id: ?[]const u8,
    continuation: ?ResumableSessionContinuation,
    limit: usize,
) !ResumableSessionPage {
    const page_limit = @max(limit, 1);
    var page: ResumableSessionPage = .{};
    errdefer page.deinit(alloc);
    for (summaries) |summary| {
        if (workspace_root) |root| {
            const summary_workspace = summary.workspace_root orelse continue;
            if (!std.mem.eql(u8, summary_workspace, root)) continue;
        }
        if (!summary.hasResumableContent()) continue;
        if (active_id) |id| {
            if (std.mem.eql(u8, summary.id, id)) continue;
        }
        if (continuation) |position| {
            if (!summaryFollowsContinuation(summary, position)) continue;
        }
        if (page.summaries.items.len >= page_limit) {
            page.has_more = true;
            break;
        }
        var copied = try cloneSessionSummary(alloc, summary);
        page.summaries.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    return page;
}

pub fn sessionListPageFromSummaries(
    alloc: Allocator,
    summaries: []const SessionSummary,
    workspace_root: ?[]const u8,
    continuation: ?ResumableSessionContinuation,
    limit: usize,
) !types.SessionListPage {
    var page: types.SessionListPage = .{};
    errdefer page.deinit(alloc);
    for (summaries) |summary| {
        if (workspace_root) |root| {
            const summary_workspace = summary.workspace_root orelse continue;
            if (!std.mem.eql(u8, summary_workspace, root)) continue;
        }
        if (continuation) |position| {
            if (!summaryFollowsContinuation(summary, position)) continue;
        }
        if (page.summaries.items.len == limit) {
            page.has_more = true;
            break;
        }
        var copied = try cloneSessionSummary(alloc, summary);
        page.summaries.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    return page;
}

pub fn summaryFollowsContinuation(
    summary: SessionSummary,
    continuation: ResumableSessionContinuation,
) bool {
    if (summary.updated_at_ms != continuation.updated_at_ms) {
        return summary.updated_at_ms < continuation.updated_at_ms;
    }
    return std.mem.order(u8, summary.id, continuation.id) == .lt;
}

pub fn sortSummariesNewestFirst(items: []SessionSummary) void {
    sort_utils.sort(SessionSummary, items, {}, lessSummaryNewerFirst);
}

fn lessSummaryNewerFirst(_: void, a: SessionSummary, b: SessionSummary) bool {
    if (a.updated_at_ms != b.updated_at_ms) return a.updated_at_ms > b.updated_at_ms;
    return std.mem.order(u8, a.id, b.id) == .gt;
}

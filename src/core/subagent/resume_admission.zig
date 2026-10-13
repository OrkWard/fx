const std = @import("std");
const child_state = @import("child_state.zig");
const session = @import("../session/session.zig");
const session_store = @import("../session/session_store.zig");
const catalog_cache = @import("../session/session_catalog_cache.zig");
const session_summary_codec = @import("../session/session_summary_codec.zig");

const Allocator = std.mem.Allocator;

pub const ActionableContinuation = struct {
    updated_at_ms: i64,
    id: []u8,

    pub fn deinit(self: *ActionableContinuation, alloc: Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }

    pub fn view(self: ActionableContinuation) session_store.ResumableSessionContinuation {
        return .{ .updated_at_ms = self.updated_at_ms, .id = self.id };
    }
};

/// Lists visible sessions from the session index, newest first, without
/// writing anything. The index reuses fingerprint-matched rows, so a listing
/// opens only the sessions that changed since writable flows last saved it.
pub fn listVisiblePage(
    store: session_store.Store,
    alloc: Allocator,
    scope: session_store.SessionListScope,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !session_store.SessionListPage {
    if (limit == 0 or limit > session_store.session_list_max_limit) return error.InvalidSessionListLimit;
    var catalog = catalog_cache.listActionableCatalog(store, alloc, null, null, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SessionStoreUnavailable,
    };
    defer catalog.deinit(alloc);
    var page = try session_summary_codec.sessionListPageFromSummaries(
        alloc,
        catalog.summaries.items,
        switch (scope) {
            .current_workspace => store.workspace_root,
            .all_workspaces => null,
        },
        continuation,
        limit,
    );
    page.skipped_invalid = catalog.skipped_invalid;
    return page;
}

/// Returns the newest listed session in this workspace from the index page
/// `--resume last` reads. `--resume last` also skips a session whose stale log
/// failed to replay in that listing, so the two can differ. Caller owns the
/// summary.
pub fn latestVisibleWorkspaceSummary(
    store: session_store.Store,
    alloc: Allocator,
) !session_store.SessionSummary {
    var page = try listVisiblePage(
        store,
        alloc,
        .current_workspace,
        null,
        1,
    );
    defer page.deinit(alloc);
    if (page.summaries.items.len == 0) {
        if (page.skipped_invalid > 0) return error.NoReadableSessions;
        return error.NoSavedSessions;
    }
    return session_summary_codec.cloneSessionSummary(
        alloc,
        page.summaries.items[0],
    );
}

pub fn loadVisibleReadOnlyDetail(
    store: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
    options: session_store.ResumeOptions,
) !session_store.ReadOnlyDetail {
    const managed = child_state.hasManagedChildMarker(
        store,
        alloc,
        session_id,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.InvalidSessionId => return err,
        else => return error.SessionNotFound,
    };
    if (managed) return error.SessionNotFound;

    var detail = store.loadReadOnlyAdmissionDetail(alloc, session_id, options) catch |err| switch (err) {
        error.ConversationHistoryUnavailable => return error.SessionNotFound,
        else => return err,
    };
    errdefer detail.deinit(alloc);
    if (detail.state.subagent_child) return error.SessionNotFound;
    return detail;
}

pub fn resumeForExternalPrompt(
    store: session_store.Store,
    alloc: Allocator,
    target: session_store.ResumeTarget,
    workspace_root: []const u8,
    options: session_store.ResumeOptions,
) !session_store.LoadedWritableSession {
    switch (target) {
        .id => |session_id| try ensureExternalMarkerAllowed(store, alloc, session_id),
        .last => {},
    }
    var loaded = try store.resumeTargetForWrite(
        alloc,
        target,
        workspace_root,
        options,
    );
    errdefer loaded.deinit(alloc);
    try ensureExternalMarkerAllowed(store, alloc, loaded.active_id);
    try ensureLoadedExternalPromptAllowed(&loaded);
    return loaded;
}

fn ensureExternalMarkerAllowed(
    store: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
) !void {
    const managed = child_state.hasManagedChildMarker(
        store,
        alloc,
        session_id,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SessionNotFound, error.SessionStoreUnavailable => return,
        else => return err,
    };
    if (managed) return error.OneOffSessionNotResumable;
}

fn ensureLoadedExternalPromptAllowed(
    loaded: *const session_store.LoadedWritableSession,
) !void {
    if (loaded.state.subagent_child) return error.OneOffSessionNotResumable;
}

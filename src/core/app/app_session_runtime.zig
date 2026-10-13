const std = @import("std");
const worker_runtime = @import("../agent/worker_runtime.zig");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const question_answer = @import("../agent/question_answer.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
const assistant_presentation = @import("../agent/assistant_presentation.zig");
const tool_admission = @import("../agent/runtime/tool_admission.zig");
const tool_presentation = @import("../agent/runtime/tool_presentation.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const host_capability = @import("../hosts/host.zig");
const diff = @import("../output/diff.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const app_lifecycle = @import("app_lifecycle.zig");
const provider_runtime = @import("provider_runtime.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const list_window = @import("../shared/list_window.zig");
const session_runtime = @import("../session/session.zig");
const session_catalog = @import("../session/session_catalog.zig");
const session_codec = @import("../session/session_codec.zig");
const session_usage = @import("../session/session_usage.zig");
const session_child_store = @import("../session/session_child_store.zig");
const legacy_background_migration = @import("../session/legacy_background_migration.zig");
const result_store = @import("../session/result_store.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const tooling_presentation = @import("../tooling/tool_presentation.zig");
const tool_args = @import("../tooling/tool_args.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const captured_command = @import("../tooling/captured_command.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const session_display_metadata = @import("../session/session_display_metadata.zig");
const session_title_generation = @import("../session/session_title_generation.zig");
const session_log = @import("../session/session_log.zig");
const session_store = @import("../session/session_store.zig");
const session_catalog_cache = @import("../session/session_catalog_cache.zig");
const session_summary_codec = @import("../session/session_summary_codec.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_authority = @import("../subagent/authority.zig");
const subagent_resume_admission = @import("../subagent/resume_admission.zig");
const types = @import("../shared/types.zig");
const history_range = @import("../shared/history_range.zig");
const permissions = @import("../permissions/permissions.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const resume_projection = @import("../../ui/transcript/resume_projection.zig");
const ui_render = @import("../../ui/render.zig");
const update_notes = @import("../upgrade/update_notes.zig");
const update_target = @import("../upgrade/update_target.zig");

const Allocator = std.mem.Allocator;

fn monotonicMillis(io: std.Io) u64 {
    const now = std.Io.Clock.Timestamp.now(io, .awake);
    if (now.raw.nanoseconds <= 0) return 0;
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(u64, milliseconds) orelse std.math.maxInt(u64);
}
const live_session_handoff_timeout_ms: u64 = 2_000;
const live_session_worker_cancel_timeout_ms: u64 = 5_000;

const RecoveryAutoContinue = enum {
    auto_continue,
    skip_compaction_owned,
    ask_after_unclean_exit,
};

/// Whether a paused recovery continues on its own after a restart or resume.
/// A leftover owner marker means the previous process died mid-recovery, and
/// a leftover asked marker means a prior resume already suppressed this
/// checkpoint without the user resolving it. Either way the turn is the
/// user's to retry, not fx's to re-spend.
fn recoveryAutoContinueDecision(
    checkpoint: session_codec.RecoveryCheckpoint,
    previous_owner_died: bool,
    recovery_asked_before: bool,
) RecoveryAutoContinue {
    if (checkpoint.cause == .compaction_prepared) return .skip_compaction_owned;
    if (recovery_asked_before) return .ask_after_unclean_exit;
    if (previous_owner_died) return .ask_after_unclean_exit;
    return .auto_continue;
}

const BackgroundSessionPolicy = enum {
    carry_forward,
    stop_forget,
};

const LiveSessionTransitionEvent = union(enum) {
    request: BackgroundSessionPolicy,
    settle,
};

const LiveSessionTransitionAction = union(enum) {
    apply_now: BackgroundSessionPolicy,
    apply_pending: BackgroundSessionPolicy,
    none,
};

const LiveSessionTransitionDecision = struct {
    pending_policy: ?BackgroundSessionPolicy,
    action: LiveSessionTransitionAction,
};

const LiveSessionWait = union(enum) {
    worker: u64,
    geometry: u64,
};

const LiveSessionTimeout = enum { worker, geometry };

fn liveSessionWaitTimeout(wait: LiveSessionWait, processing: bool, now_ms: u64) ?LiveSessionTimeout {
    return switch (wait) {
        .worker => |started| if (processing and now_ms -| started >= live_session_worker_cancel_timeout_ms) .worker else null,
        .geometry => |started| if (!processing and now_ms -| started >= live_session_handoff_timeout_ms) .geometry else null,
    };
}

fn decideLiveSessionTransition(
    processing: bool,
    pending_policy: ?BackgroundSessionPolicy,
    event: LiveSessionTransitionEvent,
) LiveSessionTransitionDecision {
    return switch (event) {
        .request => |policy| .{
            .pending_policy = null,
            .action = .{ .apply_now = policy },
        },
        .settle => if (processing)
            .{
                .pending_policy = pending_policy,
                .action = .none,
            }
        else if (pending_policy) |policy|
            .{
                .pending_policy = null,
                .action = .{ .apply_pending = policy },
            }
        else
            .{
                .pending_policy = null,
                .action = .none,
            },
    };
}

fn nextImageIdForResume(
    alloc: Allocator,
    history: []const types.HistoryTurn,
    checkpoint: ?session_codec.RecoveryCheckpoint,
) !usize {
    const restored_catalog = try session_runtime.collect_image_catalog(
        alloc,
        history,
        &.{},
    );
    defer types.freeImageAttachmentSlice(alloc, restored_catalog);
    if (checkpoint) |value| {
        const merged = try session_runtime.merge_image_catalog_history_turn(alloc, restored_catalog, value.interruptedTurn());
        defer types.freeImageAttachmentSlice(alloc, merged);
        return (try image_attachments.calculate_next_image_id(merged)).next_id;
    }
    return (try image_attachments.calculate_next_image_id(restored_catalog)).next_id;
}

pub const SessionPickerScope = session_catalog.Scope;

pub const HistoryAppendOutcome = enum {
    uncommitted,
    committed,
};

pub const ResumeHandoffIntent = enum {
    none,
    requested,
    upgrade_requested,
};

const UpgradeNotice = struct {
    version: []const u8,
    channel: update_target.Channel,
    previous_revision: []const u8,
    revision: []const u8,
};

const ResumeNotice = union(enum) {
    session,
    upgrade: UpgradeNotice,
};

fn writeUpgradeNoticeBody(writer: *std.Io.Writer, upgrade: UpgradeNotice) !void {
    try writer.writeAll("fx has been updated to ");
    if (upgrade.channel == .dev and update_target.isValidRevision(upgrade.revision)) {
        try writer.print("dev {s} (v{s})", .{
            upgrade.revision[0..@min(upgrade.revision.len, 12)],
            update_target.normalizeVersion(upgrade.version),
        });
    } else {
        try writer.print("v{s}", .{update_target.normalizeVersion(upgrade.version)});
    }
    if (update_notes.destination(
        upgrade.channel,
        upgrade.version,
        upgrade.previous_revision,
        upgrade.revision,
    )) |notes| {
        try writer.writeByte(' ');
        try notes.writeHyperlinkLabel(writer);
    }
}

pub const ResumeHandoffState = struct {
    intent: ResumeHandoffIntent,
    has_writable_session: bool,
    is_pristine: bool,
};

pub fn shouldCreateResumeHandoff(state: ResumeHandoffState) bool {
    return state.intent != .none and
        state.has_writable_session and
        (!state.is_pristine or state.intent == .upgrade_requested);
}

/// Owns `session_id`; callers must release it with `deinit`.
pub const ResumeHandoff = struct {
    session_id: []u8,

    pub fn deinit(self: *ResumeHandoff, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

pub const ShutdownOutcome = struct {
    handoff: ?ResumeHandoff = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *ShutdownOutcome, alloc: Allocator) void {
        if (self.handoff) |*handoff| handoff.deinit(alloc);
        self.* = undefined;
    }
};

pub const SessionPreferencePatch = struct {
    provider: ?model_provider.ProviderId = null,
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    fast_mode: ?bool = null,
    ultrafast_mode: ?bool = null,

    pub fn userSettingsPatch(self: SessionPreferencePatch) config_runtime.UserSettingsPatch {
        var patch = config_runtime.UserSettingsPatch{
            .provider = self.provider,
            .effort = self.effort,
            .fast_mode = self.fast_mode,
            .ultrafast_mode = self.ultrafast_mode,
        };
        if (self.model) |model| patch.model_preference = .{
            .provider = self.provider orelse .gateway,
            .model = model,
        };
        return patch;
    }
};

pub const PreferenceCommitResult = struct {
    settings_outcome: ?config_runtime.CommitOutcome = null,
    settings_error: ?anyerror = null,
    settings_failure_cleanup: config_runtime.LegacyCleanup = .{},
    session_error: ?anyerror = null,

    pub fn deinit(self: *PreferenceCommitResult, alloc: Allocator) void {
        if (self.settings_outcome) |*outcome| outcome.deinit(alloc);
        self.settings_failure_cleanup.deinit(alloc);
        self.* = undefined;
    }
};

pub const SessionPicker = struct {
    active: bool = false,
    load_state: session_catalog.LoadState = .loading,
    generation: u64 = 0,
    has_more: bool = false,
    loading_more: bool = false,
    summaries: std.ArrayList(session_store.SessionSummary) = .empty,
    continuation: ?subagent_resume_admission.ActionableContinuation = null,
    selected: usize = 0,
    window_start: usize = 0,
    scope: SessionPickerScope = .current_workspace,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,
    selection_failure: ?session_catalog.ResumeFailure = null,

    pub fn deinit(self: *SessionPicker, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        if (self.continuation) |*continuation| continuation.deinit(alloc);
        self.* = .{};
    }

    fn appendSummary(
        self: *SessionPicker,
        alloc: Allocator,
        source: *const session_store.SessionSummary,
    ) !void {
        if (!source.hasResumableContent()) return;

        var summary = try session_summary_codec.cloneSessionSummary(alloc, source.*);
        errdefer summary.deinit(alloc);
        try self.summaries.append(alloc, summary);
    }

    pub fn selectedId(self: *const SessionPicker) ?[]const u8 {
        if (!self.active or self.load_state != .ready) return null;
        if (self.selected >= self.filteredItemCount()) return null;
        const summary = session_catalog.summaryAt(self.summaries.items, self.query(), self.selected) orelse return null;
        return summary.id;
    }

    fn isLoading(self: *const SessionPicker) bool {
        return self.active and self.load_state == .loading;
    }

    pub fn query(self: *const SessionPicker) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn setQuery(self: *SessionPicker, query_text: []const u8) void {
        const len = @min(query_text.len, self.query_buf.len);
        if (len > 0) @memmove(self.query_buf[0..len], query_text[0..len]);
        self.query_len = len;
        self.selected = 0;
        self.window_start = 0;
        self.selection_failure = null;
    }

    pub fn filteredItemCount(self: *const SessionPicker) usize {
        return session_catalog.filteredCount(self.summaries.items, self.query());
    }

    pub fn navigationItemCount(self: *const SessionPicker) usize {
        return self.filteredItemCount() + @intFromBool(self.has_more);
    }

    fn isLoadMoreSelected(self: *const SessionPicker) bool {
        return self.active and self.load_state == .ready and self.has_more and
            self.selected == self.filteredItemCount();
    }

    fn moveVisibleItems(self: *SessionPicker, delta: i32, visible_items: u16) bool {
        if (!self.active or self.load_state != .ready) return false;
        self.selection_failure = null;
        const count = self.navigationItemCount();
        if (count == 0) return true;
        // Clamp at both ends instead of wrapping: at the top the selection
        // stays on the first session, at the bottom on the last row.
        const current: i32 = @intCast(self.selected % count);
        var next = current + delta;
        if (next < 0) next = 0;
        if (next >= @as(i32, @intCast(count))) next = @as(i32, @intCast(count)) - 1;
        self.selected = @intCast(next);
        self.syncWindowStart(visible_items);
        return true;
    }

    pub fn syncWindowStart(self: *SessionPicker, visible_items: u16) void {
        const session_count = self.filteredItemCount();
        const action_items: u16 = @intFromBool(self.has_more and visible_items > 0);
        const visible_sessions = visible_items -| action_items;
        if (session_count == 0 or visible_sessions == 0) {
            self.window_start = 0;
            return;
        }
        if (self.selected >= session_count) {
            self.window_start = session_count -| visible_sessions;
            return;
        }
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            session_count,
            self.selected,
            visible_sessions,
        );
    }

    fn appendPage(
        self: *SessionPicker,
        alloc: Allocator,
        summaries: []const session_store.SessionSummary,
    ) !void {
        const summary_len = self.summaries.items.len;
        errdefer {
            while (self.summaries.items.len > summary_len) {
                if (self.summaries.pop()) |summary_value| {
                    var summary = summary_value;
                    summary.deinit(alloc);
                }
            }
        }
        for (summaries) |*summary| try self.appendSummary(alloc, summary);
    }
};

const SessionPickerCatalogCache = struct {
    ready: bool = false,
    loaded_at_ns: i128 = 0,
    active_id: ?[]u8 = null,
    catalog: session_catalog_cache.ActionableSessionCatalog = .{},

    fn deinit(self: *SessionPickerCatalogCache) void {
        const alloc = std.heap.c_allocator;
        if (self.active_id) |id| alloc.free(id);
        self.catalog.deinit(alloc);
        self.* = .{};
    }

    fn matches(
        self: *const SessionPickerCatalogCache,
        active_id: ?[]const u8,
    ) bool {
        return self.ready and optionalStringEql(self.active_id, active_id);
    }

    fn isFresh(self: *const SessionPickerCatalogCache) bool {
        const now_ns = io_mod.nanoTimestamp();
        return self.ready and now_ns >= self.loaded_at_ns and
            now_ns - self.loaded_at_ns <= 5 * std.time.ns_per_s;
    }

    fn install(
        self: *SessionPickerCatalogCache,
        source: *session_catalog_cache.ActionableSessionCatalog,
        active_id: ?[]const u8,
    ) !void {
        return self.installAt(source, active_id, io_mod.nanoTimestamp());
    }

    /// Same content as install but stamped stale, so the picker shows it
    /// immediately while still scheduling a background revalidation scan.
    fn installStale(
        self: *SessionPickerCatalogCache,
        source: *session_catalog_cache.ActionableSessionCatalog,
        active_id: ?[]const u8,
    ) !void {
        return self.installAt(source, active_id, 0);
    }

    fn installAt(
        self: *SessionPickerCatalogCache,
        source: *session_catalog_cache.ActionableSessionCatalog,
        active_id: ?[]const u8,
        loaded_at_ns: i128,
    ) !void {
        const alloc = std.heap.c_allocator;
        const owned_active_id = if (active_id) |id| try alloc.dupe(u8, id) else null;
        errdefer if (owned_active_id) |id| alloc.free(id);
        self.deinit();
        self.* = .{
            .ready = true,
            .loaded_at_ns = loaded_at_ns,
            .active_id = owned_active_id,
            .catalog = source.*,
        };
        source.* = .{};
    }
};

/// Publishes the persisted picker catalog as a stale in-memory catalog so a
/// cold picker open can paint immediately instead of waiting for the full
/// session scan. Rows are unvalidated against current on-disk state; the
/// background scan replaces them, and canonical admission re-checks any
/// selection.
fn installStaleDiskCatalog(
    store: *const session_store.Store,
    cache: *SessionPickerCatalogCache,
    active_id: ?[]const u8,
) !void {
    const sessions = store.canonical_root.sessions orelse return;
    var loaded = try session_catalog_cache.Loaded.load(std.heap.c_allocator, sessions, null);
    defer loaded.deinit(std.heap.c_allocator);
    // Without a persisted catalog there is nothing to paint early; keep the
    // loading state until the background scan lands.
    if (loaded.parsed == null) return;
    var summaries = try loaded.cloneVisibleSummaries(std.heap.c_allocator, active_id);
    errdefer {
        for (summaries.items) |*summary| summary.deinit(std.heap.c_allocator);
        summaries.deinit(std.heap.c_allocator);
    }
    var catalog: session_catalog_cache.ActionableSessionCatalog = .{ .summaries = summaries };
    session_summary_codec.sortSummariesNewestFirst(catalog.summaries.items);
    try cache.installStale(&catalog, active_id);
}

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn replaceSessionPickerPage(
    picker: *SessionPicker,
    alloc: Allocator,
    source: *const session_store.ResumableSessionPage,
) !void {
    var replacement: std.ArrayList(session_store.SessionSummary) = .empty;
    errdefer {
        for (replacement.items) |*summary| summary.deinit(alloc);
        replacement.deinit(alloc);
    }
    for (source.summaries.items) |*summary| {
        if (!summary.hasResumableContent()) continue;
        var copied = try session_summary_codec.cloneSessionSummary(alloc, summary.*);
        replacement.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    for (picker.summaries.items) |*summary| summary.deinit(alloc);
    picker.summaries.deinit(alloc);
    picker.summaries = replacement;
}

fn applySessionPickerCatalogPage(
    picker: *SessionPicker,
    alloc: Allocator,
    cache: *const SessionPickerCatalogCache,
    workspace_root: []const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
    append: bool,
) !void {
    const workspace = if (picker.scope == .current_workspace) workspace_root else null;
    var selected_index: ?usize = null;
    var page_limit = limit;
    if (!append) {
        page_limit = @max(page_limit, picker.summaries.items.len);
        if (picker.selectedId()) |selected_id| {
            var index: usize = 0;
            for (cache.catalog.summaries.items) |summary| {
                if (workspace) |root| {
                    if (summary.workspace_root == null or !std.mem.eql(u8, summary.workspace_root.?, root)) continue;
                }
                if (std.mem.eql(u8, summary.id, selected_id)) {
                    selected_index = index;
                    page_limit = @max(page_limit, index + 1);
                    break;
                }
                index += 1;
            }
        }
    }
    var page = try session_summary_codec.resumablePageFromSummaries(
        alloc,
        cache.catalog.summaries.items,
        workspace,
        null,
        continuation,
        page_limit,
    );
    defer page.deinit(alloc);
    var next: ?subagent_resume_admission.ActionableContinuation = if (page.has_more and page.summaries.items.len > 0) blk: {
        const last = page.summaries.items[page.summaries.items.len - 1];
        break :blk .{
            .updated_at_ms = last.updated_at_ms,
            .id = try alloc.dupe(u8, last.id),
        };
    } else null;
    defer if (next) |*value| value.deinit(alloc);
    const previous_filtered_count = picker.filteredItemCount();
    const selected_load_more = append and
        picker.selected == previous_filtered_count;
    if (append) {
        try picker.appendPage(alloc, page.summaries.items);
    } else {
        try replaceSessionPickerPage(picker, alloc, &page);
    }
    if (picker.continuation) |*prior| prior.deinit(alloc);
    picker.continuation = next;
    next = null;
    picker.has_more = page.has_more;
    picker.loading_more = false;
    picker.load_state = .ready;
    if (!append) {
        if (selected_index) |index| {
            picker.selected = session_catalog.filteredCount(
                picker.summaries.items[0..index],
                picker.query(),
            );
        }
        picker.selected = @min(picker.selected, picker.filteredItemCount() -| 1);
        picker.window_start = @min(picker.window_start, picker.selected);
    } else if (selected_load_more) {
        picker.selected = selectionAfterLoadedPage(
            previous_filtered_count,
            picker.filteredItemCount(),
            picker.has_more,
        );
    }
}

fn selectionAfterLoadedPage(
    previous_filtered_count: usize,
    filtered_count: usize,
    has_more: bool,
) usize {
    if (filtered_count > previous_filtered_count) return previous_filtered_count;
    if (has_more) return filtered_count;
    return filtered_count -| 1;
}

const SessionPickerLoad = struct {
    const PageRequest = struct {
        generation: u64,
        active_id: ?[]u8 = null,

        fn init(
            generation: u64,
            active_id: ?[]const u8,
        ) !PageRequest {
            const alloc = std.heap.c_allocator;
            var request: PageRequest = .{ .generation = generation };
            errdefer request.deinit();
            if (active_id) |id| request.active_id = try alloc.dupe(u8, id);
            return request;
        }

        fn deinit(self: *PageRequest) void {
            if (self.active_id) |id| std.heap.c_allocator.free(id);
            self.* = undefined;
        }
    };

    /// Where a listing comes from.
    const Source = union(enum) {
        v1: *const session_store.Store,

        fn workspaceRoot(source: Source) []const u8 {
            return switch (source) {
                .v1 => |store| store.workspace_root,
            };
        }
    };

    const Task = struct {
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        // Main-loop-owned; worker failures may also set cancel_requested.
        abandoned: bool = false,
        home_dir: []u8,
        workspace_root: []u8,
        request: PageRequest,
        catalog: ?session_catalog_cache.ActionableSessionCatalog = null,
        cache_writer: ?session_catalog_cache.Writer = null,
        failure: ?anyerror = null,

        fn requestStop(self: *Task) void {
            if (!self.done.load(.acquire) and
                !self.cancel_requested.swap(true, .acq_rel))
            {
                debug_trace.logf(
                    "core",
                    "session picker load cancellation requested generation={d}",
                    .{self.request.generation},
                );
            }
        }

        fn deinit(self: *Task) void {
            self.requestStop();
            if (self.thread) |thread| thread.join();
            if (self.catalog) |*catalog| catalog.deinit(std.heap.c_allocator);
            if (self.cache_writer) |*writer| writer.deinit();
            self.request.deinit();
            std.heap.c_allocator.free(self.home_dir);
            std.heap.c_allocator.free(self.workspace_root);
            std.heap.c_allocator.destroy(self);
        }
    };

    task: ?*Task = null,
    pending: ?PageRequest = null,
    next_generation: u64 = 1,

    fn deinit(self: *SessionPickerLoad) void {
        self.requestStop();
        if (self.task) |task| task.deinit();
        self.* = .{};
    }

    fn requestStop(self: *SessionPickerLoad) void {
        if (self.task) |task| task.requestStop();
        if (self.pending) |*pending| {
            debug_trace.logf(
                "core",
                "session picker request dropped reason=shutdown generation={d}",
                .{pending.generation},
            );
            pending.deinit();
            self.pending = null;
        }
    }

    fn allocateGeneration(self: *SessionPickerLoad) u64 {
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        return generation;
    }

    fn schedule(
        self: *SessionPickerLoad,
        source: Source,
        request: PageRequest,
    ) !void {
        if (self.task != null) {
            self.replacePending(request);
            return;
        }
        try self.start(source, request);
    }

    fn replacePending(self: *SessionPickerLoad, request: PageRequest) void {
        if (self.pending) |*pending| {
            debug_trace.logf(
                "core",
                "session picker request dropped reason=superseded generation={d}",
                .{pending.generation},
            );
            pending.deinit();
        }
        self.pending = request;
    }

    fn cancelGeneration(self: *SessionPickerLoad, generation: u64) void {
        if (self.task) |task| {
            if (task.request.generation == generation) {
                task.abandoned = true;
                task.requestStop();
                debug_trace.logf(
                    "core",
                    "session picker request abandoned reason=cancelled generation={d}",
                    .{generation},
                );
            }
        }
        if (self.pending) |pending| {
            if (pending.generation == generation) {
                debug_trace.logf(
                    "core",
                    "session picker request dropped reason=cancelled generation={d}",
                    .{generation},
                );
                var owned = self.pending.?;
                self.pending = null;
                owned.deinit();
            }
        }
    }

    fn pendingGeneration(self: *const SessionPickerLoad) ?u64 {
        return if (self.pending) |request| request.generation else null;
    }

    fn matchingInitialGeneration(
        self: *const SessionPickerLoad,
        active_id: ?[]const u8,
    ) ?u64 {
        if (self.task) |task| {
            if (!task.abandoned and
                optionalStringEql(task.request.active_id, active_id))
            {
                return task.request.generation;
            }
        }
        if (self.pending) |request| {
            if (optionalStringEql(request.active_id, active_id)) {
                return request.generation;
            }
        }
        return null;
    }

    fn startPending(self: *SessionPickerLoad, source: Source) !?u64 {
        const request = self.pending orelse return null;
        self.pending = null;
        const generation = request.generation;
        try self.start(source, request);
        return generation;
    }

    fn start(
        self: *SessionPickerLoad,
        source: Source,
        request: PageRequest,
    ) !void {
        std.debug.assert(self.task == null);

        const alloc = std.heap.c_allocator;
        var owned_request = request;
        const home_dir = alloc.dupe(u8, switch (source) {
            .v1 => |store| store.home_dir,
        }) catch |err| {
            owned_request.deinit();
            return err;
        };
        const workspace_root = alloc.dupe(u8, source.workspaceRoot()) catch |err| {
            alloc.free(home_dir);
            owned_request.deinit();
            return err;
        };
        const task = alloc.create(Task) catch |err| {
            alloc.free(workspace_root);
            alloc.free(home_dir);
            owned_request.deinit();
            return err;
        };
        task.* = .{
            .home_dir = home_dir,
            .workspace_root = workspace_root,
            .request = owned_request,
        };
        switch (source) {
            .v1 => |store| task.cache_writer = session_catalog_cache.Writer.init(store.*) catch |err| blk: {
                debug_trace.logf("core", "session catalog cache writer unavailable err={s}", .{@errorName(err)});
                break :blk null;
            },
        }
        task.thread = std.Thread.spawn(.{}, threadMain, .{task}) catch |err| {
            if (task.cache_writer) |*writer| writer.deinit();
            task.request.deinit();
            alloc.free(task.workspace_root);
            alloc.free(task.home_dir);
            alloc.destroy(task);
            return err;
        };
        self.task = task;
    }

    fn takeCompleted(self: *SessionPickerLoad) ?*Task {
        const task = self.task orelse return null;
        if (!task.done.load(.acquire)) return null;
        self.task = null;
        return task;
    }

    fn threadMain(task: *Task) void {
        defer task.done.store(true, .release);
        const started = io_mod.nanoTimestamp();
        var read_only = session_store.Store.initReadOnlyFromHome(
            std.heap.c_allocator,
            task.home_dir,
            task.workspace_root,
        ) catch |err| {
            task.failure = err;
            return;
        };
        defer read_only.deinit(std.heap.c_allocator);

        task.catalog = session_catalog_cache.listActionableCatalog(
            read_only,
            std.heap.c_allocator,
            task.request.active_id,
            &task.cancel_requested,
            if (task.cache_writer) |*writer| writer else null,
        ) catch |err| {
            debug_trace.logf("core", "session picker catalog stopped err={s} elapsed_us={d}", .{ @errorName(err), @divTrunc(io_mod.nanoTimestamp() - started, std.time.ns_per_us) });
            task.failure = err;
            return;
        };
        debug_trace.logf("core", "session picker catalog loaded sessions={d} elapsed_us={d}", .{ task.catalog.?.summaries.items.len, @divTrunc(io_mod.nanoTimestamp() - started, std.time.ns_per_us) });
    }
};

const TitleGenerationLoad = struct {
    task: ?*session_title_generation.Task = null,
    last: LastResult = .{},

    /// Final state of the most recent attempt, retained for diagnostics after
    /// the task itself is destroyed. `detail` is a static string borrowed from
    /// the task; the model and session id are copied into fixed buffers.
    const LastResult = struct {
        status: Status = .none,
        reason: ?session_title_generation.FailureReason = null,
        detail: []const u8 = "",
        elapsed_ms: i64 = -1,
        model_buf: [max_model_bytes]u8 = undefined,
        model_len: u8 = 0,
        session_buf: [max_session_bytes]u8 = undefined,
        session_len: u8 = 0,

        const max_model_bytes = 128;
        const max_session_bytes = 64;

        pub fn model(self: *const LastResult) []const u8 {
            return self.model_buf[0..self.model_len];
        }

        pub fn sessionId(self: *const LastResult) []const u8 {
            return self.session_buf[0..self.session_len];
        }

        fn copyIds(self: *LastResult, session_id: []const u8, title_model: []const u8) void {
            const model_len: u8 = @intCast(@min(title_model.len, max_model_bytes));
            @memcpy(self.model_buf[0..model_len], title_model[0..model_len]);
            self.model_len = model_len;
            const session_len: u8 = @intCast(@min(session_id.len, max_session_bytes));
            @memcpy(self.session_buf[0..session_len], session_id[0..session_len]);
            self.session_len = session_len;
        }
    };

    const Status = enum { none, installed, dropped, failed };

    fn deinit(self: *TitleGenerationLoad) void {
        if (self.task) |task| {
            debug_trace.logf("session", "event=title_generation_dropped reason=deinit", .{});
            task.destroy();
        }
        self.* = .{};
    }

    fn requestStop(self: *TitleGenerationLoad) void {
        if (self.task) |task| task.cancel();
    }

    fn start(self: *TitleGenerationLoad, task: *session_title_generation.Task) void {
        if (self.task) |old| {
            debug_trace.logf("session", "event=title_generation_dropped reason=superseded session={s}", .{old.session_id});
            old.destroy();
        }
        self.task = task;
    }

    fn recordSpawnFailure(self: *TitleGenerationLoad, session_id: []const u8, model: []const u8, err: anyerror) void {
        var last = LastResult{
            .status = .failed,
            .reason = .spawn_failed,
            .detail = @errorName(err),
            .elapsed_ms = 0,
        };
        last.copyIds(session_id, model);
        self.last = last;
    }

    /// Snapshots a finished task's outcome before the caller destroys it.
    fn recordFinished(self: *TitleGenerationLoad, task: *session_title_generation.Task) void {
        var last = LastResult{
            .status = switch (task.status) {
                .generated => .installed,
                .pending, .unavailable => .failed,
            },
            .elapsed_ms = if (task.started_at_ms > 0 and task.finished_at_ms >= task.started_at_ms)
                task.finished_at_ms - task.started_at_ms
            else
                -1,
        };
        if (task.status == .unavailable) {
            last.reason = task.failure_reason;
            last.detail = task.failure_detail;
        }
        last.copyIds(task.session_id, task.model);
        self.last = last;
    }

    /// Marks that a generated title was dropped while being applied.
    fn recordDropped(self: *TitleGenerationLoad, reason: session_title_generation.FailureReason, detail: []const u8) void {
        if (self.last.status != .installed) return;
        self.last.status = .dropped;
        self.last.reason = reason;
        self.last.detail = detail;
    }

    fn takeCompleted(self: *TitleGenerationLoad) ?*session_title_generation.Task {
        const task = self.task orelse return null;
        if (!task.isDone()) return null;
        self.task = null;
        return task;
    }
};

fn resumePageLimitForRows(rows: u16) usize {
    // Fill the resume screen: terminal rows minus the composer/divider/hint
    // chrome (4), the menu header (1), the top gap (1), and a trailing
    // "Load more" row (1). Floored so short terminals still page usefully.
    return @max(@as(usize, rows -| 7), session_store.default_resume_page_limit);
}

const PendingCancelledCommand = struct {
    lifecycle_id: types.ToolLifecycleId,
    command_artifact_handle: ?[]u8 = null,

    fn matches(self: PendingCancelledCommand, id: types.ToolLifecycleId) bool {
        return self.lifecycle_id.turn_id == id.turn_id and
            std.mem.eql(u8, self.lifecycle_id.call_id, id.call_id);
    }

    fn discard(self: *PendingCancelledCommand, alloc: Allocator) void {
        alloc.free(@constCast(self.lifecycle_id.call_id));
        if (self.command_artifact_handle) |handle| alloc.free(handle);
        self.* = undefined;
    }
};

pub const Persistence = struct {
    // Serializes event-log mutations with worker usage callbacks. Usage takes
    // its checkpoint mutex first, so callers must not checkpoint while held.
    // UI compaction publication takes worker_mutex before this mutex.
    write_mutex: std.Io.Mutex = .init,
    store: ?session_store.Store = null,
    writable: ?session_store.LoadedWritableSession = null,
    remember_fresh_session: bool = false,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    workspace_preferences: ?session_codec.DurableSessionPreferences = null,
    session_preferences: ?session_codec.DurableSessionPreferences = null,
    fast_mode_model_bound: bool = false,
    process_provider_override: ?model_provider.ProviderId = null,
    process_model_override: ?[]u8 = null,
    process_effort_override: ?types.ReasoningEffort = null,
    process_fast_override: ?bool = null,
    process_ultrafast_override: ?bool = null,
    session_picker: SessionPicker = .{},
    session_picker_load: SessionPickerLoad = .{},
    session_picker_cache: SessionPickerCatalogCache = .{},
    title_generation: TitleGenerationLoad = .{},
    degraded_warning_emitted: bool = false,
    pending_cancelled_command: ?PendingCancelledCommand = null,
    image_snapshot_temp_dir: ?[]u8 = null,
    resume_handoff_intent: ResumeHandoffIntent = .none,
    pending_live_session_policy: ?BackgroundSessionPolicy = null,
    pending_live_session_wait: ?LiveSessionWait = null,
    shutdown_failure: ?anyerror = null,

    /// Fieldwise initialization avoids retaining undefined optional payloads
    /// in a static release-binary template.
    pub fn initInto(storage: *Persistence) void {
        comptime {
            if (@typeInfo(Persistence).@"struct".field_names.len != 24) {
                @compileError("update Persistence.initInto for the changed field set");
            }
        }
        storage.* = undefined;
        storage.write_mutex = .init;
        storage.store = null;
        storage.writable = null;
        storage.remember_fresh_session = false;
        storage.subagent_host = null;
        storage.workspace_preferences = null;
        storage.session_preferences = null;
        storage.fast_mode_model_bound = false;
        storage.process_provider_override = null;
        storage.process_model_override = null;
        storage.process_effort_override = null;
        storage.process_fast_override = null;
        storage.process_ultrafast_override = null;
        storage.session_picker = .{};
        storage.session_picker_load = .{};
        storage.session_picker_cache = .{};
        storage.title_generation = .{};
        storage.degraded_warning_emitted = false;
        storage.pending_cancelled_command = null;
        storage.image_snapshot_temp_dir = null;
        storage.resume_handoff_intent = .none;
        storage.pending_live_session_policy = null;
        storage.pending_live_session_wait = null;
        storage.shutdown_failure = null;
    }

    pub fn deinit(self: *Persistence, alloc: Allocator) void {
        self.deinitWithCatalog(alloc, .free);
    }

    /// Process exit leaves the session picker catalog to the exiting process;
    /// freeing thousands of cached sessions one by one only delays exit.
    pub fn deinitForProcessExit(self: *Persistence, alloc: Allocator) void {
        self.deinitWithCatalog(alloc, .abandon);
    }

    fn deinitWithCatalog(self: *Persistence, alloc: Allocator, catalog: enum { free, abandon }) void {
        if (self.pending_live_session_policy) |policy| {
            debug_trace.logf(
                "session",
                "event=live_session_transition_discard reason=deinit policy={s}",
                .{@tagName(policy)},
            );
        }
        if (self.pending_cancelled_command) |*pending| pending.discard(alloc);
        if (self.image_snapshot_temp_dir) |path| {
            image_attachments.cleanupSnapshotDir(path);
            alloc.free(path);
        }
        if (self.subagent_host) |host| host.deinit();
        if (self.writable) |*loaded| loaded.deinit(alloc);
        if (self.store) |*store| store.deinit(alloc);
        if (self.workspace_preferences) |*preferences| preferences.deinit(alloc);
        if (self.session_preferences) |*preferences| preferences.deinit(alloc);
        if (self.process_model_override) |model| alloc.free(model);
        self.session_picker.deinit(alloc);
        self.session_picker_load.deinit();
        if (catalog == .free) self.session_picker_cache.deinit();
        self.title_generation.deinit();
        self.* = undefined;
    }
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn captureImageAttachment(
            app: *App,
            attachment: *types.ImageAttachment,
        ) !void {
            const snapshot_dir = try imageSnapshotStorageDir(app);
            defer app.alloc.free(snapshot_dir);
            try image_attachments.captureImageSnapshot(
                app.alloc,
                attachment,
                snapshot_dir,
            );
        }

        fn imageSnapshotStorageDir(app: *App) ![]u8 {
            const sessions_dir = if (app.session_persistence.store) |*store|
                store.sessions_dir
            else
                null;
            const session_id = activeSessionId(app);
            return session_store.imageSnapshotStorageDir(
                app.alloc,
                sessions_dir,
                session_id,
                &app.session_persistence.image_snapshot_temp_dir,
            );
        }

        pub fn configureStartupPreferences(
            app: *App,
            provider: model_provider.ProviderId,
            configured_model: []const u8,
            model_source: config_runtime.ModelSource,
            selected_model: []const u8,
            effort: types.ReasoningEffort,
            fast_mode: bool,
            fast_mode_model_bound: bool,
            configured_ultrafast_mode: bool,
            ultrafast_process_override: ?bool,
            effort_process_override: ?types.ReasoningEffort,
            fast_process_override: ?bool,
            provider_process_override: ?model_provider.ProviderId,
        ) !void {
            try replacePreferences(
                app.alloc,
                &app.session_persistence.workspace_preferences,
                .{
                    .provider = provider,
                    .model = @constCast(configured_model),
                    .effort = effort,
                    .fast_mode = fast_mode,
                    .ultrafast_mode = configured_ultrafast_mode,
                },
            );
            try replacePreferences(
                app.alloc,
                &app.session_persistence.session_preferences,
                app.session_persistence.workspace_preferences.?,
            );
            app.session_persistence.fast_mode_model_bound = fast_mode_model_bound;
            if (app.session_persistence.process_model_override) |model| {
                app.alloc.free(model);
                app.session_persistence.process_model_override = null;
            }
            if (model_source == .process_override) {
                app.session_persistence.process_model_override =
                    try app.alloc.dupe(u8, selected_model);
            }
            app.session_persistence.process_effort_override = effort_process_override;
            app.session_persistence.process_fast_override = fast_process_override;
            app.session_persistence.process_ultrafast_override = ultrafast_process_override;
            app.session_persistence.process_provider_override = provider_process_override;
            // A provider override must pin the resolved model too, or a resume
            // would restore the session's model from a different provider.
            if (provider_process_override != null and
                app.session_persistence.process_model_override == null)
            {
                app.session_persistence.process_model_override =
                    try app.alloc.dupe(u8, selected_model);
            }
        }

        pub fn initializePersistence(
            app: *App,
            required: bool,
        ) !void {
            var store = session_store.Store.init(
                app.alloc,
                app.workspace_root,
            ) catch |err| {
                if (required) return err;
                return;
            };
            errdefer store.deinit(app.alloc);

            app.session_persistence.store = store;
        }

        pub fn enableSessionStores(app: *App) void {
            const loaded = if (app.session_persistence.writable) |*value| value else return;
            const capability = loaded.childCapability() catch |err| {
                debug_trace.logf(
                    "session",
                    "interactive child capability unavailable session={s} err={s}",
                    .{ loaded.active_id, @errorName(err) },
                );
                return;
            };

            configureWebFetchArtifacts(app, loaded);
            enableSubagentHost(app, loaded);
            if (comptime @hasField(App, "legacy_process_provider")) {
                const migrated = legacy_background_migration.migrate(
                    app.alloc,
                    capability,
                    app.legacy_process_provider,
                ) catch |err| {
                    debug_trace.logf(
                        "session",
                        "legacy process migration deferred session={s} err={s}",
                        .{ loaded.active_id, @errorName(err) },
                    );
                    return;
                };
                if (migrated.records_removed != 0 or migrated.logs_removed != 0) {
                    debug_trace.logf(
                        "session",
                        "legacy process migration committed session={s} records={d} logs={d} signaled={d} unavailable={d}",
                        .{
                            loaded.active_id,
                            migrated.records_removed,
                            migrated.logs_removed,
                            migrated.processes_signaled,
                            migrated.identities_unavailable,
                        },
                    );
                }
            }
        }

        pub fn beginFreshPersistedSession(app: *App) !void {
            closeWritableSession(app);
            const store = app.session_persistence.store orelse return;
            const preferences = app.session_persistence.workspace_preferences orelse
                return error.SessionPreferencesUnavailable;
            try replacePreferences(
                app.alloc,
                &app.session_persistence.session_preferences,
                preferences,
            );

            var state = try freshState(app, preferences);
            defer state.deinit(app.alloc);
            app.session_persistence.writable = store.startWritableSession(
                app.alloc,
                state,
            ) catch |err| {
                try warnNonDurable(app, "session creation failed", err);
                return;
            };
            app.session_persistence.remember_fresh_session = true;
            app.session_persistence.degraded_warning_emitted = false;
            app.total_input_tokens = 0;
            app.total_output_tokens = 0;
            app.total_web_search_requests = 0;
        }

        pub fn clearSession(app: *App) !void {
            try resetSessionWithBackgroundPolicy(app, .carry_forward);
        }

        pub fn newSession(app: *App) !void {
            try resetSessionWithBackgroundPolicy(app, .carry_forward);
        }

        pub fn resetSession(app: *App) !void {
            try resetSessionWithBackgroundPolicy(app, .stop_forget);
        }

        fn resetSessionWithBackgroundPolicy(
            app: *App,
            background_policy: BackgroundSessionPolicy,
        ) !void {
            if (comptime @hasDecl(@TypeOf(app.worker), "holdSessionTransition")) {
                app.worker.holdSessionTransition();
            }
            errdefer {
                app.session_persistence.pending_live_session_wait = null;
                releaseLiveSessionTransitionHold(app);
            }
            const previous_policy = app.session_persistence.pending_live_session_policy;
            const processing = app.worker.isProcessing();
            const decision = decideLiveSessionTransition(
                processing,
                previous_policy,
                .{ .request = background_policy },
            );
            if (previous_policy == null) {
                const now = monotonicMillis(io_mod.getIo());
                app.session_persistence.pending_live_session_wait = if (processing) .{ .worker = now } else .{ .geometry = now };
            }
            if (previous_policy) |previous| {
                if (decision.pending_policy) |next| {
                    if (previous != next) {
                        debug_trace.logf(
                            "session",
                            "event=live_session_transition_coalesced previous={s} next={s}",
                            .{ @tagName(previous), @tagName(next) },
                        );
                    }
                }
            }
            app.session_persistence.pending_live_session_policy = decision.pending_policy;
            switch (decision.action) {
                .apply_now => |policy| {
                    if (!freshSessionResizeReady(app)) {
                        app.session_persistence.pending_live_session_policy = policy;
                        if (processing) app.worker.requestCancel();
                        debug_trace.logf("session", "event=live_session_transition_deferred reason=resize_pending", .{});
                        return;
                    }
                    applyLiveSessionTransition(app, policy) catch |err| {
                        if (handleScrollbackHandoffError(app, policy, err)) return;
                        return err;
                    };
                },
                .none => if (decision.pending_policy == null) {
                    app.session_persistence.pending_live_session_wait = null;
                    releaseLiveSessionTransitionHold(app);
                },
                .apply_pending => unreachable,
            }
        }

        fn freshSessionResizeReady(app: *App) bool {
            if (comptime @hasField(@TypeOf(app.shell), "has_committed_frame")) {
                if (!app.shell.has_committed_frame) return true;
            }
            if (comptime @hasDecl(App, "admitPendingResizeSignal")) {
                _ = app.admitPendingResizeSignal("session_handoff");
            }
            if (!shell_runtime.resizeLifecycleIdle(&app.shell)) return false;
            if (comptime @hasField(App, "terminal")) {
                const actual = app.terminal.queryLayout(app.shell.layout.rows -| app.shell.layout.content_bottom) catch return false;
                if (actual.cols != app.shell.layout.cols or actual.rows != app.shell.layout.rows) return false;
            }
            return true;
        }

        fn handleScrollbackHandoffError(app: *App, policy: BackgroundSessionPolicy, err: anyerror) bool {
            switch (err) {
                error.SessionScrollbackHandoffUnavailable,
                error.SessionScrollbackHandoffIncomplete,
                => {
                    app.session_persistence.pending_live_session_policy = policy;
                    debug_trace.logf("session", "event=live_session_transition_deferred reason=scrollback_handoff err={s}", .{@errorName(err)});
                    return true;
                },
                error.SessionScrollbackHandoffGeometryChanged => {
                    app.session_persistence.pending_live_session_policy = null;
                    app.session_persistence.pending_live_session_wait = null;
                    app.shell.cancelSessionScrollbackHandoff();
                    releaseLiveSessionTransitionHold(app);
                    debug_trace.logf("session", "event=live_session_transition_cancelled reason=scrollback_handoff_geometry_changed", .{});
                    if (comptime @hasDecl(App, "writeDomainNotice")) {
                        app.writeDomainNotice(.{
                            .topic = "session",
                            .tone = .warning,
                            .body = "Session change cancelled after a terminal resize. The old session was kept; an active turn may have been cancelled. Retry the command.",
                        }, true) catch |notice_err| {
                            debug_trace.logf("session", "event=transition_cancel_notice_dropped err={s}", .{@errorName(notice_err)});
                        };
                    }
                    return true;
                },
                else => return false,
            }
        }

        pub fn cancelPendingLiveSessionForInputLimit(app: *App) !void {
            try cancelPendingLiveSessionForInput(app, "deferred_input_limit", "Session change cancelled because input arrived faster than it could finish. Your input is still being delivered to the old session; retry the command.");
        }

        pub fn cancelPendingLiveSessionForTimeout(app: *App) !void {
            try cancelPendingLiveSessionForInput(app, "resize_timeout", "Session change cancelled because the terminal resize did not settle. Continuing in the old session; retry the command.");
        }

        fn cancelPendingLiveSessionForWorkerTimeout(app: *App) !void {
            try cancelPendingLiveSessionForInput(app, "worker_timeout", "Session change cancelled because the active turn did not stop. Continuing in the old session; retry the command.");
        }

        fn cancelPendingLiveSessionForInput(app: *App, reason: []const u8, notice: []const u8) !void {
            if (app.session_persistence.pending_live_session_policy == null) return;
            app.session_persistence.pending_live_session_policy = null;
            app.session_persistence.pending_live_session_wait = null;
            app.shell.cancelSessionScrollbackHandoff();
            releaseLiveSessionTransitionHold(app);
            debug_trace.logf("session", "event=live_session_transition_cancelled reason={s}", .{reason});
            try app.writeDomainNotice(.{ .topic = "session", .tone = .warning, .body = notice }, true);
        }

        pub fn settlePendingLiveSessionTransition(app: *App) !void {
            if (app.session_persistence.pending_live_session_policy == null) return;
            const processing = app.worker.isProcessing();
            const now = monotonicMillis(io_mod.getIo());
            var wait = app.session_persistence.pending_live_session_wait orelse if (processing) LiveSessionWait{ .worker = now } else LiveSessionWait{ .geometry = now };
            if (wait == .worker and !processing) wait = .{ .geometry = now };
            app.session_persistence.pending_live_session_wait = wait;
            if (liveSessionWaitTimeout(wait, processing, now)) |timeout| {
                switch (timeout) {
                    .worker => try cancelPendingLiveSessionForWorkerTimeout(app),
                    .geometry => try cancelPendingLiveSessionForTimeout(app),
                }
                return;
            }
            errdefer {
                app.session_persistence.pending_live_session_wait = null;
                releaseLiveSessionTransitionHold(app);
            }
            const decision = decideLiveSessionTransition(
                processing,
                app.session_persistence.pending_live_session_policy,
                .settle,
            );
            app.session_persistence.pending_live_session_policy = decision.pending_policy;
            switch (decision.action) {
                .apply_pending => |policy| {
                    if (comptime @hasDecl(@TypeOf(app.shell), "sessionScrollbackHandoffPending")) {
                        if (app.shell.sessionScrollbackHandoffPending()) {
                            if (comptime @hasDecl(App, "admitPendingResizeSignal")) {
                                _ = app.admitPendingResizeSignal("session_handoff");
                            }
                            if (!shell_runtime.resizeLifecycleIdle(&app.shell)) {
                                _ = handleScrollbackHandoffError(app, policy, error.SessionScrollbackHandoffGeometryChanged);
                                return;
                            }
                        }
                    }
                    applyIdleLiveSessionTransition(app, policy, true) catch |err| {
                        if (handleScrollbackHandoffError(app, policy, err)) return;
                        return err;
                    };
                    try installFreshLiveSession(app);
                },
                .none => {},
                .apply_now => unreachable,
            }
        }

        fn applyLiveSessionTransition(
            app: *App,
            background_policy: BackgroundSessionPolicy,
        ) !void {
            try prepareLiveSessionTransition(app, background_policy, true);
            try installFreshLiveSession(app);
        }

        fn installFreshLiveSession(app: *App) !void {
            defer {
                app.session_persistence.pending_live_session_wait = null;
                releaseLiveSessionTransitionHold(app);
            }
            try beginFreshPersistedSession(app);
            enableSessionStores(app);
            try finishLiveSessionTransition(app);
        }

        fn releaseLiveSessionTransitionHold(app: *App) void {
            if (comptime @hasField(App, "terminal_input_runtime")) {
                if (comptime @hasDecl(@TypeOf(app.terminal_input_runtime), "hasDeferredSessionInput") and
                    @hasDecl(@TypeOf(app.terminal_input_runtime), "allowCurrentDeferredSessionInputForReplay"))
                {
                    if (app.terminal_input_runtime.hasDeferredSessionInput()) {
                        app.terminal_input_runtime.allowCurrentDeferredSessionInputForReplay();
                        return;
                    }
                }
            }
            if (comptime @hasDecl(@TypeOf(app.worker), "releaseSessionTransitionHold")) {
                app.worker.releaseSessionTransitionHold();
            }
        }

        pub fn finishDeferredSessionInputReplay(app: *App) void {
            if (app.session_persistence.pending_live_session_policy != null) return;
            releaseLiveSessionTransitionHold(app);
        }

        pub fn prepareLiveSessionResume(app: *App) !void {
            try prepareLiveSessionTransition(app, .stop_forget, false);
        }

        pub fn finishLiveSessionResume(app: *App) !void {
            try app.shell.requestTerminalReset(&app.metrics);
            app.shell.render_requests.request(.footer);
        }

        fn prepareLiveSessionTransition(
            app: *App,
            background_policy: BackgroundSessionPolicy,
            preserve_scrollback: bool,
        ) !void {
            if (preserve_scrollback) {
                app.worker.requestCancel();
            } else {
                beginLiveSessionCancellation(app);
            }
            app.worker.waitUntilIdle();
            try applyIdleLiveSessionTransition(app, background_policy, preserve_scrollback);
        }

        fn beginLiveSessionCancellation(app: *App) void {
            app.worker.requestCancel();
            app.pacer.clear(app.alloc);
            if (comptime @hasDecl(App, "clearPendingSubmissionForSessionTransition")) {
                App.clearPendingSubmissionForSessionTransition(app);
            } else {
                if (comptime @hasDecl(App, "clearPendingSubmission")) {
                    App.clearPendingSubmission(app, "session_transition");
                }
                app.worker.clearQueuedPrompts(std.heap.c_allocator, &.{});
            }
        }

        fn retireLiveSessionCompaction(app: *App) void {
            // Called after the worker is idle, before installing the next session.
            const observed = app.worker.compactionActivitySnapshot();
            if (observed.operation) |op| {
                _ = app.worker.dismissCompactionActivity(op.id, observed.revision);
            }
        }

        fn applyIdleLiveSessionTransition(
            app: *App,
            background_policy: BackgroundSessionPolicy,
            preserve_scrollback: bool,
        ) !void {
            if (preserve_scrollback) {
                if (comptime @hasField(App, "terminal")) {
                    if (comptime @hasField(@TypeOf(app.terminal), "alternate_screen_owner")) {
                        if (app.terminal.alternate_screen_owner != .none) return error.SessionScrollbackHandoffUnavailable;
                    }
                }
                if (!freshSessionResizeReady(app)) return error.SessionScrollbackHandoffUnavailable;
                try app.shell.commitVisibleTranscriptBeforeFreshSession(app.alloc, &app.metrics);
                beginLiveSessionCancellation(app);
            }
            retireLiveSessionCompaction(app);
            clearCachedSessionTitle(app);
            app.worker.discardEvents(std.heap.c_allocator);

            if (comptime @hasField(App, "subagents") and
                @hasDecl(@TypeOf(app.subagents), "clearProjection"))
            {
                app.subagents.clearProjection(app.alloc);
            }

            closeWritableSession(app);
            app.stopStream();
            app.shell.clearTranscript(app.alloc);
            app.session.reset(app.alloc);
            app.input_runtime.inputResetState().resetForSession(app.alloc);
            app.terminal_input_runtime.resetEscapeDecoder();
            app.permission_engine.clear(app.alloc);
            app.clearPendingImages();
            app.change_tracker.clear(std.heap.c_allocator);
            diagnostics.resetSession();
            _ = background_policy;
            app.context_snapshot.deinit(app.alloc);
            app.approval_prompt.clear(app.alloc);
            if (comptime @hasField(App, "approval_screen")) {
                app.approval_screen.clear();
            }
            app.question_prompt.discard(app.alloc, "session_reset");
            cancelSessionPicker(app);
            invalidateSessionPickerCaches(app);
        }

        fn finishLiveSessionTransition(app: *App) !void {
            const welcome = try ui_render.welcomeMessage(app.alloc);
            defer app.alloc.free(welcome);
            try app.writeTranscriptClassified(welcome, true, .welcome);
            app.shell.render_requests.request(.footer);
            try shell_runtime.requestRedraw(&app.shell, &app.metrics, .replay_viewport);
        }

        pub fn resumeRequestedSession(app: *App) !void {
            return resumeRequestedSessionWithNotice(app, .session);
        }

        pub fn resumeRequestedSessionAfterUpgrade(
            app: *App,
            version: []const u8,
            channel: update_target.Channel,
            previous_revision: []const u8,
            revision: []const u8,
        ) !void {
            return resumeRequestedSessionWithNotice(app, .{ .upgrade = .{
                .version = version,
                .channel = channel,
                .previous_revision = previous_revision,
                .revision = revision,
            } });
        }

        fn resumeRequestedSessionWithNotice(
            app: *App,
            notice: ResumeNotice,
        ) !void {
            var target = app.requested_resume orelse return;
            app.requested_resume = null;
            defer target.deinit(app.alloc);

            var remembered: ?[]u8 = null;
            defer if (remembered) |id| app.alloc.free(id);
            const resume_target: session_store.ResumeTarget = switch (target) {
                // Nothing to load yet: the picker asks which session to open.
                .pick => return openSessionPicker(app),
                .last => .last,
                .remembered => blk: {
                    const store = app.session_persistence.store orelse return error.SessionStoreUnavailable;
                    remembered = store.readRememberedSessionId(app.alloc) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => return error.RememberedSessionUnavailable,
                    };
                    break :blk .{ .id = remembered orelse return error.NoRememberedSession };
                },
                .id => |session_id| .{ .id = session_id },
            };
            var loaded = try loadResumeTargetForWrite(app, resume_target, .{});
            var loaded_owned = true;
            errdefer if (loaded_owned) loaded.deinit(app.alloc);

            loaded_owned = false;
            try installResumedSession(app, &loaded, notice);
            errdefer closeWritableSession(app);
            try app.commitStartupResumeReplayAnchor();
            if (target != .remembered and notice == .session) rememberSelectedSession(app);
        }

        pub fn startResumedSessionReconciliation(app: *App) void {
            if (comptime @hasDecl(App, "startModelCacheWarmup")) app.startModelCacheWarmup();
            if (comptime !@hasField(App, "auth") or !provider_runtime.supported(App)) return;
            if (comptime !@hasDecl(@TypeOf(app.auth), "credentialSource") or
                !@hasDecl(@TypeOf(app.auth), "accountId") or
                !@hasDecl(@TypeOf(app.session.usage), "replaceProviderReconciliationCredential")) return;

            const source = app.auth.credentialSource() orelse return;
            if (!model_provider.authorizesCredential(provider_runtime.provider(app), source)) return;
            const credential = app.auth.apiKey() orelse return;
            app.session.usage.replaceProviderReconciliationCredential(
                app.alloc,
                provider_runtime.provider(app),
                source,
                app.auth.accountId(),
                credential,
            );
        }

        pub fn resumeSelectedSession(app: *App) !bool {
            const selected_id = app.session_persistence.session_picker.selectedId() orelse return false;
            const log_options = session_log.Options{
                .session_lock_deadline_ms = 0,
            };
            var loaded = try loadResumeTargetForWrite(
                app,
                .{ .id = selected_id },
                log_options,
            );
            var loaded_owned = true;
            errdefer if (loaded_owned) loaded.deinit(app.alloc);

            try app.prepareLiveSessionResume();
            loaded_owned = false;
            try installResumedSession(app, &loaded, .session);
            startResumedSessionReconciliation(app);
            try app.finishLiveSessionResume();
            rememberSelectedSession(app);
            return true;
        }

        fn loadResumeTargetForWrite(
            app: *App,
            target: session_store.ResumeTarget,
            log_options: session_log.Options,
        ) !session_store.LoadedWritableSession {
            const store = app.session_persistence.store orelse
                return session_log.failLoadedWritableSession(error.SessionStoreUnavailable);
            return subagent_resume_admission.resumeForExternalPrompt(
                store,
                app.alloc,
                target,
                app.workspace_root,
                .{
                    .seed_preferences = app.session_persistence.workspace_preferences,
                    .log = log_options,
                },
            );
        }

        fn installResumedSession(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
            notice: ResumeNotice,
        ) !void {
            var loaded_owned = true;
            errdefer if (loaded_owned) loaded.deinit(app.alloc);

            var display = try readNativeResumeDisplay(app, loaded);
            defer display.deinit(app.alloc);

            closeWritableSession(app);
            app.session_persistence.writable = loaded.*;
            loaded_owned = false;
            loaded.* = undefined;
            errdefer {
                app.session_persistence.writable.?.deinit(app.alloc);
                app.session_persistence.writable = null;
            }
            const active = &app.session_persistence.writable.?;
            try hydrateResumedSession(app, active.state, &display, notice);
            active.releaseHydrationHistory(app.alloc);
            enableSessionStores(app);
        }

        /// Record whether restored history references shell execution handles
        /// this process does not own. Registry membership, not the resume
        /// itself, decides staleness (see session_runtime.detectStaleShellHandles).
        fn updateStaleShellHandles(app: *App, history: []const session_runtime.HistoryTurn) void {
            if (comptime !@hasField(App, "managed_executions")) return;
            app.session.has_stale_shell_handles = session_runtime.detectStaleShellHandles(
                app.alloc,
                history,
                &app.managed_executions,
            ) catch |err| blk: {
                debug_trace.logf(
                    "session",
                    "event=stale_shell_handle_scan outcome=skipped err={s}",
                    .{@errorName(err)},
                );
                break :blk false;
            };
        }

        fn hydrateResumedSession(
            app: *App,
            loaded_state: session_codec.DurableSessionState,
            display: *const session_display_metadata.DisplayMetadata,
            notice: ResumeNotice,
        ) !void {
            var state = loaded_state;
            const previous_provider = provider_runtime.provider(app);
            if (comptime @hasField(App, "next_image_id")) {
                app.next_image_id = try nextImageIdForResume(
                    app.alloc,
                    state.history,
                    state.recovery_checkpoint,
                );
            }
            try app.session.restoreWithPermissionState(
                app.alloc,
                state.conversation_language,
                state.history,
                state.permission_state,
            );
            updateStaleShellHandles(app, state.history);
            if (state.usage) |usage| {
                try app.session.usage.restore(
                    app.alloc,
                    usage,
                    state.created_at_ms,
                );
            } else {
                app.session.usage.restoreLegacyWallDuration(state.created_at_ms);
            }
            try replacePreferences(
                app.alloc,
                &app.session_persistence.session_preferences,
                state.preferences,
            );
            try restoreRuntimePreferences(app, state.preferences);
            normalizeRecoveryUltrafastForProcessOverride(app, &state);

            app.total_input_tokens = state.total_input_tokens;
            app.total_output_tokens = state.total_output_tokens;
            app.total_web_search_requests = 0;

            var historical_labels = HistoricalSessionLabels{ .workspace_root = app.workspace_root };
            defer historical_labels.deinit(app.alloc);

            // Decide before rendering: the checkpoint replay below must not
            // promise an automatic continuation the gate is about to suppress.
            const recovery_decision: ?RecoveryAutoContinue = if (comptime @hasDecl(App, "queueRecoveryCheckpoint"))
                if (state.recovery_checkpoint) |checkpoint|
                    recoveryAutoContinueDecision(checkpoint, previousOwnerDied(app), recoveryAskedBefore(app))
                else
                    null
            else
                null;

            if (comptime @hasDecl(App, "beginResumeProjection")) {
                const projection_started_ns = io_mod.nanoTimestamp();
                var projection = try app.beginResumeProjection();
                defer projection.deinit();
                var sink = DetachedHistorySink(@TypeOf(projection)){
                    .app = app,
                    .projection = &projection,
                    .labels = &historical_labels,
                };
                try writeResumeNotice(app, &sink, display, notice);
                try replayResumedHistoryToSink(app, &sink, state.history, &historical_labels);
                try writeRecoveryCheckpointToSink(app, &sink, state, &historical_labels, recovery_decision);
                const projection_finished_ns = io_mod.nanoTimestamp();
                try projection.finalize();
                const finalization_finished_ns = io_mod.nanoTimestamp();
                try app.installResumeProjection(&projection);
                const install_finished_ns = io_mod.nanoTimestamp();
                debug_trace.logf(
                    "session",
                    "event=resume_projection turns={d} project_us={d} finalize_us={d} install_us={d}",
                    .{
                        state.history.len,
                        @divTrunc(projection_finished_ns - projection_started_ns, std.time.ns_per_us),
                        @divTrunc(finalization_finished_ns - projection_finished_ns, std.time.ns_per_us),
                        @divTrunc(install_finished_ns - finalization_finished_ns, std.time.ns_per_us),
                    },
                );
            } else {
                var sink = LiveHistorySink(App){ .app = app };
                try writeResumeNotice(app, &sink, display, notice);
                try replayResumedHistoryToSink(app, &sink, state.history, &historical_labels);
                try writeRecoveryCheckpointToSink(app, &sink, state, &historical_labels, recovery_decision);
            }
            if (comptime @hasDecl(App, "restoreSessionCredential")) {
                try app.restoreSessionCredential(previous_provider);
            }
            // A paused recovery resumes on its own after a clean restart or
            // resume. Harnesses without a real worker queue opt out via the
            // decl check. A compaction_prepared checkpoint records completed
            // source, not a turn waiting to run; the compaction flow owns it.
            // A checkpoint left behind by an unclean exit is different: the
            // interrupted turn may be what killed the process, so the user
            // decides whether to retry it instead of fx re-spending the turn
            // on its own, and that suppression stays sticky until the turn
            // is resolved.
            if (comptime @hasDecl(App, "queueRecoveryCheckpoint")) {
                if (state.recovery_checkpoint) |checkpoint| {
                    switch (recovery_decision.?) {
                        .skip_compaction_owned => debug_trace.logf(
                            "session",
                            "event=auto_continue_skipped cause=compaction_prepared",
                            .{},
                        ),
                        .ask_after_unclean_exit => {
                            debug_trace.logf(
                                "session",
                                "event=auto_continue_suppressed reason=unclean_exit turn_id={d}",
                                .{checkpoint.turn_id},
                            );
                            if (comptime @hasField(App, "session_persistence")) {
                                if (app.session_persistence.writable) |*loaded| {
                                    session_log.markRecoveryAsked(app.alloc, &loaded.log.dir);
                                }
                            }
                            try app.writeDomainNotice(.{
                                .topic = "recovery",
                                .tone = .warning,
                                .body = "fx quit unexpectedly while this response was recovering, so it was not restarted. Send \"continue\" to retry it, or a new message to move on.",
                            }, true);
                        },
                        .auto_continue => {
                            const queued = continuePausedRecovery(app) catch |err| switch (err) {
                                error.MissingApiKey => missing: {
                                    try app.writeDomainNotice(.{
                                        .topic = "recovery",
                                        .tone = .warning,
                                        .body = "sign in to let the interrupted response continue automatically",
                                    }, true);
                                    break :missing false;
                                },
                                else => other: {
                                    debug_trace.logf(
                                        "session",
                                        "event=auto_continue_failed err={s}",
                                        .{@errorName(err)},
                                    );
                                    try app.writeDomainNotice(.{
                                        .topic = "recovery",
                                        .tone = .warning,
                                        .body = "the interrupted response could not continue automatically; it will try again on the next resume",
                                    }, true);
                                    break :other false;
                                },
                            };
                            _ = queued;
                        },
                    }
                }
            }
        }

        fn previousOwnerDied(app: *App) bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            const loaded = if (app.session_persistence.writable) |*value| value else return false;
            return loaded.log.previous_owner_died;
        }

        fn recoveryAskedBefore(app: *App) bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            const loaded = if (app.session_persistence.writable) |*value| value else return false;
            return session_log.recoveryWasAsked(&loaded.log.dir);
        }

        /// The picker lists from the backend this process runs on.
        fn pickerSource(app: *App) ?SessionPickerLoad.Source {
            if (app.session_persistence.store) |*store| return .{ .v1 = store };
            return null;
        }

        /// The open session, which the picker leaves out.
        fn pickerActiveId(app: *App) ?[]const u8 {
            return if (app.session_persistence.writable) |*loaded| loaded.active_id else null;
        }

        pub fn openSessionPicker(app: *App) !void {
            return openSessionPickerWithScope(app, .current_workspace);
        }

        /// Warms the session catalog in the background right after interactive
        /// startup, so the first picker open can paint from memory instead of
        /// waiting for a scan. Runs only when a persisted catalog exists: a
        /// profile that has never listed sessions has nothing worth warming.
        /// A picker opened while the preload is in flight adopts that scan as
        /// its own; the completed scan lands in the in-memory catalog cache
        /// through the ordinary poll path.
        pub fn preloadSessionCatalog(app: *App) void {
            const persistence = &app.session_persistence;
            if (persistence.session_picker.active) return;
            const loader = &persistence.session_picker_load;
            if (loader.task != null or loader.pending != null) return;
            const store = if (persistence.store) |*value| value else return;
            if (!session_catalog_cache.catalogFileExists(store.canonical_root.sessions)) return;
            const active_id = if (persistence.writable) |*loaded| loaded.active_id else null;
            const cache = &persistence.session_picker_cache;
            if (cache.matches(active_id) and cache.isFresh()) return;
            const request = SessionPickerLoad.PageRequest.init(
                loader.allocateGeneration(),
                active_id,
            ) catch return;
            loader.schedule(.{ .v1 = store }, request) catch |err| {
                debug_trace.logf(
                    "core",
                    "session catalog preload unavailable err={s}",
                    .{@errorName(err)},
                );
            };
        }

        pub fn openAllSessionPicker(app: *App) !void {
            return openSessionPickerWithScope(app, .all_workspaces);
        }

        fn openSessionPickerWithScope(app: *App, scope: SessionPickerScope) !void {
            if (app.stream.active) {
                try app.writeDomainNotice(.{
                    .topic = "session",
                    .tone = .neutral,
                    .body = "resume is unavailable until the response finishes",
                }, true);
                return;
            }

            var picker = &app.session_persistence.session_picker;
            const previous_generation = picker.generation;
            picker.deinit(app.alloc);
            picker.active = true;
            picker.load_state = .loading;
            picker.scope = scope;
            picker.setQuery(app.input_runtime.edit_state.input.items);
            const source = pickerSource(app) orelse {
                picker.load_state = .failed;
                try writeSessionPickerError(app, error.SessionStoreUnavailable);
                app.shell.render_requests.request(.footer);
                return;
            };
            const active_id = pickerActiveId(app);
            const limit = if (comptime @hasField(App, "shell"))
                resumePageLimitForRows(app.shell.layout.rows)
            else
                session_store.default_resume_page_limit;
            const loader = &app.session_persistence.session_picker_load;
            const matching = loader.matchingInitialGeneration(active_id);
            if (matching != previous_generation) loader.cancelGeneration(previous_generation);
            const cache = &app.session_persistence.session_picker_cache;
            if (!cache.matches(active_id)) {
                installStaleDiskCatalog(source.v1, cache, active_id) catch |err| {
                    debug_trace.logf(
                        "core",
                        "session picker disk catalog unavailable err={s}",
                        .{@errorName(err)},
                    );
                };
            }
            var cache_visible = false;
            if (cache.matches(active_id)) {
                try applySessionPickerCatalogPage(
                    picker,
                    app.alloc,
                    cache,
                    source.workspaceRoot(),
                    null,
                    limit,
                    false,
                );
                cache_visible = true;
                if (cache.isFresh()) {
                    picker.generation = app.session_persistence.session_picker_load.allocateGeneration();
                    return;
                }
            }

            if (matching) |generation| {
                picker.generation = generation;
                return;
            }
            const request = SessionPickerLoad.PageRequest.init(
                loader.allocateGeneration(),
                active_id,
            ) catch |err| {
                if (!cache_visible) picker.load_state = .failed;
                try writeSessionPickerError(app, err);
                return;
            };
            picker.generation = request.generation;
            loader.schedule(source, request) catch |err| {
                if (!cache_visible) picker.load_state = .failed;
                try writeSessionPickerError(app, err);
                return;
            };
        }

        pub fn toggleSessionPickerScope(app: *App) !bool {
            const picker = &app.session_persistence.session_picker;
            if (!picker.active) return false;
            const next: SessionPickerScope = switch (picker.scope) {
                .current_workspace => .all_workspaces,
                .all_workspaces => .current_workspace,
            };
            try openSessionPickerWithScope(app, next);
            return true;
        }

        pub fn pollSessionPicker(app: *App) !void {
            const loader = &app.session_persistence.session_picker_load;
            const task = loader.takeCompleted() orelse return;
            var task_owned = true;
            defer if (task_owned) task.deinit();

            const active_id = pickerActiveId(app);
            const valid = pickerSource(app) != null and
                !task.abandoned and optionalStringEql(task.request.active_id, active_id);
            var cache_installed = false;
            if (valid and task.failure == null) {
                if (task.catalog) |*catalog| {
                    const cache = &app.session_persistence.session_picker_cache;
                    cache.install(catalog, task.request.active_id) catch |err| {
                        task.failure = err;
                    };
                    cache_installed = task.failure == null;
                }
            }

            const picker = &app.session_persistence.session_picker;
            const current = valid and picker.active and picker.generation == task.request.generation;
            if (!current) {
                debug_trace.logf(
                    "core",
                    "session picker completion {s} generation={d}",
                    .{
                        if (cache_installed) "cached" else "dropped",
                        task.request.generation,
                    },
                );
            } else if (task.failure) |err| {
                if (picker.load_state != .ready) picker.load_state = .failed;
                try writeSessionPickerError(app, err);
            } else {
                const cache = &app.session_persistence.session_picker_cache;
                const limit = if (comptime @hasField(App, "shell"))
                    resumePageLimitForRows(app.shell.layout.rows)
                else
                    session_store.default_resume_page_limit;
                applySessionPickerCatalogPage(
                    picker,
                    app.alloc,
                    cache,
                    pickerSource(app).?.workspaceRoot(),
                    null,
                    limit,
                    false,
                ) catch |err| {
                    picker.load_state = .failed;
                    try writeSessionPickerError(app, err);
                };
            }

            task.deinit();
            task_owned = false;

            const source = pickerSource(app) orelse return;
            const pending_generation = loader.pendingGeneration();
            _ = loader.startPending(source) catch |err| {
                if (pending_generation) |generation| {
                    if (picker.active and picker.generation == generation) {
                        if (picker.loading_more) {
                            picker.loading_more = false;
                        } else {
                            picker.load_state = .failed;
                        }
                        try writeSessionPickerError(app, err);
                    }
                }
                return;
            };
            if (comptime @hasField(App, "shell")) {
                if (picker.active) app.shell.render_requests.request(.footer);
            }
        }

        fn writeSessionPickerError(app: *App, err: anyerror) !void {
            const notice = try app.alloc.print(
                "unable to list saved sessions: {s}",
                .{@errorName(err)},
            );
            defer app.alloc.free(notice);
            try app.writeDomainNotice(.{
                .topic = "session",
                .tone = .@"error",
                .body = notice,
            }, true);
        }

        pub fn loadMoreSessionPicker(app: *App) !bool {
            const picker = &app.session_persistence.session_picker;
            if (!picker.isLoadMoreSelected()) return false;
            if (picker.loading_more) return true;
            try scheduleMoreSessions(app);
            return true;
        }

        fn scheduleMoreSessions(app: *App) !void {
            const picker = &app.session_persistence.session_picker;
            const continuation = picker.continuation orelse
                return error.SessionStoreUnavailable;
            const source = pickerSource(app) orelse return error.SessionStoreUnavailable;
            const active_id = pickerActiveId(app);
            const cache = &app.session_persistence.session_picker_cache;
            if (!cache.matches(active_id)) return error.SessionStoreUnavailable;
            const limit = if (comptime @hasField(App, "shell"))
                resumePageLimitForRows(app.shell.layout.rows)
            else
                session_store.default_resume_page_limit;

            picker.loading_more = true;
            applySessionPickerCatalogPage(
                picker,
                app.alloc,
                cache,
                source.workspaceRoot(),
                continuation.view(),
                limit,
                true,
            ) catch |err| {
                picker.loading_more = false;
                return err;
            };
            try input_completion_runtime.CompletionRuntime(App).syncSessionPickerWindowStart(app);
            if (comptime @hasField(App, "shell")) {
                app.shell.render_requests.request(.footer);
            }
        }

        // Prefetch the next page as the selection reaches the last loaded
        // session (or the load-more slot), so scrolling down fills the list in
        // without stopping to activate "Load more".
        fn maybePrefetchMoreSessions(app: *App) void {
            const picker = &app.session_persistence.session_picker;
            if (!picker.active or picker.load_state != .ready) return;
            if (!picker.has_more or picker.loading_more) return;
            if (picker.summaries.items.len == 0) return;
            if (picker.selected + 1 < picker.filteredItemCount()) return;
            scheduleMoreSessions(app) catch |err| {
                debug_trace.logf(
                    "core",
                    "session picker prefetch failed err={s}",
                    .{@errorName(err)},
                );
            };
        }

        pub fn cancelSessionPicker(app: *App) void {
            const picker = &app.session_persistence.session_picker;
            const loader = &app.session_persistence.session_picker_load;
            if (loader.task) |task| loader.cancelGeneration(task.request.generation);
            if (loader.pending) |pending| loader.cancelGeneration(pending.generation);
            picker.deinit(app.alloc);
        }

        pub fn cancelSessionPickerToComposer(app: *App) void {
            cancelSessionPicker(app);
            if (comptime !@hasField(App, "session")) return;
            if (app.session_persistence.writable != null) return;
            beginFreshPersistedSession(app) catch |err| {
                debug_trace.logf(
                    "session",
                    "fresh session after picker cancel unavailable err={s}",
                    .{@errorName(err)},
                );
                return;
            };
            enableSessionStores(app);
        }

        fn invalidateSessionPickerCaches(app: *App) void {
            const loader = &app.session_persistence.session_picker_load;
            if (loader.task) |task| loader.cancelGeneration(task.request.generation);
            if (loader.pending) |pending| loader.cancelGeneration(pending.generation);
            app.session_persistence.session_picker_cache.deinit();
        }

        pub fn moveSessionPicker(app: *App, delta: i32, visible_items: u16) bool {
            const moved = app.session_persistence.session_picker.moveVisibleItems(delta, visible_items);
            maybePrefetchMoreSessions(app);
            return moved;
        }

        pub fn recordToolTerminal(
            app: *App,
            event: types.ToolLifecycleEvent,
            captured_command_call: bool,
        ) void {
            const terminal = switch (event) {
                .terminal => |value| value,
                .provisional, .authoritative_started, .progress, .turn_finished => return,
            };
            if (!captured_command_call) {
                discardPendingCancelledCommand(app, terminal.id, "non_command_terminal");
                return;
            }
            if (terminal.outcome.kind != .cancelled) {
                discardPendingCancelledCommand(app, terminal.id, "ordinary_command_terminal");
                return;
            }
            const pending = ensurePendingCancelledCommand(app, terminal.id) orelse return;
            if (pending.command_artifact_handle) |handle| {
                app.alloc.free(handle);
                pending.command_artifact_handle = null;
            }
            if (terminal.command_artifact_handle) |handle| {
                pending.command_artifact_handle = app.alloc.dupe(u8, handle) catch |err| {
                    debug_trace.logf(
                        "session",
                        "cancelled command artifact capture unavailable call_id={s} err={s}",
                        .{ terminal.id.call_id, @errorName(err) },
                    );
                    return;
                };
            }
        }

        pub fn appendHistoryTurn(app: *App, turn: types.HistoryTurn) !void {
            _ = try appendHistoryTurnWithPendingPresentation(app, turn, .strict, null);
        }

        pub fn appendFinishedPrompt(
            app: *App,
            finished: types.FinishedPrompt,
        ) !void {
            var turn = finished.turn;
            if (finished.summary) |summary| {
                types.setHistoryTurnSummary(&turn, summary);
            }
            _ = try appendHistoryTurnWithPendingPresentation(
                app,
                turn,
                .finished_prompt,
                finished.snapshot_file_ownership,
            );
        }

        pub fn persistUsageCheckpoint(
            app: *App,
            snapshot: session_usage.Snapshot,
        ) !void {
            if (comptime !@hasField(App, "session_persistence")) {
                return error.SessionPersistenceUnavailable;
            }
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const store = if (app.session_persistence.store) |value|
                value
            else
                return error.SessionPersistenceUnavailable;
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return error.SessionPersistenceUnavailable;
            const recovery_checkpoint = try store.prepareUsageRecoveryCheckpoint(
                app.alloc,
                loaded,
                snapshot,
            );
            _ = try loaded.appendEvent(
                app.alloc,
                .{ .usage_checkpointed = .{ .usage = snapshot } },
                recovery_checkpoint.timestamp_ms,
            );
            try store.finishUsageRecoveryCheckpoint(
                loaded.active_id,
                recovery_checkpoint,
            );
        }

        pub fn setRecoveryCheckpoint(
            app: *App,
            checkpoint: session_codec.RecoveryCheckpoint,
        ) !void {
            writeRecoveryCheckpoint(app, checkpoint) catch |err| {
                if (err == error.SessionPersistenceUncertain) {
                    if (comptime @hasDecl(@TypeOf(app.worker), "preservePromptSnapshots")) {
                        app.worker.preservePromptSnapshots(checkpoint.turn_id, checkpoint.user.images);
                    }
                }
                return err;
            };
        }

        fn writeRecoveryCheckpoint(
            app: *App,
            checkpoint: session_codec.RecoveryCheckpoint,
        ) !void {
            if (comptime !@hasField(App, "session_persistence")) {
                return error.SessionPersistenceUnavailable;
            }
            var remember_failure: ?RememberFailure = null;
            {
                app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
                defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
                const loaded = if (app.session_persistence.writable) |*value|
                    value
                else
                    return error.SessionPersistenceUnavailable;
                const first_work = app.session_persistence.remember_fresh_session and !hasDurableUserWork(loaded);
                const now_ms = io_mod.milliTimestamp();
                _ = try loaded.appendEvent(
                    app.alloc,
                    .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } },
                    now_ms,
                );
                if (first_work) {
                    app.session_persistence.remember_fresh_session = false;
                    remember_failure = rememberSession(app, loaded.active_id);
                }
            }
            if (remember_failure) |failure| reportRememberFailure(app, failure, true);
            if (comptime @hasDecl(@TypeOf(app.worker), "preservePromptSnapshots")) {
                app.worker.preservePromptSnapshots(checkpoint.turn_id, checkpoint.user.images);
            }
        }

        pub fn clearRecoveryCheckpoint(app: *App) !void {
            if (comptime !@hasField(App, "session_persistence")) {
                return error.SessionPersistenceUnavailable;
            }
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return error.SessionPersistenceUnavailable;
            if (loaded.state.recovery_checkpoint == null) return;
            _ = try loaded.appendEvent(
                app.alloc,
                .{ .recovery_checkpoint_cleared = .{} },
                io_mod.milliTimestamp(),
            );
        }

        pub fn snapshotRecoveryCheckpoint(
            app: *App,
            alloc: Allocator,
        ) !?session_codec.RecoveryCheckpoint {
            if (comptime !@hasField(App, "session_persistence")) return null;
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value| value else return null;
            const checkpoint = loaded.state.recovery_checkpoint orelse return null;
            return try checkpoint.dupe(alloc);
        }

        pub fn continuePausedRecovery(app: *App) !bool {
            var checkpoint = (try snapshotRecoveryCheckpoint(
                app,
                std.heap.c_allocator,
            )) orelse return false;
            defer checkpoint.deinit(std.heap.c_allocator);

            app.session.setConversationLanguageFromUserMessage(checkpoint.user.text);
            return app.queueRecoveryCheckpoint(&checkpoint);
        }

        /// Poll cadence and bound for snapshotFreshPromptBoundary's wait for an
        /// in-flight turn close.
        const fresh_prompt_turn_close_poll_ms: u64 = 50;
        const fresh_prompt_turn_close_wait_ms: i64 = 30 * std.time.ms_per_s;

        const FreshPromptBoundaryProbe = union(enum) {
            wait,
            ready: session_codec.RecoveryCheckpoint,
        };

        /// An open turn without a recovery checkpoint is the finalization
        /// window of a cancelled or stall-stopped turn: those paths clear the
        /// durable checkpoint first and close the turn through the queued
        /// turn-finished event, which drains on another thread. Wait for the
        /// close instead of failing the send. Only a turn that stays open
        /// past the deadline is genuinely corrupt and still errors.
        pub fn snapshotFreshPromptBoundary(app: *App, alloc: Allocator) !?session_codec.RecoveryCheckpoint {
            return snapshotFreshPromptBoundaryWithin(app, alloc, fresh_prompt_turn_close_wait_ms);
        }

        fn snapshotFreshPromptBoundaryWithin(app: *App, alloc: Allocator, wait_ms: i64) !?session_codec.RecoveryCheckpoint {
            const deadline_ms = io_mod.milliTimestamp() + wait_ms;
            var waiting_logged = false;
            while (true) {
                const probe: FreshPromptBoundaryProbe = blk: {
                    app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
                    defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
                    const loaded = if (app.session_persistence.writable) |*value| value else return null;
                    if (!loaded.conversation_writer.turn_open) {
                        loaded.boundary_wedged = false;
                        return null;
                    }
                    if (loaded.state.recovery_checkpoint) |checkpoint| {
                        loaded.boundary_wedged = false;
                        break :blk .{ .ready = try checkpoint.dupe(alloc) };
                    }
                    // A wedged boundary (a stop path that never commits the
                    // close) already paid the wait once; fail fast after that.
                    if (loaded.boundary_wedged) return error.InvalidRecoveryCheckpoint;
                    break :blk .wait;
                };
                switch (probe) {
                    .ready => |value| return value,
                    .wait => {},
                }
                // A cancelled or shutting-down worker must not hold the send
                // (or the worker-thread join at shutdown) for the full wait.
                if (comptime @hasDecl(@TypeOf(app.worker), "isCancelRequested")) {
                    if (app.worker.isCancelRequested()) {
                        debug_trace.logf("session", "event=fresh_prompt_boundary_aborted reason=cancel_requested", .{});
                        return error.InvalidRecoveryCheckpoint;
                    }
                }
                if (!waiting_logged) {
                    debug_trace.logf("session", "event=fresh_prompt_boundary_waiting reason=open_turn_without_checkpoint", .{});
                    waiting_logged = true;
                }
                if (io_mod.milliTimestamp() >= deadline_ms) {
                    app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
                    if (app.session_persistence.writable) |*loaded| {
                        if (loaded.conversation_writer.turn_open and loaded.state.recovery_checkpoint == null) {
                            loaded.boundary_wedged = true;
                        }
                    }
                    app.session_persistence.write_mutex.unlock(io_mod.getIo());
                    debug_trace.logf("session", "event=fresh_prompt_boundary_timeout reason=open_turn_without_checkpoint wait_ms={d}", .{wait_ms});
                    return error.InvalidRecoveryCheckpoint;
                }
                io_mod.sleep(fresh_prompt_turn_close_poll_ms * std.time.ns_per_ms);
            }
        }

        pub fn normalizeFreshPromptPreparation(app: *App, request: worker_runtime.FreshPromptPreparation) worker_runtime.FreshPromptPreparation {
            if (comptime !@hasField(App, "session_persistence")) return request;
            var current = request;
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            if (app.session_persistence.writable) |*loaded| {
                if (!loaded.conversation_writer.turn_open and current.prior_turn != null) {
                    debug_trace.logf("session", "event=fresh_prompt_prior_already_finished turn_id={d}; skipping interrupted closure", .{request.turn_id});
                    current.prior_turn = null;
                }
            }
            return current;
        }

        pub fn prepareFreshPrompt(app: *App, request: worker_runtime.FreshPromptPreparation) !worker_runtime.FreshPromptHistory {
            const alloc = std.heap.c_allocator;
            var source: std.ArrayList(types.HistoryTurn) = .empty;
            defer source.deinit(alloc);
            try source.appendSlice(alloc, app.session.agent.history.items);
            if (request.prior_turn) |prior| try source.append(alloc, prior);
            const history = try session_runtime.snapshotOwnedContextHistory(alloc, source.items, 0, 0);
            errdefer types.freeHistoryTurnSlice(alloc, history);
            const images = try session_runtime.collect_image_catalog(alloc, history, request.user.images);
            errdefer types.freeImageAttachmentSlice(alloc, images);
            const intent = try auto_classifier_context.buildCanonicalRootUserContext(alloc, request.user.text, history);
            errdefer alloc.free(intent);
            if (request.prior_turn) |prior| try appendHistoryTurn(app, prior);
            return .{
                .history = history,
                .authorized_image_catalog = images,
                .root_user_intent_context = intent,
                .unversioned_history_count = app.session.unversionedHistoryEnd(),
            };
        }

        pub fn appendHistoryTurnForVisualEpoch(
            app: *App,
            turn: types.HistoryTurn,
        ) !HistoryAppendOutcome {
            return appendHistoryTurnWithPendingPresentation(
                app,
                turn,
                .visual_epoch,
                null,
            );
        }

        pub fn appendFinishedPromptForVisualEpoch(
            app: *App,
            finished: types.FinishedPrompt,
        ) !HistoryAppendOutcome {
            return appendHistoryTurnWithPendingPresentation(
                app,
                finished.turn,
                .visual_epoch,
                finished.snapshot_file_ownership,
            );
        }

        const AppendHistoryMode = enum {
            strict,
            visual_epoch,
            /// A rendered, user-visible finished turn. A validation or commit
            /// failure must not take the session down: commit in memory, warn,
            /// and keep the process alive. `SessionPersistenceUncertain` still
            /// propagates, because the write may have partially landed.
            finished_prompt,
        };

        fn appendHistoryTurnWithPendingPresentation(
            app: *App,
            turn: types.HistoryTurn,
            mode: AppendHistoryMode,
            snapshot_file_ownership: ?types.SnapshotFileOwnership,
        ) !HistoryAppendOutcome {
            if (comptime !@hasField(App, "session_persistence")) {
                return appendHistoryTurnWithOutcome(app, turn, mode, snapshot_file_ownership);
            }
            const interrupted = switch (turn) {
                .interrupted => |entry| entry,
                else => return appendHistoryTurnWithOutcome(app, turn, mode, snapshot_file_ownership),
            };
            var pending = app.session_persistence.pending_cancelled_command orelse {
                return appendHistoryTurnWithOutcome(app, turn, mode, snapshot_file_ownership);
            };
            app.session_persistence.pending_cancelled_command = null;
            const call = interrupted.tool_call orelse {
                pending.discard(app.alloc);
                return appendHistoryTurnWithOutcome(app, turn, mode, snapshot_file_ownership);
            };
            const is_command = try captured_command.isToolCall(
                app.alloc,
                call.name,
                call.arguments_json,
            );
            if (!is_command or
                !std.mem.eql(u8, call.id, pending.lifecycle_id.call_id))
            {
                pending.discard(app.alloc);
                return appendHistoryTurnWithOutcome(app, turn, mode, snapshot_file_ownership);
            }
            defer pending.discard(app.alloc);

            if (interrupted.cancelled_command) |authoritative| {
                var enriched_presentation = authoritative;
                if (enriched_presentation.command_artifact_handle == null) {
                    enriched_presentation.command_artifact_handle =
                        pending.command_artifact_handle;
                }
                var enriched_interrupted = interrupted;
                enriched_interrupted.cancelled_command = enriched_presentation;
                return appendHistoryTurnWithOutcome(
                    app,
                    .{ .interrupted = enriched_interrupted },
                    mode,
                    snapshot_file_ownership,
                );
            }

            var enriched_interrupted = interrupted;
            enriched_interrupted.cancelled_command = .{
                .command_artifact_handle = pending.command_artifact_handle,
            };
            const enriched: types.HistoryTurn = .{ .interrupted = enriched_interrupted };
            return appendHistoryTurnWithOutcome(app, enriched, mode, snapshot_file_ownership);
        }

        fn ensurePendingCancelledCommand(
            app: *App,
            id: types.ToolLifecycleId,
        ) ?*PendingCancelledCommand {
            if (app.session_persistence.pending_cancelled_command) |*pending| {
                if (pending.matches(id)) return pending;
                discardAnyPendingCancelledCommand(app, "lifecycle_replaced");
            }

            const call_id = app.alloc.dupe(u8, id.call_id) catch |err| {
                debug_trace.logf(
                    "session",
                    "cancelled command metadata identity unavailable call_id={s} err={s}",
                    .{ id.call_id, @errorName(err) },
                );
                return null;
            };
            app.session_persistence.pending_cancelled_command = .{
                .lifecycle_id = .{
                    .turn_id = id.turn_id,
                    .call_id = call_id,
                },
            };
            return &app.session_persistence.pending_cancelled_command.?;
        }

        fn discardPendingCancelledCommand(
            app: *App,
            id: types.ToolLifecycleId,
            reason: []const u8,
        ) void {
            const pending = if (app.session_persistence.pending_cancelled_command) |*value|
                value
            else
                return;
            if (!pending.matches(id)) return;
            discardAnyPendingCancelledCommand(app, reason);
        }

        fn discardAnyPendingCancelledCommand(app: *App, reason: []const u8) void {
            const pending = if (app.session_persistence.pending_cancelled_command) |*value|
                value
            else
                return;
            debug_trace.logf(
                "session",
                "cancelled command metadata discarded call_id={s} reason={s}",
                .{ pending.lifecycle_id.call_id, reason },
            );
            pending.discard(app.alloc);
            app.session_persistence.pending_cancelled_command = null;
        }

        fn appendHistoryTurnWithOutcome(
            app: *App,
            turn: types.HistoryTurn,
            mode: AppendHistoryMode,
            snapshot_file_ownership: ?types.SnapshotFileOwnership,
        ) !HistoryAppendOutcome {
            var prepared = (if (comptime @hasDecl(@TypeOf(app.session), "prepareHistoryEntry"))
                app.session.prepareHistoryEntry(app.alloc, turn)
            else
                types.dupeHistoryTurn(app.alloc, turn)) catch |err| {
                return switch (mode) {
                    // In-memory preparation failure (out of memory) cannot be
                    // degraded: the in-memory commit needs the prepared copy.
                    .strict, .finished_prompt => err,
                    .visual_epoch => .uncommitted,
                };
            };
            var prepared_owned = true;
            defer if (prepared_owned) types.freeHistoryTurn(app.alloc, prepared);
            if (comptime !@hasField(App, "session_persistence")) {
                if (comptime @hasDecl(@TypeOf(app.session), "commitPreparedHistoryEntry")) {
                    app.session.commitPreparedHistoryEntry(app.alloc, prepared);
                    prepared_owned = false;
                } else {
                    try app.session.appendHistoryEntry(app.alloc, prepared);
                }
                if (snapshot_file_ownership) |ownership| ownership.transfer();
                ensureCachedSessionTitle(app) catch {};
                return .committed;
            }
            var remember_failure: ?RememberFailure = null;
            defer if (remember_failure) |failure| reportRememberFailure(app, failure, false);
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else {
                app.session_persistence.write_mutex.unlock(io_mod.getIo());
                if (comptime @hasDecl(@TypeOf(app.session), "commitPreparedHistoryEntry")) {
                    app.session.commitPreparedHistoryEntry(app.alloc, prepared);
                    prepared_owned = false;
                } else {
                    try app.session.appendHistoryEntry(app.alloc, prepared);
                }
                if (snapshot_file_ownership) |ownership| ownership.transfer();
                ensureCachedSessionTitle(app) catch {};
                return .committed;
            };
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const first_work = app.session_persistence.remember_fresh_session and !hasDurableUserWork(loaded);
            var persistence_failure: ?anyerror = null;
            loaded.prepareHistoryTurnForCommit(app.alloc, &prepared) catch |err| {
                if (mode == .finished_prompt and err != error.SessionPersistenceUncertain) {
                    persistence_failure = err;
                } else return err;
            };
            if (persistence_failure == null) {
                _ = loaded.appendEvent(
                    app.alloc,
                    .{ .history_turn_committed = .{
                        .conversation_language = app.session.languageSnapshot(),
                        .total_input_tokens = app.total_input_tokens,
                        .total_output_tokens = app.total_output_tokens,
                        .turn = prepared,
                    } },
                    io_mod.milliTimestamp(),
                ) catch |err| {
                    if (err == error.SessionPersistenceUncertain) {
                        if (snapshot_file_ownership) |ownership| ownership.transfer();
                        return err;
                    }
                    switch (mode) {
                        .strict => return err,
                        .visual_epoch => {
                            debug_trace.logf(
                                "session",
                                "visual epoch history not committed err={s}",
                                .{@errorName(err)},
                            );
                            return .uncommitted;
                        },
                        .finished_prompt => persistence_failure = err,
                    }
                };
            }
            if (persistence_failure) |err| {
                // A finished turn kept in memory cannot be followed by another
                // prompt while its unfinished copy is still in the journal.
                recordShutdownFailure(app, err);
                if (loaded.conversation_writer.turn_open and loaded.conversation_writer.failure == null) {
                    loaded.conversation_writer.failure = error.SessionCommitFailed;
                    debug_trace.logf("session", "open turn blocked after failed save err={s}", .{@errorName(err)});
                }
                if (comptime @hasDecl(App, "writeDomainNotice")) {
                    const body = if (loaded.conversation_writer.turn_open)
                        try app.alloc.print(
                            "Turn completed, but fx could not save it ({s}). New messages are blocked until you reopen the session. The turn may run again.",
                            .{@errorName(err)},
                        )
                    else
                        try app.alloc.print(
                            "Turn completed, but fx could not save it ({s}). The session keeps running; this turn may be missing after a resume.",
                            .{@errorName(err)},
                        );
                    defer app.alloc.free(body);
                    app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = body }, true) catch {};
                }
            } else if (first_work) {
                app.session_persistence.remember_fresh_session = false;
                remember_failure = rememberSession(app, loaded.active_id);
            }
            if (comptime @hasDecl(@TypeOf(app.session), "commitPreparedHistoryEntry")) {
                app.session.commitPreparedHistoryEntry(app.alloc, prepared);
                prepared_owned = false;
            } else {
                try app.session.appendHistoryEntry(app.alloc, prepared);
            }
            if (snapshot_file_ownership) |ownership| ownership.transfer();
            ensureCachedSessionTitle(app) catch {};
            return .committed;
        }

        pub fn commitRuntimePreferences(
            app: *App,
            patch: SessionPreferencePatch,
        ) PreferenceCommitResult {
            var result = PreferenceCommitResult{};
            applySessionPreferencePatch(app, patch) catch |err| {
                result.session_error = err;
            };
            if (patch.model != null or patch.fast_mode != null) {
                app.session_persistence.fast_mode_model_bound =
                    patch.model != null and patch.fast_mode != null;
            }

            var settings_attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                patch.userSettingsPatch(),
            );
            switch (settings_attempt) {
                .outcome => |outcome| {
                    result.settings_outcome = outcome;
                    settings_attempt = undefined;
                },
                .failure => |failure| {
                    result.settings_error = failure.err;
                    result.settings_failure_cleanup = failure.cleanup;
                    settings_attempt = undefined;
                },
            }
            if (result.settings_error == null) {
                applyPreferencePatch(
                    app.alloc,
                    &app.session_persistence.workspace_preferences,
                    patch,
                ) catch |err| {
                    result.session_error = err;
                };
            }

            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return result;
            if (result.session_error != null) return result;
            const durable_ultrafast_mode = durableUltrafastEventDelta(
                loaded.state.preferences.ultrafast_mode,
                patch.ultrafast_mode,
            );
            if (patch.model == null and
                patch.provider == null and
                patch.effort == null and
                patch.fast_mode == null and
                durable_ultrafast_mode == null)
            {
                return result;
            }
            _ = loaded.appendEvent(
                app.alloc,
                .{ .preferences_changed = .{
                    .model = if (patch.model) |model|
                        @constCast(model)
                    else
                        null,
                    .provider = patch.provider,
                    .effort = patch.effort,
                    .fast_mode = patch.fast_mode,
                    .ultrafast_mode = durable_ultrafast_mode,
                } },
                io_mod.milliTimestamp(),
            ) catch |err| {
                result.session_error = err;
                warnDegraded(app, err) catch {};
            };
            return result;
        }

        pub fn activeSessionId(app: *App) ?[]const u8 {
            if (app.session_persistence.writable) |*loaded| return loaded.active_id;
            return null;
        }

        /// Replaces the cached footer title. App owns the copy.
        pub fn setCachedSessionTitle(app: *App, title: []const u8) !void {
            if (comptime !@hasField(App, "session_title")) return;
            app.session_title.clearRetainingCapacity();
            try appendTitleWithoutControlBytes(app, title);
            syncTerminalTitle(app);
        }

        pub fn clearCachedSessionTitle(app: *App) void {
            if (comptime !@hasField(App, "session_title")) return;
            app.session_title.clearRetainingCapacity();
            syncTerminalTitle(app);
        }

        /// Drops C0 and DEL bytes before the cached title reaches the statusline.
        /// Derived titles come from untrusted prompt text and display sidecars;
        /// `/rename` input is already rejected by `validateSessionTitle`.
        fn appendTitleWithoutControlBytes(app: *App, title: []const u8) !void {
            var start: usize = 0;
            for (title, 0..) |byte, index| {
                if (byte >= 0x20 and byte != 0x7f) continue;
                try app.session_title.appendSlice(app.alloc, title[start..index]);
                start = index + 1;
            }
            try app.session_title.appendSlice(app.alloc, title[start..]);
        }

        fn terminalTitle(app: *App) host_capability.TerminalTitle {
            if (comptime @hasDecl(App, "terminalTitle")) {
                return app.terminalTitle();
            }
            if (comptime builtin.is_test) return host_capability.unavailable_terminal_title;
            @compileError("interactive session runtime requires a terminal title host capability");
        }

        /// Terminal tabs show the session title once one exists; before the
        /// first prompt they identify the running build and workspace.
        pub fn syncTerminalTitle(app: *App) void {
            if (comptime !provider_runtime.supported(App)) return;
            syncTerminalTitleWith(app, terminalTitle(app));
        }

        pub fn syncTerminalTitleWith(
            app: *App,
            provider: host_capability.TerminalTitle,
        ) void {
            if (comptime !provider_runtime.supported(App)) return;
            if (cachedSessionTitle(app)) |title| {
                provider.set(title);
                return;
            }
            const basename = if (comptime @hasField(App, "workspace_root"))
                std.Io.Dir.path.basename(app.workspace_root)
            else
                "";
            const folder = if (basename.len == 0) "workspace" else basename;
            const prefix = "fx v" ++ build_options.app_version ++ " | ";
            var label_buffer: [prefix.len + std.Io.Dir.max_path_bytes]u8 = undefined;
            const label = std.mem.print(&label_buffer, "{s}{s}", .{ prefix, folder }) catch |err| {
                debug_trace.logf("session", "terminal title workspace omitted err={s}", .{@errorName(err)});
                provider.set("fx v" ++ build_options.app_version);
                return;
            };
            provider.set(label);
        }

        pub fn cachedSessionTitle(app: *App) ?[]const u8 {
            if (comptime !@hasField(App, "session_title")) return null;
            return if (app.session_title.items.len == 0) null else app.session_title.items;
        }

        /// Derives and caches the title on the first turn of a fresh session.
        /// Derivation freezes at the first usable prompt, so this is a no-op
        /// once a title is cached.
        pub fn ensureCachedSessionTitle(app: *App) !void {
            if (comptime !@hasField(App, "session_title")) return;
            if (app.session_title.items.len > 0) return;
            var display = session_display_metadata.deriveFromHistory(
                app.alloc,
                app.session.agent.history.items,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
            defer display.deinit(app.alloc);
            if (!display.present) return;
            try setCachedSessionTitle(app, display.title);
        }

        /// Starts background title generation for a fresh session on the first
        /// user prompt submit. Fire-and-forget: every gate failure is a silent
        /// no-op because the locally derived title remains in place. The
        /// generated title is applied by `pollSessionTitleGeneration`.
        pub fn maybeStartSessionTitleGeneration(app: *App, prompt: []const u8) void {
            if (comptime !@hasField(App, "session_persistence")) return;
            if (comptime !@hasField(App, "session_title_generation")) return;
            if (comptime !@hasField(App, "session_title")) return;
            if (comptime !@hasField(App, "session")) return;
            if (comptime !@hasField(App, "auth")) return;
            if (comptime !@hasDecl(App, "agentStreamProvider")) return;
            if (comptime !@hasDecl(App, "sessionTitleModel")) return;

            const excerpt = session_title_generation.promptExcerpt(prompt) orelse return;
            const title_model = app.sessionTitleModel();
            if (!session_title_generation.shouldGenerate(.{
                .setting_enabled = app.session_title_generation,
                .provider_supports_titles = title_model != null,
                .session_untitled = app.session_title.items.len == 0 and
                    app.session.agent.history.items.len == 0,
                .recovery_replay = false,
                .task_running = app.session_persistence.title_generation.task != null,
            })) return;
            const session_id = activeSessionId(app) orelse return;
            const credential = app.auth.gatewayCredential() orelse return;

            const task = session_title_generation.Task.create(.{
                .session_id = session_id,
                .model = title_model.?,
                .prompt_excerpt = excerpt,
                .api_key = credential.api_key,
                .gateway_team = credential.gateway_team,
                .account_id = app.auth.accountId(),
                .credential_source = credential.source,
                .stream_provider = app.agentStreamProvider(),
            }) catch |err| {
                app.session_persistence.title_generation.recordSpawnFailure(session_id, title_model.?, err);
                return;
            };
            task.spawn() catch |err| {
                debug_trace.logf("session", "event=title_generation result=unavailable reason=spawn err={s}", .{@errorName(err)});
                app.session_persistence.title_generation.recordSpawnFailure(session_id, title_model.?, err);
                task.destroy();
                return;
            };
            app.session_persistence.title_generation.start(task);
        }

        /// Applies a finished background title generation on the main loop.
        /// Returns true when the session title changed.
        pub fn pollSessionTitleGeneration(app: *App) !bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            if (comptime !@hasField(App, "session_title")) return false;
            if (comptime !@hasField(App, "session")) return false;
            const task = app.session_persistence.title_generation.takeCompleted() orelse return false;
            defer task.destroy();
            app.session_persistence.title_generation.recordFinished(task);
            const title = task.takeTitle() orelse return false;
            defer std.heap.c_allocator.free(title);
            const active_id = activeSessionId(app) orelse {
                debug_trace.logf("session", "event=title_generation_apply result=dropped reason=no_active_session", .{});
                app.session_persistence.title_generation.recordDropped(.no_active_session, "");
                return false;
            };
            if (!std.mem.eql(u8, active_id, task.session_id)) {
                debug_trace.logf(
                    "session",
                    "event=title_generation_apply result=dropped reason=session_changed session={s} active={s}",
                    .{ task.session_id, active_id },
                );
                app.session_persistence.title_generation.recordDropped(.session_changed, "");
                return false;
            }
            var installed = false;
            {
                app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
                defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
                if (app.session_persistence.writable) |*loaded| {
                    installed = session_title_generation.installGeneratedTitle(
                        app.alloc,
                        loaded,
                        app.session.agent.history.items,
                        title,
                    ) catch |err| {
                        debug_trace.logf(
                            "session",
                            "event=title_generation_apply result=failed session={s} err={s}",
                            .{ task.session_id, @errorName(err) },
                        );
                        app.session_persistence.title_generation.recordDropped(.install_failed, @errorName(err));
                        return false;
                    };
                    if (!installed) {
                        app.session_persistence.title_generation.recordDropped(.user_title_present, "");
                    }
                } else {
                    debug_trace.logf(
                        "session",
                        "event=title_generation_apply result=dropped reason=not_writable session={s}",
                        .{task.session_id},
                    );
                    app.session_persistence.title_generation.recordDropped(.not_writable, "");
                }
            }
            if (!installed) return false;
            try setCachedSessionTitle(app, title);
            invalidateSessionPickerCaches(app);
            debug_trace.logf("session", "event=title_generation_apply result=installed session={s}", .{task.session_id});
            return true;
        }

        pub const RenameError = error{
            EmptyTitle,
            TitleTooLong,
            InvalidTitle,
            NoActiveSession,
        };

        /// Validates a user-supplied session title. Returns the trimmed slice,
        /// which borrows from `raw`.
        pub fn validateSessionTitle(raw: []const u8) RenameError![]const u8 {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) return error.EmptyTitle;
            if (trimmed.len > session_display_metadata.max_title_bytes) return error.TitleTooLong;
            if (!std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidTitle;
            for (trimmed) |byte| {
                if (byte < 0x20 or byte == 0x7f) return error.InvalidTitle;
            }
            return trimmed;
        }

        /// Renames the active session in memory and in session metadata.
        pub fn renameActiveSession(app: *App, raw: []const u8) !void {
            const title = try validateSessionTitle(raw);
            if (comptime !@hasField(App, "session_persistence")) return error.NoActiveSession;
            if (app.session_persistence.writable == null) return error.NoActiveSession;

            try setCachedSessionTitle(app, title);

            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());

            const loaded = &app.session_persistence.writable.?;
            if (!try loaded.renameConversation(app.alloc, title)) {
                return error.UnsupportedSessionFormat;
            }
            invalidateSessionPickerCaches(app);
        }

        pub fn activeSessionDisplayPath(
            app: *App,
            alloc: Allocator,
        ) !?[]u8 {
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return null;
            const store = app.session_persistence.store orelse return null;
            return try session_store.sessionDirPath(
                alloc,
                store.sessions_dir,
                loaded.active_id,
            );
        }

        pub fn childCapability(app: *App) ?*session_child_store.SessionChildCapability {
            if (app.session_persistence.writable == null) return null;
            return activeChildCapability(app) catch null;
        }

        /// The open session's side-file capability, from either backend.
        fn activeChildCapability(app: *App) !*session_child_store.SessionChildCapability {
            const loaded = if (app.session_persistence.writable) |*value| value else return error.SessionPersistenceUnavailable;
            return loaded.childCapability();
        }

        pub fn subagentHost(app: *App) ?*subagent_tool_host.Runtime {
            if (comptime !@hasField(App, "session_persistence")) return null;
            return app.session_persistence.subagent_host;
        }

        pub fn rebindSubagentHost(app: *App) void {
            const host = app.session_persistence.subagent_host orelse return;
            const store = if (app.session_persistence.store) |*value| value else return;
            host.rebind(store, app, subagentAuthorityResolver(app));
        }

        /// Stops the subagent host, joining its child threads, before the
        /// session they append to can close.
        pub fn disableSubagentHost(app: *App) void {
            if (app.session_persistence.subagent_host) |host| {
                host.deinit();
                app.session_persistence.subagent_host = null;
            }
        }

        pub fn finalizePersistence(app: *App) void {
            closeWritableSession(app);
        }

        pub fn recordShutdownFailure(app: *App, err: anyerror) void {
            if (app.session_persistence.shutdown_failure == null) {
                app.session_persistence.shutdown_failure = err;
            }
            debug_trace.logf("session", "shutdown finished prompt persistence failed err={s}", .{@errorName(err)});
        }

        pub fn recordFailedHistoryDelivery(app: *App, err: anyerror) void {
            recordShutdownFailure(app, err);
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            if (app.session_persistence.writable) |*loaded| {
                // A missing finished turn cannot be followed by another saved turn.
                if (loaded.conversation_writer.failure == null) {
                    loaded.conversation_writer.failure = error.SessionCommitFailed;
                }
            }
        }

        pub fn finalizePersistenceWithResumeHandoff(app: *App) ?ResumeHandoff {
            return closeWritableSessionWithResumeHandoff(app);
        }

        pub fn requestResumeHandoff(app: *App) void {
            app.session_persistence.resume_handoff_intent = .requested;
        }

        pub fn requestUpgradeResumeHandoff(app: *App) void {
            app.session_persistence.resume_handoff_intent = .upgrade_requested;
        }

        pub fn prepareResumeHandoff(app: *App) !void {
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return error.SessionPersistenceUnavailable;
            try settleDurableState(app, loaded);
        }

        pub fn suspendToJobControl(app: *App, footer_rows: u16) !void {
            return app_lifecycle.suspendToJobControl(
                &app.terminal,
                &app.shell,
                &app.metrics,
                footer_rows,
            );
        }

        pub fn deinitPersistence(app: *App) void {
            closeWritableSession(app);
            app.session_persistence.deinit(app.alloc);
        }

        pub fn deinitPersistenceForProcessExit(app: *App) void {
            closeWritableSession(app);
            app.session_persistence.deinitForProcessExit(app.alloc);
        }

        pub fn requestPersistenceShutdown(app: *App) void {
            app.session_persistence.session_picker_load.requestStop();
            app.session_persistence.title_generation.requestStop();
        }

        /// Exit publishes nothing to the profile usage ledger, so it never
        /// waits on another process holding its lock. The session keeps
        /// unpublished usage for recovery and the next resume.
        pub fn abandonProfileLedgerForProcessExit(app: *App) void {
            if (comptime @hasField(@TypeOf(app.session), "profile_usage")) {
                app.session.profile_usage.abandonLedgerForProcessExit();
            }
        }

        fn LiveHistorySink(comptime SinkApp: type) type {
            return struct {
                app: *SinkApp,

                const Self = @This();

                fn appendNotice(self: *Self, notice: types.SemanticNotice) !void {
                    try self.app.writeDomainNotice(notice, true);
                }

                fn setCreatedAtMs(_: *Self, _: i64) void {}

                fn materializeCommandReplay(_: *const Self) bool {
                    return true;
                }

                fn appendTurnSummary(self: *Self, summary: types.TurnSummary) !void {
                    if (comptime @hasField(SinkApp, "shell")) {
                        if (comptime @hasDecl(@TypeOf(self.app.shell), "appendTurnSummaryEntry")) {
                            _ = try self.app.shell.appendTurnSummaryEntry(self.app.alloc, summary);
                        }
                    }
                }

                fn appendUserTurn(self: *Self, user: types.UserTurn, has_prior_turns: bool) !void {
                    try self.app.writeUserPromptCardWithSpacing(user, has_prior_turns);
                }

                fn appendRaw(self: *Self, text: []const u8) !void {
                    try self.app.writeTranscript(text, true);
                }

                fn appendTurnCancellation(self: *Self) !void {
                    const line = try transcript_runtime.formatHistoricalToolStatusLine(
                        self.app.alloc,
                        .cancelled,
                        "Cancelled",
                    );
                    defer self.app.alloc.free(line);
                    try self.app.writeTranscriptClassified(
                        line,
                        true,
                        .turn_cancellation,
                    );
                }

                fn appendToolStatus(
                    self: *Self,
                    kind: types.ToolOutcomeKind,
                    status: []const u8,
                ) !u32 {
                    if (comptime @hasDecl(SinkApp, "writeCompletedToolStatusReturningEntryId")) {
                        return self.app.writeCompletedToolStatusReturningEntryId(kind, status, true);
                    }
                    try self.app.writeCompletedToolStatus(kind, status, true);
                    return 0;
                }

                fn appendCommandOutput(
                    self: *Self,
                    stream: command_output_content.Stream,
                    text: []const u8,
                ) !void {
                    try self.app.writeCommandOutputChunk(stream, text, true);
                }

                fn finishCommandOutput(self: *Self) !void {
                    try self.app.flushCommandOutputSummary(true);
                }

                fn attachHistoricalToolDetail(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalToolDetail")) {
                        try self.app.attachHistoricalToolDetail(entry_id, call, result);
                    }
                }

                fn attachHistoricalToolDetailWithLifecycle(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                    lifecycle_id: types.ToolLifecycleId,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalToolDetailWithLifecycle")) {
                        try self.app.attachHistoricalToolDetailWithLifecycle(
                            entry_id,
                            call,
                            result,
                            lifecycle_id,
                        );
                    } else {
                        try self.attachHistoricalToolDetail(entry_id, call, result);
                    }
                }

                fn attachHistoricalToolDetailAfterCommandOutput(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalToolDetailAfterCommandOutput")) {
                        try self.app.attachHistoricalToolDetailAfterCommandOutput(
                            entry_id,
                            call,
                            result,
                        );
                    } else {
                        try self.attachHistoricalToolDetail(entry_id, call, result);
                    }
                }

                fn attachHistoricalToolCallWithoutResult(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalToolCallWithoutResult")) {
                        try self.app.attachHistoricalToolCallWithoutResult(entry_id, call);
                    }
                }

                fn attachHistoricalCommandOutput(self: *Self, entry_id: u32) void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalCommandOutput")) {
                        self.app.attachHistoricalCommandOutput(entry_id);
                    }
                }

                fn attachHistoricalCancelledCommandDetail(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    command_artifact_handle: ?[]const u8,
                    replayed_output: bool,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalCancelledCommandDetail")) {
                        try self.app.attachHistoricalCancelledCommandDetail(
                            entry_id,
                            call,
                            command_artifact_handle,
                            replayed_output,
                        );
                    }
                }

                fn appendQuestionResolution(
                    self: *Self,
                    answers: []const types.QuestionAnswer,
                ) !u32 {
                    return self.app.writeHistoricalQuestionResolution(answers);
                }

                fn appendDiff(self: *Self, payload: diff.DiffEntryPayload) !void {
                    try self.app.registerAndEmitDiffBlock(payload);
                }

                fn appendAssistantText(self: *Self, text: []const u8) !void {
                    try SinkApp.pacerEmit(self.app, text);
                }

                fn appendAssistantTable(
                    self: *Self,
                    table: assistant_presentation.TablePayload,
                ) !void {
                    try self.app.appendAssistantTable(table);
                }

                fn appendAssistantCodeBlock(
                    self: *Self,
                    block: assistant_presentation.CodeBlockPayload,
                ) !void {
                    try self.app.appendAssistantCodeBlock(block);
                }

                fn appendAssistantThematicRule(self: *Self) !void {
                    try self.app.appendAssistantThematicRule();
                }
            };
        }

        fn DetachedHistorySink(comptime Projection: type) type {
            return struct {
                app: *App,
                projection: *Projection,
                labels: *const HistoricalSessionLabels,

                const Self = @This();

                fn activityKind(self: *Self, call: types.ToolCall) types.ToolActivityKind {
                    return self.app.historicalToolActivityKind(call);
                }

                /// Terminal-session actions (interact, stop) carry no command
                /// argument; restore their full launch command from the recorded
                /// session label so resumed rows reclip to the live width.
                fn attachSessionCommandDisplay(self: *Self, entry_id: u32, call: types.ToolCall) !void {
                    var scratch_state = std.heap.ArenaAllocator.init(self.projection.alloc);
                    defer mem_utils.deinit_arena(scratch_state);
                    const scratch = scratch_state.allocator();
                    const label = tooling_presentation.terminalSessionCompletedActionLabel(
                        scratch,
                        self.app.toolRegistry(),
                        call,
                    ) catch |err| {
                        debug_trace.logf(
                            "session",
                            "historical session action label unavailable entry_id={d} err={s}",
                            .{ entry_id, @errorName(err) },
                        );
                        return;
                    } orelse return;
                    const reflow = historicalSessionReflow(scratch, self.labels, call) orelse {
                        debug_trace.logf(
                            "session",
                            "historical session command unknown entry_id={d}",
                            .{entry_id},
                        );
                        return;
                    };
                    self.projection.setHistoricalToolCommandMetadata(
                        entry_id,
                        reflow,
                        label,
                    ) catch |err| debug_trace.logf(
                        "session",
                        "historical session command metadata unavailable entry_id={d} err={s}",
                        .{ entry_id, @errorName(err) },
                    );
                }

                fn attachCommandDisplay(self: *Self, entry_id: u32, call: types.ToolCall) !void {
                    var parsed = std.json.parseFromSlice(std.json.Value, self.projection.alloc, call.arguments_json, .{}) catch |err| {
                        debug_trace.logf(
                            "session",
                            "historical command metadata parse failed entry_id={d} err={s}",
                            .{ entry_id, @errorName(err) },
                        );
                        return;
                    };
                    defer parsed.deinit();
                    if (parsed.value != .object) return;
                    const command_value = parsed.value.object.get("command") orelse {
                        try self.attachSessionCommandDisplay(entry_id, call);
                        return;
                    };
                    if (command_value != .string) {
                        try self.attachSessionCommandDisplay(entry_id, call);
                        return;
                    }
                    // Use the app's live workspace root: the replayed status
                    // phrases are generated with that same root, so this keeps
                    // both halves of the row consistent.
                    const display = (tooling_presentation.formatRunCommandDetailBounded(
                        self.projection.alloc,
                        command_value.string,
                        self.app.workspace_root,
                        tooling_presentation.max_run_command_reflow_bytes,
                    ) catch |err| blk: {
                        debug_trace.logf(
                            "session",
                            "historical command display unavailable entry_id={d} err={s}",
                            .{ entry_id, @errorName(err) },
                        );
                        break :blk null;
                    }) orelse {
                        debug_trace.logf(
                            "session",
                            "historical command display withheld entry_id={d}",
                            .{entry_id},
                        );
                        return;
                    };
                    defer self.projection.alloc.free(display);
                    const label = tooling_presentation.runCommandCompletedActionLabel(
                        self.projection.alloc,
                        self.app.toolRegistry(),
                        call,
                    ) catch |err| blk: {
                        debug_trace.logf(
                            "session",
                            "historical command action label unavailable entry_id={d} err={s}",
                            .{ entry_id, @errorName(err) },
                        );
                        break :blk null;
                    };
                    if (label == null) debug_trace.logf(
                        "session",
                        "historical command action label withheld entry_id={d}",
                        .{entry_id},
                    );
                    if (label) |value| self.projection.setHistoricalToolCommandMetadata(
                        entry_id,
                        display,
                        value,
                    ) catch |err| debug_trace.logf(
                        "session",
                        "historical command metadata unavailable entry_id={d} err={s}",
                        .{ entry_id, @errorName(err) },
                    );
                }

                fn appendNotice(self: *Self, notice: types.SemanticNotice) !void {
                    _ = try self.projection.appendNotice(notice);
                }

                fn setCreatedAtMs(self: *Self, created_at_ms: i64) void {
                    self.projection.setCreatedAtMs(created_at_ms);
                }

                fn materializeCommandReplay(_: *const Self) bool {
                    return false;
                }

                fn appendTurnSummary(self: *Self, summary: types.TurnSummary) !void {
                    try self.projection.appendTurnSummary(summary);
                }

                fn appendUserTurn(self: *Self, user: types.UserTurn, _: bool) !void {
                    _ = try self.projection.appendUserTurn(user);
                }

                fn appendRaw(self: *Self, text: []const u8) !void {
                    _ = try self.projection.appendRawClassified(text, .unknown_raw);
                }

                fn appendTurnCancellation(self: *Self) !void {
                    const line = try transcript_runtime.formatHistoricalToolStatusLine(
                        self.projection.alloc,
                        .cancelled,
                        "Cancelled",
                    );
                    defer self.projection.alloc.free(line);
                    _ = try self.projection.appendRawClassified(
                        line,
                        .turn_cancellation,
                    );
                }

                fn appendToolStatus(
                    self: *Self,
                    kind: types.ToolOutcomeKind,
                    status: []const u8,
                ) !u32 {
                    return self.projection.appendToolStatus(kind, status);
                }

                fn appendCommandOutput(
                    self: *Self,
                    stream: command_output_content.Stream,
                    text: []const u8,
                ) !void {
                    try self.projection.appendCommandOutput(null, stream, text);
                }

                fn finishCommandOutput(self: *Self) !void {
                    try self.projection.finishCommandOutput(null);
                }

                fn attachHistoricalToolDetail(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                ) !void {
                    try self.projection.attachHistoricalToolDetail(
                        entry_id,
                        call,
                        self.activityKind(call),
                        result,
                    );
                    try self.attachCommandDisplay(entry_id, call);
                }

                fn attachHistoricalToolDetailWithLifecycle(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                    lifecycle_id: types.ToolLifecycleId,
                ) !void {
                    try self.projection.attachHistoricalToolDetailWithLifecycle(
                        entry_id,
                        call,
                        self.activityKind(call),
                        result,
                        lifecycle_id,
                    );
                    try self.attachCommandDisplay(entry_id, call);
                }

                fn attachHistoricalToolDetailAfterCommandOutput(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                ) !void {
                    try self.projection.attachHistoricalToolDetailAfterCommandOutput(
                        entry_id,
                        call,
                        self.activityKind(call),
                        result,
                    );
                    try self.attachCommandDisplay(entry_id, call);
                }

                fn attachHistoricalToolCallWithoutResult(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                ) !void {
                    try self.projection.attachHistoricalToolCallWithoutResult(entry_id, call);
                }

                fn attachHistoricalCommandOutput(self: *Self, entry_id: u32) void {
                    self.projection.attachHistoricalCommandOutput(entry_id);
                }

                fn attachHistoricalCancelledCommandDetail(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    command_artifact_handle: ?[]const u8,
                    replayed_output: bool,
                ) !void {
                    try self.projection.attachHistoricalCancelledCommandDetail(
                        entry_id,
                        call,
                        command_artifact_handle,
                        replayed_output,
                    );
                }

                fn appendQuestionResolution(
                    self: *Self,
                    answers: []const types.QuestionAnswer,
                ) !u32 {
                    const text = try self.app.prepareHistoricalQuestionResolution(answers);
                    defer self.app.alloc.free(text);
                    return self.projection.appendReplaceableLine(text);
                }

                fn appendDiff(self: *Self, payload: diff.DiffEntryPayload) !void {
                    try self.projection.appendDiff(payload);
                }

                fn appendAssistantText(self: *Self, text: []const u8) !void {
                    try self.projection.appendAssistantText(text);
                }

                fn appendAssistantTable(
                    self: *Self,
                    table: assistant_presentation.TablePayload,
                ) !void {
                    try self.projection.appendAssistantTable(table);
                }

                fn appendAssistantCodeBlock(
                    self: *Self,
                    block: assistant_presentation.CodeBlockPayload,
                ) !void {
                    try self.projection.appendAssistantCodeBlock(block);
                }

                fn appendAssistantThematicRule(self: *Self) !void {
                    try self.projection.appendAssistantThematicRule();
                }
            };
        }

        /// Maps historical shell session ids to their launch-command label so a
        /// resumed transcript can render the same `Observed <command>` text the
        /// live session showed, after the in-memory execution registry is gone.
        /// Session ids restart per process, so a session resumed across epochs
        /// can contain two runs that both produced `shell-1`; the later record
        /// wins, matching the most recent epoch's live rendering.
        const HistoricalSessionLabels = struct {
            const Label = struct {
                /// Compact-bound text baked into frozen status lines.
                label: []const u8,
                /// Reflow-bound command stored as tool detail metadata so group
                /// projection can reclip resumed rows to the live terminal width.
                reflow: ?[]const u8,
            };

            workspace_root: []const u8,
            map: std.StringHashMapUnmanaged(Label) = .empty,

            fn deinit(self: *HistoricalSessionLabels, alloc: Allocator) void {
                var it = self.map.iterator();
                while (it.next()) |entry| {
                    alloc.free(entry.key_ptr.*);
                    alloc.free(entry.value_ptr.label);
                    if (entry.value_ptr.reflow) |value| alloc.free(value);
                }
                self.map.deinit(alloc);
            }
        };

        /// Returns the recorded launch-command label for a session-scoped call
        /// (borrowed from `labels`), or null when the session is unknown.
        fn historicalSessionTarget(
            arena: Allocator,
            labels: *const HistoricalSessionLabels,
            call: types.ToolCall,
        ) ?[]const u8 {
            const entry = historicalSessionLabelEntry(arena, labels, call) orelse return null;
            return entry.label;
        }

        /// Returns the recorded reflow-bound launch command for a
        /// session-scoped call (borrowed from `labels`), or null when the
        /// session is unknown or no full display was recorded.
        fn historicalSessionReflow(
            arena: Allocator,
            labels: *const HistoricalSessionLabels,
            call: types.ToolCall,
        ) ?[]const u8 {
            const entry = historicalSessionLabelEntry(arena, labels, call) orelse return null;
            return entry.reflow;
        }

        fn historicalSessionLabelEntry(
            arena: Allocator,
            labels: *const HistoricalSessionLabels,
            call: types.ToolCall,
        ) ?HistoricalSessionLabels.Label {
            const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch return null;
            const session_id = tool_args.optionalStringArg(args, "session_id") orelse return null;
            return labels.map.get(session_id);
        }

        /// Reads the session id out of a persisted shell status payload into
        /// `buffer`, returning a slice of it. The preview can be truncated
        /// mid-JSON, so fall back to a bounded scan for the leading
        /// `"session_id"` field when a full parse fails.
        fn historicalSessionIdFromOutput(
            alloc: Allocator,
            output: []const u8,
            buffer: *[128]u8,
        ) ?[]const u8 {
            if (copyParsedSessionId(alloc, output, buffer)) |session_id| return session_id;
            const key = "\"session_id\":\"";
            const start = (std.mem.find(u8, output, key) orelse return null) + key.len;
            const end = std.mem.findScalarPos(u8, output, start, '"') orelse return null;
            return copyHistoricalSessionId(output[start..end], buffer);
        }

        fn copyParsedSessionId(alloc: Allocator, output: []const u8, buffer: *[128]u8) ?[]const u8 {
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                alloc,
                output,
                .{},
            ) catch return null;
            defer parsed.deinit();
            if (parsed.value != .object) return null;
            const value = parsed.value.object.get("session_id") orelse return null;
            if (value != .string) return null;
            return copyHistoricalSessionId(value.string, buffer);
        }

        fn copyHistoricalSessionId(raw: []const u8, buffer: *[128]u8) ?[]const u8 {
            if (!validHistoricalSessionId(raw)) return null;
            @memcpy(buffer[0..raw.len], raw);
            return buffer[0..raw.len];
        }

        fn validHistoricalSessionId(session_id: []const u8) bool {
            if (session_id.len == 0 or session_id.len > 128) return false;
            for (session_id) |byte| {
                if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
            }
            return true;
        }

        /// Records the launch command of a completed `run` call whose result
        /// still owns a live session, so later interact/stop calls naming that
        /// session render the command instead of the raw session id. Calls
        /// without a command argument, or whose result names no session,
        /// return without recording.
        fn recordHistoricalSessionLabel(
            app: *App,
            labels: *HistoricalSessionLabels,
            call: types.ToolCall,
            result: types.PersistedToolResult,
        ) Allocator.Error!void {
            var scratch_state = std.heap.ArenaAllocator.init(app.alloc);
            defer mem_utils.deinit_arena(scratch_state);
            const scratch = scratch_state.allocator();
            const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch return;
            const command = tool_args.optionalStringArg(args, "command") orelse return;
            const output = if (result.output.len > 0)
                result.output
            else
                result.preview orelse return;
            var session_id_buffer: [128]u8 = undefined;
            const session_id = historicalSessionIdFromOutput(scratch, output, &session_id_buffer) orelse return;
            const label = (try tooling_presentation.formatHistoricalTerminalDisplayTarget(
                app.alloc,
                command,
                labels.workspace_root,
            )) orelse {
                debug_trace.logf(
                    "session",
                    "historical session label withheld call_id={s} session_id={s}",
                    .{ call.id, session_id },
                );
                return;
            };
            errdefer app.alloc.free(label);
            const reflow: ?[]const u8 = (try tooling_presentation.formatRunCommandDetailBounded(
                app.alloc,
                command,
                labels.workspace_root,
                tooling_presentation.max_run_command_reflow_bytes,
            )) orelse null;
            errdefer if (reflow) |value| app.alloc.free(value);
            const owned_id = try app.alloc.dupe(u8, session_id);
            errdefer app.alloc.free(owned_id);
            const gop = try labels.map.getOrPut(app.alloc, owned_id);
            if (gop.found_existing) {
                app.alloc.free(owned_id);
                app.alloc.free(gop.value_ptr.label);
                if (gop.value_ptr.reflow) |value| app.alloc.free(value);
            }
            gop.value_ptr.* = .{ .label = label, .reflow = reflow };
        }

        fn replayResumedHistoryToSink(
            app: *App,
            sink: anytype,
            context_history: []const types.HistoryTurn,
            labels: *HistoricalSessionLabels,
        ) !void {
            {
                if (app.session_persistence.writable) |*loaded| {
                    if (app.session_persistence.store) |store| {
                        const Visitor = struct {
                            app: *App,
                            sink: @TypeOf(sink),
                            labels: *HistoricalSessionLabels,
                            has_prior_turns: bool = false,

                            pub fn append(self: *@This(), turn: types.HistoryTurn) !void {
                                return replayHistoryToSinkIncremental(
                                    self.app,
                                    self.sink,
                                    &.{turn},
                                    &self.has_prior_turns,
                                    self.labels,
                                );
                            }
                        };
                        var visitor = Visitor{ .app = app, .sink = sink, .labels = labels };
                        return store.visitConversationHistory(app.alloc, loaded.active_id, &visitor);
                    }
                }
            }
            return replayHistoryToSink(app, sink, context_history, labels);
        }

        fn readNativeResumeDisplay(
            app: *App,
            session: *session_store.LoadedWritableSession,
        ) !session_display_metadata.DisplayMetadata {
            if (try session.conversationTitle(app.alloc)) |title| {
                return .{ .present = true, .title = title };
            }
            return session_display_metadata.deriveFromHistory(
                app.alloc,
                session.state.history,
            );
        }

        fn writeResumeNotice(
            app: *App,
            sink: anytype,
            display: *const session_display_metadata.DisplayMetadata,
            notice: ResumeNotice,
        ) !void {
            // Only a real title enters the cache: the fallback placeholder must
            // not count as an existing title, or background title generation
            // would consider the session already named and never run.
            if (display.present) try setCachedSessionTitle(app, display.title);
            switch (notice) {
                .session => try sink.appendNotice(.{
                    .topic = "session resumed",
                    .tone = .neutral,
                    .body = display.title,
                }),
                .upgrade => |upgrade| {
                    var body: std.Io.Writer.Allocating = .init(app.alloc);
                    defer body.deinit();
                    try writeUpgradeNoticeBody(&body.writer, upgrade);
                    const owned_body = try body.toOwnedSlice();
                    defer app.alloc.free(owned_body);
                    try sink.appendNotice(.{
                        .topic = "",
                        .tone = .success,
                        .body = owned_body,
                    });
                },
            }
        }

        fn writeRecoveryCheckpointToSink(
            app: *App,
            sink: anytype,
            state: session_codec.DurableSessionState,
            labels: *HistoricalSessionLabels,
            recovery_decision: ?RecoveryAutoContinue,
        ) !void {
            const checkpoint = state.recovery_checkpoint orelse return;
            var has_prior_turns = false;
            for (state.history) |turn| switch (turn) {
                .compacted_summary => {},
                .assistant, .interrupted => {
                    has_prior_turns = true;
                    break;
                },
            };
            try sink.appendUserTurn(checkpoint.user, has_prior_turns);
            try writeExecutionHistoryToSink(app, sink, checkpoint.execution, labels);
            if (checkpoint.assistant_source.len > 0) {
                try writeAssistantHistoryMarkdownToSink(
                    app,
                    sink,
                    checkpoint.assistant_source,
                );
            }
            // A compaction_prepared checkpoint records completed source owned by
            // the compaction flow, not a turn waiting to run; it gets no recovery
            // notice and no automatic continuation. Only a checkpoint the gate
            // will actually auto-continue may promise one; a suppressed
            // checkpoint gets the gate's own notice below.
            const recovery_notice_suppressed = if (recovery_decision) |decision|
                decision != .auto_continue
            else
                checkpoint.cause == .compaction_prepared;
            if (!recovery_notice_suppressed) {
                // No attempt counts: there is no budget to count against.
                const recovery_notice: []const u8 = if (checkpoint.tool_state == .uncertain)
                    "model response recovery paused and continues automatically; inspect the uncertain tool state if anything looks wrong"
                else
                    "model response recovery paused and continues automatically";
                try sink.appendNotice(.{
                    .topic = "recovery",
                    .tone = .warning,
                    .body = recovery_notice,
                });
            }
        }

        fn replayHistory(app: *App, history: []const types.HistoryTurn) !void {
            var sink = LiveHistorySink(App){ .app = app };
            var labels = HistoricalSessionLabels{ .workspace_root = app.workspace_root };
            defer labels.deinit(app.alloc);
            return replayHistoryToSink(app, &sink, history, &labels);
        }

        fn replayHistoryToSink(
            app: *App,
            sink: anytype,
            history: []const types.HistoryTurn,
            labels: *HistoricalSessionLabels,
        ) !void {
            var has_prior_turns = false;
            return replayHistoryToSinkIncremental(app, sink, history, &has_prior_turns, labels);
        }

        fn replayHistoryToSinkIncremental(
            app: *App,
            sink: anytype,
            history: []const types.HistoryTurn,
            has_prior_turns: *bool,
            labels: *HistoricalSessionLabels,
        ) !void {
            for (history) |turn| {
                switch (turn) {
                    .compacted_summary => {},
                    .assistant => |entry| {
                        if (entry.execution.turn_summary) |summary| {
                            sink.setCreatedAtMs(summary.started_at_ms);
                        }
                        try sink.appendUserTurn(entry.user, has_prior_turns.*);
                        has_prior_turns.* = true;
                        try writeExecutionHistoryToSink(app, sink, entry.execution, labels);
                        if (entry.execution.turn_summary) |summary| {
                            sink.setCreatedAtMs(summary.completed_at_ms);
                        }
                        if (entry.assistant.len > 0) {
                            try writeAssistantHistoryMarkdownToSink(app, sink, entry.assistant);
                        }
                        if (entry.execution.turn_summary) |summary| {
                            try sink.appendTurnSummary(summary);
                        }
                    },
                    .interrupted => |entry| {
                        if (entry.execution.turn_summary) |summary| {
                            sink.setCreatedAtMs(summary.started_at_ms);
                        }
                        try sink.appendUserTurn(entry.user, has_prior_turns.*);
                        has_prior_turns.* = true;
                        try writeExecutionHistoryToSink(app, sink, entry.execution, labels);
                        if (entry.execution.turn_summary) |summary| {
                            sink.setCreatedAtMs(summary.completed_at_ms);
                        }
                        if (entry.assistant) |assistant| {
                            if (assistant.len > 0) try writeAssistantHistoryMarkdownToSink(app, sink, assistant);
                        }
                        if (entry.cancelled_command) |presentation| {
                            try writeCancelledCommandPresentation(app, sink, entry.tool_call.?, presentation, labels);
                        }
                        switch (entry.terminal_reason) {
                            .cancelled => if (entry.cancelled_command == null and entry.cancellation_origin == .turn) {
                                try sink.appendTurnCancellation();
                            },
                            .failed => try sink.appendNotice(
                                session_runtime.interruptedTurnNotice(entry),
                            ),
                        }
                        if (entry.execution.turn_summary) |summary| {
                            try sink.appendTurnSummary(summary);
                        }
                    },
                }
            }
        }

        /// Replay canonical session turns into a detached presentation using
        /// the exact same tool, message, markdown, diff, and command-output
        /// adapters as ordinary session resume.
        pub fn appendHistoryToDetachedProjection(
            app: *App,
            projection: anytype,
            history: []const types.HistoryTurn,
            has_prior_turns: *bool,
        ) !void {
            var labels = HistoricalSessionLabels{ .workspace_root = app.workspace_root };
            defer labels.deinit(app.alloc);
            var sink = DetachedHistorySink(@TypeOf(projection.*)){
                .app = app,
                .projection = projection,
                .labels = &labels,
            };
            return replayHistoryToSinkIncremental(
                app,
                &sink,
                history,
                has_prior_turns,
                &labels,
            );
        }

        fn writeCancelledCommandPresentation(
            app: *App,
            sink: anytype,
            call: types.ToolCall,
            presentation: types.CancelledCommandPresentation,
            labels: *HistoricalSessionLabels,
        ) !void {
            var action_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer mem_utils.deinit_arena(action_arena);
            const action = try app.describeToolActionDeniedWithAdvertised(
                action_arena.allocator(),
                call,
                historicalSessionTarget(action_arena.allocator(), labels, call),
                "Cancelled",
            );
            const entry_id = try writeCompletedToolStatus(sink, .cancelled, action);
            const replayed_output = try writeCommandReplay(
                app,
                sink,
                presentation.output_replay,
                call.id,
            );
            try sink.attachHistoricalCancelledCommandDetail(
                entry_id,
                call,
                presentation.command_artifact_handle,
                replayed_output,
            );
        }

        fn writeExecutionHistory(app: *App, execution: types.ExecutionMemory) !void {
            var sink = LiveHistorySink(App){ .app = app };
            var labels = HistoricalSessionLabels{ .workspace_root = app.workspace_root };
            defer labels.deinit(app.alloc);
            return writeExecutionHistoryToSink(app, &sink, execution, &labels);
        }

        fn writeExecutionHistoryToSink(
            app: *App,
            sink: anytype,
            execution: types.ExecutionMemory,
            labels: *HistoricalSessionLabels,
        ) !void {
            var steering_index: usize = 0;
            for (execution.tool_steps, 0..) |step, step_index| {
                try writePersistedSteeringAtBoundary(
                    app,
                    sink,
                    execution.steering,
                    &steering_index,
                    step_index,
                );
                if (step.assistant) |assistant| {
                    if (assistant.len > 0) try writeAssistantHistoryMarkdownToSink(app, sink, assistant);
                }

                for (step.tool_calls) |call| {
                    if (findPersistedToolResult(step.tool_results, call.id)) |result| {
                        try writeCompletedToolResult(app, sink, call, result, labels);
                        try writePermissionFeedback(sink, result.permission_feedback);
                    } else {
                        try writeUnreportedToolStatus(app, sink, call);
                    }
                }

                for (step.tool_results) |result| {
                    if (!hasPersistedToolCall(step.tool_calls, result.tool_call_id)) {
                        try writeUnpairedToolResult(app, sink, result);
                        try writePermissionFeedback(sink, result.permission_feedback);
                    }
                }
            }
            while (steering_index < execution.steering.len) : (steering_index += 1) {
                const steering = execution.steering[steering_index];
                if (steering.assistant_prefix) |prefix| {
                    if (prefix.len > 0) try writeAssistantHistoryMarkdownToSink(app, sink, prefix);
                }
                if (steering.text.len == 0) continue;
                try sink.appendUserTurn(.{ .text = steering.text }, true);
            }
        }

        fn writePersistedSteeringAtBoundary(
            app: *App,
            sink: anytype,
            steering: []const types.PersistedSteering,
            index: *usize,
            tool_step_count: usize,
        ) !void {
            while (index.* < steering.len and
                steering[index.*].after_tool_step_count == tool_step_count)
            {
                const item = steering[index.*];
                if (item.assistant_prefix) |prefix| {
                    if (prefix.len > 0) try writeAssistantHistoryMarkdownToSink(app, sink, prefix);
                }
                if (item.text.len > 0) {
                    try sink.appendUserTurn(.{ .text = item.text }, true);
                }
                index.* += 1;
            }
        }

        fn writePermissionFeedback(sink: anytype, feedback: []const []const u8) !void {
            for (feedback) |text| {
                if (text.len == 0) continue;
                try sink.appendUserTurn(.{
                    .text = @constCast(text),
                }, true);
            }
        }

        fn findPersistedToolResult(
            results: []const types.PersistedToolResult,
            tool_call_id: []const u8,
        ) ?types.PersistedToolResult {
            for (results) |result| {
                if (std.mem.eql(u8, result.tool_call_id, tool_call_id)) return result;
            }
            return null;
        }

        fn hasPersistedToolCall(
            calls: []const types.ToolCall,
            tool_call_id: []const u8,
        ) bool {
            for (calls) |call| {
                if (std.mem.eql(u8, call.id, tool_call_id)) return true;
            }
            return false;
        }

        fn writeCompletedToolResult(
            app: *App,
            sink: anytype,
            call: types.ToolCall,
            result: types.PersistedToolResult,
            labels: *HistoricalSessionLabels,
        ) !void {
            if (try writeAnsweredQuestionResult(app, sink, call, result)) return;
            if (try writeCommittedFilePresentation(app, sink, call, result)) return;

            const is_command = try captured_command.isToolCall(
                app.alloc,
                call.name,
                call.arguments_json,
            );
            const context_deferred = types.isContextDeferredToolResult(result);
            const deferred = types.isDeferredToolResult(result);
            const permission_denial_reason = tool_result_errors.toolPermissionDenialReason(result.output);

            var action_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer mem_utils.deinit_arena(action_arena);
            const session_target = historicalSessionTarget(action_arena.allocator(), labels, call);
            const command_decision = if (is_command)
                try tool_presentation.commandOutcomeDecision(
                    action_arena.allocator(),
                    result.command_process_presentation,
                )
            else
                null;
            const terminal_action_decision = if (std.mem.eql(u8, call.name, "terminal"))
                try tool_presentation.terminalActionOutcomeDecision(
                    action_arena.allocator(),
                    result.terminal_action_presentation,
                )
            else
                null;
            const outcome_decision = command_decision orelse terminal_action_decision;
            const formatted_action_base = if (deferred)
                try app.describeToolActionDeniedWithAdvertised(
                    action_arena.allocator(),
                    call,
                    session_target,
                    if (context_deferred)
                        types.context_deferred_tool_status_label
                    else
                        types.deferred_tool_result_output,
                )
            else if (permission_denial_reason) |reason|
                try app.describeToolActionDeniedWithAdvertised(
                    action_arena.allocator(),
                    call,
                    session_target,
                    tool_admission.permissionDeniedStatusLabel(reason),
                )
            else if (outcome_decision) |decision|
                try app.describeToolActionDeniedWithAdvertised(
                    action_arena.allocator(),
                    call,
                    session_target,
                    decision.label,
                )
            else if (try tooling_presentation.subagentStatusLine(action_arena.allocator(), call, result.output)) |line|
                line
            else if (result.status == .success) success: {
                var skill_name_buffer: [skill_contract.max_name_bytes]u8 = undefined;
                const registry = app.toolAdvertisementSet().registry;
                const display_target = target: {
                    const spec = registry.lookup(call.name) orelse break :target null;
                    if (spec.prepare_skill_call_fn == null) break :target null;
                    const args = tool_args.parseToolArgsObject(action_arena.allocator(), call.arguments_json) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => break :target null,
                    };
                    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
                    if (presentation.label_arg_kind != .name or
                        tool_dispatch.presentationLabelValue(presentation, args) != null) break :target null;
                    break :target skill_invocation.displayNameFromOutput(result.preview orelse result.output, &skill_name_buffer);
                };
                break :success try app.describeToolActionCompletedWithAdvertised(
                    action_arena.allocator(),
                    call,
                    display_target orelse session_target,
                );
            } else try app.describeToolActionDeniedWithAdvertised(
                action_arena.allocator(),
                call,
                session_target,
                try tooling_presentation.subagentFailureLabel(action_arena.allocator(), call, result.output),
            );
            const formatted_action = if (outcome_decision) |decision|
                if (decision.detail) |detail|
                    try action_arena.allocator().print(
                        "{s}: {s}",
                        .{ formatted_action_base, detail },
                    )
                else
                    formatted_action_base
            else
                formatted_action_base;
            const action = try app.alloc.dupe(u8, formatted_action);
            defer app.alloc.free(action);

            const outcome: types.ToolOutcomeKind = if (context_deferred)
                .deferred
            else if (deferred or permission_denial_reason != null)
                .denied
            else if (outcome_decision) |decision|
                decision.outcome
            else if (result.status == .success)
                .completed
            else
                .failed;
            // tty runs are not captured commands but still own a live session
            // with a launch command worth recording for later session rows.
            if (outcome == .completed and (is_command or std.mem.eql(u8, call.name, "shell"))) {
                try recordHistoricalSessionLabel(app, labels, call, result);
            }
            const entry_id = try writeCompletedToolStatus(
                sink,
                outcome,
                action,
            );
            if (!is_command or deferred or permission_denial_reason != null) {
                try sink.attachHistoricalToolDetail(entry_id, call, result);
                return;
            }
            if (!sink.materializeCommandReplay()) {
                try sink.attachHistoricalToolDetail(entry_id, call, result);
                return;
            }
            const wrote_command_output =
                try writeCommandReplay(
                    app,
                    sink,
                    result.command_output_replay,
                    result.tool_call_id,
                ) or
                try writeStoredCommandOutput(app, sink, result) or
                try writeSavedCommandOutput(sink, result.output);
            // Attach terminal detail after historical command chunks so typed
            // process presentation joins the existing block instead of
            // synthesizing a second, empty command-output block.
            if (wrote_command_output) {
                try sink.attachHistoricalToolDetailAfterCommandOutput(
                    entry_id,
                    call,
                    result,
                );
            } else {
                try sink.attachHistoricalToolDetail(entry_id, call, result);
            }
            if (wrote_command_output) {
                sink.attachHistoricalCommandOutput(entry_id);
                return;
            }

            debug_trace.logf(
                "session",
                "resume command replay fell back to raw result call_id={s}",
                .{result.tool_call_id},
            );
            try writeReplayResultFallback(sink, result.output);
        }

        fn writeCommandReplay(
            app: *App,
            sink: anytype,
            replay_value: ?types.CommandOutputReplay,
            call_id: []const u8,
        ) !bool {
            const replay = replay_value orelse return false;
            const descriptor = switch (replay) {
                .available => |value| value,
                .unavailable => {
                    debug_trace.logf(
                        "session",
                        "resume command replay unavailable call_id={s}",
                        .{call_id},
                    );
                    return false;
                },
            };
            if (app.session_persistence.writable == null) return false;
            const capability = activeChildCapability(app) catch |err| {
                debug_trace.logf(
                    "session",
                    "resume command replay capability unavailable handle_bytes={d} err={s}",
                    .{ descriptor.handle.len, @errorName(err) },
                );
                return false;
            };
            if (!validateCommandReplay(app.alloc, capability, descriptor)) {
                debug_trace.logf(
                    "session",
                    "resume command replay invalid handle_bytes={d}",
                    .{descriptor.handle.len},
                );
                return false;
            }

            var reader = command_replay_store.Reader.open(
                app.alloc,
                capability,
                descriptor,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "resume command replay reopen failed handle_bytes={d} err={s}",
                    .{ descriptor.handle.len, @errorName(err) },
                );
                return false;
            };
            defer reader.deinit();
            var wrote = false;
            while (try reader.next(app.alloc)) |frame| {
                defer app.alloc.free(frame.payload);
                try sink.appendCommandOutput(frame.stream, frame.payload);
                wrote = true;
            }
            if (wrote) try sink.finishCommandOutput();
            return wrote;
        }

        fn validateCommandReplay(
            alloc: Allocator,
            capability: *session_child_store.SessionChildCapability,
            descriptor: types.CommandOutputReplayDescriptor,
        ) bool {
            var reader = command_replay_store.Reader.open(
                alloc,
                capability,
                descriptor,
            ) catch return false;
            defer reader.deinit();
            while (reader.nextByte() catch return false) |_| {}
            return true;
        }

        /// Builds the full review of a resumed edit the first time it is
        /// opened, from the spilled snapshots. Runs at most once per entry. A
        /// missing or corrupt artifact leaves only the preview and never
        /// fails; the full-diff expansion is simply absent. The built diff is
        /// owned by `entry` and allocated with `std.heap.c_allocator`.
        pub fn materializeDeferredDiff(
            app: *App,
            entry: *diff.DiffEntry,
            styles: diff.FormatStyles,
        ) void {
            const deferred = entry.deferred orelse return;
            entry.deferred = null;
            defer deferred.deinit(std.heap.c_allocator);
            const capability = childCapability(app) orelse {
                debug_trace.logf(
                    "session",
                    "event=diff_content_unavailable call_id={s} reason=no_session",
                    .{deferred.call_id},
                );
                return;
            };
            var pack = result_store.loadDiffContentManaged(
                app.alloc,
                capability,
                deferred.call_id,
                deferred.content_handle,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=diff_content_unavailable call_id={s} err={s}; preview only",
                    .{ deferred.call_id, @errorName(err) },
                );
                return;
            };
            defer pack.deinit(app.alloc);
            const after = pack.after_content orelse return;
            entry.full = diff.formatFileChangeFullDiff(
                std.heap.c_allocator,
                pack.previous_content,
                .{ .after_content = after, .lifecycle_id = deferred.lifecycle_id },
                styles,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=diff_content_unavailable call_id={s} err={s}; preview only",
                    .{ deferred.call_id, @errorName(err) },
                );
                return;
            };
            debug_trace.logf(
                "session",
                "event=diff_content_loaded call_id={s} previous_bytes={d} after_bytes={d}",
                .{
                    deferred.call_id,
                    if (pack.previous_content) |content| content.len else 0,
                    after.len,
                },
            );
        }

        fn writeCommittedFilePresentation(
            app: *App,
            sink: anytype,
            call: types.ToolCall,
            result: types.PersistedToolResult,
        ) !bool {
            const presentation = result.committed_file_presentation orelse return false;
            if (result.status != .success or
                (!std.mem.eql(u8, result.tool_name, "write_file") and
                    !std.mem.eql(u8, result.tool_name, "edit_file")) or
                !@hasDecl(App, "preparePersistedFileDiff") or
                !@hasDecl(App, "registerAndEmitDiffBlock")) return false;

            // Spilled snapshots stay on disk: the transcript renders the inline
            // preview, and the full review is built only when it is opened.
            var deferred: ?diff.DeferredFullDiff = null;
            if (presentation.content_handle) |handle| {
                if (presentation.lifecycle_id) |lifecycle_id| {
                    if (presentation.previous_content == null or presentation.after_content == null) {
                        deferred = try diff.DeferredFullDiff.clone(
                            std.heap.c_allocator,
                            result.tool_call_id,
                            handle,
                            lifecycle_id,
                        );
                    }
                }
            }

            var payload = app.preparePersistedFileDiff(presentation) catch |err| {
                if (deferred) |value| value.deinit(std.heap.c_allocator);
                debug_trace.logf(
                    "session",
                    "resume committed file presentation unavailable call_id={s} err={s}",
                    .{ result.tool_call_id, @errorName(err) },
                );
                return false;
            };
            payload.deferred = deferred;
            var owns_payload = true;
            errdefer if (owns_payload) diff.freeDiffEntryPayload(std.heap.c_allocator, payload);

            var action_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer mem_utils.deinit_arena(action_arena);
            const base = try app.describeToolActionCompletedWithAdvertised(
                action_arena.allocator(),
                call,
                presentation.path,
            );
            const action = try tool_presentation.formatToolStatusWithStats(
                action_arena.allocator(),
                base,
                presentation.additions,
                presentation.deletions,
                .{
                    .added = ui_render.diff_added_marker_style,
                    .removed = ui_render.diff_removed_marker_style,
                },
            );
            const entry_id = try writeCompletedToolStatus(sink, .completed, action);
            try sink.appendDiff(payload);
            owns_payload = false;

            if (presentation.lifecycle_id) |lifecycle_id| {
                try sink.attachHistoricalToolDetailWithLifecycle(
                    entry_id,
                    call,
                    result,
                    lifecycle_id,
                );
                return true;
            }
            try sink.attachHistoricalToolDetail(entry_id, call, result);
            return true;
        }

        fn writeAnsweredQuestionResult(
            app: *App,
            sink: anytype,
            call: types.ToolCall,
            result: types.PersistedToolResult,
        ) !bool {
            if (result.status != .success or
                !std.mem.eql(u8, result.tool_name, "ask_user_question") or
                !@hasDecl(App, "writeHistoricalQuestionResolution")) return false;

            var answer_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer mem_utils.deinit_arena(answer_arena);
            const answers = (try question_answer.decodeJson(
                answer_arena.allocator(),
                result.output,
            )) orelse return false;

            const entry_id = try sink.appendQuestionResolution(answers);
            try sink.attachHistoricalToolDetail(entry_id, call, result);
            return true;
        }

        fn writeStoredCommandOutput(
            app: *App,
            sink: anytype,
            result: types.PersistedToolResult,
        ) !bool {
            const handle = result.output_handle orelse return false;
            if (app.session_persistence.writable == null) return false;
            const capability = activeChildCapability(app) catch |err| {
                debug_trace.logf(
                    "session",
                    "resume command replay could not open result handle={s} err={s}",
                    .{ handle, @errorName(err) },
                );
                return false;
            };
            const output = result_store.readForReplayManaged(
                app.alloc,
                capability,
                handle,
                result.stored_output_bytes,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "resume command replay could not read result handle={s} err={s}",
                    .{ handle, @errorName(err) },
                );
                return false;
            };
            defer app.alloc.free(output);
            return writeSavedCommandOutput(sink, output);
        }

        fn writeUnreportedToolStatus(
            app: *App,
            sink: anytype,
            call: types.ToolCall,
        ) !void {
            const status = try app.alloc.print(
                "● Tool completion was not reported: {s}",
                .{call.name},
            );
            defer app.alloc.free(status);
            const entry_id = try writeCompletedToolStatus(sink, .failed, status);
            try sink.attachHistoricalToolCallWithoutResult(entry_id, call);
        }

        fn writeUnpairedToolResult(
            app: *App,
            sink: anytype,
            result: types.PersistedToolResult,
        ) !void {
            const status = try app.alloc.print(
                "● {s} tool result: {s}",
                .{ @tagName(result.status), result.tool_name },
            );
            defer app.alloc.free(status);
            _ = try writeCompletedToolStatus(sink, switch (result.status) {
                .success => .completed,
                .failure => .failed,
            }, status);
            try writeReplayResultFallback(sink, result.output);
        }

        fn writeCompletedToolStatus(
            sink: anytype,
            kind: types.ToolOutcomeKind,
            status: []const u8,
        ) !u32 {
            return sink.appendToolStatus(kind, status);
        }

        fn writeSavedCommandOutput(sink: anytype, output: []const u8) !bool {
            var wrote = false;
            wrote = try writeCommandEnvelope(sink, output, "<stdout>\n", "\n</stdout>", .stdout) or wrote;
            wrote = try writeCommandEnvelope(sink, output, "<stderr>\n", "\n</stderr>", .stderr) or wrote;
            if (wrote) try sink.finishCommandOutput();
            return wrote;
        }

        fn writeCommandEnvelope(
            sink: anytype,
            output: []const u8,
            open: []const u8,
            close: []const u8,
            stream: command_output_content.Stream,
        ) !bool {
            const text = envelopeBody(output, open, close) orelse return false;
            if (text.len == 0) return false;
            var remaining = text;
            while (std.mem.findScalar(u8, remaining, '\n')) |newline_index| {
                try sink.appendCommandOutput(stream, remaining[0 .. newline_index + 1]);
                remaining = remaining[newline_index + 1 ..];
            }
            if (remaining.len > 0) try sink.appendCommandOutput(stream, remaining);
            return true;
        }

        fn envelopeBody(output: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
            const start = std.mem.find(u8, output, open) orelse return null;
            const body = output[start + open.len ..];
            const end = std.mem.find(u8, body, close) orelse return null;
            return body[0..end];
        }

        fn writeReplayResultFallback(sink: anytype, output: []const u8) !void {
            if (output.len == 0) return;
            try sink.appendRaw(output);
            if (!std.mem.endsWith(u8, output, "\n")) try sink.appendRaw("\n");
        }

        fn AssistantHistoryMarkdownReplay(comptime Sink: type) type {
            return struct {
                sink: *Sink,

                const Self = @This();

                fn flushText(self: *Self, out: *std.ArrayList(u8)) !void {
                    if (out.items.len == 0) return;
                    try self.sink.appendAssistantText(out.items);
                    out.clearRetainingCapacity();
                }

                fn deliverTable(
                    raw: *anyopaque,
                    table: assistant_presentation.TablePayload,
                    out: *std.ArrayList(u8),
                ) anyerror!void {
                    const self: *Self = @ptrCast(@alignCast(raw));
                    try self.flushText(out);
                    try self.sink.appendAssistantTable(table);
                }

                fn deliverCodeBlock(
                    raw: *anyopaque,
                    block: assistant_presentation.CodeBlockPayload,
                    out: *std.ArrayList(u8),
                ) anyerror!void {
                    const self: *Self = @ptrCast(@alignCast(raw));
                    try self.flushText(out);
                    try self.sink.appendAssistantCodeBlock(block);
                }

                fn deliverThematicRule(
                    raw: *anyopaque,
                    out: *std.ArrayList(u8),
                ) anyerror!void {
                    const self: *Self = @ptrCast(@alignCast(raw));
                    try self.flushText(out);
                    try self.sink.appendAssistantThematicRule();
                }
            };
        }

        fn writeAssistantHistoryMarkdown(app: *App, text: []const u8) !void {
            var sink = LiveHistorySink(App){ .app = app };
            return writeAssistantHistoryMarkdownToSink(app, &sink, text);
        }

        fn writeAssistantHistoryMarkdownToSink(
            app: *App,
            sink: anytype,
            text: []const u8,
        ) !void {
            var processor = assistant_presentation.MarkdownProcessor{};
            defer processor.deinit(app.alloc);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(app.alloc);
            const Sink = @TypeOf(sink.*);
            const Replay = AssistantHistoryMarkdownReplay(Sink);
            var replay = Replay{ .sink = sink };
            var table_completion = assistant_presentation.TableCompletion{
                .ctx = &replay,
                .deliver = Replay.deliverTable,
            };
            var code_completion = assistant_presentation.CodeBlockCompletion{
                .ctx = &replay,
                .deliver = Replay.deliverCodeBlock,
            };
            var thematic_rule_completion = assistant_presentation.ThematicRuleCompletion{
                .ctx = &replay,
                .deliver = Replay.deliverThematicRule,
            };
            const completions = assistant_presentation.MarkdownCompletions{
                .table = &table_completion,
                .code = &code_completion,
                .thematic_rule = &thematic_rule_completion,
            };

            try processor.pushWithCompletions(app.alloc, text, &out, completions);
            try processor.flushWithCompletions(app.alloc, &out, completions);
            try replay.flushText(&out);
            try sink.appendAssistantText("\n");
        }

        fn closeWritableSession(app: *App) void {
            app.session_persistence.resume_handoff_intent = .none;
            _ = closeWritableSessionWithResumeHandoff(app);
        }

        fn closeWritableSessionWithResumeHandoff(app: *App) ?ResumeHandoff {
            const handoff_intent = app.session_persistence.resume_handoff_intent;
            app.session_persistence.resume_handoff_intent = .none;
            if (comptime @hasField(@TypeOf(app.session), "usage")) {
                app.session.usage.cancelReconciliation();
                app.session.usage.finishProfilePublicationsBeforeShutdown();
                app.session.usage.configureCheckpointSink(null);
            }
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            app.session_persistence.remember_fresh_session = false;
            discardAnyPendingCancelledCommand(app, "writable_session_close");
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return null;
            var resume_boundary_valid = false;
            if (handoff_intent != .none) {
                var settlement_failed = false;
                settleDurableState(app, loaded) catch |err| {
                    settlement_failed = true;
                    recordShutdownFailure(app, err);
                    debug_trace.logf(
                        "session",
                        "resume handoff boundary invalid session={s} err={s}",
                        .{ loaded.active_id, @errorName(err) },
                    );
                };
                resume_boundary_valid = !settlement_failed;
            } else {
                settleDurableState(app, loaded) catch |err| {
                    recordShutdownFailure(app, err);
                    debug_trace.logf(
                        "session",
                        "final persistence settlement failed session={s} err={s}",
                        .{ loaded.active_id, @errorName(err) },
                    );
                };
            }
            const should_create_handoff = resume_boundary_valid and
                shouldCreateResumeHandoff(.{
                    .intent = handoff_intent,
                    .has_writable_session = true,
                    .is_pristine = session_store.isPristineStartedSession(loaded),
                });
            const handoff: ?ResumeHandoff = if (should_create_handoff) blk: {
                const session_id = app.alloc.dupe(u8, loaded.active_id) catch |err| {
                    debug_trace.logf(
                        "session",
                        "resume handoff unavailable session={s} err={s}",
                        .{ loaded.active_id, @errorName(err) },
                    );
                    break :blk null;
                };
                break :blk .{ .session_id = session_id };
            } else null;
            const discard_empty = handoff == null and discardableOnClose(app, loaded);
            if (comptime @hasDecl(
                @TypeOf(app.session),
                "clearWebFetchArtifacts",
            )) {
                app.session.clearWebFetchArtifacts();
            }
            disableSubagentHost(app);
            {
                if (discard_empty) {
                    if (app.session_persistence.store) |store| {
                        // Consumes `loaded` on every return; the store logs the disposition.
                        _ = store.discardPristineStartedSession(app.alloc, loaded);
                        app.session_persistence.writable = null;
                        return handoff;
                    }
                }
            }
            loaded.deinit(app.alloc);
            app.session_persistence.writable = null;
            return handoff;
        }

        /// A fresh interactive session that never received durable work has
        /// nothing to resume. Discarding it on close keeps each launch from
        /// leaving an empty session directory behind, matching `fx ask`.
        /// A user-chosen title is durable intent, so a renamed session stays.
        fn discardableOnClose(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
        ) bool {
            if (!session_store.isPristineStartedSession(loaded)) return false;
            const title = loaded.conversationTitle(app.alloc) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=pristine_session_discard disposition=retained reason=title_unreadable err={s}",
                    .{@errorName(err)},
                );
                return false;
            };
            if (title) |value| {
                app.alloc.free(value);
                return false;
            }
            return true;
        }

        fn configureWebFetchArtifacts(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
        ) void {
            if (comptime !@hasDecl(
                @TypeOf(app.session),
                "configureWebFetchArtifacts",
            )) return;

            const store = app.session_persistence.store orelse return;
            const session_dir = session_store.sessionDirPath(
                app.alloc,
                store.sessions_dir,
                loaded.active_id,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "interactive web fetch artifact setup failed session={s} err={s}",
                    .{ loaded.active_id, @errorName(err) },
                );
                app.session.clearWebFetchArtifacts();
                return;
            };
            defer app.alloc.free(session_dir);
            app.session.configureWebFetchArtifacts(app.alloc, session_dir);
        }

        fn enableSubagentHost(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
        ) void {
            disableSubagentHost(app);
            const store = if (app.session_persistence.store) |*value| value else return;
            app.session_persistence.subagent_host = subagent_tool_host.Runtime.create(
                app.alloc,
                store,
                loaded.active_id,
                subagentAuthorityResolver(app),
                if (comptime @hasDecl(App, "runSubagentChild"))
                    .{ .context = app, .run_fn = App.runSubagentChild }
                else
                    .{},
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "interactive subagent host unavailable session={s} err={s}",
                    .{ loaded.active_id, @errorName(err) },
                );
                return;
            };
        }

        fn subagentAuthorityResolver(app: *App) subagent_authority.HostResolver {
            return .{ .context = app, .resolve_fn = resolveSubagentAuthority };
        }

        fn resolveSubagentAuthority(
            raw: ?*anyopaque,
            alloc: Allocator,
            root_id: []const u8,
        ) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
            const app: *App = @ptrCast(@alignCast(raw.?));
            if (comptime @hasField(@TypeOf(app.permission_state), "authority_mutex")) {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            }
            defer if (comptime @hasField(@TypeOf(app.permission_state), "authority_mutex")) {
                app.permission_state.authority_mutex.unlock(io_mod.getIo());
            };
            const active_id = if (app.session_persistence.writable) |*value|
                value.active_id
            else
                return error.HostAuthorityUnavailable;
            if (!std.mem.eql(u8, active_id, root_id)) {
                return error.HostAuthorityUnavailable;
            }
            var permission_state = app.session.snapshotPermissionState(alloc) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.HostAuthorityUnavailable,
            };
            defer permission_state.deinit(alloc);
            return subagent_tool_host.captureHostAuthority(
                alloc,
                .{
                    .tool_set = app.toolAdvertisementSet(),
                    .mode = .full,
                },
                if (comptime @hasField(App, "permission_engine")) app.permission_engine.rules else .{},
                if (comptime @hasField(App, "permission_engine")) app.permission_engine.grants.items else &.{},
                permission_state,
            );
        }

        fn settleDurableState(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
        ) !void {
            try loaded.requireWritable();
            const usage_dirty = if (comptime @hasField(@TypeOf(app.session), "usage"))
                app.session.usage.isDirty()
            else
                false;
            if (usage_dirty) {
                var usage = try app.session.usage.snapshot(app.alloc);
                defer usage.deinit(app.alloc);
                _ = try loaded.appendEvent(
                    app.alloc,
                    .{ .usage_checkpointed = .{ .usage = usage } },
                    io_mod.milliTimestamp(),
                );
                app.session.usage.markClean(usage);
            }
        }

        pub fn commitContextCompaction(
            app: *App,
            summary: types.CompactedSummaryHistoryTurn,
            active_prefix: ?types.AssistantHistoryTurn,
            retained_from: ?types.ContextHistoryCut,
        ) !void {
            const prepared = try session_runtime.prepareCompactedHistory(app.alloc, app.session.agent.history.items, summary, retained_from orelse .{ .turns = history_range.rawHistoryTurnCount(app.session.agent.history.items) });
            var prepared_owned = true;
            defer if (prepared_owned) types.freeHistoryTurnSlice(app.alloc, prepared);
            if (comptime @hasField(App, "session_persistence")) {
                app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
                defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
                if (app.session_persistence.writable) |*loaded| {
                    _ = try loaded.commitContextCompaction(
                        app.alloc,
                        summary,
                        active_prefix,
                        retained_from,
                        io_mod.milliTimestamp(),
                    );
                }
            }
            app.session.commitCompactedHistory(app.alloc, prepared);
            prepared_owned = false;
        }

        pub fn commitPermissionState(
            app: *App,
            permission_state: session_permission_state.State,
        ) !void {
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return error.SessionPersistenceUnavailable;
            try loaded.replacePermissionState(
                app.alloc,
                permission_state,
                io_mod.milliTimestamp(),
            );
        }

        fn freshState(
            app: *App,
            preferences: session_codec.DurableSessionPreferences,
        ) !session_codec.DurableSessionState {
            const now = io_mod.milliTimestamp();
            const id = try session_store.generateSessionId(app.alloc);
            errdefer app.alloc.free(id);
            const origin = try app.alloc.dupe(u8, app.workspace_root);
            errdefer app.alloc.free(origin);
            const workspace = try app.alloc.dupe(u8, app.workspace_root);
            errdefer app.alloc.free(workspace);
            const owned_preferences = try preferences.dupe(app.alloc);
            errdefer {
                var value = owned_preferences;
                value.deinit(app.alloc);
            }
            const history = try app.alloc.alloc(types.HistoryTurn, 0);
            errdefer app.alloc.free(history);
            const permission_state = try app.session.snapshotPermissionState(app.alloc);
            errdefer {
                var value = permission_state;
                value.deinit(app.alloc);
            }
            const usage = try app.session.usage.snapshot(app.alloc);
            return .{
                .id = id,
                .origin_workspace_root = origin,
                .workspace_root = workspace,
                .created_at_ms = now,
                .updated_at_ms = now,
                .conversation_language = app.session.languageSnapshot(),
                .preferences = owned_preferences,
                .history = history,
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .permission_state = permission_state,
                .usage = usage,
            };
        }

        fn normalizeRecoveryUltrafastForProcessOverride(
            app: *App,
            resumed: *session_codec.DurableSessionState,
        ) void {
            const process_override = app.session_persistence.process_ultrafast_override;
            const local_changed = if (resumed.recovery_checkpoint) |*checkpoint|
                suppressRecoveryUltrafast(checkpoint, process_override)
            else
                false;

            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const durable_changed = if (app.session_persistence.writable) |*loaded|
                if (loaded.state.recovery_checkpoint) |*checkpoint|
                    suppressRecoveryUltrafast(checkpoint, process_override)
                else
                    false
            else
                false;
            if (local_changed or durable_changed) {
                debug_trace.logf(
                    "session",
                    "event=recovery_ultrafast_suppressed reason=explicit_process_disable",
                    .{},
                );
            }
        }

        fn restoreRuntimePreferences(
            app: *App,
            preferences: session_codec.DurableSessionPreferences,
        ) !void {
            const fast_mode_model_bound = restoredFastModeModelBound(
                app.session_persistence.fast_mode_model_bound,
                app.session_persistence.workspace_preferences,
                preferences,
            );
            if (app.session_persistence.process_provider_override) |override_provider| {
                // --provider pins the provider for this resumed launch; the
                // resolved model arrives through process_model_override below.
                try provider_runtime.replaceSelection(app, override_provider, preferences.model);
            } else if (config_runtime.providerEnvOverride() != null) {
                var settings = try config_runtime.loadMergedSettings(app.alloc, app.workspace_root);
                defer settings.deinit(app.alloc);
                const selected = settings.provider orelse return error.InvalidProviderValue;
                const model = settings.models.get(selected) orelse fallback: {
                    const seeded = app.session_persistence.workspace_preferences orelse return error.ConfiguredModelNotSelected;
                    if (!seeded.provider.eql(selected)) return error.ConfiguredModelNotSelected;
                    break :fallback seeded.model;
                };
                try provider_runtime.replaceSelection(app, selected, model);
            } else try provider_runtime.replaceSelection(app, preferences.provider, preferences.model);
            if (app.session_persistence.process_model_override) |model| {
                try provider_runtime.replaceModel(app, model);
            }
            try app.worker.syncQueuedPromptModel(
                std.heap.c_allocator,
                provider_runtime.model(app),
            );
            // Launch flags (fx --effort/--fast) win over the resumed session's
            // stored preferences for this launch, without rewriting them.
            const effective_effort = app.session_persistence.process_effort_override orelse preferences.effort;
            const effective_fast_mode = app.session_persistence.process_fast_override orelse preferences.fast_mode;
            const effective_ultrafast_mode = resolveUltrafastMode(
                preferences.ultrafast_mode,
                app.session_persistence.process_ultrafast_override,
            );
            app.effort = effective_effort;
            app.fast_mode = effective_fast_mode;
            app.session_persistence.fast_mode_model_bound = if (app.session_persistence.process_fast_override != null)
                effective_fast_mode
            else
                fast_mode_model_bound;
            app.worker.syncQueuedPromptEffort(effective_effort);
            app.worker.syncQueuedPromptFastMode(effective_fast_mode);
            app.worker.syncQueuedPromptUltrafastMode(effective_ultrafast_mode);
        }

        pub fn fastModeModelBound(app: *const App) bool {
            return app.session_persistence.fast_mode_model_bound;
        }

        fn applySessionPreferencePatch(
            app: *App,
            patch: SessionPreferencePatch,
        ) !void {
            try applyPreferencePatch(
                app.alloc,
                &app.session_persistence.session_preferences,
                patch,
            );
        }

        fn warnDegraded(app: *App, err: anyerror) !void {
            if (app.session_persistence.degraded_warning_emitted) {
                debug_trace.logf(
                    "session",
                    "canonical persistence remains degraded err={s}",
                    .{@errorName(err)},
                );
                return;
            }
            app.session_persistence.degraded_warning_emitted = true;
            try warnNonDurable(app, "session persistence degraded", err);
        }

        const RememberFailure = struct {
            id: [255]u8,
            len: usize,
            err: anyerror,
        };

        fn hasDurableUserWork(loaded: *const session_store.LoadedWritableSession) bool {
            return loaded.conversation_writer.last_seq != 0 or loaded.state.recovery_checkpoint != null;
        }

        fn rememberSession(app: *App, id: []const u8) ?RememberFailure {
            const store = app.session_persistence.store orelse return null;
            store.rememberSessionId(app.alloc, id) catch |err| {
                debug_trace.logf("session", "event=remember_session_failed id={s} err={s}", .{ id, @errorName(err) });
                var failure = RememberFailure{ .id = undefined, .len = id.len, .err = err };
                // Native loaded session IDs have already passed Store validation.
                @memcpy(failure.id[0..id.len], id);
                return failure;
            };
            return null;
        }

        fn rememberSelectedSession(app: *App) void {
            if (app.session_persistence.writable) |*loaded| {
                if (rememberSession(app, loaded.active_id)) |failure| reportRememberFailure(app, failure, false);
            }
        }

        fn reportRememberFailure(app: *App, failure: RememberFailure, comptime from_worker: bool) void {
            const alloc = std.heap.c_allocator;
            const body = alloc.print("Session saved, but could not remember it for -c ({s}). Resume with fx --resume {s}.", .{ @errorName(failure.err), failure.id[0..failure.len] }) catch return;
            defer alloc.free(body);
            const notice = types.SemanticNotice{ .topic = "session", .tone = .warning, .body = body };
            if (comptime @hasDecl(@TypeOf(app.worker), "pushEvent") and (from_worker or !@hasDecl(App, "writeDomainNotice"))) {
                app.worker.pushEvent(alloc, .{ .semantic_notice = notice }) catch |err| {
                    debug_trace.logf("session", "event=remember_warning_dropped err={s}", .{@errorName(err)});
                };
            } else {
                app.writeDomainNotice(notice, true) catch |err| {
                    debug_trace.logf("session", "event=remember_warning_dropped err={s}", .{@errorName(err)});
                };
            }
        }

        fn warnNonDurable(
            app: *App,
            label: []const u8,
            err: anyerror,
        ) !void {
            const notice = try app.alloc.print(
                "{s}: {s}; continuing non-durably",
                .{ label, @errorName(err) },
            );
            defer app.alloc.free(notice);
            try app.writeDomainNotice(.{
                .topic = "session",
                .tone = .warning,
                .body = notice,
            }, true);
        }
    };
}

fn replacePreferences(
    alloc: Allocator,
    target: *?session_codec.DurableSessionPreferences,
    source: session_codec.DurableSessionPreferences,
) !void {
    const replacement = try source.dupe(alloc);
    if (target.*) |*current| current.deinit(alloc);
    target.* = replacement;
}

/// The old durable event schema exact-matches preference keys. Omit only an
/// idempotent default-off patch; a stored true must receive an explicit false.
fn durableUltrafastEventDelta(stored: bool, requested: ?bool) ?bool {
    const value = requested orelse return null;
    return if (!value and !stored) null else value;
}

fn resolveUltrafastMode(preference: bool, process_override: ?bool) bool {
    return process_override orelse preference;
}

fn suppressRecoveryUltrafast(
    checkpoint: *session_codec.RecoveryCheckpoint,
    process_override: ?bool,
) bool {
    if (process_override != false) return false;
    const changed = checkpoint.requested_ultrafast_mode or checkpoint.ultrafast_mode;
    checkpoint.requested_ultrafast_mode = false;
    checkpoint.ultrafast_mode = false;
    return changed;
}

fn restoredFastModeModelBound(
    current_bound: bool,
    configured: ?session_codec.DurableSessionPreferences,
    restored: session_codec.DurableSessionPreferences,
) bool {
    if (!current_bound) return false;
    const current = configured orelse return false;
    return current.provider.same_authority(restored.provider) and
        std.mem.eql(u8, current.model, restored.model) and
        current.fast_mode == restored.fast_mode;
}

fn applyPreferencePatch(
    alloc: Allocator,
    target: *?session_codec.DurableSessionPreferences,
    patch: SessionPreferencePatch,
) !void {
    var current = target.* orelse return error.SessionPreferencesUnavailable;
    if (patch.provider) |provider| current.provider = provider;
    if (patch.model) |model| {
        const replacement = try alloc.dupe(u8, model);
        alloc.free(current.model);
        current.model = replacement;
    }
    if (patch.effort) |effort| current.effort = effort;
    if (patch.fast_mode) |fast_mode| current.fast_mode = fast_mode;
    if (patch.ultrafast_mode) |ultrafast_mode| current.ultrafast_mode = ultrafast_mode;
    target.* = current;
}

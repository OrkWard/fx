const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const core_types = @import("../shared/types.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const artifact_digest = @import("artifact_digest.zig");
const command_replay_store = @import("command_replay_store.zig");
const result_store = @import("result_store.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const catalog_cache = @import("session_catalog_cache.zig");
const session_child_store = @import("session_child_store.zig");
const relationship_index_codec = @import("session_relationship_index_codec.zig");
const session_json = @import("session_json.zig");
const session_layout = @import("session_layout.zig");
const session_log = @import("session_log.zig");
const session_replay = @import("session_replay.zig");
const session_projection = @import("session_projection.zig");
const session_usage = @import("session_usage.zig");
const session_usage_sidecar = @import("session_usage_sidecar.zig");
const subagent_child_state = @import("../subagent/child_state.zig");
const Allocator = std.mem.Allocator;

const authority_module = @import("session_authority.zig");
const discovery = @import("session_discovery.zig");
const migration = @import("session_migration.zig");
const paths = @import("session_store_paths.zig");
const store_types = @import("session_store_types.zig");
const summary_codec = @import("session_summary_codec.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const classifyAuthority = authority_module.classifyAuthority;
const classifyAuthorityAllowingLargeLegacy = authority_module.classifyAuthorityAllowingLargeLegacy;
const deleteSessionEntry = authority_module.deleteSessionEntry;
const openSessionFile = authority_module.openSessionFile;
const readExactLegacyFile = authority_module.readExactLegacyFile;
const requireAuthorityFenceAbsent = authority_module.requireAuthorityFenceAbsent;
const DiscoveryCandidateMetadata = discovery.DiscoveryCandidateMetadata;
const DiscoveryMode = discovery.DiscoveryMode;
const ReadOnlyCandidate = discovery.ReadOnlyCandidate;
const appendDoctorDiagnostic = discovery.appendDoctorDiagnostic;
const classifyReadOnlyCandidate = discovery.classifyReadOnlyCandidate;
const inspectDoctorSession = discovery.inspectDoctorSession;
const logDiscovery = discovery.logDiscovery;
const logDiscoveryError = discovery.logDiscoveryError;
const storageFormatForLegacy = discovery.storageFormatForLegacy;
const summaryFromState = discovery.summaryFromState;
const retired_latest_sessions_dir = "latest";
const recovery_staging_dir = "recovery+staging";
const recovery_staging_lock_file = "recovery-staging.lock";
const usage_recovery_dir = profile_paths.usage_recovery_dir_name;
const usage_recovery_marker_prefix = "v1 ";
const max_usage_recovery_marker_bytes =
    usage_recovery_marker_prefix.len + 20 + 1;
const max_usage_recovery_sessions: usize = 512;
const LegacyStoredSession = migration.LegacyStoredSession;
const MigrationPreferenceSource = migration.MigrationPreferenceSource;
const legacyToDurableState = migration.legacyToDurableState;
const loadSchemaV3ReadOnly = migration.loadSchemaV3ReadOnly;
const migrateLegacyLocked = migration.migrateLegacyLocked;
const migrateSchemaV3Locked = migration.migrateSchemaV3Locked;
const normalizeWorkspaceRoot = paths.normalizeWorkspaceRoot;
pub const sessionDirPath = paths.sessionDirPath;
pub const validateSessionId = paths.validateSessionId;
const validateWorkspaceRoot = paths.validateWorkspaceRoot;
pub const generateSessionId = paths.generateSessionId;
pub const CandidateStorage = store_types.CandidateStorage;
pub const DiscoveryCause = store_types.DiscoveryCause;
pub const DoctorDiagnostic = store_types.DoctorDiagnostic;
pub const DoctorInspectionResult = store_types.DoctorInspectionResult;
const DoctorInspectionOptions = store_types.DoctorInspectionOptions;
pub const DoctorIssueKind = store_types.DoctorIssueKind;
pub const LoadedWritableSession = store_types.LoadedWritableSession;
pub const MigrationOptions = store_types.MigrationOptions;
pub const ProjectionState = store_types.ProjectionState;

pub const UsageRecoverySession = struct {
    id: []u8,
    protected_updated_at_ms: ?i64,
    marker_modified_at_ns: i128 = 0,

    pub fn deinit(self: *UsageRecoverySession, alloc: Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }
};

pub const UsageRecoveryCheckpoint = struct {
    recovery_pending: bool,
    timestamp_ms: i64,
};

pub fn imageSnapshotStorageDir(
    alloc: Allocator,
    sessions_dir: ?[]const u8,
    session_id: ?[]const u8,
    temp_dir: *?[]u8,
) ![]u8 {
    if ((sessions_dir == null) != (session_id == null)) return error.InvalidSessionSnapshotOwner;
    if (sessions_dir) |root| {
        const durable_dir = try sessionDirPath(alloc, root, session_id.?);
        defer alloc.free(durable_dir);
        return std.Io.Dir.path.join(alloc, &.{ durable_dir, "images" });
    }
    if (temp_dir.* == null) {
        temp_dir.* = try image_attachments.createTempSnapshotDir(alloc);
    }
    return alloc.dupe(u8, temp_dir.*.?);
}
pub const ReadOnlyDetail = store_types.ReadOnlyDetail;
pub const ResumeOptions = store_types.ResumeOptions;
pub const ResumeTarget = store_types.ResumeTarget;
pub const SessionMigrationResult = store_types.SessionMigrationResult;
pub const SessionMigrationStatus = store_types.SessionMigrationStatus;
pub const SessionRecoveryResult = store_types.SessionRecoveryResult;
pub const SessionSummary = store_types.SessionSummary;
pub const HistoryPage = store_types.HistoryPage;

pub const LoadHistoryPageError = error{
    OutOfMemory,
    InvalidSessionId,
    InvalidHistoryPageLimit,
    InvalidHistoryPageCursor,
    StaleHistoryPageCursor,
    SessionNotFound,
    SessionPathUnsafe,
    SessionStoreUnavailable,
    UnsupportedSessionFormat,
    CorruptSession,
};

const HistoryPageCursor = struct {
    session_id: []const u8,
    history_len: usize,
    revision_ms: i64,
    prefix_digest: [32]u8,
    start: usize,
};

const ConversationHistoryPageCursor = struct {
    session_id: []const u8,
    history_len: usize,
    start: usize,
};

fn parseConversationHistoryPageCursor(
    raw: []const u8,
) LoadHistoryPageError!ConversationHistoryPageCursor {
    if (raw.len == 0 or raw.len > 512) return error.InvalidHistoryPageCursor;
    var fields = std.mem.splitScalar(u8, raw, ':');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidHistoryPageCursor, "v3")) {
        return error.InvalidHistoryPageCursor;
    }
    const session_id = fields.next() orelse return error.InvalidHistoryPageCursor;
    const history_len = std.fmt.parseInt(
        usize,
        fields.next() orelse return error.InvalidHistoryPageCursor,
        10,
    ) catch return error.InvalidHistoryPageCursor;
    const start = std.fmt.parseInt(
        usize,
        fields.next() orelse return error.InvalidHistoryPageCursor,
        10,
    ) catch return error.InvalidHistoryPageCursor;
    if (fields.next() != null or start > history_len) {
        return error.InvalidHistoryPageCursor;
    }
    validateSessionId(session_id) catch return error.InvalidHistoryPageCursor;
    return .{
        .session_id = session_id,
        .history_len = history_len,
        .start = start,
    };
}

fn formatConversationHistoryPageCursor(
    buffer: []u8,
    cursor: ConversationHistoryPageCursor,
) ![]u8 {
    return std.mem.print(buffer, "v3:{s}:{d}:{d}", .{
        cursor.session_id,
        cursor.history_len,
        cursor.start,
    });
}

fn parseHistoryPageCursor(raw: []const u8) LoadHistoryPageError!HistoryPageCursor {
    if (raw.len == 0 or raw.len > 512) return error.InvalidHistoryPageCursor;
    var fields = std.mem.splitScalar(u8, raw, ':');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidHistoryPageCursor, "v2")) return error.InvalidHistoryPageCursor;
    const session_id = fields.next() orelse return error.InvalidHistoryPageCursor;
    const history_len = std.fmt.parseInt(usize, fields.next() orelse return error.InvalidHistoryPageCursor, 10) catch return error.InvalidHistoryPageCursor;
    const revision_ms = std.fmt.parseInt(i64, fields.next() orelse return error.InvalidHistoryPageCursor, 10) catch return error.InvalidHistoryPageCursor;
    const digest_hex = fields.next() orelse return error.InvalidHistoryPageCursor;
    const start = std.fmt.parseInt(usize, fields.next() orelse return error.InvalidHistoryPageCursor, 10) catch return error.InvalidHistoryPageCursor;
    if (fields.next() != null) return error.InvalidHistoryPageCursor;
    if (digest_hex.len != 64 or revision_ms < 0 or start > history_len) return error.InvalidHistoryPageCursor;
    validateSessionId(session_id) catch return error.InvalidHistoryPageCursor;
    var prefix_digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&prefix_digest, digest_hex) catch return error.InvalidHistoryPageCursor;
    const cursor: HistoryPageCursor = .{ .session_id = session_id, .history_len = history_len, .revision_ms = revision_ms, .prefix_digest = prefix_digest, .start = start };
    var canonical: [512]u8 = undefined;
    const encoded = formatHistoryPageCursor(&canonical, cursor) catch return error.InvalidHistoryPageCursor;
    if (!std.mem.eql(u8, raw, encoded)) return error.InvalidHistoryPageCursor;
    return cursor;
}

fn formatHistoryPageCursor(buffer: []u8, cursor: HistoryPageCursor) ![]u8 {
    return std.mem.print(buffer, "v2:{s}:{d}:{d}:{x}:{d}", .{ cursor.session_id, cursor.history_len, cursor.revision_ms, cursor.prefix_digest, cursor.start });
}

fn duplicateHistoryPage(alloc: Allocator, turns: []const session.HistoryTurn) ![]session.HistoryTurn {
    const copy = try alloc.alloc(session.HistoryTurn, turns.len);
    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |turn| session.freeHistoryTurn(alloc, turn);
        alloc.free(copy);
    }
    for (turns) |turn| {
        copy[copied] = try session.dupeHistoryTurn(alloc, turn);
        copied += 1;
    }
    return copy;
}

fn latestCheckpointHistoryIndex(history: []const session.HistoryTurn) usize {
    var result: usize = 0;
    for (history, 0..) |turn, index| {
        if (turn == .compacted_summary) result = index;
    }
    return result;
}

fn historyPrefixDigest(turns: []const session.HistoryTurn) error{ WriteFailed, NoSpaceLeft, InvalidSessionFormat }![32]u8 {
    var buffer: [256]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&buffer);
    try hashing.writer.writeAll("fx.history-page-prefix.v2\x00");
    for (turns) |turn| {
        try session_codec.writeHistoryTurn(&hashing.writer, turn);
        // Canonical JSON never contains a literal NUL, so this makes the
        // concatenation unambiguous without introducing another serializer.
        try hashing.writer.writeByte(0);
    }
    try hashing.writer.flush();
    return hashing.hasher.finalResult();
}

fn mapHistoryPageLoadError(err: anyerror) LoadHistoryPageError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSessionId => error.InvalidSessionId,
        error.SessionNotFound => error.SessionNotFound,
        error.SessionPathUnsafe => error.SessionPathUnsafe,
        error.UnsupportedSessionFormat, error.UnsupportedSessionSchema => error.UnsupportedSessionFormat,
        error.InvalidSessionFormat,
        error.InvalidDurableField,
        error.InvalidDurableBytes,
        error.InvalidSessionIndex,
        => error.CorruptSession,
        // `loadReadOnly` intentionally has an inferred upstream error set.
        // Its uncategorized I/O and replay failures are unavailable storage,
        // never evidence that the committed session itself is corrupt.
        else => error.SessionStoreUnavailable,
    };
}

const HistoryPageWindow = struct {
    start: usize,
    end: usize,
};

fn selectHistoryPageWindow(history_len: usize, exclusive_end: usize, limit: usize) HistoryPageWindow {
    std.debug.assert(exclusive_end <= history_len);
    return .{ .start = exclusive_end -| limit, .end = exclusive_end };
}
pub const OpenSubagentControlError = error{
    OutOfMemory,
    InvalidSessionId,
    SessionNotFound,
    SessionPathUnsafe,
    SessionStoreUnavailable,
    PrivateStatePermissionsUnsupported,
    SessionChildStoreFailed,
};
pub const LoadSubagentBootstrapError = error{
    OutOfMemory,
    InvalidSessionId,
    SessionNotFound,
    SessionPathUnsafe,
    SessionMetadataUnavailable,
};
pub const ListSubagentControlIdsError = error{
    OutOfMemory,
    SessionStoreUnavailable,
};
pub const SubagentBootstrapMetadata = struct {
    name: []u8,
    preferences: session_codec.DurableSessionPreferences,

    pub fn deinit(self: *SubagentBootstrapMetadata, alloc: Allocator) void {
        alloc.free(self.name);
        self.preferences.deinit(alloc);
        self.* = undefined;
    }
};
pub const ResumableSessionContinuation = store_types.ResumableSessionContinuation;
pub const ResumableSessionPage = store_types.ResumableSessionPage;
pub const SessionListScope = store_types.SessionListScope;
pub const SessionListPage = store_types.SessionListPage;
pub const session_list_default_limit: usize = 100;
pub const session_list_max_limit: usize = 100;
/// Latest selection skips a candidate that vanished or moved between the index
/// read and the exact open; this bounds how many such races one resume absorbs.
const max_latest_selection_retries: usize = 3;
const ResumableSessionScope = enum {
    all_workspaces,
    current_workspace,
};
pub const StorageFormat = store_types.StorageFormat;
const automatic_legacy_max_bytes = store_types.automatic_legacy_max_bytes;
const StoreContext = store_types.StoreContext;
const freeSummaries = summary_codec.freeSummaries;
const resumablePageFromSummaries = summary_codec.resumablePageFromSummaries;
const sortSummariesNewestFirst = summary_codec.sortSummariesNewestFirst;

const SessionSummaryScan = struct {
    summaries: std.ArrayList(SessionSummary) = .empty,
    skipped_invalid: usize = 0,

    fn deinit(self: *SessionSummaryScan, alloc: Allocator) void {
        freeSummaries(alloc, &self.summaries);
        self.* = undefined;
    }
};

/// Borrows its store's directory handles. The caller owns each returned candidate.
pub const CandidateIterator = struct {
    store: Store,
    entries: ?std.Io.Dir.Iterator,
    mode: DiscoveryMode = .read_only_list,
    skipped_invalid: usize = 0,

    pub fn next(self: *CandidateIterator, alloc: Allocator) !?ReadOnlyCandidate {
        while (try self.nextName(null)) |name| {
            return self.store.readOnlyCandidate(alloc, name, null) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    logDiscoveryError(self.mode, name, null, null, err);
                    self.skipped_invalid += 1;
                    continue;
                },
            };
        }
        return null;
    }

    /// Returns an owned ID; callers sharing an iterator must serialize advancement.
    pub fn nextId(
        self: *CandidateIterator,
        alloc: Allocator,
        cancelled: ?*const std.atomic.Value(bool),
    ) !?[]u8 {
        const name = (try self.nextName(cancelled)) orelse return null;
        return try alloc.dupe(u8, name);
    }

    fn nextName(self: *CandidateIterator, cancelled: ?*const std.atomic.Value(bool)) !?[]const u8 {
        if (cancelled) |stop| {
            if (stop.load(.acquire)) return error.Cancelled;
        }
        const entries = if (self.entries) |*value| value else return null;
        while (true) {
            if (cancelled) |stop| {
                if (stop.load(.acquire)) return error.Cancelled;
            }
            const entry = (try entries.next(io_mod.getIo())) orelse return null;
            if (entry.kind != .directory or std.mem.eql(u8, entry.name, retired_latest_sessions_dir)) continue;
            validateSessionId(entry.name) catch continue;
            return entry.name;
        }
    }
};

fn retainWorkspaceSummaries(alloc: Allocator, summaries: *std.ArrayList(SessionSummary), workspace_root: []const u8) void {
    var write_index: usize = 0;
    for (summaries.items, 0..) |*summary, read_index| {
        const summary_workspace = summary.workspace_root orelse {
            summary.deinit(alloc);
            continue;
        };
        if (!std.mem.eql(u8, summary_workspace, workspace_root)) {
            summary.deinit(alloc);
            continue;
        }
        if (write_index != read_index) summaries.items[write_index] = summary.*;
        write_index += 1;
    }
    summaries.items.len = write_index;
}

pub const default_resume_page_limit: usize = 10;

fn openUsageRecoveryProfileRoot(
    home_path: []const u8,
) !?io_mod.VerifiedDir {
    const zio = io_mod.getIo();
    var home = try std.Io.Dir.openDirAbsolute(zio, home_path, .{
        .iterate = true,
    });
    defer home.close(zio);
    var profile = home.openDir(zio, profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir, error.SymLinkLoop => return error.InvalidUsageRecoveryIndex,
        else => return err,
    };
    errdefer profile.close(zio);
    const stat = try profile.stat(zio);
    if (stat.kind != .directory or
        stat.permissions.toMode() & 0o777 != 0o700)
    {
        return error.InvalidUsageRecoveryIndex;
    }
    return .{ .dir = profile };
}

fn openUsageRecoveryDir(
    home_path: []const u8,
) !?io_mod.VerifiedDir {
    var profile = try openUsageRecoveryProfileRoot(home_path) orelse return null;
    defer profile.close();
    var dir = profile.dir.openDir(io_mod.getIo(), usage_recovery_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir, error.SymLinkLoop => return error.InvalidUsageRecoveryIndex,
        else => return err,
    };
    errdefer dir.close(io_mod.getIo());
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or
        stat.permissions.toMode() & 0o777 != 0o700)
    {
        return error.InvalidUsageRecoveryIndex;
    }
    return .{ .dir = dir };
}

pub fn validateUsageRecoveryMarker(
    recovery: *const io_mod.VerifiedDir,
    session_id: []const u8,
) !?i64 {
    var marker = recovery.dir.openFile(io_mod.getIo(), session_id, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.UsageRecoveryMarkerNotFound,
        else => return error.InvalidUsageRecoveryIndex,
    };
    defer marker.close(io_mod.getIo());
    const stat = try marker.stat(io_mod.getIo());
    if (stat.kind != .file or
        stat.nlink != 1 or
        stat.size == 0 or
        stat.size > max_usage_recovery_marker_bytes or
        stat.permissions.toMode() & 0o777 != 0o600)
    {
        return error.InvalidUsageRecoveryIndex;
    }
    var bytes: [max_usage_recovery_marker_bytes]u8 = undefined;
    const marker_len: usize = @intCast(stat.size);
    const read = marker.readPositionalAll(
        io_mod.getIo(),
        bytes[0..marker_len],
        0,
    ) catch return error.InvalidUsageRecoveryIndex;
    if (read != marker_len) {
        return error.InvalidUsageRecoveryIndex;
    }
    const marker_bytes = bytes[0..marker_len];
    if (!std.mem.startsWith(
        u8,
        marker_bytes,
        usage_recovery_marker_prefix,
    ) or !std.mem.endsWith(u8, marker_bytes, "\n")) {
        return error.InvalidUsageRecoveryIndex;
    }
    const timestamp_bytes = marker_bytes[usage_recovery_marker_prefix.len .. marker_bytes.len - 1];
    if (timestamp_bytes.len == 0) return error.InvalidUsageRecoveryIndex;
    const timestamp_ms = std.fmt.parseInt(
        i64,
        timestamp_bytes,
        10,
    ) catch return error.InvalidUsageRecoveryIndex;
    if (timestamp_ms < 0) return error.InvalidUsageRecoveryIndex;
    return timestamp_ms;
}

pub const Store = struct {
    sessions_dir: []u8,
    home_dir: []u8,
    workspace_root: []u8,
    canonical_root: session_log.Root,
    // How many sessions one resume page yields before flagging `has_more`.
    // Carried on the value so it propagates through the by-value page chain;
    // the UI sets it from the visible screen height.
    resume_page_limit: usize = default_resume_page_limit,

    /// Narrow, copyable view of this store for the discovery/migration helpers,
    /// so they depend on `StoreContext` instead of the full facade.
    fn ctx(self: Store) StoreContext {
        return .{
            .sessions_dir = self.sessions_dir,
            .home_dir = self.home_dir,
            .workspace_root = self.workspace_root,
            .canonical_root = self.canonical_root,
        };
    }

    /// Opens a writable store rooted at `$HOME`, creating the layout if needed.
    pub fn init(alloc: Allocator, workspace_root: []const u8) !Store {
        const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
        return initWithHome(alloc, home, workspace_root, true);
    }

    /// Opens a read-only store rooted at `$HOME`; never creates layout.
    pub fn initReadOnly(alloc: Allocator, workspace_root: []const u8) !Store {
        const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
        return initWithHome(alloc, home, workspace_root, false);
    }

    /// Read-only store with an injected home directory (tests / non-HOME callers).
    pub fn initReadOnlyFromHome(
        alloc: Allocator,
        home_dir: []const u8,
        workspace_root: []const u8,
    ) !Store {
        return initWithHome(alloc, home_dir, workspace_root, false);
    }

    /// Opens the store using an injected home directory for tests.
    /// Writable store with an injected home directory (tests).
    pub fn initFromHome(alloc: Allocator, home_dir: []const u8, workspace_root: []const u8) !Store {
        return initWithHome(alloc, home_dir, workspace_root, true);
    }

    /// Frees store path strings.
    /// Frees the store path strings and the canonical root.
    pub fn deinit(self: *Store, alloc: Allocator) void {
        self.canonical_root.deinit(alloc);
        alloc.free(self.sessions_dir);
        alloc.free(self.home_dir);
        alloc.free(self.workspace_root);
        self.* = undefined;
    }

    /// Returns an owned ID, or null when this workspace has no remembered selection.
    /// Reading never creates profile state or enumerates sessions.
    pub fn readRememberedSessionId(self: Store, alloc: Allocator) !?[]u8 {
        var directory = (try self.openRememberedDirectory(false)) orelse return null;
        defer directory.close();
        const name = self.rememberedSessionFilename();
        const path_stat = directory.dir.statFile(io_mod.getIo(), &name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        if (path_stat.kind != .file) return error.InvalidRememberedSession;
        var file = directory.dir.openFile(io_mod.getIo(), &name, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        return try readRememberedSessionFile(alloc, &file);
    }

    fn readRememberedSessionFile(alloc: Allocator, file: *std.Io.File) ![]u8 {
        const stat = try file.stat(io_mod.getIo());
        // An atomic replacement can unlink the valid version already opened here.
        if (stat.kind != .file or stat.nlink > 1 or stat.permissions.toMode() & 0o777 != 0o600 or stat.size > 256) {
            return error.InvalidRememberedSession;
        }
        const bytes = try io_mod.readFileToEnd(alloc, file, 256);
        defer alloc.free(bytes);
        return try alloc.dupe(u8, try parseRememberedSessionId(bytes));
    }

    /// Publishes one interactive selection. Conversation writes retain their own lock.
    pub fn rememberSessionId(self: Store, alloc: Allocator, session_id: []const u8) !void {
        if (self.canonical_root.mode != .writable) return error.SessionStoreReadOnly;
        try validateSessionId(session_id);
        var directory = (try self.openRememberedDirectory(true)) orelse return error.SessionStoreUnavailable;
        defer directory.close();
        const name = self.rememberedSessionFilename();
        var buffer: [256]u8 = undefined;
        const bytes = try std.mem.print(&buffer, "{s}\n", .{session_id});
        try io_mod.durableReplaceVerified(alloc, &directory, &name, bytes);
    }

    fn rememberedSessionFilename(self: Store) [64]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(normalizeWorkspaceRoot(self.workspace_root), &digest, .{});
        return std.fmt.bytesToHex(digest, .lower);
    }

    fn openRememberedDirectory(self: Store, create: bool) !?io_mod.VerifiedDir {
        const zio = io_mod.getIo();
        var home = std.Io.Dir.openDirAbsolute(zio, self.home_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer home.close(zio);
        var profile = home.openDir(zio, profile_paths.root_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer profile.close(zio);
        if ((try profile.stat(zio)).permissions.toMode() & 0o777 != 0o700) return error.SessionPathUnsafe;
        if (create) return try io_mod.openOrCreateVerifiedPrivateDirFromDir(profile, "continue");
        var directory = profile.openDir(zio, "continue", .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        errdefer directory.close(zio);
        if ((try directory.stat(zio)).permissions.toMode() & 0o777 != 0o700) return error.SessionPathUnsafe;
        return .{ .dir = directory };
    }

    /// Starts a brand-new writable session from `state`, with default log options.
    pub fn startWritableSession(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
    ) !LoadedWritableSession {
        return self.startWritableSessionWithOptions(alloc, state, .{});
    }

    /// Starts a new conversation and attaches its writable managed-child
    /// capability. Caller owns the returned session.
    pub fn startWritableSessionWithOptions(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        options: session_log.Options,
    ) !LoadedWritableSession {
        var root = self.canonical_root;
        var loaded = try root.startConversationSession(
            alloc,
            state,
            options,
        );
        errdefer loaded.deinit(alloc);
        try self.attachWritableChildCapability(alloc, &loaded);
        return loaded;
    }

    fn startRecoveryStagedSession(
        self: Store,
        alloc: Allocator,
        staging_root: *session_log.Root,
        state: session_codec.DurableSessionState,
        options: session_log.Options,
    ) !LoadedWritableSession {
        var loaded = try staging_root.startConversationSession(alloc, state, options);
        errdefer loaded.deinit(alloc);
        try self.attachWritableChildCapability(alloc, &loaded);
        return loaded;
    }

    fn initRecoveryStagingRoot(
        self: Store,
        alloc: Allocator,
    ) !session_log.Root {
        var root = self.canonical_root;
        const sessions = &(root.sessions orelse
            return error.SessionStoreUnavailable);
        var staging = try io_mod.openOrCreateVerifiedPrivateDir(
            sessions,
            recovery_staging_dir,
        );
        errdefer staging.close();
        return .{
            .sessions = staging,
            .display_root = try std.Io.Dir.path.join(
                alloc,
                &.{ self.sessions_dir, recovery_staging_dir },
            ),
            .mode = .writable,
        };
    }

    fn deinitRecoveryStagingRoot(
        self: Store,
        alloc: Allocator,
        staging_root: *session_log.Root,
    ) void {
        staging_root.deinit(alloc);
        const sessions = &(self.canonical_root.sessions orelse return);
        sessions.dir.deleteDir(
            io_mod.getIo(),
            recovery_staging_dir,
        ) catch return;
        io_mod.syncVerifiedDir(sessions.dir) catch |err| {
            debug_trace.logf(
                "session",
                "event=recovery_staging_cleanup disposition=indeterminate err={s}",
                .{@errorName(err)},
            );
        };
    }

    fn acquireRecoveryStagingLock(
        self: Store,
        deadline_ms: u64,
    ) !io_mod.TimedAdvisoryLock {
        var root = self.canonical_root;
        const sessions = &(root.sessions orelse
            return error.SessionStoreUnavailable);
        return io_mod.acquireTimedAdvisoryLock(
            sessions,
            recovery_staging_lock_file,
            deadline_ms,
        ) catch |err| switch (err) {
            error.LockBusy => error.SessionBusy,
            error.LockUnsupported => error.SessionLockUnsupported,
            else => return err,
        };
    }

    fn cleanupAbandonedRecoveryStages(
        staging_root: *session_log.Root,
    ) !void {
        const staging = &(staging_root.sessions orelse
            return error.SessionStoreUnavailable);
        var entries = staging.dir.iterate();
        var changed = false;
        while (try entries.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            validateSessionId(entry.name) catch continue;
            try staging.dir.deleteTree(io_mod.getIo(), entry.name);
            changed = true;
            debug_trace.logf(
                "session",
                "event=recovery_staging_abandoned_target_removed",
                .{},
            );
        }
        if (changed) try io_mod.syncVerifiedDir(staging.dir);
    }

    fn promoteRecoveryStagedSession(
        self: Store,
        staging_root: *session_log.Root,
        session_id: []const u8,
    ) !RecoveryPromotionStatus {
        const staging = &(staging_root.sessions orelse
            return error.SessionStoreUnavailable);
        const sessions = &(self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable);
        try staging.dir.rename(
            session_id,
            sessions.dir,
            session_id,
            io_mod.getIo(),
        );
        io_mod.syncVerifiedDir(sessions.dir) catch
            return .indeterminate;
        io_mod.syncVerifiedDir(staging.dir) catch
            return .indeterminate;
        return .promoted;
    }

    /// Consumes `loaded` on every return.
    fn discardRecoveryStagedSession(
        staging_root: *session_log.Root,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
    ) PristineDiscardDisposition {
        defer loaded.deinit(alloc);
        if (staging_root.mode != .writable) {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=retained reason=guard_failed",
                .{},
            );
            return .retained;
        }
        const writer_belongs_to_store = loadedWriterBelongsToRoot(
            alloc,
            loaded,
            staging_root.display_root,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=retained reason=store_root_unverified err={s}",
                .{@errorName(err)},
            );
            return .retained;
        };
        if (!writer_belongs_to_store) {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=retained reason=store_root_mismatch",
                .{},
            );
            return .retained;
        }
        const sessions = &(staging_root.sessions orelse {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=indeterminate stage=sessions_root",
                .{},
            );
            return .indeterminate;
        });
        sessions.dir.deleteTree(io_mod.getIo(), loaded.active_id) catch |err| {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=indeterminate stage=delete err={s}",
                .{@errorName(err)},
            );
            return .indeterminate;
        };
        io_mod.syncVerifiedDir(sessions.dir) catch |err| {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=indeterminate stage=sync err={s}",
                .{@errorName(err)},
            );
            return .indeterminate;
        };
        debug_trace.logf(
            "session",
            "event=recovery_staging_discard disposition=discarded",
            .{},
        );
        return .discarded;
    }

    /// Consumes `loaded` on every return. A confirmed result means the canonical
    /// session directory was removed and the sessions parent was synced.
    pub fn discardPristineStartedSession(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
    ) PristineDiscardDisposition {
        if (!isPristineStartedSession(loaded)) {
            loaded.deinit(alloc);
            debug_trace.logf(
                "session",
                "event=pristine_session_discard disposition=retained reason=guard_failed",
                .{},
            );
            return .retained;
        }
        return self.deleteWriterOwnedSession(
            alloc,
            loaded,
            "pristine_session_discard",
            true,
        );
    }

    /// Consumes an exact writable session on every return. Policy checks such
    /// as terminal one-off admission remain with the caller that owns them.
    pub fn deleteCommittedSession(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
    ) PristineDiscardDisposition {
        return self.deleteWriterOwnedSession(
            alloc,
            loaded,
            "committed_session_delete",
            true,
        );
    }

    fn deleteWriterOwnedSession(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
        event_name: []const u8,
        cascade_children: bool,
    ) PristineDiscardDisposition {
        defer loaded.deinit(alloc);
        if (self.canonical_root.mode != .writable or
            !std.mem.eql(u8, self.workspace_root, loaded.state.workspace_root))
        {
            debug_trace.logf(
                "session",
                "event={s} disposition=retained reason=guard_failed",
                .{event_name},
            );
            return .retained;
        }
        const writer_belongs_to_store = loadedWriterBelongsToStore(
            self,
            alloc,
            loaded,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=retained reason=store_root_unverified err={s}",
                .{ event_name, @errorName(err) },
            );
            return .retained;
        };
        if (!writer_belongs_to_store) {
            debug_trace.logf(
                "session",
                "event={s} disposition=retained reason=store_root_mismatch",
                .{event_name},
            );
            return .retained;
        }
        const sessions = &(self.canonical_root.sessions orelse {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=sessions_root",
                .{event_name},
            );
            return .indeterminate;
        });
        if (cascade_children and !self.deleteOwnedSubagentChildren(
            alloc,
            loaded.active_id,
            event_name,
        )) {
            return .indeterminate;
        }
        sessions.dir.deleteTree(io_mod.getIo(), loaded.active_id) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=delete err={s}",
                .{ event_name, @errorName(err) },
            );
            return .indeterminate;
        };
        io_mod.syncVerifiedDir(sessions.dir) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=sync err={s}",
                .{ event_name, @errorName(err) },
            );
            return .indeterminate;
        };
        debug_trace.logf(
            "session",
            "event={s} disposition=discarded",
            .{event_name},
        );
        return .discarded;
    }

    fn deleteOwnedSubagentChildren(
        self: Store,
        alloc: Allocator,
        parent_id: []const u8,
        event_name: []const u8,
    ) bool {
        const children = self.loadOwnedSubagentChildIds(alloc, parent_id) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=child_index err={s}",
                .{ event_name, @errorName(err) },
            );
            return false;
        };
        defer {
            for (children) |child_id| alloc.free(child_id);
            if (children.len > 0) alloc.free(children);
        }
        for (children) |child_id| {
            if (!(self.childOwnerMatches(alloc, child_id, parent_id) catch |err| {
                debug_trace.logf(
                    "session",
                    "event={s} disposition=indeterminate stage=child_owner child_id={s} err={s}",
                    .{ event_name, child_id, @errorName(err) },
                );
                return false;
            })) {
                debug_trace.logf(
                    "session",
                    "event={s} disposition=indeterminate stage=child_owner child_id={s} err=OwnerMismatch",
                    .{ event_name, child_id },
                );
                return false;
            }
            var child = self.resumeForWrite(alloc, child_id) catch |err| switch (err) {
                error.SessionNotFound => continue,
                else => {
                    debug_trace.logf(
                        "session",
                        "event={s} disposition=indeterminate stage=child_resume child_id={s} err={s}",
                        .{ event_name, child_id, @errorName(err) },
                    );
                    return false;
                },
            };
            if (self.deleteWriterOwnedSession(
                alloc,
                &child,
                event_name,
                false,
            ) != .discarded) {
                return false;
            }
        }
        return true;
    }

    fn loadOwnedSubagentChildIds(
        self: Store,
        alloc: Allocator,
        parent_id: []const u8,
    ) ![][]u8 {
        var capability = try self.openSubagentControlCapabilityReadOnly(
            alloc,
            parent_id,
            .{},
        );
        defer capability.deinit();
        var file = capability.openFileReadOnly(
            alloc,
            .subagent_control,
            "children.json",
        ) catch |err| switch (err) {
            error.FileNotFound => return alloc.alloc([]u8, 0),
            else => return err,
        };
        defer file.deinit();
        const bytes = try file.readToEnd(alloc, 512 * 1024);
        defer alloc.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSubagentState;
        const stored_parent = parsed.value.object.get("parent_id") orelse
            return error.InvalidSubagentState;
        const children_value = parsed.value.object.get("children") orelse
            return error.InvalidSubagentState;
        if (stored_parent != .string or
            !std.mem.eql(u8, stored_parent.string, parent_id) or
            children_value != .array or children_value.array.items.len > 256)
        {
            return error.InvalidSubagentState;
        }
        const result = try alloc.alloc([]u8, children_value.array.items.len);
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |child_id| alloc.free(child_id);
            alloc.free(result);
        }
        for (children_value.array.items) |item| {
            if (item != .object) return error.InvalidSubagentState;
            const id = item.object.get("id") orelse return error.InvalidSubagentState;
            if (id != .string) return error.InvalidSubagentState;
            session_layout.validateSessionId(id.string) catch
                return error.InvalidSubagentState;
            result[initialized] = try alloc.dupe(u8, id.string);
            initialized += 1;
        }
        return result;
    }

    fn childOwnerMatches(
        self: Store,
        alloc: Allocator,
        child_id: []const u8,
        parent_id: []const u8,
    ) !bool {
        var capability = self.openSubagentControlCapabilityReadOnly(
            alloc,
            child_id,
            .{},
        ) catch |err| switch (err) {
            error.SessionNotFound => return true,
            else => return err,
        };
        defer capability.deinit();
        var file = try capability.openFileReadOnly(
            alloc,
            .subagent_control,
            "owner.json",
        );
        defer file.deinit();
        const bytes = try file.readToEnd(alloc, 4096);
        defer alloc.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const stored_parent = parsed.value.object.get("parent_id") orelse return false;
        return stored_parent == .string and
            std.mem.eql(u8, stored_parent.string, parent_id);
    }

    /// Resumes a specific session by id for writing, rebinding it to this store's
    /// workspace if needed.
    pub fn resumeForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !LoadedWritableSession {
        return self.resumeTargetForWrite(
            alloc,
            .{ .id = session_id },
            self.workspace_root,
            .{},
        );
    }

    /// Resumes a target (a specific id, or the latest) for writing under
    /// `workspace_root`, migrating legacy storage and recovering interrupted
    /// authority transitions as needed. Caller owns the returned session.
    pub fn resumeTargetForWrite(
        self: Store,
        alloc: Allocator,
        target: ResumeTarget,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        try validateWorkspaceRoot(workspace_root);
        const loaded = switch (target) {
            .id => |session_id| try self.resumeExactForWrite(
                alloc,
                session_id,
                workspace_root,
                true,
                options,
            ),
            .last => try self.resumeLatestByDiscovery(alloc, workspace_root, options),
        };
        return self.finishResumedForWrite(alloc, loaded, options);
    }

    fn finishResumedForWrite(
        self: Store,
        alloc: Allocator,
        loaded_value: LoadedWritableSession,
        _: ResumeOptions,
    ) !LoadedWritableSession {
        var loaded = loaded_value;
        errdefer loaded.deinit(alloc);
        const needs_permission_migration =
            loaded.state.permission_state.version !=
            session_permission_state.schema_version;
        if (needs_permission_migration) {
            var migrated_permission_state = try session_permission_state.migrateV1ToV2(
                alloc,
                loaded.state.permission_state,
            );
            defer migrated_permission_state.deinit(alloc);
            try loaded.replacePermissionState(
                alloc,
                migrated_permission_state,
                io_mod.milliTimestamp(),
            );
        }
        try self.attachWritableChildCapability(alloc, &loaded);
        return loaded;
    }

    /// Resumes the newest resumable session in `workspace_root`, taking
    /// candidates in the order and with the workspace filter of the index
    /// page `fx session last` reads. A listed session whose stale schema-v3
    /// log failed to replay in this listing is skipped without a second replay
    /// and counted as unreadable. A candidate that disappears or
    /// moves to another workspace between selection and open yields to the
    /// next newest, up to `max_latest_selection_retries`. Every other
    /// failure, including a busy session, is returned.
    fn resumeLatestByDiscovery(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var writer = catalog_cache.Writer.init(self) catch |err| blk: {
            debug_trace.logf("session", "latest selection index writer unavailable err={s}", .{@errorName(err)});
            break :blk null;
        };
        defer if (writer) |*value| value.deinit();
        var catalog = try catalog_cache.listActionableCatalog(
            self,
            alloc,
            null,
            null,
            if (writer) |*value| value else null,
        );
        defer catalog.deinit(alloc);
        var vanished: usize = 0;
        var unreadable = catalog.skipped_invalid;
        for (catalog.summaries.items) |summary| {
            const summary_workspace = summary.workspace_root orelse continue;
            if (!std.mem.eql(u8, summary_workspace, workspace_root)) continue;
            if (catalog.isUnreplayable(summary.id)) {
                debug_trace.logf("session", "latest selection skipped unreplayable id={s}", .{summary.id});
                unreadable += 1;
                continue;
            }
            if (self.resumeLatestCandidate(alloc, summary.id, workspace_root, options)) |loaded| {
                return loaded;
            } else |err| switch (err) {
                error.SessionNotFound, error.FileNotFound, error.SessionTargetChanged => {
                    logDiscoveryError(.workspace_writable_last, summary.id, null, null, err);
                    vanished += 1;
                    if (vanished == max_latest_selection_retries) return err;
                },
                else => {
                    logDiscoveryError(.workspace_writable_last, summary.id, null, null, err);
                    return err;
                },
            }
        }
        if (unreadable > 0) return session_log.failLoadedWritableSession(error.NoReadableSessions);
        return session_log.failLoadedWritableSession(error.NoSavedSessions);
    }

    /// Opens one latest-selection candidate, retrying a namespace loss once:
    /// recovering an interrupted upgrade moves files under the first attempt,
    /// and the second attempt sees the settled directory.
    fn resumeLatestCandidate(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        return self.openLatestCandidate(alloc, session_id, workspace_root, options) catch |err| switch (err) {
            error.SessionNotFound, error.FileNotFound, error.SessionTargetChanged => self.openLatestCandidate(alloc, session_id, workspace_root, options),
            else => err,
        };
    }

    /// The test barrier marks the window in which the candidate can vanish or
    /// move between the index read and the open.
    fn openLatestCandidate(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        try options.log.test_controls.boundary(.latest_barrier_completed);
        return self.resumeExactForWrite(alloc, session_id, workspace_root, false, options);
    }

    /// Loads a session's full durable state read-only. Caller owns the state.
    pub fn loadReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_codec.DurableSessionState {
        var detail = try self.loadReadOnlyDetail(alloc, session_id, .{});
        detail.summary.deinit(alloc);
        const state = detail.state;
        detail.state = undefined;
        return state;
    }

    /// Replays complete canonical conversation turns without retaining the archive.
    /// The visitor borrows each turn only for the duration of append().
    pub fn visitConversationHistory(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        visitor: anytype,
    ) !void {
        try validateSessionId(session_id);
        var dir = try self.openSessionDir(session_id);
        defer dir.close();
        var buffer: [8192]u8 = undefined;
        var reader = try session_log.ConversationHistoryReader.init(alloc, &dir, &buffer);
        defer reader.deinit();
        while (try reader.next()) |turn| {
            var turns = [_]session.HistoryTurn{turn};
            defer session.freeHistoryTurn(alloc, turns[0]);
            try resolveSessionSnapshotLocators(alloc, &turns, null, self.sessions_dir, session_id);
            try visitor.append(turns[0]);
        }
    }

    /// Reads the child identity a legacy session records in its first event,
    /// for a session discovery classified as legacy. The event is read only
    /// within a small fixed bound, so listing never scans a log.
    pub fn loadListedLegacyChildIdentity(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !bool {
        return self.canonical_root.loadListedLegacyChildIdentity(alloc, session_id);
    }

    /// Reads one bounded chronological history page without acquiring the
    /// session writer lock. The cursor is opaque and anchored to the history
    /// length that produced it, so later appends cannot duplicate older pages.
    pub fn loadHistoryPage(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        cursor: ?[]const u8,
        limit: usize,
    ) LoadHistoryPageError!store_types.HistoryPage {
        validateSessionId(session_id) catch return error.InvalidSessionId;
        if (limit == 0 or limit > 100) return error.InvalidHistoryPageLimit;
        if (cursor) |raw| {
            if (std.mem.startsWith(u8, raw, "v3:")) {
                _ = try parseConversationHistoryPageCursor(raw);
            } else {
                _ = try parseHistoryPageCursor(raw);
            }
        }
        var session_dir = self.openSessionDir(session_id) catch |err|
            return mapHistoryPageLoadError(err);
        defer session_dir.close();
        if (session_log.hasConversationMetadata(alloc, &session_dir) catch |err|
            return mapHistoryPageLoadError(err))
        {
            var candidate = classifyReadOnlyCandidate(
                alloc,
                &session_dir,
                session_id,
            ) catch |err| return mapHistoryPageLoadError(err);
            defer candidate.deinit(alloc);
            const snapshot = if (cursor) |raw|
                try parseConversationHistoryPageCursor(raw)
            else
                ConversationHistoryPageCursor{
                    .session_id = candidate.summary.id,
                    .history_len = candidate.summary.history_len,
                    .start = candidate.summary.history_len,
                };
            if (!std.mem.eql(u8, snapshot.session_id, session_id)) {
                return error.InvalidHistoryPageCursor;
            }
            if (snapshot.history_len > candidate.summary.history_len) {
                return error.StaleHistoryPageCursor;
            }
            const window = selectHistoryPageWindow(
                snapshot.history_len,
                snapshot.start,
                limit,
            );
            const turns = session_log.loadConversationHistoryRange(
                alloc,
                &session_dir,
                window.start,
                window.end,
            ) catch |err| return mapHistoryPageLoadError(err);
            errdefer session.freeHistoryTurnSlice(alloc, turns);
            resolveSessionSnapshotLocators(
                alloc,
                turns,
                null,
                self.sessions_dir,
                session_id,
            ) catch |err| return mapHistoryPageLoadError(err);
            const next_cursor = if (window.start > 0) blk: {
                var encoded: [512]u8 = undefined;
                const raw = formatConversationHistoryPageCursor(&encoded, .{
                    .session_id = session_id,
                    .history_len = snapshot.history_len,
                    .start = window.start,
                }) catch return error.SessionStoreUnavailable;
                break :blk try alloc.dupe(u8, raw);
            } else null;
            errdefer if (next_cursor) |value| alloc.free(value);
            return .{
                .session_id = try alloc.dupe(u8, session_id),
                .revision_ms = candidate.summary.updated_at_ms,
                .history_len = snapshot.history_len,
                .turns = turns,
                .next_cursor = next_cursor,
            };
        }
        const position = if (cursor) |raw| try parseHistoryPageCursor(raw) else null;
        if (position) |value| {
            if (!std.mem.eql(u8, value.session_id, session_id)) return error.InvalidHistoryPageCursor;
        }

        var state = self.loadReadOnly(alloc, session_id) catch |err| return mapHistoryPageLoadError(err);
        defer state.deinit(alloc);

        const snapshot: HistoryPageCursor = if (position) |value| blk: {
            if (value.history_len > state.history.len)
                return error.StaleHistoryPageCursor;
            const digest = historyPrefixDigest(state.history[0..value.history_len]) catch return error.SessionStoreUnavailable;
            if (!std.mem.eql(u8, &value.prefix_digest, &digest)) return error.StaleHistoryPageCursor;
            break :blk value;
        } else .{
            .session_id = state.id,
            .history_len = state.history.len,
            .revision_ms = state.updated_at_ms,
            .prefix_digest = historyPrefixDigest(state.history) catch return error.SessionStoreUnavailable,
            .start = state.history.len,
        };
        const window = selectHistoryPageWindow(state.history.len, snapshot.start, limit);
        const turns = try duplicateHistoryPage(alloc, state.history[window.start..window.end]);
        errdefer session.freeHistoryTurnSlice(alloc, turns);
        const next_cursor = if (window.start > 0) blk: {
            var encoded: [512]u8 = undefined;
            const raw = formatHistoryPageCursor(&encoded, .{
                .session_id = snapshot.session_id,
                .history_len = snapshot.history_len,
                .revision_ms = snapshot.revision_ms,
                .prefix_digest = snapshot.prefix_digest,
                .start = window.start,
            }) catch return error.SessionStoreUnavailable;
            break :blk try alloc.dupe(u8, raw);
        } else null;
        errdefer if (next_cursor) |value| alloc.free(value);
        return .{
            .session_id = try alloc.dupe(u8, state.id),
            .revision_ms = snapshot.revision_ms,
            .history_len = snapshot.history_len,
            .turns = turns,
            .next_cursor = next_cursor,
        };
    }

    /// Opens read-only managed-child storage for a session, validating it loads.
    pub fn openChildCapabilityReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_child_store.SessionChildCapability {
        var detail = try self.loadReadOnlyDetail(alloc, session_id, .{});
        detail.deinit(alloc);

        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        const display_path = try sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        );
        defer alloc.free(display_path);
        return session_child_store.SessionChildCapability.init(
            alloc,
            session_dir.dir,
            display_path,
            .read_only,
        );
    }

    /// Opens child storage for a session id that was already accepted by list
    /// or another caller-owned read-only selection. This avoids replaying the
    /// canonical event log when only managed child routes are needed.
    pub fn openListedChildCapabilityReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_child_store.SessionChildCapability {
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        const display_path = try sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        );
        defer alloc.free(display_path);
        return session_child_store.SessionChildCapability.init(
            alloc,
            session_dir.dir,
            display_path,
            .read_only,
        );
    }

    /// Opens verified read-only storage restricted to subagent control files.
    /// The caller has already classified the session; no history is replayed.
    pub fn openListedSubagentControlReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !?session_child_store.SessionChildCapability {
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        const display = try sessionDirPath(alloc, self.sessions_dir, session_id);
        defer alloc.free(display);
        return session_child_store.SessionChildCapability.initLegacySubagentControl(alloc, session_dir.dir, display);
    }

    /// Opens verified read-only storage restricted to subagent control files.
    pub fn openSubagentControlCapabilityReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: session_child_store.Options,
    ) OpenSubagentControlError!session_child_store.SessionChildCapability {
        return self.openSubagentControlCapabilityMode(
            alloc,
            session_id,
            .read_only,
            options,
        );
    }

    /// Opens verified writable storage restricted to subagent control files.
    /// The returned capability never owns `session.lock` and cannot mutate the
    /// transcript or any other managed-child route.
    pub fn openSubagentControlCapabilityWritable(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: session_child_store.Options,
    ) OpenSubagentControlError!session_child_store.SessionChildCapability {
        if (self.canonical_root.mode != .writable) return error.SessionStoreUnavailable;
        return self.openSubagentControlCapabilityMode(
            alloc,
            session_id,
            .writable,
            options,
        );
    }

    fn openSubagentControlCapabilityMode(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        mode: session_child_store.Mode,
        options: session_child_store.Options,
    ) OpenSubagentControlError!session_child_store.SessionChildCapability {
        validateSessionId(session_id) catch return error.InvalidSessionId;

        var session_dir = self.openSessionDir(session_id) catch |err| return switch (err) {
            error.InvalidSessionId => error.InvalidSessionId,
            error.SessionNotFound => error.SessionNotFound,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            else => error.SessionStoreUnavailable,
        };
        defer session_dir.close();
        validateSubagentControlSession(alloc, &session_dir, session_id) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionNotFound => error.SessionNotFound,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            else => error.SessionStoreUnavailable,
        };
        const display_path = sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSessionId => error.InvalidSessionId,
        };
        defer alloc.free(display_path);
        return session_child_store.SessionChildCapability.initSubagentControl(
            alloc,
            session_dir.dir,
            display_path,
            mode,
            options,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported => error.PrivateStatePermissionsUnsupported,
            error.SessionChildStoreFailed => error.SessionChildStoreFailed,
        };
    }

    fn validateSubagentControlSession(
        alloc: Allocator,
        session_dir: *io_mod.VerifiedDir,
        session_id: []const u8,
    ) !void {
        if (try session_log.readConversationMetadata(alloc, session_dir)) |value| {
            var metadata = value;
            defer metadata.deinit();
            if (!std.mem.eql(u8, metadata.value.id, session_id)) return error.InvalidSessionFormat;
            _ = try session.ConversationLanguage.fromSlice(metadata.value.conversation_language);
            const event_stat = try session_dir.dir.statFile(io_mod.getIo(), "events.jsonl", .{ .follow_symlinks = false });
            if (event_stat.kind != .file or event_stat.nlink != 1) return error.SessionPathUnsafe;
            return;
        }
        var candidate = try classifyReadOnlyCandidate(alloc, session_dir, session_id);
        candidate.deinit(alloc);
    }

    /// Returns owned session metadata needed to initialize a control record.
    /// This validates ordinary-session visibility without replaying transcript history.
    pub fn loadSubagentBootstrapMetadata(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) LoadSubagentBootstrapError!SubagentBootstrapMetadata {
        validateSessionId(session_id) catch return error.InvalidSessionId;
        var session_dir = self.openSessionDir(session_id) catch |err| return switch (err) {
            error.InvalidSessionId => error.InvalidSessionId,
            error.SessionNotFound => error.SessionNotFound,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            else => error.SessionMetadataUnavailable,
        };
        defer session_dir.close();
        var candidate = classifyReadOnlyCandidate(
            alloc,
            &session_dir,
            session_id,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionNotFound => error.SessionNotFound,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            else => error.SessionMetadataUnavailable,
        };
        defer candidate.deinit(alloc);

        const name_source = candidate.summary.title orelse session_id;
        const name = try alloc.dupe(u8, name_source);
        errdefer alloc.free(name);
        return .{
            .name = name,
            .preferences = switch (candidate.storage) {
                .conversation => self.loadConversationPreferences(
                    alloc,
                    &session_dir,
                    session_id,
                ) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.SessionNotFound => error.SessionNotFound,
                    error.SessionPathUnsafe => error.SessionPathUnsafe,
                    else => error.SessionMetadataUnavailable,
                },
                .schema_v3 => self.loadSubagentManifestPreferences(
                    alloc,
                    &session_dir,
                    session_id,
                ) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.SessionNotFound => error.SessionNotFound,
                    error.SessionPathUnsafe => error.SessionPathUnsafe,
                    else => error.SessionMetadataUnavailable,
                },
                .legacy_v1, .legacy_v2 => self.loadSubagentLegacyPreferences(
                    alloc,
                    candidate.summary.workspace_root orelse self.workspace_root,
                ) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.SessionMetadataUnavailable,
                },
            },
        };
    }

    fn loadConversationPreferences(
        self: Store,
        alloc: Allocator,
        session_dir: *io_mod.VerifiedDir,
        session_id: []const u8,
    ) !session_codec.DurableSessionPreferences {
        _ = self;
        var file = openSessionFile(session_dir, "session.json", .read_only) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        const bytes = try io_mod.readFileToEnd(
            alloc,
            &file,
            session_codec.max_session_metadata_bytes,
        );
        defer alloc.free(bytes);
        var metadata = try session_codec.decodeSessionMetadata(alloc, bytes);
        defer metadata.deinit();
        if (!std.mem.eql(u8, metadata.value.id, session_id)) {
            return error.InvalidSessionMetadata;
        }
        return .{
            .provider = model_provider.parse(metadata.value.provider) orelse
                return error.InvalidSessionMetadata,
            .model = try alloc.dupe(u8, metadata.value.model),
            .effort = core_types.ReasoningEffort.parse(metadata.value.effort) orelse
                return error.InvalidSessionMetadata,
            .fast_mode = metadata.value.fast_mode,
            .ultrafast_mode = metadata.value.ultrafast_mode orelse false,
        };
    }

    fn loadSubagentManifestPreferences(
        self: Store,
        alloc: Allocator,
        session_dir: *io_mod.VerifiedDir,
        session_id: []const u8,
    ) !session_codec.DurableSessionPreferences {
        _ = self;
        var file = openSessionFile(session_dir, "session.json", .read_only) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        const bytes = try io_mod.readFileToEnd(
            alloc,
            &file,
            session_projection.manifest_max_bytes,
        );
        defer alloc.free(bytes);
        var manifest = try session_projection.decodeManifest(alloc, bytes);
        defer manifest.deinit(alloc);
        if (!std.mem.eql(u8, manifest.id, session_id)) return error.InvalidSessionFormat;
        return manifest.preferences.dupe(alloc);
    }

    fn loadSubagentLegacyPreferences(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
    ) !session_codec.DurableSessionPreferences {
        var detailed = try config_runtime.loadMergedSettingsDetailedFromHome(
            alloc,
            self.home_dir,
            workspace_root,
        );
        defer detailed.deinit(alloc);
        return .{
            .model = try alloc.dupe(
                u8,
                detailed.settings.models.get(.gateway) orelse "anthropic/claude-opus-4.7",
            ),
            .effort = detailed.settings.effort orelse .auto,
            .fast_mode = detailed.settings.fast_mode orelse false,
            .ultrafast_mode = detailed.settings.ultrafast_mode orelse false,
        };
    }

    fn attachWritableChildCapability(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
    ) !void {
        const display_path = try sessionDirPath(
            alloc,
            self.sessions_dir,
            loaded.active_id,
        );
        defer alloc.free(display_path);
        const capability = try alloc.create(
            session_child_store.SessionChildCapability,
        );
        errdefer alloc.destroy(capability);
        capability.* = try session_child_store.SessionChildCapability.init(
            alloc,
            loaded.log.dir.dir,
            display_path,
            .writable,
        );
        loaded.child_capability = capability;
    }

    /// Loads a session's summary, state, and storage format read-only, handling
    /// both schema-v3 and legacy snapshots. Caller owns the returned detail.
    pub fn loadReadOnlyDetail(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: ResumeOptions,
    ) !ReadOnlyDetail {
        return self.loadReadOnlyDetailWithHistoryErrors(alloc, session_id, options, false);
    }

    /// Loads detail with a distinct history error for external admission.
    /// Supporting-file failures and ordinary read-only loads retain their errors.
    pub fn loadReadOnlyAdmissionDetail(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: ResumeOptions,
    ) !ReadOnlyDetail {
        return self.loadReadOnlyDetailWithHistoryErrors(alloc, session_id, options, true);
    }

    fn loadReadOnlyDetailWithHistoryErrors(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: ResumeOptions,
        comptime classify_history_errors: bool,
    ) !ReadOnlyDetail {
        try validateSessionId(session_id);
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        if (try session_log.hasConversationMetadata(alloc, &session_dir)) {
            var state = if (classify_history_errors)
                try session_log.loadConversationDetailState(alloc, &session_dir, session_id)
            else blk: {
                var root = self.canonical_root;
                break :blk try root.loadReadOnly(alloc, session_id, options.log);
            };
            errdefer state.deinit(alloc);
            const archive = try session_log.loadConversationArchive(
                alloc,
                &session_dir,
            );
            session.freeHistoryTurnSlice(alloc, state.history);
            state.history = archive;
            state.context_history_start = latestCheckpointHistoryIndex(archive);
            try resolveSessionSnapshotLocators(
                alloc,
                state.history,
                if (state.recovery_checkpoint) |*checkpoint| checkpoint else null,
                self.sessions_dir,
                session_id,
            );
            return .{
                .summary = try summaryFromState(alloc, state),
                .state = state,
                .storage_format = .conversation,
            };
        }
        const authority = try classifyAuthority(alloc, &session_dir, session_id);
        return switch (authority) {
            .schema_v3 => {
                var source = try loadSchemaV3ReadOnly(
                    alloc,
                    &session_dir,
                    session_id,
                );
                var source_owned = true;
                defer if (source_owned) source.deinit(alloc);
                var state = source.takeState();
                source_owned = false;
                errdefer state.deinit(alloc);
                try resolveSessionSnapshotLocators(
                    alloc,
                    state.history,
                    if (state.recovery_checkpoint) |*checkpoint| checkpoint else null,
                    self.sessions_dir,
                    session_id,
                );
                return .{
                    .summary = try summaryFromState(alloc, state),
                    .state = state,
                    .storage_format = .schema_v3,
                };
            },
            .legacy => try self.loadLegacyReadOnlyDetail(
                alloc,
                &session_dir,
                session_id,
                options,
            ),
        };
    }

    /// Lists supported readable sessions newest-first; caller frees each item and the list.
    /// Lists all readable sessions newest-first. Caller frees each item and the list.
    pub fn list(self: Store, alloc: Allocator) anyerror!std.ArrayList(SessionSummary) {
        const scan = try self.scanSessionSummariesWithDiagnostics(alloc, .read_only_list, false);
        return scan.summaries;
    }

    pub fn readOnlyCandidates(self: Store) CandidateIterator {
        return .{
            .store = self,
            .entries = if (self.canonical_root.sessions) |dir| dir.dir.iterate() else null,
        };
    }

    /// Listing's read of one session: a schema-v3 session whose projection is
    /// stale, missing, or unreadable is summarized from its committed log. The
    /// caller owns the candidate. No directory handle escapes this read.
    pub fn readOnlyCandidate(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        cancelled: ?*const std.atomic.Value(bool),
    ) !ReadOnlyCandidate {
        if (cancelled) |stop| {
            if (stop.load(.acquire)) return error.Cancelled;
        }
        var dir = try self.openSessionDir(session_id);
        defer dir.close();
        const classified = if (cancelled) |stop|
            discovery.classifyReadOnlyCandidateCancellable(alloc, &dir, session_id, stop)
        else
            classifyReadOnlyCandidate(alloc, &dir, session_id);
        var candidate = classified catch |err| switch (err) {
            // A missing or undecodable manifest; every other failure is
            // reported, not recovered.
            error.SessionNotFound, error.InvalidSessionFormat => (try discovery.recoverSchemaV3Candidate(alloc, &dir, session_id, cancelled)) orelse return err,
            else => return err,
        };
        errdefer candidate.deinit(alloc);
        try discovery.summarizeStaleProjection(alloc, &dir, &candidate, cancelled);
        return candidate;
    }

    /// Summarizes a legacy session behind an interrupted upgrade fence from
    /// its stable snapshot, for listing only. The caller owns the candidate.
    pub fn readOnlyFencedLegacyCandidate(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        cancelled: ?*const std.atomic.Value(bool),
    ) !ReadOnlyCandidate {
        var dir = try self.openSessionDir(session_id);
        defer dir.close();
        return discovery.classifyFencedLegacyCandidate(alloc, &dir, session_id, cancelled);
    }

    /// Invalidates the derived resume catalog after managed child ownership
    /// changes. The relationship index remains the canonical authority.
    /// Returns owned IDs for every readable ordinary session. Caller frees each
    /// ID and the list with the allocator passed here.
    pub fn listSubagentControlSessionIds(
        self: Store,
        alloc: Allocator,
    ) ListSubagentControlIdsError!std.ArrayList([]u8) {
        const scan = self.scanSessionSummariesWithDiagnostics(alloc, .read_only_list, false) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SessionStoreUnavailable,
            };
        };
        var summaries = scan.summaries;
        defer freeSummaries(alloc, &summaries);
        var ids: std.ArrayList([]u8) = .empty;
        errdefer {
            for (ids.items) |id| alloc.free(id);
            ids.deinit(alloc);
        }
        for (summaries.items) |summary| {
            const id = try alloc.dupe(u8, summary.id);
            errdefer alloc.free(id);
            try ids.append(alloc, id);
        }
        return ids;
    }

    /// Returns a bounded page of ordinary-session IDs for derived relationship
    /// migration only. These candidates never establish relationship truth.
    /// Persists the unresolved marker before its matching session checkpoint.
    /// The caller must persist the returned timestamp with that checkpoint.
    pub fn prepareUsageRecoveryCheckpoint(
        self: Store,
        alloc: Allocator,
        writable: *const LoadedWritableSession,
        snapshot: session_usage.Snapshot,
    ) !UsageRecoveryCheckpoint {
        try writable.requireWritable();
        const now_ms = @max(io_mod.milliTimestamp(), 0);
        const timestamp_ms = if (now_ms > writable.state.updated_at_ms)
            now_ms
        else
            std.math.add(
                i64,
                writable.state.updated_at_ms,
                1,
            ) catch return error.InvalidSessionFormat;
        const recovery_pending = session_usage.needsProfileRecovery(snapshot);
        if (recovery_pending) {
            const durable_recovery_pending = if (writable.state.usage) |usage|
                session_usage.needsProfileRecovery(usage)
            else
                false;
            const protected_updated_at_ms = if (durable_recovery_pending)
                writable.state.updated_at_ms
            else
                timestamp_ms;
            try self.writeUsageRecoveryPending(
                alloc,
                writable.active_id,
                protected_updated_at_ms,
                !durable_recovery_pending,
            );
        }
        return .{
            .recovery_pending = recovery_pending,
            .timestamp_ms = timestamp_ms,
        };
    }

    /// Completes the marker transition after the matching session checkpoint
    /// is durable.
    pub fn finishUsageRecoveryCheckpoint(
        self: Store,
        session_id: []const u8,
        checkpoint: UsageRecoveryCheckpoint,
    ) !void {
        if (!checkpoint.recovery_pending) {
            try self.clearUsageRecoveryPending(session_id);
        }
    }

    /// Records that this session has profile usage which is not yet proven
    /// durable in the profile ledger.
    pub fn markUsageRecoveryPending(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        protected_updated_at_ms: i64,
    ) !void {
        try self.writeUsageRecoveryPending(
            alloc,
            session_id,
            protected_updated_at_ms,
            true,
        );
    }

    fn writeUsageRecoveryPending(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        protected_updated_at_ms: i64,
        replace_existing: bool,
    ) !void {
        try validateSessionId(session_id);
        if (protected_updated_at_ms < 0) return error.InvalidSessionFormat;
        if (self.canonical_root.mode != .writable) {
            return error.SessionStoreReadOnly;
        }
        _ = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        var profile = try openUsageRecoveryProfileRoot(self.home_dir) orelse
            return error.SessionStoreUnavailable;
        defer profile.close();
        var recovery = try io_mod.openOrCreateVerifiedPrivateDir(
            &profile,
            usage_recovery_dir,
        );
        defer recovery.close();
        const existing = validateUsageRecoveryMarker(
            &recovery,
            session_id,
        ) catch |err| switch (err) {
            error.UsageRecoveryMarkerNotFound => null,
            else => return err,
        };
        if (!replace_existing and existing != null) return;
        if (existing) |timestamp_ms| {
            if (timestamp_ms == protected_updated_at_ms) return;
        }
        const marker_bytes = try alloc.print(
            "{s}{d}\n",
            .{ usage_recovery_marker_prefix, protected_updated_at_ms },
        );
        defer alloc.free(marker_bytes);
        try io_mod.durableReplaceVerified(
            alloc,
            &recovery,
            session_id,
            marker_bytes,
        );
    }

    /// Clears a session's recovery marker only after its settled checkpoint is
    /// durable. Missing markers are already clear.
    pub fn clearUsageRecoveryPending(
        self: Store,
        session_id: []const u8,
    ) !void {
        try validateSessionId(session_id);
        if (self.canonical_root.mode != .writable) {
            return error.SessionStoreReadOnly;
        }
        _ = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        var recovery = try openUsageRecoveryDir(self.home_dir) orelse return;
        defer recovery.close();
        _ = validateUsageRecoveryMarker(&recovery, session_id) catch |err| switch (err) {
            error.UsageRecoveryMarkerNotFound => return,
            else => return err,
        };
        recovery.dir.deleteFile(io_mod.getIo(), session_id) catch |err| switch (err) {
            error.FileNotFound => return,
            error.NotDir, error.SymLinkLoop => return error.InvalidUsageRecoveryIndex,
            else => return err,
        };
        try io_mod.syncVerifiedDir(recovery.dir);
    }

    /// Returns the bounded durable recovery marker set. The caller owns every
    /// entry and the list.
    pub fn listUsageRecoverySessions(
        self: Store,
        alloc: Allocator,
    ) !std.ArrayList(UsageRecoverySession) {
        var recovery = try openUsageRecoveryDir(self.home_dir) orelse
            return std.ArrayList(UsageRecoverySession).empty;
        defer recovery.close();

        var marked: std.ArrayList(UsageRecoverySession) = .empty;
        errdefer {
            for (marked.items) |*entry| entry.deinit(alloc);
            marked.deinit(alloc);
        }
        var iter = recovery.dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            if (entry.kind != .file or
                marked.items.len == max_usage_recovery_sessions)
            {
                return error.InvalidUsageRecoveryIndex;
            }
            validateSessionId(entry.name) catch
                return error.InvalidUsageRecoveryIndex;
            const protected_updated_at_ms = validateUsageRecoveryMarker(
                &recovery,
                entry.name,
            ) catch return error.InvalidUsageRecoveryIndex;
            const marker_stat = try recovery.dir.statFile(
                io_mod.getIo(),
                entry.name,
                .{ .follow_symlinks = false },
            );
            try marked.append(alloc, .{
                .id = try alloc.dupe(u8, entry.name),
                .protected_updated_at_ms = protected_updated_at_ms,
                .marker_modified_at_ns = marker_stat.mtime.nanoseconds,
            });
        }
        sort_utils.sort(UsageRecoverySession, marked.items, {}, struct {
            fn lessThan(
                _: void,
                left: UsageRecoverySession,
                right: UsageRecoverySession,
            ) bool {
                return std.mem.order(u8, left.id, right.id) == .lt;
            }
        }.lessThan);
        return marked;
    }

    pub fn usageCheckpointModifiedAtNs(
        self: Store,
        session_id: []const u8,
    ) !?i128 {
        var session_dir = self.openSessionDir(session_id) catch |err| switch (err) {
            error.SessionNotFound => return null,
            else => return err,
        };
        defer session_dir.close();
        const stat = session_dir.dir.statFile(
            io_mod.getIo(),
            session_usage_sidecar.sidecar_file,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        if (stat.kind != .file or stat.nlink != 1) return error.SessionPathUnsafe;
        return stat.mtime.nanoseconds;
    }

    /// Lists readable sessions for this store's workspace newest-first. Caller frees each item and the list.
    pub fn listForWorkspace(self: Store, alloc: Allocator) anyerror!std.ArrayList(SessionSummary) {
        const scan = try self.scanSessionSummariesWithDiagnostics(alloc, .read_only_list, false);
        var summaries = scan.summaries;
        errdefer freeSummaries(alloc, &summaries);
        retainWorkspaceSummaries(alloc, &summaries, self.workspace_root);
        return summaries;
    }

    /// Lists session candidates for workspace-owned managed children. Child
    /// payloads remain the authority for child ownership.
    pub fn listManagedChildCandidatesForWorkspace(self: Store, alloc: Allocator) anyerror!std.ArrayList(SessionSummary) {
        return self.listForWorkspace(alloc);
    }

    /// Lists up to ten resumable sessions after filtering the current and empty sessions.
    pub fn listResumablePage(
        self: Store,
        alloc: Allocator,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        return self.listResumablePageForScope(
            alloc,
            .all_workspaces,
            active_id,
            continuation,
        );
    }

    pub fn listResumableWorkspacePage(
        self: Store,
        alloc: Allocator,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        return self.listResumablePageForScope(
            alloc,
            .current_workspace,
            active_id,
            continuation,
        );
    }

    fn listResumablePageForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        return self.listResumablePageFromDiscoveryForScope(alloc, scope, active_id, continuation);
    }

    /// Rewrites the cached title for one indexed session. The index freezes
    /// display metadata once present, so a rename must update it here or the
    /// resume picker keeps serving the previously derived title.
    fn listResumablePageFromDiscoveryForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        var summaries = try self.scanSessionSummaries(alloc, .read_only_list);
        defer freeSummaries(alloc, &summaries);
        return try self.resumablePageFromSummariesForScope(
            alloc,
            scope,
            summaries.items,
            active_id,
            continuation,
        );
    }

    fn resumablePageFromSummariesForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        summaries: []const SessionSummary,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        const workspace_root = switch (scope) {
            .all_workspaces => null,
            .current_workspace => self.workspace_root,
        };
        return try resumablePageFromSummaries(
            alloc,
            summaries,
            workspace_root,
            active_id,
            continuation,
            self.resume_page_limit,
        );
    }

    /// Takes ownership of `page` and refreshes stale display rows when the
    /// source is small enough for bounded first-paint work. Large histories
    /// keep their honest fallback title instead of blocking the whole page.
    fn displayMetadataReplaySourceBytes(self: Store, session_id: []const u8) !u64 {
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        var events = openSessionFile(&session_dir, "events.jsonl", .read_only) catch |err| switch (err) {
            error.FileNotFound => {
                var legacy = try openSessionFile(&session_dir, "session.json", .read_only);
                defer legacy.close(io_mod.getIo());
                return (try legacy.stat(io_mod.getIo())).size;
            },
            else => return err,
        };
        defer events.close(io_mod.getIo());
        return (try events.stat(io_mod.getIo())).size;
    }

    /// Fills display metadata from an existing frozen sidecar so hydration
    /// replays the event log only when no sidecar is readable.
    /// Returns the single newest readable session summary, or
    /// `error.NoSavedSessions`. Caller owns it.
    pub fn latestReadOnlySummary(
        self: Store,
        alloc: Allocator,
    ) !SessionSummary {
        var summaries = try self.scanSessionSummaries(
            alloc,
            .global_read_only_last,
        );
        defer summaries.deinit(alloc);
        if (summaries.items.len == 0) return error.NoSavedSessions;
        const latest = summaries.orderedRemove(0);
        for (summaries.items) |*summary| summary.deinit(alloc);
        return latest;
    }

    /// Returns the newest readable session summary for this store's workspace, or
    /// `error.NoSavedSessions`. Caller owns it.
    pub fn latestReadOnlyWorkspaceSummary(
        self: Store,
        alloc: Allocator,
    ) !SessionSummary {
        return self.latestReadOnlyWorkspaceSummaryFor(
            alloc,
            self.workspace_root,
        );
    }

    fn latestReadOnlyWorkspaceSummaryFor(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
    ) !SessionSummary {
        var scan = try self.scanSessionSummariesWithDiagnostics(
            alloc,
            .global_read_only_last,
            true,
        );
        defer scan.summaries.deinit(alloc);
        retainWorkspaceSummaries(alloc, &scan.summaries, workspace_root);
        if (scan.summaries.items.len == 0) {
            if (scan.skipped_invalid > 0) return error.NoReadableSessions;
            return error.NoSavedSessions;
        }
        const latest = scan.summaries.orderedRemove(0);
        for (scan.summaries.items) |*summary| summary.deinit(alloc);
        return latest;
    }

    fn scanSessionSummaries(
        self: Store,
        alloc: Allocator,
        mode: DiscoveryMode,
    ) !std.ArrayList(SessionSummary) {
        const scan = try self.scanSessionSummariesWithDiagnostics(alloc, mode, true);
        return scan.summaries;
    }

    /// Scans session directories into summaries. `probe_managed_children`
    /// controls whether each session's subagent relationship index is opened.
    fn scanSessionSummariesWithDiagnostics(
        self: Store,
        alloc: Allocator,
        mode: DiscoveryMode,
        probe_managed_children: bool,
    ) !SessionSummaryScan {
        var scan = SessionSummaryScan{};
        errdefer scan.deinit(alloc);
        var metadata: std.ArrayList(DiscoveryCandidateMetadata) = .empty;
        defer metadata.deinit(alloc);
        var iter = self.readOnlyCandidates();
        iter.mode = mode;
        while (try iter.next(alloc)) |value| {
            var candidate = value;
            const session_id = candidate.summary.id;
            if (probe_managed_children) {
                candidate.summary.has_managed_children =
                    self.sessionHasManagedChildren(alloc, session_id) catch |err| switch (err) {
                        error.OutOfMemory => {
                            candidate.deinit(alloc);
                            return error.OutOfMemory;
                        },
                        else => false,
                    };
            }
            logDiscovery(
                mode,
                session_id,
                candidate.storage,
                candidate.projection_state,
                .listable,
                .retained,
                null,
            );
            metadata.append(alloc, .{
                .id = candidate.summary.id,
                .storage = candidate.storage,
                .projection_state = candidate.projection_state,
            }) catch |err| {
                candidate.deinit(alloc);
                return err;
            };
            scan.summaries.append(alloc, candidate.summary) catch |err| {
                candidate.deinit(alloc);
                return err;
            };
            candidate.summary = undefined;
        }
        scan.skipped_invalid = iter.skipped_invalid;
        sortSummariesNewestFirst(scan.summaries.items);
        if (mode == .global_read_only_last and scan.summaries.items.len > 0) {
            for (metadata.items) |candidate| {
                if (!std.mem.eql(u8, candidate.id, scan.summaries.items[0].id)) {
                    continue;
                }
                logDiscovery(
                    mode,
                    candidate.id,
                    candidate.storage,
                    candidate.projection_state,
                    .listable,
                    .selected,
                    null,
                );
                break;
            }
        }
        return scan;
    }

    fn sessionHasManagedChildren(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !bool {
        var capability = try self.openListedChildCapabilityReadOnly(
            alloc,
            session_id,
        );
        defer capability.deinit();
        var children_file = capability.openFileReadOnly(
            alloc,
            .subagent_control,
            "children.json",
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (children_file) |*file| {
            defer file.deinit();
            const bytes = try file.readToEnd(alloc, 512 * 1024);
            defer alloc.free(bytes);
            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidSubagentState;
            const children = parsed.value.object.get("children") orelse
                return error.InvalidSubagentState;
            if (children != .array or children.array.items.len > 256) {
                return error.InvalidSubagentState;
            }
            return children.array.items.len != 0;
        }
        var header_file = capability.openFileReadOnly(
            alloc,
            .subagent_control,
            session_child_store.subagent_relationship_index_file,
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer header_file.deinit();
        const header_bytes = try header_file.readToEnd(
            alloc,
            relationship_index_codec.max_header_bytes,
        );
        defer alloc.free(header_bytes);
        const header = try relationship_index_codec.decodeHeader(header_bytes);
        if (header.active_count_known) return header.active_count != 0;

        var page_number: u64 = 0;
        var offset: u64 = 0;
        while (offset < header.high_watermark) : (page_number += 1) {
            const page_name = relationship_index_codec.pageFileName(page_number);
            var page_file = try capability.openFileReadOnly(
                alloc,
                .subagent_control,
                &page_name,
            );
            defer page_file.deinit();
            const page_bytes = try page_file.readToEnd(
                alloc,
                relationship_index_codec.max_page_bytes,
            );
            defer alloc.free(page_bytes);
            const page = try relationship_index_codec.decodePage(
                page_bytes,
                page_number,
                header.storage_epoch,
            );
            const remaining = header.high_watermark - offset;
            const slots_to_read: usize = @intCast(@min(
                remaining,
                relationship_index_codec.page_slots,
            ));
            for (page.slots[0..slots_to_read]) |slot| {
                if (slot.occupied) return true;
            }
            offset += @intCast(slots_to_read);
        }
        return false;
    }

    /// Runs `doctor` over every session and returns one diagnostic per problem
    /// found. Caller frees the list.
    pub fn inspectForDoctor(
        self: Store,
        alloc: Allocator,
    ) !std.ArrayList(DoctorDiagnostic) {
        var result = try self.inspectForDoctorReportWithOptions(alloc, .{}, null);
        return result.takeDiagnostics();
    }

    fn inspectForDoctorWithOptions(
        self: Store,
        alloc: Allocator,
        options: DoctorInspectionOptions,
    ) !std.ArrayList(DoctorDiagnostic) {
        var result = try self.inspectForDoctorReportWithOptions(alloc, options, null);
        return result.takeDiagnostics();
    }

    /// Runs `doctor` over up to `max_valid_sessions` valid session directories.
    /// Caller frees the returned result.
    pub fn inspectForDoctorBounded(
        self: Store,
        alloc: Allocator,
        max_valid_sessions: usize,
    ) !DoctorInspectionResult {
        return self.inspectForDoctorReportWithOptions(alloc, .{}, max_valid_sessions);
    }

    fn inspectForDoctorReportWithOptions(
        self: Store,
        alloc: Allocator,
        options: DoctorInspectionOptions,
        max_valid_sessions: ?usize,
    ) !DoctorInspectionResult {
        var result: DoctorInspectionResult = .{};
        errdefer result.deinit(alloc);
        if (self.canonical_root.sessions == null) return result;

        var iterator = self.canonical_root.sessions.?.dir.iterate();
        while (try iterator.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, retired_latest_sessions_dir)) {
                continue;
            }
            validateSessionId(entry.name) catch continue;
            if (max_valid_sessions) |limit| {
                if (result.inspected_count >= limit) {
                    result.truncated = true;
                    break;
                }
            }
            result.inspected_count += 1;
            var session_dir = self.openSessionDir(entry.name) catch |err| {
                try appendDoctorDiagnostic(
                    &result.diagnostics,
                    alloc,
                    entry.name,
                    if (err == error.SessionPathUnsafe) .unsafe_path else .canonical_state_invalid,
                    null,
                );
                continue;
            };
            inspectDoctorSession(
                self.ctx(),
                alloc,
                &result.diagnostics,
                &session_dir,
                entry.name,
                options,
            ) catch |err| {
                session_dir.close();
                if (err == error.OutOfMemory) return err;
                try appendDoctorDiagnostic(
                    &result.diagnostics,
                    alloc,
                    entry.name,
                    if (err == error.SessionPathUnsafe) .unsafe_path else .canonical_state_invalid,
                    null,
                );
                continue;
            };
            session_dir.close();
        }
        return result;
    }

    /// Opens the named session writable and deletes its orphaned artifacts,
    /// returning a report of what was removed.
    pub fn cleanupForDoctor(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_log.CleanupReport {
        var writable_store = try Store.initFromHome(
            alloc,
            self.home_dir,
            self.workspace_root,
        );
        defer writable_store.deinit(alloc);
        var loaded = try writable_store.resumeForWrite(alloc, session_id);
        defer loaded.deinit(alloc);
        return .{};
    }

    fn openSessionDir(
        self: Store,
        session_id: []const u8,
    ) !io_mod.VerifiedDir {
        try validateSessionId(session_id);
        const sessions = self.canonical_root.sessions orelse
            return error.SessionNotFound;
        var dir = sessions.dir.openDir(io_mod.getIo(), session_id, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        errdefer dir.close(io_mod.getIo());
        const stat = try dir.stat(io_mod.getIo());
        if (stat.kind != .directory) return error.SessionPathUnsafe;
        return .{ .dir = dir };
    }

    fn loadLegacyReadOnlyDetail(
        self: Store,
        alloc: Allocator,
        session_dir: *io_mod.VerifiedDir,
        session_id: []const u8,
        options: ResumeOptions,
    ) !ReadOnlyDetail {
        try requireAuthorityFenceAbsent(alloc, session_dir, session_id);
        var file = openSessionFile(
            session_dir,
            "session.json",
            .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        const max_bytes = if (options.allow_large_legacy)
            stat.size
        else
            automatic_legacy_max_bytes;
        if (stat.size > max_bytes) return error.LegacySessionTooLarge;
        const bytes = readExactLegacyFile(alloc, &file, stat.size) catch |err| switch (err) {
            error.OutOfMemory => return error.LegacySessionReadResourceExhausted,
            else => return err,
        };
        defer alloc.free(bytes);
        var legacy = session_json.parseLegacyExact(
            LegacyStoredSession,
            alloc,
            bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.LegacySessionReadResourceExhausted,
            else => return err,
        };
        errdefer legacy.deinit(alloc);
        if (!std.mem.eql(u8, legacy.id, session_id)) return error.InvalidSessionFormat;
        try requireAuthorityFenceAbsent(alloc, session_dir, session_id);

        const schema = try session_json.parseLegacySchemaVersion(alloc, bytes);
        var state = try legacyToDurableState(
            self.ctx(),
            alloc,
            &legacy,
            self.workspace_root,
            .preserved_workspace,
            options.seed_preferences,
        );
        errdefer state.deinit(alloc);
        try resolveSessionSnapshotLocators(
            alloc,
            state.history,
            if (state.recovery_checkpoint) |*checkpoint| checkpoint else null,
            self.sessions_dir,
            session_id,
        );
        return .{
            .summary = try summaryFromState(alloc, state),
            .state = state,
            .storage_format = storageFormatForLegacy(schema),
        };
    }

    fn resumeExactForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        allow_rebind: bool,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        try validateSessionId(session_id);
        var session_dir = try self.openSessionDir(session_id);
        if (try session_log.legacyImportRecoveryNeeded(&session_dir)) {
            session_dir.close();
            {
                var writable = try self.openWritableSessionDir(
                    alloc,
                    session_id,
                    options.log.session_lock_deadline_ms,
                );
                defer writable.deinit(alloc);
                try session_log.recoverInterruptedLegacyImport(
                    alloc,
                    &writable,
                );
            }
            session_dir = try self.openSessionDir(session_id);
        }
        defer session_dir.close();
        if (try session_log.hasConversationMetadata(alloc, &session_dir)) {
            var root = self.canonical_root;
            const loaded = try root.resumeForWrite(alloc, session_id, options.log);
            return self.finishWorkspaceResume(
                alloc,
                loaded,
                workspace_root,
                allow_rebind,
            );
        }
        const authority = classifyAuthority(
            alloc,
            &session_dir,
            session_id,
        ) catch |err| switch (err) {
            error.SessionAuthorityBoundaryUnavailable => {
                const recovered = try self.resolveAuthorityTransitionForWrite(
                    alloc,
                    session_id,
                    workspace_root,
                    .requesting_workspace,
                    options,
                );
                return self.finishWorkspaceResume(
                    alloc,
                    recovered,
                    workspace_root,
                    allow_rebind,
                );
            },
            else => return err,
        };
        const loaded = switch (authority) {
            .schema_v3 => try self.migrateSchemaV3ForWrite(
                alloc,
                session_id,
                options,
            ),
            .legacy => try self.migrateLegacyForWrite(
                alloc,
                session_id,
                workspace_root,
                .requesting_workspace,
                options,
            ),
        };
        return self.finishWorkspaceResume(
            alloc,
            loaded,
            workspace_root,
            allow_rebind,
        );
    }

    fn finishWorkspaceResume(
        self: Store,
        alloc: Allocator,
        loaded_value: LoadedWritableSession,
        workspace_root: []const u8,
        allow_rebind: bool,
    ) !LoadedWritableSession {
        var loaded = loaded_value;
        errdefer loaded.deinit(alloc);
        try resolveSessionSnapshotLocators(
            alloc,
            loaded.state.history,
            if (loaded.state.recovery_checkpoint) |*checkpoint| checkpoint else null,
            self.sessions_dir,
            loaded.active_id,
        );

        if (std.mem.eql(u8, loaded.state.workspace_root, workspace_root)) {
            return loaded;
        }
        if (!allow_rebind) {
            return session_log.failLoadedWritableSession(error.SessionTargetChanged);
        }

        const rebound = session_log.SessionUpdate{ .workspace_rebound = .{
            .previous_workspace_root = loaded.state.workspace_root,
            .workspace_root = @constCast(workspace_root),
        } };
        _ = loaded.appendEvent(
            alloc,
            rebound,
            io_mod.milliTimestamp(),
        ) catch |err| return err;
        return loaded;
    }

    fn migrateLegacyForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var loaded: LoadedWritableSession = undefined;
        try self.migrateLegacyForWriteInto(
            &loaded,
            alloc,
            session_id,
            workspace_root,
            preference_source,
            options,
        );
        return loaded;
    }

    fn migrateSchemaV3ForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var writable = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.log.session_lock_deadline_ms,
        );
        errdefer writable.deinit(alloc);
        return migrateSchemaV3Locked(self.ctx(), alloc, &writable);
    }

    // Keep cold fallible constructors behind noinline out-parameter boundaries
    // so error returns do not materialize the full LoadedWritableSession payload.
    noinline fn migrateLegacyForWriteInto(
        self: Store,
        out: *LoadedWritableSession,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !void {
        if (self.canonical_root.mode != .writable or
            self.canonical_root.sessions == null)
        {
            return error.SessionStoreUnavailable;
        }
        var dir = self.canonical_root.sessions.?.dir.openDir(
            io_mod.getIo(),
            session_id,
            .{
                .iterate = true,
                .follow_symlinks = false,
            },
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        prepareWritableSessionDir(dir) catch |err| {
            dir.close(io_mod.getIo());
            return err;
        };
        var verified = io_mod.VerifiedDir{ .dir = dir };
        var writer_lock = io_mod.acquireTimedAdvisoryLock(
            &verified,
            "session.lock",
            options.log.session_lock_deadline_ms,
        ) catch |err| switch (err) {
            error.LockBusy => return error.SessionBusy,
            error.LockUnsupported => return error.SessionLockUnsupported,
            else => return err,
        };
        const owned_id = alloc.dupe(u8, session_id) catch |err| {
            writer_lock.release();
            dir.close(io_mod.getIo());
            return err;
        };
        var writable = session_log.WritableSessionDir{
            .dir = verified,
            .writer_lock = writer_lock,
            .session_id = owned_id,
        };
        writable.trackOwnerLiveness(alloc);
        const loaded = self.migrateLegacyWithoutCache(
            alloc,
            &writable,
            workspace_root,
            preference_source,
            options,
        ) catch |err| {
            writable.deinit(alloc);
            return err;
        };
        out.* = loaded;
    }

    fn migrateLegacyWithoutCache(
        self: Store,
        alloc: Allocator,
        writable: *session_log.WritableSessionDir,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        return migrateLegacyLocked(
            self.ctx(),
            alloc,
            writable,
            workspace_root,
            preference_source,
            options,
        );
    }

    fn resolveAuthorityTransitionForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var writable = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.log.session_lock_deadline_ms,
        );
        errdefer writable.deinit(alloc);

        var stable = openSessionFile(
            &writable.dir,
            "session.legacy.json",
            .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionAuthorityBoundaryUnavailable,
            else => return err,
        };
        defer stable.close(io_mod.getIo());
        const stat = try stable.stat(io_mod.getIo());
        const allowed_size = if (options.allow_large_legacy)
            stat.size
        else
            automatic_legacy_max_bytes;
        if (stat.size > allowed_size) return error.LegacySessionTooLarge;
        const bytes = readExactLegacyFile(
            alloc,
            &stable,
            stat.size,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.LegacySessionMigrationResourceExhausted,
            else => return error.LegacySessionMigrationFailed,
        };
        defer alloc.free(bytes);
        _ = try session_json.parseLegacySchemaVersion(alloc, bytes);

        try io_mod.durableReplaceVerified(
            alloc,
            &writable.dir,
            "session.json",
            bytes,
        );
        try deleteSessionEntry(&writable.dir, "authority.pending.json");
        try deleteSessionEntry(&writable.dir, "authority.json");
        try deleteSessionEntry(&writable.dir, "checkpoint.json");
        try io_mod.syncVerifiedDir(writable.dir.dir);

        return self.migrateLegacyWithoutCache(
            alloc,
            &writable,
            workspace_root,
            preference_source,
            options,
        );
    }
    fn openWritableSessionDir(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        session_lock_deadline_ms: u64,
    ) !session_log.WritableSessionDir {
        const sessions = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        var dir = sessions.dir.openDir(io_mod.getIo(), session_id, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        prepareWritableSessionDir(dir) catch |err| {
            dir.close(io_mod.getIo());
            return err;
        };
        var verified = io_mod.VerifiedDir{ .dir = dir };
        var writer_lock = io_mod.acquireTimedAdvisoryLock(
            &verified,
            "session.lock",
            session_lock_deadline_ms,
        ) catch |err| {
            dir.close(io_mod.getIo());
            return switch (err) {
                error.LockBusy => error.SessionBusy,
                error.LockUnsupported => error.SessionLockUnsupported,
                else => err,
            };
        };
        const owned_id = alloc.dupe(u8, session_id) catch |err| {
            writer_lock.release();
            dir.close(io_mod.getIo());
            return err;
        };
        var writable = session_log.WritableSessionDir{
            .dir = verified,
            .writer_lock = writer_lock,
            .session_id = owned_id,
        };
        writable.trackOwnerLiveness(alloc);
        return writable;
    }

    /// Migrates a legacy session to schema-v3 in place without returning a live
    /// session, reporting the source schema/bytes. Idempotent on already-current
    /// sessions. Caller owns the returned result.
    /// Converts any supported older session to the current conversation format.
    /// Current sessions are reported without rewriting them.
    pub fn migrateLegacyStorageOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: MigrationOptions,
    ) !SessionMigrationResult {
        try validateSessionId(session_id);
        var session_dir = try self.openSessionDir(session_id);
        if (try session_log.legacyImportRecoveryNeeded(&session_dir)) {
            session_dir.close();
            {
                var writable = try self.openWritableSessionDir(
                    alloc,
                    session_id,
                    options.log.session_lock_deadline_ms,
                );
                defer writable.deinit(alloc);
                try session_log.recoverInterruptedLegacyImport(
                    alloc,
                    &writable,
                );
            }
            session_dir = try self.openSessionDir(session_id);
        }
        if (try session_log.hasConversationMetadata(alloc, &session_dir)) {
            session_dir.close();
            return .{
                .session_id = try alloc.dupe(u8, session_id),
                .source_schema_version = session_codec.session_metadata_schema_version,
                .source_bytes = 0,
                .status = .already_current,
            };
        }
        const authority = (if (options.allow_large)
            classifyAuthorityAllowingLargeLegacy(alloc, &session_dir, session_id)
        else
            classifyAuthority(alloc, &session_dir, session_id)) catch |err| {
            session_dir.close();
            if (err != error.SessionAuthorityBoundaryUnavailable) return err;
            var recovered = try self.resolveAuthorityTransitionForWrite(
                alloc,
                session_id,
                self.workspace_root,
                .preserved_workspace,
                .{
                    .allow_large_legacy = options.allow_large,
                    .seed_preferences = options.seed_preferences,
                    .log = options.log,
                },
            );
            defer recovered.deinit(alloc);
            return migrationResultFromLoaded(alloc, session_id, recovered);
        };
        session_dir.close();

        var migrated = switch (authority) {
            .schema_v3 => try self.migrateSchemaV3ForWrite(
                alloc,
                session_id,
                .{ .log = options.log },
            ),
            .legacy => try self.migrateLegacyForWrite(
                alloc,
                session_id,
                self.workspace_root,
                .preserved_workspace,
                .{
                    .allow_large_legacy = options.allow_large,
                    .seed_preferences = options.seed_preferences,
                    .log = options.log,
                },
            ),
        };
        defer migrated.deinit(alloc);
        return migrationResultFromLoaded(alloc, session_id, migrated);
    }

    fn migrationResultFromLoaded(
        alloc: Allocator,
        session_id: []const u8,
        loaded: LoadedWritableSession,
    ) !SessionMigrationResult {
        const source_schema_version = loaded.migration_source_schema_version orelse
            return error.LegacySessionMigrationFailed;
        const source_bytes = loaded.migration_source_bytes orelse
            return error.LegacySessionMigrationFailed;
        return .{
            .session_id = try alloc.dupe(u8, session_id),
            .source_schema_version = source_schema_version,
            .source_bytes = source_bytes,
            .status = .migrated,
        };
    }

    /// Copies a validated conversation prefix or legacy manifest boundary to a
    /// new session. The source is locked for the read and is never modified.
    pub fn recoverSessionCopy(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: session_log.Options,
    ) !SessionRecoveryResult {
        try validateSessionId(session_id);
        var source = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.session_lock_deadline_ms,
        );
        defer source.deinit(alloc);
        var metadata = session_log.readConversationMetadata(alloc, &source.dir) catch |err| switch (err) {
            error.InvalidSessionMetadata, error.InvalidSessionFormat => return error.SessionRecoveryBoundaryInvalid,
            else => return err,
        };
        defer if (metadata) |*current| current.deinit();
        var current_boundary: ?session_log.ConversationRecoveryBoundary = null;
        var usage_incomplete = false;
        var recovered = recovery_state: {
            if (metadata) |current| {
                if (!std.mem.eql(u8, current.value.id, session_id)) return error.SessionRecoveryBoundaryInvalid;
                if (current.value.subagent_child) return error.SessionNotFound;
                const recovery = session_log.classify_conversation_recovery(alloc, &source.dir, session_id) catch |err| {
                    if (err == error.SessionRecoveryNotNeeded) {
                        var healthy = try self.loadReadOnly(alloc, session_id);
                        healthy.deinit(alloc);
                    }
                    return err;
                };
                current_boundary = recovery.boundary;
                usage_incomplete = recovery.usage_incomplete;
                break :recovery_state try session_log.load_conversation_recovery_state(alloc, &source.dir, session_id, current_boundary.?);
            }
            const authority = try classifyAuthority(
                alloc,
                &source.dir,
                session_id,
            );
            if (authority != .schema_v3) {
                return error.SessionRecoveryRequiresCurrentSchema;
            }
            var manifest_file = openSessionFile(
                &source.dir,
                "session.json",
                .read_only,
            ) catch return error.SessionRecoveryBoundaryInvalid;
            defer manifest_file.close(io_mod.getIo());
            const manifest_stat = try manifest_file.stat(io_mod.getIo());
            if (manifest_stat.size > session_projection.manifest_max_bytes) {
                return error.SessionRecoveryBoundaryInvalid;
            }
            const manifest_bytes = readExactLegacyFile(
                alloc,
                &manifest_file,
                manifest_stat.size,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.SessionRecoveryBoundaryInvalid,
            };
            defer alloc.free(manifest_bytes);
            const manifest_schema = authority_module.manifestSchemaVersion(
                alloc,
                manifest_bytes,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.SessionRecoveryBoundaryInvalid,
            };
            if (manifest_schema != 3) {
                return error.SessionRecoveryUnsupportedSchema;
            }

            var manifest = session_projection.decodeManifest(alloc, manifest_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.SessionRecoveryBoundaryInvalid,
            };
            defer manifest.deinit(alloc);
            if (!std.mem.eql(u8, manifest.id, session_id)) return error.SessionRecoveryBoundaryInvalid;
            var events = openSessionFile(&source.dir, "events.jsonl", .read_only) catch
                return error.SessionRecoveryBoundaryInvalid;
            defer events.close(io_mod.getIo());
            var imported = session_replay.replayCommittedPrefix(
                alloc,
                events,
                manifest.log_generation,
                manifest.last_event_seq,
                manifest.event_log_bytes,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnsupportedSessionSchema => return error.SessionRecoveryUnsupportedSchema,
                else => return error.SessionRecoveryBoundaryInvalid,
            };
            var imported_owned = true;
            defer if (imported_owned) imported.deinit(alloc);
            if (!session_projection.stateMatchesManifest(imported.state, manifest)) {
                return error.SessionRecoveryBoundaryInvalid;
            }
            const recovered_state = imported.takeState();
            imported_owned = false;
            break :recovery_state recovered_state;
        };
        defer recovered.deinit(alloc);
        try resolveSessionSnapshotLocators(
            alloc,
            recovered.history,
            if (recovered.recovery_checkpoint) |*checkpoint| checkpoint else null,
            self.sessions_dir,
            session_id,
        );
        const source_dir_path = try sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        );
        defer alloc.free(source_dir_path);
        var source_children = try session_child_store.SessionChildCapability.init(
            alloc,
            source.dir.dir,
            source_dir_path,
            .read_only,
        );
        defer source_children.deinit();
        if (try subagent_child_state.capabilityHasManagedChildMarker(alloc, &source_children)) {
            return error.SessionNotFound;
        }

        const source_id = try alloc.dupe(u8, recovered.id);
        errdefer alloc.free(source_id);
        const recovered_id = try generateSessionId(alloc);
        errdefer alloc.free(recovered_id);
        const replacement_id = try alloc.dupe(u8, recovered_id);
        alloc.free(recovered.id);
        recovered.id = replacement_id;

        var initial = try recovered.dupe(alloc);
        defer initial.deinit(alloc);
        var staging_lock = try self.acquireRecoveryStagingLock(
            options.session_lock_deadline_ms,
        );
        defer staging_lock.release();
        var staging_root = try self.initRecoveryStagingRoot(alloc);
        defer self.deinitRecoveryStagingRoot(alloc, &staging_root);
        try cleanupAbandonedRecoveryStages(&staging_root);
        var target = try self.startRecoveryStagedSession(
            alloc,
            &staging_root,
            initial,
            options,
        );
        var target_owned = true;
        var target_promoted = false;
        errdefer if (target_owned) {
            if (target_promoted) {
                target.deinit(alloc);
            } else {
                const disposition = discardRecoveryStagedSession(
                    &staging_root,
                    alloc,
                    &target,
                );
                if (disposition != .discarded) {
                    debug_trace.logf(
                        "session",
                        "event=session_recovery_unpublished_target_cleanup disposition={s}",
                        .{@tagName(disposition)},
                    );
                }
            }
            target_owned = false;
        };

        if (recovered.usage == null) {
            if (target.state.usage) |usage| {
                // Keep the normal new-session default when optional usage is absent.
                recovered.usage = try session_usage.dupeSnapshotOwned(alloc, usage);
            }
        }

        const staged_target_dir = try sessionDirPath(
            alloc,
            staging_root.display_root,
            recovered_id,
        );
        defer alloc.free(staged_target_dir);
        const staged_target_images = try std.Io.Dir.path.join(
            alloc,
            &.{ staged_target_dir, "images" },
        );
        defer alloc.free(staged_target_images);
        const target_dir = try sessionDirPath(
            alloc,
            self.sessions_dir,
            recovered_id,
        );
        defer alloc.free(target_dir);
        const target_images = try std.Io.Dir.path.join(
            alloc,
            &.{ target_dir, "images" },
        );
        defer alloc.free(target_images);
        try copyRecoveredImageSnapshots(
            alloc,
            recovered.history,
            if (recovered.recovery_checkpoint) |*checkpoint| checkpoint else null,
            staged_target_images,
        );
        try rebaseRecoveredImageSnapshots(
            alloc,
            recovered.history,
            if (recovered.recovery_checkpoint) |*checkpoint| checkpoint else null,
            staged_target_images,
            target_images,
        );
        const contains_unverified_artifacts = try copyRecoveredManagedChildren(
            alloc,
            recovered.history,
            if (recovered.recovery_checkpoint) |*checkpoint| checkpoint else null,
            &source_children,
            target.child_capability orelse
                return error.SessionChildStoreFailed,
        );
        try canonicalizeRecoveredCheckpointFilePresentations(
            alloc,
            &recovered,
            target.state,
        );
        if (current_boundary) |boundary| {
            try session_log.copy_conversation_recovery_prefix(alloc, &source.dir, &target.log.dir, boundary);
            if (metadata.?.value.title) |title| _ = try target.renameConversation(alloc, title);
        }
        const promotion = self.promoteRecoveryStagedSession(
            &staging_root,
            recovered_id,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=session_recovery_target_promotion_failed target={s} err={s}",
                .{ recovered_id, @errorName(err) },
            );
            return error.SessionRecoveryIndeterminate;
        };
        target_promoted = true;
        if (promotion == .indeterminate) {
            target.deinit(alloc);
            target_owned = false;
            return .{
                .source_session_id = source_id,
                .recovered_session_id = recovered_id,
                .history_len = recovered.history.len,
                .usage_incomplete = usage_incomplete,
                .status = .indeterminate,
            };
        }
        target.deinit(alloc);
        target_owned = false;

        var verified = self.loadReadOnly(alloc, recovered_id) catch |err| {
            debug_trace.logf(
                "session",
                "event=session_recovery_target_indeterminate target={s} verify_err={s}",
                .{ recovered_id, @errorName(err) },
            );
            return .{
                .source_session_id = source_id,
                .recovered_session_id = recovered_id,
                .history_len = recovered.history.len,
                .usage_incomplete = usage_incomplete,
                .status = .indeterminate,
            };
        };
        defer verified.deinit(alloc);
        if (!try session_log.durableStatesEqual(verified, recovered)) {
            return .{
                .source_session_id = source_id,
                .recovered_session_id = recovered_id,
                .history_len = recovered.history.len,
                .usage_incomplete = usage_incomplete,
                .status = .indeterminate,
            };
        }

        return .{
            .source_session_id = source_id,
            .recovered_session_id = recovered_id,
            .history_len = recovered.history.len,
            .usage_incomplete = usage_incomplete,
            .status = if (contains_unverified_artifacts)
                .recovered_with_unverified_artifacts
            else
                .recovered,
        };
    }
};

pub const PristineDiscardDisposition = enum {
    discarded,
    retained,
    indeterminate,
};

const RecoveryPromotionStatus = enum {
    promoted,
    indeterminate,
};

fn copyRecoveredImageSlice(
    alloc: Allocator,
    images: []core_types.ImageAttachment,
    target_images: []const u8,
) !void {
    for (images) |*image| {
        if (image.snapshot_path == null) continue;
        const copied = image_attachments.copyVerifiedImageAttachmentToDir(
            alloc,
            image.*,
            image.id,
            target_images,
        ) catch |err| switch (err) {
            error.FileNotFound,
            error.InvalidImageId,
            error.MissingImageSnapshot,
            error.InvalidImageSnapshotDigest,
            error.NotRegularFile,
            error.ImageTooLarge,
            error.ImageSnapshotCorrupt,
            error.UnsupportedImageType,
            error.ImageSnapshotMediaTypeMismatch,
            => return error.SessionRecoveryBoundaryInvalid,
            else => return err,
        };
        core_types.freeImageAttachment(alloc, image.*);
        image.* = copied;
    }
}

fn copyRecoveredImageSnapshots(
    alloc: Allocator,
    history: []session.HistoryTurn,
    recovery_checkpoint: ?*session_codec.RecoveryCheckpoint,
    target_images: []const u8,
) !void {
    for (history) |*turn| {
        const images = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| entry.user.images,
            .interrupted => |*entry| entry.user.images,
        };
        try copyRecoveredImageSlice(alloc, images, target_images);
    }
    if (recovery_checkpoint) |checkpoint| {
        try copyRecoveredImageSlice(alloc, checkpoint.user.images, target_images);
    }
}

fn rebaseRecoveredImageSlice(
    alloc: Allocator,
    images: []core_types.ImageAttachment,
    staged_images: []const u8,
    target_images: []const u8,
) !void {
    for (images) |*image| {
        const staged_path = image.snapshot_path orelse continue;
        const parent = std.Io.Dir.path.dirname(staged_path) orelse
            return error.SessionRecoveryBoundaryInvalid;
        if (!std.mem.eql(u8, parent, staged_images)) {
            return error.SessionRecoveryBoundaryInvalid;
        }
        const leaf = std.Io.Dir.path.basename(staged_path);
        const target_path = try std.Io.Dir.path.join(
            alloc,
            &.{ target_images, leaf },
        );
        alloc.free(staged_path);
        image.snapshot_path = target_path;
    }
}

fn rebaseRecoveredImageSnapshots(
    alloc: Allocator,
    history: []session.HistoryTurn,
    recovery_checkpoint: ?*session_codec.RecoveryCheckpoint,
    staged_images: []const u8,
    target_images: []const u8,
) !void {
    for (history) |*turn| {
        const images = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| entry.user.images,
            .interrupted => |*entry| entry.user.images,
        };
        try rebaseRecoveredImageSlice(alloc, images, staged_images, target_images);
    }
    if (recovery_checkpoint) |checkpoint| {
        try rebaseRecoveredImageSlice(
            alloc,
            checkpoint.user.images,
            staged_images,
            target_images,
        );
    }
}

fn committedFilePresentationIdentityEqual(
    first: core_types.CommittedFilePresentation,
    second: core_types.CommittedFilePresentation,
) bool {
    if (!std.mem.eql(u8, first.path, second.path) or
        first.kind != second.kind or
        first.additions != second.additions or
        first.deletions != second.deletions or
        first.truncated != second.truncated or
        first.lines.len != second.lines.len or
        (first.lifecycle_id == null) != (second.lifecycle_id == null))
    {
        return false;
    }
    for (first.lines, second.lines) |first_line, second_line| {
        if (first_line.kind != second_line.kind or
            first_line.old_line != second_line.old_line or
            first_line.new_line != second_line.new_line or
            !std.mem.eql(u8, first_line.text, second_line.text))
        {
            return false;
        }
    }
    if (first.lifecycle_id) |first_lifecycle| {
        const second_lifecycle = second.lifecycle_id.?;
        if (first_lifecycle.turn_id != second_lifecycle.turn_id or
            !std.mem.eql(u8, first_lifecycle.call_id, second_lifecycle.call_id))
        {
            return false;
        }
    }
    return true;
}

fn canonicalizeRecoveredExecutionFilePresentations(
    alloc: Allocator,
    recovered: *core_types.ExecutionMemory,
    target: core_types.ExecutionMemory,
) !void {
    if (recovered.tool_steps.len != target.tool_steps.len) {
        return error.SessionRecoveryIndeterminate;
    }
    for (recovered.tool_steps, target.tool_steps) |*recovered_step, target_step| {
        if (recovered_step.tool_results.len != target_step.tool_results.len) {
            return error.SessionRecoveryIndeterminate;
        }
        for (recovered_step.tool_results, target_step.tool_results) |*recovered_result, target_result| {
            if (!std.mem.eql(u8, recovered_result.tool_call_id, target_result.tool_call_id) or
                (recovered_result.committed_file_presentation == null) !=
                    (target_result.committed_file_presentation == null))
            {
                return error.SessionRecoveryIndeterminate;
            }
            const target_presentation = target_result.committed_file_presentation orelse continue;
            const recovered_presentation = &recovered_result.committed_file_presentation.?;
            if (!committedFilePresentationIdentityEqual(
                recovered_presentation.*,
                target_presentation,
            )) {
                return error.SessionRecoveryIndeterminate;
            }
            const target_handle = target_presentation.content_handle orelse continue;
            const owned_handle = try alloc.dupe(u8, target_handle);
            if (recovered_presentation.previous_content) |content| alloc.free(content);
            if (recovered_presentation.after_content) |content| alloc.free(content);
            if (recovered_presentation.content_handle) |handle| alloc.free(handle);
            recovered_presentation.previous_content = null;
            recovered_presentation.after_content = null;
            recovered_presentation.content_handle = owned_handle;
        }
    }
}

fn canonicalizeRecoveredCheckpointFilePresentations(
    alloc: Allocator,
    recovered: *session_codec.DurableSessionState,
    target: session_codec.DurableSessionState,
) !void {
    if ((recovered.recovery_checkpoint == null) != (target.recovery_checkpoint == null)) {
        return error.SessionRecoveryIndeterminate;
    }
    if (recovered.recovery_checkpoint) |*checkpoint| {
        try canonicalizeRecoveredExecutionFilePresentations(
            alloc,
            &checkpoint.execution,
            target.recovery_checkpoint.?.execution,
        );
    }
}

const RecoveredArtifactContract = enum {
    tool_output,
    tool_images,
    diff_content,
    command_replay,
    command_log,
};

fn isCommandLogHandle(handle: []const u8) bool {
    return std.mem.startsWith(u8, handle, "fx-command-") and
        std.mem.endsWith(u8, handle, ".log");
}

fn recoveredCommandArtifactIsAuthenticated(
    contract: RecoveredArtifactContract,
    handle: []const u8,
) bool {
    return switch (contract) {
        .command_replay => command_replay_store.isReplayHandle(handle) and
            command_replay_store.hasContentDigest(handle),
        .command_log => isCommandLogHandle(handle) and
            artifact_digest.hasContentDigest(handle, ".log"),
        else => false,
    };
}

fn recoveredArtifactKind(
    contract: RecoveredArtifactContract,
) session_child_store.ManagedChildKind {
    return switch (contract) {
        .tool_output, .tool_images, .diff_content => .tool_results,
        .command_replay, .command_log => .command_artifacts,
    };
}

fn copyRecoveredExecutionManagedChildren(
    alloc: Allocator,
    execution: *core_types.ExecutionMemory,
    source: *session_child_store.SessionChildCapability,
    target: *session_child_store.SessionChildCapability,
    contains_unverified_artifacts: *bool,
) !void {
    for (execution.tool_steps) |*step| {
        for (step.tool_results) |*result| {
            if (result.tool_image_handle) |handle| {
                try copyRecoveredManagedChild(
                    alloc,
                    source,
                    target,
                    .tool_images,
                    handle,
                    null,
                    null,
                );
            }
            if (result.output_handle) |handle| {
                try copyRecoveredManagedChild(
                    alloc,
                    source,
                    target,
                    .tool_output,
                    handle,
                    null,
                    result.stored_output_bytes,
                );
            }
            if (result.committed_file_presentation) |presentation| {
                if (presentation.content_handle) |handle| {
                    try copyRecoveredManagedChild(
                        alloc,
                        source,
                        target,
                        .diff_content,
                        handle,
                        result.tool_call_id,
                        null,
                    );
                }
            }
            if (result.command_output_replay) |replay| {
                contains_unverified_artifacts.* =
                    (try copyRecoveredCommandReplay(
                        alloc,
                        source,
                        target,
                        replay,
                    )) or contains_unverified_artifacts.*;
            }
        }
    }
}

fn copyRecoveredManagedChildren(
    alloc: Allocator,
    history: []session.HistoryTurn,
    recovery_checkpoint: ?*session_codec.RecoveryCheckpoint,
    source: *session_child_store.SessionChildCapability,
    target: *session_child_store.SessionChildCapability,
) !bool {
    var contains_unverified_artifacts = false;
    for (history) |*turn| {
        const execution = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| &entry.execution,
            .interrupted => |*entry| &entry.execution,
        };
        try copyRecoveredExecutionManagedChildren(
            alloc,
            execution,
            source,
            target,
            &contains_unverified_artifacts,
        );
        if (turn.* == .interrupted) {
            const presentation = if (turn.interrupted.cancelled_command) |*value|
                value
            else
                continue;
            if (presentation.output_replay) |replay| {
                contains_unverified_artifacts =
                    (try copyRecoveredCommandReplay(
                        alloc,
                        source,
                        target,
                        replay,
                    )) or contains_unverified_artifacts;
            }
            if (presentation.command_artifact_handle) |handle| {
                const authenticated = recoveredCommandArtifactIsAuthenticated(
                    .command_log,
                    handle,
                );
                try copyRecoveredManagedChild(
                    alloc,
                    source,
                    target,
                    .command_log,
                    handle,
                    null,
                    null,
                );
                if (!authenticated) contains_unverified_artifacts = true;
            }
        }
    }
    if (recovery_checkpoint) |checkpoint| {
        try copyRecoveredExecutionManagedChildren(
            alloc,
            &checkpoint.execution,
            source,
            target,
            &contains_unverified_artifacts,
        );
    }
    return contains_unverified_artifacts;
}

fn copyRecoveredCommandReplay(
    alloc: Allocator,
    source: *session_child_store.SessionChildCapability,
    target: *session_child_store.SessionChildCapability,
    replay: core_types.CommandOutputReplay,
) !bool {
    switch (replay) {
        .available => |descriptor| {
            const authenticated = recoveredCommandArtifactIsAuthenticated(
                .command_replay,
                descriptor.handle,
            );
            try copyRecoveredManagedChild(
                alloc,
                source,
                target,
                .command_replay,
                descriptor.handle,
                null,
                descriptor.framed_bytes,
            );
            var reader = command_replay_store.Reader.open(
                alloc,
                target,
                descriptor,
            ) catch |err| return recoveryArtifactReadError(err);
            defer reader.deinit();
            while (reader.nextByte() catch |err|
                return recoveryArtifactReadError(err)) |_|
            {}
            return !authenticated;
        },
        .unavailable => return false,
    }
}

fn copyRecoveredManagedChild(
    alloc: Allocator,
    source: *session_child_store.SessionChildCapability,
    target: *session_child_store.SessionChildCapability,
    contract: RecoveredArtifactContract,
    handle: []const u8,
    expected_call_id: ?[]const u8,
    expected_bytes: ?usize,
) !void {
    const kind = recoveredArtifactKind(contract);
    if (contract == .diff_content) {
        const call_id = expected_call_id orelse
            return error.SessionRecoveryBoundaryInvalid;
        if (!result_store.diffContentHandleMatchesCall(handle, call_id)) {
            return error.SessionRecoveryBoundaryInvalid;
        }
    }
    var source_file = source.openFileReadOnly(
        alloc,
        kind,
        handle,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SessionRecoveryBoundaryInvalid,
        else => return err,
    };
    defer source_file.deinit();
    const source_stat = try source_file.stat();
    if (contract == .diff_content and
        source_stat.size > result_store.diff_content_max_bytes)
    {
        return error.SessionRecoveryBoundaryInvalid;
    }
    if (expected_bytes) |expected| {
        const expected_u64 = std.math.cast(u64, expected) orelse
            return error.SessionRecoveryBoundaryInvalid;
        if (source_stat.size != expected_u64) {
            return error.SessionRecoveryBoundaryInvalid;
        }
    }
    var target_file = target.createExclusiveFile(
        alloc,
        kind,
        handle,
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {
            var existing = try target.openFileReadOnly(alloc, kind, handle);
            defer existing.deinit();
            const existing_stat = try existing.stat();
            if (existing_stat.size != source_stat.size) {
                return error.SessionRecoveryBoundaryInvalid;
            }
            const source_digest = try managedFileDigest(
                &source_file,
                source_stat.size,
            );
            const existing_digest = try managedFileDigest(
                &existing,
                existing_stat.size,
            );
            if (!std.mem.eql(u8, &source_digest, &existing_digest)) {
                return error.SessionRecoveryBoundaryInvalid;
            }
            try validateRecoveredManagedChildDigest(
                contract,
                handle,
                expected_call_id,
                expected_bytes,
                source_digest,
            );
            try validateRecoveredManagedChildContent(
                alloc,
                contract,
                expected_call_id,
                target,
                handle,
            );
            return;
        },
        else => return err,
    };
    var copied = false;
    defer {
        target_file.deinit();
        if (!copied) target.delete(kind, handle) catch {};
    }

    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    var source_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (offset < source_stat.size) {
        const remaining = source_stat.size - offset;
        const chunk_len = std.math.cast(
            usize,
            @min(remaining, buffer.len),
        ) orelse return error.SessionChildStoreFailed;
        const read_len = source_file.readRangeInto(
            offset,
            buffer[0..chunk_len],
        ) catch |err| return recoveryArtifactReadError(err);
        if (read_len == 0) return error.SessionRecoveryBoundaryInvalid;
        source_hasher.update(buffer[0..read_len]);
        try target_file.writeAll(buffer[0..read_len]);
        offset = std.math.add(u64, offset, read_len) catch
            return error.SessionChildStoreFailed;
    }
    try target_file.sync();
    var source_digest: [32]u8 = undefined;
    source_hasher.final(&source_digest);
    try validateRecoveredManagedChildDigest(
        contract,
        handle,
        expected_call_id,
        expected_bytes,
        source_digest,
    );
    try validateRecoveredManagedChildContent(
        alloc,
        contract,
        expected_call_id,
        target,
        handle,
    );
    var target_reader = try target.openFileReadOnly(alloc, kind, handle);
    defer target_reader.deinit();
    const target_digest = try managedFileDigest(
        &target_reader,
        source_stat.size,
    );
    if (!std.mem.eql(u8, &source_digest, &target_digest)) {
        return error.SessionChildStoreFailed;
    }
    copied = true;
}

fn managedFileDigest(
    file: *session_child_store.ManagedFile,
    size: u64,
) ![32]u8 {
    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (offset < size) {
        const remaining = size - offset;
        const chunk_len = std.math.cast(
            usize,
            @min(remaining, buffer.len),
        ) orelse return error.SessionRecoveryBoundaryInvalid;
        const read_len = file.readRangeInto(
            offset,
            buffer[0..chunk_len],
        ) catch |err| return recoveryArtifactReadError(err);
        if (read_len == 0) return error.SessionRecoveryBoundaryInvalid;
        hasher.update(buffer[0..read_len]);
        offset = std.math.add(u64, offset, read_len) catch
            return error.SessionRecoveryBoundaryInvalid;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn recoveryArtifactReadError(err: anyerror) anyerror {
    return switch (err) {
        error.FileNotFound,
        error.InvalidReplayHeader,
        error.ReplaySizeMismatch,
        error.ReplayTooLarge,
        error.ReplayOffsetTooLarge,
        error.UnexpectedEndOfReplay,
        error.EndOfStream,
        error.TruncatedReplayFrame,
        error.InvalidReplayStream,
        error.EmptyReplayFrame,
        error.ReplayFrameTooLarge,
        error.Overflow,
        => error.SessionRecoveryBoundaryInvalid,
        else => err,
    };
}

fn validateRecoveredManagedChildContent(
    alloc: Allocator,
    contract: RecoveredArtifactContract,
    expected_call_id: ?[]const u8,
    target: *session_child_store.SessionChildCapability,
    handle: []const u8,
) !void {
    if (contract != .diff_content) return;
    const call_id = expected_call_id orelse
        return error.SessionRecoveryBoundaryInvalid;
    var pack = result_store.loadDiffContentManaged(
        alloc,
        target,
        call_id,
        handle,
    ) catch |err| switch (err) {
        error.InvalidResultHandle,
        error.ResultHandleNotFound,
        error.ResultTooLarge,
        error.DiffContentArtifactChanged,
        error.InvalidDiffContentArtifact,
        => return error.SessionRecoveryBoundaryInvalid,
        else => return err,
    };
    pack.deinit(alloc);
}

fn validateRecoveredManagedChildDigest(
    contract: RecoveredArtifactContract,
    handle: []const u8,
    expected_call_id: ?[]const u8,
    expected_bytes: ?usize,
    digest: [32]u8,
) !void {
    switch (contract) {
        .tool_output => {
            if (!result_store.isStoredTextHandle(handle) or
                !result_store.handleMatchesContentDigest(handle, digest))
            {
                return error.SessionRecoveryBoundaryInvalid;
            }
        },
        .tool_images => {
            if (!result_store.isImageHandle(handle) or
                !result_store.handleMatchesContentDigest(handle, digest))
            {
                return error.SessionRecoveryBoundaryInvalid;
            }
        },
        .diff_content => {
            const call_id = expected_call_id orelse
                return error.SessionRecoveryBoundaryInvalid;
            if (!result_store.diffContentHandleMatchesCall(handle, call_id) or
                !result_store.diffContentHandleMatchesContentDigest(
                    handle,
                    digest,
                ))
            {
                return error.SessionRecoveryBoundaryInvalid;
            }
        },
        .command_replay => {
            if (expected_bytes == null or
                !command_replay_store.isReplayHandle(handle) or
                (command_replay_store.hasContentDigest(handle) and
                    !command_replay_store.handleMatchesContentDigest(
                        handle,
                        digest,
                    )))
            {
                return error.SessionRecoveryBoundaryInvalid;
            }
        },
        .command_log => {
            if (expected_bytes != null or
                !isCommandLogHandle(handle) or
                (artifact_digest.hasContentDigest(handle, ".log") and
                    !artifact_digest.handleMatchesContentDigest(
                        handle,
                        ".log",
                        digest,
                    )))
            {
                return error.SessionRecoveryBoundaryInvalid;
            }
        },
    }
}

fn canonicalSnapshotLeaf(image: session.ImageAttachment, stored: []const u8) ![]const u8 {
    if (std.Io.Dir.path.isAbsolute(stored)) return error.InvalidSessionFormat;
    const prefix = "images/";
    if (!std.mem.startsWith(u8, stored, prefix)) return error.InvalidSessionFormat;
    const leaf = stored[prefix.len..];
    if (leaf.len == 0 or
        std.mem.findAny(u8, leaf, "/\\") != null or
        std.mem.eql(u8, leaf, ".") or
        std.mem.eql(u8, leaf, ".."))
    {
        return error.InvalidSessionFormat;
    }

    const digest = image.snapshot_sha256 orelse return error.InvalidSessionFormat;
    if (image.id == 0 or digest.len != 64) return error.InvalidSessionFormat;
    for (digest) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return error.InvalidSessionFormat;
        }
    }
    var expected_buffer: [128]u8 = undefined;
    const expected = std.mem.print(
        &expected_buffer,
        "image-{d}-{s}.bin",
        .{ image.id, digest[0..16] },
    ) catch return error.InvalidSessionFormat;
    if (!std.mem.eql(u8, leaf, expected)) return error.InvalidSessionFormat;
    return leaf;
}

fn resolveSessionSnapshotLocators(
    alloc: Allocator,
    history: []session.HistoryTurn,
    checkpoint: ?*session_codec.RecoveryCheckpoint,
    sessions_dir: []const u8,
    session_id: []const u8,
) !void {
    const session_dir = try sessionDirPath(alloc, sessions_dir, session_id);
    defer alloc.free(session_dir);
    const image_dir = try std.Io.Dir.path.join(alloc, &.{ session_dir, "images" });
    defer alloc.free(image_dir);

    for (history) |*turn| {
        const images = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| entry.user.images,
            .interrupted => |*entry| entry.user.images,
        };
        try resolveImageSnapshotLocators(alloc, images, image_dir);
    }
    if (checkpoint) |value| try resolveImageSnapshotLocators(alloc, value.user.images, image_dir);
}

fn resolveImageSnapshotLocators(
    alloc: Allocator,
    images: []session.ImageAttachment,
    image_dir: []const u8,
) !void {
    for (images) |*image| {
        const stored = image.snapshot_path orelse continue;
        const leaf = try canonicalSnapshotLeaf(image.*, stored);
        const resolved = try std.Io.Dir.path.join(alloc, &.{ image_dir, leaf });
        alloc.free(stored);
        image.snapshot_path = resolved;
    }
}

pub fn isPristineStartedSession(loaded: *const LoadedWritableSession) bool {
    return loaded.freshly_started and
        std.mem.eql(u8, loaded.active_id, loaded.state.id) and
        std.mem.eql(u8, loaded.log.session_id, loaded.state.id) and
        loaded.state.history.len == 0 and
        loaded.state.context_history_start == 0 and
        loaded.state.total_input_tokens == 0 and
        loaded.state.total_output_tokens == 0 and
        loaded.state.recovery_checkpoint == null and
        loaded.migration_source_schema_version == null and
        loaded.migration_source_bytes == null;
}

fn loadedWriterBelongsToStore(
    store: Store,
    alloc: Allocator,
    loaded: *const LoadedWritableSession,
) !bool {
    return loadedWriterBelongsToRoot(
        alloc,
        loaded,
        store.sessions_dir,
    );
}

fn loadedWriterBelongsToRoot(
    alloc: Allocator,
    loaded: *const LoadedWritableSession,
    root_path: []const u8,
) !bool {
    const actual_path = try io_mod.dirRealpathAlloc(
        alloc,
        loaded.log.dir.dir,
        "",
    );
    defer alloc.free(actual_path);
    const expected_path = try sessionDirPath(
        alloc,
        root_path,
        loaded.active_id,
    );
    defer alloc.free(expected_path);
    return std.mem.eql(u8, expected_path, actual_path);
}

fn prepareWritableSessionDir(dir: std.Io.Dir) !void {
    const permissions = std.Io.File.Permissions.fromMode(0o700);
    dir.setPermissions(io_mod.getIo(), permissions) catch
        return error.PrivateStatePermissionsUnsupported;
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory) return error.SessionPathUnsafe;
    if (stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn initWithHome(alloc: Allocator, home: []const u8, workspace_root: []const u8, ensure_layout: bool) !Store {
    const trimmed_workspace = normalizeWorkspaceRoot(workspace_root);
    if (trimmed_workspace.len == 0) return error.InvalidWorkspaceRoot;

    var canonical_root = session_log.Root.initFromHome(
        alloc,
        home,
        if (ensure_layout) .writable else .read_only,
    ) catch |err| switch (err) {
        error.OutOfMemory,
        error.PrivateStatePermissionsUnsupported,
        error.SessionPathUnsafe,
        => return err,
        else => {
            if (!ensure_layout) return err;
            debug_trace.logf(
                "session",
                "event=writable_layout_failed source_error={s} mapped_error=DurableLayoutFailed",
                .{@errorName(err)},
            );
            return error.DurableLayoutFailed;
        },
    };
    errdefer canonical_root.deinit(alloc);
    const sessions_dir = try alloc.dupe(u8, canonical_root.display_root);
    errdefer alloc.free(sessions_dir);
    const home_dir = try alloc.dupe(u8, home);
    errdefer alloc.free(home_dir);
    const owned_workspace = try alloc.dupe(u8, trimmed_workspace);
    errdefer alloc.free(owned_workspace);
    return .{
        .sessions_dir = sessions_dir,
        .home_dir = home_dir,
        .workspace_root = owned_workspace,
        .canonical_root = canonical_root,
    };
}
fn parseRememberedSessionId(bytes: []const u8) ![]const u8 {
    if (bytes.len < 2 or bytes.len > 256 or bytes[bytes.len - 1] != '\n') return error.InvalidRememberedSession;
    const id = bytes[0 .. bytes.len - 1];
    validateSessionId(id) catch return error.InvalidRememberedSession;
    return id;
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

const std = @import("std");
const contracts = @import("contracts.zig");
const operation = @import("operation.zig");
const recovery = @import("recovery.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_layout = @import("../session/session_layout.zig");
const process_identity = @import("../execution/process_identity.zig");
const process_provider_mod = @import(
    "../execution/process_provider.zig",
);
const profile_paths = @import("../shared/profile_paths.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

pub const per_session_payload_limit: u64 = 64 * 1024 * 1024;
pub const profile_payload_limit: u64 = 512 * 1024 * 1024;
const default_segment_bytes: u64 = 1024 * 1024;
const max_record_bytes: usize = 1024 * 1024;
const max_event_bytes: usize = 64 * 1024;
const event_retention_limit: u64 = 256;
const record_schema_version: u16 = 2;
const authority_schema_version: u16 = 3;
const owner_catalog_authority_schema_version: u16 = 2;
const event_schema_version: u16 = 1;
const close_transaction_schema_version: u16 = 2;
const checkpoint_schema_version: u16 = 1;
const checkpoint_magic = "FXCP";
const checkpoint_header_bytes: usize = 4 + 2 + 2 + 8 + 8 + 4 + 32;

pub const FailurePoint = enum {
    grant,
    start,
    append,
    acknowledgement,
    cancellation,
    checkpoint_replacement,
    revoke,
    close,
    finalization,
    after_journal_create,
    after_proof_write,
    after_authority_write,
    after_close_authority_write,
    after_close_record_write,
    after_close_authority_event,
    after_close_lifecycle_record,
    after_close_lifecycle_event,
    after_close_cleanup,
    before_close_recovery_oom,
    before_close_recovery_capability,
    after_journal_sync,
    after_checkpoint_write,
    after_checkpoint_record,
    after_event_write,
    after_acknowledgement_record,
    after_eviction_record,
};

const Options = struct {
    per_session_limit: u64 = per_session_payload_limit,
    profile_limit: u64 = profile_payload_limit,
    segment_bytes: u64 = default_segment_bytes,
    fail_at: ?FailurePoint = null,

    fn validate(self: Options) error{InvalidStoreOptions}!void {
        if (self.per_session_limit == 0 or self.profile_limit == 0 or
            self.segment_bytes == 0 or self.per_session_limit > self.profile_limit)
        {
            return error.InvalidStoreOptions;
        }
    }
};

pub const PersistedTermination = union(enum) {
    exited: i32,
    signal: u32,

    fn validate(self: PersistedTermination) error{InvalidTerminalRecord}!void {
        const outcome: contracts.ReturnOutcome = switch (self) {
            .exited => |code| .{ .exited = code },
            .signal => |signal| .{ .signal = signal },
        };
        outcome.validate() catch return error.InvalidTerminalRecord;
    }
};

pub const DurableEvent = struct {
    id: u64,
    kind: contracts.HostEvent,
    lifecycle: contracts.Lifecycle,
    cursor: contracts.RawCursor,
    created_at_ms: i64,

    pub fn validate(self: DurableEvent) error{InvalidDurableEvent}!void {
        if (self.id == 0) return error.InvalidDurableEvent;
        self.cursor.validate() catch return error.InvalidDurableEvent;
    }
};

pub const JournalFile = struct {
    file_id: u64,
    range: contracts.RawRange,
    payload_bytes: u64,
    checksum: contracts.CheckpointChecksum,

    fn validate(self: JournalFile) error{InvalidTerminalRecord}!void {
        if (self.file_id == 0) return error.InvalidTerminalRecord;
        self.range.validate() catch return error.InvalidTerminalRecord;
        if (self.range.start.segment != self.range.end.segment or
            self.range.end.offset - self.range.start.offset != self.payload_bytes)
        {
            return error.InvalidTerminalRecord;
        }
    }
};

const EventWire = struct {
    schema_version: u16 = event_schema_version,
    event: DurableEvent,
};

const CloseTransaction = struct {
    schema_version: u16 = close_transaction_schema_version,
    updated_at_ms: i64,
    initiator_verifier: ?contracts.CheckpointChecksum,
    authority_generation: contracts.AuthorityGeneration,
    authority_event: DurableEvent,
    lifecycle_event: ?DurableEvent = null,

    fn validate(self: CloseTransaction) !void {
        if (self.schema_version != close_transaction_schema_version or
            self.updated_at_ms < 0)
        {
            return error.InvalidCloseTransaction;
        }
        self.authority_generation.validate() catch
            return error.InvalidCloseTransaction;
        self.authority_event.validate() catch
            return error.InvalidCloseTransaction;
        if (self.authority_event.kind != .authority_revoked) {
            return error.InvalidCloseTransaction;
        }
        if (self.lifecycle_event) |event| {
            event.validate() catch return error.InvalidCloseTransaction;
            if (event.kind != .lifecycle or event.lifecycle != .closed or
                event.id <= self.authority_event.id)
            {
                return error.InvalidCloseTransaction;
            }
        }
    }
};

const CloseRecoveryErrorClass = enum {
    isolate,
    propagate,
};

fn classify_close_recovery_error(err: anyerror) CloseRecoveryErrorClass {
    return switch (err) {
        error.InvalidCloseTransaction, error.StreamTooLong => .isolate,
        else => .propagate,
    };
}

pub const Record = struct {
    session_id: []u8,
    owner_session_id: []u8,
    host_identity: []u8,
    backend_identity: []u8,
    shell: []u8,
    cwd: []u8,
    command: ?[]u8,
    timeout_ms: ?u64,
    timeout_at_ms: ?i64,
    timed_out: bool,
    backend: contracts.Backend,
    lifecycle: contracts.Lifecycle,
    attention: contracts.AttentionState,
    dimensions: contracts.Dimensions,
    pid: ?[]u8,
    process_token: ?[]u8,
    takeover_owner_pid: ?[]u8,
    takeover_owner_process_token: ?[]u8,
    output_cursor: contracts.RawCursor,
    available_from: contracts.RawCursor,
    raw_gap: ?contracts.RawGap,
    raw_replay_exact: bool,
    screen_recovery: contracts.ScreenRecovery,
    checkpoint_payload_bytes: u64,
    journal_payload_bytes: u64,
    journal_files: []JournalFile,
    journal_cleanup_through: u64,
    checkpoint_generation: u64,
    checkpoint_cleanup_generation: ?u64,
    next_event_id: u64,
    acknowledged_event_id: u64,
    event_gap_through: u64,
    event_cleanup_through: u64,
    monitor_count: u16,
    authority_generation: contracts.AuthorityGeneration,
    authority_revoked: bool,
    termination: ?PersistedTermination,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: *Record, alloc: Allocator) void {
        alloc.free(self.journal_files);
        if (self.takeover_owner_process_token) |value| alloc.free(value);
        if (self.takeover_owner_pid) |value| alloc.free(value);
        if (self.process_token) |value| alloc.free(value);
        if (self.pid) |value| alloc.free(value);
        if (self.command) |value| alloc.free(value);
        alloc.free(self.cwd);
        alloc.free(self.shell);
        alloc.free(self.backend_identity);
        alloc.free(self.host_identity);
        alloc.free(self.owner_session_id);
        alloc.free(self.session_id);
        self.* = undefined;
    }

    pub fn validate(self: Record) error{InvalidTerminalRecord}!void {
        contracts.validate_session_id(self.session_id) catch
            return error.InvalidTerminalRecord;
        contracts.validate_session_id(self.owner_session_id) catch
            return error.InvalidTerminalRecord;
        if (self.host_identity.len == 0 or self.backend_identity.len == 0 or
            self.shell.len == 0 or self.cwd.len == 0 or
            !std.Io.Dir.path.isAbsolute(self.cwd))
        {
            return error.InvalidTerminalRecord;
        }
        if ((self.timed_out and
            (self.timeout_ms == null or self.timeout_at_ms == null)) or
            (self.timeout_at_ms != null and self.timeout_ms == null) or
            if (self.timeout_at_ms) |deadline|
                deadline < self.created_at_ms
            else
                false)
        {
            return error.InvalidTerminalRecord;
        }
        self.attention.validate() catch return error.InvalidTerminalRecord;
        self.dimensions.validate() catch return error.InvalidTerminalRecord;
        self.output_cursor.validate() catch return error.InvalidTerminalRecord;
        self.available_from.validate() catch return error.InvalidTerminalRecord;
        if (contracts.compare_raw_cursors(
            self.available_from,
            self.output_cursor,
        ) == .gt) return error.InvalidTerminalRecord;
        if (self.raw_gap) |gap| {
            gap.validate() catch return error.InvalidTerminalRecord;
            const is_prefix_gap = contracts.compare_raw_cursors(
                gap.available_from,
                self.available_from,
            ) == .eq;
            if ((!is_prefix_gap and contracts.compare_raw_cursors(
                gap.missing_from,
                self.available_from,
            ) == .lt) or
                contracts.compare_raw_cursors(
                    gap.available_from,
                    self.output_cursor,
                ) == .gt)
            {
                return error.InvalidTerminalRecord;
            }
        }
        switch (self.screen_recovery) {
            .available => |checkpoint| {
                if (self.checkpoint_generation == 0 or
                    self.checkpoint_payload_bytes == 0)
                {
                    return error.InvalidTerminalRecord;
                }
                checkpoint.validate_header() catch
                    return error.InvalidTerminalRecord;
                if (@as(u64, checkpoint.payload_len) !=
                    self.checkpoint_payload_bytes)
                {
                    return error.InvalidTerminalRecord;
                }
                if (contracts.compare_raw_cursors(
                    checkpoint.applied_cursor,
                    self.output_cursor,
                ) == .gt) return error.InvalidTerminalRecord;
            },
            .unavailable => {
                if (self.checkpoint_generation != 0 or
                    self.checkpoint_payload_bytes != 0)
                {
                    return error.InvalidTerminalRecord;
                }
            },
        }
        self.authority_generation.validate() catch
            return error.InvalidTerminalRecord;
        if (self.next_event_id == 0 or
            self.acknowledged_event_id >= self.next_event_id or
            self.event_gap_through >= self.next_event_id or
            self.event_cleanup_through >= self.next_event_id or
            self.event_cleanup_through > @max(
                self.acknowledged_event_id,
                self.event_gap_through,
            ))
        {
            return error.InvalidTerminalRecord;
        }
        var journal_bytes: u64 = 0;
        var internal_gap_seen = false;
        for (self.journal_files, 0..) |file, index| {
            try file.validate();
            journal_bytes = std.math.add(
                u64,
                journal_bytes,
                file.payload_bytes,
            ) catch return error.InvalidTerminalRecord;
            if (index == 0) {
                if (contracts.compare_raw_cursors(
                    file.range.start,
                    self.available_from,
                ) != .eq) return error.InvalidTerminalRecord;
            } else {
                const previous = self.journal_files[index - 1];
                if (file.file_id <= previous.file_id) {
                    return error.InvalidTerminalRecord;
                }
                if (contracts.compare_raw_cursors(
                    previous.range.end,
                    file.range.start,
                ) != .eq) {
                    const gap = self.raw_gap orelse
                        return error.InvalidTerminalRecord;
                    if (internal_gap_seen or
                        contracts.compare_raw_cursors(
                            previous.range.end,
                            gap.missing_from,
                        ) != .eq or
                        contracts.compare_raw_cursors(
                            file.range.start,
                            gap.available_from,
                        ) != .eq)
                    {
                        return error.InvalidTerminalRecord;
                    }
                    internal_gap_seen = true;
                }
            }
        }
        if (self.raw_gap) |gap| {
            const prefix_gap = contracts.compare_raw_cursors(
                gap.available_from,
                self.available_from,
            ) == .eq;
            if (!prefix_gap and !internal_gap_seen) {
                return error.InvalidTerminalRecord;
            }
        }
        if (journal_bytes != self.journal_payload_bytes) {
            return error.InvalidTerminalRecord;
        }
        if (self.journal_files.len == 0) {
            if (self.journal_payload_bytes != 0 or
                contracts.compare_raw_cursors(
                    self.available_from,
                    self.output_cursor,
                ) != .eq)
            {
                return error.InvalidTerminalRecord;
            }
        } else if (contracts.compare_raw_cursors(
            self.journal_files[self.journal_files.len - 1].range.end,
            self.output_cursor,
        ) != .eq) {
            return error.InvalidTerminalRecord;
        }
        if (self.termination) |termination| try termination.validate();
        if (self.process_token) |token| {
            _ = process_identity.ProcessInstanceToken.parse(token) catch
                return error.InvalidTerminalRecord;
        }
        if ((self.takeover_owner_pid == null) !=
            (self.takeover_owner_process_token == null))
        {
            return error.InvalidTerminalRecord;
        }
        const human_takeover = self.attention.attention == .user_takeover and
            self.attention.write_lease == .human;
        if (human_takeover != (self.takeover_owner_pid != null)) {
            return error.InvalidTerminalRecord;
        }
        if (self.takeover_owner_pid) |pid| {
            _ = std.fmt.parseInt(std.posix.pid_t, pid, 10) catch
                return error.InvalidTerminalRecord;
            _ = process_identity.ProcessInstanceToken.parse(
                self.takeover_owner_process_token.?,
            ) catch return error.InvalidTerminalRecord;
        }
        const payload_total = std.math.add(
            u64,
            self.checkpoint_payload_bytes,
            self.journal_payload_bytes,
        ) catch return error.InvalidTerminalRecord;
        if (payload_total > per_session_payload_limit) {
            return error.InvalidTerminalRecord;
        }
    }
};

const RecordWire = struct {
    schema_version: u16 = record_schema_version,
    session_id: []const u8,
    owner_session_id: []const u8,
    host_identity: []const u8,
    backend_identity: []const u8,
    shell: []const u8,
    cwd: []const u8,
    command: ?[]const u8,
    timeout_ms: ?u64 = null,
    timeout_at_ms: ?i64 = null,
    timed_out: bool = false,
    backend: contracts.Backend,
    lifecycle: contracts.Lifecycle,
    attention: contracts.AttentionState,
    dimensions: contracts.Dimensions,
    pid: ?[]const u8,
    process_token: ?[]const u8,
    takeover_owner_pid: ?[]const u8 = null,
    takeover_owner_process_token: ?[]const u8 = null,
    output_cursor: contracts.RawCursor,
    available_from: contracts.RawCursor,
    raw_gap: ?contracts.RawGap,
    raw_replay_exact: bool = false,
    screen_recovery: contracts.ScreenRecovery,
    checkpoint_payload_bytes: u64,
    journal_payload_bytes: u64,
    journal_files: []const JournalFile,
    journal_cleanup_through: u64,
    checkpoint_generation: u64,
    checkpoint_cleanup_generation: ?u64,
    next_event_id: u64,
    acknowledged_event_id: u64,
    event_gap_through: u64,
    event_cleanup_through: u64,
    monitor_count: u16,
    authority_generation: contracts.AuthorityGeneration,
    authority_revoked: bool,
    termination: ?PersistedTermination,
    created_at_ms: i64,
    updated_at_ms: i64,
};

const AuthorityWire = struct {
    schema_version: u16 = authority_schema_version,
    session_id: []const u8,
    grant: contracts.AuthorityGrant,
    verifier: contracts.CheckpointChecksum,
    revoked: bool,
};

const OwnerCatalogAuthorityWire = struct {
    schema_version: u16 = owner_catalog_authority_schema_version,
    principal: contracts.OwnerCatalogPrincipal,
    actor: contracts.ActorRole,
    verifier: contracts.CheckpointChecksum,
};

pub const ProfileStore = struct {
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    sessions_dir: io_mod.VerifiedDir,
    display_sessions_path: []u8,
    /// `~/.fx`, kept open to reach terminal state kept outside a session
    /// folder: `~/.fx/terminal/{id}`, or an older `~/.fx/session-files/{id}`.
    fx_dir: io_mod.VerifiedDir,
    /// `~/.fx/terminal` and `~/.fx/session-files`, as `outside_roots`.
    display_outside_paths: [outside_roots.len][]u8,
    options: Options,
    mutex: std.Io.Mutex = .init,
    residents: std.ArrayList(*DurableSession) = .empty,

    pub fn init(
        alloc: Allocator,
        home: []const u8,
        process_provider: process_provider_mod.Provider,
    ) !ProfileStore {
        return init_with_options(alloc, home, process_provider, .{});
    }

    fn init_with_options(
        alloc: Allocator,
        home: []const u8,
        process_provider: process_provider_mod.Provider,
        options: Options,
    ) !ProfileStore {
        try options.validate();
        var home_dir = io_mod.VerifiedDir{
            .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{
                .iterate = true,
                .follow_symlinks = false,
            }),
        };
        defer home_dir.close();
        var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(
            &home_dir,
            profile_paths.root_dir_name,
        );
        errdefer fx_dir.close();
        var sessions_dir = try io_mod.openOrCreateVerifiedPrivateDir(
            &fx_dir,
            profile_paths.sessions_dir_name,
        );
        errdefer sessions_dir.close();
        const display_sessions_path = try profile_paths.sessionsDir(alloc, home);
        errdefer alloc.free(display_sessions_path);
        var display_outside_paths: [outside_roots.len][]u8 = undefined;
        var joined: usize = 0;
        errdefer for (display_outside_paths[0..joined]) |path| alloc.free(path);
        for (outside_roots, &display_outside_paths) |root_name, *path| {
            path.* = try std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, root_name });
            joined += 1;
        }
        return .{
            .alloc = alloc,
            .process_provider = process_provider,
            .sessions_dir = sessions_dir,
            .display_sessions_path = display_sessions_path,
            .fx_dir = fx_dir,
            .display_outside_paths = display_outside_paths,
            .options = options,
        };
    }

    pub fn deinit(self: *ProfileStore) void {
        std.debug.assert(self.residents.items.len == 0);
        self.residents.deinit(self.alloc);
        self.alloc.free(self.display_sessions_path);
        for (self.display_outside_paths) |path| self.alloc.free(path);
        self.sessions_dir.close();
        self.fx_dir.close();
        self.* = undefined;
    }

    pub fn register_resident(
        self: *ProfileStore,
        session: *DurableSession,
    ) Allocator.Error!void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        try self.register_resident_locked(session);
    }

    fn register_resident_locked(
        self: *ProfileStore,
        session: *DurableSession,
    ) Allocator.Error!void {
        for (self.residents.items) |resident| {
            if (resident == session) return;
            std.debug.assert(!std.mem.eql(
                u8,
                resident.record.session_id,
                session.record.session_id,
            ));
        }
        try self.residents.append(self.alloc, session);
        session.registered = true;
    }

    pub fn unregister_resident(
        self: *ProfileStore,
        session: *DurableSession,
    ) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (self.residents.items, 0..) |resident, index| {
            if (resident != session) continue;
            _ = self.residents.swapRemove(index);
            session.registered = false;
            return;
        }
    }

    fn resident_by_id(
        self: *ProfileStore,
        session_id: []const u8,
    ) ?*DurableSession {
        for (self.residents.items) |resident| {
            if (std.mem.eql(u8, resident.record.session_id, session_id)) {
                return resident;
            }
        }
        return null;
    }

    /// A capability over an owner's terminal state or proofs. Only a new
    /// terminal makes a v2 owner's folder (`create_owner`); every other use
    /// finds it or fails with FileNotFound.
    fn open_capability(
        self: *ProfileStore,
        owner_session_id: []const u8,
        comptime proof_route: bool,
        create_owner: bool,
    ) !session_child_store.SessionChildCapability {
        try session_layout.validateSessionId(owner_session_id);
        var owner = try self.open_owner(owner_session_id, create_owner);
        defer owner.deinit(self.alloc);
        const owner_dir = owner.dir;
        const display_path = owner.display_path;
        return if (proof_route)
            session_child_store.SessionChildCapability.initTerminalProofs(
                self.alloc,
                owner_dir,
                display_path,
                .writable,
                .{},
            )
        else
            session_child_store.SessionChildCapability.initTerminalState(
                self.alloc,
                owner_dir,
                display_path,
                .writable,
                .{},
            );
    }

    const OwnerFolder = struct {
        dir: std.Io.Dir,
        display_path: []u8,

        fn deinit(owner: *OwnerFolder, alloc: Allocator) void {
            owner.dir.close(io_mod.getIo());
            alloc.free(owner.display_path);
        }
    };

    /// Where terminal state lives outside a session folder, in order:
    /// `~/.fx/terminal`, then older side folders. A new owner folder is made
    /// only in the first.
    const outside_roots = [_][]const u8{ profile_paths.terminal_dir_name, profile_paths.session_files_dir_name };

    /// The folder an owner keeps its terminal state in: its session folder,
    /// or a folder outside it. `create` makes
    /// `~/.fx/terminal/{id}` (`0700`) when the owner has none.
    fn open_owner(self: *ProfileStore, owner_session_id: []const u8, create: bool) !OwnerFolder {
        const zio = io_mod.getIo();
        const options: std.Io.Dir.OpenOptions = .{ .iterate = true, .follow_symlinks = false };
        if (self.sessions_dir.dir.openDir(zio, owner_session_id, options)) |found| {
            var dir = found;
            errdefer dir.close(zio);
            return .{ .dir = dir, .display_path = try session_layout.sessionDirPath(self.alloc, self.display_sessions_path, owner_session_id) };
        } else |err| switch (err) {
            error.FileNotFound => {},
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        }
        for (outside_roots, 0..) |root_name, index| {
            var root = (try self.open_outside_root(root_name, false)) orelse continue;
            defer root.close();
            var dir = root.dir.openDir(zio, owner_session_id, options) catch |err| switch (err) {
                error.FileNotFound => continue,
                error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
                else => return err,
            };
            errdefer dir.close(zio);
            return .{ .dir = dir, .display_path = try session_layout.sessionDirPath(self.alloc, self.display_outside_paths[index], owner_session_id) };
        }
        if (!create) return error.FileNotFound;
        var root = (try self.open_outside_root(outside_roots[0], true)).?;
        defer root.close();
        var made = try io_mod.openOrCreateVerifiedPrivateDir(&root, owner_session_id);
        errdefer made.close();
        return .{ .dir = made.dir, .display_path = try session_layout.sessionDirPath(self.alloc, self.display_outside_paths[0], owner_session_id) };
    }

    /// `~/.fx/{root_name}`, or null when nothing has made it yet. Opened
    /// for each use: it can appear after this store opened.
    fn open_outside_root(self: *ProfileStore, root_name: []const u8, create: bool) !?io_mod.VerifiedDir {
        if (create) return try io_mod.openOrCreateVerifiedPrivateDir(&self.fx_dir, root_name);
        return io_mod.openVerifiedPrivateDirIfPresent(&self.fx_dir, root_name);
    }

    /// Every owner folder: session folders, then the folders of each
    /// outside root whose id no earlier root has. A name lasts until the
    /// next call.
    const OwnerIterator = struct {
        store: *ProfileStore,
        sessions: std.Io.Dir.Iterator,
        roots: [outside_roots.len]?io_mod.VerifiedDir,
        root_index: usize = 0,
        root_iter: ?std.Io.Dir.Iterator = null,

        fn next(it: *OwnerIterator) !?[]const u8 {
            const zio = io_mod.getIo();
            while (try it.sessions.next(zio)) |entry| {
                if (isOwner(entry)) return entry.name;
            }
            while (it.root_index < it.roots.len) : ({
                it.root_index += 1;
                it.root_iter = null;
            }) {
                const root = if (it.roots[it.root_index]) |*value| value else continue;
                if (it.root_iter == null) it.root_iter = root.dir.iterate();
                while (try it.root_iter.?.next(zio)) |entry| {
                    if (!isOwner(entry) or it.seenEarlier(entry.name)) continue;
                    return entry.name;
                }
            }
            return null;
        }

        /// An id with a folder in an earlier root is that owner, seen once.
        fn seenEarlier(it: *OwnerIterator, name: []const u8) bool {
            const zio = io_mod.getIo();
            const options: std.Io.Dir.StatFileOptions = .{ .follow_symlinks = false };
            if (it.store.sessions_dir.dir.statFile(zio, name, options)) |_| return true else |_| {}
            for (it.roots[0..it.root_index]) |*maybe| {
                const root = if (maybe.*) |*value| value else continue;
                if (root.dir.statFile(zio, name, options)) |_| return true else |_| {}
            }
            return false;
        }

        fn deinit(it: *OwnerIterator) void {
            for (&it.roots) |*maybe| if (maybe.*) |*value| value.close();
        }

        fn isOwner(entry: anytype) bool {
            session_layout.validateSessionId(entry.name) catch return false;
            return entry.kind == .directory;
        }
    };

    fn owner_iterator(self: *ProfileStore) !OwnerIterator {
        var roots: [outside_roots.len]?io_mod.VerifiedDir = @splat(null);
        errdefer for (&roots) |*maybe| if (maybe.*) |*value| value.close();
        for (outside_roots, &roots) |root_name, *root| root.* = try self.open_outside_root(root_name, false);
        return .{ .store = self, .sessions = self.sessions_dir.dir.iterate(), .roots = roots };
    }

    fn open_existing(
        self: *ProfileStore,
        owner_session_id: []const u8,
        terminal_session_id: []const u8,
    ) !DurableSession {
        var state = try self.open_capability(owner_session_id, false, false);
        errdefer state.deinit();
        var record = try load_record(self.alloc, &state, terminal_session_id);
        errdefer record.deinit(self.alloc);
        if (!std.mem.eql(u8, record.owner_session_id, owner_session_id)) {
            return error.InvalidTerminalRecord;
        }
        return .{
            .profile = self,
            .state = state,
            .record = record,
            .journal = null,
        };
    }

    pub fn open_terminal(
        self: *ProfileStore,
        terminal_session_id: []const u8,
    ) !*DurableSession {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        try contracts.validate_session_id(terminal_session_id);
        if (self.resident_by_id(terminal_session_id) != null) {
            return error.TerminalSessionResident;
        }
        var result: ?DurableSession = null;
        errdefer if (result) |*session| session.deinit();
        var owners = try self.owner_iterator();
        defer owners.deinit();
        while (try owners.next()) |owner_id| {
            var capability = self.open_capability(owner_id, false, false) catch continue;
            defer capability.deinit();
            const name = try record_name(self.alloc, terminal_session_id);
            defer self.alloc.free(name);
            _ = capability.stat(.terminal_state, name) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            if (result != null) return error.DuplicateTerminalSession;
            result = try self.open_existing(owner_id, terminal_session_id);
        }
        const session = result orelse return error.TerminalSessionNotFound;
        const resident = try self.alloc.create(DurableSession);
        errdefer self.alloc.destroy(resident);
        resident.* = session;
        result = null;
        errdefer resident.deinit();
        try self.register_resident_locked(resident);
        return resident;
    }

    pub fn release_terminal(
        self: *ProfileStore,
        session: *DurableSession,
    ) void {
        session.deinit();
        self.alloc.destroy(session);
    }

    pub fn ownerCatalog(
        self: *ProfileStore,
        claim: contracts.OwnerCatalogAuthorityClaim,
    ) !CatalogList {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        try verify_owner_catalog_claim(self.alloc, self, claim);

        var result = CatalogList{ .alloc = self.alloc };
        errdefer result.deinit();
        var capability = try self.open_capability(
            claim.principal.durable_session_id,
            false,
            false,
        );
        defer capability.deinit();
        var names = capability.iterate(self.alloc, .terminal_state) catch |err| switch (err) {
            error.FileNotFound => return result,
            else => return err,
        };
        defer names.deinit();
        for (names.names) |name| {
            const terminal_id = terminal_id_from_record_name(name) orelse continue;
            var record = load_record(self.alloc, &capability, terminal_id) catch continue;
            defer record.deinit(self.alloc);
            if (!std.mem.eql(
                u8,
                record.owner_session_id,
                claim.principal.durable_session_id,
            )) continue;
            const authority = load_authority(
                self.alloc,
                &capability,
                terminal_id,
            ) catch continue;
            defer authority.deinit();
            if (!owner_catalog_scope_matches(
                claim.principal,
                authority.value.grant.principal,
            )) continue;
            _ = try reconcile_takeover_owner_record(
                self.alloc,
                self.process_provider,
                &capability,
                &record,
                io_mod.milliTimestamp(),
            );
            const session_id = try self.alloc.dupe(u8, record.session_id);
            errdefer self.alloc.free(session_id);
            const cwd = try self.alloc.dupe(u8, record.cwd);
            errdefer self.alloc.free(cwd);
            const workspace_root = try self.alloc.dupe(
                u8,
                authority.value.grant.principal.workspace_root,
            );
            errdefer self.alloc.free(workspace_root);
            try result.entries.append(self.alloc, .{
                .facts = facts_from_record(record, session_id),
                .cwd = cwd,
                .workspace_root = workspace_root,
                .authorization = catalog_authorization(
                    &record,
                    &authority.value,
                    claim.actor,
                ),
            });
        }
        return result;
    }

    fn ensure_profile_capacity(
        self: *ProfileStore,
        additional: u64,
        active_session_id: []const u8,
    ) !void {
        try self.retry_pending_cleanups();
        while (true) {
            var candidates = try self.scan_payload_candidates();
            defer candidates.deinit(self.alloc);
            const required = std.math.add(u64, candidates.total_bytes, additional) catch
                return error.CapacityExceeded;
            if (required <= self.options.profile_limit) return;
            const selected = choose_eviction(
                candidates.items.items,
                active_session_id,
            ) orelse
                return error.CapacityExceeded;
            const candidate = candidates.items.items[selected.index];
            if (self.resident_by_id(candidate.session_id)) |resident| {
                switch (selected.class) {
                    .completed_output => try resident.evict_completed_output(),
                    .completed_checkpoint => try resident.evict_completed_checkpoint(),
                    .live_covered_journal => try resident.evict_live_covered_journals(),
                }
            } else {
                var session = try self.open_existing(
                    candidate.owner_session_id,
                    candidate.session_id,
                );
                defer session.deinit();
                switch (selected.class) {
                    .completed_output => try session.evict_completed_output(),
                    .completed_checkpoint => try session.evict_completed_checkpoint(),
                    .live_covered_journal => try session.evict_live_covered_journals(),
                }
            }
        }
    }

    fn retry_pending_cleanups(self: *ProfileStore) !void {
        var owners = try self.owner_iterator();
        defer owners.deinit();
        while (try owners.next()) |owner_id| {
            var capability = self.open_capability(owner_id, false, false) catch continue;
            defer capability.deinit();
            var names = capability.iterate(self.alloc, .terminal_state) catch continue;
            defer names.deinit();
            for (names.names) |name| {
                const terminal_id = terminal_id_from_record_name(name) orelse continue;
                var detached: ?DurableSession = null;
                const session = self.resident_by_id(terminal_id) orelse blk: {
                    detached = self.open_existing(owner_id, terminal_id) catch continue;
                    break :blk &detached.?;
                };
                defer if (detached) |*value| value.deinit();
                try session.retry_journal_cleanup();
                try session.retry_checkpoint_cleanup();
                try session.retry_event_cleanup_locked();
            }
        }
    }

    fn scan_payload_candidates(self: *ProfileStore) !CandidateList {
        var list = CandidateList{};
        errdefer list.deinit(self.alloc);
        var owners = try self.owner_iterator();
        defer owners.deinit();
        while (try owners.next()) |owner_id| {
            var capability = self.open_capability(owner_id, false, false) catch continue;
            defer capability.deinit();
            var names = capability.iterate(self.alloc, .terminal_state) catch continue;
            defer names.deinit();
            for (names.names) |name| {
                if (!is_payload_artifact_name(name)) continue;
                const stat = capability.stat(.terminal_state, name) catch continue;
                const payload_bytes = if (std.mem.startsWith(
                    u8,
                    name,
                    "checkpoint-",
                ) and stat.size >= checkpoint_header_bytes)
                    stat.size - checkpoint_header_bytes
                else
                    stat.size;
                list.total_bytes = std.math.add(
                    u64,
                    list.total_bytes,
                    payload_bytes,
                ) catch return error.CapacityExceeded;
            }
            for (names.names) |name| {
                const terminal_id = terminal_id_from_record_name(name) orelse continue;
                var record = load_record(
                    self.alloc,
                    &capability,
                    terminal_id,
                ) catch continue;
                defer record.deinit(self.alloc);
                if (is_live(record.lifecycle)) {
                    const reserve = try checkpoint_reserve_bytes(record.dimensions);
                    list.total_bytes = std.math.add(
                        u64,
                        list.total_bytes,
                        reserve -| record.checkpoint_payload_bytes,
                    ) catch return error.CapacityExceeded;
                }
                const owner_session_id = try self.alloc.dupe(
                    u8,
                    record.owner_session_id,
                );
                errdefer self.alloc.free(owner_session_id);
                const session_id = try self.alloc.dupe(u8, record.session_id);
                errdefer self.alloc.free(session_id);
                try list.items.append(self.alloc, .{
                    .owner_session_id = owner_session_id,
                    .session_id = session_id,
                    .lifecycle = record.lifecycle,
                    .created_at_ms = record.created_at_ms,
                    .journal_bytes = record.journal_payload_bytes,
                    .checkpoint_bytes = record.checkpoint_payload_bytes,
                    .covered_live_bytes = try covered_live_bytes(
                        self.alloc,
                        &capability,
                        record,
                    ),
                });
            }
        }
        return list;
    }

    /// Reconciles the terminal records of the single owner session named by
    /// `claim`, after authorizing it. A record owned by a running fx process
    /// instance, including this one, is never modified. A record whose owner
    /// instance is gone is repaired and, if it still claims to be live,
    /// recorded as lost: nothing can reach its terminal any more. Other
    /// owners' records are never scanned.
    ///
    /// The caller owns the returned list and must finish any pending close in
    /// it before releasing it.
    pub fn reconcileOwner(
        self: *ProfileStore,
        claim: contracts.OwnerCatalogAuthorityClaim,
        now_ms: i64,
    ) !RecoveredList {
        {
            const zio = io_mod.getIo();
            self.mutex.lockUncancelable(zio);
            defer self.mutex.unlock(zio);
            try verify_owner_catalog_claim(self.alloc, self, claim);
        }
        var recovered = RecoveredList{ .profile = self };
        errdefer recovered.deinit();
        try self.recover_owner(
            &recovered,
            claim.principal.durable_session_id,
            now_ms,
            owner_liveness,
        );
        return recovered;
    }

    fn is_resident(self: *ProfileStore, terminal_session_id: []const u8) bool {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        return self.resident_by_id(terminal_session_id) != null;
    }

    fn recover_owner(
        self: *ProfileStore,
        recovered: *RecoveredList,
        owner_id: []const u8,
        now_ms: i64,
        liveness: *const fn (Allocator, process_provider_mod.Provider, Record) OwnerLiveness,
    ) !void {
        var capability = self.open_capability(owner_id, false, false) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer capability.deinit();
        var names = capability.iterate(self.alloc, .terminal_state) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer names.deinit();
        for (names.names) |name| {
            // Artifacts without a record may be a start that another running
            // process has not finished writing, so they are left alone.
            const terminal_id = terminal_id_from_record_name(name) orelse continue;
            if (self.is_resident(terminal_id)) continue;
            var session = self.open_existing(owner_id, terminal_id) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                try recovered.append_diagnostic(
                    self.alloc,
                    owner_id,
                    terminal_id,
                    @errorName(err),
                );
                continue;
            };
            var keep = false;
            defer if (!keep) session.deinit();
            switch (liveness(self.alloc, self.process_provider, session.record)) {
                .running, .unknown => continue,
                .gone => {},
            }
            try self.recover_terminal(recovered, owner_id, terminal_id, &session, now_ms);
            try recovered.sessions.append(self.alloc, session);
            keep = true;
        }
    }

    /// Repairs one record whose owner process instance is gone.
    fn recover_terminal(
        self: *ProfileStore,
        recovered: *RecoveredList,
        owner_id: []const u8,
        terminal_id: []const u8,
        session: *DurableSession,
        now_ms: i64,
    ) !void {
        const repaired_close = session.reconcile_close_transaction(now_ms) catch |err| switch (classify_close_recovery_error(err)) {
            .isolate => blk: {
                try session.isolate_invalid_close_transaction(now_ms);
                try recovered.append_diagnostic(
                    self.alloc,
                    owner_id,
                    terminal_id,
                    "InvalidCloseTransaction",
                );
                break :blk false;
            },
            .propagate => return err,
        };
        if (repaired_close) {
            try recovered.append_diagnostic(
                self.alloc,
                owner_id,
                terminal_id,
                "CloseTransactionReconciled",
            );
        }
        const removed_orphans = session.reconcile_unreferenced_artifacts() catch |err| blk: {
            try recovered.append_diagnostic(
                self.alloc,
                owner_id,
                terminal_id,
                @errorName(err),
            );
            break :blk false;
        };
        if (removed_orphans) {
            try recovered.append_diagnostic(
                self.alloc,
                owner_id,
                terminal_id,
                "UnreferencedArtifacts",
            );
        }
        const repaired_authority = session.reconcile_authority() catch |err| blk: {
            if (!is_definitive_recovery_authority_error(err)) return err;
            try recovered.append_diagnostic(
                self.alloc,
                owner_id,
                terminal_id,
                @errorName(err),
            );
            break :blk false;
        };
        if (repaired_authority) {
            try recovered.append_diagnostic(
                self.alloc,
                owner_id,
                terminal_id,
                "AuthorityRecordReconciled",
            );
        }
        const repaired_journal = session.reconcile_journals() catch |err| blk: {
            try recovered.append_diagnostic(
                self.alloc,
                owner_id,
                terminal_id,
                @errorName(err),
            );
            break :blk false;
        };
        if (repaired_journal) {
            try recovered.append_diagnostic(
                self.alloc,
                owner_id,
                terminal_id,
                "CorruptJournalChain",
            );
        }
        session.reconcile_checkpoint() catch |err| {
            try recovered.append_diagnostic(
                self.alloc,
                owner_id,
                terminal_id,
                @errorName(err),
            );
        };
        const repaired_events = session.reconcile_events() catch |err| blk: {
            try recovered.append_diagnostic(
                self.alloc,
                owner_id,
                terminal_id,
                @errorName(err),
            );
            break :blk false;
        };
        if (repaired_events) {
            try recovered.append_diagnostic(
                self.alloc,
                owner_id,
                terminal_id,
                "CorruptEventChain",
            );
        }
        const decision = recovery.reconcile(.{
            .record = .valid,
            .lifecycle = session.record.lifecycle,
            .termination_present = session.record.termination != null,
            .host = .absent,
            .process = process_evidence_for(
                self.alloc,
                self.process_provider,
                session.record,
            ),
            .checkpoint = checkpoint_evidence_for(session.record),
        });
        switch (decision.disposition) {
            .mark_lost => {
                debug_trace.logf(
                    "terminal_store",
                    "terminal ended with its owner id={s} owner={s}",
                    .{ terminal_id, owner_id },
                );
                try session.persist_lost(now_ms);
            },
            .finalize_exited => {
                if (session.record.lifecycle == .starting or
                    session.record.lifecycle == .running)
                {
                    session.record.lifecycle = .exited;
                    session.record.updated_at_ms = now_ms;
                    try save_record(
                        self.alloc,
                        try session.state_capability(),
                        session.record,
                    );
                }
            },
            .retain_final => {},
            // An absent owner can never retain a live terminal.
            .retain_live, .unavailable, .isolate_corrupt => unreachable,
        }
        session.release_completed_handles();
    }
};

pub const CatalogEntry = struct {
    facts: contracts.SessionFacts,
    cwd: []u8,
    workspace_root: []u8,
    authorization: Authorization,

    fn deinit(self: *CatalogEntry, alloc: Allocator) void {
        alloc.free(self.workspace_root);
        alloc.free(self.cwd);
        alloc.free(self.facts.session_id);
        self.* = undefined;
    }
};

pub const CatalogList = struct {
    alloc: Allocator,
    entries: std.ArrayList(CatalogEntry) = .empty,

    pub fn deinit(self: *CatalogList) void {
        for (self.entries.items) |*entry| entry.deinit(self.alloc);
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }
};

pub const RecoveryDiagnostic = struct {
    owner_session_id: []u8,
    terminal_session_id: []u8,
    reason: []u8,

    fn deinit(self: *RecoveryDiagnostic, alloc: Allocator) void {
        alloc.free(self.reason);
        alloc.free(self.terminal_session_id);
        alloc.free(self.owner_session_id);
        self.* = undefined;
    }
};

pub const RecoveredList = struct {
    profile: ?*ProfileStore = null,
    sessions: std.ArrayList(DurableSession) = .empty,
    diagnostics: std.ArrayList(RecoveryDiagnostic) = .empty,

    pub fn deinit(self: *RecoveredList) void {
        const profile = self.profile orelse {
            std.debug.assert(self.sessions.items.len == 0);
            std.debug.assert(self.diagnostics.items.len == 0);
            return;
        };
        for (self.sessions.items) |*session| session.deinit();
        self.sessions.deinit(profile.alloc);
        for (self.diagnostics.items) |*diagnostic| {
            diagnostic.deinit(profile.alloc);
        }
        self.diagnostics.deinit(profile.alloc);
        self.* = undefined;
    }

    fn append_diagnostic(
        self: *RecoveredList,
        alloc: Allocator,
        owner_session_id: []const u8,
        terminal_session_id: []const u8,
        reason: []const u8,
    ) !void {
        const owner = try alloc.dupe(u8, owner_session_id);
        errdefer alloc.free(owner);
        const terminal = try alloc.dupe(u8, terminal_session_id);
        errdefer alloc.free(terminal);
        try self.diagnostics.append(alloc, .{
            .owner_session_id = owner,
            .terminal_session_id = terminal,
            .reason = try alloc.dupe(u8, reason),
        });
    }
};

/// `Record.host_identity` names the fx process instance that owns a terminal:
/// `fx-process-v1/<instance>/<pid>/<start token>`. The instance is random per
/// process, and the pid and start token prove whether that process still runs.
/// Records written by the retired terminal host daemon hold a bare instance id
/// instead and are judged by their terminal process.
const owner_identity_prefix = "fx-process-v1/";
const owner_instance_hex_len = 32;

pub const max_owner_identity_bytes = owner_identity_prefix.len +
    owner_instance_hex_len + 1 + 20 + 1 + 128;

/// Writes the owner identity of one process instance into `buffer`. The
/// result borrows `buffer`.
pub fn formatOwnerIdentity(
    buffer: []u8,
    instance_hex: []const u8,
    pid: std.posix.pid_t,
    token: process_identity.ProcessInstanceToken,
) error{ NoSpaceLeft, InvalidOwnerIdentity }![]const u8 {
    if (instance_hex.len != owner_instance_hex_len) return error.InvalidOwnerIdentity;
    return std.mem.print(buffer, "{s}{s}/{d}/{s}", .{
        owner_identity_prefix,
        instance_hex,
        pid,
        token.view(),
    });
}

const OwnerProcess = struct {
    pid: []const u8,
    token: process_identity.ProcessInstanceToken,
};

fn parse_owner_identity(text: []const u8) ?OwnerProcess {
    if (!std.mem.startsWith(u8, text, owner_identity_prefix)) return null;
    var parts = std.mem.splitScalar(u8, text[owner_identity_prefix.len..], '/');
    const instance = parts.next() orelse return null;
    if (instance.len != owner_instance_hex_len) return null;
    const pid = parts.next() orelse return null;
    _ = std.fmt.parseInt(std.posix.pid_t, pid, 10) catch return null;
    const token = process_identity.ProcessInstanceToken.parse(parts.rest()) catch
        return null;
    return .{ .pid = pid, .token = token };
}

const OwnerLiveness = enum { running, gone, unknown };

/// Whether the process instance that owns `record` still runs. Only `gone`
/// permits another process to change the record.
fn owner_liveness(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    record: Record,
) OwnerLiveness {
    if (parse_owner_identity(record.host_identity)) |owner| {
        return switch (process_provider.matchToken(alloc, owner.pid, owner.token)) {
            .matched => .running,
            .missing, .mismatched => .gone,
            .unavailable => .unknown,
        };
    }
    // A retired daemon's launcher watchdog ends the terminal when the daemon
    // goes away, so a running terminal process means its daemon still runs.
    if (record.pid == null or record.process_token == null) return .unknown;
    return switch (process_evidence_for(alloc, process_provider, record)) {
        .matched => .running,
        .missing, .mismatched => .gone,
        .unavailable => .unknown,
    };
}

fn process_evidence_for(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    record: Record,
) recovery.ProcessEvidence {
    const pid = record.pid orelse return .missing;
    const token_text = record.process_token orelse return .missing;
    const token = process_identity.ProcessInstanceToken.parse(token_text) catch
        return .mismatched;
    return switch (process_provider.matchToken(
        alloc,
        pid,
        token,
    )) {
        .matched => .matched,
        .missing => .missing,
        .mismatched => .mismatched,
        .unavailable => .unavailable,
    };
}

fn optional_text_eql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn takeover_owner_matches(
    record: Record,
    owner: *const contracts.ProcessOwner,
) bool {
    const pid = record.takeover_owner_pid orelse return false;
    const process_token = record.takeover_owner_process_token orelse return false;
    var pid_buffer: [32]u8 = undefined;
    const owner_pid = std.mem.print(&pid_buffer, "{d}", .{owner.pid}) catch
        return false;
    return std.mem.eql(u8, pid, owner_pid) and
        std.mem.eql(u8, process_token, owner.token());
}

fn takeover_owner_evidence(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    record: Record,
) process_identity.TokenMatch {
    const pid = record.takeover_owner_pid orelse return .mismatched;
    const token_text = record.takeover_owner_process_token orelse
        return .mismatched;
    const token = process_identity.ProcessInstanceToken.parse(token_text) catch
        return .mismatched;
    return process_provider.matchToken(
        alloc,
        pid,
        token,
    );
}

fn reconcile_takeover_owner_record(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    capability: *session_child_store.SessionChildCapability,
    record: *Record,
    now_ms: i64,
) !bool {
    if (record.attention.write_lease != .human) return false;
    switch (takeover_owner_evidence(alloc, process_provider, record.*)) {
        .matched, .unavailable => return false,
        .missing, .mismatched => {},
    }

    const previous_attention = record.attention;
    const previous_owner_pid = record.takeover_owner_pid;
    const previous_owner_process_token = record.takeover_owner_process_token;
    const previous_updated_at_ms = record.updated_at_ms;
    record.attention = .{};
    record.takeover_owner_pid = null;
    record.takeover_owner_process_token = null;
    record.updated_at_ms = now_ms;
    save_record(alloc, capability, record.*) catch |err| {
        record.attention = previous_attention;
        record.takeover_owner_pid = previous_owner_pid;
        record.takeover_owner_process_token = previous_owner_process_token;
        record.updated_at_ms = previous_updated_at_ms;
        return err;
    };
    alloc.free(previous_owner_process_token.?);
    alloc.free(previous_owner_pid.?);
    debug_trace.logf(
        "terminal_store",
        "orphan takeover owner reconciled id={s}",
        .{record.session_id},
    );
    return true;
}

fn checkpoint_evidence_for(record: Record) recovery.CheckpointEvidence {
    return switch (record.screen_recovery) {
        .available => .valid_contiguous,
        .unavailable => |reason| switch (reason) {
            .missing => .missing,
            .corrupt => .corrupt,
            .unsupported_schema => .unsupported,
            .retention_evicted => .retention_evicted,
            .raw_gap => .disconnected,
            .resize_uncheckpointed => .resize_uncheckpointed,
        },
    };
}

const PayloadCandidate = struct {
    owner_session_id: []u8,
    session_id: []u8,
    lifecycle: contracts.Lifecycle,
    created_at_ms: i64,
    journal_bytes: u64,
    checkpoint_bytes: u64,
    covered_live_bytes: u64,
};

const CandidateList = struct {
    items: std.ArrayList(PayloadCandidate) = .empty,
    total_bytes: u64 = 0,

    fn deinit(self: *CandidateList, alloc: Allocator) void {
        for (self.items.items) |candidate| {
            alloc.free(candidate.session_id);
            alloc.free(candidate.owner_session_id);
        }
        self.items.deinit(alloc);
        self.* = undefined;
    }
};

pub const EvictionClass = enum {
    completed_output,
    completed_checkpoint,
    live_covered_journal,
};

pub const EvictionSelection = struct {
    index: usize,
    class: EvictionClass,
};

fn choose_eviction(
    items: []const PayloadCandidate,
    active_session_id: []const u8,
) ?EvictionSelection {
    const classes = [_]EvictionClass{
        .completed_output,
        .completed_checkpoint,
        .live_covered_journal,
    };
    for (classes) |class| {
        var selected: ?usize = null;
        for (items, 0..) |item, index| {
            if (std.mem.eql(u8, item.session_id, active_session_id)) continue;
            const eligible = switch (class) {
                .completed_output => is_completed(item.lifecycle) and
                    item.journal_bytes != 0,
                .completed_checkpoint => is_completed(item.lifecycle) and
                    item.checkpoint_bytes != 0,
                .live_covered_journal => is_live(item.lifecycle) and
                    item.covered_live_bytes != 0,
            };
            if (!eligible) continue;
            if (selected == null or
                item.created_at_ms < items[selected.?].created_at_ms)
            {
                selected = index;
            }
        }
        if (selected) |index| return .{ .index = index, .class = class };
    }
    return null;
}

fn is_completed(lifecycle: contracts.Lifecycle) bool {
    return lifecycle == .exited or lifecycle == .lost or lifecycle == .closed;
}

fn is_live(lifecycle: contracts.Lifecycle) bool {
    return lifecycle == .starting or lifecycle == .running;
}

fn terminal_id_from_record_name(name: []const u8) ?[]const u8 {
    const prefix = "record-";
    const suffix = ".json";
    if (!std.mem.startsWith(u8, name, prefix) or
        !std.mem.endsWith(u8, name, suffix) or
        name.len <= prefix.len + suffix.len)
    {
        return null;
    }
    const id = name[prefix.len .. name.len - suffix.len];
    contracts.validate_session_id(id) catch return null;
    return id;
}

fn terminal_id_from_artifact_name(name: []const u8) ?[]const u8 {
    const fixed = [_]struct { prefix: []const u8, suffix: []const u8 }{
        .{ .prefix = "record-", .suffix = ".json" },
        .{ .prefix = "authority-", .suffix = ".json" },
        .{ .prefix = "monitors-", .suffix = ".json" },
        .{ .prefix = "monitor-transaction-", .suffix = ".json" },
        .{ .prefix = "close-transaction-", .suffix = ".json" },
        .{ .prefix = "proof-", .suffix = ".bin" },
    };
    for (fixed) |shape| {
        if (!std.mem.startsWith(u8, name, shape.prefix) or
            !std.mem.endsWith(u8, name, shape.suffix) or
            name.len <= shape.prefix.len + shape.suffix.len)
        {
            continue;
        }
        const id = name[shape.prefix.len .. name.len - shape.suffix.len];
        contracts.validate_session_id(id) catch continue;
        return id;
    }
    const indexed = [_]struct { prefix: []const u8, suffix: []const u8 }{
        .{ .prefix = "checkpoint-", .suffix = ".bin" },
        .{ .prefix = "journal-", .suffix = ".bin" },
        .{ .prefix = "event-", .suffix = ".json" },
    };
    for (indexed) |shape| {
        if (!std.mem.startsWith(u8, name, shape.prefix) or
            !std.mem.endsWith(u8, name, shape.suffix) or
            name.len <= shape.prefix.len + shape.suffix.len + 2)
        {
            continue;
        }
        const body = name[shape.prefix.len .. name.len - shape.suffix.len];
        const separator = std.mem.findScalarLast(u8, body, '-') orelse continue;
        if (separator == 0 or separator + 1 == body.len) continue;
        _ = std.fmt.parseInt(u64, body[separator + 1 ..], 10) catch continue;
        const id = body[0..separator];
        contracts.validate_session_id(id) catch continue;
        return id;
    }
    return null;
}

fn is_payload_artifact_name(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".bin")) return false;
    return std.mem.startsWith(u8, name, "journal-") or
        std.mem.startsWith(u8, name, "checkpoint-");
}

fn cleanup_session_artifacts(
    alloc: Allocator,
    state: *session_child_store.SessionChildCapability,
    proofs: ?*session_child_store.SessionChildCapability,
    session_id: []const u8,
) void {
    cleanup_session_artifacts_in(
        alloc,
        state,
        .terminal_state,
        session_id,
    );
    if (proofs) |capability| {
        cleanup_session_artifacts_in(
            alloc,
            capability,
            .terminal_proofs,
            session_id,
        );
    }
}

fn cleanup_session_artifacts_in(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    kind: session_child_store.ManagedChildKind,
    session_id: []const u8,
) void {
    var names = capability.iterate(alloc, kind) catch return;
    defer names.deinit();
    for (names.names) |name| {
        const id = terminal_id_from_artifact_name(name) orelse continue;
        if (!std.mem.eql(u8, id, session_id)) continue;
        capability.delete(kind, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => debug_trace.logf(
                "terminal_store",
                "partial artifact cleanup failed file={s} err={s}",
                .{ name, @errorName(err) },
            ),
        };
    }
}

fn indexed_artifact_id(
    name: []const u8,
    kind: []const u8,
    session_id: []const u8,
    suffix: []const u8,
) ?u64 {
    if (!std.mem.startsWith(u8, name, kind) or
        name.len <= kind.len + session_id.len + suffix.len + 2 or
        name[kind.len] != '-' or
        !std.mem.eql(
            u8,
            name[kind.len + 1 .. kind.len + 1 + session_id.len],
            session_id,
        ) or
        name[kind.len + 1 + session_id.len] != '-' or
        !std.mem.endsWith(u8, name, suffix))
    {
        return null;
    }
    const digits = name[kind.len + 2 + session_id.len .. name.len - suffix.len];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

fn covered_live_bytes(
    _: Allocator,
    _: *session_child_store.SessionChildCapability,
    record: Record,
) !u64 {
    const checkpoint = switch (record.screen_recovery) {
        .unavailable => return 0,
        .available => |value| value,
    };
    if (!is_live(record.lifecycle)) return 0;
    var total: u64 = 0;
    for (record.journal_files) |file| {
        if (contracts.compare_raw_cursors(
            file.range.end,
            checkpoint.applied_cursor,
        ) == .gt) break;
        total = std.math.add(u64, total, file.payload_bytes) catch
            return error.CapacityExceeded;
    }
    return total;
}

fn record_wire(record: Record) RecordWire {
    return .{
        .session_id = record.session_id,
        .owner_session_id = record.owner_session_id,
        .host_identity = record.host_identity,
        .backend_identity = record.backend_identity,
        .shell = record.shell,
        .cwd = record.cwd,
        .command = record.command,
        .timeout_ms = record.timeout_ms,
        .timeout_at_ms = record.timeout_at_ms,
        .timed_out = record.timed_out,
        .backend = record.backend,
        .lifecycle = record.lifecycle,
        .attention = record.attention,
        .dimensions = record.dimensions,
        .pid = record.pid,
        .process_token = record.process_token,
        .takeover_owner_pid = record.takeover_owner_pid,
        .takeover_owner_process_token = record.takeover_owner_process_token,
        .output_cursor = record.output_cursor,
        .available_from = record.available_from,
        .raw_gap = record.raw_gap,
        .raw_replay_exact = record.raw_replay_exact,
        .screen_recovery = record.screen_recovery,
        .checkpoint_payload_bytes = record.checkpoint_payload_bytes,
        .journal_payload_bytes = record.journal_payload_bytes,
        .journal_files = record.journal_files,
        .journal_cleanup_through = record.journal_cleanup_through,
        .checkpoint_generation = record.checkpoint_generation,
        .checkpoint_cleanup_generation = record.checkpoint_cleanup_generation,
        .next_event_id = record.next_event_id,
        .acknowledged_event_id = record.acknowledged_event_id,
        .event_gap_through = record.event_gap_through,
        .event_cleanup_through = record.event_cleanup_through,
        .monitor_count = record.monitor_count,
        .authority_generation = record.authority_generation,
        .authority_revoked = record.authority_revoked,
        .termination = record.termination,
        .created_at_ms = record.created_at_ms,
        .updated_at_ms = record.updated_at_ms,
    };
}

fn render_json(alloc: Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch
        return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn clone_record(alloc: Allocator, wire: RecordWire) Allocator.Error!Record {
    const session_id = try alloc.dupe(u8, wire.session_id);
    errdefer alloc.free(session_id);
    const owner_session_id = try alloc.dupe(u8, wire.owner_session_id);
    errdefer alloc.free(owner_session_id);
    const host_identity = try alloc.dupe(u8, wire.host_identity);
    errdefer alloc.free(host_identity);
    const backend_identity = try alloc.dupe(u8, wire.backend_identity);
    errdefer alloc.free(backend_identity);
    const shell = try alloc.dupe(u8, wire.shell);
    errdefer alloc.free(shell);
    const cwd = try alloc.dupe(u8, wire.cwd);
    errdefer alloc.free(cwd);
    const command = if (wire.command) |value| try alloc.dupe(u8, value) else null;
    errdefer if (command) |value| alloc.free(value);
    const pid = if (wire.pid) |value| try alloc.dupe(u8, value) else null;
    errdefer if (pid) |value| alloc.free(value);
    const takeover_owner_pid = if (wire.takeover_owner_pid) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (takeover_owner_pid) |value| alloc.free(value);
    const takeover_owner_process_token = if (wire.takeover_owner_process_token) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (takeover_owner_process_token) |value| alloc.free(value);
    const journal_files = try alloc.dupe(JournalFile, wire.journal_files);
    errdefer alloc.free(journal_files);
    return .{
        .session_id = session_id,
        .owner_session_id = owner_session_id,
        .host_identity = host_identity,
        .backend_identity = backend_identity,
        .shell = shell,
        .cwd = cwd,
        .command = command,
        .timeout_ms = wire.timeout_ms,
        .timeout_at_ms = wire.timeout_at_ms,
        .timed_out = wire.timed_out,
        .backend = wire.backend,
        .lifecycle = wire.lifecycle,
        .attention = wire.attention,
        .dimensions = wire.dimensions,
        .pid = pid,
        .process_token = if (wire.process_token) |value|
            try alloc.dupe(u8, value)
        else
            null,
        .takeover_owner_pid = takeover_owner_pid,
        .takeover_owner_process_token = takeover_owner_process_token,
        .output_cursor = wire.output_cursor,
        .available_from = wire.available_from,
        .raw_gap = wire.raw_gap,
        .raw_replay_exact = wire.raw_replay_exact,
        .screen_recovery = wire.screen_recovery,
        .checkpoint_payload_bytes = wire.checkpoint_payload_bytes,
        .journal_payload_bytes = wire.journal_payload_bytes,
        .journal_files = journal_files,
        .journal_cleanup_through = wire.journal_cleanup_through,
        .checkpoint_generation = wire.checkpoint_generation,
        .checkpoint_cleanup_generation = wire.checkpoint_cleanup_generation,
        .next_event_id = wire.next_event_id,
        .acknowledged_event_id = wire.acknowledged_event_id,
        .event_gap_through = wire.event_gap_through,
        .event_cleanup_through = wire.event_cleanup_through,
        .monitor_count = wire.monitor_count,
        .authority_generation = wire.authority_generation,
        .authority_revoked = wire.authority_revoked,
        .termination = wire.termination,
        .created_at_ms = wire.created_at_ms,
        .updated_at_ms = wire.updated_at_ms,
    };
}

fn parse_record(alloc: Allocator, bytes: []const u8) !Record {
    var parsed = std.json.parseFromSlice(
        RecordWire,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTerminalRecord,
    };
    defer parsed.deinit();
    if (parsed.value.schema_version != record_schema_version) {
        return error.UnsupportedTerminalSchema;
    }
    var record = try clone_record(alloc, parsed.value);
    errdefer record.deinit(alloc);
    try record.validate();
    return record;
}

fn make_name(
    alloc: Allocator,
    prefix: []const u8,
    session_id: []const u8,
    suffix: []const u8,
) Allocator.Error![]u8 {
    return alloc.print("{s}-{s}{s}", .{
        prefix,
        session_id,
        suffix,
    });
}

fn record_name(alloc: Allocator, session_id: []const u8) Allocator.Error![]u8 {
    return make_name(alloc, "record", session_id, ".json");
}

fn authority_name(alloc: Allocator, session_id: []const u8) Allocator.Error![]u8 {
    return make_name(alloc, "authority", session_id, ".json");
}

fn proof_name(alloc: Allocator, session_id: []const u8) Allocator.Error![]u8 {
    return make_name(alloc, "proof", session_id, ".bin");
}

fn checkpoint_name(
    alloc: Allocator,
    session_id: []const u8,
    generation: u64,
) Allocator.Error![]u8 {
    return alloc.print(
        "checkpoint-{s}-{d}.bin",
        .{ session_id, generation },
    );
}

fn close_transaction_name(
    alloc: Allocator,
    session_id: []const u8,
) Allocator.Error![]u8 {
    return make_name(alloc, "close-transaction", session_id, ".json");
}

fn journal_name(
    alloc: Allocator,
    session_id: []const u8,
    segment: u64,
) Allocator.Error![]u8 {
    return alloc.print(
        "journal-{s}-{d}.bin",
        .{ session_id, segment },
    );
}

fn find_journal_file(
    files: []const JournalFile,
    cursor: contracts.RawCursor,
) ?usize {
    for (files, 0..) |file, index| {
        if (cursor.segment != file.range.start.segment) continue;
        if (cursor.offset < file.range.start.offset) return null;
        if (cursor.offset < file.range.end.offset) return index;
        if (cursor.offset == file.range.end.offset and
            index + 1 < files.len and
            contracts.compare_raw_cursors(
                files[index + 1].range.start,
                cursor,
            ) == .eq)
        {
            return index + 1;
        }
    }
    return null;
}

fn event_name(
    alloc: Allocator,
    session_id: []const u8,
    event_id: u64,
) Allocator.Error![]u8 {
    return alloc.print(
        "event-{s}-{d}.json",
        .{ session_id, event_id },
    );
}

fn load_event(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
    event_id: u64,
) !DurableEvent {
    const name = try event_name(alloc, session_id, event_id);
    defer alloc.free(name);
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_state,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingDurableEvent,
        else => return err,
    };
    defer file.deinit();
    const bytes = file.readToEnd(alloc, max_event_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.DurableEventTooLarge,
        else => return err,
    };
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(
        EventWire,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidDurableEvent,
    };
    defer parsed.deinit();
    if (parsed.value.schema_version != event_schema_version or
        parsed.value.event.id != event_id)
    {
        return error.InvalidDurableEvent;
    }
    try parsed.value.event.validate();
    return parsed.value.event;
}

fn proof_verifier(
    proof: contracts.HolderProof,
    grant: contracts.AuthorityGrant,
) contracts.CheckpointChecksum {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.terminal.holder-proof.v2\x00");
    hash.update(&proof.bytes);
    hash_u64(&hash, grant.generation.value);
    hash.update(@tagName(grant.actor));
    hash.update(@tagName(grant.principal.transport_role));
    hash.update(@tagName(grant.principal.backend));
    hash.update(@tagName(grant.principal.lifetime));
    hash_text(&hash, grant.principal.profile_user);
    hash_text(&hash, grant.principal.durable_session_id);
    hash_text(&hash, grant.principal.workspace_root);
    hash_text(&hash, grant.principal.cwd);
    hash_allowed_controls(&hash, grant.controls);
    hash_u64(&hash, grant.repeated_probes.len);
    for (grant.repeated_probes) |probe| {
        hash_text(&hash, probe.command);
        hash_text(&hash, probe.cwd);
        hash_u64(&hash, probe.check_schedule.interval_ms);
        hash_monitor_notify(&hash, probe.notify_schedule);
        hash_monitor_lifetime(&hash, probe.lifetime);
    }
    var digest: contracts.CheckpointChecksum = undefined;
    hash.final(&digest);
    return digest;
}

fn close_initiator_verifier(
    claim: contracts.AuthorityClaim,
) contracts.CheckpointChecksum {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.terminal.close-initiator.v2\x00");
    hash.update(&claim.proof.bytes);
    hash_u64(&hash, claim.generation.value);
    hash_text(&hash, @tagName(claim.actor));
    hash_text(&hash, @tagName(claim.principal.transport_role));
    hash_text(&hash, @tagName(claim.principal.backend));
    hash_text(&hash, @tagName(claim.principal.lifetime));
    hash_text(&hash, claim.principal.profile_user);
    hash_text(&hash, claim.principal.durable_session_id);
    hash_text(&hash, claim.principal.workspace_root);
    hash_text(&hash, claim.principal.cwd);
    if (claim.process_owner) |owner| {
        hash.update("\x01");
        hash_u64(&hash, @intCast(owner.pid));
        hash_text(&hash, owner.token());
    } else {
        hash.update("\x00");
    }
    var digest: contracts.CheckpointChecksum = undefined;
    hash.final(&digest);
    return digest;
}

fn owner_catalog_key(
    principal: contracts.OwnerCatalogPrincipal,
    actor: contracts.ActorRole,
) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.terminal.owner-catalog-key.v2\x00");
    hash.update(@tagName(actor));
    hash.update(@tagName(principal.transport_role));
    hash_text(&hash, principal.profile_user);
    hash_text(&hash, principal.durable_session_id);
    hash_text(&hash, principal.workspace_root);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn owner_catalog_verifier(
    claim: contracts.OwnerCatalogAuthorityClaim,
) contracts.CheckpointChecksum {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.terminal.owner-catalog-proof.v2\x00");
    hash.update(&claim.proof.bytes);
    hash.update(@tagName(claim.actor));
    hash.update(@tagName(claim.principal.transport_role));
    hash_text(&hash, claim.principal.profile_user);
    hash_text(&hash, claim.principal.durable_session_id);
    hash_text(&hash, claim.principal.workspace_root);
    var digest: contracts.CheckpointChecksum = undefined;
    hash.final(&digest);
    return digest;
}

fn verify_owner_catalog_authority(
    authority: OwnerCatalogAuthorityWire,
    claim: contracts.OwnerCatalogAuthorityClaim,
) !void {
    try claim.validate();
    if (!authority.principal.eql(claim.principal) or
        authority.actor != claim.actor)
    {
        return error.PrincipalMismatch;
    }
    const verifier = owner_catalog_verifier(claim);
    if (!std.mem.eql(u8, &verifier, &authority.verifier)) {
        return error.InvalidHolderProof;
    }
}

fn verify_owner_catalog_claim(
    alloc: Allocator,
    profile: *ProfileStore,
    claim: contracts.OwnerCatalogAuthorityClaim,
) !void {
    try claim.validate();
    var capability = try profile.open_capability(
        claim.principal.durable_session_id,
        false,
        false,
    );
    defer capability.deinit();
    const key = owner_catalog_key(claim.principal, claim.actor);
    var name_buffer: [96]u8 = undefined;
    const name = try std.mem.print(
        &name_buffer,
        "catalog-authority-{s}.json",
        .{&key},
    );
    var authority = try load_owner_catalog_authority(alloc, &capability, name);
    defer authority.deinit();
    try verify_owner_catalog_authority(authority.value, claim);
}

fn owner_catalog_scope_matches(
    owner: contracts.OwnerCatalogPrincipal,
    terminal: contracts.Principal,
) bool {
    return std.mem.eql(u8, owner.profile_user, terminal.profile_user) and
        std.mem.eql(u8, owner.durable_session_id, terminal.durable_session_id) and
        std.mem.eql(u8, owner.workspace_root, terminal.workspace_root) and
        owner.transport_role == terminal.transport_role;
}

fn catalog_authorization(
    record: *const Record,
    authority: *const AuthorityWire,
    actor: contracts.ActorRole,
) Authorization {
    if (record.authority_revoked or authority.revoked) {
        return .{ .actor = actor, .controls = .{} };
    }
    if (authority.grant.actor != actor) {
        return .{ .actor = actor, .controls = .{} };
    }
    return .{
        .actor = actor,
        .controls = authority.grant.controls,
    };
}

// Retained only to verify authority records written by versions that allowed
// repeated monitor probes. The upgraded runtime never evaluates or creates
// these grants.
fn hash_monitor_notify(
    hash: *std.crypto.hash.sha2.Sha256,
    schedule: contracts.NotifySchedule,
) void {
    hash.update(@tagName(schedule));
    switch (schedule) {
        .every_n_checks => |count| hash_u64(hash, count),
        .interval => |value| hash_u64(hash, value.interval_ms),
        else => {},
    }
}

fn hash_monitor_lifetime(
    hash: *std.crypto.hash.sha2.Sha256,
    lifetime: contracts.MonitorLifetime,
) void {
    hash.update(@tagName(lifetime));
    if (lifetime == .duration_ms) hash_u64(hash, lifetime.duration_ms);
}

fn hash_text(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hash_u64(hash, value.len);
    hash.update(value);
}

fn hash_allowed_controls(
    hash: *std.crypto.hash.sha2.Sha256,
    controls: contracts.AllowedControls,
) void {
    const bits: u10 = @bitCast(controls);
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, bits, .little);
    hash.update(&bytes);
}

fn hash_u64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

pub const CreateInput = struct {
    session_id: []const u8,
    host_identity: []const u8,
    shell: []const u8,
    cwd: []const u8,
    command: ?[]const u8,
    timeout_ms: ?u64 = null,
    backend: contracts.Backend,
    dimensions: contracts.Dimensions,
    persistence: contracts.StartPersistence,
    now_ms: i64,
};

pub const ReadPage = struct {
    output: []u8,
    range: ?contracts.RawRange,
    gap: ?contracts.RawGap,

    pub fn deinit(self: *ReadPage, alloc: Allocator) void {
        alloc.free(self.output);
        self.* = undefined;
    }
};

pub const CloseCommitOutcome = union(enum) {
    previous: anyerror,
    candidate: ?anyerror,
    indeterminate: anyerror,
};

pub const EventReplay = struct {
    events: []DurableEvent,
    next_event_id: u64,

    pub fn deinit(self: *EventReplay, alloc: Allocator) void {
        alloc.free(self.events);
        self.* = undefined;
    }
};

pub const Authorization = struct {
    actor: contracts.ActorRole,
    controls: contracts.AllowedControls,
};

pub const AuthorityReload = struct {
    terminal_session_id: []const u8,
    principal: contracts.Principal,
    actor: contracts.ActorRole,
    generation: contracts.AuthorityGeneration,
};

pub const OwnerAuthorityReload = struct {
    terminal_session_id: []const u8,
    profile_user: []const u8,
    durable_session_id: []const u8,
    workspace_root: []const u8,
    transport_role: contracts.TransportRole,
    actor: contracts.ActorRole,
};

pub const OwnerCatalogAuthorityReload = struct {
    profile_user: []const u8,
    durable_session_id: []const u8,
    workspace_root: []const u8,
    transport_role: contracts.TransportRole,
    actor: contracts.ActorRole,
};

pub fn loadOrCreateOwnerCatalogClaim(
    alloc: Allocator,
    owner: *session_child_store.SessionChildCapability,
    input: OwnerCatalogAuthorityReload,
) !operation.OwnedOwnerCatalogClaim {
    const principal = contracts.OwnerCatalogPrincipal{
        .profile_user = input.profile_user,
        .durable_session_id = input.durable_session_id,
        .workspace_root = input.workspace_root,
        .transport_role = input.transport_role,
    };
    try principal.validate();
    const key = owner_catalog_key(principal, input.actor);
    var authority_name_buffer: [96]u8 = undefined;
    const catalog_authority_name = try std.mem.print(
        &authority_name_buffer,
        "catalog-authority-{s}.json",
        .{&key},
    );
    var proof_name_buffer: [96]u8 = undefined;
    const catalog_proof_name = try std.mem.print(
        &proof_name_buffer,
        "catalog-proof-{s}",
        .{&key},
    );
    var lock_name_buffer: [96]u8 = undefined;
    const lock_name = try std.mem.print(
        &lock_name_buffer,
        "catalog-{s}.lock",
        .{&key},
    );
    var authority_lock = try owner.acquireTimedAdvisoryLock(
        .terminal_state,
        lock_name,
        2_000,
    );
    defer authority_lock.release();

    if (load_owner_catalog_authority(alloc, owner, catalog_authority_name)) |parsed_value| {
        var parsed = parsed_value;
        defer parsed.deinit();
        var proof = try read_owner_catalog_proof(alloc, owner, catalog_proof_name);
        defer std.crypto.secureZero(u8, @volatileCast(proof.bytes[0..]));
        const claim = contracts.OwnerCatalogAuthorityClaim{
            .principal = principal,
            .actor = input.actor,
            .proof = proof,
        };
        try verify_owner_catalog_authority(parsed.value, claim);
        return operation.ownOwnerCatalogClaim(alloc, claim);
    } else |err| switch (err) {
        error.OwnerCatalogAuthorityNotFound => {},
        else => return err,
    }

    var proof = contracts.OwnerCatalogProof{ .bytes = undefined };
    defer std.crypto.secureZero(u8, @volatileCast(proof.bytes[0..]));
    while (true) {
        try std.Io.randomSecure(io_mod.getIo(), &proof.bytes);
        proof.validate() catch continue;
        break;
    }
    const claim = contracts.OwnerCatalogAuthorityClaim{
        .principal = principal,
        .actor = input.actor,
        .proof = proof,
    };
    try write_owner_catalog_proof(alloc, owner, catalog_proof_name, proof);
    try write_owner_catalog_authority(
        alloc,
        owner,
        catalog_authority_name,
        claim,
    );
    return operation.ownOwnerCatalogClaim(alloc, claim);
}

/// Reloads authority for the current fx owner without trusting caller-supplied
/// cwd, backend, or generation. Those facts are recovered from durable state;
/// the active profile/session/workspace/transport identity must still match.
pub fn reloadOwnerAuthorityClaim(
    alloc: Allocator,
    owner: *session_child_store.SessionChildCapability,
    input: OwnerAuthorityReload,
) !operation.OwnedAuthorityClaim {
    try contracts.validate_session_id(input.terminal_session_id);
    try contracts.validate_session_id(input.durable_session_id);
    var record = try load_record(alloc, owner, input.terminal_session_id);
    defer record.deinit(alloc);
    if (!std.mem.eql(u8, record.owner_session_id, input.durable_session_id)) {
        return error.PrincipalMismatch;
    }
    const authority = try load_authority(alloc, owner, input.terminal_session_id);
    defer authority.deinit();
    const principal = authority.value.grant.principal;
    if (!std.mem.eql(u8, principal.profile_user, input.profile_user) or
        !std.mem.eql(u8, principal.durable_session_id, input.durable_session_id) or
        !std.mem.eql(u8, principal.workspace_root, input.workspace_root) or
        principal.transport_role != input.transport_role or
        !std.mem.eql(u8, principal.cwd, record.cwd) or
        principal.backend != record.backend or
        principal.lifetime != .session)
    {
        return error.PrincipalMismatch;
    }
    return reloadAuthorityClaim(alloc, owner, .{
        .terminal_session_id = input.terminal_session_id,
        .principal = principal,
        .actor = input.actor,
        .generation = record.authority_generation,
    });
}

/// Mints the session-shaped claim used only for an interactive human
/// takeover. The proof remains an owner-catalog proof; the host recognizes
/// and verifies that proof separately from the terminal's agent grant.
pub fn reloadHumanTakeoverAuthorityClaim(
    alloc: Allocator,
    owner: *session_child_store.SessionChildCapability,
    input: OwnerAuthorityReload,
) !operation.OwnedAuthorityClaim {
    try contracts.validate_session_id(input.terminal_session_id);
    try contracts.validate_session_id(input.durable_session_id);
    if (input.actor != .human) return error.ActorRoleMismatch;

    var record = try load_record(alloc, owner, input.terminal_session_id);
    defer record.deinit(alloc);
    if (!std.mem.eql(u8, record.owner_session_id, input.durable_session_id)) {
        return error.PrincipalMismatch;
    }
    const authority = try load_authority(alloc, owner, input.terminal_session_id);
    defer authority.deinit();
    const principal = authority.value.grant.principal;
    if (!std.mem.eql(u8, principal.profile_user, input.profile_user) or
        !std.mem.eql(u8, principal.durable_session_id, input.durable_session_id) or
        !std.mem.eql(u8, principal.workspace_root, input.workspace_root) or
        principal.transport_role != input.transport_role or
        !std.mem.eql(u8, principal.cwd, record.cwd) or
        principal.backend != record.backend or
        principal.lifetime != .session or
        authority.value.revoked or record.authority_revoked)
    {
        return error.PrincipalMismatch;
    }
    if (authority.value.grant.actor == .human) {
        return reloadAuthorityClaim(alloc, owner, .{
            .terminal_session_id = input.terminal_session_id,
            .principal = principal,
            .actor = .human,
            .generation = record.authority_generation,
        });
    }

    var catalog = try loadOrCreateOwnerCatalogClaim(alloc, owner, .{
        .profile_user = input.profile_user,
        .durable_session_id = input.durable_session_id,
        .workspace_root = input.workspace_root,
        .transport_role = input.transport_role,
        .actor = .human,
    });
    defer catalog.deinit();
    return operation.ownAuthorityClaim(alloc, .{
        .principal = principal,
        .actor = .human,
        .generation = record.authority_generation,
        .proof = .{ .bytes = catalog.view().proof.bytes },
    }, .humanTakeover());
}

/// Reloads a proof only through the managed-child capability of the durable fx
/// session that owns it. A terminal id alone cannot select proof storage.
pub fn reloadAuthorityClaim(
    alloc: Allocator,
    owner: *session_child_store.SessionChildCapability,
    input: AuthorityReload,
) !operation.OwnedAuthorityClaim {
    try contracts.validate_session_id(input.terminal_session_id);
    try input.principal.validate();
    try input.generation.validate();

    var record = try load_record(alloc, owner, input.terminal_session_id);
    defer record.deinit(alloc);
    if (!std.mem.eql(
        u8,
        record.owner_session_id,
        input.principal.durable_session_id,
    ) or !std.mem.eql(u8, record.cwd, input.principal.cwd) or
        record.backend != input.principal.backend)
    {
        return failReloadedAuthorityClaim(error.PrincipalMismatch);
    }
    const authority = try load_authority(
        alloc,
        owner,
        input.terminal_session_id,
    );
    defer authority.deinit();
    if (record.authority_revoked or authority.value.revoked) {
        return failReloadedAuthorityClaim(error.AuthorityRevoked);
    }
    const grant = authority.value.grant;
    if (!grant.principal.eql(input.principal)) {
        return failReloadedAuthorityClaim(error.PrincipalMismatch);
    }
    if (record.authority_generation.value != input.generation.value or
        grant.generation.value != input.generation.value)
    {
        return failReloadedAuthorityClaim(error.StaleAuthorityGeneration);
    }
    if (grant.actor != input.actor) {
        return failReloadedAuthorityClaim(error.ActorRoleMismatch);
    }
    const controls = grant.controls;

    var proof = try read_proof(alloc, owner, input.terminal_session_id);
    defer std.crypto.secureZero(u8, @volatileCast(proof.bytes[0..]));
    const actual = proof_verifier(proof, grant);
    if (!std.mem.eql(u8, &actual, &authority.value.verifier)) {
        return failReloadedAuthorityClaim(error.InvalidHolderProof);
    }
    return operation.ownAuthorityClaim(alloc, .{
        .principal = input.principal,
        .actor = input.actor,
        .generation = input.generation,
        .proof = proof,
    }, controls);
}

inline fn failReloadedAuthorityClaim(err: anytype) @TypeOf(err)!operation.OwnedAuthorityClaim {
    return @errorCast(failReloadedAuthorityClaimDynamic(err));
}

noinline fn failReloadedAuthorityClaimDynamic(err: anyerror) anyerror!operation.OwnedAuthorityClaim {
    return err;
}

pub const DurableSession = struct {
    profile: *ProfileStore,
    state: ?session_child_store.SessionChildCapability,
    record: Record,
    journal: ?session_child_store.ManagedFile,
    registered: bool = false,

    pub fn create(profile: *ProfileStore, input: CreateInput) !DurableSession {
        const zio = io_mod.getIo();
        profile.mutex.lockUncancelable(zio);
        defer profile.mutex.unlock(zio);
        try contracts.validate_session_id(input.session_id);
        try input.dimensions.validate();
        // A new terminal makes a v2 owner's folder (D45).
        var state = try profile.open_capability(
            input.persistence.grant.principal.durable_session_id,
            false,
            true,
        );
        errdefer state.deinit();
        var proofs = try profile.open_capability(
            input.persistence.grant.principal.durable_session_id,
            true,
            true,
        );
        defer proofs.deinit();
        return create_started(profile, input, &state, &proofs) catch |err| {
            if (err != error.InjectedCrash) {
                cleanup_partial_start(
                    profile.alloc,
                    &state,
                    &proofs,
                    input.session_id,
                );
            }
            return err;
        };
    }

    fn create_started(
        profile: *ProfileStore,
        input: CreateInput,
        state: *session_child_store.SessionChildCapability,
        proofs: *session_child_store.SessionChildCapability,
    ) !DurableSession {
        const reserve = try checkpoint_reserve_bytes(input.dimensions);
        if (reserve > profile.options.per_session_limit) {
            return error.CapacityExceeded;
        }
        try profile.ensure_profile_capacity(reserve, input.session_id);

        var backend_random: [16]u8 = undefined;
        io_mod.getIo().random(&backend_random);
        const backend_text = std.fmt.bytesToHex(backend_random, .lower);
        const alloc = profile.alloc;
        var fields_owned_by_record = false;
        const session_id = try alloc.dupe(u8, input.session_id);
        errdefer if (!fields_owned_by_record) alloc.free(session_id);
        const owner_session_id = try alloc.dupe(
            u8,
            input.persistence.grant.principal.durable_session_id,
        );
        errdefer if (!fields_owned_by_record) alloc.free(owner_session_id);
        const host_identity = try alloc.dupe(u8, input.host_identity);
        errdefer if (!fields_owned_by_record) alloc.free(host_identity);
        const backend_identity = try alloc.dupe(u8, &backend_text);
        errdefer if (!fields_owned_by_record) alloc.free(backend_identity);
        const shell = try alloc.dupe(u8, input.shell);
        errdefer if (!fields_owned_by_record) alloc.free(shell);
        const cwd = try alloc.dupe(u8, input.cwd);
        errdefer if (!fields_owned_by_record) alloc.free(cwd);
        const command = if (input.command) |value| try alloc.dupe(u8, value) else null;
        errdefer if (!fields_owned_by_record) {
            if (command) |value| alloc.free(value);
        };
        const initial_cursor = contracts.RawCursor{ .segment = 1, .offset = 0 };
        const journal_files = try alloc.alloc(JournalFile, 1);
        errdefer if (!fields_owned_by_record) alloc.free(journal_files);
        journal_files[0] = .{
            .file_id = 1,
            .range = .{ .start = initial_cursor, .end = initial_cursor },
            .payload_bytes = 0,
            .checksum = contracts.checkpoint_checksum(""),
        };
        var record = Record{
            .session_id = session_id,
            .owner_session_id = owner_session_id,
            .host_identity = host_identity,
            .backend_identity = backend_identity,
            .shell = shell,
            .cwd = cwd,
            .command = command,
            .timeout_ms = input.timeout_ms,
            .timeout_at_ms = null,
            .timed_out = false,
            .backend = input.backend,
            .lifecycle = .starting,
            .attention = .{},
            .dimensions = input.dimensions,
            .pid = null,
            .process_token = null,
            .takeover_owner_pid = null,
            .takeover_owner_process_token = null,
            .output_cursor = initial_cursor,
            .available_from = initial_cursor,
            .raw_gap = null,
            .raw_replay_exact = true,
            .screen_recovery = .{ .unavailable = .missing },
            .checkpoint_payload_bytes = 0,
            .journal_payload_bytes = 0,
            .journal_files = journal_files,
            .journal_cleanup_through = 0,
            .checkpoint_generation = 0,
            .checkpoint_cleanup_generation = null,
            .next_event_id = 1,
            .acknowledged_event_id = 0,
            .event_gap_through = 0,
            .event_cleanup_through = 0,
            .monitor_count = 0,
            .authority_generation = input.persistence.grant.generation,
            .authority_revoked = false,
            .termination = null,
            .created_at_ms = input.now_ms,
            .updated_at_ms = input.now_ms,
        };
        fields_owned_by_record = true;
        errdefer record.deinit(alloc);

        const journal_file_name = try journal_name(alloc, input.session_id, 1);
        defer alloc.free(journal_file_name);
        var journal = try state.createExclusiveFile(
            alloc,
            .terminal_state,
            journal_file_name,
        );
        errdefer journal.deinit();
        try journal.sync();
        if (profile.options.fail_at == .after_journal_create) {
            return error.InjectedCrash;
        }

        try write_proof(alloc, proofs, input.session_id, input.persistence.proof);
        if (profile.options.fail_at == .after_proof_write) {
            return error.InjectedCrash;
        }
        if (profile.options.fail_at == .grant) return error.InjectedFailure;
        try write_authority(
            alloc,
            state,
            input.session_id,
            input.persistence.grant,
            input.persistence.proof,
            false,
        );
        if (profile.options.fail_at == .after_authority_write) {
            return error.InjectedCrash;
        }
        if (profile.options.fail_at == .start) return error.InjectedFailure;
        try save_record(alloc, state, record);
        return .{
            .profile = profile,
            .state = state.*,
            .record = record,
            .journal = journal,
        };
    }

    pub fn deinit(self: *DurableSession) void {
        if (self.registered) self.profile.unregister_resident(self);
        if (self.journal) |*journal| journal.deinit();
        self.record.deinit(self.profile.alloc);
        if (self.state) |*state| state.deinit();
        self.* = undefined;
    }

    pub fn rollback_unreleased_start(self: *DurableSession) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (self.record.lifecycle != .starting or self.record.pid != null) {
            return error.InvalidLifecycle;
        }
        if (self.registered) {
            for (self.profile.residents.items, 0..) |resident, index| {
                if (resident != self) continue;
                _ = self.profile.residents.swapRemove(index);
                self.registered = false;
                break;
            }
        }
        if (self.journal) |*journal| journal.deinit();
        self.journal = null;
        var proofs = try self.profile.open_capability(
            self.record.owner_session_id,
            true,
            false,
        );
        defer proofs.deinit();
        cleanup_partial_start(
            self.profile.alloc,
            try self.state_capability(),
            &proofs,
            self.record.session_id,
        );
    }

    fn state_capability(
        self: *DurableSession,
    ) !*session_child_store.SessionChildCapability {
        if (self.state == null) {
            self.state = try self.profile.open_capability(
                self.record.owner_session_id,
                false,
                false,
            );
        }
        return &self.state.?;
    }

    pub fn release_completed_handles(self: *DurableSession) void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        self.release_completed_handles_locked();
    }

    fn release_completed_handles_locked(self: *DurableSession) void {
        if (!is_completed(self.record.lifecycle)) return;
        if (self.journal) |*journal| journal.deinit();
        self.journal = null;
        if (self.state) |*state| state.deinit();
        self.state = null;
    }

    pub fn mark_started(
        self: *DurableSession,
        pid: []const u8,
        token: process_identity.ProcessInstanceToken,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.reject_close_intent_locked();
        if (self.record.lifecycle != .starting) {
            return error.InvalidLifecycle;
        }
        const alloc = self.profile.alloc;
        const pid_owned = try alloc.dupe(u8, pid);
        errdefer alloc.free(pid_owned);
        const token_owned = try alloc.dupe(u8, token.view());
        errdefer alloc.free(token_owned);
        const previous_pid = self.record.pid;
        const previous_token = self.record.process_token;
        const previous_lifecycle = self.record.lifecycle;
        const previous_timeout_at_ms = self.record.timeout_at_ms;
        const previous_updated_at_ms = self.record.updated_at_ms;
        const timeout_at_ms = if (self.record.timeout_ms) |timeout_ms|
            std.math.add(i64, now_ms, @intCast(timeout_ms)) catch
                return error.CapacityExceeded
        else
            null;
        self.record.pid = pid_owned;
        self.record.process_token = token_owned;
        self.record.timeout_at_ms = timeout_at_ms;
        self.record.lifecycle = try contracts.transition_lifecycle(
            self.record.lifecycle,
            .child_started,
        );
        self.record.updated_at_ms = now_ms;
        save_record(alloc, try self.state_capability(), self.record) catch |err| {
            self.record.pid = previous_pid;
            self.record.process_token = previous_token;
            self.record.lifecycle = previous_lifecycle;
            self.record.timeout_at_ms = previous_timeout_at_ms;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        if (previous_pid) |value| alloc.free(value);
        if (previous_token) |value| alloc.free(value);
        _ = try self.append_event_locked(.lifecycle, now_ms);
    }

    pub fn mark_timed_out(self: *DurableSession, now_ms: i64) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (self.record.timed_out) return;
        if (self.record.timeout_at_ms == null) return error.InvalidLifecycle;
        const previous_timed_out = self.record.timed_out;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.timed_out = true;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.timed_out = previous_timed_out;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
    }

    pub fn append(self: *DurableSession, bytes: []const u8, now_ms: i64) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (bytes.len == 0) return;
        if (self.profile.options.fail_at == .append) return error.InjectedFailure;
        const appended_len = std.math.cast(u64, bytes.len) orelse
            return error.CapacityExceeded;
        const reserve = try checkpoint_reserve_bytes(self.record.dimensions);
        var retained_after = std.math.add(
            u64,
            self.record.journal_payload_bytes,
            appended_len,
        ) catch return error.CapacityExceeded;
        var session_after = std.math.add(
            u64,
            retained_after,
            @max(reserve, self.record.checkpoint_payload_bytes),
        ) catch return error.CapacityExceeded;
        if (session_after > self.profile.options.per_session_limit) {
            self.evict_live_covered_journals() catch
                return error.CapacityExceeded;
            retained_after = std.math.add(
                u64,
                self.record.journal_payload_bytes,
                appended_len,
            ) catch return error.CapacityExceeded;
            session_after = std.math.add(
                u64,
                retained_after,
                @max(reserve, self.record.checkpoint_payload_bytes),
            ) catch return error.CapacityExceeded;
            if (session_after > self.profile.options.per_session_limit) {
                return error.CapacityExceeded;
            }
        }
        self.profile.ensure_profile_capacity(
            appended_len,
            self.record.session_id,
        ) catch |err| switch (err) {
            error.CapacityExceeded => {
                self.evict_live_covered_journals() catch
                    return error.CapacityExceeded;
                try self.profile.ensure_profile_capacity(
                    appended_len,
                    self.record.session_id,
                );
            },
            else => return err,
        };

        var remaining = bytes;
        while (remaining.len != 0) {
            const current = self.record.journal_files[
                self.record.journal_files.len - 1
            ];
            const space = self.profile.options.segment_bytes -
                current.payload_bytes;
            const write_len = @min(
                remaining.len,
                std.math.cast(usize, if (space == 0)
                    self.profile.options.segment_bytes
                else
                    space) orelse return error.CapacityExceeded,
            );
            try self.append_journal_chunk(remaining[0..write_len], now_ms);
            remaining = remaining[write_len..];
        }
        std.debug.assert(self.record.journal_payload_bytes == retained_after);
    }

    pub fn begin_raw_gap(self: *DurableSession, now_ms: i64) !contracts.RawGap {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (!is_live(self.record.lifecycle)) return error.InvalidLifecycle;
        const next_segment = std.math.add(
            u64,
            self.record.output_cursor.segment,
            1,
        ) catch return error.CapacityExceeded;
        const next_cursor = contracts.RawCursor{
            .segment = next_segment,
            .offset = 0,
        };
        const collapse_previous_gap = self.record.raw_gap != null;
        const gap = contracts.RawGap{
            .missing_from = if (collapse_previous_gap)
                self.record.available_from
            else
                self.record.output_cursor,
            .available_from = next_cursor,
        };
        const previous_files = self.record.journal_files;
        const expanded = try self.profile.alloc.alloc(
            JournalFile,
            if (collapse_previous_gap) 1 else previous_files.len + 1,
        );
        errdefer self.profile.alloc.free(expanded);
        if (!collapse_previous_gap) {
            @memcpy(expanded[0..previous_files.len], previous_files);
        }
        const next_file_id = std.math.add(
            u64,
            previous_files[previous_files.len - 1].file_id,
            1,
        ) catch return error.CapacityExceeded;
        expanded[expanded.len - 1] = .{
            .file_id = next_file_id,
            .range = .{ .start = next_cursor, .end = next_cursor },
            .payload_bytes = 0,
            .checksum = contracts.checkpoint_checksum(""),
        };
        const name = try journal_name(
            self.profile.alloc,
            self.record.session_id,
            next_file_id,
        );
        defer self.profile.alloc.free(name);
        var journal = try (try self.state_capability()).createExclusiveFile(
            self.profile.alloc,
            .terminal_state,
            name,
        );
        var journal_owned = true;
        errdefer if (journal_owned) {
            journal.deinit();
            if (self.state_capability() catch null) |capability| {
                capability.delete(.terminal_state, name) catch {};
            }
        };
        try journal.sync();

        const previous_cursor = self.record.output_cursor;
        const previous_available = self.record.available_from;
        const previous_gap = self.record.raw_gap;
        const previous_exact = self.record.raw_replay_exact;
        const previous_journal_bytes = self.record.journal_payload_bytes;
        const previous_journal_cleanup = self.record.journal_cleanup_through;
        const previous_recovery = self.record.screen_recovery;
        const previous_checkpoint_bytes = self.record.checkpoint_payload_bytes;
        const previous_checkpoint_generation = self.record.checkpoint_generation;
        const previous_checkpoint_cleanup = self.record.checkpoint_cleanup_generation;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.journal_files = expanded;
        self.record.output_cursor = next_cursor;
        if (collapse_previous_gap) {
            self.record.available_from = next_cursor;
            self.record.journal_payload_bytes = 0;
            self.record.journal_cleanup_through = @max(
                self.record.journal_cleanup_through,
                previous_files[previous_files.len - 1].file_id,
            );
        }
        self.record.raw_gap = gap;
        self.record.raw_replay_exact = false;
        self.record.screen_recovery = .{ .unavailable = .raw_gap };
        self.record.checkpoint_payload_bytes = 0;
        self.record.checkpoint_generation = 0;
        self.record.checkpoint_cleanup_generation = if (previous_checkpoint_generation == 0)
            previous_checkpoint_cleanup
        else
            previous_checkpoint_generation;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.journal_files = previous_files;
            self.record.output_cursor = previous_cursor;
            self.record.available_from = previous_available;
            self.record.raw_gap = previous_gap;
            self.record.raw_replay_exact = previous_exact;
            self.record.journal_payload_bytes = previous_journal_bytes;
            self.record.journal_cleanup_through = previous_journal_cleanup;
            self.record.screen_recovery = previous_recovery;
            self.record.checkpoint_payload_bytes = previous_checkpoint_bytes;
            self.record.checkpoint_generation = previous_checkpoint_generation;
            self.record.checkpoint_cleanup_generation = previous_checkpoint_cleanup;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        self.profile.alloc.free(previous_files);
        if (self.journal) |*previous| previous.deinit();
        self.journal = journal;
        journal_owned = false;
        self.retry_journal_cleanup() catch |err| debug_trace.logf(
            "terminal_store",
            "raw gap journal cleanup deferred id={s} err={s}",
            .{ self.record.session_id, @errorName(err) },
        );
        self.retry_checkpoint_cleanup() catch |err| debug_trace.logf(
            "terminal_store",
            "raw gap checkpoint cleanup deferred id={s} err={s}",
            .{ self.record.session_id, @errorName(err) },
        );
        return gap;
    }

    fn append_journal_chunk(
        self: *DurableSession,
        bytes: []const u8,
        now_ms: i64,
    ) !void {
        const alloc = self.profile.alloc;
        const previous_files = self.record.journal_files;
        var working = try alloc.dupe(JournalFile, previous_files);
        var working_owned = true;
        defer if (working_owned) alloc.free(working);

        var replacement: ?session_child_store.ManagedFile = null;
        var replacement_name: ?[]u8 = null;
        defer if (replacement_name) |name| alloc.free(name);
        self.write_journal_chunk(
            bytes,
            now_ms,
            previous_files,
            &working,
            &working_owned,
            &replacement,
            &replacement_name,
        ) catch |err| {
            if (replacement) |*file| file.deinit();
            if (err != error.InjectedCrash) {
                if (replacement_name) |name| {
                    const capability = self.state_capability() catch |cleanup_err| blk: {
                        debug_trace.logf(
                            "terminal_store",
                            "journal rollback open failed file={s} err={s}",
                            .{ name, @errorName(cleanup_err) },
                        );
                        break :blk null;
                    };
                    if (capability) |value| {
                        value.delete(.terminal_state, name) catch |cleanup_err| {
                            debug_trace.logf(
                                "terminal_store",
                                "journal rollback delete failed file={s} err={s}",
                                .{ name, @errorName(cleanup_err) },
                            );
                        };
                    }
                }
            }
            return err;
        };
    }

    fn write_journal_chunk(
        self: *DurableSession,
        bytes: []const u8,
        now_ms: i64,
        previous_files: []JournalFile,
        working: *[]JournalFile,
        working_owned: *bool,
        replacement: *?session_child_store.ManagedFile,
        replacement_name: *?[]u8,
    ) !void {
        const alloc = self.profile.alloc;
        const resumes_reopened_journal = self.journal == null;
        if (resumes_reopened_journal or
            working.*[working.*.len - 1].payload_bytes ==
                self.profile.options.segment_bytes)
        {
            const next_id = std.math.add(
                u64,
                working.*[working.*.len - 1].file_id,
                1,
            ) catch return error.CapacityExceeded;
            const expanded = try alloc.alloc(JournalFile, working.*.len + 1);
            @memcpy(expanded[0..working.*.len], working.*);
            alloc.free(working.*);
            working.* = expanded;
            const cursor = self.record.output_cursor;
            working.*[working.*.len - 1] = .{
                .file_id = next_id,
                .range = .{ .start = cursor, .end = cursor },
                .payload_bytes = 0,
                .checksum = contracts.checkpoint_checksum(""),
            };
            const name = try journal_name(alloc, self.record.session_id, next_id);
            replacement_name.* = name;
            replacement.* = try (try self.state_capability()).createExclusiveFile(
                alloc,
                .terminal_state,
                name,
            );
            try replacement.*.?.sync();
            if (resumes_reopened_journal) {
                debug_trace.logf(
                    "terminal_store",
                    "journal append resumed id={s} cursor={d}:{d} file={d}",
                    .{
                        self.record.session_id,
                        cursor.segment,
                        cursor.offset,
                        next_id,
                    },
                );
            }
        }

        const file = if (replacement.*) |*value|
            value
        else if (self.journal) |*value|
            value
        else
            return error.TerminalStoreFailed;
        try file.writeAll(bytes);
        try file.sync();
        if (self.profile.options.fail_at == .after_journal_sync) {
            return error.InjectedCrash;
        }

        const extent = &working.*[working.*.len - 1];
        const next_offset = std.math.add(
            u64,
            self.record.output_cursor.offset,
            bytes.len,
        ) catch return error.CapacityExceeded;
        const next_file_bytes = std.math.add(
            u64,
            extent.payload_bytes,
            bytes.len,
        ) catch return error.CapacityExceeded;
        extent.range.end.offset = next_offset;
        extent.payload_bytes = next_file_bytes;
        extent.checksum = try self.journal_checksum(
            extent.file_id,
            next_file_bytes,
        );

        const previous_output_cursor = self.record.output_cursor;
        const previous_journal_bytes = self.record.journal_payload_bytes;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.journal_files = working.*;
        self.record.output_cursor.offset = next_offset;
        self.record.journal_payload_bytes = std.math.add(
            u64,
            previous_journal_bytes,
            bytes.len,
        ) catch return error.CapacityExceeded;
        self.record.updated_at_ms = now_ms;
        save_record(
            alloc,
            try self.state_capability(),
            self.record,
        ) catch {
            self.record.journal_files = previous_files;
            self.record.output_cursor = previous_output_cursor;
            self.record.journal_payload_bytes = previous_journal_bytes;
            self.record.updated_at_ms = previous_updated_at_ms;
            return error.TerminalStoreFailed;
        };
        alloc.free(previous_files);
        working_owned.* = false;
        if (replacement.*) |new_file| {
            if (self.journal) |*old_file| old_file.deinit();
            self.journal = new_file;
            replacement.* = null;
        }
    }

    fn journal_checksum(
        self: *DurableSession,
        file_id: u64,
        expected_bytes: u64,
    ) !contracts.CheckpointChecksum {
        const alloc = self.profile.alloc;
        const name = try journal_name(alloc, self.record.session_id, file_id);
        defer alloc.free(name);
        var file = try (try self.state_capability()).openFileReadOnly(
            alloc,
            .terminal_state,
            name,
        );
        defer file.deinit();
        const max_bytes = std.math.cast(usize, expected_bytes) orelse
            return error.CapacityExceeded;
        const contents = try file.readToEnd(alloc, max_bytes + 1);
        defer alloc.free(contents);
        if (contents.len != max_bytes) return error.CorruptJournalSegment;
        return contracts.checkpoint_checksum(contents);
    }

    pub fn read(
        self: *DurableSession,
        alloc: Allocator,
        requested: contracts.RawCursor,
        max_bytes: usize,
    ) !ReadPage {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try requested.validate();
        if (max_bytes == 0) return error.InvalidReadLength;
        if (contracts.compare_raw_cursors(
            requested,
            self.record.output_cursor,
        ) == .gt) return error.InvalidCursor;

        var start = if (contracts.compare_raw_cursors(
            requested,
            self.record.available_from,
        ) == .lt)
            self.record.available_from
        else
            requested;
        var gap = if (contracts.compare_raw_cursors(requested, start) == .lt)
            contracts.RawGap{
                .missing_from = requested,
                .available_from = start,
            }
        else
            null;
        if (self.record.raw_gap) |raw_gap| {
            if (contracts.compare_raw_cursors(start, raw_gap.missing_from) != .lt and
                contracts.compare_raw_cursors(start, raw_gap.available_from) == .lt)
            {
                start = raw_gap.available_from;
                gap = raw_gap;
            }
        }
        if (contracts.compare_raw_cursors(start, self.record.output_cursor) == .eq) {
            return .{
                .output = try alloc.dupe(u8, ""),
                .range = null,
                .gap = gap,
            };
        }
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(alloc);
        try output.ensureTotalCapacity(alloc, max_bytes);
        var cursor = start;
        while (output.items.len < max_bytes and
            contracts.compare_raw_cursors(cursor, self.record.output_cursor) == .lt)
        {
            if (self.record.raw_gap) |raw_gap| {
                if (contracts.compare_raw_cursors(
                    cursor,
                    raw_gap.missing_from,
                ) == .eq) break;
            }
            const index = find_journal_file(self.record.journal_files, cursor) orelse
                return error.MissingJournalSegment;
            const extent = self.record.journal_files[index];
            const local_offset = cursor.offset - extent.range.start.offset;
            const remaining_file = extent.payload_bytes - local_offset;
            const wanted = @min(
                max_bytes - output.items.len,
                std.math.cast(usize, remaining_file) orelse
                    return error.InvalidReadLength,
            );
            const name = try journal_name(alloc, self.record.session_id, extent.file_id);
            defer alloc.free(name);
            var file = (try self.state_capability()).openFileReadOnly(
                alloc,
                .terminal_state,
                name,
            ) catch |err| switch (err) {
                error.FileNotFound => return error.MissingJournalSegment,
                else => return err,
            };
            defer file.deinit();
            const bytes = try file.readRange(alloc, local_offset, wanted);
            defer alloc.free(bytes);
            if (bytes.len != wanted) return error.CorruptJournalSegment;
            try output.appendSlice(alloc, bytes);
            cursor.offset = std.math.add(u64, cursor.offset, bytes.len) catch
                return error.CorruptJournalSegment;
            if (bytes.len == 0) return error.CorruptJournalSegment;
        }
        const owned_output = try output.toOwnedSlice(alloc);
        return .{
            .output = owned_output,
            .range = if (owned_output.len == 0) null else .{
                .start = start,
                .end = cursor,
            },
            .gap = gap,
        };
    }

    pub fn contains(
        self: *DurableSession,
        pattern: []const u8,
        requested: contracts.RawCursor,
    ) !bool {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (pattern.len == 0) return error.InvalidMatchPattern;
        try requested.validate();
        if (contracts.compare_raw_cursors(
            requested,
            self.record.output_cursor,
        ) == .gt) return false;
        var start = if (contracts.compare_raw_cursors(
            requested,
            self.record.available_from,
        ) == .lt)
            self.record.available_from
        else
            requested;
        if (self.record.raw_gap) |gap| {
            if (contracts.compare_raw_cursors(start, gap.missing_from) != .lt and
                contracts.compare_raw_cursors(start, gap.available_from) == .lt)
            {
                start = gap.available_from;
            }
        }
        var carry: std.ArrayList(u8) = .empty;
        defer carry.deinit(self.profile.alloc);
        try carry.ensureTotalCapacity(self.profile.alloc, pattern.len - 1);
        var cursor = start;
        while (contracts.compare_raw_cursors(
            cursor,
            self.record.output_cursor,
        ) == .lt) {
            if (self.record.raw_gap) |gap| {
                if (contracts.compare_raw_cursors(cursor, gap.missing_from) == .eq) {
                    carry.clearRetainingCapacity();
                    cursor = gap.available_from;
                    continue;
                }
            }
            const index = find_journal_file(self.record.journal_files, cursor) orelse
                return error.MissingJournalSegment;
            const extent = self.record.journal_files[index];
            const name = try journal_name(
                self.profile.alloc,
                self.record.session_id,
                extent.file_id,
            );
            defer self.profile.alloc.free(name);
            var file = (try self.state_capability()).openFileReadOnly(
                self.profile.alloc,
                .terminal_state,
                name,
            ) catch |err| switch (err) {
                error.FileNotFound => return error.MissingJournalSegment,
                else => return err,
            };
            defer file.deinit();
            const offset = cursor.offset - extent.range.start.offset;
            const length = std.math.cast(usize, extent.payload_bytes - offset) orelse
                return error.CapacityExceeded;
            const bytes = try file.readRange(self.profile.alloc, offset, length);
            defer self.profile.alloc.free(bytes);
            if (bytes.len != length) return error.CorruptJournalSegment;
            var combined: std.ArrayList(u8) = .empty;
            defer combined.deinit(self.profile.alloc);
            try combined.appendSlice(self.profile.alloc, carry.items);
            try combined.appendSlice(self.profile.alloc, bytes);
            if (std.mem.find(u8, combined.items, pattern) != null) return true;
            carry.clearRetainingCapacity();
            const tail_len = @min(combined.items.len, pattern.len - 1);
            if (tail_len != 0) {
                try carry.appendSlice(
                    self.profile.alloc,
                    combined.items[combined.items.len - tail_len ..],
                );
            }
            cursor = extent.range.end;
        }
        return false;
    }

    pub fn store_checkpoint(
        self: *DurableSession,
        envelope: contracts.CheckpointEnvelope,
        payload: []const u8,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.retry_checkpoint_cleanup();
        try envelope.validate(payload);
        if (contracts.compare_raw_cursors(
            envelope.applied_cursor,
            self.record.output_cursor,
        ) == .gt) return error.InvalidCheckpoint;
        if (self.profile.options.fail_at == .checkpoint_replacement) {
            return error.InjectedFailure;
        }
        const payload_len = std.math.cast(u64, payload.len) orelse
            return error.CapacityExceeded;
        const reserve = try checkpoint_reserve_bytes(self.record.dimensions);
        const session_after = std.math.add(
            u64,
            self.record.journal_payload_bytes,
            @max(reserve, payload_len),
        ) catch return error.CapacityExceeded;
        if (session_after > self.profile.options.per_session_limit) {
            return error.CapacityExceeded;
        }
        const additional = @max(reserve, payload_len) -|
            @max(reserve, self.record.checkpoint_payload_bytes);
        try self.profile.ensure_profile_capacity(additional, self.record.session_id);
        const bytes = try encode_checkpoint(self.profile.alloc, envelope, payload);
        defer self.profile.alloc.free(bytes);
        const next_generation = std.math.add(
            u64,
            self.record.checkpoint_generation,
            1,
        ) catch return error.CapacityExceeded;
        const name = try checkpoint_name(
            self.profile.alloc,
            self.record.session_id,
            next_generation,
        );
        defer self.profile.alloc.free(name);
        var entry = try (try self.state_capability()).atomicReplace(
            self.profile.alloc,
            .terminal_state,
            name,
            bytes,
        );
        entry.deinit(self.profile.alloc);
        if (self.profile.options.fail_at == .after_checkpoint_write) {
            return error.InjectedCrash;
        }
        const previous_recovery = self.record.screen_recovery;
        const previous_checkpoint_bytes = self.record.checkpoint_payload_bytes;
        const previous_generation = self.record.checkpoint_generation;
        const previous_cleanup_generation = self.record.checkpoint_cleanup_generation;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.screen_recovery = .{ .available = envelope };
        self.record.checkpoint_payload_bytes = payload_len;
        self.record.checkpoint_generation = next_generation;
        self.record.checkpoint_cleanup_generation = if (previous_generation == 0)
            previous_cleanup_generation
        else
            previous_generation;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.screen_recovery = previous_recovery;
            self.record.checkpoint_payload_bytes = previous_checkpoint_bytes;
            self.record.checkpoint_generation = previous_generation;
            self.record.checkpoint_cleanup_generation = previous_cleanup_generation;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        if (self.profile.options.fail_at == .after_checkpoint_record) {
            return error.InjectedCrash;
        }
        try self.retry_checkpoint_cleanup();
    }

    pub fn load_checkpoint(
        self: *DurableSession,
        alloc: Allocator,
    ) !?Checkpoint {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.load_checkpoint_locked(alloc);
    }

    fn load_checkpoint_locked(
        self: *DurableSession,
        alloc: Allocator,
    ) !?Checkpoint {
        const envelope = switch (self.record.screen_recovery) {
            .unavailable => return null,
            .available => |value| value,
        };
        const name = try checkpoint_name(
            alloc,
            self.record.session_id,
            self.record.checkpoint_generation,
        );
        defer alloc.free(name);
        var file = (try self.state_capability()).openFileReadOnly(
            alloc,
            .terminal_state,
            name,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.MissingCheckpoint,
            else => return err,
        };
        defer file.deinit();
        const bytes = try file.readToEnd(
            alloc,
            contracts.max_checkpoint_payload_bytes + checkpoint_header_bytes,
        );
        defer alloc.free(bytes);
        var checkpoint = try decode_checkpoint(alloc, bytes);
        errdefer checkpoint.deinit(alloc);
        if (!checkpoint_envelopes_equal(checkpoint.envelope, envelope)) {
            return error.InvalidCheckpoint;
        }
        if (checkpoint.payload.len != self.record.checkpoint_payload_bytes) {
            return error.InvalidCheckpoint;
        }
        return checkpoint;
    }

    fn retry_checkpoint_cleanup(self: *DurableSession) !void {
        const generation = self.record.checkpoint_cleanup_generation orelse return;
        const name = try checkpoint_name(
            self.profile.alloc,
            self.record.session_id,
            generation,
        );
        defer self.profile.alloc.free(name);
        (try self.state_capability()).delete(.terminal_state, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        self.record.checkpoint_cleanup_generation = null;
        try save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        );
    }

    pub fn append_event(
        self: *DurableSession,
        kind: contracts.HostEvent,
        now_ms: i64,
    ) !u64 {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.append_event_locked(kind, now_ms);
    }

    fn append_event_locked(
        self: *DurableSession,
        kind: contracts.HostEvent,
        now_ms: i64,
    ) !u64 {
        const event_id = self.record.next_event_id;
        try self.write_event_locked(kind, now_ms);
        if (self.profile.options.fail_at == .after_event_write) {
            return error.InjectedCrash;
        }
        const previous_updated_at_ms = self.record.updated_at_ms;
        const previous_gap = self.record.event_gap_through;
        self.record.next_event_id = std.math.add(u64, event_id, 1) catch
            return error.EventIdExhausted;
        if (event_id > event_retention_limit) {
            self.record.event_gap_through = @max(
                self.record.event_gap_through,
                event_id - event_retention_limit,
            );
        }
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.next_event_id = event_id;
            self.record.event_gap_through = previous_gap;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        try self.retry_event_cleanup_locked();
        return event_id;
    }

    fn write_event_locked(
        self: *DurableSession,
        kind: contracts.HostEvent,
        now_ms: i64,
    ) !void {
        const event_id = self.record.next_event_id;
        const event = DurableEvent{
            .id = event_id,
            .kind = kind,
            .lifecycle = self.record.lifecycle,
            .cursor = self.record.output_cursor,
            .created_at_ms = now_ms,
        };
        try self.write_event_value_locked(
            try self.state_capability(),
            event,
        );
    }

    fn write_event_value_locked(
        self: *DurableSession,
        capability: *session_child_store.SessionChildCapability,
        event: DurableEvent,
    ) !void {
        try event.validate();
        const bytes = try render_json(
            self.profile.alloc,
            EventWire{ .event = event },
        );
        defer self.profile.alloc.free(bytes);
        if (bytes.len > max_event_bytes) return error.DurableEventTooLarge;
        const name = try event_name(
            self.profile.alloc,
            self.record.session_id,
            event.id,
        );
        defer self.profile.alloc.free(name);
        var entry = try capability.atomicReplace(
            self.profile.alloc,
            .terminal_state,
            name,
            bytes,
        );
        entry.deinit(self.profile.alloc);
    }

    pub fn acknowledge(self: *DurableSession, event_id: u64, now_ms: i64) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (event_id <= self.record.acknowledged_event_id) {
            try self.retry_event_cleanup_locked();
            return;
        }
        if (event_id >= self.record.next_event_id) return error.UnknownEventId;
        if (self.profile.options.fail_at == .acknowledgement) {
            return error.InjectedFailure;
        }
        const previous_acknowledged = self.record.acknowledged_event_id;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.acknowledged_event_id = event_id;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.acknowledged_event_id = previous_acknowledged;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        if (self.profile.options.fail_at == .after_acknowledgement_record) {
            return error.InjectedCrash;
        }
        try self.retry_event_cleanup_locked();
    }

    fn retry_event_cleanup_locked(self: *DurableSession) !void {
        const target = @max(
            self.record.acknowledged_event_id,
            self.record.event_gap_through,
        );
        if (target <= self.record.event_cleanup_through) return;
        var id = self.record.event_cleanup_through + 1;
        while (id <= target) : (id += 1) {
            const name = try event_name(
                self.profile.alloc,
                self.record.session_id,
                id,
            );
            defer self.profile.alloc.free(name);
            (try self.state_capability()).delete(.terminal_state, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            if (id == std.math.maxInt(u64)) break;
        }
        self.record.event_cleanup_through = target;
        try save_record(self.profile.alloc, try self.state_capability(), self.record);
    }

    pub fn replay_events(
        self: *DurableSession,
        alloc: Allocator,
        after_event_id: u64,
        max_events: usize,
    ) !EventReplay {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (max_events == 0 or max_events > @as(usize, event_retention_limit)) {
            return error.InvalidEventReplayLimit;
        }
        const requested = std.math.add(u64, after_event_id, 1) catch
            return error.EventIdExhausted;
        const retained_after = @max(
            self.record.acknowledged_event_id,
            self.record.event_gap_through,
        );
        var id = @max(
            requested,
            std.math.add(u64, retained_after, 1) catch
                return error.EventIdExhausted,
        );
        var events: std.ArrayList(DurableEvent) = .empty;
        errdefer events.deinit(alloc);
        while (id < self.record.next_event_id and events.items.len < max_events) : (id += 1) {
            const event = try load_event(
                alloc,
                try self.state_capability(),
                self.record.session_id,
                id,
            );
            try events.append(alloc, event);
        }
        return .{
            .events = try events.toOwnedSlice(alloc),
            .next_event_id = @min(id, self.record.next_event_id),
        };
    }

    pub fn resize(
        self: *DurableSession,
        dimensions: contracts.Dimensions,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.retry_checkpoint_cleanup();
        try self.check_resize_capacity_locked(dimensions);
        const previous_reserve = if (is_live(self.record.lifecycle))
            @max(
                try checkpoint_reserve_bytes(self.record.dimensions),
                self.record.checkpoint_payload_bytes,
            )
        else
            self.record.checkpoint_payload_bytes;
        const next_reserve = if (is_live(self.record.lifecycle))
            @max(
                try checkpoint_reserve_bytes(dimensions),
                self.record.checkpoint_payload_bytes,
            )
        else
            self.record.checkpoint_payload_bytes;
        try self.profile.ensure_profile_capacity(
            next_reserve -| previous_reserve,
            self.record.session_id,
        );
        const previous_dimensions = self.record.dimensions;
        const previous_raw_replay_exact = self.record.raw_replay_exact;
        const previous_screen_recovery = self.record.screen_recovery;
        const previous_checkpoint_payload_bytes = self.record.checkpoint_payload_bytes;
        const previous_checkpoint_generation = self.record.checkpoint_generation;
        const previous_checkpoint_cleanup_generation = self.record.checkpoint_cleanup_generation;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.dimensions = dimensions;
        self.record.raw_replay_exact = false;
        self.record.screen_recovery = .{ .unavailable = .resize_uncheckpointed };
        self.record.checkpoint_payload_bytes = 0;
        self.record.checkpoint_generation = 0;
        self.record.checkpoint_cleanup_generation = if (previous_checkpoint_generation == 0)
            previous_checkpoint_cleanup_generation
        else
            previous_checkpoint_generation;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.dimensions = previous_dimensions;
            self.record.raw_replay_exact = previous_raw_replay_exact;
            self.record.screen_recovery = previous_screen_recovery;
            self.record.checkpoint_payload_bytes = previous_checkpoint_payload_bytes;
            self.record.checkpoint_generation = previous_checkpoint_generation;
            self.record.checkpoint_cleanup_generation = previous_checkpoint_cleanup_generation;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
    }

    pub fn check_resize_capacity(
        self: *const DurableSession,
        dimensions: contracts.Dimensions,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.check_resize_capacity_locked(dimensions);
    }

    fn check_resize_capacity_locked(
        self: *const DurableSession,
        dimensions: contracts.Dimensions,
    ) !void {
        try dimensions.validate();
        const reserve = try checkpoint_reserve_bytes(dimensions);
        const session_after = std.math.add(
            u64,
            self.record.journal_payload_bytes,
            @max(reserve, self.record.checkpoint_payload_bytes),
        ) catch return error.CapacityExceeded;
        if (session_after > self.profile.options.per_session_limit) {
            return error.CapacityExceeded;
        }
    }

    pub fn persist_termination(
        self: *DurableSession,
        termination: PersistedTermination,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.reject_close_intent_locked();
        try termination.validate();
        if (self.profile.options.fail_at == .finalization) {
            return error.InjectedFailure;
        }
        const previous_lifecycle = self.record.lifecycle;
        const previous_termination = self.record.termination;
        const previous_attention = self.record.attention;
        const previous_owner_pid = self.record.takeover_owner_pid;
        const previous_owner_process_token = self.record.takeover_owner_process_token;
        const previous_updated_at_ms = self.record.updated_at_ms;
        if (self.record.lifecycle == .starting or self.record.lifecycle == .running) {
            self.record.lifecycle = try contracts.transition_lifecycle(
                self.record.lifecycle,
                .child_exited,
            );
        }
        self.record.termination = termination;
        self.record.attention = .{};
        self.record.takeover_owner_pid = null;
        self.record.takeover_owner_process_token = null;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.lifecycle = previous_lifecycle;
            self.record.termination = previous_termination;
            self.record.attention = previous_attention;
            self.record.takeover_owner_pid = previous_owner_pid;
            self.record.takeover_owner_process_token = previous_owner_process_token;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        if (previous_owner_pid) |value| self.profile.alloc.free(value);
        if (previous_owner_process_token) |value| self.profile.alloc.free(value);
        _ = try self.append_event_locked(.lifecycle, now_ms);
    }

    pub fn termination_outcome(self: *DurableSession) ?contracts.ReturnOutcome {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const termination = self.record.termination orelse return null;
        return switch (termination) {
            .exited => |code| .{ .exited = code },
            .signal => |signal| .{ .signal = signal },
        };
    }

    pub fn persist_lost(self: *DurableSession, now_ms: i64) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.reject_close_intent_locked();
        if (self.profile.options.fail_at == .finalization) {
            return error.InjectedFailure;
        }
        defer self.release_completed_handles_locked();
        const previous_lifecycle = self.record.lifecycle;
        const previous_updated_at_ms = self.record.updated_at_ms;
        if (self.record.lifecycle == .starting or self.record.lifecycle == .running) {
            self.record.lifecycle = try contracts.transition_lifecycle(
                self.record.lifecycle,
                .host_lost,
            );
        }
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.lifecycle = previous_lifecycle;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        _ = try self.append_event_locked(.lifecycle, now_ms);
    }

    pub fn revoke(self: *DurableSession, now_ms: i64) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.revoke_locked(now_ms);
    }

    fn revoke_locked(self: *DurableSession, now_ms: i64) !void {
        if (self.record.authority_revoked) {
            try self.persist_attention_locked(.{}, now_ms);
            return;
        }
        if (self.profile.options.fail_at == .revoke) return error.InjectedFailure;
        const authority = try load_authority(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
        );
        defer authority.deinit();
        const next_generation = try self.record.authority_generation.next();
        const previous_generation = self.record.authority_generation;
        const previous_revoked = self.record.authority_revoked;
        const previous_attention = self.record.attention;
        const previous_owner_pid = self.record.takeover_owner_pid;
        const previous_owner_process_token = self.record.takeover_owner_process_token;
        const previous_updated_at_ms = self.record.updated_at_ms;
        var grant = authority.value.grant;
        grant.generation = next_generation;
        try write_authority(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
            grant,
            .{ .bytes = @splat(1) },
            true,
        );
        if (self.profile.options.fail_at == .after_authority_write) {
            return error.InjectedCrash;
        }
        self.record.authority_generation = next_generation;
        self.record.authority_revoked = true;
        self.record.attention = .{};
        self.record.takeover_owner_pid = null;
        self.record.takeover_owner_process_token = null;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.authority_generation = previous_generation;
            self.record.authority_revoked = previous_revoked;
            self.record.attention = previous_attention;
            self.record.takeover_owner_pid = previous_owner_pid;
            self.record.takeover_owner_process_token = previous_owner_process_token;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        if (previous_owner_process_token) |value| self.profile.alloc.free(value);
        if (previous_owner_pid) |value| self.profile.alloc.free(value);
        _ = try self.append_event_locked(.authority_revoked, now_ms);
    }

    pub fn begin_close(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        now_ms: i64,
    ) CloseCommitOutcome {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        claim.validate() catch |err| return .{ .previous = err };
        const capability = self.state_capability() catch |err| {
            return .{ .previous = err };
        };
        var existing = load_close_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
        ) catch |err| return .{ .indeterminate = err };
        if (existing) |*transaction| {
            defer transaction.deinit();
            const expected = transaction.value.initiator_verifier orelse
                return .{ .previous = error.AuthorityRevoked };
            const actual = close_initiator_verifier(claim);
            if (!std.mem.eql(u8, &expected, &actual)) {
                return .{ .previous = error.InvalidHolderProof };
            }
            self.reconcile_close_authority_locked(
                capability,
                transaction.value,
            ) catch |err| return .{ .candidate = err };
            return .{ .candidate = null };
        }
        if (self.record.lifecycle == .closed) {
            return .{ .previous = error.AuthorityRevoked };
        }
        _ = self.authorize_locked(claim, .close) catch |err| {
            return .{ .previous = err };
        };
        if (self.profile.options.fail_at == .close) {
            return .{ .previous = error.InjectedFailure };
        }
        const authority_generation = self.record.authority_generation.next() catch |err| {
            return .{ .previous = err };
        };
        const transaction = CloseTransaction{
            .updated_at_ms = now_ms,
            .initiator_verifier = close_initiator_verifier(claim),
            .authority_generation = authority_generation,
            .authority_event = .{
                .id = self.record.next_event_id,
                .kind = .authority_revoked,
                .lifecycle = self.record.lifecycle,
                .cursor = self.record.output_cursor,
                .created_at_ms = now_ms,
            },
        };
        write_close_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
            transaction,
        ) catch |err| return .{ .previous = err };
        self.reconcile_close_authority_locked(
            capability,
            transaction,
        ) catch |err| return .{ .candidate = err };
        return .{ .candidate = null };
    }

    fn reject_close_intent_locked(self: *DurableSession) !void {
        var transaction = (try load_close_transaction(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
        )) orelse return;
        transaction.deinit();
        return error.CloseIntentCommitted;
    }

    pub fn finish_close(self: *DurableSession, now_ms: i64) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (try self.reconcile_close_transaction_locked(now_ms, true)) return;
        if (self.record.lifecycle != .closed) return error.CloseIntentNotFound;
        self.release_completed_handles_locked();
    }

    fn reconcile_close_transaction(self: *DurableSession, now_ms: i64) !bool {
        if (self.profile.options.fail_at == .before_close_recovery_oom) {
            return error.OutOfMemory;
        }
        if (self.profile.options.fail_at == .before_close_recovery_capability) {
            return error.PrivateStatePermissionsUnsupported;
        }
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.reconcile_close_transaction_locked(now_ms, false);
    }

    fn reconcile_close_transaction_locked(
        self: *DurableSession,
        now_ms: i64,
        cleanup_transaction: bool,
    ) !bool {
        const capability = try self.state_capability();
        var parsed = (try load_close_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
        )) orelse return false;
        defer parsed.deinit();
        try self.reconcile_close_authority_locked(capability, parsed.value);

        if (parsed.value.lifecycle_event == null) {
            parsed.value.lifecycle_event = .{
                .id = self.record.next_event_id,
                .kind = .lifecycle,
                .lifecycle = .closed,
                .cursor = self.record.output_cursor,
                .created_at_ms = now_ms,
            };
            try write_close_transaction(
                self.profile.alloc,
                capability,
                self.record.session_id,
                parsed.value,
            );
        }
        const lifecycle_event = parsed.value.lifecycle_event.?;
        if (self.record.lifecycle != .closed) {
            const previous_lifecycle = self.record.lifecycle;
            const previous_updated_at_ms = self.record.updated_at_ms;
            self.record.lifecycle = try contracts.transition_lifecycle(
                self.record.lifecycle,
                .close,
            );
            self.record.updated_at_ms = now_ms;
            save_record(
                self.profile.alloc,
                capability,
                self.record,
            ) catch |err| {
                self.record.lifecycle = previous_lifecycle;
                self.record.updated_at_ms = previous_updated_at_ms;
                return err;
            };
        }
        if (closeFailureAt(self.profile, .after_close_lifecycle_record)) {
            return error.InjectedCrash;
        }
        try self.commit_close_event_locked(capability, lifecycle_event);
        if (closeFailureAt(self.profile, .after_close_lifecycle_event)) {
            return error.InjectedCrash;
        }
        if (!cleanup_transaction) return true;
        try delete_close_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
        );
        self.release_completed_handles_locked();
        if (closeFailureAt(self.profile, .after_close_cleanup)) {
            return error.InjectedCrash;
        }
        return true;
    }

    fn isolate_invalid_close_transaction(
        self: *DurableSession,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const capability = try self.state_capability();
        var authority = try load_authority(
            self.profile.alloc,
            capability,
            self.record.session_id,
        );
        defer authority.deinit();
        try validate_recovery_principal(&self.record, &authority.value);
        const current_generation = @max(
            self.record.authority_generation.value,
            authority.value.grant.generation.value,
        );
        const authority_generation = (contracts.AuthorityGeneration{
            .value = current_generation,
        }).next() catch |err| return err;
        const transaction = CloseTransaction{
            .updated_at_ms = now_ms,
            .initiator_verifier = null,
            .authority_generation = authority_generation,
            .authority_event = .{
                .id = self.record.next_event_id,
                .kind = .authority_revoked,
                .lifecycle = self.record.lifecycle,
                .cursor = self.record.output_cursor,
                .created_at_ms = now_ms,
            },
        };
        try write_close_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
            transaction,
        );
        _ = try self.reconcile_close_transaction_locked(now_ms, false);
    }

    pub fn close_cleanup_pending(self: *DurableSession) !bool {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        var transaction = try load_close_transaction(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
        );
        defer if (transaction) |*value| value.deinit();
        return transaction != null;
    }

    fn reconcile_close_authority_locked(
        self: *DurableSession,
        capability: *session_child_store.SessionChildCapability,
        transaction: CloseTransaction,
    ) !void {
        var authority = try load_authority(
            self.profile.alloc,
            capability,
            self.record.session_id,
        );
        defer authority.deinit();
        try validate_recovery_principal(&self.record, &authority.value);
        if (authority.value.grant.generation.value >
            transaction.authority_generation.value)
        {
            return error.InvalidCloseTransaction;
        }
        if (authority.value.grant.generation.value <
            transaction.authority_generation.value or !authority.value.revoked)
        {
            var grant = authority.value.grant;
            grant.generation = transaction.authority_generation;
            try write_authority(
                self.profile.alloc,
                capability,
                self.record.session_id,
                grant,
                .{ .bytes = @splat(1) },
                true,
            );
        }
        if (closeFailureAt(self.profile, .after_close_authority_write)) {
            return error.InjectedCrash;
        }
        if (self.record.authority_generation.value >
            transaction.authority_generation.value)
        {
            return error.InvalidCloseTransaction;
        }
        if (self.record.authority_generation.value <
            transaction.authority_generation.value or
            !self.record.authority_revoked or
            !std.meta.eql(self.record.attention, contracts.AttentionState{}) or
            self.record.takeover_owner_pid != null or
            self.record.takeover_owner_process_token != null)
        {
            const previous_generation = self.record.authority_generation;
            const previous_revoked = self.record.authority_revoked;
            const previous_attention = self.record.attention;
            const previous_owner_pid = self.record.takeover_owner_pid;
            const previous_owner_process_token = self.record.takeover_owner_process_token;
            const previous_updated_at_ms = self.record.updated_at_ms;
            self.record.authority_generation = transaction.authority_generation;
            self.record.authority_revoked = true;
            self.record.attention = .{};
            self.record.takeover_owner_pid = null;
            self.record.takeover_owner_process_token = null;
            self.record.updated_at_ms = transaction.updated_at_ms;
            save_record(
                self.profile.alloc,
                capability,
                self.record,
            ) catch |err| {
                self.record.authority_generation = previous_generation;
                self.record.authority_revoked = previous_revoked;
                self.record.attention = previous_attention;
                self.record.takeover_owner_pid = previous_owner_pid;
                self.record.takeover_owner_process_token = previous_owner_process_token;
                self.record.updated_at_ms = previous_updated_at_ms;
                return err;
            };
            if (previous_owner_process_token) |value| self.profile.alloc.free(value);
            if (previous_owner_pid) |value| self.profile.alloc.free(value);
        }
        if (closeFailureAt(self.profile, .after_close_record_write)) {
            return error.InjectedCrash;
        }
        try self.commit_close_event_locked(capability, transaction.authority_event);
        if (closeFailureAt(self.profile, .after_close_authority_event)) {
            return error.InjectedCrash;
        }
    }

    fn commit_close_event_locked(
        self: *DurableSession,
        capability: *session_child_store.SessionChildCapability,
        event: DurableEvent,
    ) !void {
        const next_event_id = std.math.add(u64, event.id, 1) catch
            return error.EventIdExhausted;
        if (self.record.next_event_id < event.id) {
            return error.InvalidCloseTransaction;
        }
        const existing = load_event(
            self.profile.alloc,
            capability,
            self.record.session_id,
            event.id,
        ) catch |err| switch (err) {
            error.MissingDurableEvent => null,
            else => return err,
        };
        if (existing) |persisted| {
            if (!std.meta.eql(event, persisted)) return error.InvalidCloseTransaction;
        } else {
            if (self.record.next_event_id > event.id) {
                return error.InvalidCloseTransaction;
            }
            try self.write_event_value_locked(capability, event);
        }
        if (self.record.next_event_id >= next_event_id) return;
        const previous_gap = self.record.event_gap_through;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.next_event_id = next_event_id;
        if (event.id > event_retention_limit) {
            self.record.event_gap_through = @max(
                self.record.event_gap_through,
                event.id - event_retention_limit,
            );
        }
        self.record.updated_at_ms = event.created_at_ms;
        save_record(
            self.profile.alloc,
            capability,
            self.record,
        ) catch |err| {
            self.record.next_event_id = event.id;
            self.record.event_gap_through = previous_gap;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
    }

    pub fn verify_claim(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        action: contracts.Action,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        _ = try self.authorize_locked(claim, action);
    }

    pub fn authorize(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        action: contracts.Action,
    ) !Authorization {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.authorize_locked(claim, action);
    }

    fn authorize_locked(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        action: contracts.Action,
    ) !Authorization {
        const authorization = try self.resolve_claim_locked(claim);
        if (!authorization.controls.allows(action)) return error.ControlDenied;
        if (authorization.actor == .human and
            self.record.attention.write_lease == .human)
        {
            try self.verify_takeover_owner_locked(claim.process_owner);
        }
        return authorization;
    }

    fn resolve_claim_locked(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
    ) !Authorization {
        _ = try self.reconcile_takeover_owner_locked(io_mod.milliTimestamp());
        const authority = try load_authority(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
        );
        defer authority.deinit();
        if (authority.value.revoked or self.record.authority_revoked) {
            return error.AuthorityRevoked;
        }
        const grant = authority.value.grant;
        const human_takeover = grant.actor == .agent and claim.actor == .human;
        const controls = if (human_takeover)
            contracts.AllowedControls.humanTakeover()
        else
            grant.controls;
        try claim.validate();
        if (!grant.principal.eql(claim.principal)) {
            return error.PrincipalMismatch;
        }
        if (!human_takeover and grant.actor != claim.actor) {
            return error.ActorRoleMismatch;
        }
        if (grant.generation.value != claim.generation.value) {
            return error.StaleAuthorityGeneration;
        }
        if (human_takeover) {
            verify_owner_catalog_claim(self.profile.alloc, self.profile, .{
                .principal = .{
                    .profile_user = claim.principal.profile_user,
                    .durable_session_id = claim.principal.durable_session_id,
                    .workspace_root = claim.principal.workspace_root,
                    .transport_role = claim.principal.transport_role,
                },
                .actor = .human,
                .proof = .{ .bytes = claim.proof.bytes },
            }) catch |err| switch (err) {
                error.OwnerCatalogAuthorityNotFound => return error.ActorRoleMismatch,
                else => return err,
            };
        } else {
            const actual = proof_verifier(
                claim.proof,
                authority.value.grant,
            );
            if (!std.mem.eql(u8, &actual, &authority.value.verifier)) {
                return error.InvalidHolderProof;
            }
        }
        return .{
            .actor = claim.actor,
            .controls = controls,
        };
    }

    pub fn acquire_write_lease(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        now_ms: i64,
    ) !Authorization {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const authorization = try self.resolve_claim_locked(claim);
        const lease: contracts.WriteLease = switch (authorization.actor) {
            .human => .human,
            .agent => .agent,
        };
        if (self.record.attention.write_lease != .none and
            self.record.attention.write_lease != lease)
        {
            return error.LeaseConflict;
        }
        if (!authorization.controls.write) return error.ControlDenied;
        var attention = self.record.attention;
        attention.write_lease = lease;
        if (authorization.actor == .human) {
            const owner = claim.process_owner orelse
                return error.InvalidAuthorityClaim;
            if (self.record.attention.write_lease == .human and
                !takeover_owner_matches(self.record, &owner))
            {
                return error.LeaseConflict;
            }
            attention.attention = .user_takeover;
            try self.persist_attention_with_owner_locked(
                attention,
                &owner,
                now_ms,
            );
        } else {
            try self.persist_attention_locked(attention, now_ms);
        }
        return authorization;
    }

    pub fn cancel_claim(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (self.profile.options.fail_at == .cancellation) {
            return error.InjectedCancellationPersistenceFailure;
        }
        const authorization = try self.resolve_claim_locked(claim);
        if (authorization.actor == .human and
            self.record.attention.write_lease == .human)
        {
            try self.verify_takeover_owner_locked(claim.process_owner);
        }
        try self.persist_attention_locked(
            contracts.cancel_attention(self.record.attention, authorization.actor),
            now_ms,
        );
    }

    pub fn release_write_lease(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        now_ms: i64,
    ) !Authorization {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const authorization = try self.authorize_locked(claim, .write);
        const lease: contracts.WriteLease = switch (authorization.actor) {
            .human => .human,
            .agent => .agent,
        };
        if (self.record.attention.write_lease != .none and
            self.record.attention.write_lease != lease)
        {
            return error.LeaseConflict;
        }
        try self.persist_attention_locked(
            contracts.cancel_attention(self.record.attention, authorization.actor),
            now_ms,
        );
        return authorization;
    }

    pub fn authorize_write(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
    ) !Authorization {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const authorization = try self.authorize_locked(claim, .write);
        const lease: contracts.WriteLease = switch (authorization.actor) {
            .human => .human,
            .agent => .agent,
        };
        if (self.record.attention.write_lease != lease) {
            return error.LeaseConflict;
        }
        return authorization;
    }

    pub fn begin_wait(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        now_ms: i64,
    ) !Authorization {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const authorization = try self.authorize_locked(claim, .wait);
        if (authorization.actor == .agent) {
            var attention = self.record.attention;
            attention.attention = .agent_wait;
            try self.persist_attention_locked(attention, now_ms);
        }
        return authorization;
    }

    pub fn finish_wait(
        self: *DurableSession,
        actor: contracts.ActorRole,
        cancelled: bool,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        var attention = self.record.attention;
        if (actor == .agent and attention.attention == .agent_wait) {
            attention.attention = .background;
        }
        if (cancelled) attention = contracts.cancel_attention(attention, actor);
        try self.persist_attention_locked(attention, now_ms);
    }

    pub fn revoke_claim(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        _ = try self.authorize_locked(claim, .close);
        try self.revoke_locked(now_ms);
    }

    fn persist_attention_locked(
        self: *DurableSession,
        attention: contracts.AttentionState,
        now_ms: i64,
    ) !void {
        if (attention.write_lease == .human) {
            return self.persist_attention_state_locked(
                attention,
                self.record.takeover_owner_pid,
                self.record.takeover_owner_process_token,
                now_ms,
            );
        }
        return self.persist_attention_state_locked(attention, null, null, now_ms);
    }

    fn persist_attention_with_owner_locked(
        self: *DurableSession,
        attention: contracts.AttentionState,
        owner: *const contracts.ProcessOwner,
        now_ms: i64,
    ) !void {
        var pid_buffer: [32]u8 = undefined;
        const pid = try std.mem.print(&pid_buffer, "{d}", .{owner.pid});
        return self.persist_attention_state_locked(
            attention,
            pid,
            owner.token(),
            now_ms,
        );
    }

    fn persist_attention_state_locked(
        self: *DurableSession,
        attention: contracts.AttentionState,
        takeover_owner_pid: ?[]const u8,
        takeover_owner_process_token: ?[]const u8,
        now_ms: i64,
    ) !void {
        try attention.validate();
        const owner_complete = takeover_owner_pid != null and
            takeover_owner_process_token != null;
        const human_takeover = attention.attention == .user_takeover and
            attention.write_lease == .human;
        if (owner_complete != human_takeover or
            ((takeover_owner_pid == null) !=
                (takeover_owner_process_token == null)))
        {
            return error.InvalidAttentionState;
        }
        const owner_unchanged = optional_text_eql(
            self.record.takeover_owner_pid,
            takeover_owner_pid,
        ) and optional_text_eql(
            self.record.takeover_owner_process_token,
            takeover_owner_process_token,
        );
        if (std.meta.eql(self.record.attention, attention) and owner_unchanged) return;

        const next_owner_pid = if (takeover_owner_pid) |value|
            try self.profile.alloc.dupe(u8, value)
        else
            null;
        errdefer if (next_owner_pid) |value| self.profile.alloc.free(value);
        const next_owner_process_token = if (takeover_owner_process_token) |value|
            try self.profile.alloc.dupe(u8, value)
        else
            null;
        errdefer if (next_owner_process_token) |value| self.profile.alloc.free(value);

        const previous_attention = self.record.attention;
        const previous_owner_pid = self.record.takeover_owner_pid;
        const previous_owner_process_token = self.record.takeover_owner_process_token;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.attention = attention;
        self.record.takeover_owner_pid = next_owner_pid;
        self.record.takeover_owner_process_token = next_owner_process_token;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.attention = previous_attention;
            self.record.takeover_owner_pid = previous_owner_pid;
            self.record.takeover_owner_process_token = previous_owner_process_token;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        if (previous_owner_process_token) |value| self.profile.alloc.free(value);
        if (previous_owner_pid) |value| self.profile.alloc.free(value);
    }

    fn verify_takeover_owner_locked(
        self: *DurableSession,
        process_owner: ?contracts.ProcessOwner,
    ) !void {
        const owner = process_owner orelse return error.InvalidAuthorityClaim;
        if (!takeover_owner_matches(self.record, &owner)) {
            return error.LeaseConflict;
        }
    }

    fn reconcile_takeover_owner_locked(
        self: *DurableSession,
        now_ms: i64,
    ) !bool {
        return reconcile_takeover_owner_record(
            self.profile.alloc,
            self.profile.process_provider,
            try self.state_capability(),
            &self.record,
            now_ms,
        );
    }

    pub fn facts(self: *const DurableSession) contracts.SessionFacts {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return facts_from_record(self.record, self.record.session_id);
    }

    pub fn available_cursor(self: *const DurableSession) contracts.RawCursor {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.record.available_from;
    }

    pub fn output_cursor(self: *const DurableSession) contracts.RawCursor {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.record.output_cursor;
    }

    pub fn checkpoint_due_cursor(self: *const DurableSession) ?contracts.RawCursor {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const anchor = switch (self.record.screen_recovery) {
            .available => |checkpoint| checkpoint.applied_cursor,
            .unavailable => contracts.RawCursor{ .segment = 1, .offset = 0 },
        };
        const output = self.record.output_cursor;
        if (contracts.compare_raw_cursors(anchor, output) != .lt) return null;
        if (anchor.segment != output.segment or
            output.offset - anchor.offset >= self.profile.options.segment_bytes)
        {
            return output;
        }
        return null;
    }

    pub fn mark_screen_unavailable(
        self: *DurableSession,
        reason: contracts.ScreenUnavailableReason,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.mark_screen_unavailable_locked(reason, now_ms);
    }

    fn mark_screen_unavailable_locked(
        self: *DurableSession,
        reason: contracts.ScreenUnavailableReason,
        now_ms: i64,
    ) !void {
        if (self.record.checkpoint_generation == 0) {
            switch (self.record.screen_recovery) {
                .unavailable => |current| if (current == reason) return,
                .available => {},
            }
        }
        try self.retry_checkpoint_cleanup();
        const previous_recovery = self.record.screen_recovery;
        const previous_checkpoint_bytes = self.record.checkpoint_payload_bytes;
        const previous_generation = self.record.checkpoint_generation;
        const previous_cleanup_generation = self.record.checkpoint_cleanup_generation;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.screen_recovery = .{ .unavailable = reason };
        self.record.checkpoint_payload_bytes = 0;
        self.record.checkpoint_generation = 0;
        self.record.checkpoint_cleanup_generation = if (previous_generation == 0)
            previous_cleanup_generation
        else
            previous_generation;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.screen_recovery = previous_recovery;
            self.record.checkpoint_payload_bytes = previous_checkpoint_bytes;
            self.record.checkpoint_generation = previous_generation;
            self.record.checkpoint_cleanup_generation = previous_cleanup_generation;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        try self.retry_checkpoint_cleanup();
    }

    pub fn reconcile_checkpoint(self: *DurableSession) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.retry_checkpoint_cleanup();
        switch (self.record.screen_recovery) {
            .unavailable => return,
            .available => {},
        }
        var checkpoint = self.load_checkpoint_locked(self.profile.alloc) catch |err| {
            const reason = checkpoint_load_unavailable_reason(err) orelse
                return err;
            try self.mark_screen_unavailable_locked(
                reason,
                io_mod.milliTimestamp(),
            );
            return;
        } orelse return;
        defer checkpoint.deinit(self.profile.alloc);
        if (!contiguous_after_checkpoint(
            checkpoint.envelope,
            self.record.available_from,
            self.record.output_cursor,
        )) {
            try self.mark_screen_unavailable_locked(.raw_gap, io_mod.milliTimestamp());
        }
    }

    fn reconcile_authority(self: *DurableSession) !bool {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const authority = try load_authority(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
        );
        defer authority.deinit();
        try validate_recovery_principal(&self.record, &authority.value);
        if (authority.value.grant.generation.value <
            self.record.authority_generation.value)
        {
            return error.InvalidAuthorityRecord;
        }
        if (self.record.authority_revoked and !authority.value.revoked) {
            return error.InvalidAuthorityRecord;
        }
        const authority_matches = authority.value.grant.generation.value ==
            self.record.authority_generation.value and
            authority.value.revoked == self.record.authority_revoked;
        const revoked_takeover = authority.value.revoked and
            (self.record.attention.attention == .user_takeover or
                self.record.attention.write_lease == .human or
                self.record.takeover_owner_pid != null or
                self.record.takeover_owner_process_token != null);
        if (authority_matches and !revoked_takeover) {
            try validate_recovery_authority(&self.record, &authority.value);
            return false;
        }
        const previous_generation = self.record.authority_generation;
        const previous_revoked = self.record.authority_revoked;
        const previous_attention = self.record.attention;
        const previous_owner_pid = self.record.takeover_owner_pid;
        const previous_owner_process_token = self.record.takeover_owner_process_token;
        self.record.authority_generation = authority.value.grant.generation;
        self.record.authority_revoked = authority.value.revoked;
        if (authority.value.revoked) {
            self.record.attention = .{};
            self.record.takeover_owner_pid = null;
            self.record.takeover_owner_process_token = null;
        }
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.authority_generation = previous_generation;
            self.record.authority_revoked = previous_revoked;
            self.record.attention = previous_attention;
            self.record.takeover_owner_pid = previous_owner_pid;
            self.record.takeover_owner_process_token = previous_owner_process_token;
            return err;
        };
        if (authority.value.revoked) {
            if (previous_owner_process_token) |value| self.profile.alloc.free(value);
            if (previous_owner_pid) |value| self.profile.alloc.free(value);
        }
        try validate_recovery_authority(&self.record, &authority.value);
        return true;
    }

    fn reconcile_unreferenced_artifacts(self: *DurableSession) !bool {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.retry_journal_cleanup();
        try self.retry_checkpoint_cleanup();
        const capability = try self.state_capability();
        var names = try capability.iterate(self.profile.alloc, .terminal_state);
        defer names.deinit();
        const legacy_monitors_name = try make_name(
            self.profile.alloc,
            "monitors",
            self.record.session_id,
            ".json",
        );
        defer self.profile.alloc.free(legacy_monitors_name);
        const legacy_monitor_transaction_name = try make_name(
            self.profile.alloc,
            "monitor-transaction",
            self.record.session_id,
            ".json",
        );
        defer self.profile.alloc.free(legacy_monitor_transaction_name);
        var repaired = false;
        for (names.names) |name| {
            if (indexed_artifact_id(
                name,
                "journal",
                self.record.session_id,
                ".bin",
            )) |file_id| {
                var referenced = false;
                for (self.record.journal_files) |file| {
                    if (file.file_id == file_id) {
                        referenced = true;
                        break;
                    }
                }
                if (referenced) continue;
            } else if (indexed_artifact_id(
                name,
                "checkpoint",
                self.record.session_id,
                ".bin",
            )) |generation| {
                if (generation == self.record.checkpoint_generation) continue;
            } else if (!std.mem.eql(u8, name, legacy_monitors_name) and
                !std.mem.eql(u8, name, legacy_monitor_transaction_name))
            {
                continue;
            }
            capability.delete(.terminal_state, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            repaired = true;
        }
        if (self.record.monitor_count != 0) {
            self.record.monitor_count = 0;
            try save_record(self.profile.alloc, capability, self.record);
            repaired = true;
        }
        return repaired;
    }

    fn reconcile_events(self: *DurableSession) !bool {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.retry_event_cleanup_locked();
        const capability = try self.state_capability();
        var names = try capability.iterate(self.profile.alloc, .terminal_state);
        defer names.deinit();
        var repaired = false;
        for (names.names) |name| {
            const id = indexed_artifact_id(
                name,
                "event",
                self.record.session_id,
                ".json",
            ) orelse continue;
            if (id < self.record.next_event_id) continue;
            capability.delete(.terminal_state, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            repaired = true;
        }
        const cleanup_target = @max(
            self.record.acknowledged_event_id,
            self.record.event_gap_through,
        );
        var id = std.math.add(u64, cleanup_target, 1) catch
            return error.EventIdExhausted;
        var gap_through = self.record.event_gap_through;
        while (id < self.record.next_event_id) : (id += 1) {
            _ = load_event(
                self.profile.alloc,
                capability,
                self.record.session_id,
                id,
            ) catch {
                gap_through = id;
                repaired = true;
                continue;
            };
        }
        if (gap_through != self.record.event_gap_through) {
            self.record.event_gap_through = gap_through;
            try save_record(self.profile.alloc, capability, self.record);
            try self.retry_event_cleanup_locked();
        }
        return repaired;
    }

    fn reconcile_journals(self: *DurableSession) !bool {
        try self.retry_journal_cleanup();
        if (self.record.journal_files.len == 0) return false;
        const alloc = self.profile.alloc;
        const valid = try alloc.alloc(bool, self.record.journal_files.len);
        defer alloc.free(valid);
        var corrupted = false;
        for (self.record.journal_files, 0..) |extent, index| {
            const name = try journal_name(alloc, self.record.session_id, extent.file_id);
            defer alloc.free(name);
            const capability = try self.state_capability();
            const stat = capability.stat(.terminal_state, name) catch {
                valid[index] = false;
                corrupted = true;
                continue;
            };
            if (stat.size > extent.payload_bytes) {
                capability.truncate(
                    .terminal_state,
                    name,
                    extent.payload_bytes,
                ) catch {
                    valid[index] = false;
                    corrupted = true;
                    continue;
                };
                corrupted = true;
            } else if (stat.size < extent.payload_bytes) {
                valid[index] = false;
                corrupted = true;
                continue;
            }
            var file = capability.openFileReadOnly(
                alloc,
                .terminal_state,
                name,
            ) catch {
                valid[index] = false;
                corrupted = true;
                continue;
            };
            defer file.deinit();
            const expected = std.math.cast(usize, extent.payload_bytes) orelse
                return error.CapacityExceeded;
            const bytes = file.readToEnd(alloc, expected + 1) catch {
                valid[index] = false;
                corrupted = true;
                continue;
            };
            defer alloc.free(bytes);
            const actual_checksum = contracts.checkpoint_checksum(bytes);
            valid[index] = bytes.len == expected and std.mem.eql(
                u8,
                &actual_checksum,
                &extent.checksum,
            );
            corrupted = corrupted or !valid[index];
        }
        if (!corrupted) return false;

        var first_retained = self.record.journal_files.len;
        while (first_retained != 0 and valid[first_retained - 1]) {
            first_retained -= 1;
        }
        const previous_files = self.record.journal_files;
        const retained = try alloc.dupe(JournalFile, previous_files[first_retained..]);
        errdefer alloc.free(retained);
        var retained_bytes: u64 = 0;
        for (retained) |extent| {
            retained_bytes = std.math.add(
                u64,
                retained_bytes,
                extent.payload_bytes,
            ) catch return error.CapacityExceeded;
        }
        const previous_available = self.record.available_from;
        const new_available = if (retained.len == 0)
            self.record.output_cursor
        else
            retained[0].range.start;
        self.record.journal_files = retained;
        self.record.available_from = new_available;
        self.record.raw_gap = if (contracts.compare_raw_cursors(
            previous_available,
            new_available,
        ) == .lt) .{
            .missing_from = previous_available,
            .available_from = new_available,
        } else self.record.raw_gap;
        self.record.journal_payload_bytes = retained_bytes;
        if (first_retained != 0) {
            self.record.journal_cleanup_through = @max(
                self.record.journal_cleanup_through,
                previous_files[first_retained - 1].file_id,
            );
        }
        switch (self.record.screen_recovery) {
            .available => |checkpoint| {
                if (contracts.compare_raw_cursors(
                    checkpoint.applied_cursor,
                    new_available,
                ) == .lt) {
                    self.record.screen_recovery = .{ .unavailable = .raw_gap };
                    self.record.checkpoint_cleanup_generation =
                        self.record.checkpoint_generation;
                    self.record.checkpoint_generation = 0;
                    self.record.checkpoint_payload_bytes = 0;
                }
            },
            .unavailable => {},
        }
        try save_record(alloc, try self.state_capability(), self.record);
        alloc.free(previous_files);
        try self.retry_journal_cleanup();
        try self.retry_checkpoint_cleanup();
        return true;
    }

    fn evict_completed_output(self: *DurableSession) !void {
        if (!is_completed(self.record.lifecycle) or
            self.record.journal_payload_bytes == 0)
        {
            return error.InvalidEviction;
        }
        try self.commit_journal_eviction(self.record.journal_files.len);
    }

    fn evict_completed_checkpoint(self: *DurableSession) !void {
        if (!is_completed(self.record.lifecycle) or
            self.record.checkpoint_payload_bytes == 0)
        {
            return error.InvalidEviction;
        }
        const generation = self.record.checkpoint_generation;
        const previous_recovery = self.record.screen_recovery;
        const previous_bytes = self.record.checkpoint_payload_bytes;
        const previous_cleanup = self.record.checkpoint_cleanup_generation;
        self.record.screen_recovery = .{ .unavailable = .retention_evicted };
        self.record.checkpoint_payload_bytes = 0;
        self.record.checkpoint_generation = 0;
        self.record.checkpoint_cleanup_generation = generation;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.screen_recovery = previous_recovery;
            self.record.checkpoint_payload_bytes = previous_bytes;
            self.record.checkpoint_generation = generation;
            self.record.checkpoint_cleanup_generation = previous_cleanup;
            return err;
        };
        if (self.profile.options.fail_at == .after_eviction_record) {
            return error.InjectedCrash;
        }
        try self.retry_checkpoint_cleanup();
    }

    fn evict_live_covered_journals(self: *DurableSession) !void {
        if (!is_live(self.record.lifecycle)) return error.InvalidEviction;
        const checkpoint = switch (self.record.screen_recovery) {
            .unavailable => return error.InvalidEviction,
            .available => |value| value,
        };
        var remove_count: usize = 0;
        while (remove_count + 1 < self.record.journal_files.len) : (remove_count += 1) {
            const file = self.record.journal_files[remove_count];
            if (file.payload_bytes != self.profile.options.segment_bytes or
                contracts.compare_raw_cursors(
                    file.range.end,
                    checkpoint.applied_cursor,
                ) == .gt)
            {
                break;
            }
        }
        if (remove_count == 0) return error.InvalidEviction;
        try self.commit_journal_eviction(remove_count);
    }

    fn commit_journal_eviction(
        self: *DurableSession,
        remove_count: usize,
    ) !void {
        if (remove_count == 0 or remove_count > self.record.journal_files.len) {
            return error.InvalidEviction;
        }
        const alloc = self.profile.alloc;
        const previous_files = self.record.journal_files;
        const retained = try alloc.dupe(JournalFile, previous_files[remove_count..]);
        errdefer alloc.free(retained);
        var removed_bytes: u64 = 0;
        for (previous_files[0..remove_count]) |file| {
            removed_bytes = std.math.add(
                u64,
                removed_bytes,
                file.payload_bytes,
            ) catch return error.CapacityExceeded;
        }
        const previous_available = self.record.available_from;
        const previous_gap = self.record.raw_gap;
        const previous_journal_bytes = self.record.journal_payload_bytes;
        const previous_cleanup = self.record.journal_cleanup_through;
        const new_available = if (retained.len == 0)
            self.record.output_cursor
        else
            retained[0].range.start;
        self.record.journal_files = retained;
        self.record.available_from = new_available;
        self.record.raw_gap = .{
            .missing_from = previous_available,
            .available_from = new_available,
        };
        self.record.journal_payload_bytes -= removed_bytes;
        self.record.journal_cleanup_through = @max(
            previous_cleanup,
            previous_files[remove_count - 1].file_id,
        );
        save_record(
            alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.journal_files = previous_files;
            self.record.available_from = previous_available;
            self.record.raw_gap = previous_gap;
            self.record.journal_payload_bytes = previous_journal_bytes;
            self.record.journal_cleanup_through = previous_cleanup;
            return err;
        };
        alloc.free(previous_files);
        if (self.profile.options.fail_at == .after_eviction_record) {
            return error.InjectedCrash;
        }
        if (retained.len == 0) {
            if (self.journal) |*journal| journal.deinit();
            self.journal = null;
        }
        try self.retry_journal_cleanup();
    }

    fn retry_journal_cleanup(self: *DurableSession) !void {
        const through = self.record.journal_cleanup_through;
        if (through == 0) return;
        var file_id: u64 = 1;
        while (file_id <= through) : (file_id += 1) {
            const name = try journal_name(
                self.profile.alloc,
                self.record.session_id,
                file_id,
            );
            defer self.profile.alloc.free(name);
            (try self.state_capability()).delete(.terminal_state, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            if (file_id == std.math.maxInt(u64)) break;
        }
        self.record.journal_cleanup_through = 0;
        try save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        );
    }
};

pub fn checkpoint_load_unavailable_reason(
    err: anyerror,
) ?contracts.ScreenUnavailableReason {
    return switch (err) {
        error.MissingCheckpoint => .missing,
        error.UnsupportedCheckpointSchema => .unsupported_schema,
        error.CheckpointChecksumMismatch,
        error.CheckpointTooLarge,
        error.InvalidCheckpoint,
        error.StreamTooLong,
        => .corrupt,
        else => null,
    };
}

fn is_definitive_recovery_authority_error(err: anyerror) bool {
    return switch (err) {
        error.AuthorityNotFound,
        error.InvalidAuthorityRecord,
        error.HolderProofNotFound,
        error.InvalidHolderProof,
        error.AuthorityRevoked,
        error.SessionPathUnsafe,
        error.StreamTooLong,
        => true,
        else => false,
    };
}

fn facts_from_record(record: Record, session_id: []const u8) contracts.SessionFacts {
    const unread_range: ?contracts.RawRange = if (contracts.compare_raw_cursors(
        record.available_from,
        record.output_cursor,
    ) == .lt and record.available_from.segment == record.output_cursor.segment)
        .{
            .start = record.available_from,
            .end = record.output_cursor,
        }
    else
        null;
    return .{
        .session_id = session_id,
        .lifecycle = record.lifecycle,
        .attention = record.attention,
        .backend = record.backend,
        .model_managed = true,
        .timed_out = record.timed_out,
        .output_cursor = record.output_cursor,
        .unread_range = unread_range,
        .raw_gap = record.raw_gap,
        .screen_recovery = record.screen_recovery,
    };
}

fn cleanup_partial_start(
    alloc: Allocator,
    state: *session_child_store.SessionChildCapability,
    proofs: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) void {
    cleanup_session_artifacts(alloc, state, proofs, session_id);
}

pub const Checkpoint = struct {
    envelope: contracts.CheckpointEnvelope,
    payload: []u8,

    pub fn deinit(self: *Checkpoint, alloc: Allocator) void {
        alloc.free(self.payload);
        self.* = undefined;
    }
};

pub fn checkpoint_reserve_bytes(
    dimensions: contracts.Dimensions,
) error{ InvalidDimensions, CapacityExceeded }!u64 {
    try dimensions.validate();
    const cells = std.math.mul(
        u64,
        dimensions.rows,
        dimensions.columns,
    ) catch return error.CapacityExceeded;
    const cell_bytes = std.math.mul(u64, cells, 16) catch
        return error.CapacityExceeded;
    return std.math.add(u64, cell_bytes, 64 * 1024) catch
        return error.CapacityExceeded;
}

pub fn contiguous_after_checkpoint(
    checkpoint: contracts.CheckpointEnvelope,
    available_from: contracts.RawCursor,
    output_cursor: contracts.RawCursor,
) bool {
    checkpoint.validate_header() catch return false;
    available_from.validate() catch return false;
    output_cursor.validate() catch return false;
    if (contracts.compare_raw_cursors(
        checkpoint.applied_cursor,
        output_cursor,
    ) == .gt) return false;
    return contracts.compare_raw_cursors(
        available_from,
        checkpoint.applied_cursor,
    ) != .gt;
}

fn save_record(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    record: Record,
) !void {
    try record.validate();
    const bytes = try render_json(alloc, record_wire(record));
    defer alloc.free(bytes);
    if (bytes.len > max_record_bytes) return error.TerminalRecordTooLarge;
    const name = try record_name(alloc, record.session_id);
    defer alloc.free(name);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

inline fn failRecord(err: anytype) @TypeOf(err)!Record {
    return @errorCast(failRecordDynamic(err));
}

noinline fn failRecordDynamic(err: anyerror) anyerror!Record {
    return err;
}

fn load_record(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) !Record {
    const name = record_name(alloc, session_id) catch |err|
        return failRecord(err);
    defer alloc.free(name);
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_state,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return failRecord(error.TerminalRecordNotFound),
        else => return failRecord(err),
    };
    defer file.deinit();
    const bytes = file.readToEnd(alloc, max_record_bytes) catch |err| switch (err) {
        error.StreamTooLong => return failRecord(error.TerminalRecordTooLarge),
        else => return failRecord(err),
    };
    defer alloc.free(bytes);
    return parse_record(alloc, bytes) catch |err| return failRecord(err);
}

fn write_owner_catalog_proof(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
    proof: contracts.OwnerCatalogProof,
) !void {
    try proof.validate();
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_proofs,
        name,
        &proof.bytes,
    );
    entry.deinit(alloc);
}

fn read_owner_catalog_proof(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
) !contracts.OwnerCatalogProof {
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_proofs,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.OwnerCatalogProofNotFound,
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, 33);
    defer {
        std.crypto.secureZero(u8, @volatileCast(bytes));
        alloc.free(bytes);
    }
    if (bytes.len != 32) return error.InvalidHolderProof;
    var proof = contracts.OwnerCatalogProof{ .bytes = undefined };
    @memcpy(&proof.bytes, bytes);
    try proof.validate();
    return proof;
}

fn write_owner_catalog_authority(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
    claim: contracts.OwnerCatalogAuthorityClaim,
) !void {
    try claim.validate();
    const bytes = try render_json(alloc, OwnerCatalogAuthorityWire{
        .principal = claim.principal,
        .actor = claim.actor,
        .verifier = owner_catalog_verifier(claim),
    });
    defer alloc.free(bytes);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

fn load_owner_catalog_authority(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
) !std.json.Parsed(OwnerCatalogAuthorityWire) {
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_state,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.OwnerCatalogAuthorityNotFound,
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, max_record_bytes);
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(
        OwnerCatalogAuthorityWire,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAuthorityRecord,
    };
    errdefer parsed.deinit();
    if (parsed.value.schema_version != owner_catalog_authority_schema_version) {
        return error.TerminalAuthorityRetired;
    }
    parsed.value.principal.validate() catch return error.InvalidAuthorityRecord;
    return parsed;
}

fn write_proof(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
    proof: contracts.HolderProof,
) !void {
    try proof.validate();
    const name = try proof_name(alloc, session_id);
    defer alloc.free(name);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_proofs,
        name,
        &proof.bytes,
    );
    entry.deinit(alloc);
}

fn read_proof(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) !contracts.HolderProof {
    const name = try proof_name(alloc, session_id);
    defer alloc.free(name);
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_proofs,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.HolderProofNotFound,
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, 33);
    defer {
        std.crypto.secureZero(u8, @volatileCast(bytes));
        alloc.free(bytes);
    }
    if (bytes.len != 32) return error.InvalidHolderProof;
    var proof = contracts.HolderProof{ .bytes = undefined };
    @memcpy(&proof.bytes, bytes);
    try proof.validate();
    return proof;
}

fn write_authority(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
    grant: contracts.AuthorityGrant,
    proof: contracts.HolderProof,
    revoked: bool,
) !void {
    try grant.validate();
    const bytes = try render_json(alloc, AuthorityWire{
        .session_id = session_id,
        .grant = grant,
        .verifier = proof_verifier(
            proof,
            grant,
        ),
        .revoked = revoked,
    });
    defer alloc.free(bytes);
    const name = try authority_name(alloc, session_id);
    defer alloc.free(name);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

fn load_authority(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) !std.json.Parsed(AuthorityWire) {
    const name = try authority_name(alloc, session_id);
    defer alloc.free(name);
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_state,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.AuthorityNotFound,
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, max_record_bytes);
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(
        AuthorityWire,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAuthorityRecord,
    };
    errdefer parsed.deinit();
    if (parsed.value.schema_version != authority_schema_version) {
        return error.TerminalAuthorityRetired;
    }
    if (!std.mem.eql(u8, parsed.value.session_id, session_id)) {
        return error.InvalidAuthorityRecord;
    }
    parsed.value.grant.validate() catch return error.InvalidAuthorityRecord;
    return parsed;
}

fn validate_recovery_principal(
    record: *const Record,
    authority: *const AuthorityWire,
) error{InvalidAuthorityRecord}!void {
    const principal = authority.grant.principal;
    if (!std.mem.eql(u8, record.session_id, authority.session_id) or
        !std.mem.eql(u8, record.owner_session_id, principal.durable_session_id) or
        !std.mem.eql(u8, record.cwd, principal.cwd) or
        record.backend != principal.backend or
        principal.lifetime != .session or
        !std.Io.Dir.path.isAbsolute(principal.workspace_root))
    {
        return error.InvalidAuthorityRecord;
    }
}

fn validate_recovery_authority(
    record: *const Record,
    authority: *const AuthorityWire,
) error{InvalidAuthorityRecord}!void {
    try validate_recovery_principal(record, authority);
    if (record.authority_generation.value != authority.grant.generation.value or
        record.authority_revoked != authority.revoked)
    {
        return error.InvalidAuthorityRecord;
    }
}

fn closeFailureAt(profile: *ProfileStore, point: FailurePoint) bool {
    return profile.options.fail_at == point;
}

fn write_close_transaction(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
    transaction: CloseTransaction,
) !void {
    try transaction.validate();
    const bytes = try render_json(alloc, transaction);
    defer alloc.free(bytes);
    if (bytes.len > max_event_bytes) return error.CloseTransactionTooLarge;
    const name = try close_transaction_name(alloc, session_id);
    defer alloc.free(name);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

fn load_close_transaction(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) !?std.json.Parsed(CloseTransaction) {
    const name = try close_transaction_name(alloc, session_id);
    defer alloc.free(name);
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_state,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, max_event_bytes);
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(
        CloseTransaction,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCloseTransaction,
    };
    errdefer parsed.deinit();
    parsed.value.validate() catch return error.InvalidCloseTransaction;
    return parsed;
}

fn delete_close_transaction(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) !void {
    const name = try close_transaction_name(alloc, session_id);
    defer alloc.free(name);
    capability.delete(.terminal_state, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn encode_checkpoint(
    alloc: Allocator,
    envelope: contracts.CheckpointEnvelope,
    payload: []const u8,
) ![]u8 {
    try envelope.validate(payload);
    const total = std.math.add(
        usize,
        checkpoint_header_bytes,
        payload.len,
    ) catch return error.CheckpointTooLarge;
    const bytes = try alloc.alloc(u8, total);
    errdefer alloc.free(bytes);
    @memcpy(bytes[0..4], checkpoint_magic);
    std.mem.writeInt(u16, bytes[4..6], checkpoint_schema_version, .little);
    std.mem.writeInt(u16, bytes[6..8], envelope.engine_schema_revision, .little);
    std.mem.writeInt(u64, bytes[8..16], envelope.applied_cursor.segment, .little);
    std.mem.writeInt(u64, bytes[16..24], envelope.applied_cursor.offset, .little);
    std.mem.writeInt(u32, bytes[24..28], envelope.payload_len, .little);
    @memcpy(bytes[28..60], &envelope.checksum);
    @memcpy(bytes[checkpoint_header_bytes..], payload);
    return bytes;
}

fn decode_checkpoint(alloc: Allocator, bytes: []const u8) !Checkpoint {
    if (bytes.len < checkpoint_header_bytes or
        !std.mem.eql(u8, bytes[0..4], checkpoint_magic))
    {
        return error.InvalidCheckpoint;
    }
    const schema_version = std.mem.readInt(u16, bytes[4..6], .little);
    if (schema_version != checkpoint_schema_version) {
        return error.UnsupportedCheckpointSchema;
    }
    const engine_revision = std.mem.readInt(u16, bytes[6..8], .little);
    const payload_len = std.mem.readInt(u32, bytes[24..28], .little);
    if (payload_len > contracts.max_checkpoint_payload_bytes) {
        return error.CheckpointTooLarge;
    }
    const expected = std.math.add(
        usize,
        checkpoint_header_bytes,
        payload_len,
    ) catch return error.CheckpointTooLarge;
    if (bytes.len != expected) return error.InvalidCheckpoint;
    var checksum: contracts.CheckpointChecksum = undefined;
    @memcpy(&checksum, bytes[28..60]);
    const envelope = contracts.CheckpointEnvelope{
        .engine_schema_revision = engine_revision,
        .applied_cursor = .{
            .segment = std.mem.readInt(u64, bytes[8..16], .little),
            .offset = std.mem.readInt(u64, bytes[16..24], .little),
        },
        .payload_len = payload_len,
        .checksum = checksum,
    };
    const payload = try alloc.dupe(u8, bytes[checkpoint_header_bytes..]);
    errdefer alloc.free(payload);
    try envelope.validate(payload);
    return .{ .envelope = envelope, .payload = payload };
}

fn checkpoint_envelopes_equal(
    left: contracts.CheckpointEnvelope,
    right: contracts.CheckpointEnvelope,
) bool {
    return left.engine_schema_revision == right.engine_schema_revision and
        contracts.compare_raw_cursors(
            left.applied_cursor,
            right.applied_cursor,
        ) == .eq and
        left.payload_len == right.payload_len and
        std.mem.eql(u8, &left.checksum, &right.checksum);
}

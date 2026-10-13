const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host_contract = @import("../hosts/host.zig");
const native_keychain = @import("../hosts/native_keychain.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");
const session_presence = @import("session_presence.zig");

const Allocator = std.mem.Allocator;

pub const issuer = "https://vercel.com";
pub const client_id_env = "FX_OAUTH_CLIENT_ID";
pub const default_client_id = "cl_zzh5hiOZbwJ9bfqEcYqPIJv3TaPaEYL0";
const e2e_issuer_url_env = "FX_E2E_OAUTH_ISSUER_URL";
pub const auth_file_name = profile_paths.auth_file_name;
const schema_version: i64 = 1;
const max_auth_file_bytes: usize = 64 * 1024;
const expiry_skew_ms: i64 = 60 * 1000;
const mutation_lock_file_name = "auth.lock";
const mutation_lock_deadline_ms: u64 = 2000;
const e2e_lock_contention_file_name = "auth-lock-contention";

const StorageBackend = enum {
    profile_file,
    macos_keychain,
};

const FileState = enum { absent, valid, unusable };
const KeychainState = enum { absent, valid, invalid, unavailable };
const Resolution = enum {
    missing,
    file_migrate,
    file_defer_migration,
    keychain,
    storage_error,
};

const Authority = enum { unresolved, missing, profile_file, keychain };

const KeychainError = Allocator.Error || native_keychain.Error;

const KeychainBackend = struct {
    context: ?*anyopaque = null,
    load_fn: *const fn (?*anyopaque, Allocator) KeychainError!?[]u8,
    store_fn: *const fn (?*anyopaque, []const u8) KeychainError!void,
    delete_fn: *const fn (?*anyopaque, Allocator) KeychainError!bool,
    presence_fn: *const fn (?*anyopaque) native_keychain.Error!host_contract.SecretStorePresence,

    fn load(self: KeychainBackend, alloc: Allocator) KeychainError!?[]u8 {
        return self.load_fn(self.context, alloc);
    }

    fn store(self: KeychainBackend, value: []const u8) KeychainError!void {
        return self.store_fn(self.context, value);
    }

    fn delete(self: KeychainBackend, alloc: Allocator) KeychainError!bool {
        return self.delete_fn(self.context, alloc);
    }

    fn presence(self: KeychainBackend) native_keychain.Error!host_contract.SecretStorePresence {
        return self.presence_fn(self.context);
    }
};

const native_keychain_backend: KeychainBackend = .{
    .load_fn = nativeKeychainLoad,
    .store_fn = nativeKeychainStore,
    .delete_fn = nativeKeychainDelete,
    .presence_fn = nativeKeychainPresence,
};

fn nativeKeychainPresence(_: ?*anyopaque) native_keychain.Error!host_contract.SecretStorePresence {
    return native_keychain.oauthSessionPresence();
}

fn nativeKeychainLoad(_: ?*anyopaque, alloc: Allocator) KeychainError!?[]u8 {
    return native_keychain.loadOAuthSession(alloc);
}

fn nativeKeychainStore(_: ?*anyopaque, value: []const u8) KeychainError!void {
    return native_keychain.storeOAuthSession(value);
}

fn nativeKeychainDelete(_: ?*anyopaque, alloc: Allocator) KeychainError!bool {
    return native_keychain.deleteOAuthSession(alloc);
}

fn selectStorageBackend(os_tag: std.Target.Os.Tag, keychain_disabled: bool) StorageBackend {
    if (os_tag == .macos and !keychain_disabled) return .macos_keychain;
    return .profile_file;
}

fn storageBackend() StorageBackend {
    // A temporary HOME does not isolate the host account's macOS Keychain.
    // Keychain-specific tests inject their backend explicitly.
    if (comptime builtin.is_test) return .profile_file;
    return selectStorageBackend(builtin.target.os.tag, native_keychain.isDisabled());
}

pub fn presence() host_contract.SecretStorePresence {
    const file_presence = session_presence.profileFile(
        auth_file_name,
        max_auth_file_bytes,
    );
    if (storageBackend() == .profile_file or file_presence == .present) {
        return file_presence;
    }
    const keychain_presence = native_keychain.oauthSessionPresence() catch
        return .unavailable;
    if (keychain_presence == .present) return .present;
    if (file_presence == .missing and keychain_presence == .missing) {
        return .missing;
    }
    return .unavailable;
}

pub fn requireSignInStorage() error{CredentialStorageUnavailable}!void {
    const file_exists = try session_presence.requireWritableProfileFile(auth_file_name, mutation_lock_file_name);
    try requireSignInDestination(storageBackend(), file_exists, native_keychain_backend);
}

fn requireSignInDestination(backend: StorageBackend, file_exists: bool, keychain: KeychainBackend) error{CredentialStorageUnavailable}!void {
    if (backend == .profile_file or file_exists) return;
    const available = keychain.presence() catch return error.CredentialStorageUnavailable;
    if (available == .unavailable) return error.CredentialStorageUnavailable;
}

fn selectResolution(file: FileState, keychain: KeychainState) Resolution {
    return switch (file) {
        .valid => if (keychain == .unavailable) .file_defer_migration else .file_migrate,
        .absent => switch (keychain) {
            .absent => .missing,
            .valid => .keychain,
            .invalid, .unavailable => .storage_error,
        },
        .unusable => switch (keychain) {
            .valid => .keychain,
            .absent, .invalid, .unavailable => .storage_error,
        },
    };
}

pub fn refresh_deadline_ms(expires_at_ms: i64) i64 {
    return expires_at_ms -| expiry_skew_ms;
}

const MutationLockProbe = struct {
    fx_dir: std.Io.Dir,
    signaled: bool = false,

    fn tryLock(raw_ctx: ?*anyopaque, file: std.Io.File) anyerror!bool {
        const locked = try file.tryLock(io_mod.getIo(), .exclusive);
        const self: *MutationLockProbe = @ptrCast(@alignCast(raw_ctx.?));
        if (!locked and !self.signaled) {
            signalE2ELockContention(self.fx_dir);
            self.signaled = true;
        }
        return locked;
    }
};

fn signalE2ELockContention(fx_dir: std.Io.Dir) void {
    const enabled = io_mod.getenv("FX_E2E_AUTH_LOCK_CONTENTION") orelse return;
    if (!std.mem.eql(u8, enabled, "1")) return;
    var file = fx_dir.createFile(io_mod.getIo(), e2e_lock_contention_file_name, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    }) catch return;
    defer file.close(io_mod.getIo());
    file.writeStreamingAll(io_mod.getIo(), "contended\n") catch {};
}

const DeleteOutcome = enum {
    deleted,
    missing,
    deleted_not_durable,
};

pub const DeleteResult = struct {
    session_deleted: bool = false,
    local_cleanup_failed: bool = false,
};

pub const Session = struct {
    issuer: []u8,
    client_id: []u8,
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    scope: []u8,
    token_type: []u8,
    team_slug: ?[]u8 = null,
    team_id: ?[]u8 = null,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        alloc.free(self.issuer);
        alloc.free(self.client_id);
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.scope);
        alloc.free(self.token_type);
        if (self.team_slug) |value| alloc.free(value);
        if (self.team_id) |value| alloc.free(value);
        self.* = undefined;
    }

    pub fn expired(self: Session, now_ms: i64) bool {
        return refresh_deadline_ms(self.expires_at_ms) <= now_ms;
    }
};

const FileObservation = union(enum) {
    absent,
    valid: Session,
    unusable,

    fn state(self: FileObservation) FileState {
        return switch (self) {
            .absent => .absent,
            .valid => .valid,
            .unusable => .unusable,
        };
    }

    fn takeSession(self: *FileObservation) ?Session {
        return switch (self.*) {
            .valid => |session| blk: {
                self.* = .absent;
                break :blk session;
            },
            else => null,
        };
    }

    fn deinit(self: *FileObservation, alloc: Allocator) void {
        switch (self.*) {
            .valid => |*session| session.deinit(alloc),
            else => {},
        }
        self.* = .absent;
    }
};

const KeychainObservation = union(enum) {
    absent,
    valid: Session,
    invalid,
    unavailable: KeychainError,

    fn state(self: KeychainObservation) KeychainState {
        return switch (self) {
            .absent => .absent,
            .valid => .valid,
            .invalid => .invalid,
            .unavailable => .unavailable,
        };
    }

    fn takeSession(self: *KeychainObservation) ?Session {
        return switch (self.*) {
            .valid => |session| blk: {
                self.* = .absent;
                break :blk session;
            },
            else => null,
        };
    }

    fn storageError(self: KeychainObservation) (KeychainError || error{
        InvalidOAuthKeychainSession,
        InvalidOAuthStorageState,
    }) {
        return switch (self) {
            .invalid => error.InvalidOAuthKeychainSession,
            .unavailable => |err| err,
            else => error.InvalidOAuthStorageState,
        };
    }

    fn deinit(self: *KeychainObservation, alloc: Allocator) void {
        switch (self.*) {
            .valid => |*session| session.deinit(alloc),
            else => {},
        }
        self.* = .absent;
    }
};

fn observeAuthFile(alloc: Allocator, fx_dir: *std.Io.Dir) !FileObservation {
    var file = fx_dir.openFile(io_mod.getIo(), auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => {
            debug_trace.logf("auth", "session load failed source=file step=open err={s}", .{@errorName(err)});
            return .unusable;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch |err| {
        debug_trace.logf("auth", "session load failed source=file step=stat err={s}", .{@errorName(err)});
        return .unusable;
    };
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "session load failed source=file step=permissions err=InsecureAuthFile", .{});
        return .unusable;
    }

    const bytes = io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "session load failed source=file step=read err={s}", .{@errorName(err)});
            return .unusable;
        },
    };
    defer secret.zeroAndFree(alloc, bytes);
    const session = parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "session load failed source=file step=parse err={s}", .{@errorName(err)});
            return .unusable;
        },
    };
    return .{ .valid = session };
}

fn observeKeychain(alloc: Allocator, keychain: KeychainBackend) !KeychainObservation {
    const maybe_bytes = keychain.load(alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.KeychainItemNotFound => return .absent,
        else => return .{ .unavailable = err },
    };
    const bytes = maybe_bytes orelse return .absent;
    defer secret.zeroAndFree(alloc, bytes);
    if (bytes.len > max_auth_file_bytes) return .invalid;
    const session = parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .invalid,
    };
    return .{ .valid = session };
}

fn publishAndVerifyKeychain(alloc: Allocator, keychain: KeychainBackend, session: Session) !void {
    const bytes = try stringify(alloc, session);
    defer secret.zeroAndFree(alloc, bytes);
    try keychain.store(bytes);
    const persisted = keychain.load(alloc) catch |err| switch (err) {
        error.KeychainItemNotFound => return error.OAuthSessionKeychainWriteMismatch,
        else => return err,
    } orelse return error.OAuthSessionKeychainWriteMismatch;
    defer secret.zeroAndFree(alloc, persisted);
    if (!std.mem.eql(u8, bytes, persisted)) return error.OAuthSessionKeychainWriteMismatch;
}

fn authFileExists(fx_dir: *std.Io.Dir) !bool {
    _ = fx_dir.statFile(io_mod.getIo(), auth_file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub const Mutation = struct {
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,
    backend: StorageBackend,
    keychain: KeychainBackend,
    authority: Authority = .unresolved,

    pub fn requireWritable(self: *Mutation) error{CredentialStorageUnavailable}!void {
        if (self.backend == .profile_file or self.authority == .profile_file) {
            _ = try session_presence.requireWritableInDir(self.fx_dir.dir, auth_file_name);
        }
    }

    pub fn deinit(self: *Mutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Session {
        if (self.backend == .profile_file) {
            self.authority = .profile_file;
            return loadFromDir(alloc, &self.fx_dir.dir);
        }
        return self.loadKeychainResolved(alloc);
    }

    pub fn save(self: *Mutation, alloc: Allocator, session: Session) !void {
        if (self.backend == .macos_keychain) {
            return self.saveKeychainResolved(alloc, session);
        }
        self.authority = .profile_file;
        return self.saveFile(alloc, session);
    }

    fn saveFile(self: *Mutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try io_mod.durableReplaceVerified(alloc, &self.fx_dir, auth_file_name, text);
    }

    pub fn delete(self: *Mutation, alloc: Allocator) !DeleteResult {
        var result: DeleteResult = .{};
        if (self.backend == .macos_keychain) {
            const deleted = self.keychain.delete(alloc) catch blk: {
                result.local_cleanup_failed = true;
                break :blk false;
            };
            result.session_deleted = result.session_deleted or deleted;
        }

        const file_outcome = deleteAuthFile(&self.fx_dir.dir, .{}) catch {
            result.local_cleanup_failed = true;
            return result;
        };
        switch (file_outcome) {
            .missing => {},
            .deleted => result.session_deleted = true,
            .deleted_not_durable => {
                result.session_deleted = true;
                result.local_cleanup_failed = true;
            },
        }
        self.authority = .missing;
        return result;
    }

    fn loadKeychainResolved(self: *Mutation, alloc: Allocator) !?Session {
        var file = try observeAuthFile(alloc, &self.fx_dir.dir);
        defer file.deinit(alloc);
        var keychain = try observeKeychain(alloc, self.keychain);
        defer keychain.deinit(alloc);

        switch (selectResolution(file.state(), keychain.state())) {
            .missing => {
                self.authority = .missing;
                return null;
            },
            .keychain => {
                self.authority = .keychain;
                return keychain.takeSession().?;
            },
            .file_defer_migration => {
                self.authority = .profile_file;
                return file.takeSession().?;
            },
            .file_migrate => {
                var session = file.takeSession().?;
                errdefer session.deinit(alloc);
                const migrated = try self.publishAndCleanup(alloc, session);
                self.authority = if (migrated) .keychain else .profile_file;
                return session;
            },
            .storage_error => return keychain.storageError(),
        }
    }

    fn saveKeychainResolved(self: *Mutation, alloc: Allocator, session: Session) !void {
        if (self.authority == .unresolved) {
            self.authority = if (try authFileExists(&self.fx_dir.dir)) .profile_file else .keychain;
        }

        switch (self.authority) {
            .profile_file => {
                try self.saveFile(alloc, session);
                const migrated = try self.publishAndCleanup(alloc, session);
                if (migrated) self.authority = .keychain;
            },
            .keychain, .missing => {
                try publishAndVerifyKeychain(alloc, self.keychain, session);
                self.authority = .keychain;
            },
            .unresolved => unreachable,
        }
    }

    fn publishAndCleanup(self: *Mutation, alloc: Allocator, session: Session) !bool {
        publishAndVerifyKeychain(alloc, self.keychain, session) catch |err| {
            debug_trace.logf("auth", "session migration deferred step=publish err={s}", .{@errorName(err)});
            return false;
        };

        const outcome = deleteAuthFile(&self.fx_dir.dir, .{}) catch |err| {
            const stat = self.fx_dir.dir.statFile(io_mod.getIo(), auth_file_name, .{}) catch |stat_err| switch (stat_err) {
                error.FileNotFound => return error.OAuthSessionCleanupUncertain,
                else => return stat_err,
            };
            if (stat.kind != .file) return error.OAuthSessionCleanupUncertain;
            debug_trace.logf("auth", "session migration deferred step=delete err={s}", .{@errorName(err)});
            return false;
        };
        return switch (outcome) {
            .deleted => true,
            .missing => blk: {
                try io_mod.syncVerifiedDir(self.fx_dir.dir);
                break :blk true;
            },
            .deleted_not_durable => error.OAuthSessionCleanupUncertain,
        };
    }
};

pub fn configuredClientId() ?[]const u8 {
    if (io_mod.getenv(client_id_env)) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len > 0) return value;
    }
    return if (default_client_id.len == 0) null else default_client_id;
}

pub fn configuredIssuerUrl() ![]const u8 {
    return selectIssuerUrl(io_mod.getenv(e2e_issuer_url_env));
}

pub fn isLoopbackE2EIssuer(url: []const u8) bool {
    return !std.mem.eql(u8, url, issuer) and isLoopbackHttpUrl(url, true);
}

pub fn validateE2EEndpoint(issuer_url: []const u8, endpoint: []const u8) !void {
    if (isLoopbackE2EIssuer(issuer_url) and !isLoopbackHttpUrl(endpoint, false)) {
        return error.InvalidE2EOAuthEndpoint;
    }
}

fn selectIssuerUrl(override: ?[]const u8) ![]const u8 {
    const raw = override orelse return issuer;
    const candidate = std.mem.trimEnd(u8, raw, "/");
    if (!isLoopbackHttpUrl(candidate, true)) return error.InvalidE2EOAuthIssuer;
    return candidate;
}

fn isLoopbackHttpUrl(url: []const u8, require_origin: bool) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        uri.user != null or
        uri.password != null or
        uri.port == null or
        (require_origin and (!uri.path.isEmpty() or uri.query != null or uri.fragment != null)))
    {
        return false;
    }

    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

pub fn load(alloc: Allocator) !?Session {
    const home = io_mod.getenv("HOME") orelse {
        debug_trace.logf("auth", "session load skipped step=home err=HomeNotSet", .{});
        return null;
    };
    if (storageBackend() == .macos_keychain) {
        if (try beginExistingNativeMutation()) |existing| {
            var mutation = existing;
            defer mutation.deinit();
            return mutation.load(alloc);
        }
        return loadKeychainWithoutProfile(alloc);
    }
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("auth", "session load failed step=open_home err={s}", .{@errorName(err)});
        if (err == error.FileNotFound) return null;
        return session_presence.storageError(auth_file_name, err);
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        debug_trace.logf("auth", "session load failed step=open_profile err={s}", .{@errorName(err)});
        if (err == error.FileNotFound) return null;
        return session_presence.storageError(auth_file_name, err);
    };
    defer fx_dir.close(io_mod.getIo());

    return loadFromDir(alloc, &fx_dir);
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir) !?Session {
    var file = fx_dir.openFile(io_mod.getIo(), auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("auth", "session load failed step=open_file err={s}", .{@errorName(err)});
            return session_presence.storageError(auth_file_name, err);
        },
    };
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch |err| return session_presence.storageError(auth_file_name, err);
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "session load failed step=permissions err=InsecureAuthFile", .{});
        return error.InsecureAuthFile;
    }

    const bytes = io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes) catch |err| return session_presence.storageError(auth_file_name, err);
    defer secret.zeroAndFree(alloc, bytes);
    return try parseStoredSession(alloc, bytes);
}

fn parseStoredSession(alloc: Allocator, bytes: []const u8) !Session {
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "session load failed step=parse err={s}", .{@errorName(err)});
            return error.InvalidAuthSession;
        },
    };
}

pub fn saveNewSession(alloc: Allocator, session: Session) !void {
    var mutation = try beginMutation();
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation() !?Mutation {
    if (storageBackend() == .macos_keychain) {
        return @as(?Mutation, beginMutation() catch |err| return session_presence.storageError(auth_file_name, err));
    }
    return beginExistingNativeMutation() catch |err| return session_presence.storageError(auth_file_name, err);
}

fn beginExistingNativeMutation() !?Mutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| return session_presence.storageError(auth_file_name, err),
    };
    defer home_dir.close();

    const fx_dir = openExistingPrivateFxDir(&home_dir) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return session_presence.storageError(auth_file_name, err),
    };
    return @as(?Mutation, try lockMutation(fx_dir));
}

fn loadKeychainWithoutProfile(alloc: Allocator) !?Session {
    var keychain = try observeKeychain(alloc, native_keychain_backend);
    defer keychain.deinit(alloc);

    if (try beginExistingNativeMutation()) |existing| {
        var mutation = existing;
        defer mutation.deinit();
        return mutation.load(alloc);
    }

    return switch (selectResolution(.absent, keychain.state())) {
        .missing => null,
        .keychain => keychain.takeSession().?,
        .storage_error => keychain.storageError(),
        .file_migrate, .file_defer_migration => unreachable,
    };
}

fn beginMutation() !Mutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    const fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    return lockMutation(fx_dir);
}

fn lockMutation(open_fx_dir: io_mod.VerifiedDir) !Mutation {
    var probe = MutationLockProbe{ .fx_dir = open_fx_dir.dir };
    return lockMutationWithOps(open_fx_dir, mutation_lock_deadline_ms, .{
        .ctx = &probe,
        .try_lock = MutationLockProbe.tryLock,
    });
}

fn lockMutationWithOps(
    open_fx_dir: io_mod.VerifiedDir,
    deadline_ms: u64,
    ops: io_mod.LockOps,
) !Mutation {
    return lockMutationWithBackend(
        open_fx_dir,
        deadline_ms,
        ops,
        storageBackend(),
        native_keychain_backend,
    );
}

fn lockMutationWithBackend(
    open_fx_dir: io_mod.VerifiedDir,
    deadline_ms: u64,
    ops: io_mod.LockOps,
    backend: StorageBackend,
    keychain: KeychainBackend,
) !Mutation {
    var fx_dir = open_fx_dir;
    errdefer fx_dir.close();

    var lock = io_mod.acquireTimedAdvisoryLockWithOps(
        &fx_dir,
        mutation_lock_file_name,
        deadline_ms,
        ops,
    ) catch |err| return session_presence.storageError(auth_file_name, err);
    errdefer lock.release();

    return .{
        .fx_dir = fx_dir,
        .lock = lock,
        .backend = backend,
        .keychain = keychain,
    };
}

fn openExistingPrivateFxDir(home_dir: *io_mod.VerifiedDir) !io_mod.VerifiedDir {
    var dir = try home_dir.dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer dir.close(io_mod.getIo());

    const initial_stat = try dir.stat(io_mod.getIo());
    if (initial_stat.kind != .directory) return error.DurablePathUnsafe;
    if (initial_stat.permissions.toMode() & 0o200 == 0) {
        return error.PrivateStatePermissionsUnsupported;
    }
    dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o700)) catch {
        return error.PrivateStatePermissionsUnsupported;
    };
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory) return error.DurablePathUnsafe;
    if (stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
    return .{ .dir = dir };
}

fn deleteAuthFile(fx_dir: *std.Io.Dir, ops: io_mod.DurableOps) !DeleteOutcome {
    fx_dir.deleteFile(io_mod.getIo(), auth_file_name) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    ops.sync_dir(ops.ctx, fx_dir.*) catch return .deleted_not_durable;
    return .deleted;
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidAuthSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidAuthSession;
    const saved_issuer = try requiredString(object, "issuer");
    if (!std.mem.eql(u8, saved_issuer, issuer) and !isLoopbackE2EIssuer(saved_issuer)) {
        return error.InvalidAuthSession;
    }

    const expires_at_ms = try requiredInteger(object, "expires_at_ms");
    const owned_issuer = try alloc.dupe(u8, saved_issuer);
    errdefer alloc.free(owned_issuer);
    const client_id = try dupeRequiredString(alloc, object, "client_id");
    errdefer alloc.free(client_id);
    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(alloc, object, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const scope = try dupeRequiredString(alloc, object, "scope");
    errdefer alloc.free(scope);
    const token_type = try dupeRequiredString(alloc, object, "token_type");
    errdefer alloc.free(token_type);
    const team_slug = try dupeOptionalString(alloc, object, "team_slug");
    errdefer if (team_slug) |value| alloc.free(value);
    const team_id = try dupeOptionalString(alloc, object, "team_id");
    errdefer if (team_id) |value| alloc.free(value);

    return .{
        .issuer = owned_issuer,
        .client_id = client_id,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .scope = scope,
        .token_type = token_type,
        .team_slug = team_slug,
        .team_id = team_id,
    };
}

pub fn stringify(alloc: Allocator, session: Session) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"version\":1");
    try writeField(writer, "issuer", session.issuer);
    try writeField(writer, "client_id", session.client_id);
    try writeField(writer, "access_token", session.access_token);
    try writeField(writer, "refresh_token", session.refresh_token);
    try writer.print(",\"expires_at_ms\":{d}", .{session.expires_at_ms});
    try writeField(writer, "scope", session.scope);
    try writeField(writer, "token_type", session.token_type);
    if (session.team_slug) |value| try writeField(writer, "team_slug", value);
    if (session.team_id) |value| try writeField(writer, "team_id", value);
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn writeField(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.writeAll(",");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(":");
    try std.json.Stringify.value(value, .{}, writer);
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    return alloc.dupe(u8, try requiredString(object, key));
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidAuthSession;
    if (value != .string or value.string.len == 0) return error.InvalidAuthSession;
    return value.string;
}

fn dupeOptionalString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len == 0) return error.InvalidAuthSession;
    return try alloc.dupe(u8, value.string);
}

fn requiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidAuthSession;
    if (value != .integer) return error.InvalidAuthSession;
    return value.integer;
}

const std = @import("std");
const builtin = @import("builtin");
const api_key_validator = @import("api_key_validator.zig");
const auth_transition = @import("auth_transition.zig");
const credentials = @import("credentials.zig");
const chatgpt_oauth = @import("chatgpt_oauth.zig");
const grok_oauth = @import("grok_oauth.zig");
const host = @import("../hosts/host.zig");
const login_flow = @import("login_flow.zig");
const model_provider = @import("../config/model_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_catalog = @import("provider_catalog.zig");
const provider_picker_catalog = @import("provider_picker_catalog.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const SourceSet = std.EnumSet(credentials.Source);

pub const CredentialRefreshMode = enum {
    if_needed,
    force,
};

const credential_source_order = [_]credentials.Source{
    .vercel_oidc_token,
    .ai_gateway_api_key,
    .fx_login,
    .stored_key,
    .chatgpt_subscription,
    .grok_subscription,
};

const SourceProbeFn = *const fn (?*anyopaque, Allocator, credentials.Source) anyerror!bool;
const CredentialLoaderFn = *const fn (?*anyopaque, Allocator, credentials.Source) anyerror!?credentials.Credential;
const StoredKeyStoreFn = *const fn (?*anyopaque, Allocator, []const u8) anyerror!void;

const max_api_key_entry_bytes: usize = 8 * 1024;
const max_api_key_mask_glyphs = provider_picker_catalog.max_key_mask_glyphs;
const max_manual_code_mask_glyphs: usize = 32;
const max_team_query_bytes: usize = 256;

fn sourceLabelOrMissing(source: ?credentials.Source) []const u8 {
    return credentials.sourceLabel(source orelse return "missing");
}

pub const CredentialFailureReason = enum {
    temporary_unavailable,
    invalid_credential,
    invalid_storage,
    persistence_uncertain,
    authority_changed,
};

pub const CredentialFailure = struct {
    source: credentials.Source,
    reason: CredentialFailureReason,

    pub fn retryable(self: CredentialFailure) bool {
        return self.reason == .temporary_unavailable;
    }

    pub fn requiresSignIn(self: CredentialFailure) bool {
        return self.reason == .invalid_credential or self.reason == .persistence_uncertain;
    }
};

pub fn classifyCredentialFailure(
    source: credentials.Source,
    err: anyerror,
) CredentialFailure {
    return .{
        .source = source,
        .reason = switch (err) {
            error.InvalidGrant,
            error.AccessDenied,
            error.ExpiredToken,
            error.InvalidClient,
            error.NoRefreshToken,
            error.CredentialRefreshRejected,
            error.CredentialRefreshUnavailable,
            => .invalid_credential,
            error.InvalidAuthSession,
            error.InvalidOAuthKeychainSession,
            error.InvalidOAuthStorageState,
            error.KeychainItemNotFound,
            error.CredentialStorageUnavailable,
            error.DurablePathUnsafe,
            error.InsecureAuthFile,
            error.StoredKeyUnreadable,
            error.StoredKeyInsecure,
            error.InvalidChatGptAuthSession,
            error.InvalidGrokAuthSession,
            error.KeychainReadFailed,
            error.PrivateStatePermissionsUnsupported,
            error.HomeNotSet,
            error.UserNotSet,
            => .invalid_storage,
            error.KeychainWriteFailed,
            error.OAuthSessionKeychainWriteMismatch,
            error.OAuthSessionCleanupUncertain,
            error.CredentialRefreshPersistenceUncertain,
            error.CredentialPersistenceFailed,
            error.DurableReplacePreRenameFailed,
            error.DurableReplacePostRenameFailed,
            => .persistence_uncertain,
            error.CredentialAuthorityChanged,
            error.SessionChanged,
            error.ChatGptAccountChanged,
            error.GrokAccountChanged,
            => .authority_changed,
            else => .temporary_unavailable,
        },
    };
}

pub const FailureReason = enum {
    credential_refresh_failed,
    http_unauthorized,
};

pub const FailureSnapshot = struct {
    source: credentials.Source,
    reason: FailureReason,
    http_status: ?std.http.Status = null,

    pub fn fromHttp(status: std.http.Status, source: ?credentials.Source) ?FailureSnapshot {
        if (status != .unauthorized) return null;
        return .{
            .source = source orelse return null,
            .reason = .http_unauthorized,
            .http_status = status,
        };
    }

    /// Returns owned, detail-free text. The caller owns the returned slice.
    pub fn renderText(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("{s} {s}", .{
            credentials.sourceLabel(self.source),
            switch (self.reason) {
                .credential_refresh_failed => "credential refresh failed",
                .http_unauthorized => "authentication failed",
            },
        });
        if (self.http_status) |status| {
            try out.writer.print(" · HTTP {d}", .{@backingInt(status)});
        }
        return try out.toOwnedSlice();
    }

    /// Returns owned JSON containing only the shared auth-failure facts.
    pub fn renderJson(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }

    pub fn writeJson(self: FailureSnapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"source\":");
        try std.json.Stringify.value(credentials.sourceLabel(self.source), .{}, writer);
        try writer.writeAll(",\"reason\":");
        try std.json.Stringify.value(@tagName(self.reason), .{}, writer);
        if (self.http_status) |status| {
            try writer.print(",\"http_status\":{d}", .{@backingInt(status)});
        }
        try writer.writeByte('}');
    }
};

/// Process-local proof that a request-path credential load succeeded recently.
/// The request path's defensive `.if_needed` reload reads the OS secret store
/// (tens of milliseconds on macOS); when admission or an earlier step just
/// proved the credential, repeating that read only adds latency. A stale skip
/// costs one unauthorized response, which the existing force-refresh replay
/// already recovers from.
const request_path_verified_window_ms: u32 = 30_000;
const source_none: u8 = std.math.maxInt(u8);
// u32 keeps the stamp atomic-loadable on 32-bit targets; wrapping subtraction
// keeps window comparisons correct across the ~49 day wrap.
var request_path_verified_ms = std.atomic.Value(u32).init(0);
var request_path_verified_source = std.atomic.Value(u8).init(source_none);

fn stampNowMs() u32 {
    return @truncate(@as(u64, @bitCast(io_mod.milliTimestamp())));
}

fn noteRequestPathCredentialVerified(source: credentials.Source) void {
    request_path_verified_source.store(@backingInt(source), .seq_cst);
    request_path_verified_ms.store(stampNowMs(), .seq_cst);
}

/// True when one refreshable source's credential was loaded successfully within
/// the skip window. Request-path callers use this to bypass a redundant
/// defensive reload; admission and forced refreshes must not consult it.
pub fn requestPathCredentialVerifiedRecently(source: credentials.Source) bool {
    const verified_ms = request_path_verified_ms.load(.seq_cst);
    if (verified_ms == 0) return false;
    if (request_path_verified_source.load(.seq_cst) != @backingInt(source)) return false;
    return stampNowMs() -% verified_ms < request_path_verified_window_ms;
}

/// Returns one complete owned credential after a provider-specific refresh.
/// The caller owns every field and must call `Credential.deinit`.
pub fn refreshCredentialForAccount(
    transport: oauth_transport.Provider,
    alloc: Allocator,
    source: credentials.Source,
    mode: CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?credentials.Credential {
    if (!credentials.sourceRefreshable(source)) return null;

    var credential = (loadCredentialForRefresh(alloc, transport, source, mode) catch |err| {
        debug_trace.logf(
            "auth",
            "credential refresh provider failed source={t} mode={t} err={s}",
            .{ source, mode, @errorName(err) },
        );
        return err;
    }) orelse return null;
    errdefer credential.deinit(alloc);
    if (expected_account_id) |expected| {
        const actual = credential.accountId() orelse {
            debug_trace.logf("auth", "credential refresh rejected stage=account_missing source={t}", .{source});
            return error.ChatGptAccountChanged;
        };
        if (!std.mem.eql(u8, expected, actual)) {
            debug_trace.logf("auth", "credential refresh rejected stage=account_changed source={t}", .{source});
            return error.ChatGptAccountChanged;
        }
    }
    noteRequestPathCredentialVerified(source);
    return credential;
}

fn loadCredentialForRefresh(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    source: credentials.Source,
    mode: CredentialRefreshMode,
) !?credentials.Credential {
    return switch (source) {
        .fx_login => switch (mode) {
            .if_needed => credentials.loadFxLoginCredential(alloc, transport),
            .force => credentials.refreshFxLoginCredential(alloc, transport),
        },
        .chatgpt_subscription => switch (mode) {
            .if_needed => credentials.loadSource(alloc, transport, host.unavailable_secret_store, source),
            .force => credentials.refreshChatGptCredential(alloc, transport),
        },
        .grok_subscription => switch (mode) {
            .if_needed => credentials.loadSource(alloc, transport, host.unavailable_secret_store, source),
            .force => credentials.refreshGrokCredential(alloc, transport),
        },
        else => null,
    };
}

pub const CredentialPreparationError = Allocator.Error || error{
    CredentialStorageUnavailable,
    CredentialTemporarilyUnavailable,
    CredentialRefreshPersistenceUncertain,
    CredentialAuthorityChanged,
};

/// Resolves and refreshes one provider credential. The returned value is owned
/// by the caller and must be released with `Credential.deinit`.
/// Null means authentication is needed; storage, transport and authority
/// failures stay errors. Non-null `preferred` is an exact Gateway source.
pub fn prepareCredential(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    provider: model_provider.ProviderId,
    preferred: ?credentials.Source,
) CredentialPreparationError!?credentials.Credential {
    var resolution = credentials.resolveForProvider(
        alloc,
        transport,
        secret_store,
        .refresh_if_needed,
        provider,
        preferred,
    ) catch |err| failure: {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf(
            "auth",
            "credential preparation failed provider={t} source={s} err={s}",
            .{
                provider,
                if (requestedSource(provider, preferred)) |source| @tagName(source) else "automatic",
                @errorName(err),
            },
        );
        break :failure credentials.Resolution{ .failure = .{
            .source = requestedSource(provider, preferred) orelse .fx_login,
            .err = err,
        } };
    };
    return prepareResolvedCredential(
        alloc,
        provider,
        io_mod.milliTimestamp(),
        &resolution,
    );
}

fn prepareResolvedCredential(
    alloc: Allocator,
    provider: model_provider.ProviderId,
    now_ms: i64,
    resolution: *credentials.Resolution,
) CredentialPreparationError!?credentials.Credential {
    var credential = resolution.credential orelse {
        if (resolution.failure) |failure| {
            if (preparationError(classifyCredentialFailure(failure.source, failure.err))) |err| return err;
            return null;
        }
        if (resolution.fx_login_status == .unavailable or resolution.stored_key_status == .unavailable) {
            return error.CredentialStorageUnavailable;
        }
        return null;
    };
    resolution.credential = null;

    const blocked = (credential.token.len == 0 and !(provider == .configured and credential.source == .configured)) or
        !model_provider.authorizesCredential(provider, credential.source) or
        credential.needsRefreshAt(now_ms) or
        (credential.source == .fx_login and
            (credential.gatewayTeam() == null or
                !types.validGatewayTeam(credential.gatewayTeam().?))) or
        ((provider == .codex or provider == .grok) and
            (credential.accountId() == null or
                !types.validCredentialAccountId(credential.accountId().?)));

    if (blocked) {
        credential.deinit(alloc);
        return null;
    }
    if (credentials.sourceRefreshable(credential.source)) {
        noteRequestPathCredentialVerified(credential.source);
    }
    return credential;
}

pub fn requestedSource(
    provider: model_provider.ProviderId,
    preferred: ?credentials.Source,
) ?credentials.Source {
    if (provider != .gateway) return provider_catalog.find(provider).login_source;
    return if (model_provider.authorizesCredential(provider, preferred)) preferred else null;
}

pub fn preparationError(failure: CredentialFailure) ?CredentialPreparationError {
    return switch (failure.reason) {
        .invalid_credential => null,
        .invalid_storage => error.CredentialStorageUnavailable,
        .temporary_unavailable => error.CredentialTemporarilyUnavailable,
        .persistence_uncertain => error.CredentialRefreshPersistenceUncertain,
        .authority_changed => error.CredentialAuthorityChanged,
    };
}

pub fn preparationFailureNotice(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.CredentialStorageUnavailable => "Saved credential storage is unavailable. Check the saved credential, then retry.",
        error.CredentialTemporarilyUnavailable => "Credential refresh is temporarily unavailable. Retry shortly.",
        error.CredentialRefreshPersistenceUncertain => "Credential could not be saved. Check authentication storage before signing in again.",
        error.CredentialAuthorityChanged => "The credential account or team changed. Review authentication before retrying.",
        else => null,
    };
}

/// Returns an owned, secret-free explanation shared by activation surfaces.
pub fn preparationFailureText(alloc: Allocator, provider: model_provider.ProviderId, err: anyerror) ![]u8 {
    const label = provider_catalog.label(provider);
    const failure = classifyCredentialFailure(provider_catalog.find(provider).login_source, err);
    const normalized = preparationError(failure) orelse return alloc.print("{s} requires a new sign-in.", .{label});
    return alloc.print("{s}: {s}", .{ label, preparationFailureNotice(normalized).? });
}

pub const AcquisitionAction = enum {
    connections,
    login,
    chatgpt_login,
    grok_login,
    setup,
    change_team,
    switch_credential,
    switch_provider,
    /// Clears a remembered choice so resolution returns to plain precedence.
    /// Without it the only way back would be editing settings.json by hand.
    automatic,
};

pub const PickerStage = enum {
    root,
    connections,
    provider,
    sign_in,
    api_key,
    change_team,
    switch_credential,
};

pub const ApiKeySaveStart = enum {
    started,
    /// Nothing typed, so Enter is a no-op the user already understands.
    empty,
    /// A previous save is still in flight. The entered key is discarded rather
    /// than queued, so the caller must say so instead of failing silently.
    busy,
};

pub const ApiKeySaveResult = union(enum) {
    empty,
    saved: bool,
    gateway_refused,
    gateway_unavailable,
    store_failed,
    reload_failed,
};

/// The save does a gateway round trip and a key-store write, either of which can
/// take seconds. It runs on a worker so the event loop keeps drawing; the worker
/// performs I/O only and hands the loaded credential back for the main thread to
/// adopt, keeping `selected_credential` single-threaded.
pub const ApiKeySaveOutcome = union(enum) {
    gateway_refused,
    gateway_unavailable,
    store_failed,
    reload_failed,
    loaded: credentials.Credential,

    pub fn deinit(self: *ApiKeySaveOutcome, alloc: Allocator) void {
        switch (self.*) {
            .loaded => |*credential| credential.deinit(alloc),
            else => {},
        }
        self.* = .reload_failed;
    }
};

const ApiKeySaveDeps = struct {
    ctx: ?*anyopaque = null,
    validator: api_key_validator.Provider = api_key_validator.unavailable_provider,
    store: StoredKeyStoreFn = storeUnavailableSecret,
    loader: CredentialLoaderFn = loadCredentialSource,
};

/// The whole save sequence with no runtime state, so outcome behaviour can be
/// tested synchronously while the worker owns only threading.
fn performApiKeySave(alloc: Allocator, key: []const u8, deps: ApiKeySaveDeps) ApiKeySaveOutcome {
    switch (deps.validator.validate(alloc, key)) {
        .accepted => {},
        .refused => return .gateway_refused,
        .unavailable => return .gateway_unavailable,
    }
    deps.store(deps.ctx, alloc, key) catch |err| {
        debug_trace.logf("auth", "api key save failed step=store err={s}", .{@errorName(err)});
        return .store_failed;
    };
    const loaded = deps.loader(deps.ctx, alloc, .stored_key) catch |err| {
        debug_trace.logf("auth", "api key save failed step=reload err={s}", .{@errorName(err)});
        return .reload_failed;
    };
    const credential = loaded orelse return .reload_failed;
    if (credential.source != .stored_key) {
        var wrong = credential;
        wrong.deinit(alloc);
        return .reload_failed;
    }
    return .{ .loaded = credential };
}

const ApiKeySaveRuntime = struct {
    const Self = @This();

    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    running: bool = false,
    /// Owned for the worker's lifetime and zeroed by it, so the entry stage can
    /// drop its own buffer the moment the save starts.
    key: std.ArrayList(u8) = .empty,
    outcome: ?ApiKeySaveOutcome = null,
    deps: ApiKeySaveDeps = .{},

    fn start(self: *Self, alloc: Allocator, key: std.ArrayList(u8), deps: ApiKeySaveDeps) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running or self.thread != null) {
            self.mutex.unlock(io_mod.getIo());
            var rejected = key;
            secret.zeroAndFree(alloc, rejected.allocatedSlice());
            return false;
        }
        self.running = true;
        self.key = key;
        self.deps = deps;
        self.mutex.unlock(io_mod.getIo());

        self.thread = std.Thread.spawn(.{}, workerMain, .{ self, alloc }) catch {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.running = false;
            var abandoned = self.key;
            self.key = .empty;
            self.mutex.unlock(io_mod.getIo());
            secret.zeroAndFree(alloc, abandoned.allocatedSlice());
            debug_trace.logf("auth", "api key save worker failed to spawn", .{});
            return false;
        };
        return true;
    }

    fn workerMain(self: *Self, alloc: Allocator) void {
        const result = performApiKeySave(alloc, self.key.items, self.deps);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var spent = self.key;
        self.key = .empty;
        secret.zeroAndFree(alloc, spent.allocatedSlice());
        self.outcome = result;
        self.running = false;
    }

    /// Returns the finished outcome once, joining the worker first. Ownership of a
    /// loaded credential passes to the caller.
    fn take(self: *Self, alloc: Allocator) ?ApiKeySaveOutcome {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running) {
            self.mutex.unlock(io_mod.getIo());
            return null;
        }
        const thread = self.thread;
        self.thread = null;
        const outcome = self.outcome;
        self.outcome = null;
        self.mutex.unlock(io_mod.getIo());

        if (thread) |handle| handle.join();
        _ = alloc;
        return outcome;
    }

    fn isSaving(self: *const Self) bool {
        const mutable = @constCast(self);
        mutable.mutex.lockUncancelable(io_mod.getIo());
        defer mutable.mutex.unlock(io_mod.getIo());
        return self.running;
    }

    fn deinit(self: *Self, alloc: Allocator) void {
        const thread = self.thread;
        self.thread = null;
        if (thread) |handle| handle.join();
        if (self.outcome) |*outcome| outcome.deinit(alloc);
        self.outcome = null;
        var spent = self.key;
        self.key = .empty;
        secret.zeroAndFree(alloc, spent.allocatedSlice());
        self.running = false;
    }
};

pub const InventoryRefreshDestination = enum {
    auth_picker,
    provider_picker_login,
    provider_picker_command,
};

pub const InventoryRefreshAction = struct {
    provider: model_provider.ProviderId,
    destination: InventoryRefreshDestination = .auth_picker,
};

pub const InventoryRefreshStart = enum {
    started,
    busy,
    failed,
};

pub const InventoryRefreshResult = union(enum) {
    ready: InventoryRefreshAction,
    failed: InventoryRefreshAction,
};

const InventoryRefreshDeps = struct {
    ctx: ?*anyopaque,
    probe: SourceProbeFn,
};

const SourceInventory = struct {
    available: SourceSet = .empty,
    unavailable: SourceSet = .empty,

    fn detect(alloc: Allocator, ctx: ?*anyopaque, probe: SourceProbeFn) !SourceInventory {
        var inventory: SourceInventory = .{};
        for (credential_source_order) |source| {
            const present = probe(ctx, alloc, source) catch |err| switch (err) {
                error.CredentialStorageUnavailable => {
                    debug_trace.logf("auth", "inventory source unavailable source={t}", .{source});
                    inventory.unavailable.insert(source);
                    continue;
                },
                else => return err,
            };
            if (present) inventory.available.insert(source);
        }
        return inventory;
    }
};

pub const PromptCredentialRefreshStart = enum {
    not_needed,
    started,
    pending,
    failed,
};

pub const PromptCredentialRefreshPoll = union(enum) {
    idle,
    pending,
    ready: credentials.Credential,
    failed: struct {
        source: credentials.Source,
        err: anyerror,
    },

    pub fn deinit(self: *PromptCredentialRefreshPoll) void {
        switch (self.*) {
            .ready => |*credential| credential.deinit(std.heap.c_allocator),
            .idle, .pending, .failed => {},
        }
        self.* = .idle;
    }
};

const PromptCredentialRefreshTask = struct {
    transport: oauth_transport.Provider,
    source: credentials.Source,
    expected_account_id: ?[]u8,
    thread: ?std.Thread = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    credential: ?credentials.Credential = null,
    failure: ?anyerror = null,

    fn start(
        transport: oauth_transport.Provider,
        source: credentials.Source,
        expected_account_id: ?[]const u8,
    ) !*PromptCredentialRefreshTask {
        const alloc = std.heap.c_allocator;
        const task = try alloc.create(PromptCredentialRefreshTask);
        errdefer alloc.destroy(task);
        const owned_account_id = if (expected_account_id) |account_id|
            try alloc.dupe(u8, account_id)
        else
            null;
        errdefer if (owned_account_id) |account_id| alloc.free(account_id);
        task.* = .{
            .transport = transport,
            .source = source,
            .expected_account_id = owned_account_id,
        };
        task.thread = try std.Thread.spawn(.{}, workerMain, .{task});
        return task;
    }

    fn workerMain(self: *PromptCredentialRefreshTask) void {
        self.credential = refreshCredentialForAccount(
            self.cancellableTransport(),
            std.heap.c_allocator,
            self.source,
            .if_needed,
            self.expected_account_id,
        ) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        if (self.credential == null) self.failure = error.CredentialRefreshUnavailable;
        self.done.store(true, .release);
    }

    fn cancellableTransport(self: *PromptCredentialRefreshTask) oauth_transport.Provider {
        return .{
            .context = self,
            .execute_fn = executeCancellable,
        };
    }

    fn executeCancellable(
        raw: ?*anyopaque,
        alloc: Allocator,
        request: oauth_transport.Request,
    ) !oauth_transport.Response {
        const self: *PromptCredentialRefreshTask = @ptrCast(@alignCast(raw.?));
        var bounded = request;
        bounded.cancel_flag = &self.cancel_requested;
        return self.transport.execute(alloc, bounded);
    }

    fn poll(self: *const PromptCredentialRefreshTask) bool {
        return self.done.load(.acquire);
    }

    fn takeResult(self: *PromptCredentialRefreshTask) PromptCredentialRefreshPoll {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        const result: PromptCredentialRefreshPoll = if (self.credential) |credential|
            .{ .ready = credential }
        else
            .{ .failed = .{
                .source = self.source,
                .err = self.failure orelse error.CredentialRefreshUnavailable,
            } };
        self.credential = null;
        self.destroy();
        return result;
    }

    fn deinit(self: *PromptCredentialRefreshTask) void {
        self.cancel_requested.store(true, .seq_cst);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.credential) |*credential| credential.deinit(std.heap.c_allocator);
        self.credential = null;
        self.destroy();
    }

    fn destroy(self: *PromptCredentialRefreshTask) void {
        const alloc = std.heap.c_allocator;
        if (self.expected_account_id) |account_id| alloc.free(account_id);
        self.expected_account_id = null;
        alloc.destroy(self);
    }
};

/// The launch credential lookup an interactive session resolves after its
/// first frame instead of before it.
pub const StartupCredentialRequest = struct {
    provider: model_provider.ProviderId,
    preferred: ?credentials.Source,
};

pub const StartupCredentialOutcome = union(enum) {
    /// The credential, when present, is owned by `std.heap.c_allocator`.
    resolved: credentials.Resolution,
    failed: anyerror,

    pub fn deinit(self: *StartupCredentialOutcome) void {
        switch (self.*) {
            .resolved => |*resolution| if (resolution.credential) |*credential| {
                credential.deinit(std.heap.c_allocator);
                resolution.credential = null;
            },
            .failed => {},
        }
    }
};

/// Runs the launch credential resolution on a worker so the first frame does
/// not wait for Keychain reads. Only the worker writes `outcome`; the main
/// thread reads it after the release/acquire completion and join.
const StartupCredentialTask = struct {
    secret_store: host.SecretStore,
    request: StartupCredentialRequest,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    outcome: StartupCredentialOutcome = .{ .resolved = .{} },

    fn start(secret_store: host.SecretStore, request: StartupCredentialRequest) !*StartupCredentialTask {
        const alloc = std.heap.c_allocator;
        const task = try alloc.create(StartupCredentialTask);
        errdefer alloc.destroy(task);
        task.* = .{ .secret_store = secret_store, .request = request };
        task.thread = try std.Thread.spawn(.{}, workerMain, .{task});
        return task;
    }

    fn workerMain(self: *StartupCredentialTask) void {
        defer self.done.store(true, .release);
        // Matches the blocking launch path: stored credentials only, no network.
        const resolution = credentials.resolveForProvider(
            std.heap.c_allocator,
            oauth_transport.unavailable_provider,
            self.secret_store,
            .stored,
            self.request.provider,
            self.request.preferred,
        ) catch |err| {
            self.outcome = .{ .failed = err };
            return;
        };
        self.outcome = .{ .resolved = resolution };
    }

    fn takeOutcome(self: *StartupCredentialTask) StartupCredentialOutcome {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        const outcome = self.outcome;
        self.outcome = .{ .resolved = .{} };
        std.heap.c_allocator.destroy(self);
        return outcome;
    }

    /// Waits for the worker: a Keychain read cannot be interrupted, so this
    /// joins the same way an abandoned prompt credential refresh does.
    fn deinit(self: *StartupCredentialTask) void {
        var outcome = self.takeOutcome();
        outcome.deinit();
    }
};

pub const ProviderPreparationIntent = union(enum) {
    provider: struct {
        target: model_provider.ProviderId,
        allow_login: bool,
        origin: auth_transition.ProviderSwitchIntent,
        fallback: ?model_provider.ProviderId = null,
    },
    team: struct {
        index: usize,
        activate_gateway: bool,
    },
};

pub const ProviderPreparationInput = struct {
    intent: ProviderPreparationIntent,
    catalog_provider: model_catalog.Provider,
    models_path: []const u8,
    preferred_source: ?credentials.Source = null,
    primary_model: ?[]const u8 = null,
    preferred_model: ?[]const u8 = null,
    candidate: ?credentials.Credential = null,

    pub fn target(self: ProviderPreparationInput) model_provider.ProviderId {
        return switch (self.intent) {
            .provider => |request| request.target,
            .team => .gateway,
        };
    }
};

/// Owns the preparation inputs and outcome until the event loop consumes it.
/// Provider capabilities must outlive the task. Only the worker writes results;
/// the main thread reads them after the release/acquire completion and join.
pub const ProviderPreparation = struct {
    alloc: Allocator,
    input: ProviderPreparationInput,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    host_managed: bool,
    thread: ?std.Thread = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    credential: ?credentials.Credential = null,
    catalog: ?model_catalog.ProviderResult = null,
    failure: ?anyerror = null,

    fn start(alloc: Allocator, runtime: *const Runtime, input: ProviderPreparationInput) !*ProviderPreparation {
        const self = try alloc.create(ProviderPreparation);
        self.* = .{
            .alloc = alloc,
            .input = input,
            .transport = runtime.oauth_transport,
            .secret_store = runtime.secret_store,
            .host_managed = runtime.isHostManaged(),
        };
        self.input.primary_model = null;
        self.input.preferred_model = null;
        self.input.candidate = null;
        self.input.models_path = "";
        errdefer self.deinit();
        self.input.models_path = try alloc.dupe(u8, input.models_path);
        if (input.primary_model) |value| self.input.primary_model = try alloc.dupe(u8, value);
        if (input.preferred_model) |value| self.input.preferred_model = try alloc.dupe(u8, value);
        if (input.candidate) |candidate| self.input.candidate = try candidate.clone(alloc);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *ProviderPreparation) void {
        defer self.done.store(true, .release);
        if (self.cancel_requested.load(.seq_cst)) return;
        if (self.input.candidate) |candidate| {
            self.credential = candidate;
            self.input.candidate = null;
        } else if (!self.host_managed) {
            self.credential = prepareCredential(
                self.alloc,
                .{ .context = self, .execute_fn = executeCancellable },
                self.secret_store,
                self.input.target(),
                self.input.preferred_source,
            ) catch |err| {
                self.failure = err;
                return;
            };
            if (self.credential == null) return;
        }
        if (self.cancel_requested.load(.seq_cst)) return;
        const access: credentials.CatalogAccess = if (self.host_managed)
            .host_managed
        else
            credentials.catalogAccessForCredentialAndAccount(
                self.credential.?.source,
                self.credential.?.token,
                self.credential.?.gatewayTeam(),
                self.credential.?.accountId(),
            );
        self.catalog = self.input.catalog_provider.fetch(self.alloc, .{
            .access = access,
            .endpoint = self.input.models_path,
            .cancel_flag = &self.cancel_requested,
            .view = .picker,
        }) catch |err| {
            self.failure = err;
            return;
        };
    }

    fn executeCancellable(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
        const self: *ProviderPreparation = @ptrCast(@alignCast(raw.?));
        var bounded = request;
        bounded.cancel_flag = &self.cancel_requested;
        return self.transport.execute(alloc, bounded);
    }

    pub fn requestCancel(self: *ProviderPreparation) void {
        if (!self.cancel_requested.swap(true, .seq_cst)) {
            debug_trace.logf("auth", "provider preparation cancelled target={t}", .{self.input.target()});
        }
    }

    pub fn deinit(self: *ProviderPreparation) void {
        if (self.thread) |thread| {
            self.requestCancel();
            thread.join();
        }
        if (self.credential) |*credential| credential.deinit(self.alloc);
        if (self.input.candidate) |*credential| credential.deinit(self.alloc);
        if (self.catalog) |*result| switch (result.*) {
            .catalog => |*catalog| model_catalog.freeModelCatalog(self.alloc, catalog),
            .failure => {},
        };
        if (self.input.primary_model) |value| self.alloc.free(value);
        if (self.input.preferred_model) |value| self.alloc.free(value);
        self.alloc.free(self.input.models_path);
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const InventoryRefreshTask = struct {
    alloc: Allocator,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    action: InventoryRefreshAction,
    deps: InventoryRefreshDeps,
    inventory: ?SourceInventory = null,
    failure: ?anyerror = null,

    fn start(
        alloc: Allocator,
        action: InventoryRefreshAction,
        deps: InventoryRefreshDeps,
    ) !*InventoryRefreshTask {
        const task = try alloc.create(InventoryRefreshTask);
        task.* = .{
            .alloc = alloc,
            .action = action,
            .deps = deps,
        };
        task.thread = std.Thread.spawn(.{}, workerMain, .{task}) catch |err| {
            alloc.destroy(task);
            return err;
        };
        return task;
    }

    fn workerMain(self: *InventoryRefreshTask) void {
        self.inventory = SourceInventory.detect(self.alloc, self.deps.ctx, self.deps.probe) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        self.done.store(true, .release);
    }

    fn deinit(self: *InventoryRefreshTask) void {
        if (self.thread) |thread| thread.join();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const ApiKeyExitReason = enum {
    cancel,
    saved,
    screen_replacement,
    runtime_deinit,
};

const ManualCodeClearReason = enum {
    cancel,
    submitted,
    screen_replacement,
    runtime_deinit,
};

pub const Choice = union(enum) {
    provider: model_provider.ProviderId,
    source: credentials.Source,
    action: AcquisitionAction,
    team: usize,

    pub fn eql(self: Choice, other: Choice) bool {
        return switch (self) {
            .provider => |provider| switch (other) {
                .provider => |other_provider| provider.eql(other_provider),
                .source, .action, .team => false,
            },
            .source => |source| switch (other) {
                .source => |other_source| source == other_source,
                .provider, .action, .team => false,
            },
            .action => |action| switch (other) {
                .provider, .source, .team => false,
                .action => |other_action| action == other_action,
            },
            .team => |team| switch (other) {
                .provider, .source, .action => false,
                .team => |other_team| team == other_team,
            },
        };
    }
};

pub const PickerView = struct {
    active: bool,
    available_sources: SourceSet,
    unavailable_sources: SourceSet = .empty,
    selected_choice: ?Choice,
    active_source: ?credentials.Source,
    active_provider: model_provider.ProviderId = .gateway,
    include_skip: bool,
    stage: PickerStage = .root,
    fx_login_session_available: bool = false,
    teams: []const login_flow.Team = &.{},
    current_team: ?[]const u8 = null,
    team_query: []const u8 = &.{},
    sign_in: login_flow.SignInSnapshot = .{},
    sign_in_source: credentials.Source = .fx_login,
    sign_in_code_visible: bool = false,
    sign_in_code_mask_count: usize = 0,
    api_key_mask_count: usize = 0,
    api_key_inline: bool = false,

    pub fn activeSourceLabel(self: PickerView) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn choiceCount(self: PickerView) usize {
        return switch (self.stage) {
            .root => if (self.include_skip)
                connectionChoiceCount()
            else
                4,
            .connections => connectionChoiceCount(),
            .provider => 3,
            .sign_in, .api_key => 0,
            .change_team => blk: {
                var count: usize = 0;
                for (self.teams) |team| {
                    if (teamMatchesQuery(team, self.team_query)) count += 1;
                }
                break :blk count;
            },
            .switch_credential => gatewaySourceCount(self.available_sources) + 1,
        };
    }

    pub fn choiceAt(self: PickerView, index: usize) ?Choice {
        return switch (self.stage) {
            .root => if (self.include_skip) connectionChoiceAt(index) else switch (index) {
                0 => .{ .action = .connections },
                1 => .{ .action = .switch_provider },
                2 => .{ .action = .change_team },
                3 => .{ .action = .switch_credential },
                else => null,
            },
            .connections => connectionChoiceAt(index),
            .provider => switch (index) {
                0 => .{ .provider = .gateway },
                1 => .{ .provider = .codex },
                2 => .{ .provider = .grok },
                else => null,
            },
            .sign_in, .api_key => null,
            .change_team => blk: {
                var visible_index: usize = 0;
                for (self.teams, 0..) |team, team_index| {
                    if (!teamMatchesQuery(team, self.team_query)) continue;
                    if (visible_index == index) break :blk .{ .team = team_index };
                    visible_index += 1;
                }
                break :blk null;
            },
            .switch_credential => if (index < gatewaySourceCount(self.available_sources))
                .{ .source = gatewaySourceAtIndex(self.available_sources, index).? }
            else if (index == gatewaySourceCount(self.available_sources))
                .{ .action = .automatic }
            else
                null,
        };
    }

    pub fn choiceIsSelected(self: PickerView, choice: Choice) bool {
        const selected = self.selected_choice orelse return false;
        return selected.eql(choice);
    }

    pub fn selectedIndex(self: PickerView) usize {
        const selected = self.selected_choice orelse return 0;
        var index: usize = 0;
        while (self.choiceAt(index)) |choice| : (index += 1) {
            if (choice.eql(selected)) return index;
        }
        return 0;
    }

    pub fn choiceLabel(self: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .provider => |provider| provider_catalog.label(provider),
            .source => |source| credentials.sourceLabel(source),
            .action => |action| switch (action) {
                .connections => "Connections",
                .login => "Sign in with Vercel",
                .chatgpt_login => "Sign in with Codex",
                .grok_login => "Sign in with Grok",
                .setup => if (self.include_skip) "Add an API key" else "API key",
                .change_team => "Change team",
                .switch_credential => "Switch credential",
                .switch_provider => "Switch provider",
                .automatic => "Automatic",
            },
            .team => |index| if (index < self.teams.len) self.teams[index].name else "",
        };
    }

    pub fn choiceDescription(self: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .provider => |provider| if (provider.eql(self.active_provider)) "current" else "available",
            .source => |source| if (self.active_source == source) "current" else "available",
            .action => |action| switch (action) {
                .connections => "",
                .login => if (self.fx_login_session_available) "connected" else "",
                .chatgpt_login => if (self.available_sources.contains(.chatgpt_subscription)) "connected" else "",
                .grok_login => if (self.available_sources.contains(.grok_subscription)) "connected" else "",
                .setup, .switch_credential, .switch_provider => "",
                .automatic => "use the first available source",
                .change_team => if (self.fx_login_session_available) "choose a team" else "sign in first",
            },
            .team => |index| if (self.teamIsCurrent(index)) "current" else "",
        };
    }

    pub fn choiceEnabled(self: PickerView, choice: Choice) bool {
        return switch (choice) {
            .action => |action| action != .change_team or self.fx_login_session_available,
            .provider, .source, .team => true,
        };
    }

    fn teamIsCurrent(self: PickerView, index: usize) bool {
        if (index >= self.teams.len) return false;
        const current = self.current_team orelse return false;
        const team = self.teams[index];
        return std.mem.eql(u8, current, team.id) or std.mem.eql(u8, current, team.slug);
    }
};

fn connectionChoiceCount() usize {
    return 4;
}

fn connectionChoiceAt(index: usize) ?Choice {
    return switch (index) {
        0 => .{ .action = .login },
        1 => .{ .action = .chatgpt_login },
        2 => .{ .action = .grok_login },
        3 => .{ .action = .setup },
        else => null,
    };
}

fn teamMatchesQuery(team: login_flow.Team, query: []const u8) bool {
    return text_utils.containsIgnoreCase(team.name, query) or
        text_utils.containsIgnoreCase(team.slug, query);
}

pub const GatewayTeamStatus = enum {
    set,
    unset,
    unknown,

    pub fn label(self: GatewayTeamStatus) []const u8 {
        return switch (self) {
            .set => "set",
            .unset => "unset",
            .unknown => "unknown",
        };
    }
};

pub const MissingHelpSurface = enum {
    cli,
    interactive,
};

pub const StatusSnapshot = struct {
    active_source: ?credentials.Source = null,
    required_source: ?credentials.Source = null,
    team: ?[]const u8 = null,
    owned_team: ?[]u8 = null,
    stored_key_status: credentials.StoredKeyReadStatus = .not_attempted,
    fx_login_status: credentials.FxLoginReadStatus = .not_attempted,
    failure: ?CredentialFailure = null,
    gateway_connected: bool = false,
    chatgpt_connected: bool = false,
    grok_connected: bool = false,
    /// The active credential is past its refresh deadline. Distinct from `refreshable`,
    /// which answers whether this source type can refresh at all.
    expired: bool = false,

    pub fn deinit(self: *StatusSnapshot, alloc: Allocator) void {
        if (self.owned_team) |team| alloc.free(team);
        self.* = .{};
    }

    pub fn activeSourceLabel(self: StatusSnapshot) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn refreshable(self: StatusSnapshot) bool {
        const source = self.active_source orelse return false;
        return credentials.sourceRefreshable(source);
    }

    pub fn missingHelp(self: StatusSnapshot, surface: MissingHelpSurface) ?[]const u8 {
        if (self.active_source != null) return null;
        if (self.stored_key_status == .unavailable) {
            if (self.required_source == .stored_key) return switch (surface) {
                .cli => "The selected stored API key could not be read from " ++ credentials.stored_key_backend_label ++ ". Start fx and open /provider to choose an available credential; no other credential was selected.",
                .interactive => "The selected stored API key could not be read from " ++ credentials.stored_key_backend_label ++ ". Run /provider to choose an available credential; no other credential was selected.",
            };
            return credentials.unreadable_store_message;
        }
        if (self.failure) |failure| {
            if (preparationError(failure)) |err| return preparationFailureNotice(err);
        }
        const automatic_help: []const u8 = switch (surface) {
            .cli => credentials.missing_credential_message,
            .interactive => credentials.missing_interactive_credential_message,
        };
        const required_source = self.required_source orelse return automatic_help;
        return switch (required_source) {
            .vercel_oidc_token => "VERCEL_OIDC_TOKEN is selected but unavailable. Set VERCEL_OIDC_TOKEN before starting fx; no other credential was selected.",
            .ai_gateway_api_key => "AI_GATEWAY_API_KEY is selected but unavailable. Set AI_GATEWAY_API_KEY before starting fx; no other credential was selected.",
            .stored_key => switch (surface) {
                .cli => "A stored API key is selected but unavailable. Start fx and open /provider to choose an available credential; no other credential was selected.",
                .interactive => "A stored API key is selected but unavailable. Run /provider to choose an available credential; no other credential was selected.",
            },
            .fx_login => switch (surface) {
                .cli => if (self.fx_login_status == .unavailable)
                    "The saved fx login could not be loaded. Run fx login to repair this source; no other credential was selected."
                else
                    "fx login is selected but unavailable. Run fx login to reconnect; no other credential was selected.",
                .interactive => if (self.fx_login_status == .unavailable)
                    "The saved fx login could not be loaded. Run /login to repair this source; no other credential was selected."
                else
                    "fx login is selected but unavailable. Run /login to reconnect; no other credential was selected.",
            },
            .chatgpt_subscription => switch (surface) {
                .cli => credentials.missing_chatgpt_credential_message,
                .interactive => credentials.missing_chatgpt_interactive_credential_message,
            },
            .grok_subscription => switch (surface) {
                .cli => credentials.missing_grok_credential_message,
                .interactive => credentials.missing_grok_interactive_credential_message,
            },
            .host_managed => automatic_help,
            .configured => "The configured provider credential is unavailable. Check its auth environment variable in settings.json; no other provider was selected.",
        };
    }

    /// Returns owned doctor status text containing no credential bytes.
    pub fn formatDoctorDetail(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        if (self.missingHelp(.cli)) |help| return alloc.dupe(u8, help);

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("{s} is configured", .{self.activeSourceLabel()});
        if (self.expired) try out.writer.writeAll("; session expired");
        try out.writer.print("; refreshable={s}", .{if (self.refreshable()) "true" else "false"});
        if (self.team) |team| try out.writer.print("; team={s}", .{team});
        return try out.toOwnedSlice();
    }
};

pub fn loadStatusSnapshot(
    alloc: Allocator,
    secret_store: host.SecretStore,
    preferred: ?credentials.Source,
) !StatusSnapshot {
    return loadStatusSnapshotForProvider(alloc, secret_store, null, preferred);
}

pub fn loadStatusSnapshotForProvider(
    alloc: Allocator,
    secret_store: host.SecretStore,
    provider: ?model_provider.ProviderId,
    preferred: ?credentials.Source,
) !StatusSnapshot {
    const chatgpt_connected = credentials.sourceExists(
        alloc,
        secret_store,
        .chatgpt_subscription,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    const grok_connected = credentials.sourceExists(
        alloc,
        secret_store,
        .grok_subscription,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    // Resolves in `.stored` mode: a diagnostic must not refresh, because refreshing
    // rewrites the session file and performs network I/O. It reports the expired state
    // instead of repairing it.
    const resolution = (if (provider) |selected_provider|
        credentials.resolveForProvider(
            alloc,
            oauth_transport.unavailable_provider,
            secret_store,
            .stored,
            selected_provider,
            preferred,
        )
    else
        credentials.resolvePreferring(
            alloc,
            oauth_transport.unavailable_provider,
            secret_store,
            .stored,
            preferred,
        )) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // The store could not be interrogated, so its contents are unknown rather than absent.
        else => blk: {
            debug_trace.logf("auth", "status snapshot failed step=resolve err={s}", .{@errorName(err)});
            break :blk credentials.Resolution{ .stored_key_status = .unavailable };
        },
    };
    const resolved_source = if (resolution.credential) |credential| credential.source else null;
    var gateway_connected = resolved_source != null and resolved_source != .chatgpt_subscription and resolved_source != .grok_subscription and resolved_source != .configured;
    const gateway_probe_required = (provider != null and (provider.? == .codex or provider.? == .grok)) or
        resolved_source == .chatgpt_subscription or resolved_source == .grok_subscription;
    if (gateway_probe_required) {
        for ([_]credentials.Source{ .vercel_oidc_token, .ai_gateway_api_key, .fx_login, .stored_key }) |source| {
            if (credentials.sourceExists(alloc, secret_store, source) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => false,
            }) {
                gateway_connected = true;
                break;
            }
        }
    }
    if (resolution.credential) |loaded| {
        var credential = loaded;
        defer credential.deinit(alloc);
        const expired = credential.needsRefreshAt(io_mod.milliTimestamp());
        const owned_team = takeDisplayTeam(alloc, &credential);
        return .{
            .active_source = credential.source,
            .team = owned_team,
            .owned_team = owned_team,
            .stored_key_status = resolution.stored_key_status,
            .fx_login_status = resolution.fx_login_status,
            .gateway_connected = gateway_connected,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
            .expired = expired,
        };
    }
    return .{
        .required_source = if (provider) |selected_provider| requestedSource(selected_provider, preferred) else preferred,
        .stored_key_status = resolution.stored_key_status,
        .fx_login_status = resolution.fx_login_status,
        .failure = if (resolution.failure) |failure| classifyCredentialFailure(failure.source, failure.err) else null,
        .gateway_connected = gateway_connected,
        .chatgpt_connected = chatgpt_connected,
        .grok_connected = grok_connected,
    };
}

pub const View = struct {
    active_source: ?credentials.Source,
    available_inactive_sources: SourceSet,
    selected_team: ?[]const u8,
    refreshable: bool,
    stored_key_status: credentials.StoredKeyReadStatus,
    fx_login_status: credentials.FxLoginReadStatus,
    onboarding_skipped: bool,

    pub fn activeSourceLabel(self: View) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn gatewayTeamStatus(self: View) GatewayTeamStatus {
        if (self.active_source == null) return .unknown;
        return if (self.selected_team == null) .unset else .set;
    }
};

pub const GatewayCredential = struct {
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    source: credentials.Source,
};

pub const ProviderCredentialSelection = union(enum) {
    unchanged,
    selected,
    missing,
    failed: credentials.LoadFailure,
};

pub const Runtime = struct {
    const Self = @This();

    api_key_validator: api_key_validator.Provider = api_key_validator.unavailable_provider,
    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
    secret_store: host.SecretStore = host.unavailable_secret_store,
    auth_mode: credentials.AuthMode = .local,
    selected_credential: ?credentials.Credential = null,
    credential_failure: ?struct {
        failure: CredentialFailure,
        notice_claimed: bool,
    } = null,
    source_inventory: SourceSet = .empty,
    unavailable_sources: SourceSet = .empty,
    stored_key_status: credentials.StoredKeyReadStatus = .not_attempted,
    fx_login_status: credentials.FxLoginReadStatus = .not_attempted,
    onboarding_skipped: bool = false,
    picker_active: bool = false,
    picker_selection: ?Choice = null,
    picker_include_skip: bool = false,
    picker_stage: PickerStage = .root,
    provider_picker_active: model_provider.ProviderId = .gateway,
    fx_login_session_available: bool = false,
    team_selection: ?login_flow.TeamSelection = null,
    team_query: std.ArrayList(u8) = .empty,
    sign_in_flow: login_flow.SignInRuntime = .{},
    sign_in_source: credentials.Source = .fx_login,
    sign_in_returns_to_root: bool = false,
    sign_in_code_visible: bool = false,
    sign_in_code_input: std.ArrayList(u8) = .empty,
    api_key_input: std.ArrayList(u8) = .empty,
    /// The key field is rendered as a `/provider` column instead of the staged
    /// panel, so the composer keeps showing which path the user walked.
    api_key_inline: bool = false,
    api_key_returns_to_root: bool = false,
    api_key_save: ApiKeySaveRuntime = .{},
    inventory_refresh_task: ?*InventoryRefreshTask = null,
    prompt_credential_refresh_task: ?*PromptCredentialRefreshTask = null,
    provider_preparation: ?*ProviderPreparation = null,
    startup_credential_task: ?*StartupCredentialTask = null,
    /// The launch source inventory waits for the first frame.
    startup_inventory_deferred: bool = false,

    pub fn init(
        validator: api_key_validator.Provider,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
    ) Self {
        return initWithMode(validator, transport, secret_store, .local);
    }

    pub fn initWithMode(
        validator: api_key_validator.Provider,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
        auth_mode: credentials.AuthMode,
    ) Self {
        return .{
            .api_key_validator = validator,
            .oauth_transport = transport,
            .secret_store = secret_store,
            .auth_mode = auth_mode,
        };
    }

    /// Fieldwise initialization avoids retaining inactive credential and
    /// worker payloads in a static release-binary template.
    pub fn initInto(
        storage: *Self,
        validator: api_key_validator.Provider,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
    ) void {
        initIntoWithMode(storage, validator, transport, secret_store, .local);
    }

    pub fn initIntoWithMode(
        storage: *Self,
        validator: api_key_validator.Provider,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
        auth_mode: credentials.AuthMode,
    ) void {
        comptime {
            if (@typeInfo(Self).@"struct".field_names.len != 33) {
                @compileError("update Runtime.initInto for the changed field set");
            }
        }
        storage.* = undefined;
        storage.api_key_validator = validator;
        storage.oauth_transport = transport;
        storage.secret_store = secret_store;
        storage.auth_mode = auth_mode;
        storage.selected_credential = null;
        storage.credential_failure = null;
        storage.source_inventory = .empty;
        storage.unavailable_sources = .empty;
        storage.stored_key_status = .not_attempted;
        storage.fx_login_status = .not_attempted;
        storage.onboarding_skipped = false;
        storage.picker_active = false;
        storage.picker_selection = null;
        storage.picker_include_skip = false;
        storage.picker_stage = .root;
        storage.provider_picker_active = .gateway;
        storage.fx_login_session_available = false;
        storage.team_selection = null;
        storage.team_query = .empty;
        storage.sign_in_flow = .{};
        storage.sign_in_source = .fx_login;
        storage.sign_in_returns_to_root = false;
        storage.sign_in_code_visible = false;
        storage.sign_in_code_input = .empty;
        storage.api_key_input = .empty;
        storage.api_key_inline = false;
        storage.api_key_returns_to_root = false;
        storage.api_key_save = .{};
        storage.inventory_refresh_task = null;
        storage.prompt_credential_refresh_task = null;
        storage.provider_preparation = null;
        storage.startup_credential_task = null;
        storage.startup_inventory_deferred = false;
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        if (self.startup_credential_task) |task| task.deinit();
        self.startup_credential_task = null;
        self.stopProviderPreparation();
        if (self.inventory_refresh_task) |task| task.deinit();
        self.inventory_refresh_task = null;
        if (self.prompt_credential_refresh_task) |task| task.deinit();
        self.prompt_credential_refresh_task = null;
        self.api_key_save.deinit(alloc);
        self.sign_in_flow.deinit(alloc);
        self.clearSignInCodeInput(alloc, .runtime_deinit);
        self.exitApiKeyStage(alloc, .runtime_deinit);
        self.clearTeamSelection(alloc);
        self.team_query.deinit(alloc);
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.* = .{};
    }

    /// Borrows the current credential until this runtime replaces or releases it.
    pub fn gatewayCredential(self: *const Self) ?GatewayCredential {
        return self.gatewayCredentialAt(io_mod.milliTimestamp());
    }

    fn gatewayCredentialAt(self: *const Self, now_ms: i64) ?GatewayCredential {
        if (self.auth_mode == .host_managed) return .{
            .api_key = null,
            .gateway_team = null,
            .source = .host_managed,
        };
        const credential = self.selected_credential orelse return null;
        if (credential.needsRefreshAt(now_ms)) return null;
        if (credential.source == .fx_login) {
            const team = credential.gatewayTeam() orelse return null;
            if (!types.validGatewayTeam(team)) return null;
        }
        return .{
            .api_key = credential.token,
            .gateway_team = credential.gatewayTeam(),
            .source = credential.source,
        };
    }

    pub fn apiKey(self: *const Self) ?[]const u8 {
        const credential = self.gatewayCredential() orelse return null;
        return credential.api_key;
    }

    pub fn isHostManaged(self: *const Self) bool {
        return self.auth_mode == .host_managed;
    }

    pub fn authMode(self: *const Self) credentials.AuthMode {
        return self.auth_mode;
    }

    pub fn oauthTransport(self: *const Self) oauth_transport.Provider {
        return self.oauth_transport;
    }

    pub fn secretStore(self: *const Self) host.SecretStore {
        return self.secret_store;
    }

    pub fn modelCatalogAccess(self: *const Self) credentials.CatalogAccess {
        if (self.auth_mode == .host_managed) return .host_managed;
        if (self.credentialFailure()) |failure| {
            return credentials.catalogAccessAfterRefreshFailure(failure.source);
        }
        return credentials.catalogAccessAt(self.selected_credential, io_mod.milliTimestamp());
    }

    /// Records recovery state even when silent. Returns true only when claiming
    /// the first requested notice of this failure episode.
    pub fn recordCredentialFailure(
        self: *Self,
        failure: CredentialFailure,
        options: struct { notify: bool = true },
    ) bool {
        std.debug.assert(self.credentialSource() == failure.source);
        const same_failure = if (self.credential_failure) |current|
            current.failure.source == failure.source and current.failure.reason == failure.reason
        else
            false;
        if (!same_failure) self.credential_failure = .{ .failure = failure, .notice_claimed = false };
        if (!options.notify or self.credential_failure.?.notice_claimed) return false;
        self.credential_failure.?.notice_claimed = true;
        return true;
    }

    /// Recovery and catalog access concern only the selected credential.
    pub fn credentialFailure(self: *const Self) ?CredentialFailure {
        const episode = self.credential_failure orelse return null;
        return if (self.credentialSource() == episode.failure.source) episode.failure else null;
    }

    pub fn credentialSource(self: *const Self) ?credentials.Source {
        if (self.auth_mode == .host_managed) return .host_managed;
        const credential = self.selected_credential orelse return null;
        return credential.source;
    }

    pub fn accountId(self: *const Self) ?[]const u8 {
        if (self.auth_mode == .host_managed) return null;
        const credential = self.selected_credential orelse return null;
        return credential.accountId();
    }

    pub fn gatewayTeam(self: *const Self) ?[]const u8 {
        const credential = self.gatewayCredential() orelse return null;
        return credential.gateway_team;
    }

    pub fn credentialNeedsRefresh(self: *const Self) bool {
        return self.credentialNeedsRefreshAt(io_mod.milliTimestamp());
    }

    fn credentialNeedsRefreshAt(self: *const Self, now_ms: i64) bool {
        const credential = self.selected_credential orelse return false;
        return credential.needsRefreshAt(now_ms);
    }

    pub fn statusSnapshot(self: *const Self, provider: model_provider.ProviderId, preferred: ?credentials.Source) StatusSnapshot {
        return self.statusSnapshotAt(io_mod.milliTimestamp(), provider, preferred);
    }

    fn statusSnapshotAt(self: *const Self, now_ms: i64, provider: model_provider.ProviderId, preferred: ?credentials.Source) StatusSnapshot {
        if (self.auth_mode == .host_managed) return .{
            .active_source = .host_managed,
            .gateway_connected = true,
            .chatgpt_connected = true,
            .grok_connected = true,
        };
        const gateway_connected = self.source_inventory.contains(.vercel_oidc_token) or
            self.source_inventory.contains(.ai_gateway_api_key) or
            self.source_inventory.contains(.fx_login) or
            self.source_inventory.contains(.stored_key);
        const chatgpt_connected = self.source_inventory.contains(.chatgpt_subscription);
        const grok_connected = self.source_inventory.contains(.grok_subscription);
        const credential = self.selected_credential orelse return .{
            .required_source = requestedSource(provider, preferred),
            .failure = if (self.credential_failure) |episode|
                if (model_provider.authorizesCredential(provider, episode.failure.source)) episode.failure else null
            else
                null,
            .stored_key_status = if (provider == .gateway) self.stored_key_status else .not_attempted,
            .fx_login_status = if (provider == .gateway) self.fx_login_status else .not_attempted,
            .gateway_connected = gateway_connected,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
        };
        return .{
            .active_source = credential.source,
            .team = displayTeam(credential),
            .gateway_connected = gateway_connected,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
            .expired = credential.needsRefreshAt(now_ms),
        };
    }

    pub fn view(self: *const Self) View {
        const active_source = self.credentialSource();
        var available_inactive_sources = self.source_inventory;
        if (active_source) |source| available_inactive_sources.remove(source);

        return .{
            .active_source = active_source,
            .available_inactive_sources = available_inactive_sources,
            .selected_team = if (self.selected_credential) |credential| credential.gatewayTeam() else null,
            .refreshable = if (active_source) |source| credentials.sourceRefreshable(source) else false,
            .stored_key_status = self.stored_key_status,
            .fx_login_status = self.fx_login_status,
            .onboarding_skipped = self.onboarding_skipped,
        };
    }

    pub fn recordStartupStatus(
        self: *Self,
        stored_key_status: credentials.StoredKeyReadStatus,
        fx_login_status: credentials.FxLoginReadStatus,
        load_failure: ?credentials.LoadFailure,
        onboarding_skipped: bool,
    ) void {
        self.stored_key_status = stored_key_status;
        self.fx_login_status = fx_login_status;
        self.onboarding_skipped = onboarding_skipped;
        if (self.auth_mode == .local and self.selected_credential == null) {
            self.credential_failure = if (load_failure) |failure| .{
                .failure = classifyCredentialFailure(failure.source, failure.err),
                .notice_claimed = true,
            } else null;
        }
    }

    pub fn beginProviderPreparation(self: *Self, alloc: Allocator, input: ProviderPreparationInput) !void {
        if (self.provider_preparation != null) return error.ProviderPreparationInProgress;
        self.cancelPromptCredentialRefresh();
        self.provider_preparation = try ProviderPreparation.start(alloc, self, input);
    }

    pub fn providerPreparationPending(self: *const Self) bool {
        return self.provider_preparation != null;
    }

    pub fn cancelProviderPreparation(self: *Self) bool {
        const task = self.provider_preparation orelse return false;
        task.requestCancel();
        return true;
    }

    pub fn takeProviderPreparation(self: *Self) ?*ProviderPreparation {
        const task = self.provider_preparation orelse return null;
        if (!task.done.load(.acquire)) return null;
        if (task.thread) |thread| thread.join();
        task.thread = null;
        self.provider_preparation = null;
        return task;
    }

    pub fn stopProviderPreparation(self: *Self) void {
        const task = self.provider_preparation orelse return;
        self.provider_preparation = null;
        task.deinit();
    }

    pub fn skipOnboarding(self: *Self) void {
        self.onboarding_skipped = true;
    }

    pub fn refreshSourceInventory(self: *Self, alloc: Allocator) !void {
        if (self.auth_mode == .host_managed) {
            self.source_inventory = .empty;
            self.unavailable_sources = .empty;
            return;
        }
        try self.refreshSourceInventoryWithProbe(alloc, self, probeCredentialSource);
    }

    pub fn beginSourceInventoryRefresh(
        self: *Self,
        alloc: Allocator,
        action: InventoryRefreshAction,
    ) InventoryRefreshStart {
        return self.beginSourceInventoryRefreshWithDeps(alloc, action, .{
            .ctx = self,
            .probe = probeCredentialSource,
        });
    }

    fn beginSourceInventoryRefreshWithDeps(
        self: *Self,
        alloc: Allocator,
        action: InventoryRefreshAction,
        deps: InventoryRefreshDeps,
    ) InventoryRefreshStart {
        if (self.inventory_refresh_task != null) return .busy;
        self.inventory_refresh_task = InventoryRefreshTask.start(
            alloc,
            action,
            deps,
        ) catch return .failed;
        return .started;
    }

    pub fn takeSourceInventoryRefresh(
        self: *Self,
    ) ?InventoryRefreshResult {
        const task = self.inventory_refresh_task orelse return null;
        if (!task.done.load(.acquire)) return null;
        if (task.thread) |thread| {
            thread.join();
            task.thread = null;
        }
        self.inventory_refresh_task = null;
        defer task.deinit();
        if (task.failure != null or task.inventory == null) {
            return .{ .failed = task.action };
        }
        self.applySourceInventory(task.inventory.?);
        return .{ .ready = task.action };
    }

    pub fn sourceInventoryRefreshActive(self: *const Self) bool {
        return self.inventory_refresh_task != null;
    }

    pub fn refreshChatGptSourceInventory(self: *Self, alloc: Allocator) !void {
        if (self.auth_mode == .host_managed) return;
        if (try credentials.sourceExists(alloc, self.secret_store, .chatgpt_subscription)) {
            self.source_inventory.insert(.chatgpt_subscription);
        } else if (self.credentialSource() != .chatgpt_subscription) {
            self.source_inventory.remove(.chatgpt_subscription);
        }
    }

    pub fn refreshGrokSourceInventory(self: *Self, alloc: Allocator) !void {
        if (self.auth_mode == .host_managed) return;
        if (try credentials.sourceExists(alloc, self.secret_store, .grok_subscription)) {
            self.source_inventory.insert(.grok_subscription);
        } else if (self.credentialSource() != .grok_subscription) {
            self.source_inventory.remove(.grok_subscription);
        }
    }

    fn refreshSourceInventoryWithProbe(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
    ) !void {
        self.applySourceInventory(try SourceInventory.detect(alloc, ctx, probe));
    }

    fn applySourceInventory(self: *Self, inventory: SourceInventory) void {
        self.source_inventory = inventory.available;
        self.unavailable_sources = inventory.unavailable;
        self.fx_login_session_available = inventory.available.contains(.fx_login);
        if (!inventory.available.contains(.stored_key) and !inventory.unavailable.contains(.stored_key)) {
            self.stored_key_status = .not_found;
        }
        if (!inventory.available.contains(.fx_login) and !inventory.unavailable.contains(.fx_login)) {
            self.fx_login_status = .absent;
        }
        if (self.credentialSource()) |source| {
            if (source != .host_managed and !inventory.unavailable.contains(source)) self.source_inventory.insert(source);
        } else if (self.credential_failure) |episode| {
            const failure = episode.failure;
            if (!inventory.available.contains(failure.source) and !inventory.unavailable.contains(failure.source)) {
                debug_trace.logf("auth", "credential load failure cleared source={t} reason=source_absent", .{failure.source});
                self.credential_failure = null;
            }
        }
    }

    pub fn openPicker(self: *Self, alloc: Allocator) void {
        self.openPickerForProvider(alloc, .gateway);
    }

    pub fn openPickerForProvider(
        self: *Self,
        alloc: Allocator,
        active_provider: model_provider.ProviderId,
    ) void {
        self.provider_picker_active = active_provider;
        self.openPickerWithSkip(alloc, false);
    }

    pub fn openOnboardingPicker(self: *Self, alloc: Allocator) void {
        self.openPickerWithSkip(alloc, true);
    }

    fn openPickerWithSkip(self: *Self, alloc: Allocator, include_skip: bool) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_include_skip = include_skip;
        self.picker_stage = .root;
        self.picker_selection = self.pickerView().choiceAt(0);
    }

    pub fn pickerView(self: *const Self) PickerView {
        return .{
            .active = self.picker_active,
            .available_sources = self.source_inventory,
            .unavailable_sources = self.unavailable_sources,
            .selected_choice = self.picker_selection,
            .active_source = self.credentialSource(),
            .active_provider = self.provider_picker_active,
            .include_skip = self.picker_include_skip,
            .stage = self.picker_stage,
            .fx_login_session_available = self.fx_login_session_available,
            .teams = if (self.team_selection) |*selection| selection.teams.items else &.{},
            .current_team = if (self.team_selection) |*selection|
                selection.currentTeam()
            else if (self.selected_credential) |credential|
                credential.gatewayTeam()
            else
                null,
            .team_query = self.team_query.items,
            .sign_in = self.sign_in_flow.snapshot(),
            .sign_in_source = self.sign_in_source,
            .sign_in_code_visible = self.sign_in_code_visible,
            .sign_in_code_mask_count = @min(self.sign_in_code_input.items.len, max_manual_code_mask_glyphs),
            .api_key_mask_count = self.apiKeyMaskCount(),
            .api_key_inline = self.api_key_inline,
        };
    }

    pub fn movePicker(self: *Self, delta: i32) bool {
        if (!self.picker_active or delta == 0) return false;
        const picker = self.pickerView();
        const choice_count = picker.choiceCount();
        if (choice_count < 2) return false;
        var next_index = picker.selectedIndex();
        for (0..choice_count) |_| {
            next_index = if (delta < 0)
                if (next_index == 0) choice_count - 1 else next_index - 1
            else if (next_index + 1 == choice_count)
                0
            else
                next_index + 1;
            const choice = picker.choiceAt(next_index) orelse continue;
            if (!picker.choiceEnabled(choice)) continue;
            self.picker_selection = choice;
            return true;
        }
        return false;
    }

    /// Frees a team list adopted for the inline `/provider` picker. The staged
    /// picker owns its list through its stages, so an active staged picker is
    /// left alone.
    pub fn releaseLoadedTeamSelection(self: *Self, alloc: Allocator) void {
        if (self.picker_active) return;
        self.clearTeamSelection(alloc);
    }

    /// Takes ownership of a loaded team list without opening the staged picker
    /// band, so the inline `/provider` picker can render the teams as a column.
    pub fn adoptTeamSelection(self: *Self, alloc: Allocator, selection: *login_flow.TeamSelection) void {
        self.clearTeamSelection(alloc);
        self.team_selection = selection.take();
    }

    pub fn openTeamPicker(self: *Self, alloc: Allocator, selection: *login_flow.TeamSelection) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.team_selection = selection.take();
        self.picker_include_skip = false;
        self.picker_stage = .change_team;
        self.picker_selection = self.currentTeamChoice() orelse self.pickerView().choiceAt(0);
    }

    fn openConnectionPicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_stage = .connections;
        self.picker_selection = self.pickerView().choiceAt(0);
    }

    pub fn openProviderPicker(
        self: *Self,
        alloc: Allocator,
        active_provider: model_provider.ProviderId,
    ) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_include_skip = false;
        self.picker_stage = .provider;
        self.provider_picker_active = active_provider;
        self.picker_selection = .{ .provider = active_provider };
    }

    pub fn teamPickerActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .change_team;
    }

    pub fn appendTeamQueryByte(self: *Self, alloc: Allocator, byte: u8) !bool {
        if (!self.teamPickerActive()) return false;
        if (byte < 0x20 or byte == 0x7f) return false;
        if (self.team_query.items.len < max_team_query_bytes) {
            try self.team_query.append(alloc, byte);
            self.resetTeamPickerSelection();
        }
        return true;
    }

    pub fn deleteTeamQueryByte(self: *Self) bool {
        if (!self.teamPickerActive()) return false;
        if (self.team_query.items.len > 0) {
            const end = text_utils.utf8BackwardBoundary(
                self.team_query.items,
                self.team_query.items.len - 1,
            );
            self.team_query.shrinkRetainingCapacity(end);
            self.resetTeamPickerSelection();
        }
        return true;
    }

    pub fn openSwitchCredentialPicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.picker_stage = .switch_credential;
        const active_source = self.credentialSource();
        self.picker_selection = if (active_source) |source|
            if (source != .chatgpt_subscription and source != .grok_subscription and self.source_inventory.contains(source))
                .{ .source = source }
            else
                self.pickerView().choiceAt(0)
        else
            self.pickerView().choiceAt(0);
    }

    pub fn openApiKeyPicker(self: *Self, alloc: Allocator) void {
        self.openApiKeyPickerWithParent(alloc, false);
    }

    pub fn openApiKeyPickerFromRoot(self: *Self, alloc: Allocator) void {
        self.openApiKeyPickerWithParent(alloc, true);
    }

    fn openApiKeyPickerWithParent(self: *Self, alloc: Allocator, returns_to_root: bool) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_stage = .api_key;
        self.picker_selection = null;
        self.api_key_returns_to_root = returns_to_root;
    }

    /// Opens the key field for the inline `/provider` picker. The stage is the
    /// same one the staged panel uses, so entry, saving, and cancelling all
    /// keep working; only the rendering differs.
    pub fn openApiKeyPickerInline(self: *Self, alloc: Allocator) void {
        self.openApiKeyPickerWithParent(alloc, false);
        self.api_key_inline = true;
    }

    pub fn apiKeyInlineActive(self: *const Self) bool {
        return self.apiKeyEntryActive() and self.api_key_inline;
    }

    pub fn apiKeyMaskCount(self: *const Self) usize {
        return @min(self.api_key_input.items.len, max_api_key_mask_glyphs);
    }

    /// Leaves the key field without saving, zeroing whatever was typed.
    pub fn cancelInlineApiKeyEntry(self: *Self, alloc: Allocator) void {
        if (!self.apiKeyInlineActive()) return;
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.picker_active = false;
        self.picker_stage = .root;
    }

    pub fn openSignInPicker(self: *Self, alloc: Allocator) !bool {
        return self.openSignInPickerWithParent(alloc, false, .fx_login);
    }

    pub fn openSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        return self.openSignInPickerWithParent(alloc, true, .fx_login);
    }

    pub fn openChatGptSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        return self.openSignInPickerWithParent(alloc, true, .chatgpt_subscription);
    }

    pub fn openChatGptSignInPickerForProviderSwitch(self: *Self, alloc: Allocator) !bool {
        return self.openSignInPickerWithParent(alloc, false, .chatgpt_subscription);
    }

    pub fn openGrokSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        return self.openSignInPickerWithParent(alloc, true, .grok_subscription);
    }

    pub fn openGrokSignInPickerForProviderSwitch(self: *Self, alloc: Allocator) !bool {
        return self.openSignInPickerWithParent(alloc, false, .grok_subscription);
    }

    fn openSignInPickerWithParent(
        self: *Self,
        alloc: Allocator,
        returns_to_root: bool,
        source: credentials.Source,
    ) !bool {
        self.exitSignInStage(alloc);
        const started = switch (source) {
            .fx_login => try self.sign_in_flow.start(alloc, self.oauth_transport),
            .chatgpt_subscription => try chatgpt_oauth.startSignIn(&self.sign_in_flow, alloc, self.oauth_transport),
            .grok_subscription => try grok_oauth.startSignIn(&self.sign_in_flow, alloc, self.oauth_transport),
            else => return error.InvalidSignInSource,
        };
        if (!started) return false;
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_stage = .sign_in;
        self.picker_selection = null;
        self.sign_in_source = source;
        self.sign_in_returns_to_root = returns_to_root;
        self.sign_in_code_visible = false;
        return true;
    }

    pub fn signInEntryActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .sign_in;
    }

    pub fn signInCodeEntryActive(self: *const Self) bool {
        return self.signInEntryActive() and
            self.sign_in_flow.snapshot().accepts_manual_code and
            self.sign_in_code_visible;
    }

    pub fn toggleSignInCodeEntry(self: *Self) bool {
        if (!self.signInEntryActive() or !self.sign_in_flow.snapshot().accepts_manual_code) {
            return false;
        }
        self.sign_in_code_visible = !self.sign_in_code_visible;
        return true;
    }

    pub fn signInReturnsToRoot(self: *const Self) bool {
        return self.sign_in_returns_to_root;
    }

    pub fn signInBrowserUrlAlloc(self: *Self, alloc: Allocator) !?[]u8 {
        if (!self.signInEntryActive()) return null;
        return self.sign_in_flow.browserUrlAlloc(alloc);
    }

    pub fn pollSignInTransition(self: *Self, alloc: Allocator) login_flow.SignInTransition {
        return self.sign_in_flow.pollTransition(alloc);
    }

    pub fn appendSignInCodeByte(self: *Self, alloc: Allocator, byte: u8) !bool {
        if (!self.signInCodeEntryActive()) return false;
        if (byte <= 0x20 or byte > 0x7e) return true;
        if (self.sign_in_code_input.items.len >= login_flow.max_manual_code_bytes) return true;
        try self.sign_in_code_input.ensureTotalCapacityPrecise(alloc, login_flow.max_manual_code_bytes);
        self.sign_in_code_input.appendAssumeCapacity(byte);
        return true;
    }

    pub fn deleteSignInCodeByte(self: *Self) bool {
        if (!self.signInCodeEntryActive()) return false;
        if (self.sign_in_code_input.items.len > 0) {
            self.sign_in_code_input.items.len -= 1;
            self.sign_in_code_input.allocatedSlice()[self.sign_in_code_input.items.len] = 0;
        }
        return true;
    }

    pub fn replaceSignInCodeInput(self: *Self, alloc: Allocator, input: []const u8) !bool {
        if (!self.signInCodeEntryActive()) return false;
        const code = std.mem.trim(u8, input, " \t\r\n");
        if (code.len == 0 or code.len > login_flow.max_manual_code_bytes) return false;
        for (code) |byte| {
            if (byte < 0x21 or byte > 0x7e) return false;
        }
        if (self.sign_in_code_input.capacity > 0) {
            self.sign_in_code_input.clearRetainingCapacity();
            @memset(self.sign_in_code_input.allocatedSlice(), 0);
        }
        try self.sign_in_code_input.ensureTotalCapacityPrecise(alloc, login_flow.max_manual_code_bytes);
        self.sign_in_code_input.appendSliceAssumeCapacity(code);
        return true;
    }

    pub fn submitSignInCode(self: *Self, alloc: Allocator) !bool {
        if (!self.signInCodeEntryActive() or self.sign_in_code_input.items.len == 0) return false;
        if (!try self.sign_in_flow.submitManualCode(alloc, self.sign_in_code_input.items)) return false;
        self.clearSignInCodeInput(alloc, .submitted);
        return true;
    }

    pub fn apiKeyEntryActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .api_key;
    }

    pub fn appendApiKeyByte(self: *Self, alloc: Allocator, byte: u8) !bool {
        if (!self.apiKeyEntryActive()) return false;
        if (self.api_key_input.items.len >= max_api_key_entry_bytes) return true;
        if (byte < 0x20 or byte == 0x7f) return true;
        // Reserve the entry ceiling up front so growth never abandons an
        // unzeroed buffer holding part of the key.
        try self.api_key_input.ensureTotalCapacityPrecise(alloc, max_api_key_entry_bytes);
        self.api_key_input.appendAssumeCapacity(byte);
        return true;
    }

    pub fn deleteApiKeyByte(self: *Self) bool {
        if (!self.apiKeyEntryActive()) return false;
        if (self.api_key_input.items.len > 0) _ = self.api_key_input.pop();
        return true;
    }

    /// Hands the entered key to a worker and pops the stage immediately. The key
    /// store write can block for seconds on a locked keychain, and the gateway
    /// check is a network round trip; neither may run on the event loop.
    pub fn beginApiKeySave(self: *Self, alloc: Allocator) ApiKeySaveStart {
        return self.beginApiKeySaveWithDeps(alloc, .{
            .ctx = self,
            .validator = self.api_key_validator,
            .store = storeRuntimeSecret,
            .loader = loadRuntimeCredentialSource,
        });
    }

    fn beginApiKeySaveWithDeps(self: *Self, alloc: Allocator, deps: ApiKeySaveDeps) ApiKeySaveStart {
        if (!self.apiKeyEntryActive() or self.api_key_input.items.len == 0) return .empty;

        // Ownership moves to the worker, so the stage exit below has nothing to zero.
        const key = self.api_key_input;
        self.api_key_input = .empty;

        const returns_to_root = self.api_key_returns_to_root;
        self.exitApiKeyStage(alloc, .saved);
        self.picker_active = returns_to_root;
        if (!returns_to_root or self.picker_include_skip) {
            self.picker_stage = .root;
            self.picker_selection = if (returns_to_root) .{ .action = .setup } else null;
        } else {
            self.picker_stage = .connections;
            self.picker_selection = .{ .action = .setup };
        }

        return if (self.api_key_save.start(alloc, key, deps)) .started else .busy;
    }

    pub fn apiKeySaveInFlight(self: *const Self) bool {
        return self.api_key_save.isSaving();
    }

    /// Applies a finished save on the main thread. Adopting the credential here
    /// keeps `selected_credential` off the worker.
    pub fn takeApiKeySaveResult(self: *Self, alloc: Allocator) ?ApiKeySaveResult {
        var outcome = self.api_key_save.take(alloc) orelse return null;
        return switch (outcome) {
            .gateway_refused => .gateway_refused,
            .gateway_unavailable => .gateway_unavailable,
            .store_failed => .store_failed,
            .reload_failed => .reload_failed,
            .loaded => |*credential| blk: {
                var owned = credential.*;
                outcome = .reload_failed;
                defer owned.deinit(alloc);
                break :blk .{ .saved = self.adoptCredential(alloc, &owned) };
            },
        };
    }

    pub fn popPickerStage(self: *Self, alloc: Allocator) bool {
        if (!self.picker_active) return false;
        const stage = self.picker_stage;
        if (stage == .root) {
            self.closePicker(alloc);
            return true;
        }
        if (stage == .provider) {
            self.picker_stage = .root;
            self.picker_selection = .{ .action = .switch_provider };
            return true;
        }
        if (stage == .connections) {
            self.picker_stage = .root;
            self.picker_selection = .{ .action = .connections };
            return true;
        }

        if (stage == .sign_in) {
            const returns_to_root = self.sign_in_returns_to_root;
            _ = self.sign_in_flow.cancel(alloc);
            self.clearSignInCodeInput(alloc, .cancel);
            self.sign_in_returns_to_root = false;
            if (!returns_to_root) {
                self.picker_active = false;
                self.picker_stage = .root;
                self.picker_selection = null;
                return true;
            }
            if (!self.picker_include_skip) {
                self.clearTeamSelection(alloc);
                self.picker_stage = .connections;
                self.picker_selection = .{ .action = switch (self.sign_in_source) {
                    .chatgpt_subscription => .chatgpt_login,
                    .grok_subscription => .grok_login,
                    else => .login,
                } };
                return true;
            }
        }

        if (stage == .api_key) {
            const returns_to_root = self.api_key_returns_to_root;
            self.exitApiKeyStage(alloc, .cancel);
            if (!returns_to_root) {
                self.picker_active = false;
                self.picker_stage = .root;
                self.picker_selection = null;
                return true;
            }
            if (!self.picker_include_skip) {
                self.clearTeamSelection(alloc);
                self.picker_stage = .connections;
                self.picker_selection = .{ .action = .setup };
                return true;
            }
        }

        self.clearTeamSelection(alloc);
        self.picker_stage = .root;
        self.picker_selection = .{ .action = switch (stage) {
            .root => unreachable,
            .connections => unreachable,
            .provider => unreachable,
            .sign_in => if (self.sign_in_source == .chatgpt_subscription)
                .chatgpt_login
            else if (self.sign_in_source == .grok_subscription)
                .grok_login
            else
                .login,
            .api_key => .setup,
            .change_team => .change_team,
            .switch_credential => .switch_credential,
        } };
        return true;
    }

    pub fn closePicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = false;
        self.picker_stage = .root;
    }

    pub fn takePickerChoice(self: *Self, alloc: Allocator) ?Choice {
        if (!self.picker_active) return null;
        if (self.picker_stage == .sign_in or self.picker_stage == .api_key) return null;
        const choice = self.picker_selection;
        const selected = choice orelse return null;
        if (!self.pickerView().choiceEnabled(selected)) return null;

        switch (self.picker_stage) {
            .sign_in, .api_key => unreachable,
            .connections => switch (selected) {
                .action => |action| switch (action) {
                    .login, .chatgpt_login, .grok_login => self.closePicker(alloc),
                    .setup => {},
                    .connections,
                    .change_team,
                    .switch_credential,
                    .switch_provider,
                    .automatic,
                    => unreachable,
                },
                .provider, .source, .team => unreachable,
            },
            .provider => switch (selected) {
                .provider => self.closePicker(alloc),
                .source, .action, .team => unreachable,
            },
            .root => switch (selected) {
                .provider => unreachable,
                .source => self.closePicker(alloc),
                .action => |action| switch (action) {
                    .connections => {
                        self.openConnectionPicker(alloc);
                        return null;
                    },
                    .change_team => {},
                    .switch_provider => {},
                    .switch_credential => {
                        self.openSwitchCredentialPicker(alloc);
                        return null;
                    },
                    .setup => {},
                    // Only reachable from the switch screen, never the root.
                    .automatic => unreachable,
                    .login, .chatgpt_login, .grok_login => self.closePicker(alloc),
                },
                .team => unreachable,
            },
            .change_team => switch (selected) {
                .team => {},
                .provider, .source, .action => unreachable,
            },
            .switch_credential => switch (selected) {
                .source => self.closePicker(alloc),
                // Automatic is the only action this stage offers; the app
                // handler clears the stored choice and closes the picker.
                .action => |action| std.debug.assert(action == .automatic),
                .provider, .team => unreachable,
            },
        }
        return choice;
    }

    fn exitSignInStage(self: *Self, alloc: Allocator) void {
        if (self.picker_stage != .sign_in) return;
        _ = self.sign_in_flow.cancel(alloc);
        self.clearSignInCodeInput(alloc, .screen_replacement);
        self.sign_in_returns_to_root = false;
    }

    fn clearSignInCodeInput(self: *Self, alloc: Allocator, reason: ManualCodeClearReason) void {
        const byte_count = self.sign_in_code_input.items.len;
        self.sign_in_code_visible = false;
        if (self.sign_in_code_input.capacity > 0) {
            secret.zeroAndFree(alloc, self.sign_in_code_input.allocatedSlice());
            self.sign_in_code_input = .empty;
        }
        if (byte_count > 0) {
            debug_trace.logf(
                "auth",
                "authorization code entry cleared reason={s} bytes={d}",
                .{ @tagName(reason), byte_count },
            );
        }
    }

    /// The loaded team list regardless of which picker is presenting it: the
    /// staged picker only shows it during its team stage, while the inline
    /// `/provider` picker renders it as a column without opening a stage.
    pub fn loadedTeamSelection(self: *Self) ?*login_flow.TeamSelection {
        return if (self.team_selection) |*selection| selection else null;
    }

    /// Moves the credential into this session and returns whether any observed
    /// credential field changed. Callers that distinguish secret rotation from
    /// authority replacement should use `adoptPreparedCredential`.
    pub fn adoptCredential(self: *Self, alloc: Allocator, credential: *credentials.Credential) bool {
        return self.adoptPreparedCredential(alloc, credential) != .none;
    }

    /// Moves one complete prepared credential into this runtime. The result
    /// separates token/refresh-deadline rotation from provider, source,
    /// account, or team authority changes so callers can preserve valid caches.
    pub fn adoptPreparedCredential(
        self: *Self,
        alloc: Allocator,
        credential: *credentials.Credential,
    ) auth_transition.CredentialChange {
        const change = self.preparedCredentialChange(credential.*);
        if (change == .authority) _ = self.cancelProviderPreparation();
        self.cancelPromptCredentialRefresh();
        const source = credential.source;
        if (self.selected_credential) |*selected| selected.deinit(alloc);

        self.selected_credential = credential.*;
        self.credential_failure = null;
        credential.token = &.{};
        credential.account_id = null;
        credential.team_id = null;
        credential.team_slug = null;
        self.source_inventory.insert(source);
        self.unavailable_sources.remove(source);
        if (source == .fx_login) self.fx_login_session_available = true;
        if (source == .stored_key) self.stored_key_status = .not_attempted;
        return change;
    }

    pub fn preparedCredentialChange(
        self: *const Self,
        credential: credentials.Credential,
    ) auth_transition.CredentialChange {
        return if (self.selected_credential) |selected|
            auth_transition.decideCredentialChange(
                credentialAuthorityFacts(selected),
                credentialAuthorityFacts(credential),
                !std.mem.eql(u8, selected.token, credential.token) or
                    selected.refresh_after_ms != credential.refresh_after_ms,
            )
        else
            .authority;
    }

    fn selectSourceWithLoader(
        self: *Self,
        alloc: Allocator,
        source: credentials.Source,
        ctx: ?*anyopaque,
        loader: CredentialLoaderFn,
    ) !?bool {
        var credential = (try loader(ctx, alloc, source)) orelse return null;
        defer credential.deinit(alloc);
        if (credential.source != source) return error.CredentialSourceMismatch;
        return self.adoptCredential(alloc, &credential);
    }

    pub fn selectSource(self: *Self, alloc: Allocator, source: credentials.Source) !?bool {
        return self.selectSourceWithLoader(alloc, source, self, loadRuntimeCredentialSource);
    }

    pub fn selectForProvider(
        self: *Self,
        alloc: Allocator,
        provider: model_provider.ProviderId,
        preferred: ?credentials.Source,
    ) Allocator.Error!ProviderCredentialSelection {
        if (self.auth_mode == .host_managed or
            (provider != .configured and model_provider.authorizesCredential(provider, self.credentialSource()))) return .unchanged;

        var resolution = credentials.resolveForProvider(
            alloc,
            self.oauth_transport,
            self.secret_store,
            .stored,
            provider,
            preferred,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failed = .{
                .source = requestedSource(provider, preferred) orelse .fx_login,
                .err = err,
            } };
        };
        defer if (resolution.credential) |*credential| credential.deinit(alloc);
        if (resolution.credential) |*credential| {
            return if (self.adoptCredential(alloc, credential)) .selected else .unchanged;
        }
        if (resolution.failure) |failure| return .{ .failed = failure };
        return .missing;
    }

    pub fn beginPromptCredentialRefresh(self: *Self) PromptCredentialRefreshStart {
        if (self.auth_mode == .host_managed) return .not_needed;
        if (self.prompt_credential_refresh_task != null) return .pending;
        const credential = self.selected_credential orelse return .not_needed;
        if (!credentials.sourceRefreshable(credential.source)) return .not_needed;
        self.prompt_credential_refresh_task = PromptCredentialRefreshTask.start(
            self.oauth_transport,
            credential.source,
            credential.accountId(),
        ) catch return .failed;
        return .started;
    }

    pub fn pollPromptCredentialRefresh(self: *Self) PromptCredentialRefreshPoll {
        const task = self.prompt_credential_refresh_task orelse return .idle;
        if (!task.poll()) return .pending;
        self.prompt_credential_refresh_task = null;
        return task.takeResult();
    }

    pub fn cancelPromptCredentialRefresh(self: *Self) void {
        const task = self.prompt_credential_refresh_task orelse return;
        self.prompt_credential_refresh_task = null;
        task.deinit();
    }

    /// Starts resolving the launch credential on a worker. Returns false when
    /// the worker cannot start; the caller then resolves the credential inline.
    pub fn beginStartupCredentialLoad(self: *Self, request: StartupCredentialRequest) bool {
        // Single-threaded builds have no worker; the caller resolves inline.
        if (comptime builtin.single_threaded) return false;
        std.debug.assert(self.startup_credential_task == null);
        self.startup_credential_task = StartupCredentialTask.start(self.secret_store, request) catch |err| {
            debug_trace.logf("auth", "startup credential worker unavailable err={s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    /// Probing every source loads the Keychain framework, and the launch only
    /// needs the inventory for onboarding, so an active credential lets the
    /// probe wait until after the first frame.
    pub fn deferStartupSourceInventory(self: *Self) void {
        self.startup_inventory_deferred = true;
    }

    /// Returns true once when the deferred launch inventory is due.
    pub fn takeDeferredStartupSourceInventory(self: *Self) bool {
        const deferred = self.startup_inventory_deferred;
        self.startup_inventory_deferred = false;
        return deferred;
    }

    pub fn startupCredentialPending(self: *const Self) bool {
        return self.startup_credential_task != null;
    }

    /// Returns the finished launch credential lookup once; null while it runs.
    pub fn takeStartupCredentialLoad(self: *Self) ?StartupCredentialOutcome {
        const task = self.startup_credential_task orelse return null;
        if (!task.done.load(.acquire)) return null;
        self.startup_credential_task = null;
        return task.takeOutcome();
    }

    pub fn refreshSelectedCredentialIfNeeded(
        self: *Self,
        alloc: Allocator,
    ) !auth_transition.CredentialChange {
        const source = self.credentialSource() orelse return .none;
        if (!credentials.sourceRefreshable(source)) return .none;

        const loaded = (try credentials.loadSource(alloc, self.oauth_transport, self.secret_store, source)) orelse {
            if (self.credentialNeedsRefresh()) return error.CredentialRefreshUnavailable;
            return .none;
        };
        var credential = loaded;
        defer credential.deinit(alloc);
        return self.adoptPreparedCredential(alloc, &credential);
    }

    /// Drops the current selection and re-runs precedence after the user clears
    /// a remembered credential source.
    pub fn reselectByPrecedence(self: *Self, alloc: Allocator) !bool {
        return self.reselectByPrecedenceWithDeps(alloc, self, probeCredentialSource, loadRuntimeCredentialSource);
    }

    fn reselectByPrecedenceWithDeps(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
        loader: CredentialLoaderFn,
    ) !bool {
        const previous = self.credentialSource();
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.selected_credential = null;
        self.credential_failure = null;

        try self.refreshSourceInventoryWithProbe(alloc, ctx, probe);
        for (credential_source_order) |source| {
            if (source == .chatgpt_subscription or source == .grok_subscription) continue;
            if (!self.source_inventory.contains(source)) continue;
            if (try self.selectSourceWithLoader(alloc, source, ctx, loader) != null) {
                return self.credentialSource() != previous;
            }
            self.source_inventory.remove(source);
        }
        self.onboarding_skipped = false;
        return previous != null;
    }

    pub fn reconcileAfterChatGptLogout(self: *Self, alloc: Allocator) !bool {
        const was_available = self.source_inventory.contains(.chatgpt_subscription);
        const was_active = self.credentialSource() == .chatgpt_subscription;
        if (was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_failure = null;
        }
        try self.refreshSourceInventory(alloc);
        return was_active or was_available;
    }

    pub fn reconcileAfterGrokLogout(self: *Self, alloc: Allocator) !bool {
        const was_available = self.source_inventory.contains(.grok_subscription);
        const was_active = self.credentialSource() == .grok_subscription;
        if (was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_failure = null;
        }
        try self.refreshSourceInventory(alloc);
        return was_active or was_available;
    }

    pub fn reconcileAfterFxLoginLogout(self: *Self, alloc: Allocator) !bool {
        return self.reconcileAfterFxLoginLogoutWithDeps(
            alloc,
            self,
            probeCredentialSource,
            loadRuntimeCredentialSource,
        );
    }

    fn reconcileAfterFxLoginLogoutWithDeps(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
        loader: CredentialLoaderFn,
    ) !bool {
        const login_was_active = self.credentialSource() == .fx_login;
        if (login_was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_failure = null;
        }

        try self.refreshSourceInventoryWithProbe(alloc, ctx, probe);
        if (!login_was_active) return false;

        for (credential_source_order) |source| {
            if (source == .chatgpt_subscription or source == .grok_subscription) continue;
            if (!self.source_inventory.contains(source)) continue;
            if (try self.selectSourceWithLoader(alloc, source, ctx, loader) != null) return true;
            self.source_inventory.remove(source);
        }

        self.onboarding_skipped = false;
        return true;
    }

    fn currentTeamChoice(self: *const Self) ?Choice {
        const picker = self.pickerView();
        for (picker.teams, 0..) |_, index| {
            if (picker.teamIsCurrent(index)) return .{ .team = index };
        }
        return null;
    }

    fn clearTeamSelection(self: *Self, alloc: Allocator) void {
        if (self.provider_preparation) |task| {
            if (task.input.intent == .team) task.requestCancel();
        }
        if (self.team_selection) |*selection| selection.deinit(alloc);
        self.team_selection = null;
        self.team_query.clearRetainingCapacity();
    }

    fn resetTeamPickerSelection(self: *Self) void {
        self.picker_selection = if (self.team_query.items.len == 0)
            self.currentTeamChoice() orelse self.pickerView().choiceAt(0)
        else
            self.pickerView().choiceAt(0);
    }

    fn exitApiKeyStage(self: *Self, alloc: Allocator, reason: ApiKeyExitReason) void {
        self.api_key_inline = false;
        const byte_count = self.api_key_input.items.len;
        if (self.api_key_input.capacity > 0) {
            const allocated = self.api_key_input.allocatedSlice();
            secret.zeroAndFree(alloc, allocated);
            self.api_key_input = .empty;
        }
        self.api_key_returns_to_root = false;
        if (byte_count > 0) {
            debug_trace.logf(
                "auth",
                "api key entry cleared reason={s} bytes={d}",
                .{ @tagName(reason), byte_count },
            );
        }
    }
};

fn probeCredentialSource(raw_context: ?*anyopaque, _: Allocator, source: credentials.Source) !bool {
    const self: *Runtime = @ptrCast(@alignCast(raw_context.?));
    if (self.auth_mode == .host_managed) return false;
    return switch (credentials.sourcePresence(self.secret_store, source)) {
        .present => true,
        .missing => false,
        .unavailable => error.CredentialStorageUnavailable,
    };
}

fn loadCredentialSource(_: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
    return credentials.loadSource(
        alloc,
        oauth_transport.unavailable_provider,
        host.unavailable_secret_store,
        source,
    );
}

fn loadRuntimeCredentialSource(raw: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    // Interactive selection paths run on keypresses; a source whose refresh
    // the issuer rejects must read as "unavailable" (the callers all explain
    // that), not ride a `try` chain out of the event loop. `resolve()` keeps
    // its own error handling for startup status reporting.
    return credentials.loadSource(alloc, self.oauth_transport, self.secret_store, source) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => {
            debug_trace.logf("auth", "credential load failed source={t} err={s}", .{ source, @errorName(err) });
            return null;
        },
    };
}

fn storeRuntimeSecret(raw: ?*anyopaque, alloc: Allocator, value: []const u8) !void {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    return self.secret_store.store(alloc, value);
}

fn storeUnavailableSecret(_: ?*anyopaque, _: Allocator, _: []const u8) !void {
    return error.StoredKeyWriteFailed;
}

fn displayTeam(credential: credentials.Credential) ?[]const u8 {
    return credential.team_slug orelse credential.team_id;
}

fn takeDisplayTeam(alloc: Allocator, credential: *credentials.Credential) ?[]u8 {
    if (credential.team_slug) |team| {
        credential.team_slug = null;
        if (credential.team_id) |id| alloc.free(id);
        credential.team_id = null;
        return team;
    }
    const team = credential.team_id;
    credential.team_id = null;
    return team;
}

fn gatewaySourceCount(sources: SourceSet) usize {
    var count: usize = 0;
    for (credential_source_order) |source| {
        if (source == .chatgpt_subscription or source == .grok_subscription or !sources.contains(source)) continue;
        count += 1;
    }
    return count;
}

fn gatewaySourceAtIndex(sources: SourceSet, wanted_index: usize) ?credentials.Source {
    var index: usize = 0;
    for (credential_source_order) |source| {
        if (source == .chatgpt_subscription or source == .grok_subscription or !sources.contains(source)) continue;
        if (index == wanted_index) return source;
        index += 1;
    }
    return null;
}

fn credentialAuthorityFacts(credential: credentials.Credential) auth_transition.CredentialAuthorityFacts {
    return .{
        .provider = switch (credential.source) {
            .chatgpt_subscription => .codex,
            .grok_subscription => .grok,
            else => .gateway,
        },
        .source = credential.source,
        .account_id = credential.accountId(),
        .team = credential.gatewayTeam(),
    };
}

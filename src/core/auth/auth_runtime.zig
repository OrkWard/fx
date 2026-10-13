const std = @import("std");
const auth_transition = @import("auth_transition.zig");
const credentials = @import("credentials.zig");
const chatgpt_oauth = @import("chatgpt_oauth.zig");
const grok_oauth = @import("grok_oauth.zig");
const login_flow = @import("login_flow.zig");
const model_provider = @import("../config/model_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_catalog = @import("provider_catalog.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const SourceSet = std.EnumSet(credentials.Source);

pub const CredentialRefreshMode = enum {
    if_needed,
    force,
};

const credential_source_order = [_]credentials.Source{
    .chatgpt_subscription,
    .grok_subscription,
};

const SourceProbeFn = *const fn (?*anyopaque, Allocator, credentials.Source) anyerror!bool;

const max_manual_code_mask_glyphs: usize = 32;

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
        .chatgpt_subscription => switch (mode) {
            .if_needed => credentials.loadSource(alloc, transport, source),
            .force => credentials.refreshChatGptCredential(alloc, transport),
        },
        .grok_subscription => switch (mode) {
            .if_needed => credentials.loadSource(alloc, transport, source),
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
/// failures stay errors.
pub fn prepareCredential(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    provider: model_provider.ProviderId,
) CredentialPreparationError!?credentials.Credential {
    var resolution = credentials.resolveForProvider(
        alloc,
        transport,
        .refresh_if_needed,
        provider,
    ) catch |err| failure: {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf(
            "auth",
            "credential preparation failed provider={t} source={s} err={s}",
            .{ provider, @tagName(requestedSource(provider)), @errorName(err) },
        );
        break :failure credentials.Resolution{ .failure = .{
            .source = requestedSource(provider),
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
        return null;
    };
    resolution.credential = null;

    const blocked = (credential.token.len == 0 and !(provider == .configured and credential.source == .configured)) or
        !model_provider.authorizesCredential(provider, credential.source) or
        credential.needsRefreshAt(now_ms) or
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

pub fn requestedSource(provider: model_provider.ProviderId) credentials.Source {
    return provider_catalog.find(provider).login_source;
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
    chatgpt_login,
    grok_login,
    switch_provider,
};

pub const PickerStage = enum {
    root,
    connections,
    provider,
    sign_in,
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

pub const ProviderPreparationIntent = union(enum) {
    provider: struct {
        target: model_provider.ProviderId,
        allow_login: bool,
        origin: auth_transition.ProviderSwitchIntent,
        fallback: ?model_provider.ProviderId = null,
    },
};

pub const ProviderPreparationInput = struct {
    intent: ProviderPreparationIntent,
    catalog_provider: model_catalog.Provider,
    models_path: []const u8,
    primary_model: ?[]const u8 = null,
    preferred_model: ?[]const u8 = null,

    pub fn target(self: ProviderPreparationInput) model_provider.ProviderId {
        return self.intent.provider.target;
    }
};

/// Owns the preparation inputs and outcome until the event loop consumes it.
/// Provider capabilities must outlive the task. Only the worker writes results;
/// the main thread reads them after the release/acquire completion and join.
pub const ProviderPreparation = struct {
    alloc: Allocator,
    input: ProviderPreparationInput,
    transport: oauth_transport.Provider,
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
            .host_managed = runtime.isHostManaged(),
        };
        self.input.primary_model = null;
        self.input.preferred_model = null;
        self.input.models_path = "";
        errdefer self.deinit();
        self.input.models_path = try alloc.dupe(u8, input.models_path);
        if (input.primary_model) |value| self.input.primary_model = try alloc.dupe(u8, value);
        if (input.preferred_model) |value| self.input.preferred_model = try alloc.dupe(u8, value);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *ProviderPreparation) void {
        defer self.done.store(true, .release);
        if (self.cancel_requested.load(.seq_cst)) return;
        if (!self.host_managed) {
            self.credential = prepareCredential(
                self.alloc,
                .{ .context = self, .execute_fn = executeCancellable },
                self.input.target(),
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

const ManualCodeClearReason = enum {
    cancel,
    submitted,
    screen_replacement,
    runtime_deinit,
};

pub const Choice = union(enum) {
    provider: model_provider.ProviderId,
    action: AcquisitionAction,

    pub fn eql(self: Choice, other: Choice) bool {
        return switch (self) {
            .provider => |provider| other == .provider and provider.eql(other.provider),
            .action => |action| other == .action and action == other.action,
        };
    }
};

pub const PickerView = struct {
    active: bool,
    available_sources: SourceSet,
    unavailable_sources: SourceSet = .empty,
    selected_choice: ?Choice,
    active_source: ?credentials.Source,
    active_provider: model_provider.ProviderId = .codex,
    include_skip: bool,
    stage: PickerStage = .root,
    sign_in: login_flow.SignInSnapshot = .{},
    sign_in_source: credentials.Source = .chatgpt_subscription,
    sign_in_code_visible: bool = false,
    sign_in_code_mask_count: usize = 0,

    pub fn activeSourceLabel(self: PickerView) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn choiceCount(self: PickerView) usize {
        return switch (self.stage) {
            .root => if (self.include_skip) connection_choices.len else 2,
            .connections => connection_choices.len,
            .provider => 2,
            .sign_in => 0,
        };
    }

    pub fn choiceAt(self: PickerView, index: usize) ?Choice {
        return switch (self.stage) {
            .root => if (self.include_skip) connectionChoiceAt(index) else switch (index) {
                0 => .{ .action = .connections },
                1 => .{ .action = .switch_provider },
                else => null,
            },
            .connections => connectionChoiceAt(index),
            .provider => switch (index) {
                0 => .{ .provider = .codex },
                1 => .{ .provider = .grok },
                else => null,
            },
            .sign_in => null,
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

    pub fn choiceLabel(_: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .provider => |provider| provider_catalog.label(provider),
            .action => |action| switch (action) {
                .connections => "Connections",
                .chatgpt_login => "Sign in with Codex",
                .grok_login => "Sign in with Grok",
                .switch_provider => "Switch provider",
            },
        };
    }

    pub fn choiceDescription(self: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .provider => |provider| if (provider.eql(self.active_provider)) "current" else "available",
            .action => |action| switch (action) {
                .chatgpt_login => if (self.available_sources.contains(.chatgpt_subscription)) "connected" else "",
                .grok_login => if (self.available_sources.contains(.grok_subscription)) "connected" else "",
                .connections, .switch_provider => "",
            },
        };
    }

    pub fn choiceEnabled(_: PickerView, _: Choice) bool {
        return true;
    }
};

const connection_choices = [_]AcquisitionAction{ .chatgpt_login, .grok_login };

fn connectionChoiceAt(index: usize) ?Choice {
    if (index >= connection_choices.len) return null;
    return .{ .action = connection_choices[index] };
}

pub const MissingHelpSurface = enum {
    cli,
    interactive,
};

pub const StatusSnapshot = struct {
    active_source: ?credentials.Source = null,
    required_source: ?credentials.Source = null,
    failure: ?CredentialFailure = null,
    chatgpt_connected: bool = false,
    grok_connected: bool = false,
    /// The active credential is past its refresh deadline. Distinct from `refreshable`,
    /// which answers whether this source type can refresh at all.
    expired: bool = false,

    pub fn activeSourceLabel(self: StatusSnapshot) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn refreshable(self: StatusSnapshot) bool {
        const source = self.active_source orelse return false;
        return credentials.sourceRefreshable(source);
    }

    pub fn missingHelp(self: StatusSnapshot, surface: MissingHelpSurface) ?[]const u8 {
        if (self.active_source != null) return null;
        if (self.failure) |failure| {
            if (preparationError(failure)) |err| return preparationFailureNotice(err);
        }
        const required_source = self.required_source orelse return "No provider credential is available.";
        return switch (required_source) {
            .chatgpt_subscription => switch (surface) {
                .cli => credentials.missing_chatgpt_credential_message,
                .interactive => credentials.missing_chatgpt_interactive_credential_message,
            },
            .grok_subscription => switch (surface) {
                .cli => credentials.missing_grok_credential_message,
                .interactive => credentials.missing_grok_interactive_credential_message,
            },
            .host_managed => "No provider credential is available.",
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
        return try out.toOwnedSlice();
    }
};

pub fn loadStatusSnapshotForProvider(
    alloc: Allocator,
    provider: model_provider.ProviderId,
) !StatusSnapshot {
    const chatgpt_connected = credentials.sourceExists(alloc, .chatgpt_subscription) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    const grok_connected = credentials.sourceExists(alloc, .grok_subscription) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    // Resolves in `.stored` mode: a diagnostic must not refresh, because refreshing
    // rewrites the session file and performs network I/O.
    const resolution = credentials.resolveForProvider(
        alloc,
        oauth_transport.unavailable_provider,
        .stored,
        provider,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => blk: {
            debug_trace.logf("auth", "status snapshot failed step=resolve err={s}", .{@errorName(err)});
            break :blk credentials.Resolution{};
        },
    };
    if (resolution.credential) |loaded| {
        var credential = loaded;
        defer credential.deinit(alloc);
        return .{
            .active_source = credential.source,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
            .expired = credential.needsRefreshAt(io_mod.milliTimestamp()),
        };
    }
    return .{
        .required_source = requestedSource(provider),
        .failure = if (resolution.failure) |failure| classifyCredentialFailure(failure.source, failure.err) else null,
        .chatgpt_connected = chatgpt_connected,
        .grok_connected = grok_connected,
    };
}

pub const View = struct {
    active_source: ?credentials.Source,
    available_inactive_sources: SourceSet,
    refreshable: bool,
    onboarding_skipped: bool,

    pub fn activeSourceLabel(self: View) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }
};

pub const ProviderCredentialSelection = union(enum) {
    unchanged,
    selected,
    missing,
    failed: credentials.LoadFailure,
};

pub const Runtime = struct {
    const Self = @This();

    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
    auth_mode: credentials.AuthMode = .local,
    selected_credential: ?credentials.Credential = null,
    credential_failure: ?struct {
        failure: CredentialFailure,
        notice_claimed: bool,
    } = null,
    source_inventory: SourceSet = .empty,
    unavailable_sources: SourceSet = .empty,
    onboarding_skipped: bool = false,
    picker_active: bool = false,
    picker_selection: ?Choice = null,
    picker_include_skip: bool = false,
    picker_stage: PickerStage = .root,
    provider_picker_active: model_provider.ProviderId = .codex,
    sign_in_flow: login_flow.SignInRuntime = .{},
    sign_in_source: credentials.Source = .chatgpt_subscription,
    sign_in_returns_to_root: bool = false,
    sign_in_code_visible: bool = false,
    sign_in_code_input: std.ArrayList(u8) = .empty,
    inventory_refresh_task: ?*InventoryRefreshTask = null,
    prompt_credential_refresh_task: ?*PromptCredentialRefreshTask = null,
    provider_preparation: ?*ProviderPreparation = null,
    /// The launch source inventory waits for the first frame.
    startup_inventory_deferred: bool = false,

    pub fn init(transport: oauth_transport.Provider, auth_mode: credentials.AuthMode) Self {
        return .{ .oauth_transport = transport, .auth_mode = auth_mode };
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.stopProviderPreparation();
        if (self.inventory_refresh_task) |task| task.deinit();
        self.inventory_refresh_task = null;
        if (self.prompt_credential_refresh_task) |task| task.deinit();
        self.prompt_credential_refresh_task = null;
        self.sign_in_flow.deinit(alloc);
        self.clearSignInCodeInput(alloc, .runtime_deinit);
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.* = .{};
    }

    /// Borrows the current credential token until this runtime replaces or releases it.
    pub fn apiKey(self: *const Self) ?[]const u8 {
        if (self.auth_mode == .host_managed) return null;
        const credential = self.selected_credential orelse return null;
        if (credential.needsRefreshAt(io_mod.milliTimestamp())) return null;
        return credential.token;
    }

    pub fn hasUsableCredential(self: *const Self) bool {
        return self.auth_mode == .host_managed or self.apiKey() != null;
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

    pub fn credentialNeedsRefresh(self: *const Self) bool {
        return self.credentialNeedsRefreshAt(io_mod.milliTimestamp());
    }

    fn credentialNeedsRefreshAt(self: *const Self, now_ms: i64) bool {
        const credential = self.selected_credential orelse return false;
        return credential.needsRefreshAt(now_ms);
    }

    pub fn statusSnapshot(self: *const Self, provider: model_provider.ProviderId) StatusSnapshot {
        if (self.auth_mode == .host_managed) return .{
            .active_source = .host_managed,
            .chatgpt_connected = true,
            .grok_connected = true,
        };
        const chatgpt_connected = self.source_inventory.contains(.chatgpt_subscription);
        const grok_connected = self.source_inventory.contains(.grok_subscription);
        const credential = self.selected_credential orelse return .{
            .required_source = requestedSource(provider),
            .failure = if (self.credential_failure) |episode|
                if (model_provider.authorizesCredential(provider, episode.failure.source)) episode.failure else null
            else
                null,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
        };
        return .{
            .active_source = credential.source,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
            .expired = credential.needsRefreshAt(io_mod.milliTimestamp()),
        };
    }

    pub fn view(self: *const Self) View {
        const active_source = self.credentialSource();
        var available_inactive_sources = self.source_inventory;
        if (active_source) |source| available_inactive_sources.remove(source);
        return .{
            .active_source = active_source,
            .available_inactive_sources = available_inactive_sources,
            .refreshable = if (active_source) |source| credentials.sourceRefreshable(source) else false,
            .onboarding_skipped = self.onboarding_skipped,
        };
    }

    pub fn recordStartupStatus(
        self: *Self,
        load_failure: ?credentials.LoadFailure,
        onboarding_skipped: bool,
    ) void {
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
        if (try credentials.sourceExists(alloc, .chatgpt_subscription)) {
            self.source_inventory.insert(.chatgpt_subscription);
        } else if (self.credentialSource() != .chatgpt_subscription) {
            self.source_inventory.remove(.chatgpt_subscription);
        }
    }

    pub fn refreshGrokSourceInventory(self: *Self, alloc: Allocator) !void {
        if (self.auth_mode == .host_managed) return;
        if (try credentials.sourceExists(alloc, .grok_subscription)) {
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
            .sign_in = self.sign_in_flow.snapshot(),
            .sign_in_source = self.sign_in_source,
            .sign_in_code_visible = self.sign_in_code_visible,
            .sign_in_code_mask_count = @min(self.sign_in_code_input.items.len, max_manual_code_mask_glyphs),
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

    fn openConnectionPicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
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
        self.picker_active = true;
        self.picker_include_skip = false;
        self.picker_stage = .provider;
        self.provider_picker_active = active_provider;
        self.picker_selection = .{ .provider = active_provider };
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
            .chatgpt_subscription => try chatgpt_oauth.startSignIn(&self.sign_in_flow, alloc, self.oauth_transport),
            .grok_subscription => try grok_oauth.startSignIn(&self.sign_in_flow, alloc, self.oauth_transport),
            else => return error.InvalidSignInSource,
        };
        if (!started) return false;
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

    pub fn popPickerStage(self: *Self, alloc: Allocator) bool {
        if (!self.picker_active) return false;
        switch (self.picker_stage) {
            .root => self.closePicker(alloc),
            .provider => {
                self.picker_stage = .root;
                self.picker_selection = .{ .action = .switch_provider };
            },
            .connections => {
                self.picker_stage = .root;
                self.picker_selection = .{ .action = .connections };
            },
            .sign_in => {
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
                self.picker_stage = if (self.picker_include_skip) .root else .connections;
                self.picker_selection = .{ .action = if (self.sign_in_source == .grok_subscription) .grok_login else .chatgpt_login };
            },
        }
        return true;
    }

    pub fn closePicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.picker_active = false;
        self.picker_stage = .root;
    }

    pub fn takePickerChoice(self: *Self, alloc: Allocator) ?Choice {
        if (!self.picker_active) return null;
        if (self.picker_stage == .sign_in) return null;
        const choice = self.picker_selection;
        const selected = choice orelse return null;
        switch (selected) {
            .provider => self.closePicker(alloc),
            .action => |action| switch (action) {
                .connections => {
                    self.openConnectionPicker(alloc);
                    return null;
                },
                .switch_provider => {},
                .chatgpt_login, .grok_login => self.closePicker(alloc),
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
        self.source_inventory.insert(source);
        self.unavailable_sources.remove(source);
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

    pub fn selectForProvider(
        self: *Self,
        alloc: Allocator,
        provider: model_provider.ProviderId,
    ) Allocator.Error!ProviderCredentialSelection {
        if (self.auth_mode == .host_managed or
            (provider != .configured and model_provider.authorizesCredential(provider, self.credentialSource()))) return .unchanged;

        var resolution = credentials.resolveForProvider(
            alloc,
            self.oauth_transport,
            .stored,
            provider,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failed = .{
                .source = requestedSource(provider),
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

    pub fn refreshSelectedCredentialIfNeeded(
        self: *Self,
        alloc: Allocator,
    ) !auth_transition.CredentialChange {
        const source = self.credentialSource() orelse return .none;
        if (!credentials.sourceRefreshable(source)) return .none;

        const loaded = (try credentials.loadSource(alloc, self.oauth_transport, source)) orelse {
            if (self.credentialNeedsRefresh()) return error.CredentialRefreshUnavailable;
            return .none;
        };
        var credential = loaded;
        defer credential.deinit(alloc);
        return self.adoptPreparedCredential(alloc, &credential);
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
};

fn probeCredentialSource(raw_context: ?*anyopaque, _: Allocator, source: credentials.Source) !bool {
    const self: *Runtime = @ptrCast(@alignCast(raw_context.?));
    if (self.auth_mode == .host_managed) return false;
    return switch (credentials.sourcePresence(source)) {
        .present => true,
        .missing => false,
        .unavailable => error.CredentialStorageUnavailable,
    };
}

fn credentialAuthorityFacts(credential: credentials.Credential) auth_transition.CredentialAuthorityFacts {
    return .{
        .provider = switch (credential.source) {
            .chatgpt_subscription => .codex,
            .grok_subscription => .grok,
            else => .codex,
        },
        .source = credential.source,
        .account_id = credential.accountId(),
    };
}

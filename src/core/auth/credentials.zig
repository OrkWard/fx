const std = @import("std");
const builtin = @import("builtin");
const chatgpt_oauth = @import("chatgpt_oauth.zig");
const chatgpt_session = @import("chatgpt_session.zig");
const grok_oauth = @import("grok_oauth.zig");
const grok_session = @import("grok_session.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_catalog = @import("provider_catalog.zig");
const oauth = @import("oauth.zig");
const oauth_session = @import("oauth_session.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const types = @import("../shared/types.zig");

pub const Source = types.CredentialSource;

pub const AuthMode = enum {
    local,
    host_managed,
};

pub const AuthModeError = error{InvalidAuthMode};

pub fn parseAuthMode(value: ?[]const u8) AuthModeError!AuthMode {
    const raw = value orelse return .local;
    if (std.mem.eql(u8, raw, "local")) return .local;
    if (std.mem.eql(u8, raw, "host-managed")) return .host_managed;
    return error.InvalidAuthMode;
}

pub const CatalogPublicOnly = union(enum) {
    no_credential,
    fx_login_team_required,
    fx_login_refresh_required,
    credential_refresh_required: Source,
    credential_refresh_failed: Source,
    authenticated_credential_rejected: Source,
    chatgpt_subscription,
    grok_subscription,

    fn credentialSource(self: CatalogPublicOnly) ?Source {
        return switch (self) {
            .no_credential => null,
            .fx_login_team_required, .fx_login_refresh_required => .fx_login,
            .credential_refresh_required => |source| source,
            .credential_refresh_failed => |source| source,
            .authenticated_credential_rejected => |source| source,
            .chatgpt_subscription => .chatgpt_subscription,
            .grok_subscription => .grok_subscription,
        };
    }
};

pub const CatalogPublicOnlyReason = std.meta.Tag(CatalogPublicOnly);

pub const CatalogAuthenticatedSource = enum {
    vercel_oidc_token,
    ai_gateway_api_key,
    fx_login,
    stored_key,
    chatgpt_subscription,
    grok_subscription,

    fn credentialSource(self: CatalogAuthenticatedSource) Source {
        return switch (self) {
            .vercel_oidc_token => .vercel_oidc_token,
            .ai_gateway_api_key => .ai_gateway_api_key,
            .fx_login => .fx_login,
            .stored_key => .stored_key,
            .chatgpt_subscription => .chatgpt_subscription,
            .grok_subscription => .grok_subscription,
        };
    }
};

const CatalogAuthority = enum {
    automatic,
    explicit,
};

/// A borrowed authorization decision for one model-catalog request. Public-only
/// states cannot carry credential or team bytes; authenticated states carry the
/// only values the request is allowed to send.
pub const CatalogAccess = union(enum) {
    public_only: CatalogPublicOnly,
    authenticated: struct {
        source: CatalogAuthenticatedSource,
        credential: []const u8,
        team_context: ?[]const u8,
        account_id: ?[]const u8 = null,
        authority: CatalogAuthority = .automatic,
    },
    host_managed,

    pub fn credentialSource(self: CatalogAccess) ?Source {
        return switch (self) {
            .public_only => |access| access.credentialSource(),
            .authenticated => |access| access.source.credentialSource(),
            .host_managed => .host_managed,
        };
    }

    pub fn publicOnlyReason(self: CatalogAccess) ?CatalogPublicOnlyReason {
        const access = self.publicOnly() orelse return null;
        return std.meta.activeTag(access);
    }

    pub fn publicOnly(self: CatalogAccess) ?CatalogPublicOnly {
        return switch (self) {
            .public_only => |access| access,
            .authenticated, .host_managed => null,
        };
    }

    pub fn publicFallbackAfterRejection(self: CatalogAccess) ?CatalogAccess {
        return switch (self) {
            .public_only => null,
            .authenticated => |access| if (access.authority == .explicit or
                access.source == .chatgpt_subscription or
                access.source == .grok_subscription)
                null
            else
                .{
                    .public_only = .{
                        .authenticated_credential_rejected = access.source.credentialSource(),
                    },
                },
            .host_managed => null,
        };
    }

    pub fn withExplicitAuthority(self: CatalogAccess) CatalogAccess {
        return switch (self) {
            .public_only => |access| .{ .public_only = access },
            .authenticated => |access| .{ .authenticated = .{
                .source = access.source,
                .credential = access.credential,
                .team_context = access.team_context,
                .account_id = access.account_id,
                .authority = .explicit,
            } },
            .host_managed => .host_managed,
        };
    }

    pub fn authorizationCredential(self: CatalogAccess) ?[]const u8 {
        return switch (self) {
            .public_only => null,
            .authenticated => |access| access.credential,
            .host_managed => null,
        };
    }

    pub fn teamContext(self: CatalogAccess) ?[]const u8 {
        const team = switch (self) {
            .public_only => return null,
            .authenticated => |access| access.team_context orelse return null,
            .host_managed => return null,
        };
        return if (team.len > 0) team else null;
    }

    pub fn accountId(self: CatalogAccess) ?[]const u8 {
        const account_id = switch (self) {
            .public_only => return null,
            .authenticated => |access| access.account_id orelse return null,
            .host_managed => return null,
        };
        return if (account_id.len > 0) account_id else null;
    }
};

pub fn catalogAccessAt(credential: ?Credential, now_ms: i64) CatalogAccess {
    const selected = credential orelse return .{ .public_only = .no_credential };
    if (selected.source == .fx_login and selected.needsRefreshAt(now_ms)) {
        return .{ .public_only = .fx_login_refresh_required };
    }
    if (sourceRefreshable(selected.source) and selected.needsRefreshAt(now_ms)) {
        return .{ .public_only = .{ .credential_refresh_required = selected.source } };
    }
    return catalogAccessForCredentialAndAccount(
        selected.source,
        selected.token,
        selected.gatewayTeam(),
        selected.accountId(),
    );
}

pub fn catalogAccessAfterRefreshFailure(source: Source) CatalogAccess {
    return .{
        .public_only = .{
            .credential_refresh_failed = source,
        },
    };
}

pub fn catalogAccessForCredential(
    source: ?Source,
    credential: []const u8,
    team_context: ?[]const u8,
) CatalogAccess {
    return catalogAccessForCredentialAndAccount(source, credential, team_context, null);
}

pub fn catalogAccessForCredentialAndAccount(
    source: ?Source,
    credential: []const u8,
    team_context: ?[]const u8,
    account_id: ?[]const u8,
) CatalogAccess {
    const selected_source = source orelse return .{ .public_only = .no_credential };
    if (selected_source == .host_managed) return .host_managed;
    const authenticated_source: CatalogAuthenticatedSource = switch (selected_source) {
        .vercel_oidc_token => .vercel_oidc_token,
        .ai_gateway_api_key => .ai_gateway_api_key,
        .stored_key => .stored_key,
        .chatgpt_subscription => .chatgpt_subscription,
        .grok_subscription => .grok_subscription,
        .host_managed => unreachable,
        .configured => return .{ .public_only = .no_credential },
        .fx_login => blk: {
            const team = team_context orelse
                return .{ .public_only = .fx_login_team_required };
            if (!types.validGatewayTeam(team))
                return .{ .public_only = .fx_login_team_required };
            break :blk .fx_login;
        },
    };
    return .{
        .authenticated = .{
            .source = authenticated_source,
            .credential = credential,
            .team_context = if (authenticated_source == .chatgpt_subscription or authenticated_source == .grok_subscription) null else team_context,
            .account_id = if (authenticated_source == .grok_subscription) account_id else null,
        },
    };
}

/// Current native product copy. Store mechanics and availability come from the
/// injected host port; Core retains the stable user-facing source name.
pub const stored_key_backend_label = if (builtin.target.os.tag == .macos) "macOS Keychain" else "profile file";

/// Both modes resolve the same source set; the mode selects only whether an expired
/// fx login session is refreshed first.
pub const LoadMode = enum { stored, refresh_if_needed };

const FxLoginRefreshMode = enum { if_needed, force };

pub const missing_credential_message = "fx needs access to Vercel AI Gateway. Run fx login to sign in, fx setup to use an API key, or set AI_GATEWAY_API_KEY.";
pub const missing_interactive_credential_message = "fx needs access to Vercel AI Gateway. Run /login to sign in, /provider to use an API key, or set AI_GATEWAY_API_KEY.";
pub const missing_chatgpt_credential_message = "fx needs a Codex subscription login for this model. Run fx login codex.";
pub const missing_chatgpt_interactive_credential_message = "Codex needs a subscription login. Run /login, open Connections, then choose Codex subscription.";
pub const missing_grok_credential_message = "fx needs a Grok subscription login for this model. Run fx login grok.";
pub const missing_grok_interactive_credential_message = "Grok needs a subscription login. Run /login, open Connections, then choose Grok subscription.";
pub const unreadable_store_message = "fx could not read the stored API key from " ++ stored_key_backend_label ++ ". A key may be saved but unreadable. Set FX_TRACE_LOG for the failing step, or set AI_GATEWAY_API_KEY.";
pub const host_managed_auth_message = "Authentication is managed by the host.";

pub const Credential = struct {
    token: []u8,
    source: Source,
    account_id: ?[]u8 = null,
    team_id: ?[]u8 = null,
    team_slug: ?[]u8 = null,
    refresh_after_ms: ?i64 = null,

    pub fn clone(self: Credential, alloc: std.mem.Allocator) !Credential {
        const token = try alloc.dupe(u8, self.token);
        errdefer secret.zeroAndFree(alloc, token);
        const account_id = if (self.account_id) |value| try alloc.dupe(u8, value) else null;
        errdefer if (account_id) |value| alloc.free(value);
        const team_id = if (self.team_id) |value| try alloc.dupe(u8, value) else null;
        errdefer if (team_id) |value| alloc.free(value);
        const team_slug = if (self.team_slug) |value| try alloc.dupe(u8, value) else null;
        errdefer if (team_slug) |value| alloc.free(value);
        return .{
            .token = token,
            .source = self.source,
            .account_id = account_id,
            .team_id = team_id,
            .team_slug = team_slug,
            .refresh_after_ms = self.refresh_after_ms,
        };
    }

    pub fn deinit(self: *Credential, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.token);
        if (self.account_id) |account_id| alloc.free(account_id);
        if (self.team_id) |team| alloc.free(team);
        if (self.team_slug) |team| alloc.free(team);
        self.* = undefined;
    }

    pub fn gatewayTeam(self: Credential) ?[]const u8 {
        if (self.team_id) |team| return team;
        return self.team_slug;
    }

    pub fn accountId(self: Credential) ?[]const u8 {
        return self.account_id;
    }

    pub fn needsRefreshAt(self: Credential, now_ms: i64) bool {
        const refresh_after_ms = self.refresh_after_ms orelse return false;
        return refresh_after_ms <= now_ms;
    }
};

pub const StoredKeyReadStatus = enum {
    not_attempted,
    not_found,
    unavailable,
};

/// Why the fx login produced no credential. Only meaningful once resolution has
/// reached the fx-login step and it stayed silent. `unavailable` means the
/// session could not be loaded or its refresh failed, which is different from
/// having no session at all: the login exists and may still be repairable.
pub const FxLoginReadStatus = enum {
    not_attempted,
    absent,
    unavailable,
};

pub const LoadFailure = struct {
    source: Source,
    err: anyerror,
};

pub const Resolution = struct {
    credential: ?Credential = null,
    stored_key_status: StoredKeyReadStatus = .not_attempted,
    fx_login_status: FxLoginReadStatus = .not_attempted,
    failure: ?LoadFailure = null,
};

/// The single credential resolution method. Walks source precedence, then falls back to
/// the stored key, reporting why that store was silent when it produced nothing.
pub fn resolve(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    mode: LoadMode,
) !Resolution {
    return resolvePreferring(alloc, transport, secret_store, mode, null);
}

pub fn resolveForProvider(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    mode: LoadMode,
    provider: model_provider.ProviderId,
    preferred: ?Source,
) !Resolution {
    if (provider == .configured) {
        var registry = try @import("../config/config_runtime.zig").loadConfiguredProviders(alloc);
        defer registry.deinit(alloc);
        const bound = try provider.bind(registry);
        const definition = registry.get(bound.label()).?;
        return switch (definition.auth) {
            .none => .{ .credential = .{ .token = try alloc.dupe(u8, ""), .source = .configured } },
            .bearer => |env| .{ .credential = try loadEnvCredential(alloc, env, .configured) },
        };
    }
    if (provider != .gateway) {
        const source = provider_catalog.find(provider).login_source;
        const credential = loadPreferredSource(alloc, transport, secret_store, mode, source) catch |err| {
            if (err == error.OutOfMemory) return err;
            debug_trace.logf("auth", "provider source load failed source={t} err={s}", .{ source, @errorName(err) });
            return .{ .failure = .{ .source = source, .err = err } };
        };
        return .{ .credential = credential };
    }
    return resolvePreferring(
        alloc,
        transport,
        secret_store,
        mode,
        if (preferred == .chatgpt_subscription or preferred == .grok_subscription) null else preferred,
    );
}

/// `preferred` is the source the user last chose in the hub. It is an exact
/// authority choice, not a precedence hint: absence or refresh failure must not
/// silently select a different billing, account, or team boundary. Only null
/// runs automatic precedence.
pub fn resolvePreferring(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    mode: LoadMode,
    preferred: ?Source,
) !Resolution {
    if (preferred) |source| {
        if (source == .stored_key and secret_store.isDisabled()) {
            debug_trace.logf("auth", "explicit source unavailable source={t} reason=disabled", .{source});
            return .{};
        }

        const chosen = loadPreferredSource(alloc, transport, secret_store, mode, source) catch |err| {
            if (err == error.OutOfMemory) return err;
            debug_trace.logf("auth", "explicit source load failed source={t} err={s}", .{ source, @errorName(err) });
            return unavailableExplicitResolution(source, err);
        };
        if (chosen) |credential| return .{ .credential = credential };
        debug_trace.logf("auth", "explicit source unavailable source={t}", .{source});
        return missingExplicitResolution(source);
    }

    if (try loadSource(alloc, transport, secret_store, .vercel_oidc_token)) |credential| return .{ .credential = credential };
    if (try loadSource(alloc, transport, secret_store, .ai_gateway_api_key)) |credential| return .{ .credential = credential };

    // A login that cannot be loaded or refreshed is one silent source, not a
    // reason to abandon resolution: the sources on either side of it already
    // fall through on failure, and a rejected refresh token must not hide a
    // stored key that works. OutOfMemory stays fatal, as it does for them.
    var fx_login_status: FxLoginReadStatus = .absent;
    var failure: ?LoadFailure = null;
    const fx_login = loadFxLoginForPrecedence(alloc, transport, mode) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        fx_login_status = .unavailable;
        failure = .{ .source = .fx_login, .err = err };
        debug_trace.logf("auth", "fx login load failed mode={t} err={s}; using precedence", .{ mode, @errorName(err) });
        break :blk null;
    };
    if (fx_login) |credential| return .{ .credential = credential };

    if (secret_store.isDisabled()) return .{ .fx_login_status = fx_login_status, .failure = failure };

    var status: StoredKeyReadStatus = .not_found;
    const stored = loadSource(alloc, transport, secret_store, .stored_key) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        status = .unavailable;
        failure = .{ .source = .stored_key, .err = err };
        debug_trace.logf("auth", "stored key load failed err={s} status={t}", .{ @errorName(err), status });
        break :blk null;
    };
    if (stored) |credential| return .{ .credential = credential, .fx_login_status = fx_login_status };
    return .{ .stored_key_status = status, .fx_login_status = fx_login_status, .failure = failure };
}

fn missingExplicitResolution(source: Source) Resolution {
    return switch (source) {
        .fx_login => .{ .fx_login_status = .absent },
        .stored_key => .{ .stored_key_status = .not_found },
        else => .{},
    };
}

fn unavailableExplicitResolution(source: Source, err: anyerror) Resolution {
    var resolution: Resolution = switch (source) {
        .fx_login => .{ .fx_login_status = .unavailable },
        .stored_key => .{ .stored_key_status = .unavailable },
        else => .{},
    };
    resolution.failure = .{ .source = source, .err = err };
    return resolution;
}

fn loadFxLoginForPrecedence(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    mode: LoadMode,
) !?Credential {
    return switch (mode) {
        .stored => loadStoredFxLoginCredential(alloc),
        .refresh_if_needed => loadFxLoginCredential(alloc, transport),
    };
}

/// `loadSource` always refreshes an expired fx login, which `.stored` mode
/// forbids: a diagnostic must not rewrite the session file or make an OAuth
/// request. Honour the mode for the preferred source too.
fn loadPreferredSource(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    mode: LoadMode,
    source: Source,
) !?Credential {
    return switch (source) {
        .fx_login => switch (mode) {
            .stored => loadStoredFxLoginCredential(alloc),
            .refresh_if_needed => loadFxLoginCredential(alloc, transport),
        },
        .chatgpt_subscription => switch (mode) {
            .stored => loadStoredChatGptCredential(alloc),
            .refresh_if_needed => loadChatGptCredential(alloc, transport, .if_needed),
        },
        .grok_subscription => switch (mode) {
            .stored => loadStoredGrokCredential(alloc),
            .refresh_if_needed => loadGrokCredential(alloc, transport, .if_needed),
        },
        else => loadSource(alloc, transport, secret_store, source),
    };
}

pub fn loadSource(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    source: Source,
) !?Credential {
    return switch (source) {
        .vercel_oidc_token => loadEnvCredential(alloc, "VERCEL_OIDC_TOKEN", source),
        .ai_gateway_api_key => loadEnvCredential(alloc, "AI_GATEWAY_API_KEY", source),
        .fx_login => loadFxLoginCredential(alloc, transport),
        .stored_key => loadStoredKeyCredential(alloc, secret_store),
        .chatgpt_subscription => loadChatGptCredential(alloc, transport, .if_needed),
        .grok_subscription => loadGrokCredential(alloc, transport, .if_needed),
        .host_managed, .configured => null,
    };
}

pub fn sourceExists(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    source: Source,
) !bool {
    try requireSourceStorage(source);
    return switch (source) {
        .vercel_oidc_token => nonEmptyEnvValue("VERCEL_OIDC_TOKEN") != null,
        .ai_gateway_api_key => nonEmptyEnvValue("AI_GATEWAY_API_KEY") != null,
        .fx_login => blk: {
            const loaded = oauth_session.load(alloc) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    debug_trace.logf("auth", "source probe failed source=fx_login err={s}", .{@errorName(err)});
                    break :blk false;
                },
            };
            var session = loaded orelse break :blk false;
            defer session.deinit(alloc);
            break :blk true;
        },
        .chatgpt_subscription => chatgpt_oauth.sourceExists(alloc) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => blk: {
                debug_trace.logf("auth", "source probe failed source=chatgpt err={s}", .{@errorName(err)});
                break :blk false;
            },
        },
        .grok_subscription => grok_oauth.sourceExists(alloc) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => blk: {
                debug_trace.logf("auth", "source probe failed source=grok err={s}", .{@errorName(err)});
                break :blk false;
            },
        },
        .stored_key => blk: {
            if (secret_store.isDisabled()) break :blk false;
            break :blk switch (secret_store.presence()) {
                .present => true,
                .missing => false,
                .unavailable => {
                    debug_trace.logf(
                        "auth",
                        "source probe failed source=stored_key err=StoredKeyUnreadable",
                        .{},
                    );
                    return error.StoredKeyUnreadable;
                },
            };
        },
        .host_managed, .configured => false,
    };
}

pub fn sourcePresence(
    secret_store: host.SecretStore,
    source: Source,
) host.SecretStorePresence {
    return switch (source) {
        .vercel_oidc_token => if (nonEmptyEnvValue("VERCEL_OIDC_TOKEN") != null)
            .present
        else
            .missing,
        .ai_gateway_api_key => if (nonEmptyEnvValue("AI_GATEWAY_API_KEY") != null)
            .present
        else
            .missing,
        .fx_login => oauth_session.presence(),
        .stored_key => if (secret_store.isDisabled())
            .missing
        else
            secret_store.presence(),
        .chatgpt_subscription => chatgpt_session.presence(),
        .grok_subscription => grok_session.presence(),
        .host_managed, .configured => .missing,
    };
}

/// Shared admission for reading a saved OAuth credential.
pub fn requireSourceStorage(source: Source) error{CredentialStorageUnavailable}!void {
    if (!sourceRefreshable(source)) return;
    if (sourcePresence(host.unavailable_secret_store, source) == .unavailable) {
        debug_trace.logf("auth", "credential storage unavailable source={t}", .{source});
        return error.CredentialStorageUnavailable;
    }
}

pub fn requireSignInStorage(source: Source) error{CredentialStorageUnavailable}!void {
    switch (source) {
        .fx_login => try oauth_session.requireSignInStorage(),
        .chatgpt_subscription => try chatgpt_session.requireSignInStorage(),
        .grok_subscription => try grok_session.requireSignInStorage(),
        else => {},
    }
}

fn loadEnvCredential(
    alloc: std.mem.Allocator,
    name: []const u8,
    source: Source,
) !?Credential {
    const value = nonEmptyEnvValue(name) orelse return null;
    return .{
        .token = try alloc.dupe(u8, value),
        .source = source,
    };
}

fn loadStoredKeyCredential(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
) !?Credential {
    if (secret_store.isDisabled()) return null;
    const value = (try secret_store.load(alloc)) orelse return null;
    return .{ .token = value, .source = .stored_key };
}

fn loadChatGptCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    mode: chatgpt_oauth.RefreshMode,
) !?Credential {
    try requireSourceStorage(.chatgpt_subscription);
    var access = (try chatgpt_oauth.loadAccess(alloc, transport, mode)) orelse return null;
    defer access.deinit(alloc);
    const token = access.access_token;
    access.access_token = &.{};
    const account_id = access.account_id;
    access.account_id = &.{};
    return .{
        .token = token,
        .source = .chatgpt_subscription,
        .account_id = account_id,
        .refresh_after_ms = access.refresh_after_ms,
    };
}

fn loadStoredChatGptCredential(alloc: std.mem.Allocator) !?Credential {
    return loadChatGptCredential(alloc, oauth_transport.unavailable_provider, .stored);
}

fn loadGrokCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    mode: grok_oauth.RefreshMode,
) !?Credential {
    try requireSourceStorage(.grok_subscription);
    var access = (try grok_oauth.loadAccess(alloc, transport, mode)) orelse return null;
    defer access.deinit(alloc);
    const token = access.access_token;
    access.access_token = &.{};
    const account_id = access.account_id;
    access.account_id = &.{};
    return .{
        .token = token,
        .source = .grok_subscription,
        .account_id = account_id,
        .refresh_after_ms = access.refresh_after_ms,
    };
}

fn loadStoredGrokCredential(alloc: std.mem.Allocator) !?Credential {
    return loadGrokCredential(alloc, oauth_transport.unavailable_provider, .stored);
}

fn nonEmptyEnvValue(name: []const u8) ?[]const u8 {
    return nonEmptyValue(io_mod.getenv(name));
}

fn nonEmptyValue(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return raw;
}

pub fn loadFxLoginCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
) !?Credential {
    try requireSourceStorage(.fx_login);
    var session = (try oauth_session.load(alloc)) orelse return null;
    defer session.deinit(alloc);

    if (session.expired(io_mod.milliTimestamp())) {
        return refreshFxLoginCredentialLocked(alloc, transport, .if_needed);
    }

    return takeCredentialFromSession(&session, null);
}

fn loadStoredFxLoginCredential(alloc: std.mem.Allocator) !?Credential {
    try requireSourceStorage(.fx_login);
    var session = (try oauth_session.load(alloc)) orelse return null;
    defer session.deinit(alloc);
    return takeCredentialFromSession(&session, null);
}

pub fn refreshFxLoginCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
) !?Credential {
    return refreshFxLoginCredentialLocked(alloc, transport, .force);
}

pub fn refreshChatGptCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
) !?Credential {
    return loadChatGptCredential(alloc, transport, .force);
}

pub fn refreshGrokCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
) !?Credential {
    return loadGrokCredential(alloc, transport, .force);
}

fn refreshFxLoginCredentialLocked(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    mode: FxLoginRefreshMode,
) !?Credential {
    try requireSourceStorage(.fx_login);
    var mutation = (try oauth_session.beginExistingMutation()) orelse return null;
    defer mutation.deinit();

    var session = (try mutation.load(alloc)) orelse return null;
    defer session.deinit(alloc);

    var refreshed_at_ms: ?i64 = null;
    if (mode == .force or session.expired(io_mod.milliTimestamp())) {
        try refreshFxSession(alloc, transport, &mutation, &session);
        refreshed_at_ms = io_mod.milliTimestamp();
    }
    return takeCredentialFromSession(&session, refreshed_at_ms);
}

pub fn refreshFxSession(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    mutation: *oauth_session.Mutation,
    session: *oauth_session.Session,
) !void {
    try mutation.requireWritable();
    const issuer_url = session.issuer;
    var metadata = try oauth.discover(alloc, transport, issuer_url);
    defer metadata.deinit(alloc);
    try oauth_session.validateE2EEndpoint(issuer_url, metadata.token_endpoint);

    var refreshed = oauth.refreshToken(
        alloc,
        transport,
        metadata,
        session.client_id,
        session.refresh_token,
    ) catch |err| {
        if (err == error.InvalidOAuthResponse) {
            debug_trace.logf("auth", "retiring fx login session reason={s}", .{@errorName(err)});
            try retire_fx_session(alloc, mutation);
            return error.NoRefreshToken;
        }
        if (refresh_rejection_requires_sign_in(err)) {
            debug_trace.logf("auth", "retiring terminal fx login session reason={s}", .{@errorName(err)});
            try retire_fx_session(alloc, mutation);
        }
        return err;
    };
    defer refreshed.deinit(alloc);

    const rotated_refresh_token = refreshed.refresh_token orelse {
        debug_trace.logf("auth", "retiring fx login session reason=NoRefreshToken", .{});
        try retire_fx_session(alloc, mutation);
        return error.NoRefreshToken;
    };
    const expires_at_ms = oauth.expiry_timestamp_ms(
        io_mod.milliTimestamp(),
        refreshed.expires_in,
    ) catch |err| {
        debug_trace.logf("auth", "retiring fx login session reason={s}", .{@errorName(err)});
        try retire_fx_session(alloc, mutation);
        return error.NoRefreshToken;
    };

    const replacement = oauth_session.Session{
        .issuer = session.issuer,
        .client_id = session.client_id,
        .access_token = refreshed.access_token,
        .refresh_token = rotated_refresh_token,
        .expires_at_ms = expires_at_ms,
        .scope = refreshed.scope,
        .token_type = refreshed.token_type,
        .team_slug = session.team_slug,
        .team_id = session.team_id,
    };
    mutation.save(alloc, replacement) catch |err| {
        debug_trace.logf("auth", "retiring fx login session after refresh save failed err={s}", .{@errorName(err)});
        retire_fx_session(alloc, mutation) catch |cleanup_err| {
            debug_trace.logf("auth", "fx login session retirement failed err={s}", .{@errorName(cleanup_err)});
        };
        return error.OAuthSessionCleanupUncertain;
    };

    secret.zeroAndFree(alloc, session.access_token);
    session.access_token = refreshed.access_token;
    refreshed.access_token = &.{};

    secret.zeroAndFree(alloc, session.refresh_token);
    session.refresh_token = rotated_refresh_token;
    refreshed.refresh_token = null;

    alloc.free(session.scope);
    session.scope = refreshed.scope;
    refreshed.scope = &.{};

    alloc.free(session.token_type);
    session.token_type = refreshed.token_type;
    refreshed.token_type = &.{};

    session.expires_at_ms = expires_at_ms;
}

fn refresh_rejection_requires_sign_in(err: anyerror) bool {
    return switch (err) {
        error.InvalidGrant,
        error.AccessDenied,
        error.ExpiredToken,
        error.InvalidClient,
        => true,
        else => false,
    };
}

fn retire_fx_session(
    alloc: std.mem.Allocator,
    mutation: *oauth_session.Mutation,
) !void {
    const result = mutation.delete(alloc) catch return error.OAuthSessionCleanupUncertain;
    if (result.local_cleanup_failed) return error.OAuthSessionCleanupUncertain;
}

fn takeCredentialFromSession(session: *oauth_session.Session, refreshed_at_ms: ?i64) Credential {
    const token = session.access_token;
    session.access_token = &.{};
    const team_id = session.team_id;
    session.team_id = null;
    const team_slug = session.team_slug;
    session.team_slug = null;
    return .{
        .token = token,
        .source = .fx_login,
        .team_id = team_id,
        .team_slug = team_slug,
        .refresh_after_ms = credentialRefreshAfterMs(session.expires_at_ms, refreshed_at_ms),
    };
}

fn credentialRefreshAfterMs(expires_at_ms: i64, refreshed_at_ms: ?i64) i64 {
    const refresh_after_ms = oauth_session.refresh_deadline_ms(expires_at_ms);
    const refreshed_at = refreshed_at_ms orelse return refresh_after_ms;
    if (refresh_after_ms > refreshed_at) return refresh_after_ms;
    return expires_at_ms;
}

pub fn sourceLabel(source: Source) []const u8 {
    return switch (source) {
        .vercel_oidc_token => "VERCEL_OIDC_TOKEN",
        .ai_gateway_api_key => "AI_GATEWAY_API_KEY",
        .fx_login => "fx login",
        .stored_key => "stored API key (" ++ stored_key_backend_label ++ ")",
        .chatgpt_subscription => "Codex subscription",
        .grok_subscription => "Grok subscription",
        .host_managed => "host managed",
        .configured => "configured provider",
    };
}

pub fn sourceRefreshable(source: Source) bool {
    return source == .fx_login or source == .chatgpt_subscription or source == .grok_subscription;
}

const std = @import("std");
const chatgpt_oauth = @import("chatgpt_oauth.zig");
const chatgpt_session = @import("chatgpt_session.zig");
const grok_oauth = @import("grok_oauth.zig");
const grok_session = @import("grok_session.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_catalog = @import("provider_catalog.zig");
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
    credential_refresh_required: Source,
    credential_refresh_failed: Source,
    authenticated_credential_rejected: Source,
    chatgpt_subscription,
    grok_subscription,

    fn credentialSource(self: CatalogPublicOnly) ?Source {
        return switch (self) {
            .no_credential => null,
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
    chatgpt_subscription,
    grok_subscription,

    fn credentialSource(self: CatalogAuthenticatedSource) Source {
        return switch (self) {
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
/// states carry no credential bytes; authenticated states carry the only values
/// the request is allowed to send.
pub const CatalogAccess = union(enum) {
    public_only: CatalogPublicOnly,
    authenticated: struct {
        source: CatalogAuthenticatedSource,
        credential: []const u8,
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

    pub fn withExplicitAuthority(self: CatalogAccess) CatalogAccess {
        return switch (self) {
            .public_only => |access| .{ .public_only = access },
            .authenticated => |access| .{ .authenticated = .{
                .source = access.source,
                .credential = access.credential,
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
    if (sourceRefreshable(selected.source) and selected.needsRefreshAt(now_ms)) {
        return .{ .public_only = .{ .credential_refresh_required = selected.source } };
    }
    return catalogAccessForCredentialAndAccount(selected.source, selected.token, selected.accountId());
}

pub fn catalogAccessAfterRefreshFailure(source: Source) CatalogAccess {
    return .{ .public_only = .{ .credential_refresh_failed = source } };
}

pub fn catalogAccessForCredentialAndAccount(
    source: ?Source,
    credential: []const u8,
    account_id: ?[]const u8,
) CatalogAccess {
    const selected_source = source orelse return .{ .public_only = .no_credential };
    const authenticated_source: CatalogAuthenticatedSource = switch (selected_source) {
        .chatgpt_subscription => .chatgpt_subscription,
        .grok_subscription => .grok_subscription,
        .host_managed => return .host_managed,
        .configured => return .{ .public_only = .no_credential },
    };
    return .{
        .authenticated = .{
            .source = authenticated_source,
            .credential = credential,
            .account_id = if (authenticated_source == .grok_subscription) account_id else null,
        },
    };
}

/// Both modes resolve the same sources; the mode selects only whether an
/// expired subscription session is refreshed first.
pub const LoadMode = enum { stored, refresh_if_needed };

pub const missing_chatgpt_credential_message = "fx needs a Codex subscription login for this model. Run fx login codex.";
pub const missing_chatgpt_interactive_credential_message = "Codex needs a subscription login. Run /login, open Connections, then choose Codex subscription.";
pub const missing_grok_credential_message = "fx needs a Grok subscription login for this model. Run fx login grok.";
pub const missing_grok_interactive_credential_message = "Grok needs a subscription login. Run /login, open Connections, then choose Grok subscription.";
pub const host_managed_auth_message = "Authentication is managed by the host.";

pub const Credential = struct {
    token: []u8,
    source: Source,
    account_id: ?[]u8 = null,
    refresh_after_ms: ?i64 = null,

    pub fn clone(self: Credential, alloc: std.mem.Allocator) !Credential {
        const token = try alloc.dupe(u8, self.token);
        errdefer secret.zeroAndFree(alloc, token);
        const account_id = if (self.account_id) |value| try alloc.dupe(u8, value) else null;
        return .{
            .token = token,
            .source = self.source,
            .account_id = account_id,
            .refresh_after_ms = self.refresh_after_ms,
        };
    }

    pub fn deinit(self: *Credential, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.token);
        if (self.account_id) |account_id| alloc.free(account_id);
        self.* = undefined;
    }

    pub fn accountId(self: Credential) ?[]const u8 {
        return self.account_id;
    }

    pub fn needsRefreshAt(self: Credential, now_ms: i64) bool {
        const refresh_after_ms = self.refresh_after_ms orelse return false;
        return refresh_after_ms <= now_ms;
    }
};

pub const LoadFailure = struct {
    source: Source,
    err: anyerror,
};

pub const Resolution = struct {
    credential: ?Credential = null,
    failure: ?LoadFailure = null,
};

pub fn resolveForProvider(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    mode: LoadMode,
    provider: model_provider.ProviderId,
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
    const source = provider_catalog.find(provider).login_source;
    const credential = loadPreferredSource(alloc, transport, mode, source) catch |err| {
        if (err == error.OutOfMemory) return err;
        debug_trace.logf("auth", "provider source load failed source={t} err={s}", .{ source, @errorName(err) });
        return .{ .failure = .{ .source = source, .err = err } };
    };
    return .{ .credential = credential };
}

fn loadPreferredSource(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    mode: LoadMode,
    source: Source,
) !?Credential {
    return switch (source) {
        .chatgpt_subscription => switch (mode) {
            .stored => loadChatGptCredential(alloc, oauth_transport.unavailable_provider, .stored),
            .refresh_if_needed => loadChatGptCredential(alloc, transport, .if_needed),
        },
        .grok_subscription => switch (mode) {
            .stored => loadGrokCredential(alloc, oauth_transport.unavailable_provider, .stored),
            .refresh_if_needed => loadGrokCredential(alloc, transport, .if_needed),
        },
        .host_managed, .configured => null,
    };
}

pub fn loadSource(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    source: Source,
) !?Credential {
    return loadPreferredSource(alloc, transport, .refresh_if_needed, source);
}

pub fn sourceExists(alloc: std.mem.Allocator, source: Source) !bool {
    try requireSourceStorage(source);
    return switch (source) {
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
        .host_managed, .configured => false,
    };
}

pub fn sourcePresence(source: Source) host.SecretStorePresence {
    return switch (source) {
        .chatgpt_subscription => chatgpt_session.presence(),
        .grok_subscription => grok_session.presence(),
        .host_managed, .configured => .missing,
    };
}

/// Shared admission for reading a saved OAuth credential.
pub fn requireSourceStorage(source: Source) error{CredentialStorageUnavailable}!void {
    if (!sourceRefreshable(source)) return;
    if (sourcePresence(source) == .unavailable) {
        debug_trace.logf("auth", "credential storage unavailable source={t}", .{source});
        return error.CredentialStorageUnavailable;
    }
}

pub fn requireSignInStorage(source: Source) error{CredentialStorageUnavailable}!void {
    switch (source) {
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
    const value = io_mod.getenv(name) orelse return null;
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return null;
    return .{
        .token = try alloc.dupe(u8, value),
        .source = source,
    };
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

pub fn sourceLabel(source: Source) []const u8 {
    return switch (source) {
        .chatgpt_subscription => "Codex subscription",
        .grok_subscription => "Grok subscription",
        .host_managed => "host managed",
        .configured => "configured provider",
    };
}

pub fn sourceRefreshable(source: Source) bool {
    return source == .chatgpt_subscription or source == .grok_subscription;
}

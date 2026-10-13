const std = @import("std");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const collections = @import("../shared/collections.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const View = enum {
    full,
    picker,
};

pub const FetchInput = struct {
    access: credentials.CatalogAccess = .{ .public_only = .no_credential },
    endpoint: []const u8,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    view: View = .full,
};

pub const FailureCategory = enum {
    authentication,
    rate_limited,
    gateway_unavailable,
    cancellation,
    transport,
    malformed_response,
    http_status,
    resource_exhausted,
    runtime,
};

pub const Failure = struct {
    category: FailureCategory,
    http_status: ?std.http.Status = null,
    retryable: bool = false,

    pub fn asError(self: Failure) error{
        AuthenticationRejected,
        Cancelled,
        GatewayUnavailable,
        MalformedResponse,
        OutOfMemory,
        RateLimited,
        TransportFailure,
        Unavailable,
    } {
        return switch (self.category) {
            .authentication => error.AuthenticationRejected,
            .rate_limited => error.RateLimited,
            .gateway_unavailable => error.GatewayUnavailable,
            .cancellation => error.Cancelled,
            .transport => error.TransportFailure,
            .malformed_response => error.MalformedResponse,
            .resource_exhausted => error.OutOfMemory,
            .http_status, .runtime => error.Unavailable,
        };
    }
};

pub fn failureForHttpStatus(status: std.http.Status) Failure {
    if (status == .unauthorized or status == .forbidden) {
        return .{ .category = .authentication, .http_status = status };
    }
    if (status == .too_many_requests) {
        return .{ .category = .rate_limited, .http_status = status, .retryable = true };
    }

    const code = @backingInt(status);
    if (code >= 500 and code < 600) {
        return .{
            .category = .gateway_unavailable,
            .http_status = status,
            .retryable = switch (status) {
                .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => true,
                else => false,
            },
        };
    }
    return .{ .category = .http_status, .http_status = status };
}

pub const AccessLevel = enum {
    authenticated,
    public_only,
};

pub const AccessMetadata = struct {
    level: AccessLevel,
    source: ?credentials.Source,
    public_only_reason: ?credentials.CatalogPublicOnlyReason,
    private_models_may_be_hidden: bool,

    pub fn init(access: credentials.CatalogAccess) AccessMetadata {
        const public_only_reason = access.publicOnlyReason();
        return .{
            .level = if (public_only_reason == null) .authenticated else .public_only,
            .source = access.credentialSource(),
            .public_only_reason = public_only_reason,
            .private_models_may_be_hidden = public_only_reason != null,
        };
    }
};

pub const Provenance = struct {
    access: AccessMetadata,
    anonymous_fallback_used: bool = false,
    fallback_failure: ?Failure = null,
};

pub const FailedOutcome = struct {
    access: AccessMetadata,
    anonymous_fallback_used: bool,
    failure: Failure,
};

pub const ProviderResult = union(enum) {
    catalog: std.ArrayList(ModelCatalogEntry),
    failure: Failure,
};

pub const FetchFn = *const fn (
    ?*anyopaque,
    Allocator,
    FetchInput,
) Allocator.Error!ProviderResult;

pub const Provider = struct {
    /// When set, context must outlive every in-flight fetch and capability lookup.
    context: ?*anyopaque = null,
    fetch_fn: FetchFn,
    /// Reads already-owned metadata without allocation, I/O, or waiting.
    lookup_capabilities_fn: ?*const fn (?*anyopaque, []const u8) model_capabilities.Capabilities = null,
    provider_id: model_provider.ProviderId = .codex,
    refresh_interval_ms: ?i64 = null,

    /// Returns owned catalog entries; the caller frees them with `freeModelCatalog`.
    pub fn fetch(self: Provider, alloc: Allocator, input: FetchInput) Allocator.Error!ProviderResult {
        return self.fetch_fn(self.context, alloc, input);
    }

    /// Null means lookup is unsupported, not that the model is unknown.
    pub fn lookupCapabilities(self: Provider, model: []const u8) ?model_capabilities.Capabilities {
        const lookup = self.lookup_capabilities_fn orelse return null;
        return lookup(self.context, model);
    }
};

pub const FetchResult = union(enum) {
    loaded: struct {
        /// Owned catalog entries; the caller frees them with `freeModelCatalog`.
        catalog: std.ArrayList(ModelCatalogEntry),
        provenance: Provenance,
    },
    failed: FailedOutcome,
};

fn failedOutcome(access: credentials.CatalogAccess, anonymous_fallback_used: bool, failure: Failure) FetchResult {
    return .{ .failed = .{
        .access = .init(access),
        .anonymous_fallback_used = anonymous_fallback_used,
        .failure = failure,
    } };
}

pub fn fetchWithPublicFallback(
    provider: Provider,
    alloc: Allocator,
    input: FetchInput,
) FetchResult {
    const requested_access = AccessMetadata.init(input.access);
    const result = fetchWithPublicFallbackUntraced(provider, alloc, input);
    traceCatalogLoad(requested_access, &result);
    return result;
}

fn fetchWithPublicFallbackUntraced(
    provider: Provider,
    alloc: Allocator,
    input: FetchInput,
) FetchResult {
    const attempt = input;
    const first = provider.fetch(alloc, attempt) catch
        return failedOutcome(attempt.access, false, .{ .category = .resource_exhausted });
    switch (first) {
        .catalog => |catalog| return .{ .loaded = .{
            .catalog = catalog,
            .provenance = .{ .access = .init(attempt.access) },
        } },
        .failure => |failure| {
            return failedOutcome(attempt.access, false, failure);
        },
    }
}

fn traceCatalogLoad(requested: AccessMetadata, result: *const FetchResult) void {
    switch (result.*) {
        .loaded => |loaded| traceCatalogLoadOutcome(
            requested,
            loaded.provenance.access,
            loaded.provenance.anonymous_fallback_used,
            "loaded",
            loaded.provenance.fallback_failure,
        ),
        .failed => |failed| traceCatalogLoadOutcome(
            requested,
            failed.access,
            failed.anonymous_fallback_used,
            "failed",
            failed.failure,
        ),
    }
}

fn traceCatalogLoadOutcome(
    requested: AccessMetadata,
    effective: AccessMetadata,
    anonymous_fallback_used: bool,
    outcome: []const u8,
    failure: ?Failure,
) void {
    const credential_source = if (requested.source) |source| @tagName(source) else "none";
    const public_only_reason = if (effective.public_only_reason) |reason| @tagName(reason) else "none";
    const failure_category = if (failure) |detail| @tagName(detail.category) else "none";
    const retryable = if (failure) |detail|
        if (detail.retryable) "true" else "false"
    else
        "none";
    const common_format = "requested_access={s} credential_source={s} effective_access={s} public_only_reason={s} anonymous_fallback={s} outcome={s} failure_category={s}";
    const common_args = .{
        @tagName(requested.level),
        credential_source,
        @tagName(effective.level),
        public_only_reason,
        if (anonymous_fallback_used) "true" else "false",
        outcome,
        failure_category,
    };

    const http_status = if (failure) |detail| detail.http_status else null;
    if (http_status) |status| {
        debug_trace.eventf(
            "catalog",
            "model_catalog_load",
            .{},
            common_format ++ " http_status={d} retryable={s}",
            common_args ++ .{ @backingInt(status), retryable },
        );
    } else {
        debug_trace.eventf(
            "catalog",
            "model_catalog_load",
            .{},
            common_format ++ " http_status=none retryable={s}",
            common_args ++ .{retryable},
        );
    }
}

pub const ModelCatalogEntry = struct {
    id: []u8,
    /// The catalog's display name, trimmed; null when the catalog has none.
    name: ?[]u8 = null,
    model_type: []u8,
    released: i64 = 0,
    has_tool_use: bool = false,
    has_reasoning: bool = false,
    reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty,
    supports_fast_mode: bool = false,
    has_vision: bool = false,
    has_file_input: bool = false,
    has_web_search: bool = false,
    has_explicit_caching: bool = false,
    has_implicit_caching: bool = false,
    context_window: u32 = 0,
    max_tokens: u32 = 0,
    web_search_price: ?[]u8 = null,
};

pub fn freeModelCatalog(alloc: std.mem.Allocator, entries: *std.ArrayList(ModelCatalogEntry)) void {
    for (entries.items) |entry| freeModelCatalogEntry(alloc, entry);
    entries.deinit(alloc);
}

pub fn freeModelCatalogEntry(alloc: std.mem.Allocator, entry: ModelCatalogEntry) void {
    alloc.free(entry.id);
    if (entry.name) |name| alloc.free(name);
    alloc.free(entry.model_type);
    var reasoning_efforts = entry.reasoning_efforts;
    reasoning_efforts.deinit(alloc);
    if (entry.web_search_price) |price| alloc.free(price);
}

/// Returns owned model id strings in catalog order; caller frees with `collections.freeStringList`.
pub fn projectModelIds(alloc: std.mem.Allocator, candidates: []const ModelCatalogEntry) !std.ArrayList([]u8) {
    var ids: std.ArrayList([]u8) = .empty;
    errdefer collections.freeStringList(alloc, &ids);
    try ids.ensureTotalCapacity(alloc, candidates.len);
    for (candidates) |candidate| {
        try ids.append(alloc, try alloc.dupe(u8, candidate.id));
    }
    return ids;
}

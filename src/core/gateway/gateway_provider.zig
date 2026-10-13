const std = @import("std");
const credentials = @import("../auth/credentials.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const model_catalog = @import("model_catalog.zig");
const model_catalog_metadata = @import("model_catalog_metadata.zig");

const Allocator = std.mem.Allocator;

pub const CliModelCatalogInput = struct {
    access: credentials.CatalogAccess = .{ .public_only = .no_credential },
    endpoint: []const u8,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const CliModelCatalogResult = union(enum) {
    loaded: struct {
        /// Owned model id strings; the caller frees them with `collections.freeStringList`.
        ids: std.ArrayList([]u8),
        /// Owned catalog entries behind `ids`, from a provider whose catalog carries model
        /// metadata; empty otherwise. The caller frees them with `model_catalog.freeModelCatalog`.
        entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
        provenance: model_catalog.Provenance,
    },
    failure: model_catalog.FailedOutcome,
};

pub const FetchCliModelCatalogFn = *const fn (
    ?*anyopaque,
    Allocator,
    CliModelCatalogInput,
) CliModelCatalogResult;

pub const CliModelCatalogProvider = struct {
    /// When set, context must remain valid until every in-flight `fetch` returns.
    context: ?*anyopaque = null,
    fetch_fn: FetchCliModelCatalogFn,

    pub fn fetch(
        self: CliModelCatalogProvider,
        alloc: Allocator,
        input: CliModelCatalogInput,
    ) CliModelCatalogResult {
        return self.fetch_fn(self.context, alloc, input);
    }
};

const CapabilityResolverState = enum {
    idle,
    ready,
    failed,
};

pub const CapabilityResolver = struct {
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
    state: CapabilityResolverState = .idle,
    last_attempt_ms: i64 = 0,
    requested_access: ?model_catalog.AccessMetadata = null,
    provider_id: ?model_provider.ProviderId = null,

    pub fn deinit(self: *CapabilityResolver, alloc: Allocator) void {
        model_catalog.freeModelCatalog(alloc, &self.catalog);
    }

    /// The owner must exclude capability readers during refresh. Borrowed
    /// catalog entries stay valid until the next exclusive refresh or adoption.
    pub fn refreshIfDue(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
    ) model_capabilities.ResolveError!void {
        const now = io_mod.milliTimestamp();
        const requested = model_catalog.AccessMetadata.init(input.access);
        const access_changed = !std.meta.eql(self.provider_id, provider.provider_id) or
            self.requested_access == null or !std.meta.eql(self.requested_access.?, requested);
        const expired = if (provider.refresh_interval_ms) |interval|
            now < self.last_attempt_ms or now - self.last_attempt_ms >= interval
        else
            false;
        if (self.state != .idle and !access_changed and !expired) return;

        const result = model_catalog.fetchWithPublicFallback(provider, alloc, input);
        const loaded = switch (result) {
            .loaded => |loaded| loaded,
            .failed => |failed| {
                if (failed.failure.category == .cancellation) return error.Cancelled;
                self.last_attempt_ms = now;
                self.requested_access = requested;
                self.provider_id = provider.provider_id;
                if (access_changed) {
                    if (self.catalog.items.len > 0) debug_trace.logf("gateway", "dropping model catalog after access changed entries={d}", .{self.catalog.items.len});
                    model_catalog.freeModelCatalog(alloc, &self.catalog);
                    self.catalog = .empty;
                }
                if (self.catalog.items.len == 0) self.state = .failed;
                debug_trace.logf("gateway", "model catalog refresh failed category={t} retained={}", .{ failed.failure.category, self.state == .ready });
                return;
            },
        };
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        self.catalog = loaded.catalog;
        self.state = .ready;
        self.last_attempt_ms = now;
        self.requested_access = requested;
        self.provider_id = provider.provider_id;
    }

    pub fn resolve(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
        model: []const u8,
        fallback: model_capabilities.Capabilities,
    ) model_capabilities.ResolveError!model_capabilities.Capabilities {
        if (self.state == .idle) {
            try self.refreshIfDue(alloc, provider, input);
        }

        if (self.state == .failed) {
            debug_trace.logf(
                "gateway",
                "model catalog lookup outcome=cache_failed model={s}",
                .{model},
            );
            return fallback;
        }
        for (self.catalog.items) |entry| {
            if (std.mem.eql(u8, entry.id, model)) {
                debug_trace.logf(
                    "gateway",
                    "model catalog lookup outcome=ready_hit model={s}",
                    .{model},
                );
                return model_capabilities.mergeCapabilities(
                    fallback,
                    model_catalog_metadata.fromCatalogEntry(entry),
                );
            }
        }
        debug_trace.logf(
            "gateway",
            "model catalog lookup outcome=missing_entry model={s}",
            .{model},
        );
        return fallback;
    }

    pub fn available(
        self: *const CapabilityResolver,
        model: []const u8,
        fallback: model_capabilities.Capabilities,
    ) model_capabilities.Capabilities {
        if (self.state == .ready) {
            for (self.catalog.items) |entry| {
                if (std.mem.eql(u8, entry.id, model)) {
                    return model_capabilities.mergeCapabilities(
                        fallback,
                        model_catalog_metadata.fromCatalogEntry(entry),
                    );
                }
            }
        }
        return fallback;
    }

    pub fn catalogEntries(self: *const CapabilityResolver) ?[]const model_catalog.ModelCatalogEntry {
        if (self.state != .ready) return null;
        return self.catalog.items;
    }

    pub fn adoptOwnedCatalog(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
        owned_catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
    ) void {
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        self.catalog = owned_catalog.*;
        owned_catalog.* = .empty;
        self.state = .ready;
        self.last_attempt_ms = io_mod.milliTimestamp();
        self.requested_access = .init(access);
        self.provider_id = provider.provider_id;
    }
};

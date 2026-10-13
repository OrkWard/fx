const std = @import("std");
const credentials = @import("../auth/credentials.zig");
const secret = @import("../auth/secret.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const model_catalog_metadata = @import("../gateway/model_catalog_metadata.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const io_mod = @import("../shared/io.zig");
const list_window = @import("../shared/list_window.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

const ModelCacheState = enum {
    idle,
    loading,
    ready,
    failed,
};

const CatalogOutcome = struct {
    loaded: ?model_catalog.Provenance = null,
    last_failure: ?model_catalog.FailedOutcome = null,
};

const OwnedCatalogAccess = struct {
    access: credentials.CatalogAccess,

    fn init(alloc: Allocator, access: credentials.CatalogAccess) !OwnedCatalogAccess {
        return switch (access) {
            .public_only, .host_managed => .{ .access = access },
            .authenticated => |authenticated| blk: {
                const credential = try alloc.dupe(u8, authenticated.credential);
                errdefer secret.zeroAndFree(alloc, credential);

                const team_context = if (access.teamContext()) |team|
                    try alloc.dupe(u8, team)
                else
                    null;
                errdefer if (team_context) |team| alloc.free(team);

                const account_id = if (access.accountId()) |account|
                    try alloc.dupe(u8, account)
                else
                    null;
                errdefer if (account_id) |account| alloc.free(account);

                break :blk .{
                    .access = .{
                        .authenticated = .{
                            .source = authenticated.source,
                            .credential = credential,
                            .team_context = team_context,
                            .account_id = account_id,
                        },
                    },
                };
            },
        };
    }

    fn deinit(self: *OwnedCatalogAccess, alloc: Allocator) void {
        switch (self.access) {
            .public_only, .host_managed => {},
            .authenticated => |access| {
                secret.zeroAndFree(alloc, @constCast(access.credential));
                if (access.team_context) |team| alloc.free(@constCast(team));
                if (access.account_id) |account| alloc.free(@constCast(account));
            },
        }
        self.* = undefined;
    }
};

pub const ModelMenuLoadState = enum {
    loading,
    ready,
    failed,
};

pub const ModelMenuCatalogState = struct {
    access_level: ?model_catalog.AccessLevel = null,
    source: ?credentials.Source = null,
    public_only_reason: ?credentials.CatalogPublicOnlyReason = null,
    private_models_hidden: bool = false,
    from_profile_settings: bool = false,
    failure: ?Failure = null,

    pub const Failure = struct {
        category: model_catalog.FailureCategory,
        retryable: bool,
    };
};

pub const ModelProviderFilter = enum {
    all,
    anthropic,
    openai,
    xai,
    zai,
    others,
};

pub const model_provider_filter_count = @typeInfo(ModelProviderFilter).@"enum".field_names.len;

pub const ModelMenuItem = struct {
    id: []u8,
    provider: []const u8,
    capabilities: model_capabilities.Capabilities,

    fn deinit(self: ModelMenuItem, alloc: Allocator) void {
        alloc.free(self.id);
    }
};

pub const ModelMenu = struct {
    active: bool = false,
    load_state: ModelMenuLoadState = .loading,
    catalog_state: ModelMenuCatalogState = .{},
    items: std.ArrayList(ModelMenuItem) = .empty,
    provider_index: usize = 0,
    selected_index: usize = 0,
    window_start: usize = 0,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,

    pub fn deinit(self: *ModelMenu, alloc: Allocator) void {
        self.clearSnapshot(alloc);
        self.* = .{};
    }

    pub fn query(self: *const ModelMenu) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn setQuery(self: *ModelMenu, query_text: []const u8) void {
        const len = @min(query_text.len, self.query_buf.len);
        if (len > 0) @memmove(self.query_buf[0..len], query_text[0..len]);
        self.query_len = len;
        self.selected_index = 0;
        self.window_start = 0;
    }

    pub fn providerFilter(self: *const ModelMenu) ModelProviderFilter {
        return @fromBackingInt(@intCast(@min(self.provider_index, model_provider_filter_count - 1)));
    }

    pub fn filteredItemCount(self: *const ModelMenu) usize {
        return modelMenuFilteredItemCount(self.items.items, self.providerFilter(), self.query());
    }

    pub fn itemAt(self: *const ModelMenu, display_index: usize) ?*const ModelMenuItem {
        return modelMenuItemAt(self.items.items, self.providerFilter(), self.query(), display_index);
    }

    pub fn moveVisibleItems(self: *ModelMenu, delta: i32, visible_items: u16) bool {
        const item_count = self.filteredItemCount();
        if (!self.active or self.load_state != .ready or item_count == 0) return false;

        const current: i32 = @intCast(self.selected_index % item_count);
        var next = current + delta;
        if (next < 0) next = @as(i32, @intCast(item_count)) - 1;
        if (next >= @as(i32, @intCast(item_count))) next = 0;
        self.selected_index = @intCast(next);
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            item_count,
            self.selected_index,
            @max(visible_items, 1),
        );
        return true;
    }

    pub fn moveProvider(self: *ModelMenu, delta: i32) bool {
        if (!self.active or self.load_state != .ready or delta == 0) return false;
        const filter_count = model_provider_filter_count;
        if (filter_count <= 1) return false;

        const current = @min(self.provider_index, filter_count - 1);
        const direction: i32 = if (delta < 0) -1 else 1;
        var next: i32 = @intCast(current);
        for (0..filter_count) |_| {
            next += direction;
            if (next < 0) next = @as(i32, @intCast(filter_count)) - 1;
            if (next >= @as(i32, @intCast(filter_count))) next = 0;
            const filter: ModelProviderFilter = @fromBackingInt(@intCast(next));
            if (!modelProviderFilterAvailable(self.items.items, filter)) continue;
            if (next == current) return false;
            self.provider_index = @intCast(next);
            self.selected_index = 0;
            self.window_start = 0;
            return true;
        }
        return false;
    }

    pub fn selectedModelAlloc(self: *const ModelMenu, alloc: Allocator) !?[]u8 {
        if (!self.active or self.load_state != .ready) return null;
        const item = self.itemAt(self.selected_index) orelse return null;
        return try alloc.dupe(u8, item.id);
    }

    fn clearSnapshot(self: *ModelMenu, alloc: Allocator) void {
        for (self.items.items) |item| item.deinit(alloc);
        self.items.deinit(alloc);
        self.items = .empty;
        self.provider_index = 0;
        self.selected_index = 0;
        self.window_start = 0;
    }
};

pub fn modelMenuFilteredItemCount(
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
) usize {
    var count: usize = 0;
    for (items) |item| {
        if (modelMenuItemMatches(item, provider_filter, query)) count += 1;
    }
    return count;
}

pub fn modelMenuItemAt(
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
    display_index: usize,
) ?*const ModelMenuItem {
    var current: usize = 0;
    for (items) |*item| {
        if (!modelMenuItemMatches(item.*, provider_filter, query)) continue;
        if (current == display_index) return item;
        current += 1;
    }
    return null;
}

fn modelMenuItemMatches(
    item: ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
) bool {
    if (!providerMatchesFilter(item.provider, provider_filter)) return false;
    const query_text = std.mem.trim(u8, query, " \t\r\n");
    return query_text.len == 0 or
        text_utils.containsIgnoreCase(item.id, query_text) or
        text_utils.containsIgnoreCase(item.provider, query_text);
}

fn providerFilter(provider: []const u8) ModelProviderFilter {
    return if (std.ascii.eqlIgnoreCase(provider, "anthropic"))
        .anthropic
    else if (std.ascii.eqlIgnoreCase(provider, "openai"))
        .openai
    else if (std.ascii.eqlIgnoreCase(provider, "xai"))
        .xai
    else if (std.ascii.eqlIgnoreCase(provider, "zai"))
        .zai
    else
        .others;
}

pub fn modelProviderFilterAvailable(items: []const ModelMenuItem, filter: ModelProviderFilter) bool {
    if (filter == .all) return true;
    var seen: [model_provider_filter_count]bool = @splat(false);
    for (items) |item| seen[@backingInt(providerFilter(item.provider))] = true;

    var specific_count: usize = 0;
    for (seen[1..]) |available| specific_count += @intFromBool(available);
    return specific_count > 1 and seen[@backingInt(filter)];
}

fn providerMatchesFilter(provider: []const u8, filter: ModelProviderFilter) bool {
    return filter == .all or providerFilter(provider) == filter;
}

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    models_path: []const u8,
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    state: ModelCacheState = .idle,
    completion_pending: bool = false,
    last_attempt_ms: i64 = 0,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    requested_access: ?model_catalog.AccessMetadata = null,
    outcome: CatalogOutcome = .{},
    from_profile_settings: bool = false,
    menu: ModelMenu = .{},

    pub fn init(alloc: Allocator, models_path: []const u8) Self {
        return .{
            .alloc = alloc,
            .models_path = models_path,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cancelAndJoin();
        self.menu.deinit(self.alloc);
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
    }

    pub fn startWarmup(
        self: *Self,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
    ) void {
        self.from_profile_settings = provider.provider_id == .configured;
        if (!self.beginLoad(access, provider.refresh_interval_ms)) return;

        const owned_access = OwnedCatalogAccess.init(self.alloc, access) catch {
            self.markFailed(.{
                .access = .init(access),
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            });
            return;
        };

        self.thread = std.Thread.spawn(.{}, preloadThreadMain, .{ self, provider, owned_access }) catch {
            var failed_access = owned_access;
            const failure = model_catalog.FailedOutcome{
                .access = .init(failed_access.access),
                .anonymous_fallback_used = false,
                .failure = .{ .category = .runtime, .retryable = true },
            };
            failed_access.deinit(self.alloc);
            self.markFailed(failure);
            return;
        };
    }

    /// Loads the catalog inline on the calling thread.
    pub fn loadInline(
        self: *Self,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
    ) void {
        self.from_profile_settings = provider.provider_id == .configured;
        if (!self.beginLoad(access, provider.refresh_interval_ms)) return;

        const result = model_catalog.fetchWithPublicFallback(provider, self.alloc, .{
            .access = access,
            .endpoint = self.models_path,
            .cancel_flag = &self.cancel_requested,
            .view = .picker,
        });
        var loaded = switch (result) {
            .loaded => |loaded| loaded,
            .failed => |failure| {
                self.markFailed(failure);
                self.mutex.lockUncancelable(io_mod.getIo());
                self.completion_pending = true;
                self.mutex.unlock(io_mod.getIo());
                return;
            },
        };

        self.mutex.lockUncancelable(io_mod.getIo());
        if (loaded.catalog.items.len == 0 and self.outcome.loaded != null and self.catalog.items.len > 0) {
            model_catalog.freeModelCatalog(self.alloc, &loaded.catalog);
            self.outcome.last_failure = if (loaded.provenance.fallback_failure) |failure|
                .{
                    .access = loaded.provenance.access,
                    .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                    .failure = failure,
                }
            else
                null;
            self.state = .ready;
            self.completion_pending = true;
            const retained_entries = self.catalog.items.len;
            self.mutex.unlock(io_mod.getIo());
            recordLoadReady(retained_entries, true, loaded.provenance);
            return;
        }
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = loaded.catalog;
        self.outcome = .{ .loaded = loaded.provenance };
        self.state = .ready;
        self.completion_pending = true;
        const loaded_entries = self.catalog.items.len;
        self.mutex.unlock(io_mod.getIo());
        recordLoadReady(loaded_entries, false, loaded.provenance);
    }

    fn beginLoad(self: *Self, access: credentials.CatalogAccess, refresh_interval_ms: ?i64) bool {
        self.finishThreadIfDone();

        const requested_access = model_catalog.AccessMetadata.init(access);
        self.mutex.lockUncancelable(io_mod.getIo());
        const access_changed = self.state != .idle and
            (self.requested_access == null or
                !std.meta.eql(self.requested_access.?, requested_access));
        var reused_public_catalog = false;
        if (access_changed and
            self.state == .ready and
            requested_access.level == .public_only)
        {
            if (self.outcome.loaded) |*loaded| {
                if (loaded.access.level == .public_only) {
                    self.requested_access = requested_access;
                    loaded.* = .{ .access = requested_access };
                    self.outcome.last_failure = null;
                    if (self.menu.active) {
                        self.menu.catalog_state = modelMenuCatalogState(self.outcome, self.from_profile_settings);
                    }
                    reused_public_catalog = true;
                }
            }
        }
        self.mutex.unlock(io_mod.getIo());
        if (reused_public_catalog) return false;
        if (access_changed) self.reset();

        const now = io_mod.milliTimestamp();
        self.mutex.lockUncancelable(io_mod.getIo());
        const expired = if (refresh_interval_ms) |interval|
            now < self.last_attempt_ms or now - self.last_attempt_ms >= interval
        else
            false;
        const should_load = switch (self.state) {
            .idle => true,
            .failed => now - self.last_attempt_ms >= 1000,
            .ready => if (self.outcome.last_failure) |failed|
                expired or (failed.failure.retryable and now - self.last_attempt_ms >= 1000)
            else
                expired,
            .loading => false,
        };
        if (!should_load) {
            self.mutex.unlock(io_mod.getIo());
            return false;
        }
        self.state = .loading;
        self.last_attempt_ms = now;
        self.requested_access = requested_access;
        self.mutex.unlock(io_mod.getIo());
        self.cancel_requested.store(false, .seq_cst);
        return true;
    }

    pub fn reset(self: *Self) void {
        self.cancelAndJoin();

        self.mutex.lockUncancelable(io_mod.getIo());
        self.menu.deinit(self.alloc);
        const preserve_public = if (self.outcome.loaded) |loaded|
            loaded.access.level == .public_only
        else
            false;
        if (!preserve_public) {
            model_catalog.freeModelCatalog(self.alloc, &self.catalog);
            self.catalog = .empty;
            self.outcome = .{};
        }
        self.state = .idle;
        self.completion_pending = false;
        self.last_attempt_ms = 0;
        self.requested_access = null;
        self.mutex.unlock(io_mod.getIo());
        self.cancel_requested.store(false, .seq_cst);
    }

    pub fn resetForProviderChange(self: *Self) void {
        debug_trace.logf("catalog", "model catalog reset reason=provider_changed", .{});
        self.reset();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = .empty;
        self.outcome = .{};
        self.from_profile_settings = false;
    }

    /// Installs a catalog that was completely fetched and validated before the
    /// caller's publication boundary. Ownership transfers without allocation.
    pub fn adoptOwnedCatalog(
        self: *Self,
        access: credentials.CatalogAccess,
        owned_catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
    ) void {
        self.cancelAndJoin();

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.menu.deinit(self.alloc);
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = owned_catalog.*;
        owned_catalog.* = .empty;
        self.outcome = .{ .loaded = .{
            .access = model_catalog.AccessMetadata.init(access),
        } };
        self.from_profile_settings = false;
        self.state = .ready;
        self.completion_pending = true;
        self.last_attempt_ms = io_mod.milliTimestamp();
        self.requested_access = model_catalog.AccessMetadata.init(access);
        self.cancel_requested.store(false, .seq_cst);
        const entries = self.catalog.items.len;
        diagnostics.recordModelCatalogEvent(false, .load, "outcome=adopted entries={d}", .{entries});
    }

    pub fn isLoading(self: *Self) bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.state == .loading;
    }

    pub fn openMenu(self: *Self) !void {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        var next: ModelMenu = .{ .active = true };
        errdefer next.deinit(self.alloc);
        try self.refreshMenuLocked(&next);
        self.menu.deinit(self.alloc);
        self.menu = next;
    }

    pub fn closeMenu(self: *Self) void {
        self.menu.deinit(self.alloc);
    }

    pub fn setMenuQuery(self: *Self, query: []const u8) void {
        self.menu.setQuery(query);
    }

    pub fn pollLoadTransition(self: *Self) !bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.completion_pending) return false;

        if (self.menu.active) try self.refreshMenuLocked(&self.menu);
        self.completion_pending = false;
        return true;
    }

    pub fn isFailed(self: *Self) bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.state == .failed;
    }

    pub fn snapshotCachedModelIds(self: *Self, alloc: Allocator) !?std.ArrayList([]u8) {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready or self.catalog.items.len == 0) return null;

        return try model_catalog.projectModelIds(alloc, self.catalog.items);
    }

    pub fn metadataForModel(self: *Self, model: []const u8) ?model_capabilities.GatewayMetadata {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready) return null;

        const entry = findCatalogModel(self.catalog.items, model) orelse return null;
        return model_catalog_metadata.fromCatalogEntry(entry.*);
    }

    pub const TraceSnapshot = struct {
        state: []const u8,
        entries: usize,
        last_attempt_ms: i64,
        failure_category: ?[]const u8,
        failure_http_status: ?std.http.Status,
        failure_retryable: bool,
        anonymous_fallback: bool,
    };

    /// Point-in-time catalog state for the /trace report; the returned struct
    /// owns no memory and stays valid after the lock is released.
    pub fn snapshotForTrace(self: *Self) TraceSnapshot {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const failure = self.outcome.last_failure;
        return .{
            .state = @tagName(self.state),
            .entries = self.catalog.items.len,
            .last_attempt_ms = self.last_attempt_ms,
            .failure_category = if (failure) |failed| @tagName(failed.failure.category) else null,
            .failure_http_status = if (failure) |failed| failed.failure.http_status else null,
            .failure_retryable = if (failure) |failed| failed.failure.retryable else false,
            .anonymous_fallback = if (failure) |failed| failed.anonymous_fallback_used else false,
        };
    }

    pub fn resolveForRequest(
        self: *Self,
        model: []const u8,
        cancel_flag: *std.atomic.Value(bool),
    ) model_capabilities.ResolveError!model_capabilities.Capabilities {
        while (true) {
            self.finishThreadIfDone();
            self.mutex.lockUncancelable(io_mod.getIo());
            const state = self.state;
            if (state == .ready) {
                const metadata = if (findCatalogModel(self.catalog.items, model)) |entry|
                    model_catalog_metadata.fromCatalogEntry(entry.*)
                else
                    null;
                self.mutex.unlock(io_mod.getIo());
                debug_trace.logf(
                    "gateway",
                    "interactive model catalog lookup outcome={s} model={s}",
                    .{ if (metadata != null) "ready_hit" else "missing_entry", model },
                );
                if (metadata == null) {
                    diagnostics.recordModelCatalogEvent(false, .lookup, "outcome=missing_entry model={s}", .{model});
                }
                return model_capabilities.resolveCapabilities(model, metadata);
            }
            self.mutex.unlock(io_mod.getIo());

            switch (state) {
                .loading => {
                    if (cancel_flag.load(.seq_cst)) {
                        debug_trace.logf(
                            "gateway",
                            "interactive model catalog lookup outcome=cancelled model={s}",
                            .{model},
                        );
                        diagnostics.recordModelCatalogEvent(false, .lookup, "outcome=cancelled model={s}", .{model});
                        return error.Cancelled;
                    }
                    io_mod.sleep(std.time.ns_per_ms);
                },
                .failed, .idle => {
                    debug_trace.logf(
                        "gateway",
                        "interactive model catalog lookup outcome={s} model={s}",
                        .{ if (state == .failed) "cache_failed" else "cache_unavailable", model },
                    );
                    diagnostics.recordModelCatalogEvent(true, .lookup, "outcome={s} model={s}", .{
                        if (state == .failed) "cache_failed" else "cache_unavailable",
                        model,
                    });
                    return model_capabilities.capabilitiesForModel(model);
                },
                .ready => unreachable,
            }
        }
    }

    pub fn catalogModelCompletion(self: *Self, model: []const u8) ?[]const u8 {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready) return null;

        const entry = findCatalogModel(self.catalog.items, model) orelse return null;
        return entry.id;
    }

    pub fn modelCompletions(self: *Self, query: []const u8, out: [][]const u8) usize {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready) return 0;

        var count: usize = 0;
        for (self.catalog.items) |entry| {
            if (count >= out.len) break;
            if (query.len == 0 or text_utils.containsIgnoreCase(entry.id, query)) {
                out[count] = entry.id;
                count += 1;
            }
        }
        return count;
    }

    fn preloadThreadMain(
        self: *Self,
        provider: model_catalog.Provider,
        owned_access: OwnedCatalogAccess,
    ) void {
        var access = owned_access;
        defer access.deinit(self.alloc);

        const result = model_catalog.fetchWithPublicFallback(provider, self.alloc, .{
            .access = access.access,
            .endpoint = self.models_path,
            .cancel_flag = &self.cancel_requested,
            .view = .picker,
        });
        var loaded = switch (result) {
            .loaded => |loaded| loaded,
            .failed => |failure| {
                self.markFailed(failure);
                return;
            },
        };

        self.mutex.lockUncancelable(io_mod.getIo());
        if (loaded.catalog.items.len == 0 and self.outcome.loaded != null and self.catalog.items.len > 0) {
            model_catalog.freeModelCatalog(self.alloc, &loaded.catalog);
            self.outcome.last_failure = if (loaded.provenance.fallback_failure) |failure|
                .{
                    .access = loaded.provenance.access,
                    .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                    .failure = failure,
                }
            else
                null;
            self.state = .ready;
            const retained_entries = self.catalog.items.len;
            self.mutex.unlock(io_mod.getIo());
            recordLoadReady(retained_entries, true, loaded.provenance);
            return;
        }
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = loaded.catalog;
        self.outcome = .{ .loaded = loaded.provenance };
        self.state = .ready;
        const loaded_entries = self.catalog.items.len;
        self.mutex.unlock(io_mod.getIo());
        recordLoadReady(loaded_entries, false, loaded.provenance);
    }

    fn recordLoadReady(entries: usize, reused_previous: bool, provenance: model_catalog.Provenance) void {
        diagnostics.recordModelCatalogEvent(false, .load, "outcome=ready entries={d} reused_previous={s} anonymous_fallback={s} fallback_failure={s}", .{
            entries,
            boolLabel(reused_previous),
            boolLabel(provenance.anonymous_fallback_used),
            boolLabel(provenance.fallback_failure != null),
        });
    }

    fn markFailed(self: *Self, failure: model_catalog.FailedOutcome) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.outcome.last_failure = failure;
        self.state = if (self.outcome.loaded != null and self.catalog.items.len > 0) .ready else .failed;
        const kept_previous = self.state == .ready;
        self.mutex.unlock(io_mod.getIo());
        diagnostics.recordModelCatalogEvent(true, .load, "outcome=failed category={s} status={d} retryable={s} anonymous_fallback={s} kept_previous_catalog={s}", .{
            @tagName(failure.failure.category),
            if (failure.failure.http_status) |status| @backingInt(status) else 0,
            boolLabel(failure.failure.retryable),
            boolLabel(failure.anonymous_fallback_used),
            boolLabel(kept_previous),
        });
    }

    fn cancelAndJoin(self: *Self) void {
        self.cancel_requested.store(true, .seq_cst);
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
    }

    fn finishThreadIfDone(self: *Self) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const should_join = self.state != .loading and self.thread != null;
        const thread = if (should_join) self.thread.? else null;
        if (should_join) self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| {
            handle.join();
            self.mutex.lockUncancelable(io_mod.getIo());
            self.completion_pending = true;
            self.mutex.unlock(io_mod.getIo());
        }
    }

    fn refreshMenuLocked(self: *Self, menu: *ModelMenu) !void {
        if (!menu.active) return;
        switch (self.state) {
            .idle, .loading => {
                menu.clearSnapshot(self.alloc);
                menu.load_state = .loading;
            },
            .failed => {
                menu.clearSnapshot(self.alloc);
                menu.load_state = .failed;
            },
            .ready => try hydrateMenuSnapshot(self.alloc, menu, self.catalog.items),
        }
        menu.catalog_state = modelMenuCatalogState(self.outcome, self.from_profile_settings);
    }
};

fn boolLabel(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn modelMenuCatalogState(outcome: CatalogOutcome, from_profile_settings: bool) ModelMenuCatalogState {
    const access = if (outcome.last_failure) |failed|
        if (outcome.loaded == null or failed.anonymous_fallback_used)
            failed.access
        else
            outcome.loaded.?.access
    else if (outcome.loaded) |loaded|
        loaded.access
    else
        return .{};
    const failure = if (outcome.last_failure) |failed|
        failed.failure
    else if (outcome.loaded) |loaded|
        loaded.fallback_failure
    else
        null;
    return .{
        .access_level = access.level,
        .source = access.source,
        .public_only_reason = access.public_only_reason,
        .private_models_hidden = access.private_models_may_be_hidden,
        .from_profile_settings = from_profile_settings,
        .failure = if (failure) |failed| .{
            .category = failed.category,
            .retryable = failed.retryable,
        } else null,
    };
}

fn hydrateMenuSnapshot(
    alloc: Allocator,
    menu: *ModelMenu,
    catalog: []const model_catalog.ModelCatalogEntry,
) !void {
    var items: std.ArrayList(ModelMenuItem) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(alloc);
        items.deinit(alloc);
    }
    try items.ensureTotalCapacity(alloc, catalog.len);

    for (catalog) |entry| {
        const item = item: {
            const id = try alloc.dupe(u8, entry.id);
            errdefer alloc.free(id);
            break :item ModelMenuItem{
                .id = id,
                .provider = modelProvider(id),
                .capabilities = model_capabilities.resolveCapabilities(
                    id,
                    model_catalog_metadata.fromCatalogEntry(entry),
                ),
            };
        };
        items.append(alloc, item) catch |err| {
            item.deinit(alloc);
            return err;
        };
    }

    menu.clearSnapshot(alloc);
    menu.items = items;
    menu.load_state = .ready;
}

fn modelProvider(model: []const u8) []const u8 {
    const slash = std.mem.findScalar(u8, model, '/') orelse return "";
    if (slash == 0) return "";
    return model[0..slash];
}

fn findCatalogModel(catalog: []const model_catalog.ModelCatalogEntry, model: []const u8) ?*const model_catalog.ModelCatalogEntry {
    for (catalog) |*entry| {
        if (std.mem.eql(u8, entry.id, model)) return entry;
    }
    return null;
}

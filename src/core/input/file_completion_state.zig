const std = @import("std");
const file_index = @import("../workspace/file_index.zig");
const file_picker_path = @import("file_picker_path.zig");
const list_window = @import("../shared/list_window.zig");

pub const capacity = 32;
pub const Status = enum { loading, ready, empty, unavailable, stale };

/// All paths and spans have independent owned storage. Moving Rows does not
/// invalidate its slices; no result borrows an index generation or producer stack.
pub const Rows = struct {
    results: []file_index.SearchResult,
    paths: []u8,
    spans: []file_index.MatchSpan,

    pub fn copy(alloc: std.mem.Allocator, source: []const file_index.SearchResult) !Rows {
        if (source.len > capacity) return error.NoSpaceLeft;
        var path_bytes: usize = 0;
        var span_count: usize = 0;
        for (source) |item| {
            if (item.path.len > file_index.max_path_len or item.matched_spans.len > file_index.max_path_len) return error.NoSpaceLeft;
            path_bytes += item.path.len;
            span_count += item.matched_spans.len;
        }
        const results = try alloc.alloc(file_index.SearchResult, source.len);
        errdefer alloc.free(results);
        const paths = try alloc.alloc(u8, path_bytes);
        errdefer alloc.free(paths);
        const spans = try alloc.alloc(file_index.MatchSpan, span_count);
        errdefer alloc.free(spans);
        var path_offset: usize = 0;
        var span_offset: usize = 0;
        for (source, results) |item, *result| {
            const path = paths[path_offset..][0..item.path.len];
            const matches = spans[span_offset..][0..item.matched_spans.len];
            @memcpy(path, item.path);
            @memcpy(matches, item.matched_spans);
            result.* = .{ .path = path, .kind = item.kind, .matched_spans = matches };
            path_offset += path.len;
            span_offset += matches.len;
        }
        return .{ .results = results, .paths = paths, .spans = spans };
    }

    pub fn deinit(self: *Rows, alloc: std.mem.Allocator) void {
        alloc.free(self.results);
        alloc.free(self.paths);
        alloc.free(self.spans);
        self.* = undefined;
    }
};

const Snapshot = struct {
    id: u64,
    episode: u64,
    status: Status,
    rows: ?Rows = null,

    fn items(self: *const Snapshot) []const file_index.SearchResult {
        return if (self.rows) |rows| rows.results else &.{};
    }

    fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        if (self.rows) |*rows| rows.deinit(alloc);
        self.* = undefined;
    }
};

pub const Receipt = struct {
    episode: u64,
    revision: u64,
    selected: ?usize,
    window_start: usize,
};

pub const View = struct {
    items: []const file_index.SearchResult = &.{},
    status: Status = .loading,
    receipt: ?Receipt = null,
};

pub const State = struct {
    active: bool = false,
    indexed: bool = true,
    scope_epoch: u64 = 0,
    episode: u64 = 1,
    next_revision: u64 = 1,
    raw_query: [2 * file_index.max_path_len + 2]u8 = undefined,
    raw_len: usize = 0,
    lookup_query: [file_index.max_path_len]u8 = undefined,
    lookup_len: ?usize = null,
    at_offset: usize = 0,
    token_start: usize = 0,
    replace_end: usize = 0,
    quoted: bool = false,
    source: ?file_index.ReadableRevision = null,
    lookup_dirty: bool = true,
    directory_request: ?u64 = null,
    refresh_requested: bool = false,
    trusted: bool = false,
    selection_missing: bool = false,
    prepared: ?Snapshot = null,
    presented: ?Snapshot = null,

    pub fn initInto(self: *State) void {
        const state_info = @typeInfo(State).@"struct";
        inline for (state_info.field_names, state_info.field_types, state_info.field_attrs) |field_name, field_type, field_attrs| {
            if (comptime std.mem.eql(u8, field_name, "raw_query") or
                std.mem.eql(u8, field_name, "lookup_query")) continue;
            @field(self.*, field_name) = field_attrs.defaultValue(field_type).?;
        }
    }

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        if (self.prepared) |*value| value.deinit(alloc);
        if (self.presented) |*value| value.deinit(alloc);
        const state_info = @typeInfo(State).@"struct";
        inline for (state_info.field_names, state_info.field_types, state_info.field_attrs) |field_name, field_type, field_attrs| {
            @field(self.*, field_name) = field_attrs.defaultValue(field_type).?;
        }
    }

    pub fn invalidate(self: *State) void {
        self.episode +%= 1;
        self.active = false;
        self.trusted = false;
        self.source = null;
        self.lookup_dirty = true;
        self.directory_request = null;
        self.refresh_requested = false;
        self.selection_missing = false;
    }

    pub fn distrust(self: *State) void {
        self.trusted = false;
    }

    /// Reconciles owned binding state without I/O. Oversized queries cannot acquire
    /// results; their bounded prefix is retained only to avoid repeated failures.
    pub fn reconcile(self: *State, query: ?file_picker_path.Query, scope_epoch: u64, indexed: bool) bool {
        const q = query orelse {
            if (!self.active) return false;
            self.invalidate();
            return true;
        };
        const kept = @min(q.query.len, self.raw_query.len);
        if (self.active and self.scope_epoch == scope_epoch and self.indexed == indexed and
            self.at_offset == q.at_offset and self.token_start == q.token_start and
            self.replace_end == q.replace_end and self.quoted == q.quoted and
            self.raw_len == q.query.len and std.mem.eql(u8, self.raw_query[0..kept], q.query[0..kept])) return false;
        var decoded_storage: [file_index.max_path_len]u8 = undefined;
        const decoded = q.decoded_query(&decoded_storage) catch null;
        const lookup = if (decoded) |bytes| if (bytes.len <= self.lookup_query.len) bytes else null else null;
        const same_lookup = self.active and self.directory_request == null and self.scope_epoch == scope_epoch and self.indexed == indexed and
            self.lookup_len != null and lookup != null and std.mem.eql(u8, self.lookup_query[0..self.lookup_len.?], lookup.?);
        self.directory_request = null;
        self.refresh_requested = self.refresh_requested or !self.active or self.indexed != indexed or self.scope_epoch != scope_epoch;
        self.episode +%= 1;
        self.active = true;
        self.indexed = indexed;
        self.scope_epoch = scope_epoch;
        @memcpy(self.raw_query[0..kept], q.query[0..kept]);
        self.raw_len = q.query.len;
        self.at_offset = q.at_offset;
        self.token_start = q.token_start;
        self.replace_end = q.replace_end;
        self.quoted = q.quoted;
        self.trusted = false;
        self.selection_missing = false;
        self.lookup_len = if (lookup) |bytes| bytes.len else null;
        if (lookup) |bytes| @memcpy(self.lookup_query[0..bytes.len], bytes);
        if (same_lookup and !self.lookup_dirty) {
            // Reuse bytes for another occurrence, never its old presentation
            // authority. Ownership moves into the unacknowledged slot.
            if (self.prepared == null) {
                self.prepared = self.presented;
                self.presented = null;
            }
            if (self.prepared) |*value| {
                value.episode = self.episode;
                value.id = self.next_revision;
                self.next_revision +%= 1;
            }
        } else {
            self.lookup_dirty = true;
            self.source = null;
        }
        return true;
    }

    pub fn needsLookup(self: *const State, source: file_index.ReadableRevision) bool {
        return self.active and (self.lookup_dirty or self.source == null or !std.meta.eql(self.source.?, source));
    }

    /// Takes ownership of rows. A producer may stage data but cannot acknowledge
    /// presentation. Replacing prepared output never changes acceptance authority.
    pub fn stage(self: *State, alloc: std.mem.Allocator, source: file_index.ReadableRevision, status: Status, rows: ?Rows) void {
        if (self.prepared) |*old| old.deinit(alloc);
        self.prepared = .{ .id = self.next_revision, .episode = self.episode, .status = status, .rows = rows };
        self.next_revision +%= 1;
        self.source = source;
        self.lookup_dirty = false;
    }

    fn current(self: *const State) ?*const Snapshot {
        if (!self.active) return null;
        if (self.presented) |*value| if (value.episode == self.episode) return value;
        return null;
    }

    pub fn selected(self: *const State, index: usize) ?file_index.SearchResult {
        if (!self.trusted or self.selection_missing) return null;
        const value = self.current() orelse return null;
        if (value.status != .ready or index >= value.items().len) return null;
        return value.items()[index];
    }

    pub fn acceptedEmpty(self: *const State) bool {
        const value = self.current() orelse return false;
        return self.trusted and !self.selection_missing and value.status == .empty;
    }

    pub fn retry(self: *State) void {
        self.lookup_dirty = true;
        self.refresh_requested = true;
    }

    pub fn rejectSelection(self: *State) void {
        self.selection_missing = true;
    }

    pub fn navigate(self: *State, index: *usize, window: *usize, delta: i32) void {
        if (!self.trusted) return;
        const value = self.current() orelse return;
        const count = value.items().len;
        if (count == 0) return;
        if (self.selection_missing) {
            index.* = if (delta < 0) count - 1 else 0;
            window.* = 0;
            self.selection_missing = false;
        } else list_window.advanceSelection(index, window, count, delta);
    }

    pub fn view(self: *const State, index: usize, window: usize) View {
        if (!self.active) return .{};
        const current_rows = self.current();
        const value = if (self.prepared) |*ready|
            if (ready.episode == self.episode) ready else current_rows orelse return .{}
        else
            current_rows orelse return .{};
        var selected_index: ?usize = if (!self.selection_missing and value.items().len > 0) 0 else null;
        if (current_rows) |old| {
            if (old.items().len > 0) selected_index = null;
            if (!self.selection_missing and index < old.items().len) {
                const choice = old.items()[index];
                for (value.items(), 0..) |item, i| {
                    if (item.kind == choice.kind and std.mem.eql(u8, item.path, choice.path)) {
                        selected_index = i;
                        break;
                    }
                }
            }
        }
        return .{
            .items = value.items(),
            .status = if ((value.status == .ready and selected_index == null) or
                (value.status == .empty and self.selection_missing)) .stale else value.status,
            .receipt = .{ .episode = self.episode, .revision = value.id, .selected = selected_index, .window_start = window },
        };
    }

    /// No-fail acknowledgement of the exact captured, visibly committed rowset.
    pub fn acknowledge(self: *State, alloc: std.mem.Allocator, receipt: Receipt, index: *usize, window: *usize) void {
        if (!self.active or receipt.episode != self.episode) return;
        if (self.prepared) |ready| {
            if (ready.id == receipt.revision and ready.episode == receipt.episode) {
                if (self.presented) |*old| old.deinit(alloc);
                self.presented = ready;
                self.prepared = null;
            }
        }
        const value = self.current() orelse return;
        if (value.id != receipt.revision) return;
        self.selection_missing = self.selection_missing or (receipt.selected == null and value.items().len > 0);
        index.* = receipt.selected orelse 0;
        window.* = receipt.window_start;
        self.trusted = true;
    }
};

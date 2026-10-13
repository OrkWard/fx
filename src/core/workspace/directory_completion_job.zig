const std = @import("std");
const completion = @import("../input/file_completion_state.zig");
const file_index = @import("file_index.zig");
const path_completion = @import("path_completion.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Request = struct {
    id: u64,
    episode: u64,
    scope_epoch: u64,
    at_offset: usize,
    token_start: usize,
    replace_end: usize,
    quoted: bool,
    raw: []u8,
    query: []u8,
    root: []u8,
    home: ?[]u8,

    fn copy(alloc: std.mem.Allocator, id: u64, state: *const completion.State, root: []const u8, home: ?[]const u8) !Request {
        const raw = try alloc.dupe(u8, state.raw_query[0..state.raw_len]);
        errdefer alloc.free(raw);
        const query = try alloc.dupe(u8, state.lookup_query[0..state.lookup_len.?]);
        errdefer alloc.free(query);
        const owned_root = try alloc.dupe(u8, root);
        errdefer alloc.free(owned_root);
        const owned_home = if (home) |bytes| try alloc.dupe(u8, bytes) else null;
        return .{
            .id = id,
            .episode = state.episode,
            .scope_epoch = state.scope_epoch,
            .at_offset = state.at_offset,
            .token_start = state.token_start,
            .replace_end = state.replace_end,
            .quoted = state.quoted,
            .raw = raw,
            .query = query,
            .root = owned_root,
            .home = owned_home,
        };
    }

    fn matches(self: Request, state: *const completion.State) bool {
        return state.active and !state.indexed and state.directory_request == self.id and
            state.episode == self.episode and state.scope_epoch == self.scope_epoch and
            state.at_offset == self.at_offset and state.token_start == self.token_start and
            state.replace_end == self.replace_end and state.quoted == self.quoted and
            state.raw_len == self.raw.len and state.lookup_len == self.query.len and
            std.mem.eql(u8, state.raw_query[0..state.raw_len], self.raw) and
            std.mem.eql(u8, state.lookup_query[0..self.query.len], self.query);
    }

    fn deinit(self: *Request, alloc: std.mem.Allocator) void {
        alloc.free(self.raw);
        alloc.free(self.query);
        alloc.free(self.root);
        if (self.home) |home| alloc.free(home);
        self.* = undefined;
    }
};

const Task = struct {
    alloc: std.mem.Allocator,
    request: Request,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    // Main-only. Worker output is read only after acquire-observing done.
    abandoned: bool = false,
    rows: ?completion.Rows = null,
    failure: ?(path_completion.Error || error{ Cancelled, OutOfMemory }) = null,

    fn stop(self: *Task) void {
        if (!self.abandoned) {
            self.abandoned = true;
            self.cancel.store(true, .release);
            debug_trace.logf("input", "directory completion cancelled request={d}", .{self.request.id});
        }
    }

    fn deinit(self: *Task) void {
        if (self.thread) |thread| thread.join();
        if (self.rows) |*rows| rows.deinit(self.alloc);
        self.request.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    fn run(self: *Task) void {
        // All operation scratch and directory handles are gone before publication.
        defer self.done.store(true, .release);
        self.rows = self.lookup() catch |err| {
            self.failure = err;
            return;
        };
        if (self.cancel.load(.acquire)) {
            self.rows.?.deinit(self.alloc);
            self.rows = null;
            self.failure = error.Cancelled;
        }
    }

    fn lookup(self: *Task) !completion.Rows {
        var results: [completion.capacity]file_index.SearchResult = undefined;
        var spans: [completion.capacity * file_index.max_path_len]file_index.MatchSpan = undefined;
        var paths: [completion.capacity * file_index.max_path_len]u8 = undefined;
        const count = try path_completion.completeCancellable(self.request.root, self.request.home, self.request.query, &self.cancel, &results, &spans, &paths);
        if (self.cancel.load(.acquire)) return error.Cancelled;
        return completion.Rows.copy(self.alloc, results[0..count]);
    }
};

/// Main-owned bounded scheduler. The supplied allocator must be safe for concurrent
/// allocation and outlive deinit. Tasks never borrow editor, workspace or index data.
pub const Job = struct {
    task: ?*Task = null,
    pending: ?Request = null,
    next_request: u64 = 1,

    pub fn stop(self: *Job, alloc: std.mem.Allocator) void {
        if (self.task) |task| task.stop();
        self.dropPending(alloc, "stopped");
    }

    pub fn deinit(self: *Job, alloc: std.mem.Allocator) void {
        self.stop(alloc);
        if (self.task) |task| task.deinit();
        self.* = .{};
    }

    fn dropPending(self: *Job, alloc: std.mem.Allocator, reason: []const u8) void {
        if (self.pending) |*request| {
            debug_trace.logf("input", "directory completion pending dropped request={d} reason={s}", .{ request.id, reason });
            request.deinit(alloc);
            self.pending = null;
        }
    }

    /// No joins here: ingress, owner changes and scope changes only abandon work.
    pub fn reconcile(self: *Job, alloc: std.mem.Allocator, state: *completion.State, eligible: bool) void {
        if (self.task) |task| {
            if (!eligible or !task.request.matches(state)) task.stop();
        }
        if (self.pending) |request| {
            if (!eligible or !request.matches(state)) self.dropPending(alloc, if (eligible) "superseded" else "hidden");
        }
        if (!eligible and state.directory_request != null) {
            state.directory_request = null;
            state.lookup_dirty = true;
        }
    }

    pub fn schedule(self: *Job, alloc: std.mem.Allocator, state_alloc: std.mem.Allocator, state: *completion.State, root: []const u8, home: ?[]const u8) void {
        const id = self.next_request;
        self.next_request +%= 1;
        state.directory_request = id;
        self.reconcile(alloc, state, true);
        state.stage(state_alloc, .{ .scope_epoch = state.scope_epoch, .state = .ready }, .loading, null);
        const request = Request.copy(alloc, id, state, root, home) catch |err| {
            fail(state_alloc, state, id, err);
            return;
        };
        if (self.task != null) {
            self.pending = request;
        } else self.start(alloc, request) catch |err| fail(state_alloc, state, id, err);
    }

    fn start(self: *Job, alloc: std.mem.Allocator, request: Request) !void {
        try self.startWith(alloc, request, spawn);
    }

    // Spawn injection exercises exactly the allocation/ownership failure path.
    fn startWith(self: *Job, alloc: std.mem.Allocator, request: Request, comptime start_thread: anytype) !void {
        std.debug.assert(self.task == null);
        var owned = request;
        errdefer owned.deinit(alloc);
        const task = try alloc.create(Task);
        errdefer alloc.destroy(task);
        task.* = .{ .alloc = alloc, .request = owned };
        task.thread = try start_thread(task);
        self.task = task;
        debug_trace.logf("input", "directory completion started request={d}", .{request.id});
    }

    fn spawn(task: *Task) !std.Thread {
        return std.Thread.spawn(.{}, Task.run, .{task});
    }

    /// Reaps only published tasks. Copies bounded output to the picker allocator,
    /// stages it (never presents it), then starts at most the latest pending request.
    pub fn harvest(self: *Job, alloc: std.mem.Allocator, state_alloc: std.mem.Allocator, state: *completion.State, eligible: bool) bool {
        self.reconcile(alloc, state, eligible);
        const task = self.task orelse return false;
        if (!task.done.load(.acquire)) return false;
        if (!task.abandoned and task.request.matches(state)) {
            if (task.failure) |err| {
                fail(state_alloc, state, task.request.id, err);
            } else {
                const rows = completion.Rows.copy(state_alloc, task.rows.?.results) catch |err| blk: {
                    fail(state_alloc, state, task.request.id, err);
                    break :blk null;
                };
                if (rows) |owned| {
                    state.directory_request = null;
                    state.stage(state_alloc, .{ .scope_epoch = state.scope_epoch, .state = .ready }, if (owned.results.len == 0) .empty else .ready, owned);
                    debug_trace.logf("input", "file picker prepared revision={d} count={d} indexed=false request={d}", .{ state.next_revision -% 1, owned.results.len, task.request.id });
                }
            }
        } else debug_trace.logf("input", "directory completion stale output dropped request={d} failed={}", .{ task.request.id, task.failure != null });
        task.deinit();
        self.task = null;
        if (self.pending) |request| {
            self.pending = null;
            self.start(alloc, request) catch |err| fail(state_alloc, state, request.id, err);
        }
        return true;
    }

    fn fail(alloc: std.mem.Allocator, state: *completion.State, id: u64, err: anyerror) void {
        debug_trace.logf("input", "directory completion failed request={d} err={s}", .{ id, @errorName(err) });
        if (state.directory_request != id) return;
        state.directory_request = null;
        state.stage(alloc, .{ .scope_epoch = state.scope_epoch, .state = .ready }, .unavailable, null);
    }
};

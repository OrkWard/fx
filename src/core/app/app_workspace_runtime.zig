const std = @import("std");
const file_index = @import("../workspace/file_index.zig");
const path_completion = @import("../workspace/path_completion.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const directory_completion_job = @import("../workspace/directory_completion_job.zig");
const io_mod = @import("../shared/io.zig");

pub const Access = workspace_access.WorkspaceAccess;
pub const AccessScope = workspace_access.AccessScope;
pub const Error = workspace_access.Error;
pub const FileCompletionError = file_index.SearchError || path_completion.Error;

pub const State = struct {
    access: Access = .{},
    scope_epoch: u64 = 0,
    directory_completion: directory_completion_job.Job = .{},
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn access(app: *App) *Access {
            return &app.workspace.access;
        }

        pub fn scope(app: *const App) AccessScope {
            return app.workspace.access.scope(app.workspace_root);
        }

        pub fn fileCompletions(
            app: *App,
            query: []const u8,
            out: []file_index.SearchResult,
            match_spans: []file_index.MatchSpan,
            path_storage: []u8,
        ) FileCompletionError!usize {
            return fileCompletionsAtRevision(app, app.file_index.readableRevision(), query, out, match_spans, path_storage);
        }

        pub fn fileCompletionsAtRevision(
            app: *App,
            revision: file_index.ReadableRevision,
            query: []const u8,
            out: []file_index.SearchResult,
            match_spans: []file_index.MatchSpan,
            _: []u8,
        ) FileCompletionError!usize {
            if (path_completion.queryMode(query) != .workspace_index or revision.scope_epoch != app.workspace.scope_epoch) return error.PathUnavailable;
            return app.file_index.searchAtRevision(revision, query, out, match_spans);
        }

        pub fn reconcileDirectoryCompletion(app: *App, eligible: bool) void {
            app.workspace.directory_completion.reconcile(std.heap.c_allocator, &app.input_runtime.picker.file_completion, eligible);
        }

        pub fn prepareDirectoryCompletion(app: *App) void {
            app.workspace.directory_completion.schedule(std.heap.c_allocator, app.alloc, &app.input_runtime.picker.file_completion, app.workspace_root, io_mod.getenv("HOME"));
            app.shell.render_requests.request(.footer);
        }

        pub fn harvestDirectoryCompletion(app: *App, eligible: bool) void {
            if (app.workspace.directory_completion.harvest(std.heap.c_allocator, app.alloc, &app.input_runtime.picker.file_completion, eligible)) {
                app.shell.render_requests.request(.footer);
            }
        }

        pub fn requestStop(app: *App) void {
            app.workspace.directory_completion.stop(std.heap.c_allocator);
        }

        pub fn fileCompletionRevision(app: *const App) file_index.ReadableRevision {
            return app.file_index.readableRevision();
        }

        pub fn fileCompletionScopeEpoch(app: *const App) u64 {
            return app.workspace.scope_epoch;
        }

        pub fn fileCompletionsDependOnIndex(_: *const App, query: []const u8) bool {
            return path_completion.queryMode(query) == .workspace_index;
        }

        pub fn isCurrentFileCompletion(
            app: *const App,
            query: []const u8,
            path: []const u8,
            kind: file_index.CandidateKind,
        ) bool {
            return switch (path_completion.queryMode(query)) {
                .workspace_index => app.file_index.isCurrentCandidateKind(path, kind),
                .explicit_path => path_completion.isCurrentCandidateKind(app.workspace_root, path, kind),
            };
        }

        fn invalidateScope(app: *App) void {
            app.workspace.scope_epoch +%= 1;
            requestStop(app);
            if (comptime @hasField(App, "input_runtime")) {
                app.input_runtime.picker.file_completion.invalidate();
            }
        }

        pub fn adopt(app: *App, value: Access) void {
            invalidateScope(app);
            app.workspace.access.deinit(app.alloc);
            app.workspace.access = value;
        }

        pub fn applyLaunch(
            app: *App,
            command_line_directories: []const []const u8,
            saved_suppressed: bool,
        ) !void {
            try app.workspace.access.applyLaunch(
                app.alloc,
                app.workspace_root,
                command_line_directories,
                saved_suppressed,
            );
            invalidateScope(app);
        }

        /// Installs `replacement` and clears it after taking ownership.
        pub fn install(app: *App, replacement: *Access) bool {
            const runtime_changed = !app.workspace.access.eql(replacement);
            app.workspace.access.deinit(app.alloc);
            app.workspace.access = replacement.*;
            replacement.* = .{};
            if (runtime_changed) {
                invalidateScope(app);
                refreshFileIndex(app);
            }
            return runtime_changed;
        }

        pub fn startFileIndex(app: *App) void {
            if (app.workspace_root.len == 0) return;
            app.file_index.ensureScopeEpoch(std.heap.c_allocator, scope(app), app.workspace.scope_epoch);
        }

        pub fn refreshFileIndex(app: *App) void {
            app.file_index.refreshScopeEpoch(std.heap.c_allocator, scope(app), app.workspace.scope_epoch);
        }

        pub fn refreshAvailability(app: *App) workspace_access.Error!bool {
            var replacement = (try app.workspace.access.stageAvailabilityRefresh(
                app.alloc,
                app.workspace_root,
            )) orelse return false;
            defer replacement.deinit(app.alloc);
            return install(app, &replacement);
        }

        pub fn deinit(app: *App) void {
            app.workspace.directory_completion.deinit(std.heap.c_allocator);
            app.workspace.access.deinit(app.alloc);
            app.workspace = .{};
        }
    };
}

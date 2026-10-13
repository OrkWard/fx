const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const helpers = @import("upgrade_helpers.zig");
const update_target = @import("update_target.zig");

const Allocator = std.mem.Allocator;

const check_interval_ms: u64 = 30 * 60 * 1000;
const initial_delay_ms: u64 = 10_000;
const sleep_increment_ms: u64 = 50;
/// Upper bound stop() waits for the upgrade thread once cancellation has
/// been requested; a stuck network read must not delay process exit.
const stop_join_budget_ms: i64 = 250;
const download_dir_prefix = "fx-auto-upgrade-";
/// A download directory this old belongs to no live upgrade: its process ended
/// before the upgrade thread could remove it.
const stale_download_dir_ns: i128 = std.time.ns_per_hour;

pub const State = enum(u8) {
    idle = 0,
    checking = 1,
    waiting = 2,
    downloading = 3,
    ready = 4,
    failed = 5,
};

pub const RelaunchRequest = struct {
    executable_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    executable_path_len: usize = 0,
    previous_revision_buf: [update_target.max_revision_bytes]u8 = undefined,
    previous_revision_len: u8 = 0,

    pub fn executablePath(self: *const RelaunchRequest) []const u8 {
        return self.executable_path_buf[0..self.executable_path_len];
    }

    pub fn previousRevision(self: *const RelaunchRequest) ?[]const u8 {
        if (self.previous_revision_len == 0) return null;
        return self.previous_revision_buf[0..self.previous_revision_len];
    }
};

pub fn shouldEnableForCurrentExecutable() bool {
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io_mod.getIo(), &exe_buf) catch return true;
    return !isDevelopmentBuildPath(exe_buf[0..n]);
}

pub fn isDevelopmentBuildPath(path: []const u8) bool {
    return std.mem.find(u8, path, "/zig-out/bin/") != null or
        std.mem.find(u8, path, "\\zig-out\\bin\\") != null;
}

pub const AutoUpgrade = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(State.idle)),
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    render_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    version_mutex: std.Io.Mutex = .init,
    latest_version_buf: [64]u8 = undefined,
    latest_version_len: u8 = 0,
    previous_revision_buf: [update_target.max_revision_bytes]u8 = undefined,
    previous_revision_len: u8 = 0,

    selected_channel: update_target.Channel = .stable,

    transfer_interrupt: helpers.TransferInterrupt = .{},
    /// Held across the final stop check and the install, so process exit can
    /// wait out an install already under way and no install starts after it.
    install_mutex: std.Io.Mutex = .init,

    relaunch_request: ?RelaunchRequest = null,

    pub fn configure_channel(self: *AutoUpgrade, selected: update_target.Channel) void {
        self.selected_channel = selected;
    }

    pub fn channel(self: *const AutoUpgrade) update_target.Channel {
        return self.selected_channel;
    }

    pub fn start(
        self: *AutoUpgrade,
        alloc: Allocator,
        current: update_target.CurrentBuild,
    ) void {
        self.setPreviousRevision(current.revision);
        self.thread = std.Thread.spawn(.{}, runLoop, .{ self, alloc, current }) catch return;
    }

    fn requestStop(self: *AutoUpgrade) void {
        self.should_stop.store(true, .release);
        // Wake a thread blocked in a transfer read so it can observe the
        // cancel flag instead of stalling on the socket.
        self.transfer_interrupt.interrupt();
    }

    /// Stops the upgrade thread without joining it. Only an install already
    /// under way is waited out, since it is a local copy; once this returns no
    /// install can start, so process exit cannot interrupt one midway.
    pub fn stopForProcessExit(self: *AutoUpgrade) void {
        self.requestStop();
        self.install_mutex.lockUncancelable(io_mod.getIo());
        self.install_mutex.unlock(io_mod.getIo());
    }

    pub fn stop(self: *AutoUpgrade) void {
        self.requestStop();
        const t = self.thread orelse return;
        const deadline_ms = io_mod.milliTimestamp() + stop_join_budget_ms;
        while (!self.stopped.load(.acquire) and io_mod.milliTimestamp() < deadline_ms) {
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (self.stopped.load(.acquire)) {
            t.join();
        } else {
            // The thread is stuck in a network read; process exit reaps it.
            // downloadAndInstall rechecks should_stop before touching the
            // executable, so a late wake-up cannot install.
            debug_trace.logf("upgrade", "stop detaching upgrade thread mid-transfer", .{});
        }
        self.thread = null;
    }

    pub fn getState(self: *const AutoUpgrade) State {
        return @fromBackingInt(@intCast(self.state.load(.acquire)));
    }

    fn transferControl(self: *AutoUpgrade) helpers.TransferControl {
        return .{
            .cancel = &self.should_stop,
            .interrupt = &self.transfer_interrupt,
        };
    }

    pub fn requestRelaunch(self: *AutoUpgrade, executable_path: []const u8) !void {
        if (executable_path.len > std.Io.Dir.max_path_bytes) return error.NameTooLong;
        var request = RelaunchRequest{
            .executable_path_len = executable_path.len,
        };
        @memcpy(
            request.executable_path_buf[0..executable_path.len],
            executable_path,
        );
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        if (self.selected_channel == .dev and self.previous_revision_len > 0) {
            @memcpy(
                request.previous_revision_buf[0..self.previous_revision_len],
                self.previous_revision_buf[0..self.previous_revision_len],
            );
            request.previous_revision_len = self.previous_revision_len;
        }
        self.relaunch_request = request;
    }

    pub fn takeRelaunchRequest(self: *AutoUpgrade) ?RelaunchRequest {
        const request = self.relaunch_request;
        self.relaunch_request = null;
        return request;
    }

    pub fn statusLabel(self: *AutoUpgrade, buf: []u8) []const u8 {
        const state = self.getState();
        switch (state) {
            .downloading => {
                var ver_buf: [32]u8 = undefined;
                const ver = self.getLatestVersion(&ver_buf);
                return std.mem.print(buf, "upgrading to {s}...", .{ver}) catch "";
            },
            .ready => return "update ready: ctrl+g to reload",
            .failed => return "upgrade failed",
            else => return "",
        }
    }

    pub fn takeRenderDirty(self: *AutoUpgrade) bool {
        return self.render_dirty.swap(false, .acq_rel);
    }

    fn getLatestVersion(self: *AutoUpgrade, out: []u8) []const u8 {
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        const len = self.latest_version_len;
        if (len == 0) return "";
        const n: usize = @min(len, out.len);
        @memcpy(out[0..n], self.latest_version_buf[0..n]);
        return out[0..n];
    }

    fn setState(self: *AutoUpgrade, state: State) void {
        const next = @backingInt(state);
        const previous = self.state.swap(next, .acq_rel);
        if (previous != next) self.markRenderDirty();
    }

    fn setPreviousRevision(self: *AutoUpgrade, revision: []const u8) void {
        const valid = update_target.isValidRevision(revision);
        const len: u8 = if (valid) @intCast(revision.len) else 0;
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        if (len > 0) @memcpy(self.previous_revision_buf[0..len], revision);
        self.previous_revision_len = len;
    }

    fn setLatestVersion(self: *AutoUpgrade, version: []const u8) void {
        const stripped = update_target.normalizeVersion(version);
        const len: u8 = @intCast(@min(stripped.len, 32));
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        @memcpy(self.latest_version_buf[0..len], stripped[0..len]);
        self.latest_version_len = len;
        self.markRenderDirty();
    }

    fn markRenderDirty(self: *AutoUpgrade) void {
        self.render_dirty.store(true, .release);
    }

    fn runLoop(
        self: *AutoUpgrade,
        alloc: Allocator,
        current: update_target.CurrentBuild,
    ) void {
        defer self.stopped.store(true, .release);
        self.sleepInterruptible(initial_delay_ms);

        while (!self.should_stop.load(.acquire)) {
            if (self.getState() == .ready) return;
            self.setState(.checking);
            self.runOnce(alloc, current);

            const post_state = self.getState();
            if (post_state == .ready) return;

            if (post_state != .failed) self.setState(.waiting);
            self.sleepInterruptible(check_interval_ms);
        }
    }

    fn runOnce(
        self: *AutoUpgrade,
        alloc: Allocator,
        current: update_target.CurrentBuild,
    ) void {
        const cdn_base = helpers.resolveCdnBase();
        if (helpers.cancelRequested(&self.should_stop)) return;
        var target = helpers.fetchTarget(alloc, self.selected_channel, cdn_base, self.transferControl()) catch return;
        defer target.deinit(alloc);

        if (!target.shouldInstall(current)) return;

        var label_buf: [64]u8 = undefined;
        const label = target.writeDisplayLabel(&label_buf) catch return;
        self.setLatestVersion(label);
        self.setState(.downloading);

        self.downloadAndInstall(alloc, target, cdn_base) catch {
            self.setState(.failed);
            return;
        };
        self.setState(.ready);
    }

    const InstallError = error{
        AllocFailed,
        DownloadFailed,
        ChecksumFailed,
        ExtractionFailed,
        SelfExeNotFound,
        InstallFailed,
        Cancelled,
    };

    fn downloadAndInstall(
        self: *AutoUpgrade,
        alloc: Allocator,
        target: update_target.Target,
        cdn_base: []const u8,
    ) InstallError!void {
        var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
        defer client.deinit();

        const tmp_base: []const u8 = io_mod.getenv("TMPDIR") orelse "/tmp";
        sweepStaleDownloadDirs(tmp_base, io_mod.nanoTimestamp());
        var rand_buf: [8]u8 = undefined;
        io_mod.getIo().random(&rand_buf);
        const rand_hex = std.fmt.bytesToHex(rand_buf, .lower);
        const tmp_dir = alloc.print("{s}/" ++ download_dir_prefix ++ "{s}", .{ tmp_base, rand_hex }) catch return error.AllocFailed;
        defer alloc.free(tmp_dir);
        defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), tmp_dir) catch {};

        std.Io.Dir.createDirAbsolute(io_mod.getIo(), tmp_dir, .default_dir) catch return error.ExtractionFailed;

        const archive_path = alloc.print("{s}/fx.tar.gz", .{tmp_dir}) catch return error.AllocFailed;
        defer alloc.free(archive_path);

        const archive_url = alloc.print("{s}/{s}/fx-{s}.tar.gz", .{ cdn_base, target.artifactRef(), helpers.platform }) catch return error.AllocFailed;
        defer alloc.free(archive_url);

        helpers.downloadFileStreaming(&client, archive_url, archive_path, self.transferControl()) catch |err| return switch (err) {
            error.Cancelled => error.Cancelled,
            else => error.DownloadFailed,
        };

        if (self.should_stop.load(.acquire)) return error.Cancelled;

        const checksum_url = alloc.print("{s}/{s}/fx-{s}.tar.gz.sha256", .{ cdn_base, target.artifactRef(), helpers.platform }) catch return error.AllocFailed;
        defer alloc.free(checksum_url);

        helpers.verifyChecksum(&client, archive_path, checksum_url, self.transferControl()) catch |err| return switch (err) {
            error.Cancelled => error.Cancelled,
            else => error.ChecksumFailed,
        };

        if (self.should_stop.load(.acquire)) return error.Cancelled;

        helpers.extractTarGz(alloc, archive_path, tmp_dir) catch return error.ExtractionFailed;

        const extracted_bin = alloc.print("{s}/fx", .{tmp_dir}) catch return error.AllocFailed;
        defer alloc.free(extracted_bin);

        var self_exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const self_exe = helpers.currentExecutablePath(&self_exe_buf) catch return error.SelfExeNotFound;
        try self.installUnlessStopped(alloc, extracted_bin, self_exe);
    }

    /// Holds install_mutex across the stop check and the copy, so
    /// stopForProcessExit waits out an install already under way and no
    /// install starts after it.
    fn installUnlessStopped(
        self: *AutoUpgrade,
        alloc: Allocator,
        extracted_bin: []const u8,
        self_exe: []const u8,
    ) InstallError!void {
        self.install_mutex.lockUncancelable(io_mod.getIo());
        defer self.install_mutex.unlock(io_mod.getIo());
        if (self.should_stop.load(.acquire)) return error.Cancelled;
        io_mod.copyFileAtomic(alloc, extracted_bin, self_exe) catch return error.InstallFailed;
    }

    fn sleepInterruptible(self: *AutoUpgrade, total_ms: u64) void {
        var remaining = total_ms;
        while (remaining > 0 and !self.should_stop.load(.acquire)) {
            const chunk = @min(remaining, sleep_increment_ms);
            io_mod.sleep(chunk * @as(u64, std.time.ns_per_ms));
            remaining -|= chunk;
        }
    }
};

/// Removes download directories in `tmp_base` left by upgrades whose process
/// ended mid-download, such as an interactive exit that did not join the
/// upgrade thread.
fn sweepStaleDownloadDirs(tmp_base: []const u8, now_ns: i128) void {
    if (!std.Io.Dir.path.isAbsolute(tmp_base)) return;
    const zio = io_mod.getIo();
    var dir = std.Io.Dir.openDirAbsolute(zio, tmp_base, .{ .iterate = true }) catch return;
    defer dir.close(zio);
    var entries = dir.iterate();
    while (entries.next(zio) catch return) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, download_dir_prefix)) continue;
        const stat = dir.statFile(zio, entry.name, .{ .follow_symlinks = false }) catch continue;
        if (now_ns - stat.mtime.nanoseconds < stale_download_dir_ns) continue;
        dir.deleteTree(zio, entry.name) catch |err| {
            debug_trace.logf("upgrade", "stale download dir not removed err={s}", .{@errorName(err)});
            continue;
        };
        debug_trace.logf("upgrade", "removed stale download dir", .{});
    }
}

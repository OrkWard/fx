const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const update_target = @import("../upgrade/update_target.zig");

const Allocator = std.mem.Allocator;
const cache_dir_name = "provider-versions";
const max_cache_bytes = 256;

pub const refresh_interval_ms: i64 = 60_000;
pub const Provider = enum { codex, grok };
pub const Error = Allocator.Error || error{ Cancelled, ProviderVersionUnavailable };

pub const Version = struct {
    bytes: [update_target.max_version_bytes]u8,
    len: u8,

    pub fn parse(raw: []const u8) ?Version {
        const value = update_target.normalizeVersion(std.mem.trim(u8, raw, " \r\n\t"));
        if (!update_target.isValidVersion(value)) return null;
        var version: Version = .{ .bytes = @as([update_target.max_version_bytes]u8, @splat(0)), .len = @intCast(value.len) };
        @memcpy(version.bytes[0..value.len], value);
        return version;
    }

    pub fn slice(self: *const Version) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Lookup = struct {
    context: ?*anyopaque,
    fetch: *const fn (?*anyopaque, Allocator, Provider) Error!Version,
};

pub const Cached = struct {
    version: Version,
    checked_at_ms: i64,

    fn fresh(self: Cached, now_ms: i64) bool {
        const age = std.math.sub(i64, now_ms, self.checked_at_ms) catch return false;
        return age >= 0 and age < refresh_interval_ms;
    }
};

/// Where resolved versions are kept. Defaults to the profile's cache files; a
/// host runtime without a profile passes its own.
pub const Cache = struct {
    context: ?*anyopaque = null,
    load: *const fn (?*anyopaque, Allocator, Provider) anyerror!?Cached = loadCache,
    save: *const fn (?*anyopaque, Allocator, Provider, Cached) anyerror!void = saveCache,
};

pub fn resolve(alloc: Allocator, provider: Provider, lookup: Lookup) Error!Version {
    return resolveWithCache(alloc, provider, lookup, .{}, io_mod.milliTimestamp());
}

pub fn resolveWithCache(alloc: Allocator, provider: Provider, lookup: Lookup, cache: Cache, now_ms: i64) Error!Version {
    const cached = cache.load(cache.context, alloc, provider) catch |err| blk: {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("models", "provider version cache unreadable provider={t} err={s}", .{ provider, @errorName(err) });
        break :blk null;
    };
    if (cached) |entry| if (entry.fresh(now_ms)) return entry.version;

    const version = lookup.fetch(lookup.context, alloc, provider) catch |err| blk: {
        if (err == error.OutOfMemory or err == error.Cancelled) return err;
        const previous = cached orelse return err;
        debug_trace.logf("models", "provider version lookup unavailable provider={t}; using cached version={s}", .{ provider, previous.version.slice() });
        break :blk previous.version;
    };
    // The timestamp also bounds retries when the release service is unavailable.
    cache.save(cache.context, alloc, provider, .{ .version = version, .checked_at_ms = now_ms }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("models", "provider version cache write failed provider={t} err={s}", .{ provider, @errorName(err) });
    };
    return version;
}

fn cacheFile(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "codex.json",
        .grok => "grok.json",
    };
}

fn loadCache(_: ?*anyopaque, alloc: Allocator, provider: Provider) !?Cached {
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer home_dir.close(io_mod.getIo());
    var profile_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer profile_dir.close(io_mod.getIo());
    var cache_dir = profile_dir.openDir(io_mod.getIo(), cache_dir_name, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer cache_dir.close(io_mod.getIo());
    return readCached(alloc, cache_dir, provider);
}

fn readCached(alloc: Allocator, dir: std.Io.Dir, provider: Provider) !?Cached {
    var file = io_mod.openExistingRegularFile(dir, cacheFile(provider), .read_only) catch |err| {
        if (err == error.FileNotFound) return null;
        if (err == error.DurablePathUnsafe) return error.InvalidProviderVersionCache;
        return err;
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.InvalidProviderVersionCache;
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_cache_bytes);
    defer alloc.free(bytes);
    const Record = struct { version: []const u8, checked_at_ms: i64 };
    const parsed = try std.json.parseFromSlice(Record, alloc, bytes, .{});
    defer parsed.deinit();
    return .{
        .version = Version.parse(parsed.value.version) orelse return error.InvalidProviderVersionCache,
        .checked_at_ms = parsed.value.checked_at_ms,
    };
}

fn saveCache(_: ?*anyopaque, alloc: Allocator, provider: Provider, cached: Cached) !void {
    const home = io_mod.getenv("HOME") orelse return;
    try saveCacheAtHome(alloc, provider, cached, home);
}

fn saveCacheAtHome(alloc: Allocator, provider: Provider, cached: Cached, home: []const u8) !void {
    var home_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true });
    defer home_dir.close(io_mod.getIo());
    var profile_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(home_dir, profile_paths.root_dir_name);
    defer profile_dir.close();
    var cache_dir = try io_mod.openOrCreateVerifiedPrivateDir(&profile_dir, cache_dir_name);
    defer cache_dir.close();
    try writeCached(alloc, &cache_dir, provider, cached);
}

fn writeCached(alloc: Allocator, dir: *io_mod.VerifiedDir, provider: Provider, cached: Cached) !void {
    var bytes: [max_cache_bytes]u8 = undefined;
    const text = try std.mem.print(&bytes, "{{\"version\":\"{s}\",\"checked_at_ms\":{d}}}\n", .{ cached.version.slice(), cached.checked_at_ms });
    try io_mod.durableReplaceVerified(alloc, dir, cacheFile(provider), text);
}

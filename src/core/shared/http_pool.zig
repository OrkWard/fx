const std = @import("std");
const debug_trace = @import("debug_trace.zig");
const io_mod = @import("io.zig");

/// Long-lived HTTP client wrapper that keeps std's ConnectionPool alive
/// across requests to one product origin. std already implements acquire,
/// release, and thread safety; this wrapper owns the three product concerns
/// std does not: client lifetime, launch warming, and idle staleness.
///
/// Ownership: created once per process by the provider runtime, borrowed by
/// request paths. All methods are safe to call from concurrent request
/// threads (the underlying std pool is internally mutex-guarded).
const default_ttl_ms: i64 = 30_000;

pub const HttpPool = struct {
    client: std.http.Client,
    /// Pooled connections idle longer than this are closed instead of reused.
    /// std's pool has no liveness tracking; a gracefully-idle-closed
    /// connection fails only when the next request reads from it, which lands
    /// in the delivery-ambiguity retry path. Bounding idle age keeps that
    /// rare. One conservative timestamp is enough: the pool only gains free
    /// connections at noteActivity-stamped completions, so when
    /// now - last_activity > ttl every free connection is provably stale.
    ttl_ms: i64 = default_ttl_ms,
    last_activity_ms: std.atomic.Value(i64) = .init(0),
    warm_started: std.atomic.Value(bool) = .init(false),
    warm_done: std.atomic.Value(bool) = .init(false),
    deinitialized: bool = false,

    pub const DestroyDisposition = enum {
        /// Pool resources released; caller may free the HttpPool itself.
        destroyed,
        /// A warm flight is still inside connect and owns the client. The
        /// pool is intentionally leaked; only reachable while a process is
        /// exiting or abandoning state, so the memory dies with the process.
        abandoned_warm_flight,
    };

    pub fn init(alloc: std.mem.Allocator) HttpPool {
        return .{ .client = .{ .allocator = alloc, .io = io_mod.getIo() } };
    }

    /// Tears the pool down. When a warm flight is still inside connect, waits
    /// briefly for it, then abandons rather than freeing memory the thread is
    /// using (only reachable on process-abandon paths).
    pub fn deinit(self: *HttpPool) DestroyDisposition {
        if (self.deinitialized) return .destroyed;
        self.deinitialized = true;
        if (self.warm_started.load(.acquire) and !self.warm_done.load(.acquire)) {
            var waited_ms: u64 = 0;
            while (!self.warm_done.load(.acquire) and waited_ms < 500) : (waited_ms += 10) {
                io_mod.sleep(10 * std.time.ns_per_ms);
            }
            if (!self.warm_done.load(.acquire)) {
                debug_trace.logf("gateway", "pool_deinit result=abandoned_warm_flight", .{});
                return .abandoned_warm_flight;
            }
        }
        self.client.deinit();
        return .destroyed;
    }

    pub fn noteActivity(self: *HttpPool) void {
        self.last_activity_ms.store(io_mod.milliTimestamp(), .release);
    }

    /// Establishes one connection to the URL's origin and parks it in the
    /// pool. Best-effort: failures are traced, never propagated.
    fn warm(self: *HttpPool, url: []const u8) void {
        const io = io_mod.getIo();
        const uri = std.Uri.parse(url) catch return;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return;
        if (protocol == .tls) {
            // Client.connect skips the TLS preamble that Client.request
            // performs; Tls.create requires ca_bundle loaded and now set.
            self.ensureTlsReady() catch |err| {
                debug_trace.logf("gateway", "pool_warm result=error stage=tls_init err={s}", .{@errorName(err)});
                return;
            };
        }
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = std.Io.net.HostName.fromUri(uri, &host_buf) catch return;
        const port: u16 = uri.port orelse defaultPort(protocol);
        const started = io_mod.milliTimestamp();
        const conn = self.client.connect(host, port, protocol) catch |err| {
            debug_trace.logf("gateway", "pool_warm result=error err={s}", .{@errorName(err)});
            return;
        };
        self.client.connection_pool.release(conn, io);
        self.noteActivity();
        debug_trace.logf("gateway", "pool_warm result=ok elapsed_ms={d}", .{io_mod.milliTimestamp() - started});
    }

    /// Mirrors the cert-bundle preamble of std.http.Client.request so direct
    /// Client.connect calls are safe. Concurrent with real requests by lock.
    fn ensureTlsReady(self: *HttpPool) !void {
        const client = &self.client;
        const io = client.io;
        {
            try client.ca_bundle_lock.lockShared(io);
            defer client.ca_bundle_lock.unlockShared(io);
            if (client.now != null) return;
        }
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(client.allocator);
        const now = std.Io.Clock.real.now(io);
        bundle.rescan(client.allocator, io, now) catch return error.CertificateBundleLoadFailure;
        try client.ca_bundle_lock.lock(io);
        defer client.ca_bundle_lock.unlock(io);
        if (client.now != null) return; // a concurrent request loaded it first
        client.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
    }

    fn defaultPort(protocol: std.http.Client.Protocol) u16 {
        return switch (protocol) {
            .plain => 80,
            .tls => 443,
        };
    }
};

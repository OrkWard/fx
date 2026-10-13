const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");
const session_usage = @import("session_usage.zig");
const usage_report = @import("usage_report.zig");

const Allocator = std.mem.Allocator;
const max_recovery_facts: usize = 4096;
const max_recovery_incidents: usize = 4096;
const max_recovery_pending: usize = 4096;

pub const OwnedRecovery = struct {
    facts: []usage_report.GenerationFact,
    incidents: []usage_report.Incident,
    pending: []usage_report.PendingMarker,
    unknown_pending: bool,

    pub fn deinit(self: *OwnedRecovery, alloc: Allocator) void {
        for (self.facts) |*fact| fact.deinit(alloc);
        alloc.free(self.facts);
        alloc.free(self.incidents);
        for (self.pending) |hint| alloc.free(hint.id);
        alloc.free(self.pending);
        self.* = undefined;
    }
};

/// Collects unresolved publication state through the bounded recovery
/// registry. Only marked sessions are loaded; historical session directories
/// are never scanned.
pub fn collectFromHome(
    alloc: Allocator,
    home_path: []const u8,
) !OwnedRecovery {
    return collectFromHomeCancelable(alloc, home_path, null);
}

fn collectFromHomeCancelable(
    alloc: Allocator,
    home_path: []const u8,
    cancel_requested: ?*const std.atomic.Value(bool),
) !OwnedRecovery {
    if (cancelRequested(cancel_requested)) return error.Cancelled;
    var store = session_store.Store.initReadOnlyFromHome(
        alloc,
        home_path,
        "/",
    ) catch |err| switch (err) {
        error.FileNotFound => return empty(alloc),
        else => return err,
    };
    defer store.deinit(alloc);

    var marked_sessions = try store.listUsageRecoverySessions(alloc);
    defer {
        for (marked_sessions.items) |*entry| entry.deinit(alloc);
        marked_sessions.deinit(alloc);
    }

    var facts: std.ArrayList(usage_report.GenerationFact) = .empty;
    errdefer {
        for (facts.items) |*fact| fact.deinit(alloc);
        facts.deinit(alloc);
    }
    var incidents: std.ArrayList(usage_report.Incident) = .empty;
    errdefer incidents.deinit(alloc);
    var pending_hints: std.ArrayList(usage_report.PendingMarker) = .empty;
    errdefer {
        for (pending_hints.items) |hint| alloc.free(hint.id);
        pending_hints.deinit(alloc);
    }
    var out: Collected = .{ .facts = &facts, .incidents = &incidents, .pending = &pending_hints };

    for (marked_sessions.items) |marked| {
        if (cancelRequested(cancel_requested)) return error.Cancelled;
        var state = store.loadReadOnly(alloc, marked.id) catch {
            out.unknown_pending = true;
            continue;
        };
        defer state.deinit(alloc);
        const usage = state.usage orelse {
            out.unknown_pending = true;
            continue;
        };
        const checkpoint_modified = store.usageCheckpointModifiedAtNs(marked.id) catch null;
        const newer = checkpointIsNewer(usage, state.updated_at_ms, checkpoint_modified, marked.marker_modified_at_ns, marked.protected_updated_at_ms);
        try collectMarkedSession(alloc, &out, usage, state.updated_at_ms, newer);
    }

    return .{
        .facts = try facts.toOwnedSlice(alloc),
        .incidents = try incidents.toOwnedSlice(alloc),
        .pending = try pending_hints.toOwnedSlice(alloc),
        .unknown_pending = out.unknown_pending,
    };
}

const Collected = struct {
    facts: *std.ArrayList(usage_report.GenerationFact),
    incidents: *std.ArrayList(usage_report.Incident),
    pending: *std.ArrayList(usage_report.PendingMarker),
    unknown_pending: bool = false,
};

/// Whether a v1 session's durable usage checkpoint is at least as new as
/// what its marker protects, from the files' modification times.
fn checkpointIsNewer(
    usage: session_usage.Snapshot,
    updated_at_ms: i64,
    checkpoint_modified_ns: ?i128,
    marker_modified_at_ns: i128,
    protected_updated_at_ms: ?i64,
) bool {
    if (!session_usage.needsProfileRecovery(usage)) {
        const modified = checkpoint_modified_ns orelse return false;
        return modified > marker_modified_at_ns;
    }
    const protected = protected_updated_at_ms orelse return true;
    if (checkpoint_modified_ns) |modified| return modified > marker_modified_at_ns;
    return updated_at_ms >= protected;
}

/// Adds one marked session's usage to `out`. `newer` says whether its
/// durable checkpoint is at least as new as what its marker protects.
fn collectMarkedSession(
    alloc: Allocator,
    out: *Collected,
    usage: session_usage.Snapshot,
    updated_at_ms: i64,
    newer: bool,
) !void {
    if (!newer) out.unknown_pending = true;
    if (!session_usage.needsProfileRecovery(usage)) return;

    if (usage.settled_through_sequence != usage.next_sequence - 1) {
        out.unknown_pending = true;
    }
    for (usage.publication_backlog) |fact| {
        if (out.facts.items.len == max_recovery_facts) {
            out.unknown_pending = true;
            break;
        }
        try out.facts.append(alloc, try fact.dupe(alloc));
    }
    for (usage.incidents) |incident| {
        if (out.incidents.items.len == max_recovery_incidents) {
            out.unknown_pending = true;
            break;
        }
        try out.incidents.append(alloc, incident);
    }
    for (usage.pending) |pending| {
        if (out.pending.items.len == max_recovery_pending) {
            out.unknown_pending = true;
            break;
        }
        const id = try alloc.dupe(u8, pending.id);
        errdefer alloc.free(id);
        try out.pending.append(alloc, .{
            .id = id,
            .observed_at_ms = pending.observed_at_ms orelse
                @max(updated_at_ms, 0),
        });
    }
    if (usage.billing == .incomplete and
        usage.incidents.len == 0 and
        usage.settled_through_sequence == usage.next_sequence - 1)
    {
        if (out.incidents.items.len == max_recovery_incidents) {
            out.unknown_pending = true;
        } else {
            try out.incidents.append(alloc, .{
                .occurred_at_ms = @max(updated_at_ms, 0),
                .completeness = .incomplete,
            });
        }
    }
}

pub fn collectFromHomeConservative(
    alloc: Allocator,
    home_path: []const u8,
) !OwnedRecovery {
    return collectFromHome(
        alloc,
        home_path,
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        debug_trace.logf(
            "usage",
            "local usage recovery incomplete reason={s}",
            .{@errorName(err)},
        );
        return unknown(alloc);
    };
}

pub fn collectFromHomeConservativeCancelable(
    alloc: Allocator,
    home_path: []const u8,
    cancel_requested: *const std.atomic.Value(bool),
) !OwnedRecovery {
    return collectFromHomeCancelable(
        alloc,
        home_path,
        cancel_requested,
    ) catch |err| {
        if (err == error.OutOfMemory or err == error.Cancelled) return err;
        debug_trace.logf(
            "usage",
            "local usage recovery incomplete reason={s}",
            .{@errorName(err)},
        );
        return unknown(alloc);
    };
}

fn cancelRequested(cancel_requested: ?*const std.atomic.Value(bool)) bool {
    return if (cancel_requested) |flag| flag.load(.seq_cst) else false;
}

fn empty(alloc: Allocator) Allocator.Error!OwnedRecovery {
    return .{
        .facts = try alloc.alloc(usage_report.GenerationFact, 0),
        .incidents = try alloc.alloc(usage_report.Incident, 0),
        .pending = try alloc.alloc(usage_report.PendingMarker, 0),
        .unknown_pending = false,
    };
}

fn unknown(alloc: Allocator) Allocator.Error!OwnedRecovery {
    var recovery = try empty(alloc);
    recovery.unknown_pending = true;
    return recovery;
}

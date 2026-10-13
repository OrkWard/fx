//! Lazy compaction of a session's conversation event log on writable resume.
//!
//! Logs written before diff snapshots spilled to the result store inline full
//! previous/after file contents inside `committed_file_presentation` tool_result
//! frames, which dominates log bytes on edit-heavy sessions. This module
//! rewrites such a log once, moving each oversized inline snapshot into the
//! same content-addressed result-store artifacts used by new commits, leaving a
//! `content_handle` reference behind. The rewrite is invisible: it runs inside
//! the writer lock before the open scan, and every later resume replays the
//! compact log (or its history cache) instead of the fat original.
//!
//! Contract:
//! * The log is only replaced by an atomic rename after the compacted tmp file
//!   has been fully written, synced, and re-validated frame by frame. A crash
//!   before the rename leaves the original log untouched; a crash after leaves
//!   the complete compacted log. Orphaned tmp or artifact files are harmless.
//! * Frames are copied verbatim from the original log; only frames whose
//!   presentation spills are re-encoded, so unmodified history keeps its exact
//!   bytes. A torn tail (crash mid-write) is dropped the same way the open
//!   scan would truncate it, so compaction never preserves a partial frame.
//! * Pre-rename failure never blocks resume. Mid-pass errors delete the tmp
//!   file and resume proceeds with the original log; OOM propagates. Failure
//!   to sync the directory after rename is persistence-uncertain and blocks a
//!   writable resume rather than appending to a possibly non-durable inode.
//! * A freshness marker records the compacted log's length and tail CRC. A log
//!   unchanged since the last pass is skipped without being parsed; a log that
//!   grew is re-scanned, which is cheap because new commits already write
//!   handle-based frames.
//! * Read-only loads never compact; the writer lock in `resumeForWrite` is the
//!   single entry point.
//!
//! Temporary compatibility machinery: remove this module, its marker sidecar,
//! wiring, and migration tests once the supported upgrade window excludes all
//! builds that wrote inline diff snapshots and format-convergence evidence
//! shows no remaining legacy payloads in active session stores.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const result_store = @import("result_store.zig");
const session_event = @import("session_event.zig");
const session_replay = @import("session_replay.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

const events_file = "events.jsonl";
const tmp_file = "events.jsonl.compact-tmp";
const pending_file = "events-compaction.pending";
const marker_file = "events-compaction.marker";
const legacy_tmp_files = [_][]const u8{ "events.compact-tmp", "events.jsonl.tmp" };

/// Inline previous/after snapshot bytes above this budget spill to the result
/// store. Mirrors the commit-time budget in session_log.
const inline_budget_bytes: usize = result_store.preview_bytes;
/// A complete log no larger than the inline budget cannot contain a spillable
/// presentation. Every larger log is scanned once so all legacy shapes can
/// converge, including small sessions with one oversized edit.
const min_log_bytes: u64 = inline_budget_bytes + 1;
const marker_max_bytes: usize = 128;
const copy_buffer_bytes: usize = 64 * 1024;
/// The freshness pin hashes this many bytes from the log's tail. Append-only
/// growth changes the length; tail rewrites change the hash. Same-scope
/// middle rewrites stay invisible, the same blind spot the history cache's
/// watermark deliberately accepts.
const tail_pin_bytes: u64 = 64 * 1024;

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

pub const Outcome = enum {
    compacted,
    deferred,
    skipped_small_log,
    skipped_fresh,
    no_inline_payloads,
};

pub const TestControls = struct {
    context: ?*anyopaque = null,
    before_rename_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    before_spill_fn: ?*const fn (?*anyopaque, usize) anyerror!void = null,
    sync_dir_fn: ?*const fn (?*anyopaque, std.Io.Dir) anyerror!void = null,

    fn beforeRename(self: TestControls) !void {
        if (self.before_rename_fn) |callback| try callback(self.context);
    }

    fn beforeSpill(self: TestControls, spill_count: usize) !void {
        if (self.before_spill_fn) |callback| try callback(self.context, spill_count);
    }

    fn syncDir(self: TestControls, dir: std.Io.Dir) !void {
        if (self.sync_dir_fn) |callback| return callback(self.context, dir);
        return io_mod.syncVerifiedDir(dir);
    }
};

pub const Options = struct {
    force: bool = false,
    test_controls: TestControls = .{},
};

const Marker = struct {
    log_len: u64,
    tail_crc: u32,
};

const Stats = struct {
    frames_seen: usize = 0,
    frames_reencoded: usize = 0,
    spill_failures: usize = 0,
    intentionally_inline: usize = 0,
    spilled_bytes: usize = 0,
    input_bytes: u64 = 0,
    output_bytes: u64 = 0,
};

const RewriteResult = struct {
    changed: bool,
    unresolved: bool,
};

const LogLine = struct {
    bytes: []u8,
    start_offset: u64,
    next_offset: u64,
};

const SpillCandidate = struct {
    result: session_event.ConversationToolResult,
    presentation: types.CommittedFilePresentation,
    inline_bytes: usize,
};

/// Compacts the session's event log when it holds inline diff snapshots.
/// Runs under the session writer lock during `resumeForWrite`, before the
/// open scan. Pre-rename non-OOM errors degrade to "keep the original log" at
/// the call site. Post-rename sync failure reports persistence uncertainty.
pub fn compactIfNeeded(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    options: Options,
) !Outcome {
    try cleanupStaleArtifacts(dir, session_id);

    const zio = io_mod.getIo();
    var event_file = openRegularFile(dir, events_file, .read_only) catch |err| switch (err) {
        error.FileNotFound => return .no_inline_payloads,
        else => return err,
    };
    defer event_file.close(zio);
    const log_len = try event_file.length(zio);
    if (log_len < min_log_bytes and !options.force) {
        debug_trace.logf("session", "event=session_log_compaction_skipped id={s} reason=small_log bytes={d}", .{ session_id, log_len });
        return .skipped_small_log;
    }

    const tail_crc = try tailPin(alloc, dir, log_len);
    if (!options.force) {
        if (try readMarker(dir)) |marker| {
            if (marker.log_len == log_len and marker.tail_crc == tail_crc) {
                debug_trace.logf("session", "event=session_log_compaction_skipped id={s} reason=fresh_marker bytes={d}", .{ session_id, log_len });
                return .skipped_fresh;
            }
        }
    }

    var stats: Stats = .{};
    const rewrite = try rewriteLog(
        alloc,
        dir,
        session_id,
        event_file,
        log_len,
        options.test_controls,
        &stats,
    );
    var temp_pending = rewrite.changed;
    defer if (temp_pending) deleteIfPresent(dir, tmp_file);
    if (!rewrite.changed) {
        if (rewrite.unresolved) {
            debug_trace.logf("session", "event=session_log_compaction_deferred id={s} spill_failures={d}; retrying on next resume", .{ session_id, stats.spill_failures });
            return .deferred;
        }
        // Nothing spilled: pin the current log so later resumes skip the
        // scan until the log changes.
        try writeMarkerBestEffort(alloc, dir, session_id, .{ .log_len = log_len, .tail_crc = tail_crc });
        debug_trace.logf(
            "session",
            "event=session_log_compaction_skipped id={s} reason={s} frames={d} intentionally_inline={d}",
            .{
                session_id,
                if (stats.intentionally_inline > 0) "no_spillable_payloads" else "no_inline_payloads",
                stats.frames_seen,
                stats.intentionally_inline,
            },
        );
        return .no_inline_payloads;
    }

    try validateCompactedLog(alloc, dir, session_id);

    const renamed_len = stats.output_bytes;
    try options.test_controls.beforeRename();
    try renameCompactedLog(alloc, dir, session_id, options.test_controls);
    temp_pending = false;
    if (!rewrite.unresolved) {
        try writeMarkerBestEffort(
            alloc,
            dir,
            session_id,
            .{ .log_len = renamed_len, .tail_crc = try tailPin(alloc, dir, renamed_len) },
        );
    }
    debug_trace.logf(
        "session",
        "event=session_log_compacted id={s} frames={d} reencoded={d} spill_failures={d} intentionally_inline={d} spilled_bytes={d} before_bytes={d} after_bytes={d}",
        .{ session_id, stats.frames_seen, stats.frames_reencoded, stats.spill_failures, stats.intentionally_inline, stats.spilled_bytes, stats.input_bytes, stats.output_bytes },
    );
    return .compacted;
}

/// Rewrites the log into tmp_file, spilling oversized inline snapshots.
/// Returns false when no frame spilled; the tmp file is removed in that case
/// so a clean log is never swapped for an identical copy.
fn rewriteLog(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    event_file: std.Io.File,
    log_len: u64,
    test_controls: TestControls,
    stats: *Stats,
) !RewriteResult {
    const zio = io_mod.getIo();
    var tmp = try createPrivateTempFile(dir);
    var tmp_open = true;
    var keep_tmp = false;
    defer {
        if (tmp_open) tmp.close(zio);
        if (!keep_tmp) deleteIfPresent(dir, tmp_file);
    }

    var result_dir: ?[]const u8 = null;
    defer if (result_dir) |path| alloc.free(path);
    var spill_path_failed = false;
    var unresolved = false;

    var reader_buffer: [copy_buffer_bytes]u8 = undefined;
    var reader = event_file.reader(zio, &reader_buffer);
    var copy_buffer: [copy_buffer_bytes]u8 = undefined;
    var pending_offset: u64 = 0;
    var complete_end: u64 = 0;
    var tmp_len: u64 = 0;
    var spill_attempts: usize = 0;
    var any_spill = false;

    while (true) {
        const line = readLogLine(alloc, &reader, log_len) catch |err| switch (err) {
            // A torn tail is the open scan's truncation case: stop copying at
            // the last complete frame and let the tmp end there.
            error.TruncatedEventFrame => break,
            else => return err,
        } orelse break;
        defer alloc.free(line.bytes);
        stats.frames_seen += 1;

        var parsed = session_event.decodeConversationFrame(alloc, line.bytes) catch |err| {
            debug_trace.logf("session", "event=session_log_compaction_aborted id={s} err={s}; keeping original log", .{ session_id, @errorName(err) });
            return err;
        };
        defer parsed.deinit();
        // The frame boundary only advances past fully decoded frames; the tmp
        // copy range never includes a torn tail.
        complete_end = line.next_offset;

        const spill = spillablePresentation(parsed.value.event) orelse continue;
        if (spill_path_failed) {
            unresolved = true;
            stats.spill_failures += 1;
            continue;
        }
        if (result_dir == null) {
            const base = io_mod.dirRealpathAlloc(alloc, dir.dir, ".") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    debug_trace.logf("session", "event=session_log_compaction_spill_unavailable id={s} err={s}; keeping presentations inline", .{ session_id, @errorName(err) });
                    spill_path_failed = true;
                    unresolved = true;
                    stats.spill_failures += 1;
                    continue;
                },
            };
            defer alloc.free(base);
            result_dir = std.Io.Dir.path.join(alloc, &.{ base, "tool-results" }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        spill_attempts += 1;
        test_controls.beforeSpill(spill_attempts) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("session", "event=diff_content_spill_failed call_id={s} err={s}; keeping presentation inline", .{ spill.result.call_id, @errorName(err) });
                unresolved = true;
                stats.spill_failures += 1;
                continue;
            },
        };
        const handle = result_store.storeDiffContent(
            alloc,
            result_dir.?,
            spill.result.call_id,
            spill.presentation.previous_content,
            spill.presentation.after_content,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DiffContentTooLarge => {
                // A valid event frame can exceed the stricter artifact-pack
                // limit. It must remain inline permanently, but it must not
                // force every future resume to retry the impossible spill.
                debug_trace.logf("session", "event=diff_content_spill_skipped call_id={s} reason=artifact_too_large inline_bytes={d}", .{ spill.result.call_id, spill.inline_bytes });
                stats.intentionally_inline += 1;
                continue;
            },
            else => {
                // Store hiccups mirror the commit-time rule: keep this frame
                // inline and continue with the rest of the log. Do not publish
                // a freshness marker: the next resume must retry this spill.
                debug_trace.logf("session", "event=diff_content_spill_failed call_id={s} err={s}; keeping presentation inline", .{ spill.result.call_id, @errorName(err) });
                unresolved = true;
                stats.spill_failures += 1;
                continue;
            },
        };
        defer alloc.free(handle);

        try copyLogRange(event_file, &tmp, &copy_buffer, pending_offset, line.start_offset);
        tmp_len += line.start_offset - pending_offset;
        const frame = try encodeSpilledFrame(alloc, parsed.value, spill, handle);
        defer alloc.free(frame);
        try tmp.writeStreamingAll(zio, frame);
        tmp_len += frame.len;
        stats.frames_reencoded += 1;
        stats.spilled_bytes += spill.inline_bytes;
        pending_offset = line.next_offset;
        any_spill = true;
    }

    if (!any_spill) return .{ .changed = false, .unresolved = unresolved };
    try copyLogRange(event_file, &tmp, &copy_buffer, pending_offset, complete_end);
    tmp_len += complete_end - pending_offset;
    stats.input_bytes = log_len;
    stats.output_bytes = tmp_len;
    try tmp.sync(zio);
    tmp.close(zio);
    tmp_open = false;
    keep_tmp = true;
    return .{ .changed = true, .unresolved = unresolved };
}

fn spillablePresentation(event: session_event.ConversationEvent) ?SpillCandidate {
    const result = switch (event) {
        .tool_result => |value| value,
        else => return null,
    };
    const presentation = result.committed_file_presentation orelse return null;
    if (presentation.content_handle != null) return null;
    const previous_bytes = if (presentation.previous_content) |content| content.len else 0;
    const after_bytes = if (presentation.after_content) |content| content.len else 0;
    const inline_bytes = previous_bytes +| after_bytes;
    if (inline_bytes <= inline_budget_bytes) return null;
    return .{
        .result = result,
        .presentation = presentation,
        .inline_bytes = inline_bytes,
    };
}

fn encodeSpilledFrame(
    alloc: Allocator,
    envelope: session_event.ConversationEnvelope,
    spill: SpillCandidate,
    handle: []const u8,
) ![]u8 {
    var projected_presentation = spill.presentation;
    projected_presentation.previous_content = null;
    projected_presentation.after_content = null;
    projected_presentation.content_handle = handle;
    var projected_result = spill.result;
    projected_result.committed_file_presentation = projected_presentation;
    return session_event.encodeConversationFrame(alloc, .{
        .seq = envelope.seq,
        .timestamp_ms = envelope.timestamp_ms,
        .event = .{ .tool_result = projected_result },
    });
}

/// Adds the starting offset needed by the rewrite to the canonical bounded
/// session-line reader used by discovery and replay.
fn readLogLine(alloc: Allocator, reader: *std.Io.File.Reader, max_end: u64) !?LogLine {
    const start_offset = reader.logicalPos();
    const read = (try session_replay.readBufferedLine(alloc, reader, max_end, null)) orelse
        return null;
    return .{
        .bytes = read.bytes,
        .start_offset = start_offset,
        .next_offset = read.next_offset,
    };
}

/// Streams `source[start..end)` into `dest` in bounded chunks via positional
/// reads, leaving the streaming reader's state untouched.
fn copyLogRange(
    source: std.Io.File,
    dest: *std.Io.File,
    buffer: *[copy_buffer_bytes]u8,
    start: u64,
    end: u64,
) !void {
    const zio = io_mod.getIo();
    var offset = start;
    while (offset < end) {
        const want: usize = @intCast(@min(buffer.len, end - offset));
        const n = try source.readPositional(zio, &.{buffer[0..want]}, offset);
        if (n == 0) return error.UnexpectedEndOfFile;
        try dest.writeStreamingAll(zio, buffer[0..n]);
        offset += n;
    }
}

/// Re-parses the tmp log and replays the open scan's transition validation,
/// proving the rewrite preserved every frame before it can replace the
/// original. A torn tail is accepted: the tmp ends at the last complete frame
/// by construction, but a partial line here would mean the rewrite itself was
/// interrupted, so any truncation error fails validation.
fn validateCompactedLog(alloc: Allocator, dir: *io_mod.VerifiedDir, session_id: []const u8) !void {
    const zio = io_mod.getIo();
    var file = try openRegularFile(dir, tmp_file, .read_only);
    defer file.close(zio);
    const len = try file.length(zio);
    var reader_buffer: [copy_buffer_bytes]u8 = undefined;
    var reader = file.reader(zio, &reader_buffer);
    var last_seq: u64 = 0;
    var latest_checkpoint_coverage: u64 = 0;
    var turn_open = false;
    var pending_tool_calls: std.ArrayList(session_event.PendingToolCall) = .empty;
    defer {
        for (pending_tool_calls.items) |pending| {
            alloc.free(@constCast(pending.call_id));
            alloc.free(@constCast(pending.tool_name));
        }
        pending_tool_calls.deinit(alloc);
    }
    var frames: usize = 0;
    while (true) {
        const line = (try readLogLine(alloc, &reader, len)) orelse break;
        defer alloc.free(line.bytes);
        var parsed = try session_event.decodeConversationFrame(alloc, line.bytes);
        defer parsed.deinit();
        const envelope = parsed.value;
        try session_event.validateConversationTransition(.{
            .last_seq = last_seq,
            .latest_checkpoint_coverage = latest_checkpoint_coverage,
            .pending_tool_calls = pending_tool_calls.items,
        }, envelope);
        switch (envelope.event) {
            .user => {
                if (turn_open) return error.InvalidConversationFrame;
                turn_open = true;
            },
            .turn_completed, .interrupted => {
                if (!turn_open) return error.InvalidConversationFrame;
                turn_open = false;
            },
            .assistant, .tool_call, .tool_result, .steering => {
                if (!turn_open) return error.InvalidConversationFrame;
            },
            .context_checkpoint => {
                latest_checkpoint_coverage = envelope.event.context_checkpoint.covers_through_seq;
            },
        }
        try trackPendingToolCall(alloc, &pending_tool_calls, envelope);
        last_seq = envelope.seq;
        frames += 1;
    }
    debug_trace.logf("session", "event=session_log_compaction_verified id={s} frames={d} bytes={d}", .{ session_id, frames, len });
}

/// Mirrors ConversationWriter's pending-call bookkeeping so validation sees
/// the same tool-call pairing the open scan enforces.
fn trackPendingToolCall(
    alloc: Allocator,
    pending: *std.ArrayList(session_event.PendingToolCall),
    envelope: session_event.ConversationEnvelope,
) !void {
    switch (envelope.event) {
        .tool_call => |call| {
            const call_id = try alloc.dupe(u8, call.call_id);
            errdefer alloc.free(call_id);
            const tool_name = try alloc.dupe(u8, call.tool_name);
            errdefer alloc.free(tool_name);
            try pending.append(alloc, .{ .call_id = call_id, .tool_name = tool_name, .seq = envelope.seq });
        },
        .tool_result => |result| {
            for (pending.items, 0..) |item, index| {
                if (std.mem.eql(u8, item.call_id, result.call_id)) {
                    const removed = pending.orderedRemove(index);
                    alloc.free(@constCast(removed.call_id));
                    alloc.free(@constCast(removed.tool_name));
                    break;
                }
            }
        },
        .interrupted => {
            for (pending.items) |item| {
                alloc.free(@constCast(item.call_id));
                alloc.free(@constCast(item.tool_name));
            }
            pending.clearRetainingCapacity();
        },
        else => {},
    }
}

fn openRegularFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !std.Io.File {
    return io_mod.openExistingRegularFile(dir.dir, name, mode);
}

fn createPrivateTempFile(dir: *io_mod.VerifiedDir) !std.Io.File {
    const zio = io_mod.getIo();
    var file = dir.dir.createFile(zio, tmp_file, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = private_file_permissions,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.IsDir, error.NotDir, error.SymLinkLoop, error.PathAlreadyExists => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer file.close(zio);
    file.setPermissions(zio, private_file_permissions) catch
        return error.PrivateStatePermissionsUnsupported;
    try io_mod.verifyOpenedRegularFile(try file.stat(zio), .read_write);
    return file;
}

fn renameCompactedLog(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    test_controls: TestControls,
) !void {
    const zio = io_mod.getIo();
    var temp = try openRegularFile(dir, tmp_file, .read_only);
    temp.close(zio);
    var current = try openRegularFile(dir, events_file, .read_only);
    current.close(zio);

    // The durable pending fence survives a post-rename sync failure. A later
    // writer must resolve it before opening events.jsonl, making whichever
    // atomic rename state is visible durable before new events can append.
    try io_mod.durableReplaceVerified(alloc, dir, pending_file, "1\n");
    try dir.dir.rename(tmp_file, dir.dir, events_file, zio);
    test_controls.syncDir(dir.dir) catch |err| {
        debug_trace.logf("session", "event=session_log_compaction_durability_uncertain id={s} err={s}", .{ session_id, @errorName(err) });
        return error.SessionCompactionPersistenceUncertain;
    };
    clearPendingFenceBestEffort(dir, session_id);
}

/// CRC32 over the log's trailing bytes; combined with the length it pins the
/// exact log state a marker refers to, matching the history cache watermark's
/// documented blind spot for in-place middle rewrites.
fn tailPin(alloc: Allocator, dir: *io_mod.VerifiedDir, log_len: u64) !u32 {
    if (log_len == 0) return 0;
    const zio = io_mod.getIo();
    var file = try openRegularFile(dir, events_file, .read_only);
    defer file.close(zio);
    const tail_bytes: u64 = @min(log_len, tail_pin_bytes);
    const start = log_len - tail_bytes;
    const buffer = try alloc.alloc(u8, @intCast(tail_bytes));
    defer alloc.free(buffer);
    var offset: u64 = start;
    while (offset < log_len) {
        const n = try file.readPositional(zio, &.{buffer[@intCast(offset - start)..]}, offset);
        if (n == 0) return error.UnexpectedEndOfFile;
        offset += n;
    }
    return std.hash.Crc32.hash(buffer);
}

fn readMarker(dir: *io_mod.VerifiedDir) !?Marker {
    const zio = io_mod.getIo();
    var file = openRegularFile(dir, marker_file, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(zio);
    var buffer: [marker_max_bytes]u8 = undefined;
    const n = try file.readPositional(zio, &.{&buffer}, 0);
    var iterator = std.mem.tokenizeScalar(u8, buffer[0..n], '\n');
    const len_line = iterator.next() orelse return null;
    const crc_line = iterator.next() orelse return null;
    const log_len = std.fmt.parseInt(u64, std.mem.trim(u8, len_line, " \r"), 10) catch return null;
    const tail_crc = std.fmt.parseInt(u32, std.mem.trim(u8, crc_line, " \r"), 10) catch return null;
    return .{ .log_len = log_len, .tail_crc = tail_crc };
}

fn writeMarkerBestEffort(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    marker: Marker,
) !void {
    const text = try alloc.print("{d}\n{d}\n", .{ marker.log_len, marker.tail_crc });
    defer alloc.free(text);
    io_mod.durableReplaceVerified(alloc, dir, marker_file, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => debug_trace.logf("session", "event=session_log_compaction_marker_unavailable id={s} err={s}; future resume will rescan", .{ session_id, @errorName(err) }),
    };
}

fn deleteRegularIfPresent(dir: *io_mod.VerifiedDir, name: []const u8) !bool {
    const stat = dir.dir.statFile(io_mod.getIo(), name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir, error.SymLinkLoop => return error.DurablePathUnsafe,
        else => return err,
    };
    if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
    try dir.dir.deleteFile(io_mod.getIo(), name);
    return true;
}

fn deleteIfPresent(dir: *io_mod.VerifiedDir, name: []const u8) void {
    _ = deleteRegularIfPresent(dir, name) catch |err| {
        debug_trace.logf("session", "session compaction cleanup failed name={s} err={s}", .{ name, @errorName(err) });
    };
}

fn clearPendingFenceBestEffort(dir: *io_mod.VerifiedDir, session_id: []const u8) void {
    const removed = deleteRegularIfPresent(dir, pending_file) catch |err| {
        debug_trace.logf("session", "event=session_log_compaction_fence_retained id={s} err={s}", .{ session_id, @errorName(err) });
        return;
    };
    if (!removed) return;
    io_mod.syncVerifiedDir(dir.dir) catch |err| {
        debug_trace.logf("session", "event=session_log_compaction_fence_cleanup_uncertain id={s} err={s}", .{ session_id, @errorName(err) });
    };
}

fn recoverPendingReplacement(dir: *io_mod.VerifiedDir, session_id: []const u8) !void {
    const stat = dir.dir.statFile(io_mod.getIo(), pending_file, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            debug_trace.logf("session", "event=session_log_compaction_recovery_uncertain id={s} err={s}", .{ session_id, @errorName(err) });
            return error.SessionCompactionPersistenceUncertain;
        },
    };
    if (stat.kind != .file or stat.nlink != 1) {
        debug_trace.logf("session", "event=session_log_compaction_recovery_uncertain id={s} err=unsafe_pending_fence", .{session_id});
        return error.SessionCompactionPersistenceUncertain;
    }

    // First make the currently visible atomic-rename state durable. Only then
    // may the fence and any pre-rename temp be removed.
    io_mod.syncVerifiedDir(dir.dir) catch |err| {
        debug_trace.logf("session", "event=session_log_compaction_recovery_uncertain id={s} err={s}", .{ session_id, @errorName(err) });
        return error.SessionCompactionPersistenceUncertain;
    };
    _ = deleteRegularIfPresent(dir, tmp_file) catch
        return error.SessionCompactionPersistenceUncertain;
    _ = deleteRegularIfPresent(dir, pending_file) catch
        return error.SessionCompactionPersistenceUncertain;
    io_mod.syncVerifiedDir(dir.dir) catch |err| {
        debug_trace.logf("session", "event=session_log_compaction_recovery_uncertain id={s} err={s}", .{ session_id, @errorName(err) });
        return error.SessionCompactionPersistenceUncertain;
    };
    debug_trace.logf("session", "event=session_log_compaction_recovered id={s}", .{session_id});
}

/// Resolves a post-rename uncertainty fence, then removes tmp files left by an
/// interrupted earlier pass (including names from superseded builds).
fn cleanupStaleArtifacts(dir: *io_mod.VerifiedDir, session_id: []const u8) !void {
    try recoverPendingReplacement(dir, session_id);
    var removed: usize = 0;
    if (try deleteRegularIfPresent(dir, tmp_file)) removed += 1;
    for (legacy_tmp_files) |name| {
        if (try deleteRegularIfPresent(dir, name)) removed += 1;
    }
    if (removed > 0) {
        debug_trace.logf("session", "event=session_log_compaction_cleanup id={s} stale_tmp_files={d}", .{ session_id, removed });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

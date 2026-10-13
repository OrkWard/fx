const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session = @import("session.zig");
const session_child_store = @import("session_child_store.zig");
const session_codec = @import("session_codec.zig");
const session_compaction = @import("session_compaction.zig");
const types = @import("../shared/types.zig");
const history_range = @import("../shared/history_range.zig");
const session_event = @import("session_event.zig");
const history_snapshot = @import("history_snapshot.zig");
const session_layout = @import("session_layout.zig");
const session_replay = @import("session_replay.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const result_store = @import("result_store.zig");
const session_usage = @import("session_usage.zig");
const session_usage_sidecar = @import("session_usage_sidecar.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");

const Allocator = std.mem.Allocator;
const Identifier = session_event.Identifier;
const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const lock_deadline_ms: u64 = 2000;
/// Real first events stay under 2 KiB; this leaves room for two maximum-length
/// workspace paths while keeping listing reads independent of log size.
const listed_first_event_max_bytes: usize = 16 * 1024;
const events_file = "events.jsonl";
const authority_file = "authority.json";
const authority_intent_file = "authority.pending.json";
const publication_intent_file = "commit.pending.json";
const manifest_file = "session.json";
const permission_state_file = "permissions.json";
const recovery_checkpoint_file = "recovery.json";
/// Written when resume suppresses a checkpoint's auto-continue after an
/// unclean exit. Cleared with the checkpoint so suppression stays sticky
/// until the user resolves the turn instead of re-arming after a clean quit.
const recovery_asked_file = "recovery.asked";
/// Liveness marker naming the live writable owner.
const owner_live_file = "owner.live";
const conversation_migration_temp_file = "events.v4.tmp";
const conversation_migration_backup_file = "events.v3.backup";
const checkpoint_file = "checkpoint.json";
const session_lock_file = "session.lock";
const commit_lock_file = "commit.lock";

const ConversationProgress = struct {
    point: types.ContextHistoryCut = .{},
    pending: usize = 0,
    coverage: u64 = 0,
    reached: bool = false,
    pending_assistant: ?struct { seq: u64, has_replay: bool } = null,

    fn observe(self: *ConversationProgress, seq: u64, event: session_event.ConversationEvent, cut: ?types.ContextHistoryCut) !void {
        if (self.pending_assistant) |assistant| {
            const standalone = switch (event) {
                .assistant, .context_checkpoint, .interrupted => true,
                .steering => assistant.has_replay,
                else => false,
            };
            if (standalone) {
                self.point.tool_steps += 1;
                if (cut) |target| if (!self.reached and std.meta.eql(self.point, target)) {
                    self.coverage = assistant.seq;
                    self.reached = true;
                };
            }
            self.pending_assistant = null;
        }
        if (cut) |target| if (std.meta.eql(self.point, target) and self.pending == 0) {
            self.reached = true;
        };
        switch (event) {
            .assistant => |value| {
                if (value.standalone_response) {
                    self.point.tool_steps += 1;
                } else if (value.text.len > 0 or value.provider_replay != null) {
                    self.pending_assistant = .{ .seq = seq, .has_replay = value.provider_replay != null };
                }
            },
            .tool_call => self.pending += 1,
            .tool_result => {
                if (self.pending == 0) return error.InvalidConversationFrame;
                self.pending -= 1;
                if (self.pending == 0) self.point.tool_steps += 1;
            },
            .steering => self.point.steering += 1,
            .turn_completed, .interrupted => {
                self.point.turns += 1;
                self.point.tool_steps = 0;
                self.point.steering = 0;
                self.pending = 0;
            },
            else => {},
        }
        if (cut) |target| {
            if (!self.reached and std.meta.eql(self.point, target) and self.pending == 0) {
                self.coverage = seq;
                self.reached = true;
            }
        }
    }
};

pub const ConversationWriter = struct {
    alloc: Allocator,
    file: std.Io.File,
    committed_bytes: u64 = 0,
    last_seq: u64 = 0,
    latest_checkpoint_coverage: u64 = 0,
    turn_open: bool = false,
    pending_tool_calls: std.ArrayList(session_event.PendingToolCall) = .empty,
    failure: ?error{ SessionWriterChanged, SessionPersistenceUncertain, SessionCommitFailed } = null,
    test_sync_ops: if (builtin.is_test) io_mod.DurableOps else void = if (builtin.is_test) .{} else {},

    /// Takes ownership of `file` only on success.
    pub fn init(alloc: Allocator, file: std.Io.File) !ConversationWriter {
        return initWithReplayScan(alloc, file, null, null, null);
    }

    fn initWithReplayScan(
        alloc: Allocator,
        file: std.Io.File,
        replay_scan: ?*ConversationReplayScan,
        source: ?*HistoryFrameSource,
        snapshot_tee: ?*history_snapshot.Writer,
    ) !ConversationWriter {
        const length = try file.length(io_mod.getIo());
        var writer = ConversationWriter{ .alloc = alloc, .file = file };
        errdefer {
            writer.clearPendingToolCalls();
            writer.pending_tool_calls.deinit(alloc);
        }
        var log_source = HistoryFrameSource{ .log_file = file, .log_length = length };
        const frames = source orelse &log_source;
        if (source == null) frames.reset();
        var frame_arena = std.heap.ArenaAllocator.init(alloc);
        defer mem_utils.deinit_arena(frame_arena);
        var offset: u64 = 0;
        var open_turn_offset: ?u64 = null;
        var open_turn_prior_seq: u64 = 0;
        var open_turn_snapshot_len: ?u64 = null;
        var checkpointed_turn = false;
        while (true) {
            const frame = frames.next(frame_arena.allocator()) catch |err| switch (err) {
                error.TruncatedEventFrame => {
                    try file.setLength(io_mod.getIo(), offset);
                    try file.sync(io_mod.getIo());
                    writer.committed_bytes = offset;
                    break;
                },
                else => return err,
            } orelse break;
            const envelope = frame.envelope;
            try session_event.validateConversationTransition(.{
                .last_seq = writer.last_seq,
                .latest_checkpoint_coverage = writer.latest_checkpoint_coverage,
                .pending_tool_calls = writer.pending_tool_calls.items,
            }, envelope);
            switch (envelope.event) {
                .user => {
                    if (open_turn_offset != null) return error.InvalidConversationFrame;
                    open_turn_offset = frame.log_offset;
                    open_turn_prior_seq = writer.last_seq;
                    // Cache position of this open turn's first frame: the
                    // truncation mirror for an unfinished tail turn. Frames
                    // served from a verified prefix point at their own offset;
                    // frames teed now point at the writer's pre-append length.
                    open_turn_snapshot_len = frames.last_frame_snapshot_file_offset orelse
                        if (snapshot_tee) |tee| tee.len else null;
                },
                .turn_completed, .interrupted => {
                    if (open_turn_offset == null) return error.InvalidConversationFrame;
                    open_turn_offset = null;
                    open_turn_snapshot_len = null;
                    checkpointed_turn = false;
                },
                .context_checkpoint => if (open_turn_offset != null) {
                    open_turn_offset = frame.nextOffset();
                    open_turn_prior_seq = envelope.seq;
                    checkpointed_turn = true;
                },
                .assistant, .tool_call, .tool_result, .steering => if (open_turn_offset == null) {
                    return error.InvalidConversationFrame;
                },
            }
            try writer.applyReplayedEvent(envelope.seq, envelope.event);
            if (replay_scan) |scan| try scan.observe(frame.log_offset, envelope.seq, envelope.event);
            // Tee only frames read from the log. Cache-sourced frames are
            // already in the cache; re-appending them would duplicate it.
            if (snapshot_tee) |tee| {
                if (frames.last_frame_snapshot_file_offset == null) tee.append(envelope, frame.log_offset, frame.log_bytes, frame.line_crc);
            }
            offset = frame.nextOffset();
            writer.committed_bytes = offset;
            _ = frame_arena.reset(.retain_capacity);
        }
        if (open_turn_offset) |truncate_from| {
            debug_trace.logf(
                "session",
                "event=conversation_unfinished_turn_discarded offset={d} bytes={d}",
                .{ truncate_from, writer.committed_bytes - truncate_from },
            );
            try file.setLength(io_mod.getIo(), truncate_from);
            try file.sync(io_mod.getIo());
            writer.clearPendingToolCalls();
            writer.committed_bytes = truncate_from;
            writer.last_seq = open_turn_prior_seq;
            writer.turn_open = checkpointed_turn;
            if (replay_scan) |scan| {
                scan.last_seq = writer.last_seq;
                if (!writer.turn_open) scan.active_user_offset = null;
            }
            // The open turn's frames were already mirrored into the cache;
            // truncate the cache to the same logical point.
            if (snapshot_tee) |tee| {
                if (open_turn_snapshot_len) |snapshot_len| tee.truncateTo(snapshot_len);
            }
        }
        return writer;
    }

    pub fn deinit(self: *ConversationWriter) void {
        for (self.pending_tool_calls.items) |pending| {
            self.alloc.free(@constCast(pending.call_id));
            self.alloc.free(@constCast(pending.tool_name));
        }
        self.pending_tool_calls.deinit(self.alloc);
        self.file.close(io_mod.getIo());
        self.* = undefined;
    }

    pub fn append(
        self: *ConversationWriter,
        alloc: Allocator,
        timestamp_ms: i64,
        event: session_event.ConversationEvent,
    ) !u64 {
        if (self.failure) |err| return err;
        const seq = std.math.add(u64, self.last_seq, 1) catch
            return error.ConversationSequenceOverflow;
        const envelope = session_event.ConversationEnvelope{
            .seq = seq,
            .timestamp_ms = timestamp_ms,
            .event = event,
        };
        try session_event.validateConversationTransition(.{
            .last_seq = self.last_seq,
            .latest_checkpoint_coverage = self.latest_checkpoint_coverage,
            .pending_tool_calls = self.pending_tool_calls.items,
        }, envelope);
        const turn_open = try nextConversationTurnOpen(self.turn_open, event);

        var owned_pending: ?session_event.PendingToolCall = null;
        errdefer if (owned_pending) |pending| {
            self.alloc.free(@constCast(pending.call_id));
            self.alloc.free(@constCast(pending.tool_name));
        };
        const completed_index: ?usize = switch (event) {
            .tool_call => |call| blk: {
                try self.pending_tool_calls.ensureUnusedCapacity(self.alloc, 1);
                const call_id = try self.alloc.dupe(u8, call.call_id);
                errdefer mem_utils.free(self.alloc, call_id);
                const tool_name = try self.alloc.dupe(u8, call.tool_name);
                owned_pending = .{
                    .call_id = call_id,
                    .tool_name = tool_name,
                    .seq = seq,
                };
                break :blk null;
            },
            .tool_result => |result| self.pendingIndex(result.call_id),
            else => null,
        };

        const frame = try session_event.encodeConversationFrame(alloc, envelope);
        defer alloc.free(frame);
        try self.writePrepared(frame);
        self.last_seq = seq;
        self.turn_open = turn_open;

        if (owned_pending) |pending| {
            self.pending_tool_calls.appendAssumeCapacity(pending);
            owned_pending = null;
        }
        if (completed_index) |index| {
            const completed = self.pending_tool_calls.orderedRemove(index);
            self.alloc.free(@constCast(completed.call_id));
            self.alloc.free(@constCast(completed.tool_name));
        }
        if (event == .interrupted) self.clearPendingToolCalls();
        if (event == .context_checkpoint) {
            self.latest_checkpoint_coverage = event.context_checkpoint.covers_through_seq;
        }
        return seq;
    }

    pub fn pendingToolCallCount(self: *const ConversationWriter) usize {
        return self.pending_tool_calls.items.len;
    }

    pub fn appendHistoryTurn(
        self: *ConversationWriter,
        alloc: Allocator,
        timestamp_ms: i64,
        turn: types.HistoryTurn,
    ) !void {
        if (turn == .compacted_summary) {
            _ = try self.append(alloc, timestamp_ms, .{
                .context_checkpoint = .{
                    .covers_through_seq = self.last_seq,
                    .summary = turn.compacted_summary.summary,
                },
            });
            return;
        }

        try self.appendTurnBatch(alloc, timestamp_ms, turn, null);
    }

    fn appendContextCompaction(
        self: *ConversationWriter,
        alloc: Allocator,
        timestamp_ms: i64,
        summary: types.CompactedSummaryHistoryTurn,
        prefix: ?types.AssistantHistoryTurn,
        retained_from: ?types.ContextHistoryCut,
    ) !void {
        if (prefix) |entry| {
            if (entry.assistant.len != 0) return error.InvalidConversationEvent;
            try self.appendTurnBatchWithCut(alloc, timestamp_ms, .{ .assistant = entry }, summary.summary, retained_from);
        } else {
            const coverage = if (retained_from) |cut| try self.contextCoverage(alloc, cut, &.{}) else self.last_seq;
            _ = try self.append(alloc, timestamp_ms, .{ .context_checkpoint = .{
                .covers_through_seq = coverage,
                .summary = summary.summary,
            } });
        }
    }

    fn appendTurnBatch(
        self: *ConversationWriter,
        alloc: Allocator,
        timestamp_ms: i64,
        turn: types.HistoryTurn,
        checkpoint_summary: ?[]const u8,
    ) !void {
        return self.appendTurnBatchWithCut(alloc, timestamp_ms, turn, checkpoint_summary, null);
    }

    fn appendTurnBatchWithCut(
        self: *ConversationWriter,
        alloc: Allocator,
        timestamp_ms: i64,
        turn: types.HistoryTurn,
        checkpoint_summary: ?[]const u8,
        retained_from: ?types.ContextHistoryCut,
    ) !void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer mem_utils.deinit_arena(arena);
        // A checkpoint can have already committed the recent execution prefix.
        // Finalization supplies that prefix for model history; append only its
        // not-yet-written suffix to the conversation log.
        const unwritten = if (self.turn_open) blk: {
            var progress: ConversationProgress = .{};
            try self.scanContext(alloc, &progress, null);
            const view = try history_range.contextHistoryRange(arena.allocator(), &.{turn}, .{
                .tool_steps = progress.point.tool_steps,
                .steering = progress.point.steering,
            }, null);
            if (view.len != 1) return error.InvalidConversationEvent;
            break :blk view[0];
        } else turn;
        var events: std.ArrayList(session_event.ConversationEvent) = .empty;
        defer events.deinit(alloc);
        try session_event.appendHistoryTurnConversationEvents(alloc, &events, unwritten);
        const start: usize = if (self.turn_open) 1 else 0;
        if (checkpoint_summary) |summary| {
            _ = events.pop();
            const covers_through_seq = if (retained_from) |cut|
                try self.contextCoverage(alloc, cut, events.items[start..])
            else
                std.math.add(u64, self.last_seq, events.items.len - start) catch
                    return error.ConversationSequenceOverflow;
            try events.append(alloc, .{ .context_checkpoint = .{
                .covers_through_seq = covers_through_seq,
                .summary = summary,
            } });
        }
        var projected_images: ?[]types.ImageAttachment = null;
        defer if (projected_images) |images| {
            types.freeImageAttachmentSlice(alloc, images);
        };
        for (events.items[start..]) |*event| switch (event.*) {
            .user => |*user| {
                if (user.images.len == 0) continue;
                const images = try types.dupeImageAttachmentSlice(alloc, user.images);
                projectConversationImageLocators(alloc, images) catch |err| {
                    types.freeImageAttachmentSlice(alloc, images);
                    return err;
                };
                user.images = images;
                projected_images = images;
            },
            else => {},
        };
        try self.appendBatch(alloc, timestamp_ms, events.items[start..]);
    }

    fn scanContext(self: *const ConversationWriter, alloc: Allocator, progress: *ConversationProgress, cut: ?types.ContextHistoryCut) !void {
        progress.coverage = self.latest_checkpoint_coverage;
        var offset: u64 = 0;
        var buffer: [8192]u8 = undefined;
        var reader = self.file.reader(io_mod.getIo(), &buffer);
        while (offset < self.committed_bytes) {
            const line = try session_replay.readBufferedLine(alloc, &reader, self.committed_bytes, null) orelse break;
            defer alloc.free(line.bytes);
            var decoded = try session_event.decodeConversationFrame(alloc, line.bytes);
            defer decoded.deinit();
            if (decoded.value.seq > self.latest_checkpoint_coverage) {
                try progress.observe(decoded.value.seq, decoded.value.event, cut);
            }
            offset = line.next_offset;
        }
    }

    fn contextCoverage(self: *const ConversationWriter, alloc: Allocator, cut: types.ContextHistoryCut, upcoming: []const session_event.ConversationEvent) !u64 {
        var progress: ConversationProgress = .{};
        try self.scanContext(alloc, &progress, cut);
        for (upcoming, 0..) |event, index| {
            const seq = std.math.add(u64, self.last_seq, index + 1) catch return error.ConversationSequenceOverflow;
            try progress.observe(seq, event, cut);
        }
        if (!progress.reached and !std.meta.eql(cut, types.ContextHistoryCut{})) return error.InvalidContextHistoryStart;
        return progress.coverage;
    }

    pub fn readAllForTest(self: *const ConversationWriter, alloc: Allocator) ![]u8 {
        const size = std.math.cast(usize, self.committed_bytes) orelse
            return error.ConversationTooLarge;
        const bytes = try alloc.alloc(u8, size);
        errdefer mem_utils.free(alloc, bytes);
        const count = try self.file.readPositionalAll(io_mod.getIo(), bytes, 0);
        if (count != size) return error.TruncatedConversation;
        return bytes;
    }

    fn pendingIndex(self: *const ConversationWriter, call_id: []const u8) ?usize {
        for (self.pending_tool_calls.items, 0..) |pending, index| {
            if (std.mem.eql(u8, pending.call_id, call_id)) return index;
        }
        return null;
    }

    fn appendBatch(
        self: *ConversationWriter,
        alloc: Allocator,
        timestamp_ms: i64,
        events: []const session_event.ConversationEvent,
    ) !void {
        if (self.failure) |err| return err;
        if (events.len == 0) return;
        if (self.pending_tool_calls.items.len != 0) return error.UnresolvedToolCall;

        var pending: std.ArrayList(session_event.PendingToolCall) = .empty;
        defer pending.deinit(alloc);
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        var seq = self.last_seq;
        var checkpoint_coverage = self.latest_checkpoint_coverage;
        var turn_open = self.turn_open;
        for (events) |event| {
            seq = std.math.add(u64, seq, 1) catch
                return error.ConversationSequenceOverflow;
            const envelope = session_event.ConversationEnvelope{
                .seq = seq,
                .timestamp_ms = timestamp_ms,
                .event = event,
            };
            try session_event.validateConversationTransition(.{
                .last_seq = seq - 1,
                .latest_checkpoint_coverage = checkpoint_coverage,
                .pending_tool_calls = pending.items,
            }, envelope);
            turn_open = try nextConversationTurnOpen(turn_open, event);
            switch (event) {
                .tool_call => |call| try pending.append(alloc, .{
                    .call_id = call.call_id,
                    .tool_name = call.tool_name,
                    .seq = seq,
                }),
                .tool_result => |result| {
                    for (pending.items, 0..) |call, index| {
                        if (std.mem.eql(u8, call.call_id, result.call_id)) {
                            _ = pending.orderedRemove(index);
                            break;
                        }
                    }
                },
                .interrupted => pending.clearRetainingCapacity(),
                .context_checkpoint => |checkpoint| checkpoint_coverage =
                    checkpoint.covers_through_seq,
                else => {},
            }
            const frame = try session_event.encodeConversationFrame(alloc, envelope);
            defer alloc.free(frame);
            try out.writer.writeAll(frame);
        }
        if (pending.items.len != 0) return error.UnresolvedToolCall;
        try self.writePrepared(out.written());
        self.last_seq = seq;
        self.latest_checkpoint_coverage = checkpoint_coverage;
        self.turn_open = turn_open;
    }

    fn writePrepared(self: *ConversationWriter, bytes: []const u8) !void {
        if (self.failure) |err| return err;
        const next_bytes = std.math.add(u64, self.committed_bytes, bytes.len) catch
            return error.ConversationSizeOverflow;
        if (try self.file.length(io_mod.getIo()) != self.committed_bytes) {
            self.failure = error.SessionWriterChanged;
            debug_trace.logf("session", "conversation writer changed outside ownership offset={d}", .{self.committed_bytes});
            return error.SessionWriterChanged;
        }
        self.file.writePositionalAll(io_mod.getIo(), bytes, self.committed_bytes) catch |err| {
            return self.rollbackAppend(err);
        };
        self.syncAppend() catch |err| return self.rollbackAppend(err);
        self.committed_bytes = next_bytes;
    }

    fn syncAppend(self: *ConversationWriter) !void {
        if (comptime builtin.is_test) {
            return self.test_sync_ops.sync_file(self.test_sync_ops.ctx, self.file);
        }
        try self.file.sync(io_mod.getIo());
    }

    fn rollbackAppend(self: *ConversationWriter, original: anyerror) anyerror {
        self.failure = error.SessionPersistenceUncertain;
        self.file.setLength(io_mod.getIo(), self.committed_bytes) catch |err| {
            debug_trace.logf("session", "conversation append rollback failed offset={d} append_err={s} rollback_err={s}", .{ self.committed_bytes, @errorName(original), @errorName(err) });
            return error.SessionPersistenceUncertain;
        };
        self.syncAppend() catch |err| {
            debug_trace.logf("session", "conversation append rollback sync failed offset={d} append_err={s} rollback_err={s}", .{ self.committed_bytes, @errorName(original), @errorName(err) });
            return error.SessionPersistenceUncertain;
        };
        self.failure = null;
        debug_trace.logf("session", "conversation append rolled back offset={d} err={s}", .{ self.committed_bytes, @errorName(original) });
        return original;
    }

    fn clearPendingToolCalls(self: *ConversationWriter) void {
        for (self.pending_tool_calls.items) |pending| {
            self.alloc.free(@constCast(pending.call_id));
            self.alloc.free(@constCast(pending.tool_name));
        }
        self.pending_tool_calls.clearRetainingCapacity();
    }

    fn applyReplayedEvent(
        self: *ConversationWriter,
        seq: u64,
        event: session_event.ConversationEvent,
    ) !void {
        const turn_open = try nextConversationTurnOpen(self.turn_open, event);
        switch (event) {
            .tool_call => |call| {
                const call_id = try self.alloc.dupe(u8, call.call_id);
                errdefer mem_utils.free(self.alloc, call_id);
                const tool_name = try self.alloc.dupe(u8, call.tool_name);
                errdefer mem_utils.free(self.alloc, tool_name);
                try self.pending_tool_calls.append(self.alloc, .{
                    .call_id = call_id,
                    .tool_name = tool_name,
                    .seq = seq,
                });
            },
            .tool_result => |result| {
                const index = self.pendingIndex(result.call_id) orelse
                    return error.OrphanToolResult;
                const completed = self.pending_tool_calls.orderedRemove(index);
                self.alloc.free(@constCast(completed.call_id));
                self.alloc.free(@constCast(completed.tool_name));
            },
            .context_checkpoint => |checkpoint| {
                self.latest_checkpoint_coverage = checkpoint.covers_through_seq;
            },
            .interrupted => self.clearPendingToolCalls(),
            .user, .assistant, .steering, .turn_completed => {},
        }
        self.last_seq = seq;
        self.turn_open = turn_open;
    }
};

fn nextConversationTurnOpen(open: bool, event: session_event.ConversationEvent) !bool {
    return switch (event) {
        .user => if (open) error.InvalidConversationFrame else true,
        .turn_completed, .interrupted => if (open) false else error.InvalidConversationFrame,
        .assistant, .tool_call, .tool_result, .steering => if (open) true else error.InvalidConversationFrame,
        .context_checkpoint => open,
    };
}

fn createConversationStorage(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    metadata: session_codec.SessionMetadata,
) !ConversationWriter {
    const metadata_bytes = try session_codec.encodeSessionMetadata(alloc, metadata);
    defer alloc.free(metadata_bytes);
    try io_mod.durableReplaceVerified(alloc, dir, manifest_file, metadata_bytes);
    errdefer {
        dir.dir.deleteFile(io_mod.getIo(), manifest_file) catch {};
        io_mod.syncVerifiedDir(dir.dir) catch {};
    }

    const file = createManagedFile(dir, events_file) catch |err| switch (err) {
        error.PathAlreadyExists => return error.SessionAlreadyExists,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    // Fresh sessions keep the minimal durable footprint; the replay cache is
    // built lazily by the first writable resume (see openConversationWritableSession).
    return ConversationWriter.init(alloc, file);
}

fn writeConversationMetadata(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    state: session_codec.DurableSessionState,
) !void {
    const existing = readManagedFileAlloc(
        alloc,
        dir,
        manifest_file,
        session_codec.max_session_metadata_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |bytes| alloc.free(bytes);
    var decoded = if (existing) |bytes|
        try session_codec.decodeSessionMetadata(alloc, bytes)
    else
        null;
    defer if (decoded) |*metadata| metadata.deinit();
    const bytes = try encodeConversationMetadataWithTitle(
        alloc,
        state,
        if (decoded) |metadata| metadata.value.title else null,
    );
    defer alloc.free(bytes);
    try io_mod.durableReplaceVerified(alloc, dir, manifest_file, bytes);
}

fn encodeConversationMetadataWithTitle(
    alloc: Allocator,
    state: session_codec.DurableSessionState,
    title: ?[]const u8,
) ![]u8 {
    return session_codec.encodeSessionMetadata(alloc, .{
        .id = state.id,
        .origin_workspace_root = state.origin_workspace_root,
        .workspace_root = state.workspace_root,
        .created_at_ms = state.created_at_ms,
        .updated_at_ms = state.updated_at_ms,
        .conversation_language = state.conversation_language.view(),
        .provider = state.preferences.provider,
        .model = state.preferences.model,
        .effort = state.preferences.effort.label(),
        .fast_mode = state.preferences.fast_mode,
        .ultrafast_mode = if (state.preferences.ultrafast_mode) true else null,
        .title = title,
        .subagent_child = state.subagent_child,
    });
}

fn writeConversationControlState(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    state: session_codec.DurableSessionState,
    conversation_seq: u64,
) !void {
    const permission_bytes = try session_codec.encodePermissionState(
        alloc,
        state.permission_state,
    );
    defer alloc.free(permission_bytes);
    try io_mod.durableReplaceVerified(
        alloc,
        dir,
        permission_state_file,
        permission_bytes,
    );
    if (state.usage) |usage| {
        try session_usage_sidecar.write(alloc, dir, state.id, usage);
    }
    try writeConversationRecoveryState(alloc, dir, state.recovery_checkpoint, conversation_seq);
}

fn writeConversationRecoveryState(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    recovery_checkpoint: ?session_codec.RecoveryCheckpoint,
    conversation_seq: u64,
) !void {
    if (recovery_checkpoint) |checkpoint| {
        var projection_arena = std.heap.ArenaAllocator.init(alloc);
        defer mem_utils.deinit_arena(projection_arena);
        const projected = try spillRecoveryCheckpointOutputs(
            projection_arena.allocator(),
            dir,
            checkpoint,
        );
        const recovery_bytes = session_codec.encodeRecoveryCheckpoint(
            alloc,
            projected,
        ) catch |err| switch (err) {
            // The durable checkpoint is a resume aid, not turn-critical
            // state. An oversized checkpoint keeps the previously persisted
            // file and the turn continues; in-memory state still advances.
            error.RecoveryCheckpointTooLarge => {
                debug_trace.logf(
                    "session",
                    "event=recovery_checkpoint_oversized cap_bytes={d}; keeping previous durable checkpoint",
                    .{session_codec.max_recovery_checkpoint_bytes},
                );
                return;
            },
            else => return err,
        };
        defer alloc.free(recovery_bytes);
        const bound_bytes = try alloc.print(
            "{{\"conversation_seq\":{d},\"checkpoint\":{s}}}\n",
            .{ conversation_seq, recovery_bytes },
        );
        defer alloc.free(bound_bytes);
        try io_mod.durableReplaceVerified(
            alloc,
            dir,
            recovery_checkpoint_file,
            bound_bytes,
        );
        // A fresh checkpoint is a new recovery state; any prior suppression
        // belonged to the turn it replaces.
        clearRecoveryAsked(dir);
    } else {
        dir.dir.deleteFile(io_mod.getIo(), recovery_checkpoint_file) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        clearRecoveryAsked(dir);
        try io_mod.syncVerifiedDir(dir.dir);
    }
}

fn clearRecoveryAsked(dir: *io_mod.VerifiedDir) void {
    dir.dir.deleteFile(io_mod.getIo(), recovery_asked_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => debug_trace.logf("session", "recovery ask marker clear failed err={s}", .{@errorName(err)}),
    };
}

/// Records that resume suppressed this checkpoint's auto-continue once.
/// Advisory like owner.live: write failures degrade to a single suppression
/// instead of blocking the resume.
pub fn markRecoveryAsked(alloc: Allocator, dir: *io_mod.VerifiedDir) void {
    const body = alloc.print("{{\"asked_at_ms\":{d}}}\n", .{io_mod.milliTimestamp()}) catch |err| {
        debug_trace.logf("session", "recovery ask marker allocation failed err={s}", .{@errorName(err)});
        return;
    };
    defer alloc.free(body);
    io_mod.durableReplaceVerified(alloc, dir, recovery_asked_file, body) catch |err| {
        debug_trace.logf("session", "recovery ask marker write failed err={s}", .{@errorName(err)});
    };
}

/// True when a prior resume already suppressed this checkpoint. Read at
/// decision time; the marker is written mid-session, after the open.
pub fn recoveryWasAsked(dir: *io_mod.VerifiedDir) bool {
    return entryExists(dir, recovery_asked_file) catch |err| blk: {
        debug_trace.logf("session", "recovery ask marker probe failed err={s}", .{@errorName(err)});
        break :blk false;
    };
}

/// Inline tool-result output budget for the durable recovery checkpoint.
/// Larger outputs live in the session's result store and the checkpoint
/// carries their content-addressed handle instead.
const recovery_checkpoint_inline_output_max_bytes: usize = result_store.preview_bytes;

/// Inline budget for committed-edit previous/after snapshots inside durable
/// records (conversation log, recovery checkpoint). Larger contents move to a
/// result-store artifact and the record carries its content-addressed handle.
const file_presentation_inline_max_bytes: usize = result_store.preview_bytes;

fn presentationNeedsSpill(presentation: types.CommittedFilePresentation) !bool {
    if (!types.committedFilePresentationContentSourceValid(presentation)) {
        return error.InvalidCommittedFilePresentation;
    }
    if (presentation.content_handle != null) return false;
    const previous_bytes = if (presentation.previous_content) |content| content.len else 0;
    const after_bytes = if (presentation.after_content) |content| content.len else 0;
    return previous_bytes +| after_bytes > file_presentation_inline_max_bytes;
}

/// Spills one result's oversized diff snapshots into the session result
/// store, returning a copy whose presentation carries only the handle. Store
/// or path failures keep the presentation inline so a hiccup cannot block the
/// enclosing commit. `result_dir` is resolved lazily and reused across calls.
fn spillResultFilePresentation(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    result_dir: *?[]const u8,
    result: types.PersistedToolResult,
) !types.PersistedToolResult {
    const presentation = result.committed_file_presentation orelse return result;
    if (!try presentationNeedsSpill(presentation)) return result;
    if (result_dir.* == null) {
        const base = io_mod.dirRealpathAlloc(alloc, dir.dir, ".") catch |err| {
            const path_err: anyerror = err;
            if (path_err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf(
                "session",
                "event=diff_content_spill_unavailable err={s}; keeping presentation inline",
                .{@errorName(path_err)},
            );
            return result;
        };
        defer alloc.free(base);
        result_dir.* = try std.Io.Dir.path.join(alloc, &.{ base, "tool-results" });
    }
    const handle = result_store.storeDiffContent(
        alloc,
        result_dir.*.?,
        result.tool_call_id,
        presentation.previous_content,
        presentation.after_content,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf(
                "session",
                "event=diff_content_spill_failed call_id={s} err={s}; keeping presentation inline",
                .{ result.tool_call_id, @errorName(err) },
            );
            return result;
        },
    };
    debug_trace.logf(
        "session",
        "event=diff_content_spilled call_id={s} previous_bytes={d} after_bytes={d}",
        .{
            result.tool_call_id,
            if (presentation.previous_content) |content| content.len else 0,
            if (presentation.after_content) |content| content.len else 0,
        },
    );
    var projected = result;
    var projected_presentation = presentation;
    projected_presentation.previous_content = null;
    projected_presentation.after_content = null;
    projected_presentation.content_handle = handle;
    projected.committed_file_presentation = projected_presentation;
    return projected;
}

/// Returns a copy of `turn` whose oversized committed-edit snapshots are
/// spilled to the session result store. Untouched payloads keep borrowing the
/// source turn; spilled handles and projected slices are allocated from
/// `alloc`, which the caller releases in bulk after the append. Only OOM
/// propagates; store failures keep the offending presentation inline.
fn spillHistoryTurnFilePresentations(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    turn: types.HistoryTurn,
) !types.HistoryTurn {
    const execution = switch (turn) {
        .assistant => |entry| entry.execution,
        .interrupted => |entry| entry.execution,
        .compacted_summary => return turn,
    };
    var needs_spill = false;
    scan: for (execution.tool_steps) |step| {
        for (step.tool_results) |result| {
            if (result.committed_file_presentation) |presentation| {
                if (try presentationNeedsSpill(presentation)) {
                    needs_spill = true;
                    break :scan;
                }
            }
        }
    }
    if (!needs_spill) return turn;

    var result_dir: ?[]const u8 = null;
    const steps = try alloc.alloc(types.ToolExecutionStep, execution.tool_steps.len);
    for (execution.tool_steps, 0..) |step, index| {
        steps[index] = step;
        var step_needs_spill = false;
        for (step.tool_results) |result| {
            if (result.committed_file_presentation) |presentation| {
                if (try presentationNeedsSpill(presentation)) {
                    step_needs_spill = true;
                    break;
                }
            }
        }
        if (!step_needs_spill) continue;
        const results = try alloc.alloc(types.PersistedToolResult, step.tool_results.len);
        for (step.tool_results, 0..) |result, result_index| {
            results[result_index] = try spillResultFilePresentation(alloc, dir, &result_dir, result);
        }
        steps[index].tool_results = results;
    }
    var projected = turn;
    switch (projected) {
        .assistant => |*entry| entry.execution.tool_steps = steps,
        .interrupted => |*entry| entry.execution.tool_steps = steps,
        .compacted_summary => {},
    }
    return projected;
}

/// Appends one durable history turn after projecting oversized committed-file
/// snapshots into the session result store. Every product path that seeds,
/// imports, restores, or commits history uses this boundary.
fn appendPersistedHistoryTurn(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    writer: *ConversationWriter,
    timestamp_ms: i64,
    turn: types.HistoryTurn,
) !void {
    var spill_arena = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(spill_arena);
    const projected = try spillHistoryTurnFilePresentations(
        spill_arena.allocator(),
        dir,
        turn,
    );
    try writer.appendHistoryTurn(alloc, timestamp_ms, projected);
}

/// Returns a copy of the checkpoint whose oversized tool-result outputs are
/// spilled to the session result store and replaced by their handle. The
/// source checkpoint is borrowed; the projection owns only its own
/// allocations, and `alloc` is expected to free them in bulk. Spill failures
/// keep the offending result inline so a store hiccup cannot block the
/// checkpoint write.
fn spillRecoveryCheckpointOutputs(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    checkpoint: session_codec.RecoveryCheckpoint,
) !session_codec.RecoveryCheckpoint {
    var spills = false;
    scan: for (checkpoint.execution.tool_steps) |step| {
        for (step.tool_results) |result| {
            if (result.output_handle != null or
                result.output.len > recovery_checkpoint_inline_output_max_bytes)
            {
                spills = true;
                break :scan;
            }
            if (result.committed_file_presentation) |presentation| {
                if (try presentationNeedsSpill(presentation)) {
                    spills = true;
                    break :scan;
                }
            }
        }
    }
    if (!spills) return checkpoint;

    var result_dir: ?[]const u8 = null;
    const steps = try alloc.alloc(types.ToolExecutionStep, checkpoint.execution.tool_steps.len);
    for (checkpoint.execution.tool_steps, 0..) |step, index| {
        steps[index] = step;
        var results_changed = false;
        for (step.tool_results) |result| {
            if (result.output_handle != null or
                result.output.len > recovery_checkpoint_inline_output_max_bytes)
            {
                results_changed = true;
                break;
            }
            if (result.committed_file_presentation) |presentation| {
                if (try presentationNeedsSpill(presentation)) {
                    results_changed = true;
                    break;
                }
            }
        }
        if (!results_changed) continue;
        const results = try alloc.alloc(types.PersistedToolResult, step.tool_results.len);
        for (step.tool_results, 0..) |result, result_index| {
            results[result_index] = try projectRecoveryResult(alloc, dir, &result_dir, result);
        }
        steps[index].tool_results = results;
    }
    var projected = checkpoint;
    projected.execution.tool_steps = steps;
    return projected;
}

fn projectRecoveryResult(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    result_dir: *?[]const u8,
    result: types.PersistedToolResult,
) !types.PersistedToolResult {
    var projected = result;
    // Only spill output the restore path can read back; larger inline output
    // stays put and the oversize guard in writeConversationRecoveryState
    // covers the checkpoint as a whole.
    if (projected.output_handle == null and
        projected.output.len > recovery_checkpoint_inline_output_max_bytes and
        projected.output.len <= result_store.stored_text_max_bytes)
    {
        if (result_dir.* == null) {
            const base = io_mod.dirRealpathAlloc(alloc, dir.dir, ".") catch |err| {
                const path_err: anyerror = err;
                if (path_err == error.OutOfMemory) return error.OutOfMemory;
                debug_trace.logf(
                    "session",
                    "event=recovery_checkpoint_spill_unavailable err={s}; keeping result inline",
                    .{@errorName(path_err)},
                );
                return projected;
            };
            defer alloc.free(base);
            result_dir.* = try std.Io.Dir.path.join(alloc, &.{ base, "tool-results" });
        }
        const handle = result_store.storeLargeResult(
            alloc,
            result_dir.*.?,
            result.tool_call_id,
            result.tool_name,
            result.output,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf(
                    "session",
                    "event=recovery_checkpoint_spill_failed tool_call_id={s} err={s}; keeping result inline",
                    .{ result.tool_call_id, @errorName(err) },
                );
                return projected;
            },
        };
        projected.output_handle = handle;
        projected.stored_output_bytes = result.output.len;
    }
    if (projected.output_handle != null and projected.output.len != 0) {
        if (projected.preview == null) {
            projected.preview = try result_store.previewText(alloc, result.output, result_store.preview_bytes);
        }
        projected.output = "";
    }
    return spillResultFilePresentation(alloc, dir, result_dir, projected);
}

fn loadConversationPermissionState(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !session_permission_state.State {
    const bytes = readManagedFileAlloc(
        alloc,
        dir,
        permission_state_file,
        session_codec.max_permission_state_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer alloc.free(bytes);
    return session_codec.decodePermissionState(alloc, bytes);
}

fn loadConversationRecoveryCheckpoint(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    conversation_seq: u64,
) !?session_codec.RecoveryCheckpoint {
    const bytes = readManagedFileAlloc(
        alloc,
        dir,
        recovery_checkpoint_file,
        session_codec.max_recovery_checkpoint_bytes + 128,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(struct {
        conversation_seq: u64,
        checkpoint: std.json.Value,
    }, alloc, bytes, .{
        .max_value_len = session_codec.max_recovery_checkpoint_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRecoveryCheckpoint,
    };
    defer parsed.deinit();
    if (parsed.value.conversation_seq < conversation_seq) return null;
    if (parsed.value.conversation_seq != conversation_seq) return error.InvalidRecoveryCheckpoint;
    return session_codec.parseRecoveryCheckpoint(alloc, parsed.value.checkpoint) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRecoveryCheckpoint,
    };
}

fn loadConversationStateIfPresent(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    expected_session_id: []const u8,
) !?session_codec.DurableSessionState {
    return load_conversation_state_at_boundary(alloc, dir, expected_session_id, null, null, null, null);
}

/// Loads owned detail state, distinguishing unreadable conversation history
/// from supporting-file errors. Writable resume retains its original errors.
pub fn loadConversationDetailState(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !session_codec.DurableSessionState {
    var history_failed = false;
    return (load_conversation_state_at_boundary(alloc, dir, session_id, null, null, &history_failed, null) catch |err| {
        if (err == error.OutOfMemory or !history_failed) return err;
        debug_trace.logf("session", "conversation detail history unavailable id={s} err={s}", .{ session_id, @errorName(err) });
        return error.ConversationHistoryUnavailable;
    }) orelse error.SessionMigrationRequired;
}

fn load_conversation_state_at_boundary(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    expected_session_id: []const u8,
    recovery: ?ConversationRecoveryBoundary,
    replay_window: ?ConversationReplayWindow,
    history_failed: ?*bool,
    history_source: ?*HistoryFrameSource,
) !?session_codec.DurableSessionState {
    const metadata_bytes = readManagedFileAlloc(
        alloc,
        dir,
        manifest_file,
        session_codec.max_session_metadata_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(metadata_bytes);
    var probe = std.json.parseFromSlice(std.json.Value, alloc, metadata_bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer probe.deinit();
    const object = if (probe.value == .object) probe.value.object else return null;
    const version_value = object.get("schema_version") orelse return null;
    if (version_value != .number_string or
        !std.mem.eql(u8, version_value.number_string, "4"))
    {
        return null;
    }

    var metadata = try session_codec.decodeSessionMetadata(alloc, metadata_bytes);
    defer metadata.deinit();
    if (!std.mem.eql(u8, metadata.value.id, expected_session_id)) {
        return error.InvalidSessionMetadata;
    }
    var conversation_seq: u64 = 0;
    var open_work_id: ?[]u8 = null;
    defer if (open_work_id) |work_id| alloc.free(work_id);
    const history = blk: {
        errdefer if (history_failed) |failed| {
            failed.* = true;
        };
        var event_file = try openManagedFile(dir, events_file, .read_only);
        defer event_file.close(io_mod.getIo());
        const length = if (recovery) |boundary| boundary.bytes else try event_file.length(io_mod.getIo());
        // Recovery boundaries keep the raw-log path; the snapshot cache covers
        // only full loads, where a prefix replay splices into the live log.
        if (recovery != null) {
            var pure_log = HistoryFrameSource{ .log_file = event_file, .log_length = length, .limit = length };
            break :blk try replayConversationHistory(alloc, &pure_log, &conversation_seq, &open_work_id, replay_window);
        }
        var owned_source: HistoryFrameSource = undefined;
        const frames = history_source orelse frames_blk: {
            owned_source = try HistoryFrameSource.open(alloc, dir, expected_session_id, event_file, length);
            break :frames_blk &owned_source;
        };
        defer if (history_source == null) frames.deinit(alloc);
        const result = replayConversationHistory(alloc, frames, &conversation_seq, &open_work_id, replay_window) catch |err| retry: {
            if (err == error.OutOfMemory or frames.verified == null) return err;
            // A cache-sourced replay failure is a cache problem, not a log
            // problem: retry once from the raw log so the cache can never fail
            // a load. The writable caller owns rebuild decisions; read-only
            // loads just fall back.
            debug_trace.logf("session", "history cache replay rejected id={s} err={s}; reading log", .{ expected_session_id, @errorName(err) });
            conversation_seq = 0;
            open_work_id = null;
            frames.verified_cleanup(alloc);
            frames.reset();
            if (history_source != null) history_snapshot.deleteForRebuild(dir);
            break :retry try replayConversationHistory(alloc, frames, &conversation_seq, &open_work_id, replay_window);
        };
        break :blk result;
    };
    errdefer session.freeHistoryTurnSlice(alloc, history);
    if (recovery == null) try restoreContextResultBodies(alloc, dir, history);
    const latest_work_id = if (recovery != null and recovery.?.turn_open and open_work_id != null)
        open_work_id
    else
        latestConversationWorkId(history);
    const last_work_id = if (latest_work_id) |work_id|
        try alloc.dupe(u8, work_id)
    else
        null;
    errdefer if (last_work_id) |work_id| mem_utils.free(alloc, work_id);
    var usage: ?session_usage.Snapshot = try session_usage_sidecar.loadConversation(
        alloc,
        dir,
        expected_session_id,
        metadata.value.updated_at_ms,
    );
    errdefer if (usage) |*snapshot| snapshot.deinit(alloc);
    var permission_state = try loadConversationPermissionState(alloc, dir);
    errdefer permission_state.deinit(alloc);
    var recovery_checkpoint = if (recovery == null)
        try loadConversationRecoveryCheckpoint(alloc, dir, conversation_seq)
    else
        null;
    errdefer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
    if (recovery_checkpoint) |*checkpoint| {
        var capability: ?session_child_store.SessionChildCapability = null;
        defer if (capability) |*value| value.deinit();
        try restoreExecutionResultBodies(alloc, dir, &capability, &checkpoint.execution);
        if (checkpoint.user.work_id == null) {
            checkpoint.user.work_id = open_work_id;
            open_work_id = null;
        }
    }
    const id = try alloc.dupe(u8, metadata.value.id);
    errdefer mem_utils.free(alloc, id);
    const origin = try alloc.dupe(u8, metadata.value.origin_workspace_root);
    errdefer mem_utils.free(alloc, origin);
    const workspace = try alloc.dupe(u8, metadata.value.workspace_root);
    errdefer mem_utils.free(alloc, workspace);
    const model = try alloc.dupe(u8, metadata.value.model);
    errdefer mem_utils.free(alloc, model);
    const language = session.ConversationLanguage.fromSlice(
        metadata.value.conversation_language,
    ) catch return error.InvalidSessionMetadata;
    const provider = metadata.value.provider;
    const effort = types.ReasoningEffort.parse(metadata.value.effort) orelse
        return error.InvalidSessionMetadata;
    return .{
        .id = id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = metadata.value.created_at_ms,
        .updated_at_ms = metadata.value.updated_at_ms,
        .conversation_language = language,
        .preferences = .{
            .provider = provider,
            .model = model,
            .effort = effort,
            .fast_mode = metadata.value.fast_mode,
            .ultrafast_mode = metadata.value.ultrafast_mode orelse false,
        },
        .history = history,
        .context_history_start = latestConversationCheckpointIndex(history),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .permission_state = permission_state,
        .last_subagent_work_id = last_work_id,
        .usage = usage,
        .recovery_checkpoint = recovery_checkpoint,
        .subagent_child = metadata.value.subagent_child,
    };
}

fn latestConversationWorkId(history: []const session.HistoryTurn) ?[]const u8 {
    var latest: ?[]const u8 = null;
    for (history) |turn| {
        if (session.historyTurnWorkId(turn)) |work_id| latest = work_id;
    }
    return latest;
}

pub fn hasConversationMetadata(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !bool {
    const bytes = (try readConversationMetadataBytes(alloc, dir)) orelse return false;
    defer alloc.free(bytes);
    return isConversationMetadata(alloc, bytes);
}

pub const ConversationRecoveryBoundary = struct {
    bytes: u64 = 0,
    seq: u64 = 0,
    timestamp_ms: i64 = 0,
    turn_open: bool = false,
};

const ConversationRecovery = struct {
    boundary: ConversationRecoveryBoundary,
    usage_incomplete: bool,
};

pub fn classify_conversation_recovery(alloc: Allocator, dir: *io_mod.VerifiedDir, session_id: []const u8) !ConversationRecovery {
    const scan = try scan_conversation_recovery(alloc, dir);
    const usage_incomplete = try session_usage_sidecar.has_recoverable_corruption(alloc, dir, session_id);
    if (scan.complete and !usage_incomplete) return error.SessionRecoveryNotNeeded;
    return .{ .boundary = scan.boundary, .usage_incomplete = usage_incomplete };
}

/// Reads only. The existing transition validator remains the record authority.
fn scan_conversation_recovery(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !struct { boundary: ConversationRecoveryBoundary, complete: bool } {
    var history_buffer: [8192]u8 = undefined;
    var reader = try ConversationHistoryReader.init(alloc, dir, &history_buffer);
    defer reader.deinit();
    const file = reader.file;
    const length = reader.length;
    reader.length = 0;
    var state = ConversationWriter{ .alloc = alloc, .file = file };
    defer {
        state.clearPendingToolCalls();
        state.pending_tool_calls.deinit(alloc);
    }
    var boundary: ConversationRecoveryBoundary = .{};
    var offset: u64 = 0;
    var coverage_seq: u64 = 0;
    var coverage_progress: ConversationProgress = .{};
    var buffer: [8192]u8 = undefined;
    var lines = file.reader(io_mod.getIo(), &buffer);
    var coverage_buffer: [8192]u8 = undefined;
    var coverage_lines = file.reader(io_mod.getIo(), &coverage_buffer);
    scan: while (offset < length) {
        const line = session_replay.readBufferedLine(alloc, &lines, length, null) catch |err| switch (err) {
            error.TruncatedEventFrame, error.EventFrameTooLarge => break,
            else => return err,
        } orelse break;
        defer alloc.free(line.bytes);
        var decoded = session_event.decodeConversationFrame(alloc, line.bytes) catch |err| switch (err) {
            error.InvalidConversationFrame => break,
            else => return err,
        };
        defer decoded.deinit();
        session_event.validateConversationTransition(.{
            .last_seq = state.last_seq,
            .latest_checkpoint_coverage = state.latest_checkpoint_coverage,
            .pending_tool_calls = state.pending_tool_calls.items,
        }, decoded.value) catch break;
        if (decoded.value.event == .context_checkpoint) {
            const coverage = decoded.value.event.context_checkpoint.covers_through_seq;
            // Coverage is monotone, so historical cuts need only one extra scan.
            while (coverage_seq < coverage) {
                const covered = (try session_replay.readBufferedLine(alloc, &coverage_lines, offset, null)) orelse
                    return error.SessionRecoveryBoundaryInvalid;
                defer alloc.free(covered.bytes);
                var frame = try session_event.decodeConversationFrame(alloc, covered.bytes);
                defer frame.deinit();
                try coverage_progress.observe(frame.value.seq, frame.value.event, null);
                coverage_seq = frame.value.seq;
            }
            if (coverage_progress.pending != 0) break :scan;
        }
        state.applyReplayedEvent(decoded.value.seq, decoded.value.event) catch |err| switch (err) {
            error.InvalidConversationFrame => break :scan,
            else => return err,
        };
        // A valid frame must also be replayable before it can extend the copy.
        reader.length = line.next_offset;
        if (reader.next() catch |err| switch (err) {
            error.InvalidConversationFrame, error.ConversationSizeOverflow => break :scan,
            else => return err,
        }) |turn| session.freeHistoryTurn(alloc, turn);
        offset = line.next_offset;
        if (!state.turn_open or
            (decoded.value.event == .context_checkpoint and state.pending_tool_calls.items.len == 0))
        {
            boundary = .{
                .bytes = offset,
                .seq = state.last_seq,
                .timestamp_ms = decoded.value.timestamp_ms,
                .turn_open = state.turn_open,
            };
        }
    }
    const complete = offset == length and boundary.bytes == length;
    if (!complete and boundary.bytes == 0) return error.SessionRecoveryBoundaryInvalid;
    debug_trace.logf("session", "event=conversation_recovery_boundary source_bytes={d} retained_bytes={d} through_seq={d}", .{ length, boundary.bytes, boundary.seq });
    return .{ .boundary = boundary, .complete = complete };
}

/// Caller owns the returned complete archive, with a checkpointed open turn
/// explicitly interrupted rather than scheduling its abandoned continuation.
pub fn load_conversation_recovery_state(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    boundary: ConversationRecoveryBoundary,
) !session_codec.DurableSessionState {
    const loaded = load_conversation_state_at_boundary(alloc, dir, session_id, boundary, null, null, null) catch |err| switch (err) {
        error.InvalidSessionMetadata, error.InvalidSessionFormat => return error.SessionRecoveryBoundaryInvalid,
        else => return err,
    };
    var state = loaded orelse return error.SessionRecoveryBoundaryInvalid;
    errdefer state.deinit(alloc);
    const file = try openManagedFile(dir, events_file, .read_only);
    defer file.close(io_mod.getIo());
    const archive = try load_conversation_archive_from_file(alloc, file, boundary.bytes, boundary.turn_open);
    session.freeHistoryTurnSlice(alloc, state.history);
    state.history = archive;
    state.context_history_start = latestConversationCheckpointIndex(archive);
    return state;
}

/// Installs exact validated records in an unpublished target; never edits source.
pub fn copy_conversation_recovery_prefix(
    alloc: Allocator,
    source: *io_mod.VerifiedDir,
    target: *io_mod.VerifiedDir,
    boundary: ConversationRecoveryBoundary,
) !void {
    const input = try openManagedFile(source, events_file, .read_only);
    defer input.close(io_mod.getIo());
    const output = try openManagedFile(target, events_file, .read_write);
    defer output.close(io_mod.getIo());
    var buffer: [8192]u8 = undefined;
    var offset: u64 = 0;
    while (offset < boundary.bytes) {
        const count: usize = @intCast(@min(buffer.len, boundary.bytes - offset));
        if (try input.readPositionalAll(io_mod.getIo(), buffer[0..count], offset) != count)
            return error.SessionRecoveryBoundaryInvalid;
        try output.writePositionalAll(io_mod.getIo(), buffer[0..count], offset);
        offset += count;
    }
    if (boundary.turn_open) {
        const interrupted = try session_event.encodeConversationFrame(alloc, .{
            .seq = try std.math.add(u64, boundary.seq, 1),
            .timestamp_ms = boundary.timestamp_ms,
            .event = .{ .interrupted = .{ .reason = .failed } },
        });
        defer alloc.free(interrupted);
        try output.writePositionalAll(io_mod.getIo(), interrupted, offset);
        offset = try std.math.add(u64, offset, interrupted.len);
    }
    try output.setLength(io_mod.getIo(), offset);
    try output.sync(io_mod.getIo());
    debug_trace.logf("session", "event=conversation_recovery_prefix bytes={d} through_seq={d} interrupted={}", .{ boundary.bytes, boundary.seq, boundary.turn_open });
}

/// Reads and validates current metadata once. The caller owns the decoded value.
pub fn readConversationMetadata(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !?session_codec.DecodedSessionMetadata {
    const bytes = (try readConversationMetadataBytes(alloc, dir)) orelse return null;
    defer alloc.free(bytes);
    if (!try isConversationMetadata(alloc, bytes)) return null;
    return session_codec.decodeSessionMetadata(alloc, bytes) catch |err| switch (err) {
        error.SessionMetadataTooLarge => error.InvalidSessionFormat,
        else => err,
    };
}

fn readConversationMetadataBytes(alloc: Allocator, dir: *io_mod.VerifiedDir) !?[]u8 {
    const bytes = readManagedFileAlloc(
        alloc,
        dir,
        manifest_file,
        session_codec.max_session_metadata_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound, error.InvalidSessionFormat => return null,
        else => return err,
    };
    return bytes;
}

fn isConversationMetadata(alloc: Allocator, bytes: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer parsed.deinit();
    const object = if (parsed.value == .object) parsed.value.object else return false;
    const version = object.get("schema_version") orelse return false;
    return version == .number_string and std.mem.eql(u8, version.number_string, "4");
}

fn openConversationWritableSession(
    alloc: Allocator,
    writable: *WritableSessionDir,
) !LoadedWritableSession {
    var event_file = try openManagedFile(&writable.dir, events_file, .read_write);
    const log_length = try event_file.length(io_mod.getIo());

    // Verify the replay cache against the log, then scan from it. Any
    // cache-origin failure discards the cache and retries from the raw log, so
    // a bad cache can never block a resume.
    var source: ?HistoryFrameSource = null;
    var replay_scan: ConversationReplayScan = .{};
    var conversation_writer: ConversationWriter = undefined;
    var snapshot_writer: ?history_snapshot.Writer = null;
    var cache_retry_spent = false;
    while (true) {
        source = try HistoryFrameSource.open(alloc, &writable.dir, writable.session_id, event_file, log_length);
        const used_cache = !cache_retry_spent and source.?.verified != null;
        snapshot_writer = if (source.?.verified) |*verified|
            history_snapshot.Writer.beginAppend(alloc, &writable.dir, verified.prefix_file_bytes) catch |err| blk: {
                debug_trace.logf("session", "history cache append-open failed id={s} err={s}", .{ writable.session_id, @errorName(err) });
                break :blk null;
            }
        else if (log_length == 0)
            // A brand-new conversation keeps the minimal durable footprint; the
            // cache is built by the first resume with real content.
            null
        else
            history_snapshot.Writer.beginReplace(alloc, &writable.dir, writable.session_id) catch |err| blk: {
                debug_trace.logf("session", "history cache rebuild-open failed id={s} err={s}", .{ writable.session_id, @errorName(err) });
                break :blk null;
            };
        conversation_writer = ConversationWriter.initWithReplayScan(
            alloc,
            event_file,
            &replay_scan,
            &source.?,
            if (snapshot_writer) |*writer| writer else null,
        ) catch |err| {
            if (snapshot_writer) |*writer| writer.finalize();
            snapshot_writer = null;
            source.?.deinit(alloc);
            source = null;
            if (err == error.OutOfMemory) {
                event_file.close(io_mod.getIo());
                return err;
            }
            if (used_cache) {
                // A cache-backed scan failure is a cache problem, not a log
                // problem: drop the cache and retry from the raw log once.
                // The scan state observed partial cache frames, so it must be
                // reset or the retry's first log frame fails seq continuity.
                // The spent flag makes termination structural even when the
                // delete itself fails and the next open verifies again.
                debug_trace.logf("session", "history cache scan rejected id={s} err={s}; rebuilding from log", .{ writable.session_id, @errorName(err) });
                history_snapshot.deleteForRebuild(&writable.dir);
                replay_scan = .{};
                cache_retry_spent = true;
                continue;
            }
            event_file.close(io_mod.getIo());
            return err;
        };
        break;
    }
    var frames = &source.?;
    errdefer frames.deinit(alloc);
    // The cache is written only by the open-time scan tee; nothing appends at
    // commit time, so the tee writer is finalized here and no writer state
    // leaks into the session writer.
    if (snapshot_writer) |*writer| writer.finalize();
    snapshot_writer = null;
    errdefer conversation_writer.deinit();
    if (conversation_writer.turn_open) {
        var recovery = try loadConversationRecoveryCheckpoint(
            alloc,
            &writable.dir,
            conversation_writer.last_seq,
        );
        defer if (recovery) |*checkpoint| checkpoint.deinit(alloc);
        if (recovery == null) {
            const interrupted: session_event.ConversationEvent = .{
                .interrupted = .{ .reason = .failed },
            };
            const offset = conversation_writer.committed_bytes;
            _ = try conversation_writer.append(alloc, io_mod.milliTimestamp(), interrupted);
            try replay_scan.observe(offset, conversation_writer.last_seq, interrupted);
        }
    }
    const replay_window = try replay_scan.finish(alloc, frames);
    var state = (try load_conversation_state_at_boundary(
        alloc,
        &writable.dir,
        writable.session_id,
        null,
        replay_window,
        null,
        frames,
    )) orelse return error.InvalidSessionMetadata;
    errdefer state.deinit(alloc);
    if (state.recovery_checkpoint) |checkpoint| {
        if (checkpoint.cause == .compaction_prepared) {
            // This checkpoint records completed source, not permission to run
            // captured work. Make it ordinary interrupted history before a new
            // prompt can replace the recovery slot. Sequence binding makes a
            // crash after this append safe even if sidecar cleanup did not run.
            const timestamp = io_mod.milliTimestamp();
            try appendPersistedHistoryTurn(
                alloc,
                &writable.dir,
                &conversation_writer,
                timestamp,
                checkpoint.interruptedTurn(),
            );
            writeConversationRecoveryState(alloc, &writable.dir, null, conversation_writer.last_seq) catch |err| {
                debug_trace.logf("session", "compaction source committed but recovery cleanup failed err={s}", .{@errorName(err)});
            };
            var restored = (try load_conversation_state_at_boundary(alloc, &writable.dir, writable.session_id, null, null, null, frames)) orelse return error.InvalidSessionMetadata;
            restored.updated_at_ms = timestamp;
            state.deinit(alloc);
            state = restored;
            debug_trace.logf("session", "event=compaction_source_restored session={s} through_seq={d}", .{ writable.session_id, conversation_writer.last_seq });
        }
    }
    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer mem_utils.free(alloc, active_id);
    const generation = randomIdentifier();
    const position = CommitPosition{
        .log_generation = generation,
        .through_seq = conversation_writer.last_seq,
        .through_event_id = randomIdentifier(),
        .through_event_log_bytes = conversation_writer.committed_bytes,
    };
    frames.deinit(alloc);
    const result = LoadedWritableSession{
        .active_id = active_id,
        .state = state,
        .conversation_writer = conversation_writer,
        .log = writable.*,
        .position = position,
    };
    writable.* = undefined;
    return result;
}

/// One replay frame regardless of origin. Snapshot frames carry their verified
/// decoded envelope; log frames decode the JSON line as before.
const HistoryFrame = struct {
    log_offset: u64,
    log_bytes: u32,
    line_crc: u32,
    envelope: session_event.ConversationEnvelope,

    fn nextOffset(self: HistoryFrame) u64 {
        return self.log_offset + self.log_bytes;
    }
};

/// Serves replay frames from the verified snapshot prefix, then the log
/// suffix. When no usable snapshot exists, serves the whole log. Never writes;
/// callers on writable paths decide whether to rebuild or extend the cache.
const HistoryFrameSource = struct {
    log_file: std.Io.File,
    log_length: u64,
    /// Fixed read boundary for recovery loads; null follows the physical
    /// length so later passes see frames appended after the source opened.
    limit: ?u64 = null,
    verified: ?history_snapshot.Verified = null,
    cursor: history_snapshot.Cursor = undefined,
    buffer: [8192]u8 = undefined,
    reader: ?std.Io.File.Reader = null,
    log_next: u64 = 0,
    /// Cache-file offset of the last frame served from the snapshot, null when
    /// the last frame came from the log. The writable scan uses this to mirror
    /// log truncations into the cache.
    last_frame_snapshot_file_offset: ?u64 = null,

    /// Verifies the snapshot against the already-open log file and prepares a
    /// merged source. Pure log when the cache is absent or invalid.
    fn open(
        alloc: Allocator,
        dir: *io_mod.VerifiedDir,
        session_id: []const u8,
        log_file: std.Io.File,
        log_length: u64,
    ) !HistoryFrameSource {
        var source = HistoryFrameSource{ .log_file = log_file, .log_length = log_length };
        if (history_snapshot.openAndVerify(alloc, dir, session_id, log_file, log_length) catch |err| blk: {
            debug_trace.logf("session", "history cache verify failed id={s} err={s}", .{ session_id, @errorName(err) });
            break :blk null;
        }) |verified| {
            source.verified = verified;
            source.cursor = .{ .file = verified.file, .frames = verified.frames };
            source.log_next = verified.covered_log_bytes;
        }
        return source;
    }

    fn deinit(self: *HistoryFrameSource, alloc: Allocator) void {
        if (self.verified) |*verified| verified.deinit(alloc);
        self.* = undefined;
    }

    /// Drops the cache portion after a cache-sourced failure; the source
    /// becomes pure log. Callers then reset() and replay from the log.
    fn verified_cleanup(self: *HistoryFrameSource, alloc: Allocator) void {
        if (self.verified) |*verified| verified.deinit(alloc);
        self.verified = null;
        self.cursor = undefined;
        self.reader = null;
        self.log_next = 0;
        self.last_frame_snapshot_file_offset = null;
    }

    fn coveredLogBytes(self: *const HistoryFrameSource) u64 {
        return if (self.verified) |*verified| verified.covered_log_bytes else 0;
    }

    /// Re-stats the log so a pass that follows an open-time truncation or a
    /// recovery append reads the current file, not the length captured at open.
    fn refresh(self: *HistoryFrameSource) !void {
        const physical = try self.log_file.length(io_mod.getIo());
        self.log_length = if (self.limit) |limit| @min(physical, limit) else physical;
    }

    /// Repositions the source at the frame starting at `log_offset`.
    fn seekLogOffset(self: *HistoryFrameSource, log_offset: u64) !void {
        try self.refresh();
        if (self.verified) |*verified| {
            if (log_offset < verified.covered_log_bytes) {
                try self.cursor.seekLogOffset(log_offset);
                self.log_next = verified.covered_log_bytes;
                self.reader = null;
                return;
            }
            self.cursor.index = verified.frames.len;
        }
        if (log_offset > self.log_length) return error.InvalidConversationFrame;
        self.log_next = log_offset;
        self.reader = null;
    }

    fn reset(self: *HistoryFrameSource) void {
        if (self.verified != null) self.cursor.reset();
        self.reader = null;
        self.last_frame_snapshot_file_offset = null;
        self.refresh() catch |err| {
            debug_trace.logf("session", "history source refresh failed err={s}; keeping stale length", .{@errorName(err)});
        };
        self.log_next = self.coveredLogBytes();
    }

    /// Returns the next frame in log order, or null at the end. Decoded memory
    /// is owned by `arena`.
    fn next(self: *HistoryFrameSource, arena: Allocator) !?HistoryFrame {
        if (self.verified) |*verified| {
            if (self.cursor.index < verified.frames.len) {
                const meta = verified.frames[self.cursor.index];
                const envelope = (try self.cursor.next(arena)) orelse return error.InvalidCache;
                self.last_frame_snapshot_file_offset = meta.file_offset;
                return .{
                    .log_offset = meta.log_offset,
                    .log_bytes = meta.log_bytes,
                    .line_crc = meta.line_crc,
                    .envelope = envelope,
                };
            }
        }
        self.last_frame_snapshot_file_offset = null;
        return self.nextFromLog(arena);
    }

    fn nextFromLog(self: *HistoryFrameSource, arena: Allocator) !?HistoryFrame {
        if (self.log_next >= self.log_length) return null;
        if (self.reader == null) {
            self.reader = self.log_file.reader(io_mod.getIo(), &self.buffer);
            self.reader.?.pos = self.log_next;
        }
        const frame_offset = self.log_next;
        const line = (try session_replay.readBufferedLine(arena, &self.reader.?, self.log_length, null)) orelse return null;
        self.log_next = line.next_offset;
        const decoded = try session_event.decodeConversationFrame(arena, line.bytes);
        return .{
            .log_offset = frame_offset,
            .log_bytes = @intCast(line.bytes.len),
            .line_crc = std.hash.Crc32.hash(line.bytes),
            .envelope = decoded.value,
        };
    }

    /// Reads exactly the frame starting at `log_offset`.
    fn readAtLogOffset(self: *HistoryFrameSource, arena: Allocator, log_offset: u64) !?HistoryFrame {
        try self.refresh();
        if (self.verified) |*verified| {
            if (log_offset < verified.covered_log_bytes) {
                var probe = self.cursor;
                try probe.seekLogOffset(log_offset);
                const meta = probe.frames[probe.index];
                const envelope = (try probe.next(arena)) orelse return error.InvalidCache;
                return .{
                    .log_offset = meta.log_offset,
                    .log_bytes = meta.log_bytes,
                    .line_crc = meta.line_crc,
                    .envelope = envelope,
                };
            }
        }
        const line = (try session_replay.readLineAt(arena, self.log_file, log_offset, self.log_length)) orelse return null;
        const decoded = try session_event.decodeConversationFrame(arena, line.bytes);
        return .{
            .log_offset = log_offset,
            .log_bytes = @intCast(line.bytes.len),
            .line_crc = std.hash.Crc32.hash(line.bytes),
            .envelope = decoded.value,
        };
    }
};

fn replayConversationHistory(
    alloc: Allocator,
    source: *HistoryFrameSource,
    conversation_seq: *u64,
    open_work_id: *?[]u8,
    replay_window: ?ConversationReplayWindow,
) ![]session.HistoryTurn {
    const window = replay_window orelse try findConversationReplayWindow(alloc, source);
    conversation_seq.* = window.last_complete_seq;
    var history: std.ArrayList(session.HistoryTurn) = .empty;
    errdefer {
        for (history.items) |turn| session.freeHistoryTurn(alloc, turn);
        history.deinit(alloc);
    }
    var turn = ConversationTurnBuilder.init(alloc);
    defer turn.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(frame_arena);
    if (window.checkpoint_offset) |checkpoint_offset| {
        const frame = (try source.readAtLogOffset(frame_arena.allocator(), checkpoint_offset)) orelse return error.InvalidConversationFrame;
        const summary = try alloc.dupe(u8, frame.envelope.event.context_checkpoint.summary);
        errdefer mem_utils.free(alloc, summary);
        try history.append(alloc, .{ .compacted_summary = .{
            .summary = summary,
            .removed_turn_count = window.prior_turn_count,
            .compaction_count = window.compaction_count,
            .root_user_messages_complete = false,
            .permission_feedback_complete = false,
        } });
    }
    if (window.active_user_offset) |user_offset| {
        const frame = (try source.readAtLogOffset(frame_arena.allocator(), user_offset)) orelse
            return error.InvalidConversationFrame;
        if (frame.envelope.event != .user) return error.InvalidConversationFrame;
        try turn.begin(frame.envelope.event.user);
    }
    var checkpoint_turn_open = window.active_user_offset != null;
    try source.seekLogOffset(window.offset);
    while (true) {
        const frame = source.next(frame_arena.allocator()) catch |err| switch (err) {
            error.TruncatedEventFrame => break,
            else => return err,
        } orelse break;
        switch (frame.envelope.event) {
            .user => |value| try turn.begin(value),
            .assistant => |value| try turn.appendAssistant(value),
            .tool_call => |value| try turn.appendToolCall(value),
            .tool_result => |value| try turn.appendToolResult(value),
            .steering => |value| try turn.appendSteering(value.text),
            .turn_completed => |value| {
                const completed = try turn.finishAssistant(value);
                checkpoint_turn_open = false;
                errdefer session.freeHistoryTurn(alloc, completed);
                try history.append(alloc, completed);
            },
            .interrupted => |value| {
                const completed = try turn.finishInterrupted(value);
                checkpoint_turn_open = false;
                errdefer session.freeHistoryTurn(alloc, completed);
                try history.append(alloc, completed);
            },
            .context_checkpoint => {
                try turn.finishStandalone();
                checkpoint_turn_open = turn.user != null;
            },
        }
        _ = frame_arena.reset(.retain_capacity);
    }
    // A concurrent writer may have exposed a complete-record prefix of its
    // final batched turn before sync. The next writable open truncates that
    // incomplete turn; read-only replay returns the preceding complete turns.
    const completed = try history.toOwnedSlice(alloc);
    if (checkpoint_turn_open) {
        if (turn.user) |*user| {
            open_work_id.* = user.work_id;
            user.work_id = null;
        }
    }
    return completed;
}

/// Reads complete canonical turns while retaining only the turn being built.
/// Each returned turn is owned by the caller.
pub const ConversationHistoryReader = struct {
    alloc: Allocator,
    file: std.Io.File,
    reader: std.Io.File.Reader,
    length: u64,
    offset: u64 = 0,
    builder: ConversationTurnBuilder,

    /// Borrows buffer until deinit; owns the opened file and current turn.
    pub fn init(alloc: Allocator, dir: *io_mod.VerifiedDir, buffer: []u8) !ConversationHistoryReader {
        var file = try openManagedFile(dir, events_file, .read_only);
        errdefer file.close(io_mod.getIo());
        return .{
            .alloc = alloc,
            .file = file,
            .length = try file.length(io_mod.getIo()),
            .reader = file.reader(io_mod.getIo(), buffer),
            .builder = ConversationTurnBuilder.init(alloc),
        };
    }

    pub fn deinit(self: *ConversationHistoryReader) void {
        self.builder.deinit();
        self.file.close(io_mod.getIo());
        self.* = undefined;
    }

    pub fn next(self: *ConversationHistoryReader) !?session.HistoryTurn {
        while (self.offset < self.length) {
            const line = session_replay.readBufferedLine(self.alloc, &self.reader, self.length, null) catch |err| switch (err) {
                error.TruncatedEventFrame => return null,
                else => return err,
            } orelse return null;
            defer self.alloc.free(line.bytes);
            var decoded = try session_event.decodeConversationFrame(self.alloc, line.bytes);
            defer decoded.deinit();
            const completed: ?session.HistoryTurn = switch (decoded.value.event) {
                .user => |value| blk: {
                    try self.builder.begin(value);
                    break :blk null;
                },
                .assistant => |value| blk: {
                    try self.builder.appendAssistant(value);
                    break :blk null;
                },
                .tool_call => |value| blk: {
                    try self.builder.appendToolCall(value);
                    break :blk null;
                },
                .tool_result => |value| blk: {
                    try self.builder.appendToolResult(value);
                    break :blk null;
                },
                .steering => |value| blk: {
                    try self.builder.appendSteering(value.text);
                    break :blk null;
                },
                .turn_completed => |value| try self.builder.finishAssistant(value),
                .interrupted => |value| try self.builder.finishInterrupted(value),
                .context_checkpoint => blk: {
                    if (self.builder.calls.items.len != 0 or self.builder.results.items.len != 0) {
                        return error.InvalidConversationFrame;
                    }
                    try self.builder.finishStandalone();
                    break :blk null;
                },
            };
            self.offset = line.next_offset;
            if (completed) |turn| return turn;
        }
        return null;
    }
};

pub fn loadConversationHistoryRange(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    start: usize,
    end: usize,
) ![]session.HistoryTurn {
    if (start > end) return error.InvalidHistoryPageCursor;
    var buffer: [8192]u8 = undefined;
    var reader = try ConversationHistoryReader.init(alloc, dir, &buffer);
    defer reader.deinit();
    var turns: std.ArrayList(session.HistoryTurn) = .empty;
    errdefer {
        for (turns.items) |turn| session.freeHistoryTurn(alloc, turn);
        turns.deinit(alloc);
    }
    var turn_index: usize = 0;
    while (turn_index < end) : (turn_index += 1) {
        const turn = (try reader.next()) orelse break;
        if (turn_index >= start) {
            errdefer session.freeHistoryTurn(alloc, turn);
            try turns.append(alloc, turn);
        } else {
            session.freeHistoryTurn(alloc, turn);
        }
    }
    return turns.toOwnedSlice(alloc);
}

pub fn loadConversationArchive(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) ![]session.HistoryTurn {
    var file = try openManagedFile(dir, events_file, .read_only);
    defer file.close(io_mod.getIo());
    const length = try file.length(io_mod.getIo());
    var source = HistoryFrameSource{ .log_file = file, .log_length = length, .limit = length };
    if (readConversationMetadata(alloc, dir) catch null) |metadata| {
        defer metadata.deinit();
        const opened: ?HistoryFrameSource = HistoryFrameSource.open(alloc, dir, metadata.value.id, file, length) catch |err| blk: {
            debug_trace.logf("session", "history cache archive open failed err={s}; reading log", .{@errorName(err)});
            break :blk null;
        };
        if (opened) |with_cache| {
            if (with_cache.verified != null) {
                // Keep the load bounded at open time, matching the raw-log path.
                var bounded = with_cache;
                bounded.limit = length;
                source = bounded;
            }
        }
    }
    defer source.deinit(alloc);
    return load_conversation_archive_from_source(alloc, &source, false) catch |err| {
        if (err == error.OutOfMemory or source.verified == null) return err;
        debug_trace.logf("session", "history cache archive rejected err={s}; reading log", .{@errorName(err)});
        source.verified_cleanup(alloc);
        source.reset();
        return load_conversation_archive_from_source(alloc, &source, false);
    };
}

fn load_conversation_archive_from_file(
    alloc: Allocator,
    file: std.Io.File,
    length: u64,
    close_open_turn: bool,
) ![]session.HistoryTurn {
    var source = HistoryFrameSource{ .log_file = file, .log_length = length, .limit = length };
    return load_conversation_archive_from_source(alloc, &source, close_open_turn);
}

fn load_conversation_archive_from_source(
    alloc: Allocator,
    source: *HistoryFrameSource,
    close_open_turn: bool,
) ![]session.HistoryTurn {
    var turns: std.ArrayList(session.HistoryTurn) = .empty;
    errdefer {
        for (turns.items) |turn| session.freeHistoryTurn(alloc, turn);
        turns.deinit(alloc);
    }
    var builder = ConversationTurnBuilder.init(alloc);
    defer builder.deinit();
    var raw_turn_count: usize = 0;
    var compaction_count: usize = 0;
    var frame_arena = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(frame_arena);
    source.reset();
    while (true) {
        const frame = source.next(frame_arena.allocator()) catch |err| switch (err) {
            error.TruncatedEventFrame => break,
            else => return err,
        } orelse break;
        const decoded_value = frame.envelope;
        const completed: ?session.HistoryTurn = switch (decoded_value.event) {
            .user => |value| blk: {
                try builder.begin(value);
                break :blk null;
            },
            .assistant => |value| blk: {
                try builder.appendAssistant(value);
                break :blk null;
            },
            .tool_call => |value| blk: {
                try builder.appendToolCall(value);
                break :blk null;
            },
            .tool_result => |value| blk: {
                try builder.appendToolResult(value);
                break :blk null;
            },
            .steering => |value| blk: {
                try builder.appendSteering(value.text);
                break :blk null;
            },
            .turn_completed => |value| try builder.finishAssistant(value),
            .interrupted => |value| try builder.finishInterrupted(value),
            .context_checkpoint => |value| blk: {
                if (builder.calls.items.len != 0 or builder.results.items.len != 0) {
                    return error.InvalidConversationFrame;
                }
                try builder.finishStandalone();
                compaction_count += 1;
                break :blk .{ .compacted_summary = .{
                    .summary = try alloc.dupe(u8, value.summary),
                    .removed_turn_count = raw_turn_count,
                    .compaction_count = compaction_count,
                    .root_user_messages_complete = false,
                    .permission_feedback_complete = false,
                } };
            },
        };
        if (completed) |turn| {
            errdefer session.freeHistoryTurn(alloc, turn);
            try turns.append(alloc, turn);
            if (turn != .compacted_summary) raw_turn_count += 1;
        }
        _ = frame_arena.reset(.retain_capacity);
    }
    if (close_open_turn and builder.user != null) {
        const completed = try builder.finishInterrupted(.{ .reason = .failed });
        errdefer session.freeHistoryTurn(alloc, completed);
        try turns.append(alloc, completed);
    }
    return turns.toOwnedSlice(alloc);
}

const ConversationReplayWindow = struct {
    offset: u64 = 0,
    prior_turn_count: usize = 0,
    compaction_count: usize = 0,
    last_complete_seq: u64 = 0,
    active_user_offset: ?u64 = null,
    checkpoint_offset: ?u64 = null,
    coverage: u64 = 0,
};

const ConversationReplayScan = struct {
    window: ConversationReplayWindow = .{},
    turn_count: usize = 0,
    last_seq: u64 = 0,
    active_user_offset: ?u64 = null,

    fn observe(self: *ConversationReplayScan, offset: u64, seq: u64, event: session_event.ConversationEvent) !void {
        const expected_seq = std.math.add(u64, self.last_seq, 1) catch return error.InvalidConversationFrame;
        if (seq != expected_seq) return error.InvalidConversationFrame;
        self.last_seq = seq;
        switch (event) {
            .user => {
                if (self.active_user_offset != null) return error.InvalidConversationFrame;
                self.active_user_offset = offset;
            },
            .turn_completed, .interrupted => {
                if (self.active_user_offset == null) return error.InvalidConversationFrame;
                self.active_user_offset = null;
                self.turn_count = std.math.add(usize, self.turn_count, 1) catch return error.InvalidConversationFrame;
                self.window.last_complete_seq = seq;
            },
            .context_checkpoint => |checkpoint| {
                self.window = .{
                    .offset = offset,
                    .prior_turn_count = self.turn_count,
                    .compaction_count = std.math.add(usize, self.window.compaction_count, 1) catch return error.InvalidConversationFrame,
                    .last_complete_seq = seq,
                    .active_user_offset = self.active_user_offset,
                    .checkpoint_offset = offset,
                    .coverage = checkpoint.covers_through_seq,
                };
            },
            else => {},
        }
    }

    fn finish(self: *const ConversationReplayScan, alloc: Allocator, source: *HistoryFrameSource) !ConversationReplayWindow {
        var window = self.window;
        // Coverage can precede the checkpoint: retain the recent exchanges
        // between those boundaries rather than replaying only after the record.
        if (window.checkpoint_offset != null) {
            window.offset = 0;
            window.active_user_offset = null;
            window.prior_turn_count = 0;
            source.reset();
            var frame_arena = std.heap.ArenaAllocator.init(alloc);
            defer mem_utils.deinit_arena(frame_arena);
            while (true) {
                const frame = (try source.next(frame_arena.allocator())) orelse break;
                if (frame.envelope.seq > window.coverage) break;
                switch (frame.envelope.event) {
                    .user => window.active_user_offset = frame.log_offset,
                    .turn_completed, .interrupted => {
                        window.active_user_offset = null;
                        window.prior_turn_count += 1;
                    },
                    else => {},
                }
                window.offset = frame.nextOffset();
                _ = frame_arena.reset(.retain_capacity);
            }
        }
        return window;
    }
};

fn findConversationReplayWindow(
    alloc: Allocator,
    source: *HistoryFrameSource,
) !ConversationReplayWindow {
    var scan: ConversationReplayScan = .{};
    source.reset();
    var frame_arena = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(frame_arena);
    while (true) {
        const frame = source.next(frame_arena.allocator()) catch |err| switch (err) {
            error.TruncatedEventFrame => break,
            else => return err,
        } orelse break;
        try scan.observe(frame.log_offset, frame.envelope.seq, frame.envelope.event);
        _ = frame_arena.reset(.retain_capacity);
    }
    return scan.finish(alloc, source);
}

pub const ConversationTurnBuilder = struct {
    alloc: Allocator,
    user: ?types.UserTurn = null,
    pending_assistant: ?[]u8 = null,
    pending_replay: ?types.ProviderReplay = null,
    calls: std.ArrayList(types.ToolCall) = .empty,
    results: std.ArrayList(types.PersistedToolResult) = .empty,
    steps: std.ArrayList(types.ToolExecutionStep) = .empty,
    steering: std.ArrayList(types.PersistedSteering) = .empty,

    pub fn init(alloc: Allocator) ConversationTurnBuilder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *ConversationTurnBuilder) void {
        if (self.user) |user| types.freeUserTurn(self.alloc, user);
        if (self.pending_assistant) |text| self.alloc.free(text);
        if (self.pending_replay) |replay| types.freeProviderReplay(self.alloc, replay);
        for (self.calls.items) |call| types.freeToolCall(self.alloc, call);
        self.calls.deinit(self.alloc);
        for (self.results.items) |result| freeConversationToolResult(self.alloc, result);
        self.results.deinit(self.alloc);
        for (self.steps.items) |step| {
            if (step.assistant) |text| self.alloc.free(text);
            if (step.provider_replay) |replay| types.freeProviderReplay(self.alloc, replay);
            types.freeToolCallSlice(self.alloc, step.tool_calls);
            types.freePersistedToolResults(self.alloc, step.tool_results);
        }
        for (self.steering.items) |item| {
            self.alloc.free(item.text);
            if (item.assistant_prefix) |text| self.alloc.free(text);
        }
        self.steps.deinit(self.alloc);
        self.steering.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn isIdle(self: *const ConversationTurnBuilder) bool {
        return self.user == null and
            self.pending_assistant == null and
            self.calls.items.len == 0 and
            self.results.items.len == 0 and
            self.steps.items.len == 0 and
            self.steering.items.len == 0;
    }

    pub fn begin(
        self: *ConversationTurnBuilder,
        value: session_event.ConversationUser,
    ) !void {
        if (!self.isIdle()) return error.InvalidConversationFrame;
        self.user = try types.dupeUserTurn(self.alloc, .{
            .text = @constCast(value.text),
            .images = @constCast(value.images),
            .work_id = if (value.work_id) |work_id| @constCast(work_id) else null,
        });
    }

    pub fn appendAssistant(self: *ConversationTurnBuilder, value: session_event.ConversationAssistant) !void {
        if (self.calls.items.len == 0 and self.results.items.len == 0) try self.finishStandalone();
        if (self.user == null or self.pending_assistant != null or self.calls.items.len != 0) {
            return error.InvalidConversationFrame;
        }
        {
            const text = try self.alloc.dupe(u8, value.text);
            errdefer mem_utils.free(self.alloc, text);
            self.pending_replay = if (value.provider_replay) |replay| try types.dupeProviderReplay(self.alloc, replay) else null;
            self.pending_assistant = text;
        }
        if (value.standalone_response) try self.finishStep();
    }

    pub fn appendToolCall(
        self: *ConversationTurnBuilder,
        value: session_event.ConversationToolCall,
    ) !void {
        if (self.user == null or self.results.items.len != 0) {
            return error.InvalidConversationFrame;
        }
        for (self.calls.items) |call| {
            if (std.mem.eql(u8, call.id, value.call_id)) return error.InvalidConversationFrame;
        }
        const call = try types.dupeToolCall(self.alloc, .{
            .id = value.call_id,
            .name = value.tool_name,
            .arguments_json = value.arguments_json,
            .argument_integrity = value.argument_integrity,
            .provisional_id = value.provisional_id,
            .provider_result = value.provider_result,
            .final_identity = value.final_identity,
            .provenance = value.provenance,
        });
        errdefer types.freeToolCall(self.alloc, call);
        try self.calls.append(self.alloc, call);
    }

    pub fn appendToolResult(
        self: *ConversationTurnBuilder,
        value: session_event.ConversationToolResult,
    ) !void {
        if (self.user == null or self.calls.items.len == 0) {
            return error.InvalidConversationFrame;
        }
        var matching_call = false;
        for (self.calls.items) |call| {
            if (!std.mem.eql(u8, call.id, value.call_id)) continue;
            if (!std.mem.eql(u8, call.name, value.tool_name)) {
                return error.InvalidConversationFrame;
            }
            matching_call = true;
            break;
        }
        if (!matching_call) return error.InvalidConversationFrame;
        for (self.results.items) |result| {
            if (std.mem.eql(u8, result.tool_call_id, value.call_id)) {
                return error.InvalidConversationFrame;
            }
        }

        const result = try dupeConversationToolResult(self.alloc, value);
        errdefer freeConversationToolResult(self.alloc, result);
        try self.results.append(self.alloc, result);
        if (self.results.items.len == self.calls.items.len) try self.finishStep();
    }

    pub fn finishStandalone(self: *ConversationTurnBuilder) !void {
        if (self.calls.items.len != 0 or self.results.items.len != 0) return error.InvalidConversationFrame;
        const text = self.pending_assistant orelse return;
        if (text.len == 0 and self.pending_replay == null) {
            self.alloc.free(text);
            self.pending_assistant = null;
            return;
        }
        try self.finishStep();
    }

    pub fn finishStep(self: *ConversationTurnBuilder) !void {
        try self.steps.ensureUnusedCapacity(self.alloc, 1);
        const calls = try self.calls.toOwnedSlice(self.alloc);
        errdefer types.freeToolCallSlice(self.alloc, calls);
        const results = try self.results.toOwnedSlice(self.alloc);
        errdefer types.freePersistedToolResults(self.alloc, results);
        self.steps.appendAssumeCapacity(.{
            .assistant = self.pending_assistant,
            .provider_replay = self.pending_replay,
            .tool_calls = calls,
            .tool_results = results,
        });
        self.pending_assistant = null;
        self.pending_replay = null;
    }

    pub fn appendSteering(self: *ConversationTurnBuilder, text: []const u8) !void {
        if (self.user == null or self.calls.items.len != 0 or self.results.items.len != 0) {
            return error.InvalidConversationFrame;
        }
        if (self.pending_replay != null) try self.finishStep();
        const owned = try self.alloc.dupe(u8, text);
        errdefer mem_utils.free(self.alloc, owned);
        try self.steering.append(self.alloc, .{
            .text = owned,
            .assistant_prefix = self.pending_assistant,
            .after_tool_step_count = self.steps.items.len,
        });
        self.pending_assistant = null;
    }

    pub fn finishAssistant(
        self: *ConversationTurnBuilder,
        completed: session_event.ConversationTurnCompleted,
    ) !session.HistoryTurn {
        if (self.user == null or self.calls.items.len != 0 or self.results.items.len != 0) {
            return error.InvalidConversationFrame;
        }
        const assistant = if (self.pending_assistant) |text|
            text
        else
            try self.alloc.dupe(u8, "");
        const execution = try self.takeExecution(
            completed.files,
            completed.turn_summary,
        );
        const user = self.user.?;
        self.user = null;
        self.pending_assistant = null;
        const replay = self.pending_replay;
        self.pending_replay = null;
        return .{ .assistant = .{
            .user = user,
            .assistant = assistant,
            .execution = execution,
            .provider_replay = replay,
        } };
    }

    pub fn finishInterrupted(
        self: *ConversationTurnBuilder,
        value: session_event.ConversationInterruption,
    ) !session.HistoryTurn {
        if (self.user == null or self.results.items.len != 0 or self.calls.items.len > 1) {
            return error.InvalidConversationFrame;
        }
        if (self.calls.items.len == 0) try self.finishStandalone();
        const tool_call = if (self.calls.items.len == 1)
            self.calls.orderedRemove(0)
        else
            null;
        errdefer if (tool_call) |call| types.freeToolCall(self.alloc, call);
        if (self.pending_assistant) |text| {
            self.alloc.free(text);
            self.pending_assistant = null;
        }
        if (self.pending_replay) |replay| {
            debug_trace.logf("session", "provider replay omitted reason=interrupted_association", .{});
            types.freeProviderReplay(self.alloc, replay);
            self.pending_replay = null;
        }
        const assistant = if (value.partial_text) |text|
            try self.alloc.dupe(u8, text)
        else
            null;
        errdefer if (assistant) |text| mem_utils.free(self.alloc, text);
        const replay = if (value.command_replay_ref) |handle| blk: {
            const owned_handle = try self.alloc.dupe(u8, handle);
            break :blk types.CommandOutputReplay{ .available = .{
                .handle = owned_handle,
                .framed_bytes = std.math.cast(
                    usize,
                    value.command_replay_bytes.?,
                ) orelse {
                    self.alloc.free(owned_handle);
                    return error.ConversationSizeOverflow;
                },
            } };
        } else null;
        errdefer if (replay) |owned| types.freeCommandOutputReplay(self.alloc, owned);
        const command_artifact = if (value.command_artifact_ref) |handle|
            try self.alloc.dupe(u8, handle)
        else
            null;
        errdefer if (command_artifact) |handle| mem_utils.free(self.alloc, handle);
        const cancelled_command = if (replay != null or command_artifact != null)
            types.CancelledCommandPresentation{
                .output_replay = replay,
                .command_artifact_handle = command_artifact,
            }
        else
            null;
        const execution = try self.takeExecution(
            value.files,
            value.turn_summary,
        );
        const user = self.user.?;
        self.user = null;
        return .{ .interrupted = .{
            .user = user,
            .assistant = assistant,
            .tool_call = tool_call,
            .execution = execution,
            .cancelled_command = cancelled_command,
            .terminal_reason = value.reason,
            .cancellation_origin = value.cancellation_origin,
        } };
    }

    pub fn takeExecution(
        self: *ConversationTurnBuilder,
        files_source: []const types.FileEvidence,
        turn_summary: ?types.TurnSummary,
    ) !types.ExecutionMemory {
        const steps = try self.steps.toOwnedSlice(self.alloc);
        errdefer types.freeToolExecutionSteps(self.alloc, steps);
        const steering = try self.steering.toOwnedSlice(self.alloc);
        errdefer types.freePersistedSteering(self.alloc, steering);
        const files = try types.dupeFileEvidenceSlice(self.alloc, files_source);
        return .{
            .tool_steps = steps,
            .files = files,
            .steering = steering,
            .turn_summary = turn_summary,
        };
    }
};

fn dupeConversationToolResult(
    alloc: Allocator,
    value: session_event.ConversationToolResult,
) !types.PersistedToolResult {
    const call_id = try alloc.dupe(u8, value.call_id);
    errdefer mem_utils.free(alloc, call_id);
    const tool_name = try alloc.dupe(u8, value.tool_name);
    errdefer mem_utils.free(alloc, tool_name);
    const output = try alloc.dupe(u8, value.preview orelse "");
    errdefer mem_utils.free(alloc, output);
    const handle = try alloc.dupe(u8, value.artifact_ref);
    errdefer mem_utils.free(alloc, handle);
    const image_handle = if (value.tool_image_handle) |image_ref| try alloc.dupe(u8, image_ref) else null;
    errdefer if (image_handle) |image_ref| mem_utils.free(alloc, image_ref);
    const preview = if (value.preview) |text| try alloc.dupe(u8, text) else null;
    errdefer if (preview) |text| mem_utils.free(alloc, text);
    var permission_feedback: [][]u8 = if (value.permission_feedback.len > 0)
        try alloc.alloc([]u8, value.permission_feedback.len)
    else
        &.{};
    errdefer if (permission_feedback.len > 0) mem_utils.free(alloc, permission_feedback);
    var feedback_count: usize = 0;
    errdefer for (permission_feedback[0..feedback_count]) |feedback| {
        alloc.free(feedback);
    };
    for (value.permission_feedback, 0..) |feedback, index| {
        permission_feedback[index] = try alloc.dupe(u8, feedback);
        feedback_count += 1;
    }
    const command_output_replay: ?types.CommandOutputReplay = if (value.command_replay_ref) |replay_ref| blk: {
        const replay_handle = try alloc.dupe(u8, replay_ref);
        break :blk .{ .available = .{
            .handle = replay_handle,
            .framed_bytes = std.math.cast(
                usize,
                value.command_replay_bytes.?,
            ) orelse {
                alloc.free(replay_handle);
                return error.ConversationSizeOverflow;
            },
        } };
    } else null;
    errdefer if (command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    };
    const committed_file_presentation = if (value.committed_file_presentation) |presentation|
        try types.dupeCommittedFilePresentation(alloc, presentation)
    else
        null;
    errdefer if (committed_file_presentation) |presentation| {
        types.freeCommittedFilePresentation(alloc, presentation);
    };
    const stored_bytes = std.math.cast(usize, value.stored_bytes) orelse
        return error.ConversationSizeOverflow;
    const output_bytes = std.math.cast(
        usize,
        value.output_bytes orelse value.stored_bytes,
    ) orelse return error.ConversationSizeOverflow;
    return .{
        .tool_call_id = call_id,
        .tool_name = tool_name,
        .status = value.status,
        .output = output,
        .output_handle = handle,
        .tool_image_handle = image_handle,
        .preview = preview,
        .output_bytes = output_bytes,
        .stored_output_bytes = stored_bytes,
        .truncated = value.completeness != .complete,
        .provider_native = value.provider_native,
        .review_feedback = value.review_feedback,
        .created_at_ms = value.created_at_ms,
        .permission_feedback = permission_feedback,
        .committed_file_presentation = committed_file_presentation,
        .command_output_replay = command_output_replay,
        .command_process_presentation = value.command_process_presentation,
        .terminal_action_presentation = value.terminal_action_presentation,
    };
}

fn freeConversationToolResult(
    alloc: Allocator,
    result: types.PersistedToolResult,
) void {
    alloc.free(result.tool_call_id);
    alloc.free(result.tool_name);
    alloc.free(result.output);
    if (result.output_handle) |handle| alloc.free(handle);
    types.freeToolImages(alloc, result.tool_images);
    if (result.tool_image_handle) |handle| alloc.free(handle);
    if (result.preview) |preview| alloc.free(preview);
    for (result.permission_feedback) |feedback| alloc.free(feedback);
    if (result.permission_feedback.len > 0) alloc.free(result.permission_feedback);
    if (result.committed_file_presentation) |presentation| {
        types.freeCommittedFilePresentation(alloc, presentation);
    }
    if (result.command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    }
}

fn latestConversationCheckpointIndex(history: []const session.HistoryTurn) usize {
    var index: usize = 0;
    for (history, 0..) |turn, candidate| {
        if (turn == .compacted_summary) index = candidate;
    }
    return index;
}

fn restoreContextResultBodies(alloc: Allocator, dir: *io_mod.VerifiedDir, history: []session.HistoryTurn) !void {
    var capability: ?session_child_store.SessionChildCapability = null;
    defer if (capability) |*value| value.deinit();
    for (history) |*turn| {
        const execution = switch (turn.*) {
            .assistant => |*entry| &entry.execution,
            .interrupted => |*entry| &entry.execution,
            .compacted_summary => continue,
        };
        try restoreExecutionResultBodies(alloc, dir, &capability, execution);
    }
}

fn restoreExecutionResultBodies(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    capability: *?session_child_store.SessionChildCapability,
    execution: *types.ExecutionMemory,
) !void {
    for (execution.tool_steps) |*step| for (step.tool_results) |*result| {
        const handle = result.output_handle orelse continue;
        if (!result.truncated and result.output.len == result.stored_output_bytes) continue;
        const body = if (result.truncated)
            try result_store.formatStoredResultOutput(alloc, handle, result.preview orelse "", result.stored_output_bytes)
        else blk: {
            if (capability.* == null) {
                const path = try io_mod.dirRealpathAlloc(alloc, dir.dir, ".");
                defer alloc.free(path);
                capability.* = try session_child_store.SessionChildCapability.init(alloc, dir.dir, path, .read_only);
            }
            break :blk result_store.readForReplayManaged(alloc, &capability.*.?, handle, result.stored_output_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    debug_trace.logf("session", "event=context_result_unavailable handle={s} err={s}; marking content unavailable", .{ handle, @errorName(err) });
                    const unavailable = try alloc.dupe(u8, "Saved tool-result content is unavailable. The complete output could not be restored.");
                    result.truncated = true;
                    break :blk unavailable;
                },
            };
        };
        alloc.free(result.output);
        result.output = body;
    };
}

fn projectConversationSnapshotLocators(
    alloc: Allocator,
    history: []session.HistoryTurn,
) !void {
    for (history) |*turn| {
        const images = switch (turn.*) {
            .assistant => |*entry| entry.user.images,
            .interrupted => |*entry| entry.user.images,
            .compacted_summary => continue,
        };
        try projectConversationImageLocators(alloc, images);
    }
}

fn projectConversationImageLocators(
    alloc: Allocator,
    images: []types.ImageAttachment,
) !void {
    for (images) |*image| {
        const snapshot_path = image.snapshot_path orelse continue;
        if (!std.Io.Dir.path.isAbsolute(snapshot_path)) continue;
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const projected = try session.projectSnapshotLocator(
            &buffer,
            snapshot_path,
        );
        const owned = try alloc.dupe(u8, projected);
        alloc.free(snapshot_path);
        image.snapshot_path = owned;
    }
}

fn externalizeConversationResults(
    alloc: Allocator,
    state: *session_codec.DurableSessionState,
    capability: *session_child_store.SessionChildCapability,
) !void {
    for (state.history) |*turn| switch (turn.*) {
        .assistant => |*entry| try externalizeExecutionResults(
            alloc,
            &entry.execution,
            capability,
            true,
        ),
        .interrupted => |*entry| try externalizeExecutionResults(
            alloc,
            &entry.execution,
            capability,
            true,
        ),
        .compacted_summary => {},
    };
}

pub fn externalizeConversationTurnResults(
    alloc: Allocator,
    turn: *session.HistoryTurn,
    capability: ?*session_child_store.SessionChildCapability,
) !void {
    const execution = switch (turn.*) {
        .assistant => |*entry| &entry.execution,
        .interrupted => |*entry| &entry.execution,
        .compacted_summary => return,
    };
    var has_results = false;
    for (execution.tool_steps) |step| {
        if (step.tool_results.len != 0) {
            has_results = true;
            break;
        }
    }
    if (!has_results) return;
    try externalizeExecutionResults(
        alloc,
        execution,
        capability,
        false,
    );
}

fn externalizeExecutionResults(
    alloc: Allocator,
    execution: *types.ExecutionMemory,
    capability: ?*session_child_store.SessionChildCapability,
    legacy_completeness_unknown: bool,
) !void {
    for (execution.tool_steps) |*step| {
        for (step.tool_results) |*result| {
            if (result.tool_images.len > 0 and result.tool_image_handle == null) {
                result.tool_image_handle = try result_store.storeToolImages(
                    alloc,
                    capability orelse return error.SessionChildCapabilityUnavailable,
                    result.tool_call_id,
                    result.tool_name,
                    result.tool_images,
                );
            }
            if (result.output_handle == null) {
                result.output_handle = try result_store.storeLargeResultManaged(
                    alloc,
                    capability orelse return error.SessionChildCapabilityUnavailable,
                    result.tool_call_id,
                    result.tool_name,
                    result.output,
                );
                if (legacy_completeness_unknown) result.truncated = true;
                result.stored_output_bytes = result.output.len;
            }
            if (result.preview == null) {
                result.preview = try result_store.previewText(
                    alloc,
                    result.output,
                    result_store.preview_bytes,
                );
            }
        }
    }
}

fn deleteConversationMigrationFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
) !void {
    dir.dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

fn deleteLegacyConversationFiles(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    source_generation: ?Identifier,
) !void {
    const names = [_][]const u8{
        conversation_migration_backup_file,
        "session.legacy.json",
        authority_file,
        authority_intent_file,
        publication_intent_file,
        checkpoint_file,
        commit_lock_file,
        session_display_metadata.sidecar_file,
        "resume-view.bin",
        history_snapshot.file_name,
    };
    for (names) |name| try deleteConversationMigrationFile(dir, name);
    if (source_generation) |generation| {
        const watermark = try watermarkName(alloc, generation);
        defer alloc.free(watermark);
        try deleteConversationMigrationFile(dir, watermark);
    }
    try io_mod.syncVerifiedDir(dir.dir);
}

pub fn legacyImportRecoveryNeeded(dir: *io_mod.VerifiedDir) !bool {
    return entryExists(dir, conversation_migration_backup_file);
}

/// Repairs the only two interrupted publication states produced by the
/// one-way legacy importer. The old event log remains the authority until the
/// current metadata is durable; after that point the current log wins.
pub fn recoverInterruptedLegacyImport(
    alloc: Allocator,
    writable: *WritableSessionDir,
) !void {
    if (!try legacyImportRecoveryNeeded(&writable.dir)) return;
    const current_metadata = try hasConversationMetadata(alloc, &writable.dir);
    const current_events = try entryExists(&writable.dir, events_file);
    if (current_metadata) {
        if (!current_events) return error.SessionMigrationIncomplete;
        try deleteConversationMigrationFile(
            &writable.dir,
            conversation_migration_backup_file,
        );
        try deleteConversationMigrationFile(
            &writable.dir,
            conversation_migration_temp_file,
        );
        try io_mod.syncVerifiedDir(writable.dir.dir);
        return;
    }

    if (current_events) {
        try deleteConversationMigrationFile(&writable.dir, events_file);
    }
    try writable.dir.dir.rename(
        conversation_migration_backup_file,
        writable.dir.dir,
        events_file,
        io_mod.getIo(),
    );
    try deleteConversationMigrationFile(
        &writable.dir,
        conversation_migration_temp_file,
    );
    try io_mod.syncVerifiedDir(writable.dir.dir);
}

pub const Boundary = enum {
    latest_barrier_completed,
};

pub const LockKind = enum {
    session,
};

pub const TestControls = struct {
    context: ?*anyopaque = null,
    boundary_fn: ?*const fn (?*anyopaque, Boundary) anyerror!void = null,
    lock_fn: ?*const fn (?*anyopaque, LockKind) void = null,
    compaction: session_compaction.TestControls = .{},

    pub fn boundary(self: TestControls, point: Boundary) !void {
        if (self.boundary_fn) |callback| try callback(self.context, point);
    }

    fn lock(self: TestControls, kind: LockKind) void {
        if (self.lock_fn) |callback| callback(self.context, kind);
    }
};

pub const Options = struct {
    test_controls: TestControls = .{},
    session_lock_deadline_ms: u64 = lock_deadline_ms,
};

pub const SessionUpdate = union(enum) {
    preferences_changed: session_event.PreferencesChanged,
    workspace_rebound: session_event.WorkspaceRebound,
    history_turn_committed: session_event.HistoryTurnCommitted,
    usage_checkpointed: session_event.UsageCheckpointed,
    recovery_checkpoint_set: session_event.RecoveryCheckpointSet,
    recovery_checkpoint_cleared: session_event.RecoveryCheckpointCleared,
};

pub const OpenMode = enum {
    read_only,
    writable,
};

pub const CommitPosition = session_replay.CommitPosition;

pub const CleanupReport = struct {
    removed: usize = 0,
    report_only: usize = 0,
    ignored: usize = 0,
};

pub const WritableSessionDir = struct {
    dir: io_mod.VerifiedDir,
    writer_lock: ?io_mod.TimedAdvisoryLock,
    session_id: []u8,
    /// True when a leftover owner marker was present at open time: the
    /// previous owning process exited without deinit (crash or kill). A
    /// still-live parked owner produces the same signal, so callers must
    /// treat it as a reason to be careful, never as proof of corruption.
    previous_owner_died: bool = false,

    pub fn deinit(self: *WritableSessionDir, alloc: Allocator) void {
        self.clearOwnerLiveness();
        if (self.writer_lock) |*lock| lock.release();
        self.dir.close();
        alloc.free(self.session_id);
        self.* = undefined;
    }

    /// Records this process as the live owner of the session directory. The
    /// marker is written on every writable open and removed by deinit while
    /// the writer lock is still held, so a leftover marker means the previous
    /// owner died. Advisory only: probe and write failures degrade to no
    /// signal rather than blocking the open.
    pub fn trackOwnerLiveness(self: *WritableSessionDir, alloc: Allocator) void {
        self.previous_owner_died = entryExists(&self.dir, owner_live_file) catch |err| blk: {
            debug_trace.logf("session", "owner liveness probe failed id={s} err={s}", .{ self.session_id, @errorName(err) });
            break :blk false;
        };
        const body = alloc.print("{{\"pid\":{d},\"opened_at_ms\":{d}}}\n", .{
            std.c.getpid(),
            io_mod.milliTimestamp(),
        }) catch |err| {
            debug_trace.logf("session", "owner liveness mark allocation failed id={s} err={s}", .{ self.session_id, @errorName(err) });
            return;
        };
        defer alloc.free(body);
        io_mod.durableReplaceVerified(alloc, &self.dir, owner_live_file, body) catch |err| {
            debug_trace.logf("session", "owner liveness mark failed id={s} err={s}", .{ self.session_id, @errorName(err) });
        };
    }

    fn clearOwnerLiveness(self: *WritableSessionDir) void {
        self.dir.dir.deleteFile(io_mod.getIo(), owner_live_file) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                debug_trace.logf("session", "owner liveness clear failed id={s} err={s}", .{ self.session_id, @errorName(err) });
                return;
            },
        };
        io_mod.syncVerifiedDir(self.dir.dir) catch |err| {
            debug_trace.logf("session", "owner liveness clear sync failed id={s} err={s}", .{ self.session_id, @errorName(err) });
        };
    }

    fn isParked(self: *const WritableSessionDir) bool {
        return self.writer_lock == null;
    }

    /// Release `session.lock`. The loaded session must be retired before
    /// acquiring another writer, since its state may no longer match storage.
    pub fn park(self: *WritableSessionDir) void {
        const lock = &(self.writer_lock orelse return);
        lock.release();
        self.writer_lock = null;
    }

    pub fn eventLogLengthForTest(self: *WritableSessionDir) !u64 {
        var file = try openManagedFile(&self.dir, events_file, .read_only);
        defer file.close(io_mod.getIo());
        return file.length(io_mod.getIo());
    }

    fn entryExistsForTest(self: *WritableSessionDir, name: []const u8) !bool {
        return entryExists(&self.dir, name);
    }
};

pub const LoadedWritableSession = struct {
    pub const ExternalPromptOrigin = enum {
        root,
        persistent_child,
    };

    active_id: []u8,
    state: session_codec.DurableSessionState,
    conversation_writer: ConversationWriter,
    log: WritableSessionDir,
    freshly_started: bool = false,
    /// Runtime-only latch set when an open turn without a recovery checkpoint
    /// outlived the fresh-prompt boundary wait: some stop paths never commit
    /// the close in-process, so later sends fail fast instead of re-waiting.
    boundary_wedged: bool = false,
    child_capability: ?*session_child_store.SessionChildCapability = null,
    position: CommitPosition,
    migration_source_schema_version: ?u8 = null,
    migration_source_bytes: ?u64 = null,
    /// Runtime-only provenance installed by subagent resume admission. These
    /// fields are never written into the session event log.
    external_prompt_origin: ExternalPromptOrigin = .root,
    external_root_user_messages: [][]u8 = &.{},
    external_root_user_evidence_complete: bool = false,

    pub fn requireWritable(self: *const LoadedWritableSession) !void {
        if (self.log.isParked()) return error.SessionWriterParked;
        if (self.conversation_writer.failure) |err| return err;
    }

    fn recordWriteFailure(self: *LoadedWritableSession, err: anyerror) anyerror {
        if (err == error.DurableReplacePostRenameFailed) {
            self.conversation_writer.failure = error.SessionPersistenceUncertain;
            return error.SessionPersistenceUncertain;
        }
        return err;
    }

    pub fn deinit(self: *LoadedWritableSession, alloc: Allocator) void {
        self.conversation_writer.deinit();
        if (self.child_capability) |capability| {
            capability.deinit();
            alloc.destroy(capability);
        }
        for (self.external_root_user_messages) |message| alloc.free(message);
        if (self.external_root_user_messages.len > 0) {
            alloc.free(self.external_root_user_messages);
        }
        alloc.free(self.active_id);
        self.state.deinit(alloc);
        self.log.deinit(alloc);
        self.* = undefined;
    }

    /// Returns a borrowed address that remains stable until deinit.
    pub fn childCapability(
        self: *LoadedWritableSession,
    ) !*session_child_store.SessionChildCapability {
        return if (self.child_capability) |capability|
            capability
        else
            error.SessionChildCapabilityUnavailable;
    }

    /// Releases the one-time resume projection after the owning runtime has
    /// restored it. New conversation events continue through `ConversationWriter`.
    pub fn releaseHydrationHistory(
        self: *LoadedWritableSession,
        alloc: Allocator,
    ) void {
        session.freeHistoryTurnSlice(alloc, self.state.history);
        self.state.history = &.{};
        self.state.context_history_start = 0;
    }

    pub fn prepareHistoryTurnForCommit(
        self: *LoadedWritableSession,
        alloc: Allocator,
        turn: *session.HistoryTurn,
    ) !void {
        try self.requireWritable();
        try externalizeConversationTurnResults(
            alloc,
            turn,
            self.child_capability,
        );
    }

    pub fn renameConversation(
        self: *LoadedWritableSession,
        alloc: Allocator,
        title: []const u8,
    ) !bool {
        try self.requireWritable();
        const bytes = try readManagedFileAlloc(
            alloc,
            &self.log.dir,
            manifest_file,
            session_codec.max_session_metadata_bytes,
        );
        defer alloc.free(bytes);
        var metadata = try session_codec.decodeSessionMetadata(alloc, bytes);
        defer metadata.deinit();
        const encoded = try session_codec.encodeSessionMetadata(alloc, .{
            .id = metadata.value.id,
            .origin_workspace_root = metadata.value.origin_workspace_root,
            .workspace_root = metadata.value.workspace_root,
            .created_at_ms = metadata.value.created_at_ms,
            .updated_at_ms = metadata.value.updated_at_ms,
            .conversation_language = metadata.value.conversation_language,
            .provider = metadata.value.provider,
            .model = metadata.value.model,
            .effort = metadata.value.effort,
            .fast_mode = metadata.value.fast_mode,
            .ultrafast_mode = metadata.value.ultrafast_mode,
            .title = title,
            .subagent_child = metadata.value.subagent_child,
        });
        defer alloc.free(encoded);
        io_mod.durableReplaceVerified(
            alloc,
            &self.log.dir,
            manifest_file,
            encoded,
        ) catch |err| return self.recordWriteFailure(err);
        return true;
    }

    pub fn conversationTitle(
        self: *LoadedWritableSession,
        alloc: Allocator,
    ) !?[]u8 {
        const bytes = try readManagedFileAlloc(
            alloc,
            &self.log.dir,
            manifest_file,
            session_codec.max_session_metadata_bytes,
        );
        defer alloc.free(bytes);
        var metadata = try session_codec.decodeSessionMetadata(alloc, bytes);
        defer metadata.deinit();
        return if (metadata.value.title) |title|
            try alloc.dupe(u8, title)
        else
            null;
    }

    pub fn appendEvent(
        self: *LoadedWritableSession,
        alloc: Allocator,
        event: SessionUpdate,
        timestamp_ms: i64,
    ) !CommitPosition {
        try self.requireWritable();
        const result = switch (event) {
            .history_turn_committed => self.appendConversationHistoryEvent(
                alloc,
                event,
                timestamp_ms,
            ),
            .preferences_changed, .workspace_rebound => self.appendConversationMetadataEvent(
                alloc,
                event,
                timestamp_ms,
            ),
            .usage_checkpointed => self.appendConversationUsageEvent(
                alloc,
                event,
                timestamp_ms,
            ),
            .recovery_checkpoint_set, .recovery_checkpoint_cleared => self.appendConversationRecoveryEvent(
                alloc,
                event,
                timestamp_ms,
            ),
        };
        return result catch |err| self.recordWriteFailure(err);
    }

    pub fn commitContextCompaction(
        self: *LoadedWritableSession,
        alloc: Allocator,
        summary: types.CompactedSummaryHistoryTurn,
        active_prefix: ?types.AssistantHistoryTurn,
        retained_from: ?types.ContextHistoryCut,
        timestamp_ms: i64,
    ) !CommitPosition {
        try self.requireWritable();
        var prepared: ?session.HistoryTurn = if (active_prefix) |prefix|
            try session.dupeHistoryTurn(alloc, .{ .assistant = prefix })
        else
            null;
        defer if (prepared) |turn| session.freeHistoryTurn(alloc, turn);
        if (prepared) |*turn| try self.prepareHistoryTurnForCommit(alloc, turn);
        var spill_arena = std.heap.ArenaAllocator.init(alloc);
        defer mem_utils.deinit_arena(spill_arena);
        const append_prefix: ?types.AssistantHistoryTurn = if (prepared) |turn| blk: {
            const projected = try spillHistoryTurnFilePresentations(
                spill_arena.allocator(),
                &self.log.dir,
                turn,
            );
            break :blk projected.assistant;
        } else null;
        try self.conversation_writer.appendContextCompaction(
            alloc,
            timestamp_ms,
            summary,
            append_prefix,
            retained_from,
        );
        if (prepared) |turn| self.writeFirstConversationTitle(alloc, turn);
        if (self.conversation_writer.failure) |err| return err;
        return self.finishConversationCommit(alloc, timestamp_ms);
    }

    fn appendConversationHistoryEvent(
        self: *LoadedWritableSession,
        alloc: Allocator,
        event: SessionUpdate,
        timestamp_ms: i64,
    ) !CommitPosition {
        const payload = switch (event) {
            .history_turn_committed => |value| value,
            else => return error.InvalidConversationEvent,
        };
        var work_id = if (payload.work_id) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (work_id) |value| mem_utils.free(alloc, value);
        try appendPersistedHistoryTurn(
            alloc,
            &self.log.dir,
            &self.conversation_writer,
            timestamp_ms,
            payload.turn,
        );
        self.writeFirstConversationTitle(alloc, payload.turn);
        if (self.conversation_writer.failure) |err| return err;
        if (work_id) |value| {
            if (self.state.last_subagent_work_id) |old| alloc.free(old);
            self.state.last_subagent_work_id = value;
            work_id = null;
        }
        const language_changed = !std.mem.eql(u8, self.state.conversation_language.view(), payload.conversation_language.view());
        self.state.conversation_language = payload.conversation_language;
        self.state.total_input_tokens = payload.total_input_tokens;
        self.state.total_output_tokens = payload.total_output_tokens;
        const position = self.finishConversationCommit(alloc, timestamp_ms);
        if (language_changed) {
            writeConversationMetadata(alloc, &self.log.dir, self.state) catch |err| {
                self.conversation_writer.failure = error.SessionPersistenceUncertain;
                debug_trace.logf("session", "history committed but language metadata failed session={s} err={s}", .{ self.active_id, @errorName(err) });
                return error.SessionPersistenceUncertain;
            };
        }
        if (self.conversation_writer.failure) |err| return err;
        return position;
    }

    fn writeFirstConversationTitle(self: *LoadedWritableSession, alloc: Allocator, turn: session.HistoryTurn) void {
        if (!self.freshly_started) return;
        // A generated title (or a user rename) that landed before the first
        // commit wins; the derived title only names an untitled session.
        const persisted = self.conversationTitle(alloc) catch |err| {
            debug_trace.logf(
                "session",
                "derived session title check failed session={s} err={s}",
                .{ self.active_id, @errorName(err) },
            );
            return;
        };
        defer if (persisted) |value| alloc.free(value);
        if (persisted != null) return;
        var display = session_display_metadata.deriveFromHistory(alloc, &.{turn}) catch return;
        defer display.deinit(alloc);
        if (!display.present) return;
        // The fallback placeholder is not a title: persisting it would block
        // background title generation, which never overwrites a named session.
        if (std.mem.eql(u8, display.title, session_display_metadata.fallback_title)) return;
        _ = self.renameConversation(alloc, display.title) catch |err| {
            debug_trace.logf(
                "session",
                "derived session title not persisted session={s} err={s}",
                .{ self.active_id, @errorName(err) },
            );
        };
    }

    fn finishConversationCommit(self: *LoadedWritableSession, alloc: Allocator, timestamp_ms: i64) CommitPosition {
        if (self.state.recovery_checkpoint != null) {
            writeConversationRecoveryState(alloc, &self.log.dir, null, self.conversation_writer.last_seq) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=committed_turn_recovery_cleanup_failed session={s} err={s}",
                    .{ self.active_id, @errorName(err) },
                );
            };
            self.state.recovery_checkpoint.?.deinit(alloc);
            self.state.recovery_checkpoint = null;
        }
        self.state.updated_at_ms = timestamp_ms;
        self.position = .{
            .log_generation = self.position.log_generation,
            .through_seq = self.conversation_writer.last_seq,
            .through_event_id = randomIdentifier(),
            .through_event_log_bytes = self.conversation_writer.committed_bytes,
        };
        self.freshly_started = false;
        return self.position;
    }

    fn appendConversationMetadataEvent(
        self: *LoadedWritableSession,
        alloc: Allocator,
        event: SessionUpdate,
        timestamp_ms: i64,
    ) !CommitPosition {
        switch (event) {
            .preferences_changed => |patch| {
                var preferences = try self.state.preferences.dupe(alloc);
                errdefer preferences.deinit(alloc);
                if (patch.model) |model| {
                    const copy = try alloc.dupe(u8, model);
                    alloc.free(preferences.model);
                    preferences.model = copy;
                }
                if (patch.provider) |provider| preferences.provider = provider;
                if (patch.effort) |effort| preferences.effort = effort;
                if (patch.fast_mode) |fast_mode| preferences.fast_mode = fast_mode;
                if (patch.ultrafast_mode) |ultrafast_mode| preferences.ultrafast_mode = ultrafast_mode;
                var proposed = self.state;
                proposed.preferences = preferences;
                proposed.updated_at_ms = timestamp_ms;
                try session_codec.validateState(proposed);
                try writeConversationMetadata(alloc, &self.log.dir, proposed);
                self.state.preferences.deinit(alloc);
                self.state.preferences = preferences;
            },
            .workspace_rebound => |rebound| {
                if (!std.mem.eql(
                    u8,
                    rebound.previous_workspace_root,
                    self.state.workspace_root,
                ) or std.mem.eql(
                    u8,
                    rebound.workspace_root,
                    self.state.workspace_root,
                )) {
                    return error.ImmutableSessionIdentity;
                }
                const workspace_root = try alloc.dupe(u8, rebound.workspace_root);
                errdefer mem_utils.free(alloc, workspace_root);
                var proposed = self.state;
                proposed.workspace_root = workspace_root;
                proposed.updated_at_ms = timestamp_ms;
                try session_codec.validateState(proposed);
                try writeConversationMetadata(alloc, &self.log.dir, proposed);
                alloc.free(self.state.workspace_root);
                self.state.workspace_root = workspace_root;
            },
            else => return error.InvalidConversationEvent,
        }
        self.state.updated_at_ms = timestamp_ms;
        self.freshly_started = false;
        return self.position;
    }

    fn appendConversationUsageEvent(
        self: *LoadedWritableSession,
        alloc: Allocator,
        event: SessionUpdate,
        timestamp_ms: i64,
    ) !CommitPosition {
        const snapshot = switch (event) {
            .usage_checkpointed => |payload| payload.usage,
            else => return error.InvalidConversationEvent,
        };
        var next_usage = try session_usage.dupeSnapshotOwned(alloc, snapshot);
        errdefer next_usage.deinit(alloc);
        try session_usage_sidecar.write(
            alloc,
            &self.log.dir,
            self.active_id,
            snapshot,
        );
        if (self.state.usage) |*prior| prior.deinit(alloc);
        self.state.usage = next_usage;
        next_usage = undefined;
        self.state.updated_at_ms = timestamp_ms;
        return self.position;
    }

    fn appendConversationRecoveryEvent(
        self: *LoadedWritableSession,
        alloc: Allocator,
        event: SessionUpdate,
        timestamp_ms: i64,
    ) !CommitPosition {
        switch (event) {
            .recovery_checkpoint_set => |payload| {
                const checkpoint = try payload.checkpoint.dupe(alloc);
                errdefer {
                    var owned = checkpoint;
                    owned.deinit(alloc);
                }
                try writeConversationRecoveryState(
                    alloc,
                    &self.log.dir,
                    checkpoint,
                    self.conversation_writer.last_seq,
                );
                if (self.state.recovery_checkpoint) |*prior| prior.deinit(alloc);
                self.state.recovery_checkpoint = checkpoint;
            },
            .recovery_checkpoint_cleared => {
                try writeConversationRecoveryState(alloc, &self.log.dir, null, self.conversation_writer.last_seq);
                if (self.state.recovery_checkpoint) |*prior| prior.deinit(alloc);
                self.state.recovery_checkpoint = null;
            },
            else => return error.InvalidConversationEvent,
        }
        self.state.updated_at_ms = timestamp_ms;
        return self.position;
    }

    pub fn replacePermissionState(
        self: *LoadedWritableSession,
        alloc: Allocator,
        permission_state: session_permission_state.State,
        timestamp_ms: i64,
    ) !void {
        try self.requireWritable();
        var next = try session_permission_state.dupe(alloc, permission_state);
        errdefer next.deinit(alloc);
        const bytes = try session_codec.encodePermissionState(alloc, next);
        defer alloc.free(bytes);
        io_mod.durableReplaceVerified(
            alloc,
            &self.log.dir,
            permission_state_file,
            bytes,
        ) catch |err| return self.recordWriteFailure(err);
        self.state.permission_state.deinit(alloc);
        self.state.permission_state = next;
        self.state.updated_at_ms = timestamp_ms;
        self.freshly_started = false;
    }
};

/// Consumes a validated legacy snapshot and its locked directory, then writes
/// the current conversation representation directly. The legacy metadata stays
/// authoritative until the complete event log is durable; callers receive only
/// a current-format writable session.
pub fn importLegacySnapshotState(
    alloc: Allocator,
    writable: *WritableSessionDir,
    state: session_codec.DurableSessionState,
    source_schema_version: u8,
    source_bytes: u64,
    source_generation: ?Identifier,
) !LoadedWritableSession {
    return importLegacySnapshotStateWithOps(
        alloc,
        writable,
        state,
        source_schema_version,
        source_bytes,
        source_generation,
        .{},
    );
}

fn discardEmptyLegacyFileEvidence(alloc: Allocator, history: []session.HistoryTurn) !usize {
    var discarded: usize = 0;
    for (history) |*turn| {
        const execution = switch (turn.*) {
            .assistant => |*entry| &entry.execution,
            .interrupted => |*entry| &entry.execution,
            .compacted_summary => continue,
        };
        const files = execution.files;
        var retained_count: usize = 0;
        for (files) |file| if (file.path.len > 0) {
            retained_count += 1;
        };
        if (retained_count == files.len) continue;
        const retained = try alloc.alloc(types.FileEvidence, retained_count);
        var index: usize = 0;
        for (files) |file| {
            if (file.path.len == 0) {
                types.freeFileEvidence(alloc, file);
            } else {
                retained[index] = file;
                index += 1;
            }
        }
        discarded += files.len - retained_count;
        alloc.free(files);
        execution.files = retained;
    }
    return discarded;
}

fn importLegacySnapshotStateWithOps(
    alloc: Allocator,
    writable: *WritableSessionDir,
    state: session_codec.DurableSessionState,
    source_schema_version: u8,
    source_bytes: u64,
    source_generation: ?Identifier,
    metadata_ops: io_mod.DurableOps,
) !LoadedWritableSession {
    try recoverInterruptedLegacyImport(alloc, writable);
    var migrated_permissions = if (state.permission_state.version != session_permission_state.schema_version)
        try session_permission_state.migrateV1ToV2(alloc, state.permission_state)
    else
        null;
    defer if (migrated_permissions) |*permissions| permissions.deinit(alloc);
    var import_state = state;
    if (migrated_permissions) |permissions| import_state.permission_state = permissions;
    var converted = try import_state.dupe(alloc);
    errdefer converted.deinit(alloc);
    if (try converted.archive_legacy_recovery(alloc)) {
        debug_trace.logf("session", "legacy recovery archived session_id={s} reason=unverifiable_route_authority", .{converted.id});
    }
    const discarded = try discardEmptyLegacyFileEvidence(alloc, converted.history);
    if (discarded > 0) debug_trace.logf("session", "legacy import discarded file evidence count={d} reason=empty_path", .{discarded});
    try projectConversationSnapshotLocators(alloc, converted.history);

    const display_path = try io_mod.dirRealpathAlloc(
        alloc,
        writable.dir.dir,
        ".",
    );
    defer alloc.free(display_path);
    var capability = try session_child_store.SessionChildCapability.init(
        alloc,
        writable.dir.dir,
        display_path,
        .writable,
    );
    defer capability.deinit();
    try externalizeConversationResults(alloc, &converted, &capability);

    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer mem_utils.free(alloc, active_id);
    try deleteConversationMigrationFile(
        &writable.dir,
        conversation_migration_temp_file,
    );
    var temp_file = try createManagedFile(
        &writable.dir,
        conversation_migration_temp_file,
    );
    var writer = ConversationWriter.init(alloc, temp_file) catch |err| {
        temp_file.close(io_mod.getIo());
        return err;
    };
    var writer_owned = true;
    defer if (writer_owned) writer.deinit();
    for (converted.history, 0..) |turn, index| {
        if (turn == .compacted_summary) {
            // Legacy archives can retain raw turns before the active summary.
            // Earlier summaries stay archived without advancing that cut.
            const coverage = if (index > 0 and index == converted.context_history_start)
                try writer.contextCoverage(alloc, .{ .turns = turn.compacted_summary.removed_turn_count }, &.{})
            else
                writer.latest_checkpoint_coverage;
            _ = try writer.append(alloc, converted.updated_at_ms, .{ .context_checkpoint = .{
                .covers_through_seq = coverage,
                .summary = turn.compacted_summary.summary,
            } });
        } else {
            try appendPersistedHistoryTurn(
                alloc,
                &writable.dir,
                &writer,
                converted.updated_at_ms,
                turn,
            );
        }
    }
    const conversation_seq = writer.last_seq;
    writer.deinit();
    writer_owned = false;

    try writeConversationControlState(alloc, &writable.dir, converted, conversation_seq);
    var display = try session_display_metadata.deriveFromHistory(
        alloc,
        converted.history,
    );
    defer display.deinit(alloc);
    const metadata_bytes = try encodeConversationMetadataWithTitle(
        alloc,
        converted,
        if (display.present) display.title else null,
    );
    defer alloc.free(metadata_bytes);
    const had_previous_log = try entryExists(&writable.dir, events_file);
    var old_log_renamed = false;
    var new_log_published = false;
    var metadata_published = false;
    errdefer if (!metadata_published) {
        if (new_log_published) {
            deleteConversationMigrationFile(&writable.dir, events_file) catch {};
        }
        if (old_log_renamed) {
            writable.dir.dir.rename(
                conversation_migration_backup_file,
                writable.dir.dir,
                events_file,
                io_mod.getIo(),
            ) catch {};
        }
        io_mod.syncVerifiedDir(writable.dir.dir) catch {};
    };
    if (had_previous_log) {
        try writable.dir.dir.rename(
            events_file,
            writable.dir.dir,
            conversation_migration_backup_file,
            io_mod.getIo(),
        );
        old_log_renamed = true;
    }
    try writable.dir.dir.rename(
        conversation_migration_temp_file,
        writable.dir.dir,
        events_file,
        io_mod.getIo(),
    );
    new_log_published = true;
    try io_mod.syncVerifiedDir(writable.dir.dir);
    io_mod.durableReplaceVerifiedWithOps(
        alloc,
        &writable.dir,
        manifest_file,
        metadata_bytes,
        metadata_ops,
    ) catch |err| {
        // A failed directory sync can leave the new metadata visible. Keep
        // both logs so recovery can select the metadata that survived.
        if (err == error.DurableReplacePostRenameFailed) metadata_published = true;
        return err;
    };
    metadata_published = true;

    var hydrated = (try loadConversationStateIfPresent(alloc, &writable.dir, converted.id)) orelse
        return error.InvalidSessionMetadata;
    defer hydrated.deinit(alloc);
    session.freeHistoryTurnSlice(alloc, converted.history);
    converted.history = hydrated.history;
    hydrated.history = &.{};
    converted.context_history_start = hydrated.context_history_start;
    if (converted.recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
    converted.recovery_checkpoint = hydrated.recovery_checkpoint;
    hydrated.recovery_checkpoint = null;

    var event_file = try openManagedFile(
        &writable.dir,
        events_file,
        .read_write,
    );
    deleteLegacyConversationFiles(
        alloc,
        &writable.dir,
        source_generation,
    ) catch |err| debug_trace.logf(
        "session",
        "event=legacy_session_cleanup_failed session={s} err={s}",
        .{ writable.session_id, @errorName(err) },
    );

    // Tee the freshly migrated log into a replay cache during the writer's
    // open scan so legacy sessions are cache-backed from their first resume.
    var import_source = HistoryFrameSource{
        .log_file = event_file,
        .log_length = try event_file.length(io_mod.getIo()),
    };
    var import_snapshot: ?history_snapshot.Writer = history_snapshot.Writer.beginReplace(
        alloc,
        &writable.dir,
        writable.session_id,
    ) catch |err| blk: {
        debug_trace.logf("session", "history cache create-on-import failed id={s} err={s}", .{ writable.session_id, @errorName(err) });
        break :blk null;
    };
    var conversation_writer = ConversationWriter.initWithReplayScan(
        alloc,
        event_file,
        null,
        &import_source,
        if (import_snapshot) |*snapshot| snapshot else null,
    ) catch |err| {
        if (import_snapshot) |*snapshot| snapshot.finalize();
        event_file.close(io_mod.getIo());
        return err;
    };
    if (import_snapshot) |*snap| snap.finalize();
    import_snapshot = null;
    errdefer conversation_writer.deinit();

    const position = CommitPosition{
        .log_generation = randomIdentifier(),
        .through_seq = conversation_writer.last_seq,
        .through_event_id = randomIdentifier(),
        .through_event_log_bytes = conversation_writer.committed_bytes,
    };
    const result = LoadedWritableSession{
        .active_id = active_id,
        .state = converted,
        .conversation_writer = conversation_writer,
        .log = writable.*,
        .position = position,
        .migration_source_schema_version = source_schema_version,
        .migration_source_bytes = source_bytes,
    };
    converted = undefined;
    writable.* = undefined;
    return result;
}
/// Preserves each call's exact error set while sharing one dynamic return ABI.
pub inline fn failLoadedWritableSession(err: anytype) @TypeOf(err)!LoadedWritableSession {
    return @errorCast(failLoadedWritableSessionDynamic(err));
}

noinline fn failLoadedWritableSessionDynamic(err: anyerror) anyerror!LoadedWritableSession {
    return err;
}

pub const Root = struct {
    sessions: ?io_mod.VerifiedDir,
    display_root: []u8,
    mode: OpenMode,

    pub fn initFromHome(
        alloc: Allocator,
        home_path: []const u8,
        mode: OpenMode,
    ) !Root {
        const zio = io_mod.getIo();
        var home = std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) {
                    return .{
                        .sessions = null,
                        .display_root = try std.Io.Dir.path.join(
                            alloc,
                            &.{ home_path, profile_paths.root_dir_name, profile_paths.sessions_dir_name },
                        ),
                        .mode = mode,
                    };
                }
                std.Io.Dir.createDirAbsolute(zio, home_path, private_dir_permissions) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    else => return create_err,
                };
                break :blk try std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true });
            },
            else => return err,
        };
        defer home.close(zio);

        var durable_home = home.openDir(zio, profile_paths.root_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) {
                    return .{
                        .sessions = null,
                        .display_root = try std.Io.Dir.path.join(
                            alloc,
                            &.{ home_path, profile_paths.root_dir_name, profile_paths.sessions_dir_name },
                        ),
                        .mode = mode,
                    };
                }
                var verified_home = io_mod.VerifiedDir{
                    .dir = try std.Io.Dir.openDirAbsolute(zio, home_path, .{
                        .iterate = true,
                    }),
                };
                defer verified_home.close();
                const created = try io_mod.openOrCreateVerifiedPrivateDir(
                    &verified_home,
                    profile_paths.root_dir_name,
                );
                break :blk created.dir;
            },
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        defer durable_home.close(zio);
        if (mode == .writable) {
            durable_home.setPermissions(zio, private_dir_permissions) catch
                return error.PrivateStatePermissionsUnsupported;
        }
        try verifyPrivateDir(durable_home, mode);

        var sessions_dir = durable_home.openDir(zio, profile_paths.sessions_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) {
                    return .{
                        .sessions = null,
                        .display_root = try std.Io.Dir.path.join(
                            alloc,
                            &.{ home_path, profile_paths.root_dir_name, profile_paths.sessions_dir_name },
                        ),
                        .mode = mode,
                    };
                }
                var parent = io_mod.VerifiedDir{ .dir = durable_home };
                const created = try io_mod.openOrCreateVerifiedPrivateDir(
                    &parent,
                    profile_paths.sessions_dir_name,
                );
                break :blk created.dir;
            },
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        errdefer sessions_dir.close(zio);
        if (mode == .writable) {
            sessions_dir.setPermissions(zio, private_dir_permissions) catch
                return error.PrivateStatePermissionsUnsupported;
        }
        try verifyPrivateDir(sessions_dir, mode);
        const display_root = try io_mod.dirRealpathAlloc(alloc, sessions_dir, ".");
        return .{
            .sessions = .{ .dir = sessions_dir },
            .display_root = display_root,
            .mode = mode,
        };
    }

    pub fn deinit(self: *Root, alloc: Allocator) void {
        if (self.sessions) |*dir| dir.close();
        alloc.free(self.display_root);
        self.* = undefined;
    }

    pub fn startConversationSession(
        self: *Root,
        alloc: Allocator,
        initial_state: session_codec.DurableSessionState,
        options: Options,
    ) !LoadedWritableSession {
        if (self.mode != .writable or self.sessions == null) {
            return failLoadedWritableSession(error.SessionStoreUnavailable);
        }
        try session_codec.validateState(initial_state);
        const sessions = &self.sessions.?;
        if (try entryExists(sessions, initial_state.id)) {
            return failLoadedWritableSession(error.SessionAlreadyExists);
        }

        const random = randomIdentifier();
        const suffix = std.fmt.bytesToHex(random, .lower);
        const staging_name = try alloc.print("creating+{s}", .{suffix});
        defer alloc.free(staging_name);
        sessions.dir.createDir(
            io_mod.getIo(),
            staging_name,
            private_dir_permissions,
        ) catch return failLoadedWritableSession(error.SessionStartFailed);
        var unpublished = true;
        errdefer if (unpublished) {
            debug_trace.logf("session", "session creation discarded unpublished state id={s}", .{initial_state.id});
            sessions.dir.deleteTree(io_mod.getIo(), staging_name) catch |err| {
                debug_trace.logf("session", "session creation cleanup retained id={s} err={s}", .{ initial_state.id, @errorName(err) });
            };
        };

        var session_dir = try io_mod.openOrCreateVerifiedPrivateDir(sessions, staging_name);
        options.test_controls.lock(.session);
        var writer_lock = acquireLockWithDeadline(
            &session_dir,
            session_lock_file,
            true,
            options.session_lock_deadline_ms,
        ) catch |err| {
            session_dir.close();
            return mapSessionLockError(err);
        };
        const session_id = alloc.dupe(u8, initial_state.id) catch |err| {
            writer_lock.release();
            session_dir.close();
            return err;
        };
        var writable = WritableSessionDir{
            .dir = session_dir,
            .writer_lock = writer_lock,
            .session_id = session_id,
        };
        writable.trackOwnerLiveness(alloc);
        var writable_owned = true;
        errdefer if (writable_owned) writable.deinit(alloc);
        var loaded = try createNativeSession(
            alloc,
            &writable,
            initial_state,
            options,
        );
        writable_owned = false;
        errdefer loaded.deinit(alloc);
        try loaded.conversation_writer.file.sync(io_mod.getIo());
        try io_mod.syncVerifiedDir(loaded.log.dir.dir);
        publishSessionDirectory(sessions.dir, staging_name, initial_state.id) catch |err| {
            if (err == error.PathAlreadyExists) return error.SessionAlreadyExists;
            debug_trace.logf("session", "session creation publication failed id={s} err={s}", .{ initial_state.id, @errorName(err) });
            return err;
        };
        unpublished = false;
        io_mod.syncVerifiedDir(sessions.dir) catch |err| {
            debug_trace.logf("session", "session creation retained published state id={s} durability=uncertain err={s}", .{ initial_state.id, @errorName(err) });
            return error.SessionStartFailed;
        };
        return loaded;
    }

    pub fn resumeForWrite(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        options: Options,
    ) !LoadedWritableSession {
        options.test_controls.lock(.session);
        var writable = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.session_lock_deadline_ms,
        );
        errdefer writable.deinit(alloc);
        if (!try hasConversationMetadata(alloc, &writable.dir)) {
            return error.SessionMigrationRequired;
        }
        // Compact legacy fat logs (inline diff snapshots) before the open
        // scan replays them. Pre-rename failures keep the original log intact
        // and do not block resume. A post-rename directory-sync failure is
        // persistence-uncertain and must stop the writer from appending to an
        // inode whose directory entry is not known durable.
        if (session_compaction.compactIfNeeded(alloc, &writable.dir, writable.session_id, .{
            .test_controls = options.test_controls.compaction,
        })) |_| {} else |err| {
            if (err == error.OutOfMemory) return err;
            if (err == error.SessionCompactionPersistenceUncertain) {
                return error.SessionPersistenceUncertain;
            }
            debug_trace.logf("session", "event=session_log_compaction_degraded id={s} err={s}; resuming from original log", .{ writable.session_id, @errorName(err) });
        }
        return openConversationWritableSession(alloc, &writable);
    }

    pub fn loadReadOnly(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        _: Options,
    ) !session_codec.DurableSessionState {
        if (self.sessions == null) return error.SessionNotFound;
        var session_dir = openSessionDir(
            &self.sessions.?,
            session_id,
            .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        defer session_dir.close();
        return (try loadConversationStateIfPresent(
            alloc,
            &session_dir,
            session_id,
        )) orelse error.SessionMigrationRequired;
    }

    /// Reads the child identity a legacy session records in its first event,
    /// for a session discovery classified as legacy, whose metadata carries no
    /// child bit. The event is read only within `listed_first_event_max_bytes`,
    /// so listing never scans a log; a longer first line fails with
    /// `error.TruncatedEventFrame`.
    pub fn loadListedLegacyChildIdentity(
        self: *const Root,
        alloc: Allocator,
        session_id: []const u8,
    ) !bool {
        var sessions = self.sessions orelse return error.SessionNotFound;
        try session_layout.validateSessionId(session_id);
        var session_dir = openSessionDir(
            &sessions,
            session_id,
            .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        defer session_dir.close();
        var log_file = try openManagedFile(&session_dir, events_file, .read_only);
        defer log_file.close(io_mod.getIo());
        return session_replay.readSubagentChildIdentityWithin(alloc, log_file, listed_first_event_max_bytes);
    }

    fn openWritableSessionDir(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        deadline_ms: u64,
    ) !WritableSessionDir {
        if (self.mode != .writable or self.sessions == null) return error.SessionNotFound;
        try session_layout.validateSessionId(session_id);
        var dir = openSessionDir(&self.sessions.?, session_id, .writable) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        var writer_lock = acquireLockWithDeadline(
            &dir,
            session_lock_file,
            true,
            deadline_ms,
        ) catch |err| {
            dir.close();
            return mapSessionLockError(err);
        };
        const owned_id = alloc.dupe(u8, session_id) catch |err| {
            writer_lock.release();
            dir.close();
            return err;
        };
        var writable = WritableSessionDir{
            .dir = dir,
            .writer_lock = writer_lock,
            .session_id = owned_id,
        };
        writable.trackOwnerLiveness(alloc);
        return writable;
    }

    fn entryExistsForTest(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        name: []const u8,
    ) !bool {
        _ = alloc;
        if (self.sessions == null) return false;
        var dir = openSessionDir(&self.sessions.?, session_id, .read_only) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer dir.close();
        return entryExists(&dir, name);
    }
};

fn publishSessionDirectory(parent: std.Io.Dir, staging: []const u8, target: []const u8) !void {
    if (comptime @import("builtin").target.os.tag != .macos) {
        return parent.renamePreserve(staging, parent, target, io_mod.getIo());
    }
    // Zig 0.16's Darwin preserve-rename used hard links, which cannot publish
    // directories. Zig 0.17 calls renameatx_np as this does, but treats
    // ENOTEMPTY as a programmer bug: a panic in Debug builds and
    // error.Unexpected otherwise. fx keeps its own error mapping.
    const Darwin = struct {
        extern "c" fn renameatx_np(c_int, [*:0]const u8, c_int, [*:0]const u8, c_uint) c_int;
    };
    var staging_buffer: [256]u8 = undefined;
    var target_buffer: [256]u8 = undefined;
    const staging_z = try std.mem.printSentinel(&staging_buffer, "{s}", .{staging}, 0);
    const target_z = try std.mem.printSentinel(&target_buffer, "{s}", .{target}, 0);
    while (true) {
        try io_mod.getIo().checkCancel();
        const err = std.posix.errno(Darwin.renameatx_np(parent.handle, staging_z, parent.handle, target_z, 0x4));
        switch (err) {
            .SUCCESS => return,
            .INTR => continue,
            .EXIST, .NOTEMPTY => return error.PathAlreadyExists,
            .OPNOTSUPP, .NOSYS => return error.OperationUnsupported,
            else => {
                debug_trace.logf("session", "session directory publication failed errno={s}", .{@tagName(err)});
                return error.SessionStartFailed;
            },
        }
    }
}

fn validateLeaf(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.findAny(u8, name, "/\\") != null)
    {
        return error.SessionPathUnsafe;
    }
}

fn verifyPrivateDir(dir: std.Io.Dir, mode: OpenMode) !void {
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory) return error.SessionPathUnsafe;
    if (mode == .writable and stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn verifyManagedFile(file: std.Io.File, mode: OpenMode) !void {
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.SessionPathUnsafe;
    if (mode == .writable and stat.permissions.toMode() & 0o777 != 0o600) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn openSessionDir(
    sessions: *io_mod.VerifiedDir,
    session_id: []const u8,
    mode: OpenMode,
) !io_mod.VerifiedDir {
    try session_layout.validateSessionId(session_id);
    var dir = sessions.dir.openDir(io_mod.getIo(), session_id, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer dir.close(io_mod.getIo());
    if (mode == .writable) {
        dir.setPermissions(io_mod.getIo(), private_dir_permissions) catch
            return error.PrivateStatePermissionsUnsupported;
    }
    try verifyPrivateDir(dir, mode);
    return .{ .dir = dir };
}

/// Opens an existing session file without waiting on a special file such as
/// a FIFO; non-regular, hard-linked, or linked targets are unsafe.
fn openManagedFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !std.Io.File {
    try validateLeaf(name);
    var file = io_mod.openExistingRegularFile(dir.dir, name, mode) catch |err| switch (err) {
        error.DurablePathUnsafe, error.IsDir, error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    try verifyManagedFile(file, if (mode == .read_only) .read_only else .writable);
    return file;
}

fn createManagedFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
) !std.Io.File {
    try validateLeaf(name);
    var file = dir.dir.createFile(io_mod.getIo(), name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = private_file_permissions,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.IsDir, error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    file.setPermissions(io_mod.getIo(), private_file_permissions) catch
        return error.PrivateStatePermissionsUnsupported;
    try verifyManagedFile(file, .writable);
    return file;
}

fn entryExists(dir: *io_mod.VerifiedDir, name: []const u8) !bool {
    try validateLeaf(name);
    const stat = dir.dir.statFile(io_mod.getIo(), name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    if (stat.kind != .file and stat.kind != .directory) return error.SessionPathUnsafe;
    if (stat.kind == .file and stat.nlink != 1) return error.SessionPathUnsafe;
    return true;
}

fn acquireLockWithDeadline(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    create: bool,
    deadline_ms: u64,
) !io_mod.TimedAdvisoryLock {
    if (create) {
        return io_mod.acquireTimedAdvisoryLock(dir, name, deadline_ms);
    }
    var file = try openManagedFile(dir, name, .read_write);
    errdefer file.close(io_mod.getIo());
    const started = io_mod.milliTimestamp();
    while (true) {
        const locked = file.tryLock(io_mod.getIo(), .exclusive) catch |err| switch (err) {
            error.FileLocksUnsupported => return error.LockUnsupported,
            else => return err,
        };
        if (locked) return .{ .file = file };
        if (io_mod.milliTimestamp() - started >= deadline_ms) return error.LockBusy;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}

fn mapSessionLockError(err: anyerror) anyerror {
    return switch (err) {
        error.LockBusy => error.SessionBusy,
        error.LockUnsupported => error.SessionLockUnsupported,
        else => err,
    };
}

fn readManagedFileAlloc(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try openManagedFile(dir, name, .read_only);
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes + 1) catch |err| switch (err) {
        error.StreamTooLong => error.InvalidSessionFormat,
        else => err,
    };
}

fn randomIdentifier() Identifier {
    var id: Identifier = undefined;
    io_mod.getIo().random(&id);
    return id;
}

fn watermarkName(alloc: Allocator, generation: Identifier) ![]u8 {
    const hex = std.fmt.bytesToHex(generation, .lower);
    return alloc.print("commit.{s}.json", .{hex});
}

fn createNativeSession(
    alloc: Allocator,
    writable: *WritableSessionDir,
    initial_state: session_codec.DurableSessionState,
    _: Options,
) !LoadedWritableSession {
    var synthesized_usage: ?session_usage.Snapshot = null;
    if (initial_state.usage == null) {
        var fresh_usage = session_usage.Usage.initFresh();
        defer fresh_usage.deinit(alloc);
        synthesized_usage = try fresh_usage.snapshot(alloc);
    }
    defer if (synthesized_usage) |*usage| usage.deinit(alloc);

    var display = try session_display_metadata.deriveFromHistory(
        alloc,
        initial_state.history,
    );
    defer display.deinit(alloc);
    var conversation_writer = try createConversationStorage(alloc, &writable.dir, .{
        .id = initial_state.id,
        .origin_workspace_root = initial_state.origin_workspace_root,
        .workspace_root = initial_state.workspace_root,
        .created_at_ms = initial_state.created_at_ms,
        .updated_at_ms = initial_state.updated_at_ms,
        .conversation_language = initial_state.conversation_language.view(),
        .provider = initial_state.preferences.provider,
        .model = initial_state.preferences.model,
        .effort = initial_state.preferences.effort.label(),
        .fast_mode = initial_state.preferences.fast_mode,
        .ultrafast_mode = if (initial_state.preferences.ultrafast_mode) true else null,
        .title = if (display.present) display.title else null,
        .subagent_child = initial_state.subagent_child,
    });
    errdefer conversation_writer.deinit();
    for (initial_state.history) |turn| {
        if (turn == .compacted_summary and conversation_writer.last_seq == 0) continue;
        try appendPersistedHistoryTurn(
            alloc,
            &writable.dir,
            &conversation_writer,
            initial_state.updated_at_ms,
            turn,
        );
    }

    var state = try initial_state.dupe(alloc);
    errdefer state.deinit(alloc);
    if (state.usage == null) {
        state.usage = synthesized_usage;
        synthesized_usage = null;
    }
    try writeConversationControlState(alloc, &writable.dir, state, conversation_writer.last_seq);
    const persisted_state = (try loadConversationStateIfPresent(
        alloc,
        &writable.dir,
        writable.session_id,
    )) orelse return error.InvalidSessionMetadata;
    state.deinit(alloc);
    state = persisted_state;
    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer mem_utils.free(alloc, active_id);
    const generation = randomIdentifier();
    const position = CommitPosition{
        .log_generation = generation,
        .through_seq = conversation_writer.last_seq,
        .through_event_id = randomIdentifier(),
        .through_event_log_bytes = conversation_writer.committed_bytes,
    };
    const result = LoadedWritableSession{
        .active_id = active_id,
        .state = state,
        .conversation_writer = conversation_writer,
        .log = writable.*,
        .freshly_started = true,
        .position = position,
    };
    writable.* = undefined;
    return result;
}

pub fn durableStatesEqual(
    first: session_codec.DurableSessionState,
    second: session_codec.DurableSessionState,
) !bool {
    var first_buffer: [4096]u8 = undefined;
    var first_discard = std.Io.Writer.Discarding.init(&first_buffer);
    const first_summary = try session_codec.encodeState(
        first,
        &first_discard.writer,
    );
    var second_buffer: [4096]u8 = undefined;
    var second_discard = std.Io.Writer.Discarding.init(&second_buffer);
    const second_summary = try session_codec.encodeState(
        second,
        &second_discard.writer,
    );
    return first_summary.encoded_bytes == second_summary.encoded_bytes and
        std.mem.eql(
            u8,
            &first_summary.sha256,
            &second_summary.sha256,
        );
}

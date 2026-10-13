const std = @import("std");
const Allocator = std.mem.Allocator;

const debug_trace = @import("../../core/shared/debug_trace.zig");
const display_width = @import("../../core/shared/display_width.zig");
const shared_theme = @import("../../core/shared/theme.zig");
const types = @import("../../core/shared/types.zig");
const FinishedPrompt = types.FinishedPrompt;

pub const EmitFn = *const fn (*anyopaque, []const u8) anyerror!void;
pub const FinishResult = union(enum) {
    committed,
    presentation_failed: anyerror,
};

// A result acknowledges history. An error retains the finish for settlement.
pub const FinishFn = *const fn (*anyopaque, FinishedPrompt) anyerror!FinishResult;

pub const DeferredFinishCommit = enum {
    uncommitted,
    committed,
};

pub const DeferredPresentationCallbacks = struct {
    ctx: *anyopaque,
    append_history: *const fn (*anyopaque, *const FinishedPrompt) anyerror!DeferredFinishCommit,
};

const FlushResult = enum {
    drained,
    blocked,
};

pub const TickCallbacks = struct {
    emit_ctx: *anyopaque,
    emit_fn: EmitFn,
    finish_ctx: *anyopaque,
    finish_fn: FinishFn,
};

pub const SgrState = struct {
    /// The tracked foreground open. Theme-owned slots re-resolve at restore
    /// time so live theme flips retint mid-stream; anything else restores
    /// with its original bytes.
    const Foreground = enum { none, inline_code, link, other };

    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    fg: Foreground = .none,
    fg_buf: [24]u8 = undefined,
    fg_len: u8 = 0,

    pub fn isActive(self: SgrState) bool {
        return self.bold or self.dim or self.italic or self.underline or self.strike or self.fg != .none;
    }

    /// Update based on a complete ANSI sequence (including `\x1b[` prefix and
    /// terminator). Unrecognized sequences are ignored, so non-SGR escapes
    /// (cursor moves, erasures, etc.) do not confuse the tracker.
    pub fn apply(self: *SgrState, seq: []const u8) void {
        if (seq.len < 3) return;
        if (seq[0] != 0x1b or seq[1] != '[') return;
        if (seq[seq.len - 1] != 'm') return;
        const body = seq[2 .. seq.len - 1];

        if (body.len == 0 or std.mem.eql(u8, body, "0")) {
            self.* = .{};
            return;
        }

        // Exact full-body match against the known single-parameter codes the
        // markdown renderer emits; multi-parameter SGRs (e.g. "1;38;5;245")
        // count for every attribute and the color they carry.
        if (std.mem.eql(u8, body, "1")) self.bold = true else if (std.mem.eql(u8, body, "2")) self.dim = true else if (std.mem.eql(u8, body, "3")) self.italic = true else if (std.mem.eql(u8, body, "4")) self.underline = true else if (std.mem.eql(u8, body, "9")) self.strike = true else if (std.mem.eql(u8, body, "22")) {
            self.bold = false;
            self.dim = false;
        } else if (std.mem.eql(u8, body, "23")) self.italic = false else if (std.mem.eql(u8, body, "24")) self.underline = false else if (std.mem.eql(u8, body, "29")) self.strike = false else if (std.mem.eql(u8, body, "39")) {
            self.fg = .none;
        } else {
            // Multi-parameter SGRs (e.g. "1;38;5;245") apply each attribute
            // they carry; color-spec parameters are not attributes.
            if (std.mem.findScalar(u8, body, ';') != null) {
                var params = std.mem.splitScalar(u8, body, ';');
                while (params.next()) |param| {
                    if (std.mem.eql(u8, param, "38") or std.mem.eql(u8, param, "48")) {
                        // Skip the color space and value parameters so their
                        // digits are not mistaken for attributes.
                        if (params.next()) |space| {
                            const skip: usize = if (std.mem.eql(u8, space, "2")) 3 else 1;
                            for (0..skip) |_| _ = params.next();
                        }
                        continue;
                    }
                    if (std.mem.eql(u8, param, "1")) self.bold = true else if (std.mem.eql(u8, param, "2")) self.dim = true else if (std.mem.eql(u8, param, "3")) self.italic = true else if (std.mem.eql(u8, param, "4")) self.underline = true else if (std.mem.eql(u8, param, "9")) self.strike = true;
                }
            }
            if (hasForegroundColor(body)) {
                if (std.mem.eql(u8, seq, shared_theme.current().inline_code_open)) {
                    self.fg = .inline_code;
                } else if (std.mem.eql(u8, seq, shared_theme.current().link_style)) {
                    self.fg = .link;
                } else if (seq.len <= self.fg_buf.len) {
                    @memcpy(self.fg_buf[0..seq.len], seq);
                    self.fg_len = @intCast(seq.len);
                    self.fg = .other;
                }
            }
        }
    }

    /// True when the SGR body sets a foreground color (a 38-prefixed extended
    /// color or a basic 30-37/90-97), including combined forms like 1;38;5;245.
    fn hasForegroundColor(body: []const u8) bool {
        var it = std.mem.splitScalar(u8, body, ';');
        while (it.next()) |param| {
            if (std.mem.eql(u8, param, "38")) return true;
            const value = std.fmt.parseInt(u8, param, 10) catch continue;
            if ((value >= 30 and value <= 37) or (value >= 90 and value <= 97)) return true;
        }
        return false;
    }

    /// Serialize open codes for the currently-active attributes into `buf`.
    /// Returns the number of bytes written. The caller sizes `buf` for five
    /// 4-byte attribute opens plus the active foreground open (bounded at 24
    /// bytes); an oversized open is truncated by the bounds check, degrading
    /// restore to pre-fix behavior rather than corrupting the frame.
    pub fn writeOpens(self: SgrState, buf: []u8) usize {
        var n: usize = 0;
        const append = struct {
            fn f(dst: []u8, pos: *usize, src: []const u8) void {
                if (pos.* + src.len <= dst.len) {
                    @memcpy(dst[pos.* .. pos.* + src.len], src);
                    pos.* += src.len;
                }
            }
        }.f;
        if (self.bold) append(buf, &n, "\x1b[1m");
        if (self.dim) append(buf, &n, "\x1b[2m");
        if (self.italic) append(buf, &n, "\x1b[3m");
        if (self.underline) append(buf, &n, "\x1b[4m");
        if (self.strike) append(buf, &n, "\x1b[9m");
        switch (self.fg) {
            .none => {},
            .inline_code => append(buf, &n, shared_theme.current().inline_code_open),
            .link => append(buf, &n, shared_theme.current().link_style),
            .other => append(buf, &n, self.fg_buf[0..self.fg_len]),
        }
        return n;
    }
};

pub const AssistantPacer = struct {
    pending: std.ArrayList(u8) = .empty,
    deferred_turn: ?FinishedPrompt = null,
    deferred_started_ns: ?i128 = null,
    /// Tracks which SGR attributes the terminal should have active at the
    /// start of the next emit. Other frame-work (footer, body renders)
    /// between ticks can emit their own `\x1b[0m`, so state is restored
    /// by prefixing each emit with `\x1b[0m` + the active opens.
    sgr: SgrState = .{},

    pub fn deinit(self: *AssistantPacer, alloc: Allocator) void {
        self.pending.deinit(alloc);
        if (self.deferred_turn) |finished| {
            types.freeFinishedPrompt(alloc, finished);
            self.deferred_turn = null;
        }
        self.deferred_started_ns = null;
    }

    pub fn hasPending(self: *const AssistantPacer) bool {
        return self.pending.items.len > 0 or self.deferred_turn != null;
    }

    pub fn hasCompletedAssistantPresentationTail(self: *const AssistantPacer) bool {
        const finished = self.deferred_turn orelse return false;
        return finished.terminal_outcome != null and
            finished.terminal_outcome.? == .completed and
            finished.summary != null and
            finished.turn == .assistant;
    }

    pub fn completedAssistantPresentationTokenProgress(self: *const AssistantPacer) ?types.TurnTokenProgress {
        if (!self.hasCompletedAssistantPresentationTail()) return null;
        return self.deferred_turn.?.summary.?.token_progress;
    }

    pub fn enqueue(self: *AssistantPacer, alloc: Allocator, text: []const u8) !void {
        if (text.len == 0) return;
        try self.pending.appendSlice(alloc, text);
    }

    pub fn pause(_: *AssistantPacer, _: i128) void {}

    pub fn rethemeInlineCode(self: *AssistantPacer, light: bool) void {
        const from = if (light) "\x1b[38;5;245m" else "\x1b[38;5;247m";
        const to = if (light) "\x1b[38;5;247m" else "\x1b[38;5;245m";

        var index: usize = 0;
        while (index + from.len <= self.pending.items.len) {
            if (std.mem.startsWith(u8, self.pending.items[index..], from)) {
                @memcpy(self.pending.items[index..][0..to.len], to);
                index += to.len;
            } else {
                index += 1;
            }
        }

        // Theme-owned opens re-emit from the active theme at restore time, so
        // there is nothing to rewrite in the tracker itself.
    }

    pub fn deferFinish(self: *AssistantPacer, alloc: Allocator, finished: FinishedPrompt) !bool {
        if (self.pending.items.len == 0) return false;
        if (self.deferred_turn) |old| {
            types.freeFinishedPrompt(alloc, old);
            self.deferred_turn = null;
        }
        self.deferred_turn = try types.dupeFinishedPrompt(alloc, finished);
        self.deferred_started_ns = null;
        return true;
    }

    pub fn clear(self: *AssistantPacer, alloc: Allocator) void {
        self.pending.clearRetainingCapacity();
        if (self.deferred_turn) |finished| {
            types.freeFinishedPrompt(alloc, finished);
            self.deferred_turn = null;
        }
        self.deferred_started_ns = null;
        self.sgr = .{};
    }

    pub fn discardDeferredPresentationForVisualEpoch(
        self: *AssistantPacer,
        alloc: Allocator,
        callbacks: DeferredPresentationCallbacks,
    ) !bool {
        const finished = self.deferred_turn orelse return true;
        if (try callbacks.append_history(callbacks.ctx, &finished) == .uncommitted) return false;

        self.deferred_turn = null;
        types.freeFinishedPrompt(alloc, finished);
        self.pending.clearRetainingCapacity();
        self.deferred_started_ns = null;
        self.sgr = .{};
        return true;
    }

    pub fn tick(self: *AssistantPacer, alloc: Allocator, now_ns: i128, cb: TickCallbacks) !void {
        if (self.pending.items.len == 0) {
            try self.fireDeferredFinish(alloc, now_ns, cb);
            return;
        }

        if (self.deferred_turn != null and self.deferred_started_ns == null) {
            self.deferred_started_ns = now_ns;
        }

        if (try self.emitPendingBlock(cb) == .drained or self.deferred_turn != null) {
            if (self.pending.items.len > 0) try self.neutralizeIncompleteTail(cb);
            try self.fireDeferredFinish(alloc, now_ns, cb);
        }
    }

    pub fn flushPresentationAtBoundary(
        self: *AssistantPacer,
        alloc: Allocator,
        now_ns: i128,
        cb: TickCallbacks,
    ) !void {
        if (self.pending.items.len > 0) {
            switch (try self.emitPendingBlock(cb)) {
                .drained => {},
                .blocked => try self.neutralizeIncompleteTail(cb),
            }
        }
        try self.fireDeferredFinish(alloc, now_ns, cb);
    }

    fn emitPendingBlock(self: *AssistantPacer, cb: TickCallbacks) !FlushResult {
        try self.emitCompletePrefix(cb);
        if (self.pending.items.len == 0) {
            return .drained;
        }
        return .blocked;
    }

    fn neutralizeIncompleteTail(self: *AssistantPacer, cb: TickCallbacks) !void {
        const tail = self.pending.items;
        std.debug.assert(tail.len > 0);
        if (tail[0] == 0x1b) {
            const kind: []const u8 = if (tail.len == 1)
                "escape"
            else if (tail[1] == '[')
                "csi"
            else if (tail[1] == ']')
                "osc"
            else
                "escape";
            try cb.emit_fn(cb.emit_ctx, "\xef\xbf\xbd\x1b[0m");
            debug_trace.logf(
                "ui_activity",
                "neutralized incomplete assistant control tail kind={s} bytes={d}",
                .{ kind, tail.len },
            );
        } else {
            try cb.emit_fn(cb.emit_ctx, "\xef\xbf\xbd\x1b[0m");
            debug_trace.logf(
                "ui_activity",
                "neutralized incomplete assistant utf8 tail bytes={d}",
                .{tail.len},
            );
        }

        self.pending.clearRetainingCapacity();
        self.sgr = .{};
    }

    fn fireDeferredFinish(self: *AssistantPacer, alloc: Allocator, now_ns: i128, cb: TickCallbacks) !void {
        if (self.deferred_turn) |finished| {
            const started_ns = self.deferred_started_ns;
            var callback_finished = finished;
            if (callback_finished.summary) |*summary| {
                const started = started_ns orelse now_ns;
                if (now_ns > started) {
                    summary.turn_duration_ms += @intCast(@divFloor(now_ns - started, std.time.ns_per_ms));
                }
            }
            const result = try cb.finish_fn(cb.finish_ctx, callback_finished);
            self.deferred_turn = null;
            self.deferred_started_ns = null;
            types.freeFinishedPrompt(alloc, finished);
            switch (result) {
                .committed => {},
                .presentation_failed => |err| return err,
            }
        }
    }

    fn emitCompletePrefix(self: *AssistantPacer, cb: TickCallbacks) !void {
        const i = self.emittablePrefixLen();
        if (i == 0) return;

        // Restore tracked SGR state because other renderers may reset it between ticks.
        if (self.sgr.isActive()) {
            var prefix_buf: [96]u8 = undefined;
            const reset = "\x1b[0m";
            @memcpy(prefix_buf[0..reset.len], reset);
            const opens_len = self.sgr.writeOpens(prefix_buf[reset.len..]);
            try cb.emit_fn(cb.emit_ctx, prefix_buf[0 .. reset.len + opens_len]);
        }

        try cb.emit_fn(cb.emit_ctx, self.pending.items[0..i]);
        self.updateSgrFromEmitted(self.pending.items[0..i]);
        self.consume(i);
    }

    fn emittablePrefixLen(self: *const AssistantPacer) usize {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const first = self.pending.items[i];
            if (first == 0x1b) {
                // Keep ANSI sequences atomic and hold incomplete tails for a later tick.
                const end = display_width.ansiSequenceEnd(self.pending.items, i);
                if (end > i) {
                    if (!ansiSequenceComplete(self.pending.items, i, end)) break;
                    i = end;
                    continue;
                }
            }
            const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
            if (i + len > self.pending.items.len) break;
            i += len;
        }
        return i;
    }

    fn updateSgrFromEmitted(self: *AssistantPacer, bytes: []const u8) void {
        var idx: usize = 0;
        while (idx < bytes.len) {
            if (bytes[idx] == 0x1b) {
                const end = display_width.ansiSequenceEnd(bytes, idx);
                if (end > idx) self.sgr.apply(bytes[idx..end]);
                idx = if (end > idx) end else idx + 1;
                continue;
            }
            idx += 1;
        }
    }

    fn ansiSequenceComplete(bytes: []const u8, start: usize, end: usize) bool {
        if (end <= start + 1) return false;
        if (start + 1 >= bytes.len) return false;
        const kind = bytes[start + 1];
        if (kind == '[') {
            if (end <= start + 2) return false;
            const last = bytes[end - 1];
            return last >= '@' and last <= '~';
        }
        if (kind == ']') {
            if (end <= start + 2) return false;
            const last = bytes[end - 1];
            if (last == 0x07) return true;
            if (end >= start + 4 and bytes[end - 2] == 0x1b and last == '\\') return true;
            return false;
        }
        return end == start + 2;
    }

    fn consume(self: *AssistantPacer, byte_count: usize) void {
        const remaining = self.pending.items.len - byte_count;
        if (remaining > 0) {
            @memmove(self.pending.items[0..remaining], self.pending.items[byte_count..]);
        }
        self.pending.items.len = remaining;
    }
};

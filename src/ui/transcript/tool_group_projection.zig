const std = @import("std");
const build_checkpoint = @import("../render_engine/build_checkpoint.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const types = @import("../../core/shared/types.zig");
const display_width = @import("../../core/shared/display_width.zig");
const mem_utils = @import("../../core/shared/mem_utils.zig");
const shared_theme = @import("../../core/shared/theme.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");
const ui_render = @import("../render.zig");
const code_highlight = @import("../../core/agent/presentation/code_highlight.zig");
const code_highlight_languages = @import("../../core/agent/presentation/code_highlight_languages.zig");

const TranscriptEntry = transcript_blocks.TranscriptEntry;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;
const cancellation_follow_up = " · What can fx do differently?";

pub const Projection = struct {
    entry_actions: std.ArrayList(transcript_blocks.EntryRenderAction) = .empty,
    owned_overrides: std.ArrayList(OwnedOverride) = .empty,

    pub fn deinit(self: *Projection, alloc: std.mem.Allocator) void {
        for (self.owned_overrides.items) |owned| {
            alloc.free(owned.bytes);
            alloc.free(owned.line_provenance);
        }
        self.owned_overrides.deinit(alloc);
        self.entry_actions.deinit(alloc);
        self.* = undefined;
    }

    fn setOwnedOverride(
        self: *Projection,
        alloc: std.mem.Allocator,
        entry_index: usize,
        kind: transcript_blocks.TranscriptBlockKind,
        bytes: []u8,
    ) !void {
        errdefer alloc.free(bytes);
        try self.owned_overrides.append(alloc, .{
            .entry_index = entry_index,
            .bytes = bytes,
        });
        self.entry_actions.items[entry_index] = .{ .override = .{
            .kind = kind,
            .bytes = bytes,
        } };
    }

    fn setOwnedGroup(self: *Projection, alloc: std.mem.Allocator, index: usize, group: GroupBlock) !void {
        errdefer alloc.free(group.lines);
        try self.setOwnedOverride(alloc, index, .tool_status, group.bytes);
        self.owned_overrides.items[self.owned_overrides.items.len - 1].line_provenance = group.lines;
        self.entry_actions.items[index].override.line_provenance = group.lines;
    }
};

const OwnedOverride = struct {
    entry_index: usize,
    bytes: []u8,
    line_provenance: []const transcript_blocks.LineProvenance = &.{},
};

pub const SummaryStyle = struct {
    marker_style: []const u8 = "",
    text_style: []const u8 = "",
    reset_style: []const u8 = "",
};

const BuildStats = struct {
    detail_lookups: usize = 0,
};

const ProjectionMode = enum { compact, expanded };

const category_labels = [_][]const u8{
    "read",
    "list",
    "write",
    "edit",
    "open",
    "command",
    "subagent",
    "browser",
};
const command_category_index = 5;

const Summary = struct {
    total: usize = 0,
    categories: [category_labels.len]usize = @splat(0),
    failed: usize = 0,
    timed_out: usize = 0,
    denied: usize = 0,
    cancelled: usize = 0,
    completion_unreported: usize = 0,
    not_executed: usize = 0,
};

const PresentationGroup = struct {
    anchor_index: usize,
    status_indices: std.ArrayList(usize) = .empty,
    summary: Summary = .{},

    fn deinit(self: *PresentationGroup, alloc: std.mem.Allocator) void {
        self.status_indices.deinit(alloc);
        self.* = undefined;
    }
};

fn categoryIndex(kind: types.ToolActivityKind) ?usize {
    return switch (kind) {
        .read => 0,
        .list => 1,
        .write => 2,
        .edit => 3,
        .open => 4,
        .command => command_category_index,
        .subagent => 6,
        .ask => null,
    };
}

fn detailForEntry(
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    entry_id: u32,
    stats: ?*BuildStats,
) ?*const ToolDetailRecord {
    if (stats) |value| value.detail_lookups += 1;
    const index = detail_indices.get(entry_id) orelse return null;
    return &details[index];
}

fn toolStatusEntryId(entry: TranscriptEntry) ?u32 {
    return switch (entry) {
        .raw_bytes => |raw| if (raw.class == .tool_status) raw.id else null,
        else => null,
    };
}

fn skipSgrSequence(text: []const u8, index: *usize) bool {
    if (index.* + 2 > text.len or text[index.*] != 0x1b or text[index.* + 1] != '[') {
        return false;
    }
    var end = index.* + 2;
    while (end < text.len and (text[end] < 0x40 or text[end] > 0x7e)) : (end += 1) {}
    if (end == text.len or text[end] != 'm') return false;
    index.* = end + 1;
    return true;
}

fn rawStatusNamesAskTool(text: []const u8) bool {
    var index: usize = 0;
    while (skipSgrSequence(text, &index)) {}
    const label = "● ask_user_question";
    if (!std.mem.startsWith(u8, text[index..], label)) return false;
    index += label.len;
    while (skipSgrSequence(text, &index)) {}
    return std.mem.eql(u8, text[index..], "") or
        std.mem.eql(u8, text[index..], "\n") or
        std.mem.eql(u8, text[index..], "\r\n");
}

fn statusNamesAsk(entry: TranscriptEntry, detail: ?*const ToolDetailRecord) bool {
    if (detail) |record| {
        return record.activity_kind == .ask or
            std.mem.eql(u8, record.tool_name, "ask_user_question");
    }
    return switch (entry) {
        .raw_bytes => |raw| rawStatusNamesAskTool(raw.bytes),
        else => false,
    };
}

fn isAttachedEntry(entry: TranscriptEntry) bool {
    return switch (entry) {
        .raw_bytes => |raw| raw.class == .command_output or raw.class == .diff_block,
        else => false,
    };
}

fn isTransparentCompactEntry(entry: TranscriptEntry) bool {
    if (!transcript_blocks.isEntryVisibleInCompactPresentation(entry)) return true;
    return switch (entry) {
        .assistant_turn => |assistant| assistant.segments.text.items.len == 0,
        else => false,
    };
}

fn commandProcessFailed(record: *const ToolDetailRecord) bool {
    if (record.activity_kind != .command) return false;
    const presentation = record.command_process_presentation orelse return false;
    return switch (presentation) {
        .exit_code => |code| code != 0,
        .signal, .timed_out, .output_capture_failed => true,
    };
}

fn commandProcessTimedOut(record: *const ToolDetailRecord) bool {
    if (record.activity_kind != .command) return false;
    const presentation = record.command_process_presentation orelse return false;
    return presentation == .timed_out;
}

fn observeTool(summary: *Summary, detail: ?*const ToolDetailRecord) void {
    summary.total += 1;
    const record = detail orelse return;
    if (record.activity_kind) |kind| {
        if (categoryIndex(kind)) |index| summary.categories[index] += 1;
    }
    if (record.fallback_disposition) |disposition| {
        switch (disposition) {
            .completion_unreported => summary.completion_unreported += 1,
            .not_executed => summary.not_executed += 1,
        }
        return;
    }
    const process_failed = commandProcessFailed(record);
    const process_timed_out = commandProcessTimedOut(record);
    if (record.outcome) |outcome| {
        switch (outcome) {
            .completed => {
                if (process_timed_out)
                    summary.timed_out += 1
                else if (process_failed)
                    summary.failed += 1;
            },
            .failed => {
                if (process_timed_out)
                    summary.timed_out += 1
                else
                    summary.failed += 1;
            },
            .denied => summary.denied += 1,
            .cancelled => summary.cancelled += 1,
            .deferred => {},
        }
    }
}

fn appendSegment(writer: *std.Io.Writer, count: usize, label: []const u8) !void {
    if (count == 0) return;
    try writer.print(" · {d} {s}", .{ count, label });
}

fn normalizeCanonicalStatus(
    scratch: std.mem.Allocator,
    text: []const u8,
) !?[]const u8 {
    var index: usize = 0;
    while (skipSgrSequence(text, &index)) {}
    const markers = [_][]const u8{ "●", "■", "⊘", "↻" };
    const marker = for (markers) |candidate| {
        if (std.mem.startsWith(u8, text[index..], candidate)) break candidate;
    } else return null;
    index += marker.len;
    while (skipSgrSequence(text, &index)) {}
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}

    var out: std.Io.Writer.Allocating = .init(scratch);
    errdefer out.deinit();
    while (index < text.len) {
        if (skipSgrSequence(text, &index)) continue;
        const byte = text[index];
        if (byte == '\n' or byte == '\r') break;
        if (byte >= 0x20) try out.writer.writeByte(byte);
        index += 1;
    }
    const owned = try out.toOwnedSlice();
    var phrase = std.mem.trim(u8, owned, " \t");
    if (std.mem.endsWith(u8, phrase, cancellation_follow_up)) {
        phrase = std.mem.trimEnd(u8, phrase[0 .. phrase.len - cancellation_follow_up.len], " \t");
    }
    return if (phrase.len == 0) null else phrase;
}

fn normalizeStatusPhrase(
    scratch: std.mem.Allocator,
    text: []const u8,
) !?[]const u8 {
    if (try normalizeCanonicalStatus(scratch, text)) |phrase| return phrase;
    var out: std.Io.Writer.Allocating = .init(scratch);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < text.len) {
        if (skipSgrSequence(text, &index)) continue;
        const byte = text[index];
        if (byte == '\n' or byte == '\r') break;
        if (byte >= 0x20) try out.writer.writeByte(byte);
        index += 1;
    }
    const owned = try out.toOwnedSlice();
    const phrase = std.mem.trim(u8, owned, " \t");
    return if (phrase.len == 0) null else phrase;
}

fn subagentStatusContinuation(
    entry: TranscriptEntry,
    detail: ?*const ToolDetailRecord,
) ?[]const u8 {
    const record = detail orelse return null;
    if (record.activity_kind != .subagent) return null;
    const text = switch (entry) {
        .raw_bytes => |raw| raw.bytes,
        else => return null,
    };
    const newline = std.mem.findScalar(u8, text, '\n') orelse return null;
    const continuation = std.mem.trim(u8, text[newline + 1 ..], " \t\r\n");
    return if (continuation.len == 0) null else continuation;
}

fn clipSummary(
    alloc: std.mem.Allocator,
    text: []const u8,
    cols: u16,
) ![]u8 {
    if (display_width.visibleWidthIgnoringAnsi(text) <= cols) return try alloc.dupe(u8, text);
    if (cols == 0) return try alloc.dupe(u8, "");
    if (cols == 1) return try alloc.dupe(u8, "…");
    const prefix = display_width.prefixByWidthIgnoringAnsi(text, cols - 1);
    const clipped = try alloc.print("{s}…", .{prefix});
    // A cut inside a styled run can leave the final SGR open; close it so the
    // accent cannot bleed into whatever the terminal paints next.
    if (std.mem.find(u8, clipped, "\x1b") == null or std.mem.endsWith(u8, clipped, "\x1b[0m"))
        return clipped;
    defer alloc.free(clipped);
    return try alloc.print("{s}\x1b[0m", .{clipped});
}

const StatToken = struct {
    /// Index of the sign character.
    start: usize,
    added: bool,
};

/// Diff counts exist only on write_file/edit_file status lines; every other
/// phrase can end in a coincidental " +N" / "-N" (for example `head -80`).
fn entryShowsDiffStats(detail: ?*const ToolDetailRecord) bool {
    const record = detail orelse return false;
    return std.mem.eql(u8, record.tool_name, "write_file") or
        std.mem.eql(u8, record.tool_name, "edit_file");
}

/// Matches a trailing " +N" or " -N" diff count in a plain status phrase.
fn trailingStatToken(text: []const u8) ?StatToken {
    var index = text.len;
    while (index > 0 and std.ascii.isDigit(text[index - 1])) : (index -= 1) {}
    if (index == text.len) return null;
    if (index < 2) return null;
    const sign = text[index - 1];
    if (sign != '+' and sign != '-') return null;
    if (text[index - 2] != ' ') return null;
    return .{ .start = index - 1, .added = sign == '+' };
}

/// Re-applies the diff add/remove marker accents to the trailing "+N" / "-N"
/// counts of a normalized tool status phrase. Normalization strips SGR so
/// grouped lines stay uniform; the counts keep their green/red so file edits
/// stay scannable inside collapsed and expanded groups. `ambient_style` is
/// re-applied between the two counts so the " / " separator keeps the line's
/// surrounding style. Returns `text` unchanged when no diff count suffix is
/// present. Caller owns the returned slice.
fn accentTrailingDiffStats(
    alloc: std.mem.Allocator,
    text: []const u8,
    ambient_style: []const u8,
) ![]u8 {
    const added_style = ui_render.diff_added_marker_style;
    const removed_style = ui_render.diff_removed_marker_style;
    if (added_style.len == 0 and removed_style.len == 0) return try alloc.dupe(u8, text);
    const reset = "\x1b[0m";

    const last = trailingStatToken(text) orelse return try alloc.dupe(u8, text);
    if (!last.added and last.start >= 2 and text[last.start - 2] == '/') {
        const before_slash = std.mem.trimEnd(u8, text[0 .. last.start - 2], " ");
        if (trailingStatToken(before_slash)) |first| {
            if (first.added) {
                return try alloc.print("{s}{s}{s}{s}{s} / {s}{s}{s}", .{
                    before_slash[0..first.start],
                    added_style,
                    before_slash[first.start..],
                    reset,
                    ambient_style,
                    removed_style,
                    text[last.start..],
                    reset,
                });
            }
        }
    }
    const style = if (last.added) added_style else removed_style;
    if (style.len == 0) return try alloc.dupe(u8, text);
    return try alloc.print("{s}{s}{s}{s}", .{
        text[0..last.start],
        style,
        text[last.start..],
        reset,
    });
}

fn applySummaryStyle(
    alloc: std.mem.Allocator,
    text: []const u8,
    style: SummaryStyle,
) ![]u8 {
    if (style.marker_style.len == 0 and
        style.text_style.len == 0 and
        style.reset_style.len == 0)
    {
        return try alloc.dupe(u8, text);
    }

    const marker = "●";
    if (!std.mem.startsWith(u8, text, marker)) return try alloc.dupe(u8, text);
    var content_start = marker.len;
    const has_separator = content_start < text.len and text[content_start] == ' ';
    if (has_separator) content_start += 1;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(style.marker_style);
    try out.writer.writeAll(marker);
    try out.writer.writeAll(style.reset_style);
    if (content_start < text.len) {
        if (has_separator) try out.writer.writeByte(' ');
        try out.writer.writeAll(style.text_style);
        try out.writer.writeAll(text[content_start..]);
        try out.writer.writeAll(style.reset_style);
    }
    return try out.toOwnedSlice();
}

fn formatGroupHeader(
    alloc: std.mem.Allocator,
    summary: Summary,
    cols: u16,
    style: SummaryStyle,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("● {d} tool call{s}", .{
        summary.total,
        if (summary.total == 1) "" else "s",
    });
    var emitted: [category_labels.len]bool = @splat(false);
    for (0..category_labels.len) |_| {
        var next_index: ?usize = null;
        for (summary.categories, 0..) |count, index| {
            if (count == 0 or emitted[index]) continue;
            if (next_index == null or count > summary.categories[next_index.?]) {
                next_index = index;
            }
        }
        const index = next_index orelse break;
        emitted[index] = true;
        const count = summary.categories[index];
        const label = if (index == command_category_index and count != 1)
            "commands"
        else
            category_labels[index];
        try appendSegment(&out.writer, count, label);
    }
    try appendSegment(&out.writer, summary.completion_unreported, "unreported");
    try appendSegment(&out.writer, summary.not_executed, "not executed");
    try appendSegment(&out.writer, summary.timed_out, "timed out");
    try appendSegment(&out.writer, summary.failed, "failed");
    try appendSegment(&out.writer, summary.denied, "denied");
    try appendSegment(&out.writer, summary.cancelled, "cancelled");

    const plain = try out.toOwnedSlice();
    defer alloc.free(plain);
    const clipped = try clipSummary(alloc, plain, cols);
    defer alloc.free(clipped);
    return applySummaryStyle(alloc, clipped, style);
}

const GroupBlock = struct { bytes: []u8, lines: []const transcript_blocks.LineProvenance };

fn formatGroupBlock(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    status_indices: []const usize,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    summary: Summary,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    cols: u16,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
) !GroupBlock {
    const header = try formatGroupHeader(alloc, summary, cols, style);
    defer alloc.free(header);
    var lines: std.ArrayList(transcript_blocks.LineProvenance) = .empty;
    errdefer lines.deinit(alloc);
    try lines.append(alloc, .{ .entry = .{ .entry_id = entries[status_indices[0]].id(), .entry_class = .tool_status, .projection_part = .group_header } });
    if (collapse_tool_calls) {
        const bytes = try alloc.dupe(u8, header);
        errdefer alloc.free(bytes);
        return .{ .bytes = bytes, .lines = try lines.toOwnedSlice(alloc) };
    }

    var focused_in_group = false;
    var static_count: usize = 0;
    for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        if (statusNamesAsk(entry, detail)) continue;
        if (focused_entry_id == entry_id) {
            focused_in_group = true;
        } else {
            static_count += 1;
        }
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(header);

    var static_index: usize = 0;
    for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        if (statusNamesAsk(entry, detail) or focused_entry_id == entry_id) continue;

        const raw_phrase = switch (entry) {
            .raw_bytes => |raw| try normalizeCanonicalStatus(scratch, raw.bytes),
            else => null,
        } orelse if (detail) |record| record.tool_name else "tool activity";
        const phrase = try reprojectTruncatedCommandPhrase(
            scratch,
            raw_phrase,
            detail,
        ) orelse raw_phrase;
        const display_phrase = try highlightCommandPhrase(scratch, phrase, detail, style.text_style) orelse phrase;
        static_index += 1;
        const last_static_row = !focused_in_group and static_index == static_count;
        const connector = if (last_static_row) "└" else "├";
        const child = try scratch.print("{s} {s}", .{ connector, display_phrase });
        const clipped = try clipSummary(scratch, child, cols);
        try lines.append(alloc, .{ .entry = .{ .entry_id = entry_id, .entry_class = .tool_status, .projection_part = .group_child } });
        const accented = if (entryShowsDiffStats(detail))
            try accentTrailingDiffStats(scratch, clipped, style.text_style)
        else
            clipped;
        try out.writer.writeByte('\n');
        if (style.text_style.len > 0) try out.writer.writeAll(style.text_style);
        try out.writer.writeAll(accented);
        if (style.text_style.len > 0) try out.writer.writeAll(style.reset_style);
        if (subagentStatusContinuation(entry, detail)) |continuation| {
            const continuation_row = try scratch.print(
                "{s}{s}",
                .{ if (last_static_row) "  " else "│ ", continuation },
            );
            const clipped_continuation = try clipSummary(scratch, continuation_row, cols);
            try lines.append(alloc, .{ .entry = .{ .entry_id = entry_id, .entry_class = .tool_status, .projection_part = .group_child } });
            try out.writer.writeByte('\n');
            if (style.text_style.len > 0) try out.writer.writeAll(style.text_style);
            try out.writer.writeAll(clipped_continuation);
            if (style.text_style.len > 0) try out.writer.writeAll(style.reset_style);
        }
    }

    for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null) orelse continue;
        if (detail.outcome != .cancelled) continue;

        const terminal = try transcript_blocks.renderEntryToBlock(scratch, entry, cols, styles);
        if (terminal.bytes.len > 0) {
            try lines.append(alloc, .block_separator);
            const count = std.mem.count(u8, std.mem.trimEnd(u8, terminal.bytes, "\n"), "\n") + 1;
            try lines.appendNTimes(alloc, .{ .entry = .{ .entry_id = entry_id, .entry_class = .tool_status, .projection_part = .group_cancel } }, count);
            try out.writer.writeAll("\n\n");
            try out.writer.writeAll(terminal.bytes);
        }
        terminal.deinit(scratch);
    }
    const bytes = try out.toOwnedSlice();
    errdefer alloc.free(bytes);
    return .{ .bytes = bytes, .lines = try lines.toOwnedSlice(alloc) };
}

/// The minimum tail length accepted as an identity match in
/// reprojectTruncatedCommandPhrase. Genuinely truncated command phrases carry
/// roughly 116 bytes of command prefix (the compact activity bound), so a long
/// threshold cannot reject a real row; it exists to stop a short coincidental
/// tail from rewriting an unrelated one.
const min_reclip_tail_bytes = 16;

/// Returns the longest suffix of `text` that is also a prefix of `base`, when
/// it is long enough to prove the two share a command. O(n^2) over a frozen
/// phrase of at most ~120 bytes; the loop count is bounded and tiny.
fn commandTailMatch(text: []const u8, base: []const u8) ?[]const u8 {
    var len: usize = @min(text.len, base.len);
    while (len >= min_reclip_tail_bytes) : (len -= 1) {
        const tail = text[text.len - len ..];
        if (std.mem.startsWith(u8, base, tail)) return tail;
    }
    return null;
}

/// Substitutes the stored full command for a status phrase that was truncated
/// to the compact activity bound at generation time. Records carry the full
/// display whenever the command is known — captured runs, tty runs, and
/// terminal-session actions — so the phrase can be reclipped to the live
/// terminal width instead of keeping the frozen "..." marker.
///
/// The row's own leading label is preserved ("Running", "Ran", "Exited 1"):
/// the stored action label is a start-time prediction that cannot know the
/// settled outcome, and an active row must never be rewritten to the
/// completed label. Identity is proven by the command itself — the frozen
/// tail is a generation-time prefix of the stored display — which is a
/// stronger guard than comparing the predicted label against the row.
fn reprojectTruncatedCommandPhrase(
    scratch: std.mem.Allocator,
    phrase: []const u8,
    detail: ?*const ToolDetailRecord,
) !?[]const u8 {
    const record = detail orelse return null;
    if (!std.mem.endsWith(u8, phrase, "...")) return null;
    const command = record.command_display orelse return null;
    if (command.len == 0) return null;
    const body = phrase[0 .. phrase.len - "...".len];
    const tail = commandTailMatch(body, command) orelse return null;
    const label = body[0 .. body.len - tail.len];
    if (label.len == 0 or label[label.len - 1] != ' ') return null;
    return try scratch.print("{s}{s}", .{ label, command });
}

/// Shell-highlight the command portion of a command phrase ("Running <cmd>",
/// "Ran <cmd>"). The leading action word and connector stay in the row's
/// ambient style; only the command's syntax tokens pick up palette colors.
/// `base_style` (the row's text style, when any) is re-established after every
/// token close so untokenized text keeps the row's color.
/// Multi-word status labels that can lead a command row when no label was
/// recorded. Mirrors the terminal-outcome labels composed in
/// tool_admission.permissionDeniedStatusLabel and the lifecycle rows.
const known_multiword_labels = [_][]const u8{
    "Denied by auto agent",
    "Review evidence incomplete",
    "Permission required",
    "Safety caution",
    "Review unavailable",
    "Timed out",
};

fn knownLabelPrefix(phrase: []const u8) ?usize {
    for (known_multiword_labels) |label| {
        if (std.mem.startsWith(u8, phrase, label) and phrase.len > label.len and phrase[label.len] == ' ')
            return label.len;
    }
    return null;
}

fn highlightCommandPhrase(
    scratch: std.mem.Allocator,
    phrase: []const u8,
    detail: ?*const ToolDetailRecord,
    base_style: []const u8,
) !?[]const u8 {
    const record = detail orelse return null;
    if (record.activity_kind != .command) return null;
    // Prefer the recorded action label so multi-word labels ("Timed out")
    // split at the true boundary. Otherwise trust the stored command text:
    // prose-prefixed rows ("Reading project instructions before continuing:
    // <cmd>") end with it. Then known multi-word labels, then first space.
    const label_end = if (record.command_action_label) |action|
        if (std.mem.startsWith(u8, phrase, action) and phrase.len > action.len and phrase[action.len] == ' ')
            action.len
        else
            null
    else
        null;
    const display_end = if (record.command_display) |display| blk: {
        if (display.len == 0 or phrase.len <= display.len + 1) break :blk null;
        if (!std.mem.endsWith(u8, phrase, display)) break :blk null;
        const split_at = phrase.len - display.len - 1;
        break :blk if (phrase[split_at] == ' ') split_at else null;
    } else null;
    const split = label_end orelse display_end orelse knownLabelPrefix(phrase) orelse std.mem.findScalar(u8, phrase, ' ') orelse return null;
    const command = phrase[split + 1 ..];
    if (command.len == 0) return null;
    const theme = shared_theme.current();
    const profile = code_highlight_languages.resolve("sh") orelse return null;
    const variant: code_highlight.Theme = if (theme.light) .light else .dark;
    // Commands without tokens keep their exact plain bytes.
    const plain = try code_highlight.highlight(scratch, command, profile, variant, null);
    if (std.mem.eql(u8, plain, command)) return null;
    const highlighted = try code_highlight.highlight(
        scratch,
        command,
        profile,
        variant,
        if (base_style.len > 0) base_style else null,
    );
    return try scratch.print("{s} {s}", .{ phrase[0..split], highlighted });
}

fn formatExpandedChild(
    alloc: std.mem.Allocator,
    entry: TranscriptEntry,
    detail: ?*const ToolDetailRecord,
    connector: []const u8,
    cols: u16,
) ![]u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();
    const raw_phrase = switch (entry) {
        .raw_bytes => |raw| try normalizeStatusPhrase(scratch, raw.bytes),
        else => null,
    } orelse if (detail) |record| record.tool_name else "tool activity";
    const phrase = try reprojectTruncatedCommandPhrase(
        scratch,
        raw_phrase,
        detail,
    ) orelse raw_phrase;
    // Expanded rows carry no ambient text style, so tokens highlight over the
    // terminal default foreground.
    const display_phrase = try highlightCommandPhrase(scratch, phrase, detail, "") orelse phrase;
    const child = try scratch.print("{s} {s}", .{ connector, display_phrase });
    const clipped = try clipSummary(scratch, child, cols);
    const accented = if (entryShowsDiffStats(detail))
        try accentTrailingDiffStats(scratch, clipped, "")
    else
        clipped;
    const continuation = subagentStatusContinuation(entry, detail) orelse return alloc.dupe(u8, accented);
    const continuation_row = try scratch.print(
        "{s}{s}",
        .{ if (std.mem.eql(u8, connector, "└")) "  " else "│ ", continuation },
    );
    return alloc.print("{s}\n{s}", .{ accented, try clipSummary(scratch, continuation_row, cols) });
}

fn installExpandedGroup(
    alloc: std.mem.Allocator,
    projection: *Projection,
    entries: []const TranscriptEntry,
    status_indices: []const usize,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    summary: Summary,
    cols: u16,
    style: SummaryStyle,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !void {
    const header = try formatGroupHeader(alloc, summary, cols, style);
    defer alloc.free(header);
    for (status_indices, 0..) |status_index, child_index| {
        try build_checkpoint.tick(checkpoint);
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        const connector = if (child_index + 1 == status_indices.len) "└" else "├";
        const child = try formatExpandedChild(alloc, entry, detail, connector, cols);
        defer alloc.free(child);
        const bytes = if (child_index == 0)
            try alloc.print("{s}\n{s}", .{ header, child })
        else
            try alloc.dupe(u8, child);
        try projection.setOwnedOverride(alloc, status_index, .tool_status, bytes);
    }
}

fn presentationGroupId(
    detail: ?*const ToolDetailRecord,
) ?types.ToolPresentationGroupId {
    const record = detail orelse return null;
    return record.presentation_group_id;
}

fn statusIndexLessThan(
    entries: []const TranscriptEntry,
    lhs: usize,
    rhs: usize,
) bool {
    return toolStatusEntryId(entries[lhs]).? < toolStatusEntryId(entries[rhs]).?;
}

fn hideAttachedRows(
    entries: []const TranscriptEntry,
    entry_actions: []transcript_blocks.EntryRenderAction,
    status_index: usize,
) void {
    var index = status_index + 1;
    while (index < entries.len) : (index += 1) {
        if (toolStatusEntryId(entries[index]) != null) break;
        if (isAttachedEntry(entries[index])) {
            entry_actions[index] = .hide;
            continue;
        }
        if (!isTransparentCompactEntry(entries[index])) break;
    }
}

pub fn buildExpandedStyledInterruptible(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    return buildWithStyleAndStats(alloc, entries, details, cols, null, false, style, styles, .expanded, null, checkpoint);
}

pub fn buildStyledFocusedInterruptible(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    return buildWithStyleAndStats(
        alloc,
        entries,
        details,
        cols,
        focused_entry_id,
        collapse_tool_calls,
        style,
        styles,
        .compact,
        null,
        checkpoint,
    );
}

fn buildWithStyleAndStats(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
    mode: ProjectionMode,
    stats: ?*BuildStats,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    var projection: Projection = .{};
    errdefer projection.deinit(alloc);
    try projection.entry_actions.appendNTimes(alloc, .keep, entries.len);
    if (mode == .compact) {
        for (entries, projection.entry_actions.items) |entry, *action| {
            switch (entry) {
                .raw_bytes => |raw| if (raw.class == .command_output) {
                    action.* = .hide;
                },
                else => {},
            }
        }
    }

    var detail_indices: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer detail_indices.deinit(alloc);
    for (details, 0..) |detail, detail_index| {
        try build_checkpoint.tick(checkpoint);
        const result = try detail_indices.getOrPut(alloc, detail.entry_id);
        if (!result.found_existing) result.value_ptr.* = detail_index;
    }

    const presentation_group_indices = try alloc.alloc(?usize, entries.len);
    defer alloc.free(presentation_group_indices);
    @memset(presentation_group_indices, null);

    var presentation_groups: std.ArrayList(PresentationGroup) = .empty;
    defer {
        for (presentation_groups.items) |*group| group.deinit(alloc);
        presentation_groups.deinit(alloc);
    }
    var presentation_group_by_id: std.AutoHashMapUnmanaged(
        types.ToolPresentationGroupId,
        usize,
    ) = .empty;
    defer presentation_group_by_id.deinit(alloc);

    for (entries, 0..) |entry, entry_index| {
        try build_checkpoint.tick(checkpoint);
        if (mode == .compact and !transcript_blocks.isEntryVisibleInCompactPresentation(entry)) continue;
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, &detail_indices, entry_id, stats);
        if (statusNamesAsk(entry, detail)) continue;
        const group_id = presentationGroupId(detail) orelse continue;

        const result = try presentation_group_by_id.getOrPut(alloc, group_id);
        if (!result.found_existing) {
            result.value_ptr.* = presentation_groups.items.len;
            try presentation_groups.append(alloc, .{ .anchor_index = entry_index });
        }
        const group_index = result.value_ptr.*;
        const group = &presentation_groups.items[group_index];
        try group.status_indices.append(alloc, entry_index);
        observeTool(&group.summary, detail);
        presentation_group_indices[entry_index] = group_index;
    }
    for (presentation_groups.items) |*group| {
        try build_checkpoint.tick(checkpoint);
        sort_utils.sort(
            usize,
            group.status_indices.items,
            entries,
            statusIndexLessThan,
        );
    }

    if (mode == .expanded) {
        for (presentation_groups.items) |*group| {
            try build_checkpoint.tick(checkpoint);
            try installExpandedGroup(
                alloc,
                &projection,
                entries,
                group.status_indices.items,
                details,
                &detail_indices,
                group.summary,
                cols,
                style,
                checkpoint,
            );
        }

        var expanded_index: usize = 0;
        while (expanded_index < entries.len) {
            try build_checkpoint.tick(checkpoint);
            if (presentation_group_indices[expanded_index] != null) {
                expanded_index += 1;
                continue;
            }
            const entry_id = toolStatusEntryId(entries[expanded_index]) orelse {
                expanded_index += 1;
                continue;
            };
            const detail = detailForEntry(details, &detail_indices, entry_id, stats);
            if (statusNamesAsk(entries[expanded_index], detail)) {
                expanded_index += 1;
                continue;
            }

            var status_indices: std.ArrayList(usize) = .empty;
            defer status_indices.deinit(alloc);
            var summary: Summary = .{};
            while (expanded_index < entries.len) : (expanded_index += 1) {
                try build_checkpoint.tick(checkpoint);
                if (presentation_group_indices[expanded_index] != null) break;
                if (toolStatusEntryId(entries[expanded_index])) |group_entry_id| {
                    const group_detail = detailForEntry(details, &detail_indices, group_entry_id, stats);
                    if (statusNamesAsk(entries[expanded_index], group_detail)) break;
                    observeTool(&summary, group_detail);
                    try status_indices.append(alloc, expanded_index);
                    continue;
                }
                if (!isAttachedEntry(entries[expanded_index]) and
                    !isTransparentCompactEntry(entries[expanded_index])) break;
            }
            try installExpandedGroup(
                alloc,
                &projection,
                entries,
                status_indices.items,
                details,
                &detail_indices,
                summary,
                cols,
                style,
                checkpoint,
            );
        }
        return projection;
    }

    var index: usize = 0;
    while (index < entries.len) {
        try build_checkpoint.tick(checkpoint);
        // Hidden entries keep their action, but grouping below skips them, so
        // they must not anchor a group either.
        if (projection.entry_actions.items[index] != .keep or
            !transcript_blocks.isEntryVisibleInCompactPresentation(entries[index]))
        {
            index += 1;
            continue;
        }
        const entry_id = toolStatusEntryId(entries[index]) orelse {
            index += 1;
            continue;
        };

        if (presentation_group_indices[index]) |group_index| {
            const group = &presentation_groups.items[group_index];
            if (index != group.anchor_index) {
                projection.entry_actions.items[index] = .hide;
                index += 1;
                continue;
            }
            for (group.status_indices.items) |status_index| {
                projection.entry_actions.items[status_index] = .hide;
                hideAttachedRows(
                    entries,
                    projection.entry_actions.items,
                    status_index,
                );
            }

            const bytes = try formatGroupBlock(
                alloc,
                entries,
                group.status_indices.items,
                details,
                &detail_indices,
                group.summary,
                focused_entry_id,
                collapse_tool_calls,
                cols,
                style,
                styles,
            );
            try projection.setOwnedGroup(alloc, index, bytes);
            index += 1;
            continue;
        }

        const detail = detailForEntry(details, &detail_indices, entry_id, stats);
        if (statusNamesAsk(entries[index], detail)) {
            index += 1;
            continue;
        }

        const first_index = index;
        var status_indices: std.ArrayList(usize) = .empty;
        defer status_indices.deinit(alloc);
        var summary: Summary = .{};

        while (index < entries.len) : (index += 1) {
            try build_checkpoint.tick(checkpoint);
            if (!transcript_blocks.isEntryVisibleInCompactPresentation(entries[index])) continue;
            if (presentation_group_indices[index] != null) break;
            if (toolStatusEntryId(entries[index])) |group_entry_id| {
                const group_detail = detailForEntry(details, &detail_indices, group_entry_id, stats);
                if (statusNamesAsk(entries[index], group_detail)) break;
                observeTool(&summary, group_detail);
                try status_indices.append(alloc, index);
                projection.entry_actions.items[index] = .hide;
                continue;
            }
            if (isAttachedEntry(entries[index])) {
                projection.entry_actions.items[index] = .hide;
                continue;
            }
            if (!isTransparentCompactEntry(entries[index])) break;
        }

        const bytes = try formatGroupBlock(
            alloc,
            entries,
            status_indices.items,
            details,
            &detail_indices,
            summary,
            focused_entry_id,
            collapse_tool_calls,
            cols,
            style,
            styles,
        );
        try projection.setOwnedGroup(alloc, first_index, bytes);
    }

    return projection;
}

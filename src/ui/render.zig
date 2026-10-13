const std = @import("std");
const build_options = @import("build_options");
const io_mod = @import("../core/shared/io.zig");
const host = @import("../core/hosts/host.zig");
const display_width = @import("../core/shared/display_width.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const types = @import("../core/shared/types.zig");
const assistant_presentation = @import("../core/agent/assistant_presentation.zig");
const main = @import("../main.zig");
const theme_detection = @import("terminal/theme_detection.zig");
const theme_protocol = @import("terminal/theme_protocol.zig");
const shared_theme = @import("../core/shared/theme.zig");
const update_target = @import("../core/upgrade/update_target.zig");

pub const TerminalRgb = user_message_card.Rgb;
pub const reset_style = "\x1b[0m";
pub const bold_style = "\x1b[1m";
pub const ask_activity_label = "⏺ Asking";

const user_message_card = @import("assistant/user_message_card.zig");

pub const welcome_message_reserved_rows: u16 = 11;

pub var is_light: bool = false;
pub var divider_style: []const u8 = shared_theme.fx_dark.divider_style;
pub var hint_style: []const u8 = shared_theme.fx_dark.hint_style;
pub var statusline_style: []const u8 = shared_theme.fx_dark.statusline_style;
pub var tag_style: []const u8 = shared_theme.fx_dark.tag_style;
pub var subtitle_style: []const u8 = shared_theme.fx_dark.subtitle_style;
pub var system_notice_label_style: []const u8 = shared_theme.fx_dark.system_notice_label_style;
pub var system_notice_text_style: []const u8 = shared_theme.fx_dark.system_notice_text_style;
pub var dim_style: []const u8 = shared_theme.fx_dark.dim_style;
pub var warning_style: []const u8 = shared_theme.fx_dark.warning_style;
pub var green_style: []const u8 = shared_theme.fx_dark.green_style;
pub var red_style: []const u8 = shared_theme.fx_dark.red_style;
pub var diff_added_style: []const u8 = shared_theme.fx_dark.diff_added_style;
pub var diff_removed_style: []const u8 = shared_theme.fx_dark.diff_removed_style;
pub var diff_added_marker_style: []const u8 = "";
pub var diff_removed_marker_style: []const u8 = "";
pub var approval_button_active_style: []const u8 = shared_theme.fx_dark.approval_button_active_style;
pub var approval_button_inactive_style: []const u8 = shared_theme.fx_dark.approval_button_inactive_style;
pub var selected_completion_style: []const u8 = shared_theme.fx_dark.selected_completion_style;
// Statusbar permissions "auto": a step brighter than the statusline gray.
pub var permission_auto_style: []const u8 = shared_theme.fx_dark.permission_auto_style;
var active_terminal_background: ?TerminalRgb = null;

var truecolor_enabled: bool = true;

pub fn setTruecolorSupport(enabled: bool) void {
    truecolor_enabled = enabled;
}

// A configured light|dark pin (FX_THEME or the settings "theme" key) locks the
// variant. Custom themes keep the live monitor so terminal mode flips
// re-resolve the theme pair without a restart.
pub fn themeInputLocked() bool {
    return explicitThemeOverride() != null or shared_theme.variantPinned();
}

pub fn truecolorIsEnabled() bool {
    return truecolor_enabled;
}

pub fn initTheme(light: bool, terminal_bg: ?TerminalRgb) void {
    applyTheme(shared_theme.builtin(light), terminal_bg);
}

pub fn applyTheme(theme: shared_theme.Theme, terminal_bg: ?TerminalRgb) void {
    shared_theme.activate(theme);
    is_light = theme.light;
    active_terminal_background = terminal_bg;
    assistant_presentation.applyTheme(theme);
    divider_style = theme.divider_style;
    hint_style = theme.hint_style;
    statusline_style = theme.statusline_style;
    tag_style = theme.tag_style;
    subtitle_style = theme.subtitle_style;
    system_notice_label_style = theme.system_notice_label_style;
    system_notice_text_style = theme.system_notice_text_style;
    dim_style = theme.dim_style;
    warning_style = theme.warning_style;
    green_style = theme.green_style;
    red_style = theme.red_style;
    diff_added_style = theme.diff_added_style;
    diff_removed_style = theme.diff_removed_style;
    approval_button_active_style = theme.approval_button_active_style;
    approval_button_inactive_style = theme.approval_button_inactive_style;
    selected_completion_style = theme.selected_completion_style;
    permission_auto_style = theme.permission_auto_style;

    // Terminal-following defaults keep diff markers monochrome. An explicit
    // light/dark pin or named theme enables its green/red marker colors.
    const theme_selected = shared_theme.variantPinned() or shared_theme.sourceName() != null;
    if (!theme_selected) {
        diff_added_marker_style = "";
        diff_removed_marker_style = "";
    } else if (truecolor_enabled) {
        diff_added_marker_style = theme.diff_added_marker_truecolor;
        diff_removed_marker_style = theme.diff_removed_marker_truecolor;
    } else {
        diff_added_marker_style = theme.diff_added_marker_fallback;
        diff_removed_marker_style = theme.diff_removed_marker_fallback;
    }

    user_message_card.applyTheme(theme, terminal_bg);
}

pub fn themeNeedsUpdate(light: bool, terminal_bg: ?TerminalRgb) bool {
    if (light != is_light) return true;
    const background = terminal_bg orelse return false;
    const current = active_terminal_background orelse return true;
    return current.r != background.r or current.g != background.g or current.b != background.b;
}

// Explicit theme overrides skip OSC 11, leaving `rgb` null for fallback shading.
pub const explicitThemeOverride = theme_detection.explicitThemeOverride;
pub const explicitThemeName = theme_detection.explicitThemeName;
pub const detectTheme = theme_detection.detectTheme;
pub const parseOsc11Response = theme_protocol.parseOsc11Response;
pub const truecolorSupportedForValues = theme_protocol.truecolorSupportedForValues;

const build_channel = update_target.Channel.parse(build_options.update_channel) orelse .stable;
const welcome_build_label_bytes: usize = 96;
const dev_revision_bytes: usize = 7;

/// Dev builds ship on every merged PR, so the version alone cannot identify the
/// binary: the header carries the commit and a brighter `[dev]` tag.
fn writeBuildLabel(
    out: []u8,
    channel: update_target.Channel,
    version_text: []const u8,
    revision: []const u8,
) ![]const u8 {
    if (channel != .dev) return std.mem.print(out, "v{s}", .{version_text});
    if (revision.len < dev_revision_bytes or std.mem.eql(u8, revision, "unknown")) {
        return std.mem.print(out, "v{s} {s}[dev]{s}", .{ version_text, hint_style, dim_style });
    }
    return std.mem.print(out, "v{s}-{s} {s}[dev]{s}", .{
        version_text,
        revision[0..dev_revision_bytes],
        hint_style,
        dim_style,
    });
}

pub fn welcomeMessage(alloc: std.mem.Allocator) ![]u8 {
    var label_buf: [welcome_build_label_bytes]u8 = undefined;
    const build_label = try writeBuildLabel(
        &label_buf,
        build_channel,
        main.version,
        build_options.git_commit,
    );
    return alloc.print(
        "{s}𝒇x{s}{s} {s} · Run /help for commands" ++ reset_style ++ "\n\n",
        .{ subtitle_style, reset_style, dim_style, build_label },
    );
}

pub const StatuslineItems = struct {
    workspace_label: []const u8 = "",
    git_branch: ?[]const u8 = null,
    context_used: u64 = 0,
    context_total: ?u32 = null,
    session_title: ?[]const u8 = null,
};

/// Cell budget for the session title segment. The title is capped at 8 words
/// upstream, so this only bounds pathological single-word titles.
const max_session_title_cells: usize = 32;

fn compactModelLabel(model: []const u8, out: []u8) []const u8 {
    var start: usize = 0;
    for (model, 0..) |byte, i| {
        if (byte == '/') start = i + 1;
    }
    const bare = model[start..];

    const claude_prefix = "claude-";
    if (!std.mem.startsWith(u8, bare, claude_prefix)) return bare;
    const claude_name = bare[claude_prefix.len..];

    inline for (&.{
        .{ "opus-", "opus " },
        .{ "sonnet-", "sonnet " },
        .{ "haiku-", "haiku " },
    }) |mapping| {
        const prefix = mapping[0];
        const label = mapping[1];
        if (std.mem.startsWith(u8, claude_name, prefix)) {
            return std.mem.print(out, "{s}{s}", .{ label, claude_name[prefix.len..] }) catch bare;
        }
    }

    return claude_name;
}

fn permissionModeStatusLabel(mode: types.PermissionMode, out: []u8) []const u8 {
    return switch (mode) {
        .ask => "ask",
        .auto => std.mem.print(out, "{s}auto{s}", .{ permission_auto_style, statusline_style }) catch "auto",
        .yolo => std.mem.print(out, "{s}full access{s}", .{ permission_auto_style, statusline_style }) catch "full access",
    };
}

fn appendStatusSegment(out: []u8, end: *usize, segment: []const u8) void {
    if (segment.len == 0) return;
    const sep = " · ";
    const sep_len = if (end.* > 0) sep.len else 0;
    if (end.* + sep_len + segment.len > out.len) return;

    if (sep_len > 0) {
        @memcpy(out[end.* .. end.* + sep.len], sep);
        end.* += sep.len;
    }
    @memcpy(out[end.* .. end.* + segment.len], segment);
    end.* += segment.len;
}

const statusline_separator = " · ";

fn leadingPermissionModeFits(
    limit: usize,
    permission_label: []const u8,
    model_label: []const u8,
) bool {
    if (limit == 0) return false;
    return display_width.visibleWidthIgnoringAnsi(permission_label) +
        display_width.visibleWidth(statusline_separator) +
        display_width.visibleWidth(model_label) <= limit;
}

const ClippedSegment = struct {
    bytes: []const u8,
    marker_before: bool = false,
    marker_after: bool = false,
};

fn clippedWorkspaceSuffix(encoded: []const u8, max_width: usize) ClippedSegment {
    if (display_width.visibleWidth(encoded) <= max_width) return .{ .bytes = encoded };
    if (max_width <= 1) return .{ .bytes = "", .marker_before = max_width == 1 };
    return .{
        .bytes = text_utils.suffixTerminalSafeByWidth(encoded, max_width - 1),
        .marker_before = true,
    };
}

fn clippedBranchPrefix(encoded: []const u8, max_width: usize) ClippedSegment {
    if (display_width.visibleWidth(encoded) <= max_width) return .{ .bytes = encoded };
    if (max_width <= 1) return .{ .bytes = "", .marker_after = max_width == 1 };
    return .{
        .bytes = text_utils.prefixTerminalSafeByWidth(encoded, max_width - 1),
        .marker_after = true,
    };
}

fn appendIdentityBytes(out: []u8, end: *usize, bytes: []const u8) bool {
    if (end.* + bytes.len > out.len) return false;
    @memcpy(out[end.* .. end.* + bytes.len], bytes);
    end.* += bytes.len;
    return true;
}

fn appendClippedIdentityPart(
    out: []u8,
    end: *usize,
    clipped: ClippedSegment,
) bool {
    if (clipped.marker_before and !appendIdentityBytes(out, end, "…")) return false;
    if (!appendIdentityBytes(out, end, clipped.bytes)) return false;
    if (clipped.marker_after and !appendIdentityBytes(out, end, "…")) return false;
    return true;
}

fn composeWorkspaceIdentity(
    statusline: StatuslineItems,
    max_width: usize,
    out: []u8,
) ?[]const u8 {
    if (statusline.workspace_label.len == 0 or max_width == 0) return null;

    var width_budget = @min(max_width, out.len);
    while (width_budget > 0) : (width_budget -= 1) {
        var end: usize = 0;
        if (statusline.git_branch) |branch| {
            if (branch.len > 0) {
                // Below seven cells, showing fragments of both values is less
                // useful than retaining the working-directory tail alone.
                if (width_budget >= 7) {
                    const branch_width = display_width.visibleWidth(branch);
                    const max_branch_width = width_budget - 4;
                    const branch_budget = @min(
                        branch_width,
                        @min(max_branch_width, @max(@as(usize, 4), width_budget / 2)),
                    );
                    const path_budget = width_budget - 3 - branch_budget;
                    const path = clippedWorkspaceSuffix(statusline.workspace_label, path_budget);
                    const branch_label = clippedBranchPrefix(branch, branch_budget);
                    if (appendClippedIdentityPart(out, &end, path) and
                        appendIdentityBytes(out, &end, " (") and
                        appendClippedIdentityPart(out, &end, branch_label) and
                        appendIdentityBytes(out, &end, ")"))
                    {
                        return out[0..end];
                    }
                    continue;
                }
            }
        }

        const path = clippedWorkspaceSuffix(statusline.workspace_label, width_budget);
        if (appendClippedIdentityPart(out, &end, path)) return out[0..end];
    }
    return null;
}

fn appendWorkspaceIdentity(
    out: []u8,
    end: *usize,
    status_limit: usize,
    statusline: StatuslineItems,
) void {
    if (statusline.workspace_label.len == 0) return;
    const used_width = display_width.visibleWidthIgnoringAnsi(out[0..end.*]);
    const separator_width = if (end.* > 0)
        display_width.visibleWidth(statusline_separator)
    else
        0;
    if (used_width + separator_width >= status_limit) return;

    const separator_bytes = if (end.* > 0) statusline_separator.len else 0;
    if (end.* + separator_bytes >= out.len) return;
    const available_width = status_limit - used_width - separator_width;
    const available_bytes = out.len - end.* - separator_bytes;
    var identity_buf: [512]u8 = undefined;
    const identity = composeWorkspaceIdentity(
        statusline,
        available_width,
        identity_buf[0..@min(identity_buf.len, available_bytes)],
    ) orelse return;
    appendStatusSegment(out, end, identity);
}

fn appendSessionStatusSegments(
    out: []u8,
    end: *usize,
    status_limit: usize,
    model: []const u8,
    effort: types.ReasoningEffort,
    model_supports_effort: bool,
    fast_indicator_active: bool,
    statusline: StatuslineItems,
) void {
    var model_buf: [96]u8 = undefined;
    appendStatusSegment(out, end, compactModelLabel(model, &model_buf));
    if (model_supports_effort and !effort.isDefault()) {
        appendStatusSegment(out, end, effort.displayLabel());
    }
    if (fast_indicator_active) {
        appendStatusSegment(out, end, "⚡︎");
    }
    if (statusline.session_title) |title| {
        appendStatusSegment(out, end, display_width.prefixByWidth(title, max_session_title_cells));
    }
    if (statusline.context_used > 0) {
        if (statusline.context_total) |total| {
            const used_k = statusline.context_used / 1000;
            const total_k: u64 = @as(u64, total) / 1000;
            const pct = if (total > 0) (statusline.context_used * 100) / @as(u64, total) else 0;
            var ctx_buf: [48]u8 = undefined;
            appendStatusSegment(out, end, std.mem.print(&ctx_buf, "{d}k/{d}k {d}%", .{ used_k, total_k, pct }) catch "");
        } else {
            const used_k = statusline.context_used / 1000;
            var ctx_buf: [32]u8 = undefined;
            appendStatusSegment(out, end, std.mem.print(&ctx_buf, "{d}k", .{used_k}) catch "");
        }
    }
    appendWorkspaceIdentity(out, end, status_limit, statusline);
}

pub const subagent_status_width: u16 = 200;

pub fn buildSessionStatusLine(
    model: []const u8,
    effort: types.ReasoningEffort,
    model_supports_effort: bool,
    statusline: StatuslineItems,
    width: u16,
    out: []u8,
) []const u8 {
    var end: usize = 0;
    const status_limit = @min(@as(usize, width), out.len);
    appendSessionStatusSegments(out, &end, status_limit, model, effort, model_supports_effort, false, statusline);
    if (width == 0) return "";
    return display_width.prefixByWidthIgnoringAnsi(out[0..end], width);
}

pub fn buildHintLine(
    awaiting_permission: bool,
    has_api_key: bool,
    model: []const u8,
    permission_mode: types.PermissionMode,
    fast_indicator_active: bool,
    effort: types.ReasoningEffort,
    model_supports_effort: bool,
    statusline: StatuslineItems,
    width: u16,
    out: []u8,
) []const u8 {
    var model_buf: [96]u8 = undefined;
    const model_label = compactModelLabel(model, &model_buf);
    var permission_buf: [64]u8 = undefined;
    const permission_label = permissionModeStatusLabel(permission_mode, &permission_buf);

    var end: usize = 0;
    if (!awaiting_permission and !has_api_key) {
        appendStatusSegment(out, &end, "run /login");
    }
    const status_limit = @min(@as(usize, width), out.len);
    if (leadingPermissionModeFits(status_limit, permission_label, model_label)) {
        appendStatusSegment(out, &end, permission_label);
    }
    appendSessionStatusSegments(out, &end, status_limit, model, effort, model_supports_effort, fast_indicator_active, statusline);

    const width_usize: usize = width;
    if (width_usize == 0) return "";
    return display_width.prefixByWidthIgnoringAnsi(out[0..end], width_usize);
}

/// Writes the title to the same file the transcript renders to, so a host
/// that redirects its output keeps the escape sequence out of the real
/// stdout. `out` must outlive every call.
pub fn terminalTitleFor(out: *const std.Io.File) host.TerminalTitle {
    return .{
        .context = @constCast(out),
        .set_fn = setTerminalTitleLabel,
        .clear_fn = clearTerminalTitleProvider,
    };
}

fn titleOutput(raw: ?*anyopaque) std.Io.File {
    const out: *const std.Io.File = @ptrCast(@alignCast(raw.?));
    return out.*;
}

const terminal_title_osc_prefix = "\x1b]2;";
const terminal_title_max_content_bytes: usize = 128;
const terminal_title_max_label_bytes = terminal_title_max_content_bytes;

fn sanitizedTerminalTitleLabel(raw: []const u8, buffer: *[terminal_title_max_label_bytes]u8) []const u8 {
    const marker = "...";
    var source_index: usize = 0;
    var written: usize = 0;
    while (source_index < raw.len) {
        const sequence_len: usize = std.unicode.utf8ByteSequenceLength(raw[source_index]) catch {
            source_index += 1;
            continue;
        };
        if (raw.len - source_index < sequence_len) break;
        const sequence = raw[source_index .. source_index + sequence_len];
        const codepoint = display_width.decodeUtf8Sequence(sequence) catch {
            source_index += 1;
            continue;
        };
        source_index += sequence_len;
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) continue;
        if (written + sequence_len > buffer.len) {
            written = text_utils.utf8BackwardBoundary(buffer[0..written], buffer.len - marker.len);
            @memcpy(buffer[written .. written + marker.len], marker);
            written += marker.len;
            break;
        }
        @memcpy(buffer[written .. written + sequence_len], sequence);
        written += sequence_len;
    }
    return buffer[0..written];
}

fn setTerminalTitleLabel(raw: ?*anyopaque, label: []const u8) void {
    const out = titleOutput(raw);
    var label_buffer: [terminal_title_max_label_bytes]u8 = undefined;
    const sanitized = sanitizedTerminalTitleLabel(label, &label_buffer);
    var sequence_buffer: [terminal_title_osc_prefix.len + terminal_title_max_content_bytes + 1]u8 = undefined;
    var sequence: std.Io.Writer = .fixed(&sequence_buffer);
    sequence.writeAll(terminal_title_osc_prefix) catch return;
    sequence.writeAll(sanitized) catch return;
    sequence.writeByte('\x07') catch return;
    out.writeStreamingAll(io_mod.getIo(), sequence.buffered()) catch return;
}

fn clearTerminalTitleProvider(raw: ?*anyopaque) void {
    const out = titleOutput(raw);
    out.writeStreamingAll(io_mod.getIo(), "\x1b]2;\x07") catch return;
}

pub fn formatResumeHandoff(
    buffer: []u8,
    session_id: []const u8,
    terminal_cols: u16,
) ![]const u8 {
    const label = "Continue session with:";
    const command = "fx --resume ";
    const single_row_width = label.len + 1 + command.len + session_id.len;
    const separator = if (single_row_width <= terminal_cols) " " else "\n  ";
    return std.mem.print(
        buffer,
        "{s}{s}{s}{s}{s}{s}\n",
        .{ dim_style, label, separator, command, session_id, reset_style },
    );
}

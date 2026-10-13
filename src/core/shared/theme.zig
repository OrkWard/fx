//! Built-in color themes plus theme.json loading.
//!
//! `fx_dark` and `fx_light` retain their historical palette bytes. The ui
//! keeps diff marker accents off until a theme is explicitly selected. Both
//! core presentation and ui rendering resolve their themed values from here.
//! User themes load from `~/.fx/themes/<name>.json` (selected with
//! FX_THEME=<name>) in either the
//! native fx slot schema or the VS Code theme schema (`colors` +
//! `tokenColors`), so editor themes like GitHub Dark apply
//! directly. Hex colors resolve to truecolor escapes when the terminal
//! supports them, otherwise they quantize to the xterm-256 palette.

const std = @import("std");
const debug_trace = @import("debug_trace.zig");
const io_mod = @import("io.zig");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const SyntaxPalette = struct {
    /// `syntax: false` in a native theme turns syntax highlighting off; the
    /// style slots keep their defaults but the highlighter passes text through.
    enabled: bool = true,
    keyword_style: []const u8,
    string_style: []const u8,
    number_style: []const u8,
    comment_style: []const u8,
    /// Command words (the grammar's variable.function).
    function_style: []const u8,
    /// `$VAR`, `${VAR}`, and `~` references.
    variable_style: []const u8,
    /// `&&`, `|`, redirects, glob stars.
    operator_style: []const u8,
};

pub const Theme = struct {
    name: []const u8,
    light: bool,

    divider_style: []const u8,
    hint_style: []const u8,
    statusline_style: []const u8,
    tag_style: []const u8,
    subtitle_style: []const u8,
    system_notice_label_style: []const u8,
    system_notice_text_style: []const u8,
    dim_style: []const u8,
    warning_style: []const u8,
    green_style: []const u8,
    red_style: []const u8,
    diff_added_style: []const u8,
    diff_removed_style: []const u8,
    // When selected, the line number and +/- sign carry the diff color:
    // green for additions (#30A46C), red for deletions (#E5484D).
    // Unconfigured builtins keep markers monochrome. Both truecolor and
    // 256-color variants ship in each theme for terminal capability selection.
    diff_added_marker_truecolor: []const u8,
    diff_removed_marker_truecolor: []const u8,
    diff_added_marker_fallback: []const u8,
    diff_removed_marker_fallback: []const u8,
    approval_button_active_style: []const u8,
    approval_button_inactive_style: []const u8,
    selected_completion_style: []const u8,
    permission_auto_style: []const u8,
    user_card_marker_style: []const u8,
    user_card_accent_style: []const u8,
    inline_code_open: []const u8,
    task_completed_open: []const u8,
    tool_stdout_style: []const u8,
    tool_stderr_style: []const u8,
    link_style: []const u8,
    syntax: SyntaxPalette,
};

pub const fx_dark: Theme = .{
    .name = "fx-dark",
    .light = false,

    .divider_style = "\x1b[38;5;240m",
    .hint_style = "\x1b[38;5;255m",
    .statusline_style = "\x1b[38;5;245m",
    .tag_style = "\x1b[1;38;5;255m",
    .subtitle_style = "\x1b[1;38;5;255m",
    .system_notice_label_style = "\x1b[1;38;5;252m",
    .system_notice_text_style = "\x1b[38;5;250m",
    .dim_style = "\x1b[38;5;245m",
    .warning_style = "\x1b[38;5;252m",
    .green_style = "\x1b[38;5;252m",
    .red_style = "\x1b[38;5;252m",
    .diff_added_style = "\x1b[38;5;252m",
    .diff_removed_style = "\x1b[38;5;252m",
    .diff_added_marker_truecolor = "\x1b[38;2;48;164;108m",
    .diff_removed_marker_truecolor = "\x1b[38;2;229;72;77m",
    .diff_added_marker_fallback = "\x1b[38;5;71m",
    .diff_removed_marker_fallback = "\x1b[38;5;167m",
    .approval_button_active_style = "\x1b[48;5;255m\x1b[38;5;235m\x1b[1m",
    .approval_button_inactive_style = "\x1b[48;5;239m\x1b[38;5;255m",
    .selected_completion_style = "\x1b[1;38;5;255m",
    .permission_auto_style = "\x1b[38;5;252m",
    .user_card_marker_style = "\x1b[38;5;255m",
    .user_card_accent_style = "\x1b[38;5;252m",
    .inline_code_open = "\x1b[38;5;245m",
    .task_completed_open = "\x1b[38;5;252m",
    .tool_stdout_style = "\x1b[38;5;245m",
    .tool_stderr_style = "\x1b[38;5;252m",
    .link_style = "\x1b[38;5;75m",
    .syntax = .{
        .keyword_style = "\x1b[38;5;252m",
        .string_style = "\x1b[38;5;250m",
        .number_style = "\x1b[38;5;250m",
        .comment_style = "\x1b[38;5;245m",
        .function_style = "\x1b[38;5;252m",
        .variable_style = "\x1b[38;5;252m",
        .operator_style = "\x1b[38;5;252m",
    },
};

pub const fx_light: Theme = .{
    .name = "fx-light",
    .light = true,

    .divider_style = "\x1b[38;5;250m",
    .hint_style = "\x1b[38;5;235m",
    .statusline_style = "\x1b[38;5;241m",
    .tag_style = "\x1b[1;38;5;235m",
    .subtitle_style = "\x1b[1;38;5;235m",
    .system_notice_label_style = "\x1b[1;38;5;238m",
    .system_notice_text_style = "\x1b[38;5;241m",
    .dim_style = "\x1b[38;5;247m",
    .warning_style = "\x1b[38;5;238m",
    .green_style = "\x1b[38;5;238m",
    .red_style = "\x1b[38;5;238m",
    .diff_added_style = "\x1b[38;5;238m",
    .diff_removed_style = "\x1b[38;5;238m",
    .diff_added_marker_truecolor = "\x1b[38;2;48;164;108m",
    .diff_removed_marker_truecolor = "\x1b[38;2;229;72;77m",
    .diff_added_marker_fallback = "\x1b[38;5;71m",
    .diff_removed_marker_fallback = "\x1b[38;5;167m",
    .approval_button_active_style = "\x1b[48;5;236m\x1b[38;5;255m\x1b[1m",
    .approval_button_inactive_style = "\x1b[48;5;251m\x1b[38;5;237m",
    .selected_completion_style = "\x1b[1;38;5;235m",
    .permission_auto_style = "\x1b[38;5;238m",
    .user_card_marker_style = "\x1b[38;5;235m",
    .user_card_accent_style = "\x1b[38;5;238m",
    .inline_code_open = "\x1b[38;5;247m",
    .link_style = "\x1b[38;5;25m",
    .task_completed_open = "\x1b[38;5;238m",
    .tool_stdout_style = "\x1b[38;5;245m",
    .tool_stderr_style = "\x1b[38;5;252m",
    .syntax = .{
        .keyword_style = "\x1b[38;5;238m",
        .string_style = "\x1b[38;5;241m",
        .number_style = "\x1b[38;5;241m",
        .comment_style = "\x1b[38;5;243m",
        .function_style = "\x1b[38;5;238m",
        .variable_style = "\x1b[38;5;238m",
        .operator_style = "\x1b[38;5;238m",
    },
};

pub fn builtin(light: bool) Theme {
    return if (light) fx_light else fx_dark;
}

/// The theme currently applied to the process. Core producers that cannot
/// import ui state read their colors through `current()`; `activate` is called
/// by the ui layer whenever a theme is applied.
var active_theme: Theme = fx_dark;

pub fn current() Theme {
    return active_theme;
}

pub fn activate(theme: Theme) void {
    active_theme = theme;
}

pub const ThemeChoice = union(enum) {
    pin_light,
    pin_dark,
    custom: []const u8,
};

/// Classifies a configured theme value (FX_THEME or the settings "theme"
/// key): light/dark pin the builtin variant, anything else names a theme file
/// under ~/.fx/themes.
pub fn classifyValue(value: []const u8) ?ThemeChoice {
    if (value.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(value, "light")) return .pin_light;
    if (std.ascii.eqlIgnoreCase(value, "dark")) return .pin_dark;
    return .{ .custom = value };
}

/// Where the active theme came from: the configured custom theme file key (so
/// live terminal flips can re-resolve it), and whether a light/dark variant is
/// pinned by configuration. Recorded once at startup by the app lifecycle.
/// The name is copied into bounded internal storage: callers never donate
/// memory, and the bound matches loadNamed's validation.
var source_name_buf: [64]u8 = undefined;
var source_name_len: usize = 0;
var source_name_set: bool = false;
var variant_pinned: bool = false;

pub fn setSource(name: ?[]const u8, pinned: bool) void {
    source_name_set = false;
    source_name_len = 0;
    if (name) |value| {
        if (value.len <= source_name_buf.len) {
            @memcpy(source_name_buf[0..value.len], value);
            source_name_len = value.len;
            source_name_set = true;
        } else {
            debug_trace.logf("theme", "theme_source_name_too_long len={d}", .{value.len});
        }
    }
    variant_pinned = pinned;
}

pub fn sourceName() ?[]const u8 {
    if (!source_name_set) return null;
    return source_name_buf[0..source_name_len];
}

pub fn variantPinned() bool {
    return variant_pinned;
}

// --- Hex colors and terminal capability resolution ---

pub const HexColor = struct { rgb: Rgb, alpha: u8 };

/// Parses `#rgb`, `#rrggbb`, and `#rrggbbaa` (the forms VS Code themes use).
pub fn parseHexColor(bytes: []const u8) ?HexColor {
    if (bytes.len < 2 or bytes[0] != '#') return null;
    const hex = bytes[1..];
    const n = std.fmt.charToDigit;
    switch (hex.len) {
        3 => {
            const r = n(hex[0], 16) catch return null;
            const g = n(hex[1], 16) catch return null;
            const b = n(hex[2], 16) catch return null;
            return .{ .rgb = .{ .r = r * 17, .g = g * 17, .b = b * 17 }, .alpha = 0xff };
        },
        6, 8 => {
            var channels: [4]u8 = .{ 0, 0, 0, 0xff };
            const count = hex.len / 2;
            for (0..count) |i| {
                const hi = n(hex[i * 2], 16) catch return null;
                const lo = n(hex[i * 2 + 1], 16) catch return null;
                channels[i] = hi * 16 + lo;
            }
            return .{ .rgb = .{ .r = channels[0], .g = channels[1], .b = channels[2] }, .alpha = channels[3] };
        },
        else => return null,
    }
}

/// Composites a possibly translucent color over a background, the same way an
/// editor renders theme colors with an alpha channel.
pub fn blendOver(fg: Rgb, alpha: u8, bg: Rgb) Rgb {
    if (alpha == 0xff) return fg;
    const a: u32 = alpha;
    const inv: u32 = 0xff - a;
    return .{
        .r = @intCast((@as(u32, fg.r) * a + @as(u32, bg.r) * inv + 127) / 255),
        .g = @intCast((@as(u32, fg.g) * a + @as(u32, bg.g) * inv + 127) / 255),
        .b = @intCast((@as(u32, fg.b) * a + @as(u32, bg.b) * inv + 127) / 255),
    };
}

const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

fn cubeLevelIndex(v: u8) u8 {
    var best: u8 = 0;
    var best_dist: u32 = std.math.maxInt(u32);
    for (cube_levels, 0..) |level, i| {
        const d = if (level > v) level - v else v - level;
        if (d < best_dist) {
            best_dist = d;
            best = @intCast(i);
        }
    }
    return best;
}

fn colorDistance(r1: u8, g1: u8, b1: u8, r2: u8, g2: u8, b2: u8) u32 {
    const dr = @as(i32, r1) - r2;
    const dg = @as(i32, g1) - g2;
    const db = @as(i32, b1) - b2;
    return @intCast(dr * dr + dg * dg + db * db);
}

/// Maps an RGB color to the nearest xterm-256 palette index, choosing between
/// the 6x6x6 color cube (16-231) and the grayscale ramp (232-255).
pub fn rgbToAnsi256(r: u8, g: u8, b: u8) u8 {
    const ri = cubeLevelIndex(r);
    const gi = cubeLevelIndex(g);
    const bi = cubeLevelIndex(b);
    const cube_dist = colorDistance(r, g, b, cube_levels[ri], cube_levels[gi], cube_levels[bi]);

    const avg: u32 = (@as(u32, r) + g + b) / 3;
    const gray_idx: u32 = if (avg < 8) 0 else @min((avg - 8) / 10, 23);
    const gray_level: u8 = @intCast(8 + gray_idx * 10);
    const gray_dist = colorDistance(r, g, b, gray_level, gray_level, gray_level);

    if (gray_dist < cube_dist) return @intCast(232 + gray_idx);
    return 16 + 36 * ri + 6 * gi + bi;
}

const SlotSpec = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    bold: bool = false,
    italic: bool = false,
};

fn writeColorParam(writer: *std.Io.Writer, prefix: []const u8, rgb: Rgb, truecolor: bool) !void {
    if (truecolor) {
        try writer.print("{s};2;{d};{d};{d}", .{ prefix, rgb.r, rgb.g, rgb.b });
    } else {
        try writer.print("{s};5;{d}", .{ prefix, rgbToAnsi256(rgb.r, rgb.g, rgb.b) });
    }
}

/// True when an SGR open sets the given parameter ("1" bold, "3" italic, "48"
/// background), parsed from the parameter list rather than substring matched.
/// Handles slots built from multiple concatenated SGR escapes.
pub fn sgrHasParam(open: []const u8, param: []const u8) bool {
    var rest = open;
    while (std.mem.find(u8, rest, "\x1b[")) |start| {
        const after = rest[start + 2 ..];
        const end = std.mem.findScalar(u8, after, 'm') orelse return false;
        var it = std.mem.splitScalar(u8, after[0..end], ';');
        var skip: usize = 0;
        while (it.next()) |part| {
            if (skip > 0) {
                skip -= 1;
                continue;
            }
            if (std.mem.eql(u8, part, "38") or std.mem.eql(u8, part, "48")) {
                if (std.mem.eql(u8, part, param)) return true;
                // Color introducer: 5;n consumes one parameter, 2;r;g;b three.
                // Skipping keeps RGB triples from reading as bold/italic.
                const mode = it.next() orelse break;
                if (std.mem.eql(u8, mode, "2")) {
                    skip = 3;
                } else if (std.mem.eql(u8, mode, "5")) {
                    skip = 1;
                }
                continue;
            }
            if (std.mem.eql(u8, part, param)) return true;
        }
        rest = after[end + 1 ..];
    }
    return false;
}

/// The closing sequence that fully neutralizes an SGR open: always resets the
/// foreground, and resets background, bold, and italic only when the open set
/// them. Builtin fg-only slots keep their historical one-escape close.
pub fn closingFor(open: []const u8) []const u8 {
    const has_bg = sgrHasParam(open, "48");
    const has_bold = sgrHasParam(open, "1");
    const has_italic = sgrHasParam(open, "3");
    if (has_bg) {
        if (has_bold and has_italic) return "\x1b[39m\x1b[49m\x1b[22m\x1b[23m";
        if (has_bold) return "\x1b[39m\x1b[49m\x1b[22m";
        if (has_italic) return "\x1b[39m\x1b[49m\x1b[23m";
        return "\x1b[39m\x1b[49m";
    }
    if (has_bold and has_italic) return "\x1b[39m\x1b[22m\x1b[23m";
    if (has_bold) return "\x1b[39m\x1b[22m";
    if (has_italic) return "\x1b[39m\x1b[23m";
    return "\x1b[39m";
}

/// Renders a slot style as one SGR escape. Caller owns the returned slice.
fn slotEscapeChecked(alloc: std.mem.Allocator, spec: SlotSpec, truecolor: bool) ParseError![]u8 {
    return slotEscape(alloc, spec, truecolor) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Writer.Allocating reports allocation failure as WriteFailed in 0.17.
        error.WriteFailed => error.OutOfMemory,
    };
}

fn slotEscape(alloc: std.mem.Allocator, spec: SlotSpec, truecolor: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("\x1b[");
    if (spec.bold) try writer.writeAll("1;");
    if (spec.italic) try writer.writeAll("3;");
    if (spec.fg) |fg| try writeColorParam(writer, "38", fg, truecolor);
    if (spec.bg) |bg| {
        if (spec.fg != null or spec.bold or spec.italic) try writer.writeByte(';');
        try writeColorParam(writer, "48", bg, truecolor);
    }
    try writer.writeByte('m');
    return out.toOwnedSlice();
}

// --- theme.json parsing ---

pub const max_theme_bytes: usize = 1024 * 1024;

pub const ParseError = error{ InvalidTheme, OutOfMemory };
pub const ParseOptions = struct { truecolor: bool = true };

/// Parses a theme.json document, auto-detecting the native fx slot schema and
/// the VS Code theme schema. Slots the file does not mention inherit from the
/// matching builtin variant, so partial themes compose with the fx look.
///
/// The returned Theme borrows from `alloc`; themes are process-lifetime state,
/// so the caller keeps the allocation alive rather than freeing per theme.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8, options: ParseOptions) ParseError!Theme {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return error.InvalidTheme;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidTheme,
    };
    if (looksLikeVsCode(root)) return parseVsCode(alloc, root, options);
    return parseNative(alloc, root, options);
}

fn looksLikeVsCode(root: std.json.ObjectMap) bool {
    if (root.get("tokenColors")) |token_colors| {
        if (token_colors == .array) return true;
    }
    if (root.get("colors")) |colors| {
        if (colors == .object) {
            var it = colors.object.iterator();
            while (it.next()) |entry| {
                if (std.mem.findScalar(u8, entry.key_ptr.*, '.') != null) return true;
            }
        }
    }
    return false;
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// Maps JSON slot keys to Theme fields: field names minus a trailing
/// `_style` or `_open` ("divider", "inline_code"). Unknown keys are ignored
/// so newer theme files keep loading on older binaries.
fn assignSlotEscape(theme: *Theme, json_key: []const u8, escape: []const u8) void {
    const info = @typeInfo(Theme).@"struct";
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        if (field_type == []const u8 and !std.mem.eql(u8, field_name, "name")) {
            const stripped = comptime blk: {
                if (std.mem.endsWith(u8, field_name, "_style")) break :blk field_name[0 .. field_name.len - "_style".len];
                if (std.mem.endsWith(u8, field_name, "_open")) break :blk field_name[0 .. field_name.len - "_open".len];
                break :blk field_name;
            };
            if (std.mem.eql(u8, json_key, stripped)) {
                @field(theme, field_name) = escape;
                return;
            }
        }
    }
}

fn parseSlotSpec(value: std.json.Value) ParseError!SlotSpec {
    return switch (value) {
        .string => |s| blk: {
            const parsed = parseHexColor(s) orelse return error.InvalidTheme;
            if (parsed.alpha != 0xff) return error.InvalidTheme;
            break :blk SlotSpec{ .fg = parsed.rgb };
        },
        .object => |object| blk: {
            var spec: SlotSpec = .{};
            if (object.get("fg")) |fg| {
                const parsed = parseHexColor(jsonString(fg) orelse return error.InvalidTheme) orelse return error.InvalidTheme;
                if (parsed.alpha != 0xff) return error.InvalidTheme;
                spec.fg = parsed.rgb;
            }
            if (object.get("bg")) |bg| {
                const parsed = parseHexColor(jsonString(bg) orelse return error.InvalidTheme) orelse return error.InvalidTheme;
                if (parsed.alpha != 0xff) return error.InvalidTheme;
                spec.bg = parsed.rgb;
            }
            if (object.get("bold")) |bold| {
                if (bold != .bool) return error.InvalidTheme;
                spec.bold = bold.bool;
            }
            if (object.get("italic")) |italic| {
                if (italic != .bool) return error.InvalidTheme;
                spec.italic = italic.bool;
            }
            if (spec.fg == null and spec.bg == null) return error.InvalidTheme;
            break :blk spec;
        },
        else => error.InvalidTheme,
    };
}

fn applySlot(theme: *Theme, alloc: std.mem.Allocator, json_key: []const u8, spec: SlotSpec, options: ParseOptions) ParseError!void {
    if (std.mem.eql(u8, json_key, "diff_added_marker") or std.mem.eql(u8, json_key, "diff_removed_marker")) {
        // Markers resolve both capability forms from one color so the
        // terminal picks at render time, matching the builtin contract.
        const fg = spec.fg orelse return error.InvalidTheme;
        if (spec.bg != null or spec.bold or spec.italic) return error.InvalidTheme;
        const truecolor = try slotEscapeChecked(alloc, .{ .fg = fg }, true);
        const fallback = try slotEscapeChecked(alloc, .{ .fg = fg }, false);
        if (json_key[5] == 'a') {
            theme.diff_added_marker_truecolor = truecolor;
            theme.diff_added_marker_fallback = fallback;
        } else {
            theme.diff_removed_marker_truecolor = truecolor;
            theme.diff_removed_marker_fallback = fallback;
        }
        return;
    }
    assignSlotEscape(theme, json_key, try slotEscapeChecked(alloc, spec, options.truecolor));
}

fn parseNative(alloc: std.mem.Allocator, root: std.json.ObjectMap, options: ParseOptions) ParseError!Theme {
    var light = false;
    if (root.get("type")) |type_value| {
        const type_string = jsonString(type_value) orelse return error.InvalidTheme;
        if (std.ascii.eqlIgnoreCase(type_string, "light")) {
            light = true;
        } else if (!std.ascii.eqlIgnoreCase(type_string, "dark")) {
            return error.InvalidTheme;
        }
    }
    var theme = builtin(light);
    if (root.get("name")) |name_value| {
        const name = jsonString(name_value) orelse return error.InvalidTheme;
        if (name.len == 0) return error.InvalidTheme;
        theme.name = try alloc.dupe(u8, name);
    }
    if (root.get("colors")) |colors_value| {
        if (colors_value != .object) return error.InvalidTheme;
        var it = colors_value.object.iterator();
        while (it.next()) |entry| {
            const spec = try parseSlotSpec(entry.value_ptr.*);
            try applySlot(&theme, alloc, entry.key_ptr.*, spec, options);
        }
    }
    if (root.get("syntax")) |syntax_value| {
        switch (syntax_value) {
            .object => |syntax_object| try applySyntax(&theme, alloc, syntax_object, options),
            .bool => |enabled| theme.syntax.enabled = enabled,
            else => return error.InvalidTheme,
        }
    }
    return theme;
}

fn applySyntax(theme: *Theme, alloc: std.mem.Allocator, syntax: std.json.ObjectMap, options: ParseOptions) ParseError!void {
    var it = syntax.iterator();
    while (it.next()) |entry| {
        const spec = try parseSlotSpec(entry.value_ptr.*);
        const resolved = try slotEscapeChecked(alloc, spec, options.truecolor);
        if (std.mem.eql(u8, entry.key_ptr.*, "keyword")) {
            theme.syntax.keyword_style = resolved;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "string")) {
            theme.syntax.string_style = resolved;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "number")) {
            theme.syntax.number_style = resolved;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "comment")) {
            theme.syntax.comment_style = resolved;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "function")) {
            theme.syntax.function_style = resolved;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "variable")) {
            theme.syntax.variable_style = resolved;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "operator")) {
            theme.syntax.operator_style = resolved;
        }
    }
}

// --- VS Code theme schema ---

const VsCodeSlot = struct {
    key: []const u8,
    sources: []const []const u8,
    bg_sources: []const []const u8 = &.{},
    bold: bool = false,
};

/// Maps editor workbench colors onto fx chrome slots. Unmapped slots inherit
/// the builtin variant, which keeps fx's neutral layout under editor themes.
const vscode_slot_map = [_]VsCodeSlot{
    .{ .key = "divider", .sources = &.{ "editorLineNumber.foreground", "panel.border" } },
    .{ .key = "hint", .sources = &.{ "editor.foreground", "foreground" } },
    .{ .key = "statusline", .sources = &.{ "statusBar.foreground", "editor.foreground", "foreground" } },
    .{ .key = "tag", .sources = &.{ "editor.foreground", "foreground" }, .bold = true },
    .{ .key = "subtitle", .sources = &.{ "editor.foreground", "foreground" }, .bold = true },
    .{ .key = "system_notice_label", .sources = &.{ "editor.foreground", "foreground" }, .bold = true },
    .{ .key = "system_notice_text", .sources = &.{ "editor.foreground", "foreground" } },
    .{ .key = "dim", .sources = &.{ "editorLineNumber.foreground", "editor.foreground", "foreground" } },
    // No foreground fallbacks: a link that matches body text stops reading as a link.
    .{ .key = "link", .sources = &.{"textLink.foreground"} },
    .{ .key = "warning", .sources = &.{ "editorWarning.foreground", "terminal.ansiYellow" } },
    .{ .key = "green", .sources = &.{"terminal.ansiGreen"} },
    .{ .key = "red", .sources = &.{"terminal.ansiRed"} },
    .{ .key = "diff_added", .sources = &.{ "editorGutter.addedBackground", "terminal.ansiGreen" } },
    .{ .key = "diff_removed", .sources = &.{ "editorGutter.deletedBackground", "terminal.ansiRed" } },
    .{ .key = "diff_added_marker", .sources = &.{ "editorGutter.addedBackground", "terminal.ansiGreen" } },
    .{ .key = "diff_removed_marker", .sources = &.{ "editorGutter.deletedBackground", "terminal.ansiRed" } },
    .{ .key = "approval_button_active", .sources = &.{ "button.foreground", "editor.background" }, .bg_sources = &.{ "button.background", "editor.foreground" }, .bold = true },
    .{ .key = "approval_button_inactive", .sources = &.{ "editor.foreground", "foreground" }, .bg_sources = &.{"editor.lineHighlightBackground"} },
    .{ .key = "selected_completion", .sources = &.{ "editor.foreground", "foreground" }, .bold = true },
    .{ .key = "permission_auto", .sources = &.{ "editor.foreground", "foreground" } },
    .{ .key = "user_card_marker", .sources = &.{ "editor.foreground", "foreground" } },
    .{ .key = "user_card_accent", .sources = &.{ "editor.foreground", "foreground" } },
    .{ .key = "inline_code", .sources = &.{ "terminal.ansiCyan", "editor.foreground", "foreground" } },
    .{ .key = "task_completed", .sources = &.{ "terminal.ansiGreen", "editor.foreground", "foreground" } },
    .{ .key = "tool_stdout", .sources = &.{ "terminal.foreground", "editor.foreground", "foreground" } },
    .{ .key = "tool_stderr", .sources = &.{ "editorWarning.foreground", "terminal.foreground", "editor.foreground" } },
};

const vscode_syntax_scopes = [_]struct { slot: []const u8, scope: []const u8 }{
    .{ .slot = "keyword", .scope = "keyword" },
    .{ .slot = "string", .scope = "string" },
    .{ .slot = "number", .scope = "constant.numeric" },
    .{ .slot = "comment", .scope = "comment" },
    .{ .slot = "function", .scope = "entity.name.function" },
    .{ .slot = "variable", .scope = "variable" },
    .{ .slot = "operator", .scope = "keyword.operator" },
};

fn vscodeColor(colors: ?std.json.ObjectMap, sources: []const []const u8, bg: Rgb) ?Rgb {
    const map = colors orelse return null;
    for (sources) |key| {
        if (map.get(key)) |value| {
            if (jsonString(value)) |s| {
                if (parseHexColor(s)) |parsed| return blendOver(parsed.rgb, parsed.alpha, bg);
            }
        }
    }
    return null;
}

const ScopeMatch = struct { rgb: Rgb, bold: bool, italic: bool };

/// Finds the best TextMate scope match for one of fx's syntax slots. Exact
/// scope beats a dotted prefix match; on a tie the later entry wins, matching
/// VS Code's override order. Compound (space-separated) selectors are skipped.
fn tokenColorMatch(token_colors: []const std.json.Value, want: []const u8, bg: Rgb) ?ScopeMatch {
    var best_score: u8 = 0;
    var best: ?ScopeMatch = null;
    for (token_colors) |entry| {
        if (entry != .object) continue;
        const settings = switch (entry.object.get("settings") orelse continue) {
            .object => |object| object,
            else => continue,
        };
        const foreground = blk: {
            const value = settings.get("foreground") orelse break :blk null;
            const s = jsonString(value) orelse break :blk null;
            const parsed = parseHexColor(s) orelse break :blk null;
            break :blk blendOver(parsed.rgb, parsed.alpha, bg);
        } orelse continue;

        var score: u8 = 0;
        switch (entry.object.get("scope") orelse continue) {
            .string => |s| score = scopeAlternativesScore(s, want),
            .array => |items| {
                for (items.items) |item| {
                    const s = jsonString(item) orelse continue;
                    score = @max(score, scopeAlternativesScore(s, want));
                }
            },
            else => continue,
        }
        if (score == 0 or score < best_score) continue;

        var bold = false;
        var italic = false;
        if (settings.get("fontStyle")) |font_style| {
            if (jsonString(font_style)) |s| {
                bold = std.mem.find(u8, s, "bold") != null;
                italic = std.mem.find(u8, s, "italic") != null;
            }
        }
        best_score = score;
        best = .{ .rgb = foreground, .bold = bold, .italic = italic };
    }
    return best;
}

fn scopeAlternativesScore(scopes: []const u8, want: []const u8) u8 {
    var best: u8 = 0;
    var it = std.mem.splitScalar(u8, scopes, ',');
    while (it.next()) |part| {
        const alt = std.mem.trim(u8, part, " \t");
        if (std.mem.findScalar(u8, alt, ' ') != null) continue;
        if (std.mem.eql(u8, alt, want)) {
            best = @max(best, 2);
        } else if (std.mem.startsWith(u8, alt, want) and alt.len > want.len and alt[want.len] == '.') {
            best = @max(best, 1);
        }
    }
    return best;
}

fn parseVsCode(alloc: std.mem.Allocator, root: std.json.ObjectMap, options: ParseOptions) ParseError!Theme {
    const colors: ?std.json.ObjectMap = switch (root.get("colors") orelse .null) {
        .object => |object| object,
        else => null,
    };

    const declared_bg = vscodeColor(colors, &.{"editor.background"}, .{ .r = 0, .g = 0, .b = 0 });
    var light = false;
    if (root.get("type")) |type_value| {
        const type_string = jsonString(type_value) orelse return error.InvalidTheme;
        if (std.ascii.eqlIgnoreCase(type_string, "light") or std.ascii.eqlIgnoreCase(type_string, "hc-light")) {
            light = true;
        } else if (std.ascii.eqlIgnoreCase(type_string, "dark") or std.ascii.eqlIgnoreCase(type_string, "hc")) {
            light = false;
        } else {
            return error.InvalidTheme;
        }
    } else if (declared_bg) |bg| {
        const luminance = (@as(u32, bg.r) * 299 + @as(u32, bg.g) * 587 + @as(u32, bg.b) * 114) / 1000;
        light = luminance >= 128;
    }

    // Alpha-bearing workbench colors composite over the editor background,
    // matching how the editor itself renders them.
    const blend_bg = declared_bg orelse if (light) Rgb{ .r = 0xff, .g = 0xff, .b = 0xff } else Rgb{ .r = 0, .g = 0, .b = 0 };

    var theme = builtin(light);
    if (root.get("name")) |name_value| {
        if (jsonString(name_value)) |name| {
            if (name.len > 0) theme.name = try alloc.dupe(u8, name);
        }
    }

    for (vscode_slot_map) |mapping| {
        const fg = vscodeColor(colors, mapping.sources, blend_bg);
        const bg = vscodeColor(colors, mapping.bg_sources, blend_bg);
        if (fg == null and bg == null) continue;
        const spec: SlotSpec = .{ .fg = fg, .bg = bg, .bold = mapping.bold };
        try applySlot(&theme, alloc, mapping.key, spec, options);
    }

    if (root.get("tokenColors")) |token_colors| {
        if (token_colors == .array) {
            inline for (vscode_syntax_scopes) |target| {
                if (tokenColorMatch(token_colors.array.items, target.scope, blend_bg)) |match| {
                    const resolved = try slotEscapeChecked(alloc, .{ .fg = match.rgb, .bold = match.bold, .italic = match.italic }, options.truecolor);
                    @field(theme.syntax, target.slot ++ "_style") = resolved;
                }
            }
        }
    }
    return theme;
}

// --- Loading from ~/.fx/themes ---

pub const LoadError = error{ InvalidName, ThemeNotFound, InvalidTheme, OutOfMemory };

/// Returns the sibling variant name for the common `-dark` / `-light`
/// (or `_dark` / `_light`) file naming convention, so a pinned theme can
/// follow the terminal's detected mode: github-dark -> github-light.
/// Returns null when the name carries no recognizable variant suffix.
pub fn siblingName(alloc: std.mem.Allocator, name: []const u8, want_light: bool) !?[]const u8 {
    const suffixes = [_][]const u8{ "-dark", "-light", "_dark", "_light" };
    for (suffixes) |suffix| {
        if (name.len <= suffix.len) continue;
        const tail = name[name.len - suffix.len ..];
        if (!std.ascii.eqlIgnoreCase(tail, suffix)) continue;
        const is_light_suffix = std.mem.find(u8, suffix, "light") != null;
        if (is_light_suffix == want_light) return null;
        const base = name[0 .. name.len - suffix.len];
        // Preserve the suffix capitalization style: GitHub_Light -> GitHub_Dark.
        const replacement: []const u8 = if (std.ascii.isUpper(tail[1]))
            (if (want_light) "Light" else "Dark")
        else
            (if (want_light) "light" else "dark");
        return try alloc.print("{s}{s}{s}", .{ base, suffix[0..1], replacement });
    }
    return null;
}

/// Resolves the named theme for the terminal's detected mode: loads it, swaps
/// to a sibling variant file (github-dark <-> github-light) when the variant
/// mismatches, and returns null to signal the builtin variant when neither
/// file fits. Used both at startup and on live terminal theme notifications.
pub fn resolveNamed(alloc: std.mem.Allocator, name: []const u8, terminal_light: bool, options: ParseOptions) LoadError!?Theme {
    const theme = loadNamed(alloc, name, options) catch |err| {
        debug_trace.logf("theme", "custom_theme_load_failed name={s} err={s}", .{ name, @errorName(err) });
        return null;
    };
    if (theme.light == terminal_light) return theme;
    if (siblingName(alloc, name, terminal_light) catch null) |sibling| {
        if (loadNamed(alloc, sibling, options)) |swapped| {
            if (swapped.light == terminal_light) {
                debug_trace.logf("theme", "theme_variant_swapped from={s} to={s}", .{ name, sibling });
                return swapped;
            }
            // A sibling whose declared variant also mismatches is a user file
            // error; fall through to the builtin rather than trusting it.
            debug_trace.logf("theme", "theme_sibling_variant_mismatch name={s}", .{sibling});
        } else |err| {
            debug_trace.logf("theme", "theme_sibling_load_failed name={s} err={s}", .{ sibling, @errorName(err) });
        }
    }
    debug_trace.logf("theme", "theme_variant_fallback name={s} terminal_light={s}", .{ name, if (terminal_light) "true" else "false" });
    return null;
}

/// Loads `~/.fx/themes/<name>.json` and resolves it for the terminal's color
/// capability. The returned Theme is process-lifetime state allocated from
/// `alloc`; the caller keeps the allocation alive.
pub fn loadNamed(alloc: std.mem.Allocator, name: []const u8, options: ParseOptions) LoadError!Theme {
    if (name.len == 0 or name.len > 64) return error.InvalidName;
    for (name) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
        if (!ok) return error.InvalidName;
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;

    const home = io_mod.getenv("HOME") orelse return error.ThemeNotFound;
    const dir_path = try alloc.print("{s}/.fx/themes", .{home});
    defer alloc.free(dir_path);
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), dir_path, .{}) catch return error.ThemeNotFound;
    defer dir.close(io_mod.getIo());

    const file_name = try alloc.print("{s}.json", .{name});
    defer alloc.free(file_name);
    var file = io_mod.openExistingRegularFile(dir, file_name, .read_only) catch return error.ThemeNotFound;
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch return error.ThemeNotFound;
    if (stat.size > max_theme_bytes) return error.InvalidTheme;
    const bytes = io_mod.readFileToEnd(alloc, &file, max_theme_bytes) catch return error.ThemeNotFound;
    defer alloc.free(bytes);

    return parse(alloc, bytes, options);
}

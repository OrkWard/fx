const std = @import("std");
const question_prompt = @import("../../core/agent/question_prompt.zig");
const auth_runtime = @import("../../core/auth/auth_runtime.zig");
const credentials = @import("../../core/auth/credentials.zig");
const image_attachments = @import("../../core/images/image_attachments.zig");
const command_specs = @import("../../core/slash_commands/command_specs.zig");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const visual_layout = @import("../input/visual_layout.zig");
const ui_render = @import("../render.zig");
const picker_presentation = @import("picker_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
const RenderContext = render_input.RenderContext;

const max_status_line_len: usize = 512;
pub const max_top_row_len = row_text.max_top_row_len;
pub const max_model_picker_rows: u16 = list_window.default_max_picker_rows;
pub const composeDividerRow = row_text.composeDividerRow;
pub const appendClipped = row_text.appendClipped;
pub const appendAbsoluteColumn = row_text.appendAbsoluteColumn;

pub const PickerKind = enum { model_stage, provider_stage, models, file, slash, skills, help, settings, sessions, auth };
pub const CappedInputRows = struct {
    row_limit: usize,
    total_lines: u16,
    input_extra: u16,
};

pub const RawInputGeometry = struct {
    summary: visual_layout.Summary,
    window: visual_layout.VisibleWindow,
    total_lines: u16,
    input_extra: u16,
    slash_completion_count: usize,
    show_slash_query: bool,
    picker_start_col: u16,
};

pub const ComposedInputRows = struct {
    rows: std.ArrayList(std.ArrayList(u8)) = .empty,

    pub fn deinit(self: *ComposedInputRows, alloc: Allocator) void {
        for (self.rows.items) |*row| row.deinit(alloc);
        self.rows.deinit(alloc);
    }
};

pub fn composeSteeringMessageRows(
    alloc: Allocator,
    message: []const u8,
    width: u16,
    row_limit: u16,
    waits_for_boundary: bool,
) !ComposedInputRows {
    var composed: ComposedInputRows = .{};
    errdefer composed.deinit(alloc);
    const layout = render_input.steering_message_layout(message, width, waits_for_boundary, row_limit);
    for (layout.rows[0..layout.row_count], 0..) |content, index| {
        const normalized = try alloc.dupe(u8, content);
        defer alloc.free(normalized);
        for (normalized) |*byte| {
            if (byte.* == '\t') byte.* = ' ';
        }
        var safe = try text_utils.encodeTerminalSafe(alloc, normalized, std.math.maxInt(usize));
        defer safe.deinit(alloc);

        var row: std.ArrayList(u8) = .empty;
        errdefer row.deinit(alloc);
        try row.appendSlice(alloc, if (waits_for_boundary) ui_render.dim_style else ui_render.hint_style);
        if (waits_for_boundary) try row_text.appendClipped(alloc, &row, "┋ ", width);
        const ellipsis = layout.truncated and index + 1 == layout.row_count and layout.content_width > 0;
        try row_text.appendClipped(alloc, &row, safe.bytes, layout.content_width - @as(u16, @intFromBool(ellipsis)));
        if (ellipsis) {
            try row.appendSlice(alloc, "…");
        }
        try row.appendSlice(alloc, ui_render.reset_style);
        try composed.rows.append(alloc, row);
    }
    return composed;
}

// Ordered widest-first; every fallback keeps the enter/esc controls so narrow
// terminals never lose the submit and cancel instructions.
const freeform_question_hints = [_][]const u8{
    "↑↓ cursor · shift+↑↓ options · tab questions · enter answer · esc cancel",
    "shift+↑↓ options · tab questions · enter answer · esc cancel",
    "tab questions · enter answer · esc cancel",
    "enter answer · esc cancel",
};

const predefined_question_hints = [_][]const u8{
    "↑↓ options · tab questions · enter answer · esc cancel",
    "tab questions · enter answer · esc cancel",
    "enter answer · esc cancel",
};

fn questionInteractionHint(
    projection: question_prompt.Projection,
    width: u16,
    out_buf: []u8,
) []const u8 {
    const option_count = if (projection.current_entry) |entry| entry.options.len else 0;
    const variants: []const []const u8 = if (projection.isFreeformSelected())
        &freeform_question_hints
    else
        &predefined_question_hints;

    var out: std.Io.Writer = .fixed(out_buf);
    if (projection.isFreeformSelected()) {
        out.writeAll(
            "type answer    ↑↓←→ cursor    shift+↑↓ options    tab questions    enter answer    esc cancel",
        ) catch return display_width.widestFitting(variants, width);
    } else {
        out.print(
            "1–{d} choose now    ↑↓ options    tab questions    enter answer    esc cancel",
            .{option_count},
        ) catch return display_width.widestFitting(variants, width);
    }
    var base = out.buffered();
    if (display_width.visibleWidth(base) > width) {
        const variant = display_width.widestFitting(variants, width);
        out = .fixed(out_buf);
        out.writeAll(variant) catch return variant;
        base = out.buffered();
    }

    // Batch progress rides the hint row, right-aligned like the rest of the
    // footer chrome; a lone question needs no counter.
    if (projection.entry_count > 1) {
        var counter_buf: [32]u8 = undefined;
        const counter = std.mem.print(
            &counter_buf,
            "Question {d} of {d}",
            .{ projection.current_index + 1, projection.entry_count },
        ) catch "";
        const base_width = display_width.visibleWidth(base);
        const counter_width = display_width.visibleWidth(counter);
        if (counter.len > 0 and base_width + counter_width + 2 <= width) {
            out.splatByteAll(' ', width - base_width - counter_width) catch return base;
            out.writeAll(counter) catch return base;
            return out.buffered();
        }
    }
    return base;
}

pub fn slashInputPrefix(registry: command_specs.SlashRegistry, items: []const u8) []const u8 {
    return command_specs.slashCompletionPrefix(registry, items) orelse "";
}

pub fn inputRowLimit(content_bottom: u16) usize {
    const max_extra: usize = if (content_bottom > 4) content_bottom / 2 else 0;
    return max_extra + 1;
}

pub fn cappedInputRows(total_rows: usize, content_bottom: u16, input_visible: bool) CappedInputRows {
    const row_limit = inputRowLimit(content_bottom);
    const visible_rows = @min(total_rows, row_limit);
    const total_lines: u16 = @intCast(@min(visible_rows, std.math.maxInt(u16)));
    const input_extra: u16 = if (input_visible and total_lines > 1) total_lines - 1 else 0;
    return .{
        .row_limit = row_limit,
        .total_lines = total_lines,
        .input_extra = input_extra,
    };
}

pub fn slashCompletionPickerPrefix(ctx: RenderContext, modal_active: bool, show_model_query: bool, show_file_query: bool) ?[]const u8 {
    if (ctx.input.picker.isInlinePickerSuppressed(.slash) or modal_active or show_model_query or show_file_query) return null;
    if (ctx.input.picker.inlinePickerTriggerKind(&ctx.input.edit_state) != .slash) return null;
    // Mid-turn bare `/model` owns the footer slot before the staged picker opens.
    if (ctx.stream.active and ctx.input.picker.isModelShapedInput(&ctx.input.edit_state)) return null;
    const prefix = slashInputPrefix(ctx.slash_registry, ctx.input.edit_state.input.items);
    return if (prefix.len > 0) prefix else null;
}

fn slashCompletionPickerActive(ctx: RenderContext, modal_active: bool, show_model_query: bool, show_file_query: bool) bool {
    return slashCompletionPickerPrefix(ctx, modal_active, show_model_query, show_file_query) != null;
}

pub fn slashCompletionPickerCount(ctx: RenderContext, modal_active: bool, show_model_query: bool, show_file_query: bool) usize {
    const prefix = slashCompletionPickerPrefix(ctx, modal_active, show_model_query, show_file_query) orelse return 0;
    return picker_presentation.mixedSlashCompletionCount(ctx.slash_registry, prefix, ctx.skills_menu.items);
}

fn slashRawAnchor(input_items: []const u8, prefix: []const u8) ?usize {
    const slash_anchor = command_specs.argCompletionAnchor(prefix);
    if (slash_anchor == 0 or prefix.len > input_items.len or slash_anchor > prefix.len) return null;
    const leading_ws = input_items.len - prefix.len;
    return leading_ws + slash_anchor;
}

pub fn measureRawInputGeometry(
    ctx: RenderContext,
    terminal_cols: u16,
    content_bottom: u16,
    input_visible: bool,
    modal_active: bool,
    show_model_query: bool,
    show_file_query: bool,
) RawInputGeometry {
    return measureRawInputGeometryPrepared(
        ctx,
        terminal_cols,
        content_bottom,
        input_visible,
        modal_active,
        show_model_query,
        show_file_query,
        null,
    );
}

pub fn measureRawInputGeometryPrepared(
    ctx: RenderContext,
    terminal_cols: u16,
    content_bottom: u16,
    input_visible: bool,
    modal_active: bool,
    show_model_query: bool,
    show_file_query: bool,
    prepared_slash_completion_count: ?usize,
) RawInputGeometry {
    return measureRawInputGeometryPreparedWithProvider(
        ctx,
        terminal_cols,
        content_bottom,
        input_visible,
        modal_active,
        show_model_query,
        false,
        show_file_query,
        prepared_slash_completion_count,
    );
}

pub fn measureRawInputGeometryPreparedWithProvider(
    ctx: RenderContext,
    terminal_cols: u16,
    content_bottom: u16,
    input_visible: bool,
    modal_active: bool,
    show_model_query: bool,
    show_provider_query: bool,
    show_file_query: bool,
    prepared_slash_completion_count: ?usize,
) RawInputGeometry {
    const display_input = ctx.input.edit_state.input.items;
    const display_cursor = ctx.input.edit_state.cursor;
    const display_images = ctx.pending_images;
    const display_pasted_blocks = ctx.input.entities.pasted_blocks.items;
    const display_image_tokens = ctx.input.entities.image_tokens.items;
    const display_skill_tokens = ctx.input.entities.skill_tokens.items;
    const slash_prefix = slashInputPrefix(ctx.slash_registry, ctx.input.edit_state.input.items);
    const raw_anchor: ?usize = if (show_model_query)
        ctx.model_completion_anchor
    else if (show_provider_query)
        ctx.provider_picker_completion_anchor
    else if (show_file_query)
        ctx.file_completion_anchor
    else
        slashRawAnchor(ctx.input.edit_state.input.items, slash_prefix);

    const summary = visual_layout.summarize(.{
        .input = display_input,
        .cursor = display_cursor,
        .terminal_cols = terminal_cols,
        .images = display_images,
        .pasted_blocks = display_pasted_blocks,
        .image_tokens = display_image_tokens,
        .skill_tokens = display_skill_tokens,
    }, raw_anchor);
    const capped = cappedInputRows(summary.total_rows, content_bottom, input_visible);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, capped.row_limit);
    const slash_query_active = slashCompletionPickerActive(ctx, modal_active, show_model_query, show_provider_query or show_file_query);
    const slash_completion_count = if (slash_query_active)
        prepared_slash_completion_count orelse
            slashCompletionPickerCount(ctx, modal_active, show_model_query, show_provider_query or show_file_query)
    else
        0;
    const show_slash_query = slash_query_active and slash_completion_count > 0;
    const picker_start_col = if (show_model_query or show_provider_query or show_file_query or show_slash_query)
        visual_layout.projectedAnchorColumn(summary, terminal_cols)
    else
        @as(u16, 1);

    return .{
        .summary = summary,
        .window = window,
        .total_lines = capped.total_lines,
        .input_extra = capped.input_extra,
        .slash_completion_count = slash_completion_count,
        .show_slash_query = show_slash_query,
        .picker_start_col = picker_start_col,
    };
}

fn authPickerInteractionHint(view: auth_runtime.PickerView, width: u16) ?[]const u8 {
    if (!view.active or view.include_skip) return null;

    if (view.stage == .api_key and view.api_key_inline) {
        const key_variants = [_][]const u8{
            "enter saves     esc cancels     " ++ credentials.stored_key_backend_label,
            "enter saves  esc cancels",
            "enter  esc",
        };
        for (key_variants) |candidate| {
            if (display_width.visibleWidth(candidate) <= width) return candidate;
        }
        return key_variants[key_variants.len - 1];
    }

    const root_variants = [_][]const u8{
        "↑↓ navigate     enter open     esc close",
        "↑↓ move  enter open  esc",
        "enter open  esc close",
        "enter esc",
    };
    const connections_variants = [_][]const u8{
        "↑↓ navigate     enter open     esc back",
        "↑↓ move  enter open  esc",
        "enter open  esc back",
        "enter esc",
    };
    const selection_variants = [_][]const u8{
        "↑↓ navigate     enter use     esc back",
        "↑↓ move  enter use  esc",
        "enter use  esc back",
        "enter esc",
    };
    const team_variants = [_][]const u8{
        "type to search     ↑↓ navigate     enter use     esc back",
        "type  ↑↓ move  enter  esc",
        "↑↓ move  enter  esc",
        "enter esc",
    };
    const codex_sign_in_variants = [_][]const u8{
        "enter reopens browser · esc cancels",
        "enter reopens  esc cancels",
        "enter  esc",
        "enter esc",
    };
    const grok_browser_variants = [_][]const u8{
        "enter reopens browser · tab enters code · esc cancels",
        "enter reopens  tab code  esc cancels",
        "enter  tab  esc",
        "enter tab esc",
    };
    const grok_manual_variants = [_][]const u8{
        "enter submits code · tab returns to browser · esc cancels",
        "enter submits  tab browser  esc cancels",
        "enter  tab  esc",
        "enter tab esc",
    };
    const variants = switch (view.stage) {
        .root => root_variants,
        .connections => connections_variants,
        .provider, .switch_credential => selection_variants,
        .change_team => team_variants,
        .sign_in => switch (view.sign_in_source) {
            .chatgpt_subscription => codex_sign_in_variants,
            .grok_subscription => if (view.sign_in_code_visible)
                grok_manual_variants
            else
                grok_browser_variants,
            else => return null,
        },
        .api_key => return null,
    };
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) return candidate;
    }
    return variants[variants.len - 1];
}

pub fn composeHintRow(
    alloc: Allocator,
    approval_active: bool,
    ctx: RenderContext,
    width: u16,
) !std.ArrayList(u8) {
    var question_hint_buf: [512]u8 = undefined;
    const question_hint = if (ctx.question) |projection|
        questionInteractionHint(projection, width, &question_hint_buf)
    else
        null;
    const auth_hint = if (!approval_active and question_hint == null and !ctx.ctrl_c_pending)
        authPickerInteractionHint(ctx.auth_picker, width)
    else
        null;
    var hint_buf: [max_status_line_len]u8 = undefined;
    const base_hint_line = ui_render.buildHintLine(
        approval_active,
        ctx.has_api_key or (ctx.auth_picker.active and ctx.auth_picker.include_skip),
        ctx.model,
        ctx.permission_mode,
        ctx.fast_indicator_active,
        ctx.effort,
        ctx.model_supports_effort,
        ctx.statusline,
        width,
        &hint_buf,
    );
    var hint_line = if (question_hint) |hint|
        hint
    else if (ctx.ctrl_c_pending)
        "press ctrl+c again to exit"
    else if (auth_hint) |hint|
        hint
    else
        base_hint_line;

    const width_usize: usize = width;
    const danger_text = dangerStatusText(approval_active, ctx, width);
    // The armed interrupt hint shrinks through compact variants so narrow
    // terminals still show the confirming-press cue; when no variant fits
    // beside the left hint, the cue owns the whole row like ctrl+c does.
    const esc_interrupt_variants = [_][]const u8{
        "esc again to interrupt",
        "esc esc interrupt",
        "esc esc",
    };
    var esc_interrupt_hint: []const u8 = "";
    if (ctx.esc_interrupt_armed) {
        const left_width = display_width.visibleWidthIgnoringAnsi(hint_line);
        for (esc_interrupt_variants) |candidate| {
            if (width_usize > left_width + display_width.visibleWidth(candidate)) {
                esc_interrupt_hint = candidate;
                break;
            }
        }
        if (esc_interrupt_hint.len == 0) hint_line = "esc esc to interrupt";
    }
    // The armed clear indicator outranks the question suppression: a
    // freeform draft mid-question uses the same double-Esc contract as the
    // composer and needs the same cue. The armed interrupt indicator outranks
    // both: it guards an irreversible cancel of active work.
    const right_text: []const u8 = if (ctx.esc_interrupt_armed)
        esc_interrupt_hint
    else if (ctx.esc_clear_armed)
        "esc again to clear"
    else if (question_hint != null)
        ""
    else if (danger_text.len > 0)
        danger_text
    else
        ctx.upgrade_status;
    const right_width = display_width.visibleWidth(right_text);
    const danger_visible = danger_text.len > 0 and right_text.ptr == danger_text.ptr;
    const left_width: u16 = if (!danger_visible and right_width > 0 and width_usize > right_width)
        @intCast(width_usize - right_width - 1)
    else
        width;

    var row: std.ArrayList(u8) = .empty;
    try row.appendSlice(alloc, if (question_hint != null) ui_render.dim_style else ui_render.statusline_style);
    try row_text.appendClipped(alloc, &row, hint_line, left_width);
    try row.appendSlice(alloc, ui_render.reset_style);

    const hint_width = @min(
        display_width.visibleWidthIgnoringAnsi(hint_line),
        @as(usize, left_width),
    );
    if (right_text.len > 0 and right_width > 0 and
        ((danger_visible and width_usize >= right_width) or
            (!danger_visible and width_usize > hint_width + right_width)))
    {
        const tag_col: u16 = @intCast(width_usize - right_width + 1);
        try row_text.appendAbsoluteColumn(alloc, &row, tag_col);
        try row.appendSlice(alloc, if (danger_visible) ui_render.red_style else ui_render.dim_style);
        try row.appendSlice(alloc, right_text);
        try row.appendSlice(alloc, ui_render.reset_style);
    }

    return row;
}

pub fn dangerStatusText(
    approval_active: bool,
    ctx: RenderContext,
    width: u16,
) []const u8 {
    // Transient interaction hints own the whole row: the warning is placed at
    // an absolute column and would overwrite them on narrow terminals.
    if (approval_active or ctx.question != null or ctx.esc_clear_armed or ctx.esc_interrupt_armed or ctx.ctrl_c_pending) return "";
    if (ctx.danger_status.len > 0 and
        display_width.visibleWidth(ctx.danger_status) <= width)
    {
        return ctx.danger_status;
    }
    if (ctx.danger_status_compact.len > 0 and
        display_width.visibleWidth(ctx.danger_status_compact) <= width)
    {
        return ctx.danger_status_compact;
    }
    return "";
}

pub fn composeSkillsMenuHintRow(alloc: Allocator, width: u16, ctrl_c_pending: bool) !std.ArrayList(u8) {
    return composeCatalogMenuHintRow(alloc, width, ctrl_c_pending, .source);
}

pub fn composeModelsMenuHintRow(alloc: Allocator, width: u16, ctrl_c_pending: bool) !std.ArrayList(u8) {
    return composeCatalogMenuHintRow(alloc, width, ctrl_c_pending, .provider);
}

pub fn composeResumeMenuHintRow(alloc: Allocator, width: u16, ctrl_c_pending: bool) !std.ArrayList(u8) {
    return composeCatalogMenuHintRow(alloc, width, ctrl_c_pending, .scope);
}

pub fn composeHelpMenuHintRow(alloc: Allocator, width: u16, ctrl_c_pending: bool) !std.ArrayList(u8) {
    if (ctrl_c_pending) {
        var warning: std.ArrayList(u8) = .empty;
        errdefer warning.deinit(alloc);
        try warning.appendSlice(alloc, ui_render.statusline_style);
        try row_text.appendClipped(alloc, &warning, "press ctrl+c again to exit", width);
        try warning.appendSlice(alloc, ui_render.reset_style);
        return warning;
    }

    const variants = [_][]const u8{
        "↑↓ navigate     tab category     enter open     esc close",
        "↑↓ navigate  tab category  enter open  esc close",
        "↑↓ move  tab category  enter  esc",
        "tab category  enter open  esc",
        "tab enter esc",
    };
    var hint = variants[variants.len - 1];
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) {
            hint = candidate;
            break;
        }
    }

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, hint, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composeSettingsMenuHintRow(
    alloc: Allocator,
    width: u16,
    ctrl_c_pending: bool,
) !std.ArrayList(u8) {
    if (ctrl_c_pending) {
        var warning: std.ArrayList(u8) = .empty;
        errdefer warning.deinit(alloc);
        try warning.appendSlice(alloc, ui_render.statusline_style);
        try row_text.appendClipped(alloc, &warning, "press ctrl+c again to exit", width);
        try warning.appendSlice(alloc, ui_render.reset_style);
        return warning;
    }

    const variants = [_][]const u8{
        "↑↓ navigate     tab category     ←→ change     esc close",
        "↑↓ navigate  tab category  ←→ change  esc close",
        "↑↓ move  tab category  ←→ change  esc",
        "tab category  ←→ change  esc",
        "tab ←→ esc",
    };
    var hint = variants[variants.len - 1];
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) {
            hint = candidate;
            break;
        }
    }

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, hint, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composeCompactCommandMenuHintRow(
    alloc: Allocator,
    width: u16,
    menu: render_input.CompactCommandMenuProjection,
) !std.ArrayList(u8) {
    const variants = switch (menu) {
        .statusline => [_][]const u8{
            "↑↓ navigate     ←→ change     esc close",
            "↑↓ move  ←→ change  esc",
            "←→ esc",
        },
        .usage => [_][]const u8{
            "tab scope     ↑↓ model     enter expand     r refresh     esc close",
            "tab scope  ↑↓ model  enter expand  r refresh  esc",
            "tab ↑↓  enter  r  esc",
        },
        .workspace => [_][]const u8{
            "↑↓ navigate     enter use     esc close",
            "↑↓ move  enter use  esc",
            "enter esc",
        },
    };
    var hint = variants[variants.len - 1];
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) {
            hint = candidate;
            break;
        }
    }

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, hint, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

const CatalogTabKind = enum {
    source,
    provider,
    scope,
};

fn composeCatalogMenuHintRow(alloc: Allocator, width: u16, ctrl_c_pending: bool, tab_kind: CatalogTabKind) !std.ArrayList(u8) {
    if (ctrl_c_pending) {
        var warning: std.ArrayList(u8) = .empty;
        errdefer warning.deinit(alloc);
        try warning.appendSlice(alloc, ui_render.statusline_style);
        try row_text.appendClipped(alloc, &warning, "press ctrl+c again to exit", width);
        try warning.appendSlice(alloc, ui_render.reset_style);
        return warning;
    }

    const source_variants = [_][]const u8{
        "↑↓ navigate     tab source     enter use     esc close",
        "↑↓ navigate  tab source  enter use  esc close",
        "↑↓ move  tab source  enter  esc",
        "enter use  esc close",
        "enter esc",
    };
    const provider_variants = [_][]const u8{
        "↑↓ navigate     tab provider     enter use     esc close",
        "↑↓ navigate  tab provider  enter use  esc close",
        "↑↓ move  tab provider  enter  esc",
        "enter use  esc close",
        "enter esc",
    };
    const scope_variants = [_][]const u8{
        "↑↓ navigate     tab scope     enter resume     esc close",
        "↑↓ navigate  tab scope  enter resume  esc close",
        "↑↓ move  tab scope  enter  esc",
        "enter resume  esc close",
        "enter esc",
    };
    const variants = switch (tab_kind) {
        .source => source_variants,
        .provider => provider_variants,
        .scope => scope_variants,
    };
    var hint = variants[variants.len - 1];
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) {
            hint = candidate;
            break;
        }
    }

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, hint, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composeSlashMenuHintRow(alloc: Allocator, width: u16) !std.ArrayList(u8) {
    const variants = [_][]const u8{
        "↑↓ navigate     enter use     esc close",
        "↑↓ navigate  enter use  esc close",
        "↑↓ move  enter  esc",
        "enter use  esc close",
        "enter esc",
    };
    var hint = variants[variants.len - 1];
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) {
            hint = candidate;
            break;
        }
    }

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, hint, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composeVisibleInputRows(
    alloc: Allocator,
    source: visual_layout.Source,
    window: visual_layout.VisibleWindow,
) !ComposedInputRows {
    var result = ComposedInputRows{};
    errdefer result.deinit(alloc);
    if (window.row_count == 0) return result;

    const end_row = window.first_row + window.row_count;
    var current: std.ArrayList(u8) = .empty;
    errdefer current.deinit(alloc);
    var row_started = false;
    var remaining_cells: usize = 0;
    var omitted_positive_unit = false;

    var it = visual_layout.iterator(source);
    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (unit.row_index < window.first_row) continue;
            if (unit.row_index >= end_row) break;
            try startComposedInputRow(
                alloc,
                &current,
                source.terminal_cols,
                unit.row_index,
                unit.row_index == window.first_row and window.first_row > 0,
                &row_started,
                &remaining_cells,
            );
            try appendLayoutUnit(alloc, &current, source, unit, &remaining_cells, &omitted_positive_unit);
        },
        .row_end => |row| {
            if (row.index < window.first_row) continue;
            if (row.index >= end_row) break;
            try startComposedInputRow(
                alloc,
                &current,
                source.terminal_cols,
                row.index,
                row.index == window.first_row and window.first_row > 0,
                &row_started,
                &remaining_cells,
            );
            try finishComposedInputRow(alloc, &current, source.terminal_cols);
            try result.rows.append(alloc, current);
            current = .empty;
            row_started = false;
            remaining_cells = 0;
            omitted_positive_unit = false;
            if (row.index + 1 >= end_row) break;
        },
    };

    return result;
}

pub fn appendInlineCompletionSuffix(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    width: u16,
    suffix: []const u8,
) !void {
    if (suffix.len == 0) return;
    const used_cells = display_width.visibleWidthIgnoringAnsi(row.items);
    if (used_cells >= @as(usize, width)) return;

    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(
        alloc,
        row,
        suffix,
        @intCast(@as(usize, width) - used_cells),
    );
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn startComposedInputRow(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    width: u16,
    row_index: usize,
    hidden_above: bool,
    started: *bool,
    remaining_cells: *usize,
) !void {
    if (started.*) return;
    started.* = true;
    const prefix = visual_layout.inputPrefix(row_index);
    try row.appendSlice(alloc, ui_render.hint_style);
    try row_text.appendClipped(alloc, row, if (hidden_above) "┃↑" else "┃", width);
    try row.appendSlice(alloc, ui_render.reset_style);
    if (!hidden_above and width > 1) try row_text.appendClipped(alloc, row, " ", width - 1);
    const width_usize: usize = width;
    remaining_cells.* = if (width_usize > prefix.cell_width) width_usize - prefix.cell_width else 0;
}

fn appendLayoutUnit(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    source: visual_layout.Source,
    unit: visual_layout.Unit,
    remaining_cells: *usize,
    omitted_positive_unit: *bool,
) !void {
    if (remaining_cells.* == 0) return;

    const selected = if (source.selection) |selection|
        unit.raw_start < selection.end and unit.raw_end > selection.start
    else
        false;
    if (selected) try row.appendSlice(alloc, "\x1b[7m");
    try appendLayoutUnitContent(
        alloc,
        row,
        source,
        unit,
        remaining_cells,
        omitted_positive_unit,
    );
    if (selected) {
        try row.appendSlice(alloc, ui_render.reset_style);
    }
}

fn appendLayoutUnitContent(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    source: visual_layout.Source,
    unit: visual_layout.Unit,
    remaining_cells: *usize,
    omitted_positive_unit: *bool,
) !void {
    switch (unit.kind) {
        .text => {
            if (unit.cell_width == 0) {
                if (!omitted_positive_unit.*) try row.appendSlice(alloc, source.input[unit.raw_start..unit.raw_end]);
                return;
            }
            if (unit.cell_width <= remaining_cells.*) {
                try row.appendSlice(alloc, source.input[unit.raw_start..unit.raw_end]);
                remaining_cells.* -= unit.cell_width;
                omitted_positive_unit.* = false;
            } else {
                omitted_positive_unit.* = true;
            }
        },
        .paste_placeholder => {
            const emit_cells = @min(unit.cell_width, remaining_cells.*);
            try row_text.appendClipped(
                alloc,
                row,
                source.input[unit.raw_start..unit.raw_end],
                @intCast(@min(emit_cells, std.math.maxInt(u16))),
            );
            remaining_cells.* -= emit_cells;
            omitted_positive_unit.* = emit_cells < unit.cell_width;
        },
        .tab => {
            if (unit.cell_width == 0) return;
            if (unit.cell_width <= remaining_cells.*) {
                try row.appendNTimes(alloc, ' ', unit.cell_width);
                remaining_cells.* -= unit.cell_width;
                omitted_positive_unit.* = false;
            } else {
                omitted_positive_unit.* = true;
            }
        },
        .skill_token => |token_index| {
            const token = source.skill_tokens[token_index];
            const emit_cells = @min(unit.cell_width, remaining_cells.*);
            if (emit_cells == 0) {
                omitted_positive_unit.* = unit.cell_width > 0;
                return;
            }
            try row.appendSlice(alloc, ui_render.tag_style);
            try row_text.appendClipped(alloc, row, token.name, @intCast(@min(emit_cells, std.math.maxInt(u16))));
            try row.appendSlice(alloc, ui_render.reset_style);
            remaining_cells.* -= emit_cells;
            omitted_positive_unit.* = unit.cell_width > emit_cells;
        },
        .image_badge => |badge| {
            const emit_cells = @min(unit.cell_width, remaining_cells.*);
            if (emit_cells == 0) {
                omitted_positive_unit.* = unit.cell_width > 0;
                return;
            }
            var writer = std.Io.Writer.Allocating.fromArrayList(alloc, row);
            const attachment = source.images[badge.attachment_index];
            try image_attachments.writeImageBadgeClipped(&writer.writer, attachment.id, attachment.path, emit_cells);
            row.* = writer.toArrayList();
            remaining_cells.* -= emit_cells;
            omitted_positive_unit.* = unit.cell_width > emit_cells;
        },
    }
}

fn finishComposedInputRow(alloc: Allocator, row: *std.ArrayList(u8), width: u16) !void {
    if (display_width.visibleWidthIgnoringAnsi(row.items) < @as(usize, width)) try row.appendSlice(alloc, "\x1b[K");
}

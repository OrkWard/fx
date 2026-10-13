const std = @import("std");
const question_state = @import("../../core/agent/question_prompt.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const permission_request = @import("../../core/permissions/permission_request.zig");
const approval_prompt = @import("../../core/permissions/approval_prompt.zig");
const file_index = @import("../../core/workspace/file_index.zig");
const types = @import("../../core/shared/types.zig");
const activity_runtime = @import("../../core/output/activity_runtime.zig");
const visual_layout = @import("../input/visual_layout.zig");
const user_message_card = @import("../assistant/user_message_card.zig");
const ui_render = @import("../render.zig");
const render_engine = @import("../render_engine.zig");
const transcript_runtime = @import("../transcript/runtime.zig");
const footer_viewport = @import("viewport.zig");
const approval_ui = @import("approval_ui.zig");
const compact_command_menu_presentation = @import("compact_command_menu_presentation.zig");
const input_presentation = @import("input_presentation.zig");
const picker_presentation = @import("picker_presentation.zig");
const model_menu_presentation = @import("model_menu_presentation.zig");
const skills_menu_presentation = @import("skills_menu_presentation.zig");
const help_menu_presentation = @import("help_menu_presentation.zig");
const settings_menu_presentation = @import("settings_menu_presentation.zig");
const resume_menu_presentation = @import("resume_menu_presentation.zig");
const question_ui = @import("question_ui.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
const engine_paint_plan = render_engine.paint_plan;
const viewport_selection = render_engine.viewport_selection;
const Layout = types.Layout;
const ActivityProjection = activity_runtime.ActivityProjection;
const PaintPlan = engine_paint_plan.PaintPlan;
const ViewportSelection = viewport_selection.ViewportSelection;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const ApprovalProjection = approval_prompt.Projection;

pub const FooterTranscriptState = struct {
    selection: ViewportSelection,
    cursor_row: u16,
    cursor_col: u16,
    replaceable_row: u16,
    bottom_reserved_rows: u16,
};

pub const FooterPlannerInput = struct {
    active_label: ?[]const u8,
    activity_projection: ActivityProjection = .none,
    ctx: render_input.RenderContext,
    place_mid_line_active: bool,
    input_extra: u16,
    input_visible: bool = true,
    composer_top_chrome_rows: u16 = 1,
    picker_rows: u16,
    footer_gap_active: bool = false,
    banner_active: bool,
    banner_rows: u16 = 0,
    footer_extra_rows: ?u16 = null,
    allocated_rows: ?u16 = null,
    applied_bottom_reserved_rows: u16 = 0,
    approval: ?ApprovalProjection = null,
    input_display: []const u8 = "",
    input_cursor: usize = 0,
    input_summary: visual_layout.Summary = .{
        .total_rows = 1,
        .cursor = .{ .raw_offset = 0, .row_index = 0, .content_column = 0 },
        .anchor = null,
    },
    input_window: visual_layout.VisibleWindow = .{ .first_row = 0, .row_count = 1 },
    total_lines: u16 = 1,
    show_picker: bool = false,
    picker_kind: input_presentation.PickerKind = .model_stage,
    picker_items: []const []const u8 = &.{},
    picker_annotations: []const []const u8 = &.{},
    file_picker_items: []const file_index.SearchResult = &.{},
    picker_selection_index: usize = 0,
    picker_window_start: usize = 0,
    picker_loading: bool = false,
    picker_failed: bool = false,
    slash_completion_count: usize = 0,
    slash_menu_layout: ?picker_presentation.SlashMenuLayout = null,
    prepared_slash_menu: ?*const picker_presentation.PreparedSlashMenu = null,
    picker_start_col: u16 = 1,
    transcript_state: ?FooterTranscriptState = null,
};

pub noinline fn composerTopChromeRows() u16 {
    return 0;
}

pub fn appendFooterFrameInvalidation(
    invalidation: *engine_paint_plan.FrameInvalidationSet,
    range: engine_paint_plan.FrameInvalidationRange,
) void {
    if (invalidation.appendOrCollapse(range)) |collapsed| {
        debug_trace.logf(
            "frame_plan",
            "footer_plan_invalidation_collapse incoming_reason={s} collapsed_reason={s} top={d} bottom={d}",
            .{ @tagName(range.reason), @tagName(collapsed.reason), collapsed.top, collapsed.bottom },
        );
    }
}

pub fn currentViewportSelection(shell: *const TranscriptRuntime) ViewportSelection {
    if (shell.last_viewport_selection) |selection| return clampViewportSelectionToLayout(selection, shell.layout);
    const top_row = @max(if (shell.viewport_top_row < 1) 1 else shell.viewport_top_row, shell.owned_top_row);
    return clampViewportSelectionToLayout(.{
        .top_row = top_row,
        .bottom_row = shell.layout.content_bottom,
        .start_line = shell.last_visible_transcript_start_line,
        .partial_skip_rows = shell.last_visible_transcript_partial_skip_rows,
        .line_count = 0,
        .last_visible_row = shell.last_visible_transcript_last_row,
        .last_visible_row_blank = shell.last_visible_transcript_last_row_blank,
        .tail_kind = shell.last_visible_transcript_tail_kind,
        .replaceable_start_row = shell.replaceable_row,
        .split_active = shell.last_visible_transcript_split_active,
        .split_prefix_lines = shell.last_visible_transcript_split_prefix_lines,
        .split_suffix_start_line = shell.last_visible_transcript_split_suffix_start_line,
    }, shell.layout);
}

fn clampViewportSelectionToLayout(selection: ViewportSelection, layout: Layout) ViewportSelection {
    if (layout.rows == 0 or layout.content_bottom == 0) return selection;

    const max_row = @min(layout.content_bottom, layout.rows);
    var clamped = selection;
    if (clamped.top_row == 0) clamped.top_row = 1;
    if (clamped.top_row > max_row) clamped.top_row = max_row;
    if (clamped.bottom_row < clamped.top_row) clamped.bottom_row = clamped.top_row;
    if (clamped.bottom_row > max_row) clamped.bottom_row = max_row;
    if (clamped.last_visible_row > max_row) clamped.last_visible_row = max_row;
    if (clamped.last_visible_row != 0 and clamped.last_visible_row < clamped.top_row) clamped.last_visible_row = clamped.top_row;
    if (clamped.replaceable_start_row > max_row) clamped.replaceable_start_row = max_row;
    return clamped;
}

const InputCursorPlacement = struct {
    row: u16,
    col: u16,
};

fn pushSteeringRows(
    alloc: Allocator,
    frame: *footer_viewport.ComposedFooterFrame,
    plan: PaintPlan,
    ctx: render_input.RenderContext,
    width: u16,
) !void {
    if (ctx.steering_messages.len == 0 or
        !plan.footer.banner_active or
        plan.footer.banner_rows == 0) return;

    const gap_rows: u16 = @intFromBool(plan.footer.banner_rows > 1);
    const steering_row_budget = plan.footer.banner_rows -| gap_rows;
    var visible_start = ctx.steering_messages.len;
    var remaining_rows = steering_row_budget;
    var oldest_row_limit: u16 = 0;
    while (visible_start > 0 and remaining_rows > 0) {
        const candidate = visible_start - 1;
        const candidate_rows = render_input.steering_message_layout(
            ctx.steering_messages[candidate],
            width,
            ctx.steering_waits_for_boundary,
            render_input.max_steering_message_rows,
        ).row_count;
        visible_start = candidate;
        oldest_row_limit = @min(candidate_rows, remaining_rows);
        if (candidate_rows >= remaining_rows) break;
        remaining_rows -= candidate_rows;
    }

    var painted: u16 = 0;
    for (ctx.steering_messages[visible_start..], visible_start..) |message, index| {
        if (painted >= steering_row_budget) break;
        const row_limit = if (index == visible_start)
            oldest_row_limit
        else
            render_input.max_steering_message_rows;
        var rows = try input_presentation.composeSteeringMessageRows(
            alloc,
            message,
            width,
            row_limit,
            ctx.steering_waits_for_boundary,
        );
        defer rows.deinit(alloc);
        for (rows.rows.items) |*row| {
            if (painted >= steering_row_budget) break;
            try pushFooterBandRow(
                alloc,
                frame,
                plan,
                plan.footer.banner +| painted,
                row,
            );
            painted +|= 1;
        }
    }

    if (painted < plan.footer.banner_rows) {
        var gap: std.ArrayList(u8) = .empty;
        try pushFooterBandRow(
            alloc,
            frame,
            plan,
            plan.footer.banner +| painted,
            &gap,
        );
    }
}

pub fn composeFooterFrame(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    input: FooterPlannerInput,
    plan: PaintPlan,
) !footer_viewport.ComposedFooterFrame {
    const rows = plan.footer;
    const ctx = input.ctx;
    const approval_active = input.approval != null;
    const question_projection = if (!approval_active) ctx.question else null;
    const question_active = question_projection != null;
    const compact_command_menu = if (!approval_active and !question_active)
        render_input.activeCompactCommandMenu(ctx)
    else
        null;
    const compact_command_active = compact_command_menu != null;

    if (approval_active) {
        if (input.approval.?.request.file) |file_request| {
            return composeFileApprovalFooterFrame(alloc, shell, input, plan, file_request);
        }
    }

    if (ctx.transcript_depth.active()) {
        return composeTranscriptViewerFooterFrame(alloc, shell, input, plan);
    }

    var frame = footer_viewport.ComposedFooterFrame{};
    errdefer frame.deinit(alloc);

    try pushSteeringRows(alloc, &frame, plan, ctx, shell.layout.cols);

    const needs_top_divider = !input.input_visible or input.composer_top_chrome_rows > 0;
    if (needs_top_divider) {
        var top_divider_row = try composeComposerTopDividerRow(alloc, shell.layout.cols);
        try pushFooterBandRow(alloc, &frame, plan, rows.top_divider, &top_divider_row);
    }

    const base_row = rows.input_base;
    var cursor_row: u16 = base_row;
    var cursor_col: u16 = 1;

    if (input.input_visible) {
        const standalone_selection: ?visual_layout.RawRange = if (ctx.input.edit_state.selectionRange()) |selection| .{
            .start = selection.start,
            .end = selection.end,
        } else null;
        const cursor = try composeAndPushVisibleInputRows(alloc, &frame, plan, base_row, input.input_summary, input.input_window, .{
            .input = ctx.input.edit_state.input.items,
            .cursor = ctx.input.edit_state.cursor,
            .terminal_cols = shell.layout.cols,
            .images = ctx.pending_images,
            .pasted_blocks = ctx.input.entities.pasted_blocks.items,
            .image_tokens = ctx.input.entities.image_tokens.items,
            .skill_tokens = ctx.input.entities.skill_tokens.items,
            .selection = standalone_selection,
        }, ctx.inline_completion_suffix);
        cursor_row = cursor.row;
        cursor_col = cursor.col;
    }

    if (approval_active or question_active or compact_command_active or input.show_picker) {
        if (input.input_visible) {
            var picker_divider = try row_text.composeDividerRow(alloc, shell.layout.cols);
            try pushFooterBandRow(alloc, &frame, plan, rows.picker_divider, &picker_divider);
        }

        if (approval_active) {
            var approval_row_index: u16 = 0;
            while (approval_row_index < input.picker_rows) : (approval_row_index += 1) {
                var approval_row = try approval_ui.composeInlineApprovalPanelRow(
                    alloc,
                    input.approval.?,
                    shell.layout.cols,
                    shell.layout.rows,
                    approval_row_index,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + approval_row_index, &approval_row);
            }
        } else if (question_projection) |projection| {
            try pushQuestionPanelRows(alloc, &frame, plan, rows.picker_start, input.picker_rows, projection, shell.layout.cols);
        } else if (compact_command_menu) |menu| {
            var menu_row_index: u16 = 0;
            while (menu_row_index < input.picker_rows) : (menu_row_index += 1) {
                var menu_row = try compact_command_menu_presentation.composeCompactCommandMenuRow(
                    alloc,
                    menu,
                    menu_row_index,
                    input.picker_rows,
                    shell.layout.cols,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + menu_row_index, &menu_row);
            }
        } else if (input.picker_kind == .settings and ctx.settings_menu.active) {
            var menu_row_index: u16 = 0;
            while (menu_row_index < input.picker_rows) : (menu_row_index += 1) {
                var menu_row = try settings_menu_presentation.composeSettingsMenuRow(
                    alloc,
                    ctx.settings_menu,
                    menu_row_index,
                    shell.layout.cols,
                    input.picker_rows,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + menu_row_index, &menu_row);
            }
        } else if (input.picker_kind == .help and ctx.help_menu.active) {
            var menu_row_index: u16 = 0;
            while (menu_row_index < input.picker_rows) : (menu_row_index += 1) {
                var menu_row = try help_menu_presentation.composeHelpMenuRow(
                    alloc,
                    ctx.help_menu,
                    menu_row_index,
                    shell.layout.cols,
                    input.picker_rows,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + menu_row_index, &menu_row);
            }
        } else if (input.picker_kind == .sessions and ctx.session_menu.active) {
            var menu_row_index: u16 = 0;
            while (menu_row_index < input.picker_rows) : (menu_row_index += 1) {
                var menu_row = try resume_menu_presentation.composeSessionMenuRow(
                    alloc,
                    ctx.session_menu,
                    menu_row_index,
                    shell.layout.cols,
                    input.picker_rows,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + menu_row_index, &menu_row);
            }
        } else if (input.picker_kind == .models and ctx.model_menu.active) {
            var menu_row_index: u16 = 0;
            while (menu_row_index < input.picker_rows) : (menu_row_index += 1) {
                var menu_row = try model_menu_presentation.composeModelMenuRow(
                    alloc,
                    ctx.model_menu,
                    menu_row_index,
                    shell.layout.cols,
                    input.picker_rows,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + menu_row_index, &menu_row);
            }
        } else if (input.picker_kind == .skills and ctx.skills_menu.active) {
            var prepared = try skills_menu_presentation.prepareInlineSkillsMenu(
                alloc,
                ctx.skills_menu,
                input.picker_rows,
            );
            defer prepared.deinit(alloc);
            var menu_row_index: u16 = 0;
            while (menu_row_index < prepared.rowCount()) : (menu_row_index += 1) {
                var menu_row = try skills_menu_presentation.composeSkillsMenuRow(
                    alloc,
                    prepared,
                    menu_row_index,
                    shell.layout.cols,
                );
                try pushFooterBandRow(
                    alloc,
                    &frame,
                    plan,
                    rows.picker_start + menu_row_index,
                    &menu_row,
                );
            }
        } else if (input.picker_kind == .auth and ctx.auth_picker.active) {
            var auth_row_index: u16 = 0;
            while (auth_row_index < input.picker_rows) : (auth_row_index += 1) {
                var auth_row = try picker_presentation.composeAuthPickerRow(
                    alloc,
                    ctx.auth_picker,
                    auth_row_index,
                    input.picker_rows,
                    shell.layout.cols,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + auth_row_index, &auth_row);
            }
            if (picker_presentation.authPickerQueryCursorColumn(ctx.auth_picker, shell.layout.cols)) |column| {
                cursor_row = rows.picker_start;
                cursor_col = column;
            }
        } else if (input.picker_kind == .slash) {
            const slash_prefix = input_presentation.slashInputPrefix(ctx.slash_registry, ctx.input.edit_state.input.items);
            const count = if (input.prepared_slash_menu) |prepared|
                prepared.resultCount()
            else
                picker_presentation.mixedSlashCompletionCount(ctx.slash_registry, slash_prefix, ctx.skills_menu.items);
            if (count > 0) {
                if (input.slash_menu_layout) |layout| {
                    var row = rows.picker_start;
                    if (layout.show_header) {
                        var header = try picker_presentation.composeSlashMenuHeaderRow(alloc, slash_prefix, layout, shell.layout.cols);
                        try pushFooterBandRow(alloc, &frame, plan, row, &header);
                        row += 1;

                        var gap: std.ArrayList(u8) = .empty;
                        try pushFooterBandRow(alloc, &frame, plan, row, &gap);
                        row += 1;
                    }

                    const column_widths = if (input.prepared_slash_menu) |prepared|
                        picker_presentation.preparedSlashMenuColumnWidths(
                            prepared,
                            layout.window,
                            ctx.input.slash_menu_categories,
                        )
                    else
                        picker_presentation.mixedSlashMenuColumnWidths(
                            ctx.slash_registry,
                            slash_prefix,
                            ctx.skills_menu.items,
                            layout.window,
                            ctx.input.slash_menu_categories,
                        );
                    var match_idx = layout.window.start;
                    while (match_idx < layout.window.end) : (match_idx += 1) {
                        var slash_row = if (input.prepared_slash_menu) |prepared|
                            try picker_presentation.composePreparedSlashMenuOptionRow(
                                alloc,
                                prepared,
                                match_idx,
                                match_idx == layout.selected,
                                column_widths,
                                shell.layout.cols,
                                ctx.input.slash_menu_categories,
                            )
                        else
                            try picker_presentation.composeSlashMenuOptionRow(
                                alloc,
                                ctx.slash_registry,
                                slash_prefix,
                                ctx.skills_menu.items,
                                match_idx,
                                match_idx == layout.selected,
                                column_widths,
                                shell.layout.cols,
                                ctx.input.slash_menu_categories,
                            );
                        try pushFooterBandRow(alloc, &frame, plan, row, &slash_row);
                        row += 1;
                    }
                } else {
                    const selected = input.picker_selection_index % count;
                    const window_start = picker_presentation.updateEdgeScrollPickerWindowStart(input.picker_window_start, count, selected, input.picker_rows);
                    const window = picker_presentation.edgeScrollPickerWindowFromStart(count, window_start, input.picker_rows);
                    const command_width = picker_presentation.mixedSlashCompletionCommandColumnWidth(ctx.slash_registry, slash_prefix, ctx.skills_menu.items, window);
                    var row = rows.picker_start;
                    var match_idx = window.start;
                    while (match_idx < window.end) : (match_idx += 1) {
                        var slash_row = try picker_presentation.composeMixedSlashCompletionOptionRow(alloc, ctx.slash_registry, slash_prefix, ctx.skills_menu.items, match_idx, match_idx == selected, input.picker_start_col, command_width, shell.layout.cols);
                        try pushFooterBandRow(alloc, &frame, plan, row, &slash_row);
                        row += 1;
                    }
                }
            }
        } else if (input.picker_kind == .file and input.file_picker_items.len > 0) {
            const selected = input.picker_selection_index % input.file_picker_items.len;
            var row = rows.picker_start;
            const status_rows: u16 = @intFromBool(ctx.file_completion_status != null and input.picker_rows > 1);
            if (status_rows > 0) {
                const status = ctx.file_completion_status.?;
                var status_row = try picker_presentation.composePickerOptionRow(alloc, .file, input.picker_start_col, status, false, shell.layout.cols);
                try pushFooterBandRow(alloc, &frame, plan, row, &status_row);
                row += 1;
            }
            const visible_rows = input.picker_rows -| status_rows;
            const window_start = picker_presentation.updateEdgeScrollPickerWindowStart(input.picker_window_start, input.file_picker_items.len, selected, visible_rows);
            const window = picker_presentation.edgeScrollPickerWindowFromStart(input.file_picker_items.len, window_start, visible_rows);
            for (input.file_picker_items[window.start..window.end], window.start..) |item, i| {
                var picker_row = try picker_presentation.composeFilePickerOptionRow(alloc, input.picker_start_col, item, ctx.file_completion_has_selection and i == selected, shell.layout.cols);
                try pushFooterBandRow(alloc, &frame, plan, row, &picker_row);
                row += 1;
            }
        } else if (input.picker_items.len > 0) {
            const selected = input.picker_selection_index % input.picker_items.len;
            const window_start = picker_presentation.updateEdgeScrollPickerWindowStart(input.picker_window_start, input.picker_items.len, selected, input.picker_rows);
            const window = picker_presentation.edgeScrollPickerWindowFromStart(input.picker_items.len, window_start, input.picker_rows);
            var row = rows.picker_start;
            for (input.picker_items[window.start..window.end], window.start..) |item, i| {
                const annotation = if (i < input.picker_annotations.len) input.picker_annotations[i] else "";
                var picker_row = try picker_presentation.composePickerOptionRowAnnotated(alloc, input.picker_kind, input.picker_start_col, item, annotation, i == selected, shell.layout.cols);
                try pushFooterBandRow(alloc, &frame, plan, row, &picker_row);
                row += 1;
            }
        } else {
            var status_row = if (input.picker_kind == .file and ctx.file_completion_status != null)
                try picker_presentation.composePickerOptionRow(alloc, .file, input.picker_start_col, ctx.file_completion_status.?, false, shell.layout.cols)
            else
                try picker_presentation.composePickerStatusRowWithProvider(alloc, input.picker_kind, ctx.model_picker_stage, input.picker_loading, input.picker_failed, input.picker_start_col, shell.layout.cols);
            try pushFooterBandRow(alloc, &frame, plan, rows.picker_start, &status_row);
        }
    }

    const needs_bottom_divider = !input.input_visible or approval_active or question_active or compact_command_active or input.show_picker;
    var bottom_row: std.ArrayList(u8) = if (needs_bottom_divider)
        try row_text.composeDividerRow(alloc, shell.layout.cols)
    else
        .empty;
    try pushFooterBandRow(alloc, &frame, plan, rows.bottom_divider, &bottom_row);

    var danger_status_visible = false;
    var hint_row = if (approval_active)
        try approval_ui.composeInlineApprovalHintRow(
            alloc,
            input.approval.?,
            shell.layout.cols,
        )
    else if (compact_command_menu) |menu|
        try input_presentation.composeCompactCommandMenuHintRow(alloc, shell.layout.cols, menu)
    else if (input.show_picker and input.picker_kind == .skills)
        try input_presentation.composeSkillsMenuHintRow(alloc, shell.layout.cols, ctx.ctrl_c_pending)
    else if (input.show_picker and input.picker_kind == .settings)
        try input_presentation.composeSettingsMenuHintRow(alloc, shell.layout.cols, ctx.ctrl_c_pending)
    else if (input.show_picker and input.picker_kind == .help)
        try input_presentation.composeHelpMenuHintRow(alloc, shell.layout.cols, ctx.ctrl_c_pending)
    else if (input.show_picker and input.picker_kind == .sessions)
        try input_presentation.composeResumeMenuHintRow(alloc, shell.layout.cols, ctx.ctrl_c_pending)
    else if (input.show_picker and input.picker_kind == .models)
        try input_presentation.composeModelsMenuHintRow(alloc, shell.layout.cols, ctx.ctrl_c_pending)
    else if (input.show_picker and input.picker_kind == .slash and input.slash_menu_layout != null)
        try input_presentation.composeSlashMenuHintRow(alloc, shell.layout.cols)
    else blk: {
        danger_status_visible = input_presentation.dangerStatusText(
            approval_active,
            ctx,
            shell.layout.cols,
        ).len > 0;
        break :blk try input_presentation.composeHintRow(
            alloc,
            approval_active,
            ctx,
            shell.layout.cols,
        );
    };
    frame.danger_status_visible = danger_status_visible;
    try pushFooterBandRow(alloc, &frame, plan, rows.hint, &hint_row);

    frame.cursor = .{ .row = cursor_row, .col = cursor_col };
    if (!input.input_visible) frame.cursor_visible = false;
    return frame;
}

fn composeTranscriptViewerFooterFrame(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    input: FooterPlannerInput,
    plan: PaintPlan,
) !footer_viewport.ComposedFooterFrame {
    var frame = footer_viewport.ComposedFooterFrame{};
    errdefer frame.deinit(alloc);
    const width = shell.layout.cols;
    const navigation = switch (input.ctx.transcript_depth) {
        .full => "full detail · ctrl+o close · pgup/pgdn scroll · esc close",
        .inline_mode => unreachable,
    };

    var navigation_row: std.ArrayList(u8) = .empty;
    try navigation_row.appendSlice(alloc, user_message_card.promptMarkerStyle());
    try row_text.appendClipped(alloc, &navigation_row, "┃", width);
    try navigation_row.appendSlice(alloc, ui_render.reset_style);
    if (width > 1) {
        try navigation_row.append(alloc, ' ');
        try navigation_row.appendSlice(alloc, ui_render.statusline_style);
        try row_text.appendSingleLineEllipsized(alloc, &navigation_row, navigation, width - 2);
        try navigation_row.appendSlice(alloc, ui_render.reset_style);
    }
    try pushFooterBandRow(
        alloc,
        &frame,
        plan,
        plan.footer.top_divider,
        &navigation_row,
    );

    var gap_row: std.ArrayList(u8) = .empty;
    try pushFooterBandRow(
        alloc,
        &frame,
        plan,
        plan.footer.bottom_divider,
        &gap_row,
    );

    var status_row = try input_presentation.composeHintRow(
        alloc,
        false,
        input.ctx,
        width,
    );
    try pushFooterBandRow(
        alloc,
        &frame,
        plan,
        plan.footer.hint,
        &status_row,
    );

    frame.cursor = .{ .row = plan.footer.hint, .col = 1 };
    frame.cursor_visible = false;
    return frame;
}

fn composeComposerTopDividerRow(
    alloc: Allocator,
    width: u16,
) !std.ArrayList(u8) {
    return row_text.composeDividerRow(alloc, width);
}

fn composeAndPushVisibleInputRows(
    alloc: Allocator,
    frame: *footer_viewport.ComposedFooterFrame,
    plan: PaintPlan,
    base_row: u16,
    summary: visual_layout.Summary,
    window: visual_layout.VisibleWindow,
    source: visual_layout.Source,
    inline_completion_suffix: []const u8,
) !InputCursorPlacement {
    const visible_count_u16: u16 = @intCast(@min(window.row_count, std.math.maxInt(u16)));
    var placement = InputCursorPlacement{ .row = base_row, .col = visual_layout.terminalColumn(summary.cursor, source.terminal_cols) };
    if (summary.cursor.row_index >= window.first_row and summary.cursor.row_index < window.first_row + window.row_count) {
        const cursor_index: u16 = @intCast(summary.cursor.row_index - window.first_row);
        placement.row = base_row - (visible_count_u16 - 1 - cursor_index);
    }

    var rows = try input_presentation.composeVisibleInputRows(alloc, source, window);
    defer rows.deinit(alloc);
    if (inline_completion_suffix.len > 0 and
        summary.cursor.row_index >= window.first_row and
        summary.cursor.row_index < window.first_row + window.row_count)
    {
        const cursor_index = summary.cursor.row_index - window.first_row;
        try input_presentation.appendInlineCompletionSuffix(
            alloc,
            &rows.rows.items[cursor_index],
            source.terminal_cols,
            inline_completion_suffix,
        );
    }

    var line_idx: u16 = 0;
    for (rows.rows.items) |*input_row| {
        const row = base_row - (visible_count_u16 - 1 - line_idx);
        try pushFooterBandRow(alloc, frame, plan, row, input_row);
        line_idx += 1;
    }
    return placement;
}

fn pushFooterBandRow(
    alloc: Allocator,
    frame: *footer_viewport.ComposedFooterFrame,
    plan: PaintPlan,
    row: u16,
    text: *std.ArrayList(u8),
) !void {
    if (!plan.footer_band.isEmpty() and !plan.footer_band.containsRow(row)) {
        text.deinit(alloc);
        text.* = .empty;
        return;
    }
    try frame.pushComposedRow(alloc, row, text);
}

fn composeFileApprovalFooterFrame(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    input: FooterPlannerInput,
    plan: PaintPlan,
    request: permission_request.FileApprovalRequest,
) !footer_viewport.ComposedFooterFrame {
    var frame = footer_viewport.ComposedFooterFrame{};
    errdefer frame.deinit(alloc);

    try pushSteeringRows(alloc, &frame, plan, input.ctx, shell.layout.cols);

    const profile_top = plan.footer.top_divider;
    const allocated_rows = plan.footer.hint - profile_top + 1;
    const projection = approval_ui.projectFileApproval(request, input.approval.?.choice_index, shell.layout.cols, allocated_rows);
    for (projection.slice(), 0..) |kind, row_index| {
        var row = try approval_ui.composeFileApprovalRow(
            alloc,
            request,
            &projection,
            input.approval.?.choice_index,
            input.approval,
            shell.layout.cols,
            kind,
        );
        try pushFooterBandRow(alloc, &frame, plan, profile_top + @as(u16, @intCast(row_index)), &row);
    }

    frame.cursor = .{ .row = plan.footer.hint, .col = 1 };
    frame.cursor_visible = false;
    return frame;
}

fn pushQuestionPanelRows(
    alloc: Allocator,
    frame: *footer_viewport.ComposedFooterFrame,
    plan: PaintPlan,
    start_row: u16,
    row_count: u16,
    projection: question_state.Projection,
    width: u16,
) !void {
    const text = try question_ui.composeQuestionPanelText(alloc, projection, width);
    defer alloc.free(text);

    var line_start: usize = 0;
    var row_index: u16 = 0;
    while (row_index < row_count) : (row_index += 1) {
        const line = question_ui.nextPanelLine(text, &line_start);
        var row: std.ArrayList(u8) = .empty;
        try row_text.appendClipped(alloc, &row, line, width);
        try row.appendSlice(alloc, ui_render.reset_style);
        try pushFooterBandRow(alloc, frame, plan, start_row + row_index, &row);
    }
}

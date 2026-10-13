const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const approval_prompt = @import("../../core/permissions/approval_prompt.zig");
const file_index = @import("../../core/workspace/file_index.zig");
const types = @import("../../core/shared/types.zig");
const activity_runtime = @import("../../core/output/activity_runtime.zig");
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
const surface_invalidation = @import("surface_invalidation.zig");
const footer_paint_plan = @import("paint_plan.zig");
const visual_layout = @import("../input/visual_layout.zig");
const render_engine = @import("../render_engine.zig");
const render_request = @import("../render_request.zig");
const transcript_runtime = @import("../transcript/runtime.zig");

const Allocator = std.mem.Allocator;
const activity_overlay = render_engine.activity_overlay;
const footer_layout = render_engine.footer_layout;
const paint_plan = render_engine.paint_plan;
const ActivityProjection = activity_runtime.ActivityProjection;
const ActivityPlacement = activity_overlay.ActivityPlacement;
const FooterRows = footer_layout.FooterRows;
const FrameInvalidationSet = paint_plan.FrameInvalidationSet;
const PaintPlan = paint_plan.PaintPlan;
const ApprovalProjection = approval_prompt.Projection;
const PickerKind = input_presentation.PickerKind;
const RenderContext = render_input.RenderContext;
const FooterPlannerInput = footer_paint_plan.FooterPlannerInput;
const FooterTranscriptState = footer_paint_plan.FooterTranscriptState;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;

pub const SurfaceFooterFrame = struct {
    paint: PaintPlan,
    composed: footer_viewport.ComposedFooterFrame,
    activity_label: std.ArrayList(u8) = .empty,
    tool_activity_label: std.ArrayList(u8) = .empty,
    shimmer_pos: i16 = -render_request.animation_padding,
    thinking_blink: ?bool = null,
    trace_paint_frame: bool = false,

    pub fn deinit(self: *SurfaceFooterFrame, alloc: Allocator) void {
        self.composed.deinit(alloc);
        self.activity_label.deinit(alloc);
        self.tool_activity_label.deinit(alloc);
    }

    pub fn label(self: *const SurfaceFooterFrame) []const u8 {
        return self.activity_label.items;
    }

    pub fn toolLabel(self: *const SurfaceFooterFrame) ?[]const u8 {
        return if (self.tool_activity_label.items.len > 0) self.tool_activity_label.items else null;
    }
};

const FooterSurfaceProjectionMode = enum {
    measurement,
    reservation,
    frame,
};

const FooterSurfaceActivity = struct {
    projection: ActivityProjection,
    active_label: ?[]const u8,

    fn resolve(
        buf: []u8,
        shell: *TranscriptRuntime,
        approval: ?ApprovalProjection,
        ctx: RenderContext,
    ) FooterSurfaceActivity {
        const projection = render_input.frameOwnedActivityProjection(buf, shell, ctx, approval);
        return .{
            .projection = projection,
            .active_label = render_input.activityProjectionLabel(projection),
        };
    }
};

const FooterSurfaceProjection = struct {
    active_label: ?[]const u8,
    activity_projection: ActivityProjection,
    input_display: []const u8,
    input_cursor: usize,
    input_summary: visual_layout.Summary,
    input_window: visual_layout.VisibleWindow,
    input_extra: u16,
    input_visible: bool,
    composer_top_chrome_rows: u16,
    picker_rows: u16,
    top_gap_rows: u16,
    footer_gap_active: bool,
    banner_active: bool,
    banner_rows: u16,
    footer_extra: u16,
    total_lines: u16,
    show_picker: bool,
    picker_kind: PickerKind,
    picker_items: []const []const u8,
    picker_annotations: []const []const u8,
    file_picker_items: []const file_index.SearchResult,
    picker_selection_index: usize,
    picker_window_start: usize,
    picker_loading: bool,
    picker_failed: bool,
    slash_completion_count: usize,
    slash_menu_layout: ?picker_presentation.SlashMenuLayout,
    prepared_slash_menu: picker_presentation.PreparedSlashMenu,
    picker_start_col: u16,
    file_approval_active: bool,
    allocated_rows: ?u16,

    fn deinit(self: *FooterSurfaceProjection, alloc: Allocator) void {
        self.prepared_slash_menu.deinit(alloc);
    }

    fn takePreparedSlashMenu(self: *FooterSurfaceProjection) picker_presentation.PreparedSlashMenu {
        const prepared = self.prepared_slash_menu;
        self.prepared_slash_menu = .{};
        return prepared;
    }

    fn framePlannerInput(
        self: *const FooterSurfaceProjection,
        ctx: RenderContext,
        approval: ?ApprovalProjection,
        place_mid_line_active: bool,
        applied_bottom_reserved_rows: u16,
        transcript_state: ?FooterTranscriptState,
    ) FooterPlannerInput {
        return .{
            .active_label = self.active_label,
            .activity_projection = self.activity_projection,
            .ctx = ctx,
            .place_mid_line_active = place_mid_line_active,
            .input_extra = self.input_extra,
            .input_visible = self.input_visible,
            .composer_top_chrome_rows = self.composer_top_chrome_rows,
            .picker_rows = self.picker_rows,
            .footer_gap_active = self.footer_gap_active,
            .banner_active = self.banner_active,
            .banner_rows = self.banner_rows,
            .footer_extra_rows = self.footer_extra,
            .allocated_rows = self.allocated_rows,
            .applied_bottom_reserved_rows = applied_bottom_reserved_rows,
            .approval = approval,
            .input_display = self.input_display,
            .input_cursor = self.input_cursor,
            .input_summary = self.input_summary,
            .input_window = self.input_window,
            .total_lines = self.total_lines,
            .show_picker = self.show_picker,
            .picker_kind = self.picker_kind,
            .picker_items = self.picker_items,
            .picker_annotations = self.picker_annotations,
            .file_picker_items = self.file_picker_items,
            .picker_selection_index = self.picker_selection_index,
            .picker_window_start = self.picker_window_start,
            .picker_loading = self.picker_loading,
            .picker_failed = self.picker_failed,
            .slash_completion_count = self.slash_completion_count,
            .slash_menu_layout = self.slash_menu_layout,
            .prepared_slash_menu = if (self.picker_kind == .slash) &self.prepared_slash_menu else null,
            .picker_start_col = self.picker_start_col,
            .transcript_state = transcript_state,
        };
    }

    fn reservationPlannerInput(
        self: *const FooterSurfaceProjection,
        ctx: RenderContext,
        place_mid_line_active: bool,
        applied_bottom_reserved_rows: u16,
        transcript_state: FooterTranscriptState,
    ) FooterPlannerInput {
        return .{
            .active_label = self.active_label,
            .activity_projection = self.activity_projection,
            .ctx = ctx,
            .place_mid_line_active = place_mid_line_active,
            .input_extra = self.input_extra,
            .input_visible = self.input_visible,
            .composer_top_chrome_rows = self.composer_top_chrome_rows,
            .picker_rows = self.picker_rows,
            .slash_completion_count = self.slash_completion_count,
            .banner_active = self.banner_active,
            .banner_rows = self.banner_rows,
            .allocated_rows = self.allocated_rows,
            .applied_bottom_reserved_rows = applied_bottom_reserved_rows,
            .transcript_state = transcript_state,
        };
    }
};

fn steeringBannerRowsForLayout(
    ctx: RenderContext,
    terminal_cols: u16,
    terminal_rows: u16,
    input_visible: bool,
    composer_top_chrome_rows: u16,
    input_extra: u16,
) u16 {
    const requested = render_input.steeringBannerRows(ctx, terminal_cols);
    return clampSteeringBannerRows(
        requested,
        terminal_rows,
        input_visible,
        composer_top_chrome_rows,
        input_extra,
    );
}

pub fn clampSteeringBannerRows(
    requested: u16,
    terminal_rows: u16,
    input_visible: bool,
    composer_top_chrome_rows: u16,
    input_extra: u16,
) u16 {
    if (requested == 0) return 0;
    const non_banner_rows: u16 = if (input_visible)
        footer_layout.reservedBaseRows(true, composer_top_chrome_rows) +| 1 +| input_extra
    else
        3;
    return @min(requested, terminal_rows -| non_banner_rows);
}

fn buildFooterSurfaceProjection(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    approval: ?ApprovalProjection,
    ctx: RenderContext,
    activity: FooterSurfaceActivity,
    mode: FooterSurfaceProjectionMode,
) !FooterSurfaceProjection {
    const viewer_active = ctx.transcript_depth.active();
    const activity_projection: ActivityProjection = if (viewer_active) .none else activity.projection;
    const active_label = if (viewer_active) null else activity.active_label;
    const approval_active = approval != null;
    const question_projection = switch (mode) {
        .reservation => null,
        .measurement, .frame => if (!viewer_active and !approval_active) ctx.question else null,
    };
    const compact_command_menu = if (!viewer_active and !approval_active and question_projection == null)
        render_input.activeCompactCommandMenu(ctx)
    else
        null;
    const compact_command_active = compact_command_menu != null;
    const modal_active = !viewer_active and switch (mode) {
        .reservation => approval_active or compact_command_active,
        .measurement, .frame => approval_active or question_projection != null or compact_command_active,
    };
    const input_visible = ctx.composer_visible and !modal_active and !viewer_active;
    const composer_top_chrome_rows = footer_paint_plan.composerTopChromeRows();
    const show_auth_picker = !viewer_active and !modal_active and !ctx.stream.active and ctx.auth_picker.active;
    const show_settings_menu = !viewer_active and !show_auth_picker and !modal_active and ctx.settings_menu.active;
    const show_help_menu = !viewer_active and !show_auth_picker and !show_settings_menu and !modal_active and ctx.help_menu.active;
    const show_session_menu = !viewer_active and !show_auth_picker and !show_settings_menu and !show_help_menu and !modal_active and ctx.session_menu.active;
    const show_models_menu = !viewer_active and !show_auth_picker and !show_settings_menu and !show_help_menu and !show_session_menu and !modal_active and ctx.model_menu.active;
    const show_inline_catalog = show_settings_menu or show_help_menu or show_session_menu or show_models_menu;
    const show_skills_query = !viewer_active and !show_auth_picker and !show_inline_catalog and !modal_active and ctx.skills_menu.active;
    const show_model_query = !viewer_active and !show_auth_picker and !show_inline_catalog and !show_skills_query and !modal_active and
        ctx.model_query_active;
    const show_provider_query = !viewer_active and !show_auth_picker and !show_inline_catalog and !show_skills_query and !modal_active and !ctx.stream.active and
        ctx.provider_query_active and !show_model_query;
    const show_file_query = !viewer_active and !show_inline_catalog and !show_skills_query and !modal_active and ctx.file_query_active and !show_model_query and !show_provider_query;
    const prepared_slash_prefix = if (!show_auth_picker and
        !show_inline_catalog and
        !show_skills_query)
        input_presentation.slashCompletionPickerPrefix(
            ctx,
            modal_active,
            show_model_query,
            show_provider_query or show_file_query,
        )
    else
        null;
    var prepared_slash_menu = if (prepared_slash_prefix) |prefix|
        try picker_presentation.prepareSlashMenu(
            alloc,
            ctx.slash_registry,
            prefix,
            ctx.skills_menu.items,
        )
    else
        picker_presentation.PreparedSlashMenu{};
    errdefer prepared_slash_menu.deinit(alloc);
    const geometry = input_presentation.measureRawInputGeometryPreparedWithProvider(
        ctx,
        shell.layout.cols,
        shell.layout.content_bottom,
        input_visible,
        modal_active,
        show_model_query,
        show_provider_query,
        show_file_query,
        if (prepared_slash_prefix != null) prepared_slash_menu.resultCount() else null,
    );
    const show_slash_query = prepared_slash_prefix != null and geometry.show_slash_query;
    const show_picker = show_auth_picker or show_inline_catalog or show_skills_query or show_model_query or show_provider_query or show_file_query or show_slash_query;
    const picker_items: []const []const u8 = if (show_model_query)
        ctx.model_completions
    else if (show_provider_query)
        ctx.provider_picker_completions
    else
        &.{};
    const picker_annotations: []const []const u8 = if (show_provider_query) ctx.provider_picker_annotations else &.{};
    const file_picker_items: []const file_index.SearchResult = if (show_file_query) ctx.file_completions else &.{};
    const picker_selection_index: usize = if (show_skills_query)
        ctx.skills_menu.selected_index
    else if (show_slash_query)
        ctx.input.picker.slash_completion_index
    else if (show_auth_picker)
        ctx.auth_picker.selectedIndex()
    else if (show_model_query)
        ctx.model_completion_index
    else if (show_provider_query)
        ctx.provider_picker_completion_index
    else if (show_file_query)
        ctx.file_completion_index
    else
        0;
    const picker_window_start: usize = if (show_skills_query)
        ctx.skills_menu.window_start
    else if (show_slash_query)
        ctx.input.picker.slash_completion_window_start
    else if (show_model_query)
        ctx.model_completion_window_start
    else if (show_provider_query)
        ctx.provider_picker_completion_window_start
    else if (show_file_query)
        ctx.file_completion_window_start
    else
        0;
    const picker_loading: bool = if (show_model_query)
        ctx.model_completions_loading
    else if (show_file_query)
        ctx.file_completions_loading
    else
        false;
    const picker_failed: bool = if (show_model_query)
        ctx.model_completions_failed
    else if (show_file_query)
        ctx.file_completions_failed
    else
        false;
    const picker_kind: PickerKind = if (show_skills_query)
        .skills
    else if (show_settings_menu)
        .settings
    else if (show_help_menu)
        .help
    else if (show_session_menu)
        .sessions
    else if (show_models_menu)
        .models
    else if (show_slash_query)
        .slash
    else if (show_auth_picker)
        .auth
    else if (show_model_query)
        .model_stage
    else if (show_provider_query)
        .provider_stage
    else if (show_file_query)
        .file
    else
        .model_stage;
    const sizing_request = if (approval) |value| value.request else null;
    const file_request = if (sizing_request) |request| request.file else null;
    const banner_rows = if (viewer_active) 0 else steeringBannerRowsForLayout(
        ctx,
        shell.layout.cols,
        shell.layout.rows,
        input_visible,
        composer_top_chrome_rows,
        geometry.input_extra,
    );
    const banner_active = switch (mode) {
        .reservation => modal_active or banner_rows > 0,
        .measurement, .frame => banner_rows > 0,
    };
    const list_picker_rows = picker_presentation.activeListPickerReservedRows(
        shell.layout.rows,
        geometry.input_extra,
        banner_rows,
    );
    const slash_menu_layout = if (show_slash_query)
        picker_presentation.preparedSlashMenuLayout(
            &prepared_slash_menu,
            picker_selection_index,
            picker_window_start,
            shell.layout.rows,
            geometry.input_extra,
            banner_rows,
        )
    else
        null;
    const inline_picker_row_budget = picker_presentation.inlinePickerRowBudget(
        shell.layout.rows,
        geometry.input_extra,
        banner_rows,
    );
    const expanded_picker_row_budget = picker_presentation.inlinePickerRowBudgetCapped(
        shell.layout.rows,
        geometry.input_extra,
        banner_rows,
        resume_menu_presentation.max_inline_rows,
    );
    const settings_picker_row_budget = picker_presentation.inlinePickerRowBudgetCapped(
        shell.layout.rows,
        geometry.input_extra,
        banner_rows,
        settings_menu_presentation.max_inline_rows,
    );
    const models_picker_row_budget = picker_presentation.inlinePickerRowBudgetCapped(
        shell.layout.rows,
        geometry.input_extra,
        banner_rows,
        model_menu_presentation.max_inline_rows,
    );
    const picker_rows: u16 = if (sizing_request) |request|
        if (request.file) |request_file|
            approval_ui.fileApprovalPickerRows(request_file)
        else
            try inlineApprovalPanelRowsForRequest(
                alloc,
                request,
                shell.layout.cols,
                shell.layout.rows,
            )
    else if (question_projection) |projection|
        try question_ui.questionPanelRowsForLayout(alloc, projection, shell.layout.cols)
    else if (compact_command_menu) |menu|
        @min(
            compact_command_menu_presentation.desiredRowCount(
                menu,
                shell.layout.cols,
            ),
            shell.layout.rows -| 3,
        )
    else if (show_auth_picker)
        picker_presentation.authPickerReservedRows(
            ctx.auth_picker,
            shell.layout.rows,
            geometry.input_extra,
            banner_rows,
        )
    else if (show_settings_menu)
        settings_menu_presentation.menuRowCount(
            ctx.settings_menu,
            shell.layout.cols,
            settings_picker_row_budget,
        )
    else if (show_help_menu)
        help_menu_presentation.menuRowCount(
            ctx.help_menu,
            shell.layout.cols,
            expanded_picker_row_budget,
        )
    else if (show_session_menu)
        resume_menu_presentation.menuRowCount(
            ctx.session_menu,
            shell.layout.cols,
            expanded_picker_row_budget,
        )
    else if (show_models_menu)
        model_menu_presentation.menuRowCount(
            ctx.model_menu,
            shell.layout.cols,
            models_picker_row_budget,
        )
    else if (show_skills_query)
        skills_menu_presentation.inlineMenuRowCount(
            ctx.skills_menu,
            inline_picker_row_budget,
        )
    else if (slash_menu_layout) |layout|
        layout.row_count
    else if (show_picker)
        list_picker_rows
    else
        0;
    const allocated_rows: ?u16 = switch (mode) {
        .measurement => null,
        .reservation, .frame => if (file_request) |request|
            approval_ui.fileApprovalDesiredRows(request.preview) +| banner_rows
        else
            null,
    };
    const picker_extra: u16 = if (modal_active) picker_rows else if (show_picker) picker_rows + 1 else 0;
    return .{
        .active_label = active_label,
        .activity_projection = activity_projection,
        .input_display = ctx.input.edit_state.input.items,
        .input_cursor = ctx.input.edit_state.cursor,
        .input_summary = geometry.summary,
        .input_window = geometry.window,
        .input_extra = geometry.input_extra,
        .input_visible = input_visible,
        .composer_top_chrome_rows = composer_top_chrome_rows,
        .picker_rows = picker_rows,
        .top_gap_rows = if (viewer_active or modal_active) 1 else 0,
        .footer_gap_active = !viewer_active and (modal_active or ctx.steering_messages.len > 0),
        .banner_active = banner_active,
        .banner_rows = banner_rows,
        .footer_extra = geometry.input_extra + banner_rows + picker_extra,
        .total_lines = geometry.total_lines,
        .show_picker = show_picker,
        .picker_kind = picker_kind,
        .picker_items = picker_items,
        .picker_annotations = picker_annotations,
        .file_picker_items = file_picker_items,
        .picker_selection_index = picker_selection_index,
        .picker_window_start = picker_window_start,
        .picker_loading = picker_loading,
        .picker_failed = picker_failed,
        .slash_completion_count = geometry.slash_completion_count,
        .slash_menu_layout = slash_menu_layout,
        .prepared_slash_menu = prepared_slash_menu,
        .picker_start_col = geometry.picker_start_col,
        .file_approval_active = file_request != null,
        .allocated_rows = allocated_rows,
    };
}

fn appendActivityLabels(
    alloc: Allocator,
    primary: *std.ArrayList(u8),
    tool: *std.ArrayList(u8),
    projection: ActivityProjection,
    ctx: RenderContext,
    cols: u16,
) !void {
    var primary_buf: [256]u8 = undefined;
    try primary.appendSlice(alloc, render_input.activityFallbackLabel(&primary_buf, projection, ctx));
    try render_input.appendActivityToolLabel(alloc, tool, projection, cols);
}

const FooterFrameTraceInput = struct {
    rows: FooterRows,
    activity: ActivityPlacement,
    footer_clean_allowed: bool,
    activity_projection: ActivityProjection,
    force_redraw: bool,
};

fn recordFooterFrameTrace(
    shell: *TranscriptRuntime,
    ctx: RenderContext,
    input: FooterFrameTraceInput,
) bool {
    const activity_kind_id: u8 = switch (input.activity) {
        .none => 0,
        .transient_row => 1,
        .overlay_entry => 2,
    };
    const trace_external_invalid = !input.footer_clean_allowed and
        shell.paint_trace.transcript_log_frame;
    const footer_trace_frame = !shell.paint_trace.footer_initialized or
        shell.paint_trace.footer_top != input.rows.top or
        shell.paint_trace.footer_input_base != input.rows.input_base or
        shell.paint_trace.footer_hint != input.rows.hint or
        shell.paint_trace.footer_activity_row != input.activity.row() or
        shell.paint_trace.footer_activity_reserved != input.activity.reservedFooterRows() or
        shell.paint_trace.footer_activity_kind != activity_kind_id or
        trace_external_invalid;
    shell.paint_trace.footer_initialized = true;
    shell.paint_trace.footer_top = input.rows.top;
    shell.paint_trace.footer_input_base = input.rows.input_base;
    shell.paint_trace.footer_hint = input.rows.hint;
    shell.paint_trace.footer_activity_row = input.activity.row();
    shell.paint_trace.footer_activity_reserved = input.activity.reservedFooterRows();
    shell.paint_trace.footer_activity_kind = activity_kind_id;

    if (footer_trace_frame) {
        const activity_kind: []const u8 = switch (input.activity) {
            .none => "none",
            .transient_row => "transient",
            .overlay_entry => "overlay_entry",
        };
        var fallback_label_buf: [256]u8 = undefined;
        const label = render_input.activityFallbackLabel(&fallback_label_buf, input.activity_projection, ctx);
        debug_trace.logf(
            "frame_plan",
            "footer_layout top={d} top_divider={d} input_base={d} bottom_divider={d} hint={d} activity_kind={s} activity_row={d} activity_reserved={d} force_redraw={s} external_invalid={s} cursor={d},{d} label_bytes={d} label_hash={x}",
            .{
                input.rows.top,
                input.rows.top_divider,
                input.rows.input_base,
                input.rows.bottom_divider,
                input.rows.hint,
                activity_kind,
                input.activity.row() orelse 0,
                input.activity.reservedFooterRows(),
                if (input.force_redraw) "true" else "false",
                if (!input.footer_clean_allowed) "true" else "false",
                shell.cursor_row,
                shell.cursor_col,
                label.len,
                std.hash.Wyhash.hash(0, label),
            },
        );
    }

    return footer_trace_frame;
}

const SurfaceFooterFrameAssembly = struct {
    paint: PaintPlan,
    planner_input: FooterPlannerInput,
    activity_projection: ActivityProjection,
    trace_paint_frame: bool,
};

fn assembleSurfaceFooterFrame(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    assembly: SurfaceFooterFrameAssembly,
) !SurfaceFooterFrame {
    var paint = assembly.paint;
    var composed = try footer_paint_plan.composeFooterFrame(
        alloc,
        shell,
        assembly.planner_input,
        paint,
    );
    errdefer composed.deinit(alloc);
    if (paint.cursor_target) |cursor| {
        paint.cursor_target = .{
            .row = composed.cursor.row,
            .col = composed.cursor.col,
            .visible = cursor.visible,
        };
    }
    try paint.validate();

    var activity_label: std.ArrayList(u8) = .empty;
    errdefer activity_label.deinit(alloc);
    var tool_activity_label: std.ArrayList(u8) = .empty;
    errdefer tool_activity_label.deinit(alloc);
    try appendActivityLabels(
        alloc,
        &activity_label,
        &tool_activity_label,
        assembly.activity_projection,
        assembly.planner_input.ctx,
        shell.layout.cols,
    );

    return .{
        .paint = paint,
        .composed = composed,
        .activity_label = activity_label,
        .tool_activity_label = tool_activity_label,
        .shimmer_pos = assembly.planner_input.ctx.shimmer_pos,
        .thinking_blink = render_input.frameActivityBlink(assembly.planner_input.ctx),
        .trace_paint_frame = assembly.trace_paint_frame,
    };
}

pub fn retargetSurfaceFooterFrame(frame: *SurfaceFooterFrame, requested_plan: PaintPlan) void {
    var plan = requested_plan;
    const old_footer = frame.paint.footer;
    for (frame.composed.rows.items) |*row| {
        row.row = retargetFooterRow(row.row, old_footer, plan.footer);
    }
    frame.composed.cursor.row = retargetFooterRow(frame.composed.cursor.row, old_footer, plan.footer);
    if (plan.cursor_target) |cursor| {
        plan.cursor_target = .{
            .row = frame.composed.cursor.row,
            .col = frame.composed.cursor.col,
            .visible = cursor.visible,
        };
    }
    frame.paint = plan;
}

fn retargetFooterRow(row: u16, old_footer: footer_layout.FooterRows, new_footer: footer_layout.FooterRows) u16 {
    if (row < old_footer.top or row > old_footer.hint) return row;
    return new_footer.top + (row - old_footer.top);
}

pub const SurfaceFooterMeasurement = struct {
    active_label: std.ArrayList(u8) = .empty,
    active_label_present: bool = false,
    activity_projection: ActivityProjection = .none,
    input_display_owned: std.ArrayList(u8) = .empty,
    input_display: []const u8 = "",
    input_cursor: usize = 0,
    input_summary: visual_layout.Summary = .{
        .total_rows = 1,
        .cursor = .{ .raw_offset = 0, .row_index = 0, .content_column = 0 },
        .anchor = null,
    },
    input_window: visual_layout.VisibleWindow = .{ .first_row = 0, .row_count = 1 },
    input_extra: u16 = 0,
    input_visible: bool = true,
    composer_top_chrome_rows: u16 = 1,
    picker_rows: u16 = 0,
    top_gap_rows: u16 = 0,
    footer_gap_active: bool = false,
    banner_active: bool = false,
    banner_rows: u16 = 0,
    footer_extra: u16 = 0,
    total_lines: u16 = 1,
    show_picker: bool = false,
    picker_kind: PickerKind = .model_stage,
    picker_items: []const []const u8 = &.{},
    picker_annotations: []const []const u8 = &.{},
    file_picker_items: []const file_index.SearchResult = &.{},
    picker_selection_index: usize = 0,
    picker_window_start: usize = 0,
    picker_loading: bool = false,
    picker_failed: bool = false,
    slash_completion_count: usize = 0,
    slash_menu_layout: ?picker_presentation.SlashMenuLayout = null,
    prepared_slash_menu: picker_presentation.PreparedSlashMenu = .{},
    picker_start_col: u16 = 1,
    file_approval_active: bool = false,

    pub fn deinit(self: *SurfaceFooterMeasurement, alloc: Allocator) void {
        self.active_label.deinit(alloc);
        self.input_display_owned.deinit(alloc);
        self.prepared_slash_menu.deinit(alloc);
    }

    fn activeLabel(self: *const SurfaceFooterMeasurement) ?[]const u8 {
        return render_input.activityProjectionLabel(self.activity_projection);
    }

    pub fn changesFooterReservation(self: *const SurfaceFooterMeasurement, shell: *const TranscriptRuntime) bool {
        return self.footer_extra != shell.extra_input_rows or
            self.footerReservedBaseRows() != shell.footer_reserved_base_rows;
    }

    pub fn replaysDisplacedTranscriptHistory(
        self: *const SurfaceFooterMeasurement,
        shell: *const TranscriptRuntime,
    ) bool {
        const measured_rows = @as(u32, self.footer_extra) +
            @as(u32, self.footerReservedBaseRows());
        const committed_rows = @as(u32, shell.extra_input_rows) +
            @as(u32, shell.footer_reserved_base_rows);
        return measured_rows > committed_rows;
    }

    pub fn frameInvalidationUpdate(self: *const SurfaceFooterMeasurement) surface_invalidation.FooterExtraUpdate {
        return .{
            .footer_extra = self.footer_extra,
            .footer_reserved_base_rows = self.footerReservedBaseRows(),
            .input_extra = self.input_extra,
            .banner_active = self.banner_active,
            .picker_rows = self.picker_rows,
            .show_picker = self.show_picker,
        };
    }

    pub noinline fn footerReservedBaseRows(self: *const SurfaceFooterMeasurement) u16 {
        return footer_layout.reservedBaseRows(self.input_visible, self.composer_top_chrome_rows);
    }

    pub noinline fn frameLayoutMeasurement(self: *const SurfaceFooterMeasurement) render_engine.frame_layout.FooterMeasurement {
        const banner_rows: u16 = if (self.banner_rows > 0) self.banner_rows else if (self.banner_active) 1 else 0;
        const picker_block_rows: u16 = if (!self.input_visible)
            self.picker_rows
        else if (self.show_picker)
            self.picker_rows +| 1
        else
            0;
        const input_rows: u16 = if (self.input_visible)
            self.footerReservedBaseRows() +| 1 +| self.input_extra
        else
            3;
        const natural_rows = input_rows +| banner_rows +| picker_block_rows;
        return .{
            .natural_rows = natural_rows,
            .min_rows = 1,
            .max_rows = natural_rows,
            .top_gap_rows = self.top_gap_rows,
            .input_rows = if (self.input_visible) self.total_lines else 0,
            .picker_rows = self.picker_rows,
            .banner_rows = banner_rows,
        };
    }

    pub noinline fn frameLayoutRows(self: *const SurfaceFooterMeasurement, terminal_rows: u16, top: u16) FooterRows {
        const banner_rows: u16 = if (self.banner_rows > 0) self.banner_rows else if (self.banner_active) 1 else 0;
        const natural_rows = self.frameLayoutMeasurement().natural_rows;
        const available_rows = if (top > 0 and top <= terminal_rows)
            terminal_rows - top + 1
        else
            1;
        return footer_layout.resolve(.{
            .footer_top_for_extra = top,
            .terminal_rows = terminal_rows,
            .activity_offset = 0,
            .extra_input_rows = self.footer_extra,
            .input_extra = self.input_extra,
            .input_visible = self.input_visible,
            .composer_top_chrome_rows = self.composer_top_chrome_rows,
            .picker_rows = self.picker_rows,
            .banner_active = self.banner_active,
            .banner_rows = banner_rows,
            .allocated_rows = if (self.file_approval_active)
                @min(natural_rows, available_rows)
            else
                null,
        });
    }

    fn plannerInput(
        self: *const SurfaceFooterMeasurement,
        ctx: RenderContext,
        approval: ?ApprovalProjection,
        place_mid_line_active: bool,
        applied_bottom_reserved_rows: u16,
        transcript_state: ?FooterTranscriptState,
        banner_active: bool,
        input_extra: u16,
        picker_rows: u16,
    ) FooterPlannerInput {
        const banner_rows: u16 = if (self.banner_rows > 0) self.banner_rows else if (banner_active) 1 else 0;
        return .{
            .active_label = self.activeLabel(),
            .activity_projection = self.activity_projection,
            .ctx = ctx,
            .place_mid_line_active = place_mid_line_active,
            .input_extra = input_extra,
            .input_visible = self.input_visible,
            .composer_top_chrome_rows = self.composer_top_chrome_rows,
            .picker_rows = picker_rows,
            .footer_gap_active = self.footer_gap_active,
            .banner_active = banner_active,
            .banner_rows = banner_rows,
            .footer_extra_rows = self.footer_extra,
            .allocated_rows = if (self.file_approval_active)
                self.frameLayoutMeasurement().natural_rows
            else
                null,
            .applied_bottom_reserved_rows = applied_bottom_reserved_rows,
            .approval = approval,
            .input_display = self.input_display,
            .input_cursor = self.input_cursor,
            .input_summary = self.input_summary,
            .input_window = self.input_window,
            .total_lines = self.total_lines,
            .show_picker = self.show_picker,
            .picker_kind = self.picker_kind,
            .picker_items = self.picker_items,
            .picker_annotations = self.picker_annotations,
            .file_picker_items = self.file_picker_items,
            .picker_selection_index = self.picker_selection_index,
            .picker_window_start = self.picker_window_start,
            .picker_loading = self.picker_loading,
            .picker_failed = self.picker_failed,
            .slash_completion_count = self.slash_completion_count,
            .slash_menu_layout = self.slash_menu_layout,
            .prepared_slash_menu = if (self.picker_kind == .slash) &self.prepared_slash_menu else null,
            .picker_start_col = self.picker_start_col,
            .transcript_state = transcript_state,
        };
    }

    fn actualPlannerInput(
        self: *const SurfaceFooterMeasurement,
        ctx: RenderContext,
        approval: ?ApprovalProjection,
        place_mid_line_active: bool,
        applied_bottom_reserved_rows: u16,
        transcript_state: ?FooterTranscriptState,
    ) FooterPlannerInput {
        return self.plannerInput(
            ctx,
            approval,
            place_mid_line_active,
            applied_bottom_reserved_rows,
            transcript_state,
            self.banner_active,
            self.input_extra,
            self.picker_rows,
        );
    }
};

pub fn commandApprovalFitsInline(
    alloc: Allocator,
    label: []const u8,
    command: ?[]const u8,
    layout: types.Layout,
    banner_row_count: usize,
) !bool {
    const picker_rows = try approval_ui.inlineApprovalPanelRowsForCommand(
        alloc,
        label,
        command,
        layout.cols,
        layout.rows,
    );
    const banner_rows: u16 = @intCast(@min(banner_row_count, std.math.maxInt(u16)));
    const measurement = SurfaceFooterMeasurement{
        .input_visible = false,
        .picker_rows = picker_rows,
        .banner_active = banner_rows > 0,
        .banner_rows = banner_rows,
    };
    return measurement.frameLayoutMeasurement().natural_rows <= layout.rows;
}

fn inlineApprovalPanelRowsForRequest(
    alloc: Allocator,
    request: anytype,
    width: u16,
    terminal_rows: u16,
) !u16 {
    return approval_ui.inlineApprovalPanelRowsForCommand(
        alloc,
        request.label,
        request.command,
        width,
        terminal_rows,
    );
}

pub noinline fn measureSurfaceFooter(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    approval: ?ApprovalProjection,
    ctx: RenderContext,
) !SurfaceFooterMeasurement {
    var measurement = SurfaceFooterMeasurement{};
    errdefer measurement.deinit(alloc);

    var active_buf: [256]u8 = undefined;
    const activity = FooterSurfaceActivity.resolve(&active_buf, shell, approval, ctx);
    var projection = try buildFooterSurfaceProjection(
        alloc,
        shell,
        approval,
        ctx,
        activity,
        .measurement,
    );
    defer projection.deinit(alloc);
    switch (projection.activity_projection) {
        .none => {},
        .tool_slot => |slot| {
            var copied = slot;
            if (slot.thinking_label) |label| {
                try measurement.active_label.appendSlice(alloc, label);
                measurement.active_label_present = true;
                copied.thinking_label = measurement.active_label.items;
            }
            measurement.activity_projection = .{ .tool_slot = copied };
        },
        .turn_thinking => |thinking| {
            try measurement.active_label.appendSlice(alloc, thinking.label);
            measurement.active_label_present = true;
            measurement.activity_projection = .{ .turn_thinking = .{
                .label = measurement.active_label.items,
                .tone = thinking.tone,
            } };
        },
    }

    measurement.input_display = projection.input_display;
    measurement.input_cursor = projection.input_cursor;
    measurement.input_summary = projection.input_summary;
    measurement.input_window = projection.input_window;
    measurement.total_lines = projection.total_lines;
    measurement.input_extra = projection.input_extra;
    measurement.composer_top_chrome_rows = projection.composer_top_chrome_rows;
    measurement.slash_completion_count = projection.slash_completion_count;
    measurement.slash_menu_layout = projection.slash_menu_layout;
    measurement.prepared_slash_menu = projection.takePreparedSlashMenu();
    measurement.input_visible = projection.input_visible;
    measurement.show_picker = projection.show_picker;
    measurement.picker_items = projection.picker_items;
    measurement.picker_annotations = projection.picker_annotations;
    measurement.file_picker_items = projection.file_picker_items;
    measurement.picker_selection_index = projection.picker_selection_index;
    measurement.picker_window_start = projection.picker_window_start;
    measurement.picker_loading = projection.picker_loading;
    measurement.picker_failed = projection.picker_failed;
    measurement.picker_kind = projection.picker_kind;
    measurement.picker_start_col = projection.picker_start_col;
    measurement.file_approval_active = projection.file_approval_active;
    measurement.picker_rows = projection.picker_rows;
    measurement.top_gap_rows = projection.top_gap_rows;
    measurement.footer_gap_active = projection.footer_gap_active;
    measurement.banner_active = projection.banner_active;
    measurement.banner_rows = projection.banner_rows;
    if (measurement.footer_gap_active) {
        switch (measurement.activity_projection) {
            .tool_slot => measurement.activity_projection = .none,
            .none, .turn_thinking => {},
        }
    }
    measurement.footer_extra = projection.footer_extra;

    return measurement;
}

pub noinline fn prepareMeasuredSurfaceFooterFrameForPlan(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    force_redraw: *bool,
    approval: ?ApprovalProjection,
    ctx: RenderContext,
    measurement: *const SurfaceFooterMeasurement,
    plan: PaintPlan,
    attempt_invalidations: FrameInvalidationSet,
) !SurfaceFooterFrame {
    var paint = plan;
    const footer_reservation_changed = measurement.changesFooterReservation(shell);
    try surface_invalidation.appendMeasuredFooterExtraInvalidation(
        shell,
        &paint,
        force_redraw,
        measurement.frameInvalidationUpdate(),
    );
    surface_invalidation.mergeAttemptInvalidations(attempt_invalidations, &paint);
    if (footer_reservation_changed) paint.footer_clean_allowed = false;
    try paint.validate();

    const footer_trace_frame = recordFooterFrameTrace(shell, ctx, .{
        .rows = paint.footer,
        .activity = paint.activity,
        .footer_clean_allowed = paint.footer_clean_allowed,
        .activity_projection = measurement.activity_projection,
        .force_redraw = force_redraw.*,
    });

    return assembleSurfaceFooterFrame(alloc, shell, .{
        .paint = paint,
        .planner_input = measurement.actualPlannerInput(
            ctx,
            approval,
            false,
            0,
            null,
        ),
        .activity_projection = measurement.activity_projection,
        .trace_paint_frame = footer_trace_frame,
    });
}

pub fn commitSurfaceFooterFrame(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    frame: *SurfaceFooterFrame,
    measurement: ?*const SurfaceFooterMeasurement,
) void {
    var geometry = footerGeometryForRows(frame.paint.footer, frame.paint.activity);
    if (measurement) |measured| {
        shell.extra_input_rows = measured.footer_extra;
        shell.footer_reserved_base_rows = measured.footerReservedBaseRows();
        const input_row_count: u16 = @intCast(@min(
            measured.input_window.row_count,
            std.math.maxInt(u16),
        ));
        if (measured.input_visible and
            input_row_count > 0 and
            geometry.input_base >= input_row_count)
        {
            geometry.input_first = geometry.input_base - (input_row_count - 1);
            geometry.input_window_first = measured.input_window.first_row;
        }
    }
    shell.footer_viewport.installComposedFrame(
        alloc,
        geometry,
        &frame.composed,
    );
    shell.footer_viewport.trace_paint_frame = frame.trace_paint_frame;
}

pub noinline fn currentSurfaceFooterTranscriptState(shell: *const TranscriptRuntime) FooterTranscriptState {
    return .{
        .selection = footer_paint_plan.currentViewportSelection(shell),
        .cursor_row = shell.cursor_row,
        .cursor_col = shell.cursor_col,
        .replaceable_row = shell.replaceable_row,
        .bottom_reserved_rows = shell.last_paint_bottom_reserved_rows,
    };
}

fn footerGeometryForRows(rows: FooterRows, activity: ActivityPlacement) footer_viewport.Geometry {
    return .{
        .top = rows.top,
        .top_divider = rows.top_divider,
        .input_base = rows.input_base,
        .bottom_divider = rows.bottom_divider,
        .hint = rows.hint,
        .activity_row = activity.row(),
    };
}

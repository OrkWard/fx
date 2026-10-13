const std = @import("std");
const question_prompt = @import("../agent/question_prompt.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const app_commands = @import("app_commands.zig");
const app_lifecycle = @import("app_lifecycle.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const provider_picker_runtime = @import("provider_picker_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const picker_state = @import("../input/picker_state.zig");
const provider_runtime = @import("provider_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const permission_request = @import("../permissions/permission_request.zig");
const types = @import("../shared/types.zig");
const activity_runtime = @import("../output/activity_runtime.zig");
const event_loop = @import("../../ui/event_loop.zig");
const surface_frame = @import("../../ui/footer/surface_frame.zig");
const surface_invalidation = @import("../../ui/footer/surface_invalidation.zig");
const interaction_state = @import("../../ui/footer/interaction_state.zig");
const approval_prompt = @import("../permissions/approval_prompt.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const footer_viewport = @import("../../ui/footer/viewport.zig");
const render_request = @import("../../ui/render_request.zig");
const registered_entities = @import("../input/registered_entities.zig");
const approval_screen = @import("../../ui/approval_screen.zig");
const full_transcript_screen = @import("../../ui/full_transcript_screen.zig");
const session_child_store = @import("../session/session_child_store.zig");
const render_engine = @import("../../ui/render_engine.zig");
const build_checkpoint = @import("../../ui/render_engine/build_checkpoint.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const shimmer_runtime = @import("../../ui/transcript/shimmer_runtime.zig");
const vt_emulator = @import("../terminal/engine.zig");
const transcript_painter = @import("../../ui/transcript/painter.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const ui_render = @import("../../ui/render.zig");
const shared_theme = @import("../shared/theme.zig");
const assistant_pacer = @import("../../ui/assistant/pacer.zig");
const user_message_card = @import("../../ui/assistant/user_message_card.zig");

fn set_transcript_assistant_tail_writable(
    runtime: *transcript_runtime.TranscriptRuntime,
    writable: bool,
) void {
    if (runtime.transcript_release.assistant_tail_writable == writable) return;
    runtime.transcript_release = runtime.transcript_release.with_assistant_tail_writable(writable);
    debug_trace.logf(
        "scroll",
        "assistant tail writability changed writable={s}",
        .{if (writable) "true" else "false"},
    );
}

pub const VisualEpochResetTrigger = enum {
    native_clear_probe,
    ctrl_l,
};

const FrameAttemptResult = struct {
    shadow_state: render_engine.terminal_diff.ShadowCommitState,
    animation_visible: bool,
    yolo_warning_visible: bool = false,
    pending_prompt_presented: bool = false,
    file_picker_receipt: ?input_completion_runtime.FilePickerReceipt = null,

    fn is_committed(self: FrameAttemptResult) bool {
        return self.shadow_state.is_committed();
    }
};

const InlineRenderReconciliation = struct {
    alternate_screen_owns_rendering: bool = false,
    terminal_transition: render_engine.terminal_diff.FrameTerminalTransition = .none,
};

/// Couples the physical terminal buffer with the logical presentation that
/// owns retry invalidations.
const SurfaceFrameShell = struct {
    output: *transcript_runtime.TranscriptRuntime,
    invalidation_owner: *transcript_runtime.TranscriptRuntime,
    shadow_vt: ?*vt_emulator.Grid,
    committed_frame_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
    history_reset_uses_ris: bool,

    fn init(
        output: *transcript_runtime.TranscriptRuntime,
        invalidation_owner: *transcript_runtime.TranscriptRuntime,
        committed_frame_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
    ) SurfaceFrameShell {
        return .{
            .output = output,
            .invalidation_owner = invalidation_owner,
            .shadow_vt = output.shadow_vt,
            .committed_frame_layout = committed_frame_layout,
            .history_reset_uses_ris = output.history_reset_uses_ris,
        };
    }

    pub fn frameSink(
        self: *SurfaceFrameShell,
    ) render_engine.terminal_diff.FrameSink {
        return self.output.frameSink();
    }

    pub fn recordFrameInvalidation(
        self: *SurfaceFrameShell,
        range: render_engine.paint_plan.FrameInvalidationRange,
    ) !void {
        try self.invalidation_owner.recordFrameInvalidation(range);
    }
};

const RenderReconciliation = union(enum) {
    inline_render: InlineRenderReconciliation,
    file_approval_screen,
    frame_result: FrameAttemptResult,
};

const SteeringProjection = struct {
    messages: [][]u8 = &.{},
    pending_feedback: [][]u8 = &.{},
    waits_for_boundary: bool = false,

    fn deinit(self: *SteeringProjection, alloc: std.mem.Allocator) void {
        for (self.messages) |message| alloc.free(message);
        if (self.messages.len > 0) alloc.free(self.messages);
        for (self.pending_feedback) |message| alloc.free(message);
        if (self.pending_feedback.len > 0) alloc.free(self.pending_feedback);
        self.* = .{};
    }
};

const PendingCardProjection = struct {
    bytes: []u8,
    row_count: u16,
    paint_row_count: u16,
    leading_advance_rows: u16,

    fn overlaps_flow_endpoint(self: PendingCardProjection, cursor_col: u16) bool {
        return self.leading_advance_rows == 0 and cursor_col > 1;
    }

    fn deinit(self: *PendingCardProjection, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

const PendingCardPaintContext = struct {
    bytes: []const u8,
    row: u16,
    max_rows: u16,

    fn init(
        card: PendingCardProjection,
        band: render_engine.paint_plan.FrameBand,
        canonical_cursor_row: ?u16,
        activity_visible: bool,
    ) ?PendingCardPaintContext {
        if (band.isEmpty()) return null;
        const row = if (canonical_cursor_row) |base|
            @max(base +| card.leading_advance_rows, band.top)
        else
            band.top;
        if (row > band.bottom) return null;
        const blank_rows: u16 = @intFromBool(activity_visible and band.bottom > row);
        const bottom = band.bottom - blank_rows;
        const max_rows = @min(card.paint_row_count, bottom - row + 1);
        if (max_rows == 0) return null;
        var lines = std.mem.splitScalar(u8, card.bytes, '\n');
        for (0..card.paint_row_count - max_rows) |_| _ = lines.next();
        return .{ .bytes = lines.rest(), .row = row, .max_rows = max_rows };
    }

    fn paint(
        raw: *anyopaque,
        surface: *render_engine.frame_surface.FrameSurface,
    ) anyerror!void {
        const self: *PendingCardPaintContext = @ptrCast(@alignCast(raw));
        _ = try surface.writeAnsiBandNoWrap(
            self.row,
            self.max_rows,
            self.bytes,
            .transcript,
            .same_owner,
        );
    }
};

// A mid-line flow endpoint always takes the canonical user-turn separator,
// even at the content bottom: the frame scrolls to reserve the card rows, so
// the preview starts on a fresh row instead of overwriting the endpoint.
fn pendingCardLeadingAdvanceRows(cursor_col: u16) u16 {
    if (cursor_col == 1) return 0;
    return render_engine.transcript_blocks.blockSeparatorNewlineCount(
        .unknown_raw,
        .user_turn,
    );
}

fn buildPendingCardProjection(
    comptime App: type,
    app: *App,
    presentation_shell: *const transcript_runtime.TranscriptRuntime,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !?PendingCardProjection {
    if (comptime !@hasField(App, "submission")) return null;
    const pending = app.submission.pending orelse return null;
    switch (pending.phase) {
        .awaiting_frame, .awaiting_adoption => {},
        .adopted, .awaiting_auth, .queued => return null,
    }

    const spans = pending.draft.skill_display_spans;
    const skill_tokens: []registered_entities.SkillTokenSpan = if (spans.len == 0)
        &.{}
    else
        try app.alloc.alloc(registered_entities.SkillTokenSpan, spans.len);
    defer if (skill_tokens.len > 0) app.alloc.free(skill_tokens);
    for (spans, 0..) |span, index| {
        skill_tokens[index] = .{
            .raw_start = span.raw_start,
            .raw_end = span.raw_end,
            .name = span.name,
            .path = span.path,
            .display_source = span.display_source,
            .owns_trailing_separator = span.owns_trailing_separator,
        };
    }

    const cursor_row = @min(
        @max(presentation_shell.cursor_row, 1),
        presentation_shell.layout.content_bottom,
    );
    const leading_advance_rows = pendingCardLeadingAdvanceRows(presentation_shell.cursor_col);
    const available_rows = presentation_shell.layout.content_bottom - cursor_row + 1 -| leading_advance_rows;
    const card = try user_message_card.buildUserPromptCardTailForTerminalPresentationInterruptible(
        app.alloc,
        pending.draft.prompt,
        pending.draft.images,
        presentation_shell.layout.cols,
        skill_tokens,
        @max(available_rows, 1),
        checkpoint,
    );
    defer app.alloc.free(card);
    if (card.len == 0) return null;
    const bytes = try pendingCardTerminalWireBytes(app.alloc, card);
    const rendered_line_count: u16 = @intCast(@min(
        std.mem.count(u8, card, "\n"),
        @as(usize, std.math.maxInt(u16)),
    ));
    const paint_row_count = rendered_line_count;
    const row_count = rendered_line_count +| leading_advance_rows;
    if (row_count == 0) {
        app.alloc.free(bytes);
        return error.EmptyPendingPromptCard;
    }
    return .{
        .bytes = bytes,
        .row_count = row_count,
        .paint_row_count = paint_row_count,
        .leading_advance_rows = leading_advance_rows,
    };
}

fn pendingPromptActivityVisible(app: anytype) bool {
    if (comptime !@hasField(@TypeOf(app.*), "submission")) return false;
    const pending = app.submission.pending orelse return false;
    return pending.phase != .awaiting_auth;
}

fn buildPendingSteeringCardProjection(
    alloc: std.mem.Allocator,
    shell: *const transcript_runtime.TranscriptRuntime,
    steering: SteeringProjection,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !?PendingCardProjection {
    const queued_count = if (steering.waits_for_boundary) 0 else steering.messages.len;
    var index = steering.pending_feedback.len + queued_count;
    if (index == 0) return null;

    var card_bytes: std.ArrayList(u8) = .empty;
    defer card_bytes.deinit(alloc);
    var row_count: u16 = 0;
    const row_limit = @max(shell.layout.content_bottom, 1);
    while (index > 0 and row_count < row_limit) {
        index -= 1;
        const message = if (index < steering.pending_feedback.len)
            steering.pending_feedback[index]
        else
            steering.messages[index - steering.pending_feedback.len];
        const gap: u16 = @intFromBool(card_bytes.items.len > 0);
        const remaining_rows = row_limit - row_count -| gap;
        if (remaining_rows == 0) break;
        const card = try user_message_card.buildUserPromptCardTailForTerminalPresentationInterruptible(
            alloc,
            message,
            &.{},
            shell.layout.cols,
            &.{},
            remaining_rows,
            checkpoint,
        );
        defer alloc.free(card);
        if (card.len == 0) continue;
        if (gap > 0) try card_bytes.insert(alloc, 0, '\n');
        try card_bytes.insertSlice(alloc, 0, card);
        row_count += @as(u16, @intCast(std.mem.count(u8, card, "\n"))) + gap;
    }
    if (row_count == 0) return null;
    const leading_rows = pendingCardLeadingAdvanceRows(shell.cursor_col);
    return .{
        .bytes = try pendingCardTerminalWireBytes(alloc, card_bytes.items),
        .row_count = row_count +| leading_rows,
        .paint_row_count = row_count,
        .leading_advance_rows = leading_rows,
    };
}

fn pendingCardTerminalWireBytes(
    alloc: std.mem.Allocator,
    logical: []const u8,
) ![]u8 {
    var logical_end = logical.len;
    if (logical_end > 0 and logical[logical_end - 1] == '\n') logical_end -= 1;
    if (logical_end > 0 and logical[logical_end - 1] == '\r') logical_end -= 1;
    const source = logical[0..logical_end];
    var missing_carriage_returns: usize = 0;
    for (source, 0..) |byte, index| {
        if (byte == '\n' and (index == 0 or source[index - 1] != '\r')) {
            missing_carriage_returns += 1;
        }
    }
    const wire_len = try std.math.add(
        usize,
        source.len,
        missing_carriage_returns,
    );
    const wire = try alloc.alloc(u8, wire_len);
    var written: usize = 0;
    for (source, 0..) |byte, index| {
        if (byte == '\n' and (index == 0 or source[index - 1] != '\r')) {
            wire[written] = '\r';
            written += 1;
        }
        wire[written] = byte;
        written += 1;
    }
    std.debug.assert(written == wire.len);
    return wire;
}

fn previewWithPendingCard(
    preview: render_engine.frame_layout.TranscriptFlowPreview,
    pending: ?PendingCardProjection,
) render_engine.frame_layout.TranscriptFlowPreview {
    const card = pending orelse return preview;
    var next = preview;
    next.natural_visual_rows +|= card.row_count;
    next.cursor_row +|= card.row_count;
    next.cursor_col = 1;
    next.replaceable_row = next.cursor_row;
    next.tail_kind = .user_turn;
    next.replaceable_active = false;
    next.trailing_boundary_blank_rows = 0;
    next.footer_boundary_gap_rows = 0;
    return next;
}

// Every steering slice in the result is owned for one render frame.
fn buildSteeringProjection(comptime App: type, app: *App) !SteeringProjection {
    var projection: SteeringProjection = .{};
    errdefer projection.deinit(app.alloc);
    if (comptime @hasDecl(@TypeOf(app.worker), "snapshotSteeringPresentation")) {
        var snapshot = try app.worker.snapshotSteeringPresentation(app.alloc);
        defer snapshot.deinit(app.alloc);
        projection.waits_for_boundary = snapshot.waits_for_boundary;
        projection.messages = snapshot.messages;
        snapshot.messages = &.{};
        projection.pending_feedback = snapshot.pending_feedback;
        snapshot.pending_feedback = &.{};
    }
    return projection;
}

noinline fn approvalScreenNeedsClear(
    screen_active: bool,
    request: permission_request.PermissionRequest,
    layout: types.Layout,
    commit: ?interaction_state.ApprovalScreenCommit,
) bool {
    if (!screen_active) return true;
    const prior = commit orelse return true;
    return prior.request_id != request.id or
        prior.rows != layout.rows or
        prior.cols != layout.cols;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        fn appendDeferredHistoryForVisualEpoch(
            ctx: *anyopaque,
            finished: *const types.FinishedPrompt,
        ) anyerror!assistant_pacer.DeferredFinishCommit {
            const app: *App = @ptrCast(@alignCast(ctx));
            return switch (try app_session_runtime.Runtime(App).appendFinishedPromptForVisualEpoch(
                app,
                finished.*,
            )) {
                .uncommitted => .uncommitted,
                .committed => .committed,
            };
        }

        pub fn resetVisualEpoch(
            app: *App,
            trigger: VisualEpochResetTrigger,
        ) !bool {
            const welcome = try ui_render.welcomeMessage(app.alloc);
            defer app.alloc.free(welcome);

            const committed = try app.pacer.discardDeferredPresentationForVisualEpoch(
                app.alloc,
                .{
                    .ctx = app,
                    .append_history = appendDeferredHistoryForVisualEpoch,
                },
            );
            if (!committed) {
                switch (trigger) {
                    .native_clear_probe => debug_trace.logf(
                        "native_clear",
                        "native_clear_recovery_skipped reason=history_uncommitted",
                        .{},
                    ),
                    .ctrl_l => debug_trace.logf(
                        "render",
                        "visual_epoch_reset_skipped trigger=ctrl_l reason=history_uncommitted",
                        .{},
                    ),
                }
                return false;
            }

            try app.shell.resetVisualEpoch(app.alloc, welcome);
            try app.shell.requestTerminalReset(&app.metrics);
            switch (trigger) {
                .native_clear_probe => debug_trace.logf(
                    "native_clear",
                    "native_clear_recovery_requested",
                    .{},
                ),
                .ctrl_l => debug_trace.logf(
                    "render",
                    "visual_epoch_reset_requested trigger=ctrl_l",
                    .{},
                ),
            }
            return true;
        }

        pub fn applyThemeUpdate(app: *App, light: bool, rgb: ?ui_render.TerminalRgb) !void {
            if (!ui_render.themeNeedsUpdate(light, rgb)) return;

            // Resolve the target first so the retint rewrites the old theme's
            // escapes into the new theme's, custom pairs included.
            const prior_theme = shared_theme.current();
            var resolved_target: ?shared_theme.Theme = null;
            if (shared_theme.sourceName() orelse ui_render.explicitThemeName()) |name| {
                // Custom themes re-resolve on live flips: sibling swap or
                // builtin fallback, same rule as startup.
                resolved_target = shared_theme.resolveNamed(app.alloc, name, light, .{ .truecolor = ui_render.truecolorIsEnabled() }) catch |err| blk: {
                    debug_trace.logf("theme", "live_theme_resolve_failed name={s} err={s}", .{ name, @errorName(err) });
                    break :blk null;
                };
            }
            const target = resolved_target orelse shared_theme.builtin(light);

            app.shell.retintEntriesForTheme(app.alloc, prior_theme, target) catch |err| {
                debug_trace.logf("theme", "theme_transcript_retint_failed err={s}", .{@errorName(err)});
                return;
            };
            app.pacer.rethemeInlineCode(light);
            if (resolved_target) |resolved| {
                ui_render.applyTheme(resolved, rgb);
            } else {
                ui_render.initTheme(light, rgb);
            }
            app.shell.setCommandOutputRenderPolicy(shellStyles());
            try app.shell.requestTerminalReset(&app.metrics);
            app.shell.render_requests.request(.transcript);
        }

        pub fn shellStyles() transcript_runtime.Styles {
            return .{
                .system_notice_label_style = ui_render.system_notice_label_style,
                .system_notice_text_style = ui_render.system_notice_text_style,
                .reset_style = ui_render.reset_style,
                .dim_style = ui_render.dim_style,
                .red_style = ui_render.red_style,
                .notice_information_style = ui_render.system_notice_label_style,
                .notice_success_style = ui_render.green_style,
                .notice_warning_style = ui_render.warning_style,
                .notice_error_style = ui_render.red_style,
                .notice_cancelled_style = ui_render.dim_style,
                .code_highlight_theme = if (ui_render.is_light) .light else .dark,
            };
        }

        var model_completions_buf: [32][]const u8 = undefined;
        var effort_picker_values_buf: [types.ReasoningEffort.max_options + 1]types.ReasoningEffort = undefined;
        var effort_picker_labels_buf: [types.ReasoningEffort.max_options + 1][]const u8 = undefined;
        var fast_picker_labels_buf: [3][]const u8 = undefined;
        var provider_picker_column: provider_picker_runtime.ColumnBuffer = .{};
        noinline fn footerContext(
            app: *App,
            upgrade_status_buf: *[64]u8,
            shimmer_pos: i16,
            steering: *const SteeringProjection,
        ) render_input.RenderContext {
            const model_query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state);
            const pending_model = if (app.input_runtime.picker.hasPendingModelPickerSelection()) app.input_runtime.picker.model_picker_pending_model.items else null;
            var model_picker_stage: picker_state.ModelPickerStage = .model;
            var picker_items: []const []const u8 = &.{};
            var picker_index: usize = 0;
            var picker_window_start: usize = 0;
            var picker_anchor: usize = 0;

            if (model_query) |picker_query| {
                model_picker_stage = picker_query.stage;
                picker_anchor = picker_query.token_start;
                switch (picker_query.stage) {
                    .model => {
                        const count = input_completion_runtime.CompletionRuntime(App).modelPickerCompletions(app, picker_query.query, &model_completions_buf);
                        picker_items = model_completions_buf[0..count];
                        picker_index = input_completion_runtime.CompletionRuntime(App).modelPickerIndex(app, picker_items);
                        picker_window_start = input_completion_runtime.CompletionRuntime(App).modelPickerWindowStart(app, count, picker_index);
                    },
                    .effort => {
                        const target = if (app.input_runtime.picker.hasPendingModelPickerSelection()) app.input_runtime.picker.model_picker_pending_model.items else provider_runtime.model(app);
                        const capabilities = model_capabilities.resolveForApp(App, app, target);
                        const effort_count = model_capabilities.reasoningEffortOptionCount(capabilities);
                        for (0..effort_count) |i| {
                            effort_picker_values_buf[i] = model_capabilities.reasoningEffortAtIndex(capabilities, i);
                            effort_picker_labels_buf[i] = effort_picker_values_buf[i].displayLabel();
                        }
                        const count = picker_state.filterCompletionLabels(picker_query.query, effort_picker_labels_buf[0..effort_count], effort_picker_labels_buf[0..]);
                        picker_items = effort_picker_labels_buf[0..count];
                        picker_index = app.input_runtime.picker.model_picker_effort_index;
                        picker_window_start = app.input_runtime.picker.model_picker_effort_window_start;
                    },
                    .fast => {
                        const count = input_completion_runtime.CompletionRuntime(App).speedPickerLabels(
                            app,
                            picker_query.query,
                            &fast_picker_labels_buf,
                        );
                        picker_items = fast_picker_labels_buf[0..count];
                        picker_index = input_completion_runtime.CompletionRuntime(App).speedPickerIndex(
                            app,
                            picker_items,
                        );
                        picker_window_start = app.input_runtime.picker.model_picker_fast_window_start;
                    },
                }
            }

            const provider_query = if (model_query == null)
                app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state)
            else
                null;
            var provider_picker_items: []const []const u8 = &.{};
            var provider_picker_annotations: []const []const u8 = &.{};
            var provider_picker_index: usize = 0;
            var provider_picker_window_start: usize = 0;
            var provider_picker_anchor: usize = 0;
            if (provider_query) |picker_query| {
                provider_picker_anchor = picker_query.token_start;
                const count = provider_picker_runtime.Runtime(App).columnOptions(app, picker_query, &provider_picker_column);
                provider_picker_items = provider_picker_column.labels[0..count];
                provider_picker_annotations = provider_picker_column.annotations[0..count];
                provider_picker_index = app.input_runtime.picker.provider_column_index;
                provider_picker_window_start = app.input_runtime.picker.provider_column_window_start;
            }

            const completion_rt = input_completion_runtime.CompletionRuntime(App);
            const file_query = if (model_query == null and provider_query == null and completion_rt.hasFileQuery(app))
                app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state)
            else
                null;
            const file_view = completion_rt.filePickerView(app);
            const file_anchor = if (file_query) |fq| fq.at_offset else 0;
            const file_selection = if (file_view.receipt) |receipt| receipt.selected else null;
            const file_status: ?[]const u8 = switch (file_view.status) {
                .unavailable => if (app.input_runtime.picker.file_completion.indexed)
                    "Files unavailable. tab to retry; esc to dismiss."
                else
                    "Directory unavailable. tab to retry; esc to dismiss.",
                .stale => "Selection unavailable. navigate to choose; tab to retry.",
                .loading, .ready, .empty => null,
            };
            const inline_completion =
                input_completion_runtime.CompletionRuntime(App).visibleInlineCompletion(app);

            const visible_model = pending_model orelse provider_runtime.model(app);
            const visible_capabilities = model_capabilities.resolveForApp(App, app, visible_model);
            const active_capabilities_pending = pending_model == null and app.isModelCacheLoading();
            const model_supports_fast = visible_capabilities.supports_fast_mode;
            const model_supports_effort = visible_capabilities.reasoning_efforts.len > 0 or
                (active_capabilities_pending and !app.effort.isDefault());
            const visible_effort = if (pending_model != null and model_supports_effort)
                pendingPickerEffort(app, visible_model, model_query, app.input_runtime.picker.model_picker_effort_index)
            else if (active_capabilities_pending or model_capabilities.reasoningEffortSupported(visible_capabilities, app.effort))
                app.effort
            else
                .auto;
            const active_fast_mode_model_bound = if (comptime @hasDecl(App, "fastModeModelBound"))
                app.fastModeModelBound()
            else
                true;
            const fast_indicator_active = if (pending_model != null)
                visible_capabilities.intrinsic_fast or
                    (model_supports_fast and pendingPickerFastMode(model_query, app.input_runtime.picker.model_picker_fast_index))
            else
                visible_capabilities.intrinsic_fast or
                    (app.fast_mode and active_fast_mode_model_bound);

            const upgrade_label = app.upgrader.statusLabel(upgrade_status_buf);
            const yolo_warning_active =
                if (comptime @hasField(App, "permission_state") and
                @hasField(App, "permission_engine"))
                    app_permission_runtime.Runtime(App).yoloWarningActive(app)
                else
                    false;
            const settings_snapshot = app_commands.settingsCatalogSnapshot(app);
            const now_ms = io_mod.milliTimestamp();
            var visible_stream = app.stream;
            if (visible_stream.active) {
                const cancel_requested = if (comptime @hasField(App, "worker"))
                    if (comptime @hasDecl(@TypeOf(app.worker), "isCancelRequested"))
                        app.worker.isCancelRequested()
                    else
                        false
                else
                    false;
                if (cancel_requested) {
                    const stops_turn = if (comptime @hasDecl(
                        @TypeOf(app.worker),
                        "cancellationStopsTurn",
                    ))
                        app.worker.cancellationStopsTurn()
                    else
                        true;
                    if (stops_turn) visible_stream.active = false;
                }
            }
            if (!visible_stream.active) {
                if (app.pacer.completedAssistantPresentationTokenProgress()) |progress| {
                    visible_stream.token_progress = progress;
                }
            }

            const statusline = buildStatuslineItems(app, visible_model);

            return .{
                .slash_registry = app.slashRegistry(),
                .stream = visible_stream,
                .compaction = if (comptime @hasDecl(@TypeOf(app.worker), "compactionActivitySnapshot")) app.worker.compactionActivitySnapshot() else .{},
                .pending_prompt_activity = pendingPromptActivityVisible(app),
                .completed_assistant_presentation_tail = app.pacer.hasCompletedAssistantPresentationTail(),
                .writing_response = app.pacer.hasPending(),
                .has_api_key = app.auth.credentialSource() != null,
                .model = visible_model,
                .pending_images = app.pending_images.items,
                .permission_mode = if (comptime @hasField(App, "permission_engine"))
                    app.permission_engine.mode
                else
                    .ask,
                .steering_messages = steering.messages,
                .steering_waits_for_boundary = steering.waits_for_boundary,
                .fast_indicator_active = fast_indicator_active,
                .effort = visible_effort,
                .model_supports_effort = model_supports_effort,
                .ctrl_c_pending = app.input_runtime.gestures.ctrlCExitArmed(),
                .shimmer_pos = shimmer_pos,
                .now_ms = now_ms,
                .model_query_active = model_query != null,
                .model_picker_stage = model_picker_stage,
                .model_completions_loading = if (model_query != null and model_picker_stage == .model) app.isModelCacheLoading() else false,
                .model_completions_failed = if (model_query != null and model_picker_stage == .model) app.isModelCacheFailed() else false,
                .model_completions = picker_items,
                .model_completion_index = picker_index,
                .model_completion_window_start = picker_window_start,
                .model_completion_anchor = picker_anchor,
                .provider_query_active = provider_query != null,
                .provider_picker_completions = provider_picker_items,
                .provider_picker_annotations = provider_picker_annotations,
                .provider_picker_completion_index = provider_picker_index,
                .provider_picker_completion_window_start = provider_picker_window_start,
                .provider_picker_completion_anchor = provider_picker_anchor,
                .file_query_active = file_query != null,
                .file_completions = file_view.items,
                .file_completion_index = file_selection orelse 0,
                .file_completion_has_selection = file_selection != null,
                .file_completion_status = file_status,
                .file_completion_window_start = app.input_runtime.picker.file_completion_window_start,
                .file_completion_anchor = file_anchor,
                .file_completions_loading = file_view.status == .loading,
                .file_completions_failed = file_view.status == .unavailable,
                .inline_completion_suffix = if (inline_completion) |completion|
                    completion.suffix()
                else
                    "",
                .auth_picker = app.auth.pickerView(),
                .skills_menu = if (comptime @hasField(App, "skills"))
                    render_input.skillsMenuProjection(&app.skills)
                else
                    .{},
                .help_menu = render_input.helpMenuProjection(
                    &app.input_runtime.help_menu,
                    app.slashRegistry(),
                    app.input_runtime.edit_state.input.items,
                ),
                .settings_menu = blk: {
                    var projection = render_input.settingsMenuProjection(
                        &app.input_runtime.settings_menu,
                        settings_snapshot,
                        app.input_runtime.edit_state.input.items,
                    );
                    if (comptime @hasField(App, "model_cache")) {
                        projection.models = render_input.modelMenuProjection(&app.model_cache);
                    }
                    break :blk projection;
                },
                .model_menu = if (comptime @hasField(App, "model_cache"))
                    render_input.modelMenuProjection(&app.model_cache)
                else
                    .{},
                .session_menu = if (comptime @hasField(App, "session_persistence")) .{
                    .active = app.session_persistence.session_picker.active,
                    .load_state = app.session_persistence.session_picker.load_state,
                    .summaries = app.session_persistence.session_picker.summaries.items,
                    .has_more = app.session_persistence.session_picker.has_more,
                    .loading_more = app.session_persistence.session_picker.loading_more,
                    .scope = app.session_persistence.session_picker.scope,
                    .selected_index = app.session_persistence.session_picker.selected,
                    .window_start = app.session_persistence.session_picker.window_start,
                    .query = app.session_persistence.session_picker.query(),
                    .now_ms = now_ms,
                    .selection_failure = app.session_persistence.session_picker.selection_failure,
                } else .{},
                .statusline_menu = render_input.statuslineMenuProjection(
                    &app.input_runtime.statusline_menu,
                    settings_snapshot,
                ),
                .usage_menu = render_input.usageMenuProjection(
                    &app.input_runtime.usage_menu,
                ),
                .workspace_menu = if (comptime @hasDecl(App, "workspaceAccess"))
                    render_input.workspaceMenuProjection(
                        &app.input_runtime.workspace_menu,
                        app.workspace_root,
                        app.workspaceAccess(),
                    )
                else
                    .{},
                .upgrade_status = upgrade_label,
                .danger_status = if (yolo_warning_active)
                    app_permission_runtime.yolo_warning_text
                else
                    "",
                .danger_status_compact = if (yolo_warning_active)
                    app_permission_runtime.yolo_warning_compact_text
                else
                    "",
                .esc_clear_armed = app.input_runtime.gestures.escapeClearArmed(),
                .esc_interrupt_armed = app.input_runtime.gestures.escapeInterruptArmed(),
                .question = app.question_prompt.projection(),
                .statusline = statusline,
                .activity = activityProjection(app),
                .input = &app.input_runtime,
            };
        }

        fn pendingPickerEffort(app: *App, model: []const u8, query: ?picker_state.ModelPickerQuery, effort_index: usize) types.ReasoningEffort {
            const capabilities = model_capabilities.resolveForApp(App, app, model);
            if (query) |picker_query| {
                if (picker_query.stage == .effort) {
                    const typed = std.mem.trim(u8, picker_query.query, " \t");
                    if (types.ReasoningEffort.parseDisplayLabel(typed)) |effort| {
                        if (model_capabilities.reasoningEffortSupported(capabilities, effort)) return effort;
                    }
                }
            }
            return model_capabilities.reasoningEffortAtIndex(capabilities, effort_index);
        }

        fn buildStatuslineItems(
            app: *App,
            visible_model: []const u8,
        ) ui_render.StatuslineItems {
            var items: ui_render.StatuslineItems = .{};
            if (comptime @hasField(App, "workspace_identity") and
                @hasField(App, "workspace_root"))
            {
                const identity = app.workspace_identity.refresh(
                    app.alloc,
                    app.workspace_root,
                ) catch app.workspace_identity.snapshot();
                items.workspace_label = identity.workspace_label;
                items.git_branch = identity.git_branch;
            }
            if (app.statusline_context) {
                items.context_used = app.total_input_tokens;
                items.context_total = model_capabilities.resolveForApp(App, app, visible_model).context_window;
            }
            if (comptime @hasField(App, "statusline_session")) {
                if (app.statusline_session) {
                    items.session_title = app_session_runtime.Runtime(App).cachedSessionTitle(app);
                }
            }
            return items;
        }

        fn pendingPickerSpeed(query: ?picker_state.ModelPickerQuery, speed_index: usize) []const u8 {
            if (query) |picker_query| {
                if (picker_query.stage == .fast) {
                    const typed = std.mem.trim(u8, picker_query.query, " \t");
                    for (picker_state.model_picker_speed_options) |speed| {
                        if (std.ascii.eqlIgnoreCase(typed, speed)) return speed;
                    }
                }
            }
            return picker_state.model_picker_speed_options[speed_index % picker_state.model_picker_speed_options.len];
        }

        fn pendingPickerFastMode(query: ?picker_state.ModelPickerQuery, speed_index: usize) bool {
            return std.mem.eql(u8, pendingPickerSpeed(query, speed_index), "fast");
        }

        pub fn flushRequestedFrame(app: *App) !void {
            if (comptime @hasDecl(@TypeOf(app.shell), "sessionScrollbackHandoffPending")) {
                if (app.shell.sessionScrollbackHandoffPending()) return;
            }
            if (app.shell.terminal_dimensions_invalid or app.shell.layout.rows == 0 or app.shell.layout.cols == 0) return;
            const has_resize_lifecycle =
                @hasField(@TypeOf(app.shell), "pending_resize_observation");
            if (comptime has_resize_lifecycle) {
                if (shell_runtime.resizeBlocksFrameCommit(&app.shell)) return;
            }
            const render_requests = activeRenderRequests(app);
            var attempt = (try render_requests.beginAttempt()) orelse return;
            const snapshot = attempt.snapshot;
            var reason_buf: [128]u8 = undefined;
            const reason_names = renderReasonNames(snapshot.reasons, &reason_buf);
            debug_trace.logf(
                "frame_schedule",
                "attempt_begin reasons={s} reason_count={d} invalidations={d} resize_blocked={s} animation_phase={d} animation_generation={d} animation_deadline_ms={d}",
                .{
                    reason_names,
                    snapshot.reasons.count(),
                    snapshot.invalidations.len,
                    if (render_requests.blocksFrameCommit()) "true" else "false",
                    render_requests.visibleAnimationPhase(),
                    if (snapshot.animation_candidate) |candidate| candidate.generation else 0,
                    render_requests.animation_next_deadline_ms,
                },
            );
            defer attempt.deinit();

            const resize_commit = if (comptime has_resize_lifecycle)
                shell_runtime.pendingResizeFrameCommit(
                    &app.shell,
                    snapshot.reasons.contains(.resize),
                )
            else
                shell_runtime.ResizeFrameCommit.none;
            const attempted = attemptRequestedFrame(app, snapshot) catch |err| {
                attempt.restore();
                if (comptime @hasField(App, "terminal")) {
                    _ = app_lifecycle.closeFullTranscriptIfActive(
                        app.alloc,
                        &app.terminal,
                        &app.shell,
                        &app.metrics,
                    ) catch {};
                }
                debug_trace.logf(
                    "frame_schedule",
                    "attempt_restore outcome=error err={s} reasons={s} reason_count={d} invalidations={d} pending_reason_count={d} animation_phase={d} animation_deadline_ms={d}",
                    .{
                        @errorName(err),
                        reason_names,
                        snapshot.reasons.count(),
                        snapshot.invalidations.len,
                        render_requests.pendingReasonCount(),
                        render_requests.visibleAnimationPhase(),
                        render_requests.animation_next_deadline_ms,
                    },
                );
                return err;
            };
            const result = attempted orelse {
                attempt.restore();
                render_requests.noteInputPendingAbort();
                debug_trace.logf(
                    "frame_schedule",
                    "attempt_restore outcome=input_pending reasons={s} reason_count={d} invalidations={d} consecutive_aborts={d}",
                    .{
                        reason_names,
                        snapshot.reasons.count(),
                        snapshot.invalidations.len,
                        render_requests.consecutive_input_pending_aborts,
                    },
                );
                return;
            };

            if (!result.is_committed()) {
                input_completion_runtime.CompletionRuntime(App).distrustFilePicker(app);
                render_requests.resetInputPendingAbortStreak();
                attempt.restore();
                debug_trace.logf(
                    "frame_schedule",
                    "attempt_restore outcome={s} reasons={s} reason_count={d} invalidations={d} pending_reason_count={d} animation_phase={d} animation_deadline_ms={d}",
                    .{
                        @tagName(result.shadow_state),
                        reason_names,
                        snapshot.reasons.count(),
                        snapshot.invalidations.len,
                        render_requests.pendingReasonCount(),
                        render_requests.visibleAnimationPhase(),
                        render_requests.animation_next_deadline_ms,
                    },
                );
                return;
            }

            if (result.file_picker_receipt) |receipt| {
                input_completion_runtime.CompletionRuntime(App).acknowledgeFilePicker(app, receipt);
            } else {
                input_completion_runtime.CompletionRuntime(App).distrustFilePicker(app);
            }
            const committed_at_ms = io_mod.milliTimestamp();
            attempt.commit(
                committed_at_ms,
                render_request.animation_interval_ms,
                result.animation_visible,
            );
            if (comptime @hasDecl(App, "startPromptCredentialPrewarm")) {
                if (snapshot.reasons.contains(.first_frame)) {
                    App.startPromptCredentialPrewarm(app);
                }
            }
            if (comptime @hasDecl(App, "notePendingFrameCommitted")) {
                if (result.pending_prompt_presented) {
                    App.notePendingFrameCommitted(app);
                }
            }
            if (comptime @hasField(App, "permission_state") and
                @hasField(App, "permission_engine"))
            {
                app_permission_runtime.Runtime(App).noteFrameCommitted(
                    app,
                    app_permission_runtime.monotonicMillis(),
                    result.yolo_warning_visible,
                );
            }
            if (comptime has_resize_lifecycle) {
                shell_runtime.acknowledgeResizeFrameCommit(&app.shell, resize_commit);
            }
            if (comptime @hasDecl(App, "flushNotifications")) {
                if (snapshot.reasons.contains(.notification)) {
                    app.flushNotifications();
                }
            }
            if (comptime @hasField(@TypeOf(app.shell), "resize_history_row_delta")) {
                if (snapshot.reasons.contains(.resize) and
                    !app.shell.render_requests.hasReason(.resize))
                {
                    app.shell.resize_history_row_delta = null;
                }
            }
            debug_trace.logf(
                "frame_schedule",
                "attempt_end outcome=committed reasons={s} reason_count={d} invalidations={d} pending_reason_count={d} animation_phase={d} animation_deadline_ms={d}",
                .{
                    reason_names,
                    snapshot.reasons.count(),
                    snapshot.invalidations.len,
                    render_requests.pendingReasonCount(),
                    render_requests.visibleAnimationPhase(),
                    render_requests.animation_next_deadline_ms,
                },
            );
        }

        fn attemptRequestedFrame(
            app: *App,
            snapshot: render_request.AttemptSnapshot,
        ) !?FrameAttemptResult {
            const result = (if (comptime @hasDecl(App, "renderFrameAttemptForTest"))
                App.renderFrameAttemptForTest(app, snapshot)
            else
                renderFrameAttempt(app, snapshot)) catch |err| {
                if (err == error.InputPending) return null;
                return err;
            };
            return result;
        }

        fn transcriptInputPending(context: *anyopaque) bool {
            const app: *App = @ptrCast(@alignCast(context));
            if (app.terminal_input_runtime.hasPendingTerminalInput()) return true;
            const state = app.terminal.pollInput(0) catch |err| {
                debug_trace.logf(
                    "frame_schedule",
                    "input_poll_failed err={s}",
                    .{@errorName(err)},
                );
                return true;
            };
            return state.readable or state.closed();
        }

        fn transcriptBuildCheckpoint(app: *App) ?build_checkpoint.BuildCheckpoint {
            if (comptime !@hasField(App, "terminal")) return null;
            if (comptime @hasField(App, "shell")) {
                const render_requests = activeRenderRequests(app);
                if (!render_requests.permitsInputPendingAbort()) {
                    debug_trace.logf(
                        "frame_schedule",
                        "input_cancellation_suppressed consecutive_aborts={d} bound={d}",
                        .{
                            render_requests.consecutive_input_pending_aborts,
                            render_request.max_consecutive_input_pending_aborts,
                        },
                    );
                    return null;
                }
            }
            return .init(app, transcriptInputPending);
        }

        fn reconcileBeforeFrameRender(app: *App, queued_rows: usize) !RenderReconciliation {
            if (comptime !@hasField(App, "terminal")) return .{ .inline_render = .{} };

            if (try app_lifecycle.recoverFullTranscriptDriftBeforeRender(
                app.alloc,
                &app.terminal,
                &app.shell,
                &app.metrics,
            )) {
                try requestNormalViewportRecovery(app);
            }

            const question_active = app.question_prompt.isActive();
            if (question_active) {
                if (try app_lifecycle.closeFullTranscriptIfActive(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                )) {
                    try requestNormalViewportRecovery(app);
                }
                if (app.terminal.catalogMenuScreenActive()) {
                    try app_lifecycle.leaveCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
                    try requestNormalViewportRecovery(app);
                }
            }

            const approval = app.approval_prompt.projection();
            if (approval) |projection| {
                const approval_screen_active = try approval_screen.needsScreen(
                    app.alloc,
                    projection.request,
                    app.shell.layout,
                    queued_rows,
                );
                if (app.terminal.catalogMenuScreenActive()) {
                    try app_lifecycle.leaveCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
                    if (!approval_screen_active) try requestNormalViewportRecovery(app);
                }
                switch (try app_lifecycle.transitionFullTranscriptForApproval(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                    approval_screen_active,
                )) {
                    .inactive, .handed_off => {},
                    .closed => {
                        try requestNormalViewportRecovery(app);
                    },
                }
                if (approval_screen_active) return .file_approval_screen;
            }

            const terminal_transition = app_lifecycle.approvalInlineRestoreTransition(
                &app.terminal,
            );
            switch (terminal_transition) {
                .none => {},
                .restore_normal_screen => {
                    if (!question_active and approval == null and
                        (settingsMenuActive(app) or helpMenuActive(app) or
                            skillsMenuActive(app) or modelMenuActive(app) or
                            sessionMenuActive(app)))
                    {
                        app.shell.render_requests.request(.footer);
                    }
                    return .{ .inline_render = .{
                        .terminal_transition = terminal_transition,
                    } };
                },
            }

            if (!question_active and approval == null and (settingsMenuActive(app) or helpMenuActive(app) or skillsMenuActive(app) or modelMenuActive(app) or sessionMenuActive(app))) {
                if (try app_lifecycle.closeFullTranscriptIfActive(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                )) {
                    try requestNormalViewportRecovery(app);
                }
            }

            if (app.terminal.catalogMenuScreenActive()) {
                try app_lifecycle.leaveCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
                try requestNormalViewportRecovery(app);
            }

            return .{ .inline_render = .{
                .alternate_screen_owns_rendering = app.terminal.alternate_screen_owner != .none,
            } };
        }

        fn renderFrameAttempt(app: *App, snapshot: render_request.AttemptSnapshot) !FrameAttemptResult {
            var checkpoint_storage = transcriptBuildCheckpoint(app);
            const checkpoint = if (checkpoint_storage) |*value| value else null;
            // Frame-fresh producer fact for the finality floor: the trailing
            // assistant entry stays non-final while the stream is open or
            // the pacer still holds undelivered output.
            set_transcript_assistant_tail_writable(
                &app.shell,
                app.stream.active or app.pacer.hasPending(),
            );
            const presentation_shell: *transcript_runtime.TranscriptRuntime = &app.shell;
            const render_requests = activeRenderRequests(app);
            var upgrade_status_buf: [64]u8 = undefined;
            var steering = try buildSteeringProjection(App, app);
            defer steering.deinit(app.alloc);
            const shimmer_pos = if (snapshot.animation_candidate) |candidate|
                candidate.phase
            else
                render_requests.visibleAnimationPhase();
            const main_footer_ctx = footerContext(
                app,
                &upgrade_status_buf,
                shimmer_pos,
                &steering,
            );
            const file_picker_receipt = input_completion_runtime.CompletionRuntime(App).filePickerView(app).receipt;
            var footer_ctx = main_footer_ctx;
            const render_reconciliation = switch (try reconcileBeforeFrameRender(app, render_input.steeringBannerRows(footer_ctx, app.shell.layout.cols))) {
                .inline_render => |inline_render| inline_render,
                .file_approval_screen => return renderApprovalScreen(app),
                .frame_result => |result| return result,
            };
            const presentation_commits_transcript = !render_reconciliation.alternate_screen_owns_rendering;
            const active_committed_layout = if (render_reconciliation.alternate_screen_owns_rendering)
                app.terminal.alternate_frame_layout
            else
                app.shell.committed_frame_layout;
            var pending_card = if (!render_reconciliation.alternate_screen_owns_rendering)
                try buildPendingCardProjection(App, app, presentation_shell, checkpoint)
            else
                null;
            const pending_submission_card = pending_card != null;
            if (pending_card == null and !render_reconciliation.alternate_screen_owns_rendering) {
                pending_card = try buildPendingSteeringCardProjection(app.alloc, presentation_shell, steering, checkpoint);
            }
            defer if (pending_card) |*card| card.deinit(app.alloc);

            var attempt_invalidations = snapshot.invalidations;
            presentation_shell.normalizeFrameInvalidations(&attempt_invalidations);
            var frame_redraw = snapshot.reasons.count() > 0 or !attempt_invalidations.isEmpty();

            const body_rows: usize = presentation_shell.layout.content_bottom;

            var prepared_transcript: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
            defer if (prepared_transcript) |*prepared| prepared.deinit(app.alloc);
            var owned_transcript_source: ?transcript_runtime.TranscriptPreparationSource = null;
            defer if (owned_transcript_source) |*source| source.deinit(app.alloc);
            var transcript_source: ?*transcript_runtime.TranscriptPreparationSource = null;
            var full_transcript_projection: ?*full_transcript_screen.Projection = null;
            var full_transcript_capability: ?*session_child_store.SessionChildCapability = if (comptime @hasDecl(
                App,
                "fullTranscriptSidecarCapability",
            ))
                app.fullTranscriptSidecarCapability()
            else
                null;
            var transcript_transition: ?transcript_runtime.TranscriptTransition = null;
            defer if (transcript_transition) |*transition| transition.deinit(app.alloc);
            var footer_measurement: ?surface_frame.SurfaceFooterMeasurement = null;
            defer if (footer_measurement) |*measurement| measurement.deinit(app.alloc);
            const extra_input_rows_before_footer_prepare = presentation_shell.extra_input_rows;
            const footer_reserved_base_rows_before_footer_prepare = presentation_shell.footer_reserved_base_rows;
            var restore_footer_prepare_state = true;
            defer {
                if (restore_footer_prepare_state) {
                    presentation_shell.extra_input_rows = extra_input_rows_before_footer_prepare;
                    presentation_shell.footer_reserved_base_rows = footer_reserved_base_rows_before_footer_prepare;
                }
            }
            const visible_approval = app.approval_prompt.projection();
            {
                footer_ctx.transcript_depth = presentation_shell.transcriptPresentationDepth();
                if (presentation_shell.fullTranscriptActive()) {
                    const full_diff_resolver: ?full_transcript_screen.FullDiffResolver =
                        if (comptime @hasDecl(App, "fullTranscriptDiffResolver"))
                            app.fullTranscriptDiffResolver()
                        else
                            null;
                    full_transcript_projection = try presentation_shell.preparedFullTranscriptPageProjectionInterruptible(
                        full_diff_resolver,
                        full_transcript_capability,
                        checkpoint,
                    );
                    if (presentation_shell.preparedFullTranscriptPageCapability()) |capability| {
                        full_transcript_capability = capability;
                    }
                }
                footer_measurement = try surface_frame.measureSurfaceFooter(
                    app.alloc,
                    presentation_shell,
                    visible_approval,
                    footer_ctx,
                );
                const omitted_entry_id: ?u32 = if (!presentation_shell.fullTranscriptActive() and footer_measurement != null) switch (footer_measurement.?.activity_projection) {
                    .tool_slot => |slot| if (slot.active) slot.entry_id else null,
                    .none, .turn_thinking => null,
                } else null;
                if (!presentation_shell.fullTranscriptActive()) {
                    if (try presentation_shell.pendingResumeSourceInterruptible(
                        app.alloc,
                        checkpoint,
                    )) |source| {
                        transcript_source = source;
                    } else if (omitted_entry_id) |entry_id| {
                        owned_transcript_source = try presentation_shell.prepareTranscriptSourceForFrameInterruptible(
                            app.alloc,
                            entry_id,
                            null,
                            checkpoint,
                        );
                    } else {
                        owned_transcript_source = try presentation_shell.cachedTranscriptSourceInterruptible(
                            app.alloc,
                            checkpoint,
                        );
                    }
                    if (transcript_source == null) {
                        transcript_source = &owned_transcript_source.?;
                    }
                }
            }
            const footer_reservation_changed = if (footer_measurement) |*measurement|
                measurement.changesFooterReservation(presentation_shell)
            else
                false;
            const replay_displaced_footer_history = if (footer_measurement) |*measurement|
                measurement.replaysDisplacedTranscriptHistory(presentation_shell)
            else
                false;

            var footer_frame: surface_frame.SurfaceFooterFrame = undefined;
            var footer_frame_initialized = false;
            defer if (footer_frame_initialized) footer_frame.deinit(app.alloc);
            var solved_layout: ?render_engine.frame_layout.FrameLayout = null;
            var resolved_transcript_target: ?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget = null;
            var scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(
                presentation_shell.layout.rows,
                presentation_shell.owned_top_row,
            );
            var planned_scroll_next_start_line: usize = 0;
            {
                const canonical_transcript_preview = if (transcript_source) |source|
                    source.preview
                else
                    render_engine.frame_layout.TranscriptFlowPreview{
                        .natural_visual_rows = @intCast(@min(body_rows, @as(usize, std.math.maxInt(u16)))),
                        .cursor_row = presentation_shell.cursor_row,
                        .cursor_col = presentation_shell.cursor_col,
                        .replaceable_row = presentation_shell.replaceable_row,
                    };
                const transcript_preview = previewWithPendingCard(
                    canonical_transcript_preview,
                    pending_card,
                );
                const neutral_footer = if (footer_measurement) |*measurement|
                    measurement.frameLayoutMeasurement()
                else
                    footerMeasurementFromRows(footer_frame.paint.footer);
                var frame_activity = if (footer_measurement) |*measurement|
                    frameActivityStateFromMeasurement(presentation_shell, measurement)
                else
                    activityStateFromPlacement(footer_frame.paint.activity);
                if (pending_card != null and frame_activity == .thinking) {
                    // The pending tail already includes the transcript cursor's blank row.
                    frame_activity.thinking.gap_above_activity = render_engine.transcript_blocks.blockGapRowsBetween(
                        .user_turn,
                        .assistant_turn,
                    ) -| 1;
                }
                const target_activity_projection: activity_runtime.ActivityProjection = if (footer_measurement) |*measurement|
                    measurement.activity_projection
                else
                    .{ .turn_thinking = .{ .label = footer_frame.label() } };
                const prompt_turn_reservation = promptTurnReservation(
                    app,
                    presentation_shell,
                    canonical_transcript_preview,
                    pending_card,
                    if (footer_measurement) |*measurement| measurement else null,
                    frame_activity,
                );
                var fixed_point_ctx = FixedPointTranscriptContext(App){
                    .app = app,
                    .presentation_shell = presentation_shell,
                    .prepare_transcript = !presentation_shell.fullTranscriptActive(),
                    .source = transcript_source,
                    .prepared_transcript = &prepared_transcript,
                    .resolved_target = &resolved_transcript_target,
                    .footer_reservation_changed = footer_reservation_changed,
                    .replay_displaced_footer_history = replay_displaced_footer_history,
                    .footer_measurement = if (footer_measurement) |*measurement| measurement else null,
                    .fallback_footer_rows = if (footer_measurement == null)
                        footer_frame.paint.footer
                    else
                        null,
                    .activity_projection = target_activity_projection,
                    .frame_activity = frame_activity,
                    .base_invalidation = if (footer_measurement != null)
                        render_engine.paint_plan.FrameInvalidationSet.empty()
                    else
                        footer_frame.paint.invalidation,
                    .attempt_invalidations = attempt_invalidations,
                    .pending_tail_rows = if (pending_card) |card| card.row_count else 0,
                };
                const fixed_point = try render_engine.frame_fixed_point.solve(
                    FixedPointTranscriptContext(App),
                    &fixed_point_ctx,
                    .{
                        .terminal = presentation_shell.layout,
                        .owned_top = presentation_shell.owned_top_row,
                        .footer = neutral_footer,
                        .transcript = transcript_preview,
                        .activity = frame_activity,
                        .prompt_turn = prompt_turn_reservation,
                        .body_mode = .transcript,
                        .prior = active_committed_layout,
                    },
                    FixedPointTranscriptContext(App).prepareCandidate,
                    FixedPointTranscriptContext(App).resolveCandidate,
                );
                const solved = fixed_point.layout;
                solved_layout = solved;
                scroll_plan = fixed_point.scroll_plan;
                debug_trace.logf(
                    "frame_layout",
                    "layout_id={x} solved_frame_height={d} footer_height={d} footer_top={d} owned_top={d} owned_bottom={d} prompt_turn_transcript_rows={d} prompt_turn_active={s} scroll_rows={d}",
                    .{
                        solved.layout_id,
                        solved.solved_frame_height,
                        solved.footer_area.height(),
                        solved.footer_area.top,
                        solved.owned_top,
                        solved.owned_band.bottom,
                        prompt_turn_reservation.transcript_rows,
                        if (prompt_turn_reservation.active()) "true" else "false",
                        scroll_plan.terminal_scroll_rows,
                    },
                );
                const solved_footer_rows = if (footer_measurement) |*measurement|
                    measurement.frameLayoutRows(presentation_shell.layout.rows, solved.footer_area.top)
                else
                    footer_frame.paint.footer;
                const solved_viewport = if (resolved_transcript_target) |target|
                    target.selection()
                else if (prepared_transcript) |*prepared|
                    prepared.selection
                else if (footer_measurement != null)
                    surface_frame.currentSurfaceFooterTranscriptState(presentation_shell).selection
                else
                    footer_frame.paint.viewport;
                const solved_projection = if (footer_measurement) |*measurement|
                    measurement.activity_projection
                else
                    .none;
                const solved_activity = if (footer_measurement != null)
                    render_engine.activity_placement.resolve(
                        solved_projection,
                        frame_activity,
                        solved,
                    )
                else
                    render_engine.activity_placement.resolve(
                        .{ .turn_thinking = .{ .label = footer_frame.label() } },
                        frame_activity,
                        solved,
                    );
                const solved_cursor_visible = if (footer_measurement) |*measurement|
                    measurement.input_visible
                else switch (solved_activity) {
                    .transient_row => false,
                    .none, .overlay_entry => true,
                };
                const solved_cursor_target = if (resolved_transcript_target) |target|
                    render_engine.paint_plan.FrameCursorTarget{
                        .row = target.cursorRow(),
                        .col = target.cursorCol(),
                        .visible = solved_cursor_visible,
                    }
                else if (prepared_transcript) |*prepared|
                    render_engine.paint_plan.FrameCursorTarget{
                        .row = prepared.cursor.cursor_row,
                        .col = prepared.cursor.cursor_col,
                        .visible = solved_cursor_visible,
                    }
                else if (footer_measurement != null)
                    render_engine.paint_plan.FrameCursorTarget{
                        .row = solved_footer_rows.input_base,
                        .col = 1,
                        .visible = solved_cursor_visible,
                    }
                else
                    footer_frame.paint.cursor_target;
                const solved_plan = solved.toPaintPlan(.{
                    .footer_rows = solved_footer_rows,
                    .viewport = solved_viewport,
                    .activity = solved_activity,
                    .invalidation = if (footer_measurement != null)
                        render_engine.paint_plan.FrameInvalidationSet.empty()
                    else
                        footer_frame.paint.invalidation,
                    .synchronized_update = app.shell.sync_updates_enabled,
                    .cursor_target = solved_cursor_target,
                    .preserve_scrollback = if (footer_measurement != null)
                        !presentation_shell.pending_scroll_compact
                    else
                        footer_frame.paint.preserve_scrollback,
                    .reset_terminal = shouldResetPhysicalTerminal(
                        render_reconciliation.alternate_screen_owns_rendering,
                        app.shell.terminal_reset_pending,
                    ),
                });
                if (footer_measurement) |*measurement| {
                    footer_frame = try surface_frame.prepareMeasuredSurfaceFooterFrameForPlan(
                        app.alloc,
                        presentation_shell,
                        &frame_redraw,
                        visible_approval,
                        footer_ctx,
                        measurement,
                        solved_plan,
                        attempt_invalidations,
                    );
                    footer_frame_initialized = true;
                } else {
                    surface_frame.retargetSurfaceFooterFrame(&footer_frame, solved_plan);
                }
                if (!framePlanBandsEqual(footer_frame.paint, solved_plan)) {
                    debug_trace.logf(
                        "frame_layout",
                        "migration_mismatch old_transcript={d}..{d} old_activity={d}..{d} old_footer={d}..{d} solved_transcript={d}..{d} solved_activity={d}..{d} solved_footer={d}..{d}",
                        .{
                            footer_frame.paint.transcript_band.top,
                            footer_frame.paint.transcript_band.bottom,
                            footer_frame.paint.activity_band.top,
                            footer_frame.paint.activity_band.bottom,
                            footer_frame.paint.footer_band.top,
                            footer_frame.paint.footer_band.bottom,
                            solved_plan.transcript_band.top,
                            solved_plan.transcript_band.bottom,
                            solved_plan.activity_band.top,
                            solved_plan.activity_band.bottom,
                            solved_plan.footer_band.top,
                            solved_plan.footer_band.bottom,
                        },
                    );
                }
                try footer_frame.paint.validate();
                if (prepared_transcript) |*prepared| {
                    try validatePreparedTranscriptFitsPlan(prepared, footer_frame.paint);
                    planned_scroll_next_start_line = if (resolved_transcript_target) |target|
                        target.selection().start_line
                    else
                        prepared.selection.start_line;
                }
                if (full_transcript_projection) |projection| {
                    const area = footer_frame.paint.transcript_band;
                    if (!area.isEmpty()) {
                        const staged = try presentation_shell.prepareFullTranscriptSurfacePaintInterruptible(
                            app.alloc,
                            &app.metrics,
                            projection,
                            full_transcript_capability,
                            .{ .top = area.top, .bottom = area.bottom },
                            checkpoint,
                        );
                        if (staged.owned_source) |source| {
                            owned_transcript_source = source;
                            transcript_source = &owned_transcript_source.?;
                        } else {
                            transcript_source = staged.borrowed_source.?;
                        }
                        prepared_transcript = staged.prepared;
                        footer_frame.paint.viewport = prepared_transcript.?.selection;
                        try validatePreparedTranscriptFitsPlan(&prepared_transcript.?, footer_frame.paint);
                    }
                }
            }
            if (presentation_commits_transcript) {
                if (transcript_source) |source| {
                    if (prepared_transcript) |*prepared| {
                        if (presentation_shell.fullTranscriptActive()) {
                            return error.InvalidFullTranscriptRoute;
                        } else {
                            const target = resolved_transcript_target orelse
                                return error.MissingResolvedTranscriptTarget;
                            transcript_transition = try presentation_shell.sealTranscriptTransition(
                                app.alloc,
                                source,
                                prepared,
                                &footer_frame.paint,
                                target,
                            );
                        }
                    }
                }
            }
            const committed_layout = solved_layout orelse return error.MissingSolvedFrameLayout;
            const commit_diagnostic = presentation_shell.transcriptCommitDiagnostic();
            debug_trace.logf(
                "scroll",
                "frame_builder_scroll terminal_scroll_rows={d} source_state={s} previous_committed_start_line={d} next_start_line={d}",
                .{
                    scroll_plan.terminal_scroll_rows,
                    @tagName(commit_diagnostic.state),
                    commit_diagnostic.stable_start_line orelse 0,
                    planned_scroll_next_start_line,
                },
            );

            const observation_activity: activity_runtime.ActivityProjection =
                if (footer_measurement) |*measurement|
                    measurement.activity_projection
                else
                    .{ .turn_thinking = .{ .label = footer_frame.label() } };
            var frame_ctx = FramePaintContext(App){
                .app = app,
                .presentation_shell = presentation_shell,
                .body = .transcript,
                .prepared_transcript = if (prepared_transcript) |*prepared| prepared else null,
                .footer_frame = &footer_frame,
                .activity_style = switch (observation_activity) {
                    .tool_slot => |slot| if (slot.thinking_label != null) .thinking else .tool_marker,
                    .turn_thinking => |thinking| switch (thinking.tone) {
                        .thinking => .thinking,
                        .neutral => .neutral,
                        .warning => .warning,
                        .success => .success,
                        .danger => .danger,
                    },
                    .none => .thinking,
                },
                .activity_result = .{ .painted = false, .row = 0, .overlay = false },
            };
            const document_append = if (transcript_transition) |*transition|
                transition.document_append
            else
                render_engine.frame_scroll_plan.FrameDocumentAppend{};
            var transcript_body: render_engine.frame_builder.TranscriptBodyDisposition =
                if (transcript_transition) |*transition| switch (transition.body_disposition) {
                    .paint => .paint,
                    .retain_committed => |retained| .{ .retain = retained },
                } else .paint;
            const pending_preview_overlaps_flow = pending_submission_card and if (prepared_transcript) |prepared|
                pending_card.?.overlaps_flow_endpoint(prepared.cursor.cursor_col)
            else
                false;
            var pending_paint_ctx = if (pending_preview_overlaps_flow) null else if (pending_card) |card|
                PendingCardPaintContext.init(
                    card,
                    footer_frame.paint.transcript_band,
                    if (prepared_transcript) |*prepared| prepared.cursor.cursor_row else null,
                    !footer_frame.paint.activity_band.isEmpty(),
                )
            else
                null;
            // A band too short for the preview below the flow endpoint defers it
            // the same way: adoption writes the real card.
            const pending_preview_deferred = pending_submission_card and
                prepared_transcript != null and pending_paint_ctx == null;
            if (pending_paint_ctx) |paint_ctx| switch (transcript_body) {
                .paint => {},
                .retain => |retained_source| {
                    const first_changed_row = paint_ctx.row;
                    if (first_changed_row <= retained_source.source_area.top) {
                        transcript_body = .paint;
                    } else if (first_changed_row <= retained_source.source_area.bottom) {
                        var narrowed = retained_source;
                        narrowed.source_area.bottom = first_changed_row - 1;
                        narrowed.occupied_last_row = @min(
                            narrowed.occupied_last_row,
                            narrowed.source_area.bottom,
                        );
                        transcript_body = .{ .retain = narrowed };
                    }
                },
            };
            if (pending_paint_ctx) |paint_ctx| {
                debug_trace.logf(
                    "frame_plan",
                    "pending_prompt_tail start={d} paint_rows={d} layout_rows={d} bytes={d} transcript={d}..{d} body={s}",
                    .{
                        paint_ctx.row,
                        paint_ctx.max_rows,
                        pending_card.?.row_count,
                        paint_ctx.bytes.len,
                        footer_frame.paint.transcript_band.top,
                        footer_frame.paint.transcript_band.bottom,
                        @tagName(transcript_body),
                    },
                );
            }
            const observation_rows = if (transcript_transition) |*transition|
                switch (transition.body_disposition) {
                    .paint => transition.row_provenance,
                    .retain_committed => presentation_shell.committedRowProvenance(),
                }
            else
                presentation_shell.committedRowProvenance();
            var counters: render_engine.frame_builder.TraceCounters = .{};
            try build_checkpoint.poll(checkpoint);
            if (footer_frame.paint.reset_terminal) {
                if (comptime @hasField(App, "terminal")) {
                    if (app.terminal.alternate_screen_owner == .none) {
                        app.terminal.clearTmuxScreenAndHistory(app.alloc);
                    }
                }
            }
            var frame_shell = SurfaceFrameShell.init(
                &app.shell,
                presentation_shell,
                active_committed_layout,
            );
            const result = try render_engine.frame_builder.buildAndFlushFrame(
                app.alloc,
                &frame_shell,
                &app.metrics,
                .{
                    .plan = footer_frame.paint,
                    .committed_layout = active_committed_layout,
                    .body = frame_ctx.body,
                    .transcript_body = transcript_body,
                    .scroll_plan = scroll_plan,
                    .document_append = document_append,
                    .terminal_transition = render_reconciliation.terminal_transition,
                    .body_painter = .{ .ctx = &frame_ctx, .paint = FramePaintContext(App).paintBody },
                    .transcript_tail_painter = if (pending_paint_ctx) |*paint_ctx| .{
                        .ctx = paint_ctx,
                        .paint = PendingCardPaintContext.paint,
                    } else null,
                    .footer_painter = .{ .ctx = &frame_ctx, .paint = FramePaintContext(App).paintFooter },
                    .activity_painter = .{ .ctx = &frame_ctx, .paint = FramePaintContext(App).paintActivity },
                    .trace_counters = &counters,
                    .observation = .{
                        .observer = &presentation_shell.ui_observer,
                        .row_provenance = observation_rows,
                        .activity = observation_activity,
                        .stream_active = footer_ctx.stream.active,
                        .completed_assistant_presentation_tail = footer_ctx.completed_assistant_presentation_tail,
                    },
                },
            );
            const scroll_commit = result.scrollCommit(scroll_plan);
            debug_trace.logf(
                "frame_diff",
                "attempt_result transcript_body={s} body_paints={d} retained_changed_cells={d} document_append_bytes={d} planned_scroll_rows={d} committed_scroll_rows={d} accepted_scroll_rows={d} unplanned_scroll_rows={d} changed_cells={d} shadow_state={s}",
                .{
                    @tagName(transcript_body),
                    counters.body_paints,
                    counters.retained_transcript_changed_cells,
                    document_append.bytes.len,
                    scroll_commit.planned_terminal_scroll_rows,
                    scroll_commit.physical_terminal_scroll_rows,
                    scroll_commit.accepted_terminal_scroll_rows,
                    scroll_commit.unplanned_terminal_scroll_rows,
                    result.changed_cells,
                    @tagName(result.state()),
                },
            );

            if (presentation_commits_transcript) {
                const transition_ptr: ?*transcript_runtime.TranscriptTransition =
                    if (transcript_transition) |*transition| transition else null;
                presentation_shell.consumeFrameScrollCommit(
                    app.alloc,
                    scroll_plan,
                    result,
                    transition_ptr,
                );
            }
            if (result.is_committed() and render_reconciliation.alternate_screen_owns_rendering) {
                app.terminal.alternate_frame_layout =
                    render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(committed_layout);
            }
            if (result.is_committed()) {
                switch (render_reconciliation.terminal_transition) {
                    .none => {},
                    .restore_normal_screen => app_lifecycle.commitApprovalInlineRestore(
                        &app.terminal,
                    ),
                }
            }
            if (result.is_committed() and presentation_commits_transcript) {
                restore_footer_prepare_state = false;
                presentation_shell.has_committed_frame = true;
                presentation_shell.terminal_reset_pending = false;
                if (footer_frame.paint.reset_terminal) {
                    app.shell.terminal_reset_pending = false;
                }
                if (transcript_transition == null) {
                    presentation_shell.committed_frame_layout = render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(committed_layout);
                    presentation_shell.invalidateTranscriptAnchor("empty_transcript_commit");
                }
                surface_frame.commitSurfaceFooterFrame(
                    app.alloc,
                    presentation_shell,
                    &footer_frame,
                    if (footer_measurement) |*measurement| measurement else null,
                );
                presentation_shell.shimmer_active = frame_ctx.activity_result.painted;
                presentation_shell.shimmer_is_overlay = frame_ctx.activity_result.overlay;
                if (scroll_plan.remaining_inline_advance_rows > 0) {
                    presentation_shell.markTranscriptDirty();
                } else if (!render_requests.hasReason(.transcript)) {
                    presentation_shell.transcript_band_dirty = false;
                }
                if (!render_requests.hasReason(.external_damage)) {
                    presentation_shell.footer_viewport.clearExternalInvalidation();
                }
            }
            return .{
                .shadow_state = result.state(),
                .animation_visible = frame_ctx.activity_result.painted,
                .yolo_warning_visible = !render_reconciliation.alternate_screen_owns_rendering and
                    footer_frame.composed.danger_status_visible,
                // The committed pending UI permits adoption even when its preview
                // would overwrite the flow endpoint. Adoption writes the real card.
                .pending_prompt_presented = pending_submission_card and (pending_paint_ctx != null or pending_preview_deferred),
                .file_picker_receipt = if (result.is_committed() and presentation_commits_transcript and
                    footer_measurement != null and footer_measurement.?.show_picker and
                    footer_measurement.?.picker_kind == .file and footer_measurement.?.picker_rows > 0)
                    file_picker_receipt
                else
                    null,
            };
        }

        fn renderApprovalScreen(app: *App) !FrameAttemptResult {
            const approval = app.approval_prompt.projection() orelse return error.MissingApprovalRequest;
            const request = approval.request;
            const clear_display = approvalScreenNeedsClear(
                app.terminal.fileApprovalScreenActive(),
                request,
                app.shell.layout,
                app.approval_screen.screen_commit,
            );
            app.approval_screen.invalidateScreenCommit();
            app_lifecycle.enterApprovalScreen(
                &app.terminal,
                &app.shell,
                &app.metrics,
            ) catch |err| return failApprovalScreen(app, request.id, err);
            if (app.shell.shadow_vt) |grid| {
                if (grid.cols != app.shell.layout.cols or
                    grid.rows != app.shell.layout.rows)
                {
                    grid.resize(
                        app.shell.layout.cols,
                        app.shell.layout.rows,
                    ) catch |err| return failApprovalScreen(app, request.id, err);
                }
            }

            var transcript_source: ?transcript_runtime.TranscriptPreparationSource = null;
            defer if (transcript_source) |*source| source.deinit(app.alloc);
            const transcript_document: approval_screen.TranscriptDocument = switch (approval_screen.transcriptDocumentPlan(
                approval,
                &app.approval_screen,
                app.shell.entries.items,
                app.shell.layout,
            ) catch |err| return failApprovalScreen(app, request.id, err)) {
                .none => .none,
                .progressive => |present| .{ .progressive = present },
                .projected => blk: {
                    transcript_source = app.shell.cachedTranscriptSource(app.alloc) catch |err|
                        return failApprovalScreen(app, request.id, err);
                    break :blk .{ .projected = transcript_source.?.bytes };
                },
            };

            var screen = approval_screen.paint(
                app.alloc,
                approval,
                &app.approval_screen,
                transcript_document,
                app.shell.layout,
                clear_display,
            ) catch |err| return failApprovalScreen(app, request.id, err);
            defer screen.deinit(app.alloc);

            app_lifecycle.setApprovalScreenMouseTracking(
                &app.terminal,
                &app.shell,
                &app.metrics,
                request.file != null or screen.document_scrollable,
            ) catch |err| return failApprovalScreen(app, request.id, err);

            app_lifecycle.writeLifecycleTerminalBytes(
                &app.shell,
                &app.metrics,
                screen.bytes,
            ) catch |err| return failApprovalScreen(app, request.id, err);

            app.approval_screen.recordScreenCommit(request.id, .{
                .request_id = request.id,
                .rows = app.shell.layout.rows,
                .cols = app.shell.layout.cols,
                .file_identity_visible = screen.file_identity_visible,
                .all_decision_controls_visible = screen.all_decision_controls_visible,
                .changed_or_notice_visible = screen.changed_or_notice_visible,
                .document_scrollable = screen.document_scrollable,
            });
            app.shell.ui_observer.observeAlternateScreen(app.alloc, .{
                .request_id = request.id,
                .rows = app.shell.layout.rows,
                .cols = app.shell.layout.cols,
                .file_identity_visible = screen.file_identity_visible,
                .all_decision_controls_visible = screen.all_decision_controls_visible,
                .changed_or_notice_visible = screen.changed_or_notice_visible,
                .document_scrollable = screen.document_scrollable,
            });
            if (screen.needs_full_file_projection) {
                app.shell.render_requests.request(.modal);
            }
            return .{
                .shadow_state = .committed,
                .animation_visible = false,
            };
        }

        fn failApprovalScreen(
            app: *App,
            request_id: u64,
            err: anyerror,
        ) !FrameAttemptResult {
            debug_trace.logf(
                "permission",
                "approval_screen_failed request_id={d} err={s}",
                .{ request_id, @errorName(err) },
            );
            _ = app_lifecycle.leaveApprovalScreen(
                &app.terminal,
                &app.shell,
                &app.metrics,
            ) catch |leave_err| {
                debug_trace.logf(
                    "permission",
                    "approval_screen_leave_failed reason=screen_failure err={s}",
                    .{@errorName(leave_err)},
                );
            };
            switch (app.worker.submitPermissionResponse(
                request_id,
                permission_request.OwnedPermissionResponse.init(app.alloc, .deny, null),
            )) {
                .accepted => {
                    app.approval_prompt.clearWithReason(app.alloc, "screen_failure");
                    app.approval_screen.clear();
                },
                .stale, .no_pending => {},
            }
            app.shell.render_requests.request(.modal);
            return .{
                .shadow_state = .committed,
                .animation_visible = false,
            };
        }

        pub noinline fn requestNormalViewportRecovery(app: *App) !void {
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.alternate_screen_owner != .none) return;
                try shell_runtime.requestRedraw(&app.shell, &app.metrics, .replay_viewport);
            }
        }

        fn skillsMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "skills")) return app.skills.menuVisible();
            return false;
        }

        fn modelMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "model_cache")) return app.model_cache.menu.active;
            return false;
        }

        fn sessionMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "session_persistence")) return app.session_persistence.session_picker.active;
            return false;
        }

        fn helpMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "input_runtime")) return app.input_runtime.help_menu.active;
            return false;
        }

        fn settingsMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "input_runtime")) return app.input_runtime.settings_menu.active;
            return false;
        }

        fn activityProjection(app: *const App) activity_runtime.ActivityProjection {
            return shell_runtime.activityProjection(&app.shell);
        }

        fn activeRenderRequests(app: *App) *render_request.RenderRequestState {
            return &app.shell.render_requests;
        }

        pub fn requestActiveSurfaceFrame(
            app: *App,
            reason: render_request.Reason,
        ) void {
            activeRenderRequests(app).request(reason);
        }

        pub fn eventLoopCallbacks(app: *App) event_loop.EventLoopCallbacks {
            return .{
                .ctx = @ptrCast(app),
                .collect_facts = App.loopCollectFacts,
                .next_collected_byte = App.loopNextCollectedByte,
                .handle_byte = App.loopHandleByte,
                .settle_delivery_epoch = App.loopSettleInputDeliveryEpoch,
                .commit_frame = App.loopCommitFrame,
                .poll_timeout_ms = if (comptime @hasDecl(App, "loopPollTimeoutMs")) App.loopPollTimeoutMs else null,
            };
        }
    };
}

fn renderReasonNames(
    reasons: render_request.ReasonSet,
    buf: *[128]u8,
) []const u8 {
    var len: usize = 0;
    for (std.meta.tags(render_request.Reason)) |reason| {
        if (!reasons.contains(reason)) continue;
        if (len > 0) {
            if (len == buf.len) break;
            buf[len] = ',';
            len += 1;
        }
        const name = @tagName(reason);
        const copy_len = @min(name.len, buf.len - len);
        @memcpy(buf[len..][0..copy_len], name[0..copy_len]);
        len += copy_len;
        if (copy_len < name.len) break;
    }
    if (len == 0) return "none";
    return buf[0..len];
}

fn FixedPointTranscriptContext(comptime App: type) type {
    return struct {
        app: *App,
        presentation_shell: *transcript_runtime.TranscriptRuntime,
        prepare_transcript: bool,
        source: ?*const transcript_runtime.TranscriptPreparationSource,
        prepared_transcript: *?transcript_painter.PreparedTranscriptSurfacePaint,
        resolved_target: *?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget,
        footer_reservation_changed: bool,
        replay_displaced_footer_history: bool,
        footer_measurement: ?*const surface_frame.SurfaceFooterMeasurement,
        fallback_footer_rows: ?render_engine.footer_layout.FooterRows,
        activity_projection: activity_runtime.ActivityProjection,
        frame_activity: render_engine.frame_layout.ActivityState,
        base_invalidation: render_engine.paint_plan.FrameInvalidationSet,
        attempt_invalidations: render_engine.paint_plan.FrameInvalidationSet,
        pending_tail_rows: u16 = 0,
        scroll_facts: ?transcript_runtime.TranscriptScrollFacts = null,

        fn prepareCandidate(
            self: *@This(),
            candidate: render_engine.frame_layout.FrameLayout,
        ) !render_engine.frame_fixed_point.CandidatePreparation {
            if (self.prepared_transcript.*) |*prepared| {
                prepared.deinit(self.app.alloc);
                self.prepared_transcript.* = null;
            }
            self.resolved_target.* = null;
            self.scroll_facts = null;
            if (!self.prepare_transcript or candidate.transcript_area.isEmpty()) return .{
                .inline_advance_rows = 0,
                .occupied_transcript_rows = candidate.transcript_area.height(),
            };
            const source = self.source orelse return error.MissingTranscriptPreparationSource;
            const canonical_area = transcriptAreaBeforePendingTail(
                candidate.transcript_area,
                self.pending_tail_rows,
            );

            self.prepared_transcript.* = try self.presentation_shell.prepareTranscriptSurfacePaintFromSourceForFrame(
                self.app.alloc,
                &self.app.metrics,
                source,
                canonical_area,
                self.footer_reservation_changed,
            );
            const prepared = &self.prepared_transcript.*.?;
            const scroll_facts = try self.presentation_shell.prepareTranscriptScrollFactsForFrame(
                self.app.alloc,
                source,
                prepared,
                self.footer_reservation_changed,
                self.replay_displaced_footer_history,
            );
            self.scroll_facts = scroll_facts;
            const canonical_occupied_rows = if (prepared.selection.last_visible_row >= canonical_area.top)
                prepared.selection.last_visible_row - canonical_area.top + 1
            else
                0;
            return .{
                .inline_advance_rows = scroll_facts.planned_rows,
                .occupied_transcript_rows = @min(
                    canonical_occupied_rows +| self.pending_tail_rows,
                    candidate.transcript_area.height(),
                ),
            };
        }

        fn resolveCandidate(
            self: *@This(),
            candidate: render_engine.frame_layout.FrameLayout,
            scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
        ) !render_engine.frame_fixed_point.CandidateResolution {
            const candidate_rows = candidate.transcript_area.height();
            if (!self.prepare_transcript or candidate.transcript_area.isEmpty()) {
                return .{ .occupied_transcript_rows = candidate_rows };
            }
            const source = self.source orelse return error.MissingTranscriptPreparationSource;
            const prepared = if (self.prepared_transcript.*) |*value| value else return error.MissingTranscriptPaint;
            const scroll_facts = self.scroll_facts orelse return error.MissingTranscriptScrollFacts;
            const footer_rows = if (self.footer_measurement) |measurement|
                measurement.frameLayoutRows(
                    self.presentation_shell.layout.rows,
                    candidate.footer_area.top,
                )
            else
                self.fallback_footer_rows orelse return error.MissingFooterRows;
            const activity = render_engine.activity_placement.resolve(
                self.activity_projection,
                self.frame_activity,
                candidate,
            );
            var candidate_plan = candidate.toPaintPlan(.{
                .footer_rows = footer_rows,
                .viewport = prepared.selection,
                .activity = activity,
                .invalidation = self.base_invalidation,
                .cursor_target = .{
                    .row = prepared.cursor.cursor_row,
                    .col = prepared.cursor.cursor_col,
                    .visible = true,
                },
            });
            candidate_plan.invalidation = try surface_invalidation.resolveCandidateFrameInvalidations(
                self.presentation_shell,
                candidate_plan,
                if (self.footer_measurement) |measurement|
                    measurement.frameInvalidationUpdate()
                else
                    null,
                self.attempt_invalidations,
            );
            const destructive_invalidation = render_engine.frame_retention.transcriptAreaHasDestructiveInvalidation(
                self.presentation_shell.committed_frame_layout.transcript_area,
                candidate_plan.invalidation,
            );
            const target = try self.presentation_shell.resolveTranscriptTransitionTargetForFrameInArea(
                self.app.alloc,
                source,
                prepared,
                render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(candidate),
                transcriptAreaBeforePendingTail(
                    candidate.transcript_area,
                    self.pending_tail_rows,
                ),
                scroll_plan,
                scroll_facts,
                destructive_invalidation,
                activity == .overlay_entry,
            );
            self.resolved_target.* = target;
            return .{ .occupied_transcript_rows = @min(
                target.occupiedTranscriptRows() +| self.pending_tail_rows,
                candidate.transcript_area.height(),
            ) };
        }
    };
}

fn transcriptAreaBeforePendingTail(
    area: render_engine.frame_layout.FrameRect,
    tail_rows: u16,
) render_engine.frame_layout.FrameRect {
    if (area.isEmpty() or tail_rows == 0) return area;
    // A tail taller than the band still leaves the flow endpoint row. Without
    // it the frame seals no transcript transition, and adoption would rebase
    // onto rows that never reached scrollback.
    const canonical_rows = @max(area.height() -| tail_rows, 1);
    return .{ .top = area.top, .bottom = area.top + canonical_rows - 1 };
}

fn FramePaintContext(comptime App: type) type {
    return struct {
        app: *App,
        presentation_shell: *transcript_runtime.TranscriptRuntime,
        body: render_engine.frame_builder.FrameBody,
        prepared_transcript: ?*const transcript_painter.PreparedTranscriptSurfacePaint,
        footer_frame: *const surface_frame.SurfaceFooterFrame,
        activity_style: shimmer_runtime.ActivityPaintStyle,
        activity_result: render_engine.paint_plan.ActivityPaintResult,

        fn paintBody(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (self.body) {
                .transcript => {
                    if (surface.plan.transcript_band.isEmpty()) return;
                    if (self.prepared_transcript) |prepared| {
                        _ = try self.presentation_shell.paintPreparedTranscriptIntoSurface(self.app.alloc, surface, prepared);
                    }
                },
                .subagent_panel => |text| {
                    if (surface.plan.transcript_band.isEmpty() or text.len == 0) return;
                    const rows = surface.plan.transcript_band.bottom - surface.plan.transcript_band.top + 1;
                    _ = try surface.writeAnsiBand(surface.plan.transcript_band.top, rows, text, .transcript, .same_owner);
                },
                .none => {},
            }
        }

        fn paintFooter(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = try footer_viewport.paintFooterIntoSurface(surface, &self.footer_frame.composed);
        }

        fn paintActivity(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.activity_result = try shimmer_runtime.paintActivityIntoSurface(surface, .{
                .label = self.footer_frame.label(),
                .tool_label = self.footer_frame.toolLabel(),
                .shimmer_pos = self.footer_frame.shimmer_pos,
                .style = self.activity_style,
                .thinking_blink = self.footer_frame.thinking_blink,
            });
        }
    };
}

fn validatePreparedTranscriptFitsPlan(
    prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
    plan: render_engine.paint_plan.PaintPlan,
) !void {
    const selection = prepared.selection;
    const has_prepared_rows = prepared.total_lines > 0 or selection.last_visible_row > 0;
    if (!has_prepared_rows) return;

    if (plan.transcript_band.isEmpty() or
        selection.top_row < plan.transcript_band.top or
        selection.bottom_row > plan.transcript_band.bottom or
        selection.last_visible_row > plan.transcript_band.bottom)
    {
        debug_trace.logf(
            "frame_plan",
            "prepared_transcript_outside_band selection={d}..{d} last_visible={d} transcript_band={d}..{d} total_lines={d}",
            .{
                selection.top_row,
                selection.bottom_row,
                selection.last_visible_row,
                plan.transcript_band.top,
                plan.transcript_band.bottom,
                prepared.total_lines,
            },
        );
        return error.InvalidPaintPlan;
    }
}

fn promptTurnReservation(
    app: anytype,
    shell: *const transcript_runtime.TranscriptRuntime,
    canonical_preview: render_engine.frame_layout.TranscriptFlowPreview,
    pending_card: ?PendingCardProjection,
    footer_measurement: ?*const surface_frame.SurfaceFooterMeasurement,
    frame_activity: render_engine.frame_layout.ActivityState,
) render_engine.frame_layout.PromptTurnReservation {
    if (frame_activity != .none) return .{};
    const measurement = footer_measurement orelse return .{};
    if (!measurement.input_visible or
        measurement.show_picker or
        measurement.picker_rows > 0 or
        measurement.banner_active or
        measurement.footer_gap_active or
        app.stream.active or
        shell.fullTranscriptActive()) return .{};
    if (comptime @hasField(@TypeOf(app.*), "skills")) {
        if (comptime @hasDecl(@TypeOf(app.skills), "menuVisible")) {
            if (app.skills.menuVisible()) return .{};
        }
    }

    const future_activity = render_engine.frame_layout.ActivityState.thinkingAfterUserTurn();
    const pending_submission_active = if (comptime @hasField(@TypeOf(app.*), "submission"))
        app.submission.pending != null
    else
        false;
    if (pending_card != null or pending_submission_active) {
        const canonical_rows = if (pending_card) |card|
            canonical_preview.natural_visual_rows +| (card.row_count -| 1)
        else
            canonical_preview.natural_visual_rows;
        return .{ .transcript_rows = canonical_rows, .activity = future_activity };
    }
    return .{};
}

fn footerMeasurementFromRows(rows: render_engine.footer_layout.FooterRows) render_engine.frame_layout.FooterMeasurement {
    return .{
        .natural_rows = rows.total_rows,
        .min_rows = 1,
        .max_rows = rows.total_rows,
        .input_rows = 1,
        .picker_rows = if (rows.picker_start <= rows.bottom_divider and rows.bottom_divider > rows.picker_divider)
            rows.bottom_divider - rows.picker_divider - 1
        else
            0,
        .banner_rows = rows.banner_rows,
    };
}

fn activityStateFromPlacement(activity: render_engine.activity_overlay.ActivityPlacement) render_engine.frame_layout.ActivityState {
    return switch (activity) {
        .transient_row => |transient| .{ .thinking = .{
            .gap_above_activity = transient.gap_above_rows,
            .activity_rows = transient.row_count,
            .footer_gap_after_activity = transient.footer_clearance_rows,
            .tool_before_activity = transient.tool_row != null,
        } },
        .overlay_entry => |row| .{ .overlay_entry = row },
        .none => .none,
    };
}

noinline fn frameActivityStateFromMeasurement(
    shell: *const transcript_runtime.TranscriptRuntime,
    measurement: *const surface_frame.SurfaceFooterMeasurement,
) render_engine.frame_layout.ActivityState {
    return switch (measurement.activity_projection) {
        .none => .none,
        .tool_slot => |slot| if (slot.active)
            transientActivityState(shell, measurement.activity_projection, slot.thinking_label != null)
        else
            .none,
        .turn_thinking => transientActivityState(shell, measurement.activity_projection, false),
    };
}

fn transientActivityState(
    shell: *const transcript_runtime.TranscriptRuntime,
    projection: activity_runtime.ActivityProjection,
    tool_before_activity: bool,
) render_engine.frame_layout.ActivityState {
    return .{ .thinking = .{
        .gap_above_activity = render_input.transientActivityGapRows(shell, tool_before_activity),
        .activity_rows = render_input.activityProjectionRows(projection, shell.layout.cols),
        .footer_gap_after_activity = render_engine.transcript_blocks.footerBoundaryGapRowsForTail(.turn_summary),
        .tool_before_activity = tool_before_activity,
    } };
}

fn framePlanBandsEqual(
    old: render_engine.paint_plan.PaintPlan,
    solved: render_engine.paint_plan.PaintPlan,
) bool {
    return frameBandsEqual(old.transcript_band, solved.transcript_band) and
        frameBandsEqual(old.blank_band, solved.blank_band) and
        frameBandsEqual(old.activity_band, solved.activity_band) and
        frameBandsEqual(old.footer_gap_band, solved.footer_gap_band) and
        frameBandsEqual(old.footer_band, solved.footer_band);
}

noinline fn frameBandsEqual(
    a: render_engine.paint_plan.FrameBand,
    b: render_engine.paint_plan.FrameBand,
) bool {
    return a.top == b.top and a.bottom == b.bottom and a.owner == b.owner;
}

noinline fn shouldResetPhysicalTerminal(
    alternate_screen_active: bool,
    main_reset_pending: bool,
) bool {
    return !alternate_screen_active and main_reset_pending;
}

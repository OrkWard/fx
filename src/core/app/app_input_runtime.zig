const std = @import("std");
const file_picker_path = @import("../input/file_picker_path.zig");
const question_prompt = @import("../agent/question_prompt.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_commands = @import("app_commands.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const composer_insertion = @import("../input/composer_insertion.zig");
const composer_stash = @import("../input/composer_stash.zig");
const gesture_state = @import("../input/gesture_state.zig");
const input_action = @import("../input/input_action.zig");
const input_limit_rejection = @import("../input/input_limit_rejection.zig");
const input_reset = @import("../input/input_reset.zig");
const picker_state = @import("../input/picker_state.zig");
const paste_framing = @import("../input/paste_framing.zig");
const text_scalar = @import("../input/text_scalar.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const image_commands = @import("../images/image_commands.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const approval_decision = @import("../permissions/approval_decision.zig");
const permissions = @import("../permissions/permissions.zig");
const session_commands = @import("../session/session_commands.zig");
const session_catalog = @import("../session/session_catalog.zig");
const usage_report = @import("../session/usage_report.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const types = @import("../shared/types.zig");
const visual_layout = @import("../../ui/input/visual_layout.zig");
const approval_prompt = @import("../permissions/approval_prompt.zig");
const picker_presentation = @import("../../ui/footer/picker_presentation.zig");
const compact_command_menu_presentation = @import("../../ui/footer/compact_command_menu_presentation.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const paste_blocks = @import("../input/pasted_blocks.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const input_interrupt_runtime = @import("input_interrupt_runtime.zig");
const input_history_runtime = @import("input_history_runtime.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const provider_picker_runtime = @import("provider_picker_runtime.zig");
const input_paste_runtime = @import("input_paste_runtime.zig");
const input_submit_runtime = @import("input_submit_runtime.zig");
const input_approval_runtime = @import("input_approval_runtime.zig");
const input_question_runtime = @import("input_question_runtime.zig");
const input_full_transcript_runtime = @import("input_full_transcript_runtime.zig");
const input_selection_runtime = @import("input_selection_runtime.zig");
const input_limit_feedback = @import("input_limit_feedback.zig");

pub const file_picker_completion_cap = input_completion_runtime.file_picker_completion_cap;
const ctrl_g_upgrade_byte: u8 = 7;

fn classifyResumeFailure(err: anyerror) session_catalog.ResumeFailure {
    return switch (err) {
        error.SessionBusy => .open_elsewhere,
        error.SessionAuthorityBoundaryUnavailable,
        error.SessionCommitBoundaryUnavailable,
        => .being_updated,
        else => .unavailable,
    };
}

const ExplicitModelSelection = struct {
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool,
    ultrafast_mode: bool = false,
    has_fast_mode_token: bool = false,
};

const ExplicitModelSelectionParse = union(enum) {
    none,
    invalid,
    selection: ExplicitModelSelection,
};

fn parseExplicitModelSelection(input: []const u8) ExplicitModelSelectionParse {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "/model")) return .none;
    if (trimmed.len == "/model".len) return .none;
    if (trimmed["/model".len] != ' ' and trimmed["/model".len] != '\t') return .none;

    var tokens: [4][]const u8 = undefined;
    var token_count: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, trimmed["/model".len..], " \t\r\n");
    while (iterator.next()) |token| {
        if (token_count == tokens.len) return .invalid;
        tokens[token_count] = token;
        token_count += 1;
    }
    if (token_count < 2) return .none;

    const effort = types.ReasoningEffort.parse(tokens[1]) orelse return .none;

    if (token_count == 2) {
        return .{ .selection = .{
            .model = tokens[0],
            .effort = effort,
            .fast_mode = false,
            .has_fast_mode_token = false,
        } };
    }

    if (token_count != 3) return .invalid;
    const fast_mode = std.ascii.eqlIgnoreCase(tokens[2], "fast");
    const ultrafast_mode = std.ascii.eqlIgnoreCase(tokens[2], "ultrafast");
    if (!fast_mode and !ultrafast_mode and !std.ascii.eqlIgnoreCase(tokens[2], "normal")) {
        return .invalid;
    }
    return .{ .selection = .{
        .model = tokens[0],
        .effort = effort,
        .fast_mode = fast_mode,
        .ultrafast_mode = ultrafast_mode,
        .has_fast_mode_token = true,
    } };
}

fn validateExplicitModelSelection(selection: ExplicitModelSelection, capabilities: model_capabilities.Capabilities) ExplicitModelSelectionParse {
    if (!model_capabilities.reasoningEffortSupported(capabilities, selection.effort)) return .invalid;
    if (!selection.has_fast_mode_token) return .{ .selection = selection };
    if (selection.ultrafast_mode and !capabilities.supports_ultrafast_mode) return .invalid;
    if (selection.fast_mode and !capabilities.supports_fast_mode) return .invalid;
    if (!selection.fast_mode and !selection.ultrafast_mode and
        !capabilities.supports_fast_mode and !capabilities.supports_ultrafast_mode)
    {
        return .invalid;
    }
    return .{ .selection = selection };
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const history_rt = input_history_runtime.HistoryRuntime(App);
        const completion_rt = input_completion_runtime.CompletionRuntime(App);
        const provider_picker_rt = provider_picker_runtime.Runtime(App);
        const paste_rt = input_paste_runtime.PasteEditRuntime(App);
        const submit_rt = input_submit_runtime.SubmitRuntime(App);
        const approval_rt = input_approval_runtime.ApprovalRuntime(App);
        const question_rt = input_question_runtime.QuestionRuntime(App);
        const interrupt_rt = input_interrupt_runtime.InterruptRuntime(App);
        const full_transcript_rt = input_full_transcript_runtime.Runtime(App);

        const ctrl_c_exit_window_ms = gesture_state.ctrl_c_exit_window_ms;
        const ResolvedEscapeRoute = union(enum) {
            done,
            remapped_byte: u8,
        };

        const routeSlashCompletionMove = completion_rt.routeSlashCompletionMove;
        const advanceModelPickerOnSpace = completion_rt.advanceModelPickerOnSpace;
        const routeModifiedHistory = completion_rt.routeModifiedHistory;
        const routePlainVertical = completion_rt.routePlainVertical;
        const routeVisiblePickerMove = completion_rt.routeVisiblePickerMove;
        const navigateModelPicker = completion_rt.navigateModelPicker;
        const cancelApprovalOperation = approval_rt.cancelApprovalOperation;

        const routeApprovalEscapeAction = approval_rt.routeApprovalEscapeAction;
        const routeQuestionEscapeAction = question_rt.routeQuestionEscapeAction;
        const submitQuestionBatch = question_rt.submitQuestionBatch;
        pub const rerenderQuestionBlock = question_rt.rerenderQuestionBlock;
        const finishPaste = paste_rt.finishPaste;
        const finalizePastedBlock = paste_rt.finalizePastedBlock;
        const handlePastedBytes = paste_rt.handlePastedBytes;
        const submit = submit_rt.submit;
        pub const installPromptHistory = history_rt.installPromptHistory;
        pub const loadAndInstallPromptHistory = history_rt.loadAndInstallPromptHistory;

        fn insertComposerSliceBounded(
            app: *App,
            bytes: []const u8,
            max_input_len: usize,
            preserve_model_picker: bool,
        ) !composer_insertion.InsertResult {
            const picker_policy: composer_insertion.PickerPolicy = if (preserve_model_picker)
                .preserve
            else
                .clear;
            return app.input_runtime.replacementState(&app.pending_images).replaceSelectionOrInsertSliceBounded(
                app.alloc,
                bytes,
                max_input_len,
                picker_policy,
            );
        }

        pub fn clearPendingImages(app: *App) void {
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.entities.image_tokens.clearRetainingCapacity();
            image_attachments.discardImageSnapshots(app.alloc, app.pending_images.items);
            for (app.pending_images.items) |image| {
                types.freeImageAttachment(app.alloc, image);
            }
            app.pending_images.clearRetainingCapacity();
        }

        pub fn releasePendingImages(app: *App) void {
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.entities.image_tokens.clearRetainingCapacity();
            for (app.pending_images.items) |image| {
                types.freeImageAttachment(app.alloc, image);
            }
            app.pending_images.clearRetainingCapacity();
        }

        fn routeComposerShortcutAction(app: *App, action: input_action.ShortcutAction, max_input_len: usize) !void {
            switch (action) {
                .move => |intent| {
                    switch (intent.kind) {
                        .character_left => {
                            app.input_runtime.vertical_navigation.reset();
                            if (!intent.extend_selection and
                                app.input_runtime.edit_state.selectionRange() == null)
                            {
                                if (!app.stream.active and try provider_picker_rt.stepBack(app)) {
                                    app.shell.render_requests.request(.footer);
                                    return;
                                }
                                if (try completion_rt.stepBackModelPicker(app)) {
                                    app.shell.render_requests.request(.footer);
                                    return;
                                }
                            }
                            _ = app.input_runtime.moveInputCursor(intent);
                        },
                        .character_right => {
                            app.input_runtime.vertical_navigation.reset();
                            // In the provider picker the arrows walk columns:
                            // Left reopens the previous one, Right acts as
                            // Enter on the highlighted row. Only from the end
                            // of the text, so Right keeps moving the cursor
                            // while editing.
                            if (!intent.extend_selection and
                                app.input_runtime.edit_state.selectionRange() == null and
                                !app.stream.active and
                                app.input_runtime.edit_state.cursor == app.input_runtime.edit_state.input.items.len and
                                try provider_picker_rt.submit(app))
                            {
                                app.shell.render_requests.request(.footer);
                                return;
                            }
                            if (!intent.extend_selection and
                                app.input_runtime.edit_state.selectionRange() == null)
                            {
                                switch (try completion_rt.autocompleteInlineCompletion(app, max_input_len)) {
                                    .inserted => {
                                        app.shell.render_requests.request(.footer);
                                        return;
                                    },
                                    .inactive => {},
                                    .limit_exceeded => {
                                        try input_limit_feedback.report(App, app, .composer, 1);
                                        app.shell.render_requests.request(.footer);
                                        return;
                                    },
                                }
                            }
                            _ = app.input_runtime.moveInputCursor(intent);
                        },
                        .word_left,
                        .word_right,
                        .line_start,
                        .line_end,
                        .draft_start,
                        .draft_end,
                        .paragraph_up,
                        .paragraph_down,
                        => {
                            completion_rt.abandonModelPickerOptions(app);
                            _ = app.input_runtime.moveInputCursor(intent);
                        },
                        .visual_up,
                        .visual_down,
                        .page_up,
                        .page_down,
                        => {
                            const direction: visual_layout.Direction = switch (intent.kind) {
                                .visual_up, .page_up => .up,
                                .visual_down, .page_down => .down,
                                else => unreachable,
                            };
                            const delta: i32 = if (direction == .up) -1 else 1;
                            try completion_rt.routeComposerVertical(
                                app,
                                direction,
                                delta,
                                intent.extend_selection,
                                intent.kind == .page_up or intent.kind == .page_down,
                            );
                        },
                    }
                    app.shell.render_requests.request(.footer);
                },
                .select_all => {
                    dismissActiveMenusThenRedraw(app);
                    if (app.input_runtime.selectionState().selectAll()) {
                        app.shell.render_requests.request(.footer);
                    }
                },
                .copy_selection => {
                    if (comptime @hasDecl(App, "clipboard")) {
                        if (input_selection_runtime.copySelection(
                            &app.input_runtime.edit_state,
                            app.clipboard(),
                        ) == .copy_failed) {
                            debug_trace.logf(
                                "input",
                                "composer selection copy preserved reason=clipboard_copy_failed",
                                .{},
                            );
                        }
                    }
                },
                .cut_selection => {
                    if (comptime @hasDecl(App, "clipboard")) {
                        switch (input_selection_runtime.cutSelection(
                            app.alloc,
                            app.input_runtime.selectionState(),
                            &app.pending_images,
                            app.clipboard(),
                        )) {
                            .cut => {
                                dismissActiveMenusThenRedraw(app);
                                syncCatalogMenus(app);
                                app.shell.render_requests.request(.footer);
                            },
                            .copy_failed => debug_trace.logf(
                                "input",
                                "composer selection cut preserved reason=clipboard_copy_failed",
                                .{},
                            ),
                            .delete_failed => debug_trace.logf(
                                "input",
                                "composer selection cut delete skipped reason=delete_failed",
                                .{},
                            ),
                            .inactive, .copied => {},
                        }
                    }
                },
                .undo => {
                    dismissActiveMenusThenRedraw(app);
                    if (try app.input_runtime.undoState().undo(app.alloc)) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .redo => {
                    dismissActiveMenusThenRedraw(app);
                    if (try app.input_runtime.undoState().redo(app.alloc)) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .redraw => {
                    if (!composerPickerSurfaceVisible(app) or
                        activeCatalogMenuOwnsByte(app, 12)) return;
                    if (comptime @hasField(App, "pacer") and
                        @hasField(App, "metrics") and
                        @hasDecl(@TypeOf(app.pacer), "discardDeferredPresentationForVisualEpoch"))
                    {
                        _ = try app_render_runtime.Runtime(App).resetVisualEpoch(app, .ctrl_l);
                    }
                },
                .history_next => {
                    try completion_rt.navigatePromptHistory(app, 1);
                    syncCatalogMenus(app);
                    app.shell.render_requests.request(.footer);
                },
                .delete_backward => {
                    if (app.input_runtime.edit_state.input.items.len > 0) {
                        const picker_policy: composer_insertion.PickerPolicy =
                            if (completion_rt.shouldPreserveModelPickerBackspace(app))
                                .preserve
                            else
                                .clear;
                        const changed = app.input_runtime.deletionState(
                            &app.pending_images,
                        ).delete(app.alloc, .character_left, picker_policy);
                        if (changed) {
                            app.input_runtime.picker.resetFilePickerIndex();
                            syncCatalogMenus(app);
                            app.shell.render_requests.request(.footer);
                        }
                    }
                },
                .delete_forward => {
                    dismissActiveMenusThenRedraw(app);
                    if (app.input_runtime.deletionState(&app.pending_images).delete(
                        app.alloc,
                        .character_right,
                        .clear,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_word_left => {
                    dismissActiveMenusThenRedraw(app);
                    completion_rt.abandonModelPickerOptions(app);
                    if (app.input_runtime.deletionState(&app.pending_images).delete(
                        app.alloc,
                        .word_left,
                        .clear,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_whitespace_word_left => {
                    if (try app.input_runtime.killRingState(&app.pending_images).delete(
                        app.alloc,
                        .whitespace_word_left,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_word_right => {
                    dismissActiveMenusThenRedraw(app);
                    completion_rt.abandonModelPickerOptions(app);
                    if (app.input_runtime.deletionState(&app.pending_images).delete(
                        app.alloc,
                        .word_right,
                        .clear,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_to_line_start => {
                    dismissActiveMenusThenRedraw(app);
                    if (try app.input_runtime.killRingState(&app.pending_images).delete(
                        app.alloc,
                        .line_start,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_to_line_end => {
                    dismissActiveMenusThenRedraw(app);
                    if (try app.input_runtime.killRingState(&app.pending_images).delete(
                        app.alloc,
                        .line_end,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .yank => {
                    const first_image_id = app.peekNextImageId();
                    switch (try app.input_runtime.killRingState(&app.pending_images).yank(
                        app.alloc,
                        first_image_id,
                        max_input_len,
                    )) {
                        .inserted => |image_count| {
                            for (0..image_count) |offset| {
                                const committed_id = app.nextImageId();
                                std.debug.assert(committed_id == first_image_id + offset);
                            }
                            syncCatalogMenus(app);
                            app.shell.render_requests.request(.footer);
                        },
                        .inactive => {},
                        .limit_exceeded => |attempted_bytes| try input_limit_feedback.report(
                            App,
                            app,
                            .composer,
                            attempted_bytes,
                        ),
                    }
                },
                .insert_newline => {
                    if (commandSkillsMenuActive(app) or modelMenuActive(app) or sessionMenuActive(app)) return;
                    dismissActiveMenusThenRedraw(app);
                    switch (try insertComposerSliceBounded(app, "\n", max_input_len, false)) {
                        .inserted => app.shell.render_requests.request(.footer),
                        .inactive => unreachable,
                        .limit_exceeded => try input_limit_feedback.report(App, app, .composer, 1),
                    }
                },
            }
        }

        fn routePrimaryComposerPointerAction(
            app: *App,
            pointer: input_action.MousePointer,
        ) bool {
            if (pointer.kind != .press or pointer.shift or pointer.alt or pointer.ctrl) return false;
            if (!app.shell.footer_viewport.has_frame) return false;

            const prefix_cells: u16 = @intCast(visual_layout.inputPrefix(0).cell_width);
            const position = app.shell.footer_viewport.geometry.inputPointerPosition(
                pointer.row,
                pointer.column,
                prefix_cells,
            ) orelse return false;
            const point = visual_layout.cursorPointAtPosition(.{
                .input = app.input_runtime.edit_state.input.items,
                .cursor = app.input_runtime.edit_state.cursor,
                .terminal_cols = app.shell.layout.cols,
                .pasted_blocks = app.input_runtime.entities.pasted_blocks.items,
                .skill_tokens = app.input_runtime.entities.skill_tokens.items,
            }, position.row_index, position.content_column) orelse return false;

            dismissActiveMenusThenRedraw(app);
            app.input_runtime.vertical_navigation.reset();
            if (app.input_runtime.edit_state.setCursor(point.raw_offset)) {
                app.shell.render_requests.request(.footer);
            }
            return true;
        }

        pub fn expireTerminalInputGestures(app: *App, now: i64) void {
            expireCtrlCExitArm(app, now);
            expireEscClearArm(app, now);
            expireEscapeInterruptArm(app, now);
        }

        fn terminalDecodeContext(
            app: *App,
            paste_active: bool,
        ) input_action.TerminalDecodeContext {
            if (paste_active) {
                return .{
                    .now_ms = 0,
                    .paste_active = true,
                    .cancel_pending = false,
                    .question_freeform_selected = false,
                };
            }
            return .{
                .now_ms = io_mod.milliTimestamp(),
                .paste_active = false,
                .cancel_pending = interrupt_rt.hasActiveOperation(app),
                .question_freeform_selected = app.question_prompt.isFreeformSelected(),
            };
        }

        pub fn prepareTerminalDecode(app: *App) !?input_action.TerminalDecodeContext {
            if (!try app_worker_runtime.Runtime(App).authorizeInteractiveAdmission(app)) return null;
            const paste_active = terminalPasteActive(app);
            return terminalDecodeContext(app, paste_active);
        }

        pub fn handleTerminalInputIngressWithLimits(
            app: *App,
            ingress: input_action.TerminalInputIngress,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !?u8 {
            if (!ingress.has_routing_work()) return null;
            if (terminalIngressCancelsPendingFullTranscriptOpen(ingress)) {
                _ = full_transcript_rt.cancelPendingOpenForInput(app);
            }

            defer completion_rt.reconcileFilePicker(app);
            // Runs first so the file picker reconciles against a restored draft.
            defer settleModelPickerDraft(app);

            const paste_was_active = terminalPasteActive(app);
            defer {
                const paste_is_active = terminalPasteActive(app);
                if (!paste_was_active and paste_is_active) {
                    shell_runtime.suspendResizeCursorProbeForPaste(&app.terminal_input_runtime.terminal_cursor_probe);
                } else if (paste_was_active and !paste_is_active) {
                    shell_runtime.resumeResizeCursorProbeAfterPaste(
                        &app.terminal_input_runtime.terminal_cursor_probe,
                        io_mod.milliTimestamp(),
                    );
                }
            }

            if (ingress.interrupts_pending_text and
                text_scalar.hasPending(app.input_runtime.text_scalar))
            {
                input_reset.resetPendingTextScalarWithTrace(
                    &app.input_runtime.text_scalar,
                    "interrupted_by_non_text_input",
                );
            }

            var replay_byte = ingress.replay_byte_after_routing;
            if (ingress.event) |event| {
                switch (event) {
                    .paste_byte => |byte| {
                        const routed = try routeActivePasteByte(app, byte);
                        std.debug.assert(routed);
                    },
                    .raw => |raw| try handleRawTerminalInputWithLimits(
                        app,
                        raw,
                        input_limits,
                        max_prompt_history,
                    ),
                    .action => |decoded| {
                        switch (try routeResolvedEscapeAction(
                            app,
                            decoded.action,
                            decoded.composer_shortcut,
                            decoded.approval_focused_edit,
                            decoded.question_action,
                            decoded.cancel_pending,
                            input_limits.composer_bytes,
                        )) {
                            .done => {},
                            .remapped_byte => |byte| {
                                std.debug.assert(replay_byte == null);
                                replay_byte = byte;
                            },
                        }
                    },
                }
            }
            return replay_byte;
        }

        pub fn flushPendingEscape(app: *App, input_escape_timeout_ms: i64) !void {
            const now = io_mod.milliTimestamp();
            expireTerminalInputGestures(app, now);
            const ingress = app.terminal_input_runtime.flushTerminalAction(
                now,
                input_escape_timeout_ms,
                terminalPasteActive(app),
            );
            if (ingress.event) |event| {
                switch (event) {
                    .action => |decoded| {
                        std.debug.assert(decoded.action == .escape);
                        disarmCtrlCExit(app, "semantic_action");
                        defer settleModelPickerDraft(app);
                        try resolveEscape(app, decoded.cancel_pending, now);
                    },
                    .paste_byte, .raw => unreachable,
                }
            }
        }

        pub fn handleTerminalByteAcrossSessionTransition(
            app: *App,
            byte: u8,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !void {
            const session_rt = app_session_runtime.Runtime(App);
            defer session_rt.finishDeferredSessionInputReplay(app);
            while (true) {
                if (app.session_persistence.pending_live_session_policy != null or
                    app.terminal_input_runtime.hasDeferredSessionInput())
                {
                    if (try app.terminal_input_runtime.deferSessionInputByte(app.alloc, byte, input_limits.composer_bytes)) return;
                    if (app.session_persistence.pending_live_session_policy != null) {
                        try session_rt.cancelPendingLiveSessionForInputLimit(app);
                    }
                    app.terminal_input_runtime.allowCurrentDeferredSessionInputForReplay();
                }
                _ = try flushDeferredSessionInput(app, input_limits, max_prompt_history);
                if (app.should_exit) return;
                if (app.session_persistence.pending_live_session_policy == null and
                    !app.terminal_input_runtime.hasDeferredSessionInput()) break;
            }
            try handleTerminalByteWithLimits(app, byte, input_limits, max_prompt_history);
        }

        pub fn flushDeferredSessionInput(
            app: *App,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !bool {
            var delivered = false;
            while (!app.should_exit and app.session_persistence.pending_live_session_policy == null) {
                const item = app.terminal_input_runtime.takeDeferredSessionInput() orelse break;
                delivered = true;
                switch (item) {
                    .byte => |byte| try handleTerminalByteWithLimits(app, byte, input_limits, max_prompt_history),
                    .delivery_epoch => try settleTerminalPasteDeliveryEpochWithLimits(app, input_limits),
                }
            }
            if (app.should_exit) {
                const dropped = app.terminal_input_runtime.discardDeferredSessionInput();
                if (dropped > 0) debug_trace.logf("input", "deferred session input dropped bytes={d} reason=quit", .{dropped});
            }
            return delivered;
        }

        pub fn handleTerminalByte(app: *App, byte: u8, max_input_len: usize, max_prompt_history: usize) !void {
            return handleTerminalByteWithLimits(
                app,
                byte,
                paste_framing.InputLimits.single(max_input_len),
                max_prompt_history,
            );
        }

        pub fn handleTerminalByteWithLimits(
            app: *App,
            byte: u8,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !void {
            var context = try prepareTerminalDecode(app) orelse return;
            var ingress = app.terminal_input_runtime.decodeTerminalByte(
                byte,
                context,
            );
            while (true) {
                const replay_byte = try handleTerminalInputIngressWithLimits(
                    app,
                    ingress,
                    input_limits,
                    max_prompt_history,
                );
                const replay = replay_byte orelse return;
                context = try prepareTerminalDecode(app) orelse return;
                ingress = app.terminal_input_runtime.decodeTerminalByte(replay, context);
            }
        }

        pub fn terminalPasteActive(app: *const App) bool {
            return app.input_runtime.paste.active();
        }

        fn terminalIngressCancelsPendingFullTranscriptOpen(
            ingress: input_action.TerminalInputIngress,
        ) bool {
            const event = ingress.event orelse return false;
            return switch (event) {
                .paste_byte, .raw => true,
                .action => |decoded| decoded.action != .toggle_full_transcript,
            };
        }

        pub fn routeActivePasteIngressByteWithLimits(
            app: *App,
            byte: u8,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !bool {
            if (!terminalPasteActive(app)) return false;
            const replay_byte = try handleTerminalInputIngressWithLimits(
                app,
                .{ .event = .{ .paste_byte = byte } },
                input_limits,
                max_prompt_history,
            );
            std.debug.assert(replay_byte == null);
            return true;
        }

        pub fn settleTerminalPasteDeliveryEpochWithLimits(
            app: *App,
            input_limits: paste_framing.InputLimits,
        ) !void {
            const paste_was_active = terminalPasteActive(app);
            if (!paste_was_active) return;
            defer if (!terminalPasteActive(app)) {
                shell_runtime.resumeResizeCursorProbeAfterPaste(
                    &app.terminal_input_runtime.terminal_cursor_probe,
                    io_mod.milliTimestamp(),
                );
            };

            if (app.input_runtime.paste.active()) {
                const settled = try paste_rt.settlePasteDeliveryEpoch(
                    app,
                    input_limits.forOwner(app.input_runtime.paste.owner),
                );
                if (settled and !app.input_runtime.paste.active()) {
                    syncCatalogMenus(app);
                    settleModelPickerDraft(app);
                }
            }
        }

        pub const prepareFilePicker = completion_rt.prepareFilePicker;
        pub const collectFilePickerFacts = completion_rt.collectFilePickerFacts;

        pub fn handleByte(app: *App, byte: u8, max_input_len: usize, max_prompt_history: usize) !void {
            return handleTerminalByteWithLimits(
                app,
                byte,
                paste_framing.InputLimits.single(max_input_len),
                max_prompt_history,
            );
        }

        fn routeActivePasteByte(
            app: *App,
            byte: u8,
        ) !bool {
            if (app.input_runtime.paste.active()) {
                try paste_rt.handleActivePasteByte(app, byte);
                return true;
            }
            return false;
        }

        fn handleRawTerminalInputWithLimits(
            app: *App,
            raw: input_action.RawTerminalInput,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !void {
            const byte = raw.byte;
            const max_input_len = input_limits.composer_bytes;
            // Fire the max-level cue only when the slash menu becomes visible.
            const slash_menu_was_visible = slashMenuVisibleForCue(app);
            defer announceSlashMenuOpened(app, slash_menu_was_visible);
            if (try routeActivePasteByte(app, byte)) return;

            if (byte != 3 and byte != 0x1b) disarmCtrlCExit(app, "raw_input");

            // Non-escape input disarms the pending double-Escape clear.
            if (byte != 0x1b) {
                if (disarmEscapeClear(app)) {
                    app.shell.render_requests.request(.footer);
                }
                _ = disarmEscapeInterrupt(app, "raw_input");
            }

            // Ctrl-Z arrives as raw byte 26 (ISIG disabled); kitty remaps here too.
            if (byte == 26) {
                try app.suspendToJobControl();
                return;
            }

            {
                if (try app_auth_runtime.Runtime(App).routeAuthPickerByte(app, byte)) return;
            }
            if (try full_transcript_rt.routeByte(app, byte)) return;
            if (try routeActiveModalInput(app, raw, input_limits.decision_bytes)) return;
            if (byte >= 0x80) {
                try handleTextByte(app, .composer, byte, max_input_len);
                return;
            }
            if (try routeUpgradeShortcut(app, byte)) return;
            if (try routePickerControlByte(app, byte)) return;

            if (isComposerEditingByte(byte, raw.composer_shortcut) and
                !activeCatalogMenuOwnsByte(app, byte) and
                dismissActiveMenusForComposerEdit(app))
            {
                app.shell.render_requests.request(.footer);
            }
            try handleComposerByte(
                app,
                byte,
                raw.composer_shortcut,
                max_input_len,
                max_prompt_history,
            );
        }

        fn routeResolvedEscapeAction(
            app: *App,
            resolved: input_action.Action,
            composer_shortcut: ?input_action.ShortcutAction,
            approval_focused_edit: ?approval_decision.DraftAction,
            question_action: ?question_prompt.Action,
            was_cancel_pending: bool,
            max_input_len: usize,
        ) !ResolvedEscapeRoute {
            switch (resolved) {
                .remapped_byte, .paste_start, .paste_end, .ignore => {},
                else => disarmCtrlCExit(app, "semantic_action"),
            }
            // Any other semantic key stands down an armed interrupt.
            switch (resolved) {
                .remapped_byte, .paste_start, .paste_end, .ignore, .escape => {},
                else => _ = disarmEscapeInterrupt(app, "semantic_action"),
            }

            if (resolved == .escape) {
                if (try full_transcript_rt.routeAction(app, resolved)) {
                    _ = disarmEscapeInterrupt(app, "full_transcript");
                    return .done;
                }
                const now = io_mod.milliTimestamp();
                expireEscClearArm(app, now);
                try resolveEscape(app, was_cancel_pending, now);
                return .done;
            }

            if (app_auth_runtime.Runtime(App).routeAuthPickerEscapeAction(app, resolved)) {
                return .done;
            }

            if (try full_transcript_rt.routeAction(app, resolved)) return .done;

            if (resolved == .paste_start) {
                if (comptime @hasDecl(@TypeOf(app.auth), "signInCodeEntryActive")) {
                    if (app.auth.signInCodeEntryActive()) {
                        paste_rt.beginPaste(app, max_input_len);
                        return .done;
                    }
                }
                dismissActiveMenusThenRedraw(app);
                paste_rt.beginPaste(app, max_input_len);
                return .done;
            }

            if (resolved == .paste_end) {
                return .done;
            }

            switch (resolved) {
                .remapped_byte => |byte| return .{ .remapped_byte = byte },
                else => {},
            }

            if (app.question_prompt.isActive()) {
                try question_rt.routeQuestionEscapeAction(
                    app,
                    resolved,
                    question_action,
                );
                return .done;
            }

            if (app.approval_prompt.isActive()) {
                try approval_rt.routeApprovalEscapeAction(
                    app,
                    resolved,
                    approval_focused_edit,
                );
                return .done;
            }

            if (resolved == .mouse_pointer and
                routePrimaryComposerPointerAction(app, resolved.mouse_pointer))
            {
                return .done;
            }

            if (activeCompactCommandMenu(app)) |menu| {
                try routeCompactCommandMenuEscapeAction(app, menu, resolved);
                return .done;
            }

            if (settingsMenuActive(app) and
                (resolved == .cursor_left or resolved == .cursor_right))
            {
                try changeSettingsMenuSelection(
                    app,
                    if (resolved == .cursor_left) -1 else 1,
                );
                return .done;
            }

            if (try full_transcript_rt.routeComposerAction(app, resolved)) return .done;

            if (composer_shortcut) |action| {
                try routeComposerShortcutAction(app, action, max_input_len);
                return .done;
            }

            switch (resolved) {
                .history_up => {
                    try completion_rt.routeModifiedHistory(app, .up, -1);
                    app.shell.render_requests.request(.footer);
                },
                .history_down => {
                    try completion_rt.routeModifiedHistory(app, .down, 1);
                    app.shell.render_requests.request(.footer);
                },
                .cursor_up => {
                    try completion_rt.routePlainVertical(app, .up, -1);
                    app.shell.render_requests.request(.footer);
                },
                .cursor_down => {
                    try completion_rt.routePlainVertical(app, .down, 1);
                    app.shell.render_requests.request(.footer);
                },
                .cursor_left,
                .cursor_right,
                .word_left,
                .word_right,
                .home,
                .end,
                .delete_next,
                .delete_word_left,
                .delete_word_right,
                .delete_to_line_start,
                .delete_to_line_end,
                .insert_newline,
                .composer_shortcut,
                .toggle_full_transcript,
                => unreachable,
                .page_up,
                .page_down,
                .mouse_wheel,
                .mouse_pointer,
                => {},
                .clear_line => {
                    dismissActiveMenusThenRedraw(app);
                    if (draftHasState(app)) {
                        clearDraftState(app, "clear_line");
                        app.shell.render_requests.request(.footer);
                    }
                },
                .toggle_permission_mode => {
                    if (cycleHelpMenuCategory(app, -1) or cycleSettingsMenuCategory(app, -1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (try toggleSessionPickerScopeIfActive(app)) {
                        app.shell.render_requests.request(.footer);
                    } else if (cycleModelMenuProvider(app, -1) or cycleSkillsMenuSource(app, -1)) {
                        app.shell.render_requests.request(.footer);
                    } else {
                        try app_permission_runtime.Runtime(App).toggleMode(app);
                    }
                },
                .open_all_sessions => {
                    if (comptime @hasField(App, "session_persistence")) {
                        if (settingsMenuActive(app) or helpMenuActive(app) or skillsMenuActive(app) or modelMenuActive(app)) return .done;
                        if (try refuseSessionActionWithDraft(app, "submit or clear the draft before switching sessions")) return .done;
                        dismissActiveMenusThenRedraw(app);
                        try app_session_runtime.Runtime(App).openAllSessionPicker(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .open_model_catalog => {
                    if (comptime @hasField(App, "model_cache")) {
                        // A second Ctrl+P backs out of the shortcut's flow
                        // from the catalog or its inline effort and fast stages.
                        if (exitModelPickerShortcutIfActive(app)) return .done;
                        if (modelMenuActive(app)) {
                            _ = closeModelMenu(app, true);
                            app.shell.render_requests.request(.footer);
                            return .done;
                        }
                        if (modelPickerShortcutBlocked(app)) return .done;
                        try openModelPickerShortcut(app);
                    }
                },
                .paste_start => dismissActiveMenusThenRedraw(app),
                .paste_end => {},
                .remapped_byte => unreachable,
                .escape => unreachable,
                .ignore => {},
            }
            return .done;
        }

        fn routePickerControlByte(app: *App, byte: u8) !bool {
            if (!composerPickerSurfaceVisible(app)) return false;
            const delta = pickerControlDelta(byte) orelse return false;
            if (!try routeVisiblePickerMove(app, delta)) return false;
            app.input_runtime.vertical_navigation.reset();
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn pickerControlDelta(byte: u8) ?i32 {
            return switch (byte) {
                10 => 1,
                11 => -1,
                else => null,
            };
        }

        fn composerPickerSurfaceVisible(app: *App) bool {
            if (app.question_prompt.isActive() or approvalOwnsCurrentSurface(app)) return false;
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.fullTranscriptScreenActive()) return false;
            }
            return true;
        }

        fn routeUpgradeShortcut(app: *App, byte: u8) !bool {
            if (byte != ctrl_g_upgrade_byte) return false;
            if (comptime @hasDecl(App, "applyReadyUpgradeShortcut")) {
                try app.applyReadyUpgradeShortcut();
            }
            return true;
        }

        fn routeActiveModalInput(
            app: *App,
            raw: input_action.RawTerminalInput,
            max_input_len: usize,
        ) !bool {
            const byte = raw.byte;
            if ((app.question_prompt.isActive() or approvalOwnsCurrentSurface(app)) and byte == ctrl_g_upgrade_byte) {
                _ = try routeUpgradeShortcut(app, byte);
                return true;
            }
            if (app.question_prompt.isActive()) {
                if (byte >= 0x80) {
                    if (app.question_prompt.isFreeformSelected()) {
                        try handleTextByte(app, .question_freeform, byte, max_input_len);
                    } else {
                        input_reset.resetPendingTextScalarWithTrace(
                            &app.input_runtime.text_scalar,
                            "question_decision_active",
                        );
                    }
                    return true;
                }
                if (raw.question_action) |action| {
                    switch (try question_rt.handleQuestionActionBounded(
                        app,
                        action,
                        max_input_len,
                    )) {
                        .consumed => app.input_runtime.input_limit_rejection = input_limit_rejection.clear(),
                        .ignored => {},
                        .limit_exceeded => try input_limit_feedback.report(App, app, .question_freeform, 1),
                    }
                }
                return true;
            }
            if (approvalOwnsCurrentSurface(app)) {
                if (byte >= 0x80) {
                    if (app.approval_prompt.isAmending()) {
                        try handleTextByte(app, .approval_amendment, byte, max_input_len);
                    } else {
                        input_reset.resetPendingTextScalarWithTrace(
                            &app.input_runtime.text_scalar,
                            "approval_decision_active",
                        );
                    }
                    return true;
                }
                if (raw.approval_action) |action| {
                    switch (try approval_rt.handlePermissionActionBounded(
                        app,
                        action,
                        max_input_len,
                    )) {
                        .consumed => app.input_runtime.input_limit_rejection = input_limit_rejection.clear(),
                        .ignored => {},
                        .limit_exceeded => try input_limit_feedback.report(App, app, .approval_amendment, 1),
                    }
                }
                return true;
            }
            if (activeCompactCommandMenu(app)) |menu| {
                if (byte >= 0x80) {
                    input_reset.resetPendingTextScalarWithTrace(
                        &app.input_runtime.text_scalar,
                        "compact_command_menu_active",
                    );
                    return true;
                }
                switch (byte) {
                    '\t' => if (menu == .usage) {
                        try cycleUsageMenuScope(app, 1);
                    },
                    '\r' => try submitCompactCommandMenuSelection(app, menu, max_input_len),
                    'r', 'R' => if (menu == .usage) {
                        {
                            try reloadUsageMenu(
                                app,
                                app.input_runtime.usage_menu.navigationScope(),
                            );
                        }
                    },
                    10 => {
                        _ = moveCompactCommandMenu(app, menu, 1);
                        app.shell.render_requests.request(.footer);
                    },
                    11 => {
                        _ = moveCompactCommandMenu(app, menu, -1);
                        app.shell.render_requests.request(.footer);
                    },
                    else => {},
                }
                return true;
            }
            return false;
        }

        fn presentedSubagentApproval(app: *const App) bool {
            _ = app;
            return false;
        }

        fn approvalOwnsCurrentSurface(app: *const App) bool {
            return app.approval_prompt.isActive();
        }

        fn handleTextByte(app: *App, owner: text_scalar.Owner, byte: u8, max_input_len: usize) !void {
            const transition = text_scalar.advance(app.input_runtime.text_scalar, owner, byte);
            app.input_runtime.text_scalar = transition.next;
            const step = transition.step;
            if (step.dropped) |drop| {
                debug_trace.logf(
                    "input",
                    "text scalar dropped owner={s} bytes={d} reason={s}",
                    .{ @tagName(drop.owner), drop.bytes, @tagName(drop.reason) },
                );
            }
            const scalar = step.scalar orelse return;
            const bytes = scalar.slice();
            switch (scalar.owner) {
                .question_freeform => switch (try app.question_prompt.insertFreeformSlice(app.alloc, bytes, max_input_len)) {
                    .inserted => {
                        app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
                        app.shell.render_requests.request(.modal);
                    },
                    .inactive => {},
                    .limit_exceeded => try input_limit_feedback.report(App, app, .question_freeform, bytes.len),
                },
                .approval_amendment => switch (try app.approval_prompt.decision.insertAmendmentSlice(app.alloc, bytes, max_input_len)) {
                    .inserted => {
                        app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
                        app.shell.render_requests.request(.modal);
                    },
                    .inactive => {},
                    .limit_exceeded => try input_limit_feedback.report(App, app, .approval_amendment, bytes.len),
                },
                .composer => {
                    if (!app.input_runtime.replacementState(&app.pending_images).canReplaceSelectionOrInsert(
                        bytes.len,
                        max_input_len,
                    )) {
                        try input_limit_feedback.report(App, app, .composer, bytes.len);
                        return;
                    }
                    if (dismissActiveMenusForComposerEdit(app)) {
                        app.shell.render_requests.request(.footer);
                    }
                    switch (try insertComposerSliceBounded(
                        app,
                        bytes,
                        max_input_len,
                        completion_rt.shouldPreserveModelPickerInsert(app),
                    )) {
                        .inserted => {},
                        .inactive => unreachable,
                        .limit_exceeded => {
                            try input_limit_feedback.report(App, app, .composer, bytes.len);
                            return;
                        },
                    }
                    app.input_runtime.picker.resetFilePickerIndex();
                    syncCatalogMenus(app);
                    app.shell.render_requests.request(.footer);
                },
            }
        }

        fn handleComposerByte(
            app: *App,
            byte: u8,
            composer_shortcut: ?input_action.ShortcutAction,
            max_input_len: usize,
            max_prompt_history: usize,
        ) !void {
            switch (byte) {
                3 => {
                    try handleSemanticCtrlC(app);
                },
                4 => {
                    try handleSemanticCtrlD(app, max_input_len);
                },
                '\t' => {
                    if (cycleHelpMenuCategory(app, 1) or cycleSettingsMenuCategory(app, 1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (moveAuthPickerIfActive(app, 1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (try toggleSessionPickerScopeIfActive(app)) {
                        app.shell.render_requests.request(.footer);
                    } else if (cycleModelMenuProvider(app, 1) or cycleSkillsMenuSource(app, 1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (picker_state.isBareModelCommandAtCursor(&app.input_runtime.edit_state)) {
                        try completion_rt.openCurrentModelPicker(app);
                    } else if (completion_rt.hasFileQuery(app)) {
                        if ((try completion_rt.autocompleteFilePickerSelection(app, max_input_len)) == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                        }
                        app.shell.render_requests.request(.footer);
                    } else if (!commandSkillsMenuActive(app) and provider_picker_rt.hasQuery(app)) {
                        if (!app.stream.active) try provider_picker_rt.autocomplete(app);
                    } else if (!commandSkillsMenuActive(app) and completion_rt.hasModelQuery(app)) {
                        try completion_rt.autocompleteModelPickerSelection(app);
                    } else if (completion_rt.visibleInlineCompletion(app) != null) {
                        if ((try completion_rt.autocompleteInlineCompletion(app, max_input_len)) == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                        }
                        app.shell.render_requests.request(.footer);
                    } else if (!(app.stream.active and app.input_runtime.picker.isModelShapedInput(&app.input_runtime.edit_state))) {
                        const count = completion_rt.visibleSlashCompletionCount(app);
                        if (count > 0) {
                            const items = app.input_runtime.edit_state.input.items;
                            const prefix = command_specs.slashCompletionPrefix(
                                app.slashRegistry(),
                                items,
                            ) orelse return;
                            const idx = app.input_runtime.picker.slash_completion_index % count;
                            if (try bindSelectedSlashSkill(app, idx)) {
                                app.shell.render_requests.request(.footer);
                            } else if (command_specs.nthSlashCompletion(app.slashRegistry(), prefix, idx)) |completion| {
                                if (command_specs.slashCompletionHasArgs(app.slashRegistry(), completion)) {
                                    var buf: [128]u8 = undefined;
                                    const with_space = std.mem.print(&buf, "{s} ", .{completion}) catch completion;
                                    try app.input_runtime.textReplacementState().replace(app.alloc, with_space);
                                } else {
                                    try app.input_runtime.textReplacementState().replace(app.alloc, completion);
                                }
                                app.shell.render_requests.request(.footer);
                            }
                        }
                    }
                },
                ' ' => {
                    dismissMentionSkillsMenuForSpace(app);
                    if (app.input_runtime.edit_state.selectionRange() == null and
                        !commandSkillsMenuActive(app) and
                        completion_rt.hasModelQuery(app))
                    {
                        if (try completion_rt.advanceModelPickerOnSpace(app)) {
                            app.shell.render_requests.request(.footer);
                        }
                    } else if (app.input_runtime.edit_state.selectionRange() == null and
                        !app.stream.active and
                        !commandSkillsMenuActive(app) and
                        provider_picker_rt.hasQuery(app) and
                        try provider_picker_rt.advanceOnSpace(app))
                    {
                        app.shell.render_requests.request(.footer);
                    } else {
                        switch (try insertComposerSliceBounded(app, " ", max_input_len, false)) {
                            .inserted => {
                                syncCatalogMenus(app);
                                app.shell.render_requests.request(.footer);
                            },
                            .inactive => unreachable,
                            .limit_exceeded => try input_limit_feedback.report(App, app, .composer, 1),
                        }
                    }
                },
                22 => {
                    if (paste_rt.modelPickerBorrowsComposer(app)) {
                        debug_trace.logf("input", "image attach skipped reason=model_picker_borrows_composer", .{});
                        return;
                    }
                    try image_commands.Commands(App).attachClipboard(app);
                },
                24 => {
                    return;
                },
                '\r' => {
                    if (try submitSettingsMenuSelection(app)) return;
                    if (try submitHelpMenuSelection(app, max_input_len, max_prompt_history)) return;
                    if (try submitAuthPickerSelection(app)) return;
                    if (try submitModelMenuSelection(app)) return;
                    if (try submitSkillsMenuSelection(app, max_input_len)) return;
                    if (try submitSlashPickerSelection(app)) return;
                    {
                        if (try submitSessionPickerSelection(app)) return;
                    }
                    if (try completion_rt.submitFilePickerOnEnter(app, max_input_len)) |result| {
                        if (result == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                        }
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    if (picker_state.isBareModelCommandAtCursor(&app.input_runtime.edit_state)) {
                        try openModelBrowseCatalog(app);
                        return;
                    }
                    if (provider_picker_rt.hasQuery(app)) {
                        if (try app_auth_runtime.Runtime(App).reject_provider_picker_if_busy(app)) return;
                        if (try provider_picker_rt.submit(app)) return;
                    }
                    if (completion_rt.hasModelQuery(app)) {
                        if (try completion_rt.submitModelPicker(app)) return;
                    }
                    if (try submitExplicitModelSelection(
                        app,
                        resolveExplicitModelSelection(app, app.input_runtime.edit_state.input.items),
                    )) return;
                    // A Ctrl+P flow's borrowed composer holds only a picker
                    // query. Submitting it as a prompt or command would act
                    // on the stashed draft's pending images.
                    if (app.input_runtime.model_picker_draft != null) {
                        debug_trace.logf("input", "submit skipped reason=model_picker_borrows_composer", .{});
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    if (app.input_runtime.lineContinuationState().replaceBackslashBeforeCursorWithNewline(app.alloc)) {
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    debug_trace.logf("input", "submit requested stream_active={s} queued={d} input_bytes={d}", .{ if (app.stream.active) "true" else "false", app.worker.queuedPromptCount(), app.input_runtime.edit_state.input.items.len });
                    try submit_rt.submit(app, max_prompt_history);
                },
                else => {
                    if (composer_shortcut) |action| {
                        try routeComposerShortcutAction(app, action, max_input_len);
                        return;
                    }
                    if (byte >= 32 and byte != 127) {
                        const insertion_start = if (app.input_runtime.edit_state.selectionRange()) |selection|
                            selection.start
                        else
                            app.input_runtime.edit_state.cursor;
                        if (byte == '$' and !file_picker_path.contains_position(app.input_runtime.edit_state.input.items, insertion_start) and !helpMenuActive(app) and !commandSkillsMenuActive(app) and !modelMenuActive(app)) {
                            if ((try insertComposerSliceBounded(app, &.{byte}, max_input_len, false)) == .limit_exceeded) {
                                try input_limit_feedback.report(App, app, .composer, 1);
                                return;
                            }
                            app.input_runtime.picker.resetInlinePickerEpisode();
                            if (comptime @hasField(App, "skills")) {
                                app.skills.openMenuWithQuery(.dollar, .{ .start = insertion_start, .end = insertion_start + 1 }, "");
                            }
                            app.input_runtime.picker.resetFilePickerIndex();
                            app.shell.render_requests.request(.footer);
                            return;
                        }
                        const result = try insertComposerSliceBounded(
                            app,
                            &.{byte},
                            max_input_len,
                            completion_rt.shouldPreserveModelPickerInsert(app),
                        );
                        if (result == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                            return;
                        }
                        app.input_runtime.picker.resetFilePickerIndex();
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
            }
        }

        /// While the picker borrows the composer, destructive global gestures
        /// back out of the picker and restore the draft instead of acting on
        /// the empty borrowed composer (clearing draft state would free the
        /// stashed draft's pending image payloads; exiting would hand off an
        /// empty composer). The restore also covers the inline effort and
        /// fast stages, which borrow the composer after the menu closes.
        fn exitModelPickerShortcutIfActive(app: *App) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (app.input_runtime.model_picker_draft == null) return false;
            _ = closeModelMenu(app, true);
            restoreModelPickerDraft(app);
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn handleSemanticCtrlC(app: *App) !void {
            if (exitModelPickerShortcutIfActive(app)) return;
            if (app.stream.active and draftHasState(app)) {
                clearDraftState(app, "ctrl_c");
                app.shell.render_requests.request(.footer);
                return;
            }

            const now = io_mod.milliTimestamp();
            const transition = gesture_state.pressCtrlCExit(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.result == .activated) {
                debug_trace.logf("shutdown", "ctrl_c_exit_activated", .{});
                app_session_runtime.Runtime(App).requestResumeHandoff(app);
                app.should_exit = true;
                return;
            }

            debug_trace.logf("input", "ctrl_c_exit_hint_armed", .{});

            if (interrupt_rt.hasActiveOperation(app)) {
                try interrupt_rt.cancelActiveOperation(app);
                app.shell.render_requests.request(.footer);
                return;
            }

            if (comptime @hasDecl(App, "cancelPendingSubmission")) {
                if (App.cancelPendingSubmission(app)) return;
            }

            if (draftHasState(app)) clearDraftState(app, "ctrl_c");
            app.shell.render_requests.request(.footer);
        }

        fn draftHasState(app: *App) bool {
            return app.input_runtime.edit_state.input.items.len > 0 or
                app.input_runtime.entities.pasted_blocks.items.len > 0 or
                app.pending_images.items.len > 0;
        }

        fn refuseSessionActionWithDraft(app: *App, body: []const u8) !bool {
            if (!draftHasState(app)) return false;
            try app.writeDomainNotice(.{
                .topic = "session",
                .tone = .neutral,
                .body = body,
            }, true);
            return true;
        }

        fn clearDraftState(app: *App, reason: []const u8) void {
            debug_trace.logf(
                "input",
                "draft cleared reason={s} input_bytes={d} pasted_blocks={d} images={d}",
                .{
                    reason,
                    app.input_runtime.edit_state.input.items.len,
                    app.input_runtime.entities.pasted_blocks.items.len,
                    app.pending_images.items.len,
                },
            );
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.clearPendingImages();
            syncCatalogMenus(app);
        }

        fn handleSemanticCtrlD(app: *App, max_input_len: usize) !void {
            if (exitModelPickerShortcutIfActive(app)) return;
            if (app.input_runtime.edit_state.input.items.len > 0) {
                try routeComposerShortcutAction(app, .delete_forward, max_input_len);
                return;
            }
            if (app.stream.active) return;
            app_session_runtime.Runtime(App).requestResumeHandoff(app);
            app.should_exit = true;
        }

        fn isComposerEditingByte(
            byte: u8,
            composer_shortcut: ?input_action.ShortcutAction,
        ) bool {
            if (composer_shortcut) |shortcut| {
                return switch (shortcut) {
                    .redraw => false,
                    else => true,
                };
            }
            return switch (byte) {
                ' ', 22 => true,
                else => byte >= 32 and byte != 127,
            };
        }

        fn activeCatalogMenuOwnsByte(app: *App, byte: u8) bool {
            if (settingsMenuActive(app)) return true;
            if (helpMenuActive(app)) return true;
            if (modelMenuActive(app)) return true;
            if (sessionMenuActive(app)) return true;
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            return byte == ' ' or commandSkillsMenuActive(app);
        }

        fn moveAuthPickerIfActive(app: *App, delta: i32) bool {
            if (comptime !@hasField(App, "auth")) return false;
            if (app.stream.active) return false;
            return app.auth.movePicker(delta);
        }

        fn submitSessionPickerSelection(app: *App) !bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            if (!app.session_persistence.session_picker.active) return false;

            if (app.loadMoreSessionPicker() catch |err| {
                const notice = try app.alloc.print(
                    "unable to load more saved sessions: {s}",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = notice }, true);
                app.shell.render_requests.request(.footer);
                return true;
            }) return true;

            if (app.session_persistence.session_picker.selectedId() == null) return true;

            _ = app.resumeSelectedSession() catch |err| {
                const picker = &app.session_persistence.session_picker;
                debug_trace.logf(
                    "session",
                    "picker resume failed err={s} picker_active={s}",
                    .{ @errorName(err), if (picker.active) "true" else "false" },
                );
                if (picker.active) {
                    picker.selection_failure = classifyResumeFailure(err);
                } else {
                    try app.writeDomainNotice(.{
                        .topic = "session",
                        .tone = .@"error",
                        .body = "Unable to resume selected session.",
                    }, true);
                }
                app.shell.render_requests.request(.footer);
                return true;
            };
            return true;
        }

        fn dismissAuthPickerForComposerEdit(app: *App) bool {
            if (comptime !@hasField(App, "auth")) return false;
            if (!app.auth.pickerView().active) return false;
            cancelPromptRetryAfterAuth(app);
            app.auth.closePicker(app.alloc);
            return true;
        }

        fn popOrCloseAuthPicker(app: *App) bool {
            if (comptime !@hasField(App, "auth")) return false;
            const picker = app.auth.pickerView();
            if (!picker.active) return false;
            cancelPromptRetryAfterAuth(app);
            if (picker.stage == .root and picker.include_skip) app.auth.skipOnboarding();
            return app.auth.popPickerStage(app.alloc);
        }

        fn cancelPromptRetryAfterAuth(app: *App) void {
            if (comptime @hasDecl(App, "cancelPromptRetryAfterAuth")) {
                app.cancelPromptRetryAfterAuth();
            }
        }

        fn commandSkillsMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            return app.skills.menu.active and !app.skills.menu.origin.isMention();
        }

        fn skillsMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            return app.skills.menuVisible();
        }

        fn modelMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            return app.model_cache.menu.active;
        }

        fn sessionMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            return app.session_persistence.session_picker.active;
        }

        fn helpMenuActive(app: *App) bool {
            return app.input_runtime.help_menu.active;
        }

        fn settingsMenuActive(app: *App) bool {
            return app.input_runtime.settings_menu.active;
        }

        const CompactCommandMenuKind = enum {
            statusline,
            usage,
            workspace,
        };

        fn activeCompactCommandMenu(app: *App) ?CompactCommandMenuKind {
            if (app.input_runtime.statusline_menu.active) return .statusline;
            if (app.input_runtime.usage_menu.active) return .usage;
            if (app.input_runtime.workspace_menu.active) return .workspace;
            return null;
        }

        // A space never extends a mention token, so it ends the mention and
        // inserts through the normal composer path.
        fn dismissMentionSkillsMenuForSpace(app: *App) void {
            if (comptime !@hasField(App, "skills")) return;
            if (!app.skills.menu.active) return;
            if (!app.skills.menu.origin.isMention()) return;
            app.skills.closeMenu();
            app.shell.render_requests.request(.footer);
        }

        fn closeSkillsMenu(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            app.skills.closeMenu();
            return true;
        }

        fn closeHelpMenu(app: *App, clear_query: bool) bool {
            if (!app.input_runtime.help_menu.active) return false;
            app.input_runtime.help_menu.close();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn closeSettingsMenu(app: *App, clear_query: bool) bool {
            if (!app.input_runtime.settings_menu.active) return false;
            app.input_runtime.settings_menu.close();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn closeModelMenu(app: *App, clear_query: bool) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            app.model_cache.closeMenu();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            restoreModelPickerDraft(app);
            return true;
        }

        fn openModelBrowseCatalog(app: *App) !void {
            if (comptime !@hasField(App, "model_cache")) return;
            if (comptime @hasDecl(App, "ensureModelCache")) app.ensureModelCache();
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            try app.model_cache.openMenu();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.shell.render_requests.request(.footer);
        }

        /// Ctrl+P opens the same catalog `/model` opens, but the composer is
        /// only lent to the menu: the draft moves into a stash and comes back
        /// verbatim when the picker closes, whether a model was picked or not.
        fn openModelPickerShortcut(app: *App) !void {
            if (comptime !@hasField(App, "model_cache")) return;
            if (app.input_runtime.model_picker_draft != null) {
                // Unreachable through the keyboard (Ctrl+P backs out of an
                // active flow first); recover a stranded draft rather than
                // overwrite it.
                debug_trace.logf("input", "model picker draft stashed with menu closed; restoring before reopen", .{});
                restoreModelPickerDraft(app);
            }
            app.input_runtime.model_picker_draft = composer_stash.State.capture(
                app.input_runtime.composerStashView(),
            );
            openModelBrowseCatalog(app) catch |err| {
                restoreModelPickerDraft(app);
                return err;
            };
        }

        fn restoreModelPickerDraft(app: *App) void {
            if (app.input_runtime.model_picker_draft) |*draft| {
                // The flow's picker stage and query belong to the borrowed
                // composer, not to the draft coming back.
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                draft.restore(app.alloc, app.input_runtime.composerStashView());
                app.input_runtime.model_picker_draft = null;
                app.shell.render_requests.request(.footer);
            }
        }

        /// Ctrl+P lends the composer to the whole model picker flow: the
        /// catalog, then the inline effort and fast stages. Once neither owns
        /// it (a model was applied, Esc dismissed a stage, or an edit left the
        /// `/model` query), the stashed draft comes back.
        fn settleModelPickerDraft(app: *App) void {
            if (app.input_runtime.model_picker_draft == null) return;
            if (modelMenuActive(app) or completion_rt.hasModelQuery(app)) return;
            const leftover_bytes = app.input_runtime.edit_state.input.items.len;
            if (leftover_bytes > 0) {
                debug_trace.logf(
                    "input",
                    "model picker flow ended; discarding borrowed composer bytes={d} to restore the draft",
                    .{leftover_bytes},
                );
            }
            restoreModelPickerDraft(app);
        }

        /// Surfaces that own the keyboard make Ctrl+P a no-op instead of
        /// borrowing a composer they are already using.
        fn modelPickerShortcutBlocked(app: *App) bool {
            if (settingsMenuActive(app) or helpMenuActive(app) or
                skillsMenuActive(app) or sessionMenuActive(app)) return true;
            if (comptime @hasField(App, "auth")) {
                if (app.auth.pickerView().active) return true;
            }
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.fullTranscriptScreenActive()) return true;
            }
            return false;
        }

        fn toggleSessionPickerScopeIfActive(app: *App) !bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            if (!app.session_persistence.session_picker.active) return false;
            return try app_session_runtime.Runtime(App).toggleSessionPickerScope(app);
        }

        fn dismissActiveMenusForComposerEdit(app: *App) bool {
            return dismissAuthPickerForComposerEdit(app);
        }

        fn dismissActiveMenusThenRedraw(app: *App) void {
            if (dismissActiveMenusForComposerEdit(app)) {
                app.shell.render_requests.request(.footer);
            }
        }

        fn submitSkillsMenuSelection(app: *App, max_input_len: usize) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            // Captured before the sync: a stale $ anchor makes the sync close
            // the menu, and close() resets origin to .command.
            const origin = app.skills.menu.origin;
            syncSkillsMenu(app);
            const skill = app.skills.selectedMenuSkill() orelse {
                if (origin.isMention()) {
                    app.skills.closeMenu();
                    app.shell.render_requests.request(.footer);
                    return false;
                }
                return true;
            };
            const target = if (!origin.isMention())
                skill_runtime.SkillMenuTarget{ .start = 0, .end = app.input_runtime.edit_state.input.items.len }
            else
                app.skills.menu.target orelse skill_runtime.SkillMenuTarget{
                    .start = app.input_runtime.edit_state.cursor,
                    .end = app.input_runtime.edit_state.cursor,
                };
            const raw_len = app.input_runtime.entities.skillTokenInsertedLen(
                app.input_runtime.edit_state.input.items,
                target.end,
                skill.name,
            );
            if (!app.input_runtime.insertionState().canReplaceRange(
                target.start,
                target.end,
                raw_len,
                max_input_len,
            )) {
                app.skills.closeMenu();
                app.shell.render_requests.request(.footer);
                try input_limit_feedback.report(App, app, .composer, raw_len);
                return true;
            }

            try app.input_runtime.skillBindingState().bindSkillToken(
                app.alloc,
                target.start,
                target.end,
                skill.name,
                skill.path,
                skill_runtime.skillDisplaySource(app.skills.items, skill),
            );
            app.skills.closeMenu();
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn changeSettingsMenuSelection(app: *App, delta: i32) !void {
            const menu = &app.input_runtime.settings_menu;
            if (comptime @hasField(App, "model_cache")) {
                if (app.model_cache.menu.active) {
                    if (delta < 0) try applyInlineSettingsModelSelection(app);
                    return;
                }
            }

            const snapshot = app_commands.settingsCatalogSnapshot(app);
            const query = app.input_runtime.edit_state.input.items;
            const item = menu.selectedItem(&snapshot, query) orelse return;
            if (item.id == .model) {
                if (delta > 0 and comptime @hasField(App, "model_cache")) {
                    if (comptime @hasDecl(App, "ensureModelCache")) app.ensureModelCache();
                    try app.model_cache.openMenu();
                    app.shell.render_requests.request(.footer);
                }
                return;
            }

            const change = menu.changeSelectedOption(&snapshot, query, delta) orelse return;
            if (comptime @hasDecl(App, "notificationPreferences")) {
                try app_commands.applySettingsCatalogChange(app, change);
            }
            app.shell.render_requests.request(.footer);
        }

        fn applyInlineSettingsModelSelection(app: *App) !void {
            const selected = (try app.model_cache.menu.selectedModelAlloc(app.alloc)) orelse return;
            defer app.alloc.free(selected);
            try session_commands.Commands(App).selectModelFromPicker(
                app,
                selected,
                app.effort,
                app.fast_mode,
                false,
            );
            app.model_cache.closeMenu();
            app.shell.render_requests.request(.footer);
        }

        fn submitSettingsMenuSelection(app: *App) !bool {
            if (!settingsMenuActive(app)) return false;
            if (comptime @hasField(App, "model_cache")) {
                if (app.model_cache.menu.active) {
                    try applyInlineSettingsModelSelection(app);
                    return true;
                }

                const snapshot = app_commands.settingsCatalogSnapshot(app);
                const selected = app.input_runtime.settings_menu.selectedItem(
                    &snapshot,
                    app.input_runtime.edit_state.input.items,
                ) orelse return true;
                if (selected.id == .model) {
                    if (comptime @hasDecl(App, "ensureModelCache")) app.ensureModelCache();
                    try app.model_cache.openMenu();
                    app.shell.render_requests.request(.footer);
                }
            }
            return true;
        }

        fn submitCompactCommandMenuSelection(
            app: *App,
            menu: CompactCommandMenuKind,
            max_input_len: usize,
        ) !void {
            if (menu == .workspace) {
                try prepareWorkspaceMenuCommand(app, max_input_len);
                return;
            }
            if (menu == .usage) {
                _ = app.input_runtime.usage_menu.toggleExpanded(
                    usageMenuVisibleModelItems(app),
                );
                app.shell.render_requests.request(.footer);
                return;
            }
            const snapshot = app_commands.settingsCatalogSnapshot(app);
            const change = switch (menu) {
                .statusline => app.input_runtime.statusline_menu.selectedChange(snapshot),
                .usage, .workspace => unreachable,
            } orelse return;
            if (comptime @hasDecl(App, "notificationPreferences")) {
                try app_commands.applySettingsCatalogMenuChange(app, change);
            }
            app.shell.render_requests.request(.footer);
        }

        fn prepareWorkspaceMenuCommand(app: *App, max_input_len: usize) !void {
            if (comptime !@hasDecl(App, "workspaceAccess")) return;
            const entries = app.workspaceAccess().entries;
            const action = app.input_runtime.workspace_menu.selectedAction(entries) orelse return;

            var command: std.Io.Writer.Allocating = .init(app.alloc);
            defer command.deinit();
            switch (action) {
                .add => try command.writer.writeAll("/workspace add "),
                .remove => |index| {
                    if (index >= entries.len) return;
                    try command.writer.print("/workspace remove {s}", .{entries[index].path});
                },
                .clear => try command.writer.writeAll("/workspace clear"),
            }
            const text = command.written();
            if (text.len > max_input_len) return;
            var prepared_input = try app.input_runtime.textReplacementState().prepare(
                app.alloc,
                text,
            );
            defer prepared_input.deinit(app.alloc);

            app.input_runtime.workspace_menu.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.input_runtime.textReplacementState().commit(app.alloc, &prepared_input);
            app.input_runtime.picker.dismissInlinePicker(.slash);
            app.shell.render_requests.request(.footer);
        }

        fn moveCompactCommandMenu(app: *App, menu: CompactCommandMenuKind, delta: i32) bool {
            return switch (menu) {
                .statusline => app.input_runtime.statusline_menu.move(delta),
                .usage => app.input_runtime.usage_menu.moveModel(
                    delta,
                    usageMenuVisibleModelItems(app),
                ),
                .workspace => if (comptime @hasDecl(App, "workspaceAccess"))
                    app.input_runtime.workspace_menu.move(
                        delta,
                        app.workspaceAccess().entries,
                    )
                else
                    false,
            };
        }

        fn usageMenuVisibleModelItems(app: *App) u16 {
            const projection = render_input.usageMenuProjection(
                &app.input_runtime.usage_menu,
            );
            const menu: render_input.CompactCommandMenuProjection = .{
                .usage = projection,
            };
            const visible_rows = @min(
                compact_command_menu_presentation.desiredRowCount(
                    menu,
                    app.shell.layout.cols,
                ),
                app.shell.layout.rows -| 3,
            );
            return compact_command_menu_presentation.usageVisibleModelItems(
                projection,
                visible_rows,
                app.shell.layout.cols,
            );
        }

        fn routeCompactCommandMenuEscapeAction(
            app: *App,
            menu: CompactCommandMenuKind,
            resolved: input_action.Action,
        ) !void {
            if (menu == .usage and
                (resolved == .cursor_left or resolved == .cursor_right))
            {
                const current = app.input_runtime.usage_menu.navigationScope();
                const next = if (resolved == .cursor_left)
                    current.previous()
                else
                    current.next();
                if (next != current) {
                    try refreshUsageMenu(app, next);
                }
                return;
            }
            if (menu == .usage and resolved == .toggle_permission_mode) {
                try cycleUsageMenuScope(app, -1);
                return;
            }
            if (menu == .statusline and
                (resolved == .cursor_left or resolved == .cursor_right))
            {
                const snapshot = app_commands.settingsCatalogSnapshot(app);
                const delta: i32 = if (resolved == .cursor_left) -1 else 1;
                const change = switch (menu) {
                    .statusline => app.input_runtime.statusline_menu.changeSelectedOption(&snapshot, delta),
                    .usage, .workspace => unreachable,
                } orelse return;
                if (comptime @hasDecl(App, "notificationPreferences")) {
                    try app_commands.applySettingsCatalogMenuChange(app, change);
                }
                return;
            }
            const delta: i32 = switch (resolved) {
                .cursor_up => -1,
                .cursor_down => 1,
                else => return,
            };
            _ = moveCompactCommandMenu(app, menu, delta);
            app.shell.render_requests.request(.footer);
        }

        fn refreshUsageMenu(app: *App, scope: usage_report.Scope) !void {
            if (comptime @hasDecl(App, "refreshUsageMenu")) {
                try app.refreshUsageMenu(scope);
            } else {
                try app_commands.Handlers(App).refreshUsageMenu(app, scope);
            }
        }

        fn reloadUsageMenu(app: *App, scope: usage_report.Scope) !void {
            if (comptime @hasDecl(App, "reloadUsageMenu")) {
                try app.reloadUsageMenu(scope);
            } else if (comptime @hasDecl(App, "refreshUsageMenu")) {
                try app.refreshUsageMenu(scope);
            } else {
                try app_commands.Handlers(App).reloadUsageMenu(app, scope);
            }
        }

        fn cycleUsageMenuScope(app: *App, delta: i32) !void {
            const current = app.input_runtime.usage_menu.navigationScope();
            const next: usage_report.Scope = if (delta < 0)
                switch (current) {
                    .days_30 => .session,
                    .days_7 => .days_30,
                    .hours_24 => .days_7,
                    .session => .hours_24,
                }
            else switch (current) {
                .days_30 => .days_7,
                .days_7 => .hours_24,
                .hours_24 => .session,
                .session => .days_30,
            };
            try refreshUsageMenu(app, next);
        }

        fn submitHelpMenuSelection(app: *App, max_input_len: usize, max_prompt_history: usize) !bool {
            if (!app.input_runtime.help_menu.active) return false;
            if (app.slashRegistry().matchExact(app.input_runtime.edit_state.input.items) != null) {
                app.input_runtime.help_menu.close();
                return false;
            }
            const selected = app.input_runtime.help_menu.selectedSpec(
                app.slashRegistry(),
                app.input_runtime.edit_state.input.items,
            ) orelse {
                app.shell.render_requests.request(.footer);
                return true;
            };
            const inserted_len = selected.command.len + @intFromBool(selected.has_args);
            if (inserted_len > max_input_len) return true;
            var prepared_input = try app.input_runtime.textReplacementState().prepare(
                app.alloc,
                selected.command,
            );
            defer prepared_input.deinit(app.alloc);

            app.input_runtime.help_menu.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.input_runtime.textReplacementState().commit(app.alloc, &prepared_input);
            if (selected.has_args) {
                try app.input_runtime.insertionState().insertByte(app.alloc, ' ', .clear);
                app.shell.render_requests.request(.footer);
                return true;
            }
            try submit_rt.submit(app, max_prompt_history);
            return true;
        }

        fn submitModelMenuSelection(app: *App) !bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            const selected = (try app.model_cache.menu.selectedModelAlloc(app.alloc)) orelse {
                app.shell.render_requests.request(.footer);
                return true;
            };
            defer app.alloc.free(selected);

            // Ctrl+P and `/model` both continue into the inline effort and
            // fast stages. A Ctrl+P draft stays stashed while those stages
            // borrow the composer; settleModelPickerDraft hands it back once
            // the flow ends, and a failure here hands it back immediately.
            errdefer restoreModelPickerDraft(app);
            app.model_cache.closeMenu();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            try completion_rt.beginExactModelSelection(app, selected);
            return true;
        }

        fn submitAuthPickerSelection(app: *App) !bool {
            if (comptime !@hasField(App, "auth")) return false;
            if (app.stream.active) return false;
            if (!app.auth.pickerView().active) return false;
            const choice = app.auth.takePickerChoice(app.alloc) orelse {
                app.shell.render_requests.request(.footer);
                return true;
            };
            app.applyAuthPickerChoice(choice) catch |err| {
                debug_trace.logf("auth", "picker choice failed choice={s} err={s}", .{ @tagName(choice), @errorName(err) });
                app.auth.closePicker(app.alloc);
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Could not load that credential. The current source is unchanged.",
                }, true);
                app.shell.render_requests.request(.footer);
                return true;
            };
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn submitSlashPickerSelection(app: *App) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (nonSlashPickerOwnsEnter(app)) return false;
            const items = app.input_runtime.edit_state.input.items;
            const prefix = command_specs.slashCompletionPrefix(
                app.slashRegistry(),
                items,
            ) orelse return false;
            if (app.slashRegistry().matchExact(prefix) != null) return false;
            const count = completion_rt.visibleSlashCompletionCount(app);
            if (count == 0) return false;
            const idx = app.input_runtime.picker.slash_completion_index % count;
            if (!picker_presentation.mixedSlashCompletionIsSkill(
                app.slashRegistry(),
                prefix,
                app.skills.items,
                idx,
            )) {
                const selected = picker_presentation.nthMixedSlashCompletionText(
                    app.slashRegistry(),
                    prefix,
                    app.skills.items,
                    idx,
                ) orelse return false;
                const spec = app.slashRegistry().matchExact(selected) orelse return false;
                if (spec.command.kind != .model) return false;
                try openModelBrowseCatalog(app);
                return true;
            }
            return try bindSelectedSlashSkill(app, idx);
        }

        fn nonSlashPickerOwnsEnter(app: *App) bool {
            if (completion_rt.filePickerOwnsSurface(app)) return true;
            // Bare `/model` and `/model …` own Enter over slash/skill bind. Mid-turn
            // commit is gated separately when the model list stays hidden.
            if (app.input_runtime.picker.isModelShapedInput(&app.input_runtime.edit_state)) return true;
            if (comptime @hasField(App, "stream")) {
                if (app.stream.active) return false;
            }
            if (comptime @hasField(App, "session_persistence")) {
                if (app.session_persistence.session_picker.active) return true;
            }
            if (comptime @hasField(App, "auth")) {
                if (app.auth.pickerView().active) return true;
            }
            return false;
        }

        fn resolveExplicitModelSelection(app: *App, input: []const u8) ExplicitModelSelectionParse {
            return switch (parseExplicitModelSelection(input)) {
                .selection => |selection| validateExplicitModelSelection(selection, model_capabilities.resolveForApp(App, app, selection.model)),
                .none => .none,
                .invalid => .invalid,
            };
        }

        fn submitExplicitModelSelection(
            app: *App,
            parsed: ExplicitModelSelectionParse,
        ) !bool {
            switch (parsed) {
                .none => return false,
                .invalid => {
                    try app.writeDomainNotice(.{
                        .topic = "",
                        .tone = .@"error",
                        .body = "usage: /model <id> <effort> [normal|fast|ultrafast]",
                    }, true);
                },
                .selection => |selection| {
                    try session_commands.Commands(App).selectModelFromPicker(
                        app,
                        selection.model,
                        selection.effort,
                        selection.fast_mode,
                        selection.ultrafast_mode,
                    );
                    app.input_runtime.inputResetState().clearCurrent(app.alloc);
                },
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn bindSelectedSlashSkill(app: *App, selected_index: usize) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            const items = app.input_runtime.edit_state.input.items;
            const prefix = command_specs.slashCompletionPrefix(
                app.slashRegistry(),
                items,
            ) orelse return false;
            const skill = picker_presentation.nthMixedSlashCompletionSkill(
                app.slashRegistry(),
                prefix,
                app.skills.items,
                selected_index,
            ) orelse return false;
            const leading_ws = items.len - prefix.len;
            try app.input_runtime.skillBindingState().bindSkillToken(
                app.alloc,
                leading_ws,
                leading_ws + prefix.len,
                skill.name,
                skill.path,
                skill_runtime.skillDisplaySource(app.skills.items, skill),
            );
            app.input_runtime.picker.resetInlinePickerEpisode();
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn syncCatalogMenus(app: *App) void {
            syncSettingsMenu(app);
            syncHelpMenu(app);
            syncSkillsMenu(app);
            syncModelMenu(app);
            syncSessionMenu(app);
        }

        fn syncSettingsMenu(app: *App) void {
            if (!app.input_runtime.settings_menu.active) return;
            app.input_runtime.settings_menu.resetForQuery();
        }

        fn syncHelpMenu(app: *App) void {
            if (!app.input_runtime.help_menu.active) return;
            app.input_runtime.help_menu.resetForQuery();
        }

        fn syncSkillsMenu(app: *App) void {
            if (comptime !@hasField(App, "skills")) return;
            if (!app.skills.menu.active) return;
            if (!app.skills.menu.origin.isMention()) {
                app.skills.setMenuQuery(
                    app.alloc,
                    app.input_runtime.edit_state.input.items,
                );
                return;
            }
            const target = app.skills.menu.target orelse return;
            const items = app.input_runtime.edit_state.input.items;
            if (target.start >= items.len or items[target.start] != '$') {
                app.skills.closeMenu();
                return;
            }
            const end = skillTokenEnd(items, target.start + 1);
            app.skills.menu.target = .{ .start = target.start, .end = end };
            app.skills.setMenuQuery(app.alloc, items[target.start + 1 .. end]);
        }

        fn syncModelMenu(app: *App) void {
            if (comptime !@hasField(App, "model_cache")) return;
            if (!app.model_cache.menu.active) return;
            app.model_cache.setMenuQuery(app.input_runtime.edit_state.input.items);
        }

        fn syncSessionMenu(app: *App) void {
            if (comptime !@hasField(App, "session_persistence")) return;
            const picker = &app.session_persistence.session_picker;
            if (!picker.active) return;
            picker.setQuery(app.input_runtime.edit_state.input.items);
        }

        fn skillTokenEnd(items: []const u8, start: usize) usize {
            var end = start;
            while (end < items.len) : (end += 1) {
                const byte = items[end];
                if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == ':')) break;
            }
            return end;
        }

        fn cycleSkillsMenuSource(app: *App, delta: i32) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menuVisible()) return false;
            return app.skills.moveMenuSourceFilter(delta);
        }

        fn slashMenuVisibleForCue(app: *App) bool {
            if (comptime !@hasDecl(App, "playSlashMenuSound")) return false;
            if (comptime @hasDecl(App, "soundMaxEnabled")) {
                if (!app.soundMaxEnabled()) return false;
            }
            return completion_rt.slashCompletionCount(app) > 0;
        }

        fn announceSlashMenuOpened(app: *App, was_visible: bool) void {
            if (comptime !@hasDecl(App, "playSlashMenuSound")) return;
            if (comptime @hasDecl(App, "soundMaxEnabled")) {
                if (!app.soundMaxEnabled()) return;
            }
            if (was_visible) return;
            if (completion_rt.slashCompletionCount(app) == 0) return;
            app.playSlashMenuSound();
        }

        fn cycleModelMenuProvider(app: *App, delta: i32) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            _ = app.model_cache.menu.moveProvider(delta);
            return true;
        }

        fn cycleSettingsMenuCategory(app: *App, delta: i32) bool {
            if (!app.input_runtime.settings_menu.cycleCategory(delta)) return false;
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            return true;
        }

        fn cycleHelpMenuCategory(app: *App, delta: i32) bool {
            return app.input_runtime.help_menu.cycleCategory(delta);
        }

        fn expireEscClearArm(app: *App, now: i64) void {
            const transition = gesture_state.expireEscapeClear(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                app.shell.render_requests.request(.footer);
            }
        }

        fn expireEscapeInterruptArm(app: *App, now: i64) void {
            // An armed interrupt guards one active operation. When that
            // operation settles on its own, the arm must not carry into
            // whatever work starts next.
            if (app.input_runtime.gestures.escapeInterruptArmed() and
                !interrupt_rt.hasActiveOperation(app))
            {
                _ = disarmEscapeInterrupt(app, "operation_settled");
                return;
            }
            const transition = gesture_state.expireEscapeInterrupt(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                debug_trace.logf(
                    "input",
                    "event=esc_interrupt_disarmed reason=timeout",
                    .{},
                );
                app.shell.render_requests.request(.footer);
            }
        }

        fn expireCtrlCExitArm(app: *App, now: i64) void {
            const transition = gesture_state.expireCtrlCExit(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                debug_trace.logf(
                    "input",
                    "event=ctrl_c_exit_disarmed reason=timeout",
                    .{},
                );
                app.shell.render_requests.request(.footer);
            }
        }

        fn disarmCtrlCExit(app: *App, reason: []const u8) void {
            const transition = gesture_state.disarmCtrlCExit(
                app.input_runtime.gestures,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                debug_trace.logf(
                    "input",
                    "event=ctrl_c_exit_disarmed reason={s}",
                    .{reason},
                );
                app.shell.render_requests.request(.footer);
            }
        }

        fn disarmEscapeClear(app: *App) bool {
            const transition = gesture_state.disarmEscapeClear(
                app.input_runtime.gestures,
            );
            app.input_runtime.gestures = transition.next;
            return transition.cleared;
        }

        fn disarmEscapeInterrupt(app: *App, reason: []const u8) bool {
            const transition = gesture_state.disarmEscapeInterrupt(
                app.input_runtime.gestures,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                debug_trace.logf(
                    "input",
                    "event=esc_interrupt_disarmed reason={s}",
                    .{reason},
                );
                app.shell.render_requests.request(.footer);
            }
            return transition.cleared;
        }

        fn resolveEscape(app: *App, was_cancel_pending: bool, now: i64) !void {
            if (try full_transcript_rt.routeAction(app, .escape)) return;
            if (was_cancel_pending) {
                if (app.question_prompt.isActive()) {
                    // Freeform answers mirror the composer's Esc contract:
                    // Esc on a non-empty draft arms, a second press within
                    // the window clears it, and only an empty field lets
                    // Esc cancel the batch.
                    _ = disarmEscapeInterrupt(app, "question_prompt");
                    if (app.question_prompt.freeformDraftLen() > 0) {
                        const transition = gesture_state.pressEscapeClear(
                            app.input_runtime.gestures,
                            now,
                        );
                        app.input_runtime.gestures = transition.next;
                        if (transition.result == .activated) {
                            app.question_prompt.clearFreeformDraft("escape_clear");
                        }
                        app.shell.render_requests.request(.modal);
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    try question_rt.cancelQuestionPrompt(app);
                    return;
                }
                if (app.approval_prompt.isActive()) {
                    try approval_rt.cancelApprovalOperation(app);
                    _ = disarmEscapeClear(app);
                    _ = disarmEscapeInterrupt(app, "approval_prompt");
                    return;
                }
                if (cancelCompactCommandMenu(app) or cancelSettingsMenu(app) or cancelHelpMenu(app) or cancelModelMenu(app) or cancelSkillsMenu(app) or cancelSessionMenu(app)) {
                    _ = disarmEscapeClear(app);
                    _ = disarmEscapeInterrupt(app, "menu");
                    app.shell.render_requests.request(.footer);
                    return;
                }
                if (completion_rt.dismissVisibleInlinePicker(app)) {
                    _ = disarmEscapeClear(app);
                    _ = disarmEscapeInterrupt(app, "inline_picker");
                    app.shell.render_requests.request(.footer);
                    return;
                }
                if (interrupt_rt.dismissCompactionFeedback(app)) {
                    _ = disarmEscapeClear(app);
                    _ = disarmEscapeInterrupt(app, "compaction_feedback");
                    return;
                }
                if (interrupt_rt.pauseActiveRecovery(app)) {
                    _ = disarmEscapeClear(app);
                    _ = disarmEscapeInterrupt(app, "recovery_pause");
                    return;
                }
                // Interrupting active work requires a confirming second Esc
                // within the gesture window. The first press only arms.
                const transition = gesture_state.pressEscapeInterrupt(
                    app.input_runtime.gestures,
                    now,
                );
                app.input_runtime.gestures = transition.next;
                if (transition.result == .activated) {
                    try interrupt_rt.cancelActiveOperation(app);
                } else {
                    debug_trace.logf(
                        "input",
                        "event=esc_interrupt_armed target=active_operation",
                        .{},
                    );
                }
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }

            if (app.approval_prompt.isActive()) {
                _ = disarmEscapeClear(app);
                return;
            }
            if (cancelCompactCommandMenu(app) or cancelSettingsMenu(app) or cancelHelpMenu(app) or cancelModelMenu(app) or cancelSkillsMenu(app) or cancelSessionMenu(app)) {
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (popOrCloseAuthPicker(app)) {
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (completion_rt.dismissVisibleInlinePicker(app)) {
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (interrupt_rt.dismissCompactionFeedback(app)) {
                _ = disarmEscapeClear(app);
                return;
            }
            if (!draftHasState(app)) {
                _ = disarmEscapeClear(app);
                return;
            }
            const transition = gesture_state.pressEscapeClear(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.result == .activated) {
                clearDraftState(app, "double_escape");
                app.shell.render_requests.request(.footer);
                if (comptime @hasDecl(App, "playInputClearedSound")) app.playInputClearedSound();
            } else {
                app.shell.render_requests.request(.footer);
            }
        }

        fn cancelSkillsMenu(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menuVisible()) return false;
            const mention = app.skills.menu.origin.isMention();
            const clear_query = !mention;
            app.skills.closeMenu();
            if (mention) app.input_runtime.picker.dismissInlinePicker(.skill);
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn cancelCompactCommandMenu(app: *App) bool {
            if (app.input_runtime.statusline_menu.active) {
                app.input_runtime.statusline_menu.close();
                return true;
            }
            if (app.input_runtime.usage_menu.active) {
                app.input_runtime.usage_menu.close(app.alloc);
                return true;
            }
            if (app.input_runtime.workspace_menu.active) {
                app.input_runtime.workspace_menu.close();
                return true;
            }
            return false;
        }

        fn cancelHelpMenu(app: *App) bool {
            return closeHelpMenu(app, true);
        }

        fn cancelSettingsMenu(app: *App) bool {
            return closeSettingsMenu(app, true);
        }

        fn cancelModelMenu(app: *App) bool {
            return closeModelMenu(app, true);
        }

        fn cancelSessionMenu(app: *App) bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            if (!app.session_persistence.session_picker.active) return false;
            app_session_runtime.Runtime(App).cancelSessionPickerToComposer(app);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            return true;
        }
    };
}

const std = @import("std");
const auth_runtime = @import("../../core/auth/auth_runtime.zig");
const credentials = @import("../../core/auth/credentials.zig");
const login_flow = @import("../../core/auth/login_flow.zig");
const picker_state = @import("../../core/input/picker_state.zig");
const command_specs = @import("../../core/slash_commands/command_specs.zig");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const file_index = @import("../../core/workspace/file_index.zig");
const ui_render = @import("../render.zig");
const input_presentation = @import("input_presentation.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
pub const inline_picker_column_gap_width: usize = 4;
pub fn authPickerQueryCursorColumn(_: auth_runtime.PickerView, _: u16) ?u16 {
    return null;
}

pub fn authPickerRowCount(view: auth_runtime.PickerView) u16 {
    if (view.stage == .sign_in) {
        return switch (view.sign_in_source) {
            .chatgpt_subscription => 4,
            .grok_subscription => if (view.sign_in_code_visible) 7 else 5,
            else => 7,
        };
    }
    if (view.stage == .root and view.include_skip) return 18;
    return @intCast(2 + @max(view.choiceCount(), 1));
}

fn setupChoiceLabel(view: auth_runtime.PickerView, choice: auth_runtime.Choice) []const u8 {
    return switch (view.stage) {
        .root => switch (choice) {
            .action => |action| switch (action) {
                .connections => "Connections",
                .switch_provider => "Model provider",
                .chatgpt_login, .grok_login => "",
            },
            .provider => "",
        },
        .connections => switch (choice) {
            .action => |action| switch (action) {
                .chatgpt_login => "Codex subscription",
                .grok_login => "Grok subscription",
                .connections, .switch_provider => "",
            },
            .provider => "",
        },
        .provider => view.choiceLabel(choice),
        .sign_in => "",
    };
}

fn setupChoiceValue(view: auth_runtime.PickerView, choice: auth_runtime.Choice) []const u8 {
    return switch (view.stage) {
        .root => switch (choice) {
            .action => |action| switch (action) {
                .connections => if (view.available_sources.count() > 0) "connected" else "not connected",
                .switch_provider => view.choiceLabel(.{ .provider = view.active_provider }),
                .chatgpt_login, .grok_login => "",
            },
            .provider => "",
        },
        .connections => switch (choice) {
            .action => |action| switch (action) {
                .chatgpt_login => if (view.available_sources.contains(.chatgpt_subscription)) "connected" else "not connected",
                .grok_login => if (view.available_sources.contains(.grok_subscription)) "connected" else "not connected",
                .connections, .switch_provider => "",
            },
            .provider => "",
        },
        .provider => view.choiceDescription(choice),
        .sign_in => "",
    };
}

fn detailValueColumn(width: u16) usize {
    const width_usize: usize = width;
    const minimum = display_width.visibleWidth("  Codex subscription") + 2;
    return @min(width_usize, @max(width_usize * 2 / 3, minimum));
}

fn composeSetupChoiceRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    choice: auth_runtime.Choice,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    const selected = view.choiceIsSelected(choice);
    const style = if (selected) ui_render.selected_completion_style else ui_render.dim_style;
    try row.appendSlice(alloc, style);
    try row.appendSlice(alloc, if (selected) "› " else "  ");

    const value_col = detailValueColumn(width);
    const label_width = value_col -| 2;
    try row_text.appendSingleLineEllipsized(alloc, &row, setupChoiceLabel(view, choice), label_width);
    try row.appendSlice(alloc, ui_render.reset_style);

    if (value_col < width) {
        try row_text.appendSpacesToColumn(alloc, &row, value_col);
        try row.appendSlice(alloc, style);
        try row_text.appendSingleLineEllipsized(alloc, &row, setupChoiceValue(view, choice), @as(usize, width) - value_col);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn composeSetupHeaderRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    const heading = switch (view.stage) {
        .root => "Setup",
        .connections => "Connections",
        .provider => "Model provider",
        .sign_in => unreachable,
    };
    try row_text.appendClipped(alloc, &row, heading, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeSetupEmptyRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, if (view.stage == .provider) "  No providers available" else "", width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeSetupPickerRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    row_index: u16,
    row_count: u16,
    width: u16,
) !std.ArrayList(u8) {
    if (width == 0 or row_index >= row_count) return .empty;
    if (row_count == 1) {
        const selected = view.selected_choice orelse return composeSetupEmptyRow(alloc, view, width);
        return composeSetupChoiceRow(alloc, view, selected, width);
    }
    if (row_index == 0) return composeSetupHeaderRow(alloc, view, width);

    const choice_start: u16 = if (row_count >= 3) 2 else 1;
    if (row_index < choice_start) return .empty;
    if (view.choiceCount() == 0) return composeSetupEmptyRow(alloc, view, width);

    const window = pickerWindow(
        view.choiceCount(),
        view.selectedIndex(),
        row_count - choice_start,
    );
    const choice_index = window.start + row_index - choice_start;
    if (choice_index >= window.end) return .empty;
    const choice = view.choiceAt(choice_index) orelse return .empty;
    return composeSetupChoiceRow(alloc, view, choice, width);
}

pub noinline fn composeAuthPickerRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    row_index: u16,
    row_count: u16,
    width: u16,
) !std.ArrayList(u8) {
    if (view.stage == .sign_in) {
        const source_row_index = signInProjectedRowIndex(
            view.sign_in,
            view.sign_in_source,
            view.sign_in_code_visible,
            row_index,
            row_count,
        );
        return composeSignInPickerRow(
            alloc,
            view.sign_in,
            view.sign_in_source,
            view.sign_in_code_visible,
            view.sign_in_code_mask_count,
            source_row_index,
            width,
        );
    }
    if (view.stage == .root and view.include_skip) {
        return composeOnboardingPickerRow(alloc, view, row_index, row_count, width);
    }
    return composeSetupPickerRow(alloc, view, row_index, row_count, width);
}

fn signInProjectedRowIndex(
    snapshot: login_flow.SignInSnapshot,
    source: credentials.Source,
    manual_code_visible: bool,
    row_index: u16,
    row_count: u16,
) u16 {
    const codex_priority = [_]u16{ 2, 0, 3, 1 };
    if (source == .chatgpt_subscription) {
        return prioritizedRowIndex(4, &codex_priority, row_index, row_count);
    }
    const grok_browser_priority = [_]u16{ 2, 3, 0, 4, 1 };
    if (source == .grok_subscription and !manual_code_visible) {
        return prioritizedRowIndex(5, &grok_browser_priority, row_index, row_count);
    }

    const manual_code_priority = [_]u16{ 5, 4, 2, 0, 6, 3, 1 };
    const device_code_priority = [_]u16{ 2, 3, 6, 0, 5, 1, 4 };
    const priority = if (snapshot.accepts_manual_code)
        &manual_code_priority
    else
        &device_code_priority;
    return prioritizedRowIndex(7, priority, row_index, row_count);
}

fn prioritizedRowIndex(
    source_row_count: u16,
    priority: []const u16,
    row_index: u16,
    row_count: u16,
) u16 {
    if (row_count >= source_row_count) return row_index;
    var projected_index: u16 = 0;
    for (0..source_row_count) |source_row| {
        for (priority[0..@min(row_count, priority.len)]) |included_row| {
            if (source_row != included_row) continue;
            if (projected_index == row_index) return @intCast(source_row);
            projected_index += 1;
            break;
        }
    }
    return source_row_count -| 1;
}

const onboarding_note = "   ⚠︎ Note: fx is experimental and defaults to auto mode.";
const onboarding_note_link = onboarding_note ++ " \x1b]8;id=fx-onboarding;https://fx.sh/docs/stability\x1b\\\x1b[4mLearn more\x1b[24m\x1b]8;;\x1b\\";

fn onboardingProjectedRowIndex(view: auth_runtime.PickerView, row_index: u16, row_count: u16) u16 {
    if (row_count >= 18) return row_index;

    const selected_row: u16 = 8 + @as(u16, @intCast(view.selectedIndex()));
    const priority = [_]u16{ selected_row, 11, 9, 10, 8, 15, 7, 12, 5, 0, 2, 3, 6, 13, 14, 1, 4, 16, 17 };

    var projected_index: u16 = 0;
    for (0..18) |source_row| {
        for (priority[0..@min(row_count, priority.len)]) |included_row| {
            if (source_row != included_row) continue;
            if (projected_index == row_index) return @intCast(source_row);
            projected_index += 1;
            break;
        }
    }
    return 17;
}

fn composeOnboardingPickerRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    row_index: u16,
    row_count: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    const source_row_index = onboardingProjectedRowIndex(view, row_index, row_count);
    const maybe_choice_index: ?usize = switch (source_row_index) {
        8 => 0,
        9 => 1,
        10 => 2,
        11 => 3,
        else => null,
    };
    if (maybe_choice_index) |choice_index| {
        const choice = view.choiceAt(choice_index) orelse return row;
        const selected = view.choiceIsSelected(choice);
        try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
        var label_buf: [96]u8 = undefined;
        const label = std.mem.print(
            &label_buf,
            "{s}{s}",
            .{ if (selected) "   › " else "     ", view.choiceLabel(choice) },
        ) catch view.choiceLabel(choice);
        try row_text.appendClipped(alloc, &row, label, width);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    try row.appendSlice(alloc, ui_render.hint_style);
    const label = switch (source_row_index) {
        0 => "   Welcome to fx",
        1 => "",
        2 => "   fx can access AI models with a subscription or a configured provider.",
        3 => "   Choose a sign-in option below.",
        4 => "",
        5 => "   You can change this anytime with /setup.",
        6 => "",
        7 => "   Get started",
        12 => if (display_width.visibleWidthIgnoringAnsi(onboarding_note_link) <= width) onboarding_note_link else onboarding_note,
        13, 14 => "",
        15 => "   esc to set up later · explore all commands with /help",
        16, 17 => "",
        else => "",
    };
    try row_text.appendClipped(alloc, &row, label, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeSignInPickerRow(
    alloc: Allocator,
    snapshot: login_flow.SignInSnapshot,
    source: credentials.Source,
    manual_code_visible: bool,
    manual_code_mask_count: usize,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;
    const accepts_manual_code = snapshot.accepts_manual_code;

    const subscription_source = source == .chatgpt_subscription or source == .grok_subscription;
    if (subscription_source and row_index == 0) {
        try row.appendSlice(alloc, ui_render.dim_style);
        const value_col = detailValueColumn(width);
        const status = switch (snapshot.state) {
            .idle => "Preparing sign-in…",
            .polling => "Waiting for authorization…",
            .succeeded => "Authorization complete",
            .failed => "Sign-in failed",
            .cancelled => "Sign-in cancelled",
        };
        const status_col = @max(
            value_col,
            @as(usize, width) -| display_width.visibleWidth(status),
        );
        try row_text.appendSingleLineEllipsized(
            alloc,
            &row,
            if (source == .chatgpt_subscription) "Sign in with Codex" else "Sign in with Grok",
            value_col,
        );
        if (status_col < width) {
            try row_text.appendSpacesToColumn(alloc, &row, status_col);
            try row_text.appendSingleLineEllipsized(
                alloc,
                &row,
                status,
                @as(usize, width) - status_col,
            );
        }
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    if (subscription_source and row_index == 2) {
        try row.appendSlice(alloc, ui_render.selected_completion_style);
        const prefix = "  Open   ";
        try row_text.appendClipped(alloc, &row, prefix, width);
        const used: u16 = @intCast(@min(display_width.visibleWidth(prefix), width));
        const remaining = width -| used;
        if (remaining > 0) {
            try row.appendSlice(
                alloc,
                if (source == .chatgpt_subscription)
                    "\x1b]8;id=fx-codex-auth;"
                else
                    "\x1b]8;id=fx-grok-auth;",
            );
            try row.appendSlice(alloc, snapshot.verification_uri);
            try row.appendSlice(alloc, "\x1b\\\x1b[4m");
            try row_text.appendClipped(
                alloc,
                &row,
                if (source == .chatgpt_subscription) "Authorize with Codex" else "Authorize with Grok",
                remaining,
            );
            try row.appendSlice(alloc, "\x1b[24m\x1b]8;;\x1b\\");
        }
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    if (source == .grok_subscription and !manual_code_visible) {
        try row.appendSlice(alloc, ui_render.dim_style);
        if (row_index == 3) {
            try row_text.appendClipped(
                alloc,
                &row,
                "  Browser didn't return? press tab to enter a code",
                width,
            );
        }
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    try row.appendSlice(
        alloc,
        if ((accepts_manual_code and row_index == 5) or
            (!accepts_manual_code and (row_index == 2 or row_index == 3)))
            ui_render.selected_completion_style
        else
            ui_render.dim_style,
    );
    if (source == .grok_subscription and manual_code_visible and row_index == 4) {
        try row_text.appendClipped(alloc, &row, "  Paste the code shown by xAI", width);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    if (source == .grok_subscription and manual_code_visible and row_index == 5) {
        const prefix = "  ┃ ";
        try row_text.appendClipped(alloc, &row, prefix, width);
        const used: u16 = @intCast(@min(display_width.visibleWidth(prefix), width));
        if (manual_code_mask_count == 0) {
            try row.appendSlice(alloc, ui_render.dim_style);
            const placeholder = "Paste or type the code";
            try row_text.appendClipped(alloc, &row, placeholder, width -| used);
        } else {
            const visible_mask_count = @min(manual_code_mask_count, width -| used);
            for (0..visible_mask_count) |_| try row.appendSlice(alloc, "•");
        }
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    if (source == .grok_subscription and manual_code_visible and row_index == 6) {
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    var label_buf: [512]u8 = undefined;
    const label = switch (row_index) {
        0 => if (source == .chatgpt_subscription)
            "   Sign in with Codex"
        else
            "   Sign in with Grok",
        1, 4 => "",
        2 => std.mem.print(
            &label_buf,
            "   Open   {s}",
            .{snapshot.verification_uri},
        ) catch if (source == .chatgpt_subscription)
            "   Open the Codex authorization page"
        else
            "   Open the Grok authorization page",
        3 => if (snapshot.user_code.len == 0)
            ""
        else
            std.mem.print(
                &label_buf,
                "   Code   {s}",
                .{snapshot.user_code},
            ) catch "   Code unavailable",
        5 => switch (snapshot.state) {
            .idle => "   Preparing sign-in…",
            .polling => "   Waiting for authorization…",
            .succeeded => "   Authorization complete",
            .failed => "   Sign-in failed",
            .cancelled => "   Sign-in cancelled",
        },
        6 => if (accepts_manual_code)
            "   enter submits or reopens browser · esc cancels"
        else
            "   enter reopens browser · esc cancels",
        else => "",
    };
    try row_text.appendClipped(alloc, &row, label, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn activeListPickerReservedRows(terminal_rows: u16, input_extra: u16, banner_rows: u16) u16 {
    const fixed_rows: u16 = 5 +| input_extra +| banner_rows;
    const available_rows = terminal_rows -| fixed_rows;
    if (available_rows == 0) return 1;
    return @min(input_presentation.max_model_picker_rows, available_rows);
}

pub fn authPickerReservedRows(view: auth_runtime.PickerView, terminal_rows: u16, input_extra: u16, banner_rows: u16) u16 {
    if (view.stage == .sign_in or (view.stage == .root and view.include_skip)) {
        const available_rows = terminal_rows -| (5 +| input_extra +| banner_rows);
        return @min(authPickerRowCount(view), @max(available_rows, 1));
    }
    return @min(authPickerRowCount(view), activeListPickerReservedRows(terminal_rows, input_extra, banner_rows));
}

pub const PickerWindow = list_window.Window;

pub fn pickerWindow(count: usize, selected: usize, max_rows: u16) PickerWindow {
    return list_window.centered(count, selected, max_rows);
}

pub fn edgeScrollPickerWindowFromStart(count: usize, start: usize, max_rows: u16) PickerWindow {
    return list_window.edgeFromStart(count, start, max_rows);
}

pub fn updateEdgeScrollPickerWindowStart(current_start: usize, count: usize, selected: usize, max_rows: u16) usize {
    return list_window.updateEdgeStart(current_start, count, selected, max_rows);
}

pub const SlashMenuLayout = struct {
    row_count: u16,
    selectable_rows: u16,
    show_header: bool,
    selected: usize,
    command_count: usize,
    result_count: usize,
    window: PickerWindow,
};

pub fn preparedSlashMenuLayout(
    prepared: *const PreparedSlashMenu,
    selection_index: usize,
    current_window_start: usize,
    terminal_rows: u16,
    input_extra: u16,
    banner_rows: u16,
) ?SlashMenuLayout {
    if (command_specs.argCompletionAnchor(prepared.prefix) != 0) return null;
    return slashMenuLayoutForCounts(
        prepared.commandCount(),
        prepared.resultCount(),
        selection_index,
        current_window_start,
        terminal_rows,
        input_extra,
        banner_rows,
    );
}

fn slashMenuLayoutForCounts(
    command_count: usize,
    result_count: usize,
    selection_index: usize,
    current_window_start: usize,
    terminal_rows: u16,
    input_extra: u16,
    banner_rows: u16,
) ?SlashMenuLayout {
    if (result_count == 0) return null;

    const row_budget = inlinePickerRowBudget(terminal_rows, input_extra, banner_rows);
    const show_header = row_budget > 2;
    const header_rows: u16 = if (show_header) 2 else 0;
    const selectable_rows = row_budget - header_rows;
    const selected = selection_index % result_count;
    const window_start = updateEdgeScrollPickerWindowStart(current_window_start, result_count, selected, selectable_rows);
    const window = edgeScrollPickerWindowFromStart(result_count, window_start, selectable_rows);

    return .{
        .row_count = selectable_rows + header_rows,
        .selectable_rows = selectable_rows,
        .show_header = show_header,
        .selected = selected,
        .command_count = command_count,
        .result_count = result_count,
        .window = window,
    };
}

pub fn inlinePickerRowBudget(terminal_rows: u16, input_extra: u16, banner_rows: u16) u16 {
    return inlinePickerRowBudgetCapped(
        terminal_rows,
        input_extra,
        banner_rows,
        input_presentation.max_model_picker_rows + 2,
    );
}

pub fn inlinePickerRowBudgetCapped(
    terminal_rows: u16,
    input_extra: u16,
    banner_rows: u16,
    max_picker_rows: u16,
) u16 {
    const fixed_rows: u16 = 5 +| input_extra +| banner_rows;
    const minimum_transcript_rows: u16 = 5;
    const available_picker_rows = (terminal_rows -| fixed_rows) -| minimum_transcript_rows;
    return @min(max_picker_rows, @max(available_picker_rows, 1));
}

pub noinline fn composePickerOptionRow(
    alloc: Allocator,
    kind: input_presentation.PickerKind,
    start_col: u16,
    item: []const u8,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    return composePickerOptionRowAnnotated(alloc, kind, start_col, item, "", selected, width);
}

const picker_annotation_separator = " · ";

pub noinline fn composePickerOptionRowAnnotated(
    alloc: Allocator,
    kind: input_presentation.PickerKind,
    start_col: u16,
    item: []const u8,
    annotation: []const u8,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0 or start_col == 0 or start_col > width) return row;

    if (start_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, start_col);
    // Model, provider, and model-catalog pickers signal selection by
    // brightness alone, like the question panel; other pickers keep the filled row.
    const selected_style = switch (kind) {
        .model_stage, .provider_stage, .models => ui_render.selected_completion_style,
        .file, .slash, .skills, .help, .settings, .sessions, .auth => ui_render.approval_button_inactive_style,
    };
    const base_style = if (selected) selected_style else ui_render.dim_style;
    const available = width_usize - @as(usize, start_col - 1);
    const annotation_width = if (annotation.len == 0)
        0
    else
        display_width.visibleWidth(picker_annotation_separator) + display_width.visibleWidth(annotation);
    const show_annotation = annotation_width > 0 and
        available >= display_width.visibleWidth(item) + annotation_width;
    const label_width = if (show_annotation) available - annotation_width else available;

    try row.appendSlice(alloc, base_style);
    try row_text.appendClipped(alloc, &row, item, @intCast(label_width));
    if (show_annotation) {
        try row.appendSlice(alloc, ui_render.reset_style);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, picker_annotation_separator);
        try row.appendSlice(alloc, annotation);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composeFilePickerOptionRow(
    alloc: Allocator,
    start_col: u16,
    item: file_index.SearchResult,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0 or start_col == 0 or start_col > width) return row;

    if (start_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, start_col);
    const base_style = if (selected) ui_render.approval_button_inactive_style else ui_render.dim_style;
    try row.appendSlice(alloc, base_style);
    try appendFilePickerLabel(
        alloc,
        &row,
        item,
        @intCast(width_usize - @as(usize, start_col - 1)),
        base_style,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composePickerStatusRowWithProvider(
    alloc: Allocator,
    kind: input_presentation.PickerKind,
    model_stage: picker_state.ModelPickerStage,
    loading: bool,
    failed: bool,
    start_col: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0 or start_col == 0 or start_col > width) return row;

    if (start_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, start_col);
    try row.appendSlice(alloc, ui_render.dim_style);

    const label = switch (kind) {
        .model_stage => switch (model_stage) {
            .model => if (loading)
                "loading models..."
            else if (failed)
                "unable to load models"
            else
                "no matching models",
            .effort => "no matching effort",
            .fast => "no matching mode",
        },
        .provider_stage => "no matching providers",
        .models => "no models available",
        .file => if (loading)
            "indexing files..."
        else if (failed)
            "unable to index files"
        else
            "no matching files",
        .slash => unreachable,
        .skills => "no matching skills",
        .help => "no matching commands",
        .settings => "no matching settings",
        .sessions => "no matching sessions",
        .auth => "authentication actions unavailable",
    };

    try row_text.appendClipped(alloc, &row, label, @intCast(width_usize - @as(usize, start_col - 1)));
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendFilePickerLabel(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    item: file_index.SearchResult,
    width: u16,
    base_style: []const u8,
) !void {
    const path = item.path;
    const width_usize: usize = width;
    const slash_width: usize = @intFromBool(item.kind == .directory);
    if (display_width.visibleWidth(path) + slash_width <= width_usize) {
        try appendStyledPathRange(alloc, row, item, 0, path.len, base_style);
        if (item.kind == .directory) try row.append(alloc, '/');
        return;
    }

    const basename = std.Io.Dir.path.basename(path);
    const basename_start = @intFromPtr(basename.ptr) - @intFromPtr(path.ptr);
    const dirname = std.Io.Dir.path.dirname(path) orelse {
        try appendBasenameProjection(alloc, row, item, basename_start, width_usize, base_style);
        return;
    };
    const separator = "/";
    const separator_width = display_width.visibleWidth(separator);
    const minimum_segmented_width = 8;
    if (width_usize < minimum_segmented_width) {
        try appendBasenameProjection(alloc, row, item, basename_start, width_usize, base_style);
        return;
    }

    const directory_budget = @min(display_width.visibleWidth(dirname), @min(@max(width_usize / 3, 3), 12));
    const basename_budget = width_usize - directory_budget - separator_width - slash_width;

    try appendStyledEllipsizedRange(alloc, row, item, 0, dirname.len, directory_budget, .middle, base_style);
    try appendStyledPathRange(alloc, row, item, dirname.len, basename_start, base_style);
    try appendStyledEllipsizedRange(alloc, row, item, basename_start, path.len, basename_budget, .prefix_biased, base_style);
    if (item.kind == .directory) try row.append(alloc, '/');
}

const FileEllipsisPlacement = enum { middle, prefix_biased };

fn appendBasenameProjection(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    item: file_index.SearchResult,
    basename_start: usize,
    width: usize,
    base_style: []const u8,
) !void {
    if (item.kind == .directory) {
        if (width == 0) return;
        if (width > 1) {
            try appendStyledEllipsizedRange(alloc, row, item, basename_start, item.path.len, width - 1, .prefix_biased, base_style);
        }
        try row.append(alloc, '/');
        return;
    }
    try appendStyledEllipsizedRange(alloc, row, item, basename_start, item.path.len, width, .prefix_biased, base_style);
}

fn appendStyledEllipsizedRange(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    item: file_index.SearchResult,
    source_start: usize,
    source_end: usize,
    width: usize,
    placement: FileEllipsisPlacement,
    base_style: []const u8,
) !void {
    if (width == 0 or source_start >= source_end) return;
    const source = item.path[source_start..source_end];
    if (display_width.visibleWidth(source) <= width) {
        try appendStyledPathRange(alloc, row, item, source_start, source_end, base_style);
        return;
    }
    if (width == 1) {
        try row.appendSlice(alloc, "…");
        return;
    }

    const content_width = width - 1;
    const prefix_width, const suffix_width = switch (placement) {
        .middle => .{ (content_width + 1) / 2, content_width / 2 },
        .prefix_biased => .{ content_width - content_width / 4, content_width / 4 },
    };
    const prefix = display_width.prefixByWidth(source, prefix_width);
    const suffix = displaySafeSuffixByWidth(source, suffix_width);
    try appendStyledPathRange(alloc, row, item, source_start, source_start + prefix.len, base_style);
    try row.appendSlice(alloc, "…");
    try appendStyledPathRange(alloc, row, item, source_end - suffix.len, source_end, base_style);
}

fn displaySafeSuffixByWidth(source: []const u8, width: usize) []const u8 {
    const suffix = display_width.suffixByWidth(source, width);
    if (suffix.len == 0 or suffix.len == source.len) return suffix;

    var start: usize = 0;
    while (start < suffix.len) {
        const unit = display_width.displayUnitAt(suffix, start);
        if (unit.cell_width != 0) break;
        start += unit.byte_len;
    }
    return suffix[start..];
}

fn appendStyledPathRange(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    item: file_index.SearchResult,
    source_start: usize,
    source_end: usize,
    base_style: []const u8,
) !void {
    var cursor = source_start;
    for (item.matched_spans) |span| {
        const match_start: usize = span.byte_start;
        const match_end: usize = span.byte_end;
        if (match_end <= source_start) continue;
        if (match_start >= source_end) break;

        const visible_start = @max(match_start, source_start);
        const visible_end = @min(match_end, source_end);
        if (cursor < visible_start) try row.appendSlice(alloc, item.path[cursor..visible_start]);
        try row.appendSlice(alloc, ui_render.bold_style);
        try row.appendSlice(alloc, item.path[visible_start..visible_end]);
        try row.appendSlice(alloc, ui_render.reset_style);
        try row.appendSlice(alloc, base_style);
        cursor = visible_end;
    }
    if (cursor < source_end) try row.appendSlice(alloc, item.path[cursor..source_end]);
}

const MixedSlashCompletionEntry = union(enum) {
    command: usize,
    skill: skill_runtime.Skill,
};

const PreparedSlashMenuEntry = union(enum) {
    command: usize,
    skill: *const skill_runtime.Skill,
};

pub const PreparedSlashMenu = struct {
    registry: command_specs.SlashRegistry = .{},
    prefix: []const u8 = "",
    command_count: usize = 0,
    skill_matches: std.ArrayList(*const skill_runtime.Skill) = .empty,

    pub fn deinit(self: *PreparedSlashMenu, alloc: Allocator) void {
        self.skill_matches.deinit(alloc);
        self.* = .{};
    }

    pub fn commandCount(self: *const PreparedSlashMenu) usize {
        return self.command_count;
    }

    pub fn resultCount(self: *const PreparedSlashMenu) usize {
        return self.command_count + self.skill_matches.items.len;
    }

    fn entryAt(self: *const PreparedSlashMenu, index: usize) ?PreparedSlashMenuEntry {
        if (index < self.command_count) return .{ .command = index };
        const skill_index = index - self.command_count;
        if (skill_index >= self.skill_matches.items.len) return null;
        return .{ .skill = self.skill_matches.items[skill_index] };
    }
};

pub fn prepareSlashMenu(
    alloc: Allocator,
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
) !PreparedSlashMenu {
    var prepared = PreparedSlashMenu{
        .registry = registry,
        .prefix = prefix,
        .command_count = command_specs.slashCompletionCount(registry, prefix),
    };
    errdefer prepared.deinit(alloc);

    if (command_specs.argCompletionAnchor(prefix) != 0 or
        prefix.len == 0 or prefix[0] != '/' or skills.len == 0)
    {
        return prepared;
    }

    try prepared.skill_matches.resize(alloc, skills.len);
    const written = skill_runtime.fillSkillMenuRangeAtQuery(
        skills,
        .all,
        prefix[1..],
        0,
        prepared.skill_matches.items,
    );
    prepared.skill_matches.shrinkRetainingCapacity(written);
    return prepared;
}

pub fn mixedSlashCompletionCount(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill) usize {
    const command_count = command_specs.slashCompletionCount(registry, prefix);
    if (command_specs.argCompletionAnchor(prefix) != 0) return command_count;
    if (prefix.len == 0 or prefix[0] != '/') return command_count;
    return command_count + skill_runtime.skillMenuFilterQueryCount(skills, .all, prefix[1..]);
}

pub fn mixedSlashCompletionIsSkill(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) bool {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, n) orelse return false) {
        .command => false,
        .skill => true,
    };
}

pub fn nthMixedSlashCompletionSkill(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) ?skill_runtime.Skill {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, n) orelse return null) {
        .command => null,
        .skill => |skill| skill,
    };
}

pub fn nthMixedSlashCompletionText(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) ?[]const u8 {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, n) orelse return null) {
        .command => |match_idx| command_specs.nthSlashCompletion(registry, prefix, match_idx),
        .skill => |skill| skill.name,
    };
}

pub fn mixedSlashCompletionCommandColumnWidth(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    window: PickerWindow,
) usize {
    var width: usize = 0;
    var match_idx = window.start;
    while (match_idx < window.end) : (match_idx += 1) {
        const label = mixedSlashCompletionLabel(registry, prefix, skills, match_idx) orelse continue;
        width = @max(width, display_width.visibleWidth(label));
    }
    return width + 2;
}

fn mixedSlashCompletionEntry(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) ?MixedSlashCompletionEntry {
    const command_count = command_specs.slashCompletionCount(registry, prefix);
    if (n < command_count) return .{ .command = n };
    if (command_specs.argCompletionAnchor(prefix) != 0) return null;
    if (prefix.len == 0 or prefix[0] != '/') return null;
    const skill = skill_runtime.skillMenuSkillAtQuery(skills, .all, prefix[1..], n - command_count) orelse return null;
    return .{ .skill = skill };
}

fn mixedSlashCompletionLabel(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) ?[]const u8 {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, n) orelse return null) {
        .command => |match_idx| command_specs.nthSlashCompletionLabel(registry, prefix, match_idx),
        .skill => |skill| skill.name,
    };
}

pub fn composeSlashMenuHeaderRow(
    alloc: Allocator,
    prefix: []const u8,
    layout: SlashMenuLayout,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    const noun = if (layout.command_count == layout.result_count) "Commands" else "Results";
    var left_buf: [96]u8 = undefined;
    const left = if (std.mem.eql(u8, prefix, "/"))
        std.mem.print(&left_buf, "{s} {d} · type to filter", .{ noun, layout.result_count }) catch noun
    else
        std.mem.print(&left_buf, "{s} {d}", .{ noun, layout.result_count }) catch noun;

    var range_buf: [48]u8 = undefined;
    const range = if (layout.result_count > layout.selectable_rows)
        std.mem.print(&range_buf, "{d}–{d}", .{ layout.window.start + 1, layout.window.end }) catch ""
    else
        "";

    const content_width: usize = @as(usize, width) -| 1;
    const range_width = display_width.visibleWidth(range);
    const left_width = if (range_width > 0 and content_width > range_width + 2)
        content_width - range_width - 2
    else
        content_width;

    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, left, left_width);
    if (range_width > 0 and content_width > range_width + 2) {
        try appendSpacesToVisibleWidth(alloc, &row, content_width - range_width);
        try row.appendSlice(alloc, range);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

const SlashMenuRowContent = struct {
    label: []const u8,
    description: []const u8,
    metadata: []const u8,
};

pub const SlashMenuColumnWidths = struct {
    label: usize,
    metadata: usize,
};

fn slashMenuRowContent(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    match_idx: usize,
    include_metadata: bool,
) ?SlashMenuRowContent {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, match_idx) orelse return null) {
        .command => |command_idx| .{
            .label = command_specs.nthSlashCompletionLabel(registry, prefix, command_idx) orelse return null,
            .description = command_specs.nthSlashCompletionDescription(registry, prefix, command_idx) orelse "",
            .metadata = if (include_metadata)
                if (command_specs.nthSlashCompletionCategory(registry, prefix, command_idx)) |category| category.label() else ""
            else
                "",
        },
        .skill => |skill| .{
            .label = skill.name,
            .description = skill.description,
            .metadata = if (include_metadata) skill_runtime.skillSourceShortLabel(skill.source) else "",
        },
    };
}

fn preparedSlashMenuRowContent(
    prepared: *const PreparedSlashMenu,
    match_idx: usize,
    include_metadata: bool,
) ?SlashMenuRowContent {
    return switch (prepared.entryAt(match_idx) orelse return null) {
        .command => |command_idx| .{
            .label = command_specs.nthSlashCompletionLabel(prepared.registry, prepared.prefix, command_idx) orelse return null,
            .description = command_specs.nthSlashCompletionDescription(prepared.registry, prepared.prefix, command_idx) orelse "",
            .metadata = if (include_metadata)
                if (command_specs.nthSlashCompletionCategory(prepared.registry, prepared.prefix, command_idx)) |category| category.label() else ""
            else
                "",
        },
        .skill => |skill| .{
            .label = skill.name,
            .description = skill.description,
            .metadata = if (include_metadata) skill_runtime.skillSourceShortLabel(skill.source) else "",
        },
    };
}

pub fn mixedSlashMenuColumnWidths(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    window: PickerWindow,
    include_metadata: bool,
) SlashMenuColumnWidths {
    var widths: SlashMenuColumnWidths = .{ .label = 0, .metadata = 0 };
    var match_idx = window.start;
    while (match_idx < window.end) : (match_idx += 1) {
        const content = slashMenuRowContent(registry, prefix, skills, match_idx, include_metadata) orelse continue;
        widths.label = @max(widths.label, display_width.visibleWidth(content.label));
        widths.metadata = @max(widths.metadata, display_width.visibleWidth(content.metadata));
    }
    return widths;
}

pub fn preparedSlashMenuColumnWidths(
    prepared: *const PreparedSlashMenu,
    window: PickerWindow,
    include_metadata: bool,
) SlashMenuColumnWidths {
    var widths: SlashMenuColumnWidths = .{ .label = 0, .metadata = 0 };
    var match_idx = window.start;
    while (match_idx < window.end) : (match_idx += 1) {
        const content = preparedSlashMenuRowContent(prepared, match_idx, include_metadata) orelse continue;
        widths.label = @max(widths.label, display_width.visibleWidth(content.label));
        widths.metadata = @max(widths.metadata, display_width.visibleWidth(content.metadata));
    }
    return widths;
}

pub noinline fn composeSlashMenuOptionRow(
    alloc: Allocator,
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    match_idx: usize,
    selected: bool,
    column_widths: SlashMenuColumnWidths,
    width: u16,
    include_metadata: bool,
) !std.ArrayList(u8) {
    const content = slashMenuRowContent(registry, prefix, skills, match_idx, include_metadata) orelse return .empty;
    return composeSlashMenuRow(alloc, content, selected, column_widths, width);
}

pub noinline fn composePreparedSlashMenuOptionRow(
    alloc: Allocator,
    prepared: *const PreparedSlashMenu,
    match_idx: usize,
    selected: bool,
    column_widths: SlashMenuColumnWidths,
    width: u16,
    include_metadata: bool,
) !std.ArrayList(u8) {
    const content = preparedSlashMenuRowContent(prepared, match_idx, include_metadata) orelse return .empty;
    return composeSlashMenuRow(alloc, content, selected, column_widths, width);
}

fn composeSlashMenuRow(
    alloc: Allocator,
    content: SlashMenuRowContent,
    selected: bool,
    column_widths: SlashMenuColumnWidths,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    // Selection is signaled by brightness alone (like the model picker); no
    // caret marker. The two-column indent stays fixed so rows stay aligned.
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row.appendSlice(alloc, "  ");

    const content_width: usize = @as(usize, width) -| 1;
    const marker_width: usize = 2;
    if (content_width <= marker_width) {
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    try row_text.appendSingleLineEllipsized(alloc, &row, content.label, content_width - marker_width);

    const label_width = display_width.visibleWidth(content.label);
    const column_gap: usize = 3;
    const description_start = @min(content_width, marker_width + @max(column_widths.label, label_width) + column_gap);
    try appendSpacesToVisibleWidth(alloc, &row, description_start);

    const metadata_width = display_width.visibleWidth(content.metadata);
    const min_description_width: usize = 24;
    const metadata_start = content_width -| column_widths.metadata;
    const metadata_fits = metadata_width > 0 and column_widths.metadata > 0 and column_widths.metadata <= content_width;
    const show_metadata = if (content.description.len > 0)
        metadata_fits and metadata_start >= description_start + min_description_width + column_gap
    else
        metadata_fits and metadata_start >= description_start + column_gap;
    const description_width = if (show_metadata)
        metadata_start - description_start - column_gap
    else
        content_width - description_start;

    if (content.description.len > 0 and description_width > 0) {
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendSingleLineEllipsized(alloc, &row, content.description, description_width);
    }
    if (show_metadata) {
        try appendSpacesToVisibleWidth(alloc, &row, metadata_start);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, content.metadata);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendSpacesToVisibleWidth(alloc: Allocator, row: *std.ArrayList(u8), target_width: usize) !void {
    var visible = display_width.visibleWidthIgnoringAnsi(row.items);
    while (visible < target_width) : (visible += 1) try row.append(alloc, ' ');
}

pub fn composeSlashCompletionOptionRow(
    alloc: Allocator,
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    match_idx: usize,
    selected: bool,
    start_col: u16,
    command_width: usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0) return row;

    const label = command_specs.nthSlashCompletionLabel(registry, prefix, match_idx) orelse return row;
    const description = command_specs.nthSlashCompletionDescription(registry, prefix, match_idx) orelse "";
    const label_col: u16 = if (start_col > 1) start_col else 3;
    if (label_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, label_col);

    const before_label_width: usize = label_col - 1;
    if (before_label_width >= width_usize) return row;
    const remaining: u16 = @intCast(width_usize - before_label_width);

    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, label, remaining);
    try row.appendSlice(alloc, ui_render.reset_style);

    var visible = display_width.visibleWidth(label);
    while (visible < command_width and before_label_width + visible < width_usize) : (visible += 1) {
        try row.append(alloc, ' ');
    }

    if (description.len > 0 and before_label_width + visible < width_usize) {
        try row.appendSlice(alloc, ui_render.dim_style);
        const desc_remaining: u16 = @intCast(width_usize - before_label_width - visible);
        try row_text.appendClipped(alloc, &row, description, desc_remaining);
        try row.appendSlice(alloc, ui_render.reset_style);
    }

    return row;
}

pub fn composeMixedSlashCompletionOptionRow(
    alloc: Allocator,
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    match_idx: usize,
    selected: bool,
    start_col: u16,
    command_width: usize,
    width: u16,
) !std.ArrayList(u8) {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, match_idx) orelse return .empty) {
        .command => |command_idx| composeSlashCompletionOptionRow(alloc, registry, prefix, command_idx, selected, start_col, command_width, width),
        .skill => |skill| composeSkillCompletionOptionRow(alloc, skill, selected, start_col, command_width, width),
    };
}

fn composeSkillCompletionOptionRow(
    alloc: Allocator,
    skill: skill_runtime.Skill,
    selected: bool,
    start_col: u16,
    command_width: usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0) return row;

    const label_col: u16 = if (start_col > 1) start_col else 3;
    if (label_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, label_col);

    const before_label_width: usize = label_col - 1;
    if (before_label_width >= width_usize) return row;
    const remaining: u16 = @intCast(width_usize - before_label_width);

    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, skill.name, remaining);
    try row.appendSlice(alloc, ui_render.reset_style);

    var visible = display_width.visibleWidth(skill.name);
    while (visible < command_width and before_label_width + visible < width_usize) : (visible += 1) {
        try row.append(alloc, ' ');
    }

    const source = skill_runtime.skillSourceShortLabel(skill.source);
    if (before_label_width + visible < width_usize) {
        try row.appendSlice(alloc, ui_render.dim_style);
        const desc_remaining: u16 = @intCast(width_usize - before_label_width - visible);
        try row_text.appendClipped(alloc, &row, source, desc_remaining);
        try row.appendSlice(alloc, ui_render.reset_style);
    }

    return row;
}

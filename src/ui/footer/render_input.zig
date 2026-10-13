const std = @import("std");
const question_prompt = @import("../../core/agent/question_prompt.zig");
const approval_prompt = @import("../../core/permissions/approval_prompt.zig");
const auth_runtime = @import("../../core/auth/auth_runtime.zig");
const activity_status = @import("../../core/output/activity_status.zig");
const model_cache_runtime = @import("../../core/app/model_cache_runtime.zig");
const picker_state = @import("../../core/input/picker_state.zig");
const session_catalog = @import("../../core/session/session_catalog.zig");
const session_store = @import("../../core/session/session_store.zig");
const usage_report = @import("../../core/session/usage_report.zig");
const command_specs = @import("../../core/slash_commands/command_specs.zig");
const settings_catalog = @import("../../core/config/settings_catalog.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const display_width = @import("../../core/shared/display_width.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const types = @import("../../core/shared/types.zig");
const workspace_access = @import("../../core/workspace/workspace_access.zig");
const file_index = @import("../../core/workspace/file_index.zig");
const workspace_menu = @import("../../core/workspace/workspace_menu.zig");
const activity_runtime = @import("../../core/output/activity_runtime.zig");
const transcript_presentation = @import("../../core/output/transcript_presentation.zig");
const usage_menu = @import("../../core/session/usage_menu.zig");
const core_input_runtime = @import("../../core/input/runtime.zig");
const ui_render = @import("../render.zig");
const render_engine = @import("../render_engine.zig");
const render_request = @import("../render_request.zig");
const transcript_runtime = @import("../transcript/runtime.zig");

const StreamState = types.StreamState;
const ActivityProjection = activity_runtime.ActivityProjection;
const InputRuntime = core_input_runtime.Runtime;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;

pub const SkillsMenuProjection = struct {
    active: bool = false,
    items: []const skill_runtime.Skill = &.{},
    actual_indices: []const u32 = &.{},
    index_ready: bool = false,
    source_filter: skill_runtime.SkillMenuSourceFilter = .all,
    selected_index: usize = 0,
    window_start: usize = 0,
    query: []const u8 = "",

    pub fn itemCount(self: SkillsMenuProjection) usize {
        if (self.index_ready) return self.actual_indices.len;
        return skill_runtime.skillMenuFilterQueryCount(
            self.items,
            self.source_filter,
            self.query,
        );
    }

    pub fn itemAt(
        self: SkillsMenuProjection,
        display_index: usize,
    ) ?*const skill_runtime.Skill {
        if (!self.index_ready) {
            const actual_index = skill_runtime.skillMenuActualIndexAtQuery(
                self.items,
                self.source_filter,
                self.query,
                display_index,
            ) orelse return null;
            return &self.items[actual_index];
        }
        if (display_index >= self.actual_indices.len) return null;
        const actual_index: usize = self.actual_indices[display_index];
        if (actual_index >= self.items.len) return null;
        return &self.items[actual_index];
    }
};

pub const ModelMenuProjection = struct {
    active: bool = false,
    load_state: model_cache_runtime.ModelMenuLoadState = .loading,
    catalog_state: model_cache_runtime.ModelMenuCatalogState = .{},
    items: []const model_cache_runtime.ModelMenuItem = &.{},
    provider_index: usize = 0,
    selected_index: usize = 0,
    window_start: usize = 0,
    query: []const u8 = "",

    pub fn providerFilter(self: ModelMenuProjection) model_cache_runtime.ModelProviderFilter {
        return @fromBackingInt(@intCast(@min(self.provider_index, model_cache_runtime.model_provider_filter_count - 1)));
    }

    pub fn filteredItemCount(self: ModelMenuProjection) usize {
        return model_cache_runtime.modelMenuFilteredItemCount(self.items, self.providerFilter(), self.query);
    }

    pub fn itemAt(self: ModelMenuProjection, display_index: usize) ?*const model_cache_runtime.ModelMenuItem {
        return model_cache_runtime.modelMenuItemAt(self.items, self.providerFilter(), self.query, display_index);
    }
};

pub const SessionMenuProjection = struct {
    active: bool = false,
    load_state: session_catalog.LoadState = .loading,
    summaries: []const session_store.SessionSummary = &.{},
    has_more: bool = false,
    loading_more: bool = false,
    scope: session_catalog.Scope = .current_workspace,
    selected_index: usize = 0,
    window_start: usize = 0,
    query: []const u8 = "",
    now_ms: i64 = 0,
    selection_failure: ?session_catalog.ResumeFailure = null,

    pub fn filteredItemCount(self: SessionMenuProjection) usize {
        return session_catalog.filteredCount(self.summaries, self.query);
    }

    pub fn navigationItemCount(self: SessionMenuProjection) usize {
        return self.filteredItemCount() + @intFromBool(self.has_more);
    }

    pub fn isLoadMoreIndex(self: SessionMenuProjection, display_index: usize) bool {
        return self.has_more and display_index == self.filteredItemCount();
    }

    pub fn itemAt(self: SessionMenuProjection, display_index: usize) ?*const session_store.SessionSummary {
        return session_catalog.summaryAt(self.summaries, self.query, display_index);
    }
};

pub const HelpMenuProjection = struct {
    active: bool = false,
    category: ?command_specs.SlashPresentationCategory = null,
    registry: command_specs.SlashRegistry = .{},
    selected_index: usize = 0,
    window_start: usize = 0,
    query: []const u8 = "",

    pub fn filteredItemCount(self: HelpMenuProjection) usize {
        return command_specs.helpCatalogCountForCategory(self.registry, self.category, self.query);
    }

    pub fn itemAt(self: HelpMenuProjection, display_index: usize) ?*const command_specs.SlashSpec {
        return command_specs.helpCatalogSpecAtForCategory(self.registry, self.category, self.query, display_index);
    }
};

pub const SettingsMenuProjection = struct {
    active: bool = false,
    category: settings_catalog.Category = .all,
    selected_index: usize = 0,
    window_start: usize = 0,
    snapshot: settings_catalog.Snapshot = .{},
    query: []const u8 = "",
    models: ModelMenuProjection = .{},

    pub fn filteredItemCount(self: SettingsMenuProjection) usize {
        return settings_catalog.filteredCount(self.snapshot, self.category, self.query);
    }

    pub fn itemAt(self: SettingsMenuProjection, display_index: usize) ?settings_catalog.Item {
        return settings_catalog.itemAt(self.snapshot, self.category, self.query, display_index);
    }
};

pub const StatuslineMenuProjection = struct {
    active: bool = false,
    selected_index: usize = 0,
    snapshot: settings_catalog.Snapshot = .{},
};

pub fn statuslineMenuProjection(
    menu: *const settings_catalog.StatuslineMenu,
    snapshot: settings_catalog.Snapshot,
) StatuslineMenuProjection {
    return .{
        .active = menu.active,
        .selected_index = menu.selected_index,
        .snapshot = snapshot,
    };
}

pub const UsageMenuProjection = struct {
    active: bool = false,
    scope: usage_report.Scope = .days_30,
    selected_model: usize = 0,
    expanded_model: ?usize = null,
    model_window_start: usize = 0,
    snapshot: ?*const usage_report.Snapshot = null,
    refresh_error: ?[]const u8 = null,
};

pub fn usageMenuProjection(
    menu: *const usage_menu.State,
) UsageMenuProjection {
    return .{
        .active = menu.active,
        .scope = menu.scope(),
        .selected_model = menu.selected_model,
        .expanded_model = menu.expanded_model,
        .model_window_start = menu.model_window_start,
        .snapshot = if (menu.snapshot) |*snapshot| snapshot else null,
        .refresh_error = menu.refresh_error,
    };
}

pub const WorkspaceMenuProjection = struct {
    active: bool = false,
    selected_row: usize = 0,
    primary_directory: []const u8 = "",
    saved_suppressed: bool = false,
    entries: []const workspace_access.Entry = &.{},
};

pub fn workspaceMenuProjection(
    menu: *const workspace_menu.State,
    primary_directory: []const u8,
    access: *const workspace_access.WorkspaceAccess,
) WorkspaceMenuProjection {
    return .{
        .active = menu.active,
        .selected_row = menu.selectedRow(access.entries) orelse 0,
        .primary_directory = primary_directory,
        .saved_suppressed = access.saved_suppressed,
        .entries = access.entries,
    };
}

pub const CompactCommandMenuProjection = union(enum) {
    statusline: StatuslineMenuProjection,
    usage: UsageMenuProjection,
    workspace: WorkspaceMenuProjection,
};

pub fn settingsMenuProjection(
    menu: *const settings_catalog.Menu,
    snapshot: settings_catalog.Snapshot,
    query: []const u8,
) SettingsMenuProjection {
    return .{
        .active = menu.active,
        .category = menu.category,
        .selected_index = menu.selected_index,
        .window_start = menu.window_start,
        .snapshot = snapshot,
        .query = query,
    };
}

pub fn helpMenuProjection(
    menu: *const command_specs.HelpMenu,
    registry: command_specs.SlashRegistry,
    query: []const u8,
) HelpMenuProjection {
    return .{
        .active = menu.active,
        .category = menu.category,
        .registry = registry,
        .selected_index = menu.selected_index,
        .window_start = menu.window_start,
        .query = query,
    };
}

pub fn skillsMenuProjection(skills: *const skill_runtime.Runtime) SkillsMenuProjection {
    return .{
        .active = skills.menuVisible(),
        .items = skills.items,
        .actual_indices = skills.menu_index.actual_indices.items,
        .index_ready = skills.menu_index_ready,
        .source_filter = skills.menu.source_filter,
        .selected_index = skills.menu.selected_index,
        .window_start = skills.menu.window_start,
        .query = skills.menu.query(),
    };
}

pub fn modelMenuProjection(cache: *const model_cache_runtime.Runtime) ModelMenuProjection {
    return .{
        .active = cache.menu.active,
        .load_state = cache.menu.load_state,
        .catalog_state = cache.menu.catalog_state,
        .items = cache.menu.items.items,
        .provider_index = cache.menu.provider_index,
        .selected_index = cache.menu.selected_index,
        .window_start = cache.menu.window_start,
        .query = cache.menu.query(),
    };
}

const max_static_status_activity_rows: u16 = 3;

pub const RenderContext = struct {
    slash_registry: command_specs.SlashRegistry = .{},
    stream: StreamState,
    compaction: @import("../../core/output/compaction_activity.zig").Snapshot = .{},
    pending_prompt_activity: bool = false,
    completed_assistant_presentation_tail: bool = false,
    // Pacer emitting visible text, including the post-finish tail drain.
    writing_response: bool = false,
    has_api_key: bool,
    model: []const u8,
    pending_images: []const types.ImageAttachment = &.{},
    composer_visible: bool = true,
    permission_mode: types.PermissionMode = .ask,
    steering_messages: []const []const u8 = &.{},
    steering_waits_for_boundary: bool = false,
    fast_indicator_active: bool = false,
    effort: types.ReasoningEffort = .auto,
    model_supports_effort: bool = false,
    ctrl_c_pending: bool = false,
    shimmer_pos: i16 = -render_request.animation_padding,
    now_ms: i64 = 0,
    model_query_active: bool = false,
    model_picker_stage: picker_state.ModelPickerStage = .model,
    model_completions_loading: bool = false,
    model_completions_failed: bool = false,
    model_completions: []const []const u8 = &.{},
    model_completion_index: usize = 0,
    model_completion_window_start: usize = 0,
    model_completion_anchor: usize = 0,
    provider_query_active: bool = false,
    provider_picker_completions: []const []const u8 = &.{},
    /// Parallel to `provider_picker_completions`; an empty entry renders no annotation.
    provider_picker_annotations: []const []const u8 = &.{},
    provider_picker_completion_index: usize = 0,
    provider_picker_completion_window_start: usize = 0,
    provider_picker_completion_anchor: usize = 0,
    file_query_active: bool = false,
    file_completions: []const file_index.SearchResult = &.{},
    file_completion_index: usize = 0,
    file_completion_has_selection: bool = true,
    file_completion_status: ?[]const u8 = null,
    file_completion_window_start: usize = 0,
    file_completion_anchor: usize = 0,
    file_completions_loading: bool = false,
    file_completions_failed: bool = false,
    inline_completion_suffix: []const u8 = "",
    auth_picker: auth_runtime.PickerView = .{
        .active = false,
        .available_sources = .empty,
        .selected_choice = null,
        .active_source = null,
        .include_skip = false,
    },
    skills_menu: SkillsMenuProjection = .{},
    help_menu: HelpMenuProjection = .{},
    settings_menu: SettingsMenuProjection = .{},
    model_menu: ModelMenuProjection = .{},
    session_menu: SessionMenuProjection = .{},
    statusline_menu: StatuslineMenuProjection = .{},
    usage_menu: UsageMenuProjection = .{},
    workspace_menu: WorkspaceMenuProjection = .{},
    upgrade_status: []const u8 = "",
    danger_status: []const u8 = "",
    danger_status_compact: []const u8 = "",
    esc_clear_armed: bool = false,
    esc_interrupt_armed: bool = false,
    question: ?question_prompt.Projection = null,
    statusline: ui_render.StatuslineItems = .{},
    activity: ActivityProjection = .none,
    transcript_depth: transcript_presentation.Depth = .inline_mode,
    input: *const InputRuntime,
};

pub fn activeCompactCommandMenu(ctx: RenderContext) ?CompactCommandMenuProjection {
    if (ctx.statusline_menu.active) return .{ .statusline = ctx.statusline_menu };
    if (ctx.usage_menu.active) return .{ .usage = ctx.usage_menu };
    if (ctx.workspace_menu.active) return .{ .workspace = ctx.workspace_menu };
    return null;
}

pub const steering_composer_gap_rows: u16 = 1;
pub const max_steering_message_rows: u16 = 2;

const SteeringMessageLayout = struct {
    rows: [max_steering_message_rows][]const u8 = @splat(""),
    row_count: u16 = 0,
    content_width: u16,
    truncated: bool = false,
};

fn steering_unit_width(raw: []const u8) usize {
    var width: usize = 0;
    var safe_start: usize = 0;
    var index: usize = 0;
    while (index < raw.len) {
        const rune = display_width.decodeNextRune(raw, index);
        const end = index + rune.len;
        if (!text_utils.isTerminalSafe(raw[index..end])) {
            width += display_width.visibleWidth(raw[safe_start..index]);
            width += text_utils.terminalSafeVisibleWidth(raw[index..end]);
            safe_start = end;
        }
        index = end;
    }
    return width + display_width.visibleWidth(raw[safe_start..]);
}

/// Borrows at most two visible row slices; measurement and painting share this layout.
pub fn steering_message_layout(
    message: []const u8,
    width: u16,
    waits_for_boundary: bool,
    row_limit: u16,
) SteeringMessageLayout {
    var layout: SteeringMessageLayout = .{
        .content_width = if (waits_for_boundary) width -| 2 else width,
    };
    const limit = @min(row_limit, max_steering_message_rows);
    var offset: usize = 0;
    while (layout.row_count < limit) {
        const start = offset;
        var cells: usize = 0;
        var ellipsis_end = start;
        var last_space: ?usize = null;
        while (offset < message.len and message[offset] != '\n' and message[offset] != '\r') {
            const unit = display_width.displayUnitAt(message, offset);
            const raw = message[offset .. offset + unit.byte_len];
            const unit_width = if (message[offset] == '\t')
                1
            else if (text_utils.isTerminalSafe(raw))
                unit.cell_width
            else
                steering_unit_width(raw);
            if (unit_width > layout.content_width - cells) break;
            if (message[offset] == ' ' or message[offset] == '\t') last_space = offset;
            cells += unit_width;
            offset += unit.byte_len;
            if (cells < layout.content_width) ellipsis_end = offset;
        }
        var end = offset;
        const soft_separator = offset < message.len and (message[offset] == ' ' or message[offset] == '\t');
        if (soft_separator) {
            while (offset < message.len and (message[offset] == ' ' or message[offset] == '\t')) offset += 1;
        }
        const hard_break = offset < message.len and (message[offset] == '\n' or message[offset] == '\r');
        if (hard_break) {
            const cr = message[offset] == '\r';
            offset += 1;
            if (cr and offset < message.len and message[offset] == '\n') offset += 1;
        } else if (!soft_separator and offset < message.len) {
            if (last_space) |space| {
                if (space > start) {
                    end = space;
                    offset = space + 1;
                }
            }
        }
        layout.rows[layout.row_count] = message[start..end];
        layout.row_count += 1;
        if (offset == message.len) break;
        if (layout.row_count == limit or (!hard_break and end == start)) {
            layout.rows[layout.row_count - 1] = message[start..@min(end, ellipsis_end)];
            layout.truncated = true;
            break;
        }
    }
    return layout;
}

pub fn steeringBannerRowsForMessages(
    messages: []const []const u8,
    waits_for_boundary: bool,
    width: u16,
) u16 {
    if (messages.len == 0 or !waits_for_boundary) return 0;
    var rows: u16 = 0;
    for (messages) |message| {
        rows +|= steering_message_layout(message, width, waits_for_boundary, max_steering_message_rows).row_count;
    }
    return rows +| steering_composer_gap_rows;
}

pub fn steeringBannerRows(ctx: RenderContext, width: u16) u16 {
    return steeringBannerRowsForMessages(
        ctx.steering_messages,
        ctx.steering_waits_for_boundary,
        width,
    );
}

pub fn transientActivityGapRows(shell: *const TranscriptRuntime, tool_before_activity: bool) u16 {
    if (tool_before_activity) return 0;
    return shell.transientAssistantGapRows();
}

pub fn activityProjectionRows(projection: ActivityProjection, cols: u16) u16 {
    return switch (projection) {
        .turn_thinking => |thinking| if (thinking.tone == .thinking)
            1
        else
            wrappedStatusRowCount(thinking.label, cols, max_static_status_activity_rows),
        .none, .tool_slot => 1,
    };
}

pub fn frameOwnedActivityProjection(
    buf: []u8,
    shell: *TranscriptRuntime,
    ctx: RenderContext,
    approval: ?approval_prompt.Projection,
) ActivityProjection {
    if (approval != null or ctx.question != null) return .none;
    const compaction = activity_status.compactionProjection(buf, ctx.compaction, ctx.stream, ctx.now_ms);
    if (compaction == .none and !ctx.stream.active and ctx.pending_prompt_activity) {
        return .{ .turn_thinking = .{ .label = "• Thinking" } };
    }
    switch (ctx.activity) {
        .tool_slot => {},
        .turn_thinking => |thinking| {
            if (thinking.tone != .thinking) return ctx.activity;
        },
        .none => {},
    }
    if (compaction != .none) return compaction;
    return turnActivityProjection(buf, shell, ctx);
}

pub fn frameActivityBlink(ctx: RenderContext) ?bool {
    if (ctx.compaction.operation) |op| {
        if (op.active() and op.visible(ctx.now_ms)) {
            return activity_status.activityBlinkVisible(activity_status.compactionClock(ctx.stream, op), ctx.now_ms);
        }
    }
    return activity_status.activityBlinkVisible(ctx.stream, ctx.now_ms);
}

fn turnActivityProjection(
    buf: []u8,
    shell: *TranscriptRuntime,
    ctx: RenderContext,
) ActivityProjection {
    _ = shell;
    if (!ctx.stream.active) {
        if (!ctx.writing_response and !ctx.completed_assistant_presentation_tail) return .none;
        return .{ .turn_thinking = .{
            .label = activity_status.buildCompletedTurnLabel(buf, ctx.stream),
            .tone = .neutral,
        } };
    }

    var visible_stream = ctx.stream;
    visible_stream.last_activity_kind = null;
    if (activity_status.buildTurnLabel(buf, visible_stream, ctx.now_ms)) |label| {
        return .{ .turn_thinking = .{ .label = label } };
    }
    return .{ .turn_thinking = .{
        .label = "• Thinking",
    } };
}

fn toolSlotLabelWithTokens(buf: []u8, label: []const u8, stream: StreamState) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    out.writeAll(label) catch return label;
    activity_status.appendTurnTokenSuffix(&out, stream) catch return out.buffered();
    return out.buffered();
}

fn appendConnectedToolLabel(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    label: []const u8,
    cols: u16,
) !void {
    var marker_start: usize = 0;
    while (marker_start < label.len and label[marker_start] == 0x1b) {
        const ansi_end = display_width.ansiSequenceEnd(label, marker_start);
        if (ansi_end <= marker_start) break;
        marker_start = ansi_end;
    }
    const marker = display_width.decodeNextRune(label, marker_start);
    if (marker.len == 0) return;
    const marker_end = @min(marker_start + marker.len, label.len);
    const marker_bytes = label[marker_start..marker_end];
    const line_end = std.mem.findScalar(u8, label[marker_end..], '\n') orelse label[marker_end..].len;

    // The live label arrives with the formatter's bold styling; the connected
    // row belongs to the dimmed group block, so restyle it plain gray.
    var connected: std.ArrayList(u8) = .empty;
    defer connected.deinit(alloc);
    try connected.appendSlice(alloc, ui_render.statusline_style);
    if (std.mem.eql(u8, marker_bytes, "●") or std.mem.eql(u8, marker_bytes, "■")) {
        try connected.appendSlice(alloc, "└");
        try appendWithoutAnsi(alloc, &connected, label[marker_end .. marker_end + line_end]);
    } else {
        try appendWithoutAnsi(alloc, &connected, label[0 .. marker_end + line_end]);
    }

    const clipped = try render_engine.transcript_blocks.formatCompactCommandStatus(
        alloc,
        connected.items,
        cols,
    );
    defer alloc.free(clipped);
    try out.appendSlice(alloc, clipped);
    try out.appendSlice(alloc, ui_render.reset_style);
}

fn appendWithoutAnsi(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
) !void {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            const ansi_end = display_width.ansiSequenceEnd(text, index);
            if (ansi_end > index) {
                index = ansi_end;
                continue;
            }
        }
        try out.append(alloc, text[index]);
        index += 1;
    }
}

pub fn activityProjectionLabel(projection: ActivityProjection) ?[]const u8 {
    return switch (projection) {
        .none => null,
        .turn_thinking => |thinking| thinking.label,
        .tool_slot => |slot| slot.thinking_label orelse slot.fallback_label,
    };
}

fn wrappedStatusRowCount(label: []const u8, cols: u16, max_rows: u16) u16 {
    if (max_rows <= 1 or cols == 0) return 1;
    if (display_width.visibleWidthIgnoringAnsi(label) <= cols) return 1;

    const safe_cols = @max(@as(usize, cols), 1);
    const prefix_end = display_width.statusPrefixEnd(label);
    const prefix_width = display_width.visibleWidthIgnoringAnsi(label[0..prefix_end]);
    var remaining = label[prefix_end..];
    var row_count: u16 = 0;
    var first = true;
    while (remaining.len > 0 and row_count < max_rows) {
        const indent_width = if (first) prefix_width else @max(prefix_width, 1);
        const available = if (safe_cols > indent_width) safe_cols - indent_width else 1;
        var chunk = display_width.wrapCutIgnoringAnsi(remaining, available);
        if (chunk.len == 0) {
            const unit = display_width.displayUnitAt(remaining, 0);
            chunk = remaining[0..unit.byte_len];
        }
        remaining = display_width.trimBreakWhitespace(remaining[chunk.len..]);
        row_count += 1;
        first = false;
    }
    return @max(row_count, 1);
}

pub fn activityFallbackLabel(buf: []u8, projection: ActivityProjection, ctx: RenderContext) []const u8 {
    return switch (projection) {
        .none => "",
        .turn_thinking => |thinking| thinking.label,
        .tool_slot => |slot| slot.thinking_label orelse toolSlotLabelWithTokens(buf, slot.fallback_label, ctx.stream),
    };
}

pub fn appendActivityToolLabel(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    projection: ActivityProjection,
    cols: u16,
) !void {
    switch (projection) {
        .tool_slot => |slot| if (slot.thinking_label != null) {
            try appendConnectedToolLabel(alloc, out, slot.fallback_label, cols);
        },
        .none, .turn_thinking => {},
    }
}

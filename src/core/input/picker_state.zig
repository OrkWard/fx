const std = @import("std");
const file_picker_path = @import("file_picker_path.zig");
const file_completion_state = @import("file_completion_state.zig");
const editor_state = @import("editor_state.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const ModelPickerStage = enum {
    model,
    effort,
    fast,
};

pub const InlinePickerKind = enum {
    slash,
    model,
    provider,
    file,
    skill,
};

const InlinePickerSuppression = union(enum) {
    dismissed_until_trigger_change: InlinePickerKind,
    history_slash_recall_until_edit,

    fn kind(self: InlinePickerSuppression) InlinePickerKind {
        return switch (self) {
            .dismissed_until_trigger_change => |suppressed_kind| suppressed_kind,
            .history_slash_recall_until_edit => .slash,
        };
    }
};

pub const model_picker_speed_options = [_][]const u8{ "normal", "fast", "ultrafast" };

/// `/login` and `/setup` are aliases of `/provider`: all open the same
/// columnar picker. Typed text keeps whichever spelling the user wrote;
/// executing the bare command reseeds the composer with the canonical
/// `/provider ` prefix.
pub const provider_prefix = "/provider ";
pub const login_prefix = "/login ";
const setup_prefix = "/setup ";
pub const provider_picker_prefixes = [_][]const u8{ provider_prefix, login_prefix, setup_prefix };

pub const ModelPickerQuery = struct {
    stage: ModelPickerStage,
    query: []const u8,
    token_start: usize,
};

pub const ProviderPickerQuery = struct {
    /// The `/provider ` or `/login ` the user typed, kept verbatim so rewriting
    /// the composer does not swap one alias for the other.
    prefix: []const u8,
    query: []const u8,
    token_start: usize,
};

pub const FilePickerQuery = file_picker_path.Query;

pub const InlineSkillQuery = struct {
    /// Bytes between `$` and the cursor, without the leading `$`.
    query: []const u8,
    /// Byte offset of the `$` in the composer text.
    dollar_offset: usize,
    /// Byte offset where `query` begins.
    token_start: usize,
};

pub const InlineSlashQuery = struct {
    /// Slash command prefix through the cursor, including the leading `/`.
    prefix: []const u8,
};

/// Owns layout-independent composer picker state. Call `deinit` with the
/// allocator used by `beginModelPickerFlow`.
pub const State = struct {
    slash_completion_index: usize = 0,
    slash_completion_window_start: usize = 0,
    inline_picker_suppression: ?InlinePickerSuppression = null,
    model_completion_index: usize = 0,
    model_completion_window_start: usize = 0,
    model_completion_anchor_current: bool = false,
    model_picker_stage: ModelPickerStage = .model,
    model_picker_pending_model: std.ArrayList(u8) = .empty,
    model_picker_effort_index: usize = 0,
    model_picker_effort_window_start: usize = 0,
    model_picker_fast_index: usize = 0,
    model_picker_fast_window_start: usize = 0,
    provider_column_index: usize = 0,
    provider_column_window_start: usize = 0,
    file_completion: file_completion_state.State = .{},
    // The ordinal is meaningful only within file_completion's presented rows.
    file_completion_index: usize = 0,
    file_completion_window_start: usize = 0,
    file_picker_episode_seen: bool = false,

    pub fn initInto(self: *State) void {
        const state_info = @typeInfo(State).@"struct";
        inline for (state_info.field_names, state_info.field_types, state_info.field_attrs) |field_name, field_type, field_attrs| {
            if (comptime std.mem.eql(u8, field_name, "file_completion")) continue;
            @field(self.*, field_name) = field_attrs.defaultValue(field_type).?;
        }
        self.file_completion.initInto();
    }

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.file_completion.deinit(alloc);
        self.model_picker_pending_model.deinit(alloc);
        const state_info = @typeInfo(State).@"struct";
        inline for (state_info.field_names, state_info.field_types, state_info.field_attrs) |field_name, field_type, field_attrs| {
            // The child's owner already restored its defaults.
            if (comptime std.mem.eql(u8, field_name, "file_completion")) continue;
            @field(self.*, field_name) = field_attrs.defaultValue(field_type).?;
        }
    }

    pub fn resetInlinePickerEpisode(self: *State) void {
        self.file_completion.invalidate();
        self.slash_completion_index = 0;
        self.slash_completion_window_start = 0;
        self.inline_picker_suppression = null;
    }

    pub fn resetInlinePickerForHistoryRecall(self: *State, editor: *const editor_state.State) void {
        self.resetInlinePickerEpisode();
        self.inline_picker_suppression = suppressionForHistoryRecall(
            self.inlinePickerTriggerKind(editor),
        );
    }

    pub fn dismissInlinePicker(self: *State, kind: InlinePickerKind) void {
        if (kind == .file) self.file_completion.invalidate();
        self.inline_picker_suppression = .{ .dismissed_until_trigger_change = kind };
    }

    pub fn isInlinePickerDismissed(self: *const State, kind: InlinePickerKind) bool {
        const suppression = self.inline_picker_suppression orelse return false;
        return switch (suppression) {
            .dismissed_until_trigger_change => |dismissed| dismissed == kind,
            .history_slash_recall_until_edit => false,
        };
    }

    pub fn isInlinePickerSuppressed(self: *const State, kind: InlinePickerKind) bool {
        const suppression = self.inline_picker_suppression orelse return false;
        return suppression.kind() == kind;
    }

    pub fn reconcileInlinePickerAfterEdit(self: *State, editor: *const editor_state.State) void {
        self.slash_completion_index = 0;
        self.slash_completion_window_start = 0;
        self.inline_picker_suppression = suppressionAfterEdit(
            self.inline_picker_suppression,
            self.inlinePickerTriggerKind(editor),
        );
    }

    pub fn resetFilePickerIndex(self: *State) void {
        self.file_completion_index = 0;
        self.file_completion_window_start = 0;
    }

    pub fn activeFilePickerQuery(self: *const State, editor: *const editor_state.State) ?FilePickerQuery {
        if (self.isInlinePickerSuppressed(.file)) return null;
        return self.rawFilePickerQuery(editor);
    }

    pub fn activeModelPickerQuery(self: *const State, editor: *const editor_state.State) ?ModelPickerQuery {
        if (self.isInlinePickerSuppressed(.model)) return null;
        return self.rawModelPickerQuery(editor);
    }

    pub fn activeProviderPickerQuery(self: *const State, editor: *const editor_state.State) ?ProviderPickerQuery {
        if (self.isInlinePickerDismissed(.provider)) return null;
        return self.rawProviderPickerQuery(editor);
    }

    pub fn activeInlineSkillQuery(self: *const State, editor: *const editor_state.State) ?InlineSkillQuery {
        if (self.isInlinePickerSuppressed(.skill)) return null;
        return findInlineSkillQuery(editor.input.items, editor.cursor);
    }

    pub fn activeInlineSlashQuery(self: *const State, editor: *const editor_state.State) ?InlineSlashQuery {
        if (self.isInlinePickerSuppressed(.slash)) return null;
        return findInlineSlashQuery(editor.input.items, editor.cursor);
    }

    fn rawFilePickerQuery(self: *const State, editor: *const editor_state.State) ?FilePickerQuery {
        if (self.rawModelPickerQuery(editor) != null) return null;
        if (self.rawProviderPickerQuery(editor) != null) return null;
        return findFilePickerQuery(editor.input.items, editor.cursor);
    }

    pub fn inlinePickerTriggerKind(self: *const State, editor: *const editor_state.State) ?InlinePickerKind {
        if (self.rawModelPickerQuery(editor) != null) return .model;
        if (self.rawProviderPickerQuery(editor) != null) return .provider;
        if (self.rawFilePickerQuery(editor) != null) return .file;
        if (findInlineSkillQuery(editor.input.items, editor.cursor) != null) return .skill;
        if (findInlineSlashQuery(editor.input.items, editor.cursor) != null) return .slash;
        const trimmed = std.mem.trimStart(u8, editor.input.items, " \t\r\n");
        if (trimmed.len > 0 and trimmed[0] == '/') return .slash;
        return null;
    }

    fn rawModelPickerQuery(self: *const State, editor: *const editor_state.State) ?ModelPickerQuery {
        const items = editor.input.items;
        const trim_start = leadingWhitespaceLen(items);
        const trimmed = items[trim_start..];
        const prefix = "/model ";
        if (trimmed.len < prefix.len or !std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) return null;

        switch (self.model_picker_stage) {
            .model => return .{
                .stage = .model,
                .query = trimmed[prefix.len..],
                .token_start = trim_start + prefix.len,
            },
            .effort => {
                const token_start = modelPickerTokenStart(trimmed, self.model_picker_pending_model.items, .effort) orelse return null;
                return .{
                    .stage = .effort,
                    .query = trimmed[token_start..],
                    .token_start = trim_start + token_start,
                };
            },
            .fast => {
                const token_start = modelPickerTokenStart(trimmed, self.model_picker_pending_model.items, .fast) orelse return null;
                return .{
                    .stage = .fast,
                    .query = trimmed[token_start..],
                    .token_start = trim_start + token_start,
                };
            },
        }
    }

    fn rawProviderPickerQuery(_: *const State, editor: *const editor_state.State) ?ProviderPickerQuery {
        const items = editor.input.items;
        const trim_start = leadingWhitespaceLen(items);
        const trimmed = items[trim_start..];
        const prefix_len = providerPickerPrefixLen(trimmed) orelse return null;
        return .{
            .prefix = trimmed[0..prefix_len],
            .query = trimmed[prefix_len..],
            .token_start = trim_start + prefix_len,
        };
    }

    /// The composer text changed, so whichever column is open no longer has a
    /// trustworthy highlighted row.
    pub fn resetActiveCompletionIndex(self: *State) void {
        self.resetActiveModelPickerIndex();
        self.clearProviderPickerFlow();
    }

    pub fn clearProviderPickerFlow(self: *State) void {
        self.provider_column_index = 0;
        self.provider_column_window_start = 0;
    }

    pub fn isModelShapedInput(self: *const State, editor: *const editor_state.State) bool {
        return isBareModelCommandAtCursor(editor) or self.rawModelPickerQuery(editor) != null;
    }

    fn resetActiveModelPickerIndex(self: *State) void {
        switch (self.model_picker_stage) {
            .model => {
                self.model_completion_index = 0;
                self.model_completion_window_start = 0;
                self.model_completion_anchor_current = false;
            },
            .effort => {
                self.model_picker_effort_index = 0;
                self.model_picker_effort_window_start = 0;
            },
            .fast => {
                self.model_picker_fast_index = 0;
                self.model_picker_fast_window_start = 0;
            },
        }
    }

    pub fn beginModelPickerFlow(
        self: *State,
        alloc: Allocator,
        model: []const u8,
        effort_index: usize,
        fast_mode: bool,
        ultrafast_mode: bool,
        stage: ModelPickerStage,
    ) Allocator.Error!void {
        const stable_model = try alloc.dupe(u8, model);
        defer alloc.free(stable_model);

        try self.model_picker_pending_model.ensureTotalCapacity(alloc, stable_model.len);
        self.model_picker_pending_model.clearRetainingCapacity();
        self.model_picker_pending_model.appendSliceAssumeCapacity(stable_model);
        self.model_picker_stage = stage;
        self.model_picker_effort_index = effort_index;
        self.model_picker_effort_window_start = 0;
        self.model_picker_fast_index = if (ultrafast_mode) 2 else if (fast_mode) 1 else 0;
        self.model_picker_fast_window_start = 0;
    }

    pub fn clearModelPickerFlow(self: *State) void {
        self.model_picker_stage = .model;
        self.model_picker_pending_model.clearRetainingCapacity();
        self.model_picker_effort_index = 0;
        self.model_picker_effort_window_start = 0;
        self.model_picker_fast_index = 0;
        self.model_picker_fast_window_start = 0;
        self.model_completion_index = 0;
        self.model_completion_window_start = 0;
        self.model_completion_anchor_current = false;
    }

    pub fn hasPendingModelPickerSelection(self: *const State) bool {
        return self.model_picker_pending_model.items.len > 0;
    }

    pub fn selectedModelPickerEffortIndex(self: *const State) usize {
        return self.model_picker_effort_index;
    }

    pub fn selectedModelPickerSpeed(self: *const State) []const u8 {
        return model_picker_speed_options[self.model_picker_fast_index % model_picker_speed_options.len];
    }

    pub fn selectedModelPickerFast(self: *const State) bool {
        return std.mem.eql(u8, self.selectedModelPickerSpeed(), "fast");
    }
};

fn suppressionForHistoryRecall(trigger: ?InlinePickerKind) ?InlinePickerSuppression {
    if (trigger != .slash) return null;
    return .history_slash_recall_until_edit;
}

fn suppressionAfterEdit(
    current: ?InlinePickerSuppression,
    trigger: ?InlinePickerKind,
) ?InlinePickerSuppression {
    const suppression = current orelse return null;
    return switch (suppression) {
        .dismissed_until_trigger_change => |dismissed| if (trigger == dismissed)
            suppression
        else
            null,
        .history_slash_recall_until_edit => null,
    };
}

pub fn isBareModelCommandAtCursor(editor: *const editor_state.State) bool {
    if (editor.cursor != editor.input.items.len) return false;
    const trimmed = std.mem.trimStart(u8, editor.input.items, " \t");
    return std.ascii.eqlIgnoreCase(trimmed, "/model");
}

pub fn filterCompletionLabels(query: []const u8, options: []const []const u8, out: [][]const u8) usize {
    const normalized_query = std.mem.trim(u8, query, " \t");
    var count: usize = 0;
    for (options) |option| {
        if (count >= out.len) break;
        if (normalized_query.len == 0 or text_utils.containsIgnoreCase(option, normalized_query)) {
            out[count] = option;
            count += 1;
        }
    }
    return count;
}

/// Compacts `labels` and its parallel `annotations` in place to the entries
/// matching `query`, keeping the two arrays aligned.
pub fn filterAnnotatedLabels(
    query: []const u8,
    labels: [][]const u8,
    annotations: [][]const u8,
    count: usize,
) usize {
    const normalized_query = std.mem.trim(u8, query, " \t");
    if (normalized_query.len == 0) return count;

    var kept: usize = 0;
    for (0..count) |i| {
        if (!text_utils.containsIgnoreCase(labels[i], normalized_query)) continue;
        labels[kept] = labels[i];
        annotations[kept] = annotations[i];
        kept += 1;
    }
    return kept;
}

pub fn isFilePickerTerminator(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn leadingWhitespaceLen(bytes: []const u8) usize {
    var index: usize = 0;
    while (index < bytes.len and (bytes[index] == ' ' or bytes[index] == '\t')) : (index += 1) {}
    return index;
}

fn findFilePickerQuery(items: []const u8, cursor: usize) ?FilePickerQuery {
    return file_picker_path.query_at(items, cursor);
}

fn findInlineSkillQuery(items: []const u8, cursor: usize) ?InlineSkillQuery {
    if (cursor != items.len) return null;

    var index = cursor;
    while (index > 0) {
        const byte = items[index - 1];
        if (isFilePickerTerminator(byte)) return null;
        index -= 1;
        if (byte != '$') continue;
        if (file_picker_path.contains_position(items, index)) return null;
        return .{
            .query = items[index + 1 .. cursor],
            .dollar_offset = index,
            .token_start = index + 1,
        };
    }
    return null;
}

fn findInlineSlashQuery(items: []const u8, cursor: usize) ?InlineSlashQuery {
    if (cursor != items.len) return null;

    var token_start = cursor;
    while (token_start > 0 and !isFilePickerTerminator(items[token_start - 1])) {
        token_start -= 1;
    }
    if (token_start == 0 or token_start + 1 >= cursor or items[token_start] != '/') return null;
    if (std.mem.trim(u8, items[0..token_start], " \t\r\n").len == 0) return null;

    return .{ .prefix = items[token_start..cursor] };
}

fn modelPickerTokenStart(trimmed: []const u8, model: []const u8, stage: ModelPickerStage) ?usize {
    const prefix = "/model ";
    if (trimmed.len < prefix.len or !std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) return null;
    if (model.len == 0) return null;

    const after_prefix = trimmed[prefix.len..];
    if (after_prefix.len < model.len or !std.mem.eql(u8, after_prefix[0..model.len], model)) return null;

    const after_model = prefix.len + model.len;
    if (stage == .effort) return skipPickerSpaces(trimmed, after_model);

    const effort_start = skipPickerSpaces(trimmed, after_model);
    if (effort_start >= trimmed.len) return null;

    var effort_end = effort_start;
    while (effort_end < trimmed.len and trimmed[effort_end] != ' ' and trimmed[effort_end] != '\t') : (effort_end += 1) {}
    return skipPickerSpaces(trimmed, effort_end);
}

fn providerPickerPrefixLen(trimmed: []const u8) ?usize {
    for (provider_picker_prefixes) |prefix| {
        if (trimmed.len < prefix.len) continue;
        if (std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) return prefix.len;
    }
    return null;
}

fn skipPickerSpaces(bytes: []const u8, start: usize) usize {
    var index = start;
    while (index < bytes.len and (bytes[index] == ' ' or bytes[index] == '\t')) : (index += 1) {}
    return index;
}

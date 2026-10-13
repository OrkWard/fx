const std = @import("std");
const question_prompt = @import("../../core/agent/question_prompt.zig");
const approval_decision = @import("../../core/permissions/approval_decision.zig");
const core_input_runtime = @import("../../core/input/runtime.zig");
const native_clear_probe_runtime = @import("native_clear_probe.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");
const cursor_probe = @import("../terminal/cursor_probe.zig");
const theme_monitor = @import("../terminal/theme_monitor.zig");
const input_action = @import("../../core/input/input_action.zig");
const vertical_navigation = @import("../../core/input/vertical_navigation.zig");
const visual_layout = @import("visual_layout.zig");
const escape_parser = @import("escape_parser.zig");
const shortcuts = @import("shortcuts.zig");
const terminal_action_decoder = @import("terminal_action_decoder.zig");

const InputRuntime = core_input_runtime.Runtime;

const Allocator = std.mem.Allocator;

pub const DeferredTerminalInputSource = enum {
    theme_monitor,
    cursor_probe,
};

pub const TerminalInputOwner = enum {
    theme_monitor,
    paste,
    fx_input,
};

pub fn terminalInputOwner(
    monitor: *const theme_monitor.Monitor,
    paste_active: bool,
) TerminalInputOwner {
    if (monitor.ownsInput()) return .theme_monitor;
    if (paste_active) return .paste;
    if (monitor.enabled) return .theme_monitor;
    return .fx_input;
}

pub const shortcutFromControlByte = shortcuts.fromControlByte;

pub fn approvalActionFromByte(byte: u8) ?approval_decision.Action {
    return switch (byte) {
        3 => .deny,
        '\r', '\n' => .submit,
        '\t' => .tab,
        0x7F, 0x08 => .backspace,
        '1'...'3' => .{ .number = byte - '1' },
        else => if (byte >= 0x20 and byte <= 0x7E)
            .{ .insert_ascii = byte }
        else
            null,
    };
}

fn approvalDraftActionFromShortcut(
    action: input_action.ShortcutAction,
) ?approval_decision.DraftAction {
    return switch (action) {
        .move => |intent| switch (intent.kind) {
            .character_left => .cursor_left,
            .character_right => .cursor_right,
            .line_start, .draft_start => .cursor_home,
            .line_end, .draft_end => .cursor_end,
            .word_left => .cursor_word_left,
            .word_right => .cursor_word_right,
            else => null,
        },
        .delete_forward => .delete_next,
        .delete_word_left => .delete_word_left,
        .delete_whitespace_word_left => .delete_whitespace_word_left,
        .delete_word_right => .delete_word_right,
        .delete_to_line_start => .delete_to_line_start,
        .delete_to_line_end => .delete_to_line_end,
        else => null,
    };
}

fn approvalDraftActionFromControlByte(byte: u8) ?approval_decision.DraftAction {
    const action = shortcuts.fromFocusedEditorControlByte(byte) orelse return null;
    return approvalDraftActionFromShortcut(action);
}

fn approvalActionFromRawByte(byte: u8) ?approval_decision.Action {
    if (approvalDraftActionFromControlByte(byte)) |edit| {
        return .{ .edit_draft = edit };
    }
    return approvalActionFromByte(byte);
}

fn withApprovalInput(
    ingress: input_action.TerminalInputIngress,
) input_action.TerminalInputIngress {
    var typed = ingress;
    const event = typed.event orelse return typed;
    typed.event = switch (event) {
        .raw => |raw| input_action.TerminalInputEvent{ .raw = .{
            .byte = raw.byte,
            .composer_shortcut = raw.composer_shortcut,
            .approval_action = approvalActionFromRawByte(raw.byte),
        } },
        .action => |decoded| input_action.TerminalInputEvent{ .action = .{
            .action = decoded.action,
            .composer_shortcut = decoded.composer_shortcut,
            .approval_focused_edit = if (decoded.composer_shortcut) |shortcut|
                approvalDraftActionFromShortcut(shortcut)
            else
                null,
            .cancel_pending = decoded.cancel_pending,
        } },
        .paste_byte => event,
    };
    return typed;
}

fn questionActionFromByte(
    byte: u8,
    freeform_selected: bool,
) ?question_prompt.Action {
    return switch (byte) {
        3 => .cancel,
        '\r', '\n' => .submit,
        '\t' => .next_entry,
        0x7F, 0x08 => if (freeform_selected) .backspace else null,
        '1'...'9' => if (freeform_selected)
            .{ .insert_ascii = byte }
        else
            .{ .select_ordinal = byte - '1' },
        else => if (freeform_selected and byte >= 0x20 and byte <= 0x7E)
            .{ .insert_ascii = byte }
        else
            null,
    };
}

fn questionFreeformActionFromShortcut(
    action: input_action.ShortcutAction,
) ?question_prompt.FreeformAction {
    return switch (action) {
        .move => |intent| switch (intent.kind) {
            .character_left => .cursor_left,
            .character_right => .cursor_right,
            .line_start, .draft_start => .cursor_home,
            .line_end, .draft_end => .cursor_end,
            .word_left => .cursor_word_left,
            .word_right => .cursor_word_right,
            else => null,
        },
        .delete_forward => .delete_next,
        .delete_word_left => .delete_word_left,
        .delete_whitespace_word_left => .delete_whitespace_word_left,
        .delete_word_right => .delete_word_right,
        .delete_to_line_start => .delete_to_line_start,
        .delete_to_line_end => .delete_to_line_end,
        else => null,
    };
}

fn questionActionFromShortcut(
    action: input_action.ShortcutAction,
    freeform_selected: bool,
) ?question_prompt.Action {
    switch (action) {
        .move => |intent| {
            if (intent.extend_selection) {
                switch (intent.kind) {
                    .visual_up => return .{ .move_choice = .previous },
                    .visual_down => return .{ .move_choice = .next },
                    else => {},
                }
            }
        },
        else => {},
    }
    if (!freeform_selected) return null;
    const edit = questionFreeformActionFromShortcut(action) orelse return null;
    return .{ .edit_freeform = edit };
}

fn questionActionFromRawByte(
    byte: u8,
    freeform_selected: bool,
) ?question_prompt.Action {
    if (freeform_selected) {
        if (shortcuts.fromFocusedEditorControlByte(byte)) |shortcut| {
            return questionActionFromShortcut(shortcut, true);
        }
    }
    return questionActionFromByte(byte, freeform_selected);
}

fn questionActionFromDecoded(
    action: input_action.Action,
    shortcut: ?input_action.ShortcutAction,
    freeform_selected: bool,
) ?question_prompt.Action {
    switch (action) {
        .remapped_byte => |byte| return questionActionFromRawByte(
            byte,
            freeform_selected,
        ),
        else => {},
    }
    return questionActionFromShortcut(
        shortcut orelse return null,
        freeform_selected,
    );
}

fn withQuestionInput(
    ingress: input_action.TerminalInputIngress,
    freeform_selected: bool,
) input_action.TerminalInputIngress {
    var typed = ingress;
    const event = typed.event orelse return typed;
    typed.event = switch (event) {
        .raw => |raw| input_action.TerminalInputEvent{ .raw = .{
            .byte = raw.byte,
            .composer_shortcut = raw.composer_shortcut,
            .approval_action = raw.approval_action,
            .question_action = questionActionFromRawByte(
                raw.byte,
                freeform_selected,
            ),
        } },
        .action => |decoded| input_action.TerminalInputEvent{ .action = .{
            .action = decoded.action,
            .composer_shortcut = decoded.composer_shortcut,
            .approval_focused_edit = decoded.approval_focused_edit,
            .question_action = questionActionFromDecoded(
                decoded.action,
                decoded.composer_shortcut,
                freeform_selected,
            ),
            .cancel_pending = decoded.cancel_pending,
        } },
        .paste_byte => event,
    };
    return typed;
}

pub const DeferredSessionInput = union(enum) {
    byte: u8,
    delivery_epoch,
};

pub const Runtime = struct {
    terminal_cursor_probe: cursor_probe.Parser = .{},
    terminal_theme_monitor: theme_monitor.Monitor = .{},
    deferred_terminal_input_source: ?DeferredTerminalInputSource = null,
    deferred_session_input: std.ArrayList(DeferredSessionInput) = .empty,
    deferred_session_input_index: usize = 0,
    deferred_session_completed_end: usize = 0,
    native_clear_probe: native_clear_probe_runtime.Runtime = .{},
    terminal_action_decoder: terminal_action_decoder.Decoder = .{},

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        const dropped = self.discardDeferredSessionInput();
        if (dropped > 0) debug_trace.logf("input", "deferred session input dropped bytes={d} reason=shutdown", .{dropped});
        self.deferred_session_input.deinit(alloc);
        self.native_clear_probe.deinit(alloc);
    }

    pub fn hasDeferredSessionInput(self: *const Runtime) bool {
        return self.deferred_session_input_index < self.deferred_session_input.items.len;
    }

    pub fn deferSessionInputByte(self: *Runtime, alloc: Allocator, byte: u8, limit: usize) !bool {
        if (self.deferred_session_input.items.len - self.deferred_session_input_index >= limit) return false;
        if (self.deferred_session_input_index > 0) {
            const remaining = self.deferred_session_input.items[self.deferred_session_input_index..];
            @memmove(self.deferred_session_input.items[0..remaining.len], remaining);
            self.deferred_session_input.items.len = remaining.len;
            self.deferred_session_completed_end -|= self.deferred_session_input_index;
            self.deferred_session_input_index = 0;
        }
        try self.deferred_session_input.append(alloc, .{ .byte = byte });
        return true;
    }

    pub fn markDeferredSessionDeliveryEpoch(self: *Runtime, alloc: Allocator) !void {
        if (!self.hasDeferredSessionInput() or self.deferred_session_input.items[self.deferred_session_input.items.len - 1] == .delivery_epoch) return;
        try self.deferred_session_input.append(alloc, .delivery_epoch);
        self.deferred_session_completed_end = self.deferred_session_input.items.len;
    }

    pub fn allowCurrentDeferredSessionInputForReplay(self: *Runtime) void {
        self.deferred_session_completed_end = self.deferred_session_input.items.len;
    }

    pub fn takeDeferredSessionInput(self: *Runtime) ?DeferredSessionInput {
        if (self.deferred_session_input_index == self.deferred_session_input.items.len) {
            self.deferred_session_input.clearRetainingCapacity();
            self.deferred_session_input_index = 0;
            self.deferred_session_completed_end = 0;
            return null;
        }
        if (self.deferred_session_input_index >= self.deferred_session_completed_end) return null;
        const item = self.deferred_session_input.items[self.deferred_session_input_index];
        self.deferred_session_input_index += 1;
        return item;
    }

    pub fn discardDeferredSessionInput(self: *Runtime) usize {
        var dropped: usize = 0;
        for (self.deferred_session_input.items[self.deferred_session_input_index..]) |item| {
            if (item == .byte) dropped += 1;
        }
        self.deferred_session_input.clearRetainingCapacity();
        self.deferred_session_input_index = 0;
        self.deferred_session_completed_end = 0;
        return dropped;
    }

    pub fn resetEscapeDecoder(self: *Runtime) void {
        self.terminal_action_decoder.reset();
    }

    pub fn hasPendingTerminalAction(self: *const Runtime) bool {
        return self.terminal_action_decoder.hasPending();
    }

    pub fn hasPendingTerminalInput(self: *const Runtime) bool {
        return self.hasPendingTerminalAction() or
            self.terminal_theme_monitor.hasPendingInput() or
            self.terminal_cursor_probe.hasPendingInput();
    }

    pub fn decodeTerminalByte(
        self: *Runtime,
        byte: u8,
        context: input_action.TerminalDecodeContext,
    ) input_action.TerminalInputIngress {
        if (context.paste_active) return terminal_action_decoder.pasteByteIngress(byte);
        return withQuestionInput(
            withApprovalInput(self.terminal_action_decoder.feed(byte, context)),
            context.question_freeform_selected,
        );
    }

    pub fn flushTerminalAction(
        self: *Runtime,
        now_ms: i64,
        timeout_ms: i64,
        paste_active: bool,
    ) input_action.TerminalInputIngress {
        return self.terminal_action_decoder.flush(now_ms, timeout_ms, paste_active);
    }

    pub fn takeDeferredTerminalInputByte(self: *Runtime) ?u8 {
        if (self.takeDeferredThemeMonitorByte()) |byte| return byte;
        if (self.terminal_cursor_probe.takeDeferredByte()) |byte| {
            self.deferred_terminal_input_source = .cursor_probe;
            return byte;
        }
        return null;
    }

    pub fn takeDeferredThemeMonitorByte(self: *Runtime) ?u8 {
        std.debug.assert(self.deferred_terminal_input_source == null);
        if (self.terminal_theme_monitor.takeDeferredByte()) |byte| {
            self.deferred_terminal_input_source = .theme_monitor;
            return byte;
        }
        return null;
    }

    pub fn consumeDeferredTerminalInputDispatch(self: *Runtime) ?DeferredTerminalInputSource {
        const source = self.deferred_terminal_input_source;
        self.deferred_terminal_input_source = null;
        return switch (source orelse return null) {
            .theme_monitor => blk: {
                std.debug.assert(self.terminal_theme_monitor.consumeDeferredInputDispatch());
                break :blk .theme_monitor;
            },
            .cursor_probe => blk: {
                std.debug.assert(self.terminal_cursor_probe.consumeDeferredInputDispatch());
                break :blk .cursor_probe;
            },
        };
    }
};

pub fn scanInputCursorVertical(
    input: *const InputRuntime,
    direction: visual_layout.Direction,
    terminal_cols: u16,
    pending_images: []const types.ImageAttachment,
) visual_layout.VerticalScan {
    return visual_layout.scanAdjacentRow(.{
        .input = input.edit_state.input.items,
        .cursor = input.edit_state.cursor,
        .terminal_cols = terminal_cols,
        .images = pending_images,
        .pasted_blocks = input.entities.pasted_blocks.items,
        .image_tokens = input.entities.image_tokens.items,
        .skill_tokens = input.entities.skill_tokens.items,
    }, direction, input.vertical_navigation.preferredColumn());
}

pub fn scanInputCursorRows(
    input: *const InputRuntime,
    direction: visual_layout.Direction,
    row_count: usize,
    terminal_cols: u16,
    pending_images: []const types.ImageAttachment,
) visual_layout.VerticalScan {
    return visual_layout.scanRowDelta(.{
        .input = input.edit_state.input.items,
        .cursor = input.edit_state.cursor,
        .terminal_cols = terminal_cols,
        .images = pending_images,
        .pasted_blocks = input.entities.pasted_blocks.items,
        .image_tokens = input.entities.image_tokens.items,
        .skill_tokens = input.entities.skill_tokens.items,
    }, direction, row_count, input.vertical_navigation.preferredColumn());
}

pub const MouseReportDiscardResult = escape_parser.MouseReportDiscardResult;
pub const isLegacyX10PayloadStage = escape_parser.isLegacyX10PayloadStage;
pub const isMouseReportPayloadStage = escape_parser.isMouseReportPayloadStage;
pub const isMouseReportDiscardStage = escape_parser.isMouseReportDiscardStage;
pub const isControlSequenceDiscardStage = escape_parser.isControlSequenceDiscardStage;
pub const beginMouseReportDiscard = escape_parser.beginMouseReportDiscard;
pub const consumeMouseReportDiscardByte = escape_parser.consumeMouseReportDiscardByte;
pub const consumeInputEscapeByte = escape_parser.consumeInputEscapeByte;
pub const consumeInputEscapeByteWithMouse = escape_parser.consumeInputEscapeByteWithMouse;
pub const controlByteFeatureAction = escape_parser.controlByteFeatureAction;

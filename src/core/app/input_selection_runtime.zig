const std = @import("std");
const host = @import("../hosts/host.zig");
const composer_selection = @import("../input/composer_selection.zig");
const composer_replacement = @import("../input/composer_replacement.zig");
const editor_state = @import("../input/editor_state.zig");

pub const ClipboardResult = enum {
    inactive,
    copied,
    cut,
    copy_failed,
    delete_failed,
};

pub fn copySelection(
    edit: *const editor_state.State,
    clipboard: host.Clipboard,
) ClipboardResult {
    const selected = edit.selectedText() orelse return .inactive;
    if (!(clipboard.copy(selected) catch false)) return .copy_failed;
    return .copied;
}

pub fn cutSelection(
    alloc: std.mem.Allocator,
    selection: composer_selection.State,
    pending_images: ?*composer_replacement.ImageBlocks,
    clipboard: host.Clipboard,
) ClipboardResult {
    const selected = selection.selectedText() orelse return .inactive;
    if (!(clipboard.copy(selected) catch false)) return .copy_failed;
    if (!selection.delete(alloc, pending_images)) return .delete_failed;
    return .cut;
}

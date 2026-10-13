const std = @import("std");
const composer_insertion = @import("composer_insertion.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const registered_entities = @import("registered_entities.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

/// Borrows the Core state changed by one composer skill-token binding.
/// The containing input runtime retains ownership of every pointer and allocation.
pub const State = struct {
    insertion: composer_insertion.State,

    pub fn bindSkillToken(
        self: State,
        alloc: Allocator,
        replace_start: usize,
        replace_end: usize,
        name: []const u8,
        path: []const u8,
        display_source: ?skill_contract.SkillSource,
    ) registered_entities.BindError!void {
        try self.insertion.entities.bindSkillToken(
            alloc,
            self.insertion.edit,
            replace_start,
            replace_end,
            name,
            path,
            display_source,
        );
        self.insertion.history.reset(alloc);
        self.insertion.vertical_navigation.reset();
        self.insertion.picker.reconcileInlinePickerAfterEdit(self.insertion.edit);
        self.insertion.picker.resetActiveCompletionIndex();
        self.insertion.input_limit_rejection.* = input_limit_rejection.clear();
    }
};

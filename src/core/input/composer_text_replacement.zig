const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const input_reset = @import("input_reset.zig");
const pasted_blocks = @import("pasted_blocks.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

/// Owns staged replacement bytes before commit and the displaced editor buffer
/// afterward. Always call `deinit` with the allocator used by `prepare`.
pub const Prepared = struct {
    input: std.ArrayList(u8) = .empty,
    dropped_entities: DroppedEntities = .{},

    pub fn deinit(self: *Prepared, alloc: Allocator) void {
        self.input.deinit(alloc);
        self.* = .{};
    }
};

const DroppedEntities = struct {
    pasted_blocks: usize = 0,
    image_tokens: usize = 0,
    skill_tokens: usize = 0,
};

/// Borrows the Core state changed by one whole-composer text replacement.
/// The containing input runtime retains ownership of every pointer and allocation.
pub const State = struct {
    edit: *editor_state.State,
    history: *edit_history.State,
    picker: *picker_state.State,
    entities: *registered_entities.State,
    vertical_navigation: *vertical_navigation.State,
    input_limit_rejection: *input_limit_rejection.State,

    /// Stages an exact replacement and records the entities it supersedes
    /// without mutating composer state.
    pub fn prepare(
        self: State,
        alloc: Allocator,
        text: []const u8,
    ) Allocator.Error!Prepared {
        var prepared: Prepared = .{
            .dropped_entities = .{
                .pasted_blocks = self.entities.pasted_blocks.items.len,
                .image_tokens = self.entities.image_tokens.items.len,
                .skill_tokens = self.entities.skill_tokens.items.len,
            },
        };
        errdefer prepared.deinit(alloc);
        try prepared.input.appendSlice(alloc, text);
        return prepared;
    }

    pub fn replace(
        self: State,
        alloc: Allocator,
        text: []const u8,
    ) Allocator.Error!void {
        var prepared_replacement = try self.prepare(alloc, text);
        defer prepared_replacement.deinit(alloc);
        self.commit(alloc, &prepared_replacement);
    }

    /// Swaps in staged text and resets metadata without further allocation.
    /// On return, `prepared_replacement` owns the displaced editor buffer.
    pub fn commit(
        self: State,
        alloc: Allocator,
        prepared_replacement: *Prepared,
    ) void {
        self.vertical_navigation.reset();
        input_reset.discardSelectionWithTrace(self.edit, "input_replaced");
        self.picker.clearModelPickerFlow();
        self.picker.clearProviderPickerFlow();
        traceDroppedEntities(prepared_replacement.dropped_entities);
        pasted_blocks.clearBlocks(alloc, &self.entities.pasted_blocks);
        self.entities.clearImageAndSkillTokens(alloc);
        self.edit.swapInput(&prepared_replacement.input);
        self.history.reset(alloc);
        self.picker.resetInlinePickerEpisode();
        self.picker.model_completion_index = 0;
        self.picker.model_completion_window_start = 0;
        self.picker.resetFilePickerIndex();
        self.input_limit_rejection.* = input_limit_rejection.clear();
    }
};

fn traceDroppedEntities(entities: DroppedEntities) void {
    if (entities.pasted_blocks > 0) {
        debug_trace.logf(
            "input",
            "pasted blocks dropped count={d} reason=input_replaced",
            .{entities.pasted_blocks},
        );
    }
    if (entities.image_tokens > 0) {
        debug_trace.logf(
            "input",
            "image tokens dropped count={d} reason=input_replaced",
            .{entities.image_tokens},
        );
    }
    if (entities.skill_tokens > 0) {
        debug_trace.logf(
            "input",
            "skill tokens dropped count={d} reason=input_replaced",
            .{entities.skill_tokens},
        );
    }
}

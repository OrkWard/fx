const std = @import("std");
const composer_history = @import("composer_history.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const registered_entities = @import("registered_entities.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

/// Composer state set aside while the model picker shortcut borrows the
/// composer as the catalog menu's query box. `capture` moves the state out of
/// the live composer, leaving it empty for the picker flow; `restore` moves it
/// back verbatim, tearing down whatever the flow left behind. Neither performs
/// I/O, so the round trip cannot lose the draft to a partial failure.
pub const State = struct {
    edit: editor_state.State = .{},
    entities: registered_entities.State = .{},
    edit_history: edit_history.State = .{},
    vertical_navigation: vertical_navigation.State = .{},
    history_nav: composer_history.State.NavigationSnapshot = .{},

    /// Non-owning view of the live composer state the stash moves in and out.
    /// Callers retain ownership of every referenced state value.
    pub const ComposerView = struct {
        edit: *editor_state.State,
        entities: *registered_entities.State,
        edit_history: *edit_history.State,
        vertical_navigation: *vertical_navigation.State,
        composer_history: *composer_history.State,
    };

    pub fn capture(view: ComposerView) State {
        const stash: State = .{
            .edit = view.edit.*,
            .entities = view.entities.*,
            .edit_history = view.edit_history.*,
            .vertical_navigation = view.vertical_navigation.*,
            .history_nav = view.composer_history.takeNavigation(),
        };
        view.edit.* = .{};
        view.entities.* = .{};
        view.edit_history.* = .{};
        view.vertical_navigation.* = .{};
        return stash;
    }

    /// Consumes the stash: the flow-era composer state is torn down and the
    /// stashed state moves back in, leaving the stash empty.
    pub fn restore(self: *State, alloc: Allocator, view: ComposerView) void {
        view.edit.deinit(alloc);
        view.entities.deinit(alloc);
        view.edit_history.deinit(alloc);
        view.edit.* = self.edit;
        view.entities.* = self.entities;
        view.edit_history.* = self.edit_history;
        view.vertical_navigation.* = self.vertical_navigation;
        view.composer_history.restoreNavigation(alloc, &self.history_nav);
        self.* = .{};
    }

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.edit.deinit(alloc);
        self.entities.deinit(alloc);
        self.edit_history.deinit(alloc);
        self.history_nav.deinit(alloc);
        self.* = .{};
    }
};

//! Behavior for the `/provider` picker: one column listing the providers.
//!
//! Terminal actions are not reimplemented here. A commit is expressed as an
//! `auth_runtime.Choice` and handed to the auth runtime, which owns provider
//! switching and sign-in.

const std = @import("std");
const auth_runtime = @import("../auth/auth_runtime.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const provider_picker_catalog = @import("../auth/provider_picker_catalog.zig");
const model_provider = @import("../config/model_provider.zig");
const picker_state = @import("../input/picker_state.zig");
const list_window = @import("../shared/list_window.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");

const max_options = provider_picker_catalog.max_provider_options;

/// Scratch for the column: stack-local in key handlers, container-retained in
/// the render path.
pub const ColumnBuffer = struct {
    labels: [max_options][]const u8 = undefined,
    annotations: [max_options][]const u8 = undefined,
    count: usize = 0,
};

/// Hosts without a composer, an auth runtime, or a provider selection have no
/// `/provider` picker; every entry point below is inert for them.
pub fn supported(comptime App: type) bool {
    return @hasField(App, "input_runtime") and
        @hasField(App, "auth") and
        provider_runtime.supported(App);
}

pub fn Runtime(comptime App: type) type {
    return struct {
        /// Fills the column with providers and their `current` annotations,
        /// then narrows both to what the typed query matches.
        pub fn columnOptions(
            app: *App,
            query: picker_state.ProviderPickerQuery,
            column: *ColumnBuffer,
        ) usize {
            column.count = 0;
            if (comptime !supported(App)) return 0;
            if (app.auth.sourceInventoryRefreshActive()) {
                column.labels[0] = "checking credentials...";
                column.annotations[0] = "";
                column.count = 1;
                return column.count;
            }
            const active_provider = provider_runtime.provider(app);
            var slugs: [max_options][]const u8 = undefined;
            const count = provider_picker_catalog.providerOptions(&slugs);
            for (slugs[0..count], 0..) |slug, i| {
                column.labels[i] = slug;
                const id = provider_catalog.parse(slug) orelse .codex;
                column.annotations[i] = if (id.eql(active_provider) and
                    model_provider.authorizesCredential(id, app.auth.credentialSource())) "current" else "";
            }
            column.count = picker_state.filterAnnotatedLabels(
                query.query,
                &column.labels,
                &column.annotations,
                count,
            );
            return column.count;
        }

        pub fn hasQuery(app: *App) bool {
            if (comptime !supported(App)) return false;
            return app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) != null;
        }

        pub fn navigate(app: *App, delta: i32) void {
            if (comptime !supported(App)) return;
            if (app.auth.sourceInventoryRefreshActive()) return;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return;
            var column: ColumnBuffer = .{};
            const count = columnOptions(app, query, &column);
            const picker = &app.input_runtime.picker;
            list_window.advanceSelection(&picker.provider_column_index, &picker.provider_column_window_start, count, delta);
        }

        /// Tab: write the highlighted provider into the composer.
        pub fn autocomplete(app: *App) !void {
            if (comptime !supported(App)) return;
            if (app.auth.sourceInventoryRefreshActive()) return;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return;
            var column: ColumnBuffer = .{};
            _ = columnOptions(app, query, &column);
            const selected = selectedLabel(app, query, &column) orelse return;
            const prefix = try app.alloc.dupe(u8, query.prefix);
            defer app.alloc.free(prefix);
            const text = try app.alloc.print("{s}{s}", .{ prefix, selected });
            defer app.alloc.free(text);
            try app.input_runtime.textReplacementState().replace(app.alloc, text);
            app.shell.render_requests.request(.footer);
        }

        /// There is no column after the provider, so space never advances.
        pub fn advanceOnSpace(_: *App) !bool {
            return false;
        }

        /// Enter: hand the chosen provider to the auth runtime.
        pub fn submit(app: *App) !bool {
            if (comptime !supported(App)) return false;
            if (!hasQuery(app)) return false;
            if (app.auth.sourceInventoryRefreshActive()) return true;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return false;
            var column: ColumnBuffer = .{};
            _ = columnOptions(app, query, &column);
            // No matching option: let Enter fall through so the router reports
            // the unknown text instead of silently eating the key.
            const selected = selectedLabel(app, query, &column) orelse return false;
            const provider = provider_catalog.parse(selected) orelse return false;
            try commit(app, .{ .provider = provider });
            return true;
        }

        /// There is no column to the left of the provider column.
        pub fn stepBack(_: *App) !bool {
            return false;
        }

        pub fn abandon(app: *App) void {
            if (comptime !supported(App)) return;
            app.input_runtime.picker.clearProviderPickerFlow();
        }

        fn commit(app: *App, choice: auth_runtime.Choice) !void {
            app.input_runtime.picker.clearProviderPickerFlow();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            try app_auth_runtime.Runtime(App).applyPickerChoice(app, choice);
            app.shell.render_requests.request(.footer);
        }

        fn selectedLabel(
            app: *App,
            query: picker_state.ProviderPickerQuery,
            column: *const ColumnBuffer,
        ) ?[]const u8 {
            if (column.count == 0) return null;
            if (exactLabel(query.query, column)) |label| return label;
            return column.labels[app.input_runtime.picker.provider_column_index % column.count];
        }
    };
}

fn exactLabel(raw_query: []const u8, column: *const ColumnBuffer) ?[]const u8 {
    const query = std.mem.trim(u8, raw_query, " \t");
    if (query.len == 0) return null;
    for (column.labels[0..column.count]) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, query)) return candidate;
    }
    return null;
}

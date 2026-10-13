const std = @import("std");
const auto_upgrade = @import("../upgrade/auto_upgrade.zig");
const types = @import("../shared/types.zig");
const upgrade_helpers = @import("../upgrade/upgrade_helpers.zig");

pub const ApplyOutcome = enum {
    not_ready,
    unavailable,
    relaunch_requested,
};

const CurrentExecutablePathFn = *const fn (
    ?*anyopaque,
    []u8,
) upgrade_helpers.ExecutablePathError![]const u8;

pub const Deps = struct {
    ctx: ?*anyopaque = null,
    current_executable_path: CurrentExecutablePathFn = currentExecutablePathDefault,
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn applyReadyUpgrade(app: *App) !void {
            _ = try applyReadyUpgradeWithDeps(app, .{});
        }

        pub fn collectUpgradeFacts(app: *App) void {
            if (!autoUpgradeEnabled(app)) return;

            if (comptime @hasField(App, "upgrader")) {
                if (comptime @hasDecl(@TypeOf(app.upgrader), "takeRenderDirty")) {
                    if (app.upgrader.takeRenderDirty()) requestFooterRender(app);
                }
            }
        }

        pub fn applyReadyUpgradeWithDeps(
            app: *App,
            deps: Deps,
        ) !ApplyOutcome {
            if (upgradeUnavailableNotice(app)) |notice| {
                try writeUpgradeNotice(app, .neutral, notice);
                return .unavailable;
            }

            if (!autoUpgradeEnabled(app)) {
                try writeUpgradeNotice(app, .neutral, "auto-upgrade is disabled");
                return .not_ready;
            }

            if (comptime @hasField(App, "upgrader")) {
                if (app.upgrader.getState() != auto_upgrade.State.ready) {
                    try writeUpgradeNotice(app, .neutral, "no installed upgrade is ready");
                    return .not_ready;
                }
            }

            app.prepareResumeHandoffForUpgrade() catch |err| {
                const notice = try app.alloc.print(
                    "upgrade paused because this conversation is not safely resumable: {s}; run `fx doctor` for recovery guidance",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try writeUpgradeNotice(app, .@"error", notice);
                return .unavailable;
            };

            var executable_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const executable_path = deps.current_executable_path(
                deps.ctx,
                &executable_buf,
            ) catch |err| {
                const notice = try app.alloc.print(
                    "upgrade installed, but the executable path could not be resolved: {s}; restart fx manually",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try writeUpgradeNotice(app, .@"error", notice);
                return .unavailable;
            };

            app.requestUpgradeRelaunch(executable_path) catch |err| {
                const notice = try app.alloc.print(
                    "upgrade installed, but relaunch could not be prepared: {s}; restart fx manually",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try writeUpgradeNotice(app, .@"error", notice);
                return .unavailable;
            };
            app.requestResumeHandoffForUpgrade();
            if (comptime @hasField(App, "should_exit")) app.should_exit = true;
            return .relaunch_requested;
        }

        fn upgradeUnavailableNotice(app: *App) ?[]const u8 {
            if (comptime @hasField(App, "stream")) {
                if (app.stream.active) return "upgrade is unavailable until the response finishes";
            }
            if (comptime @hasField(App, "worker")) {
                if (comptime @hasDecl(@TypeOf(app.worker), "queuedPromptCount")) {
                    if (app.worker.queuedPromptCount() > 0) {
                        return "upgrade is unavailable while prompts are queued";
                    }
                }
            }
            if (comptime @hasField(App, "question_prompt")) {
                if (app.question_prompt.isActive()) return "upgrade is unavailable while a question is open";
            }
            if (comptime @hasField(App, "approval_prompt")) {
                if (app.approval_prompt.isActive()) return "upgrade is unavailable while an approval is open";
            }
            if (comptime @hasField(App, "subagents")) {
                if (app.subagents.isViewActive()) return "close the subagent view before upgrading";
            }
            if (comptime @hasField(App, "session_persistence")) {
                if (app.session_persistence.session_picker.active) return "close the session picker before upgrading";
            }
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.fullTranscriptScreenActive()) return "close the transcript view before upgrading";
            }
            if (comptime @hasField(App, "input_runtime")) {
                if (app.input_runtime.paste.active()) return "finish the paste before upgrading";
                if (app.input_runtime.edit_state.input.items.len > 0) return "submit or clear the current prompt before upgrading";
            }
            if (comptime @hasField(App, "pending_images")) {
                if (app.pending_images.items.len > 0) return "submit or clear pending images before upgrading";
            }
            if (comptime @hasField(App, "terminal_input_runtime")) {
                if (app.terminal_input_runtime.hasPendingTerminalAction()) return "finish the key sequence before upgrading";
            }
            return null;
        }

        fn autoUpgradeEnabled(app: *const App) bool {
            if (comptime @hasField(App, "auto_upgrade_enabled")) {
                return app.auto_upgrade_enabled;
            }
            return true;
        }

        fn writeUpgradeNotice(app: *App, tone: types.NoticeTone, body: []const u8) !void {
            try app.writeDomainNotice(.{
                .topic = "upgrade",
                .tone = tone,
                .body = body,
            }, true);
            requestFooterRender(app);
        }

        fn requestFooterRender(app: *App) void {
            if (comptime @hasField(App, "shell")) app.shell.render_requests.request(.footer);
        }
    };
}

fn currentExecutablePathDefault(
    _: ?*anyopaque,
    executable_buf: []u8,
) upgrade_helpers.ExecutablePathError![]const u8 {
    return upgrade_helpers.currentExecutablePath(executable_buf);
}

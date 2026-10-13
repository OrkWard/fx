const std = @import("std");
const app_session_runtime = @import("app_session_runtime.zig");
const app_lifecycle = @import("app_lifecycle.zig");
const app_bootstrap_runtime = @import("app_bootstrap_runtime.zig");
const io_mod = @import("../shared/io.zig");
const shell_snapshot = @import("../terminal/shell_snapshot.zig");
const command_router = @import("../slash_commands/command_router.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const settings_catalog = @import("../config/settings_catalog.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const feedback_runtime = @import("../feedback/runtime.zig");
const output_contracts = @import("../output/output_contracts.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const workspace_commands = @import("../workspace/workspace_commands.zig");
const image_commands = @import("../images/image_commands.zig");
const provider_runtime = @import("provider_runtime.zig");
const permissions = @import("../permissions/permissions.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const skill_commands = @import("../skills/skill_commands.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const display_width = @import("../shared/display_width.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");
const session_commands = @import("../session/session_commands.zig");
const usage_recovery = @import("../session/usage_recovery.zig");
const usage_dashboard_runtime = @import("usage_dashboard_runtime.zig");
const usage_report = @import("../session/usage_report.zig");
const types = @import("../shared/types.zig");
const assistant_presentation = @import("../agent/assistant_presentation.zig");
const transcript_blocks = @import("../../ui/render_engine/transcript_blocks.zig");

fn finish_trace_notice(app: anytype, entry_id: u32, tone: types.NoticeTone, body: []const u8) !void {
    const notice: types.SemanticNotice = .{
        .topic = "",
        .tone = tone,
        .body = body,
    };
    if (!try app.replaceDomainNotice(entry_id, notice)) {
        _ = try app.appendDomainNotice(notice);
    }
    app.shell.render_requests.request(.transcript);
}

const TraceReportDisposition = union(enum) {
    copied_file: []const u8,
    copy_failed: []const u8,
    saved: []const u8,
    unavailable,
};

/// Returns an owned trace notice whose bytes belong to the caller.
fn format_trace_notice(
    alloc: std.mem.Allocator,
    disposition: TraceReportDisposition,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    switch (disposition) {
        .copied_file => try out.writer.writeAll("Trace copied to clipboard. Review and redact it before sharing."),
        .copy_failed => |path| try out.writer.print("Clipboard copy failed. Trace saved at {s}. Review and redact it before sharing.", .{path}),
        .saved => |path| try out.writer.print("Trace saved at {s}. Review and redact it before sharing.", .{path}),
        .unavailable => try out.writer.writeAll("Could not create trace."),
    }
    return out.toOwnedSlice();
}

fn persistUserPreferences(
    app: anytype,
    label: []const u8,
    patch: config_runtime.UserSettingsPatch,
    runtime_changed: bool,
) !void {
    var attempt = config_runtime.attemptUserPreferences(app.alloc, patch);
    defer attempt.deinit(app.alloc);
    switch (attempt) {
        .failure => |failure| try session_commands.reportUserSettingsFailure(
            app,
            label,
            failure.err,
            failure.cleanup,
            runtime_changed,
        ),
        .outcome => |outcome| _ = try session_commands.reportUserSettingsCommit(
            app,
            label,
            patch,
            outcome,
            null,
            true,
        ),
    }
}

fn clearSessionForClearCommand(app: anytype) !void {
    try app.clearSession();
}

noinline fn parseWorkspaceCommand(rest: []const u8) !?workspace_commands.Action {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "list")) return null;
    if (std.mem.eql(u8, trimmed, "clear")) return .clear;
    if (std.mem.startsWith(u8, trimmed, "add") and trimmed.len > "add".len and
        std.ascii.isWhitespace(trimmed["add".len]))
    {
        const path = std.mem.trim(u8, trimmed["add".len..], " \t");
        if (path.len == 0) return error.InvalidWorkspaceCommand;
        return .{ .add = path };
    }
    if (std.mem.startsWith(u8, trimmed, "remove") and trimmed.len > "remove".len and
        std.ascii.isWhitespace(trimmed["remove".len]))
    {
        const path = std.mem.trim(u8, trimmed["remove".len..], " \t");
        if (path.len == 0) return error.InvalidWorkspaceCommand;
        return .{ .remove = path };
    }
    return error.InvalidWorkspaceCommand;
}

noinline fn tryBeginWorkspaceMutation(app: anytype) bool {
    if (app.stream.active) return false;
    return app.worker.tryHoldTurnStart();
}

fn refreshWorkspaceAvailabilityForList(app: anytype) !void {
    if (!tryBeginWorkspaceMutation(app)) return;
    defer app.worker.releaseTurnStartHold();
    if (comptime @hasDecl(@TypeOf(app.*), "refreshWorkspaceAccess")) {
        _ = try app.refreshWorkspaceAccess();
    }
}

fn handleShellCommand(app: anytype, rest: []const u8) !void {
    if (!std.mem.eql(u8, std.mem.trim(u8, rest, " \t"), "reload")) {
        try app.writeDomainNotice(.{ .topic = "", .tone = .@"error", .body = "usage: /shell reload" }, true);
        return;
    }
    shell_snapshot.processOwner().markDirty(.user_reload);
    try app.writeDomainNotice(.{
        .topic = "shell",
        .tone = .neutral,
        .body = "The next command reloads your shell startup files. Remembered command approvals were reset.",
    }, true);
}

fn handleWorkspaceCommand(app: anytype, rest: []const u8) !void {
    const maybe_action = parseWorkspaceCommand(rest) catch {
        try app.writeDomainNotice(.{
            .topic = "",
            .tone = .@"error",
            .body = "usage: /workspace [add PATH|remove PATH|clear]",
        }, true);
        return;
    };
    const action = maybe_action orelse {
        refreshWorkspaceAvailabilityForList(app) catch |err| {
            const reason = output_contracts.workspaceErrorMessage(err) orelse "workspace refresh failed";
            const message = try app.alloc.print("Workspace refresh rejected: {s}", .{reason});
            defer app.alloc.free(message);
            try app.writeDomainNotice(.{
                .topic = "workspace",
                .tone = .@"error",
                .body = message,
            }, true);
            return;
        };
        return writeWorkspaceSnapshot(app, null);
    };

    if (!tryBeginWorkspaceMutation(app)) {
        try app.writeDomainNotice(.{
            .topic = "workspace",
            .tone = .neutral,
            .body = "Workspace changes are unavailable until the active and queued work finishes.",
        }, true);
        return;
    }
    defer app.worker.releaseTurnStartHold();

    var failure_phase: workspace_commands.FailurePhase = .stage;
    var result = workspace_commands.execute(
        app.alloc,
        app.workspace_root,
        app.workspaceAccess(),
        action,
        &failure_phase,
    ) catch |err| {
        const reason = output_contracts.workspaceErrorMessage(err) orelse "workspace update failed";
        const prefix: []const u8 = switch (failure_phase) {
            .stage => "Workspace update rejected",
            .commit => "Workspace settings were not changed",
            .reconcile => "Workspace settings are uncertain and could not be reloaded",
        };
        const message = try app.alloc.print("{s}: {s}", .{ prefix, reason });
        defer app.alloc.free(message);
        try app.writeDomainNotice(.{
            .topic = "workspace",
            .tone = .@"error",
            .body = message,
        }, true);
        return;
    };
    defer result.deinit(app.alloc);

    switch (result) {
        .updated => |*updated| {
            _ = app.installWorkspaceAccess(&updated.access);
            try writeWorkspaceSnapshot(app, updated.mutation);
        },
        .indeterminate => |*reconciliation| {
            const message: []const u8 = switch (reconciliation.*) {
                .intended => |*reconciled| blk: {
                    _ = app.installWorkspaceAccess(reconciled);
                    break :blk "Workspace settings durability is uncertain; reloaded settings match the requested update.";
                },
                .previous => |*reconciled| blk: {
                    _ = app.installWorkspaceAccess(reconciled);
                    break :blk "Workspace settings durability is uncertain; reloaded settings match the previous state, so the update is not active.";
                },
                .unconfirmed => "Workspace settings durability is uncertain; reloaded settings match neither the requested nor previous state, so runtime access is unchanged.",
            };
            try app.writeDomainNotice(.{
                .topic = "workspace",
                .tone = .warning,
                .body = message,
            }, true);
        },
    }
}

fn writeWorkspaceSnapshot(
    app: anytype,
    mutation: ?workspace_commands.Mutation,
) !void {
    var snapshot = output_contracts.WorkspaceSnapshot.fromAccess(app.workspace_root, app.workspaceAccess());
    snapshot.mutation = mutation;
    const body = try snapshot.renderInteractiveBody(app.alloc);
    defer app.alloc.free(body);
    try app.writeDomainNotice(.{
        .topic = "workspace",
        .tone = .neutral,
        .body = body,
    }, true);
}

fn requestResumeExit(app: anytype) void {
    const App = @TypeOf(app.*);
    app_session_runtime.Runtime(App).requestResumeHandoff(app);
    app.should_exit = true;
}

pub fn Handlers(comptime App: type) type {
    return struct {
        pub fn route(app: *App, cmd: []const u8) !void {
            const handlers = commandHandlers(app);
            try command_router.route(app.slashRegistry(), &handlers, cmd);
        }

        pub fn commandHandlers(app: *App) command_router.CommandHandlers {
            return .{
                .ctx = @ptrCast(app),
                .quit = commandQuit,
                .clear_screen = commandClearScreen,
                .new_session = commandNewSession,
                .reset_session = commandResetSession,
                .resume_session = commandResumeSession,

                .show_help = commandShowHelp,
                .login = commandLogin,
                .logout = commandLogout,
                .provider = commandProvider,
                .show_status = commandShowStatus,
                .attach_image = commandAttachImage,
                .manage_images = commandManageImages,
                .handle_model = commandHandleModel,
                .handle_permissions = commandHandlePermissions,
                .handle_allowlist = commandHandleAllowlist,
                .show_stats = commandShowStats,
                .show_usage = commandShowUsage,
                .undo_last = commandUndoLast,
                .handle_skills = commandHandleSkills,
                .copy_last = commandCopyLast,
                .submit_feedback = commandSubmitFeedback,
                .create_trace = commandCreateTrace,
                .compact_history = commandCompactHistory,
                .handle_settings = commandHandleSettings,
                .handle_alias = commandHandleAlias,
                .paste_clipboard = commandPasteClipboard,
                .toggle_fast = commandToggleFast,
                .handle_statusline = commandHandleStatusline,
                .rename_session = commandRenameSession,
                .handle_notifications = commandHandleNotifications,
                .handle_workspace = commandHandleWorkspace,
                .handle_shell = commandHandleShell,
                .show_version = commandShowVersion,
                .unknown = commandUnknown,
            };
        }

        pub fn collectShellSnapshotFacts(app: *App) !void {
            var buffer: [shell_snapshot.max_notice_bytes]u8 = undefined;
            const notice = shell_snapshot.processOwner().takeUiNotice(&buffer) orelse return;
            try app.writeDomainNotice(.{ .topic = "shell", .tone = .warning, .body = notice }, true);
        }

        fn handleFeedback(app: *App) !void {
            try app.flushBeforeBlockingExternalWork();
            const opened = if (comptime @hasDecl(App, "urlOpener"))
                app.urlOpener().open(app.alloc, feedback_runtime.url) catch false
            else
                false;
            if (opened) {
                try app.writeDomainNotice(.{
                    .topic = "",
                    .tone = .neutral,
                    .body = "Opened https://fx.sh/feedback.",
                }, true);
                return;
            }
            try app.writeDomainNotice(.{
                .topic = "",
                .tone = .@"error",
                .body = "Could not open https://fx.sh/feedback. Open it manually.",
            }, true);
        }

        fn handleTraceReport(app: *App) !void {
            const progress_entry_id = try app.appendReplaceableDomainNotice(.{
                .topic = "",
                .tone = .neutral,
                .body = "Preparing trace...",
            });
            app.shell.render_requests.request(.transcript);
            try app.flushBeforeBlockingExternalWork();

            const report = buildTraceReport(app) catch {
                try finish_trace_notice(app, progress_entry_id, .@"error", "Failed to build trace.");
                return;
            };
            defer app.alloc.free(report);

            const builtin = @import("builtin");
            const report_path: ?[]u8 = writeTraceReportFile(app.alloc, report) catch null;
            defer if (report_path) |path| app.alloc.free(path);
            const disposition: TraceReportDisposition = if (report_path) |path| blk: {
                const copied = if (comptime @hasDecl(App, "clipboard"))
                    app.clipboard().copy_file(app.alloc, path) catch false
                else
                    false;
                if (copied) break :blk .{ .copied_file = path };
                if (builtin.target.os.tag == .macos) break :blk .{ .copy_failed = path };
                break :blk .{ .saved = path };
            } else blk: {
                break :blk .unavailable;
            };
            const body = try format_trace_notice(app.alloc, disposition);
            defer app.alloc.free(body);
            const tone: types.NoticeTone = switch (disposition) {
                .copied_file, .saved => .neutral,
                .copy_failed, .unavailable => .@"error",
            };
            try finish_trace_notice(app, progress_entry_id, tone, body);
        }

        fn commandQuit(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            requestResumeExit(app);
        }

        fn commandClearScreen(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try clearSessionForClearCommand(app);
        }

        fn commandResetSession(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.resetSession();
        }

        fn commandNewSession(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.newSession();
        }

        fn commandResumeSession(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_session_runtime.Runtime(App).openSessionPicker(app);
        }

        fn commandRenameSession(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleRenameCommand(app, rest);
        }

        fn commandShowHelp(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            app.input_runtime.help_menu.open();
            app.shell.render_requests.request(.footer);
        }

        fn commandLogin(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "runLoginCommand")) {
                try app.runLoginCommand();
            } else {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "login is not available in this runtime",
                }, true);
            }
        }

        fn commandLogout(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "runLogoutCommand")) {
                try app.runLogoutCommand(rest);
            } else {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "logout is not available in this runtime",
                }, true);
            }
        }

        fn commandProvider(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "runProviderCommand")) {
                try app.runProviderCommand();
            } else {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = "provider selection is not available in this runtime",
                }, true);
            }
        }

        fn commandShowStatus(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).showStatus(app);
        }

        fn commandAttachImage(ctx: *anyopaque, path: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try image_commands.Commands(App).attachPath(app, path);
        }

        fn commandManageImages(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try image_commands.Commands(App).managePending(app, rest);
        }

        fn commandHandleModel(ctx: *anyopaque, query: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).handleModel(app, query);
        }

        fn commandHandlePermissions(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (try handlePermissionRuleManagement(app, rest)) return;
            try session_commands.Commands(App).handlePermissions(app, rest);
            if (std.mem.trim(u8, rest, " \t").len == 0) {
                try writeSessionPermissionRules(app);
            }
        }

        fn writeSessionPermissionRules(app: *App) !void {
            if (comptime !@hasField(App, "session") or
                !@hasDecl(@TypeOf(app.session), "snapshotPermissionState"))
            {
                return;
            } else {
                var snapshot = try app.session.snapshotPermissionState(app.alloc);
                defer snapshot.deinit(app.alloc);
                var out: std.Io.Writer.Allocating = .init(app.alloc);
                defer out.deinit();
                if (snapshot.rules.items.len == 0) {
                    try out.writer.writeAll("saved-session permission rules: none");
                } else {
                    try out.writer.print(
                        "saved-session permission rules ({d}):",
                        .{snapshot.rules.items.len},
                    );
                    for (snapshot.rules.items) |rule| {
                        var identity = try text_utils.encodeTerminalSafe(
                            app.alloc,
                            rule.display_identity,
                            session_permission_state.max_display_identity_bytes,
                        );
                        defer identity.deinit(app.alloc);
                        try out.writer.print(
                            "\n{d} {s} {s}",
                            .{ rule.id.value, @tagName(rule.decision), identity.bytes },
                        );
                    }
                }
                try app.writeDomainNotice(.{
                    .topic = "permissions",
                    .tone = .neutral,
                    .body = out.writer.buffered(),
                }, true);
            }
        }

        fn handlePermissionRuleManagement(app: *App, rest: []const u8) !bool {
            if (comptime !@hasField(App, "approval_prompt") or
                !@hasField(App, "session_persistence") or
                !@hasDecl(App, "preparePermissionStateAction"))
            {
                return false;
            } else {
                const trimmed = std.mem.trim(u8, rest, " \t");
                const action = splitPermissionWord(trimmed) orelse return false;
                const remember = std.ascii.eqlIgnoreCase(action.word, "remember");
                const revoke = std.ascii.eqlIgnoreCase(action.word, "revoke");
                if (!remember and !revoke) return false;
                debug_trace.logf("permission", "event=rule_management_begin action={s}", .{action.word});
                if (app_session_runtime.Runtime(App).activeSessionId(app) == null) {
                    try writePermissionManagementNotice(
                        app,
                        .@"error",
                        "saved-session permission rules require an active saved session",
                    );
                    return true;
                }
                debug_trace.logf("permission", "event=rule_management_session_ready", .{});
                if (app.approval_prompt.isActive()) {
                    try writePermissionManagementNotice(
                        app,
                        .warning,
                        "finish the active permission prompt before managing saved-session rules",
                    );
                    return true;
                }

                debug_trace.logf("permission", "event=rule_management_snapshot_start", .{});
                var snapshot = try app.session.snapshotPermissionState(app.alloc);
                defer snapshot.deinit(app.alloc);
                debug_trace.logf("permission", "event=rule_management_snapshot_done rules={d}", .{snapshot.rules.items.len});
                if (remember) {
                    const decision_word = splitPermissionWord(action.rest) orelse {
                        try writePermissionManagementUsage(app);
                        return true;
                    };
                    const decision: session_permission_state.Decision =
                        if (std.ascii.eqlIgnoreCase(decision_word.word, "allow"))
                            .allow
                        else if (std.ascii.eqlIgnoreCase(decision_word.word, "deny"))
                            .deny
                        else {
                            try writePermissionManagementUsage(app);
                            return true;
                        };
                    const tool_word = splitPermissionWord(decision_word.rest) orelse {
                        try writePermissionManagementUsage(app);
                        return true;
                    };
                    if (tool_word.rest.len == 0) {
                        try writePermissionManagementUsage(app);
                        return true;
                    }
                    var arena_state = std.heap.ArenaAllocator.init(app.alloc);
                    defer arena_state.deinit();
                    debug_trace.logf("permission", "event=rule_management_prepare_start tool={s}", .{tool_word.word});
                    const prepared = app.preparePermissionStateAction(
                        arena_state.allocator(),
                        .{
                            .id = "permission-rule-management",
                            .name = tool_word.word,
                            .arguments_json = tool_word.rest,
                        },
                    ) catch {
                        try writePermissionManagementNotice(
                            app,
                            .@"error",
                            "could not prepare that exact permission action without executing it",
                        );
                        return true;
                    };
                    debug_trace.logf("permission", "event=rule_management_prepare_done kind={s}", .{@tagName(prepared.key.kind)});
                    const existing = session_permission_state.ruleForKey(
                        snapshot,
                        prepared.key,
                    );
                    try app.approval_prompt.syncRuleManagement(
                        app.alloc,
                        .{
                            .id = debug_trace.nextStepId(),
                            .label = if (decision == .allow)
                                "Remember allow for this saved session"
                            else
                                "Remember deny for this saved session",
                            .explanation = if (existing == null)
                                "Confirm this exact saved-session permission rule. The action will not run."
                            else
                                "Confirm replacement of the existing exact saved-session rule. The action will not run.",
                            .command = prepared.display_identity,
                            .amendment_allowed = false,
                            .confirmation_only = true,
                        },
                        .{ .set = .{
                            .key = prepared.key,
                            .display_identity = prepared.display_identity,
                            .decision = decision,
                            .expected_generation = if (existing) |rule|
                                rule.generation
                            else
                                null,
                        } },
                    );
                    debug_trace.logf("permission", "event=rule_management_prompt_published", .{});
                    app.shell.render_requests.request(.footer);
                    return true;
                }

                const id_word = splitPermissionWord(action.rest) orelse {
                    try writePermissionManagementUsage(app);
                    return true;
                };
                if (id_word.rest.len != 0) {
                    try writePermissionManagementUsage(app);
                    return true;
                }
                const raw_id = std.fmt.parseUnsigned(u64, id_word.word, 10) catch {
                    try writePermissionManagementUsage(app);
                    return true;
                };
                const rule = session_permission_state.ruleForId(
                    snapshot,
                    .{ .value = raw_id },
                ) orelse {
                    try writePermissionManagementNotice(
                        app,
                        .warning,
                        "saved-session permission rule not found",
                    );
                    return true;
                };
                try app.approval_prompt.syncRuleManagement(
                    app.alloc,
                    .{
                        .id = debug_trace.nextStepId(),
                        .label = "Revoke saved-session permission rule",
                        .explanation = "Confirm revocation of this stored rule. No current action will be prepared or run.",
                        .command = rule.display_identity,
                        .amendment_allowed = false,
                        .confirmation_only = true,
                    },
                    .{ .revoke = .{
                        .id = rule.id,
                        .expected_generation = rule.generation,
                    } },
                );
                app.shell.render_requests.request(.footer);
                return true;
            }
        }

        const PermissionWord = struct {
            word: []const u8,
            rest: []const u8,
        };

        fn splitPermissionWord(value: []const u8) ?PermissionWord {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len == 0) return null;
            const end = std.mem.findAny(u8, trimmed, " \t") orelse trimmed.len;
            return .{
                .word = trimmed[0..end],
                .rest = std.mem.trim(u8, trimmed[end..], " \t"),
            };
        }

        fn writePermissionManagementUsage(app: *App) !void {
            // Usage lines name the command; a topic tag would repeat it.
            try app.writeDomainNotice(.{
                .topic = "",
                .tone = .@"error",
                .body = "usage: /permissions remember <allow|deny> <tool-name> <arguments-json>\n       /permissions revoke <rule-id>",
            }, true);
        }

        fn writePermissionManagementNotice(
            app: *App,
            tone: types.NoticeTone,
            body: []const u8,
        ) !void {
            try app.writeDomainNotice(.{
                .topic = "permissions",
                .tone = tone,
                .body = body,
            }, true);
        }

        fn commandHandleAllowlist(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).handleAllowlist(app, rest);
        }

        fn commandShowStats(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var buf: [256]u8 = undefined;
            const body = try std.mem.print(
                &buf,
                "ansi_bytes={d}, redraws={d}, debounced_resizes={d}, footer_updates={d}, stream_chunks={d}",
                .{ app.metrics.ansi_bytes, app.metrics.full_redraws, app.metrics.debounced_resizes, app.metrics.footer_line_updates, app.metrics.stream_chunks },
            );
            try app.writeDomainNotice(.{
                .topic = "stats",
                .tone = .neutral,
                .body = body,
            }, true);
        }

        fn commandShowUsage(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            closeHelpMenuIfPresent(app);
            app.input_runtime.settings_menu.close();
            closeInlineCommandMenusIfPresent(app);
            if (comptime @hasField(App, "usage_dashboard")) {
                try openUsageDashboard(app, .days_30);
                return;
            }
            var usage = loadUsageSnapshot(app, .days_30) catch |err| {
                debug_trace.logf(
                    "usage",
                    "usage dashboard open failed scope={s} reason={s}",
                    .{ @tagName(usage_report.Scope.days_30), @errorName(err) },
                );
                try app.input_runtime.usage_menu.openError(
                    app.alloc,
                    .days_30,
                    "Local usage data is unavailable",
                );
                app.shell.render_requests.request(.footer);
                return;
            };
            errdefer usage.deinit(app.alloc);
            app.input_runtime.usage_menu.openOwned(app.alloc, usage);
            app.shell.render_requests.request(.footer);
        }

        pub fn refreshUsageMenu(
            app: *App,
            scope: usage_report.Scope,
        ) !void {
            if (comptime @hasField(App, "usage_dashboard")) {
                if (scope == .session) {
                    var usage = loadUsageSnapshot(app, scope) catch |err| {
                        try recordUsageRefreshFailure(app, scope, err);
                        return;
                    };
                    errdefer usage.deinit(app.alloc);
                    installUsageSnapshot(app, usage);
                    return;
                }
                if (try app.usage_dashboard.snapshot(app.alloc, scope)) |usage| {
                    installUsageSnapshot(app, usage);
                    return;
                }
                app.input_runtime.usage_menu.setLoadingScope(app.alloc, scope);
                try requestUsageDashboardRefresh(app);
                app.shell.render_requests.request(.footer);
                return;
            }
            var usage = loadUsageSnapshot(app, scope) catch |err| {
                try recordUsageRefreshFailure(app, scope, err);
                return;
            };
            errdefer usage.deinit(app.alloc);
            installUsageSnapshot(app, usage);
        }

        pub fn reloadUsageMenu(
            app: *App,
            scope: usage_report.Scope,
        ) !void {
            if (comptime !@hasField(App, "usage_dashboard")) {
                try refreshUsageMenu(app, scope);
                return;
            }
            if (scope == .session) {
                try refreshUsageMenu(app, scope);
                return;
            }
            app.input_runtime.usage_menu.requested_scope = scope;
            requestUsageDashboardRefresh(app) catch |err| {
                try recordUsageRefreshFailure(app, scope, err);
                return;
            };
            app.shell.render_requests.request(.footer);
        }

        pub fn collectUsageDashboardFacts(app: *App) !bool {
            if (comptime !@hasField(App, "usage_dashboard")) return false;
            const transition = app.usage_dashboard.pollTransition();
            if (transition == .none) return false;
            if (!app.input_runtime.usage_menu.active or
                app.input_runtime.usage_menu.navigationScope() == .session)
            {
                return false;
            }
            const scope = app.input_runtime.usage_menu.navigationScope();
            if (transition == .failed) {
                const err = app.usage_dashboard.lastError() orelse
                    error.ProfileUsageUnavailable;
                try recordUsageRefreshFailure(app, scope, err);
                return true;
            }
            if (try app.usage_dashboard.snapshot(app.alloc, scope)) |usage| {
                installUsageSnapshot(app, usage);
                return true;
            }
            const err = app.usage_dashboard.lastError() orelse
                error.ProfileUsageUnavailable;
            try recordUsageRefreshFailure(app, scope, err);
            return true;
        }

        fn openUsageDashboard(
            app: *App,
            scope: usage_report.Scope,
        ) !void {
            const cached = try app.usage_dashboard.snapshot(app.alloc, scope);
            if (cached) |usage| {
                app.input_runtime.usage_menu.openOwned(app.alloc, usage);
            } else {
                app.input_runtime.usage_menu.openLoading(app.alloc, scope);
            }
            requestUsageDashboardRefresh(app) catch |err| {
                try recordUsageRefreshFailure(app, scope, err);
                return;
            };
            app.shell.render_requests.request(.footer);
        }

        fn requestUsageDashboardRefresh(app: *App) !void {
            const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
            const availability = try app.session.ensureProfileUsageReadable(
                app.alloc,
                home,
            );
            if (availability == .unavailable) {
                return app.session.profile_usage.lastError() orelse
                    error.ProfileUsageUnavailable;
            }
            _ = try app.usage_dashboard.requestRefresh(
                usage_dashboard_runtime.profileProvider(
                    &app.session.profile_usage,
                ),
                home,
                @max(io_mod.milliTimestamp(), 0),
            );
        }

        fn installUsageSnapshot(
            app: *App,
            usage: usage_report.Snapshot,
        ) void {
            if (app.input_runtime.usage_menu.active) {
                app.input_runtime.usage_menu.replaceOwned(app.alloc, usage);
            } else {
                app.input_runtime.usage_menu.openOwned(app.alloc, usage);
            }
            app.shell.render_requests.request(.footer);
        }

        fn recordUsageRefreshFailure(
            app: *App,
            scope: usage_report.Scope,
            err: anyerror,
        ) !void {
            debug_trace.logf(
                "usage",
                "usage dashboard refresh failed scope={s} reason={s}",
                .{ @tagName(scope), @errorName(err) },
            );
            try app.input_runtime.usage_menu.recordRefreshFailure(
                app.alloc,
                scope,
                "Local usage data is unavailable",
            );
            app.shell.render_requests.request(.footer);
        }

        fn loadUsageSnapshot(
            app: *App,
            scope: usage_report.Scope,
        ) !usage_report.Snapshot {
            if (scope == .session) {
                return app.session.usage.reportSnapshot(app.alloc);
            }
            const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
            const availability = try app.session.ensureProfileUsageReadable(
                app.alloc,
                home,
            );
            if (availability == .unavailable) {
                return app.session.profile_usage.lastError() orelse
                    error.ProfileUsageUnavailable;
            }
            const snapshot_time_ms = @max(io_mod.milliTimestamp(), 0);
            var recovery = try usage_recovery.collectFromHomeConservative(
                app.alloc,
                home,
            );
            defer recovery.deinit(app.alloc);
            return app.session.profile_usage.snapshot(
                app.alloc,
                scope,
                snapshot_time_ms,
                .{
                    .facts = recovery.facts,
                    .incidents = recovery.incidents,
                    .pending = recovery.pending,
                    .unknown_pending = recovery.unknown_pending,
                },
            );
        }

        fn commandUndoLast(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const result = app.change_tracker.undoLast(std.heap.c_allocator);
            const msg = switch (result) {
                .restored => |path| blk: {
                    var display_path = try text_utils.encodeTerminalSafe(
                        app.alloc,
                        path,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer display_path.deinit(app.alloc);
                    break :blk try app.alloc.print("Restored {s}", .{display_path.bytes});
                },
                .deleted => |path| blk: {
                    var display_path = try text_utils.encodeTerminalSafe(
                        app.alloc,
                        path,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer display_path.deinit(app.alloc);
                    break :blk try app.alloc.print("Deleted {s} (was newly created)", .{display_path.bytes});
                },
                .unavailable => |path| blk: {
                    var display_path = try text_utils.encodeTerminalSafe(
                        app.alloc,
                        path,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer display_path.deinit(app.alloc);
                    break :blk try app.alloc.print(
                        "Could not undo {s}",
                        .{display_path.bytes},
                    );
                },
                .empty => try app.alloc.dupe(u8, "Nothing to undo."),
            };
            defer app.alloc.free(msg);
            switch (result) {
                .restored => |path| std.heap.c_allocator.free(path),
                .deleted => |path| std.heap.c_allocator.free(path),
                .unavailable => |path| std.heap.c_allocator.free(path),
                .empty => {},
            }
            try app.writeDomainNotice(.{
                .topic = "undo",
                .tone = .neutral,
                .body = msg,
            }, true);
        }

        noinline fn commandHandleSkills(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const provider = app.skillsCommandProvider();
            const command = provider.parseCommand(rest);

            if (comptime @hasDecl(App, "requestSkillsRefresh")) switch (command) {
                .list => {
                    const generation = try app.requestSkillsRefresh();
                    try app.skills.queueRefreshAction(app.alloc, generation, .list);
                    try collectSkillsRefreshFacts(app);
                    return;
                },
                .show => |name| {
                    const generation = try app.requestSkillsRefresh();
                    try app.skills.queueRefreshAction(
                        app.alloc,
                        generation,
                        .{ .show = name },
                    );
                    try collectSkillsRefreshFacts(app);
                    return;
                },
                .install, .create, .remove, .path, .usage => {},
            };
            try executeSkillsCommand(app, provider, command);
            try collectSkillsRefreshFacts(app);
        }

        pub fn collectSkillsRefreshFacts(app: *App) !void {
            var ready = app.skills.takeReadyRefreshAction() orelse return;
            defer ready.deinit(app.alloc);
            if (!ready.succeeded) {
                try app.writeDomainNotice(.{
                    .topic = "skills",
                    .tone = .@"error",
                    .body = if (ready.action == .startup_notice)
                        "Skills could not be loaded. Run /skills to try again."
                    else
                        "Skills could not be refreshed. The previous catalog was not shown as current.",
                }, true);
                return;
            }
            switch (ready.action) {
                .startup_notice => try app_bootstrap_runtime.Runtime(App).writeSkillDiagnosticsNotice(app),
                .list => try executeSkillsCommand(
                    app,
                    app.skillsCommandProvider(),
                    .list,
                ),
                .show => |name| try executeSkillsCommand(
                    app,
                    app.skillsCommandProvider(),
                    .{ .show = name },
                ),
                .notice => |body| try app.writeDomainNotice(.{
                    .topic = noticeTopicForBody("skills", body),
                    .tone = .neutral,
                    .body = body,
                }, true),
            }
        }

        fn executeSkillsCommand(
            app: *App,
            provider: skill_commands.Provider,
            command: skill_commands.Command,
        ) !void {
            try writeSkillDiagnosticNotice(app);

            switch (command) {
                .install => |install| {
                    const install_notice = try app.alloc.print("Installing from {s}...", .{install.source});
                    defer app.alloc.free(install_notice);
                    try app.writeDomainNotice(.{
                        .topic = "skills",
                        .tone = .neutral,
                        .body = install_notice,
                    }, true);
                },
                .show => |name| switch (skill_runtime.resolveSkill(app.skills.items, name, null)) {
                    .ambiguous_name => {
                        closeModelMenuIfPresent(app);
                        closeHelpMenuIfPresent(app);
                        try app.input_runtime.textReplacementState().replace(app.alloc, name);
                        app.skills.openMenuWithQuery(.command, null, name);
                        app.shell.render_requests.request(.footer);
                        return;
                    },
                    .found, .not_found, .name_location_mismatch => {},
                },
                else => {},
            }

            var result = try provider.executeCommand(app.alloc, command, .{
                .skills_dir = app.skills.dir,
                .find_ctx = @ptrCast(app),
                .find_skill = findSkillForProvider,
            });
            defer result.deinit(app.alloc);

            try applySkillsCommandResult(app, &result);
        }

        /// Usage lines name the command; a topic tag would repeat it.
        fn noticeTopicForBody(comptime default: []const u8, body: []const u8) []const u8 {
            return if (std.mem.startsWith(u8, body, "usage:")) "" else default;
        }

        fn findSkillForProvider(ctx: *anyopaque, name: []const u8) ?skill_commands.SkillInfo {
            const app: *App = @ptrCast(@alignCast(ctx));
            var fallback: ?skill_runtime.Skill = null;
            for (app.skills.items) |skill| {
                if (!std.mem.eql(u8, skill.name, name)) continue;
                if (skill_runtime.isManagedInstallSkill(skill)) return skillInfoForProvider(skill);
                if (fallback == null) fallback = skill;
            }
            const skill = fallback orelse return null;
            return skillInfoForProvider(skill);
        }

        fn skillInfoForProvider(skill: skill_runtime.Skill) skill_commands.SkillInfo {
            return .{
                .path = skill.path,
                .source_label = skill_runtime.skillSourceLabel(skill.source),
                .managed_install = skill_runtime.isManagedInstallSkill(skill),
            };
        }

        fn writeSkillDiagnosticNotice(app: *App) !void {
            if (app.skills.diagnostics.len == 0) return;

            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try skill_runtime.writeDiagnosticSummary(app.alloc, &out.writer, app.skills.diagnostics);
            const body = try out.toOwnedSlice();
            defer app.alloc.free(body);
            if (comptime @hasField(App, "session") and @hasDecl(@TypeOf(app.session), "claimContextNotice")) {
                _ = try app.session.claimContextNotice(app.alloc, body);
            }
            try app.writeDomainNotice(.{
                .topic = "skills",
                .tone = .warning,
                .body = body,
            }, true);
        }

        fn applySkillsCommandResult(app: *App, result: *const skill_commands.CommandResult) !void {
            switch (result.*) {
                .open_menu => {
                    closeModelMenuIfPresent(app);
                    closeHelpMenuIfPresent(app);
                    app.skills.openMenu();
                    app.shell.render_requests.request(.footer);
                },
                .focus_menu => |name| {
                    closeModelMenuIfPresent(app);
                    closeHelpMenuIfPresent(app);
                    if (app.skills.openMenuFocusedByName(name)) {
                        app.shell.render_requests.request(.footer);
                    }
                },
                .notice => |notice| {
                    if (notice.reload and comptime @hasDecl(App, "requestSkillsRefresh")) {
                        try queueSkillsNoticeAfterRefresh(app, notice.text);
                    } else {
                        try app.writeDomainNotice(.{
                            .topic = noticeTopicForBody("skills", notice.text),
                            .tone = .neutral,
                            .body = notice.text,
                        }, true);
                    }
                },
                .installed => |install_result| {
                    var installed_notice: std.Io.Writer.Allocating = .init(app.alloc);
                    defer installed_notice.deinit();

                    for (install_result.installed.items) |name| {
                        try installed_notice.writer.print("Installed: {s}\n", .{name});
                    }

                    const msg = try installed_notice.toOwnedSlice();
                    defer app.alloc.free(msg);
                    if (comptime @hasDecl(App, "requestSkillsRefresh")) {
                        try queueSkillsNoticeAfterRefresh(
                            app,
                            std.mem.trimEnd(u8, msg, "\n"),
                        );
                    } else {
                        try app.writeDomainNotice(.{
                            .topic = "skills",
                            .tone = .neutral,
                            .body = std.mem.trimEnd(u8, msg, "\n"),
                        }, true);
                    }
                },
            }
        }

        fn queueSkillsNoticeAfterRefresh(app: *App, body: []const u8) !void {
            const generation = try app.requestSkillsRefresh();
            try app.skills.queueRefreshAction(
                app.alloc,
                generation,
                .{ .notice = body },
            );
        }

        fn closeModelMenuIfPresent(app: *App) void {
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
        }

        noinline fn closeHelpMenuIfPresent(app: *App) void {
            if (comptime @hasField(App, "input_runtime")) {
                if (comptime @hasField(@TypeOf(app.input_runtime), "help_menu")) {
                    app.input_runtime.help_menu.close();
                }
            }
        }

        fn closeInlineCommandMenusIfPresent(app: *App) void {
            if (comptime !@hasField(App, "input_runtime")) return;
            const InputRuntime = @TypeOf(app.input_runtime);
            if (comptime @hasField(InputRuntime, "statusline_menu")) app.input_runtime.statusline_menu.close();
            if (comptime @hasField(InputRuntime, "usage_menu")) app.input_runtime.usage_menu.close(app.alloc);
            if (comptime @hasField(InputRuntime, "workspace_menu")) app.input_runtime.workspace_menu.close();
        }

        fn commandCopyLast(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const last_reply = app.session.lastAssistantReply() orelse {
                try app.writeDomainNotice(.{
                    .topic = "clipboard",
                    .tone = .neutral,
                    .body = "No assistant reply to copy.",
                }, true);
                return;
            };
            const copied = app.clipboard().copy(last_reply) catch false;
            if (!copied) {
                try app.writeDomainNotice(.{
                    .topic = "clipboard",
                    .tone = .@"error",
                    .body = "Failed to copy to clipboard.",
                }, true);
                return;
            }
            try app.writeDomainNotice(.{
                .topic = "clipboard",
                .tone = .neutral,
                .body = "Copied to clipboard.",
            }, true);
        }

        fn commandSubmitFeedback(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleFeedback(app);
        }

        fn commandCreateTrace(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleTraceReport(app);
        }

        fn commandCompactHistory(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "request_context_compaction")) {
                return app.request_context_compaction();
            }
            try app.writeDomainNotice(.{
                .topic = "context",
                .tone = .neutral,
                .body = "No context to compact.",
            }, true);
        }

        fn commandHandleSettings(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (std.mem.trim(u8, rest, " \t").len == 0) {
                var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch {
                    try session_commands.Commands(App).handleSettings(app, rest);
                    return;
                };
                defer settings.deinit(app.alloc);
                if (comptime @hasField(App, "skills")) app.skills.closeMenu();
                if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
                closeHelpMenuIfPresent(app);
                closeInlineCommandMenusIfPresent(app);
                app.input_runtime.settings_menu.openWithStartupScrollback(
                    settings.startup_scrollback orelse true,
                );
                app.shell.render_requests.request(.footer);
                return;
            }
            try session_commands.Commands(App).handleSettings(app, rest);
        }

        fn commandHandleAlias(ctx: *anyopaque, _: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(.{
                .topic = "aliases",
                .tone = .neutral,
                .body = "Aliases are not yet configurable.",
            }, true);
        }

        fn commandPasteClipboard(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try image_commands.Commands(App).attachClipboard(app);
        }

        fn commandToggleFast(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).toggleFast(app);
        }

        fn commandHandleStatusline(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (std.mem.trim(u8, rest, " \t").len == 0) {
                if (comptime @hasField(App, "skills")) app.skills.closeMenu();
                if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
                closeHelpMenuIfPresent(app);
                app.input_runtime.settings_menu.close();
                closeInlineCommandMenusIfPresent(app);
                app.input_runtime.statusline_menu.open();
                app.shell.render_requests.request(.footer);
                return;
            }
            try handleStatuslineCommand(app, rest);
        }

        fn commandHandleNotifications(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleNotificationsCommand(app, rest);
        }

        fn commandHandleShell(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleShellCommand(app, rest);
        }

        fn commandHandleWorkspace(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !@hasDecl(App, "workspaceAccess")) {
                try app.writeDomainNotice(.{
                    .topic = "workspace",
                    .tone = .@"error",
                    .body = "Workspace access is unavailable in this runtime.",
                }, true);
                return;
            }
            if (std.mem.trim(u8, rest, " \t").len == 0) {
                refreshWorkspaceAvailabilityForList(app) catch |err| {
                    const reason = output_contracts.workspaceErrorMessage(err) orelse "workspace refresh failed";
                    const message = try app.alloc.print("Workspace refresh rejected: {s}", .{reason});
                    defer app.alloc.free(message);
                    try app.writeDomainNotice(.{
                        .topic = "workspace",
                        .tone = .@"error",
                        .body = message,
                    }, true);
                    return;
                };
                if (comptime @hasField(App, "skills")) app.skills.closeMenu();
                if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
                closeHelpMenuIfPresent(app);
                app.input_runtime.settings_menu.close();
                closeInlineCommandMenusIfPresent(app);
                app.input_runtime.workspace_menu.open();
                app.shell.render_requests.request(.footer);
                return;
            }
            try handleWorkspaceCommand(app, rest);
        }

        fn commandShowVersion(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(.{
                .topic = "version",
                .tone = .neutral,
                .body = App.app_version,
            }, true);
        }

        fn commandUnknown(ctx: *anyopaque, _: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(.{
                .topic = "command",
                .tone = .@"error",
                .body = "Unknown command. Try /help.",
            }, true);
        }
    };
}

const trace_transcript_max_line_bytes: usize = 300;

fn traceFilePermissions() std.Io.File.Permissions {
    const builtin = @import("builtin");
    return switch (builtin.target.os.tag) {
        .windows => .default_file,
        else => std.Io.File.Permissions.fromMode(0o600),
    };
}

fn writeTraceReportFile(alloc: std.mem.Allocator, contents: []const u8) ![]u8 {
    const tmp_dir = io_mod.getenv("TMPDIR") orelse "/tmp";
    const trimmed = std.mem.trimEnd(u8, tmp_dir, "/");
    const now_ms = io_mod.milliTimestamp();
    const now_secs: i64 = @max(@divFloor(now_ms, 1000), 0);
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_secs) };
    const day_seconds = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var attempts: u8 = 0;
    while (attempts < 8) : (attempts += 1) {
        var random_bytes: [6]u8 = undefined;
        io_mod.getIo().random(&random_bytes);
        const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
        const path = try alloc.print("{s}/fx-trace-{d}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{s}.md", .{
            trimmed,
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            random_hex,
        });
        errdefer alloc.free(path);

        var file = std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
            .truncate = false,
            .exclusive = true,
            .permissions = traceFilePermissions(),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                alloc.free(path);
                continue;
            },
            else => return err,
        };
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), contents);
        try file.sync(io_mod.getIo());

        return path;
    }
    return error.PathAlreadyExists;
}

fn buildTraceReport(app: anytype) ![]u8 {
    const App = @TypeOf(app.*);
    const builtin = @import("builtin");

    var out: std.Io.Writer.Allocating = .init(app.alloc);
    defer out.deinit();

    try out.writer.writeAll("# fx trace\n\n");
    try out.writer.writeAll("Private diagnostic report. It may include prompts, file paths, command output, and file snippets.\n\n");

    try out.writer.writeAll("## Summary\n");
    const now_secs: i64 = @divFloor(io_mod.milliTimestamp(), 1000);
    if (now_secs >= 0) {
        const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_secs) };
        const day_seconds = epoch_secs.getDaySeconds();
        const year_day = epoch_secs.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        try out.writer.print("generated: {d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\n", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
    }
    const build_options = @import("build_options");
    try out.writer.print("version: {s} ({s})\n", .{ App.app_version, build_options.git_commit });
    try out.writer.print("platform: {s}/{s}\n", .{ @tagName(builtin.target.os.tag), @tagName(builtin.target.cpu.arch) });
    try out.writer.print("build: {s}\n", .{switch (builtin.optimize) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    }});
    try out.writer.print("model: {s}\n", .{provider_runtime.model(app)});
    if (app.fast_mode) try out.writer.writeAll("fast_mode: on\n");
    const perm_label = permissions.permissionModeLabel(app.permission_engine.mode);
    try out.writer.print("permission_mode: {s}\n", .{perm_label});
    try out.writer.print("workspace: {s}\n", .{app.workspace_root});

    try writeCurrentStateSummary(&out.writer, app, app.alloc);
    try writeProblemsSummary(&out.writer, app, app.alloc);
    try writeLastShutdownSection(&out.writer, app.alloc);
    try writeCompactionSummary(&out.writer, app.alloc);
    try writeLastInterruptedDetail(&out.writer, app.session.agent.history.items, app.alloc);
    try writeSessionTitleSummary(&out.writer, app, app.alloc);
    try writeNetworkCallsSummary(&out.writer);
    try writeModelCatalogSummary(&out.writer, app);
    try writeToolCallsSummary(&out.writer, app.alloc, app.session.agent.history.items);
    try writePermissionsSummary(&out.writer, app.permission_engine.grants.items);
    try writeRuntimeContextSummary(&out.writer);
    try writeRendererState(&out.writer, app, app.alloc);
    try writeRendererEvents(&out.writer, app.alloc);

    if (app.shell.entries.items.len > 0) {
        try out.writer.writeAll("\n## Transcript Timeline\n");
        try out.writer.writeAll("ansi stripped; only obvious secrets masked\n");
        try writeTranscriptTimeline(&out.writer, app.alloc, app.shell.entries.items);
    } else {
        try out.writer.writeAll("\n## Transcript Timeline\n(empty)\n");
    }

    const trace_path: ?[]const u8 = debug_trace.activeLogPath() orelse io_mod.getenv("FX_TRACE_LOG");
    if (trace_path) |path| {
        try writeTraceLogTail(&out.writer, app.alloc, path);
    }

    return try out.toOwnedSlice();
}

noinline fn writeMaskedInline(writer: *std.Io.Writer, alloc: std.mem.Allocator, text: []const u8) !void {
    const masked = try text_utils.maskSecrets(alloc, text);
    defer if (masked.ptr != text.ptr) alloc.free(masked);
    try writer.writeAll(masked);
}

fn traceToolDisplayName(tool_name: []const u8) []const u8 {
    return if (tool_presentation.isProviderSearchAlias(tool_name))
        "web_search"
    else
        tool_name;
}

fn isTraceToolTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn providerSearchAliasPrefixLen(token: []const u8) ?usize {
    var end: usize = 1;
    while (end <= token.len) : (end += 1) {
        if (!tool_presentation.isProviderSearchAlias(token[0..end])) continue;
        if (end == token.len or token[end] == '_') return end;
    }
    return null;
}

fn writeTraceTextNeutralized(writer: *std.Io.Writer, text: []const u8) !void {
    var token_start: usize = 0;
    var scan_index: usize = 0;
    var written_through: usize = 0;
    while (scan_index < text.len) {
        if (!isTraceToolTokenByte(text[scan_index])) {
            scan_index += 1;
            continue;
        }
        token_start = scan_index;
        while (scan_index < text.len and isTraceToolTokenByte(text[scan_index])) : (scan_index += 1) {}
        const alias_len = providerSearchAliasPrefixLen(text[token_start..scan_index]) orelse continue;
        try writer.writeAll(text[written_through..token_start]);
        try writer.writeAll("web_search");
        written_through = token_start + alias_len;
    }
    try writer.writeAll(text[written_through..]);
}

fn writeCurrentStateSummary(writer: *std.Io.Writer, app: anytype, alloc: std.mem.Allocator) !void {
    const App = @TypeOf(app.*);
    try writer.writeAll("\n## Current State\n");
    if (comptime @hasField(App, "session_persistence")) {
        if (app_session_runtime.Runtime(App).activeSessionId(app)) |id| {
            try writer.print("session_id: {s}\n", .{id});
        }
        const session_dir =
            try app_session_runtime.Runtime(App).activeSessionDisplayPath(
                app,
                alloc,
            );
        if (session_dir) |dir| {
            defer alloc.free(dir);
            try writer.print("session_dir: {s}\n", .{dir});
        }
    }
    if (comptime @hasField(App, "agent_step_limit")) try writer.print("agent_step_limit: {d}\n", .{app.agent_step_limit});
    if (comptime @hasField(App, "effort")) try writer.print("effort: {s}\n", .{app.effort.label()});
    if (comptime @hasField(App, "total_input_tokens") and @hasField(App, "total_output_tokens")) {
        try writer.print("tokens_total: {d}->{d}\n", .{ app.total_input_tokens, app.total_output_tokens });
    }
    if (comptime @hasField(App, "total_web_search_requests")) {
        var usage = try app.session.usage.snapshot(alloc);
        defer usage.deinit(alloc);
        try writeSearchUsageSummary(
            writer,
            app.total_web_search_requests,
            usage.billable_web_search_calls,
        );
    }
    try writeAuthStateSummary(writer, app);
    try writeProcessSummary(writer, alloc);
    if (comptime @hasField(App, "worker")) {
        const snapshot = app.worker.snapshotState(alloc) catch null;
        if (snapshot) |state| {
            defer state.deinit(alloc);
            try writer.print("worker: processing={s} queued={d} cancel={s}\n", .{ boolLabel(state.processing), state.queued_count, boolLabel(state.cancel_requested) });
            if (state.pending_permission_request) |request| {
                try writer.writeAll("pending_permission: ");
                try writeMaskedInline(writer, alloc, request.label);
                try writer.writeByte('\n');
            }
        }
        const pending_questions = app.worker.snapshotPendingQuestionBatch(alloc) catch null;
        if (pending_questions) |questions| {
            defer questions.deinit(alloc);
            try writer.print("pending_questions: {d}\n", .{questions.entries.len});
            for (questions.entries, 0..) |entry, idx| {
                if (idx >= 3) {
                    try writer.print("  ... {d} more pending questions\n", .{questions.entries.len - idx});
                    break;
                }
                try writer.writeAll("  - ");
                try writeMaskedInline(writer, alloc, entry.question);
                try writer.print(" options={d}\n", .{entry.options.len});
            }
        }
    }
    if (comptime @hasField(App, "pending_images")) {
        if (app.pending_images.items.len > 0) {
            try writer.print("pending_images: {d}\n", .{app.pending_images.items.len});
            for (app.pending_images.items, 0..) |image, idx| {
                if (idx >= 3) {
                    try writer.print("  ... {d} more pending images\n", .{app.pending_images.items.len - idx});
                    break;
                }
                try writer.print("  - media={s} path=", .{image.media_type});
                try writeMaskedInline(writer, alloc, image.path);
                try writer.writeByte('\n');
            }
        }
    }
    if (comptime @hasField(App, "context_enabled") and @hasField(App, "context_snapshot")) {
        try writer.print("project_context: enabled={s}", .{boolLabel(app.context_enabled)});
        const context_bytes = app.context_snapshot.modelVisibleBytes();
        if (context_bytes.len > 0) try writer.print(" bytes={d}", .{context_bytes.len}) else try writer.writeAll(" not_loaded");
        try writer.writeByte('\n');
    }
    try writeDebugEnvSummary(writer, alloc);
    if (comptime @hasField(App, "stream")) {
        try writer.print("stream: active={s} chunks={d} reads={d} lists={d} writes={d} edits={d} commands={d} subagents={d}", .{
            boolLabel(app.stream.active),
            app.stream.chunks,
            app.stream.read_count,
            app.stream.list_count,
            app.stream.write_count,
            app.stream.edit_count,
            app.stream.command_count,
            app.stream.subagent_count,
        });
        if (app.stream.last_activity_kind) |kind| try writer.print(" last_activity={s}", .{@tagName(kind)});
        try writer.writeByte('\n');
    }
    try writer.print("terminal: {d} cols x {d} rows\n", .{ app.shell.layout.cols, app.shell.layout.rows });
    try writer.print("metrics: ansi_bytes={d} full_redraws={d} debounced_resizes={d} footer_updates={d} stream_chunks={d}\n", .{
        app.metrics.ansi_bytes,
        app.metrics.full_redraws,
        app.metrics.debounced_resizes,
        app.metrics.footer_line_updates,
        app.metrics.stream_chunks,
    });
}

fn writeProcessSummary(writer: *std.Io.Writer, alloc: std.mem.Allocator) !void {
    const pid = std.c.getpid();
    try writer.print("process: pid={d}", .{pid});
    if (countOpenFileDescriptors()) |fd_count| try writer.print(" open_fds={d}", .{fd_count});
    try writer.writeByte('\n');

    const ps = processMemorySnapshot(alloc, pid) catch null;
    if (ps) |text| {
        defer alloc.free(text);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) {
            try writer.writeAll("process_memory:\n");
            var it = std.mem.splitScalar(u8, trimmed, '\n');
            while (it.next()) |line| {
                try writer.writeAll("  ");
                try writer.writeAll(std.mem.trimEnd(u8, line, " \t\r"));
                try writer.writeByte('\n');
            }
        }
    }
}

fn countOpenFileDescriptors() ?usize {
    const builtin = @import("builtin");
    const fd_dir = switch (builtin.target.os.tag) {
        .linux => "/proc/self/fd",
        .macos => "/dev/fd",
        else => return null,
    };
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), fd_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io_mod.getIo());

    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io_mod.getIo()) catch return null) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        count += 1;
    }
    return count;
}

fn processMemorySnapshot(alloc: std.mem.Allocator, pid: std.c.pid_t) ![]u8 {
    const pid_text = try alloc.print("{d}", .{pid});
    defer alloc.free(pid_text);
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "ps", "-o", "pid,ppid,rss,vsz,etime,stat", "-p", pid_text },
    });
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        alloc.free(result.stdout);
        return error.ProcessSnapshotFailed;
    }
    return result.stdout;
}

fn writeDebugEnvSummary(writer: *std.Io.Writer, alloc: std.mem.Allocator) !void {
    try writer.print("FX_TRACE: {s}\n", .{if (envTruthy("FX_TRACE")) "on" else "off"});
    if (debug_trace.activeLogPath() orelse io_mod.getenv("FX_TRACE_LOG")) |path| {
        try writer.writeAll("trace_log: ");
        try writeMaskedInline(writer, alloc, path);
        try writer.writeByte('\n');
    }
}

fn envTruthy(name: []const u8) bool {
    const raw = io_mod.getenv(name) orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

fn writeAuthStateSummary(writer: *std.Io.Writer, app: anytype) !void {
    const App = @TypeOf(app.*);
    if (comptime !@hasField(App, "auth")) return;

    const auth_view = app.auth.view();
    try writer.print(
        "auth: source={s} refreshable={s}\n",
        .{
            auth_view.activeSourceLabel(),
            boolLabel(auth_view.refreshable),
        },
    );
}

fn writeLastShutdownSection(writer: *std.Io.Writer, alloc: std.mem.Allocator) !void {
    try writer.writeAll("\n## Last Shutdown\n");
    const contents = app_lifecycle.readLastShutdownReport(alloc) orelse {
        try writer.writeAll("(none recorded)\n");
        return;
    };
    defer alloc.free(contents);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, contents, .{}) catch {
        try writer.writeAll("(last shutdown report unreadable)\n");
        return;
    };
    defer parsed.deinit();
    const root = parsed.value.object;
    const total_ms = if (root.get("total_ms")) |value| value.integer else -1;
    try writer.print("total_ms={d}", .{total_ms});
    if (root.get("recorded_at_ms")) |value| {
        if (value.integer >= 0) {
            const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(value.integer, 1000)) };
            const day_seconds = epoch_secs.getDaySeconds();
            const year_day = epoch_secs.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            try writer.print(" recorded={d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
            });
        }
    }
    try writer.writeByte('\n');
    if (root.get("stages")) |stages_value| {
        for (stages_value.array.items) |stage_value| {
            const stage = stage_value.object;
            const name = if (stage.get("name")) |v| v.string else "?";
            const step_ms = if (stage.get("step_ms")) |v| v.integer else -1;
            try writer.print("- {s} step_ms={d}\n", .{ name, step_ms });
        }
    }
}

fn writeProblemsSummary(writer: *std.Io.Writer, app: anytype, alloc: std.mem.Allocator) !void {
    const App = @TypeOf(app.*);
    try writer.writeAll("\n## Problems\n");
    var count: usize = 0;

    const state = app.worker.snapshotState(alloc) catch null;
    if (state) |snapshot| {
        defer snapshot.deinit(alloc);
        if (snapshot.processing or app.stream.active) {
            count += 1;
            try writer.print("- report captured an active turn; state may be partial processing={s} stream_active={s} queued={d}\n", .{ boolLabel(snapshot.processing), boolLabel(app.stream.active), snapshot.queued_count });
        }
    }

    if (lastInterruptedTurn(app.session.agent.history.items)) |entry| {
        count += 1;
        try writer.writeAll("- interrupted turn");
        if (entry.tool_call) |call| try writer.print(" in_flight_tool={s}", .{traceToolDisplayName(call.name)});
        if (entry.completed_tool_names.len > 0) try writer.print(" completed_tools={d}", .{entry.completed_tool_names.len});
        try writer.writeByte('\n');
    }

    if (comptime @hasField(App, "session_persistence")) {
        const Persistence = @TypeOf(app.session_persistence);
        if (comptime @hasField(Persistence, "title_generation")) {
            const TitleGeneration = @TypeOf(app.session_persistence.title_generation);
            if (comptime @hasField(TitleGeneration, "last")) {
                const last = &app.session_persistence.title_generation.last;
                if (last.status == .failed or last.status == .dropped) {
                    count += 1;
                    try writer.print("- session title generation {s}", .{@tagName(last.status)});
                    if (last.reason) |reason| try writer.print(" reason={s}", .{@tagName(reason)});
                    if (last.detail.len > 0) try writer.print(" detail={s}", .{last.detail});
                    try writer.writeByte('\n');
                }
            }
        }
    }

    var network_buf: [diagnostics.network_ring_capacity]diagnostics.NetworkCall = undefined;
    const network_n = diagnostics.snapshotNetworkCalls(&network_buf);
    var network_reported: usize = 0;
    var ni = network_n;
    while (ni > 0 and network_reported < 3) {
        ni -= 1;
        const call = network_buf[ni];
        if (!networkCallIsError(call)) continue;
        count += 1;
        network_reported += 1;
        try writer.writeAll("- network ");
        try writeNetworkCallCompact(writer, call);
    }

    var tool_buf: [diagnostics.tool_call_ring_capacity]diagnostics.ToolCallMetric = undefined;
    const tool_n = diagnostics.snapshotToolCalls(&tool_buf);
    var tool_reported: usize = 0;
    var ti = tool_n;
    while (ti > 0 and tool_reported < 5) {
        ti -= 1;
        const call = tool_buf[ti];
        if (call.outcome == .succeeded) continue;
        count += 1;
        tool_reported += 1;
        try writer.writeAll("- tool ");
        try writeToolCallCompact(writer, call);
    }

    var compaction_buf: [diagnostics.compaction_ring_capacity]diagnostics.CompactionEvent = undefined;
    const compaction_n = diagnostics.snapshotCompactionEvents(&compaction_buf);
    var compaction_reported: usize = 0;
    var ci = compaction_n;
    while (ci > 0 and compaction_reported < 3) {
        ci -= 1;
        const event = &compaction_buf[ci];
        if (!event.failed) continue;
        count += 1;
        compaction_reported += 1;
        try writer.writeAll("- context compaction ");
        try writer.writeAll(event.name());
        if (event.turn_id != 0) try writer.print(" turn_id={d}", .{event.turn_id});
        if (event.detail_len > 0) {
            try writer.writeAll(" detail=");
            const detail = event.detail();
            const visible = if (detail.len > 160) detail[0..160] else detail;
            try writeTraceTextNeutralized(writer, visible);
            if (detail.len > 160) try writer.writeAll(" ...");
        }
        try writer.writeByte('\n');
    }

    count += try writeModelCatalogProblems(writer);

    if (count == 0) try writer.writeAll("- no obvious errors captured in recent network, tool, compaction, or model catalog state\n");
}

/// Surfaces failed model-catalog loads, capability lookup misses, and image
/// gate rejections under Problems so an unverifiable-capability failure is
/// never reported as "no obvious errors".
fn writeModelCatalogProblems(writer: *std.Io.Writer) !usize {
    var buf: [diagnostics.model_catalog_ring_capacity]diagnostics.ModelCatalogEvent = undefined;
    const total = diagnostics.snapshotModelCatalogEvents(&buf);
    var count: usize = 0;
    var index = total;
    while (index > 0 and count < 3) {
        index -= 1;
        const event = &buf[index];
        if (!event.failed) continue;
        count += 1;
        try writer.print("- model catalog {s}", .{event.name()});
        if (event.detail().len > 0) {
            try writer.writeByte(' ');
            try writer.writeAll(event.detail());
        }
        try writer.writeByte('\n');
    }
    return count;
}

const trace_compaction_max_events: usize = 24;

/// Renders the always-on compaction decision and failure trail so a shared
/// trace explains what the compaction pipeline did even when FX_TRACE was off.
fn writeCompactionSummary(writer: *std.Io.Writer, alloc: std.mem.Allocator) !void {
    var buf: [diagnostics.compaction_ring_capacity]diagnostics.CompactionEvent = undefined;
    const total = diagnostics.snapshotCompactionEvents(&buf);

    try writer.writeAll("\n## Context Compaction\n");
    if (total == 0) {
        try writer.writeAll("(none recorded)\n");
        return;
    }
    var failed: usize = 0;
    for (buf[0..total]) |event| {
        if (event.failed) failed += 1;
    }
    try writer.print("last={d} failed={d}", .{ total, failed });
    // Events evicted by the bounded ring are reported, not silently dropped.
    const overwritten = buf[0].sequence -| 1;
    if (overwritten > 0) try writer.print(" overwritten_before={d}", .{overwritten});
    try writer.writeAll(" (always recorded; does not require FX_TRACE)\n");

    const start = if (total > trace_compaction_max_events) total - trace_compaction_max_events else 0;
    if (start > 0) try writer.print("... ({d} older events omitted)\n", .{start});
    for (buf[start..total]) |*event| {
        var line: std.Io.Writer.Allocating = .init(alloc);
        defer line.deinit();
        try writeTraceTimestampUtc(&line.writer, event.timestamp_ms);
        try line.writer.print(" event={s}", .{event.name()});
        if (event.turn_id != 0) try line.writer.print(" turn_id={d}", .{event.turn_id});
        if (event.step_id != 0) try line.writer.print(" step_id={d}", .{event.step_id});
        if (event.subagent_id != 0) try line.writer.print(" subagent_id={d}", .{event.subagent_id});
        if (event.failed) try line.writer.writeAll(" failed");
        if (event.detail_len > 0) {
            try line.writer.writeByte(' ');
            try line.writer.writeAll(event.detail());
        }
        if (event.truncated) try line.writer.writeAll(" ...");
        // Compaction events carry internal counters and enum names only, never
        // user payloads, so they render unmasked like network-call telemetry.
        const raw = line.written();
        const visible = if (raw.len > trace_transcript_max_line_bytes)
            raw[0..trace_transcript_max_line_bytes]
        else
            raw;
        try writeTraceTextNeutralized(writer, visible);
        if (raw.len > trace_transcript_max_line_bytes) {
            try writer.writeAll(" ...\n");
        } else {
            try writer.writeByte('\n');
        }
    }
}

/// Renders the retained session title generation outcome so a shared trace can
/// explain why a session has no generated title even when FX_TRACE was off.
fn writeSessionTitleSummary(writer: *std.Io.Writer, app: anytype, alloc: std.mem.Allocator) !void {
    const App = @TypeOf(app.*);
    if (comptime !@hasField(App, "session_persistence")) return;
    const Persistence = @TypeOf(app.session_persistence);
    if (comptime !@hasField(Persistence, "title_generation")) return;
    const TitleGeneration = @TypeOf(app.session_persistence.title_generation);
    if (comptime !@hasField(TitleGeneration, "last")) return;

    try writer.writeAll("\n## Session Title\n");
    if (comptime @hasField(App, "session_title_generation")) {
        try writer.print("setting: {s}\n", .{boolLabel(app.session_title_generation)});
    }
    if (comptime @hasField(App, "session_title")) {
        if (app.session_title.items.len > 0) {
            try writer.writeAll("title: ");
            try writeMaskedInline(writer, alloc, app.session_title.items);
            try writer.writeByte('\n');
        } else {
            try writer.writeAll("title: (none)\n");
        }
    }
    const generation = &app.session_persistence.title_generation;
    if (generation.task) |task| {
        try writer.print("generation: status=running session={s} model={s}", .{ task.session_id, task.model });
        if (task.started_at_ms > 0) {
            const elapsed = io_mod.milliTimestamp() - task.started_at_ms;
            if (elapsed >= 0) try writer.print(" elapsed={d}ms", .{elapsed});
        }
        try writer.writeByte('\n');
        return;
    }
    const last = &generation.last;
    try writer.print("generation: status={s}", .{@tagName(last.status)});
    if (last.sessionId().len > 0) try writer.print(" session={s}", .{last.sessionId()});
    if (last.model().len > 0) try writer.print(" model={s}", .{last.model()});
    if (last.reason) |reason| try writer.print(" reason={s}", .{@tagName(reason)});
    if (last.detail.len > 0) try writer.print(" detail={s}", .{last.detail});
    if (last.elapsed_ms >= 0) try writer.print(" elapsed={d}ms", .{last.elapsed_ms});
    try writer.writeByte('\n');
}

fn writeRuntimeContextSummary(writer: *std.Io.Writer) !void {
    try writer.writeAll("\n## Runtime Context\n");
    try writer.print("TERM: {s}\n", .{io_mod.getenv("TERM") orelse "(unset)"});
    try writer.print("TERM_PROGRAM: {s}\n", .{io_mod.getenv("TERM_PROGRAM") orelse "(unset)"});
    try writer.print("LANG: {s}\n", .{io_mod.getenv("LANG") orelse "(unset)"});
    try writer.print("terminal_hosts: tmux={s} cmux={s}\n", .{
        boolLabel(io_mod.getenv("TMUX") != null),
        boolLabel(io_mod.getenv("CMUX_WORKSPACE_ID") != null),
    });
}

fn writeRendererState(writer: *std.Io.Writer, app: anytype, alloc: std.mem.Allocator) !void {
    const transcript_commit = app.shell.transcriptCommitDiagnostic();
    try writer.writeAll("\n## Renderer State\n");
    try writer.print(
        "layout: cols={d} rows={d} content_bottom={d} divider_top={d} input_row={d}\n",
        .{ app.shell.layout.cols, app.shell.layout.rows, app.shell.layout.content_bottom, app.shell.layout.divider_top_row, app.shell.layout.input_row },
    );
    try writer.print(
        "cursor: row={d} col={d} viewport_top={d} owned_top={d} last_visible_top={d} last_start_line={d} partial_skip={d}\n",
        .{
            app.shell.cursor_row,
            app.shell.cursor_col,
            app.shell.viewport_top_row,
            app.shell.owned_top_row,
            app.shell.last_visible_transcript_top_row,
            app.shell.last_visible_transcript_start_line,
            app.shell.last_visible_transcript_partial_skip_rows,
        },
    );
    try writer.print(
        "transcript: bytes={d} entries={d} last_rendered_cols={d} dirty={s} has_painted={s} commit_state={s} committed_start_line={d} pending_compact={s}\n",
        .{
            app.shell.transcript.items.len,
            app.shell.entries.items.len,
            app.shell.last_rendered_cols,
            boolLabel(app.shell.transcript_band_dirty),
            boolLabel(app.shell.has_painted_transcript),
            @tagName(transcript_commit.state),
            transcript_commit.stable_start_line orelse 0,
            boolLabel(app.shell.pending_scroll_compact),
        },
    );
    try writer.print(
        "projection: view={d} history={d} total_rows={d} source_bytes={d} recovery={s} catchup={s}\n",
        .{ transcript_commit.visual_offset, transcript_commit.history_visual_offset, transcript_commit.total_visual_rows, transcript_commit.source_bytes, boolLabel(app.shell.normalBufferRecoveryPending()), boolLabel(app.shell.historyCatchupPending()) },
    );
    try writer.print(
        "replaceable: active={s} row={d} start={d}\n",
        .{ boolLabel(app.shell.replaceable_last_line), app.shell.replaceable_row, app.shell.replaceable_start },
    );

    const grid = app.shell.shadow_vt orelse {
        try writer.writeAll("shadow_grid: unavailable\n");
        return;
    };
    try writer.print(
        "shadow_grid: cols={d} rows={d} cursor={d},{d} visible={s} sync_active={s}\n",
        .{ grid.cols, grid.rows, grid.cursor_row, grid.cursor_col, boolLabel(grid.cursor_visible), boolLabel(grid.sync_active) },
    );
    try writer.writeAll("shadow_grid_visible_rows:\n");
    var emitted_any = false;
    var row: u16 = 1;
    while (row <= grid.rows) : (row += 1) {
        var row_text: std.ArrayList(u8) = .empty;
        defer row_text.deinit(alloc);
        try grid.rowTextTrimmed(row, &row_text);
        const trimmed = std.mem.trimEnd(u8, row_text.items, " \t\r");
        if (trimmed.len == 0) continue;
        emitted_any = true;
        const masked = try text_utils.maskSecrets(alloc, trimmed);
        defer if (masked.ptr != trimmed.ptr) alloc.free(masked);
        try writer.print("  {d:0>3}: {s}\n", .{ row, masked });
    }
    if (!emitted_any) try writer.writeAll("  (empty)\n");
}

fn writeRendererEvents(writer: *std.Io.Writer, alloc: std.mem.Allocator) !void {
    var events: [diagnostics.render_ring_capacity]diagnostics.RenderEvent = undefined;
    const count = diagnostics.snapshotRenderEvents(&events);
    try writer.writeAll("\n## Recent Renderer Events\n");
    try writer.writeAll("Internal rendering decisions, not terminal readback. Idle and same-row updates are omitted.\n");
    if (count == 0) {
        try writer.writeAll("(none recorded)\n");
        return;
    }
    try writer.print("retained={d} capacity={d} overwritten_before={d}\n", .{
        count, diagnostics.render_ring_capacity, events[0].sequence -| 1,
    });
    for (events[0..count]) |*event| {
        try writeTraceTimestampUtc(writer, event.timestamp_ms);
        try writer.print(" seq={d} kind={s} ", .{ event.sequence, @tagName(event.kind) });
        try writeMaskedInline(writer, alloc, event.detail());
        if (event.truncated) try writer.writeAll(" [truncated]");
        try writer.writeByte('\n');
    }
}

fn boolLabel(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn lastInterruptedTurn(items: []const types.HistoryTurn) ?types.InterruptedHistoryTurn {
    if (items.len == 0) return null;
    return switch (items[items.len - 1]) {
        .interrupted => |entry| entry,
        else => null,
    };
}

const trace_tool_args_max_bytes: usize = 1200;

fn networkCallIsError(call: diagnostics.NetworkCall) bool {
    return call.isError();
}

fn writeNetworkCallCompact(writer: *std.Io.Writer, call: diagnostics.NetworkCall) !void {
    try writeTraceTimestampUtc(writer, call.started_at_ms);
    try writer.print(" model={s}", .{call.model()});
    if (call.kind != .gateway) try writer.print(" kind={s}", .{@tagName(call.kind)});
    if (call.subagent_id != 0) try writer.print(" source=subagent#{d}", .{call.subagent_id}) else try writer.writeAll(" source=parent");
    if (call.errorName().len > 0) {
        try writer.print(" err={s}", .{call.errorName()});
    } else if (call.status != 0) {
        try writer.print(" status={d}", .{call.status});
    }
    try writer.print(" duration={d}ms bytes={d}", .{ call.duration_ms, call.response_bytes });
    if (call.input_tokens > 0 or call.output_tokens > 0) try writer.print(" tokens={d}->{d}", .{ call.input_tokens, call.output_tokens });
    if (call.is_web_search) try writer.print(" web_search_requests={d}", .{call.web_search_requests});
    if (call.terminalStopReason().len > 0) try writer.print(" stop_reason={s}", .{call.terminalStopReason()});
    if (call.turn_id != 0) try writer.print(" turn={d}", .{call.turn_id});
    if (call.step_id != 0) try writer.print(" step={d}", .{call.step_id});
    if (call.gatewaySchemaDiagnostic().len > 0) try writer.print(" gateway_schema=\"{s}\"", .{call.gatewaySchemaDiagnostic()});
    if (call.gatewayRequestShape().len > 0) try writer.print(" request_shape=\"{s}\"", .{call.gatewayRequestShape()});
    try writer.writeByte('\n');
}

fn writeNetworkCallsSummary(writer: *std.Io.Writer) !void {
    var buf: [diagnostics.network_ring_capacity]diagnostics.NetworkCall = undefined;
    const n = diagnostics.snapshotNetworkCalls(&buf);
    if (n == 0) {
        try writer.writeAll("\n## Network Calls\n(none recorded)\n");
        return;
    }

    var ok_count: u32 = 0;
    var error_count: u32 = 0;
    var total_ms: u64 = 0;
    var max_ms: u32 = 0;
    var min_ms: u32 = std.math.maxInt(u32);
    for (buf[0..n]) |call| {
        if (networkCallIsError(call)) error_count += 1 else ok_count += 1;
        total_ms += call.duration_ms;
        if (call.duration_ms > max_ms) max_ms = call.duration_ms;
        if (call.duration_ms < min_ms) min_ms = call.duration_ms;
    }
    const avg_ms: u64 = if (n > 0) total_ms / n else 0;

    try writer.print("\n## Network Calls\nlast={d} ok={d} errors={d} avg={d}ms min={d}ms max={d}ms\n", .{ n, ok_count, error_count, avg_ms, min_ms, max_ms });
    try writeNetworkSessionTotals(writer, buf[0..n]);
    for (buf[0..n]) |call| {
        try writeNetworkCallCompact(writer, call);
    }
}

/// Renders session-wide totals, the per-turn model-call rollup, and an
/// explicit coverage statement so a shared trace cannot be misread as
/// describing the whole session when the ring has already evicted history.
fn writeNetworkSessionTotals(writer: *std.Io.Writer, window: []const diagnostics.NetworkCall) !void {
    const lifetime = diagnostics.networkLifetimeStats();
    try writer.print(
        "session: calls={d} ok={d} errors={d} total_time={d}s\n",
        .{ lifetime.total_calls, lifetime.ok_calls, lifetime.error_calls, lifetime.total_duration_ms / 1000 },
    );
    if (window.len > 0 and lifetime.total_calls > window.len) {
        try writer.print(
            "coverage: window holds only the last {d} of {d} calls, oldest retained ",
            .{ window.len, lifetime.total_calls },
        );
        try writeTraceTimestampUtc(writer, window[0].started_at_ms);
        try writer.writeAll("; run with FX_TRACE_LOG for a complete transport record\n");
    } else {
        try writer.writeAll("coverage: complete (window holds every recorded call)\n");
    }

    var rollups: [diagnostics.network_turn_rollup_capacity]diagnostics.NetworkTurnRollup = undefined;
    const rollup_n = diagnostics.snapshotNetworkTurnRollups(&rollups);
    if (rollup_n == 0) return;
    if (lifetime.evicted_turns > 0) {
        try writer.print("turns: most recent {d} shown, {d} older evicted\n", .{ rollup_n, lifetime.evicted_turns });
    } else {
        try writer.writeAll("turns:\n");
    }
    for (rollups[0..rollup_n]) |rollup| {
        try writer.print(
            "  turn {d}: calls={d} errors={d} total_time={d}s",
            .{ rollup.turn_id, rollup.calls, rollup.error_calls, rollup.total_duration_ms / 1000 },
        );
        if (rollup.subagent_calls > 0) try writer.print(" subagent_calls={d}", .{rollup.subagent_calls});
        if (rollup.first_started_at_ms > 0) {
            try writer.writeAll(" started ");
            try writeTraceTimestampUtc(writer, rollup.first_started_at_ms);
        }
        try writer.writeByte('\n');
    }
}

/// Renders catalog cache state, the selected model's resolved capabilities,
/// and the always-on catalog event ring so a shared trace explains why an
/// image submission or capability-dependent feature was rejected.
fn writeModelCatalogSummary(writer: *std.Io.Writer, app: anytype) !void {
    const App = @TypeOf(app.*);
    try writer.writeAll("\n## Model Catalog\n");
    if (comptime @hasField(App, "model_cache")) {
        const snapshot = app.model_cache.snapshotForTrace();
        try writer.print("state={s} entries={d}", .{ snapshot.state, snapshot.entries });
        if (snapshot.last_attempt_ms > 0) {
            const age_ms = io_mod.milliTimestamp() - snapshot.last_attempt_ms;
            try writer.print(" last_attempt={d}s ago", .{@divFloor(@max(age_ms, 0), @as(i64, 1000))});
        }
        if (snapshot.failure_category) |category| {
            try writer.print(" failure={s} retryable={s}", .{ category, boolLabel(snapshot.failure_retryable) });
            if (snapshot.failure_http_status) |status| try writer.print(" status={d}", .{@backingInt(status)});
            if (snapshot.anonymous_fallback) try writer.writeAll(" anonymous_fallback=true");
        }
        try writer.writeByte('\n');
    }
    if (comptime @hasDecl(App, "resolvedModelCapabilities")) {
        const model = provider_runtime.model(app);
        const capabilities = app.resolvedModelCapabilities(model);
        try writer.print("selected_model={s} image_input={s} vision={s} file_input={s} tool_use={s}", .{
            model,
            @tagName(capabilities.image_input_support),
            boolLabel(capabilities.supports_vision),
            boolLabel(capabilities.supports_file_input),
            boolLabel(capabilities.supports_tool_use),
        });
        if (capabilities.context_window) |window| try writer.print(" context_window={d}", .{window});
        try writer.writeByte('\n');
    }
    var buf: [diagnostics.model_catalog_ring_capacity]diagnostics.ModelCatalogEvent = undefined;
    const total = diagnostics.snapshotModelCatalogEvents(&buf);
    if (total == 0) {
        try writer.writeAll("(no catalog events recorded)\n");
        return;
    }
    try writer.print("events={d} (always recorded; does not require FX_TRACE)\n", .{total});
    for (buf[0..total]) |*event| {
        try writeTraceTimestampUtc(writer, event.timestamp_ms);
        try writer.print(" seq={d} {s}", .{ event.sequence, event.name() });
        if (event.failed) try writer.writeAll(" failed");
        if (event.detail().len > 0) {
            try writer.writeByte(' ');
            try writer.writeAll(event.detail());
        }
        if (event.truncated) try writer.writeAll(" [truncated]");
        try writer.writeByte('\n');
    }
}

fn writePermissionsSummary(writer: *std.Io.Writer, grants: []const types.PermissionGrant) !void {
    if (grants.len == 0) {
        try writer.writeAll("\n## Permissions\npermission grants: none\n");
        return;
    }
    try writer.print("\n## Permissions\npermission grants ({d}):\n", .{grants.len});
    for (grants) |grant| {
        try writer.print("  - {s} :: {s}\n", .{ traceToolDisplayName(grant.tool_name), grant.target_path });
    }
}

fn writeToolCallCompact(writer: *std.Io.Writer, call: diagnostics.ToolCallMetric) !void {
    try writeTraceTimestampUtc(writer, call.started_at_ms);
    try writer.print(" name={s} outcome={s} duration={d}ms", .{ traceToolDisplayName(call.name()), @tagName(call.outcome), call.duration_ms });
    if (call.subagent_id != 0) try writer.print(" source=subagent#{d}", .{call.subagent_id}) else try writer.writeAll(" source=parent");
    try writer.writeByte('\n');
}

const ProviderToolCallSummary = struct {
    call_id: []const u8,
    status: ?types.PersistedToolStatus,
};

fn findPersistedToolResult(
    execution: types.ExecutionMemory,
    call_id: []const u8,
) ?types.PersistedToolResult {
    for (execution.tool_steps) |step| {
        for (step.tool_results) |result| {
            if (std.mem.eql(u8, result.tool_call_id, call_id)) return result;
        }
    }
    return null;
}

fn projectProviderToolCalls(
    history: []const types.HistoryTurn,
    output: []ProviderToolCallSummary,
) usize {
    if (output.len == 0) return 0;

    var count: usize = 0;
    for (history) |turn| {
        const execution: types.ExecutionMemory = switch (turn) {
            .assistant => |entry| entry.execution,
            .interrupted => |entry| entry.execution,
            .compacted_summary => continue,
        };
        for (execution.tool_steps) |step| {
            for (step.tool_calls) |call| {
                if (call.provenance != .provider_executed or
                    !tool_presentation.isProviderSearchAlias(call.name)) continue;
                const summary: ProviderToolCallSummary = .{
                    .call_id = call.id,
                    .status = if (findPersistedToolResult(execution, call.id)) |result|
                        result.status
                    else
                        null,
                };
                if (count < output.len) {
                    output[count] = summary;
                    count += 1;
                } else {
                    @memmove(
                        output[0 .. output.len - 1],
                        output[1..],
                    );
                    output[output.len - 1] = summary;
                }
            }
        }
    }
    return count;
}

fn providerToolStatusLabel(status: ?types.PersistedToolStatus) []const u8 {
    return if (status) |value| switch (value) {
        .success => "ok",
        .failure => "err",
    } else "pending";
}

fn writeSearchUsageSummary(writer: *std.Io.Writer, observed: u64, billed: u64) !void {
    try writer.print("web_search_requests_total: {d} (observed)\n", .{observed});
    try writer.print("billable_web_search_calls: {d} (billed)\n", .{billed});
}

noinline fn writeToolCallsSummary(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    history: []const types.HistoryTurn,
) !void {
    var buf: [diagnostics.tool_call_ring_capacity]diagnostics.ToolCallMetric = undefined;
    const n = diagnostics.snapshotToolCalls(&buf);
    var provider_buf: [diagnostics.tool_call_ring_capacity]ProviderToolCallSummary = undefined;
    const provider_n = projectProviderToolCalls(history, &provider_buf);
    if (n == 0 and provider_n == 0) {
        try writer.writeAll("\n## Tool Calls\n(none recorded)\n");
        return;
    }

    try writer.writeAll("\n## Tool Calls\n### Local\n");
    if (n == 0) {
        try writer.writeAll("(none locally executed)\n");
    } else {
        var succeeded_count: u32 = 0;
        var rejected_count: u32 = 0;
        var command_failed_count: u32 = 0;
        var tool_failed_count: u32 = 0;
        var runtime_failed_count: u32 = 0;
        var total_ms: u64 = 0;
        for (buf[0..n]) |call| {
            switch (call.outcome) {
                .succeeded => succeeded_count += 1,
                .rejected => rejected_count += 1,
                .command_failed => command_failed_count += 1,
                .tool_failed => tool_failed_count += 1,
                .runtime_failed => runtime_failed_count += 1,
            }
            total_ms += call.duration_ms;
        }

        try writer.print(
            "last={d} succeeded={d} rejected={d} command_failed={d} tool_failed={d} runtime_failed={d} total={d}ms\n",
            .{ n, succeeded_count, rejected_count, command_failed_count, tool_failed_count, runtime_failed_count, total_ms },
        );
        const lifetime = diagnostics.toolCallLifetimeStats();
        try writer.print(
            "session: calls={d} succeeded={d} rejected={d} command_failed={d} tool_failed={d} runtime_failed={d} total_time={d}s\n",
            .{
                lifetime.total_calls,
                lifetime.countFor(.succeeded),
                lifetime.countFor(.rejected),
                lifetime.countFor(.command_failed),
                lifetime.countFor(.tool_failed),
                lifetime.countFor(.runtime_failed),
                lifetime.total_duration_ms / 1000,
            },
        );
        if (lifetime.total_calls > n) {
            try writer.print(
                "coverage: window holds only the last {d} of {d} tool calls; full results persist in the session directory\n",
                .{ n, lifetime.total_calls },
            );
        } else {
            try writer.writeAll("coverage: complete (window holds every recorded tool call)\n");
        }
        if (succeeded_count != n) {
            try writer.writeAll("non-successes first:\n");
            for (buf[0..n]) |call| {
                if (call.outcome == .succeeded) continue;
                try writeToolCallCompact(writer, call);
                try writeToolFieldBlock(writer, alloc, "args", call.args(), call.args_len, call.args_total_bytes);
                try writeToolFieldBlock(writer, alloc, "result", call.result(), call.result_len, call.result_total_bytes);
            }
            try writer.writeAll("recent successes (compact):\n");
        } else {
            try writer.writeAll("recent successes (compact):\n");
        }
        for (buf[0..n]) |call| {
            if (call.outcome != .succeeded) continue;
            try writeToolCallCompact(writer, call);
            try writeToolFieldBlock(writer, alloc, "args", call.args(), call.args_len, call.args_total_bytes);
            try writeToolResultPreview(writer, alloc, call.result(), call.result_total_bytes);
        }
    }

    try writer.writeAll("### Web Search\n");
    if (provider_n == 0) {
        try writer.writeAll("(none retained)\n");
        return;
    }
    try writer.print("last={d}\n", .{provider_n});
    for (provider_buf[0..provider_n]) |call| {
        try writer.print(
            "name=web_search status={s}\n",
            .{providerToolStatusLabel(call.status)},
        );
    }
}

fn writeToolResultPreview(writer: *std.Io.Writer, alloc: std.mem.Allocator, body: []const u8, total_bytes: u32) !void {
    if (total_bytes == 0) return;
    const raw_trimmed = std.mem.trim(u8, body, " \t\r\n");
    const masked = try text_utils.maskSecrets(alloc, raw_trimmed);
    defer if (masked.ptr != raw_trimmed.ptr) alloc.free(masked);
    const trimmed = std.mem.trim(u8, masked, " \t\r\n");
    if (trimmed.len == 0) return;

    const preview = firstUsefulPreviewLine(trimmed);
    try writer.writeAll("  result_preview: ");
    if (preview.len > 180) {
        try writer.writeAll(preview[0..180]);
        try writer.writeAll(" ...");
    } else {
        try writer.writeAll(preview);
    }
    if (total_bytes > preview.len) try writer.print(" ({d} bytes total)", .{total_bytes});
    try writer.writeByte('\n');
}

fn firstUsefulPreviewLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, ":")) continue;
        return trimmed;
    }
    return text[0..@min(text.len, 180)];
}

fn writeToolFieldBlock(writer: *std.Io.Writer, alloc: std.mem.Allocator, label: []const u8, body: []const u8, body_len: u16, total_bytes: u32) !void {
    if (total_bytes == 0) return;
    const raw_trimmed = std.mem.trim(u8, body, " \t\r\n");
    const masked = try text_utils.maskSecrets(alloc, raw_trimmed);
    defer if (masked.ptr != raw_trimmed.ptr) alloc.free(masked);
    const trimmed = std.mem.trim(u8, masked, " \t\r\n");
    if (trimmed.len == 0) return;

    if (std.mem.findScalar(u8, trimmed, '\n') == null) {
        try writer.print("  {s}: {s}", .{ label, trimmed });
        if (total_bytes > body_len) {
            try writer.print(" ... ({d} more bytes)", .{total_bytes - body_len});
        }
        try writer.writeByte('\n');
        return;
    }

    try writer.print("  {s}:\n", .{label});
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| {
        try writer.print("    {s}\n", .{std.mem.trimEnd(u8, line, " \t\r")});
    }
    if (total_bytes > body_len) {
        try writer.print("    ... ({d} more bytes)\n", .{total_bytes - body_len});
    }
}

fn writeLastInterruptedDetail(writer: *std.Io.Writer, items: []const types.HistoryTurn, alloc: std.mem.Allocator) !void {
    if (items.len == 0) return;
    const last = items[items.len - 1];
    switch (last) {
        .interrupted => |t| {
            try writer.writeAll("\n## Interrupted Turn\nlast turn was interrupted by user\n");
            if (t.tool_call) |call| {
                try writer.print("  in_flight_tool: {s}\n", .{traceToolDisplayName(call.name)});
                if (call.arguments_json.len > 0) {
                    try writer.writeAll("  in_flight_args:\n");
                    if (call.arguments_json.len > trace_tool_args_max_bytes) {
                        try writer.writeAll("    ");
                        try writeMaskedInline(writer, alloc, call.arguments_json[0..trace_tool_args_max_bytes]);
                        try writer.print("\n    ... (truncated, {d} more bytes)\n", .{call.arguments_json.len - trace_tool_args_max_bytes});
                    } else {
                        try writer.writeAll("    ");
                        try writeMaskedInline(writer, alloc, call.arguments_json);
                        try writer.writeByte('\n');
                    }
                }
            }
            if (t.completed_tool_names.len > 0) {
                try writer.print("  completed_tools ({d}):", .{t.completed_tool_names.len});
                for (t.completed_tool_names) |name| try writer.print(" {s}", .{traceToolDisplayName(name)});
                try writer.writeByte('\n');
            }
        },
        else => {},
    }
}

const trace_tail_bytes: usize = 6 * 1024;
const trace_max_lines: usize = 80;

fn writeTraceLogTail(writer: *std.Io.Writer, alloc: std.mem.Allocator, path: []const u8) !void {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return;
    defer file.close(io_mod.getIo());

    var stat_buf: std.Io.File.Stat = undefined;
    stat_buf = file.stat(io_mod.getIo()) catch return;
    const total_size: usize = @intCast(stat_buf.size);
    if (total_size == 0) return;

    const read_size = @min(total_size, trace_tail_bytes);
    const offset: u64 = total_size - read_size;

    const buf = alloc.alloc(u8, read_size) catch return;
    defer alloc.free(buf);
    const n = file.readPositionalAll(io_mod.getIo(), buf, offset) catch return;
    if (n == 0) return;

    try writer.print("\n## Trace Tail\npath={s} last_bytes={d}\n", .{ path, n });
    try writer.writeAll("only obvious secrets masked\n");
    if (offset > 0) try writer.writeAll("... (older lines truncated)\n");

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try lines.append(alloc, trimmed);
    }

    const start = if (lines.items.len > trace_max_lines)
        lines.items.len - trace_max_lines
    else
        0;

    for (lines.items[start..]) |line| {
        const masked = try text_utils.maskSecrets(alloc, line);
        defer if (masked.ptr != line.ptr) alloc.free(masked);
        const visible = if (masked.len > trace_transcript_max_line_bytes)
            masked[0..trace_transcript_max_line_bytes]
        else
            masked;
        try writeTraceTextNeutralized(writer, visible);
        if (masked.len > trace_transcript_max_line_bytes) {
            try writer.writeAll(" ...\n");
        } else {
            try writer.writeByte('\n');
        }
    }
}

fn writeTraceTimestampUtc(writer: *std.Io.Writer, ms: i64) !void {
    if (ms <= 0) {
        try writer.writeAll("[----------T--:--:--Z]");
        return;
    }
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const ms_part: u64 = @intCast(@mod(ms, 1000));
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day_seconds = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    try writer.print("[{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z]", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        ms_part,
    });
}

noinline fn writeTranscriptTimeline(writer: *std.Io.Writer, alloc: std.mem.Allocator, entries: anytype) !void {
    var emitted_any = false;
    for (entries) |entry| {
        const ts = entry.createdAtMs();
        var rendered_payload: ?[]u8 = null;
        defer if (rendered_payload) |text| alloc.free(text);
        const kind: []const u8 = switch (entry) {
            .raw_bytes => "raw",
            .user_turn => "user",
            .assistant_turn => "assistant",
            .assistant_table => "assistant table",
            .assistant_code_block => "assistant code block",
            .assistant_thematic_rule => "assistant thematic rule",
            .semantic_notice => "semantic notice",
        };
        const text: []const u8 = switch (entry) {
            .raw_bytes => |e| e.bytes,
            .user_turn => |e| e.turn.text,
            .assistant_turn => |e| e.segments.text.items,
            .assistant_table => |e| blk: {
                var table_text: std.ArrayList(u8) = .empty;
                errdefer table_text.deinit(alloc);
                try assistant_presentation.renderTablePayload(alloc, e.table, &table_text);
                rendered_payload = try table_text.toOwnedSlice(alloc);
                break :blk rendered_payload.?;
            },
            .assistant_code_block => |e| blk: {
                var code_text: std.ArrayList(u8) = .empty;
                errdefer code_text.deinit(alloc);
                try assistant_presentation.renderCodeBlockPayload(alloc, e.block, &code_text);
                rendered_payload = try code_text.toOwnedSlice(alloc);
                break :blk rendered_payload.?;
            },
            .assistant_thematic_rule => blk: {
                var rule_text: std.ArrayList(u8) = .empty;
                errdefer rule_text.deinit(alloc);
                try assistant_presentation.writeHorizontalRule(alloc, &rule_text);
                rendered_payload = try rule_text.toOwnedSlice(alloc);
                break :blk rendered_payload.?;
            },
            .semantic_notice => |e| blk: {
                const rendered = try transcript_blocks.renderSemanticNotice(
                    alloc,
                    .{
                        .topic = e.topic,
                        .tone = e.tone,
                        .body = e.body,
                        .visibility = e.visibility,
                    },
                    .{},
                    std.math.maxInt(u16),
                );
                rendered_payload = rendered;
                break :blk rendered;
            },
        };
        if (text.len == 0) continue;

        const body = switch (entry) {
            .assistant_thematic_rule => try renderThematicRuleTimelineBody(alloc, text),
            else => try renderTimelineEntryBody(alloc, text),
        };
        defer alloc.free(body);
        if (body.len == 0) continue;

        if (emitted_any) try writer.writeByte('\n');
        try writeTraceTimestampUtc(writer, ts);
        try writer.print(" {s}\n", .{kind});
        try writer.writeAll(body);
        emitted_any = true;
    }
    if (!emitted_any) try writer.writeAll("(empty after filtering)\n");
}

fn renderTimelineEntryBody(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const stripped = try stripAnsiEscapes(alloc, text);
    defer alloc.free(stripped);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var it = std.mem.splitScalar(u8, stripped, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (isBannerNoiseLine(trimmed)) continue;
        const masked = try text_utils.maskSecrets(alloc, trimmed);
        defer if (masked.ptr != trimmed.ptr) alloc.free(masked);
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, masked);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

fn renderThematicRuleTimelineBody(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const stripped = try stripAnsiEscapes(alloc, text);
    defer alloc.free(stripped);
    const trimmed = std.mem.trimEnd(u8, stripped, " \t\r\n");
    return alloc.print("  {s}\n", .{trimmed});
}

fn isBannerNoiseLine(line: []const u8) bool {
    if (line.len == 0) return true;
    if (std.mem.find(u8, line, "\xe2\x96\x91") != null) return true;
    var has_alnum: bool = false;
    for (line) |c| if (std.ascii.isAlphanumeric(c)) {
        has_alnum = true;
        break;
    };
    return !has_alnum;
}

fn stripAnsiEscapes(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, input.len);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == 0x1b and i + 1 < input.len) {
            i = display_width.ansiSequenceEnd(input, i);
            continue;
        }
        if (c == '\r') {
            i += 1;
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

fn handleRenameCommand(app: anytype, rest: []const u8) !void {
    const App = @TypeOf(app.*);
    const SessionRuntime = app_session_runtime.Runtime(App);
    SessionRuntime.renameActiveSession(app, rest) catch |err| {
        if (err == error.EmptyTitle) {
            // Usage lines name the command; a topic tag would repeat it.
            try app.writeDomainNotice(
                .{ .topic = "", .tone = .@"error", .body = "usage: /rename <title>" },
                true,
            );
            return;
        }
        const body: []const u8 = switch (err) {
            error.EmptyTitle => unreachable,
            error.TitleTooLong => "title is too long",
            error.InvalidTitle => "title must be printable text",
            error.NoActiveSession => "no active session to rename",
            else => {
                const notice = try app.alloc.print(
                    "renamed for this process but not saved ({s})",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try app.writeDomainNotice(
                    .{ .topic = "session", .tone = .warning, .body = notice },
                    true,
                );
                app.shell.render_requests.request(.footer);
                return;
            },
        };
        try app.writeDomainNotice(
            .{ .topic = "session", .tone = .@"error", .body = body },
            true,
        );
        return;
    };

    app.shell.render_requests.request(.footer);
    const title = SessionRuntime.cachedSessionTitle(app) orelse "";
    const msg = try app.alloc.print("renamed to \"{s}\"", .{title});
    defer app.alloc.free(msg);
    try app.writeDomainNotice(.{ .topic = "session", .tone = .neutral, .body = msg }, true);
}

const StatuslineFeedback = enum { announce, silent };

fn parseStatuslineItem(raw: []const u8) ?config_runtime.StatuslineItem {
    const trimmed = std.mem.trim(u8, raw, " \t");
    const statusline_item_info = @typeInfo(config_runtime.StatuslineItem).@"enum";
    inline for (statusline_item_info.field_names, statusline_item_info.field_values) |field_name, field_value| {
        if (std.mem.eql(u8, trimmed, field_name)) return @fromBackingInt(@intCast(field_value));
    }
    return null;
}

fn statuslineItemForSetting(setting: settings_catalog.SettingId) ?config_runtime.StatuslineItem {
    return switch (setting) {
        .statusline_context => .context,
        .statusline_session => .session,
        .statusline_workspace => .workspace,
        else => null,
    };
}

fn statuslineItemEnabled(app: anytype, item: config_runtime.StatuslineItem) bool {
    const App = @TypeOf(app.*);
    return switch (item) {
        .context => app.statusline_context,
        .session => app.statusline_session,
        .workspace => if (comptime @hasField(App, "workspace_identity"))
            app.workspace_identity.enabled
        else
            false,
    };
}

fn assignStatuslineItem(app: anytype, item: config_runtime.StatuslineItem, enabled: bool) bool {
    const App = @TypeOf(app.*);
    const current = statuslineItemEnabled(app, item);
    switch (item) {
        .context => app.statusline_context = enabled,
        .session => app.statusline_session = enabled,
        .workspace => if (comptime @hasField(App, "workspace_identity")) {
            app.workspace_identity.enabled = enabled;
        },
    }
    return current != enabled;
}

fn applyStatuslineItem(
    app: anytype,
    item: config_runtime.StatuslineItem,
    enabled: bool,
    feedback: StatuslineFeedback,
) !void {
    const runtime_changed = assignStatuslineItem(app, item, enabled);
    const patch: config_runtime.UserSettingsPatch = .{
        .statusline_item = .{ .item = item, .enabled = enabled },
    };
    switch (feedback) {
        .announce => {
            try persistUserPreferences(app, "statusline", patch, runtime_changed);
            const message = try app.alloc.print(
                "{s}: {s}",
                .{ @tagName(item), if (enabled) "on" else "off" },
            );
            defer app.alloc.free(message);
            try app.writeDomainNotice(.{ .topic = "statusline", .tone = .neutral, .body = message }, true);
        },
        .silent => try persistUserPreferencesSilently(app, "statusline", patch, runtime_changed),
    }
    app.shell.render_requests.request(.footer);
}

fn handleStatuslineCommand(app: anytype, rest: []const u8) !void {
    const item = parseStatuslineItem(rest) orelse {
        try app.writeDomainNotice(.{
            .topic = "",
            .tone = .@"error",
            .body = "usage: /statusline [context|session|workspace]",
        }, true);
        return;
    };
    try applyStatuslineItem(app, item, !statuslineItemEnabled(app, item), .announce);
}

const SoundLevel = enum {
    off,
    on,
    max,

    fn label(self: SoundLevel) []const u8 {
        return @tagName(self);
    }
};

const ParsedSoundCommand = union(enum) {
    toggle,
    set: SoundLevel,
    invalid,
};

noinline fn parseSoundCommand(rest: []const u8) ParsedSoundCommand {
    var tokens = std.mem.tokenizeAny(u8, rest, " \t");
    const first = tokens.next() orelse return .toggle;
    const level = parseSoundLevel(first) orelse return .invalid;
    if (tokens.next() != null) return .invalid;
    return .{ .set = level };
}

fn parseSoundLevel(value: []const u8) ?SoundLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "on")) return .on;
    if (std.mem.eql(u8, value, "max")) return .max;
    return null;
}

fn handleNotificationsCommand(app: anytype, rest: []const u8) !void {
    const current = app.notificationPreferences();
    const level: SoundLevel = switch (parseSoundCommand(rest)) {
        // Bare /sound toggles sound on/off; max is only ever explicit.
        .toggle => if (current.turn_end) .off else .on,
        .set => |value| value,
        .invalid => {
            try app.writeDomainNotice(.{
                .topic = "",
                .tone = .@"error",
                .body = "usage: /sound [on|off|max]",
            }, true);
            return;
        },
    };

    const sound_on = level != .off;
    const max = level == .max;
    const runtime_changed = sound_on != current.turn_end or
        sound_on != current.attention_required or
        max != current.max;
    app.setNotificationPreferences(sound_on, sound_on, max);

    const patch: config_runtime.UserSettingsPatch = .{
        .notification_turn_end = sound_on,
        .notification_attention_required = sound_on,
        .notification_max = max,
    };
    var attempt = config_runtime.attemptUserPreferences(app.alloc, patch);
    defer attempt.deinit(app.alloc);
    switch (attempt) {
        .failure => |failure| try session_commands.reportUserSettingsFailure(
            app,
            "sound",
            failure.err,
            failure.cleanup,
            runtime_changed,
        ),
        // announce_commit=false drops the routine "saved" line (the state
        // notice below covers it, matching /fast) but keeps warnings.
        .outcome => |outcome| _ = try session_commands.reportUserSettingsCommit(
            app,
            "sound",
            patch,
            outcome,
            null,
            false,
        ),
    }

    try app.writeDomainNotice(.{
        .topic = "sound",
        .tone = .neutral,
        .body = level.label(),
    }, true);
}

pub fn settingsCatalogSnapshot(app: anytype) settings_catalog.Snapshot {
    const App = @TypeOf(app.*);
    var snapshot: settings_catalog.Snapshot = .{};
    if (comptime provider_runtime.supported(App)) snapshot.model = provider_runtime.model(app);
    if (comptime @hasField(App, "effort")) snapshot.effort = app.effort.displayLabel();
    if (comptime @hasField(App, "fast_mode")) snapshot.fast_mode = app.fast_mode;
    if (comptime @hasField(App, "worker") and
        @hasField(@TypeOf(app.worker), "agent_turn_settings"))
    {}
    if (comptime @hasDecl(App, "resolvedModelCapabilities") and provider_runtime.supported(App)) {
        const capabilities = app.resolvedModelCapabilities(provider_runtime.model(app));
        snapshot.reasoning_efforts = capabilities.reasoning_efforts;
        snapshot.supports_fast_mode = capabilities.supports_fast_mode;
    }
    if (comptime @hasField(App, "permission_engine")) snapshot.permission_mode = @tagName(app.permission_engine.mode);
    if (comptime @hasField(App, "input_runtime")) {
        snapshot.startup_scrollback = app.input_runtime.settings_menu.startup_scrollback;
        if (comptime @hasField(@TypeOf(app.input_runtime), "slash_menu_categories")) {
            snapshot.slash_menu_categories = app.input_runtime.slash_menu_categories;
        }
    }
    if (comptime @hasField(App, "shell") and @hasField(@TypeOf(app.shell), "collapse_tool_calls")) {
        snapshot.collapse_tool_calls = app.shell.collapse_tool_calls;
    }
    if (comptime @hasField(App, "statusline_context")) snapshot.statusline_context = app.statusline_context;
    if (comptime @hasField(App, "statusline_session")) snapshot.statusline_session = app.statusline_session;
    if (comptime @hasField(App, "session_title_generation")) snapshot.session_titles = app.session_title_generation;
    if (comptime @hasField(App, "workspace_identity")) snapshot.statusline_workspace = app.workspace_identity.enabled;
    if (comptime @hasField(App, "prompt_history")) snapshot.prompt_history = app.prompt_history.enabled;
    if (comptime @hasDecl(App, "notificationPreferences")) {
        const notifications = app.notificationPreferences();
        snapshot.sound_level = settings_catalog.notificationLevel(
            notifications.turn_end,
            notifications.attention_required,
            notifications.max,
        );
    }
    return snapshot;
}

pub fn applySettingsCatalogMenuChange(app: anytype, change: settings_catalog.Change) !void {
    switch (change.setting) {
        .statusline_context, .statusline_session, .statusline_workspace => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            try applyStatuslineItem(
                app,
                statuslineItemForSetting(change.setting).?,
                enabled,
                .silent,
            );
        },
        else => try applySettingsCatalogChange(app, change),
    }
    app.shell.render_requests.request(.footer);
}

fn persistUserPreferencesSilently(
    app: anytype,
    label: []const u8,
    patch: config_runtime.UserSettingsPatch,
    runtime_changed: bool,
) !void {
    var attempt = config_runtime.attemptUserPreferences(app.alloc, patch);
    defer attempt.deinit(app.alloc);
    switch (attempt) {
        .failure => |failure| try session_commands.reportUserSettingsFailure(
            app,
            label,
            failure.err,
            failure.cleanup,
            runtime_changed,
        ),
        .outcome => {},
    }
}

pub fn applySettingsCatalogChange(app: anytype, change: settings_catalog.Change) !void {
    switch (change.setting) {
        .model => unreachable,
        .statusline_context, .statusline_session, .statusline_workspace => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const item = statuslineItemForSetting(change.setting).?;
            if (enabled != statuslineItemEnabled(app, item)) {
                try applyStatuslineItem(app, item, enabled, .announce);
            }
        },
        .collapse_tool_calls => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const runtime_changed = enabled != app.shell.collapse_tool_calls;
            if (runtime_changed) {
                app.shell.collapse_tool_calls = enabled;
                app.shell.markTranscriptStructureDirty();
                app.shell.render_requests.request(.transcript);
            }
            try persistUserPreferences(
                app,
                "collapse tool calls",
                .{ .collapse_tool_calls = enabled },
                runtime_changed,
            );
        },
        .slash_menu_categories => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const runtime_changed = enabled != app.input_runtime.slash_menu_categories;
            if (runtime_changed) {
                app.input_runtime.slash_menu_categories = enabled;
                app.shell.render_requests.request(.footer);
            }
            try persistUserPreferences(
                app,
                "slash menu categories",
                .{ .slash_menu_categories = enabled },
                runtime_changed,
            );
        },
        .session_titles => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const ChangeApp = @TypeOf(app.*);
            const current = if (comptime @hasField(ChangeApp, "session_title_generation"))
                app.session_title_generation
            else
                true;
            const runtime_changed = enabled != current;
            if (comptime @hasField(ChangeApp, "session_title_generation")) {
                if (runtime_changed) app.session_title_generation = enabled;
            }
            try persistUserPreferences(
                app,
                "session titles",
                .{ .session_titles = enabled },
                runtime_changed,
            );
        },
        .effort => {
            const effort = types.ReasoningEffort.parseDisplayLabel(change.value) orelse
                return error.InvalidSettingsCatalogValue;
            const capabilities = app.resolvedModelCapabilities(provider_runtime.model(app));
            if (!model_capabilities.reasoningEffortSupported(capabilities, effort)) {
                const message = try app.alloc.print(
                    "{s} is not available for {s}",
                    .{ effort.displayLabel(), provider_runtime.model(app) },
                );
                defer app.alloc.free(message);
                try app.writeDomainNotice(.{ .topic = "effort", .tone = .neutral, .body = message }, true);
                return;
            }
            try session_commands.Commands(@TypeOf(app.*)).selectEffortFromSettings(app, effort);
        },
        .fast_mode => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            if (enabled != app.fast_mode) try session_commands.Commands(@TypeOf(app.*)).toggleFast(app);
        },
        .permission_mode => try session_commands.Commands(@TypeOf(app.*)).handlePermissions(app, change.value),
        .sound_level => try handleNotificationsCommand(app, change.value),
        .startup_scrollback => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            try session_commands.Commands(@TypeOf(app.*)).handleSettings(
                app,
                if (enabled) "startup-scrollback on" else "startup-scrollback off",
            );
            var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch return;
            defer settings.deinit(app.alloc);
            app.input_runtime.settings_menu.startup_scrollback = settings.startup_scrollback orelse true;
        },
        .prompt_history => try session_commands.Commands(@TypeOf(app.*)).handleHistory(app, change.value),
    }
}

fn parseOnOff(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "off")) return false;
    return null;
}

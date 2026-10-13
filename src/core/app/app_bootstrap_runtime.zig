const std = @import("std");
const app_lifecycle = @import("app_lifecycle.zig");
const provider_runtime = @import("provider_runtime.zig");
const app_input_runtime = @import("app_input_runtime.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const app_runtime_setup = @import("app_runtime_setup.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
const host = @import("../hosts/host.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const record_tape = @import("../workspace/record_tape.zig");
const shared_io = @import("../shared/io.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const types = @import("../shared/types.zig");
const auto_upgrade = @import("../upgrade/auto_upgrade.zig");
const ui_render = @import("../../ui/render.zig");

const Allocator = std.mem.Allocator;

const SessionAssemblyFacts = struct {
    provider: []const u8,
    model: []const u8,
    effort: []const u8,
    system_prompt_bytes: ?usize,
    tool_names: []const []const u8,
    /// Null while the launch skill discovery is still running.
    skill_count: ?usize,
};

const session_tool_name_preview_max = 8;

/// Pure formatter for the full-only session assembly record. Facts in,
/// bounded body text out; no I/O, no app state.
fn writeSessionAssemblyBody(
    writer: *std.Io.Writer,
    facts: SessionAssemblyFacts,
) !void {
    try writer.print("provider: {s} · model: {s} · effort: {s}\n", .{
        facts.provider,
        facts.model,
        facts.effort,
    });
    if (facts.system_prompt_bytes) |bytes| {
        try writer.print("system prompt: ready · {d} bytes\n", .{bytes});
    }
    try writer.print("tools: {d} advertised", .{facts.tool_names.len});
    if (facts.tool_names.len > 0) {
        try writer.writeAll(" (");
        const shown = @min(facts.tool_names.len, session_tool_name_preview_max);
        for (facts.tool_names[0..shown], 0..) |name, index| {
            if (index > 0) try writer.writeAll(", ");
            try writer.writeAll(name);
        }
        if (facts.tool_names.len > shown) {
            try writer.print(", +{d} more", .{facts.tool_names.len - shown});
        }
        try writer.writeAll(")");
    }
    try writer.writeByte('\n');
    if (facts.skill_count) |count| {
        try writer.print("skills: {d} in catalog", .{count});
    } else {
        try writer.writeAll("skills: loading");
    }
}

pub const CapabilityProviders = struct {
    skill_root_policy: skill_contract.RootPolicy,
    terminal_title: host.TerminalTitle,
};

fn BootstrapDeps(comptime App: type) type {
    return struct {
        const BootstrapInteractiveAppFn = *const fn (app_lifecycle.BootstrapConfig) anyerror!app_lifecycle.StartupState;
        const ConfigureSessionPreferencesFn = *const fn (
            *App,
            model_provider.ProviderId,
            []const u8,
            config_runtime.ModelSource,
            []const u8,
            types.ReasoningEffort,
            bool,
            bool,
            bool,
            ?bool,
            ?types.ReasoningEffort,
            ?bool,
            ?model_provider.ProviderId,
        ) anyerror!void;
        const InitializePersistenceFn = *const fn (*App, bool) anyerror!void;
        const LoadSkillsFn = *const fn (
            Allocator,
            []const u8,
            skill_contract.RootPolicy,
        ) app_runtime_setup.LoadSkillsError!app_runtime_setup.LoadedSkills;
        const WelcomeMessageFn = *const fn (Allocator) anyerror![]u8;
        const BeginFreshPersistedSessionFn = *const fn (*App) anyerror!void;
        const EnableSessionStoresFn = *const fn (*App) void;
        bootstrap_interactive_app: BootstrapInteractiveAppFn,
        configure_session_preferences: ConfigureSessionPreferencesFn,
        initialize_persistence: InitializePersistenceFn,
        load_skills: LoadSkillsFn,
        skill_root_policy: skill_contract.RootPolicy,
        welcome_message: WelcomeMessageFn,
        begin_fresh_persisted_session: BeginFreshPersistedSessionFn,
        enable_session_stores: EnableSessionStoresFn,
        terminal_title: host.TerminalTitle,
    };
}

pub fn Runtime(comptime App: type) type {
    return struct {
        pub const LaunchOverrides = struct {
            provider: ?model_provider.ProviderId = null,
            model: ?[]const u8 = null,
            effort: ?types.ReasoningEffort = null,
            fast: ?bool = null,
            ultrafast: ?bool = null,
            /// Borrowed from the launch arguments; StartupState dupes on apply.
            provider_order: ?[]const []const u8 = null,
            provider_strict: ?bool = null,
        };

        pub fn bootstrap(
            app: *App,
            footer_rows: u16,
            default_model: []const u8,
            default_agent_step_limit: usize,
            resize_handler: app_lifecycle.ResizeHandler,
            capability_providers: CapabilityProviders,
            launch_overrides: LaunchOverrides,
        ) !void {
            try bootstrapWithDeps(
                app,
                footer_rows,
                default_model,
                default_agent_step_limit,
                resize_handler,
                defaultDeps(capability_providers),
                launch_overrides,
            );
        }

        fn defaultDeps(capability_providers: CapabilityProviders) BootstrapDeps(App) {
            return .{
                .bootstrap_interactive_app = bootstrapInteractiveAppDefault,
                .configure_session_preferences = configureSessionPreferencesDefault,
                .initialize_persistence = initializePersistenceDefault,
                .load_skills = app_runtime_setup.loadSkills,
                .skill_root_policy = capability_providers.skill_root_policy,
                .welcome_message = welcomeMessageDefault,
                .begin_fresh_persisted_session = beginFreshPersistedSessionDefault,
                .enable_session_stores = enableSessionStoresDefault,
                .terminal_title = capability_providers.terminal_title,
            };
        }

        fn bootstrapInteractiveAppDefault(cfg: app_lifecycle.BootstrapConfig) !app_lifecycle.StartupState {
            return app_lifecycle.bootstrapInteractiveApp(cfg);
        }

        fn initializePersistenceDefault(
            app: *App,
            required: bool,
        ) !void {
            try app_session_runtime.Runtime(App).initializePersistence(
                app,
                required,
            );
        }

        fn configureSessionPreferencesDefault(
            app: *App,
            provider: model_provider.ProviderId,
            configured_model: []const u8,
            model_source: config_runtime.ModelSource,
            selected_model: []const u8,
            effort: types.ReasoningEffort,
            fast_mode: bool,
            fast_mode_model_bound: bool,
            configured_ultrafast_mode: bool,
            ultrafast_process_override: ?bool,
            effort_process_override: ?types.ReasoningEffort,
            fast_process_override: ?bool,
            provider_process_override: ?model_provider.ProviderId,
        ) !void {
            try app_session_runtime.Runtime(App).configureStartupPreferences(
                app,
                provider,
                configured_model,
                model_source,
                selected_model,
                effort,
                fast_mode,
                fast_mode_model_bound,
                configured_ultrafast_mode,
                ultrafast_process_override,
                effort_process_override,
                fast_process_override,
                provider_process_override,
            );
        }

        fn welcomeMessageDefault(alloc: Allocator) ![]u8 {
            return ui_render.welcomeMessage(alloc);
        }

        fn beginFreshPersistedSessionDefault(app: *App) !void {
            try app_session_runtime.Runtime(App).beginFreshPersistedSession(app);
        }

        fn enableSessionStoresDefault(app: *App) void {
            app_session_runtime.Runtime(App).enableSessionStores(app);
        }

        // Neutral one-line summary inline; the full detail stays behind Ctrl+O.
        fn writeCollapsedStartupNotice(app: *App, topic: []const u8, summary_lead: []const u8, detail: []const u8) !void {
            const summary = try app.alloc.print("{s} (ctrl+o to view)", .{summary_lead});
            defer app.alloc.free(summary);
            try app.writeDomainNotice(.{ .topic = topic, .tone = .neutral, .body = summary }, true);
            try app.writeDomainNotice(.{ .topic = topic, .tone = .neutral, .body = detail, .visibility = .full_only }, true);
        }

        /// Starts skill discovery on the catalog refresh worker so the first
        /// frame does not wait for it, and queues the discovery notice for
        /// when it lands. Prompts already wait for a current catalog. Returns
        /// false when the host loads skills inline.
        fn beginStartupSkillsLoad(app: *App) !bool {
            if (comptime !@hasDecl(App, "requestSkillsRefresh")) return false;
            const dir = (try app_runtime_setup.resolveManagedSkillsDir(std.heap.c_allocator)) orelse return false;
            // An empty catalog records the managed directory the refresh scans.
            app.skills.replaceLoaded(std.heap.c_allocator, dir, &.{}, &.{}) catch |err| {
                std.heap.c_allocator.free(dir);
                return err;
            };
            const generation = try app.requestSkillsRefresh();
            try app.skills.queueRefreshAction(std.heap.c_allocator, generation, .startup_notice);
            return true;
        }

        /// Reports skill discovery issues inline and to the model's context.
        pub fn writeSkillDiagnosticsNotice(app: *App) !void {
            if (app.skills.diagnostics.len == 0) return;
            var notice_writer: std.Io.Writer.Allocating = .init(app.alloc);
            defer notice_writer.deinit();
            skill_runtime.writeDiagnosticSummary(app.alloc, &notice_writer.writer, app.skills.diagnostics) catch return error.OutOfMemory;
            const skills_body = notice_writer.toOwnedSlice() catch return error.OutOfMemory;
            defer app.alloc.free(skills_body);
            if (comptime @hasField(App, "session") and @hasDecl(@TypeOf(app.session), "claimContextNotice")) {
                _ = try app.session.claimContextNotice(app.alloc, skills_body);
            }

            const skills_summary = try app.alloc.print("{d} discovery issue{s}; some skills may be missing", .{
                app.skills.diagnostics.len,
                if (app.skills.diagnostics.len == 1) "" else "s",
            });
            defer app.alloc.free(skills_summary);
            try writeCollapsedStartupNotice(app, "skills", skills_summary, skills_body);
        }

        /// Writes one full-only record describing what this session assembled:
        /// provider/model/effort, system prompt size, advertised tools, skill
        /// catalog size. Live-session only; resume does
        /// not replay it, matching other full-only startup detail.
        fn writeSessionAssemblyNotice(app: *App, provider_label: []const u8) !void {
            const system_prompt_bytes: ?usize = if (comptime @hasDecl(App, "promptPolicy"))
                app.promptPolicy().system_prompt.len
            else
                null;
            const tool_names: []const []const u8 = if (comptime @hasDecl(App, "toolAdvertisementSet"))
                app.toolAdvertisementSet().order
            else
                &.{};
            const effort_label: []const u8 = if (comptime @hasField(App, "effort"))
                app.effort.label()
            else
                "auto";
            var body: std.Io.Writer.Allocating = .init(app.alloc);
            defer body.deinit();
            try writeSessionAssemblyBody(&body.writer, .{
                .provider = provider_label,
                .model = provider_runtime.model(app),
                .effort = effort_label,
                .system_prompt_bytes = system_prompt_bytes,
                .tool_names = tool_names,
                .skill_count = if (app.skills.refreshActive()) null else app.skills.items.len,
            });
            try app.shell.appendFullDetailRecord(app.alloc, .{
                .topic = "session",
                .tone = .neutral,
                .body = body.written(),
                .visibility = .full_only,
            });
        }

        fn bootstrapWithDeps(
            app: *App,
            footer_rows: u16,
            default_model: []const u8,
            default_agent_step_limit: usize,
            resize_handler: app_lifecycle.ResizeHandler,
            deps: BootstrapDeps(App),
            launch_overrides: LaunchOverrides,
        ) !void {
            errdefer app.deinit();

            var startup = try deps.bootstrap_interactive_app(.{
                .alloc = app.alloc,
                .terminal = &app.terminal,
                .shell = &app.shell,
                .metrics = &app.metrics,
                .terminal_title = deps.terminal_title,
                .footer_rows = footer_rows,
                .startup_min_body_rows = ui_render.welcome_message_reserved_rows,
                .default_model = default_model,
                .default_agent_step_limit = default_agent_step_limit,
                .auth_mode = if (comptime @hasDecl(@TypeOf(app.auth), "authMode"))
                    app.auth.authMode()
                else
                    .local,
                .resize_handler = resize_handler,
                .fx_version = App.app_version,
                .provider_override = launch_overrides.provider,
                .model_override = launch_overrides.model,
            });
            defer startup.deinit(app.alloc);

            if (launch_overrides.model) |model| {
                try startup.applyLaunchModelOverride(app.alloc, model);
            }

            app.workspace_root = startup.takeWorkspaceRoot();
            if (comptime @hasDecl(App, "adoptWorkspaceAccess")) {
                app.adoptWorkspaceAccess(startup.takeWorkspaceAccess());
            }
            if (startup.takeCredential()) |credential_value| {
                var credential = credential_value;
                defer credential.deinit(app.alloc);
                _ = app.auth.adoptCredential(app.alloc, &credential);
            }
            app.auth.recordStartupStatus(
                startup.credential_load_failure,
                startup.credential_onboarding_skipped,
            );
            // An active credential needs no onboarding, so a fresh launch probes
            // the other sources after its first frame.
            const can_defer_inventory = comptime @hasDecl(@TypeOf(app.auth), "deferStartupSourceInventory");
            const inventory_deferred = can_defer_inventory and
                app.requested_resume == null and
                app.auth.view().active_source != null;
            if (comptime can_defer_inventory) {
                if (inventory_deferred) app.auth.deferStartupSourceInventory();
            }
            if (!inventory_deferred) {
                if (comptime @hasDecl(@TypeOf(app.auth), "refreshSourceInventory")) {
                    app.auth.refreshSourceInventory(app.alloc) catch |err| {
                        debug_trace.logf("auth", "startup source inventory refresh failed err={s}", .{@errorName(err)});
                    };
                } else if (comptime @hasDecl(@TypeOf(app.auth), "refreshChatGptSourceInventory")) {
                    app.auth.refreshChatGptSourceInventory(app.alloc) catch |err| {
                        debug_trace.logf("auth", "startup source inventory refresh failed err={s}", .{@errorName(err)});
                    };
                }
                const startup_auth_view = app.auth.view();
                if (startup_auth_view.active_source == null and !startup_auth_view.onboarding_skipped) {
                    app.auth.openOnboardingPicker(app.alloc);
                }
            }
            if (comptime @hasField(App, "terminal_input_runtime") and @hasField(App, "terminal")) {
                // Own theme protocol bytes even under FX_THEME; probing stays gated.
                app.terminal_input_runtime.terminal_theme_monitor.start();
                if (startup.theme_monitor_enabled) {
                    app.terminal.enableThemeNotifications() catch |err| {
                        debug_trace.logf("theme", "theme_notification_enable_failed err={s}", .{@errorName(err)});
                    };
                    app.terminal.requestThemeColorScheme() catch |err| {
                        debug_trace.logf("theme", "theme_color_scheme_query_failed err={s}", .{@errorName(err)});
                    };
                }
            }
            var prompt_history_unavailable = false;
            if (comptime @hasField(App, "prompt_history")) {
                prompt_history_unavailable =
                    (try app.prompt_history.initialize(
                        app.alloc,
                        shared_io.getenv("HOME"),
                        startup.prompt_history_enabled,
                        startup.prompt_history_store_allowed,
                    )) == .unavailable;
            }
            if (comptime @hasField(App, "session") and
                @hasDecl(@TypeOf(app.session), "initializeProfileUsage"))
            {
                _ = try app.session.initializeProfileUsage(
                    app.alloc,
                    shared_io.getenv("HOME"),
                );
            }

            var selected_model = startup.takeSelectedModel();
            defer if (selected_model.len > 0) app.alloc.free(selected_model);
            if (comptime @hasField(App, "provider_selection")) {
                app.provider_selection.model_requests_blocked = startup.model_requests_blocked;
                app.provider_selection.definitions = startup.configured_providers;
                startup.configured_providers = .{};
                app.provider_selection.adoptOwned(startup.provider, &selected_model);
            } else {
                try provider_runtime.replaceModel(app, selected_model);
            }
            const active_model = provider_runtime.model(app);
            // Per-launch --effort/--fast flags shape runtime state only; the
            // configured and stored preferences keep their pre-flag values.
            const persisted_effort = startup.effort;
            const persisted_fast_mode = startup.fast_mode;
            const persisted_ultrafast_mode = startup.configured_ultrafast_mode;
            startup.applyLaunchTurnOverrides(launch_overrides.effort, launch_overrides.fast, launch_overrides.ultrafast);
            if (launch_overrides.provider_order != null or launch_overrides.provider_strict != null) {
                try startup.applyLaunchProviderRouting(app.alloc, launch_overrides.provider_order, launch_overrides.provider_strict);
            }
            try deps.configure_session_preferences(
                app,
                startup.provider,
                startup.configured_model,
                startup.model_source,
                active_model,
                persisted_effort,
                persisted_fast_mode,
                startup.fast_mode_model_bound,
                persisted_ultrafast_mode,
                startup.ultrafast_process_override,
                launch_overrides.effort,
                launch_overrides.fast,
                launch_overrides.provider,
            );
            app.permission_engine.mode = startup.permission_mode;
            app.permission_engine.replaceRules(app.alloc, startup.takePermissionRules());
            app.agent_step_limit = startup.agent_step_limit;
            app.worker.agent_turn_settings.max_tool_result_bytes = startup.max_tool_result_bytes;
            app.worker.agent_turn_settings.auto_compact_percent = startup.auto_compact_percent;
            if (comptime @hasField(App, "context_limits")) app.context_limits = startup.context_limits;
            app.worker.agent_turn_settings.first_call_tool_choice = startup.first_call_tool_choice;
            app.worker.agent_turn_settings.fast_mode = startup.fast_mode;
            app.worker.agent_turn_settings.ultrafast_mode = startup.ultrafast_mode;
            app.worker.agent_turn_settings.effort = startup.effort;
            // Worker-owned memory uses the C allocator, matching worker deinit.
            try app.worker.setProviderRouting(std.heap.c_allocator, startup.provider_order, startup.provider_strict);
            app.context_enabled = startup.context_enabled;
            app.fast_mode = startup.fast_mode;
            app.input_runtime.slash_menu_categories = startup.slash_menu_categories;
            app.shell.collapse_tool_calls = startup.collapse_tool_calls;
            app.auto_upgrade_enabled = startup.auto_upgrade;
            app.upgrader.configure_channel(startup.update_channel);
            app.effort = startup.effort;
            if (comptime @hasField(App, "review_model")) app.review_model = startup.takeReviewModel();
            app.shell.setCommandOutputRenderPolicy(
                app_render_runtime.Runtime(App).shellStyles(),
            );
            app.permission_state.yolo_acknowledged = startup.yolo_acknowledged;
            app_permission_runtime.Runtime(App).initializeYoloWarning(app);
            app.statusline_context = startup.statusline_context;
            app.statusline_session = startup.statusline_session;
            if (comptime @hasField(App, "session_title_generation")) {
                app.session_title_generation = startup.session_title_generation;
            }
            if (comptime @hasField(App, "workspace_identity")) {
                app.workspace_identity.enabled = startup.statusline_workspace;
            }
            if (comptime @hasDecl(App, "setNotificationPreferences")) {
                app.setNotificationPreferences(
                    startup.notification_turn_end,
                    startup.notification_attention_required,
                    startup.notification_max,
                );
            }
            try deps.initialize_persistence(
                app,
                app.requested_resume != null,
            );

            const skills_deferred = try beginStartupSkillsLoad(app);
            if (!skills_deferred) {
                var loaded = try deps.load_skills(
                    std.heap.c_allocator,
                    app.workspace_root,
                    deps.skill_root_policy,
                );
                errdefer loaded.deinit(std.heap.c_allocator);
                skill_runtime.traceDiagnostics("interactive_startup", loaded.diagnostics);
                try app.skills.replaceLoaded(std.heap.c_allocator, loaded.dir, loaded.skills, loaded.diagnostics);
                loaded = .{};
            }

            if (app.requested_resume == null) {
                const welcome_message = try deps.welcome_message(app.alloc);
                defer app.alloc.free(welcome_message);
                var welcome_preview_buf: [96]u8 = undefined;
                const welcome_preview = debug_trace.terminalPreview(welcome_preview_buf[0..], welcome_message);
                debug_trace.logf(
                    "paint",
                    "welcome_write bytes={d} reserved_rows={d} has_version={s} has_help={s} has_feedback={s} preview=\"{s}\"",
                    .{
                        welcome_message.len,
                        ui_render.welcome_message_reserved_rows,
                        if (std.mem.find(u8, welcome_message, " v") != null) "true" else "false",
                        if (std.mem.find(u8, welcome_message, "Run /help") != null) "true" else "false",
                        if (std.mem.find(u8, welcome_message, "Feedback?") != null) "true" else "false",
                        welcome_preview,
                    },
                );
                try app.writeTranscriptClassified(welcome_message, true, .welcome);
                // Fresh sessions only: on resume the transcript must stay
                // empty until the deferred session load replays history.
                try writeSessionAssemblyNotice(app, startup.provider.label());
            }
            // A deferred catalog reports its discovery issues when it lands.
            if (!skills_deferred) try writeSkillDiagnosticsNotice(app);
            if (comptime @hasField(App, "auth")) {
                try app_auth_runtime.Runtime(App).writeStartupCredentialFailure(app, startup.provider, startup.credential_load_failure);
            }
            var recording = try record_tape.captureStatus(app.alloc);
            defer recording.deinit(app.alloc);
            if (recording == .active) {
                const recording_body = try app.alloc.print(
                    "visual terminal capture: {s}\nvisible terminal content, including typed prompt text, is recorded",
                    .{recording.active.path},
                );
                defer app.alloc.free(recording_body);
                try app.writeDomainNotice(.{
                    .topic = "recording",
                    .tone = .warning,
                    .body = recording_body,
                    .visibility = if (recording.active.show_inline_notice) .compact_and_full else .full_only,
                }, true);
            }
            {
                var detail_writer: std.Io.Writer.Allocating = .init(app.alloc);
                defer detail_writer.deinit();
                var reported: usize = 0;
                for (startup.config_diagnostics) |diagnostic| {
                    if (!diagnostic.reportAtStartup()) continue;
                    if (reported > 0) try detail_writer.writer.writeByte('\n');
                    try detail_writer.writer.print(
                        "{s}: {s}",
                        .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
                    );
                    try config_runtime.writeDiagnosticMetadata(&detail_writer.writer, diagnostic);
                    reported += 1;
                }
                if (reported > 0) {
                    const summary = try app.alloc.print("{d} configuration issue{s}", .{
                        reported,
                        if (reported == 1) "" else "s",
                    });
                    defer app.alloc.free(summary);
                    try writeCollapsedStartupNotice(app, "config", summary, detail_writer.written());
                }
            }
            if (comptime @hasField(App, "prompt_history")) {
                if (prompt_history_unavailable) {
                    try app.writeDomainNotice(.{
                        .topic = "history",
                        .tone = .warning,
                        .body = "durable prompt history unavailable",
                    }, true);
                } else {
                    app_input_runtime.Runtime(App).loadAndInstallPromptHistory(
                        app,
                    ) catch |err| {
                        app.prompt_history.writes_available = false;
                        debug_trace.logf(
                            "prompt_history",
                            "startup load failed err={s}",
                            .{@errorName(err)},
                        );
                        const history_body = try app.alloc.print(
                            "failed to load durable prompt history ({s})",
                            .{@errorName(err)},
                        );
                        defer app.alloc.free(history_body);
                        try app.writeDomainNotice(.{
                            .topic = "history",
                            .tone = .warning,
                            .body = history_body,
                        }, true);
                    };
                }
            }

            if (app.requested_resume == null) {
                try deps.begin_fresh_persisted_session(app);
                deps.enable_session_stores(app);
                app_session_runtime.Runtime(App).syncTerminalTitleWith(app, deps.terminal_title);
            }

            app.shell.render_requests.request(.first_frame);
        }
    };
}

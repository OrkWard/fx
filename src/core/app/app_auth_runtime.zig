const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const credentials = @import("../auth/credentials.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const login_flow = @import("../auth/login_flow.zig");
const chatgpt_oauth = @import("../auth/chatgpt_oauth.zig");
const grok_oauth = @import("../auth/grok_oauth.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const auth_transition = @import("../auth/auth_transition.zig");
const model_provider = @import("../config/model_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_runtime = @import("provider_runtime.zig");
const picker_state = @import("../input/picker_state.zig");
const provider_picker_runtime = @import("provider_picker_runtime.zig");
const types = @import("../shared/types.zig");

const ProviderSwitchIntent = auth_transition.ProviderSwitchIntent;
const decideProviderSwitch = auth_transition.decideProviderSwitch;
const provider_busy_message = "Provider switching is unavailable until active and queued work finishes.";

fn providerFailureMessage(
    intent: ProviderSwitchIntent,
    ordinary: []const u8,
    after_oauth: []const u8,
) []const u8 {
    return if (intent == .post_oauth) after_oauth else ordinary;
}

fn selectCatalogModel(
    entries: []const model_catalog.ModelCatalogEntry,
    primary: ?[]const u8,
    secondary: ?[]const u8,
) ?[]const u8 {
    for ([_]?[]const u8{ primary, secondary }) |maybe_candidate| {
        const candidate = maybe_candidate orelse continue;
        for (entries) |entry| {
            if (std.mem.eql(u8, candidate, entry.id)) return entry.id;
        }
    }
    return if (entries.len > 0) entries[0].id else null;
}

fn optionalGatewayApiKey(credential: anytype) ?[]const u8 {
    if (comptime @typeInfo(@TypeOf(credential.api_key)) == .optional) {
        return credential.api_key;
    }
    return credential.api_key;
}

fn gatewayCredentialSource(credential: anytype) ?credentials.Source {
    if (comptime @hasField(@TypeOf(credential), "source")) {
        return credential.source;
    }
    return null;
}

fn hostManagesAuth(app: anytype) bool {
    if (comptime @hasDecl(@TypeOf(app.auth), "isHostManaged")) {
        return app.auth.isHostManaged();
    }
    return false;
}

const TeamCatalogValidation = union(enum) {
    rejected,
    accepted: ?[]u8,

    fn deinit(self: *TeamCatalogValidation, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .accepted => |model| if (model) |owned| alloc.free(owned),
            .rejected => {},
        }
        self.* = undefined;
    }
};

pub const PendingPromptCredentialReadiness = enum {
    pending,
    current,
    rejected,
};

pub fn Runtime(comptime App: type) type {
    return struct {
        fn compactionOwnsCredentialFeedback(app: *const App) bool {
            return if (comptime @hasField(App, "submission")) app.submission.compaction_pending else false;
        }

        fn ensurePromptCredential(app: *App) !bool {
            if (comptime @hasField(App, "provider_selection")) {
                if (app.provider_selection.model_requests_blocked) {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = "Repair profile settings and restart fx before sending a message.",
                    });
                    return false;
                }
            }
            if (try rejectPendingPreparation(app)) return false;
            if (comptime provider_runtime.supported(App) and
                @hasDecl(@TypeOf(app.auth), "selectForProvider"))
            {
                const provider = provider_runtime.provider(app);
                if (provider == .configured or !model_provider.authorizesCredential(provider, app.auth.credentialSource())) {
                    const selection = selectProviderCredential(app, provider) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        debug_trace.logf("auth", "prompt credential preference load failed err={s}", .{@errorName(err)});
                        if (compactionOwnsCredentialFeedback(app)) return false;
                        try writeAuthNotice(app, .{
                            .topic = "auth",
                            .tone = .@"error",
                            .body = "Could not load authentication settings. Check user settings, then press enter to retry.",
                        });
                        return false;
                    };
                    switch (selection) {
                        .selected => applyCredentialChange(app, true),
                        .unchanged => {},
                        .failed => |failure| return recoverCredentialFailure(app, failure.source, failure.err),
                        .missing => return missingPromptCredential(app, provider),
                    }
                }
            }
            if (app.auth.credentialSource() != null) return true;
            return missingPromptCredential(app, .gateway);
        }

        fn selectProviderCredential(app: *App, provider: model_provider.ProviderId) !auth_runtime.ProviderCredentialSelection {
            if (hostManagesAuth(app) or (provider != .configured and model_provider.authorizesCredential(provider, app.auth.credentialSource()))) return .unchanged;
            var preferred: ?credentials.Source = null;
            if (provider == .gateway) {
                var settings = try config_runtime.loadMergedSettings(app.alloc, app.workspace_root);
                defer settings.deinit(app.alloc);
                preferred = settings.credential_source;
            }
            return app.auth.selectForProvider(app.alloc, provider, preferred);
        }

        pub fn restoreSessionCredential(app: *App, previous_provider: model_provider.ProviderId) !void {
            // Hydration can run before App.init returns, so it must not start background tasks.
            const provider = provider_runtime.provider(app);
            const provider_changed = !previous_provider.same_authority(provider);
            if (provider_changed) {
                app.auth.cancelPromptCredentialRefresh();
                app.model_cache.resetForProviderChange();
            }
            if (hostManagesAuth(app)) return;
            const selection = selectProviderCredential(app, provider) catch |err| {
                if (err == error.OutOfMemory) return err;
                debug_trace.logf("auth", "resumed credential preference load failed err={s}", .{@errorName(err)});
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Could not load authentication settings for the resumed session. Check user settings and retry.",
                }, true);
                app.shell.render_requests.request(.footer);
                return;
            };
            switch (selection) {
                .selected => app.model_cache.reset(),
                .unchanged => {},
                .missing => try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = switch (provider) {
                        .gateway => credentials.missing_interactive_credential_message,
                        .codex => credentials.missing_chatgpt_interactive_credential_message,
                        .grok => credentials.missing_grok_interactive_credential_message,
                        .configured => "Configured provider authentication is unavailable. Check settings.json and its environment variable.",
                    },
                }, true),
                .failed => |failure| {
                    const classified = auth_runtime.classifyCredentialFailure(failure.source, failure.err);
                    const message = if (auth_runtime.preparationError(classified)) |err|
                        auth_runtime.preparationFailureNotice(err).?
                    else
                        "Authentication is unavailable. Run /provider to repair this source.";
                    debug_trace.logf("auth", "resumed credential unavailable source={t} err={s}", .{ failure.source, @errorName(failure.err) });
                    const body = try app.alloc.print("{s}: {s}", .{ credentials.sourceLabel(failure.source), message });
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{ .topic = "auth", .tone = .@"error", .body = body }, true);
                },
            }
            app.shell.render_requests.request(.footer);
        }

        fn missingPromptCredential(app: *App, provider: model_provider.ProviderId) !bool {
            if (provider != .gateway) {
                if (compactionOwnsCredentialFeedback(app)) return false;
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = if (provider == .configured)
                        "Configured provider authentication is unavailable. Check settings.json and its environment variable."
                    else if (provider == .grok)
                        credentials.missing_grok_interactive_credential_message
                    else
                        credentials.missing_chatgpt_interactive_credential_message,
                }, true);
                app.shell.render_requests.request(.footer);
                return false;
            }

            const auth_view = app.auth.view();
            if (auth_view.onboarding_skipped) {
                if (compactionOwnsCredentialFeedback(app)) return false;
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = credentials.missing_interactive_credential_message,
                }, true);
            } else if (!app.auth.pickerView().active) {
                try app.auth.refreshSourceInventory(app.alloc);
                app.auth.openOnboardingPicker(app.alloc);
            }
            app.shell.render_requests.request(.footer);
            return false;
        }

        pub fn runLoginCommand(app: *App) !void {
            if (hostManagesAuth(app)) {
                try writeAuthNotice(app, .{ .topic = "auth", .tone = .neutral, .body = credentials.host_managed_auth_message });
                return;
            }
            try beginProviderPickerInventoryRefresh(app, .provider_picker_login);
        }

        pub fn runLogoutCommand(app: *App, target: []const u8) !void {
            if (try rejectPendingPreparation(app)) return;
            if (hostManagesAuth(app)) {
                try writeAuthNotice(app, .{ .topic = "auth", .tone = .neutral, .body = credentials.host_managed_auth_message });
                return;
            }
            const requested_provider = if (std.mem.trim(u8, target, " \t\r\n").len == 0)
                null
            else
                provider_catalog.parse(std.mem.trim(u8, target, " \t\r\n")) orelse {
                    try writeAuthNotice(app, .{
                        .topic = "",
                        .tone = .warning,
                        .body = "usage: /logout [vercel|codex|grok]",
                    });
                    return;
                };
            try app.flushBeforeBlockingExternalWork();
            const selected_provider: model_provider.ProviderId = if (comptime provider_runtime.supported(App))
                provider_runtime.provider(app)
            else
                .gateway;
            const provider_inventory = if (comptime @hasDecl(@TypeOf(app.auth), "pickerView")) inventory: {
                try app.auth.refreshSourceInventory(app.alloc);
                break :inventory app.auth.pickerView().available_sources;
            } else @as(auth_runtime.SourceSet, .empty);
            const logout_provider = auth_transition.decideLogoutProvider(.{
                .requested = requested_provider,
                .selected = selected_provider,
                .active_source = app.auth.credentialSource(),
                .available_sources = provider_inventory,
            });
            const hold_turn_start = logout_provider.eql(selected_provider) and logout_provider != .gateway;
            if (hold_turn_start and (app.stream.active or !app.worker.tryHoldTurnStart())) {
                try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Sign out is unavailable until active and queued work finishes.",
                });
                return;
            }
            defer if (hold_turn_start) app.worker.releaseTurnStartHold();
            if (logout_provider == .grok) {
                const outcome = grok_oauth.logout(app.alloc, app.auth.oauthTransport()) catch {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = "Could not durably sign out of Grok. The current source is unchanged.",
                    });
                    return;
                };
                const changed = if (comptime @hasDecl(@TypeOf(app.auth), "reconcileAfterGrokLogout"))
                    try app.auth.reconcileAfterGrokLogout(app.alloc)
                else
                    false;
                applyCredentialChange(app, changed);
                try writeAuthNotice(app, switch (outcome.deletion) {
                    .deleted => .{ .topic = "auth", .tone = .neutral, .body = "Signed out of Grok." },
                    .missing => .{ .topic = "auth", .tone = .neutral, .body = "No Grok login session found." },
                    .deleted_not_durable => .{ .topic = "auth", .tone = .warning, .body = "Signed out of Grok, but could not confirm the profile directory update." },
                });
                if (outcome.revocation_failed) {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .warning,
                        .body = "The local Grok session was removed, but remote revocation could not be confirmed.",
                    });
                }
                try reconcileSubscriptionLogout(app, .grok);
                return;
            }
            if (logout_provider == .codex) {
                const outcome = chatgpt_oauth.logout() catch {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = "Could not durably sign out of Codex. The current source is unchanged.",
                    });
                    return;
                };
                const changed = if (comptime @hasDecl(@TypeOf(app.auth), "reconcileAfterChatGptLogout"))
                    try app.auth.reconcileAfterChatGptLogout(app.alloc)
                else
                    false;
                applyCredentialChange(app, changed);
                try writeAuthNotice(app, switch (outcome) {
                    .deleted => .{ .topic = "auth", .tone = .neutral, .body = "Signed out of Codex." },
                    .missing => .{ .topic = "auth", .tone = .neutral, .body = "No Codex login session found." },
                    .deleted_not_durable => .{ .topic = "auth", .tone = .warning, .body = "Signed out of Codex, but could not confirm the profile directory update." },
                });
                try reconcileSubscriptionLogout(app, .codex);
                return;
            }
            const result = login_flow.logout(app.alloc, app.auth.oauthTransport()) catch |err| switch (err) {
                error.SessionDeleteFailed => {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = "Could not complete fx logout. The current source is unchanged.",
                    });
                    return;
                },
            };
            try applyLogoutResult(app, result);
        }

        fn reconcileSubscriptionLogout(app: *App, removed: model_provider.ProviderId) !void {
            const selected = provider_runtime.provider(app);
            if (!selected.eql(removed)) return;
            const candidates = auth_transition.logoutFallbackProviders(.{
                .requested = removed,
                .selected = selected,
                .active_source = app.auth.credentialSource(),
                .available_sources = app.auth.pickerView().available_sources,
            });
            if (candidates[0]) |target| {
                try startProviderSwitch(app, target, false, .manual, candidates[1]);
                return;
            }
            try app.writeDomainNotice(.{
                .topic = "provider",
                .tone = .warning,
                .body = "No connected provider is available. Use /provider to sign in.",
            }, true);
        }

        pub fn runProviderCommand(app: *App) !void {
            try beginProviderPickerInventoryRefresh(app, .provider_picker_command);
        }

        pub fn openSetupHub(app: *App) !void {
            if (hostManagesAuth(app)) {
                try writeAuthNotice(app, .{ .topic = "auth", .tone = .neutral, .body = credentials.host_managed_auth_message });
                return;
            }
            switch (app.auth.beginSourceInventoryRefresh(app.alloc, .{
                .provider = provider_runtime.provider(app),
            })) {
                .started => {},
                .busy => try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Authentication inventory refresh is already in progress.",
                }),
                .failed => try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Authentication sources could not be checked. The picker remains closed.",
                }),
            }
        }

        /// Reports blocked provider interaction without changing the composer.
        pub fn reject_provider_picker_if_busy(app: *App) !bool {
            if (!auth_transition.provider_work_busy(app.stream.active, app.worker.queuedPromptCount())) return false;
            try app.writeDomainNotice(.{
                .topic = "provider",
                .tone = .neutral,
                .body = provider_busy_message,
            }, true);
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn beginProviderPickerInventoryRefresh(
            app: *App,
            destination: auth_runtime.InventoryRefreshDestination,
        ) !void {
            if (try reject_provider_picker_if_busy(app)) return;
            const prefix = switch (destination) {
                .provider_picker_login => picker_state.login_prefix,
                .provider_picker_command => picker_state.provider_prefix,
                .auth_picker => unreachable,
            };
            var prepared = try app.input_runtime.textReplacementState().prepare(app.alloc, prefix);
            defer prepared.deinit(app.alloc);
            switch (app.auth.beginSourceInventoryRefresh(app.alloc, .{
                .provider = provider_runtime.provider(app),
                .destination = destination,
            })) {
                .started => {
                    app.input_runtime.textReplacementState().commit(app.alloc, &prepared);
                    app.shell.render_requests.request(.footer);
                },
                .busy => try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Authentication inventory refresh is already in progress.",
                }),
                .failed => try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Authentication sources could not be checked. The picker remains closed.",
                }),
            }
        }

        /// Explains a launch credential that could not be loaded, once the
        /// launch lookup has settled without an active source.
        pub fn writeStartupCredentialFailure(
            app: *App,
            provider: model_provider.ProviderId,
            load_failure: ?credentials.LoadFailure,
        ) !void {
            const auth_view = app.auth.view();
            const load_error: anyerror = if (load_failure) |failure|
                failure.err
            else if (auth_view.stored_key_status == .unavailable or auth_view.fx_login_status == .unavailable)
                error.CredentialStorageUnavailable
            else
                return;
            if (auth_view.active_source != null) return;
            const body = try auth_runtime.preparationFailureText(app.alloc, provider, load_error);
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{
                .topic = "auth",
                .tone = .warning,
                .body = body,
            }, true);
        }

        pub fn startupCredentialPending(app: *const App) bool {
            if (comptime !@hasDecl(@TypeOf(app.auth), "startupCredentialPending")) return false;
            return app.auth.startupCredentialPending();
        }

        /// Probes the launch source inventory once the first frame is on screen.
        pub fn collectDeferredStartupInventory(app: *App) void {
            if (comptime !@hasDecl(@TypeOf(app.auth), "takeDeferredStartupSourceInventory")) return;
            if (app.shell.render_requests.hasReason(.first_frame)) return;
            if (!app.auth.takeDeferredStartupSourceInventory()) return;
            app.auth.refreshSourceInventory(app.alloc) catch |err| {
                debug_trace.logf("auth", "startup source inventory refresh failed err={s}", .{@errorName(err)});
            };
            app.shell.render_requests.request(.footer);
        }

        /// Settles the launch credential that was resolved after the first
        /// frame, in the order the blocking launch path settles it before
        /// its first frame: adoption, status, inventory, onboarding, notice.
        pub fn collectStartupCredentialFacts(app: *App) !void {
            if (comptime !@hasDecl(@TypeOf(app.auth), "takeStartupCredentialLoad")) return;
            var outcome = app.auth.takeStartupCredentialLoad() orelse return;
            defer outcome.deinit();
            // The blocking path aborts launch on these errors; only allocation
            // failure can reach here for a Keychain-backed Gateway lookup.
            const resolution = switch (outcome) {
                .failed => |err| return err,
                .resolved => |*resolution| resolution,
            };

            var adopted = false;
            if (resolution.credential) |*credential| {
                if (app.auth.credentialSource()) |selected| {
                    debug_trace.logf("auth", "startup credential dropped source={t} reason=selected_during_load selected={t}", .{ credential.source, selected });
                } else {
                    var owned = try credential.clone(app.alloc);
                    defer owned.deinit(app.alloc);
                    adopted = app.auth.adoptCredential(app.alloc, &owned);
                }
            }
            app.auth.recordStartupStatus(
                resolution.stored_key_status,
                resolution.fx_login_status,
                resolution.failure,
                app.auth.view().onboarding_skipped,
            );
            app.auth.refreshSourceInventory(app.alloc) catch |err| {
                debug_trace.logf("auth", "startup source inventory refresh failed err={s}", .{@errorName(err)});
            };
            const auth_view = app.auth.view();
            if (auth_view.active_source == null and !auth_view.onboarding_skipped and !app.auth.pickerView().active) {
                app.auth.openOnboardingPicker(app.alloc);
            }
            const provider = if (comptime provider_runtime.supported(App)) provider_runtime.provider(app) else .gateway;
            try writeStartupCredentialFailure(app, provider, resolution.failure);

            // Model cache warmup waited for this credential (see startModelCacheWarmup).
            if (adopted) {
                applyCredentialChange(app, true);
            } else if (comptime @hasDecl(App, "startModelCacheWarmup")) {
                app.startModelCacheWarmup();
            }
            // Before the first frame commits, its own hook starts the prewarm.
            if (adopted and !app.shell.render_requests.hasReason(.first_frame)) {
                startPromptCredentialPrewarm(app);
            }
            debug_trace.logf("auth", "startup credential settled adopted={} source={?t}", .{ adopted, auth_view.active_source });
            app.shell.render_requests.request(.footer);
        }

        pub fn collectSourceInventoryFacts(app: *App) !void {
            const result = app.auth.takeSourceInventoryRefresh() orelse return;
            switch (result) {
                .ready => |action| {
                    if (action.destination != .auth_picker and try reject_provider_picker_if_busy(app)) {
                        debug_trace.logf("auth", "provider picker publication dropped destination={t} reason=work_in_progress", .{action.destination});
                        if (comptime @hasField(App, "input_runtime")) {
                            if (app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) != null) {
                                app.input_runtime.picker.dismissInlinePicker(.provider);
                            }
                        }
                        return;
                    }
                    var unavailable = app.auth.pickerView().unavailable_sources.iterator();
                    while (unavailable.next()) |source| {
                        const body = try app.alloc.print(
                            "{s} is unavailable. Check the saved credential or choose another option.",
                            .{credentials.sourceLabel(source)},
                        );
                        defer app.alloc.free(body);
                        try writeAuthNotice(app, .{ .topic = "auth", .tone = .warning, .body = body });
                    }
                    switch (action.destination) {
                        .auth_picker => app.auth.openPickerForProvider(app.alloc, action.provider),
                        .provider_picker_login, .provider_picker_command => {},
                    }
                    app.shell.render_requests.request(.footer);
                },
                .failed => |action| {
                    if (comptime @hasField(App, "input_runtime")) {
                        if (action.destination != .auth_picker and
                            app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) != null)
                        {
                            app.input_runtime.picker.dismissInlinePicker(.provider);
                        }
                    }
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = "Authentication sources could not be checked. The picker was not opened with stale data.",
                    });
                },
            }
        }

        fn applyLogoutResult(app: *App, result: login_flow.LogoutResult) !void {
            // Logging out is an explicit rejection of that credential, so a
            // remembered pointer to it would silently reactivate on next login.
            // A remembered source always wins resolution, so an active fx login
            // is the only way one can be remembered; clearing otherwise is a
            // no-op against a store that holds nothing.
            if (app.auth.credentialSource() == .fx_login) forgetCredentialSource(app);
            applyCredentialChange(app, try app.auth.reconcileAfterFxLoginLogout(app.alloc));
            try writeAuthNotice(app, if (result.local_durability_failed)
                .{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Could not confirm durable fx logout. The active source was recalculated.",
                }
            else if (result.session_deleted)
                .{
                    .topic = "auth",
                    .tone = .neutral,
                    .body = "Signed out of fx.",
                }
            else
                .{
                    .topic = "auth",
                    .tone = .neutral,
                    .body = "No fx login session found.",
                });
            if (result.remote_revocation_failed) {
                try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .warning,
                    .body = login_flow.remote_revocation_warning,
                });
            }
        }

        pub fn applyPickerChoice(app: *App, choice: auth_runtime.Choice) !void {
            if (try rejectPendingPreparation(app)) return;
            switch (choice) {
                .provider => |provider| try switchProvider(app, provider, true, .manual),
                .source => |source| _ = try applySourceChoice(app, source),
                .action => |action| switch (action) {
                    .connections => unreachable,
                    .login => try beginSignIn(app, true),
                    .chatgpt_login => try beginChatGptSignIn(app),
                    .grok_login => try beginGrokSignIn(app),
                    .setup => {
                        prepareApiKeyInputBoundary(app);
                        app.auth.openApiKeyPickerFromRoot(app.alloc);
                    },
                    .change_team => try beginTeamPicker(app),
                    .switch_credential => app.auth.openSwitchCredentialPicker(app.alloc),
                    .switch_provider => app.auth.openProviderPicker(app.alloc, provider_runtime.provider(app)),
                    .automatic => try applyAutomaticCredential(app),
                },
                .team => |index| _ = try applyTeamChoice(app, index),
            }
        }

        pub fn routeAuthPickerByte(app: *App, byte: u8) !bool {
            if (app.auth.signInEntryActive()) {
                if (byte == '\t') {
                    _ = app.auth.toggleSignInCodeEntry();
                } else if (app.auth.signInCodeEntryActive()) {
                    switch (byte) {
                        3, 4 => cancelAndPopPickerStage(app),
                        '\r', '\n' => _ = try app.auth.submitSignInCode(app.alloc),
                        8, 127 => _ = app.auth.deleteSignInCodeByte(),
                        else => _ = try app.auth.appendSignInCodeByte(app.alloc, byte),
                    }
                } else {
                    switch (byte) {
                        3, 4 => cancelAndPopPickerStage(app),
                        '\r', '\n' => try openSignInBrowser(app),
                        else => {},
                    }
                }
                app.shell.render_requests.request(.footer);
                return true;
            }
            if (app.auth.teamPickerActive()) {
                const consumed = switch (byte) {
                    8, 127 => app.auth.deleteTeamQueryByte(),
                    else => try app.auth.appendTeamQueryByte(app.alloc, byte),
                };
                if (consumed) {
                    app.shell.render_requests.request(.footer);
                    return true;
                }
            }
            if (!app.auth.apiKeyEntryActive()) return false;
            switch (byte) {
                3, 4 => cancelAndPopPickerStage(app),
                '\r', '\n' => try submitApiKeyEntry(app),
                8, 127 => _ = app.auth.deleteApiKeyByte(),
                else => _ = try app.auth.appendApiKeyByte(app.alloc, byte),
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn routeAuthPickerEscapeAction(app: *App, action: anytype) bool {
            if (!app.auth.signInEntryActive() and !app.auth.apiKeyEntryActive()) return false;
            return switch (action) {
                .escape, .remapped_byte => false,
                .paste_start => blk: {
                    if (app.auth.signInCodeEntryActive()) break :blk false;
                    if (!app.auth.toggleSignInCodeEntry()) break :blk true;
                    app.shell.render_requests.request(.footer);
                    break :blk false;
                },
                .paste_end => !app.auth.signInCodeEntryActive(),
                else => true,
            };
        }

        fn cancelAndPopPickerStage(app: *App) void {
            cancelPromptRetryAfterAuth(app);
            _ = app.auth.popPickerStage(app.alloc);
        }

        pub fn collectSignInFacts(app: *App) !void {
            const sign_in_source: credentials.Source = if (comptime @hasDecl(@TypeOf(app.auth), "pickerView"))
                app.auth.pickerView().sign_in_source
            else
                .fx_login;
            switch (app.auth.pollSignInTransition(app.alloc)) {
                .none => {},
                .cancelled => {
                    cancelPromptRetryAfterAuth(app);
                    app.shell.render_requests.request(.footer);
                },
                .failed => |err| {
                    cancelPromptRetryAfterAuth(app);
                    debug_trace.logf("auth", "login failed source={t} err={s}", .{ sign_in_source, @errorName(err) });
                    _ = app.auth.popPickerStage(app.alloc);
                    try writeLoginError(app, sign_in_source, err);
                },
                .succeeded => |completed| {
                    var owned = completed;
                    defer owned.deinit(app.alloc);
                    switch (owned) {
                        .vercel => |*selection| {
                            if (selection.teams.items.len == 0) {
                                _ = app.auth.popPickerStage(app.alloc);
                                try writeAuthNotice(app, .{
                                    .topic = "auth",
                                    .tone = .@"error",
                                    .body = "Signed in to Vercel, but no Vercel teams could be loaded. The current credential is unchanged.",
                                });
                                cancelPromptRetryAfterAuth(app);
                                return;
                            }
                            try app.auth.refreshSourceInventory(app.alloc);
                            app.auth.openTeamPicker(app.alloc, selection);
                            try writeAuthNotice(app, .{
                                .topic = "auth",
                                .tone = .neutral,
                                .body = "Signed in to Vercel. Choose a team to finish setup.",
                            });
                        },
                        .chatgpt => {
                            try finishSubscriptionSignIn(app, .codex);
                            return;
                        },
                        .grok => {
                            try finishSubscriptionSignIn(app, .grok);
                            return;
                        },
                    }
                },
            }
        }

        fn finishSubscriptionSignIn(
            app: *App,
            provider: model_provider.ProviderId,
        ) !void {
            try app.auth.refreshSourceInventory(app.alloc);
            switch (auth_transition.signInCompletion(
                provider,
                comptime provider_runtime.supported(App),
            )) {
                .vercel => unreachable,
                .switch_provider => |target| {
                    app.auth.closePicker(app.alloc);
                    try switchProvider(app, target, false, .post_oauth);
                },
                .activate_source => |source| {
                    if (!try selectCredentialSource(app, source)) {
                        cancelPromptRetryAfterAuth(app);
                        _ = app.auth.popPickerStage(app.alloc);
                        try writeAuthNotice(app, .{
                            .topic = "auth",
                            .tone = .@"error",
                            .body = if (provider == .codex)
                                "Signed in, but the Codex subscription credential could not be loaded."
                            else
                                "Signed in, but the Grok subscription credential could not be loaded.",
                        });
                        return;
                    }
                    app.auth.closePicker(app.alloc);
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .neutral,
                        .body = if (provider == .codex)
                            "Signed in with Codex."
                        else
                            "Signed in with Grok.",
                    });
                    try resumePromptAfterAuth(app);
                },
            }
        }

        fn prepareApiKeyInputBoundary(app: *App) void {
            if (comptime @hasDecl(App, "prepareApiKeyInputBoundary")) {
                app.prepareApiKeyInputBoundary();
            }
        }

        fn submitApiKeyEntry(app: *App) !void {
            if (app.auth.pickerView().api_key_mask_count == 0) return;
            switch (app.auth.beginApiKeySave(app.alloc)) {
                .started => app.shell.render_requests.request(.footer),
                .empty => {},
                .busy => try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Still saving the previous API key. Nothing was stored for this one; try again in a moment.",
                }, true),
            }
        }

        /// Polled from the event loop so a save that blocks on a locked key store
        /// or a slow gateway never stalls rendering.
        pub fn collectApiKeySaveFacts(app: *App) !void {
            // Runs every tick: the key column has to retire whenever its entry
            // ended, whether it was saved, cancelled, or replaced.
            defer provider_picker_runtime.Runtime(App).closeKeyColumn(app);
            const result = app.auth.takeApiKeySaveResult(app.alloc) orelse return;
            try applyApiKeySaveResult(app, result);
        }

        fn applyApiKeySaveResult(app: *App, result: auth_runtime.ApiKeySaveResult) !void {
            switch (result) {
                .empty => return,
                .saved => |changed| {
                    applyCredentialChange(app, changed);
                    rememberCredentialSource(app, .stored_key);
                    const body = try app.alloc.print(
                        "Saved the API key to {s} and made it active.",
                        .{credentials.stored_key_backend_label},
                    );
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .neutral,
                        .body = body,
                    }, true);
                    // Only the inline `/provider vercel api-key` path implies
                    // "use the gateway now": the user named the provider on the
                    // way in. The staged hub also reaches this save, and there
                    // adding a key is not a request to switch.
                    if (comptime provider_runtime.supported(App) and provider_picker_runtime.supported(App)) {
                        if (app.input_runtime.picker.provider_picker_stage == .api_key and
                            provider_runtime.provider(app) != .gateway)
                        {
                            try switchProvider(app, .gateway, false, .manual);
                        }
                    }
                },
                .gateway_refused => try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "The AI Gateway refused that API key. Nothing was stored.",
                }, true),
                .gateway_unavailable => try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Could not verify that API key with AI Gateway. Nothing was stored.",
                }, true),
                .store_failed => {
                    const body = try app.alloc.print(
                        "Could not save the API key to {s}. Nothing was stored.",
                        .{credentials.stored_key_backend_label},
                    );
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = body,
                    }, true);
                },
                .reload_failed => {
                    const body = try app.alloc.print(
                        "Saved the API key to {s}, but could not make it active.",
                        .{credentials.stored_key_backend_label},
                    );
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .warning,
                        .body = body,
                    }, true);
                },
            }
        }

        /// Clearing the remembered choice must also re-resolve, otherwise the
        /// session would keep running on a source precedence no longer selects.
        fn applyAutomaticCredential(app: *App) !void {
            forgetCredentialSource(app);
            app.auth.closePicker(app.alloc);
            applyCredentialChange(app, try app.auth.reselectByPrecedence(app.alloc));
            try app.writeDomainNotice(.{
                .topic = "auth",
                .tone = .neutral,
                .body = "Using automatic credential precedence again.",
            }, true);
            try resumePromptAfterAuth(app);
        }

        fn forgetCredentialSource(app: *App) void {
            var attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                .{ .clear_credential_source = true },
            );
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .outcome => debug_trace.logf("auth", "credential choice cleared", .{}),
                .failure => |failure| debug_trace.logf(
                    "auth",
                    "credential choice not cleared err={s}",
                    .{@errorName(failure.err)},
                ),
            }
        }

        /// Reports whether the credential actually switched, so callers that
        /// chain further work (the inline picker's provider switch) can stop
        /// when it did not. Failure is already explained to the user here.
        pub fn applySourceChoice(app: *App, source: credentials.Source) !bool {
            if (try rejectPendingPreparation(app)) return false;
            const body = try app.alloc.print(
                "Switched credential to {s}.",
                .{credentials.sourceLabel(source)},
            );
            defer app.alloc.free(body);

            if (!try selectCredentialSource(app, source)) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "That credential is no longer available. The current source is unchanged.",
                }, true);
                return false;
            }

            rememberCredentialSource(app, source);
            try app.writeDomainNotice(.{
                .topic = "auth",
                .tone = .neutral,
                .body = body,
            }, true);
            try resumePromptAfterAuth(app);
            return true;
        }

        /// An explicit source choice outlives the session. Failing to persist
        /// leaves the source active for this run rather than refusing a working
        /// credential the user already selected.
        fn rememberCredentialSource(app: *App, source: credentials.Source) void {
            // ChatGPT is selected by model route, not as a global Gateway
            // credential preference. Its saved session coexists independently.
            if (source == .chatgpt_subscription or source == .grok_subscription) return;
            if (comptime @hasDecl(App, "persistCredentialSourcePreference")) {
                app.persistCredentialSourcePreference(source);
                return;
            }

            var attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                .{ .credential_source = source },
            );
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .outcome => debug_trace.logf("auth", "credential choice persisted source={t}", .{source}),
                .failure => |failure| debug_trace.logf(
                    "auth",
                    "credential choice not persisted source={t} err={s}",
                    .{ source, @errorName(failure.err) },
                ),
            }
        }

        fn beginChatGptSignIn(app: *App) !void {
            if (comptime provider_runtime.supported(App)) {
                const decision = decideProviderSwitch(.{
                    .current = provider_runtime.provider(app),
                    .target = .codex,
                    .target_credential_ready = false,
                    .intent = .post_oauth,
                    .stream_active = app.stream.active,
                    .queued_prompts = app.worker.queuedPromptCount(),
                });
                if (decision == .busy) {
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .warning,
                        .body = "Codex sign-in is unavailable until active and queued work finishes.",
                    }, true);
                    return;
                }
            }
            try app.flushBeforeBlockingExternalWork();
            const started = app.auth.openChatGptSignInPickerFromRoot(app.alloc);
            if (started catch |err| {
                cancelPromptRetryAfterAuth(app);
                debug_trace.logf("auth", "ChatGPT login failed err={s}", .{@errorName(err)});
                try writeLoginError(app, .chatgpt_subscription, err);
                return;
            }) {
                app.shell.render_requests.request(.footer);
                if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) try openSignInBrowser(app);
            }
        }

        fn beginGrokSignIn(app: *App) !void {
            if (comptime provider_runtime.supported(App)) {
                const decision = decideProviderSwitch(.{
                    .current = provider_runtime.provider(app),
                    .target = .grok,
                    .target_credential_ready = false,
                    .intent = .post_oauth,
                    .stream_active = app.stream.active,
                    .queued_prompts = app.worker.queuedPromptCount(),
                });
                if (decision == .busy) {
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .warning,
                        .body = "Grok sign-in is unavailable until active and queued work finishes.",
                    }, true);
                    return;
                }
            }
            try app.flushBeforeBlockingExternalWork();
            const started = app.auth.openGrokSignInPickerFromRoot(app.alloc);
            if (started catch |err| {
                cancelPromptRetryAfterAuth(app);
                debug_trace.logf("auth", "Grok login failed err={s}", .{@errorName(err)});
                try writeLoginError(app, .grok_subscription, err);
                return;
            }) {
                app.shell.render_requests.request(.footer);
                if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) try openSignInBrowser(app);
            }
        }

        fn beginCodexSignInForProviderSwitch(app: *App) !void {
            try app.flushBeforeBlockingExternalWork();
            const started = app.auth.openChatGptSignInPickerForProviderSwitch(app.alloc);
            if (started catch |err| {
                debug_trace.logf("auth", "Codex login failed err={s}", .{@errorName(err)});
                try writeLoginError(app, .chatgpt_subscription, err);
                return;
            }) {
                app.shell.render_requests.request(.footer);
                if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) try openSignInBrowser(app);
            }
        }

        fn beginGrokSignInForProviderSwitch(app: *App) !void {
            try app.flushBeforeBlockingExternalWork();
            const started = app.auth.openGrokSignInPickerForProviderSwitch(app.alloc);
            if (started catch |err| {
                debug_trace.logf("auth", "Grok login failed err={s}", .{@errorName(err)});
                try writeLoginError(app, .grok_subscription, err);
                return;
            }) {
                app.shell.render_requests.request(.footer);
                if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) try openSignInBrowser(app);
            }
        }

        fn switchProvider(
            app: *App,
            target: model_provider.ProviderId,
            allow_login: bool,
            intent: ProviderSwitchIntent,
        ) !void {
            try startProviderSwitch(app, target, allow_login, intent, null);
        }

        fn startProviderSwitch(
            app: *App,
            target: model_provider.ProviderId,
            allow_login: bool,
            intent: ProviderSwitchIntent,
            fallback: ?model_provider.ProviderId,
        ) !void {
            if (comptime !provider_runtime.supported(App) or !@hasDecl(App, "providerCatalog") or !@hasDecl(@TypeOf(app.auth), "beginProviderPreparation")) {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .warning,
                    .body = "Provider switching is unavailable in this host.",
                }, true);
                return;
            }
            if (try rejectPendingPreparation(app)) return;
            switch (decideProviderSwitch(.{
                .current = provider_runtime.provider(app),
                .target = target,
                .target_credential_ready = model_provider.authorizesCredential(target, app.auth.credentialSource()),
                .intent = intent,
                .stream_active = app.stream.active or pendingPromptBlocksPreparation(app),
                .queued_prompts = app.worker.queuedPromptCount(),
            })) {
                .prepare => {},
                .no_change => {
                    const body = try app.alloc.print("Already using {s}.", .{provider_catalog.label(target)});
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .neutral,
                        .body = body,
                    }, true);
                    return;
                },
                .busy => {
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .warning,
                        .body = providerFailureMessage(intent, provider_busy_message, "Subscription sign-in completed, but provider activation is unavailable until active and queued work finishes. The current provider is unchanged."),
                    }, true);
                    return;
                },
            }
            var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch |err| {
                debug_trace.logf("provider", "settings load failed err={s}", .{@errorName(err)});
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = "Could not load the saved provider selection. The current provider is unchanged.",
                }, true);
                return;
            };
            defer settings.deinit(app.alloc);
            const catalog_provider = app.providerCatalog(target) orelse {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = "The target provider catalog is unavailable. The current provider is unchanged.",
                }, true);
                return;
            };
            try beginPreparation(app, .{
                .intent = .{ .provider = .{ .target = target, .allow_login = allow_login, .origin = intent, .fallback = fallback } },
                .catalog_provider = catalog_provider,
                .models_path = app.model_cache.models_path,
                .preferred_source = if (target == .gateway) settings.credential_source else null,
                .primary_model = if (intent == .post_oauth and provider_runtime.provider(app).eql(target)) provider_runtime.model(app) else null,
                .preferred_model = if (intent == .post_oauth) settings.models.get(target) else io_mod.getenv("FX_MODEL") orelse settings.models.get(target),
            });
        }

        fn pendingPromptBlocksPreparation(app: *const App) bool {
            if (comptime !@hasField(App, "submission")) return false;
            const pending = app.submission.pending orelse return false;
            return pending.credential_admitted or pending.phase == .queued;
        }

        fn pendingPromptNeedsAdoption(app: *const App) bool {
            if (comptime !@hasField(App, "submission")) return false;
            const pending = app.submission.pending orelse return false;
            return pending.phase == .awaiting_frame or pending.phase == .awaiting_adoption;
        }

        fn rejectPendingPreparation(app: *App) !bool {
            if (comptime !@hasDecl(@TypeOf(app.auth), "providerPreparationPending")) return false;
            if (!app.auth.providerPreparationPending()) return false;
            try app.writeDomainNotice(.{
                .topic = "provider",
                .tone = .neutral,
                .body = "Provider preparation is still in progress. ctrl+c cancels.",
            }, true);
            return true;
        }

        fn beginPreparation(app: *App, input: auth_runtime.ProviderPreparationInput) !void {
            app.auth.beginProviderPreparation(app.alloc, input) catch |err| {
                debug_trace.logf("provider", "preparation start failed err={s}", .{@errorName(err)});
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = "Could not start provider preparation. The current provider is unchanged.",
                }, true);
                return;
            };
            const body = try app.alloc.print("Preparing {s}.", .{provider_catalog.label(input.target())});
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{
                .topic = "provider",
                .tone = .neutral,
                .body = body,
            }, true);
        }

        pub fn collectProviderPreparationFacts(app: *App) !void {
            if (comptime !@hasDecl(@TypeOf(app.auth), "takeProviderPreparation")) return;
            if (pendingPromptNeedsAdoption(app)) return;
            const task = app.auth.takeProviderPreparation() orelse return;
            defer task.deinit();
            if (task.cancel_requested.load(.seq_cst)) {
                holdPromptAfterPreparationFailure(app);
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .neutral,
                    .body = "Provider preparation cancelled. The current provider is unchanged.",
                }, true);
                return;
            }
            const applied = switch (task.input.intent) {
                .provider => try finishProviderSwitch(app, task),
                .team => try finishTeamPreparation(app, task),
            };
            if (applied) {
                if (comptime @hasField(App, "submission")) {
                    if (app.submission.pending) |pending| {
                        if (pending.phase == .awaiting_auth) requestPromptRetryAfterAuth(app);
                    }
                }
                try resumePromptAfterAuth(app);
                return;
            }
            if (task.input.intent == .provider) {
                if (task.input.intent.provider.fallback) |target| {
                    try startProviderSwitch(app, target, false, .manual, null);
                    if (app.auth.providerPreparationPending()) return;
                }
            }
            holdPromptAfterPreparationFailure(app);
        }

        fn holdPromptAfterPreparationFailure(app: *App) void {
            if (comptime !@hasField(App, "submission")) return;
            if (app.submission.pending) |*pending| {
                if (pending.phase == .adopted) {
                    pending.phase = .awaiting_auth;
                    app.submission.retry_after_auth = app.auth.signInEntryActive();
                    debug_trace.logf("provider", "pending prompt retained after preparation failure", .{});
                }
            }
        }

        fn finishProviderSwitch(app: *App, task: *auth_runtime.ProviderPreparation) !bool {
            const request = task.input.intent.provider;
            const target = request.target;
            const intent = request.origin;
            if (task.failure) |err| {
                debug_trace.logf("provider", "preparation failed target={t} err={s}", .{ target, @errorName(err) });
                if (task.credential == null and !hostManagesAuth(app)) {
                    const body = try auth_runtime.preparationFailureText(app.alloc, target, err);
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = body,
                    }, true);
                } else {
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .@"error",
                        .body = providerFailureMessage(intent, "Could not load the target provider catalog. The current provider is unchanged.", "Subscription sign-in completed, but its model catalog could not be loaded. The current provider is unchanged."),
                    }, true);
                }
                return false;
            }
            if (task.credential == null and !hostManagesAuth(app)) {
                if (request.allow_login) {
                    switch (target) {
                        .codex => try beginCodexSignInForProviderSwitch(app),
                        .grok => try beginGrokSignInForProviderSwitch(app),
                        .gateway, .configured => {},
                    }
                }
                if (target == .gateway or !request.allow_login) {
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .warning,
                        .body = if (intent == .post_oauth) "Subscription sign-in completed, but its saved credential is unavailable. The current provider is unchanged." else if (target == .codex) "Run fx login codex, then try switching again." else if (target == .grok) "Run fx login grok, then try switching again." else credentials.missing_interactive_credential_message,
                    }, true);
                }
                return false;
            }
            const fetched = task.catalog orelse return false;
            task.catalog = null;
            var catalog = switch (fetched) {
                .catalog => |catalog| catalog,
                .failure => |failure| {
                    debug_trace.logf("provider", "catalog rejected provider={t} category={t}", .{ target, failure.category });
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .@"error",
                        .body = if (failure.category == .cancellation) "Provider switching was cancelled. The current provider is unchanged." else providerFailureMessage(intent, "The target provider catalog could not be validated. The current provider is unchanged.", "Subscription sign-in completed, but its model catalog could not be validated. The current provider is unchanged."),
                    }, true);
                    return false;
                },
            };
            defer model_catalog.freeModelCatalog(app.alloc, &catalog);
            const selected_model = selectCatalogModel(catalog.items, task.input.primary_model, task.input.preferred_model) orelse {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = providerFailureMessage(intent, "The target provider returned no supported models. The current provider is unchanged.", "Subscription sign-in completed, but its model catalog returned no supported models. The current provider is unchanged."),
                }, true);
                return false;
            };
            var credential = task.credential;
            task.credential = null;
            defer if (credential) |*value| value.deinit(app.alloc);
            const access: credentials.CatalogAccess = if (hostManagesAuth(app)) .host_managed else credentials.catalogAccessForCredentialAndAccount(credential.?.source, credential.?.token, credential.?.gatewayTeam(), credential.?.accountId());
            var owned_model = try app.alloc.dupe(u8, selected_model);
            defer app.alloc.free(owned_model);

            if (auth_transition.provider_work_busy(app.stream.active, app.worker.queuedPromptCount())) {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .warning,
                    .body = providerFailureMessage(
                        intent,
                        provider_busy_message,
                        "Subscription sign-in completed, but provider activation is unavailable until active and queued work finishes. The current provider is unchanged.",
                    ),
                }, true);
                return false;
            }

            app.model_cache.adoptOwnedCatalog(access, &catalog);
            app.provider_selection.adoptOwned(target, &owned_model);
            if (credential) |*value| _ = app.auth.adoptCredential(app.alloc, value);
            reconcileGatewayCredential(app);

            const body = try app.alloc.print(
                "Switched to {s} with {s}.",
                .{ provider_catalog.label(target), provider_runtime.model(app) },
            );
            defer app.alloc.free(body);
            if (comptime @hasDecl(App, "persistRuntimePreferences")) {
                var persistence = app.persistRuntimePreferences(.{
                    .provider = target,
                    .model = provider_runtime.model(app),
                });
                defer persistence.deinit(app.alloc);
                if (persistence.settings_error != null or persistence.session_error != null) {
                    debug_trace.logf(
                        "provider",
                        "runtime switch persistence failed settings={s} session={s}",
                        .{
                            if (persistence.settings_error) |err| @errorName(err) else "none",
                            if (persistence.session_error) |err| @errorName(err) else "none",
                        },
                    );
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .warning,
                        .body = "Provider switched for this run, but the selection could not be saved.",
                    }, true);
                } else {
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .neutral,
                        .body = body,
                    }, true);
                }
            } else {
                var persistence = config_runtime.attemptUserPreferences(app.alloc, .{
                    .provider = target,
                    .model_preference = .{
                        .provider = target,
                        .model = provider_runtime.model(app),
                    },
                });
                defer persistence.deinit(app.alloc);
                switch (persistence) {
                    .outcome => try app.writeDomainNotice(.{ .topic = "provider", .tone = .neutral, .body = body }, true),
                    .failure => |failure| {
                        debug_trace.logf("provider", "runtime switch persistence failed err={s}", .{@errorName(failure.err)});
                        try app.writeDomainNotice(.{
                            .topic = "provider",
                            .tone = .warning,
                            .body = "Provider switched for this run, but the selection could not be saved.",
                        }, true);
                    },
                }
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        /// What the inline `/provider` picker should do after the user chooses to
        /// connect with a Vercel account.
        pub const TeamColumn = enum {
            /// Teams are loaded and ready to render as the next column.
            ready,
            /// No session yet, so the account has to be connected first.
            needs_sign_in,
            /// A session exists but its teams could not be listed. The reason
            /// has already been reported.
            unavailable,
            /// Credential preparation failed; no source may be activated.
            blocked,
        };

        pub fn loadTeamsForProviderPicker(app: *App) !TeamColumn {
            const view = app.auth.pickerView();
            if (view.unavailable_sources.contains(.fx_login)) {
                const body = try auth_runtime.preparationFailureText(app.alloc, .gateway, error.CredentialStorageUnavailable);
                defer app.alloc.free(body);
                try writeAuthNotice(app, .{ .topic = "auth", .tone = .warning, .body = body });
                return .blocked;
            }
            if (comptime @hasDecl(@TypeOf(app.auth), "credentialFailure")) {
                if (app.auth.credentialFailure()) |failure| {
                    if (failure.source == .fx_login and failure.requiresSignIn()) {
                        return .needs_sign_in;
                    }
                }
            }
            if (!view.fx_login_session_available) return .needs_sign_in;
            try app.flushBeforeBlockingExternalWork();

            var selection = login_flow.loadTeamSelection(app.alloc, app.auth.oauthTransport()) catch |err| {
                debug_trace.logf("auth", "provider picker team load failed err={s}", .{@errorName(err)});
                // A session file that exists but can no longer be refreshed is
                // not a listing failure: there is nothing to list until the
                // user signs in again.
                if (err == error.NoSession or auth_runtime.classifyCredentialFailure(.fx_login, err).requiresSignIn()) {
                    return .needs_sign_in;
                }
                if (err != error.NoTeams and err != error.TeamRequestFailed) {
                    if (err == error.OutOfMemory) return err;
                    const body = try auth_runtime.preparationFailureText(app.alloc, .gateway, err);
                    defer app.alloc.free(body);
                    try writeAuthNotice(app, .{ .topic = "auth", .tone = .warning, .body = body });
                    return .blocked;
                }
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = if (err == error.NoTeams) .neutral else .@"error",
                    .body = switch (err) {
                        error.NoTeams => "No Vercel teams are available for this account.",
                        else => "Could not reach Vercel to list teams. The current team is unchanged.",
                    },
                }, true);
                return .unavailable;
            };
            defer selection.deinit(app.alloc);
            if (selection.teams.items.len == 0) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .neutral,
                    .body = "No Vercel teams are available for this account.",
                }, true);
                return .unavailable;
            }
            app.auth.adoptTeamSelection(app.alloc, &selection);
            return .ready;
        }

        fn beginTeamPicker(app: *App) !void {
            if (!app.auth.pickerView().fx_login_session_available) return;
            try app.flushBeforeBlockingExternalWork();

            var selection = login_flow.loadTeamSelection(app.alloc, app.auth.oauthTransport()) catch |err| {
                debug_trace.logf("auth", "team picker load failed err={s}", .{@errorName(err)});
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = switch (err) {
                        error.NoSession => "The fx login session is no longer available. Sign in to change teams.",
                        error.NoTeams => "No Vercel teams are available for this account.",
                        else => "Could not load Vercel teams. The current team is unchanged.",
                    },
                }, true);
                return;
            };
            defer selection.deinit(app.alloc);
            app.auth.openTeamPicker(app.alloc, &selection);
            app.shell.render_requests.request(.footer);
        }

        pub fn applyTeamChoice(app: *App, index: usize) !bool {
            if (pendingPromptBlocksPreparation(app)) {
                try app.writeDomainNotice(.{ .topic = "provider", .tone = .neutral, .body = provider_busy_message }, true);
                return false;
            }
            if (try rejectPendingPreparation(app)) return false;
            if (try reject_provider_picker_if_busy(app)) return false;
            const selection = app.auth.loadedTeamSelection() orelse return false;
            if (index >= selection.teams.items.len) return false;
            var candidate = selection.validationCredential(app.alloc, index) catch |err| {
                cancelPromptRetryAfterAuth(app);
                if (err == error.OutOfMemory) return err;
                debug_trace.logf("auth", "team validation credential failed err={s}", .{@errorName(err)});
                app.auth.closePicker(app.alloc);
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "The selected Vercel team could not be validated. The current team is unchanged.",
                }, true);
                return false;
            };
            defer candidate.deinit(app.alloc);
            if (comptime @hasDecl(@TypeOf(app.auth), "beginProviderPreparation") and @hasDecl(App, "providerCatalog")) {
                const catalog_provider = app.providerCatalog(.gateway) orelse return false;
                var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch |err| {
                    debug_trace.logf("auth", "team preparation settings failed err={s}", .{@errorName(err)});
                    try app.writeDomainNotice(.{ .topic = "auth", .tone = .@"error", .body = "Could not load provider preferences. The current team is unchanged." }, true);
                    return false;
                };
                defer settings.deinit(app.alloc);
                try beginPreparation(app, .{
                    .intent = .{ .team = .{ .index = index, .activate_gateway = provider_runtime.provider(app) != .gateway } },
                    .preferred_model = io_mod.getenv("FX_MODEL") orelse settings.models.get(.gateway),
                    .catalog_provider = catalog_provider,
                    .models_path = app.model_cache.models_path,
                    .candidate = candidate,
                });
                return false;
            } else {
                var validation = try validateTeamCredential(app, candidate);
                defer validation.deinit(app.alloc);
                return finishTeamChoice(app, index, validation, null);
            }
        }

        fn finishTeamPreparation(app: *App, task: *auth_runtime.ProviderPreparation) !bool {
            const request = task.input.intent.team;
            if (try reject_provider_picker_if_busy(app)) return false;
            if (task.failure) |err| debug_trace.logf("auth", "team preparation failed err={s}", .{@errorName(err)});
            const selection = app.auth.loadedTeamSelection() orelse {
                debug_trace.logf("auth", "team preparation discarded reason=selection_closed", .{});
                return false;
            };
            const candidate = task.credential orelse return false;
            if (request.index >= selection.teams.items.len or
                !std.mem.eql(u8, selection.teams.items[request.index].id, candidate.team_id orelse ""))
            {
                debug_trace.logf("auth", "team preparation discarded reason=selection_changed", .{});
                return false;
            }
            var validation: TeamCatalogValidation = if (task.catalog) |catalog| try validateTeamCatalog(app, catalog) else .rejected;
            defer validation.deinit(app.alloc);
            return finishTeamChoice(app, request.index, validation, if (request.activate_gateway) task else null);
        }

        fn finishTeamChoice(app: *App, index: usize, validation: TeamCatalogValidation, activation: ?*auth_runtime.ProviderPreparation) !bool {
            const selection = app.auth.loadedTeamSelection() orelse return false;
            if (index >= selection.teams.items.len) return false;
            const team = selection.teams.items[index];
            const body = try app.alloc.print("Changed Vercel team to {s} ({s}).", .{ team.name, team.slug });
            defer app.alloc.free(body);
            if (validation == .rejected) {
                cancelPromptRetryAfterAuth(app);
                app.auth.closePicker(app.alloc);
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "The selected Vercel team could not be validated for AI Gateway. The current team is unchanged.",
                }, true);
                return false;
            }

            var selected_team = selection.select(app.alloc, index) catch |err| {
                cancelPromptRetryAfterAuth(app);
                debug_trace.logf("auth", "team change failed err={s}", .{@errorName(err)});
                app.auth.closePicker(app.alloc);
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = switch (err) {
                        error.SessionChanged, error.NoSession => "The fx login session changed before the team could be saved.",
                        else => "Could not change the Vercel team. The current team is unchanged.",
                    },
                }, true);
                return false;
            };
            defer selected_team.deinit(app.alloc);

            if (comptime provider_runtime.supported(App) and @hasDecl(App, "providerCatalog") and @hasDecl(@TypeOf(app.auth), "beginProviderPreparation")) {
                if (activation) |task| {
                    task.input.intent = .{ .provider = .{ .target = .gateway, .allow_login = false, .origin = .manual } };
                    if (!try finishProviderSwitch(app, task)) return false;
                    rememberCredentialSource(app, .fx_login);
                    app.auth.closePicker(app.alloc);
                    try app.writeDomainNotice(.{ .topic = "auth", .tone = .neutral, .body = body }, true);
                    return true;
                }
            }

            var model_persistence_failed = false;
            if (comptime provider_runtime.supported(App)) {
                if (validation.accepted) |selected_model| {
                    try provider_runtime.replaceModel(app, selected_model);
                    if (comptime @hasDecl(App, "persistRuntimePreferences")) {
                        var persistence = app.persistRuntimePreferences(.{
                            .provider = .gateway,
                            .model = provider_runtime.model(app),
                        });
                        defer persistence.deinit(app.alloc);
                        model_persistence_failed = persistence.settings_error != null or
                            persistence.session_error != null;
                    } else {
                        var persistence = config_runtime.attemptUserPreferences(app.alloc, .{
                            .model_preference = .{
                                .provider = .gateway,
                                .model = provider_runtime.model(app),
                            },
                        });
                        defer persistence.deinit(app.alloc);
                        model_persistence_failed = persistence == .failure;
                    }
                }
            }

            if (!try selectCredentialSource(app, .fx_login)) {
                cancelPromptRetryAfterAuth(app);
                app.auth.closePicker(app.alloc);
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Changed the Vercel team, but the fx login credential could not be loaded.",
                }, true);
                return false;
            }
            rememberCredentialSource(app, .fx_login);
            app.auth.closePicker(app.alloc);
            try app.writeDomainNotice(if (model_persistence_failed) .{
                .topic = "auth",
                .tone = .warning,
                .body = "The Vercel team changed and a valid model was selected for this run, but the model preference could not be saved.",
            } else .{
                .topic = "auth",
                .tone = .neutral,
                .body = body,
            }, true);
            try resumePromptAfterAuth(app);
            return true;
        }

        /// Sign-in launched from the inline `/provider` picker. Esc must close
        /// the sign-in surface entirely; the legacy staged hub is not the
        /// screen the user came from.
        pub fn beginSignInForProviderPicker(app: *App) !void {
            try beginSignIn(app, false);
        }

        fn validateTeamCredential(
            app: *App,
            candidate: credentials.Credential,
        ) std.mem.Allocator.Error!TeamCatalogValidation {
            if (comptime !@hasDecl(App, "providerCatalog")) {
                return .{ .accepted = null };
            }
            const access = credentials.catalogAccessAt(candidate, io_mod.milliTimestamp());
            if (access.authorizationCredential() == null) return .rejected;
            const provider = app.providerCatalog(.gateway) orelse return .rejected;
            var cancelled = std.atomic.Value(bool).init(false);
            const fetched = provider.fetch(app.alloc, .{
                .access = access,
                .endpoint = app.model_cache.models_path,
                .cancel_flag = &cancelled,
                .view = .picker,
            }) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                debug_trace.logf("auth", "team catalog validation failed err={s}", .{@errorName(err)});
                return .rejected;
            };
            defer if (fetched == .catalog) {
                var owned = fetched.catalog;
                model_catalog.freeModelCatalog(app.alloc, &owned);
            };
            return validateTeamCatalog(app, fetched);
        }

        fn validateTeamCatalog(app: *App, fetched: model_catalog.ProviderResult) std.mem.Allocator.Error!TeamCatalogValidation {
            return switch (fetched) {
                .failure => |failure| result: {
                    debug_trace.logf("auth", "team catalog rejected category={t}", .{failure.category});
                    break :result .rejected;
                },
                .catalog => |catalog_value| result: {
                    const catalog = catalog_value;
                    if (catalog.items.len == 0) break :result .rejected;
                    if (comptime provider_runtime.supported(App)) {
                        const current_model = provider_runtime.model(app);
                        for (catalog.items) |entry| {
                            if (std.mem.eql(u8, entry.id, current_model)) {
                                break :result .{ .accepted = null };
                            }
                        }
                        break :result .{
                            .accepted = try app.alloc.dupe(u8, catalog.items[0].id),
                        };
                    }
                    break :result .{ .accepted = null };
                },
            };
        }

        fn beginSignIn(app: *App, from_root: bool) !void {
            try app.flushBeforeBlockingExternalWork();

            const started = if (from_root)
                app.auth.openSignInPickerFromRoot(app.alloc)
            else
                app.auth.openSignInPicker(app.alloc);
            if (started catch |err| {
                cancelPromptRetryAfterAuth(app);
                debug_trace.logf("auth", "login failed err={s}", .{@errorName(err)});
                try writeLoginError(app, .fx_login, err);
                return;
            }) {
                app.shell.render_requests.request(.footer);
                // Open the browser as soon as the device code is ready instead of
                // waiting for Enter; Enter stays as a manual re-open, and
                // FX_NO_OPEN_BROWSER opts out for headless/SSH sessions.
                if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) try openSignInBrowser(app);
            }
        }

        fn openSignInBrowser(app: *App) !void {
            const url = (try app.auth.signInBrowserUrlAlloc(app.alloc)) orelse return;
            defer app.alloc.free(url);
            if (!try app.urlOpener().open(app.alloc, url)) {
                debug_trace.logf("auth", "login browser launcher failed", .{});
            }
        }

        pub fn selectCredentialSource(app: *App, source: credentials.Source) !bool {
            const changed = (try app.auth.selectSource(app.alloc, source)) orelse return false;
            applyCredentialChange(app, changed);
            return true;
        }

        fn refreshFxLoginCredentialIfNeeded(app: *App) !void {
            const change = try app.auth.refreshSelectedCredentialIfNeeded(app.alloc);
            applyCredentialRefreshChange(app, change);
        }

        fn applyCredentialRefreshChange(
            app: *App,
            change: auth_transition.CredentialChange,
        ) void {
            if (change == .none) return;
            reconcileGatewayCredential(app);
            if (app.auth.modelCatalogAccess().authorizationCredential() == null) return;
            if (change == .authority) app.model_cache.reset();
            if (comptime @hasDecl(App, "startModelCacheWarmup")) {
                app.startModelCacheWarmup();
            }
        }

        pub fn admitPromptCredential(app: *App) !bool {
            if (!try ensurePromptCredential(app)) return false;
            return preparePromptCredential(app);
        }

        pub fn startPromptCredentialPrewarm(app: *App) void {
            if (comptime @hasDecl(@TypeOf(app.auth), "providerPreparationPending")) {
                if (app.auth.providerPreparationPending()) return;
            }
            if (comptime !@hasDecl(@TypeOf(app.auth), "beginPromptCredentialRefresh")) return;
            if (comptime provider_runtime.supported(App)) {
                if (!model_provider.authorizesCredential(provider_runtime.provider(app), app.auth.credentialSource())) return;
            }
            const outcome = app.auth.beginPromptCredentialRefresh();
            debug_trace.logf(
                "auth",
                "prompt credential prewarm start outcome={s}",
                .{@tagName(outcome)},
            );
        }

        pub fn collectPendingPromptCredential(
            app: *App,
        ) !PendingPromptCredentialReadiness {
            if (startupCredentialPending(app)) return .pending;
            if (comptime @hasDecl(@TypeOf(app.auth), "providerPreparationPending")) {
                if (app.auth.providerPreparationPending()) return .pending;
            }
            if (!try ensurePromptCredential(app)) return .rejected;
            const source = app.auth.credentialSource() orelse return .rejected;
            if (!credentials.sourceRefreshable(source)) {
                return if (app.auth.gatewayCredential() != null) .current else .rejected;
            }

            var refresh = app.auth.pollPromptCredentialRefresh();
            defer refresh.deinit();
            switch (refresh) {
                .idle => {
                    return switch (app.auth.beginPromptCredentialRefresh()) {
                        .started, .pending => .pending,
                        .not_needed => if (app.auth.gatewayCredential() != null) .current else .rejected,
                        .failed => if (try admitPromptCredential(app)) .current else .rejected,
                    };
                },
                .pending => return .pending,
                .failed => |failure| {
                    _ = try recoverCredentialFailure(app, failure.source, failure.err);
                    return .rejected;
                },
                .ready => |*refreshed| {
                    var owned = try refreshed.clone(app.alloc);
                    defer owned.deinit(app.alloc);
                    const change = app.auth.adoptPreparedCredential(app.alloc, &owned);
                    applyCredentialRefreshChange(app, change);
                    return if (app.auth.gatewayCredential() != null) .current else .pending;
                },
            }
        }

        pub fn retryPendingPromptCredential(
            app: *App,
        ) !PendingPromptCredentialReadiness {
            if (startupCredentialPending(app)) return .pending;
            if (comptime @hasDecl(@TypeOf(app.auth), "providerPreparationPending")) {
                if (app.auth.providerPreparationPending()) return .pending;
            }
            if (!try ensurePromptCredential(app)) return .rejected;
            if (comptime @hasDecl(@TypeOf(app.auth), "credentialFailure")) {
                if (app.auth.credentialFailure()) |failure| {
                    if (!failure.retryable()) {
                        return if (try preparePromptCredential(app)) .current else .rejected;
                    }
                }
            }
            app.auth.cancelPromptCredentialRefresh();
            return switch (app.auth.beginPromptCredentialRefresh()) {
                .started, .pending => .pending,
                .not_needed => if (app.auth.gatewayCredential() != null) .current else .rejected,
                .failed => if (try preparePromptCredential(app)) .current else .rejected,
            };
        }

        fn preparePromptCredential(app: *App) !bool {
            if (comptime @hasDecl(@TypeOf(app.auth), "credentialFailure")) {
                if (app.auth.credentialFailure()) |failure| {
                    if (failure.requiresSignIn()) {
                        try beginCredentialRepair(app, failure);
                        return false;
                    }
                }
            }
            for (0..2) |_| {
                refreshFxLoginCredentialIfNeeded(app) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return recoverPromptCredentialRefreshFailure(app, err),
                };
                if (app.auth.gatewayCredential() != null) return true;
            }
            return recoverPromptCredentialRefreshFailure(app, error.CredentialRefreshUnavailable);
        }

        fn beginCredentialRepair(
            app: *App,
            failure: auth_runtime.CredentialFailure,
        ) !void {
            requestPromptRetryAfterAuth(app);
            switch (failure.source) {
                .fx_login => try beginSignIn(app, false),
                .chatgpt_subscription => try beginChatGptSignIn(app),
                .grok_subscription => try beginGrokSignIn(app),
                .vercel_oidc_token,
                .ai_gateway_api_key,
                .stored_key,
                .host_managed,
                .configured,
                => {},
            }
        }

        fn requestPromptRetryAfterAuth(app: *App) void {
            if (comptime @hasDecl(App, "requestPromptRetryAfterAuth")) {
                app.requestPromptRetryAfterAuth();
            }
        }

        fn cancelPromptRetryAfterAuth(app: *App) void {
            if (comptime @hasDecl(App, "cancelPromptRetryAfterAuth")) {
                app.cancelPromptRetryAfterAuth();
            }
        }

        fn resumePromptAfterAuth(app: *App) !void {
            if (comptime @hasDecl(App, "resumePromptAfterAuth")) {
                try app.resumePromptAfterAuth();
            }
        }

        fn recoverPromptCredentialRefreshFailure(app: *App, err: anyerror) !bool {
            const active_source = app.auth.credentialSource();
            const source = if (active_source) |active|
                if (credentials.sourceRefreshable(active)) active else .fx_login
            else
                .fx_login;
            return recoverCredentialFailure(app, source, err);
        }

        fn recoverCredentialFailure(app: *App, source: credentials.Source, err: anyerror) !bool {
            debug_trace.logf("auth", "prompt credential refresh failed source={t} err={s}", .{ source, @errorName(err) });
            const failure = auth_runtime.classifyCredentialFailure(source, err);
            debug_trace.logf(
                "auth",
                "credential failure source={t} reason={t} retryable={s}",
                .{ failure.source, failure.reason, if (failure.retryable()) "true" else "false" },
            );
            const notify = !compactionOwnsCredentialFeedback(app);
            const should_notify = if (app.auth.credentialSource() == source and
                comptime @hasDecl(@TypeOf(app.auth), "recordCredentialFailure"))
                app.auth.recordCredentialFailure(failure, .{ .notify = notify })
            else
                notify;
            if (!should_notify) return false;
            const recovery = try credentialRecoveryText(app.alloc, failure);
            defer app.alloc.free(recovery);
            try app.writeDomainNotice(.{
                .topic = "auth",
                .tone = .@"error",
                .body = recovery,
            }, true);
            app.shell.render_requests.request(.footer);
            return false;
        }

        fn credentialRecoveryText(
            alloc: std.mem.Allocator,
            failure: auth_runtime.CredentialFailure,
        ) ![]u8 {
            const source_label = credentials.sourceLabel(failure.source);
            return switch (failure.reason) {
                .invalid_credential => alloc.print(
                    "{s} sign-in expired.\npress enter to sign in again. Your prompt is saved.",
                    .{source_label},
                ),
                .invalid_storage => alloc.print(
                    "{s}: Saved credential storage is unavailable.\nCheck credential storage, then press enter to retry. Your prompt is saved.",
                    .{source_label},
                ),
                .persistence_uncertain => alloc.print(
                    "{s} refresh could not be saved.\npress enter to sign in again. Your prompt is saved.",
                    .{source_label},
                ),
                .authority_changed => alloc.print(
                    "{s} account or team changed during refresh.\nReview authentication before retrying. Your prompt is saved.",
                    .{source_label},
                ),
                .temporary_unavailable => alloc.print(
                    "{s} credential refresh failed.\npress enter to retry. Your prompt is saved.",
                    .{source_label},
                ),
            };
        }

        fn applyCredentialChange(app: *App, changed: bool) void {
            if (!changed) return;
            if (comptime @hasDecl(@TypeOf(app.auth), "cancelPromptCredentialRefresh")) {
                app.auth.cancelPromptCredentialRefresh();
            }
            reconcileGatewayCredential(app);
            app.model_cache.reset();
            if (comptime @hasDecl(App, "startModelCacheWarmup")) {
                app.startModelCacheWarmup();
            }
        }

        fn reconcileGatewayCredential(app: *App) void {
            if (comptime @hasField(App, "session") and
                @hasField(@TypeOf(app.session), "usage"))
            {
                if (app.auth.gatewayCredential()) |credential| {
                    if (gatewayCredentialSource(credential) == .host_managed) {
                        if (comptime @hasDecl(@TypeOf(app.session.usage), "replaceHostManagedReconciliationAuthority")) {
                            app.session.usage.replaceHostManagedReconciliationAuthority(
                                app.alloc,
                                provider_runtime.provider(app),
                            );
                        }
                        return;
                    }
                    const subscription = if (comptime @hasField(@TypeOf(credential), "source"))
                        credential.source == .chatgpt_subscription or credential.source == .grok_subscription
                    else
                        false;
                    if (subscription) {
                        app.session.usage.clearReconciliationCredential();
                    } else {
                        if (comptime @hasDecl(
                            @TypeOf(app.session.usage),
                            "replaceProviderReconciliationCredential",
                        )) {
                            if (optionalGatewayApiKey(credential)) |api_key| {
                                app.session.usage.replaceProviderReconciliationCredential(
                                    app.alloc,
                                    .gateway,
                                    credential.source,
                                    null,
                                    api_key,
                                );
                            }
                        } else {
                            if (optionalGatewayApiKey(credential)) |api_key| {
                                app.session.usage.replaceReconciliationCredential(
                                    app.alloc,
                                    api_key,
                                );
                            }
                        }
                    }
                } else {
                    app.session.usage.clearReconciliationCredential();
                }
            }
        }

        fn writeLoginError(app: *App, source: credentials.Source, err: anyerror) !void {
            const failure = auth_runtime.classifyCredentialFailure(source, err);
            if (failure.reason == .invalid_storage or failure.reason == .persistence_uncertain) {
                const notice = auth_runtime.preparationFailureNotice(auth_runtime.preparationError(failure).?).?;
                const body = try app.alloc.print("{s}: {s}", .{ credentials.sourceLabel(source), notice });
                defer app.alloc.free(body);
                try writeAuthNotice(app, .{ .topic = "auth", .tone = .@"error", .body = body });
                return;
            }
            const notice: types.SemanticNotice = if (source == .chatgpt_subscription)
                switch (err) {
                    error.ChatGptAuthorizationFailed => .{ .topic = "auth", .tone = .@"error", .body = "Codex sign-in was denied. The current credential is unchanged." },
                    error.ChatGptLoginTimedOut, error.LoginTimedOut => .{ .topic = "auth", .tone = .warning, .body = "Codex sign-in expired. The current credential is unchanged; run /login to try again." },
                    else => .{ .topic = "auth", .tone = .@"error", .body = "Codex sign-in failed. The current credential is unchanged." },
                }
            else if (source == .grok_subscription)
                switch (err) {
                    error.GrokAuthorizationFailed => .{ .topic = "auth", .tone = .@"error", .body = "Grok sign-in was denied. The current credential is unchanged." },
                    error.GrokLoginTimedOut, error.LoginTimedOut => .{ .topic = "auth", .tone = .warning, .body = "Grok sign-in expired. The current credential is unchanged; run /login to try again." },
                    else => .{ .topic = "auth", .tone = .@"error", .body = "Grok sign-in failed. The current credential is unchanged." },
                }
            else switch (err) {
                error.ClientIdMissing => .{ .topic = "auth", .tone = .@"error", .body = "fx login is not configured yet. The current credential is unchanged." },
                error.AccessDenied => .{ .topic = "auth", .tone = .@"error", .body = "Vercel sign-in was denied. The current credential is unchanged." },
                error.ExpiredToken, error.LoginTimedOut => .{ .topic = "auth", .tone = .warning, .body = "The Vercel sign-in code expired. The current credential is unchanged; run /login to try again." },
                else => .{ .topic = "auth", .tone = .@"error", .body = "Vercel sign-in failed. The current credential is unchanged." },
            };
            try writeAuthNotice(app, notice);
        }

        fn writeAuthNotice(app: *App, notice: types.SemanticNotice) !void {
            try app.writeDomainNotice(notice, true);
            app.shell.render_requests.request(.first_frame);
            try app.flushBeforeBlockingExternalWork();
        }
    };
}

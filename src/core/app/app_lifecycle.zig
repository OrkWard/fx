const std = @import("std");
const io_mod = @import("../shared/io.zig");
const agent_steps = @import("../config/agent_steps.zig");
const config_runtime = @import("../config/config_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const host = @import("../hosts/host.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const shared_theme = @import("../shared/theme.zig");
const record_tape = @import("../workspace/record_tape.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const update_target = @import("../upgrade/update_target.zig");
const notification_sound = @import("../notifications/sound.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const compactor = @import("../compactor/compactor.zig");
const types = @import("../shared/types.zig");
const ui_render = @import("../../ui/render.zig");
const transcript_presentation = @import("../output/transcript_presentation.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const ui_terminal = @import("../../ui/terminal/terminal.zig");
const program_status = @import("../../ui/terminal/program_status.zig");
const terminal_diff = @import("../../ui/render_engine/terminal_diff.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;
const PermissionMode = types.PermissionMode;
const CursorPosition = shell_runtime.CursorPosition;
const TerminalState = shell_runtime.TerminalState;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
pub const ResizeHandler = shell_runtime.ResizeHandler;
pub const default_permission_mode = config_runtime.default_permission_mode;

/// Compile-time terminal restoration for one async-signal-safe `write(2)` call.
/// Resets terminal modes, clears fx's program status, and ends with a newline
/// before the next shell prompt.
const abnormal_exit_restore_prefix = "\x1b[?2026l\x1b[?1000l\x1b[?1002l\x1b[?1004l\x1b[?1006l\x1b[?1l\x1b>\x1b[?1049l\x1b[?7h\x1b[4l\x1b[?6l\x1b[0m\x1b[?25h\x1b[?2031l\x1b[?2004l" ++ program_status.clear_sequence;
const abnormal_exit_restore = abnormal_exit_restore_prefix ++ "\x1b[<u\x1b[>4;0m\n";
const tmux_abnormal_exit_restore = abnormal_exit_restore_prefix ++ "\x1b[>4;0m\n";
const normal_exit_restore_prefix = ui_terminal.theme_notification_disable_sequence ++ "\x1b[?2026l\x1b[?1000l\x1b[?1002l\x1b[?1004l\x1b[?1006l\x1b[?1l\x1b>\x1b[4l\x1b[?6l\x1b[?2004l" ++ program_status.clear_sequence;
const normal_exit_restore = normal_exit_restore_prefix ++ "\x1b[<u\x1b[>4;0m";
const tmux_normal_exit_restore = normal_exit_restore_prefix ++ "\x1b[>4;0m";
const alternate_screen_enter = "\x1b[?1049h";
const alternate_mouse_tracking_enter = "\x1b[?1000h\x1b[?1006h";

/// Original handlers, written at bootstrap and restored at shutdown.
/// Signal context never mutates them.
var old_sigterm_action: ?std.posix.Sigaction = null;
var old_sighup_action: ?std.posix.Sigaction = null;

/// Restores terminal state, installs the default disposition, and re-raises.
/// Must remain async-signal-safe: only `write(2)`, `sigaction(2)`, and `raise(3)`.
fn abnormalExitHandlerWithRestore(comptime restore: []const u8, sig: std.posix.SIG) void {
    // Signal context cannot recover from a failed async-signal-safe write.
    _ = std.c.write(
        std.posix.STDOUT_FILENO,
        restore.ptr,
        restore.len,
    );

    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &default_action, null);
    _ = std.c.raise(sig);
}

fn abnormalExitHandler(sig: std.posix.SIG) callconv(.c) void {
    abnormalExitHandlerWithRestore(abnormal_exit_restore, sig);
}

fn tmuxAbnormalExitHandler(sig: std.posix.SIG) callconv(.c) void {
    abnormalExitHandlerWithRestore(tmux_abnormal_exit_restore, sig);
}

/// Install handlers for SIGTERM and SIGHUP so an externally-terminated
/// fx restores terminal state before dying. SIGINT is not included
/// because raw mode disables terminal-generated SIGINT.
pub fn installAbnormalExitHandlers(tmux: ?[]const u8) void {
    if (!shell_runtime.supports_resize_signal) return;

    const handler: std.posix.Sigaction.handler_fn = if (tmux == null)
        abnormalExitHandler
    else
        tmuxAbnormalExitHandler;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    var old_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, &act, &old_term);
    old_sigterm_action = old_term;

    var old_hup: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.HUP, &act, &old_hup);
    old_sighup_action = old_hup;
}

pub fn uninstallAbnormalExitHandlers() void {
    if (!shell_runtime.supports_resize_signal) return;

    if (old_sigterm_action) |old| {
        std.posix.sigaction(std.posix.SIG.TERM, &old, null);
        old_sigterm_action = null;
    }
    if (old_sighup_action) |old| {
        std.posix.sigaction(std.posix.SIG.HUP, &old, null);
        old_sighup_action = null;
    }
}

pub const StartupState = struct {
    workspace_root: []u8 = &.{},
    workspace_access: workspace_access.WorkspaceAccess = .{},
    credential: ?credentials.Credential = null,
    credential_load_failure: ?credentials.LoadFailure = null,
    auth_mode: credentials.AuthMode = .local,
    credential_onboarding_skipped: bool = false,
    configured_providers: @import("../config/configured_provider.zig").Registry = .{},
    model_requests_blocked: bool = false,
    provider: model_provider.ProviderId = .codex,
    selected_model: []u8 = &.{},
    configured_model: []u8 = &.{},
    model_source: config_runtime.ModelSource = .compiled_default,
    permission_mode: PermissionMode = default_permission_mode,
    yolo_acknowledged: bool = false,
    permission_rules: types.PermissionRuleSet = .{},
    agent_step_limit: usize,
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    auto_compact_percent: u8 = compactor.default_percent,
    context_limits: config_runtime.context_limits.Values = .{},
    context_enabled: bool = true,
    fast_mode: bool = false,
    ultrafast_mode: bool = false,
    configured_ultrafast_mode: bool = false,
    ultrafast_process_override: ?bool = null,
    ultrafast_mode_source: config_runtime.ConfigSource = .compiled_default,
    fast_mode_model_bound: bool = false,
    fast_mode_source: config_runtime.ConfigSource = .compiled_default,
    slash_menu_categories: bool = true,
    collapse_tool_calls: bool = false,
    auto_upgrade: bool = true,
    update_channel: update_target.Channel = .stable,
    startup_scrollback: bool = true,
    prompt_history_enabled: bool = true,
    prompt_history_store_allowed: bool = true,
    config_diagnostics: []config_runtime.ConfigDiagnostic = &.{},
    effort: types.ReasoningEffort = .auto,
    /// Owned gateway provider slugs in preference order; empty leaves routing
    /// to the gateway.
    provider_order: [][]const u8 = &.{},
    provider_strict: bool = false,
    /// Resolved review-model override for automatic permission review. Owned;
    /// empty keeps the reviewer's compiled default.
    review_model: []u8 = &.{},
    first_call_tool_choice: types.ToolChoice = .auto,
    statusline_context: bool = false,
    statusline_session: bool = false,
    statusline_workspace: bool = false,
    session_title_generation: bool = true,
    notification_turn_end: bool = false,
    notification_attention_required: bool = false,
    notification_max: bool = false,
    theme_monitor_enabled: bool = false,
    theme: ?[]const u8 = null,

    pub fn deinit(self: *StartupState, alloc: Allocator) void {
        self.workspace_access.deinit(alloc);
        self.configured_providers.deinit(alloc);
        if (self.workspace_root.len > 0) alloc.free(self.workspace_root);
        if (self.credential) |*credential| credential.deinit(alloc);
        if (self.selected_model.len > 0) alloc.free(self.selected_model);
        if (self.configured_model.len > 0) alloc.free(self.configured_model);
        if (self.review_model.len > 0) alloc.free(self.review_model);
        if (self.provider_order.len > 0) {
            for (self.provider_order) |slug| alloc.free(@constCast(slug));
            alloc.free(self.provider_order);
        }
        self.permission_rules.deinit(alloc);
        if (self.config_diagnostics.len > 0) {
            for (self.config_diagnostics) |*diagnostic| diagnostic.deinit(alloc);
            alloc.free(self.config_diagnostics);
        }
        if (self.theme) |value| alloc.free(value);
        self.* = .{ .agent_step_limit = self.agent_step_limit };
    }

    pub fn takeWorkspaceRoot(self: *StartupState) []u8 {
        const value = self.workspace_root;
        self.workspace_root = &.{};
        return value;
    }

    pub fn takeWorkspaceAccess(self: *StartupState) workspace_access.WorkspaceAccess {
        const value = self.workspace_access;
        self.workspace_access = .{};
        return value;
    }

    pub fn apiKey(self: *const StartupState) ?[]const u8 {
        const credential = self.credential orelse return null;
        if (credential.needsRefreshAt(io_mod.milliTimestamp())) return null;
        return credential.token;
    }

    pub fn modelCatalogAccess(self: *const StartupState) credentials.CatalogAccess {
        if (self.auth_mode == .host_managed) return .host_managed;
        return credentials.catalogAccessAt(self.credential, io_mod.milliTimestamp());
    }

    pub fn takeCredential(self: *StartupState) ?credentials.Credential {
        const value = self.credential;
        self.credential = null;
        return value;
    }

    pub fn takeSelectedModel(self: *StartupState) []u8 {
        const value = self.selected_model;
        self.selected_model = &.{};
        return value;
    }

    /// Applies an interactive launch `--model` override. Like FX_MODEL, it
    /// marks a process override and drops compiled-default fast mode; an
    /// explicit --fast restores fast separately in applyLaunchTurnOverrides.
    pub fn applyLaunchModelOverride(self: *StartupState, alloc: Allocator, model: []const u8) !void {
        const owned = try alloc.dupe(u8, model);
        if (self.selected_model.len > 0) alloc.free(self.selected_model);
        self.selected_model = owned;
        self.model_source = .process_override;
        if (self.fast_mode_source == .compiled_default) {
            self.fast_mode = false;
            self.fast_mode_model_bound = false;
        }
    }

    /// Applies per-launch turn overrides after session preferences are
    /// configured, so they shape runtime state without rewriting persistence.
    pub fn applyLaunchTurnOverrides(self: *StartupState, effort: ?types.ReasoningEffort, fast: ?bool, ultrafast: ?bool) void {
        if (effort) |value| self.effort = value;
        if (fast) |value| {
            self.fast_mode = value;
            // An explicit --fast is bound to the launch model selection so the
            // footer indicator reflects it; --no-fast clears the binding.
            self.fast_mode_model_bound = value;
        }
        if (ultrafast) |value| {
            self.ultrafast_process_override = value;
            self.ultrafast_mode = value;
        }
        if (self.ultrafast_mode) self.fast_mode = false;
    }

    /// Applies per-launch `--provider-order`/`--provider-strict` flags. Like
    /// the turn overrides, flags shape this launch only and never rewrite
    /// stored settings.
    pub fn applyLaunchProviderRouting(self: *StartupState, alloc: Allocator, order: ?[]const []const u8, strict: ?bool) !void {
        if (order) |slugs| {
            const owned = try alloc.alloc([]const u8, slugs.len);
            var filled: usize = 0;
            errdefer {
                for (owned[0..filled]) |slug| alloc.free(@constCast(slug));
                alloc.free(owned);
            }
            for (slugs, 0..) |slug, index| {
                owned[index] = try alloc.dupe(u8, slug);
                filled += 1;
            }
            if (self.provider_order.len > 0) {
                for (self.provider_order) |slug| alloc.free(@constCast(slug));
                alloc.free(self.provider_order);
            }
            self.provider_order = owned;
        }
        if (strict) |value| self.provider_strict = value;
    }

    pub fn takePermissionRules(self: *StartupState) types.PermissionRuleSet {
        const value = self.permission_rules;
        self.permission_rules = .{};
        return value;
    }

    /// Moves the owned review-model override out; caller owns the bytes.
    pub fn takeReviewModel(self: *StartupState) []u8 {
        const value = self.review_model;
        self.review_model = &.{};
        return value;
    }
};

/// Where `fx status` found the selected model.
pub const ModelOrigin = enum {
    env,
    settings,
    default,

    pub fn label(self: ModelOrigin) []const u8 {
        return switch (self) {
            .env => "FX_MODEL",
            .settings => "settings",
            .default => "default",
        };
    }

    fn of(settings: *const config_runtime.Settings, provider: model_provider.ProviderId, env_model: ?[]const u8) ModelOrigin {
        if (env_model != null) return .env;
        return if (settings.models.get(provider) != null) .settings else .default;
    }
};

pub const StartupStatus = struct {
    workspace_root: []u8,
    provider_endpoint: ?[]u8 = null,
    provider: model_provider.ProviderId = .codex,
    selected_model: []const u8,
    owned_selected_model: ?[]u8 = null,
    model_origin: ModelOrigin = .default,
    /// The reasoning effort a new session starts with, as `StartupState` resolves it.
    effort: types.ReasoningEffort = .auto,
    ultrafast_mode: bool = false,
    auth: auth_runtime.StatusSnapshot = .{},
    permission_mode: PermissionMode,
    agent_step_limit: usize,
    update_channel: update_target.Channel = .stable,
    config_diagnostics: []config_runtime.ConfigDiagnostic = &.{},

    pub fn deinit(self: *StartupStatus, alloc: Allocator) void {
        alloc.free(self.workspace_root);
        if (self.provider_endpoint) |endpoint| alloc.free(endpoint);
        if (self.owned_selected_model) |model| alloc.free(model);
        if (self.config_diagnostics.len > 0) {
            for (self.config_diagnostics) |*diagnostic| diagnostic.deinit(alloc);
            alloc.free(self.config_diagnostics);
        }
        self.* = undefined;
    }
};

const StartupStatusModel = struct {
    value: []const u8,
    owned: ?[]u8 = null,
};

pub const BootstrapConfig = struct {
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    terminal_title: host.TerminalTitle,
    footer_rows: u16,
    startup_min_body_rows: u16 = 0,
    default_model: []const u8,
    default_agent_step_limit: usize,
    auth_mode: credentials.AuthMode = .local,
    resize_handler: ResizeHandler,
    fx_version: []const u8 = "",
    /// Interactive launch `--provider` override; null keeps the configured provider.
    provider_override: ?model_provider.ProviderId = null,
    /// Interactive launch `--model`; stands in for a provider without a saved model.
    model_override: ?[]const u8 = null,
};

pub fn loadStartupState(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !StartupState {
    return loadStartupStateWithAuthMode(
        alloc,
        transport,
        default_model,
        default_agent_step_limit,
        .local,
    );
}

pub fn loadStartupStateWithAuthMode(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    default_model: []const u8,
    default_agent_step_limit: usize,
    auth_mode: credentials.AuthMode,
) !StartupState {
    return loadStartupStateForRun(alloc, transport, default_model, default_agent_step_limit, auth_mode, null);
}

/// `model_override` is the run's `--model`. It stands in for a provider without
/// a saved model; callers still apply it over the selected or resumed model.
pub fn loadStartupStateForRun(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    default_model: []const u8,
    default_agent_step_limit: usize,
    auth_mode: credentials.AuthMode,
    model_override: ?[]const u8,
) !StartupState {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    return loadStartupStateFromOwnedWorkspace(alloc, transport, workspace_root, default_model, default_agent_step_limit, auth_mode, null, .refresh_if_needed, null, model_override);
}

pub fn loadStartupStateWithoutCredentials(alloc: Allocator, default_model: []const u8, default_agent_step_limit: usize) !StartupState {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    return loadStartupStateFromOwnedWorkspace(alloc, oauth_transport.unavailable_provider, workspace_root, default_model, default_agent_step_limit, .local, null, null, null, null);
}

pub fn loadCatalogStartupStateWithAuthMode(
    alloc: Allocator,
    default_model: []const u8,
    default_agent_step_limit: usize,
    auth_mode: credentials.AuthMode,
    provider_override: ?model_provider.ProviderId,
    model_override: ?[]const u8,
) !StartupState {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    return loadStartupStateFromOwnedWorkspace(alloc, oauth_transport.unavailable_provider, workspace_root, default_model, default_agent_step_limit, auth_mode, null, .stored, provider_override, model_override);
}

pub fn loadInteractiveStartupState(
    alloc: Allocator,
    default_model: []const u8,
    default_agent_step_limit: usize,
    auth_mode: credentials.AuthMode,
    provider_override: ?model_provider.ProviderId,
    model_override: ?[]const u8,
) !StartupState {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    return loadStartupStateFromOwnedWorkspace(alloc, oauth_transport.unavailable_provider, workspace_root, default_model, default_agent_step_limit, auth_mode, null, .stored, provider_override, model_override);
}

pub fn loadStartupStatus(
    alloc: Allocator,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !StartupStatus {
    return loadStartupStatusWithAuthMode(
        alloc,
        default_model,
        default_agent_step_limit,
        .local,
    );
}

pub fn loadStartupStatusWithAuthMode(
    alloc: Allocator,
    default_model: []const u8,
    default_agent_step_limit: usize,
    auth_mode: credentials.AuthMode,
) !StartupStatus {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    errdefer alloc.free(workspace_root);
    debug_trace.configureFromEnv(alloc, workspace_root);

    var detailed = try config_runtime.loadMergedSettingsDetailed(alloc, workspace_root);
    defer detailed.deinit(alloc);
    const settings = &detailed.settings;

    const run_model = config_runtime.modelEnvOverride();
    const configured_selection = try config_runtime.selectProviderModel(default_model, settings, null, run_model);
    const selected_model = try loadStartupStatusModel(alloc, configured_selection.model, null);
    errdefer if (selected_model.owned) |model| alloc.free(model);

    const auth_status = if (auth_mode == .host_managed)
        auth_runtime.StatusSnapshot{
            .active_source = .host_managed,
            .chatgpt_connected = true,
            .grok_connected = true,
        }
    else
        try auth_runtime.loadStatusSnapshotForProvider(alloc, configured_selection.provider);

    const definitions: @import("../config/configured_provider.zig").Registry = settings.providers orelse .{};
    const result = StartupStatus{
        .workspace_root = workspace_root,
        .provider_endpoint = if (definitions.get(configured_selection.provider.label())) |definition| try alloc.dupe(u8, definition.base_url) else null,
        .provider = configured_selection.provider,
        .selected_model = selected_model.value,
        .owned_selected_model = selected_model.owned,
        .model_origin = ModelOrigin.of(settings, configured_selection.provider, run_model),
        .effort = settings.effort orelse .auto,
        .ultrafast_mode = detailed.ultrafast_mode_env_override orelse (settings.ultrafast_mode orelse false),
        .auth = auth_status,
        .permission_mode = loadPermissionMode(settings.permission_mode),
        .agent_step_limit = loadAgentStepLimit(default_agent_step_limit, settings.max_agent_steps),
        .update_channel = settings.update_channel orelse .stable,
        .config_diagnostics = detailed.diagnostics,
    };
    detailed.diagnostics = &.{};
    return result;
}

pub fn applyWorkspaceLaunch(
    self: *StartupState,
    alloc: Allocator,
    command_line_directories: []const []const u8,
    saved_suppressed: bool,
) !void {
    try self.workspace_access.applyLaunch(
        alloc,
        self.workspace_root,
        command_line_directories,
        saved_suppressed,
    );
}

const CredentialLoadMode = credentials.LoadMode;

fn loadStartupStateFromOwnedWorkspace(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    owned_workspace_root: []u8,
    default_model: []const u8,
    default_agent_step_limit: usize,
    auth_mode: credentials.AuthMode,
    profile_home: ?[]const u8,
    credential_mode: ?CredentialLoadMode,
    provider_override: ?model_provider.ProviderId,
    model_override: ?[]const u8,
) !StartupState {
    var state = StartupState{
        .agent_step_limit = default_agent_step_limit,
        .auth_mode = auth_mode,
    };
    errdefer state.deinit(alloc);

    state.workspace_root = owned_workspace_root;
    debug_trace.configureFromEnv(alloc, state.workspace_root);
    var detailed = if (profile_home) |home_dir|
        try config_runtime.loadMergedSettingsDetailedFromHome(alloc, home_dir, state.workspace_root)
    else
        try config_runtime.loadMergedSettingsDetailed(alloc, state.workspace_root);
    defer detailed.deinit(alloc);
    const settings = &detailed.settings;
    // A malformed process override must never silently fall through to a
    // potentially paid profile preference, regardless of credential mode.
    for (detailed.diagnostics) |diagnostic| {
        if (diagnostic.cause == .invalid_ultrafast_mode_override) {
            return error.InvalidUltrafastOverride;
        }
    }
    // A rejected local profile cannot safely identify the destination of model data.
    if (auth_mode == .local) for (detailed.diagnostics) |diagnostic| {
        if (diagnostic.layer != .user) continue;
        switch (diagnostic.cause) {
            .durable_path_unsafe => {
                if (credential_mode != .stored) return error.InvalidProfileConfiguration;
                state.model_requests_blocked = true;
            },
            .malformed_settings,
            .settings_too_large,
            .invalid_model_id,
            => return error.InvalidProfileConfiguration,
            else => {},
        }
    };

    state.workspace_access = try workspace_access.WorkspaceAccess.init(
        alloc,
        state.workspace_root,
        detailed.additional_directory_sources orelse &.{},
        &.{},
        false,
    );
    // Skill authority checks run across discovery, refresh, and the skill tool,
    // so the profile setting is installed process-wide like the env var.
    try skill_runtime.setConfiguredSymlinkAuthorities(settings.skill_symlink_authorities orelse &.{});

    // A launch --provider override must bind configured provider names against
    // the registry just like the settings and FX_PROVIDER paths do.
    const bound_override = if (provider_override) |override|
        try override.bind(settings.providers orelse .{})
    else
        null;
    const run_model = model_override orelse config_runtime.modelEnvOverride();
    const configured_selection = try config_runtime.selectProviderModel(default_model, settings, bound_override, run_model);
    state.provider = configured_selection.provider;
    state.configured_providers = settings.providers orelse .{};
    settings.providers = null;
    state.configured_model = try alloc.dupe(u8, configured_selection.model);
    state.model_source = if (bound_override) |override|
        detailed.sources.models.get(model_provider.NameKey.fromProvider(override))
    else
        detailed.model_source orelse .compiled_default;
    state.selected_model = try loadInitialModel(alloc, configured_selection.model, null);
    if (hasProcessModelOverride()) state.model_source = .process_override;
    state.config_diagnostics = detailed.diagnostics;
    detailed.diagnostics = &.{};
    state.prompt_history_enabled = settings.prompt_history_enabled orelse true;
    state.prompt_history_store_allowed = detailed.prompt_history_store_allowed;
    if (auth_mode == .local and !state.model_requests_blocked) {
        if (credential_mode) |mode| {
            const resolution = try credentials.resolveForProvider(alloc, transport, mode, state.provider);
            state.credential = resolution.credential;
            state.credential_load_failure = resolution.failure;
        }
    }
    state.permission_mode = loadPermissionMode(settings.permission_mode);
    state.yolo_acknowledged = settings.yolo_acknowledged orelse false;
    state.permission_rules = try types.dupePermissionRuleSet(alloc, settings.permission_rules);
    state.agent_step_limit = loadAgentStepLimit(default_agent_step_limit, settings.max_agent_steps);
    state.max_tool_result_bytes = tool_result_limits.resolveMaxToolResultBytes(settings.max_tool_result_bytes, tool_result_limits.default_max_tool_result_bytes);
    state.auto_compact_percent = compactor.resolvePercent(settings.auto_compact_percent, io_mod.getenv("FX_AUTO_COMPACT_PERCENT"));
    state.context_limits = config_runtime.resolveContextLimits(settings, &.{});
    state.context_enabled = settings.context orelse true;
    const fast_mode = resolveStartupFastMode(
        state.model_source,
        settings.fast_mode,
        detailed.sources.fast_mode,
        settings.fast_mode_model_bound,
        detailed.sources.fast_mode_model_bound,
    );
    state.fast_mode = fast_mode.enabled;
    state.fast_mode_model_bound = fast_mode.model_bound;
    state.fast_mode_source = detailed.sources.fast_mode;
    state.configured_ultrafast_mode = settings.ultrafast_mode orelse false;
    state.ultrafast_process_override = detailed.ultrafast_mode_env_override;
    state.ultrafast_mode = state.ultrafast_process_override orelse state.configured_ultrafast_mode;
    state.ultrafast_mode_source = detailed.sources.ultrafast_mode;
    state.slash_menu_categories = settings.slash_menu_categories orelse true;
    state.collapse_tool_calls = settings.collapse_tool_calls orelse false;
    state.auto_upgrade = settings.auto_upgrade orelse true;
    state.update_channel = settings.update_channel orelse .stable;
    state.startup_scrollback = settings.startup_scrollback orelse true;
    state.theme = if (settings.theme) |value| try alloc.dupe(u8, value) else null;
    state.effort = settings.effort orelse .auto;
    state.review_model = try alloc.dupe(u8, settings.review_model orelse "");
    state.first_call_tool_choice = settings.first_call_tool_choice orelse .auto;
    state.provider_strict = settings.provider_strict orelse false;
    if (settings.provider_order) |order| {
        const owned_order = try alloc.alloc([]const u8, order.len);
        var filled: usize = 0;
        errdefer {
            for (owned_order[0..filled]) |slug| alloc.free(@constCast(slug));
            alloc.free(owned_order);
        }
        for (order, 0..) |slug, index| {
            owned_order[index] = try alloc.dupe(u8, slug);
            filled += 1;
        }
        state.provider_order = owned_order;
    }
    state.statusline_context = settings.statusline_context orelse false;
    state.statusline_session = settings.statusline_session orelse false;
    state.statusline_workspace = settings.statusline_workspace orelse false;
    state.session_title_generation = settings.session_titles orelse true;
    const sound_override = soundEnvOverride();
    const sound_on_override: ?bool = if (sound_override) |level| level != .off else null;
    const max_override: ?bool = if (sound_override) |level| level == .max else null;
    state.notification_turn_end = sound_on_override orelse settings.notification_turn_end orelse notification_sound.default_enabled;
    state.notification_attention_required = sound_on_override orelse settings.notification_attention_required orelse notification_sound.default_enabled;
    state.notification_max = max_override orelse settings.notification_max orelse false;

    return state;
}

const StartupFastMode = struct {
    enabled: bool,
    model_bound: bool,
};

fn resolveStartupFastMode(
    model_source: config_runtime.ModelSource,
    configured_fast_mode: ?bool,
    fast_mode_source: config_runtime.ConfigSource,
    model_bound: ?bool,
    binding_source: config_runtime.ConfigSource,
) StartupFastMode {
    if (configured_fast_mode) |enabled| {
        return .{
            .enabled = enabled,
            .model_bound = enabled and
                model_bound == true and
                model_source == fast_mode_source and
                fast_mode_source == binding_source,
        };
    }
    return .{ .enabled = false, .model_bound = false };
}

pub fn bootstrapInteractiveApp(cfg: BootstrapConfig) !StartupState {
    try cfg.terminal.ensureInteractive();
    try cfg.terminal.captureOriginalTermios();

    cfg.shell.sync_updates_enabled = shell_runtime.detectSyncUpdatesEnabled(cfg.alloc);
    cfg.shell.history_reset_uses_ris = shell_runtime.detectHistoryResetUsesRis(cfg.alloc);
    cfg.shell.layout = minimalLayout();
    try cfg.shell.initBacking(cfg.alloc);

    var state = try loadInteractiveStartupState(
        cfg.alloc,
        cfg.default_model,
        cfg.default_agent_step_limit,
        cfg.auth_mode,
        cfg.provider_override,
        cfg.model_override,
    );
    errdefer state.deinit(cfg.alloc);

    state.credential_onboarding_skipped = cfg.auth_mode == .host_managed or credentialOnboardingDisabled();

    errdefer shutdownInteractiveShell(
        cfg.terminal,
        cfg.shell,
        cfg.metrics,
        cfg.terminal_title,
    );

    try cfg.terminal.enableRawMode();
    cfg.terminal.installResizeSignal(cfg.resize_handler);
    installAbnormalExitHandlers(io_mod.getenv("TMUX"));
    cfg.shell.layout = try cfg.terminal.queryLayout(cfg.footer_rows);

    record_tape.configureFromEnv(
        cfg.alloc,
        cfg.shell.layout.cols,
        cfg.shell.layout.rows,
        cfg.fx_version,
    ) catch |err| {
        debug_trace.logf("record", "startup recording failed err={s}", .{@errorName(err)});
        return error.RecordingStartFailed;
    };

    // The shadow VT is load-bearing: frame commit diffs the target
    // surface against it and records the accepted terminal state.
    try cfg.shell.enableShadowVt(cfg.alloc);

    const truecolor = ui_render.truecolorSupportedForValues(
        io_mod.getenv("COLORTERM"),
        io_mod.getenv("TERM_PROGRAM"),
    );
    ui_render.setTruecolorSupport(truecolor);
    // Theme selection: FX_THEME wins over the settings "theme" key; an empty
    // FX_THEME counts as unset per the codebase convention. light/dark pin the
    // builtin variant and skip the OSC 11 probe; any other value names a theme
    // file under ~/.fx/themes.
    var configured_theme: ?[]const u8 = state.theme;
    if (io_mod.getenv("FX_THEME")) |value| {
        if (value.len > 0) configured_theme = value;
    }
    if (if (configured_theme) |value| shared_theme.classifyValue(value) else null) |choice| {
        switch (choice) {
            .pin_light, .pin_dark => {
                const light = choice == .pin_light;
                // The flag marks "pinned", not the direction: any configured
                // pin locks live theme updates out.
                shared_theme.setSource(null, true);
                ui_render.initTheme(light, null);
            },
            .custom => |name| {
                shared_theme.setSource(name, false);
                const detected = ui_render.detectTheme(cfg.alloc, cfg.terminal);
                const custom_theme = shared_theme.resolveNamed(cfg.alloc, name, detected.light, .{ .truecolor = truecolor }) catch |err| blk: {
                    debug_trace.logf("theme", "custom_theme_resolve_failed name={s} err={s}", .{ name, @errorName(err) });
                    break :blk null;
                };
                if (custom_theme) |resolved| {
                    ui_render.applyTheme(resolved, detected.rgb);
                } else {
                    ui_render.initTheme(detected.light, detected.rgb);
                }
            },
        }
    } else {
        shared_theme.setSource(null, false);
        const detected = ui_render.detectTheme(cfg.alloc, cfg.terminal);
        ui_render.initTheme(detected.light, detected.rgb);
    }
    // Custom themes keep live monitoring: terminal mode flips re-resolve the
    // theme pair. Only a configured light/dark pin locks updates out.
    state.theme_monitor_enabled = !ui_render.themeInputLocked();

    const cursor = cfg.terminal.queryCursorPosition() catch blk: {
        break :blk CursorPosition{
            .row = cfg.shell.layout.content_bottom,
            .col = 1,
        };
    };
    const start_row = blk: {
        var row = cursor.row;
        if (cursor.col > 1 and row < cfg.shell.layout.rows) row += 1;
        break :blk row;
    };
    var launch_start_row = start_row;
    const effective_startup_min_body_rows = try prepareStartupViewport(
        cfg.shell,
        cfg.metrics,
        &launch_start_row,
        cfg.startup_min_body_rows,
        state.startup_scrollback,
    );
    // Enable keyboard/paste protocol modes and disable autowrap for the
    // interactive session. Shutdown restores each mode.
    try enableInteractiveTerminalModes(cfg.shell, cfg.metrics);
    try cfg.shell.initViewportWithReservedRows(cfg.metrics, launch_start_row, effective_startup_min_body_rows);

    return state;
}

fn prepareStartupViewport(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    launch_start_row: *u16,
    startup_min_body_rows: u16,
    startup_scrollback: bool,
) !u16 {
    if (startup_scrollback and launch_start_row.* > 1) {
        try pushLaunchRowsIntoScrollback(shell, metrics, launch_start_row.* - 1);
        launch_start_row.* = 1;
    } else if (shell.layout.content_bottom > 0) {
        const reserve_rows = @min(startup_min_body_rows, shell.layout.content_bottom);
        const max_start_row = if (reserve_rows > 0)
            shell.layout.content_bottom - reserve_rows + 1
        else
            shell.layout.content_bottom;
        if (launch_start_row.* > max_start_row) {
            try pushLaunchRowsIntoScrollback(shell, metrics, launch_start_row.* - max_start_row);
            launch_start_row.* = max_start_row;
        }
    }
    return startup_min_body_rows;
}

fn pushLaunchRowsIntoScrollback(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    rows: u16,
) !void {
    if (rows == 0 or shell.layout.rows == 0) return;
    debug_trace.logf("render", "launch_scrollback_push rows={d} cols={d} content_bottom={d}", .{
        rows,
        shell.layout.cols,
        shell.layout.content_bottom,
    });
    var cursor_buf: [32]u8 = undefined;
    const cursor = try ui_terminal.moveCursorSequence(&cursor_buf, shell.layout.rows, 1);
    try writeLifecycleTerminalBytes(shell, metrics, cursor);

    var newlines: [64]u8 = undefined;
    @memset(newlines[0..], '\n');
    var remaining = rows;
    while (remaining > 0) {
        const count: u16 = @min(remaining, newlines.len);
        try writeLifecycleTerminalBytes(shell, metrics, newlines[0..count]);
        remaining -= count;
    }
}

pub fn shutdownInteractiveShell(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    terminal_title: host.TerminalTitle,
) void {
    leaveAlternateScreens(terminal, shell, metrics);
    terminal.uninstallResizeSignal();
    uninstallAbnormalExitHandlers();
    _ = writeLifecycleTerminalBytes(shell, metrics, normalExitRestoreSequence(io_mod.getenv("TMUX"))) catch {};
    terminal_title.clear();
    record_tape.shutdown();
    finishLeavingInteractiveMode(terminal, shell, metrics);
}

/// Stage timing for interactive shutdown. Each mark logs the delta since the
/// previous stage plus the total, so a slow exit names its stage in
/// FX_TRACE_LOG under the "shutdown" scope. Stages are also recorded in
/// memory and persisted at exit, so the next session's /trace report shows
/// the last shutdown breakdown without any flag.
pub const ShutdownStageTrace = struct {
    pub const max_recorded_stages = 16;

    pub const Stage = struct {
        name: []const u8,
        step_ms: i64,
        total_ms: i64,
    };

    started_ms: i64,
    last_ms: i64,
    stages: [max_recorded_stages]Stage = undefined,
    stages_len: usize = 0,

    pub fn init() ShutdownStageTrace {
        const now_ms = io_mod.milliTimestamp();
        return .{ .started_ms = now_ms, .last_ms = now_ms };
    }

    pub fn mark(self: *ShutdownStageTrace, stage: []const u8) void {
        const now_ms = io_mod.milliTimestamp();
        const step_ms = now_ms - self.last_ms;
        const total_ms = now_ms - self.started_ms;
        debug_trace.logf(
            "shutdown",
            "stage name={s} step_ms={d} total_ms={d}",
            .{ stage, step_ms, total_ms },
        );
        self.last_ms = now_ms;
        if (self.stages_len < max_recorded_stages) {
            self.stages[self.stages_len] = .{ .name = stage, .step_ms = step_ms, .total_ms = total_ms };
            self.stages_len += 1;
        }
    }

    pub fn recordedStages(self: *const ShutdownStageTrace) []const Stage {
        return self.stages[0..self.stages_len];
    }

    pub fn totalMs(self: *const ShutdownStageTrace) i64 {
        return self.last_ms - self.started_ms;
    }
};

/// Persists the shutdown breakdown for the next session's /trace report.
/// Best-effort: a diagnostics write failure must never fail exit.
pub fn writeLastShutdownReport(alloc: Allocator, trace: *const ShutdownStageTrace) void {
    writeLastShutdownReportInner(alloc, trace) catch |err| {
        debug_trace.logf("shutdown", "last shutdown report write failed err={s}", .{@errorName(err)});
    };
}

fn writeLastShutdownReportInner(alloc: Allocator, trace: *const ShutdownStageTrace) !void {
    const home = io_mod.getenv("HOME") orelse return;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"version\":1,\"recorded_at_ms\":");
    try out.writer.print("{d}", .{io_mod.milliTimestamp()});
    try out.writer.writeAll(",\"total_ms\":");
    try out.writer.print("{d}", .{trace.totalMs()});
    try out.writer.writeAll(",\"stages\":[");
    for (trace.recordedStages(), 0..) |stage, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"name\":\"{s}\",\"step_ms\":{d},\"total_ms\":{d}}}",
            .{ stage.name, stage.step_ms, stage.total_ms },
        );
    }
    try out.writer.writeAll("]}");

    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    defer fx_dir.close();
    var diagnostics = try io_mod.openOrCreateVerifiedPrivateDir(&fx_dir, profile_paths.diagnostics_dir_name);
    defer diagnostics.close();
    try io_mod.durableReplaceVerified(
        alloc,
        &diagnostics,
        profile_paths.last_shutdown_report_file_name,
        out.writer.buffered(),
    );
}

/// Reads the persisted shutdown breakdown for the /trace report. Returns the
/// owned file contents; caller frees. Missing or unreadable file is null.
pub fn readLastShutdownReport(alloc: Allocator) ?[]u8 {
    const home = io_mod.getenv("HOME") orelse return null;
    const path = profile_paths.lastShutdownReportPath(alloc, home) catch return null;
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return null;
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 64 * 1024) catch null;
}

/// Cooked-mode handoff for Ctrl-Z / SIGTSTP. Same terminal restore as
/// shutdown, but keeps signal handlers, title, and recording so resume can
/// continue the same session.
fn suspendTerminalForJobControl(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) void {
    leaveAlternateScreens(terminal, shell, metrics);
    _ = writeLifecycleTerminalBytes(shell, metrics, normalExitRestoreSequence(io_mod.getenv("TMUX"))) catch {};
    finishLeavingInteractiveMode(terminal, shell, metrics);
}

/// Raise SIGTSTP after restoring cooked mode; on SIGCONT rebuild interactive
/// terminal state and request a full repaint. Platforms without job-control
/// signals (same set as `supports_resize_signal`) are a no-op.
pub fn suspendToJobControl(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    footer_rows: u16,
) !void {
    if (!shell_runtime.supports_resize_signal) return;

    suspendTerminalForJobControl(terminal, shell, metrics);
    _ = std.c.raise(std.posix.SIG.TSTP);
    try resumeTerminalAfterJobControl(terminal, shell, metrics, footer_rows);
}

fn leaveAlternateScreens(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) void {
    switch (terminal.alternate_screen_owner) {
        .none => {},
        .file_approval => _ = leaveApprovalScreen(terminal, shell, metrics) catch {},
        .full_transcript => _ = leaveFullTranscriptScreen(terminal, shell, metrics) catch {},
        .catalog_menu => _ = leaveCatalogMenuScreen(terminal, shell, metrics) catch {},
    }
}

fn finishLeavingInteractiveMode(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) void {
    shell.footer_viewport.eraseCurrentFrame(shell, metrics) catch {};
    terminal.disableRawMode();
    emitShutdownCleanupAndResume(shell, metrics);
}

/// Re-arm raw mode after a job-control continue, re-query layout in case the
/// terminal was resized while stopped, then request a full repaint.
fn resumeTerminalAfterJobControl(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    footer_rows: u16,
) !void {
    shell.layout = terminal.queryLayout(footer_rows) catch shell.layout;
    try terminal.captureOriginalTermios();
    try terminal.enableRawMode();
    try enableInteractiveTerminalModes(shell, metrics);
    try shell.requestTerminalReset(metrics);
    shell.render_requests.request(.first_frame);
}

fn enableInteractiveTerminalModes(shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try writeLifecycleTerminalBytes(
        shell,
        metrics,
        ui_terminal.interactiveModeEnableSequence(io_mod.getenv("TMUX")),
    );
}

fn normalExitRestoreSequence(tmux: ?[]const u8) []const u8 {
    return if (tmux == null)
        normal_exit_restore
    else
        tmux_normal_exit_restore;
}

/// Full transcript steady state is `active`: the terminal owns the
/// full-transcript alternate screen and the shell projection is active.
/// The drift states exist only while a recovery or approval handoff path
/// is resolving a partially transitioned screen.
const FullTranscriptLifecycleState = enum {
    inactive,
    active,
    terminal_only,
    projection_only,
};

pub const FullTranscriptApprovalTransition = enum {
    inactive,
    closed,
    handed_off,
};

fn fullTranscriptLifecycleState(
    terminal: *const TerminalState,
    shell: *const TranscriptRuntime,
) FullTranscriptLifecycleState {
    const terminal_active = terminal.fullTranscriptScreenActive();
    const projection_active = shell.fullTranscriptActive();
    if (terminal_active and projection_active) return .active;
    if (terminal_active) return .terminal_only;
    if (projection_active) return .projection_only;
    return .inactive;
}

fn fullTranscriptActive(
    terminal: *const TerminalState,
    shell: *const TranscriptRuntime,
) bool {
    return fullTranscriptStateIsActive(fullTranscriptLifecycleState(terminal, shell));
}

fn fullTranscriptStateIsActive(state: FullTranscriptLifecycleState) bool {
    return state != .inactive;
}

fn fullTranscriptStateOwnsAlternateScreen(state: FullTranscriptLifecycleState) bool {
    return state == .active or state == .terminal_only;
}

fn fullTranscriptStateDrifted(state: FullTranscriptLifecycleState) bool {
    return state == .terminal_only or state == .projection_only;
}

pub fn closeFullTranscriptIfActive(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !bool {
    if (!fullTranscriptActive(terminal, shell)) return false;
    try closeFullTranscript(alloc, terminal, shell, metrics);
    return true;
}

pub fn recoverFullTranscriptDriftBeforeRender(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !bool {
    const state = fullTranscriptLifecycleState(terminal, shell);
    if (!fullTranscriptStateDrifted(state)) return false;

    debug_trace.logf(
        "full_transcript",
        "reconcile_before_render state={s} action=recover_to_inline",
        .{@tagName(state)},
    );
    try closeFullTranscript(alloc, terminal, shell, metrics);
    return true;
}

pub fn transitionFullTranscriptForApproval(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    approval_screen_active: bool,
) !FullTranscriptApprovalTransition {
    const state = fullTranscriptLifecycleState(terminal, shell);
    if (!fullTranscriptStateIsActive(state)) return .inactive;

    if (approval_screen_active and fullTranscriptStateOwnsAlternateScreen(state)) {
        try handoffFullTranscriptToApproval(alloc, terminal, shell, metrics);
        return .handed_off;
    }

    try closeFullTranscript(alloc, terminal, shell, metrics);
    return .closed;
}

pub fn enterApprovalScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try enterAlternateScreen(terminal, shell, metrics, .file_approval);
}

pub fn leaveApprovalScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try leaveAlternateScreen(terminal, shell, metrics, .file_approval);
}

pub fn approvalInlineRestoreTransition(
    terminal: *const TerminalState,
) terminal_diff.FrameTerminalTransition {
    if (!terminal.fileApprovalScreenActive()) return .none;
    return .{ .restore_normal_screen = .{
        .mouse_tracking_active = terminal.alternate_mouse_tracking_active,
    } };
}

pub fn commitApprovalInlineRestore(terminal: *TerminalState) void {
    if (!terminal.fileApprovalScreenActive()) return;
    terminal.alternate_mouse_tracking_active = false;
    terminal.alternate_screen_owner = .none;
    terminal.alternate_frame_layout = .{};
}

pub fn setApprovalScreenMouseTracking(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    enabled: bool,
) !void {
    try setAlternateScreenMouseTracking(terminal, shell, metrics, .file_approval, enabled);
}

pub fn leaveCatalogMenuScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try leaveAlternateScreen(terminal, shell, metrics, .catalog_menu);
}

pub fn openFullTranscript(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    if (terminal.alternate_screen_owner != .none and !terminal.fullTranscriptScreenActive()) {
        return error.AlternateScreenAlreadyOwned;
    }

    try setFullTranscriptProjection(alloc, shell, .full);
    errdefer {
        if (terminal.fullTranscriptScreenActive()) {
            leaveFullTranscriptScreen(terminal, shell, metrics) catch {};
        }
        setFullTranscriptProjection(alloc, shell, .inline_mode) catch {};
    }

    try enterFullTranscriptScreen(terminal, shell, metrics);
}

pub fn closeFullTranscript(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    const primary_restore = shell.fullTranscriptPrimaryRestore();
    debug_trace.logf(
        "full_transcript",
        "close_full_transcript restore={s}",
        .{@tagName(primary_restore)},
    );
    if (terminal.fullTranscriptScreenActive()) {
        try leaveFullTranscriptScreen(terminal, shell, metrics);
    }
    try setFullTranscriptProjection(alloc, shell, .inline_mode);
    switch (primary_restore) {
        .changed => {},
        .exact => shell.retainRestoredPrimaryTranscript(),
        .resized => shell.repaintRestoredPrimaryTranscriptAfterResize(),
    }
}

pub fn handoffFullTranscriptToApproval(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    if (!fullTranscriptStateOwnsAlternateScreen(fullTranscriptLifecycleState(terminal, shell))) {
        return error.FullTranscriptScreenNotActive;
    }
    try setFullTranscriptScreenMouseTracking(terminal, shell, metrics, true);
    const from = shell.transcriptPresentationDepth();
    try setFullTranscriptProjection(alloc, shell, .inline_mode);
    debug_trace.logf(
        "full_transcript",
        "depth_transition from={s} to=inline route=root trigger=approval_handoff",
        .{switch (from) {
            .inline_mode => "inline",
            .full => "full",
        }},
    );
    terminal.alternate_screen_owner = .file_approval;
    terminal.alternate_frame_layout = .{};
}

fn setFullTranscriptProjection(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    depth: transcript_presentation.Depth,
) !void {
    _ = try shell.setTranscriptPresentationDepth(alloc, depth);
}

fn enterFullTranscriptScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try enterAlternateScreen(terminal, shell, metrics, .full_transcript);
}

fn leaveFullTranscriptScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try leaveAlternateScreen(terminal, shell, metrics, .full_transcript);
}

fn setFullTranscriptScreenMouseTracking(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    enabled: bool,
) !void {
    try setAlternateScreenMouseTracking(terminal, shell, metrics, .full_transcript, enabled);
}

fn enterAlternateScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    owner: shell_runtime.AlternateScreenOwner,
) !void {
    if (terminal.alternate_screen_owner == owner) return;
    if (terminal.alternate_screen_owner != .none) return error.AlternateScreenAlreadyOwned;
    // Keep the flag set if the write fails so shutdown still attempts a restore.
    terminal.alternate_screen_owner = owner;
    terminal.alternate_frame_layout = .{};
    try writeLifecycleTerminalBytes(shell, metrics, alternate_screen_enter);
}

fn leaveAlternateScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    owner: shell_runtime.AlternateScreenOwner,
) !void {
    if (terminal.alternate_screen_owner != owner) return;
    const restore = ui_terminal.alternateScreenLeaveSequence(
        terminal.alternate_mouse_tracking_active,
    );
    try writeLifecycleTerminalBytes(shell, metrics, restore);
    terminal.alternate_mouse_tracking_active = false;
    terminal.alternate_screen_owner = .none;
    terminal.alternate_frame_layout = .{};
}

fn setAlternateScreenMouseTracking(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    owner: shell_runtime.AlternateScreenOwner,
    enabled: bool,
) !void {
    if (terminal.alternate_screen_owner != owner or
        terminal.alternate_mouse_tracking_active == enabled)
    {
        return;
    }
    if (enabled) {
        // Keep the state armed on an enable write failure so leave/shutdown
        // still attempts to restore the terminal mode.
        terminal.alternate_mouse_tracking_active = true;
        try writeLifecycleTerminalBytes(shell, metrics, alternate_mouse_tracking_enter);
        return;
    }

    // Keep the state armed on a disable failure so leave/shutdown still
    // attempts to restore the terminal mode.
    try writeLifecycleTerminalBytes(
        shell,
        metrics,
        ui_terminal.alternate_mouse_tracking_leave_sequence,
    );
    terminal.alternate_mouse_tracking_active = false;
}

fn emitShutdownCleanupAndResume(shell: *TranscriptRuntime, metrics: *Metrics) void {
    if (shell.sync_updates_enabled) {
        _ = writeLifecycleTerminalBytes(shell, metrics, "\x1b[?2026l") catch {};
    }
    _ = writeLifecycleTerminalBytes(shell, metrics, "\x1b[?7h\x1b[0m") catch {};

    var cursor_buf: [32]u8 = undefined;
    if (ui_terminal.moveCursorSequence(&cursor_buf, shutdownCleanupRow(shell), 1)) |cursor| {
        _ = writeLifecycleTerminalBytes(shell, metrics, cursor) catch {};
    } else |_| {}
    _ = writeLifecycleTerminalBytes(shell, metrics, "\x1b[J\x1b[?25h\n") catch {};
}

pub fn writeLifecycleTerminalBytes(shell: *TranscriptRuntime, metrics: *Metrics, bytes: []const u8) !void {
    try shell.stdout_file.writeStreamingAll(io_mod.getIo(), bytes);
    if (shell.shadow_vt) |grid| {
        grid.feed(bytes) catch |err| debug_trace.logf(
            "render",
            "lifecycle_shadow_feed_drop bytes={d} err={s}",
            .{ bytes.len, @errorName(err) },
        );
    }
    record_tape.recordStdout(bytes);
    metrics.ansi_bytes += bytes.len;
}

fn shutdownCleanupRow(shell: *const TranscriptRuntime) u16 {
    const row = if (shell.footer_viewport.has_frame)
        shell.footer_viewport.geometry.top
    else
        shell.cursor_row;

    if (row == 0) return 1;
    if (shell.layout.rows == 0) return row;
    return @min(row, shell.layout.rows);
}

fn loadPermissionMode(configured: ?PermissionMode) PermissionMode {
    const fallback = configured orelse default_permission_mode;
    const mode = io_mod.getenv("FX_PERMISSION_MODE") orelse return fallback;
    return config_runtime.parsePermissionMode(mode) orelse fallback;
}

fn loadAgentStepLimit(fallback: usize, configured: ?usize) usize {
    return agent_steps.resolveMaxAgentStepsWithOverride(
        configured,
        fallback,
        io_mod.getenv("FX_MAX_AGENT_STEPS"),
    );
}

fn initialModelId(default_model: []const u8, configured: ?[]const u8) []const u8 {
    return config_runtime.modelEnvOverride() orelse configured orelse default_model;
}

fn loadInitialModel(alloc: Allocator, default_model: []const u8, configured: ?[]const u8) ![]u8 {
    return alloc.dupe(u8, initialModelId(default_model, configured));
}

fn hasProcessModelOverride() bool {
    return config_runtime.modelEnvOverride() != null;
}

fn loadStartupStatusModel(alloc: Allocator, default_model: []const u8, configured: ?[]const u8) !StartupStatusModel {
    const owned = try alloc.dupe(u8, initialModelId(default_model, configured));
    return .{ .value = owned, .owned = owned };
}

fn credentialOnboardingDisabled() bool {
    const value = io_mod.getenv("FX_SKIP_ONBOARDING") orelse return false;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return false;
    return !std.mem.eql(u8, trimmed, "0") and !std.ascii.eqlIgnoreCase(trimmed, "false");
}

const SoundEnvLevel = enum { off, on, max };

fn soundEnvOverride() ?SoundEnvLevel {
    const value = io_mod.getenv("FX_SOUND") orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "max")) return .max;
    const off = std.mem.eql(u8, trimmed, "0") or
        std.ascii.eqlIgnoreCase(trimmed, "false") or
        std.ascii.eqlIgnoreCase(trimmed, "off");
    return if (off) .off else .on;
}

fn minimalLayout() types.Layout {
    return .{
        .rows = 1,
        .cols = 1,
        .content_bottom = 1,
        .divider_top_row = 1,
        .input_row = 1,
        .divider_bottom_row = 1,
        .hint_row = 1,
    };
}

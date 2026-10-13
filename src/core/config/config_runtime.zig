const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const compactor = @import("../compactor/compactor.zig");
const types = @import("../shared/types.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const settings_store = @import("settings_store.zig");
const model_provider = @import("model_provider.zig");
const model_preferences = @import("model_preferences.zig");
const configured_provider = @import("configured_provider.zig");
const update_target = @import("../upgrade/update_target.zig");
pub const context_limits = @import("context_limits.zig");

const Allocator = std.mem.Allocator;
const max_settings_bytes: usize = 64 * 1024;
pub const default_permission_mode: types.PermissionMode = .auto;

pub const Paths = struct {
    home_dir: ?[]u8 = null,
    user_settings: ?[]u8 = null,
    workspace_settings: []u8,
    home_fx_dir: ?[]u8 = null,
    sessions_dir: ?[]u8 = null,
    workspace_root: []u8,

    pub fn deinit(self: *Paths, alloc: Allocator) void {
        if (self.home_dir) |path| alloc.free(path);
        if (self.user_settings) |path| alloc.free(path);
        alloc.free(self.workspace_settings);
        if (self.home_fx_dir) |path| alloc.free(path);
        if (self.sessions_dir) |path| alloc.free(path);
        alloc.free(self.workspace_root);
        self.* = undefined;
    }
};

pub const Settings = struct {
    providers: ?configured_provider.Registry = null,
    models: model_preferences.Preferences = .{},
    provider: ?model_provider.ProviderId = null,
    permission_mode: ?types.PermissionMode = null,
    yolo_acknowledged: ?bool = null,
    max_agent_steps: ?usize = null,
    max_tool_result_bytes: ?usize = null,
    /// Share of usable input, 10 to 80 percent, at which automatic
    /// compaction starts. Profile-only.
    auto_compact_percent: ?u8 = null,
    context_limits: context_limits.Overrides = .{},
    first_call_tool_choice: ?types.ToolChoice = null,
    context: ?bool = null,
    fast_mode: ?bool = null,
    ultrafast_mode: ?bool = null,
    fast_mode_model_bound: ?bool = null,
    /// Owned gateway provider slugs in preference order; null leaves routing
    /// to the gateway. Freed in deinit.
    provider_order: ?[][]const u8 = null,
    provider_strict: ?bool = null,
    slash_menu_categories: ?bool = null,
    collapse_tool_calls: ?bool = null,
    auto_upgrade: ?bool = null,
    update_channel: ?update_target.Channel = null,
    theme: ?[]const u8 = null,
    startup_scrollback: ?bool = null,
    prompt_history_enabled: ?bool = null,
    effort: ?types.ReasoningEffort = null,
    /// Optional review-model override for automatic permission review. Owned by
    /// this Settings; freed in deinit. Null keeps the provider's default.
    review_model: ?[]const u8 = null,
    statusline_context: ?bool = null,
    statusline_session: ?bool = null,
    statusline_workspace: ?bool = null,
    session_titles: ?bool = null,
    notification_turn_end: ?bool = null,
    notification_attention_required: ?bool = null,
    notification_max: ?bool = null,
    permission_rules: types.PermissionRuleSet = .{},
    has_permission_rules: bool = false,
    /// Owned absolute directories whose contents symlinked skills may resolve
    /// into. Profile-only; a later layer replaces the whole list. Freed in deinit.
    skill_symlink_authorities: ?[][]u8 = null,

    pub fn deinit(self: *Settings, alloc: Allocator) void {
        if (self.skill_symlink_authorities) |paths| freeStringSlice(alloc, paths);
        self.models.deinit(alloc);
        if (self.providers) |*providers| providers.deinit(alloc);
        self.permission_rules.deinit(alloc);
        if (self.review_model) |value| alloc.free(value);
        if (self.theme) |value| alloc.free(value);
        if (self.provider_order) |order| {
            for (order) |slug| alloc.free(@constCast(slug));
            alloc.free(order);
        }
        self.* = .{};
    }
};

pub const StartupStatusSettings = struct {
    model: ?[]u8 = null,
    permission_mode: ?types.PermissionMode = null,
    max_agent_steps: ?usize = null,

    pub fn deinit(self: *StartupStatusSettings, alloc: Allocator) void {
        if (self.model) |value| alloc.free(value);
        self.* = .{};
    }
};

pub const ConfigLayer = enum {
    user,
    project,
};

pub const ConfigSource = enum {
    compiled_default,
    user_global,
    project,
    user_workspace,
    process_override,
};

pub const ModelSource = ConfigSource;

pub const ConfigSources = struct {
    models: ProviderModelSources = .{},
    provider: ConfigSource = .compiled_default,
    permission_mode: ConfigSource = .compiled_default,
    effort: ConfigSource = .compiled_default,
    fast_mode: ConfigSource = .compiled_default,
    ultrafast_mode: ConfigSource = .compiled_default,
    fast_mode_model_bound: ConfigSource = .compiled_default,
    slash_menu_categories: ConfigSource = .compiled_default,
    collapse_tool_calls: ConfigSource = .compiled_default,
    startup_scrollback: ConfigSource = .compiled_default,
    prompt_history_enabled: ConfigSource = .compiled_default,
    statusline_context: ConfigSource = .compiled_default,
    statusline_session: ConfigSource = .compiled_default,
    session_titles: ConfigSource = .compiled_default,
    notification_turn_end: ConfigSource = .compiled_default,
    notification_attention_required: ConfigSource = .compiled_default,
    notification_max: ConfigSource = .compiled_default,
};

pub const ProviderModelSources = struct {
    const Entry = struct { provider: model_provider.NameKey, source: ConfigSource };
    entries: [model_preferences.max_preferences]?Entry = @splat(null),

    pub fn get(self: *const ProviderModelSources, provider: model_provider.NameKey) ConfigSource {
        for (self.entries) |entry| if (entry) |*value| {
            if (value.provider.eqlName(provider.label())) return value.source;
        };
        return .compiled_default;
    }

    pub fn set(self: *ProviderModelSources, provider: model_provider.NameKey, source: ConfigSource) !void {
        for (&self.entries) |*entry| {
            if (entry.*) |*value| {
                if (!value.provider.eqlName(provider.label())) continue;
                value.source = source;
                return;
            } else {
                entry.* = .{ .provider = provider, .source = source };
                return;
            }
        }
        return error.TooManyModelPreferences;
    }
};

pub fn resolveContextLimits(settings: *const Settings, command_line: []const context_limits.Override) context_limits.Values {
    var values = context_limits.Values{};
    values.apply(settings.context_limits);
    values.applyCommandLine(command_line);
    return values;
}

pub const PermissionSourceViews = struct {
    user: types.PermissionRuleSet = .{},
    local: types.PermissionRuleSet = .{},
    user_shadowed_by_local: bool = false,

    pub fn deinit(self: *PermissionSourceViews, alloc: Allocator) void {
        self.user.deinit(alloc);
        self.local.deinit(alloc);
        self.* = .{};
    }
};

pub const ConfigDiagnosticCause = enum {
    malformed_settings,
    settings_too_large,
    durable_path_unsafe,
    private_state_permissions_unsupported,
    invalid_model_id,
    ignored_project_user_only_setting,
    legacy_workspace_preferences,
    manual_backup_available,
    retired_skill_match_fuzzy,
    invalid_context_limits,
    invalid_additional_directories,
    invalid_skill_symlink_authorities,
    invalid_ultrafast_mode_override,
};

pub const ConfigDiagnostic = struct {
    layer: ConfigLayer,
    cause: ConfigDiagnosticCause,
    setting_key: ?[]u8 = null,
    recovery_path: ?[]u8 = null,

    pub fn reportAtStartup(self: ConfigDiagnostic) bool {
        return self.cause != .legacy_workspace_preferences;
    }

    pub fn deinit(self: *ConfigDiagnostic, alloc: Allocator) void {
        if (self.setting_key) |key| alloc.free(key);
        if (self.recovery_path) |path| alloc.free(path);
        self.* = undefined;
    }
};

pub fn writeDiagnosticMetadata(writer: *std.Io.Writer, diagnostic: ConfigDiagnostic) !void {
    if (diagnostic.setting_key) |key| try writer.print("; key={s}", .{key});
    if (diagnostic.recovery_path) |path| try writer.print("; recovery={s}", .{path});
    if (diagnostic.cause == .retired_skill_match_fuzzy) {
        try writer.writeAll("; remove skill_match_fuzzy; skills now load only through explicit invocation or the skill tool");
    }
    if (diagnostic.cause == .invalid_context_limits) {
        try writer.writeAll("; context_limits keys must be documented limit names with a non-negative integer or \"off\" value");
    }
    if (diagnostic.cause == .invalid_additional_directories) {
        try writer.print(
            "; additional_directories must be an array of at most {d} unique absolute directory paths for the current primary workspace",
            .{workspace_access.max_additional_directories},
        );
    }
    if (diagnostic.cause == .invalid_skill_symlink_authorities) {
        try writer.print(
            "; skill_symlink_authorities must be an array of at most {d} absolute directory paths without .. components",
            .{max_skill_symlink_authorities},
        );
    }
    if (diagnostic.cause == .invalid_ultrafast_mode_override) {
        try writer.writeAll("; FX_ULTRAFAST must be a boolean value");
    }
}

/// Upper bound on profile `skill_symlink_authorities` entries.
const max_skill_symlink_authorities: usize = 32;

pub const DetailedSettings = struct {
    settings: Settings,
    diagnostics: []ConfigDiagnostic = &.{},
    model_source: ?ModelSource = null,
    sources: ConfigSources = .{},
    /// Process-only override; null leaves the profile preference in effect.
    ultrafast_mode_env_override: ?bool = null,
    permission_sources: PermissionSourceViews = .{},
    prompt_history_store_allowed: bool = true,
    additional_directories: ?[][]u8 = null,
    additional_directory_sources: ?[][]u8 = null,

    pub fn deinit(self: *DetailedSettings, alloc: Allocator) void {
        self.settings.deinit(alloc);
        self.permission_sources.deinit(alloc);
        if (self.additional_directories) |paths| freeStringSlice(alloc, paths);
        if (self.additional_directory_sources) |paths| freeStringSlice(alloc, paths);
        if (self.diagnostics.len > 0) {
            for (self.diagnostics) |*diagnostic| diagnostic.deinit(alloc);
            alloc.free(self.diagnostics);
        }
        self.* = undefined;
    }
};

pub fn discoverPaths(alloc: Allocator, workspace_root: []const u8) !Paths {
    return discoverPathsWithOptionalHome(alloc, io_mod.getenv("HOME"), workspace_root);
}

pub fn providerEnvOverride() ?[]const u8 {
    const raw = io_mod.getenv("FX_PROVIDER") orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return raw;
}

/// Trimmed FX_MODEL, or null when unset or blank. Borrows process environment storage.
pub fn modelEnvOverride() ?[]const u8 {
    const raw = io_mod.getenv("FX_MODEL") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

pub const ModelSelectionError = error{
    CodexModelNotSelected,
    GrokModelNotSelected,
    ConfiguredModelNotSelected,
};

/// Chooses the provider and the model it persists as its preference. A saved
/// model wins; Gateway falls back to `default_model`; providers without a
/// built-in default accept `run_model` (--model or FX_MODEL) for this run.
/// The result borrows from its arguments.
pub fn selectProviderModel(
    default_model: []const u8,
    settings: *const Settings,
    provider_override: ?model_provider.ProviderId,
    run_model: ?[]const u8,
) ModelSelectionError!model_provider.ProviderSelection {
    _ = default_model;
    const provider = provider_override orelse settings.provider orelse .codex;
    const model = settings.models.get(provider) orelse switch (provider) {
        .codex => run_model orelse return error.CodexModelNotSelected,
        .grok => run_model orelse return error.GrokModelNotSelected,
        .configured => run_model orelse return error.ConfiguredModelNotSelected,
    };
    return .{ .provider = provider, .model = model };
}

/// User-facing guidance for a `ModelSelectionError`, or null for any other error.
pub fn modelNotSelectedMessage(err: anyerror) ?[]const u8 {
    const for_this_run = "or set a model for this run with --model or FX_MODEL";
    return switch (err) {
        error.CodexModelNotSelected => "no Codex model is selected; run `fx provider codex` to choose one, " ++ for_this_run,
        error.GrokModelNotSelected => "no Grok model is selected; run `fx provider grok` to choose one, " ++ for_this_run,
        error.ConfiguredModelNotSelected => "no model is selected for this connection; save one under \"models\" in ~/.fx/settings.json, " ++ for_this_run,
        else => null,
    };
}

fn resolve_provider_selection(settings: *Settings) !void {
    if (providerEnvOverride()) |raw| {
        settings.provider = model_provider.parse(raw) orelse return error.InvalidProviderValue;
    }
    if (settings.provider) |provider| settings.provider = try provider.bind(settings.providers orelse .{});
}

/// Reads only profile-global connection definitions. Caller owns the registry.
pub fn loadConfiguredProviders(alloc: Allocator) !configured_provider.Registry {
    var paths = try discoverPaths(alloc, ".");
    defer paths.deinit(alloc);
    const bytes = (try readOptionalUserSettingsFile(alloc, paths)) orelse return .{};
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSettingsShape;
    const definitions = parsed.value.object.get("providers") orelse return .{};
    return configured_provider.Registry.parse(alloc, definitions);
}

pub fn loadMergedSettings(alloc: Allocator, workspace_root: []const u8) !Settings {
    var paths = try discoverPaths(alloc, workspace_root);
    defer paths.deinit(alloc);
    return loadMergedSettingsFromPaths(alloc, paths);
}

pub fn loadMergedSettingsDetailedFromHome(
    alloc: Allocator,
    home_dir: []const u8,
    workspace_root: []const u8,
) !DetailedSettings {
    return loadMergedSettingsDetailedWithOptionalHome(alloc, home_dir, workspace_root);
}

pub fn loadMergedSettingsDetailed(alloc: Allocator, workspace_root: []const u8) !DetailedSettings {
    return loadMergedSettingsDetailedWithOptionalHome(alloc, io_mod.getenv("HOME"), workspace_root);
}

fn loadMergedSettingsDetailedWithOptionalHome(
    alloc: Allocator,
    home_dir: ?[]const u8,
    workspace_root: []const u8,
) !DetailedSettings {
    var settings = Settings{};
    errdefer settings.deinit(alloc);
    var diagnostics: std.ArrayList(ConfigDiagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
        diagnostics.deinit(alloc);
    }
    var sources = ConfigSources{};
    var permission_sources = PermissionSourceViews{};
    errdefer permission_sources.deinit(alloc);
    var prompt_history_store_allowed = home_dir != null;
    var additional_directories: ?[][]u8 = null;
    errdefer if (additional_directories) |paths| freeStringSlice(alloc, paths);
    var additional_directory_sources: ?[][]u8 = null;
    errdefer if (additional_directory_sources) |paths| freeStringSlice(alloc, paths);
    const detailed_merge_state: DetailedSettingsMergeState = .{
        .settings = &settings,
        .sources = &sources,
        .permission_sources = &permission_sources,
        .diagnostics = &diagnostics,
        .prompt_history_store_allowed = &prompt_history_store_allowed,
    };

    var user_root: ?std.json.Parsed(std.json.Value) = null;
    defer if (user_root) |*parsed| parsed.deinit();

    if (home_dir) |home| {
        var store: ?settings_store.Store = settings_store.Store.initFromHome(alloc, home, .read_only) catch |err| blk: {
            prompt_history_store_allowed = false;
            try diagnostics.append(alloc, .{
                .layer = .user,
                .cause = diagnosticCauseForUserStoreError(err),
            });
            break :blk null;
        };
        if (store) |*usable_store| {
            defer usable_store.deinit(alloc);
            var primary = usable_store.loadPrimary(alloc) catch |err| blk: {
                prompt_history_store_allowed = false;
                try diagnostics.append(alloc, .{
                    .layer = .user,
                    .cause = diagnosticCauseForUserStoreError(err),
                });
                break :blk settings_store.PrimaryLoad.absent;
            };
            defer primary.deinit(alloc);
            switch (primary) {
                .absent => {},
                .invalid => {
                    prompt_history_store_allowed = false;
                    try diagnostics.append(alloc, .{ .layer = .user, .cause = .malformed_settings });
                    if (usable_store.newestValidBackupPath(alloc) catch null) |recovery_path| {
                        try diagnostics.append(alloc, .{
                            .layer = .user,
                            .cause = .manual_backup_available,
                            .recovery_path = recovery_path,
                        });
                    }
                },
                .oversized => {
                    prompt_history_store_allowed = false;
                    try diagnostics.append(alloc, .{ .layer = .user, .cause = .settings_too_large });
                    if (usable_store.newestValidBackupPath(alloc) catch null) |recovery_path| {
                        try diagnostics.append(alloc, .{
                            .layer = .user,
                            .cause = .manual_backup_available,
                            .recovery_path = recovery_path,
                        });
                    }
                },
                .valid => |bytes| {
                    user_root = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always });
                    if (user_root.?.value != .object) {
                        prompt_history_store_allowed = false;
                        try diagnostics.append(alloc, .{ .layer = .user, .cause = .malformed_settings });
                        user_root.?.deinit();
                        user_root = null;
                    }
                },
            }
        }
    }

    const project_path = try std.Io.Dir.path.join(alloc, &.{ workspace_root, ".fx.json" });
    defer alloc.free(project_path);
    const project_text = readOptionalFile(alloc, project_path) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        try diagnostics.append(alloc, .{
            .layer = .project,
            .cause = switch (err) {
                error.StreamTooLong => .settings_too_large,
                error.DurablePathUnsafe => .durable_path_unsafe,
                else => .malformed_settings,
            },
        });
        break :blk null;
    };
    defer if (project_text) |text| alloc.free(text);
    if (project_text) |text| {
        if (std.json.parseFromSlice(std.json.Value, alloc, text, .{})) |parsed_value| {
            var parsed = parsed_value;
            defer parsed.deinit();
            if (parsed.value != .object) {
                try diagnostics.append(alloc, .{ .layer = .project, .cause = .malformed_settings });
            } else {
                try appendIgnoredProjectProfileSettingDiagnostics(alloc, &diagnostics, parsed.value);
                try mergeDetailedSettingsLayer(
                    alloc,
                    &detailed_merge_state,
                    parsed.value,
                    .project,
                    false,
                    .project,
                    .project,
                    .none,
                );
            }
        } else |err| {
            if (err == error.OutOfMemory) return err;
            try diagnostics.append(alloc, .{ .layer = .project, .cause = .malformed_settings });
        }
    }

    if (user_root) |parsed| {
        if (parsed.value.object.contains("additional_directories")) {
            try diagnostics.append(alloc, .{
                .layer = .user,
                .cause = .invalid_additional_directories,
                .setting_key = try alloc.dupe(u8, "additional_directories"),
            });
        }
        if (hasLegacyWorkspacePreferences(parsed.value)) {
            try diagnostics.append(alloc, .{
                .layer = .user,
                .cause = .legacy_workspace_preferences,
            });
        }
        try mergeDetailedSettingsLayer(
            alloc,
            &detailed_merge_state,
            parsed.value,
            .profile,
            false,
            .user,
            .user_global,
            .user,
        );
    }

    if (user_root) |parsed| {
        const workspaces = parsed.value.object.get("workspaces");
        if (workspaces) |workspaces_value| {
            if (workspaces_value != .object) {
                try diagnostics.append(alloc, .{ .layer = .user, .cause = .malformed_settings });
            } else if (workspaces_value.object.get(workspace_root)) |workspace_value| {
                if (workspace_value != .object) {
                    try diagnostics.append(alloc, .{ .layer = .user, .cause = .malformed_settings });
                } else {
                    if (workspace_value.object.get("additional_directories")) |value| {
                        const parsed_directories = parseAdditionalDirectories(
                            alloc,
                            workspace_root,
                            value,
                        ) catch |err| blk: {
                            if (err == error.OutOfMemory) return err;
                            try diagnostics.append(alloc, .{
                                .layer = .user,
                                .cause = .invalid_additional_directories,
                                .setting_key = try alloc.dupe(u8, "additional_directories"),
                            });
                            break :blk null;
                        };
                        if (parsed_directories) |directories| {
                            additional_directories = directories.canonical;
                            additional_directory_sources = directories.sources;
                        }
                    }
                    try mergeDetailedSettingsLayer(
                        alloc,
                        &detailed_merge_state,
                        workspace_value,
                        .profile,
                        true,
                        .user,
                        .user_workspace,
                        .local,
                    );
                }
            }
        }
    }

    try resolve_provider_selection(&settings);
    if (providerEnvOverride() != null) sources.provider = .process_override;
    if (modelEnvOverride() != null) {
        const override_provider = model_provider.NameKey.fromProvider(settings.provider orelse .codex);
        sources.models.set(override_provider, .process_override) catch |err| switch (err) {
            error.TooManyModelPreferences => debug_trace.logf(
                "config",
                "dropping process model override provenance provider={s}: provenance table holds at most {d} provider names",
                .{ override_provider.label(), model_preferences.max_preferences },
            ),
        };
    }
    if (io_mod.getenv("FX_PROVIDER_ORDER")) |order_override| {
        switch (parseProviderOrderList(alloc, order_override)) {
            .ok => |maybe_order| {
                if (maybe_order) |order| {
                    if (settings.provider_order) |old| {
                        for (old) |slug| alloc.free(@constCast(slug));
                        alloc.free(old);
                    }
                    settings.provider_order = order;
                }
            },
            .invalid => debug_trace.logf("config", "ignoring invalid FX_PROVIDER_ORDER value", .{}),
        }
    }
    if (io_mod.getenv("FX_PROVIDER_STRICT")) |strict_override| {
        const trimmed = std.mem.trim(u8, strict_override, " \t\r\n");
        if (parseEnvBool(trimmed)) |strict| {
            settings.provider_strict = strict;
        } else if (trimmed.len > 0) {
            debug_trace.logf("config", "ignoring invalid FX_PROVIDER_STRICT value", .{});
        }
    }
    if (io_mod.getenv("FX_REVIEW_MODEL")) |review_override| {
        const trimmed = std.mem.trim(u8, review_override, " \t\r\n");
        if (trimmed.len > 0) {
            if (settings_store.validateModel(trimmed)) |_| {
                if (settings.review_model) |old| alloc.free(old);
                settings.review_model = try alloc.dupe(u8, trimmed);
            } else |_| {
                debug_trace.logf("config", "ignoring invalid FX_REVIEW_MODEL value", .{});
            }
        }
    }
    const ultrafast_mode_env_override = ultrafastModeEnvOverride() catch |err| blk: {
        try diagnostics.append(alloc, .{
            .layer = .user,
            .cause = .invalid_ultrafast_mode_override,
        });
        debug_trace.logf("config", "invalid FX_ULTRAFAST value err={s}", .{@errorName(err)});
        break :blk null;
    };

    return .{
        .settings = settings,
        .diagnostics = try diagnostics.toOwnedSlice(alloc),
        .model_source = sources.models.get(model_provider.NameKey.fromProvider(settings.provider orelse .codex)),
        .sources = sources,
        .ultrafast_mode_env_override = ultrafast_mode_env_override,
        .permission_sources = permission_sources,
        .prompt_history_store_allowed = prompt_history_store_allowed,
        .additional_directories = additional_directories,
        .additional_directory_sources = additional_directory_sources,
    };
}

const ParsedAdditionalDirectories = struct {
    canonical: [][]u8,
    sources: [][]u8,
};

pub const ProviderOrderParse = union(enum) {
    /// Owned slice; null when the input held no slugs. Caller frees each slug
    /// and the slice.
    ok: ?[][]const u8,
    invalid,
};

/// Parses a comma-separated gateway provider list ("azure, anthropic") into
/// validated, deduplicated slugs. Caller owns the returned memory.
pub fn parseProviderOrderList(alloc: Allocator, raw: []const u8) ProviderOrderParse {
    const result = parseProviderOrderListInner(alloc, raw) catch return .invalid;
    return .{ .ok = result };
}

fn parseProviderOrderListInner(alloc: Allocator, raw: []const u8) !?[][]const u8 {
    var slugs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (slugs.items) |slug| alloc.free(@constCast(slug));
        slugs.deinit(alloc);
    }
    var tokenizer = std.mem.tokenizeScalar(u8, raw, ',');
    while (tokenizer.next()) |token| {
        const slug = std.mem.trim(u8, token, " \t\r\n");
        if (slug.len == 0) continue;
        if (!settings_store.validateProviderSlug(slug)) return error.InvalidProviderSlug;
        if (slugs.items.len >= settings_store.max_provider_order_entries) return error.TooManyProviderSlugs;
        for (slugs.items) |existing| {
            if (std.mem.eql(u8, existing, slug)) return error.DuplicateProviderSlug;
        }
        const owned = try alloc.dupe(u8, slug);
        errdefer alloc.free(@constCast(owned));
        try slugs.append(alloc, owned);
    }
    if (slugs.items.len == 0) return null;
    return try slugs.toOwnedSlice(alloc);
}

pub const UltrafastModeEnvError = error{InvalidUltrafastMode};

/// Reads the process-only paid lane override using the repository's standard
/// environment-boolean vocabulary. A malformed value cannot widen cost.
pub fn ultrafastModeEnvOverride() UltrafastModeEnvError!?bool {
    const raw = io_mod.getenv("FX_ULTRAFAST") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return parseEnvBool(trimmed) orelse error.InvalidUltrafastMode;
}

fn parseEnvBool(raw: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(raw, "1") or std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "on") or std.ascii.eqlIgnoreCase(raw, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "0") or std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "off") or std.ascii.eqlIgnoreCase(raw, "no")) return false;
    return null;
}

fn parseAdditionalDirectories(
    alloc: Allocator,
    workspace_root: []const u8,
    value: std.json.Value,
) !ParsedAdditionalDirectories {
    if (value != .array) return error.InvalidAdditionalDirectories;

    var raw_paths: std.ArrayList([]const u8) = .empty;
    defer raw_paths.deinit(alloc);
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidAdditionalDirectories;
        if (raw_paths.items.len >= workspace_access.max_additional_directories) {
            return error.InvalidAdditionalDirectories;
        }
        for (raw_paths.items) |path| {
            if (std.mem.eql(u8, path, item.string)) return error.InvalidAdditionalDirectories;
        }
        try raw_paths.append(alloc, item.string);
    }

    var access = workspace_access.WorkspaceAccess.init(
        alloc,
        workspace_root,
        raw_paths.items,
        &.{},
        false,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAdditionalDirectories,
    };
    defer access.deinit(alloc);
    const canonical = try access.savedDirectoriesAlloc(alloc);
    errdefer freeStringSlice(alloc, canonical);
    return .{
        .canonical = canonical,
        .sources = try access.savedSourcePathsAlloc(alloc),
    };
}

fn hasLegacyWorkspacePreferences(root: std.json.Value) bool {
    if (root != .object) return false;
    const workspaces = root.object.get("workspaces") orelse return false;
    if (workspaces != .object) return false;

    var iterator = workspaces.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const workspace = entry.value_ptr.object;
        inline for (&.{
            "model",
            "effort",
            "fast_mode",
            "ultrafast_mode",
            "fast_mode_model_bound",
            "slash_menu_categories",
            "collapse_tool_calls",
            "startup_scrollback",
        }) |key| {
            if (workspace.contains(key)) return true;
        }
        if (workspace.get("prompt_history")) |value| {
            if (value == .object and value.object.contains("enabled")) return true;
        }
        if (workspace.get("statusLine")) |value| {
            if (value == .object and
                (value.object.contains("context") or
                    value.object.contains("session")))
            {
                return true;
            }
        }
    }
    return false;
}

fn isProfileOnlySettingKey(key: []const u8) bool {
    inline for (&.{
        "model",
        "models",
        "provider",
        "providers",
        "codex_model",
        "grok_model",
        "review_model",
        "effort",
        "fast_mode",
        "ultrafast_mode",
        "fast_mode_model_bound",
        "slash_menu_categories",
        "collapse_tool_calls",
        "theme",
        "session_titles",
        "startup_scrollback",
        "prompt_history",
        "statusLine",
        "notifications",
        "context_limits",
        "skill_match_fuzzy",
        "first_call_tool_choice",
        "auto_upgrade",
        "update_channel",
        "permission_mode",
        "yolo_acknowledged",
        "permission",
        "additional_directories",
        "skill_symlink_authorities",
    }) |profile_key| {
        if (std.mem.eql(u8, key, profile_key)) return true;
    }
    return false;
}

fn appendIgnoredProjectProfileSettingDiagnostics(
    alloc: Allocator,
    diagnostics: *std.ArrayList(ConfigDiagnostic),
    root: std.json.Value,
) !void {
    if (root != .object) return;
    var iterator = root.object.iterator();
    while (iterator.next()) |entry| {
        if (!isProfileOnlySettingKey(entry.key_ptr.*)) continue;
        try diagnostics.append(alloc, .{
            .layer = .project,
            .cause = .ignored_project_user_only_setting,
            .setting_key = try alloc.dupe(u8, entry.key_ptr.*),
        });
    }
}

/// The profile layer parse is atomic: one malformed field discards every
/// field, including provider routing. When that happens, re-parse only the
/// provider routing triple (connections, selection, per-provider models)
/// through the same layer-scoped parser so a broken sibling (for example a
/// mistyped effort) cannot silently drop the configured connection and fall
/// back to Gateway. The layer scope is identical to normal parsing, so
/// workspace override provider definitions stay ignored here too. Returns
/// true when the layer declared routing that is now installed; errors when
/// the routing fields themselves are broken.
fn salvageProviderRouting(alloc: Allocator, settings: *Settings, sources: *ConfigSources, value: std.json.Value, layer: SettingsLayer, source: ConfigSource) error{ OutOfMemory, InvalidProviderRouting }!bool {
    var routing_only: std.json.ObjectMap = .empty;
    defer routing_only.deinit(alloc);
    for ([_][]const u8{ "provider", "providers", "models" }) |key| {
        const field = value.object.get(key) orelse continue;
        routing_only.put(alloc, key, field) catch return error.OutOfMemory;
    }
    if (routing_only.count() == 0) return false;
    var salvaged = parseSettingsValueForLayer(alloc, .{ .object = routing_only }, layer, false, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderRouting,
    };
    defer salvaged.deinit(alloc);
    if (salvaged.provider == null and salvaged.providers == null and salvaged.models.isEmpty()) return false;
    updateConfigSources(sources, salvaged, source);
    if (salvaged.providers) |registry| {
        if (settings.providers) |*old| old.deinit(alloc);
        settings.providers = registry;
        salvaged.providers = null;
    }
    if (salvaged.provider) |provider| settings.provider = provider;
    settings.models.mergeOwnedFrom(alloc, &salvaged.models) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyModelPreferences => return error.InvalidProviderRouting,
    };
    return true;
}

fn updateConfigSources(sources: *ConfigSources, settings: Settings, source: ConfigSource) void {
    for (settings.models.entries.items) |entry| sources.models.set(entry.provider, source) catch |err| switch (err) {
        error.TooManyModelPreferences => debug_trace.logf(
            "config",
            "dropping model provenance provider={s} source={s}: provenance table holds at most {d} provider names",
            .{ entry.provider.label(), @tagName(source), model_preferences.max_preferences },
        ),
    };
    if (settings.provider != null) sources.provider = source;
    if (settings.permission_mode != null) sources.permission_mode = source;
    if (settings.effort != null) sources.effort = source;
    if (settings.fast_mode != null) sources.fast_mode = source;
    if (settings.ultrafast_mode != null) sources.ultrafast_mode = source;
    if (settings.fast_mode_model_bound != null) sources.fast_mode_model_bound = source;
    if (settings.slash_menu_categories != null) sources.slash_menu_categories = source;
    if (settings.collapse_tool_calls != null) sources.collapse_tool_calls = source;
    if (settings.session_titles != null) sources.session_titles = source;
    if (settings.startup_scrollback != null) sources.startup_scrollback = source;
    if (settings.prompt_history_enabled != null) sources.prompt_history_enabled = source;
    if (settings.statusline_context != null) sources.statusline_context = source;
    if (settings.statusline_session != null) sources.statusline_session = source;
    if (settings.notification_turn_end != null) sources.notification_turn_end = source;
    if (settings.notification_attention_required != null) sources.notification_attention_required = source;
    if (settings.notification_max != null) sources.notification_max = source;
}

const DetailedPermissionSource = enum {
    none,
    user,
    local,
};

const DetailedSettingsMergeState = struct {
    settings: *Settings,
    sources: *ConfigSources,
    permission_sources: *PermissionSourceViews,
    diagnostics: *std.ArrayList(ConfigDiagnostic),
    prompt_history_store_allowed: *bool,
};

fn mergeDetailedSettingsLayer(
    alloc: Allocator,
    state: *const DetailedSettingsMergeState,
    value: std.json.Value,
    settings_layer: SettingsLayer,
    tolerate_non_object_user_containers: bool,
    diagnostic_layer: ConfigLayer,
    source: ConfigSource,
    permission_source: DetailedPermissionSource,
) !void {
    if (parseSettingsValueForLayer(
        alloc,
        value,
        if (source == .user_workspace) .profile_workspace else settings_layer,
        tolerate_non_object_user_containers,
        source != .user_workspace,
    )) |layer_settings| {
        var incoming = layer_settings;
        defer incoming.deinit(alloc);
        incoming.context_limits.retag(switch (source) {
            .user_global => .user_global,
            .user_workspace => .user_workspace,
            else => .compiled_default,
        });
        if (source == .user_workspace) {
            incoming.update_channel = null;
        }
        updateConfigSources(state.sources, incoming, source);
        if (incoming.has_permission_rules) {
            switch (permission_source) {
                .none => {},
                .user => {
                    state.permission_sources.user.deinit(alloc);
                    state.permission_sources.user = try types.dupePermissionRuleSet(alloc, incoming.permission_rules);
                },
                .local => {
                    state.permission_sources.local.deinit(alloc);
                    state.permission_sources.local = try types.dupePermissionRuleSet(alloc, incoming.permission_rules);
                    state.permission_sources.user_shadowed_by_local = true;
                },
            }
        }
        try mergeSettings(state.settings, &incoming, alloc);
    } else |err| {
        if (err == error.OutOfMemory) return err;
        if (diagnostic_layer == .user and value == .object) {
            _ = salvageProviderRouting(alloc, state.settings, state.sources, value, if (source == .user_workspace) .profile_workspace else settings_layer, source) catch |salvage_err| switch (salvage_err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidProviderRouting => return err,
            };
        }
        if (diagnostic_layer == .user and err == error.InvalidModelValue) state.prompt_history_store_allowed.* = false;
        try state.diagnostics.append(alloc, .{
            .layer = diagnostic_layer,
            .cause = diagnosticCauseForParseError(err),
        });
    }
}

fn diagnosticCauseForParseError(err: anyerror) ConfigDiagnosticCause {
    return switch (err) {
        error.InvalidModelValue => .invalid_model_id,
        error.RetiredSkillMatchFuzzy => .retired_skill_match_fuzzy,
        error.InvalidContextLimitsType,
        error.UnknownContextLimit,
        error.InvalidContextLimitValue,
        => .invalid_context_limits,
        error.InvalidSkillSymlinkAuthorities => .invalid_skill_symlink_authorities,
        else => .malformed_settings,
    };
}

fn diagnosticCauseForUserStoreError(err: anyerror) ConfigDiagnosticCause {
    return switch (err) {
        error.DurablePathUnsafe => .durable_path_unsafe,
        error.PrivateStatePermissionsUnsupported => .private_state_permissions_unsupported,
        else => .malformed_settings,
    };
}

pub fn parsePermissionMode(raw: []const u8) ?types.PermissionMode {
    return types.PermissionMode.parse(raw);
}

pub fn parsePermissionAction(raw: []const u8) ?types.PermissionAction {
    if (std.ascii.eqlIgnoreCase(raw, "allow")) return .allow;
    if (std.ascii.eqlIgnoreCase(raw, "ask")) return .ask;
    if (std.ascii.eqlIgnoreCase(raw, "deny")) return .deny;
    return null;
}

pub fn makeAbsolutePath(path_abs: []const u8) !void {
    const zio = io_mod.getIo();
    var root = try std.Io.Dir.openDirAbsolute(zio, "/", .{});
    defer root.close(zio);

    const relative_to_root = std.mem.trimStart(u8, path_abs, "/");
    if (relative_to_root.len == 0) return;
    try root.createDirPath(zio, relative_to_root);
}

pub const AllowlistResetScope = settings_store.AllowlistResetScope;
pub const PermissionMutation = settings_store.PermissionMutation;
pub const PermissionScope = settings_store.PermissionScope;
pub const StatuslineItem = settings_store.StatuslineItem;
pub const UserSettingsPatch = settings_store.UserSettingsPatch;
pub const WorkspaceDirectoryMutation = settings_store.WorkspaceDirectoryMutation;
pub const CommitOutcome = settings_store.CommitOutcome;
pub const LegacyCleanup = settings_store.LegacyCleanup;

pub const CommitFailure = struct {
    err: anyerror,
    cleanup: LegacyCleanup = .{},

    pub fn deinit(self: *CommitFailure, alloc: Allocator) void {
        self.cleanup.deinit(alloc);
        self.* = undefined;
    }
};

pub const CommitAttempt = union(enum) {
    outcome: CommitOutcome,
    failure: CommitFailure,

    pub fn deinit(self: *CommitAttempt, alloc: Allocator) void {
        switch (self.*) {
            .outcome => |*outcome| outcome.deinit(alloc),
            .failure => |*failure| failure.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub fn attemptUserPreferences(
    alloc: Allocator,
    patch: UserSettingsPatch,
) CommitAttempt {
    const home = io_mod.getenv("HOME") orelse return .{ .failure = .{ .err = error.HomeNotSet } };
    return attemptUserPreferencesInHome(alloc, home, patch);
}

/// Like attemptUserPreferences, for hosts that run with their own home.
pub fn attemptUserPreferencesInHome(
    alloc: Allocator,
    home: []const u8,
    patch: UserSettingsPatch,
) CommitAttempt {
    var store = settings_store.Store.initFromHome(alloc, home, .writable) catch |err| {
        return .{ .failure = .{ .err = err } };
    };
    defer store.deinit(alloc);
    const outcome = store.applyUserPatch(alloc, patch) catch |err| {
        return .{ .failure = .{
            .err = err,
            .cleanup = store.takeFailureCleanup(),
        } };
    };
    return .{ .outcome = outcome };
}

pub fn setUserPreferences(
    alloc: Allocator,
    patch: UserSettingsPatch,
) !CommitOutcome {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var store = try settings_store.Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    return store.applyUserPatch(alloc, patch);
}

pub fn mutateWorkspaceDirectory(
    alloc: Allocator,
    mutation: WorkspaceDirectoryMutation,
) !CommitOutcome {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var store = try settings_store.Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    return store.applyWorkspaceDirectoryPatch(alloc, mutation);
}

pub fn mutatePermission(
    alloc: Allocator,
    mutation: PermissionMutation,
) !CommitOutcome {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var store = try settings_store.Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    return store.applyPermissionPatch(alloc, mutation);
}

pub fn addPermissionRule(
    alloc: Allocator,
    scope: PermissionScope,
    workspace_root: ?[]const u8,
    category: []const u8,
    pattern: []const u8,
    action: types.PermissionAction,
) !CommitOutcome {
    return mutatePermission(alloc, .{
        .scope = scope,
        .workspace_root = workspace_root,
        .patch = .{ .add = .{
            .category = category,
            .pattern = pattern,
            .action = action,
        } },
    });
}

pub fn removePermissionRule(
    alloc: Allocator,
    scope: PermissionScope,
    workspace_root: ?[]const u8,
    category: []const u8,
    pattern: []const u8,
) !CommitOutcome {
    return mutatePermission(alloc, .{
        .scope = scope,
        .workspace_root = workspace_root,
        .patch = .{ .remove = .{
            .category = category,
            .pattern = pattern,
        } },
    });
}

pub fn removeAllowlistRules(
    alloc: Allocator,
    permission_scope: PermissionScope,
    workspace_root: ?[]const u8,
    reset_scope: AllowlistResetScope,
) !CommitOutcome {
    return mutatePermission(alloc, .{
        .scope = permission_scope,
        .workspace_root = workspace_root,
        .patch = .{ .reset = reset_scope },
    });
}

fn discoverPathsWithOptionalHome(alloc: Allocator, home_dir: ?[]const u8, workspace_root: []const u8) !Paths {
    const trimmed_workspace = normalizeWorkspaceRoot(workspace_root);
    if (trimmed_workspace.len == 0) return error.InvalidWorkspaceRoot;

    var paths: Paths = .{
        .workspace_settings = undefined,
        .workspace_root = try alloc.dupe(u8, trimmed_workspace),
    };
    errdefer alloc.free(paths.workspace_root);

    if (home_dir) |home| {
        paths.home_dir = try alloc.dupe(u8, home);
        errdefer alloc.free(paths.home_dir.?);

        paths.home_fx_dir = try profile_paths.rootDir(alloc, home);
        errdefer alloc.free(paths.home_fx_dir.?);

        paths.user_settings = try profile_paths.settingsPath(alloc, home);
        errdefer alloc.free(paths.user_settings.?);

        paths.sessions_dir = try profile_paths.sessionsDir(alloc, home);
        errdefer alloc.free(paths.sessions_dir.?);
    }

    paths.workspace_settings = try std.Io.Dir.path.join(alloc, &.{ trimmed_workspace, ".fx.json" });
    errdefer alloc.free(paths.workspace_settings);

    return paths;
}

pub fn loadMergedSettingsFromPaths(alloc: Allocator, paths: Paths) !Settings {
    var settings = Settings{};
    errdefer settings.deinit(alloc);

    const user_text = try readOptionalUserSettingsFile(alloc, paths);
    defer if (user_text) |owned| alloc.free(owned);

    if (user_text) |text| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSettingsShape;

        try mergeSettingsFile(&settings, alloc, paths.workspace_settings);

        var user_settings = try parseSettingsValueForLayer(alloc, parsed.value, .profile, false, true);
        defer user_settings.deinit(alloc);
        user_settings.context_limits.retag(.user_global);
        try mergeSettings(&settings, &user_settings, alloc);

        try mergeWorkspaceOverridesFromValue(&settings, alloc, parsed.value, paths.workspace_root);
        try resolve_provider_selection(&settings);
        return settings;
    }

    try mergeSettingsFile(&settings, alloc, paths.workspace_settings);
    try resolve_provider_selection(&settings);
    return settings;
}

fn readOptionalUserSettingsFile(alloc: Allocator, paths: Paths) !?[]u8 {
    if (paths.home_dir) |home| {
        var store = try settings_store.Store.initFromHome(alloc, home, .read_only);
        defer store.deinit(alloc);
        var primary = try store.loadPrimary(alloc);
        errdefer primary.deinit(alloc);
        return switch (primary) {
            .absent => null,
            .valid => |bytes| blk: {
                primary = .absent;
                break :blk bytes;
            },
            .invalid => error.InvalidSettingsFormat,
            .oversized => error.StreamTooLong,
        };
    }
    if (paths.user_settings) |path| return try readOptionalFile(alloc, path);
    return null;
}

fn mergeWorkspaceOverridesFromValue(target: *Settings, alloc: Allocator, root_value: std.json.Value, workspace_root: []const u8) !void {
    if (root_value != .object) return error.InvalidSettingsShape;

    const workspaces_val = root_value.object.get("workspaces") orelse return;
    if (workspaces_val != .object) return;

    const override_val = workspaces_val.object.get(workspace_root) orelse return;
    if (override_val != .object) return;

    var override_settings = try parseSettingsValueForLayer(alloc, override_val, .profile_workspace, true, false);
    defer override_settings.deinit(alloc);
    override_settings.update_channel = null;
    override_settings.context_limits.retag(.user_workspace);
    try mergeSettings(target, &override_settings, alloc);
}

fn mergeSettingsFile(target: *Settings, alloc: Allocator, path: []const u8) !void {
    const bytes = (try readOptionalFile(alloc, path)) orelse return;
    defer alloc.free(bytes);

    var parsed = try parseSettingsJsonForLayer(alloc, bytes, .project);
    defer parsed.deinit(alloc);
    try mergeSettings(target, &parsed, alloc);
}

fn readOptionalFile(alloc: Allocator, path: []const u8) !?[]u8 {
    var file = io_mod.openExistingRegularFile(
        std.Io.Dir.cwd(),
        path,
        .read_only,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.size > max_settings_bytes) return error.StreamTooLong;
    return try io_mod.readFileToEnd(alloc, &file, max_settings_bytes + 1);
}

fn parseSettingsJsonForLayer(alloc: Allocator, json_text: []const u8, layer: SettingsLayer) !Settings {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    return parseSettingsValueForLayer(alloc, parsed.value, layer, false, true);
}

const SettingsLayer = enum {
    profile,
    profile_workspace,
    project,
};

fn parseSettingsValueForLayer(
    alloc: Allocator,
    root: std.json.Value,
    layer: SettingsLayer,
    tolerate_non_object_user_containers: bool,
    parse_workspace_statusline: bool,
) !Settings {
    if (root != .object) return error.InvalidSettingsShape;

    var settings = Settings{};
    errdefer settings.deinit(alloc);

    if (layer == .profile) {
        if (root.object.get("providers")) |value| settings.providers = try configured_provider.Registry.parse(alloc, value);
    }
    if (layer != .project) try parseProfileOnlyFields(
        &settings,
        alloc,
        root,
        tolerate_non_object_user_containers,
        parse_workspace_statusline,
    );
    try parseProjectSafeFields(&settings, alloc, root);

    return settings;
}

fn parseProfileOnlyFields(
    settings: *Settings,
    alloc: Allocator,
    root: std.json.Value,
    tolerate_non_object_user_containers: bool,
    parse_workspace_statusline: bool,
) !void {
    if (root.object.contains("skill_match_fuzzy")) return error.RetiredSkillMatchFuzzy;
    if (root.object.get("auto_compact_percent")) |value| {
        if (value != .integer) return error.InvalidAutoCompactPercentType;
        if (value.integer < 0 or !compactor.isValidPercent(@intCast(value.integer))) return error.InvalidAutoCompactPercentValue;
        settings.auto_compact_percent = @intCast(value.integer);
    }
    if (root.object.get("provider")) |provider_value| {
        if (provider_value != .string) return error.InvalidProviderType;
        settings.provider = model_provider.parse(provider_value.string) orelse
            return error.InvalidProviderValue;
    }

    if (root.object.get("codex_model")) |model_value| {
        if (model_value != .string) return error.InvalidCodexModelType;
        settings_store.validateModel(model_value.string) catch return error.InvalidCodexModelValue;
        try settings.models.putCopy(alloc, .codex, model_value.string);
    }

    if (root.object.get("grok_model")) |model_value| {
        if (model_value != .string) return error.InvalidGrokModelType;
        settings_store.validateModel(model_value.string) catch return error.InvalidGrokModelValue;
        try settings.models.putCopy(alloc, .grok, model_value.string);
    }

    if (root.object.get("models")) |models_value| {
        if (models_value != .object) return error.InvalidModelType;
        var iterator = models_value.object.iterator();
        while (iterator.next()) |entry| {
            const provider = model_provider.parse(entry.key_ptr.*) orelse return error.InvalidProviderValue;
            const model_value = entry.value_ptr.*;
            if (model_value != .string) return error.InvalidModelType;
            settings_store.validateModel(model_value.string) catch return error.InvalidModelValue;
            try settings.models.putCopy(alloc, provider, model_value.string);
        }
    }

    if (root.object.get("permission_mode")) |permission_mode_value| {
        const value = permission_mode_value;
        if (value != .string) return error.InvalidPermissionModeType;
        settings.permission_mode = parsePermissionMode(value.string) orelse return error.InvalidPermissionMode;
    }

    if (root.object.get("yolo_acknowledged")) |acknowledged_value| {
        if (acknowledged_value != .bool) return error.InvalidYoloAcknowledgedType;
        settings.yolo_acknowledged = acknowledged_value.bool;
    }

    if (root.object.get("context_limits")) |context_limits_value| {
        settings.context_limits = try context_limits.parseJsonObject(context_limits_value);
    }

    if (root.object.get("first_call_tool_choice")) |first_call_tool_choice_value| {
        const value = first_call_tool_choice_value;
        if (value != .string) return error.InvalidFirstCallToolChoiceType;
        const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
        if (types.ToolChoice.parse(trimmed)) |choice| {
            settings.first_call_tool_choice = choice;
        } else if (trimmed.len > 0) {
            debug_trace.logf("core", "ignoring invalid first_call_tool_choice value={s}", .{trimmed});
        }
    }

    if (root.object.get("review_model")) |review_model_value| {
        const value = review_model_value;
        if (value != .string) return error.InvalidReviewModelType;
        const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
        if (trimmed.len > 0) {
            settings_store.validateModel(trimmed) catch {
                debug_trace.logf("core", "ignoring invalid review_model value", .{});
                return error.InvalidReviewModelValue;
            };
            settings.review_model = try alloc.dupe(u8, trimmed);
        }
    }

    if (root.object.get("fast_mode")) |fast_mode_value| {
        const value = fast_mode_value;
        if (value != .bool) return error.InvalidFastModeType;
        settings.fast_mode = value.bool;
    }

    if (root.object.get("ultrafast_mode")) |ultrafast_mode_value| {
        const value = ultrafast_mode_value;
        if (value != .bool) return error.InvalidUltrafastModeType;
        settings.ultrafast_mode = value.bool;
    }

    if (root.object.get("fast_mode_model_bound")) |bound_value| {
        if (bound_value != .bool) return error.InvalidFastModeBindingType;
        settings.fast_mode_model_bound = bound_value.bool;
    }

    if (root.object.get("slash_menu_categories")) |slash_menu_categories_value| {
        const value = slash_menu_categories_value;
        if (value != .bool) return error.InvalidSlashMenuCategoriesType;
        settings.slash_menu_categories = value.bool;
    }

    if (root.object.get("collapse_tool_calls")) |collapse_tool_calls_value| {
        const value = collapse_tool_calls_value;
        if (value != .bool) return error.InvalidCollapseToolCallsType;
        settings.collapse_tool_calls = value.bool;
    }

    if (root.object.get("session_titles")) |session_titles_value| {
        const value = session_titles_value;
        if (value != .bool) return error.InvalidSessionTitlesType;
        settings.session_titles = value.bool;
    }

    if (root.object.get("auto_upgrade")) |auto_upgrade_value| {
        const value = auto_upgrade_value;
        if (value != .bool) return error.InvalidAutoUpgradeType;
        settings.auto_upgrade = value.bool;
    }

    if (root.object.get("update_channel")) |update_channel_value| {
        const value = update_channel_value;
        if (value != .string) return error.InvalidUpdateChannelType;
        settings.update_channel = update_target.Channel.parse(value.string) orelse
            return error.InvalidUpdateChannelValue;
    }

    if (root.object.get("theme")) |theme_value| {
        const value = theme_value;
        if (value != .string) return error.InvalidThemeType;
        if (value.string.len > 0) settings.theme = try alloc.dupe(u8, value.string);
    }

    if (root.object.get("startup_scrollback")) |startup_scrollback_value| {
        const value = startup_scrollback_value;
        if (value != .bool) return error.InvalidStartupScrollbackType;
        settings.startup_scrollback = value.bool;
    }

    if (root.object.get("skill_symlink_authorities")) |value| {
        const paths = try parseSkillSymlinkAuthorities(alloc, value);
        if (settings.skill_symlink_authorities) |old| freeStringSlice(alloc, old);
        settings.skill_symlink_authorities = paths;
    }

    if (root.object.get("prompt_history")) |prompt_history_value| {
        if (prompt_history_value != .object) return error.InvalidPromptHistoryType;
        if (prompt_history_value.object.get("enabled")) |enabled| {
            if (enabled != .bool) return error.InvalidPromptHistoryEnabledType;
            settings.prompt_history_enabled = enabled.bool;
        }
    }

    if (root.object.get("effort")) |effort_value| {
        const value = effort_value;
        switch (value) {
            .string => |raw| settings.effort = types.ReasoningEffort.parse(raw) orelse return error.InvalidEffortValue,
            .null => settings.effort = .auto,
            else => return error.InvalidEffortType,
        }
    }

    if (root.object.get("statusLine")) |statusline_value| {
        const value = statusline_value;
        if (value != .object) {
            if (!tolerate_non_object_user_containers) return error.InvalidStatusLineType;
        } else {
            if (value.object.get("context")) |v| {
                if (v != .bool) return error.InvalidStatusLineContextType;
                settings.statusline_context = v.bool;
            }
            if (value.object.get("session")) |v| {
                if (v != .bool) return error.InvalidStatusLineSessionType;
                settings.statusline_session = v.bool;
            }
            if (parse_workspace_statusline) {
                if (value.object.get("workspace")) |v| {
                    if (v != .bool) return error.InvalidStatusLineWorkspaceType;
                    settings.statusline_workspace = v.bool;
                }
            }
        }
    }

    if (root.object.get("notifications")) |notifications_value| {
        if (notifications_value != .object) return error.InvalidNotificationsType;
        if (notifications_value.object.get("turn_end")) |value| {
            if (value != .bool) return error.InvalidNotificationTurnEndType;
            settings.notification_turn_end = value.bool;
        }
        if (notifications_value.object.get("attention_required")) |value| {
            if (value != .bool) return error.InvalidNotificationAttentionRequiredType;
            settings.notification_attention_required = value.bool;
        }
        if (notifications_value.object.get("max")) |value| {
            if (value != .bool) return error.InvalidNotificationMaxType;
            settings.notification_max = value.bool;
        }
    }

    if (root.object.get("permission")) |permission_value| {
        const value = permission_value;
        settings.permission_rules.deinit(alloc);
        settings.permission_rules = try parsePermissionConfig(alloc, value);
        settings.has_permission_rules = true;
    }
}

/// Parses `skill_symlink_authorities` into caller-owned path copies. Every
/// entry must be an absolute path without `..` components so a typo cannot
/// silently widen or narrow the directories skills may resolve into.
fn parseSkillSymlinkAuthorities(alloc: Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return error.InvalidSkillSymlinkAuthorities;
    const items = value.array.items;
    if (items.len > max_skill_symlink_authorities) return error.InvalidSkillSymlinkAuthorities;
    for (items) |item| {
        if (item != .string or
            !std.Io.Dir.path.isAbsolute(item.string) or
            pathHasDotDotComponent(item.string))
        {
            return error.InvalidSkillSymlinkAuthorities;
        }
    }
    const paths = try alloc.alloc([]u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (paths[0..filled]) |path| alloc.free(path);
        alloc.free(paths);
    }
    for (items) |item| {
        paths[filled] = try alloc.dupe(u8, item.string);
        filled += 1;
    }
    return paths;
}

fn pathHasDotDotComponent(path: []const u8) bool {
    var it = std.Io.Dir.path.componentIterator(path);
    while (it.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) return true;
    }
    return false;
}

fn parseProjectSafeFields(settings: *Settings, alloc: Allocator, root: std.json.Value) !void {
    if (root.object.get("provider_order")) |order_value| {
        if (order_value != .array) return error.InvalidProviderOrderType;
        const items = order_value.array.items;
        // An empty array explicitly clears an inherited routing list.
        if (items.len > settings_store.max_provider_order_entries) {
            return error.InvalidProviderOrderValue;
        }
        var order = try alloc.alloc([]const u8, items.len);
        errdefer alloc.free(order);
        var filled: usize = 0;
        errdefer for (order[0..filled]) |slug| alloc.free(@constCast(slug));
        for (items, 0..) |item, index| {
            if (item != .string or !settings_store.validateProviderSlug(item.string)) {
                return error.InvalidProviderOrderValue;
            }
            for (items[0..index]) |previous| {
                if (previous == .string and std.mem.eql(u8, item.string, previous.string)) {
                    return error.InvalidProviderOrderValue;
                }
            }
            order[index] = try alloc.dupe(u8, item.string);
            filled += 1;
        }
        if (settings.provider_order) |old| {
            for (old) |slug| alloc.free(@constCast(slug));
            alloc.free(old);
        }
        settings.provider_order = order;
    }

    if (root.object.get("provider_strict")) |strict_value| {
        if (strict_value != .bool) return error.InvalidProviderStrictType;
        settings.provider_strict = strict_value.bool;
    }

    if (root.object.get("max_agent_steps")) |max_agent_steps_value| {
        const value = max_agent_steps_value;
        if (value != .integer) return error.InvalidMaxAgentStepsType;
        if (value.integer < 0) return error.InvalidMaxAgentStepsValue;
        settings.max_agent_steps = std.math.cast(usize, value.integer) orelse return error.InvalidMaxAgentStepsValue;
    }

    if (root.object.get("max_tool_result_bytes")) |max_tool_result_bytes_value| {
        const value = max_tool_result_bytes_value;
        if (value != .integer) return error.InvalidMaxToolResultBytesType;
        if (value.integer < @as(i64, @intCast(tool_result_limits.min_configured_tool_result_bytes))) return error.InvalidMaxToolResultBytesValue;
        settings.max_tool_result_bytes = std.math.cast(usize, value.integer) orelse return error.InvalidMaxToolResultBytesValue;
    }

    if (root.object.get("context")) |context_value| {
        const value = context_value;
        if (value != .bool) return error.InvalidContextType;
        settings.context = value.bool;
    }
}

fn mergeSettings(target: *Settings, incoming: *Settings, alloc: Allocator) !void {
    try target.models.mergeOwnedFrom(alloc, &incoming.models);
    if (incoming.providers) |providers| {
        if (target.providers) |*old| old.deinit(alloc);
        target.providers = providers;
        incoming.providers = null;
    }
    if (incoming.provider) |value| target.provider = value;
    if (incoming.permission_mode) |value| target.permission_mode = value;
    if (incoming.yolo_acknowledged) |value| target.yolo_acknowledged = value;
    if (incoming.max_agent_steps) |value| target.max_agent_steps = value;
    if (incoming.max_tool_result_bytes) |value| target.max_tool_result_bytes = value;
    if (incoming.auto_compact_percent) |value| target.auto_compact_percent = value;
    target.context_limits.merge(incoming.context_limits);
    if (incoming.first_call_tool_choice) |value| target.first_call_tool_choice = value;
    if (incoming.context) |value| target.context = value;
    if (incoming.fast_mode) |value| target.fast_mode = value;
    if (incoming.ultrafast_mode) |value| target.ultrafast_mode = value;
    if (incoming.fast_mode_model_bound) |value| target.fast_mode_model_bound = value;
    if (incoming.provider_order) |value| {
        if (target.provider_order) |old| {
            for (old) |slug| alloc.free(@constCast(slug));
            alloc.free(old);
        }
        target.provider_order = value;
        incoming.provider_order = null;
    }
    if (incoming.provider_strict) |value| target.provider_strict = value;
    if (incoming.slash_menu_categories) |value| target.slash_menu_categories = value;
    if (incoming.collapse_tool_calls) |value| target.collapse_tool_calls = value;
    if (incoming.session_titles) |value| target.session_titles = value;
    if (incoming.auto_upgrade) |value| target.auto_upgrade = value;
    if (incoming.update_channel) |value| target.update_channel = value;
    if (incoming.theme) |value| {
        if (target.theme) |old| alloc.free(old);
        target.theme = value;
        incoming.theme = null;
    }
    if (incoming.startup_scrollback) |value| target.startup_scrollback = value;
    if (incoming.skill_symlink_authorities) |value| {
        if (target.skill_symlink_authorities) |old| freeStringSlice(alloc, old);
        target.skill_symlink_authorities = value;
        incoming.skill_symlink_authorities = null;
    }
    if (incoming.prompt_history_enabled) |value| target.prompt_history_enabled = value;
    if (incoming.effort) |value| target.effort = value;
    if (incoming.review_model) |value| {
        if (target.review_model) |old| alloc.free(old);
        target.review_model = value;
        incoming.review_model = null;
    }

    if (incoming.statusline_context) |value| target.statusline_context = value;
    if (incoming.statusline_session) |value| target.statusline_session = value;
    if (incoming.statusline_workspace) |value| target.statusline_workspace = value;
    if (incoming.notification_turn_end) |value| target.notification_turn_end = value;
    if (incoming.notification_attention_required) |value| target.notification_attention_required = value;
    if (incoming.notification_max) |value| target.notification_max = value;

    if (incoming.has_permission_rules) {
        target.permission_rules.deinit(alloc);
        target.permission_rules = incoming.permission_rules;
        incoming.permission_rules = .{};
        target.has_permission_rules = true;
        incoming.has_permission_rules = false;
    }
}

fn parsePermissionConfig(alloc: Allocator, value: std.json.Value) !types.PermissionRuleSet {
    var rules: std.ArrayList(types.PermissionRule) = .empty;
    errdefer {
        for (rules.items) |rule| {
            alloc.free(rule.permission);
            alloc.free(rule.pattern);
        }
        rules.deinit(alloc);
    }

    switch (value) {
        .string => |action| {
            try rules.append(alloc, try parsePermissionRuleFromParts(alloc, "*", "*", parsePermissionAction(action) orelse return error.InvalidPermissionAction));
        },
        .object => |permission_map| {
            var it = permission_map.iterator();
            while (it.next()) |entry| {
                const permission = std.mem.trim(u8, entry.key_ptr.*, " \t\r\n");
                if (permission.len == 0) return error.InvalidPermissionRuleTool;

                switch (entry.value_ptr.*) {
                    .string => |action| {
                        try rules.append(alloc, try parsePermissionRuleFromParts(alloc, permission, "*", parsePermissionAction(action) orelse return error.InvalidPermissionAction));
                    },
                    .object => |pattern_map| {
                        var pattern_it = pattern_map.iterator();
                        while (pattern_it.next()) |pattern_entry| {
                            if (pattern_entry.value_ptr.* != .string) return error.InvalidPermissionAction;
                            const pattern = std.mem.trim(u8, pattern_entry.key_ptr.*, " \t\r\n");
                            try rules.append(alloc, try parsePermissionRuleFromParts(alloc, permission, pattern, parsePermissionAction(pattern_entry.value_ptr.*.string) orelse return error.InvalidPermissionAction));
                        }
                    },
                    else => return error.InvalidPermissionRulesType,
                }
            }
        },
        else => return error.InvalidPermissionRulesType,
    }

    return .{ .rules = try rules.toOwnedSlice(alloc) };
}

fn freeStringSlice(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len > 0) alloc.free(values);
}

fn parsePermissionRuleFromParts(alloc: Allocator, permission: []const u8, pattern: []const u8, action: types.PermissionAction) !types.PermissionRule {
    const owned_permission = try alloc.dupe(u8, permission);
    errdefer alloc.free(owned_permission);

    return .{
        .permission = owned_permission,
        .pattern = try alloc.dupe(u8, pattern),
        .action = action,
    };
}

fn normalizeWorkspaceRoot(workspace_root: []const u8) []const u8 {
    var end = workspace_root.len;
    while (end > 1 and workspace_root[end - 1] == '/') {
        end -= 1;
    }
    return workspace_root[0..end];
}

const std = @import("std");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const doctor_runtime = @import("../cli/doctor_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const mode_contract = @import("../modes/mode_contract.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const permissions = @import("../permissions/permissions.zig");
const session_codec = @import("../session/session_codec.zig");
const session_display_metadata = @import("../session/session_display_metadata.zig");
const session_json = @import("../session/session_json.zig");
const compactor = @import("../compactor/compactor.zig");
const session_store = @import("../session/session_store.zig");
const usage_report = @import("../session/usage_report.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const update_notes = @import("../upgrade/update_notes.zig");
const update_target = @import("../upgrade/update_target.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const workspace_commands = @import("../workspace/workspace_commands.zig");

const Allocator = std.mem.Allocator;

fn providerDisplayName(provider: *const model_provider.ProviderId) []const u8 {
    return if (provider.* == .configured) provider.label() else provider_catalog.label(provider.*);
}

fn permissionModeLabel(mode: types.PermissionMode) []const u8 {
    return permissions.permissionModeLabel(mode);
}

pub const OutputFormat = enum {
    text,
    json,
};

pub const CommandFailureSnapshot = struct {
    kind: []const u8,
    message: []const u8,
    code: []const u8,

    pub fn renderJson(self: CommandFailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":");
        try std.json.Stringify.value(self.kind, .{}, &out.writer);
        try out.writer.writeAll(",\"error\":");
        try std.json.Stringify.value(self.message, .{}, &out.writer);
        try out.writer.writeAll(",\"code\":");
        try std.json.Stringify.value(self.code, .{}, &out.writer);
        try out.writer.writeByte('}');
        return try out.toOwnedSlice();
    }
};

pub const UsageSnapshot = struct {
    report: *const usage_report.Snapshot,

    pub fn render(
        self: UsageSnapshot,
        alloc: Allocator,
        format: OutputFormat,
    ) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: UsageSnapshot, alloc: Allocator) ![]u8 {
        const report = self.report;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("Usage ({s})\n", .{report.scope.label()});
        switch (report.coverage) {
            .not_started => try out.writer.writeAll("Tracking has not started.\n"),
            .partial => {
                var date_buf: [24]u8 = undefined;
                try out.writer.print(
                    "Tracking since {s} (partial window).\n",
                    .{usage_report.formatUtcDate(
                        &date_buf,
                        report.coverage_started_at_ms.?,
                    )},
                );
            },
            .full => {},
        }
        switch (report.completeness) {
            .complete => {},
            .pending => try out.writer.writeAll(
                "Known totals exclude pending Gateway reconciliation.\n",
            ),
            .incomplete => try out.writer.writeAll(
                "Known totals may be incomplete.\n",
            ),
            .legacy => try out.writer.writeAll(
                "This session predates complete usage tracking.\n",
            ),
        }

        const totals = report.totals orelse return try out.toOwnedSlice();
        try out.writer.print(
            "Total tokens  {d}\nInput         {d}\nOutput        {d}\n",
            .{ totals.total_tokens, totals.input_tokens, totals.output_tokens },
        );
        try out.writer.print(
            "Cache         {d} read · {d} write\n",
            .{ totals.cache_read_tokens, totals.cache_write_tokens },
        );
        if (totals.reasoning_tokens) |reasoning| {
            try out.writer.print("Reasoning     {d}\n", .{reasoning});
        }
        if (totals.request_count) |requests| {
            try out.writer.print("Requests      {d}\n", .{requests});
        }
        try out.writer.print("Spend         ${d:.4}\n", .{totals.total_cost});

        if (report.models.len > 0) {
            try out.writer.writeAll("\nBy model\n");
            for (report.models) |model| {
                try out.writer.writeAll("- ");
                try writeTerminalSafe(&out.writer, alloc, model.model);
                try out.writer.print(
                    "  {d} tokens  ${d:.4}\n",
                    .{ model.totals.total_tokens, model.totals.total_cost },
                );
            }
        }
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: UsageSnapshot, alloc: Allocator) ![]u8 {
        const report = self.report;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":\"usage\",\"schema_version\":1,\"period\":");
        try std.json.Stringify.value(report.scope.cliValue() orelse "session", .{}, &out.writer);
        try out.writer.print(
            ",\"snapshot_time_ms\":{d},\"window_start_ms\":{d},\"coverage\":{{\"status\":",
            .{ report.snapshot_time_ms, report.window_start_ms },
        );
        try std.json.Stringify.value(@tagName(report.coverage), .{}, &out.writer);
        try out.writer.writeAll(",\"started_at_ms\":");
        if (report.coverage_started_at_ms) |started_at_ms| {
            try out.writer.print("{d}", .{started_at_ms});
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.print(
            ",\"full_window\":{}}},\"completeness\":",
            .{report.coverage == .full},
        );
        try std.json.Stringify.value(@tagName(report.completeness), .{}, &out.writer);
        try out.writer.writeAll(",\"totals\":");
        if (report.totals) |totals| {
            try writeUsageTotalsJson(&out.writer, totals);
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeAll(",\"models\":[");
        for (report.models, 0..) |model, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"model\":");
            try std.json.Stringify.value(model.model, .{}, &out.writer);
            try out.writer.writeAll(",\"totals\":");
            try writeUsageTotalsJson(&out.writer, model.totals);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

fn writeUsageTotalsJson(
    writer: *std.Io.Writer,
    totals: usage_report.Totals,
) !void {
    try writer.print(
        "{{\"total_tokens\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"reasoning_tokens\":",
        .{
            totals.total_tokens,
            totals.input_tokens,
            totals.output_tokens,
            totals.cache_read_tokens,
            totals.cache_write_tokens,
        },
    );
    if (totals.reasoning_tokens) |reasoning| {
        try writer.print("{d}", .{reasoning});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"request_count\":");
    if (totals.request_count) |requests| {
        try writer.print("{d}", .{requests});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"spend\":{d}}}", .{totals.total_cost});
}

pub fn workspaceErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidWorkspaceArgs => null,
        error.InvalidPath => "path is invalid",
        error.PathNotFound => "directory does not exist",
        error.NotDirectory => "path is not a directory",
        error.UnknownAdditionalDirectory => "directory is not configured as an additional workspace",
        error.PrimaryDirectory => "the primary workspace cannot be added or removed",
        error.TooManyDirectories => "additional directory limit reached",
        error.HomeNotSet => "HOME is not set",
        error.SettingsStoreUnavailable => "settings are unavailable",
        error.DurablePathUnsafe, error.PrivateStatePermissionsUnsupported => "settings path is unsafe",
        else => "workspace update failed",
    };
}

pub const WorkspaceSnapshot = struct {
    primary_directory: []const u8,
    saved_suppressed: bool,
    additional_directories: []const workspace_access.Entry,
    mutation: ?workspace_commands.Mutation = null,

    pub fn fromAccess(primary_directory: []const u8, access: *const workspace_access.WorkspaceAccess) WorkspaceSnapshot {
        return .{
            .primary_directory = primary_directory,
            .saved_suppressed = access.saved_suppressed,
            .additional_directories = access.entries,
        };
    }

    pub fn render(self: WorkspaceSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: WorkspaceSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("[workspace] primary=");
        try writeTerminalSafe(&out.writer, alloc, self.primary_directory);
        try out.writer.writeByte('\n');
        try out.writer.print("[workspace] saved_suppressed={} limit={d}\n", .{ self.saved_suppressed, workspace_access.max_additional_directories });
        if (self.mutation) |mutation| {
            try out.writer.print("[workspace] {s}", .{mutation.action});
            if (mutation.path) |path| {
                try out.writer.writeByte(' ');
                try writeTerminalSafe(&out.writer, alloc, path);
            }
            try out.writer.print(" saved_changed={} runtime_changed={} launch_flag_can_restore={}\n", .{
                mutation.saved_changed,
                mutation.runtime_changed,
                mutation.launch_flag_can_restore,
            });
            if (mutation.launch_flag_can_restore) {
                try out.writer.writeAll("[workspace] warning: repeating --add-dir can restore removed access on the next launch\n");
            }
        }
        if (self.additional_directories.len == 0) {
            try out.writer.writeAll("[workspace] additional directories: (none)\n");
            return try out.toOwnedSlice();
        }
        try out.writer.writeAll("[workspace] additional directories:\n");
        for (self.additional_directories) |entry| {
            try out.writer.writeAll(" - ");
            try writeTerminalSafe(&out.writer, alloc, entry.path);
            try out.writer.print(" saved={} command_line={} available={} active={}\n", .{
                entry.saved,
                entry.command_line,
                entry.available,
                entry.active,
            });
        }
        return try out.toOwnedSlice();
    }

    pub fn renderInteractiveBody(self: WorkspaceSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("primary=");
        try writeTerminalSafe(&out.writer, alloc, self.primary_directory);
        try out.writer.writeByte('\n');
        try out.writer.print("saved_suppressed={} limit={d}\n", .{ self.saved_suppressed, workspace_access.max_additional_directories });
        if (self.mutation) |mutation| {
            try out.writer.writeAll(mutation.action);
            if (mutation.path) |path| {
                try out.writer.writeByte(' ');
                try writeTerminalSafe(&out.writer, alloc, path);
            }
            try out.writer.print(" saved_changed={} runtime_changed={} launch_flag_can_restore={}\n", .{
                mutation.saved_changed,
                mutation.runtime_changed,
                mutation.launch_flag_can_restore,
            });
            if (mutation.launch_flag_can_restore) {
                try out.writer.writeAll("warning: repeating --add-dir can restore removed access on the next launch\n");
            }
        }
        if (self.additional_directories.len == 0) {
            try out.writer.writeAll("additional directories: (none)");
            return try out.toOwnedSlice();
        }
        try out.writer.writeAll("additional directories:\n");
        for (self.additional_directories, 0..) |entry, index| {
            try out.writer.writeAll(" - ");
            try writeTerminalSafe(&out.writer, alloc, entry.path);
            try out.writer.print(" saved={} command_line={} available={} active={}", .{
                entry.saved,
                entry.command_line,
                entry.available,
                entry.active,
            });
            if (index + 1 < self.additional_directories.len) try out.writer.writeByte('\n');
        }
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: WorkspaceSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const action = if (self.mutation) |mutation| mutation.action else "list";
        const changed = if (self.mutation) |mutation| mutation.saved_changed or mutation.runtime_changed else false;
        try out.writer.writeAll("{\"kind\":\"workspace\",\"action\":");
        try std.json.Stringify.value(action, .{}, &out.writer);
        try out.writer.print(",\"changed\":{}", .{changed});
        try out.writer.writeAll(",\"primary_directory\":");
        try std.json.Stringify.value(self.primary_directory, .{}, &out.writer);
        try out.writer.print(",\"saved_suppressed\":{},\"limit\":{d}", .{ self.saved_suppressed, workspace_access.max_additional_directories });
        if (self.mutation) |mutation| {
            if (mutation.path) |path| {
                try out.writer.writeAll(",\"path\":");
                try std.json.Stringify.value(path, .{}, &out.writer);
            }
            try out.writer.print(",\"saved_changed\":{},\"runtime_changed\":{},\"launch_flag_can_restore\":{}", .{
                mutation.saved_changed,
                mutation.runtime_changed,
                mutation.launch_flag_can_restore,
            });
        }
        try out.writer.writeAll(",\"additional_directories\":[");
        for (self.additional_directories, 0..) |entry, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"path\":");
            try std.json.Stringify.value(entry.path, .{}, &out.writer);
            try out.writer.print(",\"saved\":{},\"command_line\":{},\"available\":{},\"active\":{}}}", .{
                entry.saved,
                entry.command_line,
                entry.available,
                entry.active,
            });
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

fn writeTerminalSafe(writer: *std.Io.Writer, alloc: Allocator, raw: []const u8) !void {
    var encoded = try text_utils.encodeTerminalSafe(alloc, raw, std.math.maxInt(usize));
    defer encoded.deinit(alloc);
    try writer.writeAll(encoded.bytes);
}

fn chatGptProviderConnected(auth: auth_runtime.StatusSnapshot) bool {
    return auth.chatgpt_connected or auth.active_source == .chatgpt_subscription;
}

fn grokProviderConnected(auth: auth_runtime.StatusSnapshot) bool {
    return auth.grok_connected or auth.active_source == .grok_subscription;
}

fn writeConnectedProvidersText(writer: *std.Io.Writer, auth: auth_runtime.StatusSnapshot) !void {
    var wrote_provider = false;
    if (chatGptProviderConnected(auth)) {
        if (wrote_provider) try writer.writeAll(", Codex");
        if (!wrote_provider) try writer.writeAll("Codex");
        wrote_provider = true;
    }
    if (grokProviderConnected(auth)) {
        if (wrote_provider) try writer.writeAll(", Grok");
        if (!wrote_provider) try writer.writeAll("Grok");
        wrote_provider = true;
    }
    if (!wrote_provider) try writer.writeAll("none");
}

pub const StatusSnapshot = struct {
    model: []const u8,
    /// Where startup found `model`: FX_MODEL, settings, or default.
    model_origin: ?[]const u8 = null,
    /// The reasoning effort a new session starts with, when the caller resolved one.
    effort: ?types.ReasoningEffort = null,
    provider_endpoint: ?[]const u8 = null,
    provider: model_provider.ProviderId = .codex,
    update_channel: []const u8 = "stable",
    build_channel: []const u8 = "stable",
    build_revision: []const u8 = "",
    auth: auth_runtime.StatusSnapshot = .{},
    auth_help: ?[]const u8 = null,
    permission_mode: types.PermissionMode,
    /// The session modes fx offers and the one a new session starts in,
    /// when the caller has a mode registry with modes.
    modes: ?SessionModes = null,
    workspace_root: []const u8,
    history_turns: usize,
    session_permission_grants: usize,
    agent_step_limit: usize,
    /// Requested Ultra mode. The serving provider may still fall back.
    pub const SessionModes = struct {
        current: []const u8,
        all: []const mode_contract.ModeSpec,
    };

    pub fn render(self: StatusSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("[status] model={s}\n", .{self.model});
        if (self.model_origin) |origin| try out.writer.print("[status] model_origin={s}\n", .{origin});
        if (self.effort) |*effort| try out.writer.print("[status] effort={s}\n", .{effort.label()});
        try out.writer.print("[status] model_source={s}\n", .{providerDisplayName(&self.provider)});
        if (self.provider_endpoint) |endpoint| try out.writer.print("[status] provider_endpoint={s}\n", .{endpoint});
        try out.writer.print("[status] update_channel={s}\n", .{self.update_channel});
        try out.writer.print("[status] build_channel={s}\n", .{self.build_channel});
        if (self.build_revision.len > 0) {
            try out.writer.print("[status] build_revision={s}\n", .{self.build_revision});
        }
        try out.writer.print("[status] auth={s}\n", .{self.auth.activeSourceLabel()});
        try out.writer.writeAll("[status] connected_providers=");
        try self.writeConnections(&out.writer);
        try out.writer.writeByte('\n');
        try out.writer.print("[status] auth_refreshable={}\n", .{self.auth.refreshable()});
        if (self.auth.expired) try out.writer.writeAll("[status] auth_expired=true\n");
        if (self.auth_help) |help| {
            try out.writer.print("[status] auth_help={s}\n", .{help});
        }
        try out.writer.print("[status] permission_mode={s}\n", .{permissions.permissionModeDisplayLabel(self.permission_mode)});
        try out.writer.print("[status] workspace={s}\n", .{self.workspace_root});
        try out.writer.print("[status] history_turns={d}\n", .{self.history_turns});
        try out.writer.print("[status] session_permission_grants={d}\n", .{self.session_permission_grants});
        try out.writer.print("[status] agent_step_limit={d}\n", .{self.agent_step_limit});
        return try out.toOwnedSlice();
    }

    pub fn renderInteractiveBody(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("model={s}\n", .{self.model});
        try out.writer.print("model_source={s}\n", .{providerDisplayName(&self.provider)});
        if (self.provider_endpoint) |endpoint| try out.writer.print("provider_endpoint={s}\n", .{endpoint});
        try out.writer.print("update_channel={s}\n", .{self.update_channel});
        try out.writer.print("build_channel={s}\n", .{self.build_channel});
        if (self.build_revision.len > 0) {
            try out.writer.print("build_revision={s}\n", .{self.build_revision});
        }
        try out.writer.print("auth={s}\n", .{self.auth.activeSourceLabel()});
        try out.writer.writeAll("connected_providers=");
        try self.writeConnections(&out.writer);
        try out.writer.writeByte('\n');
        try out.writer.print("auth_refreshable={}\n", .{self.auth.refreshable()});
        if (self.auth.expired) try out.writer.writeAll("auth_expired=true\n");
        if (self.auth_help) |help| try out.writer.print("auth_help={s}\n", .{help});
        try out.writer.print("permission_mode={s}\n", .{permissions.permissionModeDisplayLabel(self.permission_mode)});
        try out.writer.print("workspace={s}\n", .{self.workspace_root});
        try out.writer.print("history_turns={d}\n", .{self.history_turns});
        try out.writer.print("session_permission_grants={d}\n", .{self.session_permission_grants});
        try out.writer.print("agent_step_limit={d}", .{self.agent_step_limit});
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }

    fn writeConnections(self: StatusSnapshot, writer: *std.Io.Writer) !void {
        if (self.provider == .configured and self.auth.active_source == .configured) {
            try writer.writeAll(self.provider.label());
            if (!chatGptProviderConnected(self.auth) and !grokProviderConnected(self.auth)) return;
            try writer.writeAll(", ");
        }
        try writeConnectedProvidersText(writer, self.auth);
    }

    pub fn writeJson(self: StatusSnapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"kind\":\"status\",\"model\":");
        try std.json.Stringify.value(self.model, .{}, writer);
        if (self.model_origin) |origin| {
            try writer.writeAll(",\"model_origin\":");
            try std.json.Stringify.value(origin, .{}, writer);
        }
        if (self.effort) |*effort| {
            try writer.writeAll(",\"effort\":");
            try std.json.Stringify.value(effort.label(), .{}, writer);
        }
        try writer.writeAll(",\"model_source\":");
        try std.json.Stringify.value(providerDisplayName(&self.provider), .{}, writer);
        if (self.provider_endpoint) |endpoint| {
            try writer.writeAll(",\"provider_endpoint\":");
            try std.json.Stringify.value(endpoint, .{}, writer);
        }
        try writer.writeAll(",\"update_channel\":");
        try std.json.Stringify.value(self.update_channel, .{}, writer);
        try writer.writeAll(",\"build_channel\":");
        try std.json.Stringify.value(self.build_channel, .{}, writer);
        try writer.writeAll(",\"build_revision\":");
        try std.json.Stringify.value(self.build_revision, .{}, writer);
        try writer.writeAll(",\"auth\":");
        try std.json.Stringify.value(self.auth.activeSourceLabel(), .{}, writer);
        try writer.writeAll(",\"connected_providers\":[");
        var wrote_provider = false;
        if (self.provider == .configured and self.auth.active_source == .configured) {
            try std.json.Stringify.value(self.provider.label(), .{}, writer);
            wrote_provider = true;
        }
        if (chatGptProviderConnected(self.auth)) {
            if (wrote_provider) try writer.writeByte(',');
            try std.json.Stringify.value("codex", .{}, writer);
            wrote_provider = true;
        }
        if (grokProviderConnected(self.auth)) {
            if (wrote_provider) try writer.writeByte(',');
            try std.json.Stringify.value("grok", .{}, writer);
        }
        try writer.writeByte(']');
        try writer.print(",\"auth_refreshable\":{}", .{self.auth.refreshable()});
        if (self.auth.expired) try writer.writeAll(",\"auth_expired\":true");
        if (self.auth_help) |help| {
            try writer.writeAll(",\"auth_help\":");
            try std.json.Stringify.value(help, .{}, writer);
        }
        try writer.writeAll(",\"permission_mode\":");
        try std.json.Stringify.value(permissionModeLabel(self.permission_mode), .{}, writer);
        if (self.modes) |modes| {
            try writer.writeAll(",\"mode\":");
            try std.json.Stringify.value(modes.current, .{}, writer);
            try writer.writeAll(",\"modes\":[");
            for (modes.all, 0..) |mode, index| {
                if (index > 0) try writer.writeByte(',');
                try writer.writeAll("{\"id\":");
                try std.json.Stringify.value(mode.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(mode.name, .{}, writer);
                try writer.writeAll(",\"description\":");
                try std.json.Stringify.value(mode.description, .{}, writer);
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
        }
        try writer.writeAll(",\"workspace\":");
        try std.json.Stringify.value(self.workspace_root, .{}, writer);
        try writer.print(",\"history_turns\":{d}", .{self.history_turns});
        try writer.print(",\"session_permission_grants\":{d}", .{self.session_permission_grants});
        try writer.print(",\"agent_step_limit\":{d}", .{self.agent_step_limit});
        try writer.writeByte('}');
    }
};

pub const PermissionsSnapshot = struct {
    workspace_root: []const u8,
    mode: types.PermissionMode,
    grants: []const types.PermissionGrant,
    rules: types.PermissionRuleSet = .{},
    runtime_grants_available: bool = true,

    pub fn render(self: PermissionsSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: PermissionsSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("[permissions] mode={s}\n", .{permissions.permissionModeDisplayLabel(self.mode)});
        try writePermissionRulesText(&out.writer, self.rules);
        if (self.grants.len == 0) {
            try out.writer.writeAll("[permissions] session grants: (none)\n");
            return try out.toOwnedSlice();
        }

        try out.writer.writeAll("[permissions] session grants:\n");
        for (self.grants) |grant| {
            const display_target = try displayGrantTarget(alloc, self.workspace_root, grant);
            defer alloc.free(display_target);
            try out.writer.print(" - {s} -> {s}\n", .{ grant.tool_name, display_target });
        }

        return try out.toOwnedSlice();
    }

    pub fn renderInteractiveBody(self: PermissionsSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("mode={s}\n", .{permissions.permissionModeDisplayLabel(self.mode)});
        if (self.rules.rules.len == 0) {
            try out.writer.writeAll("configured rules: (none)\n");
        } else {
            try out.writer.writeAll("configured rules:\n");
            for (self.rules.rules) |rule| {
                try out.writer.print(" - {s} {s} -> {s}\n", .{ @tagName(rule.action), rule.permission, rule.pattern });
            }
        }
        if (self.grants.len == 0) {
            try out.writer.writeAll("session grants: (none)");
            return try out.toOwnedSlice();
        }
        try out.writer.writeAll("session grants:\n");
        for (self.grants, 0..) |grant, index| {
            const display_target = try displayGrantTarget(alloc, self.workspace_root, grant);
            defer alloc.free(display_target);
            try out.writer.print(" - {s} -> {s}", .{ grant.tool_name, display_target });
            if (index + 1 < self.grants.len) try out.writer.writeByte('\n');
        }
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: PermissionsSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":\"permissions\",\"mode\":");
        try std.json.Stringify.value(permissionModeLabel(self.mode), .{}, &out.writer);
        try out.writer.print(",\"grant_count\":{d}", .{self.grants.len});
        try out.writer.writeAll(",\"grant_scope\":\"session\"");
        try out.writer.print(",\"runtime_grants_available\":{}", .{self.runtime_grants_available});
        try out.writer.writeAll(",\"rules_scope\":\"persistent_config\",\"rules\":");
        try writePermissionRulesJson(&out.writer, self.rules);
        try out.writer.writeAll(",\"grants\":[");

        for (self.grants, 0..) |grant, i| {
            if (i > 0) try out.writer.writeByte(',');

            const display_target = try displayGrantTarget(alloc, self.workspace_root, grant);
            defer alloc.free(display_target);

            try out.writer.writeAll("{\"tool_name\":");
            try std.json.Stringify.value(grant.tool_name, .{}, &out.writer);
            try out.writer.writeAll(",\"target_path\":");
            try std.json.Stringify.value(grant.target_path, .{}, &out.writer);
            try out.writer.writeAll(",\"display_target\":");
            try std.json.Stringify.value(display_target, .{}, &out.writer);
            try out.writer.writeByte('}');
        }

        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

/// What fx offers for one listed model: the same efforts and speed lanes a session on that model
/// exposes. `efforts` excludes `auto`, which every model accepts.
pub const ModelDetail = struct {
    name: ?[]const u8 = null,
    efforts: model_capabilities.ReasoningEffortOptions = .{},
    fast: bool = false,
};

pub const ModelListSnapshot = struct {
    ids: []const []const u8,
    /// One per id when the provider's catalog describes its models; empty otherwise.
    details: []const ModelDetail = &.{},
    provider: model_provider.ProviderId = .codex,
    limit: ?usize = null,
    private_models_hidden: bool = false,
    public_only_reason: ?credentials.CatalogPublicOnlyReason = null,

    pub fn render(self: ModelListSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: ModelListSnapshot, alloc: Allocator) ![]u8 {
        if (self.ids.len == 0) {
            const provider_name = self.emptyCatalogProviderName();
            if (self.catalogExplanation()) |explanation| {
                return alloc.print("[models] no models returned by {s}\n[models] {s}\n", .{ provider_name, explanation });
            }
            return alloc.print("[models] no models returned by {s}\n", .{provider_name});
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("[models] {d} available\n", .{self.ids.len});

        const shown = self.shownCount();
        for (self.ids[0..shown]) |id| {
            try out.writer.print(" - {s} · {s}\n", .{ id, providerDisplayName(&self.provider) });
        }
        if (self.ids.len > shown) {
            try out.writer.print(" ... and {d} more\n", .{self.ids.len - shown});
        }
        if (self.catalogExplanation()) |explanation| try out.writer.print("[models] {s}\n", .{explanation});

        return try out.toOwnedSlice();
    }

    pub fn renderInteractiveBody(self: ModelListSnapshot, alloc: Allocator) ![]u8 {
        if (self.ids.len == 0) {
            const provider_name = self.emptyCatalogProviderName();
            if (self.catalogExplanation()) |explanation| {
                return alloc.print("no models returned by {s}\n{s}", .{ provider_name, explanation });
            }
            return alloc.print("no models returned by {s}", .{provider_name});
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("{d} available", .{self.ids.len});
        const shown = self.shownCount();
        for (self.ids[0..shown]) |id| {
            try out.writer.print("\n - {s} · {s}", .{ id, providerDisplayName(&self.provider) });
        }
        if (self.ids.len > shown) try out.writer.print("\n ... and {d} more", .{self.ids.len - shown});
        if (self.catalogExplanation()) |explanation| try out.writer.print("\n{s}", .{explanation});
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: ModelListSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const shown = self.shownCount();
        try out.writer.print(
            "{{\"kind\":\"models\",\"count\":{d},\"shown_count\":{d},\"more_count\":{d},\"private_models_hidden\":{},\"ids\":[",
            .{ self.ids.len, shown, self.ids.len - shown, self.private_models_hidden },
        );
        for (self.ids[0..shown], 0..) |id, i| {
            if (i > 0) try out.writer.writeByte(',');
            try std.json.Stringify.value(id, .{}, &out.writer);
        }
        const has_details = self.ids.len > 0 and self.details.len == self.ids.len;
        try out.writer.writeAll("],\"models\":[");
        for (self.ids[0..shown], 0..) |id, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"id\":");
            try std.json.Stringify.value(id, .{}, &out.writer);
            try out.writer.writeAll(",\"source\":");
            try std.json.Stringify.value(providerDisplayName(&self.provider), .{}, &out.writer);
            if (has_details) try writeModelDetailJson(&out.writer, &self.details[i]);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }

    fn writeModelDetailJson(w: *std.Io.Writer, detail: *const ModelDetail) !void {
        if (detail.name) |name| {
            try w.writeAll(",\"name\":");
            try std.json.Stringify.value(name, .{}, w);
        }
        try w.writeAll(",\"efforts\":[");
        for (detail.efforts.slice(), 0..) |effort, i| {
            if (i > 0) try w.writeByte(',');
            try std.json.Stringify.value(effort.label(), .{}, w);
        }
        try w.print("],\"fast\":{}", .{detail.fast});
    }

    fn shownCount(self: ModelListSnapshot) usize {
        return if (self.limit) |value| @min(self.ids.len, value) else self.ids.len;
    }

    fn emptyCatalogProviderName(self: ModelListSnapshot) []const u8 {
        return switch (self.provider) {
            .codex => provider_catalog.label(.codex),
            .grok => provider_catalog.label(.grok),
            .configured => "configured provider",
        };
    }

    fn catalogExplanation(self: ModelListSnapshot) ?[]const u8 {
        if (self.provider == .configured) return "Models from profile settings; explicit model IDs do not require catalog discovery.";
        if (!self.private_models_hidden) return null;
        const reason = self.public_only_reason orelse return "Using the public model catalog.";
        return switch (reason) {
            .no_credential => "Using the public model catalog.",
            .credential_refresh_required => "The selected sign-in must refresh before authenticated models can load.",
            .credential_refresh_failed => "Sign-in refresh failed; using the public model catalog.",
            .authenticated_credential_rejected => "Your credential was rejected; using the public model catalog.",
            .chatgpt_subscription => "Codex models require an authenticated Codex catalog.",
            .grok_subscription => "Grok models require an authenticated Grok catalog.",
        };
    }
};

pub const SessionListSnapshot = struct {
    sessions: []const session_store.SessionSummary,
    has_more: bool = false,
    next_cursor: ?[]const u8 = null,
    skipped_invalid: usize = 0,
    all_workspaces: bool = false,

    pub fn render(self: SessionListSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: SessionListSnapshot, alloc: Allocator) ![]u8 {
        if (self.sessions.len == 0 and self.skipped_invalid == 0) {
            return alloc.print("[sessions] no saved sessions\n", .{});
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        if (self.sessions.len == 0) {
            try out.writer.writeAll("[sessions] no readable saved sessions\n");
        } else {
            try out.writer.print("[sessions] {d} saved\n", .{self.sessions.len});
            for (self.sessions) |entry| {
                try out.writer.writeAll(" - ");
                try writeTerminalSafe(
                    &out.writer,
                    alloc,
                    entry.title orelse session_display_metadata.fallback_title,
                );
                try out.writer.writeByte('\n');
                try writeSessionListDetails(&out.writer, alloc, entry);
            }
        }
        if (self.has_more) {
            try out.writer.print(
                "[sessions] more saved sessions; continue with `fx sessions {s}--cursor {s}`\n",
                .{ if (self.all_workspaces) "--all " else "", self.next_cursor orelse "" },
            );
        }
        if (self.skipped_invalid > 0) {
            try out.writer.print(
                "[sessions] warning: skipped {d} unreadable saved session{s}; run `fx doctor` for recovery guidance\n",
                .{ self.skipped_invalid, if (self.skipped_invalid == 1) "" else "s" },
            );
        }

        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: SessionListSnapshot, alloc: Allocator) ![]u8 {
        if (self.sessions.len == 0 and self.skipped_invalid == 0) {
            return alloc.dupe(u8, "{\"kind\":\"sessions\",\"count\":0,\"sessions\":[]}");
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("{{\"kind\":\"sessions\",\"count\":{d}", .{self.sessions.len});
        if (self.skipped_invalid > 0) {
            try out.writer.print(",\"skipped_invalid\":{d}", .{self.skipped_invalid});
        }
        if (self.has_more) {
            try out.writer.writeAll(",\"has_more\":true,\"next_cursor\":");
            try std.json.Stringify.value(self.next_cursor orelse "", .{}, &out.writer);
        }
        try out.writer.writeAll(",\"sessions\":[");
        for (self.sessions, 0..) |entry, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"id\":");
            try std.json.Stringify.value(entry.id, .{}, &out.writer);
            try writeSessionDisplayJsonFields(&out.writer, entry);
            try out.writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"history_len\":{d}", .{ entry.created_at_ms, entry.updated_at_ms, entry.history_len });
            try out.writer.writeAll(",\"conversation_language\":");
            try std.json.Stringify.value(entry.conversation_language.view(), .{}, &out.writer);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

fn writeSessionListDetails(
    writer: *std.Io.Writer,
    alloc: Allocator,
    entry: session_store.SessionSummary,
) !void {
    try writer.print(
        "   id={s} | {d} turn{s}",
        .{ entry.id, entry.history_len, if (entry.history_len == 1) "" else "s" },
    );
    if (sessionLanguageLabel(entry.conversation_language.view())) |label| {
        try writer.writeAll(" | ");
        try writeTerminalSafe(writer, alloc, label);
    }
    try writer.writeAll(" | updated ");
    try writeUtcTimestamp(writer, entry.updated_at_ms);
    try writer.writeByte('\n');
}

fn sessionLanguageLabel(tag: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(tag, "und")) return null;

    if (tag.len > 4 and std.ascii.eqlIgnoreCase(tag[0..4], "und-")) {
        const script = tag[4..];
        if (std.ascii.eqlIgnoreCase(script, "Latn")) return "Latin script";
        if (std.ascii.eqlIgnoreCase(script, "Hani")) return "Han script";
        if (std.ascii.eqlIgnoreCase(script, "Arab")) return "Arabic script";
        if (std.ascii.eqlIgnoreCase(script, "Hebr")) return "Hebrew script";
        if (std.ascii.eqlIgnoreCase(script, "Cyrl")) return "Cyrillic script";
        if (std.ascii.eqlIgnoreCase(script, "Grek")) return "Greek script";
        if (std.ascii.eqlIgnoreCase(script, "Deva")) return "Devanagari script";
        if (std.ascii.eqlIgnoreCase(script, "Thai")) return "Thai script";
        return tag;
    }

    const separator = std.mem.findScalar(u8, tag, '-') orelse tag.len;
    const primary = tag[0..separator];
    if (std.ascii.eqlIgnoreCase(primary, "en")) return "English";
    if (std.ascii.eqlIgnoreCase(primary, "es")) return "Spanish";
    if (std.ascii.eqlIgnoreCase(primary, "fr")) return "French";
    if (std.ascii.eqlIgnoreCase(primary, "de")) return "German";
    if (std.ascii.eqlIgnoreCase(primary, "it")) return "Italian";
    if (std.ascii.eqlIgnoreCase(primary, "pt")) return "Portuguese";
    if (std.ascii.eqlIgnoreCase(primary, "ja")) return "Japanese";
    if (std.ascii.eqlIgnoreCase(primary, "ko")) return "Korean";
    if (std.ascii.eqlIgnoreCase(primary, "zh")) return "Chinese";
    if (std.ascii.eqlIgnoreCase(primary, "ar")) return "Arabic";
    if (std.ascii.eqlIgnoreCase(primary, "he")) return "Hebrew";
    if (std.ascii.eqlIgnoreCase(primary, "ru")) return "Russian";
    if (std.ascii.eqlIgnoreCase(primary, "el")) return "Greek";
    if (std.ascii.eqlIgnoreCase(primary, "hi")) return "Hindi";
    if (std.ascii.eqlIgnoreCase(primary, "th")) return "Thai";
    return tag;
}

fn writeUtcTimestamp(writer: *std.Io.Writer, timestamp_ms: i64) !void {
    const max_supported_timestamp_ms: i64 = 253_402_300_799_999;
    if (timestamp_ms < 0 or timestamp_ms > max_supported_timestamp_ms) {
        try writer.writeAll("unknown");
        return;
    }

    const epoch_secs: u64 = @intCast(@divTrunc(timestamp_ms, std.time.ms_per_s));
    const milliseconds: u16 = @intCast(@mod(timestamp_ms, std.time.ms_per_s));
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} UTC", .{
        year_day.year,
        @backingInt(month_day.month),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
        milliseconds,
    });
}

pub const SessionSummarySnapshot = struct {
    summary: session_store.SessionSummary,

    pub fn render(self: SessionSummarySnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: SessionSummarySnapshot, alloc: Allocator) ![]u8 {
        return alloc.print(
            "[session] {s}\ncreated_at_ms: {d}\nupdated_at_ms: {d}\nlanguage: {s}\nhistory_len: {d}\n",
            .{
                self.summary.id,
                self.summary.created_at_ms,
                self.summary.updated_at_ms,
                self.summary.conversation_language.view(),
                self.summary.history_len,
            },
        );
    }

    pub fn renderJson(self: SessionSummarySnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":\"session_summary\",\"id\":");
        try std.json.Stringify.value(self.summary.id, .{}, &out.writer);
        try writeSessionDisplayJsonFields(&out.writer, self.summary);
        try out.writer.print(
            ",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"history_len\":{d},\"conversation_language\":",
            .{
                self.summary.created_at_ms,
                self.summary.updated_at_ms,
                self.summary.history_len,
            },
        );
        try std.json.Stringify.value(
            self.summary.conversation_language.view(),
            .{},
            &out.writer,
        );
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }
};

fn writeSessionDisplayJsonFields(writer: *std.Io.Writer, summary: session_store.SessionSummary) !void {
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(
        summary.title orelse session_display_metadata.fallback_title,
        .{},
        writer,
    );
    try writer.writeAll(",\"preview\":");
    if (summary.preview) |preview| {
        try std.json.Stringify.value(preview, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"workspace_root\":");
    if (summary.workspace_root) |workspace_root| {
        try std.json.Stringify.value(workspace_root, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"origin_workspace_root\":");
    if (summary.origin_workspace_root) |origin_workspace_root| {
        try std.json.Stringify.value(origin_workspace_root, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

pub const SessionDetailSnapshot = struct {
    state: session_codec.DurableSessionState,

    pub fn render(self: SessionDetailSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: SessionDetailSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const state = self.state;
        try out.writer.print("[session] {s}\n", .{state.id});
        try out.writer.print("created_at_ms: {d}\n", .{state.created_at_ms});
        try out.writer.print("updated_at_ms: {d}\n", .{state.updated_at_ms});
        try out.writer.print("language: {s}\n", .{state.conversation_language.view()});
        try out.writer.print("history_len: {d}\n", .{state.history.len});

        if (state.history.len == 0) {
            try out.writer.writeAll("\n(no history yet)\n");
            return try out.toOwnedSlice();
        }

        for (state.history, 0..) |turn, i| {
            try out.writer.print("\n[turn {d}]\n", .{i + 1});
            try writeSessionHistoryTurnText(&out.writer, turn);
        }

        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: SessionDetailSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const state = self.state;
        try out.writer.writeAll("{\"kind\":\"session_detail\",\"id\":");
        try std.json.Stringify.value(state.id, .{}, &out.writer);
        try out.writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"history_len\":{d}", .{ state.created_at_ms, state.updated_at_ms, state.history.len });
        try out.writer.writeAll(",\"conversation_language\":");
        try std.json.Stringify.value(state.conversation_language.view(), .{}, &out.writer);
        try out.writer.writeAll(",\"history\":[");

        for (state.history, 0..) |turn, i| {
            if (i > 0) try out.writer.writeByte(',');
            try writeSessionHistoryTurnJson(&out.writer, turn);
        }

        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

pub const SessionMigrationSnapshot = struct {
    result: session_store.SessionMigrationResult,

    pub fn render(self: SessionMigrationSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: SessionMigrationSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print(
            "[session migration] {s}\nstatus: {s}\nsource_schema_version: {d}\nsource_bytes: {d}\n",
            .{
                self.result.session_id,
                sessionMigrationStatusLabel(self.result.status),
                self.result.source_schema_version,
                self.result.source_bytes,
            },
        );
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: SessionMigrationSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":\"session_migration\",\"id\":");
        try std.json.Stringify.value(self.result.session_id, .{}, &out.writer);
        try out.writer.writeAll(",\"status\":");
        try std.json.Stringify.value(sessionMigrationStatusLabel(self.result.status), .{}, &out.writer);
        try out.writer.print(
            ",\"source_schema_version\":{d},\"source_bytes\":{d}}}",
            .{ self.result.source_schema_version, self.result.source_bytes },
        );
        return try out.toOwnedSlice();
    }
};

fn sessionMigrationStatusLabel(status: session_store.SessionMigrationStatus) []const u8 {
    return switch (status) {
        .migrated => "migrated",
        .already_current => "already_current",
    };
}

pub const SessionRecoverySnapshot = struct {
    result: session_store.SessionRecoveryResult,

    pub fn render(
        self: SessionRecoverySnapshot,
        alloc: Allocator,
        format: OutputFormat,
    ) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(
        self: SessionRecoverySnapshot,
        alloc: Allocator,
    ) ![]u8 {
        const usage_warning = if (self.result.usage_incomplete) "warning: historical usage is incomplete because the source accounting data is corrupt\n" else "";
        if (self.result.status == .indeterminate) {
            return alloc.print(
                "[session recovery] could not confirm target {s}\nsource: {s} (unchanged)\n{s}resolve: fx --resume {s}\ninspect: fx doctor\n",
                .{
                    self.result.recovered_session_id,
                    self.result.source_session_id,
                    usage_warning,
                    self.result.recovered_session_id,
                },
            );
        }
        if (self.result.status == .recovered_with_unverified_artifacts) {
            return alloc.print(
                "[session recovery] copied {s} to {s}\nhistory_turns: {d}\nwarning: legacy command artifacts could not be authenticated\n{s}resume: fx --resume {s}\n",
                .{
                    self.result.source_session_id,
                    self.result.recovered_session_id,
                    self.result.history_len,
                    usage_warning,
                    self.result.recovered_session_id,
                },
            );
        }
        return alloc.print(
            "[session recovery] copied {s} to {s}\nhistory_turns: {d}\n{s}resume: fx --resume {s}\n",
            .{
                self.result.source_session_id,
                self.result.recovered_session_id,
                self.result.history_len,
                usage_warning,
                self.result.recovered_session_id,
            },
        );
    }

    pub fn renderJson(
        self: SessionRecoverySnapshot,
        alloc: Allocator,
    ) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(
            "{\"kind\":\"session_recovery\",\"source_id\":",
        );
        try std.json.Stringify.value(
            self.result.source_session_id,
            .{},
            &out.writer,
        );
        try out.writer.writeAll(",\"recovered_id\":");
        try std.json.Stringify.value(
            self.result.recovered_session_id,
            .{},
            &out.writer,
        );
        try out.writer.writeAll(",\"status\":");
        try std.json.Stringify.value(
            @tagName(self.result.status),
            .{},
            &out.writer,
        );
        try out.writer.print(
            ",\"history_turns\":{d}",
            .{self.result.history_len},
        );
        if (self.result.usage_incomplete) try out.writer.writeAll(",\"usage_incomplete\":true");
        try out.writer.writeByte('}');
        return try out.toOwnedSlice();
    }
};

pub const DoctorSnapshot = struct {
    workspace_root: []const u8,
    model: []const u8,
    provider: model_provider.ProviderId = .codex,
    auth: auth_runtime.StatusSnapshot = .{},
    permission_mode: types.PermissionMode,
    agent_step_limit: usize,
    checks: []const doctor_runtime.Check,

    pub fn render(self: DoctorSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: DoctorSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const counts = countDoctorChecks(self.checks);
        try out.writer.print(
            "[doctor] ok={d} warn={d} fail={d}\n",
            .{ counts.ok, counts.warn, counts.fail },
        );
        try out.writer.print("[doctor] workspace={s}\n", .{self.workspace_root});
        try out.writer.print("[doctor] model={s}\n", .{self.model});
        try out.writer.print("[doctor] model_source={s}\n", .{providerDisplayName(&self.provider)});
        try out.writer.print("[doctor] auth={s}\n", .{self.auth.activeSourceLabel()});
        try out.writer.print("[doctor] auth_refreshable={}\n", .{self.auth.refreshable()});
        if (self.auth.expired) try out.writer.writeAll("[doctor] auth_expired=true\n");
        try out.writer.print("[doctor] permission_mode={s}\n", .{permissions.permissionModeDisplayLabel(self.permission_mode)});
        try out.writer.print("[doctor] agent_step_limit={d}\n", .{self.agent_step_limit});

        for (self.checks) |entry| {
            try out.writer.print("[{s}] ", .{checkStatusLabel(entry.status)});
            try writeTerminalSafe(&out.writer, alloc, entry.name);
            try out.writer.writeAll(": ");
            try writeTerminalSafe(&out.writer, alloc, entry.detail);
            try out.writer.writeByte('\n');
        }

        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: DoctorSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }

    pub fn writeJson(self: DoctorSnapshot, writer: *std.Io.Writer) !void {
        const counts = countDoctorChecks(self.checks);
        try writer.print(
            "{{\"kind\":\"doctor\",\"ok_count\":{d},\"warn_count\":{d},\"fail_count\":{d}",
            .{ counts.ok, counts.warn, counts.fail },
        );
        try writer.writeAll(",\"workspace\":");
        try std.json.Stringify.value(self.workspace_root, .{}, writer);
        try writer.writeAll(",\"model\":");
        try std.json.Stringify.value(self.model, .{}, writer);
        try writer.writeAll(",\"model_source\":");
        try std.json.Stringify.value(providerDisplayName(&self.provider), .{}, writer);
        try writer.writeAll(",\"auth\":");
        try std.json.Stringify.value(self.auth.activeSourceLabel(), .{}, writer);
        try writer.print(",\"auth_refreshable\":{}", .{self.auth.refreshable()});
        if (self.auth.expired) try writer.writeAll(",\"auth_expired\":true");
        try writer.writeAll(",\"permission_mode\":");
        try std.json.Stringify.value(permissionModeLabel(self.permission_mode), .{}, writer);
        try writer.print(",\"agent_step_limit\":{d},\"checks\":[", .{self.agent_step_limit});

        for (self.checks, 0..) |entry, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try std.json.Stringify.value(entry.name, .{}, writer);
            try writer.writeAll(",\"status\":");
            try std.json.Stringify.value(checkStatusLabel(entry.status), .{}, writer);
            try writer.writeAll(",\"detail\":");
            try std.json.Stringify.value(entry.detail, .{}, writer);
            try writer.writeByte('}');
        }

        try writer.writeByte(']');
        try writer.writeByte('}');
    }
};

pub const UpgradeSnapshot = struct {
    current: []const u8,
    latest: []const u8,
    channel: []const u8 = "stable",
    current_channel: []const u8 = "stable",
    current_revision: []const u8 = "",
    latest_revision: []const u8 = "",
    status: Status,
    err_message: ?[]const u8 = null,

    pub const Status = enum {
        upgraded,
        up_to_date,
        failed,

        fn label(self: Status) []const u8 {
            return switch (self) {
                .upgraded => "upgraded",
                .up_to_date => "up_to_date",
                .failed => "failed",
            };
        }
    };

    pub fn render(self: UpgradeSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: UpgradeSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        if (self.err_message) |msg| {
            try out.writer.print("error: {s}\n", .{msg});
            return try out.toOwnedSlice();
        }

        switch (self.status) {
            .upgraded => {
                try out.writer.writeAll("upgraded to ");
                if (std.mem.eql(u8, self.channel, "dev") and self.latest_revision.len > 0) {
                    try out.writer.print("dev {s} (", .{shortRevision(self.latest_revision)});
                    try writeVersionWithPrefix(&out.writer, self.latest);
                    try out.writer.writeByte(')');
                } else {
                    try writeVersionWithPrefix(&out.writer, self.latest);
                }
                try out.writer.writeByte('\n');
                const channel = update_target.Channel.parse(self.channel) orelse .stable;
                if (update_notes.destination(
                    channel,
                    self.latest,
                    self.current_revision,
                    self.latest_revision,
                )) |notes| {
                    try update_notes.writeLabel(notes.kind, &out.writer);
                    try out.writer.writeAll(": ");
                    try notes.writeUrl(&out.writer);
                    try out.writer.writeByte('\n');
                }
            },
            .up_to_date => {
                if (std.mem.eql(u8, self.channel, "dev") and self.latest_revision.len > 0) {
                    try out.writer.print("fx dev {s} is already up to date (", .{shortRevision(self.latest_revision)});
                } else {
                    try out.writer.writeAll("fx is already up to date (");
                }
                try writeVersionWithPrefix(&out.writer, self.latest);
                try out.writer.writeAll(")\n");
            },
            .failed => try out.writer.writeAll("upgrade failed\n"),
        }

        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: UpgradeSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":\"upgrade\"");

        if (self.err_message) |msg| {
            try out.writer.writeAll(",\"error\":");
            try std.json.Stringify.value(msg, .{}, &out.writer);
            try out.writer.writeByte('}');
            return try out.toOwnedSlice();
        }

        try out.writer.writeAll(",\"current\":");
        try std.json.Stringify.value(self.current, .{}, &out.writer);
        try out.writer.writeAll(",\"latest\":");
        try std.json.Stringify.value(self.latest, .{}, &out.writer);
        if (!std.mem.eql(u8, self.channel, "stable") or
            !std.mem.eql(u8, self.current_channel, "stable") or
            self.latest_revision.len > 0)
        {
            try out.writer.writeAll(",\"channel\":");
            try std.json.Stringify.value(self.channel, .{}, &out.writer);
            try out.writer.writeAll(",\"current_channel\":");
            try std.json.Stringify.value(self.current_channel, .{}, &out.writer);
            try out.writer.writeAll(",\"current_revision\":");
            try std.json.Stringify.value(self.current_revision, .{}, &out.writer);
            try out.writer.writeAll(",\"latest_revision\":");
            try std.json.Stringify.value(self.latest_revision, .{}, &out.writer);
        }
        try out.writer.writeAll(",\"status\":");
        try std.json.Stringify.value(self.status.label(), .{}, &out.writer);
        try out.writer.writeByte('}');
        return try out.toOwnedSlice();
    }
};

fn shortRevision(revision: []const u8) []const u8 {
    return revision[0..@min(revision.len, 12)];
}

fn writeVersionWithPrefix(writer: *std.Io.Writer, version: []const u8) !void {
    if (version.len == 0 or version[0] != 'v') {
        try writer.writeByte('v');
    }
    try writer.writeAll(version);
}

fn displayGrantTarget(alloc: Allocator, workspace_root: []const u8, grant: types.PermissionGrant) ![]u8 {
    if (std.mem.eql(u8, grant.tool_name, "run_command") or std.mem.eql(u8, grant.tool_name, "bash")) {
        return alloc.dupe(u8, grant.target_path);
    }

    if (std.Io.Dir.path.isAbsolute(grant.target_path)) {
        return std.Io.Dir.path.relativeAlloc(alloc, "/", null, workspace_root, grant.target_path) catch alloc.dupe(u8, grant.target_path);
    }

    return alloc.dupe(u8, grant.target_path);
}

fn writePermissionRulesText(writer: *std.Io.Writer, rules: types.PermissionRuleSet) !void {
    if (rules.rules.len == 0) {
        try writer.writeAll("[permissions] configured rules: (none)\n");
        return;
    }

    try writer.writeAll("[permissions] configured rules:\n");
    for (rules.rules) |rule| {
        try writer.print(" - {s} {s} -> {s}\n", .{ @tagName(rule.action), rule.permission, rule.pattern });
    }
}

fn writePermissionRulesJson(writer: *std.Io.Writer, rules: types.PermissionRuleSet) !void {
    try writer.writeByte('[');
    for (rules.rules, 0..) |rule, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"permission\":");
        try std.json.Stringify.value(rule.permission, .{}, writer);
        try writer.writeAll(",\"pattern\":");
        try std.json.Stringify.value(rule.pattern, .{}, writer);
        try writer.writeAll(",\"action\":");
        try std.json.Stringify.value(@tagName(rule.action), .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

const DoctorCheckCounts = struct {
    ok: usize = 0,
    warn: usize = 0,
    fail: usize = 0,
};

fn countDoctorChecks(checks: []const doctor_runtime.Check) DoctorCheckCounts {
    var counts: DoctorCheckCounts = .{};
    for (checks) |entry| {
        switch (entry.status) {
            .ok => counts.ok += 1,
            .warn => counts.warn += 1,
            .fail => counts.fail += 1,
        }
    }
    return counts;
}

fn checkStatusLabel(status: doctor_runtime.CheckStatus) []const u8 {
    return switch (status) {
        .ok => "ok",
        .warn => "warn",
        .fail => "fail",
    };
}

fn writeSessionHistoryTurnText(writer: *std.Io.Writer, turn: types.HistoryTurn) !void {
    switch (turn) {
        .compacted_summary => |entry| {
            try writer.print("[compacted] removed_turns={d} compactions={d}\n", .{ entry.removed_turn_count, entry.compaction_count });
            var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena_state.deinit();
            const rendered = compactor.modelText(arena_state.allocator(), entry.summary) catch null;
            try writeTextBlock(writer, rendered orelse entry.summary);
        },
        .assistant => |entry| {
            try writeSessionUserTurnText(writer, entry.user);
            try writeSessionExecutionText(writer, entry.execution);
            try writer.writeAll("[assistant]\n");
            try writeTextBlock(writer, entry.assistant);
        },
        .interrupted => |entry| {
            try writeSessionUserTurnText(writer, entry.user);
            try writeSessionExecutionText(writer, entry.execution);
            if (entry.assistant) |assistant| {
                try writer.writeAll("[assistant]\n");
                try writeTextBlock(writer, assistant);
            }
            try writer.writeAll("[interrupted]\n");
            if (entry.tool_call) |tool_call| {
                try writer.print("tool_call_id: {s}\n", .{tool_call.id});
                try writer.print("tool_name: {s}\n", .{tool_call.name});
            } else {
                try writer.writeAll("tool: (none)\n");
            }
            if (entry.completed_tool_names.len > 0) {
                try writer.writeAll("completed_tools: ");
                for (entry.completed_tool_names, 0..) |name, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(name);
                }
                try writer.writeByte('\n');
            }
        },
    }
}

fn writeSessionExecutionText(writer: *std.Io.Writer, execution: types.ExecutionMemory) !void {
    if (execution.isEmpty()) return;

    try writer.writeAll("[execution]\n");
    for (execution.tool_steps) |step| {
        if (step.assistant) |assistant| {
            try writer.writeAll("assistant:\n");
            try writeTextBlock(writer, assistant);
        }
        for (step.tool_calls) |call| {
            try writer.print("tool_call: {s} {s}\n", .{ call.id, call.name });
            try writer.writeAll("arguments:\n");
            try writeTextBlock(writer, call.arguments_json);
        }
        for (step.tool_results) |result| {
            try writer.print(
                "tool_result: {s} {s} {s}\n",
                .{ result.tool_call_id, result.tool_name, @tagName(result.status) },
            );
            try writer.writeAll("output:\n");
            try writeTextBlock(writer, result.output);
        }
    }
    for (execution.files) |file| {
        try writer.print(
            "file: {s} {s} {s}\n",
            .{ @tagName(file.action), @tagName(file.status), file.path },
        );
    }
}

fn writeSessionUserTurnText(writer: *std.Io.Writer, user: types.UserTurn) !void {
    try writer.writeAll("[user]\n");
    try writeTextBlock(writer, user.text);
    if (user.images.len > 0) {
        try writer.print("[images] {d}\n", .{user.images.len});
        for (user.images) |image| {
            try writer.print(" - {s} ({s})\n", .{ image.path, image.media_type });
        }
    }
}

fn writeTextBlock(writer: *std.Io.Writer, text: []const u8) !void {
    if (text.len == 0) {
        try writer.writeAll("(empty)\n");
        return;
    }

    try writer.writeAll(text);
    if (text[text.len - 1] != '\n') try writer.writeByte('\n');
}

fn writeSessionHistoryTurnJson(writer: *std.Io.Writer, turn: types.HistoryTurn) !void {
    switch (turn) {
        .compacted_summary => |entry| {
            try writer.writeAll("{\"kind\":\"compacted_summary\",\"summary\":");
            try std.json.Stringify.value(entry.summary, .{}, writer);
            try writer.print(",\"removed_turn_count\":{d},\"compaction_count\":{d}", .{ entry.removed_turn_count, entry.compaction_count });
            try writer.writeByte('}');
        },
        .assistant => |entry| {
            try writer.writeAll("{\"kind\":\"assistant\",\"user\":");
            try writeSessionUserTurnJson(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            try std.json.Stringify.value(entry.assistant, .{}, writer);
            try writer.writeAll(",\"execution\":");
            try session_json.writeExecutionMemoryJson(writer, entry.execution);
            try writer.writeByte('}');
        },
        .interrupted => |entry| {
            try writer.writeAll("{\"kind\":\"interrupted\",\"user\":");
            try writeSessionUserTurnJson(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            if (entry.assistant) |assistant| {
                try std.json.Stringify.value(assistant, .{}, writer);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"tool_call\":");
            if (entry.tool_call) |tool_call| {
                try writer.writeAll("{\"id\":");
                try std.json.Stringify.value(tool_call.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(tool_call.name, .{}, writer);
                try writer.writeAll(",\"arguments_json\":");
                try std.json.Stringify.value(tool_call.arguments_json, .{}, writer);
                try writer.writeByte('}');
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"completed_tool_names\":[");
            for (entry.completed_tool_names, 0..) |name, i| {
                if (i > 0) try writer.writeByte(',');
                try std.json.Stringify.value(name, .{}, writer);
            }
            try writer.writeByte(']');
            if (!entry.execution.isEmpty()) {
                try writer.writeAll(",\"execution\":");
                try session_json.writeExecutionMemoryJson(writer, entry.execution);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeSessionUserTurnJson(writer: *std.Io.Writer, user: types.UserTurn) !void {
    try writer.writeAll("{\"text\":");
    try std.json.Stringify.value(user.text, .{}, writer);
    try writer.writeAll(",\"images\":[");

    for (user.images, 0..) |image, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try std.json.Stringify.value(image.path, .{}, writer);
        try writer.writeAll(",\"media_type\":");
        try std.json.Stringify.value(image.media_type, .{}, writer);
        try writer.writeByte('}');
    }

    try writer.writeAll("]}");
}

pub const SlackSnapshot = struct {
    action: []const u8,
    installed: bool,
    app_id: ?[]const u8,
    team_id: ?[]const u8,
    bot_user_id: ?[]const u8,
    expires_at_ms: ?i64,
    refresh_expires_at_ms: ?i64,

    pub fn render(self: SlackSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        if (format == .json) {
            try std.json.Stringify.value(self, .{}, &out.writer);
        } else if (!self.installed) {
            try out.writer.writeAll("No local Slack bot installation. Run fx slack install.\n");
        } else {
            try out.writer.writeAll(if (std.mem.eql(u8, self.action, "install"))
                "fx is now installed in your Slack workspace.\n"
            else
                "Your fx Slack bot credentials are saved on this computer.\n");
            if (self.expires_at_ms) |expiry| {
                if (expiry >= 0 and expiry <= 253_402_300_799_999) {
                    var date_buf: [24]u8 = undefined;
                    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(expiry, std.time.ms_per_s)) };
                    const day = epoch.getDaySeconds();
                    try out.writer.print("Access expires on {s} at {d:0>2}:{d:0>2} UTC.\n", .{
                        usage_report.formatUtcDate(&date_buf, expiry),
                        day.getHoursIntoDay(),
                        day.getMinutesIntoHour(),
                    });
                } else {
                    try out.writer.writeAll("Access expiration time is unavailable.\n");
                }
                try out.writer.writeAll("Run fx slack refresh to renew locally.\n");
            }
        }
        return out.toOwnedSlice();
    }
};

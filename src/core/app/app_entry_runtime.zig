const std = @import("std");
const builtin = @import("builtin");
const app_process_runtime = @import("app_process_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const auto_upgrade = @import("../upgrade/auto_upgrade.zig");
const cli_surface = @import("../cli/cli_surface.zig");
const config_runtime = @import("../config/config_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const process_provider = @import("../execution/process_provider.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const provider_set = @import("../gateway/provider_set.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const context_contract = @import("../workspace/context_contract.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const update_target = @import("../upgrade/update_target.zig");

const Allocator = std.mem.Allocator;

const GracefulExitSigintGuard = struct {
    saved_action: ?std.posix.Sigaction = null,

    fn install(enabled: bool) @This() {
        if (!enabled) return .{};

        const ignore_action: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var saved_action: std.posix.Sigaction = undefined;
        std.posix.sigaction(std.posix.SIG.INT, &ignore_action, &saved_action);
        return .{ .saved_action = saved_action };
    }

    fn deinit(self: *@This()) void {
        const saved_action = self.saved_action orelse return;
        std.posix.sigaction(std.posix.SIG.INT, &saved_action, null);
        self.saved_action = null;
    }
};

pub const Config = struct {
    version: []const u8 = "",
    revision: []const u8 = "",
    build_channel: update_target.Channel = .stable,
    auth_mode: credentials.AuthMode = .local,
    command_catalog: command_specs.TopLevelRegistry,
    default_model: []const u8,
    default_agent_step_limit: usize,
    models_path: []const u8,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_provider: gateway_provider.Provider,
    provider_set: provider_set.Set,
    process_provider: process_provider.Provider = process_provider.unavailable_provider,
    url_opener: host.UrlOpener,
    secret_store: host.SecretStore,
    prompt_policy: prompt_policy.Policy,
    skill_root_policy: skill_contract.RootPolicy,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize,
    max_history_turns: usize,
    context_registry: context_contract.Registry,
    mode_registry: mode_registry.Registry,
    tool_set: tool_set_contract.ToolSet,
};

pub const RunOutcome = union(enum) {
    returned,
    exit: u8,
};

pub const BeforeInteractiveResult = union(enum) {
    interactive: cli_surface.InteractiveLaunch,
    returned,
    exit: u8,
};

const RunIfRequestedFn = *const fn (?*anyopaque, Allocator, []const [:0]const u8, cli_surface.Config) anyerror!cli_surface.RunResult;
const GetenvFn = *const fn (?*anyopaque, []const u8) ?[]const u8;
const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;
const FormatUnexpectedErrorFn = *const fn ([]u8, anyerror) anyerror![]const u8;
const StartWorkerThreadFn = *const fn (?*anyopaque, *anyopaque) anyerror!void;
const ReplaceProcessFn = *const fn (
    ?*anyopaque,
    std.Io,
    std.process.ReplaceOptions,
) std.process.ReplaceError;
const RunDeps = struct {
    cli_ctx: ?*anyopaque = null,
    run_if_requested: RunIfRequestedFn = runIfRequestedDefault,
    env_ctx: ?*anyopaque = null,
    getenv: GetenvFn = getenvDefault,
    stderr_ctx: ?*anyopaque = null,
    write_stderr: WriteFn = writeRealStderr,
    stdout_ctx: ?*anyopaque = null,
    write_stdout: WriteFn = writeRealStdout,
    format_unexpected_error: FormatUnexpectedErrorFn = formatUnexpectedError,
    worker_ctx: ?*anyopaque = null,
    start_worker_thread: ?StartWorkerThreadFn = null,
    replace_ctx: ?*anyopaque = null,
    replace_process: ReplaceProcessFn = replaceProcessDefault,
};

pub fn runBeforeInteractive(alloc: Allocator, args: []const [:0]const u8, cfg: Config) !BeforeInteractiveResult {
    const run_result = cli_surface.runIfRequested(alloc, args, cliSurfaceConfig(cfg)) catch |err| switch (err) {
        error.UnknownCliCommand => return .{ .exit = 1 },
        else => {
            tryWriteErrorMessage(.{}, err);
            return .{ .exit = 1 };
        },
    };

    return beforeInteractiveResultFromRunResult(alloc, run_result, benchEnabled());
}

fn beforeInteractiveResultFromRunResult(alloc: Allocator, run_result: cli_surface.RunResult, bench: bool) BeforeInteractiveResult {
    switch (run_result) {
        .interactive => |launch| {
            if (bench) {
                var mutable_launch = launch;
                mutable_launch.deinit(alloc);
                return .returned;
            }
            return .{ .interactive = launch };
        },
        .handled_success => return .returned,
        .handled_failure => return .{ .exit = 1 },
        .handled_exit => |code| return if (code == 0) .returned else .{ .exit = code },
    }
}

fn benchEnabled() bool {
    if (comptime builtin.link_libc) {
        return std.c.getenv("FX_BENCH") != null;
    }
    return io_mod.getenv("FX_BENCH") != null;
}

/// `app` is uninitialized storage that must stay valid until the process
/// exits: interactive shutdown stops background threads without joining them,
/// so they can still reach the app after this returns.
pub fn runInteractive(comptime App: type, app: *App, alloc: Allocator, launch: *cli_surface.InteractiveLaunch, auth_mode: credentials.AuthMode) !RunOutcome {
    return runInteractiveWithDeps(App, app, alloc, launch, auth_mode, .{});
}

fn runInteractiveWithDeps(comptime App: type, app: *App, alloc: Allocator, launch: *cli_surface.InteractiveLaunch, auth_mode: credentials.AuthMode, deps: RunDeps) !RunOutcome {
    const resume_requested = launch.requested_resume != null;
    app.* = App.init(alloc, launch, auth_mode) catch |err| {
        switch (err) {
            error.NotATerminal => {
                writeStderr(deps, "fx requires an interactive terminal (TTY).\n");
                return .{ .exit = 1 };
            },
            error.TerminalTooSmall => {
                writeStderr(deps, "fx needs at least 5 terminal rows.\n");
                return .returned;
            },
            error.RecordingStartFailed => {
                writeStderr(deps, "fx: unable to start terminal recording.\n");
                return .{ .exit = 1 };
            },
            error.NoRememberedSession => {
                writeStderr(deps, "fx: no remembered session for this workspace; choose one with fx -r or fx --resume <id>\n");
                return .{ .exit = 1 };
            },
            error.RememberedSessionUnavailable => {
                writeStderr(deps, "fx: the remembered session ID could not be read; choose one with fx -r or fx --resume <id>\n");
                return .{ .exit = 1 };
            },
            error.NoSavedSessions => {
                writeStderr(deps, "fx: no saved sessions for this workspace.\n");
                return .{ .exit = 1 };
            },
            error.NoReadableSessions => {
                // The unreadable sessions can belong to any workspace, so only
                // the absence of a readable one is tied to this workspace.
                writeStderr(deps, "fx: no readable saved sessions for this workspace, and some saved sessions are unreadable; run `fx doctor` for recovery guidance.\n");
                return .{ .exit = 1 };
            },
            error.SessionNotFound => {
                writeStderr(deps, "fx: saved session not found.\n");
                return .{ .exit = 1 };
            },
            error.SessionBusy => {
                writeStderr(deps, "fx: another fx process may be using this session (running or suspended); check other terminals or run jobs, then use fg or quit that process\n");
                return .{ .exit = 1 };
            },
            error.SessionLockUnsupported => {
                writeStderr(deps, "fx: the filesystem cannot provide the required session lock\n");
                return .{ .exit = 1 };
            },
            error.SessionAuthorityBoundaryUnavailable,
            error.SessionCommitBoundaryUnavailable,
            => {
                writeStderr(deps, "fx: a saved session has an unfinished update that could not be recovered; run `fx doctor` to identify the affected session\n");
                return .{ .exit = 1 };
            },
            error.OneOffSessionNotResumable => {
                writeStderr(deps, "fx: subagent child sessions cannot be resumed directly; message the named agent from its parent session\n");
                return .{ .exit = 1 };
            },
            error.InvalidSessionFormat => {
                writeStderr(deps, "fx: saved session is unreadable. Run `fx doctor`; if it is recoverable, use `fx session recover <id>`.\n");
                return .{ .exit = 1 };
            },
            error.UnsupportedSessionSchema => {
                writeStderr(deps, "fx: saved session uses an unsupported version and cannot be resumed by this fx build.\n");
                return .{ .exit = 1 };
            },
            else => {
                reportUnexpectedInteractiveError(deps, err);
                return err;
            },
        }
    };
    if (@hasDecl(App, "rebindAfterInit")) app.rebindAfterInit();
    var app_needs_deinit = true;
    defer if (app_needs_deinit) {
        var shutdown = app.shutdownForProcessExit();
        defer shutdown.deinit(alloc);
        if (shutdown.failure) |err| reportShutdownFailure(deps, err);
    };
    if (comptime @hasField(App, "session") and
        @hasDecl(@TypeOf(app.session), "attachProfileUsagePublisher"))
    {
        app.session.attachProfileUsagePublisher(app.alloc);
    }
    if (resume_requested) app.startResumedSessionReconciliation();
    if (@hasDecl(App, "configureNotifications")) try app.configureNotifications();
    if (@hasDecl(App, "playStartupSound")) app.playStartupSound();
    if (@hasDecl(App, "startAutoUpgrade")) app.startAutoUpgrade();
    if (@hasDecl(App, "startFileIndex")) app.startFileIndex();
    startWorkerThread(App, app, deps) catch |err| {
        app.releaseTerminal();
        reportUnexpectedInteractiveError(deps, err);
        return err;
    };
    app.startModelCacheWarmup();
    if (@hasDecl(App, "startSessionCatalogPreload")) app.startSessionCatalogPreload();

    app.run() catch |err| {
        app.releaseTerminal();
        if (err == error.TerminalInputClosed) {
            app_needs_deinit = false;
            var shutdown = app.shutdownForProcessExit();
            defer shutdown.deinit(alloc);
            if (shutdown.failure) |failure| {
                reportShutdownFailure(deps, failure);
                return .{ .exit = 1 };
            }
            return .returned;
        }
        reportUnexpectedInteractiveError(deps, err);
        return err;
    };
    const relaunch_request: ?auto_upgrade.RelaunchRequest = if (comptime @hasDecl(App, "takeUpgradeRelaunchRequest"))
        app.takeUpgradeRelaunchRequest()
    else
        null;
    const resume_handoff_columns: u16 = if (comptime @hasDecl(App, "resumeHandoffColumns"))
        app.resumeHandoffColumns()
    else
        0;
    var graceful_exit_sigint_guard = GracefulExitSigintGuard.install(
        relaunch_request == null,
    );
    defer graceful_exit_sigint_guard.deinit();
    app_needs_deinit = false;
    const shutdown: app_session_runtime.ShutdownOutcome = app.shutdownForProcessExit();
    const handoff_value = shutdown.handoff;
    if (shutdown.failure) |err| {
        if (handoff_value) |value| {
            var handoff = value;
            handoff.deinit(alloc);
        }
        reportShutdownFailure(deps, err);
        return .{ .exit = 1 };
    }
    if (relaunch_request) |request| {
        if (handoff_value) |value| {
            var handoff = value;
            defer handoff.deinit(alloc);
            var argv: [5][]const u8 = undefined;
            var argc: usize = 0;
            argv[argc] = request.executablePath();
            argc += 1;
            for ([_][]const u8{ "resume", handoff.session_id, cli_surface.upgrade_relaunch_arg }) |arg| {
                argv[argc] = arg;
                argc += 1;
            }
            if (request.previousRevision()) |revision| {
                argv[argc] = revision;
                argc += 1;
            }
            const argv_slice = argv[0..argc];
            const replace_err = deps.replace_process(
                deps.replace_ctx,
                io_mod.getIo(),
                .{ .argv = argv_slice },
            );
            writeUpgradeRelaunchFailure(deps, replace_err, handoff.session_id);
        } else {
            writeStderr(
                deps,
                "fx: upgrade installed, but no validated resume handoff was available. Your conversation remains on disk; run `fx doctor`.\n",
            );
        }
        return .{ .exit = 1 };
    }
    if (handoff_value) |value| {
        var handoff = value;
        defer handoff.deinit(alloc);
        var message_buffer: [512]u8 = undefined;
        const message = (if (comptime @hasDecl(App, "formatResumeHandoff"))
            App.formatResumeHandoff(
                &message_buffer,
                handoff.session_id,
                resume_handoff_columns,
            )
        else
            formatResumeHandoff(&message_buffer, handoff.session_id)) catch return .returned;
        deps.write_stdout(deps.stdout_ctx, message) catch {};
    }
    return .returned;
}

fn reportShutdownFailure(deps: RunDeps, err: anyerror) void {
    var buffer: [256]u8 = undefined;
    const text = std.mem.print(&buffer, "fx: session save failed: {s}\n", .{@errorName(err)}) catch
        "fx: session save failed\n";
    writeStderr(deps, text);
}

fn replaceProcessDefault(
    _: ?*anyopaque,
    zio: std.Io,
    options: std.process.ReplaceOptions,
) std.process.ReplaceError {
    return std.process.replace(zio, options);
}

fn writeUpgradeRelaunchFailure(
    deps: RunDeps,
    err: std.process.ReplaceError,
    session_id: []const u8,
) void {
    var buffer: [768]u8 = undefined;
    const message = std.mem.print(
        &buffer,
        "fx: upgrade installed, but relaunch failed: {s}\nContinue session with: fx --resume {s}\n",
        .{ @errorName(err), session_id },
    ) catch "fx: upgrade installed, but relaunch failed; run `fx doctor`.\n";
    writeStderr(deps, message);
}

fn cliSurfaceConfig(cfg: Config) cli_surface.Config {
    return .{
        .version = cfg.version,
        .revision = cfg.revision,
        .build_channel = cfg.build_channel,
        .auth_mode = cfg.auth_mode,
        .command_catalog = cfg.command_catalog,
        .default_model = cfg.default_model,
        .default_agent_step_limit = cfg.default_agent_step_limit,
        .models_path = cfg.models_path,
        .gateway_retry_count = cfg.gateway_retry_count,
        .gateway_chat_url = cfg.gateway_chat_url,
        .gateway_provider = cfg.gateway_provider,
        .provider_set = cfg.provider_set,
        .process_provider = cfg.process_provider,
        .url_opener = cfg.url_opener,
        .secret_store = cfg.secret_store,
        .prompt_policy = cfg.prompt_policy,
        .skill_root_policy = cfg.skill_root_policy,
        .ignored_list_entries = cfg.ignored_list_entries,
        .max_list_entries = cfg.max_list_entries,
        .max_read_file_bytes = cfg.max_read_file_bytes,
        .max_read_file_lines = cfg.max_read_file_lines,
        .max_read_file_line_len = cfg.max_read_file_line_len,
        .max_command_output_bytes = cfg.max_command_output_bytes,
        .max_tool_result_bytes = cfg.max_tool_result_bytes,
        .max_history_turns = cfg.max_history_turns,
        .context_registry = cfg.context_registry,
        .mode_registry = cfg.mode_registry,
        .tool_set = cfg.tool_set,
    };
}

fn startWorkerThread(comptime App: type, app: *App, deps: RunDeps) !void {
    if (!@hasField(App, "worker_thread")) {
        const start = deps.start_worker_thread orelse return error.MissingWorkerThreadDependency;
        return start(deps.worker_ctx, @ptrCast(app));
    }
    if (deps.start_worker_thread) |start| {
        return start(deps.worker_ctx, @ptrCast(app));
    }
    try app_process_runtime.Runtime(App).startWorkerThread(app);
}

fn runIfRequestedDefault(_: ?*anyopaque, alloc: Allocator, args: []const [:0]const u8, cfg: cli_surface.Config) !cli_surface.RunResult {
    return cli_surface.runIfRequested(alloc, args, cfg);
}

fn getenvDefault(_: ?*anyopaque, key: []const u8) ?[]const u8 {
    return io_mod.getenv(key);
}

fn writeRealStderr(_: ?*anyopaque, text: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
}

fn writeRealStdout(_: ?*anyopaque, text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn formatResumeHandoff(buffer: []u8, session_id: []const u8) ![]const u8 {
    return std.mem.print(
        buffer,
        "Continue session with: fx --resume {s}\n",
        .{session_id},
    );
}

fn formatUnexpectedError(buffer: []u8, err: anyerror) ![]const u8 {
    return std.mem.print(buffer, "fx: {s}\n", .{config_runtime.modelNotSelectedMessage(err) orelse @errorName(err)});
}

fn reportUnexpectedInteractiveError(deps: RunDeps, err: anyerror) void {
    var buffer: [256]u8 = undefined;
    const message = deps.format_unexpected_error(&buffer, err) catch return;
    deps.write_stderr(deps.stderr_ctx, message) catch {};
}

fn writeStderr(deps: RunDeps, text: []const u8) void {
    deps.write_stderr(deps.stderr_ctx, text) catch {};
}

fn tryWriteErrorMessage(deps: RunDeps, err: anyerror) void {
    writeStderr(deps, "fx: ");
    writeStderr(deps, config_runtime.modelNotSelectedMessage(err) orelse @errorName(err));
    writeStderr(deps, "\n");
}

var test_events: [16][]const u8 = undefined;
var test_event_count: usize = 0;
var active_capture: ?*TestCapture = null;

fn resetTestEvents() void {
    test_event_count = 0;
}

fn appendTestEvent(text: []const u8) void {
    test_events[test_event_count] = text;
    test_event_count += 1;
}

const TestCapture = struct {
    run_result: cli_surface.RunResult,
    cli_calls: usize = 0,
    seen_config: ?cli_surface.Config = null,
    stderr: std.Io.Writer.Allocating,
    stdout: std.Io.Writer.Allocating,
    bench_value: ?[]const u8 = null,
    init_error: ?anyerror = null,
    worker_error: ?anyerror = null,
    run_error: ?anyerror = null,
    stderr_error: ?anyerror = null,
    stdout_error: ?anyerror = null,
    stderr_calls: usize = 0,
    stdout_calls: usize = 0,
    record_stderr_event: bool = false,
    record_stdout_event: bool = false,
    resume_handoff_id: ?[]const u8 = null,
    shutdown_failure: ?anyerror = null,
    raise_sigint_during_deinit: bool = false,
    upgrade_relaunch_path: ?[]const u8 = null,
    upgrade_previous_revision: ?[]const u8 = null,
    replace_error: std.process.ReplaceError = error.InvalidExe,
    replace_calls: usize = 0,
    replace_arg_count: usize = 0,
    replace_arg_bufs: [5][128]u8 = undefined,
    replace_arg_lens: [5]usize = .{ 0, 0, 0, 0, 0 },
    fail_unexpected_format: bool = false,

    fn init(run_result: cli_surface.RunResult) TestCapture {
        resetTestEvents();
        return .{
            .run_result = run_result,
            .stderr = .init(std.testing.allocator),
            .stdout = .init(std.testing.allocator),
        };
    }

    fn deinit(self: *TestCapture) void {
        active_capture = null;
        self.stderr.deinit();
        self.stdout.deinit();
    }

    fn deps(self: *TestCapture) RunDeps {
        active_capture = self;
        return .{
            .cli_ctx = self,
            .run_if_requested = runIfRequestedForTest,
            .env_ctx = self,
            .getenv = getenvForTest,
            .stderr_ctx = self,
            .write_stderr = writeStderrForTest,
            .stdout_ctx = self,
            .write_stdout = writeStdoutForTest,
            .format_unexpected_error = if (self.fail_unexpected_format)
                failUnexpectedErrorFormatForTest
            else
                formatUnexpectedError,
            .worker_ctx = self,
            .start_worker_thread = startWorkerThreadForTest,
            .replace_ctx = self,
            .replace_process = replaceProcessForTest,
        };
    }

    fn replaceArg(self: *const TestCapture, index: usize) []const u8 {
        return self.replace_arg_bufs[index][0..self.replace_arg_lens[index]];
    }
};

fn runIfRequestedForTest(ctx: ?*anyopaque, _: Allocator, _: []const [:0]const u8, cfg: cli_surface.Config) !cli_surface.RunResult {
    const capture: *TestCapture = @ptrCast(@alignCast(ctx.?));
    capture.cli_calls += 1;
    capture.seen_config = cfg;
    return capture.run_result;
}

fn getenvForTest(ctx: ?*anyopaque, key: []const u8) ?[]const u8 {
    const capture: *TestCapture = @ptrCast(@alignCast(ctx.?));
    if (std.mem.eql(u8, key, "FX_BENCH")) return capture.bench_value;
    return null;
}

fn writeStderrForTest(ctx: ?*anyopaque, text: []const u8) !void {
    const capture: *TestCapture = @ptrCast(@alignCast(ctx.?));
    capture.stderr_calls += 1;
    if (capture.record_stderr_event) appendTestEvent("stderr-attempt");
    if (capture.stderr_error) |err| return err;
    try capture.stderr.writer.writeAll(text);
}

fn writeStdoutForTest(ctx: ?*anyopaque, text: []const u8) !void {
    const capture: *TestCapture = @ptrCast(@alignCast(ctx.?));
    capture.stdout_calls += 1;
    if (capture.record_stdout_event) appendTestEvent("stdout-attempt");
    if (capture.stdout_error) |err| return err;
    try capture.stdout.writer.writeAll(text);
}

fn replaceProcessForTest(
    ctx: ?*anyopaque,
    _: std.Io,
    options: std.process.ReplaceOptions,
) std.process.ReplaceError {
    const capture: *TestCapture = @ptrCast(@alignCast(ctx.?));
    capture.replace_calls += 1;
    capture.replace_arg_count = options.argv.len;
    const count = @min(options.argv.len, capture.replace_arg_bufs.len);
    for (options.argv[0..count], 0..) |arg, index| {
        if (arg.len > capture.replace_arg_bufs[index].len) {
            return error.SystemResources;
        }
        @memcpy(capture.replace_arg_bufs[index][0..arg.len], arg);
        capture.replace_arg_lens[index] = arg.len;
    }
    return capture.replace_error;
}

fn failUnexpectedErrorFormatForTest(_: []u8, _: anyerror) ![]const u8 {
    return error.TestUnexpectedErrorFormatFailed;
}

fn startWorkerThreadForTest(ctx: ?*anyopaque, _: *anyopaque) !void {
    appendTestEvent("worker-thread");
    const capture: *TestCapture = @ptrCast(@alignCast(ctx.?));
    if (capture.worker_error) |err| return err;
}

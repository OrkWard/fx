const std = @import("std");
const std_builtin = @import("builtin");
const command_admission = @import("../permissions/command_admission.zig");
const agent_runtime = @import("../agent/agent_runtime.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const app_lifecycle = @import("../app/app_lifecycle.zig");
const shared_theme = @import("../shared/theme.zig");
const ui_render = @import("../../ui/render.zig");
const app_runtime_setup = @import("../app/app_runtime_setup.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const secret = @import("../auth/secret.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const context_contract = @import("../workspace/context_contract.zig");
const workspace_diagnostics = @import("../workspace/diagnostics.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_set = @import("../gateway/provider_set.zig");
const process_provider = @import("../execution/process_provider.zig");
const host = @import("../hosts/host.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("../tooling/file_mutation.zig");
const gateway_error_format = @import("../shared/gateway_error_format.zig");
const image_attachments = @import("../images/image_attachments.zig");
const hooks = @import("../hooks/hooks.zig");
const notification_sound = @import("../notifications/sound.zig");
const io_mod = @import("../shared/io.zig");
const shell_snapshot = @import("../terminal/shell_snapshot.zig");
const session_title_generation = @import("../session/session_title_generation.zig");
const compactor = @import("../compactor/compactor.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const permission_request = @import("../permissions/permission_request.zig");
const permissions = @import("../permissions/permissions.zig");
const session_runtime = @import("../session/session.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const session_codec = @import("../session/session_codec.zig");
const session_usage = @import("../session/session_usage.zig");
const session_store = @import("../session/session_store.zig");
const session_child_store = @import("../session/session_child_store.zig");
const legacy_background_migration = @import("../session/legacy_background_migration.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const subagent_agent_adapter = @import("../subagent/agent_adapter.zig");
const subagent_authority = @import("../subagent/authority.zig");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_execution = @import("../subagent/execution.zig");
const subagent_resume_admission = @import("../subagent/resume_admission.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const text_utils = @import("../shared/text_utils.zig");
const builtin_tools = @import("../../builtins/tools.zig");
const tool_projection_mod = @import("../tooling/tool_projection.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const web_fetch_runtime = @import("../tooling/web_fetch_runtime.zig");
const types = @import("../shared/types.zig");
const history_range = @import("../shared/history_range.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const ask_presentation = @import("../../ui/ask_presentation.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const ImageAttachment = types.ImageAttachment;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const SessionRuntime = session_runtime.SessionRuntime;
const ToolCall = types.ToolCall;
const ToolExecutionResult = agent_runtime.ToolExecutionResult;
const WorkerEvent = worker_runtime.WorkerEvent;
const WorkerRuntime = worker_runtime.WorkerRuntime;

const ShellAction = enum {
    run,
    interact,
    stop,
};

const supports_headless_interrupt = switch (std_builtin.target.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => true,
};

const HeadlessInterruptInstallError = error{HeadlessInterruptBusy};
const headless_interrupt_exit_code: u8 = 130;
const headless_termination_exit_code: u8 = 143;

const headless_interrupt = if (supports_headless_interrupt) struct {
    var coordinator_mutex: std.Io.Mutex = .init;
    var coordinator_active = false;
    var cancel_requested = std.atomic.Value(bool).init(false);
    var requested_signal = std.atomic.Value(u8).init(0);
    var test_after_reset_before_install: if (std_builtin.is_test) ?*const fn () void else void =
        if (std_builtin.is_test) null else {};
    var test_after_restore: if (std_builtin.is_test) ?*const fn () void else void =
        if (std_builtin.is_test) null else {};

    fn handle(signal: std.posix.SIG) callconv(.c) void {
        _ = requested_signal.cmpxchgStrong(
            0,
            @intCast(@backingInt(signal)),
            .seq_cst,
            .seq_cst,
        );
        cancel_requested.store(true, .seq_cst);
    }

    fn exitCode() u8 {
        return switch (@as(std.posix.SIG, @fromBackingInt(@intCast(requested_signal.load(.seq_cst))))) {
            std.posix.SIG.TERM => headless_termination_exit_code,
            else => headless_interrupt_exit_code,
        };
    }

    const Scope = struct {
        old_sigint_action: std.posix.Sigaction = undefined,
        old_sigterm_action: std.posix.Sigaction = undefined,
        installed: bool = false,

        fn install(enabled: bool) HeadlessInterruptInstallError!Scope {
            if (!enabled) return .{};
            coordinator_mutex.lockUncancelable(io_mod.getIo());
            defer coordinator_mutex.unlock(io_mod.getIo());
            if (coordinator_active) return error.HeadlessInterruptBusy;

            const action: std.posix.Sigaction = .{
                .handler = .{ .handler = handle },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            var scope = Scope{};
            requested_signal.store(0, .seq_cst);
            cancel_requested.store(false, .seq_cst);
            if (std_builtin.is_test) {
                if (test_after_reset_before_install) |hook| hook();
            }
            std.posix.sigaction(std.posix.SIG.INT, &action, &scope.old_sigint_action);
            std.posix.sigaction(std.posix.SIG.TERM, &action, &scope.old_sigterm_action);
            coordinator_active = true;
            scope.installed = true;
            return scope;
        }

        fn restore(self: *Scope, redeliver: bool) void {
            if (!self.installed) return;
            coordinator_mutex.lockUncancelable(io_mod.getIo());
            defer coordinator_mutex.unlock(io_mod.getIo());
            std.debug.assert(coordinator_active);
            std.posix.sigaction(std.posix.SIG.INT, &self.old_sigint_action, null);
            std.posix.sigaction(std.posix.SIG.TERM, &self.old_sigterm_action, null);
            if (std_builtin.is_test) {
                if (test_after_restore) |hook| hook();
            }
            if (redeliver and cancel_requested.load(.seq_cst)) {
                const signal: std.posix.SIG = @fromBackingInt(@intCast(requested_signal.load(.seq_cst)));
                _ = std.c.raise(signal);
            }
            coordinator_active = false;
            self.installed = false;
        }

        fn deinit(self: *Scope) void {
            self.restore(false);
        }

        fn restoreAndRedeliver(self: *Scope) void {
            self.restore(true);
        }

        fn requested(self: *const Scope) bool {
            return self.installed and cancel_requested.load(.seq_cst);
        }
    };
} else struct {
    fn exitCode() u8 {
        return headless_interrupt_exit_code;
    }

    const Scope = struct {
        fn install(_: bool) HeadlessInterruptInstallError!Scope {
            return .{};
        }

        fn deinit(_: *Scope) void {}

        fn restoreAndRedeliver(_: *Scope) void {}

        fn requested(_: *const Scope) bool {
            return false;
        }
    };
};

pub const Config = struct {
    auth_mode: credentials.AuthMode = .local,
    command_usage: []const u8,
    default_model: []const u8,
    default_agent_step_limit: usize,
    oauth_transport: oauth_transport.Provider,
    provider_set: provider_set.Set,
    process_provider: process_provider.Provider = process_provider.unavailable_provider,
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
    mode_registry: mode_registry.Registry,
    context_limit_overrides: []const config_runtime.context_limits.Override = &.{},
    additional_directories: []const []const u8 = &.{},
    saved_directories_suppressed: bool = false,
};

fn runAskChild(
    raw: ?*anyopaque,
    turn: *subagent_execution.TurnContext,
    message: subagent_domain.QueuedMessage,
    admission: subagent_domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) subagent_execution.ServiceError!subagent_execution.RunOutcome {
    const ctx: *AskContext = @ptrCast(@alignCast(raw.?));
    var child_projection = ctx.cfg.mode_registry.buildModelToolProjection(
        ctx.alloc,
        ctx.deps.tool_set,
        ctx.mode_id,
        .{
            .permission_mode = admission.permission_mode,
            .permission_rules = admission.rules,
            .subagent_available = true,
        },
    ) catch return error.OutOfMemory;
    defer child_projection.deinit(ctx.alloc);
    return subagent_agent_adapter.run(.{
        .host = ctx.subagent_host orelse return error.ProviderFailed,
        .tool_context = ctx.toolContext(),
        .provider_set = ctx.cfg.provider_set,
        .system_prompt = ctx.cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = ctx.cfg.prompt_policy.modelPromptOverlay(admission.model),
        .skill_catalog = .{ .skills = ctx.loaded_skills.skills, .diagnostics = ctx.loaded_skills.diagnostics },
        .advertised_tool_names = child_projection.advertised_names,
        .advertised_functions = child_projection.advertised_functions,
        .custom_tool_guidance = child_projection.custom_guidance,
        .context_registry = ctx.deps.context_registry,
        .context_enabled = ctx.context_enabled,
        .project_context = ctx.modelVisibleProjectContext(),
        .lifecycle_view = ctx.lifecycle_view,
    }, turn, message, admission, cancel);
}

pub const PromptRunResult = struct {
    exit_code: u8,
    assistant_output: []u8,
    final_output: []u8 = &.{},
    /// Owned raw text of the completed final response as saved to history,
    /// with its Markdown intact; empty when absent. Unlike `final_output`, it
    /// never includes display-only text.
    final_source: []u8 = &.{},
    interrupted: bool = false,
    model: []u8 = &.{},
    session_id: []u8 = &.{},
    tool_calls: []ToolCallRecord = &.{},
    step_count: usize = 0,
    /// Owned slug of the provider that served the last gateway request;
    /// empty when the provider did not report routing metadata.
    resolved_provider: []u8 = &.{},
    error_code: ?[]const u8 = null,
    auth_failure: ?auth_runtime.FailureSnapshot = null,
    recovery: ?types.RouteRecoveryStatus = null,
    recovery_durable: bool = false,
    usage: types.Usage = .{},

    pub fn deinit(self: PromptRunResult, alloc: Allocator) void {
        alloc.free(self.assistant_output);
        if (self.final_output.len > 0) alloc.free(self.final_output);
        if (self.final_source.len > 0) alloc.free(self.final_source);
        if (self.model.len > 0) alloc.free(self.model);
        if (self.resolved_provider.len > 0) alloc.free(self.resolved_provider);
        if (self.session_id.len > 0) alloc.free(self.session_id);
        freeToolCallRecords(alloc, self.tool_calls);
    }
};

inline fn failPromptRunResult(err: anytype) @TypeOf(err)!PromptRunResult {
    return @errorCast(failPromptRunResultDynamic(err));
}

noinline fn failPromptRunResultDynamic(err: anyerror) anyerror!PromptRunResult {
    return err;
}

/// Resume selector parsed from fx ask --resume.
const ResumeTarget = session_store.ResumeTarget;

const AskOptions = struct {
    prompt: []u8,
    resume_target: ?ResumeTarget = null,
    permission_override: ?PermissionMode = null,
    model_override: ?[]u8 = null,
    effort_override: ?types.ReasoningEffort = null,
    fast_override: ?bool = null,
    ultrafast_override: ?bool = null,
    provider_order_override: ?[][]const u8 = null,
    provider_strict_override: ?bool = null,
    image_paths: std.ArrayList([]u8) = .empty,
    images: std.ArrayList(ImageAttachment) = .empty,
    system_prompt_override: ?[]u8 = null,
    json_output: bool = false,
    prompt_permissions: bool = false,
    timeout_ms: ?usize = null,
    quiet: bool = false,
    verbose: bool = false,
    no_save: bool = false,
    no_color: bool = false,
    continue_recovery: bool = false,

    fn deinit(self: *AskOptions, alloc: Allocator) void {
        alloc.free(self.prompt);
        for (self.image_paths.items) |p| alloc.free(p);
        self.image_paths.deinit(alloc);
        for (self.images.items) |image| types.freeImageAttachment(alloc, image);
        self.images.deinit(alloc);
        if (self.system_prompt_override) |s| alloc.free(s);
        if (self.model_override) |m| alloc.free(m);
        if (self.provider_order_override) |order| {
            for (order) |slug| alloc.free(@constCast(slug));
            if (order.len > 0) alloc.free(order);
        }
    }
};

const ToolCallRecord = struct {
    name: []u8,
    status: []u8,
    action: ?ShellAction = null,
    error_category: ?workspace_diagnostics.ToolCallOutcome = null,
    error_code: ?[]u8 = null,
    command_result_json: ?[]u8 = null,
    ask_question_text: ?[]u8 = null,
    web_search_completion: ?types.WebSearchCompletion = null,
    web_fetch_completion: ?types.WebFetchCompletion = null,
};

const PendingToolProgress = struct {
    call_id: []u8,
    tool_name: []u8,
    text: ?[]u8 = null,
    visible: bool = false,

    fn deinit(self: PendingToolProgress, alloc: Allocator) void {
        alloc.free(self.call_id);
        alloc.free(self.tool_name);
        if (self.text) |text| alloc.free(text);
    }
};

fn freeToolCallRecord(alloc: Allocator, record: ToolCallRecord) void {
    alloc.free(record.name);
    alloc.free(record.status);
    if (record.error_code) |code| alloc.free(code);
    if (record.command_result_json) |json| alloc.free(json);
    if (record.ask_question_text) |text| alloc.free(text);
}

fn freeToolCallRecords(alloc: Allocator, records: []ToolCallRecord) void {
    for (records) |record| freeToolCallRecord(alloc, record);
    if (records.len > 0) alloc.free(records);
}

const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;
const PermissionApprovalPromptResult = enum {
    approve,
    deny,
    unavailable,
};
const NotifyAttentionFn = *const fn (?*anyopaque) void;
const PermissionApprovalPromptFn = *const fn (?*anyopaque, ?*anyopaque, WriteFn, []const u8, ?*anyopaque, NotifyAttentionFn) anyerror!PermissionApprovalPromptResult;
const IsTtyFn = *const fn (?*anyopaque) bool;
/// The final `?[]const u8` is the run's --model, which stands in for a provider without a saved model.
const LoadStartupStateFn = *const fn (Allocator, oauth_transport.Provider, []const u8, usize, ?[]const u8) anyerror!app_lifecycle.StartupState;
const LoadStartupStateWithAuthModeFn = *const fn (Allocator, oauth_transport.Provider, []const u8, usize, credentials.AuthMode, ?[]const u8) anyerror!app_lifecycle.StartupState;
const InitializeSessionStoresFn = *const fn (*AskContext) anyerror!void;
const LoadSkillsFn = *const fn (
    Allocator,
    []const u8,
    skill_contract.RootPolicy,
) app_runtime_setup.LoadSkillsError!app_runtime_setup.LoadedSkills;
const ProcessQueuedPromptFn = *const fn (*agent_runtime.Agent, *const agent_runtime.AgentRuntimeDeps, ?agent_runtime.SemanticPresentationSink, agent_runtime.LifecycleContext, agent_runtime.Config, worker_runtime.QueuedPrompt) anyerror!void;
const DiscardPristineSessionFn = *const fn (?*anyopaque, *AskContext, *session_store.LoadedWritableSession) session_store.PristineDiscardDisposition;
const PersistYoloAcknowledgmentFn = *const fn (Allocator) config_runtime.CommitAttempt;

const RunDeps = struct {
    stdin_ctx: ?*anyopaque = null,
    stdout_ctx: ?*anyopaque = null,
    stderr_ctx: ?*anyopaque = null,
    permission_approval_prompt_ctx: ?*anyopaque = null,
    write_stdout: WriteFn = writeRealStdout,
    write_stderr: WriteFn = writeRealStderr,
    permission_approval_prompt: PermissionApprovalPromptFn = promptRealPermissionApproval,
    stdin_is_tty: IsTtyFn = realStdinIsTty,
    stdout_is_tty: IsTtyFn = realStdoutIsTty,
    stderr_is_tty: IsTtyFn = realStderrIsTty,
    load_startup_state: LoadStartupStateFn = loadStartupStateDefault,
    load_startup_state_with_auth_mode: LoadStartupStateWithAuthModeFn = app_lifecycle.loadStartupStateForRun,
    initialize_session_stores: InitializeSessionStoresFn = initializeSessionStoresDefault,
    load_skills: LoadSkillsFn = app_runtime_setup.loadSkills,
    context_registry: context_contract.Registry,
    tool_set: tool_set_contract.ToolSet,
    process_queued_prompt: ProcessQueuedPromptFn = processQueuedPromptDefault,
    persist_yolo_acknowledgment: PersistYoloAcknowledgmentFn = persistYoloAcknowledgmentDefault,
    discard_pristine_session_ctx: ?*anyopaque = null,
    discard_pristine_session: DiscardPristineSessionFn = discardPristineSessionDefault,
    install_headless_interrupt: bool = false,
    stdin_source: StdinSource = .real,
};

const OutputMode = enum {
    quiet,
    json,
    raw,
    terminal,
    terminal_no_color,

    fn isTerminal(self: OutputMode) bool {
        return self == .terminal or self == .terminal_no_color;
    }

    fn capturesJson(self: OutputMode) bool {
        return self == .json;
    }
};

const RunOptions = struct {
    output_mode: OutputMode,
    prompt_permissions: bool = false,
    images: []const ImageAttachment = &.{},
    command_timeout_ms: ?usize = null,
    save_session: bool = true,
    resume_target: ?ResumeTarget = null,
    color_enabled: bool = true,
    continue_recovery: bool = false,
    model_override: ?[]const u8 = null,
    effort_override: ?types.ReasoningEffort = null,
    fast_override: ?bool = null,
    ultrafast_override: ?bool = null,
    provider_order_override: ?[]const []const u8 = null,
    provider_strict_override: ?bool = null,
    deps: RunDeps,
};

fn buildAskGatewayToolProjection(
    alloc: Allocator,
    registry: mode_registry.Registry,
    tool_set: tool_set_contract.ToolSet,
    mode_id: []const u8,
    options: tool_projection_mod.Options,
    has_child_capability: bool,
) !tool_projection_mod.EffectiveToolProjection {
    if (has_child_capability) {
        return registry.buildModelToolProjection(
            alloc,
            tool_set,
            mode_id,
            options,
        );
    }

    const shell_index = for (tool_set.registry.tools, 0..) |tool, index| {
        if (tool.executor_kind == .terminal and
            std.mem.eql(u8, tool.name, "shell"))
        {
            break index;
        }
    } else {
        return registry.buildModelToolProjection(
            alloc,
            tool_set,
            mode_id,
            options,
        );
    };

    const projected_tools = try alloc.dupe(
        tool_dispatch.Tool,
        tool_set.registry.tools,
    );
    defer alloc.free(projected_tools);
    projected_tools[shell_index] = builtin_tools.shellProcessOnlySpec();
    return registry.buildModelToolProjection(
        alloc,
        .{
            .registry = .{ .tools = projected_tools },
            .order = tool_set.order,
            .read_only_tool_names = tool_set.read_only_tool_names,
        },
        mode_id,
        options,
    );
}

const StdinSource = union(enum) {
    real,
    tty,
    bytes: []const u8,
    read_error,
};

const stdin_prompt_resource_byte_limit: usize = 8 * 1024 * 1024;

const AskContext = struct {
    alloc: Allocator,
    cfg: Config,
    deps: RunDeps,
    workspace_root: []const u8,
    workspace_access: workspace_access.WorkspaceAccess = .{},
    api_key: []const u8 = "",
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    refreshed_credential: ?credentials.Credential = null,
    provider: model_provider.ProviderId = .codex,
    model_catalog_access: credentials.CatalogAccess = .{ .public_only = .no_credential },
    model: []const u8 = "",
    /// Resolved review-model override borrowed from the startup state for the
    /// duration of the run. Empty keeps the reviewer's compiled default.
    reviewer_model: []const u8 = "",
    agent_step_limit: usize = 0,
    max_tool_result_bytes: usize = 64 * 1024,
    auto_compact_percent: u8 = compactor.default_percent,
    context_limits: config_runtime.context_limits.Values = .{},
    fast_mode: bool = false,
    /// Profile preference used only when creating a new durable session.
    /// Process and CLI overrides remain per-run and never rewrite this value.
    persisted_ultrafast_mode: bool = false,
    ultrafast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    /// Borrowed gateway provider routing for this run; startup state owns the
    /// backing memory.
    provider_order: []const []const u8 = &.{},
    provider_strict: bool = false,
    /// Owned slug of the provider that served the latest gateway request this
    /// run, reported by the gateway's routing metadata.
    resolved_provider: ?[]u8 = null,
    first_call_tool_choice: types.ToolChoice = .auto,
    permission_mode: PermissionMode = .ask,
    permission_rules: types.PermissionRuleSet = .{},
    mode_id: []const u8,
    auto_classifier: permission_auto_classifier.Classifier =
        permission_auto_classifier.Classifier.disabled(),
    worker: WorkerRuntime = .{},
    use_process_interrupt_flag: bool = false,
    terminal_client: terminal_client_runtime.Runtime = .{},
    managed_executions: managed_execution.Runtime,
    ephemeral_command_replay: command_replay_store.EphemeralStore,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    loaded_skills: app_runtime_setup.LoadedSkills = .{},
    store: ?session_store.Store = null,
    writable: ?session_store.LoadedWritableSession = null,
    session_write_mutex: std.Io.Mutex = .init,
    requested_resume: ?ResumeTarget = null,
    seed_model: []const u8 = "",
    command_timeout_ms: ?usize = null,
    session: SessionRuntime,
    skills_dir: []u8 = &.{},
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    context_enabled: bool = true,
    failed: bool = false,
    typed_error_code: ?[]const u8 = null,
    auth_failure: ?auth_runtime.FailureSnapshot = null,
    output_mode: OutputMode = .raw,
    prompt_permissions: bool = false,
    presenter: ?*ask_presentation.Runtime = null,
    pending_tool_progress: std.ArrayList(PendingToolProgress) = .empty,
    deferred_tool_progress: std.ArrayList([]u8) = .empty,
    pending_tool_progress_mutex: std.Io.Mutex = .init,
    raw_boundary_pending: bool = false,
    response_output_start: usize = 0,
    response_restart_pending: bool = false,
    raw_trailing_newlines: u8 = 0,
    raw_has_output: bool = false,
    command_output_line_open: bool = false,
    assistant_output: std.ArrayList(u8) = .empty,
    final_output: std.ArrayList(u8) = .empty,
    final_source: std.ArrayList(u8) = .empty,
    tool_call_records: std.ArrayList(ToolCallRecord) = .empty,
    tool_call_records_mutex: std.Io.Mutex = .init,
    web_search_progress_mutex: std.Io.Mutex = .init,
    step_count: usize = 0,
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    capability_resolver: gateway_provider.CapabilityResolver = .{},
    lifecycle_runtime: hooks.Runtime,
    lifecycle_view: hooks.RuntimeView,
    active_turn_id: u64 = 0,
    notification_player: ?notification_sound.Player = null,
    image_snapshot_temp_dir: ?[]u8 = null,
    prompt_snapshot_committed: bool = false,
    last_recovery_status: ?types.RouteRecoveryStatus = null,

    fn init(alloc: Allocator, cfg: Config, deps: RunDeps, workspace_root: []const u8) AskContext {
        const lifecycle_runtime = hooks.Runtime.init(alloc);
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .deps = deps,
            .workspace_root = workspace_root,
            .model = cfg.default_model,
            .seed_model = cfg.default_model,
            .mode_id = cfg.mode_registry.default_mode_id,
            .session = session_runtime.SessionRuntime.initWithProviders(
                cfg.max_history_turns,
                cfg.provider_set.deferredUsageProviders(),
            ),
            .terminal_client = terminal_client_runtime.Runtime.init(
                cfg.process_provider,
            ),
            .managed_executions = managed_execution.Runtime.init(alloc),
            .ephemeral_command_replay = command_replay_store.EphemeralStore.init(alloc),
            .lifecycle_runtime = lifecycle_runtime,
            .lifecycle_view = hooks.RuntimeView.empty(),
        };
    }

    fn configureNotifications(
        self: *AskContext,
        turn_end: bool,
        attention_required: bool,
    ) !void {
        self.notification_player = notification_sound.Player.init(.{
            .ctx = self,
            .emit = emitAskNotificationBell,
        });
        if (turn_end) {
            try self.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.sound.turn_end",
                .ctx = self,
                .run = postTurnEndNotification,
            });
        }
        if (attention_required) {
            try self.lifecycle_runtime.registerAttentionRequired(.{
                .name = "fx.sound.attention_required",
                .ctx = self,
                .run = attentionRequiredNotification,
            });
        }
        self.lifecycle_view = self.lifecycle_runtime.freeze();
    }

    fn dispatchAttentionRequired(self: *AskContext, kind: hooks.AttentionKind) void {
        agent_runtime.dispatchAttentionRequiredCheckpoint(self.lifecycleContext(), .{
            .turn_id = self.active_turn_id,
            .kind = kind,
        });
    }

    fn postTurnEndNotification(
        raw: *anyopaque,
        input: hooks.PostTurnEndInput,
    ) hooks.HandlerError!void {
        const self: *AskContext = @ptrCast(@alignCast(raw));
        if (input.invocation.scope.kind != .ask) return;
        const cue: notification_sound.Cue = switch (input.outcome) {
            .completed => .success,
            .failed => .@"error",
            .interrupted, .paused => return,
        };
        self.playNotification(.turn_end, cue);
    }

    fn attentionRequiredNotification(
        raw: *anyopaque,
        input: hooks.AttentionRequiredInput,
    ) hooks.HandlerError!void {
        const self: *AskContext = @ptrCast(@alignCast(raw));
        if (input.invocation.scope.kind != .ask) return;
        self.playNotification(.attention_required, .success);
    }

    fn playNotification(
        self: *AskContext,
        kind: notification_sound.Kind,
        cue: notification_sound.Cue,
    ) void {
        const player = if (self.notification_player) |*configured|
            configured
        else {
            debug_trace.logf(
                "notifications",
                "notification delivery dropped kind={s} reason=player_not_configured",
                .{@tagName(kind)},
            );
            return;
        };
        debug_trace.logf("notifications", "sound play kind={s} cue={s}", .{ @tagName(kind), @tagName(cue) });
        switch (kind) {
            .attention_required => player.playAttention(cue),
            .turn_end => player.play(cue),
        }
    }

    fn deinit(self: *AskContext) void {
        // Terminals end with this process. Ending them first also releases
        // any subagent still waiting on one.
        self.terminal_client.closeOwnedTerminals();
        if (self.subagent_host) |subagent_host| subagent_host.deinit();
        self.subagent_host = null;
        self.managed_executions.deinit();
        self.terminal_client.deinit();
        self.workspace_access.deinit(self.alloc);
        self.worker.deinit(std.heap.c_allocator);
        self.session.usage.finishReconciliationBeforeShutdown();
        self.session.usage.finishProfilePublicationsBeforeShutdown();
        self.session.usage.configurePublicationSink(null);
        self.session.usage.configureCheckpointSink(null);
        if (self.writable) |*writable| {
            if (self.session.usage.isDirty()) {
                flushAskSessionUsage(self, writable) catch |err| {
                    debug_trace.logf(
                        "session",
                        "failed to flush ask session usage err={s}",
                        .{@errorName(err)},
                    );
                };
            }
        }
        self.web_fetch_runtime.deinit(self.alloc);
        if (self.refreshed_credential) |*credential| credential.deinit(self.alloc);
        self.capability_resolver.deinit(self.alloc);
        self.lifecycle_runtime.deinit();
        if (self.writable) |*writable| writable.deinit(self.alloc);
        self.writable = null;
        if (self.store) |*store| store.deinit(self.alloc);
        self.ephemeral_command_replay.deinit();
        self.permission_rules.deinit(self.alloc);
        self.session.deinit(self.alloc);
        if (self.skills_dir.len > 0) self.alloc.free(self.skills_dir);
        self.context_snapshot.deinit(self.alloc);
        if (self.image_snapshot_temp_dir) |path| {
            image_attachments.cleanupSnapshotDir(path);
            self.alloc.free(path);
        }
        self.assistant_output.deinit(self.alloc);
        self.final_output.deinit(self.alloc);
        self.final_source.deinit(self.alloc);
        for (self.pending_tool_progress.items) |progress| progress.deinit(self.alloc);
        self.pending_tool_progress.deinit(self.alloc);
        for (self.deferred_tool_progress.items) |progress| self.alloc.free(progress);
        self.deferred_tool_progress.deinit(self.alloc);
        for (self.tool_call_records.items) |record| {
            freeToolCallRecord(self.alloc, record);
        }
        self.tool_call_records.deinit(self.alloc);
        if (self.resolved_provider) |provider| self.alloc.free(provider);
        self.loaded_skills.deinit(self.alloc);
    }

    fn lifecycleContext(self: *AskContext) agent_runtime.LifecycleContext {
        return .{
            .view = self.lifecycle_view,
            .scope = .{
                .kind = .ask,
                .workspace_root = self.workspace_root,
                .session_id = self.activeSessionId(),
            },
            .outcome_allocator = self.alloc,
        };
    }

    fn cancelFlag(self: *AskContext) *std.atomic.Value(bool) {
        if (comptime supports_headless_interrupt) {
            if (self.use_process_interrupt_flag) {
                return &headless_interrupt.cancel_requested;
            }
        }
        return &self.worker.worker_cancel_requested;
    }

    fn checkCancellation(self: *AskContext) !void {
        if (self.cancelFlag().load(.seq_cst)) return error.Cancelled;
    }

    fn processInterruptRequested(self: *const AskContext) bool {
        if (comptime supports_headless_interrupt) {
            return self.use_process_interrupt_flag and
                headless_interrupt.cancel_requested.load(.seq_cst);
        }
        return false;
    }

    /// The saved session's id, from whichever backend holds it.
    fn activeSessionId(self: *const AskContext) ?[]const u8 {
        return if (self.writable) |*writable| writable.active_id else null;
    }

    /// The saved session's side-file capability, if any.
    fn sessionChildCapability(self: *AskContext) ?*session_child_store.SessionChildCapability {
        return if (self.writable) |*writable| writable.childCapability() catch null else null;
    }

    fn imageSnapshotStorageDir(self: *AskContext) ![]u8 {
        const sessions_dir = if (self.store) |*store| store.sessions_dir else null;
        const session_id = self.activeSessionId();
        return session_store.imageSnapshotStorageDir(
            self.alloc,
            sessions_dir,
            session_id,
            &self.image_snapshot_temp_dir,
        );
    }

    fn captureImageAttachment(self: *AskContext, attachment: *ImageAttachment) !void {
        const snapshot_dir = try self.imageSnapshotStorageDir();
        defer self.alloc.free(snapshot_dir);
        try image_attachments.captureImageSnapshotWithBudget(
            self.alloc,
            attachment,
            snapshot_dir,
            .{ .cancel_flag = self.cancelFlag() },
        );
    }

    fn captureImageAttachments(self: *AskContext, attachments: []ImageAttachment) !void {
        const snapshot_dir = try self.imageSnapshotStorageDir();
        defer self.alloc.free(snapshot_dir);
        try image_attachments.captureImageSnapshots(
            self.alloc,
            attachments,
            snapshot_dir,
            .{ .cancel_flag = self.cancelFlag() },
        );
    }

    /// Record whether restored history references shell execution handles this
    /// process does not own. Registry membership, not the resume itself,
    /// decides staleness (see session_runtime.detectStaleShellHandles).
    fn updateStaleShellHandles(self: *AskContext, history: []const session_runtime.HistoryTurn) void {
        self.session.has_stale_shell_handles = session_runtime.detectStaleShellHandles(
            self.alloc,
            history,
            &self.managed_executions,
        ) catch |err| blk: {
            debug_trace.logf(
                "session",
                "event=stale_shell_handle_scan outcome=skipped err={s}",
                .{@errorName(err)},
            );
            break :blk false;
        };
    }

    fn initializeSessionStores(self: *AskContext) !void {
        var store = session_store.Store.init(self.alloc, self.workspace_root) catch |err| {
            if (err == error.OutOfMemory or self.requested_resume != null) return err;
            debug_trace.logf(
                "session",
                "event=ask_session_store_unavailable error={s}",
                .{@errorName(err)},
            );
            try self.writeStderr("fx ask: warning: session persistence unavailable; error=");
            try self.writeStderr(@errorName(err));
            try self.writeStderr("; continuing without saving\n");
            return;
        };
        var store_owned = true;
        errdefer if (store_owned) store.deinit(self.alloc);

        const seed_preferences = session_codec.DurableSessionPreferences{
            .provider = self.provider,
            .model = @constCast(self.seed_model),
            .effort = self.effort,
            .fast_mode = self.fast_mode,
            .ultrafast_mode = self.persisted_ultrafast_mode,
        };
        var writable = if (self.requested_resume) |target|
            try subagent_resume_admission.resumeForExternalPrompt(
                store,
                self.alloc,
                target,
                self.workspace_root,
                .{ .seed_preferences = seed_preferences },
            )
        else blk: {
            var state = try freshAskState(self, seed_preferences);
            defer state.deinit(self.alloc);
            break :blk try store.startWritableSession(self.alloc, state);
        };
        var writable_owned = true;
        errdefer if (writable_owned) writable.deinit(self.alloc);

        if (self.requested_resume != null) {
            try self.session.restoreWithPermissionState(
                self.alloc,
                writable.state.conversation_language,
                writable.state.history,
                writable.state.permission_state,
            );
            updateStaleShellHandles(self, writable.state.history);
            writable.releaseHydrationHistory(self.alloc);
            if (writable.state.usage) |usage| {
                try self.session.usage.restore(
                    self.alloc,
                    usage,
                    writable.state.created_at_ms,
                );
            } else {
                self.session.usage.restoreLegacyWallDuration(
                    writable.state.created_at_ms,
                );
            }
        }

        const session_dir = try session_store.sessionDirPath(
            self.alloc,
            store.sessions_dir,
            writable.active_id,
        );
        defer self.alloc.free(session_dir);
        self.session.configureWebFetchArtifacts(self.alloc, session_dir);

        self.store = store;
        self.writable = writable;
        store_owned = false;
        writable_owned = false;

        if (self.requested_resume != null) {
            const preferences = self.writable.?.state.preferences;
            self.provider = preferences.provider;
            self.model = preferences.model;
            self.effort = preferences.effort;
            self.fast_mode = preferences.fast_mode;
            self.ultrafast_mode = preferences.ultrafast_mode;
        }
        self.subagent_host = subagent_tool_host.Runtime.create(
            self.alloc,
            &self.store.?,
            self.writable.?.active_id,
            .{ .context = self, .resolve_fn = resolveAskSubagentAuthority },
            .{ .context = self, .run_fn = runAskChild },
        ) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            debug_trace.logf(
                "subagent",
                "ask subagent host unavailable root_id={s} err={s}",
                .{ self.writable.?.active_id, @errorName(err) },
            );
            break :blk null;
        };
        const capability = try self.writable.?.childCapability();
        if (legacy_background_migration.migrate(
            self.alloc,
            capability,
            self.cfg.process_provider,
        )) |migrated| {
            if (migrated.records_removed != 0 or migrated.logs_removed != 0) {
                debug_trace.logf(
                    "session",
                    "legacy process migration committed session={s} records={d} logs={d} signaled={d} unavailable={d}",
                    .{
                        self.writable.?.active_id,
                        migrated.records_removed,
                        migrated.logs_removed,
                        migrated.processes_signaled,
                        migrated.identities_unavailable,
                    },
                );
            }
        } else |err| {
            debug_trace.logf(
                "session",
                "legacy process migration deferred session={s} err={s}",
                .{ self.writable.?.active_id, @errorName(err) },
            );
        }
    }

    fn toolContext(self: *AskContext) tool_runtime.Context {
        const provider_capabilities = self.cfg.provider_set.select(self.provider).capabilities;
        const tc: tool_runtime.Context = .{
            .workspace_root = self.workspace_root,
            .access_scope = self.workspace_access.scope(self.workspace_root),
            .ignored_list_entries = self.cfg.ignored_list_entries,
            .max_list_entries = self.cfg.max_list_entries,
            .max_read_file_bytes = self.cfg.max_read_file_bytes,
            .max_read_file_lines = self.cfg.max_read_file_lines,
            .max_read_file_line_len = self.cfg.max_read_file_line_len,
            .max_command_output_bytes = self.cfg.max_command_output_bytes,
            .max_tool_result_bytes = self.max_tool_result_bytes,
            .auto_compact_percent = self.auto_compact_percent,
            .api_key = self.api_key,
            .agent_stream_provider = self.agentStreamProvider(),
            .credential_source = self.credential_source,
            .account_id = self.account_id,
            .provider = self.provider,
            .provider_capabilities = provider_capabilities,
            .oauth_transport = self.cfg.oauth_transport,
            .model = self.model,
            .reviewer_model = self.reviewer_model,
            .agent_step_limit = self.agent_step_limit,
            .fast_mode = self.fast_mode,
            .ultrafast_mode = self.ultrafast_mode,
            .effort = self.effort,
            .first_call_tool_choice = self.first_call_tool_choice,
            .permission_mode = self.permission_mode,
            .permission_grants = &.{},
            .permission_rules = self.permission_rules,
            .tool_registry = self.toolRegistry(),
            .subagent_host = self.subagent_host,
            .subagent_caller_id = self.activeSessionId(),
            .auto_classifier = self.admissionAutoClassifier(),
            .worker = &self.worker,
            .cancel_flag = self.cancelFlag(),
            .session = &self.session,
            .session_allocator = self.alloc,
            .skills_dir = self.skills_dir,
            .context_limits = self.context_limits,
            .context_enabled = self.context_enabled,
            .context_registry = self.deps.context_registry,
            .output_chunk_ctx = @ptrCast(self),
            .on_output_chunk = onCommandOutputChunk,
            .session_child_capability = self.sessionChildCapability(),
            .ephemeral_command_replay = self.managed_executions.replayStore(),
            .terminal_client = &self.terminal_client,
            .managed_executions = &self.managed_executions,
            .command_timeout_ms = self.command_timeout_ms,
            .web_fetch_runtime = &self.web_fetch_runtime,
            .web_fetch_artifact_store = self.session.webFetchArtifactStore(),
            .web_fetch_artifact_error = self.session.webFetchArtifactError(),
            .web_fetch_progress_ctx = @ptrCast(self),
            .on_web_fetch_progress = onWebFetchProgress,
            .model_capability_resolver = .{
                .ctx = @ptrCast(self),
                .resolve_fn = resolveModelCapabilities,
            },
            .interactive = false,
            .lifecycle_view = self.lifecycle_view,
            .lifecycle_scope = self.lifecycleContext().scope,
        };
        return tc;
    }

    fn modelVisibleProjectContext(self: *const AskContext) []const u8 {
        if (!self.context_enabled) return "";
        return self.context_snapshot.modelVisibleBytes();
    }

    fn toolRegistry(self: *const AskContext) tool_dispatch.Registry {
        return self.deps.tool_set.registry;
    }

    fn admissionAutoClassifier(self: *AskContext) permission_auto_classifier.Classifier {
        if (self.auto_classifier.enabled()) return self.auto_classifier;
        const provider = self.cfg.provider_set.select(self.provider).permission_reviewer orelse
            return permission_auto_classifier.Classifier.disabled();
        return permission_auto_classifier.Classifier.withProvider(provider, .{
            .credential = self.api_key,
            .credential_source = self.credential_source,
            .account_id = self.account_id,
            .endpoint = "",
            .reviewer_model = self.reviewer_model,
            .cancel_flag = self.cancelFlag(),
            .usage = &self.session.usage,
            .usage_allocator = self.alloc,
        });
    }

    fn agentStreamProvider(self: *const AskContext) agent_stream_provider.Provider {
        return self.cfg.provider_set.select(self.provider).agent_stream_or_unavailable();
    }

    fn writeStdout(self: *AskContext, text: []const u8) !void {
        try self.deps.write_stdout(self.deps.stdout_ctx, text);
    }

    fn writeStderr(self: *AskContext, text: []const u8) !void {
        try self.deps.write_stderr(self.deps.stderr_ctx, text);
    }

    fn writeLine(self: *AskContext, text: []const u8) !void {
        try self.writeStderr(text);
        try self.writeStderr("\n");
    }
};

fn freshAskState(
    ctx: *AskContext,
    preferences: session_codec.DurableSessionPreferences,
) !session_codec.DurableSessionState {
    const now = io_mod.milliTimestamp();
    const id = try session_store.generateSessionId(ctx.alloc);
    errdefer ctx.alloc.free(id);
    const origin = try ctx.alloc.dupe(u8, ctx.workspace_root);
    errdefer ctx.alloc.free(origin);
    const workspace = try ctx.alloc.dupe(u8, ctx.workspace_root);
    errdefer ctx.alloc.free(workspace);
    const owned_preferences = try preferences.dupe(ctx.alloc);
    errdefer {
        var value = owned_preferences;
        value.deinit(ctx.alloc);
    }
    const history = try ctx.alloc.alloc(HistoryTurn, 0);
    errdefer ctx.alloc.free(history);
    const permission_state = try ctx.session.snapshotPermissionState(ctx.alloc);
    errdefer {
        var value = permission_state;
        value.deinit(ctx.alloc);
    }
    return .{
        .id = id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = now,
        .updated_at_ms = now,
        .conversation_language = ctx.session.languageSnapshot(),
        .preferences = owned_preferences,
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .permission_state = permission_state,
    };
}

pub fn run(alloc: Allocator, args: []const [:0]const u8, cfg: Config, context_registry: context_contract.Registry, tool_set: tool_set_contract.ToolSet) !u8 {
    return runWithDeps(alloc, args, cfg, .{
        .load_startup_state = loadStartupStateDefault,
        .context_registry = context_registry,
        .tool_set = tool_set,
        .install_headless_interrupt = true,
    });
}

fn selectOutputMode(quiet: bool, json: bool, stdout_is_tty: bool, no_color: bool) OutputMode {
    if (json) return .json;
    if (quiet) return .quiet;
    if (!stdout_is_tty) return .raw;
    return if (no_color) .terminal_no_color else .terminal;
}

fn checkHeadlessCancellation(deps: RunDeps) !void {
    if (comptime supports_headless_interrupt) {
        if (deps.install_headless_interrupt and
            headless_interrupt.cancel_requested.load(.seq_cst))
        {
            return error.Cancelled;
        }
    }
}

fn writeAskUsage(deps: RunDeps, usage: []const u8) !void {
    try deps.write_stderr(deps.stderr_ctx, "usage: fx ");
    try deps.write_stderr(deps.stderr_ctx, usage);
    try deps.write_stderr(deps.stderr_ctx, "\n");
}

fn askErrorNotice(err: anyerror) ?[]const u8 {
    if (auth_runtime.preparationFailureNotice(err)) |notice| return notice;
    if (config_runtime.modelNotSelectedMessage(err)) |message| return message;
    return switch (err) {
        error.ImagePreparationFailed => image_attachments.image_preparation_failed_notice,
        error.ModelImageCapabilityUnavailable => image_attachments.model_image_capability_unavailable_notice,
        else => null,
    };
}

fn runWithDeps(alloc: Allocator, args: []const [:0]const u8, cfg: Config, deps: RunDeps) !u8 {
    var interrupt_scope = try headless_interrupt.Scope.install(
        deps.install_headless_interrupt,
    );
    defer interrupt_scope.restoreAndRedeliver();

    var options = parseOptionsWithStdin(alloc, args, deps.stdin_source) catch |err| switch (err) {
        error.MissingPrompt => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err));
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: missing prompt\n");
            try writeAskUsage(deps, cfg.command_usage);
            return 1;
        },
        error.NoSaveResumeConflict => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, "InvalidAskArgs");
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: --no-save cannot be used with --resume or --resume-id\n");
            try writeAskUsage(deps, cfg.command_usage);
            return 1;
        },
        error.PromptResourceLimitExceeded => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err));
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: prompt exceeds the local input safety limit\n");
            return 1;
        },
        error.PromptInputReadFailed => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err));
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: failed to read prompt from stdin\n");
            return 1;
        },
        error.InvalidAskArgs => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err));
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try writeAskUsage(deps, cfg.command_usage);
            return 1;
        },
        error.InvalidPromptText => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err));
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: prompt must be valid UTF-8 and contain no NUL bytes\n");
            return 1;
        },
        else => return err,
    };
    defer options.deinit(alloc);

    if (interrupt_scope.requested()) return headless_interrupt.exitCode();
    if (options.image_paths.items.len > 0) {
        const workspace_root = try io_mod.realpathAlloc(alloc, ".");
        defer alloc.free(workspace_root);
        if (!try preflightAskImages(alloc, workspace_root, &options, deps)) return 1;
    }
    if (interrupt_scope.requested()) return headless_interrupt.exitCode();

    var effective_cfg = cfg;
    if (options.system_prompt_override) |sp| {
        effective_cfg.prompt_policy.system_prompt = sp;
    }

    const output_mode = selectOutputMode(
        options.quiet,
        options.json_output,
        deps.stdout_is_tty(deps.stdout_ctx),
        options.no_color,
    );
    const result = runPromptInternal(alloc, options.prompt, options.permission_override, effective_cfg, .{
        .output_mode = output_mode,
        .prompt_permissions = options.prompt_permissions,
        .images = if (options.images.items.len > 0) options.images.items else &.{},
        .command_timeout_ms = options.timeout_ms,
        .save_session = !options.no_save,
        .resume_target = options.resume_target,
        .color_enabled = !options.no_color,
        .continue_recovery = options.continue_recovery,
        .model_override = options.model_override,
        .effort_override = options.effort_override,
        .fast_override = options.fast_override,
        .ultrafast_override = options.ultrafast_override,
        .provider_order_override = options.provider_order_override,
        .provider_strict_override = options.provider_strict_override,
        .deps = deps,
    }) catch |err| {
        if (interrupt_scope.requested()) return headless_interrupt.exitCode();
        if (err == error.OutOfMemory) return err;
        if (err == error.OneOffSessionNotResumable and !options.json_output) {
            try deps.write_stderr(
                deps.stderr_ctx,
                "fx ask: subagent child sessions cannot be resumed directly; message the named agent from its parent session\n",
            );
            return 1;
        }
        if (!options.json_output) {
            const notice = askErrorNotice(err) orelse return err;
            try deps.write_stderr(deps.stderr_ctx, "fx ask: ");
            try deps.write_stderr(deps.stderr_ctx, notice);
            try deps.write_stderr(deps.stderr_ctx, "\n");
            return 1;
        }
        const json = try renderErrorJsonResult(alloc, @errorName(err));
        defer alloc.free(json);
        try deps.write_stdout(deps.stdout_ctx, json);
        return 1;
    };
    defer result.deinit(alloc);

    if (result.interrupted or interrupt_scope.requested()) {
        return headless_interrupt.exitCode();
    }

    if (options.json_output) {
        const json = try renderFinalJsonResult(alloc, result);
        defer alloc.free(json);
        if (interrupt_scope.requested()) return headless_interrupt.exitCode();
        try deps.write_stdout(deps.stdout_ctx, json);
    }

    return if (interrupt_scope.requested())
        headless_interrupt.exitCode()
    else
        result.exit_code;
}

fn preflightAskImages(
    alloc: Allocator,
    workspace_root: []const u8,
    options: *AskOptions,
    deps: RunDeps,
) !bool {
    for (options.image_paths.items) |image_path| {
        const attachment = image_attachments.loadUserImageAttachment(
            alloc,
            workspace_root,
            image_path,
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            const reason = switch (err) {
                error.FileNotFound => "image file not found",
                error.UnsupportedImageType => "unsupported image type",
                error.ImageTooLarge => image_attachments.image_too_large_notice,
                else => @errorName(err),
            };
            if (options.json_output) {
                const detail = try alloc.print("{s}: {s}", .{ @errorName(err), image_path });
                defer alloc.free(detail);
                const json = try renderErrorJsonResult(alloc, detail);
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
            } else {
                var message: std.Io.Writer.Allocating = .init(alloc);
                defer message.deinit();
                try message.writer.print("fx ask: failed to attach image \"{s}\": {s}\n", .{ image_path, reason });
                try deps.write_stderr(deps.stderr_ctx, message.written());
            }
            return false;
        };
        var attachment_owned = true;
        errdefer if (attachment_owned) types.freeImageAttachment(alloc, attachment);
        try options.images.append(alloc, attachment);
        attachment_owned = false;
    }
    return true;
}

pub fn runPrompt(alloc: Allocator, prompt: []const u8, auto_permission: bool, cfg: Config, context_registry: context_contract.Registry, tool_set: tool_set_contract.ToolSet) !u8 {
    const result = try runPromptInternal(alloc, prompt, if (auto_permission) .auto else null, cfg, .{
        .output_mode = .raw,
        .images = &.{},
        .deps = .{
            .context_registry = context_registry,
            .tool_set = tool_set,
        },
    });
    defer result.deinit(alloc);
    return result.exit_code;
}

pub fn runPromptCapture(alloc: Allocator, prompt: []const u8, auto_permission: bool, cfg: Config, context_registry: context_contract.Registry, tool_set: tool_set_contract.ToolSet) !PromptRunResult {
    return runPromptInternal(alloc, prompt, if (auto_permission) .auto else null, cfg, .{
        .output_mode = .json,
        .images = &.{},
        .deps = .{
            .context_registry = context_registry,
            .tool_set = tool_set,
        },
    });
}

fn missingCredentialResult(
    alloc: Allocator,
    options: RunOptions,
    provider: model_provider.ProviderId,
) !PromptRunResult {
    const status = auth_runtime.StatusSnapshot{
        .required_source = auth_runtime.requestedSource(provider),
    };
    const message = status.missingHelp(.cli).?;
    try options.deps.write_stderr(options.deps.stderr_ctx, "fx ask: ");
    try options.deps.write_stderr(options.deps.stderr_ctx, message);
    try options.deps.write_stderr(options.deps.stderr_ctx, "\n");
    return .{
        .exit_code = 1,
        .assistant_output = try alloc.dupe(u8, ""),
        .error_code = "MissingCredentials",
    };
}

fn runPromptInternal(alloc: Allocator, prompt: []const u8, permission_override: ?PermissionMode, initial_cfg: Config, options: RunOptions) !PromptRunResult {
    var cfg = initial_cfg;
    var owned_prompt = try alloc.dupe(u8, prompt);
    defer alloc.free(owned_prompt);

    try checkHeadlessCancellation(options.deps);
    var startup = if (cfg.auth_mode == .host_managed)
        try options.deps.load_startup_state_with_auth_mode(
            alloc,
            cfg.oauth_transport,
            cfg.default_model,
            cfg.default_agent_step_limit,
            cfg.auth_mode,
            options.model_override,
        )
    else
        try options.deps.load_startup_state(
            alloc,
            cfg.oauth_transport,
            cfg.default_model,
            cfg.default_agent_step_limit,
            options.model_override,
        );
    defer startup.deinit(alloc);
    applyAskThemeChoice(startup.theme);
    cfg.provider_set.definitions = startup.configured_providers.definitions;
    try checkHeadlessCancellation(options.deps);

    var permission_mode = toCorePermissionMode(startup.permission_mode);
    const mode_id: []const u8 = cfg.mode_registry.default_mode_id;
    if (permission_override) |explicit| permission_mode = explicit;

    if (permission_mode == .yolo and !startup.yolo_acknowledged) {
        try emitHeadlessYoloWarning(alloc, options);
    }

    for (startup.config_diagnostics) |diagnostic| {
        var notice_writer: std.Io.Writer.Allocating = .init(alloc);
        defer notice_writer.deinit();
        try notice_writer.writer.print(
            "fx ask: config {s}: {s}",
            .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
        );
        try config_runtime.writeDiagnosticMetadata(&notice_writer.writer, diagnostic);
        try notice_writer.writer.writeByte('\n');
        const notice = try notice_writer.toOwnedSlice();
        defer alloc.free(notice);
        try options.deps.write_stderr(options.deps.stderr_ctx, notice);
    }

    try app_lifecycle.applyWorkspaceLaunch(
        &startup,
        alloc,
        cfg.additional_directories,
        cfg.saved_directories_suppressed,
    );
    try checkHeadlessCancellation(options.deps);

    if (cfg.auth_mode == .local and
        !options.continue_recovery and options.resume_target == null and startup.credential == null)
    {
        if (startup.credential_load_failure) |failure| {
            if (auth_runtime.preparationError(auth_runtime.classifyCredentialFailure(failure.source, failure.err))) |err| return err;
        }
        return missingCredentialResult(alloc, options, startup.provider);
    }

    var owned_resumed_model: ?[]u8 = null;
    defer if (owned_resumed_model) |model| alloc.free(model);
    var ctx = AskContext.init(alloc, cfg, options.deps, startup.workspace_root);
    defer ctx.deinit();
    if (options.save_session) {
        _ = try ctx.session.initializeProfileUsage(alloc, io_mod.getenv("HOME"));
        ctx.session.attachProfileUsagePublisher(alloc);
    }
    ctx.use_process_interrupt_flag = options.deps.install_headless_interrupt;
    try ctx.checkCancellation();
    var presenter: ?ask_presentation.Runtime = null;
    defer if (presenter) |*value| value.deinit();
    var worker_events_drained = false;
    ctx.workspace_access = startup.takeWorkspaceAccess();
    ctx.output_mode = options.output_mode;
    ctx.prompt_permissions = options.prompt_permissions;
    ctx.command_timeout_ms = options.command_timeout_ms;
    ctx.model = startup.selected_model;
    ctx.provider = startup.provider;
    ctx.seed_model = startup.configured_model;
    ctx.requested_resume = options.resume_target;
    ctx.agent_step_limit = startup.agent_step_limit;
    ctx.max_tool_result_bytes = startup.max_tool_result_bytes;
    ctx.auto_compact_percent = startup.auto_compact_percent;
    ctx.context_limits = startup.context_limits;
    ctx.context_limits.applyCommandLine(cfg.context_limit_overrides);
    ctx.fast_mode = startup.fast_mode;
    ctx.persisted_ultrafast_mode = startup.configured_ultrafast_mode;
    ctx.ultrafast_mode = startup.ultrafast_mode;
    ctx.provider_order = startup.provider_order;
    ctx.provider_strict = startup.provider_strict;
    ctx.effort = toCoreReasoningEffort(startup.effort);
    ctx.first_call_tool_choice = startup.first_call_tool_choice;
    ctx.permission_mode = permission_mode;
    ctx.reviewer_model = startup.review_model;
    ctx.mode_id = mode_id;
    ctx.permission_rules = try takeCorePermissionRules(alloc, &startup);
    ctx.context_enabled = startup.context_enabled;
    if (options.output_mode.isTerminal()) {
        presenter = try ask_presentation.Runtime.init(alloc, .{
            .text = owned_prompt,
            .images = @constCast(options.images),
        }, options.output_mode == .terminal_no_color);
        ctx.presenter = &presenter.?;
    }
    try ctx.configureNotifications(
        startup.notification_turn_end,
        startup.notification_attention_required,
    );
    ctx.session.setConversationLanguageFromUserMessage(owned_prompt);
    if (options.save_session) {
        try ctx.checkCancellation();
        try options.deps.initialize_session_stores(&ctx);
        try ctx.checkCancellation();
        if (config_runtime.providerEnvOverride() != null) {
            ctx.provider = startup.provider;
            ctx.model = startup.selected_model;
        }
        if (startup.model_source == .process_override) {
            ctx.model = startup.selected_model;
        } else if (ctx.requested_resume != null) {
            owned_resumed_model = try alloc.dupe(u8, ctx.model);
            ctx.model = owned_resumed_model.?;
        }
        // Environment precedence survives resume without rewriting the saved
        // profile preference. CLI flags below remain the final per-run layer.
        if (startup.ultrafast_process_override) |ultrafast| ctx.ultrafast_mode = ultrafast;
        ctx.session.setConversationLanguageFromUserMessage(owned_prompt);
    }

    // Ask flags are per-run overrides: they win over startup and resumed
    // session preferences but are never persisted into session preferences.
    if (options.model_override) |model| {
        ctx.model = model;
    }
    if (options.effort_override) |effort| {
        ctx.effort = effort;
    }
    if (options.fast_override) |fast| {
        ctx.fast_mode = fast;
        if (fast) ctx.ultrafast_mode = false;
    } else if (options.model_override != null and ctx.requested_resume == null and
        startup.fast_mode_source == .compiled_default)
    {
        // Default fast mode applies to the compiled default model only; an
        // explicit model override drops it unless --fast restores it.
        ctx.fast_mode = false;
    }
    if (options.ultrafast_override) |ultrafast| {
        ctx.ultrafast_mode = ultrafast;
        if (ultrafast) ctx.fast_mode = false;
    } else if (options.model_override != null and ctx.requested_resume == null and
        startup.ultrafast_mode_source == .compiled_default)
    {
        // Ultra mode must never follow an explicit model override by default.
        ctx.ultrafast_mode = false;
    }
    if (options.provider_order_override) |order| {
        ctx.provider_order = order;
    }
    if (options.provider_strict_override) |strict| {
        ctx.provider_strict = strict;
    }

    var recovery_checkpoint: ?session_codec.RecoveryCheckpoint = null;
    defer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
    if (options.continue_recovery) {
        const writable = if (ctx.writable) |*value| value else return failPromptRunResult(error.RecoverySessionUnavailable);
        const checkpoint = writable.state.recovery_checkpoint orelse
            return failPromptRunResult(error.NoPendingRecovery);
        recovery_checkpoint = try checkpoint.dupe(alloc);
        alloc.free(owned_prompt);
        owned_prompt = try alloc.dupe(u8, recovery_checkpoint.?.user.text);
        ctx.session.setConversationLanguageFromUserMessage(owned_prompt);
    } else if (ctx.writable) |*writable| {
        if (writable.conversation_writer.turn_open) {
            const checkpoint = writable.state.recovery_checkpoint orelse
                return error.InvalidRecoveryCheckpoint;
            const prompt_snapshot_committed = ctx.prompt_snapshot_committed;
            defer ctx.prompt_snapshot_committed = prompt_snapshot_committed;
            try propagateHistoryTurn(&ctx, checkpoint.interruptedTurn());
        }
    }

    var routed_credential: ?credentials.Credential = null;
    defer if (routed_credential) |*credential| credential.deinit(alloc);
    if (cfg.auth_mode == .host_managed) {
        ctx.api_key = "";
        ctx.credential_source = .host_managed;
        ctx.account_id = null;
        ctx.model_catalog_access = .host_managed;
        {
            if (ctx.cfg.provider_set.select(ctx.provider).deferred_usage != null) {
                ctx.session.usage.replaceHostManagedReconciliationAuthority(
                    ctx.alloc,
                    ctx.provider,
                );
            }
        }
    } else {
        const startup_matches_final_model = if (startup.credential) |credential|
            startup.provider.same_authority(ctx.provider) and model_provider.authorizesCredential(ctx.provider, credential.source)
        else
            false;
        const startup_credential_is_final = startup_matches_final_model and
            !credentials.sourceRefreshable(startup.credential.?.source);
        const credential: *const credentials.Credential = if (startup_credential_is_final)
            &startup.credential.?
        else routed: {
            routed_credential = try auth_runtime.prepareCredential(alloc, cfg.oauth_transport, ctx.provider);
            if (routed_credential == null) {
                return missingCredentialResult(alloc, options, ctx.provider);
            }
            break :routed &routed_credential.?;
        };
        ctx.api_key = credential.token;
        ctx.credential_source = credential.source;
        ctx.account_id = credential.accountId();
        ctx.model_catalog_access = credentials.catalogAccessForCredentialAndAccount(
            credential.source,
            credential.token,
            credential.accountId(),
        );
        {
            if (ctx.cfg.provider_set.select(ctx.provider).deferred_usage != null) {
                ctx.session.usage.replaceProviderReconciliationCredential(
                    alloc,
                    ctx.provider,
                    credential.source,
                    credential.accountId(),
                    credential.token,
                );
            }
        }
    }

    const restored_image_catalog = try ctx.session.snapshotImageCatalog(alloc, &.{});
    defer types.freeImageAttachmentSlice(alloc, restored_image_catalog);
    const restored_image_bounds = try image_attachments.calculate_next_image_id(restored_image_catalog);

    const current_images = try types.dupeImageAttachmentSlice(
        alloc,
        if (recovery_checkpoint) |checkpoint|
            checkpoint.user.images
        else
            options.images,
    );
    defer types.freeImageAttachmentSlice(alloc, current_images);
    defer if (recovery_checkpoint == null and options.save_session and !ctx.prompt_snapshot_committed) {
        image_attachments.deleteUnreferencedImageSnapshots(current_images, restored_image_catalog);
    };
    if (recovery_checkpoint == null and current_images.len > 0) {
        try ctx.checkCancellation();
        _ = std.math.add(
            usize,
            restored_image_bounds.next_id,
            current_images.len - 1,
        ) catch return failPromptRunResult(error.ImageIdOverflow);
        for (current_images, 0..) |*image, index| image.id = restored_image_bounds.next_id + index;
        try ctx.captureImageAttachments(current_images);
        try ctx.checkCancellation();
    }

    const authorized_image_catalog = if (recovery_checkpoint) |checkpoint|
        try session_runtime.merge_image_catalog_history_turn(alloc, restored_image_catalog, checkpoint.interruptedTurn())
    else
        try ctx.session.snapshotImageCatalog(alloc, current_images);
    defer types.freeImageAttachmentSlice(alloc, authorized_image_catalog);

    try ctx.checkCancellation();
    ctx.loaded_skills = try options.deps.load_skills(
        alloc,
        startup.workspace_root,
        cfg.skill_root_policy,
    );
    const loaded_skills = &ctx.loaded_skills;
    try ctx.checkCancellation();
    skill_runtime.traceDiagnostics("ask_startup", loaded_skills.diagnostics);
    ctx.skills_dir = loaded_skills.dir;
    loaded_skills.dir = &.{};
    if (startup.context_enabled) {
        try ctx.checkCancellation();
        const context_targets = try context_contract.applicableTargetsForImages(alloc, current_images);
        defer if (context_targets.len > 0) alloc.free(context_targets);
        ctx.context_snapshot = try ctx.deps.context_registry.gatherDefaultSnapshot(alloc, .{
            .workspace_root = startup.workspace_root,
            .access_scope = ctx.workspace_access.scope(ctx.workspace_root),
            .targets = context_targets,
            .context_limits = ctx.context_limits,
        });
        try ctx.checkCancellation();
        for (ctx.context_snapshot.notices) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    }

    try ctx.checkCancellation();
    const session_child_capability = ctx.sessionChildCapability();
    var tool_projection = try buildAskGatewayToolProjection(alloc, ctx.cfg.mode_registry, options.deps.tool_set, ctx.mode_id, .{
        .permission_mode = ctx.permission_mode,
        .permission_rules = ctx.permission_rules,
        .subagent_available = ctx.subagent_host != null,
    }, session_child_capability != null);
    defer tool_projection.deinit(alloc);

    const context_history = try ctx.session.snapshotHistory(alloc);
    defer types.freeHistoryTurnSlice(alloc, context_history);
    const root_user_intent_context = try auto_classifier_context.buildCanonicalRootUserContext(
        alloc,
        owned_prompt,
        ctx.session.agent.history.items,
    );
    defer alloc.free(root_user_intent_context);
    ctx.active_turn_id = if (recovery_checkpoint) |checkpoint|
        checkpoint.turn_id
    else
        debug_trace.nextTurnId();

    const job: worker_runtime.QueuedPrompt = .{
        .turn_id = ctx.active_turn_id,
        .prompt = owned_prompt,
        .images = current_images,
        .authorized_image_catalog = authorized_image_catalog,
        .model = @constCast(ctx.model),
        .api_key = @constCast(ctx.api_key),
        .credential_source = ctx.credential_source,
        .account_id = if (ctx.account_id) |account_id| @constCast(account_id) else null,
        .provider = ctx.provider,
        .permission_mode = ctx.permission_mode,
        .history = context_history,
        .unversioned_history_count = ctx.session.unversionedHistoryEnd(),
        .root_user_intent_context = root_user_intent_context,
        .grants = &.{},
        // process_queued_prompt is synchronous here; AskContext keeps the
        // immutable snapshot allocations alive for the whole call.
        .context_snapshot = ctx.context_snapshot,
        .recovery_checkpoint = recovery_checkpoint,
    };

    const deps = agentRuntimeDeps(&ctx);
    const semantic_presentation = if (ctx.presenter) |value| value.semanticSink() else null;
    try ctx.checkCancellation();
    const title_task = maybeStartAskTitleTask(
        &ctx,
        startup.session_title_generation,
        owned_prompt,
        recovery_checkpoint == null and options.save_session and ctx.requested_resume == null,
    );
    defer if (title_task) |task| completeAskTitleTask(&ctx, task);
    const current_prompt_is_root_authority = if (ctx.writable) |writable|
        writable.external_prompt_origin == .persistent_child and
            recovery_checkpoint == null
    else
        false;
    options.deps.process_queued_prompt(&ctx.session.agent, &deps, semantic_presentation, ctx.lifecycleContext(), .{
        .system_prompt = cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = cfg.prompt_policy.modelPromptOverlay(ctx.model),
        .skill_catalog = .{ .skills = loaded_skills.skills, .diagnostics = loaded_skills.diagnostics },
        .advertised_tool_names = tool_projection.advertised_names,
        .advertised_functions = tool_projection.advertised_functions,
        .provider_capabilities = cfg.provider_set.select(ctx.provider).capabilities,
        .custom_tool_guidance = tool_projection.custom_guidance,
        .agent_step_limit = startup.agent_step_limit,
        .max_tool_result_bytes = startup.max_tool_result_bytes,
        .auto_compact_percent = startup.auto_compact_percent,
        .cancel_flag = ctx.cancelFlag(),
        .fast_mode = ctx.fast_mode,
        .ultrafast_mode = ctx.ultrafast_mode,
        .effort = ctx.effort,
        .first_call_tool_choice = ctx.first_call_tool_choice,
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.workspace_access.scope(ctx.workspace_root),
        .origin = if (ctx.writable) |writable|
            if (writable.external_prompt_origin == .persistent_child) .subagent else .root
        else
            .root,
        .root_user_messages = if (ctx.writable) |writable|
            writable.external_root_user_messages
        else
            &.{},
        .root_user_evidence_complete = if (ctx.writable) |writable|
            writable.external_root_user_evidence_complete
        else
            false,
        .current_prompt_is_root_authority = current_prompt_is_root_authority,
        .context_limits = ctx.context_limits,
        .session_child_capability = session_child_capability,
        .ephemeral_command_replay = if (session_child_capability == null)
            &ctx.ephemeral_command_replay
        else
            null,
    }, job) catch |err| switch (err) {
        error.NonInteractivePermissionRequired => {
            const assistant_output = try alloc.dupe(u8, ctx.assistant_output.items);
            errdefer alloc.free(assistant_output);
            const tool_calls = try takeToolCallRecords(&ctx, alloc);
            return .{
                .exit_code = 1,
                .assistant_output = assistant_output,
                .interrupted = ctx.processInterruptRequested(),
                .tool_calls = tool_calls,
                .error_code = "NonInteractivePermissionRequired",
                .usage = ctx.session.agent.turn_usage,
            };
        },
        else => {
            if (!options.output_mode.capturesJson()) return err;
            var failed_result = try takePromptRunResult(&ctx, alloc);
            failed_result.exit_code = 1;
            failed_result.error_code = @errorName(err);
            return failed_result;
        },
    };
    worker_events_drained = true;
    if (ctx.presenter) |value| try value.finish();

    var result = try takePromptRunResult(&ctx, alloc);
    finalizeFreshAuthSession(&ctx, &result);
    return result;
}

/// Starts background title generation for a fresh saved session. The task runs
/// concurrently with the first turn and is applied by `completeAskTitleTask`
/// on every exit path. The locally derived title remains when generation is
/// skipped or unavailable.
fn maybeStartAskTitleTask(
    ctx: *AskContext,
    setting_enabled: bool,
    prompt: []const u8,
    fresh_session: bool,
) ?*session_title_generation.Task {
    // Unit tests share the real provider bundles; never spawn network side
    // calls from a test process. Wiring is covered by e2e mock servers.
    if (comptime @import("builtin").is_test) return null;
    if (!setting_enabled or !fresh_session) return null;
    if (ctx.session.agent.history.items.len != 0) return null;
    const session_id = ctx.activeSessionId() orelse return null;
    const bundle = ctx.cfg.provider_set.select(ctx.provider);
    const title_model = bundle.title_model orelse return null;
    const agent_stream = bundle.agent_stream orelse return null;
    const excerpt = session_title_generation.promptExcerpt(prompt) orelse return null;
    if (ctx.credential_source != .host_managed and ctx.api_key.len == 0) return null;
    const task = session_title_generation.Task.create(.{
        .session_id = session_id,
        .model = title_model,
        .prompt_excerpt = excerpt,
        .api_key = if (ctx.api_key.len > 0) ctx.api_key else null,
        .account_id = ctx.account_id,
        .credential_source = ctx.credential_source,
        .stream_provider = agent_stream,
    }) catch return null;
    task.spawn() catch |err| {
        debug_trace.logf("session", "event=title_generation result=unavailable reason=spawn err={s}", .{@errorName(err)});
        task.destroy();
        return null;
    };
    return task;
}

/// Joins the bounded title task and installs the generated title unless the
/// session already carries a user-set title.
fn completeAskTitleTask(ctx: *AskContext, task: *session_title_generation.Task) void {
    defer task.destroy();
    task.join();
    const title = task.takeTitle() orelse return;
    defer std.heap.c_allocator.free(title);
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (ctx.writable) |*value| value else return;
    if (!std.mem.eql(u8, writable.active_id, task.session_id)) {
        debug_trace.logf("session", "event=title_generation_apply result=dropped reason=session_changed session={s}", .{task.session_id});
        return;
    }
    const installed = session_title_generation.installGeneratedTitle(ctx.alloc, writable, ctx.session.agent.history.items, title) catch |err| {
        debug_trace.logf("session", "event=title_generation_apply result=failed session={s} err={s}", .{ task.session_id, @errorName(err) });
        return;
    };
    if (installed) {
        debug_trace.logf("session", "event=title_generation_apply result=installed session={s}", .{task.session_id});
    }
}

/// Reports a pending shell snapshot fallback once, on stderr.
fn writeShellSnapshotNotice(ctx: *AskContext) void {
    var buffer: [shell_snapshot.max_notice_bytes]u8 = undefined;
    const notice = shell_snapshot.processOwner().takeUiNotice(&buffer) orelse return;
    ctx.writeStderr("fx ask: warning: ") catch return;
    ctx.writeStderr(notice) catch return;
    ctx.writeStderr("\n") catch return;
}

fn takePromptRunResult(ctx: *AskContext, alloc: Allocator) !PromptRunResult {
    writeShellSnapshotNotice(ctx);
    const assistant_output = try alloc.dupe(u8, ctx.assistant_output.items);
    errdefer alloc.free(assistant_output);
    const final_output: []u8 = if (ctx.final_output.items.len > 0)
        try alloc.dupe(u8, ctx.final_output.items)
    else
        @constCast(&.{});
    errdefer if (final_output.len > 0) alloc.free(final_output);
    const final_source: []u8 = if (ctx.final_source.items.len > 0)
        try alloc.dupe(u8, ctx.final_source.items)
    else
        @constCast(&.{});
    errdefer if (final_source.len > 0) alloc.free(final_source);
    const model = try alloc.dupe(u8, ctx.model);
    errdefer alloc.free(model);
    const resolved_provider: []u8 = if (ctx.resolved_provider) |provider|
        try alloc.dupe(u8, provider)
    else
        @constCast(&.{});
    errdefer if (resolved_provider.len > 0) alloc.free(resolved_provider);
    const session_id = if (ctx.writable) |writable|
        try alloc.dupe(u8, writable.active_id)
    else
        try alloc.dupe(u8, "");
    errdefer if (session_id.len > 0) alloc.free(session_id);

    const tool_calls = try takeToolCallRecords(ctx, alloc);

    return .{
        .exit_code = if (ctx.failed) 1 else 0,
        .assistant_output = assistant_output,
        .final_output = final_output,
        .final_source = final_source,
        .interrupted = ctx.processInterruptRequested(),
        .model = model,
        .resolved_provider = resolved_provider,
        .session_id = session_id,
        .tool_calls = tool_calls,
        .step_count = ctx.step_count,
        .error_code = ctx.typed_error_code,
        .auth_failure = ctx.auth_failure,
        .recovery = ctx.last_recovery_status,
        .recovery_durable = ctx.writable != null,
        .usage = ctx.session.agent.turn_usage,
    };
}

fn takeToolCallRecords(ctx: *AskContext, alloc: Allocator) ![]ToolCallRecord {
    ctx.tool_call_records_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.tool_call_records_mutex.unlock(io_mod.getIo());
    const owned = if (ctx.tool_call_records.items.len > 0)
        try alloc.dupe(ToolCallRecord, ctx.tool_call_records.items)
    else
        @as([]ToolCallRecord, &.{});
    if (owned.len > 0) ctx.tool_call_records.clearRetainingCapacity();
    return owned;
}

fn finalizeFreshAuthSession(ctx: *AskContext, result: *PromptRunResult) void {
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    if (result.auth_failure == null or
        ctx.requested_resume != null or
        ctx.session.historyLen() != 0 or
        result.step_count != 0 or
        ctx.store == null or
        ctx.writable == null)
    {
        return;
    }

    if (ctx.writable.?.state.recovery_checkpoint != null) {
        _ = ctx.writable.?.appendEvent(
            ctx.alloc,
            .{ .recovery_checkpoint_cleared = .{} },
            io_mod.milliTimestamp(),
        ) catch |err| {
            debug_trace.logf(
                "ask",
                "fresh auth session retained because recovery checkpoint clear failed err={s}",
                .{@errorName(err)},
            );
            return;
        };
    }

    ctx.session.clearWebFetchArtifacts();
    if (ctx.subagent_host) |subagent_host| subagent_host.deinit();
    ctx.subagent_host = null;

    var loaded = ctx.writable.?;
    ctx.writable = null;
    const disposition = ctx.deps.discard_pristine_session(
        ctx.deps.discard_pristine_session_ctx,
        ctx,
        &loaded,
    );
    if (disposition != .discarded) return;
    if (result.session_id.len > 0) ctx.alloc.free(result.session_id);
    result.session_id = &.{};
}

fn agentRuntimeDeps(ctx: *AskContext) agent_runtime.AgentRuntimeDeps {
    ctx.session.usage.configureCheckpointSink(
        if (ctx.writable != null)
            .{
                .context = @ptrCast(ctx),
                .allocator = ctx.alloc,
                .persist = persistUsageCheckpoint,
            }
        else
            null,
    );
    return .{
        .ctx = @ptrCast(ctx),
        .agent_stream_provider = ctx.agentStreamProvider(),
        .render_assistant_text = ctx.output_mode.isTerminal(),
        .tool_registry = ctx.toolRegistry(),
        .context_registry = ctx.deps.context_registry,
        .context_enabled = ctx.context_enabled,
        .finalize_turn = finalizeTurn,
        .release_agent_terminal_lease = releaseAgentTerminalLease,
        .append_runtime_context = appendRuntimeContext,
        .append_static_context = appendStaticContext,
        .validate_tool_call = validateToolCall,
        .prepare_skill_call = prepareSkillCall,
        .check_tool_availability = checkToolAvailability,
        .request_tool_permission = requestToolPermissionOutcomeWithRequest,
        .request_prepared_file_mutation_permission = requestPreparedFileMutationPermissionOutcomeForRuntime,
        .resolve_tool_action_display_target = resolveToolActionDisplayTarget,
        .describe_tool_action = describeToolAction,
        .describe_tool_action_completed = describeToolActionCompleted,
        .describe_tool_action_denied = describeToolActionDenied,
        .permission_target_for_call = permissionTargetForCall,
        .execute_tool_call = executeToolCallAuthorized,
        .publish_committed_file_handoff = publishCommittedFileHandoff,
        .propagate_history_turn = propagateHistoryTurn,
        .commit_context_compaction = .{ .commit = commitContextCompaction },
        .recovery_checkpoint = if (ctx.writable != null)
            .{
                .set = setRecoveryCheckpoint,
                .clear = clearRecoveryCheckpoint,
            }
        else
            null,
        .propagate_grant = propagateGrant,
        .push_event = pushEvent,
        .push_text = pushText,
        .push_tool_lifecycle = pushToolLifecycle,
        .push_diff_block = pushDiffBlock,
        .push_system_notice = pushSystemNotice,
        .push_context_notice = pushContextNotice,
        .push_route_recovery_status = pushRouteRecoveryStatus,
        .push_command_output_complete = pushCommandOutputComplete,
        .push_http_error = pushHttpError,
        .refresh_gateway_credential = refreshGatewayCredential,
        .available_model_capabilities = availableModelCapabilities,
        .resolve_model_capabilities = resolveModelCapabilities,
        .model_catalog_unavailable = modelCatalogUnavailable,
        .format_tool_execution_error = formatToolExecutionError,
        .record_tool_call_rejected = recordToolCallRejected,
        .record_tool_call_failed = recordToolCallFailed,
        .report_usage = reportUsage,
        .usage = &ctx.session.usage,
        .usage_allocator = ctx.alloc,
    };
}

fn modelCatalogUnavailable(raw_ctx: *anyopaque) bool {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return ctx.capability_resolver.state == .failed;
}

fn releaseAgentTerminalLease(raw_ctx: *anyopaque, session_id: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.release_agent_terminal_lease(ctx.toolContext(), session_id);
}

fn refreshGatewayCredential(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    source: credentials.Source,
    mode: auth_runtime.CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (mode == .if_needed and auth_runtime.requestPathCredentialVerifiedRecently(source)) {
        debug_trace.logf("auth", "credential refresh skipped source={t} reason=verified_recently", .{source});
        return null;
    }
    var refreshed = (try auth_runtime.refreshCredentialForAccount(
        ctx.cfg.oauth_transport,
        ctx.alloc,
        source,
        mode,
        expected_account_id,
    )) orelse return null;
    defer refreshed.deinit(ctx.alloc);
    return try adoptRefreshedAskCredential(ctx, alloc, &refreshed);
}

fn adoptRefreshedAskCredential(
    ctx: *AskContext,
    worker_alloc: Allocator,
    refreshed: *credentials.Credential,
) ![]u8 {
    if (ctx.credential_source != refreshed.source) return error.CredentialAuthorityChanged;
    if (!optionalCredentialFieldEqual(ctx.account_id, refreshed.accountId())) {
        return error.CredentialAuthorityChanged;
    }

    const worker_token = try worker_alloc.dupe(u8, refreshed.token);
    errdefer secret.zeroAndFree(worker_alloc, worker_token);
    if (ctx.refreshed_credential) |*current| current.deinit(ctx.alloc);
    ctx.refreshed_credential = refreshed.*;
    refreshed.token = &.{};
    refreshed.account_id = null;

    const current = &ctx.refreshed_credential.?;
    ctx.api_key = current.token;
    ctx.credential_source = current.source;
    ctx.account_id = current.accountId();
    ctx.model_catalog_access = credentials.catalogAccessForCredentialAndAccount(
        current.source,
        current.token,
        current.accountId(),
    );
    return worker_token;
}

fn optionalCredentialFieldEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn persistUsageCheckpoint(
    raw_ctx: *anyopaque,
    snapshot: session_usage.Snapshot,
) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (ctx.writable) |*value|
        value
    else
        return error.SessionPersistenceUnavailable;
    const store = ctx.store orelse return error.SessionPersistenceUnavailable;
    const recovery_checkpoint = try store.prepareUsageRecoveryCheckpoint(
        ctx.alloc,
        writable,
        snapshot,
    );
    _ = try writable.appendEvent(
        ctx.alloc,
        .{ .usage_checkpointed = .{ .usage = snapshot } },
        recovery_checkpoint.timestamp_ms,
    );
    try store.finishUsageRecoveryCheckpoint(
        writable.active_id,
        recovery_checkpoint,
    );
}

/// Overwrite session totals with the latest completion usage (same semantics as
/// interactive `agentReportUsage`). Gateway `input_tokens` is full-prompt
/// occupancy, not a delta, so overwrite rather than accumulate.
fn reportUsage(raw_ctx: *anyopaque, usage: types.Usage) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (ctx.writable) |*value| value else return;
    if (usage.input_tokens) |input| writable.state.total_input_tokens = input;
    if (usage.output_tokens) |output| writable.state.total_output_tokens = output;
}

fn resolveModelCapabilities(raw_ctx: *anyopaque, _: Allocator, model: []const u8) model_capabilities.ResolveError!model_capabilities.Capabilities {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const bundle = ctx.cfg.provider_set.select(ctx.provider);
    const catalog = bundle.model_catalog orelse return bundle.fallbackModelCapabilities(model);
    return ctx.capability_resolver.resolve(
        ctx.alloc,
        catalog,
        .{
            .access = ctx.model_catalog_access,
            .endpoint = "",
            .cancel_flag = ctx.cancelFlag(),
        },
        model,
        bundle.fallbackModelCapabilities(model),
    );
}

fn availableModelCapabilities(raw_ctx: *anyopaque, model: []const u8) model_capabilities.Capabilities {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return ctx.capability_resolver.available(
        model,
        ctx.cfg.provider_set.select(ctx.provider).fallbackModelCapabilities(model),
    );
}

fn finalizeTurn(raw_ctx: *anyopaque, turn_id: u64, outcome: types.TurnPresentationOutcome, disposition: ?types.ProviderCompletionDisposition) !void {
    std.debug.assert(turn_id != 0);
    _ = disposition;
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (outcome == .failed or outcome == .paused) {
        ctx.failed = true;
    }
    if (outcome == .completed) discard_restarted_json_preview(ctx);
}

fn appendRuntimeContext(raw_ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.deps.context_registry.appendDefaultTransient(.{
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.workspace_access.scope(ctx.workspace_root),
        .interactive = false,
        .permission_mode = ctx.permission_mode,
        .stale_shell_handles = ctx.session.has_stale_shell_handles,
    }, arena, messages);
}

fn appendStaticContext(raw_ctx: *anyopaque, arena: Allocator, project_context: ?[]const u8, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.deps.context_registry.appendDefaultStatic(.{
        .project_context = project_context orelse ctx.modelVisibleProjectContext(),
    }, arena, messages);
}

fn validateToolCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (try ctx.cfg.mode_registry.toolPolicyDeniedJson(arena, ctx.deps.tool_set, ctx.mode_id, call.name)) |reason| {
        return .{ .failure = reason };
    }
    return tool_runtime.validateToolCall(ctx.toolContext(), arena, call);
}

fn checkToolAvailability(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.checkToolAvailability(ctx.toolContext(), arena, call);
}

fn prepareSkillCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, locations: ?*const skill_contract.Locations) !skill_contract.CallPreparation {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.prepareSkillCall(ctx.toolContext(), arena, call, locations);
}

fn cliAdmissionContext(
    ctx: *AskContext,
    review_turn: ?permission_auto_classifier.ReviewTurnContext,
) tool_runtime.Context {
    var tool_ctx = ctx.toolContext();
    tool_ctx.permission_review_turn = review_turn;
    if (cliContextPermissionPromptAllowed(ctx)) {
        tool_ctx.permission_prompter = .{
            .context = @ptrCast(ctx),
            .request_fn = requestCliPermission,
        };
    }
    return tool_ctx;
}

fn requestPreparedFileMutationPermissionOutcomeForRuntime(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority) !command_admission.PermissionOutcome {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = cliAdmissionContext(ctx, review_turn);
    return finishCliPermissionOutcome(
        ctx,
        tool_ctx,
        arena,
        call,
        permission_mode,
        try tool_admission.requestPreparedFileMutationPermissionOutcome(
            tool_ctx.admissionInputWithLiveAuthority(live_authority),
            arena,
            call,
            prepared,
            permission_mode,
            local_grants,
        ),
    );
}

fn requestToolPermissionOutcomeWithRequest(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation) !command_admission.PermissionOutcome {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    var tool_ctx = cliAdmissionContext(ctx, review_turn);
    return finishCliPermissionOutcome(
        ctx,
        tool_ctx,
        arena,
        call,
        permission_mode,
        if (revalidation) |request| switch (request) {
            .action => |action| try tool_admission.revalidateLiveActionPermissionOutcome(
                tool_ctx.admissionInputWithLiveAuthority(live_authority),
                arena,
                call,
                permission_mode,
                local_grants,
                action.authority,
                action.human_approval,
            ),
        } else try tool_admission.requestPermissionOutcome(
            tool_ctx.admissionInputWithLiveAuthority(live_authority),
            arena,
            call,
            permission_mode,
            local_grants,
        ),
    );
}

inline fn failPermissionOutcome(err: anytype) @TypeOf(err)!command_admission.PermissionOutcome {
    return @errorCast(failPermissionOutcomeDynamic(err));
}

noinline fn failPermissionOutcomeDynamic(err: anyerror) anyerror!command_admission.PermissionOutcome {
    return err;
}

fn finishCliPermissionOutcome(
    ctx: *AskContext,
    tool_ctx: tool_runtime.Context,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    outcome: command_admission.PermissionOutcome,
) !command_admission.PermissionOutcome {
    if (outcome.decision != .permission_required) return outcome;
    const label = try tool_presentation.formatPlainAction(arena, .{
        .tool_registry = tool_ctx.tool_registry,
        .call = call,
        .workspace_root = tool_ctx.workspace_root,
    });
    switch (outcome.requirement orelse .approval_required) {
        .configured_rule => try writeBlockedActionGuidance(
            ctx,
            "fx ask: permission required by configured rule",
            label,
            "noninteractive_permission_prompt_unavailable",
            "fx ask: rerun in the interactive shell to approve this action, or add a narrow matching permission rule before retrying\n",
        ),
        .approval_required => try writeBlockedActionGuidance(
            ctx,
            "fx ask: permission required for tool execution in noninteractive mode",
            label,
            "noninteractive_permission_prompt_unavailable",
            if (permission_mode == .auto)
                "fx ask: human approval is required for this action; use the interactive shell to approve it, or add a narrow matching permission rule\n"
            else
                "fx ask: rerun with --auto to review this exact action automatically, or use the interactive shell to approve it\n",
        ),
    }
    try recordToolCallRejected(
        @ptrCast(ctx),
        arena,
        call,
        "Permission required",
        null,
    );
    return failPermissionOutcome(error.NonInteractivePermissionRequired);
}

fn writeBlockedActionGuidance(
    ctx: *AskContext,
    headline: []const u8,
    label: []const u8,
    reason: []const u8,
    hint: []const u8,
) !void {
    try ctx.writeLine(headline);
    try ctx.writeStderr("fx ask: blocked action: ");
    try ctx.writeStderr(label);
    try ctx.writeStderr("\nfx ask: reason=");
    try ctx.writeStderr(reason);
    try ctx.writeStderr("\n");
    try ctx.writeStderr(hint);
}

fn requestCliPermission(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    request: permission_request.PermissionRequest,
    _: ToolCall,
    _: ?*const diff_mod.FileReview,
    _: ?[]const PermissionGrant,
) anyerror!permission_request.OwnedPermissionResponse {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return switch (try promptCliPermissionApproval(ctx, request.label)) {
        .approve => permission_request.OwnedPermissionResponse.init(alloc, .once, null),
        .deny => permission_request.OwnedPermissionResponse.init(alloc, .deny, null),
        .unavailable => error.PermissionPromptUnavailable,
    };
}

fn promptCliPermissionApproval(
    ctx: *AskContext,
    label: []const u8,
) !PermissionApprovalPromptResult {
    if (!cliContextPermissionPromptAllowed(ctx)) return .unavailable;
    return try ctx.deps.permission_approval_prompt(
        ctx.deps.permission_approval_prompt_ctx,
        ctx.deps.stderr_ctx,
        ctx.deps.write_stderr,
        label,
        ctx,
        notifyAskPermissionAttention,
    );
}

fn notifyAskPermissionAttention(raw: ?*anyopaque) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw.?));
    ctx.dispatchAttentionRequired(.permission);
}

fn emitAskNotificationBell(raw: *anyopaque) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw));
    if (!ctx.deps.stderr_is_tty(ctx.deps.stderr_ctx)) return;
    ctx.writeStderr("\x07") catch |err| {
        debug_trace.logf(
            "notifications",
            "fx ask terminal bell write failed err={s}",
            .{@errorName(err)},
        );
    };
}

fn cliPermissionPromptAllowed(
    output_mode: OutputMode,
    prompt_permissions: bool,
    stdin_is_tty: bool,
) bool {
    return switch (output_mode) {
        .raw, .terminal, .terminal_no_color => true,
        .json, .quiet => prompt_permissions and stdin_is_tty,
    };
}

fn cliContextPermissionPromptAllowed(ctx: *const AskContext) bool {
    return cliPermissionPromptAllowed(
        ctx.output_mode,
        ctx.prompt_permissions,
        ctx.deps.stdin_is_tty(ctx.deps.stdin_ctx),
    );
}

fn describeToolAction(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8) ![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .workspace_root = ctx.workspace_root,
        .display_target = display_target,
    });
}

fn resolveToolActionDisplayTarget(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.resolveTerminalDisplayTarget(
        arena,
        ctx.toolRegistry(),
        ctx.workspace_root,
        &ctx.terminal_client,
        &ctx.managed_executions,
        call,
    );
}

fn describeToolActionCompleted(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8) ![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (try tool_presentation.formatSubagentPlainAction(arena, call, .completed)) |line| return line;
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .workspace_root = ctx.workspace_root,
        .display_target = display_target,
    });
}

fn describeToolActionDenied(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8) ![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (try tool_presentation.formatSubagentPlainAction(arena, call, .{ .stopped = label })) |line| return line;
    const action = try tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .workspace_root = ctx.workspace_root,
        .display_target = display_target,
    });
    return arena.print("{s}: {s}", .{ label, action });
}

fn permissionTargetForCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) ![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = ctx.toolContext();
    return tool_admission.permissionTargetForCall(tool_ctx.admissionInput(), arena, call);
}

fn executeToolCallAuthorized(
    raw_ctx: *anyopaque,
    request: agent_runtime.ToolExecutionRequest,
) !ToolExecutionResult {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    var tool_ctx = ctx.toolContext();
    tool_ctx.root_user_intent_context = request.root_user_intent_context;
    tool_ctx.root_user_messages = request.root_user_messages;
    tool_ctx.root_user_evidence_complete = request.root_user_evidence_complete;
    tool_ctx.session_grants = request.session_grants;
    tool_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    const result = tool_runtime.executeToolCallAuthorized(
        tool_ctx,
        request,
    ) catch |err| {
        captureToolExecutionError(ctx, request, err);
        return err;
    };
    captureToolExecutionResult(ctx, request, result);
    return result;
}

fn captureToolExecutionError(
    ctx: *AskContext,
    request: agent_runtime.ToolExecutionRequest,
    err: anyerror,
) void {
    if (ctx.output_mode.capturesJson()) {
        appendToolCallRecordBestEffort(
            ctx,
            request.call,
            "error",
            null,
            .runtime_failed,
            @errorName(err),
        );
    }
}

fn captureToolExecutionResult(
    ctx: *AskContext,
    request: agent_runtime.ToolExecutionRequest,
    result: ToolExecutionResult,
) void {
    if (ctx.output_mode.capturesJson()) {
        appendToolCallRecordBestEffort(
            ctx,
            request.call,
            if (result.status == .failure) "error" else "success",
            result,
            if (result.status == .failure)
                if (result.command_result_json != null) .command_failed else .tool_failed
            else
                null,
            null,
        );
    }
    if (result.status == .failure and result.finish_turn) {
        ctx.failed = true;
        ctx.typed_error_code = result.status_detail;
    }
}

fn publishCommittedFileHandoff(
    _: *anyopaque,
    _: file_mutation.CommittedFileHandoff,
) agent_runtime.SecondaryPublicationReport {
    return .{ .diff = .skipped, .tracker = .skipped };
}

fn recordToolCallRejected(
    raw_ctx: *anyopaque,
    _: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (!ctx.output_mode.capturesJson()) return;
    appendToolCallRecordBestEffort(
        ctx,
        call,
        "error",
        .{
            .status = .failure,
            .model_output = model_output,
            .command_result_json = command_result_json,
        },
        .rejected,
        "rejected",
    );
}

fn recordToolCallFailed(
    raw_ctx: *anyopaque,
    _: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (!ctx.output_mode.capturesJson()) return;
    appendToolCallRecordBestEffort(
        ctx,
        call,
        "error",
        .{
            .status = .failure,
            .model_output = model_output,
            .command_result_json = command_result_json,
        },
        .tool_failed,
        "tool_failed",
    );
}

fn appendToolCallRecordBestEffort(
    ctx: *AskContext,
    call: ToolCall,
    status: []const u8,
    result: ?ToolExecutionResult,
    error_category: ?workspace_diagnostics.ToolCallOutcome,
    error_code: ?[]const u8,
) void {
    appendToolCallRecord(
        ctx,
        call,
        status,
        result,
        error_category,
        error_code,
    ) catch |err| {
        debug_trace.logf(
            "cli_ask",
            "tool-call capture dropped name={s} status={s} err={s}",
            .{ call.name, status, @errorName(err) },
        );
    };
}

fn appendToolCallRecord(
    ctx: *AskContext,
    call: ToolCall,
    status: []const u8,
    result: ?ToolExecutionResult,
    error_category: ?workspace_diagnostics.ToolCallOutcome,
    explicit_error_code: ?[]const u8,
) !void {
    ctx.tool_call_records_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.tool_call_records_mutex.unlock(io_mod.getIo());

    const name = try ctx.alloc.dupe(u8, call.name);
    errdefer ctx.alloc.free(name);
    const owned_status = try ctx.alloc.dupe(u8, status);
    errdefer ctx.alloc.free(owned_status);
    var scratch_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const is_shell = std.mem.eql(u8, call.name, "shell");
    const action = if (is_shell and error_category != null)
        shell_action_for_call(scratch, call)
    else
        null;
    const error_code = if (is_shell and error_category != null)
        try ctx.alloc.dupe(
            u8,
            explicit_error_code orelse shell_failure_code(
                scratch,
                error_category.?,
                result,
            ),
        )
    else
        null;
    errdefer if (error_code) |code| ctx.alloc.free(code);
    const command_result_json = if (result) |execution|
        if (execution.command_result_json) |json|
            try ctx.alloc.dupe(u8, json)
        else
            null
    else
        null;
    errdefer if (command_result_json) |json| ctx.alloc.free(json);
    const ask_question_text = try questionTextForAskCall(ctx.alloc, call);
    errdefer if (ask_question_text) |text| ctx.alloc.free(text);

    try ctx.tool_call_records.append(ctx.alloc, .{
        .name = name,
        .status = owned_status,
        .action = action,
        .error_category = if (is_shell) error_category else null,
        .error_code = error_code,
        .command_result_json = command_result_json,
        .ask_question_text = ask_question_text,
        .web_search_completion = if (result) |execution| execution.web_search_completion else null,
        .web_fetch_completion = if (result) |execution| execution.web_fetch_completion else null,
    });
}

fn shell_action_for_call(arena: Allocator, call: ToolCall) ?ShellAction {
    if (!std.mem.eql(u8, call.name, "shell")) return null;
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        call.arguments_json,
        .{},
    ) catch return null;
    const root = switch (parsed) {
        .object => |object| object,
        else => return null,
    };
    const request = if (root.get("request")) |value| switch (value) {
        .object => |object| object,
        else => return null,
    } else root;
    const action = switch (request.get("action") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    return std.meta.stringToEnum(ShellAction, action);
}

fn shell_failure_code(
    arena: Allocator,
    category: workspace_diagnostics.ToolCallOutcome,
    result: ?ToolExecutionResult,
) []const u8 {
    return switch (category) {
        .succeeded => "tool_failed",
        .rejected => "rejected",
        .runtime_failed => "runtime_failed",
        .command_failed => command_failure_code(arena, result),
        .tool_failed => shell_tool_failure_code(arena, result),
    };
}

fn command_failure_code(
    arena: Allocator,
    result: ?ToolExecutionResult,
) []const u8 {
    const json = (result orelse return "command_failed").command_result_json orelse
        return "command_failed";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch
        return "command_failed";
    const object = switch (parsed) {
        .object => |value| value,
        else => return "command_failed",
    };
    if (json_bool(object, "termination_indeterminate")) return "termination_indeterminate";
    if (json_bool(object, "output_incomplete")) return "output_incomplete";
    if (json_bool(object, "timed_out")) return "timeout";
    if (json_has_value(object, "signal")) return "signal";
    if (json_nonzero_int(object, "exit_code")) return "nonzero_exit";
    return "command_failed";
}

fn shell_tool_failure_code(
    arena: Allocator,
    result: ?ToolExecutionResult,
) []const u8 {
    const body = (result orelse return "tool_failed").model_output;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return "tool_failed";
    const root = switch (parsed) {
        .object => |value| value,
        else => return "tool_failed",
    };
    const failure = switch (root.get("error") orelse return "tool_failed") {
        .object => |value| value,
        else => return "tool_failed",
    };
    const tool = switch (failure.get("tool") orelse return "tool_failed") {
        .string => |value| value,
        else => return "tool_failed",
    };
    if (!std.mem.eql(u8, tool, "shell")) return "tool_failed";
    const code = switch (failure.get("code") orelse return "tool_failed") {
        .string => |value| value,
        else => return "tool_failed",
    };
    if (!safe_error_code(code)) return "tool_failed";
    return code;
}

fn safe_error_code(code: []const u8) bool {
    if (code.len == 0 or code.len > 64) return false;
    for (code) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn json_bool(object: std.json.ObjectMap, name: []const u8) bool {
    return switch (object.get(name) orelse return false) {
        .bool => |value| value,
        else => false,
    };
}

fn json_has_value(object: std.json.ObjectMap, name: []const u8) bool {
    return switch (object.get(name) orelse return false) {
        .null => false,
        else => true,
    };
}

fn json_nonzero_int(object: std.json.ObjectMap, name: []const u8) bool {
    return switch (object.get(name) orelse return false) {
        .integer => |value| value != 0,
        else => false,
    };
}

fn questionTextForAskCall(alloc: Allocator, call: ToolCall) !?[]u8 {
    if (!std.mem.eql(u8, call.name, "ask_user_question")) return null;
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        call.arguments_json,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const questions_value = parsed.value.object.get("questions") orelse return null;
    if (questions_value != .array or questions_value.array.items.len == 0) return null;
    const first = questions_value.array.items[0];
    if (first != .object) return null;
    const question_value = first.object.get("question") orelse return null;
    if (question_value != .string) return null;
    const text = std.mem.trim(u8, question_value.string, " \t\r\n");
    if (text.len == 0) return null;
    const max_question_text_bytes: usize = 256;
    return try alloc.dupe(
        u8,
        text_utils.utf8PrefixByBytes(text, max_question_text_bytes),
    );
}

fn propagateHistoryTurn(raw_ctx: *anyopaque, turn: HistoryTurn) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    var prepared = try ctx.session.prepareHistoryEntry(ctx.alloc, turn);
    var prepared_owned = true;
    defer if (prepared_owned) types.freeHistoryTurn(ctx.alloc, prepared);
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (ctx.writable) |*value| value else {
        ctx.session.commitPreparedHistoryEntry(ctx.alloc, prepared);
        prepared_owned = false;
        return;
    };
    try writable.prepareHistoryTurnForCommit(ctx.alloc, &prepared);
    _ = writable.appendEvent(
        ctx.alloc,
        .{ .history_turn_committed = .{
            .conversation_language = ctx.session.languageSnapshot(),
            .total_input_tokens = writable.state.total_input_tokens,
            .total_output_tokens = writable.state.total_output_tokens,
            .turn = prepared,
        } },
        io_mod.milliTimestamp(),
    ) catch |err| {
        if (err == error.SessionPersistenceUncertain) ctx.prompt_snapshot_committed = true;
        return err;
    };
    ctx.session.commitPreparedHistoryEntry(ctx.alloc, prepared);
    prepared_owned = false;
    ctx.prompt_snapshot_committed = true;
}

fn commitContextCompaction(
    raw_ctx: *anyopaque,
    summary: types.CompactedSummaryHistoryTurn,
    active_prefix: ?types.AssistantHistoryTurn,
    retained_from: ?types.ContextHistoryCut,
) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const prepared = try session_runtime.prepareCompactedHistory(ctx.alloc, ctx.session.agent.history.items, summary, retained_from orelse .{ .turns = history_range.rawHistoryTurnCount(ctx.session.agent.history.items) });
    errdefer types.freeHistoryTurnSlice(ctx.alloc, prepared);
    if (ctx.writable) |*writable| {
        _ = writable.commitContextCompaction(ctx.alloc, summary, active_prefix, retained_from, io_mod.milliTimestamp()) catch |err| {
            if (err == error.SessionPersistenceUncertain and active_prefix != null) ctx.prompt_snapshot_committed = true;
            return err;
        };
        if (active_prefix != null) ctx.prompt_snapshot_committed = true;
    }
    ctx.session.commitCompactedHistory(ctx.alloc, prepared);
}

fn setRecoveryCheckpoint(
    raw_ctx: *anyopaque,
    checkpoint: session_codec.RecoveryCheckpoint,
) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    writeRecoveryCheckpoint(ctx, checkpoint) catch |err| {
        if (err == error.SessionPersistenceUncertain) ctx.prompt_snapshot_committed = true;
        return err;
    };
}

fn writeRecoveryCheckpoint(ctx: *AskContext, checkpoint: session_codec.RecoveryCheckpoint) !void {
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (ctx.writable) |*value| value else return error.SessionPersistenceUnavailable;
    const now_ms = io_mod.milliTimestamp();
    _ = try writable.appendEvent(
        ctx.alloc,
        .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } },
        now_ms,
    );
    ctx.prompt_snapshot_committed = true;
}

fn clearRecoveryCheckpoint(raw_ctx: *anyopaque) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (ctx.writable) |*value| value else return error.SessionPersistenceUnavailable;
    if (writable.state.recovery_checkpoint == null) return;
    _ = try writable.appendEvent(
        ctx.alloc,
        .{ .recovery_checkpoint_cleared = .{} },
        io_mod.milliTimestamp(),
    );
}

fn flushAskSessionUsage(
    ctx: *AskContext,
    writable: *session_store.LoadedWritableSession,
) !void {
    const now_ms = io_mod.milliTimestamp();
    var usage = try ctx.session.usage.snapshot(ctx.alloc);
    defer usage.deinit(ctx.alloc);
    _ = try writable.appendEvent(
        ctx.alloc,
        .{ .usage_checkpointed = .{ .usage = usage } },
        now_ms,
    );
    ctx.session.usage.markClean(usage);
}

fn propagateGrant(_: *anyopaque, _: []const u8, _: []const u8) !void {}

fn pushEvent(raw_ctx: *anyopaque, event: WorkerEvent) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    defer worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
    switch (event) {
        .clear_route_recovery_status => ctx.last_recovery_status = null,
        .provider_resolved => |slug| {
            if (ctx.resolved_provider) |old| ctx.alloc.free(old);
            ctx.resolved_provider = try ctx.alloc.dupe(u8, slug);
        },
        .finish_prompt => |finished| {
            ctx.final_output.clearRetainingCapacity();
            ctx.final_source.clearRetainingCapacity();
            if (finished.terminal_outcome == .completed) switch (finished.turn) {
                .assistant => |turn| {
                    const presentation = @import("../agent/runtime/assistant_stream.zig");
                    const text = finished.presentation_text orelse turn.assistant;
                    const normalized = try presentation.normalizeAssistantTextForDisplay(ctx.alloc, text);
                    defer ctx.alloc.free(normalized);
                    try ctx.final_output.appendSlice(ctx.alloc, presentation.textForCompletedPresentation(text, normalized));
                    try ctx.final_source.appendSlice(ctx.alloc, turn.assistant);
                },
                .compacted_summary, .interrupted => {},
            };
        },
        else => {},
    }
}

fn pushText(raw_ctx: *anyopaque, emission: agent_runtime.TextEmission) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    switch (emission) {
        .assistant_started => {
            discard_restarted_json_preview(ctx);
            ctx.response_output_start = ctx.assistant_output.items.len;
        },
        .assistant_restarted => |text| switch (ctx.output_mode) {
            .raw => try writeRawAssistantBytes(ctx, text),
            .json => {
                ctx.response_restart_pending = true;
                try ctx.writeStderr(text);
            },
            .quiet => try ctx.writeStderr(text),
            .terminal, .terminal_no_color => try ctx.presenter.?.pushText(text),
        },
        .assistant_source => |text| switch (ctx.output_mode) {
            .raw, .json => try pushRawAssistantText(ctx, text),
            .quiet, .terminal, .terminal_no_color => {},
        },
        .assistant_rendered => |text| switch (ctx.output_mode) {
            .terminal, .terminal_no_color => try ctx.presenter.?.pushText(text),
            .quiet, .json, .raw => {},
        },
        .operational => |text| switch (ctx.output_mode) {
            .terminal, .terminal_no_color => try ctx.presenter.?.pushText(text),
            .quiet, .json, .raw => try ctx.writeStderr(text),
        },
    }
}

fn discard_restarted_json_preview(ctx: *AskContext) void {
    if (!ctx.response_restart_pending) return;
    debug_trace.logf("agent", "discarding interrupted JSON preview bytes={d}", .{ctx.assistant_output.items.len - ctx.response_output_start});
    ctx.assistant_output.shrinkRetainingCapacity(ctx.response_output_start);
    ctx.response_restart_pending = false;
    ctx.raw_has_output = ctx.assistant_output.items.len > 0;
    ctx.raw_boundary_pending = ctx.raw_has_output;
    ctx.raw_trailing_newlines = if (std.mem.endsWith(u8, ctx.assistant_output.items, "\n\n"))
        2
    else if (std.mem.endsWith(u8, ctx.assistant_output.items, "\n"))
        1
    else
        0;
}

fn pushRawAssistantText(ctx: *AskContext, text: []const u8) !void {
    if (text.len == 0) return;
    if (ctx.raw_boundary_pending and ctx.raw_has_output) {
        const separator = if (ctx.raw_trailing_newlines >= 2)
            ""
        else if (ctx.raw_trailing_newlines == 1)
            "\n"
        else
            "\n\n";
        try writeRawAssistantBytes(ctx, separator);
    }
    ctx.raw_boundary_pending = false;
    try writeRawAssistantBytes(ctx, text);
}

fn writeRawAssistantBytes(ctx: *AskContext, text: []const u8) !void {
    if (ctx.output_mode == .json) try ctx.assistant_output.appendSlice(ctx.alloc, text);
    if (ctx.output_mode == .raw) try ctx.writeStdout(text);
    if (text.len == 0) return;
    ctx.raw_has_output = true;
    var trailing: usize = 0;
    while (trailing < text.len and text[text.len - trailing - 1] == '\n') : (trailing += 1) {}
    ctx.raw_trailing_newlines = if (trailing == text.len)
        @min(2, ctx.raw_trailing_newlines + @as(u8, @intCast(@min(trailing, 2))))
    else
        @intCast(@min(trailing, 2));
}

fn pushToolLifecycle(raw_ctx: *anyopaque, event: types.ToolLifecycleEvent) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal()) {
        try ctx.presenter.?.pushToolLifecycle(event);
    }
    switch (event) {
        .provisional => |provisional| if (!ctx.output_mode.isTerminal()) {
            if (provisional.tool_name) |tool_name| {
                try beginPendingToolProgress(ctx, provisional.id.call_id, tool_name);
            }
        },
        .authoritative_started => |started| {
            ctx.step_count += 1;
            if (!ctx.output_mode.isTerminal()) {
                try beginPendingToolProgress(ctx, started.id.call_id, started.tool_name);
            }
            if (ctx.raw_has_output) ctx.raw_boundary_pending = true;
        },
        .progress => |progress| if (!ctx.output_mode.isTerminal()) {
            try publishPendingToolProgress(ctx, progress.id.call_id, progress.text);
        },
        .turn_finished => if (!ctx.output_mode.isTerminal()) clearPendingToolProgress(ctx),
        .terminal => |value| {
            if (!ctx.output_mode.isTerminal()) {
                try settlePendingToolProgress(ctx, value.id.call_id, value.outcome);
            }
            // Report a fallback right after the command it affected; a later
            // recapture in the same run would otherwise clear it unseen.
            writeShellSnapshotNotice(ctx);
        },
    }
}

fn beginPendingToolProgress(ctx: *AskContext, call_id: []const u8, tool_name: []const u8) !void {
    ctx.pending_tool_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.pending_tool_progress_mutex.unlock(io_mod.getIo());
    discardPendingToolProgressLocked(ctx, call_id);

    const owned_id = try ctx.alloc.dupe(u8, call_id);
    errdefer ctx.alloc.free(owned_id);
    const owned_name = try ctx.alloc.dupe(u8, tool_name);
    errdefer ctx.alloc.free(owned_name);
    try ctx.pending_tool_progress.append(ctx.alloc, .{
        .call_id = owned_id,
        .tool_name = owned_name,
    });
}

fn publishPendingToolProgress(ctx: *AskContext, call_id: []const u8, text: []const u8) !void {
    ctx.pending_tool_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.pending_tool_progress_mutex.unlock(io_mod.getIo());

    const pending = findPendingToolProgressLocked(ctx, call_id) orelse return;
    const owned_text = try ctx.alloc.dupe(u8, text);
    if (pending.text) |previous| ctx.alloc.free(previous);
    pending.text = owned_text;
    pending.visible = false;
    if (ctx.toolRegistry().lookup(pending.tool_name)) |tool| {
        if (tool.executor_kind == .web_fetch) return;
    }
    if (consumeDeferredToolProgressLocked(ctx, text)) {
        pending.visible = true;
        return;
    }
    try ctx.writeStderr(text);
    try ctx.writeStderr("\n");
    pending.visible = true;
}

fn settlePendingToolProgress(ctx: *AskContext, call_id: []const u8, outcome: types.ToolOutcome) !void {
    ctx.pending_tool_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.pending_tool_progress_mutex.unlock(io_mod.getIo());
    var pending = takePendingToolProgressLocked(ctx, call_id) orelse return;
    defer pending.deinit(ctx.alloc);
    const context_deferred = outcome.kind == .deferred and
        std.mem.startsWith(u8, outcome.summary, types.context_deferred_tool_status_label ++ " ");
    const legacy_deferred = outcome.kind == .denied and
        std.mem.startsWith(u8, outcome.summary, types.deferred_tool_result_output ++ ": ");
    if (!context_deferred and !legacy_deferred) return;
    if (!pending.visible) return;
    const text = pending.text orelse return;
    try ctx.deferred_tool_progress.append(ctx.alloc, text);
    pending.text = null;
}

fn discardPendingToolProgressLocked(ctx: *AskContext, call_id: []const u8) void {
    for (ctx.pending_tool_progress.items, 0..) |pending, index| {
        if (!std.mem.eql(u8, pending.call_id, call_id)) continue;
        const removed = ctx.pending_tool_progress.swapRemove(index);
        removed.deinit(ctx.alloc);
        return;
    }
}

fn takePendingToolProgressLocked(ctx: *AskContext, call_id: []const u8) ?PendingToolProgress {
    for (ctx.pending_tool_progress.items, 0..) |pending, index| {
        if (std.mem.eql(u8, pending.call_id, call_id)) {
            return ctx.pending_tool_progress.swapRemove(index);
        }
    }
    return null;
}

fn findPendingToolProgressLocked(ctx: *AskContext, call_id: []const u8) ?*PendingToolProgress {
    for (ctx.pending_tool_progress.items) |*pending| {
        if (std.mem.eql(u8, pending.call_id, call_id)) return pending;
    }
    return null;
}

fn consumeDeferredToolProgressLocked(ctx: *AskContext, text: []const u8) bool {
    for (ctx.deferred_tool_progress.items, 0..) |progress, index| {
        if (!std.mem.eql(u8, progress, text)) continue;
        ctx.alloc.free(ctx.deferred_tool_progress.swapRemove(index));
        return true;
    }
    return false;
}

fn clearPendingToolProgress(ctx: *AskContext) void {
    ctx.pending_tool_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.pending_tool_progress_mutex.unlock(io_mod.getIo());
    for (ctx.pending_tool_progress.items) |progress| progress.deinit(ctx.alloc);
    ctx.pending_tool_progress.clearRetainingCapacity();
    for (ctx.deferred_tool_progress.items) |progress| ctx.alloc.free(progress);
    ctx.deferred_tool_progress.clearRetainingCapacity();
}

fn onWebFetchProgress(raw_ctx: *anyopaque, _: []const u8, progress: types.WebFetchProgress) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal()) return;
    const alloc = std.heap.c_allocator;
    const line = tool_presentation.formatWebFetchProgressPlain(alloc, progress) catch return;
    defer alloc.free(line);
    ctx.web_search_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.web_search_progress_mutex.unlock(io_mod.getIo());
    ctx.writeLine(line) catch {};
}

fn pushSystemNotice(raw_ctx: *anyopaque, text: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.presenter) |presenter| return presenter.pushNotice(.{
        .topic = "system",
        .tone = .neutral,
        .body = text,
    });
    try ctx.writeStderr("[notice] ");
    try ctx.writeStderr(text);
    try ctx.writeStderr("\n");
}

fn pushContextNotice(raw_ctx: *anyopaque, text: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (!try ctx.session.claimContextNotice(ctx.alloc, text)) return;
    if (ctx.presenter) |presenter| {
        const body = try types.renderContextNoticeBody(ctx.alloc, text);
        defer ctx.alloc.free(body);
        return presenter.pushNotice(.{
            .topic = "context",
            .tone = .warning,
            .body = body,
            .visibility = .full_only,
        });
    }
    try pushSystemNotice(raw_ctx, text);
}

fn pushRouteRecoveryStatus(raw_ctx: *anyopaque, status: types.RouteRecoveryStatus) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.last_recovery_status = status;
    const terminal = status.kind == .terminal_provider_error;
    const json_progress = switch (status.kind) {
        .auto_retry,
        .auto_recovered,
        .manual_retry_without_fast,
        .manual_recovered_without_fast,
        .terminal_provider_error,
        => true,
        .unsafe_assistant_output,
        .unsafe_tool_start,
        .content_filter,
        => false,
    };
    if ((ctx.output_mode == .json and !json_progress) or
        (ctx.output_mode == .quiet and !terminal)) return;
    var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try pushSystemNotice(raw_ctx, status.label(&label_buf));
    if (terminal and ctx.writable == null) {
        try pushSystemNotice(
            raw_ctx,
            "This run was started with --no-save, so its recovery context cannot be resumed after exit.",
        );
    }
}

fn pushDiffBlock(raw_ctx: *anyopaque, payload: agent_runtime.DiffEntryPayload) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.presenter) |presenter| return presenter.pushDiffBlock(payload);
    defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    try ctx.writeStderr(payload.preview);
}

fn pushCommandOutputComplete(raw_ctx: *anyopaque, _: ?types.ToolLifecycleId) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal() or !ctx.command_output_line_open) return;
    try ctx.writeStderr("\n");
    ctx.command_output_line_open = false;
}

fn pushHttpError(raw_ctx: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.failed = true;
    const auth_failure = auth_runtime.FailureSnapshot.fromHttp(status, credential_source);
    ctx.auth_failure = auth_failure;
    const message = if (auth_failure) |failure|
        try failure.renderText(ctx.alloc)
    else
        try gateway_error_format.formatHttpErrorMessage(ctx.alloc, status, detail);
    defer ctx.alloc.free(message);
    try ctx.writeStderr("fx ask: ");
    try ctx.writeStderr(message);
    try ctx.writeStderr("\n");
    if (ctx.output_mode.capturesJson()) {
        try ctx.assistant_output.appendSlice(ctx.alloc, message);
        try ctx.assistant_output.append(ctx.alloc, '\n');
    }
}

fn formatToolExecutionError(_: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    return tool_result_errors.formatToolExecutionErrorJson(arena, tool_name, err);
}

fn onCommandOutputChunk(raw_ctx: *anyopaque, _: ?types.ToolLifecycleId, _: command_output_content.Stream, chunk: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal()) return;
    try ctx.writeStderr(chunk);
    if (chunk.len > 0) ctx.command_output_line_open = chunk[chunk.len - 1] != '\n';
}

fn resolveAskSubagentAuthority(
    raw: ?*anyopaque,
    alloc: Allocator,
    root_id: []const u8,
) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
    const ctx: *AskContext = @ptrCast(@alignCast(raw.?));
    const active_id = if (ctx.writable) |*value|
        value.active_id
    else
        return error.HostAuthorityUnavailable;
    if (!std.mem.eql(u8, active_id, root_id)) {
        return error.HostAuthorityUnavailable;
    }
    var permission_state = ctx.session.snapshotPermissionState(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HostAuthorityUnavailable,
    };
    defer permission_state.deinit(alloc);
    return subagent_tool_host.captureHostAuthority(
        alloc,
        .{
            .tool_set = ctx.deps.tool_set,
            .mode = .{
                .active = .{
                    .registry = ctx.cfg.mode_registry,
                    .id = ctx.mode_id,
                },
            },
        },
        ctx.permission_rules,
        &.{},
        permission_state,
    );
}

/// Parses one `--provider-order` value for `fx ask`, replacing any earlier
/// occurrence. The returned slice is owned by `alloc`.
fn parseAskProviderOrder(alloc: Allocator, raw: []const u8, previous: ?[][]const u8) ![][]const u8 {
    const parsed: [][]const u8 = switch (config_runtime.parseProviderOrderList(alloc, raw)) {
        .ok => |maybe| maybe orelse return error.InvalidAskArgs,
        .invalid => return error.InvalidAskArgs,
    };
    if (previous) |old| {
        for (old) |slug| alloc.free(@constCast(slug));
        if (old.len > 0) alloc.free(old);
    }
    return parsed;
}

fn parseOptionsWithStdin(alloc: Allocator, args: []const [:0]const u8, stdin: StdinSource) !AskOptions {
    var opts: AskOptions = .{ .prompt = &.{} };
    errdefer opts.deinit(alloc);

    var prompt_parts: std.ArrayList([]const u8) = .empty;
    defer prompt_parts.deinit(alloc);

    var options_ended = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options_ended) {
            try prompt_parts.append(alloc, arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            options_ended = true;
        } else if (std.mem.eql(u8, arg, "--auto")) {
            if (opts.permission_override != null) return error.InvalidAskArgs;
            opts.permission_override = .auto;
        } else if (std.mem.eql(u8, arg, "--full-access") or std.mem.eql(u8, arg, "--yolo")) {
            if (opts.permission_override != null) return error.InvalidAskArgs;
            opts.permission_override = .yolo;
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) return error.InvalidAskArgs;
            const model = std.mem.trim(u8, args[i], " \t\r\n");
            if (model.len == 0) return error.InvalidAskArgs;
            const owned_model = try alloc.dupe(u8, model);
            if (opts.model_override) |old| alloc.free(old);
            opts.model_override = owned_model;
        } else if (std.mem.eql(u8, arg, "--effort")) {
            i += 1;
            if (i >= args.len) return error.InvalidAskArgs;
            opts.effort_override = types.ReasoningEffort.parse(args[i]) orelse
                return error.InvalidAskArgs;
        } else if (std.mem.eql(u8, arg, "--fast") or std.mem.eql(u8, arg, "--no-fast")) {
            const enabled = std.mem.eql(u8, arg, "--fast");
            if (opts.fast_override != null and opts.fast_override.? != enabled)
                return error.InvalidAskArgs;
            opts.fast_override = enabled;
            if (enabled) opts.ultrafast_override = false;
        } else if (std.mem.eql(u8, arg, "--ultrafast") or std.mem.eql(u8, arg, "--no-ultrafast")) {
            const enabled = std.mem.eql(u8, arg, "--ultrafast");
            if (opts.ultrafast_override != null and opts.ultrafast_override.? != enabled)
                return error.InvalidAskArgs;
            opts.ultrafast_override = enabled;
            if (enabled) opts.fast_override = false;
        } else if (std.mem.eql(u8, arg, "--provider-order")) {
            i += 1;
            if (i >= args.len) return error.InvalidAskArgs;
            opts.provider_order_override = try parseAskProviderOrder(alloc, args[i], opts.provider_order_override);
        } else if (std.mem.startsWith(u8, arg, "--provider-order=")) {
            opts.provider_order_override = try parseAskProviderOrder(alloc, arg["--provider-order=".len..], opts.provider_order_override);
        } else if (std.mem.eql(u8, arg, "--provider-strict") or std.mem.eql(u8, arg, "--no-provider-strict")) {
            const strict = std.mem.eql(u8, arg, "--provider-strict");
            if (opts.provider_strict_override != null and opts.provider_strict_override.? != strict)
                return error.InvalidAskArgs;
            opts.provider_strict_override = strict;
        } else if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "--resume-id")) {
            if (opts.resume_target != null) return error.InvalidAskArgs;
            const exact_id = std.mem.eql(u8, arg, "--resume-id");
            i += 1;
            if (i >= args.len) return error.InvalidAskArgs;
            const target = std.mem.trim(u8, args[i], " \t\r\n");
            if (target.len == 0) return error.InvalidAskArgs;
            opts.resume_target = if (!exact_id and std.mem.eql(u8, target, "last"))
                .last
            else
                .{ .id = target };
        } else if (std.mem.eql(u8, arg, "--image")) {
            i += 1;
            if (i >= args.len) return error.MissingPrompt;
            try opts.image_paths.append(alloc, try alloc.dupe(u8, args[i]));
        } else if (std.mem.eql(u8, arg, "--system")) {
            i += 1;
            if (i >= args.len) return error.MissingPrompt;
            if (opts.system_prompt_override) |old| alloc.free(old);
            opts.system_prompt_override = try alloc.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json_output = true;
        } else if (std.mem.eql(u8, arg, "--prompt-permissions")) {
            opts.prompt_permissions = true;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) return error.MissingPrompt;
            opts.timeout_ms = parseTimeoutMs(args[i]);
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-save")) {
            opts.no_save = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
        } else if (std.mem.eql(u8, arg, "--continue-recovery")) {
            if (opts.continue_recovery) return error.InvalidAskArgs;
            opts.continue_recovery = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            return error.InvalidAskArgs;
        } else {
            try prompt_parts.append(alloc, arg);
        }
    }

    if (opts.continue_recovery) {
        if (opts.resume_target == null or opts.no_save or
            prompt_parts.items.len != 0 or opts.image_paths.items.len != 0)
        {
            return error.InvalidAskArgs;
        }
        opts.prompt = try alloc.dupe(u8, "");
    } else if (prompt_parts.items.len > 0) {
        opts.prompt = try joinPromptSlices(alloc, prompt_parts.items);
    } else {
        opts.prompt = try readPromptFromStdinSource(alloc, stdin);
    }
    if (!text_utils.isModelSafeText(opts.prompt)) return error.InvalidPromptText;
    if (opts.no_save and opts.resume_target != null) return error.NoSaveResumeConflict;

    return opts;
}

fn emitHeadlessYoloWarning(alloc: Allocator, options: RunOptions) !void {
    if (options.color_enabled and options.deps.stderr_is_tty(options.deps.stderr_ctx)) {
        try options.deps.write_stderr(
            options.deps.stderr_ctx,
            "\x1b[38;5;252m" ++ permissions.yolo_warning_text ++ "\x1b[0m\n",
        );
    } else {
        try options.deps.write_stderr(options.deps.stderr_ctx, permissions.yolo_warning_text ++ "\n");
    }

    var attempt = options.deps.persist_yolo_acknowledgment(alloc);
    defer attempt.deinit(alloc);
    switch (attempt) {
        .outcome => {},
        .failure => |failure| {
            var message: std.Io.Writer.Allocating = .init(alloc);
            defer message.deinit();
            try message.writer.print(
                "fx ask: failed to save full access acknowledgment: {s}\n",
                .{@errorName(failure.err)},
            );
            try options.deps.write_stderr(options.deps.stderr_ctx, message.written());
        },
    }
}

fn persistYoloAcknowledgmentDefault(alloc: Allocator) config_runtime.CommitAttempt {
    return config_runtime.attemptUserPreferences(
        alloc,
        .{ .yolo_acknowledged = true },
    );
}

fn hasJsonFlag(args: []const [:0]const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn parseTimeoutMs(raw: []const u8) ?usize {
    const seconds = std.fmt.parseInt(usize, raw, 10) catch return null;
    return std.math.mul(usize, seconds, std.time.ms_per_s) catch null;
}

fn joinPromptSlices(alloc: Allocator, args: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (args, 0..) |arg, idx| {
        if (idx > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(arg);
    }
    return try out.toOwnedSlice();
}

fn readPromptFromStdinSource(alloc: Allocator, stdin: StdinSource) ![]u8 {
    return readPromptFromStdinSourceWithLimit(alloc, stdin, stdin_prompt_resource_byte_limit);
}

fn readPromptFromStdinSourceWithLimit(
    alloc: Allocator,
    stdin: StdinSource,
    resource_byte_limit: usize,
) ![]u8 {
    const input = switch (stdin) {
        .real => blk: {
            if (try std.Io.File.stdin().isTty(io_mod.getIo())) return error.MissingPrompt;
            break :blk try readPromptFromStdin(alloc, resource_byte_limit);
        },
        .tty => return error.MissingPrompt,
        .bytes => |bytes| blk: {
            if (bytes.len > resource_byte_limit) return error.PromptResourceLimitExceeded;
            break :blk try alloc.dupe(u8, bytes);
        },
        .read_error => return error.PromptInputReadFailed,
    };
    errdefer alloc.free(input);

    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.MissingPrompt;
    if (trimmed.len == input.len) return input;

    const owned = try alloc.dupe(u8, trimmed);
    alloc.free(input);
    return owned;
}

fn readPromptFromStdin(alloc: Allocator, resource_byte_limit: usize) ![]u8 {
    const zio = io_mod.getIo();
    var read_buf: [8192]u8 = undefined;
    var r = std.Io.File.stdin().reader(zio, &read_buf);
    return readPromptFromReader(alloc, &r.interface, resource_byte_limit);
}

fn readPromptFromReader(
    alloc: Allocator,
    reader: *std.Io.Reader,
    resource_byte_limit: usize,
) ![]u8 {
    const detection_limit = std.math.add(usize, resource_byte_limit, 1) catch
        return error.PromptResourceLimitExceeded;
    const input = reader.allocRemaining(alloc, .limited(detection_limit)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.PromptResourceLimitExceeded,
        else => return error.PromptInputReadFailed,
    };
    if (input.len > resource_byte_limit) {
        alloc.free(input);
        return error.PromptResourceLimitExceeded;
    }
    return input;
}

fn renderFinalJsonResult(alloc: Allocator, result: PromptRunResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"output\":");
    try std.json.Stringify.value(result.assistant_output, .{}, &out.writer);
    try out.writer.writeAll(",\"final_output\":");
    try std.json.Stringify.value(result.final_output, .{}, &out.writer);
    try out.writer.print(",\"exit_code\":{d}", .{result.exit_code});
    try out.writer.writeAll(",\"model\":");
    try std.json.Stringify.value(result.model, .{}, &out.writer);
    try out.writer.writeAll(",\"resolved_provider\":");
    if (result.resolved_provider.len > 0) {
        try std.json.Stringify.value(result.resolved_provider, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"session_id\":");
    try std.json.Stringify.value(result.session_id, .{}, &out.writer);
    try out.writer.print(",\"steps\":{d}", .{result.step_count});
    try out.writer.writeAll(",\"tool_calls\":[");
    for (result.tool_calls, 0..) |tc, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(tc.name, .{}, &out.writer);
        try out.writer.writeAll(",\"status\":");
        try std.json.Stringify.value(tc.status, .{}, &out.writer);
        if (tc.action) |action| {
            try out.writer.writeAll(",\"action\":");
            try std.json.Stringify.value(@tagName(action), .{}, &out.writer);
        }
        if (tc.error_category) |category| {
            try out.writer.writeAll(",\"error\":{\"category\":");
            try std.json.Stringify.value(@tagName(category), .{}, &out.writer);
            try out.writer.writeAll(",\"code\":");
            try std.json.Stringify.value(
                tc.error_code orelse "tool_failed",
                .{},
                &out.writer,
            );
            try out.writer.writeByte('}');
        }
        if (tc.command_result_json) |json| {
            try out.writer.writeAll(",\"command_result\":");
            try out.writer.writeAll(json);
        }
        if (tc.ask_question_text) |text| {
            try out.writer.writeAll(",\"question\":");
            try std.json.Stringify.value(text, .{}, &out.writer);
        }
        if (tc.web_search_completion) |completion| {
            try out.writer.print(",\"web_search\":{{\"searches\":{d},\"duration_ms\":{d}}}", .{ completion.searches, completion.duration_ms });
        }
        if (tc.web_fetch_completion) |completion| {
            try out.writer.writeAll(",\"web_fetch\":{\"url\":");
            try std.json.Stringify.value(completion.url(), .{}, &out.writer);
            try out.writer.print(",\"bytes\":{d},\"status\":{d},\"duration_ms\":{d},\"cache_hit\":{s},\"artifact\":\"{s}\"}}", .{
                completion.bytes,
                completion.status,
                completion.duration_ms,
                if (completion.cache_hit) "true" else "false",
                @tagName(completion.artifact_state),
            });
        }
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("],\"usage\":");
    try std.json.Stringify.value(.{
        .input_tokens = result.usage.input_tokens,
        .output_tokens = result.usage.output_tokens,
    }, .{}, &out.writer);
    if (result.error_code) |error_code| {
        try out.writer.writeAll(",\"error\":");
        try std.json.Stringify.value(error_code, .{}, &out.writer);
    }
    if (result.auth_failure) |failure| {
        try out.writer.writeAll(",\"auth_failure\":");
        try failure.writeJson(&out.writer);
    }
    if (result.recovery) |recovery| {
        var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
        try out.writer.writeAll(",\"recovery\":{\"state\":");
        try std.json.Stringify.value(
            if (recovery.kind == .terminal_provider_error)
                // A genuine lifecycle pause (action == .paused) is resumable; a
                // terminal stop (no action) is not. JSON consumers need the
                // distinction.
                if (recovery.action == .paused) "paused" else "failed"
            else if (recovery.isRecovered()) "recovered" else "active",
            .{},
            &out.writer,
        );
        try out.writer.writeAll(",\"kind\":");
        try std.json.Stringify.value(@tagName(recovery.kind), .{}, &out.writer);
        if (recovery.cause) |cause| {
            try out.writer.writeAll(",\"cause\":");
            try std.json.Stringify.value(@tagName(cause), .{}, &out.writer);
        }
        if (recovery.action) |action| {
            try out.writer.writeAll(",\"action\":");
            try std.json.Stringify.value(@tagName(action), .{}, &out.writer);
        }
        if (recovery.required_action != .none) {
            try out.writer.writeAll(",\"required_action\":");
            try std.json.Stringify.value(@tagName(recovery.required_action), .{}, &out.writer);
        }
        try out.writer.print(",\"attempt\":{d},\"attempt_limit\":{d},\"delay_seconds\":{d},\"durable\":{s},\"message\":", .{
            recovery.reportedAttempt(),
            recovery.attempt_limit,
            recovery.delay_seconds,
            if (result.recovery_durable) "true" else "false",
        });
        try std.json.Stringify.value(recovery.label(&label_buf), .{}, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("}\n");
    return try out.toOwnedSlice();
}

fn renderErrorJsonResult(alloc: Allocator, err_name: []const u8) ![]u8 {
    return renderFinalJsonResult(alloc, .{
        .exit_code = 1,
        .assistant_output = &.{},
        .error_code = err_name,
    });
}

fn toCoreReasoningEffort(effort: types.ReasoningEffort) types.ReasoningEffort {
    return effort;
}

fn toCorePermissionMode(mode: anytype) PermissionMode {
    return switch (mode) {
        .ask => .ask,
        .auto => .auto,
        .yolo => .yolo,
    };
}

fn takeCorePermissionRules(_: Allocator, startup: *app_lifecycle.StartupState) !types.PermissionRuleSet {
    return startup.takePermissionRules();
}

/// Theme selection mirrors the interactive bootstrap: FX_THEME wins over the
/// settings "theme" key. light/dark pin the builtin variant immediately; a
/// named theme records its source so the presentation layer can resolve it
/// once terminal detection picks the variant.
fn applyAskThemeChoice(settings_theme: ?[]const u8) void {
    var configured: ?[]const u8 = settings_theme;
    if (io_mod.getenv("FX_THEME")) |value| {
        if (value.len > 0) configured = value;
    }
    const choice = if (configured) |value| shared_theme.classifyValue(value) else null;
    if (choice) |selected| switch (selected) {
        .pin_light, .pin_dark => {
            shared_theme.setSource(null, true);
            ui_render.initTheme(selected == .pin_light, null);
        },
        .custom => |name| shared_theme.setSource(name, false),
    };
}

fn loadStartupStateDefault(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    default_model: []const u8,
    default_agent_step_limit: usize,
    model_override: ?[]const u8,
) !app_lifecycle.StartupState {
    return app_lifecycle.loadStartupStateForRun(
        alloc,
        transport,
        default_model,
        default_agent_step_limit,
        .local,
        model_override,
    );
}

fn initializeSessionStoresDefault(ctx: *AskContext) !void {
    try ctx.initializeSessionStores();
}

fn processQueuedPromptDefault(agent: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, config: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
    return agent_runtime.processAgentPrompt(agent, deps, semantic_presentation, lifecycle, config, job);
}

fn discardPristineSessionDefault(
    _: ?*anyopaque,
    ctx: *AskContext,
    loaded: *session_store.LoadedWritableSession,
) session_store.PristineDiscardDisposition {
    return ctx.store.?.discardPristineStartedSession(ctx.alloc, loaded);
}

fn promptRealPermissionApproval(
    _: ?*anyopaque,
    stderr_ctx: ?*anyopaque,
    write_stderr: WriteFn,
    label: []const u8,
    attention_ctx: ?*anyopaque,
    notify_attention: NotifyAttentionFn,
) !PermissionApprovalPromptResult {
    const zio = io_mod.getIo();
    const stdin_tty = std.Io.File.stdin().isTty(zio) catch false;
    if (!stdin_tty) return .unavailable;

    try write_stderr(stderr_ctx, "fx wants to run:\n  ");
    try write_stderr(stderr_ctx, label);
    try write_stderr(stderr_ctx, "\n\nApprove? [y/N] ");
    notify_attention(attention_ctx);

    var read_buf: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(zio, &read_buf);
    const line = reader.interface.takeDelimiter('\n') catch return .deny;
    const answer = std.mem.trim(u8, line orelse "", " \t\r\n");
    if (answer.len == 1 and (answer[0] == 'y' or answer[0] == 'Y')) return .approve;
    return .deny;
}

fn realStderrIsTty(_: ?*anyopaque) bool {
    return std.Io.File.stderr().isTty(io_mod.getIo()) catch false;
}

fn realStdinIsTty(_: ?*anyopaque) bool {
    return std.Io.File.stdin().isTty(io_mod.getIo()) catch false;
}

fn realStdoutIsTty(_: ?*anyopaque) bool {
    return std.Io.File.stdout().isTty(io_mod.getIo()) catch false;
}

fn writeRealStdout(_: ?*anyopaque, text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn writeRealStderr(_: ?*anyopaque, text: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
}

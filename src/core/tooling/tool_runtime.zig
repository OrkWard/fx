const std = @import("std");
const skill_contract = @import("../skills/skill_contract.zig");
const builtin = @import("builtin");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const command_contract = @import("../execution/command_contract.zig");
const command_environment = @import("../execution/command_environment.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const tool_contracts = @import("../agent/runtime/tool_contracts.zig");
const result_commit = @import("result_commit.zig");
const vision_executor = @import("../agent/runtime/vision_executor.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const file_mutation = @import("file_mutation.zig");
const hooks = @import("../hooks/hooks.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const permission_prompter = @import("../permissions/permission_prompter.zig");
const command_admission = @import("../permissions/command_admission.zig");
const execution_router = @import("../execution/router.zig");
const subagent_model_contract = @import("../subagent/model_contract.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_tool_provider = @import("../subagent/tool_provider.zig");
const session_runtime = @import("../session/session.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_child_store = @import("../session/session_child_store.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const tool_admission = @import("tool_admission.zig");
const command_result_mapping = @import("command_result_mapping.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_specs = @import("tool_specs.zig");
const tool_result_errors = @import("tool_result_errors.zig");
const tool_result_limits = @import("tool_result_limits.zig");
const compactor = @import("../compactor/compactor.zig");
const file_mutation_execution = @import("file_mutation_execution.zig");
const tool_presentation = @import("tool_presentation.zig");
const shell_impl = @import("../../tools/shell/shell.zig");
const web_fetch_runtime = @import("web_fetch_runtime.zig");
const web_fetch_artifacts = @import("../session/web_fetch_artifacts.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_set = @import("../gateway/provider_set.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const context_contract = @import("../workspace/context_contract.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const ChatMessage = types.ChatMessage;

const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolExecutionResult = tool_contracts.ToolExecutionResult;
const SessionRuntime = session_runtime.SessionRuntime;
const WorkerRuntime = worker_runtime.WorkerRuntime;

const context_limits = @import("../config/context_limits.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const host_capabilities = @import("../hosts/host.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const terminal_managed_observer = @import("../terminal/managed_observer.zig");

pub const Context = struct {
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    /// Passed to subagent turns. See `Config.auto_compact_percent`.
    auto_compact_percent: u8 = compactor.default_percent,
    api_key: []const u8,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    provider: model_provider.ProviderId = .codex,
    provider_capabilities: provider_set.Bundle.Capabilities = .{
        .fx_search = true,
        .vision_fallback = true,
    },
    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
    model: []const u8,
    /// Resolved review-model override for automatic permission review. Empty
    /// keeps the reviewer provider's compiled default.
    reviewer_model: []const u8 = "",
    permission_review_turn: ?permission_auto_classifier.ReviewTurnContext = null,
    root_user_intent_context: []const u8 = "",
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    current_turn_messages: []const ChatMessage = &.{},
    agent_step_limit: usize,
    fast_mode: bool = false,
    ultrafast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    /// Borrowed gateway provider routing inherited by subagent turns. Never
    /// applied to tool-internal provider requests (vision, web search), which
    /// keep gateway-default routing.
    provider_order: []const []const u8 = &.{},
    provider_strict: bool = false,
    first_call_tool_choice: types.ToolChoice = .auto,
    tool_registry: tool_dispatch.Registry = .{},
    subagent_host: ?*subagent_tool_host.Runtime = null,
    subagent_caller_id: ?[]const u8 = null,
    permission_mode: PermissionMode,
    permission_grants: []const PermissionGrant,
    session_grants: []const PermissionGrant = &.{},
    permission_rules: types.PermissionRuleSet,
    permission_state_override: ?*const session_permission_state.State = null,
    worker: *WorkerRuntime,
    /// Sole prompt capability admission consults. When null, admission never
    /// prompts: it resolves by rule, automatic review, or fail-closed denial
    permission_prompter: ?permission_prompter.Prompter = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    session: *SessionRuntime,
    session_allocator: Allocator = std.heap.c_allocator,
    skills_dir: []const u8 = "",
    skill_locations: ?*const skill_contract.Locations = null,
    context_limits: context_limits.Values = .{},
    context_registry: context_contract.Registry,
    context_enabled: bool = true,
    output_chunk_lifecycle_id: ?types.ToolLifecycleId = null,
    output_chunk_ctx: *anyopaque,
    on_output_chunk: command_contract.CommandOutputCallback,
    command_artifact_dir: ?[]const u8 = null,
    tool_result_dir: ?[]const u8 = null,
    session_child_capability: ?*session_child_store.SessionChildCapability = null,
    ephemeral_command_replay: ?*command_replay_store.EphemeralStore = null,
    terminal_client: ?*terminal_client_runtime.Runtime = null,
    managed_executions: ?*managed_execution.Runtime = null,
    command_timeout_ms: ?usize = null,
    command_timeout_started_ms: ?i64 = null,
    command_replay_capture: ?*command_replay_store.Capture = null,
    command_replay_unavailable: bool = false,
    tracker: ?*change_tracker.ChangeTracker = null,
    tool_progress_ctx: ?*anyopaque = null,
    on_tool_progress: ?*const fn (*anyopaque, types.ToolLifecycleId, []const u8) void = null,
    subagent_status_renderer: ?types.SubagentStatusRenderer = null,
    permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    auto_classifier: permission_auto_classifier.Classifier =
        permission_auto_classifier.Classifier.disabled(),
    web_fetch_runtime: ?*web_fetch_runtime.Runtime = null,
    web_fetch_artifact_store: ?*web_fetch_artifacts.Store = null,
    web_fetch_artifact_error: ?anyerror = null,
    web_search_runtime_ready: bool = false,
    web_search_backend: ?tool_dispatch.WebSearchBackend = null,
    web_search_progress_ctx: ?*anyopaque = null,
    on_web_search_progress: ?tool_dispatch.WebSearchProgressFn = null,
    web_fetch_progress_ctx: ?*anyopaque = null,
    on_web_fetch_progress: ?tool_dispatch.WebFetchProgressFn = null,
    model_capability_resolver: ?model_capabilities.Resolver = null,
    /// False when running outside an interactive TUI (e.g. `fx ask`). Tools
    /// that require a live user (like `ask_user_question`) short-circuit
    /// in that case.
    interactive: bool = true,
    lifecycle_view: hooks.RuntimeView = hooks.RuntimeView.empty(),
    lifecycle_scope: hooks.Scope = .{
        .kind = .interactive,
        .workspace_root = "",
    },

    /// Projects only the borrowed capabilities consumed by admission.
    pub fn admissionInput(self: Context) tool_admission.Input {
        var input: tool_admission.Input = .{
            .workspace_root = self.workspace_root,
            .access_scope = self.access_scope,
            .permission_review_turn = self.permission_review_turn,
            .permission_grants = self.permission_grants,
            .permission_rules = self.permission_rules,
            .session_permission_state = self.permission_state_override,
            .session_permission_state_provider = .{
                .context = @ptrCast(self.session),
                .snapshot_fn = snapshotSessionPermissionState,
            },
            .tool_registry = self.tool_registry,
            .worker = self.worker,
            .permission_prompter = self.permission_prompter,
            .context_limits = self.context_limits,
            .auto_classifier = self.admissionAutoClassifier(),
            .terminal_review_context = self.terminalReviewContext(),
        };
        if (self.permission_state_override != null) {
            input.session_permission_state_provider = null;
        }
        return input;
    }

    fn terminalReviewContext(self: Context) ?terminal_managed_observer.Context {
        return .{
            .alloc = self.session_allocator,
            .lifecycle_allocator = self.session_allocator,
            .terminal_client = self.terminal_client orelse return null,
            .managed_runtime = self.managed_executions orelse return null,
            .owner = self.session_child_capability orelse return null,
            .durable_session_id = self.lifecycle_scope.session_id orelse return null,
            .workspace_root = self.workspace_root,
            .transport_role = switch (self.lifecycle_scope.kind) {
                .interactive, .subagent => .interactive,
                .ask => .headless,
            },
            .max_output_bytes = self.max_command_output_bytes,
            .cancel_flag = runtimeCancelFlag(self),
        };
    }

    pub fn admissionInputWithLiveAuthority(
        self: Context,
        authority: ?tool_contracts.LiveToolAuthority,
    ) tool_admission.Input {
        var input = self.admissionInput();
        if (authority) |live| {
            input.permission_grants = live.grants;
            input.permission_rules = live.rules;
            input.session_permission_state = live.permission_state;
            if (live.permission_state != null) {
                input.session_permission_state_provider = null;
            }
        }
        return input;
    }

    fn admissionAutoClassifier(self: Context) permission_auto_classifier.Classifier {
        if (self.auto_classifier.enabled()) return self.auto_classifier;
        const provider = self.permission_reviewer_provider orelse
            return permission_auto_classifier.Classifier.disabled();
        return permission_auto_classifier.Classifier.withProvider(provider, .{
            .credential = self.api_key,
            .credential_source = self.credential_source,
            .account_id = self.account_id,
            .endpoint = "",
            .reviewer_model = self.reviewer_model,
            .cancel_flag = self.cancel_flag,
            .usage = &self.session.usage,
            .usage_allocator = self.session_allocator,
        });
    }
};

fn snapshotSessionPermissionState(
    raw_session: *anyopaque,
    alloc: Allocator,
) !session_permission_state.State {
    const session: *SessionRuntime = @ptrCast(@alignCast(raw_session));
    return session.snapshotPermissionState(alloc);
}

fn registeredToolSpec(ctx: Context, name: []const u8) ?*const tool_specs.ToolSpec {
    return ctx.tool_registry.lookup(name);
}

fn providerDisablesTool(capabilities: provider_set.Bundle.Capabilities, name: []const u8) bool {
    return std.mem.eql(u8, name, "vision") and
        !capabilities.vision_fallback;
}

pub fn validateToolCall(ctx: Context, arena: Allocator, call: ToolCall) !tool_contracts.ToolCallValidationResult {
    if (providerDisablesTool(ctx.provider_capabilities, call.name)) {
        return .{ .failure = try arena.dupe(u8, "Unsupported tool: vision") };
    }
    const spec = registeredToolSpec(ctx, call.name) orelse return .not_registered;
    switch (spec.executor_kind) {
        // File mutation arguments are decoded once by shared permission preflight.
        .write_file, .edit_file => return .{ .valid = .{} },
        else => {},
    }

    var dispatch_ctx = typedDispatchContext(ctx, arena);
    dispatch_ctx.captured_command_host = spec.captured_command_host;
    return switch (try tool_dispatch.validateRegisteredToolCall(dispatch_ctx, ctx.tool_registry, call)) {
        .not_registered => .not_registered,
        .valid => .{ .valid = .{} },
        .failure => |reason| .{ .failure = reason },
    };
}

pub fn checkToolAvailability(ctx: Context, arena: Allocator, call: ToolCall) !?[]const u8 {
    if (providerDisablesTool(ctx.provider_capabilities, call.name)) {
        return try arena.dupe(u8, "Unsupported tool: vision");
    }
    return tool_dispatch.localToolAvailabilityFailureForCall(
        typedDispatchContext(ctx, arena),
        ctx.tool_registry,
        call,
    );
}

pub fn executeToolCallAuthorized(
    ctx: Context,
    request: tool_contracts.ToolExecutionRequest,
) !ToolExecutionResult {
    var replay_continuation_transferred = request.command_replay_capture == null;
    defer if (!replay_continuation_transferred) {
        request.command_replay_capture.?.abort(request.result_allocator);
    };
    var execution_ctx = ctx;
    execution_ctx.skill_locations = request.skill_locations orelse ctx.skill_locations;
    if (request.permission_mode) |permission_mode| {
        execution_ctx.permission_mode = permission_mode;
    }
    if (request.live_authority) |authority| {
        if (!containsName(authority.tools, request.call.name)) {
            return tool_contracts.failToolExecutionResult(
                error.LiveToolAuthorityUnavailable,
            );
        }
        execution_ctx.permission_mode = authority.permission_mode;
        execution_ctx.permission_grants = authority.grants;
        execution_ctx.session_grants = authority.grants;
        execution_ctx.permission_rules = authority.rules;
    } else {
        execution_ctx.session_grants = request.session_grants;
    }
    execution_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    execution_ctx.current_turn_messages = request.current_turn_messages;
    execution_ctx.output_chunk_lifecycle_id = request.lifecycle_id;
    execution_ctx.command_timeout_started_ms = request.command_timeout_started_ms;
    execution_ctx.command_replay_capture = request.command_replay_capture;
    execution_ctx.command_replay_unavailable = request.command_replay_unavailable;

    const started_at_ms = io_mod.milliTimestamp();
    const uses_file_mutation_contract = if (registeredToolSpec(
        execution_ctx,
        request.call.name,
    )) |spec|
        spec.take_file_mutation_input_fn != null
    else
        false;
    const result = (if (uses_file_mutation_contract)
        file_mutation_execution.execute(.{
            .call_allocator = request.call_allocator,
            .result_allocator = request.result_allocator,
            .call = request.call,
            .authorization = switch (request.authority) {
                .file_mutation => |value| value,
                else => null,
            },
            .maybe_cancel_flag = execution_ctx.cancel_flag,
            .lifecycle_id = request.lifecycle_id,
        })
    else
        executeToolCallInner(
            execution_ctx,
            request.result_allocator,
            request.call,
            request.authority,
            request.classification_complete,
            request.authorized_image_catalog,
        )) catch |err| {
        diagnostics.recordToolCallResult(.{
            .name = request.call.name,
            .arguments_json = request.call.arguments_json,
            .model_output = "",
            .outcome = classifyToolExecutionError(err),
            .started_at_ms = started_at_ms,
            .subagent_id = execution_ctx.lifecycle_scope.subagent_id orelse 0,
        });
        return if (err == error.CancelledBeforeExecution) error.Cancelled else err;
    };
    diagnostics.recordToolCallResult(.{
        .name = request.call.name,
        .arguments_json = request.call.arguments_json,
        .model_output = result.model_output,
        .outcome = classifyReturnedToolCallOutcome(result),
        .started_at_ms = started_at_ms,
        .subagent_id = execution_ctx.lifecycle_scope.subagent_id orelse 0,
    });
    if (request.command_replay_capture) |continued| {
        replay_continuation_transferred = result.command_replay_capture == continued;
    }
    return result;
}

fn classifyToolExecutionError(err: anyerror) diagnostics.ToolCallOutcome {
    return switch (err) {
        error.CancelledBeforeExecution => .rejected,
        error.Cancelled => .tool_failed,
        else => .runtime_failed,
    };
}

fn classifyReturnedToolCallOutcome(
    result: ToolExecutionResult,
) diagnostics.ToolCallOutcome {
    if (result.status == .success) return .succeeded;
    if (result.command_result_json != null) return .command_failed;
    // Only an explicit denial records a rejection. An authorized execution
    // that failed — with or without a declared kind — is a tool failure, so
    // a producer that forgets to declare a kind cannot silently masquerade
    // as a rejection in diagnostics.
    return switch (result.failure_kind) {
        .denied => .rejected,
        .none, .preflight, .apply => .tool_failed,
    };
}

fn containsName(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

pub fn executeToolCall(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
) !ToolExecutionResult {
    return executeToolCallAuthorized(ctx, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = call,
        .authority = .ordinary,
        .current_turn_messages = ctx.current_turn_messages,
        .session_grants = ctx.session_grants,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
    });
}

const ToolDispatchPrelude = union(enum) {
    completed: ToolExecutionResult,
    registered_static,
};

fn executeToolCallInner(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
    classification_complete: bool,
    authorized_image_catalog: []const types.ImageAttachment,
) !ToolExecutionResult {
    return switch (try resolveToolDispatchPrelude(
        ctx,
        arena,
        call,
        classification_complete,
    )) {
        .completed => |result| return result,
        .registered_static => try executeRegisteredTool(
            ctx,
            arena,
            call,
            authority,
            authorized_image_catalog,
            ctx.tool_registry,
        ),
    };
}

fn resolveToolDispatchPrelude(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    classification_complete: bool,
) !ToolDispatchPrelude {
    if (!classification_complete) {
        if (try checkToolAvailability(ctx, arena, call)) |reason| {
            return .{ .completed = semanticFailure(reason) };
        }
    }
    if (registeredToolSpec(ctx, call.name) != null) return .registered_static;
    return .{ .completed = semanticFailure(
        try arena.print("Unsupported tool: {s}", .{call.name}),
    ) };
}

fn executeRegisteredTool(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
    authorized_image_catalog: []const types.ImageAttachment,
    registry: tool_dispatch.Registry,
) !ToolExecutionResult {
    var context_notice_sink = ContextNoticeSinkState{ .allocator = arena };
    var command_backend = RunCommandBackendState{ .runtime = ctx };
    var vision_provider = VisionProviderState{
        .runtime = ctx,
        .authorized_image_catalog = authorized_image_catalog,
    };
    var dispatch_metadata: DispatchMetadata = .{};
    var subagent_provider = SubagentProviderState{
        .runtime = ctx,
        .call = call,
        .completion_sink = &dispatch_metadata.subagent_completion,
    };
    var dispatch_ctx = typedDispatchContextForCall(ctx, arena, call);
    dispatch_metadata.attach(&dispatch_ctx);
    var result_commit_token: ?result_commit.Token = null;
    dispatch_ctx.result_commit_sink = &result_commit_token;
    dispatch_ctx.execution_authority = authority;
    const runtime_provider = if (registry.lookup(call.name)) |tool|
        tool.runtime_provider
    else
        .none;
    if (registry.lookup(call.name)) |tool| {
        dispatch_ctx.captured_command_host = tool.captured_command_host;
    }
    switch (runtime_provider) {
        .none => {},
        .run_command => dispatch_ctx.run_command_backend = .{
            .ctx = &command_backend,
            .execute_fn = executeRunCommandBackend,
        },
        .vision => dispatch_ctx.vision_provider = .{
            .ctx = &vision_provider,
            .execute_fn = executeVisionProvider,
        },
        .subagent => dispatch_ctx.subagent_provider = .{
            .context = &subagent_provider,
            .execute_fn = executeSubagentProvider,
        },
    }
    attachContextNoticeSink(&dispatch_ctx, &context_notice_sink);
    const dispatched = try tool_dispatch.dispatchAuthorizedToolCall(
        dispatch_ctx,
        registry,
        call,
    );
    if (command_backend.execution_error) |err| {
        dispatched.deinit(arena);
        return err;
    }
    if (vision_provider.execution_error) |err| {
        dispatched.deinit(arena);
        return err;
    }

    var execution = if (command_backend.completion) |completion|
        completion
    else if (vision_provider.completion) |completion|
        completion
    else
        toolExecutionResultFromDispatch(dispatched, dispatch_metadata);
    execution.model_output = dispatched.body;
    execution.context_notices = context_notice_sink.notices.items;
    execution.result_commit = result_commit_token;
    if (dispatch_ctx.cancel_flag) |cancel_flag| {
        if (cancel_flag.load(.seq_cst) and
            tool_dispatch.toolActivityKind(registry, call.name) == .command)
        {
            execution.cancelled = true;
        }
    }
    return execution;
}

const RunCommandBackendState = struct {
    runtime: Context,
    completion: ?ToolExecutionResult = null,
    execution_error: ?anyerror = null,
};

fn executeRunCommandBackend(
    maybe_ctx: ?*anyopaque,
    dispatch_ctx: tool_dispatch.DispatchContext,
    request: tool_dispatch.RunCommandRequest,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const raw_ctx = maybe_ctx orelse unreachable;
    const state: *RunCommandBackendState = @ptrCast(@alignCast(raw_ctx));
    const authority = switch (dispatch_ctx.execution_authority orelse {
        state.execution_error = error.InvalidRunCommandExecutionAuthority;
        return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
    }) {
        .run_command => |command_authority| command_authority,
        .ordinary, .file_mutation, .vision_paths => {
            state.execution_error = error.InvalidRunCommandExecutionAuthority;
            return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
        },
    };
    const execution = toolRunCommand(
        state.runtime,
        dispatch_ctx.allocator,
        request,
        authority,
    ) catch |err| {
        state.execution_error = err;
        return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
    };
    state.completion = execution;
    return switch (execution.status) {
        .success => .{ .success = @constCast(execution.model_output) },
        .failure => .{ .failure = @constCast(execution.model_output) },
    };
}

const DispatchMetadata = struct {
    model_content_kind: tool_dispatch.ModelContentKind = .ordinary,
    inner_usage: ?types.ToolUsage = null,
    web_search_completion: ?types.WebSearchCompletion = null,
    web_fetch_completion: ?types.WebFetchCompletion = null,
    subagent_completion: ?types.SubagentStatus = null,
    tool_result_memory: ?types.ToolResultMemory = null,
    command_result_json: ?[]const u8 = null,

    fn attach(self: *DispatchMetadata, ctx: *tool_dispatch.DispatchContext) void {
        ctx.model_content_kind_sink = &self.model_content_kind;
        ctx.inner_usage_sink = &self.inner_usage;
        ctx.web_search_completion_sink = &self.web_search_completion;
        ctx.web_fetch_completion_sink = &self.web_fetch_completion;
        ctx.tool_result_memory_sink = &self.tool_result_memory;
        ctx.command_result_json_sink = &self.command_result_json;
    }
};

fn toolExecutionResultFromDispatch(
    result: tool_dispatch.AuthorizedDispatchResult,
    metadata: DispatchMetadata,
) ToolExecutionResult {
    var memory = metadata.tool_result_memory;
    if (result.images.len > 0) {
        var rich_memory = memory orelse types.ToolResultMemory{};
        rich_memory.tool_images = result.images;
        memory = rich_memory;
    }
    return switch (result.status) {
        .success => .{
            .model_content_kind = metadata.model_content_kind,
            .model_output = result.body,
            .inner_usage = metadata.inner_usage,
            .web_search_completion = metadata.web_search_completion,
            .web_fetch_completion = metadata.web_fetch_completion,
            .subagent_completion = metadata.subagent_completion,
            .tool_result_memory = memory,
            .command_result_json = metadata.command_result_json,
        },
        .failure => .{
            .status = .failure,
            .model_output = result.body,
            .inner_usage = metadata.inner_usage,
            .web_search_completion = metadata.web_search_completion,
            .web_fetch_completion = metadata.web_fetch_completion,
            .subagent_completion = metadata.subagent_completion,
            .tool_result_memory = memory,
            .command_result_json = metadata.command_result_json,
        },
    };
}

const ContextNoticeSinkState = struct {
    allocator: Allocator,
    notices: std.ArrayList([]const u8) = .empty,
};

fn attachContextNoticeSink(dispatch_ctx: *tool_dispatch.DispatchContext, state: *ContextNoticeSinkState) void {
    dispatch_ctx.context_notice_ctx = state;
    dispatch_ctx.on_context_notice = recordContextNoticeForDispatch;
}

fn recordContextNoticeForDispatch(raw_ctx: ?*anyopaque, notice: []const u8) error{OutOfMemory}!void {
    const state_ptr = raw_ctx orelse return;
    const state: *ContextNoticeSinkState = @ptrCast(@alignCast(state_ptr));
    const duplicate = try state.allocator.dupe(u8, notice);
    errdefer state.allocator.free(duplicate);
    try state.notices.append(state.allocator, duplicate);
}

fn typedDispatchContext(ctx: Context, arena: Allocator) tool_dispatch.DispatchContext {
    var capabilities = tool_dispatch.ToolCapabilities.for_host(
        host_capabilities.current(),
    );
    capabilities.web_search_runtime_ready =
        ctx.web_search_runtime_ready and ctx.web_search_backend != null;
    return .{
        .allocator = arena,
        .permission_mode = ctx.permission_mode,
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.access_scope,
        .change_tracker = ctx.tracker,
        .skills_dir = ctx.skills_dir,
        .skill_locations = ctx.skill_locations,
        .context_limits = ctx.context_limits,
        .ignored_list_entries = ctx.ignored_list_entries,
        .max_list_entries = ctx.max_list_entries,
        .max_read_file_bytes = ctx.max_read_file_bytes,
        .max_read_file_lines = ctx.max_read_file_lines,
        .max_read_file_line_len = ctx.max_read_file_line_len,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
        .tool_result_dir = ctx.tool_result_dir,
        .session_child_capability = ctx.session_child_capability,
        .ephemeral_command_replay = ctx.ephemeral_command_replay,
        .terminal_client = ctx.terminal_client,
        .managed_executions = ctx.managed_executions,
        .command_artifact_dir = ctx.command_artifact_dir,
        .terminal_owner_session_id = ctx.lifecycle_scope.session_id,
        .terminal_transport_role = switch (ctx.lifecycle_scope.kind) {
            .interactive, .subagent => .interactive,
            .ask => .headless,
        },
        .lifecycle_allocator = ctx.session_allocator,
        .cancel_flag = runtimeCancelFlag(ctx),
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .command_timeout_ms = ctx.command_timeout_ms,
        .ask_question_ctx = if (ctx.interactive) ctx.worker else null,
        .ask_question_batch = if (ctx.interactive) requestQuestionBatchWithWorker else null,
        .web_fetch_runtime = ctx.web_fetch_runtime,
        .web_fetch_artifact_store = ctx.web_fetch_artifact_store,
        .web_fetch_artifact_error = ctx.web_fetch_artifact_error,
        .tool_capabilities = capabilities,
        .web_search_backend = ctx.web_search_backend,
        .web_search_progress_ctx = ctx.web_search_progress_ctx,
        .on_web_search_progress = ctx.on_web_search_progress,
        .web_fetch_progress_ctx = ctx.web_fetch_progress_ctx,
        .on_web_fetch_progress = ctx.on_web_fetch_progress,
    };
}

fn terminal_lease_cleanup_dispatch_context(
    ctx: Context,
    arena: Allocator,
) tool_dispatch.DispatchContext {
    var dispatch = typedDispatchContext(ctx, arena);
    dispatch.cancel_flag = null;
    return dispatch;
}

pub fn release_agent_terminal_lease(ctx: Context, session_id: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.session_allocator);
    defer arena_state.deinit();
    return shell_impl.releaseAgentWriteLease(
        terminal_lease_cleanup_dispatch_context(ctx, arena_state.allocator()),
        session_id,
    );
}

fn requestQuestionBatchWithWorker(
    raw_ctx: ?*anyopaque,
    response_alloc: Allocator,
    entries: []const types.QuestionBatchEntry,
) Allocator.Error!?[][]u8 {
    const worker: *WorkerRuntime = @ptrCast(@alignCast(raw_ctx.?));
    const worker_alloc = std.heap.c_allocator;
    const worker_answers = try worker.requestQuestionBatchAnswerBlocking(worker_alloc, entries);
    defer freeQuestionAnswers(worker_alloc, worker_answers);

    const answers = worker_answers orelse return null;
    const copied_answers = try dupeQuestionAnswers(response_alloc, answers);
    return copied_answers;
}

fn dupeQuestionAnswers(alloc: Allocator, answers: []const []const u8) Allocator.Error![][]u8 {
    const copy = try alloc.alloc([]u8, answers.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |answer| alloc.free(answer);
    }
    while (copied < answers.len) : (copied += 1) {
        copy[copied] = try alloc.dupe(u8, answers[copied]);
    }
    return copy;
}

fn freeQuestionAnswers(alloc: Allocator, maybe_answers: ?[][]u8) void {
    const answers = maybe_answers orelse return;
    for (answers) |answer| alloc.free(answer);
    alloc.free(answers);
}

fn runtimeCancelFlag(ctx: Context) *std.atomic.Value(bool) {
    return ctx.cancel_flag orelse &ctx.worker.worker_cancel_requested;
}

fn typedDispatchContextForCall(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
) tool_dispatch.DispatchContext {
    var dispatch = typedDispatchContext(ctx, arena);
    dispatch.tool_call_id = call.id;
    dispatch.tool_call_name = call.name;
    dispatch.resolved_skill = call.resolved_skill;
    return dispatch;
}

pub fn prepareSkillCall(ctx: Context, arena: Allocator, call: ToolCall, locations: ?*const skill_contract.Locations) !skill_contract.CallPreparation {
    const tool = ctx.tool_registry.lookup(call.name) orelse return error.UnsupportedTool;
    const prepare = tool.prepare_skill_call_fn orelse return error.UnsupportedTool;
    var dispatch = typedDispatchContextForCall(ctx, arena, call);
    dispatch.skill_locations = locations;
    return prepare(dispatch, call.arguments_json);
}

const VisionProviderState = struct {
    runtime: Context,
    authorized_image_catalog: []const types.ImageAttachment,
    completion: ?ToolExecutionResult = null,
    execution_error: ?anyerror = null,
};

fn executeVisionProvider(
    maybe_ctx: ?*anyopaque,
    dispatch_ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const raw_ctx = maybe_ctx orelse unreachable;
    const state: *VisionProviderState = @ptrCast(@alignCast(raw_ctx));
    const request = input.as(tool_contracts.vision.VisionRequest);
    const execution = executeVisionRequest(
        state,
        dispatch_ctx.allocator,
        request.*,
        dispatch_ctx.execution_authority orelse {
            state.execution_error = error.InvalidVisionExecutionAuthority;
            return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
        },
    ) catch |err| {
        state.execution_error = err;
        return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
    };
    state.completion = execution;
    return switch (execution.status) {
        .success => .{ .success = @constCast(execution.model_output) },
        .failure => .{ .failure = @constCast(execution.model_output) },
    };
}

fn executeVisionRequest(
    state: *VisionProviderState,
    alloc: Allocator,
    request: tool_contracts.vision.VisionRequest,
    authority: command_admission.ToolExecutionAuthority,
) !ToolExecutionResult {
    const config: vision_executor.Config = .{
        .stream_provider = state.runtime.agent_stream_provider,
        .api_key = state.runtime.api_key,
        .credential_source = state.runtime.credential_source,
        .session_id = state.runtime.lifecycle_scope.session_id,
        .retry_count = 3,
        .cancel_flag = state.runtime.cancel_flag,
        .usage = &state.runtime.session.usage,
        .usage_allocator = state.runtime.session_allocator,
        .trace_ctx = .{},
        .output_limit = state.runtime.context_limits.image_adapter_output_bytes,
    };
    if (request.image_ids() != null) {
        if (authority != .ordinary) return error.InvalidVisionExecutionAuthority;
        return vision_executor.executeRequest(
            alloc,
            request,
            state.authorized_image_catalog,
            config,
        );
    }

    const approved_targets = switch (authority) {
        .vision_paths => |vision_authority| vision_authority.targets,
        .ordinary, .run_command, .file_mutation => return error.InvalidVisionExecutionAuthority,
    };
    const raw_paths = request.paths() orelse return error.InvalidVisionExecutionAuthority;
    if (raw_paths.len != approved_targets.len) return error.InvalidVisionExecutionAuthority;
    return executeVisionPathRequest(state, alloc, request, approved_targets, config);
}

fn executeVisionPathRequest(
    state: *VisionProviderState,
    alloc: Allocator,
    request: tool_contracts.vision.VisionRequest,
    approved_targets: []const command_admission.VisionPathExecutionTarget,
    config: vision_executor.Config,
) !ToolExecutionResult {
    const catalog = try alloc.alloc(types.ImageAttachment, approved_targets.len);
    defer alloc.free(catalog);
    var initialized: usize = 0;

    const snapshot_dir = image_attachments.createTempSnapshotDir(alloc) catch |err|
        return visionPathPreparationFailure(alloc, err);
    defer alloc.free(snapshot_dir);
    defer image_attachments.cleanupSnapshotDir(snapshot_dir);
    defer {
        image_attachments.discardImageSnapshots(alloc, catalog[0..initialized]);
        for (catalog[0..initialized]) |image| types.freeImageAttachment(alloc, image);
    }

    for (approved_targets, 0..) |target, index| {
        const image = image_attachments.captureBoundImageAttachment(
            alloc,
            target.canonical_path,
            target.identity,
            index + 1,
            snapshot_dir,
            .{ .cancel_flag = state.runtime.cancel_flag },
        ) catch |err| return visionPathPreparationFailure(alloc, err);
        catalog[index] = image;
        initialized += 1;
    }

    const image_ids = try alloc.alloc(usize, catalog.len);
    defer alloc.free(image_ids);
    for (image_ids, 0..) |*image_id, index| image_id.* = index + 1;
    const id_request: tool_contracts.vision.VisionRequest = .{
        .source = .{ .image_ids = image_ids },
        .focus = request.focus,
    };
    return vision_executor.executeRequest(alloc, id_request, catalog, config);
}

fn visionPathFailure(alloc: Allocator, err: anyerror) Allocator.Error!ToolExecutionResult {
    const details = [_]tool_result_errors.Detail{
        .{ .name = "error", .value = .{ .string = @errorName(err) } },
    };
    return .{
        .status = .failure,
        .status_detail = @errorName(err),
        .model_output = try tool_result_errors.toolExecutionFailureJson(alloc, .{
            .tool_name = "vision",
            .message = "Vision could not load an approved image path.",
            .details = &details,
            .suggestion = "Use an existing supported image under 20 MiB, or choose another image.",
        }),
    };
}

fn visionPathImagePreparationFailure(alloc: Allocator) Allocator.Error!ToolExecutionResult {
    const details = [_]tool_result_errors.Detail{
        .{ .name = "error", .value = .{ .string = "ImagePreparationFailed" } },
    };
    return .{
        .status = .failure,
        .status_detail = "ImagePreparationFailed",
        .model_output = try tool_result_errors.toolExecutionFailureJson(alloc, .{
            .tool_name = "vision",
            .message = "Vision could not prepare an approved image path.",
            .details = &details,
            .suggestion = image_attachments.image_preparation_failed_notice,
        }),
    };
}

fn visionPathPreparationFailure(
    alloc: Allocator,
    err: anyerror,
) !ToolExecutionResult {
    return switch (err) {
        error.OutOfMemory, error.Cancelled, error.TimedOut => err,
        error.ImagePreparationFailed => visionPathImagePreparationFailure(alloc),
        else => visionPathFailure(alloc, err),
    };
}

fn semanticFailure(output: []const u8) ToolExecutionResult {
    return .{ .status = .failure, .model_output = output };
}

const EffectiveCommandTimeout = struct {
    timeout_ms: usize,
    started_ms: i64,
};

fn effectiveCommandTimeout(
    request_timeout_ms: u64,
    ambient_timeout_ms: ?usize,
    ambient_started_ms: ?i64,
    now_ms: i64,
) !EffectiveCommandTimeout {
    const requested = std.math.cast(usize, request_timeout_ms) orelse
        return error.InvalidToolArguments;
    const ambient = ambient_timeout_ms orelse return .{
        .timeout_ms = requested,
        .started_ms = now_ms,
    };
    const ambient_started = ambient_started_ms orelse now_ms;
    const elapsed: usize = if (now_ms <= ambient_started)
        0
    else
        std.math.cast(usize, now_ms - ambient_started) orelse std.math.maxInt(usize);
    return .{
        .timeout_ms = @min(requested, ambient -| elapsed),
        .started_ms = now_ms,
    };
}

fn commandReplayPolicy(
    environment: command_environment.Environment,
    has_replay_capability: bool,
    interactive: bool,
    continued: ?command_replay_store.CapturePolicy,
) ?command_replay_store.CapturePolicy {
    if (continued) |policy| return policy;
    return switch (environment) {
        .workspace_clean => null,
        .legacy => if (has_replay_capability or interactive)
            .best_effort
        else
            null,
        .clean, .user => if (has_replay_capability)
            .required
        else if (interactive)
            .best_effort
        else
            null,
    };
}

fn toolRunCommand(
    ctx: Context,
    arena: Allocator,
    request: tool_dispatch.RunCommandRequest,
    authority: command_admission.CommandExecutionAuthority,
) !ToolExecutionResult {
    const command = request.command;
    const cwd = request.resolved_cwd;
    const command_ctx = command_admission.CommandContext{
        .command = command,
        .resolved_cwd = cwd,
        .target_os = builtin.target.os.tag,
        .environment = request.environment,
    };
    const timeout = try effectiveCommandTimeout(
        request.timeout_ms,
        ctx.command_timeout_ms,
        ctx.command_timeout_started_ms,
        io_mod.milliTimestamp(),
    );
    const replay_policy = commandReplayPolicy(
        request.environment,
        ctx.session_child_capability != null or
            ctx.ephemeral_command_replay != null,
        ctx.interactive,
        if (ctx.command_replay_capture) |capture| capture.policy() else null,
    );

    try execution_router.validateConfigContext(.{
        .max_command_output_bytes = ctx.max_command_output_bytes,
    }, command_ctx);
    var route = try execution_router.prepareAuthorizedRoute(arena, command_ctx, authority);
    defer route.deinit(arena);

    const compatibility_result = try tool_dispatch.dispatchRunCommandCompatibility(
        typedDispatchContext(ctx, arena),
        ctx.tool_registry,
        request,
    );
    if (compatibility_result) |compatibility| {
        if (route != .approved_shell) return error.CommandAdmissionChanged;
        const intercepted_replay = try initCommandReplayCapture(
            arena,
            replay_policy,
            ctx.max_command_output_bytes,
            ctx.max_command_output_bytes,
            ctx.session_child_capability,
            ctx.ephemeral_command_replay,
            ctx.command_replay_capture,
            ctx.command_replay_unavailable,
        );
        const capture = intercepted_replay.capture;
        var transferred = false;
        defer if (!transferred) {
            if (capture) |candidate| candidate.abort(arena);
        };
        var callback = CommandReplayCaptureCallback{
            .alloc = arena,
            .capture = capture,
        };
        const output = switch (compatibility) {
            .success => |body| body,
            .failure => |body| body,
            .rich => {
                compatibility.deinit(arena);
                return error.RichCommandOutputUnsupported;
            },
        };
        if (compatibility == .success and capture != null and output.len > 0) {
            callback.accept(
                ctx.output_chunk_lifecycle_id,
                .stdout,
                output,
            ) catch |err| {
                if (err != error.CommandOutputCaptureFailed) return err;
                return finishCommandToolResult(
                    arena,
                    capture,
                    false,
                    &transferred,
                    null,
                    try command_result_mapping.Command.outputCaptureFailure(arena),
                );
            };
        }
        if (compatibility == .success and ctx.interactive and output.len > 0) {
            try ctx.on_output_chunk(
                ctx.output_chunk_ctx,
                ctx.output_chunk_lifecycle_id,
                .stdout,
                output,
            );
        }
        return finishCommandToolResult(
            arena,
            capture,
            intercepted_replay.unavailable and
                (ctx.command_replay_unavailable or callback.had_accepted_output),
            &transferred,
            null,
            .{
                .status = switch (compatibility) {
                    .success => .success,
                    .failure => .failure,
                    .rich => unreachable,
                },
                .model_output = output,
            },
        );
    }

    const replay_init = try initCommandReplayCapture(
        arena,
        replay_policy,
        ctx.max_command_output_bytes,
        execution_router.foregroundResultComparisonLimit(
            route,
            ctx.max_command_output_bytes,
        ),
        ctx.session_child_capability,
        ctx.ephemeral_command_replay,
        ctx.command_replay_capture,
        ctx.command_replay_unavailable,
    );
    const replay_capture = replay_init.capture;
    var replay_transferred = false;
    defer if (!replay_transferred) {
        if (replay_capture) |capture| capture.abort(arena);
    };
    var replay_callback = CommandReplayCaptureCallback{
        .alloc = arena,
        .capture = replay_capture,
    };

    const routed = execution_router.executePreparedRoute(.{
        .max_command_output_bytes = ctx.max_command_output_bytes,
        .cancel_flag = runtimeCancelFlag(ctx),
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .accepted_output_chunk_ctx = if (replay_capture != null) @ptrCast(&replay_callback) else null,
        .on_accepted_output_chunk = if (replay_capture != null) CommandReplayCaptureCallback.onChunk else null,
        .callback_projection = if (ctx.interactive) .raw else .model_safe,
        .timeout_ms = timeout.timeout_ms,
        .timeout_started_ms = timeout.started_ms,
        .command_artifact_capability = ctx.session_child_capability,
        .command_artifact_dir = ctx.command_artifact_dir,
    }, arena, route) catch |err| {
        if (err == error.TimeoutExpired) {
            return finishCommandToolResult(
                arena,
                replay_capture,
                replay_init.unavailable and
                    (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
                &replay_transferred,
                null,
                try command_result_mapping.Command.timeoutFailure(
                    arena,
                    command,
                    cwd,
                    timeout.timeout_ms,
                    timeout.started_ms,
                ),
            );
        }
        if (err == error.CommandOutputCaptureFailed) return finishCommandToolResult(
            arena,
            replay_capture,
            false,
            &replay_transferred,
            null,
            try command_result_mapping.Command.outputCaptureFailure(arena),
        );
        if (err == error.Cancelled and runtimeCancelFlag(ctx).load(.seq_cst)) {
            return finishCommandToolResult(
                arena,
                replay_capture,
                replay_init.unavailable and
                    (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
                &replay_transferred,
                null,
                .{
                    .status = .failure,
                    .cancelled = true,
                    .model_output = "command cancelled\n",
                },
            );
        }
        return err;
    };
    const result = routed.result;

    if (try command_result_mapping.Command.cancelledFailure(arena, result)) |cancelled| {
        return finishCommandToolResult(
            arena,
            replay_capture,
            replay_init.unavailable and
                (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
            &replay_transferred,
            result,
            cancelled,
        );
    }

    if (try command_result_mapping.Command.nonZeroFailure(arena, result)) |failure| {
        return finishCommandToolResult(
            arena,
            replay_capture,
            replay_init.unavailable and
                (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
            &replay_transferred,
            result,
            failure,
        );
    }

    return finishCommandToolResult(
        arena,
        replay_capture,
        replay_init.unavailable and
            (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
        &replay_transferred,
        result,
        .{
            .model_output = result.output,
            .command_result_json = if (result.command_result) |command_result| try command_result.toJson(arena) else null,
        },
    );
}

const CommandReplayCaptureCallback = struct {
    alloc: Allocator,
    capture: ?*command_replay_store.Capture,
    had_accepted_output: bool = false,

    fn onChunk(
        raw_ctx: *anyopaque,
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_contract.CommandOutputStream,
        chunk: []const u8,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        return self.accept(lifecycle_id, stream, chunk);
    }

    fn accept(
        self: *@This(),
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_contract.CommandOutputStream,
        chunk: []const u8,
    ) !void {
        _ = lifecycle_id;
        if (chunk.len == 0) return;
        self.had_accepted_output = true;
        if (self.capture) |capture| {
            switch (capture.policy()) {
                .required => try capture.appendAcceptedRequired(
                    self.alloc,
                    stream,
                    chunk,
                ),
                .best_effort => capture.appendAccepted(self.alloc, stream, chunk),
            }
        }
    }
};

const CommandReplayCaptureInit = struct {
    capture: ?*command_replay_store.Capture = null,
    unavailable: bool = false,
};

fn initCommandReplayCapture(
    arena: Allocator,
    replay_policy: ?command_replay_store.CapturePolicy,
    inline_limit: usize,
    comparison_limit: usize,
    capability: ?*session_child_store.SessionChildCapability,
    ephemeral_store: ?*command_replay_store.EphemeralStore,
    continued_capture: ?*command_replay_store.Capture,
    continued_unavailable: bool,
) !CommandReplayCaptureInit {
    const policy = replay_policy orelse return .{};
    if (continued_unavailable) {
        if (policy == .required) return error.CommandOutputCaptureFailed;
        return .{ .unavailable = true };
    }
    if (continued_capture) |capture| {
        capture.setComparisonLimit(comparison_limit);
        return .{ .capture = capture };
    }
    const capture_inline_limit = if (policy == .required) 0 else inline_limit;
    const capture = (if (capability) |saved|
        command_replay_store.Capture.create(arena, capture_inline_limit, saved)
    else if (ephemeral_store) |ephemeral|
        command_replay_store.Capture.createEphemeral(arena, capture_inline_limit, ephemeral)
    else
        command_replay_store.Capture.create(arena, capture_inline_limit, null)) catch |err| {
        if (policy == .required) return err;
        debug_trace.logf(
            "session",
            "command replay capture initialization unavailable err={s}",
            .{@errorName(err)},
        );
        return .{ .unavailable = true };
    };
    capture.setPolicyBeforeCapture(policy);
    capture.setComparisonLimit(comparison_limit);
    return .{ .capture = capture };
}

fn finishCommandToolResult(
    arena: Allocator,
    capture: ?*command_replay_store.Capture,
    replay_unavailable: bool,
    replay_transferred: *bool,
    process_result: ?command_contract.RunCommandResult,
    result: ToolExecutionResult,
) !ToolExecutionResult {
    var owned = result;
    if (capture) |candidate| switch (candidate.policy()) {
        .required => candidate.sealRequired(arena) catch {
            owned = try command_result_mapping.Command.outputCaptureFailure(arena);
        },
        .best_effort => {},
    };
    if (process_result) |command_result| {
        if (commandProcessPresentation(command_result)) |presentation| {
            var memory = owned.tool_result_memory orelse types.ToolResultMemory{};
            memory.command_process_presentation = presentation;
            owned.tool_result_memory = memory;
        }
    }
    if (replay_unavailable) {
        var memory = owned.tool_result_memory orelse types.ToolResultMemory{};
        memory.command_output_replay = .unavailable;
        owned.tool_result_memory = memory;
    }
    owned.command_replay_capture = capture;
    if (capture != null) replay_transferred.* = true;
    return owned;
}

fn commandProcessPresentation(
    result: command_contract.RunCommandResult,
) ?types.CommandProcessPresentation {
    const command_result = result.command_result orelse return null;
    const foreground = command_result;
    if (foreground.timed_out) return .timed_out;
    if (foreground.signal) |signal| return .{ .signal = signal };
    if (foreground.exit_code) |exit_code| {
        if (exit_code != 0) return .{ .exit_code = exit_code };
    }
    return null;
}

const SubagentProviderState = struct {
    runtime: Context,
    call: ToolCall,
    completion_sink: *?types.SubagentStatus,
};

fn requestDerivedSubagentSessionTitle(alloc: Allocator, call: ToolCall) Allocator.Error!?[]u8 {
    const action = try tool_presentation.subagentAction(alloc, call, .identity) orelse return null;
    alloc.free(action.detail);
    return action.label;
}

const SubagentProgressBridge = struct {
    alloc: Allocator,
    call: ToolCall,
    renderer: types.SubagentStatusRenderer,
    progress_ctx: *anyopaque,
    progress_fn: *const fn (*anyopaque, types.ToolLifecycleId, []const u8) void,
    lifecycle_id: types.ToolLifecycleId,

    fn init(alloc: Allocator, ctx: Context, call: ToolCall) ?SubagentProgressBridge {
        return .{
            .alloc = alloc,
            .call = call,
            .renderer = ctx.subagent_status_renderer orelse return null,
            .progress_ctx = ctx.tool_progress_ctx orelse return null,
            .progress_fn = ctx.on_tool_progress orelse return null,
            .lifecycle_id = ctx.output_chunk_lifecycle_id orelse return null,
        };
    }

    fn sink(self: *SubagentProgressBridge) subagent_tool_host.ProgressSink {
        return .{ .context = self, .publish_fn = publish };
    }

    fn publish(raw: *anyopaque, status: types.SubagentStatus) void {
        const self: *SubagentProgressBridge = @ptrCast(@alignCast(raw));
        var rendered_status = status;
        const session_title = requestDerivedSubagentSessionTitle(self.alloc, self.call) catch null;
        defer if (session_title) |title| self.alloc.free(title);
        rendered_status.session_title = session_title;
        var status_buf: [256]u8 = undefined;
        const status_line = self.renderer.render(&status_buf, rendered_status);
        if (status_line.len == 0) return;
        const first_line = (tool_presentation.formatSubagentPlainAction(self.alloc, self.call, .active) catch return) orelse return;
        defer self.alloc.free(first_line);
        const row = self.alloc.print("● {s}\n  {s}", .{ first_line, status_line }) catch return;
        defer self.alloc.free(row);
        self.progress_fn(self.progress_ctx, self.lifecycle_id, row);
    }
};

fn subagentProviderFailure(
    alloc: Allocator,
    error_code: []const u8,
) Allocator.Error!subagent_tool_provider.Result {
    const body = subagent_model_contract.encodeResultAlloc(alloc, .{
        .ok = false,
        .error_code = error_code,
    }) catch return error.OutOfMemory;
    return .{ .status = .failure, .body = body };
}

fn executeSubagentProvider(
    raw_context: ?*anyopaque,
    arena: Allocator,
    request: *subagent_model_contract.Request,
    invocation_id: []const u8,
) subagent_tool_provider.ExecuteError!subagent_tool_provider.Result {
    const state: *SubagentProviderState = @ptrCast(@alignCast(raw_context.?));
    const ctx = state.runtime;
    const host = ctx.subagent_host orelse
        return subagentProviderFailure(arena, "host_unavailable");
    const caller_id = ctx.subagent_caller_id orelse
        return subagentProviderFailure(arena, "caller_unavailable");
    const identity_epoch = host.issueOperationIdentity(invocation_id);
    var progress_bridge = SubagentProgressBridge.init(arena, ctx, state.call);
    const output = host.executeManaged(arena, request, .{
        .caller_id = caller_id,
        .invocation_id = invocation_id,
        .parent_permission_mode = ctx.permission_mode,
        .root_user_intent_context = ctx.root_user_intent_context,
        .root_user_messages = ctx.root_user_messages,
        .root_user_evidence_complete = ctx.root_user_evidence_complete,
        .defaults = .{
            .provider = ctx.provider,
            .model = ctx.model,
            .effort = ctx.effort,
            .fast_mode = ctx.fast_mode,
            .ultrafast_mode = ctx.ultrafast_mode,
            .conversation_language = ctx.session.languageSnapshot(),
        },
        .max_result_bytes = ctx.max_tool_result_bytes,
        .timestamp_ms = io_mod.milliTimestamp(),
        .identity_epoch = identity_epoch,
        .cancel_flag = runtimeCancelFlag(ctx),
        .steering_worker = if (ctx.interactive) ctx.worker else null,
        .progress = if (progress_bridge) |*bridge| bridge.sink() else null,
        .model_capability_resolver = ctx.model_capability_resolver,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return error.Cancelled;
        return subagentProviderFailure(arena, "host_failure");
    };
    if (output.final_status) |status_value| {
        var status = status_value;
        status.session_title = requestDerivedSubagentSessionTitle(arena, state.call) catch null;
        state.completion_sink.* = status;
    }
    return .{
        .status = if (output.success) .success else .failure,
        .body = output.body,
    };
}

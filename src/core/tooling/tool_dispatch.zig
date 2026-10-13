const std = @import("std");
const skill_contract = @import("../skills/skill_contract.zig");
const command_admission = @import("../permissions/command_admission.zig");
const core_permissions = @import("../permissions/permissions.zig");
const core_types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const command_environment = @import("../execution/command_environment.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const message = @import("../shared/message.zig");
const mod_registry = @import("../mods/registry.zig");
const permission_gate = @import("../permissions/permission_gate.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const read_tracker_mod = @import("../workspace/read_tracker.zig");
const session_child_store = @import("../session/session_child_store.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const command_runner = @import("../execution/command_runner.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const subagent_tool_provider = @import("../subagent/tool_provider.zig");
const text_utils = @import("../shared/text_utils.zig");
const web_fetch_runtime = @import("web_fetch_runtime.zig");
const web_fetch_artifacts = @import("../session/web_fetch_artifacts.zig");
const model_tool_schema = @import("model_tool_schema.zig");
const host = @import("../hosts/host.zig");
const tool_result_errors = @import("tool_result_errors.zig");
const tool_result_limits = @import("tool_result_limits.zig");
const web_search_contract = @import("web_search_contract.zig");
const context_limits = @import("../config/context_limits.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const terminal_contracts = @import("../terminal/contracts.zig");
const tool_args = @import("tool_args.zig");
const result_commit = @import("result_commit.zig");

const Allocator = std.mem.Allocator;

pub const default_ignored_list_entries = [_][]const u8{
    ".git",
    ".zig-cache",
    "zig-out",
    "node_modules",
    ".next",
    "dist",
    "build",
    "coverage",
};
pub const default_max_list_entries: usize = 100;
pub const default_max_read_file_bytes: usize = 50 * 1024;
pub const default_max_read_file_lines: usize = 400;
pub const default_max_read_file_line_len: usize = 2000;

pub const web_search_unavailable_message = "web_search is unavailable: no local runtime with a configured Gateway transport policy is installed";
pub const terminal_unavailable_message =
    "{\"error\":{\"tool\":\"shell\",\"code\":\"unsupported_host\",\"retryable\":false}}";
const terminal_saved_session_required_message =
    "TTY shell actions require a saved fx session.";
const terminal_saved_session_required_suggestion =
    "Use shell.run with tty=false, or rerun without --no-save.";

pub const ToolCapabilities = struct {
    web_search_runtime_ready: bool = false,
    terminal: host.TerminalSupport = .unsupported,

    pub fn for_host(host_capabilities: host.Capabilities) ToolCapabilities {
        return .{ .terminal = host_capabilities.terminal };
    }

    pub fn terminalAvailable(self: ToolCapabilities) bool {
        return self.terminal.isSupported();
    }
};

pub const WebSearchProgressFn = *const fn (*anyopaque, []const u8, core_types.WebSearchProgress) void;
pub const WebFetchProgressFn = *const fn (*anyopaque, []const u8, core_types.WebFetchProgress) void;

pub const WebSearchBackendFn = *const fn (
    *anyopaque,
    DispatchContext,
    web_search_contract.Request,
) anyerror!web_search_contract.ExecutionOutput;

pub const WebSearchBackend = struct {
    ctx: *anyopaque,
    execute_fn: WebSearchBackendFn,

    pub fn execute(
        self: WebSearchBackend,
        ctx: DispatchContext,
        request: web_search_contract.Request,
    ) !web_search_contract.ExecutionOutput {
        return self.execute_fn(self.ctx, ctx, request);
    }
};

pub const VisionProviderFn = *const fn (
    ?*anyopaque,
    DispatchContext,
    ToolInput,
) DispatchError!ToolResult;

pub const VisionProvider = struct {
    ctx: ?*anyopaque = null,
    execute_fn: VisionProviderFn,

    pub fn execute(
        self: VisionProvider,
        ctx: DispatchContext,
        input: ToolInput,
    ) DispatchError!ToolResult {
        return self.execute_fn(self.ctx, ctx, input);
    }
};

pub const ContextNoticeSinkFn = *const fn (?*anyopaque, []const u8) error{OutOfMemory}!void;

/// Erased, owned typed input decoded by a concrete tool.
pub const ToolInput = struct {
    ptr: *anyopaque,
    deinit_fn: *const fn (ptr: *anyopaque, alloc: Allocator) void,

    /// Casts the erased input back to the tool's concrete input type.
    pub fn as(self: ToolInput, comptime T: type) *T {
        return @ptrCast(@alignCast(self.ptr));
    }

    /// Frees the concrete input through the tool-provided destructor.
    pub fn deinit(self: ToolInput, alloc: Allocator) void {
        self.deinit_fn(self.ptr, alloc);
    }
};

/// Owned success or failure text returned by a tool call.
pub const ToolResult = union(enum) {
    success: []u8,
    failure: []u8,
    rich: struct { text: []u8, images: []core_types.ToolImage, is_error: bool = false },

    /// Frees the owned result text and media.
    pub fn deinit(self: ToolResult, alloc: Allocator) void {
        switch (self) {
            .success => |body| alloc.free(body),
            .failure => |body| alloc.free(body),
            .rich => |content| {
                alloc.free(content.text);
                core_types.freeToolImages(alloc, content.images);
            },
        }
    }

    pub fn intoAuthorized(self: ToolResult) AuthorizedDispatchResult {
        return switch (self) {
            .success => |body| .{ .status = .success, .body = body },
            .failure => |body| .{ .status = .failure, .body = body },
            .rich => |content| .{ .status = if (content.is_error) .failure else .success, .body = content.text, .images = content.images },
        };
    }
};

pub const ModelContentKind = enum { ordinary, complete_skill };

/// Result of decoding a raw JSON argument buffer into a typed input.
pub const DecodeResult = union(enum) {
    input: ToolInput,
    failure: []u8,
};

/// Errors that stop local dispatch before a model-recoverable result is built.
pub const DispatchError = std.json.ParseError(std.json.Scanner) || error{
    OutOfMemory,
    InvalidToolArguments,
    InvalidPath,
    FileNotFound,
    HomeNotSet,
    PathOutsideWorkspace,
    WorkspaceUnavailable,
    Cancelled,
};

/// Core-owned execution backend used by the registered run_command callback.
pub const RunCommandRequest = struct {
    command: []const u8,
    resolved_cwd: []const u8,
    environment: command_environment.Environment,
    timeout_ms: u64,
};

pub const RunCommandBackendFn = *const fn (
    ?*anyopaque,
    DispatchContext,
    RunCommandRequest,
) DispatchError!ToolResult;

pub const RunCommandBackend = struct {
    ctx: ?*anyopaque = null,
    execute_fn: RunCommandBackendFn,

    pub fn execute(
        self: RunCommandBackend,
        ctx: DispatchContext,
        request: RunCommandRequest,
    ) DispatchError!ToolResult {
        return self.execute_fn(self.ctx, ctx, request);
    }
};

/// Context shared by core tool dispatch, validation, and execution.
pub const DispatchContext = struct {
    allocator: Allocator,
    permission_mode: permission_gate.PermissionMode = .ask,
    permission_decider: ?PermissionDecider = null,
    execution_authority: ?command_admission.ToolExecutionAuthority = null,
    workspace_root: []const u8 = "",
    access_scope: ?workspace_access.AccessScope = null,
    ignored_list_entries: []const []const u8 = &default_ignored_list_entries,
    max_list_entries: usize = default_max_list_entries,
    max_read_file_bytes: usize = default_max_read_file_bytes,
    max_read_file_lines: usize = default_max_read_file_lines,
    max_read_file_line_len: usize = default_max_read_file_line_len,
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    max_command_output_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    skills_dir: []const u8 = "",
    skill_locations: ?*const skill_contract.Locations = null,
    resolved_skill: ?*const skill_contract.PreparedSkill = null,
    context_limits: context_limits.Values = .{},
    read_tracker: ?*read_tracker_mod.ReadTracker = null,
    change_tracker: ?*change_tracker.ChangeTracker = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    output_chunk_lifecycle_id: ?core_types.ToolLifecycleId = null,
    output_chunk_ctx: ?*anyopaque = null,
    on_output_chunk: ?command_runner.CommandOutputCallback = null,
    command_artifact_dir: ?[]const u8 = null,
    managed_executions: ?*managed_execution.Runtime = null,
    tool_result_dir: ?[]const u8 = null,
    session_child_capability: ?*session_child_store.SessionChildCapability = null,
    ephemeral_command_replay: ?*command_replay_store.EphemeralStore = null,
    terminal_client: ?*terminal_client_runtime.Runtime = null,
    terminal_owner_session_id: ?[]const u8 = null,
    terminal_transport_role: terminal_contracts.TransportRole = .interactive,
    lifecycle_allocator: Allocator = std.heap.c_allocator,
    command_timeout_ms: ?usize = null,
    captured_command_host: command_environment.Host = .native,
    run_command_backend: ?RunCommandBackend = null,
    subagent_provider: ?subagent_tool_provider.Provider = null,
    vision_provider: ?VisionProvider = null,
    ask_question_ctx: ?*anyopaque = null,
    ask_question_batch: ?AskQuestionBatchFn = null,
    tool_capabilities: ToolCapabilities = .{},
    web_fetch_runtime: ?*web_fetch_runtime.Runtime = null,
    web_fetch_artifact_store: ?*web_fetch_artifacts.Store = null,
    web_fetch_artifact_error: ?anyerror = null,
    web_search_backend: ?WebSearchBackend = null,
    tool_call_id: []const u8 = "",
    tool_call_name: []const u8 = "",
    web_search_progress_ctx: ?*anyopaque = null,
    on_web_search_progress: ?WebSearchProgressFn = null,
    web_fetch_progress_ctx: ?*anyopaque = null,
    on_web_fetch_progress: ?WebFetchProgressFn = null,
    context_notice_ctx: ?*anyopaque = null,
    on_context_notice: ?ContextNoticeSinkFn = null,
    inner_usage_sink: ?*?core_types.ToolUsage = null,
    web_search_completion_sink: ?*?core_types.WebSearchCompletion = null,
    web_fetch_completion_sink: ?*?core_types.WebFetchCompletion = null,
    tool_result_memory_sink: ?*?core_types.ToolResultMemory = null,
    model_content_kind_sink: ?*ModelContentKind = null,
    command_result_json_sink: ?*?[]const u8 = null,
    result_commit_sink: ?*?result_commit.Token = null,
};

/// Function pointer used by ask_user_question to request live user answers.
pub const AskQuestionBatchFn = *const fn (
    ?*anyopaque,
    Allocator,
    []const core_types.QuestionBatchEntry,
) anyerror!?[][]u8;

/// Function pointer used to override permission decisions in tests and callers.
pub const PermissionDecider = *const fn (*const Tool, ToolInput, DispatchContext) permission_gate.Decision;

/// Function pointer that decodes JSON arguments into a concrete input.
pub const DecodeFn = *const fn (DispatchContext, []const u8) DispatchError!DecodeResult;

/// Optional pure validation step run before the permission gate.
pub const ValidateFn = *const fn (DispatchContext, ToolInput) DispatchError!?[]u8;

/// Function pointer that executes a validated and allowed tool input.
pub const CallFn = *const fn (DispatchContext, ToolInput) DispatchError!ToolResult;

pub const RunCommandCompatibility = struct {
    matches: *const fn ([]const u8) bool,
    /// Returns success or failure text owned by `ctx.allocator`.
    execute: *const fn (DispatchContext, []const u8) DispatchError!ToolResult,
};

/// Consumes a decoded tool input and transfers its owned fields into Core's
/// canonical file-mutation contract. The caller owns the returned input and
/// must not deinitialize the consumed ToolInput.
pub const TakeFileMutationInputFn = *const fn (
    ToolInput,
    Allocator,
) file_mutation_contract.FileMutationInput;

/// Function pointer classifying whether an input is read-only.
pub const ReadsOnlyFn = *const fn (ToolInput) bool;

/// Function pointer classifying whether an input is irreversible.
pub const IrreversibleFn = *const fn (ToolInput) bool;

pub const ProviderAdvertisementError = std.mem.Allocator.Error || std.Io.Writer.Error || error{
    InvalidWebSearchBackend,
    ConflictingDomainFilters,
    InvalidGatewayAdvertisement,
};

pub const WriteProviderAdvertisementFn = *const fn (
    std.mem.Allocator,
    *std.Io.Writer,
) ProviderAdvertisementError!void;

pub const LabelArgKind = enum {
    none,
    name,
    path,
    pattern,
    url,
    command,
    description,
    source,
    resource,
    action,
    query,
    server,
    selector,
    session_id,
};

pub const PermissionTargetKind = core_permissions.PermissionTargetKind;

pub const ExecutorKind = enum {
    glob_files,
    grep_files,
    read_file,
    read_tool_result,
    write_file,
    edit_file,
    web_fetch,
    web_search,
    run_command,
    terminal,
    skill,
    install_skill,
    subagent,
    capability_search,
    ask_user_question,
    vision,
};

pub const ApprovalPolicy = enum {
    standard,
    ask_only,
    auto_deny_on_ask,
};

pub const RuntimeProviderKind = enum {
    none,
    run_command,
    subagent,
    vision,
};

pub const CapturedCommandFn = *const fn (ToolInput) bool;
pub const ProcessLocalFn = *const fn (ToolInput) bool;

pub const CallPresentation = struct {
    activity_kind: core_types.ToolActivityKind,
    action_label: []const u8,
    completed_action_label: []const u8,
    label_arg_kind: LabelArgKind,
    label_arg_default: []const u8,
};

/// Optional call-aware presentation override. Returned strings must outlive the
/// parsed arguments supplied to the callback.
pub const PresentationFn = *const fn (std.json.ObjectMap) ?CallPresentation;

/// Descriptor for a core tool's model-facing metadata and runtime callbacks.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    model_schema: model_tool_schema.FunctionSchema,
    model_visible: bool = true,
    /// fx's own discovery or bookkeeping step rather than work the user asked
    /// for. Hosts may hide these calls.
    internal: bool = false,
    write_provider_advertisement_fn: ?WriteProviderAdvertisementFn = null,
    /// Set when the provider runs the tool instead of fx dispatch. Such a tool
    /// never reaches a call-time permission check, so advertisement is its only
    /// enforcement point and requires an already-settled allow.
    provider_executed: bool = false,
    executor_kind: ExecutorKind = .read_file,
    activity_kind: core_types.ToolActivityKind = .read,
    requires_approval: bool = false,
    approval_policy: ApprovalPolicy = .standard,
    action_label: []const u8 = "Working",
    completed_action_label: []const u8 = "Completed",
    label_arg_kind: LabelArgKind = .none,
    label_arg_default: []const u8 = "",
    presentation_fn: ?PresentationFn = null,
    permission_target_kind: PermissionTargetKind = .none,
    decode: DecodeFn,
    validate: ?ValidateFn = null,
    call: CallFn,
    runtime_provider: RuntimeProviderKind = .none,
    captured_command_host: command_environment.Host = .native,
    captured_command_action: ?[]const u8 = null,
    captured_command_fn: ?CapturedCommandFn = null,
    process_local_fn: ?ProcessLocalFn = null,
    cancel_if_requested_after_call: bool = false,
    run_command_compatibility: ?RunCommandCompatibility = null,
    take_file_mutation_input_fn: ?TakeFileMutationInputFn = null,
    prepare_skill_call_fn: ?*const fn (DispatchContext, []const u8) DispatchError!skill_contract.CallPreparation = null,
    reads_only_fn: ReadsOnlyFn,
    irreversible_fn: IrreversibleFn,
};

pub const Registry = mod_registry.ToolRegistry(Tool);

pub const RunCommandCompatibilityMatch = struct {
    tool: *const Tool,
    compatibility: RunCommandCompatibility,
};

pub const RunCommandCompatibilityMatchError = error{AmbiguousRunCommandCompatibility};

pub fn matchRunCommandCompatibility(
    registry: Registry,
    command: []const u8,
) RunCommandCompatibilityMatchError!?RunCommandCompatibilityMatch {
    var matched: ?RunCommandCompatibilityMatch = null;
    for (registry.tools) |*tool| {
        const compatibility = tool.run_command_compatibility orelse continue;
        if (!compatibility.matches(command)) continue;
        if (matched != null) return error.AmbiguousRunCommandCompatibility;
        matched = .{
            .tool = tool,
            .compatibility = compatibility,
        };
    }
    return matched;
}

pub fn dispatchRunCommandCompatibility(
    ctx: DispatchContext,
    registry: Registry,
    request: RunCommandRequest,
) (DispatchError || RunCommandCompatibilityMatchError)!?ToolResult {
    if (std.meta.activeTag(request.environment) != .legacy) return null;
    const matched = (try matchRunCommandCompatibility(
        registry,
        request.command,
    )) orelse return null;
    if (std.mem.findAny(u8, request.command, "|;&\n") != null) return null;
    return try matched.compatibility.execute(ctx, request.command);
}

pub fn toolActivityKind(registry: Registry, tool_name: []const u8) core_types.ToolActivityKind {
    return if (registry.lookup(tool_name)) |tool| tool.activity_kind else .command;
}

pub fn staticPresentation(tool: Tool) CallPresentation {
    return .{
        .activity_kind = tool.activity_kind,
        .action_label = tool.action_label,
        .completed_action_label = tool.completed_action_label,
        .label_arg_kind = tool.label_arg_kind,
        .label_arg_default = tool.label_arg_default,
    };
}

pub fn presentationForArgs(tool: Tool, args: std.json.ObjectMap) CallPresentation {
    if (tool.presentation_fn) |resolve| {
        if (resolve(args)) |presentation| return presentation;
    }
    return staticPresentation(tool);
}

pub fn toolCallPresentation(
    alloc: Allocator,
    registry: Registry,
    call: core_types.ToolCall,
) ?CallPresentation {
    const tool = registry.lookup(call.name) orelse return null;
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const args = tool_args.parseToolArgsObject(
        scratch_state.allocator(),
        call.arguments_json,
    ) catch return staticPresentation(tool.*);
    return presentationForArgs(tool.*, args);
}

pub fn toolActivityKindForCall(
    alloc: Allocator,
    registry: Registry,
    call: core_types.ToolCall,
) core_types.ToolActivityKind {
    const presentation = toolCallPresentation(alloc, registry, call) orelse
        return .command;
    return presentation.activity_kind;
}

pub fn toolLabelValue(tool: Tool, args: std.json.ObjectMap) ?[]const u8 {
    return labelValueForKind(tool.label_arg_kind, args);
}

pub fn presentationLabelValue(presentation: CallPresentation, args: std.json.ObjectMap) ?[]const u8 {
    return labelValueForKind(presentation.label_arg_kind, args);
}

fn labelValueForKind(kind: LabelArgKind, args: std.json.ObjectMap) ?[]const u8 {
    return switch (kind) {
        .none => null,
        .name => optionalStringArg(args, "name"),
        .path => optionalStringArg(args, "path"),
        .pattern => optionalStringArg(args, "pattern"),
        .url => optionalStringArg(args, "url"),
        .command => optionalStringArg(args, "command"),
        .description => optionalStringArg(args, "description"),
        .source => optionalStringArg(args, "source"),
        .resource => optionalStringArg(args, "resource"),
        .action => optionalStringArg(args, "action"),
        .query => optionalStringArg(args, "query"),
        .server => optionalStringArg(args, "server"),
        .selector => optionalStringArg(args, "selector"),
        .session_id => optionalStringArg(args, "session_id"),
    };
}

fn optionalStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = args.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

/// Side-effect-free admission result for a registered tool call.
pub const ValidationResult = union(enum) {
    not_registered,
    valid,
    failure: []u8,
};

const ValidatedToolCall = union(enum) {
    not_registered,
    failure: []u8,
    input: struct {
        tool: *const Tool,
        value: ToolInput,
    },
};

/// Decodes and validates registered input without resolving permission or executing the tool.
pub fn validateRegisteredToolCall(ctx: DispatchContext, registry: Registry, call: message.ToolCall) DispatchError!ValidationResult {
    const validated = try decodeAndValidateRegisteredToolCall(ctx, registry, call);
    return switch (validated) {
        .not_registered => .not_registered,
        .failure => |reason| .{ .failure = reason },
        .input => |input| blk: {
            input.value.deinit(ctx.allocator);
            break :blk .valid;
        },
    };
}

fn decodeAndValidateRegisteredToolCall(ctx: DispatchContext, registry: Registry, call: message.ToolCall) DispatchError!ValidatedToolCall {
    const tool = registry.lookup(call.name) orelse return .not_registered;
    return decodeAndValidateToolCall(ctx, tool, call.arguments_json);
}

fn decodeAndValidateToolCall(
    ctx: DispatchContext,
    tool: *const Tool,
    arguments_json: []const u8,
) DispatchError!ValidatedToolCall {
    const decoded = try tool.decode(ctx, arguments_json);
    return switch (decoded) {
        .failure => |reason| .{ .failure = reason },
        .input => |input| blk: {
            errdefer input.deinit(ctx.allocator);
            if (tool.validate) |validate| {
                if (try validate(ctx, input)) |reason| {
                    input.deinit(ctx.allocator);
                    break :blk .{ .failure = reason };
                }
            }
            break :blk .{ .input = .{ .tool = tool, .value = input } };
        },
    };
}

/// Owned tool-result message body produced by dispatch.
pub const DispatchResult = struct {
    model_content_kind: ModelContentKind = .ordinary,
    status: Status,
    body: []u8,
    images: []core_types.ToolImage = &.{},
    status_detail: ?[]u8 = null,
    inner_usage: ?core_types.ToolUsage = null,
    web_search_completion: ?core_types.WebSearchCompletion = null,
    web_fetch_completion: ?core_types.WebFetchCompletion = null,
    tool_result_memory: ?core_types.ToolResultMemory = null,
    command_result_json: ?[]const u8 = null,

    /// Tool-result status used only by tests and diagnostics.
    pub const Status = enum {
        success,
        failure,
    };

    /// Frees the owned tool-result body and optional diagnostic detail.
    pub fn deinit(self: DispatchResult, alloc: Allocator) void {
        alloc.free(self.body);
        core_types.freeToolImages(alloc, self.images);
        if (self.status_detail) |detail| alloc.free(detail);
        if (self.command_result_json) |json| alloc.free(@constCast(json));
        if (self.tool_result_memory) |memory| {
            if (memory.command_output_replay) |replay| switch (replay) {
                .available => |descriptor| alloc.free(@constCast(descriptor.handle)),
                .unavailable => {},
            };
        }
    }
};

/// Owned authorized-dispatch result. Runtime metadata is published through
/// the caller-provided sinks in `DispatchContext` instead of being copied into
/// this transport result.
pub const AuthorizedDispatchResult = struct {
    status: DispatchResult.Status,
    body: []u8,
    images: []core_types.ToolImage = &.{},

    pub fn deinit(self: AuthorizedDispatchResult, alloc: Allocator) void {
        alloc.free(self.body);
        core_types.freeToolImages(alloc, self.images);
    }
};

/// Runs one already-authorized registered tool call through lookup, validation, and call.
pub fn dispatchAuthorizedToolCall(
    ctx: DispatchContext,
    registry: Registry,
    call: message.ToolCall,
) DispatchError!AuthorizedDispatchResult {
    const validated = try decodeAndValidateRegisteredToolCall(ctx, registry, call);
    switch (validated) {
        .not_registered => return .{ .status = .failure, .body = try ctx.allocator.print("unknown tool: {s}", .{call.name}) },
        .failure => |reason| return .{ .status = .failure, .body = reason },
        .input => |input| {
            defer input.value.deinit(ctx.allocator);

            const result = try input.tool.call(ctx, input.value);
            if (input.tool.cancel_if_requested_after_call and
                ctx.cancel_flag != null and
                ctx.cancel_flag.?.load(.seq_cst))
            {
                result.deinit(ctx.allocator);
                return error.Cancelled;
            }
            return result.intoAuthorized();
        },
    }
}

pub fn reportWebFetchCompletion(ctx: DispatchContext, completion: core_types.WebFetchCompletion) void {
    const sink = ctx.web_fetch_completion_sink orelse return;
    sink.* = completion;
}

pub fn reportToolResultMemory(ctx: DispatchContext, memory: core_types.ToolResultMemory) void {
    const sink = ctx.tool_result_memory_sink orelse return;
    sink.* = memory;
}

pub fn reportCommandResultJson(ctx: DispatchContext, json: []const u8) void {
    const sink = ctx.command_result_json_sink orelse return;
    sink.* = json;
}

pub fn reportResultCommit(ctx: DispatchContext, token: result_commit.Token) void {
    const sink = ctx.result_commit_sink orelse return;
    sink.* = token;
}

pub fn reportContextNotice(ctx: DispatchContext, notice: []const u8) error{OutOfMemory}!void {
    const sink = ctx.on_context_notice orelse return;
    try sink(ctx.context_notice_ctx, notice);
}

pub fn localToolAvailabilityFailure(
    ctx: DispatchContext,
    tool: *const Tool,
    input: ToolInput,
) DispatchError!?[]u8 {
    return switch (tool.executor_kind) {
        .web_search => if (ctx.tool_capabilities.web_search_runtime_ready)
            null
        else
            try ctx.allocator.dupe(u8, web_search_unavailable_message),
        .terminal => if (tool.captured_command_fn != null and tool.captured_command_fn.?(input))
            null
        else if (tool.process_local_fn != null and
            tool.process_local_fn.?(input) and
            ctx.managed_executions != null)
            null
        else if (!ctx.tool_capabilities.terminalAvailable())
            try ctx.allocator.dupe(u8, terminal_unavailable_message)
        else if (ctx.session_child_capability != null)
            null
        else
            try tool_result_errors.toolExecutionFailureJson(ctx.allocator, .{
                .tool_name = tool.name,
                .message = terminal_saved_session_required_message,
                .suggestion = terminal_saved_session_required_suggestion,
            }),
        else => null,
    };
}

pub fn localToolAvailabilityFailureForCall(
    ctx: DispatchContext,
    registry: Registry,
    call: message.ToolCall,
) DispatchError!?[]u8 {
    const validated = try decodeAndValidateRegisteredToolCall(ctx, registry, call);
    return switch (validated) {
        .not_registered, .failure => null,
        .input => |input| blk: {
            defer input.value.deinit(ctx.allocator);
            break :blk try localToolAvailabilityFailure(ctx, input.tool, input.value);
        },
    };
}

fn failure(body: []u8) DispatchResult {
    return .{ .status = .failure, .body = body };
}

pub fn traceDeniedWebSearch(ctx: debug_trace.TraceContext, call: message.ToolCall, reason: core_types.ToolPermissionDenialReason) void {
    if (!core_permissions.isWebSearchToolName(call.name)) return;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, arena, call.arguments_json, .{}) catch {
        debug_trace.eventf("permission", "web_search_denied", ctx, "call_id={s} tool_name={s} query=<invalid-json> reason={s}", .{ call.id, call.name, @tagName(reason) });
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const query_value = parsed.value.object.get("query") orelse return;
    if (query_value != .string) return;

    const masked = text_utils.maskSecrets(arena, query_value.string) catch "<redaction-error>";
    var preview_buf: [160]u8 = undefined;
    const query_preview = debug_trace.terminalPreview(&preview_buf, masked);
    debug_trace.eventf("permission", "web_search_denied", ctx, "call_id={s} tool_name={s} query={s} query_bytes={d} reason={s}", .{ call.id, call.name, query_preview, query_value.string.len, @tagName(reason) });
}

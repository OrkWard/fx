const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const model_request_budget = @import("model_request_budget.zig");
const session_usage = @import("../session/session_usage.zig");
const web_search_contract = @import("web_search_contract.zig");
const web_search_policy = @import("web_search_policy.zig");
const web_search_provider = @import("web_search_provider.zig");

const Allocator = std.mem.Allocator;

pub const ClockFn = *const fn (*anyopaque) i64;

var default_clock_context: u8 = 0;

pub const Clock = struct {
    ctx: *anyopaque = @ptrCast(&default_clock_context),
    now_fn: ClockFn = defaultNow,

    fn now(self: Clock) i64 {
        return self.now_fn(self.ctx);
    }
};

pub const Config = struct {
    provider: ?web_search_provider.Provider = null,
    clock: Clock = .{},
    policy: ?web_search_policy.WebSearchPolicy = null,
    api_key: []const u8 = "",
    credential_source: ?types.CredentialSource = null,
    gateway_team: ?[]const u8 = null,
    worker_model: []const u8 = "",
    gateway_retry_count: usize = 3,
    gateway_chat_url: []const u8 = "https://ai-gateway.vercel.sh/v4/ai/language-model",
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
};

pub const Inputs = web_search_provider.Inputs;

const OwnedInputs = struct {
    api_key: []u8,
    credential_source: ?types.CredentialSource = null,
    gateway_team: ?[]u8 = null,
    worker_model: []u8,
    gateway_retry_count: usize,
    gateway_chat_url: []u8,
    // The usage pointer and allocator borrow the parent session's lifetime.
    usage: ?*session_usage.Usage,
    usage_allocator: Allocator,

    fn deinit(self: *OwnedInputs, alloc: Allocator) void {
        alloc.free(self.api_key);
        if (self.gateway_team) |team| alloc.free(team);
        alloc.free(self.worker_model);
        alloc.free(self.gateway_chat_url);
        self.* = undefined;
    }

    fn borrowed(self: *const OwnedInputs) Inputs {
        return .{
            .api_key = self.api_key,
            .credential_source = self.credential_source,
            .gateway_team = self.gateway_team,
            .worker_model = self.worker_model,
            .gateway_retry_count = self.gateway_retry_count,
            .gateway_chat_url = self.gateway_chat_url,
            .usage = self.usage,
            .usage_allocator = self.usage_allocator,
        };
    }
};

pub const ExecutionOutput = web_search_contract.ExecutionOutput;

pub const Runtime = struct {
    provider: ?web_search_provider.Provider,
    clock: Clock,
    policy: web_search_policy.WebSearchPolicy,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    gateway_team: ?[]const u8 = null,
    worker_model: []const u8,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    usage: ?*session_usage.Usage,
    usage_allocator: Allocator,
    config_mutex: std.Io.Mutex = .init,
    fallback_cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(config: Config) Runtime {
        return .{
            .provider = config.provider,
            .clock = config.clock,
            .policy = config.policy orelse if (config.provider) |provider| provider.policy else .{},
            .api_key = config.api_key,
            .credential_source = config.credential_source,
            .gateway_team = config.gateway_team,
            .worker_model = config.worker_model,
            .gateway_retry_count = config.gateway_retry_count,
            .gateway_chat_url = config.gateway_chat_url,
            .usage = config.usage,
            .usage_allocator = config.usage_allocator,
        };
    }

    pub fn deinit(_: *Runtime) void {}

    pub fn configure(self: *Runtime, inputs: Inputs) void {
        self.config_mutex.lockUncancelable(io_mod.getIo());
        defer self.config_mutex.unlock(io_mod.getIo());
        self.api_key = inputs.api_key;
        self.credential_source = inputs.credential_source;
        self.gateway_team = inputs.gateway_team;
        self.worker_model = inputs.worker_model;
        self.gateway_retry_count = inputs.gateway_retry_count;
        self.gateway_chat_url = inputs.gateway_chat_url;
        self.usage = inputs.usage;
        self.usage_allocator = inputs.usage_allocator;
    }

    pub fn dispatchBackend(self: *Runtime) tool_dispatch.WebSearchBackend {
        return .{ .ctx = @ptrCast(self), .execute_fn = executeForDispatch };
    }

    pub fn execute(
        self: *Runtime,
        alloc: Allocator,
        request: web_search_contract.Request,
        cancel_flag: *std.atomic.Value(bool),
    ) !ExecutionOutput {
        return self.executeWithProgress(alloc, request, cancel_flag, null, null);
    }

    pub fn executeWithProgress(
        self: *Runtime,
        alloc: Allocator,
        input: web_search_contract.Request,
        cancel_flag: *std.atomic.Value(bool),
        on_progress: ?web_search_contract.ProgressFn,
        progress_ctx: ?*anyopaque,
    ) !ExecutionOutput {
        const started_at_ms = self.clock.now();
        var inputs = try self.inputsSnapshot(alloc);
        defer inputs.deinit(alloc);
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        var policy = self.policy;
        if (self.provider) |provider| {
            if (try provider.preferredBackends()) |preferred_backends| {
                policy.preferred_backends = preferred_backends;
            }
        }
        const selected_backend = web_search_policy.selectBackend(policy, .{
            .has_allowed_domains = hasValues(input.allowed_domains),
            .has_blocked_domains = hasValues(input.blocked_domains),
        }) orelse return error.UnsupportedWebSearchFeatures;
        if (!model_request_budget.searchWorkerInputFitsLimit(
            if (self.provider) |provider| provider.input_overhead_bytes else 0,
            input.query,
            input.allowed_domains,
            input.blocked_domains,
            self.policy.max_input_bytes,
        )) return error.WebSearchRequestTooLarge;
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        const request = web_search_contract.ProviderRequest{
            .backend = selected_backend.id,
            .query = input.query,
            .allowed_domains = input.allowed_domains,
            .blocked_domains = input.blocked_domains,
            .max_uses = self.policy.max_uses,
            .max_results = self.policy.max_results,
            .max_output_tokens = self.policy.max_output_tokens,
            .max_output_chars = self.policy.max_output_chars,
            .timeout_ms = self.policy.timeout_ms,
            .cancel_flag = cancel_flag,
        };

        const transport_started_at_ms = self.clock.now();
        var response = self.executeProvider(alloc, inputs.borrowed(), request, on_progress, progress_ctx) catch |err| {
            if (shouldRecordFailedNetworkCall(err)) {
                recordNetworkCall(inputs.worker_model, transport_started_at_ms, self.clock.now(), 0, null, null, @errorName(err));
            }
            return err;
        };
        defer response.deinit(alloc);

        const transport_finished_at_ms = self.clock.now();
        const usage = response.usage;
        const web_search_requests = if (usage) |value| value.web_search_requests else 0;
        recordNetworkCall(inputs.worker_model, transport_started_at_ms, transport_finished_at_ms, @backingInt(std.http.Status.ok), usage, response.stop_reason, "");
        const results = response.takeContent();
        const duration_ms = elapsedMs(started_at_ms, self.clock.now());
        debug_trace.logf("web_search", "complete backend={s} model={s} duration_ms={d} requests={d} stop_reason={s}", .{
            selected_backend.id.value,
            inputs.worker_model,
            duration_ms,
            web_search_requests,
            response.stop_reason orelse "(none)",
        });
        return .{
            .output = .{
                .query = input.query,
                .results = results,
                .incomplete = hasTerminalIncomplete(results),
                .duration_ms = duration_ms,
                .web_search_requests = web_search_requests,
            },
            .inner_usage = usage,
        };
    }

    fn inputsSnapshot(self: *Runtime, alloc: Allocator) !OwnedInputs {
        self.config_mutex.lockUncancelable(io_mod.getIo());
        defer self.config_mutex.unlock(io_mod.getIo());
        const api_key = try alloc.dupe(u8, self.api_key);
        errdefer alloc.free(api_key);
        const gateway_team = if (self.gateway_team) |team| try alloc.dupe(u8, team) else null;
        errdefer if (gateway_team) |team| alloc.free(team);
        const worker_model = try alloc.dupe(u8, self.worker_model);
        errdefer alloc.free(worker_model);
        const gateway_chat_url = try alloc.dupe(u8, self.gateway_chat_url);
        return .{
            .api_key = api_key,
            .credential_source = self.credential_source,
            .gateway_team = gateway_team,
            .worker_model = worker_model,
            .gateway_retry_count = self.gateway_retry_count,
            .gateway_chat_url = gateway_chat_url,
            .usage = self.usage,
            .usage_allocator = self.usage_allocator,
        };
    }

    fn executeProvider(
        self: *Runtime,
        alloc: Allocator,
        inputs: Inputs,
        request: web_search_contract.ProviderRequest,
        on_progress: ?web_search_contract.ProgressFn,
        progress_ctx: ?*anyopaque,
    ) !web_search_contract.ProviderResponse {
        const provider = self.provider orelse return error.MissingWebSearchProvider;
        return provider.execute(alloc, inputs, request, on_progress, progress_ctx);
    }
};

const ProgressForwarder = struct {
    dispatch: tool_dispatch.DispatchContext,

    fn onProgress(raw_ctx: *anyopaque, progress: web_search_contract.Progress) void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        const callback = self.dispatch.on_web_search_progress orelse return;
        const callback_ctx = self.dispatch.web_search_progress_ctx orelse return;
        const update: types.WebSearchProgress = switch (progress) {
            .query_update => |query| .{ .query_started = query },
            .results_received => |entry| .{ .results_received = .{
                .query = entry.query,
                .result_count = entry.result_count,
            } },
        };
        callback(callback_ctx, self.dispatch.tool_call_id, update);
    }
};

fn executeForDispatch(
    raw_ctx: *anyopaque,
    ctx: tool_dispatch.DispatchContext,
    request: web_search_contract.Request,
) anyerror!web_search_contract.ExecutionOutput {
    const self: *Runtime = @ptrCast(@alignCast(raw_ctx));
    var progress_forwarder = ProgressForwarder{ .dispatch = ctx };
    return self.executeWithProgress(
        ctx.allocator,
        request,
        ctx.cancel_flag orelse &self.fallback_cancel_flag,
        if (ctx.on_web_search_progress != null) ProgressForwarder.onProgress else null,
        if (ctx.on_web_search_progress != null) @ptrCast(&progress_forwarder) else null,
    );
}

fn defaultNow(_: *anyopaque) i64 {
    return io_mod.milliTimestamp();
}

fn elapsedMs(started_at_ms: i64, finished_at_ms: i64) u64 {
    if (finished_at_ms <= started_at_ms) return 0;
    return @intCast(finished_at_ms - started_at_ms);
}

fn recordNetworkCall(
    model: []const u8,
    started_at_ms: i64,
    finished_at_ms: i64,
    status: u16,
    usage: ?types.ToolUsage,
    stop_reason: ?[]const u8,
    error_name: []const u8,
) void {
    var call: diagnostics.NetworkCall = .{
        .kind = .web_search,
        .started_at_ms = started_at_ms,
        .duration_ms = clampU64ToU32(elapsedMs(started_at_ms, finished_at_ms)),
        .status = status,
        .input_tokens = if (usage) |value| clampU64ToU32(value.input_tokens) else 0,
        .output_tokens = if (usage) |value| clampU64ToU32(value.output_tokens) else 0,
        .is_web_search = true,
        .web_search_requests = if (usage) |value| value.web_search_requests else 0,
    };
    call.setModel(model);
    if (stop_reason) |reason| call.setTerminalStopReason(reason);
    if (error_name.len > 0) call.setError(error_name);
    diagnostics.recordNetworkCall(call);
}

fn clampU64ToU32(value: u64) u32 {
    return @intCast(@min(value, std.math.maxInt(u32)));
}

fn shouldRecordFailedNetworkCall(err: anyerror) bool {
    return switch (err) {
        error.Cancelled,
        error.ConflictingDomainFilters,
        error.MissingGatewaySearchConfiguration,
        error.MissingWebSearchProvider,
        error.OutOfMemory,
        => false,
        else => true,
    };
}

fn hasValues(maybe_strings: ?[]const []const u8) bool {
    return if (maybe_strings) |strings| strings.len > 0 else false;
}

fn hasTerminalIncomplete(items: []const web_search_contract.ResultItem) bool {
    for (items) |item| {
        if (item == .terminal_incomplete) return true;
    }
    return false;
}

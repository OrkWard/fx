const std = @import("std");
const text_utils = @import("text_utils.zig");
const skill_contract = @import("../skills/skill_contract.zig");

pub const Layout = struct {
    rows: u16,
    cols: u16,
    content_bottom: u16,
    divider_top_row: u16,
    input_row: u16,
    divider_bottom_row: u16,
    hint_row: u16,
};

pub const Metrics = struct {
    ansi_bytes: usize = 0,
    full_redraws: usize = 0,
    debounced_resizes: usize = 0,
    footer_line_updates: usize = 0,
    stream_chunks: usize = 0,
};

pub const NoticeTone = enum {
    information,
    success,
    warning,
    @"error",
    cancelled,
    // Renders in the neutral body color so the line reads like a normal response.
    neutral,
};

pub const NoticeVisibility = enum {
    compact_and_full,
    full_only,
};

pub const SemanticNotice = struct {
    topic: []const u8,
    tone: NoticeTone,
    body: []const u8,
    visibility: NoticeVisibility = .compact_and_full,
};

/// Status glyph leading every semantic notice, keyed by tone. Tool activity
/// owns "●"; notices deliberately use distinct git-style status glyphs so the
/// two channels never read as the same raw marker. The neutral marker "*"
/// avoids the middot, which the footer already uses as a separator.
pub fn noticeGlyph(tone: NoticeTone) []const u8 {
    return switch (tone) {
        .information => "i",
        .success => "✓",
        .warning => "!",
        .@"error" => "✗",
        .cancelled => "⊘",
        .neutral => "*",
    };
}

/// Returns a duplicate with owned topic and body bytes. The caller frees it
/// with `freeSemanticNotice` using the same allocator.
pub fn dupeSemanticNotice(alloc: std.mem.Allocator, notice: SemanticNotice) std.mem.Allocator.Error!SemanticNotice {
    const topic = try alloc.dupe(u8, notice.topic);
    errdefer alloc.free(topic);
    return .{
        .topic = topic,
        .tone = notice.tone,
        .body = try alloc.dupe(u8, notice.body),
        .visibility = notice.visibility,
    };
}

pub fn freeSemanticNotice(alloc: std.mem.Allocator, notice: SemanticNotice) void {
    alloc.free(notice.topic);
    alloc.free(notice.body);
}

/// Converts legacy context-notice text into a semantic notice body while
/// preserving line structure. The caller owns the returned bytes.
pub fn renderContextNoticeBody(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    var needs_separator = false;
    while (lines.next()) |line| {
        if (needs_separator) try body.writer.writeByte('\n');
        needs_separator = true;
        if (std.mem.eql(u8, line, "[context]")) continue;
        const legacy_prefix = "[context] ";
        try body.writer.writeAll(if (std.mem.startsWith(u8, line, legacy_prefix)) line[legacy_prefix.len..] else line);
    }
    return body.toOwnedSlice();
}

pub const CredentialSource = enum {
    chatgpt_subscription,
    grok_subscription,
    host_managed,
    configured,
};

pub const DirectCredentialLease = struct {
    secret_bytes: []const u8 = "",
    source: ?CredentialSource = null,
    account_id: ?[]const u8 = null,
};

/// Borrowed authorization for one provider request. Host-managed requests
/// cannot carry credential or account bytes into the embedded runtime.
pub const CredentialLease = union(enum) {
    direct: DirectCredentialLease,
    host_managed,

    pub fn secret(self: CredentialLease) ?[]const u8 {
        return switch (self) {
            .direct => |direct| if (direct.secret_bytes.len > 0) direct.secret_bytes else null,
            .host_managed => null,
        };
    }

    pub fn credentialSource(self: CredentialLease) ?CredentialSource {
        return switch (self) {
            .direct => |direct| direct.source,
            .host_managed => .host_managed,
        };
    }

    pub fn accountId(self: CredentialLease) ?[]const u8 {
        return switch (self) {
            .direct => |direct| direct.account_id,
            .host_managed => null,
        };
    }
};

pub fn parseRuntimeCredentialSource(text: []const u8) ?CredentialSource {
    return std.meta.stringToEnum(CredentialSource, text);
}

pub const TurnPresentationOutcome = enum {
    completed,
    interrupted,
    failed,
    paused,
};

pub const TurnFinished = struct {
    turn_id: u64,
    outcome: TurnPresentationOutcome,
};

pub const ToolLifecycleId = struct {
    turn_id: u64,
    call_id: []const u8,
};

pub const ToolPresentationGroupId = struct {
    turn_id: u64,
    anchor_step_id: u64,
};

pub const ToolOutcomeKind = enum {
    completed,
    denied,
    cancelled,
    failed,
    deferred,
};

pub const ToolOutcome = struct {
    kind: ToolOutcomeKind,
    summary: []const u8,
};

pub const ToolLifecycleEvent = union(enum) {
    provisional: struct {
        id: ToolLifecycleId,
        presentation_group_id: ?ToolPresentationGroupId = null,
        tool_name: ?[]const u8,
        activity_kind: ToolActivityKind,
    },
    authoritative_started: struct {
        id: ToolLifecycleId,
        presentation_group_id: ?ToolPresentationGroupId = null,
        reconciles_provisional_call_id: ?[]const u8,
        tool_name: []const u8,
        activity_kind: ToolActivityKind,
        arguments_json: ?[]const u8 = null,
        place_after_current_transcript: bool = false,
    },
    progress: struct {
        id: ToolLifecycleId,
        text: []const u8,
    },
    terminal: struct {
        id: ToolLifecycleId,
        outcome: ToolOutcome,
        result: ?[]const u8 = null,
        result_memory: ?ToolResultMemory = null,
        command_artifact_handle: ?[]const u8 = null,
    },
    turn_finished: TurnFinished,
};

pub const TurnPhase = enum {
    thinking,
    generating,
    running,
    waiting_for_subagent,
};

pub const TurnPhaseUpdate = struct {
    turn_id: u64,
    step_id: u64,
    phase: TurnPhase,
};

pub const StreamState = struct {
    active: bool = false,
    phase: TurnPhase = .thinking,
    phase_step_id: u64 = 0,
    chunks: usize = 0,
    read_count: usize = 0,
    list_count: usize = 0,
    write_count: usize = 0,
    edit_count: usize = 0,
    open_count: usize = 0,
    command_count: usize = 0,
    subagent_count: usize = 0,
    token_progress: TurnTokenProgress = .{},
    last_activity_kind: ?ToolActivityKind = null,
    /// When the turn started; 0 hides the elapsed counter and activity blink.
    /// Monotonic for the whole turn: phase and tool boundaries never reset it.
    turn_started_ms: i64 = 0,
    /// When fx started waiting on user input (approval or question); 0 means
    /// not waiting. While set, the turn clock freezes at this instant;
    /// on resume the wait is excluded by shifting turn_started_ms forward.
    waiting_since_ms: i64 = 0,
};

pub const RouteRecoveryUnsafeReason = enum {
    assistant_output,
    tool_start,
};

pub const RouteRecoveryStatusTone = enum {
    warning,
    success,
    danger,
};

pub const ModelRecoveryCause = enum {
    network_interrupted,
    /// The network path is provably down; nothing was sent and the turn is
    /// waiting for connectivity instead of spending retry budget.
    connectivity_lost,
    response_interrupted,
    provider_stream_timeout,
    provider_unavailable,
    rate_limited,
    system_resumed,
    authentication,
    request_limit_reached,
    compaction_prepared,
};

pub const ModelRecoveryAction = enum {
    retrying_request,
    continuing_response,
    regenerating_tool,
    continuing_after_tool,
    reconciling_tool,
    waiting_for_connectivity,
    /// Silence detected; checking liveness before doing anything else.
    checking_liveness,
    paused,
};

pub const ModelRecoveryRequiredAction = enum {
    none,
    continue_later,
    inspect_uncertain_tool,
    change_request,
    /// The same failure repeated at the same progress point; surfaced as a
    /// broken response instead of an endless restart loop.
    surface_stall,
};

pub const ModelFailureDiagnostic = struct {
    pub const max_bytes: usize = 256;

    bytes: [max_bytes]u8 = @splat(0),
    len: u16 = 0,

    pub fn defaultTextForCause(cause: ModelRecoveryCause) []const u8 {
        return switch (cause) {
            .network_interrupted => "NetworkInterrupted",
            .connectivity_lost => "ConnectionUnavailable",
            .response_interrupted => "StreamInterrupted",
            .provider_stream_timeout => "gateway_stream_timeout",
            .provider_unavailable => "provider_error",
            .rate_limited => "HTTP 429",
            .system_resumed => "SystemResumed",
            .authentication => "AuthenticationExpired",
            .request_limit_reached => "ProviderRequestLimitReached",
            .compaction_prepared => "CompactionPrepared",
        };
    }

    pub fn forCause(cause: ModelRecoveryCause) ModelFailureDiagnostic {
        return init(defaultTextForCause(cause));
    }

    pub fn init(text: []const u8) ModelFailureDiagnostic {
        var diagnostic: ModelFailureDiagnostic = .{};
        if (text.len <= max_bytes) {
            @memcpy(diagnostic.bytes[0..text.len], text);
            diagnostic.len = @intCast(text.len);
            return diagnostic;
        }

        const marker = "...";
        const prefix = text_utils.utf8PrefixByBytes(text, max_bytes - marker.len);
        @memcpy(diagnostic.bytes[0..prefix.len], prefix);
        @memcpy(diagnostic.bytes[prefix.len .. prefix.len + marker.len], marker);
        diagnostic.len = @intCast(prefix.len + marker.len);
        return diagnostic;
    }

    pub fn view(self: *const ModelFailureDiagnostic) []const u8 {
        return self.bytes[0..self.len];
    }

    /// User-facing phrasing for machine error names. Provider-supplied text
    /// passes through unchanged; only known transport error identifiers are
    /// translated. Raw names stay available in trace logs.
    fn humanText(self: *const ModelFailureDiagnostic) []const u8 {
        const raw = self.view();
        const pairs = .{
            .{ "ReadFailed", "connection dropped" },
            .{ "WriteFailed", "connection dropped" },
            .{ "HttpConnectionClosing", "connection closed" },
            .{ "ConnectionResetByPeer", "connection reset" },
            .{ "ConnectionRefused", "connection refused" },
            .{ "ConnectionTimedOut", "connection timed out" },
            .{ "Timeout", "timed out" },
            .{ "StreamStalled", "stream stalled" },
            .{ "UnknownHostName", "cannot resolve host" },
            .{ "NameServerFailure", "DNS lookup failed" },
            .{ "NetworkUnreachable", "network unreachable" },
            .{ "NetworkDown", "network is down" },
            .{ "HostUnreachable", "host unreachable" },
            .{ "NetworkInterrupted", "network interrupted" },
            .{ "StreamInterrupted", "stream interrupted" },
        };
        inline for (pairs) |pair| {
            if (std.mem.eql(u8, raw, pair[0])) return pair[1];
        }
        return raw;
    }
};

pub const RouteRecoveryStatus = struct {
    pub const label_max_bytes: usize = 512;

    pub const Kind = enum {
        auto_retry,
        auto_recovered,
        manual_retry_without_fast,
        manual_recovered_without_fast,
        terminal_provider_error,
        unsafe_assistant_output,
        unsafe_tool_start,
        content_filter,
    };

    kind: Kind,
    failed_attempt: usize = 0,
    succeeded_attempt: usize = 0,
    attempt_limit: usize = 0,
    cause: ?ModelRecoveryCause = null,
    action: ?ModelRecoveryAction = null,
    required_action: ModelRecoveryRequiredAction = .none,
    delay_seconds: u64 = 0,
    retry_deadline: ?std.Io.Clock.Timestamp = null,
    diagnostic: ?ModelFailureDiagnostic = null,

    pub fn tone(self: RouteRecoveryStatus) RouteRecoveryStatusTone {
        return switch (self.kind) {
            .auto_recovered,
            .manual_recovered_without_fast,
            => .success,
            .terminal_provider_error,
            .unsafe_assistant_output,
            .unsafe_tool_start,
            .content_filter,
            => .danger,
            .auto_retry,
            .manual_retry_without_fast,
            => .warning,
        };
    }

    pub fn isRecovered(self: RouteRecoveryStatus) bool {
        return switch (self.kind) {
            .auto_recovered,
            .manual_recovered_without_fast,
            => true,
            else => false,
        };
    }

    pub fn reportedAttempt(self: RouteRecoveryStatus) usize {
        if (self.isRecovered() and self.succeeded_attempt != 0) {
            return self.succeeded_attempt;
        }
        return self.failed_attempt;
    }

    pub fn label(self: RouteRecoveryStatus, buf: []u8) []const u8 {
        return switch (self.kind) {
            .auto_retry => self.recoveryLabel(buf),
            .auto_recovered => std.mem.print(
                buf,
                "✓ recovered · succeeded on attempt {d}",
                .{self.succeeded_attempt},
            ) catch "✓ recovered",
            .manual_retry_without_fast => self.manualRetryLabel(buf),
            .manual_recovered_without_fast => "✓ recovered · Fast disabled",
            .terminal_provider_error => self.pausedLabel(buf),
            .unsafe_assistant_output => self.fixedFailureLabel(
                buf,
                "Response interrupted",
                "partial output preserved",
            ),
            .unsafe_tool_start => self.fixedFailureLabel(
                buf,
                "Tool state needs review",
                "context preserved",
            ),
            .content_filter => self.fixedFailureLabel(buf, "blocked", "content filter"),
        };
    }

    fn manualRetryLabel(self: RouteRecoveryStatus, buf: []u8) []const u8 {
        if (self.diagnostic) |diagnostic| {
            return std.mem.print(
                buf,
                "⚠ Provider route unavailable · {s} · continuing without Fast",
                .{diagnostic.view()},
            ) catch "⚠ Provider route unavailable · continuing without Fast";
        }
        return "⚠ Provider route unavailable · continuing without Fast";
    }

    fn fixedFailureLabel(
        self: RouteRecoveryStatus,
        buf: []u8,
        cause: []const u8,
        action: []const u8,
    ) []const u8 {
        if (self.diagnostic) |diagnostic| {
            return std.mem.print(
                buf,
                "⚠ {s} · {s} · {s}",
                .{ cause, diagnostic.view(), action },
            ) catch "⚠ Model response failed";
        }
        return std.mem.print(buf, "⚠ {s} · {s}", .{ cause, action }) catch "⚠ Model response failed";
    }

    fn recoveryLabel(self: RouteRecoveryStatus, buf: []u8) []const u8 {
        const cause = switch (self.cause orelse .provider_unavailable) {
            .network_interrupted => "Network interrupted",
            .connectivity_lost => "Connection lost",
            .response_interrupted => "Response ended early",
            .provider_stream_timeout => "Gateway stream timed out",
            .provider_unavailable => "Provider unavailable",
            .rate_limited => "Rate limited",
            .system_resumed => "Mac woke from sleep",
            .authentication => "Authentication refreshed",
            .request_limit_reached => "Provider request limit reached",
            .compaction_prepared => "Resuming saved compaction",
        };
        const action_value = self.action orelse .retrying_request;
        const action = switch (action_value) {
            .retrying_request => "retrying request",
            .continuing_response => "restarting response",
            .regenerating_tool => "regenerating unstarted tool",
            .continuing_after_tool => "continuing after confirmed tool",
            .reconciling_tool => "checking uncertain tool state",
            .waiting_for_connectivity => "waiting for connection",
            .checking_liveness => "checking the connection",
            .paused => "recovery paused",
        };
        // Connectivity waits and liveness probes are un-budgeted: no attempt
        // counter and no raw error names, just the honest current state.
        if (action_value == .waiting_for_connectivity or action_value == .checking_liveness) {
            if (self.delay_seconds > 0) {
                return std.mem.print(
                    buf,
                    "⚠ {s} · {s} · {d}s",
                    .{ cause, action, self.delay_seconds },
                ) catch "⚠ Recovering model response";
            }
            return std.mem.print(
                buf,
                "⚠ {s} · {s}",
                .{ cause, action },
            ) catch "⚠ Recovering model response";
        }
        if (self.delay_seconds > 0) {
            if (self.diagnostic) |diagnostic| {
                return std.mem.print(
                    buf,
                    "⚠ {s} · {s} · {s} in {d}s",
                    .{ cause, diagnostic.humanText(), action, self.delay_seconds },
                ) catch "⚠ Recovering model response";
            }
            return std.mem.print(
                buf,
                "⚠ {s} · {s} in {d}s",
                .{ cause, action, self.delay_seconds },
            ) catch "⚠ Recovering model response";
        }
        if (self.diagnostic) |diagnostic| {
            return std.mem.print(
                buf,
                "⚠ {s} · {s} · {s}",
                .{ cause, diagnostic.humanText(), action },
            ) catch "⚠ Recovering model response";
        }
        return std.mem.print(
            buf,
            "⚠ {s} · {s}",
            .{ cause, action },
        ) catch "⚠ Recovering model response";
    }

    // Display names for paused and terminal recovery states; single source so
    // the stall and generic branches cannot drift. In-progress resume copy
    // stays in recoveryLabel, where the wording reads differently mid-flight.
    fn pausedCauseDisplayName(cause: ModelRecoveryCause) []const u8 {
        return switch (cause) {
            .network_interrupted => "Network interrupted",
            .connectivity_lost => "Connection lost",
            .response_interrupted => "Response ended early",
            .provider_stream_timeout => "Gateway stream timed out",
            .provider_unavailable => "Provider unavailable",
            .rate_limited => "Rate limited",
            .system_resumed => "Mac woke from sleep",
            .authentication => "Authentication expired",
            .request_limit_reached => "Provider request limit reached",
            .compaction_prepared => "Saved compaction",
        };
    }

    fn pausedLabel(self: RouteRecoveryStatus, buf: []u8) []const u8 {
        if (self.required_action == .surface_stall) {
            const cause_text: []const u8 = if (self.cause) |cause|
                pausedCauseDisplayName(cause)
            else
                "Response failed";
            if (self.diagnostic) |diagnostic| {
                return std.mem.print(
                    buf,
                    "⚠ {s} · {s} · kept failing at the same point · stopped",
                    .{ cause_text, diagnostic.humanText() },
                ) catch "⚠ Response kept failing at the same point";
            }
            return std.mem.print(
                buf,
                "⚠ {s} · kept failing at the same point · stopped",
                .{cause_text},
            ) catch "⚠ Response kept failing at the same point";
        }
        const cause = self.cause orelse return self.pausedCauseLabel(buf, "Provider unavailable");
        if (cause == .rate_limited) {
            if (self.diagnostic) |diagnostic| {
                return std.mem.print(
                    buf,
                    "⚠ Rate limited · {s} · server requested a longer wait · recovery paused · attempt {d}",
                    .{ diagnostic.view(), self.failed_attempt },
                ) catch "⚠ Rate limited · recovery paused";
            }
            return std.mem.print(
                buf,
                "⚠ Rate limited · server requested a longer wait · recovery paused · attempt {d}",
                .{self.failed_attempt},
            ) catch "⚠ Rate limited · recovery paused";
        }
        if (cause == .system_resumed) {
            if (self.diagnostic) |diagnostic| {
                return std.mem.print(
                    buf,
                    "⚠ Mac woke from sleep · {s} · connection still unavailable · recovery paused · attempt {d}",
                    .{ diagnostic.view(), self.failed_attempt },
                ) catch "⚠ Connection unavailable · recovery paused";
            }
            return std.mem.print(
                buf,
                "⚠ Mac woke from sleep · connection still unavailable · recovery paused · attempt {d}",
                .{self.failed_attempt},
            ) catch "⚠ Connection unavailable · recovery paused";
        }
        if (cause == .provider_stream_timeout) {
            if (self.diagnostic) |diagnostic| {
                return std.mem.print(
                    buf,
                    "⚠ Gateway stream timed out · {s} · automatic retry paused · attempt {d}",
                    .{ diagnostic.view(), self.failed_attempt },
                ) catch "⚠ Gateway stream timed out · automatic retry paused";
            }
            return std.mem.print(
                buf,
                "⚠ Gateway stream timed out · automatic retry paused · attempt {d}",
                .{self.failed_attempt},
            ) catch "⚠ Gateway stream timed out · automatic retry paused";
        }
        if (cause == .request_limit_reached) {
            if (self.diagnostic) |diagnostic| {
                return std.mem.print(
                    buf,
                    "⚠ Response paused · {s} · {d}/{d} provider-request safety limit reached",
                    .{ diagnostic.view(), self.failed_attempt, self.attempt_limit },
                ) catch "⚠ Response paused · provider-request safety limit reached";
            }
            return std.mem.print(
                buf,
                "⚠ Response paused · {d}/{d} provider-request safety limit reached",
                .{ self.failed_attempt, self.attempt_limit },
            ) catch "⚠ Response paused · provider-request safety limit reached";
        }
        return self.pausedCauseLabel(buf, pausedCauseDisplayName(cause));
    }

    fn pausedCauseLabel(
        self: RouteRecoveryStatus,
        buf: []u8,
        name: []const u8,
    ) []const u8 {
        // A lifecycle/safety pause (.paused action) can resume; a terminal
        // stop (no action) is honest about ending.
        const state_text: []const u8 = if (self.action == .paused)
            "recovery paused"
        else
            "stopped";
        const plural: []const u8 = if (self.failed_attempt == 1) "" else "s";
        if (self.diagnostic) |diagnostic| {
            return std.mem.print(
                buf,
                "⚠ {s} · {s} · {s} after {d} attempt{s}",
                .{ name, diagnostic.humanText(), state_text, self.failed_attempt, plural },
            ) catch "⚠ Model response recovery ended";
        }
        return std.mem.print(
            buf,
            "⚠ {s} · {s} after {d} attempt{s}",
            .{ name, state_text, self.failed_attempt, plural },
        ) catch "⚠ Model response recovery ended";
    }
};

pub const ChatRole = enum {
    system,
    user,
    assistant,
    tool,
};

pub const FinalToolIdentity = enum {
    valid,
    absent,
    empty,
    wrong_type,
};

pub const ToolExecutionProvenance = enum {
    fx_local,
    provider_executed,
};

pub const ProviderResultIdentityFailure = enum {
    absent,
    empty,
    wrong_type,
    unmatched,
    ambiguous,
    missing_result,
    incomplete_streamed_input,
    invalid_tool_input,
    conflicting_tool_name,
    malformed_provider_executed,
    provenance_contradiction,
    malformed_preliminary,
    duplicate_result,
};

pub const ToolArgumentIntegrity = enum {
    valid,
    malformed_json,
    non_object_json,

    pub fn classifySerialized(
        alloc: std.mem.Allocator,
        serialized: []const u8,
    ) std.mem.Allocator.Error!ToolArgumentIntegrity {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .malformed_json,
        };
        defer parsed.deinit();
        return .valid;
    }

    pub fn classifyFunctionInput(
        alloc: std.mem.Allocator,
        serialized: []const u8,
    ) std.mem.Allocator.Error!ToolArgumentIntegrity {
        const integrity = try classifySerialized(alloc, serialized);
        if (integrity != .valid) return integrity;
        // A complete JSON root is nonempty; only an object can start with '{'.
        return if (std.mem.trimStart(u8, serialized, " \t\r\n")[0] == '{') .valid else .non_object_json;
    }
};

/// Explains why raw function arguments were `malformed_json`, captured before
/// fx replaces them with `{}`. It carries positions only: rejected argument
/// bytes never leave the parse step.
pub const ToolArgumentDiagnostic = struct {
    pub const Failure = enum {
        /// The input ended before the JSON value was complete.
        truncated,
        /// The scanner rejected the input at `error_offset`.
        syntax_error,
        /// The syntax was complete, but the parsed value was refused, such as
        /// an object that repeats a key.
        rejected_value,
    };

    failure: Failure,
    input_bytes: usize,
    /// Byte offset where scanning stopped; null when no single byte is at fault.
    error_offset: ?usize,

    /// Diagnoses raw input that failed `ToolArgumentIntegrity` classification.
    /// `scratch` backs only the scanner's nesting stack, released before return.
    pub fn diagnose(scratch: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!ToolArgumentDiagnostic {
        var scanner = std.json.Scanner.initCompleteInput(scratch, raw);
        defer scanner.deinit();
        var position: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&position);
        while (true) {
            const token = scanner.next() catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                // Complete input cannot underrun; treat it as the same missing tail.
                error.UnexpectedEndOfInput, error.BufferUnderrun => .{
                    .failure = .truncated,
                    .input_bytes = raw.len,
                    .error_offset = raw.len,
                },
                error.SyntaxError => .{
                    .failure = .syntax_error,
                    .input_bytes = raw.len,
                    .error_offset = @min(raw.len, std.math.cast(usize, position.getByteOffset()) orelse raw.len),
                },
            };
            if (token == .end_of_document) return .{
                .failure = .rejected_value,
                .input_bytes = raw.len,
                .error_offset = null,
            };
        }
    }
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    argument_integrity: ToolArgumentIntegrity = .valid,
    /// Set when fx rejected the raw arguments as `malformed_json`. Copies keep
    /// it; durable and provider encodings omit it.
    argument_diagnostic: ?ToolArgumentDiagnostic = null,
    provisional_id: ?[]const u8 = null,
    provider_result: ?[]const u8 = null,
    final_identity: FinalToolIdentity = .valid,
    provenance: ToolExecutionProvenance = .fx_local,
    /// Borrowed only for this action. Copies and durable/provider encodings omit it.
    resolved_skill: ?*const skill_contract.PreparedSkill = null,
};

pub const WebFetchProgress = union(enum) {
    fetching: []const u8,
    converting: []const u8,
};

pub const WebFetchArtifactState = enum {
    none,
    stored,
    unavailable,
};

pub const WebFetchCompletion = struct {
    pub const max_url_len: usize = 192;

    url_buf: [max_url_len]u8 = @splat(0),
    url_len: u8 = 0,
    bytes: u64 = 0,
    status: u16 = 0,
    duration_ms: u64 = 0,
    cache_hit: bool = false,
    artifact_state: WebFetchArtifactState = .none,

    pub fn setUrl(self: *WebFetchCompletion, url_value: []const u8) void {
        const n = @min(url_value.len, max_url_len);
        if (n > 0) @memcpy(self.url_buf[0..n], url_value[0..n]);
        self.url_len = @intCast(n);
    }

    pub fn url(self: *const WebFetchCompletion) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};

pub const SubagentStatus = struct {
    session_title: ?[]const u8 = null,
    model: []const u8,
    effort: ReasoningEffort,
    input_tokens: u64,
    context_window: ?u32,
};

pub const SubagentStatusRenderer = struct {
    ctx: *anyopaque,
    render_fn: *const fn (*anyopaque, buf: []u8, SubagentStatus) []const u8,

    pub fn render(self: SubagentStatusRenderer, buf: []u8, status: SubagentStatus) []const u8 {
        return self.render_fn(self.ctx, buf, status);
    }
};

pub const PersistedToolStatus = enum {
    success,
    failure,
};

pub const FileEvidenceAction = enum {
    read,
    write,
    edit,
    delete,
    rename,
    copy,
    search,
    list,
    unknown,
};

pub const CommittedFilePresentationKind = enum {
    added,
    edited,
};

pub const CommittedFilePresentationLineKind = enum {
    context,
    addition,
    deletion,
    elision,
    notice,
};

pub const CommittedFilePresentationLine = struct {
    kind: CommittedFilePresentationLineKind,
    old_line: ?u32 = null,
    new_line: ?u32 = null,
    text: []const u8,
};

pub const CommittedFilePresentation = struct {
    path: []const u8,
    kind: CommittedFilePresentationKind,
    lines: []const CommittedFilePresentationLine,
    additions: usize,
    deletions: usize,
    truncated: bool,
    previous_content: ?[]const u8 = null,
    after_content: ?[]const u8 = null,
    lifecycle_id: ?ToolLifecycleId = null,
    /// Content-addressed artifact handle holding the previous/after content
    /// pack in the session result store. When present, the durable record
    /// omits the inline contents and readers load them through the handle.
    /// In-memory live-turn presentations keep contents inline and leave this
    /// null; only the persistence projection sets it.
    content_handle: ?[]const u8 = null,
};

/// Rejects competing or wrongly typed durable content authorities. A
/// preview-only presentation may have neither inline snapshots nor a handle.
pub fn committedFilePresentationContentSourceValid(
    presentation: CommittedFilePresentation,
) bool {
    const handle = presentation.content_handle orelse return true;
    return presentation.previous_content == null and
        presentation.after_content == null and
        std.mem.startsWith(u8, handle, "diff-") and
        std.mem.endsWith(u8, handle, ".json");
}

pub const PersistedToolResult = struct {
    tool_images: []ToolImage = &.{},
    tool_image_handle: ?[]u8 = null,
    tool_call_id: []u8,
    tool_name: []u8,
    status: PersistedToolStatus,
    output: []u8,
    output_handle: ?[]u8 = null,
    preview: ?[]u8 = null,
    output_bytes: usize,
    stored_output_bytes: usize,
    truncated: bool = false,
    provider_native: bool = false,
    review_feedback: bool = false,
    created_at_ms: i64 = 0,
    permission_feedback: [][]u8 = &.{},
    committed_file_presentation: ?CommittedFilePresentation = null,
    command_output_replay: ?CommandOutputReplay = null,
    command_process_presentation: ?CommandProcessPresentation = null,
    terminal_action_presentation: ?TerminalActionPresentation = null,
};

pub const CommandOutputReplayDescriptor = struct {
    handle: []const u8,
    framed_bytes: usize,
};

pub const CommandOutputReplay = union(enum) {
    available: CommandOutputReplayDescriptor,
    unavailable,
};

pub const CancelledCommandPresentation = struct {
    output_replay: ?CommandOutputReplay = null,
    command_artifact_handle: ?[]const u8 = null,
};

pub const CommandProcessPresentation = union(enum) {
    exit_code: i64,
    signal: u32,
    timed_out,
    output_capture_failed,
};

pub const TerminalReturnPresentation = union(enum) {
    started,
    condition_met,
    safety_ceiling,
    cancelled,
    exited: i32,
    signal: u32,
};

pub const TerminalFailurePresentation = enum {
    invalid_request,
    path_outside_workspace,
    unsupported_host,
    shell_unavailable,
    pty_unavailable,
    startup_failed,
    process_identity_unavailable,
    session_lost,
    session_not_found,
    invalid_lifecycle,
    authority_denied,
    authority_retired,
    lease_conflict,
    cursor_gap,
    screen_unavailable,
    protocol_incompatible,
    capacity_exceeded,
    cancelled,

    pub fn detail(self: TerminalFailurePresentation) []const u8 {
        return switch (self) {
            .invalid_request => "invalid request",
            .path_outside_workspace => "path is outside the workspace",
            .unsupported_host => "terminal host is unavailable",
            .shell_unavailable => "terminal shell is unavailable",
            .pty_unavailable => "terminal PTY is unavailable",
            .startup_failed => "terminal startup failed",
            .process_identity_unavailable => "terminal process identity is unavailable",
            .session_lost => "terminal session was lost",
            .session_not_found => "terminal session not found",
            .invalid_lifecycle => "terminal session is in an invalid lifecycle state",
            .authority_denied => "terminal authority denied",
            .authority_retired => "saved terminal authority is from an older fx version; start a new terminal",
            .lease_conflict => "terminal control lease conflict",
            .cursor_gap => "terminal output cursor gap",
            .screen_unavailable => "terminal screen is unavailable",
            .protocol_incompatible => "terminal protocol is incompatible",
            .capacity_exceeded => "terminal capacity exceeded",
            .cancelled => "terminal action was cancelled",
        };
    }
};

pub const TerminalActionPresentation = union(enum) {
    returned: TerminalReturnPresentation,
    failed: TerminalFailurePresentation,

    pub fn outcomeKind(self: TerminalActionPresentation) ToolOutcomeKind {
        return switch (self) {
            .returned => |returned| switch (returned) {
                .started, .condition_met, .safety_ceiling => .completed,
                .cancelled => .cancelled,
                .exited => |code| if (code == 0) .completed else .failed,
                .signal => .failed,
            },
            .failed => |failed| if (failed == .cancelled)
                .cancelled
            else
                .failed,
        };
    }
};

pub const deferred_tool_result_output = "Not executed";
pub const context_deferred_tool_result_output = "Scoped project instructions were added before execution. Review them and reissue this tool call if it is still appropriate.";
pub const context_deferred_tool_status_label = "Reading project instructions before continuing:";

pub fn isContextDeferredToolResult(result: PersistedToolResult) bool {
    return result.status == .failure and
        std.mem.eql(u8, result.output, context_deferred_tool_result_output);
}

pub fn isDeferredToolResult(result: PersistedToolResult) bool {
    return result.status == .failure and
        (std.mem.eql(u8, result.output, deferred_tool_result_output) or
            std.mem.eql(u8, result.output, context_deferred_tool_result_output));
}

pub const ToolResultMemory = struct {
    /// Host review feedback is retained for the agent, not security evidence.
    review_feedback: bool = false,
    tool_images: []const ToolImage = &.{},
    tool_image_handle: ?[]const u8 = null,
    output_handle: ?[]const u8 = null,
    preview: ?[]const u8 = null,
    output_bytes: usize = 0,
    stored_output_bytes: usize = 0,
    truncated: bool = false,
    model_view_covers_full_file: ?bool = null,
    committed_file_presentation: ?CommittedFilePresentation = null,
    command_output_replay: ?CommandOutputReplay = null,
    command_process_presentation: ?CommandProcessPresentation = null,
    terminal_action_presentation: ?TerminalActionPresentation = null,
};

pub const ToolExecutionStep = struct {
    assistant: ?[]u8 = null,
    tool_calls: []ToolCall = &.{},
    tool_results: []PersistedToolResult = &.{},
    provider_replay: ?ProviderReplay = null,
};

pub const PersistedSteering = struct {
    text: []u8,
    assistant_prefix: ?[]u8 = null,
    after_tool_step_count: usize,
};

pub const SteeringDelivery = enum(u8) { queued, applied, not_applied };

pub const FileEvidence = struct {
    path: []u8,
    new_path: ?[]u8 = null,
    tool_call_id: []u8,
    tool_name: []u8,
    action: FileEvidenceAction = .unknown,
    status: PersistedToolStatus = .success,
    model_view_covers_full_file: bool = false,
    stale: bool = false,
};

pub const ExecutionMemory = struct {
    tool_steps: []ToolExecutionStep = &.{},
    files: []FileEvidence = &.{},
    /// User guidance consumed between model steps, with its chronological tool boundary.
    steering: []PersistedSteering = &.{},
    turn_summary: ?TurnSummary = null,

    pub fn isEmpty(self: ExecutionMemory) bool {
        return self.tool_steps.len == 0 and self.files.len == 0 and self.steering.len == 0;
    }
};

/// Image bytes returned by a tool; never a grant to read a user file.
pub const ToolImage = struct {
    /// Owned encoded bytes.
    data: []u8,
    mime_type: []u8,
};

pub fn freeToolImages(alloc: std.mem.Allocator, images: []const ToolImage) void {
    for (images) |image| {
        alloc.free(image.data);
        alloc.free(image.mime_type);
    }
    alloc.free(images);
}

pub fn dupeToolImages(alloc: std.mem.Allocator, images: []const ToolImage) ![]ToolImage {
    const copies = try alloc.alloc(ToolImage, images.len);
    var initialized: usize = 0;
    errdefer {
        for (copies[0..initialized]) |image| {
            alloc.free(image.data);
            alloc.free(image.mime_type);
        }
        alloc.free(copies);
    }
    for (images, 0..) |image, index| {
        const data = try alloc.dupe(u8, image.data);
        errdefer alloc.free(data);
        const mime_type = try alloc.dupe(u8, image.mime_type);
        errdefer alloc.free(mime_type);
        copies[index] = .{
            .data = data,
            .mime_type = mime_type,
        };
        initialized += 1;
    }
    return copies;
}

/// Deep-copies every slice-bearing field of a ToolResultMemory so the caller's
/// copy is independent of the source's backing allocations. Use when the
/// source memory is owned by a shorter-lived scope (for example a parallel
/// tool attempt whose run result is deinitialized after assembly).
pub fn dupeToolResultMemory(alloc: std.mem.Allocator, memory: ToolResultMemory) !ToolResultMemory {
    const tool_images = try dupeToolImages(alloc, memory.tool_images);
    errdefer freeToolImages(alloc, tool_images);
    const tool_image_handle = if (memory.tool_image_handle) |handle| try alloc.dupe(u8, handle) else null;
    errdefer if (tool_image_handle) |handle| alloc.free(handle);
    const output_handle = if (memory.output_handle) |handle| try alloc.dupe(u8, handle) else null;
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = if (memory.preview) |value| try alloc.dupe(u8, value) else null;
    errdefer if (preview) |value| alloc.free(value);
    const committed_file_presentation = if (memory.committed_file_presentation) |presentation|
        try dupeCommittedFilePresentation(alloc, presentation)
    else
        null;
    errdefer if (committed_file_presentation) |presentation| freeCommittedFilePresentation(alloc, presentation);
    const command_output_replay = if (memory.command_output_replay) |replay|
        try dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (command_output_replay) |replay| freeCommandOutputReplay(alloc, replay);
    return .{
        .review_feedback = memory.review_feedback,
        .tool_images = tool_images,
        .tool_image_handle = tool_image_handle,
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = memory.output_bytes,
        .stored_output_bytes = memory.stored_output_bytes,
        .truncated = memory.truncated,
        .model_view_covers_full_file = memory.model_view_covers_full_file,
        .committed_file_presentation = committed_file_presentation,
        .command_output_replay = command_output_replay,
        .command_process_presentation = memory.command_process_presentation,
        .terminal_action_presentation = memory.terminal_action_presentation,
    };
}

/// Frees the slice-bearing fields of a ToolResultMemory owned by the caller,
/// as produced by dupeToolResultMemory.
pub fn freeToolResultMemory(alloc: std.mem.Allocator, memory: ToolResultMemory) void {
    freeToolImages(alloc, memory.tool_images);
    if (memory.tool_image_handle) |handle| alloc.free(handle);
    if (memory.output_handle) |handle| alloc.free(handle);
    if (memory.preview) |value| alloc.free(value);
    if (memory.committed_file_presentation) |presentation| freeCommittedFilePresentation(alloc, presentation);
    if (memory.command_output_replay) |replay| freeCommandOutputReplay(alloc, replay);
}

/// A cut in the active context, not a second persisted history.
pub const ContextHistoryCut = struct {
    turns: usize = 0,
    tool_steps: usize = 0,
    steering: usize = 0,
};

pub const ImageAttachment = struct {
    id: usize = 0,
    path: []u8,
    media_type: []u8,
    snapshot_path: ?[]u8 = null,
    snapshot_sha256: ?[]u8 = null,
    /// Owned decoded image bytes for sessions without a filesystem snapshot
    /// backend. When set, the
    /// attachment loads from memory instead of `snapshot_path`, and durable
    /// serializers embed the bytes so checkpoint/restore round-trips them.
    inline_data: ?[]u8 = null,
};

pub const UserTurn = struct {
    text: []u8,
    images: []ImageAttachment = &.{},
    /// Durable join key for manager-owned child work. This is metadata only;
    /// model projections continue to use `text` and `images` exclusively.
    work_id: ?[]u8 = null,
};

/// Borrows both strings; use dupeProviderReplay/freeProviderReplay for ownership.
pub const ProviderReplay = struct {
    pub const max_bytes: usize = 4 * 1024 * 1024;
    source: @import("../config/model_provider.zig").ProviderSelection,
    parts_json: []const u8,

    pub fn matches(self: ProviderReplay, source: @import("../config/model_provider.zig").ProviderSelection) bool {
        return self.source.provider.same_authority(source.provider) and std.mem.eql(u8, self.source.model, source.model);
    }
};

pub fn dupeProviderReplay(alloc: std.mem.Allocator, value: ProviderReplay) !ProviderReplay {
    const model = try alloc.dupe(u8, value.source.model);
    errdefer alloc.free(model);
    const parts = try alloc.dupe(u8, value.parts_json);
    return .{ .source = .{ .provider = value.source.provider, .model = model }, .parts_json = parts };
}

pub fn freeProviderReplay(alloc: std.mem.Allocator, value: ProviderReplay) void {
    alloc.free(value.source.model);
    alloc.free(value.parts_json);
}

pub const ChatMessage = struct {
    role: ChatRole,
    content: ?[]const u8 = null,
    images: []const ImageAttachment = &.{},
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    provider_replay: ?ProviderReplay = null,
    tool_result_status: ?PersistedToolStatus = null,
    tool_result_memory: ?ToolResultMemory = null,
    permission_feedback: bool = false,
    /// Checkpoint steering text has already had its envelope removed.
    restored_steering: bool = false,
    // Source provenance for compaction, never permission authority.
    context_origin: enum { ordinary, user_turn, handoff } = .ordinary,
    standalone_response: bool = false,
};

/// Returns a caller-owned shallow projection only when incompatible replay exists.
pub fn projectProviderReplay(
    alloc: std.mem.Allocator,
    messages: []const ChatMessage,
    source: @import("../config/model_provider.zig").ProviderSelection,
) !?[]ChatMessage {
    var projected: ?[]ChatMessage = null;
    errdefer if (projected) |owned| alloc.free(owned);
    for (messages, 0..) |message, index| {
        const replay = message.provider_replay orelse continue;
        if (replay.matches(source)) continue;
        if (projected == null) projected = try alloc.dupe(ChatMessage, messages);
        projected.?[index].provider_replay = null;
    }
    return projected;
}

pub const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_tokens: ?u64 = null,
    cache_write_tokens: ?u64 = null,
    reasoning_tokens: ?u64 = null,
};

/// Exact usage metadata returned by a completed provider stream. `model` is
/// owned by the completion carrying this value.
pub const ProviderBilling = struct {
    created_at_ms: i64,
    model: []const u8,
    total_cost: f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64,
    billable_web_search_calls: u64,
};

/// Absolute per-turn token totals. Input covers only user-submitted prompt text
/// and stays estimated; output may become exact from provider usage.
pub const TurnTokenProgress = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    input_exact: bool = true,
    output_exact: bool = true,
};

pub const ToolUsage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    web_search_requests: u32 = 0,
};

pub const TurnSummary = struct {
    started_at_ms: i64 = 0,
    completed_at_ms: i64 = 0,
    thinking_duration_ms: u64 = 0,
    turn_duration_ms: u64 = 0,
    token_progress: TurnTokenProgress = .{},
};

pub const ProviderFinishReason = enum {
    stop,
    length,
    content_filter,
    tool_calls,
    provider_error,
    other,

    pub fn label(self: ProviderFinishReason) []const u8 {
        return switch (self) {
            .stop => "stop",
            .length => "length",
            .content_filter => "content-filter",
            .tool_calls => "tool-calls",
            .provider_error => "error",
            .other => "other",
        };
    }
};

pub const ProviderFailureCause = enum {
    gateway_stream_timeout,
    non_retryable,
    rate_limited,
};

pub const ProviderServiceTier = enum {
    standard,
    flex,
    priority,

    pub fn parse(raw: []const u8) ?ProviderServiceTier {
        if (std.mem.eql(u8, raw, "default") or std.mem.eql(u8, raw, "standard")) return .standard;
        if (std.mem.eql(u8, raw, "priority") or std.mem.eql(u8, raw, "fast")) return .priority;
        if (std.mem.eql(u8, raw, "flex")) return .flex;
        return null;
    }
};

pub const ModelCompletion = struct {
    content: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    generation_id: ?[]const u8 = null,
    /// Owned gateway provider slug that actually served the request (the
    /// gateway's routing finalProvider/resolvedProvider). Null when the
    /// provider did not report routing metadata.
    resolved_provider: ?[]const u8 = null,
    billing: ?ProviderBilling = null,
    /// Gateway-applied service tier. Null when the provider did not confirm it.
    service_tier: ?ProviderServiceTier = null,
    /// Gateway generation or resolved-model metadata was malformed or conflicting.
    generation_metadata_invalid: bool = false,
    /// An earlier delivery may have billed outside this generation identity.
    delivery_ambiguous: bool = false,
    provider_result_identity_failure: ?ProviderResultIdentityFailure = null,
    provider_failure_cause: ?ProviderFailureCause = null,
    provider_failure_detail: ?[]const u8 = null,
    /// Provider-owned opaque response items for the next stateless request in this turn.
    provider_state_json: ?[]const u8 = null,
    finish_reason: ?ProviderFinishReason = null,
    usage: Usage = .{},
};

pub fn validGatewayGenerationId(id: []const u8) bool {
    if (id.len != 30 or !std.mem.startsWith(u8, id, "gen_")) return false;
    for (id[4..]) |char| switch (char) {
        '0'...'9', 'A'...'H', 'J'...'K', 'M'...'N', 'P'...'T', 'V'...'Z' => {},
        else => return false,
    };
    return true;
}

pub fn validCredentialAccountId(account_id: []const u8) bool {
    if (account_id.len == 0 or account_id.len > 1024) return false;
    for (account_id) |byte| {
        if (byte < 0x21 or byte > 0x7e) return false;
    }
    return true;
}

pub const ProviderCompletionDisposition = enum {
    completed,
    length_limited,
    interrupted,
    provider_failure,
    invalid_completion,
};

pub fn allToolCallsProviderExecuted(tool_calls: []const ToolCall) bool {
    if (tool_calls.len == 0) return false;
    for (tool_calls) |call| {
        if (call.provenance != .provider_executed) return false;
    }
    return true;
}

pub fn classifyProviderCompletion(completion: ModelCompletion) ProviderCompletionDisposition {
    const finish_reason = completion.finish_reason orelse return .interrupted;
    return switch (finish_reason) {
        .provider_error, .content_filter => .provider_failure,
        .length => .length_limited,
        .tool_calls => if (completion.tool_calls.len > 0) .completed else .invalid_completion,
        .stop => if (completion.tool_calls.len == 0 or allToolCallsProviderExecuted(completion.tool_calls)) .completed else .invalid_completion,
        .other => if (completion.tool_calls.len == 0) .completed else .invalid_completion,
    };
}

pub const ConversationIdentity = struct {
    pub const max_bytes: usize = 256;
    pub const Failure = enum { empty, too_long, invalid_utf8 };

    pub fn invalidReason(value: []const u8) ?Failure {
        if (value.len == 0) return .empty;
        if (value.len > max_bytes) return .too_long;
        if (!std.unicode.utf8ValidateSlice(value)) return .invalid_utf8;
        return null;
    }
};

pub const AuthoritativeToolAdmission = union(enum) {
    admitted,
    reject_malformed_identity: FinalToolIdentity,
    reject_unstorable_identity: struct {
        field: enum { id, name, provisional_id },
        reason: ConversationIdentity.Failure,
    },
    reject_malformed_provider_result: ProviderResultIdentityFailure,
    reject_malformed_provider_arguments,
    reject_duplicate_identity,
};

pub fn authoritativeToolAdmission(completion: ModelCompletion) AuthoritativeToolAdmission {
    if (completion.provider_result_identity_failure) |failure| {
        return .{ .reject_malformed_provider_result = failure };
    }

    for (completion.tool_calls) |call| {
        const final_identity = if (call.final_identity == .valid and std.mem.trim(u8, call.id, " \t\r\n").len == 0)
            FinalToolIdentity.empty
        else
            call.final_identity;
        if (final_identity != .valid) {
            return if (call.provenance == .provider_executed)
                .{ .reject_malformed_provider_result = switch (final_identity) {
                    .absent => .absent,
                    .empty => .empty,
                    .wrong_type => .wrong_type,
                    .valid => unreachable,
                } }
            else
                .{ .reject_malformed_identity = final_identity };
        }
    }

    for (completion.tool_calls, 0..) |call, i| {
        for (completion.tool_calls[0..i]) |prior| {
            if (std.mem.eql(u8, prior.id, call.id)) return .reject_duplicate_identity;
        }
    }

    for (completion.tool_calls) |call| {
        if (ConversationIdentity.invalidReason(call.id)) |reason| {
            return .{ .reject_unstorable_identity = .{ .field = .id, .reason = reason } };
        }
        if (ConversationIdentity.invalidReason(call.name)) |reason| {
            return .{ .reject_unstorable_identity = .{ .field = .name, .reason = reason } };
        }
        if (call.provisional_id) |id| {
            if (ConversationIdentity.invalidReason(id)) |reason| {
                return .{ .reject_unstorable_identity = .{ .field = .provisional_id, .reason = reason } };
            }
        }
    }

    for (completion.tool_calls) |call| {
        if (call.provenance == .provider_executed and
            call.argument_integrity == .malformed_json)
        {
            return .reject_malformed_provider_arguments;
        }
    }

    for (completion.tool_calls) |call| {
        if (call.provenance == .provider_executed and call.provider_result == null) {
            return .{ .reject_malformed_provider_result = .missing_result };
        }
    }

    return .admitted;
}

pub const ConversationLanguage = struct {
    pub const max_len: usize = 24;

    bytes: [max_len]u8 = @splat(0),
    len: u8 = 0,

    pub fn default() ConversationLanguage {
        return literal("und");
    }

    pub fn literal(comptime tag: []const u8) ConversationLanguage {
        if (tag.len == 0 or tag.len > max_len) @compileError("invalid conversation language literal");

        var value: ConversationLanguage = .{};
        value.len = @intCast(tag.len);
        @memcpy(value.bytes[0..tag.len], tag);
        return value;
    }

    pub fn fromSlice(tag: []const u8) !ConversationLanguage {
        const trimmed = std.mem.trim(u8, tag, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > max_len) return error.InvalidConversationLanguage;

        var value: ConversationLanguage = .{};
        value.len = @intCast(trimmed.len);
        @memcpy(value.bytes[0..trimmed.len], trimmed);
        return value;
    }

    pub fn view(self: *const ConversationLanguage) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const AssistantHistoryTurn = struct {
    user: UserTurn,
    assistant: []u8,
    execution: ExecutionMemory = .{},
    provider_replay: ?ProviderReplay = null,
};

pub const InterruptedTerminalReason = enum {
    cancelled,
    failed,
};

pub const CancellationOrigin = enum {
    turn,
    compaction,
};

pub const InterruptedHistoryTurn = struct {
    user: UserTurn,
    assistant: ?[]u8 = null,
    tool_call: ?ToolCall = null,
    completed_tool_names: [][]u8 = &.{},
    execution: ExecutionMemory = .{},
    cancelled_command: ?CancelledCommandPresentation = null,
    terminal_reason: InterruptedTerminalReason = .cancelled,
    cancellation_origin: CancellationOrigin = .turn,
};

pub const CompactedSummaryHistoryTurn = struct {
    summary: []u8,
    removed_turn_count: usize,
    compaction_count: usize,
    /// Legacy compacted root text retained for storage compatibility. It is
    /// model context only and never permission authority.
    root_user_messages: [][]u8 = &.{},
    /// Legacy completeness marker retained for storage compatibility.
    root_user_messages_complete: bool = true,
    /// Legacy compacted feedback retained for storage compatibility. It is not
    /// permission authority.
    permission_feedback: [][]u8 = &.{},
    /// Legacy completeness marker retained for storage compatibility.
    permission_feedback_complete: bool = true,
};

pub const HistoryTurn = union(enum) {
    compacted_summary: CompactedSummaryHistoryTurn,
    assistant: AssistantHistoryTurn,
    interrupted: InterruptedHistoryTurn,
};

pub fn setHistoryTurnSummary(turn: *HistoryTurn, summary: TurnSummary) void {
    switch (turn.*) {
        .assistant => |*entry| entry.execution.turn_summary = summary,
        .interrupted => |*entry| entry.execution.turn_summary = summary,
        .compacted_summary => {},
    }
}

pub fn historyTurnSummary(turn: HistoryTurn) ?TurnSummary {
    return switch (turn) {
        .assistant => |entry| entry.execution.turn_summary,
        .interrupted => |entry| entry.execution.turn_summary,
        .compacted_summary => null,
    };
}

pub const FinishedPromptProjection = enum {
    history_default,
    assistant_text,
};

pub const SnapshotFileOwnership = struct {
    /// Shared lifetime for snapshot files after worker completion. Copies must
    /// retain/release; accepted history transfers deletion responsibility.
    ctx: *anyopaque,
    retain_fn: *const fn (*anyopaque) void,
    release_fn: *const fn (*anyopaque) void,
    transfer_fn: *const fn (*anyopaque) void,

    pub fn retain(self: SnapshotFileOwnership) void {
        self.retain_fn(self.ctx);
    }

    pub fn release(self: SnapshotFileOwnership) void {
        self.release_fn(self.ctx);
    }

    pub fn transfer(self: SnapshotFileOwnership) void {
        self.transfer_fn(self.ctx);
    }
};

pub const FinishedPrompt = struct {
    turn: HistoryTurn,
    /// Owned display-only text; never serialized as conversation history.
    presentation_text: ?[]const u8 = null,
    summary: ?TurnSummary = null,
    terminal_projection: FinishedPromptProjection = .history_default,
    terminal_outcome: ?TurnPresentationOutcome = null,
    snapshot_file_ownership: ?SnapshotFileOwnership = null,
};

pub const PermissionMode = enum {
    ask,
    auto,
    yolo,

    pub fn parse(raw: []const u8) ?PermissionMode {
        if (std.ascii.eqlIgnoreCase(raw, "ask")) return .ask;
        if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(raw, "full-access") or
            std.ascii.eqlIgnoreCase(raw, "full access") or
            std.ascii.eqlIgnoreCase(raw, "yolo")) return .yolo;
        return null;
    }
};

pub const RuleDecision = enum {
    none,
    allow,
    ask,
    deny,
};

pub const ContentHash = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub const ToolChoice = enum {
    auto,
    none,
    required,

    pub fn label(self: ToolChoice) []const u8 {
        return @tagName(self);
    }

    pub fn parse(raw: []const u8) ?ToolChoice {
        if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
        return null;
    }
};

pub const ReasoningEffort = union(enum) {
    auto,
    named: Name,

    pub const max_name_bytes = 64;
    pub const max_options = 16;

    pub const Name = struct {
        bytes: [max_name_bytes]u8,
        len: u8,

        fn parse(raw: []const u8) ?Name {
            if (raw.len == 0 or raw.len > max_name_bytes) return null;
            for (raw) |byte| {
                if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return null;
            }

            var name = Name{
                .bytes = @as([max_name_bytes]u8, @splat(0)),
                .len = @intCast(raw.len),
            };
            @memcpy(name.bytes[0..raw.len], raw);
            return name;
        }

        fn literal(comptime raw: []const u8) Name {
            const parsed = comptime Name.parse(raw);
            if (parsed) |name| return name;
            @compileError("invalid reasoning effort literal: " ++ raw);
        }

        fn view(self: *const Name) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    pub fn literal(comptime raw: []const u8) ReasoningEffort {
        return .{ .named = Name.literal(raw) };
    }

    pub fn label(self: *const ReasoningEffort) []const u8 {
        return switch (self.*) {
            .auto => "auto",
            .named => |*name| name.view(),
        };
    }

    pub fn displayLabel(self: *const ReasoningEffort) []const u8 {
        return switch (self.*) {
            .auto => "default",
            .named => self.label(),
        };
    }

    pub fn parse(raw: []const u8) ?ReasoningEffort {
        if (std.ascii.eqlIgnoreCase(raw, "auto") or
            std.ascii.eqlIgnoreCase(raw, "adaptive") or
            std.ascii.eqlIgnoreCase(raw, "default")) return .auto;
        return .{ .named = Name.parse(raw) orelse return null };
    }

    pub fn parseDisplayLabel(raw: []const u8) ?ReasoningEffort {
        return parse(raw);
    }

    pub fn eql(a: ReasoningEffort, b: ReasoningEffort) bool {
        return switch (a) {
            .auto => b == .auto,
            .named => |a_name| switch (b) {
                .auto => false,
                .named => |b_name| std.mem.eql(u8, a_name.view(), b_name.view()),
            },
        };
    }

    pub fn isDefault(self: ReasoningEffort) bool {
        return self == .auto;
    }
};

pub const ToolPermissionDenialReason = enum {
    user_denied,
    auto_denied,
    review_caution,
    review_evidence_incomplete,
    review_unavailable,
    policy_denied,
    permission_required,
};

pub const ToolPermissionDecision = enum {
    once,
    always,
    deny,
    policy_denied,
    permission_required,

    pub fn isDenied(self: ToolPermissionDecision) bool {
        return switch (self) {
            .deny, .policy_denied, .permission_required => true,
            .once, .always => false,
        };
    }

    pub fn denialReason(self: ToolPermissionDecision) ?ToolPermissionDenialReason {
        return switch (self) {
            .deny => .user_denied,
            .policy_denied => .policy_denied,
            .permission_required => .permission_required,
            .once, .always => null,
        };
    }
};

pub const PermissionGrant = struct {
    tool_name: []u8,
    target_path: []u8,
};

pub const PermissionAction = enum {
    allow,
    ask,
    deny,
};

pub const PermissionRule = struct {
    permission: []u8,
    pattern: []u8,
    action: PermissionAction,
};

pub const PermissionRuleSet = struct {
    rules: []PermissionRule = &.{},

    pub fn deinit(self: *PermissionRuleSet, alloc: std.mem.Allocator) void {
        freePermissionRuleSlice(alloc, self.rules);
        self.* = .{};
    }
};

pub const ToolActivityKind = enum {
    read,
    list,
    write,
    edit,
    open,
    command,
    subagent,
    ask,
};

pub const QuestionOption = struct {
    label: []const u8,
    description: ?[]const u8 = null,
};

pub const QuestionBatchEntry = struct {
    question: []const u8,
    options: []const QuestionOption,
    /// Submission prompts return JSON {"value": string} or {"option": index},
    /// keeping typed text distinct from action labels such as Decline.
    submission: enum { none, input, choice } = .none,
};

/// One persisted answer from an interactive question batch. The strings are
/// borrowed from the short-lived arena that decodes the completed tool result.
pub const QuestionAnswer = struct {
    question: []const u8,
    answer: []const u8,
};

pub const ResolveMode = enum {
    existing,
    create,
};

pub fn freeHistoryTurn(alloc: std.mem.Allocator, turn: HistoryTurn) void {
    switch (turn) {
        .compacted_summary => |entry| {
            alloc.free(entry.summary);
            freeCompletedToolNames(alloc, entry.root_user_messages);
            freePermissionFeedback(alloc, entry.permission_feedback);
        },
        .assistant => |entry| {
            freeUserTurn(alloc, entry.user);
            alloc.free(entry.assistant);
            if (entry.provider_replay) |replay| freeProviderReplay(alloc, replay);
            freeExecutionMemory(alloc, entry.execution);
        },
        .interrupted => |entry| {
            freeUserTurn(alloc, entry.user);
            if (entry.assistant) |assistant| alloc.free(assistant);
            if (entry.tool_call) |tool_call| freeToolCall(alloc, tool_call);
            freeCompletedToolNames(alloc, entry.completed_tool_names);
            freeExecutionMemory(alloc, entry.execution);
            if (entry.cancelled_command) |presentation| {
                freeCancelledCommandPresentation(alloc, presentation);
            }
        },
    }
}

pub fn freeHistoryTurnSlice(alloc: std.mem.Allocator, turns: []HistoryTurn) void {
    for (turns) |turn| {
        freeHistoryTurn(alloc, turn);
    }
    alloc.free(turns);
}

pub fn freeFinishedPrompt(alloc: std.mem.Allocator, finished: FinishedPrompt) void {
    freeHistoryTurn(alloc, finished.turn);
    if (finished.presentation_text) |text| alloc.free(text);
    if (finished.snapshot_file_ownership) |ownership| ownership.release();
}

pub fn dupeHistoryTurn(alloc: std.mem.Allocator, turn: HistoryTurn) !HistoryTurn {
    return switch (turn) {
        .compacted_summary => |entry| blk: {
            const summary = try alloc.dupe(u8, entry.summary);
            errdefer alloc.free(summary);
            const root_user_messages = try dupeCompletedToolNames(
                alloc,
                entry.root_user_messages,
            );
            errdefer freeCompletedToolNames(alloc, root_user_messages);
            const permission_feedback = try dupePermissionFeedback(
                alloc,
                entry.permission_feedback,
            );
            break :blk .{ .compacted_summary = .{
                .summary = summary,
                .removed_turn_count = entry.removed_turn_count,
                .compaction_count = entry.compaction_count,
                .root_user_messages = root_user_messages,
                .root_user_messages_complete = entry.root_user_messages_complete,
                .permission_feedback = permission_feedback,
                .permission_feedback_complete = entry.permission_feedback_complete,
            } };
        },
        .assistant => |entry| blk: {
            const user = try dupeUserTurn(alloc, entry.user);
            errdefer freeUserTurn(alloc, user);

            const assistant = try alloc.dupe(u8, entry.assistant);
            errdefer alloc.free(assistant);

            const execution = try dupeExecutionMemory(alloc, entry.execution);
            errdefer freeExecutionMemory(alloc, execution);
            const replay = if (entry.provider_replay) |value| try dupeProviderReplay(alloc, value) else null;
            break :blk .{ .assistant = .{
                .user = user,
                .assistant = assistant,
                .execution = execution,
                .provider_replay = replay,
            } };
        },
        .interrupted => |entry| blk: {
            const user = try dupeUserTurn(alloc, entry.user);
            errdefer freeUserTurn(alloc, user);

            const assistant = if (entry.assistant) |text| try alloc.dupe(u8, text) else null;
            errdefer if (assistant) |text| alloc.free(text);

            const tool_call = if (entry.tool_call) |call| try dupeToolCall(alloc, call) else null;
            errdefer if (tool_call) |call| freeToolCall(alloc, call);

            const completed_tool_names = try dupeCompletedToolNames(alloc, entry.completed_tool_names);
            errdefer freeCompletedToolNames(alloc, completed_tool_names);

            const cancelled_command = if (entry.cancelled_command) |presentation|
                try dupeCancelledCommandPresentation(alloc, presentation)
            else
                null;
            errdefer if (cancelled_command) |presentation| {
                freeCancelledCommandPresentation(alloc, presentation);
            };

            const execution = try dupeExecutionMemory(alloc, entry.execution);

            break :blk .{ .interrupted = .{
                .user = user,
                .assistant = assistant,
                .tool_call = tool_call,
                .completed_tool_names = completed_tool_names,
                .execution = execution,
                .cancelled_command = cancelled_command,
                .terminal_reason = entry.terminal_reason,
                .cancellation_origin = entry.cancellation_origin,
            } };
        },
    };
}

pub fn dupeCancelledCommandPresentation(
    alloc: std.mem.Allocator,
    presentation: CancelledCommandPresentation,
) !CancelledCommandPresentation {
    const output_replay = if (presentation.output_replay) |replay|
        try dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (output_replay) |replay| freeCommandOutputReplay(alloc, replay);
    return .{
        .output_replay = output_replay,
        .command_artifact_handle = if (presentation.command_artifact_handle) |handle|
            try alloc.dupe(u8, handle)
        else
            null,
    };
}

pub fn freeCancelledCommandPresentation(
    alloc: std.mem.Allocator,
    presentation: CancelledCommandPresentation,
) void {
    if (presentation.output_replay) |replay| freeCommandOutputReplay(alloc, replay);
    if (presentation.command_artifact_handle) |handle| alloc.free(@constCast(handle));
}

pub fn dupeFinishedPrompt(alloc: std.mem.Allocator, finished: FinishedPrompt) !FinishedPrompt {
    const turn = try dupeHistoryTurn(alloc, finished.turn);
    errdefer freeHistoryTurn(alloc, turn);
    const presentation_text = if (finished.presentation_text) |text| try alloc.dupe(u8, text) else null;
    if (finished.snapshot_file_ownership) |ownership| ownership.retain();
    return .{
        .turn = turn,
        .presentation_text = presentation_text,
        .summary = finished.summary,
        .terminal_projection = finished.terminal_projection,
        .terminal_outcome = finished.terminal_outcome,
        .snapshot_file_ownership = finished.snapshot_file_ownership,
    };
}

pub fn dupeCompletedToolNames(alloc: std.mem.Allocator, items: []const []u8) ![][]u8 {
    if (items.len == 0) return &.{};

    const copy = try alloc.alloc([]u8, items.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            alloc.free(copy[i]);
        }
    }

    for (items, 0..) |item, i| {
        copy[i] = try alloc.dupe(u8, item);
        copied += 1;
    }
    return copy;
}

pub fn freeCompletedToolNames(alloc: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| alloc.free(item);
    if (items.len > 0) alloc.free(items);
}

pub fn dupeExecutionMemory(alloc: std.mem.Allocator, memory: ExecutionMemory) !ExecutionMemory {
    const tool_steps = try dupeToolExecutionSteps(alloc, memory.tool_steps);
    errdefer freeToolExecutionSteps(alloc, tool_steps);
    const files = try dupeFileEvidenceSlice(alloc, memory.files);
    errdefer freeFileEvidenceSlice(alloc, files);
    const steering = try dupePersistedSteering(alloc, memory.steering);
    return .{
        .tool_steps = tool_steps,
        .files = files,
        .steering = steering,
        .turn_summary = memory.turn_summary,
    };
}

pub fn freeExecutionMemory(alloc: std.mem.Allocator, memory: ExecutionMemory) void {
    freeToolExecutionSteps(alloc, memory.tool_steps);
    freeFileEvidenceSlice(alloc, memory.files);
    freePersistedSteering(alloc, memory.steering);
}

pub fn dupePersistedSteering(
    alloc: std.mem.Allocator,
    steering: []const PersistedSteering,
) ![]PersistedSteering {
    if (steering.len == 0) return &.{};
    const copy = try alloc.alloc(PersistedSteering, steering.len);
    errdefer alloc.free(copy);
    var copied: usize = 0;
    errdefer for (copy[0..copied]) |item| {
        alloc.free(item.text);
        if (item.assistant_prefix) |prefix| alloc.free(prefix);
    };
    for (steering, copy) |item, *dest| {
        const text = try alloc.dupe(u8, item.text);
        errdefer alloc.free(text);
        const assistant_prefix = if (item.assistant_prefix) |prefix|
            try alloc.dupe(u8, prefix)
        else
            null;
        errdefer if (assistant_prefix) |prefix| alloc.free(prefix);
        dest.* = .{
            .text = text,
            .assistant_prefix = assistant_prefix,
            .after_tool_step_count = item.after_tool_step_count,
        };
        copied += 1;
    }
    return copy;
}

pub fn freePersistedSteering(alloc: std.mem.Allocator, steering: []PersistedSteering) void {
    for (steering) |item| {
        alloc.free(item.text);
        if (item.assistant_prefix) |prefix| alloc.free(prefix);
    }
    if (steering.len > 0) alloc.free(steering);
}

pub fn dupeToolExecutionSteps(alloc: std.mem.Allocator, steps: []const ToolExecutionStep) ![]ToolExecutionStep {
    if (steps.len == 0) return &.{};

    const copy = try alloc.alloc(ToolExecutionStep, steps.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) freeToolExecutionStep(alloc, copy[i]);
    }

    for (steps, 0..) |step, i| {
        copy[i] = try dupeToolExecutionStep(alloc, step);
        copied += 1;
    }
    return copy;
}

pub fn freeToolExecutionSteps(alloc: std.mem.Allocator, steps: []ToolExecutionStep) void {
    for (steps) |step| freeToolExecutionStep(alloc, step);
    if (steps.len > 0) alloc.free(steps);
}

fn dupeToolExecutionStep(alloc: std.mem.Allocator, step: ToolExecutionStep) !ToolExecutionStep {
    const assistant = if (step.assistant) |text| try alloc.dupe(u8, text) else null;
    errdefer if (assistant) |text| alloc.free(text);
    const tool_calls = try dupeToolCallSlice(alloc, step.tool_calls);
    errdefer freeToolCallSlice(alloc, tool_calls);
    const tool_results = try dupePersistedToolResults(alloc, step.tool_results);
    errdefer freePersistedToolResults(alloc, tool_results);
    const replay = if (step.provider_replay) |value| try dupeProviderReplay(alloc, value) else null;

    return .{
        .assistant = assistant,
        .provider_replay = replay,
        .tool_calls = tool_calls,
        .tool_results = tool_results,
    };
}

fn freeToolExecutionStep(alloc: std.mem.Allocator, step: ToolExecutionStep) void {
    if (step.assistant) |assistant| alloc.free(assistant);
    if (step.provider_replay) |replay| freeProviderReplay(alloc, replay);
    freeToolCallSlice(alloc, step.tool_calls);
    freePersistedToolResults(alloc, step.tool_results);
}

pub fn dupeToolCallSlice(alloc: std.mem.Allocator, calls: []const ToolCall) ![]ToolCall {
    if (calls.len == 0) return &.{};

    const copy = try alloc.alloc(ToolCall, calls.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) freeToolCall(alloc, copy[i]);
    }

    for (calls, 0..) |call, i| {
        copy[i] = try dupeToolCall(alloc, call);
        copied += 1;
    }
    return copy;
}

pub fn freeToolCallSlice(alloc: std.mem.Allocator, calls: []ToolCall) void {
    for (calls) |call| freeToolCall(alloc, call);
    if (calls.len > 0) alloc.free(calls);
}

pub fn dupePersistedToolResults(alloc: std.mem.Allocator, results: []const PersistedToolResult) ![]PersistedToolResult {
    if (results.len == 0) return &.{};

    const copy = try alloc.alloc(PersistedToolResult, results.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) freePersistedToolResult(alloc, copy[i]);
    }

    for (results, 0..) |result, i| {
        copy[i] = try dupePersistedToolResult(alloc, result);
        copied += 1;
    }
    return copy;
}

pub fn freePersistedToolResults(alloc: std.mem.Allocator, results: []PersistedToolResult) void {
    for (results) |result| freePersistedToolResult(alloc, result);
    if (results.len > 0) alloc.free(results);
}

pub fn dupeCommittedFilePresentation(
    alloc: std.mem.Allocator,
    presentation: CommittedFilePresentation,
) !CommittedFilePresentation {
    const path = try alloc.dupe(u8, presentation.path);
    errdefer alloc.free(path);
    const lines = try alloc.alloc(CommittedFilePresentationLine, presentation.lines.len);
    errdefer alloc.free(lines);
    var copied_lines: usize = 0;
    errdefer {
        for (lines[0..copied_lines]) |line| alloc.free(@constCast(line.text));
    }
    for (presentation.lines, 0..) |line, index| {
        lines[index] = .{
            .kind = line.kind,
            .old_line = line.old_line,
            .new_line = line.new_line,
            .text = try alloc.dupe(u8, line.text),
        };
        copied_lines += 1;
    }
    const previous_content = if (presentation.previous_content) |content|
        try alloc.dupe(u8, content)
    else
        null;
    errdefer if (previous_content) |content| alloc.free(content);
    const after_content = if (presentation.after_content) |content|
        try alloc.dupe(u8, content)
    else
        null;
    errdefer if (after_content) |content| alloc.free(content);
    const lifecycle_id: ?ToolLifecycleId = if (presentation.lifecycle_id) |id| .{
        .turn_id = id.turn_id,
        .call_id = try alloc.dupe(u8, id.call_id),
    } else null;
    errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    const content_handle = if (presentation.content_handle) |handle|
        try alloc.dupe(u8, handle)
    else
        null;
    errdefer if (content_handle) |handle| alloc.free(handle);
    return .{
        .path = path,
        .kind = presentation.kind,
        .lines = lines,
        .additions = presentation.additions,
        .deletions = presentation.deletions,
        .truncated = presentation.truncated,
        .previous_content = previous_content,
        .after_content = after_content,
        .lifecycle_id = lifecycle_id,
        .content_handle = content_handle,
    };
}

pub fn freeCommittedFilePresentation(
    alloc: std.mem.Allocator,
    presentation: CommittedFilePresentation,
) void {
    alloc.free(@constCast(presentation.path));
    for (presentation.lines) |line| alloc.free(@constCast(line.text));
    if (presentation.lines.len > 0) alloc.free(@constCast(presentation.lines));
    if (presentation.previous_content) |content| alloc.free(@constCast(content));
    if (presentation.after_content) |content| alloc.free(@constCast(content));
    if (presentation.lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    if (presentation.content_handle) |handle| alloc.free(@constCast(handle));
}

fn dupePersistedToolResult(alloc: std.mem.Allocator, result: PersistedToolResult) !PersistedToolResult {
    const tool_call_id = try alloc.dupe(u8, result.tool_call_id);
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, result.tool_name);
    errdefer alloc.free(tool_name);
    const output = try alloc.dupe(u8, result.output);
    errdefer alloc.free(output);
    const output_handle = if (result.output_handle) |handle| try alloc.dupe(u8, handle) else null;
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = if (result.preview) |text| try alloc.dupe(u8, text) else null;
    errdefer if (preview) |text| alloc.free(text);
    const permission_feedback = try dupePermissionFeedback(alloc, result.permission_feedback);
    errdefer freePermissionFeedback(alloc, permission_feedback);
    const committed_file_presentation = if (result.committed_file_presentation) |presentation|
        try dupeCommittedFilePresentation(alloc, presentation)
    else
        null;
    errdefer if (committed_file_presentation) |presentation| freeCommittedFilePresentation(alloc, presentation);
    const command_output_replay = if (result.command_output_replay) |replay|
        try dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (command_output_replay) |replay| freeCommandOutputReplay(alloc, replay);
    const tool_image_handle = if (result.tool_image_handle) |handle| try alloc.dupe(u8, handle) else null;
    errdefer if (tool_image_handle) |handle| alloc.free(handle);
    const tool_images = try dupeToolImages(alloc, result.tool_images);
    return .{
        .tool_images = tool_images,
        .tool_image_handle = tool_image_handle,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .status = result.status,
        .output = output,
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = result.output_bytes,
        .stored_output_bytes = result.stored_output_bytes,
        .truncated = result.truncated,
        .provider_native = result.provider_native,
        .review_feedback = result.review_feedback,
        .created_at_ms = result.created_at_ms,
        .permission_feedback = permission_feedback,
        .committed_file_presentation = committed_file_presentation,
        .command_output_replay = command_output_replay,
        .command_process_presentation = result.command_process_presentation,
        .terminal_action_presentation = result.terminal_action_presentation,
    };
}

pub fn freePersistedToolResult(alloc: std.mem.Allocator, result: PersistedToolResult) void {
    alloc.free(result.tool_call_id);
    alloc.free(result.tool_name);
    alloc.free(result.output);
    freeToolImages(alloc, result.tool_images);
    if (result.tool_image_handle) |handle| alloc.free(handle);
    if (result.output_handle) |handle| alloc.free(handle);
    if (result.preview) |preview| alloc.free(preview);
    freePermissionFeedback(alloc, result.permission_feedback);
    if (result.committed_file_presentation) |presentation| {
        freeCommittedFilePresentation(alloc, presentation);
    }
    if (result.command_output_replay) |replay| freeCommandOutputReplay(alloc, replay);
}

pub fn dupeCommandOutputReplay(
    alloc: std.mem.Allocator,
    replay: CommandOutputReplay,
) !CommandOutputReplay {
    return switch (replay) {
        .available => |descriptor| .{ .available = .{
            .handle = try alloc.dupe(u8, descriptor.handle),
            .framed_bytes = descriptor.framed_bytes,
        } },
        .unavailable => .unavailable,
    };
}

pub fn freeCommandOutputReplay(
    alloc: std.mem.Allocator,
    replay: CommandOutputReplay,
) void {
    switch (replay) {
        .available => |descriptor| alloc.free(@constCast(descriptor.handle)),
        .unavailable => {},
    }
}

pub fn dupePermissionFeedback(
    alloc: std.mem.Allocator,
    feedback: []const []const u8,
) ![][]u8 {
    if (feedback.len == 0) return &.{};

    const copy = try alloc.alloc([]u8, feedback.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |text| alloc.free(text);
    }
    for (feedback, 0..) |text, i| {
        copy[i] = try alloc.dupe(u8, text);
        copied += 1;
    }
    return copy;
}

pub fn freePermissionFeedback(alloc: std.mem.Allocator, feedback: [][]u8) void {
    for (feedback) |text| alloc.free(text);
    if (feedback.len > 0) alloc.free(feedback);
}

pub fn dupeFileEvidenceSlice(alloc: std.mem.Allocator, files: []const FileEvidence) ![]FileEvidence {
    if (files.len == 0) return &.{};

    const copy = try alloc.alloc(FileEvidence, files.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) freeFileEvidence(alloc, copy[i]);
    }

    for (files, 0..) |file, i| {
        copy[i] = try dupeFileEvidence(alloc, file);
        copied += 1;
    }
    return copy;
}

pub fn freeFileEvidenceSlice(alloc: std.mem.Allocator, files: []FileEvidence) void {
    for (files) |file| freeFileEvidence(alloc, file);
    if (files.len > 0) alloc.free(files);
}

fn dupeFileEvidence(alloc: std.mem.Allocator, file: FileEvidence) !FileEvidence {
    const path = try alloc.dupe(u8, file.path);
    errdefer alloc.free(path);
    const new_path = if (file.new_path) |value| try alloc.dupe(u8, value) else null;
    errdefer if (new_path) |value| alloc.free(value);
    const tool_call_id = try alloc.dupe(u8, file.tool_call_id);
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, file.tool_name);
    return .{
        .path = path,
        .new_path = new_path,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .action = file.action,
        .status = file.status,
        .model_view_covers_full_file = file.model_view_covers_full_file,
        .stale = file.stale,
    };
}

/// Frees one entry's owned strings, not its containing slice.
pub fn freeFileEvidence(alloc: std.mem.Allocator, file: FileEvidence) void {
    alloc.free(file.path);
    if (file.new_path) |new_path| alloc.free(new_path);
    alloc.free(file.tool_call_id);
    alloc.free(file.tool_name);
}

pub fn dupeToolCall(alloc: std.mem.Allocator, call: ToolCall) !ToolCall {
    const id = try alloc.dupe(u8, call.id);
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, call.name);
    errdefer alloc.free(name);
    const arguments_json = try alloc.dupe(u8, call.arguments_json);
    errdefer alloc.free(arguments_json);
    const provisional_id = if (call.provisional_id) |value| try alloc.dupe(u8, value) else null;
    errdefer if (provisional_id) |value| alloc.free(value);
    const provider_result = if (call.provider_result) |result| try alloc.dupe(u8, result) else null;
    errdefer if (provider_result) |result| alloc.free(result);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
        .argument_integrity = call.argument_integrity,
        .argument_diagnostic = call.argument_diagnostic,
        .provisional_id = provisional_id,
        .provider_result = provider_result,
        .final_identity = call.final_identity,
        .provenance = call.provenance,
    };
}

pub fn freeToolCall(alloc: std.mem.Allocator, call: ToolCall) void {
    alloc.free(call.id);
    alloc.free(call.name);
    alloc.free(call.arguments_json);
    if (call.provisional_id) |provisional_id| alloc.free(provisional_id);
    if (call.provider_result) |provider_result| alloc.free(provider_result);
}

pub fn freeUserTurn(alloc: std.mem.Allocator, user: UserTurn) void {
    alloc.free(user.text);
    freeImageAttachmentSlice(alloc, user.images);
    if (user.work_id) |work_id| alloc.free(work_id);
}

pub fn dupeUserTurn(alloc: std.mem.Allocator, user: UserTurn) !UserTurn {
    const text = try alloc.dupe(u8, user.text);
    errdefer alloc.free(text);

    const images = try dupeImageAttachmentSlice(alloc, user.images);
    errdefer freeImageAttachmentSlice(alloc, images);

    const work_id = if (user.work_id) |value| try alloc.dupe(u8, value) else null;

    return .{
        .text = text,
        .images = images,
        .work_id = work_id,
    };
}

pub fn dupeImageAttachmentSlice(alloc: std.mem.Allocator, attachments: []const ImageAttachment) ![]ImageAttachment {
    if (attachments.len == 0) return &.{};

    const copy = try alloc.alloc(ImageAttachment, attachments.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            freeImageAttachment(alloc, copy[i]);
        }
    }

    for (attachments, 0..) |attachment, i| {
        const path = try alloc.dupe(u8, attachment.path);
        errdefer alloc.free(path);

        const media_type = try alloc.dupe(u8, attachment.media_type);
        errdefer alloc.free(media_type);

        const snapshot_path = if (attachment.snapshot_path) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (snapshot_path) |value| alloc.free(value);

        const snapshot_sha256 = if (attachment.snapshot_sha256) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (snapshot_sha256) |value| alloc.free(value);

        const inline_data = if (attachment.inline_data) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (inline_data) |value| alloc.free(value);
        copy[i] = .{
            .id = attachment.id,
            .path = path,
            .media_type = media_type,
            .snapshot_path = snapshot_path,
            .snapshot_sha256 = snapshot_sha256,
            .inline_data = inline_data,
        };
        copied += 1;
    }
    return copy;
}

/// Frees the owned fields in one attachment; caller owns any containing storage.
pub fn freeImageAttachment(alloc: std.mem.Allocator, attachment: ImageAttachment) void {
    alloc.free(attachment.path);
    alloc.free(attachment.media_type);
    if (attachment.snapshot_path) |path| alloc.free(path);
    if (attachment.snapshot_sha256) |sha256| alloc.free(sha256);
    if (attachment.inline_data) |data| alloc.free(data);
}

pub fn freeImageAttachmentSlice(alloc: std.mem.Allocator, attachments: []ImageAttachment) void {
    if (attachments.len == 0) return;
    for (attachments) |attachment| freeImageAttachment(alloc, attachment);
    alloc.free(attachments);
}

pub fn dupePermissionGrantSlice(alloc: std.mem.Allocator, grants: []const PermissionGrant) ![]PermissionGrant {
    const copy = try alloc.alloc(PermissionGrant, grants.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            alloc.free(copy[i].tool_name);
            alloc.free(copy[i].target_path);
        }
    }

    for (grants, 0..) |grant, i| {
        const tool_name = try alloc.dupe(u8, grant.tool_name);
        errdefer alloc.free(tool_name);

        const target_path = try alloc.dupe(u8, grant.target_path);
        copy[i] = .{
            .tool_name = tool_name,
            .target_path = target_path,
        };
        copied += 1;
    }

    return copy;
}

pub fn freePermissionGrantSlice(alloc: std.mem.Allocator, grants: []PermissionGrant) void {
    for (grants) |grant| {
        alloc.free(grant.tool_name);
        alloc.free(grant.target_path);
    }
    alloc.free(grants);
}

pub fn dupePermissionRuleSlice(alloc: std.mem.Allocator, rules: []const PermissionRule) ![]PermissionRule {
    if (rules.len == 0) return &.{};

    const copy = try alloc.alloc(PermissionRule, rules.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            alloc.free(copy[i].permission);
            alloc.free(copy[i].pattern);
        }
    }

    for (rules, 0..) |rule, i| {
        const permission = try alloc.dupe(u8, rule.permission);
        errdefer alloc.free(permission);

        const pattern = try alloc.dupe(u8, rule.pattern);
        copy[i] = .{
            .permission = permission,
            .pattern = pattern,
            .action = rule.action,
        };
        copied += 1;
    }

    return copy;
}

pub fn freePermissionRuleSlice(alloc: std.mem.Allocator, rules: []PermissionRule) void {
    if (rules.len == 0) return;
    for (rules) |rule| {
        alloc.free(rule.permission);
        alloc.free(rule.pattern);
    }
    alloc.free(rules);
}

pub fn dupePermissionRuleSet(alloc: std.mem.Allocator, rules: PermissionRuleSet) !PermissionRuleSet {
    return .{
        .rules = try dupePermissionRuleSlice(alloc, rules.rules),
    };
}

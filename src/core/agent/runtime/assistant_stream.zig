const std = @import("std");
const types = @import("../../shared/types.zig");
const text_utils = @import("../../shared/text_utils.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const assistant_presentation = @import("../assistant_presentation.zig");
const io_mod = @import("../../shared/io.zig");

const runtime_deps = @import("deps.zig");
const runtime_telemetry = @import("telemetry.zig");
const runtime_tool_presentation = @import("tool_presentation.zig");
const response_language = @import("response_language.zig");

const Allocator = std.mem.Allocator;
const sanitizeAssistantText = text_utils.sanitizeAssistantText;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const TablePayload = assistant_presentation.TablePayload;
const CodeBlockPayload = assistant_presentation.CodeBlockPayload;
const response_language_probe_limit_bytes: usize = 4096;

pub const SemanticPresentationSink = struct {
    ctx: *anyopaque,
    /// Takes ownership of `table` only when it returns successfully.
    table: *const fn (ctx: *anyopaque, table: TablePayload) anyerror!void,
    /// Takes ownership of `block` only when it returns successfully.
    code_block: *const fn (ctx: *anyopaque, block: CodeBlockPayload) anyerror!void,
    thematic_rule: *const fn (ctx: *anyopaque) anyerror!void,
};

pub const StreamChunkContext = struct {
    hooks: *const AgentRuntimeDeps,
    flush_assistant_stream_per_content_chunk: bool = false,
    semantic_presentation: ?SemanticPresentationSink = null,
    token_progress: ?*runtime_telemetry.TurnSummaryAccumulator = null,
    turn_id: u64,
    step_id: u64 = 0,
    alloc: Allocator = std.heap.c_allocator,
    saw_visible_text: bool = false,
    saw_tool_start: bool = false,
    saw_provider_tool_start: bool = false,
    saw_visible_text_after_tool_start: bool = false,
    last_byte_was_newline: bool = false,
    trailing_newline_count: u8 = 0,
    first_model_output_at_ms: ?i64 = null,
    markdown: assistant_presentation.MarkdownProcessor = .{},
    raw_text: std.ArrayList(u8) = .empty,
    /// Every streamed byte counts as progress for the stall detector: text,
    /// reasoning, and tool-input chunks alike. A turn composing one large
    /// tool call must not read as zero progress.
    streamed_output_bytes: usize = 0,
    interrupted_source: std.ArrayList(u8) = .empty,
    response_started: bool = false,
    published_phase: ?types.TurnPhase = null,
    initial_line_prefix: std.ArrayList(u8) = .empty,
    provisional_statuses: runtime_tool_presentation.ProvisionalToolStatuses = .{},
    response_language_expected: ?response_language.Script = null,
    response_language_accepted: bool = false,
    response_language_hold_until_completion: bool = false,
    response_language_next_probe_bytes: usize = 5,

    fn markModelOutput(self: *StreamChunkContext) void {
        if (self.first_model_output_at_ms == null) self.first_model_output_at_ms = io_mod.milliTimestamp();
    }

    fn recordTextOutput(self: *StreamChunkContext, text: []const u8) void {
        if (text.len > 0 and self.saw_tool_start) {
            self.saw_visible_text_after_tool_start = true;
        }
        var trailing: usize = 0;
        while (trailing < text.len and text[text.len - trailing - 1] == '\n') : (trailing += 1) {}
        if (trailing == 0) {
            self.last_byte_was_newline = false;
            self.trailing_newline_count = 0;
            return;
        }

        self.last_byte_was_newline = true;
        const bounded: u8 = @intCast(@min(trailing, @as(usize, 2)));
        self.trailing_newline_count = if (trailing == text.len)
            @min(2, self.trailing_newline_count + bounded)
        else
            bounded;
    }

    fn recordSemanticBoundary(self: *StreamChunkContext) void {
        if (self.saw_tool_start) {
            self.saw_visible_text_after_tool_start = true;
        }
        self.last_byte_was_newline = true;
        self.trailing_newline_count = 1;
    }

    pub fn deinit(self: *StreamChunkContext) void {
        self.markdown.deinit(self.alloc);
        self.raw_text.deinit(self.alloc);
        self.interrupted_source.deinit(self.alloc);
        self.initial_line_prefix.deinit(self.alloc);
        self.provisional_statuses.deinit(self.alloc);
    }

    pub fn start_response(self: *StreamChunkContext) !void {
        if (self.response_started) return;
        try self.hooks.push_text(self.hooks.ctx, .assistant_started);
        self.response_started = true;
    }

    pub fn beginRecoveryAttempt(self: *StreamChunkContext) !void {
        if (self.response_language_staging()) {
            self.drop_staged_response_language_candidate();
        }
        if (self.raw_text.items.len > 0) {
            try flushAssistantStream(self);
            try self.hooks.push_text(self.hooks.ctx, .{
                .assistant_restarted = "\n\n[Response interrupted. Restarting.]\n\n",
            });
            debug_trace.logf("agent", "restarting response preview_bytes={d} superseded_preview_bytes={d}", .{
                self.raw_text.items.len,
                self.interrupted_source.items.len,
            });
            std.mem.swap(std.ArrayList(u8), &self.raw_text, &self.interrupted_source);
            self.raw_text.clearRetainingCapacity();
        }
        self.markdown.deinit(self.alloc);
        self.markdown = .{};
        self.initial_line_prefix.clearRetainingCapacity();
        self.saw_visible_text = false;
        self.response_started = false;
        self.last_byte_was_newline = false;
        self.trailing_newline_count = 0;
        self.response_language_accepted = false;
        self.response_language_next_probe_bytes = 5;
        self.saw_tool_start = false;
        self.saw_provider_tool_start = false;
        self.saw_visible_text_after_tool_start = false;
        self.first_model_output_at_ms = null;
        self.streamed_output_bytes = 0;
        self.published_phase = null;
    }

    pub fn accepted_source(self: *const StreamChunkContext) []const u8 {
        return if (self.response_language_staging()) "" else self.raw_text.items;
    }

    pub fn accepted_source_or(self: *const StreamChunkContext, fallback: []const u8) []const u8 {
        if (self.response_language_staging()) return "";
        return if (self.raw_text.items.len > 0) self.raw_text.items else fallback;
    }

    pub fn interruption_source_or(self: *const StreamChunkContext, fallback: []const u8) []const u8 {
        if (!self.response_language_staging()) {
            if (self.raw_text.items.len > 0) return self.raw_text.items;
            return if (fallback.len > 0) fallback else self.interrupted_source.items;
        }
        const candidate = if (self.raw_text.items.len > 0) self.raw_text.items else fallback;
        if (candidate.len == 0) return self.interrupted_source.items;
        const actual = response_language.evidence(candidate).script orelse return candidate;
        return if (actual == self.response_language_expected.?) candidate else self.interrupted_source.items;
    }

    pub fn accept_staged_response_language(self: *StreamChunkContext) !void {
        if (!self.response_language_staging()) return;
        self.response_language_accepted = true;
        try publishAssistantChunkResolved(self, self.raw_text.items);
    }

    pub fn drop_staged_response_language_candidate(self: *StreamChunkContext) void {
        if (!self.response_language_staging()) return;
        if (self.raw_text.items.len > 0) {
            debug_trace.logf(
                "agent",
                "dropping rejected response language candidate bytes={d}",
                .{self.raw_text.items.len},
            );
        }
        self.raw_text.clearRetainingCapacity();
        self.initial_line_prefix.clearRetainingCapacity();
        self.saw_visible_text = false;
        self.last_byte_was_newline = false;
        self.trailing_newline_count = 0;
        self.response_language_next_probe_bytes = 5;
    }

    fn response_language_staging(self: *const StreamChunkContext) bool {
        return self.response_language_expected != null and
            !self.response_language_accepted;
    }

    /// Restores durable partial source before a restarted turn sends anything.
    /// The next attempt retains it as interruption evidence and starts fresh.
    /// Surfaces that already show the preview do not emit it again here.
    pub fn restoreRecoverySource(
        self: *StreamChunkContext,
        source: []const u8,
        already_presented: bool,
    ) !void {
        if (source.len == 0) return;
        if (already_presented) {
            try self.raw_text.appendSlice(self.alloc, source);
            self.response_language_accepted = true;
            return;
        }
        try streamAssistantChunk(self, source);
        try flushAssistantStream(self);
    }
};

pub fn onStreamContentChunk(ctx: *anyopaque, chunk: []const u8) void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(ctx));
    stream_ctx.markModelOutput();
    stream_ctx.streamed_output_bytes += chunk.len;
    publishTurnPhase(stream_ctx, .generating);
    if (stream_ctx.token_progress) |progress| {
        pushTokenProgressUpdate(stream_ctx, progress.consumeContent(chunk)) catch |err| {
            debug_trace.logf("agent", "token progress publication failed source=content err={s}", .{@errorName(err)});
        };
    }
    streamAssistantChunk(stream_ctx, chunk) catch {};
    if (stream_ctx.flush_assistant_stream_per_content_chunk) {
        flushAssistantStream(stream_ctx) catch {};
    }
}

pub fn onStreamReasoningChunk(ctx: *anyopaque, chunk: []const u8) void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(ctx));
    stream_ctx.markModelOutput();
    stream_ctx.streamed_output_bytes += chunk.len;
    publishTurnPhase(stream_ctx, .thinking);
    if (stream_ctx.token_progress) |progress| {
        pushTokenProgressUpdate(stream_ctx, progress.consumeReasoning(chunk)) catch |err| {
            debug_trace.logf("agent", "token progress publication failed source=reasoning err={s}", .{@errorName(err)});
        };
    }
    if (stream_ctx.hooks.push_reasoning_delta) |push| {
        push(stream_ctx.hooks.ctx, chunk) catch |err| {
            debug_trace.logf("agent", "reasoning publication failed err={s}", .{@errorName(err)});
        };
    }
}

pub fn publishTurnPhase(stream_ctx: *StreamChunkContext, phase: types.TurnPhase) void {
    if (stream_ctx.published_phase == phase) return;
    stream_ctx.hooks.push_event(stream_ctx.hooks.ctx, .{ .turn_phase_update = .{
        .turn_id = stream_ctx.turn_id,
        .step_id = stream_ctx.step_id,
        .phase = phase,
    } }) catch |err| {
        debug_trace.logf("agent", "turn phase publication failed phase={s} err={s}", .{ @tagName(phase), @errorName(err) });
        return;
    };
    stream_ctx.published_phase = phase;
}

pub fn onStreamToolInputChunk(ctx: *anyopaque, chunk: []const u8) void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(ctx));
    stream_ctx.streamed_output_bytes += chunk.len;
    publishTurnPhase(stream_ctx, .running);
    if (stream_ctx.token_progress) |progress| {
        pushTokenProgressUpdate(stream_ctx, progress.consumeToolInput(chunk)) catch |err| {
            debug_trace.logf("agent", "token progress publication failed source=tool_input err={s}", .{@errorName(err)});
        };
    }
}

pub fn pushTokenProgressUpdate(stream_ctx: *StreamChunkContext, update: runtime_telemetry.TokenProgressUpdate) !void {
    switch (update) {
        .unchanged => {},
        .changed => {
            const progress = stream_ctx.token_progress orelse return;
            try stream_ctx.hooks.push_event(stream_ctx.hooks.ctx, .{ .turn_token_update = progress.tokenProgress() });
        },
        .invalid => debug_trace.logf("agent", "token progress observation ignored reason=invalid_sequence", .{}),
    }
}

pub fn onStreamToolStart(ctx: *anyopaque, tool_id: []const u8, tool_name: []const u8, label_value: ?[]const u8, arguments_json: ?[]const u8) void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(ctx));
    const first_tool_in_step = !stream_ctx.saw_tool_start;
    recordStreamToolStart(ctx, tool_name);
    const preflight = runtime_tool_presentation.ProvisionalToolStatuses.preflight(stream_ctx.hooks.tool_registry, tool_name) orelse {
        publishTurnPhase(stream_ctx, .running);
        return;
    };
    stream_ctx.markModelOutput();
    flushAssistantStream(stream_ctx) catch {};
    if (stream_ctx.saw_visible_text and !stream_ctx.last_byte_was_newline) {
        stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_rendered = "\n" }) catch {};
        stream_ctx.recordTextOutput("\n");
    }
    if (first_tool_in_step and
        stream_ctx.saw_visible_text and
        stream_ctx.turn_id != 0 and
        stream_ctx.step_id != 0)
    {
        stream_ctx.provisional_statuses.presentation_group_id = .{
            .turn_id = stream_ctx.turn_id,
            .anchor_step_id = stream_ctx.step_id,
        };
    }
    publishTurnPhase(stream_ctx, .running);
    switch (preflight) {
        // Published last: the flush above can push the response's trailing
        // newline, and any text landing after the notice reopens the response
        // row.
        .ineligible => {},
        .eligible => |metadata| stream_ctx.provisional_statuses.publish(
            stream_ctx.hooks,
            stream_ctx.alloc,
            stream_ctx.turn_id,
            tool_id,
            tool_name,
            metadata.activity_kind,
            metadata.action_label,
            label_value,
            arguments_json,
        ) catch {},
    }
}

pub fn recordStreamToolStart(ctx: *anyopaque, tool_name: []const u8) void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(ctx));
    stream_ctx.saw_tool_start = true;
    if (runtime_tool_presentation.streamStartMayHaveExecutedAtProvider(
        stream_ctx.hooks.tool_registry,
        tool_name,
    )) {
        stream_ctx.saw_provider_tool_start = true;
    }
}

fn streamAssistantChunk(stream_ctx: *StreamChunkContext, chunk: []const u8) !void {
    if (chunk.len == 0) return;
    const alloc = stream_ctx.alloc;
    try stream_ctx.raw_text.appendSlice(alloc, chunk);
    if (stream_ctx.response_language_staging()) {
        if (stream_ctx.response_language_hold_until_completion) return;
        if (stream_ctx.raw_text.items.len >= stream_ctx.response_language_next_probe_bytes) {
            const prefix_len = @min(
                stream_ctx.raw_text.items.len,
                response_language_probe_limit_bytes,
            );
            const prefix = stream_ctx.raw_text.items[0..prefix_len];
            if (response_language.evidence(prefix).script == stream_ctx.response_language_expected) {
                try stream_ctx.accept_staged_response_language();
            } else if (prefix_len == response_language_probe_limit_bytes) {
                stream_ctx.response_language_next_probe_bytes = std.math.maxInt(usize);
            } else {
                stream_ctx.response_language_next_probe_bytes = @min(
                    response_language_probe_limit_bytes,
                    @max(stream_ctx.raw_text.items.len +| 1, stream_ctx.raw_text.items.len *| 2),
                );
            }
        }
        return;
    }
    try publishAssistantChunkResolved(stream_ctx, chunk);
}

fn publishAssistantChunkResolved(stream_ctx: *StreamChunkContext, chunk: []const u8) !void {
    if (chunk.len == 0) return;
    const alloc = stream_ctx.alloc;
    try stream_ctx.start_response();
    try stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_source = chunk });
    if (!stream_ctx.hooks.render_assistant_text) {
        if (std.mem.trim(u8, chunk, " \t\r\n").len > 0) stream_ctx.saw_visible_text = true;
        stream_ctx.recordTextOutput(chunk);
        return;
    }

    var start: usize = 0;
    var initial_prefix_to_emit: ?[]const u8 = null;
    var clear_initial_line_prefix = false;
    defer if (clear_initial_line_prefix) stream_ctx.initial_line_prefix.clearRetainingCapacity();
    if (!stream_ctx.saw_visible_text) {
        while (start < chunk.len and isTrimmedAssistantPrefixByte(chunk[start])) : (start += 1) {
            switch (chunk[start]) {
                ' ', '\t' => try stream_ctx.initial_line_prefix.append(alloc, chunk[start]),
                '\n' => stream_ctx.initial_line_prefix.clearRetainingCapacity(),
                else => {},
            }
        }
        if (start == chunk.len) return;
        if (hasResponseLeadingIndentedCodePrefix(stream_ctx.initial_line_prefix.items)) {
            initial_prefix_to_emit = stream_ctx.initial_line_prefix.items;
        }
        stream_ctx.saw_visible_text = true;
        clear_initial_line_prefix = true;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var completion = assistant_presentation.TableCompletion{
        .ctx = stream_ctx,
        .deliver = deliverSemanticTable,
    };
    var code_completion = assistant_presentation.CodeBlockCompletion{
        .ctx = stream_ctx,
        .deliver = deliverSemanticCodeBlock,
    };
    var thematic_rule_completion = assistant_presentation.ThematicRuleCompletion{
        .ctx = stream_ctx,
        .deliver = deliverSemanticThematicRule,
    };
    const table_completion: ?*const assistant_presentation.TableCompletion = if (stream_ctx.semantic_presentation != null)
        &completion
    else
        null;
    const semantic_code_completion: ?*const assistant_presentation.CodeBlockCompletion = if (stream_ctx.semantic_presentation != null)
        &code_completion
    else
        null;
    const semantic_thematic_rule_completion: ?*const assistant_presentation.ThematicRuleCompletion = if (stream_ctx.semantic_presentation != null)
        &thematic_rule_completion
    else
        null;
    if (initial_prefix_to_emit) |prefix| {
        try stream_ctx.markdown.pushWithCompletions(alloc, prefix, &out, .{
            .table = table_completion,
            .code = semantic_code_completion,
            .thematic_rule = semantic_thematic_rule_completion,
        });
    }
    try stream_ctx.markdown.pushWithCompletions(alloc, chunk[start..], &out, .{
        .table = table_completion,
        .code = semantic_code_completion,
        .thematic_rule = semantic_thematic_rule_completion,
    });
    if (out.items.len == 0) return;
    try stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_rendered = out.items });
    stream_ctx.recordTextOutput(out.items);
}

pub fn flushAssistantStream(stream_ctx: *StreamChunkContext) !void {
    if (stream_ctx.response_language_staging()) return;
    if (!stream_ctx.hooks.render_assistant_text) return;
    const alloc = stream_ctx.alloc;
    stream_ctx.initial_line_prefix.clearRetainingCapacity();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var completion = assistant_presentation.TableCompletion{
        .ctx = stream_ctx,
        .deliver = deliverSemanticTable,
    };
    var code_completion = assistant_presentation.CodeBlockCompletion{
        .ctx = stream_ctx,
        .deliver = deliverSemanticCodeBlock,
    };
    var thematic_rule_completion = assistant_presentation.ThematicRuleCompletion{
        .ctx = stream_ctx,
        .deliver = deliverSemanticThematicRule,
    };
    const table_completion: ?*const assistant_presentation.TableCompletion = if (stream_ctx.semantic_presentation != null)
        &completion
    else
        null;
    const semantic_code_completion: ?*const assistant_presentation.CodeBlockCompletion = if (stream_ctx.semantic_presentation != null)
        &code_completion
    else
        null;
    const semantic_thematic_rule_completion: ?*const assistant_presentation.ThematicRuleCompletion = if (stream_ctx.semantic_presentation != null)
        &thematic_rule_completion
    else
        null;
    try stream_ctx.markdown.flushWithCompletions(alloc, &out, .{
        .table = table_completion,
        .code = semantic_code_completion,
        .thematic_rule = semantic_thematic_rule_completion,
    });
    if (out.items.len == 0) return;
    const text = if (stream_ctx.trailing_newline_count >= 2 and beginsFootnoteProjection(out.items))
        out.items[1..]
    else
        out.items;
    try stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_rendered = text });
    stream_ctx.recordTextOutput(text);
}

fn beginsFootnoteProjection(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "\n\x1b[2m[");
}

fn deliverSemanticTable(raw: *anyopaque, table: TablePayload, out: *std.ArrayList(u8)) !void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(raw));
    const alloc = stream_ctx.alloc;

    if (out.items.len > 0) {
        try stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_rendered = out.items });
        stream_ctx.recordTextOutput(out.items);
        out.clearRetainingCapacity();
    }

    var compatibility: std.ArrayList(u8) = .empty;
    defer compatibility.deinit(alloc);
    try assistant_presentation.renderTablePayload(alloc, table, &compatibility);
    const sink = stream_ctx.semantic_presentation orelse return error.MissingTableSink;
    try sink.table(sink.ctx, table);
    stream_ctx.recordSemanticBoundary();
}

fn deliverSemanticCodeBlock(raw: *anyopaque, block: CodeBlockPayload, out: *std.ArrayList(u8)) !void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(raw));
    const alloc = stream_ctx.alloc;

    if (out.items.len > 0) {
        try stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_rendered = out.items });
        stream_ctx.recordTextOutput(out.items);
        out.clearRetainingCapacity();
    }

    var compatibility: std.ArrayList(u8) = .empty;
    defer compatibility.deinit(alloc);
    try assistant_presentation.renderCodeBlockPayload(alloc, block, &compatibility);
    const sink = stream_ctx.semantic_presentation orelse return error.MissingCodeBlockSink;
    try sink.code_block(sink.ctx, block);
    stream_ctx.recordSemanticBoundary();
}

fn deliverSemanticThematicRule(raw: *anyopaque, out: *std.ArrayList(u8)) !void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(raw));
    const alloc = stream_ctx.alloc;

    if (out.items.len > 0) {
        try stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_rendered = out.items });
        stream_ctx.recordTextOutput(out.items);
        out.clearRetainingCapacity();
    }

    var compatibility: std.ArrayList(u8) = .empty;
    defer compatibility.deinit(alloc);
    try assistant_presentation.writeHorizontalRule(alloc, &compatibility);
    const sink = stream_ctx.semantic_presentation orelse return error.MissingThematicRuleSink;
    try sink.thematic_rule(sink.ctx);
    stream_ctx.recordSemanticBoundary();
}

pub fn emitProviderLengthNotice(hooks: *const AgentRuntimeDeps, arena: Allocator, disposition: types.ProviderCompletionDisposition) !void {
    if (disposition != .length_limited) return;
    const line = try arena.print("response hit provider length limit; output may be incomplete", .{});
    try hooks.push_system_notice(hooks.ctx, line);
}

pub fn finishLengthLimitedToolCallCompletion(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    completion: types.ModelCompletion,
    streamed_content_len: usize,
) ![]const u8 {
    const blocker = "Provider response hit the length limit, so I did not execute the returned tool calls. Latest partial response is preserved above; retry with a narrower prompt or inspect stored tool output before continuing.";

    const has_content = completion.content != null and completion.content.?.len > 0;
    const normalized = if (has_content) try normalizeAssistantTextForDisplay(arena, completion.content.?) else "";
    const rendered = if (normalized.len > 0)
        try arena.print("{s}\n\n{s}", .{ normalized, blocker })
    else
        blocker;

    if (!has_content or streamed_content_len == 0) {
        if (has_content) {
            try hooks.push_text(hooks.ctx, .{ .assistant_source = completion.content.? });
            try hooks.push_text(hooks.ctx, .{ .assistant_rendered = normalized });
            try hooks.push_text(hooks.ctx, .{ .operational = "\n\n" });
        }
        try hooks.push_text(hooks.ctx, .{ .operational = blocker });
        try hooks.push_text(hooks.ctx, .{ .operational = "\n" });
    } else {
        try hooks.push_text(hooks.ctx, .{ .operational = "\n" });
        try hooks.push_text(hooks.ctx, .{ .operational = blocker });
        try hooks.push_text(hooks.ctx, .{ .operational = "\n" });
    }
    return rendered;
}

pub fn normalizeAssistantTextForDisplay(alloc: Allocator, raw_text: []const u8) ![]u8 {
    const base = sanitizeAssistantText(raw_text);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var saw_visible_text = false;
    var pending_stars: u8 = 0;

    for (base) |byte| {
        if (!saw_visible_text and isTrimmedAssistantPrefixByte(byte)) {
            continue;
        }
        saw_visible_text = true;

        if (byte == '*') {
            if (pending_stars < std.math.maxInt(u8)) {
                pending_stars += 1;
            }
            continue;
        }
        pending_stars = 0;

        if (byte == '`') continue;
        try out.writer.writeByte(byte);
    }

    const rendered = std.mem.trimEnd(u8, out.written(), " \t\r\n");
    const owned = try out.toOwnedSlice();
    if (rendered.len == owned.len) return owned;

    const trimmed = try alloc.dupe(u8, rendered);
    alloc.free(owned);
    return trimmed;
}

pub fn textForCompletedPresentation(raw_text: []const u8, normalized_text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, raw_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            return raw_text;
        }
    }
    return normalized_text;
}

fn isTrimmedAssistantPrefixByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn hasResponseLeadingIndentedCodePrefix(prefix: []const u8) bool {
    return prefix.len > 0 and (prefix[0] == '\t' or (prefix.len >= 4 and std.mem.eql(u8, prefix[0..4], "    ")));
}

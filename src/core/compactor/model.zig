//! How fx-compactor asks a model for the summary: the conversation's own
//! model, with the least reasoning it accepts. If that call fails, refuses,
//! or returns nothing, the gateway tries once more with another model family.
//! A request right after the conversation instead keeps the agent's own
//! settings, reasoning too: the provider reuses its cache only for the same
//! settings. The caller of fx-compactor hands in the `ModelCaller` that
//! reaches them.

const std = @import("std");
const summarize = @import("summarize.zig");
const trace = @import("trace.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// A summary larger than this is not a summary; it only bounds memory.
const max_summary_bytes = 8 * 1024 * 1024;

/// Reaches the conversation's model, and other models through the same
/// provider and credential.
pub const ModelCaller = struct {
    context: *anyopaque,
    vtable: *const VTable,
    /// The conversation's model.
    model: []const u8,
    provider: model_provider.ProviderId,
    credential_source: ?types.CredentialSource,
    /// The caller can send a request right after the conversation, exactly
    /// as the agent was about to send it, so the provider can reuse what it
    /// cached of it.
    sends_after_conversation: bool = false,

    pub const VTable = struct {
        /// What `model` accepts.
        capabilities: *const fn (context: *anyopaque, model: []const u8) model_capabilities.Capabilities,
        /// Sends one request and waits for the whole reply.
        send: *const fn (context: *anyopaque, alloc: Allocator, call: Call) CallError!Reply,
    };
};

/// One request: a system message and one user message, no tools. Or, with
/// `after_conversation`, the conversation as the agent sends it, with the
/// agent's own settings, then `user` as one more user message; `system` and
/// `reasoning` are not used.
pub const Call = struct {
    model: []const u8,
    reasoning: ?types.ReasoningEffort,
    system: []const u8,
    user: []const u8,
    after_conversation: bool = false,
    /// Longest reply kept; a longer one counts as truncated.
    max_bytes: usize,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
};

pub const CallError = error{ Cancelled, OutOfMemory };

pub const FailureReason = enum { transport, provider, tool_call, incomplete, truncated };

pub const Reply = union(enum) {
    /// Allocated with the `alloc` given to `send`.
    text: []u8,
    /// No usable text. `detail` names the cause in `key=value` form for the
    /// trace; allocated with the `alloc` given to `send`.
    failed: struct { reason: FailureReason, detail: []u8 },
};

/// The least reasoning a model accepts: `none` when it can turn reasoning
/// off, otherwise its lowest level (levels are listed lowest first). Null
/// when the model offers no levels to choose from.
fn lowestReasoningEffort(capabilities: model_capabilities.Capabilities) ?types.ReasoningEffort {
    const options = capabilities.reasoning_efforts.slice();
    for (options) |option| {
        if (option.eql(types.ReasoningEffort.literal("none"))) return option;
    }
    return if (options.len > 0) options[0] else null;
}

/// The model the summary step calls, remembering how many summaries it
/// wrote and whether it fell back.
pub const Summarizer = struct {
    caller: ModelCaller,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
    summaries: usize = 0,
    fallback_used: ?[]const u8 = null,

    pub fn model(self: *Summarizer) summarize.Model {
        return .{ .context = self, .summarize_fn = summarizeWith };
    }

    fn summarizeWith(context: *anyopaque, alloc: Allocator, prompt: summarize.Prompt) summarize.ModelError![]u8 {
        const self: *Summarizer = @ptrCast(@alignCast(context));
        self.summaries += 1;
        // Only the conversation's own model has it cached; when it fails,
        // the summary step writes the turns out instead.
        if (prompt.after_conversation) return self.ask(alloc, prompt, prompt.model);
        var primary_error: ?summarize.ModelError = null;
        if (self.ask(alloc, prompt, prompt.model)) |text| {
            if (std.mem.trim(u8, text, " \t\r\n").len > 0) return text;
            alloc.free(text);
        } else |err| {
            if (err == error.Cancelled or err == error.OutOfMemory) return err;
            primary_error = err;
        }
        // An empty reply becomes the summary step's EmptySummary error.
        if (primary_error) |err| return err;
        return alloc.dupe(u8, "");
    }

    /// One summary request to `model_name`, at its lowest reasoning.
    fn ask(self: *Summarizer, alloc: Allocator, prompt: summarize.Prompt, model_name: []const u8) summarize.ModelError![]u8 {
        const caller = self.caller;
        const reply = try caller.vtable.send(caller.context, alloc, .{
            .model = model_name,
            .reasoning = if (prompt.after_conversation) null else lowestReasoningEffort(caller.vtable.capabilities(caller.context, model_name)),
            .system = prompt.system,
            .user = prompt.user,
            .after_conversation = prompt.after_conversation,
            .max_bytes = max_summary_bytes,
            .cancel_flag = self.cancel_flag,
            .trace_ctx = self.trace_ctx,
        });
        const failure = switch (reply) {
            .text => |text| return text,
            .failed => |failure| failure,
        };
        defer alloc.free(failure.detail);
        switch (failure.reason) {
            .transport, .provider => trace.failure(self.trace_ctx, .summary_transport_failed, "model={s} {s}", .{ model_name, failure.detail }),
            .tool_call => trace.failure(self.trace_ctx, .summary_tool_call_rejected, "model={s}", .{model_name}),
            .incomplete => {
                trace.failure(self.trace_ctx, .summary_incomplete, "model={s} {s}", .{ model_name, failure.detail });
                return error.SummaryIncomplete;
            },
            .truncated => trace.failure(self.trace_ctx, .summary_truncated, "model={s} {s}", .{ model_name, failure.detail }),
        }
        return error.ModelFailed;
    }
};

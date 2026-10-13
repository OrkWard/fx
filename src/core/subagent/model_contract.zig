const std = @import("std");
const domain = @import("domain.zig");
const types = @import("../shared/types.zig");
const session_commands = @import("../session/session_commands.zig");

const Allocator = std.mem.Allocator;

const max_error_code_bytes: usize = 64;

/// Catalog candidates surfaced for ambiguous or unknown model overrides.
pub const max_model_match_candidates: usize = 4;

/// Outcome of matching a requested model override against the cached catalog.
/// Returned slices are allocated from the allocator passed to
/// `matchCatalogModel`; the caller owns them.
pub const ModelCatalogMatch = union(enum) {
    /// No catalog entries were available; the override passes through unchanged.
    no_catalog,
    /// Exactly one catalog entry is the best match.
    matched: []const u8,
    /// Several entries tie as the best confident match.
    ambiguous: []const []const u8,
    /// No confident match; carries close but inconclusive entries (may be empty).
    unknown: []const []const u8,
};

/// Matches a model override against catalog IDs using the same scoring as
/// interactive `/model` selection. Exact (case-insensitive) IDs and unique
/// confident matches resolve; confident ties and weak matches do not.
pub fn matchCatalogModel(
    alloc: Allocator,
    ids: []const []const u8,
    query: []const u8,
) Allocator.Error!ModelCatalogMatch {
    if (ids.len == 0) return .no_catalog;
    for (ids) |id| {
        if (std.ascii.eqlIgnoreCase(id, query)) {
            return .{ .matched = try alloc.dupe(u8, id) };
        }
    }
    // Confident matches contain the query verbatim (case-insensitive). Every
    // fuzzyModelScore band that may resolve (prefix, substring, suffix after
    // the provider slash) requires substring membership, while its weaker
    // token and subsequence bands can reach the same numeric scores without
    // it, so a score threshold alone would let scrambled paraphrases resolve.
    var confident_best: i32 = 0;
    var confident_count: usize = 0;
    var confident_id: ?[]const u8 = null;
    var weak_best: i32 = 0;
    for (ids) |id| {
        const score = session_commands.fuzzyModelScore(id, query);
        if (containsIgnoreCase(id, query)) {
            if (confident_id == null or score > confident_best) {
                confident_best = score;
                confident_count = 1;
                confident_id = id;
            } else if (score == confident_best) {
                confident_count += 1;
            }
        } else if (score > weak_best) {
            weak_best = score;
        }
    }
    if (confident_id) |id| {
        if (confident_count == 1) return .{ .matched = try alloc.dupe(u8, id) };
        return .{ .ambiguous = try collectScoredMatches(alloc, ids, query, confident_best, true) };
    }
    if (weak_best == 0) return .{ .unknown = &.{} };
    return .{ .unknown = try collectScoredMatches(alloc, ids, query, weak_best, false) };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Collects up to `max_model_match_candidates` IDs at the target score,
/// optionally restricted to substring matches. Returned slices are owned by
/// the caller.
fn collectScoredMatches(
    alloc: Allocator,
    ids: []const []const u8,
    query: []const u8,
    target_score: i32,
    require_substring: bool,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |item| alloc.free(item);
        out.deinit(alloc);
    }
    for (ids) |id| {
        if (out.items.len == max_model_match_candidates) break;
        if (require_substring and !containsIgnoreCase(id, query)) continue;
        if (session_commands.fuzzyModelScore(id, query) != target_score) continue;
        try out.append(alloc, try alloc.dupe(u8, id));
    }
    return out.toOwnedSlice(alloc);
}

pub const Action = enum { run, message };

pub const RunInput = struct {
    task: []const u8,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
};
pub const MessageInput = struct {
    agent: []const u8,
    instructions: ?[]const u8 = null,
    message: []const u8,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
};
pub const RequestInput = union(Action) {
    run: RunInput,
    message: MessageInput,
};

/// Creation-time routing overrides carried by a request. Both default to the
/// parent's values; overrides apply only when a child session is created.
pub const Override = struct {
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,

    pub fn present(self: Override) bool {
        return self.model != null or self.effort != null;
    }
};

pub const Request = union(Action) {
    run: struct {
        task: []u8,
        model: ?[]u8 = null,
        effort: ?types.ReasoningEffort = null,
    },
    message: struct {
        agent: []u8,
        instructions: ?[]u8 = null,
        message: []u8,
        model: ?[]u8 = null,
        effort: ?types.ReasoningEffort = null,
    },
    pub fn deinit(self: *Request, alloc: Allocator) void {
        switch (self.*) {
            .run => |value| {
                alloc.free(value.task);
                if (value.model) |model| alloc.free(model);
            },
            .message => |value| {
                alloc.free(value.agent);
                if (value.instructions) |instructions| alloc.free(instructions);
                alloc.free(value.message);
                if (value.model) |model| alloc.free(model);
            },
        }
        self.* = undefined;
    }

    pub fn action(self: Request) Action {
        return std.meta.activeTag(self);
    }

    pub fn agentName(self: Request) ?[]const u8 {
        return switch (self) {
            .message => |value| value.agent,
            .run => null,
        };
    }

    /// Borrows from the request; the request must outlive the returned value.
    pub fn override(self: Request) Override {
        return switch (self) {
            .run => |value| .{ .model = value.model, .effort = value.effort },
            .message => |value| .{ .model = value.model, .effort = value.effort },
        };
    }
};

pub const ValidationError = error{
    OutOfMemory,
    InvalidTask,
    InvalidAgent,
    InvalidInstructions,
    InvalidMessage,
    InvalidModel,
    InvalidEffort,
};

pub fn validateRequest(
    alloc: Allocator,
    input: RequestInput,
) ValidationError!Request {
    return switch (input) {
        .run => |value| blk: {
            try validateText(value.task, domain.max_prompt_bytes, error.InvalidTask);
            const effort = try validateOverrideText(value.model, value.effort);
            const task = try alloc.dupe(u8, value.task);
            errdefer alloc.free(task);
            break :blk .{ .run = .{
                .task = task,
                .model = try dupeOptional(alloc, value.model),
                .effort = effort,
            } };
        },
        .message => |value| blk: {
            if (!domain.validAgentName(value.agent)) return error.InvalidAgent;
            if (value.instructions) |instructions| {
                if (instructions.len == 0 or
                    !domain.validInstructions(instructions))
                {
                    return error.InvalidInstructions;
                }
            }
            try validateText(value.message, domain.max_message_bytes, error.InvalidMessage);
            const effort = try validateOverrideText(value.model, value.effort);
            const agent = try alloc.dupe(u8, value.agent);
            errdefer alloc.free(agent);
            const instructions = if (value.instructions) |instructions|
                try alloc.dupe(u8, instructions)
            else
                null;
            errdefer if (instructions) |owned| alloc.free(owned);
            const message = try alloc.dupe(u8, value.message);
            errdefer alloc.free(message);
            break :blk .{ .message = .{
                .agent = agent,
                .instructions = instructions,
                .message = message,
                .model = try dupeOptional(alloc, value.model),
                .effort = effort,
            } };
        },
    };
}

/// Validates override text without allocating. Returns the parsed effort.
fn validateOverrideText(
    model: ?[]const u8,
    effort: ?[]const u8,
) ValidationError!?types.ReasoningEffort {
    if (model) |raw| try validateText(raw, domain.max_model_bytes, error.InvalidModel);
    if (effort) |raw| {
        return types.ReasoningEffort.parse(raw) orelse error.InvalidEffort;
    }
    return null;
}

/// Returns an owned copy the caller frees, or null. Never fails on null.
fn dupeOptional(alloc: Allocator, value: ?[]const u8) ValidationError!?[]u8 {
    return if (value) |raw| try alloc.dupe(u8, raw) else null;
}

fn validateText(
    value: []const u8,
    max_bytes: usize,
    invalid: ValidationError,
) ValidationError!void {
    if (value.len == 0 or value.len > max_bytes or
        !std.unicode.utf8ValidateSlice(value) or
        std.mem.findScalar(u8, value, 0) != null)
    {
        return invalid;
    }
}

pub const Kind = enum { one_off, persistent };
pub const Phase = @import("child_state.zig").Phase;
pub const Snapshot = struct {
    kind: Kind,
    phase: Phase,
};

pub const RejectCode = enum {
    child_unavailable,
    child_busy,
    child_not_persistent,
};

pub const Plan = union(enum) {
    create_one_off,
    create_persistent,
    continue_persistent,
    steer_persistent,
    reject: RejectCode,
};

pub fn plan(request: Request, snapshot: ?Snapshot) Plan {
    return switch (request) {
        .run => .create_one_off,
        .message => if (snapshot) |child| switch (child.kind) {
            .one_off => .{ .reject = .child_not_persistent },
            .persistent => switch (child.phase) {
                .idle, .interrupted => .continue_persistent,
                .running, .awaiting_approval => if (request.message.instructions != null)
                    .{ .reject = .child_busy }
                else
                    .steer_persistent,
                .finished => .{ .reject = .child_unavailable },
            },
        } else .create_persistent,
    };
}

pub fn requestFingerprint(request: Request) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.request.v1\x00");
    hash.update(@tagName(request.action()));
    hash.update("\x00");
    switch (request) {
        .run => |value| hash.update(value.task),
        .message => |value| {
            hash.update(value.agent);
            hash.update("\x00");
            if (value.instructions) |instructions| {
                hash.update("\x01");
                hash.update(instructions);
            } else {
                hash.update("\x00");
            }
            hash.update("\x00");
            hash.update(value.message);
        },
    }
    // Overrides extend the identity only when present so that override-less
    // requests keep their pre-override fingerprints in persisted registries.
    // The leading NUL is unambiguous: validated request text never contains
    // NUL, so the override section cannot be confused with task or message
    // content.
    const override = request.override();
    if (override.present()) {
        hash.update("\x00\x01");
        if (override.model) |model| {
            hash.update("\x01");
            hash.update(model);
        } else {
            hash.update("\x00");
        }
        hash.update("\x00");
        if (override.effort) |effort| {
            hash.update("\x01");
            hash.update(effort.label());
        } else {
            hash.update("\x00");
        }
    }
    return hash.finalResult();
}

pub const steering_pending_result = "The subagent is still running. Handle the user's steering now. Its result will arrive automatically; do not delegate again to poll for it.";

pub const Result = struct {
    ok: bool,
    pending: bool = false,
    result: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    delivery: ?types.SteeringDelivery = null,
};

pub fn feedbackResult(delivery: types.SteeringDelivery) Result {
    return .{
        .ok = delivery != .not_applied,
        .delivery = delivery,
        .result = switch (delivery) {
            .queued => "Feedback queued for the running child. Its result will arrive automatically.",
            .applied => "Feedback consumed at the child's safe boundary. This is not a task-completion result.",
            .not_applied => "Feedback was not applied before the child stopped.",
        },
        .error_code = if (delivery == .not_applied) "feedback_not_applied" else null,
    };
}

pub fn encodeResultAlloc(alloc: Allocator, result: Result) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{{\"ok\":{s},\"result\":", .{
        if (result.ok) "true" else "false",
    });
    try writeOptionalString(&out.writer, result.result);
    try out.writer.writeAll(",\"error_code\":");
    try writeOptionalString(
        &out.writer,
        if (result.error_code) |code| code[0..@min(code.len, max_error_code_bytes)] else null,
    );
    if (result.pending) try out.writer.writeAll(",\"pending\":true");
    if (result.delivery) |delivery| try out.writer.print(",\"delivery\":\"{s}\"", .{@tagName(delivery)});
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

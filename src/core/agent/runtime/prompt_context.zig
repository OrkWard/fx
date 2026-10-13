const std = @import("std");
const token_estimate = @import("../../shared/token_estimate.zig");
const types = @import("../../shared/types.zig");
const stream_provider = @import("../stream_provider.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

const textTokens = token_estimate.textTokens;

pub const RequestCost = struct {
    serialized_bytes: usize,
    /// Uncalibrated serialization estimate; non-image usage may replace it.
    text_tokens: usize,
    /// Null means no image parts. Otherwise visual cost needs applicable usage.
    image_identity: ?[32]u8 = null,
    estimated_input_tokens: usize,
};

pub const RequestTokenCalibration = struct {
    request: RequestCost,
    exact_input_tokens: usize,

    pub fn applies(self: RequestTokenCalibration, cost: RequestCost) bool {
        return self.request.serialized_bytes != 0 and self.exact_input_tokens != 0 and
            std.meta.eql(cost.image_identity, self.request.image_identity);
    }
};

const ImagePartData = struct {
    type: []const u8 = "",
    data: ?[]const u8 = null,
};

/// Responses `input_image` parts carry the URL as a string; chat-completions
/// `image_url` parts wrap it in an object.
const ImageUrl = struct {
    url: []const u8,

    pub fn jsonParse(alloc: Allocator, source: anytype, options: std.json.ParseOptions) !ImageUrl {
        if (try source.peekNextTokenType() == .string) {
            return .{ .url = try std.json.innerParse([]const u8, alloc, source, options) };
        }
        const Wrapped = struct { url: []const u8 };
        const wrapped = try std.json.innerParse(Wrapped, alloc, source, options);
        return .{ .url = wrapped.url };
    }
};

const ImagePart = struct {
    type: []const u8 = "",
    mediaType: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    data: ?ImagePartData = null,
    image_url: ?ImageUrl = null,
};

const MessageContent = struct {
    parts: []const ImagePart = &.{},

    pub fn jsonParse(alloc: Allocator, source: anytype, options: std.json.ParseOptions) !MessageContent {
        if (try source.peekNextTokenType() == .array_begin) {
            return .{ .parts = try std.json.innerParse([]const ImagePart, alloc, source, options) };
        }
        try source.skipValue();
        return .{};
    }
};

const CostMessage = struct {
    role: []const u8 = "",
    type: []const u8 = "",
    content: MessageContent = .{},
    output: MessageContent = .{},
};

const CostRequest = struct {
    prompt: ?[]const CostMessage = null,
    input: ?[]const CostMessage = null,
    messages: ?[]const CostMessage = null,
};

pub const MeasurementError = error{ OutOfMemory, InvalidRequestMeasurement };

/// Borrows the prepared body and request; releases parsing scratch before returning.
/// Image payloads are transport bytes, not text. Their initial token cost is unknown.
pub fn measureProviderRequest(alloc: Allocator, body: []const u8, request: stream_provider.RequestData) MeasurementError!RequestCost {
    const has_images = image_input: {
        if (request.verified_images) |images| if (images.len != 0) break :image_input true;
        for (request.messages) |message| {
            if (message.images.len != 0) break :image_input true;
            // Retained tool images serialize as follow-up user-message file
            // parts, so they never appear in message.images. Count them as
            // image input or their base64 payloads are priced as text.
            if (message.tool_result_memory) |memory| if (memory.tool_images.len != 0) break :image_input true;
        }
        break :image_input false;
    };
    if (!has_images) {
        const tokens = textTokens(body);
        return .{ .serialized_bytes = body.len, .text_tokens = tokens, .estimated_input_tokens = tokens };
    }

    // Typed parsing borrows unescaped payload strings. Value parsing copies them.
    const parsed = std.json.parseFromSlice(CostRequest, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRequestMeasurement,
    };
    defer parsed.deinit();
    const envelopes = @as(u8, @intFromBool(parsed.value.prompt != null)) +
        @intFromBool(parsed.value.input != null) +
        @intFromBool(parsed.value.messages != null);
    if (envelopes > 1) return error.InvalidRequestMeasurement;
    const messages = parsed.value.prompt orelse parsed.value.input orelse parsed.value.messages orelse {
        // Unrecognized envelope: degrade to the conservative text estimate
        // rather than fail the request over a shape this measurer does not know.
        const tokens = textTokens(body);
        return .{ .serialized_bytes = body.len, .text_tokens = tokens, .estimated_input_tokens = tokens };
    };
    var estimator = token_estimate.StreamingEstimator{};
    var identity = std.crypto.hash.sha2.Sha256.init(.{});
    var cursor: usize = 0;
    var found_image = false;
    for (messages) |message| {
        // Retained tool images never land in user-message content on
        // input-style bodies: the responses protocol writes them as
        // input_image parts inside function_call_output items, which carry no
        // role. Scan both carriers.
        const parts = if (std.mem.eql(u8, message.role, "user"))
            message.content.parts
        else if (parsed.value.input != null and std.mem.eql(u8, message.type, "function_call_output"))
            message.output.parts
        else
            continue;
        for (parts) |part| {
            const payload = if (parsed.value.input != null and std.mem.eql(u8, part.type, "input_image"))
                (part.image_url orelse return error.InvalidRequestMeasurement).url
            else if (parsed.value.messages != null and std.mem.eql(u8, part.type, "image_url"))
                (part.image_url orelse return error.InvalidRequestMeasurement).url
            else if (parsed.value.prompt != null and std.mem.eql(u8, part.type, "file") and
                std.mem.startsWith(u8, part.mediaType orelse "", "image/"))
            payload: {
                const data = part.data orelse return error.InvalidRequestMeasurement;
                if (!std.mem.eql(u8, data.type, "data")) return error.InvalidRequestMeasurement;
                break :payload data.data orelse return error.InvalidRequestMeasurement;
            } else continue;
            const address = @intFromPtr(payload.ptr);
            if (address < @intFromPtr(body.ptr)) return error.InvalidRequestMeasurement;
            const offset = address - @intFromPtr(body.ptr);
            if (offset < cursor or offset > body.len or payload.len > body.len - offset) return error.InvalidRequestMeasurement;
            estimator.consume(body[cursor..offset]);
            cursor = offset + payload.len;
            for ([_][]const u8{ part.type, part.mediaType orelse "", part.detail orelse "", payload }) |value| {
                identity.update(std.mem.asBytes(&value.len));
                identity.update(value);
            }
            found_image = true;
        }
    }
    estimator.consume(body[cursor..]);
    const tokens: usize = @intCast(@min(estimator.estimate(), std.math.maxInt(usize)));
    return .{
        .serialized_bytes = body.len,
        .text_tokens = tokens,
        .image_identity = if (found_image) identity.finalResult() else null,
        .estimated_input_tokens = tokens,
    };
}

pub fn calibrateProviderRequest(
    cost: RequestCost,
    calibration: RequestTokenCalibration,
) RequestCost {
    if (!calibration.applies(cost)) return cost;
    const calibrated_tokens = if (cost.image_identity != null)
        if (cost.text_tokens >= calibration.request.text_tokens)
            calibration.exact_input_tokens +| (cost.text_tokens - calibration.request.text_tokens)
        else
            calibration.exact_input_tokens -| (calibration.request.text_tokens - cost.text_tokens)
    else
        multiplyDivideCeilSaturating(cost.serialized_bytes, calibration.exact_input_tokens, calibration.request.serialized_bytes);
    var result = cost;
    result.estimated_input_tokens = if (cost.image_identity != null)
        @max(cost.text_tokens, calibrated_tokens)
    else
        @max(1, calibrated_tokens);
    return result;
}

fn multiplyDivideCeilSaturating(
    value: usize,
    numerator: usize,
    denominator: usize,
) usize {
    std.debug.assert(denominator != 0);
    const whole = std.math.mul(
        usize,
        value / denominator,
        numerator,
    ) catch return std.math.maxInt(usize);
    const remainder_product = std.math.mul(
        usize,
        value % denominator,
        numerator,
    ) catch return std.math.maxInt(usize);
    const partial = remainder_product / denominator +
        @intFromBool(remainder_product % denominator != 0);
    return std.math.add(usize, whole, partial) catch std.math.maxInt(usize);
}

pub const ProviderPrompt = struct {
    instructions: std.ArrayList(ChatMessage),
    messages: std.ArrayList(ChatMessage),

    pub fn deinit(self: *ProviderPrompt, alloc: Allocator) void {
        self.instructions.deinit(alloc);
        self.messages.deinit(alloc);
        self.* = undefined;
    }
};

pub fn buildProviderPrompt(
    alloc: Allocator,
    stable_prefix: []const ChatMessage,
    ephemeral_overlay: []const ChatMessage,
    durable_history: []const ChatMessage,
    current_user_message: ChatMessage,
    within_turn_suffix: []const ChatMessage,
) !ProviderPrompt {
    var instructions: std.ArrayList(ChatMessage) = .empty;
    errdefer instructions.deinit(alloc);
    var messages: std.ArrayList(ChatMessage) = .empty;
    errdefer messages.deinit(alloc);

    try instructions.appendSlice(alloc, stable_prefix);
    try instructions.appendSlice(alloc, ephemeral_overlay);
    try messages.appendSlice(alloc, durable_history);
    try messages.append(alloc, current_user_message);
    try messages.appendSlice(alloc, within_turn_suffix);
    return .{
        .instructions = instructions,
        .messages = messages,
    };
}

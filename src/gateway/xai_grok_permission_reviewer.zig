const std = @import("std");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const xai_grok = @import("xai_grok.zig");
const grok_session = @import("../core/auth/grok_session.zig");
const responses_reviewer = @import("responses_permission_reviewer.zig");

const Allocator = std.mem.Allocator;
const reviewer_model = "grok-4.5";

pub const provider = permission_auto_classifier.Provider{
    .review_fn = reviewGrok,
};

fn reviewGrok(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) anyerror!permission_auto_classifier.ParseOutcome {
    return responses_reviewer.review(alloc, input, request, .{
        .source = .grok_subscription,
        .model = reviewer_model,
        .require_account = true,
        .validate_fn = validateCredential,
        .build_fn = xai_grok.buildRequest,
        .send_fn = sendPrepared,
    });
}

fn validateCredential(
    _: Allocator,
    input: permission_auto_classifier.ProviderInput,
) !void {
    if (!grok_session.validAccountId(input.account_id orelse return error.InvalidAccount)) {
        return error.InvalidAccount;
    }
}

fn sendPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) anyerror!stream_provider.Result {
    return xai_grok.streamPrepared(alloc, request, payload);
}

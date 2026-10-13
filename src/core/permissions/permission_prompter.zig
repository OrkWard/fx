const std = @import("std");
const diff_mod = @import("../output/diff.zig");
const permission_request = @import("permission_request.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// Transport-neutral permission prompt capability. Policy evaluation and
/// grant construction stay in tool admission; transports present the request,
/// return the selected response, and may retain grants in session-owned state.
pub const Prompter = struct {
    context: *anyopaque,
    request_fn: *const fn (
        *anyopaque,
        Allocator,
        permission_request.PermissionRequest,
        types.ToolCall,
        ?*const diff_mod.FileReview,
        ?[]const types.PermissionGrant,
    ) anyerror!permission_request.OwnedPermissionResponse,
    retain_grant_fn: ?*const fn (*anyopaque, []const u8, []const u8) anyerror!void = null,

    pub fn request(
        self: Prompter,
        alloc: Allocator,
        request_value: permission_request.PermissionRequest,
        call: types.ToolCall,
        review: ?*const diff_mod.FileReview,
        grant_offer: ?[]const types.PermissionGrant,
    ) anyerror!permission_request.OwnedPermissionResponse {
        return self.request_fn(
            self.context,
            alloc,
            request_value,
            call,
            review,
            grant_offer,
        );
    }
};

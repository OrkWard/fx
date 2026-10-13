const std = @import("std");
const model_contract = @import("model_contract.zig");

const Allocator = std.mem.Allocator;

pub const Status = enum {
    success,
    failure,
};

/// Owned provider output. The caller frees `body` with the allocator passed to
/// `Provider.execute`.
pub const Result = struct {
    status: Status,
    body: []u8,
};

pub const ExecuteError = Allocator.Error || error{Cancelled};

pub const ExecuteFn = *const fn (
    ?*anyopaque,
    Allocator,
    *model_contract.Request,
    []const u8,
) ExecuteError!Result;

/// Host-facing executor for one validated registered subagent request. The
/// caller retains request ownership; the provider may inspect it during the
/// synchronous call but must not retain the pointer.
pub const Provider = struct {
    context: ?*anyopaque = null,
    execute_fn: ExecuteFn,

    pub fn execute(
        self: Provider,
        alloc: Allocator,
        request: *model_contract.Request,
        invocation_id: []const u8,
    ) ExecuteError!Result {
        return self.execute_fn(
            self.context,
            alloc,
            request,
            invocation_id,
        );
    }
};

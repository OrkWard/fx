const std = @import("std");
const process_identity = @import("process_identity.zig");

const Allocator = std.mem.Allocator;

pub const ProviderError = Allocator.Error || error{
    Unsupported,
    ProcessIdentityIndeterminate,
    ProcessIdentityMismatch,
    ProcessIdentityUnavailable,
    ProcessIdentityUnsupported,
    ProcessNotFound,
    PermissionDenied,
    Unexpected,
    InvalidPid,
};

pub const Provider = struct {
    context: ?*anyopaque = null,
    capture_token_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
    ) ProviderError!process_identity.ProcessInstanceToken,
    match_token_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
        process_identity.ProcessInstanceToken,
    ) process_identity.TokenMatch,
    signal_process_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
        process_identity.ProcessInstanceToken,
    ) ProviderError!void,

    pub fn captureToken(
        self: Provider,
        alloc: Allocator,
        pid: []const u8,
    ) ProviderError!process_identity.ProcessInstanceToken {
        return self.capture_token_fn(self.context, alloc, pid);
    }

    pub fn matchToken(
        self: Provider,
        alloc: Allocator,
        pid: []const u8,
        expected: process_identity.ProcessInstanceToken,
    ) process_identity.TokenMatch {
        return self.match_token_fn(self.context, alloc, pid, expected);
    }

    pub fn signalProcess(
        self: Provider,
        alloc: Allocator,
        pid: []const u8,
        expected: process_identity.ProcessInstanceToken,
    ) ProviderError!void {
        return self.signal_process_fn(self.context, alloc, pid, expected);
    }
};

fn unsupportedCaptureToken(
    _: ?*anyopaque,
    _: Allocator,
    _: []const u8,
) ProviderError!process_identity.ProcessInstanceToken {
    return error.Unsupported;
}

fn unavailableMatchToken(
    _: ?*anyopaque,
    _: Allocator,
    _: []const u8,
    _: process_identity.ProcessInstanceToken,
) process_identity.TokenMatch {
    return .unavailable;
}

fn unsupportedSignalProcess(
    _: ?*anyopaque,
    _: Allocator,
    _: []const u8,
    _: process_identity.ProcessInstanceToken,
) ProviderError!void {
    return error.Unsupported;
}

pub const unavailable_provider = Provider{
    .capture_token_fn = unsupportedCaptureToken,
    .match_token_fn = unavailableMatchToken,
    .signal_process_fn = unsupportedSignalProcess,
};

const std = @import("std");
const builtin = @import("builtin");

pub const TerminalSupport = enum {
    unsupported,
    supported,

    pub fn isSupported(self: TerminalSupport) bool {
        return self == .supported;
    }
};

pub const Capabilities = struct {
    process_control: bool,
    url_open: bool,
    native_url_open: bool,
    terminal: TerminalSupport,
};

pub const UrlOpenError = std.mem.Allocator.Error;

pub const UrlOpener = struct {
    context: ?*anyopaque = null,
    open_fn: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        []const u8,
    ) UrlOpenError!bool,

    /// Borrows `url` for this call. The caller retains ownership. Returns
    /// `false` when the host cannot launch the URL so callers can keep a
    /// manual fallback available.
    pub fn open(
        self: UrlOpener,
        alloc: std.mem.Allocator,
        url: []const u8,
    ) UrlOpenError!bool {
        return self.open_fn(self.context, alloc, url);
    }
};

pub const unavailable_url_opener: UrlOpener = .{
    .open_fn = unavailableUrlOpen,
};

fn unavailableUrlOpen(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
) UrlOpenError!bool {
    return false;
}

pub const TerminalTitle = struct {
    context: ?*anyopaque = null,
    set_fn: *const fn (?*anyopaque, []const u8) void,
    clear_fn: *const fn (?*anyopaque) void,

    /// Borrows `label` for this call. Callers resolve what the label says; the
    /// provider only renders it. Terminal write failures are intentionally
    /// non-fatal because the title is presentation metadata.
    pub fn set(self: TerminalTitle, label: []const u8) void {
        self.set_fn(self.context, label);
    }

    pub fn clear(self: TerminalTitle) void {
        self.clear_fn(self.context);
    }
};

pub const unavailable_terminal_title: TerminalTitle = .{
    .set_fn = ignoreTerminalTitleSet,
    .clear_fn = ignoreTerminalTitleClear,
};

fn ignoreTerminalTitleSet(_: ?*anyopaque, _: []const u8) void {}

fn ignoreTerminalTitleClear(_: ?*anyopaque) void {}

pub const SecretStorePresence = enum {
    present,
    missing,
    unavailable,
};

pub const ClipboardError = error{CopyFailed};

fn copy_file_unavailable(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) ClipboardError!bool {
    return false;
}

pub const Clipboard = struct {
    context: ?*anyopaque = null,
    copy_fn: *const fn (
        ?*anyopaque,
        []const u8,
    ) ClipboardError!bool,
    copy_file_fn: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        []const u8,
    ) ClipboardError!bool = copy_file_unavailable,

    /// Borrows `text` for this call. The caller retains ownership. Returns
    /// `false` when the host has no clipboard implementation.
    pub fn copy(
        self: Clipboard,
        text: []const u8,
    ) ClipboardError!bool {
        return self.copy_fn(self.context, text);
    }

    /// Borrows `path` for this call. The caller retains ownership. Returns
    /// `false` when the host cannot publish file references to its clipboard.
    pub fn copy_file(
        self: Clipboard,
        alloc: std.mem.Allocator,
        path: []const u8,
    ) ClipboardError!bool {
        return self.copy_file_fn(self.context, alloc, path);
    }
};

pub fn current() Capabilities {
    return nativeForOs(builtin.target.os.tag);
}

pub fn terminalSupportForOs(os_tag: std.Target.Os.Tag) TerminalSupport {
    return if (os_tag == .macos or os_tag == .linux)
        .supported
    else
        .unsupported;
}

pub fn nativeForOs(os_tag: std.Target.Os.Tag) Capabilities {
    return .{
        .process_control = os_tag != .windows and os_tag != .wasi,
        .url_open = os_tag == .macos or os_tag == .linux,
        .native_url_open = os_tag == .macos,
        .terminal = terminalSupportForOs(os_tag),
    };
}

/// Returns an owned description of the current operating system. The caller
/// owns the returned slice and must free it with `alloc`.
pub fn operatingSystemText(alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    if (comptime builtin.target.os.tag == .windows) {
        return alloc.dupe(u8, @tagName(builtin.target.os.tag));
    }

    const uts = std.posix.uname();
    const sysname = std.mem.sliceTo(&uts.sysname, 0);
    const release = std.mem.sliceTo(&uts.release, 0);
    if (release.len == 0) return alloc.dupe(u8, sysname);
    return alloc.print("{s} {s}", .{ sysname, release });
}

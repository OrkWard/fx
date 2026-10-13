const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts.zig");
const command_environment = @import("../execution/command_environment.zig");

const Allocator = std.mem.Allocator;

pub const ResolveError = error{
    MissingLoginShell,
    RelativeShellPath,
    UnsupportedShell,
};

pub const Profile = command_environment.Profile;
pub const Environment = command_environment.Environment;

pub const ShellKind = enum { bash, zsh };

pub fn shellKind(path: []const u8) ?ShellKind {
    const basename = std.Io.Dir.path.basename(path);
    if (std.mem.eql(u8, basename, "bash")) return .bash;
    if (std.mem.eql(u8, basename, "zsh")) return .zsh;
    return null;
}

fn fallbackLoginShell() []const u8 {
    return if (builtin.target.os.tag == .macos) "/bin/zsh" else "/bin/bash";
}

fn supportedLoginShell(configured_login_shell: ?[]const u8) ResolveError![]const u8 {
    const path = configured_login_shell orelse return error.MissingLoginShell;
    if (!std.Io.Dir.path.isAbsolute(path)) return error.RelativeShellPath;
    if (shellKind(path) != null) return path;
    return fallbackLoginShell();
}

pub const Invocation = struct {
    path: []const u8,
    values: [8][]const u8 = @splat(""),
    len: usize = 0,

    pub fn argv(self: *const Invocation) []const []const u8 {
        return self.values[0..self.len];
    }

    fn append(self: *Invocation, value: []const u8) void {
        self.values[self.len] = value;
        self.len += 1;
    }

    pub fn setCommand(self: *Invocation, command: []const u8) void {
        self.append("-c");
        self.append(command);
    }
};

pub fn resolve(
    configured_login_shell: ?[]const u8,
    shell: contracts.ShellSpec,
) ResolveError!Invocation {
    const Selection = struct {
        path: []const u8,
        clean_start: bool,
    };
    const selection: Selection = switch (shell) {
        .user_login => .{
            .path = try supportedLoginShell(configured_login_shell),
            .clean_start = false,
        },
        .executable => |value| .{
            .path = value.path,
            .clean_start = value.clean_start,
        },
    };
    if (!std.Io.Dir.path.isAbsolute(selection.path)) {
        return error.RelativeShellPath;
    }

    const kind = shellKind(selection.path) orelse return error.UnsupportedShell;

    var result = Invocation{ .path = selection.path };
    result.append(selection.path);
    switch (kind) {
        .bash => {
            if (selection.clean_start) {
                result.append("--noprofile");
                result.append("--norc");
            } else {
                result.append("--login");
            }
            result.append("-i");
        },
        .zsh => {
            if (selection.clean_start) {
                result.append("-f");
            } else {
                result.append("-l");
            }
            result.append("-i");
        },
    }
    return result;
}

pub fn configuredLoginShellInto(buffer: []u8) ?[]const u8 {
    if (comptime !builtin.link_libc or builtin.target.os.tag == .windows) {
        return null;
    }
    var entry: std.c.passwd = undefined;
    var scratch: [4096]u8 = undefined;
    var found: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(
        std.c.getuid(),
        &entry,
        &scratch,
        scratch.len,
        &found,
    ) != 0) return null;
    const record = found orelse return null;
    const shell_ptr = record.shell orelse return null;
    const shell = std.mem.span(shell_ptr);
    if (shell.len == 0 or shell.len > buffer.len) return null;
    @memcpy(buffer[0..shell.len], shell);
    return buffer[0..shell.len];
}

pub fn environment(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    profile: ?Profile,
) (ResolveError || Allocator.Error)!Environment {
    const selected = profile orelse .user;
    const path = try supportedLoginShell(configured_login_shell);
    _ = try resolve(null, switch (selected) {
        .clean => .{ .executable = .{ .path = path, .clean_start = true } },
        .user => .{ .executable = .{ .path = path } },
    });
    return switch (selected) {
        .clean => .{ .clean = try alloc.dupe(u8, path) },
        .user => .{ .user = try alloc.dupe(u8, path) },
    };
}

pub fn environmentForShellSpec(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    shell: contracts.ShellSpec,
) (ResolveError || Allocator.Error)!Environment {
    const invocation = try resolve(configured_login_shell, shell);
    return switch (shell) {
        .user_login => .{ .user = try alloc.dupe(u8, invocation.path) },
        .executable => |value| if (value.clean_start)
            .{ .clean = try alloc.dupe(u8, invocation.path) }
        else
            .{ .user = try alloc.dupe(u8, invocation.path) },
    };
}

pub fn profileShell(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    profile: Profile,
) (ResolveError || Allocator.Error)!contracts.ShellSpec {
    return switch (profile) {
        .clean => blk: {
            const path = try supportedLoginShell(configured_login_shell);
            _ = try resolve(null, .{ .executable = .{ .path = path, .clean_start = true } });
            break :blk .{ .executable = .{
                .path = try alloc.dupe(u8, path),
                .clean_start = true,
            } };
        },
        .user => blk: {
            const configured = configured_login_shell orelse
                break :blk .user_login;
            const path = try supportedLoginShell(configured);
            if (std.mem.eql(u8, path, configured)) break :blk .user_login;
            break :blk .{ .executable = .{
                .path = try alloc.dupe(u8, path),
            } };
        },
    };
}

const captured_zsh_user_prelude = "\\builtin trap - TERM; ";

pub fn capturedInvocation(
    alloc: Allocator,
    environment_value: Environment,
    command: []const u8,
) (ResolveError || Allocator.Error)!Invocation {
    switch (environment_value) {
        .legacy, .workspace_clean => return error.UnsupportedShell,
        .clean => |path| {
            var invocation = try resolve(null, .{ .executable = .{
                .path = path,
                .clean_start = true,
            } });
            removeInteractiveFlag(&invocation);
            invocation.setCommand(command);
            return invocation;
        },
        .user => |path| {
            var invocation = try resolve(path, .user_login);
            if (std.mem.eql(u8, std.Io.Dir.path.basename(path), "bash")) {
                removeInteractiveFlag(&invocation);
                invocation.append("-O");
                invocation.append("expand_aliases");
            }
            const effective_command = if (shellKind(path) == .zsh)
                try std.mem.concat(alloc, u8, &.{ captured_zsh_user_prelude, command })
            else
                command;
            invocation.setCommand(effective_command);
            return invocation;
        },
    }
}

/// Stderr marker, followed by a nonce, that a snapshot bootstrap writes with
/// exit status 125 when the replay stopped before the command could start.
pub const snapshot_replay_failure_prefix = "fx-shell-snapshot-replay-failed:";

/// Builds the clean-shell argv for a snapshot run. The shell sources the
/// replay and the command from stdin, so no snapshot text or command appears
/// in argv. `failure_marker` reaches stderr, with exit status 125, only when
/// the replay stopped before the command started.
pub fn snapshotInvocation(
    alloc: Allocator,
    shell_path: []const u8,
    failure_marker: []const u8,
) (ResolveError || Allocator.Error)!Invocation {
    const kind = shellKind(shell_path) orelse return error.UnsupportedShell;
    var invocation = Invocation{ .path = shell_path };
    invocation.append(shell_path);
    switch (kind) {
        .zsh => invocation.append("-f"),
        .bash => {
            invocation.append("--noprofile");
            invocation.append("--norc");
            invocation.append("-O");
            invocation.append("expand_aliases");
        },
    }
    var bootstrap: std.ArrayList(u8) = .empty;
    errdefer bootstrap.deinit(alloc);
    try bootstrap.appendSlice(
        alloc,
        "\\builtin source /dev/fd/0; __fx_snapshot_status=$?; " ++
            "if [[ -z ${__fx_snapshot_restored-} ]]; then \\builtin printf '%s' ",
    );
    try appendShellWord(&bootstrap, alloc, failure_marker);
    // Re-raise the common termination signals so the supervisor reports a
    // signal, as it does when the shell runs the command directly.
    try bootstrap.appendSlice(
        alloc,
        " >&2; \\builtin exit 125; fi; " ++
            "case $__fx_snapshot_status in 129|130|137|143) " ++
            "\\builtin kill -$((__fx_snapshot_status - 128)) $$;; esac; " ++
            "\\builtin exit $__fx_snapshot_status",
    );
    invocation.setCommand(try bootstrap.toOwnedSlice(alloc));
    return invocation;
}

/// Builds the stdin script for a snapshot run: the replay, the restored flag
/// the bootstrap checks, and the command. The command is single-quoted so it
/// is parsed only when `eval` runs, after the replayed aliases exist, and it
/// runs with stdin from /dev/null so it cannot read the rest of the script.
pub fn snapshotScript(
    alloc: Allocator,
    replay: []const u8,
    command: []const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    try output.appendSlice(alloc, replay);
    if (replay.len != 0 and replay[replay.len - 1] != '\n') try output.append(alloc, '\n');
    try output.appendSlice(alloc, "__fx_snapshot_restored=1\n\\builtin eval -- ");
    try appendShellWord(&output, alloc, command);
    try output.appendSlice(alloc, " </dev/null\n");
    return output.toOwnedSlice(alloc);
}

/// Payload section markers written by `snapshotCaptureScript`. Each marker is
/// followed by `:` and the capture nonce.
pub const snapshot_marker_prefix = "FXSNAP:";

const zsh_capture_script =
    \\{
    \\\builtin zmodload zsh/parameter 2>/dev/null
    \\\builtin printf 'FXSNAP:@NONCE@:ENV\0'
    \\/usr/bin/env -0
    \\\builtin printf 'FXSNAP:@NONCE@:NAMES\0'
    \\\builtin printf '%s\0' ${(k)aliases} ${(k)galiases} ${(k)saliases} ${(k)functions}
    \\\builtin printf 'FXSNAP:@NONCE@:REPLAY\0'
    \\\builtin typeset -p fpath
    \\for __fx_snapshot_name in ${(ko)functions}; do
    \\  case $__fx_snapshot_name in (_*|prompt_*|__fx_snapshot_*) continue;; esac
    \\  \builtin functions -- $__fx_snapshot_name
    \\done
    \\\builtin alias -L
    \\\builtin alias -sL
    \\for __fx_snapshot_name in extendedglob globdots nullglob nomatch kshglob shglob globstarshort bareglobqual caseglob numericglobsort rcexpandparam shwordsplit ksharrays magicequalsubst equals braceccl rcquotes shortloops cshnullglob globsubst; do
    \\  if [[ -o $__fx_snapshot_name ]]; then
    \\    \builtin print -r -- "\\builtin setopt $__fx_snapshot_name"
    \\  else
    \\    \builtin print -r -- "\\builtin unsetopt $__fx_snapshot_name"
    \\  fi
    \\done
    \\\builtin printf '\0FXSNAP:@NONCE@:END\0'
    \\} 2>/dev/null
;

const bash_capture_script =
    \\{
    \\\builtin printf 'FXSNAP:@NONCE@:ENV\0'
    \\/usr/bin/env -0
    \\\builtin printf 'FXSNAP:@NONCE@:NAMES\0'
    \\\builtin printf '%s\0' $(\builtin compgen -a) $(\builtin compgen -A function)
    \\\builtin printf 'FXSNAP:@NONCE@:REPLAY\0'
    \\for __fx_snapshot_name in $(\builtin compgen -A function); do
    \\  case $__fx_snapshot_name in _*|__fx_snapshot_*) continue;; esac
    \\  \builtin declare -f -- "$__fx_snapshot_name"
    \\done
    \\\builtin alias -p
    \\for __fx_snapshot_name in extglob nullglob dotglob globstar nocaseglob failglob nocasematch globasciiranges; do
    \\  \builtin shopt -p "$__fx_snapshot_name" 2>/dev/null
    \\done
    \\\builtin printf '\0FXSNAP:@NONCE@:END\0'
    \\} 2>/dev/null
;

/// Builds the script a login shell runs once to capture its state as a
/// NUL-delimited payload: exported environment, alias and function names, and
/// a replay of functions, aliases, and selected options. Every section marker
/// carries `nonce`, so output printed by the user's startup files cannot be
/// mistaken for the payload. `nonce` must be ASCII hex.
pub fn snapshotCaptureScript(
    alloc: Allocator,
    kind: ShellKind,
    nonce: []const u8,
) Allocator.Error![]u8 {
    for (nonce) |byte| std.debug.assert(std.ascii.isHex(byte));
    const template = switch (kind) {
        .zsh => zsh_capture_script,
        .bash => bash_capture_script,
    };
    return std.mem.replaceOwned(u8, alloc, template, "@NONCE@", nonce);
}

fn removeInteractiveFlag(invocation: *Invocation) void {
    std.debug.assert(invocation.len > 0);
    std.debug.assert(std.mem.eql(u8, invocation.values[invocation.len - 1], "-i"));
    invocation.len -= 1;
}

pub fn buildBootstrap(
    alloc: Allocator,
    executable: []const u8,
    control_path: []const u8,
    nonce: []const u8,
    command_path: ?[]const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);

    try output.appendSlice(alloc, "set +x; export AI_AGENT=fx; ");
    if (command_path) |path| {
        try output.appendSlice(alloc, "fx_terminal_command=$(< ");
        try appendShellWord(&output, alloc, path);
        try output.appendSlice(alloc, ") || exit 125; ");
    }
    try appendMarker(&output, alloc, executable, control_path, nonce, "shell-ready");
    if (command_path) |_| {
        try output.appendSlice(alloc, " || exit 125; ");
        try appendMarker(
            &output,
            alloc,
            executable,
            control_path,
            nonce,
            "command-started",
        );
        try output.appendSlice(
            alloc,
            " || exit 125; builtin eval -- \"$fx_terminal_command\"; " ++
                "fx_terminal_status=$?; exit \"$fx_terminal_status\"\n",
        );
    } else {
        try output.appendSlice(alloc, " || exit 125\n");
    }
    return output.toOwnedSlice(alloc);
}

pub fn buildSourceCommand(
    alloc: Allocator,
    bootstrap_path: []const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    try output.appendSlice(alloc, ". ");
    try appendShellWord(&output, alloc, bootstrap_path);
    try output.append(alloc, '\n');
    return output.toOwnedSlice(alloc);
}

fn appendMarker(
    output: *std.ArrayList(u8),
    alloc: Allocator,
    executable: []const u8,
    control_path: []const u8,
    nonce: []const u8,
    event: []const u8,
) Allocator.Error!void {
    try appendShellWord(output, alloc, executable);
    inline for (.{
        "--fx-internal-terminal-control",
        control_path,
        nonce,
        event,
    }) |word| {
        try output.append(alloc, ' ');
        try appendShellWord(output, alloc, word);
    }
}

fn appendShellWord(
    output: *std.ArrayList(u8),
    alloc: Allocator,
    word: []const u8,
) Allocator.Error!void {
    try output.append(alloc, '\'');
    for (word) |byte| {
        if (byte == '\'') {
            try output.appendSlice(alloc, "'\"'\"'");
        } else {
            try output.append(alloc, byte);
        }
    }
    try output.append(alloc, '\'');
}

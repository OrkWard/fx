const std = @import("std");
const command_specs = @import("command_specs.zig");

const SlashKind = command_specs.SlashKind;
const SlashRegistry = command_specs.SlashRegistry;

pub const ParsedCommand = union(enum) {
    quit,
    clear_screen,
    new_session,
    reset_session,
    resume_session,
    rename_session: []const u8,
    help,
    login,
    logout: []const u8,
    provider,
    status,
    image: []const u8,
    images: []const u8,
    model: []const u8,
    permissions: []const u8,
    allowlist: []const u8,
    stats,
    usage,
    undo,
    skills: []const u8,
    copy,
    feedback,
    trace,
    compact,
    settings: []const u8,
    alias: []const u8,
    paste,
    fast,
    ultrafast: []const u8,
    statusline: []const u8,
    notifications: []const u8,
    workspace: []const u8,
    shell: []const u8,
    version,
    unknown,
};

pub const CommandHandlers = struct {
    ctx: *anyopaque,
    quit: *const fn (ctx: *anyopaque) anyerror!void,
    clear_screen: *const fn (ctx: *anyopaque) anyerror!void,
    new_session: *const fn (ctx: *anyopaque) anyerror!void,
    reset_session: *const fn (ctx: *anyopaque) anyerror!void,
    resume_session: *const fn (ctx: *anyopaque) anyerror!void,
    show_help: *const fn (ctx: *anyopaque) anyerror!void,
    login: *const fn (ctx: *anyopaque) anyerror!void,
    logout: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    provider: *const fn (ctx: *anyopaque) anyerror!void,
    show_status: *const fn (ctx: *anyopaque) anyerror!void,
    attach_image: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    manage_images: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_model: *const fn (ctx: *anyopaque, query: []const u8) anyerror!void,
    handle_permissions: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_allowlist: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    show_stats: *const fn (ctx: *anyopaque) anyerror!void,
    show_usage: *const fn (ctx: *anyopaque) anyerror!void,
    undo_last: *const fn (ctx: *anyopaque) anyerror!void,
    handle_skills: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    copy_last: *const fn (ctx: *anyopaque) anyerror!void,
    submit_feedback: *const fn (ctx: *anyopaque) anyerror!void,
    create_trace: *const fn (ctx: *anyopaque) anyerror!void,
    compact_history: *const fn (ctx: *anyopaque) anyerror!void,
    handle_settings: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_alias: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    paste_clipboard: *const fn (ctx: *anyopaque) anyerror!void,
    toggle_fast: *const fn (ctx: *anyopaque) anyerror!void,
    handle_ultrafast: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_statusline: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    rename_session: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_notifications: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_workspace: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_shell: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    show_version: *const fn (ctx: *anyopaque) anyerror!void,
    unknown: *const fn (ctx: *anyopaque, cmd: []const u8) anyerror!void,
};

fn command_payload(cmd: []const u8, prefix: []const u8) []const u8 {
    return std.mem.trim(u8, cmd[prefix.len..], " \t");
}

fn parsedCommand(kind: SlashKind, payload: []const u8) ParsedCommand {
    return switch (kind) {
        .quit => .quit,
        .clear_screen => .clear_screen,
        .new_session => .new_session,
        .reset_session => .reset_session,
        .resume_session => .resume_session,
        .rename_session => .{ .rename_session = payload },
        .help => .help,
        .login => .login,
        .logout => .{ .logout = payload },
        .provider => .provider,
        .status => .status,
        .images => .{ .images = payload },
        .image => .{ .image = payload },
        .model => .{ .model = payload },
        .permissions => .{ .permissions = payload },
        .allowlist => .{ .allowlist = payload },
        .stats => .stats,
        .usage => .usage,
        .undo => .undo,
        .skills => .{ .skills = payload },
        .copy => .copy,
        .feedback => .feedback,
        .trace => .trace,
        .compact => .compact,
        .settings => .{ .settings = payload },
        .alias => .{ .alias = payload },
        .paste => .paste,
        .fast => .fast,
        .ultrafast => .{ .ultrafast = payload },
        .statusline => .{ .statusline = payload },
        .notifications => .{ .notifications = payload },
        .workspace => .{ .workspace = payload },
        .shell => .{ .shell = payload },
        .version => .version,
    };
}

pub fn parse(registry: SlashRegistry, cmd: []const u8) ParsedCommand {
    for (registry.commands) |spec| {
        if (spec.accepts_payload) {
            if (command_specs.matchedSlashPrefix(registry, cmd, spec.kind)) |prefix| {
                return parsedCommand(spec.kind, command_payload(cmd, prefix));
            }
        } else if (command_specs.matchesSlashExact(registry, cmd, spec.kind)) {
            return parsedCommand(spec.kind, "");
        }
    }
    return .unknown;
}

pub fn route(registry: SlashRegistry, handlers: *const CommandHandlers, cmd: []const u8) !void {
    switch (parse(registry, cmd)) {
        .quit => try handlers.quit(handlers.ctx),
        .clear_screen => try handlers.clear_screen(handlers.ctx),
        .new_session => try handlers.new_session(handlers.ctx),
        .reset_session => try handlers.reset_session(handlers.ctx),
        .resume_session => try handlers.resume_session(handlers.ctx),
        .rename_session => |rest| try handlers.rename_session(handlers.ctx, rest),
        .help => try handlers.show_help(handlers.ctx),
        .login => try handlers.login(handlers.ctx),
        .logout => |rest| try handlers.logout(handlers.ctx, rest),
        .provider => try handlers.provider(handlers.ctx),
        .status => try handlers.show_status(handlers.ctx),
        .image => |path| try handlers.attach_image(handlers.ctx, path),
        .images => |rest| try handlers.manage_images(handlers.ctx, rest),
        .model => |query| try handlers.handle_model(handlers.ctx, query),
        .permissions => |rest| try handlers.handle_permissions(handlers.ctx, rest),
        .allowlist => |rest| try handlers.handle_allowlist(handlers.ctx, rest),
        .stats => try handlers.show_stats(handlers.ctx),
        .usage => try handlers.show_usage(handlers.ctx),
        .undo => try handlers.undo_last(handlers.ctx),
        .skills => |rest| try handlers.handle_skills(handlers.ctx, rest),
        .copy => try handlers.copy_last(handlers.ctx),
        .feedback => try handlers.submit_feedback(handlers.ctx),
        .trace => try handlers.create_trace(handlers.ctx),
        .compact => try handlers.compact_history(handlers.ctx),
        .settings => |rest| try handlers.handle_settings(handlers.ctx, rest),
        .alias => |rest| try handlers.handle_alias(handlers.ctx, rest),
        .paste => try handlers.paste_clipboard(handlers.ctx),
        .fast => try handlers.toggle_fast(handlers.ctx),
        .ultrafast => |rest| try handlers.handle_ultrafast(handlers.ctx, rest),
        .statusline => |rest| try handlers.handle_statusline(handlers.ctx, rest),
        .notifications => |rest| try handlers.handle_notifications(handlers.ctx, rest),
        .workspace => |rest| try handlers.handle_workspace(handlers.ctx, rest),
        .shell => |rest| try handlers.handle_shell(handlers.ctx, rest),
        .version => try handlers.show_version(handlers.ctx),
        .unknown => try handlers.unknown(handlers.ctx, cmd),
    }
}

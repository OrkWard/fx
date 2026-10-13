const std = @import("std");
const update_target = @import("update_target.zig");

pub const Kind = enum {
    notes,
    changes,
};

pub const Destination = struct {
    kind: Kind,
    channel: update_target.Channel,
    version: []const u8,
    previous_revision: ?[]const u8 = null,
    revision: ?[]const u8 = null,

    pub fn writeUrl(self: Destination, writer: *std.Io.Writer) !void {
        switch (self.channel) {
            .stable => try writer.print(
                "https://fx.sh/changelog#v{s}",
                .{update_target.normalizeVersion(self.version)},
            ),
            .dev => {
                const revision = self.revision orelse return error.InvalidRevision;
                if (!update_target.isValidRevision(revision)) return error.InvalidRevision;
                if (self.previous_revision) |previous| {
                    if (!update_target.isValidRevision(previous)) return error.InvalidRevision;
                    if (!update_target.revisionsEqual(previous, revision)) {
                        try writer.print(
                            "https://github.com/vercel-labs/fx/compare/{s}...{s}",
                            .{ previous, revision },
                        );
                        return;
                    }
                }
                try writer.print(
                    "https://github.com/vercel-labs/fx/commit/{s}",
                    .{revision},
                );
            },
        }
    }

    pub fn writeHyperlinkLabel(self: Destination, writer: *std.Io.Writer) !void {
        try writer.writeByte('(');
        try writer.writeAll("\x1b]8;;");
        try self.writeUrl(writer);
        try writer.writeAll("\x1b\\\x1b[4m");
        try writeLabel(self.kind, writer);
        try writer.writeAll("\x1b[24m\x1b]8;;\x1b\\)");
    }
};

pub fn destination(
    channel: update_target.Channel,
    version: []const u8,
    previous_revision: []const u8,
    revision: []const u8,
) ?Destination {
    return switch (channel) {
        .stable => if (update_target.isValidVersion(update_target.normalizeVersion(version))) .{
            .kind = .notes,
            .channel = .stable,
            .version = version,
        } else null,
        .dev => if (update_target.isValidRevision(revision)) .{
            .kind = .changes,
            .channel = .dev,
            .version = version,
            .previous_revision = if (update_target.isValidRevision(previous_revision)) previous_revision else null,
            .revision = revision,
        } else null,
    };
}

pub fn writeLabel(kind: Kind, writer: *std.Io.Writer) !void {
    try writer.writeAll(switch (kind) {
        .notes => "notes",
        .changes => "changes",
    });
}

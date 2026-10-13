const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const session_id_random_bytes: usize = 9;
const session_id_encoded_bytes = std.base64.url_safe_no_pad.Encoder.calcSize(session_id_random_bytes);
const terminal_session_id_prefix = "shell-";
const terminal_session_id_random_bytes: usize = 16;

pub fn sessionDirPath(alloc: Allocator, sessions_dir: []const u8, session_id: []const u8) ![]u8 {
    try validateSessionId(session_id);
    return std.Io.Dir.path.join(alloc, &.{ sessions_dir, session_id });
}

pub fn validateSessionId(session_id: []const u8) !void {
    if (session_id.len == 0 or session_id.len > 255 or
        std.mem.eql(u8, session_id, ".") or std.mem.eql(u8, session_id, ".."))
    {
        return error.InvalidSessionId;
    }
    for (session_id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return error.InvalidSessionId;
        }
    }
}

pub fn generateSessionId(alloc: Allocator) ![]u8 {
    var random_bytes: [session_id_random_bytes]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    const id = try alloc.alloc(u8, session_id_encoded_bytes);
    _ = std.base64.url_safe_no_pad.Encoder.encode(id, &random_bytes);
    return id;
}

pub fn generateTerminalSessionId(alloc: Allocator) ![]u8 {
    var random_bytes: [terminal_session_id_random_bytes]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len);
    const id = try alloc.alloc(u8, terminal_session_id_prefix.len + encoded_len);
    @memcpy(id[0..terminal_session_id_prefix.len], terminal_session_id_prefix);
    _ = std.base64.url_safe_no_pad.Encoder.encode(
        id[terminal_session_id_prefix.len..],
        &random_bytes,
    );
    return id;
}

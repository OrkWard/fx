const std = @import("std");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
/// A handle keeps the first 8 bytes of the digest.
const digest_hex_bytes = 16;

pub fn contentAddressedHandle(
    alloc: Allocator,
    source_handle: []const u8,
    suffix: []const u8,
    digest: [Sha256.digest_length]u8,
) ![]u8 {
    if (suffix.len == 0 or !std.mem.endsWith(u8, source_handle, suffix)) {
        return error.InvalidArtifactHandle;
    }
    const digest_hex = std.fmt.bytesToHex(digest[0..8].*, .lower);
    return alloc.print(
        "{s}-{s}{s}",
        .{
            source_handle[0 .. source_handle.len - suffix.len],
            &digest_hex,
            suffix,
        },
    );
}

pub fn hasContentDigest(
    handle: []const u8,
    suffix: []const u8,
) bool {
    return encodedDigest(handle, suffix) != null;
}

pub fn handleMatchesContentDigest(
    handle: []const u8,
    suffix: []const u8,
    digest: [Sha256.digest_length]u8,
) bool {
    const encoded = encodedDigest(handle, suffix) orelse return false;
    const expected = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, encoded, expected[0..encoded.len]);
}

/// The 16 hex digits a handle ends in before `suffix`.
fn encodedDigest(handle: []const u8, suffix: []const u8) ?[]const u8 {
    if (suffix.len == 0 or !std.mem.endsWith(u8, handle, suffix)) return null;
    const stem = handle[0 .. handle.len - suffix.len];
    const separator = std.mem.findScalarLast(u8, stem, '-') orelse return null;
    const encoded = stem[separator + 1 ..];
    if (encoded.len != digest_hex_bytes) return null;
    if (!isLowerHex(encoded)) return null;
    return encoded;
}

fn isLowerHex(text: []const u8) bool {
    for (text) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    return true;
}

test "content addressed artifact handles authenticate exact bytes" {
    const alloc = std.testing.allocator;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("saved output", &digest, .{});
    const handle = try contentAddressedHandle(
        alloc,
        "fx-command-123.log",
        ".log",
        digest,
    );
    defer alloc.free(handle);
    try std.testing.expectEqualStrings(
        "fx-command-123-1b2a9cb5a0298dcb.log",
        handle,
    );
    try std.testing.expect(handleMatchesContentDigest(
        handle,
        ".log",
        digest,
    ));
    Sha256.hash("xaved output", &digest, .{});
    try std.testing.expect(!handleMatchesContentDigest(
        handle,
        ".log",
        digest,
    ));
}

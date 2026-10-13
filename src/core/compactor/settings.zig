//! The `auto_compact_percent` setting: how full a request gets before
//! fx-compactor runs on its own.

const std = @import("std");

/// Automatic compaction starts once a request reaches this share of the
/// model's usable input window.
pub const default_percent: u8 = 80;
pub const min_percent: u8 = 10;
pub const max_percent: u8 = 80;

pub fn isValidPercent(value: u64) bool {
    return value >= min_percent and value <= max_percent;
}

/// Parses a process override. Invalid or out-of-range values are ignored.
fn parsePercent(raw: ?[]const u8) ?u8 {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseUnsigned(u8, trimmed, 10) catch return null;
    return if (isValidPercent(value)) value else null;
}

pub fn resolvePercent(configured: ?u8, process_override: ?[]const u8) u8 {
    return parsePercent(process_override) orelse configured orelse default_percent;
}

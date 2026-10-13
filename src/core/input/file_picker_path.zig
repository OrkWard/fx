const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");

fn needs_quotes(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, ".")) return true;
    for (path) |byte| {
        if (byte >= 0x80 or std.ascii.isAlphanumeric(byte)) continue;
        if (byte != '_' and byte != '-' and byte != '.' and byte != '/' and byte != '~') return true;
    }
    return false;
}

pub fn isRepresentable(path: []const u8) bool {
    return path.len > 0 and text_utils.isTerminalSafe(path);
}

fn is_separator(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn is_start_boundary(byte: u8) bool {
    return is_separator(byte) or switch (byte) {
        '(', '[', '{', '<', '\'', '"', '`' => true,
        else => false,
    };
}

fn is_sentence_punctuation(byte: u8) bool {
    return switch (byte) {
        ',', '.', ';', ':', '!', '?' => true,
        else => false,
    };
}

/// Legacy image token boundaries only, not shell expansion or path decoding.
pub fn token_end(text: []const u8, start: usize) usize {
    var index = start;
    var quote: ?u8 = null;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '\\' and index + 1 < text.len) {
            index += 1;
            continue;
        }
        if (quote) |active| {
            if (byte == active) quote = null;
        } else if (byte == '"' or byte == '\'') {
            quote = byte;
        } else if (is_separator(byte)) break;
    }
    return index;
}

pub const Status = enum { complete, incomplete, invalid };

/// Source offsets borrow the unchanged input. `end` includes any prose suffix;
/// `path_end` excludes the closing quote, and `quote_end` includes it.
pub const Token = struct {
    start: usize,
    end: usize,
    path_start: usize,
    path_end: usize,
    quote_end: ?usize = null,
    status: Status,
    quoted: bool,
    canonical_escapes: bool = true,
};

pub fn parse_at(text: []const u8, start: usize) ?Token {
    if (start >= text.len or text[start] != '@') return null;
    if (start > 0 and !is_start_boundary(text[start - 1])) return null;
    const quoted = start + 1 < text.len and text[start + 1] == '"';
    const path_start = start + 1 + @intFromBool(quoted);
    if (!quoted) {
        var end = path_start;
        if (end < text.len and text[end] == '\'') {
            end = token_end(text, path_start);
        } else {
            // A quote embedded in a bare filename is data, including a prose
            // quote that follows it. It must not swallow later @ occurrences.
            while (end < text.len and !is_separator(text[end])) : (end += 1) {
                if (text[end] == '\\' and end + 1 < text.len) end += 1;
            }
        }
        return .{ .start = start, .end = end, .path_start = path_start, .path_end = end, .quoted = false, .status = if (end == path_start) .incomplete else .complete };
    }

    var index = path_start;
    var canonical_escapes = true;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '\n' or byte == '\r' or byte == '\t') break;
        if (byte == '\\') {
            if (index + 1 == text.len) {
                index = text.len;
                break;
            }
            const next = text[index + 1];
            if (next == '\n' or next == '\r' or next == '\t') break;
            canonical_escapes = canonical_escapes and (next == '\\' or next == '"');
            index += 1;
        } else if (byte == '"') {
            const quote_end = index + 1;
            const end = token_end(text, quote_end);
            var valid = index > path_start and text_utils.isTerminalSafe(text[path_start..index]);
            for (text[quote_end..end]) |suffix| valid = valid and is_sentence_punctuation(suffix);
            return .{
                .start = start,
                .end = end,
                .path_start = path_start,
                .path_end = index,
                .quote_end = quote_end,
                .status = if (valid) .complete else .invalid,
                .quoted = true,
                .canonical_escapes = canonical_escapes,
            };
        }
    }
    return .{ .start = start, .end = index, .path_start = path_start, .path_end = index, .status = .incomplete, .quoted = true, .canonical_escapes = canonical_escapes };
}

pub const Iterator = struct {
    text: []const u8,
    offset: usize = 0,

    pub fn next(self: *Iterator) ?Token {
        while (self.offset < self.text.len) {
            if (parse_at(self.text, self.offset)) |token| {
                self.offset = @max(token.end, self.offset + 1);
                return token;
            }
            self.offset += 1;
        }
        return null;
    }
};

const DecodeError = error{ InvalidPath, NoSpaceLeft };

/// Decodes a quoted payload (without delimiters) into caller-owned storage.
/// Legacy escape-next-byte spelling is retained; no JSON or variable expansion.
pub fn decode_into(payload: []const u8, out: []u8) DecodeError![]const u8 {
    if (!text_utils.isTerminalSafe(payload)) return error.InvalidPath;
    var index: usize = 0;
    var written: usize = 0;
    while (index < payload.len) : (index += 1) {
        if (payload[index] == '\\') {
            index += 1;
            if (index == payload.len) return error.InvalidPath;
        }
        if (written == out.len) return error.NoSpaceLeft;
        out[written] = payload[index];
        written += 1;
    }
    return out[0..written];
}

/// Caller owns the decoded payload.
pub fn decode_alloc(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, payload.len);
    errdefer alloc.free(out);
    const decoded = try decode_into(payload, out);
    return alloc.realloc(out, decoded.len);
}

pub const Query = struct {
    /// Raw payload prefix, not the decoded lookup key.
    query: []const u8,
    at_offset: usize,
    token_start: usize,
    replace_end: usize,
    quoted: bool,

    pub fn decoded_query(self: Query, out: []u8) DecodeError![]const u8 {
        return if (self.quoted) decode_into(self.query, out) else self.query;
    }
};

pub fn query_at(text: []const u8, cursor: usize) ?Query {
    if (cursor > text.len) return null;
    var iterator: Iterator = .{ .text = text };
    while (iterator.next()) |token| {
        if (cursor < token.path_start) return null;
        if (cursor > token.path_end) continue;
        if (token.status == .invalid) return null;
        const prefix = text[token.path_start..cursor];
        if (!text_utils.isTerminalSafe(prefix)) return null;
        if (!token.quoted) {
            // Bare completion has always replaced only the prefix at the caret.
            for (prefix) |byte| if (is_separator(byte)) return null;
        }
        return .{
            .query = prefix,
            .at_offset = token.start,
            .token_start = token.path_start,
            .replace_end = token.quote_end orelse cursor,
            .quoted = token.quoted,
        };
    }
    return null;
}

/// Whether inserting at this cursor edits an existing path payload.
pub fn contains_position(text: []const u8, cursor: usize) bool {
    var paths: Iterator = .{ .text = text };
    while (paths.next()) |path| {
        if (cursor < path.path_start) return false;
        const end = if (path.quoted and path.status == .complete) path.path_end else path.end;
        if (cursor <= end) return true;
    }
    return false;
}

const EncodeOptions = struct {
    quoted: bool = false,
    directory: bool = false,
    workspace_relative: bool = false,
};

/// Returns caller-owned @ text, without a trailing composer separator.
pub fn encode(alloc: std.mem.Allocator, path: []const u8, options: EncodeOptions) ![]u8 {
    if (!isRepresentable(path)) return error.InvalidPath;
    const quote = options.quoted or needs_quotes(path);
    const prefix_relative = options.workspace_relative and path[0] == '~';
    var length = try std.math.add(usize, 1 + @as(usize, @intFromBool(quote)) + @as(usize, @intFromBool(quote and !options.directory)) + @as(usize, @intFromBool(options.directory)) + @as(usize, if (prefix_relative) 2 else 0), path.len);
    if (quote) for (path) |byte| {
        if (byte == '\\' or byte == '"') length = try std.math.add(usize, length, 1);
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, length);
    out.appendAssumeCapacity('@');
    if (quote) out.appendAssumeCapacity('"');
    if (prefix_relative) out.appendSliceAssumeCapacity("./");
    for (path) |byte| {
        if (quote and (byte == '\\' or byte == '"')) out.appendAssumeCapacity('\\');
        out.appendAssumeCapacity(byte);
    }
    if (options.directory) out.appendAssumeCapacity('/');
    if (quote and !options.directory) out.appendAssumeCapacity('"');
    return out.toOwnedSlice(alloc);
}

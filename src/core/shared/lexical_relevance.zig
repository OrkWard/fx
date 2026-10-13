const std = @import("std");

pub const max_query_bytes: usize = 4 * 1024;
// Distinct tokens require at least one byte each and a separator between them.
pub const max_query_tokens: usize = (max_query_bytes + 1) / 2;

pub const PrepareError = error{
    QueryTooLong,
};

pub const PreparedQuery = struct {
    const TokenRange = struct {
        start: u16,
        end: u16,
    };

    raw: []const u8,
    tokens: [max_query_tokens]TokenRange,
    token_count: usize,

    pub fn tokenAt(self: *const PreparedQuery, index: usize) []const u8 {
        std.debug.assert(index < self.token_count);
        const token = self.tokens[index];
        return self.raw[token.start..token.end];
    }
};

inline fn failPreparedQuery(err: anytype) @TypeOf(err)!PreparedQuery {
    return @errorCast(failPreparedQueryDynamic(err));
}

noinline fn failPreparedQueryDynamic(err: anyerror) anyerror!PreparedQuery {
    return err;
}

pub const Score = struct {
    exact_identity: bool = false,
    strong_hits: usize = 0,
    weak_hits: usize = 0,
};

pub fn prepare(query: []const u8) PrepareError!PreparedQuery {
    if (query.len > max_query_bytes) return failPreparedQuery(error.QueryTooLong);

    var prepared = PreparedQuery{
        .raw = query,
        .tokens = undefined,
        .token_count = 0,
    };
    var start: ?usize = null;
    for (query, 0..) |byte, index| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (start == null) start = index;
            continue;
        }
        if (start) |token_start| {
            appendToken(&prepared, token_start, index);
            start = null;
        }
    }
    if (start) |token_start| {
        appendToken(&prepared, token_start, query.len);
    }
    return prepared;
}

pub fn score(
    query: *const PreparedQuery,
    exact_identities: []const []const u8,
    strong_fields: []const []const u8,
    weak_fields: []const []const u8,
) ?Score {
    var result = Score{
        .exact_identity = containsCompleteIdentity(query.raw, exact_identities),
    };

    for (0..query.token_count) |index| {
        const token = query.tokenAt(index);
        if (containsAnyCompleteToken(strong_fields, token)) {
            result.strong_hits += 1;
        } else if (containsAnySubstring(weak_fields, token)) {
            result.weak_hits += 1;
        }
    }

    if (!result.exact_identity and
        result.strong_hits == 0 and
        result.weak_hits == 0 and
        query.raw.len != 0)
    {
        return null;
    }
    return result;
}

pub fn order(a: Score, b: Score) std.math.Order {
    var result = std.math.order(@intFromBool(a.exact_identity), @intFromBool(b.exact_identity));
    if (result != .eq) return result;
    result = std.math.order(a.strong_hits +| a.weak_hits, b.strong_hits +| b.weak_hits);
    if (result != .eq) return result;
    return std.math.order(a.strong_hits, b.strong_hits);
}

fn appendToken(
    prepared: *PreparedQuery,
    start: usize,
    end: usize,
) void {
    const token = prepared.raw[start..end];
    for (0..prepared.token_count) |index| {
        const existing = prepared.tokenAt(index);
        if (std.ascii.eqlIgnoreCase(existing, token)) return;
    }
    std.debug.assert(prepared.token_count < max_query_tokens);
    prepared.tokens[prepared.token_count] = .{
        .start = @intCast(start),
        .end = @intCast(end),
    };
    prepared.token_count += 1;
}

fn containsAnyCompleteToken(fields: []const []const u8, token: []const u8) bool {
    for (fields) |field| {
        if (containsCompleteTokenIgnoreCase(field, token)) return true;
    }
    return false;
}

fn containsAnySubstring(fields: []const []const u8, token: []const u8) bool {
    for (fields) |field| {
        if (containsIgnoreCase(field, token)) return true;
    }
    return false;
}

fn containsCompleteTokenIgnoreCase(field: []const u8, token: []const u8) bool {
    if (token.len == 0 or token.len > field.len) return false;

    var start: usize = 0;
    while (start <= field.len - token.len) : (start += 1) {
        const end = start + token.len;
        if (!std.ascii.eqlIgnoreCase(field[start..end], token)) continue;
        if (start > 0 and std.ascii.isAlphanumeric(field[start - 1])) continue;
        if (end < field.len and std.ascii.isAlphanumeric(field[end])) continue;
        return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start <= haystack.len - needle.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) {
            return true;
        }
    }
    return false;
}

pub fn containsCompleteIdentity(raw: []const u8, identities: []const []const u8) bool {
    for (raw, 0..) |_, start| {
        for (identities) |identity| {
            if (identity.len == 0 or identity.len > raw.len - start) continue;
            const end = start + identity.len;
            if (!std.ascii.eqlIgnoreCase(raw[start..end], identity)) continue;
            if (start > 0 and isIdentityByte(raw[start - 1])) continue;
            if (end < raw.len and isIdentityByte(raw[end])) continue;
            return true;
        }
    }
    return false;
}

fn isIdentityByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

const std = @import("std");

const whitespace = " \t\r\n";

pub const LexError = error{
    EmbeddedNul,
    InvalidUtf8,
    MalformedEscape,
    UnbalancedQuote,
};

pub const PipeSegment = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

pub const ArgvToken = struct {
    raw: []const u8,
    value: []u8,
    start: usize,
    end: usize,
    quoted: bool = false,
};

pub const Argv = struct {
    tokens: []ArgvToken = &.{},

    pub fn deinit(self: *Argv, alloc: std.mem.Allocator) void {
        for (self.tokens) |token| alloc.free(token.value);
        alloc.free(self.tokens);
        self.* = .{};
    }
};

pub const RedirectionKind = enum {
    read_path,
    write_path,
    read_write_path,
    unsupported,
};

const ShellScan = struct {
    in_single: bool = false,
    in_double: bool = false,
    escaped: bool = false,

    fn unquoted(self: *ShellScan, input: []const u8, index: usize) LexError!?u8 {
        const ch = input[index];
        if (self.escaped) {
            self.escaped = false;
            return null;
        }
        if (ch == '\\' and !self.in_single) {
            if (index + 1 >= input.len) return error.MalformedEscape;
            self.escaped = true;
            return null;
        }
        if (ch == '\'' and !self.in_double) {
            self.in_single = !self.in_single;
            return null;
        }
        if (ch == '"' and !self.in_single) {
            self.in_double = !self.in_double;
            return null;
        }
        if (self.in_single or self.in_double) return null;
        return ch;
    }

    fn finish(self: ShellScan) LexError!void {
        if (self.escaped) return error.MalformedEscape;
        if (self.in_single or self.in_double) return error.UnbalancedQuote;
    }
};

pub fn pipe_segments(alloc: std.mem.Allocator, command: []const u8) ![]PipeSegment {
    try check_input(command);

    var segments: std.ArrayList(PipeSegment) = .empty;
    errdefer segments.deinit(alloc);

    var scan: ShellScan = .{};
    var segment_start: usize = 0;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const ch = try scan.unquoted(command, i) orelse continue;

        if (ch == '|') {
            if (i > 0 and command[i - 1] == '>') continue;
            if (i + 1 < command.len and command[i + 1] == '|') {
                i += 1;
                continue;
            }
            try segments.append(alloc, trim_segment(command, segment_start, i));
            segment_start = i + 1;
        }
    }

    try scan.finish();
    try segments.append(alloc, trim_segment(command, segment_start, command.len));
    return segments.toOwnedSlice(alloc);
}

fn trim_segment(command: []const u8, raw_start: usize, raw_end: usize) PipeSegment {
    var start = raw_start;
    var end = raw_end;
    while (start < end and is_whitespace(command[start])) : (start += 1) {}
    while (end > start and is_whitespace(command[end - 1])) : (end -= 1) {}
    return .{ .text = command[start..end], .start = start, .end = end };
}

/// Conservative shell-shape detector for syntax that needs a real shell parser.
/// It recognizes common unquoted compound/subshell ASCII metacharacters only;
/// it intentionally does not model every POSIX shell grammar production.
pub fn unsafe_compound_indicator(command: []const u8) bool {
    if (check_input(command)) |_| {} else |_| return true;

    var scan: ShellScan = .{};
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const maybe_ch = scan.unquoted(command, i) catch return true;
        const ch = maybe_ch orelse continue;

        if (ch == '$' and i + 1 < command.len and command[i + 1] == '(') return true;
        if (ch == '`') return true;
        if (ch == '(' or ch == ')' or ch == '{' or ch == '}') return true;
        if (ch == ';' or ch == '\n') return true;
        if (ch == '&') {
            if (i + 1 < command.len and command[i + 1] == '>') continue;
            if (i > 0 and command[i - 1] == '>') continue;
            return true;
        }
        if (ch == '|' and i + 1 < command.len and command[i + 1] == '|') return true;
    }
    scan.finish() catch return true;
    return false;
}

pub fn tokenize_argv(alloc: std.mem.Allocator, command: []const u8) !Argv {
    try check_input(command);

    var tokens: std.ArrayList(ArgvToken) = .empty;
    errdefer {
        for (tokens.items) |token| alloc.free(token.value);
        tokens.deinit(alloc);
    }
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(alloc);

    var token_start: usize = 0;
    var token_active = false;
    var token_quoted = false;
    var in_single = false;
    var in_double = false;

    var i: usize = 0;
    while (i < command.len) {
        const ch = command[i];

        if (!in_single and !in_double) {
            if (is_whitespace(ch)) {
                if (token_active) try finish_token(alloc, &tokens, &value, command, token_start, i, token_quoted);
                token_active = false;
                token_quoted = false;
                i += 1;
                continue;
            }

            if (redirection_operator_len(command, i)) |op_len| {
                if (token_active) try finish_token(alloc, &tokens, &value, command, token_start, i, token_quoted);
                try append_operator_token(alloc, &tokens, command, i, i + op_len);
                token_active = false;
                token_quoted = false;
                i += op_len;
                continue;
            }

            if (control_operator_len(command, i)) |op_len| {
                if (token_active) try finish_token(alloc, &tokens, &value, command, token_start, i, token_quoted);
                try append_operator_token(alloc, &tokens, command, i, i + op_len);
                token_active = false;
                token_quoted = false;
                i += op_len;
                continue;
            }
        }

        if (!token_active) {
            token_start = i;
            token_active = true;
        }

        if (ch == '\'' and !in_double) {
            in_single = !in_single;
            token_quoted = true;
            i += 1;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            token_quoted = true;
            i += 1;
            continue;
        }
        if (ch == '\\' and !in_single) {
            if (i + 1 >= command.len) return error.MalformedEscape;
            try value.append(alloc, command[i + 1]);
            i += 2;
            continue;
        }

        try value.append(alloc, ch);
        i += 1;
    }

    if (in_single or in_double) return error.UnbalancedQuote;
    if (token_active) try finish_token(alloc, &tokens, &value, command, token_start, command.len, token_quoted);
    return .{ .tokens = try tokens.toOwnedSlice(alloc) };
}

fn finish_token(
    alloc: std.mem.Allocator,
    tokens: *std.ArrayList(ArgvToken),
    value: *std.ArrayList(u8),
    command: []const u8,
    start: usize,
    end: usize,
    quoted: bool,
) !void {
    const owned = try alloc.dupe(u8, value.items);
    value.clearRetainingCapacity();
    errdefer alloc.free(owned);
    try tokens.append(alloc, .{
        .raw = command[start..end],
        .value = owned,
        .start = start,
        .end = end,
        .quoted = quoted,
    });
}

fn append_operator_token(
    alloc: std.mem.Allocator,
    tokens: *std.ArrayList(ArgvToken),
    command: []const u8,
    start: usize,
    end: usize,
) !void {
    const owned = try alloc.dupe(u8, command[start..end]);
    errdefer alloc.free(owned);
    try tokens.append(alloc, .{
        .raw = command[start..end],
        .value = owned,
        .start = start,
        .end = end,
    });
}

fn redirection_operator_len(input: []const u8, start: usize) ?usize {
    const ch = input[start];
    if (ch == '&' and start + 1 < input.len and input[start + 1] == '>') {
        if (start + 2 < input.len and input[start + 2] == '>') return 3;
        return 2;
    }
    if (ch == '<') {
        if (start + 2 < input.len and input[start + 1] == '<' and input[start + 2] == '<') return 3;
        if (start + 1 < input.len and (input[start + 1] == '<' or input[start + 1] == '&' or input[start + 1] == '>')) return 2;
        return 1;
    }
    if (ch == '>') {
        if (start + 1 < input.len and (input[start + 1] == '>' or input[start + 1] == '|' or input[start + 1] == '&')) return 2;
        return 1;
    }
    return null;
}

pub fn redirection_kind(value: []const u8) ?RedirectionKind {
    if (std.mem.eql(u8, value, "<")) return .read_path;
    if (std.mem.eql(u8, value, "<>")) return .read_write_path;
    if (std.mem.eql(u8, value, "<<") or std.mem.eql(u8, value, "<<<") or std.mem.eql(u8, value, "<&")) return .unsupported;

    if (std.mem.eql(u8, value, ">") or
        std.mem.eql(u8, value, ">>") or
        std.mem.eql(u8, value, ">|") or
        std.mem.eql(u8, value, "&>") or
        std.mem.eql(u8, value, "&>>") or
        std.mem.eql(u8, value, ">&"))
    {
        return .write_path;
    }
    return null;
}

fn control_operator_len(input: []const u8, start: usize) ?usize {
    return switch (input[start]) {
        ';', '(', ')', '{', '}' => 1,
        '|' => if (start + 1 < input.len and input[start + 1] == '|') 2 else 1,
        '&' => if (start + 1 < input.len and input[start + 1] == '&') 2 else 1,
        else => null,
    };
}

pub fn is_safe_env_assignment(token: []const u8) bool {
    const eq = std.mem.findScalar(u8, token, '=') orelse return false;
    if (eq == 0) return false;
    return is_safe_env_name(token[0..eq]);
}

fn is_safe_env_name(name: []const u8) bool {
    return std.mem.eql(u8, name, "CI") or
        std.mem.eql(u8, name, "NODE_ENV") or
        std.mem.eql(u8, name, "BUN_ENV") or
        std.mem.eql(u8, name, "DENO_ENV") or
        std.mem.eql(u8, name, "PYTHONUNBUFFERED") or
        std.mem.eql(u8, name, "PYTHONWARNINGS") or
        std.mem.eql(u8, name, "RUST_LOG") or
        std.mem.eql(u8, name, "RUST_BACKTRACE") or
        std.mem.eql(u8, name, "TERM") or
        std.mem.eql(u8, name, "COLORTERM") or
        std.mem.eql(u8, name, "NO_COLOR") or
        std.mem.eql(u8, name, "FORCE_COLOR") or
        std.mem.eql(u8, name, "CLICOLOR") or
        std.mem.eql(u8, name, "CLICOLOR_FORCE") or
        std.mem.eql(u8, name, "LANG") or
        std.mem.eql(u8, name, "LC_ALL") or
        std.mem.eql(u8, name, "LC_CTYPE") or
        std.mem.eql(u8, name, "LC_MESSAGES") or
        std.mem.eql(u8, name, "TZ") or
        std.mem.eql(u8, name, "CC") or
        std.mem.eql(u8, name, "CXX") or
        std.mem.eql(u8, name, "AR") or
        std.mem.eql(u8, name, "AS") or
        std.mem.eql(u8, name, "LD") or
        std.mem.eql(u8, name, "CFLAGS") or
        std.mem.eql(u8, name, "CXXFLAGS") or
        std.mem.eql(u8, name, "CPPFLAGS") or
        std.mem.eql(u8, name, "LDFLAGS") or
        std.mem.eql(u8, name, "MAKEFLAGS") or
        std.mem.eql(u8, name, "CMAKE_BUILD_TYPE");
}

fn check_input(input: []const u8) LexError!void {
    if (std.mem.findScalar(u8, input, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
}

fn is_whitespace(ch: u8) bool {
    return std.mem.findScalar(u8, whitespace, ch) != null;
}

const std = @import("std");
const shared_theme = @import("../../shared/theme.zig");
const languages = @import("code_highlight_languages.zig");

const Allocator = std.mem.Allocator;

pub const Theme = enum {
    dark,
    light,
};

const Palette = shared_theme.SyntaxPalette;

const dark_palette: Palette = shared_theme.fx_dark.syntax;
const light_palette: Palette = shared_theme.fx_light.syntax;

fn paletteForTheme(theme: Theme) Palette {
    const active = shared_theme.current();
    // When the requested variant matches the active theme, custom themes
    // contribute their syntax palette; otherwise render the builtin variant.
    if (active.light == (theme == .light)) return active.syntax;
    return switch (theme) {
        .dark => dark_palette,
        .light => light_palette,
    };
}

/// When `base` is set, the span opens with it and every token close restores
/// it, so untokenized text keeps the caller's ambient color. Null leaves plain
/// text at the terminal default, as before.
pub fn highlight(
    alloc: Allocator,
    source: []const u8,
    profile: *const languages.Profile,
    theme: Theme,
    base: ?[]const u8,
) ![]u8 {
    var styled: std.ArrayList(u8) = .empty;
    errdefer styled.deinit(alloc);
    const palette = paletteForTheme(theme);
    if (base) |base_style| try styled.appendSlice(alloc, base_style);
    // A theme can disable syntax highlighting entirely; the span then keeps
    // only the caller's base, byte-identical to a token-free source.
    if (!palette.enabled) {
        try styled.appendSlice(alloc, source);
        return styled.toOwnedSlice(alloc);
    }

    var index: usize = 0;
    // Command-position state, used only by command_words profiles (shell):
    // the next word is a command name unless a token says otherwise.
    var command_position = profile.command_words;
    while (index < source.len) {
        const byte = source[index];
        if (byte == '\n') {
            try styled.append(alloc, '\n');
            command_position = profile.command_words;
            index += 1;
            continue;
        }
        if (blockCommentEnd(source, index, profile.block_comment)) |end| {
            try appendStyled(alloc, &styled, palette.comment_style, source[index..end], base);
            command_position = false;
            index = end;
            continue;
        }
        if (lineCommentEnd(source, index, profile.line_comments)) |end| {
            try appendStyled(alloc, &styled, palette.comment_style, source[index..end], base);
            command_position = false;
            index = end;
            continue;
        }
        if (isQuote(byte, profile.quotes)) {
            const end = quotedEnd(source, index);
            if (byte == '"' and profile.dollar_vars) {
                try appendDoubleQuoted(alloc, &styled, palette, source[index..end], base);
            } else {
                try appendStyled(alloc, &styled, palette.string_style, source[index..end], base);
            }
            command_position = false;
            index = end;
            continue;
        }
        if (isNumberStart(source, index)) {
            const end = numberEnd(source, index);
            // Shell: bare number arguments stay plain (a run id is not a
            // literal); only file descriptors glued to a redirect color.
            if (profile.bare_numbers or fdContext(source, index, end)) {
                try appendStyled(alloc, &styled, palette.number_style, source[index..end], base);
            } else {
                try styled.appendSlice(alloc, source[index..end]);
            }
            command_position = false;
            index = end;
            continue;
        }
        if (profile.dollar_vars and byte == '$') {
            // Command substitution reopens command position for its contents.
            if (index + 1 < source.len and source[index + 1] == '(') {
                try appendStyled(alloc, &styled, palette.operator_style, "$(", base);
                command_position = true;
                index += 2;
                continue;
            }
            if (dollarVarEnd(source, index)) |end| {
                try appendStyled(alloc, &styled, palette.variable_style, source[index..end], base);
                command_position = false;
                index = end;
                continue;
            }
        }
        if (profile.dollar_vars and byte == '~' and tildeStart(source, index, profile.operators)) {
            try appendStyled(alloc, &styled, palette.variable_style, "~", base);
            command_position = false;
            index += 1;
            continue;
        }
        if (profile.dash_flags and byte == '-') {
            if (flagEnd(source, index, profile.operators)) |end| {
                try appendStyled(alloc, &styled, palette.number_style, source[index..end], base);
                command_position = false;
                index = end;
                continue;
            }
        }
        if (isOperatorChar(byte, profile.operators)) {
            const end = operatorRunEnd(source, index, profile.operators);
            const run = source[index..end];
            try appendStyled(alloc, &styled, palette.operator_style, run, base);
            // Redirect targets are paths, not commands; `2>&1`-style runs too.
            command_position = std.mem.findScalar(u8, run, '<') == null and
                std.mem.findScalar(u8, run, '>') == null;
            index = end;
            continue;
        }
        if (profile.command_words and byte == '`') {
            // Backticks parse as code; their contents reopen command position.
            try styled.append(alloc, byte);
            command_position = true;
            index += 1;
            continue;
        }
        if (isIdentifierStart(byte)) {
            const end = identifierEnd(source, index);
            const token = source[index..end];
            // A word glued to a path separator is a path segment, not syntax:
            // /dev/null keeps "null" plain.
            const after_separator = index > 0 and source[index - 1] == '/';
            var styled_word = false;
            if (profile.command_words) {
                if (command_position and !after_separator) {
                    // Control keywords read as keywords; other command words
                    // as functions, matching the grammar's scopes.
                    const style = if (inList(token, &command_prefixes, .sensitive))
                        palette.keyword_style
                    else
                        palette.function_style;
                    try appendStyled(alloc, &styled, style, token, base);
                    styled_word = true;
                }
            } else if (!after_separator and (profile.keywords.len > 0 or profile.literals.len > 0)) {
                const token_hash = languages.packedWordHash(token);
                if (inPackedList(token, token_hash, profile.keywords, profile.keyword_case)) {
                    try appendStyled(alloc, &styled, palette.keyword_style, token, base);
                    styled_word = true;
                } else if (inPackedList(token, token_hash, profile.literals, profile.keyword_case)) {
                    try appendStyled(alloc, &styled, palette.number_style, token, base);
                    styled_word = true;
                }
            }
            if (!styled_word) try styled.appendSlice(alloc, token);
            // Control keywords are followed by the command they govern; an
            // ordinary command word is followed by its arguments.
            if (profile.command_words) {
                command_position = styled_word and command_position and
                    inList(token, &command_prefixes, .sensitive);
            }
            index = end;
            continue;
        }
        try styled.append(alloc, byte);
        if (!std.ascii.isWhitespace(byte)) command_position = false;
        index += 1;
    }

    return styled.toOwnedSlice(alloc);
}

/// Control keywords after which the next word is again a command.
const command_prefixes = [_][]const u8{ "if", "then", "elif", "else", "while", "until", "do" };

/// File descriptors glued to a redirect keep the number color when bare
/// number arguments stay plain: the 2 in `2>` and the 1 in `>&1`.
fn fdContext(source: []const u8, start: usize, end: usize) bool {
    if (end < source.len and (source[end] == '>' or source[end] == '<')) return true;
    if (start > 0 and (source[start - 1] == '>' or source[start - 1] == '<')) return true;
    if (start > 1 and source[start - 1] == '&' and (source[start - 2] == '>' or source[start - 2] == '<')) return true;
    return false;
}

/// A tilde opens a home path at a word boundary when a path or name follows.
fn tildeStart(source: []const u8, index: usize, operators: []const u8) bool {
    if (index > 0) {
        const prev = source[index - 1];
        if (!std.ascii.isWhitespace(prev) and !isOperatorChar(prev, operators) and prev != '(' and prev != '`') return false;
    }
    const next = index + 1;
    return next < source.len and
        (source[next] == '/' or isIdentifierStart(source[next]) or std.ascii.isDigit(source[next]));
}

/// Double-quoted spans interpolate in shell: `$name`, `${name}`, and `$(`
/// take the keyword color while the rest keeps the string color.
fn appendDoubleQuoted(alloc: Allocator, out: *std.ArrayList(u8), palette: Palette, text: []const u8, base: ?[]const u8) !void {
    const inner_end = text.len - 1;
    // The opening quote rides the first text chunk so the pair stays one span.
    var chunk_start: usize = 0;
    var i: usize = 1;
    while (i < inner_end) {
        if (text[i] == '$' and (i == 0 or text[i - 1] != '\\')) {
            var var_end: ?usize = null;
            if (i + 1 < inner_end and text[i + 1] == '(') {
                var_end = i + 2;
            } else if (dollarVarEndWithin(text, i, inner_end)) |end| {
                var_end = end;
            }
            if (var_end) |end| {
                if (chunk_start < i) try appendStyled(alloc, out, palette.string_style, text[chunk_start..i], base);
                try appendStyled(alloc, out, palette.variable_style, text[i..end], base);
                i = end;
                chunk_start = end;
                continue;
            }
        }
        i += 1;
    }
    if (chunk_start < inner_end) try appendStyled(alloc, out, palette.string_style, text[chunk_start..inner_end], base);
    try appendStyled(alloc, out, palette.string_style, text[inner_end..], base);
}

fn appendStyled(alloc: Allocator, out: *std.ArrayList(u8), style: []const u8, text: []const u8, base: ?[]const u8) !void {
    try out.appendSlice(alloc, style);
    try out.appendSlice(alloc, text);
    // Close whatever the slot opened: fg-only slots keep the plain reset,
    // themed slots carrying bold/italic get those reset too.
    try out.appendSlice(alloc, shared_theme.closingFor(style));
    if (base) |base_style| try out.appendSlice(alloc, base_style);
}

/// Line-oriented diff painting: `+`/`-` lines take the caller's
/// capability-resolved diff marker colors, `@@` hunks the keyword color, and
/// file metadata lines the comment color. Honors the theme's syntax switch.
pub fn highlightDiff(
    alloc: Allocator,
    source: []const u8,
    theme: Theme,
    added: []const u8,
    removed: []const u8,
) ![]u8 {
    var styled: std.ArrayList(u8) = .empty;
    errdefer styled.deinit(alloc);
    const palette = paletteForTheme(theme);
    if (!palette.enabled) {
        try styled.appendSlice(alloc, source);
        return styled.toOwnedSlice(alloc);
    }

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const style: ?[]const u8 = if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---"))
            palette.comment_style
        else if (std.mem.startsWith(u8, line, "+"))
            added
        else if (std.mem.startsWith(u8, line, "-"))
            removed
        else if (std.mem.startsWith(u8, line, "@@"))
            palette.keyword_style
        else if (std.mem.startsWith(u8, line, "diff ") or
            std.mem.startsWith(u8, line, "index ") or
            std.mem.startsWith(u8, line, "new file") or
            std.mem.startsWith(u8, line, "deleted file") or
            std.mem.startsWith(u8, line, "similarity") or
            std.mem.startsWith(u8, line, "rename "))
            palette.comment_style
        else
            null;
        if (style) |line_style| {
            try styled.appendSlice(alloc, line_style);
            try styled.appendSlice(alloc, line);
            try styled.appendSlice(alloc, shared_theme.closingFor(line_style));
        } else {
            try styled.appendSlice(alloc, line);
        }
        if (lines.peek() != null) try styled.append(alloc, '\n');
    }
    return styled.toOwnedSlice(alloc);
}

fn blockCommentEnd(source: []const u8, index: usize, block_comment: ?languages.BlockComment) ?usize {
    const comment = block_comment orelse return null;
    if (!std.mem.startsWith(u8, source[index..], comment.start)) return null;
    const content_start = index + comment.start.len;
    const close_start = std.mem.findPos(u8, source, content_start, comment.end) orelse return source.len;
    return close_start + comment.end.len;
}

fn lineCommentEnd(source: []const u8, index: usize, prefixes: []const []const u8) ?usize {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, source[index..], prefix)) return lineEnd(source, index);
    }
    return null;
}

fn lineEnd(source: []const u8, start: usize) usize {
    return std.mem.findScalarPos(u8, source, start, '\n') orelse source.len;
}

fn isQuote(byte: u8, quotes: []const u8) bool {
    return std.mem.findScalar(u8, quotes, byte) != null;
}

fn quotedEnd(source: []const u8, start: usize) usize {
    const quote = source[start];
    var index = start + 1;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\n') return index;
        if (source[index] == '\\' and index + 1 < source.len) {
            index += 1;
            continue;
        }
        if (source[index] == quote) return index + 1;
    }
    return source.len;
}

fn isNumberStart(source: []const u8, index: usize) bool {
    if (!std.ascii.isDigit(source[index])) return false;
    if (index == 0) return true;
    const prev = source[index - 1];
    if (isIdentifierContinue(prev)) return false;
    // A digit run glued to a word by a dash is a name segment, not a number:
    // paths like build-20260918 stay plain while flags like -80 still color.
    if (prev == '-' and index >= 2 and isIdentifierContinue(source[index - 2])) return false;
    return true;
}

fn numberEnd(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len and (std.ascii.isAlphanumeric(source[index]) or source[index] == '.' or source[index] == '_')) : (index += 1) {}
    return index;
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
}

fn isOperatorChar(byte: u8, operators: []const u8) bool {
    return std.mem.findScalar(u8, operators, byte) != null;
}

fn operatorRunEnd(source: []const u8, start: usize, operators: []const u8) usize {
    var end = start;
    while (end < source.len and isOperatorChar(source[end], operators)) end += 1;
    return end;
}

/// "$" opens a variable when a name, braced name, positional digit, or
/// special parameter follows; a bare "$" stays plain text.
fn dollarVarEnd(source: []const u8, start: usize) ?usize {
    return dollarVarEndWithin(source, start, source.len);
}

fn dollarVarEndWithin(source: []const u8, start: usize, limit: usize) ?usize {
    const next = start + 1;
    if (next >= limit) return null;
    const b = source[next];
    if (b == '{') {
        const close = std.mem.findScalarPos(u8, source, next + 1, '}') orelse return null;
        return if (close < limit) close + 1 else null;
    }
    if (std.ascii.isAlphabetic(b) or b == '_') {
        var end = next;
        while (end < limit and isIdentifierContinue(source[end])) end += 1;
        return end;
    }
    if (std.ascii.isDigit(b) or std.mem.findScalar(u8, "?#@*!$", b) != null) return next + 1;
    return null;
}

/// A dash opens a flag token only at a word boundary (after whitespace, an
/// operator, or the start) with a letter, digit, or second dash next. Dashes
/// inside words, like date suffixes in paths, stay plain.
fn flagEnd(source: []const u8, start: usize, operators: []const u8) ?usize {
    if (start > 0) {
        const prev = source[start - 1];
        if (!std.ascii.isWhitespace(prev) and !isOperatorChar(prev, operators)) return null;
    }
    const next = start + 1;
    if (next >= source.len) return null;
    const b = source[next];
    if (!std.ascii.isAlphanumeric(b) and b != '-') return null;
    var end = next;
    while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '-')) end += 1;
    return end;
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte);
}

fn identifierEnd(source: []const u8, start: usize) usize {
    var index = start + 1;
    while (index < source.len and isIdentifierContinue(source[index])) : (index += 1) {}
    return index;
}

fn inList(token: []const u8, options: []const []const u8, keyword_case: languages.KeywordCase) bool {
    for (options) |option| {
        const matches = switch (keyword_case) {
            .sensitive => std.mem.eql(u8, token, option),
            .ascii_insensitive => std.ascii.eqlIgnoreCase(token, option),
        };
        if (matches) return true;
    }
    return false;
}

fn inPackedList(token: []const u8, target_hash: u32, options: []const u8, keyword_case: languages.KeywordCase) bool {
    var offset: usize = 0;
    while (offset < options.len) {
        const hash = std.mem.readInt(u32, options[offset..][0..@sizeOf(u32)], .little);
        offset += @sizeOf(u32);
        const len = options[offset];
        offset += 1;
        const end = offset + len;
        const option = options[offset..end];
        if (hash == target_hash) {
            const matches = switch (keyword_case) {
                .sensitive => std.mem.eql(u8, token, option),
                .ascii_insensitive => std.ascii.eqlIgnoreCase(token, option),
            };
            if (matches) return true;
        }
        offset = end;
    }
    return false;
}

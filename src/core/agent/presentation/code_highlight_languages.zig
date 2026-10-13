const std = @import("std");

const Allocator = std.mem.Allocator;

pub const KeywordCase = enum {
    sensitive,
    ascii_insensitive,
};

pub const BlockComment = struct {
    start: []const u8,
    end: []const u8,
};

pub const Detection = enum {
    none,
    typescript_assertion,
    json,
    shell_shebang,
    python_header,
    sql_select,
    dockerfile_from,
    go_package,
    rust_function,
    diff_patch,
};

pub const Profile = struct {
    label: []const u8,
    aliases: []const []const u8,
    line_comments: []const []const u8 = &.{},
    block_comment: ?BlockComment = null,
    quotes: []const u8 = &.{},
    /// Characters colored as operator runs in the keyword color.
    operators: []const u8 = &.{},
    /// `$name`-style variables take the keyword color.
    dollar_vars: bool = false,
    /// A dash at a word boundary opens a flag token (`-n`, `--json`) in the
    /// number color.
    dash_flags: bool = false,
    /// The first word of each command (after start, a pipe or logical
    /// operator, `;`, `&`, `$(`, or a control keyword) takes the keyword
    /// color. Mirrors how the bash grammar scopes command words vs arguments.
    command_words: bool = false,
    /// When false, bare number arguments stay plain and only file
    /// descriptors glued to a redirect take the number color.
    bare_numbers: bool = true,
    /// Diff patches paint line-wise (+/-, hunks, file headers) instead of
    /// running the tokenizer.
    diff_lines: bool = false,
    keywords: []const u8 = "",
    literals: []const u8 = "",
    keyword_case: KeywordCase = .sensitive,
    detection: Detection = .none,
};

const double_quote = &[_]u8{'"'};
const double_single_quotes = &[_]u8{ '"', '\'' };
const shell_quotes = &[_]u8{ '"', '\'', '`' };

fn packedWordsLen(comptime words: anytype) usize {
    @setEvalBranchQuota(10_000);
    comptime var len: usize = 0;
    inline for (words) |word| {
        if (word.len > std.math.maxInt(u8)) @compileError("syntax word is too long");
        len += @sizeOf(u32) + 1 + word.len;
    }
    return len;
}

/// This is only a lookup filter. Callers compare exact bytes after a match.
pub fn packedWordHash(word: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (word) |byte| hash = (hash ^ std.ascii.toLower(byte)) *% 16777619;
    return hash;
}

fn packWords(comptime words: anytype) [packedWordsLen(words)]u8 {
    @setEvalBranchQuota(100_000);
    var result: [packedWordsLen(words)]u8 = undefined;
    comptime var offset: usize = 0;
    inline for (words) |word| {
        std.mem.writeInt(u32, result[offset..][0..@sizeOf(u32)], packedWordHash(word), .little);
        offset += @sizeOf(u32);
        result[offset] = word.len;
        offset += 1;
        @memcpy(result[offset..][0..word.len], word);
        offset += word.len;
    }
    return result;
}

const profiles = [_]Profile{
    .{
        .label = "zig",
        .aliases = &.{"zig"},
        .line_comments = &.{"//"},
        .quotes = double_quote,
        .keywords = &packWords(.{ "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "struct", "enum", "union", "try", "catch", "comptime", "defer", "errdefer", "async", "await", "anytype", "void" }),
    },
    .{
        .label = "ts",
        .aliases = &.{ "js", "jsx", "javascript", "ts", "tsx", "typescript" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = shell_quotes,
        .keywords = &packWords(.{ "const", "let", "var", "function", "class", "interface", "type", "export", "import", "from", "return", "if", "else", "for", "while", "async", "await", "new", "extends", "implements", "public", "private", "readonly" }),
        .literals = &packWords(.{ "true", "false", "null", "undefined" }),
        .detection = .typescript_assertion,
    },
    .{
        .label = "json",
        .aliases = &.{"json"},
        .quotes = double_quote,
        .literals = &packWords(.{ "true", "false", "null" }),
        .detection = .json,
    },
    .{
        .label = "sh",
        .aliases = &.{ "sh", "bash", "zsh", "shell", "shellscript" },
        .line_comments = &.{"#"},
        // Backticks are code, not strings, in shell.
        .quotes = double_single_quotes,
        .operators = "&|;<>*",
        .dollar_vars = true,
        .dash_flags = true,
        .command_words = true,
        .bare_numbers = false,
        .detection = .shell_shebang,
    },
    .{
        .label = "python",
        .aliases = &.{ "python", "py" },
        .line_comments = &.{"#"},
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "def", "class", "return", "if", "elif", "else", "for", "while", "in", "import", "from", "as", "try", "except", "with", "lambda", "async", "await", "pass", "raise", "yield", "match", "case" }),
        .literals = &packWords(.{ "True", "False", "None" }),
        .detection = .python_header,
    },
    .{
        .label = "yaml",
        .aliases = &.{ "yaml", "yml" },
        .line_comments = &.{"#"},
        .quotes = double_single_quotes,
        .literals = &packWords(.{ "true", "false", "null", "yes", "no", "on", "off" }),
    },
    .{
        .label = "toml",
        .aliases = &.{"toml"},
        .line_comments = &.{"#"},
        .quotes = double_single_quotes,
        .literals = &packWords(.{ "true", "false" }),
    },
    .{
        .label = "sql",
        .aliases = &.{"sql"},
        .line_comments = &.{"--"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "select", "from", "where", "join", "left", "right", "inner", "outer", "on", "insert", "into", "values", "update", "set", "delete", "create", "alter", "drop", "table", "index", "group", "by", "order", "having", "limit", "as", "and", "or", "not", "distinct", "union" }),
        .literals = &packWords(.{ "true", "false", "null" }),
        .keyword_case = .ascii_insensitive,
        .detection = .sql_select,
    },
    .{
        .label = "dockerfile",
        .aliases = &.{ "dockerfile", "docker" },
        .line_comments = &.{"#"},
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "from", "run", "cmd", "entrypoint", "copy", "add", "workdir", "env", "arg", "expose", "volume", "user", "label", "onbuild", "stopsignal", "healthcheck", "shell", "maintainer" }),
        .keyword_case = .ascii_insensitive,
        .detection = .dockerfile_from,
    },
    .{
        .label = "rust",
        .aliases = &.{ "rust", "rs" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "crate", "return", "if", "else", "match", "for", "while", "loop", "async", "await", "move", "where", "self", "super" }),
        .literals = &packWords(.{ "true", "false", "None", "Some" }),
        .detection = .rust_function,
    },
    .{
        .label = "go",
        .aliases = &.{"go"},
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = &[_]u8{ '"', '`' },
        .keywords = &packWords(.{ "package", "import", "func", "var", "const", "type", "struct", "interface", "return", "if", "else", "for", "range", "switch", "case", "go", "defer", "select", "chan", "map" }),
        .literals = &packWords(.{ "true", "false", "nil" }),
        .detection = .go_package,
    },
    .{
        .label = "c",
        .aliases = &.{ "c", "h", "m", "mm" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "int", "long", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while" }),
        .literals = &packWords(.{ "true", "false", "NULL" }),
    },
    .{
        .label = "cpp",
        .aliases = &.{ "cpp", "c++", "cc", "cxx", "hpp" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "auto", "bool", "class", "const", "constexpr", "decltype", "delete", "enum", "explicit", "friend", "inline", "namespace", "new", "nullptr", "private", "protected", "public", "template", "this", "typename", "using", "virtual", "void" }),
        .literals = &packWords(.{ "true", "false", "nullptr", "NULL" }),
    },
    .{
        .label = "csharp",
        .aliases = &.{ "csharp", "cs" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "class", "namespace", "using", "public", "private", "protected", "internal", "static", "void", "string", "int", "var", "new", "return", "if", "else", "for", "foreach", "while", "async", "await", "interface", "record", "get", "set" }),
        .literals = &packWords(.{ "true", "false", "null" }),
    },
    .{
        .label = "java",
        .aliases = &.{"java"},
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "class", "interface", "package", "import", "public", "private", "protected", "static", "final", "void", "new", "return", "if", "else", "for", "while", "try", "catch", "throws", "extends", "implements", "record", "var" }),
        .literals = &packWords(.{ "true", "false", "null" }),
    },
    .{
        .label = "kotlin",
        .aliases = &.{ "kotlin", "kt", "kts" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "fun", "val", "var", "class", "object", "interface", "package", "import", "public", "private", "return", "if", "else", "when", "for", "while", "try", "catch", "data", "sealed", "suspend" }),
        .literals = &packWords(.{ "true", "false", "null" }),
    },
    .{
        .label = "php",
        .aliases = &.{"php"},
        .line_comments = &.{ "//", "#" },
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "function", "class", "public", "private", "protected", "namespace", "use", "return", "if", "else", "foreach", "for", "while", "try", "catch", "new", "static", "const", "echo", "yield" }),
        .literals = &packWords(.{ "true", "false", "null" }),
    },
    .{
        .label = "ruby",
        .aliases = &.{ "ruby", "rb" },
        .line_comments = &.{"#"},
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "def", "class", "module", "end", "return", "if", "elsif", "else", "unless", "case", "when", "do", "while", "for", "in", "begin", "rescue", "require", "attr_reader" }),
        .literals = &packWords(.{ "true", "false", "nil" }),
    },
    .{
        .label = "swift",
        .aliases = &.{"swift"},
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "func", "let", "var", "class", "struct", "enum", "protocol", "extension", "import", "public", "private", "return", "if", "else", "guard", "for", "while", "switch", "case", "async", "await", "throws", "try" }),
        .literals = &packWords(.{ "true", "false", "nil" }),
    },
    .{
        .label = "powershell",
        .aliases = &.{ "powershell", "ps1", "pwsh", "ps" },
        .line_comments = &.{"#"},
        .block_comment = .{ .start = "<#", .end = "#>" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "function", "param", "if", "else", "elseif", "foreach", "for", "while", "switch", "return", "throw", "try", "catch", "finally", "begin", "process", "end", "filter", "class", "enum" }),
        .literals = &packWords(.{ "true", "false", "null" }),
        .keyword_case = .ascii_insensitive,
    },
    .{
        .label = "lua",
        .aliases = &.{"lua"},
        .line_comments = &.{"--"},
        .block_comment = .{ .start = "--[[", .end = "]]" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while" }),
        .literals = &packWords(.{ "true", "false", "nil" }),
    },
    .{
        .label = "html",
        .aliases = &.{ "html", "htm", "vue", "svelte" },
        .block_comment = .{ .start = "<!--", .end = "-->" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "html", "head", "body", "main", "header", "footer", "section", "article", "div", "span", "a", "p", "script", "style", "link", "meta", "title", "button", "input", "form", "img", "ul", "li" }),
    },
    .{
        .label = "xml",
        .aliases = &.{"xml"},
        .block_comment = .{ .start = "<!--", .end = "-->" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "xml", "version", "encoding", "DOCTYPE", "CDATA" }),
    },
    .{
        .label = "css",
        .aliases = &.{"css"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "color", "background", "display", "position", "margin", "padding", "border", "font", "width", "height", "flex", "grid", "align", "justify", "transition", "transform", "animation", "media" }),
    },
    .{
        .label = "hcl",
        .aliases = &.{ "hcl", "terraform", "tf" },
        .line_comments = &.{ "#", "//" },
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "resource", "module", "variable", "output", "provider", "terraform", "locals", "data", "dynamic", "for_each", "count" }),
        .literals = &packWords(.{ "true", "false", "null" }),
    },
    .{
        .label = "make",
        .aliases = &.{ "make", "makefile", "mk" },
        .line_comments = &.{"#"},
        .dollar_vars = true,
    },
    .{
        .label = "ini",
        .aliases = &.{ "ini", "conf", "cfg", "editorconfig" },
        .line_comments = &.{ "#", ";" },
    },
    .{
        .label = "dotenv",
        .aliases = &.{ "dotenv", "env" },
        .line_comments = &.{"#"},
    },
    .{
        .label = "graphql",
        .aliases = &.{ "graphql", "gql" },
        .line_comments = &.{"#"},
        .quotes = double_quote,
        .keywords = &packWords(.{ "query", "mutation", "subscription", "fragment", "on", "type", "input", "interface", "enum", "union", "scalar", "schema", "extend", "implements", "directive" }),
        .literals = &packWords(.{ "true", "false", "null" }),
    },
    .{
        .label = "dart",
        .aliases = &.{"dart"},
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "const", "final", "var", "class", "extends", "with", "implements", "mixin", "enum", "if", "else", "for", "while", "return", "async", "await", "new", "static", "import", "export", "void" }),
        .literals = &packWords(.{ "true", "false", "null" }),
    },
    .{
        .label = "scala",
        .aliases = &.{ "scala", "sc" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_quote,
        .keywords = &packWords(.{ "val", "var", "def", "class", "object", "trait", "extends", "with", "package", "import", "if", "else", "for", "while", "yield", "match", "case", "return", "new", "type", "given", "override" }),
        .literals = &packWords(.{ "true", "false", "null" }),
    },
    .{
        .label = "elixir",
        .aliases = &.{ "elixir", "ex", "exs" },
        .line_comments = &.{"#"},
        .quotes = double_quote,
        .keywords = &packWords(.{ "def", "defmodule", "defp", "defmacro", "defguard", "do", "end", "fn", "if", "else", "unless", "case", "cond", "when", "with", "for", "try", "rescue", "after", "alias", "import", "require", "use" }),
        .literals = &packWords(.{ "true", "false", "nil" }),
    },
    .{
        .label = "haskell",
        .aliases = &.{ "haskell", "hs" },
        .line_comments = &.{"--"},
        .block_comment = .{ .start = "{-", .end = "-}" },
        .quotes = double_quote,
        .keywords = &packWords(.{ "module", "where", "import", "data", "type", "newtype", "class", "instance", "deriving", "if", "then", "else", "case", "of", "do", "let", "in", "infix", "infixl", "infixr" }),
        .literals = &packWords(.{ "True", "False" }),
    },
    .{
        .label = "perl",
        .aliases = &.{ "perl", "pl", "pm" },
        .line_comments = &.{"#"},
        .quotes = shell_quotes,
        .dollar_vars = true,
        .keywords = &packWords(.{ "my", "our", "sub", "use", "package", "if", "else", "elsif", "unless", "while", "for", "foreach", "return", "local", "state", "say", "print", "die", "warn", "eval", "do", "require" }),
        .literals = &packWords(.{"undef"}),
    },
    .{
        .label = "r",
        .aliases = &.{"r"},
        .line_comments = &.{"#"},
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "function", "if", "else", "for", "while", "repeat", "break", "next", "return", "in", "library", "require" }),
        .literals = &packWords(.{ "TRUE", "FALSE", "NULL", "NA" }),
    },
    .{
        .label = "groovy",
        .aliases = &.{ "groovy", "gradle" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &packWords(.{ "def", "class", "interface", "enum", "if", "else", "for", "while", "return", "new", "try", "catch", "finally", "throw", "package", "import", "extends", "implements", "static", "final", "void" }),
        .literals = &packWords(.{ "true", "false", "null" }),
    },
    .{
        .label = "nginx",
        .aliases = &.{"nginx"},
        .line_comments = &.{"#"},
        .keywords = &packWords(.{ "server", "location", "listen", "root", "proxy_pass", "set", "return", "rewrite", "if", "error_page", "access_log", "include", "upstream", "worker_processes", "events", "http" }),
    },
    .{
        // Inline code spans color as strings; prose numbers stay plain.
        .label = "markdown",
        .aliases = &.{ "md", "markdown", "mdx" },
        .block_comment = .{ .start = "<!--", .end = "-->" },
        .quotes = &.{'`'},
        .bare_numbers = false,
    },
    .{
        // Explicit opt-out of highlighting; kept byte-identical.
        .label = "text",
        .aliases = &.{ "text", "txt", "plain", "plaintext" },
        .bare_numbers = false,
    },
    .{
        .label = "diff",
        .aliases = &.{ "diff", "patch" },
        .diff_lines = true,
        .detection = .diff_patch,
    },
};

pub fn resolve(label: []const u8) ?*const Profile {
    for (&profiles) |*profile| {
        for (profile.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(label, alias)) return profile;
        }
    }
    return null;
}

pub fn infer(alloc: Allocator, source: []const u8) ?*const Profile {
    for (&profiles) |*profile| {
        if (matchesDetection(alloc, profile.detection, source)) return profile;
    }
    return null;
}

fn matchesDetection(alloc: Allocator, detection: Detection, source: []const u8) bool {
    return switch (detection) {
        .none => false,
        .typescript_assertion => matchesTypeScriptAssertion(source),
        .json => isValidJson(alloc, source),
        .shell_shebang => matchesShellShebang(source),
        .python_header => matchesPythonHeader(source),
        .sql_select => matchesSqlSelect(source),
        .dockerfile_from => startsWithIgnoreCase(firstNonblankLine(source), "from "),
        .go_package => startsWith(firstNonblankLine(source), "package ") and containsLineStart(source, "func "),
        .rust_function => matchesRustFunction(source),
        .diff_patch => matchesDiffPatch(source),
    };
}

fn matchesDiffPatch(source: []const u8) bool {
    const line = firstNonblankLine(source);
    if (std.mem.startsWith(u8, line, "diff --git ") or std.mem.startsWith(u8, line, "@@ ")) return true;
    return std.mem.startsWith(u8, line, "--- ") and std.mem.find(u8, source, "\n+++ ") != null;
}

fn matchesTypeScriptAssertion(source: []const u8) bool {
    var start: usize = 0;
    while (std.mem.findPos(u8, source, start, "} as ")) |assertion_start| {
        const type_start = assertion_start + "} as ".len;
        if (type_start < source.len and std.ascii.isUpper(source[type_start])) return true;
        start = type_start;
    }
    return false;
}

fn isValidJson(alloc: Allocator, source: []const u8) bool {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0 or (trimmed[0] != '{' and trimmed[0] != '[')) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object or parsed.value == .array;
}

fn matchesShellShebang(source: []const u8) bool {
    const line = firstNonblankLine(source);
    return std.mem.startsWith(u8, line, "#!") and
        (std.mem.find(u8, line, "bash") != null or std.mem.find(u8, line, "zsh") != null or std.mem.find(u8, line, "/sh") != null);
}

fn matchesPythonHeader(source: []const u8) bool {
    const line = firstNonblankLine(source);
    return (std.mem.startsWith(u8, line, "def ") or std.mem.startsWith(u8, line, "class ")) and std.mem.endsWith(u8, line, ":");
}

fn matchesSqlSelect(source: []const u8) bool {
    const line = firstNonblankLine(source);
    return startsWithIgnoreCase(line, "select ") and containsWordIgnoreCase(source, "from");
}

fn matchesRustFunction(source: []const u8) bool {
    const line = firstNonblankLine(source);
    if (!std.mem.startsWith(u8, line, "fn ") and !std.mem.startsWith(u8, line, "pub fn ")) return false;
    return std.mem.find(u8, source, "let ") != null or std.mem.find(u8, source, "println!") != null or std.mem.find(u8, line, "->") != null;
}

fn firstNonblankLine(source: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

fn containsLineStart(source: []const u8, prefix: []const u8) bool {
    if (std.mem.startsWith(u8, source, prefix)) return true;
    var start: usize = 0;
    while (std.mem.findPos(u8, source, start, "\n")) |newline| {
        const line_start = newline + 1;
        if (std.mem.startsWith(u8, source[line_start..], prefix)) return true;
        start = line_start;
    }
    return false;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.mem.eql(u8, text[0..prefix.len], prefix);
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn containsWordIgnoreCase(source: []const u8, word: []const u8) bool {
    if (word.len > source.len) return false;
    var index: usize = 0;
    while (index + word.len <= source.len) : (index += 1) {
        const end = index + word.len;
        if (std.ascii.eqlIgnoreCase(source[index..end], word) and
            (index == 0 or !isWordByte(source[index - 1])) and
            (end == source.len or !isWordByte(source[end]))) return true;
    }
    return false;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

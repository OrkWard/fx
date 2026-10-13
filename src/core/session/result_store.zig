const std = @import("std");
const image_data = @import("../images/image_data.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const artifact_digest = @import("artifact_digest.zig");
const session_child_store = @import("session_child_store.zig");
const session_codec = @import("session_codec.zig");
const compactor = @import("../compactor/compactor.zig");

const Allocator = std.mem.Allocator;

pub const large_result_threshold_bytes: usize = 16 * 1024;
pub const preview_bytes: usize = 4 * 1024;
pub const read_default_bytes: usize = 8 * 1024;
pub const read_max_bytes: usize = 64 * 1024;
pub const full_read_chunk_bytes: usize = 64 * 1024;
pub const stored_text_max_bytes: usize = 8 * 1024 * 1024;

pub const PreparedResult = struct {
    model_output: []const u8,
    memory: types.ToolResultMemory,
};

const StorageTarget = union(enum) {
    legacy_dir: []const u8,
    managed: *session_child_store.SessionChildCapability,
};

/// Read-only, validated access to persisted tool-result text. The
/// caller chooses bounded raw pages and owns each returned allocation.
pub const ResultReader = struct {
    source: Source,
    size: usize,

    const Source = union(enum) {
        file: session_child_store.ManagedFile,
    };

    pub fn deinit(self: *ResultReader) void {
        switch (self.source) {
            .file => |*file| file.deinit(),
        }
        self.* = undefined;
    }

    pub fn readPage(
        self: *ResultReader,
        alloc: Allocator,
        offset: usize,
        max_bytes: usize,
    ) ![]u8 {
        if (offset >= self.size or max_bytes == 0) return alloc.dupe(u8, "");
        const len = @min(max_bytes, self.size - offset);
        return switch (self.source) {
            .file => |*file| file.readRange(alloc, offset, len),
        };
    }
};

pub fn prepare(
    alloc: Allocator,
    result_dir: ?[]const u8,
    tool_call_id: []const u8,
    tool_name: []const u8,
    output_bytes: usize,
    durable_output: []const u8,
    inline_cap: usize,
) !PreparedResult {
    if (result_dir) |dir| {
        if (output_bytes > large_result_threshold_bytes or
            durable_output.len > inline_cap)
        {
            return prepareStoredResult(
                alloc,
                .{ .legacy_dir = dir },
                tool_call_id,
                tool_name,
                output_bytes,
                durable_output,
            );
        }
        return prepareExternallyBackedInlineResult(
            alloc,
            .{ .legacy_dir = dir },
            tool_call_id,
            tool_name,
            output_bytes,
            durable_output,
        );
    }
    const capped = try cappedInlineOutput(alloc, tool_name, durable_output, inline_cap);
    return .{
        .model_output = capped,
        .memory = .{
            .output_bytes = output_bytes,
            .stored_output_bytes = durable_output.len,
            .truncated = capped.len < durable_output.len,
        },
    };
}

pub fn prepareManaged(
    alloc: Allocator,
    capability: ?*session_child_store.SessionChildCapability,
    tool_call_id: []const u8,
    tool_name: []const u8,
    output_bytes: usize,
    durable_output: []const u8,
    inline_cap: usize,
) !PreparedResult {
    if (capability) |managed| {
        if (output_bytes > large_result_threshold_bytes or
            durable_output.len > inline_cap)
        {
            return prepareStoredResult(
                alloc,
                .{ .managed = managed },
                tool_call_id,
                tool_name,
                output_bytes,
                durable_output,
            );
        }
        return prepareExternallyBackedInlineResult(
            alloc,
            .{ .managed = managed },
            tool_call_id,
            tool_name,
            output_bytes,
            durable_output,
        );
    }
    const capped = try cappedInlineOutput(alloc, tool_name, durable_output, inline_cap);
    return .{
        .model_output = capped,
        .memory = .{
            .output_bytes = output_bytes,
            .stored_output_bytes = durable_output.len,
            .truncated = capped.len < durable_output.len,
        },
    };
}

fn prepareExternallyBackedInlineResult(
    alloc: Allocator,
    target: StorageTarget,
    tool_call_id: []const u8,
    tool_name: []const u8,
    output_bytes: usize,
    durable_output: []const u8,
) !PreparedResult {
    const handle = try targetHandle(alloc, target, tool_call_id, tool_name, durable_output);
    errdefer alloc.free(handle);
    const model_output = try alloc.dupe(u8, durable_output);
    errdefer alloc.free(model_output);
    const preview = try previewText(alloc, durable_output, preview_bytes);
    errdefer alloc.free(preview);
    switch (target) {
        .legacy_dir => |dir| try storeLargeResultAtHandle(
            alloc,
            dir,
            handle,
            durable_output,
        ),
        .managed => |capability| try storeLargeResultAtHandleManaged(
            alloc,
            capability,
            handle,
            durable_output,
        ),
    }
    return .{
        .model_output = model_output,
        .memory = .{
            .output_handle = handle,
            .preview = preview,
            .output_bytes = output_bytes,
            .stored_output_bytes = durable_output.len,
            .truncated = false,
        },
    };
}

fn prepareStoredResult(
    alloc: Allocator,
    target: StorageTarget,
    tool_call_id: []const u8,
    tool_name: []const u8,
    output_bytes: usize,
    durable_output: []const u8,
) !PreparedResult {
    const handle = try targetHandle(alloc, target, tool_call_id, tool_name, durable_output);
    errdefer alloc.free(handle);
    const preview = try previewText(alloc, durable_output, preview_bytes);
    errdefer alloc.free(preview);
    const model_output = try formatStoredResultOutput(
        alloc,
        handle,
        preview,
        durable_output.len,
    );
    errdefer alloc.free(model_output);
    switch (target) {
        .legacy_dir => |dir| try storeLargeResultAtHandle(
            alloc,
            dir,
            handle,
            durable_output,
        ),
        .managed => |capability| try storeLargeResultAtHandleManaged(
            alloc,
            capability,
            handle,
            durable_output,
        ),
    }
    return .{
        .model_output = model_output,
        .memory = .{
            .output_handle = handle,
            .preview = preview,
            .output_bytes = output_bytes,
            .stored_output_bytes = durable_output.len,
            .truncated = true,
        },
    };
}

pub fn storeLargeResult(
    alloc: Allocator,
    result_dir: []const u8,
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
) ![]u8 {
    const handle = try makeHandle(alloc, tool_call_id, tool_name, text);
    errdefer alloc.free(handle);
    try storeLargeResultAtHandle(alloc, result_dir, handle, text);
    return handle;
}

fn storeLargeResultAtHandle(
    alloc: Allocator,
    result_dir: []const u8,
    handle: []const u8,
    text: []const u8,
) !void {
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();
    return storeLargeResultAtHandleManaged(
        alloc,
        &capability,
        handle,
        text,
    );
}

pub fn storeToolImages(alloc: Allocator, capability: *session_child_store.SessionChildCapability, call_id: []const u8, tool_name: []const u8, images: []const types.ToolImage) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try session_codec.writePersistedToolImages(&out.writer, images);
    if (out.written().len > image_data.max_result_frame_bytes) return error.ResultTooLarge;
    const base = try handleFor(alloc, capability, call_id, tool_name, out.written());
    defer alloc.free(base);
    const handle = try alloc.print("image-{s}", .{base});
    errdefer alloc.free(handle);
    try storeLargeResultAtHandleManaged(alloc, capability, handle, out.written());
    return handle;
}

pub fn isImageHandle(handle: []const u8) bool {
    return std.mem.startsWith(u8, handle, "image-result-");
}

pub fn loadToolImages(alloc: Allocator, capability: *session_child_store.SessionChildCapability, handle: []const u8) ![]types.ToolImage {
    if (!isImageHandle(handle)) return error.InvalidResultHandle;
    var reader = try openReaderManaged(alloc, capability, handle);
    defer reader.deinit();
    if (reader.size > image_data.max_result_frame_bytes) return error.ResultTooLarge;
    const bytes = try reader.readPage(alloc, 0, image_data.max_result_frame_bytes);
    defer alloc.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!handleMatchesContentDigest(handle, digest)) return error.ImageArtifactChanged;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidImageArtifact;
    const images = try session_codec.parsePersistedToolImages(alloc, parsed.value.array.items);
    errdefer types.freeToolImages(alloc, images);
    if (images.len != parsed.value.array.items.len) return error.InvalidImageArtifact;
    return images;
}

pub fn storeLargeResultManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
) ![]u8 {
    const handle = try handleFor(alloc, capability, tool_call_id, tool_name, text);
    errdefer alloc.free(handle);
    try storeLargeResultAtHandleManaged(alloc, capability, handle, text);
    return handle;
}

/// Bound on one serialized diff content pack (previous + after snapshots of
/// a committed file edit). Oversized packs stay inline and the enclosing
/// record's own size guard covers them.
pub const diff_content_max_bytes: usize = 2 * stored_text_max_bytes;

/// Restored previous/after contents of a committed file presentation.
/// The caller owns both slices; release with deinit.
pub const DiffContentPack = struct {
    previous_content: ?[]u8 = null,
    after_content: ?[]u8 = null,

    pub fn deinit(self: *DiffContentPack, alloc: Allocator) void {
        if (self.previous_content) |content| alloc.free(content);
        if (self.after_content) |content| alloc.free(content);
        self.* = undefined;
    }
};

const diff_content_handle_prefix = "diff-";
const diff_content_handle_suffix = ".json";
const diff_content_digest_hex_bytes = 16;
const diff_content_handle_bytes = diff_content_handle_prefix.len +
    diff_content_digest_hex_bytes + 1 + diff_content_digest_hex_bytes +
    diff_content_handle_suffix.len;

fn isLowerHex(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    return true;
}

pub fn isDiffContentHandle(handle: []const u8) bool {
    if (handle.len != diff_content_handle_bytes or
        !std.mem.startsWith(u8, handle, diff_content_handle_prefix) or
        !std.mem.endsWith(u8, handle, diff_content_handle_suffix))
    {
        return false;
    }
    const call_start = diff_content_handle_prefix.len;
    const call_end = call_start + diff_content_digest_hex_bytes;
    const content_start = call_end + 1;
    const content_end = content_start + diff_content_digest_hex_bytes;
    return handle[call_end] == '-' and
        isLowerHex(handle[call_start..call_end]) and
        isLowerHex(handle[content_start..content_end]);
}

pub fn diffContentHandleMatchesCall(
    handle: []const u8,
    tool_call_id: []const u8,
) bool {
    if (!isDiffContentHandle(handle)) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tool_call_id, &digest, .{});
    const expected = std.fmt.bytesToHex(digest[0..8].*, .lower);
    const start = diff_content_handle_prefix.len;
    return std.mem.eql(
        u8,
        handle[start .. start + diff_content_digest_hex_bytes],
        &expected,
    );
}

pub fn diffContentHandleMatchesContentDigest(
    handle: []const u8,
    digest: [32]u8,
) bool {
    return isDiffContentHandle(handle) and
        artifact_digest.handleMatchesContentDigest(
            handle,
            diff_content_handle_suffix,
            digest,
        );
}

/// Persists one edit's previous/after snapshots as a single content-addressed
/// artifact in the session result store and returns its handle. Keeping the
/// snapshots out of the event log and recovery checkpoint keeps those records
/// small; readers resolve the handle on demand.
pub fn storeDiffContent(
    alloc: Allocator,
    result_dir: []const u8,
    tool_call_id: []const u8,
    previous_content: ?[]const u8,
    after_content: ?[]const u8,
) ![]u8 {
    const pack = try encodeDiffContentPack(alloc, previous_content, after_content);
    defer alloc.free(pack);
    const handle = try makeDiffContentHandle(alloc, tool_call_id, pack);
    errdefer alloc.free(handle);
    try storeLargeResultAtHandle(alloc, result_dir, handle, pack);
    return handle;
}

/// Loads and digest-verifies a pack written by storeDiffContent.
pub fn loadDiffContentManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    tool_call_id: []const u8,
    handle: []const u8,
) !DiffContentPack {
    if (!diffContentHandleMatchesCall(handle, tool_call_id)) {
        return error.InvalidResultHandle;
    }
    var reader = try openReaderManaged(alloc, capability, handle);
    defer reader.deinit();
    if (reader.size > diff_content_max_bytes) return error.ResultTooLarge;
    const bytes = try reader.readPage(alloc, 0, diff_content_max_bytes);
    defer alloc.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!diffContentHandleMatchesContentDigest(handle, digest)) {
        return error.DiffContentArtifactChanged;
    }
    const Wire = struct {
        previous_content: ?[]const u8 = null,
        after_content: ?[]const u8 = null,
    };
    var parsed = std.json.parseFromSlice(Wire, alloc, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = diff_content_max_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidDiffContentArtifact,
    };
    defer parsed.deinit();
    var pack: DiffContentPack = .{};
    errdefer pack.deinit(alloc);
    if (parsed.value.previous_content) |content| {
        pack.previous_content = try alloc.dupe(u8, content);
    }
    if (parsed.value.after_content) |content| {
        pack.after_content = try alloc.dupe(u8, content);
    }
    return pack;
}

fn encodeDiffContentPack(
    alloc: Allocator,
    previous_content: ?[]const u8,
    after_content: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll("{\"previous_content\":") catch return error.OutOfMemory;
    writeOptionalPackString(&out.writer, previous_content) catch return error.OutOfMemory;
    out.writer.writeAll(",\"after_content\":") catch return error.OutOfMemory;
    writeOptionalPackString(&out.writer, after_content) catch return error.OutOfMemory;
    out.writer.writeByte('}') catch return error.OutOfMemory;
    if (out.written().len > diff_content_max_bytes) return error.DiffContentTooLarge;
    return try out.toOwnedSlice();
}

fn writeOptionalPackString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

fn makeDiffContentHandle(alloc: Allocator, tool_call_id: []const u8, pack: []const u8) ![]u8 {
    var content_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pack, &content_digest, .{});
    const content_hex = std.fmt.bytesToHex(content_digest[0..8].*, .lower);
    var call_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tool_call_id, &call_digest, .{});
    const call_hex = std.fmt.bytesToHex(call_digest[0..8].*, .lower);
    return alloc.print(
        "diff-{s}-{s}.json",
        .{ &call_hex, &content_hex },
    );
}

fn storeLargeResultAtHandleManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
    text: []const u8,
) !void {
    var entry = try capability.atomicReplace(
        alloc,
        .tool_results,
        handle,
        text,
    );
    entry.deinit(alloc);
}

pub fn formatStoredResultOutput(alloc: Allocator, handle: []const u8, preview: []const u8, stored_bytes: usize) ![]u8 {
    return alloc.print(
        "<tool_result_preview handle=\"{s}\" stored_bytes=\"{d}\">\n{s}\n</tool_result_preview>\n" ++
            "<tool_result_handle>{s}</tool_result_handle>\n" ++
            "Full result is stored outside session JSON. Use read_tool_result with this handle to inspect a byte range or literal query.",
        .{ handle, stored_bytes, preview, handle },
    );
}

pub fn readByRange(alloc: Allocator, result_dir: []const u8, handle: []const u8, start_byte: usize, byte_count: usize) ![]u8 {
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .read_only,
    );
    defer capability.deinit();
    return readByRangeManaged(
        alloc,
        &capability,
        handle,
        start_byte,
        byte_count,
    );
}

pub fn readByRangeManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
    start_byte: usize,
    byte_count: usize,
) ![]u8 {
    try validateHandle(handle);
    const text = try readStoredTextManaged(alloc, capability, handle);
    defer alloc.free(text);
    const start = if (start_byte == 0) 0 else @min(start_byte - 1, text.len);
    const requested = @min(if (byte_count == 0) read_default_bytes else byte_count, read_max_bytes);
    const end = @min(text.len, start + requested);
    const safe_start = text_utils.utf8ForwardBoundary(text, start);
    const safe_end = text_utils.utf8BackwardBoundary(text, end);
    return alloc.print(
        "<tool_result handle=\"{s}\" start_byte=\"{d}\" end_byte=\"{d}\" total_bytes=\"{d}\">\n{s}\n</tool_result>",
        .{ handle, safe_start + 1, safe_end, text.len, text[safe_start..safe_end] },
    );
}

pub fn readForReplayManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
    expected_bytes: usize,
) ![]u8 {
    if (expected_bytes > stored_text_max_bytes) return error.ResultSizeUnsupported;
    const stat = try statManaged(capability, handle);
    if (stat.size != expected_bytes) return error.ResultSizeMismatch;
    const text = try readStoredTextManaged(alloc, capability, handle);
    if (text.len != expected_bytes) {
        alloc.free(text);
        return error.ResultSizeMismatch;
    }
    return text;
}

pub fn searchByQuery(alloc: Allocator, result_dir: []const u8, handle: []const u8, query: []const u8) ![]u8 {
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .read_only,
    );
    defer capability.deinit();
    return searchByQueryManaged(alloc, &capability, handle, query);
}

pub fn searchByQueryManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
    query: []const u8,
) ![]u8 {
    try validateHandle(handle);
    const trimmed_query = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed_query.len == 0) return error.InvalidQuery;
    const text = try readStoredTextManaged(alloc, capability, handle);
    defer alloc.free(text);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("<tool_result_query handle=\"{s}\">\nquery: ", .{handle});
    try std.json.Stringify.value(trimmed_query, .{}, &out.writer);
    try out.writer.writeAll("\n");

    var matches: usize = 0;
    var line_number: usize = 1;
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line| : (line_number += 1) {
        if (std.mem.find(u8, line, trimmed_query) == null) continue;
        try out.writer.print("{d}|{s}\n", .{ line_number, line });
        matches += 1;
        if (matches >= 50 or out.written().len >= read_max_bytes) break;
    }

    if (matches == 0) try out.writer.writeAll("(no matches)\n");
    try out.writer.writeAll("</tool_result_query>");
    return try out.toOwnedSlice();
}

/// A stored file's size.
fn statManaged(
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
) !session_child_store.ManagedStat {
    try validateHandle(handle);
    return capability.stat(.tool_results, handle) catch |err| switch (err) {
        error.FileNotFound => error.ResultHandleNotFound,
        else => err,
    };
}

/// Opens a persisted tool result for bounded read-only pages. This never
/// materializes the full sidecar in memory.
pub fn openReaderManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
) !ResultReader {
    try validateHandle(handle);
    var file = capability.openFileReadOnly(alloc, .tool_results, handle) catch |err| switch (err) {
        error.FileNotFound => return error.ResultHandleNotFound,
        else => return err,
    };
    errdefer file.deinit();
    const stat = try file.stat();
    const size = std.math.cast(usize, stat.size) orelse {
        return error.ResultTooLarge;
    };
    return .{ .source = .{ .file = file }, .size = size };
}

fn cappedInlineOutput(alloc: Allocator, tool_name: []const u8, text: []const u8, max_bytes: usize) ![]u8 {
    const marker = try alloc.print(
        "\n... [tool result truncated for {s}: original {d} bytes; cap is {d} bytes]\n",
        .{ tool_name, text.len, max_bytes },
    );
    defer alloc.free(marker);
    if (text.len <= max_bytes) return try alloc.dupe(u8, text);
    const prefix_cap = if (max_bytes > marker.len) max_bytes - marker.len else 0;
    const prefix_len = text_utils.utf8BackwardBoundary(text, prefix_cap);
    if (prefix_len == 0) return try alloc.dupe(u8, marker);
    return try std.mem.concat(alloc, u8, &.{ text[0..prefix_len], marker });
}

pub fn previewText(alloc: Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    return try alloc.dupe(u8, text_utils.utf8PrefixByBytes(text, max_bytes));
}

/// The handle `storeLargeResultManaged` gives `text`: the name holds the call
/// and a hash of the content, so the same bytes always get the same name.
pub fn makeHandle(alloc: Allocator, tool_call_id: []const u8, tool_name: []const u8, text: []const u8) ![]u8 {
    var content_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &content_digest, .{});
    const content_hex = std.fmt.bytesToHex(content_digest[0..8].*, .lower);
    var call_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tool_call_id, &call_digest, .{});
    const call_hex = std.fmt.bytesToHex(call_digest[0..8].*, .lower);
    const safe_tool = try safeHandlePart(alloc, tool_name);
    defer alloc.free(safe_tool);
    return alloc.print(
        "result-{s}-{s}-{s}.txt",
        .{ safe_tool, &call_hex, &content_hex },
    );
}

/// The handle a store through `capability` gives `text`.
pub fn handleFor(
    alloc: Allocator,
    capability: *const session_child_store.SessionChildCapability,
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
) ![]u8 {
    _ = capability;
    return makeHandle(alloc, tool_call_id, tool_name, text);
}

fn targetHandle(
    alloc: Allocator,
    target: StorageTarget,
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
) ![]u8 {
    return switch (target) {
        .legacy_dir => makeHandle(alloc, tool_call_id, tool_name, text),
        .managed => |capability| handleFor(alloc, capability, tool_call_id, tool_name, text),
    };
}

pub fn isStoredTextHandle(handle: []const u8) bool {
    return std.mem.startsWith(u8, handle, "result-") and
        std.mem.endsWith(u8, handle, ".txt");
}

pub fn handleMatchesContentDigest(
    handle: []const u8,
    digest: [32]u8,
) bool {
    return artifact_digest.handleMatchesContentDigest(
        handle,
        ".txt",
        digest,
    );
}

fn safeHandlePart(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var wrote = false;
    for (text) |byte| {
        if (out.written().len >= 48) break;
        const safe = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
        try out.writer.writeByte(if (safe) byte else '-');
        wrote = true;
    }
    if (!wrote) try out.writer.writeAll("call");
    return try out.toOwnedSlice();
}

fn readStoredTextManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
) ![]u8 {
    var file = capability.openFileReadOnly(
        alloc,
        .tool_results,
        handle,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.ResultHandleNotFound,
        else => return err,
    };
    defer file.deinit();
    return file.readToEnd(alloc, stored_text_max_bytes);
}

/// This session's tool-results folder as fx-compactor's record store. The
/// store borrows `capability`.
pub fn compactorStore(capability: *session_child_store.SessionChildCapability) compactor.Store {
    return .{ .context = capability, .vtable = &.{
        .write = writeCompactorFile,
        .list = listCompactorFiles,
        .read = readCompactorFile,
    } };
}

fn writeCompactorFile(context: *anyopaque, alloc: Allocator, name: []const u8, content: []const u8) compactor.Store.Error!void {
    const capability: *session_child_store.SessionChildCapability = @ptrCast(@alignCast(context));
    var entry = capability.atomicReplace(alloc, .tool_results, name, content) catch |err| return compactorStoreError("write", name, err);
    entry.deinit(alloc);
}

fn listCompactorFiles(context: *anyopaque, arena: Allocator) compactor.Store.Error![]const []const u8 {
    const capability: *session_child_store.SessionChildCapability = @ptrCast(@alignCast(context));
    const entries = capability.iterate(arena, .tool_results) catch |err| return compactorStoreError("list", "", err);
    return entries.names;
}

fn readCompactorFile(context: *anyopaque, arena: Allocator, name: []const u8, max_bytes: usize) compactor.Store.Error![]const u8 {
    const capability: *session_child_store.SessionChildCapability = @ptrCast(@alignCast(context));
    var file = capability.openFileReadOnly(arena, .tool_results, name) catch |err| return compactorStoreError("open", name, err);
    defer file.deinit();
    const size = (file.stat() catch |err| return compactorStoreError("stat", name, err)).size;
    return file.readRange(arena, 0, @intCast(@min(size, max_bytes))) catch |err| compactorStoreError("read", name, err);
}

fn compactorStoreError(operation: []const u8, name: []const u8, err: anyerror) compactor.Store.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.FileNotFound,
        else => {
            compactor.traceLog(true, "record store {s} failed name={s} err={s}", .{ operation, name, @errorName(err) });
            return error.StoreFailed;
        },
    };
}

fn validateHandle(handle: []const u8) !void {
    if (isImageHandle(handle)) return validateHandle(handle[6..]);
    if (handle.len == 0 or handle.len > 160) return error.InvalidHandle;
    if (std.mem.find(u8, handle, "..") != null) return error.InvalidHandle;
    for (handle) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.';
        if (!ok) return error.InvalidHandle;
    }
}

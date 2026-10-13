const std = @import("std");
const file_picker_path = @import("../input/file_picker_path.zig");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const display_width = @import("../shared/display_width.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const image_data = @import("image_data.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const pathing = @import("../workspace/pathing.zig");

pub const max_image_bytes: usize = 20 * 1024 * 1024;
pub const image_too_large_notice = "image exceeds the 20 MiB limit";
pub const image_preparation_failed_notice = "Unable to prepare this image for upload. Use a smaller image.";
pub const model_image_capability_unavailable_notice = "Unable to verify image support for this model, so the image was not sent. Try again later, choose another model, or remove the image.";
const Sha256 = std.crypto.hash.sha2.Sha256;
const snapshot_digest_hex_len = Sha256.digest_length * 2;
const transfer_buffer_bytes = 64 * 1024;

pub fn findById(
    attachments: []const types.ImageAttachment,
    id: usize,
) ?types.ImageAttachment {
    for (attachments) |attachment| {
        if (attachment.id == id) return attachment;
    }
    return null;
}

pub fn projectOffsetThroughPlaceholderRewrite(
    source_tokens: []const entity_spans.ImageTokenSpan,
    target_tokens: []const entity_spans.ImageTokenSpan,
    source_len: usize,
    raw_offset: usize,
) ?usize {
    if (source_tokens.len != target_tokens.len or raw_offset > source_len) return null;

    var source_cursor: usize = 0;
    var target_cursor: usize = 0;
    for (source_tokens, target_tokens) |source, target| {
        if (!source.span.isValid(source_len) or
            source.span.raw_start < source_cursor or
            target.span.raw_start < target_cursor or
            target.span.raw_start >= target.span.raw_end)
        {
            return null;
        }
        if (raw_offset <= source.span.raw_start) {
            return std.math.add(
                usize,
                target_cursor,
                raw_offset - source_cursor,
            ) catch null;
        }
        if (raw_offset < source.span.raw_end) return null;

        target_cursor = std.math.add(
            usize,
            target_cursor,
            source.span.raw_start - source_cursor,
        ) catch return null;
        target_cursor = std.math.add(
            usize,
            target_cursor,
            target.span.raw_end - target.span.raw_start,
        ) catch return null;
        source_cursor = source.span.raw_end;
    }
    return std.math.add(
        usize,
        target_cursor,
        raw_offset - source_cursor,
    ) catch null;
}

/// The source covers consumed path syntax, not its outside punctuation. Both
/// ranges are byte offsets; later placeholder-ID changes never mutate this map.
pub const InlineImageEdit = struct {
    source: entity_spans.Span,
    output: entity_spans.Span,
    id: usize,
};

pub const ExtractedInlineImages = struct {
    text: []u8,
    images: []types.ImageAttachment,
    edits: []InlineImageEdit,

    pub fn deinit(self: ExtractedInlineImages, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        types.freeImageAttachmentSlice(alloc, self.images);
        alloc.free(self.edits);
    }

    pub fn discard(self: ExtractedInlineImages, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        discardImageAttachmentSlice(alloc, self.images);
        alloc.free(self.edits);
    }
};

const InlineImageReplacement = struct {
    source: entity_spans.Span,
    id: usize,
};

/// Pure byte transformation. The caller owns both returned allocations.
fn rewrite_inline_images(alloc: std.mem.Allocator, source: []const u8, replacements: []const InlineImageReplacement) !struct { text: []u8, edits: []InlineImageEdit } {
    const edits = try alloc.alloc(InlineImageEdit, replacements.len);
    errdefer alloc.free(edits);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var cursor: usize = 0;
    for (replacements, edits) |replacement, *edit| {
        if (!replacement.source.isValid(source.len) or replacement.source.raw_start < cursor or replacement.id == 0) return error.InvalidImageOccurrence;
        try out.appendSlice(alloc, source[cursor..replacement.source.raw_start]);
        const start = out.items.len;
        var buffer: [64]u8 = undefined;
        try out.appendSlice(alloc, try formatImagePlaceholder(&buffer, replacement.id));
        edit.* = .{
            .source = replacement.source,
            .output = .{ .raw_start = start, .raw_end = out.items.len },
            .id = replacement.id,
        };
        cursor = replacement.source.raw_end;
    }
    try out.appendSlice(alloc, source[cursor..]);
    return .{ .text = try out.toOwnedSlice(alloc), .edits = edits };
}

/// Projects an existing entity through admitted edits. Consumed entities do not
/// survive. Edits borrow immutable source/output coordinates from extraction.
pub fn project_inline_image_span(source_len: usize, span: entity_spans.Span, edits: []const InlineImageEdit) ?entity_spans.Span {
    if (!span.isValid(source_len)) return null;
    var source_cursor: usize = 0;
    var output_cursor: usize = 0;
    for (edits) |edit| {
        if (!edit.source.isValid(source_len) or edit.source.raw_start < source_cursor or edit.output.raw_end <= edit.output.raw_start or edit.id == 0) return null;
        const start = std.math.add(usize, output_cursor, edit.source.raw_start - source_cursor) catch return null;
        if (edit.output.raw_start != start) return null;
        source_cursor = edit.source.raw_end;
        output_cursor = edit.output.raw_end;
    }
    _ = std.math.add(usize, output_cursor, source_len - source_cursor) catch return null;
    var projected = span;
    var index = edits.len;
    while (index > 0) {
        index -= 1;
        const edit = edits[index];
        projected = entity_spans.afterDelete(projected, edit.source.raw_start, edit.source.raw_end) orelse return null;
        projected = entity_spans.afterInsert(projected, edit.source.raw_start, edit.output.raw_end - edit.output.raw_start) orelse return null;
    }
    return projected;
}

pub fn loadImageAttachment(alloc: std.mem.Allocator, path_input: []const u8) !types.ImageAttachment {
    const normalized_path = try normalizePathInput(alloc, path_input);
    defer alloc.free(normalized_path);

    const resolved_path = try io_mod.realpathAlloc(alloc, normalized_path);
    return loadResolvedImageAttachment(alloc, resolved_path);
}

pub fn loadUserImageAttachment(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    path_input: []const u8,
) !types.ImageAttachment {
    const normalized_path = try normalizePathInput(alloc, path_input);
    defer alloc.free(normalized_path);
    // Preserve the raw entry's second trim at the old path-resolution boundary.
    return load_user_image_literal(alloc, workspace_root, std.mem.trim(u8, normalized_path, " \t\r\n"));
}

/// Reads a decoded path without changing filename bytes. Caller owns the result.
fn load_user_image_literal(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    path: []const u8,
) !types.ImageAttachment {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const resolved_path = try pathing.resolve_workspace_or_external_literal_path(
        scratch_state.allocator(),
        workspace_root,
        path,
    );
    const owned_path = try alloc.dupe(u8, resolved_path);
    return loadResolvedImageAttachment(alloc, owned_path);
}

fn loadResolvedImageAttachment(
    alloc: std.mem.Allocator,
    resolved_path: []u8,
) !types.ImageAttachment {
    errdefer alloc.free(resolved_path);

    var header: [64]u8 = undefined;
    const bytes = try readImageHeaderBytes(resolved_path, &header);

    const media_type = try alloc.dupe(u8, detectMediaTypeFromBytes(bytes) orelse return error.UnsupportedImageType);
    errdefer alloc.free(media_type);

    return .{
        .path = resolved_path,
        .media_type = media_type,
    };
}

pub fn createTempSnapshotDir(alloc: std.mem.Allocator) ![]u8 {
    const temp_root = try io_mod.realpathAlloc(alloc, "/tmp");
    defer alloc.free(temp_root);
    for (0..16) |_| {
        var suffix: u64 = undefined;
        io_mod.getIo().random(std.mem.asBytes(&suffix));
        const path = try alloc.print(
            "{s}/fx-image-snapshots-{x}",
            .{ temp_root, suffix },
        );
        errdefer alloc.free(path);
        std.Io.Dir.createDirAbsolute(
            io_mod.getIo(),
            path,
            std.Io.File.Permissions.fromMode(0o700),
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {
                alloc.free(path);
                continue;
            },
            else => return err,
        };
        return path;
    }
    return error.PathAlreadyExists;
}

pub fn cleanupSnapshotDir(path: []const u8) void {
    if (path.len == 0) return;
    const parent_path = std.Io.Dir.path.dirname(path) orelse return;
    const name = std.Io.Dir.path.basename(path);
    var parent = openDirectoryNoFollow(parent_path) catch |err| {
        debug_trace.logf(
            "images",
            "event=snapshot_directory_cleanup_failed err={s}",
            .{@errorName(err)},
        );
        return;
    };
    defer parent.close(io_mod.getIo());
    parent.deleteTree(io_mod.getIo(), name) catch |err| {
        debug_trace.logf(
            "images",
            "event=snapshot_directory_cleanup_failed err={s}",
            .{@errorName(err)},
        );
    };
}

pub const CaptureBudget = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    deadline: ?std.Io.Clock.Timestamp = null,
    test_hook: if (builtin.is_test) ?TestBudgetHook else void = if (builtin.is_test) null else {},

    pub fn check(self: CaptureBudget) !void {
        if (comptime builtin.is_test) {
            if (self.test_hook) |hook| try hook.check(hook.ctx);
        }
        if (self.cancel_flag) |flag| {
            if (flag.load(.seq_cst)) return error.Cancelled;
        }
        if (self.deadline) |deadline| {
            const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
            if (now.raw.nanoseconds >= deadline.raw.nanoseconds) return error.TimedOut;
        }
    }
};

pub const CaptureAdmissionResult = enum {
    captured,
    rejected,
};

fn captureRejectionNotice(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ImageTooLarge => image_too_large_notice,
        error.ImagePreparationFailed => image_preparation_failed_notice,
        else => null,
    };
}

pub fn captureImageAttachmentForAdmission(
    comptime App: type,
    app: *App,
    attachment: *types.ImageAttachment,
) !CaptureAdmissionResult {
    App.captureImageAttachment(app, attachment) catch |err| {
        const notice = captureRejectionNotice(err) orelse return err;
        if (comptime !@hasDecl(App, "writeDomainNotice")) return err;
        try app.writeDomainNotice(.{
            .topic = "images",
            .tone = .@"error",
            .body = notice,
        }, true);
        return .rejected;
    };
    return .captured;
}

pub fn captureImageAttachmentsForAdmission(
    comptime App: type,
    app: *App,
    attachments: []types.ImageAttachment,
) !CaptureAdmissionResult {
    var captured: usize = 0;
    errdefer {
        discardImageSnapshots(app.alloc, attachments[0..captured]);
    }
    for (attachments) |*attachment| {
        switch (try captureImageAttachmentForAdmission(App, app, attachment)) {
            .captured => captured += 1,
            .rejected => {
                discardImageSnapshots(app.alloc, attachments[0..captured]);
                captured = 0;
                return .rejected;
            },
        }
    }
    return .captured;
}

const TestBudgetHook = struct {
    ctx: *anyopaque,
    check: *const fn (*anyopaque) anyerror!void,
};

pub fn captureImageSnapshot(
    alloc: std.mem.Allocator,
    attachment: *types.ImageAttachment,
    snapshot_dir: []const u8,
) !void {
    return captureImageSnapshotWithBudget(alloc, attachment, snapshot_dir, .{});
}

pub fn captureImageSnapshotWithBudget(
    alloc: std.mem.Allocator,
    attachment: *types.ImageAttachment,
    snapshot_dir: []const u8,
    budget: CaptureBudget,
) !void {
    if (attachment.id == 0) return error.InvalidImageId;
    try budget.check();

    var source = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), attachment.path, .{});
    defer source.close(io_mod.getIo());
    const source_stat = try source.stat(io_mod.getIo());
    return captureImageSnapshotFromOpenFileWithBudget(
        alloc,
        attachment,
        snapshot_dir,
        budget,
        &source,
        source_stat,
    );
}

pub const VisionRegularFile = struct {
    file: std.Io.File,
    identity: file_mutation_contract.FileIdentity,

    pub fn close(self: *VisionRegularFile) void {
        self.file.close(io_mod.getIo());
        self.* = undefined;
    }
};

/// Opens a read-only Vision source without following the final symlink or
/// blocking on a special file. Hard-linked regular files remain valid inputs.
/// The caller owns the returned descriptor and must close it.
pub fn openVisionRegularFile(canonical_path: []const u8) !VisionRegularFile {
    if (!std.Io.Dir.path.isAbsolute(canonical_path)) return error.InvalidPath;

    const cwd = std.Io.Dir.cwd();
    const initial = cwd.statFile(io_mod.getIo(), canonical_path, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.NotDir, error.SymLinkLoop => return error.NotRegularFile,
        else => return err,
    };
    if (initial.kind != .file) return error.NotRegularFile;

    if (comptime builtin.target.os.tag == .windows) {
        var file = cwd.openFile(io_mod.getIo(), canonical_path, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.IsDir, error.SymLinkLoop, error.NotDir => return error.NotRegularFile,
            else => return err,
        };
        errdefer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        if (stat.kind != .file) return error.NotRegularFile;
        return .{
            .file = file,
            .identity = pathing.fileIdentity(
                try pathing.descriptorDevice(file.handle),
                stat,
            ),
        };
    }

    var flags: std.posix.O = .{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true,
        .NONBLOCK = true,
    };
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;

    const fd = std.posix.openat(cwd.handle, canonical_path, flags, 0) catch |err| switch (err) {
        error.NoDevice, error.SymLinkLoop, error.NotDir => return error.NotRegularFile,
        else => return err,
    };
    var file = std.Io.File{
        .handle = fd,
        .flags = .{ .nonblocking = true },
    };
    errdefer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file) return error.NotRegularFile;
    const identity = pathing.fileIdentity(
        try pathing.descriptorDevice(file.handle),
        stat,
    );
    try makeVisionRegularFileBlocking(&file);
    return .{ .file = file, .identity = identity };
}

fn makeVisionRegularFileBlocking(file: *std.Io.File) !void {
    const current = while (true) {
        const rc = std.posix.system.fcntl(
            file.handle,
            std.posix.F.GETFL,
            @as(usize, 0),
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => break @as(usize, @intCast(rc)),
            .INTR => continue,
            else => return error.FileControlFailed,
        }
    };
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    while (true) {
        const rc = std.posix.system.fcntl(
            file.handle,
            std.posix.F.SETFL,
            current & ~nonblock,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.FileControlFailed,
        }
    }
    file.flags.nonblocking = false;
}

pub fn captureBoundImageAttachment(
    alloc: std.mem.Allocator,
    canonical_path: []const u8,
    expected_identity: file_mutation_contract.FileIdentity,
    image_id: usize,
    snapshot_dir: []const u8,
    budget: CaptureBudget,
) !types.ImageAttachment {
    if (!std.Io.Dir.path.isAbsolute(canonical_path)) return error.InvalidPath;
    if (image_id == 0) return error.InvalidImageId;
    try budget.check();

    var source = openVisionRegularFile(canonical_path) catch |err| switch (err) {
        error.NotRegularFile => return error.ImageTargetChanged,
        else => return err,
    };
    defer source.close();
    if (!std.meta.eql(source.identity, expected_identity)) {
        return error.ImageTargetChanged;
    }
    const source_stat = try source.file.stat(io_mod.getIo());

    var attachment: types.ImageAttachment = blk: {
        const owned_path = try alloc.dupe(u8, canonical_path);
        errdefer alloc.free(owned_path);
        break :blk .{
            .id = image_id,
            .path = owned_path,
            .media_type = try alloc.dupe(u8, ""),
        };
    };
    errdefer discardImageAttachment(alloc, attachment);
    try captureImageSnapshotFromOpenFileWithBudget(
        alloc,
        &attachment,
        snapshot_dir,
        budget,
        &source.file,
        source_stat,
    );
    return attachment;
}

fn captureImageSnapshotFromOpenFileWithBudget(
    alloc: std.mem.Allocator,
    attachment: *types.ImageAttachment,
    snapshot_dir: []const u8,
    budget: CaptureBudget,
    source: *std.Io.File,
    source_stat: std.Io.File.Stat,
) !void {
    if (source_stat.kind != .file) return error.NotRegularFile;
    if (source_stat.size > max_image_bytes) return error.ImageTooLarge;

    var snapshot_dir_handle = try openOrCreateSnapshotDirectoryNoFollow(snapshot_dir);
    defer snapshot_dir_handle.close(io_mod.getIo());

    const source_temp_name = try alloc.print(
        "image-{d}.source.{d}",
        .{ attachment.id, io_mod.nanoTimestamp() },
    );
    defer alloc.free(source_temp_name);
    var cleanup_source_temp = true;
    defer if (cleanup_source_temp) {
        deleteSnapshotFile(snapshot_dir_handle, source_temp_name, "capture_source_temp");
    };

    const source_metadata = try streamSourceToFile(
        source,
        snapshot_dir_handle,
        source_temp_name,
        max_image_bytes,
        budget,
    );
    try budget.check();

    const metadata = source_metadata;

    const media_type = try alloc.dupe(u8, metadata.media_type);
    errdefer alloc.free(media_type);

    const final_name = try alloc.print(
        "image-{d}-{s}.bin",
        .{ attachment.id, metadata.digest_hex[0..16] },
    );
    defer alloc.free(final_name);
    const final_path = try std.Io.Dir.path.join(alloc, &.{ snapshot_dir, final_name });
    errdefer alloc.free(final_path);
    try budget.check();
    try snapshot_dir_handle.rename(source_temp_name, snapshot_dir_handle, final_name, io_mod.getIo());
    cleanup_source_temp = false;
    var cleanup_final = true;
    errdefer if (cleanup_final) {
        deleteSnapshotFile(snapshot_dir_handle, final_name, "capture_final");
    };

    try syncSnapshotDirectory(snapshot_dir_handle);
    try budget.check();
    const digest_hex = try alloc.dupe(u8, &metadata.digest_hex);
    errdefer alloc.free(digest_hex);

    const old_snapshot_path = attachment.snapshot_path;
    const old_snapshot_sha256 = attachment.snapshot_sha256;
    const old_media_type = attachment.media_type;
    attachment.media_type = media_type;
    attachment.snapshot_path = final_path;
    attachment.snapshot_sha256 = digest_hex;
    cleanup_final = false;

    alloc.free(old_media_type);
    if (old_snapshot_path) |old| {
        if (!std.mem.eql(u8, old, final_path)) deleteSnapshotPath(old, "replaced_snapshot");
        alloc.free(old);
    }
    if (old_snapshot_sha256) |old| alloc.free(old);
}

fn streamSourceToFile(
    source: *std.Io.File,
    destination_dir: std.Io.Dir,
    destination_name: []const u8,
    limit: usize,
    budget: CaptureBudget,
) !SnapshotMetadata {
    var destination = try destination_dir.createFile(
        io_mod.getIo(),
        destination_name,
        .{
            .truncate = false,
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
            .resolve_beneath = true,
        },
    );
    defer destination.close(io_mod.getIo());

    var hasher = Sha256.init(.{});
    var header: [64]u8 = undefined;
    var header_len: usize = 0;
    var read_buffer: [8192]u8 = undefined;
    var reader = source.readerStreaming(io_mod.getIo(), &read_buffer);
    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    var written: usize = 0;
    while (true) {
        try budget.check();
        const n = try reader.interface.readSliceShort(&transfer_buffer);
        if (n == 0) break;
        if (n > limit - written) return error.ImageTooLarge;
        const header_bytes = @min(n, header.len - header_len);
        @memcpy(header[header_len..][0..header_bytes], transfer_buffer[0..header_bytes]);
        header_len += header_bytes;
        hasher.update(transfer_buffer[0..n]);
        try destination.writeStreamingAll(io_mod.getIo(), transfer_buffer[0..n]);
        written += n;
    }
    try budget.check();
    try destination.sync(io_mod.getIo());

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const media_type = detectMediaTypeFromBytes(header[0..header_len]) orelse
        return error.UnsupportedImageType;
    return .{
        .digest_hex = std.fmt.bytesToHex(digest, .lower),
        .media_type = media_type,
        .size_bytes = written,
    };
}

const SnapshotMetadata = struct {
    digest_hex: [snapshot_digest_hex_len]u8,
    media_type: []const u8,
    size_bytes: usize,
};

/// Reads a snapshot file on demand for pixel-size checks, so a JPEG frame
/// header behind large metadata is found without reading the whole file.
const SnapshotFileReader = struct {
    file: std.Io.File,

    fn readAt(context: *const anyopaque, offset: u64, buffer: []u8) []const u8 {
        const self: *const SnapshotFileReader = @ptrCast(@alignCast(context));
        const len = self.file.readPositionalAll(io_mod.getIo(), buffer, offset) catch return buffer[0..0];
        return buffer[0..len];
    }

    fn dimensions(self: *const SnapshotFileReader) ?image_data.Dimensions {
        return image_data.positionalImageDimensions(.{ .context = self, .read_at = readAt });
    }
};

/// Reports whether a snapshot file is wider or taller than the model pixel
/// limit. Unreadable dimensions report false and keep the byte-limit path.
/// Cached header dimensions of immutable snapshots, keyed by snapshot digest.
/// File size is checked again on each request. Keys are owned by the allocator
/// passed alongside the cache.
pub const AttachmentDimensionCache = std.StringHashMapUnmanaged(?image_data.Dimensions);

/// Pixel size of an attachment, or null when it cannot be read. Unreadable
/// snapshots are reported where the request loads them.
fn attachmentDimensions(
    cache_alloc: std.mem.Allocator,
    cache: *AttachmentDimensionCache,
    attachment: types.ImageAttachment,
) std.mem.Allocator.Error!?image_data.Dimensions {
    if (attachment.inline_data) |bytes| return image_data.imageDimensions(bytes);
    const path = attachment.snapshot_path orelse return null;
    const digest = attachment.snapshot_sha256 orelse return probeSnapshotDimensions(path);
    if (cache.get(digest)) |cached| return cached;
    const dimensions = probeSnapshotDimensions(path);
    const key = try cache_alloc.dupe(u8, digest);
    errdefer cache_alloc.free(key);
    try cache.put(cache_alloc, key, dimensions);
    return dimensions;
}

fn probeSnapshotDimensions(path: []const u8) ?image_data.Dimensions {
    var file = openSnapshotFileNoFollow(path) catch return null;
    defer file.close(io_mod.getIo());
    const reader: SnapshotFileReader = .{ .file = file };
    return reader.dimensions();
}

fn attachmentRawBytes(attachment: types.ImageAttachment) ?usize {
    if (attachment.inline_data) |bytes| return bytes.len;
    const path = attachment.snapshot_path orelse return null;
    var file = openSnapshotFileNoFollow(path) catch return null;
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch return null;
    if (stat.kind != .file or stat.nlink != 1) return null;
    return std.math.cast(usize, stat.size);
}

fn attachmentFitsEncodedLimit(attachment: types.ImageAttachment) bool {
    const size = attachmentRawBytes(attachment) orelse return false;
    return image_data.fitsEncodedImageLimit(size);
}

/// Base64 bytes the attachment adds to a request, or null when its size
/// cannot be read.
pub fn attachmentEncodedBytes(attachment: types.ImageAttachment) ?usize {
    const size = attachmentRawBytes(attachment) orelse return null;
    return image_data.encodedImageBytes(size);
}

fn writeWithheldAttachmentNotice(
    writer: *std.Io.Writer,
    attachment: types.ImageAttachment,
    dimensions: ?image_data.Dimensions,
    max_dimension: u32,
) std.Io.Writer.Error!void {
    if (dimensions) |size| {
        try writer.print("[Image #{d} not sent: {s} is {d}x{d} pixels. This request permits at most {d} per side and 5 MiB encoded per image. ", .{ attachment.id, attachment.media_type, size.width, size.height, max_dimension });
    } else {
        try writer.print("[Image #{d} not sent: its dimensions could not be verified. ", .{attachment.id});
    }
    if (attachment.inline_data == null) {
        if (attachment.snapshot_path) |path| {
            try writer.print("The original is saved at {s}. Use an available image tool to save a smaller copy to a new file", .{path});
            // Snapshots are named .bin, which hides the type from tools
            // that choose a decoder by file name.
            if (mediaTypeExtension(attachment.media_type)) |extension| {
                try writer.print(" ending in {s}", .{extension});
            }
            try writer.writeAll(", then read_file the copy. If no image tool is available, ask the user before installing one.]\n");
            return;
        }
    }
    try writer.writeAll("No local image file is available; ask the user for a smaller copy.]\n");
}

fn mediaTypeExtension(media_type: []const u8) ?[]const u8 {
    const extensions = [_]struct { []const u8, []const u8 }{
        .{ "image/png", ".png" },
        .{ "image/jpeg", ".jpg" },
        .{ "image/gif", ".gif" },
        .{ "image/webp", ".webp" },
    };
    for (extensions) |entry| {
        if (std.mem.eql(u8, media_type, entry[0])) return entry[1];
    }
    return null;
}

pub const AttachmentProjection = struct {
    messages: []const types.ChatMessage,
};

/// Leaves unsafe attachments out of the request and gives the model a source
/// path when one exists. History is not modified. `cache` and its keys use
/// `cache_alloc` and should outlive the requests of one turn.
pub fn withholdOversizedAttachments(
    arena: std.mem.Allocator,
    cache_alloc: std.mem.Allocator,
    cache: *AttachmentDimensionCache,
    messages: []const types.ChatMessage,
    max_dimension: u32,
) !AttachmentProjection {
    var result: ?[]types.ChatMessage = null;
    for (messages, 0..) |message, index| {
        if (message.images.len == 0) continue;
        var kept: ?std.ArrayList(types.ImageAttachment) = null;
        var notice: std.Io.Writer.Allocating = .init(arena);
        for (message.images, 0..) |image, image_index| {
            const dimensions = try attachmentDimensions(cache_alloc, cache, image);
            if (dimensions != null and !dimensions.?.exceeds(max_dimension) and attachmentFitsEncodedLimit(image)) {
                if (kept) |*list| list.appendAssumeCapacity(image);
                continue;
            }
            if (kept == null) {
                kept = try .initCapacity(arena, message.images.len);
                kept.?.appendSliceAssumeCapacity(message.images[0..image_index]);
            }
            debug_trace.logf("images", "event=attachment_withheld image_id={d} max_dimension={d} dimensions_known={s}", .{ image.id, max_dimension, if (dimensions != null) "true" else "false" });
            writeWithheldAttachmentNotice(&notice.writer, image, dimensions, max_dimension) catch return error.OutOfMemory;
        }
        const kept_images = kept orelse continue;

        const projected = result orelse try arena.dupe(types.ChatMessage, messages);
        result = projected;
        projected[index].images = kept_images.items;
        projected[index].content = try std.mem.concat(arena, u8, &.{ notice.written(), message.content orelse "" });
    }
    return .{ .messages = result orelse messages };
}

fn syncSnapshotDirectory(snapshot_dir: std.Io.Dir) !void {
    io_mod.syncVerifiedDir(snapshot_dir) catch |err| switch (err) {
        error.OperationUnsupported => {},
        else => return err,
    };
}

fn deleteSnapshotFile(dir: std.Io.Dir, name: []const u8, reason: []const u8) void {
    dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => debug_trace.logf(
            "images",
            "event=snapshot_cleanup_failed reason={s} err={s}",
            .{ reason, @errorName(err) },
        ),
    };
}

fn deleteSnapshotPath(path: []const u8, reason: []const u8) void {
    const parent_path = std.Io.Dir.path.dirname(path) orelse {
        debug_trace.logf(
            "images",
            "event=snapshot_cleanup_failed reason={s} err=ImageSnapshotPathUnsafe",
            .{reason},
        );
        return;
    };
    const name = std.Io.Dir.path.basename(path);
    var parent = openDirectoryNoFollow(parent_path) catch |err| {
        debug_trace.logf(
            "images",
            "event=snapshot_cleanup_failed reason={s} err={s}",
            .{ reason, @errorName(err) },
        );
        return;
    };
    defer parent.close(io_mod.getIo());
    deleteSnapshotFile(parent, name, reason);
}

pub const VerifiedSnapshot = struct {
    bytes: []u8,
    media_type: []const u8,

    pub fn deinit(self: *VerifiedSnapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

fn unsafeSnapshotPathError(err: anyerror) anyerror {
    return switch (err) {
        error.SymLinkLoop, error.NotDir, error.IsDir => error.ImageSnapshotPathUnsafe,
        else => err,
    };
}

fn validateSnapshotPathComponent(component: []const u8) !void {
    if (component.len == 0 or
        std.mem.eql(u8, component, ".") or
        std.mem.eql(u8, component, "..") or
        std.mem.findAny(u8, component, "/\\") != null)
    {
        return error.ImageSnapshotPathUnsafe;
    }
}

fn openDirectoryNoFollow(path: []const u8) !std.Io.Dir {
    if (!std.Io.Dir.path.isAbsolute(path)) return error.ImageSnapshotPathUnsafe;

    var components = std.Io.Dir.path.componentIterator(path);
    const root = components.root() orelse return error.ImageSnapshotPathUnsafe;
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{
        .follow_symlinks = false,
    }) catch |err| return unsafeSnapshotPathError(err);
    errdefer dir.close(io_mod.getIo());

    while (components.next()) |component| {
        try validateSnapshotPathComponent(component.name);
        const next = dir.openDir(io_mod.getIo(), component.name, .{
            .follow_symlinks = false,
        }) catch |err| return unsafeSnapshotPathError(err);
        dir.close(io_mod.getIo());
        dir = next;
    }
    return dir;
}

/// Iteration is requested so the handle is a real descriptor. Linux returns an `O_PATH`
/// descriptor otherwise, which serves `openat` and `renameat` but rejects the `fsync`
/// this directory needs after the snapshot rename.
const snapshot_dir_open_options: std.Io.Dir.OpenOptions = .{
    .iterate = true,
    .follow_symlinks = false,
};

fn openOrCreateSnapshotDirectoryNoFollow(path: []const u8) !std.Io.Dir {
    if (!std.Io.Dir.path.isAbsolute(path)) return error.ImageSnapshotPathUnsafe;
    const parent_path = std.Io.Dir.path.dirname(path) orelse return error.ImageSnapshotPathUnsafe;
    const name = std.Io.Dir.path.basename(path);
    try validateSnapshotPathComponent(name);

    var parent = try openDirectoryNoFollow(parent_path);
    defer parent.close(io_mod.getIo());
    return parent.openDir(
        io_mod.getIo(),
        name,
        snapshot_dir_open_options,
    ) catch |err| switch (err) {
        error.FileNotFound => blk: {
            parent.createDir(
                io_mod.getIo(),
                name,
                std.Io.File.Permissions.fromMode(0o700),
            ) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => return unsafeSnapshotPathError(create_err),
            };
            break :blk parent.openDir(
                io_mod.getIo(),
                name,
                snapshot_dir_open_options,
            ) catch |open_err| return unsafeSnapshotPathError(open_err);
        },
        else => return unsafeSnapshotPathError(err),
    };
}

fn openSnapshotFileNoFollow(path: []const u8) !std.Io.File {
    if (!std.Io.Dir.path.isAbsolute(path)) return error.ImageSnapshotPathUnsafe;
    const parent_path = std.Io.Dir.path.dirname(path) orelse return error.ImageSnapshotPathUnsafe;
    const name = std.Io.Dir.path.basename(path);
    try validateSnapshotPathComponent(name);

    var parent = try openDirectoryNoFollow(parent_path);
    defer parent.close(io_mod.getIo());
    return parent.openFile(io_mod.getIo(), name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| return unsafeSnapshotPathError(err);
}

pub fn loadVerifiedSnapshot(
    alloc: std.mem.Allocator,
    attachment: types.ImageAttachment,
    budget: CaptureBudget,
) !VerifiedSnapshot {
    if (attachment.inline_data) |inline_bytes| {
        const expected_inline = attachment.snapshot_sha256 orelse return error.MissingImageSnapshot;
        if (expected_inline.len != snapshot_digest_hex_len) return error.InvalidImageSnapshotDigest;
        try budget.check();
        if (inline_bytes.len > max_image_bytes) return error.ImageTooLarge;
        var actual: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(inline_bytes, &actual, .{});
        const actual_hex = std.fmt.bytesToHex(actual, .lower);
        if (!std.mem.eql(u8, actual_hex[0..], expected_inline)) return error.ImageSnapshotCorrupt;
        const detected = detectMediaTypeFromBytes(inline_bytes) orelse
            return error.UnsupportedImageType;
        if (!std.mem.eql(u8, detected, attachment.media_type)) return error.ImageSnapshotMediaTypeMismatch;
        return .{
            .bytes = try alloc.dupe(u8, inline_bytes),
            .media_type = detected,
        };
    }
    const path = attachment.snapshot_path orelse return error.MissingImageSnapshot;
    const expected = attachment.snapshot_sha256 orelse return error.MissingImageSnapshot;
    if (expected.len != snapshot_digest_hex_len) return error.InvalidImageSnapshotDigest;
    try budget.check();

    var file = try openSnapshotFileNoFollow(path);
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.NotRegularFile;
    const size = std.math.cast(usize, stat.size) orelse return error.ImageTooLarge;
    if (size > max_image_bytes) return error.ImageTooLarge;

    var hasher = Sha256.init(.{});
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(alloc);
    try bytes.ensureTotalCapacity(alloc, size);
    var read_buf: [8192]u8 = undefined;
    var reader = file.readerStreaming(io_mod.getIo(), &read_buf);
    var transfer_buf: [transfer_buffer_bytes]u8 = undefined;
    while (true) {
        try budget.check();
        const n = try reader.interface.readSliceShort(&transfer_buf);
        if (n == 0) break;
        if (n > max_image_bytes - bytes.items.len) return error.ImageTooLarge;
        try bytes.appendSlice(alloc, transfer_buf[0..n]);
        hasher.update(transfer_buf[0..n]);
    }
    var actual: [Sha256.digest_length]u8 = undefined;
    hasher.final(&actual);
    const actual_hex = std.fmt.bytesToHex(actual, .lower);
    if (!std.mem.eql(u8, actual_hex[0..], expected)) return error.ImageSnapshotCorrupt;

    const detected = detectMediaTypeFromBytes(bytes.items) orelse
        return error.UnsupportedImageType;
    if (!std.mem.eql(u8, detected, attachment.media_type)) return error.ImageSnapshotMediaTypeMismatch;
    return .{
        .bytes = try bytes.toOwnedSlice(alloc),
        .media_type = detected,
    };
}

/// Returns a new attachment with independently owned snapshot bytes for `new_id`.
/// The source snapshot remains owned by the caller.
pub fn cloneVerifiedImageAttachment(
    alloc: std.mem.Allocator,
    attachment: types.ImageAttachment,
    new_id: usize,
) !types.ImageAttachment {
    if (new_id == 0) return error.InvalidImageId;
    const source_snapshot_path = attachment.snapshot_path orelse
        return error.MissingImageSnapshot;
    const snapshot_dir = std.Io.Dir.path.dirname(source_snapshot_path) orelse
        return error.ImageSnapshotPathUnsafe;
    return copyVerifiedImageAttachmentToDir(
        alloc,
        attachment,
        new_id,
        snapshot_dir,
    );
}

pub fn copyVerifiedImageAttachmentToDir(
    alloc: std.mem.Allocator,
    attachment: types.ImageAttachment,
    new_id: usize,
    snapshot_dir: []const u8,
) !types.ImageAttachment {
    if (new_id == 0) return error.InvalidImageId;
    const source_digest = attachment.snapshot_sha256 orelse
        return error.MissingImageSnapshot;
    var verified = try loadVerifiedSnapshot(alloc, attachment, .{});
    defer verified.deinit(alloc);

    const path = try alloc.dupe(u8, attachment.path);
    errdefer alloc.free(path);
    const media_type = try alloc.dupe(u8, verified.media_type);
    errdefer alloc.free(media_type);
    const digest = try alloc.dupe(u8, source_digest);
    errdefer alloc.free(digest);

    const final_name = try alloc.print(
        "image-{d}-{s}.bin",
        .{ new_id, source_digest[0..16] },
    );
    defer alloc.free(final_name);
    const final_path = try std.Io.Dir.path.join(alloc, &.{ snapshot_dir, final_name });
    errdefer alloc.free(final_path);

    const temp_name = try alloc.print(
        "image-{d}.clone.{d}",
        .{ new_id, io_mod.nanoTimestamp() },
    );
    defer alloc.free(temp_name);

    var snapshot_dir_handle = try openOrCreateSnapshotDirectoryNoFollow(snapshot_dir);
    defer snapshot_dir_handle.close(io_mod.getIo());
    var cleanup_temp = true;
    defer if (cleanup_temp) {
        deleteSnapshotFile(snapshot_dir_handle, temp_name, "clone_snapshot_temp");
    };

    var destination = try snapshot_dir_handle.createFile(
        io_mod.getIo(),
        temp_name,
        .{
            .truncate = false,
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
            .resolve_beneath = true,
        },
    );
    defer destination.close(io_mod.getIo());
    try destination.writeStreamingAll(io_mod.getIo(), verified.bytes);
    try destination.sync(io_mod.getIo());
    try snapshot_dir_handle.rename(
        temp_name,
        snapshot_dir_handle,
        final_name,
        io_mod.getIo(),
    );
    cleanup_temp = false;
    var cleanup_final = true;
    errdefer if (cleanup_final) {
        deleteSnapshotFile(snapshot_dir_handle, final_name, "clone_snapshot_final");
    };
    try syncSnapshotDirectory(snapshot_dir_handle);

    cleanup_final = false;
    return .{
        .id = new_id,
        .path = path,
        .media_type = media_type,
        .snapshot_path = final_path,
        .snapshot_sha256 = digest,
    };
}

pub fn captureImageSnapshots(
    alloc: std.mem.Allocator,
    attachments: []types.ImageAttachment,
    snapshot_dir: []const u8,
    budget: CaptureBudget,
) !void {
    var captured: usize = 0;
    errdefer {
        for (attachments[0..captured]) |*attachment| discardImageSnapshot(alloc, attachment);
    }
    for (attachments) |*attachment| {
        try captureImageSnapshotWithBudget(alloc, attachment, snapshot_dir, budget);
        captured += 1;
    }
}

pub fn discardImageSnapshot(alloc: std.mem.Allocator, attachment: *types.ImageAttachment) void {
    if (attachment.snapshot_path) |path| {
        deleteSnapshotPath(path, "discard_snapshot");
        alloc.free(path);
        attachment.snapshot_path = null;
    }
    if (attachment.snapshot_sha256) |digest| {
        alloc.free(digest);
        attachment.snapshot_sha256 = null;
    }
}

pub fn discardImageSnapshots(alloc: std.mem.Allocator, attachments: []types.ImageAttachment) void {
    for (attachments, 0..) |*attachment, index| {
        if (attachment.snapshot_path) |path| {
            var duplicate = false;
            for (attachments[0..index]) |previous| {
                if (previous.snapshot_path) |previous_path| {
                    if (std.mem.eql(u8, path, previous_path)) {
                        duplicate = true;
                        break;
                    }
                }
            }
            if (!duplicate) deleteSnapshotPath(path, "discard_snapshot_slice");
        }
        if (attachment.snapshot_path) |owned| alloc.free(owned);
        if (attachment.snapshot_sha256) |owned| alloc.free(owned);
        attachment.snapshot_path = null;
        attachment.snapshot_sha256 = null;
    }
}

pub fn deleteUnreferencedImageSnapshots(
    candidates: []const types.ImageAttachment,
    retained: []const types.ImageAttachment,
) void {
    for (candidates, 0..) |candidate, index| {
        const path = candidate.snapshot_path orelse continue;
        var duplicate = false;
        for (candidates[0..index]) |previous| {
            if (previous.snapshot_path) |previous_path| {
                if (std.mem.eql(u8, path, previous_path)) {
                    duplicate = true;
                    break;
                }
            }
        }
        if (duplicate) continue;

        for (retained) |attachment| {
            if (attachment.snapshot_path) |retained_path| {
                if (std.mem.eql(u8, path, retained_path)) break;
            }
        } else {
            deleteSnapshotPath(path, "discard_unreferenced_snapshot");
        }
    }
}

pub fn discardImageAttachment(alloc: std.mem.Allocator, attachment: types.ImageAttachment) void {
    var owned = attachment;
    discardImageSnapshot(alloc, &owned);
    types.freeImageAttachment(alloc, owned);
}

pub fn discardImageAttachmentSlice(alloc: std.mem.Allocator, attachments: []types.ImageAttachment) void {
    discardImageSnapshots(alloc, attachments);
    types.freeImageAttachmentSlice(alloc, attachments);
}

pub fn writeImageBadge(writer: *std.Io.Writer, image_id: usize, abs_path: []const u8) !void {
    try writer.writeAll("\x1b]8;;file://");
    try writePercentEncodedPath(writer, abs_path);
    try writer.print("\x1b\\[Image {d}]\x1b]8;;\x1b\\", .{image_id});
}

pub fn writeImageBadgeClipped(writer: *std.Io.Writer, image_id: usize, abs_path: []const u8, max_cells: usize) !void {
    if (max_cells == 0) return;

    var label_buf: [64]u8 = undefined;
    const label = try std.mem.print(&label_buf, "[Image {d}]", .{image_id});
    const clipped_label = display_width.prefixByWidth(label, max_cells);

    try writer.writeAll("\x1b]8;;file://");
    try writePercentEncodedPath(writer, abs_path);
    try writer.writeAll("\x1b\\");
    try writer.writeAll(clipped_label);
    try writer.writeAll("\x1b]8;;\x1b\\");
}

pub fn imageBadgeVisibleWidth(image_id: usize) usize {
    var digits: usize = 1;
    var n = image_id;
    while (n >= 10) {
        digits += 1;
        n /= 10;
    }
    return "[Image ".len + digits + "]".len;
}

pub fn allocateImageId(counter: *usize) usize {
    const id = counter.*;
    counter.* += 1;
    return id;
}

const ImagePlaceholderMatch = struct { id: usize, length: usize };

const image_placeholder_prefix = "[Image #";

pub fn writeImagePlaceholder(writer: *std.Io.Writer, id: usize) std.Io.Writer.Error!void {
    return writer.print("{s}{d}]", .{ image_placeholder_prefix, id });
}

pub fn formatImagePlaceholder(buf: []u8, id: usize) error{NoSpaceLeft}![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writeImagePlaceholder(&writer, id) catch return error.NoSpaceLeft;
    return writer.buffered();
}

pub fn matchImagePlaceholder(text: []const u8, start: usize) ?ImagePlaceholderMatch {
    if (start > text.len or text.len - start < image_placeholder_prefix.len) return null;
    if (!std.mem.eql(u8, text[start .. start + image_placeholder_prefix.len], image_placeholder_prefix)) return null;

    var i = start + image_placeholder_prefix.len;
    var id: usize = 0;
    var digits: usize = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        id = std.math.mul(usize, id, 10) catch return null;
        id = std.math.add(usize, id, text[i] - '0') catch return null;
        digits += 1;
    }
    if (digits == 0) return null;
    if (i >= text.len or text[i] != ']') return null;
    return .{ .id = id, .length = i + 1 - start };
}

pub fn imageAttachmentsSortedById(images: []const types.ImageAttachment) bool {
    var previous: ?usize = null;
    for (images) |image| {
        if (previous) |id| {
            if (image.id <= id) return false;
        }
        previous = image.id;
    }
    return true;
}

pub fn findImageIndexByIdSorted(images: []const types.ImageAttachment, id: usize) ?usize {
    var left: usize = 0;
    var right: usize = images.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        const mid_id = images[mid].id;
        if (mid_id == id) return mid;
        if (mid_id < id) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    return null;
}

pub fn findImageIndexById(images: []const types.ImageAttachment, id: usize) ?usize {
    for (images, 0..) |image, index| {
        if (image.id == id) return index;
    }
    return null;
}

pub const ImageIdBounds = struct {
    maximum_id: ?usize,
    next_id: usize,
};

pub fn validate_image_ids(image_ids: []const usize) error{ EmptyImageIds, InvalidImageId, DuplicateImageId }!void {
    if (image_ids.len == 0) return error.EmptyImageIds;
    for (image_ids, 0..) |image_id, index| {
        if (image_id == 0) return error.InvalidImageId;
        for (image_ids[0..index]) |previous_id| {
            if (image_id == previous_id) return error.DuplicateImageId;
        }
    }
}

/// Returns a caller-owned slice of pointers borrowed from `catalog`. The
/// caller frees only the returned slice with `alloc`.
pub fn resolve_authorized_images(
    alloc: std.mem.Allocator,
    catalog: []const types.ImageAttachment,
    requested_ids: []const usize,
) (std.mem.Allocator.Error || error{
    EmptyImageIds,
    InvalidImageId,
    DuplicateImageId,
    InvalidImageCatalog,
    UnauthorizedImageId,
})![]const *const types.ImageAttachment {
    try validate_image_ids(requested_ids);
    if (!imageAttachmentsSortedById(catalog)) return error.InvalidImageCatalog;

    const resolved = try alloc.alloc(*const types.ImageAttachment, requested_ids.len);
    errdefer alloc.free(resolved);
    for (requested_ids, 0..) |image_id, index| {
        const catalog_index = findImageIndexByIdSorted(catalog, image_id) orelse
            return error.UnauthorizedImageId;
        resolved[index] = &catalog[catalog_index];
    }
    return resolved;
}

pub fn calculate_next_image_id(
    images: []const types.ImageAttachment,
) error{ InvalidImageId, ImageIdOverflow }!ImageIdBounds {
    var maximum_id: ?usize = null;
    for (images) |image| {
        if (image.id == 0) return error.InvalidImageId;
        if (maximum_id == null or image.id > maximum_id.?) maximum_id = image.id;
    }
    if (maximum_id) |value| {
        return .{
            .maximum_id = value,
            .next_id = std.math.add(usize, value, 1) catch return error.ImageIdOverflow,
        };
    }
    return .{ .maximum_id = null, .next_id = 1 };
}

pub const ExpandWithBadgesResult = struct { cursor_out: ?usize, expanded_any: bool };

/// Replaces known image placeholders with path-free badges keyed by attachment ID.
/// Unknown placeholders pass through; `cursor_out` maps `cursor_in` to output bytes.
pub fn expandPlaceholdersWithBadges(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    text: []const u8,
    images: []const types.ImageAttachment,
    cursor_in: ?usize,
) !ExpandWithBadgesResult {
    return expandPlaceholdersWithBadgeMode(
        alloc,
        writer,
        text,
        images,
        cursor_in,
        false,
    );
}

pub fn expandPlaceholdersWithLinkedBadges(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    text: []const u8,
    images: []const types.ImageAttachment,
    cursor_in: ?usize,
) !ExpandWithBadgesResult {
    return expandPlaceholdersWithBadgeMode(
        alloc,
        writer,
        text,
        images,
        cursor_in,
        true,
    );
}

fn expandPlaceholdersWithBadgeMode(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    text: []const u8,
    images: []const types.ImageAttachment,
    cursor_in: ?usize,
    linked: bool,
) !ExpandWithBadgesResult {
    var cursor_out: ?usize = null;
    var written: usize = 0;
    var expanded_any = false;
    var i: usize = 0;
    while (i < text.len) {
        if (cursor_in) |c| {
            if (cursor_out == null and i >= c) cursor_out = written;
        }
        if (text[i] == '[') {
            if (matchImagePlaceholder(text, i)) |match| {
                if (findImageById(images, match.id)) |img| {
                    expanded_any = true;
                    var badge_buf: std.Io.Writer.Allocating = .init(alloc);
                    defer badge_buf.deinit();
                    if (linked) {
                        try writeImageBadge(&badge_buf.writer, img.id, img.path);
                    } else {
                        try badge_buf.writer.print("[Image {d}]", .{img.id});
                    }
                    const badge_bytes = badge_buf.written();
                    try writer.writeAll(badge_bytes);
                    written += badge_bytes.len;
                } else {
                    try writer.writeAll(text[i .. i + match.length]);
                    written += match.length;
                }
                i += match.length;
                continue;
            }
        }
        try writer.writeByte(text[i]);
        written += 1;
        i += 1;
    }
    if (cursor_in) |c| {
        if (cursor_out == null and c >= text.len) cursor_out = written;
    }
    return .{ .cursor_out = cursor_out, .expanded_any = expanded_any };
}

fn findImageById(images: []const types.ImageAttachment, id: usize) ?types.ImageAttachment {
    for (images) |img| {
        if (img.id == id) return img;
    }
    return null;
}

fn writePercentEncodedPath(writer: *std.Io.Writer, path: []const u8) !void {
    for (path) |byte| {
        if (isUriPathSafe(byte)) {
            try writer.writeByte(byte);
        } else {
            try writer.print("%{X:0>2}", .{byte});
        }
    }
}

fn isUriPathSafe(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or
        byte == '-' or
        byte == '.' or
        byte == '_' or
        byte == '~' or
        byte == '/';
}

pub fn extractInlineImageAttachments(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    text: []const u8,
    first_image_id: usize,
) !ExtractedInlineImages {
    var images: std.ArrayList(types.ImageAttachment) = .empty;
    errdefer {
        for (images.items) |image| types.freeImageAttachment(alloc, image);
        images.deinit(alloc);
    }
    var replacements: std.ArrayList(InlineImageReplacement) = .empty;
    defer replacements.deinit(alloc);

    var index: usize = 0;
    while (true) {
        while (index < text.len and isWhitespace(text[index])) : (index += 1) {}
        if (index == text.len) break;
        const start = index;
        index = nextShellTokenEnd(text, start);
        const token = splitImagePathToken(text[start..index]) orelse continue;
        var image = load_inline_image_attachment(alloc, workspace_root, token) catch |err| switch (err) {
            error.FileNotFound,
            error.HomeNotSet,
            error.InvalidPath,
            error.NotRegularFile,
            error.UnsupportedImageType,
            => {
                debug_trace.logf("images", "event=inline_image_promotion_skipped reason={s}", .{@errorName(err)});
                continue;
            },
            else => return err,
        };
        var owns_image = true;
        errdefer if (owns_image) types.freeImageAttachment(alloc, image);
        image.id = std.math.add(usize, first_image_id, images.items.len) catch return error.ImageIdOverflow;
        if (image.id == 0) return error.InvalidImageId;
        _ = std.math.add(usize, image.id, 1) catch return error.ImageIdOverflow;
        try images.ensureUnusedCapacity(alloc, 1);
        try replacements.append(alloc, .{
            .source = .{ .raw_start = start, .raw_end = index - token.suffix.len },
            .id = image.id,
        });
        images.appendAssumeCapacity(image);
        owns_image = false;
    }

    const owned_images = try images.toOwnedSlice(alloc);
    errdefer types.freeImageAttachmentSlice(alloc, owned_images);
    const rewritten = try rewrite_inline_images(alloc, text, replacements.items);
    return .{ .text = rewritten.text, .images = owned_images, .edits = rewritten.edits };
}

pub const ClipboardImageAttachment = struct {
    attachment: ?types.ImageAttachment,
    source_dir: []u8,

    pub fn takeAttachment(self: *ClipboardImageAttachment) types.ImageAttachment {
        const attachment = self.attachment orelse unreachable;
        self.attachment = null;
        return attachment;
    }

    pub fn deinit(self: *ClipboardImageAttachment, alloc: std.mem.Allocator) void {
        if (self.attachment) |attachment| types.freeImageAttachment(alloc, attachment);
        cleanupSnapshotDir(self.source_dir);
        alloc.free(self.source_dir);
        self.* = undefined;
    }
};

pub fn loadClipboardImageAttachment(alloc: std.mem.Allocator) !ClipboardImageAttachment {
    if (builtin.target.os.tag != .macos) return error.Unsupported;

    const source_dir = try createTempSnapshotDir(alloc);
    errdefer {
        cleanupSnapshotDir(source_dir);
        alloc.free(source_dir);
    }
    const temp_path = try std.Io.Dir.path.join(alloc, &.{ source_dir, "clipboard.png" });
    defer alloc.free(temp_path);

    const write_script = try alloc.print(
        "set outFile to POSIX file \"{s}\"\n" ++
            "set pngData to the clipboard as «class PNGf»\n" ++
            "set fileRef to open for access outFile with write permission\n" ++
            "set eof fileRef to 0\n" ++
            "write pngData to fileRef\n" ++
            "close access fileRef\n",
        .{temp_path},
    );
    defer alloc.free(write_script);

    const argv = [_][]const u8{ "osascript", "-e", write_script };
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &argv,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) {
            const attachment = try loadImageAttachment(alloc, temp_path);
            return .{
                .attachment = attachment,
                .source_dir = source_dir,
            };
        },
        else => {},
    }

    return error.NoClipboardImage;
}

fn readImageHeaderBytes(path: []const u8, out: []u8) ![]const u8 {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(zio, path, .{});
    defer file.close(zio);

    const stat = try file.stat(zio);
    if (stat.kind != .file) return error.NotRegularFile;
    if (stat.size > max_image_bytes) return error.ImageTooLarge;
    return readImageHeaderFromFile(&file, @intCast(stat.size), out);
}

fn readImageHeaderFromFile(
    file: *std.Io.File,
    expected_size: usize,
    out: []u8,
) ![]const u8 {
    const zio = io_mod.getIo();
    const header_len = @min(expected_size, out.len);

    var read_buf: [4096]u8 = undefined;
    var r = file.reader(zio, &read_buf);
    const n = try r.interface.readSliceShort(out[0..header_len]);
    return out[0..n];
}

fn normalizePathInput(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const slice = stripBalancedOuterQuotes(trimmed);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < slice.len) : (i += 1) {
        if (slice[i] == '\\' and i + 1 < slice.len) {
            i += 1;
            try out.writer.writeByte(slice[i]);
            continue;
        }
        try out.writer.writeByte(slice[i]);
    }

    return out.toOwnedSlice();
}

const detectMediaTypeFromBytes = @import("image_data.zig").detectMediaTypeFromBytes;

pub const ImagePathToken = struct {
    path: []const u8,
    suffix: []const u8,
    /// Canonical @ payload without quotes; decode once before literal loading.
    literal_payload: bool = false,
};

/// Loads one parsed image token. Caller owns the returned attachment.
pub fn load_inline_image_attachment(alloc: std.mem.Allocator, workspace_root: []const u8, token: ImagePathToken) !types.ImageAttachment {
    if (!token.literal_payload) return loadUserImageAttachment(alloc, workspace_root, token.path);
    const path = try file_picker_path.decode_alloc(alloc, token.path);
    defer alloc.free(path);
    return load_user_image_literal(alloc, workspace_root, path);
}

pub fn splitImagePathToken(raw: []const u8) ?ImagePathToken {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "@\"")) {
        const token = file_picker_path.parse_at(trimmed, 0) orelse return null;
        if (token.status != .complete or token.end != trimmed.len) return null;
        if (token.canonical_escapes) {
            const payload = trimmed[token.path_start..token.path_end];
            var storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const decoded = file_picker_path.decode_into(payload, &storage) catch return null;
            const dot = std.mem.findScalarLast(u8, decoded, '.') orelse return null;
            if (!supported_path_extension(decoded[dot..])) return null;
            return .{ .path = payload, .suffix = trimmed[token.quote_end.?..], .literal_payload = true };
        }
        // Noncanonical escapes keep legacy eligibility (notably backslash-dot).
    }
    const path_start: usize = if (std.mem.startsWith(u8, trimmed, "@")) 1 else 0;
    if (path_start == 1 and std.mem.startsWith(u8, trimmed[path_start..], "@")) return null;
    const suffix_start = trailingSentencePunctuationStart(trimmed);
    if (path_start >= suffix_start) return null;
    const path = trimmed[path_start..suffix_start];
    const ext = extensionIgnoringEscapes(stripBalancedOuterQuotes(path));
    if (!supported_path_extension(ext)) return null;
    return .{ .path = path, .suffix = trimmed[suffix_start..] };
}

fn supported_path_extension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg") or
        std.ascii.eqlIgnoreCase(ext, ".gif") or
        std.ascii.eqlIgnoreCase(ext, ".webp");
}

pub fn looksLikeImagePathToken(raw: []const u8) bool {
    return splitImagePathToken(raw) != null;
}

fn trailingSentencePunctuationStart(bytes: []const u8) usize {
    var suffix_start = bytes.len;
    var quote: ?u8 = null;
    var escaped = false;
    for (bytes, 0..) |byte, index| {
        if (escaped) {
            suffix_start = index + 1;
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            suffix_start = index + 1;
            escaped = true;
            continue;
        }
        if (quote) |active| {
            suffix_start = index + 1;
            if (byte == active) quote = null;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            suffix_start = index + 1;
            quote = byte;
            continue;
        }
        if (!isSentencePunctuation(byte)) suffix_start = index + 1;
    }
    return suffix_start;
}

fn isSentencePunctuation(byte: u8) bool {
    return byte == ',' or byte == '.' or byte == ';' or
        byte == ':' or byte == '!' or byte == '?';
}

fn stripBalancedOuterQuotes(bytes: []const u8) []const u8 {
    if (bytes.len < 2) return bytes;
    if ((bytes[0] == '"' and bytes[bytes.len - 1] == '"') or
        (bytes[0] == '\'' and bytes[bytes.len - 1] == '\''))
    {
        return bytes[1 .. bytes.len - 1];
    }
    return bytes;
}

pub fn hasImagePathToken(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        while (i < bytes.len and isWhitespace(bytes[i])) : (i += 1) {}
        if (i >= bytes.len) break;
        const start = i;
        i = nextShellTokenEnd(bytes, start);
        if (looksLikeImagePathToken(bytes[start..i])) return true;
    }
    return false;
}

fn extensionIgnoringEscapes(raw: []const u8) []const u8 {
    var dot_index: ?usize = null;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            continue;
        }
        if (raw[i] == '.') dot_index = i;
    }
    return if (dot_index) |idx| raw[idx..] else "";
}

pub const nextShellTokenEnd = file_picker_path.token_end;

pub fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

//! Keeps the images re-sent with every request under the provider's request
//! size limit. Each request carries every earlier image, so its body grows
//! with every screenshot while its token estimate barely moves. The oldest
//! images leave the request first, each with a note for loading it again.
//! History is never changed.
const std = @import("std");
const types = @import("../../shared/types.zig");
const image_attachments = @import("../../images/image_attachments.zig");
const utf8PrefixLength = @import("../../config/context_limits.zig").utf8PrefixLength;

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

/// Claude routes reject request bodies over 32 MiB, the strictest limit
/// measured through AI Gateway. Gemini and OpenAI routes accept larger ones.
pub const default_max_request_bytes: usize = 30 * 1024 * 1024;
/// Anthropic accepts at most 100 images in one request.
pub const default_max_request_images: usize = 100;
/// Planning allowance for the note that replaces each withheld image.
const notice_reserve_bytes: usize = 320;

pub const Limits = struct {
    max_request_bytes: usize = default_max_request_bytes,
    max_images: usize = default_max_request_images,
};

/// Returns how many of the oldest images must leave a request of
/// `request_bytes` for it to fit `limits`. `image_bytes` holds each image's
/// serialized size, oldest first. Returns `image_bytes.len` when the request
/// does not fit even without images.
pub fn oldestImagesToWithhold(image_bytes: []const usize, request_bytes: usize, limits: Limits) usize {
    var withheld: usize = 0;
    var bytes = request_bytes;
    while (withheld < image_bytes.len) : (withheld += 1) {
        if (image_bytes.len - withheld <= limits.max_images and bytes <= limits.max_request_bytes) break;
        bytes = (bytes -| image_bytes[withheld]) +| notice_reserve_bytes;
    }
    return withheld;
}

pub const Projection = struct {
    messages: []const ChatMessage,
    withheld: usize = 0,
};

/// Leaves the oldest images out of a request whose serialized size is
/// `request_bytes` until it fits `limits`. Returned messages are `messages`
/// itself when nothing is withheld, otherwise a copy allocated in `arena`.
/// `tool_text_limit` bounds tool result content after the note is added.
pub fn withholdOldestImages(
    arena: Allocator,
    messages: []const ChatMessage,
    request_bytes: usize,
    limits: Limits,
    tool_text_limit: usize,
) Allocator.Error!Projection {
    var sizes: std.ArrayList(usize) = .empty;
    for (messages) |message| {
        for (message.images) |image| {
            // An unreadable attachment cannot be serialized either; it
            // still counts toward the image limit.
            try sizes.append(arena, image_attachments.attachmentEncodedBytes(image) orelse 0);
        }
        if (message.tool_result_memory) |memory| {
            for (memory.tool_images) |image| try sizes.append(arena, image.data.len);
        }
    }
    const withheld = oldestImagesToWithhold(sizes.items, request_bytes, limits);
    if (withheld == 0) return .{ .messages = messages };

    const projected = try arena.dupe(ChatMessage, messages);
    var remaining = withheld;
    for (projected) |*message| {
        if (remaining == 0) break;
        if (message.images.len > 0) {
            const count = @min(remaining, message.images.len);
            var notice: std.Io.Writer.Allocating = .init(arena);
            for (message.images[0..count]) |image| writeAttachmentNotice(&notice.writer, image) catch return error.OutOfMemory;
            message.images = message.images[count..];
            message.content = try std.mem.concat(arena, u8, &.{ notice.written(), message.content orelse "" });
            remaining -= count;
        }
        if (remaining == 0) break;
        if (message.tool_result_memory) |*memory| {
            if (memory.tool_images.len == 0) continue;
            const count = @min(remaining, memory.tool_images.len);
            const notice = try toolImagesNotice(arena, count, memory.tool_image_handle);
            memory.tool_images = memory.tool_images[count..];
            message.content = try prependNotice(arena, notice, message.content orelse "", tool_text_limit);
            remaining -= count;
        }
    }
    return .{ .messages = projected, .withheld = withheld };
}

fn writeAttachmentNotice(writer: *std.Io.Writer, image: types.ImageAttachment) std.Io.Writer.Error!void {
    try writer.print("[Image #{d} not sent to keep the request under the provider's size limit.", .{image.id});
    if (image.inline_data == null) {
        if (image.snapshot_path) |path| try writer.print(" The original is saved at {s}; read_file it to see it again.", .{path});
    }
    try writer.writeAll("]\n");
}

fn toolImagesNotice(arena: Allocator, count: usize, handle: ?[]const u8) Allocator.Error![]u8 {
    const subject = if (count == 1) "1 image" else try arena.print("{d} images", .{count});
    if (handle) |value| {
        const object = if (count == 1) "it" else "them";
        return arena.print("[{s} from this result not sent to keep the request under the provider's size limit. Use read_tool_result with handle {s} to load {s} again.]\n", .{ subject, value, object });
    }
    return arena.print("[{s} from this result not sent to keep the request under the provider's size limit.]\n", .{subject});
}

fn prependNotice(arena: Allocator, notice: []const u8, content: []const u8, limit: usize) Allocator.Error![]u8 {
    const notice_keep = utf8PrefixLength(notice, limit);
    const keep = utf8PrefixLength(content, limit -| notice.len);
    return std.mem.concat(arena, u8, &.{ notice[0..notice_keep], content[0..keep] });
}

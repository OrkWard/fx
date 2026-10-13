const std = @import("std");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_event = @import("session_event.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const manifest_max_bytes: usize = 64 * 1024;
pub const Digest = [Sha256.digest_length]u8;

pub const Manifest = struct {
    id: []u8,
    authority_id: session_event.Identifier,
    log_generation: session_event.Identifier,
    created_at_ms: i64,
    updated_at_ms: i64,
    origin_workspace_root: []u8,
    workspace_root: []u8,
    conversation_language: session.ConversationLanguage,
    history_len: u64,
    total_input_tokens: u64,
    total_output_tokens: u64,
    last_event_seq: u64,
    event_log_bytes: u64,
    event_log_stat_fingerprint: Digest,
    generation_base_seq: u64,
    generation_base_bytes: u64,
    checkpoint_seq: ?u64,
    checkpoint_sha256: ?Digest,
    preferences: session_codec.DurableSessionPreferences,

    pub fn deinit(self: *Manifest, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.origin_workspace_root);
        alloc.free(self.workspace_root);
        self.preferences.deinit(alloc);
        self.* = undefined;
    }
};

pub fn decodeManifest(alloc: Allocator, bytes: []const u8) !Manifest {
    if (bytes.len == 0 or bytes.len > manifest_max_bytes) return error.ManifestTooLarge;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifest,
    };
    defer parsed.deinit();
    const root = try exactObject(parsed.value, &.{
        "schema_version",
        "storage_format",
        "id",
        "authority_id",
        "log_generation",
        "created_at_ms",
        "updated_at_ms",
        "origin_workspace_root",
        "workspace_root",
        "conversation_language",
        "history_len",
        "total_input_tokens",
        "total_output_tokens",
        "last_event_seq",
        "event_log_bytes",
        "event_log_stat_fingerprint",
        "generation_base_seq",
        "generation_base_bytes",
        "checkpoint_seq",
        "checkpoint_sha256",
        "preferences",
    });
    if (try requireU64(root, "schema_version") != 3 or
        !std.mem.eql(u8, try requireString(root, "storage_format"), "event_log_v1"))
    {
        return error.InvalidManifest;
    }
    const id = try dupeString(alloc, root, "id");
    errdefer alloc.free(id);
    const origin = try dupeString(alloc, root, "origin_workspace_root");
    errdefer alloc.free(origin);
    const current = try dupeString(alloc, root, "workspace_root");
    errdefer alloc.free(current);
    const preferences = try parsePreferences(
        alloc,
        root.get("preferences") orelse return error.InvalidManifest,
    );
    errdefer {
        var owned = preferences;
        owned.deinit(alloc);
    }
    const manifest = Manifest{
        .id = id,
        .authority_id = try parseIdentifier(try requireString(root, "authority_id")),
        .log_generation = try parseIdentifier(try requireString(root, "log_generation")),
        .created_at_ms = try requireI64(root, "created_at_ms"),
        .updated_at_ms = try requireI64(root, "updated_at_ms"),
        .origin_workspace_root = origin,
        .workspace_root = current,
        .conversation_language = session_codec.parseConversationLanguage(
            try requireString(root, "conversation_language"),
        ) catch return error.InvalidManifest,
        .history_len = try requireU64(root, "history_len"),
        .total_input_tokens = try requireU64(root, "total_input_tokens"),
        .total_output_tokens = try requireU64(root, "total_output_tokens"),
        .last_event_seq = try requireU64(root, "last_event_seq"),
        .event_log_bytes = try requireU64(root, "event_log_bytes"),
        .event_log_stat_fingerprint = try parseDigest(
            try requireString(root, "event_log_stat_fingerprint"),
        ),
        .generation_base_seq = try requireU64(root, "generation_base_seq"),
        .generation_base_bytes = try requireU64(root, "generation_base_bytes"),
        .checkpoint_seq = try optionalU64(root.get("checkpoint_seq") orelse
            return error.InvalidManifest),
        .checkpoint_sha256 = try optionalDigest(root.get("checkpoint_sha256") orelse
            return error.InvalidManifest),
        .preferences = preferences,
    };
    try validateManifest(manifest);
    return manifest;
}

/// A projection is stale once the committed log's size differs from the bytes
/// it summarizes. Copying or restoring a session changes the log's inode and
/// ctime without adding events, so stat identity is not a staleness signal.
pub fn isManifestStale(manifest: Manifest, event_log_size: u64) bool {
    return event_log_size != manifest.event_log_bytes;
}

pub fn stateMatchesManifest(
    state: session_codec.DurableSessionState,
    manifest: Manifest,
) bool {
    return std.mem.eql(u8, state.id, manifest.id) and
        std.mem.eql(
            u8,
            state.origin_workspace_root,
            manifest.origin_workspace_root,
        ) and
        std.mem.eql(u8, state.workspace_root, manifest.workspace_root) and
        state.created_at_ms == manifest.created_at_ms and
        state.updated_at_ms == manifest.updated_at_ms and
        std.mem.eql(
            u8,
            state.conversation_language.view(),
            manifest.conversation_language.view(),
        ) and
        state.history.len == manifest.history_len and
        state.total_input_tokens == manifest.total_input_tokens and
        state.total_output_tokens == manifest.total_output_tokens and
        durablePreferencesEqual(state.preferences, manifest.preferences);
}

fn durablePreferencesEqual(
    left: session_codec.DurableSessionPreferences,
    right: session_codec.DurableSessionPreferences,
) bool {
    return std.mem.eql(u8, left.model, right.model) and
        left.provider.same_authority(right.provider) and
        left.effort.eql(right.effort) and
        left.fast_mode == right.fast_mode;
}

pub fn sha256(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn validateManifest(manifest: Manifest) !void {
    const state = session_codec.DurableSessionState{
        .id = manifest.id,
        .origin_workspace_root = manifest.origin_workspace_root,
        .workspace_root = manifest.workspace_root,
        .created_at_ms = manifest.created_at_ms,
        .updated_at_ms = manifest.updated_at_ms,
        .conversation_language = manifest.conversation_language,
        .preferences = manifest.preferences,
        .history = &.{},
        .total_input_tokens = manifest.total_input_tokens,
        .total_output_tokens = manifest.total_output_tokens,
    };
    session_codec.validateState(state) catch return error.InvalidManifest;
    if (manifest.last_event_seq == 0 or manifest.event_log_bytes == 0 or
        manifest.generation_base_seq == 0 or
        manifest.generation_base_seq > manifest.last_event_seq or
        manifest.generation_base_bytes == 0 or
        manifest.generation_base_bytes > manifest.event_log_bytes or
        ((manifest.checkpoint_seq == null) != (manifest.checkpoint_sha256 == null)) or
        (manifest.checkpoint_seq != null and
            (manifest.checkpoint_seq.? == 0 or
                manifest.checkpoint_seq.? > manifest.last_event_seq)))
    {
        return error.InvalidManifest;
    }
}

fn parsePreferences(alloc: Allocator, value: std.json.Value) !session_codec.DurableSessionPreferences {
    return session_codec.parse_preferences(alloc, value) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidManifest,
    };
}

fn exactObject(value: std.json.Value, keys: []const []const u8) !std.json.ObjectMap {
    if (value != .object or value.object.count() != keys.len) return error.InvalidManifest;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (keys) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidManifest;
    }
    return value.object;
}

fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidManifest;
    if (value != .string) return error.InvalidManifest;
    return value.string;
}

fn dupeString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    return try alloc.dupe(u8, try requireString(object, key));
}

fn requireI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidManifest;
    return switch (value) {
        .integer => |number| number,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch
            error.InvalidManifest,
        else => error.InvalidManifest,
    };
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidManifest;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidManifest,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch
            error.InvalidManifest,
        else => error.InvalidManifest,
    };
}

fn optionalU64(value: std.json.Value) !?u64 {
    return switch (value) {
        .null => null,
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidManifest,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch
            error.InvalidManifest,
        else => error.InvalidManifest,
    };
}

fn optionalDigest(value: std.json.Value) !?Digest {
    return switch (value) {
        .null => null,
        .string => |hex| try parseDigest(hex),
        else => error.InvalidManifest,
    };
}

fn parseIdentifier(hex: []const u8) !session_event.Identifier {
    return parseHex(session_event.Identifier, hex);
}

fn parseDigest(hex: []const u8) !Digest {
    return parseHex(Digest, hex);
}

fn parseHex(comptime T: type, hex: []const u8) !T {
    if (hex.len != @sizeOf(T) * 2) return error.InvalidManifest;
    var value: T = undefined;
    _ = std.fmt.hexToBytes(&value, hex) catch return error.InvalidManifest;
    const canonical = std.fmt.bytesToHex(value, .lower);
    if (!std.mem.eql(u8, &canonical, hex)) return error.InvalidManifest;
    return value;
}

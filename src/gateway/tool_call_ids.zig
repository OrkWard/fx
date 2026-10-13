const std = @import("std");
const types = @import("../core/shared/types.zig");

const max_id_bytes = 64;

/// Request-local wire IDs. Source IDs remain borrowed and unchanged; generated
/// IDs are owned until deinit. Portable requests allocate nothing.
pub const Projection = struct {
    const Entry = struct { wire: []const u8, protected: bool };

    ids: std.StringHashMapUnmanaged(Entry) = .empty,
    owned: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: std.mem.Allocator, messages: []const types.ChatMessage) !Projection {
        var needed = false;
        var opaque_history = false;
        for (messages) |message| {
            if (message.role == .tool) {
                const id = message.tool_call_id orelse return error.InvalidToolCallId;
                if (id.len == 0) return error.InvalidToolCallId;
                needed = needed or !portable(id);
            }
            if (message.role != .assistant) continue;
            opaque_history = opaque_history or message.provider_replay != null;
            for (message.tool_calls) |call| {
                if (call.id.len == 0) return error.InvalidToolCallId;
                if (portable(call.id)) continue;
                needed = true;
            }
        }
        if (!needed) return .{};

        var self: Projection = .{};
        errdefer self.deinit(alloc);
        for (messages) |message| {
            if (message.role == .assistant) {
                for (message.tool_calls) |call| {
                    const entry = try self.ids.getOrPut(alloc, call.id);
                    const protected = call.provenance == .provider_executed or message.provider_replay != null;
                    if (!entry.found_existing) entry.value_ptr.* = .{ .wire = call.id, .protected = false };
                    entry.value_ptr.protected = entry.value_ptr.protected or protected;
                }
            }
            if (message.role == .tool) {
                const id = message.tool_call_id.?;
                const entry = try self.ids.getOrPut(alloc, id);
                if (!entry.found_existing) entry.value_ptr.* = .{ .wire = id, .protected = false };
            }
        }
        for (messages) |message| {
            if (message.role != .assistant) continue;
            for (message.tool_calls) |call| {
                if (portable(self.resolve(call.id))) continue;
                if (call.provenance == .provider_executed or message.provider_replay != null) continue;
                if (self.ids.get(call.id).?.protected) return error.ProtectedToolCallId;
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(call.id, &digest, .{});
                const hex = std.fmt.bytesToHex(digest[0..20].*, .lower);
                const attempts = try std.math.add(usize, self.ids.count(), 1);
                for (0..attempts) |attempt| {
                    var buffer: [max_id_bytes]u8 = undefined;
                    const candidate = try std.mem.print(&buffer, "fx_{s}_{d}", .{ &hex, attempt });
                    if (self.ids.contains(candidate)) {
                        // Opaque state may refer to an alias from an earlier request.
                        if (opaque_history) return error.ProtectedToolCallId;
                        continue;
                    }
                    const alias = try alloc.dupe(u8, candidate);
                    errdefer alloc.free(alias);
                    try self.ids.ensureUnusedCapacity(alloc, 1);
                    try self.owned.ensureUnusedCapacity(alloc, 1);
                    self.ids.putAssumeCapacity(alias, .{ .wire = alias, .protected = false });
                    self.ids.getPtr(call.id).?.wire = alias;
                    self.owned.appendAssumeCapacity(alias);
                    break;
                } else return error.ToolCallIdMappingExhausted;
            }
        }
        for (messages) |message| {
            if (message.role == .tool) {
                const entry = self.ids.get(message.tool_call_id.?).?;
                if (!entry.protected and !portable(entry.wire)) return error.InvalidToolCallId;
            }
        }
        return self;
    }

    pub fn deinit(self: *Projection, alloc: std.mem.Allocator) void {
        self.ids.deinit(alloc);
        for (self.owned.items) |id| alloc.free(id);
        self.owned.deinit(alloc);
    }

    /// The result borrows either source or this projection's storage.
    pub fn resolve(self: *const Projection, source: []const u8) []const u8 {
        return if (self.ids.get(source)) |entry| entry.wire else source;
    }
};

fn portable(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_bytes) return false;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

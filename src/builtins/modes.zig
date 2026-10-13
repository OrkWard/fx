const mode_contract = @import("../core/modes/mode_contract.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");

pub const ModeSpec = mode_contract.ModeSpec;
pub const default_mode_id = "auto";

/// The CLI's `/permissions` modes, in display order.
pub const all = [_]ModeSpec{
    .{ .id = "auto", .name = "Auto", .description = "Check actions with an automatic safety review instead of asking", .permission_mode = .auto },
    .{ .id = "ask", .name = "Ask", .description = "Request permission before making any changes", .permission_mode = .ask },
    .{ .id = "full-access", .name = "Full access", .description = "Run every action without asking, outside the sandbox", .permission_mode = .yolo },
};

pub const registry = mode_registry.Registry{
    .default_mode_id = default_mode_id,
    .modes = all[0..],
};

pub fn lookup(id: []const u8) ?*const ModeSpec {
    return registry.lookup(id);
}

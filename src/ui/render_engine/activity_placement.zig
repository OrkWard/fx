const activity_runtime = @import("../../core/output/activity_runtime.zig");
const activity_overlay = @import("activity_overlay.zig");
const frame_layout = @import("frame_layout.zig");

pub fn resolve(
    projection: activity_runtime.ActivityProjection,
    activity: frame_layout.ActivityState,
    layout: frame_layout.FrameLayout,
) activity_overlay.ActivityPlacement {
    return switch (projection) {
        .none => .none,
        .tool_slot => |slot| if (slot.active)
            resolveToolSlot(slot, activity, layout)
        else
            .none,
        .turn_thinking => resolveTransient(activity, layout),
    };
}

fn resolveToolSlot(
    slot: activity_runtime.ActivityProjection.ToolSlot,
    activity: frame_layout.ActivityState,
    layout: frame_layout.FrameLayout,
) activity_overlay.ActivityPlacement {
    const placement = resolveTransient(activity, layout);
    if (slot.thinking_label == null) return placement;
    return switch (placement) {
        .transient_row => |transient| if (layout.tool_activity_row) |tool_row|
            .{ .transient_row = .{
                .row = transient.row,
                .row_count = transient.row_count,
                .gap_above_rows = transient.gap_above_rows,
                .footer_clearance_rows = transient.footer_clearance_rows,
                .tool_row = tool_row,
            } }
        else
            placement,
        .none, .overlay_entry => placement,
    };
}

fn resolveTransient(
    activity: frame_layout.ActivityState,
    layout: frame_layout.FrameLayout,
) activity_overlay.ActivityPlacement {
    return switch (activity) {
        .thinking => |thinking| if (layout.activity_row) |row|
            .{ .transient_row = .{
                .row = row,
                .row_count = @max(layout.activity_rows, 1),
                .gap_above_rows = thinking.gap_above_activity,
                .footer_clearance_rows = thinking.footer_gap_after_activity,
            } }
        else
            .none,
        .overlay_entry => |row| if (layout.transcript_area.containsRow(row))
            .{ .overlay_entry = row }
        else
            .none,
        .none => .none,
    };
}

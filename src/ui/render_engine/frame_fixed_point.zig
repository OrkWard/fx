const debug_trace = @import("../../core/shared/debug_trace.zig");
const frame_layout = @import("frame_layout.zig");
const frame_scroll_plan = @import("frame_scroll_plan.zig");

pub const CandidatePreparation = struct {
    inline_advance_rows: u16,
    occupied_transcript_rows: u16,
};

pub const CandidateResolution = struct {
    occupied_transcript_rows: u16,
};

pub const FramePlan = struct {
    layout: frame_layout.FrameLayout,
    scroll_plan: frame_scroll_plan.FrameScrollPlan,
    iterations: usize,
};

pub fn solve(
    comptime Context: type,
    ctx: *Context,
    input: frame_layout.SolveInput,
    prepare_candidate: *const fn (*Context, frame_layout.FrameLayout) anyerror!CandidatePreparation,
    resolve_candidate: *const fn (*Context, frame_layout.FrameLayout, frame_scroll_plan.FrameScrollPlan) anyerror!CandidateResolution,
) !FramePlan {
    var release_floor_rows: u16 = 0;
    var candidate_input = input;
    var previous_candidate: ?struct {
        owned_top: u16,
        effective_transcript_rows: u16,
    } = null;
    var iteration: usize = 0;

    while (true) {
        iteration += 1;
        const layout_release = frame_layout.solveWithPreservedRowRelease(candidate_input, release_floor_rows);
        const candidate = layout_release.layout;
        if (previous_candidate) |previous| {
            const owner_released = candidate.owned_top < previous.owned_top;
            const extent_reduced = candidate_input.transcript.natural_visual_rows < previous.effective_transcript_rows;
            if (candidate.owned_top > previous.owned_top or
                candidate_input.transcript.natural_visual_rows > previous.effective_transcript_rows or
                (!owner_released and !extent_reduced))
            {
                return error.InvalidFrameScrollPlan;
            }
        }
        const preparation = try prepare_candidate(ctx, candidate);
        const scroll_plan = frame_scroll_plan.merge(
            candidate_input.terminal.rows,
            candidate_input.owned_top,
            layout_release.released_rows,
            preparation.inline_advance_rows,
        );
        const prepared_projection_is_shorter = preparation.occupied_transcript_rows > 0 and
            preparation.occupied_transcript_rows < candidate.transcript_area.height();
        const resolution = if (prepared_projection_is_shorter)
            CandidateResolution{ .occupied_transcript_rows = preparation.occupied_transcript_rows }
        else
            try resolve_candidate(ctx, candidate, scroll_plan);
        debug_trace.logf(
            "frame_layout",
            "fixed_point iteration={d} requested_release={d} requested_inline={d} emitted_scroll={d} remaining_inline={d} prior_owned_top={d} post_scroll_owned_top={d}",
            .{
                iteration,
                scroll_plan.requested_release_rows,
                scroll_plan.requested_inline_advance_rows,
                scroll_plan.terminal_scroll_rows,
                scroll_plan.remaining_inline_advance_rows,
                scroll_plan.prior_owned_top,
                scroll_plan.post_scroll_owned_top,
            },
        );
        const projection_is_shorter = resolution.occupied_transcript_rows > 0 and
            resolution.occupied_transcript_rows < candidate.transcript_area.height();
        if (candidate.owned_top == scroll_plan.post_scroll_owned_top and !projection_is_shorter) {
            return .{
                .layout = candidate,
                .scroll_plan = scroll_plan,
                .iterations = iteration,
            };
        }
        previous_candidate = .{
            .owned_top = candidate.owned_top,
            .effective_transcript_rows = candidate_input.transcript.natural_visual_rows,
        };
        if (projection_is_shorter) {
            candidate_input.transcript.natural_visual_rows = resolution.occupied_transcript_rows;
        }
        release_floor_rows = scroll_plan.preserved_release_rows;
    }
}

const std = @import("std");
const credentials = @import("../auth/credentials.zig");
const secret = @import("../auth/secret.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const image_attachments = @import("../images/image_attachments.zig");
const context_contract = @import("../workspace/context_contract.zig");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const permission_request = @import("../permissions/permission_request.zig");
const notification_contract = @import("../notifications/notification_contract.zig");
const session_runtime = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const compactor = @import("../compactor/compactor.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const assistant_presentation = @import("assistant_presentation.zig");
const compaction_activity = @import("../output/compaction_activity.zig");

pub const AgentTurnSettings = struct {
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    auto_compact_percent: u8 = compactor.default_percent,
    first_call_tool_choice: types.ToolChoice = .auto,
    fast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
};

pub const SkillBinding = struct {
    name: []u8,
    path: []u8,
};

pub const SkillDisplaySpan = struct {
    raw_start: usize,
    raw_end: usize,
    name: []u8,
    path: []u8,
    display_source: ?skill_contract.SkillSource = null,
    owns_trailing_separator: bool = false,
};

pub const BeginPromptWithSkillBindings = struct {
    prompt: types.UserTurn,
    skill_bindings: []SkillBinding = &.{},
    skill_display_spans: []SkillDisplaySpan = &.{},
};

pub const PromptDelivery = union(enum) {
    ordinary,
    active_turn: u64,
    continuation,

    pub fn activeTurnId(self: PromptDelivery) ?u64 {
        return switch (self) {
            .active_turn => |turn_id| turn_id,
            .ordinary, .continuation => null,
        };
    }

    pub fn isSteering(self: PromptDelivery) bool {
        return switch (self) {
            .ordinary => false,
            .active_turn, .continuation => true,
        };
    }

    pub fn isContinuation(self: PromptDelivery) bool {
        return self == .continuation;
    }
};

pub const SteeringBoundaryKind = enum {
    model,
    cancelled,
    finalizing,
};

const SteeringDelivery = types.SteeringDelivery;

/// Borrowed by the queue. Its owner outlives worker teardown.
pub const SteeringReceipt = struct {
    operation_id: []const u8 = "",
    state: std.atomic.Value(SteeringDelivery) = .init(.queued),
};

pub const SteeringBoundaryResult = union(enum) {
    none,
    continue_turn: [][]u8,
    handoff,
    interrupt,
};

pub const QueuedPrompt = struct {
    turn_id: u64 = 0,
    steering_receipt: ?*SteeringReceipt = null,
    /// Runtime-derived delivery state. The worker retains ownership in every state.
    delivery: PromptDelivery = .ordinary,
    prompt: []u8,
    images: []types.ImageAttachment,
    authorized_image_catalog: []types.ImageAttachment = &.{},
    model: []u8,
    provider: model_provider.ProviderId = .codex,
    api_key: []u8,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]u8 = null,
    permission_mode: types.PermissionMode,
    history: []types.HistoryTurn,
    /// Absolute end of the leading canonical-history range loaded without
    /// corrected result provenance. The conservative default protects callers
    /// that do not own a SessionRuntime snapshot.
    unversioned_history_count: usize = std.math.maxInt(usize),
    root_user_intent_context: []u8 = &.{},
    grants: []types.PermissionGrant,
    skill_bindings: []SkillBinding = &.{},
    skill_display_spans: []SkillDisplaySpan = &.{},
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    agent_settings: AgentTurnSettings = .{},
    snapshot_file_ownerships: []types.SnapshotFileOwnership = &.{},
    /// Present only when an explicit host action resumes a durable paused
    /// model turn. The same ownership rules as the other queued fields apply.
    recovery_checkpoint: ?session_codec.RecoveryCheckpoint = null,
    /// True when this output surface already contains the checkpoint's
    /// assistant source. Recovery still restores the source for overlap and
    /// persistence, but publishes only novel continuation text.
    recovery_source_already_presented: bool = false,
    /// The interactive transcript already contains this exact user turn.
    /// Worker begin publishes only its identity so the UI can consume the
    /// pending owner without painting a duplicate card.
    user_prompt_already_presented: bool = false,
};

pub const ContextCompactionTask = struct {
    turn_id: u64 = 0,
    operation_id: ?compaction_activity.OperationId = null,
    model: []u8,
    provider: model_provider.ProviderId = .codex,
    api_key: []u8,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]u8 = null,
    history: []types.HistoryTurn,
    unversioned_history_count: usize = std.math.maxInt(usize),
};

pub const ContextCompactionStatus = enum {
    idle,
    queued,
    running,
};

pub const WorkItem = union(enum) {
    prompt: QueuedPrompt,
    compact_context: ContextCompactionTask,
};

pub const ActivePromptSnapshotOwnership = struct {
    /// Owns snapshot deletion until the files are transferred to accepted
    /// history or handed to a reference-counted finished-turn owner.
    images: []const types.ImageAttachment,
    state: enum {
        active,
        handed_off,
        preserved,
        discarded,
    } = .active,
    shared_ownership: ?types.SnapshotFileOwnership = null,

    pub fn init(images: []const types.ImageAttachment) ActivePromptSnapshotOwnership {
        return .{ .images = images };
    }

    fn ensureSharedOwnership(
        self: *ActivePromptSnapshotOwnership,
        alloc: std.mem.Allocator,
    ) !?types.SnapshotFileOwnership {
        if (self.images.len == 0) return null;
        if (self.state == .preserved or self.state == .discarded) return null;
        if (self.shared_ownership) |ownership| return ownership;
        const ownership = (try SnapshotFileOwnershipState.create(alloc, self.images)).handle();
        self.shared_ownership = ownership;
        return ownership;
    }

    fn handoff(
        self: *ActivePromptSnapshotOwnership,
        alloc: std.mem.Allocator,
    ) !?types.SnapshotFileOwnership {
        if (self.state != .active or self.images.len == 0) return null;
        const ownership = (try self.ensureSharedOwnership(alloc)).?;
        self.state = .handed_off;
        return ownership;
    }

    fn preserve(self: *ActivePromptSnapshotOwnership) bool {
        if (self.images.len == 0) return false;
        switch (self.state) {
            .active => {
                if (self.shared_ownership) |ownership| {
                    ownership.transfer();
                    ownership.release();
                    self.shared_ownership = null;
                }
                self.state = .preserved;
                return true;
            },
            .handed_off => {
                if (self.shared_ownership) |ownership| ownership.transfer();
                return true;
            },
            .preserved => return true,
            .discarded => return false,
        }
    }

    fn deinit(self: *ActivePromptSnapshotOwnership) void {
        if (self.state == .active) {
            if (self.shared_ownership) |ownership| {
                ownership.release();
            } else {
                image_attachments.deleteUnreferencedImageSnapshots(self.images, &.{});
            }
            self.state = .discarded;
        }
    }
};

const SnapshotFileOwnershipState = struct {
    alloc: std.mem.Allocator,
    images: []types.ImageAttachment,
    references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    transferred: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn create(
        alloc: std.mem.Allocator,
        images: []const types.ImageAttachment,
    ) !*SnapshotFileOwnershipState {
        const owned_images = try types.dupeImageAttachmentSlice(alloc, images);
        errdefer types.freeImageAttachmentSlice(alloc, owned_images);
        const state = try alloc.create(SnapshotFileOwnershipState);
        state.* = .{
            .alloc = alloc,
            .images = owned_images,
        };
        return state;
    }

    fn handle(self: *SnapshotFileOwnershipState) types.SnapshotFileOwnership {
        return .{
            .ctx = self,
            .retain_fn = retain,
            .release_fn = release,
            .transfer_fn = transfer,
        };
    }

    fn retain(raw: *anyopaque) void {
        const self: *SnapshotFileOwnershipState = @ptrCast(@alignCast(raw));
        _ = self.references.fetchAdd(1, .seq_cst);
    }

    fn release(raw: *anyopaque) void {
        const self: *SnapshotFileOwnershipState = @ptrCast(@alignCast(raw));
        if (self.references.fetchSub(1, .seq_cst) != 1) return;
        if (!self.transferred.load(.seq_cst)) {
            image_attachments.deleteUnreferencedImageSnapshots(self.images, &.{});
        }
        const alloc = self.alloc;
        types.freeImageAttachmentSlice(alloc, self.images);
        alloc.destroy(self);
    }

    fn transfer(raw: *anyopaque) void {
        const self: *SnapshotFileOwnershipState = @ptrCast(@alignCast(raw));
        self.transferred.store(true, .seq_cst);
    }
};

fn historyTurnImages(turn: types.HistoryTurn) []const types.ImageAttachment {
    return switch (turn) {
        .assistant => |value| value.user.images,
        .interrupted => |value| value.user.images,
        .compacted_summary => &.{},
    };
}

fn sameImageSnapshots(
    left: []const types.ImageAttachment,
    right: []const types.ImageAttachment,
) bool {
    if (left.len == 0 or left.len != right.len) return false;
    for (left) |image| {
        const other = image_attachments.findById(right, image.id) orelse return false;
        if (!optionalBytesEqual(image.snapshot_path, other.snapshot_path) or
            !optionalBytesEqual(image.snapshot_sha256, other.snapshot_sha256))
        {
            return false;
        }
    }
    return true;
}

fn optionalBytesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

pub const PermissionSnapshot = struct {
    mode: types.PermissionMode,
};

pub const CommandOutputChunk = struct {
    lifecycle_id: ?types.ToolLifecycleId = null,
    stream: command_output_content.Stream,
    text: []u8,
};

pub const SteeringPresentationSnapshot = struct {
    messages: [][]u8 = &.{},
    pending_feedback: [][]u8 = &.{},
    waits_for_boundary: bool = false,

    pub fn deinit(self: *SteeringPresentationSnapshot, alloc: std.mem.Allocator) void {
        for (self.messages) |message| alloc.free(message);
        if (self.messages.len > 0) alloc.free(self.messages);
        for (self.pending_feedback) |message| alloc.free(message);
        if (self.pending_feedback.len > 0) alloc.free(self.pending_feedback);
        self.* = .{};
    }
};

const PreparedHistoryPropagation = struct {
    root_user_intent_context: []u8,
    authorized_image_catalog: []types.ImageAttachment,
    snapshot_file_ownerships: ?[]types.SnapshotFileOwnership,
    added_snapshot_ownership: ?types.SnapshotFileOwnership,

    fn deinit(self: PreparedHistoryPropagation, alloc: std.mem.Allocator) void {
        alloc.free(self.root_user_intent_context);
        types.freeImageAttachmentSlice(alloc, self.authorized_image_catalog);
        if (self.added_snapshot_ownership) |ownership| ownership.release();
        if (self.snapshot_file_ownerships) |ownerships| alloc.free(ownerships);
    }
};

pub const StateSnapshot = struct {
    processing: bool = false,
    active_turn_id: u64 = 0,
    queued_count: usize = 0,
    pending_event_count: usize = 0,
    cancel_requested: bool = false,
    cancel_continues_turn: bool = false,
    pending_permission_request: ?permission_request.OwnedPermissionRequest = null,
    pending_permission_review: ?PendingPermissionReview = null,

    pub fn deinit(self: StateSnapshot, alloc: std.mem.Allocator) void {
        if (self.pending_permission_request) |request| {
            var owned = request;
            owned.deinit(alloc);
        }
    }
};

pub const PendingPermissionReview = struct {
    request_id: u64,
    review: *const diff_mod.FileReview,
};

pub const FinalizationFailure = struct {
    turn_id: u64,
    outcome: types.TurnPresentationOutcome,
};

pub const InteractiveAdmissionSnapshot = union(enum) {
    open,
    stopped,
    finalization_failed: FinalizationFailure,
};

pub const PermissionSubmissionResult = enum {
    accepted,
    stale,
    no_pending,
};

const OwnedQuestionOption = struct {
    label: []u8,
    description: ?[]u8 = null,
};

const OwnedQuestionEntry = struct {
    question: []u8,
    options: []OwnedQuestionOption,
    submission: @FieldType(types.QuestionBatchEntry, "submission") = .none,
};

pub const QuestionPromptSource = enum {
    agent_question,
    route_recovery,
};

const OwnedQuestionBatch = struct {
    entries: []OwnedQuestionEntry,
    source: QuestionPromptSource = .agent_question,
};

const QuestionResponse = union(enum) {
    pending,
    cancelled,
    answered: [][]u8,
};

pub const PendingQuestionBatchSnapshot = struct {
    entries: []types.QuestionBatchEntry,
    source: QuestionPromptSource = .agent_question,

    pub fn deinit(self: PendingQuestionBatchSnapshot, alloc: std.mem.Allocator) void {
        for (self.entries) |entry| {
            alloc.free(@constCast(entry.question));
            for (entry.options) |opt| {
                alloc.free(@constCast(opt.label));
                if (opt.description) |desc| alloc.free(@constCast(desc));
            }
            alloc.free(@constCast(entry.options));
        }
        alloc.free(self.entries);
    }
};

pub const ContextCompaction = struct {
    turn_id: u64 = 0,
    summary: types.CompactedSummaryHistoryTurn,
    active_prefix: ?types.AssistantHistoryTurn = null,
    retained_from: ?types.ContextHistoryCut = null,
    max_history_turns: usize = 0,
};

pub const ContextCompactionHandler = *const fn (*anyopaque, ContextCompaction) anyerror!void;

pub const FreshPromptPreparation = struct {
    turn_id: u64 = 0,
    user: types.UserTurn,
    prior_turn: ?types.HistoryTurn = null,
};

pub const FreshPromptHistory = struct {
    history: []types.HistoryTurn,
    authorized_image_catalog: []types.ImageAttachment,
    root_user_intent_context: []u8,
    unversioned_history_count: usize,

    pub fn deinit(self: *FreshPromptHistory, alloc: std.mem.Allocator) void {
        types.freeHistoryTurnSlice(alloc, self.history);
        types.freeImageAttachmentSlice(alloc, self.authorized_image_catalog);
        alloc.free(self.root_user_intent_context);
        self.* = undefined;
    }
};

pub const FreshPromptHandler = *const fn (*anyopaque, FreshPromptPreparation) anyerror!FreshPromptHistory;

const HistoryPublication = struct {
    ctx: *anyopaque,
    commit_fn: *const fn (*anyopaque) anyerror!void,
    retained_from: ?types.ContextHistoryCut = null,

    fn commit(self: HistoryPublication) !void {
        try self.commit_fn(self.ctx);
    }
};

const ContextCompactionPublication = struct {
    ctx: *anyopaque,
    handler: ContextCompactionHandler,
    event: ContextCompaction,

    fn commit(raw: *anyopaque) !void {
        const self: *ContextCompactionPublication = @ptrCast(@alignCast(raw));
        try self.handler(self.ctx, self.event);
    }
};

const HistoryPublicationResponse = union(enum) {
    idle,
    waiting: u64,
    committed: ?FreshPromptHistory,
    failed: anyerror,
};

pub const WorkerEvent = union(enum) {
    begin_prompt: types.UserTurn,
    begin_prompt_with_skill_bindings: BeginPromptWithSkillBindings,
    begin_presented_prompt: u64,
    append_user_feedback: []u8,
    assistant_presentation: assistant_presentation.Event,
    notification: notification_contract.Notification,
    question_requested,
    open_model_picker,
    semantic_notice: types.SemanticNotice,
    /// A full-only observability record (network call outcome) for the ctrl+o
    /// full transcript's detail section. Never enters the transcript store.
    full_detail_record: types.SemanticNotice,
    route_recovery_status: types.RouteRecoveryStatus,
    clear_route_recovery_status,
    /// The gateway provider that served a request in this turn (display-only,
    /// last value wins). Owned by the event; the consumer frees it.
    provider_resolved: []u8,
    api_status_text: []u8,
    credential_refreshed: credentials.Credential,
    command_output: CommandOutputChunk,
    command_output_complete: ?types.ToolLifecycleId,
    tool_lifecycle: types.ToolLifecycleEvent,
    turn_token_update: types.TurnTokenProgress,
    turn_phase_update: types.TurnPhaseUpdate,
    diff_block: diff_mod.DiffEntryPayload,
    context_compaction: ContextCompaction,
    prepare_fresh_prompt: FreshPromptPreparation,
    finish_prompt: types.FinishedPrompt,
    session_grant: types.PermissionGrant,
    error_text: types.SemanticNotice,
    /// A turn that can never recover hands the prompt back to the composer.
    /// Owned by the event; the consumer frees it.
    restore_failed_prompt: []u8,
};

pub const WorkerEventBatch = struct {
    events: std.ArrayList(WorkerEvent),
    cancelled_turn_id: ?u64,
};

pub const WorkerRuntime = struct {
    worker_mutex: std.Io.Mutex = .init,
    worker_cond: std.Io.Condition = .init,
    /// One admission-ordered queue for ordinary prompts and steering. Steering
    /// remains in place until its target turn consumes or demotes it.
    queued_prompts: std.ArrayList(QueuedPrompt) = .empty,
    /// One immutable conversation snapshot shared by every queued prompt.
    /// It is transferred or copied only when a prompt actually begins.
    queued_history: []types.HistoryTurn = &.{},
    queued_context_compaction: ?ContextCompactionTask = null,
    active_context_compaction: bool = false,
    history_publication_response: HistoryPublicationResponse = .idle,
    worker_events: std.ArrayList(WorkerEvent) = .empty,
    worker_processing: bool = false,
    active_turn_id: u64 = 0,
    active_tool_calls: std.StringHashMapUnmanaged(void) = .empty,
    /// Allocator used for active call IDs. Allocator handles are capabilities,
    /// not comparable identities; callers guarantee compatible ownership.
    active_tool_allocator: ?std.mem.Allocator = null,
    /// Retains the tool-producing step so later text from that same step cannot
    /// reopen immediate steering before authoritative lifecycle IDs exist.
    tool_phase_step_id: ?u64 = null,
    worker_stop_requested: bool = false,
    finalization_failure: ?FinalizationFailure = null,
    worker_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The active turn whose text steering admission owns the cancel flag.
    /// Guarded by `worker_mutex`; explicit cancellation clears this ownership.
    steering_cancel_turn_id: ?u64 = null,
    direct_steering_closed: bool = false,
    worker_recovery_pause_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_connectivity_wait_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set under `worker_mutex` once the active turn publishes its terminal
    /// recovery pause. The turn may still be finalizing, but cannot perform
    /// more model work, so one continuation may queue before processing clears.
    recovery_continuation_ready: bool = false,
    /// When true, queued work will not start.
    turn_start_held: bool = false,
    /// Independent of a pending submission's turn-start hold; protects queued
    /// work until a fresh-session scrollback handoff succeeds or is cancelled.
    session_transition_held: bool = false,
    next_permission_request_id: u64 = 1,
    pending_permission_response: ?permission_request.OwnedPermissionResponse = null,
    pending_permission_request_shared: ?permission_request.OwnedPermissionRequest = null,
    pending_permission_review: ?*const diff_mod.FileReview = null,
    pending_permission_waiting: bool = false,
    pending_question_shared: ?OwnedQuestionBatch = null,
    pending_question_response: QuestionResponse = .pending,
    agent_turn_settings: AgentTurnSettings = .{},
    active_agent_turn_settings: ?AgentTurnSettings = null,
    active_context_snapshot: ?*const context_contract.GatheredContextSnapshot = null,
    active_prompt_is_root_authority: bool = false,
    active_prompt_snapshot_ownership: ?*ActivePromptSnapshotOwnership = null,
    preserve_prompt_snapshot_turn_id: ?u64 = null,

    /// Presentation metadata only; all access is protected by worker_mutex.
    compaction_presentation: compaction_activity.State = .{},

    pub fn beginCompactionActivity(self: *WorkerRuntime, origin: compaction_activity.Origin, turn_id: ?u64) compaction_activity.OperationId {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.compaction_presentation.begin(origin, turn_id, io_mod.milliTimestamp());
    }

    /// A rejected intent must not hide an already-running compaction.
    pub fn rejectCompactionActivity(self: *WorkerRuntime, outcome: compaction_activity.Outcome) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.compaction_presentation.snapshot.operation) |op| if (op.active()) return;
        const now = io_mod.milliTimestamp();
        const id = self.compaction_presentation.begin(.manual, null, now);
        self.compaction_presentation.settle(id, .{ .outcome = outcome }, now);
    }

    pub fn runCompactionActivity(self: *WorkerRuntime, id: compaction_activity.OperationId, stage: compaction_activity.Stage) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.compaction_presentation.running(id, stage);
    }

    pub fn settleCompactionActivity(self: *WorkerRuntime, id: compaction_activity.OperationId, feedback: compaction_activity.Feedback) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.compaction_presentation.settle(id, feedback, io_mod.milliTimestamp());
    }

    /// Cheap by-value read; does not clone permissions or allocate.
    pub fn compactionActivitySnapshot(self: *WorkerRuntime) compaction_activity.Snapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.compaction_presentation.snapshot;
    }

    pub fn dismissCompactionActivity(self: *WorkerRuntime, id: compaction_activity.OperationId, revision: u64) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.compaction_presentation.dismiss(id, revision);
    }

    pub fn expireCompactionActivity(self: *WorkerRuntime, id: compaction_activity.OperationId, revision: u64, now_ms: i64) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.compaction_presentation.expire(id, revision, now_ms);
    }

    fn stopCompactionActivityLocked(self: *WorkerRuntime) void {
        const op = self.compaction_presentation.snapshot.operation orelse return;
        if (op.turn_id != self.active_turn_id or !self.worker_processing) return;
        self.compaction_presentation.stopping(op.id);
    }

    fn finishCompactionActivityLocked(self: *WorkerRuntime, turn_id: u64) void {
        const op = self.compaction_presentation.snapshot.operation orelse return;
        if (op.turn_id != turn_id or !op.active()) return;
        compactor.traceLog(true, "unsettled operation at worker finish turn_id={d}", .{turn_id});
        var feedback = compaction_activity.failure(
            if (self.isCancelRequested()) error.Cancelled else error.CompactionInterrupted,
            op.stage(),
            self.isCancelRequested(),
        );
        // No transaction acknowledgement survived this fallback; do not promise rollback.
        if (op.stage() == .publication) feedback.publication = .uncertain;
        self.compaction_presentation.settle(op.id, feedback, io_mod.milliTimestamp());
    }

    fn queuedWorkCountLocked(self: *const WorkerRuntime) usize {
        return self.queued_prompts.items.len +
            @intFromBool(self.queued_context_compaction != null);
    }

    pub fn deinit(self: *WorkerRuntime, alloc: std.mem.Allocator) void {
        if (self.pending_permission_response) |response| {
            self.discardPermissionResponse(response, "deinit");
        }
        self.pending_permission_response = null;
        if (self.pending_permission_request_shared) |*request| request.deinit(alloc);
        self.pending_permission_request_shared = null;
        self.pending_permission_review = null;
        freeOwnedQuestionBatchOpt(alloc, self.pending_question_shared);
        self.pending_question_shared = null;
        freeQuestionResponse(alloc, self.pending_question_response);
        self.pending_question_response = .pending;

        for (self.queued_prompts.items) |prompt| discardQueuedPrompt(alloc, prompt, &.{});
        self.queued_prompts.deinit(alloc);
        types.freeHistoryTurnSlice(alloc, self.queued_history);
        if (self.queued_context_compaction) |task| freeContextCompactionTask(alloc, task);

        self.clearActiveToolCallsLocked();

        for (self.worker_events.items) |event| freeWorkerEvent(alloc, event);
        self.worker_events.deinit(alloc);
    }

    pub fn requestStop(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        self.worker_stop_requested = true;
        if (self.queued_context_compaction) |task| {
            if (task.operation_id) |id| self.compaction_presentation.settle(id, .{ .outcome = .cancelled }, io_mod.milliTimestamp());
        }
        self.stopCompactionActivityLocked();
        self.worker_cond.broadcast(io_mod.getIo());
        self.worker_mutex.unlock(io_mod.getIo());
    }

    pub fn requestShutdown(self: *WorkerRuntime) void {
        self.markExplicitCancellation();
        self.requestStop();
    }

    pub fn requestCancel(self: *WorkerRuntime) void {
        debug_trace.logf("worker", "cancel requested processing={s} queued={d}", .{ if (self.worker_processing) "true" else "false", self.queuedPromptCount() });
        debug_trace.eventf("interrupt", "cancel_requested", .{}, "processing={s} queued={d} active_tool_known=false", .{ if (self.worker_processing) "true" else "false", self.queuedPromptCount() });
        self.markExplicitCancellation();
    }

    /// Interrupt the current gateway wait while preserving its recovery
    /// checkpoint. The ordinary cancel flag wakes the existing socket watcher;
    /// agent policy distinguishes the typed pause flag at the boundary.
    pub fn requestRecoveryPause(self: *WorkerRuntime) void {
        debug_trace.eventf("recovery", "pause_requested", .{}, "source=interactive_try_later", .{});
        self.worker_recovery_pause_requested.store(true, .seq_cst);
        self.markExplicitCancellation();
    }

    fn markExplicitCancellation(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.steering_cancel_turn_id = null;
        self.worker_cancel_requested.store(true, .seq_cst);
        self.stopCompactionActivityLocked();
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn requestInteractiveCancel(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        const steering_pending = for (self.queued_prompts.items) |prompt| {
            if (prompt.delivery.activeTurnId() == self.active_turn_id or
                prompt.delivery.isContinuation()) break true;
        } else false;
        debug_trace.logf("worker", "cancel requested processing={s} queued={d} steering_pending={s}", .{
            if (self.worker_processing) "true" else "false",
            self.queuedWorkCountLocked(),
            if (steering_pending) "true" else "false",
        });
        debug_trace.eventf("interrupt", "cancel_requested", .{}, "processing={s} queued={d} steering_pending={s} active_tool_known=false", .{
            if (self.worker_processing) "true" else "false",
            self.queuedWorkCountLocked(),
            if (steering_pending) "true" else "false",
        });
        self.steering_cancel_turn_id = null;
        self.worker_cancel_requested.store(true, .seq_cst);
        self.stopCompactionActivityLocked();
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn cancelApprovalTurn(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        self.steering_cancel_turn_id = null;
        self.worker_cancel_requested.store(true, .seq_cst);
        self.stopCompactionActivityLocked();
        _ = self.resolvePendingPermissionLocked(
            permission_request.OwnedPermissionResponse.init(
                std.heap.c_allocator,
                .deny,
                null,
            ),
        );
    }

    pub fn isCancelRequested(self: *const WorkerRuntime) bool {
        return self.worker_cancel_requested.load(.seq_cst);
    }

    pub fn cancellationStopsTurn(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.worker_cancel_requested.load(.seq_cst) and
            self.steering_cancel_turn_id != self.active_turn_id;
    }

    pub fn isConnectivityWaitActive(self: *const WorkerRuntime) bool {
        return self.worker_connectivity_wait_active.load(.seq_cst);
    }

    pub fn pushEvent(self: *WorkerRuntime, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        const owned = try dupeWorkerEvent(alloc, event);
        errdefer freeWorkerEvent(alloc, owned);
        try self.pushOwnedEvent(alloc, owned);
    }

    /// Transfers an already-owned event into the queue on success.
    /// Every heap payload in `event` must have been allocated by `alloc`.
    pub fn pushOwnedEvent(self: *WorkerRuntime, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        try self.worker_events.ensureUnusedCapacity(alloc, 1);
        var tool_transition = try self.prepareActiveToolTransitionLocked(alloc, event);
        errdefer tool_transition.deinit(alloc);
        self.worker_events.appendAssumeCapacity(event);
        self.applyActiveToolTransitionLocked(tool_transition);
        self.applyToolBoundaryPhaseLocked(event);
        self.applyRecoveryStateEvent(event);
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// Transfers already-owned events to the front of the queue on success.
    /// Every heap payload must have been allocated by `alloc`.
    pub fn prependOwnedEvents(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        events: []const WorkerEvent,
    ) !void {
        if (events.len == 0) return;
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        try self.worker_events.insertSlice(alloc, 0, events);
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn pushTurnFinished(self: *WorkerRuntime, alloc: std.mem.Allocator, event: types.TurnFinished) !void {
        std.debug.assert(event.turn_id != 0);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.worker_events.append(alloc, .{ .tool_lifecycle = .{
            .turn_finished = event,
        } }) catch {
            self.latchFinalizationFailureLocked(.{
                .turn_id = event.turn_id,
                .outcome = event.outcome,
            });
            return error.TurnFinalizationDeliveryFailed;
        };
        self.applyRecoveryStateEvent(.{ .tool_lifecycle = .{
            .turn_finished = event,
        } });
        self.worker_cond.broadcast(io_mod.getIo());
    }

    fn applyRecoveryStateEvent(self: *WorkerRuntime, event: WorkerEvent) void {
        switch (event) {
            .route_recovery_status => |status| {
                self.worker_connectivity_wait_active.store(
                    status.action == .waiting_for_connectivity,
                    .seq_cst,
                );
                self.recovery_continuation_ready = status.action == .paused;
            },
            .clear_route_recovery_status,
            .finish_prompt,
            .error_text,
            => {
                self.worker_connectivity_wait_active.store(false, .seq_cst);
                self.recovery_continuation_ready = false;
            },
            .tool_lifecycle => |lifecycle| switch (lifecycle) {
                .turn_finished => self.worker_connectivity_wait_active.store(false, .seq_cst),
                .provisional, .authoritative_started, .progress, .terminal => return,
            },
            else => return,
        }
    }

    fn latchFinalizationFailureLocked(self: *WorkerRuntime, failure: FinalizationFailure) void {
        if (self.finalization_failure == null) {
            self.finalization_failure = failure;
        } else {
            debug_trace.logf(
                "worker",
                "duplicate finalization failure ignored turn_id={d} first_turn_id={d}",
                .{ failure.turn_id, self.finalization_failure.?.turn_id },
            );
        }
        self.worker_stop_requested = true;
        self.steering_cancel_turn_id = null;
        self.worker_cancel_requested.store(true, .seq_cst);
        self.stopCompactionActivityLocked();
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn interactiveAdmissionSnapshot(self: *WorkerRuntime) InteractiveAdmissionSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.finalization_failure) |failure| {
            return .{ .finalization_failed = failure };
        }
        if (self.worker_stop_requested) return .stopped;
        return .open;
    }

    pub fn takeEventBatch(self: *WorkerRuntime) WorkerEventBatch {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const events = self.worker_events;
        self.worker_events = .empty;
        return .{
            .events = events,
            .cancelled_turn_id = if (self.worker_cancel_requested.load(.seq_cst) and
                self.active_turn_id != 0 and
                self.steering_cancel_turn_id != self.active_turn_id)
                self.active_turn_id
            else
                null,
        };
    }

    pub fn takeEvents(self: *WorkerRuntime) std.ArrayList(WorkerEvent) {
        return self.takeEventBatch().events;
    }

    pub fn enqueuePrompt(self: *WorkerRuntime, alloc: std.mem.Allocator, prompt: QueuedPrompt) !void {
        try self.admitPrompt(alloc, prompt, false);
    }

    pub fn admitInteractivePrompt(self: *WorkerRuntime, alloc: std.mem.Allocator, prompt: QueuedPrompt) !void {
        try self.admitPrompt(alloc, prompt, true);
    }

    /// Takes prompt ownership only on true. Does not cancel an in-flight operation
    /// or fall back to the ordinary FIFO of an ephemeral direct worker.
    pub fn admitActiveSteering(self: *WorkerRuntime, alloc: std.mem.Allocator, prompt: QueuedPrompt) !bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.worker_processing or self.active_turn_id == 0 or
            self.direct_steering_closed or self.worker_stop_requested or
            self.worker_cancel_requested.load(.seq_cst)) return false;
        var queued = prompt;
        queued.delivery = .{ .active_turn = self.active_turn_id };
        try self.enqueuePromptLocked(alloc, queued);
        return true;
    }

    pub fn enqueueContextCompaction(
        self: *WorkerRuntime,
        task: ContextCompactionTask,
    ) !void {
        var queued = task;
        if (queued.turn_id == 0) queued.turn_id = debug_trace.nextTurnId();

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.finalization_failure != null) return error.TurnFinalizationDeliveryFailed;
        if (self.worker_stop_requested) return error.WorkerStopped;
        if (self.worker_processing or self.queued_prompts.items.len > 0 or
            self.queued_context_compaction != null)
        {
            return error.WorkerBusy;
        }
        if (queued.operation_id == null) queued.operation_id = self.compaction_presentation.begin(.manual, queued.turn_id, io_mod.milliTimestamp());
        self.compaction_presentation.queued(queued.operation_id.?, queued.turn_id, io_mod.milliTimestamp());
        self.queued_context_compaction = queued;
        debug_trace.eventf(
            "worker",
            "context_compaction_enqueue",
            .{ .turn_id = queued.turn_id },
            "queue_depth=1",
            .{},
        );
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn contextCompactionStatus(self: *WorkerRuntime) ContextCompactionStatus {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.active_context_compaction) return .running;
        if (self.queued_context_compaction != null) return .queued;
        return .idle;
    }

    pub fn cancelContextCompaction(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
    ) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        if (self.queued_context_compaction) |task| {
            self.queued_context_compaction = null;
            if (task.operation_id) |id| self.compaction_presentation.settle(id, .{ .outcome = .cancelled }, io_mod.milliTimestamp());
            self.worker_cond.broadcast(io_mod.getIo());
            self.worker_mutex.unlock(io_mod.getIo());
            freeContextCompactionTask(alloc, task);
            debug_trace.eventf(
                "context_compaction",
                "cancelled",
                .{},
                "phase=queued",
                .{},
            );
            return true;
        }
        if (self.active_context_compaction) {
            self.worker_cancel_requested.store(true, .seq_cst);
            self.stopCompactionActivityLocked();
            self.worker_cond.broadcast(io_mod.getIo());
            self.worker_mutex.unlock(io_mod.getIo());
            debug_trace.eventf(
                "context_compaction",
                "cancel_requested",
                .{},
                "phase=running",
                .{},
            );
            return true;
        }
        self.worker_mutex.unlock(io_mod.getIo());
        return false;
    }

    /// Transfers `prompt` to the active turn when steering is requested and the
    /// turn still accepts guidance. Otherwise it enters the ordinary FIFO.
    /// A steer interrupts the model stream immediately only when no wait
    /// boundary is active; a running tool or an in-flight compaction defers
    /// delivery to the next steering boundary instead of being cancelled.
    fn admitPrompt(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        prompt: QueuedPrompt,
        steer_if_active: bool,
    ) !void {
        var queued = prompt;
        if (queued.turn_id == 0) queued.turn_id = debug_trace.nextTurnId();

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.finalization_failure != null) return error.TurnFinalizationDeliveryFailed;
        if (self.worker_stop_requested) return error.WorkerStopped;
        if (queued.recovery_checkpoint != null and
            !recoveryContinuationAdmission(
                self.worker_processing,
                self.queuedWorkCountLocked(),
                self.recovery_continuation_ready,
            ))
        {
            return error.RecoveryBusy;
        }
        queued.agent_settings = self.agent_turn_settings;
        var interrupt_after_admission = false;
        const explicitly_cancelled = self.worker_cancel_requested.load(.seq_cst) and
            self.steering_cancel_turn_id != self.active_turn_id;
        if (steer_if_active and self.worker_processing and self.active_turn_id != 0 and
            !explicitly_cancelled)
        {
            queued.delivery = .{ .active_turn = self.active_turn_id };
            interrupt_after_admission = !self.hasSteeringWaitBoundaryLocked();
        }
        try self.enqueuePromptLocked(alloc, queued);
        if (steer_if_active and self.worker_processing) {
            debug_trace.eventf("worker", "steering_admission", .{ .turn_id = self.active_turn_id }, "queued_turn_id={d} targeted={} plain={} tool_boundary={} compaction_active={} interrupt_model={}", .{ queued.turn_id, queued.delivery.activeTurnId() == self.active_turn_id, sameTurnSteeringEligible(queued), self.hasActiveToolBoundaryLocked(), self.compactionInFlightLocked(), interrupt_after_admission });
        }
        if (interrupt_after_admission) {
            self.steering_cancel_turn_id = if (sameTurnSteeringEligible(queued))
                self.active_turn_id
            else
                null;
            self.worker_cancel_requested.store(true, .seq_cst);
        }
    }

    fn sameTurnSteeringEligible(prompt: QueuedPrompt) bool {
        return prompt.images.len == 0 and
            prompt.skill_bindings.len == 0 and
            prompt.skill_display_spans.len == 0;
    }

    fn enqueuePromptLocked(self: *WorkerRuntime, alloc: std.mem.Allocator, queued_value: QueuedPrompt) !void {
        var queued = queued_value;
        try self.queued_prompts.ensureUnusedCapacity(alloc, 1);
        const supplied_history = queued.history;
        queued.history = &.{};
        if (self.queued_prompts.items.len == 0) {
            std.debug.assert(self.queued_history.len == 0);
            self.queued_history = supplied_history;
        } else {
            types.freeHistoryTurnSlice(alloc, supplied_history);
        }
        self.queued_prompts.appendAssumeCapacity(queued);
        debug_trace.logf(
            "worker",
            "queued prompt bytes={d} queue_depth={d} fast_mode={s} effort={s}",
            .{ queued.prompt.len, self.queuedWorkCountLocked(), if (queued.agent_settings.fast_mode) "true" else "false", queued.agent_settings.effort.label() },
        );
        debug_trace.eventf(
            "worker",
            "prompt_enqueue",
            .{ .turn_id = queued.turn_id },
            "prompt_bytes={d} queue_depth={d} fast_mode={s} effort={s}",
            .{ queued.prompt.len, self.queuedWorkCountLocked(), if (queued.agent_settings.fast_mode) "true" else "false", queued.agent_settings.effort.label() },
        );
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn hasPendingPlainSteering(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.worker_processing or self.active_turn_id == 0 or self.worker_stop_requested) return false;
        var pending = false;
        for (self.queued_prompts.items) |prompt| {
            if (prompt.delivery.activeTurnId() != self.active_turn_id) continue;
            if (!sameTurnSteeringEligible(prompt)) return false;
            pending = true;
        }
        return pending;
    }

    /// Classifies and drains steering at one observed agent boundary. Returned
    /// text is allocator-owned; handoff leaves the queued prompt worker-owned.
    pub fn takeSteeringBoundary(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn_id: u64,
        kind: SteeringBoundaryKind,
    ) !SteeringBoundaryResult {
        return self.takeSteeringBoundaryInto(alloc, alloc, turn_id, kind);
    }

    /// Queue/event storage uses alloc; returned guidance uses result_alloc.
    pub fn takeSteeringBoundaryInto(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        result_alloc: std.mem.Allocator,
        turn_id: u64,
        kind: SteeringBoundaryKind,
    ) !SteeringBoundaryResult {
        const result = try self.takeSteeringBoundaryIntoInner(alloc, result_alloc, turn_id, kind);
        debug_trace.eventf("worker", "steering_boundary_check", .{ .turn_id = turn_id }, "kind={s} outcome={s}", .{ @tagName(kind), @tagName(result) });
        return result;
    }

    fn takeSteeringBoundaryIntoInner(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        result_alloc: std.mem.Allocator,
        turn_id: u64,
        kind: SteeringBoundaryKind,
    ) !SteeringBoundaryResult {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const cancel_requested = self.worker_cancel_requested.load(.seq_cst);
        if (!self.worker_processing or self.active_turn_id != turn_id) {
            return if (kind == .cancelled and cancel_requested) .interrupt else .none;
        }

        switch (kind) {
            .cancelled => {
                if (!cancel_requested) return .none;
                if (self.steering_cancel_turn_id != turn_id) return .interrupt;
                const messages = try self.takeSteeringLocked(alloc, result_alloc, turn_id);
                if (messages.len == 0) return .interrupt;
                self.steering_cancel_turn_id = null;
                self.worker_cancel_requested.store(false, .seq_cst);
                return .{ .continue_turn = messages };
            },
            .model, .finalizing => {
                if (cancel_requested) return .none;
                for (self.queued_prompts.items) |prompt| {
                    if (prompt.delivery.activeTurnId() == turn_id and
                        !sameTurnSteeringEligible(prompt)) return .handoff;
                }
                const messages = try self.takeSteeringLocked(alloc, result_alloc, turn_id);
                if (kind == .finalizing and messages.len == 0) self.direct_steering_closed = true;
                return if (messages.len == 0)
                    .none
                else
                    .{ .continue_turn = messages };
            },
        }
    }

    fn takeSteeringLocked(self: *WorkerRuntime, alloc: std.mem.Allocator, result_alloc: std.mem.Allocator, turn_id: u64) ![][]u8 {
        var steering_count: usize = 0;
        for (self.queued_prompts.items) |prompt| {
            if (prompt.delivery.activeTurnId() != turn_id) continue;
            if (!sameTurnSteeringEligible(prompt)) return &.{};
            steering_count += 1;
        }
        if (steering_count == 0) return &.{};

        const messages = try result_alloc.alloc([]u8, steering_count);
        var copied: usize = 0;
        errdefer {
            for (messages[0..copied]) |text| result_alloc.free(text);
            result_alloc.free(messages);
        }
        const events = try alloc.alloc(WorkerEvent, steering_count);
        var event_count: usize = 0;
        errdefer {
            for (events[0..event_count]) |event| freeWorkerEvent(alloc, event);
            alloc.free(events);
        }
        for (self.queued_prompts.items) |prompt| {
            if (prompt.delivery.activeTurnId() != turn_id) continue;
            messages[copied] = try result_alloc.dupe(u8, prompt.prompt);
            copied += 1;
            if (prompt.steering_receipt == null) {
                events[event_count] = .{
                    .append_user_feedback = try alloc.dupe(u8, prompt.prompt),
                };
                event_count += 1;
            }
        }
        try self.worker_events.ensureUnusedCapacity(alloc, event_count);
        for (events[0..event_count]) |event| self.worker_events.appendAssumeCapacity(event);
        alloc.free(events);

        var index: usize = 0;
        while (index < self.queued_prompts.items.len) {
            if (self.queued_prompts.items[index].delivery.activeTurnId() != turn_id) {
                index += 1;
                continue;
            }
            const prompt = self.queued_prompts.orderedRemove(index);
            if (prompt.steering_receipt) |receipt| {
                receipt.state.store(.applied, .seq_cst);
                debug_trace.eventf("subagent", "feedback_applied", .{}, "operation={s}", .{receipt.operation_id});
            }
            freeQueuedPrompt(alloc, prompt);
        }
        if (self.queued_prompts.items.len == 0) {
            types.freeHistoryTurnSlice(alloc, self.queued_history);
            self.queued_history = &.{};
        }
        debug_trace.eventf("worker", "prompt_steering_consumed", .{ .turn_id = turn_id }, "count={d}", .{messages.len});
        self.worker_cond.broadcast(io_mod.getIo());
        return messages;
    }

    pub fn holdSessionTransition(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.session_transition_held = true;
    }

    pub fn releaseSessionTransitionHold(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.session_transition_held) return;
        self.session_transition_held = false;
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// Hold turn admission only when no turn is active or queued.
    pub fn tryHoldTurnStart(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.worker_processing or self.queuedWorkCountLocked() > 0 or
            self.turn_start_held or self.session_transition_held)
        {
            return false;
        }
        self.turn_start_held = true;
        debug_trace.logf("worker", "turn start hold acquired", .{});
        return true;
    }

    pub fn releaseTurnStartHold(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.turn_start_held) return;
        self.turn_start_held = false;
        debug_trace.logf("worker", "turn start hold released", .{});
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn removeQueuedPrompt(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn_id: u64,
        retained_images: []const types.ImageAttachment,
    ) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        var removed: ?QueuedPrompt = null;
        for (self.queued_prompts.items, 0..) |queued, index| {
            if (queued.turn_id != turn_id) continue;
            removed = self.queued_prompts.orderedRemove(index);
            break;
        }
        if (removed != null and self.queued_prompts.items.len == 0) {
            types.freeHistoryTurnSlice(alloc, self.queued_history);
            self.queued_history = &.{};
        }
        const remaining = self.queuedWorkCountLocked();
        self.worker_mutex.unlock(io_mod.getIo());

        const prompt = removed orelse return false;
        discardQueuedPrompt(alloc, prompt, retained_images);
        debug_trace.eventf(
            "worker",
            "queued_prompt_removed",
            .{ .turn_id = turn_id },
            "remaining={d}",
            .{remaining},
        );
        return true;
    }

    /// Removes the newest queued text-only steering prompt that still waits for
    /// a tool or compaction boundary and returns an allocator-owned copy of its
    /// text so the composer can restore it for editing. Returns null when
    /// nothing is safely retractable: no active turn, no wait boundary (an
    /// immediate steer is already committed to its interrupt), a cancel
    /// already in flight, or only handoff-class steers with images or skill
    /// bindings.
    pub fn popQueuedSteerForEdit(self: *WorkerRuntime, alloc: std.mem.Allocator) !?[]u8 {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.worker_processing or self.active_turn_id == 0) return null;
        if (!self.hasSteeringWaitBoundaryLocked()) return null;
        if (self.worker_cancel_requested.load(.seq_cst)) return null;

        var retractable: ?usize = null;
        var index: usize = self.queued_prompts.items.len;
        while (index > 0) {
            index -= 1;
            const prompt = self.queued_prompts.items[index];
            if (prompt.delivery.activeTurnId() != self.active_turn_id) continue;
            if (!sameTurnSteeringEligible(prompt)) continue;
            retractable = index;
            break;
        }
        const remove_index = retractable orelse return null;

        const text = try alloc.dupe(u8, self.queued_prompts.items[remove_index].prompt);
        const prompt = self.queued_prompts.orderedRemove(remove_index);
        if (self.queued_prompts.items.len == 0) {
            types.freeHistoryTurnSlice(alloc, self.queued_history);
            self.queued_history = &.{};
        }
        const turn_id = prompt.turn_id;
        const remaining = self.queuedWorkCountLocked();
        freeQueuedPrompt(alloc, prompt);
        debug_trace.eventf(
            "worker",
            "prompt_steering_retracted",
            .{ .turn_id = turn_id },
            "remaining={d}",
            .{remaining},
        );
        self.worker_cond.broadcast(io_mod.getIo());
        return text;
    }

    pub fn waitAndTakeNextWork(self: *WorkerRuntime, alloc: std.mem.Allocator) !?WorkItem {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        while (((self.queued_prompts.items.len == 0 and
            self.queued_context_compaction == null) or self.turn_start_held or
            self.session_transition_held) and !self.worker_stop_requested)
        {
            self.worker_processing = false;
            self.active_turn_id = 0;
            self.tool_phase_step_id = null;
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }
        return self.takeNextWorkLocked(alloc);
    }

    fn takeNextWorkLocked(self: *WorkerRuntime, alloc: std.mem.Allocator) !?WorkItem {
        if (self.worker_stop_requested) return null;
        if (self.queued_context_compaction) |task| {
            self.queued_context_compaction = null;
            self.worker_cancel_requested.store(false, .seq_cst);
            self.worker_recovery_pause_requested.store(false, .seq_cst);
            self.worker_connectivity_wait_active.store(false, .seq_cst);
            self.recovery_continuation_ready = false;
            self.worker_processing = true;
            self.active_turn_id = task.turn_id;
            self.tool_phase_step_id = null;
            self.active_context_compaction = true;
            if (task.operation_id) |id| self.compaction_presentation.running(id, .preparation);
            debug_trace.eventf(
                "worker",
                "context_compaction_begin",
                .{ .turn_id = task.turn_id },
                "remaining_queue={d} cancel_reset=true",
                .{self.queuedWorkCountLocked()},
            );
            return .{ .compact_context = task };
        }
        const prompt = (try self.takeNextPromptLocked(alloc)) orelse return null;
        return .{ .prompt = prompt };
    }

    fn takeNextPromptLocked(self: *WorkerRuntime, alloc: std.mem.Allocator) !?QueuedPrompt {
        if (self.worker_stop_requested or self.queued_prompts.items.len == 0) return null;

        const queued = self.queued_prompts.items[0];
        const transfer_history = self.queued_prompts.items.len == 1;
        const job_history = if (transfer_history)
            self.queued_history
        else
            try session_runtime.snapshotOwnedContextHistory(
                alloc,
                self.queued_history,
                0,
                0,
            );
        errdefer if (!transfer_history) {
            types.freeHistoryTurnSlice(alloc, job_history);
        };
        if (queued.recovery_checkpoint == null and queued.user_prompt_already_presented) {
            try self.worker_events.append(alloc, .{
                .begin_presented_prompt = queued.turn_id,
            });
        } else if (queued.recovery_checkpoint == null) {
            const begin_prompt = try types.dupeUserTurn(alloc, .{ .text = queued.prompt, .images = queued.images });
            errdefer types.freeUserTurn(alloc, begin_prompt);
            if (queued.skill_bindings.len > 0 or queued.skill_display_spans.len > 0) {
                const skill_bindings = try dupeSkillBindings(alloc, queued.skill_bindings);
                errdefer freeSkillBindings(alloc, skill_bindings);
                const skill_display_spans = try dupeSkillDisplaySpans(alloc, queued.skill_display_spans);
                errdefer freeSkillDisplaySpans(alloc, skill_display_spans);
                try self.worker_events.append(alloc, .{
                    .begin_prompt_with_skill_bindings = .{
                        .prompt = begin_prompt,
                        .skill_bindings = skill_bindings,
                        .skill_display_spans = skill_display_spans,
                    },
                });
            } else {
                try self.worker_events.append(alloc, .{ .begin_prompt = begin_prompt });
            }
        }

        var job = self.queued_prompts.orderedRemove(0);
        if (transfer_history) self.queued_history = &.{};
        job.history = job_history;
        self.steering_cancel_turn_id = null;
        self.worker_cancel_requested.store(false, .seq_cst);
        self.worker_recovery_pause_requested.store(false, .seq_cst);
        self.worker_connectivity_wait_active.store(false, .seq_cst);
        self.recovery_continuation_ready = false;
        self.worker_processing = true;
        self.active_turn_id = job.turn_id;
        self.tool_phase_step_id = null;
        if (job.delivery.isContinuation()) {
            for (self.queued_prompts.items) |*prompt| {
                if (!prompt.delivery.isContinuation() or !sameTurnSteeringEligible(prompt.*)) continue;
                prompt.delivery = .{ .active_turn = job.turn_id };
            }
        }
        self.active_context_compaction = false;
        debug_trace.logf(
            "worker",
            "begin prompt bytes={d} remaining_queue={d} fast_mode={s} effort={s}",
            .{ job.prompt.len, self.queuedWorkCountLocked(), if (job.agent_settings.fast_mode) "true" else "false", job.agent_settings.effort.label() },
        );
        debug_trace.eventf(
            "worker",
            "worker_begin",
            .{ .turn_id = job.turn_id },
            "prompt_bytes={d} remaining_queue={d} cancel_reset=true fast_mode={s} effort={s}",
            .{ job.prompt.len, self.queuedWorkCountLocked(), if (job.agent_settings.fast_mode) "true" else "false", job.agent_settings.effort.label() },
        );
        return job;
    }

    pub fn finishProcessing(self: *WorkerRuntime) void {
        debug_trace.logf("worker", "finish processing queued={d}", .{self.queuedPromptCount()});
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        // Close steering admission without moving entries, preserving the exact
        // order in which steering and ordinary prompts were submitted.
        const finished_turn_id = self.active_turn_id;
        self.finishCompactionActivityLocked(finished_turn_id);
        for (self.queued_prompts.items) |*prompt| {
            if (prompt.delivery.activeTurnId() == finished_turn_id) {
                prompt.delivery = .continuation;
                debug_trace.eventf("worker", "steering_deferred_to_next_turn", .{ .turn_id = finished_turn_id }, "queued_turn_id={d} prompt_bytes={d}", .{ prompt.turn_id, prompt.prompt.len });
            }
        }
        self.worker_processing = false;
        self.active_turn_id = 0;
        self.steering_cancel_turn_id = null;
        self.clearActiveToolCallsLocked();
        self.tool_phase_step_id = null;
        self.active_context_compaction = false;
        self.worker_connectivity_wait_active.store(false, .seq_cst);
        self.worker_cond.broadcast(io_mod.getIo());
        self.worker_mutex.unlock(io_mod.getIo());
    }

    /// Marks an agent turn that is executed directly rather than dequeued by
    /// the interactive worker loop. The caller must pair a successful begin
    /// with `finishProcessing`.
    pub fn beginDirectProcessing(self: *WorkerRuntime, turn_id: u64) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.worker_processing or self.worker_stop_requested) return false;
        self.direct_steering_closed = false;
        self.worker_cancel_requested.store(false, .seq_cst);
        self.worker_recovery_pause_requested.store(false, .seq_cst);
        self.worker_connectivity_wait_active.store(false, .seq_cst);
        self.worker_processing = true;
        self.active_turn_id = turn_id;
        self.tool_phase_step_id = null;
        return true;
    }

    const ActiveToolTransition = union(enum) {
        none,
        started: []u8,
        terminal: []const u8,
        clear,

        fn deinit(self: *ActiveToolTransition, alloc: std.mem.Allocator) void {
            switch (self.*) {
                .started => |call_id| alloc.free(call_id),
                .none, .terminal, .clear => {},
            }
            self.* = .none;
        }
    };

    fn prepareActiveToolTransitionLocked(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        event: WorkerEvent,
    ) !ActiveToolTransition {
        return switch (event) {
            .tool_lifecycle => |lifecycle| switch (lifecycle) {
                .authoritative_started => |started| blk: {
                    if (started.id.turn_id != self.active_turn_id or
                        self.active_tool_calls.contains(started.id.call_id))
                    {
                        break :blk .none;
                    }
                    if (self.active_tool_allocator == null) {
                        self.active_tool_allocator = alloc;
                    }
                    try self.active_tool_calls.ensureUnusedCapacity(alloc, 1);
                    break :blk .{ .started = try alloc.dupe(u8, started.id.call_id) };
                },
                .terminal => |terminal| if (terminal.id.turn_id == self.active_turn_id and
                    self.active_tool_calls.contains(terminal.id.call_id))
                    .{ .terminal = terminal.id.call_id }
                else
                    .none,
                .turn_finished => |finished| if (finished.turn_id == self.active_turn_id) .clear else .none,
                .provisional, .progress => .none,
            },
            else => .none,
        };
    }

    fn applyActiveToolTransitionLocked(
        self: *WorkerRuntime,
        transition: ActiveToolTransition,
    ) void {
        switch (transition) {
            .none => {},
            .started => |call_id| {
                self.active_tool_calls.putAssumeCapacity(call_id, {});
            },
            .terminal => |call_id| {
                const removed = self.active_tool_calls.fetchRemove(call_id) orelse return;
                std.debug.assert(self.active_tool_allocator != null);
                const alloc = self.active_tool_allocator.?;
                alloc.free(removed.key);
            },
            .clear => self.clearActiveToolCallsLocked(),
        }
    }

    fn applyToolBoundaryPhaseLocked(self: *WorkerRuntime, event: WorkerEvent) void {
        switch (event) {
            .turn_phase_update => |update| if (update.turn_id == self.active_turn_id) {
                switch (update.phase) {
                    .running => self.tool_phase_step_id = update.step_id,
                    .waiting_for_subagent => {},
                    .thinking, .generating => if (self.tool_phase_step_id != update.step_id) {
                        self.tool_phase_step_id = null;
                    },
                }
            },
            else => {},
        }
    }

    fn hasActiveToolBoundaryLocked(self: *const WorkerRuntime) bool {
        return self.tool_phase_step_id != null or self.active_tool_calls.count() > 0;
    }

    /// True while a context compaction owns the worker: either the compaction
    /// work item is running, or the active turn is inside a compaction
    /// transaction. Compaction reports through the activity channel rather
    /// than the tool/phase event feed, so it is consulted separately.
    fn compactionInFlightLocked(self: *const WorkerRuntime) bool {
        if (self.active_context_compaction) return true;
        if (self.compaction_presentation.snapshot.operation) |operation| return operation.active();
        return false;
    }

    /// Steering must wait whenever the active work cannot absorb guidance right
    /// now: a running tool or tool-producing step, or a compaction in flight.
    /// Cancelling either would discard in-progress work the user expects to
    /// finish; the message is delivered at the next boundary instead.
    fn hasSteeringWaitBoundaryLocked(self: *const WorkerRuntime) bool {
        return self.hasActiveToolBoundaryLocked() or self.compactionInFlightLocked();
    }

    fn clearActiveToolCallsLocked(self: *WorkerRuntime) void {
        const alloc = self.active_tool_allocator orelse {
            std.debug.assert(self.active_tool_calls.count() == 0);
            return;
        };
        var keys = self.active_tool_calls.keyIterator();
        while (keys.next()) |key| alloc.free(@constCast(key.*));
        self.active_tool_calls.deinit(alloc);
        self.active_tool_calls = .empty;
        self.active_tool_allocator = null;
    }

    pub fn waitUntilIdle(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        while (self.worker_processing) {
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }
    }

    pub fn isProcessing(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.worker_processing;
    }

    pub fn snapshotState(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
    ) permission_request.RequestCloneError!StateSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const cancel_requested = self.worker_cancel_requested.load(.seq_cst);
        return .{
            .processing = self.worker_processing,
            .active_turn_id = self.active_turn_id,
            .queued_count = self.queuedWorkCountLocked(),
            .pending_event_count = self.worker_events.items.len,
            .cancel_requested = cancel_requested,
            .cancel_continues_turn = cancel_requested and
                self.steering_cancel_turn_id == self.active_turn_id,
            .pending_permission_request = if (self.permissionRequestAwaitingDecisionLocked()) blk: {
                const request = &self.pending_permission_request_shared.?;
                break :blk try permission_request.OwnedPermissionRequest.dupe(alloc, request.view());
            } else null,
            .pending_permission_review = if (self.permissionRequestAwaitingDecisionLocked())
                if (self.pending_permission_review) |review|
                    .{
                        .request_id = self.pending_permission_request_shared.?.id,
                        .review = review,
                    }
                else
                    null
            else
                null,
        };
    }

    pub fn activeTurnId(self: *WorkerRuntime) u64 {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.active_turn_id;
    }

    /// Returns one coherent, allocator-owned steering presentation snapshot.
    pub fn snapshotSteeringPresentation(self: *WorkerRuntime, alloc: std.mem.Allocator) !SteeringPresentationSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        var steering_count: usize = 0;
        for (self.queued_prompts.items) |prompt| {
            if (prompt.delivery.isSteering()) steering_count += 1;
        }
        var snapshot: SteeringPresentationSnapshot = .{
            .waits_for_boundary = steering_count > 0 and self.hasSteeringWaitBoundaryLocked(),
        };
        errdefer snapshot.deinit(alloc);
        snapshot.pending_feedback = pending: {
            var count: usize = 0;
            for (self.worker_events.items) |event| {
                if (event == .append_user_feedback) count += 1;
            }
            if (count == 0) break :pending &.{};
            const feedback = try alloc.alloc([]u8, count);
            errdefer alloc.free(feedback);
            var written: usize = 0;
            errdefer for (feedback[0..written]) |message| alloc.free(message);
            for (self.worker_events.items) |event| {
                if (event == .append_user_feedback) {
                    feedback[written] = try alloc.dupe(u8, event.append_user_feedback);
                    written += 1;
                }
            }
            break :pending feedback;
        };
        if (steering_count == 0) return snapshot;

        const messages = try alloc.alloc([]u8, steering_count);
        var copied: usize = 0;
        errdefer {
            for (messages[0..copied]) |message| alloc.free(message);
            alloc.free(messages);
        }
        for (self.queued_prompts.items) |prompt| {
            if (!prompt.delivery.isSteering()) continue;
            messages[copied] = try alloc.dupe(u8, prompt.prompt);
            copied += 1;
        }
        snapshot.messages = messages;
        return snapshot;
    }

    pub fn queuedPromptCount(self: *WorkerRuntime) usize {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.queuedWorkCountLocked();
    }

    pub fn clearQueuedPrompts(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        retained_images: []const types.ImageAttachment,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        self.clearQueuedPromptsLocked(alloc, retained_images);
    }

    /// Clears the queue while atomically transferring deletion responsibility
    /// for a matching active or finished turn to the supplied retained images.
    pub fn clearQueuedPromptsForSessionTransition(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn_id: u64,
        retained_images: []const types.ImageAttachment,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (retained_images.len > 0) {
            _ = self.preservePromptSnapshotsLocked(turn_id, retained_images);
        }
        self.clearQueuedPromptsLocked(alloc, retained_images);
    }

    fn clearQueuedPromptsLocked(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        retained_images: []const types.ImageAttachment,
    ) void {
        const dropped = self.queuedWorkCountLocked();
        if (dropped > 0) {
            debug_trace.logf("worker", "clear queued prompts dropped={d}", .{dropped});
            debug_trace.eventf("worker", "queued_prompts_cleared", .{}, "dropped={d}", .{dropped});
        }
        for (self.queued_prompts.items) |prompt| {
            discardQueuedPrompt(alloc, prompt, retained_images);
        }
        self.queued_prompts.clearRetainingCapacity();
        types.freeHistoryTurnSlice(alloc, self.queued_history);
        self.queued_history = &.{};
        if (self.queued_context_compaction) |task| {
            if (task.operation_id) |id| self.compaction_presentation.settle(id, .{ .outcome = .cancelled }, io_mod.milliTimestamp());
            freeContextCompactionTask(alloc, task);
            self.queued_context_compaction = null;
        }
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn discardEvents(self: *WorkerRuntime, alloc: std.mem.Allocator) void {
        var events = self.takeEvents();
        defer events.deinit(alloc);
        for (events.items) |event| freeWorkerEvent(alloc, event);
    }

    pub fn syncQueuedPromptModel(self: *WorkerRuntime, alloc: std.mem.Allocator, model: []const u8) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| {
            const next_model = try alloc.dupe(u8, model);
            alloc.free(prompt.model);
            prompt.model = next_model;
        }
    }

    pub fn syncQueuedPromptPermissionSnapshot(self: *WorkerRuntime, snapshot: PermissionSnapshot) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| {
            prompt.permission_mode = snapshot.mode;
        }
    }

    pub fn syncQueuedPromptFastMode(self: *WorkerRuntime, enabled: bool) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.agent_turn_settings.fast_mode = enabled;
        for (self.queued_prompts.items) |*prompt| prompt.agent_settings.fast_mode = enabled;
    }

    pub fn syncQueuedPromptEffort(self: *WorkerRuntime, effort: types.ReasoningEffort) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.agent_turn_settings.effort = effort;
        for (self.queued_prompts.items) |*prompt| prompt.agent_settings.effort = effort;
    }

    pub fn setActiveAgentTurnSettings(self: *WorkerRuntime, settings: AgentTurnSettings) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.active_agent_turn_settings = settings;
    }

    pub fn clearActiveAgentTurnSettings(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.active_agent_turn_settings = null;
    }

    pub fn effectiveAgentTurnSettings(self: *WorkerRuntime) AgentTurnSettings {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.active_agent_turn_settings orelse self.agent_turn_settings;
    }

    pub fn syncQueuedPromptPermissionState(self: *WorkerRuntime, alloc: std.mem.Allocator, grants: []const types.PermissionGrant, snapshot: PermissionSnapshot) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| {
            const next_grants = try types.dupePermissionGrantSlice(alloc, grants);
            types.freePermissionGrantSlice(alloc, prompt.grants);
            prompt.grants = next_grants;
            prompt.permission_mode = snapshot.mode;
        }
    }

    pub fn propagateHistoryTurn(self: *WorkerRuntime, alloc: std.mem.Allocator, turn: types.HistoryTurn, max_history_turns: usize) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        try self.propagateHistoryTurnLocked(alloc, turn, max_history_turns, null);
    }

    pub fn commitContextCompaction(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        summary: types.CompactedSummaryHistoryTurn,
        active_prefix: ?types.AssistantHistoryTurn,
        retained_from: ?types.ContextHistoryCut,
        max_history_turns: usize,
    ) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const result = try self.awaitHistoryPublicationLocked(alloc, .{
            .context_compaction = .{
                .turn_id = self.active_turn_id,
                .summary = summary,
                .active_prefix = active_prefix,
                .retained_from = retained_from,
                .max_history_turns = max_history_turns,
            },
        });
        std.debug.assert(result == null);
    }

    pub fn prepareFreshPrompt(self: *WorkerRuntime, alloc: std.mem.Allocator, preparation: FreshPromptPreparation) !FreshPromptHistory {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        var request = preparation;
        request.turn_id = self.active_turn_id;
        return (try self.awaitHistoryPublicationLocked(alloc, .{ .prepare_fresh_prompt = request })) orelse error.InvalidHistoryPublication;
    }

    fn awaitHistoryPublicationLocked(self: *WorkerRuntime, alloc: std.mem.Allocator, event: WorkerEvent) !?FreshPromptHistory {
        if (self.worker_stop_requested or self.isCancelRequested()) return error.Aborted;
        std.debug.assert(self.history_publication_response == .idle);
        const owned_event = try dupeWorkerEvent(alloc, event);
        var owns_event = true;
        defer if (owns_event) freeWorkerEvent(alloc, owned_event);
        try self.worker_events.ensureUnusedCapacity(alloc, 1);
        self.history_publication_response = .{ .waiting = self.active_turn_id };
        defer {
            if (self.history_publication_response == .committed) {
                if (self.history_publication_response.committed) |*snapshot| snapshot.deinit(alloc);
            }
            self.history_publication_response = .idle;
        }
        self.worker_events.appendAssumeCapacity(owned_event);
        owns_event = false;
        self.worker_cond.broadcast(io_mod.getIo());

        while (self.history_publication_response == .waiting and
            !self.worker_stop_requested and !self.isCancelRequested())
        {
            try self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex);
        }
        switch (self.history_publication_response) {
            .committed => |result| {
                self.history_publication_response = .idle;
                return result;
            },
            .failed => |err| return err,
            .waiting, .idle => return error.Aborted,
        }
    }

    pub fn failPendingHistoryPublication(self: *WorkerRuntime, err: anyerror) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.history_publication_response != .waiting) return;
        self.history_publication_response = .{ .failed = err };
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn resolveContextCompaction(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        event: ContextCompaction,
        ctx: *anyopaque,
        handler: ContextCompactionHandler,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.history_publication_response != .waiting or
            self.history_publication_response.waiting != event.turn_id)
        {
            debug_trace.logf("worker", "compaction delivery dropped reason=stale turn_id={d}", .{event.turn_id});
            return;
        }
        defer self.worker_cond.broadcast(io_mod.getIo());
        if (self.worker_stop_requested or self.isCancelRequested()) {
            self.history_publication_response = .{ .failed = error.Aborted };
            return;
        }
        self.publishContextCompactionLocked(alloc, event, ctx, handler) catch |err| {
            self.history_publication_response = .{ .failed = err };
            return;
        };
        self.history_publication_response = .{ .committed = null };
    }

    pub fn resolveFreshPrompt(self: *WorkerRuntime, alloc: std.mem.Allocator, event: FreshPromptPreparation, ctx: *anyopaque, handler: FreshPromptHandler) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.history_publication_response != .waiting or self.history_publication_response.waiting != event.turn_id) {
            debug_trace.logf("worker", "fresh prompt preparation dropped reason=stale turn_id={d}", .{event.turn_id});
            return;
        }
        defer self.worker_cond.broadcast(io_mod.getIo());
        if (self.worker_stop_requested or self.isCancelRequested()) {
            self.history_publication_response = .{ .failed = error.Aborted };
            return;
        }
        const snapshot = self.publishFreshPromptLocked(alloc, event, ctx, handler) catch |err| {
            self.history_publication_response = .{ .failed = err };
            return;
        };
        self.history_publication_response = .{ .committed = snapshot };
    }

    fn publishFreshPromptLocked(self: *WorkerRuntime, alloc: std.mem.Allocator, event: FreshPromptPreparation, ctx: *anyopaque, handler: FreshPromptHandler) !FreshPromptHistory {
        const prior_turn = event.prior_turn orelse return handler(ctx, event);
        const Publication = struct {
            ctx: *anyopaque,
            handler: FreshPromptHandler,
            event: FreshPromptPreparation,
            result: ?FreshPromptHistory = null,

            fn commit(raw: *anyopaque) !void {
                const self_: *@This() = @ptrCast(@alignCast(raw));
                self_.result = try self_.handler(self_.ctx, self_.event);
            }
        };
        var publication: Publication = .{ .ctx = ctx, .handler = handler, .event = event };
        try self.propagateHistoryTurnLocked(alloc, prior_turn, 0, .{ .ctx = &publication, .commit_fn = Publication.commit });
        return publication.result.?;
    }

    fn publishContextCompactionLocked(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        event: ContextCompaction,
        ctx: *anyopaque,
        handler: ContextCompactionHandler,
    ) !void {
        var publication: ContextCompactionPublication = .{ .ctx = ctx, .handler = handler, .event = event };
        try self.propagateHistoryTurnLocked(
            alloc,
            .{ .compacted_summary = event.summary },
            event.max_history_turns,
            .{ .ctx = &publication, .commit_fn = ContextCompactionPublication.commit, .retained_from = event.retained_from },
        );
        if (event.active_prefix != null) {
            if (self.active_prompt_snapshot_ownership) |ownership| {
                _ = ownership.preserve();
            }
        }
    }

    fn propagateHistoryTurnLocked(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn: types.HistoryTurn,
        max_history_turns: usize,
        publication: ?HistoryPublication,
    ) !void {
        self.propagateHistoryTurnToQueue(alloc, turn, max_history_turns, publication) catch |err| {
            if (err == error.SessionPersistenceUncertain) {
                if (self.active_prompt_snapshot_ownership) |ownership| {
                    _ = ownership.preserve();
                }
            }
            return err;
        };
    }

    fn propagateHistoryTurnToQueue(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn: types.HistoryTurn,
        max_history_turns: usize,
        publication: ?HistoryPublication,
    ) !void {
        if (self.queued_prompts.items.len == 0) {
            if (publication) |value| try value.commit();
            return;
        }
        const active_ownership = if (self.active_prompt_snapshot_ownership) |ownership|
            try ownership.ensureSharedOwnership(alloc)
        else
            null;
        const cut = if (publication) |value| value.retained_from else null;
        const next_history = if (cut) |retained_from| try session_runtime.prepareCompactedHistory(alloc, self.queued_history, turn.compacted_summary, retained_from) else try appendHistoryTurnProjection(
            alloc,
            self.queued_history,
            turn,
            max_history_turns,
        );
        var next_history_owned = true;
        defer if (next_history_owned) types.freeHistoryTurnSlice(alloc, next_history);
        const prepared = try alloc.alloc(
            PreparedHistoryPropagation,
            self.queued_prompts.items.len,
        );
        var prepared_count: usize = 0;
        var committed = false;
        defer {
            if (!committed) {
                for (prepared[0..prepared_count]) |entry| entry.deinit(alloc);
            }
            alloc.free(prepared);
        }

        while (prepared_count < self.queued_prompts.items.len) : (prepared_count += 1) {
            const prompt = self.queued_prompts.items[prepared_count];
            const next_image_catalog = try session_runtime.merge_image_catalog_history_turn(
                alloc,
                prompt.authorized_image_catalog,
                turn,
            );
            errdefer types.freeImageAttachmentSlice(alloc, next_image_catalog);
            const next_root_user_intent_context = try auto_classifier_context.refreshQueuedRootUserContext(
                alloc,
                prompt.prompt,
                prompt.root_user_intent_context,
                turn,
            );
            errdefer alloc.free(next_root_user_intent_context);
            const next_snapshot_file_ownerships = if (active_ownership) |ownership| blk: {
                const ownership_count = std.math.add(
                    usize,
                    prompt.snapshot_file_ownerships.len,
                    1,
                ) catch return error.OutOfMemory;
                const ownerships = try alloc.alloc(
                    types.SnapshotFileOwnership,
                    ownership_count,
                );
                @memmove(
                    ownerships[0..prompt.snapshot_file_ownerships.len],
                    prompt.snapshot_file_ownerships,
                );
                ownership.retain();
                ownerships[prompt.snapshot_file_ownerships.len] = ownership;
                break :blk ownerships;
            } else null;
            errdefer {
                if (next_snapshot_file_ownerships) |ownerships| {
                    ownerships[ownerships.len - 1].release();
                    alloc.free(ownerships);
                }
            }

            prepared[prepared_count] = .{
                .root_user_intent_context = next_root_user_intent_context,
                .authorized_image_catalog = next_image_catalog,
                .snapshot_file_ownerships = next_snapshot_file_ownerships,
                .added_snapshot_ownership = if (next_snapshot_file_ownerships) |ownerships|
                    ownerships[ownerships.len - 1]
                else
                    null,
            };
        }

        if (publication) |value| try value.commit();
        if (next_history.len <= self.queued_history.len) {
            debug_trace.logf("worker", "queued history replaced by context checkpoint turns={d}", .{self.queued_history.len});
        }
        types.freeHistoryTurnSlice(alloc, self.queued_history);
        self.queued_history = next_history;
        next_history_owned = false;
        for (self.queued_prompts.items, prepared) |*prompt, next| {
            if (turn == .compacted_summary) prompt.unversioned_history_count = 0;
            if (prompt.root_user_intent_context.len > 0) alloc.free(prompt.root_user_intent_context);
            prompt.root_user_intent_context = next.root_user_intent_context;
            types.freeImageAttachmentSlice(alloc, prompt.authorized_image_catalog);
            prompt.authorized_image_catalog = next.authorized_image_catalog;
            if (next.snapshot_file_ownerships) |ownerships| {
                if (prompt.snapshot_file_ownerships.len > 0) {
                    alloc.free(prompt.snapshot_file_ownerships);
                }
                prompt.snapshot_file_ownerships = ownerships;
            }
        }
        committed = true;
    }

    pub fn beginActivePromptSnapshots(
        self: *WorkerRuntime,
        ownership: *ActivePromptSnapshotOwnership,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        std.debug.assert(self.active_prompt_snapshot_ownership == null);
        if (self.preserve_prompt_snapshot_turn_id == self.active_turn_id) {
            _ = ownership.preserve();
            self.preserve_prompt_snapshot_turn_id = null;
        }
        self.active_prompt_snapshot_ownership = ownership;
    }

    pub fn handoffActivePromptSnapshots(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
    ) !?types.SnapshotFileOwnership {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const ownership = self.active_prompt_snapshot_ownership orelse return null;
        return ownership.handoff(alloc);
    }

    pub fn endActivePromptSnapshots(
        self: *WorkerRuntime,
        ownership: *ActivePromptSnapshotOwnership,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        std.debug.assert(self.active_prompt_snapshot_ownership == ownership);
        self.active_prompt_snapshot_ownership = null;
        ownership.deinit();
    }

    pub fn preservePromptSnapshots(self: *WorkerRuntime, turn_id: u64, images: []const types.ImageAttachment) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        _ = self.preservePromptSnapshotsLocked(turn_id, images);
    }

    fn preservePromptSnapshotsLocked(
        self: *WorkerRuntime,
        turn_id: u64,
        images: []const types.ImageAttachment,
    ) bool {
        if (turn_id == 0 or images.len == 0) return false;

        var preserved = false;
        if (self.active_turn_id == turn_id) {
            if (self.active_prompt_snapshot_ownership) |ownership| {
                if (sameImageSnapshots(ownership.images, images)) {
                    preserved = ownership.preserve();
                }
            } else {
                // The unique active turn bridges queue take to ownership
                // registration while both operations remain mutex-serialized.
                self.preserve_prompt_snapshot_turn_id = turn_id;
                preserved = true;
            }
        }
        for (self.worker_events.items) |*event| {
            if (event.* != .finish_prompt) continue;
            const finished = &event.finish_prompt;
            const finished_images = historyTurnImages(finished.turn);
            if (!sameImageSnapshots(finished_images, images)) continue;
            if (finished.snapshot_file_ownership) |ownership| {
                ownership.transfer();
                preserved = true;
            }
        }
        return preserved;
    }

    pub fn propagateGrant(self: *WorkerRuntime, alloc: std.mem.Allocator, tool_name: []const u8, target_path: []const u8) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| try appendGrantToQueuedPrompt(alloc, prompt, tool_name, target_path);
    }

    pub fn requestPermissionBlockingWithReview(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        request: permission_request.PermissionRequest,
        review: ?*const diff_mod.FileReview,
    ) permission_request.RequestCloneError!permission_request.OwnedPermissionResponse {
        return self.requestPermissionBlockingObserved(alloc, request, review, null) catch |err| switch (err) {
            error.PermissionRegistrationFailed,
            error.PermissionCapacityExceeded,
            => unreachable,
            else => |request_err| return request_err,
        };
    }

    pub const PermissionRequestObserver = struct {
        context: *anyopaque,
        observe_fn: *const fn (
            *anyopaque,
            *WorkerRuntime,
            permission_request.PermissionRequest,
        ) error{
            OutOfMemory,
            PermissionRegistrationFailed,
            PermissionCapacityExceeded,
        }!void,
    };

    pub fn requestPermissionBlockingObserved(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        request: permission_request.PermissionRequest,
        review: ?*const diff_mod.FileReview,
        observer: ?PermissionRequestObserver,
    ) (permission_request.RequestCloneError || error{
        PermissionRegistrationFailed,
        PermissionCapacityExceeded,
    })!permission_request.OwnedPermissionResponse {
        var shared_request: ?permission_request.OwnedPermissionRequest =
            try permission_request.OwnedPermissionRequest.dupe(
                alloc,
                request,
            );
        errdefer if (shared_request) |*owned| owned.deinit(alloc);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        shared_request.?.id = try self.allocatePermissionRequestIdLocked();
        if (self.pending_permission_request_shared) |*old| old.deinit(alloc);
        self.pending_permission_request_shared = shared_request.?;
        shared_request = null;
        self.pending_permission_review = review;
        if (self.pending_permission_response) |response| {
            self.discardPermissionResponse(response, "request_replaced");
        }
        self.pending_permission_response = null;
        self.pending_permission_waiting = true;

        if (observer) |value| {
            value.observe_fn(
                value.context,
                self,
                self.pending_permission_request_shared.?.view(),
            ) catch |err| {
                self.pending_permission_waiting = false;
                self.pending_permission_request_shared.?.deinit(alloc);
                self.pending_permission_request_shared = null;
                self.pending_permission_review = null;
                return err;
            };
        }

        while (self.pending_permission_response == null and !self.worker_stop_requested) {
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }

        const response = self.pending_permission_response orelse
            permission_request.OwnedPermissionResponse.init(alloc, .deny, null);
        self.pending_permission_waiting = false;
        self.pending_permission_response = null;
        if (self.pending_permission_request_shared) |*old| {
            old.deinit(alloc);
            self.pending_permission_request_shared = null;
        }
        self.pending_permission_review = null;
        return response;
    }

    pub fn submitPermissionResponse(
        self: *WorkerRuntime,
        expected_request_id: u64,
        response: permission_request.OwnedPermissionResponse,
    ) PermissionSubmissionResult {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.permissionSubmissionBlockedLocked(expected_request_id)) |blocked| {
            self.discardPermissionResponse(response, @tagName(blocked));
            return blocked;
        }
        std.debug.assert(self.resolvePendingPermissionLocked(response));
        return .accepted;
    }

    pub const PermissionCommitError = error{
        OutOfMemory,
        PermissionCommitFailed,
        PermissionCapacityExceeded,
    };

    pub const PermissionCommit = struct {
        context: *anyopaque,
        commit_fn: *const fn (*anyopaque) PermissionCommitError!void,
    };

    /// Keeps canonical pending-request identity stable across a durable host
    /// commit. The response becomes visible and the waiter wakes only after the
    /// callback succeeds. On callback failure the owned response is discarded.
    pub fn submitPermissionResponseAfterCommit(
        self: *WorkerRuntime,
        expected_request_id: u64,
        response: permission_request.OwnedPermissionResponse,
        commit: ?PermissionCommit,
    ) PermissionCommitError!PermissionSubmissionResult {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.permissionSubmissionBlockedLocked(expected_request_id)) |blocked| {
            self.discardPermissionResponse(response, @tagName(blocked));
            return blocked;
        }
        if (commit) |effect| effect.commit_fn(effect.context) catch |err| {
            self.discardPermissionResponse(response, "commit_failed");
            return err;
        };
        std.debug.assert(self.resolvePendingPermissionLocked(response));
        return .accepted;
    }

    fn permissionSubmissionBlockedLocked(
        self: *const WorkerRuntime,
        expected_request_id: u64,
    ) ?PermissionSubmissionResult {
        if (!self.permissionRequestAwaitedLocked() or
            self.pending_permission_response != null)
        {
            return .no_pending;
        }
        if (self.pending_permission_request_shared.?.id != expected_request_id) {
            return .stale;
        }
        return null;
    }

    fn allocatePermissionRequestIdLocked(
        self: *WorkerRuntime,
    ) error{RequestIdExhausted}!u64 {
        const request_id = self.next_permission_request_id;
        if (request_id == 0) return error.RequestIdExhausted;
        self.next_permission_request_id = std.math.add(
            u64,
            request_id,
            1,
        ) catch 0;
        return request_id;
    }

    fn permissionRequestAwaitedLocked(self: *const WorkerRuntime) bool {
        return self.worker_processing and
            !self.worker_stop_requested and
            self.pending_permission_waiting and
            self.pending_permission_request_shared != null;
    }

    fn permissionRequestAwaitingDecisionLocked(
        self: *const WorkerRuntime,
    ) bool {
        return self.permissionRequestAwaitedLocked() and
            self.pending_permission_response == null;
    }

    fn resolvePendingPermissionLocked(
        self: *WorkerRuntime,
        response: permission_request.OwnedPermissionResponse,
    ) bool {
        if (!self.permissionRequestAwaitingDecisionLocked()) {
            self.discardPermissionResponse(response, "unawaited");
            return false;
        }
        self.pending_permission_response = response;
        self.worker_cond.broadcast(io_mod.getIo());
        return true;
    }

    fn discardPermissionResponse(
        _: *WorkerRuntime,
        response: permission_request.OwnedPermissionResponse,
        reason: []const u8,
    ) void {
        var owned = response;
        if (owned.feedback) |feedback| {
            debug_trace.logf(
                "permission",
                "approval feedback discarded reason={s} bytes={d}",
                .{ reason, feedback.len },
            );
        }
        owned.deinit();
    }

    pub fn requestQuestionBatchAnswerBlocking(self: *WorkerRuntime, alloc: std.mem.Allocator, entries: []const types.QuestionBatchEntry) !?[][]u8 {
        return self.requestQuestionBatchAnswerBlockingWithSource(alloc, entries, .agent_question);
    }

    pub fn requestRouteRecoveryAnswerBlocking(self: *WorkerRuntime, alloc: std.mem.Allocator, entries: []const types.QuestionBatchEntry) !?[][]u8 {
        return self.requestQuestionBatchAnswerBlockingWithSource(alloc, entries, .route_recovery);
    }

    fn requestQuestionBatchAnswerBlockingWithSource(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        entries: []const types.QuestionBatchEntry,
        source: QuestionPromptSource,
    ) !?[][]u8 {
        const owned = try dupeOwnedQuestionBatch(alloc, entries, source);
        var owns_pending_question = true;
        errdefer if (owns_pending_question) freeOwnedQuestionBatch(alloc, owned);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        std.debug.assert(self.pending_question_shared == null);
        self.pending_question_shared = owned;
        freeQuestionResponse(alloc, self.pending_question_response);
        self.pending_question_response = .pending;
        self.worker_events.append(alloc, .question_requested) catch |err| {
            self.pending_question_shared = null;
            self.pending_question_response = .pending;
            return err;
        };
        owns_pending_question = false;
        self.worker_cond.broadcast(io_mod.getIo());

        while (self.pending_question_response == .pending and !self.worker_stop_requested) {
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }

        if (self.pending_question_shared) |pending| {
            freeOwnedQuestionBatch(alloc, pending);
            self.pending_question_shared = null;
        }

        const response = self.pending_question_response;
        self.pending_question_response = .pending;
        return switch (response) {
            .answered => |labels| labels,
            .cancelled, .pending => null,
        };
    }

    pub fn submitQuestionBatchAnswer(self: *WorkerRuntime, alloc: std.mem.Allocator, answers: ?[]const []const u8) !void {
        var new_response: QuestionResponse = .cancelled;
        if (answers) |labels| {
            const dup = try alloc.alloc([]u8, labels.len);
            errdefer alloc.free(dup);
            var filled: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < filled) : (i += 1) alloc.free(dup[i]);
            }
            while (filled < labels.len) : (filled += 1) dup[filled] = try alloc.dupe(u8, labels[filled]);
            new_response = .{ .answered = dup };
        }

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.pending_question_shared == null or self.pending_question_response != .pending) {
            freeQuestionResponse(alloc, new_response);
            debug_trace.logf("worker", "ignored late question response pending=false", .{});
            return;
        }
        freeQuestionResponse(alloc, self.pending_question_response);
        self.pending_question_response = new_response;
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn snapshotPendingQuestionBatch(self: *WorkerRuntime, alloc: std.mem.Allocator) !?PendingQuestionBatchSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const pending = self.pending_question_shared orelse return null;
        return try dupePendingBatchSnapshot(alloc, pending);
    }

    pub fn pendingQuestionBatchSource(self: *WorkerRuntime) QuestionPromptSource {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const pending = self.pending_question_shared orelse return .agent_question;
        return pending.source;
    }
};

fn recoveryContinuationAdmission(
    processing: bool,
    queued_count: usize,
    terminal_pause_ready: bool,
) bool {
    return queued_count == 0 and (!processing or terminal_pause_ready);
}

fn dupeOwnedQuestionEntry(alloc: std.mem.Allocator, entry: types.QuestionBatchEntry) !OwnedQuestionEntry {
    const question_dup = try alloc.dupe(u8, entry.question);
    errdefer alloc.free(question_dup);
    const options_dup = try alloc.alloc(OwnedQuestionOption, entry.options.len);
    errdefer alloc.free(options_dup);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(options_dup[i].label);
            if (options_dup[i].description) |d| alloc.free(d);
        }
    }
    while (filled < entry.options.len) : (filled += 1) {
        const src = entry.options[filled];
        const label_dup = try alloc.dupe(u8, src.label);
        errdefer alloc.free(label_dup);
        const desc_dup: ?[]u8 = if (src.description) |d| try alloc.dupe(u8, d) else null;
        options_dup[filled] = .{ .label = label_dup, .description = desc_dup };
    }
    return .{ .question = question_dup, .options = options_dup, .submission = entry.submission };
}

fn freeOwnedQuestionEntry(alloc: std.mem.Allocator, entry: OwnedQuestionEntry) void {
    alloc.free(entry.question);
    for (entry.options) |opt| {
        alloc.free(opt.label);
        if (opt.description) |d| alloc.free(d);
    }
    alloc.free(entry.options);
}

fn dupeOwnedQuestionBatch(
    alloc: std.mem.Allocator,
    entries: []const types.QuestionBatchEntry,
    source: QuestionPromptSource,
) !OwnedQuestionBatch {
    const owned_entries = try alloc.alloc(OwnedQuestionEntry, entries.len);
    errdefer alloc.free(owned_entries);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) freeOwnedQuestionEntry(alloc, owned_entries[i]);
    }
    while (filled < entries.len) : (filled += 1) owned_entries[filled] = try dupeOwnedQuestionEntry(alloc, entries[filled]);
    return .{ .entries = owned_entries, .source = source };
}

fn freeOwnedQuestionBatch(alloc: std.mem.Allocator, owned: OwnedQuestionBatch) void {
    for (owned.entries) |entry| freeOwnedQuestionEntry(alloc, entry);
    alloc.free(owned.entries);
}

fn freeOwnedQuestionBatchOpt(alloc: std.mem.Allocator, owned: ?OwnedQuestionBatch) void {
    if (owned) |o| freeOwnedQuestionBatch(alloc, o);
}

fn freeQuestionResponse(alloc: std.mem.Allocator, response: QuestionResponse) void {
    switch (response) {
        .answered => |labels| {
            for (labels) |label| alloc.free(label);
            alloc.free(labels);
        },
        .cancelled, .pending => {},
    }
}

fn dupePendingEntrySnapshot(alloc: std.mem.Allocator, pending: OwnedQuestionEntry) !types.QuestionBatchEntry {
    const question_dup = try alloc.dupe(u8, pending.question);
    errdefer alloc.free(question_dup);
    const options_dup = try alloc.alloc(types.QuestionOption, pending.options.len);
    errdefer alloc.free(options_dup);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(@constCast(options_dup[i].label));
            if (options_dup[i].description) |d| alloc.free(@constCast(d));
        }
    }
    while (filled < pending.options.len) : (filled += 1) {
        const src = pending.options[filled];
        const label_dup = try alloc.dupe(u8, src.label);
        errdefer alloc.free(label_dup);
        const desc_dup: ?[]const u8 = if (src.description) |d| try alloc.dupe(u8, d) else null;
        options_dup[filled] = .{ .label = label_dup, .description = desc_dup };
    }
    return .{ .question = question_dup, .options = options_dup, .submission = pending.submission };
}

fn dupePendingBatchSnapshot(alloc: std.mem.Allocator, pending: OwnedQuestionBatch) !PendingQuestionBatchSnapshot {
    const entries_dup = try alloc.alloc(types.QuestionBatchEntry, pending.entries.len);
    errdefer alloc.free(entries_dup);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(@constCast(entries_dup[i].question));
            for (entries_dup[i].options) |opt| {
                alloc.free(@constCast(opt.label));
                if (opt.description) |d| alloc.free(@constCast(d));
            }
            alloc.free(@constCast(entries_dup[i].options));
        }
    }
    while (filled < pending.entries.len) : (filled += 1) entries_dup[filled] = try dupePendingEntrySnapshot(alloc, pending.entries[filled]);
    return .{ .entries = entries_dup, .source = pending.source };
}

fn appendGrantToQueuedPrompt(alloc: std.mem.Allocator, prompt: *QueuedPrompt, tool_name: []const u8, target_path: []const u8) !void {
    for (prompt.grants) |grant| {
        if (std.mem.eql(u8, grant.tool_name, tool_name) and std.mem.eql(u8, grant.target_path, target_path)) return;
    }
    const tool_name_dup = try alloc.dupe(u8, tool_name);
    errdefer alloc.free(tool_name_dup);
    const target_path_dup = try alloc.dupe(u8, target_path);
    errdefer alloc.free(target_path_dup);
    const current = prompt.grants;
    const next = try alloc.alloc(types.PermissionGrant, current.len + 1);
    errdefer alloc.free(next);
    if (current.len > 0) @memmove(next[0..current.len], current);
    next[current.len] = .{ .tool_name = tool_name_dup, .target_path = target_path_dup };
    alloc.free(current);
    prompt.grants = next;
}

fn appendHistoryTurnProjection(
    alloc: std.mem.Allocator,
    current: []const types.HistoryTurn,
    turn: types.HistoryTurn,
    max_history_turns: usize,
) ![]types.HistoryTurn {
    _ = max_history_turns;
    const retained = if (turn == .compacted_summary and
        compactor.replacesPriorContext(turn.compacted_summary.summary))
        &.{}
    else
        current;
    const next = try alloc.alloc(types.HistoryTurn, retained.len + 1);
    errdefer alloc.free(next);
    var copied: usize = 0;
    errdefer for (next[0..copied]) |owned| types.freeHistoryTurn(alloc, owned);
    for (retained, 0..) |entry, index| {
        next[index] = try types.dupeHistoryTurn(alloc, entry);
        copied += 1;
    }
    next[retained.len] = try types.dupeHistoryTurn(alloc, turn);
    return next;
}

pub fn freeQueuedPrompt(alloc: std.mem.Allocator, prompt: QueuedPrompt) void {
    if (prompt.steering_receipt) |receipt| {
        if (receipt.state.cmpxchgStrong(.queued, .not_applied, .seq_cst, .seq_cst) == null) {
            debug_trace.eventf("subagent", "feedback_not_applied", .{}, "operation={s} reason=queue_discarded", .{receipt.operation_id});
        }
    }
    alloc.free(prompt.prompt);
    types.freeImageAttachmentSlice(alloc, prompt.images);
    types.freeImageAttachmentSlice(alloc, prompt.authorized_image_catalog);
    alloc.free(prompt.model);
    secret.zeroAndFree(alloc, prompt.api_key);
    if (prompt.account_id) |account_id| alloc.free(account_id);
    types.freeHistoryTurnSlice(alloc, prompt.history);
    if (prompt.root_user_intent_context.len > 0) alloc.free(prompt.root_user_intent_context);
    types.freePermissionGrantSlice(alloc, prompt.grants);
    freeSkillBindings(alloc, prompt.skill_bindings);
    freeSkillDisplaySpans(alloc, prompt.skill_display_spans);
    var context_snapshot = prompt.context_snapshot;
    context_snapshot.deinit(alloc);
    for (prompt.snapshot_file_ownerships) |ownership| ownership.release();
    if (prompt.snapshot_file_ownerships.len > 0) {
        alloc.free(prompt.snapshot_file_ownerships);
    }
    if (prompt.recovery_checkpoint) |checkpoint| {
        var owned = checkpoint;
        owned.deinit(alloc);
    }
}

pub fn freeContextCompactionTask(
    alloc: std.mem.Allocator,
    task: ContextCompactionTask,
) void {
    alloc.free(task.model);
    secret.zeroAndFree(alloc, task.api_key);
    if (task.account_id) |account_id| alloc.free(account_id);
    types.freeHistoryTurnSlice(alloc, task.history);
}

pub fn freeWorkItem(alloc: std.mem.Allocator, work: WorkItem) void {
    switch (work) {
        .prompt => |prompt| freeQueuedPrompt(alloc, prompt),
        .compact_context => |task| freeContextCompactionTask(alloc, task),
    }
}

fn discardQueuedPrompt(
    alloc: std.mem.Allocator,
    prompt: QueuedPrompt,
    retained_images: []const types.ImageAttachment,
) void {
    if (prompt.recovery_checkpoint == null) {
        image_attachments.deleteUnreferencedImageSnapshots(prompt.images, retained_images);
    }
    freeQueuedPrompt(alloc, prompt);
}

pub fn dupeSkillBindings(alloc: std.mem.Allocator, bindings: []const SkillBinding) ![]SkillBinding {
    if (bindings.len == 0) return &.{};
    const copy = try alloc.alloc(SkillBinding, bindings.len);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(copy[i].name);
            alloc.free(copy[i].path);
        }
        alloc.free(copy);
    }
    while (filled < bindings.len) : (filled += 1) {
        copy[filled] = .{
            .name = try alloc.dupe(u8, bindings[filled].name),
            .path = try alloc.dupe(u8, bindings[filled].path),
        };
    }
    return copy;
}

pub fn freeSkillBindings(alloc: std.mem.Allocator, bindings: []SkillBinding) void {
    for (bindings) |binding| {
        alloc.free(binding.name);
        alloc.free(binding.path);
    }
    if (bindings.len > 0) alloc.free(bindings);
}

pub fn dupeSkillDisplaySpans(alloc: std.mem.Allocator, spans: []const SkillDisplaySpan) ![]SkillDisplaySpan {
    if (spans.len == 0) return &.{};
    const copy = try alloc.alloc(SkillDisplaySpan, spans.len);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(copy[i].name);
            alloc.free(copy[i].path);
        }
        alloc.free(copy);
    }
    while (filled < spans.len) : (filled += 1) {
        copy[filled] = .{
            .raw_start = spans[filled].raw_start,
            .raw_end = spans[filled].raw_end,
            .name = try alloc.dupe(u8, spans[filled].name),
            .path = try alloc.dupe(u8, spans[filled].path),
            .display_source = spans[filled].display_source,
            .owns_trailing_separator = spans[filled].owns_trailing_separator,
        };
    }
    return copy;
}

pub fn freeSkillDisplaySpans(alloc: std.mem.Allocator, spans: []SkillDisplaySpan) void {
    for (spans) |span| {
        alloc.free(span.name);
        alloc.free(span.path);
    }
    if (spans.len > 0) alloc.free(spans);
}

pub fn dupeWorkerEvent(alloc: std.mem.Allocator, event: WorkerEvent) !WorkerEvent {
    return switch (event) {
        .begin_prompt => |prompt| .{ .begin_prompt = try types.dupeUserTurn(alloc, prompt) },
        .begin_prompt_with_skill_bindings => |begin| blk: {
            const prompt = try types.dupeUserTurn(alloc, begin.prompt);
            errdefer types.freeUserTurn(alloc, prompt);
            const skill_bindings = try dupeSkillBindings(alloc, begin.skill_bindings);
            errdefer freeSkillBindings(alloc, skill_bindings);
            const skill_display_spans = try dupeSkillDisplaySpans(alloc, begin.skill_display_spans);
            break :blk .{ .begin_prompt_with_skill_bindings = .{
                .prompt = prompt,
                .skill_bindings = skill_bindings,
                .skill_display_spans = skill_display_spans,
            } };
        },
        .begin_presented_prompt => |turn_id| .{ .begin_presented_prompt = turn_id },
        .append_user_feedback => |text| .{ .append_user_feedback = try alloc.dupe(u8, text) },
        .assistant_presentation => |presentation| .{
            .assistant_presentation = try presentation.clone(alloc),
        },
        .notification => |notification| .{ .notification = notification },
        .question_requested => .question_requested,
        .open_model_picker => .open_model_picker,
        .semantic_notice => |notice| .{ .semantic_notice = try types.dupeSemanticNotice(alloc, notice) },
        .full_detail_record => |notice| .{ .full_detail_record = try types.dupeSemanticNotice(alloc, notice) },
        .route_recovery_status => |status| .{ .route_recovery_status = status },
        .clear_route_recovery_status => .clear_route_recovery_status,
        .provider_resolved => |slug| .{ .provider_resolved = try alloc.dupe(u8, slug) },
        .api_status_text => |text| .{ .api_status_text = try alloc.dupe(u8, text) },
        .credential_refreshed => |credential| .{
            .credential_refreshed = try credential.clone(alloc),
        },
        .command_output => |chunk| .{ .command_output = .{
            .lifecycle_id = if (chunk.lifecycle_id) |id| .{
                .turn_id = id.turn_id,
                .call_id = try alloc.dupe(u8, id.call_id),
            } else null,
            .stream = chunk.stream,
            .text = try alloc.dupe(u8, chunk.text),
        } },
        .command_output_complete => |lifecycle_id| .{ .command_output_complete = if (lifecycle_id) |id| .{
            .turn_id = id.turn_id,
            .call_id = try alloc.dupe(u8, id.call_id),
        } else null },
        .tool_lifecycle => |lifecycle| .{
            .tool_lifecycle = try dupeToolLifecycleEvent(alloc, lifecycle),
        },
        .turn_token_update => |update| .{ .turn_token_update = update },
        .turn_phase_update => |update| .{ .turn_phase_update = update },
        .diff_block => |payload| blk: {
            const preview = try alloc.dupe(u8, payload.preview);
            errdefer alloc.free(preview);
            const full = if (payload.full) |source| full_value: {
                const content = try alloc.dupe(u8, source.content);
                errdefer alloc.free(content);
                const call_id = try alloc.dupe(u8, source.lifecycle_id.call_id);
                break :full_value diff_mod.FullDiff{
                    .content = content,
                    .lifecycle_id = .{
                        .turn_id = source.lifecycle_id.turn_id,
                        .call_id = call_id,
                    },
                };
            } else null;
            errdefer if (full) |owned| owned.deinit(alloc);
            break :blk .{ .diff_block = .{
                .preview = preview,
                .additions = payload.additions,
                .deletions = payload.deletions,
                .full = full,
            } };
        },
        .prepare_fresh_prompt => |value| blk: {
            const user = try types.dupeUserTurn(alloc, value.user);
            errdefer types.freeUserTurn(alloc, user);
            break :blk .{ .prepare_fresh_prompt = .{
                .turn_id = value.turn_id,
                .user = user,
                .prior_turn = if (value.prior_turn) |prior| try types.dupeHistoryTurn(alloc, prior) else null,
            } };
        },
        .context_compaction => |value| blk: {
            const summary = try types.dupeHistoryTurn(alloc, .{ .compacted_summary = value.summary });
            errdefer types.freeHistoryTurn(alloc, summary);
            const prefix = if (value.active_prefix) |prefix|
                (try types.dupeHistoryTurn(alloc, .{ .assistant = prefix })).assistant
            else
                null;
            break :blk .{ .context_compaction = .{
                .turn_id = value.turn_id,
                .summary = summary.compacted_summary,
                .active_prefix = prefix,
                .retained_from = value.retained_from,
                .max_history_turns = value.max_history_turns,
            } };
        },
        .finish_prompt => |finished| .{ .finish_prompt = try types.dupeFinishedPrompt(alloc, finished) },
        .session_grant => |grant| blk: {
            const tool_name = try alloc.dupe(u8, grant.tool_name);
            errdefer alloc.free(tool_name);
            const target_path = try alloc.dupe(u8, grant.target_path);
            break :blk .{ .session_grant = .{
                .tool_name = tool_name,
                .target_path = target_path,
            } };
        },
        .error_text => |notice| .{ .error_text = try types.dupeSemanticNotice(alloc, notice) },
        .restore_failed_prompt => |text| .{ .restore_failed_prompt = try alloc.dupe(u8, text) },
    };
}

pub fn freeWorkerEvent(alloc: std.mem.Allocator, event: WorkerEvent) void {
    switch (event) {
        .begin_prompt => |prompt| types.freeUserTurn(alloc, prompt),
        .begin_prompt_with_skill_bindings => |begin| {
            types.freeUserTurn(alloc, begin.prompt);
            freeSkillBindings(alloc, begin.skill_bindings);
            freeSkillDisplaySpans(alloc, begin.skill_display_spans);
        },
        .begin_presented_prompt => {},
        .append_user_feedback => |text| alloc.free(text),
        .assistant_presentation => |presentation| {
            var owned = presentation;
            owned.deinit(alloc);
        },
        .notification => {},
        .open_model_picker => {},
        .semantic_notice => |notice| types.freeSemanticNotice(alloc, notice),
        .full_detail_record => |notice| types.freeSemanticNotice(alloc, notice),
        .route_recovery_status => {},
        .clear_route_recovery_status => {},
        .provider_resolved => |slug| alloc.free(slug),
        .api_status_text => |text| alloc.free(text),
        .credential_refreshed => |credential| {
            var owned = credential;
            owned.deinit(alloc);
        },
        .command_output => |chunk| {
            if (chunk.lifecycle_id) |id| alloc.free(@constCast(id.call_id));
            alloc.free(chunk.text);
        },
        .command_output_complete => |lifecycle_id| {
            if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
        },
        .tool_lifecycle => |lifecycle| freeToolLifecycleEvent(alloc, lifecycle),
        .diff_block => |payload| diff_mod.freeDiffEntryPayload(alloc, payload),
        .prepare_fresh_prompt => |value| {
            types.freeUserTurn(alloc, value.user);
            if (value.prior_turn) |prior| types.freeHistoryTurn(alloc, prior);
        },
        .context_compaction => |value| {
            types.freeHistoryTurn(alloc, .{ .compacted_summary = value.summary });
            if (value.active_prefix) |prefix| types.freeHistoryTurn(alloc, .{ .assistant = prefix });
        },
        .finish_prompt => |finished| types.freeFinishedPrompt(alloc, finished),
        .session_grant => |grant| {
            alloc.free(grant.tool_name);
            alloc.free(grant.target_path);
        },
        .error_text => |notice| types.freeSemanticNotice(alloc, notice),
        .restore_failed_prompt => |text| alloc.free(text),
        else => {},
    }
}

pub fn dupeToolLifecycleEvent(
    alloc: std.mem.Allocator,
    event: types.ToolLifecycleEvent,
) !types.ToolLifecycleEvent {
    return switch (event) {
        .provisional => |started| blk: {
            const call_id = try alloc.dupe(u8, started.id.call_id);
            errdefer alloc.free(call_id);
            const tool_name = if (started.tool_name) |name| try alloc.dupe(u8, name) else null;
            break :blk .{ .provisional = .{
                .id = .{ .turn_id = started.id.turn_id, .call_id = call_id },
                .presentation_group_id = started.presentation_group_id,
                .tool_name = tool_name,
                .activity_kind = started.activity_kind,
            } };
        },
        .authoritative_started => |started| blk: {
            const call_id = try alloc.dupe(u8, started.id.call_id);
            errdefer alloc.free(call_id);
            const alias = if (started.reconciles_provisional_call_id) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (alias) |value| alloc.free(value);
            const tool_name = try alloc.dupe(u8, started.tool_name);
            errdefer alloc.free(tool_name);
            const arguments_json = if (started.arguments_json) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (arguments_json) |value| alloc.free(value);
            break :blk .{ .authoritative_started = .{
                .id = .{ .turn_id = started.id.turn_id, .call_id = call_id },
                .presentation_group_id = started.presentation_group_id,
                .reconciles_provisional_call_id = alias,
                .tool_name = tool_name,
                .activity_kind = started.activity_kind,
                .arguments_json = arguments_json,
                .place_after_current_transcript = started.place_after_current_transcript,
            } };
        },
        .progress => |progress| blk: {
            const call_id = try alloc.dupe(u8, progress.id.call_id);
            errdefer alloc.free(call_id);
            const text = try alloc.dupe(u8, progress.text);
            break :blk .{ .progress = .{
                .id = .{ .turn_id = progress.id.turn_id, .call_id = call_id },
                .text = text,
            } };
        },
        .terminal => |terminal| blk: {
            const call_id = try alloc.dupe(u8, terminal.id.call_id);
            errdefer alloc.free(call_id);
            const summary = try alloc.dupe(u8, terminal.outcome.summary);
            errdefer alloc.free(summary);
            const result = if (terminal.result) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (result) |value| alloc.free(value);
            const result_memory = try dupeToolResultMemory(alloc, terminal.result_memory);
            errdefer freeToolResultMemory(alloc, result_memory);
            const command_artifact_handle = if (terminal.command_artifact_handle) |handle|
                try alloc.dupe(u8, handle)
            else
                null;
            errdefer if (command_artifact_handle) |handle| alloc.free(handle);
            break :blk .{ .terminal = .{
                .id = .{ .turn_id = terminal.id.turn_id, .call_id = call_id },
                .outcome = .{
                    .kind = terminal.outcome.kind,
                    .summary = summary,
                },
                .result = result,
                .result_memory = result_memory,
                .command_artifact_handle = command_artifact_handle,
            } };
        },
        .turn_finished => |finished| .{ .turn_finished = finished },
    };
}

pub fn freeToolLifecycleEvent(
    alloc: std.mem.Allocator,
    event: types.ToolLifecycleEvent,
) void {
    switch (event) {
        .provisional => |started| {
            alloc.free(@constCast(started.id.call_id));
            if (started.tool_name) |name| alloc.free(@constCast(name));
        },
        .authoritative_started => |started| {
            alloc.free(@constCast(started.id.call_id));
            if (started.reconciles_provisional_call_id) |alias| {
                alloc.free(@constCast(alias));
            }
            alloc.free(@constCast(started.tool_name));
            if (started.arguments_json) |arguments_json| {
                alloc.free(@constCast(arguments_json));
            }
        },
        .progress => |progress| {
            alloc.free(@constCast(progress.id.call_id));
            alloc.free(@constCast(progress.text));
        },
        .terminal => |terminal| {
            alloc.free(@constCast(terminal.id.call_id));
            alloc.free(@constCast(terminal.outcome.summary));
            if (terminal.result) |result| alloc.free(@constCast(result));
            freeToolResultMemory(alloc, terminal.result_memory);
            if (terminal.command_artifact_handle) |handle| alloc.free(@constCast(handle));
        },
        .turn_finished => {},
    }
}

fn dupeToolResultMemory(
    alloc: std.mem.Allocator,
    source: ?types.ToolResultMemory,
) !?types.ToolResultMemory {
    const memory = source orelse return null;
    const output_handle = if (memory.output_handle) |handle|
        try alloc.dupe(u8, handle)
    else
        null;
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = if (memory.preview) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (preview) |value| alloc.free(value);
    const command_output_replay = if (memory.command_output_replay) |replay|
        try types.dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (command_output_replay) |replay| types.freeCommandOutputReplay(alloc, replay);
    return .{
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = memory.output_bytes,
        .stored_output_bytes = memory.stored_output_bytes,
        .truncated = memory.truncated,
        .model_view_covers_full_file = memory.model_view_covers_full_file,
        .command_output_replay = command_output_replay,
        .command_process_presentation = memory.command_process_presentation,
        .terminal_action_presentation = memory.terminal_action_presentation,
    };
}

fn freeToolResultMemory(
    alloc: std.mem.Allocator,
    memory: ?types.ToolResultMemory,
) void {
    const value = memory orelse return;
    if (value.output_handle) |handle| alloc.free(@constCast(handle));
    if (value.preview) |preview| alloc.free(@constCast(preview));
    if (value.command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    }
}

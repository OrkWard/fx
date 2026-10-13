pub const approval_chrome_rows: u16 = 3;
pub const approval_panel_rows_compact: u16 = 8;
pub const approval_panel_rows_spacious: u16 = 11;
pub const approval_spacious_min_terminal_rows: u16 = 34;
pub const approval_once_label = "1. Yes";
pub const approval_deny_label = "3. No";
pub const approval_hint = "1–3 choose now    ↑↓ or tab options    enter confirm    esc cancel";
pub const approval_amendment_hint = "1–3 choose now    ↑↓ options    tab amend    enter confirm    esc cancel";
pub const approval_hint_compact = "1–3 choose now    enter confirm    esc cancel";
pub const approval_hint_minimal = "enter confirm    esc cancel";
// Ordered widest-first; every variant keeps the enter/esc controls so narrow
// terminals never lose the submit and cancel instructions.
pub const approval_hint_variants = [_][]const u8{ approval_hint, approval_hint_compact, approval_hint_minimal };
pub const approval_amendment_hint_variants = [_][]const u8{ approval_amendment_hint, approval_hint_compact, approval_hint_minimal };

pub const ApprovalScreenCommit = struct {
    request_id: u64,
    rows: u16,
    cols: u16,
    file_identity_visible: bool,
    all_decision_controls_visible: bool,
    changed_or_notice_visible: bool,
    document_scrollable: bool,
};

pub const ApprovalScreenState = struct {
    document_scroll_rows: usize = 0,
    screen_commit: ?ApprovalScreenCommit = null,
    changed_or_notice_observed: bool = false,
    file_document_hydrated: bool = false,

    pub fn clear(self: *ApprovalScreenState) void {
        self.* = .{};
    }

    pub fn scrollDocument(self: *ApprovalScreenState, delta: i32) void {
        if (delta < 0) {
            const amount: usize = @intCast(-@as(i64, delta));
            self.document_scroll_rows -|= amount;
        } else {
            self.document_scroll_rows +|= @intCast(delta);
        }
    }

    pub fn clampDocumentScroll(self: *ApprovalScreenState, max_scroll_rows: usize) void {
        self.document_scroll_rows = @min(self.document_scroll_rows, max_scroll_rows);
    }

    pub fn invalidateScreenCommit(self: *ApprovalScreenState) void {
        self.screen_commit = null;
    }

    pub fn markFileDocumentHydrated(self: *ApprovalScreenState) void {
        self.file_document_hydrated = true;
    }

    pub fn recordScreenCommit(
        self: *ApprovalScreenState,
        request_id: u64,
        commit: ApprovalScreenCommit,
    ) void {
        if (request_id != commit.request_id) return;
        self.screen_commit = commit;
        self.changed_or_notice_observed = self.changed_or_notice_observed or
            commit.changed_or_notice_visible;
    }
};

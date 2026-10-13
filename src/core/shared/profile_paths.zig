const std = @import("std");

const Allocator = std.mem.Allocator;

pub const root_dir_name = ".fx";
pub const auth_file_name = "auth.json";
pub const chatgpt_auth_file_name = "chatgpt-auth.json";
pub const grok_auth_file_name = "grok-auth.json";
pub const api_key_file_name = "api-key";
pub const sessions_dir_name = "sessions";
/// Older per-session side folders, one per session id.
pub const session_files_dir_name = "session-files";
/// Hosted terminal state kept outside a session folder, one per session id.
pub const terminal_dir_name = "terminal";
pub const prompt_history_file_name = "history.jsonl";
pub const usage_file_name = "usage.jsonl";
pub const usage_recovery_dir_name = "usage-recovery";
pub const backups_dir_name = "backups";

const settings_file_name = "settings.json";
const managed_skills_dir_name = "skills";
const logs_dir_name = "logs";
const trace_log_file_name = "trace.log";
const recordings_dir_name = "recordings";

pub fn rootDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name });
}

pub fn settingsPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, settings_file_name });
}

pub fn managedSkillsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, managed_skills_dir_name });
}

pub fn authPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, auth_file_name });
}

pub fn chatgptAuthPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, chatgpt_auth_file_name });
}

pub fn apiKeyPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, api_key_file_name });
}

pub fn sessionsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, sessions_dir_name });
}

pub fn promptHistoryPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, prompt_history_file_name });
}

pub fn backupsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, backups_dir_name });
}

pub fn logsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, logs_dir_name });
}

pub fn traceLogPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, logs_dir_name, trace_log_file_name });
}

pub const diagnostics_dir_name = "diagnostics";
pub const last_shutdown_report_file_name = "last-shutdown.json";

pub fn lastShutdownReportPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, diagnostics_dir_name, last_shutdown_report_file_name });
}

pub fn recordingsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, recordings_dir_name });
}

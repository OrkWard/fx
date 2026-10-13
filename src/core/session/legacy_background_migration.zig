const std = @import("std");
const process_identity = @import("../execution/process_identity.zig");
const process_provider = @import("../execution/process_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const session_child_store = @import("session_child_store.zig");

const Allocator = std.mem.Allocator;
const max_record_bytes: usize = 256 * 1024;
const max_records: usize = 1024;
const migration_lock_name = "managed-execution-migration.lock";

pub const Result = struct {
    records_removed: usize = 0,
    logs_removed: usize = 0,
    processes_signaled: usize = 0,
    identities_unavailable: usize = 0,
};

pub fn migrate(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    provider: process_provider.Provider,
) !Result {
    var record_probe = try capability.iterate(alloc, .background_records);
    defer record_probe.deinit();
    var log_probe = try capability.iterate(alloc, .background_logs);
    defer log_probe.deinit();
    const has_records = for (record_probe.names) |name| {
        if (!std.mem.eql(u8, name, migration_lock_name)) break true;
    } else false;
    if (!has_records and log_probe.names.len == 0) return .{};

    var lock = try capability.acquireTimedAdvisoryLock(
        .background_records,
        migration_lock_name,
        2_000,
    );
    defer lock.release();

    var result: Result = .{};
    var records = try capability.iterate(alloc, .background_records);
    defer records.deinit();
    if (records.names.len > max_records) return error.LegacyBackgroundMigrationTooLarge;
    for (records.names) |name| {
        if (std.mem.eql(u8, name, migration_lock_name)) continue;
        migrateRecord(alloc, capability, provider, name, &result) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf(
                "session",
                "legacy background record migration degraded name={s} err={s}",
                .{ name, @errorName(err) },
            );
        };
        capability.delete(.background_records, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        result.records_removed += 1;
    }

    var logs = try capability.iterate(alloc, .background_logs);
    defer logs.deinit();
    if (logs.names.len > max_records) return error.LegacyBackgroundMigrationTooLarge;
    for (logs.names) |name| {
        capability.delete(.background_logs, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        result.logs_removed += 1;
    }
    return result;
}

fn migrateRecord(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    provider: process_provider.Provider,
    name: []const u8,
    result: *Result,
) !void {
    var file = try capability.openFileReadOnly(
        alloc,
        .background_records,
        name,
    );
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, max_record_bytes);
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return error.InvalidLegacyBackgroundRecord;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidLegacyBackgroundRecord,
    };
    const state = stringField(object, "state") orelse return;
    if (!std.mem.eql(u8, state, "running")) return;
    const pid = stringField(object, "pid") orelse return;
    const token_text = optionalStringField(object, "process_token") orelse {
        result.identities_unavailable += 1;
        return;
    };
    const token = process_identity.ProcessInstanceToken.parse(token_text) catch {
        result.identities_unavailable += 1;
        return;
    };
    switch (provider.matchToken(alloc, pid, token)) {
        .matched => provider.signalProcess(alloc, pid, token) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                result.identities_unavailable += 1;
                return;
            },
        },
        .missing, .mismatched => return,
        .unavailable => {
            result.identities_unavailable += 1;
            return;
        },
    }
    result.processes_signaled += 1;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn optionalStringField(
    object: std.json.ObjectMap,
    name: []const u8,
) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        .null => null,
        else => null,
    };
}

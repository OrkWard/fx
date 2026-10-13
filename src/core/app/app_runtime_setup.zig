const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");

const Allocator = std.mem.Allocator;
pub const LoadSkillsError = Allocator.Error;

pub const LoadedSkills = struct {
    dir: []u8 = &.{},
    skills: []skill_runtime.Skill = &.{},
    diagnostics: []skill_runtime.SkillDiagnostic = &.{},

    pub fn deinit(self: *LoadedSkills, alloc: Allocator) void {
        if (self.dir.len > 0) alloc.free(self.dir);
        skill_runtime.freeSkills(alloc, self.skills);
        skill_runtime.freeSkillDiagnostics(alloc, self.diagnostics);
        self.* = .{};
    }
};

pub fn resolveSkillsHome(alloc: Allocator) Allocator.Error!?[]u8 {
    const configured_home = io_mod.getenv("HOME") orelse return null;
    return io_mod.realpathAlloc(alloc, configured_home) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => try alloc.dupe(u8, configured_home),
    };
}

/// The managed skills directory under the configured HOME, or null without
/// one. The caller owns the returned path.
pub fn resolveManagedSkillsDir(alloc: Allocator) Allocator.Error!?[]u8 {
    const home = (try resolveSkillsHome(alloc)) orelse return null;
    defer alloc.free(home);
    return try profile_paths.managedSkillsDir(alloc, home);
}

pub fn loadSkills(
    alloc: Allocator,
    workspace_root: []const u8,
    root_policy: skill_contract.RootPolicy,
) LoadSkillsError!LoadedSkills {
    const home = (try resolveSkillsHome(alloc)) orelse return .{};
    defer alloc.free(home);
    const dir = try profile_paths.managedSkillsDir(alloc, home);
    errdefer alloc.free(dir);
    const discovery = try skill_runtime.loadVisibleSkills(alloc, workspace_root, home, dir, root_policy);

    return .{
        .dir = dir,
        .skills = discovery.skills,
        .diagnostics = discovery.diagnostics,
    };
}

//! Role configuration loader — reads .bees/roles/{name}/ directories.
//!
//! Each role directory contains:
//!   config.json  — model, effort, budget, sources, produces, MCP refs
//!   prompt.md    — system prompt (appended to Claude's default system prompt)
//!   skills/      — agent-specific skill files (future)
//!
//! Falls back to legacy .bees/prompts/{name}.txt if roles directory doesn't exist.

const std = @import("std");
const fs = @import("fs.zig");
const config_mod = @import("config.zig");
const context = @import("context.zig");

/// Parsed role configuration from config.json
pub const RoleConfig = struct {
    name: []const u8,
    model: []const u8 = "sonnet",
    effort: []const u8 = "high",
    max_budget_usd: f64 = 30.0,
    fallback_model: ?[]const u8 = null,
    max_turns: u32 = 0,
    mcp_config: ?[]const u8 = null,
    sources: []const []const u8 = &.{},
    produces: []const []const u8 = &.{},
    stores_report: bool = false,
    prompt_path: []const u8 = "",
    backend: []const u8 = "",
};

/// All loaded roles, keyed by name
pub const RoleSet = struct {
    roles: std.StringHashMap(RoleConfig),
    allocator: std.mem.Allocator,

    pub fn get(self: *const RoleSet, name: []const u8) ?RoleConfig {
        return self.roles.get(name);
    }

    pub fn deinit(self: *RoleSet) void {
        self.roles.deinit();
    }
};

/// Load all roles from .bees/roles/ directory.
/// Falls back to legacy layout if roles dir doesn't exist.
pub fn loadRoles(paths: config_mod.ProjectPaths, allocator: std.mem.Allocator) !RoleSet {
    var set = RoleSet{
        .roles = std.StringHashMap(RoleConfig).init(allocator),
        .allocator = allocator,
    };

    const roles_dir = try std.fs.path.join(allocator, &.{ paths.bees_dir, "roles" });
    defer allocator.free(roles_dir);

    if (!fs.access(roles_dir)) {
        // Legacy mode: build role configs from .bees/config.json sections
        return set;
    }

    // Scan .bees/roles/ for subdirectories
    var dir = fs.openDir(roles_dir) catch return set;
    defer fs.closeDir(dir);

    var iter = dir.iterate();
    while (iter.next(fs.io) catch null) |entry| {
        if (entry.kind != .directory) continue;

        const role_dir = std.fs.path.join(allocator, &.{ roles_dir, entry.name }) catch continue;
        const config_path = std.fs.path.join(allocator, &.{ role_dir, "config.json" }) catch continue;
        const prompt_path = std.fs.path.join(allocator, &.{ role_dir, "prompt.md" }) catch continue;

        // Parse config.json if it exists
        var role = parseRoleConfig(allocator, config_path) orelse RoleConfig{ .name = entry.name };
        role.name = try allocator.dupe(u8, entry.name);

        // Check for prompt file
        if (fs.access(prompt_path)) {
            role.prompt_path = prompt_path;
        } else {
            allocator.free(prompt_path);
            // Try legacy .txt in prompts dir
            const legacy = std.fs.path.join(allocator, &.{ paths.prompts_dir, entry.name }) catch continue;
            const legacy_txt = std.fmt.allocPrint(allocator, "{s}.txt", .{legacy}) catch continue;
            allocator.free(legacy);
            if (fs.access(legacy_txt)) {
                role.prompt_path = legacy_txt;
            } else {
                allocator.free(legacy_txt);
                role.prompt_path = "";
            }
        }

        set.roles.put(role.name, role) catch continue;
    }

    return set;
}

/// Resolve context.Source values from the role's "sources" string array.
pub fn resolveContextSources(role: RoleConfig, allocator: std.mem.Allocator) []const context.Source {
    if (role.sources.len == 0) return &.{};

    var sources: std.ArrayList(context.Source) = .empty;
    for (role.sources) |s| {
        if (std.mem.eql(u8, s, "user_profiles")) {
            sources.append(allocator, .user_profiles) catch continue;
        } else if (std.mem.eql(u8, s, "operator_feedback")) {
            sources.append(allocator, .operator_feedback) catch continue;
        } else if (std.mem.eql(u8, s, "report:qa")) {
            sources.append(allocator, .report_qa) catch continue;
        } else if (std.mem.eql(u8, s, "report:sre")) {
            sources.append(allocator, .report_sre) catch continue;
        } else if (std.mem.eql(u8, s, "report:user")) {
            sources.append(allocator, .report_user) catch continue;
        } else if (std.mem.eql(u8, s, "task_trends")) {
            sources.append(allocator, .task_trends) catch continue;
        } else if (std.mem.eql(u8, s, "worker_summary")) {
            sources.append(allocator, .worker_summary) catch continue;
        } else if (std.mem.eql(u8, s, "changed_files")) {
            sources.append(allocator, .changed_files) catch continue;
        }
        // Unknown sources silently skipped — forward compatible
    }
    return sources.toOwnedSlice(allocator) catch &.{};
}

/// Validate all roles and their references. Returns error messages.
pub fn validate(set: *const RoleSet, allocator: std.mem.Allocator) []const []const u8 {
    var errors = std.ArrayList([]const u8).init(allocator);

    var it = set.roles.iterator();
    while (it.next()) |entry| {
        const role = entry.value_ptr.*;
        // Check prompt exists
        if (role.prompt_path.len == 0) {
            const msg = std.fmt.allocPrint(allocator, "role '{s}': no prompt.md found", .{role.name}) catch continue;
            errors.append(allocator, msg) catch continue;
        }
        // Check report sources reference existing roles
        for (role.sources) |src| {
            if (std.mem.startsWith(u8, src, "report:")) {
                const ref_role = src["report:".len..];
                if (set.roles.get(ref_role) == null) {
                    const msg = std.fmt.allocPrint(allocator, "role '{s}': source '{s}' references unknown role '{s}'", .{ role.name, src, ref_role }) catch continue;
                    errors.append(allocator, msg) catch continue;
                }
            }
        }
    }

    return errors.toOwnedSlice(allocator) catch &.{};
}

// === Internal ===

fn parseRoleConfig(allocator: std.mem.Allocator, path: []const u8) ?RoleConfig {
    const data = fs.readFileAlloc(allocator, path, 64 * 1024) catch return null;
    defer allocator.free(data);
    const parsed = std.json.parseFromSlice(RoleConfig, allocator, data, .{
        .allocate = .alloc_always,
    }) catch return null;
    return parsed.value;
}

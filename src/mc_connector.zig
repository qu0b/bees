//! MC Connector — bridges mc package manager plugins with bees agent roles.
//!
//! Reads `.mc/plugins/` directly (no runtime dependency on mc binary).
//! Resolves plugin references from role configs into:
//!   - Merged MCP config files for --mcp-config
//!   - Skill symlinks for Claude Code skill discovery
//!   - Template variable expansion (${CLAUDE_PLUGIN_ROOT})

const std = @import("std");
const fs = @import("fs.zig");
const role_mod = @import("role.zig");

/// Check if the project has an mc sandbox with installed plugins.
pub fn hasMcPlugins(allocator: std.mem.Allocator, project_root: []const u8) bool {
    const mc_json = std.fs.path.join(allocator, &.{ project_root, ".mc", "mc.json" }) catch return false;
    defer allocator.free(mc_json);
    return fs.access(mc_json);
}

/// Get the mc plugins directory path.
pub fn getPluginsDir(allocator: std.mem.Allocator, project_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ project_root, ".mc", "plugins" });
}

/// List installed mc plugin names by scanning .mc/plugins/ directory.
pub fn listInstalledPlugins(allocator: std.mem.Allocator, project_root: []const u8) ![][]const u8 {
    const plugins_dir = try getPluginsDir(allocator, project_root);
    defer allocator.free(plugins_dir);

    var dir = fs.openDir(plugins_dir) catch return &.{};
    defer fs.closeDir(dir);

    var names: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (iter.next(fs.io) catch null) |entry| {
        if (entry.kind == .directory) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    return names.toOwnedSlice(allocator) catch &.{};
}

/// Build a merged MCP config JSON file for a role, combining:
///   1. The role's explicit mcp_config file (if any)
///   2. MCP servers from each referenced mc plugin
///
/// Writes to `output_path` and returns true if any servers were merged.
pub fn writeMergedMcpConfig(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    output_path: []const u8,
    role_mcp_config: ?[]const u8,
    plugins: []const role_mod.PluginRef,
) !bool {
    const plugins_dir = try getPluginsDir(allocator, project_root);
    defer allocator.free(plugins_dir);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n  \"mcpServers\": {");
    var count: usize = 0;

    // 1. Include servers from the role's explicit mcp_config
    if (role_mcp_config) |mcp_path| {
        const data = fs.readFileAlloc(allocator, mcp_path, 256 * 1024) catch null;
        if (data) |d| {
            defer allocator.free(d);
            count += try appendMcpServersFromJson(allocator, &buf, d, count, null, ".");
        }
    }

    // 2. Include servers from each referenced mc plugin
    for (plugins) |ref| {
        const mcp_path = try std.fmt.allocPrint(allocator, "{s}/{s}/.mcp.json", .{ plugins_dir, ref.name });
        defer allocator.free(mcp_path);

        const plugin_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugins_dir, ref.name });
        defer allocator.free(plugin_root);

        const data = fs.readFileAlloc(allocator, mcp_path, 256 * 1024) catch continue;
        defer allocator.free(data);

        const filter = if (ref.servers.len > 0) ref.servers else null;
        count += try appendMcpServersFromJson(allocator, &buf, data, count, filter, plugin_root);
    }

    try buf.appendSlice(allocator, "\n  }\n}\n");

    if (count == 0) return false;

    // Ensure parent directory exists
    if (std.fs.path.dirname(output_path)) |parent| {
        fs.makePath(parent) catch {};
    }

    const file = try fs.createFile(output_path, .{});
    try fs.writeFile(file, buf.items);
    fs.closeFile(file);
    return true;
}

/// Symlink plugin skills into the worktree's .claude/skills/ directory
/// so Claude Code discovers them natively.
///
/// Creates: {worktree}/.claude/skills/{skill-name} → {mc_plugins}/{plugin}/skills/{skill-name}
pub fn symlinkPluginSkills(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    worktree: []const u8,
    plugins: []const role_mod.PluginRef,
) !u32 {
    const plugins_dir = try getPluginsDir(allocator, project_root);
    defer allocator.free(plugins_dir);

    // Ensure .claude/skills/ exists in worktree
    const skills_dir = try std.fs.path.join(allocator, &.{ worktree, ".claude", "skills" });
    defer allocator.free(skills_dir);
    fs.makePath(skills_dir) catch {};

    var linked: u32 = 0;

    for (plugins) |ref| {
        const plugin_skills = try std.fmt.allocPrint(allocator, "{s}/{s}/skills", .{ plugins_dir, ref.name });
        defer allocator.free(plugin_skills);

        // Scan plugin's skills/ directory
        var dir = fs.openDir(plugin_skills) catch continue;
        defer fs.closeDir(dir);

        var iter = dir.iterate();
        while (iter.next(fs.io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            // Check if this skill has a SKILL.md
            const skill_md = try std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ plugin_skills, entry.name });
            defer allocator.free(skill_md);
            if (!fs.access(skill_md)) continue;

            // Create symlink: {worktree}/.claude/skills/{name} → {plugin}/skills/{name}
            const link_path = try std.fs.path.join(allocator, &.{ skills_dir, entry.name });
            defer allocator.free(link_path);

            const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugin_skills, entry.name });
            defer allocator.free(target);

            // Create symlink via Dir API (Zig 0.16)
            fs.cwd().symLink(fs.io, target, link_path, .{}) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => continue,
            };
            linked += 1;
        }
    }

    return linked;
}

/// Expand ${CLAUDE_PLUGIN_ROOT} in a string. Reimplemented locally
/// to avoid build dependency on mc.
fn expandPluginRoot(allocator: std.mem.Allocator, input: []const u8, plugin_root: []const u8) ![]const u8 {
    const needle = "${CLAUDE_PLUGIN_ROOT}";
    if (std.mem.indexOf(u8, input, needle) == null) return input;

    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (i + needle.len <= input.len and std.mem.eql(u8, input[i..][0..needle.len], needle)) {
            try result.appendSlice(allocator, plugin_root);
            i += needle.len;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator) catch input;
}

/// Parse MCP JSON and append server entries to the output buffer.
/// Returns number of servers appended.
fn appendMcpServersFromJson(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    json_data: []const u8,
    existing_count: usize,
    server_filter: ?[]const []const u8,
    plugin_root: []const u8,
) !usize {
    // Find "mcpServers" key and iterate its object entries.
    // We do lightweight JSON parsing here to avoid pulling in std.json
    // with its allocator requirements — just scan for key patterns.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{
        .allocate = .alloc_always,
    }) catch return 0;
    defer parsed.deinit();

    const root = parsed.value;
    const servers_val = switch (root) {
        .object => |obj| obj.get("mcpServers") orelse return 0,
        else => return 0,
    };
    const servers_obj = switch (servers_val) {
        .object => |obj| obj,
        else => return 0,
    };

    var count: usize = 0;
    var iter = servers_obj.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const cfg = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => continue,
        };

        // Apply server filter if specified
        if (server_filter) |filter| {
            var found = false;
            for (filter) |f| {
                if (std.mem.eql(u8, f, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;
        }

        // Emit this server
        if (existing_count + count > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "\n    \"");
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, "\": {");

        // command
        if (cfg.get("command")) |cmd_val| {
            if (cmd_val == .string) {
                const expanded = try expandPluginRoot(allocator, cmd_val.string, plugin_root);
                defer if (expanded.ptr != cmd_val.string.ptr) allocator.free(expanded);
                try buf.appendSlice(allocator, "\n      \"command\": \"");
                try buf.appendSlice(allocator, expanded);
                try buf.append(allocator, '"');
            }
        }

        // args
        if (cfg.get("args")) |args_val| {
            if (args_val == .array) {
                try buf.appendSlice(allocator, ",\n      \"args\": [");
                for (args_val.array.items, 0..) |item, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    if (item == .string) {
                        const expanded = try expandPluginRoot(allocator, item.string, plugin_root);
                        defer if (expanded.ptr != item.string.ptr) allocator.free(expanded);
                        try buf.append(allocator, '"');
                        try buf.appendSlice(allocator, expanded);
                        try buf.append(allocator, '"');
                    }
                }
                try buf.append(allocator, ']');
            }
        }

        // env
        if (cfg.get("env")) |env_val| {
            if (env_val == .object) {
                try buf.appendSlice(allocator, ",\n      \"env\": {");
                var env_iter = env_val.object.iterator();
                var env_i: usize = 0;
                while (env_iter.next()) |env_entry| {
                    if (env_i > 0) try buf.appendSlice(allocator, ",");
                    try buf.appendSlice(allocator, "\n        \"");
                    try buf.appendSlice(allocator, env_entry.key_ptr.*);
                    try buf.appendSlice(allocator, "\": \"");
                    if (env_entry.value_ptr.* == .string) {
                        const expanded = try expandPluginRoot(allocator, env_entry.value_ptr.string, plugin_root);
                        defer if (expanded.ptr != env_entry.value_ptr.string.ptr) allocator.free(expanded);
                        try buf.appendSlice(allocator, expanded);
                    }
                    try buf.append(allocator, '"');
                    env_i += 1;
                }
                try buf.appendSlice(allocator, "\n      }");
            }
        }

        try buf.appendSlice(allocator, "\n    }");
        count += 1;
    }

    return count;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "expandPluginRoot replaces template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expandPluginRoot(
        arena.allocator(),
        "${CLAUDE_PLUGIN_ROOT}/scripts/run.sh",
        "/home/user/.mc/plugins/my-plugin",
    );
    try std.testing.expectEqualStrings("/home/user/.mc/plugins/my-plugin/scripts/run.sh", result);
}

test "expandPluginRoot no-op when no template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = "just/a/normal/path";
    const result = try expandPluginRoot(arena.allocator(), input, "/root");
    try std.testing.expectEqualStrings("just/a/normal/path", result);
}

test "appendMcpServersFromJson parses valid config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const json =
        \\{
        \\  "mcpServers": {
        \\    "test-server": {
        \\      "command": "node",
        \\      "args": ["server.js", "--port", "3000"]
        \\    }
        \\  }
        \\}
    ;

    var buf: std.ArrayList(u8) = .empty;
    const count = try appendMcpServersFromJson(arena.allocator(), &buf, json, 0, null, "/test/root");
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "test-server") != null);
}

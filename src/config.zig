const std = @import("std");
const fs = @import("fs.zig");

pub const Config = struct {
    project: Project,
    workers: Workers = .{},
    merger: Merger = .{},
    sre: Sre = .{},
    strategist: Strategist = .{},
    qa: Qa = .{},
    api: Api = .{},
    daemon: Daemon = .{},
    git: Git = .{},
    build: Build = .{},
    serve: Serve = .{},
    smoke_test: SmokeTest = .{},
    timeouts: Timeouts = .{},

    pub const Project = struct {
        name: []const u8,
        base_branch: []const u8 = "main",
    };

    pub const Workers = struct {
        count: u32 = 5,
        model: []const u8 = "sonnet",
        effort: []const u8 = "high",
        max_budget_usd: f64 = 30.0,
        schedule: []const u8 = "0 * * * *",
    };

    pub const Merger = struct {
        model: []const u8 = "sonnet",
        effort: []const u8 = "high",
        max_budget_usd: f64 = 30.0,
        schedule: []const u8 = "45 * * * *",
        max_conflict_files: u32 = 5,
        merge_threshold: u32 = 3,
    };

    pub const Sre = struct {
        model: []const u8 = "sonnet",
        effort: []const u8 = "high",
        max_budget_usd: f64 = 30.0,
        cooldown_minutes: u32 = 60,
        max_turns: u32 = 10,
        tool_error_threshold: u32 = 3,
    };

    pub const Strategist = struct {
        model: []const u8 = "opus",
        effort: []const u8 = "high",
        max_budget_usd: f64 = 30.0,
        cycle_interval: u32 = 3,
        mcp_config: ?[]const u8 = null,
    };

    pub const Qa = struct {
        model: []const u8 = "opus",
        effort: []const u8 = "medium",
        max_budget_usd: f64 = 30.0,
        mcp_config: ?[]const u8 = null,
    };

    pub const Api = struct {
        port: u16 = 3002,
        enabled: bool = true,
        bind_address: []const u8 = "127.0.0.1",
    };

    pub const Daemon = struct {
        cooldown_minutes: u32 = 5,
        worker_timeout_minutes: u32 = 60,
        restart_timeout_minutes: u32 = 20,
        max_restarts: u32 = 2,
    };

    pub const Git = struct {
        shallow_worktrees: bool = true,
    };

    pub const Build = struct {
        command: ?[]const u8 = null,
        test_command: ?[]const u8 = null,
        deploy_command: ?[]const u8 = null,
        setup_command: ?[]const u8 = null,
    };

    pub const Serve = struct {
        systemd_unit: ?[]const u8 = null,
        health_url: ?[]const u8 = null,
        health_timeout_secs: u32 = 30,
    };

    pub const SmokeTest = struct {
        enabled: bool = false,
        urls: []const []const u8 = &.{},
        port: u16 = 8080,
        startup_wait_secs: u32 = 10,
    };

    pub const Timeouts = struct {
        max_idle_secs: u32 = 600,
        stale_hours: u32 = 24,
        cleanup_hours: u32 = 72,
    };
};

pub const ProjectPaths = struct {
    root: []const u8,
    bees_dir: []const u8,
    config_file: []const u8,
    tasks_file: []const u8,
    db_dir: []const u8,
    logs_dir: []const u8,
    prompts_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, project_root: []const u8) !ProjectPaths {
        const bees_dir = try std.fs.path.join(allocator, &.{ project_root, ".bees" });
        return .{
            .root = project_root,
            .bees_dir = bees_dir,
            .config_file = try std.fs.path.join(allocator, &.{ bees_dir, "config.json" }),
            .tasks_file = try std.fs.path.join(allocator, &.{ bees_dir, "tasks.json" }),
            .db_dir = try std.fs.path.join(allocator, &.{ bees_dir, "db" }),
            .logs_dir = try std.fs.path.join(allocator, &.{ bees_dir, "logs" }),
            .prompts_dir = try std.fs.path.join(allocator, &.{ bees_dir, "prompts" }),
        };
    }
};

/// Walk up from start_dir looking for .bees/config.json
pub fn findProjectRoot(allocator: std.mem.Allocator, start_dir: []const u8) !?[]const u8 {
    var current = try allocator.dupe(u8, start_dir);
    while (true) {
        const config_path = try std.fs.path.join(allocator, &.{ current, ".bees", "config.json" });
        defer allocator.free(config_path);
        if (fs.access(config_path)) {
            return current;
        }

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        const new = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = new;
    }
}

/// Load and parse config.json
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const data = try fs.readFileAlloc(allocator, path, 1024 * 1024);
    const parsed = try std.json.parseFromSlice(Config, allocator, data, .{
        .allocate = .alloc_always,
    });
    return parsed.value;
}

test "default config values" {
    const cfg = Config{
        .project = .{ .name = "test" },
    };
    try std.testing.expectEqual(@as(u32, 5), cfg.workers.count);
    try std.testing.expectEqualStrings("main", cfg.project.base_branch);
    try std.testing.expectEqualStrings("sonnet", cfg.workers.model);
    try std.testing.expectEqual(@as(f64, 30.0), cfg.workers.max_budget_usd);
    try std.testing.expectEqual(false, cfg.smoke_test.enabled);
}

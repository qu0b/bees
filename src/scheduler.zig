const std = @import("std");
const Io = std.Io;
const config_mod = @import("config.zig");
const git = @import("git.zig");
const fs = @import("fs.zig");

pub fn generateAndInstall(cfg: config_mod.Config, bees_path: []const u8, project_path: []const u8, allocator: std.mem.Allocator) !void {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.sliceTo(home_ptr, 0);
    const systemd_dir = try std.fmt.allocPrint(allocator, "{s}/.config/systemd/user", .{home});
    defer allocator.free(systemd_dir);
    fs.makePath(systemd_dir) catch {};

    // Daemon service (long-running orchestrator)
    try writeDaemonUnit(allocator, systemd_dir, cfg.project.name, .{
        .description = try std.fmt.allocPrint(allocator, "Bees daemon ({s})", .{cfg.project.name}),
        .exec_start = try std.fmt.allocPrint(allocator, "{s} daemon", .{bees_path}),
        .working_directory = project_path,
    });
}

const DaemonOpts = struct {
    description: []const u8,
    exec_start: []const u8,
    working_directory: []const u8,
};

fn writeDaemonUnit(allocator: std.mem.Allocator, systemd_dir: []const u8, project_name: []const u8, opts: DaemonOpts) !void {
    const filename = try std.fmt.allocPrint(allocator, "{s}/bees-{s}.service", .{ systemd_dir, project_name });
    defer allocator.free(filename);

    const file = try fs.createFile(filename, .{});
    defer fs.closeFile(file);

    try fs.filePrint(file,
        \\[Unit]
        \\Description={s}
        \\After=network-online.target
        \\
        \\[Service]
        \\Type=simple
        \\WorkingDirectory={s}
        \\ExecStart={s}
        \\Restart=always
        \\RestartSec=30
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{
        opts.description,
        opts.working_directory,
        opts.exec_start,
    });
}

pub fn start(cfg: config_mod.Config, io: Io, allocator: std.mem.Allocator) !void {
    const service_name = try std.fmt.allocPrint(allocator, "bees-{s}.service", .{cfg.project.name});
    const commands = [_][]const []const u8{
        &.{ "systemctl", "--user", "daemon-reload" },
        &.{ "systemctl", "--user", "enable", "--now", service_name },
        &.{ "loginctl", "enable-linger" },
    };

    for (commands) |cmd| {
        const result = git.run(allocator, io, cmd, "/") catch continue;
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
}

pub fn stop(cfg: config_mod.Config, io: Io, allocator: std.mem.Allocator) !void {
    const service_name = try std.fmt.allocPrint(allocator, "bees-{s}.service", .{cfg.project.name});
    const commands = [_][]const []const u8{
        &.{ "systemctl", "--user", "disable", "--now", service_name },
    };

    for (commands) |cmd| {
        const result = git.run(allocator, io, cmd, "/") catch continue;
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
}


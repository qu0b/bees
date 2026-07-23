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

    // Bake the invoking shell's PATH into the unit: systemd user units get a
    // bare default PATH (/usr/bin:/bin), so agent CLIs installed in ~/.local/bin,
    // ~/.bun/bin, nvm, etc. would be FileNotFound at spawn time. Capturing the
    // PATH from `bees start` reproduces the environment the user tested with.
    const path_env = if (std.c.getenv("PATH")) |p| std.mem.sliceTo(p, 0) else "/usr/local/bin:/usr/bin:/bin";

    try fs.filePrint(file,
        \\[Unit]
        \\Description={s}
        \\After=network-online.target
        \\
        \\[Service]
        \\Type=simple
        \\WorkingDirectory={s}
        \\Environment="PATH={s}"
        \\ExecStart={s}
        \\Restart=always
        \\RestartSec=30
        \\TimeoutStopSec=30
        \\RestartPreventExitStatus=64
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{
        opts.description,
        opts.working_directory,
        path_env,
        opts.exec_start,
    });
}

pub const unit_prefix = "bees-";

pub fn serviceName(cfg: config_mod.Config, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}.service", .{ unit_prefix, cfg.project.name });
}

/// Run a `systemctl --user` (or loginctl) command, returning stderr + exit code
/// so callers can report failures honestly instead of pretending success.
/// When the session lacks the user-bus environment (common over ssh/sudo —
/// "Failed to connect to bus: No medium found"), prepend the standard
/// XDG_RUNTIME_DIR / DBUS_SESSION_BUS_ADDRESS for this uid via `env`.
pub fn runCtl(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !git.GitResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    if (std.c.getenv("XDG_RUNTIME_DIR") == null or std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) {
        const uid = std.c.getuid();
        try argv.append(allocator, "env");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "XDG_RUNTIME_DIR=/run/user/{d}", .{uid}));
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{d}/bus", .{uid}));
    }
    try argv.appendSlice(allocator, args);
    return git.run(allocator, io, argv.items, "/");
}

/// Current unit state via `is-active`: "active", "activating", "failed",
/// "inactive", or "unknown" on any error. Caller owns nothing (static fallback
/// or slice into freed buffer avoided by duping).
pub fn unitState(cfg: config_mod.Config, io: Io, allocator: std.mem.Allocator) []const u8 {
    const service = serviceName(cfg, allocator) catch return "unknown";
    const result = runCtl(allocator, io, &.{ "systemctl", "--user", "is-active", service }) catch return "unknown";
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return "unknown";
    return allocator.dupe(u8, trimmed) catch "unknown";
}

/// The unit's last Result property ("success", "timeout", "exit-code", ...).
pub fn unitResult(cfg: config_mod.Config, io: Io, allocator: std.mem.Allocator) []const u8 {
    const service = serviceName(cfg, allocator) catch return "unknown";
    const result = runCtl(allocator, io, &.{ "systemctl", "--user", "show", "-p", "Result", "--value", service }) catch return "unknown";
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return "unknown";
    return allocator.dupe(u8, trimmed) catch "unknown";
}

pub const CtlError = struct {
    /// Which command failed (for the error message).
    what: []const u8 = "",
    /// systemctl's stderr (trimmed), the actual reason.
    detail: []const u8 = "",
};

/// Enable + start the unit. On failure returns the failing command's stderr so
/// the caller can show WHY (e.g. a missing user bus) instead of a false
/// "started" message. loginctl enable-linger stays best-effort — it only
/// affects survival after logout, not the start itself.
pub fn start(cfg: config_mod.Config, io: Io, allocator: std.mem.Allocator, err_out: *CtlError) !void {
    const service = try serviceName(cfg, allocator);

    const steps = [_]struct { what: []const u8, argv: []const []const u8 }{
        .{ .what = "daemon-reload", .argv = &.{ "systemctl", "--user", "daemon-reload" } },
        .{ .what = "enable --now", .argv = &.{ "systemctl", "--user", "enable", "--now", service } },
    };
    for (steps) |step| {
        const result = runCtl(allocator, io, step.argv) catch |e| {
            err_out.* = .{ .what = step.what, .detail = @errorName(e) };
            return error.SystemctlFailed;
        };
        defer allocator.free(result.stdout);
        if (result.exit_code != 0) {
            err_out.* = .{ .what = step.what, .detail = std.mem.trim(u8, result.stderr, &std.ascii.whitespace) };
            return error.SystemctlFailed;
        }
        allocator.free(result.stderr);
    }

    // Best-effort: keep user units running after logout.
    if (runCtl(allocator, io, &.{ "loginctl", "enable-linger" })) |r| {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    } else |_| {}
}

/// Disable + stop the unit. Returns the failure reason on error. Callers should
/// read `unitResult` (to report a timeout-kill) BEFORE calling `resetFailed` —
/// resetting clears the Result property.
pub fn stop(cfg: config_mod.Config, io: Io, allocator: std.mem.Allocator, err_out: *CtlError) !void {
    const service = try serviceName(cfg, allocator);

    const result = runCtl(allocator, io, &.{ "systemctl", "--user", "disable", "--now", service }) catch |e| {
        err_out.* = .{ .what = "disable --now", .detail = @errorName(e) };
        return error.SystemctlFailed;
    };
    defer allocator.free(result.stdout);
    if (result.exit_code != 0) {
        err_out.* = .{ .what = "disable --now", .detail = std.mem.trim(u8, result.stderr, &std.ascii.whitespace) };
        return error.SystemctlFailed;
    }
    allocator.free(result.stderr);
}

/// Clear the unit's failed state so `list-units` isn't littered with dead red
/// entries after a stop or a circuit-breaker halt. Best-effort.
pub fn resetFailed(cfg: config_mod.Config, io: Io, allocator: std.mem.Allocator) void {
    const service = serviceName(cfg, allocator) catch return;
    if (runCtl(allocator, io, &.{ "systemctl", "--user", "reset-failed", service })) |r| {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    } else |_| {}
}


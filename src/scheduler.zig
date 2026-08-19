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
    try writeDaemonUnit(allocator, systemd_dir, cfg, .{
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

fn writeDaemonUnit(allocator: std.mem.Allocator, systemd_dir: []const u8, cfg: config_mod.Config, opts: DaemonOpts) !void {
    const project_name = cfg.project.name;
    const filename = try std.fmt.allocPrint(allocator, "{s}/bees-{s}.service", .{ systemd_dir, project_name });
    defer allocator.free(filename);

    // The gateway key lives in the invoking shell (~/.bashrc), which a systemd
    // user unit never sources: without this the daemon starts and immediately
    // exits with GatewayKeyMissing, so `bees start` only ever worked for
    // hand-started daemons. Bake it beside the unit in a 0600 EnvironmentFile
    // rather than into the world-readable unit body.
    const env_file = try writeGatewayEnvFile(allocator, systemd_dir, cfg);
    defer if (env_file) |f| allocator.free(f);

    const file = try fs.createFile(filename, .{});
    defer fs.closeFile(file);

    // Bake the invoking shell's PATH into the unit: systemd user units get a
    // bare default PATH (/usr/bin:/bin), so agent CLIs installed in ~/.local/bin,
    // ~/.bun/bin, nvm, etc. would be FileNotFound at spawn time. Capturing the
    // PATH from `bees start` reproduces the environment the user tested with.
    const path_env = if (std.c.getenv("PATH")) |p| std.mem.sliceTo(p, 0) else "/usr/local/bin:/usr/bin:/bin";

    // `-` prefix: a removed env file must not block the daemon from starting
    // (it still reports GatewayKeyMissing itself, which names the real cause).
    const env_file_line = if (env_file) |f|
        try std.fmt.allocPrint(allocator, "EnvironmentFile=-{s}\n", .{f})
    else
        "";
    defer if (env_file != null) allocator.free(env_file_line);

    try fs.filePrint(file,
        \\[Unit]
        \\Description={s}
        \\After=network-online.target
        \\
        \\[Service]
        \\Type=simple
        \\WorkingDirectory={s}
        \\Environment="PATH={s}"
        \\{s}ExecStart={s}
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
        env_file_line,
        opts.exec_start,
    });
}

/// Write `<systemd_dir>/bees-<project>.env` holding the gateway API key, and
/// return the path (caller owns) so the unit can reference it.
///
/// Returns null — leaving the unit unchanged — when the gateway is off or the
/// key is absent from this process's environment. A null here is not silent
/// breakage: the daemon still fails with the explicit GatewayKeyMissing error,
/// which is the honest report that `bees start` was run from a shell that
/// never had the key.
fn writeGatewayEnvFile(allocator: std.mem.Allocator, systemd_dir: []const u8, cfg: config_mod.Config) !?[]const u8 {
    if (!cfg.gateway.enabled) return null;

    var name_buf: [256]u8 = undefined;
    if (cfg.gateway.api_key_env.len >= name_buf.len) return null;
    @memcpy(name_buf[0..cfg.gateway.api_key_env.len], cfg.gateway.api_key_env);
    name_buf[cfg.gateway.api_key_env.len] = 0;
    const key_ptr = std.c.getenv(@ptrCast(&name_buf)) orelse return null;
    const key = std.mem.sliceTo(key_ptr, 0);
    if (key.len == 0) return null;

    const path = try std.fmt.allocPrint(allocator, "{s}/bees-{s}.env", .{ systemd_dir, cfg.project.name });
    errdefer allocator.free(path);

    const file = try fs.createFile(path, .{});
    defer fs.closeFile(file);
    // 0600 before the secret is written: the key is a credential and the unit
    // directory is not private. Zig 0.16's CreateFlags carries no mode, so the
    // permission is narrowed on the open handle first.
    if (std.c.fchmod(file.handle, 0o600) != 0) return error.ChmodFailed;
    try fs.filePrint(file, "{s}={s}\n", .{ cfg.gateway.api_key_env, key });
    return path;
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


const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const worker = @import("worker.zig");
const merger = @import("merger.zig");
const security_profiles = @import("security_profiles.zig");
const tasks_mod = @import("tasks.zig");
const git = @import("git.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");
const types = @import("types.zig");
const ctx = @import("context.zig");
const role_mod = @import("role.zig");
const workflow_mod = @import("workflow.zig");
const executor = @import("executor.zig");
const sync_mod = @import("db/sync.zig");
const api = @import("api.zig");
const MAX_WORKERS = 32;

const backend = @import("backend.zig");

/// Returned by `run` to tell the caller how the daemon loop ended.
pub const DaemonAction = enum { shutdown, reload };

/// Shared daemon state — accessed via atomics for cross-green-thread safety.
const DaemonState = struct {
    done_count: u32 = 0,
    active_count: u32 = 0,
    next_worker_id: u32 = 1,
    /// Set to 1 by signal handler to request graceful shutdown.
    shutdown_requested: u32 = 0,
    /// Session IDs that completed with tool errors above threshold.
    /// Workers write here; main loop reads and drains.
    sre_trigger_sessions: [64]u64 = [_]u64{0} ** 64,
    sre_trigger_count: u32 = 0,
};

/// Global pointer for signal handler (signals can't capture context).
var g_daemon_state: ?*DaemonState = null;

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    if (g_daemon_state) |state| {
        @atomicStore(u32, &state.shutdown_requested, 1, .release);
    }
}

fn installSignalHandlers(state: *DaemonState) void {
    g_daemon_state = state;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = .{0} ** @typeInfo(std.posix.sigset_t).array.len,
        .flags = @bitCast(@as(u32, std.c.SA.RESTART)),
    };
    std.posix.sigaction(std.c.SIG.TERM, &act, null);
    std.posix.sigaction(std.c.SIG.INT, &act, null);
}

/// I/O-cooperative sleep — yields to the event loop so other green threads
/// (API server, workers, SRE) keep making progress.
pub fn sleep_secs(io: Io, secs: u64) void {
    io.sleep(Io.Duration.fromSeconds(@intCast(secs)), .awake) catch {};
}

/// Returns true if current UTC time is within the configured quiet window.
/// During quiet hours the daemon suppresses new work to conserve usage quota.
fn isQuietHour(daemon: config_mod.Config.Daemon) bool {
    const start = daemon.quiet_start_utc orelse return false;
    const end = daemon.quiet_end_utc orelse return false;
    if (start > 23 or end > 23) return false;

    const now = fs.timestamp();

    if (daemon.quiet_weekdays_only) {
        // 0=Sun 1=Mon .. 5=Fri 6=Sat  (Jan 1 1970 = Thursday)
        const day = @as(u8, @intCast(((now / 86400) + 4) % 7));
        if (day == 0 or day == 6) return false;
    }

    const hour = @as(u8, @intCast((now % 86400) / 3600));
    if (start <= end) {
        return hour >= start and hour < end;
    } else {
        return hour >= start or hour < end;
    }
}

pub fn run(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) !DaemonAction {
    logger.info("[daemon] starting — workers={d} threshold={d} timeout={d}min cooldown={d}min", .{
        cfg.workers.count,                 cfg.merger.merge_threshold,
        cfg.daemon.worker_timeout_minutes, cfg.daemon.cooldown_minutes,
    });

    var state = DaemonState{};
    installSignalHandlers(&state);

    // Start REST API server as a background green thread
    if (cfg.api.enabled) {
        _ = io.async(api.startApiServer, .{
            store, cfg, paths, logger, io, allocator, cfg.api.port,
        });
        logger.info("[daemon] API server started on port {d}", .{cfg.api.port});
    }

    // Mark any stale "running" sessions as "error" from previous daemon crash
    cleanupStaleSessions(store, logger);

    // Track merge cycles for strategist scheduling (survives reload via LMDB)
    var merge_cycle: u32 = loadMergeCycle(store);

    // Bootstrap: sync tasks.json into LMDB
    tasks_mod.syncFromFile(store, paths.tasks_file, allocator) catch |e| {
        logger.warn("[daemon] initial task sync failed: {}", .{e});
    };

    // Wait out quiet hours before spending quota on startup strategist
    if (isQuietHour(cfg.daemon)) {
        logger.info("[daemon] quiet hours active (UTC {d}:00-{d}:00, weekdays only={s}), waiting...", .{
            cfg.daemon.quiet_start_utc.?,                        cfg.daemon.quiet_end_utc.?,
            if (cfg.daemon.quiet_weekdays_only) "yes" else "no",
        });
        while (isQuietHour(cfg.daemon)) {
            sleep_secs(io, 300);
        }
        logger.info("[daemon] quiet hours ended, resuming", .{});
    }

    // Always run strategist at startup to refresh stale tasks before spawning workers
    logger.info("[daemon] running startup strategist to refresh tasks", .{});
    runStrategistWithPrep(cfg, paths, store, logger, io, allocator);
    tasks_mod.syncFromFile(store, paths.tasks_file, allocator) catch {};

    // Preflight: verify Claude CLI is reachable before spawning workers.
    preflight: {
        const pf_argv = [_][]const u8{ "claude", "--version" };
        var pf_child = std.process.spawn(io, .{
            .argv = &pf_argv,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |e| {
            logger.err("[daemon] preflight FAILED: claude CLI not found ({s}). Install it or check PATH.", .{@errorName(e)});
            break :preflight;
        };
        _ = pf_child.wait(io) catch |e| {
            logger.err("[daemon] preflight FAILED: claude CLI error ({s})", .{@errorName(e)});
            break :preflight;
        };
        logger.info("[daemon] preflight passed: claude CLI is reachable", .{});
    }

    // Sync LMDB → SQLite so dashboard has data
    syncToSqlite(paths, store, logger, allocator);

    // Load tasks from LMDB (single source of truth)
    var pool = tasks_mod.TaskPool.loadFromStore(store, allocator) catch
        try tasks_mod.TaskPool.load(allocator, paths.tasks_file);
    if (!pool.hasActiveTasks()) {
        logger.warn("[daemon] no active tasks after startup strategist, waiting for SRE/manual intervention", .{});
    }

    // Spawn initial workers as green threads
    if (pool.hasActiveTasks()) {
        const spawn_count = @min(cfg.workers.count, MAX_WORKERS);
        for (0..spawn_count) |_| {
            spawnWorker(cfg, paths, store, pool, logger, io, allocator, &state);
        }
    }

    // Main loop — polls via cooperative sleep
    var was_quiet = false;
    var consecutive_empty_merges: u32 = 0;
    while (@atomicLoad(u32, &state.shutdown_requested, .acquire) == 0) {
        sleep_secs(io, 10);

        // Graceful shutdown: stop spawning, wait for running workers to drain
        if (@atomicLoad(u32, &state.shutdown_requested, .acquire) != 0) break;

        // Quiet hours — let running workers finish but don't start new work
        if (isQuietHour(cfg.daemon)) {
            if (!was_quiet) {
                logger.info("[daemon] entering quiet hours, pausing new work", .{});
                was_quiet = true;
            }
            sleep_secs(io, 300);
            continue;
        }
        if (was_quiet) {
            logger.info("[daemon] quiet hours ended, resuming", .{});
            was_quiet = false;
        }

        // Check completion threshold
        const current_done = @atomicLoad(u32, &state.done_count, .acquire);

        if (current_done >= cfg.merger.merge_threshold) {
            logger.info("[daemon] {d} workers completed, triggering merger", .{current_done});

            // Capture HEAD before merge for diff-aware QA
            const pre_merge_head = git.getCurrentHead(allocator, io, paths.root) catch null;

            merger.runMerger(cfg, paths, store, logger, io, allocator) catch |e| {
                logger.err("[daemon] merger failed: {}", .{e});
            };

            _ = @atomicRmw(u32, &state.done_count, .Sub, cfg.merger.merge_threshold, .release);

            // Detect changed files for QA
            const changed_files: ?[]const u8 = if (pre_merge_head) |pmh| blk: {
                defer allocator.free(pmh);
                const post_head = git.getCurrentHead(allocator, io, paths.root) catch break :blk null;
                defer allocator.free(post_head);
                if (std.mem.eql(u8, pmh, std.mem.trim(u8, post_head, &std.ascii.whitespace)))
                    break :blk null;
                break :blk git.getChangedFiles(allocator, io, paths.root, pmh, post_head) catch null;
            } else null;
            defer if (changed_files) |cf| allocator.free(cf);

            if (changed_files == null) {
                consecutive_empty_merges += 1;
                if (consecutive_empty_merges >= 3) {
                    logger.err("[daemon] circuit breaker: {d} consecutive cycles with 0 accepted merges", .{consecutive_empty_merges});
                }
            } else {
                consecutive_empty_merges = 0;
            }

            // Self-hosted reload: detect if source .zig files changed
            const source_changed = cfg.daemon.self_hosted and
                sourceFilesChanged(changed_files);

            // Build + restart once (serves QA, user agent, and strategist)
            prepareForStrategist(cfg, paths, logger, io, allocator);

            // Precompute shared context values
            const worker_summary = ctx.buildWorkerSummary(store, null, allocator);
            defer if (worker_summary) |ws| allocator.free(ws);

            // Load workflow and roles
            const wf = workflow_mod.load(paths, allocator);
            const roles = role_mod.loadRoles(paths, allocator) catch role_mod.RoleSet{
                .roles = std.StringHashMap(role_mod.RoleConfig).init(allocator),
                .allocator = allocator,
            };

            merge_cycle += 1;

            // Execute post-merger workflow steps (skip worker and merger — already handled)
            for (wf.steps) |step| {
                if (@atomicLoad(u32, &state.shutdown_requested, .acquire) != 0) break;

                // Worker and merger are handled by the outer loop
                if (std.mem.eql(u8, step.role, "worker")) continue;
                if (std.mem.eql(u8, step.role, "merger")) continue;

                // Periodic steps: skip if not this cycle
                if (!workflow_mod.Workflow.shouldRunStep(&step, merge_cycle)) {
                    logger.info("[daemon] skipping {s} (cycle {d}, every {d})", .{ step.role, merge_cycle, step.every });
                    continue;
                }

                // Conditional steps
                if (std.mem.eql(u8, step.condition, "tool_errors")) {
                    if (@atomicLoad(u32, &state.sre_trigger_count, .acquire) == 0) continue;
                    drainSreTriggers(cfg, paths, store, logger, io, allocator, &state);
                    continue;
                }

                // Write task trends before strategist
                if (std.mem.eql(u8, step.role, "strategist")) {
                    writeTaskTrends(cfg, paths, store, logger, allocator);
                }

                // Resolve role config — try roles dir, fall back to hardcoded defaults
                const role_cfg = roles.get(step.role) orelse role_mod.RoleConfig{ .name = step.role };

                // Build context from role's declared sources (including knowledge tags)
                const resolved = role_mod.resolveContextSources(role_cfg, allocator);
                const step_extras = ctx.Extras{
                    .changed_files = changed_files,
                    .worker_summary = worker_summary,
                    .knowledge_tags = resolved.knowledge_tags,
                };
                const step_ctx = if (resolved.sources.len > 0)
                    ctx.build(store, paths, resolved.sources, step_extras, allocator)
                else
                    null;
                defer if (step_ctx) |sc| allocator.free(sc);

                // Map role name to session type
                const session_type = mapRoleToSessionType(step.role) orelse {
                    logger.warn("[daemon] unknown role '{s}', skipping", .{step.role});
                    continue;
                };

                // Run through generic executor
                executor.runRole(
                    role_cfg,
                    session_type,
                    step.role,
                    paths,
                    store,
                    logger,
                    io,
                    allocator,
                    step_ctx,
                    false,
                    cfg.default_backend,
                ) catch |e| {
                    logger.err("[daemon] {s} failed: {}", .{ step.role, e });
                };
            }

            // Drain any remaining SRE triggers not handled by workflow
            drainSreTriggers(cfg, paths, store, logger, io, allocator, &state);

            // Clean up leaked Chrome renderer processes between cycles
            backend.cleanupChrome(io);

            // Sync LMDB → SQLite for dashboard
            syncToSqlite(paths, store, logger, allocator);

            // Cooldown
            const cooldown_secs = @as(u64, cfg.daemon.cooldown_minutes) * 60;
            logger.info("[daemon] cooling down for {d} minutes", .{cfg.daemon.cooldown_minutes});
            sleep_secs(io, cooldown_secs);

            // Sync tasks.json into LMDB and reload from store
            tasks_mod.syncFromFile(store, paths.tasks_file, allocator) catch {};
            reloadPool(&pool, store, paths.tasks_file, allocator);

            // Self-hosted hot reload: persist state and return to caller for execve
            if (source_changed) {
                logger.info("[daemon] source code changed, initiating hot reload", .{});
                persistMergeCycle(store, merge_cycle, logger);

                // Drain active workers before replacing the binary
                const active = @atomicLoad(u32, &state.active_count, .acquire);
                if (active > 0) {
                    logger.info("[daemon] waiting for {d} active workers to finish before reload...", .{active});
                    var wait: u32 = 0;
                    while (@atomicLoad(u32, &state.active_count, .acquire) > 0 and wait < 300) {
                        sleep_secs(io, 5);
                        wait += 5;
                    }
                }
                return .reload;
            }

            if (!pool.hasActiveTasks()) {
                logger.info("[daemon] all tasks exhausted, running strategist", .{});
                runStrategistWithPrep(cfg, paths, store, logger, io, allocator);
                tasks_mod.syncFromFile(store, paths.tasks_file, allocator) catch {};
                reloadPool(&pool, store, paths.tasks_file, allocator);
            }

            // Refill workers (only if there's work to do)
            if (pool.hasActiveTasks()) {
                const current_active = @atomicLoad(u32, &state.active_count, .acquire);
                const need = @min(cfg.workers.count, MAX_WORKERS) -| current_active;
                if (need > 0) {
                    logger.info("[daemon] spawning {d} new workers", .{need});
                    for (0..need) |_| {
                        spawnWorker(cfg, paths, store, pool, logger, io, allocator, &state);
                    }
                }
            } else {
                logger.warn("[daemon] no active tasks, skipping worker spawn — waiting for next cycle", .{});
            }
        }
    }

    // Graceful shutdown: wait for running workers to finish
    logger.info("[daemon] shutdown requested, waiting for {d} active workers to finish...", .{
        @atomicLoad(u32, &state.active_count, .acquire),
    });
    var shutdown_wait: u32 = 0;
    const shutdown_timeout: u32 = 300; // 5 minutes max wait
    while (@atomicLoad(u32, &state.active_count, .acquire) > 0 and shutdown_wait < shutdown_timeout) {
        sleep_secs(io, 5);
        shutdown_wait += 5;
    }
    if (@atomicLoad(u32, &state.active_count, .acquire) > 0) {
        logger.warn("[daemon] shutdown timeout, {d} workers still active", .{
            @atomicLoad(u32, &state.active_count, .acquire),
        });
    }
    logger.info("[daemon] shutdown complete", .{});
    return .shutdown;
}

/// Spawn a single worker as an async green thread.
fn spawnWorker(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: tasks_mod.TaskPool,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
    state: *DaemonState,
) void {
    const wid = @atomicRmw(u32, &state.next_worker_id, .Add, 1, .monotonic);
    _ = @atomicRmw(u32, &state.active_count, .Add, 1, .release);

    const timeout_secs: u32 = if (cfg.daemon.worker_timeout_minutes > 0)
        cfg.daemon.worker_timeout_minutes * 60
    else
        0;

    _ = io.async(workerTask, .{
        cfg, paths, store, pool, logger, io, wid, allocator, timeout_secs, state,
    });
}

/// Green thread entry point for a worker.
fn workerTask(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: tasks_mod.TaskPool,
    logger: *log_mod.Logger,
    io: Io,
    wid: u32,
    allocator: std.mem.Allocator,
    timeout_secs: u32,
    state: *DaemonState,
) void {
    defer {
        _ = @atomicRmw(u32, &state.done_count, .Add, 1, .release);
        _ = @atomicRmw(u32, &state.active_count, .Sub, 1, .release);
    }
    const result = worker.runWorkerWithTimeout(cfg, paths, store, &pool, logger, io, wid, allocator, timeout_secs) catch |e| {
        logger.err("[worker:{d}] fatal: {}", .{ wid, e });
        return;
    };

    // If tool errors exceed threshold, queue SRE trigger
    if (result.tool_errors >= cfg.sre.tool_error_threshold and result.session_id > 0) {
        const idx = @atomicRmw(u32, &state.sre_trigger_count, .Add, 1, .monotonic);
        if (idx < state.sre_trigger_sessions.len) {
            state.sre_trigger_sessions[idx] = result.session_id;
        }
        logger.info("[worker:{d}] queued SRE trigger: session {d} had {d} tool errors", .{
            wid, result.session_id, result.tool_errors,
        });
    }
}

fn cleanupStaleSessions(store: *store_mod.Store, logger: *log_mod.Logger) void {
    const count = store.cleanupStaleSessions();
    if (count > 0) {
        logger.info("[daemon] cleaned up {d} stale running sessions from previous run", .{count});
    }
}

/// Drain queued SRE triggers — collect tool errors from sessions that exceeded
/// the threshold, build a combined context, and run a single SRE session.
fn drainSreTriggers(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
    state: *DaemonState,
) void {
    const count = @atomicRmw(u32, &state.sre_trigger_count, .Xchg, 0, .acquire);
    if (count == 0) return;

    const n = @min(count, @as(u32, @intCast(state.sre_trigger_sessions.len)));
    logger.info("[daemon] {d} sessions triggered SRE, collecting tool errors", .{n});

    // Collect error context from all triggering sessions
    var context: std.ArrayList(u8) = .empty;
    defer context.deinit(allocator);
    var first_session_id: u64 = 0;

    for (0..n) |i| {
        const sid = state.sre_trigger_sessions[i];
        state.sre_trigger_sessions[i] = 0;
        if (sid == 0) continue;
        if (first_session_id == 0) first_session_id = sid;

        if (backend.collectToolErrors(store, sid, allocator)) |errors| {
            defer allocator.free(errors);
            context.appendSlice(allocator, errors) catch continue;
            context.append(allocator, '\n') catch continue;
        }
    }

    if (context.items.len == 0 or first_session_id == 0) {
        logger.info("[daemon] no tool errors to report to SRE", .{});
        return;
    }

    logger.info("[daemon] running SRE agent for tool error diagnosis", .{});

    // Format error context for injection into the SRE prompt.
    const sre_context = std.fmt.allocPrint(
        allocator,
        "\n\n## Tool Errors That Triggered This Run\n\nThe following tool errors were observed in session {d}. Diagnose the root cause and fix the configuration, prompts, or tasks to prevent recurrence.\n\n{s}",
        .{ first_session_id, context.items },
    ) catch null;
    defer if (sre_context) |sc| allocator.free(sc);

    const roles = role_mod.loadRoles(paths, allocator) catch role_mod.RoleSet{
        .roles = std.StringHashMap(role_mod.RoleConfig).init(allocator),
        .allocator = allocator,
    };
    const role_cfg = roles.get("sre") orelse role_mod.RoleConfig{
        .name = "sre",
        .model = cfg.sre.model,
        .fallback_model = cfg.sre.fallback_model,
        .effort = cfg.sre.effort,
        .max_budget_usd = cfg.sre.max_budget_usd,
        .max_turns = cfg.sre.max_turns,
        .stores_report = true,
    };

    executor.runRole(
        role_cfg,
        .sre,
        "sre",
        paths,
        store,
        logger,
        io,
        allocator,
        sre_context,
        false,
        cfg.default_backend,
    ) catch |e| {
        logger.err("[sre] fatal: {}", .{e});
    };
}

/// Build the project and restart the serve process before the strategist runs.
fn prepareForStrategist(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) void {
    if (cfg.build.command) |build_cmd| {
        logger.info("[daemon] pre-strategist build: {s}", .{build_cmd});
        const result = git.run(allocator, io, &.{ "sh", "-c", build_cmd }, paths.root) catch |e| {
            logger.warn("[daemon] pre-strategist build spawn failed: {}", .{e});
            return;
        };
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        if (result.exit_code != 0) {
            logger.warn("[daemon] pre-strategist build exited {d}, continuing anyway", .{result.exit_code});
        }
    }

    if (cfg.serve.systemd_unit) |unit| {
        logger.info("[daemon] restarting serve unit: {s}", .{unit});
        const result = git.run(allocator, io, &.{ "systemctl", "--user", "restart", unit }, paths.root) catch |e| {
            logger.warn("[daemon] systemctl restart failed: {}", .{e});
            return;
        };
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        if (result.exit_code != 0) {
            logger.warn("[daemon] systemctl restart exited {d}", .{result.exit_code});
        }
    }

    if (cfg.serve.health_url) |url| {
        logger.info("[daemon] waiting for serve health: {s}", .{url});
        const deadline = cfg.serve.health_timeout_secs;
        var elapsed: u32 = 0;
        while (elapsed < deadline) : (elapsed += 2) {
            const result = git.run(allocator, io, &.{
                "curl", "-sf", "-o", "/dev/null", "--max-time", "2", url,
            }, paths.root) catch {
                sleep_secs(io, 2);
                continue;
            };
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            if (result.exit_code == 0) {
                logger.info("[daemon] serve is healthy after {d}s", .{elapsed});
                return;
            }
            sleep_secs(io, 2);
        }
        logger.warn("[daemon] serve health check timed out after {d}s, strategist will proceed without live server", .{deadline});
    }
}

fn runStrategistWithPrep(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) void {
    prepareForStrategist(cfg, paths, logger, io, allocator);
    writeTaskTrends(cfg, paths, store, logger, allocator);

    // Load role config for strategist
    const roles = role_mod.loadRoles(paths, allocator) catch return;
    const role_cfg = roles.get("strategist") orelse role_mod.RoleConfig{
        .name = "strategist",
        .model = "opus",
        .fallback_model = "sonnet",
        .stores_report = true,
    };
    const resolved = role_mod.resolveContextSources(role_cfg, allocator);
    const strat_extras = ctx.Extras{ .knowledge_tags = resolved.knowledge_tags };
    const context = if (resolved.sources.len > 0)
        ctx.build(store, paths, resolved.sources, strat_extras, allocator)
    else
        ctx.build(store, paths, &.{
            .user_profiles, .operator_feedback, .report_user, .report_qa, .report_sre, .task_trends, .knowledge_base,
        }, ctx.Extras{ .knowledge_tags = &.{"*"} }, allocator);
    defer if (context) |cc| allocator.free(cc);

    executor.runRole(
        role_cfg,
        .strategist,
        "strategist",
        paths,
        store,
        logger,
        io,
        allocator,
        context,
        false,
        cfg.default_backend,
    ) catch |e| {
        logger.err("[daemon] strategist failed: {}", .{e});
    };
}

/// Map a role name string to the corresponding SessionType enum.
fn mapRoleToSessionType(name: []const u8) ?types.SessionType {
    if (std.mem.eql(u8, name, "worker")) return .worker;
    if (std.mem.eql(u8, name, "merger")) return .merger;
    if (std.mem.eql(u8, name, "review")) return .review;
    if (std.mem.eql(u8, name, "conflict")) return .conflict;
    if (std.mem.eql(u8, name, "fix")) return .fix;
    if (std.mem.eql(u8, name, "sre")) return .sre;
    if (std.mem.eql(u8, name, "strategist")) return .strategist;
    if (std.mem.eql(u8, name, "qa")) return .qa;
    if (std.mem.eql(u8, name, "user")) return .user;
    if (std.mem.eql(u8, name, "researcher")) return .researcher;
    if (std.mem.eql(u8, name, "founder")) return .founder;
    return null; // Unknown role — custom roles get .user type by default
}

fn syncToSqlite(
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    allocator: std.mem.Allocator,
) void {
    const sqlite_path = std.fs.path.join(allocator, &.{ paths.db_dir, "data.sqlite" }) catch return;
    defer allocator.free(sqlite_path);
    var sync = sync_mod.SyncEngine.init(sqlite_path) catch |e| {
        logger.warn("[daemon] SQLite sync init failed: {s}", .{@errorName(e)});
        return;
    };
    defer sync.deinit();
    const stats = sync.syncAll(store) catch |e| {
        logger.warn("[daemon] SQLite sync failed: {s}", .{@errorName(e)});
        return;
    };
    if (stats.total() > 0) {
        logger.info("[daemon] synced to SQLite: {d} sessions, {d} events, {d} tasks", .{
            stats.sessions_synced, stats.events_synced, stats.tasks_synced,
        });
    }
}

fn writeTaskTrends(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    allocator: std.mem.Allocator,
) void {
    _ = cfg;
    var pool = tasks_mod.TaskPool.loadFromStore(store, allocator) catch
        tasks_mod.TaskPool.load(allocator, paths.tasks_file) catch return;
    defer pool.deinit(allocator);

    var buf: [16384]u8 = undefined;
    var pos: usize = 0;

    const header_text = "# Task Performance Trends\n\n| Task | Weight | Runs | Accepted | Rejected | Empty | Accept Rate |\n|------|--------|------|----------|----------|-------|-------------|\n";
    if (pos + header_text.len <= buf.len) {
        @memcpy(buf[pos..][0..header_text.len], header_text);
        pos += header_text.len;
    }

    const read_txn = store.beginReadTxn() catch return;
    defer store_mod.Store.abortTxn(read_txn);

    for (pool.tasks) |a| {
        const view = (store.getTask(read_txn, a.name) catch null) orelse continue;
        const h = view.header;
        const total = h.total_runs;
        const accept_rate: f64 = if (total > 0)
            @as(f64, @floatFromInt(h.accepted)) / @as(f64, @floatFromInt(total)) * 100.0
        else
            0.0;

        const line = std.fmt.bufPrint(buf[pos..], "| {s} | {d} | {d} | {d} | {d} | {d} | {d:.0}% |\n", .{
            a.name, h.weight, total, h.accepted, h.rejected, h.empty, accept_rate,
        }) catch break;
        pos += line.len;
    }

    const rec_header = "\n## Recommendations\n";
    if (pos + rec_header.len <= buf.len) {
        @memcpy(buf[pos..][0..rec_header.len], rec_header);
        pos += rec_header.len;
    }

    for (pool.tasks) |a| {
        const view = (store.getTask(read_txn, a.name) catch null) orelse continue;
        const h = view.header;
        if (h.total_runs >= 5 and h.accepted == 0) {
            const line = std.fmt.bufPrint(buf[pos..], "- **{s}**: {d} runs, 0 accepted — consider replacing\n", .{ a.name, h.total_runs }) catch break;
            pos += line.len;
        } else if (h.total_runs >= 3 and h.empty > h.accepted) {
            const line = std.fmt.bufPrint(buf[pos..], "- **{s}**: {d} empty vs {d} accepted — prompt may be too vague\n", .{ a.name, h.empty, h.accepted }) catch break;
            pos += line.len;
        }
    }

    const write_txn = store.beginWriteTxn() catch return;
    store.putMeta(write_txn, "report:trends", buf[0..pos]) catch {
        store_mod.Store.abortTxn(write_txn);
        return;
    };
    store_mod.Store.commitTxn(write_txn) catch return;
    logger.info("[daemon] wrote task trends to LMDB ({d} bytes)", .{pos});
}

/// Returns true if any .zig source files changed in the merge diff.
fn sourceFilesChanged(changed_files: ?[]const u8) bool {
    const files = changed_files orelse return false;
    var iter = std.mem.splitScalar(u8, files, '\n');
    while (iter.next()) |line| {
        if (std.mem.endsWith(u8, line, ".zig")) return true;
    }
    return false;
}

/// Load the persisted merge cycle counter (survives hot reload via LMDB).
fn loadMergeCycle(store: *store_mod.Store) u32 {
    const txn = store.beginReadTxn() catch return 0;
    defer store_mod.Store.abortTxn(txn);

    const val = (store.getMeta(txn, "daemon:merge_cycle") catch null) orelse return 0;
    return std.fmt.parseInt(u32, val, 10) catch 0;
}

/// Persist the merge cycle counter to LMDB so it survives hot reload.
fn persistMergeCycle(store: *store_mod.Store, cycle: u32, logger: *log_mod.Logger) void {
    var buf: [16]u8 = undefined;
    const val = std.fmt.bufPrint(&buf, "{d}", .{cycle}) catch return;

    const txn = store.beginWriteTxn() catch return;
    store.putMeta(txn, "daemon:merge_cycle", val) catch {
        store_mod.Store.abortTxn(txn);
        return;
    };
    store_mod.Store.commitTxn(txn) catch return;
    logger.info("[daemon] persisted merge_cycle={d} for reload", .{cycle});
}

/// Reload the task pool, freeing the old one only on success.
fn reloadPool(pool: *tasks_mod.TaskPool, store: *store_mod.Store, tasks_file: []const u8, allocator: std.mem.Allocator) void {
    const new_pool = tasks_mod.TaskPool.loadFromStore(store, allocator) catch
        tasks_mod.TaskPool.load(allocator, tasks_file) catch return;
    pool.deinit(allocator);
    pool.* = new_pool;
}

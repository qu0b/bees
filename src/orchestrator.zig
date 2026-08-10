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
const seed_mod = @import("seed.zig");

/// Returned by `run` to tell the caller how the daemon loop ended.
pub const DaemonAction = enum { shutdown, reload, halt };

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
    /// PID of the daemon-owned headless Chrome instance (0 = not running).
    chrome_pid: std.posix.pid_t = 0,
    /// Count of strategist runs, used to route a fraction of them to Codex.
    strategist_runs: u32 = 0,
};

/// Deterministic backend split: returns true for a `fraction` (0.0-1.0) of
/// callers, keyed by a monotonic `counter`. Uses a window of 4 so the requested
/// 0.25 / 0.5 / 0.75 splits are exact; other fractions are approximated. The
/// low positions in each window are chosen, so the split is stable, not random.
fn useCodex(counter: u32, fraction: f64) bool {
    if (fraction <= 0.0) return false;
    if (fraction >= 1.0) return true;
    const pos: f64 = @floatFromInt(counter % 4);
    return (pos / 4.0) < fraction;
}

/// Route a fraction of strategist runs to Codex. Mutates `role_cfg` in place,
/// counting each strategist run via `state.strategist_runs`.
fn applyStrategistCodex(
    cfg: config_mod.Config,
    role_cfg: *role_mod.RoleConfig,
    state: *DaemonState,
    logger: *log_mod.Logger,
) void {
    const counter = @atomicRmw(u32, &state.strategist_runs, .Add, 1, .monotonic);
    if (!backend.gatewayActive() and useCodex(counter, cfg.strategist.codex_fraction)) {
        // Strategist is a thinking/knowledge role → sol at high reasoning.
        role_cfg.backend = "codex";
        role_cfg.model = cfg.codex_thinking.model;
        role_cfg.effort = cfg.codex_thinking.effort;
        logger.info("[strategist] using Codex ({s}, effort={s})", .{ role_cfg.model, role_cfg.effort });
    }
}

/// One resolved post-merger workflow step, ready to run.
const RoleJob = struct {
    role_cfg: role_mod.RoleConfig,
    session_type: types.SessionType,
    name: []const u8,
    /// Context blob built for this role; owned here, freed after the run.
    injected: ?[]const u8,
};

/// True for roles that only OBSERVE the merged state (read-only analysis) and
/// therefore have no ordering relationship with each other. The strategist and
/// founder are excluded on purpose: they read `report:qa`/`report:user`/
/// `report:sre`, so running them alongside the observers would feed them the
/// PREVIOUS cycle's reports.
fn isObserverRole(t: types.SessionType) bool {
    return switch (t) {
        .qa, .user, .sre, .researcher => true,
        else => false,
    };
}

fn runRoleJob(
    job: RoleJob,
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
    seed_uuid: ?[]const u8,
) void {
    executor.runRole(
        job.role_cfg,
        job.session_type,
        job.name,
        paths,
        store,
        logger,
        io,
        allocator,
        job.injected,
        false,
        cfg,
        seed_uuid,
    ) catch |e| {
        logger.err("[daemon] {s} failed: {}", .{ job.name, e });
    };
}

/// Run `jobs`, at most `max_concurrent` at a time, and free their contexts.
/// Serializing independent observers cost ~25min of dead time every cycle —
/// no code is being written while they run one after another.
fn runRoleJobs(
    jobs: []const RoleJob,
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
    seed_uuid: ?[]const u8,
    max_concurrent: u32,
) void {
    defer for (jobs) |j| {
        if (j.injected) |sc| allocator.free(sc);
    };

    const cap: usize = @max(1, @min(max_concurrent, 4));
    var i: usize = 0;
    while (i < jobs.len) {
        const batch = @min(cap, jobs.len - i);
        var futures: [4]Io.Future(void) = undefined;
        var spawned: usize = 0;
        for (jobs[i .. i + batch]) |job| {
            if (batch == 1) {
                runRoleJob(job, cfg, paths, store, logger, io, allocator, seed_uuid);
                continue;
            }
            if (io.concurrent(runRoleJob, .{ job, cfg, paths, store, logger, io, allocator, seed_uuid })) |f| {
                futures[spawned] = f;
                spawned += 1;
            } else |_| {
                // No concurrency available — run it inline rather than skip it.
                runRoleJob(job, cfg, paths, store, logger, io, allocator, seed_uuid);
            }
        }
        if (spawned > 1) {
            logger.info("[daemon] running {d} observer roles concurrently", .{spawned});
        }
        for (futures[0..spawned]) |*f| f.await(io);
        i += batch;
    }
}

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

/// Sleep that wakes early on shutdown. Long uninterruptible sleeps (300s
/// cooldown, quiet hours) made the daemon ignore SIGTERM for minutes, so every
/// `systemctl stop` escalated to the 30s cgroup KILL even when idle.
fn sleepInterruptible(io: Io, state: *DaemonState, secs: u64) void {
    var left = secs;
    while (left > 0 and @atomicLoad(u32, &state.shutdown_requested, .acquire) == 0) {
        const chunk = @min(left, 2);
        sleep_secs(io, chunk);
        left -= chunk;
    }
}

/// Green thread armed at startup: kills agent sessions that have stopped making
/// progress. The cycle is sequential, so ONE wedged session stalls the whole
/// swarm — on 2026-08-09 a single hung LSP call held the daemon for 8h18m while
/// emitting heartbeats that made the session look busy. Nothing else can catch
/// this: the external `timeout` wrapper breaks the CLI under io_uring, budgets
/// only bound spend, and non-worker roles carry no timeout at all.
fn stallWatchdog(io: Io, state: *DaemonState, logger: *log_mod.Logger, idle_limit_secs: u32) void {
    if (idle_limit_secs == 0) return;
    while (@atomicLoad(u32, &state.shutdown_requested, .acquire) == 0) {
        sleep_secs(io, 15);
        var hits: [8]backend.StalledChild = undefined;
        const n = backend.reapStalledChildren(idle_limit_secs, &hits);
        for (hits[0..n]) |h| {
            if (h.escalated) {
                logger.err("[watchdog] session {d} (pid {d}) ignored SIGTERM after {d}s idle — SIGKILL", .{
                    h.session_id, h.pid, h.idle_secs,
                });
            } else {
                logger.warn("[watchdog] session {d} (pid {d}) made no progress for {d}s (limit {d}s) — SIGTERM", .{
                    h.session_id, h.pid, h.idle_secs, idle_limit_secs,
                });
            }
        }
    }
}

/// Green thread armed at startup: when shutdown is requested, give in-flight
/// agent sessions a short grace period, then SIGTERM (and finally SIGKILL) the
/// registered agent child processes. This is what makes shutdown finish inside
/// systemd's TimeoutStopSec: sessions run minutes-to-hours and nothing else
/// ever signals them — and because this runs concurrently, it also unblocks a
/// shutdown that arrives while a session occupies the main loop.
fn shutdownWatchdog(io: Io, state: *DaemonState, logger: *log_mod.Logger) void {
    while (@atomicLoad(u32, &state.shutdown_requested, .acquire) == 0) {
        sleep_secs(io, 1);
    }
    // Keep signaling every second, not one-shot: sessions spawned AFTER a
    // signaling round (e.g. by startup code that was mid-sequence when the
    // signal arrived) must also be caught, or the drain times out and systemd
    // KILLs the cgroup anyway. Repeat-signaling an already-dying pid is
    // harmless; grace 0-6s, TERM 6-14s, KILL beyond.
    var t: u32 = 0;
    var logged_term = false;
    var logged_kill = false;
    while (t < 60) : (t += 1) {
        sleep_secs(io, 1);
        // No children left → done. (Startup/refill are gated on the shutdown
        // flag, so no new agents can appear after this point; exiting promptly
        // matters because lingering green threads block process exit — the io
        // runtime joins all async tasks before the process can terminate.)
        if (!backend.hasActiveChildren()) return;
        if (t >= 14) {
            const n = backend.signalActiveChildren(.kill);
            if (n > 0 and !logged_kill) {
                logger.warn("[daemon] shutdown: SIGKILL to {d} unresponsive agent process(es)", .{n});
                logged_kill = true;
            }
        } else if (t >= 6) {
            const n = backend.signalActiveChildren(.term);
            if (n > 0 and !logged_term) {
                logger.warn("[daemon] shutdown: SIGTERM to {d} in-flight agent process(es)", .{n});
                logged_term = true;
            }
        }
    }
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
    // Single instance per project. Two daemons on one project double-spawn
    // workers, race the same git base, and corrupt task accounting. This
    // happened on 2026-08-09: an agent ran `bees daemon status` for
    // diagnostics, a stale `bees` on PATH parsed `daemon`, and a second
    // gateway-less daemon ran alongside the real one.
    var lock_buf: [256]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "/tmp/bees-{s}-daemon.lock", .{cfg.project.name}) catch
        return error.InvalidProjectName;
    if (!(worker.acquireLock(lock_path) catch false)) {
        logger.err("[daemon] another daemon already owns {s} (lock {s}) — refusing to start", .{
            cfg.project.name, lock_path,
        });
        return error.DaemonAlreadyRunning;
    }
    defer worker.releaseLock(lock_path);

    logger.info("[daemon] starting — workers={d} threshold={d} timeout={d}min cooldown={d}s", .{
        cfg.workers.count,                 cfg.merger.merge_threshold,
        cfg.daemon.worker_timeout_minutes, cfg.daemon.cooldown_secs,
    });

    var state = DaemonState{};
    installSignalHandlers(&state);
    // Concurrent shutdown watchdog: signals in-flight agent children after a
    // grace period so stops complete inside systemd's TimeoutStopSec. The
    // future is canceled on exit — the io runtime joins every async task before
    // the process can terminate, so an immortal green thread turns a clean
    // "shutdown complete" into a hang that systemd resolves with SIGKILL.
    var watchdog_future = io.async(shutdownWatchdog, .{ io, &state, logger });
    defer _ = watchdog_future.cancel(io);

    // Concurrent stall watchdog — same cancel-on-exit rule as above.
    var stall_future = io.async(stallWatchdog, .{ io, &state, logger, cfg.timeouts.max_idle_secs });
    defer _ = stall_future.cancel(io);
    if (cfg.timeouts.max_idle_secs > 0) {
        logger.info("[daemon] stall watchdog armed: {d}s without progress → SIGTERM", .{cfg.timeouts.max_idle_secs});
    } else {
        logger.warn("[daemon] stall watchdog DISABLED (timeouts.max_idle_secs = 0)", .{});
    }

    // Single shared headless Chrome for MCP-enabled roles (QA, user agent). Reuses
    // an already-running instance if present (pid 0), else launches one; roles
    // share it via tabs. At most one Chrome instance runs at a time.
    if (backend.gatewayTextOnly()) {
        logger.info("[daemon] gateway model is text-only — browser stays on for textual driving, screenshots disallowed", .{});
    }
    if (backend.spawnChrome(io)) |pid| {
        state.chrome_pid = pid;
        if (pid == 0) {
            logger.info("[daemon] reusing existing shared Chrome on :9222", .{});
        } else {
            logger.info("[daemon] Chrome started (pid={d})", .{pid});
        }
    } else {
        logger.warn("[daemon] Chrome failed to start — MCP-enabled roles will not have browser access", .{});
    }

    // Start REST API server as a background green thread. Canceled on exit for
    // the same reason as the watchdog: its accept loop never returns on its
    // own and would block process termination.
    var api_future: ?Io.Future(void) = null;
    defer if (api_future) |*f| {
        _ = f.cancel(io);
    };
    if (cfg.api.enabled) {
        api_future = io.async(api.startApiServer, .{
            store, cfg, paths, logger, io, allocator, cfg.api.port,
        });
        logger.info("[daemon] API server started on port {d}", .{cfg.api.port});
    }

    // Report workflow/role drift once at startup — steps naming a role that
    // does not exist are silently dropped otherwise.
    validateConfigAtStartup(paths, logger, allocator);

    // Mark any stale "running" sessions as "error" from previous daemon crash
    cleanupStaleSessions(store, logger);

    // Track merge cycles for strategist scheduling (survives reload via LMDB)
    var merge_cycle: u32 = loadMergeCycle(store);

    // Bootstrap: sync tasks.json into LMDB
    tasks_mod.syncFromFile(store, paths.tasks_file, .template, allocator) catch |e| {
        logger.warn("[daemon] initial task sync failed: {}", .{e});
    };

    // Wait out quiet hours before spending quota on startup strategist
    if (isQuietHour(cfg.daemon)) {
        logger.info("[daemon] quiet hours active (UTC {d}:00-{d}:00, weekdays only={s}), waiting...", .{
            cfg.daemon.quiet_start_utc.?,                        cfg.daemon.quiet_end_utc.?,
            if (cfg.daemon.quiet_weekdays_only) "yes" else "no",
        });
        while (isQuietHour(cfg.daemon) and @atomicLoad(u32, &state.shutdown_requested, .acquire) == 0) {
            sleepInterruptible(io, &state, 300);
        }
        logger.info("[daemon] quiet hours ended, resuming", .{});
    }

    // Build seed session for cross-role cache sharing
    var seed_result = seed_mod.buildSeed(paths.root, cfg.project.name, cfg.cache, store, allocator, io);
    var seed_uuid: ?[]const u8 = seed_result.uuid;
    var context_blob: ?[]const u8 = seed_result.context_blob;
    if (seed_uuid) |su| {
        logger.info("[daemon] seed session built: {s}", .{su});
    } else {
        logger.info("[daemon] seed session disabled or failed, using standard prompts", .{});
    }

    // Run the startup strategist only when the task pool is empty. Running it
    // unconditionally burned a full strategist session (minutes + quota) on
    // every restart even when tasks.json was fresh — the scheduled strategist
    // (every N merge cycles) keeps tasks current once the daemon is running.
    {
        const startup_pool = tasks_mod.TaskPool.loadFromStore(store, allocator) catch
            tasks_mod.TaskPool.load(allocator, paths.tasks_file) catch null;
        const have_tasks = if (startup_pool) |sp| sp.hasActiveTasks() else false;
        if (have_tasks) {
            logger.info("[daemon] active tasks present, skipping startup strategist", .{});
        } else if (@atomicLoad(u32, &state.shutdown_requested, .acquire) == 0) {
            logger.info("[daemon] no active tasks, running startup strategist", .{});
            runStrategistWithPrep(cfg, paths, store, logger, io, allocator, seed_uuid, &state);
            tasks_mod.syncFromFile(store, paths.tasks_file, .strategist, allocator) catch {};
        }
    }

    var preflight_ok = false;

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
        preflight_ok = true;
    }

    // Sync LMDB → SQLite so dashboard has data
    syncToSqlite(paths, store, logger, allocator);

    // Load tasks from LMDB (single source of truth) and spawn initial workers
    // only if the Claude CLI preflight passed — otherwise workers would all fail
    // silently with 0 turns and $0.00 cost.
    var pool = if (preflight_ok)
        tasks_mod.TaskPool.loadFromStore(store, allocator) catch
            try tasks_mod.TaskPool.load(allocator, paths.tasks_file)
    else
        try tasks_mod.TaskPool.load(allocator, paths.tasks_file);

    if (preflight_ok) {
        if (!pool.hasActiveTasks()) {
            logger.warn("[daemon] no active tasks after startup strategist, waiting for SRE/manual intervention", .{});
        }

        // Spawn initial workers as green threads — unless a shutdown request
        // arrived during the startup sequence (spawning after the signal used
        // to guarantee a drain timeout + systemd KILL).
        if (pool.hasActiveTasks() and @atomicLoad(u32, &state.shutdown_requested, .acquire) == 0) {
            const spawn_count = @min(cfg.workers.count, MAX_WORKERS);
            for (0..spawn_count) |_| {
                spawnWorker(cfg, paths, store, pool, logger, io, allocator, &state, context_blob);
            }
        }
    } else {
        logger.err("[daemon] skipping worker spawn — Claude CLI not available. Fix the installation and restart.", .{});
    }

    // Main loop — polls via cooperative sleep
    var was_quiet = false;
    var consecutive_empty_merges: u32 = 0;
    while (@atomicLoad(u32, &state.shutdown_requested, .acquire) == 0) {
        sleepInterruptible(io, &state, 10);

        // Graceful shutdown: stop spawning, wait for running workers to drain
        if (@atomicLoad(u32, &state.shutdown_requested, .acquire) != 0) break;

        // Quiet hours — let running workers finish but don't start new work
        if (isQuietHour(cfg.daemon)) {
            if (!was_quiet) {
                logger.info("[daemon] entering quiet hours, pausing new work", .{});
                was_quiet = true;
            }
            sleepInterruptible(io, &state, 300);
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

            merger.runMerger(cfg, paths, store, logger, io, allocator, seed_uuid) catch |e| {
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
                // Halt outright on systemic failure: every cycle burns agent
                // budget on work that never lands. Detect-and-log-only cost a
                // 5h sterile run (24 cycles) once; now the daemon stops and
                // stays stopped for operator attention.
                if (cfg.daemon.max_sterile_cycles > 0 and consecutive_empty_merges >= cfg.daemon.max_sterile_cycles) {
                    logger.err("[daemon] circuit breaker TRIPPED after {d} sterile cycles — halting. Investigate (bees sessions / bees log), then restart with `bees start`.", .{consecutive_empty_merges});
                    gracefulDrain(&state, logger, io, allocator);
                    return .halt;
                }
            } else {
                consecutive_empty_merges = 0;
            }

            // Self-hosted reload: detect if source .zig files changed
            const source_changed = cfg.daemon.self_hosted and
                sourceFilesChanged(changed_files);

            // Build + restart once (serves QA, user agent, and strategist)
            prepareForStrategist(cfg, paths, logger, io, allocator);

            // Rebuild seed session with fresh file contents after merge
            seed_result = seed_mod.buildSeed(paths.root, cfg.project.name, cfg.cache, store, allocator, io);
            seed_uuid = seed_result.uuid;
            context_blob = seed_result.context_blob;

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

            // Did the strategist run this cycle? Decides the origin recorded for
            // the tasks it wrote into tasks.json (see sync below).
            var strategist_ran = false;

            // Post-merger steps are collected first, then executed by group:
            // independent observers concurrently, report-consumers after.
            var observer_jobs: [8]RoleJob = undefined;
            var observer_n: usize = 0;
            var dependent_jobs: [8]RoleJob = undefined;
            var dependent_n: usize = 0;

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

                // Resolve role config — a step naming a role we cannot fully
                // resolve must not spawn a budgeted agent with no instructions.
                var role_cfg = roles.get(step.role) orelse {
                    logger.err("[daemon] no role definition for '{s}' — skipping step", .{step.role});
                    continue;
                };
                if (role_cfg.prompt_path.len == 0) {
                    logger.err("[daemon] role '{s}' has no prompt — skipping step", .{step.role});
                    continue;
                }

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

                // Map role name to session type
                const session_type = mapRoleToSessionType(step.role) orelse {
                    logger.warn("[daemon] unknown role '{s}', skipping", .{step.role});
                    if (step_ctx) |sc| allocator.free(sc);
                    continue;
                };

                // Route a fraction of strategist runs to Codex.
                if (session_type == .strategist) {
                    applyStrategistCodex(cfg, &role_cfg, &state, logger);
                    strategist_ran = true;
                }

                const job = RoleJob{
                    .role_cfg = role_cfg,
                    .session_type = session_type,
                    .name = step.role,
                    .injected = step_ctx,
                };
                // Observers analyze the merged state independently; the
                // strategist/founder READ their reports, so they must follow.
                if (isObserverRole(session_type) and observer_n < observer_jobs.len) {
                    observer_jobs[observer_n] = job;
                    observer_n += 1;
                } else if (dependent_n < dependent_jobs.len) {
                    dependent_jobs[dependent_n] = job;
                    dependent_n += 1;
                } else {
                    if (step_ctx) |sc| allocator.free(sc);
                }
            }

            // Observers first, concurrently (bounded so workers + roles stay
            // inside the provider's concurrent-request budget), then the roles
            // that consume their reports.
            runRoleJobs(observer_jobs[0..observer_n], cfg, paths, store, logger, io, allocator, seed_uuid, @max(1, cfg.daemon.max_parallel_roles));
            runRoleJobs(dependent_jobs[0..dependent_n], cfg, paths, store, logger, io, allocator, seed_uuid, 1);

            // Drain any remaining SRE triggers not handled by workflow
            drainSreTriggers(cfg, paths, store, logger, io, allocator, &state);

            // Clean up leaked Chrome renderer processes between cycles
            backend.cleanupChrome(io);

            // Sync LMDB → SQLite for dashboard
            syncToSqlite(paths, store, logger, allocator);

            // Cooldown (interruptible — a stop during cooldown used to be
            // ignored for up to cooldown_secs and always ended in a KILL)
            logger.info("[daemon] cooling down for {d}s", .{cfg.daemon.cooldown_secs});
            sleepInterruptible(io, &state, @as(u64, cfg.daemon.cooldown_secs));

            // Sync tasks.json into LMDB and reload from store
            tasks_mod.syncFromFile(
                store,
                paths.tasks_file,
                if (strategist_ran) .strategist else .template,
                allocator,
            ) catch {};
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

                // Kill Chrome before re-exec — new daemon instance will spawn fresh
                if (state.chrome_pid != 0) {
                    logger.info("[daemon] stopping Chrome before reload (pid={d})", .{state.chrome_pid});
                    backend.killChrome(state.chrome_pid, io);
                }
                return .reload;
            }

            if (!pool.hasActiveTasks()) {
                logger.info("[daemon] all tasks exhausted, running strategist", .{});
                runStrategistWithPrep(cfg, paths, store, logger, io, allocator, seed_uuid, &state);
                tasks_mod.syncFromFile(store, paths.tasks_file, .strategist, allocator) catch {};
                reloadPool(&pool, store, paths.tasks_file, allocator);
            }

            // Refill workers (only if there's work to do and no shutdown is in
            // progress — the cooldown sleep above returns early on shutdown)
            if (pool.hasActiveTasks() and @atomicLoad(u32, &state.shutdown_requested, .acquire) == 0) {
                const current_active = @atomicLoad(u32, &state.active_count, .acquire);
                const need = @min(cfg.workers.count, MAX_WORKERS) -| current_active;
                if (need > 0) {
                    logger.info("[daemon] spawning {d} new workers", .{need});
                    for (0..need) |_| {
                        spawnWorker(cfg, paths, store, pool, logger, io, allocator, &state, context_blob);
                    }
                }
            } else {
                logger.warn("[daemon] no active tasks, skipping worker spawn — waiting for next cycle", .{});
            }
        }
    }

    gracefulDrain(&state, logger, io, allocator);
    logger.info("[daemon] shutdown complete", .{});
    return .shutdown;
}

/// Drain in-flight workers and release Chrome — the common tail of every way
/// the daemon can end (shutdown, circuit-breaker halt). The watchdog TERMs
/// agent children ~8s after shutdown_requested is set, so this drain completes
/// in seconds rather than racing systemd's stop timeout.
fn gracefulDrain(state: *DaemonState, logger: *log_mod.Logger, io: Io, allocator: std.mem.Allocator) void {
    // Ensure the watchdog fires even when we get here without a signal
    // (circuit-breaker halt sets no flag).
    @atomicStore(u32, &state.shutdown_requested, 1, .release);

    const active = @atomicLoad(u32, &state.active_count, .acquire);
    if (active > 0) {
        logger.info("[daemon] draining {d} active worker(s)...", .{active});
    }
    var waited: u32 = 0;
    const drain_timeout: u32 = 25; // watchdog TERMs at ~8s, KILLs at ~16s
    while (@atomicLoad(u32, &state.active_count, .acquire) > 0 and waited < drain_timeout) {
        sleep_secs(io, 1);
        waited += 1;
    }
    if (@atomicLoad(u32, &state.active_count, .acquire) > 0) {
        logger.warn("[daemon] drain timeout, {d} worker task(s) still active", .{
            @atomicLoad(u32, &state.active_count, .acquire),
        });
    }

    // Kill daemon-owned Chrome; for a merely-reused instance (pid 0), sweep it
    // only if we are the last bees daemon standing.
    if (state.chrome_pid != 0) {
        logger.info("[daemon] stopping Chrome (pid={d})", .{state.chrome_pid});
        backend.killChrome(state.chrome_pid, io);
    } else if (backend.stopSharedChromeIfOrphaned(allocator, io)) {
        logger.info("[daemon] stopped shared Chrome (last daemon out)", .{});
    }
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
    ctx_blob: ?[]const u8,
) void {
    const wid = @atomicRmw(u32, &state.next_worker_id, .Add, 1, .monotonic);
    _ = @atomicRmw(u32, &state.active_count, .Add, 1, .release);

    const timeout_secs: u32 = if (cfg.daemon.worker_timeout_minutes > 0)
        cfg.daemon.worker_timeout_minutes * 60
    else
        0;

    // Route a configurable fraction of workers to the Codex backend. Codex uses
    // an OpenAI model, so also swap in the codex model for those workers.
    var worker_cfg = cfg;
    if (!backend.gatewayActive() and useCodex(wid, cfg.workers.codex_fraction)) {
        // Workers are defined-execution roles → terra at ultra-high reasoning.
        worker_cfg.workers.backend = "codex";
        worker_cfg.workers.model = cfg.codex_execution.model;
        worker_cfg.workers.effort = cfg.codex_execution.effort;
        logger.info("[worker:{d}] using Codex ({s}, effort={s})", .{ wid, worker_cfg.workers.model, worker_cfg.workers.effort });
    }

    _ = io.async(workerTask, .{
        worker_cfg, paths, store, pool, logger, io, wid, allocator, timeout_secs, state, ctx_blob,
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
    ctx_blob: ?[]const u8,
) void {
    defer {
        _ = @atomicRmw(u32, &state.done_count, .Add, 1, .release);
        _ = @atomicRmw(u32, &state.active_count, .Sub, 1, .release);
    }
    const result = worker.runWorkerWithTimeout(cfg, paths, store, &pool, logger, io, wid, allocator, timeout_secs, ctx_blob) catch |e| {
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

/// Warn (never abort) about workflow steps naming unknown roles and roles with
/// missing prompts or dangling report: sources. Runs once, at daemon start.
fn validateConfigAtStartup(
    paths: config_mod.ProjectPaths,
    logger: *log_mod.Logger,
    allocator: std.mem.Allocator,
) void {
    var role_set = role_mod.loadRoles(paths, allocator) catch return;
    defer role_set.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var it = role_set.roles.keyIterator();
    while (it.next()) |k| names.append(allocator, k.*) catch {};

    const wf = workflow_mod.load(paths, allocator);
    for (workflow_mod.validate(&wf, names.items, allocator)) |m| logger.warn("[config] {s}", .{m});
    for (role_mod.validate(&role_set, allocator)) |m| logger.warn("[config] {s}", .{m});
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
        cfg,
        null, // SRE runs reactively, seed context may be stale
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
    seed_uuid: ?[]const u8,
    state: *DaemonState,
) void {
    prepareForStrategist(cfg, paths, logger, io, allocator);
    writeTaskTrends(cfg, paths, store, logger, allocator);

    // Load role config for strategist
    const roles = role_mod.loadRoles(paths, allocator) catch return;
    var role_cfg = roles.get("strategist") orelse role_mod.RoleConfig{
        .name = "strategist",
        .model = "fable",
        .fallback_model = "opus",
        .stores_report = true,
    };

    // Route a fraction of strategist runs to Codex.
    applyStrategistCodex(cfg, &role_cfg, state, logger);
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
        cfg,
        seed_uuid,
    ) catch |e| {
        logger.err("[daemon] strategist failed: {}", .{e});
        return;
    };

    // Validate that the strategist actually wrote tasks.
    // Read tasks.json and check it contains real tasks, not just "[]".
    const tasks_data = fs.readFileAlloc(allocator, paths.tasks_file, 1024 * 1024) catch {
        logger.warn("[daemon] strategist did not create tasks.json — workers will have nothing to do", .{});
        return;
    };
    defer allocator.free(tasks_data);

    // Strip whitespace and check for empty array
    var stripped = std.mem.trim(u8, tasks_data, " \t\n\r");
    if (stripped.len <= 2 or std.mem.eql(u8, stripped, "[]")) {
        logger.warn("[daemon] strategist left tasks.json empty — workers will have nothing to do", .{});
    } else {
        logger.info("[daemon] strategist wrote tasks ({d} bytes)", .{stripped.len});
    }
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
    if (std.mem.eql(u8, name, "improver")) return .improver;
    return null; // Unknown role — caller logs and skips the step
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

    // Retired history — without it the strategist only ever sees the pool it
    // wrote last cycle and re-authors the same failed task under a new spelling.
    const ret_header = "\n## Previously Retired Tasks (already tried — do not re-author under a new spelling)\n";
    if (pos + ret_header.len <= buf.len) {
        @memcpy(buf[pos..][0..ret_header.len], ret_header);
        pos += ret_header.len;
    }

    if (store.iterTasks(read_txn)) |iter_const| {
        var iter = iter_const;
        defer iter.close();
        var shown: u32 = 0;
        while (iter.next()) |entry| {
            if (shown >= 40) break;
            const h = entry.view.header;
            if (h.status == .active) continue;
            if (h.total_runs == 0) continue;
            const line = std.fmt.bufPrint(buf[pos..], "- {s}: {d} runs, {d} accepted, {d} empty\n", .{
                entry.name, h.total_runs, h.accepted, h.empty,
            }) catch break;
            pos += line.len;
            shown += 1;
        }
    } else |_| {}

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
///
/// Safe to free the old pool here because workers copy the task strings they
/// need in a suspend-free select()+dupe sequence (worker.zig) and never touch
/// the pool again — so no in-flight worker holds a pointer into it.
fn reloadPool(pool: *tasks_mod.TaskPool, store: *store_mod.Store, tasks_file: []const u8, allocator: std.mem.Allocator) void {
    const new_pool = tasks_mod.TaskPool.loadFromStore(store, allocator) catch
        tasks_mod.TaskPool.load(allocator, tasks_file) catch return;
    pool.deinit(allocator);
    pool.* = new_pool;
}

test "observer roles run concurrently; report-consumers do not" {
    // qa/user/sre/researcher only READ the merged state, so they have no
    // ordering relationship. strategist/founder consume their reports and must
    // follow — running them in the same batch would feed them last cycle's data.
    try std.testing.expect(isObserverRole(.qa));
    try std.testing.expect(isObserverRole(.user));
    try std.testing.expect(isObserverRole(.sre));
    try std.testing.expect(isObserverRole(.researcher));
    try std.testing.expect(!isObserverRole(.strategist));
    try std.testing.expect(!isObserverRole(.founder));
    try std.testing.expect(!isObserverRole(.worker));
    try std.testing.expect(!isObserverRole(.merger));
}

test "useCodex splits deterministically by fraction" {
    // 0.5 → 2 of every 4 (positions 0,1); 0.25 → 1 of 4 (position 0).
    var half: u32 = 0;
    var quarter: u32 = 0;
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        if (useCodex(i, 0.5)) half += 1;
        if (useCodex(i, 0.25)) quarter += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), half);
    try std.testing.expectEqual(@as(u32, 1), quarter);

    // Boundaries: 0.0 never, 1.0 always.
    try std.testing.expect(!useCodex(0, 0.0));
    try std.testing.expect(useCodex(3, 1.0));
}

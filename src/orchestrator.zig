const std = @import("std");
const Io = std.Io;
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const worker = @import("worker.zig");
const merger = @import("merger.zig");
const sre_mod = @import("sre.zig");
const strategist_mod = @import("strategist.zig");
const qa_mod = @import("qa.zig");
const tasks_mod = @import("tasks.zig");
const git = @import("git.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");
const types = @import("types.zig");
const MAX_WORKERS = 32;

const claude = @import("claude.zig");

/// Shared daemon state — accessed via atomics for cross-green-thread safety.
const DaemonState = struct {
    done_count: u32 = 0,
    active_count: u32 = 0,
    next_worker_id: u32 = 1,
    /// Session IDs that completed with tool errors above threshold.
    /// Workers write here; main loop reads and drains.
    sre_trigger_sessions: [64]u64 = [_]u64{0} ** 64,
    sre_trigger_count: u32 = 0,
};

/// I/O-cooperative sleep — yields to the event loop so other green threads
/// (API server, workers, SRE) keep making progress.
pub fn sleep_secs(io: Io, secs: u64) void {
    io.sleep(Io.Duration.fromSeconds(@intCast(secs)), .awake) catch {};
}

pub fn run(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) !void {
    logger.info("[daemon] starting — workers={d} threshold={d} timeout={d}min cooldown={d}min", .{
        cfg.workers.count, cfg.merger.merge_threshold,
        cfg.daemon.worker_timeout_minutes, cfg.daemon.cooldown_minutes,
    });

    var state = DaemonState{};

    // Mark any stale "running" sessions as "error" from previous daemon crash
    cleanupStaleSessions(store, logger);

    // Track merge cycles for strategist scheduling
    var merge_cycle: u32 = 0;

    // Bootstrap: sync tasks.json into LMDB
    tasks_mod.syncFromFile(store, paths.tasks_file, allocator) catch |e| {
        logger.warn("[daemon] initial task sync failed: {}", .{e});
    };

    // Always run strategist at startup to refresh stale tasks before spawning workers
    logger.info("[daemon] running startup strategist to refresh tasks", .{});
    runStrategistWithPrep(cfg, paths, store, logger, io, allocator);
    tasks_mod.syncFromFile(store, paths.tasks_file, allocator) catch {};

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
    while (true) {
        sleep_secs(io, 10);

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

            // Build + restart once (serves both QA and strategist)
            prepareForStrategist(cfg, paths, logger, io, allocator);

            // QA runs every merge cycle
            logger.info("[daemon] running QA agent", .{});
            qa_mod.runQa(cfg, paths, store, logger, io, allocator, changed_files, false) catch |e| {
                logger.err("[daemon] QA failed: {}", .{e});
            };

            // Run strategist every N merge cycles
            merge_cycle += 1;
            if (cfg.strategist.cycle_interval == 0 or merge_cycle % cfg.strategist.cycle_interval == 0) {
                logger.info("[daemon] running strategist (cycle {d})", .{merge_cycle});
                writeTaskTrends(cfg, paths, store, logger, allocator);
                const ctx = buildStrategistContext(store, allocator);
                defer if (ctx) |c| allocator.free(c);
                strategist_mod.runStrategist(cfg, paths, store, logger, io, allocator, false, ctx) catch |e| {
                    logger.err("[daemon] strategist failed: {}", .{e});
                };
            } else {
                logger.info("[daemon] skipping strategist (cycle {d}, interval {d})", .{ merge_cycle, cfg.strategist.cycle_interval });
            }

            // Check for tool-error-triggered SRE
            drainSreTriggers(cfg, paths, store, logger, io, allocator, &state);

            // Cooldown
            const cooldown_secs = @as(u64, cfg.daemon.cooldown_minutes) * 60;
            logger.info("[daemon] cooling down for {d} minutes", .{cfg.daemon.cooldown_minutes});
            sleep_secs(io, cooldown_secs);

            // Sync tasks.json into LMDB and reload from store
            tasks_mod.syncFromFile(store, paths.tasks_file, allocator) catch {};
            pool = tasks_mod.TaskPool.loadFromStore(store, allocator) catch
                tasks_mod.TaskPool.load(allocator, paths.tasks_file) catch pool;

            if (!pool.hasActiveTasks()) {
                logger.info("[daemon] all tasks exhausted, running strategist", .{});
                runStrategistWithPrep(cfg, paths, store, logger, io, allocator);
                tasks_mod.syncFromFile(store, paths.tasks_file, allocator) catch {};
                pool = tasks_mod.TaskPool.loadFromStore(store, allocator) catch
                    tasks_mod.TaskPool.load(allocator, paths.tasks_file) catch pool;
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

        if (claude.collectToolErrors(store, sid, allocator)) |errors| {
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
    sre_mod.runSre(cfg, paths, store, logger, io, allocator, false, context.items, first_session_id) catch |e| {
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

    const context = buildStrategistContext(store, allocator);
    defer if (context) |c| allocator.free(c);

    strategist_mod.runStrategist(cfg, paths, store, logger, io, allocator, false, context) catch |e| {
        logger.err("[daemon] strategist failed: {}", .{e});
    };
}

fn buildStrategistContext(store: *store_mod.Store, allocator: std.mem.Allocator) ?[]const u8 {
    const txn = store.beginReadTxn() catch return null;
    defer store_mod.Store.abortTxn(txn);

    const vision = store.getMeta(txn, "report:vision") catch null;
    const qa_report = store.getMeta(txn, "report:qa") catch null;
    const trends = store.getMeta(txn, "report:trends") catch null;

    if (vision == null and qa_report == null and trends == null) return null;

    var parts: std.ArrayList(u8) = .empty;
    if (vision) |v| {
        parts.appendSlice(allocator, "\n\n## Your Previous VISION\nThis is what you wrote last cycle. Update it at the end of your response.\n\n") catch return null;
        parts.appendSlice(allocator, v) catch return null;
    }
    if (qa_report) |qr| {
        parts.appendSlice(allocator, "\n\n## Latest QA Report\n") catch return null;
        parts.appendSlice(allocator, qr) catch return null;
    }
    if (trends) |tr| {
        parts.appendSlice(allocator, "\n\n") catch return null;
        parts.appendSlice(allocator, tr) catch return null;
    }
    return parts.toOwnedSlice(allocator) catch null;
}

fn writeTaskTrends(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    allocator: std.mem.Allocator,
) void {
    _ = cfg;
    const pool = tasks_mod.TaskPool.loadFromStore(store, allocator) catch
        tasks_mod.TaskPool.load(allocator, paths.tasks_file) catch return;

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

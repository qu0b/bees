const std = @import("std");
const Io = std.Io;
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const worker = @import("worker.zig");
const merger = @import("merger.zig");
const sre_mod = @import("sre.zig");
const strategist_mod = @import("strategist.zig");
const qa_mod = @import("qa.zig");
const approaches_mod = @import("approaches.zig");
const git = @import("git.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");
const api = @import("api.zig");

const MAX_WORKERS = 32;

const Slot = struct {
    thread: std.Thread = undefined,
    active: bool = false,
    done: bool = false,
};

// Shared state — all access protected by mutex
var mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var done_count: u32 = 0;
var active_count: u32 = 0;
var next_worker_id: u32 = 1;
var slots: [MAX_WORKERS]Slot = [_]Slot{.{}} ** MAX_WORKERS;
var sre_thread: std.Thread = undefined;
var sre_active: bool = false;
var sre_done: bool = false;
var sre_last_finished: u64 = 0;

fn lock() void {
    _ = std.c.pthread_mutex_lock(&mutex);
}

fn unlock() void {
    _ = std.c.pthread_mutex_unlock(&mutex);
}

pub fn sleep_secs(secs: u64) void {
    var ts = std.c.timespec{ .sec = @intCast(secs), .nsec = 0 };
    _ = std.c.nanosleep(&ts, null);
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

    // Spawn API server thread
    if (cfg.api.enabled) {
        _ = std.Thread.spawn(.{}, api.startApiServer, .{
            store, cfg, paths, logger, io, allocator, cfg.api.port,
        }) catch |e| {
            logger.err("[daemon] failed to spawn API server: {}", .{e});
        };
    }

    // Spawn SRE agent
    spawnSre(cfg, paths, store, logger, io, allocator);

    // Track merge cycles for strategist scheduling
    var merge_cycle: u32 = 0;

    // Bootstrap: sync approaches.json into LMDB
    approaches_mod.syncFromFile(store, paths.approaches_file, allocator) catch |e| {
        logger.warn("[daemon] initial approach sync failed: {}", .{e});
    };

    // Load approaches from LMDB (single source of truth)
    var pool = approaches_mod.ApproachPool.loadFromStore(store, allocator) catch
        try approaches_mod.ApproachPool.load(allocator, paths.approaches_file);
    if (!pool.hasActiveApproaches()) {
        logger.info("[daemon] all approaches exhausted (weight=0), running strategist to generate new work", .{});
        runStrategistWithPrep(cfg, paths, store, logger, io, allocator);
        approaches_mod.syncFromFile(store, paths.approaches_file, allocator) catch {};
        pool = approaches_mod.ApproachPool.loadFromStore(store, allocator) catch
            approaches_mod.ApproachPool.load(allocator, paths.approaches_file) catch pool;
        if (!pool.hasActiveApproaches()) {
            logger.warn("[daemon] still no active approaches after strategist, waiting for SRE/manual intervention", .{});
        }
    }
    if (pool.hasActiveApproaches()) {
        const spawn_count = @min(cfg.workers.count, MAX_WORKERS);
        for (0..spawn_count) |_| {
            spawnWorker(cfg, paths, store, pool, logger, io, allocator);
        }
    }

    // Main loop
    while (true) {
        sleep_secs(10);

        // Join completed worker threads
        joinCompleted();

        // Check SRE health and restart if needed (with cooldown)
        var need_sre_restart = false;
        {
            lock();
            defer unlock();
            if (sre_done) {
                sre_last_finished = fs.timestamp();
                need_sre_restart = true;
                sre_done = false;
            } else if (!sre_active) {
                need_sre_restart = true;
            }
        }
        if (need_sre_restart) {
            joinSre();
            const sre_cooldown_secs = @as(u64, cfg.sre.cooldown_minutes) * 60;
            const elapsed_since_sre = fs.timestamp() -| sre_last_finished;
            if (sre_last_finished == 0 or elapsed_since_sre >= sre_cooldown_secs) {
                logger.info("[daemon] starting SRE agent", .{});
                spawnSre(cfg, paths, store, logger, io, allocator);
            }
        }

        // Check completion threshold
        var current_done: u32 = 0;
        {
            lock();
            defer unlock();
            current_done = done_count;
        }

        if (current_done >= cfg.merger.merge_threshold) {
            logger.info("[daemon] {d} workers completed, triggering merger", .{current_done});

            // Capture HEAD before merge for diff-aware QA
            const pre_merge_head = git.getCurrentHead(allocator, io, paths.root) catch null;

            merger.runMerger(cfg, paths, store, logger, io, allocator) catch |e| {
                logger.err("[daemon] merger failed: {}", .{e});
            };

            {
                lock();
                defer unlock();
                done_count -|= cfg.merger.merge_threshold;
            }

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
                writeApproachTrends(cfg, paths, store, logger, allocator);
                const ctx = buildStrategistContext(store, allocator);
                defer if (ctx) |c| allocator.free(c);
                strategist_mod.runStrategist(cfg, paths, store, logger, io, allocator, false, ctx) catch |e| {
                    logger.err("[daemon] strategist failed: {}", .{e});
                };
            } else {
                logger.info("[daemon] skipping strategist (cycle {d}, interval {d})", .{ merge_cycle, cfg.strategist.cycle_interval });
            }

            // Cooldown
            const cooldown_secs = @as(u64, cfg.daemon.cooldown_minutes) * 60;
            logger.info("[daemon] cooling down for {d} minutes", .{cfg.daemon.cooldown_minutes});
            sleep_secs(cooldown_secs);

            // Sync approaches.json into LMDB and reload from store
            approaches_mod.syncFromFile(store, paths.approaches_file, allocator) catch {};
            pool = approaches_mod.ApproachPool.loadFromStore(store, allocator) catch
                approaches_mod.ApproachPool.load(allocator, paths.approaches_file) catch pool;

            if (!pool.hasActiveApproaches()) {
                logger.info("[daemon] all approaches exhausted, running strategist", .{});
                runStrategistWithPrep(cfg, paths, store, logger, io, allocator);
                approaches_mod.syncFromFile(store, paths.approaches_file, allocator) catch {};
                pool = approaches_mod.ApproachPool.loadFromStore(store, allocator) catch
                    approaches_mod.ApproachPool.load(allocator, paths.approaches_file) catch pool;
            }

            // Refill workers (only if there's work to do)
            if (pool.hasActiveApproaches()) {
                var need: u32 = 0;
                {
                    lock();
                    defer unlock();
                    need = @min(cfg.workers.count, MAX_WORKERS) -| active_count;
                }
                if (need > 0) {
                    logger.info("[daemon] spawning {d} new workers", .{need});
                    for (0..need) |_| {
                        spawnWorker(cfg, paths, store, pool, logger, io, allocator);
                    }
                }
            } else {
                logger.warn("[daemon] no active approaches, skipping worker spawn — waiting for next cycle", .{});
            }
        }
    }
}

fn spawnWorker(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: approaches_mod.ApproachPool,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) void {
    var wid: u32 = 0;
    var slot_idx: usize = MAX_WORKERS;

    {
        lock();
        defer unlock();
        for (0..MAX_WORKERS) |i| {
            if (!slots[i].active) {
                slot_idx = i;
                break;
            }
        }
        if (slot_idx >= MAX_WORKERS) {
            logger.err("[daemon] no free worker slots", .{});
            return;
        }
        wid = next_worker_id;
        next_worker_id += 1;
        active_count += 1;
        slots[slot_idx].active = true;
        slots[slot_idx].done = false;
    }

    const timeout_secs: u32 = if (cfg.daemon.worker_timeout_minutes > 0)
        cfg.daemon.worker_timeout_minutes * 60
    else
        0;

    slots[slot_idx].thread = std.Thread.spawn(.{}, workerThread, .{
        cfg, paths, store, pool, logger, io, wid, allocator, timeout_secs, slot_idx,
    }) catch |e| {
        logger.err("[daemon] spawn worker {d} failed: {}", .{ wid, e });
        lock();
        defer unlock();
        active_count -= 1;
        slots[slot_idx].active = false;
        return;
    };
}

fn workerThread(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: approaches_mod.ApproachPool,
    logger: *log_mod.Logger,
    io: Io,
    wid: u32,
    allocator: std.mem.Allocator,
    timeout_secs: u32,
    slot_idx: usize,
) void {
    defer {
        lock();
        defer unlock();
        done_count += 1;
        active_count -= 1;
        slots[slot_idx].done = true;
    }
    worker.runWorkerWithTimeout(cfg, paths, store, &pool, logger, io, wid, allocator, timeout_secs) catch |e| {
        logger.err("[worker:{d}] fatal: {}", .{ wid, e });
    };
}

fn spawnSre(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) void {
    {
        lock();
        defer unlock();
        sre_active = true;
        sre_done = false;
    }

    sre_thread = std.Thread.spawn(.{}, sreThread, .{
        cfg, paths, store, logger, io, allocator,
    }) catch |e| {
        logger.err("[daemon] spawn SRE failed: {}", .{e});
        lock();
        defer unlock();
        sre_active = false;
        return;
    };
}

fn sreThread(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) void {
    defer {
        lock();
        defer unlock();
        sre_done = true;
    }
    sre_mod.runSre(cfg, paths, store, logger, io, allocator, false) catch |e| {
        logger.err("[sre] fatal: {}", .{e});
    };
}

fn joinCompleted() void {
    var to_join: [MAX_WORKERS]std.Thread = undefined;
    var count: usize = 0;

    {
        lock();
        defer unlock();
        for (0..MAX_WORKERS) |i| {
            if (slots[i].done) {
                to_join[count] = slots[i].thread;
                count += 1;
                slots[i].active = false;
                slots[i].done = false;
            }
        }
    }

    for (to_join[0..count]) |t| {
        t.join();
    }
}

fn joinSre() void {
    var to_join: ?std.Thread = null;

    {
        lock();
        defer unlock();
        if (sre_active) {
            to_join = sre_thread;
            sre_active = false;
        }
    }

    if (to_join) |t| {
        t.join();
    }
}

/// Build the project and restart the serve process before the strategist runs.
/// All process management happens here in native Zig — never inside a Claude session.
fn prepareForStrategist(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) void {
    // Step 1: Build
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

    // Step 2: Restart systemd service
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

    // Step 3: Health check — poll until the serve port responds
    if (cfg.serve.health_url) |url| {
        logger.info("[daemon] waiting for serve health: {s}", .{url});
        const deadline = cfg.serve.health_timeout_secs;
        var elapsed: u32 = 0;
        while (elapsed < deadline) : (elapsed += 2) {
            const result = git.run(allocator, io, &.{
                "curl", "-sf", "-o", "/dev/null", "--max-time", "2", url,
            }, paths.root) catch {
                sleep_secs(2);
                continue;
            };
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            if (result.exit_code == 0) {
                logger.info("[daemon] serve is healthy after {d}s", .{elapsed});
                return;
            }
            sleep_secs(2);
        }
        logger.warn("[daemon] serve health check timed out after {d}s, strategist will proceed without live server", .{deadline});
    }
}

/// Run strategist with infrastructure preparation and LMDB context injection.
fn runStrategistWithPrep(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) void {
    prepareForStrategist(cfg, paths, logger, io, allocator);
    writeApproachTrends(cfg, paths, store, logger, allocator);

    // Read QA report and approach trends from LMDB to inject into strategist prompt
    const context = buildStrategistContext(store, allocator);
    defer if (context) |c| allocator.free(c);

    strategist_mod.runStrategist(cfg, paths, store, logger, io, allocator, false, context) catch |e| {
        logger.err("[daemon] strategist failed: {}", .{e});
    };
}

/// Build context string from LMDB reports for the strategist prompt.
/// Injects: previous VISION, latest QA report, approach trends.
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

/// Compute approach performance trends and store in LMDB meta.
fn writeApproachTrends(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    allocator: std.mem.Allocator,
) void {
    _ = cfg;
    const pool = approaches_mod.ApproachPool.loadFromStore(store, allocator) catch
        approaches_mod.ApproachPool.load(allocator, paths.approaches_file) catch return;

    // Build the trends report in a stack buffer
    var buf: [16384]u8 = undefined;
    var pos: usize = 0;

    const header_text = "# Approach Performance Trends\n\n| Approach | Weight | Runs | Accepted | Rejected | Empty | Accept Rate |\n|----------|--------|------|----------|----------|-------|-------------|\n";
    if (pos + header_text.len <= buf.len) {
        @memcpy(buf[pos..][0..header_text.len], header_text);
        pos += header_text.len;
    }

    const read_txn = store.beginReadTxn() catch return;
    defer store_mod.Store.abortTxn(read_txn);

    for (pool.approaches) |a| {
        const view = (store.getApproach(read_txn, a.name) catch null) orelse continue;
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

    for (pool.approaches) |a| {
        const view = (store.getApproach(read_txn, a.name) catch null) orelse continue;
        const h = view.header;
        if (h.total_runs >= 5 and h.accepted == 0) {
            const line = std.fmt.bufPrint(buf[pos..], "- **{s}**: {d} runs, 0 accepted — consider replacing\n", .{ a.name, h.total_runs }) catch break;
            pos += line.len;
        } else if (h.total_runs >= 3 and h.empty > h.accepted) {
            const line = std.fmt.bufPrint(buf[pos..], "- **{s}**: {d} empty vs {d} accepted — prompt may be too vague\n", .{ a.name, h.empty, h.accepted }) catch break;
            pos += line.len;
        }
    }

    // Store in LMDB meta
    const write_txn = store.beginWriteTxn() catch return;
    store.putMeta(write_txn, "report:trends", buf[0..pos]) catch {
        store_mod.Store.abortTxn(write_txn);
        return;
    };
    store_mod.Store.commitTxn(write_txn) catch return;
    logger.info("[daemon] wrote approach trends to LMDB ({d} bytes)", .{pos});
}

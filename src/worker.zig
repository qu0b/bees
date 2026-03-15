const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const git = @import("git.zig");
const claude = @import("claude.zig");
const approaches_mod = @import("approaches.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");

pub fn runWorkerWithTimeout(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: *const approaches_mod.ApproachPool,
    logger: *log_mod.Logger,
    io: Io,
    worker_id: u32,
    allocator: std.mem.Allocator,
    timeout_secs: u32,
) !void {
    return runWorkerImpl(cfg, paths, store, pool, logger, io, worker_id, allocator, timeout_secs, cfg.daemon.restart_timeout_minutes * 60, cfg.daemon.max_restarts, false);
}

pub fn runWorker(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: *const approaches_mod.ApproachPool,
    logger: *log_mod.Logger,
    io: Io,
    worker_id: u32,
    allocator: std.mem.Allocator,
    stream_output: bool,
) !void {
    return runWorkerImpl(cfg, paths, store, pool, logger, io, worker_id, allocator, 0, 0, 0, stream_output);
}

fn runWorkerImpl(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: *const approaches_mod.ApproachPool,
    logger: *log_mod.Logger,
    io: Io,
    worker_id: u32,
    allocator: std.mem.Allocator,
    giveup_timeout_secs: u32,
    restart_timeout_secs: u32,
    max_restarts: u32,
    stream_output: bool,
) !void {
    // Lock check
    var lock_path_buf: [256]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "/tmp/bees-{s}-worker-{d}.lock", .{ cfg.project.name, worker_id }) catch return;

    if (!try acquireLock(lock_path)) {
        logger.info("[worker:{d}] another instance running, skipping", .{worker_id});
        return;
    }
    defer releaseLock(lock_path);

    // Select approach
    const approach = pool.select() orelse {
        logger.info("[worker:{d}] no active approaches, skipping", .{worker_id});
        return;
    };
    logger.info("[worker:{d}] start approach=\"{s}\"", .{ worker_id, approach.name });

    // Create worktree
    var ts_buf: [32]u8 = undefined;
    const now: u64 = fs.timestamp();
    const es = std.time.epoch.EpochSeconds{ .secs = now };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        @as(u6, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "00000000-000000";

    const branch_name = try std.fmt.allocPrint(allocator, "bee/{s}/worker-{d}-{s}", .{ cfg.project.name, worker_id, ts_str });
    defer allocator.free(branch_name);

    const worktree_dir = try std.fmt.allocPrint(allocator, "/tmp/bees-{s}/worktrees/worker-{d}-{s}", .{ cfg.project.name, worker_id, ts_str });
    defer allocator.free(worktree_dir);

    // Ensure parent dir exists
    const parent = std.fs.path.dirname(worktree_dir) orelse "/tmp";
    fs.makePath(parent) catch {};

    git.createWorktree(allocator, io, paths.root, branch_name, worktree_dir, cfg.project.base_branch, cfg.git.shallow_worktrees) catch |e| {
        logger.err("[worker:{d}] worktree create failed: {}", .{ worker_id, e });
        return;
    };

    // Create session in LMDB
    const model = types.ModelType.fromString(cfg.workers.model);
    const header = types.SessionHeader{
        .@"type" = .worker,
        .status = .running,
        .has_exit_code = false,
        .has_cost = false,
        .model = model,
        .has_tokens = false,
        .has_duration = false,
        .has_diff_summary = false,
        .worker_id = @intCast(worker_id),
        .commit_count = 0,
        .num_turns = 0,
        .exit_code = 0,
        .started_at = @truncate(now),
        .finished_at = 0,
        .duration_ms = 0,
        .cost_microdollars = 0,
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
    };

    const session_id = store.createSession(header, approach.name, branch_name, worktree_dir) catch |e| {
        logger.err("[worker:{d}] session create failed: {}", .{ worker_id, e });
        return;
    };

    // Build prompt with approach
    const prompt_path = try std.fs.path.join(allocator, &.{ paths.prompts_dir, "worker.txt" });
    defer allocator.free(prompt_path);

    // Run Claude with restart-on-timeout support
    var claude_session_id: ?[]const u8 = null;
    var last_result: ?claude.SessionResult = null;
    var attempt: u32 = 0;
    const total_start = now;

    while (true) {
        // Calculate timeout for this attempt
        const elapsed = fs.timestamp() -| total_start;
        const effective_timeout = if (restart_timeout_secs > 0 and giveup_timeout_secs > 0)
            // Use restart timeout, but cap at remaining total time
            @min(restart_timeout_secs, @as(u32, @intCast(@min(
                @as(u64, giveup_timeout_secs) -| elapsed,
                std.math.maxInt(u32),
            ))))
        else if (giveup_timeout_secs > 0)
            giveup_timeout_secs
        else
            @as(u32, 0);

        // Check if we've exhausted total time
        if (giveup_timeout_secs > 0 and elapsed >= giveup_timeout_secs) {
            logger.info("[worker:{d}] give-up timeout reached after {d}s", .{ worker_id, elapsed });
            break;
        }

        const result = claude.runClaudeSession(store, io, .{
            .prompt = if (claude_session_id != null) "Continue your work from where you left off. Complete all remaining tasks." else approach.prompt,
            .cwd = worktree_dir,
            .append_prompt_file = prompt_path,
            .model = cfg.workers.model,
            .effort = cfg.workers.effort,
            .max_budget_usd = cfg.workers.max_budget_usd,
            .timeout_secs = effective_timeout,
            .resume_session_id = claude_session_id,
            .stream_output = stream_output,
            .db_dir = paths.db_dir,
        }, session_id, allocator) catch |e| {
            logger.err("[worker:{d}] claude session failed: {}", .{ worker_id, e });
            break;
        };

        last_result = result;

        // Capture conversation ID from init event
        if (result.claude_session_id.len > 0) {
            claude_session_id = result.claude_session_id;
        }

        // Check if timed out (exit code 124 from timeout command)
        if (result.exit_code == 124 and claude_session_id != null and attempt < max_restarts) {
            attempt += 1;
            logger.info("[worker:{d}] restart timeout ({d}s), resuming session (attempt {d}/{d})", .{
                worker_id, effective_timeout, attempt, max_restarts,
            });
            continue;
        }

        break; // Normal completion or non-resumable error
    }

    const result = last_result orelse return;

    // Count commits
    const commits = git.getCommitsAhead(allocator, io, paths.root, branch_name, cfg.project.base_branch) catch 0;

    // Finish session
    const finish_time: u64 = fs.timestamp();
    const has_tokens = (result.input_tokens > 0 or result.output_tokens > 0);
    const new_header = types.SessionHeader{
        .@"type" = .worker,
        .status = if (result.is_error and result.exit_code != 124) .err else .done,
        .has_exit_code = true,
        .has_cost = true,
        .model = model,
        .has_tokens = has_tokens,
        .has_duration = true,
        .has_diff_summary = false,
        .worker_id = @intCast(worker_id),
        .commit_count = @intCast(@min(commits, 255)),
        .num_turns = result.num_turns,
        .exit_code = result.exit_code,
        .started_at = @truncate(now),
        .finished_at = @truncate(finish_time),
        .duration_ms = @intCast(@min((finish_time - now) * 1000, std.math.maxInt(u32))),
        .cost_microdollars = result.cost_microdollars,
        .input_tokens = result.input_tokens,
        .output_tokens = result.output_tokens,
        .cache_creation_tokens = result.cache_creation_tokens,
        .cache_read_tokens = result.cache_read_tokens,
    };

    store.updateSessionStatus(session_id, .running, @truncate(now), new_header) catch |e| {
        logger.err("[worker:{d}] session update failed: {}", .{ worker_id, e });
    };

    // Write .done marker and .session-id if commits > 0
    if (commits > 0) {
        const marker_path = try std.fmt.allocPrint(allocator, "{s}/.done", .{worktree_dir});
        defer allocator.free(marker_path);
        const marker = fs.createFile(marker_path, .{}) catch null;
        if (marker) |f| fs.closeFile(f);

        // Write session ID so merger can update worker status after review
        const sid_path = try std.fmt.allocPrint(allocator, "{s}/.session-id", .{worktree_dir});
        defer allocator.free(sid_path);
        var sid_buf: [32]u8 = undefined;
        const sid_str = std.fmt.bufPrint(&sid_buf, "{d}", .{session_id}) catch "";
        const sid_file = fs.createFile(sid_path, .{}) catch null;
        if (sid_file) |f| {
            fs.writeFile(f, sid_str) catch {};
            fs.closeFile(f);
        }
    }

    // Update approach stats
    {
        const txn = store.beginWriteTxn() catch null;
        if (txn) |t| {
            store.incrementApproachStat(t, approach.name, .total_runs) catch {};
            if (commits == 0) store.incrementApproachStat(t, approach.name, .empty) catch {};
            store_mod.Store.commitTxn(t) catch {};
        }
    }

    const restarts = if (attempt > 0) attempt else @as(u32, 0);
    if (restarts > 0) {
        logger.info("[worker:{d}] done approach=\"{s}\" commits={d} cost=${d:.2} restarts={d}", .{
            worker_id,
            approach.name,
            commits,
            @as(f64, @floatFromInt(result.cost_microdollars)) / 1000000.0,
            restarts,
        });
    } else {
        logger.info("[worker:{d}] done approach=\"{s}\" commits={d} cost=${d:.2}", .{
            worker_id,
            approach.name,
            commits,
            @as(f64, @floatFromInt(result.cost_microdollars)) / 1000000.0,
        });
    }
}

pub fn runAllWorkers(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: *const approaches_mod.ApproachPool,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
    stream_output: bool,
) !void {
    const count = cfg.workers.count;
    logger.info("spawning {d} workers", .{count});

    var threads = try allocator.alloc(std.Thread, count);
    defer allocator.free(threads);

    for (0..count) |i| {
        const worker_id: u32 = @intCast(i + 1);
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn work(c: config_mod.Config, p: config_mod.ProjectPaths, s: *store_mod.Store, pl: *const approaches_mod.ApproachPool, lg: *log_mod.Logger, iox: Io, wid: u32, alloc: std.mem.Allocator, so: bool) void {
                runWorker(c, p, s, pl, lg, iox, wid, alloc, so) catch |e| {
                    lg.err("[worker:{d}] fatal: {}", .{ wid, e });
                };
            }
        }.work, .{ cfg, paths, store, pool, logger, io, worker_id, allocator, stream_output });
    }

    for (threads) |t| t.join();
    logger.info("all workers completed", .{});
}

fn acquireLock(path: []const u8) !bool {
    const file = fs.createFile(path, .{ .exclusive = true }) catch {
        // Lock exists — check if PID is alive
        const existing = fs.openFile(path) catch return false;
        defer fs.closeFile(existing);
        var pid_buf: [32]u8 = undefined;
        const len = fs.readAll(existing, &pid_buf) catch return false;
        if (len == 0) {
            fs.deleteFile(path) catch return false;
            return acquireLock(path);
        }
        const pid_str = std.mem.trim(u8, pid_buf[0..len], &std.ascii.whitespace);
        const pid = std.fmt.parseInt(std.c.pid_t, pid_str, 10) catch {
            fs.deleteFile(path) catch return false;
            return acquireLock(path);
        };
        // Signal 0 checks if process exists without sending a signal
        const rc = std.c.kill(pid, @enumFromInt(0));
        if (rc != 0) {
            // Process doesn't exist (ESRCH) — stale lock
            fs.deleteFile(path) catch return false;
            return acquireLock(path);
        }
        return false; // Process is alive, lock is held
    };

    // Write our PID
    var pid_buf: [32]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{std.c.getpid()}) catch "";
    fs.writeFile(file, pid_str) catch {};
    fs.closeFile(file);
    return true;
}

fn releaseLock(path: []const u8) void {
    fs.deleteFile(path) catch {};
}

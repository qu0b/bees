const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const types = @import("types.zig");
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const git = @import("git.zig");
const backend = @import("backend.zig");
const tasks_mod = @import("tasks.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");
const role_mod = @import("role.zig");
const knowledge = @import("knowledge.zig");
const ctx = @import("context.zig");
const mc_connector = @import("mc_connector.zig");
const security_profiles = @import("security_profiles.zig");

pub const WorkerResult = struct {
    session_id: u64 = 0,
    tool_errors: u16 = 0,
};

pub fn runWorkerWithTimeout(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: *const tasks_mod.TaskPool,
    logger: *log_mod.Logger,
    io: Io,
    worker_id: u32,
    allocator: std.mem.Allocator,
    timeout_secs: u32,
) !WorkerResult {
    return runWorkerImpl(cfg, paths, store, pool, logger, io, worker_id, allocator, timeout_secs, cfg.daemon.restart_timeout_minutes * 60, cfg.daemon.max_restarts, false);
}

pub fn runWorker(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: *const tasks_mod.TaskPool,
    logger: *log_mod.Logger,
    io: Io,
    worker_id: u32,
    allocator: std.mem.Allocator,
    stream_output: bool,
) !WorkerResult {
    return runWorkerImpl(cfg, paths, store, pool, logger, io, worker_id, allocator, 0, 0, 0, stream_output);
}

fn runWorkerImpl(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: *const tasks_mod.TaskPool,
    logger: *log_mod.Logger,
    io: Io,
    worker_id: u32,
    allocator: std.mem.Allocator,
    giveup_timeout_secs: u32,
    restart_timeout_secs: u32,
    max_restarts: u32,
    stream_output: bool,
) !WorkerResult {
    assert(worker_id > 0);
    assert(paths.root.len > 0);
    assert(cfg.project.name.len > 0);

    // Lock check
    var lock_path_buf: [256]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "/tmp/bees-{s}-worker-{d}.lock", .{ cfg.project.name, worker_id }) catch return .{};

    if (!try acquireLock(lock_path)) {
        logger.info("[worker:{d}] another instance running, skipping", .{worker_id});
        return .{};
    }
    defer releaseLock(lock_path);

    // Select task
    const task = pool.select() orelse {
        logger.info("[worker:{d}] no active tasks, skipping", .{worker_id});
        return .{};
    };
    logger.info("[worker:{d}] start task=\"{s}\"", .{ worker_id, task.name });

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
        return .{};
    };

    // Run setup command (e.g. npm install) to prepare the worktree
    if (cfg.build.setup_command) |setup_cmd| {
        logger.info("[worker:{d}] running setup: {s}", .{ worker_id, setup_cmd });
        if (git.run(allocator, io, &.{ "sh", "-c", setup_cmd }, worktree_dir)) |setup_result| {
            allocator.free(setup_result.stdout);
            allocator.free(setup_result.stderr);
            if (setup_result.exit_code != 0) {
                logger.warn("[worker:{d}] setup command exited {d}", .{ worker_id, setup_result.exit_code });
            }
        } else |e| {
            logger.warn("[worker:{d}] setup command failed to spawn: {}", .{ worker_id, e });
        }
    }

    // Create session in LMDB
    const bt = backend.resolveBackend(cfg.default_backend, cfg.workers.backend);
    const model = types.ModelType.fromString(cfg.workers.model);
    const header = types.SessionHeader{
        .type = .worker,
        .status = .running,
        .has_exit_code = false,
        .has_cost = false,
        .model = model,
        .has_tokens = false,
        .has_duration = false,
        .has_diff_summary = false,
        .backend = bt,
        .worker_id = @truncate(worker_id),
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

    const session_id = store.createSession(header, task.name, branch_name, worktree_dir) catch |e| {
        logger.err("[worker:{d}] session create failed: {}", .{ worker_id, e });
        return .{};
    };

    // Build prompt with task
    const prompt_path = try std.fs.path.join(allocator, &.{ paths.prompts_dir, "worker.txt" });
    defer allocator.free(prompt_path);

    // Resolve per-role security permissions
    const role_config = blk: {
        const role_set = role_mod.loadRoles(paths, allocator) catch break :blk null;
        break :blk role_set.get("worker");
    };
    const perms = if (role_config) |rc| rc.resolvePermissions() else security_profiles.getDefaultForSessionType(.worker);

    // Resolve mc plugin MCP config if role declares plugins
    var merged_mcp_path: ?[]const u8 = null;
    if (role_config) |rc| {
        if (rc.plugins.len > 0) {
            const mcp_out = std.fmt.allocPrint(allocator, "/tmp/bees-{s}/mcp-worker-{d}.json", .{ cfg.project.name, worker_id }) catch null;
            if (mcp_out) |p| {
                if (mc_connector.writeMergedMcpConfig(allocator, paths.root, p, rc.mcp_config, rc.plugins) catch false) {
                    merged_mcp_path = p;
                }
            }
            // Symlink plugin skills into worktree
            _ = mc_connector.symlinkPluginSkills(allocator, paths.root, worktree_dir, rc.plugins) catch 0;
        }
    }
    const effective_mcp = merged_mcp_path orelse if (role_config) |rc| rc.mcp_config else null;

    // Build knowledge context for the worker (if role declares knowledge sources)
    const kb_context: ?[]const u8 = blk: {
        if (role_config) |rc| {
            const resolved = role_mod.resolveContextSources(rc, allocator);
            if (resolved.knowledge_tags) |tags| {
                const rtxn = store.beginReadTxn() catch break :blk null;
                defer store_mod.Store.abortTxn(rtxn);
                const index = knowledge.loadIndex(store, rtxn, allocator) orelse break :blk null;
                break :blk knowledge.buildContext(paths.knowledge_dir, index, tags, 16384, allocator);
            }
        }
        break :blk null;
    };
    defer if (kb_context) |kc| allocator.free(kc);

    // Combine task prompt with knowledge context
    const effective_prompt = if (kb_context) |kc|
        std.fmt.allocPrint(allocator, "{s}\n{s}", .{ task.prompt, kc }) catch task.prompt
    else
        task.prompt;
    defer if (effective_prompt.ptr != task.prompt.ptr) allocator.free(effective_prompt);

    // Run Claude with restart-on-timeout support
    var claude_session_id: ?[]const u8 = null;
    var last_result: ?backend.SessionResult = null;
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

        const result = backend.runSession(store, io, .{
            .backend = bt,
            // On resume: CLI auto-continues interrupted turn via CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1.
            // Just pass original prompt (used for session metadata); the resume flag handles continuation.
            .prompt = effective_prompt,
            .cwd = worktree_dir,
            .append_prompt_file = prompt_path,
            .model = cfg.workers.model,
            .fallback_model = cfg.workers.fallback_model,
            .effort = cfg.workers.effort,
            .max_budget_usd = cfg.workers.max_budget_usd,
            .timeout_secs = effective_timeout,
            .resume_session_id = claude_session_id,
            .stream_output = stream_output,
            .db_dir = paths.db_dir,
            .mcp_config = effective_mcp,
            .permission_mode = if (perms) |p| p.permission_mode else null,
            .allowed_tools = if (perms) |p| if (p.allowed_tools.len > 0) p.allowed_tools else null else null,
            .disallowed_tools = if (perms) |p| if (p.disallowed_tools.len > 0) p.disallowed_tools else null else null,
        }, session_id, allocator) catch |e| {
            logger.err("[worker:{d}] session failed: {}", .{ worker_id, e });
            break;
        };

        // Free previous result's heap strings before overwriting
        if (last_result) |prev| {
            if (prev.result_text.len > 0) allocator.free(prev.result_text);
            // Only free previous session ID if the new result provides a replacement;
            // otherwise the outer claude_session_id still references it for resume.
            if (prev.claude_session_id.len > 0 and result.claude_session_id.len > 0) {
                allocator.free(prev.claude_session_id);
            }
        }
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

    const result = last_result orelse return .{ .session_id = session_id };
    defer {
        if (result.result_text.len > 0) allocator.free(result.result_text);
        if (result.claude_session_id.len > 0) allocator.free(result.claude_session_id);
    }

    // Count commits
    const commits = git.getCommitsAhead(allocator, io, paths.root, branch_name, cfg.project.base_branch) catch 0;

    // Finish session
    const finish_time: u64 = fs.timestamp();
    const has_tokens = (result.input_tokens > 0 or result.output_tokens > 0);
    const rs = types.ResultSubtype.fromString(result.result_subtype);
    const sr = types.StopReason.fromString(result.stop_reason);
    const has_detail = rs != .unknown or sr != .unknown or result.duration_api_ms > 0;
    const new_header = types.SessionHeader{
        .type = .worker,
        // Mark as done (not error) for: timeout restarts, max_turns, max_budget
        .status = if (result.is_error and result.exit_code != 124 and
            rs != .error_max_turns and rs != .error_max_budget) .err else .done,
        .has_exit_code = true,
        .has_cost = true,
        .model = model,
        .has_tokens = has_tokens,
        .has_duration = true,
        .has_diff_summary = false,
        .backend = bt,
        .has_result_detail = has_detail,
        .worker_id = @truncate(worker_id),
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
        .result_subtype = rs,
        .stop_reason = sr,
        .duration_api_ms = result.duration_api_ms,
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

    // Update task stats
    {
        const txn = store.beginWriteTxn() catch null;
        if (txn) |t| {
            store.incrementTaskStat(t, task.name, .total_runs) catch {};
            if (commits == 0) store.incrementTaskStat(t, task.name, .empty) catch {};
            store_mod.Store.commitTxn(t) catch {};
        }
    }

    {
        const subtype = if (result.result_subtype.len > 0) result.result_subtype else "unknown";
        const stop = if (result.stop_reason.len > 0) result.stop_reason else "-";
        logger.info("[worker:{d}] done task=\"{s}\" commits={d} cost=${d:.2} turns={d} subtype={s} stop={s} tool_errors={d}", .{
            worker_id,
            task.name,
            commits,
            @as(f64, @floatFromInt(result.cost_microdollars)) / 1000000.0,
            result.num_turns,
            subtype,
            stop,
            result.tool_errors,
        });
    }

    return .{ .session_id = session_id, .tool_errors = result.tool_errors };
}

pub fn runAllWorkers(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: *const tasks_mod.TaskPool,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
    stream_output: bool,
) !void {
    const count = cfg.workers.count;
    logger.info("spawning {d} workers as async green threads", .{count});

    var group: Io.Group = Io.Group.init;
    for (0..count) |i| {
        const worker_id: u32 = @intCast(i + 1);
        group.async(io, workerGroupTask, .{
            cfg, paths, store, pool, logger, io, worker_id, allocator, stream_output,
        });
    }
    group.await(io) catch {};
    logger.info("all workers completed", .{});
}

fn workerGroupTask(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    pool: *const tasks_mod.TaskPool,
    logger: *log_mod.Logger,
    io: Io,
    worker_id: u32,
    allocator: std.mem.Allocator,
    stream_output: bool,
) void {
    _ = runWorker(cfg, paths, store, pool, logger, io, worker_id, allocator, stream_output) catch |e| {
        logger.err("[worker:{d}] fatal: {}", .{ worker_id, e });
        return;
    };
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
            // Only reclaim lock on ESRCH (no such process).
            // EPERM means the process exists but is owned by another user — lock is valid.
            if (std.c.errno(rc) != .SRCH) return false;
            // Process doesn't exist — stale lock
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

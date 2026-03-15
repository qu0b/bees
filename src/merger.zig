const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const git = @import("git.zig");
const claude = @import("claude.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");

const WorktreeCandidate = struct {
    branch: []const u8,
    dir: []const u8,
    session_id: ?u64,
    worker_session_id: ?u64,
};

pub fn runMerger(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) !void {
    logger.info("[merger] starting scan", .{});

    // Scan worktrees for .done markers
    const worktree_base = try std.fmt.allocPrint(allocator, "/tmp/bees-{s}/worktrees", .{cfg.project.name});
    defer allocator.free(worktree_base);

    var candidates: std.ArrayList(WorktreeCandidate) = .empty;
    defer candidates.deinit(allocator);

    var dir = fs.openDir(worktree_base) catch {
        logger.info("[merger] no worktrees found", .{});
        return;
    };
    defer fs.closeDir(dir);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const wt_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_base, entry.name });

        // Check for .done marker
        const done_path = try std.fmt.allocPrint(allocator, "{s}/.done", .{wt_dir});
        defer allocator.free(done_path);
        if (!fs.access(done_path)) {
            allocator.free(wt_dir);
            continue;
        }

        const branch = try std.fmt.allocPrint(allocator, "bee/{s}/{s}", .{ cfg.project.name, entry.name });

        const commits = git.getCommitsAhead(allocator, io, paths.root, branch, cfg.project.base_branch) catch 0;
        if (commits == 0) {
            logger.info("[merger] {s}: 0 commits, skipping", .{entry.name});
            allocator.free(branch);
            allocator.free(wt_dir);
            continue;
        }

        // Read worker session ID from worktree
        const sid_path = try std.fmt.allocPrint(allocator, "{s}/.session-id", .{wt_dir});
        defer allocator.free(sid_path);
        const worker_sid: ?u64 = blk: {
            const content = fs.readFileAlloc(allocator, sid_path, 64) catch break :blk null;
            defer allocator.free(content);
            const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
            break :blk std.fmt.parseInt(u64, trimmed, 10) catch null;
        };

        try candidates.append(allocator, .{
            .branch = branch,
            .dir = wt_dir,
            .session_id = null,
            .worker_session_id = worker_sid,
        });
    }

    if (candidates.items.len == 0) {
        logger.info("[merger] no candidates to review", .{});
        return;
    }

    logger.info("[merger] found {d} candidates", .{candidates.items.len});

    // Review each candidate
    var accepted: std.ArrayList(usize) = .empty;
    defer accepted.deinit(allocator);

    for (candidates.items, 0..) |*candidate, idx| {
        const verdict = try reviewCandidate(cfg, paths, store, logger, io, candidate, allocator);
        if (verdict == .accept) {
            try accepted.append(allocator, idx);
        }
    }

    if (accepted.items.len == 0) {
        logger.info("[merger] no branches accepted", .{});
        return;
    }

    // Save HEAD before merging
    const saved_head = try git.getCurrentHead(allocator, io, paths.root);
    defer allocator.free(saved_head);

    // Merge accepted branches
    var merged_count: u32 = 0;
    for (accepted.items) |idx| {
        const candidate = &candidates.items[idx];
        logger.info("[merger] merging {s}", .{candidate.branch});

        const merge_result = try git.tryMerge(allocator, io, paths.root, candidate.branch);
        switch (merge_result) {
            .success => {
                merged_count += 1;
                logger.info("[merger] merged {s} successfully", .{candidate.branch});
            },
            .conflict => |conflict| {
                if (conflict.files.len <= cfg.merger.max_conflict_files) {
                    logger.info("[merger] {s}: {d} conflicts, attempting AI resolution", .{ candidate.branch, conflict.files.len });
                    const resolved = try resolveConflicts(cfg, paths, store, logger, io, candidate, allocator);
                    if (resolved) {
                        merged_count += 1;
                    } else {
                        try git.abortMerge(allocator, io, paths.root);
                        writeMarker(allocator, candidate.dir, ".conflict");
                        if (candidate.worker_session_id) |wsid| {
                            updateWorkerStatus(store, wsid, .conflict_status) catch {};
                        }
                    }
                } else {
                    logger.info("[merger] {s}: too many conflicts ({d}), aborting", .{ candidate.branch, conflict.files.len });
                    try git.abortMerge(allocator, io, paths.root);
                    writeMarker(allocator, candidate.dir, ".conflict");
                    if (candidate.worker_session_id) |wsid| {
                        updateWorkerStatus(store, wsid, .conflict_status) catch {};
                    }
                }
            },
        }
    }

    if (merged_count == 0) {
        logger.info("[merger] no branches merged", .{});
        return;
    }

    // Build, test, deploy pipeline
    const pipeline_ok = try runPipeline(cfg, paths, store, logger, io, saved_head, allocator);

    if (pipeline_ok) {
        for (accepted.items) |idx| {
            const candidate = &candidates.items[idx];
            // Mark worker session as merged
            if (candidate.worker_session_id) |wsid| {
                updateWorkerStatus(store, wsid, .merged) catch {};
            }
            cleanupWorktree(allocator, io, paths.root, candidate);
            logger.info("[merger] cleaned up {s}", .{candidate.branch});
        }
    }

    try cleanupOldWorktrees(cfg, paths, logger, io, worktree_base, allocator);

    logger.info("[merger] done. merged={d}", .{merged_count});
}

fn reviewCandidate(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    candidate: *WorktreeCandidate,
    allocator: std.mem.Allocator,
) !types.Verdict {
    const diff = git.getDiff(allocator, io, paths.root, candidate.branch, cfg.project.base_branch) catch |e| {
        logger.err("[merger] diff failed for {s}: {}", .{ candidate.branch, e });
        return .reject;
    };
    defer allocator.free(diff);

    if (diff.len == 0) return .reject;

    const merger_model = types.ModelType.fromString(cfg.merger.model);
    const now: u64 = fs.timestamp();
    const header = types.SessionHeader{
        .@"type" = .review,
        .status = .running,
        .has_exit_code = false,
        .has_cost = false,
        .model = merger_model,
        .has_tokens = false,
        .has_duration = false,
        .has_diff_summary = false,
        .worker_id = 0,
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

    const session_id = try store.createSession(header, "", candidate.branch, "");
    candidate.session_id = session_id;

    const review_prompt_path = try std.fs.path.join(allocator, &.{ paths.prompts_dir, "review.txt" });
    defer allocator.free(review_prompt_path);

    const result = claude.runClaudeSession(store, io, .{
        .prompt = "Review the following diff and respond with ACCEPT or REJECT followed by your reasoning.",
        .cwd = paths.root,
        .system_prompt_file = review_prompt_path,
        .stdin_data = diff,
        .model = cfg.merger.model,
        .effort = cfg.merger.effort,
        .max_budget_usd = cfg.merger.max_budget_usd,
        .db_dir = paths.db_dir,
    }, session_id, allocator) catch |e| {
        logger.err("[merger] review failed for {s}: {}", .{ candidate.branch, e });
        return .reject;
    };

    const verdict = parseVerdict(result.result_text);

    {
        const txn = try store.beginWriteTxn();
        errdefer store_mod.Store.abortTxn(txn);

        const review_header = types.ReviewHeader{
            .verdict = verdict,
            .review_session_id = @truncate(session_id),
            .reviewed_at = @truncate(now),
        };
        try store.insertReview(txn, session_id, review_header, result.result_text);

        // Increment approach stats for the worker's approach
        if (candidate.worker_session_id) |wsid| {
            if (try store.getSession(txn, wsid)) |worker_session| {
                if (worker_session.approach.len > 0 and worker_session.approach.len <= 256) {
                    var name_buf: [256]u8 = undefined;
                    const name_len = worker_session.approach.len;
                    @memcpy(name_buf[0..name_len], worker_session.approach[0..name_len]);
                    store.incrementApproachStat(txn, name_buf[0..name_len], if (verdict == .accept) .accepted else .rejected) catch {};
                }
            }
        }

        try store_mod.Store.commitTxn(txn);
    }

    // Update review session status to done
    {
        var updated_header = header;
        updated_header.status = .done;
        updated_header.has_cost = true;
        updated_header.cost_microdollars = result.cost_microdollars;
        updated_header.duration_ms = @as(u32, result.duration_secs) * 1000;
        updated_header.finished_at = @truncate(fs.timestamp());
        updated_header.num_turns = result.num_turns;
        updated_header.has_tokens = (result.input_tokens > 0 or result.output_tokens > 0);
        updated_header.input_tokens = result.input_tokens;
        updated_header.output_tokens = result.output_tokens;
        updated_header.cache_creation_tokens = result.cache_creation_tokens;
        updated_header.cache_read_tokens = result.cache_read_tokens;
        store.updateSessionStatus(session_id, .running, header.started_at, updated_header) catch {};
    }

    logger.info("[merger] review {s}: {s}", .{ candidate.branch, verdict.label() });
    if (verdict == .reject) {
        writeMarker(allocator, candidate.dir, ".rejected");
        // Update the original worker session status to rejected
        if (candidate.worker_session_id) |wsid| {
            updateWorkerStatus(store, wsid, .rejected) catch {};
        }
    }

    return verdict;
}

fn parseVerdict(text: []const u8) types.Verdict {
    const upper_start = if (text.len > 200) text[0..200] else text;
    if (std.mem.indexOf(u8, upper_start, "ACCEPT") != null) return .accept;
    return .reject;
}

fn resolveConflicts(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    candidate: *WorktreeCandidate,
    allocator: std.mem.Allocator,
) !bool {
    const conflict_model = types.ModelType.fromString(cfg.merger.model);
    const now: u64 = fs.timestamp();
    const header = types.SessionHeader{
        .@"type" = .conflict,
        .status = .running,
        .has_exit_code = false,
        .has_cost = false,
        .model = conflict_model,
        .has_tokens = false,
        .has_duration = false,
        .has_diff_summary = false,
        .worker_id = 0,
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

    const session_id = try store.createSession(header, "", candidate.branch, paths.root);

    const conflict_prompt_path = try std.fs.path.join(allocator, &.{ paths.prompts_dir, "conflict.txt" });
    defer allocator.free(conflict_prompt_path);

    const cr_result = claude.runClaudeSession(store, io, .{
        .prompt = "Resolve all merge conflicts in this repository. Ensure the code compiles and tests pass.",
        .cwd = paths.root,
        .append_prompt_file = conflict_prompt_path,
        .model = cfg.merger.model,
        .effort = cfg.merger.effort,
        .max_budget_usd = cfg.merger.max_budget_usd,
        .db_dir = paths.db_dir,
    }, session_id, allocator) catch |e| {
        logger.err("[merger] conflict resolution failed: {}", .{e});
        return false;
    };

    const check = git.run(allocator, io, &.{ "git", "diff", "--name-only", "--diff-filter=U" }, paths.root) catch return false;
    defer allocator.free(check.stdout);
    defer allocator.free(check.stderr);

    const resolved = check.stdout.len == 0;

    // Update conflict session status
    {
        var updated_header = header;
        updated_header.status = if (resolved) .done else .conflict_status;
        updated_header.has_cost = true;
        updated_header.cost_microdollars = cr_result.cost_microdollars;
        updated_header.duration_ms = @as(u32, cr_result.duration_secs) * 1000;
        updated_header.finished_at = @truncate(fs.timestamp());
        updated_header.num_turns = cr_result.num_turns;
        updated_header.has_tokens = (cr_result.input_tokens > 0 or cr_result.output_tokens > 0);
        updated_header.input_tokens = cr_result.input_tokens;
        updated_header.output_tokens = cr_result.output_tokens;
        updated_header.cache_creation_tokens = cr_result.cache_creation_tokens;
        updated_header.cache_read_tokens = cr_result.cache_read_tokens;
        store.updateSessionStatus(session_id, .running, header.started_at, updated_header) catch {};
    }

    if (resolved) {
        git.commitMerge(allocator, io, paths.root) catch return false;
        logger.info("[merger] conflicts resolved for {s}", .{candidate.branch});
        return true;
    }

    return false;
}

fn runPipeline(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    saved_head: []const u8,
    allocator: std.mem.Allocator,
) !bool {
    if (cfg.build.command) |build_cmd| {
        if (!try runBuildStep(cfg, paths, store, logger, io, "build", build_cmd, saved_head, allocator)) return false;
    }

    if (cfg.build.test_command) |test_cmd| {
        if (!try runBuildStep(cfg, paths, store, logger, io, "test", test_cmd, saved_head, allocator)) return false;
    }

    if (cfg.smoke_test.enabled) {
        logger.info("[merger] smoke test skipped (not implemented in MVP)", .{});
    }

    if (cfg.build.deploy_command) |deploy_cmd| {
        logger.info("[merger] deploying...", .{});
        const result = try runShellCommand(allocator, io, deploy_cmd, paths.root);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.exit_code != 0) {
            logger.warn("[merger] deploy failed, retrying...", .{});
            const retry = try runShellCommand(allocator, io, deploy_cmd, paths.root);
            defer allocator.free(retry.stdout);
            defer allocator.free(retry.stderr);
            if (retry.exit_code != 0) {
                logger.err("[merger] deploy failed after retry", .{});
            }
        }
    }

    return true;
}

fn runBuildStep(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    step_name: []const u8,
    command: []const u8,
    saved_head: []const u8,
    allocator: std.mem.Allocator,
) !bool {
    logger.info("[merger] running {s}: {s}", .{ step_name, command });
    const result = try runShellCommand(allocator, io, command, paths.root);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code == 0) return true;

    logger.warn("[merger] {s} failed, attempting AI fix", .{step_name});

    const fix_model = types.ModelType.fromString(cfg.merger.model);
    const now: u64 = fs.timestamp();
    const header = types.SessionHeader{
        .@"type" = .fix,
        .status = .running,
        .has_exit_code = false,
        .has_cost = false,
        .model = fix_model,
        .has_tokens = false,
        .has_duration = false,
        .has_diff_summary = false,
        .worker_id = 0,
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

    const session_id = try store.createSession(header, "", "", paths.root);

    const fix_prompt_path = try std.fs.path.join(allocator, &.{ paths.prompts_dir, "fix.txt" });
    defer allocator.free(fix_prompt_path);

    const error_context = try std.fmt.allocPrint(allocator, "The {s} command `{s}` failed with:\n{s}\n{s}\nFix the issue.", .{ step_name, command, result.stdout, result.stderr });
    defer allocator.free(error_context);

    const fix_result = claude.runClaudeSession(store, io, .{
        .prompt = error_context,
        .cwd = paths.root,
        .append_prompt_file = fix_prompt_path,
        .model = cfg.merger.model,
        .effort = cfg.merger.effort,
        .max_budget_usd = cfg.merger.max_budget_usd,
        .db_dir = paths.db_dir,
    }, session_id, allocator) catch {
        logger.err("[merger] AI fix failed", .{});
        git.resetHard(allocator, io, paths.root, saved_head) catch {};
        return false;
    };

    const retry = try runShellCommand(allocator, io, command, paths.root);
    defer allocator.free(retry.stdout);
    defer allocator.free(retry.stderr);

    const fix_ok = retry.exit_code == 0;

    // Update fix session status
    {
        var updated_header = header;
        updated_header.status = if (fix_ok) .done else .build_failed;
        updated_header.has_cost = true;
        updated_header.cost_microdollars = fix_result.cost_microdollars;
        updated_header.duration_ms = @as(u32, fix_result.duration_secs) * 1000;
        updated_header.finished_at = @truncate(fs.timestamp());
        updated_header.num_turns = fix_result.num_turns;
        updated_header.has_tokens = (fix_result.input_tokens > 0 or fix_result.output_tokens > 0);
        updated_header.input_tokens = fix_result.input_tokens;
        updated_header.output_tokens = fix_result.output_tokens;
        updated_header.cache_creation_tokens = fix_result.cache_creation_tokens;
        updated_header.cache_read_tokens = fix_result.cache_read_tokens;
        store.updateSessionStatus(session_id, .running, header.started_at, updated_header) catch {};
    }

    if (fix_ok) {
        logger.info("[merger] AI fix succeeded for {s}", .{step_name});
        return true;
    }

    logger.err("[merger] AI fix did not resolve {s} failure, rolling back", .{step_name});
    git.resetHard(allocator, io, paths.root, saved_head) catch {};
    return false;
}

fn runShellCommand(allocator: std.mem.Allocator, io: Io, command: []const u8, cwd: []const u8) !git.GitResult {
    return git.run(allocator, io, &.{ "sh", "-c", command }, cwd);
}

fn cleanupWorktree(allocator: std.mem.Allocator, io: Io, repo_path: []const u8, candidate: *const WorktreeCandidate) void {
    git.removeWorktree(allocator, io, repo_path, candidate.dir) catch {};
    git.deleteBranch(allocator, io, repo_path, candidate.branch) catch {};
}

fn writeMarker(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) void {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name }) catch return;
    defer allocator.free(path);
    const file = fs.createFile(path, .{}) catch return;
    fs.closeFile(file);
}

fn cleanupOldWorktrees(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    logger: *log_mod.Logger,
    io: Io,
    worktree_base: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var dir = fs.openDir(worktree_base) catch return;
    defer fs.closeDir(dir);

    // TODO: once we can stat files, compare worktree age vs cfg.timeouts

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const wt_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_base, entry.name });
        defer allocator.free(wt_dir);

        const has_rejected = hasFile(allocator, wt_dir, ".rejected");
        const has_conflict = hasFile(allocator, wt_dir, ".conflict");
        const has_build_failed = hasFile(allocator, wt_dir, ".build-failed");
        const has_done = hasFile(allocator, wt_dir, ".done");

        if (has_rejected or has_conflict or has_build_failed or !has_done) {
            const branch = std.fmt.allocPrint(allocator, "bee/{s}/{s}", .{ cfg.project.name, entry.name }) catch continue;
            defer allocator.free(branch);
            git.removeWorktree(allocator, io, paths.root, wt_dir) catch {};
            git.deleteBranch(allocator, io, paths.root, branch) catch {};
            logger.info("[merger] cleaned old worktree {s}", .{entry.name});
        }
    }
}

fn hasFile(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) bool {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name }) catch return false;
    defer allocator.free(path);
    return fs.access(path);
}

fn updateWorkerStatus(store: *store_mod.Store, worker_session_id: u64, new_status: types.SessionStatus) !void {
    const txn = try store.beginReadTxn();
    const session = (try store.getSession(txn, worker_session_id)) orelse {
        store_mod.Store.abortTxn(txn);
        return;
    };
    const old_started_at = session.header.started_at;
    store_mod.Store.abortTxn(txn);

    var updated_header = session.header;
    updated_header.status = new_status;
    try store.updateSessionStatus(worker_session_id, .done, old_started_at, updated_header);
}

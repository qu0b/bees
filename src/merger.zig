const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const types = @import("types.zig");
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const git = @import("git.zig");
const backend = @import("backend.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");
const ctx_mod = @import("context.zig");
const seed_mod = @import("seed.zig");

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
    seed_uuid: ?[]const u8,
) !void {
    assert(cfg.project.name.len > 0);
    assert(paths.root.len > 0);
    assert(cfg.project.base_branch.len > 0);

    logger.info("[merger] starting scan", .{});

    // Ensure clean working tree before merging. QA, strategist, and build
    // commands run in the main repo and can leave uncommitted changes that
    // cause `git merge` to refuse.
    ensureCleanWorktree(cfg, paths, logger, io, allocator);

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

    const now: u64 = fs.timestamp();
    const stale_cutoff = now -| (@as(u64, cfg.timeouts.stale_hours) * 3600);

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

        // Age-gate: parse timestamp from directory name (worker-{id}-{YYYYMMDD-HHMMSS})
        // and skip worktrees older than timeouts.stale_hours
        if (parseWorktreeTimestamp(entry.name)) |wt_time| {
            if (wt_time < stale_cutoff) {
                const age_hours = (now - wt_time) / 3600;
                logger.info("[merger] {s}: stale ({d}h old, cutoff={d}h), cleaning up", .{ entry.name, age_hours, cfg.timeouts.stale_hours });
                const branch = std.fmt.allocPrint(allocator, "bee/{s}/{s}", .{ cfg.project.name, entry.name }) catch {
                    allocator.free(wt_dir);
                    continue;
                };
                defer allocator.free(branch);
                git.removeWorktree(allocator, io, paths.root, wt_dir) catch {};
                git.deleteBranch(allocator, io, paths.root, branch) catch {};
                allocator.free(wt_dir);
                continue;
            }
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

    // Save HEAD before any merges for rollback
    const saved_head = try git.getCurrentHead(allocator, io, paths.root);
    defer allocator.free(saved_head);

    // For each candidate: one Claude agent session reviews the diff AND
    // performs the merge if it approves. The verdict is determined by
    // whether HEAD moved — no text parsing needed.
    // Merged candidates are finalized (branch deleted, session marked .merged,
    // task .accepted) ONLY after the build/test/deploy pipeline confirms the
    // merged base is good. Finalizing earlier means a pipeline failure — which
    // rolls base back to saved_head — would leave the source branches already
    // deleted and the sessions falsely marked merged, silently losing the work.
    var merged_count: u32 = 0;
    var merged_candidates: std.ArrayList(*WorktreeCandidate) = .empty;
    defer merged_candidates.deinit(allocator);

    for (candidates.items) |*candidate| {
        const pre_head = git.getCurrentHead(allocator, io, paths.root) catch continue;
        defer allocator.free(pre_head);

        const outcome = reviewAndMerge(cfg, paths, store, logger, io, candidate, allocator, seed_uuid);

        const post_head = git.getCurrentHead(allocator, io, paths.root) catch continue;
        defer allocator.free(post_head);

        if (!std.mem.eql(u8, pre_head, post_head)) {
            // HEAD moved — agent merged the branch. Defer finalization.
            merged_count += 1;
            merged_candidates.append(allocator, candidate) catch {};
        } else switch (outcome) {
            .reviewed, .empty_diff => {
                // The agent ran and chose not to merge (or there was nothing to
                // merge). A real verdict — safe to finalize as rejected.
                logger.info("[merger] {s}: not merged (rejected)", .{candidate.branch});
                writeMarker(allocator, candidate.dir, ".rejected");
                if (candidate.worker_session_id) |wsid| {
                    updateWorkerStatus(store, wsid, .rejected) catch {};
                    recordReview(store, candidate, wsid, .reject, "Rejected by review agent");
                    incrementWorkerTaskStat(store, wsid, .rejected);
                }
            },
            .review_failed => {
                // The review machinery broke — NOT a verdict on the work. Leave
                // the candidate pending so the next merger scan retries it,
                // instead of terminally discarding a worker's output. (The old
                // behavior turned one broken gate into 68 rejected sessions.)
                logger.warn("[merger] {s}: review failed, keeping candidate for retry", .{candidate.branch});
            },
        }
    }

    // Run the pipeline BEFORE finalizing any merge. A pipeline error is treated
    // as failure (rolled back) so we never finalize on an unverified base.
    const pipeline_ok = if (merged_count > 0)
        (runPipeline(cfg, paths, store, logger, io, saved_head, allocator) catch false)
    else
        true;
    if (merged_count > 0 and !pipeline_ok) {
        logger.warn("[merger] pipeline failed, changes rolled back to {s}", .{saved_head[0..@min(saved_head.len, 12)]});
    }

    for (merged_candidates.items) |candidate| {
        if (pipeline_ok) {
            if (candidate.worker_session_id) |wsid| {
                updateWorkerStatus(store, wsid, .merged) catch {};
                recordReview(store, candidate, wsid, .accept, "Merged by review agent");
                incrementWorkerTaskStat(store, wsid, .accepted);
            }
            cleanupWorktree(allocator, io, paths.root, candidate);
            logger.info("[merger] merged and cleaned up {s}", .{candidate.branch});
        } else {
            // Pipeline failed and base was rolled back — the merge is undone.
            // KEEP the branch (work is preserved for a retry) and mark rejected.
            writeMarker(allocator, candidate.dir, ".rejected");
            if (candidate.worker_session_id) |wsid| {
                updateWorkerStatus(store, wsid, .rejected) catch {};
                recordReview(store, candidate, wsid, .reject, "Reverted: post-merge pipeline failed");
                incrementWorkerTaskStat(store, wsid, .rejected);
            }
            logger.info("[merger] {s}: kept branch after pipeline rollback", .{candidate.branch});
        }
    }

    // Always clean up old/failed worktrees
    try cleanupOldWorktrees(cfg, paths, logger, io, worktree_base, allocator);

    logger.info("[merger] done. merged={d}/{d}", .{ merged_count, candidates.items.len });
}

/// Outcome of a review attempt. Distinguishes "the review agent ran and made a
/// call" from "the review machinery itself broke" — conflating them (the old
/// behavior) terminally rejected good work whenever the gate crashed.
const ReviewOutcome = enum {
    /// The review session ran to completion; the HEAD-moved check is the verdict.
    reviewed,
    /// The branch has no diff against base — nothing to merge.
    empty_diff,
    /// The review never happened (diff/spawn failure or session error). The
    /// candidate must stay pending for a retry, NOT be marked rejected.
    review_failed,
};

/// Combined review + merge agent. The agent reviews the diff, and if it
/// approves, merges the branch itself. Verdict is determined by whether
/// HEAD moved — no text parsing needed.
fn reviewAndMerge(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    candidate: *WorktreeCandidate,
    allocator: std.mem.Allocator,
    seed_uuid: ?[]const u8,
) ReviewOutcome {
    const diff = git.getDiff(allocator, io, paths.root, candidate.branch, cfg.project.base_branch) catch |e| {
        logger.err("[merger] diff failed for {s}: {}", .{ candidate.branch, e });
        return .review_failed;
    };
    defer allocator.free(diff);

    if (diff.len == 0) {
        logger.info("[merger] {s}: empty diff, skipping", .{candidate.branch});
        return .empty_diff;
    }

    const merger_model = types.ModelType.fromString(cfg.merger.model);
    const now: u64 = fs.timestamp();
    const review_bt = backend.resolveBackend(cfg.default_backend, cfg.merger.backend);
    const header = types.SessionHeader{
        .type = .review,
        .status = .running,
        .has_exit_code = false,
        .has_cost = false,
        .model = merger_model,
        .has_tokens = false,
        .has_duration = false,
        .has_diff_summary = false,
        .backend = review_bt,
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

    const session_id = store.createSession(header, "", candidate.branch, "") catch return .review_failed;
    candidate.session_id = session_id;

    const review_prompt_path = std.fs.path.join(allocator, &.{ paths.bees_dir, "roles", "review", "prompt.md" }) catch return .review_failed;
    defer allocator.free(review_prompt_path);

    // Cap diff to avoid blowing the context window
    const diff_preview = if (diff.len > 50000) diff[0..50000] else diff;

    // Look up what task the worker was working on
    const task_context = if (candidate.worker_session_id) |wsid|
        ctx_mod.getTaskContext(store, null, wsid, allocator) orelse ""
    else
        "";
    defer if (task_context.len > 0) allocator.free(task_context);

    // When seed is set, prepend review prompt.md content into user message
    const use_seed = seed_uuid != null;
    const review_prompt_content: ?[]const u8 = if (use_seed)
        fs.readFileAlloc(allocator, review_prompt_path, 256 * 1024) catch null
    else
        null;
    defer if (review_prompt_content) |rp| allocator.free(rp);

    var prompt_parts: std.ArrayList(u8) = .empty;
    if (review_prompt_content) |rp| {
        prompt_parts.appendSlice(allocator, rp) catch {};
        prompt_parts.appendSlice(allocator, "\n\n") catch {};
    }
    const review_body = std.fmt.allocPrint(allocator,
        \\Review and merge the following diff from branch `{s}`.
        \\
        \\You have full tool access. You can read source files, run the build, and run tests.
        \\{s}
        \\## Your task
        \\1. Review the diff below for correctness, safety, and quality
        \\2. If needed, read the surrounding source code for context
        \\3. If the changes are good:
        \\   - Run: `git merge --no-edit {s}`
        \\   - If there are conflicts, resolve them, then `git add -A && git commit --no-edit`
        \\   - Verify the build still passes
        \\4. If the changes are bad or harmful, do NOT merge. Explain why.
        \\
        \\```diff
        \\{s}
        \\```
    , .{ candidate.branch, task_context, candidate.branch, diff_preview }) catch return .review_failed;
    defer allocator.free(review_body);
    prompt_parts.appendSlice(allocator, review_body) catch {};

    const review_prompt = prompt_parts.toOwnedSlice(allocator) catch return .review_failed;
    defer allocator.free(review_prompt);

    logger.info("[merger] reviewing {s}", .{candidate.branch});

    const result = backend.runSession(store, io, .{
        .backend = review_bt,
        .prompt = review_prompt,
        .cwd = paths.root,
        .append_prompt_file = if (use_seed) null else review_prompt_path,
        .resume_session_id = seed_uuid,
        .fork_session = use_seed,
        .model = cfg.merger.model,
        .fallback_model = cfg.merger.fallback_model,
        .effort = cfg.merger.effort,
        .max_budget_usd = cfg.merger.max_budget_usd,
        .max_turns = 20,
        .db_dir = paths.db_dir,
    }, session_id, allocator, cfg.claude_binary, cfg.pi_binary) catch |e| {
        logger.err("[merger] review session failed for {s}: {}", .{ candidate.branch, e });
        return .review_failed;
    };
    defer {
        if (result.result_text.len > 0) allocator.free(result.result_text);
        if (result.claude_session_id.len > 0) allocator.free(result.claude_session_id);
    }

    // Update session status
    var updated_header = header;
    updated_header.status = if (result.is_error) .err else .done;
    updated_header.has_exit_code = true;
    updated_header.has_cost = true;
    updated_header.cost_microdollars = result.cost_microdollars;
    updated_header.finished_at = @truncate(fs.timestamp());
    updated_header.duration_ms = @intCast(@min((fs.timestamp() -| now) * 1000, std.math.maxInt(u32)));
    updated_header.num_turns = result.num_turns;
    updated_header.has_tokens = (result.input_tokens > 0 or result.output_tokens > 0);
    updated_header.input_tokens = result.input_tokens;
    updated_header.output_tokens = result.output_tokens;
    updated_header.cache_creation_tokens = result.cache_creation_tokens;
    updated_header.cache_read_tokens = result.cache_read_tokens;
    store.updateSessionStatus(session_id, .running, @truncate(now), updated_header) catch {};

    if (result.is_error) {
        // The gate itself broke (e.g. an API error) — this is NOT a verdict.
        if (result.result_text.len > 0) {
            logger.err("[merger] review error for {s}: {s}", .{ candidate.branch, result.result_text[0..@min(result.result_text.len, 300)] });
        }
        return .review_failed;
    }
    return .reviewed;
}

/// Increment the task stat for a worker session's task.
fn incrementWorkerTaskStat(store: *store_mod.Store, worker_session_id: u64, field: enum { accepted, rejected }) void {
    const read_txn = store.beginReadTxn() catch return;
    const session = (store.getSession(read_txn, worker_session_id) catch null) orelse {
        store_mod.Store.abortTxn(read_txn);
        return;
    };
    // Copy task name before closing read txn (it points into mmap)
    var name_buf: [256]u8 = undefined;
    const name_len = @min(session.task.len, name_buf.len);
    if (name_len == 0) {
        store_mod.Store.abortTxn(read_txn);
        return;
    }
    @memcpy(name_buf[0..name_len], session.task[0..name_len]);
    store_mod.Store.abortTxn(read_txn);

    const write_txn = store.beginWriteTxn() catch return;
    store.incrementTaskStat(write_txn, name_buf[0..name_len], switch (field) {
        .accepted => .accepted,
        .rejected => .rejected,
    }) catch {
        store_mod.Store.abortTxn(write_txn);
        return;
    };
    store_mod.Store.commitTxn(write_txn) catch {};
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
        .type = .fix,
        .status = .running,
        .has_exit_code = false,
        .has_cost = false,
        .model = fix_model,
        .has_tokens = false,
        .has_duration = false,
        .has_diff_summary = false,
        .backend = backend.resolveBackend(cfg.default_backend, cfg.merger.backend),
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

    const fix_prompt_path = try std.fs.path.join(allocator, &.{ paths.bees_dir, "roles", "fix", "prompt.md" });
    defer allocator.free(fix_prompt_path);

    const error_context = try std.fmt.allocPrint(allocator, "The {s} command `{s}` failed with:\n{s}\n{s}\nFix the issue.", .{ step_name, command, result.stdout, result.stderr });
    defer allocator.free(error_context);

    const fix_result = backend.runSession(store, io, .{
        .backend = header.backend,
        .prompt = error_context,
        .cwd = paths.root,
        .append_prompt_file = fix_prompt_path,
        .model = cfg.merger.model,
        .fallback_model = cfg.merger.fallback_model,
        .effort = cfg.merger.effort,
        .max_budget_usd = cfg.merger.max_budget_usd,
        .db_dir = paths.db_dir,
    }, session_id, allocator, cfg.claude_binary, cfg.pi_binary) catch {
        logger.err("[merger] AI fix failed", .{});
        git.resetHard(allocator, io, paths.root, saved_head) catch {};
        return false;
    };
    defer {
        if (fix_result.result_text.len > 0) allocator.free(fix_result.result_text);
        if (fix_result.claude_session_id.len > 0) allocator.free(fix_result.claude_session_id);
    }

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

/// Record a review verdict for a worker session in LMDB. Best-effort.
fn recordReview(
    store: *store_mod.Store,
    candidate: *const WorktreeCandidate,
    wsid: u64,
    verdict: types.Verdict,
    msg: []const u8,
) void {
    var txn_opt = store.beginWriteTxn() catch return;
    const t = txn_opt orelse return;
    const rh = types.ReviewHeader{
        .verdict = verdict,
        .review_session_id = @truncate(candidate.session_id orelse 0),
        .reviewed_at = @truncate(fs.timestamp()),
    };
    store.insertReview(t, wsid, rh, msg) catch {
        store_mod.Store.abortTxn(t);
        return;
    };
    store_mod.Store.commitTxnConsume(&txn_opt) catch {};
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
    // 1. Clean worktree directories with failure markers.
    //
    // A worktree that a live worker is still building has no marker at all yet
    // (the worker writes .done only on completion). Deleting such a dir destroys
    // that worker's in-progress work and leaves its session flailing in a removed
    // cwd. So only remove:
    //   - dirs with merger-written terminal markers (.rejected/.conflict/
    //     .build-failed) — the merger already finished processing them; or
    //   - dirs with no .done that are STALE (older than timeouts.stale_hours),
    //     i.e. abandoned by a crashed/never-finished worker. A recent no-.done
    //     dir is presumed to be an actively-running worker and is left alone.
    {
        var dir = fs.openDir(worktree_base) catch return;
        defer fs.closeDir(dir);

        const now: u64 = fs.timestamp();
        const stale_cutoff = now -| (@as(u64, cfg.timeouts.stale_hours) * 3600);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;

            const wt_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_base, entry.name });
            defer allocator.free(wt_dir);

            const has_rejected = hasFile(allocator, wt_dir, ".rejected");
            const has_conflict = hasFile(allocator, wt_dir, ".conflict");
            const has_build_failed = hasFile(allocator, wt_dir, ".build-failed");
            const has_done = hasFile(allocator, wt_dir, ".done");
            const terminal = has_rejected or has_conflict or has_build_failed;

            // Is this a stale, unfinished worktree (safe to reclaim)?
            const stale_unfinished = !has_done and blk: {
                const wt_time = parseWorktreeTimestamp(entry.name) orelse
                    break :blk false; // unparseable age → be conservative, keep it
                break :blk wt_time < stale_cutoff;
            };

            if (terminal or stale_unfinished) {
                const branch = std.fmt.allocPrint(allocator, "bee/{s}/{s}", .{ cfg.project.name, entry.name }) catch continue;
                defer allocator.free(branch);
                git.removeWorktree(allocator, io, paths.root, wt_dir) catch {};
                git.deleteBranch(allocator, io, paths.root, branch) catch {};
                logger.info("[merger] cleaned old worktree {s} (terminal={}, stale={})", .{ entry.name, terminal, stale_unfinished });
            }
        }
    }

    // 2. Prune stale git worktree refs (worktree dir deleted but git still tracks it)
    {
        const prune = git.run(allocator, io, &.{ "git", "worktree", "prune" }, paths.root) catch null;
        if (prune) |r| {
            allocator.free(r.stdout);
            allocator.free(r.stderr);
        }
    }

    // 3. Delete orphaned bee/ branches (no corresponding worktree directory)
    pruneOrphanedBranches(cfg, paths, logger, io, worktree_base, allocator);
}

/// Delete bee/ branches whose worktree directory no longer exists.
/// Prevents branch accumulation across daemon restarts.
fn pruneOrphanedBranches(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    logger: *log_mod.Logger,
    io: Io,
    worktree_base: []const u8,
    allocator: std.mem.Allocator,
) void {
    const prefix = std.fmt.allocPrint(allocator, "bee/{s}/", .{cfg.project.name}) catch return;
    defer allocator.free(prefix);

    const result = git.run(allocator, io, &.{ "git", "branch", "--format=%(refname:short)" }, paths.root) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return;

    var pruned: u32 = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const branch = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (branch.len == 0) continue;
        if (!std.mem.startsWith(u8, branch, prefix)) continue;

        // Extract worktree dir name from branch: "bee/{project}/{dirname}" -> "{dirname}"
        const dirname = branch[prefix.len..];
        if (dirname.len == 0) continue;

        // Check if worktree dir still exists
        const wt_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_base, dirname }) catch continue;
        defer allocator.free(wt_dir);

        if (!fs.access(wt_dir)) {
            // Worktree gone — branch is orphaned
            git.deleteBranch(allocator, io, paths.root, branch) catch continue;
            pruned += 1;
        }
    }

    if (pruned > 0) {
        logger.info("[merger] pruned {d} orphaned bee/ branches", .{pruned});
    }
}

/// Ensure the main repo working tree is clean before merging.
/// Agents (QA, strategist) and build commands can leave dirty files.
fn ensureCleanWorktree(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) void {
    _ = cfg;
    const status = git.run(allocator, io, &.{ "git", "status", "--porcelain" }, paths.root) catch return;
    defer allocator.free(status.stdout);
    defer allocator.free(status.stderr);

    const trimmed = std.mem.trim(u8, status.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    // Count modified vs untracked
    var modified: u32 = 0;
    var untracked: u32 = 0;
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        if (line.len >= 2) {
            if (line[0] == '?' and line[1] == '?') {
                untracked += 1;
            } else {
                modified += 1;
            }
        }
    }

    logger.info("[merger] dirty working tree: {d} modified, {d} untracked files", .{ modified, untracked });

    // Stage and commit everything
    {
        const add = git.run(allocator, io, &.{ "git", "add", "-A" }, paths.root) catch return;
        allocator.free(add.stdout);
        allocator.free(add.stderr);
    }
    {
        const commit = git.run(allocator, io, &.{ "git", "commit", "-m", "Auto-commit: save agent changes before merge cycle" }, paths.root) catch return;
        allocator.free(commit.stdout);
        allocator.free(commit.stderr);
        if (commit.exit_code == 0) {
            logger.info("[merger] auto-committed dirty working tree", .{});
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

/// Parse a unix timestamp from a worktree directory name like "worker-3-20260315-163045".
/// Returns null if the name doesn't match the expected pattern.
fn parseWorktreeTimestamp(name: []const u8) ?u64 {
    // Name format: worker-{id}-{YYYYMMDD}-{HHMMSS}
    // Last 15 chars: "YYYYMMDD-HHMMSS"
    if (name.len < 15) return null;
    const tail = name[name.len - 15 ..];
    if (tail[8] != '-') return null;

    const year = std.fmt.parseInt(u32, tail[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, tail[4..6], 10) catch return null;
    const day = std.fmt.parseInt(u32, tail[6..8], 10) catch return null;
    const hour = std.fmt.parseInt(u32, tail[9..11], 10) catch return null;
    const minute = std.fmt.parseInt(u32, tail[11..13], 10) catch return null;
    const second = std.fmt.parseInt(u32, tail[13..15], 10) catch return null;

    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    // Convert to epoch seconds: days since 1970-01-01 * 86400 + time of day
    // Simplified Gregorian calendar calculation
    var y = year;
    var m = month;
    if (m <= 2) {
        y -= 1;
        m += 12;
    }
    // Days from epoch (1970-01-01) using a standard formula
    const epoch_days: i64 = @as(i64, @intCast(365 * y + y / 4 - y / 100 + y / 400 + (153 * (m - 3) + 2) / 5 + day - 719469));
    if (epoch_days < 0) return null;
    return @as(u64, @intCast(epoch_days)) * 86400 +
        @as(u64, hour) * 3600 +
        @as(u64, minute) * 60 +
        @as(u64, second);
}

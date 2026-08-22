const std = @import("std");
const Io = std.Io;
const fs = @import("fs.zig");

pub const GitResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
};

pub const MergeResult = union(enum) {
    success,
    conflict: struct { files: []const []const u8, stderr: []const u8 = "" },
};

pub const DiffStats = struct {
    files_changed: u32 = 0,
    insertions: u32 = 0,
    deletions: u32 = 0,
};

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8, cwd: []const u8) !GitResult {
    const result = try std.process.run(allocator, io, .{
        .argv = args,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    });

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
    };
}

pub fn createWorktree(allocator: std.mem.Allocator, io: Io, repo_path: []const u8, branch_name: []const u8, worktree_dir: []const u8, base_branch: []const u8, shallow: bool) !void {
    if (shallow) {
        const result = try run(allocator, io, &.{ "git", "worktree", "add", "--detach", worktree_dir, base_branch }, repo_path);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        if (result.exit_code != 0) {
            const result2 = try run(allocator, io, &.{ "git", "worktree", "add", "-b", branch_name, worktree_dir, base_branch }, repo_path);
            allocator.free(result2.stdout);
            allocator.free(result2.stderr);
            if (result2.exit_code != 0) return error.WorktreeCreateFailed;
            return;
        }
        const result3 = try run(allocator, io, &.{ "git", "checkout", "-b", branch_name }, worktree_dir);
        allocator.free(result3.stdout);
        allocator.free(result3.stderr);
        if (result3.exit_code != 0) return error.BranchCreateFailed;
    } else {
        const result = try run(allocator, io, &.{ "git", "worktree", "add", "-b", branch_name, worktree_dir, base_branch }, repo_path);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        if (result.exit_code != 0) return error.WorktreeCreateFailed;
    }
}

pub fn removeWorktree(allocator: std.mem.Allocator, io: Io, repo_path: []const u8, worktree_dir: []const u8) !void {
    const result = try run(allocator, io, &.{ "git", "worktree", "remove", "--force", worktree_dir }, repo_path);
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

pub fn deleteBranch(allocator: std.mem.Allocator, io: Io, repo_path: []const u8, branch_name: []const u8) !void {
    const result = try run(allocator, io, &.{ "git", "branch", "-D", branch_name }, repo_path);
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

/// Whether a worktree file reads as text: no NUL byte in the first 8 KiB, the
/// same heuristic git uses to call a file binary. Unreadable files are treated
/// as non-text, so a sweep never guesses.
fn looksTextual(allocator: std.mem.Allocator, worktree_dir: []const u8, rel_path: []const u8) bool {
    // A directory entry ("dir/") in porcelain output: let git expand it.
    if (std.mem.endsWith(u8, rel_path, "/")) return true;
    const full = std.fs.path.join(allocator, &.{ worktree_dir, rel_path }) catch return false;
    defer allocator.free(full);
    const data = fs.readFileAlloc(allocator, full, 8 * 1024) catch return false;
    defer allocator.free(data);
    return std.mem.indexOfScalar(u8, data, 0) == null;
}

/// Commit everything left in a worker's worktree, on its own branch.
///
/// Workers are told to commit and often simply don't: on chatplugin 2026-08-19,
/// 82 worker sessions produced 66 branches that were all 0 commits ahead, while
/// their worktrees held real edits (one had 635 insertions across 16 files, and
/// it compiled). The work was done, paid for, and then thrown away because the
/// merger only ever sees commits. Sweeping the tree turns that silent loss into
/// a candidate the merger can judge — and reject on its merits if it is bad.
///
/// Returns true when a commit was actually created (a clean tree makes none).
pub fn commitLeftovers(allocator: std.mem.Allocator, io: Io, worktree_dir: []const u8, task_name: []const u8) !bool {
    const status = try run(allocator, io, &.{ "git", "status", "--porcelain" }, worktree_dir);
    defer allocator.free(status.stdout);
    defer allocator.free(status.stderr);
    if (std.mem.trim(u8, status.stdout, &std.ascii.whitespace).len == 0) return false;

    // Stage tracked edits, plus untracked TEXT files only. A worker's real work
    // is source; the untracked binaries left in a worktree are artifacts whose
    // .gitignore has not caught up (the first sweep on chatplugin committed
    // nothing but SQLite WAL/SHM sidecars, which would have cost a merger
    // review to judge as noise).
    {
        const add = try run(allocator, io, &.{ "git", "add", "-u" }, worktree_dir);
        defer allocator.free(add.stdout);
        defer allocator.free(add.stderr);
        if (add.exit_code != 0) return false;
    }
    var lines = std.mem.splitScalar(u8, status.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        if (!std.mem.startsWith(u8, line, "??")) continue;
        const path = std.mem.trim(u8, line[2..], &std.ascii.whitespace);
        if (path.len == 0) continue;
        // Our own session bookkeeping, written into the worktree — never the
        // project's files, and a sweep once carried them onto main.
        if (std.mem.eql(u8, path, ".done") or std.mem.eql(u8, path, ".session-id")) continue;
        if (!looksTextual(allocator, worktree_dir, path)) continue;
        const add_one = run(allocator, io, &.{ "git", "add", "--", path }, worktree_dir) catch continue;
        allocator.free(add_one.stdout);
        allocator.free(add_one.stderr);
    }

    // Nothing worth a commit once the artifacts are excluded.
    {
        const staged = try run(allocator, io, &.{ "git", "diff", "--cached", "--name-only" }, worktree_dir);
        defer allocator.free(staged.stdout);
        defer allocator.free(staged.stderr);
        if (std.mem.trim(u8, staged.stdout, &std.ascii.whitespace).len == 0) return false;
    }

    // The message says who made it, so a human reading `git log` can tell a
    // swept commit from one the worker chose to make.
    const message = try std.fmt.allocPrint(allocator, "{s}\n\nSwept by bees: the worker left this uncommitted when its session ended.", .{task_name});
    defer allocator.free(message);

    const commit = try run(allocator, io, &.{ "git", "commit", "-m", message }, worktree_dir);
    defer allocator.free(commit.stdout);
    defer allocator.free(commit.stderr);
    return commit.exit_code == 0;
}

pub fn getCommitsAhead(allocator: std.mem.Allocator, io: Io, repo_path: []const u8, branch: []const u8, base: []const u8) !u32 {
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, branch });
    defer allocator.free(range);
    const result = try run(allocator, io, &.{ "git", "rev-list", "--count", range }, repo_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return 0;
    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    return std.fmt.parseInt(u32, trimmed, 10) catch 0;
}

pub fn getDiff(allocator: std.mem.Allocator, io: Io, repo_path: []const u8, branch: []const u8, base: []const u8) ![]const u8 {
    const range = try std.fmt.allocPrint(allocator, "{s}...{s}", .{ base, branch });
    defer allocator.free(range);
    const result = try run(allocator, io, &.{ "git", "diff", range }, repo_path);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        return error.DiffFailed;
    }
    return result.stdout;
}

pub fn tryMerge(allocator: std.mem.Allocator, io: Io, repo_path: []const u8, branch: []const u8) !MergeResult {
    const result = try run(allocator, io, &.{ "git", "merge", "--no-edit", branch }, repo_path);
    defer allocator.free(result.stdout);

    if (result.exit_code == 0) {
        allocator.free(result.stderr);
        return .success;
    }

    // Keep merge stderr for diagnostics (caller must free)
    const merge_stderr = result.stderr;

    const conflict_result = try run(allocator, io, &.{ "git", "diff", "--name-only", "--diff-filter=U" }, repo_path);
    defer allocator.free(conflict_result.stderr);

    if (conflict_result.exit_code == 0 and conflict_result.stdout.len > 0) {
        var files: std.ArrayList([]const u8) = .empty;
        var iter = std.mem.splitScalar(u8, std.mem.trim(u8, conflict_result.stdout, &std.ascii.whitespace), '\n');
        while (iter.next()) |file| {
            if (file.len > 0) try files.append(allocator, file);
        }
        return .{ .conflict = .{ .files = try files.toOwnedSlice(allocator), .stderr = merge_stderr } };
    }

    allocator.free(conflict_result.stdout);
    return .{ .conflict = .{ .files = &.{}, .stderr = merge_stderr } };
}

pub fn abortMerge(allocator: std.mem.Allocator, io: Io, repo_path: []const u8) !void {
    const result = try run(allocator, io, &.{ "git", "merge", "--abort" }, repo_path);
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

pub fn commitMerge(allocator: std.mem.Allocator, io: Io, repo_path: []const u8) !void {
    const result = try run(allocator, io, &.{ "git", "commit", "--no-edit" }, repo_path);
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CommitFailed;
}

pub fn resetHard(allocator: std.mem.Allocator, io: Io, repo_path: []const u8, ref: []const u8) !void {
    const result = try run(allocator, io, &.{ "git", "reset", "--hard", ref }, repo_path);
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

pub fn getCurrentHead(allocator: std.mem.Allocator, io: Io, repo_path: []const u8) ![]const u8 {
    return revParse(allocator, io, repo_path, "HEAD");
}

/// Resolve any ref (branch, tag, HEAD) to its commit hash. Caller owns the result.
pub fn revParse(allocator: std.mem.Allocator, io: Io, repo_path: []const u8, ref: []const u8) ![]const u8 {
    const result = try run(allocator, io, &.{ "git", "rev-parse", ref }, repo_path);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        return error.HeadNotFound;
    }
    // Dupe the trimmed slice so callers can safely free the returned pointer.
    // result.stdout is freed here; the caller owns the dupe.
    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return owned;
}

/// True when `ancestor` is an ancestor of (or equal to) `descendant`.
pub fn isAncestor(allocator: std.mem.Allocator, io: Io, repo_path: []const u8, ancestor: []const u8, descendant: []const u8) bool {
    const result = run(allocator, io, &.{ "git", "merge-base", "--is-ancestor", ancestor, descendant }, repo_path) catch return false;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return result.exit_code == 0;
}

pub fn getChangedFiles(allocator: std.mem.Allocator, io: Io, repo_path: []const u8, old_ref: []const u8, new_ref: []const u8) ![]const u8 {
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ old_ref, new_ref });
    defer allocator.free(range);
    const result = try run(allocator, io, &.{ "git", "diff", "--name-only", range }, repo_path);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        return error.DiffFailed;
    }
    return result.stdout;
}

/// Strip the ref namespace from a symbolic-ref result, preserving branch names
/// that themselves contain slashes — e.g. "feat/x" from "refs/heads/feat/x", or
/// "feat/x" from "refs/remotes/origin/feat/x". Splitting on the LAST slash (the
/// old behavior) mangled slashed branch names into a nonexistent ref.
fn stripRefPrefix(ref: []const u8) []const u8 {
    if (std.mem.startsWith(u8, ref, "refs/heads/")) return ref["refs/heads/".len..];
    if (std.mem.startsWith(u8, ref, "refs/remotes/")) {
        const rest = ref["refs/remotes/".len..];
        // Drop the remote name (first segment); keep the branch path verbatim.
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| return rest[slash + 1 ..];
        return rest;
    }
    if (std.mem.lastIndexOfScalar(u8, ref, '/')) |pos| return ref[pos + 1 ..];
    return ref;
}

pub fn getDefaultBranch(allocator: std.mem.Allocator, io: Io, repo_path: []const u8) ?[]const u8 {
    // Try remote HEAD first (works when origin is configured)
    const refs = [_][]const u8{
        "refs/remotes/origin/HEAD",
        "HEAD", // fallback: current branch (works even in empty repos)
    };
    for (refs) |ref| {
        const result = run(allocator, io, &.{ "git", "symbolic-ref", ref }, repo_path) catch continue;
        defer allocator.free(result.stderr);
        if (result.exit_code == 0) {
            const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
            const name = stripRefPrefix(trimmed);
            if (name.len > 0) {
                const branch = allocator.dupe(u8, name) catch {
                    allocator.free(result.stdout);
                    continue;
                };
                allocator.free(result.stdout);
                return branch;
            }
        }
        allocator.free(result.stdout);
    }

    // Last resort: check if 'main' or 'master' ref exists (requires commits)
    const r2 = run(allocator, io, &.{ "git", "rev-parse", "--verify", "main" }, repo_path) catch return null;
    allocator.free(r2.stdout);
    allocator.free(r2.stderr);
    if (r2.exit_code == 0) return "main";

    const r3 = run(allocator, io, &.{ "git", "rev-parse", "--verify", "master" }, repo_path) catch return null;
    allocator.free(r3.stdout);
    allocator.free(r3.stderr);
    if (r3.exit_code == 0) return "master";

    return null;
}

pub fn isGitRepo(allocator: std.mem.Allocator, io: Io, path: []const u8) bool {
    const result = run(allocator, io, &.{ "git", "rev-parse", "--git-dir" }, path) catch return false;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return result.exit_code == 0;
}

test "stripRefPrefix preserves slashed branch names" {
    try std.testing.expectEqualStrings("main", stripRefPrefix("refs/heads/main"));
    try std.testing.expectEqualStrings("feat/internal-actor-policy", stripRefPrefix("refs/heads/feat/internal-actor-policy"));
    try std.testing.expectEqualStrings("main", stripRefPrefix("refs/remotes/origin/main"));
    try std.testing.expectEqualStrings("feat/x", stripRefPrefix("refs/remotes/origin/feat/x"));
}

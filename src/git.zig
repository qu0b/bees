const std = @import("std");
const Io = std.Io;

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
    const result = try run(allocator, io, &.{ "git", "rev-parse", "HEAD" }, repo_path);
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
            if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |pos| {
                const branch = allocator.dupe(u8, trimmed[pos + 1 ..]) catch {
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

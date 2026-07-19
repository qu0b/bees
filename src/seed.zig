//! Intelligent seed session builder — pre-loads project files into a shared
//! conversation prefix for cross-role prompt caching.
//!
//! The seed is a synthetic JSONL session file written to ~/.claude/projects/.
//! Non-worker roles fork from it via `--resume <uuid> --fork-session`, sharing
//! a cached message prefix. A cheap haiku call selects relevant files based on
//! current tasks, merged with configurable always-include lists.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const fs = @import("fs.zig");
const git = @import("git.zig");
const config_mod = @import("config.zig");
const tasks_mod = @import("tasks.zig");
const store_mod = @import("store.zig");
const backend_mod = @import("backend.zig");

/// Binary file extensions to always exclude from context.
const binary_extensions = [_][]const u8{
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".bmp", ".svg", ".webp",
    ".woff", ".woff2", ".ttf", ".eot", ".otf",
    ".pdf", ".zip", ".tar", ".gz", ".bz2", ".xz", ".7z",
    ".lock", ".min.js", ".min.css",
    ".wasm", ".pyc", ".o", ".a", ".so", ".dylib", ".dll",
    ".mp3", ".mp4", ".wav", ".avi", ".mov",
    ".sqlite", ".db", ".lmdb",
};

/// Result of the seed build process.
pub const SeedResult = struct {
    /// Deterministic UUID for the seed session. Null if seed build failed.
    uuid: ?[]const u8,
    /// Markdown blob of pre-loaded files (for workers who can't use the seed).
    context_blob: ?[]const u8,
};

/// Build a seed session and context blob for the current cycle.
///
/// 1. Selects relevant files via haiku + config
/// 2. Reads them into a markdown blob
/// 3. Writes a synthetic JSONL session to ~/.claude/projects/
/// 4. Returns the seed UUID and context blob
pub fn buildSeed(
    project_root: []const u8,
    project_name: []const u8,
    cache_cfg: config_mod.Config.Cache,
    store: *store_mod.Store,
    allocator: std.mem.Allocator,
    io: Io,
) SeedResult {
    if (!cache_cfg.shared_context) return .{ .uuid = null, .context_blob = null };

    // Select files via haiku + always_include
    const files = selectFiles(project_root, cache_cfg, store, allocator, io);
    if (files.len == 0) return .{ .uuid = null, .context_blob = null };

    // Build the markdown blob from selected files
    const blob = buildContextBlob(project_root, files, cache_cfg.max_bytes, allocator) orelse
        return .{ .uuid = null, .context_blob = null };

    // Generate deterministic UUID from project name
    const uuid = deterministicUuid(project_name);

    // Write seed JSONL
    const wrote = writeSeedJsonl(project_root, &uuid, blob, allocator, io);

    // `uuid` is a stack-local [36]u8; the returned slice must own heap memory
    // or it would dangle once this frame returns (the daemon keeps it for its
    // whole lifetime as the --resume argument of every seeded session).
    const owned_uuid: ?[]const u8 = if (wrote) (allocator.dupe(u8, &uuid) catch null) else null;
    assert(owned_uuid == null or owned_uuid.?.len == 36);

    return .{
        .uuid = owned_uuid,
        .context_blob = blob,
    };
}

/// Build a markdown blob of file contents from a list of paths.
/// Returns null on failure.
pub fn buildContextBlob(
    project_root: []const u8,
    file_paths: []const []const u8,
    max_bytes: u32,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    buf.appendSlice(allocator, "Here is the project source code for context. Review it carefully to understand the codebase.\n\n") catch return null;

    for (file_paths) |rel_path| {
        // Check budget before reading
        if (buf.items.len >= max_bytes) break;

        const full_path = std.fs.path.join(allocator, &.{ project_root, rel_path }) catch continue;
        defer allocator.free(full_path);

        const content = fs.readFileAlloc(allocator, full_path, max_bytes) catch continue;
        defer allocator.free(content);

        // Skip empty files
        if (content.len == 0) continue;

        // Check if adding this file would exceed budget
        // Header: "### path\n```ext\n" + content + "\n```\n\n" ≈ path.len + content.len + 20
        const overhead = rel_path.len + 20;
        if (buf.items.len + overhead + content.len > max_bytes) {
            // Try to fit a truncated version if file is large
            if (content.len > 4096) continue;
            // Small file — skip if it still doesn't fit
            if (buf.items.len + overhead + content.len > max_bytes) continue;
        }

        // Detect language from extension
        const ext = extensionOf(rel_path);

        buf.appendSlice(allocator, "### ") catch continue;
        buf.appendSlice(allocator, rel_path) catch continue;
        buf.appendSlice(allocator, "\n```") catch continue;
        if (ext.len > 0) buf.appendSlice(allocator, ext) catch {};
        buf.append(allocator, '\n') catch continue;
        buf.appendSlice(allocator, content) catch continue;
        // Ensure trailing newline before closing fence
        if (content.len > 0 and content[content.len - 1] != '\n') {
            buf.append(allocator, '\n') catch {};
        }
        buf.appendSlice(allocator, "```\n\n") catch continue;
    }

    if (buf.items.len < 100) return null; // Nothing meaningful loaded
    return buf.toOwnedSlice(allocator) catch null;
}

/// Read per-role context_files and format as markdown code blocks.
pub fn readRoleContextFiles(
    project_root: []const u8,
    context_files: []const []const u8,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    if (context_files.len == 0) return null;

    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(allocator, "\n## Role-Specific Context Files\n\n") catch return null;

    for (context_files) |rel_path| {
        const full_path = std.fs.path.join(allocator, &.{ project_root, rel_path }) catch continue;
        defer allocator.free(full_path);

        const content = fs.readFileAlloc(allocator, full_path, 256 * 1024) catch continue;
        defer allocator.free(content);

        if (content.len == 0) continue;

        const ext = extensionOf(rel_path);
        buf.appendSlice(allocator, "### ") catch continue;
        buf.appendSlice(allocator, rel_path) catch continue;
        buf.appendSlice(allocator, "\n```") catch continue;
        if (ext.len > 0) buf.appendSlice(allocator, ext) catch {};
        buf.append(allocator, '\n') catch continue;
        buf.appendSlice(allocator, content) catch continue;
        if (content.len > 0 and content[content.len - 1] != '\n') {
            buf.append(allocator, '\n') catch {};
        }
        buf.appendSlice(allocator, "```\n\n") catch continue;
    }

    if (buf.items.len < 40) return null;
    return buf.toOwnedSlice(allocator) catch null;
}

// ============================================================
// File selection
// ============================================================

/// Select relevant files using haiku AI + always_include config.
fn selectFiles(
    project_root: []const u8,
    cache_cfg: config_mod.Config.Cache,
    store: *store_mod.Store,
    allocator: std.mem.Allocator,
    io: Io,
) []const []const u8 {
    // Get tracked files from git
    const git_files = getTrackedFiles(project_root, allocator, io) orelse return &.{};

    // Filter out binary extensions and excluded prefixes
    var filtered: std.ArrayList([]const u8) = .empty;
    for (git_files) |path| {
        if (isBinaryPath(path)) continue;
        if (isExcluded(path, cache_cfg.always_exclude)) continue;
        filtered.append(allocator, path) catch continue;
    }

    // Load tasks for haiku context
    const tasks = loadTaskDescriptions(store, allocator);

    // Ask haiku to select relevant files
    const haiku_selected = if (tasks.len > 0 and filtered.items.len > 0)
        askHaikuForFiles(project_root, filtered.items, tasks, allocator, io)
    else
        null;

    // Merge: haiku selection + always_include
    var result: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(allocator);

    // Always-include first (guaranteed)
    for (cache_cfg.always_include) |path| {
        if (seen.contains(path)) continue;
        seen.put(path, {}) catch continue;
        result.append(allocator, path) catch continue;
    }

    // Haiku-selected files
    if (haiku_selected) |selected| {
        for (selected) |path| {
            if (seen.contains(path)) continue;
            if (isExcluded(path, cache_cfg.always_exclude)) continue;
            seen.put(path, {}) catch continue;
            result.append(allocator, path) catch continue;
        }
    } else {
        // Haiku failed — fall back to all filtered files (up to a reasonable limit)
        for (filtered.items) |path| {
            if (result.items.len >= 100) break;
            if (seen.contains(path)) continue;
            seen.put(path, {}) catch continue;
            result.append(allocator, path) catch continue;
        }
    }

    return result.toOwnedSlice(allocator) catch &.{};
}

/// Run `git ls-files` and return sorted list of tracked file paths.
fn getTrackedFiles(project_root: []const u8, allocator: std.mem.Allocator, io: Io) ?[]const []const u8 {
    const result = git.run(allocator, io, &.{ "git", "ls-files" }, project_root) catch return null;
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        return null;
    }

    // Split stdout into lines
    var lines: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, result.stdout, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        lines.append(allocator, trimmed) catch continue;
    }

    return lines.toOwnedSlice(allocator) catch null;
}

/// Load task names and truncated prompts from LMDB.
fn loadTaskDescriptions(store: *store_mod.Store, allocator: std.mem.Allocator) []const u8 {
    var buf: std.ArrayList(u8) = .empty;

    const txn = store.beginReadTxn() catch return "";
    defer store_mod.Store.abortTxn(txn);

    var iter = store.iterTasks(txn) catch return "";
    defer iter.close();

    var count: u32 = 0;
    while (iter.next()) |entry| {
        if (count >= 20) break;
        if (entry.view.header.status != .active) continue;

        buf.appendSlice(allocator, "- ") catch continue;
        buf.appendSlice(allocator, entry.name) catch continue;

        // Truncate prompt to first 200 chars for haiku
        if (entry.view.prompt.len > 0) {
            buf.appendSlice(allocator, ": ") catch continue;
            const preview_len = @min(entry.view.prompt.len, 200);
            buf.appendSlice(allocator, entry.view.prompt[0..preview_len]) catch continue;
            if (entry.view.prompt.len > 200) {
                buf.appendSlice(allocator, "...") catch continue;
            }
        }
        buf.append(allocator, '\n') catch continue;
        count += 1;
    }

    return buf.toOwnedSlice(allocator) catch "";
}

/// Ask haiku to select relevant files given tasks and file list.
fn askHaikuForFiles(
    project_root: []const u8,
    file_list: []const []const u8,
    task_descriptions: []const u8,
    allocator: std.mem.Allocator,
    io: Io,
) ?[]const []const u8 {
    // Build the file list string
    var files_buf: std.ArrayList(u8) = .empty;
    for (file_list) |path| {
        files_buf.appendSlice(allocator, path) catch continue;
        files_buf.append(allocator, '\n') catch continue;
    }
    const files_str = files_buf.toOwnedSlice(allocator) catch return null;
    defer allocator.free(files_str);

    // Build prompt
    const prompt = std.fmt.allocPrint(allocator,
        \\You are a code analysis assistant. Given these development tasks and the project's file list, select the source files most relevant for understanding and working on these tasks.
        \\
        \\## Current Tasks
        \\{s}
        \\## Source Files
        \\{s}
        \\## Instructions
        \\Return ONLY file paths, one per line. Include:
        \\1. Files directly related to the tasks above
        \\2. Core infrastructure files (entry points, config, types, shared utilities)
        \\3. Schema and interface definition files
        \\Maximum 80 files. Prioritize by relevance to current tasks.
    , .{ task_descriptions, files_str }) catch return null;
    defer allocator.free(prompt);

    // Spawn haiku via Claude CLI — simple text-in, text-out
    var env_map = backend_mod.buildFilteredEnvMap(allocator);
    defer env_map.deinit();

    const result = std.process.run(allocator, io, .{
        .argv = &.{
            "claude", "-p",
            "--model", "haiku",
            "--effort",  "low",
            "--max-turns", "1",
            "--max-budget-usd", "0.50",
            "--no-session-persistence",
            "--output-format", "text",
            "--permission-mode", "plan",
            prompt,
        },
        .cwd = .{ .path = project_root },
        .environ_map = &env_map,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(8 * 1024),
    }) catch return null;
    defer allocator.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => return null,
    };
    if (exit_code != 0) {
        allocator.free(result.stdout);
        return null;
    }

    // Build a set of valid files for validation
    var valid = std.StringHashMap(void).init(allocator);
    for (file_list) |path| valid.put(path, {}) catch {};

    // Parse output: one file path per line, validate against git ls-files
    var selected: std.ArrayList([]const u8) = .empty;
    var line_iter = std.mem.splitScalar(u8, result.stdout, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        // Strip leading "- " or "* " from markdown lists
        const clean = if (trimmed.len > 2 and (trimmed[0] == '-' or trimmed[0] == '*') and trimmed[1] == ' ')
            std.mem.trim(u8, trimmed[2..], &std.ascii.whitespace)
        else
            trimmed;
        // Strip backticks
        const no_ticks = std.mem.trim(u8, clean, "`");
        if (valid.contains(no_ticks)) {
            selected.append(allocator, no_ticks) catch continue;
        }
    }

    if (selected.items.len == 0) return null;
    return selected.toOwnedSlice(allocator) catch null;
}

// ============================================================
// JSONL seed writer
// ============================================================

/// Write the synthetic seed JSONL session file.
fn writeSeedJsonl(
    project_root: []const u8,
    uuid: []const u8,
    blob: []const u8,
    allocator: std.mem.Allocator,
    io: Io,
) bool {
    _ = io;

    // Compute session directory: ~/.claude/projects/-{cwd-dashed}/
    const home_ptr = std.c.getenv("HOME") orelse return false;
    const home = std.mem.sliceTo(home_ptr, 0);
    const session_dir = computeSessionDir(home, project_root, allocator) orelse return false;
    defer allocator.free(session_dir);

    // Ensure directory exists
    fs.makePath(session_dir) catch return false;

    // Build JSONL file path
    const jsonl_path = std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ session_dir, uuid }) catch return false;
    defer allocator.free(jsonl_path);

    // Generate UUIDs for messages
    const msg1_uuid = deterministicMsgUuid(uuid, 1);
    const msg2_uuid = deterministicMsgUuid(uuid, 2);

    // Get current timestamp
    var ts_buf: [32]u8 = undefined;
    const timestamp = formatTimestamp(&ts_buf);

    // Build JSONL content
    var out: std.ArrayList(u8) = .empty;

    // Line 1: permission mode
    appendJsonLine(&out, allocator,
        \\{{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"{s}"}}
    , .{uuid});
    out.append(allocator, '\n') catch {};

    // Line 2: user message with file contents
    out.appendSlice(allocator,
        \\{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"
    ) catch return false;
    // JSON-escape the blob content
    appendJsonEscaped(&out, blob, allocator);
    out.appendSlice(allocator,
        \\"},"uuid":"
    ) catch return false;
    out.appendSlice(allocator, &msg1_uuid) catch return false;
    out.appendSlice(allocator,
        \\","timestamp":"
    ) catch return false;
    out.appendSlice(allocator, timestamp) catch return false;
    out.appendSlice(allocator,
        \\","userType":"external","entrypoint":"cli","cwd":"
    ) catch return false;
    appendJsonEscaped(&out, project_root, allocator);
    out.appendSlice(allocator,
        \\","sessionId":"
    ) catch return false;
    out.appendSlice(allocator, uuid) catch return false;
    out.appendSlice(allocator,
        \\","version":"2.1.96"}
    ) catch return false;
    out.append(allocator, '\n') catch {};

    // Line 3: assistant acknowledgment
    out.appendSlice(allocator,
        \\{"parentUuid":"
    ) catch return false;
    out.appendSlice(allocator, &msg1_uuid) catch return false;
    out.appendSlice(allocator,
        \\","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I've reviewed the project source code and understand the codebase structure, architecture, and implementation details. I'm ready to work on tasks."}],"model":"claude-sonnet-4-5-20241022","id":"synth_msg_001","stop_reason":"end_turn","usage":{"input_tokens":0,"output_tokens":25}},"requestId":"synth_req_001","uuid":"
    ) catch return false;
    out.appendSlice(allocator, &msg2_uuid) catch return false;
    out.appendSlice(allocator,
        \\","timestamp":"
    ) catch return false;
    out.appendSlice(allocator, timestamp) catch return false;
    out.appendSlice(allocator,
        \\","userType":"external","entrypoint":"cli","cwd":"
    ) catch return false;
    appendJsonEscaped(&out, project_root, allocator);
    out.appendSlice(allocator,
        \\","sessionId":"
    ) catch return false;
    out.appendSlice(allocator, uuid) catch return false;
    out.appendSlice(allocator,
        \\","version":"2.1.96"}
    ) catch return false;
    out.append(allocator, '\n') catch {};

    // Write to file
    const jsonl_file = fs.createFile(jsonl_path, .{}) catch return false;
    fs.writeFile(jsonl_file, out.items) catch {
        fs.closeFile(jsonl_file);
        return false;
    };
    fs.closeFile(jsonl_file);
    return true;
}

/// Compute `~/.claude/projects/-{cwd-dashed}/` from project root.
/// Convention: replace each `/` with `-`. Leading `/` becomes the prefix dash.
/// E.g., `/home/ubuntu/agents-swarm` → `-home-ubuntu-agents-swarm`
fn computeSessionDir(home: []const u8, project_root: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    var dashed: std.ArrayList(u8) = .empty;
    for (project_root) |ch| {
        dashed.append(allocator, if (ch == '/') @as(u8, '-') else ch) catch return null;
    }
    // Remove trailing dash if root ended with /
    if (dashed.items.len > 1 and dashed.items[dashed.items.len - 1] == '-') {
        dashed.items.len -= 1;
    }
    const dashed_name = dashed.toOwnedSlice(allocator) catch return null;
    defer allocator.free(dashed_name);

    return std.fmt.allocPrint(allocator, "{s}/.claude/projects/{s}", .{ home, dashed_name }) catch null;
}

// ============================================================
// Helpers
// ============================================================

/// Generate a deterministic UUID v4 from a project name.
/// Uses a simple hash — not cryptographically random, but stable.
fn deterministicUuid(project_name: []const u8) [36]u8 {
    var hasher = std.hash.Fnv1a_128.init();
    hasher.update("bees-seed-v1:");
    hasher.update(project_name);
    const hash = hasher.final();

    // Format as UUID v4: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
    var uuid: [36]u8 = undefined;
    const bytes: [16]u8 = @bitCast(hash);
    const hex = "0123456789abcdef";

    var out_i: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            uuid[out_i] = '-';
            out_i += 1;
        }
        uuid[out_i] = hex[b >> 4];
        uuid[out_i + 1] = hex[b & 0x0f];
        out_i += 2;
    }

    // Set version (4) and variant (8/9/a/b)
    uuid[14] = '4'; // version
    uuid[19] = hex[(bytes[8] & 0x3) | 0x8]; // variant

    return uuid;
}

/// Generate a deterministic sub-UUID for messages within the seed.
fn deterministicMsgUuid(seed_uuid: []const u8, index: u8) [36]u8 {
    var hasher = std.hash.Fnv1a_128.init();
    hasher.update(seed_uuid);
    hasher.update(&.{index});
    const hash = hasher.final();

    var uuid: [36]u8 = undefined;
    const bytes: [16]u8 = @bitCast(hash);
    const hex = "0123456789abcdef";

    var out_i: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            uuid[out_i] = '-';
            out_i += 1;
        }
        uuid[out_i] = hex[b >> 4];
        uuid[out_i + 1] = hex[b & 0x0f];
        out_i += 2;
    }
    uuid[14] = '4';
    uuid[19] = hex[(bytes[8] & 0x3) | 0x8];
    return uuid;
}

/// Format current time as ISO-8601 timestamp.
fn formatTimestamp(buf: *[32]u8) []const u8 {
    const now = fs.timestamp();
    const es = std.time.epoch.EpochSeconds{ .secs = now };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        yd.year,
        md.month.numeric(),
        @as(u6, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "2026-01-01T00:00:00.000Z";
}

/// Append a JSON-escaped string to the buffer (no surrounding quotes).
fn appendJsonEscaped(buf: *std.ArrayList(u8), text: []const u8, allocator: std.mem.Allocator) void {
    for (text) |ch| {
        switch (ch) {
            '"' => buf.appendSlice(allocator, "\\\"") catch {},
            '\\' => buf.appendSlice(allocator, "\\\\") catch {},
            '\n' => buf.appendSlice(allocator, "\\n") catch {},
            '\r' => buf.appendSlice(allocator, "\\r") catch {},
            '\t' => buf.appendSlice(allocator, "\\t") catch {},
            else => {
                if (ch < 0x20) {
                    // Control character — encode as \u00XX
                    const hex = "0123456789abcdef";
                    buf.appendSlice(allocator, "\\u00") catch {};
                    buf.append(allocator, hex[ch >> 4]) catch {};
                    buf.append(allocator, hex[ch & 0x0f]) catch {};
                } else {
                    buf.append(allocator, ch) catch {};
                }
            },
        }
    }
}

/// Append a formatted line to the output buffer.
fn appendJsonLine(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const line = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(line);
    buf.appendSlice(allocator, line) catch {};
}

/// Check if a file path has a binary extension.
fn isBinaryPath(path: []const u8) bool {
    for (binary_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

/// Check if a path matches any exclude prefix.
fn isExcluded(path: []const u8, excludes: []const []const u8) bool {
    for (excludes) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

/// Extract file extension without the dot (e.g., "zig" from "src/main.zig").
fn extensionOf(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "";
    return path[dot + 1 ..];
}

// ============================================================
// Tests
// ============================================================

test "deterministicUuid is stable" {
    const uuid1 = deterministicUuid("test-project");
    const uuid2 = deterministicUuid("test-project");
    try std.testing.expectEqualStrings(&uuid1, &uuid2);

    // Different project → different UUID
    const uuid3 = deterministicUuid("other-project");
    try std.testing.expect(!std.mem.eql(u8, &uuid1, &uuid3));
}

test "deterministicUuid format" {
    const uuid = deterministicUuid("test");
    // Check dashes at positions 8, 13, 18, 23
    try std.testing.expectEqual(@as(u8, '-'), uuid[8]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[13]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[18]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[23]);
    // Check version 4
    try std.testing.expectEqual(@as(u8, '4'), uuid[14]);
}

test "isBinaryPath" {
    try std.testing.expect(isBinaryPath("image.png"));
    try std.testing.expect(isBinaryPath("font.woff2"));
    try std.testing.expect(isBinaryPath("app.min.js"));
    try std.testing.expect(!isBinaryPath("src/main.zig"));
    try std.testing.expect(!isBinaryPath("config.json"));
}

test "isExcluded" {
    const excludes = &[_][]const u8{ "vendor/", "node_modules/" };
    try std.testing.expect(isExcluded("vendor/lmdb/mdb.c", excludes));
    try std.testing.expect(isExcluded("node_modules/foo/bar.js", excludes));
    try std.testing.expect(!isExcluded("src/main.zig", excludes));
}

test "extensionOf" {
    try std.testing.expectEqualStrings("zig", extensionOf("src/main.zig"));
    try std.testing.expectEqualStrings("json", extensionOf("config.json"));
    try std.testing.expectEqualStrings("", extensionOf("Makefile"));
}

test "appendJsonEscaped" {
    var buf: std.ArrayList(u8) = .empty;
    appendJsonEscaped(&buf, "hello \"world\"\nline2\\end", std.testing.allocator);
    defer buf.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nline2\\\\end", buf.items);
}

test "computeSessionDir" {
    const dir = computeSessionDir("/home/ubuntu", "/home/ubuntu/agents-swarm", std.testing.allocator) orelse unreachable;
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/home/ubuntu/.claude/projects/-home-ubuntu-agents-swarm", dir);
}

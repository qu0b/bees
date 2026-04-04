//! Knowledge base — persistent institutional memory for the agent swarm.
//!
//! Agents write knowledge by including `## Knowledge Updates` in their output.
//! The executor parses this section and calls applyUpdates() to write files
//! and update the LMDB index. Agents read knowledge via the context builder,
//! which loads the index, filters by role-declared tags, and injects relevant
//! pages into the prompt.
//!
//! Storage model:
//!   - Markdown files in .bees/knowledge/ organized by category
//!   - LMDB `kb:index` meta key holds a compact JSON index for fast lookups
//!   - _index.md is a human-readable catalog (regenerated from LMDB index)
//!   - _log.md is an append-only chronological record of changes

const std = @import("std");
const assert = std.debug.assert;
const store_mod = @import("store.zig");
const config_mod = @import("config.zig");
const fs = @import("fs.zig");

const index_key = "kb:index";
const max_index_size = 64 * 1024;
const max_page_size = 32 * 1024;

// ============================================================
// Types
// ============================================================

pub const PageMeta = struct {
    path: []const u8,
    tags: []const []const u8,
    updated: u64,
    size: u32,
    summary: []const u8,
};

pub const UpdateOp = enum { create, update, append };

pub const Update = struct {
    op: UpdateOp,
    path: []const u8,
    tags: []const []const u8,
    content: []const u8,
};

// ============================================================
// Read path — load index and build context for agent prompts
// ============================================================

/// Load the knowledge index from LMDB meta. Returns null if no index exists.
/// The returned slices point into allocator-owned memory.
pub fn loadIndex(store: *store_mod.Store, txn: store_mod.ReadTxn, allocator: std.mem.Allocator) ?[]PageMeta {
    const t = txn orelse return null;
    const raw = (store.getMeta(t, index_key) catch return null) orelse return null;
    if (raw.len < 2) return null;

    // Copy out of mmap before txn ends
    const owned = allocator.dupe(u8, raw) catch return null;
    return parseIndex(owned, allocator);
}

/// Build a context string from knowledge pages matching the given tags.
/// Reads files from disk, respects budget. Returns null if nothing matches.
pub fn buildContext(
    knowledge_dir: []const u8,
    index: []const PageMeta,
    tags: []const []const u8,
    budget: u32,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    if (index.len == 0) return null;

    // Filter by tags
    var matched: std.ArrayList(PageMeta) = .empty;
    defer matched.deinit(allocator);

    for (index) |page| {
        if (matchesTags(page, tags)) {
            matched.append(allocator, page) catch continue;
        }
    }
    if (matched.items.len == 0) return null;

    // Sort by recency (most recent first)
    std.mem.sort(PageMeta, matched.items, {}, struct {
        fn lessThan(_: void, a: PageMeta, b: PageMeta) bool {
            return a.updated > b.updated;
        }
    }.lessThan);

    // Assemble context within budget
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(allocator, "\n\n## Project Knowledge Base\n") catch return null;

    var remaining: u32 = budget;
    var overflow: std.ArrayList(PageMeta) = .empty;
    defer overflow.deinit(allocator);

    for (matched.items) |page| {
        const file_path = std.fs.path.join(allocator, &.{ knowledge_dir, page.path }) catch continue;
        defer allocator.free(file_path);

        const content = fs.readFileAlloc(allocator, file_path, max_page_size) catch continue;
        defer allocator.free(content);

        if (content.len == 0) continue;

        // Check if fits in budget (header + content + padding)
        const overhead = 6 + page.path.len + 1; // "\n### " + path + "\n"
        const needed: u32 = @intCast(@min(overhead + content.len, std.math.maxInt(u32)));
        if (needed > remaining) {
            overflow.append(allocator, page) catch continue;
            continue;
        }

        buf.appendSlice(allocator, "\n### ") catch continue;
        buf.appendSlice(allocator, page.path) catch continue;
        buf.appendSlice(allocator, "\n") catch continue;
        buf.appendSlice(allocator, content) catch continue;
        if (content[content.len - 1] != '\n') buf.append(allocator, '\n') catch {};

        remaining -|= needed;
    }

    // Overflow pages get summary-only injection
    if (overflow.items.len > 0) {
        buf.appendSlice(allocator, "\n### Also available (summaries only):\n") catch {};
        for (overflow.items) |page| {
            buf.appendSlice(allocator, "- **") catch continue;
            buf.appendSlice(allocator, page.path) catch continue;
            buf.appendSlice(allocator, "** — ") catch continue;
            buf.appendSlice(allocator, if (page.summary.len > 0) page.summary else "(no summary)") catch continue;
            buf.appendSlice(allocator, "\n") catch continue;
        }
    }

    if (buf.items.len <= 30) return null; // Only header, no content
    return buf.toOwnedSlice(allocator) catch null;
}

// ============================================================
// Write path — parse agent output and apply knowledge updates
// ============================================================

/// Parse `## Knowledge Updates` section from agent output.
/// Returns a slice of Update structs. Caller owns the memory.
pub fn extractUpdates(result_text: []const u8, allocator: std.mem.Allocator) []const Update {
    // Find the knowledge updates marker
    const marker = "## Knowledge Updates";
    const start = std.mem.indexOf(u8, result_text, marker) orelse return &.{};
    const section = result_text[start + marker.len ..];

    var updates: std.ArrayList(Update) = .empty;

    // Parse each ### CREATE|UPDATE|APPEND block
    var pos: usize = 0;
    while (pos < section.len) {
        // Find next ### directive
        const directive_start = std.mem.indexOfPos(u8, section, pos, "### ") orelse break;
        const line_end = std.mem.indexOfPos(u8, section, directive_start, "\n") orelse section.len;
        const directive_line = std.mem.trim(u8, section[directive_start + 4 .. line_end], &std.ascii.whitespace);

        // Parse "CREATE path" / "UPDATE path" / "APPEND path"
        const parsed = parseDirective(directive_line) orelse {
            pos = line_end + 1;
            continue;
        };

        // Validate path: no "..", must not start with "/" or "_"
        if (!isValidKbPath(parsed.path)) {
            pos = line_end + 1;
            continue;
        }

        // Parse optional tags line and find content after "---" separator
        var tags_list: std.ArrayList([]const u8) = .empty;
        var content_start = line_end + 1;

        // Look for "tags:" line before "---"
        if (content_start < section.len) {
            const rest = section[content_start..];
            if (std.mem.startsWith(u8, std.mem.trim(u8, rest[0..@min(rest.len, 64)], &std.ascii.whitespace), "tags:")) {
                const tags_line_end = std.mem.indexOfPos(u8, section, content_start, "\n") orelse section.len;
                const tags_str = section[content_start..tags_line_end];
                // Skip "tags:" prefix
                if (std.mem.indexOf(u8, tags_str, "tags:")) |ti| {
                    parseTags(tags_str[ti + 5 ..], &tags_list, allocator);
                }
                content_start = tags_line_end + 1;
            }
        }

        // Find "---" separator
        if (content_start < section.len) {
            const rest = section[content_start..];
            if (std.mem.startsWith(u8, std.mem.trim(u8, rest[0..@min(rest.len, 16)], &std.ascii.whitespace), "---")) {
                const sep_end = std.mem.indexOfPos(u8, section, content_start, "\n") orelse section.len;
                content_start = @min(sep_end + 1, section.len);
            }
        }

        // Content extends to next "### " or next "## " (end of knowledge section)
        const content_end = blk: {
            const search_pos = content_start;
            while (search_pos < section.len) {
                if (std.mem.indexOfPos(u8, section, search_pos, "\n### ")) |next_dir| {
                    break :blk next_dir;
                }
                if (std.mem.indexOfPos(u8, section, search_pos, "\n## ")) |next_sec| {
                    break :blk next_sec;
                }
                break :blk section.len;
            }
            break :blk section.len;
        };

        const content = std.mem.trim(u8, section[content_start..content_end], &std.ascii.whitespace);

        if (content.len > 0) {
            updates.append(allocator, .{
                .op = parsed.op,
                .path = allocator.dupe(u8, parsed.path) catch {
                    pos = content_end;
                    continue;
                },
                .tags = tags_list.toOwnedSlice(allocator) catch &.{},
                .content = allocator.dupe(u8, content) catch {
                    pos = content_end;
                    continue;
                },
            }) catch {};
        }

        pos = content_end;
    }

    return updates.toOwnedSlice(allocator) catch &.{};
}

/// Apply knowledge updates: write files, update LMDB index, append to log.
pub fn applyUpdates(
    store: *store_mod.Store,
    knowledge_dir: []const u8,
    updates: []const Update,
    role_name: []const u8,
    allocator: std.mem.Allocator,
) !void {
    if (updates.len == 0) return;

    // Load current index from LMDB (need a read txn to get existing state)
    var current_index: std.ArrayList(PageMeta) = .empty;
    defer current_index.deinit(allocator);
    {
        const rtxn = store.beginReadTxn() catch null;
        defer if (rtxn) |t| store_mod.Store.abortTxn(t);
        if (rtxn) |t| {
            if (loadIndex(store, t, allocator)) |existing| {
                current_index.appendSlice(allocator, existing) catch {};
            }
        }
    }

    const now = fs.timestamp();

    // Apply each update
    for (updates) |upd| {
        const file_path = std.fs.path.join(allocator, &.{ knowledge_dir, upd.path }) catch continue;
        defer allocator.free(file_path);

        // Ensure parent directory exists
        if (std.fs.path.dirnamePosix(upd.path)) |parent_rel| {
            const parent_abs = std.fs.path.join(allocator, &.{ knowledge_dir, parent_rel }) catch continue;
            defer allocator.free(parent_abs);
            fs.makePath(parent_abs) catch {};
        }

        switch (upd.op) {
            .create, .update => {
                const file = fs.createFile(file_path, .{ .truncate = true }) catch continue;
                fs.writeFile(file, upd.content) catch {
                    fs.closeFile(file);
                    continue;
                };
                fs.closeFile(file);
            },
            .append => {
                // Read existing content and append
                const existing = fs.readFileAlloc(allocator, file_path, max_page_size) catch "";
                defer if (existing.len > 0) allocator.free(existing);

                const file = fs.createFile(file_path, .{ .truncate = true }) catch continue;
                if (existing.len > 0) {
                    fs.writeFile(file, existing) catch {
                        fs.closeFile(file);
                        continue;
                    };
                    // Ensure newline between existing and appended
                    if (existing[existing.len - 1] != '\n') {
                        fs.writeFile(file, "\n") catch {};
                    }
                    fs.writeFile(file, "\n") catch {};
                }
                fs.writeFile(file, upd.content) catch {
                    fs.closeFile(file);
                    continue;
                };
                fs.closeFile(file);
            },
        }

        // Compute summary: first non-empty, non-heading line
        const summary = extractSummary(upd.content);
        const content_size: u32 = @intCast(@min(upd.content.len, std.math.maxInt(u32)));

        // Update index entry
        upsertIndex(&current_index, .{
            .path = allocator.dupe(u8, upd.path) catch upd.path,
            .tags = if (upd.tags.len > 0) upd.tags else getDefaultTags(upd.path, allocator),
            .updated = now,
            .size = content_size,
            .summary = allocator.dupe(u8, summary) catch "",
        }, allocator);
    }

    // Write updated index to LMDB
    const index_json = serializeIndex(current_index.items, allocator) orelse return error.SerializeFailed;
    defer allocator.free(index_json);

    const wtxn = try store.beginWriteTxn();
    errdefer store_mod.Store.abortTxn(wtxn);
    try store.putMeta(wtxn, index_key, index_json);
    try store_mod.Store.commitTxn(wtxn);

    // Append to _log.md
    appendLog(knowledge_dir, updates, role_name, now, allocator);

    // Regenerate _index.md
    regenerateHumanIndex(knowledge_dir, current_index.items, allocator);
}

// ============================================================
// Index serialization — compact JSON for LMDB storage
// ============================================================

fn serializeIndex(pages: []const PageMeta, allocator: std.mem.Allocator) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(allocator, "[") catch return null;

    for (pages, 0..) |page, i| {
        if (i > 0) buf.appendSlice(allocator, ",") catch continue;
        buf.appendSlice(allocator, "{\"path\":\"") catch continue;
        appendJsonEscaped(&buf, page.path, allocator);
        buf.appendSlice(allocator, "\",\"tags\":[") catch continue;
        for (page.tags, 0..) |tag, j| {
            if (j > 0) buf.appendSlice(allocator, ",") catch continue;
            buf.appendSlice(allocator, "\"") catch continue;
            appendJsonEscaped(&buf, tag, allocator);
            buf.appendSlice(allocator, "\"") catch continue;
        }
        var num_buf: [64]u8 = undefined;
        const updated_str = std.fmt.bufPrint(&num_buf, "],\"updated\":{d},\"size\":{d},\"summary\":\"", .{
            page.updated, page.size,
        }) catch continue;
        buf.appendSlice(allocator, updated_str) catch continue;
        appendJsonEscaped(&buf, page.summary, allocator);
        buf.appendSlice(allocator, "\"}") catch continue;
    }

    buf.appendSlice(allocator, "]") catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

fn parseIndex(json: []const u8, allocator: std.mem.Allocator) ?[]PageMeta {
    // Use std.json to parse the index
    const parsed = std.json.parseFromSlice([]const IndexEntry, allocator, json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;

    var pages: std.ArrayList(PageMeta) = .empty;
    for (parsed.value) |entry| {
        pages.append(allocator, .{
            .path = entry.path,
            .tags = entry.tags,
            .updated = entry.updated,
            .size = @intCast(entry.size),
            .summary = entry.summary,
        }) catch continue;
    }
    return pages.toOwnedSlice(allocator) catch null;
}

/// JSON-compatible struct for std.json parsing.
const IndexEntry = struct {
    path: []const u8 = "",
    tags: []const []const u8 = &.{},
    updated: u64 = 0,
    size: u64 = 0,
    summary: []const u8 = "",
};

// ============================================================
// Internal helpers
// ============================================================

fn matchesTags(page: PageMeta, filter_tags: []const []const u8) bool {
    // Empty filter or "*" matches everything
    if (filter_tags.len == 0) return true;
    for (filter_tags) |ft| {
        if (std.mem.eql(u8, ft, "*")) return true;
    }
    // Check if any page tag matches any filter tag
    for (page.tags) |pt| {
        for (filter_tags) |ft| {
            if (std.mem.eql(u8, pt, ft)) return true;
        }
    }
    return false;
}

const Directive = struct {
    op: UpdateOp,
    path: []const u8,
};

fn parseDirective(line: []const u8) ?Directive {
    if (std.mem.startsWith(u8, line, "CREATE ")) {
        return .{ .op = .create, .path = std.mem.trim(u8, line[7..], &std.ascii.whitespace) };
    } else if (std.mem.startsWith(u8, line, "UPDATE ")) {
        return .{ .op = .update, .path = std.mem.trim(u8, line[7..], &std.ascii.whitespace) };
    } else if (std.mem.startsWith(u8, line, "APPEND ")) {
        return .{ .op = .append, .path = std.mem.trim(u8, line[7..], &std.ascii.whitespace) };
    }
    return null;
}

fn isValidKbPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '_') return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    if (!std.mem.endsWith(u8, path, ".md")) return false;
    return true;
}

fn parseTags(tags_str: []const u8, list: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    var iter = std.mem.splitScalar(u8, tags_str, ',');
    while (iter.next()) |raw| {
        const tag = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (tag.len > 0) {
            list.append(allocator, allocator.dupe(u8, tag) catch continue) catch continue;
        }
    }
}

fn extractSummary(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;
        if (std.mem.startsWith(u8, trimmed, "---")) continue;
        // Return first meaningful line, capped at 120 chars
        return trimmed[0..@min(trimmed.len, 120)];
    }
    return "";
}

fn getDefaultTags(path: []const u8, allocator: std.mem.Allocator) []const []const u8 {
    // Derive tag from first directory component: "architecture/foo.md" → ["architecture"]
    if (std.mem.indexOfScalar(u8, path, '/')) |sep| {
        const tag = allocator.dupe(u8, path[0..sep]) catch return &.{};
        const tags = allocator.alloc([]const u8, 1) catch return &.{};
        tags[0] = tag;
        return tags;
    }
    return &.{};
}

fn upsertIndex(index: *std.ArrayList(PageMeta), page: PageMeta, allocator: std.mem.Allocator) void {
    for (index.items) |*existing| {
        if (std.mem.eql(u8, existing.path, page.path)) {
            existing.* = page;
            return;
        }
    }
    index.append(allocator, page) catch {};
}

fn appendJsonEscaped(buf: *std.ArrayList(u8), str: []const u8, allocator: std.mem.Allocator) void {
    for (str) |ch| {
        switch (ch) {
            '"' => buf.appendSlice(allocator, "\\\"") catch {},
            '\\' => buf.appendSlice(allocator, "\\\\") catch {},
            '\n' => buf.appendSlice(allocator, "\\n") catch {},
            '\r' => buf.appendSlice(allocator, "\\r") catch {},
            '\t' => buf.appendSlice(allocator, "\\t") catch {},
            else => buf.append(allocator, ch) catch {},
        }
    }
}

fn appendLog(
    knowledge_dir: []const u8,
    updates: []const Update,
    role_name: []const u8,
    now: u64,
    allocator: std.mem.Allocator,
) void {
    const log_path = std.fs.path.join(allocator, &.{ knowledge_dir, "_log.md" }) catch return;
    defer allocator.free(log_path);

    // Format timestamp as ISO-like date
    const secs = @as(i64, @intCast(now));
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day = epoch_secs.getEpochDay();
    const ymd = day.calculateYearDay().calculateMonthDay();
    const year = day.calculateYearDay().year;

    var entry_buf: [4096]u8 = undefined;
    var pos: usize = 0;

    const header = std.fmt.bufPrint(entry_buf[pos..], "\n## [{d}-{d:0>2}-{d:0>2}] {s}\n", .{
        year, ymd.month.numeric(), ymd.day_index + 1, role_name,
    }) catch return;
    pos += header.len;

    for (updates) |upd| {
        const label = switch (upd.op) {
            .create => "created",
            .update => "updated",
            .append => "appended to",
        };
        const line = std.fmt.bufPrint(entry_buf[pos..], "- {s} `{s}`\n", .{ label, upd.path }) catch break;
        pos += line.len;
    }

    // Append to file
    const file = fs.createFile(log_path, .{ .truncate = false }) catch return;
    defer fs.closeFile(file);
    var file_pos = fs.fileLength(file);
    fs.writeFileAppend(file, entry_buf[0..pos], &file_pos) catch {};
}

fn regenerateHumanIndex(
    knowledge_dir: []const u8,
    pages: []const PageMeta,
    allocator: std.mem.Allocator,
) void {
    const index_path = std.fs.path.join(allocator, &.{ knowledge_dir, "_index.md" }) catch return;
    defer allocator.free(index_path);

    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(allocator, "# Knowledge Base Index\n\nAuto-generated catalog of all knowledge pages.\n\n") catch return;

    // Track current category to emit headers on change
    var current_cat: []const u8 = "";

    for (pages) |page| {
        const cat = if (std.mem.indexOfScalar(u8, page.path, '/')) |sep|
            page.path[0..sep]
        else
            "uncategorized";

        if (!std.mem.eql(u8, cat, current_cat)) {
            buf.appendSlice(allocator, "\n## ") catch continue;
            buf.appendSlice(allocator, cat) catch continue;
            buf.appendSlice(allocator, "\n\n") catch continue;
            current_cat = cat;
        }

        buf.appendSlice(allocator, "- **") catch continue;
        buf.appendSlice(allocator, page.path) catch continue;
        buf.appendSlice(allocator, "** — ") catch continue;
        buf.appendSlice(allocator, if (page.summary.len > 0) page.summary else "(no summary)") catch continue;
        buf.appendSlice(allocator, "\n") catch continue;
    }

    const file = fs.createFile(index_path, .{ .truncate = true }) catch return;
    defer fs.closeFile(file);
    fs.writeFile(file, buf.items) catch {};
}

/// Schema document written during `bees init`. Tells agents how to use the knowledge base.
pub const schema_document =
    \\# Knowledge Base Schema
    \\
    \\This directory is the swarm's institutional memory. Agents read pages before
    \\acting and write findings after. Knowledge compounds over time — each cycle
    \\builds on what previous cycles learned.
    \\
    \\## Categories
    \\
    \\| Directory | Purpose | Examples |
    \\|-----------|---------|----------|
    \\| `architecture/` | System design, data flow, module relationships | auth-flow.md, database-schema.md |
    \\| `components/` | Component maps, file-to-responsibility mapping | payment-api.md, user-dashboard.md |
    \\| `contracts/` | API contracts, interface boundaries, protocols | rest-api-v1.md, graphql-schema.md |
    \\| `decisions/` | Architecture Decision Records — what and why | why-lmdb.md, auth-provider-choice.md |
    \\| `failed/` | What was tried and why it failed — prevent repeats | redis-caching-attempt.md |
    \\| `operations/` | Deployment, monitoring, runtime behavior | deploy-pipeline.md, alerting-rules.md |
    \\
    \\## Writing Knowledge
    \\
    \\Include a `## Knowledge Updates` section in your output:
    \\
    \\```markdown
    \\## Knowledge Updates
    \\
    \\### CREATE category/page-name.md
    \\tags: category, topic1, topic2
    \\---
    \\# Page Title
    \\
    \\Content here. Be specific and factual.
    \\
    \\### UPDATE category/existing-page.md
    \\tags: category, topic1
    \\---
    \\# Updated Page Title
    \\
    \\Full replacement content.
    \\
    \\### APPEND decisions/some-decision.md
    \\---
    \\## YYYY-MM-DD: New finding
    \\
    \\Additional context appended to existing page.
    \\```
    \\
    \\## Conventions
    \\
    \\- **One concept per page.** 500-3000 bytes typical. Split large topics.
    \\- **Factual, not speculative.** Record what IS, not what might be.
    \\- **Say why, not just what.** "We use LMDB because zero-copy mmap reads" > "We use LMDB."
    \\- **Cross-reference freely.** Mention related pages: "See also: architecture/auth-flow.md"
    \\- **Failed approaches are valuable.** Record what was tried, why it failed, and what replaced it.
    \\- **Tags match directories.** Use the category name plus specific topics.
    \\- **Paths must end in .md** and contain no `..` or leading `_` or `/`.
    \\
    \\## Reading Knowledge
    \\
    \\Your prompt includes relevant knowledge pages based on your role's tag configuration.
    \\Full pages are included up to a budget limit; overflow pages appear as one-line summaries.
    \\If you need a page that appears only as a summary, mention it in your output and it will
    \\be prioritized in future sessions.
    \\
    \\## Maintenance
    \\
    \\Periodically check for:
    \\- **Contradictions** between pages (newer info should win)
    \\- **Stale claims** that code changes have invalidated
    \\- **Missing pages** for important concepts mentioned but not documented
    \\- **Redundant pages** that should be merged
    \\
;

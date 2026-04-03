//! Agent context assembly — unified builder for injecting context into agent prompts.
//!
//! Each agent declares which sources it needs. This module loads them all
//! in a single LMDB read transaction and assembles the prompt context string.
//!
//! Sources:
//!   - user_profiles:     .bees/prompts/users/*.txt (target personas)
//!   - operator_feedback: .bees/feedback.json (dashboard steering input)
//!   - report_qa:         LMDB report:qa (QA validation results)
//!   - report_sre:        LMDB report:sre (system health)
//!   - report_user:       LMDB report:user (simulated persona engagement)
//!   - task_trends:       LMDB report:trends (accept/reject rates)
//!   - worker_summary:    Recent worker sessions (what was built this cycle)
//!   - changed_files:     Git diff from merge cycle
//!   - task_context:      What task a worker was assigned (for review agent)

const std = @import("std");
const store_mod = @import("store.zig");
const config_mod = @import("config.zig");
const types = @import("types.zig");
const fs = @import("fs.zig");

pub const Source = enum {
    user_profiles,
    operator_feedback,
    report_qa,
    report_sre,
    report_user,
    task_trends,
    worker_summary,
    changed_files,
    task_context,
};

/// Pre-computed context values that don't come from LMDB or the filesystem.
/// Pass these when the orchestrator has already computed them.
pub const Extras = struct {
    changed_files: ?[]const u8 = null,
    worker_summary: ?[]const u8 = null,
    task_context: ?[]const u8 = null,
};

/// Build a context string from the requested sources.
/// Opens one LMDB read transaction for all DB-backed sources.
pub fn build(
    store: *store_mod.Store,
    paths: config_mod.ProjectPaths,
    sources: []const Source,
    extras: Extras,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    var parts: std.ArrayList(u8) = .empty;

    // Single read transaction for all LMDB-backed sources
    const txn: store_mod.ReadTxn = store.beginReadTxn() catch null;
    defer if (txn) |t| store_mod.Store.abortTxn(t);

    for (sources) |source| {
        switch (source) {
            .user_profiles => appendUserProfiles(&parts, paths, allocator),
            .operator_feedback => appendFeedback(&parts, paths, allocator),
            .report_qa => appendMeta(&parts, store, txn, "report:qa", "Latest QA Report", allocator),
            .report_sre => appendMeta(&parts, store, txn, "report:sre", "Latest SRE Report", allocator),
            .report_user => appendMeta(&parts, store, txn, "report:user", "User Engagement Report\nSimulated user personas navigated the product and reported their experience:", allocator),
            .task_trends => appendMeta(&parts, store, txn, "report:trends", "Task Performance Trends", allocator),
            .worker_summary => {
                if (extras.worker_summary) |ws| {
                    parts.appendSlice(allocator, "\n\n## What Workers Did This Cycle\n") catch {};
                    parts.appendSlice(allocator, ws) catch {};
                }
            },
            .changed_files => {
                if (extras.changed_files) |cf| {
                    parts.appendSlice(allocator, "\n\n## Changed Files (from this merge cycle)\n```\n") catch {};
                    parts.appendSlice(allocator, cf) catch {};
                    parts.appendSlice(allocator, "\n```\nFocus on pages/endpoints affected by these changes.") catch {};
                }
            },
            .task_context => {
                if (extras.task_context) |tc| {
                    parts.appendSlice(allocator, tc) catch {};
                }
            },
        }
    }

    if (parts.items.len == 0) return null;
    return parts.toOwnedSlice(allocator) catch null;
}

/// Build a summary of recent worker sessions for downstream agents.
/// Returns lines like: "- Task: 'Fix auth bug' — 2 commits, merged ($0.45)"
pub fn buildWorkerSummary(store: *store_mod.Store, allocator: std.mem.Allocator) ?[]const u8 {
    const txn = store.beginReadTxn() catch return null;
    defer store_mod.Store.abortTxn(txn);

    var buf: std.ArrayList(u8) = .empty;
    var iter = store.iterSessions(txn) catch return null;
    defer iter.close();

    const now = fs.timestamp();
    const cutoff = now -| 86400;
    var count: u32 = 0;

    while (count < 20) {
        const entry = iter.next() orelse break;
        if (entry.view.header.@"type" != .worker) continue;
        if (@as(u64, entry.view.header.started_at) < cutoff) continue;

        buf.appendSlice(allocator, "- Task: '") catch continue;
        buf.appendSlice(allocator, entry.view.task) catch continue;
        var detail_buf: [128]u8 = undefined;
        const cost_cents = @as(u64, entry.view.header.cost_microdollars) / 10000;
        const detail = std.fmt.bufPrint(&detail_buf, "' — {d} commits, {s} (${d}.{d:0>2})\n", .{
            entry.view.header.commit_count,
            entry.view.header.status.label(),
            cost_cents / 100,
            cost_cents % 100,
        }) catch continue;
        buf.appendSlice(allocator, detail) catch continue;
        count += 1;
    }

    if (buf.items.len == 0) return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// Look up a worker session's task name for review context.
pub fn getTaskContext(store: *store_mod.Store, worker_session_id: u64, allocator: std.mem.Allocator) ?[]const u8 {
    const txn = store.beginReadTxn() catch return null;
    defer store_mod.Store.abortTxn(txn);
    const ws = (store.getSession(txn, worker_session_id) catch return null) orelse return null;
    if (ws.task.len == 0) return null;
    return std.fmt.allocPrint(allocator,
        \\
        \\## Worker Context
        \\The worker was assigned this task: "{s}"
        \\Evaluate the diff against this intent — does the code accomplish what was asked?
        \\
    , .{ws.task}) catch null;
}

// === Internal helpers ===

fn appendUserProfiles(parts: *std.ArrayList(u8), paths: config_mod.ProjectPaths, allocator: std.mem.Allocator) void {
    const users_dir = std.fs.path.join(allocator, &.{ paths.prompts_dir, "users" }) catch return;
    defer allocator.free(users_dir);
    if (fs.readDirFiles(allocator, users_dir, 64 * 1024)) |profiles| {
        defer allocator.free(profiles);
        parts.appendSlice(allocator, "\n\n## Target User Profiles\n") catch {};
        parts.appendSlice(allocator, profiles) catch {};
    }
}

fn appendFeedback(parts: *std.ArrayList(u8), paths: config_mod.ProjectPaths, allocator: std.mem.Allocator) void {
    const fb_path = std.fs.path.join(allocator, &.{ paths.bees_dir, "feedback.json" }) catch return;
    defer allocator.free(fb_path);
    const fb = fs.readFileAlloc(allocator, fb_path, 64 * 1024) catch return;
    defer allocator.free(fb);
    if (fb.len > 3) { // More than just "[]"
        parts.appendSlice(allocator, "\n\n## Operator Feedback\nDirect input from the human operator. Address open items in your task decisions.\n\n") catch {};
        parts.appendSlice(allocator, fb) catch {};
    }
}

fn appendMeta(
    parts: *std.ArrayList(u8),
    store: *store_mod.Store,
    txn: store_mod.ReadTxn,
    key: []const u8,
    header: []const u8,
    allocator: std.mem.Allocator,
) void {
    const t = txn orelse return;
    const val = (store.getMeta(t, key) catch return) orelse return;
    parts.appendSlice(allocator, "\n\n## ") catch {};
    parts.appendSlice(allocator, header) catch {};
    parts.appendSlice(allocator, "\n") catch {};
    parts.appendSlice(allocator, val) catch {};
}

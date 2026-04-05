/// SQLite query layer — replaces LMDB read patterns for display, API, and CLI.
///
/// All functions take a sqlite.Db (read-only connection) and write results
/// directly as JSON to an Io.Writer or return simple values. No allocations
/// needed for most queries — data flows straight from SQLite rows to output.

const std = @import("std");
const Io = std.Io;
const sqlite = @import("sqlite.zig");
const types = @import("../types.zig");

// ============================================================================
// Sessions
// ============================================================================

/// Write a JSON array of sessions to writer. Optional type filter.
pub fn writeSessionsJson(db: *sqlite.Db, w: *Io.Writer, type_filter: ?types.SessionType, limit: u32) !void {
    const sql = if (type_filter != null)
        "SELECT id, session_type, status, backend, commit_count, cost_microdollars, task, branch, duration_ms, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, worker_id, num_turns, started_at, result_subtype, stop_reason, duration_api_ms FROM sessions WHERE session_type = ? ORDER BY id DESC LIMIT ?\x00"
    else
        "SELECT id, session_type, status, backend, commit_count, cost_microdollars, task, branch, duration_ms, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, worker_id, num_turns, started_at, result_subtype, stop_reason, duration_api_ms FROM sessions ORDER BY id DESC LIMIT ?\x00";

    var stmt = try db.prepare(sql);
    defer stmt.finalize();

    var param: c_int = 1;
    if (type_filter) |tf| {
        sqlite.bindInt(stmt.handle, param, @intFromEnum(tf));
        param += 1;
    }
    sqlite.bindInt(stmt.handle, param, @intCast(limit));

    try w.writeAll("[");
    var first = true;
    while (try stmt.step()) {
        if (!first) try w.writeAll(",");
        first = false;
        try writeSessionRowJson(&stmt, w);
    }
    try w.writeAll("]");
}

/// Write a single session as JSON. Returns false if not found.
pub fn writeSessionJson(db: *sqlite.Db, w: *Io.Writer, id: u64) !bool {
    var stmt = try db.prepare(
        "SELECT id, session_type, status, backend, commit_count, cost_microdollars, task, branch, duration_ms, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, worker_id, num_turns, started_at, result_subtype, stop_reason, duration_api_ms FROM sessions WHERE id = ?\x00",
    );
    defer stmt.finalize();
    sqlite.bindInt(stmt.handle, 1, @intCast(id));

    if (!try stmt.step()) return false;
    try writeSessionRowJson(&stmt, w);
    return true;
}

/// Get a session's branch name by ID, copying into caller-owned buffer.
/// Returns the slice within `buf` containing the branch, or empty if not found.
pub fn getSessionBranch(db: *sqlite.Db, id: u64, buf: []u8) ![]const u8 {
    var stmt = try db.prepare("SELECT branch FROM sessions WHERE id = ?\x00");
    defer stmt.finalize();
    sqlite.bindInt(stmt.handle, 1, @intCast(id));
    if (!try stmt.step()) return buf[0..0];
    const text = stmt.columnText(0);
    const len = @min(text.len, buf.len);
    @memcpy(buf[0..len], text[0..len]);
    return buf[0..len];
}

fn writeSessionRowJson(stmt: *sqlite.Stmt, w: *Io.Writer) !void {
    const id = stmt.columnInt(0);
    const session_type: types.SessionType = @enumFromInt(@as(u4, @intCast(stmt.columnInt(1))));
    const status: types.SessionStatus = @enumFromInt(@as(u3, @intCast(stmt.columnInt(2))));
    const backend: types.BackendType = @enumFromInt(@as(u2, @intCast(stmt.columnInt(3))));
    const commits = stmt.columnInt(4);
    const cost_micro = stmt.columnInt(5);
    const cost_cents = @divTrunc(cost_micro, 10000);

    try w.print("{{\"id\":{d},\"type\":\"{s}\",\"status\":\"{s}\",\"backend\":\"{s}\",\"commits\":{d},\"cost_cents\":{d},\"cost_microdollars\":{d},\"task\":", .{
        id, session_type.label(), status.label(), backend.label(), commits, cost_cents, cost_micro,
    });
    try writeJsonStr(w, stmt.columnText(6)); // task
    try w.print(",\"branch\":", .{});
    try writeJsonStr(w, stmt.columnText(7)); // branch
    try w.print(",\"duration_ms\":{d}", .{stmt.columnInt(8)});

    // Tokens (always present in SQLite, check for 0 as "not set")
    const input_tokens = stmt.columnInt(9);
    if (input_tokens > 0) {
        try w.print(",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_creation_tokens\":{d},\"cache_read_tokens\":{d}", .{
            input_tokens, stmt.columnInt(10), stmt.columnInt(11), stmt.columnInt(12),
        });
    }

    try w.print(",\"worker_id\":{d},\"num_turns\":{d},\"started_at\":{d}", .{
        stmt.columnInt(13), stmt.columnInt(14), stmt.columnInt(15),
    });

    // Result detail
    const result_subtype = stmt.columnInt(16);
    if (result_subtype > 0) {
        const rs: types.ResultSubtype = @enumFromInt(@as(u3, @intCast(result_subtype)));
        const sr: types.StopReason = @enumFromInt(@as(u2, @intCast(stmt.columnInt(17))));
        try w.print(",\"result_subtype\":\"{s}\",\"stop_reason\":\"{s}\",\"duration_api_ms\":{d}", .{
            rs.label(), sr.label(), stmt.columnInt(18),
        });
    }

    try w.writeAll("}");
}

// ============================================================================
// Events
// ============================================================================

/// Write events for a session as a JSON array.
pub fn writeSessionEventsJson(db: *sqlite.Db, w: *Io.Writer, session_id: u64) !void {
    var stmt = try db.prepare(
        "SELECT seq, event_type, tool_name, role, timestamp_offset_ms, raw_json FROM events WHERE session_id = ? ORDER BY seq\x00",
    );
    defer stmt.finalize();
    sqlite.bindInt(stmt.handle, 1, @intCast(session_id));

    try w.writeAll("[");
    var first = true;
    while (try stmt.step()) {
        if (!first) try w.writeAll(",");
        first = false;

        const seq = stmt.columnInt(0);
        const event_type: types.EventType = @enumFromInt(@as(u3, @intCast(stmt.columnInt(1))));
        const tool_name: types.ToolName = @enumFromInt(@as(u4, @intCast(stmt.columnInt(2))));
        const role: types.Role = @enumFromInt(@as(u2, @intCast(stmt.columnInt(3))));

        try w.print("{{\"seq\":{d},\"type\":\"{s}\",\"tool\":\"{s}\"", .{
            seq, event_type.label(), tool_name.label(),
        });
        if (role != .none) {
            try w.print(",\"role\":\"{s}\"", .{role.label()});
        }
        try w.print(",\"raw\":", .{});
        try w.writeAll(stmt.columnText(5)); // raw_json is already valid JSON
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

// ============================================================================
// Tasks
// ============================================================================

/// Write all tasks as a JSON array.
pub fn writeTasksJson(db: *sqlite.Db, w: *Io.Writer) !void {
    var stmt = try db.prepare(
        "SELECT name, weight, prompt, total_runs, accepted, rejected, empty, status, origin FROM tasks ORDER BY name\x00",
    );
    defer stmt.finalize();

    try w.writeAll("[");
    var first = true;
    while (try stmt.step()) {
        if (!first) try w.writeAll(",");
        first = false;

        const status: types.TaskStatus = @enumFromInt(@as(u2, @intCast(stmt.columnInt(7))));
        const origin: types.TaskOrigin = @enumFromInt(@as(u2, @intCast(stmt.columnInt(8))));

        try w.print("{{\"name\":", .{});
        try writeJsonStr(w, stmt.columnText(0));
        try w.print(",\"weight\":{d},\"prompt\":", .{stmt.columnInt(1)});
        try writeJsonStr(w, stmt.columnText(2));
        try w.print(",\"total_runs\":{d},\"accepted\":{d},\"rejected\":{d},\"empty\":{d},\"status\":\"{s}\",\"origin\":\"{s}\"}}", .{
            stmt.columnInt(3), stmt.columnInt(4), stmt.columnInt(5), stmt.columnInt(6),
            status.label(), origin.label(),
        });
    }
    try w.writeAll("]");
}

// ============================================================================
// Daily stats (replaces store.getDailyStats)
// ============================================================================

pub const DailyStats = struct {
    total: u32 = 0,
    accepted: u32 = 0,
    rejected: u32 = 0,
    conflicts: u32 = 0,
    build_failures: u32 = 0,
    errors: u32 = 0,
    total_cost_cents: u64 = 0,
};

pub fn getDailyStats(db: *sqlite.Db, day_start_ts: u64) !DailyStats {
    var stmt = try db.prepare(
        \\SELECT
        \\  COUNT(*),
        \\  SUM(CASE WHEN status = 2 THEN 1 ELSE 0 END),
        \\  SUM(CASE WHEN status = 3 THEN 1 ELSE 0 END),
        \\  SUM(CASE WHEN status = 4 THEN 1 ELSE 0 END),
        \\  SUM(CASE WHEN status = 5 THEN 1 ELSE 0 END),
        \\  SUM(CASE WHEN status = 6 THEN 1 ELSE 0 END),
        \\  COALESCE(SUM(cost_microdollars / 10000), 0)
        \\FROM sessions WHERE started_at >= ?
        ++ "\x00",
    );
    defer stmt.finalize();
    sqlite.bindInt(stmt.handle, 1, @intCast(day_start_ts));

    if (!try stmt.step()) return .{};

    return .{
        .total = @intCast(stmt.columnInt(0)),
        .accepted = @intCast(stmt.columnInt(1)),
        .rejected = @intCast(stmt.columnInt(2)),
        .conflicts = @intCast(stmt.columnInt(3)),
        .build_failures = @intCast(stmt.columnInt(4)),
        .errors = @intCast(stmt.columnInt(5)),
        .total_cost_cents = @intCast(stmt.columnInt(6)),
    };
}

// ============================================================================
// Worker summary (replaces context.buildWorkerSummary)
// ============================================================================

/// Build a text summary of recent worker sessions for prompt injection.
pub fn buildWorkerSummary(db: *sqlite.Db, allocator: std.mem.Allocator) ?[]const u8 {
    var stmt = db.prepare(
        "SELECT task, commit_count, status, cost_microdollars FROM sessions WHERE session_type = 0 AND started_at > ? ORDER BY id DESC LIMIT 20\x00",
    ) catch return null;
    defer stmt.finalize();

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const cutoff: i64 = @intCast(ts.sec - 86400);
    sqlite.bindInt(stmt.handle, 1, cutoff);

    var buf: std.ArrayList(u8) = .empty;

    while (true) {
        const has_row = stmt.step() catch break;
        if (!has_row) break;
        const task = stmt.columnText(0);
        const commits = stmt.columnInt(1);
        const status: types.SessionStatus = @enumFromInt(@as(u3, @intCast(stmt.columnInt(2))));
        const cost_cents: u64 = @intCast(@divTrunc(stmt.columnInt(3), 10000));

        buf.appendSlice(allocator, "- Task: '") catch continue;
        buf.appendSlice(allocator, task) catch continue;
        var detail_buf: [128]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "' — {d} commits, {s} (${d}.{d:0>2})\n", .{
            commits, status.label(), cost_cents / 100, cost_cents % 100,
        }) catch continue;
        buf.appendSlice(allocator, detail) catch continue;
    }

    if (buf.items.len == 0) return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// Look up a worker session's task name for review context.
pub fn getTaskContext(db: *sqlite.Db, worker_session_id: u64, allocator: std.mem.Allocator) ?[]const u8 {
    var stmt = db.prepare("SELECT task FROM sessions WHERE id = ?\x00") catch return null;
    defer stmt.finalize();
    sqlite.bindInt(stmt.handle, 1, @intCast(worker_session_id));
    if (!(stmt.step() catch return null)) return null;
    const task = stmt.columnText(0);
    if (task.len == 0) return null;
    return std.fmt.allocPrint(allocator,
        \\
        \\## Worker Context
        \\The worker was assigned this task: "{s}"
        \\Evaluate the diff against this intent — does the code accomplish what was asked?
        \\
    , .{task}) catch null;
}

/// Get a meta value (report text etc). Returns null if not found.
/// Meta values are stored in the _sync_state table or a dedicated meta table.
/// For now, reports are stored in LMDB meta and synced — this queries SQLite directly
/// if/when reports move to SQLite.
pub fn getMeta(db: *sqlite.Db, key: []const u8) ?[]const u8 {
    _ = db;
    _ = key;
    // TODO: once reports are synced to SQLite, query here
    return null;
}

// ============================================================================
// JSON helpers
// ============================================================================

fn writeJsonStr(w: *Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch >= 0x20) {
                    try w.print("{c}", .{ch});
                } else {
                    try w.print("\\u00{x:0>2}", .{ch});
                }
            },
        }
    }
    try w.writeAll("\"");
}

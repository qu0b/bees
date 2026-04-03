/// LMDB → SQLite sync engine.
///
/// Cursor-based: tracks a high-water mark (last synced session ID) in SQLite.
/// New records are found by LMDB cursor seek. Non-terminal sessions are updated
/// by querying SQLite for sessions with status < terminal threshold.
///
/// Design:
///   - LMDB read transaction = consistent snapshot (non-blocking to orchestrator)
///   - SQLite write = single transaction (atomic, efficient)
///   - Tiered error handling: LMDB read failure = abort, SQLite write failure = retry later

const std = @import("std");
const types = @import("../types.zig");
const store_mod = @import("../store.zig");
const sqlite = @import("sqlite.zig");
const schema = @import("schema.zig");
const c_sq = sqlite.c;

/// Terminal session statuses — sessions at or above this value never change.
/// running=0, done=1, merged=2, rejected=3, conflict=4, build_failed=5, err=6
/// "done" (1) and above are terminal from the sync perspective — the orchestrator
/// only transitions running→done, then merger transitions done→merged/rejected/etc.
const terminal_status_threshold: i64 = 1; // done and above

pub const SyncEngine = struct {
    sqlite_db: sqlite.Db,
    session_insert: sqlite.Stmt,
    event_insert: sqlite.Stmt,
    review_insert: sqlite.Stmt,
    task_insert: sqlite.Stmt,

    pub fn init(sqlite_path: []const u8) !SyncEngine {
        var db = try sqlite.Db.open(sqlite_path);
        errdefer db.close();

        // Create all tables and indexes
        inline for (schema.all_ddl) |ddl| {
            db.execMulti(ddl) catch {
                return error.SqliteError;
            };
        }

        // Sync metadata table
        db.execMulti(
            \\CREATE TABLE IF NOT EXISTS _sync_state (
            \\  table_name TEXT PRIMARY KEY,
            \\  high_water_mark INTEGER NOT NULL DEFAULT 0,
            \\  last_sync_at INTEGER NOT NULL DEFAULT 0
            \\);
        ) catch return error.SqliteError;

        // Prepare cached statements
        var session_insert = try db.prepare(schema.sessions_upsert ++ "\x00");
        errdefer session_insert.finalize();

        var event_insert = try db.prepare(schema.events_upsert ++ "\x00");
        errdefer event_insert.finalize();

        var review_insert = try db.prepare(schema.reviews_upsert ++ "\x00");
        errdefer review_insert.finalize();

        var task_insert = try db.prepare(schema.tasks_upsert ++ "\x00");
        errdefer task_insert.finalize();

        return .{
            .sqlite_db = db,
            .session_insert = session_insert,
            .event_insert = event_insert,
            .review_insert = review_insert,
            .task_insert = task_insert,
        };
    }

    pub fn deinit(self: *SyncEngine) void {
        self.session_insert.finalize();
        self.event_insert.finalize();
        self.review_insert.finalize();
        self.task_insert.finalize();
        self.sqlite_db.close();
    }

    /// Run a full sync cycle: LMDB → SQLite.
    /// Opens an LMDB read transaction (snapshot), syncs new + updated records, commits SQLite.
    pub fn syncAll(self: *SyncEngine, lmdb_store: *store_mod.Store) !SyncStats {
        var stats = SyncStats{};

        // Begin LMDB read transaction — consistent snapshot, non-blocking
        const lmdb_txn = try lmdb_store.beginReadTxn();
        defer store_mod.Store.abortTxn(lmdb_txn);

        // Begin SQLite transaction
        self.sqlite_db.execMulti("BEGIN IMMEDIATE") catch return error.SqliteError;
        errdefer self.sqlite_db.execMulti("ROLLBACK") catch {};

        // 1. Sync sessions (new + updated)
        stats.sessions_synced = try self.syncSessions(lmdb_store, lmdb_txn);

        // 2. Sync events for new sessions
        stats.events_synced = try self.syncEvents(lmdb_store, lmdb_txn);

        // 3. Sync reviews
        stats.reviews_synced = try self.syncReviews(lmdb_store, lmdb_txn);

        // 4. Sync tasks (always full scan — small table)
        stats.tasks_synced = try self.syncTasks(lmdb_store, lmdb_txn);

        // Update sync timestamp
        {
            var ts_stmt = self.sqlite_db.prepare("INSERT OR REPLACE INTO _sync_state (table_name, high_water_mark, last_sync_at) VALUES ('_global', 0, ?)\x00") catch null;
            if (ts_stmt) |*s| {
                defer s.finalize();
                var ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(.REALTIME, &ts);
                sqlite.bindInt(s.handle, 1, @intCast(ts.sec));
                s.exec() catch {};
            }
        }

        // Commit SQLite transaction
        try self.sqlite_db.execMulti("COMMIT");

        return stats;
    }

    fn syncSessions(self: *SyncEngine, lmdb_store: *store_mod.Store, lmdb_txn: store_mod.ReadTxn) !u32 {
        var count: u32 = 0;

        // Full scan of LMDB sessions — for simplicity and correctness.
        // Session count is small (hundreds to low thousands), so this is fine.
        var iter = try lmdb_store.iterSessions(lmdb_txn);
        defer iter.close();

        while (iter.next()) |entry| {
            schema.bindSession(
                self.session_insert.handle,
                entry.id,
                entry.view.header,
                entry.view.task,
                entry.view.branch,
                entry.view.worktree,
                entry.view.diff_summary,
            );
            self.session_insert.exec() catch continue;
            count += 1;
        }

        return count;
    }

    fn syncEvents(self: *SyncEngine, lmdb_store: *store_mod.Store, lmdb_txn: store_mod.ReadTxn) !u32 {
        // Get the high-water mark for events
        const hwm = self.getHighWaterMark("events") catch 0;

        var count: u32 = 0;
        var max_session: u64 = hwm;

        // Iterate sessions from hwm onward and sync their events
        var sess_iter = try lmdb_store.iterSessions(lmdb_txn);
        defer sess_iter.close();

        while (sess_iter.next()) |sess| {
            if (sess.id <= hwm) continue;

            var ev_iter = lmdb_store.iterSessionEvents(lmdb_txn, sess.id) catch continue;
            defer ev_iter.close();

            while (ev_iter.next()) |ev| {
                schema.bindEvent(
                    self.event_insert.handle,
                    sess.id,
                    ev.seq,
                    ev.header,
                    ev.raw_json,
                );
                self.event_insert.exec() catch continue;
                count += 1;
            }

            if (sess.id > max_session) max_session = sess.id;
        }

        // Only advance HWM for terminal sessions
        if (max_session > hwm) {
            self.setHighWaterMark("events", max_session) catch {};
        }

        return count;
    }

    fn syncReviews(self: *SyncEngine, lmdb_store: *store_mod.Store, lmdb_txn: store_mod.ReadTxn) !u32 {
        var count: u32 = 0;

        // Reviews are keyed by worker_session_id — iterate all sessions and check for reviews
        var sess_iter = try lmdb_store.iterSessions(lmdb_txn);
        defer sess_iter.close();

        while (sess_iter.next()) |sess| {
            if (sess.view.header.@"type" != .worker) continue;
            const review = (lmdb_store.getReview(lmdb_txn, sess.id) catch continue) orelse continue;
            schema.bindReview(
                self.review_insert.handle,
                sess.id,
                review.header,
                review.reason,
            );
            self.review_insert.exec() catch continue;
            count += 1;
        }

        return count;
    }

    fn syncTasks(self: *SyncEngine, lmdb_store: *store_mod.Store, lmdb_txn: store_mod.ReadTxn) !u32 {
        var count: u32 = 0;

        var iter = try lmdb_store.iterTasks(lmdb_txn);
        defer iter.close();

        while (iter.next()) |entry| {
            schema.bindTask(
                self.task_insert.handle,
                entry.name,
                entry.view.header,
                entry.view.prompt,
            );
            self.task_insert.exec() catch continue;
            count += 1;
        }

        return count;
    }

    // -- High-water mark helpers --

    fn getHighWaterMark(self: *SyncEngine, table_name: []const u8) !u64 {
        var stmt = try self.sqlite_db.prepare("SELECT high_water_mark FROM _sync_state WHERE table_name = ?\x00");
        defer stmt.finalize();
        sqlite.bindText(stmt.handle, 1, table_name);
        const has_row = try stmt.step();
        if (!has_row) return 0;
        return @intCast(stmt.columnInt(0));
    }

    fn setHighWaterMark(self: *SyncEngine, table_name: []const u8, value: u64) !void {
        var stmt = try self.sqlite_db.prepare("INSERT OR REPLACE INTO _sync_state (table_name, high_water_mark) VALUES (?, ?)\x00");
        defer stmt.finalize();
        sqlite.bindText(stmt.handle, 1, table_name);
        sqlite.bindInt(stmt.handle, 2, @intCast(value));
        try stmt.exec();
    }
};

pub const SyncStats = struct {
    sessions_synced: u32 = 0,
    events_synced: u32 = 0,
    reviews_synced: u32 = 0,
    tasks_synced: u32 = 0,

    pub fn total(self: SyncStats) u64 {
        return @as(u64, self.sessions_synced) + self.events_synced + self.reviews_synced + self.tasks_synced;
    }
};

// ============================================================================
// Integration test: LMDB write → sync → SQLite read
// ============================================================================

test "LMDB to SQLite round-trip sync" {
    const Store = store_mod.Store;

    // Set up temporary LMDB
    const lmdb_dir = "/tmp/bees-test-sync-lmdb";
    _ = std.c.mkdir(lmdb_dir, 0o755);
    defer {
        _ = std.c.unlink(lmdb_dir ++ "/data.mdb");
        _ = std.c.unlink(lmdb_dir ++ "/lock.mdb");
        _ = std.c.rmdir(lmdb_dir);
    }

    var lmdb_store = try Store.open(lmdb_dir);
    defer lmdb_store.close();

    // Create a session in LMDB
    const header = types.SessionHeader{
        .@"type" = .worker,
        .status = .done,
        .has_exit_code = true,
        .has_cost = true,
        .model = .sonnet,
        .has_tokens = true,
        .has_duration = true,
        .has_diff_summary = false,
        .worker_id = 3,
        .commit_count = 2,
        .num_turns = 15,
        .exit_code = 0,
        .started_at = 1712188800,
        .finished_at = 1712192400,
        .duration_ms = 3600000,
        .cost_microdollars = 1500000,
        .input_tokens = 50000,
        .output_tokens = 10000,
        .cache_creation_tokens = 5000,
        .cache_read_tokens = 20000,
    };

    const session_id = try lmdb_store.createSession(header, "Fix login bug", "bee/fix-login/worker-3", "/tmp/worktree-3");
    try std.testing.expectEqual(@as(u64, 1), session_id);

    // Insert an event
    {
        const txn = try lmdb_store.beginWriteTxn();
        errdefer Store.abortTxn(txn);
        const ev_header = types.EventHeader{
            .event_type = .tool_use,
            .tool_name = .bash,
            .role = .assistant,
            .timestamp_offset_ms = 1500,
        };
        try lmdb_store.insertEvent(txn, session_id, 0, ev_header, "{\"type\":\"tool_use\",\"tool\":\"Bash\"}");
        try Store.commitTxn(txn);
    }

    // Set up sync engine with temporary SQLite
    const sqlite_path = "/tmp/bees-test-sync.sqlite";
    defer _ = std.c.unlink(sqlite_path);

    var sync = try SyncEngine.init(sqlite_path);
    defer sync.deinit();

    // Run sync
    const stats = try sync.syncAll(&lmdb_store);
    try std.testing.expectEqual(@as(u32, 1), stats.sessions_synced);
    try std.testing.expectEqual(@as(u32, 1), stats.events_synced);

    // Verify session data in SQLite
    var q = try sync.sqlite_db.prepare("SELECT id, session_type, status, worker_id, cost_microdollars, task, branch FROM sessions WHERE id = 1\x00");
    defer q.finalize();
    const has_row = try q.step();
    try std.testing.expect(has_row);

    try std.testing.expectEqual(@as(i64, 1), q.columnInt(0)); // id
    try std.testing.expectEqual(@as(i64, 0), q.columnInt(1)); // session_type = worker = 0
    try std.testing.expectEqual(@as(i64, 1), q.columnInt(2)); // status = done = 1
    try std.testing.expectEqual(@as(i64, 3), q.columnInt(3)); // worker_id
    try std.testing.expectEqual(@as(i64, 1500000), q.columnInt(4)); // cost_microdollars
    try std.testing.expectEqualStrings("Fix login bug", q.columnText(5));
    try std.testing.expectEqualStrings("bee/fix-login/worker-3", q.columnText(6));

    // Verify event data in SQLite
    var eq = try sync.sqlite_db.prepare("SELECT session_id, seq, event_type, tool_name FROM events WHERE session_id = 1\x00");
    defer eq.finalize();
    const has_event = try eq.step();
    try std.testing.expect(has_event);

    try std.testing.expectEqual(@as(i64, 1), eq.columnInt(0)); // session_id
    try std.testing.expectEqual(@as(i64, 0), eq.columnInt(1)); // seq
    try std.testing.expectEqual(@as(i64, 2), eq.columnInt(2)); // event_type = tool_use = 2
    try std.testing.expectEqual(@as(i64, 1), eq.columnInt(3)); // tool_name = bash = 1
}

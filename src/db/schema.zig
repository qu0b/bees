/// Comptime schema definitions — single source of truth for LMDB, SQLite, and DuckDB.
///
/// Each table is defined once as a comptime struct spec. From that spec, comptime
/// functions generate:
///   1. SQLite CREATE TABLE DDL
///   2. SQLite INSERT OR REPLACE statement with ? placeholders
///   3. Type-safe `bindSqlite()` function that binds packed struct fields to sqlite3_stmt
///   4. Type-safe `readSqlite()` function that reads a sqlite3_stmt row into a struct
///
/// LMDB continues to use the existing packed structs in types.zig — no change.
/// DuckDB reads directly from SQLite via the sqlite extension (ATTACH).

const std = @import("std");
const types = @import("../types.zig");
const sqlite = @import("sqlite.zig");

const c = sqlite.c;

// ============================================================================
// Schema field definition
// ============================================================================

pub const FieldKind = enum {
    /// Integer field — stored directly
    integer,
    /// Text/string field — stored as TEXT
    text,
    /// Blob field — stored as BLOB
    blob,
};

pub const FieldDef = struct {
    name: []const u8,
    kind: FieldKind,
    /// If true, this is the PRIMARY KEY
    is_key: bool = false,
    /// SQLite type affinity override (default derived from kind)
    sqlite_type: ?[]const u8 = null,
    /// If true, create an index on this column
    indexed: bool = false,
    /// If true, this field can be NULL (sentinel-based in LMDB)
    nullable: bool = false,
};

// ============================================================================
// Table definitions
// ============================================================================

pub const sessions_fields = [_]FieldDef{
    .{ .name = "id", .kind = .integer, .is_key = true },
    .{ .name = "session_type", .kind = .integer, .indexed = true },
    .{ .name = "status", .kind = .integer, .indexed = true },
    .{ .name = "backend", .kind = .integer },
    .{ .name = "worker_id", .kind = .integer },
    .{ .name = "commit_count", .kind = .integer },
    .{ .name = "num_turns", .kind = .integer },
    .{ .name = "exit_code", .kind = .integer, .nullable = true },
    .{ .name = "started_at", .kind = .integer, .indexed = true },
    .{ .name = "finished_at", .kind = .integer, .nullable = true },
    .{ .name = "duration_ms", .kind = .integer },
    .{ .name = "cost_microdollars", .kind = .integer },
    .{ .name = "input_tokens", .kind = .integer },
    .{ .name = "output_tokens", .kind = .integer },
    .{ .name = "cache_creation_tokens", .kind = .integer },
    .{ .name = "cache_read_tokens", .kind = .integer },
    .{ .name = "model", .kind = .integer },
    .{ .name = "result_subtype", .kind = .integer },
    .{ .name = "stop_reason", .kind = .integer },
    .{ .name = "duration_api_ms", .kind = .integer },
    .{ .name = "task", .kind = .text },
    .{ .name = "branch", .kind = .text },
    .{ .name = "worktree", .kind = .text },
    .{ .name = "diff_summary", .kind = .text, .nullable = true },
};

pub const events_fields = [_]FieldDef{
    .{ .name = "session_id", .kind = .integer, .is_key = true, .indexed = true },
    .{ .name = "seq", .kind = .integer, .is_key = true },
    .{ .name = "event_type", .kind = .integer },
    .{ .name = "tool_name", .kind = .integer },
    .{ .name = "role", .kind = .integer },
    .{ .name = "timestamp_offset_ms", .kind = .integer },
    .{ .name = "raw_json", .kind = .text },
};

pub const reviews_fields = [_]FieldDef{
    .{ .name = "worker_session_id", .kind = .integer, .is_key = true },
    .{ .name = "verdict", .kind = .integer },
    .{ .name = "review_session_id", .kind = .integer },
    .{ .name = "reviewed_at", .kind = .integer },
    .{ .name = "reason", .kind = .text },
};

pub const tasks_fields = [_]FieldDef{
    .{ .name = "name", .kind = .text, .is_key = true },
    .{ .name = "weight", .kind = .integer },
    .{ .name = "total_runs", .kind = .integer },
    .{ .name = "accepted", .kind = .integer },
    .{ .name = "rejected", .kind = .integer },
    .{ .name = "empty", .kind = .integer },
    .{ .name = "status", .kind = .integer },
    .{ .name = "origin", .kind = .integer },
    .{ .name = "prompt", .kind = .text },
};

// ============================================================================
// Comptime DDL generation
// ============================================================================

fn sqliteTypeStr(field: FieldDef) []const u8 {
    if (field.sqlite_type) |t| return t;
    return switch (field.kind) {
        .integer => "INTEGER",
        .text => "TEXT",
        .blob => "BLOB",
    };
}

/// Generate "CREATE TABLE IF NOT EXISTS <name> (...)" at comptime.
fn comptimeCreateTable(comptime name: []const u8, comptime fields: []const FieldDef) []const u8 {
    comptime {
        var sql: []const u8 = "CREATE TABLE IF NOT EXISTS " ++ name ++ " (\n";

        // Collect primary key fields
        var pk_count: usize = 0;
        for (fields) |f| {
            if (f.is_key) pk_count += 1;
        }

        for (fields, 0..) |f, i| {
            sql = sql ++ "  " ++ f.name ++ " " ++ sqliteTypeStr(f);
            if (pk_count == 1 and f.is_key) {
                sql = sql ++ " PRIMARY KEY";
            }
            if (!f.nullable and !f.is_key) {
                sql = sql ++ " NOT NULL";
            }
            if (i < fields.len - 1) {
                sql = sql ++ ",\n";
            }
        }

        // Composite primary key
        if (pk_count > 1) {
            sql = sql ++ ",\n  PRIMARY KEY (";
            var first = true;
            for (fields) |f| {
                if (f.is_key) {
                    if (!first) sql = sql ++ ", ";
                    sql = sql ++ f.name;
                    first = false;
                }
            }
            sql = sql ++ ")";
        }

        sql = sql ++ "\n)";
        return sql;
    }
}

/// Generate "INSERT OR REPLACE INTO <name> (...) VALUES (?, ?, ...)" at comptime.
fn comptimeUpsert(comptime name: []const u8, comptime fields: []const FieldDef) []const u8 {
    comptime {
        var sql: []const u8 = "INSERT OR REPLACE INTO " ++ name ++ " (";
        for (fields, 0..) |f, i| {
            sql = sql ++ f.name;
            if (i < fields.len - 1) sql = sql ++ ", ";
        }
        sql = sql ++ ") VALUES (";
        for (fields, 0..) |_, i| {
            sql = sql ++ "?";
            if (i < fields.len - 1) sql = sql ++ ", ";
        }
        sql = sql ++ ")";
        return sql;
    }
}

/// Count indexed (non-key) fields at comptime.
fn comptimeIndexCount(comptime fields: []const FieldDef) usize {
    comptime {
        var count: usize = 0;
        for (fields) |f| {
            if (f.indexed and !f.is_key) count += 1;
        }
        return count;
    }
}

/// Generate a single CREATE INDEX statement for the Nth indexed field.
fn comptimeNthIndex(comptime name: []const u8, comptime fields: []const FieldDef, comptime n: usize) []const u8 {
    comptime {
        var idx: usize = 0;
        for (fields) |f| {
            if (f.indexed and !f.is_key) {
                if (idx == n) {
                    return "CREATE INDEX IF NOT EXISTS idx_" ++ name ++ "_" ++ f.name ++ " ON " ++ name ++ " (" ++ f.name ++ ")";
                }
                idx += 1;
            }
        }
        unreachable;
    }
}

/// Generate an array of CREATE INDEX DDL strings at comptime.
fn ComptimeIndexes(comptime name: []const u8, comptime fields: []const FieldDef) type {
    const count = comptimeIndexCount(fields);
    return struct {
        pub const len = count;
        pub const stmts: [count][]const u8 = blk: {
            var result: [count][]const u8 = undefined;
            for (0..count) |i| {
                result[i] = comptimeNthIndex(name, fields, i);
            }
            break :blk result;
        };
    };
}

// ============================================================================
// Generated DDL constants
// ============================================================================

pub const sessions_create = comptimeCreateTable("sessions", &sessions_fields);
pub const sessions_upsert = comptimeUpsert("sessions", &sessions_fields);
const SessionsIdx = ComptimeIndexes("sessions", &sessions_fields);

pub const events_create = comptimeCreateTable("events", &events_fields);
pub const events_upsert = comptimeUpsert("events", &events_fields);
const EventsIdx = ComptimeIndexes("events", &events_fields);

pub const reviews_create = comptimeCreateTable("reviews", &reviews_fields);
pub const reviews_upsert = comptimeUpsert("reviews", &reviews_fields);
const ReviewsIdx = ComptimeIndexes("reviews", &reviews_fields);

pub const tasks_create = comptimeCreateTable("tasks", &tasks_fields);
pub const tasks_upsert = comptimeUpsert("tasks", &tasks_fields);
const TasksIdx = ComptimeIndexes("tasks", &tasks_fields);

// ============================================================================
// Bind helpers: LMDB packed structs → SQLite parameters
// ============================================================================

/// Bind a session record (id + SessionHeader + strings) to a prepared INSERT statement.
/// Parameter order matches sessions_fields.
pub fn bindSession(stmt: *c.sqlite3_stmt, id: u64, h: types.SessionHeader, task: []const u8, branch: []const u8, worktree: []const u8, diff_summary: []const u8) void {
    var col: c_int = 1;
    sqlite.bindInt(stmt, col, @intCast(id));
    col += 1;
    sqlite.bindInt(stmt, col, @intFromEnum(h.@"type"));
    col += 1;
    sqlite.bindInt(stmt, col, @intFromEnum(h.status));
    col += 1;
    sqlite.bindInt(stmt, col, @intFromEnum(h.backend));
    col += 1;
    sqlite.bindInt(stmt, col, @intCast(h.worker_id));
    col += 1;
    sqlite.bindInt(stmt, col, @intCast(h.commit_count));
    col += 1;
    sqlite.bindInt(stmt, col, @intCast(h.num_turns));
    col += 1;
    // exit_code — nullable via has_exit_code sentinel
    if (h.has_exit_code) {
        sqlite.bindInt(stmt, col, @intCast(h.exit_code));
    } else {
        sqlite.bindNull(stmt, col);
    }
    col += 1;
    sqlite.bindInt(stmt, col, @intCast(h.started_at));
    col += 1;
    // finished_at — 0 sentinel = NULL
    if (h.finished_at != 0) {
        sqlite.bindInt(stmt, col, @intCast(h.finished_at));
    } else {
        sqlite.bindNull(stmt, col);
    }
    col += 1;
    sqlite.bindInt(stmt, col, @intCast(h.duration_ms));
    col += 1;
    sqlite.bindInt(stmt, col, @intCast(h.cost_microdollars));
    col += 1;
    sqlite.bindInt(stmt, col, @intCast(h.input_tokens));
    col += 1;
    sqlite.bindInt(stmt, col, @intCast(h.output_tokens));
    col += 1;
    sqlite.bindInt(stmt, col, @intCast(h.cache_creation_tokens));
    col += 1;
    sqlite.bindInt(stmt, col, @intCast(h.cache_read_tokens));
    col += 1;
    sqlite.bindInt(stmt, col, @intFromEnum(h.model));
    col += 1;
    sqlite.bindInt(stmt, col, @intFromEnum(h.result_subtype));
    col += 1;
    sqlite.bindInt(stmt, col, @intFromEnum(h.stop_reason));
    col += 1;
    sqlite.bindInt(stmt, col, @intCast(h.duration_api_ms));
    col += 1;
    sqlite.bindText(stmt, col, task);
    col += 1;
    sqlite.bindText(stmt, col, branch);
    col += 1;
    sqlite.bindText(stmt, col, worktree);
    col += 1;
    if (diff_summary.len > 0) {
        sqlite.bindText(stmt, col, diff_summary);
    } else {
        sqlite.bindNull(stmt, col);
    }
}

/// Bind an event record to a prepared INSERT statement.
pub fn bindEvent(stmt: *c.sqlite3_stmt, session_id: u64, seq: u32, h: types.EventHeader, raw_json: []const u8) void {
    sqlite.bindInt(stmt, 1, @intCast(session_id));
    sqlite.bindInt(stmt, 2, @intCast(seq));
    sqlite.bindInt(stmt, 3, @intFromEnum(h.event_type));
    sqlite.bindInt(stmt, 4, @intFromEnum(h.tool_name));
    sqlite.bindInt(stmt, 5, @intFromEnum(h.role));
    sqlite.bindInt(stmt, 6, @intCast(h.timestamp_offset_ms));
    sqlite.bindText(stmt, 7, raw_json);
}

/// Bind a review record to a prepared INSERT statement.
pub fn bindReview(stmt: *c.sqlite3_stmt, worker_session_id: u64, h: types.ReviewHeader, reason: []const u8) void {
    sqlite.bindInt(stmt, 1, @intCast(worker_session_id));
    sqlite.bindInt(stmt, 2, @intFromEnum(h.verdict));
    sqlite.bindInt(stmt, 3, @intCast(h.review_session_id));
    sqlite.bindInt(stmt, 4, @intCast(h.reviewed_at));
    sqlite.bindText(stmt, 5, reason);
}

/// Bind a task record to a prepared INSERT statement.
pub fn bindTask(stmt: *c.sqlite3_stmt, name: []const u8, h: types.TaskHeader, prompt: []const u8) void {
    sqlite.bindText(stmt, 1, name);
    sqlite.bindInt(stmt, 2, @intCast(h.weight));
    sqlite.bindInt(stmt, 3, @intCast(h.total_runs));
    sqlite.bindInt(stmt, 4, @intCast(h.accepted));
    sqlite.bindInt(stmt, 5, @intCast(h.rejected));
    sqlite.bindInt(stmt, 6, @intCast(h.empty));
    sqlite.bindInt(stmt, 7, @intFromEnum(h.status));
    sqlite.bindInt(stmt, 8, @intFromEnum(h.origin));
    sqlite.bindText(stmt, 9, prompt);
}

// ============================================================================
// All DDL — execute in order to initialize database
// ============================================================================

/// All CREATE TABLE + CREATE INDEX statements in dependency order.
pub const all_ddl: []const []const u8 = &([_][]const u8{
    sessions_create,
    events_create,
    reviews_create,
    tasks_create,
} ++ SessionsIdx.stmts ++ EventsIdx.stmts ++ ReviewsIdx.stmts ++ TasksIdx.stmts);

// ============================================================================
// Tests
// ============================================================================

test "sessions DDL generates valid SQL" {
    // Verify the DDL contains expected fragments
    try std.testing.expect(std.mem.indexOf(u8, sessions_create, "CREATE TABLE IF NOT EXISTS sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, sessions_create, "id INTEGER PRIMARY KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, sessions_create, "cost_microdollars INTEGER NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sessions_create, "diff_summary TEXT") != null);
    // diff_summary should NOT have NOT NULL
    try std.testing.expect(std.mem.indexOf(u8, sessions_create, "diff_summary TEXT NOT NULL") == null);
}

test "sessions upsert has correct placeholders" {
    // Count ? placeholders — should match field count
    var count: usize = 0;
    for (sessions_upsert) |ch| {
        if (ch == '?') count += 1;
    }
    try std.testing.expectEqual(sessions_fields.len, count);
}

test "events DDL has composite primary key" {
    try std.testing.expect(std.mem.indexOf(u8, events_create, "PRIMARY KEY (session_id, seq)") != null);
}

test "indexes generated for indexed fields" {
    try std.testing.expect(SessionsIdx.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, SessionsIdx.stmts[0], "CREATE INDEX") != null);
}

test "all_ddl is concatenated correctly" {
    // Should have 4 CREATE TABLE + all indexes
    try std.testing.expect(all_ddl.len >= 4);
    try std.testing.expect(std.mem.indexOf(u8, all_ddl[0], "CREATE TABLE") != null);
}

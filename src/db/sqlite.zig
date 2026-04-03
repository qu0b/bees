/// Thin SQLite wrapper for Zig — @cImport of sqlite3.h with ergonomic helpers.
///
/// Design goals:
///   - Zero allocations for bind/step/reset cycles
///   - WAL mode for concurrent readers during sync writes
///   - Prepared statement caching via caller-owned pointers

const std = @import("std");

pub const c = @cImport(@cInclude("sqlite3.h"));

pub const SqliteError = error{
    SqliteError,
    SqliteBusy,
    SqliteLocked,
    SqliteCorrupt,
    SqliteMisuse,
};

pub const Db = struct {
    handle: *c.sqlite3,

    /// Open (or create) a SQLite database at `path`. Enables WAL mode and common pragmas.
    pub fn open(path: []const u8) SqliteError!Db {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.SqliteError;

        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            path_z,
            &handle,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX,
            null,
        );
        if (rc != c.SQLITE_OK or handle == null) return error.SqliteError;

        var db = Db{ .handle = handle.? };

        // Performance pragmas
        db.execMulti(
            \\PRAGMA journal_mode=WAL;
            \\PRAGMA synchronous=NORMAL;
            \\PRAGMA busy_timeout=5000;
            \\PRAGMA cache_size=-8000;
            \\PRAGMA foreign_keys=ON;
        ) catch {};

        return db;
    }

    /// Open read-only connection (for dashboard/CLI).
    pub fn openReadOnly(path: []const u8) SqliteError!Db {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.SqliteError;

        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            path_z,
            &handle,
            c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX,
            null,
        );
        if (rc != c.SQLITE_OK or handle == null) return error.SqliteError;

        var db = Db{ .handle = handle.? };
        db.execMulti("PRAGMA busy_timeout=5000;") catch {};
        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Execute one or more SQL statements (no results).
    pub fn execMulti(self: *Db, sql: []const u8) SqliteError!void {
        var sql_buf: [8192]u8 = undefined;
        const sql_z = std.fmt.bufPrintZ(&sql_buf, "{s}", .{sql}) catch return error.SqliteError;
        const rc = c.sqlite3_exec(self.handle, sql_z, null, null, null);
        return checkRc(rc);
    }

    /// Prepare a single SQL statement.
    pub fn prepare(self: *Db, sql: [*:0]const u8) SqliteError!Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return error.SqliteError;
        return Stmt{ .handle = stmt.? };
    }

    /// Get the raw handle for advanced use.
    pub fn rawHandle(self: *Db) *c.sqlite3 {
        return self.handle;
    }

    /// Get human-readable error message.
    pub fn errmsg(self: *Db) []const u8 {
        const msg = c.sqlite3_errmsg(self.handle);
        if (msg) |m| {
            return std.mem.span(m);
        }
        return "unknown error";
    }

    /// Last insert rowid.
    pub fn lastInsertRowid(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Number of rows changed by last INSERT/UPDATE/DELETE.
    pub fn changes(self: *Db) c_int {
        return c.sqlite3_changes(self.handle);
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    /// Step the statement. Returns true if a row is available (SQLITE_ROW).
    pub fn step(self: *Stmt) SqliteError!bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return mapError(rc);
    }

    /// Reset for re-use with new bindings.
    pub fn reset(self: *Stmt) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    /// Execute (step until done), then reset. For INSERT/UPDATE/DELETE.
    pub fn exec(self: *Stmt) SqliteError!void {
        const has_row = try self.step();
        _ = has_row;
        self.reset();
    }

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    // -- Column readers --

    pub fn columnInt(self: *Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, col);
    }

    pub fn columnText(self: *Stmt, col: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.handle, col);
        if (ptr == null) return "";
        const len = c.sqlite3_column_bytes(self.handle, col);
        if (len <= 0) return "";
        return @as([*]const u8, @ptrCast(ptr))[0..@intCast(len)];
    }

    pub fn columnIsNull(self: *Stmt, col: c_int) bool {
        return c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL;
    }
};

// ============================================================================
// Free-function bind helpers (used by schema.zig bind functions)
// ============================================================================

pub fn bindInt(stmt: *c.sqlite3_stmt, col: c_int, value: i64) void {
    _ = c.sqlite3_bind_int64(stmt, col, value);
}

pub fn bindText(stmt: *c.sqlite3_stmt, col: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), c.SQLITE_STATIC);
}

pub fn bindNull(stmt: *c.sqlite3_stmt, col: c_int) void {
    _ = c.sqlite3_bind_null(stmt, col);
}

// ============================================================================
// Error mapping
// ============================================================================

fn checkRc(rc: c_int) SqliteError!void {
    if (rc == c.SQLITE_OK or rc == c.SQLITE_DONE) return;
    return mapError(rc);
}

fn mapError(rc: c_int) SqliteError {
    return switch (rc) {
        c.SQLITE_BUSY => error.SqliteBusy,
        c.SQLITE_LOCKED => error.SqliteLocked,
        c.SQLITE_CORRUPT => error.SqliteCorrupt,
        c.SQLITE_MISUSE => error.SqliteMisuse,
        else => error.SqliteError,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "open in-memory database" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.execMulti("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)");
    try db.execMulti("INSERT INTO t VALUES (1, 'hello')");

    var stmt = try db.prepare("SELECT val FROM t WHERE id = 1");
    defer stmt.finalize();

    const has_row = try stmt.step();
    try std.testing.expect(has_row);
    try std.testing.expectEqualStrings("hello", stmt.columnText(0));
}

test "bind helpers" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.execMulti("CREATE TABLE t (a INTEGER, b TEXT, c INTEGER)");

    var stmt = try db.prepare("INSERT INTO t VALUES (?, ?, ?)");
    defer stmt.finalize();

    bindInt(stmt.handle, 1, 42);
    bindText(stmt.handle, 2, "world");
    bindNull(stmt.handle, 3);
    try stmt.exec();

    var q = try db.prepare("SELECT a, b, c FROM t");
    defer q.finalize();
    const has_row = try q.step();
    try std.testing.expect(has_row);
    try std.testing.expectEqual(@as(i64, 42), q.columnInt(0));
    try std.testing.expectEqualStrings("world", q.columnText(1));
    try std.testing.expect(q.columnIsNull(2));
}

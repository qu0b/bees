/// DuckDB analytical query engine — runtime-loaded via dlopen.
///
/// Instead of maintaining a separate DuckDB database, this module opens an
/// in-memory DuckDB instance and ATTACHes the SQLite database directly using
/// DuckDB's built-in sqlite extension. This eliminates the ETL layer entirely.
///
/// Usage:
///   var duck = try Duckdb.init("/path/to/data.duckdb", "/path/to/data.sqlite");
///   defer duck.deinit();
///   var result = try duck.query("SELECT task, AVG(cost_microdollars) FROM sqlite.sessions GROUP BY task");
///   defer result.destroy();
///   while (result.next()) |row| { ... }

const std = @import("std");

// DuckDB C API types (opaque handles)
const duckdb_database = ?*anyopaque;
const duckdb_connection = ?*anyopaque;

// DuckDB result struct — must match the C layout.
// We access it through the C API functions, not directly.
const duckdb_state = enum(c_int) { success = 0, err = 1 };

// Result is a large struct in the C API; we treat it as opaque bytes.
const DuckdbResult = extern struct {
    _data: [512]u8 = std.mem.zeroes([512]u8),
};

// Function pointer types for the DuckDB C API
const OpenFn = *const fn ([*:0]const u8, *duckdb_database) callconv(.C) c_int;
const CloseFn = *const fn (*duckdb_database) callconv(.C) void;
const ConnectFn = *const fn (duckdb_database, *duckdb_connection) callconv(.C) c_int;
const DisconnectFn = *const fn (*duckdb_connection) callconv(.C) void;
const QueryFn = *const fn (duckdb_connection, [*:0]const u8, *DuckdbResult) callconv(.C) c_int;
const DestroyResultFn = *const fn (*DuckdbResult) callconv(.C) void;
const RowCountFn = *const fn (*DuckdbResult) callconv(.C) u64;
const ColumnCountFn = *const fn (*DuckdbResult) callconv(.C) u64;
const ColumnNameFn = *const fn (*DuckdbResult, u64) callconv(.C) ?[*:0]const u8;
const ValueVarcharFn = *const fn (*DuckdbResult, u64, u64) callconv(.C) ?[*:0]u8;
const ValueInt64Fn = *const fn (*DuckdbResult, u64, u64) callconv(.C) i64;
const ValueDoubleFn = *const fn (*DuckdbResult, u64, u64) callconv(.C) f64;
const ValueIsNullFn = *const fn (*DuckdbResult, u64, u64) callconv(.C) bool;
const FreeFn = *const fn (?*anyopaque) callconv(.C) void;
const ResultErrorFn = *const fn (*DuckdbResult) callconv(.C) ?[*:0]const u8;

pub const DuckdbError = error{
    DuckdbUnavailable,
    DuckdbOpenFailed,
    DuckdbConnectFailed,
    DuckdbQueryFailed,
    DuckdbAttachFailed,
};

pub const Duckdb = struct {
    lib: std.DynLib,
    db: duckdb_database,
    conn: duckdb_connection,
    sqlite_attached: bool,

    // Cached function pointers
    fn_close: CloseFn,
    fn_disconnect: DisconnectFn,
    fn_query: QueryFn,
    fn_destroy_result: DestroyResultFn,
    fn_row_count: RowCountFn,
    fn_column_count: ColumnCountFn,
    fn_column_name: ColumnNameFn,
    fn_value_varchar: ValueVarcharFn,
    fn_value_int64: ValueInt64Fn,
    fn_value_double: ValueDoubleFn,
    fn_value_is_null: ValueIsNullFn,
    fn_free: FreeFn,
    fn_result_error: ResultErrorFn,

    /// Initialize DuckDB by loading libduckdb.so at runtime.
    /// `duckdb_path` is the persistent database file (null or empty string for in-memory).
    /// If `sqlite_path` is provided, ATTACHes it as "bees" for cross-engine queries.
    /// Returns DuckdbUnavailable if the shared library cannot be found.
    pub fn init(duckdb_path: ?[]const u8, sqlite_path: ?[]const u8) DuckdbError!Duckdb {
        // Try to load the shared library from several locations
        var lib = std.DynLib.open("libduckdb.so") catch
            std.DynLib.open("vendor/duckdb/libduckdb.so") catch
            std.DynLib.open("/usr/local/lib/libduckdb.so") catch
            return error.DuckdbUnavailable;
        errdefer lib.close();

        // Load all function pointers
        const fn_open = lib.lookup(OpenFn, "duckdb_open") orelse return error.DuckdbUnavailable;
        const fn_close = lib.lookup(CloseFn, "duckdb_close") orelse return error.DuckdbUnavailable;
        const fn_connect = lib.lookup(ConnectFn, "duckdb_connect") orelse return error.DuckdbUnavailable;
        const fn_disconnect = lib.lookup(DisconnectFn, "duckdb_disconnect") orelse return error.DuckdbUnavailable;
        const fn_query = lib.lookup(QueryFn, "duckdb_query") orelse return error.DuckdbUnavailable;
        const fn_destroy_result = lib.lookup(DestroyResultFn, "duckdb_destroy_result") orelse return error.DuckdbUnavailable;
        const fn_row_count = lib.lookup(RowCountFn, "duckdb_row_count") orelse return error.DuckdbUnavailable;
        const fn_column_count = lib.lookup(ColumnCountFn, "duckdb_column_count") orelse return error.DuckdbUnavailable;
        const fn_column_name = lib.lookup(ColumnNameFn, "duckdb_column_name") orelse return error.DuckdbUnavailable;
        const fn_value_varchar = lib.lookup(ValueVarcharFn, "duckdb_value_varchar") orelse return error.DuckdbUnavailable;
        const fn_value_int64 = lib.lookup(ValueInt64Fn, "duckdb_value_int64") orelse return error.DuckdbUnavailable;
        const fn_value_double = lib.lookup(ValueDoubleFn, "duckdb_value_double") orelse return error.DuckdbUnavailable;
        const fn_value_is_null = lib.lookup(ValueIsNullFn, "duckdb_value_is_null") orelse return error.DuckdbUnavailable;
        const fn_free = lib.lookup(FreeFn, "duckdb_free") orelse return error.DuckdbUnavailable;
        const fn_result_error = lib.lookup(ResultErrorFn, "duckdb_result_error") orelse return error.DuckdbUnavailable;

        // Open database (persistent file or in-memory)
        var path_buf: [4096]u8 = undefined;
        const path_z: [*:0]const u8 = if (duckdb_path) |p|
            std.fmt.bufPrintZ(&path_buf, "{s}", .{p}) catch return error.DuckdbOpenFailed
        else
            @ptrCast("");
        var db: duckdb_database = null;
        if (fn_open(path_z, &db) != 0) return error.DuckdbOpenFailed;
        errdefer fn_close(&db);

        // Connect
        var conn: duckdb_connection = null;
        if (fn_connect(db, &conn) != 0) return error.DuckdbConnectFailed;
        errdefer fn_disconnect(&conn);

        var self = Duckdb{
            .lib = lib,
            .db = db,
            .conn = conn,
            .sqlite_attached = false,
            .fn_close = fn_close,
            .fn_disconnect = fn_disconnect,
            .fn_query = fn_query,
            .fn_destroy_result = fn_destroy_result,
            .fn_row_count = fn_row_count,
            .fn_column_count = fn_column_count,
            .fn_column_name = fn_column_name,
            .fn_value_varchar = fn_value_varchar,
            .fn_value_int64 = fn_value_int64,
            .fn_value_double = fn_value_double,
            .fn_value_is_null = fn_value_is_null,
            .fn_free = fn_free,
            .fn_result_error = fn_result_error,
        };

        // Optionally ATTACH a SQLite database for cross-engine queries
        if (sqlite_path) |sp| {
            self.attachSqlite(sp) catch |err| {
                std.debug.print("DuckDB: failed to attach SQLite: {s}\n", .{@errorName(err)});
                return error.DuckdbAttachFailed;
            };
        }

        return self;
    }

    pub fn deinit(self: *Duckdb) void {
        self.fn_disconnect(&self.conn);
        self.fn_close(&self.db);
        self.lib.close();
    }

    fn attachSqlite(self: *Duckdb, sqlite_path: []const u8) !void {
        // Install sqlite extension
        var install_result: DuckdbResult = .{};
        _ = self.fn_query(self.conn, "INSTALL sqlite", &install_result);
        self.fn_destroy_result(&install_result);

        var load_result: DuckdbResult = .{};
        if (self.fn_query(self.conn, "LOAD sqlite", &load_result) != 0) {
            self.fn_destroy_result(&load_result);
            return error.DuckdbAttachFailed;
        }
        self.fn_destroy_result(&load_result);

        // ATTACH the SQLite database
        var sql_buf: [4096]u8 = undefined;
        const attach_sql = std.fmt.bufPrintZ(&sql_buf, "ATTACH '{s}' AS bees (TYPE sqlite, READ_ONLY)", .{sqlite_path}) catch return error.DuckdbAttachFailed;

        var attach_result: DuckdbResult = .{};
        if (self.fn_query(self.conn, attach_sql, &attach_result) != 0) {
            self.fn_destroy_result(&attach_result);
            return error.DuckdbAttachFailed;
        }
        self.fn_destroy_result(&attach_result);
        self.sqlite_attached = true;
    }

    /// Execute an analytical query. Returns a QueryResult that must be destroyed.
    pub fn query(self: *Duckdb, sql: [*:0]const u8) DuckdbError!QueryResult {
        var result: DuckdbResult = .{};
        if (self.fn_query(self.conn, sql, &result) != 0) {
            const err_msg = self.fn_result_error(&result);
            if (err_msg) |msg| {
                std.debug.print("DuckDB query error: {s}\n", .{std.mem.span(msg)});
            }
            self.fn_destroy_result(&result);
            return error.DuckdbQueryFailed;
        }
        return QueryResult{
            .result = result,
            .duck = self,
            .current_row = 0,
            .num_rows = self.fn_row_count(&result),
            .num_cols = self.fn_column_count(&result),
        };
    }

    /// Execute a query and return the result as a formatted string (for injection into prompts).
    pub fn queryToString(self: *Duckdb, allocator: std.mem.Allocator, sql: [*:0]const u8) ![]const u8 {
        var result = try self.query(sql);
        defer result.destroy();

        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        const writer = buf.writer();

        // Write header
        var col: u64 = 0;
        while (col < result.num_cols) : (col += 1) {
            if (col > 0) try writer.writeAll("\t");
            const name = self.fn_column_name(&result.result, col);
            if (name) |n| try writer.writeAll(std.mem.span(n));
        }
        try writer.writeAll("\n");

        // Write rows
        while (result.current_row < result.num_rows) : (result.current_row += 1) {
            col = 0;
            while (col < result.num_cols) : (col += 1) {
                if (col > 0) try writer.writeAll("\t");
                if (self.fn_value_is_null(&result.result, col, result.current_row)) {
                    try writer.writeAll("NULL");
                } else {
                    const val = self.fn_value_varchar(&result.result, col, result.current_row);
                    if (val) |v| {
                        try writer.writeAll(std.mem.span(v));
                        self.fn_free(@ptrCast(v));
                    }
                }
            }
            try writer.writeAll("\n");
        }

        return buf.toOwnedSlice();
    }
};

pub const QueryResult = struct {
    result: DuckdbResult,
    duck: *Duckdb,
    current_row: u64,
    num_rows: u64,
    num_cols: u64,

    pub fn destroy(self: *QueryResult) void {
        self.duck.fn_destroy_result(&self.result);
    }

    pub fn rowCount(self: *QueryResult) u64 {
        return self.num_rows;
    }

    pub fn columnCount(self: *QueryResult) u64 {
        return self.num_cols;
    }

    /// Get column name.
    pub fn columnName(self: *QueryResult, col: u64) []const u8 {
        const name = self.duck.fn_column_name(&self.result, col);
        if (name) |n| return std.mem.span(n);
        return "";
    }

    /// Get value as i64 at current row.
    pub fn getInt(self: *QueryResult, col: u64) i64 {
        return self.duck.fn_value_int64(&self.result, col, self.current_row);
    }

    /// Get value as f64 at current row.
    pub fn getDouble(self: *QueryResult, col: u64) f64 {
        return self.duck.fn_value_double(&self.result, col, self.current_row);
    }

    /// Check if value is null at current row.
    pub fn isNull(self: *QueryResult, col: u64) bool {
        return self.duck.fn_value_is_null(&self.result, col, self.current_row);
    }

    /// Get value as string at current row. Caller must free with duckdb_free.
    pub fn getVarchar(self: *QueryResult, col: u64) ?[*:0]u8 {
        return self.duck.fn_value_varchar(&self.result, col, self.current_row);
    }

    /// Free a varchar obtained from getVarchar.
    pub fn freeVarchar(self: *QueryResult, ptr: [*:0]u8) void {
        self.duck.fn_free(@ptrCast(ptr));
    }

    /// Advance to next row. Returns false if exhausted.
    pub fn next(self: *QueryResult) bool {
        if (self.current_row >= self.num_rows) return false;
        self.current_row += 1;
        return self.current_row <= self.num_rows;
    }
};

// ============================================================================
// Pre-built analytical queries for strategist/SRE prompt injection
// ============================================================================

pub const analytics = struct {
    /// Task effectiveness: success rate, avg cost, run count per task — last 7 days.
    pub const task_effectiveness =
        \\SELECT task,
        \\       COUNT(*) as runs,
        \\       ROUND(SUM(CASE WHEN status >= 2 THEN 1 ELSE 0 END)::FLOAT / COUNT(*) * 100, 1) as success_pct,
        \\       ROUND(AVG(cost_microdollars) / 1000000.0, 2) as avg_cost_usd,
        \\       ROUND(AVG(duration_ms) / 1000.0, 0) as avg_duration_secs
        \\FROM bees.sessions
        \\WHERE session_type = 0
        \\  AND started_at > (EXTRACT(EPOCH FROM NOW())::BIGINT - 604800)
        \\GROUP BY task
        \\ORDER BY success_pct ASC
    ;

    /// Hourly cost trend — last 24 hours.
    pub const hourly_cost =
        \\SELECT date_trunc('hour', to_timestamp(started_at)) as hour,
        \\       COUNT(*) as sessions,
        \\       ROUND(SUM(cost_microdollars) / 1000000.0, 2) as cost_usd
        \\FROM bees.sessions
        \\WHERE started_at > (EXTRACT(EPOCH FROM NOW())::BIGINT - 86400)
        \\GROUP BY 1
        \\ORDER BY 1
    ;

    /// Worker efficiency: output/input token ratio, cost per second.
    pub const worker_efficiency =
        \\SELECT worker_id,
        \\       COUNT(*) as sessions,
        \\       ROUND(AVG(output_tokens::FLOAT / NULLIF(input_tokens, 0)), 2) as output_ratio,
        \\       ROUND(AVG(cost_microdollars::FLOAT / NULLIF(duration_ms, 0) * 1000), 2) as cost_per_sec_micro
        \\FROM bees.sessions
        \\WHERE session_type = 0 AND duration_ms > 0
        \\  AND started_at > (EXTRACT(EPOCH FROM NOW())::BIGINT - 604800)
        \\GROUP BY worker_id
        \\ORDER BY cost_per_sec_micro ASC
    ;

    /// Tool usage distribution.
    pub const tool_usage =
        \\SELECT
        \\  CASE tool_name
        \\    WHEN 1 THEN 'Bash' WHEN 2 THEN 'Read' WHEN 3 THEN 'Edit'
        \\    WHEN 4 THEN 'Write' WHEN 5 THEN 'Glob' WHEN 6 THEN 'Grep'
        \\    WHEN 7 THEN 'WebSearch' WHEN 8 THEN 'WebFetch' WHEN 9 THEN 'Agent'
        \\    ELSE 'Other'
        \\  END as tool,
        \\  COUNT(*) as uses
        \\FROM bees.events
        \\WHERE event_type = 2
        \\GROUP BY tool_name
        \\ORDER BY uses DESC
    ;
};

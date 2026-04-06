const std = @import("std");
const assert = std.debug.assert;
const types = @import("types.zig");
const c = @cImport(@cInclude("lmdb.h"));

/// Exported for cross-module use (context.zig) without leaking lmdb.h opaque types.
pub const ReadTxn = ?*c.MDB_txn;

pub const Store = struct {
    env: ?*c.MDB_env,
    sessions: c.MDB_dbi,
    sessions_by_status: c.MDB_dbi,
    sessions_by_time: c.MDB_dbi,
    events: c.MDB_dbi,
    reviews: c.MDB_dbi,
    tasks: c.MDB_dbi,
    meta: c.MDB_dbi,

    pub fn open(path: []const u8) !Store {
        assert(path.len > 0);
        assert(path.len < 4096);
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;

        var env: ?*c.MDB_env = null;
        try check(c.mdb_env_create(&env));
        errdefer c.mdb_env_close(env);

        try check(c.mdb_env_set_maxdbs(env, 8));
        try check(c.mdb_env_set_mapsize(env, 1 * 1024 * 1024 * 1024));
        // With MDB_NOTLS, each concurrent read txn needs its own reader slot.
        // 3 workers + merger + strategist + QA + SRE + CLI = ~32 max concurrent.
        try check(c.mdb_env_set_maxreaders(env, 32));
        // MDB_NOTLS: don't use thread-local storage for reader slots.
        // Required because io_uring green threads can migrate between OS threads.
        try check(c.mdb_env_open(env, path_z, c.MDB_NOTLS, 0o644));

        // Clean up stale reader slots from crashed processes
        _ = c.mdb_reader_check(env, null);

        // Open all sub-databases in a single write transaction
        var txn: ?*c.MDB_txn = null;
        try check(c.mdb_txn_begin(env, null, 0, &txn));
        errdefer c.mdb_txn_abort(txn);

        const sessions = try openDbi(txn, types.DbNames.sessions);
        const sessions_by_status = try openDbi(txn, types.DbNames.sessions_by_status);
        const sessions_by_time = try openDbi(txn, types.DbNames.sessions_by_time);
        const events = try openDbi(txn, types.DbNames.events);
        const reviews = try openDbi(txn, types.DbNames.reviews);
        const tasks_dbi = try openDbi(txn, types.DbNames.tasks);
        const meta_dbi = try openDbi(txn, types.DbNames.meta);

        try check(c.mdb_txn_commit(txn));

        return .{
            .env = env,
            .sessions = sessions,
            .sessions_by_status = sessions_by_status,
            .sessions_by_time = sessions_by_time,
            .events = events,
            .reviews = reviews,
            .tasks = tasks_dbi,
            .meta = meta_dbi,
        };
    }

    pub fn close(self: *Store) void {
        if (self.env) |env| {
            c.mdb_env_close(env);
            self.env = null;
        }
    }

    // -- Meta key-value operations --

    /// Store an arbitrary string value in the meta sub-database.
    pub fn putMeta(self: *Store, txn: ?*c.MDB_txn, key: []const u8, value: []const u8) !void {
        var key_val = mkValSlice(key);
        var data_val = mkValSlice(value);
        try check(c.mdb_put(txn, self.meta, &key_val, &data_val, 0));
    }

    /// Retrieve a string value from the meta sub-database.
    pub fn getMeta(self: *Store, txn: ?*c.MDB_txn, key: []const u8) !?[]const u8 {
        var key_val = mkValSlice(key);
        var data_val: c.MDB_val = undefined;
        const rc = c.mdb_get(txn, self.meta, &key_val, &data_val);
        if (rc == c.MDB_NOTFOUND) return null;
        if (rc != 0) return lmdbError(rc);
        const ptr: [*]const u8 = @ptrCast(data_val.mv_data);
        return ptr[0..data_val.mv_size];
    }

    // -- Session operations --

    pub fn nextSessionId(self: *Store, txn: ?*c.MDB_txn) !u64 {
        const key_str = "next_session_id";
        var key_val = mkVal(key_str);
        var data_val: c.MDB_val = undefined;

        const rc = c.mdb_get(txn, self.meta, &key_val, &data_val);
        var current: u64 = 0;
        if (rc == 0) {
            if (data_val.mv_size >= 8) {
                const ptr: *const [8]u8 = @ptrCast(@alignCast(data_val.mv_data));
                current = std.mem.readInt(u64, ptr, .little);
            }
        } else if (rc != c.MDB_NOTFOUND) {
            return lmdbError(rc);
        }

        const next = current + 1;
        var next_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &next_bytes, next, .little);
        var next_val = mkValBytes(&next_bytes);
        try check(c.mdb_put(txn, self.meta, &key_val, &next_val, 0));
        return next;
    }

    pub fn createSession(
        self: *Store,
        header: types.SessionHeader,
        task: []const u8,
        branch: []const u8,
        worktree: []const u8,
    ) !u64 {
        assert(self.env != null);
        assert(header.started_at > 0); // Timestamp must be set.

        var txn: ?*c.MDB_txn = null;
        try check(c.mdb_txn_begin(self.env, null, 0, &txn));
        errdefer c.mdb_txn_abort(txn);

        const id = try self.nextSessionId(txn);

        // Write primary record
        const key = types.SessionKey{ .id = id };
        var key_bytes = key.toBytes();
        var key_val = mkValBytes(&key_bytes);

        const value_size = types.sessionValueSize(task, branch, worktree, null);
        var data_val: c.MDB_val = .{ .mv_size = value_size, .mv_data = null };
        try check(c.mdb_put(txn, self.sessions, &key_val, &data_val, c.MDB_RESERVE));

        // Write header + strings into reserved space
        const buf: [*]u8 = @ptrCast(data_val.mv_data);
        const dest = buf[0..value_size];
        @memcpy(dest[0..@sizeOf(types.SessionHeader)], std.mem.asBytes(&header));
        var offset: usize = @sizeOf(types.SessionHeader);
        types.writeLenPrefixed(dest, &offset, task);
        types.writeLenPrefixed(dest, &offset, branch);
        types.writeLenPrefixed(dest, &offset, worktree);

        // Write status index
        var status_key = types.StatusIndexKey.init(header.status, @as(u64, header.started_at), id);
        var status_key_val = mkValSlice(status_key.toBytes());
        var empty_val = mkValEmpty();
        try check(c.mdb_put(txn, self.sessions_by_status, &status_key_val, &empty_val, 0));

        // Write time index
        var time_key = types.TimeIndexKey.init(@as(u64, header.started_at), id, header.type);
        var time_key_val = mkValSlice(time_key.toBytes());
        try check(c.mdb_put(txn, self.sessions_by_time, &time_key_val, &empty_val, 0));

        try check(c.mdb_txn_commit(txn));
        return id;
    }

    pub fn getSession(self: *Store, txn: ?*c.MDB_txn, id: u64) !?types.SessionView {
        assert(id > 0);
        const key = types.SessionKey{ .id = id };
        var key_bytes = key.toBytes();
        var key_val = mkValBytes(&key_bytes);
        var data_val: c.MDB_val = undefined;

        const rc = c.mdb_get(txn, self.sessions, &key_val, &data_val);
        if (rc == c.MDB_NOTFOUND) return null;
        if (rc != 0) return lmdbError(rc);

        // Pair assertion: validate minimum value size matches header.
        assert(data_val.mv_size >= @sizeOf(types.SessionHeader));

        const ptr: [*]const u8 = @ptrCast(data_val.mv_data);
        const view = types.SessionView.fromBytes(ptr[0..data_val.mv_size]);

        // Pair assertion: started_at must be set (matches write-side check).
        assert(view.header.started_at > 0);

        return view;
    }

    pub fn updateSessionStatus(self: *Store, id: u64, old_status: types.SessionStatus, old_started_at: u40, new_header: types.SessionHeader) !void {
        assert(self.env != null);
        assert(id > 0); // Session IDs start at 1.
        assert(new_header.started_at > 0);
        // New status must differ or be a re-write of the same terminal status.
        assert(old_status == .running or new_header.status != .running);

        var txn: ?*c.MDB_txn = null;
        try check(c.mdb_txn_begin(self.env, null, 0, &txn));
        errdefer c.mdb_txn_abort(txn);

        // Update primary record header
        const key = types.SessionKey{ .id = id };
        var key_bytes = key.toBytes();
        var key_val = mkValBytes(&key_bytes);
        var data_val: c.MDB_val = undefined;

        try check(c.mdb_get(txn, self.sessions, &key_val, &data_val));

        // Copy old value into local buffer, update header, then put back.
        // mdb_get returns a read-only mmap pointer — cannot write in place.
        // Session values: 48-byte header + len-prefixed strings. Typical ~300 bytes.
        // 8192 accommodates pathological cases (long paths + diff summary).
        var buf: [8192]u8 = undefined;
        const old_ptr: [*]const u8 = @ptrCast(data_val.mv_data);
        const old_size = data_val.mv_size;
        if (old_size > buf.len) return error.LmdbBadValSize;
        @memcpy(buf[0..old_size], old_ptr[0..old_size]);
        @memcpy(buf[0..@sizeOf(types.SessionHeader)], std.mem.asBytes(&new_header));
        var new_val: c.MDB_val = .{ .mv_size = old_size, .mv_data = @ptrCast(&buf) };
        try check(c.mdb_put(txn, self.sessions, &key_val, &new_val, 0));

        // Delete old status index entry
        var old_status_key = types.StatusIndexKey.init(old_status, @as(u64, old_started_at), id);
        var old_status_val = mkValSlice(old_status_key.toBytes());
        _ = c.mdb_del(txn, self.sessions_by_status, &old_status_val, null);

        // Insert new status index entry
        var new_status_key = types.StatusIndexKey.init(new_header.status, @as(u64, new_header.started_at), id);
        var new_status_val = mkValSlice(new_status_key.toBytes());
        var empty_val = mkValEmpty();
        try check(c.mdb_put(txn, self.sessions_by_status, &new_status_val, &empty_val, 0));

        try check(c.mdb_txn_commit(txn));
    }

    /// Write a JSON representation of a session to the meta sub-database.
    /// The dashboard reads these directly via lmdb-js.
    // -- Event operations --

    pub fn insertEvent(self: *Store, txn: ?*c.MDB_txn, session_id: u64, seq: u32, header: types.EventHeader, raw_json: []const u8) !void {
        assert(txn != null);
        assert(session_id > 0);
        assert(raw_json.len > 0);

        const key = types.EventKey{ .session_id = session_id, .seq = seq };
        var key_bytes = key.toBytes();
        var key_val = mkValBytes(&key_bytes);

        const value_len = @sizeOf(types.EventHeader) + raw_json.len;
        var data_val: c.MDB_val = .{ .mv_size = value_len, .mv_data = null };
        try check(c.mdb_put(txn, self.events, &key_val, &data_val, c.MDB_RESERVE));

        const buf: [*]u8 = @ptrCast(data_val.mv_data);
        @memcpy(buf[0..@sizeOf(types.EventHeader)], std.mem.asBytes(&header));
        @memcpy(buf[@sizeOf(types.EventHeader)..][0..raw_json.len], raw_json);
    }

    pub fn iterSessionEvents(self: *Store, txn: ?*c.MDB_txn, session_id: u64) !EventIterator {
        var cursor: ?*c.MDB_cursor = null;
        try check(c.mdb_cursor_open(txn, self.events, &cursor));

        const start_key = types.EventKey{ .session_id = session_id, .seq = 0 };
        var key_bytes = start_key.toBytes();
        var key_val = mkValBytes(&key_bytes);
        var data_val: c.MDB_val = undefined;

        const rc = c.mdb_cursor_get(cursor, &key_val, &data_val, c.MDB_SET_RANGE);
        if (rc == c.MDB_NOTFOUND) {
            return .{ .cursor = cursor, .session_id = session_id, .exhausted = true };
        }
        if (rc != 0) {
            c.mdb_cursor_close(cursor);
            return lmdbError(rc);
        }

        // Check if the first result is for our session
        if (key_val.mv_size >= 8) {
            const found_key_ptr: *const [12]u8 = @ptrCast(@alignCast(key_val.mv_data));
            const found = types.EventKey.fromBytes(found_key_ptr);
            if (found.session_id != session_id) {
                return .{ .cursor = cursor, .session_id = session_id, .exhausted = true };
            }
        }

        return .{ .cursor = cursor, .session_id = session_id, .exhausted = false, .first_key = key_val, .first_data = data_val, .has_first = true };
    }

    pub const EventIterator = struct {
        cursor: ?*c.MDB_cursor,
        session_id: u64,
        exhausted: bool,
        first_key: c.MDB_val = undefined,
        first_data: c.MDB_val = undefined,
        has_first: bool = false,

        pub fn next(self: *EventIterator) ?types.EventView {
            if (self.exhausted) return null;

            var key_val: c.MDB_val = undefined;
            var data_val: c.MDB_val = undefined;

            if (self.has_first) {
                key_val = self.first_key;
                data_val = self.first_data;
                self.has_first = false;
            } else {
                const rc = c.mdb_cursor_get(self.cursor, &key_val, &data_val, c.MDB_NEXT);
                if (rc == c.MDB_NOTFOUND) {
                    self.exhausted = true;
                    return null;
                }
                if (rc != 0) {
                    self.exhausted = true;
                    return null;
                }
            }

            if (key_val.mv_size < 12) {
                self.exhausted = true;
                return null;
            }
            const key_ptr: *const [12]u8 = @ptrCast(@alignCast(key_val.mv_data));
            const ek = types.EventKey.fromBytes(key_ptr);
            if (ek.session_id != self.session_id) {
                self.exhausted = true;
                return null;
            }

            const data_ptr: [*]const u8 = @ptrCast(data_val.mv_data);
            const data_slice = data_ptr[0..data_val.mv_size];

            // Pair assertion: event value must hold at least the EventHeader.
            assert(data_val.mv_size >= @sizeOf(types.EventHeader));

            // Copy header bytes to avoid alignment issues with LMDB pointers
            var header: types.EventHeader = undefined;
            @memcpy(std.mem.asBytes(&header), data_slice[0..@sizeOf(types.EventHeader)]);

            return .{
                .seq = ek.seq,
                .header = header,
                .raw_json = data_slice[@sizeOf(types.EventHeader)..],
            };
        }

        pub fn close(self: *EventIterator) void {
            if (self.cursor) |cur| {
                c.mdb_cursor_close(cur);
                self.cursor = null;
            }
        }
    };

    // -- Review operations --

    pub fn insertReview(self: *Store, txn: ?*c.MDB_txn, worker_session_id: u64, header: types.ReviewHeader, reason: []const u8) !void {
        const key = types.SessionKey{ .id = worker_session_id };
        var key_bytes = key.toBytes();
        var key_val = mkValBytes(&key_bytes);

        const value_len = @sizeOf(types.ReviewHeader) + reason.len;
        var data_val: c.MDB_val = .{ .mv_size = value_len, .mv_data = null };
        try check(c.mdb_put(txn, self.reviews, &key_val, &data_val, c.MDB_RESERVE));

        const buf: [*]u8 = @ptrCast(data_val.mv_data);
        @memcpy(buf[0..@sizeOf(types.ReviewHeader)], std.mem.asBytes(&header));
        @memcpy(buf[@sizeOf(types.ReviewHeader)..][0..reason.len], reason);
    }

    pub fn getReview(self: *Store, txn: ?*c.MDB_txn, worker_session_id: u64) !?types.ReviewView {
        const key = types.SessionKey{ .id = worker_session_id };
        var key_bytes = key.toBytes();
        var key_val = mkValBytes(&key_bytes);
        var data_val: c.MDB_val = undefined;

        const rc = c.mdb_get(txn, self.reviews, &key_val, &data_val);
        if (rc == c.MDB_NOTFOUND) return null;
        if (rc != 0) return lmdbError(rc);

        const ptr: [*]const u8 = @ptrCast(data_val.mv_data);
        return types.ReviewView.fromBytes(ptr[0..data_val.mv_size]);
    }

    // -- Task operations --

    pub fn upsertTask(self: *Store, txn: ?*c.MDB_txn, name: []const u8, header: types.TaskHeader, prompt: []const u8) !void {
        assert(txn != null);
        assert(name.len > 0);
        assert(name.len <= std.math.maxInt(u16)); // Must fit in length-prefixed encoding.
        assert(prompt.len <= std.math.maxInt(u16));

        var key_val = mkValSlice(name);
        const value_size = types.taskValueSize(prompt);
        var data_val: c.MDB_val = .{ .mv_size = value_size, .mv_data = null };
        try check(c.mdb_put(txn, self.tasks, &key_val, &data_val, c.MDB_RESERVE));

        const buf: [*]u8 = @ptrCast(data_val.mv_data);
        const dest = buf[0..value_size];
        @memcpy(dest[0..@sizeOf(types.TaskHeader)], std.mem.asBytes(&header));
        var offset: usize = @sizeOf(types.TaskHeader);
        types.writeLenPrefixed(dest, &offset, prompt);
    }

    pub fn getTask(self: *Store, txn: ?*c.MDB_txn, name: []const u8) !?types.TaskView {
        assert(name.len > 0);

        var key_val = mkValSlice(name);
        var data_val: c.MDB_val = undefined;

        const rc = c.mdb_get(txn, self.tasks, &key_val, &data_val);
        if (rc == c.MDB_NOTFOUND) return null;
        if (rc != 0) return lmdbError(rc);

        // Pair assertion: value must hold at least the TaskHeader.
        if (data_val.mv_size < @sizeOf(types.TaskHeader)) return null;

        const ptr: [*]const u8 = @ptrCast(data_val.mv_data);
        return types.TaskView.fromBytes(ptr[0..data_val.mv_size]);
    }

    pub fn incrementTaskStat(self: *Store, txn: ?*c.MDB_txn, name: []const u8, field: enum { total_runs, accepted, rejected, empty }) !void {
        assert(txn != null);
        assert(name.len > 0);

        var key_val = mkValSlice(name);
        var data_val: c.MDB_val = undefined;

        const rc = c.mdb_get(txn, self.tasks, &key_val, &data_val);
        if (rc == c.MDB_NOTFOUND) return;
        if (rc != 0) return lmdbError(rc);
        if (data_val.mv_size < @sizeOf(types.TaskHeader)) return;

        // Copy full value (header + prompt) to local buffer
        // 64KB is more than enough for any task (prompts are typically < 1KB)
        var buf: [65536]u8 = undefined;
        const size = data_val.mv_size;
        if (size > buf.len) return error.LmdbBadValSize;
        const src: [*]const u8 = @ptrCast(data_val.mv_data);
        @memcpy(buf[0..size], src[0..size]);

        // Modify header field
        var header: types.TaskHeader = undefined;
        @memcpy(std.mem.asBytes(&header), buf[0..@sizeOf(types.TaskHeader)]);

        switch (field) {
            .total_runs => header.total_runs +|= 1,
            .accepted => header.accepted +|= 1,
            .rejected => header.rejected +|= 1,
            .empty => header.empty +|= 1,
        }

        @memcpy(buf[0..@sizeOf(types.TaskHeader)], std.mem.asBytes(&header));

        var new_data_val: c.MDB_val = .{ .mv_size = size, .mv_data = @ptrCast(&buf) };
        try check(c.mdb_put(txn, self.tasks, &key_val, &new_data_val, 0));
    }

    pub fn deleteTask(self: *Store, txn: ?*c.MDB_txn, name: []const u8) !void {
        var key_val = mkValSlice(name);
        const rc = c.mdb_del(txn, self.tasks, &key_val, null);
        if (rc != 0 and rc != c.MDB_NOTFOUND) return lmdbError(rc);
    }

    pub fn iterTasks(self: *Store, txn: ?*c.MDB_txn) !TaskIterator {
        var cursor: ?*c.MDB_cursor = null;
        try check(c.mdb_cursor_open(txn, self.tasks, &cursor));

        var key_val: c.MDB_val = undefined;
        var data_val: c.MDB_val = undefined;
        const rc = c.mdb_cursor_get(cursor, &key_val, &data_val, c.MDB_FIRST);
        if (rc == c.MDB_NOTFOUND) {
            return .{ .cursor = cursor, .exhausted = true };
        }
        if (rc != 0) {
            c.mdb_cursor_close(cursor);
            return lmdbError(rc);
        }

        return .{ .cursor = cursor, .exhausted = false, .first_key = key_val, .first_data = data_val, .has_first = true };
    }

    pub const TaskIterator = struct {
        cursor: ?*c.MDB_cursor,
        exhausted: bool,
        first_key: c.MDB_val = undefined,
        first_data: c.MDB_val = undefined,
        has_first: bool = false,

        pub const Entry = struct {
            name: []const u8,
            view: types.TaskView,
        };

        pub fn next(self: *TaskIterator) ?Entry {
            if (self.exhausted) return null;

            var key_val: c.MDB_val = undefined;
            var data_val: c.MDB_val = undefined;

            if (self.has_first) {
                key_val = self.first_key;
                data_val = self.first_data;
                self.has_first = false;
            } else {
                const rc = c.mdb_cursor_get(self.cursor, &key_val, &data_val, c.MDB_NEXT);
                if (rc == c.MDB_NOTFOUND) {
                    self.exhausted = true;
                    return null;
                }
                if (rc != 0) {
                    self.exhausted = true;
                    return null;
                }
            }

            if (data_val.mv_size < @sizeOf(types.TaskHeader)) {
                return self.next();
            }

            const key_ptr: [*]const u8 = @ptrCast(key_val.mv_data);
            const data_ptr: [*]const u8 = @ptrCast(data_val.mv_data);

            return .{
                .name = key_ptr[0..key_val.mv_size],
                .view = types.TaskView.fromBytes(data_ptr[0..data_val.mv_size]),
            };
        }

        pub fn close(self: *TaskIterator) void {
            if (self.cursor) |cur| {
                c.mdb_cursor_close(cur);
                self.cursor = null;
            }
        }
    };

    pub fn iterSessions(self: *Store, txn: ?*c.MDB_txn) !SessionIterator {
        var cursor: ?*c.MDB_cursor = null;
        try check(c.mdb_cursor_open(txn, self.sessions, &cursor));

        var key_val: c.MDB_val = undefined;
        var data_val: c.MDB_val = undefined;
        const rc = c.mdb_cursor_get(cursor, &key_val, &data_val, c.MDB_FIRST);
        if (rc == c.MDB_NOTFOUND) {
            return .{ .cursor = cursor, .exhausted = true };
        }
        if (rc != 0) {
            c.mdb_cursor_close(cursor);
            return lmdbError(rc);
        }

        return .{ .cursor = cursor, .exhausted = false, .first_key = key_val, .first_data = data_val, .has_first = true };
    }

    pub const SessionIterator = struct {
        cursor: ?*c.MDB_cursor,
        exhausted: bool,
        first_key: c.MDB_val = undefined,
        first_data: c.MDB_val = undefined,
        has_first: bool = false,

        pub const Entry = struct {
            id: u64,
            view: types.SessionView,
        };

        pub fn next(self: *SessionIterator) ?Entry {
            if (self.exhausted) return null;

            var key_val: c.MDB_val = undefined;
            var data_val: c.MDB_val = undefined;

            if (self.has_first) {
                key_val = self.first_key;
                data_val = self.first_data;
                self.has_first = false;
            } else {
                const rc = c.mdb_cursor_get(self.cursor, &key_val, &data_val, c.MDB_NEXT);
                if (rc == c.MDB_NOTFOUND) {
                    self.exhausted = true;
                    return null;
                }
                if (rc != 0) {
                    self.exhausted = true;
                    return null;
                }
            }

            if (key_val.mv_size < 8) {
                self.exhausted = true;
                return null;
            }

            const key_ptr: *const [8]u8 = @ptrCast(@alignCast(key_val.mv_data));
            const sk = types.SessionKey.fromBytes(key_ptr);

            const data_ptr: [*]const u8 = @ptrCast(data_val.mv_data);

            return .{
                .id = sk.id,
                .view = types.SessionView.fromBytes(data_ptr[0..data_val.mv_size]),
            };
        }

        pub fn close(self: *SessionIterator) void {
            if (self.cursor) |cur| {
                c.mdb_cursor_close(cur);
                self.cursor = null;
            }
        }
    };

    /// Mark all sessions with status "running" as "error".
    /// Called on daemon startup and from CLI maintenance commands.
    pub fn cleanupStaleSessions(self: *Store) u32 {
        const read_txn = self.beginReadTxn() catch return 0;
        defer abortTxn(read_txn);

        var iter = self.iterSessions(read_txn) catch return 0;
        defer iter.close();

        var stale_ids: [1024]u64 = undefined;
        var stale_headers: [1024]types.SessionHeader = undefined;
        var count: usize = 0;

        while (iter.next()) |entry| {
            if (entry.view.header.status == .running and count < 1024) {
                stale_ids[count] = entry.id;
                stale_headers[count] = entry.view.header;
                count += 1;
            }
        }

        for (0..count) |i| {
            var h = stale_headers[i];
            const old_status = h.status;
            const old_started_at = h.started_at;
            h.status = .err;
            if (h.finished_at == 0) {
                var ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(.REALTIME, &ts);
                h.finished_at = @truncate(@as(u64, @intCast(ts.sec)));
            }
            self.updateSessionStatus(stale_ids[i], old_status, old_started_at, h) catch {};
        }
        return @intCast(count);
    }

    // -- Transaction helpers --

    pub fn beginReadTxn(self: *Store) !?*c.MDB_txn {
        var txn: ?*c.MDB_txn = null;
        try check(c.mdb_txn_begin(self.env, null, c.MDB_RDONLY, &txn));
        return txn;
    }

    pub fn beginWriteTxn(self: *Store) !?*c.MDB_txn {
        var txn: ?*c.MDB_txn = null;
        try check(c.mdb_txn_begin(self.env, null, 0, &txn));
        return txn;
    }

    pub fn commitTxn(txn: ?*c.MDB_txn) !void {
        try check(c.mdb_txn_commit(txn));
    }

    pub fn abortTxn(txn: ?*c.MDB_txn) void {
        c.mdb_txn_abort(txn);
    }

    // -- Daily stats --

    pub const DailyStats = struct {
        total: u32 = 0,
        accepted: u32 = 0,
        rejected: u32 = 0,
        conflicts: u32 = 0,
        build_failures: u32 = 0,
        errors: u32 = 0,
        total_cost_cents: u64 = 0,
    };

    pub fn getDailyStats(self: *Store, txn: ?*c.MDB_txn, day_start_ts: u64) !DailyStats {
        var stats = DailyStats{};
        var cursor: ?*c.MDB_cursor = null;
        try check(c.mdb_cursor_open(txn, self.sessions_by_time, &cursor));
        defer c.mdb_cursor_close(cursor);

        var start = types.TimeIndexKey.init(day_start_ts, 0, .worker);
        var key_val = mkValSlice(start.toBytes());
        var data_val: c.MDB_val = undefined;

        var rc = c.mdb_cursor_get(cursor, &key_val, &data_val, c.MDB_SET_RANGE);
        while (rc == 0) {
            if (key_val.mv_size < 9) break;
            stats.total += 1;

            // Look up session to get status and cost
            const time_key_ptr: *const [9]u8 = @ptrCast(@alignCast(key_val.mv_data));
            const time_key: *const types.TimeIndexKey = @ptrCast(time_key_ptr);
            const sid: u64 = @as(u64, time_key.sessionId());

            if (try self.getSession(txn, sid)) |session| {
                switch (session.header.status) {
                    .merged => stats.accepted += 1,
                    .rejected => stats.rejected += 1,
                    .conflict_status => stats.conflicts += 1,
                    .build_failed => stats.build_failures += 1,
                    .err => stats.errors += 1,
                    .running, .done => {},
                }
                stats.total_cost_cents += @as(u64, session.header.cost_microdollars) / 10000;
            }

            rc = c.mdb_cursor_get(cursor, &key_val, &data_val, c.MDB_NEXT);
        }

        return stats;
    }
};

// === LMDB helpers ===

fn openDbi(txn: ?*c.MDB_txn, name: [*:0]const u8) !c.MDB_dbi {
    var dbi: c.MDB_dbi = undefined;
    try check(c.mdb_dbi_open(txn, name, c.MDB_CREATE, &dbi));
    return dbi;
}

fn mkVal(s: anytype) c.MDB_val {
    return .{
        .mv_size = s.len,
        .mv_data = @ptrCast(@constCast(s.ptr)),
    };
}

fn mkValBytes(bytes: anytype) c.MDB_val {
    return .{
        .mv_size = bytes.len,
        .mv_data = @ptrCast(bytes),
    };
}

fn mkValSlice(s: anytype) c.MDB_val {
    return .{
        .mv_size = s.len,
        .mv_data = @ptrCast(@constCast(s.ptr)),
    };
}

fn mkValEmpty() c.MDB_val {
    const dummy = struct {
        var byte: u8 = 0;
    };
    return .{ .mv_size = 0, .mv_data = @ptrCast(&dummy.byte) };
}

pub const LmdbError = error{
    LmdbKeyExists,
    LmdbNotFound,
    LmdbPageNotFound,
    LmdbCorrupted,
    LmdbPanic,
    LmdbVersionMismatch,
    LmdbInvalid,
    LmdbMapFull,
    LmdbDbsFull,
    LmdbReadersFull,
    LmdbTlsFull,
    LmdbTxnFull,
    LmdbCursorFull,
    LmdbPageFull,
    LmdbMapResized,
    LmdbIncompatible,
    LmdbBadRslot,
    LmdbBadTxn,
    LmdbBadValSize,
    LmdbBadDbi,
    LmdbUnknown,
    PathTooLong,
};

fn lmdbError(rc: c_int) LmdbError {
    return switch (rc) {
        c.MDB_KEYEXIST => error.LmdbKeyExists,
        c.MDB_NOTFOUND => error.LmdbNotFound,
        c.MDB_PAGE_NOTFOUND => error.LmdbPageNotFound,
        c.MDB_CORRUPTED => error.LmdbCorrupted,
        c.MDB_PANIC => error.LmdbPanic,
        c.MDB_VERSION_MISMATCH => error.LmdbVersionMismatch,
        c.MDB_INVALID => error.LmdbInvalid,
        c.MDB_MAP_FULL => error.LmdbMapFull,
        c.MDB_DBS_FULL => error.LmdbDbsFull,
        c.MDB_READERS_FULL => error.LmdbReadersFull,
        c.MDB_TLS_FULL => error.LmdbTlsFull,
        c.MDB_TXN_FULL => error.LmdbTxnFull,
        c.MDB_CURSOR_FULL => error.LmdbCursorFull,
        c.MDB_PAGE_FULL => error.LmdbPageFull,
        c.MDB_MAP_RESIZED => error.LmdbMapResized,
        c.MDB_INCOMPATIBLE => error.LmdbIncompatible,
        c.MDB_BAD_RSLOT => error.LmdbBadRslot,
        c.MDB_BAD_TXN => error.LmdbBadTxn,
        c.MDB_BAD_VALSIZE => error.LmdbBadValSize,
        c.MDB_BAD_DBI => error.LmdbBadDbi,
        else => error.LmdbUnknown,
    };
}

fn check(rc: c_int) LmdbError!void {
    if (rc != 0) return lmdbError(rc);
}

test "store open and close" {
    const tmp_dir = "/tmp/bees-test-store";
    _ = std.c.mkdir(tmp_dir, 0o755);
    defer {
        _ = std.c.unlink(tmp_dir ++ "/data.mdb");
        _ = std.c.unlink(tmp_dir ++ "/lock.mdb");
        _ = std.c.rmdir(tmp_dir);
    }

    var store = try Store.open(tmp_dir);
    defer store.close();
}

test "store create and get session" {
    const tmp_dir = "/tmp/bees-test-session";
    _ = std.c.mkdir(tmp_dir, 0o755);
    defer {
        _ = std.c.unlink(tmp_dir ++ "/data.mdb");
        _ = std.c.unlink(tmp_dir ++ "/lock.mdb");
        _ = std.c.rmdir(tmp_dir);
    }

    var store = try Store.open(tmp_dir);
    defer store.close();

    const header = types.SessionHeader{
        .type = .worker,
        .status = .running,
        .has_exit_code = false,
        .has_cost = false,
        .model = .opus,
        .has_tokens = false,
        .has_duration = false,
        .has_diff_summary = false,
        .worker_id = 1,
        .commit_count = 0,
        .num_turns = 0,
        .exit_code = 0,
        .started_at = 1709856000,
        .finished_at = 0,
        .duration_ms = 0,
        .cost_microdollars = 0,
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
    };

    const id = try store.createSession(header, "Bug hunt", "bee/test/worker-1", "/tmp/worktree");
    try std.testing.expectEqual(@as(u64, 1), id);

    const txn = try store.beginReadTxn();
    defer Store.abortTxn(txn);

    const session = (try store.getSession(txn, id)).?;
    try std.testing.expectEqualStrings("Bug hunt", session.task);
    try std.testing.expectEqualStrings("bee/test/worker-1", session.branch);
    try std.testing.expectEqual(types.SessionType.worker, session.header.type);
    try std.testing.expectEqual(types.SessionStatus.running, session.header.status);
}

test "store insert and iterate events" {
    const tmp_dir = "/tmp/bees-test-events";
    _ = std.c.mkdir(tmp_dir, 0o755);
    defer {
        _ = std.c.unlink(tmp_dir ++ "/data.mdb");
        _ = std.c.unlink(tmp_dir ++ "/lock.mdb");
        _ = std.c.rmdir(tmp_dir);
    }

    var store = try Store.open(tmp_dir);
    defer store.close();

    const session_id: u64 = 1;
    const json1 = "{\"type\":\"init\"}";
    const json2 = "{\"type\":\"message\"}";

    {
        const txn = try store.beginWriteTxn();
        errdefer Store.abortTxn(txn);

        const h1 = types.EventHeader{
            .event_type = .init_event,
            .tool_name = .none,
            .role = .none,
            .timestamp_offset_ms = 0,
        };
        try store.insertEvent(txn, session_id, 0, h1, json1);

        const h2 = types.EventHeader{
            .event_type = .message,
            .tool_name = .none,
            .role = .assistant,
            .timestamp_offset_ms = 100,
        };
        try store.insertEvent(txn, session_id, 1, h2, json2);
        try Store.commitTxn(txn);
    }

    {
        const txn = try store.beginReadTxn();
        defer Store.abortTxn(txn);

        var iter = try store.iterSessionEvents(txn, session_id);
        defer iter.close();

        const ev1 = iter.next().?;
        try std.testing.expectEqual(@as(u32, 0), ev1.seq);
        try std.testing.expectEqual(types.EventType.init_event, ev1.header.event_type);
        try std.testing.expectEqualStrings(json1, ev1.raw_json);

        const ev2 = iter.next().?;
        try std.testing.expectEqual(@as(u32, 1), ev2.seq);
        try std.testing.expectEqual(types.EventType.message, ev2.header.event_type);

        try std.testing.expectEqual(@as(?types.EventView, null), iter.next());
    }
}

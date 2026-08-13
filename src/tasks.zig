const std = @import("std");
const assert = std.debug.assert;
const fs = @import("fs.zig");
const types = @import("types.zig");
const store_mod = @import("store.zig");

var select_counter: u64 = 0;

pub const Task = struct {
    name: []const u8,
    weight: u32,
    prompt: []const u8,
    cumulative: u32,
};

/// Selection weight for a task that has already delivered something.
///
/// A task retires once a later run finds nothing left to do (`isExhausted`),
/// so the pool deliberately pays one session to confirm completion. At full
/// weight that confirmation competes with undelivered work and gets drawn
/// early: on chatplugin a delivered task was re-picked and spent $4.82 to
/// report there was nothing to do, while four untouched tasks waited.
///
/// Demoting keeps the confirmation — it still happens, and still retires the
/// task — but lets fresh work go first, so the cost lands when the swarm would
/// otherwise be idle rather than instead of real progress.
fn deliveredWeight(header: types.TaskHeader) u32 {
    const w: u32 = @as(u32, header.weight);
    if (header.accepted == 0) return w;
    return @max(1, w / 4);
}

pub const TaskPool = struct {
    tasks: []Task,
    total_weight: u32,

    /// Load tasks from JSON file (backward compatible path).
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !TaskPool {
        const data = try fs.readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(data);

        const JsonTask = struct {
            name: []const u8,
            weight: u32,
            prompt: []const u8,
        };

        const parsed = try std.json.parseFromSlice([]const JsonTask, allocator, data, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        const items = parsed.value;

        var tasks = try allocator.alloc(Task, items.len);
        var cumulative: u32 = 0;
        for (items, 0..) |item, i| {
            cumulative += item.weight;
            tasks[i] = .{
                .name = try allocator.dupe(u8, item.name),
                .weight = item.weight,
                .prompt = try allocator.dupe(u8, item.prompt),
                .cumulative = cumulative,
            };
        }

        return .{
            .tasks = tasks,
            .total_weight = cumulative,
        };
    }

    /// Load tasks from LMDB. Skips completed/retired tasks, and exhausted ones
    /// that syncFromJson has not yet persisted as retired.
    pub fn loadFromStore(store: *store_mod.Store, allocator: std.mem.Allocator) !TaskPool {
        const txn = try store.beginReadTxn();
        defer store_mod.Store.abortTxn(txn);

        // First pass: count active tasks
        var count: usize = 0;
        {
            var iter = try store.iterTasks(txn);
            defer iter.close();
            while (iter.next()) |entry| {
                if (entry.view.header.status != .active) continue;
                if (entry.view.header.weight == 0) continue;
                if (entry.view.header.isExhausted()) continue;
                count += 1;
            }
        }

        // Second pass: build pool
        var tasks = try allocator.alloc(Task, count);
        var cumulative: u32 = 0;
        var idx: usize = 0;
        {
            var iter = try store.iterTasks(txn);
            defer iter.close();
            while (iter.next()) |entry| {
                if (entry.view.header.status != .active) continue;
                if (entry.view.header.weight == 0) continue;
                if (entry.view.header.isExhausted()) continue;
                if (idx >= count) break;

                const w: u32 = deliveredWeight(entry.view.header);
                cumulative += w;
                tasks[idx] = .{
                    .name = try allocator.dupe(u8, entry.name),
                    .weight = w,
                    .prompt = try allocator.dupe(u8, entry.view.prompt),
                    .cumulative = cumulative,
                };
                idx += 1;
            }
        }

        return .{
            .tasks = tasks[0..idx],
            .total_weight = cumulative,
        };
    }

    /// Free all owned memory. Only call on pools created by loadFromStore
    /// (which dupes strings). Pools from load() alias into the JSON parse
    /// buffer and must not be individually freed.
    pub fn deinit(self: *TaskPool, allocator: std.mem.Allocator) void {
        for (self.tasks) |t| {
            allocator.free(t.name);
            allocator.free(t.prompt);
        }
        allocator.free(self.tasks);
        self.tasks = &.{};
        self.total_weight = 0;
    }

    pub fn hasActiveTasks(self: *const TaskPool) bool {
        return self.total_weight > 0;
    }

    /// Select a task, weight-proportionally over `cumulative`. The draw is
    /// derived from a hashed monotonic counter, so consecutive calls within a
    /// batch land in different weight bands instead of repeating one task.
    ///
    /// LIFETIME: the returned pointer aliases `self.tasks`, which the main
    /// loop's reloadPool can free. Callers MUST copy any fields they need
    /// (name/prompt) before the next suspension point — the pool may be gone
    /// after that. Workers do this immediately (see worker.zig).
    pub fn select(self: *const TaskPool) ?*const Task {
        if (self.tasks.len == 0) return null;
        if (self.total_weight == 0) return null;

        const counter = @atomicRmw(u64, &select_counter, .Add, 1, .monotonic);
        // Hash the counter so consecutive calls land in different weight
        // bands, then pick the first task whose cumulative weight exceeds it.
        const r: u32 = @intCast((counter *% 0x9E3779B97F4A7C15 >> 32) % self.total_weight);

        var lo: usize = 0;
        var hi: usize = self.tasks.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.tasks[mid].cumulative <= r) lo = mid + 1 else hi = mid;
        }

        const task = &self.tasks[lo];
        assert(task.name.len > 0);
        assert(task.prompt.len > 0);
        return task;
    }

    /// Select a task no other in-flight worker is already running, and claim it.
    ///
    /// Weight-proportional selection alone repeats: three workers drawing from
    /// three tasks put two on the same one, the merger rejected the loser as
    /// redundant, and 47% of that cycle's spend bought nothing. The collision
    /// rate rises with worker count, so parallelism made it worse — the fix has
    /// to be a claim, not a better hash.
    ///
    /// Returns null when every task is already claimed: paying for known
    /// duplicate work is worse than running fewer workers. Deliberate
    /// best-of-N, if we ever want it, should be an explicit fan-out rather than
    /// an accident of the draw.
    ///
    /// The caller MUST `release` the returned task's name when its session
    /// ends. Claims are process-local by design: a daemon that dies takes its
    /// in-flight workers with it, and the pool is rebuilt on the next start.
    pub fn selectUnclaimed(self: *const TaskPool) ?*const Task {
        if (self.tasks.len == 0 or self.total_weight == 0) return null;

        claims_lock.lock();
        defer claims_lock.unlock();

        // Try the weighted draw first so selection keeps honouring weights,
        // then fall back to a scan so a claimed-heavy pool still finds work.
        var attempt: usize = 0;
        while (attempt < 8) : (attempt += 1) {
            const task = self.select() orelse return null;
            if (claimUnlocked(task.name)) return task;
        }
        for (self.tasks) |*task| {
            if (claimUnlocked(task.name)) return task;
        }
        return null;
    }

    /// Drop a claim taken by `selectUnclaimed`. Safe to call with a name that
    /// is not claimed, so callers can `defer` it unconditionally.
    pub fn release(name: []const u8) void {
        claims_lock.lock();
        defer claims_lock.unlock();
        var buf: [max_claim_name]u8 = undefined;
        const key = canonical(&buf, name);
        for (&claims) |*slot| {
            if (slot.len > 0 and std.mem.eql(u8, slot.slice(), key)) {
                slot.len = 0;
                return;
            }
        }
    }

    /// Number of tasks currently claimed. For tests and status reporting.
    pub fn claimedCount() usize {
        claims_lock.lock();
        defer claims_lock.unlock();
        var n: usize = 0;
        for (claims) |slot| {
            if (slot.len > 0) n += 1;
        }
        return n;
    }

    /// Test-only: forget every claim, so one test's leftovers cannot fail the
    /// next. Not for production use — a real release happens per session.
    pub fn resetClaims() void {
        claims_lock.lock();
        defer claims_lock.unlock();
        for (&claims) |*slot| slot.len = 0;
    }
};

/// Claims are compared canonically, so "Fix the parser" and "fix the parser!"
/// are one task — the same rule the pool already uses for duplicate detection.
const max_claim_name = 96;
const ClaimSlot = struct {
    buf: [max_claim_name]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const ClaimSlot) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Sized to the worker ceiling: a claim exists only while a session runs.
var claims: [64]ClaimSlot = @splat(.{});
var claims_lock: Mutex = .{};

const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},

    fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

/// Caller holds `claims_lock`. False when the task is already claimed or there
/// is no free slot — both mean "do not run this now".
fn claimUnlocked(name: []const u8) bool {
    var buf: [max_claim_name]u8 = undefined;
    const key = canonical(&buf, name);
    if (key.len == 0) return false;

    var free_slot: ?*ClaimSlot = null;
    for (&claims) |*slot| {
        if (slot.len == 0) {
            if (free_slot == null) free_slot = slot;
            continue;
        }
        if (std.mem.eql(u8, slot.slice(), key)) return false;
    }
    const slot = free_slot orelse return false;
    @memcpy(slot.buf[0..key.len], key);
    slot.len = key.len;
    return true;
}

/// Canonical form for duplicate detection: lowercase, drop non-alphanumerics,
/// collapse runs to single spaces. Writes into `buf`, returns the used slice.
fn canonical(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    var pending_space = false;
    for (name) |ch| {
        const c = std.ascii.toLower(ch);
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_space and n > 0 and n < buf.len) {
                buf[n] = ' ';
                n += 1;
            }
            pending_space = false;
            if (n >= buf.len) break;
            buf[n] = c;
            n += 1;
        } else {
            pending_space = true;
        }
    }
    return buf[0..n];
}

/// True if a session is still running against `name`, or has finished but not
/// yet been resolved by the merger (its accept/reject credit is still pending).
/// A `.done` session is work the merger has not yet resolved to merged/rejected.
/// Sessions the merger never resolves would otherwise block their task's
/// retirement forever, so `.done` only counts as pending while it is still
/// plausibly in flight.
const pending_done_window_secs: u64 = 24 * 60 * 60;

fn hasPendingSession(store: *store_mod.Store, txn: anytype, name: []const u8) bool {
    const now = fs.timestamp();
    var iter = store.iterSessions(txn) catch return false;
    defer iter.close();
    while (iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.view.task, name)) continue;
        switch (entry.view.header.status) {
            .running => return true,
            .done => {
                const finished: u64 = entry.view.header.finished_at;
                if (now -| finished < pending_done_window_secs) return true;
            },
            .merged, .rejected, .conflict_status, .build_failed, .err => {},
        }
    }
    return false;
}

/// Reconcile a JSON tasks manifest into LMDB.
/// - Creates new tasks
/// - Updates weight/prompt for existing tasks (preserves stats), merging
///   re-spellings of a name into the row that already holds its history
/// - Retires tasks no longer in JSON (unless a session is still pending on them)
pub fn syncFromJson(
    store: *store_mod.Store,
    json_data: []const u8,
    origin: types.TaskOrigin,
    allocator: std.mem.Allocator,
) !void {
    assert(json_data.len > 0);

    const JsonTask = struct {
        name: []const u8,
        weight: u32,
        prompt: []const u8,
    };

    const parsed = try std.json.parseFromSlice([]const JsonTask, allocator, json_data, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const items = parsed.value;

    var txn = try store.beginWriteTxn();
    errdefer store_mod.Store.abortTxn(txn);

    // Collect existing task names before any writes
    var existing_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (existing_names.items) |name| allocator.free(name);
        existing_names.deinit(allocator);
    }
    {
        var iter = try store.iterTasks(txn);
        defer iter.close();
        while (iter.next()) |entry| {
            try existing_names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    // Which existing key each JSON item resolved to (aliases existing_names or item.name)
    var claimed: std.ArrayList([]const u8) = .empty;
    defer claimed.deinit(allocator);

    var key_buf: [256]u8 = undefined;
    var other_buf: [256]u8 = undefined;

    // Upsert all JSON tasks
    for (items) |item| {
        var key = item.name;
        const exact = try store.getTask(txn, item.name);
        if (exact == null) {
            // Re-spelling of a known task (backticks, case, punctuation) must
            // update the row holding its history, not fork a fresh one.
            const want = canonical(&key_buf, item.name);
            for (existing_names.items) |name| {
                if (std.mem.eql(u8, want, canonical(&other_buf, name))) {
                    std.log.warn("[tasks] duplicate spelling \"{s}\" merged into \"{s}\"", .{ item.name, name });
                    key = name;
                    break;
                }
            }
        }
        try claimed.append(allocator, key);

        const existing = try store.getTask(txn, key);
        if (existing) |view| {
            // Preserve stats, update weight + prompt; an exhausted task stays
            // retired instead of being resurrected every cycle.
            var header = view.header;
            header.weight = @truncate(item.weight);
            header.status = if (header.isExhausted()) .retired else .active;
            try store.upsertTask(txn, key, header, item.prompt);
        } else {
            // New task
            const header = types.TaskHeader{
                .weight = @truncate(item.weight),
                .total_runs = 0,
                .accepted = 0,
                .rejected = 0,
                .empty = 0,
                .status = .active,
                .origin = origin,
            };
            try store.upsertTask(txn, item.name, header, item.prompt);
        }
    }

    // Retire tasks not in JSON
    for (existing_names.items) |name| {
        var found = false;
        for (claimed.items) |key| {
            if (std.mem.eql(u8, name, key)) {
                found = true;
                break;
            }
        }
        // Never retire a task a worker is still running (or whose merge credit
        // is pending) — the accept would land on a row nothing reads.
        if (!found and !hasPendingSession(store, txn, name)) {
            if (try store.getTask(txn, name)) |view| {
                if (view.header.status == .active) {
                    var header = view.header;
                    header.status = .retired;
                    // Copy prompt before writing (same key invalidates old ptr)
                    const prompt_copy = try allocator.dupe(u8, view.prompt);
                    defer allocator.free(prompt_copy);
                    try store.upsertTask(txn, name, header, prompt_copy);
                }
            }
        }
    }

    // Write tasks JSON to meta for dashboard direct reads
    writeTasksMeta(store, txn, allocator) catch {};

    try store_mod.Store.commitTxnConsume(&txn);
}

/// Write a JSON array of all tasks to the meta sub-database.
fn writeTasksMeta(store: *store_mod.Store, txn: anytype, allocator: std.mem.Allocator) !void {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try json.append(allocator, '[');

    var iter = try store.iterTasks(txn);
    defer iter.close();
    var first = true;

    while (iter.next()) |entry| {
        if (!first) try json.append(allocator, ',');
        first = false;

        const h = entry.view.header;
        // Build JSON object — escape task name and prompt
        try json.appendSlice(allocator, "{\"name\":");
        try appendJsonStr(&json, allocator, entry.name);
        var stat_buf: [256]u8 = undefined;
        const stats = std.fmt.bufPrint(&stat_buf,
            \\,"weight":{d},"total_runs":{d},"accepted":{d},"rejected":{d},"empty":{d},"status":"{s}","origin":"{s}","prompt":
        , .{ h.weight, h.total_runs, h.accepted, h.rejected, h.empty, h.status.label(), h.origin.label() }) catch continue;
        try json.appendSlice(allocator, stats);
        try appendJsonStr(&json, allocator, entry.view.prompt);
        try json.append(allocator, '}');
    }

    try json.append(allocator, ']');
    try store.putMeta(txn, "tasks:all", json.items);
}

/// Append a JSON-escaped string (with quotes) to an ArrayList.
fn appendJsonStr(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (ch >= 0x20) {
                    try list.append(allocator, ch);
                }
            },
        }
    }
    try list.append(allocator, '"');
}

/// Sync tasks from JSON file into LMDB.
pub fn syncFromFile(
    store: *store_mod.Store,
    path: []const u8,
    origin: types.TaskOrigin,
    allocator: std.mem.Allocator,
) !void {
    const data = try fs.readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(data);
    try syncFromJson(store, data, origin, allocator);
}

test "delivered work is demoted, never dropped" {
    const base = types.TaskHeader{
        .weight = 8,
        .total_runs = 1,
        .accepted = 0,
        .rejected = 0,
        .empty = 0,
        .status = .active,
        .origin = .strategist,
    };
    // Untouched work keeps its full pull.
    try std.testing.expectEqual(@as(u32, 8), deliveredWeight(base));

    var delivered = base;
    delivered.accepted = 1;
    try std.testing.expectEqual(@as(u32, 2), deliveredWeight(delivered));

    // Never zero: the confirmation run must stay reachable, or the task can
    // never retire and lingers in the pool forever.
    var small = base;
    small.weight = 1;
    small.accepted = 3;
    try std.testing.expectEqual(@as(u32, 1), deliveredWeight(small));
}

test "task pool select is weight-proportional" {
    var pool = TaskPool{
        .tasks = @constCast(&[_]Task{
            .{ .name = "a", .weight = 1, .prompt = "pa", .cumulative = 1 },
            .{ .name = "b", .weight = 4, .prompt = "pb", .cumulative = 5 },
        }),
        .total_weight = 5,
    };

    var a: u32 = 0;
    var b: u32 = 0;
    for (0..1000) |_| {
        const task = pool.select() orelse unreachable;
        try std.testing.expect(task.name.len > 0);
        if (task.name[0] == 'a') a += 1 else b += 1;
    }
    // Expect ~200/800; allow generous slack for the hash's discrepancy.
    try std.testing.expect(a > 120 and a < 290);
    try std.testing.expect(b > 710 and b < 880);
}

test "a batch of workers never draws the same task twice" {
    // The regression this exists for: three workers, three tasks, two landed on
    // the heaviest one and the merger rejected the duplicate — 47% of that
    // cycle's spend bought nothing.
    TaskPool.resetClaims();
    defer TaskPool.resetClaims();
    var pool = TaskPool{
        .tasks = @constCast(&[_]Task{
            .{ .name = "light", .weight = 1, .prompt = "p", .cumulative = 1 },
            .{ .name = "heavy", .weight = 100, .prompt = "p", .cumulative = 101 },
            .{ .name = "middle", .weight = 10, .prompt = "p", .cumulative = 111 },
        }),
        .total_weight = 111,
    };

    var seen: [3][]const u8 = undefined;
    for (0..3) |i| {
        const t = pool.selectUnclaimed() orelse return error.TestUnexpectedResult;
        for (seen[0..i]) |prev| try std.testing.expect(!std.mem.eql(u8, prev, t.name));
        seen[i] = t.name;
    }
    // Every task is claimed; a fourth worker must idle rather than duplicate.
    try std.testing.expectEqual(@as(usize, 3), TaskPool.claimedCount());
    try std.testing.expect(pool.selectUnclaimed() == null);

    // Releasing one frees exactly that task, and only it.
    TaskPool.release(seen[1]);
    try std.testing.expectEqual(@as(usize, 2), TaskPool.claimedCount());
    const again = pool.selectUnclaimed() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(seen[1], again.name);
}

test "claims ignore spelling, and releasing an unheld task is harmless" {
    TaskPool.resetClaims();
    defer TaskPool.resetClaims();
    var pool = TaskPool{
        .tasks = @constCast(&[_]Task{
            .{ .name = "Fix the parser!", .weight = 1, .prompt = "p", .cumulative = 1 },
        }),
        .total_weight = 1,
    };
    _ = pool.selectUnclaimed() orelse return error.TestUnexpectedResult;
    // Same task, different spelling — must not be claimable twice.
    try std.testing.expect(!claimUnlocked("fix the parser"));
    // A defer that runs on a path which never claimed must not corrupt state.
    TaskPool.release("something never claimed");
    try std.testing.expectEqual(@as(usize, 1), TaskPool.claimedCount());
    TaskPool.release("  fix   the parser  ");
    try std.testing.expectEqual(@as(usize, 0), TaskPool.claimedCount());
}

test "canonical collapses spelling differences" {
    var buf: [256]u8 = undefined;
    var other: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        canonical(&buf, "Add `bees knowledge` CLI command"),
        canonical(&other, "add bees knowledge cli command"),
    );
    try std.testing.expectEqualStrings("add get api knowledge", canonical(&buf, "Add `GET /api/knowledge`"));
    try std.testing.expect(!std.mem.eql(
        u8,
        canonical(&buf, "task one"),
        canonical(&other, "task two"),
    ));
}

test "syncFromJson merges re-spellings and retires exhausted tasks" {
    const tmp_dir = "/tmp/bees-test-tasks-sync";
    _ = std.c.mkdir(tmp_dir, 0o755);
    defer {
        _ = std.c.unlink(tmp_dir ++ "/data.mdb");
        _ = std.c.unlink(tmp_dir ++ "/lock.mdb");
        _ = std.c.rmdir(tmp_dir);
    }

    var store = try store_mod.Store.open(tmp_dir);
    defer store.close();
    const allocator = std.testing.allocator;

    try syncFromJson(&store,
        \\[{"name":"Add `bees knowledge` CLI command","weight":3,"prompt":"p"}]
    , .strategist, allocator);

    // Accumulate failures on the original spelling.
    {
        var txn = try store.beginWriteTxn();
        errdefer store_mod.Store.abortTxn(txn);
        for (0..3) |_| {
            try store.incrementTaskStat(txn, "Add `bees knowledge` CLI command", .total_runs);
            try store.incrementTaskStat(txn, "Add `bees knowledge` CLI command", .empty);
        }
        try store_mod.Store.commitTxnConsume(&txn);
    }

    // Re-spelled by the strategist: must land on the same row, not a new one.
    try syncFromJson(&store,
        \\[{"name":"Add bees knowledge CLI command","weight":5,"prompt":"p2"}]
    , .strategist, allocator);

    const txn = try store.beginReadTxn();
    defer store_mod.Store.abortTxn(txn);

    var rows: u32 = 0;
    var iter = try store.iterTasks(txn);
    defer iter.close();
    while (iter.next()) |_| rows += 1;
    try std.testing.expectEqual(@as(u32, 1), rows);

    const view = (try store.getTask(txn, "Add `bees knowledge` CLI command")).?;
    try std.testing.expectEqual(@as(u24, 3), view.header.total_runs);
    try std.testing.expectEqual(@as(u16, 5), view.header.weight);
    try std.testing.expectEqualStrings("p2", view.prompt);
    // Exhausted (3 runs, 0 accepted, 3 empty) → persisted as retired, not
    // reactivated by the sync.
    try std.testing.expectEqual(types.TaskStatus.retired, view.header.status);
    try std.testing.expectEqual(types.TaskOrigin.strategist, view.header.origin);
}

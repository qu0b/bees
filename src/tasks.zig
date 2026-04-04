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

    /// Load tasks from LMDB. Skips completed/retired tasks.
    /// Auto-retires exhausted tasks (empty >= 3, accepted == 0, total_runs >= 3).
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
                // Auto-retire check (skip exhausted)
                if (isExhausted(entry.view.header)) continue;
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
                if (isExhausted(entry.view.header)) continue;
                if (idx >= count) break;

                const w: u32 = @as(u32, entry.view.header.weight);
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

    /// Select a task. Uses round-robin so consecutive calls within a
    /// batch always return different tasks (when batch size <= pool size).
    /// Weight still matters across cycles — higher-weight tasks appear
    /// more often in the rotation order.
    pub fn select(self: *const TaskPool) ?*const Task {
        if (self.tasks.len == 0) return null;
        if (self.total_weight == 0) return null;

        const counter = @atomicRmw(u64, &select_counter, .Add, 1, .monotonic);
        const idx = counter % self.tasks.len;
        const task = &self.tasks[@intCast(idx)];
        assert(task.name.len > 0);
        assert(task.prompt.len > 0);
        return task;
    }
};

/// Auto-retirement: a task is exhausted if it has been tried enough
/// times with no success.
fn isExhausted(header: types.TaskHeader) bool {
    return header.total_runs >= 3 and header.accepted == 0 and header.empty >= 3;
}

/// Reconcile a JSON tasks manifest into LMDB.
/// - Creates new tasks
/// - Updates weight/prompt for existing tasks (preserves stats)
/// - Retires tasks no longer in JSON
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

    const txn = try store.beginWriteTxn();
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

    // Upsert all JSON tasks
    for (items) |item| {
        const existing = try store.getTask(txn, item.name);
        if (existing) |view| {
            // Preserve stats, update weight + prompt + reactivate
            var header = view.header;
            header.weight = @truncate(item.weight);
            header.status = .active;
            try store.upsertTask(txn, item.name, header, item.prompt);
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
        for (items) |item| {
            if (std.mem.eql(u8, name, item.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
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

    try store_mod.Store.commitTxn(txn);
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
pub fn syncFromFile(store: *store_mod.Store, path: []const u8, allocator: std.mem.Allocator) !void {
    const data = try fs.readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(data);
    try syncFromJson(store, data, .template, allocator);
}

test "task pool select distribution" {
    var pool = TaskPool{
        .tasks = @constCast(&[_]Task{
            .{ .name = "a", .weight = 1, .prompt = "pa", .cumulative = 1 },
            .{ .name = "b", .weight = 1, .prompt = "pb", .cumulative = 2 },
        }),
        .total_weight = 2,
    };

    for (0..100) |_| {
        const task = pool.select() orelse unreachable;
        try std.testing.expect(task.name.len > 0);
    }
}

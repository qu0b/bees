const std = @import("std");
const fs = @import("fs.zig");
const types = @import("types.zig");
const store_mod = @import("store.zig");

var select_counter: u64 = 0;

pub const Approach = struct {
    name: []const u8,
    weight: u32,
    prompt: []const u8,
    cumulative: u32,
};

pub const ApproachPool = struct {
    approaches: []Approach,
    total_weight: u32,

    /// Load approaches from JSON file (backward compatible path).
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !ApproachPool {
        const data = try fs.readFileAlloc(allocator, path, 1024 * 1024);

        const JsonApproach = struct {
            name: []const u8,
            weight: u32,
            prompt: []const u8,
        };

        const parsed = try std.json.parseFromSlice([]const JsonApproach, allocator, data, .{
            .allocate = .alloc_always,
        });
        const items = parsed.value;

        var approaches = try allocator.alloc(Approach, items.len);
        var cumulative: u32 = 0;
        for (items, 0..) |item, i| {
            cumulative += item.weight;
            approaches[i] = .{
                .name = item.name,
                .weight = item.weight,
                .prompt = item.prompt,
                .cumulative = cumulative,
            };
        }

        return .{
            .approaches = approaches,
            .total_weight = cumulative,
        };
    }

    /// Load approaches from LMDB. Skips completed/retired approaches.
    /// Auto-retires exhausted approaches (empty >= 3, accepted == 0, total_runs >= 3).
    pub fn loadFromStore(store: *store_mod.Store, allocator: std.mem.Allocator) !ApproachPool {
        const txn = try store.beginReadTxn();
        defer store_mod.Store.abortTxn(txn);

        // First pass: count active approaches
        var count: usize = 0;
        {
            var iter = try store.iterApproaches(txn);
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
        var approaches = try allocator.alloc(Approach, count);
        var cumulative: u32 = 0;
        var idx: usize = 0;
        {
            var iter = try store.iterApproaches(txn);
            defer iter.close();
            while (iter.next()) |entry| {
                if (entry.view.header.status != .active) continue;
                if (entry.view.header.weight == 0) continue;
                if (isExhausted(entry.view.header)) continue;
                if (idx >= count) break;

                const w: u32 = @as(u32, entry.view.header.weight);
                cumulative += w;
                approaches[idx] = .{
                    .name = try allocator.dupe(u8, entry.name),
                    .weight = w,
                    .prompt = try allocator.dupe(u8, entry.view.prompt),
                    .cumulative = cumulative,
                };
                idx += 1;
            }
        }

        return .{
            .approaches = approaches[0..idx],
            .total_weight = cumulative,
        };
    }

    pub fn hasActiveApproaches(self: *const ApproachPool) bool {
        return self.total_weight > 0;
    }

    pub fn select(self: *const ApproachPool) ?*const Approach {
        if (self.approaches.len == 0) return null;
        if (self.total_weight == 0) return null;
        if (self.approaches.len == 1) return &self.approaches[0];

        const counter = @atomicRmw(u64, &select_counter, .Add, 1, .monotonic);
        var prng = std.Random.DefaultPrng.init(fs.timestamp() *% 2654435761 +% counter);
        const rand = prng.random();
        const val = rand.intRangeAtMost(u32, 1, self.total_weight);

        var lo: usize = 0;
        var hi: usize = self.approaches.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.approaches[mid].cumulative < val) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return &self.approaches[lo];
    }
};

/// Auto-retirement: an approach is exhausted if it has been tried enough
/// times with no success.
fn isExhausted(header: types.ApproachHeader) bool {
    return header.total_runs >= 3 and header.accepted == 0 and header.empty >= 3;
}

/// Reconcile a JSON approaches manifest into LMDB.
/// - Creates new approaches
/// - Updates weight/prompt for existing approaches (preserves stats)
/// - Retires approaches no longer in JSON
pub fn syncFromJson(
    store: *store_mod.Store,
    json_data: []const u8,
    origin: types.ApproachOrigin,
    allocator: std.mem.Allocator,
) !void {
    const JsonApproach = struct {
        name: []const u8,
        weight: u32,
        prompt: []const u8,
    };

    const parsed = try std.json.parseFromSlice([]const JsonApproach, allocator, json_data, .{
        .allocate = .alloc_always,
    });
    const items = parsed.value;

    const txn = try store.beginWriteTxn();
    errdefer store_mod.Store.abortTxn(txn);

    // Collect existing approach names before any writes
    var existing_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (existing_names.items) |name| allocator.free(name);
        existing_names.deinit(allocator);
    }
    {
        var iter = try store.iterApproaches(txn);
        defer iter.close();
        while (iter.next()) |entry| {
            try existing_names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    // Upsert all JSON approaches
    for (items) |item| {
        const existing = try store.getApproach(txn, item.name);
        if (existing) |view| {
            // Preserve stats, update weight + prompt + reactivate
            var header = view.header;
            header.weight = @intCast(item.weight);
            header.status = .active;
            try store.upsertApproach(txn, item.name, header, item.prompt);
        } else {
            // New approach
            const header = types.ApproachHeader{
                .weight = @intCast(item.weight),
                .total_runs = 0,
                .accepted = 0,
                .rejected = 0,
                .empty = 0,
                .status = .active,
                .origin = origin,
            };
            try store.upsertApproach(txn, item.name, header, item.prompt);
        }
    }

    // Retire approaches not in JSON
    for (existing_names.items) |name| {
        var found = false;
        for (items) |item| {
            if (std.mem.eql(u8, name, item.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            if (try store.getApproach(txn, name)) |view| {
                if (view.header.status == .active) {
                    var header = view.header;
                    header.status = .retired;
                    // Copy prompt before writing (same key invalidates old ptr)
                    const prompt_copy = try allocator.dupe(u8, view.prompt);
                    defer allocator.free(prompt_copy);
                    try store.upsertApproach(txn, name, header, prompt_copy);
                }
            }
        }
    }

    try store_mod.Store.commitTxn(txn);
}

/// Sync approaches from JSON file into LMDB.
pub fn syncFromFile(store: *store_mod.Store, path: []const u8, allocator: std.mem.Allocator) !void {
    const data = try fs.readFileAlloc(allocator, path, 1024 * 1024);
    try syncFromJson(store, data, .template, allocator);
}

test "approach pool select distribution" {
    var pool = ApproachPool{
        .approaches = @constCast(&[_]Approach{
            .{ .name = "a", .weight = 1, .prompt = "pa", .cumulative = 1 },
            .{ .name = "b", .weight = 1, .prompt = "pb", .cumulative = 2 },
        }),
        .total_weight = 2,
    };

    for (0..100) |_| {
        const approach = pool.select() orelse unreachable;
        try std.testing.expect(approach.name.len > 0);
    }
}

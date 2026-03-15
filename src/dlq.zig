const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const store_mod = @import("store.zig");
const fs = @import("fs.zig");

/// Dead Letter Queue for failed LMDB event writes.
///
/// When an event write fails (DB full, txn error, etc.), the event is
/// appended to a binary file. On next successful opportunity, the
/// queue is drained back into LMDB.
///
/// Binary format per entry:
///   [u64 session_id] [u32 seq] [4 bytes EventHeader] [u32 json_len] [json bytes]
///   Total: 20 + json_len bytes per entry
pub const DeadLetterQueue = struct {
    path: []const u8,
    entry_count: u32 = 0,

    pub fn init(db_dir: []const u8, allocator: std.mem.Allocator) !DeadLetterQueue {
        const path = try std.fs.path.join(allocator, &.{ db_dir, "dead-letters.bin" });
        return .{ .path = path };
    }

    /// Append a failed event write to the DLQ file.
    pub fn enqueue(
        self: *DeadLetterQueue,
        session_id: u64,
        seq: u32,
        header: types.EventHeader,
        raw_json: []const u8,
    ) void {
        // Read existing content so we can append. fs.writeFile writes from position 0,
        // so we must read existing data, truncate the file, then write existing + new entry.
        const existing = fs.readFileAlloc(std.heap.page_allocator, self.path, 64 * 1024 * 1024) catch &[_]u8{};
        defer if (existing.len > 0) std.heap.page_allocator.free(existing);

        // Build the new 20-byte fixed header for this entry.
        // Write: session_id(8) + seq(4) + header(4) + json_len(4) + json(N)
        var entry_hdr: [20]u8 = undefined;
        std.mem.writeInt(u64, entry_hdr[0..8], session_id, .little);
        std.mem.writeInt(u32, entry_hdr[8..12], seq, .little);
        @memcpy(entry_hdr[12..16], std.mem.asBytes(&header));
        std.mem.writeInt(u32, entry_hdr[16..20], @intCast(raw_json.len), .little);

        // Truncate the file and rewrite: existing content + new entry header + new json.
        const file = fs.createFile(self.path, .{}) catch return;
        defer fs.closeFile(file);

        fs.writeFile(file, existing) catch return;
        fs.writeFile(file, &entry_hdr) catch return;
        fs.writeFile(file, raw_json) catch return;
        self.entry_count += 1;
    }

    /// Try to drain all queued events back into LMDB.
    /// Returns the number of events successfully replayed.
    pub fn drain(self: *DeadLetterQueue, store: *store_mod.Store) u32 {
        const content = fs.readFileAlloc(std.heap.page_allocator, self.path, 64 * 1024 * 1024) catch return 0;
        defer std.heap.page_allocator.free(content);

        if (content.len == 0) return 0;

        var replayed: u32 = 0;
        var pos: usize = 0;

        while (pos + 20 <= content.len) {
            const session_id = std.mem.readInt(u64, content[pos..][0..8], .little);
            const seq = std.mem.readInt(u32, content[pos + 8 ..][0..4], .little);
            var header: types.EventHeader = undefined;
            @memcpy(std.mem.asBytes(&header), content[pos + 12 ..][0..4]);
            const json_len = std.mem.readInt(u32, content[pos + 16 ..][0..4], .little);
            pos += 20;

            if (pos + json_len > content.len) break;
            const raw_json = content[pos..][0..json_len];
            pos += json_len;

            // Try to replay into LMDB
            const txn = store.beginWriteTxn() catch break; // If DB is still broken, stop
            store.insertEvent(txn, session_id, seq, header, raw_json) catch {
                store_mod.Store.abortTxn(txn);
                break; // DB still broken — keep remaining entries
            };
            store_mod.Store.commitTxn(txn) catch break;
            replayed += 1;
        }

        if (replayed > 0 and pos >= content.len) {
            // All entries replayed — delete the file
            fs.deleteFile(self.path) catch {};
            self.entry_count = 0;
        } else if (replayed > 0) {
            // Partial replay — rewrite file with remaining entries
            const remaining = content[pos..];
            const file = fs.createFile(self.path, .{}) catch return replayed;
            defer fs.closeFile(file);
            fs.writeFile(file, remaining) catch {};
            self.entry_count -|= replayed;
        }

        return replayed;
    }

    /// Check if there are queued entries.
    pub fn hasPending(self: *const DeadLetterQueue) bool {
        return self.entry_count > 0 or fs.access(self.path);
    }
};

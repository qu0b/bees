const std = @import("std");
const fs = @import("fs.zig");
const Io = std.Io;

pub const Logger = struct {
    file: ?Io.File,

    pub fn init(log_path: ?[]const u8) Logger {
        const file = if (log_path) |p| fs.createFile(p, .{ .truncate = false }) catch null else null;
        return .{ .file = file };
    }

    pub fn deinit(self: *Logger) void {
        if (self.file) |f| fs.closeFile(f);
        self.file = null;
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.write("INFO", fmt, args);
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.write("ERROR", fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.write("WARN", fmt, args);
    }

    fn write(self: *Logger, level: []const u8, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const epoch_secs: u64 = fs.timestamp();
        const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();

        const prefix_len = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z [{s}] ", .{
            yd.year, md.month.numeric(), @as(u6, md.day_index) + 1,
            ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), level,
        }) catch return;

        const msg_len = std.fmt.bufPrint(buf[prefix_len.len..], fmt ++ "\n", args) catch return;
        const total = buf[0 .. prefix_len.len + msg_len.len];

        if (self.file) |f| fs.writeFile(f, total) catch {};
        std.debug.print("{s}", .{total});
    }
};

test "logger writes to stderr" {
    var logger = Logger.init(null);
    defer logger.deinit();
    logger.info("test message {d}", .{42});
}

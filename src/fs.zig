const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

/// Global Io handle, set once at startup from main().
pub var io: Io = undefined;

pub fn init(io_handle: Io) void {
    io = io_handle;
}

pub fn cwd() Dir {
    return Dir.cwd();
}

pub fn access(path: []const u8) bool {
    cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn createFile(path: []const u8, flags: File.CreateFlags) !File {
    return cwd().createFile(io, path, flags);
}

pub fn openFile(path: []const u8) !File {
    return cwd().openFile(io, path, .{});
}

pub fn closeFile(file: File) void {
    file.close(io);
}

pub fn deleteFile(path: []const u8) !void {
    return cwd().deleteFile(io, path);
}

pub fn makePath(path: []const u8) !void {
    return cwd().createDirPath(io, path);
}

pub fn openDir(path: []const u8) !Dir {
    return cwd().openDir(io, path, .{ .iterate = true });
}

pub fn closeDir(dir: Dir) void {
    dir.close(io);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

pub fn readLinkAbsolute(path: []const u8, buffer: []u8) ![]const u8 {
    const n = try Dir.readLinkAbsolute(io, path, buffer);
    return buffer[0..n];
}

pub fn writeFile(file: File, data: []const u8) !void {
    var buf: [8192]u8 = undefined;
    var writer = file.writerStreaming(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

pub fn filePrint(file: File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [8192]u8 = undefined;
    var writer = file.writerStreaming(io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

pub fn timestamp() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

pub fn readAll(file: File, buf: []u8) !usize {
    var read_buf: [8192]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    return reader.interface.readSliceShort(buf) catch return 0;
}

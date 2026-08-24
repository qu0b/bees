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

/// Open an existing file for read+write (needed for positional append writes).
pub fn openFileWrite(path: []const u8) !File {
    return cwd().openFile(io, path, .{ .mode = .read_write });
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

/// Open `path` for APPEND-ONLY writing, creating it if absent.
///
/// O_APPEND makes the kernel resolve the write offset to the true end of file
/// atomically per write, which is the only way several writers can share one
/// log file safely. The alternative — each writer tracking its own offset and
/// issuing positional writes — corrupts the file two ways when more than one
/// writer is live: equal offsets OVERWRITE each other, and an offset past the
/// real end leaves a hole that reads back as NUL bytes. chatplugin's log
/// accumulated 7367 NULs that way, which also made it "binary" to grep, so
/// every plain `grep` over it silently matched nothing.
pub fn openFileAppend(path: []const u8) !File {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Append `data` to a file opened with `openFileAppend`. The kernel picks the
/// offset, so no caller-side position is tracked or needed.
pub fn appendToFile(file: File, data: []const u8) !void {
    try file.writeStreamingAll(io, data);
}

/// Write `data` at `*pos` and advance `*pos`. Single-writer only: two writers
/// tracking independent offsets corrupt the file (see `openFileAppend`). For a
/// shared log, use `openFileAppend` + `appendToFile` instead.
pub fn writeFileAppend(file: File, data: []const u8, pos: *u64) !void {
    try file.writePositionalAll(io, data, pos.*);
    pos.* += data.len;
}

/// Return the current byte length of `file`, or 0 on error.
pub fn fileLength(file: File) u64 {
    return file.length(io) catch 0;
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

/// Read all .txt files from a directory and concatenate with "### filename" headers.
/// Returns null if directory doesn't exist or contains no .txt files.
pub fn readDirFiles(allocator: std.mem.Allocator, dir_path: []const u8, max_file_size: usize) ?[]const u8 {
    var dir = openDir(dir_path) catch return null;
    defer closeDir(dir);

    var buf: std.ArrayList(u8) = .empty;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;

        const file_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
        defer allocator.free(file_path);

        const content = readFileAlloc(allocator, file_path, max_file_size) catch continue;
        defer allocator.free(content);
        if (content.len == 0) continue;

        // Header: filename without .txt extension
        const name_end = entry.name.len - 4;
        buf.appendSlice(allocator, "\n### ") catch continue;
        buf.appendSlice(allocator, entry.name[0..name_end]) catch continue;
        buf.appendSlice(allocator, "\n") catch continue;
        buf.appendSlice(allocator, content) catch continue;
        if (content[content.len - 1] != '\n') buf.append(allocator, '\n') catch {};
    }

    if (buf.items.len == 0) return null;
    return buf.toOwnedSlice(allocator) catch null;
}

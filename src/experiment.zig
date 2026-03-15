/// Experiment: Zig 0.16 async I/O — daemon + HTTP server running concurrently.
///
/// Uses io.async() to launch both a periodic daemon loop and an HTTP API server
/// as concurrent green threads (backed by io_uring on Linux). Neither blocks
/// the other because all I/O goes through the Io abstraction which cooperatively
/// yields at every I/O point.
///
/// Key Zig 0.16 async primitives demonstrated:
///   - io.async(fn, args) → Future  — spawn concurrent task
///   - future.await(io)             — block until task completes
///   - future.cancel(io)            — request cancellation + await
///   - io.sleep(duration, clock)    — I/O-cooperative sleep (yields to event loop)
///   - Io.Group                     — manage a dynamic set of concurrent tasks
///
const std = @import("std");
const Io = std.Io;

// ============================================================
// Daemon — periodic background work
// ============================================================

fn daemon(io: Io, state: *DaemonState) void {
    daemonInner(io, state) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[daemon] fatal: {}\n", .{e}) catch return;
        log(io, msg);
    };
}

fn daemonInner(io: Io, state: *DaemonState) !void {
    log(io, "[daemon] started\n");

    while (true) {
        // I/O-cooperative sleep — yields to the event loop so the HTTP
        // server (and any other green threads) keep making progress.
        io.sleep(Io.Duration.fromSeconds(3), .awake) catch |e| switch (e) {
            error.Canceled => {
                log(io, "[daemon] cancelled, shutting down\n");
                return;
            },
        };

        state.tick +%= 1;
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[daemon] tick {d} — {d} requests served so far\n", .{
            state.tick,
            @as(u64, @atomicLoad(u64, &state.request_count, .monotonic)),
        }) catch continue;
        log(io, msg);
    }
}

// ============================================================
// HTTP API Server
// ============================================================

fn httpServer(io: Io, state: *DaemonState) void {
    httpServerInner(io, state) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[http] fatal: {}\n", .{e}) catch return;
        log(io, msg);
    };
}

fn httpServerInner(io: Io, state: *DaemonState) !void {
    const port: u16 = 8080;
    const addr = try Io.net.IpAddress.parse("0.0.0.0", port);
    var server = try Io.net.IpAddress.listen(addr, io, .{ .reuse_address = true });

    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[http] listening on :{d}\n", .{port}) catch "[http] listening\n";
    log(io, msg);

    // Accept loop — each connection handled inline (single green thread).
    // For concurrent connection handling, use Io.Group (shown in comments).
    while (true) {
        var stream = server.accept(io) catch |e| switch (e) {
            error.Canceled => return,
            else => continue,
        };
        handleConnection(io, stream, state);
        stream.close(io);
    }
}

fn handleConnection(io: Io, stream: Io.net.Stream, state: *DaemonState) void {
    handleConnectionInner(io, stream, state) catch {};
}

fn handleConnectionInner(io: Io, stream: Io.net.Stream, state: *DaemonState) !void {
    // Read request — use readVec for a single I/O operation.
    // readSliceShort loops until buffer is full, which blocks on HTTP
    // (client sends headers then waits for response).
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var req_buf: [4096]u8 = undefined;
    var iov = [1][]u8{req_buf[0..]};
    const n = reader.interface.readVec(&iov) catch return;
    if (n == 0) return;

    const req = req_buf[0..n];

    // Parse request line
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return;
    const first_line = req[0..line_end];

    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse return;
    const raw_path = parts.next() orelse return;
    const path = if (std.mem.indexOf(u8, raw_path, "?")) |q| raw_path[0..q] else raw_path;

    // Write response
    var write_buf: [8192]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    _ = @atomicRmw(u64, &state.request_count, .Add, 1, .monotonic);

    route(w, method, path, state) catch {
        writeResponse(w, 500, "{\"error\":\"internal server error\"}") catch {};
    };

    w.flush() catch {};
}

fn route(w: *Io.Writer, method: []const u8, path: []const u8, state: *DaemonState) !void {
    if (!std.mem.eql(u8, method, "GET"))
        return writeResponse(w, 405, "{\"error\":\"method not allowed\"}");

    if (std.mem.eql(u8, path, "/api/status")) return handleStatus(w, state);
    if (std.mem.eql(u8, path, "/api/health")) return handleHealth(w);
    if (std.mem.eql(u8, path, "/")) return handleIndex(w);

    return writeResponse(w, 404, "{\"error\":\"not found\"}");
}

fn handleStatus(w: *Io.Writer, state: *DaemonState) !void {
    var body: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&body, "{{\"daemon_tick\":{d},\"requests_served\":{d},\"status\":\"running\"}}", .{
        state.tick,
        @as(u64, @atomicLoad(u64, &state.request_count, .monotonic)),
    }) catch return writeResponse(w, 500, "{\"error\":\"format error\"}");

    try writeResponseHeader(w, 200, "application/json");
    try w.writeAll(json);
}

fn handleHealth(w: *Io.Writer) !void {
    try writeResponse(w, 200, "{\"healthy\":true}");
}

fn handleIndex(w: *Io.Writer) !void {
    try writeResponseHeader(w, 200, "text/html");
    try w.writeAll(
        \\<!DOCTYPE html><html><head><title>Zig Async Experiment</title>
        \\<style>body{font-family:monospace;background:#1a1a2e;color:#e0e0e0;padding:2em}
        \\pre{background:#16213e;padding:1em;border-radius:4px}
        \\h1{color:#0f3460}</style></head><body>
        \\<h1>Zig 0.16 Async I/O Experiment</h1>
        \\<p>Daemon loop + HTTP server running as concurrent green threads via <code>io.async()</code></p>
        \\<h2>Endpoints</h2>
        \\<pre>GET /              — this page
        \\GET /api/status    — daemon state + request count (JSON)
        \\GET /api/health    — health check</pre>
        \\<h2>Live Status</h2>
        \\<pre id="s">loading...</pre>
        \\<script>
        \\setInterval(()=>fetch('/api/status').then(r=>r.json()).then(d=>{
        \\document.getElementById('s').textContent=JSON.stringify(d,null,2)
        \\}),1000)
        \\</script></body></html>
    );
}

// ============================================================
// HTTP helpers
// ============================================================

fn writeResponseHeader(w: *Io.Writer, status: u16, content_type: []const u8) !void {
    const status_text: []const u8 = switch (status) {
        200 => "OK",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        else => "Unknown",
    };
    try w.print("HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{
        status, status_text, content_type,
    });
}

fn writeResponse(w: *Io.Writer, status: u16, body: []const u8) !void {
    try writeResponseHeader(w, status, "application/json");
    try w.writeAll(body);
}

// ============================================================
// Shared state
// ============================================================

const DaemonState = struct {
    tick: u32 = 0,
    request_count: u64 = 0,
};

// ============================================================
// Logging helper (writes to stdout via Io)
// ============================================================

fn log(io: Io, msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var writer = Io.File.stdout().writerStreaming(io, &buf);
    writer.interface.writeAll(msg) catch {};
    writer.interface.flush() catch {};
}

// ============================================================
// Entry point
// ============================================================

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    log(io, "=== Zig 0.16 Async I/O Experiment ===\n");
    log(io, "Launching daemon + HTTP server as concurrent green threads\n\n");

    var state = DaemonState{};

    // Launch both as concurrent async tasks.
    // On Linux with io_uring, these run as green threads — neither blocks the other.
    // On platforms with only blocking I/O, io.async() calls the function
    // immediately, so you'd need OS threads (std.Thread.spawn) instead.
    var server_future = io.async(httpServer, .{ io, &state });
    var daemon_future = io.async(daemon, .{ io, &state });

    // The daemon runs forever; the server runs forever.
    // In practice you'd await one and cancel the other on shutdown signal.
    // For this experiment, await the daemon (it runs until cancelled).
    _ = daemon_future.await(io);

    // If daemon exits, cancel the server.
    _ = server_future.cancel(io);
}

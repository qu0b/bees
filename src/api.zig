const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");
const git = @import("git.zig");
const claude = @import("claude.zig");
const tasks_mod = @import("tasks.zig");

/// Entry point for the API server thread. Never returns unless fatal error.
pub fn startApiServer(
    store: *store_mod.Store,
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
    port: u16,
) void {
    runServer(store, cfg, paths, logger, io, allocator, port) catch |e| {
        logger.err("[api] server fatal error: {}", .{e});
    };
}

fn runServer(
    store: *store_mod.Store,
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
    port: u16,
) !void {
    // Bind to localhost only — the dashboard proxies via Next.js API routes.
    // Use 0.0.0.0 only if explicitly configured (e.g., behind a reverse proxy with auth).
    const bind_addr = if (cfg.api.bind_address.len > 0) cfg.api.bind_address else "127.0.0.1";
    const addr = try Io.net.IpAddress.parse(bind_addr, port);
    var server = try Io.net.IpAddress.listen(addr, io, .{ .reuse_address = true });

    logger.info("[api] HTTP server listening on {s}:{d}", .{ bind_addr, port });

    while (true) {
        var stream = server.accept(io) catch |e| {
            logger.warn("[api] accept error: {}", .{e});
            continue;
        };

        handleConnection(stream, store, cfg, paths, logger, io, allocator);
        stream.close(io);
    }
}

fn handleConnection(
    stream: Io.net.Stream,
    store: *store_mod.Store,
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) void {
    handleConnectionInner(stream, store, cfg, paths, logger, io, allocator) catch {};
}

fn handleConnectionInner(
    stream: Io.net.Stream,
    store: *store_mod.Store,
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) !void {
    // Read request via the underlying net stream directly, bypassing the
    // buffered Reader. This does a single recv() and returns immediately
    // with whatever data is available — correct for HTTP request/response.
    var request: [131072]u8 = undefined;
    var total: usize = 0;
    {
        var recv_iov = [1][]u8{request[0..]};
        total = io.vtable.netRead(io.userdata, stream.socket.handle, &recv_iov) catch return;
    }
    if (total == 0) return;

    // For POST/PUT with Content-Length, read remaining body if needed
    if (std.mem.indexOf(u8, request[0..total], "\r\n\r\n")) |hend| {
        const headers = request[0..hend];
        const content_length = parseContentLength(headers);
        const body_received = total - (hend + 4);
        var remaining = if (content_length > body_received) content_length - body_received else 0;
        while (remaining > 0 and total < request.len) {
            var body_iov = [1][]u8{request[total..]};
            const extra = io.vtable.netRead(io.userdata, stream.socket.handle, &body_iov) catch break;
            if (extra == 0) break;
            total += extra;
            remaining -|= extra;
        }
    }

    const req = request[0..total];

    // Parse request line
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return;
    const first_line = req[0..line_end];

    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse return;
    const raw_path = parts.next() orelse return;

    // Strip query string
    const path = if (std.mem.indexOf(u8, raw_path, "?")) |q| raw_path[0..q] else raw_path;

    // Extract body
    const body: []const u8 = blk: {
        if (std.mem.indexOf(u8, req, "\r\n\r\n")) |hend| {
            if (hend + 4 < total) break :blk req[hend + 4 .. total];
        }
        break :blk "";
    };

    // Write response
    var write_buf: [16384]u8 = undefined;
    var net_writer = stream.writer(io, &write_buf);
    const w = &net_writer.interface;

    route(w, method, path, body, store, cfg, paths, logger, io, allocator) catch {
        writeResponse(w, 500, "application/json", "{\"error\":\"Internal server error\"}") catch {};
    };

    w.flush() catch {};
}

fn route(
    w: *Io.Writer,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    store: *store_mod.Store,
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    _: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
) !void {
    if (std.mem.eql(u8, method, "GET")) {
        if (std.mem.eql(u8, path, "/api/status")) return handleStatus(w, store, cfg, paths);
        if (std.mem.eql(u8, path, "/api/sessions")) return handleSessions(w, store, null);
        if (std.mem.eql(u8, path, "/api/tasks")) return handleTasks(w, store);
        if (std.mem.eql(u8, path, "/api/config")) return handleConfig(w, paths);
        if (std.mem.eql(u8, path, "/api/log")) return handleLog(w, paths, allocator);
        if (std.mem.eql(u8, path, "/api/workers")) return handleSessions(w, store, .worker);
        if (std.mem.eql(u8, path, "/api/analytics")) return handleSessions(w, store, null);
        if (std.mem.eql(u8, path, "/api/branches")) return handleBranches(w, paths, io, allocator);
        if (std.mem.eql(u8, path, "/api/vision")) return handleVisionGet(w, store);
        if (std.mem.startsWith(u8, path, "/api/reports/")) return handleReportGet(w, store, path);

        if (std.mem.startsWith(u8, path, "/api/sessions/")) {
            const rest = path["/api/sessions/".len..];
            if (std.mem.endsWith(u8, rest, "/diff")) {
                const id_str = rest[0 .. rest.len - 5];
                const id = std.fmt.parseInt(u64, id_str, 10) catch
                    return writeResponse(w, 400, "application/json", "{\"error\":\"Invalid session ID\"}");
                return handleSessionDiff(w, store, paths, cfg, io, allocator, id);
            }
            const id = std.fmt.parseInt(u64, rest, 10) catch
                return writeResponse(w, 400, "application/json", "{\"error\":\"Invalid session ID\"}");
            return handleSession(w, store, id);
        }

        return writeResponse(w, 404, "application/json", "{\"error\":\"Not found\"}");
    }

    if (std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "PUT")) {
        if (std.mem.eql(u8, path, "/api/tasks") or std.mem.eql(u8, path, "/api/tasks/sync")) {
            return handleTasksPost(w, store, paths, body, allocator);
        }
        if (std.mem.eql(u8, path, "/api/config")) {
            return handleConfigPost(w, paths, body, allocator);
        }
        if (std.mem.eql(u8, path, "/api/vision")) {
            return handleVisionPut(w, store, body);
        }
        return writeResponse(w, 404, "application/json", "{\"error\":\"Not found\"}");
    }

    return writeResponse(w, 405, "application/json", "{\"error\":\"Method not allowed\"}");
}

// === Endpoint handlers ===

fn handleStatus(w: *Io.Writer, store: *store_mod.Store, cfg: config_mod.Config, paths: config_mod.ProjectPaths) !void {
    const txn = try store.beginReadTxn();
    defer store_mod.Store.abortTxn(txn);

    const now = fs.timestamp();
    const day_start = now - @mod(now, 86400);
    const stats = try store.getDailyStats(txn, day_start);

    try writeResponseHeader(w, 200, "application/json");

    try w.print("{{\"status\":{{\"project\":", .{});
    try writeJsonStr(w, cfg.project.name);
    try w.print(",\"path\":", .{});
    try writeJsonStr(w, paths.root);
    try w.print(",\"workers\":{d},\"today\":{{\"total\":{d},\"accepted\":{d},\"rejected\":{d},\"conflicts\":{d},\"build_failures\":{d},\"cost_cents\":{d}}}}},\"sessions\":", .{
        cfg.workers.count,
        stats.total,
        stats.accepted,
        stats.rejected,
        stats.conflicts,
        stats.build_failures,
        stats.total_cost_cents,
    });

    try writeSessionsArray(w, store, txn, null);
    try w.print("}}", .{});
}

fn handleSessions(w: *Io.Writer, store: *store_mod.Store, type_filter: ?types.SessionType) !void {
    const txn = try store.beginReadTxn();
    defer store_mod.Store.abortTxn(txn);

    try writeResponseHeader(w, 200, "application/json");
    try writeSessionsArray(w, store, txn, type_filter);
}

fn handleSession(w: *Io.Writer, store: *store_mod.Store, id: u64) !void {
    const txn = try store.beginReadTxn();
    defer store_mod.Store.abortTxn(txn);

    const session = (try store.getSession(txn, id)) orelse
        return writeResponse(w, 404, "application/json", "{\"error\":\"Session not found\"}");

    try writeResponseHeader(w, 200, "application/json");

    try w.print("{{\"id\":{d},\"type\":\"{s}\",\"status\":\"{s}\",\"backend\":\"{s}\",\"commits\":{d},\"cost_cents\":{d},\"cost_microdollars\":{d},\"task\":", .{
        id,
        session.header.@"type".label(),
        session.header.status.label(),
        session.header.backend.label(),
        session.header.commit_count,
        @as(u64, session.header.cost_microdollars) / 10000,
        session.header.cost_microdollars,
    });
    try writeJsonStr(w, session.task);
    try w.print(",\"branch\":", .{});
    try writeJsonStr(w, session.branch);
    try w.print(",\"turns\":{d},\"duration_ms\":{d}", .{
        session.header.num_turns,
        session.header.duration_ms,
    });
    if (session.header.has_tokens) {
        try w.print(",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_creation_tokens\":{d},\"cache_read_tokens\":{d}", .{
            session.header.input_tokens,
            session.header.output_tokens,
            session.header.cache_creation_tokens,
            session.header.cache_read_tokens,
        });
    }

    // Events
    try w.print(",\"events\":[", .{});
    var event_iter = try store.iterSessionEvents(txn, id);
    defer event_iter.close();
    var first_event = true;

    while (event_iter.next()) |ev| {
        if (!first_event) try w.print(",", .{});
        first_event = false;

        try w.print("{{\"seq\":{d},\"type\":\"{s}\",\"tool\":\"{s}\"", .{
            ev.seq,
            ev.header.event_type.label(),
            ev.header.tool_name.label(),
        });
        if (ev.header.role != .none) {
            try w.print(",\"role\":\"{s}\"", .{ev.header.role.label()});
        }
        if (ev.header.event_type == .result) {
            if (claude.findJsonNumberValue(ev.raw_json, "\"total_cost_usd\"")) |cost| {
                const cents: u64 = @intFromFloat(@max(cost * 100.0, 0.0));
                try w.print(",\"cost_cents\":{d}", .{cents});
            }
            if (claude.findJsonNumberValue(ev.raw_json, "\"duration_ms\"")) |dur| {
                const ms: u64 = @intFromFloat(@max(dur, 0.0));
                try w.print(",\"duration_ms\":{d}", .{ms});
            }
        }
        try w.print(",\"raw\":", .{});
        try w.writeAll(ev.raw_json);

        // Extract text preview
        {
            const text_preview: ?[]const u8 = blk: {
                if (ev.header.role == .assistant) {
                    break :blk claude.findJsonStringValue(ev.raw_json, "\"text\"");
                }
                if (ev.header.event_type == .tool_result) {
                    if (claude.findJsonStringValue(ev.raw_json, "\"content\"")) |c_val| {
                        if (!std.mem.eql(u8, c_val, "tool_result") and !std.mem.eql(u8, c_val, "text")) {
                            break :blk c_val;
                        }
                    }
                    break :blk claude.findJsonStringValue(ev.raw_json, "\"text\"");
                }
                break :blk null;
            };
            if (text_preview) |text| {
                const max_len: usize = 200;
                const preview = if (text.len > max_len) text[0..max_len] else text;
                try w.print(",\"message\":\"", .{});
                for (preview) |ch| {
                    switch (ch) {
                        '"' => try w.writeAll("\\\""),
                        '\\' => try w.writeAll("\\\\"),
                        '\n' => try w.writeAll(" "),
                        '\r' => {},
                        '\t' => try w.writeAll(" "),
                        else => {
                            if (ch >= 0x20) {
                                try w.print("{c}", .{ch});
                            }
                        },
                    }
                }
                try w.print("\"", .{});
            }
        }

        try w.print("}}", .{});
    }

    try w.print("]}}", .{});
}

fn handleSessionDiff(
    w: *Io.Writer,
    store: *store_mod.Store,
    paths: config_mod.ProjectPaths,
    cfg: config_mod.Config,
    io: Io,
    allocator: std.mem.Allocator,
    id: u64,
) !void {
    const txn = try store.beginReadTxn();
    const session = (try store.getSession(txn, id)) orelse {
        store_mod.Store.abortTxn(txn);
        return writeResponse(w, 404, "application/json", "{\"error\":\"Session not found\"}");
    };
    var branch_buf: [256]u8 = undefined;
    const branch_len = @min(session.branch.len, branch_buf.len);
    @memcpy(branch_buf[0..branch_len], session.branch[0..branch_len]);
    const branch = branch_buf[0..branch_len];
    store_mod.Store.abortTxn(txn);

    if (branch.len == 0) {
        return writeResponse(w, 200, "application/json", "{\"diff\":\"\",\"files_changed\":0}");
    }

    const result = git.getDiff(allocator, io, paths.root, branch, cfg.project.base_branch) catch {
        return writeResponse(w, 200, "application/json", "{\"diff\":\"\",\"files_changed\":0}");
    };
    defer allocator.free(result);

    // Count files changed
    var files_changed: u32 = 0;
    var lines = std.mem.splitScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git")) files_changed += 1;
    }

    try writeResponseHeader(w, 200, "application/json");
    try w.print("{{\"diff\":", .{});
    try writeJsonStr(w, result);
    try w.print(",\"files_changed\":{d}}}", .{files_changed});
}

fn handleTasks(w: *Io.Writer, store: *store_mod.Store) !void {
    const txn = try store.beginReadTxn();
    defer store_mod.Store.abortTxn(txn);

    try writeResponseHeader(w, 200, "application/json");
    try w.print("[", .{});

    var iter = try store.iterTasks(txn);
    defer iter.close();
    var first = true;

    while (iter.next()) |entry| {
        if (!first) try w.print(",", .{});
        first = false;

        try w.print("{{\"name\":", .{});
        try writeJsonStr(w, entry.name);
        try w.print(",\"weight\":{d},\"prompt\":", .{entry.view.header.weight});
        try writeJsonStr(w, entry.view.prompt);
        try w.print(",\"total_runs\":{d},\"accepted\":{d},\"rejected\":{d},\"empty\":{d}", .{
            entry.view.header.total_runs,
            entry.view.header.accepted,
            entry.view.header.rejected,
            entry.view.header.empty,
        });
        try w.print(",\"status\":\"{s}\",\"origin\":\"{s}\"}}", .{
            entry.view.header.status.label(),
            entry.view.header.origin.label(),
        });
    }

    try w.print("]", .{});
}

fn handleTasksPost(
    w: *Io.Writer,
    store: *store_mod.Store,
    paths: config_mod.ProjectPaths,
    body: []const u8,
    allocator: std.mem.Allocator,
) !void {
    if (body.len == 0) {
        return writeResponse(w, 400, "application/json", "{\"error\":\"Empty body\"}");
    }

    // Write to tasks.json file
    const file = fs.createFile(paths.tasks_file, .{}) catch
        return writeResponse(w, 500, "application/json", "{\"error\":\"Failed to write file\"}");
    fs.writeFile(file, body) catch {
        fs.closeFile(file);
        return writeResponse(w, 500, "application/json", "{\"error\":\"Failed to write file\"}");
    };
    fs.closeFile(file);

    // Sync to LMDB
    tasks_mod.syncFromJson(store, body, .user, allocator) catch
        return writeResponse(w, 500, "application/json", "{\"error\":\"Failed to sync to database\"}");

    return writeResponse(w, 200, "application/json", "{\"ok\":true}");
}

fn handleConfig(w: *Io.Writer, paths: config_mod.ProjectPaths) !void {
    // Use a stack buffer to read the config file
    var buf: [65536]u8 = undefined;
    const file = fs.openFile(paths.config_file) catch
        return writeResponse(w, 500, "application/json", "{\"error\":\"Config not found\"}");
    defer fs.closeFile(file);
    const n = fs.readAll(file, &buf) catch
        return writeResponse(w, 500, "application/json", "{\"error\":\"Failed to read config\"}");

    try writeResponseHeader(w, 200, "application/json");
    try w.writeAll(buf[0..n]);
}

fn handleConfigPost(w: *Io.Writer, paths: config_mod.ProjectPaths, body: []const u8, allocator: std.mem.Allocator) !void {
    if (body.len == 0) {
        return writeResponse(w, 400, "application/json", "{\"error\":\"Empty body\"}");
    }

    // Validate that body is parseable as a Config before writing
    _ = std.json.parseFromSlice(config_mod.Config, allocator, body, .{
        .allocate = .alloc_always,
    }) catch
        return writeResponse(w, 400, "application/json", "{\"error\":\"Invalid config JSON\"}");

    const file = fs.createFile(paths.config_file, .{}) catch
        return writeResponse(w, 500, "application/json", "{\"error\":\"Failed to write config\"}");
    fs.writeFile(file, body) catch {
        fs.closeFile(file);
        return writeResponse(w, 500, "application/json", "{\"error\":\"Failed to write config\"}");
    };
    fs.closeFile(file);

    return writeResponse(w, 200, "application/json", "{\"ok\":true}");
}

fn handleLog(w: *Io.Writer, paths: config_mod.ProjectPaths, allocator: std.mem.Allocator) !void {
    const log_path = std.fs.path.join(allocator, &.{ paths.logs_dir, "bees.log" }) catch
        return writeResponse(w, 500, "text/plain", "Failed to construct log path");
    defer allocator.free(log_path);

    const content = fs.readFileAlloc(allocator, log_path, 10 * 1024 * 1024) catch
        return writeResponse(w, 200, "text/plain", "No log file found");
    defer allocator.free(content);

    // Return last 200 lines
    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trim(u8, content, &std.ascii.whitespace), '\n');
    var line_list: [200][]const u8 = undefined;
    var count: usize = 0;
    while (lines.next()) |line| {
        if (count >= 200) break;
        line_list[count] = line;
        count += 1;
    }

    try writeResponseHeader(w, 200, "text/plain");
    var i = count;
    while (i > 0) {
        i -= 1;
        try w.writeAll(line_list[i]);
        try w.writeAll("\n");
    }
}

fn handleBranches(w: *Io.Writer, paths: config_mod.ProjectPaths, io: Io, allocator: std.mem.Allocator) !void {
    const result = git.run(allocator, io, &.{
        "git", "branch", "-a", "--format=%(refname:short)\t%(objectname:short)\t%(creatordate:iso8601)\t%(subject)",
    }, paths.root) catch {
        return writeResponse(w, 200, "application/json", "[]");
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try writeResponseHeader(w, 200, "application/json");
    try w.print("[", .{});

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "bee/")) continue;

        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        const hash = fields.next() orelse "";
        const date = fields.next() orelse "";
        const subject = fields.next() orelse "";

        if (!first) try w.print(",", .{});
        first = false;

        try w.print("{{\"name\":", .{});
        try writeJsonStr(w, name);
        try w.print(",\"hash\":", .{});
        try writeJsonStr(w, hash);
        try w.print(",\"date\":", .{});
        try writeJsonStr(w, date);
        try w.print(",\"subject\":", .{});
        try writeJsonStr(w, subject);
        try w.print("}}", .{});
    }

    try w.print("]", .{});
}

// === Helpers ===

fn writeSessionsArray(w: *Io.Writer, store: *store_mod.Store, txn: anytype, type_filter: ?types.SessionType) !void {
    try w.print("[", .{});

    var iter = try store.iterSessions(txn);
    defer iter.close();
    var first = true;

    while (iter.next()) |entry| {
        if (type_filter) |tf| {
            if (entry.view.header.@"type" != tf) continue;
        }

        if (!first) try w.print(",", .{});
        first = false;

        try w.print("{{\"id\":{d},\"type\":\"{s}\",\"status\":\"{s}\",\"backend\":\"{s}\",\"commits\":{d},\"cost_cents\":{d},\"task\":", .{
            entry.id,
            entry.view.header.@"type".label(),
            entry.view.header.status.label(),
            entry.view.header.backend.label(),
            entry.view.header.commit_count,
            @as(u64, entry.view.header.cost_microdollars) / 10000,
        });
        try writeJsonStr(w, entry.view.task);
        try w.print(",\"branch\":", .{});
        try writeJsonStr(w, entry.view.branch);
        try w.print(",\"duration_ms\":{d}", .{entry.view.header.duration_ms});
        if (entry.view.header.has_tokens) {
            try w.print(",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_creation_tokens\":{d},\"cache_read_tokens\":{d}", .{
                entry.view.header.input_tokens,
                entry.view.header.output_tokens,
                entry.view.header.cache_creation_tokens,
                entry.view.header.cache_read_tokens,
            });
        }
        try w.print("}}", .{});
    }

    try w.print("]", .{});
}

fn writeResponseHeader(w: *Io.Writer, status: u16, content_type: []const u8) !void {
    const status_text: []const u8 = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        else => "Unknown",
    };
    try w.print("HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{
        status,
        status_text,
        content_type,
    });
}

fn writeResponse(w: *Io.Writer, status: u16, content_type: []const u8, body: []const u8) !void {
    try writeResponseHeader(w, status, content_type);
    try w.writeAll(body);
}

fn parseContentLength(headers: []const u8) usize {
    // Case-insensitive search for Content-Length header (RFC 7230)
    const needle = "content-length:";
    var i: usize = 0;
    while (i + needle.len < headers.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            const ch = headers[i + j];
            const lower = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            if (lower != needle[j]) {
                match = false;
                break;
            }
        }
        if (!match) continue;
        var pos = i + needle.len;
        while (pos < headers.len and headers[pos] == ' ') : (pos += 1) {}
        const start = pos;
        while (pos < headers.len and headers[pos] != '\r' and headers[pos] != '\n') : (pos += 1) {}
        return std.fmt.parseInt(usize, headers[start..pos], 10) catch 0;
    }
    return 0;
}

fn handleVisionGet(w: *Io.Writer, store: *store_mod.Store) !void {
    const txn = store.beginReadTxn() catch
        return writeResponse(w, 500, "application/json", "{\"error\":\"DB read failed\"}");
    defer store_mod.Store.abortTxn(txn);

    const vision = (store.getMeta(txn, "report:vision") catch null) orelse "";

    try writeResponseHeader(w, 200, "application/json");
    try w.print("{{\"vision\":", .{});
    try writeJsonStr(w, vision);
    try w.print("}}", .{});
}

fn handleVisionPut(w: *Io.Writer, store: *store_mod.Store, body: []const u8) !void {
    if (body.len == 0) return writeResponse(w, 400, "application/json", "{\"error\":\"Empty body\"}");

    // Body is the raw vision text (or JSON with {"vision": "..."})
    // Try to extract from JSON first, fall back to raw text
    const vision = if (claude.findJsonStringValue(body, "\"vision\"")) |v| v else body;

    const txn = store.beginWriteTxn() catch
        return writeResponse(w, 500, "application/json", "{\"error\":\"DB write failed\"}");
    store.putMeta(txn, "report:vision", vision) catch {
        store_mod.Store.abortTxn(txn);
        return writeResponse(w, 500, "application/json", "{\"error\":\"Write failed\"}");
    };
    store_mod.Store.commitTxn(txn) catch
        return writeResponse(w, 500, "application/json", "{\"error\":\"Commit failed\"}");

    return writeResponse(w, 200, "application/json", "{\"ok\":true}");
}

fn handleReportGet(w: *Io.Writer, store: *store_mod.Store, path: []const u8) !void {
    const key_suffix = path["/api/reports/".len..];
    // Map URL to LMDB meta key: /api/reports/qa → report:qa
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "report:{s}", .{key_suffix}) catch
        return writeResponse(w, 400, "application/json", "{\"error\":\"Invalid report key\"}");

    const txn = store.beginReadTxn() catch
        return writeResponse(w, 500, "application/json", "{\"error\":\"DB read failed\"}");
    defer store_mod.Store.abortTxn(txn);

    const content = (store.getMeta(txn, key) catch null) orelse
        return writeResponse(w, 404, "application/json", "{\"error\":\"Report not found\"}");

    try writeResponseHeader(w, 200, "application/json");
    try w.print("{{\"key\":\"{s}\",\"content\":", .{key});
    try writeJsonStr(w, content);
    try w.print("}}", .{});
}

fn writeJsonStr(w: *Io.Writer, s: []const u8) !void {
    try w.print("\"", .{});
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch >= 0x20) {
                    try w.print("{c}", .{ch});
                } else {
                    try w.print("\\u00{x:0>2}", .{ch});
                }
            },
        }
    }
    try w.print("\"", .{});
}

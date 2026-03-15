const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const store_mod = @import("store.zig");
const dlq_mod = @import("dlq.zig");
const fs = @import("fs.zig");

pub const ClaudeOptions = struct {
    prompt: []const u8,
    cwd: []const u8,
    system_prompt_file: ?[]const u8 = null,
    append_prompt_file: ?[]const u8 = null,
    model: []const u8 = "opus",
    effort: []const u8 = "high",
    max_budget_usd: f64 = 30.0,
    stdin_data: ?[]const u8 = null,
    timeout_secs: u32 = 0,
    resume_session_id: ?[]const u8 = null,
    mcp_config: ?[]const u8 = null,
    max_turns: u32 = 0,
    stream_output: bool = false,
    db_dir: ?[]const u8 = null,
};

pub const SessionResult = struct {
    event_count: u32,
    duration_secs: u16,
    num_turns: u8,
    is_error: bool,
    exit_code: i16,
    result_text: []const u8,
    claude_session_id: []const u8 = "",
    cost_microdollars: u32 = 0,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_creation_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
};

pub fn spawnClaude(allocator: std.mem.Allocator, io: Io, options: ClaudeOptions) !std.process.Child {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    if (options.timeout_secs > 0) {
        try args.append(allocator, "timeout");
        try args.append(allocator, "--kill-after=10");
        var timeout_buf: [32]u8 = undefined;
        const timeout_str = std.fmt.bufPrint(&timeout_buf, "{d}", .{options.timeout_secs}) catch "3600";
        try args.append(allocator, timeout_str);
    }

    try args.append(allocator, "claude");

    // --mcp-config must come before -p because -p makes all
    // subsequent positional args the prompt
    if (options.mcp_config) |mcp| {
        try args.append(allocator, "--mcp-config");
        try args.append(allocator, mcp);
    }

    try args.append(allocator, "-p");
    try args.append(allocator, "--verbose");
    try args.append(allocator, "--dangerously-skip-permissions");
    try args.append(allocator, "--output-format");
    try args.append(allocator, "stream-json");
    try args.append(allocator, "--model");
    try args.append(allocator, options.model);
    try args.append(allocator, "--effort");
    try args.append(allocator, options.effort);

    var budget_buf: [32]u8 = undefined;
    const budget_str = std.fmt.bufPrint(&budget_buf, "{d:.0}", .{options.max_budget_usd}) catch "30";
    try args.append(allocator, "--max-budget-usd");
    try args.append(allocator, budget_str);

    if (options.max_turns > 0) {
        var turns_buf: [32]u8 = undefined;
        const turns_str = std.fmt.bufPrint(&turns_buf, "{d}", .{options.max_turns}) catch "10";
        try args.append(allocator, "--max-turns");
        try args.append(allocator, turns_str);
    }

    if (options.resume_session_id) |rsid| {
        try args.append(allocator, "--resume");
        try args.append(allocator, rsid);
    }

    if (options.system_prompt_file) |spf| {
        try args.append(allocator, "--system-prompt-file");
        try args.append(allocator, spf);
    }
    if (options.append_prompt_file) |apf| {
        try args.append(allocator, "--append-system-prompt-file");
        try args.append(allocator, apf);
    }

    try args.append(allocator, options.prompt);

    // Build filtered environment excluding CLAUDECODE to prevent
    // "cannot launch inside another Claude Code session" errors
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    {
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const entry_str: [*:0]const u8 = @ptrCast(entry);
            const entry_slice = std.mem.sliceTo(entry_str, 0);
            const eq_pos = std.mem.indexOfScalar(u8, entry_slice, '=') orelse continue;
            const key = entry_slice[0..eq_pos];
            if (std.mem.eql(u8, key, "CLAUDECODE")) continue;
            const value = entry_slice[eq_pos + 1 ..];
            env_map.put(key, value) catch continue;
        }
    }

    var child = try std.process.spawn(io, .{
        .argv = args.items,
        .cwd = .{ .path = options.cwd },
        .environ_map = &env_map,
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = if (options.stdin_data != null) .pipe else .ignore,
    });

    if (options.stdin_data) |data| {
        if (child.stdin) |stdin| {
            var write_buf: [8192]u8 = undefined;
            var writer = stdin.writerStreaming(io, &write_buf);
            writer.interface.writeAll(data) catch {};
            writer.interface.flush() catch {};
            stdin.close(io);
        }
        child.stdin = null;
    }

    return child;
}

pub fn parseEventMeta(line: []const u8) types.EventMeta {
    var meta = types.EventMeta{
        .event_type = .result,
        .tool_name = .none,
        .is_error = false,
        .role = .none,
        .duration_secs = 0,
        .cost_cents = 0,
        .num_turns = 0,
    };

    const type_val = findJsonStringValue(line, "\"type\"") orelse return meta;

    // Claude CLI stream-json uses top-level types: "system", "assistant", "user", "result"
    // Map these to our internal EventType enum
    if (std.mem.eql(u8, type_val, "system")) {
        meta.event_type = .init_event;
    } else if (std.mem.eql(u8, type_val, "result")) {
        meta.event_type = .result;
        if (findJsonNumberValue(line, "\"total_cost_usd\"")) |cost| {
            meta.cost_cents = @intFromFloat(@min(@max(cost * 100.0, 0.0), 65535.0));
        }
        if (findJsonNumberValue(line, "\"duration_ms\"")) |dur| {
            meta.duration_secs = @intFromFloat(@min(dur / 1000.0, 65535.0));
        }
        if (findJsonNumberValue(line, "\"num_turns\"")) |turns| {
            meta.num_turns = @intFromFloat(@min(turns, 255.0));
        }
        if (findJsonStringValue(line, "\"subtype\"")) |subtype| {
            if (std.mem.eql(u8, subtype, "error")) {
                meta.is_error = true;
            }
        }
    } else if (std.mem.eql(u8, type_val, "assistant")) {
        // Assistant messages contain content blocks; check for tool_use vs text
        if (std.mem.indexOf(u8, line, "\"tool_use\"") != null) {
            meta.event_type = .tool_use;
            meta.role = .assistant;
            if (findJsonStringValue(line, "\"name\"")) |name| {
                meta.tool_name = types.ToolName.fromJsonString(name);
            }
        } else {
            meta.event_type = .message;
            meta.role = .assistant;
        }
    } else if (std.mem.eql(u8, type_val, "user")) {
        // User messages contain tool_result blocks or plain text
        if (std.mem.indexOf(u8, line, "\"tool_result\"") != null) {
            meta.event_type = .tool_result;
            meta.role = .user;
        } else {
            meta.event_type = .message;
            meta.role = .user;
        }
    } else if (std.mem.eql(u8, type_val, "rate_limit_event")) {
        // Rate limit events are informational — not a session result
        meta.event_type = .message;
        meta.role = .none;
    } else {
        // Fallback: try legacy/direct type names for compatibility
        meta.event_type = types.EventType.fromJsonString(type_val);
        if (meta.event_type == .tool_use) {
            if (findJsonStringValue(line, "\"name\"")) |name| {
                meta.tool_name = types.ToolName.fromJsonString(name);
            }
        }
    }

    return meta;
}

pub fn runClaudeSession(
    store: *store_mod.Store,
    io: Io,
    options: ClaudeOptions,
    session_id: u64,
    allocator: std.mem.Allocator,
) !SessionResult {
    var child = try spawnClaude(allocator, io, options);

    // Set up stdout writer for streaming mode
    var stream_buf: [8192]u8 = undefined;
    var stream_writer = Io.File.stdout().writerStreaming(io, &stream_buf);
    const stream = if (options.stream_output) &stream_writer.interface else null;

    // Dead letter queue for failed LMDB writes
    var dlq: ?dlq_mod.DeadLetterQueue = if (options.db_dir) |db_dir|
        dlq_mod.DeadLetterQueue.init(db_dir, allocator) catch null
    else
        null;

    // Try draining any previously queued events before starting
    if (dlq) |*q| {
        const drained = q.drain(store);
        if (drained > 0) {
            std.debug.print("[dlq] replayed {d} dead-lettered events\n", .{drained});
        }
    }

    var seq: u32 = 0;
    var last_meta = types.EventMeta{
        .event_type = .result,
        .tool_name = .none,
        .is_error = false,
        .role = .none,
        .duration_secs = 0,
        .cost_cents = 0,
        .num_turns = 0,
    };
    var result_text: []const u8 = "";
    var claude_session_id: []const u8 = "";
    var total_input_tokens: u32 = 0;
    var total_output_tokens: u32 = 0;
    var total_cache_creation: u32 = 0;
    var total_cache_read: u32 = 0;
    var total_cost_microdollars: u32 = 0;
    const session_start = fs.timestamp();

    // Read stdout line by line using the new Reader API
    if (child.stdout) |stdout_file| {
        var read_buf: [256 * 1024]u8 = undefined;
        var reader = stdout_file.readerStreaming(io, &read_buf);

        while (true) {
            const line = reader.interface.takeDelimiter('\n') catch |e| switch (e) {
                error.ReadFailed => break,
                error.StreamTooLong => {
                    // Line exceeds buffer capacity — skip the rest and continue
                    _ = reader.interface.discardDelimiterInclusive('\n') catch break;
                    continue;
                },
            };
            if (line == null) break;
            const line_data = line.?;
            if (line_data.len == 0) continue;

            // Make a copy since the reader buffer may be reused
            const line_copy = try allocator.dupe(u8, line_data);
            defer allocator.free(line_copy);

            const meta = parseEventMeta(line_copy);

            const now: u64 = fs.timestamp();
            const offset_ms: u16 = @truncate((now -| session_start) *| 1000);

            const header = types.EventHeader{
                .event_type = meta.event_type,
                .tool_name = meta.tool_name,
                .role = meta.role,
                .timestamp_offset_ms = offset_ms,
            };

            // Write event to LMDB (non-fatal — failed writes go to dead letter queue)
            store_event: {
                const txn = store.beginWriteTxn() catch |e| {
                    std.debug.print("[lmdb] write txn failed: {}\n", .{e});
                    if (dlq) |*q| q.enqueue(session_id, seq, header, line_copy);
                    break :store_event;
                };
                store.insertEvent(txn, session_id, seq, header, line_copy) catch |e| {
                    store_mod.Store.abortTxn(txn);
                    std.debug.print("[lmdb] insertEvent failed: {}\n", .{e});
                    if (dlq) |*q| q.enqueue(session_id, seq, header, line_copy);
                    break :store_event;
                };
                store_mod.Store.commitTxn(txn) catch |e| {
                    std.debug.print("[lmdb] commit failed: {}\n", .{e});
                    if (dlq) |*q| q.enqueue(session_id, seq, header, line_copy);
                    break :store_event;
                };
            }

            if (meta.event_type == .init_event) {
                if (findJsonStringValue(line_copy, "\"session_id\"")) |sid| {
                    claude_session_id = try allocator.dupe(u8, sid);
                }
            }

            // Stream human-readable output to stdout for interactive runs
            if (stream) |s| {
                streamEvent(s, meta, line_copy);
            }

            // Parse session totals from the result event — it contains cumulative
            // token usage and cost for the entire session (no dedup needed).
            if (meta.event_type == .result) {
                last_meta = meta;
                if (findJsonStringValue(line_copy, "\"result\"")) |rt| {
                    result_text = try allocator.dupe(u8, rt);
                }
                if (findJsonNumberValue(line_copy, "\"total_cost_usd\"")) |cost| {
                    total_cost_microdollars = @intFromFloat(@min(@max(cost * 1000000.0, 0.0), @as(f64, @floatFromInt(@as(u32, std.math.maxInt(u32))))));
                }
                if (findJsonNumberValue(line_copy, "\"input_tokens\"")) |v| {
                    total_input_tokens = @intFromFloat(@max(v, 0.0));
                }
                if (findJsonNumberValue(line_copy, "\"output_tokens\"")) |v| {
                    total_output_tokens = @intFromFloat(@max(v, 0.0));
                }
                if (findJsonNumberValue(line_copy, "\"cache_creation_input_tokens\"")) |v| {
                    total_cache_creation = @intFromFloat(@max(v, 0.0));
                }
                if (findJsonNumberValue(line_copy, "\"cache_read_input_tokens\"")) |v| {
                    total_cache_read = @intFromFloat(@max(v, 0.0));
                }
            }
            seq += 1;
        }
    }

    // Wait for process
    const term = child.wait(io) catch {
        return .{
            .event_count = seq,
            .duration_secs = last_meta.duration_secs,
            .num_turns = last_meta.num_turns,
            .is_error = true,
            .exit_code = -1,
            .result_text = result_text,
            .claude_session_id = claude_session_id,
            .cost_microdollars = total_cost_microdollars,
            .input_tokens = total_input_tokens,
            .output_tokens = total_output_tokens,
            .cache_creation_tokens = total_cache_creation,
            .cache_read_tokens = total_cache_read,
        };
    };

    const exit_code: i16 = switch (term) {
        .exited => |code| @as(i16, @intCast(code)),
        .signal => |sig| -@as(i16, @intCast(@intFromEnum(sig))),
        else => -1,
    };

    return .{
        .event_count = seq,
        .duration_secs = last_meta.duration_secs,
        .num_turns = last_meta.num_turns,
        .is_error = last_meta.is_error or exit_code != 0,
        .exit_code = exit_code,
        .result_text = result_text,
        .claude_session_id = claude_session_id,
        .cost_microdollars = total_cost_microdollars,
        .input_tokens = total_input_tokens,
        .output_tokens = total_output_tokens,
        .cache_creation_tokens = total_cache_creation,
        .cache_read_tokens = total_cache_read,
    };
}

pub fn findJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    var search_start: usize = 0;
    while (search_start < json.len) {
        const key_pos = std.mem.indexOf(u8, json[search_start..], key) orelse return null;
        var pos = search_start + key_pos + key.len;
        search_start = pos;

        while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t')) : (pos += 1) {}

        if (pos >= json.len or json[pos] != '"') continue;
        pos += 1;

        const start = pos;
        while (pos < json.len and json[pos] != '"') {
            if (json[pos] == '\\') {
                pos += 1;
            }
            pos += 1;
        }
        if (pos >= json.len) return null;
        return json[start..pos];
    }
    return null;
}

pub fn findJsonNumberValue(json: []const u8, key: []const u8) ?f64 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    var pos = key_pos + key.len;

    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t')) : (pos += 1) {}

    if (pos >= json.len) return null;

    const start = pos;
    while (pos < json.len and (json[pos] == '-' or json[pos] == '.' or (json[pos] >= '0' and json[pos] <= '9'))) : (pos += 1) {}
    if (pos == start) return null;

    return std.fmt.parseFloat(f64, json[start..pos]) catch null;
}

fn streamEvent(s: *Io.Writer, meta: types.EventMeta, line: []const u8) void {
    switch (meta.event_type) {
        .message => {
            if (meta.role == .assistant) {
                // Print assistant text
                if (findJsonStringValue(line, "\"text\"")) |text| {
                    s.print("{s}\n", .{text}) catch {};
                    s.flush() catch {};
                }
            }
        },
        .tool_use => {
            // Show tool invocation
            const name = findJsonStringValue(line, "\"name\"") orelse "unknown";
            // Try to extract a short preview of the input
            if (findJsonStringValue(line, "\"command\"")) |cmd| {
                s.print("\x1b[36m▶ {s}\x1b[0m $ {s}\n", .{ name, cmd }) catch {};
            } else if (findJsonStringValue(line, "\"file_path\"")) |path| {
                s.print("\x1b[36m▶ {s}\x1b[0m {s}\n", .{ name, path }) catch {};
            } else if (findJsonStringValue(line, "\"pattern\"")) |pat| {
                s.print("\x1b[36m▶ {s}\x1b[0m {s}\n", .{ name, pat }) catch {};
            } else if (findJsonStringValue(line, "\"url\"")) |url| {
                s.print("\x1b[36m▶ {s}\x1b[0m {s}\n", .{ name, url }) catch {};
            } else if (findJsonStringValue(line, "\"prompt\"")) |prompt| {
                const preview = if (prompt.len > 80) prompt[0..80] else prompt;
                s.print("\x1b[36m▶ {s}\x1b[0m {s}...\n", .{ name, preview }) catch {};
            } else {
                s.print("\x1b[36m▶ {s}\x1b[0m\n", .{name}) catch {};
            }
            s.flush() catch {};
        },
        .result => {
            // Final result summary
            if (findJsonNumberValue(line, "\"total_cost_usd\"")) |cost| {
                if (findJsonNumberValue(line, "\"num_turns\"")) |turns| {
                    s.print("\n\x1b[32m✓ Done.\x1b[0m cost=${d:.2} turns={d:.0}\n", .{ cost, turns }) catch {};
                } else {
                    s.print("\n\x1b[32m✓ Done.\x1b[0m cost=${d:.2}\n", .{cost}) catch {};
                }
            } else if (meta.is_error) {
                s.print("\n\x1b[31m✗ Error\x1b[0m\n", .{}) catch {};
            }
            s.flush() catch {};
        },
        else => {},
    }
}

test "parseEventMeta system init" {
    const meta = parseEventMeta("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"abc\"}");
    try std.testing.expectEqual(types.EventType.init_event, meta.event_type);
}

test "parseEventMeta assistant tool_use" {
    const meta = parseEventMeta("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"123\",\"name\":\"Read\",\"input\":{}}]}}");
    try std.testing.expectEqual(types.EventType.tool_use, meta.event_type);
    try std.testing.expectEqual(types.ToolName.read, meta.tool_name);
    try std.testing.expectEqual(types.Role.assistant, meta.role);
}

test "parseEventMeta assistant message" {
    const meta = parseEventMeta("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}}");
    try std.testing.expectEqual(types.EventType.message, meta.event_type);
    try std.testing.expectEqual(types.Role.assistant, meta.role);
}

test "parseEventMeta user tool_result" {
    const meta = parseEventMeta("{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"123\",\"content\":\"ok\"}]}}");
    try std.testing.expectEqual(types.EventType.tool_result, meta.event_type);
    try std.testing.expectEqual(types.Role.user, meta.role);
}

test "parseEventMeta result" {
    const meta = parseEventMeta("{\"type\":\"result\",\"subtype\":\"success\",\"total_cost_usd\":2.34,\"duration_ms\":45000,\"num_turns\":12}");
    try std.testing.expectEqual(types.EventType.result, meta.event_type);
    try std.testing.expectEqual(@as(u16, 234), meta.cost_cents);
    try std.testing.expectEqual(@as(u16, 45), meta.duration_secs);
    try std.testing.expectEqual(@as(u8, 12), meta.num_turns);
    try std.testing.expectEqual(false, meta.is_error);
}

test "parseEventMeta error result" {
    const meta = parseEventMeta("{\"type\":\"result\",\"subtype\":\"error\",\"total_cost_usd\":0.5}");
    try std.testing.expectEqual(true, meta.is_error);
}

test "parseEventMeta legacy init" {
    const meta = parseEventMeta("{\"type\":\"init\",\"session_id\":\"abc\"}");
    try std.testing.expectEqual(types.EventType.init_event, meta.event_type);
}

test "findJsonStringValue" {
    const val = findJsonStringValue("{\"type\":\"init\",\"name\":\"test\"}", "\"type\"");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("init", val.?);
}

test "findJsonNumberValue" {
    const val = findJsonNumberValue("{\"cost\":2.34}", "\"cost\"");
    try std.testing.expect(val != null);
    try std.testing.expectApproxEqAbs(@as(f64, 2.34), val.?, 0.001);
}

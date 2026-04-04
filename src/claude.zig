const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const types = @import("types.zig");
const store_mod = @import("store.zig");

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
    /// Disable session persistence (no ~/.claude/ transcript files).
    no_session_persistence: bool = true,
    /// Additional directories for CLAUDE.md discovery and tool access.
    add_dirs: ?[]const []const u8 = null,
    /// Fallback model when primary is overloaded (529). E.g., "sonnet" for opus sessions.
    fallback_model: ?[]const u8 = null,

    // -- Per-role security (replaces --dangerously-skip-permissions) --

    /// Permission mode: "dontAsk", "plan", etc. Null = legacy --dangerously-skip-permissions.
    permission_mode: ?[]const u8 = null,
    /// Tool specifiers to allow (e.g., "Read", "Bash(git *)").
    allowed_tools: ?[]const []const u8 = null,
    /// Tool specifiers to deny (e.g., "WebSearch", "Bash(curl *)").
    disallowed_tools: ?[]const []const u8 = null,
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
    tool_errors: u16 = 0,
    /// Result subtype: "success", "error_max_turns", "error_max_budget_usd", etc.
    result_subtype: []const u8 = "",
    /// API stop reason: "end_turn", "max_tokens"
    stop_reason: []const u8 = "",
    /// API-only duration (excludes tool execution wait)
    duration_api_ms: u32 = 0,
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

    // Permission model: fine-grained per-role (new) or blanket skip (legacy)
    if (options.permission_mode) |mode| {
        try args.append(allocator, "--permission-mode");
        try args.append(allocator, mode);
        if (options.allowed_tools) |tools| {
            for (tools) |spec| {
                try args.append(allocator, "--allowedTools");
                try args.append(allocator, spec);
            }
        }
        if (options.disallowed_tools) |tools| {
            for (tools) |spec| {
                try args.append(allocator, "--disallowedTools");
                try args.append(allocator, spec);
            }
        }
    } else {
        try args.append(allocator, "--dangerously-skip-permissions");
    }

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

    // Disable session persistence — headless workers don't need ~/.claude/ transcripts.
    // Saves disk I/O and prevents bloat from thousands of sessions.
    if (options.no_session_persistence) {
        try args.append(allocator, "--no-session-persistence");
    }

    // Fallback model for 529 overload (e.g., opus → sonnet)
    if (options.fallback_model) |fm| {
        try args.append(allocator, "--fallback-model");
        try args.append(allocator, fm);
    }

    // Additional directories for CLAUDE.md discovery and tool access
    if (options.add_dirs) |dirs| {
        for (dirs) |dir| {
            try args.append(allocator, "--add-dir");
            try args.append(allocator, dir);
        }
    }

    try args.append(allocator, options.prompt);

    const backend_mod = @import("backend.zig");
    var env_map = backend_mod.buildFilteredEnvMap(allocator);
    defer env_map.deinit();

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
            // Subtypes: success, error_max_turns, error_max_budget_usd,
            // error_during_execution, error_max_structured_output_retries
            if (std.mem.startsWith(u8, subtype, "error")) {
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
            // Detect tool errors: "is_error":true or "<tool_use_error>"
            if (std.mem.indexOf(u8, line, "\"is_error\":true") != null or
                std.mem.indexOf(u8, line, "\"is_error\": true") != null or
                std.mem.indexOf(u8, line, "<tool_use_error>") != null)
            {
                meta.is_error = true;
            }
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
    var search_start: usize = 0;
    while (search_start < json.len) {
        const key_pos = std.mem.indexOf(u8, json[search_start..], key) orelse return null;
        var pos = search_start + key_pos + key.len;
        search_start = pos;

        while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t')) : (pos += 1) {}

        if (pos >= json.len) return null;

        // Value must start with a digit or minus sign (skip non-number values)
        if (json[pos] != '-' and (json[pos] < '0' or json[pos] > '9')) continue;

        const start = pos;
        while (pos < json.len and (json[pos] == '-' or json[pos] == '.' or (json[pos] >= '0' and json[pos] <= '9') or json[pos] == 'e' or json[pos] == 'E' or json[pos] == '+')) : (pos += 1) {}
        if (pos == start) continue;

        return std.fmt.parseFloat(f64, json[start..pos]) catch continue;
    }
    return null;
}

/// Scan a completed session's events in LMDB and extract tool error details
/// into a human-readable summary for the SRE agent.
pub fn collectToolErrors(
    store: *store_mod.Store,
    session_id: u64,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const txn = store.beginReadTxn() catch return null;
    defer store_mod.Store.abortTxn(txn);

    var iter = store.iterSessionEvents(txn, session_id) catch return null;
    defer iter.close();

    var buf: std.ArrayList(u8) = .empty;
    var error_count: u32 = 0;
    var last_tool_name: []const u8 = "";
    var last_tool_cmd: []const u8 = "";

    while (iter.next()) |ev| {
        // Track the most recent tool_use so we can label errors
        if (ev.header.event_type == .tool_use) {
            last_tool_name = findJsonStringValue(ev.raw_json, "\"name\"") orelse "";
            last_tool_cmd = findJsonStringValue(ev.raw_json, "\"command\"") orelse
                findJsonStringValue(ev.raw_json, "\"file_path\"") orelse "";
        }

        // Detect tool errors
        if (ev.header.event_type == .tool_result) {
            const is_err = std.mem.indexOf(u8, ev.raw_json, "\"is_error\":true") != null or
                std.mem.indexOf(u8, ev.raw_json, "\"is_error\": true") != null or
                std.mem.indexOf(u8, ev.raw_json, "<tool_use_error>") != null;
            if (!is_err) continue;

            error_count += 1;
            if (error_count > 10) continue; // Cap to avoid huge prompts

            // Extract the error content (first "content" string that's the actual error)
            const error_text = findJsonStringValue(ev.raw_json, "\"content\"") orelse
                findJsonStringValue(ev.raw_json, "\"text\"") orelse "unknown error";
            const preview_len = @min(error_text.len, 200);

            buf.appendSlice(allocator, "- [") catch continue;
            buf.appendSlice(allocator, last_tool_name) catch continue;
            if (last_tool_cmd.len > 0) {
                buf.appendSlice(allocator, "] `") catch continue;
                const cmd_len = @min(last_tool_cmd.len, 80);
                buf.appendSlice(allocator, last_tool_cmd[0..cmd_len]) catch continue;
                buf.appendSlice(allocator, "` → ") catch continue;
            } else {
                buf.appendSlice(allocator, "] → ") catch continue;
            }
            buf.appendSlice(allocator, error_text[0..preview_len]) catch continue;
            buf.append(allocator, '\n') catch continue;
        }
    }

    if (error_count == 0) return null;

    // Prepend a header
    var result: std.ArrayList(u8) = .empty;
    var count_buf: [32]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d} tool errors in session {d}:\n", .{ error_count, session_id }) catch return null;
    result.appendSlice(allocator, count_str) catch return null;
    result.appendSlice(allocator, buf.items) catch return null;
    buf.deinit(allocator);

    return result.toOwnedSlice(allocator) catch null;
}

pub fn streamEvent(s: *Io.Writer, meta: types.EventMeta, line: []const u8) void {
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

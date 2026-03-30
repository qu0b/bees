const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const backend = @import("backend.zig");
const claude = @import("claude.zig");

/// Build CLI args and spawn `codex exec --json`.
pub fn spawnCodex(allocator: std.mem.Allocator, io: Io, options: backend.BackendOptions) !std.process.Child {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var timeout_buf: [32]u8 = undefined;
    try backend.appendTimeoutArgs(&args, allocator, &timeout_buf, options.timeout_secs);

    try args.append(allocator, "codex");
    try args.append(allocator, "exec");
    try args.append(allocator, "--json");
    try args.append(allocator, "--cd");
    try args.append(allocator, options.cwd);
    try args.append(allocator, "-m");
    try args.append(allocator, options.model);
    try args.append(allocator, "--dangerously-bypass-approvals-and-sandbox");

    // Codex has no system prompt file flag — prepend/append to prompt text
    const combined = try backend.buildPromptWithFiles(allocator, options.prompt, options.system_prompt_file, options.append_prompt_file);
    try args.append(allocator, combined);

    var env_map = backend.buildFilteredEnvMap(allocator);
    defer env_map.deinit();

    var child = try std.process.spawn(io, .{
        .argv = args.items,
        .cwd = .{ .path = options.cwd },
        .environ_map = &env_map,
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = if (options.stdin_data != null) .pipe else .ignore,
    });

    backend.writeStdinAndClose(&child, io, options.stdin_data);
    return child;
}

/// Normalize Codex JSONL events to EventMeta and accumulate results.
///
/// Codex event types:
///   thread.started → init_event
///   item.started + command_execution → tool_use (bash)
///   item.started + file_change → tool_use (write)
///   item.started + mcp_tool_call → tool_use (mcp)
///   item.started + agent_message → message
///   item.completed + command_execution → tool_result
///   item.completed + mcp_tool_call → tool_result
///   turn.completed → result (per-turn accumulation)
///   turn.failed → result (is_error)
pub fn processEvent(line: []const u8, acc: *backend.ResultAccumulator) types.EventMeta {
    var meta = types.EventMeta{
        .event_type = .result,
        .tool_name = .none,
        .is_error = false,
        .role = .none,
        .duration_secs = 0,
        .cost_cents = 0,
        .num_turns = 0,
    };

    const event_type = claude.findJsonStringValue(line, "\"event\"") orelse
        claude.findJsonStringValue(line, "\"type\"") orelse return meta;

    if (std.mem.eql(u8, event_type, "thread.started")) {
        meta.event_type = .init_event;
        if (claude.findJsonStringValue(line, "\"thread_id\"")) |tid| {
            acc.session_id = tid;
        }
    } else if (std.mem.eql(u8, event_type, "item.started")) {
        // Determine item type
        if (std.mem.indexOf(u8, line, "\"command_execution\"") != null) {
            meta.event_type = .tool_use;
            meta.tool_name = .bash;
            meta.role = .assistant;
        } else if (std.mem.indexOf(u8, line, "\"file_change\"") != null) {
            meta.event_type = .tool_use;
            meta.tool_name = .write;
            meta.role = .assistant;
        } else if (std.mem.indexOf(u8, line, "\"mcp_tool_call\"") != null) {
            meta.event_type = .tool_use;
            meta.tool_name = .mcp_tool;
            meta.role = .assistant;
        } else if (std.mem.indexOf(u8, line, "\"agent_message\"") != null) {
            meta.event_type = .message;
            meta.role = .assistant;
        }
    } else if (std.mem.eql(u8, event_type, "item.completed")) {
        if (std.mem.indexOf(u8, line, "\"command_execution\"") != null or
            std.mem.indexOf(u8, line, "\"mcp_tool_call\"") != null)
        {
            meta.event_type = .tool_result;
            meta.role = .user;
            // Check for errors
            if (claude.findJsonStringValue(line, "\"error\"")) |_| {
                meta.is_error = true;
                acc.tool_errors +|= 1;
            }
            if (claude.findJsonNumberValue(line, "\"exit_code\"")) |ec| {
                if (ec != 0) {
                    meta.is_error = true;
                    acc.tool_errors +|= 1;
                }
            }
        }
    } else if (std.mem.eql(u8, event_type, "turn.completed")) {
        meta.event_type = .result;
        acc.num_turns +|= 1;
        // Per-turn token accumulation
        if (claude.findJsonNumberValue(line, "\"input_tokens\"")) |v| {
            acc.input_tokens +|= @intFromFloat(@max(v, 0.0));
        }
        if (claude.findJsonNumberValue(line, "\"output_tokens\"")) |v| {
            acc.output_tokens +|= @intFromFloat(@max(v, 0.0));
        }
        if (claude.findJsonNumberValue(line, "\"cached_input_tokens\"")) |v| {
            acc.cache_read_tokens +|= @intFromFloat(@max(v, 0.0));
        }
    } else if (std.mem.eql(u8, event_type, "turn.failed")) {
        meta.event_type = .result;
        meta.is_error = true;
        acc.is_error = true;
        if (claude.findJsonStringValue(line, "\"message\"")) |_| {}
    }

    return meta;
}

test "processEvent thread.started" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"event\":\"thread.started\",\"thread_id\":\"th_abc123\"}", &acc);
    try std.testing.expectEqual(types.EventType.init_event, meta.event_type);
    try std.testing.expectEqualStrings("th_abc123", acc.session_id);
}

test "processEvent item.started command_execution" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"event\":\"item.started\",\"item\":{\"type\":\"command_execution\",\"command\":\"ls\"}}", &acc);
    try std.testing.expectEqual(types.EventType.tool_use, meta.event_type);
    try std.testing.expectEqual(types.ToolName.bash, meta.tool_name);
}

test "processEvent item.started file_change" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"event\":\"item.started\",\"item\":{\"type\":\"file_change\",\"changes\":[{\"path\":\"foo.txt\"}]}}", &acc);
    try std.testing.expectEqual(types.EventType.tool_use, meta.event_type);
    try std.testing.expectEqual(types.ToolName.write, meta.tool_name);
}

test "processEvent item.started agent_message" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"event\":\"item.started\",\"item\":{\"type\":\"agent_message\",\"text\":\"hello\"}}", &acc);
    try std.testing.expectEqual(types.EventType.message, meta.event_type);
    try std.testing.expectEqual(types.Role.assistant, meta.role);
}

test "processEvent turn.completed accumulates tokens" {
    var acc = backend.ResultAccumulator{};
    _ = processEvent("{\"event\":\"turn.completed\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50,\"cached_input_tokens\":10}}", &acc);
    try std.testing.expectEqual(@as(u32, 100), acc.input_tokens);
    try std.testing.expectEqual(@as(u32, 50), acc.output_tokens);
    try std.testing.expectEqual(@as(u32, 10), acc.cache_read_tokens);
    try std.testing.expectEqual(@as(u8, 1), acc.num_turns);

    // Second turn accumulates
    _ = processEvent("{\"event\":\"turn.completed\",\"usage\":{\"input_tokens\":200,\"output_tokens\":75}}", &acc);
    try std.testing.expectEqual(@as(u32, 300), acc.input_tokens);
    try std.testing.expectEqual(@as(u32, 125), acc.output_tokens);
    try std.testing.expectEqual(@as(u8, 2), acc.num_turns);
}

test "processEvent turn.failed" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"event\":\"turn.failed\",\"error\":{\"message\":\"rate limit\"}}", &acc);
    try std.testing.expectEqual(types.EventType.result, meta.event_type);
    try std.testing.expect(meta.is_error);
    try std.testing.expect(acc.is_error);
}

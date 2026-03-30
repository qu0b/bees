const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const backend = @import("backend.zig");
const claude = @import("claude.zig");
const fs = @import("fs.zig");

/// Build CLI args and spawn `pi -p --mode json`.
pub fn spawnPi(allocator: std.mem.Allocator, io: Io, options: backend.BackendOptions) !std.process.Child {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var timeout_buf: [32]u8 = undefined;
    try backend.appendTimeoutArgs(&args, allocator, &timeout_buf, options.timeout_secs);

    try args.append(allocator, "pi");
    try args.append(allocator, "-p");
    try args.append(allocator, "--mode");
    try args.append(allocator, "json");
    try args.append(allocator, "--provider");

    // Model format for pi: "provider/model" — extract provider, or default to "anthropic"
    var provider: []const u8 = "anthropic";
    var model_name: []const u8 = options.model;
    if (std.mem.indexOf(u8, options.model, "/")) |slash| {
        provider = options.model[0..slash];
        model_name = options.model[slash + 1 ..];
    }
    try args.append(allocator, provider);
    try args.append(allocator, "--model");
    try args.append(allocator, model_name);

    // Map effort to thinking level
    if (std.mem.eql(u8, options.effort, "high")) {
        try args.append(allocator, "--thinking");
        try args.append(allocator, "high");
    } else if (std.mem.eql(u8, options.effort, "medium")) {
        try args.append(allocator, "--thinking");
        try args.append(allocator, "medium");
    } else if (std.mem.eql(u8, options.effort, "low")) {
        try args.append(allocator, "--thinking");
        try args.append(allocator, "low");
    }

    // Pi takes system prompt inline — read files into args (arena-owned, lives until session end)
    if (options.system_prompt_file) |spf| {
        if (fs.readFileAlloc(allocator, spf, 256 * 1024)) |content| {
            try args.append(allocator, "--system-prompt");
            try args.append(allocator, content);
        } else |_| {}
    }

    if (options.append_prompt_file) |apf| {
        if (fs.readFileAlloc(allocator, apf, 256 * 1024)) |content| {
            try args.append(allocator, "--append-system-prompt");
            try args.append(allocator, content);
        } else |_| {}
    }

    try args.append(allocator, "--tools");
    try args.append(allocator, "read,bash,edit,write");

    try args.append(allocator, options.prompt);

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

/// Normalize Pi NDJSON events to EventMeta and accumulate results.
///
/// Pi event types:
///   session → init_event (id, cwd, version)
///   agent_start → init_event
///   tool_execution_start → tool_use
///   tool_execution_end → tool_result
///   message_end (role=assistant) → message
///   message_end (role=user) → message (role=user)
///   agent_end → result (extract tokens from messages[].usage)
///   turn_end → ignored
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

    const event_type = claude.findJsonStringValue(line, "\"type\"") orelse return meta;

    if (std.mem.eql(u8, event_type, "session")) {
        meta.event_type = .init_event;
        if (claude.findJsonStringValue(line, "\"id\"")) |id| {
            acc.session_id = id;
        }
    } else if (std.mem.eql(u8, event_type, "agent_start")) {
        meta.event_type = .init_event;
    } else if (std.mem.eql(u8, event_type, "tool_execution_start")) {
        meta.event_type = .tool_use;
        meta.role = .assistant;
        if (claude.findJsonStringValue(line, "\"toolName\"")) |tool| {
            meta.tool_name = mapPiTool(tool);
        }
    } else if (std.mem.eql(u8, event_type, "tool_execution_end")) {
        meta.event_type = .tool_result;
        meta.role = .user;
        // Check isError field
        if (std.mem.indexOf(u8, line, "\"isError\":true") != null or
            std.mem.indexOf(u8, line, "\"isError\": true") != null)
        {
            meta.is_error = true;
            acc.tool_errors +|= 1;
        }
    } else if (std.mem.eql(u8, event_type, "message_end")) {
        meta.event_type = .message;
        const role = claude.findJsonStringValue(line, "\"role\"") orelse "";
        if (std.mem.eql(u8, role, "assistant")) {
            meta.role = .assistant;
            acc.num_turns +|= 1;
        } else if (std.mem.eql(u8, role, "user")) {
            meta.role = .user;
        }
    } else if (std.mem.eql(u8, event_type, "agent_end")) {
        meta.event_type = .result;
        // Extract token usage from messages — look for usage fields
        if (claude.findJsonNumberValue(line, "\"input_tokens\"")) |v| {
            acc.input_tokens +|= @intFromFloat(@max(v, 0.0));
        }
        if (claude.findJsonNumberValue(line, "\"output_tokens\"")) |v| {
            acc.output_tokens +|= @intFromFloat(@max(v, 0.0));
        }
        if (claude.findJsonNumberValue(line, "\"cache_creation_input_tokens\"")) |v| {
            acc.cache_creation_tokens +|= @intFromFloat(@max(v, 0.0));
        }
        if (claude.findJsonNumberValue(line, "\"cache_read_input_tokens\"")) |v| {
            acc.cache_read_tokens +|= @intFromFloat(@max(v, 0.0));
        }
        // Extract result text from last assistant message
        if (claude.findJsonStringValue(line, "\"text\"")) |text| {
            acc.result_text = text;
        }
    } else if (std.mem.eql(u8, event_type, "turn_end")) {
        // Ignored — redundant with message_end
        meta.event_type = .message;
    }

    return meta;
}

fn mapPiTool(tool: []const u8) types.ToolName {
    if (std.mem.eql(u8, tool, "bash")) return .bash;
    if (std.mem.eql(u8, tool, "read")) return .read;
    if (std.mem.eql(u8, tool, "edit")) return .edit;
    if (std.mem.eql(u8, tool, "write")) return .write;
    if (std.mem.eql(u8, tool, "Bash")) return .bash;
    if (std.mem.eql(u8, tool, "Read")) return .read;
    if (std.mem.eql(u8, tool, "Edit")) return .edit;
    if (std.mem.eql(u8, tool, "Write")) return .write;
    if (std.mem.eql(u8, tool, "glob")) return .glob;
    if (std.mem.eql(u8, tool, "grep")) return .grep;
    return .unknown;
}

test "processEvent session" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"type\":\"session\",\"id\":\"sess_123\",\"cwd\":\"/tmp\",\"version\":\"1.0\"}", &acc);
    try std.testing.expectEqual(types.EventType.init_event, meta.event_type);
    try std.testing.expectEqualStrings("sess_123", acc.session_id);
}

test "processEvent tool_execution_start" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"type\":\"tool_execution_start\",\"toolName\":\"bash\",\"args\":{\"command\":\"ls\"}}", &acc);
    try std.testing.expectEqual(types.EventType.tool_use, meta.event_type);
    try std.testing.expectEqual(types.ToolName.bash, meta.tool_name);
}

test "processEvent tool_execution_end error" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"type\":\"tool_execution_end\",\"result\":\"failed\",\"isError\":true}", &acc);
    try std.testing.expectEqual(types.EventType.tool_result, meta.event_type);
    try std.testing.expect(meta.is_error);
    try std.testing.expectEqual(@as(u16, 1), acc.tool_errors);
}

test "processEvent tool_execution_end success" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"type\":\"tool_execution_end\",\"result\":\"ok\",\"isError\":false}", &acc);
    try std.testing.expectEqual(types.EventType.tool_result, meta.event_type);
    try std.testing.expect(!meta.is_error);
}

test "processEvent message_end assistant" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}", &acc);
    try std.testing.expectEqual(types.EventType.message, meta.event_type);
    try std.testing.expectEqual(types.Role.assistant, meta.role);
    try std.testing.expectEqual(@as(u8, 1), acc.num_turns);
}

test "processEvent agent_end" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":500},\"content\":[{\"type\":\"text\",\"text\":\"All done\"}]}]}", &acc);
    try std.testing.expectEqual(types.EventType.result, meta.event_type);
    try std.testing.expectEqual(@as(u32, 1000), acc.input_tokens);
    try std.testing.expectEqual(@as(u32, 500), acc.output_tokens);
}

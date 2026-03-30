const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const backend = @import("backend.zig");
const claude = @import("claude.zig");
const fs = @import("fs.zig");

/// Build CLI args and spawn `opencode run --format json`.
pub fn spawnOpenCode(allocator: std.mem.Allocator, io: Io, options: backend.BackendOptions) !std.process.Child {
    // Write permission config to worktree so opencode auto-approves tool use
    writePermissionConfig(options.cwd, allocator) catch {};

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var timeout_buf: [32]u8 = undefined;
    try backend.appendTimeoutArgs(&args, allocator, &timeout_buf, options.timeout_secs);

    try args.append(allocator, "opencode");
    try args.append(allocator, "run");
    try args.append(allocator, "--format");
    try args.append(allocator, "json");
    try args.append(allocator, "--dir");
    try args.append(allocator, options.cwd);
    try args.append(allocator, "--model");
    try args.append(allocator, options.model);

    // OpenCode has no system prompt file flag — prepend/append to prompt text
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

/// Write `.opencode/opencode.json` in the worktree to auto-approve all tool use.
fn writePermissionConfig(cwd: []const u8, allocator: std.mem.Allocator) !void {
    const dir_path = try std.fs.path.join(allocator, &.{ cwd, ".opencode" });
    defer allocator.free(dir_path);
    fs.makePath(dir_path) catch {};

    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "opencode.json" });
    defer allocator.free(config_path);

    const config_content = "{\"permission\":{\"bash\":\"allow\",\"edit\":\"allow\",\"write\":\"allow\"}}";
    const file = try fs.createFile(config_path, .{});
    fs.writeFile(file, config_content) catch {};
    fs.closeFile(file);
}

/// Normalize OpenCode NDJSON events to EventMeta and accumulate results.
///
/// OpenCode event types:
///   step_start → init_event
///   tool_use (status=completed) → tool_use + tool_result
///   tool_use (status=error) → tool_result (is_error)
///   text → message (assistant)
///   reasoning → message (assistant)
///   step_finish → result (per-step accumulation with tokens + cost)
///   error → result (is_error)
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

    if (std.mem.eql(u8, event_type, "step_start")) {
        meta.event_type = .init_event;
    } else if (std.mem.eql(u8, event_type, "tool_use")) {
        // Check status to determine if this is tool_use or tool_result
        const status = claude.findJsonStringValue(line, "\"status\"") orelse "";
        if (std.mem.eql(u8, status, "error")) {
            meta.event_type = .tool_result;
            meta.is_error = true;
            meta.role = .user;
            acc.tool_errors +|= 1;
        } else if (std.mem.eql(u8, status, "completed")) {
            // Completed tool — report as tool_use (the result is embedded)
            meta.event_type = .tool_use;
            meta.role = .assistant;
            if (claude.findJsonStringValue(line, "\"tool\"")) |tool| {
                meta.tool_name = mapOpenCodeTool(tool);
            }
        } else {
            // Running or pending — report as tool_use
            meta.event_type = .tool_use;
            meta.role = .assistant;
            if (claude.findJsonStringValue(line, "\"tool\"")) |tool| {
                meta.tool_name = mapOpenCodeTool(tool);
            }
        }
    } else if (std.mem.eql(u8, event_type, "text")) {
        meta.event_type = .message;
        meta.role = .assistant;
    } else if (std.mem.eql(u8, event_type, "reasoning")) {
        meta.event_type = .message;
        meta.role = .assistant;
    } else if (std.mem.eql(u8, event_type, "step_finish")) {
        meta.event_type = .result;
        acc.num_turns +|= 1;
        // Per-step token accumulation
        if (claude.findJsonNumberValue(line, "\"input\"")) |v| {
            acc.input_tokens +|= @intFromFloat(@max(v, 0.0));
        }
        if (claude.findJsonNumberValue(line, "\"output\"")) |v| {
            acc.output_tokens +|= @intFromFloat(@max(v, 0.0));
        }
        // Cache tokens: "cache":{"read":N,"write":N}
        if (claude.findJsonNumberValue(line, "\"read\"")) |v| {
            acc.cache_read_tokens +|= @intFromFloat(@max(v, 0.0));
        }
        if (claude.findJsonNumberValue(line, "\"write\"")) |v| {
            acc.cache_creation_tokens +|= @intFromFloat(@max(v, 0.0));
        }
        // Cost in USD
        if (claude.findJsonNumberValue(line, "\"cost\"")) |cost| {
            acc.cost_microdollars +|= @intFromFloat(@min(@max(cost * 1000000.0, 0.0), @as(f64, @floatFromInt(@as(u32, std.math.maxInt(u32))))));
        }
    } else if (std.mem.eql(u8, event_type, "error")) {
        meta.event_type = .result;
        meta.is_error = true;
        acc.is_error = true;
    }

    return meta;
}

fn mapOpenCodeTool(tool: []const u8) types.ToolName {
    if (std.mem.eql(u8, tool, "bash")) return .bash;
    if (std.mem.eql(u8, tool, "read")) return .read;
    if (std.mem.eql(u8, tool, "edit")) return .edit;
    if (std.mem.eql(u8, tool, "write")) return .write;
    if (std.mem.eql(u8, tool, "glob")) return .glob;
    if (std.mem.eql(u8, tool, "grep")) return .grep;
    return .unknown;
}

test "processEvent step_start" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"type\":\"step_start\",\"part\":{\"snapshot\":\"abc\"}}", &acc);
    try std.testing.expectEqual(types.EventType.init_event, meta.event_type);
}

test "processEvent text" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"type\":\"text\",\"part\":{\"text\":\"Hello world\"}}", &acc);
    try std.testing.expectEqual(types.EventType.message, meta.event_type);
    try std.testing.expectEqual(types.Role.assistant, meta.role);
}

test "processEvent tool_use completed" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"type\":\"tool_use\",\"status\":\"completed\",\"part\":{\"tool\":\"bash\",\"state\":{\"input\":\"ls\",\"output\":\"file.txt\"}}}", &acc);
    try std.testing.expectEqual(types.EventType.tool_use, meta.event_type);
    try std.testing.expectEqual(types.ToolName.bash, meta.tool_name);
}

test "processEvent tool_use error" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"type\":\"tool_use\",\"status\":\"error\",\"part\":{\"tool\":\"bash\",\"state\":{\"error\":\"command not found\"}}}", &acc);
    try std.testing.expectEqual(types.EventType.tool_result, meta.event_type);
    try std.testing.expect(meta.is_error);
    try std.testing.expectEqual(@as(u16, 1), acc.tool_errors);
}

test "processEvent step_finish accumulates tokens and cost" {
    var acc = backend.ResultAccumulator{};
    _ = processEvent("{\"type\":\"step_finish\",\"part\":{\"tokens\":{\"input\":500,\"output\":200,\"cache\":{\"read\":50,\"write\":30}},\"cost\":0.015}}", &acc);
    try std.testing.expectEqual(@as(u32, 500), acc.input_tokens);
    try std.testing.expectEqual(@as(u32, 200), acc.output_tokens);
    try std.testing.expectEqual(@as(u32, 50), acc.cache_read_tokens);
    try std.testing.expectEqual(@as(u32, 30), acc.cache_creation_tokens);
    try std.testing.expectEqual(@as(u32, 15000), acc.cost_microdollars);
    try std.testing.expectEqual(@as(u8, 1), acc.num_turns);
}

test "processEvent error" {
    var acc = backend.ResultAccumulator{};
    const meta = processEvent("{\"type\":\"error\",\"error\":{\"data\":{\"message\":\"rate limit\"}}}", &acc);
    try std.testing.expectEqual(types.EventType.result, meta.event_type);
    try std.testing.expect(meta.is_error);
    try std.testing.expect(acc.is_error);
}

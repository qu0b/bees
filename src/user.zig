const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const backend = @import("backend.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");

/// Run simulated user agents that navigate the app as target personas.
/// Each persona uses browser/devtools MCP to interact with the live product
/// and reports their experience. Results stored as report:user in LMDB.
pub fn runUser(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
    injected_context: ?[]const u8,
    stream_output: bool,
) !void {
    logger.info("[user] starting simulated user engagement", .{});

    // Role template
    const prompt_path = try std.fs.path.join(allocator, &.{ paths.prompts_dir, "user-agent.txt" });
    defer allocator.free(prompt_path);

    // Build user prompt with persona profiles injected
    const users_dir = try std.fs.path.join(allocator, &.{ paths.prompts_dir, "users" });
    defer allocator.free(users_dir);
    const profiles = fs.readDirFiles(allocator, users_dir, 64 * 1024);
    defer if (profiles) |p| allocator.free(p);

    // User prompt: task instruction + context from the context module
    const static_prompt = "Engage with the application as each target user persona. Navigate, interact, and report your experience.";
    const prompt = if (injected_context) |ic|
        std.fmt.allocPrint(allocator, "{s}{s}", .{ static_prompt, ic }) catch static_prompt
    else if (profiles) |p|
        std.fmt.allocPrint(allocator, "{s}\n\n## Target User Personas\n{s}", .{ static_prompt, p }) catch static_prompt
    else
        static_prompt;
    defer if (prompt.ptr != static_prompt.ptr) allocator.free(prompt);

    const now: u64 = fs.timestamp();
    const model = types.ModelType.fromString(cfg.user.model);
    const bt = backend.resolveBackend(cfg.default_backend, cfg.user.backend);
    const header = types.SessionHeader{
        .@"type" = .user,
        .status = .running,
        .has_exit_code = false,
        .has_cost = false,
        .model = model,
        .has_tokens = false,
        .has_duration = false,
        .has_diff_summary = false,
        .backend = bt,
        .worker_id = 0,
        .commit_count = 0,
        .num_turns = 0,
        .exit_code = 0,
        .started_at = @truncate(now),
        .finished_at = 0,
        .duration_ms = 0,
        .cost_microdollars = 0,
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
    };

    const session_id = try store.createSession(header, "User engagement", "", paths.root);

    const result = backend.runSession(store, io, .{
        .backend = bt,
        .prompt = prompt,
        .cwd = paths.root,
        .append_prompt_file = prompt_path,
        .model = cfg.user.model,
        .fallback_model = cfg.user.fallback_model,
        .effort = cfg.user.effort,
        .max_budget_usd = cfg.user.max_budget_usd,
        .mcp_config = cfg.user.mcp_config,
        .stream_output = stream_output,
        .db_dir = paths.db_dir,
    }, session_id, allocator) catch |e| {
        logger.err("[user] session failed: {}", .{e});
        return;
    };
    defer {
        if (result.result_text.len > 0) allocator.free(result.result_text);
        if (result.claude_session_id.len > 0) allocator.free(result.claude_session_id);
    }

    const finish_time: u64 = fs.timestamp();
    const has_tokens = (result.input_tokens > 0 or result.output_tokens > 0);
    const rs = types.ResultSubtype.fromString(result.result_subtype);
    const sr = types.StopReason.fromString(result.stop_reason);
    const new_header = types.SessionHeader{
        .@"type" = .user,
        .status = if (result.is_error) .err else .done,
        .has_exit_code = true,
        .has_cost = true,
        .model = model,
        .has_tokens = has_tokens,
        .has_duration = true,
        .has_diff_summary = false,
        .backend = bt,
        .has_result_detail = rs != .unknown or sr != .unknown,
        .worker_id = 0,
        .commit_count = 0,
        .num_turns = result.num_turns,
        .exit_code = result.exit_code,
        .started_at = @truncate(now),
        .finished_at = @truncate(finish_time),
        .duration_ms = @intCast(@min((finish_time - now) * 1000, std.math.maxInt(u32))),
        .cost_microdollars = result.cost_microdollars,
        .input_tokens = result.input_tokens,
        .output_tokens = result.output_tokens,
        .cache_creation_tokens = result.cache_creation_tokens,
        .cache_read_tokens = result.cache_read_tokens,
        .result_subtype = rs,
        .stop_reason = sr,
        .duration_api_ms = result.duration_api_ms,
    };

    store.updateSessionStatus(session_id, .running, @truncate(now), new_header) catch |e| {
        logger.err("[user] session update failed: {}", .{e});
    };

    // Store user engagement report in LMDB meta for the strategist
    if (result.result_text.len > 0) {
        const txn = store.beginWriteTxn() catch null;
        if (txn) |t| {
            store.putMeta(t, "report:user", result.result_text) catch {};
            store_mod.Store.commitTxn(t) catch {};
        }
    }

    logger.info("[user] engagement complete. cost=${d:.2}", .{
        @as(f64, @floatFromInt(result.cost_microdollars)) / 1000000.0,
    });
}

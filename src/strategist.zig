const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const claude = @import("claude.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");

pub fn runStrategist(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
    stream_output: bool,
    lmdb_context: ?[]const u8,
) !void {
    logger.info("[strategist] starting review cycle", .{});

    // Load prompt from external template file
    const prompt_path = try std.fs.path.join(allocator, &.{ paths.prompts_dir, "strategist.txt" });
    defer allocator.free(prompt_path);
    const base_prompt = fs.readFileAlloc(allocator, prompt_path, 256 * 1024) catch {
        logger.err("[strategist] failed to read prompt template: {s}", .{prompt_path});
        return;
    };
    defer allocator.free(base_prompt);

    // Append LMDB context (QA report + approach trends) if available
    const prompt = if (lmdb_context) |ctx|
        std.fmt.allocPrint(allocator, "{s}{s}", .{ base_prompt, ctx }) catch base_prompt
    else
        base_prompt;
    defer if (prompt.ptr != base_prompt.ptr) allocator.free(prompt);

    const now: u64 = fs.timestamp();
    const model = types.ModelType.fromString(cfg.strategist.model);
    const header = types.SessionHeader{
        .@"type" = .strategist,
        .status = .running,
        .has_exit_code = false,
        .has_cost = false,
        .model = model,
        .has_tokens = false,
        .has_duration = false,
        .has_diff_summary = false,
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

    const session_id = try store.createSession(header, "Strategist review", "", paths.root);

    const result = claude.runClaudeSession(store, io, .{
        .prompt = prompt,
        .cwd = paths.root,
        .model = cfg.strategist.model,
        .effort = cfg.strategist.effort,
        .max_budget_usd = cfg.strategist.max_budget_usd,
        .mcp_config = "/home/ubuntu/agents-swarm/mcp-chrome.json",
        .stream_output = stream_output,
        .db_dir = paths.db_dir,
    }, session_id, allocator) catch |e| {
        logger.err("[strategist] claude session failed: {}", .{e});
        return;
    };

    const finish_time: u64 = fs.timestamp();
    const has_tokens = (result.input_tokens > 0 or result.output_tokens > 0);
    const new_header = types.SessionHeader{
        .@"type" = .strategist,
        .status = if (result.is_error) .err else .done,
        .has_exit_code = true,
        .has_cost = true,
        .model = model,
        .has_tokens = has_tokens,
        .has_duration = true,
        .has_diff_summary = false,
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
    };

    store.updateSessionStatus(session_id, .running, @truncate(now), new_header) catch |e| {
        logger.err("[strategist] session update failed: {}", .{e});
    };

    // Store strategist's result as the updated VISION in LMDB
    if (result.result_text.len > 0) {
        const meta_txn = store.beginWriteTxn() catch null;
        if (meta_txn) |t| {
            store.putMeta(t, "report:vision", result.result_text) catch {};
            store_mod.Store.commitTxn(t) catch {};
        }
    }

    logger.info("[strategist] review complete. cost=${d:.2}", .{
        @as(f64, @floatFromInt(result.cost_microdollars)) / 1000000.0,
    });
}

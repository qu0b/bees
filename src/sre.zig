const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const claude = @import("claude.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");

/// Run SRE agent reactively — triggered by tool errors in a completed session.
/// `error_context` contains the specific tool errors that triggered this run.
/// `trigger_session_id` is the session whose errors triggered SRE.
pub fn runSre(
    cfg: config_mod.Config,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
    stream_output: bool,
    error_context: ?[]const u8,
    trigger_session_id: u64,
) !void {
    logger.info("[sre] triggered by session {d}", .{trigger_session_id});

    // Load prompt template
    const prompt_path_main = try std.fs.path.join(allocator, &.{ paths.prompts_dir, "sre-main.txt" });
    defer allocator.free(prompt_path_main);
    const base_prompt = fs.readFileAlloc(allocator, prompt_path_main, 256 * 1024) catch {
        logger.err("[sre] failed to read prompt template: {s}", .{prompt_path_main});
        return;
    };
    defer allocator.free(base_prompt);

    // Build the full prompt: base template + error context
    const prompt = if (error_context) |ctx|
        std.fmt.allocPrint(allocator, "{s}\n\n## Tool Errors That Triggered This Run\n\nThe following tool errors were observed in session {d}. Diagnose the root cause and fix the configuration, prompts, or tasks to prevent recurrence.\n\n{s}", .{ base_prompt, trigger_session_id, ctx }) catch base_prompt
    else
        base_prompt;
    defer if (prompt.ptr != base_prompt.ptr) allocator.free(prompt);

    const now: u64 = fs.timestamp();
    const model = types.ModelType.fromString(cfg.sre.model);
    const header = types.SessionHeader{
        .@"type" = .sre,
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

    const session_id = try store.createSession(header, "SRE monitoring", "", paths.root);

    const sre_prompt_path = try std.fs.path.join(allocator, &.{ paths.prompts_dir, "sre.txt" });
    defer allocator.free(sre_prompt_path);

    const result = claude.runClaudeSession(store, io, .{
        .prompt = prompt,
        .cwd = paths.root,
        .system_prompt_file = sre_prompt_path,
        .model = cfg.sre.model,
        .effort = cfg.sre.effort,
        .max_budget_usd = cfg.sre.max_budget_usd,
        .max_turns = cfg.sre.max_turns,
        .stream_output = stream_output,
        .db_dir = paths.db_dir,
    }, session_id, allocator) catch |e| {
        logger.err("[sre] claude session failed: {}", .{e});
        return;
    };

    const finish_time: u64 = fs.timestamp();
    const has_tokens = (result.input_tokens > 0 or result.output_tokens > 0);
    const new_header = types.SessionHeader{
        .@"type" = .sre,
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
        logger.err("[sre] session update failed: {}", .{e});
    };

    // Store SRE report in LMDB meta
    if (result.result_text.len > 0) {
        const meta_txn = store.beginWriteTxn() catch null;
        if (meta_txn) |t| {
            store.putMeta(t, "report:sre", result.result_text) catch {};
            store_mod.Store.commitTxn(t) catch {};
        }
    }

    logger.info("[sre] done. cost=${d:.2} triggered_by=session:{d}", .{
        @as(f64, @floatFromInt(result.cost_microdollars)) / 1000000.0,
        trigger_session_id,
    });
}

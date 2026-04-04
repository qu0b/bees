//! Generic role executor — runs any agent role through the standard
//! session lifecycle: create session → run Claude → update status → store report.
//!
//! Used by the workflow engine for roles that follow the standard pattern
//! (QA, user, SRE, strategist). Worker and merger have specialized logic
//! and are handled directly by the workflow engine.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const types = @import("types.zig");
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const backend = @import("backend.zig");
const role_mod = @import("role.zig");
const context = @import("context.zig");
const knowledge = @import("knowledge.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");

/// Run a generic agent role through the standard session lifecycle.
/// Handles: session creation, prompt assembly, Claude execution, status update,
/// optional report storage in LMDB.
pub fn runRole(
    role: role_mod.RoleConfig,
    session_type: types.SessionType,
    session_label: []const u8,
    paths: config_mod.ProjectPaths,
    store: *store_mod.Store,
    logger: *log_mod.Logger,
    io: Io,
    allocator: std.mem.Allocator,
    injected_context: ?[]const u8,
    stream_output: bool,
    default_backend: []const u8,
) !void {
    assert(role.name.len > 0);
    assert(paths.root.len > 0);

    const role_name = role.name;
    logger.info("[{s}] starting", .{role_name});

    // Resolve model and backend
    const model = types.ModelType.fromString(role.model);
    const bt = backend.resolveBackend(default_backend, role.backend);

    // Resolve per-role security permissions
    const perms = role.resolvePermissions() orelse
        role_mod.security_profiles.getDefaultForSessionType(session_type);

    // Create session
    const now: u64 = fs.timestamp();
    const header = types.SessionHeader{
        .type = session_type,
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

    const session_id = try store.createSession(header, session_label, "", paths.root);

    // Build prompt: static instruction + injected context
    const static_prompt_buf = std.fmt.allocPrint(allocator, "Run your {s} cycle for this project.", .{role_name}) catch "Run your cycle.";
    defer if (static_prompt_buf.ptr != "Run your cycle.".ptr) allocator.free(static_prompt_buf);

    const prompt = if (injected_context) |ic|
        std.fmt.allocPrint(allocator, "{s}{s}", .{ static_prompt_buf, ic }) catch static_prompt_buf
    else
        static_prompt_buf;
    defer if (prompt.ptr != static_prompt_buf.ptr) allocator.free(prompt);

    // Run Claude session
    const result = backend.runSession(store, io, .{
        .backend = bt,
        .prompt = prompt,
        .cwd = paths.root,
        .append_prompt_file = if (role.prompt_path.len > 0) role.prompt_path else null,
        .model = role.model,
        .fallback_model = role.fallback_model,
        .effort = role.effort,
        .max_budget_usd = role.max_budget_usd,
        .max_turns = role.max_turns,
        .mcp_config = role.mcp_config,
        .stream_output = stream_output,
        .db_dir = paths.db_dir,
        .permission_mode = if (perms) |p| p.permission_mode else null,
        .allowed_tools = if (perms) |p| if (p.allowed_tools.len > 0) p.allowed_tools else null else null,
        .disallowed_tools = if (perms) |p| if (p.disallowed_tools.len > 0) p.disallowed_tools else null else null,
    }, session_id, allocator) catch |e| {
        logger.err("[{s}] session failed: {}", .{ role_name, e });
        // Mark session as error so it doesn't stay stale as "running".
        var err_header = header;
        err_header.status = .err;
        err_header.finished_at = @truncate(fs.timestamp());
        store.updateSessionStatus(session_id, .running, @truncate(now), err_header) catch {};
        return;
    };
    defer {
        if (result.result_text.len > 0) allocator.free(result.result_text);
        if (result.claude_session_id.len > 0) allocator.free(result.claude_session_id);
    }

    // Update session status
    const finish_time: u64 = fs.timestamp();
    const has_tokens = (result.input_tokens > 0 or result.output_tokens > 0);
    const rs = types.ResultSubtype.fromString(result.result_subtype);
    const sr = types.StopReason.fromString(result.stop_reason);
    const new_header = types.SessionHeader{
        .type = session_type,
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
        logger.err("[{s}] session update failed: {}", .{ role_name, e });
    };

    // Store report in LMDB meta if configured
    if (role.stores_report and result.result_text.len > 0) {
        const report_key = std.fmt.allocPrint(allocator, "report:{s}", .{role_name}) catch return;
        defer allocator.free(report_key);
        const txn = store.beginWriteTxn() catch return;
        store.putMeta(txn, report_key, result.result_text) catch {
            store_mod.Store.abortTxn(txn);
            return;
        };
        store_mod.Store.commitTxn(txn) catch {};
    }

    // Extract and apply knowledge updates from agent output
    if (result.result_text.len > 0) {
        const kb_updates = knowledge.extractUpdates(result.result_text, allocator);
        if (kb_updates.len > 0) {
            const kb_dir = std.fs.path.join(allocator, &.{ paths.bees_dir, "knowledge" }) catch "";
            defer if (kb_dir.len > 0) allocator.free(kb_dir);
            if (kb_dir.len > 0) {
                knowledge.applyUpdates(store, kb_dir, kb_updates, role_name, allocator) catch |e| {
                    logger.warn("[{s}] knowledge update failed: {}", .{ role_name, e });
                };
                logger.info("[{s}] applied {d} knowledge updates", .{ role_name, kb_updates.len });
            }
        }
    }

    logger.info("[{s}] done. cost=${d:.2} turns={d}", .{
        role_name,
        @as(f64, @floatFromInt(result.cost_microdollars)) / 1000000.0,
        result.num_turns,
    });
}

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const config_mod = @import("config.zig");
const types = @import("types.zig");
const store_mod = @import("store.zig");
const dlq_mod = @import("dlq.zig");
const fs = @import("fs.zig");
const claude = @import("claude.zig");
const backend_codex = @import("backend_codex.zig");
const backend_opencode = @import("backend_opencode.zig");
const backend_pi = @import("backend_pi.zig");

// Re-export shared helpers used by callers (api.zig, main.zig, orchestrator.zig)
pub const findJsonStringValue = claude.findJsonStringValue;
pub const findJsonNumberValue = claude.findJsonNumberValue;
pub const collectToolErrors = claude.collectToolErrors;
pub const streamEvent = claude.streamEvent;

// ── Gateway mode ─────────────────────────────────────────────────────────
// Optional Anthropic-compatible gateway (cfg.gateway): every agent session in
// the whole swarm runs against one endpoint serving one model (e.g. LiteLLM at
// ai.starflinger.eu serving "starflinger-anthropic"). Configured once at
// startup; kept as module state so the spawn path — the single choke point all
// backends and the seed's haiku call go through — needs no config plumbing.

const GatewayState = struct {
    active: bool = false,
    text_only: bool = false,
    model: []const u8 = "",
    /// Injected into every child env. The ANTHROPIC_DEFAULT_*_MODEL entries
    /// remap alias model names ("haiku"/"sonnet"/"opus") that reach the Claude
    /// CLI outside the spawn() override (e.g. seed file selection).
    env: [6][2][]const u8 = undefined,
};
var gateway: GatewayState = .{};

/// Activate gateway mode from config. Reads the API key from the environment
/// (never from config.json); fails fast when the key env var is unset so the
/// daemon can't start half-configured. No-op when gateway is disabled.
/// The `gw` string slices must outlive all spawns (they do: config is arena-
/// allocated for the process lifetime).
pub fn configureGateway(gw: config_mod.Config.Gateway) error{GatewayKeyMissing}!void {
    if (!gw.enabled) return;
    // std.c.getenv wants a sentinel-terminated name; config strings aren't.
    // Copy into a bounded buffer (env var names are short by construction).
    var name_buf: [128:0]u8 = undefined;
    if (gw.api_key_env.len >= name_buf.len) return error.GatewayKeyMissing;
    @memcpy(name_buf[0..gw.api_key_env.len], gw.api_key_env);
    name_buf[gw.api_key_env.len] = 0;
    const key = std.c.getenv(&name_buf) orelse return error.GatewayKeyMissing;
    configureGatewayWithKey(gw, std.mem.sliceTo(key, 0));
}

/// Testable core of configureGateway — key passed in instead of read from env.
pub fn configureGatewayWithKey(gw: config_mod.Config.Gateway, api_key: []const u8) void {
    gateway = .{
        .active = true,
        .text_only = gw.text_only,
        .model = gw.model,
        .env = .{
            .{ "ANTHROPIC_BASE_URL", gw.base_url },
            // Bearer endpoints (e.g. vLLM /v1/messages) authenticate via
            // ANTHROPIC_AUTH_TOKEN; the Anthropic default is x-api-key.
            .{ if (gw.bearer) "ANTHROPIC_AUTH_TOKEN" else "ANTHROPIC_API_KEY", api_key },
            .{ "ANTHROPIC_DEFAULT_HAIKU_MODEL", gw.model },
            .{ "ANTHROPIC_DEFAULT_SONNET_MODEL", gw.model },
            .{ "ANTHROPIC_DEFAULT_OPUS_MODEL", gw.model },
            .{ "ANTHROPIC_SMALL_FAST_MODEL", gw.model },
        },
    };
}

pub fn gatewayActive() bool {
    return gateway.active;
}

// ── Per-tool-call ceilings ───────────────────────────────────────────────
// Bounds how long ONE Bash call may run, so a wedged command can't hold a
// session open indefinitely. Complements (does not replace) the stall
// watchdog: only the watchdog covers non-Bash tools, which is what actually
// hung on 2026-08-09 (LSP).

var bash_default_buf: [16]u8 = undefined;
var bash_max_buf: [16]u8 = undefined;
var tool_timeouts: struct { default_ms: []const u8 = "", max_ms: []const u8 = "" } = .{};

/// Configure per-tool-call ceilings injected into every agent child.
pub fn configureToolTimeouts(t: config_mod.Config.Timeouts) void {
    tool_timeouts = .{
        .default_ms = if (t.bash_default_ms > 0)
            std.fmt.bufPrint(&bash_default_buf, "{d}", .{t.bash_default_ms}) catch ""
        else
            "",
        .max_ms = if (t.bash_max_ms > 0)
            std.fmt.bufPrint(&bash_max_buf, "{d}", .{t.bash_max_ms}) catch ""
        else
            "",
    };
}

/// Effective model for a session under gateway mode. Claude alias names
/// (opus/sonnet/haiku/fable) default to the gateway's model; an explicit model
/// id passes through untouched, so a role's config.json can pin any model the
/// gateway serves (e.g. "openrouter/deepseek/deepseek-chat" via LiteLLM).
/// Identity when the gateway is off.
pub fn gatewayEffectiveModel(model: []const u8) []const u8 {
    if (!gateway.active) return model;
    return if (isClaudeModelName(model)) gateway.model else model;
}

/// True when the gateway serves a text-only (no-vision) model. The browser
/// stays available for textual driving (DOM snapshots, console, JS); only
/// image-producing tools (screenshots) are disallowed at spawn.
pub fn gatewayTextOnly() bool {
    return gateway.active and gateway.text_only;
}

// === Shared spawn helpers (used by per-backend spawners) ===

/// Build a filtered environ map for spawning Claude CLI sessions.
/// - Excludes CLAUDECODE to prevent "cannot launch inside another CLI" errors
/// - Sets CLAUDE_CODE_UNATTENDED_RETRY=1 for persistent retry on 429/529
/// Prepend a coreutils `timeout` wrapper to `args` when `timeout_secs > 0`, so a
/// hung agent CLI is force-terminated instead of blocking a worker slot forever.
/// `timeout` sends SIGTERM at the deadline, then SIGKILL 30s later, and exits with
/// code 124 on timeout — which worker.zig's restart-on-timeout logic detects.
///
/// Call this BEFORE appending the binary name. `secs_buf` must outlive the spawn
/// call (the argv slices point into it), so pass a buffer at spawn-fn scope.
pub fn appendTimeoutPrefix(
    args: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    timeout_secs: u32,
    secs_buf: []u8,
) !void {
    if (timeout_secs == 0) return;
    const secs_str = std.fmt.bufPrint(secs_buf, "{d}", .{timeout_secs}) catch return;
    try args.append(allocator, "timeout");
    try args.append(allocator, "--signal=TERM");
    try args.append(allocator, "-k");
    try args.append(allocator, "30");
    try args.append(allocator, secs_str);
}

pub fn buildFilteredEnvMap(allocator: std.mem.Allocator) std.process.Environ.Map {
    var env_map = std.process.Environ.Map.init(allocator);
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const entry_str: [*:0]const u8 = @ptrCast(entry);
        const entry_slice = std.mem.sliceTo(entry_str, 0);
        const eq_pos = std.mem.indexOfScalar(u8, entry_slice, '=') orelse continue;
        const key = entry_slice[0..eq_pos];
        if (std.mem.eql(u8, key, "CLAUDECODE")) continue;
        // Gateway mode: inherited Anthropic credentials must not reach the
        // child — only the gateway's own auth var (injected below) may. An
        // inherited ANTHROPIC_API_KEY would otherwise shadow a bearer token.
        if (gateway.active and (std.mem.eql(u8, key, "ANTHROPIC_API_KEY") or
            std.mem.eql(u8, key, "ANTHROPIC_AUTH_TOKEN"))) continue;
        const value = entry_slice[eq_pos + 1 ..];
        env_map.put(key, value) catch continue;
    }
    // Headless session optimizations (from Claude CLI source analysis):
    // Persistent retry: retries 429/529 indefinitely with exponential backoff
    // (30s heartbeats, 5min max, 6hr cap) instead of dying after 10 retries.
    env_map.put("CLAUDE_CODE_UNATTENDED_RETRY", "1") catch {};
    // Disable auto-memory: workers don't need the memory system writing files
    env_map.put("CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1") catch {};
    // Auto-continue interrupted turns on resume (e.g. after timeout restart)
    env_map.put("CLAUDE_CODE_RESUME_INTERRUPTED_TURN", "1") catch {};
    // Idle timeout: kill sessions that sit idle for 60s after completing work
    env_map.put("CLAUDE_CODE_EXIT_AFTER_STOP_DELAY", "60000") catch {};
    // Prevent streaming-to-non-streaming fallback which causes double tool
    // execution (a partial stream starts a tool, then non-streaming retry
    // produces the same tool_use and runs it again — inc-4258).
    env_map.put("CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK", "1") catch {};
    // Undercover mode: suppress AI attribution in commits, PRs, and code comments.
    // Prevents "Generated by Claude", model codenames, and Co-Authored-By lines.
    env_map.put("CLAUDE_CODE_UNDERCOVER", "1") catch {};
    // Raise file read token limit from default 25K to 50K — workers reading large
    // source files (configs, generated code) hit the cap and get truncated results.
    env_map.put("CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS", "50000") catch {};
    // Bound a single Bash call so a wedged command can't hold the session open.
    if (tool_timeouts.default_ms.len > 0) env_map.put("BASH_DEFAULT_TIMEOUT_MS", tool_timeouts.default_ms) catch {};
    if (tool_timeouts.max_ms.len > 0) env_map.put("BASH_MAX_TIMEOUT_MS", tool_timeouts.max_ms) catch {};
    // Gateway mode: route every child to the configured endpoint/model,
    // deliberately overriding any inherited ANTHROPIC_* variables.
    if (gateway.active) {
        for (gateway.env) |pair| env_map.put(pair[0], pair[1]) catch {};
    }
    return env_map;
}


/// Write stdin data to child process and close stdin pipe.
pub fn writeStdinAndClose(child: *std.process.Child, io: Io, data: ?[]const u8) void {
    const payload = data orelse return;
    if (child.stdin) |stdin| {
        var write_buf: [8192]u8 = undefined;
        var writer = stdin.writerStreaming(io, &write_buf);
        writer.interface.writeAll(payload) catch {};
        writer.interface.flush() catch {};
        stdin.close(io);
    }
    child.stdin = null;
}

/// Read system/append prompt files and build a combined prompt string.
/// Returns the combined prompt (caller owns memory via allocator).
pub fn buildPromptWithFiles(allocator: std.mem.Allocator, prompt: []const u8, system_prompt_file: ?[]const u8, append_prompt_file: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    if (system_prompt_file) |spf| {
        if (fs.readFileAlloc(allocator, spf, 256 * 1024)) |content| {
            defer allocator.free(content);
            try buf.appendSlice(allocator, content);
            try buf.append(allocator, '\n');
        } else |_| {}
    }

    try buf.appendSlice(allocator, prompt);

    if (append_prompt_file) |apf| {
        if (fs.readFileAlloc(allocator, apf, 256 * 1024)) |content| {
            defer allocator.free(content);
            try buf.append(allocator, '\n');
            try buf.appendSlice(allocator, content);
        } else |_| {}
    }

    return buf.toOwnedSlice(allocator) catch prompt;
}

pub const BackendOptions = struct {
    backend: types.BackendType = .claude,
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
    no_session_persistence: bool = true,
    add_dirs: ?[]const []const u8 = null,
    fallback_model: ?[]const u8 = null,
    /// When true with --resume, create a new session instead of reusing the original.
    fork_session: bool = false,

    // -- Per-role security --
    permission_mode: ?[]const u8 = null,
    allowed_tools: ?[]const []const u8 = null,
    disallowed_tools: ?[]const []const u8 = null,

    // -- Extra environment variables injected into the child process --
    extra_env: ?[]const [2][]const u8 = null,

    /// Send the child's stderr to /dev/null instead of inheriting it. Used by the
    /// probe so a backend's internal transport chatter doesn't flood the terminal.
    silence_stderr: bool = false,
};

pub const ResultAccumulator = struct {
    cost_microdollars: u32 = 0,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_creation_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    num_turns: u8 = 0,
    result_text: []const u8 = "",
    session_id: []const u8 = "",
    is_error: bool = false,
    /// Set once a terminal result event has been seen. Until then any cost /
    /// token figure here is a partial running sum, not the authoritative total.
    saw_result: bool = false,
    tool_errors: u16 = 0,
    duration_secs: u16 = 0,
    /// Result subtype: "success", "error_max_turns", "error_max_budget_usd",
    /// "error_during_execution", etc.
    result_subtype: []const u8 = "",
    /// API stop reason: "end_turn", "max_tokens", "stop_sequence"
    stop_reason: []const u8 = "",
    /// API-only duration (excludes tool execution time)
    duration_api_ms: u32 = 0,
};

// ── Active agent child registry ──────────────────────────────────────────
// Every agent CLI process spawned by runSession registers its pid here so the
// daemon's shutdown watchdog can signal in-flight agents. Without this, no one
// ever signals the children: sessions run minutes-to-hours, the drain never
// completes inside systemd's TimeoutStopSec window, and every stop ends in a
// cgroup SIGKILL with sessions left as stale "running" rows.

const max_children = 2 * 64;

/// A live agent process plus the liveness bookkeeping the stall watchdog needs.
/// `last_progress_s` is stamped only by events that mean the agent ADVANCED —
/// never by `tool_progress` heartbeats, which a wedged tool emits forever.
const ChildSlot = struct {
    pid: std.posix.pid_t = 0,
    /// Unix seconds of the last progress event. 0 = slot claimed but not yet
    /// stamped; the watchdog skips those so a recycled slot can't be killed on
    /// its predecessor's timestamp.
    last_progress_s: u64 = 0,
    /// Unix seconds the stall SIGTERM was sent; 0 = none. Gates KILL escalation.
    term_sent_s: u64 = 0,
    session_id: u64 = 0,
};

var active_children: [max_children]ChildSlot = [_]ChildSlot{.{}} ** max_children;

/// Claim a slot for `pid`. Returns its index for later progress stamping, or
/// null when the registry is full (that child then runs unwatched).
fn registerChild(pid: std.posix.pid_t, session_id: u64) ?usize {
    if (pid <= 0) return null;
    for (&active_children, 0..) |*slot, i| {
        if (@cmpxchgStrong(std.posix.pid_t, &slot.pid, 0, pid, .acq_rel, .monotonic) == null) {
            slot.session_id = session_id;
            @atomicStore(u64, &slot.term_sent_s, 0, .release);
            // Published last: makes the slot eligible for the watchdog only
            // once its metadata is valid.
            @atomicStore(u64, &slot.last_progress_s, fs.timestamp(), .release);
            return i;
        }
    }
    // Registry full — the child simply won't receive a shutdown signal.
    return null;
}

fn unregisterChild(pid: std.posix.pid_t) void {
    if (pid <= 0) return;
    for (&active_children) |*slot| {
        if (@atomicLoad(std.posix.pid_t, &slot.pid, .acquire) != pid) continue;
        // Retire the liveness data BEFORE releasing the slot, so the next
        // claimant never inherits a stale progress timestamp.
        @atomicStore(u64, &slot.last_progress_s, 0, .release);
        @atomicStore(u64, &slot.term_sent_s, 0, .release);
        if (@cmpxchgStrong(std.posix.pid_t, &slot.pid, pid, 0, .acq_rel, .monotonic) == null) return;
    }
}

/// Record that the child in `slot_index` produced a real progress event.
fn stampProgress(slot_index: usize) void {
    if (slot_index >= active_children.len) return;
    @atomicStore(u64, &active_children[slot_index].last_progress_s, fs.timestamp(), .release);
}

pub fn hasActiveChildren() bool {
    for (&active_children) |*slot| {
        if (@atomicLoad(std.posix.pid_t, &slot.pid, .acquire) != 0) return true;
    }
    return false;
}

/// An agent process the watchdog acted on, for the caller to log.
pub const StalledChild = struct {
    pid: std.posix.pid_t,
    session_id: u64,
    idle_secs: u64,
    /// false = first SIGTERM, true = SIGKILL follow-up.
    escalated: bool,
};

/// Seconds between the stall SIGTERM and its SIGKILL follow-up.
pub const stall_kill_grace_secs: u64 = 30;

/// Signal every agent process that has made no progress for `idle_limit_secs`.
/// TERM first (the CLI flushes and exits, its stdout closes, and runSession
/// returns normally with a negative exit code), KILL if it ignores that.
/// Returns how many entries of `out` were filled. 0 disables the watchdog.
///
/// This is the Zig-native replacement for the external `timeout` wrapper, which
/// cannot be used here (it breaks the agent CLI under io_uring — see
/// config.Daemon.worker_timeout_minutes).
pub fn reapStalledChildren(idle_limit_secs: u32, out: []StalledChild) usize {
    if (idle_limit_secs == 0 or out.len == 0) return 0;
    const now = fs.timestamp();
    var n: usize = 0;
    for (&active_children) |*slot| {
        if (n >= out.len) break;
        var idle: u64 = 0;
        const action = classifyStall(slot, now, idle_limit_secs, &idle);
        if (action == .none) continue;
        const pid = @atomicLoad(std.posix.pid_t, &slot.pid, .acquire);
        switch (action) {
            .term => std.posix.kill(pid, std.c.SIG.TERM) catch continue,
            .kill => std.posix.kill(pid, std.c.SIG.KILL) catch continue,
            .none => unreachable,
        }
        out[n] = .{
            .pid = pid,
            .session_id = slot.session_id,
            .idle_secs = idle,
            .escalated = action == .kill,
        };
        n += 1;
    }
    return n;
}

const StallAction = enum { none, term, kill };

/// Decide what to do with one slot, and record that the decision was made.
/// Split from the signaling so the escalation state machine is testable with a
/// caller-supplied `now` and no real process.
fn classifyStall(slot: *ChildSlot, now: u64, idle_limit_secs: u32, idle_out: *u64) StallAction {
    if (@atomicLoad(std.posix.pid_t, &slot.pid, .acquire) <= 0) return .none;
    const last = @atomicLoad(u64, &slot.last_progress_s, .acquire);
    if (last == 0) return .none; // claimed but not yet stamped
    const idle = now -| last;
    idle_out.* = idle;
    if (idle <= idle_limit_secs) return .none;

    const term_at = @atomicLoad(u64, &slot.term_sent_s, .acquire);
    if (term_at == 0) {
        @atomicStore(u64, &slot.term_sent_s, now, .release);
        return .term;
    }
    if (now -| term_at >= stall_kill_grace_secs) {
        // Re-arm so an unkillable process is acted on once per grace window
        // rather than on every tick.
        @atomicStore(u64, &slot.term_sent_s, now, .release);
        return .kill;
    }
    return .none;
}

pub const ChildSignal = enum { term, kill };

/// Signal every registered agent child. Returns how many were signaled.
/// TERM lets the CLIs shut down cleanly (flush transcripts, mark sessions);
/// KILL is the follow-up for stragglers.
pub fn signalActiveChildren(sig: ChildSignal) u32 {
    var n: u32 = 0;
    for (&active_children) |*slot| {
        const pid = @atomicLoad(std.posix.pid_t, &slot.pid, .acquire);
        if (pid == 0) continue;
        switch (sig) {
            .term => std.posix.kill(pid, std.c.SIG.TERM) catch continue,
            .kill => std.posix.kill(pid, std.c.SIG.KILL) catch continue,
        }
        n += 1;
    }
    return n;
}

/// Saturating f64 → u32 for numbers parsed from untrusted child stdout.
/// A malformed value (e.g. "input_tokens":1e300, inf, or NaN) must never
/// reach `@intFromFloat` directly — that is checked illegal behavior and
/// would abort the whole daemon. The `!(v > 0)` form also maps NaN to 0.
fn f64ToU32Sat(v: f64) u32 {
    if (!(v > 0)) return 0;
    const max_f: f64 = @floatFromInt(@as(u32, std.math.maxInt(u32)));
    return if (v >= max_f) std.math.maxInt(u32) else @intFromFloat(v);
}

/// Saturating f64 → u64 for numbers parsed out of untrusted event JSON
/// (replayed raw_json blobs). Same contract as `f64ToU32Sat`: `!(v > 0)`
/// maps NaN and negatives to 0, and an out-of-range cast is avoided because
/// `@intFromFloat` past the destination range is illegal behavior.
pub fn f64ToU64Sat(v: f64) u64 {
    if (!(v > 0)) return 0;
    const max_f: f64 = @floatFromInt(@as(u64, std.math.maxInt(u64)));
    return if (v >= max_f) std.math.maxInt(u64) else @intFromFloat(v);
}

/// True if `model` is a Claude-family model name. Non-Claude backends (Codex)
/// must not receive these — they use their own provider's models.
pub fn isClaudeModelName(model: []const u8) bool {
    const names = [_][]const u8{ "opus", "sonnet", "haiku", "fable" };
    for (names) |n| {
        if (std.mem.eql(u8, model, n)) return true;
    }
    return false;
}

/// Resolve the effective backend: use role-specific override if non-empty, else project default.
/// Gateway mode overrides everything — the gateway speaks the Anthropic API,
/// so only the Claude backend can talk to it.
pub fn resolveBackend(default_backend: []const u8, role_backend: []const u8) types.BackendType {
    if (gateway.active) return .claude;
    const effective = if (role_backend.len > 0) role_backend else default_backend;
    return types.BackendType.fromString(effective);
}

/// Dispatch spawn to the appropriate backend.
/// Max bytes of prompt passed as a single argv string. Linux caps each argv
/// string at MAX_ARG_STRLEN (32 pages = 128 KiB); exceeding it makes execve fail
/// E2BIG, surfacing as error.SystemResources with no syscall visible in the
/// parent. Prompts above this are delivered via stdin instead (both the Claude
/// and Codex CLIs read piped stdin as user input). Margin below 128 KiB left
/// for the rest of argv.
pub const max_argv_prompt_bytes: usize = 100_000;

fn spawn(backend: types.BackendType, allocator: std.mem.Allocator, io: Io, options: BackendOptions, claude_binary: []const u8, pi_binary: []const u8) !std.process.Child {
    var opts = options;
    if (gateway.active and backend == .claude) {
        // Claude alias models default to the gateway's model; explicit ids
        // (a role pinning e.g. an openrouter/* model) pass through. Alias
        // fallbacks are dropped — they'd resolve to the same gateway model.
        opts.model = gatewayEffectiveModel(options.model);
        opts.fallback_model = if (options.fallback_model) |fm|
            (if (isClaudeModelName(fm)) null else fm)
        else
            null;
        // Text-only model (no vision): the browser stays usable — DOM/a11y
        // snapshots, console, network, evaluate_script are all textual — but
        // image-producing tools would feed the model bytes it cannot see.
        if (gateway.text_only) {
            const screenshot_tool = "mcp__chrome-devtools__take_screenshot";
            const old = opts.disallowed_tools orelse &.{};
            if (allocator.alloc([]const u8, old.len + 1)) |list| {
                @memcpy(list[0..old.len], old);
                list[old.len] = screenshot_tool;
                opts.disallowed_tools = list;
            } else |_| {} // OOM: keep the original deny list
        }
    }
    if (opts.prompt.len > max_argv_prompt_bytes and backend == .claude) {
        // Move the oversized prompt to stdin — the Claude CLI reads piped stdin
        // as user input alongside the argv prompt. If a stdin payload already
        // exists, prepend the prompt so the model sees prompt-then-data.
        // Codex handles its own overflow inside spawnCodex (it composes the
        // final prompt from files there, and its stdin marker must be a bare
        // final argv of exactly "-"). opencode/pi stdin semantics are
        // unverified — those fail loudly rather than being silently altered.
        opts.stdin_data = if (options.stdin_data) |sd|
            try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ options.prompt, sd })
        else
            options.prompt;
        opts.prompt = "Your full instructions and context are provided via stdin. Read them and proceed.";
    }
    return spawnResolved(backend, allocator, io, opts, claude_binary, pi_binary);
}

fn spawnResolved(backend: types.BackendType, allocator: std.mem.Allocator, io: Io, options: BackendOptions, claude_binary: []const u8, pi_binary: []const u8) !std.process.Child {
    return switch (backend) {
        .claude => claude.spawnClaude(allocator, io, .{
            .prompt = options.prompt,
            .cwd = options.cwd,
            .system_prompt_file = options.system_prompt_file,
            .append_prompt_file = options.append_prompt_file,
            .model = options.model,
            .effort = options.effort,
            .max_budget_usd = options.max_budget_usd,
            .stdin_data = options.stdin_data,
            .timeout_secs = options.timeout_secs,
            .resume_session_id = options.resume_session_id,
            .fork_session = options.fork_session,
            .mcp_config = options.mcp_config,
            .max_turns = options.max_turns,
            .stream_output = options.stream_output,
            .db_dir = options.db_dir,
            .no_session_persistence = options.no_session_persistence,
            .add_dirs = options.add_dirs,
            .fallback_model = options.fallback_model,
            .permission_mode = options.permission_mode,
            .allowed_tools = options.allowed_tools,
            .disallowed_tools = options.disallowed_tools,
            .extra_env = options.extra_env,
            .silence_stderr = options.silence_stderr,
        }, claude_binary),
        .codex => backend_codex.spawnCodex(allocator, io, options),
        .opencode => backend_opencode.spawnOpenCode(allocator, io, options),
        .pi => backend_pi.spawnPi(allocator, io, options, pi_binary),
    };
}

pub const ProbeStatus = enum { ok, auth_error, timeout, failed };

/// Wall-clock ceiling for a single probe. The `timeout` wrapper sends TERM at
/// this mark (then KILL 30s later), so a stuck/overloaded backend can't hang the
/// health check. Healthy models answer a one-word prompt in a few seconds.
pub const probe_timeout_secs: u32 = 45;

/// Spawn a minimal real agent call for (backend, model, effort) and confirm it
/// actually produced a completion — verifying auth, model access, and that the
/// effort is accepted. Used by `bees doctor --probe`. Does no real work: 1 turn,
/// tiny budget, bounded by a timeout, stderr silenced, and it goes through the
/// normal spawn path so env filtering (CLAUDECODE etc.) applies.
///
/// A non-zero exit is NOT trusted as success — some backends exit 0 even when
/// the model call failed. We require a genuine completion event in the output.
pub fn probeBackend(
    allocator: std.mem.Allocator,
    io: Io,
    bt: types.BackendType,
    model: []const u8,
    effort: []const u8,
    cwd: []const u8,
    claude_binary: []const u8,
    pi_binary: []const u8,
    /// When set (claude only), fork a session from this seed uuid — probing the
    /// cross-role cache-lineage path, which can break independently of bare
    /// model calls (e.g. the 2026-07-22 previous_message_id API 400).
    resume_session_id: ?[]const u8,
) ProbeStatus {
    var child = spawn(bt, allocator, io, .{
        .backend = bt,
        .prompt = "Reply with exactly: OK",
        .cwd = cwd,
        .model = model,
        .effort = effort,
        // A seed fork ingests the full context blob (up to ~200K tokens), which
        // alone exceeds $1 — a bare model call needs only pennies.
        .max_budget_usd = if (resume_session_id != null) 5.0 else 1.0,
        .max_turns = 1,
        .timeout_secs = probe_timeout_secs,
        .silence_stderr = true,
        .resume_session_id = resume_session_id,
        .fork_session = resume_session_id != null,
    }, claude_binary, pi_binary) catch return .failed;

    var saw_auth = false;
    var saw_success = false;
    if (child.stdout) |out| {
        var buf: [64 * 1024]u8 = undefined;
        var reader = out.readerStreaming(io, &buf);
        while (true) {
            const line = reader.interface.takeDelimiter('\n') catch |e| switch (e) {
                error.ReadFailed => break,
                error.StreamTooLong => {
                    _ = reader.interface.discardDelimiterInclusive('\n') catch break;
                    continue;
                },
            };
            const l = line orelse break;
            if (l.len == 0) continue;
            if (std.mem.indexOf(u8, l, "authentication_error") != null or
                std.mem.indexOf(u8, l, "\"401\"") != null or
                std.mem.indexOf(u8, l, "Invalid authentication") != null or
                std.mem.indexOf(u8, l, "invalid_api_key") != null)
            {
                saw_auth = true;
            }
            // Require a real completion signal, not just a clean exit.
            if (bt == .claude) {
                if (std.mem.indexOf(u8, l, "\"subtype\":\"success\"") != null) saw_success = true;
            } else {
                if (std.mem.indexOf(u8, l, "turn.completed") != null or
                    std.mem.indexOf(u8, l, "agent_message") != null) saw_success = true;
            }
        }
    }

    const term = child.wait(io) catch return .failed;
    if (saw_auth) return .auth_error;
    const code: i64 = switch (term) {
        .exited => |c| c,
        else => -1,
    };
    if (code == 124) return .timeout; // `timeout` wrapper fired
    if (code == 0 and saw_success) return .ok;
    return .failed;
}

/// Dispatch event processing to the appropriate backend normalizer.
fn processEvent(backend: types.BackendType, line: []const u8, acc: *ResultAccumulator) types.EventMeta {
    const meta = switch (backend) {
        .claude => claudeProcessEvent(line, acc),
        .codex => backend_codex.processEvent(line, acc),
        .opencode => backend_opencode.processEvent(line, acc),
        .pi => backend_pi.processEvent(line, acc),
    };
    // claudeProcessEvent sets saw_result itself. The other adapters normalize
    // their terminal events to .result; require a recognized event-kind key so
    // an unparseable line (whose EventMeta default is .result) is not mistaken
    // for a completed session. Codex keys its events on "event", not "type" —
    // checking only "type" would leave every Codex session cost_known = false.
    if (backend != .claude and meta.event_type == .result and
        (claude.findJsonStringValue(line, "\"event\"") != null or
            claude.findJsonStringValue(line, "\"type\"") != null))
    {
        acc.saw_result = true;
    }
    return meta;
}

/// Claude adapter: wraps existing parseEventMeta + result field extraction into the accumulator pattern.
/// NOTE: acc.result_text, acc.session_id, acc.result_subtype, and acc.stop_reason
/// are set to slices into `line`. Callers must dupe these before freeing the line buffer.
fn claudeProcessEvent(line: []const u8, acc: *ResultAccumulator) types.EventMeta {
    const meta = claude.parseEventMeta(line);

    if (meta.event_type == .tool_result and meta.is_error) {
        acc.tool_errors +|= 1;
    }

    if (meta.event_type == .init_event) {
        if (claude.findJsonStringValue(line, "\"session_id\"")) |sid| {
            acc.session_id = sid;
        }
    }

    // Accumulate per-message usage so a SIGTERMed/timed-out session still reports
    // the tokens it actually burned. The result branch below assigns (not +|=),
    // so the authoritative totals overwrite this running sum — no double count.
    if (meta.event_type == .message or meta.event_type == .tool_use) {
        if (meta.role == .assistant) {
            if (claude.findJsonNumberValue(line, "\"input_tokens\"")) |v| acc.input_tokens +|= f64ToU32Sat(v);
            if (claude.findJsonNumberValue(line, "\"output_tokens\"")) |v| acc.output_tokens +|= f64ToU32Sat(v);
            if (claude.findJsonNumberValue(line, "\"cache_creation_input_tokens\"")) |v| acc.cache_creation_tokens +|= f64ToU32Sat(v);
            if (claude.findJsonNumberValue(line, "\"cache_read_input_tokens\"")) |v| acc.cache_read_tokens +|= f64ToU32Sat(v);
        }
    }

    if (meta.event_type == .result) {
        acc.saw_result = true;
        acc.is_error = meta.is_error;
        acc.duration_secs = meta.duration_secs;
        acc.num_turns = meta.num_turns;

        if (claude.findJsonStringValue(line, "\"result\"")) |rt| {
            acc.result_text = rt;
        }
        // Result subtype: success, error_max_turns, error_max_budget_usd,
        // error_during_execution, error_max_structured_output_retries
        if (claude.findJsonStringValue(line, "\"subtype\"")) |st| {
            acc.result_subtype = st;
            // Any error_ prefix means error (not just "error")
            if (std.mem.startsWith(u8, st, "error")) {
                acc.is_error = true;
            }
        }
        if (claude.findJsonStringValue(line, "\"stop_reason\"")) |sr| {
            acc.stop_reason = sr;
        }
        if (claude.findJsonNumberValue(line, "\"total_cost_usd\"")) |cost| {
            acc.cost_microdollars = f64ToU32Sat(cost * 1000000.0);
        }
        if (claude.findJsonNumberValue(line, "\"duration_api_ms\"")) |v| {
            acc.duration_api_ms = f64ToU32Sat(v);
        }
        if (claude.findJsonNumberValue(line, "\"input_tokens\"")) |v| {
            acc.input_tokens = f64ToU32Sat(v);
        }
        if (claude.findJsonNumberValue(line, "\"output_tokens\"")) |v| {
            acc.output_tokens = f64ToU32Sat(v);
        }
        if (claude.findJsonNumberValue(line, "\"cache_creation_input_tokens\"")) |v| {
            acc.cache_creation_tokens = f64ToU32Sat(v);
        }
        if (claude.findJsonNumberValue(line, "\"cache_read_input_tokens\"")) |v| {
            acc.cache_read_tokens = f64ToU32Sat(v);
        }
    }

    return meta;
}

pub const SessionResult = claude.SessionResult;

/// Unified session loop — runs any backend, stores events in LMDB, streams output.
pub fn runSession(
    store: *store_mod.Store,
    io: Io,
    options: BackendOptions,
    session_id: u64,
    allocator: std.mem.Allocator,
    claude_binary: []const u8,
    pi_binary: []const u8,
) !SessionResult {
    assert(session_id > 0);
    assert(options.prompt.len > 0);
    assert(options.cwd.len > 0);

    var child = try spawn(options.backend, allocator, io, options, claude_binary, pi_binary);
    // Register for the daemon's shutdown watchdog; always unregister on exit.
    // Capture the pid locally — wait() may clear child.id before the defer runs.
    const child_pid: std.posix.pid_t = child.id orelse 0;
    const child_slot: ?usize = if (child_pid > 0) registerChild(child_pid, session_id) else null;
    defer if (child_pid > 0) unregisterChild(child_pid);

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
    var acc = ResultAccumulator{};
    const session_start = fs.timestamp();

    // Store the user prompt as a synthetic event so the dashboard can display it.
    {
        var prompt_json_buf: [8192]u8 = undefined;
        const prefix = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"";
        const suffix = if (options.stdin_data != null) " [+ stdin data]\"}]}}" else "\"}]}}";
        if (prefix.len < prompt_json_buf.len) {
            @memcpy(prompt_json_buf[0..prefix.len], prefix);
            var pos: usize = prefix.len;
            const prompt_preview = if (options.prompt.len > 3000) options.prompt[0..3000] else options.prompt;
            for (prompt_preview) |ch| {
                if (pos + 2 >= prompt_json_buf.len - suffix.len) break;
                switch (ch) {
                    '"' => { prompt_json_buf[pos] = '\\'; prompt_json_buf[pos + 1] = '"'; pos += 2; },
                    '\\' => { prompt_json_buf[pos] = '\\'; prompt_json_buf[pos + 1] = '\\'; pos += 2; },
                    '\n' => { prompt_json_buf[pos] = '\\'; prompt_json_buf[pos + 1] = 'n'; pos += 2; },
                    '\r' => { prompt_json_buf[pos] = '\\'; prompt_json_buf[pos + 1] = 'r'; pos += 2; },
                    '\t' => { prompt_json_buf[pos] = '\\'; prompt_json_buf[pos + 1] = 't'; pos += 2; },
                    else => {
                        if (ch >= 0x20) { prompt_json_buf[pos] = ch; pos += 1; }
                    },
                }
            }
            if (pos + suffix.len <= prompt_json_buf.len) {
                @memcpy(prompt_json_buf[pos..][0..suffix.len], suffix);
                pos += suffix.len;
                const prompt_header = types.EventHeader{
                    .event_type = .message,
                    .tool_name = .none,
                    .role = .user,
                    .timestamp_offset_ms = 0,
                };
                store_event: {
                    const txn = store.beginWriteTxn() catch break :store_event;
                    store.insertEvent(txn, session_id, seq, prompt_header, prompt_json_buf[0..pos]) catch {
                        store_mod.Store.abortTxn(txn);
                        break :store_event;
                    };
                    store_mod.Store.commitTxn(txn) catch break :store_event;
                }
                seq += 1;
            }
        }
    }

    // Read stdout line by line
    if (child.stdout) |stdout_file| {
        var read_buf: [256 * 1024]u8 = undefined;
        var reader = stdout_file.readerStreaming(io, &read_buf);

        while (true) {
            const line = reader.interface.takeDelimiter('\n') catch |e| switch (e) {
                error.ReadFailed => break,
                error.StreamTooLong => {
                    _ = reader.interface.discardDelimiterInclusive('\n') catch break;
                    continue;
                },
            };
            if (line == null) break;
            const line_data = line.?;
            if (line_data.len == 0) continue;

            // Guard: divert non-JSON lines to stderr (library banners, stray prints)
            if (line_data.len == 0 or line_data[0] != '{') {
                std.debug.print("[stdout-guard] {s}\n", .{line_data[0..@min(line_data.len, 200)]});
                continue;
            }

            const line_copy = try allocator.dupe(u8, line_data);
            defer allocator.free(line_copy);

            // Save old accumulator string values before processEvent overwrites them.
            // These may be heap dupes from previous iterations that need freeing.
            const old_result_text = acc.result_text;
            const old_session_id = acc.session_id;
            const old_result_subtype = acc.result_subtype;
            const old_stop_reason = acc.stop_reason;

            const meta = processEvent(options.backend, line_copy, &acc);

            // processEvent stores slices into line_copy for string fields.
            // Dupe them now before line_copy is freed at end of iteration,
            // then free any old heap dupes that were replaced.
            {
                const base = @intFromPtr(line_copy.ptr);
                const end = base + line_copy.len;

                // Dupe any field that points into line_copy (about to be freed)
                // result_text is the only field that carries free-form agent
                // prose, so it is the only one that needs JSON escapes decoded.
                // Decode exactly here — the single point where it stops pointing
                // into the raw line buffer. session_id/subtype/stop_reason are
                // escape-free enum-like tokens and stay raw.
                if (acc.result_text.len > 0) {
                    const p = @intFromPtr(acc.result_text.ptr);
                    if (p >= base and p < end)
                        acc.result_text = try claude.jsonUnescapeAlloc(allocator, acc.result_text);
                }
                if (acc.session_id.len > 0) {
                    const p = @intFromPtr(acc.session_id.ptr);
                    if (p >= base and p < end)
                        acc.session_id = try allocator.dupe(u8, acc.session_id);
                }
                if (acc.result_subtype.len > 0) {
                    const p = @intFromPtr(acc.result_subtype.ptr);
                    if (p >= base and p < end)
                        acc.result_subtype = try allocator.dupe(u8, acc.result_subtype);
                }
                if (acc.stop_reason.len > 0) {
                    const p = @intFromPtr(acc.stop_reason.ptr);
                    if (p >= base and p < end)
                        acc.stop_reason = try allocator.dupe(u8, acc.stop_reason);
                }

                // Free old heap dupes that were replaced by processEvent.
                // An old value is a heap dupe if: len > 0, pointer changed,
                // and it does NOT point into the current line_copy (which means
                // it was duped in a previous iteration, not a static literal).
                // Static defaults ("") have len 0, already filtered out.
                if (old_result_text.len > 0 and old_result_text.ptr != acc.result_text.ptr) {
                    const op = @intFromPtr(old_result_text.ptr);
                    if (op < base or op >= end)
                        allocator.free(old_result_text);
                }
                if (old_session_id.len > 0 and old_session_id.ptr != acc.session_id.ptr) {
                    const op = @intFromPtr(old_session_id.ptr);
                    if (op < base or op >= end)
                        allocator.free(old_session_id);
                }
                if (old_result_subtype.len > 0 and old_result_subtype.ptr != acc.result_subtype.ptr) {
                    const op = @intFromPtr(old_result_subtype.ptr);
                    if (op < base or op >= end)
                        allocator.free(old_result_subtype);
                }
                if (old_stop_reason.len > 0 and old_stop_reason.ptr != acc.stop_reason.ptr) {
                    const op = @intFromPtr(old_stop_reason.ptr);
                    if (op < base or op >= end)
                        allocator.free(old_stop_reason);
                }
            }

            // A heartbeat proves the child is alive, not that it is advancing:
            // never stamp progress, store, or stream it. (2026-08-09: one wedged
            // LSP call emitted 986 of these over 8h while the daemon waited.)
            if (meta.event_type == .tool_progress) continue;

            // Real progress — reset this child's stall clock.
            if (child_slot) |si| stampProgress(si);

            const now: u64 = fs.timestamp();
            const offset_ms: u16 = @truncate((now -| session_start) *| 1000);

            const header = types.EventHeader{
                .event_type = meta.event_type,
                .tool_name = meta.tool_name,
                .role = meta.role,
                .timestamp_offset_ms = offset_ms,
            };

            // Write event to LMDB (non-fatal)
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

            // Stream human-readable output to stdout for interactive runs
            if (stream) |s| {
                streamEvent(s, meta, line_copy);
            }

            seq += 1;
        }
    }

    // Wait for process
    const term = child.wait(io) catch {
        return .{
            .event_count = seq,
            .duration_secs = acc.duration_secs,
            .num_turns = acc.num_turns,
            .is_error = true,
            .exit_code = -1,
            .result_text = acc.result_text,
            .claude_session_id = acc.session_id,
            .cost_microdollars = acc.cost_microdollars,
            .cost_known = acc.saw_result,
            .input_tokens = acc.input_tokens,
            .output_tokens = acc.output_tokens,
            .cache_creation_tokens = acc.cache_creation_tokens,
            .cache_read_tokens = acc.cache_read_tokens,
            .tool_errors = acc.tool_errors,
            .result_subtype = acc.result_subtype,
            .stop_reason = acc.stop_reason,
            .duration_api_ms = acc.duration_api_ms,
        };
    };

    const exit_code: i16 = switch (term) {
        .exited => |code| @as(i16, @intCast(code)),
        .signal => |sig| -@as(i16, @intCast(@intFromEnum(sig))),
        else => -1,
    };

    // Clean up Chrome tabs if this session used MCP (chrome-devtools)
    if (options.mcp_config != null) {
        cleanupChromeTabs(io);
    }

    return .{
        .event_count = seq,
        .duration_secs = acc.duration_secs,
        .num_turns = acc.num_turns,
        .is_error = acc.is_error or exit_code != 0,
        .exit_code = exit_code,
        .result_text = acc.result_text,
        .claude_session_id = acc.session_id,
        .cost_microdollars = acc.cost_microdollars,
        .cost_known = acc.saw_result,
        .input_tokens = acc.input_tokens,
        .output_tokens = acc.output_tokens,
        .cache_creation_tokens = acc.cache_creation_tokens,
        .cache_read_tokens = acc.cache_read_tokens,
        .tool_errors = acc.tool_errors,
        .result_subtype = acc.result_subtype,
        .stop_reason = acc.stop_reason,
        .duration_api_ms = acc.duration_api_ms,
    };
}

// ── Chrome lifecycle ────────────────────────────────────────────────────
// The daemon owns a single headless Chrome instance shared by all roles.
// Roles create/close their own tabs via MCP; the daemon manages the process.

const CHROME_PORT: u16 = 9222;
/// Unique user-data-dir basename identifying bees' single shared Chrome. Used to
/// launch, detect, and reap the whole process tree by marker.
const CHROME_DATA_MARKER = "chrome-headless-bees";
/// Hard ceiling on open tabs in the shared Chrome. Roles reuse the one instance
/// and its tabs; the between-cycle cleanup closes work tabs and enforces this cap.
pub const MAX_CHROME_TABS: u32 = 20;
var chrome_data_dir_buf: [256]u8 = undefined;

fn chromeDataDir() []const u8 {
    const home = std.c.getenv("HOME") orelse "/tmp";
    const written = std.fmt.bufPrint(&chrome_data_dir_buf, "{s}/.cache/{s}", .{ home, CHROME_DATA_MARKER }) catch
        return "/tmp/.cache/" ++ CHROME_DATA_MARKER;
    return written;
}

/// Find a Chrome/Chromium binary. Checks common paths in priority order.
/// Public so the health check (`bees doctor`) can verify browser availability
/// for browser-dependent roles using the same detection the daemon relies on.
pub fn findChromeBinary() ?[]const u8 {
    const candidates = [_][*:0]const u8{
        "/opt/google/chrome/chrome",
        "/usr/bin/google-chrome-stable",
        "/usr/bin/google-chrome",
        "/usr/bin/chromium-browser",
        "/usr/bin/chromium",
        "/snap/bin/chromium",
    };
    for (candidates) |path| {
        if (std.c.access(path, std.c.F_OK) == 0) return std.mem.sliceTo(path, 0);
    }
    return null;
}

/// True if something is listening on the Chrome debug port. Chrome opens it only
/// once its DevTools server is ready, so this doubles as a readiness check.
fn chromePortOpen(io: Io) bool {
    const addr = Io.net.IpAddress.parse("127.0.0.1", CHROME_PORT) catch return false;
    var stream = Io.net.IpAddress.connect(addr, io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

/// Spawn a headless Chrome/Chromium instance for MCP-enabled roles, enforcing a
/// single shared instance box-wide. Returns:
///   - a real pid if we launched it (caller owns it and should killChrome on stop),
///   - 0 if an instance is already running and we reused it (NOT owned — the
///     orchestrator's `chrome_pid != 0` guard leaves it alone on shutdown),
///   - null if no browser was found or launch failed.
/// Roles share the one instance via tabs (the chrome-devtools MCP connects with
/// --browserUrl); we never run more than one Chrome at a time.
pub fn spawnChrome(io: Io) ?std.posix.pid_t {
    // Already running? Reuse it rather than launching a second instance.
    if (chromePortOpen(io)) return 0;

    // Kill any orphaned Chrome from a previous daemon run
    killOrphanedChrome(io);

    const chrome_bin = findChromeBinary() orelse return null;

    var data_dir_arg_buf: [300]u8 = undefined;
    const data_dir_arg = std.fmt.bufPrint(&data_dir_arg_buf, "--user-data-dir={s}", .{chromeDataDir()}) catch return null;

    const argv = [_][]const u8{
        chrome_bin,
        "--headless=new",
        "--no-first-run",
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--disable-extensions",
        "--disable-background-networking",
        "--disable-background-timer-throttling",
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding",
        "--renderer-process-limit=4",
        "--remote-debugging-port=9222",
        data_dir_arg,
        "--noerrdialogs",
        "--ozone-platform=headless",
        "--ozone-override-screen-size=800,600",
        "--use-angle=swiftshader-webgl",
        "about:blank",
    };

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return null;

    // Give Chrome time to bind the debug port
    io.sleep(Io.Duration.fromSeconds(2), .awake) catch {};

    return child.id;
}

pub const ChromeProbe = enum { ok, no_binary, launch_failed, no_devtools };

/// Verify Chrome actually works for browser roles, honoring the single-instance
/// rule: if a Chrome is already serving on :9222 (the daemon's shared browser),
/// REUSE it — never launch a second. Only when none is running do we launch the
/// one shared instance, confirm its DevTools port comes up, then reap it. A TCP
/// connect is a reliable "it works" signal (the debug port opens only once the
/// DevTools server is ready). Used by `bees doctor --probe`.
pub fn probeChrome(io: Io) ChromeProbe {
    if (findChromeBinary() == null) return .no_binary;

    // Already running? Reuse it — at most one Chrome instance at a time.
    if (chromePortOpen(io)) return .ok;

    // None running — launch the single shared instance, verify, then reap it.
    const pid = spawnChrome(io) orelse return .launch_failed;
    defer killChrome(pid, io);
    var attempt: u32 = 0;
    while (attempt < 15) : (attempt += 1) {
        io.sleep(Io.Duration.fromSeconds(1), .awake) catch {};
        if (chromePortOpen(io)) return .ok;
    }
    return .no_devtools;
}

/// Kill an entire Chrome process tree by matching its unique user-data-dir
/// marker — reliable where killing a single pid leaves orphaned children.
fn killChromeByMarker(io: Io, marker: []const u8) void {
    const argv = [_][]const u8{ "pkill", "-9", "-f", marker };
    var child = std.process.spawn(io, .{ .argv = &argv, .stdout = .ignore, .stderr = .ignore }) catch return;
    _ = child.wait(io) catch {};
}

/// Last-one-out cleanup for the shared Chrome. The single-instance rule means a
/// daemon that REUSED a running Chrome (pid 0, "not owned") must not kill it on
/// shutdown — so without this, the last bees daemon to stop left Chrome (and its
/// zygote/gpu/renderer tree) running forever. Called from `bees stop` and the
/// daemon's reused-Chrome shutdown path: if no other bees daemon is running,
/// sweep the shared instance (graceful TERM, then KILL stragglers).
/// Returns true if a sweep was performed.
pub fn stopSharedChromeIfOrphaned(allocator: std.mem.Allocator, io: Io) bool {
    if (!chromePortOpen(io)) return false;

    // Another project's daemon may still be using the shared instance. Exclude
    // our own pid — when called from a daemon's shutdown path, the shutting-down
    // daemon itself matches the pattern.
    if (otherBeesDaemonRunning(allocator, io)) return false;

    const term_argv = [_][]const u8{ "pkill", "-TERM", "-f", CHROME_DATA_MARKER };
    var term_child = std.process.spawn(io, .{ .argv = &term_argv, .stdout = .ignore, .stderr = .ignore }) catch return false;
    _ = term_child.wait(io) catch {};
    io.sleep(Io.Duration.fromSeconds(2), .awake) catch {};
    killChromeByMarker(io, CHROME_DATA_MARKER);
    return true;
}

/// True if a `bees daemon` process other than the calling process is running.
fn otherBeesDaemonRunning(allocator: std.mem.Allocator, io: Io) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "pgrep", "-f", "bees daemon" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const own_pid = std.c.getpid();
    var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (it.next()) |line| {
        const pid = std.fmt.parseInt(i32, std.mem.trim(u8, line, &std.ascii.whitespace), 10) catch continue;
        if (pid != own_pid) return true;
    }
    return false;
}

/// Stop the shared Chrome we launched: graceful SIGTERM → 5s → SIGKILL on the
/// browser process, then a marker sweep to reap any orphaned children (killing a
/// single pid leaves Chrome's zygote/gpu/renderer processes behind).
/// A pid of 0 (or negative) means "reused, not owned by us" — do nothing, so we
/// never kill a shared instance another daemon owns.
pub fn killChrome(pid: std.posix.pid_t, io: Io) void {
    if (pid <= 0) return;

    std.posix.kill(pid, std.c.SIG.TERM) catch {};

    var waited: u32 = 0;
    var alive = true;
    while (waited < 5) : (waited += 1) {
        io.sleep(Io.Duration.fromSeconds(1), .awake) catch {};
        std.posix.kill(pid, @enumFromInt(0)) catch {
            alive = false;
            break;
        };
    }
    if (alive) std.posix.kill(pid, std.c.SIG.KILL) catch {};

    // Reap any children the browser process left behind.
    killChromeByMarker(io, CHROME_DATA_MARKER);
}

/// Kill any Chrome processes listening on the debug port.
/// Called on startup to clean up orphans from a previous crashed daemon.
fn killOrphanedChrome(io: Io) void {
    // Check if anything is listening on the debug port
    const addr = Io.net.IpAddress.parse("127.0.0.1", CHROME_PORT) catch return;
    var stream = Io.net.IpAddress.connect(addr, io, .{ .mode = .stream }) catch return;
    stream.close(io);

    // Something is listening — find and kill Chrome processes with our data dir.
    // Use pkill matching the user-data-dir to avoid killing unrelated Chrome.
    const kill_argv = [_][]const u8{ "pkill", "-f", CHROME_DATA_MARKER };
    var child = std.process.spawn(io, .{
        .argv = &kill_argv,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};

    // Wait for processes to die
    io.sleep(Io.Duration.fromSeconds(2), .awake) catch {};
}

/// Close all Chrome DevTools tabs except about:blank and force GC on renderers.
/// Public so the orchestrator can call it between cycles for periodic cleanup.
/// Each role creates its own tabs; this closes any that leaked.
/// Entirely non-fatal — if Chrome isn't running or anything fails, silently returns.
pub fn cleanupChrome(io: Io) void {
    cleanupChromeTabs(io);
}

fn cleanupChromeTabs(io: Io) void {
    const addr = Io.net.IpAddress.parse("127.0.0.1", 9222) catch return;

    // GET /json — list all open tabs
    var tab_buf: [65536]u8 = undefined;
    const tab_json = cdpGet(io, addr, "/json", &tab_buf) orelse return;

    // Scan for tab objects: extract "id" and "url" pairs, close non-blank tabs
    // and enforce the tab ceiling — keep at most MAX_CHROME_TABS (blank) tabs.
    var pos: usize = 0;
    var closed: u32 = 0;
    var kept: u32 = 0;
    while (pos < tab_json.len) {
        const id_key = std.mem.indexOf(u8, tab_json[pos..], "\"id\":\"") orelse break;
        const id_start = pos + id_key + 6;
        const id_end_rel = std.mem.indexOfScalar(u8, tab_json[id_start..], '"') orelse break;
        const id = tab_json[id_start..][0..id_end_rel];

        const search_end = @min(id_start + 500, tab_json.len);
        const url_region = tab_json[id_start..search_end];

        var is_blank = false;
        if (std.mem.indexOf(u8, url_region, "\"url\":\"")) |url_key| {
            const url_start = url_key + 7;
            const url_end_rel = std.mem.indexOfScalar(u8, url_region[url_start..], '"') orelse 0;
            const url = url_region[url_start..][0..url_end_rel];
            is_blank = std.mem.eql(u8, url, "about:blank");
        }

        // Close non-blank (work) tabs, and any blank tab beyond the cap.
        if (!is_blank or kept >= MAX_CHROME_TABS) {
            var path_buf: [128]u8 = undefined;
            const close_path = std.fmt.bufPrint(&path_buf, "/json/close/{s}", .{id}) catch {
                pos = id_start + id_end_rel;
                continue;
            };
            var discard_buf: [1024]u8 = undefined;
            _ = cdpGet(io, addr, close_path, &discard_buf);
            closed += 1;
        } else {
            kept += 1;
        }

        pos = id_start + id_end_rel;
    }

    // Force Chrome to GC stale renderers by creating+closing a temp tab.
    // This triggers Chrome's internal cleanup of orphaned renderer processes.
    if (closed > 0) {
        var new_buf: [4096]u8 = undefined;
        if (cdpGet(io, addr, "/json/new?about:blank", &new_buf)) |new_json| {
            // Extract the new tab's id and close it immediately
            if (std.mem.indexOf(u8, new_json, "\"id\":\"")) |new_id_key| {
                const new_id_start = new_id_key + 6;
                if (std.mem.indexOfScalar(u8, new_json[new_id_start..], '"')) |new_id_end| {
                    const new_id = new_json[new_id_start..][0..new_id_end];
                    var close_buf: [128]u8 = undefined;
                    if (std.fmt.bufPrint(&close_buf, "/json/close/{s}", .{new_id})) |cp| {
                        var discard: [1024]u8 = undefined;
                        _ = cdpGet(io, addr, cp, &discard);
                    } else |_| {}
                }
            }
        }
        std.debug.print("[chrome] cleaned up {d} tab(s)\n", .{closed});
    }
}

/// Send a GET request to the Chrome DevTools Protocol HTTP endpoint.
/// Returns the response body (slice into `buf`), or null on any failure.
fn cdpGet(io: Io, addr: Io.net.IpAddress, path: []const u8, buf: []u8) ?[]const u8 {
    var stream = Io.net.IpAddress.connect(addr, io, .{ .mode = .stream }) catch return null;
    defer stream.close(io);

    // Send request
    var write_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;
    w.writeAll("GET ") catch return null;
    w.writeAll(path) catch return null;
    w.writeAll(" HTTP/1.0\r\nHost: 127.0.0.1:9222\r\nConnection: close\r\n\r\n") catch return null;
    w.flush() catch return null;

    // Read response
    var total: usize = 0;
    while (total < buf.len) {
        var iov = [1][]u8{buf[total..]};
        const n = io.vtable.netRead(io.userdata, stream.socket.handle, &iov) catch break;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) return null;

    // Skip HTTP headers — find \r\n\r\n
    const body_start = (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") orelse return null) + 4;
    if (body_start >= total) return null;
    return buf[body_start..total];
}

test "f64ToU64Sat saturates instead of illegal cast" {
    try std.testing.expectEqual(@as(u64, 0), f64ToU64Sat(-1.0));
    try std.testing.expectEqual(@as(u64, 0), f64ToU64Sat(std.math.nan(f64)));
    try std.testing.expectEqual(@as(u64, 42), f64ToU64Sat(42.9));
    try std.testing.expectEqual(std.math.maxInt(u64), f64ToU64Sat(1e30));
    try std.testing.expectEqual(std.math.maxInt(u64), f64ToU64Sat(std.math.inf(f64)));
}

test "stall watchdog: heartbeat-only session is TERMed once, then KILLed after the grace" {
    // Replays the 2026-08-09 incident: 8h13m of heartbeats, zero progress.
    var slot = ChildSlot{ .pid = 424242, .session_id = 95 };
    const t0: u64 = 1_000_000;
    var idle: u64 = 0;

    // Claimed but not yet stamped — never acted on.
    try std.testing.expectEqual(StallAction.none, classifyStall(&slot, t0, 1800, &idle));

    @atomicStore(u64, &slot.last_progress_s, t0, .release);
    // Inside the budget: a slow turn is not a stall.
    try std.testing.expectEqual(StallAction.none, classifyStall(&slot, t0 + 1799, 1800, &idle));

    // The real hang: 29581s idle → one TERM.
    try std.testing.expectEqual(StallAction.term, classifyStall(&slot, t0 + 29_581, 1800, &idle));
    try std.testing.expectEqual(@as(u64, 29_581), idle);

    // Next tick, still within the grace → no repeat signal.
    try std.testing.expectEqual(StallAction.none, classifyStall(&slot, t0 + 29_596, 1800, &idle));

    // Ignored the TERM → escalate exactly once per grace window.
    try std.testing.expectEqual(
        StallAction.kill,
        classifyStall(&slot, t0 + 29_581 + stall_kill_grace_secs, 1800, &idle),
    );
}

test "a recycled slot cannot be killed on its predecessor's timestamp" {
    // Slot reuse must not inherit a stale progress stamp, or the next session
    // to land in that slot is signaled the moment the watchdog ticks.
    const idx = registerChild(999_001, 1) orelse return error.SkipZigTest;
    @atomicStore(u64, &active_children[idx].last_progress_s, fs.timestamp() -| 7200, .release);
    unregisterChild(999_001);
    try std.testing.expectEqual(@as(u64, 0), @atomicLoad(u64, &active_children[idx].last_progress_s, .acquire));

    var idle: u64 = 0;
    try std.testing.expectEqual(StallAction.none, classifyStall(&active_children[idx], fs.timestamp(), 1800, &idle));

    // A disabled watchdog never signals, whatever the registry holds.
    var hits: [2]StalledChild = undefined;
    try std.testing.expectEqual(@as(usize, 0), reapStalledChildren(0, &hits));
}

test "configureToolTimeouts injects per-call Bash ceilings" {
    configureToolTimeouts(.{});
    var env_map = buildFilteredEnvMap(std.testing.allocator);
    defer env_map.deinit();
    try std.testing.expectEqualStrings("300000", env_map.get("BASH_DEFAULT_TIMEOUT_MS").?);
    try std.testing.expectEqualStrings("900000", env_map.get("BASH_MAX_TIMEOUT_MS").?);

    // 0 means "don't set it" — leave the CLI's own default in place.
    configureToolTimeouts(.{ .bash_default_ms = 0, .bash_max_ms = 0 });
    var bare = buildFilteredEnvMap(std.testing.allocator);
    defer bare.deinit();
    try std.testing.expect(bare.get("BASH_DEFAULT_TIMEOUT_MS") == null);
}

test "resolveBackend defaults to claude" {
    try std.testing.expectEqual(types.BackendType.claude, resolveBackend("claude", ""));
    try std.testing.expectEqual(types.BackendType.claude, resolveBackend("", ""));
}

test "resolveBackend role override" {
    try std.testing.expectEqual(types.BackendType.codex, resolveBackend("claude", "codex"));
    try std.testing.expectEqual(types.BackendType.opencode, resolveBackend("claude", "opencode"));
    try std.testing.expectEqual(types.BackendType.pi, resolveBackend("pi", ""));
}

test "gateway mode forces claude backend and injects endpoint env" {
    configureGatewayWithKey(.{
        .enabled = true,
        .base_url = "https://ai.starflinger.eu",
        .model = "starflinger-anthropic",
    }, "sk-test");
    defer gateway = .{}; // reset module state for other tests

    try std.testing.expect(gatewayActive());
    try std.testing.expect(gatewayTextOnly()); // text_only defaults on

    // Every backend choice collapses to claude — codex routing included.
    try std.testing.expectEqual(types.BackendType.claude, resolveBackend("claude", "codex"));
    try std.testing.expectEqual(types.BackendType.claude, resolveBackend("pi", ""));

    // Claude alias models default to the gateway model; explicit per-role
    // model ids (e.g. an openrouter model served by the gateway) pass through.
    try std.testing.expectEqualStrings("starflinger-anthropic", gatewayEffectiveModel("opus"));
    try std.testing.expectEqualStrings("starflinger-anthropic", gatewayEffectiveModel("fable"));
    try std.testing.expectEqualStrings("openrouter/deepseek/deepseek-chat", gatewayEffectiveModel("openrouter/deepseek/deepseek-chat"));

    // Child env carries the gateway endpoint, key, and model alias remaps.
    var env_map = buildFilteredEnvMap(std.testing.allocator);
    defer env_map.deinit();
    try std.testing.expectEqualStrings("https://ai.starflinger.eu", env_map.get("ANTHROPIC_BASE_URL").?);
    try std.testing.expectEqualStrings("sk-test", env_map.get("ANTHROPIC_API_KEY").?);
    try std.testing.expectEqualStrings("starflinger-anthropic", env_map.get("ANTHROPIC_DEFAULT_OPUS_MODEL").?);
    try std.testing.expectEqualStrings("starflinger-anthropic", env_map.get("ANTHROPIC_SMALL_FAST_MODEL").?);

    // Bearer endpoints (vLLM /v1/messages) get ANTHROPIC_AUTH_TOKEN instead.
    configureGatewayWithKey(.{
        .enabled = true,
        .base_url = "http://10.20.212.92:8002",
        .model = "starflinger",
        .bearer = true,
    }, "tok");
    var bearer_env = buildFilteredEnvMap(std.testing.allocator);
    defer bearer_env.deinit();
    try std.testing.expectEqualStrings("tok", bearer_env.get("ANTHROPIC_AUTH_TOKEN").?);
}

test "configureGateway is a no-op when disabled and fails fast on missing key" {
    try configureGateway(.{ .enabled = false });
    try std.testing.expect(!gatewayActive());
    // Gateway off: model resolution is the identity.
    try std.testing.expectEqualStrings("opus", gatewayEffectiveModel("opus"));

    try std.testing.expectError(error.GatewayKeyMissing, configureGateway(.{
        .enabled = true,
        .base_url = "https://ai.starflinger.eu",
        .model = "starflinger-anthropic",
        .api_key_env = "BEES_TEST_NONEXISTENT_KEY_ENV",
    }));
    try std.testing.expect(!gatewayActive());
}

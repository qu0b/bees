const std = @import("std");
const assert = std.debug.assert;
const fs = @import("fs.zig");

pub const Config = struct {
    project: Project,
    claude_binary: []const u8 = "claude",
    pi_binary: []const u8 = "pi",
    default_backend: []const u8 = "claude",
    /// Codex model + reasoning effort for thinking/knowledge roles (strategist,
    /// researcher). `sol` is the stronger reasoner; runs at the highest (xhigh)
    /// reasoning effort — higher than the execution workers.
    codex_thinking: CodexRole = .{ .model = "gpt-5.6-sol", .effort = "xhigh" },
    /// Codex model + reasoning effort for clearly-defined execution roles
    /// (workers). `terra` runs at high reasoning (the floor; the thinker runs
    /// a tier above).
    codex_execution: CodexRole = .{ .model = "gpt-5.6-terra", .effort = "high" },
    workers: Workers = .{},
    merger: Merger = .{},
    sre: Sre = .{},
    strategist: Strategist = .{},
    qa: Qa = .{},
    user: User = .{},
    api: Api = .{},
    daemon: Daemon = .{},
    git: Git = .{},
    build: Build = .{},
    serve: Serve = .{},
    smoke_test: SmokeTest = .{},
    timeouts: Timeouts = .{},
    cache: Cache = .{},
    funding: Funding = .{},
    gateway: Gateway = .{},

    pub const Project = struct {
        name: []const u8,
        base_branch: []const u8 = "main",
    };

    pub const Workers = struct {
        count: u32 = 5,
        model: []const u8 = "opus",
        effort: []const u8 = "high",
        max_budget_usd: f64 = 30.0,
        fallback_model: ?[]const u8 = null,
        schedule: []const u8 = "0 * * * *",
        backend: []const u8 = "",
        /// Fraction of workers (0.0-1.0) routed to the Codex backend instead of
        /// the Claude default. 0.5 = half. Codex workers use `codex_execution`.
        codex_fraction: f64 = 0.5,
    };

    pub const Merger = struct {
        model: []const u8 = "opus",
        effort: []const u8 = "high",
        max_budget_usd: f64 = 30.0,
        fallback_model: ?[]const u8 = null,
        schedule: []const u8 = "45 * * * *",
        max_conflict_files: u32 = 5,
        merge_threshold: u32 = 3,
        backend: []const u8 = "",
    };

    pub const Sre = struct {
        model: []const u8 = "opus",
        effort: []const u8 = "high",
        max_budget_usd: f64 = 30.0,
        fallback_model: ?[]const u8 = null,
        cooldown_minutes: u32 = 60,
        max_turns: u32 = 10,
        tool_error_threshold: u32 = 3,
        backend: []const u8 = "",
    };

    pub const Strategist = struct {
        // Deep-reasoning role — defaults to Fable.
        model: []const u8 = "fable",
        effort: []const u8 = "high",
        max_budget_usd: f64 = 30.0,
        fallback_model: ?[]const u8 = "opus",
        cycle_interval: u32 = 3,
        mcp_config: ?[]const u8 = null,
        backend: []const u8 = "",
        /// Fraction of strategist runs (0.0-1.0) routed to the Codex backend
        /// instead of Claude. 0.25 = a quarter. Codex runs use `codex_thinking`.
        codex_fraction: f64 = 0.25,
    };

    pub const Qa = struct {
        model: []const u8 = "opus",
        effort: []const u8 = "medium",
        max_budget_usd: f64 = 30.0,
        fallback_model: ?[]const u8 = "sonnet",
        mcp_config: ?[]const u8 = null,
        backend: []const u8 = "",
    };

    pub const User = struct {
        model: []const u8 = "opus",
        effort: []const u8 = "high",
        max_budget_usd: f64 = 30.0,
        fallback_model: ?[]const u8 = null,
        mcp_config: ?[]const u8 = null,
        backend: []const u8 = "",
    };

    pub const Api = struct {
        port: u16 = 3002,
        enabled: bool = true,
        bind_address: []const u8 = "127.0.0.1",
    };

    pub const Daemon = struct {
        cooldown_secs: u32 = 300,
        // External `timeout` wrapper breaks Claude in io_uring async context.
        // Set to 0 (disabled) by default until a Zig-native timeout is implemented.
        worker_timeout_minutes: u32 = 0,
        restart_timeout_minutes: u32 = 20,
        max_restarts: u32 = 2,
        /// UTC hour (0-23) when quiet period starts. Null = disabled.
        quiet_start_utc: ?u8 = null,
        /// UTC hour (0-23) when quiet period ends. Null = disabled.
        quiet_end_utc: ?u8 = null,
        /// If true (default), quiet hours only apply Mon-Fri.
        quiet_weekdays_only: bool = true,
        /// When true, daemon re-execs itself after merging source code changes.
        /// Only useful when bees is building itself.
        self_hosted: bool = false,
        /// Circuit breaker: halt the daemon after this many consecutive merge
        /// cycles with zero accepted merges (systemic failure — burning money on
        /// work that never lands). The unit stays stopped for operator attention
        /// (exit code 64, not restarted by systemd). 0 disables the halt.
        max_sterile_cycles: u32 = 12,
    };

    pub const Git = struct {
        shallow_worktrees: bool = true,
    };

    pub const Build = struct {
        command: ?[]const u8 = null,
        test_command: ?[]const u8 = null,
        deploy_command: ?[]const u8 = null,
        setup_command: ?[]const u8 = null,
    };

    pub const Serve = struct {
        systemd_unit: ?[]const u8 = null,
        health_url: ?[]const u8 = null,
        health_timeout_secs: u32 = 30,
    };

    pub const SmokeTest = struct {
        enabled: bool = false,
        urls: []const []const u8 = &.{},
        port: u16 = 8080,
        startup_wait_secs: u32 = 10,
    };

    pub const Timeouts = struct {
        /// Stall watchdog: SIGTERM (then SIGKILL) an agent process that has
        /// produced no PROGRESS event for this long. Heartbeats don't count —
        /// this measures advancement, not liveness. Generous on purpose: a
        /// single reasoning turn can legitimately run for minutes; what this
        /// catches is the wedged-tool hang that stalls the whole daemon.
        /// 0 disables the watchdog.
        max_idle_secs: u32 = 1800,
        /// Per-Bash-call ceilings handed to the agent CLI. Sized against real
        /// build times here (a cold `cargo build`/`zig build` runs minutes);
        /// too low kills legitimate work.
        bash_default_ms: u32 = 300_000,
        bash_max_ms: u32 = 900_000,
        stale_hours: u32 = 24,
        cleanup_hours: u32 = 72,
    };

    pub const Cache = struct {
        /// Enable shared context seed sessions for cross-role prompt caching.
        shared_context: bool = true,
        /// Maximum bytes of source files to include in the seed (default ~200k tokens).
        max_bytes: u32 = 800_000,
        /// Files always included in the seed regardless of haiku selection.
        always_include: []const []const u8 = &.{},
        /// Directory prefixes excluded from file selection (e.g., "vendor/", "node_modules/").
        always_exclude: []const []const u8 = &.{},
    };

    /// A Codex model paired with its reasoning effort, assigned by task type.
    pub const CodexRole = struct {
        /// OpenAI model passed to `codex exec -m`.
        model: []const u8,
        /// Reasoning effort passed to codex as `model_reasoning_effort`.
        effort: []const u8 = "high",
    };

    /// Anthropic-compatible gateway mode: run EVERY agent through one endpoint
    /// (e.g. LiteLLM at https://ai.starflinger.eu). When enabled, all roles are
    /// forced onto the Claude backend (codex_fraction routing is disabled).
    /// Per-role models still apply: a Claude alias (opus/sonnet/haiku/fable)
    /// defaults to `model` below, while an explicit id in a role's config.json
    /// (e.g. "openrouter/deepseek/deepseek-chat") passes through, letting each
    /// role pick any model the gateway serves.
    pub const Gateway = struct {
        enabled: bool = false,
        /// Endpoint injected as ANTHROPIC_BASE_URL into every agent session.
        base_url: []const u8 = "",
        /// Default model for roles whose model is a Claude alias name.
        model: []const u8 = "",
        /// Env var holding the gateway API key. The key itself never lives in
        /// config.json — it is read from the daemon's environment at startup.
        api_key_env: []const u8 = "LITELLM_API_KEY",
        /// Send the key as `Authorization: Bearer` (ANTHROPIC_AUTH_TOKEN)
        /// instead of `x-api-key` (ANTHROPIC_API_KEY). Needed for endpoints
        /// like vLLM's native /v1/messages that only accept Bearer auth.
        bearer: bool = false,
        /// The model's real context window in tokens. The agent CLI does not
        /// recognize gateway model names, so it assumes 200k and rejects a
        /// larger prompt with "Prompt is too long" before the request is even
        /// sent — even when the server advertises far more (vLLM
        /// max_model_len). 0 = leave the CLI's assumption alone.
        context_tokens: u32 = 0,
        /// The gateway model is text-only (no vision). Browser tooling stays
        /// available — DOM/a11y snapshots, console, network, evaluate_script
        /// are textual — but image-producing tools (chrome-devtools
        /// take_screenshot) are disallowed at spawn.
        text_only: bool = true,
    };

    pub const Funding = struct {
        /// Hard ceiling on a single funding request, in whole USDC. Requests above
        /// this are refused. 0 disables all on-chain transfers.
        max_per_request_usdc: u32 = 100,
        /// Hard ceiling on cumulative USDC transferred across the project lifetime
        /// (tracked in a ledger under the funding dir). 0 disables all transfers.
        max_cumulative_usdc: u32 = 1000,
    };

    /// Validate a loaded config. Fails fast on values that would corrupt paths,
    /// spin the daemon, or move the base branch unexpectedly.
    pub fn validate(self: Config) !void {
        // project.name flows unescaped into /tmp/bees-{name} worktree/lock paths
        // and the systemd unit name bees-{name}.service — must be a safe segment.
        const name = self.project.name;
        if (name.len == 0 or name.len > 64) return error.InvalidProjectName;
        if (std.mem.indexOfAny(u8, name, "/\\\x00") != null) return error.InvalidProjectName;
        if (std.mem.indexOf(u8, name, "..") != null) return error.InvalidProjectName;
        for (name) |ch| {
            if (ch < 0x20) return error.InvalidProjectName; // no control chars
        }
        if (self.project.base_branch.len == 0) return error.InvalidBaseBranch;
        if (self.project.base_branch[0] == '-') return error.InvalidBaseBranch; // git option-like

        // Zero workers idles the daemon forever; merge_threshold 0 spins the merger.
        if (self.workers.count == 0 or self.workers.count > 64) return error.InvalidWorkerCount;
        if (self.merger.merge_threshold == 0) return error.InvalidMergeThreshold;

        // Budgets must be finite and positive, else the cost cap is meaningless.
        if (!(self.workers.max_budget_usd > 0) or !std.math.isFinite(self.workers.max_budget_usd)) {
            return error.InvalidBudget;
        }

        // Gateway mode routes every session to one endpoint/model — a missing
        // URL or model would silently fall back to nothing usable.
        if (self.gateway.enabled) {
            if (!std.mem.startsWith(u8, self.gateway.base_url, "http")) return error.InvalidGatewayUrl;
            if (self.gateway.model.len == 0) return error.InvalidGatewayModel;
            if (self.gateway.api_key_env.len == 0) return error.InvalidGatewayKeyEnv;
        }
    }
};

pub const ProjectPaths = struct {
    root: []const u8,
    bees_dir: []const u8,
    config_file: []const u8,
    tasks_file: []const u8,
    db_dir: []const u8,
    logs_dir: []const u8,
    prompts_dir: []const u8,
    knowledge_dir: []const u8,
    funding_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, project_root: []const u8) !ProjectPaths {
        const bees_dir = try std.fs.path.join(allocator, &.{ project_root, ".bees" });
        return .{
            .root = project_root,
            .bees_dir = bees_dir,
            .config_file = try std.fs.path.join(allocator, &.{ bees_dir, "config.json" }),
            .tasks_file = try std.fs.path.join(allocator, &.{ bees_dir, "tasks.json" }),
            .db_dir = try std.fs.path.join(allocator, &.{ bees_dir, "db" }),
            .logs_dir = try std.fs.path.join(allocator, &.{ bees_dir, "logs" }),
            .prompts_dir = try std.fs.path.join(allocator, &.{ bees_dir, "prompts" }),
            .knowledge_dir = try std.fs.path.join(allocator, &.{ bees_dir, "knowledge" }),
            .funding_dir = try std.fs.path.join(allocator, &.{ bees_dir, "funding" }),
        };
    }
};

/// Walk up from start_dir looking for .bees/config.json
pub fn findProjectRoot(allocator: std.mem.Allocator, start_dir: []const u8) !?[]const u8 {
    var current = try allocator.dupe(u8, start_dir);
    while (true) {
        const config_path = try std.fs.path.join(allocator, &.{ current, ".bees", "config.json" });
        defer allocator.free(config_path);
        if (fs.access(config_path)) {
            return current;
        }

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        const new = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = new;
    }
}

/// Load and parse config.json, then validate it.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const data = try fs.readFileAlloc(allocator, path, 1024 * 1024);
    const parsed = try std.json.parseFromSlice(Config, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    try parsed.value.validate();
    return parsed.value;
}

test "default config values" {
    const cfg = Config{
        .project = .{ .name = "test" },
    };
    try std.testing.expectEqual(@as(u32, 5), cfg.workers.count);
    try std.testing.expectEqualStrings("main", cfg.project.base_branch);
    try std.testing.expectEqualStrings("opus", cfg.workers.model);
    try std.testing.expectEqualStrings("fable", cfg.strategist.model);
    try std.testing.expectEqual(@as(f64, 0.5), cfg.workers.codex_fraction);
    try std.testing.expectEqual(@as(f64, 0.25), cfg.strategist.codex_fraction);
    try std.testing.expectEqualStrings("gpt-5.6-sol", cfg.codex_thinking.model);
    try std.testing.expectEqualStrings("xhigh", cfg.codex_thinking.effort);
    try std.testing.expectEqualStrings("gpt-5.6-terra", cfg.codex_execution.model);
    try std.testing.expectEqualStrings("high", cfg.codex_execution.effort);
    try std.testing.expectEqual(@as(f64, 30.0), cfg.workers.max_budget_usd);
    try std.testing.expectEqual(false, cfg.smoke_test.enabled);
}

test "validate accepts a sane config and rejects dangerous ones" {
    try (Config{ .project = .{ .name = "my-project" } }).validate();

    try std.testing.expectError(error.InvalidProjectName, (Config{ .project = .{ .name = "" } }).validate());
    try std.testing.expectError(error.InvalidProjectName, (Config{ .project = .{ .name = "../etc" } }).validate());
    try std.testing.expectError(error.InvalidProjectName, (Config{ .project = .{ .name = "a/b" } }).validate());
    try std.testing.expectError(error.InvalidWorkerCount, (Config{ .project = .{ .name = "ok" }, .workers = .{ .count = 0 } }).validate());
    try std.testing.expectError(error.InvalidMergeThreshold, (Config{ .project = .{ .name = "ok" }, .merger = .{ .merge_threshold = 0 } }).validate());
    try std.testing.expectError(error.InvalidBaseBranch, (Config{ .project = .{ .name = "ok", .base_branch = "-x" } }).validate());
}

test "gateway config defaults off and validates when enabled" {
    const off = Config{ .project = .{ .name = "ok" } };
    try std.testing.expect(!off.gateway.enabled);
    try off.validate();

    // Enabled with a full endpoint/model passes.
    try (Config{ .project = .{ .name = "ok" }, .gateway = .{
        .enabled = true,
        .base_url = "https://ai.starflinger.eu",
        .model = "starflinger-anthropic",
    } }).validate();

    // Enabled but missing pieces fails fast.
    try std.testing.expectError(error.InvalidGatewayUrl, (Config{ .project = .{ .name = "ok" }, .gateway = .{
        .enabled = true,
        .model = "starflinger-anthropic",
    } }).validate());
    try std.testing.expectError(error.InvalidGatewayModel, (Config{ .project = .{ .name = "ok" }, .gateway = .{
        .enabled = true,
        .base_url = "https://ai.starflinger.eu",
    } }).validate());
}

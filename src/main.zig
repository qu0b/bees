const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const store_mod = @import("store.zig");
const types = @import("types.zig");
const worker = @import("worker.zig");
const merger = @import("merger.zig");
const claude = @import("claude.zig");
const backend = @import("backend.zig");
const orchestrator = @import("orchestrator.zig");
const sre_mod = @import("sre.zig");
const strategist_mod = @import("strategist.zig");
const qa_mod = @import("qa.zig");
const user_mod = @import("user.zig");
const git = @import("git.zig");
const scheduler = @import("scheduler.zig");
const tasks_mod = @import("tasks.zig");
const log_mod = @import("log.zig");
const fs = @import("fs.zig");
const ctx_mod = @import("context.zig");

pub const version = "0.1.0";

const default_strategist_prompt =
    \\You are the Strategist for this project. Your job: decide what the AI worker swarm
    \\should build next. You make this decision based on concrete context, not abstract vision.
    \\
    \\## Your Context
    \\
    \\The daemon injects the following at the end of this prompt (if available):
    \\- **Target User Profiles** — who uses this project, what they need, what success looks like
    \\- **Operator Feedback** — direct input from the human operator, highest priority
    \\- **Latest QA Report** — user-experience evaluation from the QA agent
    \\- **Task Performance Trends** — what tasks are succeeding/failing, accept rates
    \\
    \\The user profiles are your north star. Every task you write should close the gap
    \\between what those users need and what the project currently delivers.
    \\
    \\## Your Process
    \\
    \\### 1. UNDERSTAND THE USERS
    \\   Read the target user profiles injected below. For each user:
    \\   - What are their goals?
    \\   - What would make them successful?
    \\   - What frustrates them today?
    \\
    \\### 2. READ OPERATOR FEEDBACK
    \\   The human operator's direct input — highest priority signal. If there are
    \\   open feedback items, address them in your task decisions. Feedback marked
    \\   "addressed" can be deprioritized.
    \\
    \\### 3. READ THE QA REPORT
    \\   The QA agent evaluates the project as those users. Their report tells you:
    \\   - What's working well (protect it)
    \\   - Where the experience breaks down (fix it or build something better)
    \\   - What's missing that users need
    \\
    \\### 4. CHECK TASK TRENDS
    \\   - Tasks with high accept rates are working — keep or evolve them
    \\   - Tasks with many runs but 0 accepted are broken — replace or fundamentally rethink
    \\   - Look for patterns: are certain types of tasks consistently failing?
    \\
    \\### 5. ORIENT
    \\   - `git log --oneline -10` — what changed recently?
    \\   - `bees status` — daily stats
    \\   - `bees tasks` — current task performance
    \\   - Sample 2-3 areas of the codebase relevant to user needs
    \\
    \\### 6. DECIDE WHAT TO BUILD
    \\   For each target user, ask:
    \\   - What's the biggest gap between what they need and what exists?
    \\   - What would deliver the most value for the least effort?
    \\   - What's currently broken or half-built that blocks their workflow?
    \\
    \\   Prioritize ruthlessly. 3 high-impact tasks beat 10 marginal ones.
    \\
    \\### 7. WRITE TASKS
    \\   Update .bees/tasks.json.
    \\   Format: [{"name": "<50 chars>", "weight": <1-5>, "prompt": "..."}, ...]
    \\
    \\   Task mix:
    \\   - **Foundation** (2-3): Infrastructure that unblocks user-facing work
    \\   - **Feature** (3-5): Capabilities users will directly benefit from
    \\   - **Quality** (2-3): Make existing features reliable and edge-case-proof
    \\   - **Experiment** (1-2): Bold bets on what users might love
    \\
    \\   Every task prompt MUST include:
    \\   1. What to build (specific files, desired behavior)
    \\   2. Which user this serves and why
    \\   3. Success criteria — what does "done" look like?
    \\   4. Edge cases to handle
    \\   5. How to verify (build/test commands)
    \\   6. End with "Commit your work"
    \\
    \\   Weights: 5=critical user need, 3=important improvement, 1=experiment/polish
    \\   Keep 10-20 tasks. Remove done/stale ones. Replace failing tasks.
    \\   After writing tasks.json, read it back to verify valid JSON.
    \\
    \\## Principles
    \\
    \\- **User value over code polish.** Don't write tasks to refactor code unless it
    \\  directly blocks something a user needs.
    \\- **Zero silent failures.** Every task must specify error handling expectations.
    \\- **Explicit over clever.** Task prompts should be specific enough that a worker
    \\  makes the right choices without guessing your intent.
    \\- **Test what matters.** Every task should specify what to verify.
    \\
    \\## Rules
    \\
    \\- NEVER run pkill, kill, systemctl stop/restart, or any process management
    \\- NEVER try to read every file — sample and rotate, use subagents for breadth
    \\- Context (user profiles, QA report, trends) is appended at the end of this prompt
    \\
;

const strategy_setup_prompt =
    \\You are setting up the strategy layer for "bees" — an autonomous multi-agent AI coding
    \\system. Bees runs Claude Code workers in parallel. A strategist agent periodically
    \\decides what workers build, based on target user needs and QA feedback.
    \\
    \\## Your Task
    \\
    \\Read the project's key files (README, package.json, config files, .bees/config.json,
    \\source code structure) to understand the tech stack, then generate:
    \\1. User profile files — who uses this project and what they need
    \\2. A tailored strategist prompt
    \\
    \\## Inferring Target Users
    \\
    \\Analyze the codebase to identify 1-3 concrete user types. For each:
    \\- **Role**: Who are they? (e.g., "Hotel manager configuring room rates via dashboard")
    \\- **Goals**: What are they trying to accomplish with this project?
    \\- **Needs**: What capabilities must exist for them to succeed?
    \\- **Frustrations**: What pain points or gaps likely exist today?
    \\- **Success looks like**: Concrete, testable outcomes
    \\
    \\Don't settle for generic descriptions — "A developer" is useless. Infer specific
    \\users from the codebase: API consumers, dashboard users, ops engineers, etc.
    \\
    \\## What to Generate
    \\
    \\### 1. User Profiles (one file per user type)
    \\Write to the users/ directory (path in project context below). Each file is a .txt
    \\named after the user role (e.g., "developer.txt", "ops-engineer.txt"). Format:
    \\
    \\  **Role**: [specific role description]
    \\  **Goals**: [what they're trying to accomplish]
    \\  **Needs**:
    \\  - [specific capability 1]
    \\  - [specific capability 2]
    \\  **Frustrations**:
    \\  - [pain point 1]
    \\  - [pain point 2]
    \\  **Success looks like**: [concrete, testable outcomes]
    \\
    \\### 2. Strategist Prompt (strategist.txt)
    \\A system prompt for the strategist agent, tailored to THIS project. Must include:
    \\
    \\- Project identity, tech stack, key files
    \\- Process: read user profiles (injected at end of prompt), read QA report,
    \\  check task trends, orient via git log + bees status, sample codebase, write tasks
    \\- Task writing guidelines with this project's build/test commands
    \\- The principle: every task must serve a target user's needs
    \\- Task format: [{"name", "weight", "prompt"}] — weights 1-5
    \\- Task prompts must include: what, which user it serves, success criteria,
    \\  edge cases, verification, "Commit your work"
    \\- Rules: no process management (pkill/kill/systemctl), sample+rotate don't read all
    \\
    \\If this is a web project: include screenshot instructions (Chrome DevTools MCP),
    \\URLs to review, viewport sizes (1920x1080 desktop, 390x844 mobile).
    \\
    \\Make it SPECIFIC — real paths, real commands, real URLs. Generic prompts are useless.
    \\
    \\Do NOT create tasks.json — the strategist generates tasks on its first run.
    \\
    \\## Rules
    \\- Do NOT modify any existing project source code — only files inside .bees/
    \\- Write valid JSON (no comments, no trailing commas)
    \\- Be efficient — read only what you need to understand the project
    \\
;

const default_user_agent_prompt =
    \\You are a simulated user agent. You embody the target user personas defined
    \\below and engage with the application as each persona would.
    \\
    \\## Your Process
    \\
    \\For each target user persona injected in the user message:
    \\
    \\### 1. BECOME THE PERSONA
    \\   Read their role, goals, needs, and frustrations. Think like them.
    \\   What would they try to do first? What question would they ask?
    \\
    \\### 2. NAVIGATE THE APPLICATION
    \\   Use Chrome DevTools MCP to interact with the live application:
    \\   - Open a tab with `new_page` for the main URL
    \\   - `resize_page` to desktop (1920x1080) and mobile (390x844)
    \\   - `take_screenshot` format="jpeg" quality=80 at key points
    \\   - Navigate between pages as the user would
    \\   - Try to accomplish the persona's goals
    \\   - When done, `close_page`
    \\
    \\### 3. REPORT YOUR EXPERIENCE
    \\   For each persona, write a narrative:
    \\   - What you tried to do (the persona's goal)
    \\   - What worked — where the product served you well
    \\   - What didn't — where you got stuck, confused, or frustrated
    \\   - What's missing — capabilities the persona needs that don't exist
    \\   - Screenshots as evidence
    \\
    \\## Output Format
    \\
    \\# User Engagement Report
    \\
    \\## [Persona Name] — [Role]
    \\**Goal**: [What they were trying to accomplish]
    \\**Journey**: [Narrative of navigation and interaction]
    \\**Verdict**: [Could they accomplish their goal? Yes/Partially/No]
    \\**Gaps**: [What's missing or broken for this persona]
    \\
    \\(Repeat for each persona)
    \\
    \\## Priority Improvements
    \\[Ranked list of changes that would deliver the most value across all personas]
    \\
    \\## Rules
    \\- NEVER run pkill, nohup, npm start, or any server/process management
    \\- NEVER modify source code — you are a simulated user, read-only
    \\- Screenshots are ground truth — if it looks broken, it IS broken
    \\- Do NOT write any files to disk
    \\
;

const default_user_profile =
    \\**Role**: Developer working on this project
    \\**Goals**: Ship reliable software, understand codebase health, maintain quality
    \\**Needs**:
    \\- Code that works correctly and handles edge cases
    \\- Clear error messages when things fail
    \\- Tests that catch real bugs
    \\- Documentation where the intent isn't obvious from the code
    \\**Frustrations**:
    \\- Silent failures that waste debugging time
    \\- Flaky tests that erode trust
    \\- Code that's hard to change because of hidden coupling
    \\**Success looks like**: Confident merges, fast feedback loops, code that's easy to reason about
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    fs.init(io);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    const cmd = cli.parse(args) catch |e| {
        try printError(stdout, e);
        try stdout.flush();
        return;
    };

    runCommand(cmd, arena, io, stdout) catch |e| {
        try printError(stdout, e);
    };

    try stdout.flush();
}

fn runCommand(cmd: cli.Command, arena: std.mem.Allocator, io: Io, stdout: *Io.Writer) !void {
    switch (cmd) {
        .version => try stdout.print("bees v{s}\n", .{version}),
        .help => try printUsage(stdout),
        .init => |opts| try cmdInit(arena, io, stdout, opts.skip_analysis),
        .start => try cmdStart(arena, io, stdout),
        .stop => try cmdStop(arena, io, stdout),
        .daemon => try cmdDaemon(arena, io, stdout),
        .status => |opts| try cmdStatus(arena, stdout, opts.json),
        .run_worker => |opts| try cmdRunWorker(arena, io, stdout, opts.id),
        .run_merger => try cmdRunMerger(arena, io, stdout),
        .run_strategist => try cmdRunStrategist(arena, io, stdout),
        .run_sre => try cmdRunSre(arena, io, stdout),
        .run_qa => try cmdRunQa(arena, io, stdout),
        .run_user => try cmdRunUser(arena, io, stdout),
        .log => try cmdLog(arena, stdout),
        .config => |opts| try cmdConfig(arena, stdout, opts.json),
        .tasks => |opts| try cmdTasks(arena, stdout, opts.json),
        .tasks_sync => |opts| try cmdTasksSync(arena, stdout, opts.file),
        .sessions => |opts| try cmdSessions(arena, stdout, opts.session_type, opts.json),
        .session => |opts| try cmdSession(arena, stdout, opts.id, opts.json),
    }
}

fn getCwd(arena: std.mem.Allocator) ![]const u8 {
    return std.process.currentPathAlloc(fs.io, arena);
}

fn loadProject(arena: std.mem.Allocator) !struct { config_mod.Config, config_mod.ProjectPaths } {
    const cwd = try getCwd(arena);
    const root = try config_mod.findProjectRoot(arena, cwd) orelse return error.NotABeesProject;
    const paths = try config_mod.ProjectPaths.init(arena, root);
    const cfg = try config_mod.load(arena, paths.config_file);
    return .{ cfg, paths };
}

fn cmdInit(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer, skip_analysis: bool) !void {
    const cwd = try getCwd(arena);

    if (!git.isGitRepo(arena, io, cwd)) {
        try stdout.print("Error: current directory is not a git repository\n", .{});
        return;
    }

    const bees_dir = try std.fs.path.join(arena, &.{ cwd, ".bees" });
    const config_path = try std.fs.path.join(arena, &.{ bees_dir, "config.json" });

    if (fs.access(config_path)) {
        try stdout.print("Project already initialized at {s}\n", .{bees_dir});
        return;
    }

    // Create directory structure
    for ([_][]const u8{ "db", "logs", "prompts", "prompts/users" }) |d| {
        const path = try std.fs.path.join(arena, &.{ bees_dir, d });
        try fs.makePath(path);
    }

    const project_name = std.fs.path.basename(cwd);
    const base_branch = git.getDefaultBranch(arena, io, cwd) orelse "main";

    if (!skip_analysis) {
        try stdout.print("Analyzing project with Claude...\n\n", .{});
        try stdout.flush();

        const prompt = try buildInitPrompt(arena, cwd, project_name, base_branch, bees_dir);
        const success = runInitSession(arena, io, stdout, cwd, prompt);

        if (success) {
            // Validate generated config
            _ = config_mod.load(arena, config_path) catch {
                try stdout.print("\nGenerated config.json is invalid, replacing with defaults...\n", .{});
                writeDefaultConfig(arena, config_path, project_name, base_branch) catch {};
            };
        } else {
            try stdout.print("\nClaude analysis failed, using defaults...\n", .{});
        }
    }

    // Ensure all required files exist (fill in anything Claude missed or skipped)
    if (!fs.access(config_path)) {
        writeDefaultConfig(arena, config_path, project_name, base_branch) catch {};
    }

    // Create empty tasks.json — the strategist populates this on first run
    const tasks_path = try std.fs.path.join(arena, &.{ bees_dir, "tasks.json" });
    if (!fs.access(tasks_path)) {
        if (fs.createFile(tasks_path, .{})) |file| {
            fs.writeFile(file, "[]\n") catch {};
            fs.closeFile(file);
        } else |_| {}
    }

    try ensureDefaultPrompts(arena, bees_dir);

    // Interactive strategy conversation — generates a tailored strategist.txt
    if (!skip_analysis) {
        const success = runStrategyConversation(arena, io, stdout, cwd, bees_dir);
        if (!success) {
            try stdout.print("\nStrategy setup skipped — using default strategist prompt.\n", .{});
            try stdout.print("You can re-run with `claude` in .bees/ to customize later.\n", .{});
        }
    }

    // Add .bees/ to .gitignore
    try addToGitignore(arena, cwd);

    try stdout.print("\nInitialized bees project at {s}\n", .{bees_dir});
    try stdout.print("Review .bees/config.json and .bees/tasks.json, then run `bees start`.\n", .{});
}

fn runInitSession(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer, cwd: []const u8, prompt: []const u8) bool {
    var child = claude.spawnClaude(arena, io, .{
        .prompt = prompt,
        .cwd = cwd,
        .model = "sonnet",
        .effort = "high",
        .max_budget_usd = 5.0,
        .max_turns = 20,
    }) catch {
        stdout.print("Failed to start Claude CLI. Is it installed?\n", .{}) catch {};
        return false;
    };

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

            const meta = claude.parseEventMeta(line_data);
            claude.streamEvent(stdout, meta, line_data);
        }
    }

    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn buildInitPrompt(arena: std.mem.Allocator, cwd: []const u8, name: []const u8, branch: []const u8, bees_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\You are setting up bees (autonomous multi-agent coding system) for this project.
        \\
        \\Project: {s}
        \\Directory: {s}
        \\Base branch: {s}
        \\Config dir: {s}
        \\
        \\Read the project's key files to understand its tech stack (README, package.json,
        \\Cargo.toml, go.mod, pyproject.toml, Makefile, build.zig, etc.), then create the
        \\configuration files below. Be efficient — read only what you need.
        \\
        \\## 1. Config: {s}/config.json
        \\
        \\JSON object. Only include sections where the project needs non-default values.
        \\
        \\  project: {{"name": "{s}", "base_branch": "{s}"}}
        \\  build: {{"command": "<cmd>", "test_command": "<cmd>", "setup_command": "<cmd>"}}
        \\    Build commands must use absolute paths: "cd {s} && <build-cmd>"
        \\    test_command: fast check (type-check/unit tests, not E2E). Null if none.
        \\    setup_command: install deps, non-interactive (--yes flags). Null if none.
        \\  workers: {{"count": 3}} — number of parallel coding agents
        \\  merger: {{"merge_threshold": 3}} — merge after N workers complete
        \\  daemon: {{"cooldown_minutes": 5, "worker_timeout_minutes": 60}}
        \\  serve (optional, for web services):
        \\    {{"systemd_unit": "<name>", "health_url": "http://localhost:<port>"}}
        \\
        \\## 2. Prompts: {s}/prompts/
        \\
        \\Create 5 prompt template files (each is a system prompt for an agent role):
        \\
        \\  worker.txt — Autonomous coding agent. Mention this project's tech stack,
        \\    build/test commands, and coding conventions. 5-10 lines.
        \\  review.txt — Code reviewer. Receives git diff via stdin. Respond ACCEPT
        \\    or REJECT with reasoning. Only reject clearly wrong/harmful changes.
        \\  conflict.txt — Merge conflict resolver. Resolve conflicts, verify build passes.
        \\  fix.txt — Build/test failure fixer. Fix the issue, verify build is green.
        \\  sre.txt — SRE monitor. CRITICAL: Must NEVER kill/restart/stop processes
        \\    (no pkill, kill, systemctl stop/restart). Only inspect and adjust config.
        \\
        \\Do NOT create tasks.json — the strategist generates tasks on its first run.
        \\
        \\## Rules
        \\- Write valid JSON (no comments, no trailing commas)
        \\- Use the Write tool to create all files
        \\- Do NOT modify any existing project source code
        \\- Do NOT create files outside {s}
        \\
    , .{ name, cwd, branch, bees_dir, bees_dir, name, branch, cwd, bees_dir, bees_dir });
}

fn runStrategyConversation(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer, cwd: []const u8, bees_dir: []const u8) bool {
    const strategist_path = std.fs.path.join(arena, &.{ bees_dir, "prompts", "strategist.txt" }) catch return false;
    const users_dir = std.fs.path.join(arena, &.{ bees_dir, "prompts", "users" }) catch return false;

    stdout.print("\nGenerating strategy (user profiles + strategist prompt)...\n\n", .{}) catch {};
    stdout.flush() catch {};

    // Build prompt with project-specific paths
    const prompt = std.fmt.allocPrint(arena,
        \\{s}
        \\
        \\## Project Context
        \\
        \\Project directory: {s}
        \\Config directory: {s}
        \\Strategist prompt: {s}
        \\User profiles dir: {s}  (one .txt file per user type)
        \\
    , .{ strategy_setup_prompt, cwd, bees_dir, strategist_path, users_dir }) catch return false;

    var child = claude.spawnClaude(arena, io, .{
        .prompt = prompt,
        .cwd = cwd,
        .model = "sonnet",
        .effort = "high",
        .max_budget_usd = 5.0,
        .max_turns = 20,
    }) catch {
        stdout.print("Failed to start Claude CLI for strategy setup.\n", .{}) catch {};
        return false;
    };

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

            const meta = claude.parseEventMeta(line_data);
            claude.streamEvent(stdout, meta, line_data);
        }
    }

    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn writeDefaultConfig(arena: std.mem.Allocator, config_path: []const u8, project_name: []const u8, base_branch: []const u8) !void {
    const content = try std.fmt.allocPrint(arena,
        \\{{
        \\  "project": {{
        \\    "name": "{s}",
        \\    "base_branch": "{s}"
        \\  }},
        \\  "workers": {{
        \\    "count": 3
        \\  }},
        \\  "merger": {{
        \\    "merge_threshold": 3
        \\  }},
        \\  "daemon": {{
        \\    "cooldown_minutes": 5,
        \\    "worker_timeout_minutes": 60
        \\  }}
        \\}}
        \\
    , .{ project_name, base_branch });
    const file = try fs.createFile(config_path, .{});
    defer fs.closeFile(file);
    try fs.writeFile(file, content);
}

fn ensureDefaultPrompts(arena: std.mem.Allocator, bees_dir: []const u8) !void {
    const prompts = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "worker.txt", .content = "You are an autonomous coding agent working on this project. Your task is described in the prompt. Work independently, make changes, run tests, and commit your work. Each commit should be atomic and have a clear message. Do not ask questions — make your best judgment calls.\n" },
        .{ .name = "review.txt", .content = "You are a code reviewer. You will receive a git diff via stdin. Review the changes for correctness, safety, and code quality. Respond with either ACCEPT or REJECT followed by your reasoning. Be concise. Only reject changes that are clearly wrong or harmful.\n" },
        .{ .name = "conflict.txt", .content = "There are merge conflicts in this repository. Resolve all conflicts by examining both sides and making the correct choice. After resolving, ensure the code compiles and tests pass.\n" },
        .{ .name = "fix.txt", .content = "The build or tests are failing after a merge. Examine the error output and fix the issue. Ensure the build passes and tests are green before committing.\n" },
        .{ .name = "sre.txt", .content = "You are the SRE agent monitoring the bees autonomous coding system. Use bees CLI commands to check system health. Identify and resolve systemic issues. Be conservative with configuration changes.\n\nCRITICAL: Do NOT kill, restart, or stop any processes (no pkill, kill, systemctl stop/restart). The daemon manages all service lifecycle. Do NOT run build commands. Only inspect and adjust configuration/tasks.\n" },
        .{ .name = "strategist.txt", .content = default_strategist_prompt },
        .{ .name = "user-agent.txt", .content = default_user_agent_prompt },
    };

    for (prompts) |p| {
        const path = try std.fs.path.join(arena, &.{ bees_dir, "prompts", p.name });
        if (fs.access(path)) continue; // Don't overwrite Claude-generated prompts
        const file = fs.createFile(path, .{}) catch continue;
        fs.writeFile(file, p.content) catch {};
        fs.closeFile(file);
    }

    // Default user profile — gets overwritten by strategy conversation
    const user_path = try std.fs.path.join(arena, &.{ bees_dir, "prompts", "users", "developer.txt" });
    if (!fs.access(user_path)) {
        const file = fs.createFile(user_path, .{}) catch return;
        defer fs.closeFile(file);
        fs.writeFile(file, default_user_profile) catch {};
    }
}

fn addToGitignore(arena: std.mem.Allocator, cwd: []const u8) !void {
    const gitignore_path = try std.fs.path.join(arena, &.{ cwd, ".gitignore" });

    const existing = fs.readFileAlloc(arena, gitignore_path, 1024 * 1024) catch "";

    if (std.mem.indexOf(u8, existing, ".bees/") != null) return;

    const file = try fs.createFile(gitignore_path, .{ .truncate = false });
    defer fs.closeFile(file);
    var content: std.ArrayList(u8) = .empty;
    if (existing.len > 0) {
        try content.appendSlice(arena, existing);
        if (existing[existing.len - 1] != '\n') {
            try content.append(arena, '\n');
        }
    }
    try content.appendSlice(arena, ".bees/\n");
    try fs.writeFile(file, content.items);
}

fn cmdStart(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer) !void {
    const project = try loadProject(arena);
    const cfg = project[0];
    const paths = project[1];

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = fs.readLinkAbsolute("/proc/self/exe", &exe_buf) catch "bees";

    try scheduler.generateAndInstall(cfg, exe_path, paths.root, arena);
    try scheduler.start(cfg, io, arena);
    try stdout.print("Bees daemon started for {s}\n", .{cfg.project.name});
}

fn cmdStop(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer) !void {
    const project = try loadProject(arena);
    const cfg = project[0];

    try scheduler.stop(cfg, io, arena);
    try stdout.print("Bees daemon stopped for {s}\n", .{cfg.project.name});
}

fn cmdDaemon(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer) !void {
    const project = try loadProject(arena);
    const cfg = project[0];
    const paths = project[1];

    fs.makePath(paths.db_dir) catch {};
    fs.makePath(paths.logs_dir) catch {};

    const db_path = paths.db_dir;
    var store = try store_mod.Store.open(db_path);
    defer store.close();

    const log_path = try std.fs.path.join(arena, &.{ paths.logs_dir, "bees.log" });
    var logger = log_mod.Logger.init(log_path);
    defer logger.deinit();

    try stdout.print("bees daemon starting for {s}...\n", .{cfg.project.name});
    try stdout.flush();

    // Use c_allocator for the daemon loop so free() actually returns memory
    // to the OS. The process arena never reclaims pages, causing unbounded
    // growth in a long-running daemon (every worker/merger/QA session leaks).
    try orchestrator.run(cfg, paths, &store, &logger, io, std.heap.c_allocator);
}

fn cmdStatus(arena: std.mem.Allocator, stdout: *Io.Writer, json: bool) !void {
    const project = try loadProject(arena);
    const cfg = project[0];
    const paths = project[1];

    const db_path = paths.db_dir;
    var store = store_mod.Store.open(db_path) catch {
        try stdout.print("No database found. Run `bees run worker` first.\n", .{});
        return;
    };
    defer store.close();

    const txn = try store.beginReadTxn();
    defer store_mod.Store.abortTxn(txn);

    const now: u64 = fs.timestamp();
    const day_start = now - @mod(now, 86400);
    const stats = try store.getDailyStats(txn, day_start);

    if (json) {
        try stdout.print("{{\"project\":", .{});
        try writeJsonStr(stdout, cfg.project.name);
        try stdout.print(",\"path\":", .{});
        try writeJsonStr(stdout, paths.root);
        try stdout.print(",\"workers\":{d},\"today\":{{\"total\":{d},\"accepted\":{d},\"rejected\":{d},\"conflicts\":{d},\"build_failures\":{d},\"cost_cents\":{d}}}}}\n", .{
            cfg.workers.count,
            stats.total, stats.accepted, stats.rejected, stats.conflicts, stats.build_failures, stats.total_cost_cents,
        });
    } else {
        try stdout.print("  Project:   {s} ({s})\n", .{ cfg.project.name, paths.root });
        try stdout.print("  Workers:   {d} configured\n", .{cfg.workers.count});
        try stdout.print("  Today:     {d} accepted, {d} rejected, {d} conflicts, {d} build failures\n", .{ stats.accepted, stats.rejected, stats.conflicts, stats.build_failures });
        try stdout.print("  Cost:      ${d:.2} today\n", .{@as(f64, @floatFromInt(stats.total_cost_cents)) / 100.0});
    }
}

fn cmdRunWorker(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer, id: ?u32) !void {
    const project = try loadProject(arena);
    const cfg = project[0];
    const paths = project[1];

    fs.makePath(paths.db_dir) catch {};

    const db_path = paths.db_dir;
    var store = try store_mod.Store.open(db_path);
    defer store.close();

    const pool = try tasks_mod.TaskPool.load(arena, paths.tasks_file);

    const log_path = try std.fs.path.join(arena, &.{ paths.logs_dir, "bees.log" });
    var logger = log_mod.Logger.init(log_path);
    defer logger.deinit();

    if (id) |worker_id| {
        _ = try worker.runWorker(cfg, paths, &store, &pool, &logger, io, worker_id, arena, true);
    } else {
        try worker.runAllWorkers(cfg, paths, &store, &pool, &logger, io, arena, true);
    }

    try stdout.print("Worker run complete\n", .{});
}

fn cmdRunMerger(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer) !void {
    const project = try loadProject(arena);
    const cfg = project[0];
    const paths = project[1];

    fs.makePath(paths.db_dir) catch {};

    const db_path = paths.db_dir;
    var store = try store_mod.Store.open(db_path);
    defer store.close();

    const log_path = try std.fs.path.join(arena, &.{ paths.logs_dir, "bees.log" });
    var logger = log_mod.Logger.init(log_path);
    defer logger.deinit();

    try merger.runMerger(cfg, paths, &store, &logger, io, arena);
    try stdout.print("Merger run complete\n", .{});
}

fn cmdRunStrategist(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer) !void {
    const project = try loadProject(arena);
    const cfg = project[0];
    const paths = project[1];

    fs.makePath(paths.db_dir) catch {};
    fs.makePath(paths.logs_dir) catch {};

    const db_path = paths.db_dir;
    var store = try store_mod.Store.open(db_path);
    defer store.close();

    const log_path = try std.fs.path.join(arena, &.{ paths.logs_dir, "bees.log" });
    var logger = log_mod.Logger.init(log_path);
    defer logger.deinit();

    // Build and restart serve process before strategist runs
    if (cfg.build.command) |build_cmd| {
        try stdout.print("Building: {s}\n", .{build_cmd});
        try stdout.flush();
        const build_result = try git.run(arena, io, &.{ "sh", "-c", build_cmd }, paths.root);
        arena.free(build_result.stdout);
        arena.free(build_result.stderr);
        if (build_result.exit_code != 0) {
            try stdout.print("Warning: build exited {d}, continuing anyway\n", .{build_result.exit_code});
        }
    }

    if (cfg.serve.systemd_unit) |unit| {
        try stdout.print("Restarting service: {s}\n", .{unit});
        try stdout.flush();
        const restart_result = try git.run(arena, io, &.{ "systemctl", "--user", "restart", unit }, paths.root);
        arena.free(restart_result.stdout);
        arena.free(restart_result.stderr);
        if (restart_result.exit_code != 0) {
            try stdout.print("Warning: systemctl restart exited {d}\n", .{restart_result.exit_code});
        }
    }

    if (cfg.serve.health_url) |url| {
        try stdout.print("Waiting for health check: {s}\n", .{url});
        try stdout.flush();
        var elapsed: u32 = 0;
        const deadline = cfg.serve.health_timeout_secs;
        while (elapsed < deadline) : (elapsed += 2) {
            const hc = git.run(arena, io, &.{ "curl", "-sf", "-o", "/dev/null", "--max-time", "2", url }, paths.root) catch {
                io.sleep(Io.Duration.fromSeconds(2), .awake) catch {};
                continue;
            };
            arena.free(hc.stdout);
            arena.free(hc.stderr);
            if (hc.exit_code == 0) {
                try stdout.print("Server healthy after {d}s\n", .{elapsed});
                break;
            }
            io.sleep(Io.Duration.fromSeconds(2), .awake) catch {};
        }
    }

    // Build context from all sources via the context module
    const context = ctx_mod.build(&store, paths, &.{
        .user_profiles, .operator_feedback, .report_user, .report_qa, .report_sre, .task_trends,
    }, .{}, arena);

    try stdout.print("Running strategist...\n", .{});
    try stdout.flush();

    try strategist_mod.runStrategist(cfg, paths, &store, &logger, io, arena, true, context);
    try stdout.print("Strategist run complete\n", .{});
}

fn cmdRunSre(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer) !void {
    const project = try loadProject(arena);
    const cfg = project[0];
    const paths = project[1];

    fs.makePath(paths.db_dir) catch {};
    fs.makePath(paths.logs_dir) catch {};

    const db_path = paths.db_dir;
    var store = try store_mod.Store.open(db_path);
    defer store.close();

    const log_path = try std.fs.path.join(arena, &.{ paths.logs_dir, "bees.log" });
    var logger = log_mod.Logger.init(log_path);
    defer logger.deinit();

    try stdout.print("Running SRE agent...\n", .{});
    try stdout.flush();

    try sre_mod.runSre(cfg, paths, &store, &logger, io, arena, true, null, 0);
    try stdout.print("SRE run complete\n", .{});
}

fn cmdRunQa(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer) !void {
    const project = try loadProject(arena);
    const cfg = project[0];
    const paths = project[1];

    fs.makePath(paths.db_dir) catch {};
    fs.makePath(paths.logs_dir) catch {};

    const db_path = paths.db_dir;
    var store = try store_mod.Store.open(db_path);
    defer store.close();

    const log_path = try std.fs.path.join(arena, &.{ paths.logs_dir, "bees.log" });
    var logger = log_mod.Logger.init(log_path);
    defer logger.deinit();

    // Build and restart serve process
    if (cfg.build.command) |build_cmd| {
        try stdout.print("Building: {s}\n", .{build_cmd});
        try stdout.flush();
        const build_result = try git.run(arena, io, &.{ "sh", "-c", build_cmd }, paths.root);
        arena.free(build_result.stdout);
        arena.free(build_result.stderr);
        if (build_result.exit_code != 0) {
            try stdout.print("Warning: build exited {d}, continuing anyway\n", .{build_result.exit_code});
        }
    }

    if (cfg.serve.systemd_unit) |unit| {
        try stdout.print("Restarting service: {s}\n", .{unit});
        try stdout.flush();
        const restart_result = try git.run(arena, io, &.{ "systemctl", "--user", "restart", unit }, paths.root);
        arena.free(restart_result.stdout);
        arena.free(restart_result.stderr);
    }

    if (cfg.serve.health_url) |url| {
        try stdout.print("Waiting for health check: {s}\n", .{url});
        try stdout.flush();
        var elapsed: u32 = 0;
        while (elapsed < cfg.serve.health_timeout_secs) : (elapsed += 2) {
            const hc = git.run(arena, io, &.{ "curl", "-sf", "-o", "/dev/null", "--max-time", "2", url }, paths.root) catch {
                io.sleep(Io.Duration.fromSeconds(2), .awake) catch {};
                continue;
            };
            arena.free(hc.stdout);
            arena.free(hc.stderr);
            if (hc.exit_code == 0) {
                try stdout.print("Server healthy after {d}s\n", .{elapsed});
                break;
            }
            io.sleep(Io.Duration.fromSeconds(2), .awake) catch {};
        }
    }

    try stdout.print("Running QA agent...\n", .{});
    try stdout.flush();

    try qa_mod.runQa(cfg, paths, &store, &logger, io, arena, null, true);
    try stdout.print("QA run complete\n", .{});
}

fn cmdRunUser(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer) !void {
    const project = try loadProject(arena);
    const cfg = project[0];
    const paths = project[1];

    fs.makePath(paths.db_dir) catch {};
    fs.makePath(paths.logs_dir) catch {};

    var store = try store_mod.Store.open(paths.db_dir);
    defer store.close();

    const log_path = try std.fs.path.join(arena, &.{ paths.logs_dir, "bees.log" });
    var logger = log_mod.Logger.init(log_path);
    defer logger.deinit();

    try stdout.print("Running user engagement agent...\n", .{});
    try stdout.flush();

    try user_mod.runUser(cfg, paths, &store, &logger, io, arena, null, true);
    try stdout.print("User engagement complete\n", .{});
}

fn cmdLog(arena: std.mem.Allocator, stdout: *Io.Writer) !void {
    const project = try loadProject(arena);
    const paths = project[1];

    const log_path = try std.fs.path.join(arena, &.{ paths.logs_dir, "bees.log" });
    const content = fs.readFileAlloc(arena, log_path, 10 * 1024 * 1024) catch {
        try stdout.print("No log file found\n", .{});
        return;
    };

    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trim(u8, content, &std.ascii.whitespace), '\n');
    var line_list: [50][]const u8 = undefined;
    var count: usize = 0;
    while (lines.next()) |line| {
        if (count >= 50) break;
        line_list[count] = line;
        count += 1;
    }

    var i = count;
    while (i > 0) {
        i -= 1;
        try stdout.print("{s}\n", .{line_list[i]});
    }
}

fn cmdConfig(arena: std.mem.Allocator, stdout: *Io.Writer, json: bool) !void {
    const project = try loadProject(arena);
    const cfg = project[0];
    const paths = project[1];

    if (json) {
        const content = try fs.readFileAlloc(arena, paths.config_file, 1024 * 1024);
        try stdout.print("{s}\n", .{content});
    } else {
        try stdout.print("Project: {s}\n", .{cfg.project.name});
        try stdout.print("Base branch: {s}\n", .{cfg.project.base_branch});
        try stdout.print("Workers: {d} (model={s}, effort={s}, budget=${d:.0})\n", .{ cfg.workers.count, cfg.workers.model, cfg.workers.effort, cfg.workers.max_budget_usd });
        try stdout.print("Merger: model={s}, effort={s}, budget=${d:.0}\n", .{ cfg.merger.model, cfg.merger.effort, cfg.merger.max_budget_usd });
        if (cfg.build.command) |cmd| try stdout.print("Build: {s}\n", .{cmd});
        if (cfg.build.test_command) |cmd| try stdout.print("Test: {s}\n", .{cmd});
        if (cfg.build.deploy_command) |cmd| try stdout.print("Deploy: {s}\n", .{cmd});
    }
}

fn cmdTasks(arena: std.mem.Allocator, stdout: *Io.Writer, json: bool) !void {
    const project = try loadProject(arena);
    const paths = project[1];

    // Try LMDB first
    const db_path = paths.db_dir;
    var store = store_mod.Store.open(db_path) catch {
        // Fallback to file
        if (json) {
            const content = try fs.readFileAlloc(arena, paths.tasks_file, 1024 * 1024);
            try stdout.print("{s}\n", .{content});
        } else {
            const pool = try tasks_mod.TaskPool.load(arena, paths.tasks_file);
            for (pool.tasks) |a| {
                try stdout.print("  {s} (weight={d})\n", .{ a.name, a.weight });
            }
        }
        return;
    };
    defer store.close();

    const txn = try store.beginReadTxn();
    defer store_mod.Store.abortTxn(txn);

    var iter = try store.iterTasks(txn);
    defer iter.close();

    if (json) {
        try stdout.print("[", .{});
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try stdout.print(",", .{});
            first = false;
            try stdout.print("{{\"name\":", .{});
            try writeJsonStr(stdout, entry.name);
            try stdout.print(",\"weight\":{d},\"prompt\":", .{entry.view.header.weight});
            // Simple JSON string escape for prompt
            try stdout.print("\"", .{});
            for (entry.view.prompt) |ch| {
                switch (ch) {
                    '"' => try stdout.print("\\\"", .{}),
                    '\\' => try stdout.print("\\\\", .{}),
                    '\n' => try stdout.print("\\n", .{}),
                    '\r' => {},
                    '\t' => try stdout.print("\\t", .{}),
                    else => {
                        if (ch >= 0x20) {
                            try stdout.print("{c}", .{ch});
                        }
                    },
                }
            }
            try stdout.print("\"", .{});
            try stdout.print(",\"total_runs\":{d},\"accepted\":{d},\"rejected\":{d},\"empty\":{d},\"status\":\"{s}\",\"origin\":\"{s}\"}}", .{
                entry.view.header.total_runs,
                entry.view.header.accepted,
                entry.view.header.rejected,
                entry.view.header.empty,
                entry.view.header.status.label(),
                entry.view.header.origin.label(),
            });
        }
        try stdout.print("]\n", .{});
    } else {
        while (iter.next()) |entry| {
            try stdout.print("  {s} (weight={d}, runs={d}, accepted={d}, status={s})\n", .{
                entry.name,
                entry.view.header.weight,
                entry.view.header.total_runs,
                entry.view.header.accepted,
                entry.view.header.status.label(),
            });
        }
    }
}

fn cmdTasksSync(arena: std.mem.Allocator, stdout: *Io.Writer, file: ?[]const u8) !void {
    const project = try loadProject(arena);
    const paths = project[1];

    fs.makePath(paths.db_dir) catch {};

    const db_path = paths.db_dir;
    var store = try store_mod.Store.open(db_path);
    defer store.close();

    const tasks_path = file orelse paths.tasks_file;
    try tasks_mod.syncFromFile(&store, tasks_path, arena);

    // Backfill session meta for dashboard direct reads
    store.backfillSessionMeta() catch {};

    // Clean up any stale running sessions
    const cleaned = store.cleanupStaleSessions();
    if (cleaned > 0) {
        try stdout.print("Cleaned up {d} stale running sessions\n", .{cleaned});
    }

    try stdout.print("Tasks synced to LMDB from {s}\n", .{tasks_path});
}

fn cmdSessions(arena: std.mem.Allocator, stdout: *Io.Writer, session_type: ?types.SessionType, json: bool) !void {
    const project = try loadProject(arena);
    const paths = project[1];

    const db_path = paths.db_dir;
    var store = store_mod.Store.open(db_path) catch {
        try stdout.print("No database found\n", .{});
        return;
    };
    defer store.close();

    const txn = try store.beginReadTxn();
    defer store_mod.Store.abortTxn(txn);

    if (json) {
        try stdout.print("[", .{});
    } else {
        try stdout.print("  {s:<6} {s:<10} {s:<10} {s:<8} {s:<10} {s:<30}\n", .{ "ID", "Type", "Status", "Commits", "Cost", "Task" });
        try stdout.print("  {s:-<6} {s:-<10} {s:-<10} {s:-<8} {s:-<10} {s:-<30}\n", .{ "", "", "", "", "", "" });
    }

    var iter = try store.iterSessions(txn);
    defer iter.close();
    var printed: u32 = 0;
    var first_json = true;
    while (printed < 50) {
        const entry = iter.next() orelse break;
        if (session_type) |st| {
            if (entry.view.header.@"type" != st) continue;
        }

        if (json) {
            if (!first_json) try stdout.print(",", .{});
            first_json = false;
            try stdout.print("{{\"id\":{d},\"type\":\"{s}\",\"status\":\"{s}\",\"commits\":{d},\"cost_cents\":{d},\"task\":", .{
                entry.id, entry.view.header.@"type".label(), entry.view.header.status.label(),
                entry.view.header.commit_count, @as(u64, entry.view.header.cost_microdollars) / 10000,
            });
            try writeJsonStr(stdout, entry.view.task);
            try stdout.print(",\"branch\":", .{});
            try writeJsonStr(stdout, entry.view.branch);
            try stdout.print(",\"duration_ms\":{d},\"started_at\":{d}", .{
                entry.view.header.duration_ms, @as(u64, entry.view.header.started_at),
            });
            if (entry.view.header.has_tokens) {
                try stdout.print(",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_creation_tokens\":{d},\"cache_read_tokens\":{d}", .{
                    entry.view.header.input_tokens,
                    entry.view.header.output_tokens,
                    entry.view.header.cache_creation_tokens,
                    entry.view.header.cache_read_tokens,
                });
            }
            if (entry.view.header.has_result_detail) {
                try stdout.print(",\"result_subtype\":\"{s}\",\"stop_reason\":\"{s}\",\"duration_api_ms\":{d}", .{
                    entry.view.header.result_subtype.label(),
                    entry.view.header.stop_reason.label(),
                    entry.view.header.duration_api_ms,
                });
            }
            try stdout.print("}}", .{});
        } else {
            try stdout.print("  {d:<6} {s:<10} {s:<10} {d:<8} ${d:<9.2} {s:<30}\n", .{
                entry.id, entry.view.header.@"type".label(), entry.view.header.status.label(),
                entry.view.header.commit_count, @as(f64, @floatFromInt(entry.view.header.cost_microdollars)) / 1000000.0, entry.view.task,
            });
        }
        printed += 1;
    }

    if (json) try stdout.print("]\n", .{});
}

fn cmdSession(arena: std.mem.Allocator, stdout: *Io.Writer, id: u64, json: bool) !void {
    const project = try loadProject(arena);
    const paths = project[1];

    const db_path = paths.db_dir;
    var store = store_mod.Store.open(db_path) catch {
        try stdout.print("No database found\n", .{});
        return;
    };
    defer store.close();

    const txn = try store.beginReadTxn();
    defer store_mod.Store.abortTxn(txn);

    const session = (try store.getSession(txn, id)) orelse {
        try stdout.print("Session {d} not found\n", .{id});
        return;
    };

    if (json) {
        try stdout.print("{{\"id\":{d},\"type\":\"{s}\",\"status\":\"{s}\",\"commits\":{d},\"cost_cents\":{d},\"cost_microdollars\":{d},\"task\":", .{
            id, session.header.@"type".label(), session.header.status.label(),
            session.header.commit_count, @as(u64, session.header.cost_microdollars) / 10000,
            session.header.cost_microdollars,
        });
        try writeJsonStr(stdout, session.task);
        try stdout.print(",\"branch\":", .{});
        try writeJsonStr(stdout, session.branch);
        try stdout.print(",\"turns\":{d},\"duration_ms\":{d},\"started_at\":{d}", .{
            session.header.num_turns,
            session.header.duration_ms, @as(u64, session.header.started_at),
        });
        if (session.header.has_tokens) {
            try stdout.print(",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_creation_tokens\":{d},\"cache_read_tokens\":{d}", .{
                session.header.input_tokens,
                session.header.output_tokens,
                session.header.cache_creation_tokens,
                session.header.cache_read_tokens,
            });
        }
        try stdout.print(",\"events\":[", .{});
    } else {
        try stdout.print("Session #{d} | {s} | {s}\n", .{ id, session.header.@"type".label(), session.branch });
        try stdout.print("Status: {s} | Cost: ${d:.2} | Commits: {d} | Turns: {d}\n", .{
            session.header.status.label(), @as(f64, @floatFromInt(session.header.cost_microdollars)) / 1000000.0,
            session.header.commit_count, session.header.num_turns,
        });
        if (session.task.len > 0) try stdout.print("Task: {s}\n\nEvents:\n", .{session.task});
    }

    var event_iter = try store.iterSessionEvents(txn, id);
    defer event_iter.close();
    var first_json_event = true;

    while (event_iter.next()) |ev| {
        if (json) {
            if (!first_json_event) try stdout.print(",", .{});
            first_json_event = false;
            try stdout.print("{{\"seq\":{d},\"type\":\"{s}\",\"tool\":\"{s}\"", .{
                ev.seq, ev.header.event_type.label(), ev.header.tool_name.label(),
            });
            if (ev.header.role != .none) {
                try stdout.print(",\"role\":\"{s}\"", .{ev.header.role.label()});
            }
            if (ev.header.event_type == .result) {
                if (claude.findJsonNumberValue(ev.raw_json, "\"total_cost_usd\"")) |cost| {
                    const cents: u64 = @intFromFloat(@max(cost * 100.0, 0.0));
                    try stdout.print(",\"cost_cents\":{d}", .{cents});
                }
                if (claude.findJsonNumberValue(ev.raw_json, "\"duration_ms\"")) |dur| {
                    const ms: u64 = @intFromFloat(@max(dur, 0.0));
                    try stdout.print(",\"duration_ms\":{d}", .{ms});
                }
            }
            // Include raw JSON for full event data
            try stdout.print(",\"raw\":", .{});
            try stdout.writeAll(ev.raw_json);
            // Extract text preview for message and tool_result events
            {
                const text_preview: ?[]const u8 = blk: {
                    if (ev.header.role == .assistant) {
                        break :blk claude.findJsonStringValue(ev.raw_json, "\"text\"");
                    }
                    if (ev.header.event_type == .tool_result) {
                        // tool_result JSON has "content":[array] then nested "content":"string"
                        // findJsonStringValue skips array values and finds the string one
                        if (claude.findJsonStringValue(ev.raw_json, "\"content\"")) |c| {
                            // Skip if it matched the "content" key whose value is "tool_result" (the type field)
                            if (!std.mem.eql(u8, c, "tool_result") and !std.mem.eql(u8, c, "text")) {
                                break :blk c;
                            }
                        }
                        // Fallback: try "text" inside content blocks
                        break :blk claude.findJsonStringValue(ev.raw_json, "\"text\"");
                    }
                    break :blk null;
                };
                if (text_preview) |text| {
                    const max_len: usize = 200;
                    const preview = if (text.len > max_len) text[0..max_len] else text;
                    try stdout.print(",\"message\":\"", .{});
                    for (preview) |ch| {
                        switch (ch) {
                            '"' => try stdout.print("\\\"", .{}),
                            '\\' => try stdout.print("\\\\", .{}),
                            '\n' => try stdout.print(" ", .{}),
                            '\r' => {},
                            '\t' => try stdout.print(" ", .{}),
                            else => {
                                if (ch >= 0x20) {
                                    try stdout.print("{c}", .{ch});
                                }
                            },
                        }
                    }
                    try stdout.print("\"", .{});
                }
            }
            try stdout.print("}}", .{});
        } else {
            if (ev.header.event_type == .tool_use) try stdout.print("  [{d}] {s}\n", .{ ev.seq, ev.header.tool_name.label() })
            else if (ev.header.event_type == .message) try stdout.print("  [{d}] {s} message\n", .{ ev.seq, ev.header.role.label() })
            else if (ev.header.event_type == .result) try stdout.print("  [{d}] result\n", .{ev.seq});
        }
    }

    if (json) try stdout.print("]}}\n", .{});

    if (!json) {
        if (try store.getReview(txn, id)) |review| {
            try stdout.print("\nReview: {s}\n{s}\n", .{ review.header.verdict.label(), review.reason });
        }
    }
}

fn printUsage(stdout: *Io.Writer) !void {
    try stdout.print(
        \\bees v{s} — autonomous multi-agent code improvement
        \\
        \\Usage: bees <command> [options]
        \\
        \\Commands:
        \\  init [--skip-analysis]   Initialize bees in current project
        \\  daemon                   Run continuous orchestrator (workers + merger + SRE)
        \\  start                    Install and enable systemd service
        \\  stop                     Disable systemd service
        \\  status [--json]          Show project status
        \\  run worker [--id N]      Run workers (one-shot)
        \\  run merger               Run merger (one-shot)
        \\  run strategist           Run strategist (one-shot)
        \\  run sre                  Run SRE agent (one-shot)
        \\  run qa                   Run QA agent (one-shot)
        \\  log [--follow]           Show log
        \\  config [--json]          Show config
        \\  tasks [--json]           List tasks (from LMDB if available)
        \\  tasks sync [file]       Sync tasks.json into LMDB
        \\  sessions [--type X] [--json]  List sessions
        \\  session <id> [--json]    Show session detail (--json includes raw event data)
        \\  version                  Print version
        \\
    , .{version});
}

/// Write a JSON-escaped string (with surrounding quotes) to a Writer.
fn writeJsonStr(w: *Io.Writer, s: []const u8) !void {
    try w.print("\"", .{});
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch >= 0x20) {
                    try w.print("{c}", .{ch});
                }
            },
        }
    }
    try w.print("\"", .{});
}

fn printError(stdout: *Io.Writer, e: anyerror) !void {
    const msg: []const u8 = switch (e) {
        error.MissingSessionId => "Missing session ID. Usage: bees session <id>",
        error.InvalidSessionId => "Invalid session ID. Must be a number.",
        error.MissingRunSubcommand => "Missing subcommand. Usage: bees run worker|merger|strategist|sre|qa",
        error.UnknownRunSubcommand => "Unknown subcommand. Usage: bees run worker|merger|strategist|sre|qa",
        error.UnknownCommand => "Unknown command. Run `bees help` for usage.",
        error.InvalidWorkerId => "Invalid worker ID. Must be a number.",
        error.NotABeesProject => "Not a bees project. Run `bees init` first.",
        else => "An error occurred",
    };
    try stdout.print("Error: {s} ({s})\n", .{ msg, @errorName(e) });
}

comptime {
    _ = cli;
    _ = config_mod;
    _ = store_mod;
    _ = types;
    _ = worker;
    _ = merger;
    _ = claude;
    _ = backend;
    _ = @import("backend_codex.zig");
    _ = @import("backend_opencode.zig");
    _ = @import("backend_pi.zig");
    _ = git;
    _ = scheduler;
    _ = tasks_mod;
    _ = log_mod;
    _ = fs;
    _ = orchestrator;
    _ = sre_mod;
    _ = @import("strategist.zig");
    _ = @import("api.zig");
    _ = qa_mod;
    _ = @import("dlq.zig");
}

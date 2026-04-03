//! Default role configurations and workflow for bees init.
//! Generates .bees/roles/*/ and .bees/workflows/default.json.

const std = @import("std");
const fs = @import("fs.zig");

const RoleDef = struct {
    name: []const u8,
    config: []const u8,
    prompt: []const u8,
};

const roles = [_]RoleDef{
    .{
        .name = "worker",
        .config =
            \\{
            \\  "model": "sonnet",
            \\  "effort": "high",
            \\  "max_budget_usd": 30,
            \\  "sources": [],
            \\  "produces": [],
            \\  "stores_report": false
            \\}
            \\
        ,
        .prompt =
            \\You are an autonomous coding agent working on this project.
            \\Your task is described in the prompt. Work independently, make changes,
            \\run tests, and commit your work. Each commit should be atomic and have
            \\a clear message. Do not ask questions — make your best judgment calls.
            \\
        ,
    },
    .{
        .name = "review",
        .config =
            \\{
            \\  "model": "sonnet",
            \\  "effort": "high",
            \\  "max_budget_usd": 30,
            \\  "sources": ["task_context"],
            \\  "stores_report": false
            \\}
            \\
        ,
        .prompt =
            \\You are a code reviewer. You will receive a git diff and the task context
            \\that the worker was assigned. Review the changes for correctness, safety,
            \\and whether they accomplish the intended task. If the changes are good,
            \\merge them. If they are harmful or wrong, do NOT merge.
            \\
        ,
    },
    .{
        .name = "merger",
        .config =
            \\{
            \\  "model": "sonnet",
            \\  "effort": "high",
            \\  "max_budget_usd": 30,
            \\  "sources": [],
            \\  "stores_report": false
            \\}
            \\
        ,
        .prompt =
            \\There are merge conflicts in this repository. Resolve all conflicts by
            \\examining both sides and making the correct choice. After resolving,
            \\ensure the code compiles and tests pass.
            \\
        ,
    },
    .{
        .name = "qa",
        .config =
            \\{
            \\  "model": "opus",
            \\  "effort": "medium",
            \\  "max_budget_usd": 30,
            \\  "fallback_model": "sonnet",
            \\  "sources": ["user_profiles", "changed_files", "worker_summary"],
            \\  "stores_report": true
            \\}
            \\
        ,
        .prompt =
            \\You are the QA agent. After each merge cycle, evaluate the application
            \\as a USER — not as a test harness. Navigate with intention, ask questions
            \\of the UI, and report honestly on whether it answered them.
            \\
            \\Your output is an EXPERIENCE REPORT — a narrative of what you tried to do,
            \\what worked, what confused you, and where the product falls short.
            \\
        ,
    },
    .{
        .name = "user",
        .config =
            \\{
            \\  "model": "sonnet",
            \\  "effort": "high",
            \\  "max_budget_usd": 30,
            \\  "sources": ["user_profiles", "worker_summary"],
            \\  "stores_report": true
            \\}
            \\
        ,
        .prompt =
            \\You are a simulated user agent. You embody the target user personas
            \\and engage with the application as each persona would.
            \\
            \\Use Chrome DevTools MCP to navigate the live application, take screenshots,
            \\and report your experience for each persona.
            \\
        ,
    },
    .{
        .name = "sre",
        .config =
            \\{
            \\  "model": "sonnet",
            \\  "effort": "high",
            \\  "max_budget_usd": 30,
            \\  "max_turns": 10,
            \\  "sources": [],
            \\  "stores_report": true
            \\}
            \\
        ,
        .prompt =
            \\You are the SRE agent monitoring the bees autonomous coding system.
            \\Use bees CLI commands to check system health. Identify and resolve
            \\systemic issues. Be conservative with configuration changes.
            \\
            \\CRITICAL: Do NOT kill, restart, or stop any processes (no pkill, kill,
            \\systemctl stop/restart). The daemon manages all service lifecycle.
            \\
        ,
    },
    .{
        .name = "strategist",
        .config =
            \\{
            \\  "model": "opus",
            \\  "effort": "high",
            \\  "max_budget_usd": 30,
            \\  "fallback_model": "sonnet",
            \\  "sources": [
            \\    "user_profiles",
            \\    "operator_feedback",
            \\    "report:user",
            \\    "report:qa",
            \\    "report:sre",
            \\    "task_trends"
            \\  ],
            \\  "produces": ["asset:tasks"],
            \\  "stores_report": true
            \\}
            \\
        ,
        .prompt =
            \\You are the Strategist for this project. Your job: decide what the AI
            \\worker swarm should build next based on concrete context — target user
            \\profiles, operator feedback, QA/user/SRE reports, and task trends.
            \\
            \\The user profiles are your north star. Operator feedback is your highest
            \\priority signal. Every task you write should close the gap between what
            \\users need and what the project currently delivers.
            \\
        ,
    },
};

const default_workflow =
    \\{
    \\  "name": "default",
    \\  "steps": [
    \\    { "role": "worker", "parallel": 3 },
    \\    { "role": "merger", "trigger": "workers_done" },
    \\    { "role": "qa" },
    \\    { "role": "user" },
    \\    { "role": "sre", "condition": "tool_errors" },
    \\    { "role": "strategist", "every": 3 }
    \\  ],
    \\  "cycle": {
    \\    "cooldown_minutes": 5,
    \\    "merge_threshold": 3,
    \\    "worker_timeout_minutes": 60
    \\  }
    \\}
    \\
;

/// Generate the default .bees/roles/ and .bees/workflows/ structure.
pub fn generateDefaults(bees_dir: []const u8, allocator: std.mem.Allocator) void {
    // Create roles
    for (roles) |role| {
        const role_dir = std.fs.path.join(allocator, &.{ bees_dir, "roles", role.name }) catch continue;
        defer allocator.free(role_dir);
        fs.makePath(role_dir) catch continue;

        // config.json
        const cfg_path = std.fs.path.join(allocator, &.{ role_dir, "config.json" }) catch continue;
        defer allocator.free(cfg_path);
        if (!fs.access(cfg_path)) {
            const f = fs.createFile(cfg_path, .{}) catch continue;
            fs.writeFile(f, role.config) catch {};
            fs.closeFile(f);
        }

        // prompt.md
        const prompt_path = std.fs.path.join(allocator, &.{ role_dir, "prompt.md" }) catch continue;
        defer allocator.free(prompt_path);
        if (!fs.access(prompt_path)) {
            const f = fs.createFile(prompt_path, .{}) catch continue;
            fs.writeFile(f, role.prompt) catch {};
            fs.closeFile(f);
        }
    }

    // Create workflow
    const wf_dir = std.fs.path.join(allocator, &.{ bees_dir, "workflows" }) catch return;
    defer allocator.free(wf_dir);
    fs.makePath(wf_dir) catch return;

    const wf_path = std.fs.path.join(allocator, &.{ wf_dir, "default.json" }) catch return;
    defer allocator.free(wf_path);
    if (!fs.access(wf_path)) {
        const f = fs.createFile(wf_path, .{}) catch return;
        fs.writeFile(f, default_workflow) catch {};
        fs.closeFile(f);
    }
}

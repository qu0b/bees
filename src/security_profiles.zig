//! Built-in security profiles for bees agent roles.
//!
//! Each profile defines which Claude Code tools a role is allowed or denied.
//! Tool specifiers follow Claude Code's permission format:
//!   "Read"              — allow all reads
//!   "Bash(git *)"       — allow only git commands
//!   "Edit(/src/**)"     — allow edits only under /src/
//!   "mcp__*"            — allow all MCP tools
//!
//! Resolution order:
//!   1. Explicit `permissions` in role config (highest)
//!   2. Named `security_profile` in role config
//!   3. Default profile for session type
//!   4. Fallback: --dangerously-skip-permissions (legacy, no restrictions)

const std = @import("std");
const types = @import("types.zig");

pub const ToolPermissions = struct {
    permission_mode: []const u8 = "dontAsk",
    allowed_tools: []const []const u8 = &.{},
    disallowed_tools: []const []const u8 = &.{},
};

/// Look up a built-in profile by name.
pub fn getProfile(name: []const u8) ?ToolPermissions {
    if (std.mem.eql(u8, name, "worker")) return worker;
    if (std.mem.eql(u8, name, "merger")) return merger;
    if (std.mem.eql(u8, name, "qa")) return qa;
    if (std.mem.eql(u8, name, "sre")) return sre;
    if (std.mem.eql(u8, name, "strategist")) return strategist;
    if (std.mem.eql(u8, name, "user")) return user_agent;
    if (std.mem.eql(u8, name, "researcher")) return researcher;
    if (std.mem.eql(u8, name, "review")) return readonly;
    if (std.mem.eql(u8, name, "readonly")) return readonly;
    return null;
}

/// Map session type to its default profile.
pub fn getDefaultForSessionType(session_type: types.SessionType) ?ToolPermissions {
    return switch (session_type) {
        .worker => worker,
        .merger => merger,
        .qa => qa,
        .sre => sre,
        .strategist => strategist,
        .user => user_agent,
        .researcher => researcher,
        .review => readonly,
        else => null,
    };
}

// ── Worker ──────────────────────────────────────────────────────────────
// Full code editing in worktree, build/test, git operations.
// No network access, no privilege escalation.
const worker = ToolPermissions{
    .permission_mode = "dontAsk",
    .allowed_tools = &.{
        "Read",
        "Edit",
        "Write",
        "Glob",
        "Grep",
        "Bash(git *)",
        "Bash(zig build *)",
        "Bash(npm *)",
        "Bash(cargo *)",
        "Bash(make *)",
        "Bash(python *)",
        "Bash(node *)",
        "Bash(cat *)",
        "Bash(ls *)",
        "Bash(mkdir *)",
        "Bash(cp *)",
        "Bash(mv *)",
        "Bash(head *)",
        "Bash(tail *)",
        "Bash(wc *)",
        "Bash(diff *)",
        "Bash(sort *)",
        "Bash(find *)",
        "Bash(test *)",
        "Bash(echo *)",
        "Bash(cd *)",
        "Bash(sh *)",
    },
    .disallowed_tools = &.{
        "WebSearch",
        "WebFetch",
        "Bash(curl *)",
        "Bash(wget *)",
        "Bash(ssh *)",
        "Bash(scp *)",
        "Bash(sudo *)",
        "Bash(su *)",
        "Bash(kill *)",
        "Bash(pkill *)",
        "Bash(killall *)",
        "Bash(systemctl *)",
        "Bash(rm -rf /*)",
    },
};

// ── Merger ──────────────────────────────────────────────────────────────
// Same as worker + deploy commands. Still no network.
const merger = ToolPermissions{
    .permission_mode = "dontAsk",
    .allowed_tools = &.{
        "Read",
        "Edit",
        "Write",
        "Glob",
        "Grep",
        "Bash(git *)",
        "Bash(zig build *)",
        "Bash(npm *)",
        "Bash(cargo *)",
        "Bash(make *)",
        "Bash(cat *)",
        "Bash(ls *)",
        "Bash(mkdir *)",
        "Bash(sh *)",
        "Bash(diff *)",
    },
    .disallowed_tools = &.{
        "WebSearch",
        "WebFetch",
        "Bash(curl *)",
        "Bash(wget *)",
        "Bash(sudo *)",
        "Bash(systemctl *)",
    },
};

// ── QA ──────────────────────────────────────────────────────────────────
// Read-only code access + browser testing via MCP.
// Cannot modify code or push.
const qa = ToolPermissions{
    .permission_mode = "dontAsk",
    .allowed_tools = &.{
        "Read",
        "Glob",
        "Grep",
        "Bash(git log *)",
        "Bash(git diff *)",
        "Bash(git show *)",
        "Bash(git status *)",
        "Bash(npm test *)",
        "Bash(npm run test *)",
        "Bash(zig build test *)",
        "Bash(cat *)",
        "Bash(ls *)",
        "mcp__*",
    },
    .disallowed_tools = &.{
        "Edit",
        "Write",
        "Bash(git commit *)",
        "Bash(git push *)",
        "Bash(git merge *)",
        "Bash(sudo *)",
        "Bash(rm *)",
    },
};

// ── SRE ─────────────────────────────────────────────────────────────────
// Monitor system health, edit configs, no destructive service ops.
const sre = ToolPermissions{
    .permission_mode = "dontAsk",
    .allowed_tools = &.{
        "Read",
        "Glob",
        "Grep",
        "Edit",
        "Write",
        "Bash(bees *)",
        "Bash(git log *)",
        "Bash(git status *)",
        "Bash(git diff *)",
        "Bash(cat *)",
        "Bash(ls *)",
        "Bash(df *)",
        "Bash(du *)",
        "Bash(free *)",
        "Bash(ps *)",
        "Bash(uptime *)",
        "Bash(top -bn1 *)",
        "Bash(journalctl *)",
        "Bash(systemctl status *)",
        "Bash(curl *)",
    },
    .disallowed_tools = &.{
        "Bash(kill *)",
        "Bash(pkill *)",
        "Bash(killall *)",
        "Bash(systemctl stop *)",
        "Bash(systemctl restart *)",
        "Bash(systemctl disable *)",
        "Bash(sudo *)",
        "Bash(rm -rf *)",
        "Bash(git push *)",
    },
};

// ── Strategist ──────────────────────────────────────────────────────────
// Analysis + task writing. Can edit tasks.json, read everything, use MCP.
// Cannot commit or push code.
const strategist = ToolPermissions{
    .permission_mode = "dontAsk",
    .allowed_tools = &.{
        "Read",
        "Glob",
        "Grep",
        "Edit",
        "Write",
        "Bash(git log *)",
        "Bash(git diff *)",
        "Bash(git show *)",
        "Bash(git status *)",
        "Bash(cat *)",
        "Bash(ls *)",
        "Bash(bees *)",
        "Bash(wc *)",
        "mcp__*",
    },
    .disallowed_tools = &.{
        "Bash(git commit *)",
        "Bash(git push *)",
        "Bash(git merge *)",
        "Bash(sudo *)",
        "Bash(kill *)",
        "Bash(systemctl *)",
        "Bash(rm -rf *)",
    },
};

// ── User Agent ──────────────────────────────────────────────────────────
// Pure observation: read code, browse app via MCP.
// Cannot modify anything.
const user_agent = ToolPermissions{
    .permission_mode = "dontAsk",
    .allowed_tools = &.{
        "Read",
        "Glob",
        "Grep",
        "Bash(cat *)",
        "Bash(ls *)",
        "Bash(git log *)",
        "Bash(git status *)",
        "mcp__*",
    },
    .disallowed_tools = &.{
        "Edit",
        "Write",
        "Bash(git commit *)",
        "Bash(git push *)",
        "Bash(sudo *)",
        "Bash(rm *)",
    },
};

// ── Researcher ─────────────────────────────────────────────────────────
// Deep code analysis + web search for context. Can read everything,
// run tests to validate understanding, search the web for documentation
// and design patterns. Cannot modify code or push.
const researcher = ToolPermissions{
    .permission_mode = "dontAsk",
    .allowed_tools = &.{
        "Read",
        "Glob",
        "Grep",
        "Bash(git log *)",
        "Bash(git diff *)",
        "Bash(git show *)",
        "Bash(git status *)",
        "Bash(git blame *)",
        "Bash(git shortlog *)",
        "Bash(npm test *)",
        "Bash(npm run test *)",
        "Bash(zig build test *)",
        "Bash(cat *)",
        "Bash(ls *)",
        "Bash(wc *)",
        "Bash(find *)",
        "Bash(tree *)",
        "Bash(bees *)",
        "WebSearch",
        "WebFetch",
        "mcp__*",
    },
    .disallowed_tools = &.{
        "Edit",
        "Write",
        "Bash(git commit *)",
        "Bash(git push *)",
        "Bash(git merge *)",
        "Bash(sudo *)",
        "Bash(rm *)",
        "Bash(kill *)",
        "Bash(systemctl *)",
    },
};

// ── Readonly ────────────────────────────────────────────────────────────
// Strictest profile: read-only analysis, no execution.
const readonly = ToolPermissions{
    .permission_mode = "dontAsk",
    .allowed_tools = &.{
        "Read",
        "Glob",
        "Grep",
    },
    .disallowed_tools = &.{
        "Edit",
        "Write",
        "Bash",
    },
};

// ── Tests ───────────────────────────────────────────────────────────────

test "getProfile returns known profiles" {
    try std.testing.expect(getProfile("worker") != null);
    try std.testing.expect(getProfile("merger") != null);
    try std.testing.expect(getProfile("qa") != null);
    try std.testing.expect(getProfile("sre") != null);
    try std.testing.expect(getProfile("strategist") != null);
    try std.testing.expect(getProfile("user") != null);
    try std.testing.expect(getProfile("readonly") != null);
    try std.testing.expect(getProfile("nonexistent") == null);
}

test "getDefaultForSessionType maps all agent types" {
    try std.testing.expect(getDefaultForSessionType(.worker) != null);
    try std.testing.expect(getDefaultForSessionType(.merger) != null);
    try std.testing.expect(getDefaultForSessionType(.qa) != null);
    try std.testing.expect(getDefaultForSessionType(.sre) != null);
    try std.testing.expect(getDefaultForSessionType(.strategist) != null);
    try std.testing.expect(getDefaultForSessionType(.user) != null);
    try std.testing.expect(getDefaultForSessionType(.review) != null);
}

test "worker profile has no web access" {
    const w = getProfile("worker").?;
    for (w.disallowed_tools) |t| {
        if (std.mem.eql(u8, t, "WebSearch")) return; // found
    }
    return error.TestUnexpectedResult;
}

test "qa profile denies Edit" {
    const q = getProfile("qa").?;
    for (q.disallowed_tools) |t| {
        if (std.mem.eql(u8, t, "Edit")) return; // found
    }
    return error.TestUnexpectedResult;
}

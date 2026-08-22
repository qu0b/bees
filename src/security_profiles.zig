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
    // The review agent performs the merge itself when it approves (see
    // merger.reviewAndMerge) — a readonly review profile made every ACCEPT
    // silently record as "rejected" because `git merge` was denied.
    if (std.mem.eql(u8, name, "review")) return merger;
    if (std.mem.eql(u8, name, "founder")) return founder_profile;
    if (std.mem.eql(u8, name, "improver")) return improver_profile;
    if (std.mem.eql(u8, name, "readonly")) return readonly;
    return null;
}

/// Map session type to its default profile. Exhaustive on purpose: adding a
/// SessionType variant is a compile error here rather than a silent fall-through
/// to `--dangerously-skip-permissions`. conflict/fix operate on merges, so they
/// inherit the merger sandbox.
pub fn getDefaultForSessionType(session_type: types.SessionType) ?ToolPermissions {
    return switch (session_type) {
        .worker => worker,
        .merger => merger,
        .conflict, .fix => merger,
        .qa => qa,
        .sre => sre,
        .strategist => strategist,
        .user => user_agent,
        .researcher => researcher,
        .founder => founder_profile,
        .improver => improver_profile,
        .review => merger,
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
        // Read-only text tools, added 2026-08-22 after workers spent turns
        // being refused `sed`, `awk` and `which` while `cat`, `head`, `grep`
        // and `sort` were already allowed. They grant no capability the role
        // lacks — it already has Read/Edit/Write — and their absence only
        // taught agents to burn budget rediscovering the boundary.
        "Bash(sed *)",
        "Bash(awk *)",
        "Bash(which *)",
        "Bash(grep *)",
        "Bash(rg *)",
        "Bash(cut *)",
        "Bash(tr *)",
        "Bash(uniq *)",
        "Bash(basename *)",
        "Bash(dirname *)",
        "Bash(env)",
        "Bash(printf *)",
        "Bash(jq *)",
        // NOTE: `Bash(sh *)` deliberately omitted — it would let a worker run
        // `sh -c "curl … | sh"`, bypassing every disallow rule below. Project
        // build/setup commands are executed by the daemon itself, not the agent.
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
        // `Bash(sh *)` omitted — interpreter escape bypasses the disallow list.
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

// ── Founder ────────────────────────────────────────────────────────────
// Executive authority: read everything, write configs/roles/workflows,
// web search for market awareness. Can restructure the org.
// Cannot modify source code, commit, or manage processes.
const founder_profile = ToolPermissions{
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
        "Bash(mkdir *)",
        "Bash(bees *)",
        "Bash(wc *)",
        "WebSearch",
        "WebFetch",
        "mcp__*",
    },
    .disallowed_tools = &.{
        "Bash(git commit *)",
        "Bash(git push *)",
        "Bash(git merge *)",
        "Bash(sudo *)",
        "Bash(kill *)",
        "Bash(pkill *)",
        "Bash(systemctl *)",
        "Bash(rm -rf *)",
    },
};

// ── Improver ────────────────────────────────────────────────────────────
// Process leadership / recursive self-improvement. Reads the swarm's own
// output quality (git history, sessions via `bees`, reports) and refines the
// swarm's own instructions: roles/*/prompt.md and workflows/default.json.
// Can edit .bees/ files, but never commits/merges product code or manages
// processes — it improves how the swarm works, not the product directly.
const improver_profile = ToolPermissions{
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
        "Bash(git blame *)",
        "Bash(cat *)",
        "Bash(ls *)",
        "Bash(bees *)",
        "Bash(wc *)",
    },
    .disallowed_tools = &.{
        "Bash(git commit *)",
        "Bash(git push *)",
        "Bash(git merge *)",
        "Bash(sudo *)",
        "Bash(kill *)",
        "Bash(pkill *)",
        "Bash(systemctl *)",
        "Bash(rm -rf *)",
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
    try std.testing.expect(getDefaultForSessionType(.improver) != null);
    try std.testing.expect(getDefaultForSessionType(.founder) != null);
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

test "strategist grants the bare ORIENT commands its prompt uses" {
    // .bees/roles/strategist/prompt.md ORIENT step runs `git log …`, `bees status`,
    // `bees tasks`. Allow patterns match on the leading token, so `cd … && bees …`
    // or `git -C … log` would be denied silently. Guard both directions: the bare
    // forms stay granted, and nobody "fixes" a denial by widening the sandbox.
    const s = getProfile("strategist").?;
    var has_git_log = false;
    var has_bees = false;
    for (s.allowed_tools) |t| {
        if (std.mem.eql(u8, t, "Bash(git log *)")) has_git_log = true;
        if (std.mem.eql(u8, t, "Bash(bees *)")) has_bees = true;
        if (std.mem.eql(u8, t, "Bash(cd *)")) return error.TestUnexpectedResult;
        if (std.mem.eql(u8, t, "Bash(git -C *)")) return error.TestUnexpectedResult;
    }
    try std.testing.expect(has_git_log and has_bees);
}

test "no profile allows the sh interpreter escape" {
    // `Bash(sh *)` (or bash/zsh) in an allow list makes every disallow rule
    // advisory (`sh -c "curl … | sh"`), so no profile may grant it.
    const names = [_][]const u8{ "worker", "merger", "qa", "sre", "strategist", "user", "researcher", "founder", "improver", "review", "readonly" };
    const escapes = [_][]const u8{ "Bash(sh *)", "Bash(bash *)", "Bash(zsh *)" };
    for (names) |name| {
        const p = getProfile(name) orelse continue;
        for (p.allowed_tools) |t| {
            for (escapes) |e| {
                if (std.mem.eql(u8, t, e)) return error.TestUnexpectedResult;
            }
        }
    }
}

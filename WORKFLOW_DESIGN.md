# Declarative Workflow & Role System — Design Document

## Problem

The orchestration cycle is hardcoded in Zig: `workers → merger → QA → user → strategist`. Adding a new role requires modifying Zig source, recompiling, and updating the orchestrator's main loop. Data flow between agents is wired ad-hoc in each module. There's no way for users to customize the flow, add custom agents, or change execution order without touching compiled code.

## Solution

Two configuration layers:

### 1. `.bees/roles/{name}/` — Agent/Role Definitions

Each role is a directory containing:

```
.bees/roles/
  worker/
    config.yaml          # Agent configuration
    prompt.md            # System prompt (replaces .bees/prompts/worker.txt)
    skills/              # Agent-specific skills
      analyze-code.md
  strategist/
    config.yaml
    prompt.md
  qa/
    config.yaml
    prompt.md
  user/
    config.yaml
    prompt.md
  merger/
    config.yaml
    prompt.md
  sre/
    config.yaml
    prompt.md
  review/
    config.yaml
    prompt.md
```

#### `config.yaml` — Role Configuration

```yaml
# .bees/roles/strategist/config.yaml

model: opus
effort: high
max_budget_usd: 30
fallback_model: sonnet
max_turns: 50

# MCP servers available to this agent
mcp:
  - chrome-devtools    # Reference to .bees/mcp/{name}.json
  
# Tools the agent can use (null = all, [] = none)
# tools: null  # all tools (default)
# tools: [Bash, Read, Edit, Write, Grep, Glob]

# Data sources injected into the agent's prompt context
# These reference outputs from other roles or system sources
sources:
  - user_profiles      # .bees/prompts/users/*.txt
  - operator_feedback  # .bees/feedback.json
  - report:qa          # Last output from QA role
  - report:sre         # Last output from SRE role  
  - report:user        # Last output from User role
  - task_trends        # Computed from session history
  - asset:tasks        # The current tasks.json (generated asset)

# Assets this agent produces
# These become available as data sources for other agents
produces:
  - asset:tasks        # Writes .bees/tasks.json

# Whether this agent's result text is stored as report:{role_name}
stores_report: true    # Stores result as report:strategist in LMDB
```

#### `prompt.md` — Agent System Prompt

The system prompt for the agent. Replaces the current `.bees/prompts/{role}.txt` files. Supports markdown. Injected via `--append-system-prompt-file`.

### 2. `.bees/workflows/{name}.yaml` — Workflow Definitions

```yaml
# .bees/workflows/default.yaml

name: default
description: Standard continuous improvement cycle

# Steps execute in order. Each step has a role and optional config.
# Steps with the same `group` run in parallel.
steps:
  # Phase 1: Workers execute tasks in parallel
  - role: worker
    parallel: 3          # Run 3 instances simultaneously
    # Each instance gets a different task from the pool
    
  # Phase 2: Merge completed work  
  - role: merger
    trigger: workers_done  # Wait for merge_threshold workers to complete
    
  # Phase 3: Quality gates (run in parallel)
  - group: validation
    steps:
      - role: qa
      - role: user
  
  # Phase 4: SRE monitoring (conditional)
  - role: sre
    condition: tool_errors > threshold  # Only runs if workers had errors
    
  # Phase 5: Strategic planning
  - role: strategist
    every: 3              # Run every 3rd cycle (cycle_interval)

# Cycle behavior
cycle:
  cooldown_minutes: 5
  merge_threshold: 3
  worker_timeout_minutes: 60
```

#### Step Types

```yaml
# Simple sequential step
- role: worker

# Parallel instances
- role: worker
  parallel: 5

# Parallel group (different roles run simultaneously)
- group: quality_gates
  steps:
    - role: qa
    - role: user

# Conditional step
- role: sre
  condition: tool_errors > 3

# Periodic step (not every cycle)
- role: strategist
  every: 3

# Step that depends on a specific asset
- role: worker
  requires: [asset:tasks]  # Won't run if tasks.json is empty
```

## Data Flow Architecture

### Reports (LMDB meta)
Each role with `stores_report: true` writes its result_text to `report:{role_name}` in LMDB. Other roles can reference this via `sources: [report:qa]`.

### Assets (files)
Roles can produce and consume assets:
- `produces: [asset:tasks]` — the role writes `.bees/tasks.json`
- `sources: [asset:tasks]` — the asset content is injected into the prompt

### Worker Summary (computed)
A special computed source: `worker_summary` aggregates recent worker session results.

### Changed Files (computed)
`changed_files` is computed by the orchestrator from the git diff between pre-merge and post-merge HEAD.

### Last Message (implicit)
Any role's last result is available as `report:{role_name}`. The `sources` list in config.yaml controls which reports get injected.

## Validation at Startup

When the daemon loads, it:

1. **Parses all role configs** in `.bees/roles/*/config.yaml`
2. **Parses the active workflow** in `.bees/workflows/default.yaml`
3. **Validates references**:
   - Every role referenced in the workflow exists in `.bees/roles/`
   - Every `report:X` source references a role that has `stores_report: true`
   - Every `asset:X` source references a role that `produces` it
   - MCP server references exist
   - Prompt files exist
4. **Checks for cycles** in the dependency graph
5. **Reports errors** before starting any work

## Migration Path

### Phase 1: Roles (prompt + config consolidation)
- Move `.bees/prompts/*.txt` → `.bees/roles/*/prompt.md`
- Move role config from `config.json` sections → `.bees/roles/*/config.yaml`
- Context module reads from roles directory
- Orchestrator still hardcoded but reads role configs

### Phase 2: Workflows (flow definition)
- Parse `.bees/workflows/default.yaml`
- Replace hardcoded orchestrator loop with workflow executor
- Support parallel groups and conditions

### Phase 3: Dynamic roles
- Users can add custom roles via `.bees/roles/{custom}/`
- Custom roles participate in workflows
- Skills subfolder support

## File Structure Summary

```
.bees/
  config.json              # Project-level config (name, base_branch, build commands)
  feedback.json            # Operator feedback
  db/                      # LMDB database
  logs/                    # Log files
  roles/
    worker/
      config.yaml          # model, effort, budget, sources, produces
      prompt.md            # System prompt
      skills/              # Agent-specific skills
    strategist/
      config.yaml
      prompt.md
    qa/
      config.yaml
      prompt.md
    user/
      config.yaml
      prompt.md
    merger/
      config.yaml
      prompt.md
    review/
      config.yaml
      prompt.md
    sre/
      config.yaml
      prompt.md
  workflows/
    default.yaml           # The active workflow definition
  prompts/
    users/                 # Target user personas (kept here, referenced by roles)
```

## Open Questions

1. **YAML in Zig**: Zig has no YAML parser in stdlib. Options: (a) vendor a C YAML lib, (b) use JSON instead of YAML, (c) use a simple custom format. JSON loses readability for workflows. A minimal YAML subset parser (no anchors, no multiline blocks, just maps/lists/scalars) is feasible.

2. **Hot reload**: Should the daemon watch for config changes and reload? Or require restart? Current approach requires restart via systemd.

3. **Backward compatibility**: The current `.bees/config.json` + `.bees/prompts/` layout should still work as a fallback. The new system activates when `.bees/roles/` exists.

4. **`bees init` changes**: The init flow should generate the roles directory structure instead of (or in addition to) the flat prompts directory.

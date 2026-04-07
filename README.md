# bees

Autonomous multi-agent orchestration platform. Point it at a codebase, tell it who your users are, and it builds the software — continuously.

`bees init` analyzes your project and generates configuration. `bees daemon` runs a continuous loop: AI agents pick tasks, implement features in isolated worktrees, review and merge code, run tests, deploy, and decide what to build next. The human provides direction; bees does the rest.

## How it works

```
bees init              # Analyze codebase, generate .bees/ config
bees daemon            # Start the autonomous loop
```

The daemon runs a **workflow** — a declarative sequence of steps that defines the entire orchestration cycle:

1. **Workers** pick tasks from a weighted pool, implement them in isolated git worktrees, and commit
2. **Merger** reviews diffs, merges accepted work, runs build/test/deploy with AI-assisted fix on failure
3. **Strategist** (Opus-class model) evaluates progress, decides what to build next
4. **Researcher** investigates the codebase to build institutional knowledge
5. **SRE** monitors system health, adjusts task priorities, resolves operational issues
6. **QA** evaluates the project from each target user's perspective

All roles are configurable — model, effort level, budget cap, security profile, MCP plugins. Ship with sensible defaults, override anything.

## Architecture

- **Zig 0.16** — async I/O via io_uring green threads, < 512 KB steady-state memory
- **LMDB** — zero-copy mmap reads, bit-packed records (48B session headers, 4B event headers)
- **SQLite** — WAL-mode read replica synced from LMDB for queryable analytics
- **DuckDB** — runtime dlopen, ATTACHes SQLite for analytical queries
- **Multi-backend** — Claude CLI (primary), OpenAI Codex, OpenCode, Pi. Configurable per-role
- **Knowledge base** — persistent institutional memory that agents read before acting and write back what they learn

Data model uses packed structs with comptime size assertions, integer microdollars for costs, u40 unix timestamps, sentinel values over optionals. Zero-copy everywhere.

## Install

### From release binary (Linux x86_64)

```sh
curl -fsSL https://raw.githubusercontent.com/qu0b/bees/main/install.sh | sh
```

Or download manually from [Releases](https://github.com/qu0b/bees/releases).

### From source

Requires [Zig 0.16.x](https://ziglang.org/download/).

```sh
git clone https://github.com/qu0b/bees.git
cd bees
zig build
# Binary at zig-out/bin/bees

# Or install to ~/.bees/bin:
make install
```

## Quick start

```sh
# Initialize in your project directory
cd your-project
bees init

# Edit .bees/config.json to set:
#   - AI backend and model per role
#   - Build/test/deploy commands
#   - Worker count, merge threshold, cooldown
#   - Target user profiles

# Run the daemon
bees daemon

# Or install as a systemd service
bees start
```

## CLI

```
bees init [--skip-analysis]     Initialize bees in current project
bees daemon                     Run continuous orchestrator
bees start                      Install and enable systemd service
bees stop                       Disable systemd service
bees status [--json]            Show project status
bees run <role> [--id N]        Run a single role (worker, merger, strategist, sre, qa, researcher)
bees log [--follow]             Show log
bees config [--json]            Show config
bees tasks [--json]             List tasks
bees sessions [--type X]        List sessions
bees session <id> [--json]      Show session detail
bees knowledge                  List knowledge base entries
bees sync                       Sync LMDB to SQLite replica
bees version                    Print version
```

## Configuration

All config lives in `.bees/` at your project root:

```
.bees/
  config.json           # Main config (workers, backends, build commands, workflow)
  tasks.json            # Task pool with weights and descriptions
  roles/                # Per-role config and prompts
    worker/
      config.json       # Model, effort, budget, security profile
      prompt.md         # Role prompt template
    merger/
    strategist/
    ...
  knowledge/            # Institutional memory (auto-managed)
```

Roles declare which context sources they need (user profiles, task trends, knowledge tags, recent changes). The context module assembles everything into the agent prompt at runtime.

## Knowledge base

The swarm accumulates institutional knowledge as it works — not documentation, but ground truths: architecture decisions, component relationships, failed approaches, design rationale. Agents read this knowledge before acting and write back what they learn. Over time, the swarm develops deep understanding of the project it's building.

Knowledge is organized by category (architecture, components, contracts, decisions, operations) with a compact JSON index in LMDB. Any role can read/write knowledge — it's just another context source.

## Requirements

- Linux (x86_64)
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) or other supported AI backend
- Git

## License

MIT

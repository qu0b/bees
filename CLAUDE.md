# Bees - Autonomous Multi-Agent Code Improvement System

## Project Overview

Bees is a generic, project-agnostic orchestration system that runs multiple autonomous AI coding agents (workers) in parallel against a shared codebase. A separate merger agent reviews changes, resolves conflicts, builds, tests, and deploys. The system runs continuously via systemd timers with no human intervention.

## Technology Decisions

### Language: Zig (0.16.x preview — new async I/O)

- Using Zig 0.16.0-dev.2682+02142a54d (installed at /opt/zig, symlinked to /usr/local/bin/zig)
- Target Zig 1.0 when it lands (expected 2026)
- LMDB via vendored C source (`@cImport("lmdb.h")`) — zero-copy reads via mmap
- Config via `std.json` (stdlib, zero dependencies)
- No third-party Zig package dependencies in MVP

### AI Agent Transport: Claude CLI

- All invocations use `--dangerously-skip-permissions` for full autonomy
- Model is configurable per-role: strategist defaults to Opus, workers/merger/SRE default to Sonnet
- All invocations use `--effort high`
- Budget cap: `--max-budget-usd 30` per session
- Workers: `-p --output-format stream-json` for headless execution with full event capture
- Reviews: `-p --output-format json` for simple verdict output
- Conflict resolution: `-p` with tool access in worktree

### Data & Config

- Per-project config at `<project>/.bees/config.json` + `<project>/.bees/approaches.json`
- `bees` auto-detects project by walking up from CWD looking for `.bees/config.json`
- `--config <path>` overrides auto-detection
- `bees init` uses Claude to analyze the project and generate config
- Database: LMDB at `<project>/.bees/db/` — 7 sub-databases with bit-packed records
- All Claude CLI stream-json events stored with 4-byte packed headers + raw JSON in LMDB
- Prompt templates: external files in `<project>/.bees/prompts/`

### Scheduling & Interface

- systemd user timers (`systemctl --user`) for worker and merger scheduling
- CLI only for v1
- TUI deferred to v2
- Web application for session replay and analytics deferred
- Screenshots/visual verification deferred

## Architecture

- **Workers** (N instances): Spawn in isolated git worktrees, investigate codebase, commit fixes
- **Merger** (1 instance): Reviews diffs via AI, merges, resolves conflicts, builds, tests, deploys
- Coordination via filesystem markers + LMDB as source of truth
- All sessions (worker, review, conflict, fix) captured with full event streams

## Memory Model & Data Structure Rules

### Zero-Copy Rules
- Strings are slices (`[]const u8`) pointing into owned buffers. Never duplicate unless crossing an ownership boundary.
- All finite value sets (event types, tool names, statuses, verdicts) are integer enums. No string storage, no string comparisons.
- The NDJSON stream parser reuses a single dynamically-sized line buffer (1MB initial). No per-line allocation — only grows when a line exceeds current capacity.
- Config/approach strings are slices into the JSON file buffer (owned by global arena). No per-field copies.
- Git command output is parsed via slices into the stdout buffer. No copies unless data must outlive the buffer.

### Bit Packing Rules
- All enums use minimum bit widths: SessionType(u3), SessionStatus(u3), EventType(u3), ToolName(u4), Verdict(u1), Role(u2), Model(u2).
- On-disk records use `packed struct` with comptime size assertions. SessionHeader: 32 bytes. EventHeader: 4 bytes. ReviewHeader: 8 bytes. ApproachRecord: 16 bytes.
- Monetary values stored as integer microdollars or centidollars. Never f64.
- Timestamps stored as u48 (unix seconds, good until year ~10889). Never ISO strings.
- Token counts stored as u16 in thousands. Commit counts as u8.
- Sentinels (0, 0xFF) instead of `?T` optionals for numeric fields — avoids tag byte + alignment padding.
- `has_*` bit flags in packed headers indicate which sentinel values are meaningful.
- Field ordering in non-packed structs: largest alignment first to minimize padding.

### Allocator Scopes
- **Global arena** — config, approaches, prompt templates. Lives for program lifetime.
- **Per-session arena** — branch names, worktree paths. Freed when session completes.
- **Per-session line buffer** — NDJSON line parsing (1MB initial, dynamically grows for large tool results). Reused across lines, freed with session arena.
- **Stack buffers** — lockfile paths, PID formatting, small formatting. No heap.
- **LMDB read transaction** — CLI commands open read txn, access zero-copy pointers into mmap, close txn.

### LMDB Rules
- 7 sub-databases: sessions, sessions_by_status, sessions_by_time, events, reviews, approaches, meta.
- All keys are fixed-size, big-endian for correct lexicographic ordering.
- Values are packed struct headers + length-prefixed variable strings.
- Use `reserve()` for zero-copy writes (write directly into LMDB page).
- Secondary indexes maintained atomically in the same write transaction as primary records.
- Map size: 1 GB default (virtual address reservation, not physical allocation).
- Diffs NOT stored — derive from git on demand.

### Target Memory Budget
- Steady-state: < 512 KB for the orchestrator process (excluding OS mmap pages and Claude CLI children).
- EventMeta: 8 bytes (single register). SessionHeader: 32 bytes. EventHeader: 4 bytes.
- See DATA_STRUCTURES.md for full breakdown.

## Key Constraints

- Workers must NEVER deploy — only the merger deploys
- Strategist uses Opus; workers, merger, SRE use Sonnet by default (configurable per-role)
- Always high effort, always $30 budget cap
- Generic tool: build/test/deploy commands are configurable per-project in config.json
- Worktrees managed by bees (not Claude CLI's --worktree flag) for full control over naming, state, and cleanup

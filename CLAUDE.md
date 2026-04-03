# Bees - Autonomous Multi-Agent Code Improvement System

## Project Overview

Bees is a generic, project-agnostic orchestration system that runs multiple autonomous AI coding agents (workers) in parallel against a shared codebase. A separate merger agent reviews changes, resolves conflicts, builds, tests, and deploys. The system runs continuously via systemd timers with no human intervention.

## Technology Decisions

### Language: Zig (0.16.x preview — new async I/O)

- Using Zig 0.16.0-dev.2682+02142a54d (installed at /opt/zig, symlinked to /usr/local/bin/zig)
- Target Zig 1.0 when it lands (expected 2026)
- LMDB via vendored C source (`@cImport("lmdb.h")`) — zero-copy reads via mmap
- SQLite via vendored amalgamation (`vendor/sqlite/sqlite3.c`) — queryable read replica
- DuckDB via runtime `dlopen("libduckdb.so")` — analytical queries, optional dependency
- Config via `std.json` (stdlib, zero dependencies)

### AI Agent Transport: Claude CLI

- All invocations use `--dangerously-skip-permissions` for full autonomy
- Model is configurable per-role: strategist defaults to Opus, workers/merger/SRE default to Sonnet. QA defaults to Opus with medium effort. Model and effort configurable per-role.
- All invocations use `--effort high` (unless overridden per-role)
- Budget cap: `--max-budget-usd 30` per session
- Workers: `-p --output-format stream-json` for headless execution with full event capture
- Conflict resolution: `-p` with tool access in worktree

### Data & Config

- Per-project config at `<project>/.bees/config.json` + `<project>/.bees/tasks.json`
- `bees` auto-detects project by walking up from CWD looking for `.bees/config.json`
- `--config <path>` overrides auto-detection
- `bees init` uses Claude to analyze the project and generate config
- Dead letter queue at `<project>/.bees/db/dead-letters.bin` for failed LMDB writes
- Prompt templates: external files in `<project>/.bees/prompts/` — loaded at runtime, editable without recompiling

### Database: LMDB + SQLite + DuckDB

Three embedded databases — KV, relational, and OLAP. Use whichever fits the access pattern:

- **LMDB** (KV) — `<project>/.bees/db/data.mdb`. Fast key-value access, zero-copy mmap reads, bit-packed records.
- **SQLite** (relational) — `<project>/.bees/db/data.sqlite`. SQL queries, joins, WAL concurrent reads.
- **DuckDB** (OLAP) — `<project>/.bees/db/data.duckdb`. Columnar compression, aggregations, window functions. Runtime-loaded via `libduckdb.so`. Can ATTACH SQLite files directly.

Schema is defined once in `src/db/schema.zig` (comptime) and generates DDL + bind functions for all databases.

**Key files:** `src/store.zig` (LMDB), `src/db/sqlite.zig`, `src/db/duckdb.zig`, `src/db/schema.zig`, `src/db/sync.zig`

### Scheduling & Interface

- Continuous daemon mode (`bees daemon`) with configurable cooldown between cycles
- CLI only for v1
- TUI deferred to v2
- REST API server (configurable port, default 3002) for dashboard integration
- Web dashboard at bees-dashboard (Next.js, dark theme, real-time monitoring)

## Architecture

- **Workers** (N instances): Spawn in isolated git worktrees, implement tasks, commit fixes
- **Merger** (1 instance): Reviews diffs via AI, merges, resolves conflicts, builds, tests, deploys
- **SRE agent**: Monitors system health, adjusts task weights, cleans up resources
- **Strategist**: Product visionary — maintains evolving VISION, writes ambitious tasks to tasks.json, uses Chrome MCP for visual review
- **QA agent**: Diff-aware visual/functional verification after every merge cycle
- Coordination via trifecta database architecture (LMDB, SQLite, DuckDB — see Data & Config)
- All sessions and events captured and queryable across the database tier
- REST API server for dashboard integration

## Memory Model & Data Structure Rules

### Zero-Copy Rules
- Strings are slices (`[]const u8`) pointing into owned buffers. Never duplicate unless crossing an ownership boundary.
- All finite value sets (event types, tool names, statuses, verdicts) are integer enums. No string storage, no string comparisons.
- The NDJSON stream parser reuses a single dynamically-sized line buffer (1MB initial). No per-line allocation — only grows when a line exceeds current capacity.
- Config/task strings are slices into the JSON file buffer (owned by global arena). No per-field copies.
- Git command output is parsed via slices into the stdout buffer. No copies unless data must outlive the buffer.

### Bit Packing Rules
- All enums use minimum bit widths: SessionType(u3), SessionStatus(u3), EventType(u3), ToolName(u4), Verdict(u1), Role(u2), Model(u2).
- SessionType(u3) has 8 values: worker=0, merger=1, review=2, conflict=3, fix=4, sre=5, strategist=6, qa=7.
- On-disk records use `packed struct` with comptime size assertions. SessionHeader: 48 bytes. EventHeader: 4 bytes. ReviewHeader: 8 bytes. TaskHeader: 24 bytes.
- Monetary values stored as integer microdollars or centidollars. Never f64.
- Timestamps stored as u48 (unix seconds, good until year ~10889). Never ISO strings.
- Token counts stored as u16 in thousands. Commit counts as u8.
- Sentinels (0, 0xFF) instead of `?T` optionals for numeric fields — avoids tag byte + alignment padding.
- `has_*` bit flags in packed headers indicate which sentinel values are meaningful.
- Field ordering in non-packed structs: largest alignment first to minimize padding.

### Allocator Scopes
- **Global arena** — config, tasks, prompt templates. Lives for program lifetime.
- **Per-session arena** — branch names, worktree paths. Freed when session completes.
- **Per-session line buffer** — NDJSON line parsing (1MB initial, dynamically grows for large tool results). Reused across lines, freed with session arena.
- **Stack buffers** — lockfile paths, PID formatting, small formatting. No heap.
- **LMDB read transaction** — CLI commands open read txn, access zero-copy pointers into mmap, close txn.

### LMDB Rules
- **Directory mode (no `MDB_NOSUBDIR`)**: LMDB is opened with the directory path, NOT a file path. The data file is `data.mdb` and the lock file is `lock.mdb`, both inside the db directory. Any external consumer (e.g. node-lmdb, lmdb-js, Python lmdb) MUST open the same directory — never open `data.mdb` directly with `MDB_NOSUBDIR`, as this creates a separate lock file (`data.mdb-lock`) and concurrent access through different lock files silently corrupts the database.
- Sub-database short names: `s` (sessions), `ss` (sessions_by_status), `st` (sessions_by_time), `e` (events), `r` (reviews), `a` (tasks), `m` (meta).
- 7 sub-databases: sessions, sessions_by_status, sessions_by_time, events, reviews, tasks, meta.
- All keys are fixed-size, big-endian for correct lexicographic ordering.
- Values are packed struct headers + length-prefixed variable strings.
- Use `reserve()` for zero-copy writes (write directly into LMDB page).
- Secondary indexes maintained atomically in the same write transaction as primary records.
- Map size: 1 GB default (virtual address reservation, not physical allocation).
- Diffs NOT stored — derive from git on demand.
- Event writes are non-fatal — failed writes go to dead letter queue, auto-drained on next session.
- Reports stored in meta sub-database for quick access; full history in session events.

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
- QA agent runs after every merge cycle (not periodic like strategist)
- Strategist receives QA report and task trends derived from the database tier
- No reports written to disk — derived on demand via queries

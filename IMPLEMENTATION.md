# Bees — Implementation Plan

## Dependencies

| Dependency | Purpose | Strategy |
|------------|---------|----------|
| Zig 0.16.0-dev.2682 | Language + build system | Installed at /opt/zig |
| LMDB | Database (C library) | Vendored source (lmdb.h, mdb.c, midl.h, midl.c) |
| std.json | Config parsing | Zig stdlib (zero dependency) |

No third-party Zig package dependencies. Only vendored C code (LMDB) and Zig stdlib.

## Claude CLI Stream-JSON Format

All Claude CLI sessions emit NDJSON (newline-delimited JSON). Each line is one of these event types:

```jsonl
{"type":"init","session_id":"abc-123","timestamp":"2026-03-07T14:00:01Z"}

{"type":"message","role":"assistant","content":[{"type":"text","text":"I'll investigate..."}]}

{"type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_xxx","name":"Read","input":{"file_path":"/src/main.zig"}}]}

{"type":"tool_result","id":"toolu_xxx","output":"file contents here..."}

{"type":"result","subtype":"success","total_cost_usd":2.34,"duration_ms":45000,"duration_api_ms":32000,"num_turns":12,"result":"I fixed the bug...","session_id":"abc-123"}
```

The `result` event is always the final event and contains cost, duration, and turn count. This is the source of truth for session cost tracking.

## Claude CLI Invocation (All Sessions)

```bash
claude \
  -p \
  --dangerously-skip-permissions \
  --model opus \
  --effort high \
  --max-budget-usd 30 \
  --output-format stream-json \
  --no-session-persistence \
  [session-specific flags] \
  "prompt text"
```

### Session-specific flags

| Session Type | Extra Flags |
|--------------|-------------|
| Worker | `--append-system-prompt-file <project>/.bees/prompts/worker.txt` run from worktree dir |
| Review | `--system-prompt-file <project>/.bees/prompts/review.txt` diff piped via stdin |
| Conflict | `--append-system-prompt-file <project>/.bees/prompts/conflict.txt` run from worktree dir |
| Fix | `--append-system-prompt-file <project>/.bees/prompts/fix.txt` run from worktree dir |
| SRE | `--append-system-prompt-file sre.txt`, main prompt loaded from `sre-main.txt` |
| Strategist | Main prompt loaded from `strategist.txt`, `--mcp-config mcp-chrome.json` |
| QA | Main prompt loaded from `qa.txt`, `--mcp-config mcp-chrome.json` |

### Future Transport: Agent SDK

The Claude Agent SDK (Python/TypeScript) provides the same capabilities as the CLI programmatically. This could replace the CLI as transport in a future version, removing the process-spawning layer entirely. For v1, the CLI is simpler and requires no additional runtime.

---

## Phase 1: Project Scaffold

**Goal:** Zig project compiles, dependencies resolve, binary runs and prints version.

### Commit 1.1: Initialize Zig project

- `zig init` to create `build.zig` and `build.zig.zon`
- Set project name to `bees`
- Set minimum Zig version to 0.16.0
- Create `src/main.zig` with a minimal main that prints `bees v0.1.0`

### Commit 1.2: Vendor LMDB and configure build

- Create `vendor/lmdb/` directory
- Download LMDB source files: `lmdb.h`, `mdb.c`, `midl.h`, `midl.c` from github.com/LMDB/lmdb
- Configure `build.zig` to compile `mdb.c` and `midl.c` as a C static library
- Set up `@cImport("lmdb.h")` include path
- Verify `zig build` compiles the C source successfully

### Commit 1.3: Source file skeleton

Create empty source files with placeholder public functions to establish the module structure:

```
src/
├── main.zig          # Entry point, CLI dispatch
├── cli.zig           # Argument parsing
├── config.zig        # JSON config loading
├── store.zig         # LMDB operations (environment, sub-databases, CRUD)
├── types.zig         # All packed structs, enums, key/value formats
├── worker.zig        # Worker lifecycle
├── merger.zig        # Merger pipeline
├── claude.zig        # Claude CLI process management + stream parsing
├── git.zig           # Git/worktree operations
├── scheduler.zig     # systemd unit generation
├── tasks.zig         # Weighted random selection + LMDB sync
├── log.zig           # Central logging
├── orchestrator.zig  # Daemon main loop (workers, merger, QA, strategist, SRE)
├── strategist.zig    # Strategist agent (loads external prompt)
├── sre.zig           # SRE agent (loads external prompt)
├── qa.zig            # QA agent (diff-aware, Chrome MCP)
├── dlq.zig           # Dead letter queue for failed LMDB writes
├── api.zig           # REST API server for dashboard
└── fs.zig            # Global Io wrapper module
```

Add `@import` for each module in `main.zig` to verify compilation. Add comptime size assertions for all packed structs in `types.zig`.

### Commit 1.4: Example config files

```
config.example.json
tasks.example.json
prompts/
├── worker.txt
├── review.txt
├── conflict.txt
└── fix.txt
```

These are reference files only — not compiled into the binary.

---

## Phase 2: Configuration

**Goal:** `bees init` creates `<project>/.bees/` with config files. Config loads and validates from JSON. Project auto-detection works.

### Commit 2.1: Config struct definitions

Define Zig structs that mirror the JSON schema. All string fields are slices into the JSON file buffer (zero-copy). See DATA_STRUCTURES.md `Config` section for full struct definitions.

Key types:
```zig
const Config = struct {
    project: struct { name: []const u8, base_branch: []const u8 = "main" },
    workers: struct { count: u32 = 5, model: []const u8 = "opus", effort: []const u8 = "high", max_budget_usd: f64 = 30.0, schedule: []const u8 = "0 * * * *" },
    merger: struct { model: []const u8 = "opus", effort: []const u8 = "high", max_budget_usd: f64 = 30.0, schedule: []const u8 = "45 * * * *", max_conflict_files: u32 = 5 },
    sre: struct { ... },
    strategist: struct { ... },
    qa: struct { ... },
    api: struct { ... },
    daemon: struct { ... },
    git: struct { shallow_worktrees: bool = true },
    build: struct { command: ?[]const u8 = null, test_command: ?[]const u8 = null, deploy_command: ?[]const u8 = null },
    serve: struct { ... },
    smoke_test: struct { enabled: bool = false, urls: []const []const u8 = &.{}, port: u16 = 8080, startup_wait_secs: u32 = 10 },
    timeouts: struct { max_idle_secs: u32 = 600, stale_hours: u32 = 24, cleanup_hours: u32 = 72 },
};
```

Note: `project.path` is no longer in config — it's derived from `.bees/config.json` location (the parent directory).

### Commit 2.2: Project detection and JSON parsing

- **Project detection:** Walk up from CWD looking for `.bees/config.json`. The directory containing `.bees/` is the project root.
- `--config <path>` flag overrides auto-detection.
- Read JSON file into global arena (single allocation for entire file)
- Use `std.json.parseFromSlice` to parse into Config struct — string fields reference the file buffer (zero-copy)
- Struct defaults mean a minimal config only needs `{ "project": { "name": "my-project" } }`
- Validate at load time: project root must be a git repo, build commands (if set) must be non-empty strings
- Return clear error messages for missing/invalid fields

### Commit 2.3: Task loading

```zig
const Task = struct {
    name: []const u8,     // Slice into JSON buffer
    weight: u32,
    prompt: []const u8,   // Slice into JSON buffer (inline)
    cumulative: u32,      // Precomputed at load time
};
```

Parse `<project>/.bees/tasks.json` into `[]Task`. Validate weights > 0. Precompute cumulative weights for O(log n) binary search selection.

### Commit 2.4: `bees init` command

Claude-powered project setup:
1. Verify CWD is a git repo root
2. Creates `<project>/.bees/` directory structure: `db/`, `logs/`, `prompts/`, `worktrees/`
3. Spawn Claude with `-p` to analyze the project:
   - Reads build files (Makefile, package.json, Cargo.toml, build.zig, etc.)
   - Identifies build, test, and deploy commands
   - Suggests a project name
   - Generates `config.json` with appropriate settings
4. Writes Claude's output to `<project>/.bees/config.json`
5. Copies default `tasks.json` → `<project>/.bees/tasks.json`
6. Copies prompt templates → `<project>/.bees/prompts/`
7. Adds `.bees/` to `.gitignore` if not already present

---

## Phase 3: Database (LMDB)

**Goal:** LMDB environment initializes with sub-databases. CRUD operations work for all record types with bit-packed headers.

### Commit 3.1: Type definitions (types.zig)

All packed structs, enums, and key formats. Every struct has a comptime size assertion.

```zig
// Enums — minimum bit widths
const SessionType = enum(u3) { worker, merger, review, conflict, fix };
const SessionStatus = enum(u3) { running, done, merged, rejected, conflict_status, build_failed, err };
const EventType = enum(u3) { init, message, tool_use, tool_result, result };
const ToolName = enum(u4) { none, bash, read, edit, write, glob, grep, web_search, web_fetch, agent, ask_user, notebook_edit, mcp_tool = 14, unknown = 15 };
const Verdict = enum(u1) { accept, reject };
const Role = enum(u2) { none, assistant, user };
const Model = enum(u2) { opus, sonnet, haiku };

// Keys — fixed-size, big-endian for lexicographic ordering
const SessionKey = packed struct(u64) { id: u64 };
const EventKey = struct { session_id: u64, seq: u32 };       // 12 bytes
const StatusIndexKey = struct { status: u8, started_at: [5]u8, session_id: [3]u8 }; // 9 bytes
const TimeIndexKey = struct { started_at: [5]u8, session_id: [3]u8, type_byte: u8 }; // 9 bytes

// Value headers — bit-packed
const SessionHeader = packed struct(u256) { ... };             // 32 bytes exact
const EventHeader = packed struct(u32) { ... };                // 4 bytes exact
const ReviewHeader = packed struct(u64) { ... };               // 8 bytes exact
const TaskRecord = packed struct(u128) { ... };                // 16 bytes exact
```

All key types have `toBytes() → [N]u8` and `fromBytes(*const [N]u8) → Self` methods. Big-endian encoding for correct LMDB ordering.

All value headers have `toBytes() → [@sizeOf(Self)]u8` via `@bitCast` and matching `fromPtr(*const [@sizeOf(Self)]u8) → *const Self` for zero-copy reads from mmap.

### Commit 3.2: LMDB environment and sub-database setup (store.zig)

```zig
const Store = struct {
    env: lmdb.Environment,

    // 7 sub-databases
    sessions: lmdb.Database,          // session_id → SessionRecord
    sessions_by_status: lmdb.Database, // StatusIndexKey → void
    sessions_by_time: lmdb.Database,   // TimeIndexKey → void
    events: lmdb.Database,             // EventKey → EventRecord
    reviews: lmdb.Database,            // worker_session_id → ReviewRecord
    tasks: lmdb.Database,              // task_name → TaskRecord
    meta: lmdb.Database,               // string keys → various

    pub fn open(path: []const u8) !Store { ... }
    pub fn close(self: *Store) void { ... }
};
```

Open environment with:
- `map_size = 1 GB` (virtual address reservation, not physical)
- `max_dbs = 8`
- `max_readers = 8`

Create all sub-databases in a single write transaction on first run. Store schema version in `meta` db under key `"v"`.

### Commit 3.3: Session CRUD

All operations use explicit read/write transactions. Write operations atomically update both the primary record and all secondary indexes.

```zig
// Write path: single write txn updates primary + indexes atomically
pub fn createSession(self: *Store, header: SessionHeader, task: []const u8, branch: []const u8, worktree: []const u8) !u64 {
    var txn = try lmdb.Transaction.init(self.env, .{ .mode = .read_write });
    errdefer txn.abort();

    // Allocate session_id from meta counter
    const id = try self.nextSessionId(txn);

    // Write primary: sessions[id] = header + variable strings
    const key = SessionKey{ .id = id };
    const value = try self.packSessionValue(txn, header, task, branch, worktree);
    try txn.set(self.sessions, &key.toBytes(), value);

    // Write index: sessions_by_status[(status, started_at, id)] = void
    const status_key = StatusIndexKey.init(header.status(), header.started_at, id);
    try txn.set(self.sessions_by_status, std.mem.asBytes(&status_key), "");

    // Write index: sessions_by_time[(started_at, id, type)] = void
    const time_key = TimeIndexKey.init(header.started_at, id, header.type());
    try txn.set(self.sessions_by_time, std.mem.asBytes(&time_key), "");

    try txn.commit();
    return id;
}

// Read path: zero-copy via mmap
pub fn getSession(self: *Store, txn: lmdb.Transaction, id: u64) !?SessionView {
    const key = SessionKey{ .id = id };
    const value = txn.get(self.sessions, &key.toBytes()) catch return null;
    // value points directly into mmap. Zero-copy.
    return SessionView.fromBytes(value);
}

// SessionView: provides typed access to mmap'd bytes without copying
const SessionView = struct {
    header: *const SessionHeader,   // Points into mmap
    task: []const u8,               // Slice into mmap
    branch: []const u8,             // Slice into mmap
    worktree: []const u8,           // Slice into mmap
    diff_summary: []const u8,       // Slice into mmap

    pub fn fromBytes(value: []const u8) SessionView {
        const header: *const SessionHeader = @ptrCast(@alignCast(value.ptr));
        var offset: usize = @sizeOf(SessionHeader);
        // Read length-prefixed variable strings
        const task = readLenPrefixed(value, &offset);
        const branch = readLenPrefixed(value, &offset);
        const worktree = readLenPrefixed(value, &offset);
        const diff_summary = if (header.has_diff_summary) readLenPrefixed(value, &offset) else "";
        return .{ .header = header, .task = task, .branch = branch, .worktree = worktree, .diff_summary = diff_summary };
    }
};
```

Additional session functions:
- `updateSessionStatus(id, new_status)` — update primary + re-key status index (delete old, insert new)
- `finishSession(id, result_data)` — update header fields (cost, duration, tokens, status, finished_at)
- `listSessionsByTime(txn, limit) → iterator` — reverse cursor scan on `sessions_by_time`
- `getSessionsByStatus(txn, status) → iterator` — cursor range scan on `sessions_by_status`
- `getRunningWorkers(txn) → bounded array` — `getSessionsByStatus(txn, .running)` filtered to type=worker

### Commit 3.4: Event CRUD

```zig
// Write: uses reserve() for zero-copy write into LMDB page
pub fn insertEvent(self: *Store, session_id: u64, seq: u32, header: EventHeader, raw_json: []const u8) !void {
    var txn = try lmdb.Transaction.init(self.env, .{ .mode = .read_write });
    errdefer txn.abort();

    const key = EventKey{ .session_id = session_id, .seq = seq };
    const key_bytes = key.toBytes();
    const value_len = @sizeOf(EventHeader) + raw_json.len;

    // Reserve space in LMDB page — write directly, no intermediate buffer
    const reserved = try txn.reserve(self.events, &key_bytes, value_len);
    @memcpy(reserved[0..@sizeOf(EventHeader)], std.mem.asBytes(&header));
    @memcpy(reserved[@sizeOf(EventHeader)..], raw_json);

    try txn.commit();
}

// Read: zero-copy iteration over session events
pub fn iterSessionEvents(self: *Store, txn: lmdb.Transaction, session_id: u64) !EventIterator {
    var cursor = try txn.cursor(self.events);
    // Seek to first event for this session
    const start_key = EventKey{ .session_id = session_id, .seq = 0 };
    try cursor.seek(&start_key.toBytes());
    return EventIterator{ .cursor = cursor, .session_id = session_id };
}

const EventIterator = struct {
    cursor: lmdb.Cursor,
    session_id: u64,

    /// Returns next event. Header and JSON point into mmap (zero-copy).
    pub fn next(self: *EventIterator) ?EventView {
        const entry = self.cursor.next() orelse return null;
        const key = EventKey.fromBytes(entry.key);
        if (key.session_id != self.session_id) return null; // Past this session
        return EventView{
            .seq = key.seq,
            .header = @ptrCast(@alignCast(entry.value.ptr)),
            .raw_json = entry.value[@sizeOf(EventHeader)..],
        };
    }
};

const EventView = struct {
    seq: u32,
    header: *const EventHeader,  // Points into mmap
    raw_json: []const u8,        // Points into mmap
};
```

### Commit 3.5: Review and task CRUD

Reviews:
```zig
// Key: worker_session_id (u64). Value: ReviewHeader + reason text.
pub fn insertReview(self: *Store, worker_session_id: u64, header: ReviewHeader, reason: []const u8) !void
pub fn getReview(self: *Store, txn: lmdb.Transaction, worker_session_id: u64) !?ReviewView
```

Tasks:
```zig
// Key: task name (variable string). Value: TaskRecord (16 bytes fixed).
pub fn upsertTask(self: *Store, name: []const u8, record: TaskRecord) !void
pub fn getTask(self: *Store, txn: lmdb.Transaction, name: []const u8) !?*const TaskRecord
pub fn incrementTaskStat(self: *Store, name: []const u8, field: enum { total_runs, accepted, rejected, empty }) !void
```

Meta:
```zig
// Key: string. Value: u64.
pub fn nextSessionId(self: *Store, txn: lmdb.Transaction) !u64  // Atomic increment of "next_id"
pub fn getSchemaVersion(self: *Store, txn: lmdb.Transaction) !u32
```

### Commit 3.6: Daily stats aggregation

```zig
/// Compute daily stats by scanning sessions_by_time index.
/// No stored aggregates — compute on the fly. Fast because:
/// - Index is ordered by time, so we seek directly to today's start
/// - Each entry is 9 bytes (key only, value is empty)
/// - Typically < 200 sessions/day, scans in microseconds
pub fn getDailyStats(self: *Store, txn: lmdb.Transaction, day_start: u48) !DailyStats {
    var stats = DailyStats{};
    var cursor = try txn.cursor(self.sessions_by_time);
    const start = TimeIndexKey.init(day_start, 0, 0);
    try cursor.seek(std.mem.asBytes(&start));

    while (cursor.next()) |entry| {
        const time_key = TimeIndexKey.fromBytes(entry.key);
        if (time_key.started_at() < day_start) break; // Past today (reverse scan) — actually we scan forward

        // Look up the session's current status
        const session = try self.getSession(txn, time_key.sessionId()) orelse continue;
        switch (session.header.status()) {
            .merged => stats.accepted += 1,
            .rejected => stats.rejected += 1,
            .conflict_status => stats.conflicts += 1,
            .build_failed => stats.build_failures += 1,
            else => {},
        }
        stats.total_cost_cents += session.header.cost_microdollars / 10000; // micro → centi
    }
    return stats;
}
```

---

## Phase 4: Git Operations

**Goal:** Create, list, merge, and clean up worktrees. Extract diffs. Detect and list conflicts.

Worktrees live in `/tmp/bees-{project_name}/worktrees/` to avoid triggering IDE watchers or build systems in the main project. All git operations use `config.project.base_branch` (default: `"main"`) instead of hardcoded branch names.

### Commit 4.1: Core git command runner

```zig
/// Run git command. stdout allocated into provided arena. Single allocation.
pub fn run(arena: std.mem.Allocator, args: []const []const u8, cwd: []const u8) !GitResult
```

- Captures stdout and stderr
- Returns structured error on non-zero exit
- All parsing functions operate on zero-copy slices into the stdout buffer

### Commit 4.2: Worktree management

Functions:
- `createWorktree(repo_path, branch_name, worktree_dir, base_branch, shallow)` — `git worktree add -b {branch} {dir} {base_branch}` (with `--depth 1` if `shallow` and git supports it)
- `removeWorktree(repo_path, worktree_dir)` — `git worktree remove --force {dir}`
- `listWorktrees(repo_path, arena) → []WorktreeInfo` — parse `git worktree list --porcelain`, slices into stdout buffer
- `cleanupStaleBranch(repo_path, branch_name)` — `git branch -D {branch}`

Worktree directory: `/tmp/bees-{project_name}/worktrees/worker-{id}-{YYYYMMDD}-{HHMMSS}`

### Commit 4.3: Branch and diff operations

Functions:
- `getCommitsAhead(repo_path, branch, base) → u32` — parse `git rev-list --count`, no allocation
- `getDiff(repo_path, branch, base, arena) → []const u8` — `git diff {base}...{branch}`, single arena alloc
- `getDiffStats(repo_path, branch, base) → DiffStats` — parse `git diff --stat` summary line, no allocation

### Commit 4.4: Merge operations

Functions:
- `tryMerge(repo_path, branch) → MergeResult` — `.success` or `.conflict{ .files = [][]const u8 }`
- `abortMerge(repo_path)` — `git merge --abort`
- `getConflictFiles(repo_path, arena) → [][]const u8` — parse `git diff --name-only --diff-filter=U`
- `commitMerge(repo_path)` — `git commit --no-edit`
- `resetHard(repo_path, ref)` — `git reset --hard {ref}`
- `getCurrentHead(repo_path, buf) → []const u8` — `git rev-parse HEAD`, writes into stack buffer

---

## Phase 5: Claude CLI Integration

**Goal:** Spawn claude processes, parse stream-json output in real time, store all events in LMDB.

### Commit 5.1: Process spawning

`claude.zig` — spawn a Claude CLI process:

```zig
const ClaudeOptions = struct {
    prompt: []const u8,
    cwd: []const u8,
    system_prompt_file: ?[]const u8 = null,
    append_prompt_file: ?[]const u8 = null,
    model: []const u8 = "opus",
    effort: []const u8 = "high",
    max_budget_usd: f64 = 30.0,
    stdin_data: ?[]const u8 = null,
};
```

Function `spawnClaude(options) → ClaudeProcess`:
- Constructs argument list on stack (fixed-size buffer, no alloc)
- Always includes: `-p`, `--dangerously-skip-permissions`, `--output-format stream-json`, `--no-session-persistence`
- Spawns process with stdout piped
- Returns handle with stdout reader and PID

### Commit 5.2: Stream-JSON parser

NDJSON line parser. Uses `std.json.Scanner` to extract specific fields:

```zig
/// Parse one NDJSON line into EventMeta (8 bytes, single register).
/// Scanner walks tokens in the line buffer.
fn parseEventMeta(line: []const u8) EventMeta
```

For each line:
1. Find `"type"` key → map to `EventType` enum (length-switch, ~3 comparisons)
2. If `tool_use`: find `"name"` key → map to `ToolName` enum
3. If `message`: find `"role"` key → map to `Role` enum
4. If `result`: extract `total_cost_usd` (float → centidollars), `duration_ms` (→ seconds), `num_turns`, `is_error`

Everything else is ignored. The raw JSON line goes to LMDB verbatim.

### Commit 5.3: Event capture pipeline

```zig
pub fn runClaudeSession(store: *Store, options: ClaudeOptions, session_id: u64, allocator: std.mem.Allocator) !SessionResult
```

Pipeline per line:
1. Read line into dynamically-sized buffer (start at 1MB, grow as needed for large tool results like file reads)
2. Parse into `EventMeta` (8 bytes on stack)
3. Build `EventKey` (12 bytes on stack) and `EventHeader` (4 bytes on stack)
4. Write to LMDB via `reserve()` — header + raw JSON directly into page
5. If `result` event, capture cost/duration/turns for session finalization

After stream ends:
- Wait for process exit code
- Store exit code in session record (`SessionHeader.exit_code`, `has_exit_code = true`)
- If non-zero exit, set session status to `.err`
- Update session record in LMDB with final status, cost, duration, exit code
- Return `SessionResult`

### Non-fatal LMDB writes and DLQ

Event writes during stream parsing are non-fatal: errors are caught and the failed write is enqueued to a dead letter queue (DLQ) file in `db_dir`. On the next session start, the DLQ is auto-drained back into LMDB. This ensures a transient LMDB error (e.g., map full) never kills an active Claude session.

The `ClaudeOptions` struct includes:
- `stream_output: bool` — when true, raw Claude output is also written to stdout for interactive one-shot runs
- `db_dir: ?[]const u8` — directory for DLQ file location (defaults to `.bees/db/`)

### Commit 5.4: Timeout and hang detection

- Track timestamp of last received line
- If no line received for `config.timeouts.max_idle_secs`:
  - Send SIGTERM to claude process
  - Wait 10 seconds
  - If still alive, SIGKILL
  - Store exit code (SIGTERM/SIGKILL signal number)
  - Update session status to `.err`
  - Log timeout to central log

---

## Phase 6: Worker

**Goal:** `bees run worker` creates a worktree, selects a task, spawns Claude, captures output, writes markers.

### Commit 6.1: Weighted random task selection

`tasks.zig` — `TaskPool`:

- Load from `<project>/.bees/tasks.json` into global arena (zero-copy strings)
- Precompute cumulative weights at load time
- Selection via binary search: O(log n), zero allocation
- Task stats loaded from LMDB `tasks` db (supplementary, not authoritative)

### Commit 6.2: Worker lifecycle

`worker.zig` — `runWorker(config, store, worker_id)`:

1. **Lock check:** PID-based lockfile at `/tmp/bees-{project_name}-worker-{id}.lock` (stack-only, see DATA_STRUCTURES.md)
   - If PID alive and not hung → exit
   - If PID alive but hung → kill, remove lock
   - If PID dead → remove stale lock
2. **Write lockfile** with current PID
3. **Select task** via weighted random (binary search, no alloc)
4. **Create worktree:**
   - Branch: `bee/{project_name}/worker-{id}-{YYYYMMDD}-{HHMMSS}`
   - Dir: `/tmp/bees-{project_name}/worktrees/worker-{id}-{YYYYMMDD}-{HHMMSS}`
5. **Create session** in LMDB (type=worker, status=running, packed SessionHeader)
6. **Spawn Claude** in worktree dir with task prompt
7. **Capture all events** via pipeline (Phase 5) → LMDB events db
8. **Count commits** ahead of base branch (`git rev-list --count`)
9. **Finish session** in LMDB (status=done, cost, duration, commit_count)
10. **Write `.done` marker** in worktree dir (if commits > 0)
11. **If 0 commits:** record `finished_at` timestamp on worktree for delayed cleanup (at least 1 hour)
12. **Update task stats** in LMDB (increment total_runs; empty if 0 commits)
13. **Remove lockfile**
14. **Log** to central log

Note: Claude CLI is spawned with `cwd` set to the worktree directory. Since the worktree is created from the project repo, `CLAUDE.md` is present and Claude auto-reads it for project context. No need to inject project info into the prompt.

### Commit 6.3: Worker spawner

`bees run worker` (no `--id`):

- Read config for worker count
- For each worker_id 1..N, spawn `runWorker` in parallel (Zig 0.16 async tasks or `std.Thread`)
- Wait for all to complete
- Log summary to central log

### Commit 6.4: Central logging

`log.zig` — append-only structured log:

```
2026-03-07T14:00:01Z [worker:1] start task="Cross-reference verification" branch=bee/worker-1-20260307-140001
2026-03-07T14:08:19Z [worker:1] done task="Cross-reference verification" commits=2 cost=$1.47
```

File output to `<project>/.bees/logs/bees.log`. Uses stack buffer for formatting (no allocation per log line).

---

## Phase 7: Merger

**Goal:** `bees run merger` scans for `.done` worktrees, reviews, merges, builds, tests, deploys, cleans up.

### Commit 7.1: Merger lock and worktree scanning

`merger.zig` — `runMerger(config, store)`:

1. **Lock check:** Single-instance via `/tmp/bees-{project_name}-merger.lock`
2. **Scan worktrees** in `/tmp/bees-{project_name}/worktrees/` for `.done` markers
3. For each `.done` worktree:
   - Read branch name from `.git` metadata
   - Count commits ahead of base branch
   - Skip if 0 commits (update session status to done, remove worktree)
4. Return list of candidates for review

### Commit 7.2: AI code review

For each candidate:

1. Extract diff: `git diff {base_branch}...{branch}` (single arena alloc)
2. **Create review session** in LMDB (type=review, status=running)
3. Spawn Claude from the **project root** (not the worktree) with:
   - `--system-prompt-file <project>/.bees/prompts/review.txt`
   - Diff piped via stdin
   - Prompt asks Claude to accept or reject the diff with reasoning
4. Capture events → LMDB
5. Store Claude's full result text as the review reason in LMDB (ReviewHeader + reason)
6. **Verdict is binary: accept or reject.** Simple signal from result text — no complex parsing needed.
7. Update worker session status based on verdict
8. Write `.rejected` marker if rejected

### Commit 7.3: Merge execution

For each accepted branch:

1. Save current HEAD via `git rev-parse HEAD` (stack buffer)
2. Attempt `git merge --no-edit {branch}`
3. On success: log, continue
4. On conflict with ≤ `max_conflict_files` files:
   a. Create conflict session in LMDB (type=conflict)
   b. Spawn Claude in the worktree with conflict resolution prompt
   c. Capture events → LMDB
   d. Check for remaining conflicts after Claude exits
   e. If resolved: `git commit --no-edit`
   f. If not: `git merge --abort`, write `.conflict` marker
5. On conflict with > `max_conflict_files`: abort, write `.conflict` marker

### Commit 7.4: Retry previously conflicted branches

Scan for `.conflict` markers:

1. For each `.conflict` worktree:
   - Re-attempt merge (base branch has advanced)
   - If clean: remove `.conflict` marker, log
   - If still conflicted: attempt AI resolution
   - If still fails: leave `.conflict` marker

### Commit 7.5: Build, test, deploy pipeline

After all merges complete:

1. **Save HEAD** before pipeline
2. **Build:** Run `config.build.command`
   - On failure: spawn Claude (type=fix) to attempt to fix the build error
   - If Claude fixes it and build passes: continue
   - If Claude can't fix it: `git reset --hard {saved_head}`, update all merged sessions to `build_failed`
3. **Test:** Run `config.build.test_command`
   - On failure: same — spawn Claude to fix, rollback if it can't
4. **Smoke test** (if enabled):
   - Start local server on `smoke_test.port`
   - Wait `startup_wait_secs`
   - HTTP GET each URL, check for 200
   - Kill server
   - On failure: same — spawn Claude to fix, rollback if it can't
5. **Deploy:** Run `config.build.deploy_command`
   - On failure: retry once
   - If retry fails: log (don't rollback — build is known good)
6. **Log results** and update all session statuses in LMDB

### Commit 7.7: Cleanup phases

Clean merged worktrees:
- For each successfully merged + deployed branch:
  - `git worktree remove --force {dir}`
  - `git branch -D {branch}`
  - Update session status to `merged` in LMDB

Clean empty worktrees (0 commits, no `.done` marker):
- For each empty worktree older than 1 hour:
  - Remove worktree and branch
  - Log cleanup

Clean old failed worktrees:
- For each worktree with `.rejected`, `.conflict`, or `.build-failed` marker older than `cleanup_hours`:
  - Remove worktree and branch
  - Log cleanup

Stale worktree cleanup:
- For each worktree with NO marker and age > `stale_hours`:
  - Remove worktree and branch
  - Update session status to `err` in LMDB

---

## Phase 8: CLI

**Goal:** All subcommands work from the terminal.

### Commit 8.1: Argument parsing

`cli.zig` — manual arg parsing for ~12 subcommands:

```
bees init                     # Claude-powered project setup
bees start                    # Enable and start systemd timers
bees stop                     # Stop and disable systemd timers
bees status [--json]          # Show current state
bees run worker [--id N]      # Run one worker (or all workers)
bees run merger               # Run the merger
bees run strategist           # Run the strategist agent
bees run sre                  # Run the SRE agent
bees run qa                   # Run the QA agent
bees log [--follow]           # Show/tail central log
bees config [--json]          # Print resolved config
bees tasks [--json]            # List tasks with stats
bees tasks sync [file]         # Sync tasks from JSON file to LMDB
bees sessions [--type X] [--json]  # List recent sessions
bees session <id> [--json]    # Show session detail + events
bees version                  # Print version
```

Global flag `--json` outputs machine-readable JSON instead of human-readable text. Default is text.

### Commit 8.2: `bees status` command

```
bees status
  State:    running (workers: active, merger: waiting)
  Project:  /home/user/my-project (my-project)
  Workers:  5 configured, 3 running, 2 idle
  Merger:   next run in 12m
  Today:    18 accepted, 4 rejected, 2 conflicts, 1 build failure
  Cost:     $47.23 today
  Worktrees: 7 active, 0 stale
```

Opens LMDB read transaction, queries stats (zero-copy), formats to stdout, closes txn. With `--json`, outputs equivalent as a JSON object.

### Commit 8.3: `bees log` command

- Default: print last 50 lines of `<project>/.bees/logs/bees.log`
- `--follow`: poll file for changes (inotify on Linux)

### Commit 8.4: `bees sessions` and `bees session <id>`

- `bees sessions`: reverse scan on `sessions_by_time`, format table. All data zero-copy from LMDB read txn. `--json` outputs array of session objects.
- `bees session <id>`: session header + iterate events, display tool calls with abbreviated input/output. JSON fields parsed on the fly from mmap'd event data. `--json` outputs full session object with events array.

---

## Phase 9: systemd Integration

**Goal:** `bees start` installs and enables systemd user timers. `bees stop` disables them.

### Commit 9.1: Unit file generation

`scheduler.zig` — generate systemd unit files:

**`~/.config/systemd/user/bees-{project_name}-workers.service`**
```ini
[Unit]
Description=Bees worker swarm ({project_name})
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory={project_path}
ExecStart={bees_binary_path} run worker
Environment=HOME={home_dir}
TimeoutStartSec=3600
```

**`~/.config/systemd/user/bees-{project_name}-workers.timer`**
```ini
[Unit]
Description=Bees worker schedule ({project_name})

[Timer]
OnCalendar={schedule converted from cron to systemd calendar}
Persistent=true

[Install]
WantedBy=timers.target
```

Same pattern for `bees-{project_name}-merger.service` and `bees-{project_name}-merger.timer`. Project name in unit names enables multiple projects to have independent timers.

Simple cron-to-systemd converter for the subset we support (e.g., `0 * * * *` → `*:00:00`, `45 * * * *` → `*:45:00`).

### Commit 9.2: Timer management commands

- `bees start`: generate units → `systemctl --user daemon-reload` → `enable --now` both timers → `loginctl enable-linger`
- `bees stop`: `disable --now` both timers
- `bees status`: parse `systemctl --user show` for next trigger times

---

## Phase 10: QA Agent

**Goal:** Diff-aware visual and functional verification after every merge cycle.

The QA agent runs after each merge cycle completes. It receives the merged diff and uses Chrome MCP (`--mcp-config mcp-chrome.json`) to take screenshots and verify that changes render correctly. The main prompt is loaded from the external file `qa.txt` at runtime. QA reports are stored in the LMDB `meta` sub-database.

Source: `src/qa.zig`

---

## Phase 11: Template-Based Prompts

**Goal:** Strategist, SRE, and QA prompts loaded from external files at runtime — editable without recompiling.

All three agent types load their main prompt from files in `<project>/.bees/prompts/`:
- `strategist.txt` — Strategist agent prompt
- `sre-main.txt` — SRE agent main prompt (with `sre.txt` as append system prompt)
- `qa.txt` — QA agent prompt

Prompts are read into the per-session arena at spawn time.

---

## Phase 12: REST API

**Goal:** HTTP server for dashboard integration.

`src/api.zig` implements an HTTP server that serves session, task, and status data as JSON. Designed for consumption by the bees-dashboard Next.js application. Configured via the `api` section in `config.json`.

---

## Phase 13: Non-Fatal Observability

**Goal:** Ensure observability never kills an active session.

- Dead letter queue (`src/dlq.zig`) for failed LMDB writes during stream parsing
- DLQ auto-drains on next session start
- QA and SRE reports stored in LMDB `meta` sub-database instead of disk files

---

## Phase Summary

| Phase | Commits | What it delivers |
|-------|---------|-----------------|
| 1. Scaffold | 4 | Project compiles, dependencies resolve, file structure exists |
| 2. Config | 4 | `bees init` creates config, JSON loads and validates |
| 3. Database | 6 | LMDB environment, bit-packed CRUD for sessions/events/reviews/tasks/stats |
| 4. Git | 4 | Worktree CRUD, diffs, merges, conflict detection |
| 5. Claude | 4 | Process spawn, zero-alloc stream parsing, event capture, timeout, non-fatal DLQ |
| 6. Worker | 4 | Full worker lifecycle with task selection and logging |
| 7. Merger | 6 | Full merger pipeline: review, merge, conflict, build, deploy, cleanup |
| 8. CLI | 4 | All subcommands functional |
| 9. systemd | 2 | Timer generation, start/stop commands |
| 10. QA Agent | — | Diff-aware visual/functional verification via Chrome MCP |
| 11. Template Prompts | — | External prompt files for strategist, SRE, QA |
| 12. REST API | — | HTTP server for dashboard integration |
| 13. Non-Fatal Observability | — | DLQ for failed LMDB writes, reports in LMDB meta |
| **Total** | **38+** | **Complete system** |

## Testing Strategy

Zig's built-in `test` blocks used throughout. Run with `zig build test`.

- **types.zig:** Comptime size assertions for all packed structs. Round-trip encode/decode for all key and value types. Enum `fromJsonString` coverage.
- **store.zig:** Open fresh LMDB env in temp dir. CRUD operations. Verify index consistency after create/update. Concurrent read during write. Iterator correctness.
- **config.zig:** Parse valid JSON, reject invalid JSON, validate missing fields, verify zero-copy (string pointers reference input buffer).
- **claude.zig:** Mock process stdout with canned NDJSON lines. Verify `parseEventMeta` against all event types. Verify cost/duration extraction from result events. Verify timeout kill behavior.
- **git.zig:** Temp repo with scripted commits. Test worktree create/remove, merge success/conflict, diff parsing.
- **worker.zig:** Integration test with mock Claude binary (shell script that emits canned NDJSON). Test lockfile contention. Test task selection distribution over many iterations.
- **merger.zig:** Integration test with pre-built worktrees. Test review verdict parsing. Test rollback on build failure. Test conflict retry logic.

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| Claude CLI stream-json format changes | Parser breaks | Version-check on startup. Pin to known-good version |
| Zig 0.16 async not stable enough | Process mgmt issues | Fallback: std.Thread for worker spawning |
| LMDB map_size exhausted | Writes fail | Monitor with `mdb_env_info`. Configurable. 1 GB lasts years. |
| Packed struct alignment on different architectures | Corrupt data | Use `@bitCast` for serialization. All keys use explicit `writeInt` with `.big` endian. Test on target arch. |

## What's NOT in MVP

- TUI dashboard (deferred to v2)
- Web application (v2)
- Live site verification + auto-rollback (post-deploy)
- Multi-repo support
- Cost budgeting (daily limits)
- Agent SDK transport (alternative to CLI)
- Persistent browser daemon (Chrome MCP cold-starts each session)
- Automated prompt regeneration from CLI help output

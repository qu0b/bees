# Bees — Data Structures & Memory Model

## Guiding Principles

1. **Zero-copy by default.** Strings are slices (`[]const u8`) pointing into owned buffers. Never duplicate a string unless crossing an ownership boundary that requires it.
2. **Enums over strings.** Every finite set of known values is an integer enum. No string comparisons, no string storage.
3. **Bit-pack aggressively.** Pack multiple small fields into minimal bytes using Zig `packed struct`. Every bit has a purpose. On disk and in memory.
4. **Arena allocators for scoped lifetimes.** Each lifetime scope gets its own arena. One `deinit()` frees everything.
5. **Stack buffers for the hot path.** The NDJSON stream parser never heap-allocates per line.
6. **Sentinels over optionals.** Use `0` or `0xFF` as sentinel values instead of `?T` (which adds a tag byte and padding). Document sentinel meanings.

---

## Database: LMDB over SQLite

### Why LMDB

SQLite copies data at the read boundary — `sqlite3_column_text()` returns a pointer valid only until the next `sqlite3_step()`. For event replay (thousands of records), this means thousands of allocations.

LMDB returns pointers directly into memory-mapped pages. Data is valid for the entire read transaction. Zero allocations on read.

| Property | SQLite | LMDB |
|----------|--------|------|
| Read semantics | Copy on read | Zero-copy (mmap) |
| Event replay (1000 events) | 1000 allocs + copies | 0 allocs, pointer arithmetic |
| CLI query/display | Arena alloc per field | Hold read txn, direct access |
| Write model | WAL, concurrent readers | Single writer, concurrent readers |
| Query language | SQL | Key-range scans (manual) |
| Storage format | Row-based, type-tagged | Raw bytes (we control the format) |
| Storage overhead/event | ~50 bytes row overhead | 0 overhead (just key + value bytes) |
| C interop | `@cImport("sqlite3.h")` | `@cImport("lmdb.h")` |

**The tradeoff:** We lose SQL's query flexibility. Every query becomes a key-range scan. But our query patterns are simple:

| Query | LMDB Implementation |
|-------|-------------------|
| Get session by ID | Direct key lookup |
| List recent sessions | Reverse cursor scan on `sessions` db |
| Get running workers | Cursor scan on `sessions_by_status` index |
| Get session events | Range scan: `key >= (session_id, 0)` until `session_id` changes |
| Daily stats | Scan `sessions` where `started_at >= today_start` |
| Approach stats | Direct key lookup on approach name |

All are sequential scans or point lookups. No joins, no GROUP BY, no subqueries. LMDB handles these natively with cursors.

### Zig Binding

Using [zig-lmdb](https://github.com/canvasxyz/zig-lmdb) (supports Zig 0.15.1, main branch tracks nightly):

```zig
const env = try lmdb.Environment.init(db_path, .{ .max_dbs = 8 });
const txn = try lmdb.Transaction.init(env, .{ .mode = .read_only });
defer txn.deinit();

// Zero-copy read: value points directly into mmap
const value = try txn.get(sessions_db, &session_key);
// value is []const u8 — valid for lifetime of txn. No allocation.
const header = @as(*const SessionHeader, @ptrCast(@alignCast(value.ptr)));
```

---

## Bit-Packed Enums

Every enum fits in the minimum number of bits. This matters in packed struct headers.

```zig
/// 3 bits — 8 values (0-7), max 8
const SessionType = enum(u3) {
    worker = 0,
    merger = 1,
    review = 2,
    conflict = 3,
    fix = 4,
    sre = 5,
    strategist = 6,
    qa = 7,
};

/// 3 bits — 7 values (0-6), max 8
const SessionStatus = enum(u3) {
    running = 0,
    done = 1,
    merged = 2,
    rejected = 3,
    conflict_status = 4,
    build_failed = 5,
    err = 6,
};

/// 3 bits — 5 values for event types
const EventType = enum(u3) {
    init_event = 0,     // "init" is a Zig reserved word
    message = 1,
    tool_use = 2,
    tool_result = 3,
    result = 4,

    pub fn fromJsonString(s: []const u8) EventType {
        return switch (s.len) {
            4 => if (std.mem.eql(u8, s, "init")) .init_event else .result,
            6 => if (std.mem.eql(u8, s, "result")) .result else .result,
            7 => if (std.mem.eql(u8, s, "message")) .message else .result,
            8 => if (std.mem.eql(u8, s, "tool_use")) .tool_use else .result,
            11 => if (std.mem.eql(u8, s, "tool_result")) .tool_result else .result,
            else => .result,
        };
    }
};

/// 4 bits — 13 built-in tools + mcp + unknown, max 16
const ToolName = enum(u4) {
    none = 0,
    bash = 1,
    read = 2,
    edit = 3,
    write = 4,
    glob = 5,
    grep = 6,
    web_search = 7,
    web_fetch = 8,
    agent = 9,
    ask_user = 10,
    notebook_edit = 11,
    mcp_tool = 14,
    unknown = 15,

    pub fn fromJsonString(s: []const u8) ToolName {
        return switch (s.len) {
            4 => {
                if (std.mem.eql(u8, s, "Bash")) return .bash;
                if (std.mem.eql(u8, s, "Read")) return .read;
                if (std.mem.eql(u8, s, "Edit")) return .edit;
                if (std.mem.eql(u8, s, "Glob")) return .glob;
                if (std.mem.eql(u8, s, "Grep")) return .grep;
                return .unknown;
            },
            5 => {
                if (std.mem.eql(u8, s, "Write")) return .write;
                if (std.mem.eql(u8, s, "Agent")) return .agent;
                return .unknown;
            },
            7 => if (std.mem.eql(u8, s, "AskUser")) .ask_user else .unknown,
            8 => if (std.mem.eql(u8, s, "WebFetch")) .web_fetch else .unknown,
            9 => if (std.mem.eql(u8, s, "WebSearch")) .web_search else .unknown,
            12 => if (std.mem.eql(u8, s, "NotebookEdit")) .notebook_edit else .unknown,
            else => if (s.len > 4 and std.mem.startsWith(u8, s, "mcp__")) .mcp_tool else .unknown,
        };
    }
};

/// 1 bit — 2 values
const Verdict = enum(u1) {
    accept = 0,
    reject = 1,
};

/// 2 bits — 3 values
const Role = enum(u2) {
    none = 0,
    assistant = 1,
    user = 2,
};

/// 2 bits — 3 values
const ModelType = enum(u2) {
    opus = 0,
    sonnet = 1,
    haiku = 2,
};

/// 2 bits — 3 values (approach lifecycle)
const ApproachStatus = enum(u2) {
    active = 0,
    completed = 1,
    retired = 2,
};

/// 2 bits — 4 values (who created the approach)
const ApproachOrigin = enum(u2) {
    unknown = 0,
    template = 1,
    user = 2,
    strategist = 3,
};
```

**Bit width summary:**

| Enum | Values | Bits | Wasted states |
|------|--------|------|---------------|
| SessionType | 8 | 3 | 0 |
| SessionStatus | 7 | 3 | 1 |
| EventType | 5 | 3 | 3 |
| ToolName | 13 | 4 | 3 |
| Verdict | 2 | 1 | 0 |
| Role | 3 | 2 | 1 |
| ModelType | 3 | 2 | 1 |
| ApproachStatus | 3 | 2 | 1 |
| ApproachOrigin | 4 | 2 | 0 |

Display: each enum has `pub fn label(self) []const u8` returning a comptime string literal (no allocation).

---

## On-Disk Format: LMDB Sub-Databases & Keys

### Sub-databases (7 total)

```zig
const DbNames = struct {
    const sessions = "s";           // session_id → SessionHeader + variable strings
    const sessions_by_status = "ss"; // (status, started_at, session_id) → void
    const sessions_by_time = "st";  // (started_at, session_id) → void
    const events = "e";             // (session_id, seq) → EventHeader + raw JSON
    const reviews = "r";            // worker_session_id → ReviewHeader + reason
    const approaches = "a";         // approach_name → ApproachHeader + prompt
    const meta = "m";               // string keys → various (next_session_id: u64, report:qa: text, report:sre: text, report:trends: text)
};
```

Short names minimize LMDB internal overhead per sub-database.

### Key Formats

All keys are fixed-size byte arrays. Big-endian for correct lexicographic ordering in LMDB.

```zig
/// sessions primary key: 8 bytes
const SessionKey = struct {
    id: u64,

    pub fn toBytes(self: SessionKey) [8]u8 {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, self.id, .big);
        return buf;
    }

    pub fn fromBytes(bytes: *const [8]u8) SessionKey {
        return .{ .id = std.mem.readInt(u64, bytes, .big) };
    }
};

/// events composite key: 12 bytes
/// Ordered by (session_id, seq) — range scan gets all events for a session.
const EventKey = struct {
    session_id: u64,
    seq: u32,

    pub fn toBytes(self: EventKey) [12]u8 {
        var buf: [12]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.session_id, .big);
        std.mem.writeInt(u32, buf[8..12], self.seq, .big);
        return buf;
    }

    pub fn fromBytes(bytes: *const [12]u8) EventKey {
        return .{
            .session_id = std.mem.readInt(u64, bytes[0..8], .big),
            .seq = std.mem.readInt(u32, bytes[8..12], .big),
        };
    }
};

/// sessions_by_status index key: 9 bytes
/// (status:u8, started_at:u40, session_id:u24)
/// u40 for timestamp: seconds since epoch, good until year 36812
/// u24 for session_id: up to 16M sessions before rollover
const StatusIndexKey = struct {
    status: u8,
    started_at_bytes: [5]u8,  // u40 big-endian
    session_id_bytes: [3]u8,  // u24 big-endian

    pub fn init(status: SessionStatus, started_at: u64, session_id: u64) StatusIndexKey {
        var key: StatusIndexKey = undefined;
        key.status = @intFromEnum(status);
        const ts: u40 = @truncate(started_at);
        key.started_at_bytes = @bitCast(std.mem.nativeToBig(u40, ts));
        const sid: u24 = @truncate(session_id);
        key.session_id_bytes = @bitCast(std.mem.nativeToBig(u24, sid));
        return key;
    }

    pub fn toBytes(self: *const StatusIndexKey) *const [9]u8 {
        return @ptrCast(self);
    }
};

/// sessions_by_time index key: 9 bytes
/// (started_at:u40, session_id:u24, type:u8)
const TimeIndexKey = struct {
    started_at_bytes: [5]u8,
    session_id_bytes: [3]u8,
    type_byte: u8,

    pub fn init(started_at: u64, session_id: u64, session_type: SessionType) TimeIndexKey {
        var key: TimeIndexKey = undefined;
        const ts: u40 = @truncate(started_at);
        key.started_at_bytes = @bitCast(std.mem.nativeToBig(u40, ts));
        const sid: u24 = @truncate(session_id);
        key.session_id_bytes = @bitCast(std.mem.nativeToBig(u24, sid));
        key.type_byte = @intFromEnum(session_type);
        return key;
    }

    pub fn toBytes(self: *const TimeIndexKey) *const [9]u8 {
        return @ptrCast(self);
    }
};
```

### Value Formats: Packed Records

#### SessionRecord — 48 bytes fixed header + variable tail

```zig
/// Fixed portion: 48 bytes. Bit-packed.
const SessionHeader = packed struct(u384) {
    // Byte 0: type + status + flags (8 bits)
    @"type": SessionType,       // 3 bits
    status: SessionStatus,      // 3 bits
    has_exit_code: bool,        // 1 bit
    has_cost: bool,             // 1 bit

    // Byte 1: more flags + model (8 bits)
    model: ModelType,           // 2 bits
    has_tokens: bool,           // 1 bit
    has_duration: bool,         // 1 bit
    has_diff_summary: bool,     // 1 bit
    _reserved: u3,              // 3 bits

    // Bytes 2-3: worker_id (16 bits, 0 = N/A)
    worker_id: u16,

    // Bytes 4-5: commit_count + num_turns (16 bits)
    commit_count: u8,           // 0-255 commits per session
    num_turns: u8,              // 0-255 turns per session

    // Bytes 6-7: exit_code (16 bits, sentinel -1 = N/A if !has_exit_code)
    exit_code: i16,

    // Bytes 8-12: started_at (40 bits = ~34,800 years from epoch)
    started_at: u40,

    // Bytes 13-17: finished_at (40 bits, 0 = not finished)
    finished_at: u40,

    // Bytes 18-21: duration_ms (32 bits, up to ~49 days)
    duration_ms: u32,

    // Bytes 22-25: cost in micro-dollars (32 bits, up to $4,294)
    cost_microdollars: u32,     // $1.47 → 1_470_000. Avoids f64.

    // Bytes 26-29: input token count (raw, u32)
    input_tokens: u32,

    // Bytes 30-33: output token count (raw, u32)
    output_tokens: u32,

    // Bytes 34-37: cache creation token count (raw, u32)
    cache_creation_tokens: u32,

    // Bytes 38-41: cache read token count (raw, u32)
    cache_read_tokens: u32,

    // Bytes 42-47: padding to 48-byte boundary
    _pad: u48,

    comptime {
        std.debug.assert(@sizeOf(SessionHeader) == 48);
    }
};

/// Full session record: header + variable-length strings
/// Layout: [SessionHeader: 48 bytes]
///         [approach_len: u16][approach: ...]
///         [branch_len: u16][branch: ...]
///         [worktree_len: u16][worktree: ...]
///         [diff_summary_len: u16][diff_summary: ...]  (only if has_diff_summary)
///
/// Variable strings are length-prefixed with u16.
/// Max string length: 65535 bytes. More than enough.
```

**Key design decisions:**

- **`cost_microdollars: u32` instead of `f64`** — avoids floating point. $1.47 = 1,470,000 microdollars. Integer comparison and arithmetic. 32 bits covers up to $4,294 per session (more than enough at $30 cap). Saves 4 bytes vs f64.

- **Raw token counts (`u32`)** — `input_tokens`, `output_tokens`, `cache_creation_tokens`, `cache_read_tokens` store exact counts (not divided by 1000). u32 covers up to ~4.29 billion tokens per field. Four separate fields enable accurate cost breakdown and cache hit ratio analysis.

- **`started_at: u40`** — 40-bit unix timestamp covers until year ~36,812. Saves 3 bytes vs u64. Matches the u40 used in index keys.

- **No `pid` field** — removed; process ID is not needed in the persistent record.

- **`commit_count: u8`** — no single session produces >255 commits. Saves 3 bytes vs u32.

- **`has_*` flags** — bit flags indicate which optional fields contain meaningful data vs sentinel values. Avoids Zig's `?T` overhead (tag byte + alignment padding).

- **Comptime size assertion** — guarantees the header is exactly 48 bytes. Build fails if layout drifts.

#### EventHeader — 4 bytes fixed header + variable JSON

```zig
/// Event header: 4 bytes. Bit-packed.
const EventHeader = packed struct(u32) {
    event_type: EventType,      // 3 bits
    tool_name: ToolName,        // 4 bits
    role: Role,                 // 2 bits
    _reserved: u7,              // 7 bits for future use

    // Millisecond offset from session start.
    // 16 bits = up to 65.535 seconds.
    // For sessions longer than ~65s, this wraps. That's fine:
    // the event sequence (key.seq) provides ordering.
    // This is for display granularity, not ordering.
    timestamp_offset_ms: u16,

    comptime {
        std.debug.assert(@sizeOf(EventHeader) == 4);
    }
};

/// Full event record stored in LMDB:
/// [EventHeader: 4 bytes][raw_json: variable]
///
/// The raw JSON is stored verbatim from the NDJSON stream.
/// On read, we get a pointer directly into mmap. Zero-copy.
/// CLI commands can display the JSON by parsing it on the fly
/// from the mmap'd pointer — no need to copy it first.
```

**4 bytes overhead per event vs SQLite's ~50+.** For 6000 events/day, that's 24KB vs 300KB of overhead alone. Plus zero-copy reads.

#### ReviewHeader — 8 bytes fixed header + variable reason

```zig
const ReviewHeader = packed struct(u64) {
    verdict: Verdict,           // 1 bit
    _reserved: u7,              // 7 bits

    review_session_id: u24,     // Which session performed the review
    reviewed_at: u32,           // Unix timestamp (32 bits, good until 2106)

    comptime {
        std.debug.assert(@sizeOf(ReviewHeader) == 8);
    }
};

/// Layout: [ReviewHeader: 8 bytes][reason: variable, no length prefix needed — extends to end of value]
```

Since LMDB tells us the total value length, the last variable field doesn't need a length prefix. `reason.len = value.len - @sizeOf(ReviewHeader)`.

#### ApproachHeader — 16 bytes fixed header + variable prompt

```zig
const ApproachHeader = packed struct(u128) {
    weight: u16,                // Selection weight (higher = more likely)
    total_runs: u24,            // Total times this approach was used
    accepted: u24,              // Times the result was accepted
    rejected: u24,              // Times the result was rejected
    empty: u24,                 // Times the result was empty/no changes
    status: ApproachStatus,     // 2 bits: active, completed, retired
    origin: ApproachOrigin,     // 2 bits: unknown, template, user, strategist
    _reserved: u12,             // 12 bits for future use

    comptime {
        std.debug.assert(@sizeOf(ApproachHeader) == 16);
    }
};
```

Key is the approach name (variable-length string). Value layout: `[ApproachHeader: 16 bytes][prompt_len: u16][prompt: ...]`.

Note: run counters use u24 (max ~16M) instead of u32, freeing 4 bytes for `status`, `origin`, and reserved bits within the same 16-byte packed struct.

---

## In-Memory Struct Layout

### Eliminating Optional Overhead

Zig's `?T` adds 1 byte for the tag + alignment padding. For a `?u32`, that's 8 bytes (1 tag + 3 pad + 4 value) instead of 4. For structs with many optional fields, this bloats significantly.

**Rule: Use sentinel values instead of optionals for numeric fields.**

```zig
// BAD: 5 optional fields = 5 extra tag bytes + padding
const SessionBad = struct {
    cost_usd: ?f64,        // 16 bytes (1 tag + 7 pad + 8 value)
    duration_ms: ?i64,     // 16 bytes
    exit_code: ?i32,       // 8 bytes
    token_input: ?i64,     // 16 bytes
    finished_at: ?i64,     // 16 bytes
    // Total: 72 bytes for 5 fields
};

// GOOD: sentinel values, no optionals
const SessionGood = struct {
    cost_microdollars: u32, // 4 bytes. 0 = unknown.
    duration_ms: u32,       // 4 bytes. 0 = unknown.
    exit_code: i16,         // 2 bytes. sentinel: has_exit_code flag in flags byte.
    input_tokens: u32,      // 4 bytes. 0 = unknown.
    finished_at: u40,       // 5 bytes. 0 = not finished.
    // Total: 17 bytes for 5 fields. 4x smaller.
};
```

### Field Ordering for Minimal Padding

Zig non-packed structs follow platform alignment rules. Order fields from largest to smallest alignment:

```zig
// BAD: padding between fields
const Padded = struct {
    a: u8,       // 1 byte
    // 7 bytes padding
    b: u64,      // 8 bytes
    c: u8,       // 1 byte
    // 7 bytes padding
    d: u64,      // 8 bytes
    // Total: 32 bytes for 18 bytes of data
};

// GOOD: no padding needed
const Compact = struct {
    b: u64,      // 8 bytes
    d: u64,      // 8 bytes
    a: u8,       // 1 byte
    c: u8,       // 1 byte
    // 6 bytes trailing padding (struct aligned to 8)
    // Total: 24 bytes. 8 bytes saved.
};
```

### Application to Key Structs

#### In-Memory SessionView (for CLI display, read from LMDB)

```zig
/// Zero-copy view into LMDB mmap. String fields point directly into the
/// value bytes — valid for the read transaction's lifetime.
const SessionView = struct {
    header: SessionHeader,      // 48 bytes (copied from mmap for alignment safety)
    approach: []const u8,       // slice into LMDB mmap
    branch: []const u8,         // slice into LMDB mmap
    worktree: []const u8,       // slice into LMDB mmap
    diff_summary: []const u8,   // slice into LMDB mmap (empty if !has_diff_summary)

    pub fn fromBytes(value: []const u8) SessionView {
        var header: SessionHeader = undefined;
        @memcpy(std.mem.asBytes(&header), value[0..@sizeOf(SessionHeader)]);
        var offset: usize = @sizeOf(SessionHeader);
        const approach = readLenPrefixed(value, &offset);
        const branch = readLenPrefixed(value, &offset);
        const worktree = readLenPrefixed(value, &offset);
        const diff_summary = if (header.has_diff_summary) readLenPrefixed(value, &offset) else "";
        return .{
            .header = header,
            .approach = approach,
            .branch = branch,
            .worktree = worktree,
            .diff_summary = diff_summary,
        };
    }
};
```

**Key point:** The header is `@memcpy`'d from the mmap to avoid unaligned pointer access on the packed struct. The variable-length string slices point directly into LMDB's mmap. CLI commands hold a read transaction open for their duration, so these pointers remain valid until the command completes.

#### EventMeta (stack-only, per NDJSON line)

```zig
/// 8 bytes on stack. Fits in a single register (u64). Passed by value, never allocated.
const EventMeta = packed struct(u64) {
    // Byte 0 bits 0-7: classification
    event_type: EventType,          // 3 bits
    tool_name: ToolName,            // 4 bits
    is_error: bool,                 // 1 bit

    // Byte 1: role
    role: Role,                     // 2 bits
    _reserved: u6,                  // 6 bits

    // Bytes 2-3: result duration
    duration_secs: u16,             // max 65535 seconds (~18 hours)

    // Bytes 4-5: result cost in centidollars ($0.01 units)
    cost_cents: u16,                // max $655.35 per session

    // Byte 6: result turns
    num_turns: u8,                  // max 255

    // Byte 7: padding
    _pad: u8,

    comptime {
        std.debug.assert(@sizeOf(EventMeta) == 8);
    }
};
```

`cost_cents: u16` -- $0.01 precision, max $655.35 per session. Our budget cap is $30. Plenty of headroom.

#### WorkerRow (CLI display)

```zig
/// 32 bytes per worker in the CLI display array. For 5 workers: 160 bytes.
const WorkerRow = struct {
    // 8-byte aligned
    approach_ptr: [*]const u8,      // 8 bytes (zero-copy into LMDB)

    // 4-byte aligned
    elapsed_secs: u32,              // 4 bytes (0 = idle)
    approach_len: u16,              // 2 bytes

    // 1-byte aligned
    id: u8,                         // 1 byte (worker 0-255)
    status: SessionStatus,          // 1 byte (padded from 3-bit enum)
    commit_count: u8,               // 1 byte
    _pad: [7]u8,                    // explicit padding to 32-byte boundary

    pub fn approach(self: WorkerRow) []const u8 {
        if (self.approach_len == 0) return "";
        return self.approach_ptr[0..self.approach_len];
    }

    comptime {
        std.debug.assert(@sizeOf(WorkerRow) == 32);
    }
};
```

---

## Allocator Architecture (Revised for LMDB)

```
Program Lifetime (GlobalArena)
│
├─ Config           — JSON file buffer + parsed structs
├─ Approaches       — JSON file buffer + parsed structs
├─ Prompt templates — 7 files loaded once (see Prompt Templates section)
├─ LMDB env handle  — single mmap for entire database
└─ Sub-database handles (7)

Per-Session Lifetime (SessionArena)
│
├─ Branch name, worktree path — derived strings
├─ Approach prompt (ref into GlobalArena — no copy)
└─ Session result metadata

Per-Line Lifetime (session arena)
│
├─ line_buf: dynamically sized     — starts at 1MB, grows for large tool results
├─ EventMeta: 8 bytes              — packed struct, single register
└─ (line_buf reused across lines, freed when session ends)

Per-Query Lifetime (LMDB read transaction)
│
├─ Read txn held open for CLI command duration
├─ All displayed data references mmap directly — ZERO ALLOCATIONS
└─ txn.abort() when done (releases read snapshot)
```

**CLI commands hold an LMDB read transaction** for their duration. All data pointers reference the mmap. No allocation, no arena, no copies.

```zig
// CLI query — zero allocation
var read_txn = try lmdb.Transaction.init(env, .{ .mode = .read_only });
defer read_txn.abort();

// All reads are zero-copy pointers into mmap
// Format and print directly to stdout
```

---

## Stream Event Pipeline (Revised for LMDB)

```zig
pub fn processEventStream(
    child_stdout: std.io.AnyReader,
    env: *lmdb.Environment,
    events_db: lmdb.Database,
    session_id: u64,
    session_start_time: u64,
) !SessionResult {
    var line_buf = try allocator.alloc(u8, 1 * 1024 * 1024); // Start at 1MB
    defer allocator.free(line_buf);
    var seq: u32 = 0;
    var last_meta: EventMeta = @bitCast(@as(u64, 0));

    while (true) {
        const line = try readLine(child_stdout, &line_buf, allocator) orelse break;
        // readLine grows line_buf if a line exceeds capacity

        // Parse metadata: 8 bytes on stack, zero alloc
        const meta = parseEventMeta(line);

        // Build key: 12 bytes on stack
        const key = EventKey{ .session_id = session_id, .seq = seq };
        const key_bytes = key.toBytes();

        // Build value: header + raw JSON
        // We write directly into LMDB's reserved space to avoid
        // constructing a separate value buffer.
        const now = std.time.timestamp();
        const offset_ms: u16 = @truncate(
            @as(u64, now -| session_start_time) * 1000
        );

        const header = EventHeader{
            .event_type = meta.event_type,
            .tool_name = meta.tool_name,
            .role = meta.role,
            ._reserved = 0,
            .timestamp_offset_ms = offset_ms,
        };

        // Option A: two-part write via LMDB reserve
        {
            var write_txn = try lmdb.Transaction.init(env, .{ .mode = .read_write });
            errdefer write_txn.abort();

            // Reserve exact space in LMDB page
            const value_len = @sizeOf(EventHeader) + line_len;
            const reserved = try write_txn.reserve(events_db, &key_bytes, value_len);

            // Write header directly into LMDB page (zero-copy write)
            @memcpy(reserved[0..@sizeOf(EventHeader)], std.mem.asBytes(&header));
            // Write raw JSON directly into LMDB page (zero-copy write)
            @memcpy(reserved[@sizeOf(EventHeader)..], line);

            try write_txn.commit();
        }

        if (meta.event_type == .result) last_meta = meta;
        seq += 1;
    }

    return .{
        .session_id = session_id,
        .event_count = seq,
        .cost_cents = last_meta.cost_cents,
        .duration_secs = last_meta.duration_secs,
        .num_turns = last_meta.num_turns,
        .is_error = last_meta.is_error,
    };
}
```

**LMDB reserve for zero-copy writes:** Instead of building a value buffer and passing it to `put()`, we `reserve()` the exact size in the LMDB page, then `@memcpy` our header and JSON directly into the reserved space. This avoids constructing a temporary buffer that would then be copied by LMDB.

**Transaction per event vs batch:** Opening a write txn per event has overhead. Alternative: batch N events into one txn. Tradeoff: latency vs throughput. For a stream of ~50 events over minutes, per-event txns are fine. If profiling shows overhead, batch in groups of 10.

---

## LMDB Configuration

```zig
const LmdbConfig = struct {
    /// Max database size. Must be set upfront. Can be larger than actual data.
    /// 1 GB is generous for years of operation.
    map_size: usize = 1 * 1024 * 1024 * 1024,

    /// Max concurrent readers. One per thread (CLI reader + event writer + merger).
    max_readers: u32 = 8,

    /// Number of named sub-databases.
    max_dbs: u32 = 8,
};
```

---

## Summary: Memory Budget (Revised)

| Component | Memory | Lifetime | Notes |
|-----------|--------|----------|-------|
| Config + Approaches | ~10 KB | Program | JSON file buffer + slices |
| Prompt templates | ~30 KB | Program | 7 files loaded once |
| LMDB env + mmap overhead | ~4 KB | Program | Actual mmap pages loaded on demand by OS |
| Per-worker line buffer | 1 MB initial | Per-session | Dynamically grows for large lines, reused across lines |
| EventMeta | 8 bytes | Stack/per-line | Single register |
| Per-session arena | ~2 KB | Per-session | Branch name, worktree path |
| CLI display arrays | ~320 bytes | Per-query | 5 WorkerRows × 32 + 20 SessionRows × ... |
| **Total steady-state** | **< 512 KB** | | Excluding OS mmap pages |

Down from ~1.5 MB with the SQLite design. The main savings: no prepared statement cache, no SQLite internal buffers.

---

## Summary: Where Copies Happen

| Data Flow | Copy? | Why |
|-----------|-------|-----|
| JSON file → Config strings | No | Slices into file buffer |
| NDJSON line → EventMeta | No | Packed struct, enums + numbers |
| NDJSON line → LMDB write | No* | `reserve()` + `@memcpy` into LMDB page |
| LMDB → CLI display | **No** | Pointers into mmap, valid for read txn |
| LMDB → session replay | **No** | Pointers into mmap, valid for read txn |
| Git stdout → parse results | No | Slices into stdout buffer |
| Config strings → Claude CLI args | Yes | Must be null-terminated for execve |

*The `@memcpy` into the reserved LMDB page is a write, not a copy in the "allocate then copy" sense. The data goes directly from our buffer to its final resting place.

**Compared to the SQLite design, we eliminated:**
- All `sqlite3_column_text` → arena copies
- SQLite's internal page cache copies on read
- Prepared statement overhead

---

## Dead Letter Queue

When an LMDB event write fails (DB full, transaction error, etc.), the event is appended to a binary file instead of being lost. On the next session start, the queue is automatically drained back into LMDB.

```
File: <project>/.bees/db/dead-letters.bin

Binary format per entry:
  [u64 session_id] [u32 seq] [4 bytes EventHeader] [u32 json_len] [json bytes]
  Total: 20 + json_len bytes per entry

All integers are little-endian.
```

**Drain behavior:**

- On next session start, the orchestrator reads the entire DLQ file and replays entries into LMDB.
- If all entries replay successfully, the file is deleted.
- If replay partially succeeds (LMDB still broken), the file is rewritten with only the remaining entries.
- If LMDB is still unavailable, entries stay in the file until the next drain attempt.

---

## Prompt Templates

Prompt templates are external files stored at `<project>/.bees/prompts/`. Loaded once at startup into the global arena.

| File | Role | Usage |
|------|------|-------|
| `worker.txt` | Worker | Appended/system prompt for worker sessions |
| `review.txt` | Merger | Appended/system prompt for review sessions |
| `conflict.txt` | Merger | Appended/system prompt for conflict resolution sessions |
| `fix.txt` | Merger | Appended/system prompt for build-fix sessions |
| `strategist.txt` | Strategist | Main prompt, loaded at runtime |
| `sre-main.txt` | SRE | Main prompt, loaded at runtime |
| `qa.txt` | QA | Main prompt, loaded at runtime |

The first four (`worker.txt`, `review.txt`, `conflict.txt`, `fix.txt`) are appended/system prompts -- they augment the dynamically constructed prompt. The last three (`strategist.txt`, `sre-main.txt`, `qa.txt`) are main prompts -- they are the primary instruction passed to the Claude CLI session.

---

## Risk: LMDB vs SQLite

| Risk | Mitigation |
|------|------------|
| Manual index maintenance | Well-defined write paths (create/update session) maintain both primary + index dbs atomically in one txn |
| No SQL for ad-hoc queries | CLI `bees sessions` command handles common queries. Web UI (v2) can scan LMDB directly. |
| Max DB size must be set upfront | 1 GB default. Configurable. LMDB doesn't allocate this — it's a virtual address space reservation. |
| Write amplification (copy-on-write B+ tree) | Our write volume is tiny (~50 events/session, ~120 sessions/day). Not a concern. |
| Zig-lmdb compatibility with 0.16 | zig-lmdb main branch tracks nightly. Fallback: raw `@cImport("lmdb.h")` — the C API is simple. |

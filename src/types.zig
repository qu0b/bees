const std = @import("std");
const assert = std.debug.assert;

// === Bit-packed enums ===

pub const SessionType = enum(u4) {
    worker = 0,
    merger = 1,
    review = 2,
    conflict = 3,
    fix = 4,
    sre = 5,
    strategist = 6,
    qa = 7,
    user = 8,
    researcher = 9,

    pub fn label(self: SessionType) []const u8 {
        return switch (self) {
            .worker => "worker",
            .merger => "merger",
            .review => "review",
            .conflict => "conflict",
            .fix => "fix",
            .sre => "sre",
            .strategist => "strategist",
            .qa => "qa",
            .user => "user",
            .researcher => "researcher",
        };
    }
};

pub const SessionStatus = enum(u3) {
    running = 0,
    done = 1,
    merged = 2,
    rejected = 3,
    conflict_status = 4,
    build_failed = 5,
    err = 6,

    pub fn label(self: SessionStatus) []const u8 {
        return switch (self) {
            .running => "running",
            .done => "done",
            .merged => "merged",
            .rejected => "rejected",
            .conflict_status => "conflict",
            .build_failed => "build_failed",
            .err => "error",
        };
    }
};

pub const EventType = enum(u3) {
    init_event = 0,
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

    pub fn label(self: EventType) []const u8 {
        return switch (self) {
            .init_event => "init",
            .message => "message",
            .tool_use => "tool_use",
            .tool_result => "tool_result",
            .result => "result",
        };
    }
};

pub const ToolName = enum(u4) {
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
    task = 12, // TaskCreate, TaskUpdate, TaskList, TaskGet, TaskOutput, TaskStop
    lsp = 13, // LSP tool (diagnostics, definitions, etc.)
    mcp_tool = 14,
    unknown = 15,

    pub fn fromJsonString(s: []const u8) ToolName {
        if (s.len > 4 and std.mem.startsWith(u8, s, "mcp__")) return .mcp_tool;
        if (s.len >= 4 and std.mem.startsWith(u8, s, "Task")) return .task;
        return switch (s.len) {
            3 => if (std.mem.eql(u8, s, "LSP")) .lsp else .unknown,
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
                if (std.mem.eql(u8, s, "Skill")) return .unknown; // rare, not worth a slot
                return .unknown;
            },
            7 => if (std.mem.eql(u8, s, "AskUser")) .ask_user else .unknown,
            8 => if (std.mem.eql(u8, s, "WebFetch")) .web_fetch else .unknown,
            9 => if (std.mem.eql(u8, s, "WebSearch")) .web_search else .unknown,
            10 => if (std.mem.eql(u8, s, "ToolSearch")) .unknown else .unknown, // deferred tools, rare
            12 => if (std.mem.eql(u8, s, "NotebookEdit")) .notebook_edit else .unknown,
            else => .unknown,
        };
    }

    pub fn label(self: ToolName) []const u8 {
        return switch (self) {
            .none => "",
            .bash => "Bash",
            .read => "Read",
            .edit => "Edit",
            .write => "Write",
            .glob => "Glob",
            .grep => "Grep",
            .web_search => "WebSearch",
            .web_fetch => "WebFetch",
            .agent => "Agent",
            .ask_user => "AskUser",
            .notebook_edit => "NotebookEdit",
            .task => "Task",
            .lsp => "LSP",
            .mcp_tool => "MCP",
            .unknown => "?",
        };
    }
};

pub const Verdict = enum(u1) {
    accept = 0,
    reject = 1,

    pub fn label(self: Verdict) []const u8 {
        return switch (self) {
            .accept => "accept",
            .reject => "reject",
        };
    }
};

pub const Role = enum(u2) {
    none = 0,
    assistant = 1,
    user = 2,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .none => "",
            .assistant => "assistant",
            .user => "user",
        };
    }
};

pub const ModelType = enum(u2) {
    opus = 0,
    sonnet = 1,
    haiku = 2,
    other = 3,

    pub fn label(self: ModelType) []const u8 {
        return switch (self) {
            .opus => "opus",
            .sonnet => "sonnet",
            .haiku => "haiku",
            .other => "other",
        };
    }

    pub fn fromString(s: []const u8) ModelType {
        if (std.mem.eql(u8, s, "opus")) return .opus;
        if (std.mem.eql(u8, s, "haiku")) return .haiku;
        if (std.mem.eql(u8, s, "sonnet")) return .sonnet;
        return .other;
    }
};

/// Result event subtype from Claude CLI stream-json.
/// 0 = unknown for backward compatibility with old records.
pub const ResultSubtype = enum(u3) {
    unknown = 0,
    success = 1,
    error_max_turns = 2,
    error_max_budget = 3,
    error_execution = 4,
    error_other = 5,

    pub fn fromString(s: []const u8) ResultSubtype {
        if (std.mem.eql(u8, s, "success")) return .success;
        if (std.mem.eql(u8, s, "error_max_turns")) return .error_max_turns;
        if (std.mem.eql(u8, s, "error_max_budget_usd")) return .error_max_budget;
        if (std.mem.eql(u8, s, "error_during_execution")) return .error_execution;
        if (std.mem.startsWith(u8, s, "error")) return .error_other;
        return .unknown;
    }

    pub fn label(self: ResultSubtype) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .success => "success",
            .error_max_turns => "max_turns",
            .error_max_budget => "max_budget",
            .error_execution => "execution_error",
            .error_other => "other_error",
        };
    }
};

/// API stop reason from Claude CLI result event.
pub const StopReason = enum(u2) {
    unknown = 0,
    end_turn = 1,
    max_tokens = 2,
    tool_use = 3,

    pub fn fromString(s: []const u8) StopReason {
        if (std.mem.eql(u8, s, "end_turn")) return .end_turn;
        if (std.mem.eql(u8, s, "max_tokens")) return .max_tokens;
        if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
        return .unknown;
    }

    pub fn label(self: StopReason) []const u8 {
        return switch (self) {
            .unknown => "",
            .end_turn => "end_turn",
            .max_tokens => "max_tokens",
            .tool_use => "tool_use",
        };
    }
};

pub const BackendType = enum(u2) {
    claude = 0,
    opencode = 1,
    pi = 2,
    codex = 3,

    pub fn label(self: BackendType) []const u8 {
        return switch (self) {
            .claude => "claude",
            .opencode => "opencode",
            .pi => "pi",
            .codex => "codex",
        };
    }

    pub fn fromString(s: []const u8) BackendType {
        if (std.mem.eql(u8, s, "opencode")) return .opencode;
        if (std.mem.eql(u8, s, "pi")) return .pi;
        if (std.mem.eql(u8, s, "codex")) return .codex;
        return .claude;
    }
};

// === Key types (big-endian for LMDB ordering) ===

pub const SessionKey = struct {
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

pub const EventKey = struct {
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

pub const StatusIndexKey = struct {
    status: u8,
    started_at_bytes: [5]u8,
    session_id_bytes: [3]u8,

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

    pub fn startedAt(self: *const StatusIndexKey) u40 {
        return std.mem.bigToNative(u40, @bitCast(self.started_at_bytes));
    }

    pub fn sessionId(self: *const StatusIndexKey) u24 {
        return std.mem.bigToNative(u24, @bitCast(self.session_id_bytes));
    }
};

pub const TimeIndexKey = struct {
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

    pub fn startedAt(self: *const TimeIndexKey) u40 {
        return std.mem.bigToNative(u40, @bitCast(self.started_at_bytes));
    }

    pub fn sessionId(self: *const TimeIndexKey) u24 {
        return std.mem.bigToNative(u24, @bitCast(self.session_id_bytes));
    }
};

// === Value headers (bit-packed) ===

pub const SessionHeader = packed struct(u384) {
    type: SessionType,
    status: SessionStatus,
    has_exit_code: bool,
    has_cost: bool,
    model: ModelType,
    has_tokens: bool,
    has_duration: bool,
    has_diff_summary: bool,
    backend: BackendType = .claude,
    has_result_detail: bool = false,
    worker_id: u16,
    commit_count: u8,
    num_turns: u8,
    exit_code: i16,
    started_at: u40,
    finished_at: u40,
    duration_ms: u32,
    cost_microdollars: u32,
    input_tokens: u32,
    output_tokens: u32,
    cache_creation_tokens: u32,
    cache_read_tokens: u32,
    // New fields — use the former 48-bit pad. Old records have zeros here,
    // which map to unknown/unknown/0 — fully backward compatible.
    result_subtype: ResultSubtype = .unknown,
    stop_reason: StopReason = .unknown,
    duration_api_ms: u32 = 0,
    _pad: u10 = 0, // Reduced from u11 after SessionType u3→u4

    comptime {
        assert(@sizeOf(SessionHeader) == 48);
        assert(@bitSizeOf(SessionHeader) == 384);
        // Ensure started_at and finished_at can hold timestamps until year ~10889.
        assert(@bitSizeOf(@TypeOf(@as(SessionHeader, undefined).started_at)) == 40);
        assert(@bitSizeOf(@TypeOf(@as(SessionHeader, undefined).finished_at)) == 40);
    }
};

pub const EventHeader = packed struct(u32) {
    event_type: EventType,
    tool_name: ToolName,
    role: Role,
    _reserved: u7 = 0,
    timestamp_offset_ms: u16,

    comptime {
        assert(@sizeOf(EventHeader) == 4);
        assert(@bitSizeOf(EventHeader) == 32);
    }
};

pub const ReviewHeader = packed struct(u64) {
    verdict: Verdict,
    _reserved: u7 = 0,
    review_session_id: u24,
    reviewed_at: u32,

    comptime {
        assert(@sizeOf(ReviewHeader) == 8);
        assert(@bitSizeOf(ReviewHeader) == 64);
    }
};

pub const TaskStatus = enum(u2) {
    active = 0,
    completed = 1,
    retired = 2,

    pub fn label(self: TaskStatus) []const u8 {
        return switch (self) {
            .active => "active",
            .completed => "completed",
            .retired => "retired",
        };
    }
};

pub const TaskOrigin = enum(u2) {
    unknown = 0,
    template = 1,
    user = 2,
    strategist = 3,

    pub fn label(self: TaskOrigin) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .template => "template",
            .user => "user",
            .strategist => "strategist",
        };
    }
};

pub const TaskHeader = packed struct(u128) {
    weight: u16,
    total_runs: u24,
    accepted: u24,
    rejected: u24,
    empty: u24,
    status: TaskStatus,
    origin: TaskOrigin,
    _reserved: u12 = 0,

    comptime {
        assert(@sizeOf(TaskHeader) == 16);
        assert(@bitSizeOf(TaskHeader) == 128);
    }
};

pub const TaskView = struct {
    header: TaskHeader,
    prompt: []const u8,

    pub fn fromBytes(value: []const u8) TaskView {
        var header: TaskHeader = undefined;
        @memcpy(std.mem.asBytes(&header), value[0..@sizeOf(TaskHeader)]);
        var offset: usize = @sizeOf(TaskHeader);
        const prompt = if (offset < value.len) readLenPrefixed(value, &offset) else "";
        return .{ .header = header, .prompt = prompt };
    }
};

pub fn taskValueSize(prompt: []const u8) usize {
    return @sizeOf(TaskHeader) + 2 + prompt.len;
}

pub const EventMeta = packed struct(u64) {
    event_type: EventType,
    tool_name: ToolName,
    is_error: bool,
    role: Role,
    _reserved: u6 = 0,
    duration_secs: u16,
    cost_cents: u16,
    num_turns: u8,
    _pad: u8 = 0,

    comptime {
        assert(@sizeOf(EventMeta) == 8);
        assert(@bitSizeOf(EventMeta) == 64);
    }
};

// === Cross-struct invariants ===

comptime {
    // LMDB key sizes: SessionKey serializes to 8 bytes, EventKey to 12, index keys to 9.
    assert(@sizeOf(SessionKey) == 8); // u64 big-endian, no padding.
    assert(@sizeOf(StatusIndexKey) == 9);
    assert(@sizeOf(TimeIndexKey) == 9);
    // EventKey serialized form (toBytes) is 12 bytes: 8 (session_id) + 4 (seq).
    // The struct itself is larger due to alignment, but the wire format is 12.
    assert(@typeInfo(@TypeOf(@as(EventKey, undefined).toBytes())).array.len == 12);
    // SessionType must have enough bits for all 9 variants (worker=0..user=8).
    assert(@bitSizeOf(SessionType) >= 4);
    // Enum bit widths must fit in their packed struct containers.
    assert(@bitSizeOf(EventType) <= @bitSizeOf(u3));
    assert(@bitSizeOf(ToolName) <= @bitSizeOf(u4));
    assert(@bitSizeOf(Role) <= @bitSizeOf(u2));
    assert(@bitSizeOf(Verdict) <= @bitSizeOf(u1));
}

// === Sub-database names ===

pub const DbNames = struct {
    pub const sessions = "s";
    pub const sessions_by_status = "ss";
    pub const sessions_by_time = "st";
    pub const events = "e";
    pub const reviews = "r";
    pub const tasks = "a";
    pub const meta = "m";
};

// === Zero-copy view types ===

pub const SessionView = struct {
    header: SessionHeader,
    task: []const u8,
    branch: []const u8,
    worktree: []const u8,
    diff_summary: []const u8,

    pub fn fromBytes(value: []const u8) SessionView {
        var header: SessionHeader = undefined;
        @memcpy(std.mem.asBytes(&header), value[0..@sizeOf(SessionHeader)]);
        var offset: usize = @sizeOf(SessionHeader);
        const task = readLenPrefixed(value, &offset);
        const branch = readLenPrefixed(value, &offset);
        const worktree = readLenPrefixed(value, &offset);
        const diff_summary = if (header.has_diff_summary) readLenPrefixed(value, &offset) else "";
        return .{
            .header = header,
            .task = task,
            .branch = branch,
            .worktree = worktree,
            .diff_summary = diff_summary,
        };
    }
};

pub const EventView = struct {
    seq: u32,
    header: EventHeader,
    raw_json: []const u8,
};

pub const ReviewView = struct {
    header: ReviewHeader,
    reason: []const u8,

    pub fn fromBytes(value: []const u8) ReviewView {
        var header: ReviewHeader = undefined;
        @memcpy(std.mem.asBytes(&header), value[0..@sizeOf(ReviewHeader)]);
        return .{
            .header = header,
            .reason = value[@sizeOf(ReviewHeader)..],
        };
    }
};

// === Helpers ===

pub fn readLenPrefixed(buf: []const u8, offset: *usize) []const u8 {
    if (offset.* + 2 > buf.len) return "";
    const len = std.mem.readInt(u16, buf[offset.*..][0..2], .little);
    offset.* += 2;
    if (offset.* + len > buf.len) return "";
    const slice = buf[offset.*..][0..len];
    offset.* += len;
    return slice;
}

pub fn writeLenPrefixed(buf: []u8, offset: *usize, data: []const u8) void {
    // Truncate to u16 max if data is too long (defensive — avoids runtime panic)
    const capped_len = @min(data.len, std.math.maxInt(u16));
    const len: u16 = @intCast(capped_len);
    std.mem.writeInt(u16, buf[offset.*..][0..2], len, .little);
    offset.* += 2;
    @memcpy(buf[offset.*..][0..capped_len], data[0..capped_len]);
    offset.* += capped_len;
}

pub fn sessionValueSize(task: []const u8, branch: []const u8, worktree: []const u8, diff_summary: ?[]const u8) usize {
    var size: usize = @sizeOf(SessionHeader);
    size += 2 + task.len;
    size += 2 + branch.len;
    size += 2 + worktree.len;
    if (diff_summary) |ds| size += 2 + ds.len;
    return size;
}

// === Tests ===

test "enum sizes" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(SessionType));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(SessionStatus));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(EventType));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(ToolName));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Verdict));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Role));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(ModelType));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(BackendType));
}

test "packed struct sizes" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(SessionHeader));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(EventHeader));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ReviewHeader));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(TaskHeader));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(EventMeta));
}

test "SessionKey round-trip" {
    const key = SessionKey{ .id = 42 };
    const bytes = key.toBytes();
    const decoded = SessionKey.fromBytes(&bytes);
    try std.testing.expectEqual(@as(u64, 42), decoded.id);
}

test "SessionKey big-endian ordering" {
    const k1 = (SessionKey{ .id = 1 }).toBytes();
    const k2 = (SessionKey{ .id = 2 }).toBytes();
    const k256 = (SessionKey{ .id = 256 }).toBytes();
    try std.testing.expect(std.mem.order(u8, &k1, &k2) == .lt);
    try std.testing.expect(std.mem.order(u8, &k2, &k256) == .lt);
}

test "EventKey round-trip" {
    const key = EventKey{ .session_id = 100, .seq = 42 };
    const bytes = key.toBytes();
    const decoded = EventKey.fromBytes(&bytes);
    try std.testing.expectEqual(@as(u64, 100), decoded.session_id);
    try std.testing.expectEqual(@as(u32, 42), decoded.seq);
}

test "EventKey ordering" {
    const k1 = (EventKey{ .session_id = 1, .seq = 0 }).toBytes();
    const k2 = (EventKey{ .session_id = 1, .seq = 1 }).toBytes();
    const k3 = (EventKey{ .session_id = 2, .seq = 0 }).toBytes();
    try std.testing.expect(std.mem.order(u8, &k1, &k2) == .lt);
    try std.testing.expect(std.mem.order(u8, &k2, &k3) == .lt);
}

test "EventType fromJsonString" {
    try std.testing.expectEqual(EventType.init_event, EventType.fromJsonString("init"));
    try std.testing.expectEqual(EventType.message, EventType.fromJsonString("message"));
    try std.testing.expectEqual(EventType.tool_use, EventType.fromJsonString("tool_use"));
    try std.testing.expectEqual(EventType.tool_result, EventType.fromJsonString("tool_result"));
    try std.testing.expectEqual(EventType.result, EventType.fromJsonString("result"));
}

test "ToolName fromJsonString" {
    try std.testing.expectEqual(ToolName.bash, ToolName.fromJsonString("Bash"));
    try std.testing.expectEqual(ToolName.read, ToolName.fromJsonString("Read"));
    try std.testing.expectEqual(ToolName.write, ToolName.fromJsonString("Write"));
    try std.testing.expectEqual(ToolName.agent, ToolName.fromJsonString("Agent"));
    try std.testing.expectEqual(ToolName.web_fetch, ToolName.fromJsonString("WebFetch"));
    try std.testing.expectEqual(ToolName.web_search, ToolName.fromJsonString("WebSearch"));
    try std.testing.expectEqual(ToolName.mcp_tool, ToolName.fromJsonString("mcp__slack__post"));
    try std.testing.expectEqual(ToolName.task, ToolName.fromJsonString("TaskCreate"));
    try std.testing.expectEqual(ToolName.task, ToolName.fromJsonString("TaskUpdate"));
    try std.testing.expectEqual(ToolName.lsp, ToolName.fromJsonString("LSP"));
    try std.testing.expectEqual(ToolName.unknown, ToolName.fromJsonString("SomethingElse"));
}

test "readLenPrefixed round-trip" {
    var buf: [256]u8 = undefined;
    var write_off: usize = 0;
    writeLenPrefixed(&buf, &write_off, "hello");
    writeLenPrefixed(&buf, &write_off, "world");

    var read_off: usize = 0;
    const s1 = readLenPrefixed(&buf, &read_off);
    const s2 = readLenPrefixed(&buf, &read_off);
    try std.testing.expectEqualStrings("hello", s1);
    try std.testing.expectEqualStrings("world", s2);
}

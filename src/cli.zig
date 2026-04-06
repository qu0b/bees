const std = @import("std");
const types = @import("types.zig");

pub const Command = union(enum) {
    init: struct { skip_analysis: bool = false },
    start,
    stop,
    daemon,
    status: OutputOptions,
    run_worker: struct { id: ?u32 = null },
    run_merger,
    run_strategist,
    run_sre,
    run_qa,
    run_user,
    run_researcher,
    log: struct { follow: bool = false },
    config: OutputOptions,
    tasks: OutputOptions,
    tasks_sync: struct { file: ?[]const u8 = null },
    sync,
    sessions: struct { session_type: ?types.SessionType = null, json: bool = false, limit: u32 = 50 },
    session: struct { id: u64, json: bool = false },
    knowledge,
    funding: struct { action: FundingAction = .list },
    wallet: struct { action: WalletAction = .list },
    version,
    help,
};

pub const FundingAction = union(enum) {
    list,
    approve: []const u8,
    deny: []const u8,
};

pub const WalletAction = union(enum) {
    list,
    init_role: []const u8,
};

pub const OutputOptions = struct {
    json: bool = false,
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len < 2) return .help;

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "init")) {
        return .{ .init = .{ .skip_analysis = hasFlag(args[2..], "--skip-analysis") } };
    }
    if (std.mem.eql(u8, cmd, "start")) return .start;
    if (std.mem.eql(u8, cmd, "stop")) return .stop;
    if (std.mem.eql(u8, cmd, "daemon")) return .daemon;
    if (std.mem.eql(u8, cmd, "version")) return .version;
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return .help;

    if (std.mem.eql(u8, cmd, "status")) {
        return .{ .status = .{ .json = hasFlag(args[2..], "--json") } };
    }
    if (std.mem.eql(u8, cmd, "config")) {
        return .{ .config = .{ .json = hasFlag(args[2..], "--json") } };
    }
    if (std.mem.eql(u8, cmd, "tasks")) {
        if (args.len >= 3 and std.mem.eql(u8, args[2], "sync")) {
            const file = if (args.len >= 4) args[3] else null;
            return .{ .tasks_sync = .{ .file = file } };
        }
        return .{ .tasks = .{ .json = hasFlag(args[2..], "--json") } };
    }
    if (std.mem.eql(u8, cmd, "sync")) return .sync;
    if (std.mem.eql(u8, cmd, "log")) {
        return .{ .log = .{ .follow = hasFlag(args[2..], "--follow") or hasFlag(args[2..], "-f") } };
    }
    if (std.mem.eql(u8, cmd, "sessions")) {
        const json = hasFlag(args[2..], "--json");
        const type_str = getFlagValue(args[2..], "--type");
        const session_type: ?types.SessionType = if (type_str) |ts| parseSessionType(ts) else null;
        const limit_str = getFlagValue(args[2..], "--limit");
        const limit: u32 = if (limit_str) |s| std.fmt.parseInt(u32, s, 10) catch 50 else 50;
        return .{ .sessions = .{ .session_type = session_type, .json = json, .limit = limit } };
    }
    if (std.mem.eql(u8, cmd, "session")) {
        if (args.len < 3) return error.MissingSessionId;
        const id = std.fmt.parseInt(u64, args[2], 10) catch return error.InvalidSessionId;
        return .{ .session = .{ .id = id, .json = hasFlag(args[3..], "--json") } };
    }
    if (std.mem.eql(u8, cmd, "run")) {
        if (args.len < 3) return error.MissingRunSubcommand;
        const sub = args[2];
        if (std.mem.eql(u8, sub, "worker")) {
            const id_str = getFlagValue(args[3..], "--id");
            const id: ?u32 = if (id_str) |s| std.fmt.parseInt(u32, s, 10) catch return error.InvalidWorkerId else null;
            return .{ .run_worker = .{ .id = id } };
        }
        if (std.mem.eql(u8, sub, "merger")) return .run_merger;
        if (std.mem.eql(u8, sub, "strategist")) return .run_strategist;
        if (std.mem.eql(u8, sub, "sre")) return .run_sre;
        if (std.mem.eql(u8, sub, "qa")) return .run_qa;
        if (std.mem.eql(u8, sub, "user")) return .run_user;
        if (std.mem.eql(u8, sub, "researcher")) return .run_researcher;
        return error.UnknownRunSubcommand;
    }

    // Bare "strategist" as alias for "run strategist"
    if (std.mem.eql(u8, cmd, "strategist")) return .run_strategist;

    if (std.mem.eql(u8, cmd, "knowledge")) return .knowledge;

    if (std.mem.eql(u8, cmd, "wallet")) {
        if (args.len >= 3 and std.mem.eql(u8, args[2], "init")) {
            if (args.len < 4) return error.MissingRoleName;
            return .{ .wallet = .{ .action = .{ .init_role = args[3] } } };
        }
        return .{ .wallet = .{ .action = .list } };
    }

    if (std.mem.eql(u8, cmd, "funding")) {
        if (args.len < 3) return .{ .funding = .{ .action = .list } };
        const sub = args[2];
        if (std.mem.eql(u8, sub, "approve")) {
            if (args.len < 4) return error.MissingFundingId;
            return .{ .funding = .{ .action = .{ .approve = args[3] } } };
        }
        if (std.mem.eql(u8, sub, "deny")) {
            if (args.len < 4) return error.MissingFundingId;
            return .{ .funding = .{ .action = .{ .deny = args[3] } } };
        }
        return .{ .funding = .{ .action = .list } };
    }

    return error.UnknownCommand;
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn getFlagValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag) and i + 1 < args.len) {
            return args[i + 1];
        }
    }
    return null;
}

fn parseSessionType(s: []const u8) ?types.SessionType {
    if (std.mem.eql(u8, s, "worker")) return .worker;
    if (std.mem.eql(u8, s, "merger")) return .merger;
    if (std.mem.eql(u8, s, "review")) return .review;
    if (std.mem.eql(u8, s, "conflict")) return .conflict;
    if (std.mem.eql(u8, s, "fix")) return .fix;
    if (std.mem.eql(u8, s, "sre")) return .sre;
    if (std.mem.eql(u8, s, "strategist")) return .strategist;
    if (std.mem.eql(u8, s, "qa")) return .qa;
    if (std.mem.eql(u8, s, "user")) return .user;
    if (std.mem.eql(u8, s, "researcher")) return .researcher;
    if (std.mem.eql(u8, s, "founder")) return .founder;
    return null;
}

test "parse version" {
    const cmd = try parse(&.{ "bees", "version" });
    try std.testing.expect(cmd == .version);
}

test "parse help" {
    const cmd = try parse(&.{ "bees", "help" });
    try std.testing.expect(cmd == .help);
}

test "parse no args" {
    const cmd = try parse(&.{"bees"});
    try std.testing.expect(cmd == .help);
}

test "parse run worker" {
    const cmd = try parse(&.{ "bees", "run", "worker" });
    try std.testing.expect(cmd == .run_worker);
    try std.testing.expectEqual(@as(?u32, null), cmd.run_worker.id);
}

test "parse run worker with id" {
    const cmd = try parse(&.{ "bees", "run", "worker", "--id", "3" });
    try std.testing.expectEqual(@as(?u32, 3), cmd.run_worker.id);
}

test "parse session" {
    const cmd = try parse(&.{ "bees", "session", "42" });
    try std.testing.expectEqual(@as(u64, 42), cmd.session.id);
}

test "parse init" {
    const cmd = try parse(&.{ "bees", "init" });
    try std.testing.expect(cmd == .init);
    try std.testing.expectEqual(false, cmd.init.skip_analysis);
}

test "parse init skip analysis" {
    const cmd = try parse(&.{ "bees", "init", "--skip-analysis" });
    try std.testing.expectEqual(true, cmd.init.skip_analysis);
}

test "parse status json" {
    const cmd = try parse(&.{ "bees", "status", "--json" });
    try std.testing.expect(cmd.status.json);
}

const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const backend = @import("backend.zig");

/// DeepSeek Harness (`dsh`) — https://github.com/deepseek-ai/deepseek-harness
///
/// `dsh --profile headless "<task>"` accepts one nonblank task, creates and
/// persists a session, prints the final assistant text, and exits. That is the
/// whole supported non-interactive surface: the harness DOES emit canonical
/// session events as JSONL, but only through a test-only driver its own docs
/// call "test infrastructure, not a supported CLI output format". Parsing it
/// would couple bees to something upstream has explicitly not promised, in a
/// project that says "THERE WILL BE COMPATIBILITY-BREAKING CHANGES".
///
/// So a dsh session yields the final text and nothing else — no per-turn
/// events, no token counts, no cost. `BackendType.streamsEvents()` reports
/// that, and the session is stored with cost_known = false rather than a
/// fabricated zero. Budget caps cannot be enforced on this backend: pick the
/// model's own limits, and prefer dsh for roles whose spend you already bound
/// another way.
///
/// Model choice belongs to the profile, not to us: the headless profile
/// composes its model in its Cordis config and takes DEEPSEEK_API_KEY /
/// DEEPSEEK_BASE_URL from the environment. `--profile` is therefore what
/// `role.model` selects here — naming a profile, not a model id.
pub fn spawnDsh(allocator: std.mem.Allocator, io: Io, options: backend.BackendOptions, binary_name: []const u8) !std.process.Child {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var timeout_secs_buf: [16]u8 = undefined;
    try backend.appendTimeoutPrefix(&args, allocator, options.timeout_secs, &timeout_secs_buf);

    try args.append(allocator, binary_name);
    try args.append(allocator, "--profile");
    try args.append(allocator, profileOf(options.model));

    // Launcher flags come first and the first unrecognized token starts the
    // inner arguments, so the task must be last.
    const combined = try backend.buildPromptWithFiles(allocator, options.prompt, options.system_prompt_file, options.append_prompt_file);
    try args.append(allocator, combined);

    var env_map = backend.buildFilteredEnvMap(allocator);
    defer env_map.deinit();

    var child = try std.process.spawn(io, .{
        .argv = args.items,
        .cwd = .{ .path = options.cwd },
        .environ_map = &env_map,
        .stdout = .pipe,
        .stderr = if (options.silence_stderr) .ignore else .inherit,
        .stdin = if (options.stdin_data != null) .pipe else .ignore,
    });

    backend.writeStdinAndClose(&child, io, options.stdin_data);
    return child;
}

/// The profile a role's `model` names. Empty (a role that never set one, or a
/// gateway default meant for another backend) falls back to `headless` — the
/// only profile that answers one task and exits, which is the shape every bees
/// role needs.
pub fn profileOf(model: []const u8) []const u8 {
    if (model.len == 0) return "headless";
    // A gateway model id (`local-llm/foo`, `starflinger-anthropic`) is not a
    // profile name; those belong to backends that take a model flag.
    if (std.mem.indexOfScalar(u8, model, '/') != null) return "headless";
    return model;
}

test "profileOf falls back to headless for anything that is not a profile name" {
    try std.testing.expectEqualStrings("headless", profileOf(""));
    try std.testing.expectEqualStrings("headless", profileOf("local-llm/minimax-m2.7"));
    // A plain name is taken as the profile the operator wants.
    try std.testing.expectEqualStrings("headless", profileOf("headless"));
    try std.testing.expectEqualStrings("tui", profileOf("tui"));
}

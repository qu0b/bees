const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // LMDB (vendored C source)
    root_mod.addCSourceFiles(.{
        .files = &.{ "vendor/lmdb/mdb.c", "vendor/lmdb/midl.c" },
        .flags = &.{"-pthread"},
    });
    root_mod.addIncludePath(b.path("vendor/lmdb"));

    // SQLite (vendored amalgamation)
    root_mod.addCSourceFiles(.{
        .files = &.{"vendor/sqlite/sqlite3.c"},
        .flags = &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_THREADSAFE=2", // multi-thread (no mutex on connections)
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_DEFAULT_CACHE_SIZE=-8000",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_PROGRESS_CALLBACK",
            "-DSQLITE_OMIT_SHARED_CACHE",
        },
    });
    root_mod.addIncludePath(b.path("vendor/sqlite"));

    // DuckDB header (for @cImport in duckdb.zig — library loaded at runtime via dlopen)
    root_mod.addIncludePath(b.path("vendor/duckdb"));

    root_mod.linkSystemLibrary("c", .{});

    const exe = b.addExecutable(.{
        .name = "bees",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run bees");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{ .root_module = root_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

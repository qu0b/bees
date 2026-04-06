//! Workflow definition and executor — parses .bees/workflows/default.json
//! and drives the orchestration cycle.
//!
//! A workflow is a sequence of steps. Each step runs a role (or a parallel
//! group of roles). Steps can be conditional, periodic, or parallel.
//!
//! JSON format:
//! {
//!   "name": "default",
//!   "steps": [
//!     { "role": "worker", "parallel": 5 },
//!     { "role": "merger", "trigger": "workers_done" },
//!     { "group": "validation", "steps": [
//!       { "role": "qa" },
//!       { "role": "user" }
//!     ]},
//!     { "role": "sre", "condition": "tool_errors" },
//!     { "role": "strategist", "every": 3 }
//!   ],
//!   "cycle": {
//!     "cooldown_secs": 300,
//!     "merge_threshold": 3,
//!     "worker_timeout_minutes": 60
//!   }
//! }

const std = @import("std");
const fs = @import("fs.zig");
const config_mod = @import("config.zig");

pub const StepKind = enum {
    single, // Run one instance of a role
    parallel, // Run N instances of the same role
    group, // Run multiple different roles in parallel
};

pub const Step = struct {
    /// Role name (for single/parallel steps)
    role: []const u8 = "",
    /// Number of parallel instances (0 = single)
    parallel: u32 = 0,
    /// Group name (for group steps)
    group: []const u8 = "",
    /// Sub-steps (for group steps)
    steps: []const Step = &.{},
    /// Trigger condition: "workers_done" = wait for merge threshold
    trigger: []const u8 = "",
    /// Condition: "tool_errors" = only run if tool errors occurred
    condition: []const u8 = "",
    /// Periodic: run every N cycles (0 = every cycle)
    every: u32 = 0,

    pub fn kind(self: *const Step) StepKind {
        if (self.group.len > 0 or self.steps.len > 0) return .group;
        if (self.parallel > 1) return .parallel;
        return .single;
    }
};

pub const CycleConfig = struct {
    cooldown_secs: u32 = 300,
    merge_threshold: u32 = 3,
    worker_timeout_minutes: u32 = 60,
    restart_timeout_minutes: u32 = 20,
    max_restarts: u32 = 2,
    quiet_start_utc: ?u8 = null,
    quiet_end_utc: ?u8 = null,
    quiet_weekdays_only: bool = true,
};

pub const Workflow = struct {
    name: []const u8 = "default",
    steps: []const Step = &.{},
    cycle: CycleConfig = .{},

    /// Check if a step should run this cycle.
    pub fn shouldRunStep(step: *const Step, cycle_count: u32) bool {
        if (step.every == 0) return true;
        return cycle_count > 0 and (cycle_count % step.every == 0);
    }
};

/// Load workflow from .bees/workflows/default.json.
/// Returns default workflow if file doesn't exist.
pub fn load(paths: config_mod.ProjectPaths, allocator: std.mem.Allocator) Workflow {
    const workflows_dir = std.fs.path.join(allocator, &.{ paths.bees_dir, "workflows" }) catch return .{};
    defer allocator.free(workflows_dir);
    const path = std.fs.path.join(allocator, &.{ workflows_dir, "default.json" }) catch return .{};
    defer allocator.free(path);

    const data = fs.readFileAlloc(allocator, path, 256 * 1024) catch return defaultWorkflow();
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(Workflow, allocator, data, .{
        .allocate = .alloc_always,
    }) catch return defaultWorkflow();
    return parsed.value;
}

/// Default workflow matching the current hardcoded cycle.
pub fn defaultWorkflow() Workflow {
    return .{
        .name = "default",
        .steps = &default_steps,
        .cycle = .{},
    };
}

const default_steps = [_]Step{
    .{ .role = "worker", .parallel = 5 },
    .{ .role = "merger", .trigger = "workers_done" },
    .{ .role = "qa" },
    .{ .role = "user" },
    .{ .role = "sre", .condition = "tool_errors" },
    .{ .role = "founder", .every = 10 },
    .{ .role = "strategist", .every = 3 },
};

/// Validate that all roles referenced in the workflow exist.
pub fn validate(wf: *const Workflow, role_names: []const []const u8, allocator: std.mem.Allocator) []const []const u8 {
    var errors = std.ArrayList([]const u8).init(allocator);
    for (wf.steps) |step| {
        validateStep(&step, role_names, &errors, allocator);
    }
    return errors.toOwnedSlice(allocator) catch &.{};
}

fn validateStep(step: *const Step, role_names: []const []const u8, errors: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    if (step.role.len > 0) {
        var found = false;
        for (role_names) |name| {
            if (std.mem.eql(u8, name, step.role)) {
                found = true;
                break;
            }
        }
        if (!found) {
            const msg = std.fmt.allocPrint(allocator, "workflow step references unknown role '{s}'", .{step.role}) catch return;
            errors.append(allocator, msg) catch {};
        }
    }
    for (step.steps) |sub| {
        validateStep(&sub, role_names, errors, allocator);
    }
}

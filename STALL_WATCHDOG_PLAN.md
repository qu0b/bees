# Stall watchdog — implementation plan

Incident: 2026-08-09, chatplugin swarm. A QA session ran 8h18m and blocked the
whole daemon (0 merges, 0 workers spawned in that window). This plan removes
every link in the chain that let it happen.

## Root cause chain (evidence from session 95)

1. **Proximate**: the QA agent ran `./target/debug/deps/publish-<hash> --test-threads=1`
   — a test binary invoked directly, outside `cargo` — and it never exited.
2. **Why nobody noticed**: the Claude CLI emitted a `tool_progress` heartbeat
   roughly every 30s while that Bash call blocked. Session 95 holds **986
   `tool_progress` events** vs 40 `tool_use` / 40 `tool_result`. The session
   *looked* busy: events kept arriving, cost kept being reported.
3. **Why bees mis-read them**: `types.EventType.fromJsonString`
   (`src/types.zig:78-87`) maps every unrecognized type to `.result`.
   `"tool_progress"` (len 13) hits `else => .result`, so each heartbeat was
   (a) stored as an event row, (b) set `acc.saw_result = true`, and (c) let
   `claudeProcessEvent` (`src/backend.zig:~540`) re-parse cost/token/subtype
   fields from a non-terminal line. Silent cost corruption, and any future
   "is it progressing?" check based on event arrival would be fooled.
4. **Why nothing killed it**:
   - `daemon.worker_timeout_minutes = 0` — the external `timeout` wrapper is
     disabled by design (breaks the CLI under io_uring; see the comment at
     `src/config.zig:113-116`, "until a Zig-native timeout is implemented").
   - `workers.max_budget_usd` had been raised to 1000 (operator choice).
   - `executor.runRole` passes **no timeout at all** — non-worker roles (qa,
     user, sre, researcher, strategist, founder) have zero wall-clock bound.
   - `CLAUDE_CODE_EXIT_AFTER_STOP_DELAY=60000` only applies after a turn
     *stops*; a blocked tool call is not idle.
   - `timeouts.max_idle_secs` exists in config (`src/config.zig:159-163`,
     default 600) and **is referenced nowhere in the codebase**.
5. **Why it took the swarm down, not just one role**: the daemon cycle is
   sequential (merger → qa → user → sre → … → spawn workers), so one wedged
   session stalls everything behind it.

Not the cause: the 429/529 strings in the transcript are the agent's own
analysis text; there are **0 `rate_limit_event`s**. `CLAUDE_CODE_UNATTENDED_RETRY`
is not implicated here (but see Layer 3 — it can produce the same shape).

## Layer 0 — classify heartbeats correctly (prerequisite)

Without this, a progress-based watchdog cannot tell "alive" from "advancing".

- `src/types.zig`: add `tool_progress = 5` to `EventType` (it is `enum(u3)`,
  values 0..4 used — room for 3 more; existing LMDB rows are unaffected since
  no stored value changes meaning). Match `"tool_progress"` in `fromJsonString`.
- `src/backend.zig` `claudeProcessEvent`: only set `acc.saw_result` and parse
  result fields for a **terminal** result (`type == "result"` carrying a
  `subtype`), never for a progress line.
- `src/backend.zig` `runSession` event loop (`~743-841`): do not insert
  `tool_progress` rows into LMDB — they are pure liveness signal (986 noise
  rows per incident). Still count them for liveness, see Layer 1.
- Fixes as a side effect: `cost_known` no longer flips true from a heartbeat.

## Layer 1 — progress-based stall watchdog (the real fix)

Reuse the existing, proven shutdown-watchdog pattern (green thread + pid
registry + TERM/KILL escalation).

- **Registry** (`src/backend.zig:273`): widen `active_children` from
  `[128]pid_t` to `[128]ChildSlot` where
  `ChildSlot = struct { pid, last_progress_s: u64 (atomic), started_s: u64, session_id: u64, label: [16]u8 }`.
  `registerChild` returns the slot index; `unregisterChild` clears it.
- **Stamping**: in `runSession`, after `processEvent`, update
  `last_progress_s` **only** for meaningful events — `init_event`, `message`,
  `tool_use`, `tool_result`, terminal `result`. Never for `tool_progress`.
- **Reaper**: `pub fn reapStalledChildren(idle_secs: u32, hard_secs: u32) u32`
  in backend.zig — TERM a slot whose `now - last_progress_s > idle_secs` (or
  `now - started_s > hard_secs`), KILL it 30s later if still alive, log
  `pid / session_id / label / idle seconds / limit`.
- **Driver**: `stallWatchdog` green thread in `src/orchestrator.zig`, spawned
  beside `shutdownWatchdog` (`:196`), polling every 15s, `defer _ = f.cancel(io)`
  — and it must tolerate `error.Canceled` (see `project_daemon_lifecycle` memory).
- **Termination path is already handled**: killing the child closes its stdout,
  the blocking `takeDelimiter` returns EOF, `runSession` returns with
  `exit_code = -SIGTERM`, and existing error handling marks the session
  errored. No new plumbing in worker/executor/merger.
- **Config**: wire the dead `timeouts.max_idle_secs`. Raise the default
  600 → **1800**: this model legitimately spends minutes inside one turn, and
  the metric is progress-idleness, not wall clock. Document that distinction.
- Optional v2: in `worker.zig`, treat `exit_code == -15` with a known
  `claude_session_id` like the existing 124 case, so a stalled worker resumes
  instead of dying (`src/worker.zig:313-320`).

## Layer 2 — bound the proximate cause (tool calls)

One line, large blast-radius reduction: cap how long any single Bash call can
run, in `buildFilteredEnvMap` (`src/backend.zig:46+`):

- `BASH_DEFAULT_TIMEOUT_MS` = `timeouts.bash_default_ms` (default **300000**)
- `BASH_MAX_TIMEOUT_MS` = `timeouts.bash_max_ms` (default **900000**)

Defaults chosen against real build times in these projects (cold `cargo build`
with deps ≈ minutes; `zig build test` similar) — 120s would kill legitimate
builds. With this alone the incident would have ended after 5 minutes.

## Layer 3 — wall-clock ceiling for every role

`executor.runRole` (`src/executor.zig:131-152`) passes no timeout. Add:

- `max_session_minutes` to `RoleConfig` (`src/role.zig:30-56`), plus a daemon
  default (`daemon.role_timeout_minutes`, suggest **45**).
- Enforce it through the same watchdog (`hard_secs`), **not** the external
  `timeout` wrapper — that path is known-broken under io_uring.
- Also cap `CLAUDE_CODE_UNATTENDED_RETRY`: it retries 429/529 indefinitely,
  which produces exactly this hang shape when a gateway rate-limits (our
  ai.starflinger.eu LiteLLM allows 4 parallel streams). The wall-clock ceiling
  bounds it; consider making the flag config-driven per backend.

## Layer 4 — make stalls visible before they're fatal

- Watchdog logs a WARN at 50% of the idle budget:
  `[watchdog] qa session 95 idle 900s (limit 1800s)` — a log-tail monitor
  catches it hours before the kill.
- `bees status` and the REST API: show running sessions with **age** and
  **last-progress age**. Today a wedged session is indistinguishable from a
  working one in `bees status`.
- Optional: queue an SRE trigger on every stall-kill so the swarm diagnoses
  its own hangs.

## Tests

- Unit: `EventType.fromJsonString("tool_progress") == .tool_progress`.
- Unit: `claudeProcessEvent` on a `tool_progress` line leaves `saw_result` false
  and cost/token fields untouched.
- Unit: registry stamping — stamp, advance a fake clock past the limit, assert
  the slot is selected for reaping (inject `now` for determinism).
- Integration: spawn `sleep 600` as the agent binary with `idle_secs = 5`;
  assert the watchdog TERMs it and `runSession` returns `exit_code < 0` within
  ~10s, and the session row ends `.err`, not `.running`.
- Regression: a fixture stream-json of 100 `tool_progress` lines and nothing
  else → session is killed, and LMDB holds 0 event rows from it.

## Rollout order

1. Layers 0 + 1 together (coupled by event classification) — restores the
   ability to detect a stall at all.
2. Layer 2 — cheap, immediate, independent.
3. Layer 3 with conservative defaults; observe for a day for false kills.
4. Layer 4 observability.
5. Resume the chatplugin swarm with `max_idle_secs = 1800`, bash timeouts on.

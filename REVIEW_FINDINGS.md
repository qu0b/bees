# Bees — Full-Codebase Fault-Prevention Review

Line-by-line review of all 35 Zig source files (~15,800 lines) by seven parallel
reviewers, one per subsystem. Every headline finding below was re-read and
confirmed against the source (and, for the LMDB double-free, against the vendored
`mdb.c`). Findings are deduplicated — several were reported independently by
multiple reviewers, which raises confidence.

Severity: **CRITICAL** = memory corruption / crash-loop / money loss / silent data
loss. **HIGH** = daemon hang, security boundary broken, permanent state corruption
under normal operation. **MEDIUM** = wrong-but-recoverable behavior. **LOW** =
hardening / latent.

---

## ✅✅ Iteration 2 — 10 fix rounds applied (build clean, 90 tests pass, ReleaseSafe OK)

All CRITICAL and HIGH items below were fixed and verified round-by-round.

1. **C1 LMDB double-free** — added `Store.commitTxnConsume(&txn)` that nulls the
   handle before checking commit, so the paired `errdefer abortTxn` can't double-
   free a txn LMDB already freed on commit failure. Applied at all 6 at-risk sites.
2. **C2 task-pool use-after-free** — worker now copies task name/prompt in a
   suspend-free `select()`→`dupe` sequence; lifetime invariant documented at both
   `select()` and `reloadPool`.
3. **C3 merger deletes live worktrees** — cleanup now only removes worktrees with
   merger-written terminal markers or stale (>24h) unfinished ones; a live worker's
   recent no-`.done` dir is preserved.
4. **C5 worker timeout dead code** — added `backend.appendTimeoutPrefix` wrapping
   all four backends in `timeout --signal=TERM -k 30 <secs>`, so a hung CLI is
   killed and exits 124, re-activating restart-on-timeout.
5. **C4 funding safety** — address/amount/option-injection validation as a
   `transfer()` precondition; per-request + cumulative caps (new `Funding` config +
   ledger); idempotency via status + `.tx` sidecar; status set to `approved` only
   after a confirmed transfer; ambiguous null-hash never retries. +4 tests.
6. **H6 stuck-running session** + **H7 merge ordering** — worker writes `.err` on
   spawn failure; merger runs the pipeline BEFORE finalizing, keeping branches and
   marking `.rejected` on rollback instead of losing work.
7. **H10 fail-open perms / H9 `sh` escape / exhaustive default** — worker perms
   fail closed; `Bash(sh *)` removed from worker+merger; `getDefaultForSessionType`
   exhaustive (conflict/fix→merger). +1 regression test.
8. **H1 sync HWM truncation / H4 Stmt reset / query enum guards** — min-gap
   watermark never skips a running session's future events; `exec()` resets via
   `defer`; every replica-int→enum conversion is panic-safe.
9. **H2 KB index self-poison / H3 APPEND destruction** — control-char `\u`
   escaping + UTF-8-boundary summary truncation + round-trip parse guard; APPEND
   writes at EOF so pages ≥32 KB are never destroyed. +2 tests.
10. **Config validation / duration underflow / CLI exit codes** — `Config.validate()`
    (name charset/length, counts ≥1, threshold ≥1, budget >0, base_branch not
    option-like) + `ignore_unknown_fields`; saturating `-|` on all three duration
    subtractions; CLI now exits 1 on parse/command failure. +1 test.

Remaining open items (design-level, deliberately deferred): H8 merger sessions run
permissionless by design (they must perform merges); H11 config-write→setup_command
exec; H12 DLQ concurrency; H13 per-cycle leaks; H14 API single-connection/no-auth;
plus the MEDIUM/LOW backlog below. Private-key-in-argv is unreached by the money
path (approve uses the default wallet / env key), so it stays a documented item.

---

## ✅ Iteration 1 — initial pass (build + 82 tests green)

1. **Build was broken** — `executor.zig:146` referenced an undeclared `cfg`, and
   `main.zig:364` called `runInitSession` with 5 of 6 args (commit `41f516a`
   threaded `claude_binary`/`pi_binary` through everything but missed these).
   Fixed by replacing executor's `default_backend` param with the full `cfg`
   (updated all 8 call sites) and passing `"claude"` to the init session.
2. **CRITICAL — stack-escape in `seed.zig:63/69`** — `buildSeed` returned
   `uuid[0..]`, a slice into a dead `[36]u8` stack local, kept for the daemon's
   whole life as every seeded session's `--resume` argument. Now `allocator.dupe`d.
3. **CRITICAL — OOB panic in `knowledge.zig` `extractUpdates`** — a directive on
   the final line with no trailing newline made `content_start = section.len + 1`
   → slice panic → daemon abort, triggered by any budget-truncated agent output.
   Clamped both `+1` advances; added `assert` and two regression tests.
4. **HIGH — unclamped `@intFromFloat` in `backend.zig:240-252`** — `"input_tokens":1e300`
   from child stdout panics the daemon. Routed all 6 numeric fields through a
   saturating `f64ToU32Sat` helper (also maps NaN→0).
5. **MEDIUM — malformed synthetic event JSON `backend.zig:304`** — stdin-variant
   suffix had one extra `}`; every stdin session stored invalid JSON as event 0.
6. **Test discovery gap** — `workflow`, `experiment`, `funding`, `context`,
   `knowledge` tests were never collected (missing from the `comptime` refAll
   block in `main.zig`). Added them; 7 previously-dormant tests now run, including
   the 5 `funding.zig` crypto-signing tests.

---

## 🔴 CRITICAL — remaining (need decisions or larger changes)

### C1. LMDB commit/abort double-free → heap corruption
`store.zig:44/54, 133/166, 202/236, 666`, and every external caller of the
`errdefer Store.abortTxn(txn)` + `try Store.commitTxn(txn)` idiom.
Confirmed in `vendor/lmdb/mdb.c:4210-4212`: `_mdb_txn_commit`'s `fail:` path calls
`_mdb_txn_abort(txn)`, which frees the txn. So on **any** commit failure (ENOSPC,
`MDB_MAP_FULL`, I/O error) the Zig `errdefer` aborts an already-freed txn →
double-free / use-after-free in the daemon.
**Fix:** null the handle immediately after calling commit, before the errdefer can
fire — `const rc = c.mdb_txn_commit(txn); txn = null; try check(rc);` (LMDB frees on
both success and failure; `mdb_txn_abort(null)` is a no-op). Apply at all sites and
inside `commitTxn`.

### C2. Task-pool use-after-free — workers deref freed `Task` memory
`orchestrator.zig:862 reloadPool` + `tasks.zig:127 select` + `worker.zig:383`.
Reported independently by 3 reviewers. `select()` returns an interior `*const Task`
into `pool.tasks`; workers get a shallow pool copy and run up to 60 min. When
`workers.count > merge_threshold` (e.g. 5/3), stragglers are still running when the
merge cycle calls `reloadPool`, which frees every task's `name`/`prompt` under
`c_allocator`. The straggler then calls `store.incrementTaskStat(t, task.name, …)`
on freed memory → garbage LMDB keys or crash.
**Fix (design):** `select()` returns an owned copy; or refcount/generation-tag the
pool; or defer freeing the old pool until `active_count == 0`.

### C3. Merger force-deletes live workers' worktrees
`merger.zig:549 cleanupOldWorktrees` + `git.zig:66 worktree remove --force`.
Removes every worktree lacking a `.done` marker — including worktrees of workers
still running (same `workers.count > merge_threshold` scenario). The running
worker's cwd is deleted and its branch `-D`'d mid-session; its commits are lost.
**Fix:** gate deletion on liveness — a `.active` marker written at worktree
creation and removed on exit, or skip worktrees younger than `worker_timeout`.
Assert no active worker owns a dir before removal.

### C4. Funding moves money with no cap and no validation
`funding.zig:286-387` + `main.zig:1533 approveFunding`.
`amount_usdc`, `token`, `recipient` come straight from AI-generated request JSON
and flow into `tempo`/`cast` argv with (a) **no spending cap** — per-request or
cumulative; (b) **no address/amount validation** — a `recipient`/`token` of
`--rpc-url=http://evil` or `--private-key` is a *positional* argv element ahead of
the real flags, so foundry/tempo parse it as an option (CLI-option injection → can
redirect RPC or swap the signing key); (c) status set to `"approved"` **before** the
transfer runs (`main.zig:1560` vs `:1570`), and the tx hash is never written back —
failure leaves "approved but not sent," and re-approval re-broadcasts (**no
idempotency key** → double-spend on partial failure); (d) private key passed as
`--private-key <pk>` argv is world-readable via `/proc/<pid>/cmdline`.
**Fix (policy + code):** hard per-request and cumulative caps (needs a number from
you); validate `to`/`token` as `0x`+40 hex and `amount` as `[0-9]+(\.[0-9]{0,6})?`
and reject any argv element starting with `-` (or insert a `--` separator); record a
request-id + tx hash and refuse to re-transfer an already-approved request; pass the
key via env/stdin, not argv.

*(Note: `bees funding approve` is human-invoked, so a person is nominally in the
loop — but they approve by ID against JSON an agent wrote, so caps + validation are
still required.)*

### C5. Worker timeout is dead code — a hung agent blocks a slot forever
`backend.zig`/`claude.zig:16 timeout_secs` is accepted and passed
(`worker.zig:270 → backend.zig:169`) but **no spawn function ever reads it** — no
`timeout(1)` wrapper, no deadline, no kill. `grep '"timeout"' src/` = 0. A hung
CLI blocks `reader.takeDelimiter` forever; `active_count` never drops; shutdown
always hits its 300s timeout. Exit code 124 can never be produced, so the entire
restart-on-timeout / session-resume loop (`worker.zig:300-306`) is unreachable.
Reported by 2 reviewers.
**Fix:** prepend `{"timeout","--signal=TERM","-k","30",secs}` to argv when
`timeout_secs > 0`, or add a deadline in the read loop that kills+waits the child.

---

## 🟠 HIGH — remaining

### Data integrity
- **H1. SQLite replica truncates event history.** `sync.zig:161-186` advances the
  events high-water mark using **running** sessions' ids (the code contradicts its
  own comment at :183; the intended `terminal_status_threshold` const at :23 is
  dead). After a session's first sync, every later event it emits is skipped
  forever → replica event history is truncated at the first snapshot for
  essentially every session. **Fix:** only fold `sess.id` into the HWM when
  `status != .running`; use a min-gap watermark for out-of-order completion.
- **H2. Knowledge index self-poisoning wipes the whole KB.** `knowledge.zig:463,
  489-500` — `extractSummary` cuts at byte 120 mid-UTF-8 and `appendJsonEscaped`
  passes raw control bytes; `std.json` then rejects the whole index →
  `parseIndex` returns null → the next `applyUpdates` starts from EMPTY and commits
  an index containing only the new page → **all prior knowledge orphaned**.
  Empirically reproduced. **Fix:** `\u00XX`-escape control bytes, truncate on a
  codepoint boundary, round-trip-parse before `putMeta`, and refuse to overwrite a
  currently-unparseable index (rebuild from directory instead).
- **H3. APPEND destroys pages ≥ 32 KB.** `knowledge.zig:286` — `readFileAlloc(…,
  max_page_size)` returns `StreamTooLong` at the cap → `catch ""` → `createFile
  (.truncate)` rewrites with only the new content. The shipped prompts tell agents
  to APPEND to exactly these pages. **Fix:** distinguish `FileNotFound` from
  `StreamTooLong`; use positional append; reject over-size pages instead of erasing.
- **H4. Stmt not reset on error + unchecked binds wedge the sync statements.**
  `sqlite.zig:133-137, 166-176` — `exec()` skips `reset()` when `step()` errors and
  all `sqlite3_bind_*` rc are discarded; one failed row leaves a cached statement in
  a halted/misused state for the process lifetime → later rows silently dropped or
  rewritten with stale bindings. **Fix:** `defer self.reset();`; check bind rc.
- **H5. `bees init` can half-initialize permanently.** `main.zig:514-528` — auth
  failure is detected by a substring scan over **every** stream line (including file
  contents Claude read) and checked **before** the exit code. A project whose files
  contain `authentication_error` makes a *successful* init abort after writing
  `config.json` but before tasks/roles/knowledge; re-running hits "already
  initialized." **Fix:** classify auth error only when the child exited nonzero and
  the marker was in a `result`/`system` event.
- **H6. Worker session stuck `running` on spawn failure.** `worker.zig:311` — if the
  first `runSession` errors, `last_result == null` and it returns without writing a
  status; the session stays `.running` until the next daemon restart. **Fix:** mirror
  `executor.zig:148` and write an `.err` header on the early-return path.
- **H7. Merged-but-broken loses work.** `merger.zig:144-155` deletes source branches
  and marks sessions `.merged` / tasks `.accepted` **before** the build/test pipeline
  runs (:175); on pipeline failure it `git reset --hard`s the base but the branches
  are already gone (commits only in reflog) and LMDB permanently records success.
  **Fix:** run the pipeline first; only delete/mark on success; on rollback mark
  `.rejected` and keep branches.

### Security boundary
- **H8. Deploy-restricted-to-merger is not enforced.** `security_profiles.zig` +
  `merger.zig:298,455` — the merger's real review/AI-fix sessions pass **no**
  permission mode, so `claude.zig` appends `--dangerously-skip-permissions`; the
  profile is never applied. And worker's allowed set (`Bash(npm *)`, `make`, `cargo`,
  `sh`) is a superset of merger's — any deploy a merger can run, a worker can too.
- **H9. `Bash(sh *)` (and `python`/`node`) makes every deny advisory.**
  `security_profiles.zig:88` — `sh -c "curl … | sh"` matches the allow and never
  matches the `curl`/`ssh`/`sudo` denies. The "no network access" comment is false.
- **H10. Fail-open worker permissions.** `worker.zig:174` — `if (role_config) |rc|
  rc.resolvePermissions()` with **no** `orelse getDefaultForSessionType(.worker)`
  (unlike `executor.zig:52`). A worker role file that sets only the model (or has a
  typo'd `security_profile`) yields null perms → the worker runs with
  `--dangerously-skip-permissions`. **Fix:** add the `orelse` fallback; make an
  unknown profile name a hard startup error.
- **H11. Config-write → arbitrary command execution.** `security_profiles.zig` +
  worktree setup — founder/SRE/strategist have unscoped `Edit`/`Write`, and
  `.bees/config.json`'s `build.setup_command` is run via `sh -c` in every new
  worktree. Any config-writing role can set `setup_command` to arbitrary code that
  the daemon later executes. **Fix:** scope `Write` away from `config.json`, or
  pin/validate `setup_command`.

### Resource / DoS
- **H12. DLQ concurrency + data loss.** `dlq.zig:36-101` — every `runSession` opens
  its own `DeadLetterQueue` on the same file; the read-truncate-rewrite is unsynchro-
  nized across concurrent workers (lost entries, or a crash mid-rewrite destroys the
  queue); a partial-replay rewrites from the *next* entry so the failed one is lost;
  and a queue ≥ 64 MB makes `readFileAlloc` error → `catch &[_]u8{}` → the next
  enqueue truncates the whole file. **Fix:** append-only enqueue, single-owner drain
  under a file lock, temp-file+rename compaction, and don't equate read-error with
  empty.
- **H13. Per-cycle leaks under `c_allocator` (target is <512 KB steady-state).**
  Reported by 4 reviewers. Never-freed each merge cycle: workflow `Parsed` arena
  (`workflow.zig:97`), `resolved.sources`/`knowledge_tags`
  (`orchestrator.zig:325`/`worker.zig:195`), `kb_updates` (`executor.zig:211`),
  the previous seed `context_blob` (up to `cache.max_bytes`, overwritten without
  free), candidate branch/wt strings, RoleSet, `result_subtype`/`stop_reason` dupes.
  **Fix:** run per-cycle work in an arena reset each cycle, or free explicitly.
- **H14. API server is single-connection with no read timeout.** `api.zig:88` — one
  idle client that connects and sends nothing blocks the accept loop forever → total
  API DoS. **Fix:** per-connection recv deadline; worker pool or bounded budget.

---

## 🟡 MEDIUM (grouped)

- **Weighted task selection doesn't exist.** `tasks.zig:127` `select()` is pure
  round-robin (`counter % len`); `weight`/`cumulative`/`total_weight` are computed
  and stored but never used. Strategist priority tuning is a silent no-op. *(The
  atomic-counter fix for the same-second-duplicate bug is itself sound.)* Reported by
  2 reviewers. Either implement weighted rotation or delete the dead fields + fix the
  docstring and strategist prompt.
- **Untrusted `tasks.json` panics the daemon.** `tasks.zig:189,195` → `store`
  asserts — empty name/prompt, prompt >64 KB, or overflowing `cumulative += weight`
  panic (asserts on untrusted strategist output). Convert asserts to skip-and-log +
  saturating add.
- **CLOCK_REALTIME duration underflow.** `worker.zig:345`, `merger.zig:322`,
  `executor.zig:182` do unsaturated `finish - now`; a backward NTP step → u64
  underflow panic. (`worker.zig:241` already uses `-|`.) Use `-|`, and prefer
  MONOTONIC for durations.
- **`EventHeader.timestamp_offset_ms: u16` wraps every 65.5 s** (`backend.zig:436`,
  `types.zig:429`); sessions run 60 min so nearly all events store a meaningless
  offset. Widen or store seconds.
- **Session status index desync.** `store.zig:210` `updateSessionStatus` deletes the
  old status-index entry using **caller-supplied** old status (can be stale) and
  ignores `mdb_del` rc; and `merger.zig:683` hardcodes old status `.done`. → phantom
  entries in `sessions_by_status`. Derive the delete key from the authoritative
  header just read; assert forward-only transitions.
- **Unchecked `@enumFromInt` on replica ints.** `query.zig:70-72,100,129` — an
  out-of-range/newer enum value from SQLite panics the CLI/API. Use
  `std.meta.intToEnum … catch` → "unknown".
- **`createSession` has no length caps** while `writeLenPrefixed` truncates at 65 535
  but `sessionValueSize` reserves the full length → uninitialized MDB_RESERVE bytes
  persisted (info leak), and the 8 KB copy buffer in `updateSessionStatus`
  (`store.zig:216`) can't fit large records → session stuck `running`. Add caps at
  creation (match `upsertTask`), grow the buffer.
- **Index-key structs are auto-layout but persisted.** `types.zig:328-382`
  `StatusIndexKey`/`TimeIndexKey` are `@ptrCast` to bytes as LMDB keys; only
  `@sizeOf` is asserted, not field order. Make them `extern struct` + `@offsetOf`
  asserts.
- **`getDefaultBranch` mangles `/`-containing branches** (`git.zig:180`,
  `release/2.0` → `2.0`) and mixes owned/literal return memory (`:186,201`) →
  invalid free if a caller frees. Strip known prefixes; always dupe.
- **git refs passed without `--` separator or leading-dash check** (`git.zig:71-163`)
  — `base_branch`/`project.name` from agent-writable config could be `-`-prefixed and
  parsed as git options. Append `--` before positional refs; validate at config load.
- **Log injection + races.** `log.zig:34-52` — shared `pos` written by concurrent
  workers with no lock (interleaved/overwritten records); agent-authored task names /
  result text are formatted unescaped so embedded `\n` forges audit lines; >4 KB
  messages dropped entirely. Guard `pos` with the pthread mutex (or O_APPEND); escape
  control chars; truncate with a marker.
- **Workflow `group`/`parallel`/`trigger`/`cycle` parsed but never executed.**
  `workflow.zig:37-58` + `orchestrator.zig:296` — the loop only handles flat role
  steps; a documented `group`/`cycle` workflow is silently ignored with a misleading
  "unknown role ''" warning. Either implement or reject-at-load.
- **Workflow/role parse failure silently reverts to defaults** with no log
  (`workflow.zig:94`, `role.zig:221`) — one typo swaps the whole custom
  workflow/role config. `role.zig validate()` and `workflow.zig validate()` are dead
  code that can't even compile (managed-ArrayList API); wire them up.
- **No config validation.** `config.zig` — `workers.count=0`, `merge_threshold=0`,
  empty/`/`-containing `project.name` all accepted; name flows unvalidated into
  `/tmp/bees-{name}` paths and the `bees-{name}.service` unit. `merge_threshold=0`
  makes the merger fire every 10 s; `count < threshold` idles the daemon forever. Add
  `Config.validate()`.
- **`std.json.parseFromSlice` without `ignore_unknown_fields`** (`config.zig:204`) —
  one extra key fails the whole parse; init then silently replaces the tailored
  config with defaults. Add the flag; report which field failed.
- **Predictable `/tmp/bees-{name}` on multi-user hosts** (`worker.zig`, `merger.zig`)
  — squattable dir/lock files; builds run there via `sh -c`. Verify ownership/mode
  after `makePath`, or use `$XDG_RUNTIME_DIR`/`.bees/worktrees`.
- **API: unauthenticated mutating POST/PUT + `Access-Control-Allow-Origin: *`**
  (`api.zig:185,626`) — any website can `POST http://127.0.0.1:3002/api/config`
  (DNS-rebinding); `handleReportGet` reflects the URL key into JSON unescaped
  (`api.zig:709`); a read handler leaks a reader txn on the getSession error path
  (`api.zig:363`, no `defer abort`). Add a loopback token; escape/validate; add the
  `defer`.
- **DuckDB module can't compile on this toolchain.** `duckdb.zig` uses
  `callconv(.C)` (0.16 wants `.c`) and the managed `ArrayList` API in `queryToString`
  — hidden by lazy analysis (no callers). `QueryResult.next()` is also off-by-one.
  The advertised analytics feature is dead. Fix before wiring it in.
- **`transactionHash`/token-decimals assumptions in funding.** `toUsdcUnits`
  hardcodes 6 decimals for a caller-supplied `token`; and doesn't validate digits
  (`"1.2.3"` → `"12.3000"`). `runCapture` caps stdout at 8 KB so a tx hash past the
  cap reads as "not sent" → retry double-spend. Look up decimals / allowlist tokens;
  validate; distinguish exit-0-unparsed from not-sent.
- **`resolveCliPath` global-buffer race + PATH fallback** (`funding.zig:571`) — two
  threads race on `tempo_path_buf`/`cast_path_buf`; a bare `"tempo"`/`"cast"` PATH
  fallback could run a planted binary *with the private key*. Thread-local buffers;
  require an absolute verified path for money commands.

---

## 🔵 LOW / hardening (representative — see per-module notes)

- Many `catch {}` / `catch continue` / `catch null` sites swallow errors that should
  at least log (fail-fast per project standards): git exit codes
  (`git.zig:65-145`), SQLite pragmas (`sqlite.zig:40`), DDL on init
  (`main.zig:451`), file-read failures for prompts (`backend.zig:78`), stdin write
  (`backend.zig:66`).
- Timestamp helper ignores `clock_gettime` rc and `@intCast`s `ts.sec` — negative
  RTC panics every module (`fs.zig:85`).
- Backend result strings `result_subtype`/`stop_reason` are duped but never freed at
  call sites (`worker.zig`/`executor.zig`) — leak per session.
- All CLI failures exit 0 (`main.zig:267`) — CI/systemd can't detect failure. Route
  errors to stderr; `std.process.exit(1)`.
- `spawnChrome` never `wait()`s → one zombie per Chrome lifecycle; `killChrome`'s
  `kill(pid,0)` probe succeeds on the zombie so the graceful wait always burns 5 s
  (`backend.zig:560-617`).
- Iterators map mid-scan LMDB/cursor errors to silent exhaustion
  (`store.zig:315,586`); `TaskIterator.next` recurses on short records (unbounded).
- `build.zig`: vendored C compiled without `-fno-sanitize=undefined`; LMDB has known
  alignment UB that can SIGILL under Debug/ReleaseSafe UBSan-trap. Add the flag.

---

## Suggested invariants to add (per project standards)

- `store.zig` create/update: `assert(task.len <= maxInt(u16))` (+ branch/worktree);
  postcondition `assert(offset == value_size)`; forward-only status-transition
  assert; check `mdb_del` rc (== 0 or `MDB_NOTFOUND`).
- `types.zig`: `extern struct` + `@offsetOf` asserts on both index keys; per-enum
  `isValidBits` used in every `fromBytes`; `fromBytes` returns `?View` on
  `len < @sizeOf(Header)` (mirror `TaskIterator`).
- `backend.zig`: `errdefer { child.kill(); child.wait(); }` right after every spawn;
  `assert(child.stdout != null)` before the read loop; bound the read loop with a
  max-events counter.
- `funding.zig`: address/amount validators + argv option-injection guard as
  preconditions; `assert(v < 2)` after the ecdsa recovery loop.
- `security_profiles.zig`: make `getDefaultForSessionType` exhaustive (drop
  `else => null`); comptime test that worker's allow-set isn't a superset of
  merger's deploy grants and excludes `Bash(sh *)`.
- `config.zig`: `Config.validate()` (name charset/length, counts ≥ 1, budgets finite
  > 0, quiet hours < 24); bounded `findProjectRoot` depth.
- `tasks.zig`: `assert(total_weight == tasks[len-1].cumulative)` in `select()`;
  convert untrusted-input asserts to skip-and-log.
- `knowledge.zig`: `assert(isValidKbPath(upd.path))` at the write boundary (not just
  parse); round-trip-parse the index before persisting.

---

*Generated during the review session. Uncommitted — discard if not wanted. The six
"already fixed" items are applied to the working tree and covered by `zig build` +
82 passing tests.*

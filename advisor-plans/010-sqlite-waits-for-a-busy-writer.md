# Plan 010: Concurrent SQL writes wait for the lock instead of failing

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before you continue. Touch only the files in scope. If a STOP condition occurs, stop and report. When done, update the status row for this plan in `advisor-plans/README.md`.
>
> **Drift check, run first**: `git diff --stat c1ecdf65 -- packages/zts/src/sqlite.zig packages/modules/src/data/sql.zig packages/runtime/src/server_test.zig docs/reliability.md docs/user-guide.md`
> If a file in scope changed, compare the Current state facts with the live code. If they do not match, stop and report.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug (reliability)
- **Planned at**: commit `c1ecdf65`, 2026-10-26
- **Source**: release review 2026-10-26, finding M7; earlier record: completeness audit H18

## Why this matters

Each pooled runtime opens its own SQLite connection, and no connection waits for a lock. Measured on 2026-10-26: `zttp serve examples/sql/sql-crud.ts -n 4 --sqlite todos.db` with 80 concurrent POST requests returned 44 responses of 201 and 36 of 500 (`Handler execution failed: error.NativeFunctionError`). With `-n 1`, all 80 returned 201. A write while an external `BEGIN EXCLUSIVE` held the lock failed in under 1 ms. The probable cause is `SQLITE_BUSY` with no busy handler. Step 1 confirms it.

## Current state

- `packages/zts/src/sqlite.zig`: `Db.openReadWriteCreate` and `Db.openReadOnly` both call the private `openPath`. It calls `c.sqlite3_open_v2` and closes the handle on failure; no busy timeout or journal configuration follows a successful open. No ZTTP source file calls `busy_timeout` or sets `journal_mode` (the vendored `packages/zts/deps/sqlite/` files define them). `Db` has an exec helper that calls `c.sqlite3_exec`.
- The SQL module exposes no transaction to handlers, so a module call never holds a lock across statements. Bundled SQLite is 3.53.3.
- `packages/zts/src/module_binding/capabilities.zig`, `openSqliteDbChecked`: the only production caller of `openReadWriteCreate` (`packages/tools/src/module_audit.zig` forbids direct calls elsewhere).
- `packages/modules/src/data/sql.zig`: `SqlStore.ensureDb` opens one connection per runtime. In `executeOne`, `executeMany`, and `executeExec`, any step result other than done or row raises `SqlError` with `sqlite3_errmsg`; the client gets 500. The message does not reach the log or the body.
- The handler deadline is 30 seconds (`ServerConfig.timeout_ms`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Setup | `unset DEEPSEEK_API_KEY; export ZIG_LOCAL_CACHE_DIR=<private dir> ZIG_GLOBAL_CACHE_DIR=<private dir>` | none |
| zts, modules, runtime, server, examples | `zig build test-zts`, `zig build test-modules`, `zig build test-zruntime`, `zig build test-server`, `zig build test-examples` | `0` each |
| Aggregate, spine, full gate | `zig build test`, `git add -A && zig build check-spine`, `bash scripts/verify.sh` | `0` each |
| Load probe | see Step 1 | counts as stated |

`curl` is aliased in this shell; use `/usr/bin/curl ... < /dev/null`. Stop every server you start.

## Scope

**In scope:**
- `packages/zts/src/sqlite.zig`: configure read-write connections after open.
- `packages/runtime/src/server_test.zig` or `packages/runtime/src/zruntime_tests.zig`: one concurrency test.
- `docs/reliability.md`, `docs/user-guide.md` (SQL section): one sentence each on concurrent writes.

**Out of scope:**
- Read-only connections used by the analyzer (`packages/tools/src/precompile_sql.zig`).
- One shared connection per process (that interacts with plan 009 and is larger).
- Error-message logging for `SqlError` (useful, but a separate change).

## Steps

### Step 1: Confirm the cause on a scratch copy

In a scratch build (not committed), print `sqlite3_extended_errcode` where `sql.zig` raises `SqlError`. Run the load probe: create `todos.db` from `examples/sql/schema.sql`, start `zttp serve examples/sql/sql-crud.ts -p <port> -n 4 --sqlite todos.db`, send 80 concurrent POST requests that the example accepts, count status codes, and read the printed codes. Discard the scratch edit.

**Verify**: the printed codes are `SQLITE_BUSY` (5) or an extended BUSY code. If they are not, STOP and report the codes.

### Step 2: Add a busy timeout

In `Db.openReadWriteCreate`, after `openPath` succeeds, call `c.sqlite3_busy_timeout(handle, 5000)`. 5000 ms is a policy bound, chosen to stay well below the 30-second handler deadline; it is not a performance estimate. Close the handle and return an error if the call fails.

**Verify**: repeat the Step 1 probe with the committed build: 80 of 80 return 201.

### Step 3: Decide on WAL by measurement

Only if Step 2 still shows failures, also run `PRAGMA journal_mode=WAL;` once after open through the existing exec helper, and repeat the probe. WAL leaves `-wal` and `-shm` files beside the database and does not work on network file systems, so add it only when the probe needs it. Record which variant the probe needed.

**Verify**: 80 of 80 return 201 with the chosen variant.

### Step 4: Add a regression test

Add a test with two connections opened through `Db.openReadWriteCreate` on one database file. On the first, run `BEGIN IMMEDIATE`, insert one row, and commit after a short measured delay (start a thread or use a second connection, since no module export can open a transaction). While the first holds the lock, write through the second; assert that the second write succeeds after the commit. Model it on existing SQL tests in `zruntime_tests.zig`.

**Verify**: the test passes, and it fails without Step 2.

### Step 5: Document

`docs/reliability.md`, and the `--sqlite` row of the flag table in `docs/user-guide.md` (the guide has no SQL section): concurrent writers wait up to 5 seconds for the database lock; a write that still cannot get the lock returns 500. If Step 3 added WAL, say so and name the extra files.

**Verify**: `zig build test-docs-drift` and `zig build test-doc-links` exit 0.

## Done criteria

- [ ] Step 1 confirmed the cause.
- [ ] The load probe returns 80 of 80 with `-n 4`.
- [ ] The new test passes and fails without the fix.
- [ ] All gates in the table exit 0.

## STOP conditions

- Step 1 shows a code other than BUSY.
- The probe still fails after Steps 2 and 3.
- A gate fails twice after reasonable local correction.

## Maintenance notes

- If plan 009's shared-state pointer later carries a shared SQL connection, revisit this plan's per-connection settings.

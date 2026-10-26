# Release fixes, 2026-10-26

This plan promotes advisory plans 007 to 014 into the work authority. The
release review of 2026-10-26 at `c1ecdf65` gave the verdict "not ready". Each
unit below closes one or more of its findings. The unit specification is the
advisory plan file; this file records the order, the owner decisions, and the
execution record.

## Units

| Unit | Specification | Finding | Status |
|---|---|---|---|
| 007 | [Every counted diagnostic is printed](../../advisor-plans/007-show-every-counted-diagnostic.md) | H4 | DONE |
| 008 | [The handler deadline fires in callbacks and recursion](../../advisor-plans/008-deadline-on-calls.md) | H2 | DONE |
| 009 | [One rate-limit store per handler pool](../../advisor-plans/009-one-rate-limit-store-per-process.md) | H5 | DONE |
| 010 | [SQL writes wait for a busy writer](../../advisor-plans/010-sqlite-waits-for-a-busy-writer.md) | M7 | DONE |
| 011 | [The documented CLI flows work](../../advisor-plans/011-cli-flows-match-the-docs.md) | M3, M4, M5, low items | DONE |
| 012 | [Claims say what they check](../../advisor-plans/012-claims-say-what-they-check.md) | M1; H1 and M2 interim | DONE |
| 013 | [Vacuous fault coverage and one acceptance rule](../../advisor-plans/013-one-acceptance-rule-and-vacuous-fault-coverage.md) | H3 | TODO; re-record window |
| U2, U3 | [Soundness plan](2026-10-21-soundness-plan.md), sections U2 and U3 | H1, M2 | TODO; re-record window |
| 014 | [Release preparation](../../advisor-plans/014-release-prep-after-fixes.md) | M6 | TODO; last |

Units 007 to 012 run in this order, one at a time, on local `main`. Unit 013,
U2, and U3 share one owner-run DeepSeek re-record. Unit 014 runs last.

## Owner decisions

On 2026-10-26 the owner answered "as recommended" to Decisions 16 to 20:

- 16 (a): a handler with no failable site is fault-covered by vacuous truth; `path_analyzer_version` moves from 4 to 5.
- 17 (a): `deploy` refuses any spec error, as `test` does, after the census in unit 013 Step 0.
- 18 (a): one shared rate-limit store per handler pool, recorded as a documented exception to request isolation.
- 19 (a): an unpinned `zttp verify` exits 0, labels the result unpinned, and writes `keyPinned: false`. The owner accepts that automation which reads only the exit status sees success.
- 20 (a): clear `SO_REUSEPORT` after `listen`; option (b), a hand-built listener with `SO_REUSEADDR` only, is approved as the fallback if (a) fails on Linux.

## Execution record

Each unit appends its commits, gate commands, and exit statuses here.

### 007: every counted diagnostic is printed

Commit `efb3a182` (release fix 007: print flow diagnostics and the failing sections in test and dev). Scope additions beyond the plan list: `packages/tools/src/precompile.zig` (re-export of the new helper) and `scripts/proof-swallow.allow` (row `runCheckOnParsedSource catch-block@13` for the new flow format call, covered by the existing CHECK facade reason).

Gates, each with exit 0: `zig build test-precompile`, `test-cli`, `test-zts-cli`, `test-cli-abuse`, `smoke-v1`, `test-proof-swallow`, `test`, and `git add -A <paths> && zig build check-spine`. With the flow branch reverted, `zig build smoke-v1` exits 1 on the new step. `bash scripts/verify.sh` is left to the coordinator.

Coordinator: `bash scripts/verify.sh` from an empty cache exited 0 at `b0b392af`.

### 008: the handler deadline fires in callbacks and recursion

Commit `a61e24b5` (release fix 008: poll the request deadline at call entry).

Change: `callBytecodeFunction` polls the deadline at call entry through the out-of-line `pollDeadlineAtCall`, behind `deadline_ns != 0` and `@branchHint(.unlikely)`. `checkDeadline` is `pub`. `renderNode` in `packages/zts/src/http.zig` keeps `RequestTimeout` (the `RenderError` set gained it). Plan deviations: the poll body sits in a `noinline` helper that returns `bool`, because the inline form moved unrelated bench rows by 2% to 3% (layout effect); `nested map callbacks time out` nests `map` three deep over a 100-element array literal, because `range()` is a lazy iterator with no `map`, `Array.from(range(n))` is refused with `HandlerTypeFault`, and an array literal of 255 or more elements fails with `HandlerError`.

New tests in `packages/runtime/src/server_test.zig`, each with `request_timeout_ms = 50` and measured at 50 ms handler time; with the poll removed each runs to completion (fib(30) about 0.94 s, nested map about 0.68 s, component about 0.93 s, `request_timeout_ms = 0`, Debug build). Each of the three fails without the `frame.zig` change; the component test also fails without the `renderNode` change (`error.HandlerError`).

Gates, each with exit 0: `zig fmt --check packages/zts/src packages/runtime/src`, `zig build test-zts`, `test-server`, `test-zruntime`, `test-panic-isolation`, `test-docs-drift`, `test-doc-links`, `test`, `check-spine`, `bench-check`. `bash scripts/verify.sh` is left to the coordinator.

Bench: `bench-check` is load sensitive. At load 2.8 to 4.2 both the parent commit and this change failed on `intArithmetic` against the stale baseline (parent 17.60%, change 15.49%); on the next pair at load 4.2 both passed (parent geomean 0.98251, regression 1.75%; change geomean 0.99073, regression 0.93%). Per-row medians of 9 alternating `zig build bench` runs (parent worktree against this change, ms; ratio change/parent), two rounds on the final code: functionCalls 3.943/3.971 and 3.966/3.986 (1.007, 1.005); recursion 9.024/9.073 and 9.052/9.059 (1.005, 1.001); stringConcat 7.503/7.734 and 7.530/7.666 (1.031, 1.018, a row that never enters the changed path); every other row within 1.5%. A parent-against-parent control run showed at most 1.0% between arms. Residual: `stringConcat` stays 1.8% to 3.1% above the parent, probably a code layout effect of the extra branch in `callBytecodeFunction`; this needs an owner decision under the plan's 2% rule.

Owner Decision 21 (a), 2026-10-26: accept the `stringConcat` row. The bench never arms a deadline, so the poll does not run there. Coordinator: `bash scripts/verify.sh` from an empty cache exited 0 at `a61e24b5`.

### 009: one rate-limit store per handler pool

Commits `1258db20` (release fix 009: record the per-pool rate store exception, D-013) and `942f3f7c` (release fix 009: one zttp:ratelimit store per handler pool). Owner Decision 18 (a): one shared store per pool, recorded as D-013 in `docs/decisions.md`, in `AGENTS.md`, and in `packages/modules/AGENTS.md`.

Change: `RateStore` holds a `std.Io.Mutex` that `check` and `reset` lock. `HandlerPool` creates one store, puts its pointer in `RuntimeConfig.shared_rate_store`, and frees it in `deinit` after `pool.deinit()` destroys every runtime. `HandlerInstance.initFromPool` calls `zq.modules.ratelimit.installShared`, which fills the ratelimit slot through `installSdkModuleState` with a no-op deinit when the slot is empty. Scope additions beyond the plan list: `packages/zts/src/modules/data/ratelimit.zig` (the zts-side shim, in the pattern of `modules/data/sql.zig`), its export in `packages/zts/src/modules/root.zig`, and a row in `scripts/zts-tiers.allow`. The runtime package cannot name `RateStore` without that shim, and `runtime modules` already has a boundary row, so `scripts/module-boundary.allow` is unchanged.

Plan deviation: the plan says sequential requests rotate through the pool slots. They do not. `LockFreePool.release` re-parks the runtime at the hint slot, so sequential requests reuse one runtime until it recycles after `max_requests` (64) requests; the release-review figure of 20 of 200 is four recycle windows of 5. The two tests in `packages/runtime/src/server_test.zig` therefore hold 4 runtimes at once through `acquireWorkerRuntime` and rotate 40 requests across them, and run 200 sequential requests across 3 recycles. Each expects exactly 5 admitted of limit 5. Without the `installShared` call both fail with `expected 5, found 20`.

Probe (`zttp serve -n 4`, handler `rateCheck("k", 5, 60)`, 200 sequential `/usr/bin/curl` requests): before 20 admitted of 200, after 5 admitted of 200.

Gates, each with exit 0: `zig fmt --check packages scripts`, `zig build test-modules`, `test-zts`, `test-zruntime`, `test-server`, `test-module-governance`, `test-flow-census`, `test-module-boundary`, `test-zts-layering`, `test-proof-swallow`, `test-docs-drift`, `test-doc-links`, `bench-check` (geomean 0.99321, regression 0.68%), `test`, and `git add -A && zig build check-spine`. `bash scripts/verify.sh` is left to the coordinator.

Bench: no worktree was allowed, so the parent comparison used `git stash -u` in place. Per-row medians of `zig build bench`, change against parent: round 1 (5 runs each) every row within 1.4% except `intArithmetic` 1.023, `jsonOps` 1.020, `objectCreate` 1.020, `stringOps` 1.020; round 2 (parent 7 runs, change 14 runs) every row within 1.3% (0.969 to 1.012). The 2% rows of round 1 reversed or vanished in round 2, so they read as noise.

Coordinator: `bash scripts/verify.sh` from an empty cache exited 0 at `d0b56950`.

### 010: SQL writes wait for a busy writer

Commit `323f4539` (release fix 010: SQLite connections wait for a busy writer).

Step 1: a scratch print of `sqlite3_extended_errcode` in `zttpSdkSqliteStmtErrmsg` (discarded) showed `extended_errcode=5 errcode=5`, which is `SQLITE_BUSY`, on every failed write. Probe (`zttp serve examples/sql/sql-crud.ts -n 4 --sqlite <db>`, 80 concurrent POST requests): before 75, 73, and 74 of 80 returned 201, and the rest returned 500 (3 runs). After: 80 of 80 returned 201 in 3 runs, and 200 of 200 with 8 workers. WAL was not needed, so the commit does not enable it and leaves no `-wal` or `-shm` file.

Change: `Db.openReadWriteCreate` calls `sqlite3_busy_timeout(handle, busy_timeout_ms)` with 5000 ms after open and closes the handle on error. The docs say so in `docs/reliability.md` and the `--sqlite` row of `docs/user-guide.md`. Plan deviation: the test sits beside the code in `packages/zts/src/sqlite.zig`, because `packages/runtime` tests do not import the SQLite wrapper and `packages/zts` tests run in `zig build test-zts`. It holds a `BEGIN IMMEDIATE` on one connection, writes from a second connection on another thread, commits after 200 ms, and expects the write to succeed. With the timeout set to 0 it fails with `expected null, found error.SqliteExecFailed`.

Gates, each with exit 0: `zig fmt --check packages/zts/src/sqlite.zig`, `zig build test-zts`, `test-modules`, `test-zruntime`, `test-server`, `test-examples`, `test-module-boundary`, `test-proof-swallow`, `test-docs-drift`, `test-doc-links`, `test`, and `git add <paths> && zig build check-spine`. `bash scripts/verify.sh` is left to the coordinator.

Coordinator: `bash scripts/verify.sh` from an empty cache exited 0 at `38e11cc3`.

### 011: the documented CLI flows work and fail clearly

Commits: `578f260c` (release fix 011: a busy port refuses a second server), `321f6882` (release fix 011: serve prints parse diagnostics), `f68ef10c` (release fix 011: proofs bundle works from the deploy output), and `e267e6de` (release fix 011: help flags, skipped stages, and wording).

Step 1 (M3), Decision 20: option (a) failed on Linux, so option (b) landed. The new test in `packages/runtime/src/server_test.zig` starts a server on port 0, expects a second `Server.start` on that port to return `error.AddressInUse`, then expects a third server to bind the same port after the first `shutdown`. At `38e11cc3` it fails on macOS with `expected error.AddressInUse, found void`. Option (a) (clear `SO_REUSEPORT` after `listen`) passed on macOS and failed in the `zttp-release-linux:0.17.0-arm64` container with the same message, as the kernel-source reading predicted. Option (b) is `listenExclusive` in `packages/runtime/src/server.zig`: `socket`, `SO_REUSEADDR` only, `bind`, `listen` (backlog 128), `getsockname`, wrapped as `net.Server`; it replaces `address.listen` for the public listener only. After (b): `zig build test-server` exits 0 on macOS, and exits 0 in the Linux container (fresh `git clone --no-local` of local `main` plus the Step 1 patch, `cp -r /src /work && zig build test-server` under `container run --rm --arch arm64`; the shell printed `zig-exit=0`). Manual macOS check: a second `zttp serve -p <busy port>` prints `Port N is already in use` and exits 1.

Step 2 (M4): `validateSourceAuthority` in `packages/runtime/src/runtime_cli.zig` renders the parse errors on `error.ParseError` and returns `error.SourceRefused`; `cmdServe` in `packages/runtime/src/dev_cli.zig` exits 1 for it with no usage hint. The plan said to export the renderer from `packages/tools/src/precompile.zig`; the runtime package does not import tools, so `renderParseRefusal` calls `zts.DiagnosticProjection.writeParseErrors`, as `handler_instance.zig` does. Before: `zttp serve: ParseError. Run \`zttp serve --help\` for usage.` After: `error[ZTS047]: statement is not terminated ...` with `<eval>:1:58` and the source line. The one-liners in `docs/cli.md`, `docs/user-guide.md` (two places), and the `serve` help text gain the semicolon, and the corrected one-liner serves `{"ok":true}`.

Step 3 (M5): `writeBundle` in `packages/runtime/src/proofs/bundle.zig` bundles the contract embedded in the binary when `--contract` is absent, refuses a `--contract` file that differs from the embedded bytes (`error.ContractMismatch`), and names the path for an unreadable input (`error.InputUnreadable`). Both errors are in `isExpectedUserError`. Before: `error: FileNotFound` and a stack trace. After: `zttp proofs bundle: cannot read contract '<path>': FileNotFound`, exit 1. `scripts/smoke-v1.sh` runs bundle, `verify --require-proof`, and the missing-path case after deploy. Pre-existing and left alone: `rejectSuspiciousPath` refuses an absolute path under `/var/` (the macOS temp directory) with exit 1 and no message, which made the first smoke edit fail until it used relative paths. `docs/verification.md` still shows `--contract handler.contract.json --binary ./my-service`; that command now fails with `ContractMismatch` when the file differs from the embedded bytes.

Step 4 (low): `zts compile --help` and `zttp proofs bundle --help` print usage and exit 0. `formatProofCard` prints `SKIPPED (parse failed)` for Types, Sound mode, and Strict ZigTS when `parse_errors > 0`, with a test in `packages/tools/src/precompile_check_tests.zig`. `cli_help.zig`, `docs/cli.md`, `docs/reliability.md`, and `README.md` carry the wording fixes. Deviation: the `docs/roadmap.md` release-provenance row stays. `zig build release-provenance` exited 1 at this commit, because `docs/convergence.json` is stale against changed files (including `scripts/smoke-v1.sh` from units 007 and 011). The coordinator owns the offline republish.

Each new test fails without its fix: the server test fails with the original listener, Step 2 fails with `expected error.SourceRefused, found error.ParseError`, the three bundle tests fail under one mutation each, and the card and bundle `--help` tests fail with the guard reverted. Every file was restored and compared with the saved copy.

Gates, each with exit 0: `zig fmt --check packages/runtime/src packages/tools/src`, `zig build test-server`, `test-zts-cli`, `test-precompile`, `test-cli`, `test-cli-abuse`, `smoke-v1`, `smoke-getting-started`, `test-docs-drift`, `test-doc-links`, `test-proof-swallow`, `test-script-reachability`, `test`, and `check-spine`. No contract golden, `policy-hash.txt`, or codegen replay changed. `bash scripts/verify.sh` is left to the coordinator.
Coordinator: `bash scripts/verify.sh` from an empty cache exited 0 at `c0c126d4`.

### 012: claims say what they check

Commits: `cda251d7` (release fix 012: zttp verify says when the key is not pinned), `c147830f` (release fix 012: disclose the env name rule and the mask bound), and `060aeed3` (release fix 012: document key pinning and the limits of zttp verify). Website commit `37e0450` in `../ZTTP-WEBSITE`. Owner Decision 19 (a): an unpinned `zttp verify` exits 0, says "key not pinned", and writes `"keyPinned": false`; no exit code was added. U2 and U3 have not landed, so Steps 3 and 4 are done.

Change: `renderClaimsHuman` and `renderClaimsJson` in `packages/runtime/src/verify_cli.zig` take `pinned`. Human output names the unpinned state and the `--trust-key` hint, and both states print the `signed_at` and host-binding line. The help text says the same. The new test `a pinned key is reported as pinned in human and JSON output` fails when the pinned label and the `keyPinned` value are forced to the unpinned form. The docs gained `--trust-key` and the provenance limits (`docs/cli.md`, `docs/user-guide.md`, `docs/threat-model.md`, `SECURITY.md`, a `docs/roadmap.md` limitation entry). `docs/proofs-and-receipts.md` has a table of the two open rows (env name rule, `mask` bound). Scope additions: `docs/verification.md` (the `proofs bundle` command uses `--binary` only, as in unit 011) and `../ZTTP-WEBSITE/static/sitemap.xml` (`lastmod`, per the website `CLAUDE.md`).

Gates, each with exit 0: `zig fmt --check packages/runtime/src/verify_cli.zig`, `zig build test-cli`, `test-docs-drift`, `test-doc-links`, `test`, and `git add -A && zig build check-spine`; in `../ZTTP-WEBSITE`, `deno task verify`. No contract golden, `policy-hash.txt`, or codegen replay changed. `bash scripts/verify.sh` is left to the coordinator.

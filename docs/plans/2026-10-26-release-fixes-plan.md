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
| 015 | this file, Execution record 015 | follow-ups from units 011 and 012 | DONE |
| 013 | [Vacuous fault coverage and one acceptance rule](../../advisor-plans/013-one-acceptance-rule-and-vacuous-fault-coverage.md) | H3 | IMPLEMENTED; waits for the re-record |
| U2, U3 | [Soundness plan](2026-10-21-soundness-plan.md), sections U2 and U3, with the 2026-10-26 validation corrections | H1, M2 | U2 IMPLEMENTED; U3 TODO; waits for the re-record |
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

On 2026-10-26 the owner answered "a" to Decisions 22 and 23:

- 22 (a): units 013, U2, and U3 run in one re-record window before the release. Fable and Codex astra validated U2 and U3 first; their corrections are in the soundness plan section "Validation corrections for U2 and U3".
- 23 (a): the three small findings from units 011 and 012 are fixed as unit 015 before unit 014.

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

Coordinator: `bash scripts/verify.sh` from an empty cache exited 0 at `70681af2`.

### 015: follow-ups

Owner Decision 23 (a) approved three small fixes found in units 011 and 012. Each is its own commit with a test that fails without the fix. Commits: `3bc48f75` (release fix 015: proofs bundle and verify name a refused path on stderr), `59e832e6` (release fix 015: port-in-use hint names neither serve nor dev), and `3f8ee71e` (release fix 015: zttp verify prints claims of any length).

F1: `rejectSuspiciousPath` in `packages/runtime/src/proofs/bundle.zig` keeps its rule (a path containing `..`, or starting with `/etc/` or `/var/`). It now takes the stderr writer and the command name, and prints `zttp proofs <bundle|verify>: refusing path '<p>': paths under /etc/ or /var/, or containing '..', are not accepted` before it returns `error.SuspiciousPath`. Exit status stays 1. Before, `zttp proofs bundle --contract "$(mktemp -d)/c.json" --out ...` on macOS (`/var/folders/...`) exited 1 with no output. The new test `bundle and verify name a refused path on stderr` fails when the print is removed (`TestExpectedEqual`).

F2: `formatAddressInUse` in `packages/runtime/src/runtime_cli.zig` now prints `Port N is already in use. Pass a different port with -p <PORT>.` for both `zttp serve` and `zttp dev`. Measured with a second `zttp serve -p` on a busy port: the old text said `zttp dev -p <PORT>`. The test `formatAddressInUse names the port and the remedy` now requires `with -p <PORT>` and no `zttp dev`; it fails against the old text. No document quoted the old line.

F3: `renderClaimsHuman` in `packages/runtime/src/verify_cli.zig` formats with the allocator that `run` passes through `writeClaimsHuman`, so no length drops the output. Before, an output longer than 4096 bytes printed nothing and `run` still returned exit 0. The new test `renderClaimsHuman renders in full past 4096 bytes` uses a 5000-byte `property_summary`; it fails when the output is capped at 4096 bytes (`OutOfMemory`). The command line was not run against a live attested endpoint with a long claim, so the CLI-level effect rests on that unit test.

Gates, each with exit 0: `zig fmt --check` on the three files, `zig build test-cli`, `smoke-v1`, `test-docs-drift`, `test-doc-links`, `test`, and `check-spine` (before each commit and again after this record). No contract golden, `policy-hash.txt`, or codegen replay changed. `bash scripts/verify.sh` is left to the coordinator.

Coordinator: `bash scripts/verify.sh` from an empty cache exited 0 at `b3d6e760`.

### 013: vacuous fault coverage and one acceptance rule

Status: IMPLEMENTED; waits for the re-record. Step 4 (the owner-run DeepSeek re-record) is not done. Decisions 16 (a) and 17 (a).

Commits in this repository: `0160ac41` (a handler with no failable I/O site holds fault_covered; `path_analyzer_version` 4 to 5), `7c6ee096` (build, compile, and deploy refuse what check refuses), `f24dffc6` (examples and doc handlers pass check, and the example gate runs it), `b77bdfe9` (regenerate the pins), `8675a48f` (documentation and CHANGELOG), and `92b5a8ee` (two probe handlers read the clock). Website commit `92f1cfd` in `../ZTTP-WEBSITE`. Drift check: only unit 007 and 011 to 015 edits overlapped (`formatFailureSections`, a flow-diagnostic print, doc lines); the Current state facts matched.

Step 1: the three `isCovered` rules (`fault_coverage.zig`, `contract_types.zig`, the decoder in `contract_json_parser.zig`) lost `total_failable > 0`. The compile path in `packages/tools/src/precompile.zig` stamps the fault record and the property for every handler. `proof_trace.zig` says "The property holds because the handler has no failable I/O site" for a zero-site handler. `path_analyzer_version` is 5, and the doc comment carries the reason.

Step 2: `runBuild` in `packages/runtime/src/build_command.zig` takes a new `check` capability. After the compile succeeds, it runs `runCheckOnlyFromSourceWithOptions` with `json_mode = true` (so the check prints nothing of its own) and returns the spec error count; a count above zero prints the stage count and the spec sections, as `zttp test` does, and returns `error.ProofAcceptanceFailed`, which the three commands already exit on with status 1. Deviation from the plan text: the plan said to read the compiled contract's spec diagnostics. The compile path never refreshes its spec diagnostics after it stamps properties, and its import scan uses a null reader, so its verdict can differ from `check`. The gate therefore runs the check analysis itself, which makes the rule one rule. `CheckResult.specErrors` is now public. Not changed: `zts compile` (the precompile command) and flow or canonical errors that compile already refuses on its own.

Before and after, in a scratch project with `zttp.json` (binaries at `c1ecdf65`+units and at `92b5a8ee`):

| Handler | Command | Before | After |
|---|---|---|---|
| Handler Shape (`/health`) | `check` | exit 1, ZTS500 `fault_covered` | exit 0 |
| Handler Shape | `test` | exit 1, ZTS500 | exit 0, 1 passed |
| Handler Shape | `deploy` | exit 0 | exit 0 |
| `Date.now()` with `Proof<Response, "deterministic">` | `check` | exit 1, ZTS500 deterministic | exit 1, same |
| `Date.now()` with capsule | `test` | exit 1 | exit 1 |
| `Date.now()` with capsule | `deploy` | exit 0, binary written | exit 1, ZTS500 printed once, "No binary was written" |

`zttp build` and `zttp compile` give the same two results as `deploy` for these handlers.

Step 0 census (`zttp check`, handlers under `examples/` with no `Proof<` capsule). Before (at `c1ecdf65`+units, failing default properties): autoloop/handler.ts [fault_covered, no_secret_leakage, optional_safe, pure, result_safe]; handler-with-imports.ts [fault_covered, pure]; secret-leak.ts [no_secret_leakage, pure]; sugar.ts [cost_bounded, fault_covered, idempotent, pure, read_only, retry_safe, stateless]; modules_all.ts [deterministic, fault_covered, idempotent, no_credential_leakage, no_secret_leakage, pure, retry_safe, stateless]; modules.ts [fault_covered, pure]; router.ts [fault_covered, pure] plus 3 ZTS606; match-handler.ts [fault_covered]; api-surface.ts [fault_covered, optional_safe, pure, result_safe] plus verify errors and ZTS606; guard-flow.ts [deterministic, fault_covered, idempotent, no_credential_leakage, no_secret_leakage, pure] plus 3 ZTS606. feature-probes.ts (27 ZTS613) and utils.ts (a helper) are not handlers. After Step 1: autoloop/handler.ts (same list), handler-with-imports.ts [pure], secret-leak.ts (same), sugar.ts [cost_bounded, idempotent, pure, read_only, retry_safe, stateless], modules_all.ts (same), modules.ts [fault_covered, pure], router.ts [fault_covered, pure], api-surface.ts (same), guard-flow.ts (same); match-handler.ts now has a warning only. Doc handlers in `docs/user-guide.md`, `docs/typescript.md`, and `docs/verification.md`: before, "Handler Shape", the todos snippet, and the HTML snippet failed on `fault_covered`, the validate snippet on `pure`; after Step 1 the first three pass and the validate snippet still fails on `pure`. Also found: the router snippet used `match` as a variable name (a parse error) and the `typescript.md` validate snippet passed `req.body` (a type error); `verification.md` line 188 and 216 snippets fail on purpose; the `Effects` snippet in `typescript.md` calls an undefined helper and is a fragment.

Fixes under 17 (a): a narrow capsule (`Proof<Response, "state_isolated" | "no_secret_leakage" | "injection_safe">`) on handler-with-imports.ts, sugar.ts, modules.ts, router.ts, api-surface.ts, and `tests/validate/format_handler.ts`; the capsule without `no_secret_leakage` on guard-flow.ts. api-surface.ts also replaced two ternaries on Result values with `if` blocks (they failed verification ZTS303, so deploy already refused it); its bytecode identity golden moved from `refused VerificationFailed` to a hash. guard-flow.ts returns the constant `"forbidden"` instead of `result.error`, because the flow check labels `jwtVerify(token, secret).error` secret (ZTS400); its bytecode hash moved. Doc handlers: capsule on the router and validate snippets in `docs/user-guide.md` and `docs/typescript.md`, `match` renamed to `found`, the router table holds a function declaration, `req.body ?? ""`, and a paragraph that says why module handlers declare a capsule. Excluded from the new `zttp check` pass in `scripts/test-examples.sh`, each with its reason in the script: feature-probes.ts, utils.ts, secret-leak.ts, spec-fails-idempotent.ts, autoloop/handler.ts (refusal demos), modules_all.ts (returns a `jwtSign` token that flow labels secret; the example exists to show that module), and sql-crud.ts (checked separately with its schema). The gate runs 27 `check` suites and its floor is 61 (34 + 27). `test-docs-drift`, `test-doc-links`, and `render-release-notes.sh` (against a draft `0.25.0` heading with a stub Highlights section) exit 0.

Step 3 pins: `policy-hash.txt` is now `886d6fafcb220d4c16e20b272d8db925cbd7d2808bf5442461ce5b4d8f5faf32` (was `ebb4b2b0a1456b5024a91fe5bfe41a7833c1ac19da923c9e6b7c0c8fa3624f96`). Regenerated with `bash scripts/update-expert-goldens.sh` (five goldens, only `policy_hash` moved) and `bash scripts/update-contract-goldens.sh` (`plain_ts.contract.golden.json`: `fault_covered` true and the new trace summary). Copied from failing-test output: nine contract hashes in `typed_frontend_tests.zig`, two receipt hashes in `pipeline_tests.zig`, the contract hash and two certificate hashes in `build_command.zig` (`direct source contracts preserve certificate bytes and proof IR`), the `search_rules` hash in `zts_expert_query.zig`, and two lines of `bytecode_identity_golden.txt`. Corpus: `handler_without_proof_capsule` now reads the clock; `.diag` rewritten with `zig build diagnostic-corpus-write -- handler_without_proof_capsule` and read against its comment. No other corpus case changed verdict. No property other than `fault_covered` changed on an existing case.

Changed tests, beyond pins: `fault_coverage.zig` (empty test list now holds); `precompile_check_tests.zig` (three sources read the clock, one `fault_covered` expectation is true, and the ten declaration, arrow, module, and lookup fixtures with their ZTS500 text); `standin_tests.zig` and `standin/source_grammar.zig` (starter handlers declare `Proof<Response, "state_isolated" | "injection_safe">`); `zts_expert_holes.zig`, `agent_protocol_check.zig`, and `cli_abuse_check.zig` (the probe handler reads the clock). The stand-in finding: before this change, a capsule-less baseline already failed ZTS500, so the differential veto accepted a synthesized route or env draft that broke the default profile; with a clean baseline the veto rejects it. The stand-in synthesizers still do not add a capsule to a capsule-less handler. That is open, and the tests now start from a handler with a capsule.

New tests, each failing without its fix (verified by reverting one fix at a time and running the step): `fault_coverage.zig` "empty test list produces a report that holds vacuously"; `proof_trace.zig` "a handler with no failable site says the property holds because there is none"; `contract_json_writer.zig` "a decoded zero-site fault coverage record keeps the verdict the writer stamped"; `precompile.zig` "compileHandler and the check path both hold fault_covered for a handler with no failable site"; `build_command.zig` "a spec error from the check stops the build before the artifact is written" and "a build refuses a handler that breaks its own declared capsule" (both `TestExpectedError` with the refusal off). "a build accepts the handler with no I/O and no capsule" passes with the refusal off and fails under the old Step 1 rule; that revert was not run.

Gates, each with exit 0: `zig fmt --check packages build tooling`, `test-zts`, `test-precompile`, `test-contract-golden`, `test-diagnostic-corpus`, `test-meta-drift`, `test-standin`, `test-flow-census`, `test-cli`, `test-expert-golden`, `test-examples`, `test-zruntime`, `test-docs-drift`, `test-doc-links`, `test-cli-abuse`, `test-agent-protocol`, `smoke-getting-started`, `smoke-v1`, and `check-spine` (before each commit). `deno task verify` in `../ZTTP-WEBSITE` exit 0. Expected red: `test-expert-app` exits 1 with only `expert_codegen_record.test.codegen baseline replays at the committed first-attempt green rate` (`error.StaleCodegenCassette`). The aggregate `zig build test` includes `test-expert-app`; its Build Summary shows one failed step (`208/211` steps succeeded) and the same single leaf failure. A first aggregate run also failed `agent_protocol_check` and `cli-abuse-check`; commit `92b5a8ee` fixed both. `bash scripts/verify.sh` and `docs/convergence.json` and `docs/coverage.json` (they still carry the old policy hash) belong to the re-record round.

Owner next step: run the re-record in one batch with U2 and U3, then the convergence and coverage republish.

### U2: every literal env name is secret unless the policy lists it in env.public

Status: IMPLEMENTED; waits for the re-record. U3 (the `mask` bound) is not done. Decisions D3(a), D7(a), D8(a), 22 (a), and 25 (a); recorded as D-014 in `docs/decisions.md`.

Commits: `0d17c2a1` (policy parser, analyzer, and contract disclosure), `d5a64079` (check, compile, and expert-tool plumbing), `e758c5f6` (tests, seeds, and fixtures), `933dc9f2` (pins), `d310a36d` (documentation and D-014), `1417922f` (curated `parsePolicyJsonOrNull`, so `packages/pi` needs no module-boundary row), and `6cf62783` (two tests that only the aggregate step ran).

Change: `HandlerPolicy.env_public` and `envPublic()` read `env.public` (needs `allow`, no subset rule). `FlowInterp.declaredLabels` gives `env` from `zttp:env` the `config` label only for an exact, case-sensitive literal name in `env_public`; the `sensitive` table is gone and `containsIgnoreCase` stays for MIME detection. `flow_analyzer_version` moves from 7 to 8. `CheckOptions.env_public`, `ContractOnlyOptions.env_public`, and `FlowChecker.env_public` carry the names. The check path parses the policy once (`parsePolicyJsonOrNull`) and keeps it alive; the single-module compile path passes `envPublic()`; the multi-module path and the check path disclose the names in the contract `env.public`. The contract-only path and `replay_runner` stay policy-less and conservative. `pi_goal_check`, `pi_repair_plan`, and `zts_expert_narrow` set `env_public` from the discovered policy (`discoverEnvPublic` in `packages/pi/src/tools/common.zig`), and `zts_expert_holes` passes the policy to the production check. The contract diff gains `env_public_changes` (removed is breaking, added is additive). `pr_gate`, `proof_enrichment`, `canonicalize`, and `agent_protocol_*` call the check with no policy and keep every name secret.

New `policy-hash.txt`: `0b6bd3b321d2d77ce5b2a8ffe2c68031244a86488fb0764fc697b2c3473a14fa` (was `886d6fafcb220d4c16e20b272d8db925cbd7d2808bf5442461ce5b4d8f5faf32`). It moved with the version bump and the ZTS602 help text.

Pins that moved: `policy-hash.txt`; five expert goldens (`meta`, `verify_paths_clean`, `verify_paths_missing`, `canonicalize_mixed`, `canonicalize_mixed_simulate`, policy hash only) through `bash scripts/update-expert-goldens.sh`; `modules_all.contract.golden.json` (the ZTS400 help text) through `bash scripts/update-contract-goldens.sh`; the nine `json_hash` values in `typed_frontend_tests.zig`; the two receipt hashes in `pipeline_tests.zig`; the frozen search hash in `zts_expert_query.zig`; the contract hash and the two certificate hashes in `build_command.zig`; the `optional_nullish_coalesce.ts` line and the `modules_all.ts` path in `bytecode_identity_golden.txt`; and the stand-in range hash in `range.zig` with `packages/pi/docs/standin-range.md` (regenerated with `zig build zttp-standin -- --range`). `EXPECTED_BUILTIN_HASH` did not move. `frozen_expected_bits` stays 214, `scripts/unseeded-rules.allow` is unchanged, and no `proof-swallow.allow` row was needed.

Fixtures and expectations: the census runs under `{"env":{"allow":["API_TOKEN","REGION"],"public":["REGION"]}}`; the three `REGION` false-proof contrasts and five precision entries (`modules.ts`, `bytes-boundary.ts`, `router.ts`, and both sibling-helper corpus cases) carry a `policy_source`; the `flow_checker_tests.zig` controls and the flow-interp env test use `env_public` variants; the `edit_simulate` sibling-module test carries a policy. Seeds `unchecked-optional` and `optional-property` carry `{"env":{"allow":["APP_NAME"],"public":["APP_NAME"]}}`, and `pol_policy` lists `APP_NAME` and `OTHER_NAME` in `public`. Deviation from the plan: the `dynamic-capability` seed cannot carry that policy, because an `env` section guards a computed name and ZTS602 stops firing (`CapabilitySeedHasNoFamily`). Its baseline and good draft now branch on the value instead of returning it. The corpus case `check/good/optional_nullish_coalesce.ts` branches on the value, `check/bad/unchecked_optional.diag` gains a ZTS400 line, and the two `secret_in_*.diag` goldens carry the new help text. `examples/modules`, `examples/routing`, and `examples/patterns` gain a `zttp.json` and `policy.json` that list the name each directory returns. `modules_all.ts` and its test moved to `examples/modules-all`, because `zttp serve` refuses a handler with errors once a project policy exists, and `modules_all.ts` returns a signed token that stays secret. The `zttp.json` policy path is the S2.14 answer: policy files beside an example take effect through `zttp.json`.

New tests: `handler_policy.zig` (accepts `public`, refuses it without `allow`, unknown key, bad entries, `declaredSections` unchanged, runtime policy unchanged); `flow_interp.zig` and `flow_checker_tests.zig` (every name secret with no policy, listed names clean, exact match, computed name); `precompile_check_tests.zig` (the S2.15 probes (a) to (d), a policy that does not parse, and disclosure); `precompile.zig` (compile path with and without `public`, and the multi-module disclosure); `build_command.zig` (a project build accepts the handler with `public` and refuses it without, and two policies that differ only in `public` serialize to the same runtime policy); `contract_json_writer.zig` (disclosure round trip); `contract_diff.zig` (public diff); `pi_repair_plan.zig` (the expert tools agree with the production check).

Bites, each observed on the full step and restored with `cmp`: the old name heuristic returned (eight tests failed, including the S2.15 (c) probe, the flow-checker control, and the interp test); a case-insensitive name match (three tests); an env section that accepts any key (the `handler_policy.zig` test); the compile path without `env_public` (the compile-path test), the multi-module path without disclosure (the graph test), and the check path without disclosure (the disclosure test); the contract parser dropping `public` (the writer round-trip test), the writer omitting it (the same test), and the contract diff ignoring it (the diff test); `checkCapability` with no policy text (the build test); `pi_goal_check` without `env_public` (the agreement test); the census with no policy, the `modules.ts` precision entry with no policy, and the `unchecked-optional` seed with no policy (each one failed its own gate). The example gate failed on `modules.ts`, `bytes-boundary.ts`, and `router.ts` before their policy files existed.

Gates, each with exit 0: `zig fmt --check packages build tooling`, `test-zts`, `test-modules`, `test-sdk`, `test-precompile`, `test-flow-census`, `test-diagnostic-corpus`, `test-standin`, `test-contract-golden`, `test-expert-golden`, `test-meta-drift`, `test-docs-drift`, `test-doc-links`, `test-module-audit`, `test-zts-cli`, `test-cli`, `test-examples`, `test-zruntime`, `test-proof-swallow`, `test-module-boundary`, `smoke-v1`, `smoke-getting-started`, and `check-spine`. `test-expert-app` and `zig build test` exit 1, and each has one failed test: `expert_codegen_record.test.codegen baseline replays at the committed first-attempt green rate` with `error.StaleCodegenCassette` (13 cassettes need the re-record). No provider was called.

Website commit `b5b365d` in `../ZTTP-WEBSITE` (`deno task verify` exit 0; not pushed or deployed).

Owner next step: run the re-record in one batch with U3, then the convergence and coverage republish.

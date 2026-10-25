# Zig book hardening worklog

Plan: [2026-10-25-zig-book-hardening-plan.md](2026-10-25-zig-book-hardening-plan.md).

## Decisions

- 2026-10-25: the owner chose 1a. Slot-buffer reuse waits for the Task 9 recycle p99.

## Execution

Tasks 1, 2, and 3 run in parallel. Each runs in its own detached worktree from local `main` at the plan commit. Each confirmed commit is cherry-picked onto `main`.

## Evidence

### Task 8 (F5, F6): committed `87c51ddd`, `e5af109c`

- The new test `init into an existing target returns ScaffoldTargetExists` killed the runner before the fix (exit 1 after the conflict message), and it passes after.
- The doctor `switch` compiles, so the compiler confirms that every listed name is in the set of `doctorCommand`.
- `zig build test-cli`: exit 0. `zig build smoke-v1`: exit 0.

### Task 3 (F2): committed `ac551e10`

- Three refusal tests (depth 600 through `renderToString`, `h()`, and a raw-text vnode) failed before the fix. The depth-511 tests pass in Debug.
- One vnode nesting level costs 2 depth levels, so about 256 nested elements fit.
- The worker ran `test-zts`, `test-examples`, `test-server`, and `test-zruntime` (all exit 0). The reviewer reran `test-zts` (exit 0).

## New findings

- F9 (confirmed by reading): `http.zig`. When a function component call fails, the error is logged, `renderNode` returns success, and the component renders as empty. This is the F8 class. The fix follows Task 4.

### Task 2 (F3, F4 edge): committed `1c6c6835`, `d00cd03b`

- `a jump past the i16 range is refused in codegen` panicked before the fix ("integer does not fit in destination type"). `registerShape` also got a checked cast (`TooManyShapes`). The worker listed each remaining `@intCast` in `codegen.zig` with its invariant, and the commit message records the list.
- At the `zts check` edge, an unmapped analyzer error is now one ZTS000 carrying the error name. `OutOfMemory` propagates unchanged. Only the `check` command has this mapping.
- The reviewer reran `test-zts`, `test-zts-cli`, and `test-cli-abuse` (exit 0).

### Task 4 (F8): committed `a32f661e`

- Callback errors now propagate from `map`, `filter`, `reduce`, `forEach`, `every`, `some`, `find`, `findIndex`, `toSorted`, `Array.from`, the `Result` methods, and the dict helpers. These builtins register through `wrapTry`.
- The three source-level tests failed before the fix with "expected error.HandlerError, found void".
- Deviation: the tests use a failing member call (`NotCallable`), because recursion past 1024 frames overflows the native stack in Debug first.
- Deviation: `doCall`'s `std.log.err` is skipped under `builtin.is_test`.
- The reviewer killed a leftover worker shell that was stuck on `rm -i` with a queued `perl` edit, and confirmed that the diff did not change.
- The reviewer reran `test-zts` and `test-zruntime` (exit 0).
- Follow-up: `doCall` turns every native error into `NativeFunctionError`, so a request timeout inside a callback reports as `HandlerError`.

### Task 1 (F1): committed `8a1ea9c2`

- Two bounds: 64 activations, and 256 native `eval`/`exec` levels. Both record `budget_limit`, which is fail-closed. The native bound was needed because 60 functions with 400-level call sites crashed the `fast` build too.
- Debug capacity measured: about 600 `eval` levels on an 8 MB stack.
- Trade-off: an expression nested deeper than 256 levels is now unproven. No corpus, census, or stand-in verdict changed.
- The `cli_abuse_check` call-chain cases pin exit 1 and ZTS500. Reverting both bounds makes them fail on SIGABRT.

### F9: committed `f83febe9`

- A failing component now fails the render with `ComponentFailed`. The test failed before the fix ("found void").
- `test-zruntime`, `test-zts`, `test-examples`, and `test-server`: exit 0, in the main tree.

## New findings

- F10 (confirmed by the Task 1 worker's probe): `effect_inference.zig` `includeReachableNodeEffects` recursed about 8000 frames on the 60x400 shape, and Debug `zts check` died with SIGABRT. The fix converts the walk to an explicit work stack.

### F10: committed `909a9704`

- `includeReachableFunctionEffects` and `includeReachableNodeEffects` now walk an explicit `std.ArrayList(NodeIndex)` stack.
- The test "reachable effects of deeply nested call sites do not recurse natively" covers the 60x400 shape.

### Task 5 (alias and literal chains): committed `87f7530f`

- `type_pool.zig` interns literal number, bool, and string types through `literal_memo`. A flat `+` chain now grows the pool linearly.
- New tests: "a 511-term addition chain type-checks" and "a 2500-alias chain reports no ZTS200". `cli_abuse_check` adds a 511-term `add_chain` case.
- The plan's ZTS200 claim for long alias chains did not reproduce. The remaining cost is quadratic time in `type_syntax.Store.validateOwnerRangesDoNotOverlap`. It is open.
- A separate ZTS200 appears for an intersection over a reference at 2 aliases. It is open and out of scope.

### P1 (names past 255 bytes): committed `766154dd`

- `addName` refuses a name longer than 255 bytes with `TypePoolCapacityExceeded`. Before the fix, the name was truncated, so two long names could share one node.
- A value string literal longer than 255 bytes widens to `string`.
- Review finding: the merged Task 5 memo key truncated the literal to 255 bytes and brought P1 back. The reviewer changed `addLiteralString` to key and compare the full value. The test "a literal string past 255 bytes fails closed instead of sharing a node" pins the fix.
- The Task 6 patch conflicted with Task 5 at the end of `type_checker.zig`. The reviewer resolved the diff3 markers by hand and checked the file with `zig fmt`.

### P3 (schema depth): committed `68c26be9`

- `validate.zig` refuses a schema nested deeper than `MAX_SCHEMA_DEPTH` (512) with `InvalidSchema`.

### Gates after the Task 5 and Task 6 merge

- The reviewer ran these on main: `test-zts`, `test-modules`, `test-proof-swallow`, `test-diagnostic-corpus`, `test-contract-golden`, `test-standin`, `test-cli-abuse`, `test-flow-census` (fail-open 0, over-refusal 0), and `check-spine`. All exit 0.

### Task 9 (request path benchmark): committed `036caa4f`

- `zig build bench -Doptimize=fast -- --request-path` drives 1024 requests through `HandlerPool.executeHandler` with one slot and the default policy (recycle every 64 requests).
- The section exits 1 unless 1024 requests complete and at least 16 recycles occur. The run observes exactly 16.
- The section runs only with the flag, so `bench-check` and `benchmarks/perf-baseline.json` do not change.
- Reviewer rerun under load 5.5 (provisional): normal request p50 about 1 us and about 4.2 allocator calls. Recycle request p50 4 us and p99 15-19 us. Rebuild request p50 70 us, p99 120 us, and 14 allocator calls.
- Rebuild requests are 1.6% of the requests, so they set the overall p99 (70 us). Slot-buffer reuse would move the overall p99, not only a rare tail.
- Limit: `compat.Instant` reads whole microseconds on macOS. A comment in the code names the fix.
- Open: the worker's `bench-check -Doptimize=fast` under load 5.8 failed on `functionCalls` (9.15% against an 8% limit). The baseline is from Zig 0.16.0. The probable cause is host load and the toolchain change. A run with load under 4 confirms it.

### Task 7 (analysis fuzz): committed `3e30b386`

- `packages/zts/src/analysis_fuzz.zig` runs 8 seeded inputs for each of 5 deep shapes through `TypeEnv`, `TypeChecker`, and `FlowChecker`. It is in the compiler tier, because the engine tier cannot import the checkers.
- Floors for each shape: inputs reach type checking and flow analysis, the call shapes reach the depth limits, a long alias name fails closed, and a planted type mismatch reaches the span oracle.
- Review findings fixed: the span oracle saw 0 diagnostics, so a planted mismatch now feeds it (3 spans observed). The statistics now print only when a floor fails. The iterations went from 20 to 8 to shorten the run.
- Probe: raising the span floor to 1000 made the test fail with exit 1.
- No crash and no unlisted error was found.
- Gates on main: `test-zts`, `test-zts-layering`, `test-docs-drift`, `test-doc-links`, `test-proof-swallow`, and `check-spine`. All exit 0.

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

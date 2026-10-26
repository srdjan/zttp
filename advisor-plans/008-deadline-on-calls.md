# Plan 008: The handler deadline fires in callbacks and recursion

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before you continue. Touch only the files in scope. If a STOP condition occurs, stop and report. When done, update the status row for this plan in `advisor-plans/README.md`.
>
> **Drift check, run first**: `git diff --stat c1ecdf65 -- packages/zts/src/interpreter.zig packages/zts/src/interpreter/frame.zig packages/zts/src/context.zig packages/zts/src/http.zig packages/runtime/src/handler_instance.zig packages/runtime/src/server_test.zig docs/reliability.md`
> If a file in scope changed, compare the Current state facts with the live code. If they do not match, stop and report.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED (hot path; bench-sensitive)
- **Depends on**: none
- **Category**: bug (reliability)
- **Planned at**: commit `c1ecdf65`, 2026-10-26
- **Source**: release review 2026-10-26, finding H2

## Why this matters

`docs/reliability.md` promises that a slow handler gets `504 Gateway Timeout` after 30 seconds and that its pool slot is replaced. The interpreter reads the clock only on loop back-edges. A handler whose work runs in nested `map` callbacks or in recursion never reads it. A release-review probe ran 67 seconds and returned 200. A few such requests hold every pool slot, and then every other client gets 503.

## Current state

- `packages/zts/src/interpreter.zig`, `Interpreter` field `backedge_count: u32 = 0`. Method `checkDeadline` (private `fn`) reads `compat.monotonicNowNs()` and sets `ctx.interrupt_requested` when `now >= ctx.deadline_ns`. Method `checkBackedge` (inline) increments `backedge_count`; when `ctx.deadline_ns != 0` it returns `error.RequestTimeout` if the flag is set, and calls `checkDeadline` when `backedge_count & 0x3FF == 0`.
- `packages/zts/src/interpreter/frame.zig`, function `callBytecodeFunction(self: *Interpreter, ...)`, first line:
  ```zig
  if (self.ctx.deadline_ns != 0 and self.ctx.interrupt_requested.load(.monotonic)) return error.RequestTimeout;
  ```
  The `run` function in the same file has the same flag-only read. Nothing on these paths sets the flag.
- Every call of a bytecode function reaches `callBytecodeFunction`. JS-to-JS calls go through the call opcodes and `call.doCall`, which passes `RequestTimeout` through. Bytecode callbacks from native loops (array `map`, `filter`, `reduce`, `forEach`, `every`, `some`, `find`, `findIndex`, `Array.from`, the `toSorted` comparator, the dict map, filter, and fold functions in `packages/zts/src/modules/data/collections.zig`, and `builtins/result.zig`) go through `builtins/helpers.zig` function `invokeCallback`, then the runtime's `callFunctionWrapper`, then `HandlerInstance.callFunction`, then `callBytecodeFunction`. `HandlerInstance.callFunction` calls a native callback (for example `map(String)`) directly; such a callback is a bounded native function. Every native loop propagates the callback error with `try`; the sort comparator keeps the first error and returns it after the sort.
- Exception: JSX rendering. `packages/zts/src/http.zig` function `renderNode` calls `ctx.call_function_callback` for a function component and maps every error except `OutOfMemory` to `error.ComponentFailed`. A timeout inside a component therefore loses its `RequestTimeout` identity; the server does not answer 504 and does not replace the slot for it.
- Recursion depth is capped at 1024 frames (`packages/zts/src/context.zig`). The cap does not bound time: `fib(40)` without loops never reads the clock.
- The deadline is armed by `HandlerInstance.armRequestDeadlineMs` in `packages/runtime/src/handler_instance.zig` and cleared by `clearRequestDeadline` in the same file. The 504 mapping is in `packages/runtime/src/server_connection_pool.zig`, so a pool-level test that sees `error.RequestTimeout` is sufficient. The bench (`packages/runtime/bench/benchmark.zig`) leaves `request_timeout_ms` at 0, so `deadline_ns == 0` there and the new call-entry code does not run. `checkBackedge` increments `backedge_count` on every back-edge whatever the deadline; the new call-entry increment runs only when a deadline is armed, so the bench's printed `backedge_count` does not change. `backedge_count` is otherwise read only by the bench and reset in the interpreter lifecycle code.
- Test to model: `packages/runtime/src/server_test.zig`, test "B2: per-request timeout aborts a slow handler and returns RequestTimeout". It builds a `HandlerPool` with `request_timeout_ms = 50` and a `for...of range(1e9)` loop.
- Docs: `docs/reliability.md` rows "Request read timeout" and "Handler execution timeout" cite `ServerConfig.timeout_ms` or edge `timeoutMs`; `edge` was removed and no CLI flag sets the timeout. The section on deadlines says they return `504` and replace the slot.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Setup | `unset DEEPSEEK_API_KEY; export ZIG_LOCAL_CACHE_DIR=<private dir> ZIG_GLOBAL_CACHE_DIR=<private dir>` | none |
| Analyzer and interpreter tests | `zig build test-zts > z.log 2>&1; echo $?` | `0` |
| Server tests | `zig build test-server > s.log 2>&1; echo $?` | `0` |
| Runtime root | `zig build test-zruntime > r.log 2>&1; echo $?` | `0` |
| Panic isolation | `zig build test-panic-isolation > p.log 2>&1; echo $?` | `0` |
| Bench | `uptime; zig build bench-check > b.log 2>&1; echo $?` | `0`; see Step 4 |
| Aggregate | `zig build test > t.log 2>&1; echo $?` | `0` |
| Spine | `git add -A && zig build check-spine > sp.log 2>&1; echo $?` | `0` |
| Full gate | `bash scripts/verify.sh > v.log 2>&1; echo $?` | `0` |

## Scope

**In scope:**
- `packages/zts/src/interpreter.zig`: make `checkDeadline` callable from `frame.zig` (`pub`).
- `packages/zts/src/interpreter/frame.zig`: poll the deadline at call entry.
- `packages/runtime/src/server_test.zig`: three new tests.
- `packages/zts/src/http.zig`: `renderNode` keeps `RequestTimeout` (Step 2b).
- `docs/reliability.md`: the two timeout rows and the deadline paragraph.
- `packages/zts/src/context.zig`: the comment that describes where the deadline is checked, if one exists.

**Out of scope:**
- New struct fields on `Context` or `Interpreter`. A field move costs about 2% on `propertyAccess` (measured in earlier rounds).
- Native loops other than JSX rendering. The call-entry poll covers them, because each bytecode callback enters `callBytecodeFunction`.
- Running this plan in a parallel worktree with plans 009, 010, or 011; they edit `docs/reliability.md` and `server_test.zig` too.
- A CLI flag for the timeout.

## Git/workflow guidance

- Work on local `main`. One commit, for example `interp: poll the request deadline at call entry`.
- Do not push.

## Steps

### Step 1: Poll at call entry

Replace the first line of `callBytecodeFunction` with:

```zig
if (self.ctx.deadline_ns != 0) {
    if (self.ctx.interrupt_requested.load(.monotonic)) return error.RequestTimeout;
    // Callbacks and recursion run without back-edges, so calls share the
    // back-edge counter that amortizes the clock read.
    self.backedge_count +%= 1;
    if (self.backedge_count & 0x3FF == 0) {
        self.checkDeadline();
        if (self.ctx.interrupt_requested.load(.monotonic)) return error.RequestTimeout;
    }
}
```

Make `checkDeadline` `pub`. Leave `run` unchanged.

**Verify**: `zig build test-zts` exits 0.

### Step 2: Add two timeout tests

In `server_test.zig`, beside test B2, add:
- "a recursive handler with no loop times out": a handler that calls a recursive `fib`-style function without loops. Size the input so the work takes between 0.5 and 2 seconds with `request_timeout_ms = 0` on this host; measure it, do not estimate it.
- "nested map callbacks time out": `range(N).map((x) => range(N).reduce(...))` with `N` sized the same way (0.5 to 2 seconds, measured).
Both use `request_timeout_ms = 50` and expect `error.RequestTimeout`, as B2 does. Use only syntax that the profile accepts (no compound assignment; explicit semicolons).

**Verify**: `zig build test-server` exits 0. Revert Step 1 locally: both new tests must fail, because the call returns a value instead of `error.RequestTimeout`. Restore Step 1.

### Step 2b: Keep the timeout identity through JSX components

In `renderNode` (`packages/zts/src/http.zig`), add `error.RequestTimeout => return error.RequestTimeout,` before the `else` arm, so a component timeout propagates. Check that `renderNode`'s error set and its callers accept the error; if a caller converts it again, propagate it there too. Add a test beside the Step 2 tests: a handler that renders a function component whose body runs past the deadline (sized as in Step 2) must return `error.RequestTimeout`.

**Verify**: `zig build test-server` and `zig build test-zts` exit 0; the new test fails without the `renderNode` change.

### Step 3: Correct the docs

In `docs/reliability.md`, state that the deadline is checked on loop back-edges and on function calls, including callbacks from native array and dict functions. Replace "Set with `ServerConfig.timeout_ms` or edge `timeoutMs`" with a statement that the CLI uses a fixed 30 seconds and that embedders set `ServerConfig.timeout_ms`.

**Verify**: `zig build test-docs-drift` and `zig build test-doc-links` exit 0.

### Step 4: Measure the bench

Run `uptime`, then `zig build bench-check`. Compare against a run of this plan's parent commit, built in a worktree from local `main`, under the same load. Report both medians. The committed baseline is already stale for this host (owner Decision 10 (a), 2026-10-26), so judge the change against the parent-commit run, not against the baseline.

**Verify**: every bench row, and in particular `functionCalls` and `recursion`, is within 2% of the parent-commit run, or the difference is reported to the owner.

## Test plan

- Two new tests in `server_test.zig` (Step 2).
- Existing tests that must stay green: B2, and the `zruntime_tests.zig` tests on a timeout inside a map callback and on deadline arming.
- All gates in the table.

## Done criteria

- [ ] The three new tests pass; the two Step 2 tests fail without Step 1, and the Step 2b test fails without the `renderNode` change.
- [ ] `test-zts`, `test-server`, `test-zruntime`, `test-panic-isolation`, `zig build test`, `check-spine`, and `bash scripts/verify.sh` exit 0.
- [ ] Bench result reported per Step 4.
- [ ] `docs/reliability.md` matches the behavior.

## STOP conditions

- `callBytecodeFunction` or `checkBackedge` does not match the Current state.
- A native loop swallows `error.RequestTimeout` instead of propagating it (a new test still returns success with Step 1 applied).
- A bench row regresses by more than 2% against the parent-commit run.
- A gate fails twice after reasonable local correction.

## Maintenance notes

- Reviewers should check that the poll runs only when `deadline_ns != 0`, so the no-timeout path pays one compare.
- A future native function that loops without calling back into bytecode must poll the deadline itself.

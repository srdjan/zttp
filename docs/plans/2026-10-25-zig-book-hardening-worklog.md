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

- F9 (confirmed by reading): `http.zig:572`. When a function component call fails, the error is logged, `renderNode` returns success, and the component renders as empty. This is the F8 class. The fix follows Task 4.

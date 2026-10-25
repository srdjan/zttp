# Eager recycle rebuild plan

Decision 3 (option A), chosen by the owner on 2026-10-25: when a pooled runtime recycles by policy, the releasing worker builds its replacement after the response is sent. The next request then finds a ready runtime.

## Evidence

- `zig build bench -Doptimize=fast -- --request-path` (commit `036caa4f`) measured a request on a rebuilt slot at p50 66-68 us and p99 97-106 us. A normal request takes about 1 us. Rebuild requests are 16 of 1024 and set the overall p99.
- A temporary phase probe measured the rebuild. `Runtime.create` takes about 27 us: `Context.init` about 11 us, `initBuiltins` about 14 us, and the request arena buffer 0.15 us. `HandlerInstance.initFromPool` takes about 39 us, and `loadHandlerCached` about 18 us. Buffer reuse was therefore rejected.
- The server releases a slot after it sends the body. `server.zig` calls `executeHandlerBorrowedCapturingFault`, and `ResponseHandle.deinit` calls `releaseForRequest` after the send.
- `Server.handleConnection` in `packages/runtime/src/server.zig` keeps one worker on a connection. The release runs in `handleSingleRequestSync`, before `waitForNextRequest` reads the next request on that connection.

## Expected effect (review finding)

- A client on its own connection, or on a network with a round trip above the build time: the request after a recycle no longer pays the build.
- A keep-alive client on loopback that sends the next request at once: that request waits the build minus the client turnaround. Pipelined bytes wait the full build. The gain is partial.
- A saturated pool, where workers wait in `acquireForRequest` (only when `--pool` is below the worker count): no gain. A waiter can wait up to one backoff step longer than today.
- No case gets worse in work done: one build per recycle, as today.

## Global constraints

- Isolation does not change: every runtime that serves a request is still built fresh by `Runtime.create` and `ensureRuntime`. No state passes from the dropped runtime to the replacement.
- The build adds no runtime beyond the one it replaces. (`max_size` is not a hard bound: 0 means unlimited, and `LockFreePool` can create more.) The build happens before `in_use` is decremented, so the releasing worker still holds the capacity. That ordering also makes `Server.shutdown`, which drains `getInUse()`, wait for an in-flight build. State that reason in a code comment.
- The eager build happens only on a policy recycle in `releaseForRequest`, and only when the dropped runtime had been built (`rt.user_data != null`). The second condition stops a double build when `ensureRuntime` itself failed: that path also reaches `releaseForRequest`, and a second build would fail the same way. A failed audit (`audit_poisoned`), a panic quarantine (`quarantineSlot`), and a timeout (`recycleSlot`) keep the on-demand rebuild. `invalidateRuntime` does not drop the slot and is out of scope.
- Known cost: when a handler error reaches a borrowed call at the recycle threshold, `releaseForRequest` runs before the server writes the 500 body, so that 500 waits for the build. This is rare and accepted.
- A failed eager build leaves the slot empty. The next acquire builds on demand, which is today's behavior, and that request reports any error. The failure is logged with `std.log.warn` and counted in a new `prebuild_failures` metric. It is not discarded silently.
- Do not edit the owner's uncommitted files, including `packages/runtime/src/server.zig` and `packages/runtime/src/test_runner.zig`.

Order: Task 2 comes first, so that the same benchmark can measure the code before and after Task 1.

## Task 1: build the replacement at release

Files: `packages/zts/src/pool.zig`, `packages/runtime/src/runtime_pool.zig`.

1. In `pool.zig`, add `pub fn createRuntime(self: *LockFreePool) !*Runtime`. It calls `Runtime.create`, sets `in_use = true`, and increments `size`. The slow path of `acquire` calls it instead of repeating those lines.
2. In `runtime_pool.zig`, add `fn prebuildReplacement(self: *Self) void`. It calls `self.pool.createRuntime()` and then `self.ensureRuntime(fresh)`, and it gives the runtime back with `self.pool.release(fresh)`. If `ensureRuntime` fails, it calls `self.pool.dropRuntime(fresh)`. Each failure increments `prebuild_failures` and logs with `std.log.warn`.
3. In `releaseForRequest`, read `rt.user_data != null` before `dropRuntime`. The recycle branch calls `prebuildReplacement` after `dropRuntime` and before the `in_use` decrement, and only when `policy_recycle and !audit_poisoned` and the runtime was built.
4. `getMetrics` reports `prebuild_failures`.

`release` calls `reset`, which counts one request, so a prebuilt runtime recycles after 63 real requests. `prewarm` has the same effect today. Keep it, and say so in a comment.

Tests, in `runtime_pool.zig` beside the existing pool tests, through `HandlerPool` only:

- "a policy recycle leaves a built runtime in the pool": one slot, `reuse_bounded_by_count`, with `max_requests` set low. After the request that recycles, `pool.pool.getAvailable()` is 1, the pooled runtime has `user_data` set, `recycles` is 1, and `prebuild_failures` is 0. The next request succeeds, and `pool.pool.getSize()` stays 1.
- "a panic quarantine does not prebuild": after the quarantine, the pool holds no runtime. Extend the existing "WorkerRuntimeLease deinit is a no-op after quarantine" test if it already sets up this state.
- "a failed handler build does not prebuild": use a handler source that fails to load, under `.ephemeral`. Each request fails, `prebuild_failures` stays 0, and the pool holds no runtime. Prewarm makes `HandlerPool.init` fail on such a source, so build the pool with good source and then switch to failing source with `reloadSourceGeneration`.

Revert check: each new test fails when the `prebuildReplacement` call is removed. Record the failure text.

## Task 2: measure the server latency model

File: `packages/runtime/bench/benchmark.zig`, in the `request_path` section.

The section switches from `executeHandler` to `executeHandlerBorrowed`. It reads time from `CLOCK_UPTIME_RAW` on macOS (nanosecond resolution) instead of `compat.Instant`, and removes the shortcut comment about the clock. It times the call until the handle returns (request latency) separately from `handle.deinit()` (release latency). That matches the server, which sends the body before release. It reports p50 and p99 of the request latency for all requests and for the request after a recycle. It reports p99 of the release latency for the recycle requests. The floors stay: 1024 requests and at least 16 recycles.

Acceptance, measured on HEAD before and after Task 1 in the same session, with alternating runs:

- The request after a recycle has a request-latency p99 at or below 10 us. Before the change it is about 100 us. With 16 samples, p99 is the maximum; the report says so.
- The release latency on recycle requests rises by about the rebuild cost. Record the value.
- `bench-check -Doptimize=fast` passes at load under 4.

## Gates

`zig build test-zts`, `test-zruntime`, `test-server`, `test-examples`, `test-panic-isolation`, `test-module-scope-panic`, `test-cli`, `check-spine`, and then `bash scripts/verify.sh` in a clean worktree.

## Docs

Run `git grep -n -i recycl docs`. Update each sentence that says the next request rebuilds the runtime. Today `docs/performance.md`, `docs/internals/architecture.md`, and `docs/user-guide.md` have no match, so the expected change is none.

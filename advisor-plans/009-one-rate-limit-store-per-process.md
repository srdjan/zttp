# Plan 009: zttp:ratelimit counts across every runtime of a handler pool

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before you continue. Touch only the files in scope. If a STOP condition occurs, stop and report. When done, update the status row for this plan in `advisor-plans/README.md`.
>
> **Drift check, run first**: `git diff --stat c1ecdf65 -- packages/modules/src/data/ratelimit.zig packages/zts/src/module_binding/bridge.zig packages/zts/src/module_slots.zig packages/runtime/src/runtime_pool.zig packages/runtime/src/runtime_config.zig packages/runtime/src/handler_instance.zig docs/reliability.md docs/decisions.md AGENTS.md packages/modules/AGENTS.md`
> If a file in scope changed, compare the Current state facts with the live code. If they do not match, stop and report.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (adds handler-visible mutable state shared between requests, an exception to the isolation rule in `AGENTS.md`)
- **Depends on**: owner Decision 18 (below)
- **Category**: bug (security-adjacent reliability)
- **Planned at**: commit `c1ecdf65`, 2026-10-26; revised after Fable review the same day
- **Source**: release review 2026-10-26, finding H5; earlier record: completeness audit H17

## Why this matters

`docs/reliability.md` tells operators to use `zttp:ratelimit` for limits such as per API key, because the server has no rate limit. The counters live in per-runtime module state. The pool keeps several runtimes and recycles each one after a fixed request count. A release-review probe with `rateCheck("k", 5, 60)` and 4 runtimes admitted 20 of 200 requests. With the default pool, the real limit is about the configured limit times the pool size, and it resets on each recycle. A brute-force guard built on this module does not hold.

## Owner decision required

Decision 18: how to fix H5.
- (a) One rate store per handler pool, behind a mutex, pre-installed into each runtime's existing ratelimit module-state slot. This is a deliberate, documented exception to the AGENTS.md rule "avoid introducing shared mutable state between requests": the store holds only integer counters keyed by strings, never JS values, and every access is locked. **Recommended.**
- (b) Keep per-runtime counters and document them. No code change, but the module stops being a usable rate limiter and `docs/reliability.md` must stop recommending it.

Steps 1 to 6 implement (a). If the owner picks (b), do only Step 6 with the per-runtime wording and skip the rest.

## Current state

- `packages/modules/src/data/ratelimit.zig`: `MODULE_STATE_SLOT = 8`. `pub const RateStore = struct` (fixed window). `getOrCreateStore(handle)` returns `sdk.getModuleState(handle, RateStore, MODULE_STATE_SLOT)`, or allocates a new store with `sdk.getAllocator(handle)` and registers it with `sdk.setModuleState(..., RateStore.sdkDeinit)`. Unit tests of `RateStore` are at the end of the file.
- `packages/zts/src/module_slots.zig`: `pub const Slot = enum(u4)` with `ratelimit = 8`.
- `packages/zts/src/module_binding/bridge.zig`: `pub fn installSdkModuleState(ctx, slot, user_ptr, sdk_deinit)` already lets host code pre-install SDK module state; it wraps the pointer in an envelope allocated from `ctx.allocator`, and the Context's teardown calls the given `sdk_deinit`. `packages/zts/src/modules/net/fetch.zig` and `packages/zts/src/modules/data/sql.zig` use it. With a no-op `sdk_deinit`, the installed store outlives runtime recycle.
- `scripts/module-boundary.allow` already lists `runtime module_binding`, so runtime code may call the bridge.
- `packages/runtime/src/handler_instance.zig`, `HandlerInstance.initFromPool(pool_rt, config: RuntimeConfig, policy_generation)`: applies the runtime config and capability policy, sets `pool_rt.ctx.host = self`, initializes builtins, and installs bindings. Pooled Contexts are reused across wrappers.
- `packages/runtime/src/runtime_config.zig`: `pub const RuntimeConfig = struct`, passed by value to each runtime init.
- `packages/runtime/src/runtime_pool.zig`: `HandlerPool` owns the `LockFreePool` and already owns locked shared state (`BytecodeCache` with `cache_mutex`). `compat.Mutex` is `std.Io.Mutex` (`packages/zts/src/compat.zig`).
- Live reload keeps the pool (`server.zig`, `reloadSourceGeneration`), so a pool-owned store survives a reload. `zttp test` builds one pool per suite.
- Labels: `rateCheck` returns `.internal`; `rateReset` returns `.unknown`. The contract extracts `rate_limit_key`. A shared store changes none of these.
- `packages/runtime/src/zruntime_tests.zig` has a test that expects the ratelimit slot to fill after a `rateCheck`; with pre-install it is already filled, so that assertion stays true.
- `zttp:cache` has the same per-runtime design (slot 5). This plan does not change it; Step 6 documents it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Setup | `unset DEEPSEEK_API_KEY; export ZIG_LOCAL_CACHE_DIR=<private dir> ZIG_GLOBAL_CACHE_DIR=<private dir>` | none |
| Modules, zts, runtime, server | `zig build test-modules`, `zig build test-zts`, `zig build test-zruntime`, `zig build test-server` | `0` each |
| Governance, census, boundary | `zig build test-module-governance`, `zig build test-flow-census`, `zig build test-module-boundary` | `0` each |
| Bench | `uptime; zig build bench-check > b.log 2>&1; echo $?` | see Step 5 |
| Aggregate, spine, full gate | `zig build test`, `git add -A && zig build check-spine`, `bash scripts/verify.sh` | `0` each |

## Scope

**In scope:**
- `packages/runtime/src/runtime_config.zig`: one optional pointer field on `RuntimeConfig` for the pool's shared rate store.
- `packages/runtime/src/runtime_pool.zig`: create, own, and free one store per `HandlerPool`; put its pointer into the pool's `RuntimeConfig`.
- `packages/runtime/src/handler_instance.zig`: in `initFromPool`, pre-install the store into the ratelimit slot when the slot is empty.
- `packages/modules/src/data/ratelimit.zig`: add a mutex to `RateStore`; expose a no-op deinit for the shared case.
- `packages/runtime/src/server_test.zig`: one test.
- `docs/reliability.md`, `docs/virtual-modules/README.md`, `docs/internals/capabilities.md`, `docs/decisions.md`, `AGENTS.md`, `packages/modules/AGENTS.md`: the exception and the semantics.

**Out of scope:**
- New fields on `Context` (a field addition moved `propertyAccess` by about 2% in earlier rounds).
- New SDK functions or bridge exports.
- `zttp:cache` behavior (documentation only).
- Labels, contract extraction, the rule registry, and binding summaries.

## Git/workflow guidance

- Work on local `main`. Two commits: (1) the decision record and AGENTS exception (Step 1); (2) the code, test, and docs.
- Do not run this plan in a parallel worktree with plans 008, 010, or 011; they edit `docs/reliability.md` and `server_test.zig` too.
- Do not push.

## Steps

### Step 1: Record the exception

Add a decision to `docs/decisions.md` in its existing format: the per-pool rate store is the one permitted shared mutable state between requests; it holds integer counters keyed by strings, never JS values; every access holds its mutex; the handler pool owns and frees it. Add one sentence with the same scope beside the isolation rule in `AGENTS.md` ("Security & Configuration Notes") and in `packages/modules/AGENTS.md`.

**Verify**: `git add -A && zig build check-spine` exits 0.

### Step 2: Lock the store

Add a `compat.Mutex` to `RateStore` and hold it in every public method. Add a public no-op function with the `sdk_deinit` signature for a store the module does not own.

**Verify**: `zig build test-modules` exits 0.

### Step 3: Own one store per pool and pre-install it

In `HandlerPool`, create one `RateStore` with the pool's long-lived allocator during init, put its pointer into the pool's `RuntimeConfig` field, and free it in `deinit` after every runtime is destroyed. In `HandlerInstance.initFromPool`, when that pointer is set and the ratelimit slot (`module_slots.Slot.ratelimit`) is empty, call `installSdkModuleState(pool_rt.ctx, slot, store, noop_deinit)`. `getOrCreateStore` is unchanged: it finds the pre-installed store.

**Verify**: `zig build test-zruntime` and `zig build test-module-boundary` exit 0.

### Step 4: Prove the limit

Add a `server_test.zig` test: a `HandlerPool` with at least 4 slots, a handler that calls `rateCheck("k", 5, 60)`, 40 sequential requests; assert that exactly 5 are admitted (`LockFreePool` rotates its free hint, so sequential requests reach every slot). Then repeat the release-review probe: `zttp serve -n 4` with the same handler and 200 sequential requests with `/usr/bin/curl ... < /dev/null`; expect 5 admitted. Stop every server you start.

**Verify**: the test passes and fails without Step 3; the probe admits 5.

### Step 5: Measure the bench

Run `uptime`, then `bench-check`. Compare against a run of this plan's parent commit, built in a worktree from local `main`, under the same load. Report both medians.

**Verify**: every bench row is within 2% of the parent-commit run, or the difference is reported to the owner.

### Step 6: Correct the docs

`docs/reliability.md`: rate-limit counters are shared across all runtimes of one handler pool and survive live reload; they are not shared across processes. `docs/virtual-modules/README.md`: one note for `zttp:ratelimit` (per handler pool) and one for `zttp:cache` (per pooled runtime; entries can differ between requests and vanish on recycle). `docs/internals/capabilities.md`: replace "Token bucket" with "fixed window".

**Verify**: `zig build test-docs-drift` and `zig build test-doc-links` exit 0.

## Test plan

- New pooled-limit test in `server_test.zig` (Step 4).
- Existing `RateStore` unit tests and the zruntime slot test stay green.
- All gates in the table.

## Done criteria

- [ ] A pooled server admits exactly the configured limit.
- [ ] Decision record and AGENTS exception exist.
- [ ] `test-modules`, `test-zts`, `test-zruntime`, `test-server`, `test-module-governance`, `test-flow-census`, `test-module-boundary`, `zig build test`, `check-spine`, and `bash scripts/verify.sh` exit 0.
- [ ] Bench result reported.

## STOP conditions

- The owner has not chosen Decision 18.
- `installSdkModuleState` does not behave as the Current state describes (for example, the envelope deinit frees the user pointer).
- `policy-hash.txt`, a contract golden, or the codegen replay changes.
- A bench row regresses by more than 2% against the parent-commit run.
- A gate fails twice after reasonable local correction.

## Maintenance notes

- Reviewers should confirm that no code path keeps a pointer into the store after unlock, that the store never holds a `JSValue`, and that the pool frees the store only after its last runtime.
- Deferred: a shared `zttp:cache`, and limits shared across processes.

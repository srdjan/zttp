# F2: request memory reset

Finding F2 (2026-11-04 review): a pooled runtime keeps request-time memory until the pool recycles the runtime. Measured at `e5073153`, ReleaseFast, 50,000 iterations per request: `toUpperCase` after `join` grew about 11.7 MiB per request. `cacheSet` of a joined string grew about 10.5 MiB per request, to 640 MiB at request 62.

The owner chose Decision 1 option (a) on 2026-11-04: route request-time allocations to the request arena. Two reviews checked a first draft of this plan: a Fable critic and a Codex astra fact-check. This version includes their corrections. The owner chose Decision 2 option (a) on 2026-11-04: run units G1 to G7, commit each on local `main`, and do not push.

## Status

| Unit | Status |
|---|---|
| G1 | Complete: `e1c01404`. Also moved response construction on the pooled path to `backing`, because the guard found one response header list per request |
| G2 | Complete: `a33a9c81`. Also fixed in `0a70385a`: `push` and the SDK array push now refuse a request value stored into module state (finding F17) |
| G3 | In progress. Also adds the escape check on `put_upvalue` (finding F17) |
| G4 to G7 | Not started |

## Cause

`Runtime.create` in `packages/zts/src/pool.zig#LockFreePool` passes `lifetime_arena`, a `std.heap.ArenaAllocator`, to `Context.init`. That arena reclaims only its most recent allocation on `free`. A pooled `HandlerInstance` uses the same allocator (`initFromPool` in `packages/runtime/src/handler_instance.zig#HandlerInstance`). These paths allocate through it at request time:

1. Builtins: 23 sites create result strings with `string.createString(ctx.allocator, ...)`. About 80 more `ctx.allocator` uses exist in `packages/zts/src/builtins/`, some for temporaries and some for array growth. `String.prototype.concat` builds its result with `ctx.allocator`.
2. The engine: `make_function` and `make_closure` allocate each function object with `ctx.allocator` and append it to `ctx.bytecode_functions`. `UpvaluePool.acquire` allocates each upvalue through the lifetime allocator, and no runtime path calls `UpvaluePool.release`. So each callback that a request creates, such as `items.map((x) => ...)`, stays until recycle.
3. The runtime package: `parseQueryString` and header key reads per request (`packages/runtime/src/runtime_http.zig`), the outbound `fetch` client and the response body it receives, response construction on the non-borrowed paths in `handler_instance.zig`, and header combining in `runtime_natives.zig`.
4. Modules: `sdk.getAllocator` returns `ctx.allocator` (25 sites in 12 files under `packages/modules/src/`). The `zts` module copies in `packages/zts/src/modules/` (`json_mod.zig`, `internal/util.zig`, `installStore` in `packages/zts/src/modules/data/sql.zig`) also use `ctx.allocator`. Module stores live across requests: a cache overwrite or eviction frees the old value into the lifetime arena, so the cache byte limit does not bound memory. The server installs the SQL store through `installStore`, and the rate-limit store is pool-owned and shared, so `RateStore` is not affected on the server path.
5. The request arena (`arena_mod.Arena`) uses the lifetime allocator as its backing. When a request exceeds `arena_size` (1 MiB on the server), the overflow nodes come from the lifetime arena.

The 64-request recycle applies to the `reuse_bounded_by_count` policy. The `reuse_bounded_by_ttl` and `reuse_unbounded` policies have no request cap, so their growth is bounded only by time or by the atom and hidden-class thresholds.

`HandlerInstance.init` (the non-pooled path) takes the caller's allocator. The defect applies to the pooled server path.

## Design

`ctx.allocator` stays the lifetime arena. It keeps runtime-lifetime structures: builtins installed at init, the handler's top-level code (loaded with `hybrid` off), and the module state envelope.

`Context` gets two ways to allocate at request time:

- `ctx.requestAllocator()` computes its result from `ctx.hybrid` at each call. It returns the request arena's `allocator()` when `hybrid` is set, and `ctx.allocator` otherwise. A stored field would point at the arena while `loadHandlerCached` turns `hybrid` off, so the plan does not use one. The C-ABI export writes the result into a slot on `Context` and returns a pointer to that slot.
- `ctx.state_allocator` frees memory. The default is `allocator`. `Runtime.create` sets it to `backing`. Module stores that live across requests allocate through it.

Each request-time allocation site gets one class:

- R (a JS value returned to the handler): `ctx.createStringPtr`, `ctx.createObject`, or `ctx.createArray`, which already choose the arena when `hybrid` is set.
- T (a temporary, or a value that the request uses and drops): `ctx.requestAllocator()`.
- S (module state that lives across requests): `ctx.state_allocator`, through `sdk.getStateAllocator`.
- P (runtime-lifetime growth): keep `ctx.allocator`. A P site must be bounded by the program, or by a recycle threshold that `release` in `packages/runtime/src/runtime_pool.zig#HandlerPool` checks (`max_dynamic_atoms`, `max_hidden_classes`). The handback names each P site and its bound.

A request-time closure becomes an arena object. It is not appended to `ctx.bytecode_functions`, because `Context.deinit` destroys each entry of that list and an arena object is dead after a reset. Upvalues that a request-time closure captures come from the request arena.

## Acceptance guard

A counting wrapper around the lifetime allocator records the number of allocations and the bytes it hands out. `RuntimeStats` reports both as `lifetime_allocs` and `lifetime_bytes`. The guard test runs a handler shape on a `HandlerPool` with one runtime. It warms up for four requests, then runs eight more identical requests and asserts that `lifetime_allocs` did not change. The expected change is 0, a literal. This check sees one missed allocation. A capacity measure sees only growth past an arena node boundary.

Each unit adds its own failing shapes to the guard table, then makes them pass. A final census runs every example handler under `examples/` through the guard. An example that needs the network or a credential gets an allowlist row that states why.

A repeat-run test checks lifetimes. It runs a shape twice on one runtime and asserts the exact same response body both times. The test sizes the arena so that the shape does not overflow, and it asserts `overflow_count == 0`. Debug builds poison only the bump buffer at reset, not the overflow nodes.

## Units

| Unit | Change | Main files | Failing shapes added | Model | Turn budget |
|---|---|---|---|---|---|
| G1 | Counting wrapper; `lifetime_allocs` and `lifetime_bytes` in `RuntimeStats`; `Arena.init(backing, ...)` so overflow comes from `backing`; the guard harness | `packages/zts/src/pool.zig`, the `HandlerPool` test file | 2,000 objects per request with `arena_size` 4096 (overflow) | Sonnet | 40 |
| G2 | `ctx.requestAllocator()`; builtin sites classified R, T, or P; `concat` | `packages/zts/src/context.zig`, `packages/zts/src/builtins/*.zig` | `join` then `toUpperCase` in a loop; `concat`; `split`; `JSON.stringify` and `JSON.parse`; `Object.keys`. Repeat-run for each. A request that assigns a builtin result to a module-level `let` gets `ArenaObjectEscape`, the same as a `join` result | Sonnet | 80 |
| G3 | Request-time closures and upvalues in the arena; teardown rule for `bytecode_functions` | `packages/zts/src/interpreter.zig`, `packages/zts/src/gc.zig`, `packages/zts/src/context.zig`, `packages/zts/src/object.zig` | `items.map((x) => ...)` in a loop; a closure that captures a request value; repeat-run | Sonnet | 80 |
| G4 | Runtime package and `zts` module temporaries | `packages/runtime/src/runtime_http.zig`, `handler_instance.zig`, `runtime_natives.zig`, `packages/zts/src/trace.zig`, `packages/zts/src/modules/**` | A request with a query string; a combined header; an outbound `fetch` to a local listener if one exists in the tests, or an allowlist row that says why not | Sonnet | 60 |
| G5 | `sdk.getAllocator` returns `ctx.requestAllocator()`; new `sdk.getStateAllocator` and export `zttpSdkGetStateAllocator`; stores use it, including `installStore`; module sites classified | `packages/zts/src/module_binding/bridge.zig`, `module_binding.zig`, `module_binding/capabilities.zig`, `packages/zttp-sdk/src/context.zig`, `root.zig`, `test_shim.zig`, `packages/zts/src/pool.zig`, `packages/modules/src/**`, `packages/modules/AGENTS.md`, SDK docs | `slugify` in a loop; `cacheSet` of one key with a joined value; repeat-run of `compileSchema` then `validate`, and `cacheSet` then `cacheGet`, across one reset; pool teardown after `cacheSet` under `std.testing.allocator` reports no leak | Sonnet | 80 |
| G6 | Census of example handlers through the guard | the `HandlerPool` test file, an allowlist under `scripts/` | every example handler | Sonnet | 40 |
| G7 | Measurement, no code | none | none | Opus | not applicable |

G7 reruns the review shapes for 72 requests in ReleaseFast at `02659dfa` and after G6. It runs a 10-minute sustained-load RSS comparison at both commits, because `state_allocator` brings back freeing for module stores. It compares interleaved `zttp-bench` binaries for performance, with an A/A control. A sub-minute version of each measurement runs first.

The units run in order. G2 to G6 use the guard from G1, and G5 uses `requestAllocator` from G2. Each unit runs in a worktree from local `main` with a private `ZIG_LOCAL_CACHE_DIR`. Each unit runs these gates unfiltered: the step that owns the new tests, `zig build test-zts`, `zig build test-modules`, `zig build test-cli`, `zig build test-zruntime`, `zig build test-server`, `zig build test`, and `zig build check-spine`. After G6, `bash scripts/verify.sh` and `zig build bench-check` run on `main`.

## Documentation

`docs/internals/architecture.md` states that request-scoped allocations are reset between requests. After G6 that statement becomes true, and the document names the four allocation classes. The SDK documentation names `getAllocator` as request-scoped and adds `getStateAllocator`. `packages/modules/AGENTS.md` gets the rule that module state allocates through `getStateAllocator`. Opus checks whether `../ZTTP-WEBSITE` makes a memory claim. If it does, Opus updates that claim and runs `deno task verify` there.

## Risks

- `state_allocator` brings back freeing for module stores only. The 2026-07 freelist growth came from about 1400 small blocks per runtime rebuild. G7 measures the new risk.
- The arena allocator grows nothing in place, so an `ArrayList` that grows in the arena copies and keeps the old buffer until reset. The per-request peak can rise. G7 measures the peak.
- G3 changes function object lifetimes. A request-time closure that escapes into persistent state must fail as an escape, not dangle. The G3 tests include that case.
- A pooled runtime with hybrid allocation off still frees into the lifetime arena. The server turns hybrid on by default, and no CLI flag turns it off. This stays open and is recorded.

## Out of scope

F4 to F6 and F8 to F16. `stringRepeat` returning `undefined` above 1 MiB. The `-m` limit, which arena allocations through `ctx.createStringPtr` do not check.

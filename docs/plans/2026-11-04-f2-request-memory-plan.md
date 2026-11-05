# F2: request memory reset

Finding F2 (2026-11-04 review): a pooled runtime keeps request-time memory until the pool recycles the runtime. Measured at `e5073153`, ReleaseFast, 50,000 iterations per request: `toUpperCase` after `join` grew about 11.7 MiB per request. `cacheSet` of a joined string grew about 10.5 MiB per request, to 640 MiB at request 62.

The owner chose Decision 1 option (a) on 2026-11-04: route request-time allocations to the request arena. Two reviews checked a first draft of this plan: a Fable critic and a Codex astra fact-check. This version includes their corrections. The owner chose Decision 2 option (a) on 2026-11-04: run units G1 to G7, commit each on local `main`, and do not push.

## Status

| Unit | Status |
|---|---|
| G1 | Complete: `e1c01404`. Also moved response construction on the pooled path to `backing`, because the guard found one response header list per request |
| G2 | Complete: `a33a9c81`. Also fixed in `0a70385a`: `push` and the SDK array push now refuse a request value stored into module state (finding F17) |
| G3 | Complete: `927fa36a`. Request-time closures, upvalue arrays, and upvalue boxes live in the request arena; `put_upvalue` refuses a request value in a box outside the arena (finding F17). `Context.request_scope` marks a running request, because a non-pooled runtime keeps `hybrid` set while it loads the handler |
| G4 | Complete: `54529e10`. Also moved `OutboundIo` on a pooled runtime to `backing`, because the fetch guard found a task record per lookup and connect. Open: trace replay (`jsonToJSValue` in `packages/zts/src/trace.zig`) builds objects on the lifetime allocator for each replayed result; replay only, no unit covers it |
| G5 | Complete: `4069d81e` |
| G6 | Complete: `09179721` and `fe8ad11c`. The census found that object spread built its key list on the lifetime arena (`09179721`). Three example handlers are not run, each with a reason in `packages/runtime/src/example_census_test.zig` |
| G7 | Complete. Results are in the section "G7 results". The headline shape (`cacheSet` of a joined string) is bounded but not flat: finding F19 |
| F19 | Complete: `2b45957e`. Overflow now comes from 256 KiB blocks that reset unmaps; the headline shape stays at 5.7 to 7.3 MB footprint over 100 requests |
| G8 | Complete: `04de59d5`. G7 found `stringConcat` 14.7% slower; `join` now builds long text in a freeing scratch buffer |

## G7 results

Measured on 2026-11-04 in ReleaseFast on one runtime (`zttp serve -n 1`), with 50,000 iterations per request.

| Shape | `02659dfa` | `04de59d5` |
|---|---|---|
| `join` then `toUpperCase` (t16), RSS | 31.7 MiB at request 1, 219.4 MiB at request 62 | 28.4 MiB at request 1, 28.8 MiB at request 62, 30.3 MiB at request 72 |
| `join` and `slugify` (t17), RSS | 44.9 MiB at request 1, 691.5 MiB at request 62 | 40.6 MiB at request 1, 41.2 MiB at request 62, 42.2 MiB at request 72 |
| `cacheSet` of a joined string (t7), physical footprint | 26 MB at request 1, 424 MB at request 40, 394 MB at request 100 | 37 MB at request 1, 418 MB at request 30, 417 MB at request 100 |

The baseline drops after request 64 because the pool recycles the runtime. An earlier t7 run at `4069d81e` stayed at 25 to 27 MiB RSS; the same binary later reached 418 MB. The cause of that difference is not known.

Benchmarks: 101 interleaved rounds of `zttp-bench`, with the median of each. The A/A control differs by at most 1.0%. Against `02659dfa`, `04de59d5` is 3.5% slower on `objectCreate` and 0.3% slower on `arrayOps`, and equal or faster on the other 11. Bisection puts the `objectCreate` cost on `0a70385a`: `push` now runs the GC write barrier, which the old `push` skipped. `zig build bench-check` passes: 9 benchmarks, geomean 0.98597.

A 10-minute sustained run (`hey -c 32`) of a light handler grew RSS from 22.5 MiB at 30 seconds to 73.2 MiB at 600 seconds at `02659dfa`, and from 27.8 to 69.5 MiB at `4069d81e`. Neither run reached a plateau, so the result does not settle the freelist risk.

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

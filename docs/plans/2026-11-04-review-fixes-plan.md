# Zig review fixes, 2026-11-04

The 2026-11-04 Zig review of `e5073153` reported 16 confirmed findings, F1 to F16.
The full review report is outside the repository. The owner approved the recommended order on 2026-11-04: F1, then F7, then F2 and F3. Each fix starts with a failing test.

## Status

| Unit | Status |
|---|---|
| F1 | Complete: `a9ca3a9c` |
| F7 | Complete: `d7a62413` |
| F3 | Complete: `02659dfa` |
| F2 | Complete: units G1 to G8, `e1c01404` to `04de59d5`. Results are in [the F2 plan](2026-11-04-f2-request-memory-plan.md). The headline `cacheSet` shape is bounded but not flat: finding F19 |
| F18 | Owner chose Decision 3 option (a) on 2026-11-05: read-only research, then a fix plan for approval |
| F19 | Owner chose Decision 4 option (a) on 2026-11-05: a failing test, then request-arena overflow in large blocks that reset returns to the system; then measure t7 again |

`bash scripts/verify.sh` passed on `main` at `02659dfa` and at `4a4274b9`.

## Units

| Unit | Finding | Files | Acceptance check | Model |
|---|---|---|---|---|
| F1 | `zttp proofs verify` reads the literal file `binary`, not the `binary` component that the manifest hashed | `packages/runtime/src/proofs/bundle.zig#verifySemantics` | A bundle whose `binary` component is `renamed.bin` reaches the semantic check of `renamed.bin`; the new test fails before the fix with `error.InvalidManifest` | Sonnet |
| F7 | An inferred array of 400 distinct literal records fails with `TypePoolCapacityExceeded`; regression from `1ea31118` | `arrayLiteralBindingType` in `packages/zts/src/type_checker.zig#TypeChecker` | The 400-record fixture checks without ZTS000; `zts check` exits 2 on 400 and 1000 records | Sonnet |
| F3 | `padStart` and `padEnd` allocate the requested length with no cap, then panic above 512 MiB | `packages/zts/src/builtins/string_builtins.zig`, `packages/zts/src/string.zig#checkStringLength` | A 2 MiB pad throws `RangeError`; `checkStringLength` refuses a length above the block header limit | Sonnet |
| F2 | Request-time allocations through `ctx.allocator` are not freed until the runtime is recycled | See [the F2 plan](2026-11-04-f2-request-memory-plan.md) | See the F2 plan | Sonnet, units G1 to G6 |

Each unit runs in its own worktree from local `main` with a private cache. Gates per unit: the named test step unfiltered, then `zig build test` and `zig build check-spine`. After all units, `bash scripts/verify.sh` runs on `main`.

## F2 cause

`Runtime.create` in `packages/zts/src/pool.zig` passes `lifetime_arena`, a `std.heap.ArenaAllocator`, to `Context.init`. Builtins create result strings with `string.createString(ctx.allocator, ...)`. Modules allocate through `sdk.getAllocator`, which returns `ctx.allocator`. `free` on an arena is a no-op, so this memory stays until the pool recycles the runtime after `max_requests` (64). Measured: one runtime grew about 10 MiB per request to 640 MiB at request 62. The arena is deliberate: it replaced allocator freelist growth that `pool.zig` records as 15 MB to 348 MB over 45 minutes.

## Decision 1: F2 fix

- (a) Recommended. Route request-time allocations to the request arena. Builtins create strings with `ctx.createString`. The SDK gets a request-scoped allocator for module temporaries and results. Module state keeps the lifetime allocator. A Debug arena audit and a per-request memory test guard the lifetimes.
- (b) Give `Context` a freeing allocator. This reopens the freelist growth that the lifetime arena fixed.
- (c) Lower `max_requests`. This bounds the growth but keeps the defect.

## Open findings

These findings stay open. Each was reproduced or traced at `e5073153`.

| Finding | Severity | Defect | Location |
|---|---|---|---|
| F4 | Medium | An artifact that cannot read its own file (mode 0111) starts as the plain runtime and serves the working directory with no proof | `packages/runtime/src/self_extract.zig#detectPath` |
| F5 | Medium | Idle connections hold workers for `timeout_ms`; 50 keep-alive clients against 28 workers gave 5 s and 10 s stalls | `handleConnection` in `packages/runtime/src/server_connection_pool.zig#ConnectionPool` |
| F6 | Medium | Under `--watch`, the shared contract lock is taken before the request read, so one idle socket stalls requests during a reload | `handleSingleRequestSync` in `packages/runtime/src/server_connection_pool.zig#ConnectionPool` |
| F8 | Medium-low | A static request for a directory sends a 200 header, then a 500 response inside the body, and keeps the connection open | `packages/runtime/src/server_static.zig#resolveStaticFile` |
| F9 | Low-medium | `writeFile` resets an existing file to mode 0600 and replaces a symlink with a regular file | `packages/zts/src/file_io.zig#writeFile` |
| F10 | Low | An invalid `Content-Length` or chunk size gets a silent close; RFC 9112 section 6.3 requires 400 | `handleSingleRequestSync` in `packages/runtime/src/server_connection_pool.zig#ConnectionPool` |
| F11 | Low | Parse recovery after ZTS044 rescans from a fixed offset; 40,000 lines take 2.5 s | `packages/zts/src/parser/type_syntax_store.zig#AdmissionPresentation` |
| F12 | Low | Debug builds crash the process on deep JS recursion; ReleaseFast returns 500 | `packages/zts/src/interpreter/frame.zig#callBytecodeFunction` |
| F13 | Low | Cache namespaces are never freed and are not counted against the cache limits | `getOrCreateNamespace` in `packages/modules/src/data/cache.zig#CacheStore` |
| F14 | Low | `parseIso` accepts `+` signs, unknown suffixes, and an out-of-range offset | `packages/modules/src/platform/time.zig#parseIsoString` |
| F15 | Low | `cacheStats()` without a namespace sums denied namespaces | `packages/modules/src/data/cache.zig#cacheStatsImpl` |
| F16 | Low | The plain runtime leaks four allocations on its no-handler error exit | not located |
| F17 | High | A request value stored into module state through a path with no escape check leaves a dangling pointer, and a later request reads another request's data. Found during F2 on 2026-11-04. `push` and the SDK array push are fixed in `0a70385a`; a store into a captured variable (`put_upvalue`) is fixed in `927fa36a` | `arrayPush` in `packages/zts/src/builtins/array.zig`, `put_upvalue` in `packages/zts/src/interpreter.zig` |
| F18 | High | `zts check` reports `deterministic`, `idempotent`, `retry_safe`, `read_only`, and `state_isolated` PROVEN for a handler that pushes onto a module-level array and returns its length; five identical requests returned 2 to 6. Observed at `e5073153`. Not checked: whether the deploy or certificate path refuses it | the property proofs for module-level mutable state |
| F19 | Medium | A request that calls `cacheSet` 50,000 times with a joined string grows the server's physical footprint by about 15 MB per request for about 27 requests. The footprint then holds at 418 MB through request 100 (`04de59d5`, ReleaseFast, one runtime). The same loop without `cacheSet`, and `cacheSet` of a constant without `join`, each stay flat. Of the 418 MB, 413 MB is in anonymous mappings and the malloc zone holds 8 MB. Probable cause: freed request-arena overflow blocks stay on `std.heap.smp_allocator` free lists that later requests do not reuse. Check: allocate overflow in chunks above the largest `smp_allocator` size class, so that reset unmaps them, and measure again | `packages/zts/src/arena.zig#Arena` |

`stringRepeat` returns `undefined` above 1 MiB, although its declared result is `string`. Unit F3 does not change it.

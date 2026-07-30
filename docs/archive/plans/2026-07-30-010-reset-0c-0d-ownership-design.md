# Reset 0c and 0d: runtime ownership and explicit invocation state

Items 0c and 0d of `docs/plans/2026-07-28-001-reset-simplification-plan.md`. Section 6.1 of
that plan already says these are one problem with one fix, so this design covers both.

0c: `HandlerInstance` owns the engine runtime, installed builtins, loaded handler, invocation
state, and reset lifecycle, owned directly by the pool, removing the runtime-to-pool
back-imports and the alias bridges.

0d: an explicit `InvocationContext` passed to native callbacks replaces the ambient state, and
a data-only `ExecutionSpec` mapped from `ServerConfig` at the composition edge stops durable
scheduling and recovery from depending on the whole server configuration.

## Measured state

### The cycle and the bridges are real, and small

`runtime_pool.zig` (1,239 lines) holds `HandlerPool` and back-imports `zruntime.zig` for
`Runtime`; its own header says so. `zruntime.zig:2276` closes the cycle with
`pub const HandlerPool = @import("runtime_pool.zig").HandlerPool`. Three more aliases sit
alongside it: `SystemRuntime` (`:94`), `PercentileTracker` (`:2268`), and `websocket_codec`
(`:33`). Nineteen files import `zruntime.zig`.

`zruntime.zig` is 7,084 lines: `Runtime` spans lines 167 to 2245 with 82 methods, and 96 test
blocks follow from line 2685.

### The ambient state, counted

| State | Site | Refs | Readers outside the owning file |
|---|---|---|---|
| `current_runtime` | `zruntime.zig:137` | 28 | `runtime_workflow.zig` (6 save/restore pairs), `runtime_http.zig` (3) |
| `call_function_callback` | `zts/http.zig:23` | 17 | `runtime_workflow.zig` (6 save/restore pairs) |
| `last_fault_location` | `zruntime.zig:143` | 5 | `engine_adapter.zig` (read-and-clear) |
| `active_ws_connection` | `zruntime.zig:2259` | 4 | `engine_adapter.zig`, `ws_runtime_callbacks.zig` |
| `aot_override` | `zruntime.zig:155` | 3 | none: file-local |

The 12 save/restore pairs in `runtime_workflow.zig` are the tell. Ambient state that has to be
saved and restored around every nested invocation is a parameter that was never declared.

`aot_override` is already file-local and needs no context; it is a test seam.

### `ServerConfig` below the server edge: two fields of 27

`ServerConfig` has 27 fields. What the code below the edge actually reads:

- `durable_recovery.zig`: `config.runtime_config` (line 436) and `config.handler` (line 441).
  Nothing else. Every other `config.` reference in the file is on `runtime_config`.
- `durable_scheduler.zig`: none. It stores `config: ServerConfig` and forwards it to
  `recoverIncompleteOplogsTracked`.
- `replay_runner.zig`: `config.handler` and `config.runtime_config` (the replay and trace paths
  it reads live on `runtime_config`).
- `test_runner.zig`: `config.handler` and `config.runtime_config`, plus six fields it reads
  off `runtime_config`.

So `ExecutionSpec` is exactly two fields, and the same two for all four callers:

```zig
pub const ExecutionSpec = struct {
    handler: HandlerSource,
    runtime_config: RuntimeConfig,
};
```

`HandlerSource` and `AppendedPayload` are declared in `server.zig` (lines 1440 and 1454), which
is why `handler_loader.zig` imports `server.zig` at all. They are pure data and belong with the
spec.

## Mechanism for the explicit context

The engine passes `*zq.Context` to every native callback. The runtime's threadlocals exist
because `Runtime` is a host-side wrapper that a `*Context` cannot reach: `Context` has no
host-data slot (43 fields, none of them one).

Adding one gives every callback an explicit path to its own instance:

```zig
// zts/src/context.zig
/// Opaque host-owned pointer, set by whoever created this Context. The engine
/// never dereferences it.
host: ?*anyopaque = null,
```

The runtime sets it once when it creates the Context, and each callback recovers its instance
with a checked cast instead of reading a threadlocal. This is the enabler for both items: the
same slot carries the `HandlerInstance` for 0c and the per-invocation state for 0d.

## Slices

Ordered so each one is independently verifiable and independently revertible. Later slices
depend on earlier ones; earlier slices are useful on their own.

1. **`ExecutionSpec`** (0d, second half). Move `HandlerSource` and `AppendedPayload` into a new
   data-only `execution_spec.zig` with `ExecutionSpec`; re-export the two unions from
   `server.zig` so existing spellings keep working. Convert `durable_scheduler`,
   `durable_recovery`, `handler_loader`, `replay_runner`, and `test_runner` to take
   `ExecutionSpec`. Map it from `ServerConfig` at the call site in `server.zig`.
   -> verify: those five files no longer import `server.zig`; `zig build test`,
   `test-zruntime`, examples.

   DONE 2026-07-30. `execution_spec.zig` now holds `HandlerSource`,
   `AppendedPayload`, and `ExecutionSpec`; `server.zig` re-exports the two unions and
   exposes the mapping as `ServerConfig.executionSpec()`, called at the four
   `runtime_cli.zig` sites. All five files stopped importing `server.zig`; the only
   remaining importers are the CLI, live reload, and the server's own tests. The
   `config` parameters became `spec` in the three files where the type changed - taking
   care not to rename the `config: RuntimeConfig` parameters in the same files, which a
   blanket rename did hit and which was reverted. Test collection for the new file was
   confirmed by breaking its test and watching `zig build test` fail, since a file
   reachable only through an import chain is exactly where the collection hazard lives.
   `zig build test`, `test-zruntime`, and 43/43 examples pass.

2. **`Context.host`** (enabler). Add the slot, set it from the runtime, and prove it round-trips
   through a native callback in a test. No behavior change yet.
   -> verify: `zig build test-zts test-zruntime`.

   DONE 2026-07-30. `Context.host` plus `Runtime.fromContext`. Both init paths set the
   slot and `deinit` clears it, which matters on the pooled path: that Context outlives
   the wrapper and is handed to the next one, so a stale pointer would be a
   use-after-free. Three tests pin it, including the pooled re-point-and-clear cycle and
   the null case for an engine-only Context.

3. **Retire `current_runtime` from `runtime_http.zig`** (0d). Its three reads become
   `ctx.host` casts. This is the smallest ambient-state removal and it exercises slice 2 on
   the file whose own header documents the problem.
   -> verify: `test-zruntime`, `test-cli`, the outbound-HTTP example tests.

   DONE 2026-07-30. All three reads gone: `beginBodyRead` already had the Context,
   `fetchSyncNative` had it as `ctx_ptr` and was reading the threadlocal anyway, and
   `httpRequestNative` was discarding its `ctx_ptr` with `_`. The file no longer mentions
   `current_runtime`. Full `verify.sh` green.

4. **Retire `current_runtime` and `call_function_callback` save/restore from
   `runtime_workflow.zig`** (0d). Twelve save/restore pairs become an explicit parameter.
   -> verify: the durable and workflow example suites, which are the only end-to-end coverage
   of nested invocation.

   DONE 2026-07-30, and it went further than "an explicit parameter". The reason both
   threadlocals needed save/restore is that `CallFunctionFn` had no context parameter, so
   the engine could not tell the host which runtime to call back into. Giving it one
   (`fn (ctx, func, args)`) and storing the callback on the Context makes a nested
   dispatch harmless: the sub-handler has its own Context, so it cannot clear the
   caller's callback. That threaded `ctx` through 12 `getCallFn()` sites in the array,
   result, and helper builtins, including one comparator closure that had to capture it.
   With `callFunctionWrapper` taking a Context, the last reader of `current_runtime` was
   gone and the threadlocal was deleted outright, along with three test writers that only
   existed to feed it. `clearThreadStateAfterPanic` is down to one line.

   `current_runtime` and `call_function_callback` are both retired; the remaining
   save/restore in `runtime_workflow.zig` is `current_interpreter` alone, which is
   engine-owned and nulled by the panic path.

   Verified: `test-zts`, `test-zruntime`, `zig build test`, 43/43 examples,
   `test-panic-isolation`, `zig fmt --check`.

5. **`active_ws_connection` and `last_fault_location`** (0d). Both are read-and-clear channels
   between the runtime and `engine_adapter.zig`; they become fields on the invocation state.
   -> verify: `test-zruntime`, the WebSocket examples, the panic-isolation smoke.

   DONE 2026-07-30, and one of the two was not a channel at all. `active_ws_connection`
   had no reader: `ws_frame_loop.zig` saved, set, and restored it around three dispatch
   sites, and nothing in between read the value. The docstring claimed the WebSocket
   `send`/`close` callbacks fell back to it, while `ws_runtime_callbacks.zig`'s own header
   said those callbacks take the connection id from their first JS argument. The
   threadlocal, its two adapter accessors, and the nine frame-loop lines are deleted.

   `last_fault_location` is a genuine handoff and became a `Runtime` field. The server
   builds the 500 body after the runtime is released, so the value has to leave the
   runtime at the pool boundary: `executeHandlerBorrowedCapturingFault` copies it into an
   out-parameter on the error path, and `executeHandlerBorrowed` delegates with null so
   the other 29 call sites are untouched. `server.zig` names the type as
   `engine.FaultLocation` rather than importing the engine, which the purity script
   requires. The adapter's test now drives a real type fault through a runtime instead of
   poking a threadlocal.

   All five ambient-dispatch threadlocals from the 6.1 census are now gone except
   `aot_override`, which is file-local test-only state and needs no context.

6. **`HandlerInstance`** (0c). PARTLY DONE 2026-07-30: the alias bridges are gone and the
   cycle is measured. What was found and done first:

   - `Runtime`'s implementation (lines 167 to 2245) does not mention `HandlerPool` or
     `runtime_pool` at all. The zruntime-to-pool edge was never a production dependency.
   - Of the four re-exports, `PercentileTracker` and `websocket_codec` had zero users,
     `HandlerPool` had two (`engine_adapter.zig`, `edge_server.zig`), and `SystemRuntime`
     had one (`runtime_workflow.zig`). All four public aliases are deleted; the three real
     users import the owning module directly. `SystemRuntime` stays as a private import
     because `Runtime.system_registry_ref` is typed on it.
   - What still forces `zruntime.zig` to import `runtime_pool.zig` is **tests**: 15 test
     blocks, 711 lines, every one named for `HandlerPool` behavior, live in `zruntime.zig`
     instead of in `runtime_pool.zig`. The import is now private, so no production code can
     reach the pool through this module.

   Moving those tests is the head of the remaining work, and it is not a block-level cut:
   non-test declarations are interleaved between the test blocks (`writeCachedTeardownFixture`
   at line 5975 sits inside the run, and is shared with two non-pool tests), so the move has
   to be per-block with a compile between each, promoting three helpers to `pub`.

   The rest of the slice: extract `Runtime` from `zruntime.zig` into its own file as
   `HandlerInstance`, owning the Context, installed builtins, loaded handler, invocation
   state, and reset lifecycle, with `runtime_pool.zig` owning it directly. The 96 test
   blocks move with it.
   -> verify: the dependency graph is acyclic (no file imports both directions), full
   `verify.sh`, byte-identical contract and receipt fixtures.

   DONE 2026-07-30, in three commits, and the tests did not move with the type.

   The 15 pool tests moved first (`92410b90`). Measured, they referenced exactly one
   zruntime file-scope declaration, `HttpRequestOwned`, so the design's "promote three
   helpers to `pub`" was not needed. Collection was proven by breaking a moved test and
   watching `test-zruntime` fail with it.

   The eleven remaining re-exports went next (`2ffe2ad5`): the six HTTP types,
   `RuntimeConfig`, `getStringData`, `beginBodyRead`, `createFetchResponse`, and
   `splitHeaderKV`. Sixteen sites reached their real owner through `zruntime` only because
   the name used to live there. Seven of the eleven had no in-file reader either.

   The extraction itself (`03fe1b99`) put `HandlerInstance` in `handler_instance.zig` and
   left the 86 tests, plus the loopback HTTP server they need, in `zruntime.zig`. The
   design said the tests move with the type; they did not, because that would have
   reproduced today's 6,455-line file under a new name. The split is 2,255 lines of type
   against 4,305 lines of test root, and `zruntime.zig` is now imported by no production
   file. The rename had to skip `zq.LockFreePool.Runtime`, a different type the pool also
   holds.

   Two methods became `pub` for the tests, `queueSendInternal` and `createRequestObject`.
   That is the real cost of the split: a test-only coupling that was invisible inside one
   file is now declared.

   ### The acyclic gate is not met, and the remaining cycles are a different shape

   The runtime-to-pool cycle is gone: nothing imports `zruntime.zig`, and
   `handler_instance.zig` never mentions `runtime_pool.zig`. Six cycles remain, all of one
   kind, between `handler_instance.zig` and the sibling files its methods were extracted
   into: `runtime_http`, `runtime_natives`, `runtime_workflow`, `durable_executor`,
   `trace_request_recorder`, and `ws_runtime_callbacks`. Each takes `*HandlerInstance` as a
   parameter, and the instance imports each to register its callbacks.

   Breaking them is a separate piece of work with its own shape: either the registration
   moves out of the instance into a file that imports both sides, or the helpers take
   `anytype` and lose their type check. Neither is what item 0c described, so this is
   reported rather than done. Two unrelated pre-existing cycles also remain
   (`durable_store`/`idempotency_ledger`, `live_reload`/`runtime_features`).

Slice 6 is the large one. Slices 1 to 5 are each self-contained and shrink it: by the time the
extraction happens, `Runtime` no longer publishes ambient state, so the extracted type has a
declared surface rather than a threadlocal one.

## Gate for the whole item

Per the wave 4 gate: every compile path leak-free under `std.testing.allocator`,
byte-identical contract, artifact, and receipt fixtures, unchanged CLI goldens, and the runtime
dependency graph proven acyclic and free of ambient dispatch state.

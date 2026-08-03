---
title: Cached Bytecode Teardown Leaked Roots on Allocator Failure
date: 2026-07-14
category: runtime-errors
module: ZigTS cached bytecode ownership
problem_type: runtime_error
component: tooling
symptoms:
  - A Context teardown allocator failure returned normally while owned deserialized FunctionBytecode trees remained allocated.
  - Repeated cached-runtime teardown under allocator pressure could retain bytecode allocations instead of releasing them.
root_cause: memory_leak
resolution_type: code_fix
severity: medium
tags: [zts, bytecode-cache, ownership, teardown, allocator-failure, memory-leak]
---

> **Path note.** `packages/runtime/src/zruntime.zig` was split after this record was written: production `HandlerInstance` code moved to `packages/runtime/src/handler_instance.zig`, and the test root was renamed to `packages/runtime/src/zruntime_tests.zig`. Line numbers throughout were refreshed on 2026-08-03; `context.zig` and `object.zig` had also moved substantially (JIT removal, generator removal, HTTP-cache and AtomTable extraction), so the original citations had come to land on unrelated code. Every mechanism described below was re-verified against the current tree at that time and is unchanged.

# Cached Bytecode Teardown Leaked Roots on Allocator Failure

## Problem

Cached bytecode is deserialized into a heap-owned function tree, verified, and transferred into `Context` before execution (`packages/runtime/src/handler_instance.zig:1208`, `packages/runtime/src/handler_instance.zig:1228`, `packages/runtime/src/handler_instance.zig:1240`). Nested bytecode nodes can then also be reachable through runtime function objects: the context separately tracks function objects and deserialized roots, and its ownership comments identify cached function objects as borrowers (`packages/zts/src/context.zig:193`, `packages/zts/src/context.zig:200`).

The old teardown shape created an initially empty `FunctionBytecodeSeen` map during `Context.deinit` and populated it while destroying objects and roots. That made cleanup depend on a fresh allocation. `destroyFunctionBytecode` still shows the critical failure behavior: its `getOrPut` catches allocation failure and returns before freeing the function tree (`packages/zts/src/object.zig:1480`). Under allocator pressure, a cached deserialized root could therefore be skipped and leaked.

## Symptoms

- Normal shutdown succeeded because the seen-set allocation usually succeeded.
- If allocations failed only after a real cached load, teardown could silently leave the cached function tree allocated. The destructor returns `void`, and its allocation failure path is an early return rather than an error reported to the caller (`packages/zts/src/object.zig:1480`).
- Nested functions made ownership non-obvious because a function object and an ancestor constant pool can reach the same bytecode node; tracked destruction exists to prevent those paths from double-freeing it (`packages/zts/src/object.zig:1478`).

## What Didn't Work

Building the seen-set during `deinit` was the failed design. A cleanup structure allocated only when cleanup begins cannot protect teardown from allocation failure; the first unseen node still requires `getOrPut`, whose failure abandons destruction (`packages/zts/src/object.zig:1480`).

Blanket borrowing was also rejected. Treating every tracked function object as a borrower whenever any cached root exists would avoid a lookup, but cached and source-compiled bytecode can coexist in one runtime. The regression deliberately loads two cached roots and then source code in the same context (`packages/runtime/src/zruntime_tests.zig:3700`). Source function objects retain their existing ownership path, where non-closure bytecode is destroyed through tracked destruction (`packages/zts/src/object.zig:1537`).

An earlier broad review classified allocator-related `catch` forms as intentional best-effort handling without isolating this cached-bytecode lifecycle (session history). This bug needed a targeted ownership-transfer and teardown audit, not a repository-wide judgment about catch usage.

## Solution

`Context` now stores both the owned cached roots and a registry containing every bytecode node reachable from those roots (`packages/zts/src/context.zig:200`). `takeBytecodeRoot` treats ownership transfer as a small transaction:

1. Ignore a root already owned by this context (`packages/zts/src/context.zig:387`).
2. Recursively count unregistered nested bytecode nodes through bytecode constants (`packages/zts/src/context.zig:398`).
3. Reserve capacity in both the root list and registry before changing ownership state (`packages/zts/src/context.zig:392`).
4. Register the complete tree with `putAssumeCapacity`, then append the root with `appendAssumeCapacity` (`packages/zts/src/context.zig:416`, `packages/zts/src/context.zig:394`).

The runtime calls this transfer after cached bytecode verification and before executing the deserialized function (`packages/runtime/src/handler_instance.zig:1228`, `packages/runtime/src/handler_instance.zig:1240`). If reservation fails, `bytecode_transferred` remains false and the deserialization result retains cleanup responsibility (`packages/runtime/src/handler_instance.zig:1214`).

During teardown, tracked function-object cleanup receives the pre-populated registry. Cached wrappers find their bytecode already present and therefore borrow it, while source-compiled function objects retain the existing tracked destruction behavior (`packages/zts/src/context.zig:554`). The context then destroys each cached root without a seen-set and deinitializes the ownership metadata (`packages/zts/src/context.zig:567`).

## Why This Works

All allocations needed to identify cached ownership happen before the context accepts the root. Once ownership transfers, every node in that cached tree is already registered, so wrapper cleanup does not need to grow the registry for cached nodes (`packages/zts/src/context.zig:387`).

Each deserialization produces an independently owned tree. Duplicate transfer of the same root pointer is ignored, and the root list therefore contains one entry per owned tree (`packages/zts/src/context.zig:387`, `packages/zts/src/context.zig:567`). Destroying those disjoint roots with no seen-set is safe because wrapper cleanup has already treated their registered nodes as borrowed (`packages/zts/src/context.zig:554`).

This guarantee is intentionally narrow: cached-bytecode ownership teardown is allocation-free after transfer. Source-compiled function teardown still uses the tracked seen-set path and is not claimed to be globally allocation-free (`packages/zts/src/context.zig:559`, `packages/zts/src/object.zig:1480`).

## Prevention

- Ownership-transfer APIs should reserve all cleanup metadata before committing ownership. Do not defer ownership bookkeeping until destruction.
- Keep cached and source ownership explicit. A single runtime may contain both, so global mode flags or blanket borrowing rules are unsafe.
- Preserve the real-cache regression that arms `FailingAllocator` to reject every future allocation after load, then calls `deinit` (`packages/runtime/src/zruntime_tests.zig:3684`). This proves the cached teardown path uses pre-reserved metadata.
- Preserve the mixed-ownership regression. Its two cached loads exercise two independently deserialized roots, and its subsequent source load verifies that cached and source bytecode remain separate owners (`packages/runtime/src/zruntime_tests.zig:3700`).
- Verify changes with `zig build test-zts test-zruntime -j1` and `bash scripts/verify.sh`.

## Related Issues

The same bytecode node may be encountered through a runtime function object and an enclosing function's constant pool. `FunctionBytecodeSeen` remains necessary for that general double-free defense (`packages/zts/src/object.zig:1478`). This fix changes when cached ownership metadata is established; it does not replace the tracked destruction model for source-compiled bytecode.

Cached bytecode is verified before ownership transfer or execution (`packages/runtime/src/handler_instance.zig:1228`). That ordering should remain intact: malformed input must not enter the ownership registry, and failed transfer must leave the deserialization result responsible for its own cleanup (`packages/runtime/src/handler_instance.zig:1214`).

- [builtin-graph-teardown-use-after-free](builtin-graph-teardown-use-after-free.md) - the same allocation-free teardown discipline at a different ownership boundary. The two fixes sit in adjacent blocks of `Context.deinit` (`packages/zts/src/context.zig:554-570` here, `:572-598` there) precisely because they are separate ownership domains torn down in sequence: bytecode trees are keyed by a registry populated at load, builtin objects are a pointer graph with no registry at all. Read that one for a use-after-free through a stale alias; read this one for a leak when a cleanup allocation fails.

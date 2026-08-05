---
title: Bind transient state to the object whose values it references
date: 2026-08-05
category: architecture-patterns
module: packages/zts execution and hidden-class state
problem_type: architecture_pattern
component: development_workflow
severity: high
applies_when:
  - "A thread-local stores pointers, indexes, or authority that belong to a shorter-lived object"
  - "Several execution objects can alternate or nest on one worker thread"
  - "A non-local failure can skip defer-based restoration"
tags: [thread-local, ownership, context-isolation, hidden-class, structured-io, teardown]
---

# Bind transient state to the object whose values it references

## Context

Two production thread-local caches looked safe because each worker executed one
operation at a time. Their values had narrower owners than the worker thread:
the structured-I/O collector pointed into one `Context` operation, while the
JSON shape cache stored hidden-class indexes that were meaningful only inside
one `HiddenClassPool`.

Resetting thread-local state during initialization did not fix the ownership
mismatch. A second Context on the same thread could overwrite the first
Context's collector, and a cached class index could outlive the pool that gave
the index its meaning.

## Guidance

Derive the owner from what the stored value references, not from where the code
runs.

The structured-I/O collector now belongs to `Context`. Its scope token records
the exact state object, installed collector, and previous collector, then
asserts that restoration follows the expected local stack. See
`packages/zts/src/context.zig:217-219` and
`packages/zts/src/parallel_collection.zig:30-58`.

`parallel()` and `race()` enter that Context-owned scope before invoking their
thunks and restore it on every normal or error exit. The HTTP bridge reads the
collector through the same runtime Context rather than through ambient thread
state. See `packages/zts/src/modules/workflow/io.zig:172-187`,
`packages/zts/src/modules/workflow/io.zig:306-318`, and
`packages/runtime/src/runtime_http.zig:828-835`.

The JSON shape cache now belongs to `HiddenClassPool`. Each entry stores a
pool-local `HiddenClassIndex`, so the cache is initialized and destroyed with
that pool. JSON parsing performs lookup and insertion through the current
Context's pool. See `packages/zts/src/object.zig:932-948`,
`packages/zts/src/object.zig:977-1022`, and
`packages/zts/src/builtins/json.zig:260-273`.

Treat non-local recovery as a separate lifetime. Panic recovery can skip Zig
defers, so a quarantined Context clears both transient scopes before invoking
module-state destructors. See `packages/zts/src/context.zig:552-563`.

## Why This Matters

Thread identity is a scheduling fact, not an ownership boundary. A pointer to a
stack-owned collector and an index into a per-object pool remain valid only as
long as their actual owner remains valid. Storing either value on the thread
allows unrelated objects to alias state accidentally even when execution is
single-threaded.

Owner-bound state also makes the required tests precise. Nested operations must
restore the exact parent. Alternating Contexts must remain independent. Pool
tests must construct incompatible index meanings, destroy one pool, and keep
using the other. Teardown tests must observe the transient state already clear
when callbacks run.

This pattern does not require deleting every thread-local. State whose real
owner is the worker thread can stay there. The decision follows the lifetime
and meaning of the stored value.

## When to Apply

- When a thread-local contains a pointer borrowed from an operation or object.
- When a cache value is an index or handle into an owner-specific table.
- When nested or alternating execution objects can share one worker thread.
- When panic or cancellation can bypass ordinary scope restoration.

## Examples

The unsafe shape hides an owner-specific value behind the thread:

```zig
threadlocal var active: ?*Collector = null;
```

The owner-bound shape makes the lifetime explicit:

```zig
const scope = ctx.parallel_collection.enter(&collector);
defer scope.restore();
```

The cache follows the same rule:

```zig
const pool = ctx.hidden_class_pool.?;
const class_idx = pool.lookupJsonShape(atoms) orelse build: {
    const created = try buildClassForAtoms(pool, atoms);
    pool.cacheJsonShape(atoms, created);
    break :build created;
};
```

The focused regressions are in
`packages/zts/src/modules/workflow/io.zig:396-455`,
`packages/zts/src/modules/workflow/io.zig:741-859`,
`packages/zts/src/modules/workflow/io.zig:1001-1092`, and
`packages/zts/src/builtins/json.zig:661-723`.

## Related

- [Ambient module authority crossed ZTS Contexts](../security-issues/ambient-module-authority-crossed-zts-contexts.md) applies the same ownership rule to native-module authorization.
- [Remove orphaned thread-local state without replacing it](remove-orphaned-thread-local-state.md) covers the complementary case where no live value remains and the channel should be deleted.
- [Cached bytecode teardown leaked roots on allocator failure](../runtime-errors/cached-bytecode-teardown-allocator-failure-leak.md) covers explicit ownership and allocation-free teardown for bytecode roots.

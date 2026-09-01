---
title: A second program load kept the first one's object shapes
date: 2026-09-01
category: logic-errors
module: zts context and object literal shapes
problem_type: logic_error
component: engine
severity: medium
symptoms:
  - "A HandlerInstance that loads a second program returns the first program's property names in every object literal."
  - "`Response.json({ b: 2, c: 3 })` after a handler that returned `{ a: 1 }` produces `{\"a\":2}`: one field, the wrong name, and the second value dropped."
  - "No error, no diagnostic, no failing assertion. The response is well-formed JSON of the wrong shape."
  - "Not reachable in production today. Live reload rebuilds the runtime instead of loading twice into one."
root_cause: logic_error
resolution_type: documented_only
related_components:
  - runtime
  - testing_framework
tags:
  - zts
  - hidden-classes
  - object-literals
  - handler-reload
  - shared-index
  - not-fixed
---

# A second program load kept the first one's object shapes

## Problem

An object literal does not build its property list at run time. The parser
collects every literal's property names into a shape table, the bytecode carries
a `shape_idx` into that table, and the interpreter turns the index into a
pre-built hidden class:

```zig
const class_idx = self.ctx.getLiteralShape(shape_idx) orelse {
    const obj = try alloc.createObject(self);
    try self.ctx.push(obj.toValue());
    continue :sw @enumFromInt(self.pc[0]);
};
const obj = try self.ctx.createObjectWithClass(class_idx, null);
```

(`packages/zts/src/interpreter.zig:967`). `getLiteralShape` is a direct index
into one array on the Context (`packages/zts/src/context.zig:377`), and that
array is filled by `materializeShapes`, which **appends**:

```zig
pub fn materializeShapes(self: *Context, shapes: []const []const object.Atom) !void {
    const pool = self.hidden_class_pool orelse return error.NoHiddenClassPool;
    try self.literal_shapes.ensureTotalCapacity(self.allocator, shapes.len);
    for (shapes) |shape| {
        var class_idx = pool.getEmptyClass();
        for (shape) |atom| {
            class_idx = try pool.addProperty(class_idx, atom);
        }
        try self.literal_shapes.append(self.allocator, class_idx);
    }
}
```

(`packages/zts/src/context.zig:358`).

Appending is deliberate. A handler is not always one compilation unit: the pool
loads each dependency module's bytecode before the entry bytecode
(`packages/runtime/src/runtime_pool.zig:910`), and the multi-module path
materializes each module's shapes in execution order
(`packages/runtime/src/handler_instance.zig:797`). Those loads compose into one
program, and their shape indices are assigned across the whole composition, so
each load must add to what is already there.

The defect is that nothing distinguishes "another module of the same program"
from "a different program". Every emitted `shape_idx` starts at zero for its own
compilation, and the table is never reset, so a second `loadCode` on one
`HandlerInstance` appends its shapes after the first program's and then resolves
its own index 0 to the first program's shape 0. The second program's literals
silently take the first program's property names.

The interpreter cannot notice. The opcode reads the literal's property count and
discards it:

```zig
const prop_count = self.pc[0];
self.pc += 1;
_ = prop_count;
```

(`packages/zts/src/interpreter.zig:963`). The values are then written into the
class's slots by position. A two-property literal that lands on a one-property
class writes the first value into the one slot, drops the second, and reports the
first program's name for it.

## Symptoms

Two handlers, one instance, no policy or module involvement:

```zig
try rt.loadHandler("function handler(req) { return Response.json({ a: 1 }); }", "<a>");
// -> {"a":1}
try rt.loadHandler("function handler(req) { return Response.json({ b: 2, c: 3 }); }", "<b>");
// -> {"a":2}
```

`Response.text` is unaffected, because it builds no literal.

The failure signature is a response with a plausible shape and the wrong field
names, so a test that asserts on one field it happens to share with the previous
handler passes. This was found while writing a capability-guard probe that seeded
cache state in one handler and read it back in another: the read returned
`{"entries":1}` from a handler whose source contained no `entries` field at all.

## What Didn't Work

Nothing caught it, and the reason is worth stating: every test that reloads a
handler on one instance reloads it to assert an **error**
(`packages/runtime/src/zruntime_tests.zig:2657` and its neighbours load a second
handler and expect `error.NativeFunctionError`). A handler that fails never
reaches an object literal, so the shape table never matters. The one pattern that
would expose it, load a second working handler and read its response, did not
exist in the suite.

Reading the reload path is also reassuring in the wrong direction. `reloadHandler`
looks like the risky operation, and it is safe: it bumps a generation counter
rather than reloading in place (`packages/runtime/src/runtime_pool.zig:250`), and
`ensureRuntime` tears the stale runtime down with `runtimeUserDeinit` and builds
a fresh `HandlerInstance` before loading the new code
(`packages/runtime/src/runtime_pool.zig:844`). The unsafe operation is the plain
one that no production path performs.

## Not Fixed

This is recorded, not repaired. The obvious one-line fix is wrong:

```zig
// Do NOT do this.
self.literal_shapes.clearRetainingCapacity();
```

Clearing inside `materializeShapes` breaks every multi-module handler, because
the second module's load would discard the first module's shapes and every one of
its literals would resolve to a stale or out-of-range index. The append is load
bearing.

Two shapes of real fix:

1. **Give each compilation a base offset.** The program records where its shapes
   start in the table, and the lookup resolves `base + shape_idx`. This is
   correct for both composition and reload, and it is a change to the bytecode's
   shape addressing, so it touches the serializer, the deserializer, and the
   interpreter together.
2. **Reset at the entry load only, and pin the order.** Make the fresh-program
   entry point clear the table and leave dependency loads appending. This is
   smaller but depends on dependency loads happening after the reset, which is
   true of the pool's path today (`loadFromCachedBytecodeNoHandler` for each
   dependency, then the entry) and is not stated anywhere as a requirement. It
   needs a test that fails when the order changes.

Either way, `_ = prop_count` deserves to become a check: a literal whose property
count disagrees with the class it resolved to should fall back to the plain
object path rather than write by position into the wrong shape. That alone would
have converted this into a visible wrong-arity object instead of a wrong-name
one, and it is independent of which fix is chosen.

Until then, treat `loadCode` and `loadHandler` as a once-per-instance operation.
A test that needs two working handlers needs two `HandlerInstance`s.

## Prevention

**An index into a shared table is only meaningful with the table's base.** The
bug is not in either function. `materializeShapes` correctly appends, and
`getLiteralShape` correctly indexes. The unstated assumption between them is that
the table contains exactly one program, and nothing in either signature says so.
When a compiler emits positional indices and the consumer keeps a single flat
array, the array becomes program-scoped state with no program in its type. Name
the scope, either by resetting where the scope begins or by carrying the base
with the index.

**Discarding a redundant field removes a free consistency check.** The literal's
property count is in the bytecode and is thrown away. It agrees with the shape in
every correct program, which is exactly what makes it useful: it costs one
comparison and it is the only local evidence that the index resolved to the right
class. Redundancy that is present but unread is not a safety margin.

**A reload path that is never exercised with working code is not tested.** The
suite reloaded handlers many times and only ever asked whether the reload
failed. Coverage of an operation is not coverage of its success case, and here
the success case was the broken one.

## Related Issues

- [a-gate-that-counts-nothing-still-reports-a-pass](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) - the same shape of blindness one level up: a check that runs, passes, and is looking at the wrong thing.
- `packages/zts/src/interpreter.zig:967`, `packages/zts/src/context.zig:358`, and `packages/runtime/src/runtime_pool.zig:844` - the three sites any fix has to agree with: the lookup, the table, and the only production path that changes handler code.

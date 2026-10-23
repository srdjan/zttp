---
title: A walk that ended in an empty else arm proved code it never read
date: 2026-10-22
category: security-issues
module: packages/zts (effect inference, handler verifier, type checker, route resolution, path generator, behavior diff, strict checker, boolean checker, IR accessors)
problem_type: security_issue
component: compiler
symptoms:
  - "A handler that wrote the cache inside `assert` or inside a spread operand had `retry_safe` and `idempotent` PROVEN, and CHECK exited 0 with a capsule."
  - "An unchecked `result.value` read inside `assert`, a closure, or a nested block that a sibling branch had checked gave no ZTS303."
  - "`prove-behavior` reported `equivalent` for an edit that removed a nested cache write, changed a dynamic cache key, or changed an `assert` error response. For the dynamic key it also reported `safe: true`."
  - "`!n` on a number under `[...x]`, `{ ...x }`, or a member base was not refused, and the handler went on to contract extraction."
root_cause: logic_error
resolution_type: code_fix
severity: high
related_components:
  - testing_framework
  - documentation
tags:
  - zts
  - ir-walk
  - default-arm
  - fail-open
  - expression-children
  - spread
  - upvalue
  - behavior-diff
---

# A walk that ended in an empty else arm proved code it never read

## Problem

Each zts analysis pass had its own hand-written recursive walk over the IR. Each walk named the node tags it knew and ended in `else => {}`. When a walk did not name a tag that has children, the pass never saw those children. It then reported a verdict for code it had not read, and that verdict was a pass, not a failure.

## Symptoms

A census of the default arms in the proof files, followed by probes, found 15 defects (D1 to D15) in nine files, and the work fixed D1 to D13. The plan `docs/plans/2026-10-22-walker-soundness-plan.md` lists each one with its probe. These are the user-visible effects:

- Effect inference did not enter `assert` or a spread operand. A capability call there was not charged, so `retry_safe` and `idempotent` were proven for a handler that writes.
- The handler verifier did not enter `assert`, a nested function, or a closure body. Its Result and optional checks were set on sight and never scoped, so a check inside one branch cleared the obligation in a sibling branch.
- The type checker's narrowing-kill walk did not reach an assignment inside an initializer, a call argument, or a closure. A narrowing survived the assignment.
- Route resolution did not count an array-literal assignment root as a mutation, and it did not scan every escape position. A mutated route table was treated as stable.
- The I/O tracker in the path generator recorded a module call only in three positions. Removing a nested write diffed `equivalent`.
- The path generator treated `assert` as a statement without a branch, so the failure path of an `assert` did not exist.
- The strict checker and the boolean checker read spread operands from the wrong payload word, and the boolean checker treated member bases as leaves.

## What Didn't Work

- **Thirteen local fixes.** Each defect had a small local fix: add one arm to one walk. That closes the probed case and leaves the class open for the next tag, the next walk, and the next author. The plan rejected it.
- **Adding descent first in the verifier.** The first plan made the verifier descend into closures. Validation (Codex astra for facts, Fable for the argument) showed that this adds fail-opens. The verifier's checked state was set when it saw a guard, so a guard inside a closure would clear the obligation for the enclosing scope. Descent is conservative only for a walk with no scoped state. The verifier had to scope its state first, through a journal that each block restores, and only then add descent.
- **Trusting the plan's diagnosis of the strict checker.** The plan said the strict walks did not enter closures. They did. The misses came from the keys: a closure names a captured binding through an `upvalue` reference that has its own scope and slot, so a lookup by the declaring binding's key never matched. The fix matches a captured reference by its name atom.
- **A behavior diff that compared `?` with `?`.** Every non-literal argument gave the signature token `?`, and `?` equaled `?`. So `cacheSet("items", a, ...)` and `cacheSet("items", b, ...)` compared equal. A `?` token now never matches. The one exception is two handler sources with an equal IR identity that import only `zttp:` modules.

## Solution

One shared, exhaustive child map: `IrView.expressionChildren(node)` in `packages/zts/src/parser/ir.zig`. It is an iterator over the children of a node that hold code, in source order, including function bodies. Its switch names all 69 `NodeTag` members and has no `else` arm, so a new node kind does not compile until someone decides its children.

Each fixed walk keeps its named arms for the tags it handles specially. Its default arm descends through the map:

```zig
// before
.unary_op, .spread => {
    const un = self.ir_view.getUnary(node) orelse return;
    self.walkExpr(un.operand);
},
else => {},

// after
.unary_op => {
    const un = self.ir_view.getUnary(node) orelse return;
    self.walkExpr(un.operand);
},
// The spread operand is payload word `a`, read by `getOptValue`.
.spread => {
    if (self.ir_view.getOptValue(node)) |operand| self.walkExpr(operand);
},
else => {
    var children = self.ir_view.expressionChildren(node);
    while (children.next()) |child| self.walkExpr(child);
},
```

The map excludes these positions, and its doc comment gives the reason for each:
- Binding positions, such as a declared name or a parameter. They hold no code.
- Import specifiers. They are names.
- `match` patterns. The parser builds a type test as a call, for example `isDict(x)`, and the effect walk would charge that call as unknown on every type-test `match`.
- The key of an object property when it is a string literal. It is the field name, not code.

The map is an iterator, not a callback. The callers have three different error sets, and an iterator lets each caller keep its own with `try`.

## Why This Works

The defect class was not one missing arm. It was a default that answered "nothing here" for every node the author did not name. With a default that descends, a tag the author did not name is walked, not skipped. A walk that only adds facts, such as the effect walk, the narrowing kill, and the I/O tracker, becomes more conservative when it sees more code. A walk with scoped state does not, which is why the verifier needed its journal before it could descend.

The spread fix is the same misread as the `getFunction` and `function_decl` case in the related convention note. `getUnary` reads payload word `b` and fails soft only when word `a` is not a valid operator. For a spread node, word `a` holds the operand, so `getUnary` could answer with an unrelated node as the operand.

## Prevention

- **A walk over node tags has no silent `else` arm.** A new walk descends through `expressionChildren` in its default arm. Where a walk must stop at a tag, it names the tag and says why in an `// exhaustive:` comment. The proof-swallow gate reads that comment in the files it covers. `AGENTS.md` now states the descend rule and the spread rule in its proof-swallow paragraph.
- **Scope checked state before you add descent.** If a walk records "this obligation is discharged" when it sees a guard, a wider walk lets more guards discharge obligations they do not dominate.
- **A captured binding has a different key inside a closure.** A pass that looks a binding up by scope and slot must also handle the `upvalue` reference, or it must state that it does not.
- **An unknown never equals an unknown.** A structural compare that reduces a value it cannot read to one token must not treat two copies of that token as equal.
- **Probe each verdict against a control.** Each unit added its probe as a test, through the public entry point, next to a control that gives the other verdict. A probe read only by its exit status can show nothing: the W10 probes exited 1 before the fix too, through ZTS500 (observed in this session). Read the diagnostic codes.
- **Not done:** `getUnary` still answers for a `.spread` node instead of returning null. Making it refuse that layout, as `getFunction` refuses a `function_decl`, would make the next misread fail at the read.

## Related Issues

- [A decision over a path that never ran passed every gate](../conventions/a-decision-over-a-path-that-never-ran-passed-every-gate.md) has the same accessor-misread family, from the angle of a plan decision.
- [A dispatched route was never walked](a-dispatched-route-was-never-walked-so-its-leak-proved-clean.md) and [a module-level declaration carried no label](a-module-level-declaration-carried-no-label-so-its-secret-proved-clean.md) describe other places a walk did not reach.
- [A gate that counts nothing still reports a pass](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) describes the same shape in a gate.
- Open items from this work: D14 (a narrowing survives a call to a closure that assigns the variable), D15 (a `match` expression yields one behavior path), and the residual gaps in the plan's progress table.

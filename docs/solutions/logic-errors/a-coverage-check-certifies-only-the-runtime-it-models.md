---
title: A coverage check certifies only the runtime it models
date: 2026-10-08
category: logic-errors
module: ZigTS match codegen, match_analysis coverage, boolean checker narrowing
problem_type: logic_error
component: tooling
severity: high
symptoms:
  - "`when { a: { b: x } }: x` type-checked and returned `undefined` for `{ a: { b: \"deep\" } }`: nested bindings were never stored."
  - "`when { v: [] }` matched `{ v: [1, 2] }`, and `when { w }` matched the string `\"s\"`: nested `[]` and `{}` were wildcards and no record pattern tested that its value was a record."
  - "`when 1`, `default`, `when 2` ran `when 2` for `2`, and a record field `_` matched an absent field."
  - "Each handler passed `zttp check` with only ZTS500 and ZTS305, so a stricter exhaustiveness check would have certified the wrong answers."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
tags:
  - zts
  - match
  - exhaustiveness
  - codegen
  - soundness
  - fail-open
  - narrowing
  - runtime-probe
---

# A coverage check certifies only the runtime it models

## Problem

A plan replaced the per-arm `match` exhaustiveness check with a pattern-matrix
(Maranget) algorithm. The new check models what each pattern matches. The
`match` codegen did not do what that model assumed, so the stricter check would
have certified programs that return wrong answers at runtime. `match` is a
TCB-trusted construct (`packages/zts/src/semantics.zig`), so the gap is a
fail-open: a program that passes the check does not do what the check claims.

## Symptoms

Four handlers probed with `zttp serve` on 2026-10-07. Each passed `zttp check`
with only ZTS500 (proof profile) and ZTS305 (unused variable).

| Pattern | Input | Result | Spec result |
|---|---|---|---|
| `when { a: { b: x } }: x` | `{a:{b:"deep"}}` | `undefined` | `"deep"` |
| `when { v: [] }` then `default` | `{v:[1,2]}` | first arm | `default` |
| `when { w }` then `when string` | `"s"` | first arm | `when string` |
| `when 1`, `default`, `when 2` | `2` | `when 2` | refused |

Two more surfaced while the fix was built: the array pattern `[_, _, _]` matched
the record `{ length: 3 }`, and a record field `_` matched an absent field. When no arm
matched, the `match` evaluated to `undefined` and execution continued.

## What Didn't Work

- **Reading the codegen instead of running it.** The first plan named a defect
  in nested type tests. A fact check showed that `when { v: string }` is a
  renamed binding by spec: the arm binds a variable named `string` and matches
  every value. The claim came from reading code paths, not from a probe. The
  real defects were found only by running handlers.
- **"Arms after `default` are unreachable."** The first plan stated this as a
  model rule. Codegen tests every non-default arm in order and jumps to
  `default` last, so arms after a mid-position `default` still ran. A matrix
  built on the stated rule would have reported a reachable arm as redundant.
- **Trusting a passing check as evidence.** Each defective handler passed
  `zttp check`. Exhaustiveness answers "does some arm match every value?" It
  cannot answer "does the arm that matches do what its pattern says?".

## Solution

Fix the runtime first, then build the model on the fixed runtime, then prove
the two agree with tests that run values.

1. **Runtime (U0).** On local `main`, not pushed as of 2026-10-08:
   - Store bindings at every depth of a pattern
     (`packages/zts/src/parser/codegen.zig:2042`, `emitPatternBindings`, and
     `:2051`).
   - Test the shape of every record and array pattern before reading fields or
     the length. The test is a call to the engine-private global
     `%matchShape` (`codegen.zig:2193`, `emitShapeTest`;
     `packages/zts/src/builtins/number.zig:284`), because no opcode names a
     value's class. `isRecord` names every object class
     (`number.zig:295`), so a class added later is not a record by default.
   - Refuse a `default` that is not last, and a second `default`, as ZTS062
     (`packages/zts/src/parser/error.zig:37`).
   - Refuse a type-test name in a renamed binding or an array element as
     ZTS001 (`packages/zts/src/parser/parse.zig:1098`).
   - Restore `null_node` for a record field `_`. `IrView.getProperty` read the
     value through a 24-bit field, so the "no pattern" marker came back as
     `0xFFFFFF` and the presence test was lost
     (`packages/zts/src/parser/ir.zig:1915`).
2. **Model (R1).** Rewrite `match_analysis.zig` as a usefulness walk whose
   rules state the runtime as it is after step 1: a record pattern needs a
   record, a field `_` is a presence test, a field binding matches
   `undefined`, an array element `_` is a plain wildcard, and an array pattern
   needs an array of the exact length.
3. **Agreement (R1).** Runtime soundness tests in
   `packages/zts/src/interpreter.zig` run every value of each covered type to
   an arm and assert that none returns `undefined` (`:4483`, `:4522`,
   `:4571`). A paired test shows that a match the analysis calls
   non-exhaustive does fall through to `undefined` (`:4623`).

## Why This Works

A static check answers a question about a model. It is sound only when the
model and the runtime agree on every rule the check uses. Fixing the runtime
first gives the model one authoritative source: the codegen as it is after the
fix, not as the spec or a reading of the code suggests. The value-enumeration
tests then turn "the model matches the runtime" from a belief into a check
that fails when either side changes. The `undefined` fall-through test covers
the other direction: what the model calls a gap is a gap at runtime.

## Prevention

- Before a static check certifies a construct, run small programs through the
  real runtime (`zttp serve` with one request) for each rule the check will
  model. A passing `zttp check` is not evidence that the runtime is right.
- Pair each coverage rule with a runtime test that enumerates the values of a
  covered type and asserts the arm each one reaches.
- When a static rule reads types, check that it reads them where the type
  checker's narrowing is live. The same pattern recurred in a boolean-checker
  prototype on 2026-10-08: it read types after the type checker closed its
  narrowing scopes, and the type checker installs no narrowing for `&&` or
  `||`, so the prototype refused `v !== undefined && v` and
  `e.kind === "a" && e.flag`. Unit B1 of
  `docs/plans/2026-10-08-boolean-and-arity-checks.md` adds those guards
  (planned, not landed as of 2026-10-08).

## Related Issues

- `docs/solutions/logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md`:
  the same class, where a check modelled the wrong baseline and certified an
  unsound result.
- `docs/solutions/security-issues/empty-label-set-claimed-a-value-was-clean.md`:
  an analysis that claimed more than it checked.
- `docs/solutions/conventions/a-gate-can-be-non-vacuous-and-still-porous.md`:
  probe the cases nobody named.
- `docs/solutions/logic-errors/a-label-union-that-never-narrows-refuses-a-clean-program.md`:
  a static rule without narrowing refuses correct programs.
- `docs/plans/2026-10-07-tier1-test-and-diagnostic-discipline.md`: units U0 and
  R1.

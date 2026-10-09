---
title: A decision over a path that never ran passed every gate
date: 2026-10-09
category: conventions
module: packages/zts (IR accessors, flow checker walk, boolean checker walk, contract builder scope summary), docs/plans (any plan decision about a traversal)
problem_type: convention
component: testing_framework
severity: high
applies_when:
  - "A plan decides to keep, remove, or change a code path, and the evidence is that every gate stays green"
  - "A traversal arm reads a node through an accessor that returns null on a layout it does not own"
  - "A refactor makes an accessor correct and a census, corpus, or example verdict moves for no stated reason"
  - "Reviewing a walk, visitor, or analysis arm whose effect no test pins"
symptoms:
  - "Plan unit F1 chose to keep the flow checker's structural walk of nested `function` declarations; the census and every other gate stayed green"
  - "When B0 made the accessor correct, census probe x09 turned into an over-refusal: the walk now ran and counted the nested body's `return` as the handler's"
  - "The same misread meant the boolean checker never walked any `function` body, and B3 then found five handler fixtures in runtime tests that had never been checked"
root_cause: wrong_api
related_components:
  - documentation
tags:
  - testing
  - zts
  - flow-checker
  - ir-accessor
  - fail-open
  - plan-review
  - census
---

# A decision over a path that never ran passed every gate

## Context

The flow-checker plan of 2026-10-08 had to decide how its walk treats a nested
`function` declaration that nothing calls. The handler walk already had an arm
for it: `walkStmt` matched `.function_decl, .function_expr, .arrow_function`
and walked `getFunction(node).body`. Unit F1 decided to keep that structural
walk, because the census gate (771 probes) and every other gate stayed green
with it.

The walk had never run for a declaration. The parser stores a `function_decl`
as `var_decl` data, `{ binding, init = function node, kind }`
(`packages/zts/src/parser/parse.zig`, the `.tag = .function_decl` node it
returns). The arm matched the declaration's tag, but `getFunction` read the
node as if it held function data: it read extra-data slots the declaration does
not own and returned unrelated data or null, so the arm walked nothing that
belonged to the declaration. The same misread sat in
`bool_checker.zig` (so the boolean checker never walked the body of `handler`
or of any named helper) and in `contract_builder.zig` `subtreeContains`.

Unit B0 of the next plan added `getFunctionOfDecl`
(`packages/zts/src/parser/ir.zig:2058`), which reads the declaration's `init`,
and made `getFunction` return null for a `function_decl`
(`packages/zts/src/parser/ir.zig:2034`). With a correct read, the structural
walk ran for the first time, and the census moved: probe
`x09_nested_decl_returns_secret_len` became a false ZTS400, because a nested
body walked as a statement counts its `return` as a return of the enclosing
function. B0 made the arm return instead
(`packages/zts/src/flow_checker.zig:2956`), so a nested declaration is now
checked only through its calls. Probing that choice found a fail-open the no-op
had hidden: `[secret].map(leak)`, with `leak` a named function that logs its
argument, proved `no_secret_leakage`, because only a callback written as a
literal was walked with the receiver's labels.

## Guidance

**Before a decision rests on a code path, prove the path does its work.** Write
the one probe the decision's rationale predicts and run it. For F1 that is a
sink in an uncalled nested declaration, which the kept walk should report. Or
sabotage the path where it does its work, after every lookup it depends on, not
at the point where it is dispatched: the F1 arm was dispatched for every
declaration, and only the lookup inside it failed. If no verdict moves, the
gate cannot see the path, and a passing result says nothing about the
decision. A plan decision that says "keep X, the census still passes" needs
that probe or that sabotage run beside it.

**Make an accessor refuse the layout it does not own.** `getFunction` used to
answer any node index with whatever its slots held. It now returns null for a
`function_decl` on both IR implementations, and the declaration has its own
accessor. A misuse then fails at the read, and a test of the new arm shows
whether the arm does anything at all.

**When fixing an accessor moves a verdict, stop and read the move.** The x09
move was the first evidence that F1's premise was false. Treat a verdict that
moves under a behavior-neutral refactor as a finding about the earlier
decision, not as noise to allowlist.

## Why This Matters

A no-op cannot change a verdict, so every gate passes over it. The census, the
corpus, the stand-in, replay, and the examples all passed with the F1 decision
in place, and none of them could have reported anything else. The plan's
observed facts did name the misread, but only as an item for the boolean plan,
and still listed "the handler walk enters nested declarations structurally" as
a fact. F1 then kept the walk as a backstop for sinks in uncalled nested
functions, which it never provided.

The same misread held the boolean checker out of every `function` body since
the checker was written. The first real walk (unit B3) refused four examples
and flagged five runtime test fixtures that had never been checked. That is the
size of what a silent no-op had been certifying.

## When to Apply

- A plan or review chooses between keeping and removing a traversal, a guard,
  or a fallback, and the only evidence is that gates stay green.
- An accessor reads a node, a row, or a record by position and can return a
  value or null for an input it was not written for.
- A refactor that should change nothing moves a verdict.
- A walk arm has no test that fails when the arm is deleted.

## Examples

The probe F1's rationale predicts: the kept walk should report a secret logged
in a nested declaration that nothing calls.

```ts
function handler(req: Request): Claim<Response> {
  function leak(): number {
    const t = env("API_TOKEN") ?? "";
    logInfo(t, { n: 1 });
    return 1;
  }
  return Response.json({ ok: 1 });
}
```

Measured on 2026-10-09 with a `zts` built from F1's commit: `zts check` gives
no diagnostic, and `no_secret_leakage` holds. The walk F1 kept did not report
the sink it was kept for, and one run of this probe before the decision would
have shown it. At the current tree the same probe also holds, by design: a
nested declaration is checked only through its calls, as a top-level one is.

The accessor shape that turns the misuse into a visible failure
(`packages/zts/src/parser/ir.zig`):

```zig
pub fn getFunction(self: IrView, idx: NodeIndex) ?Node.FunctionExpr {
    if (self.getTag(idx) == .function_decl) return null;
    ...
}

pub fn getFunctionOfDecl(self: IrView, idx: NodeIndex) ?Node.FunctionExpr {
    if (self.getTag(idx) != .function_decl) return null;
    const decl = self.getVarDecl(idx) orelse return null;
    return self.getFunction(decl.init);
}
```

Related: [a check that never ran passed every handler](../security-issues/a-check-that-never-ran-passed-every-handler.md)
(a check, not a decision, over a path that never ran),
[a dispatched route was never walked](../security-issues/a-dispatched-route-was-never-walked-so-its-leak-proved-clean.md)
and [a module-level declaration carried no label](../security-issues/a-module-level-declaration-carried-no-label-so-its-secret-proved-clean.md)
(other places the same walk did not reach), and
[a gate that counts nothing still reports a pass](a-gate-that-counts-nothing-still-reports-a-pass.md)
(the delete-its-input check this guidance applies to a decision).

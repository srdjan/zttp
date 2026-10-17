---
title: Recursion through a function value proved total and cost_bounded
date: 2026-10-16
category: security-issues
module: packages/zts/src/effect_inference.zig (termination claims over function values), path_generator.zig, spec_discharge.zig
problem_type: security_issue
component: compiler
symptoms:
  - "A helper declaring `Proof<number, \"total\">` had the capsule discharged while it recursed forever through `wrap(o).a(n)`, `[n].map(down)`, or `apply(down, n)`."
  - "A handler declaring `cost_bounded` had it discharged with 0 errors while a nested function, a module `let`, or a module object member called back into itself."
  - "A call-returned value from a sibling module reached a helper as an argument, and the helper kept `total` although the call never ended."
  - "Direct self-recursion by name was refused, so every direct probe and test stayed green."
root_cause: logic_error
resolution_type: code_fix
severity: high
related_components:
  - documentation
tags: [termination, total, cost-bounded, function-values, recursion, fail-open, closed-world, effect-inference]
---

# Recursion through a function value proved total and cost_bounded

## Problem

The termination claims `total` (a helper's Proof capsule) and `cost_bounded` (a handler property) read recursion from the call graph. A call through a function value adds no edge to that graph, so a program that recursed through a value proved both claims while it never terminated.

## Symptoms

- Admitted probes recursed without a base case and still proved `total`, `cost_bounded`, or both. The probes covered at least thirteen shapes in five channels: a returned or stored value (`wrap(o).a(n)`, `first([down])(n)`, `([down][0])(n)`, `({ a: down }).a(n)`), a callback (`[n].map(down)` inside `down`, `apply(down, n)`, a parameter `self: Step`), a holder (`ops.a(n)`, a module `const g: Ops = { f: (x) => g.f(x) }`), local or module state (a nested `function g` that calls itself, a module `let` reassigned to the recursing function), and bindings with no initializer (a for-of over `[down]`, a match-arm binding).
- A lower-bound row already refused `total` for some of these shapes, but `cost_bounded` never read `lower_bound`, so the handler still proved it.
- The only shape refused before the fix was direct recursion by name, which is the shape every existing test used.

## What Didn't Work

- **Value edges in the recursion graph.** Revision 1 of the plan added edges from each value reference to `detectRecursion`, and edges from each higher-order function to every escaping function. A Fable review found four admitted channels that this missed: a nested function declaration, a module `let` reassigned in another function, a module object whose closure calls back through the object, and mutual recursion through a `let`. The value-edge half also contradicted existing tests, which correctly assert that a value reference is not a call. The 2026-10-14 work had rejected the same "charge a reference as a call" idea for that reason (session history).
- **A per-call "may hold a function" predicate.** Revisions 2 and 3 marked each call through a value as unresolved, using an expression predicate and declared types. Each review round found admitted programs the predicate called function-free: a module `let` passed as a callback (`items.map(slot)`), a module `const` filled by a call to a function returning `{ f: down }`, for-of and match-arm bindings with no initializer, and a sibling module's call result. The plan records that the predicate also refused 29 of 33 examples, because `Response.json({ ... })` passes an object literal. In addition, the cost path built its effect facts without a type environment, so any type-directed rule failed closed for every parameter there.
- **An inline arrow passed to a user function as a safe position.** It is unsound. `loop((g: Step) => loop(g))` with `function loop(f: Step) { return f(f); }` is admitted, proved `cost_bounded`, and never terminates.
- **Flagging only the importer functions that name an escaping sibling.** The first implementation did this. `const v = make(); useIt(v)`, where `make` returns an escaped function from a sibling module, left `useIt` proving `total`.

## Solution

Stop judging each call. Judge whether any function value can escape, and refuse termination claims for the whole module when one does.

A function value escapes when it appears anywhere outside a closed position (`scanFunctionValueEscapes` in `packages/zts/src/effect_inference.zig`):

- P0: the declaration site of a function literal.
- P1: the callee of a call by name, where the name is not a `let`, or is an import.
- P2: the first argument of a listed array builtin (`callback_methods` in `packages/zts/src/effect_inference.zig`), on a receiver that is not a function-holding module binding, when the argument is not a `let`-bound name.
- P2b: a function argument of an allowlisted `zttp:result` export (`callback_imports` in `packages/zts/src/effect_inference.zig`). Each entry is added only after its native implementation is read, to confirm that it calls the callback and does not return or keep it.
- P3: a value in a module `const` route table whose every reference is a stable `routerMatch` first argument.

When any function value escapes, `CapsuleFacts.holds` refuses `total` for every function (`packages/zts/src/spec_discharge.zig`), and the cost envelope is unbounded, which refuses `cost_bounded`. Each refusal names the first escaping site. Three additions close the remaining gaps:

- A function passed as a callback argument inside its own body marks itself recursive (`recordFunctionValueArg` in `packages/zts/src/effect_inference.zig`).
- `cost_bounded` also requires that the handler's propagated row is not a lower bound (`packages/zts/src/path_generator.zig`). This covers a call by name to a nested function or a body-local closure, which has no collected-function edge.
- A reference to a relative import whose module escapes, or whose result was not supplied, is itself an escape of the importing module (`referencesEscapingSibling` in `packages/zts/src/effect_inference.zig`).

The cost path now receives the sibling-module results (`pipeline.zig`, `pathEffectFacts`). Without them, every handler that called a relative-import helper lost `cost_bounded` under the lower-bound rule.

The plan is `docs/plans/2026-10-16-recursion-through-function-values-plan.md`. Its revision history records each rejected design and the probe that rejected it.

## Why This Works

Without an escape, every call that can run has an edge. A function value can reach code only through a closed position. P1 is a call by name, so the graph has its edge. P2 and P2b are builtins or allowlisted exports that call the argument and keep nothing: a named argument has a call edge from `recordFunctionValueArg`, and an inline closure is walked into its owner. P3 is a stable route dispatch, which `contributeRouteDispatch` adds to the graph. So `detectRecursion` and `recursionReachability` see every cycle.

The argument needs no claim about parameters, holders, returns, `let`, for-of, or match bindings. Each of those can only obtain a function value that already escaped, so the module is already refused. That is why the closed-world rule held where the per-call predicates did not: those had to enumerate every channel, and each review found one more.

P3 relies on ZTS629 (unpublished ambient global). A name that is not yet declared is outside the closed ambient namespace, so ZTS629 refuses it. A route function therefore cannot name the table declared after it. Named mutual recursion is refused by the same rule, because the first function names the second before its declaration. Probes of both shapes report ZTS629, so the call graph's only cycles are self-calls and calls through a value.

## Prevention

- Before adding a position to the closed set, write the probe that tries to recurse through it, and run it end to end with `zts check`. Each rejected position in this work was found by a probe of 5 to 10 lines, not by reading the rule.
- Before allowlisting a virtual-module export in P2b, read its native implementation. Add it only if the callback is called during the call and is neither returned nor stored.
- A consumer of termination must read every reason the graph can be incomplete: recursion, a function-value escape, and a lower-bound row. `cost_bounded` once read only the first of these.
- A rule that the type environment decides must check that every path that consumes it has that environment. The cost path built its facts with `.{}`.
- Regression tests: `packages/tools/src/precompile.zig` (the end-to-end termination probes), `packages/zts/src/function_specs.zig` (`total` refusals and controls), and the escape tests in `effect_inference.zig`. These include the sibling-module test and its clean-sibling control.

## Related Issues

- [a-gate-can-be-non-vacuous-and-still-porous.md](../conventions/a-gate-can-be-non-vacuous-and-still-porous.md): the per-call predicates were porous in this sense. Their probes covered the channels their author named.
- [a-dispatched-route-was-never-walked-so-its-leak-proved-clean.md](a-dispatched-route-was-never-walked-so-its-leak-proved-clean.md): a call through a value that the analysis did not follow, which made a flow proof fail open.
- [a-missing-import-entry-was-conservative-for-one-proof-and-clean-for-another.md](a-missing-import-entry-was-conservative-for-one-proof-and-clean-for-another.md): an unknown sibling result read as clean. Here an unknown sibling result counts as an escape.
- [empty-label-set-claimed-a-value-was-clean.md](empty-label-set-claimed-a-value-was-clean.md): the origin of the fail-open class.
- [zts-rich-surface-small-kernel.md](../tooling-decisions/zts-rich-surface-small-kernel.md): states that admitting recursion does not imply termination. This fix enforces that statement for calls through values.

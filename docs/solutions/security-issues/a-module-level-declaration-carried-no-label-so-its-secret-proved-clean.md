---
title: A module-level declaration carried no label, so its secret proved clean
date: 2026-10-08
last_updated: 2026-10-08
category: security-issues
module: packages/zts/src/flow_checker.zig (module-level declarations and .global bindings)
problem_type: security_issue
component: compiler
symptoms:
  - "`const token = env(\"API_TOKEN\") ?? \"\";` at module scope, returned in a response from `handler`, passed `zts check` with exit 0 and `no_secret_leakage` PROVEN."
  - "The same constant logged in a helper, or captured by a closure, was also unseen."
  - "The leak needed no helper and no closure. The same `env(...)` read inside the handler was refused."
root_cause: logic_error
resolution_type: code_fix
severity: critical
related_components:
  - tooling
tags:
  - zts
  - flow-checker
  - data-labels
  - fail-open
  - module-scope
  - soundness
---

# A module-level declaration carried no label, so its secret proved clean

## Problem

The flow checker walked the handler and the route functions. A module-level `var_decl` is in neither, so no walk ever ran its initializer. The labels of a binding live in a map that the walk fills, so a `.global` binding had no entry. A read of a missing entry returned the empty label set, and the empty set means "this carries nothing". It was a claim made because the walk did not look.

## Symptoms

This handler type-checks, and before the fix it reported `no_secret_leakage` PROVEN:

```js
import { env } from "zttp:env";
const token = env("API_TOKEN") ?? "";
function handler(req) {
  return Response.json({ k: token });
}
```

A sink in a module-level initializer (`const n = console.log(env("API_TOKEN"))`) also never ran, although it runs at load time.

## Solution

`check` now calls `walkModuleDeclarations` before the handler and the route roots. It walks each top-level data declaration in source order, so the labels land under the `.global` key and the sinks in an initializer run. A function declaration and a function-valued constant are skipped: they hold no datum, and a call or a route root walks their bodies. `unrecordedBindingLabels` is the fail-closed half. A `.global` read with no recorded labels carries `.unknown`, and only a function declaration, a function-valued constant, or an import is exempt, each by its kind. The walk sets `walking_module_level` so that a load-time call does not enter the witness stub sequence.

The unit tests are `FlowChecker carries labels on a module-level declaration` and `FlowChecker keeps a property for a module-level clean constant or function`. The second one holds the controls: a clean `env("REGION")` constant and a module-level function in a route table keep the property.

## Why This Works

A property analysis may call a value clean only for a value it read. A declaration that no walk reaches has not been read, so its binding must carry `.unknown` until a walk records labels for it. This is the class in [empty-label-set-claimed-a-value-was-clean](empty-label-set-claimed-a-value-was-clean.md) at a third position: a value whose declaration the walk never entered, next to a route function the walk never entered ([a-dispatched-route-was-never-walked-so-its-leak-proved-clean](a-dispatched-route-was-never-walked-so-its-leak-proved-clean.md)).

The new walk also reached a second defect that had been hidden. `inferLabels` read the operand of a unary operator with `getOptValue`, which returns the first data word of the node. For a unary node that word holds the operator, not the operand. The read dropped the operand's labels, so `!secret` carried nothing, and a module-level `typeof n` walked an unrelated node until the stack ran out. The fix reads the operand with `getUnary`. `FlowChecker carries an operand's labels through a unary operator` pins it.

## Prevention

**Put the labelled value in every place a declaration can live, not only in the handler.** The census rows `module_const_handler`, `module_const_helper`, `module_const_closure`, and the hand probe `x21_module_const_returned_by_handler` do this for the module scope. Run `zig build test-flow-census` and read the fail-open count per verdict.

**Probe the exemptions as well as the fallback.** A fail-closed default for `.global` costs a clean program every property when it also catches a function name or an import. The control tests above and the 61-example comparison of `zts check --json` before and after the change show that cost is zero.

**Treat a new walk as new input.** A walk that starts to reach code it never reached can expose a bug in code that the old walk never ran. Run the mutation test (`pipeline_mutation_tests.zig`), which found the unary defect.

## A captured read had the same defect

A closure that reads a variable of its enclosing function has the same shape. The scope analyzer keys a captured variable by the inner function and an upvalue slot, not by its declaration. The flow checker read that key as an ordinary binding, so a captured secret returned an empty set, or the labels of an unrelated parameter of the inner function that held the same key. `resolveCaptures` now places each captured read against the declarations lexically in scope at the read, by name, in one pass over the IR, and `bindingAt` hands every label lookup the declaration's own binding. A capture that no declaration matches carries `.unknown`. The scan does not run during the label walk, because that walk reaches a closure from the place that calls it and not from the place that declares it.

The tests are `FlowChecker resolves a captured value to the declaration it names` and `FlowChecker keeps a property for a captured value that holds no secret`. The second holds the controls that a union by name would break: a helper that logs its own clean `x` while the handler has a secret `x`, and a closure that captures the function-level `x` after a block with a secret `x` has ended.

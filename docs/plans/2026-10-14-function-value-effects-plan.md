# Plan: charge a function value where it is referenced

Date: 2026-10-14. Status: revision 3, validated by a Codex fact-check and a Fable review. Findings resolved below.

## Problem

`packages/zts/src/effect_inference.zig` charges an import or a user function to the caller's effect row at a call node whose callee it resolves (`handleCall`), at two argument special cases (`recordFunctionValueArg`, `recordImportValueArg`), through inline callback bodies (`walkBaseExpr`, `.function_expr`/`.arrow_function`), and through resolved route targets. Other paths for a function value charge nothing. Measured on `main` with `zig-out/bin/zts check`. Each handler declares `Proof<Response, "retry_safe" | "idempotent">` and writes the cache. Each is discharged with `retry_safe` PROVEN:

- P1: `const f = cacheSet; items.forEach(f);`
- P2: `function w(k) { cacheSet(...); return 1; }` then `const o = { f: w }; const n = o.f("k");`
- P3: `const g = w; items.forEach(g);`
- P4 (local closure passed as a value): `const w = (k) => { cacheSet(...); return 1; }; items.forEach(w);` Nested function declarations and function-valued `const` inside a body are skipped by `walkBaseStmt` (`.var_decl`, `.function_decl` arms) and are not collected by `collectFunctionsIn`, which reads top-level statements only.
- P5 (slot collision): `import { parseBearer as length } from "zttp:auth";` plus `function handler(a, b, c, d) { const f = cacheSet; f(...); }`. The local `f` is in slot 4; the module binding `length` has atom slot 4. `handleCall` looks up `imports` by slot alone, resolves `f` to `parseBearer`, and returns before it sets `lower_bound`. Renaming the import makes the same handler refused.

## Rule

A function body that references an import, a user function, or a module-level binding that holds one, outside callee position, is charged that function's effects as if it called it. A function value created inside a body is charged to that body when it is created. This over-approximates in the safe direction, as `recordFunctionValueArg` already does.

## Changes

0. Binding identity (closes P5). Module imports and module functions have IR binding kind `.global` with atom-backed slots (`packages/zts/src/parser/scope.zig`). Function locals and parameters restart at slot 0. Consult `imports` and `user_fn_by_slot` only when `binding.kind` is `.global` (check the `.upvalue` case: a nested closure that captures a module binding must still resolve). Apply this at every lookup: `handleCall`, the argument special cases, and the new rule. A local that matches nothing then reaches `calleeIsUnresolvable` and becomes `lower_bound`.
1. Local function values (closes P4). In `walkBaseStmt`, walk a body-local function declaration and a body-local function-valued `const` initializer into the owner, as anonymous closures already are. They are not separate units, because `collectFunctionsIn` never records them.
2. Identifier leaf in `walkBaseExpr` (closes P1, P2, P3). When the identifier resolves (under change 0) to an import, charge it as `recordImportValueArg` does. When it resolves to a user function other than the owner, add the call edge as `recordFunctionValueArg` does. Delete both argument special cases.
3. Callee position. In the `.call, .method_call` branch, do not apply the leaf rule to `call.callee` when it is a bare identifier. `handleCall` already charged it, and the discarded-write sink exemption depends on that single charge.
4. Module scope. Before `computeBaseEffects`, walk the program's top-level statements (unwrapping `export_decl`) once. For each module-level `var_decl` whose initializer references a function value, directly or through another such binding, record the set of imports and user functions it holds, keyed by `bool_checker.packBindingKey`. A reference to that binding in a function body, in any position, charges every function in the set. This includes a member receiver (`ops.save()`), an argument (`helper(ops)`), and a callee (`save()` where `const save = cacheSet` at module scope).

## Tests

Regression tests, each shown failing before the change:
- Effect-inference unit tests for P1 to P5, `[w][0]()`, a module-level `const ops = { save: w }` used as `ops.save()`, as `helper(ops)`, and through a second module alias `const ops2 = ops`. Assert `writes` and `!readOnly()`. Add one case per non-write effect: a clock-reading export through P1 demotes `deterministic`, and `fetchSync` through P1 sets `has_egress`.
- One `contract_builder.zig` test: P1 and P5 do not prove `retry_safe` or `idempotent`.

Controls, which already pass and must still pass: `items.map(String)` and `s.toUpperCase()` keep `readOnly()`. A pure helper referenced as a value keeps `readOnly()`. A discarded `logInfo` with no other clock read keeps `deterministic` and still sets `writes`. A local whose slot equals a pure import's atom slot, holding a pure arrow, keeps `readOnly()`. The existing callback, route, and direct-alias tests stay unchanged.

## Risk and measurement

- Over-refusal: a handler that references a writing function without calling it loses `read_only`. Measure with `scripts/verify.sh`, the contract goldens, the flow census, and the example suites.
- Recorded corpus: if `zig build test-expert-app` replay fails because recorded diagnostic text changed, stop and report. Do not call a hosted model.
- Route tables: route functions are already dispatch targets. A stable routed handler must keep its verdicts. Verify with the routed examples and the existing route tests.

## Gates

`zig build test-zts`, `test-contract-golden`, `test-flow-census`, `test-examples`, `test-standin`, `test-diagnostic-corpus`, `test-cli`, `test-zruntime`, `check-spine`, then `bash scripts/verify.sh` (offline).

## Revision 3: resolved review findings

- R1 (Fable 1, Codex): change 1 stands. A closure declared inside a body is walked into the owner. A call to it stays `lower_bound`, as today.
- R2 (Fable 2): the module-scope pass of change 4 walks each module-level initializer completely, including the bodies of closures inside it. It computes one effect row per module-level binding with the same walk as a function body, where callee-position identifiers inside those closure bodies are charged too. Probe: `const ops = { save: (k) => { cacheSet(...); return 1; } };` with `ops.save("k")` in the handler must lose `read_only`.
- R3 (Fable 3): a value reference must not create a call edge. Add a second CSR store, `value_starts`/`value_storage`, beside `callee_starts`/`callee_storage`. `propagate` merges rows across both stores. `detectRecursion`, `reachesRecursion`, and the self-recursion flag read call edges only. The two reachability walks in `contract_builder.zig` (`handlerReachability`, and the budget walk that uses `calleesOf`) read both stores, because a referenced helper can be called and including it is the conservative direction. Expose the second store with a `valueRefsOf` accessor. The existing argument edge from `recordFunctionValueArg` stays a call edge, so recursion through a callback stays detected.
- R4: a call whose callee is a member or computed access rooted at a binding known to hold function values (a module-level binding with a non-empty set, or a body-local binding whose initializer referenced a function value) sets `lower_bound`. This keeps recursion through `ops.a()` from proving `total`. Member calls on other receivers (`s.toUpperCase()`, `items.map(...)`) are unchanged.
- R5 (Fable 4): change 0 is a kind filter: return before the `imports` and `user_fn_by_slot` lookups unless `binding.kind == .global`. Keys stay unchanged.
- R6 (Fable 5): keep walking non-identifier callees (`items.filter(a).map(b)`, `f().g()`). Known asymmetry: a module-level alias `const log = logInfo;` called as a discarded statement is charged without the sink exemption, so it demotes `deterministic`. This is the safe direction; record it in a comment.
- R7 (Fable 6): out of scope. A module-level `Date.now()` or `uuid()` whose value reaches the response is a flow-checker question, because the flow walk decides handler determinism. Record as a follow-up.
- R8 (Fable 7): known over-refusal. A module-level object that mixes data and a writing function charges the function to every reference of the object, because sets are per binding. The rule is sound for the row of the function that creates or references a value. A helper that receives a function through a parameter and calls `o.f()` under-reports its own row; the caller is charged at the reference.
- R9 (Fable 8): before copying `recordImportValueArg`, check whether a module unknown to both registries is refused upstream. If it is not, the new path sets `writes` and `has_egress` for an unknown module, in the same fail-closed direction as `insertModuleCapabilities`.

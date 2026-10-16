# Plan: refuse termination claims when a function value can escape

Date: 2026-10-16. Status: revision 5. Validated by a Fable review of revision 4, with its findings resolved below.

Revisions 1 to 3 tried to find each call that goes through a function value. Three Fable reviews each found admitted programs that the rule missed: a module `let`, a module binding filled by a call, for-of and match-arm bindings, and builtin arguments. Revision 3's predicate also refused 29 of 33 examples, because `Response.json({ ... })` passes an object literal. Revision 4 changes the approach. It does not judge each call. It refuses termination claims for a whole module unless no function value can escape.

## Problem

A function that recurses through a function value proves `total`. A handler that reaches such a recursion proves `cost_bounded`. Both are false proofs. Twenty-five admitted probes show it. Probe files are in `/tmp/zttp-probes/` (p, q, r), `/tmp/zttp-fable/` (f, g), and `/tmp/zttp-factcheck/` (fc1 = `let-fn-capsule.ts`). Each probe passes `zts check` with no error, and `total` or `cost_bounded` is PROVEN, while the program recurses without end.

- Through a returned or stored value: p2g, p2h, q1 to q9 (`wrap(o).a(n)`, `first([down])(n)`, `[down][0](n)`, `(c ? down : down)(n)`, `({ a: down }).a(n)`).
- Through a callback: r4 (`[n].map(down)` inside `down`), r1 (`apply(down, n)`), r6 (a parameter `self: Step`).
- Through a holder: p2c, q7, q8, r8 (`ops.a(n)`), f6 (module `const g: Ops = { f: (x) => g.f(x) }`).
- Through local or module state: f1b (a nested `function g` that calls itself), f3 and f9 (a module `let` reassigned to `down` or to a mutual partner), fc1 (`let slot: Fn = ...`, then `slot = down`), g1 (`items.map(slot)` with `slot` reassigned).
- Through bindings without an initializer: g2 (`const cfg: Ops = compute()`), g3b (for-of over `[down]`), g3c (a match-arm binding).

The controls p2r (direct self-recursion by name) and m1 (named mutual recursion, refused by ZTS629) are refused today.

## Rule

A function value escapes when it appears anywhere other than the three closed positions below. If any function value in a module escapes, no function in that module proves `total`, and no handler in it proves `cost_bounded`. If no value escapes, the existing call graph is complete for termination, with the two additions U3 and U4.

A function value is any of these:
- an identifier that resolves to a collected user function, an imported function, or a module `let` with a function initializer;
- a function or arrow literal;
- the name of a function declared in a body, or of a body-local binding whose initializer is a function or arrow literal.

The closed positions are:
- P0. The declaration site of a function literal: the initializer of a `function` declaration, or of a module or body-local `const` or `let` whose initializer is a function or arrow literal. P0 covers literals only, so `const alias = down` is an escape. `VarDecl.kind` (`parser/ir.zig:390-392`) gives the `let` test.
- P1. The callee of a call by name, where the name is a `const` or `function` declaration or an import, not a `let`.
- P2. The first argument of a member call `R.m(...)`, where `m` is one of `map`, `filter`, `forEach`, `reduce`, `some`, `every`, `find`, `findIndex`, `flatMap`, and `sort`. `R` must not be an identifier for a module binding with `holds` set, or a body-local binding in `holding_names`. The argument must not be a `let`-bound name (g1). These builtins call the first argument and do not return it. Any other argument is not P2: `reduce` returns its second argument, so `xs.reduce((a, x) => a, down)(n)` (h4) escapes.
- P2b. A function argument of a call to an allowlisted virtual-module export that calls the argument during the call, and neither returns nor keeps it. The initial allowlist is `mapResult`, `andThen`, `mapError`, and `orElse` from `zttp:result` (`packages/zts/src/modules/data/result_mod.zig`). The implementer reads each native implementation and confirms this before adding it. A function value passed to any other import escapes. This keeps `examples/patterns/result-combinators.ts`, which passes inline arrows to these four exports.
- P3. A property value of a module-level `const` object literal binding B, when every reference to B is the first argument of a `routerMatch` call whose dispatch `contributeRouteDispatch` resolves as stable. P3 relies on ZTS629: a route function cannot name `routes`, because the table is declared after it (probe `/tmp/zttp-fable/h1.ts`).

## Argument

Assume that no value escapes. A call through a value then calls a value that came from P0 to P3, because no other position can hand a function value to code. A P0 literal is reachable only through its name, and each use of that name is itself one of P1 to P3 or an escape. P1 is a named call, so the call graph has its edge. P2 and P2b are builtins or allowlisted exports that call their argument and do not keep it. The argument is a named function, which has a call edge from `recordFunctionValueArg`, or an inline closure, which the owner walk covers. P3 is a stable route dispatch, which `contributeRouteDispatch` adds to the call graph. So every call that can run has an edge, and `detectRecursion` and `recursionReachability` see every cycle. U3 and U4 close the two remaining gaps inside these positions.

The argument needs no claim about parameters, holders, returns, `let`, for-of, or match. Each of those can only obtain a function value that already escaped, so the module is already refused.

## Changes

- U1. Escape scan. After all bodies are walked, scan every expression in the module once, including module initializers and nested closure bodies. Find each function value. If one is outside P1 to P3, set a module flag `function_value_escapes`. Record the first escaping site (line, column, name) for the diagnostic.
- U2. Consumers. When `function_value_escapes` is set:
  - `CapsuleFacts.holds` refuses `total` for every function. The suggestion names the escaping site, and says that a function used as a value makes termination unprovable.
  - The cost envelope is unbounded, so `cost_bounded` is refused. The description names the escaping site.
  The flag must reach both deciders. The `total` path is `function_specs.zig:124` through `spec_discharge.zig:512-526`. The `cost_bounded` path is `path_generator.zig:1020` through `pipeline.pathEffectFacts` (`pipeline.zig:886-892`). Expose the flag on `EffectFacts` beside `reachesRecursion`.
- U3. Self callback. When `recordFunctionValueArg` sees `callee_idx == owner`, set the owner row's `recursive` flag. P2 then covers `[n].map(down)` inside `down` (r4).
- U4. Lower bound refuses termination. `cost_bounded` also requires that the handler's propagated row has `lower_bound` false. This covers a call by name to a body-local closure or a nested function (f1b). Those names are P1 positions, but no collected function has their edge. A body-local closure that does not name itself keeps today's `lower_bound` verdict (f13 loses `cost_bounded`). Do not add a precision exemption for it in this change.
- U5. Imports. A relative import whose module sets `function_value_escapes` refuses `total` and `cost_bounded` in the importer. Use the dedicated flag, not `lower_bound`, which would also refuse the importer's `Effects` ceiling (ZTS512). Carry the flag through `mergeImportedEffect` (`effect_inference.zig:1593`) or through the export rows at `:537` and `:569`.

Existing tests at `effect_inference.zig:2716`, `:4166`, and `:4310` assert that value references are not recursion. Leave them unchanged. U1 to U5 do not change `recursive` for value references. Only the `total` and `cost_bounded` verdicts change.

## Rejected alternative

P4, an inline arrow passed to a named user function, is unsound. Probe `/tmp/zttp-probes/p4.ts`: `loop((g: Step) => loop(g))` with `loop(f: Step) { return f(f); }` is admitted, proves `cost_bounded` today, and recurses forever. Under revision 5 the arrow escapes, so the module is refused.

## Accepted over-refusals

Each of these shapes lets a function value escape, so its module proves no termination claim:
- a higher-order user helper (`apply(inc, 3)`, r7);
- middleware that takes a `next` parameter (f7);
- a record of functions (f10, and `const table = { f: fmt }` in a non-route position);
- a callback to a builtin outside the P2 list;
- f13, through U4. `examples/handler/sugar.ts` (`const double = (x) => x * 2; double(score)`) is the one example this changes. Its existing ZTS500 message gains `cost_bounded`.

The implementer measures how many examples and goldens change, and lists each one in the commit. The Fable review predicts that 1 of the 33 examples changes (sugar.ts), and that the contract goldens and the stand-in seeds do not. If more than 3 example handlers lose `cost_bounded`, stop and report before the commit.

## Tests

Add effect-inference tests. Each must fail before the change, and the implementer shows that failure. Cover one probe of each group above: p2g, q1, r1, r4, r6, p2c, f1b, f3, fc1, g1, g2, g3b, g3c, f6, h4, and p4. Assert the refusal of `total` or `cost_bounded`, not a neighbouring property. Probes that need `zts check` end to end go in the CLI or contract tests.

Controls that must hold:
- p2r stays refused.
- A handler that calls `Response.json({ ... })`, `req.headers.get(...)`, `s.trim().toLowerCase()`, and `items.map(fmt)` with a named, non-recursive `fmt` keeps `total` and `cost_bounded`.
- `examples/patterns/result-combinators.ts` keeps `cost_bounded` (P2b).
- The three routed examples (`examples/routing/router.ts`, `guard-flow.ts`, `api-surface.ts`) keep `cost_bounded`.
- The tests at `effect_inference.zig:2716`, `:3081`, `:4166`, and `:4310` pass unchanged.

## Gates

Run `zig build test-zts`, `test-contract-golden`, `test-flow-census`, `test-examples`, `test-standin`, `test-diagnostic-corpus`, `test-cli`, `test-zruntime`, and `check-spine`. Then run `bash scripts/verify.sh` offline with a private `ZIG_LOCAL_CACHE_DIR` and `DEEPSEEK_API_KEY` unset. Take each verdict from the exit status of an unfiltered run. If the corpus replay in `test-expert-app` fails because recorded text changed, stop and report. Do not call a hosted model.

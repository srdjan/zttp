---
title: An untyped value passed every typed position
date: 2026-11-02
last_updated: 2026-11-02
category: logic-errors
module: ZigTS type checker and sound-mode checker, value inference, narrowing guards, arithmetic operands, builtin results
problem_type: logic_error
component: tooling
severity: high
symptoms:
  - "`const n: number = g;`, with `g` a named function, passed `zts check` with 0 errors, and `zttp dev` answered 500 with \"Possible soundness incident\"."
  - "`Response.json({ f: g })` passed `zts check` and served `{\"f\":{}}`."
  - "The roadmap described a narrower gap than the probes measured: 15 probes at 8 kinds of typed position passed `zts check`."
  - "`x + 1` with `x: number | undefined` passed `zts check` with `optionals_safe` PROVEN, and `zttp dev` answered 500 with \"Possible soundness incident\"."
  - "`const token: string = req.headers.get(\"x\");` passed `zts check`, and `zttp dev` answered 500 with \"Possible soundness incident\" for a missing header."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
tags:
  - type-checker
  - fail-open
  - null-type
  - function-values
  - narrowing-guards
  - false-proof
  - soundness-probe
  - sound-mode
  - arithmetic-operands
  - builtin-results
  - callback-types
---

# An untyped value passed every typed position

## Problem

`inferType` in `packages/zts/src/type_checker.zig#TypeChecker` returns `null_type_idx` for an expression form that it does not type. Each assignability check reads `null_type_idx` as "unknown" and passes. So a form that `inferType` does not type passes at every typed position at the same time, with no diagnostic.

Until commit `9ce546c0` on local `main`, a function value was such a form. An arrow, a `const` bound to an arrow, and a named function all inferred to `null_type_idx`. A function therefore passed as a `number` in a `return`, an annotation, an assignment, a record field, an array or tuple element, a call argument, and a JSON payload.

## Symptoms

- `zts check` accepted a handler that used a function as a number, under a narrow `Proof<Response, ...>` capsule.
- `zttp dev` then answered 500: "Possible soundness incident: the handler faulted on a path proven optional_safe/result_safe".
- The roadmap described a narrower gap than the probes measured. The F1 table in the plan lists 15 probes at 8 kinds of typed position, and all 15 passed.

## What Didn't Work

- **A fix at one sink.** An earlier check typed only an arrow literal at a call argument (`argumentTypeForChecking`). Every other sink still read `null_type_idx` and passed. A fix at a sink closes one position. A type at the source closes all of them.
- **An empty parameter list in the new type.** The first fix gave a function value the type `() => R`. Then `const JSON = { stringify: (value) => "ignored" }; JSON.stringify(x)` got a false ZTS202, "expected 0, got 1". The member call reads its arity from the field type, and `() => R` looks the same as a declared zero-parameter function. The type needs one parameter for each parameter node.
- **Reuse of a guard as a proof.** The type predicate check (commit `471d4d14`) computes what the body's test proves by running the narrowing guards. `extractDiscriminantGuard` took the first union member whose discriminant matched. With two members that share `kind: "a"`, the guard was a false proof, and the predicate check inherited it. A check that reuses a guard is only as sound as that guard, so the guard was fixed in the same unit.

## Solution

`inferType` now gives a function value a function type, so every existing check sees it:

- For an arrow or a function expression, there is one parameter for each parameter node. A parameter takes the signature's type only when the signature has one entry for each node. Otherwise, the parameter type is `unknown`.
- A generic signature gives `unknown` parameters and no return type, so no type parameter reaches a check unresolved.
- An identifier bound to a function gets the same shape from its recorded callable metadata.
- Generic inference keeps the old empty list (`functionExprType`), so an unresolved callback still reads as ambiguous.

The discriminant guard now keeps every member that can hold the literal on the then-side. It keeps every member whose field is not exactly the literal, is optional, or is absent on the else-side.

## Second instance: a coarse lattice read "cannot name" as "pass"

The same fail-open was also in a second checker. The sound-mode arithmetic check (`requireNumeric` and `requireAddable` in `packages/zts/src/bool_checker.zig#BoolChecker`) reads its own small type lattice. That lattice has no member for an optional number or for `null`. An optional number, a `null`-admitting type, and the declared type `unknown` all mapped to the member `.unknown`, and the check passed `.unknown` with the comment "defers to runtime". The runtime did fault, but the verifier had already proven `optionals_safe`. The unary minus had no operand check at all.

The 2026-11-02 arithmetic plan measured eight such handlers. Examples are `x + 1` with `x: number | undefined`, `b.n - 1` with an optional field, `xs[5] + 1`, `v * 2` with `v: unknown`, and `-b` with `b: boolean`. Each one passed `zts check`, and `zttp dev` answered 500 with "Possible soundness incident".

The fix (commit `c92f8f67` on local `main`) keeps every lattice verdict. Where the lattice answers `.unknown`, the check reads the type that the type checker recorded for that operand while its narrowing was live (`recordContextType` and `contextTypeOf` in `packages/zts/src/type_checker.zig#TypeChecker`). The boolean-context check `requireBoolean` already worked this way. A typed operand that is not assignable to `number` gets ZTS104, or ZTS106 for `+`.

**What did not work: refusing an operand with no type.** The first plan also refused an operand for which the type checker returns `null_type_idx`. A Fable review found, before any code changed, that the type checker leaves common numeric forms untyped: `xs.length`, `Math.floor(...)`, and `parseInt(...)`, among others. That refusal would have refused valid code such as `xs.length - 1`. The fix lets an untyped operand pass, and the roadmap lists the limit. The untyped forms were themselves a false proof of the kind in this doc: `const a: string = xs.length;` passed, and `a.toUpperCase()` then faulted. The third instance below gave these forms their types.

## Third instance: a type for a builtin result is a claim

The builtin result types plan gave builtin calls their types (commits `cf174f2c`, `019cf970`, and `7cd53c65` on local `main`, pending release). Before it, `const token: string = req.headers.get("x");` passed, and a missing header faulted at runtime.

A type at the source closes the fail-open only when the type is true. A builtin returns its normal result only when its arguments have the types that the runtime reads. `Math.floor("x")`, `s.split(5)`, and `Object.keys(5)` each return `undefined`. So each row in `packages/zts/src/builtin_results.zig` declares the parameter types that the runtime reads, and a result stays untyped when an argument has no type or the wrong type. The checker adds no argument diagnostic.

**What did not work: a row that the gates accepted.** Two implementer drafts passed every gate and still claimed a false type. Opus found both by reading the runtime code for each row:

- `s.split(x)` was `string[]` for any separator. The separator is now `string`.
- `map` and `reduce` took the callback's declared return type and did not check the callback's parameters. `strings.map(g)` with `g: (n: number) => number` was `number[]`, but `g` gets strings and `n + 1` returns `"a1"`. A result that comes from a callback now needs each callback parameter to accept what the runtime passes: the element, the index, and the array. For `reduce`, the accumulator gets the seed first and each callback result after it.

**What did not work: the declared fields as a bound.** The plan typed `Object.values` from the declared field types. A record can hold a field that its type does not name, so that type would be a new false proof. `Object.values` and `Object.entries` stay untyped.

**An entry check before a refusal.** The plan's last step would refuse an arithmetic operand with no type. Its entry check applied the change first and listed every operand that it refused in `examples/`, `tests/corpus/`, the fixtures, and the offline replay. The check refused `examples/patterns/result-combinators.ts`, a valid program whose `zttp:result` combinator callbacks have untyped parameters. So the step was not built, and `docs/roadmap.md` lists the remaining untyped sources.

## Why This Works

The hole was at the source: one inference result that every consumer reads as "pass". A type at the source reaches each consumer at once, including sinks that no one listed, such as the ZTS213 JSON check. Nineteen new tests failed on the previous commit and pass now.

## Prevention

- Treat `null_type_idx` from `inferType` as a fail-open at every typed position. When a new expression form is added, give it a type, or show that no typed position can receive it.
- A secondary checker with a coarser type model than the type checker must not read "I cannot name this type" as "pass". Ask the type checker for the type it recorded with narrowing live, as `requireBoolean` and the arithmetic checks now do.
- Before a check refuses an operand with no type, list the forms that the type checker leaves untyped at that position, and probe each one with `const s: string = <form>;`. Silence means the form has no type.
- Find false proofs with a runtime probe, not only with `zts check`. Write a handler with a narrow `Proof<Response, "deterministic" | "read_only">` capsule so that `zts check` passes. Serve it with `zttp dev` and send one request. A fault prints "Possible soundness incident". This found each false proof of the 2026-11-02 plan.
- Measure a reported gap before you plan its size. Probe the same wrong value at each kind of typed position.
- When you give a source a type, take the type from the runtime code, under the argument types that the runtime reads. A result that comes from a callback also needs the callback parameters to accept what the runtime passes. Read each row against the runtime: the gates passed both false rows of the third instance.
- Before you build a refusal, apply it and list every program that it refuses in the examples, the corpus, the fixtures, and the offline replay. Build it only when each refused value is truly unknown at runtime.
- `docs/roadmap.md` lists the type checker gaps that stay open. For two of them, `zttp dev` measured a wrong result: an annotated callback parameter that does not fit the array elements, and a discriminant test that meets a record with an extra field.

## Related Issues

- [Function values and type predicates plan](../../plans/2026-11-02-function-values-and-predicates-plan.md): findings F1 to F5, the probes, and the execution record.
- [Arithmetic operand types plan](../../plans/2026-11-02-arithmetic-operand-types-plan.md): probes A1 to A8, finding B1, the validation record, and the execution record.
- [Builtin result types plan](../../plans/2026-11-02-builtin-result-types-plan.md): findings F1 and F2, the deviations that review found, and the failed entry check of U3.
- [testing-effect-instead-of-form-refused-the-canonical-predicate](testing-effect-instead-of-form-refused-the-canonical-predicate.md): the type predicate admission history, which the same plan changed.
- [a-proxy-signal-carried-a-proof-it-never-claimed](a-proxy-signal-carried-a-proof-it-never-claimed.md): another false PROVEN from a value read as an answer it never gave.

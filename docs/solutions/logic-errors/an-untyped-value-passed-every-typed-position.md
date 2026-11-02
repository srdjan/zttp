---
title: An untyped value passed every typed position
date: 2026-11-02
category: logic-errors
module: ZigTS type checker, value inference and narrowing guards
problem_type: logic_error
component: tooling
severity: high
symptoms:
  - "`const n: number = g;`, with `g` a named function, passed `zts check` with 0 errors, and `zttp dev` answered 500 with \"Possible soundness incident\"."
  - "`Response.json({ f: g })` passed `zts check` and served `{\"f\":{}}`."
  - "The roadmap described a narrower gap than the probes measured: 15 probes at 8 kinds of typed position passed `zts check`."
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

## Why This Works

The hole was at the source: one inference result that every consumer reads as "pass". A type at the source reaches each consumer at once, including sinks that no one listed, such as the ZTS213 JSON check. Nineteen new tests failed on the previous commit and pass now.

## Prevention

- Treat `null_type_idx` from `inferType` as a fail-open at every typed position. When a new expression form is added, give it a type, or show that no typed position can receive it.
- Find false proofs with a runtime probe, not only with `zts check`. Write a handler with a narrow `Proof<Response, "deterministic" | "read_only">` capsule so that `zts check` passes. Serve it with `zttp dev` and send one request. A fault prints "Possible soundness incident". This found each false proof of the 2026-11-02 plan.
- Measure a reported gap before you plan its size. Probe the same wrong value at each kind of typed position.
- `docs/roadmap.md` lists four type checker gaps that stay open. For two of them, `zttp dev` measured a wrong result: `x + 1` with `x: number | undefined`, and a discriminant test that meets a record with an extra field.

## Related Issues

- [Function values and type predicates plan](../../plans/2026-11-02-function-values-and-predicates-plan.md): findings F1 to F5, the probes, and the execution record.
- [testing-effect-instead-of-form-refused-the-canonical-predicate](testing-effect-instead-of-form-refused-the-canonical-predicate.md): the type predicate admission history, which the same plan changed.
- [a-proxy-signal-carried-a-proof-it-never-claimed](a-proxy-signal-carried-a-proof-it-never-claimed.md): another false PROVEN from a value read as an answer it never gave.

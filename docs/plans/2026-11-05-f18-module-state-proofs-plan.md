# F18: proofs for handlers that write module state

Finding F18 (2026-11-04 review): `zts check` reports five properties PROVEN for a handler that changes a module-level array. The owner chose Decision 3 option (a) on 2026-11-05: research it read-only, then write a fix plan for approval. This document is that plan. It is not approved.

## Status

| Unit | Status |
|---|---|
| H1 | Complete: `4584ecca`. A mutating array method on a module binding, an alias, or a member chain raises ZTS310, in the handler, nested arrow functions, and helpers. The list of mutating methods is shared in `packages/zts/src/mutating_methods.zig` |
| H2 | In progress |
| H3 | Not started |

## Reproduction

Observed at `b603a8d2`. This handler passes `zts check` with 0 errors and 0 warnings:

```ts
const seen: number[] = [];
function handler(req: Request): Response {
  seen.push(1);
  return Response.text(String(seen.length));
}
```

`state_isolated`, `deterministic`, `read_only`, `retry_safe`, and `idempotent` are PROVEN. `zttp serve` returned 2, 3, 4, 5, and 6 for five identical requests. `zttp deploy --no-attest` records all five as true with `proofLevel: "complete"`. A signed deploy logs "Proof accepted" and serves the same sequence.

## Cause

Observed:

- Rule ZTS310 sets `has_module_mutation` only for assignment nodes: `checkModuleScopeMutation` from the request walk and `checkHelperWrite` from the helper sweep, both in `packages/zts/src/handler_verifier.zig#HandlerVerifier`. A call to `push`, `pop`, `shift`, `unshift`, or `splice` on a module binding is not checked.
- `state_isolated` is the only property that reads `has_module_mutation`. `read_only` and `retry_safe` come from the virtual-module effect row (`packages/zts/src/effect_inference.zig`, `packages/zts/src/contract_builder.zig`). `idempotent` is `deterministic` and `retry_safe`. `deterministic` comes from the flow walk (`packages/zts/src/flow_interp.zig`), and a read of module state carries no nondeterministic label.
- The acceptance kernel does not check `state_isolated`, `deterministic`, `read_only`, or `retry_safe` itself (`Property.consumerChecked` in `packages/proof-checker/src/proof_system.zig`). It accepts them as the producer's disclosure.
- For a handler with a ZTS310 finding, the ZTS500 hint suggests a capsule that claims `pure` and `stateless`.

Inferred: the analyzer treats "no virtual-module write" as "no write". Module state is outside the effect row.

## Shapes

| Shape | Today | After H1 and H2 |
|---|---|---|
| Module `let` reassignment, member write, constant-index write | ZTS310 error; other four PROVEN | ZTS310 error; other four not proven |
| `push`, `unshift`, `pop`, `shift`, `splice` on a module array in the handler | five PROVEN, exit 0 | ZTS310 error |
| The same calls in a helper | five PROVEN, exit 0 | ZTS310 warning, `state_isolated` not proven |
| Alias: `const a = seen; a.push(1)` | five PROVEN, exit 0 | ZTS310 |
| Arrow function in the handler that pushes onto a module array | `state_isolated` PROVEN | ZTS310 |
| Helper that assigns a module member, narrow capsule without `state_isolated` | ZTS310 warning, exit 2, four PROVEN | ZTS500: the capsule claims a property that does not hold |
| Module array passed to a helper that pushes onto its parameter | five PROVEN, exit 0 | unchanged: residual gap |

The `sort` and `reverse` methods are refused today (ZTS201). A dynamic index write is refused today (ZTS605).

## Units

| Unit | Change | Main files | Model | Turn budget |
|---|---|---|---|---|
| H1 | ZTS310 for a mutating array method on a module binding or an alias of one, in the handler, in helpers, and in nested arrow functions. One shared list of mutating methods | `packages/zts/src/handler_verifier.zig`, `packages/zts/src/type_checker.zig` | Sonnet | 60 |
| H2 | When `has_module_mutation` or `unresolved_route_dispatch` is set, `read_only`, `retry_safe`, `deterministic`, `idempotent`, `pure`, and `stateless` are not proven, and the ZTS500 hint does not suggest them | `packages/zts/src/contract_builder.zig` and the hint producer | Sonnet | 50 |
| H3 | Documentation, the residual gap, the website check, and the full gate | `docs/verification.md`, this plan, `docs/plans/2026-11-04-review-fixes-plan.md` | Opus | not applicable |

Each unit starts with failing tests through `zts check` and the mutation table test in `handler_verifier.zig`. Each test names the expected diagnostic code and the literal property verdicts. H1 tests: the `push`, `unshift`, `pop`, `shift`, `splice`, helper, alias, and arrow shapes above. H2 tests: the narrow-capsule shape must fail with ZTS500, and the hint for the `let` reassignment shape must not name `pure`, `stateless`, `read_only`, `retry_safe`, `deterministic`, or `idempotent`.

Gates for each unit, unfiltered: `zig build test-zts`, `test-zts-cli`, `test-contract-golden`, `test-expert-golden`, `test-diagnostic-corpus`, `test-standin`, `test-expert-app` with `DEEPSEEK_API_KEY` unset, `test`, and `check-spine`. After H2, `bash scripts/verify.sh` runs on `main`.

## Risks

- H1 and H2 add no diagnostic code. A recorded corpus handler that changes module state can still get a different verdict, and its recorded diagnostic text then fails the replay. If that happens, the corpus needs a DeepSeek re-record, which the owner runs. H1 measures this first with the offline replay.
- H1 changes ZTS310 from assignment-only to also cover calls. A handler that builds a module table at load time is probably not affected, because the check runs only on the request walk and the helper sweep. H1 tests this with a load-time `push` that must stay accepted.
- The parameter case stays open. Closing it needs a per-function summary of the parameters that a function changes, or a readonly type for module bindings in function bodies (option C in the research). Either is a separate decision.

## Decision 5

Option (a), recommended: run H1 to H3, commit each on local `main`, and do not push. Option (b): H1 only, which closes the method shapes but leaves the other four properties PROVEN beside a ZTS310 finding. Option (c): make module bindings readonly in function bodies instead. This also closes the parameter case, but it can refuse existing handlers and move the convergence numbers.

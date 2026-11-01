# Module graph certificates worklog, 2026-11-01

This worklog records execution of the [module graph certificates plan](2026-11-01-module-graph-certificates-plan.md).
It holds commands, exit statuses, and deviations. The plan owns the design.

## Validation of the plan

Decision 6 (a) selected two validations. Each one read the plan at `fdff4cf4` and edited nothing.

A Codex fact-check confirmed 100 claims, and it reported 3 wrong claims and 15 imprecise claims. Revision 2 corrects each one. Two of them changed the design. An error inside `ModuleGraph.build` would reach model-visible output through `discoverModulePaths`. The Result limit does not fail closed.

A Fable review of the argument reported one blocker, four major findings, and five minor findings. Revision 2 folds in all ten.

| Finding | Change in revision 2 |
|---|---|
| A budget survives a merge with its ZTS607 dropped, so the certificate claims `capability_bounded` | Unit G3 unions `spec_diagnostics` and refuses on errors |
| A dependency can bind a built-in name such as `Response` | Unit G1 refuses it |
| An imported value has no type, so an entry can return a `string` as a `Response` | New Unit G2b |
| The gate would drop at Unit G4, because the refusal fires only with no certificate | Unit G5 now wires the evidence |
| An AND of per-module verifier results needs helpers to be request roots | New Unit G1b, which also fixes a single-file defect |
| The residual plan must stay sorted, import aliases count as bindings, ZTS609 must stay enforced | Units G4, G1, and G2a |

I probed each load-bearing claim before I changed the plan. The Fable review inferred that same-file helpers share the `state_isolated` gap, and the probe confirmed it.

## Probe sources

Each probe ran at `8d62cb07` through `zttp serve`, `zttp check`, or `zttp compile`.

Name collision, `label`:

```ts
// a.ts
function label(): string { return "a"; }
export function fromA(): string { return label(); }
// b.ts
function label(): string { return "b"; }
export function fromB(): string { return label(); }
// h.ts
import { fromA } from "./a.ts";
import { fromB } from "./b.ts";
export function handler(req: Request): Response {
  return Response.text([fromA(), fromB()].join(""));
}
```

Built-in shadow:

```ts
// dep.ts
const Response = { text: 5 };
export function viaDep(): number { return Response.text; }
// h.ts
import { viaDep } from "./dep.ts";
export function handler(req: Request): Proof<Response, "state_isolated"> {
  const n = viaDep();
  return Response.text(String(n));
}
```

Return of a dependency string:

```ts
// dep.ts
export function greet(): string { return "x"; }
// h.ts
import { greet } from "./dep.ts";
export function handler(req: Request): Proof<Response, "state_isolated"> {
  return greet();
}
```

State through a same-file helper:

```ts
let count = 0;
function bump(): number { count = count + 1; return count; }
export function handler(req: Request): Response {
  return Response.text(String(bump()));
}
```

The binary from `zttp compile` served 2, 3, 4, 5 on four requests.

Failed top-level assert:

```ts
// dep.ts
assert 1 === 2, "boom";
export function later(): string { return "x"; }
```

The entry-only certificate spike set `cg.witness` on the entry module in `compileAll`, built evidence with no strict checker, and forced `properties` true in `compileMultiModule`.

## G0

Status: complete on 2026-11-01 at `b050ccab`.

From an empty cache and with no provider key, `zig build test` exited 0: 214 of 214 steps, 8469 of 8475 tests, 6 skipped. `zig build` exited 0. The digest tables match `bf19a10a`: `zts check` and `zts compile` each moved 0 of 215 rows. Table hashes, first 16 hex digits: check `f3f96aea53920149`, compile `ef6ae4c00207df54`, surface `ce54095059001b3b`. The disk had 14 GiB free.

## G1

`ModuleGraph.checkBindings` refuses an ambiguous top-level binding, a reserved name, a dependency that binds `handler`, and a missing export. `compileMultiModule`, `extractMultiModuleContractWithEntry`, and the runtime source load path call it. `build`, `discoverModulePaths`, and `zttp check` do not.

Sonnet implemented the unit, and I reviewed the diff. The red run failed 10 of 24 tests against a stub, for example "expected error.AmbiguousBinding, found void".

My review added three items that the plan did not name. The list of runtime-only names moved to `packages/zts/src/known_globals.zig`, and a census in `packages/runtime/src/zruntime_tests.zig` iterates every installed global. Removing the `console` row failed the census, so the census kills that mutant. The census skips a name with `%`, `:`, or `#`, because no module can bind such a name. The `serve` smoke step has a 60-second alarm. A 20-second alarm on a direct probe fired once while `zig build test` loaded the host, so I did not use a shorter value.

`packages/zts/src/engine_root.zig` gained one line, outside the plan's file list. The existing module graph tests were never collected, so no suite ran them. They run now.

The gate found one miss of mine: the `pipeline.zig` catch needed a row in `scripts/proof-swallow.allow`. It returns the same error after it prints the message.

Results at the G1 tree, each from an unfiltered run: `zig build test` 214 of 214 steps, `test-zruntime` 274 of 275 tests with 1 skipped, and `test-cli`, `test-bytecode-identity`, `smoke-v1`, `test-module-boundary`, `test-expert-app`, `test-proof-swallow`, and `zig fmt --check packages scripts` exit 0. Against the G0 tables, `zts check` moved 0 of 215 rows, `zts compile` moved 0 of 215 rows, and the command surface moved 0 of 38 rows.

Probes through `zttp compile` and `zttp serve` exit 1 with the identifier and files for eight cases: `label`, `helper`, a `const` collision, a `let` collision, a dependency `const Response`, a dependency `handler`, a missing export, and an alias whose local name collides. `examples/handler/handler-with-imports.ts` serves 200. The corpus case `sibling-helper-holes` loads and serves its own 503 body `{"error":"unconfigured"}`.

**Correction to the plan for G1b.** The plan calls Checks 6 and 7 "the two state checks". In `packages/zts/src/handler_verifier.zig`, Check 6 is optional checking and only Check 7 is state isolation. A probe at `8d62cb07` read an optional in a helper through `env`, and `zts check` reported ZTS309 from another path. Check 6 therefore has no helper gap to close, and G1b changes Check 7 only.

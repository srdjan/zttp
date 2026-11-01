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

## G1b

`HandlerVerifier.verify` now sweeps every function that is not a request root. A write to module state in such a function sets `has_module_mutation` and adds a ZTS310 warning. A direct write in a request root stays the ZTS310 error. The sweep does not follow calls, so a helper that only module initialization calls also clears `state_isolated`. A write through a function parameter is not modeled.

The red run failed at `expect(!result.state_isolated)` in the test "check does not prove state isolation when a same-file helper mutates module state", because the value was true.

Sonnet implemented the unit, and I reviewed the diff. My review replaced the loops in two tests with literal assertions, renamed one test that claimed a binary compile, and added a `smoke-v1` step for the capsule-dependent result through `zttp compile`.

Behavior of the `count` probe through `zttp check` and `zttp compile`:

| Capsule | `zttp check` | `zttp compile` |
| --- | --- | --- |
| `Proof<Response, "state_isolated">` | Exit 1, ZTS500 | Exit 1, no binary |
| No capsule | Exit 1, ZTS500 on the default profile | Exit 1, no binary |
| `Proof<Response, "deterministic">` | Exit 2, one ZTS310 warning | Exit 0 |

The binary from the third row booted with "Proof accepted: weakest edge trusted, 3 disclosed edge(s)" and served 2, 3, 4 on three requests after its readiness probe. That capsule does not claim `state_isolated`, so this behavior is by design. `zttp check` already exits 2 on any warning.

Results at the G1b tree, each from an unfiltered run: `zig build test` 214 of 214 steps, `test-zruntime` 274 of 275 tests with 1 skipped, and `test-cli`, `test-bytecode-identity`, `smoke-v1`, `test-module-boundary`, `test-expert-app`, `test-proof-swallow`, and `zig fmt --check packages scripts` exit 0. `test-expert-app` holds the replay.

Against the G0 tables, `zts compile` moved 0 of 215 rows and the command surface moved 0 of 38 rows. `zts check` moved 1 of 215 rows, the named exception of this unit. The row is `tests/corpus/check/bad/module_scope_mutation.ts`. A byte comparison shows that the only difference is the `.failing` proof trace text, which now reads "A function mutates a module-scope variable." The exit status and stderr of that row did not move. No corpus case moved, so the stop condition did not apply.

## G2a

`compileMultiModule` now calls `checkGraphModule` for each module in execution order, after code generation. The function runs virtual import validation, the boolean, type, and strict checks, the verifier when `emit_verify` is true, and the bytecode verifier. The entry was unchecked before this unit too. Flow stays out of scope until G3.

A dependency has no handler, so `HandlerVerifier.verifyModule` checks it. It runs the import scan, unresolved route dispatch, the G1b helper sweep with no request roots, the Result check over the program, the typed absence check, and the unused-import report. It leaves out return totality, the Optional narrowing walk, and unused-variable reporting, because each one needs a handler. ZTS309 still reaches a dependency through the typed absence check. The plan's stop condition did not apply.

`StrictChecker.allow_raw_exported_boundary` exempts a dependency from ZTS061 alone. `checkExportedBoundaryTypes` emits no other kind, so the exemption goes by diagnostic kind, and ZTS609 stays enforced. A dependency with a top-level `assert`, nested in a top-level block or not, fails with `error.DependencyTopLevelAssert`. That refusal has no ZTS code, so it needs no defect seed.

Sonnet implemented the unit, and I reviewed the diff. Three decisions came from the implementation:

- `verifyModule` also runs `checkUnresolvedRouteDispatches`, so an unresolvable route dispatch in a dependency is a verifier error, as it is for a handler.
- A graph verifier failure returns `verify_failed` without the violations JSONL and summary of the single-module path. The diagnostics still print, and the build stops.
- The test "compileHandler graph accepts current type boolean and strict diagnostics" asserted the defect, so "compileHandler graph rejects an entry with an unsupported extension" replaced it and keeps its extension case. Three other tests gained type annotations, because their untyped sources now fail ZTS601.

The red run failed 11 of 17 tests, for example "expected error.SoundModeViolation, found .{ .bytecode = ... }". That run used a filter, so it shows only the red state.

No test can drive the bytecode verifier to fail from source, so no test kills a mutant of that call.

Results at the G2a tree, each from an unfiltered run: `zig build test` 214 of 214 steps, `test-zruntime` 274 of 275 tests with 1 skipped, and `test-cli`, `test-bytecode-identity`, `smoke-v1`, `test-module-boundary`, `test-expert-app`, `test-proof-swallow`, and `zig fmt --check packages scripts` exit 0. The `git diff` on `packages/proof-checker` is empty.

Against the G0 tables, `zts check` moved only the G1b row, and the command surface moved 0 of 38 rows. `zts compile` moved 1 of 215 rows: `examples/handler/handler-with-imports.ts`. Its `out.zig`, `contract.json`, and stdout are byte-identical. Its stderr gained a correct ZTS305 warning for the unused `body` variable in that example, because the entry now reaches the verifier.

## G2b

On the compile path, a file import now carries the type of its export. `TypeChecker.recordExportedSignatures` copies each exported signature and value type into an `ExportedSignatures` table, which owns its own pool. `TypeChecker.materializeFileImports` copies each one into the importer's pool. `Copier` in `packages/zts/src/import_signatures.zig` resolves a structural alias to its base type, so Decision 3 (a) holds. A nominal type reuses the importer's type of the same name, so `Response` stays one type. The file import table is null on every other path, so `zttp check`, `packages/pi`, and `ModuleGraph.build` do not move.

The `greet` probe now fails with `type error[ZTS204]: return type does not match declared return type`, the diagnostic of a same-file function. A dependency helper that declares `Response` compiles and reaches the missing certificate refusal.

**Change from the plan.** The plan and my first brief left an import unknown when its type could not cross, and refused only a request-root `return` of it. My review found that this leaves a gap. `pick(env("X"))` with a generic `pick` from a dependency compiled and read `.length`, and the same-file form reports ZTS309. `for (const r of wrap(["a"])) { return r; }` compiled a string return from a handler. An unknown value has too many positions for a walk to cover, so that walk is gone.

The rule is now that no unknown file import reaches the checks. A data export gets its declared or inferred type. Any other file import with no type fails with `error.FileImportUntyped`, whether the module uses it or not: a generic export, a type predicate, a recursive alias, or a type that does not copy. This rule can widen later. No working build depends on it, because a handler with file imports stops at the missing certificate until G5.

A Result cannot cross a file import in a form that I could build. A function with a declared `Result<object>` return that returns `jwtVerify` fails ZTS204 in a same-file build too, so no test exists for that case.

**Correction to G1.** `import { Label }` for an exported type now fails `checkBindings`, and it served 200 at G0 with a ZTS306 warning. I kept the refusal, because a value import of a type leaves that binding undefined at run time. The message now names `import type`.

Two nominal types with one name in two modules read as one type across a file import. No certificate property reads a nominal name.

Sonnet implemented the unit in two rounds, and I reviewed each diff. The first red run failed 10 of 443 tests. The second red run failed 6 of 36 tests. It used a filter, and it ran with the new code switched off, because the tree already held that code. My gate run found one miss: `scripts/zts-tiers.allow` had no row for the new file. `packages/zts/src/import_signatures.zig` is now in the `scripts/check-proof-swallow.sh` file list.

Results at the G2b tree, each from an unfiltered run: `zig build test` 214 of 214 steps, 8045 of 8051 tests with 6 skipped, `test-zruntime` 274 of 275 tests with 1 skipped, and `test-cli`, `test-bytecode-identity`, `smoke-v1`, `test-module-boundary`, `test-expert-app`, `test-proof-swallow`, and `zig fmt --check packages scripts` exit 0. `examples/handler/handler-with-imports.ts` and the expected handler of `sibling-helper-holes` compile with exit 0.

Against the G2a tables, `zts check` and `zts compile` each moved 0 of 215 rows. The command surface moved 0 of 38 rows against G0.

## G3

`compileMultiModule` now builds its contract from a full entry contract and folds each dependency into it. The flow pass reads the modules of `ModuleGraph`, each module once, in load order. The entry is module 0, and a shared dependency initializes once. The refusal for a handler with file imports stays in place until G5.

The contract of `examples/handler/handler-with-imports.ts` now holds real values. `faultCovered` and `costBounded` read true, and `maxIoDepth` reads 0, because its dependency makes no module call. `pure` reads false, because the entry calls a file import. Its digest row moved in `zts compile`, which the plan names under "Moved by this plan".

**Decision on `cost_bounded`.** The Sonnet hand-back cleared `cost_bounded` on every graph, and it said that the path generator does not walk a callee. That statement is wrong for a same-file helper: a single-file probe gave a `linear` bound with its source at the helper loop. The gap applies only to a call across files.

The bound counts module calls on the paths of the entry. A dependency that is `pure` makes no module call, so the bound stands. Any other dependency adds calls that the entry paths do not show, so `cost_bounded`, `max_io_depth`, and `cost_envelope` are all cleared. The third field matters, because `zttp deploy` writes the envelope into the proof ledger, and an entry-only envelope understates the cost. A chain of pure helpers gives `costBounded` true and `maxIoDepth` 0.

The corpus handler of the case `sibling-helper-holes` keeps its refusal for this reason. Its capsule demands `cost_bounded`, and its dependency `lib/settings.ts` calls `env`. Decision 5 accepts that the build is stricter than `zttp check`, and G6 must record the case.

**Budget.** `Effects<...>` is a capability set, not a call count. ZTS506 and ZTS607 run on the entry, and the merged capability set reaches them, so a dependency call outside the entry ceiling exits 1. `capability_bounded` is not a field of `HandlerProperties`. It stays derived in `packages/runtime/src/build_command.zig#dischargedProperties`.

**Measured.** `fault_covered` fails closed across two import levels. Entry to `a` to `b`, with an unguarded failable call in `b`, gives false. The same chain of pure helpers gives true. `pure` reads false for an entry that calls any file import, because the call counts as a call. So a handler with no capsule that calls a file import fails the default profile in `zttp compile`.

**Open for G5.** `refuseSpecErrors` in `precompile_contract.zig` skips `implicit_default` diagnostics, as the single-module path does. The entry-only CHECK in `runBuild` gates the default profile. The measured `pure` rule above covers a no-capsule entry that calls a file import. A no-capsule entry that imports a dependency and never calls it is not yet measured. G5 must probe that case, and it must gate the merged contract if the case passes.

**Limits.** Three records describe the entry paths only: `cost_envelope` when the bound stands, `behaviors`, and `fault_coverage`. Dependency helper capsules stay hidden, because dependency extraction reads the contract only. The diamond test asserts the views and the order on the constructor, and the end-to-end compile of a diamond holds `no_secret_leakage`.

Sonnet implemented the unit, past its turn budget at about 62 turns. The first red run failed 16 of 466 tests. I reviewed the diff and changed the fold for `cost_bounded`.

Results at the G3 tree, each from an unfiltered run: `zig build test` 214 of 214 steps, `test-zruntime` 274 of 275 tests with 1 skipped, and `test-cli`, `test-bytecode-identity`, `smoke-v1`, `test-module-boundary`, `test-expert-app`, `test-proof-swallow`, `zig fmt --check`, and `zig build` each exit 0. `test-precompile` passed 468 of 468 tests. The test count of `zig build test` is not comparable with G2b, because a warm cache leaves cached steps out of the summary. G7 gives the count from an empty cache.

Against the G0 tables, `zts check` moved only the G1b row. `zts compile` moved 1 of 215 rows, `examples/handler/handler-with-imports.ts`. The command surface moved 0 of 38 rows. `git diff` on `packages/proof-checker` is empty.

## G4

The fold works, and the kernel accepts it. `foldEvidence` in `packages/zts/src/proof_ir.zig` joins the evidence of each module into one program, and a certificate from that program passes production acceptance. No kernel stage refused a fold, so Decision 2 stays closed. The refusal for a handler with file imports stays in place until G5.

**Change from the plan.** The plan says that `compileMultiModule` does not return the evidence yet, but the acceptance tests need it. The evidence therefore sits in a new field, `CompiledHandler.graph_evidence`. `proof_evidence` stays null, so the refusal in `build_command.zig` stays. G5 moves the value.

**Shape.** The entry root stays node 0, and each dependency root becomes a `function` node after the entry root children. Ids stay breadth first, so `residualPlan` in `proof_certificate.zig` needs no new sort. Result ordinals, witness nodes, witness scopes, and function ordinals move with the nodes, and every digest is computed again. `capability_call` keeps its catalog row. `pre_optimization_len` and `final_len` hold the sum over the modules, and only `proof_ir.zig` reads them. `Node` gained `leaf_kind`, `ProofIr` gained `result_binding_count`, and `Evidence` gained `scope_count`. None of the three is on the wire.

**Refusal added in review.** The kernel derives Result events only under a `proved` edge. When the producer's own pass does not accept the events, the certificate states `tested`, and that edge meets the production floor with no kernel check. That state is the exposure that the plan makes G4 refuse past the Result limit, so `build` in `proof_certificate.zig` now fails with `error.GraphResultsNotProved` when a graph holds Result events that are not proved.

No real source reached that state. With verification on, I probed 11 guard shapes in a dependency: a ternary, `&&`, `||`, `=== true`, `match`, a copied flag, a guard in a loop, an error read, an unguarded top-level read, a guarded top-level read, and a copied flag at top level. Each one was refused by a check or proved. The refusal is a defensive rule, and its test uses a compile with verification off. That test failed before the fix, because the certificate built.

**Correction.** The Sonnet hand-back said that a top-level guard in a dependency loses its proof, because the walk stops at a `function`. That holds only for an early-exit guard, and top-level code has no `return`. A read inside the guarded `if` arm is still proved.

**Test 4.** With verification on, the verifier refuses an unguarded dependency read at compile. The kernel test therefore compiles with verification off and sets `results_proved` to model a producer that claims the proof. The kernel rejects it at `evidence_check` with `result_read_unguarded`.

**Counts** for the three multi-module handlers, at the fold. Each folds to 4 `function` nodes, is total, and passes production acceptance. Each holds 0 Result bindings and 0 capability calls, so none of them exercises the Result limit. `sibling-helper` used the policy `env.allow=[APP_NAME,API_TOKEN]` and `env.public=[APP_NAME]`. `sibling-helper-holes` used the same policy and a scratch copy with `cost_bounded` removed from its capsule. Both come from `packages/tools/tests/fixtures/flow_precision/corpus`.

| Handler | Nodes | Emissions | Jumps | Rewrites | Scopes | Certificate bytes |
|---|---|---|---|---|---|---|
| `handler-with-imports.ts` | 18 | 6 | 0 | 5 | 5 | 2527 |
| `sibling-helper` | 20 | 9 | 1 | 7 | 5 | 2891 |
| `sibling-helper-holes` | 18 | 9 | 1 | 7 | 5 | 2779 |

**For G7.** The test "a single-module certificate keeps its pinned bytes" pins one SHA-256 that I confirmed at `23ec4980` before any edit. The executable root folds the semantics and grammar hashes, so an unrelated later change moves it. G7 removes the test after the final gate. `function_ordinal` is not on the wire, so no consumer checks its offset. A test compares it with the span counts of the artifact.

Sonnet implemented the unit, slightly past its turn budget of 60. I reviewed the diff and added the refusal.

Results at the G4 tree, each from an unfiltered run: `zig build test` 214 of 214 steps, `test-zruntime` 274 of 275 tests with 1 skipped, and `test-cli`, `test-bytecode-identity`, `smoke-v1`, `test-module-boundary`, `test-expert-app`, `test-proof-swallow`, `test-proof-checker`, `test-proof-ratchet`, `test-proof-ratchet-drift`, `test-zts-layering`, `zig fmt --check`, and `zig build` each exit 0.

Against the G3 tables, `zts check` and `zts compile` each moved 0 of 215 rows. The command surface moved 0 of 38 rows against G0. `git diff` on `packages/proof-checker` is empty.

## G5

A handler with file imports now builds and serves. `compileMultiModule` returns the folded evidence in `proof_evidence`, and the refusal is gone. `zttp compile`, `zttp build`, and `zttp deploy` each exit 0 on `examples/handler/handler-with-imports.ts`, signed and with `--no-attest`. Each of the 6 binaries serves `{"message":"Hello, world!"}` and prints "Proof accepted: weakest edge trusted, 3 disclosed edge(s)".

`zttp proofs bundle` and then `zttp proofs verify <dir> --require-proof` exit 0 for the signed and the unsigned deploy. The output says `policy_accepted`, and "Checked: response_total, results_checked".

**Tamper measurement** on real binaries, with the method from the legacy removal worklog. No edited binary served a request. Each edited case exited 1 at boot.

| Case | Exit | Stopped by |
|---|---|---|
| Control, signed | Serves | Not applicable |
| Control, unsigned | Serves | Not applicable |
| Dependency edit, signed | 1 | Attestation: `ExecutableGraphMismatch` |
| Dependency edit, attestation removed | 1 | Proof acceptance: `artifact_binding`, `graph_member_digest_mismatch` |
| Dependency edit, unsigned | 1 | Proof acceptance: `artifact_binding`, `graph_member_digest_mismatch` |
| Dependency section grafted onto a single-module binary, signed | 1 | Attestation: `ExecutableGraphMismatch` |
| Graft, attestation removed | 1 | Proof acceptance: `artifact_binding`, `graph_member_extra` |
| Graft onto an unsigned single-module binary | 1 | Proof acceptance: `artifact_binding`, `graph_member_extra` |

These replace the unsigned edit rows of the legacy removal worklog. Those rows stopped at `missing_required_section` only because no certificate existed, so they showed little. The certificate now binds the dependency bytes.

**Named refusals through `zttp compile --no-attest`.** `GraphResultLimit` (33 Results in the entry and 33 in the dependency) and `ModuleNotClassified` (65 in the dependency) each exit 1, write no binary, and name the cause. A real source did not reach `GraphResultsNotProved`, as G4 records.

**Default profile on the merged contract.** This closes the item from G3. A handler with no capsule that imports a dependency and never calls it passed the entry-only check. A single file with an uncalled function that mutates module state fails `state_isolated`, and the same function in a dependency compiled. `runBuild` now gates each spec error of the merged contract, for a handler with file imports only. A new step in `smoke-v1` exited 0 from the compile before the fix and passes after it.

The gate is stricter than a single file in one case. A single file with an uncalled function that calls `uuid()` compiles. The same function in a dependency now fails with `ZTS500 cost_bounded, pure`, because a dependency contract counts every function in the module. Decision 5 accepts a build that is stricter than `zttp check`. A capsule that does not demand those properties still compiles.

**Residual guard in a dependency.** The guard holds at run time. A dependency calls `env(name)` with a computed name, and the policy allows one key. With both keys in the process environment, the allowed key reads `present`. The other key gives HTTP 500. With both keys in the policy, the second key reads `present` too, so the 500 comes from the policy. `smoke-v1` now holds this flow. Returning the value itself fails the build with ZTS400 across the dependency, so flow tracking also crosses the module boundary.

Sonnet implemented items 1 to 4 and took about 55 calls against a turn budget of 30. It left the default-profile gate and the guard smoke step open. I measured the single-file analogue, and I wrote both, with the failing step first.

Results at the G5 tree, each from an unfiltered run: `zig build test` 214 of 214 steps, `test-zruntime` 274 of 275 tests with 1 skipped, and `test-cli`, `test-precompile`, `test-bytecode-identity`, `smoke-v1`, `smoke-getting-started`, `test-module-boundary`, `test-expert-app`, `test-proof-swallow`, `test-proof-checker`, `test-proof-ratchet`, `test-proof-ratchet-drift`, `zig fmt --check`, and `zig build` each exit 0.

Against the G4 tables, `zts check` and `zts compile` each moved 0 of 215 rows. The command surface moved 0 of 38 rows against G0. `git diff` on `packages/proof-checker` is empty.

## G6

The documentation now states the target, the limits, and the refusals. `docs/decisions.md` holds D-018, which supersedes the P7 line on merged contracts. `docs/verification.md` holds the section "Handlers with file imports". `docs/cli.md`, `docs/user-guide.md`, `docs/roadmap.md`, `docs/plans/README.md`, the P7 specification notice, and `packages/runtime/AGENTS.md` follow it.

The website states the change under "Awaiting the next release" in `static/index.html`, with the coverage limit. The site version stays 0.26.0, and nothing was deployed or pushed.

Sonnet found two more false statements in `docs/roadmap.md`: `zttp serve` no longer lets the last module win, and the Result-limit exposure now applies to a single-module handler only. In review I corrected D-018, which said that no certificate property reads an exported signature. G2b reads those signatures for their types, so the correct statement is that no property depends on rule ZTS061.

## G7

The final gate passed at `801d1492`, from empty local and global caches, with no provider key. Every step below is an unfiltered run with its exit status read directly.

| Step | Exit | Result |
|---|---|---|
| `zig build test` | 0 | 214 of 214 steps, 8795 of 8801 tests, 6 skipped |
| `scripts/verify.sh` | 0 | Ran in separate sequential processes |
| `smoke-v1` | 0 | 2 of 2 steps |
| `test-proof-checker` | 0 | 3 of 3 steps |
| `test-proof-checker-mutants` | 0 | 3 of 3 steps |
| `test-proof-ratchet` | 0 | 5 of 5 steps |
| `test-proof-ratchet-drift` | 0 | 2 of 2 steps |
| `test-bytecode-identity` | 0 | 5 of 5 steps |
| `zig fmt --check packages scripts` | 0 | |
| `zig build` | 0 | |
| `bench-check -Doptimize=ReleaseFast` | 0 | 9 benchmarks, geomean 1.00402, regression 0.00%, load 2.81 before and 2.41 after |

`git diff` from the base commit to the final commit on `packages/proof-checker` is empty.

Against the G0 tables, `zts check` moved 1 of 215 rows and `zts compile` moved 1 of 215 rows. Each moved row traces to a unit. `tests/corpus/check/bad/module_scope_mutation.ts` is the G1b text change. `examples/handler/handler-with-imports.ts` is the G2a warning and the G3 contract.

**Single-module artifacts.** The pinned test from G4 dated only from G3, so I measured back to the base. I built each single-module handler in `examples/` with the G0 binaries at `8d62cb07` and with the final binaries, with `--no-attest`. 25 handlers built on both. Sections 1, 3, 4, and 7 (bytecode, contract, policy, and certificate) have identical SHA-256 digests in all 25. No handler changed its exit status. The other handlers under `examples/` exit nonzero on both.

That result replaces the pinned test, which I removed as G4 planned. The test pinned one digest that an unrelated change to the semantics or grammar hash would move.

**Limits.** These runs used Debug binaries on macOS, except `bench-check`, which used ReleaseFast. No provider call, corpus re-record, push, or deploy ran. `test-expert-app` ran offline inside `zig build test`. Unit G8 stays open, and `zttp build` stays stricter than `zttp check` until a re-record window.

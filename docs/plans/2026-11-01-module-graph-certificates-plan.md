# Module graph certificates plan, 2026-11-01

## Authority and status

This document is the plan for proof certificates over a handler with file imports.
It owns the findings, the target, the owner decisions, the units, and the verification.
The worklog `docs/plans/2026-11-01-module-graph-certificates-worklog.md` records execution. Unit G0 creates that worklog.

Status: approved on 2026-11-01. The owner selected option (a) for Decisions 1 to 6, which authorizes units G0 to G7.
Revision 2 folds in the two validations that Decision 6 selected: a Fable review of the argument, and a Codex fact-check of the repository claims.
No push, tag push, provider call, or corpus re-record is authorized by this plan.
This plan edits no file in `packages/proof-checker`.

## Problem

`zttp compile`, `zttp build`, and `zttp deploy` refuse a handler with file imports. `zttp serve` runs the same handler.
`packages/tools/src/precompile.zig#compileMultiModule` captures no proof evidence, so the build has no certificate.
Production acceptance requires a certificate that establishes `response_total`, `results_checked`, and `no_secret_leakage`.

That refusal also hides a wider gap. The multi-module path skips most checks that a single-module build enforces.
A certificate alone would remove the refusal and leave those checks skipped, so this plan closes both.

## Measured on 2026-11-01

All probes ran at `8d62cb07` on Debug binaries, on macOS, in a scratch directory. Scratch patches stayed out of `main`. Each probe source is a few lines, and Unit G0 copies them into the worklog.

| Probe | Result |
|---|---|
| Entry-only certificate, with `properties` forced true, no kernel edit | `zttp compile` exit 0. Boot accepted it. The binary served HTTP 200 |
| Dependency edit on that certified binary, 3 cases | Each exited 1 at boot: `graph_member_digest_mismatch` twice, attestation root mismatch once |
| Two dependencies with one private name `label`, through `zttp serve` | The body is `bb`. Lexical scope gives `ab` |
| Entry and dependency with one private name `helper`, through `zttp serve` | The body is `entry:entry`. Lexical scope gives `dep:entry` |
| `publicValue()` calls a private `value()` that another dependency also defines | `zttp serve` returned the secret. `zttp check` reported ZTS400 |
| Dependency reads `env("SECRET_KEY")` at top level | `zttp serve` returned the secret. `zttp check` reported ZTS400 |
| `zts compile --verify --contract` on `examples/handler/utils.ts` and both corpus seeds `lib/settings.ts` | Each is refused, and ZTS061 is the only code |
| Dependency binds `const Response` at top level | `zttp check` reported 0 errors. Every request failed with `NotCallable` |
| Entry returns a dependency `string` where the signature says `Response` | `zttp check` exit 0. `zttp serve` returned HTTP 200 with that string |
| A top-level `assert` in a dependency fails | `zttp check` exit 0. Boot passed. Every request failed with `NotCallable` |
| One file: `let count`, a helper that increments it, a handler that calls the helper | `zttp check` printed `state_isolated` PROVEN. A binary from `zttp compile` served 2, 3, 4, 5 on four requests |

Three results set the design. First, the kernel accepts a certificate that omits a dependency, so a certificate does not establish coverage by itself. Second, modules share one flat namespace at run time, so a check that reads a module by lexical scope can read the wrong function. Third, `state_isolated` is false for a single-file handler today, so per-module verifier results need a stronger rule before they compose.

## Findings from reading the code

Each statement below comes from reading the code. The worklog must record any statement that a unit disproves.

**Kernel.** `packages/proof-checker` reads no bytecode. It binds the certificate through member digests. The executable graph knows `dep_bytecode` as a member kind, but no IR record names its source module. The certificate holds one IR tree with one root.

`foldTotality` in `packages/proof-checker/src/checker.zig` folds every node, and the evidence check reads the result for the handler. The IR has `capability_call` but no general call tag. So `response_total` is a structural result: every path of the handler reaches a return statement. The callee does not affect it, and neither does the type of the returned value. `proof_system.zig` documents the property as "returns a Response", and that part rests on producer checks.

`results_checked` and guard coverage walk every IR node. Both therefore cover a dependency if its nodes are in the IR. A dependency whose nodes are absent gets no coverage, and no check refuses that absence.

A single-module certificate has the same exposure. The kernel cannot detect a function that the producer left out, because it reads no bytecode. Dependency omission is therefore not a new class of trust. This equivalence depends on Units G1 and G2a, because the strict undeclared-global rule must run on dependencies.

**Properties.** The kernel rechecks `response_total` and `results_checked` only. It takes the others from the producer. `packages/runtime/src/build_command.zig#dischargedProperties` reads them from the contract, and the merged contract holds `properties == null`. It sets `capability_bounded` from the budget length alone, so a budget that survives a merge makes that claim.

**Checks.** `compileMultiModule` receives no `strict`, `emit_verify`, or `emit_proof_evidence` option. The table lists the compile step only. Both paths later run CHECK on the entry and refuse its spec errors.

| Check | `compileHandler`, single module | `compileMultiModule` |
|---|---|---|
| Parse, admission, runtime owners | Enforced | Enforced on each module |
| SQL contract, capability policy | Enforced | Enforced on each module |
| Virtual import validation | Enforced | Entry only |
| Boolean checker | Enforced | Skipped |
| Type check | Enforced | Runs with omitted source types, and its error count is discarded |
| Strict checker, ZTS6xx, ZTS602 | Enforced | Skipped |
| Handler verifier | Enforced | Skipped |
| Flow | Runs, and later spec checks gate its result | Skipped |
| Bytecode verifier | Enforced at compile | Skipped at compile, enforced when a binary loads, skipped in source-mode serve |
| Capsules, capability budget, ZTS514 | Enforced | Run with omitted source types, so declared capsules are hidden, and `mergeModuleContract` drops the diagnostics |

**Contract.** `packages/zts/src/handler_contract.zig#mergeModuleContract` drops `properties`, `declared_specs`, `spec_diagnostics`, `capability_budget`, `intent`, `property_provenance`, `extensions`, `rate_limiting`, and `egress.urls`. It also leaves `effect_analysis_complete` at its default of true, which is the optimistic value.

**Imports.** No file-import typing exists. An imported binding has no type in the importer, so the type checker skips a return of that value, and the verifier cannot see an unnarrowed value that crosses a file.

**Linkage.** Top-level value bindings of every module are globals. They share an object with `Response` and the other built-ins, and the last module loaded wins. Code generation does not hoist a function declaration, and a failed top-level `assert` ends module initialization, so later exports stay undefined.

**Verifier.** The `.call` arm of the verifier walks the callee and arguments, not the callee body. Only request roots and nested functions reach the mutation checks. That is why the single-file probe reads `state_isolated` PROVEN.

**Flow.** Flow in `zttp check` evaluates dependency bodies through `analyzePersistentHandler` in `packages/zts/src/flow_interp.zig`. Contract extraction separately receives imported effect rows. FlowInterp models the flat namespace, which is why it reported ZTS400 in the probes.

When the module graph is incomplete, the flow pass clears all six flow properties. A data export is one cause, because the loader accepts only `export function` and `export const` with a direct function or arrow initializer. That rule fails closed.

`state_isolated`, `result_safe`, and `optional_safe` stay entry-only in `zttp check`. The contract in `zttp check` does not merge the inventories of each dependency.

Before W4 of the check parity plan, `zttp check` loaded one view for each import record, so a shared module initialized twice. The runtime initializes it once, and `packages/tools/src/precompile_imports.zig#flowModulesForGraph` now loads each module once in `zttp check` too. The build input removes that difference, so a verdict can differ only where `zttp check` refuses and the build proves. That direction is safe.

**Model-visible surface.** `packages/pi` calls `runCheckOnlyWithOptions` and `runCheckOnlyFromSourceWithOptions`, and never calls `compileHandler`. Compile-path work therefore moves no model text, with one route to avoid. `packages/pi/src/aggregate_proof.zig` calls `discoverModulePaths`, which runs `ModuleGraph.build`, and an error there reaches `proof_roots_failed` output. Unit G1 stays out of `build`.

`zttp check` output is frozen by D-012, and 2 of the 13 replay cases use file imports. The verifier is shared by CHECK, so Unit G1b is the one unit that can move a CHECK verdict. Its acceptance requires the replay to stay at 13 of 13.

## Target

After this plan, a sealed build of a handler with file imports passes the checks that a single-module build passes, and it carries one certificate.

| Property | Established by | Covers | Limit |
|---|---|---|---|
| `response_total` | Kernel | Every path of the handler reaches a return | Structural. A module load failure and a trap in a callee stay outside it |
| Return type | Producer, type check | The handler's returned value | Unit G2b |
| `results_checked` | Kernel | Every module in the folded IR | Unit G4 refuses a graph that it cannot classify |
| Guard coverage | Kernel | Every capability call in the folded IR | Node and work limits below |
| `no_secret_leakage` | Producer, flow pass | The module graph, in load order | Fails closed on an incomplete graph |
| `state_isolated`, `result_safe` | Producer, verifier | Each top-level function of each module | Parameter aliasing across modules is not modeled, the same as today |
| `capability_bounded` | Producer | A claim only when no module has a budget error | Unit G3 |
| Dependency bytes | Kernel | Each module, through `dep_bytecode` members | Digest only |

The certificate does not establish that the IR covers every module. Under Decision 2 (a), that coverage is the producer's word. `docs/verification.md` must say so.

The kernel limits stay unchanged. The node and work limits fail closed: these are estimates from reading `limits.zig`, about 18,724 IR nodes at the 1 MiB section limit, and a jump scan that can reach the 8,000,000 work limit. The Result limit does not fail closed by itself. Past 64 bindings the lowering clears `results_classified` and emits no Result events. The certificate then states a `tested` edge, which meets the production floor. Unit G4 refuses a multi-module graph in that state. A single-module handler keeps that exposure, and the roadmap records it.

## Owner decisions

The owner selected option (a) for each decision on 2026-11-01.

**Decision 1: module linkage.** Selected: (a) refuse a graph in which a top-level binding is ambiguous, with no change to codegen. Rejected: (b) a private scope per module, which moves `zttp check` verdicts and needs a re-record window. The Fable review widened (a) to cover built-in names, and it stays one refusal.

**Decision 2: kernel coverage.** Selected: (a) fold every module into one IR, with no kernel edit. Rejected: (b) a module table, which needs schema 6 and moves every certificate byte. The Fable review found that the fold cannot contribute totality or leak a guard, because the kernel stops at each function node.

**Decision 3: checks on a dependency.** Selected: (a) enforce every check except ZTS061, and record the exemption. ZTS061 refuses a raw built-in type in an exported signature. No checker reads a dependency's exported signature today, so no certificate property depends on it. Unit G2b reads those signatures for their types and does not depend on the rule. Rejected: (b) enforce it too, which changes the frozen corpus seeds.

**Decision 4: flow claims on a merged contract.** Selected: (a) supersede the P7 line that merged contracts omit flow claims. A build runs FlowInterp over the modules of `ModuleGraph`, each one once, in load order. FlowInterp stays unchanged. This satisfies D-011, because it stays one producer.

**Decision 5: `zttp check` parity.** Selected: (a) leave `zttp check` unchanged except for Unit G1b, and close the gap in Unit G8. Until then the build is the stricter gate.

**Decision 6: validation.** Selected: (a). Both validations ran, and revision 2 holds the results.

## Units

Each executor stops at its turn budget and hands back its changed files, check results, and open issues. Each bug fix starts with a failing test. Opus reviews each diff and runs each check again. Each exit status comes from an unfiltered step, read directly and not through a pipe.

Every unit keeps these invariants unless it names an exception: `zts check` moves 0 of 215 digest rows, `git diff` on `packages/proof-checker` stays empty, and the replay stays at 13 of 13 cases.

The refusal for a handler with file imports stays in place until Unit G5. No earlier unit may wire evidence into `CompiledHandler`.

### G0: worklog and baseline

- Model: Opus. Turn budget: 10.
- Files: the worklog, `docs/plans/README.md`, `docs/roadmap.md`.
- Work: record the base commit, the `zig build test` count, the digest tables, the probe sources, and the free disk space. Add the `state_isolated` defect and the Result limit to the roadmap.
- Acceptance: `zig build test` exits 0 from an empty cache, and the worklog holds the base values.

### G1: refuse an ambiguous top-level binding

- Model: Sonnet. Turn budget: 30. It can ship alone.
- Files: `packages/zts/src/modules/internal/module_graph.zig`, `packages/zts/src/pipeline.zig`, `packages/tools/src/precompile.zig`, `packages/runtime/src/handler_instance.zig`, `scripts/smoke-v1.sh`.
- Work: add a `ModuleGraph` method apart from `build`. Call it from `compileMultiModule`, from `extractMultiModuleContractWithEntry`, and from the runtime source load path. `discoverModulePaths` and `zttp check` do not call it. The method refuses each of these:
  - Two modules bind one top-level value name. An import local binding counts, unless it names the identical export. Type names do not count.
  - Any module binds a name in `packages/zts/src/known_globals.zig` or a built-in namespace object such as `Response`, `JSON`, or `Math`.
  - A dependency binds `handler`.
  - A named import has no matching export in its target module.
- Acceptance: the first failing test uses the `label` probe. Each refusal names the identifier and the files, and exits 1, in `zttp compile` and `zttp serve`. `smoke-v1`, `test-zts`, and `test-zruntime` exit 0. `test-bytecode-identity` does not move.

### G1b: walk helpers for `state_isolated`

- Model: Sonnet. Turn budget: 30. It can ship alone.
- Files: `packages/zts/src/handler_verifier.zig`, its tests, `docs/verification.md`.
- Work: every top-level function of a module is a request root for the two state checks, Checks 6 and 7. A same-file helper that mutates module state therefore clears `state_isolated`. The handler verifier keeps its response checks on the handler.
- Acceptance: the first failing test uses the `count` probe and asserts `state_isolated` false. A binary still compiles only when its capsule does not demand the property. The replay stays at 13 of 13. Any moved `zts check` digest row traces to this rule, which is the named exception to the invariant.
- Stop condition: if a corpus case moves, the unit stops and reports, because D-012 then applies.

### G2a: run every check on every module

- Model: Sonnet. Turn budget: 50. It depends on Unit G1b.
- Files: `packages/tools/src/precompile.zig`, `packages/zts/src/pipeline.zig`, `packages/zts/src/handler_verifier.zig`, `packages/zts/src/strict_checker.zig`.
- Work: pass the options into `compileMultiModule`. Run the boolean checker, the type check, the strict checker, the verifier, virtual import validation, and the bytecode verifier on each module. Code generation stays first, on the kept parsers, so no bytecode moves. Type-directed opcode specialization stays out of scope. The ZTS061 exemption goes by the diagnostic kind `raw_exported_boundary_type`, so ZTS609 stays enforced. A top-level `assert` in a dependency is refused, because its failure leaves later exports undefined.
- Acceptance: one test per check shows a dependency defect that exits 1 with its exact diagnostic. A dependency that fails only ZTS061 still compiles. `test-bytecode-identity` does not move.
- Stop condition: `HandlerVerifier` starts from a handler. If it cannot check a module with no handler, the unit stops and reports the gap.

### G2b: type file-import bindings

- Model: Sonnet. Turn budget: 50. It depends on Unit G2a.
- Files: `packages/zts/src/type_checker.zig`, `packages/zts/src/type_env.zig`, `packages/zts/src/pipeline.zig`, `packages/zts/src/handler_verifier.zig`.
- Work: on the compile path, type a file-import binding from the exported signature of its dependency. A structural alias resolves to its base type, so Decision 3 (a) holds.
- Fallback: if signatures cannot cross type stores without a redesign, use two narrower rules. Refuse a request-root `return` of a file-import call unless the declared return type of the export is `Response`. Clear `optional_safe` on a handler that reads a file-import value.
- Acceptance: the first failing test uses the `greet` probe, and the compile path refuses it with the exact diagnostic. A dependency helper that declares `Response` compiles. `zttp check` output does not move.

### G3: build the merged contract on the entry contract

- Model: Sonnet. Turn budget: 50. It depends on Decision 4 (a) and on Unit G2b.
- Files: `packages/tools/src/precompile_contract.zig`, `packages/tools/src/precompile.zig`, `packages/zts/src/handler_contract.zig`, `packages/zts/src/pipeline.zig`, `packages/tools/src/deploy_manifest.zig`.
- Work: start from a full entry contract with authored source types. Pass the deduplicated `ModuleGraph` modules to `prepareChecked` as flow modules, with the entry as module 0 and imports built against the deduplicated indices. Union the dependency facts, including `egress.urls` and `spec_diagnostics`. Refuse the build when `specErrors()` is above 0. AND the verifier properties and `effect_analysis_complete` across modules. Keep the entry capsule, budget, and intent. Run spec discharge again after flow, as the single-module path does. Refuse an `api.schemas` conflict in place of last-wins.
- Acceptance: a clean graph holds `no_secret_leakage` true, a dependency secret in the response holds it false, and an incomplete graph holds it false with `module_graph_gap`. A dependency call outside the entry `Effects` ceiling exits 1. A diamond graph test asserts one initialization. The tests that pin `properties == null` change to these literal values. `flow_analyzer_version` does not move.

### G4: fold the proof evidence

- Model: Sonnet. Turn budget: 60. It depends on Unit G3.
- Files: `packages/zts/src/modules/internal/compiler.zig`, `packages/zts/src/proof_ir.zig`, `packages/zts/src/root.zig`, `packages/runtime/src/build_command.zig` for tests only.
- Work: `CompileResult` owns one translation recorder per module. A new fold in `proof_ir.zig` keeps the entry IR as the root and adds each dependency root as a function node. It renumbers node ids, Result ordinals, witnesses, and residual ids, and it sorts the residual plan again by `operation_id`. It runs only when dependencies exist. It returns an error when any module is not classified. `compileMultiModule` does not return this evidence yet.
- Acceptance: tests build a certificate from a fold and run production acceptance on it. Single-module certificates stay byte-identical. Two folds of one graph give identical bytes. A dependency with an unguarded Result read is refused at `results_checked`. A dependency capability call with a non-literal resource appears in the residual plan. A graph past the Result limit gives a named refusal. The worklog records real node, witness, jump, and Result counts for the three multi-module handlers.
- Stop condition: if the kernel refuses a fold at `translation_check`, the unit stops. Decision 2 then reopens, and no kernel limit changes.

### G5: wire the evidence and remove the refusal

- Model: Sonnet. Turn budget: 30. It depends on Unit G4.
- Files: `packages/tools/src/precompile.zig`, `packages/runtime/src/build_command.zig`, `packages/runtime/src/proof_ratchet.zig`, `scripts/smoke-v1.sh`.
- Work: in one commit, return the folded evidence from `compileMultiModule`, remove the refusal that names the missing certificate, and change the `smoke-v1` step to compile, run, and assert the exact response body. Add a multi-module row to `test-proof-ratchet`.
- Acceptance: `zttp compile`, `zttp build`, and `zttp deploy` exit 0 on `examples/handler/handler-with-imports.ts`, and the binary serves `{"message":"Hello, world!"}`. The dependency edit and graft cases from the Decision 14 measurement each exit 1 at boot, and the worklog records them.

### G6: documentation

- Model: Sonnet. Turn budget: 20.
- Files: `docs/decisions.md`, `docs/verification.md`, `docs/cli.md`, `docs/user-guide.md`, `docs/roadmap.md`, `docs/plans/README.md`, `docs/plans/2026-10-20-flow-interp-p7-spec.md`, `packages/runtime/AGENTS.md`, `../ZTTP-WEBSITE`.
- Work: add one decision that records the supersession from Decision 4, and add a notice to the P7 line. State the target table in `docs/verification.md`, including the coverage limit, the callee trap limit, and the initialization order limit. Update the website in a local commit, with no deploy or push.
- Acceptance: `test-doc-links`, `test-docs-drift`, `check-spine`, and `test-spine` exit 0. `deno task verify` exits 0 in the website.

### G7: final gate

- Model: Opus. Turn budget: 15.
- Work: from empty caches and with no provider key, run `zig build test`, `scripts/verify.sh`, `smoke-v1`, `test-proof-checker`, `test-proof-checker-mutants`, `test-proof-ratchet`, and `bench-check -Doptimize=ReleaseFast` on a quiet host. Compare the digests with the G0 baseline.
- Acceptance: each step exits 0. `git diff <base> -- packages/proof-checker` is empty. Every moved digest row traces to a unit.

### G8: `zttp check` parity, deferred

The [check parity plan](2026-11-01-check-parity-plan.md) carries out this unit, with one change: `discoverModulePaths` does not call `checkBindings`, because its only caller stops on the ZTS063 first.

- Model: Opus plans, Sonnet implements. It runs only inside a re-record window that the owner opens.
- Work: run the per-module checks, typed imports, and the binding refusal in `zttp check` and in `discoverModulePaths`.
- Acceptance: a handler that passes `zttp check` passes `zttp build`. This plan closes without this unit, and the roadmap keeps it open.

## Moved by this plan

- Tests: the tests that pin the gap in `precompile.zig`, and the refusal test in `build_command.zig`.
- Output: the contract of a multi-module `zts compile`, and `state_isolated` for a handler whose helper mutates module state. The certificate of a single-module build stays byte-identical unless Unit G1b changes its properties.
- Behavior: `zttp serve` refuses an ambiguous binding under Decision 1 (a). This is a deliberate change, because today it gives a wrong answer with no error.

## Risks

- **A verifier gap.** The handler verifier may need a mode for a module with no handler. Unit G2a finds this first and stops there.
- **Limits.** The Result limit can refuse a real multi-module handler. That refusal is safe, and raising the limit needs a kernel edit and an owner decision.
- **Top-level code.** A dependency runs top-level code at load, once per pooled runtime, with no request deadline. The entry module has the same behavior. This plan does not change it.
- **Traps.** A callee can still trap at run time, so a request can end in a 500. `response_total` never covered that case. `docs/verification.md` must say so.
- **Divergence from `zttp check`.** Until Unit G8, the build refuses some handlers that `zttp check` passes. Decision 5 accepts this.

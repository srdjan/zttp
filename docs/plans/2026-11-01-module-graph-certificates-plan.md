# Module graph certificates plan, 2026-11-01

## Authority and status

This document is the plan for proof certificates over a handler with file imports.
It owns the findings, the target, the owner decisions, the units, and the verification.
The worklog `docs/plans/2026-11-01-module-graph-certificates-worklog.md` will record execution. Unit G0 creates that worklog.

Status: draft, not approved. The owner authorized this plan on 2026-11-01 and authorized no code.
No push, tag push, provider call, or corpus re-record is authorized by this plan.
Under Decision 2 (a), this plan edits no file in `packages/proof-checker`.

## Problem

`zttp compile`, `zttp build`, and `zttp deploy` refuse a handler with file imports. `zttp serve` runs the same handler.
`packages/tools/src/precompile.zig#compileMultiModule` captures no proof evidence, so the build has no certificate.
Production acceptance requires a certificate that establishes `response_total`, `results_checked`, and `no_secret_leakage`.

That refusal also hides a wider gap. The multi-module path skips most checks that a single-module build enforces.
A certificate alone would remove the refusal and leave those checks skipped, so this plan closes both.

## Measured on 2026-11-01

All probes ran at `8d62cb07` on Debug binaries, on macOS, in a scratch directory. Scratch patches stayed out of `main`.

| Probe | Result |
|---|---|
| Entry-only certificate, with `properties` forced true, no kernel edit | `zttp compile` exit 0. Boot accepted it. The binary served HTTP 200 |
| Dependency edit on that certified binary, 3 cases | Each exited 1 at boot: `graph_member_digest_mismatch` twice, attestation root mismatch once |
| Two dependencies with one private name `label`, through `zttp serve` | The body is `bb`. Lexical scope gives `ab` |
| Entry and dependency with one private name `helper`, through `zttp serve` | The body is `entry:entry`. Lexical scope gives `dep:entry` |
| `publicValue()` calls a private `value()` that another dependency also defines | `zttp serve` returned the secret. `zttp check` reported ZTS400 |
| Dependency reads `env("SECRET_KEY")` at top level | `zttp serve` returned the secret. `zttp check` reported ZTS400 |
| `zts compile --verify --contract` on `examples/handler/utils.ts` and both corpus seeds `lib/settings.ts` | Each is refused, and ZTS061 is the only code |

Two results set the design. First, the kernel accepts a certificate that omits a dependency, so a certificate does not establish coverage by itself. Second, modules share one flat namespace at run time, so a check that reads a module by lexical scope can read the wrong function.

## Findings from reading the code

Each statement below comes from reading the code. The worklog must record any statement that a unit disproves.

**Kernel.** `packages/proof-checker` reads no bytecode. It binds the certificate through member digests, and it has no concept of a module. The certificate holds one IR tree with one root. No record names a module.

`foldTotality` in `packages/proof-checker/src/checker.zig` reads `total[entry]`, and the IR has no call tag. So `response_total` means that every path of the entry reaches a return statement. That meaning does not depend on the callee.

`results_checked` and guard coverage walk every IR node. Both therefore cover a dependency if its nodes are in the IR. A dependency whose nodes are absent gets no coverage, and no check refuses that absence.

A single-module certificate has the same exposure. The kernel cannot detect a function that the producer left out, because it reads no bytecode. Dependency omission is therefore not a new class of trust.

**Properties.** The kernel rechecks `response_total` and `results_checked` only. It takes the others from the producer. `packages/runtime/src/build_command.zig#dischargedProperties` reads them from the contract, and the merged contract holds `properties == null`.

**Checks.** `compileMultiModule` receives no `strict`, `emit_verify`, or `emit_proof_evidence` option. The table lists what it does today.

| Check | Single-module build | Multi-module build |
|---|---|---|
| Parse, admission, runtime owners | Enforced | Enforced on each module |
| SQL contract, capability policy | Enforced | Enforced on each module |
| Virtual import validation | Enforced | Entry only |
| Boolean checker | Enforced | Skipped |
| Type check | Enforced | Runs, and its error count is discarded |
| Strict checker, ZTS6xx, ZTS602 | Enforced | Skipped |
| Handler verifier | Enforced | Skipped |
| Flow | Enforced | Skipped |
| Bytecode verifier | Enforced at compile | Skipped at compile, enforced at load |
| Capsules, capability budget, ZTS514 | Enforced | Run on each module, and `mergeModuleContract` drops the result |

**Contract.** `packages/zts/src/handler_contract.zig#mergeModuleContract` drops `properties`, `declared_specs`, `spec_diagnostics`, `capability_budget`, `intent`, `property_provenance`, `extensions`, `rate_limiting`, and `egress.urls`. It also leaves `effect_analysis_complete` at its default of true, which is the optimistic value.

**Flow.** `zttp check` does not use summaries across modules. `analyzePersistentHandler` in `packages/zts/src/flow_interp.zig` evaluates the dependency bodies. It models the flat namespace, which is why it reported ZTS400 in the probes.

When the module graph is incomplete, the flow pass clears all six flow properties. A data export is one cause, because only `export function` and `export const x = fn` are complete. That rule fails closed.

`state_isolated`, `result_safe`, and `optional_safe` stay entry-only in `zttp check`. The contract in `zttp check` also omits the facts of each dependency.

`packages/tools/src/precompile_imports.zig#loadFlowModulesForCheck` loads one view for each import record, so a shared module initializes twice. The runtime initializes it once. This may produce a false proof, and it needs a probe.

**Model-visible surface.** `packages/pi` calls `runCheckOnly` and never calls `compileHandler`. Compile-path work therefore moves no model text. `zttp check` output is frozen by D-012, and 2 of the 13 replay cases use file imports.

## Target

After this plan, a sealed build of a handler with file imports passes the checks that a single-module build passes, and it carries one certificate.

| Property | Established by | Covers | Limit |
|---|---|---|---|
| `response_total` | Kernel | Every path of the entry | Same meaning as a single-module build |
| `results_checked` | Kernel | Every module in the folded IR | Graph-wide limit of 64 Result bindings |
| Guard coverage | Kernel | Every capability call in the folded IR | Node and work limits below |
| `no_secret_leakage` | Producer, flow pass | The module graph, in load order | Fails closed on an incomplete graph |
| `state_isolated`, `result_safe`, `optional_safe` | Producer, verifier | Each module | Depends on the Unit G2 result |
| Dependency bytes | Kernel | Each module, through `dep_bytecode` members | Digest only |

The certificate does not establish that the IR covers every module. Under Decision 2 (a), that coverage is the producer's word. `docs/verification.md` must say so.

The kernel limits stay unchanged, so a large graph fails closed. These are the estimates from reading `limits.zig`: 64 Result bindings, about 18,724 IR nodes at the 1 MiB section limit, and a jump scan that can reach the 8,000,000 work limit. Unit G4 measures real handlers.

## Owner decisions

**Decision 1: module linkage.** The flat namespace gives wrong answers today.
- (a) Recommended: `ModuleGraph` refuses a graph in which two modules bind one top-level value name. This covers compile, build, deploy, and serve. It is a graph error like `CircularImport`, so it adds no advertised rule and does not move the policy hash.
- (b) Give each module a private scope. This keeps lexical meaning with no refusal, but it changes codegen and FlowInterp. `zttp check` verdicts then move, so it needs a re-record window.

**Decision 2: kernel coverage.**
- (a) Recommended: fold every module into one IR, with no kernel edit. Results and guards then cover every module. Omission stays undetected by the kernel, the same exposure that a single-module certificate has.
- (b) Do (a), then add a module table to the certificate: schema 6, a new section, a new kernel pass, and new reason codes. The kernel then refuses a missing module. It still does not establish that a root describes those bytes. Every certificate byte moves, and the committed mutant rows must still match.

**Decision 3: checks on a dependency.** `examples/handler/utils.ts` and both corpus seeds fail ZTS061 alone.
- (a) Recommended: enforce every check on a dependency except ZTS061, and record the exemption. ZTS061 is a naming rule on exported signatures, and no certificate property depends on it.
- (b) Enforce ZTS061 too. The example changes, and the frozen corpus seeds change, so a re-record window is needed.

**Decision 4: flow claims on a merged contract.** The P7 specification records that merged contracts omit flow claims. `no_secret_leakage` is required, so this plan cannot pass while that stands.
- (a) Recommended: supersede that line. A build runs FlowInterp over the modules of `ModuleGraph`, each one once, in load order. FlowInterp stays unchanged. This satisfies D-011, because it stays one producer.
- (b) Keep the recorded design. The refusal then stays, and this plan stops after Unit G1.

**Decision 5: `zttp check` parity.** After Unit G2, a handler can pass `zttp check` and fail `zttp build` on a dependency check.
- (a) Recommended: leave `zttp check` unchanged. Unit G8 closes the gap in the next re-record window, which the owner runs. Until then the build is the stricter gate.
- (b) Hold Units G2 to G7 until that window.

## Units

Each executor stops at its turn budget and hands back its changed files, check results, and open issues. Each bug fix starts with a failing test. Opus reviews each diff and runs each check again. Each exit status comes from an unfiltered step, read directly and not through a pipe.

Every unit keeps these invariants unless it names an exception: `zts check` moves 0 of 215 digest rows, `git diff` on `packages/proof-checker` stays empty, and the replay stays at 13 of 13 cases.

### G0: worklog and baseline

- Model: Opus. Turn budget: 10.
- Files: the worklog, `docs/plans/README.md`, `docs/roadmap.md`.
- Work: record the base commit, the `zig build test` count, the digest tables, and the free disk space.
- Acceptance: `zig build test` exits 0 from an empty cache, and the worklog holds the base values.

### G1: refuse a top-level name collision

- Model: Sonnet. Turn budget: 30. It depends on Decision 1 (a), and it can ship alone.
- Files: `packages/zts/src/modules/internal/module_graph.zig`, the graph error reports in `packages/tools/src/precompile.zig` and `packages/runtime/src/handler_instance.zig`, `scripts/smoke-v1.sh`.
- Work: after the graph is built, compare the top-level value names of all modules. Type names do not count. An imported binding of the same export does not count. A dependency that binds `handler` does count.
- Acceptance: the first failing test uses the `label` probe. The refusal names the identifier and both files, and exits 1, in `zttp compile` and `zttp serve`. `smoke-v1`, `test-zts`, and `test-zruntime` exit 0. `test-bytecode-identity` does not move.

### G2: run every check on every module

- Model: Sonnet. Turn budget: 50. It depends on Decisions 3 and 5.
- Files: `packages/tools/src/precompile.zig`, `packages/zts/src/pipeline.zig`, `packages/zts/src/modules/internal/compiler.zig`, `packages/zts/src/handler_verifier.zig`, `packages/zts/src/strict_checker.zig`.
- Work: pass the options into `compileMultiModule`, and run the boolean checker, type check, strict checker, verifier, virtual import validation, and bytecode verifier on each module. Code generation stays first, on the kept parsers, so no bytecode moves. Type-directed opcode specialization stays out of scope.
- Acceptance: one test per check shows a dependency defect that exits 1 with its exact diagnostic. A dependency that fails only ZTS061 still compiles. The test `compileHandler keeps merged properties null after loaded graph effects` stays until Unit G3. `test-bytecode-identity` does not move.
- Stop condition: `HandlerVerifier` starts from a handler. If it cannot check a module with no handler, the unit stops and reports the gap, because `state_isolated` and `result_safe` depend on it.

### G3: build the merged contract on the entry contract

- Model: Sonnet. Turn budget: 50. It depends on Decision 4 (a) and on Unit G2.
- Files: `packages/tools/src/precompile_contract.zig`, `packages/zts/src/handler_contract.zig`, `packages/zts/src/pipeline.zig`, `packages/tools/src/deploy_manifest.zig`.
- Work: start from a full entry contract, and pass the deduplicated `ModuleGraph` modules to `prepareChecked` as flow modules. Union the dependency facts, including `egress.urls`. AND the verifier properties and `effect_analysis_complete` across modules. Keep the entry capsule, budget, and intent. Run spec discharge again after flow, as the single-module path does. Refuse an `api.schemas` conflict in place of last-wins.
- Acceptance: a clean graph holds `no_secret_leakage` true, a dependency secret in the response holds it false, and an incomplete graph holds it false with `module_graph_gap`. A diamond graph test asserts one initialization. The tests that pin `properties == null` change to these literal values. `flow_analyzer_version` does not move.

### G4: fold the proof evidence

- Model: Sonnet. Turn budget: 60. It depends on Decision 2 and on Unit G3.
- Files: `packages/zts/src/modules/internal/compiler.zig`, `packages/zts/src/proof_ir.zig`, `packages/tools/src/precompile.zig`.
- Work: `CompileResult` owns one translation recorder per module. A new fold in `proof_ir.zig` keeps the entry IR as the root and adds each dependency root as a function node. It renumbers node ids, Result ordinals, witnesses, and residual ids. It runs only when dependencies exist.
- Acceptance: single-module certificates stay byte-identical. Two compiles of one graph give identical certificates. A dependency with an unguarded Result read is refused at `results_checked`. A dependency capability call with a non-literal resource appears in the residual plan. A graph over a limit gives a named refusal. The worklog records real node, witness, jump, and Result counts for the three multi-module handlers.
- Stop condition: if the kernel refuses a fold at `translation_check`, the unit stops. Decision 2 then reopens, and no kernel limit changes.

### G5: remove the refusal

- Model: Sonnet. Turn budget: 30. It depends on Unit G4.
- Files: `packages/runtime/src/build_command.zig`, `packages/runtime/src/proof_ratchet.zig`, `packages/runtime/src/server.zig` if the guard path needs it, `scripts/smoke-v1.sh`.
- Work: remove the refusal that names the missing certificate. Add a multi-module row to `test-proof-ratchet`. Change the `smoke-v1` step to compile, run, and assert the exact response body.
- Acceptance: `zttp compile`, `zttp build`, and `zttp deploy` exit 0 on `examples/handler/handler-with-imports.ts`, and the binary serves `{"message":"Hello, world!"}`. The dependency edit and graft cases from the Decision 14 measurement each exit 1 at boot, and the worklog records them.

### G6: documentation

- Model: Sonnet. Turn budget: 20.
- Files: `docs/decisions.md`, `docs/verification.md`, `docs/cli.md`, `docs/user-guide.md`, `docs/roadmap.md`, `docs/plans/README.md`, `packages/runtime/AGENTS.md`, `../ZTTP-WEBSITE`.
- Work: add one decision that records the supersession from Decision 4. State the target table in `docs/verification.md`, including the coverage limit. Update the website in a local commit, with no deploy or push.
- Acceptance: `test-doc-links`, `test-docs-drift`, `check-spine`, and `test-spine` exit 0. `deno task verify` exits 0 in the website.

### G7: final gate

- Model: Opus. Turn budget: 15.
- Work: from empty caches and with no provider key, run `zig build test`, `scripts/verify.sh`, `smoke-v1`, `test-proof-checker`, `test-proof-checker-mutants`, `test-proof-ratchet`, and `bench-check -Doptimize=ReleaseFast` on a quiet host. Compare the digests with the G0 baseline.
- Acceptance: each step exits 0. `git diff <base> -- packages/proof-checker` is empty. Every moved digest row traces to a unit.

### G8: `zttp check` parity, deferred

- Model: Opus plans, Sonnet implements. It runs only inside a re-record window that the owner opens.
- Work: run the per-module checks and the collision refusal in `zttp check`, and fix the double initialization if the G3 probe shows a false proof.
- Acceptance: a handler that passes `zttp check` passes `zttp build`. This plan closes without this unit, and the roadmap keeps it open.

## Moved by this plan

- Tests: the tests that pin the gap in `precompile.zig`, and the refusal test in `build_command.zig`.
- Output: the contract of a multi-module `zts compile`. The certificate of a single-module build stays byte-identical.
- Behavior: `zttp serve` refuses a name collision under Decision 1 (a). This is a deliberate change, because today it gives a wrong answer with no error.

## Risks

- **A verifier gap.** The handler verifier may need a mode for a module with no handler. Unit G2 finds this first and stops there.
- **Limits.** The graph-wide limit of 64 Result bindings can refuse a real handler. That refusal is safe, and raising the limit needs a kernel edit and an owner decision.
- **Top-level code.** A dependency runs top-level code at load, once per pooled runtime, with no request deadline. The entry module has the same behavior. This plan does not change it.
- **Divergence from `zttp check`.** Until Unit G8, the build refuses some handlers that `zttp check` passes. Decision 5 accepts this.

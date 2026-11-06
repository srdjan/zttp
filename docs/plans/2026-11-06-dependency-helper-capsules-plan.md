# Dependency helper capsules: discharge `Proof` and `Effects` on a helper in an imported module

The F18 residual-gaps plan (`2026-11-05-f18-residual-gaps-plan.md`) recorded this gap first in "Gaps that remain". The owner approved a plan for it on 2026-11-06. This document is that plan. The owner accepted Decisions 1 to 5, option (a) each, on 2026-11-06: run U0 to U4, commit each unit on local `main`, and do not push.

A Fable review and a Codex astra fact-check ran on the first draft on 2026-11-06. "Review findings" at the end lists each finding and what this draft changed.

## Status

| Unit | Status |
|---|---|
| U0 | Complete: results in "U0 results"; no stop condition applies |
| U1 | Complete: each spec row that carries a `function` prints at the helper's declaration; 17 gates passed |
| U2 | Complete: an arrow or function-expression helper bound by `const` is held to its capsule; 17 gates passed |
| U3 | Complete: each dependency helper is held to its declared `Proof` and `Effects` capsule in CHECK, the graph compile, and `zttp build`; 17 gates passed |
| U4 | Not started |

## Reproduction

Observed at `ecff8425` with a Debug build of `zts` and `zttp`. The probes are under `/tmp/zttp-g1/` and `/tmp/fable-g1/`.

The handler of each probe is `handler(req: Request): Proof<Response, "read_only">`. It runs `const t = stamp();` and returns `Response.text(String(t))`. The narrow handler capsule keeps the handler's own default-profile ZTS500 out of the result.

| Probe | Where `stamp` lives | `stamp` declares | `zts check` | `zts compile --verify --contract` | `zttp build` |
|---|---|---|---|---|---|
| p1 | `dep.ts`, imported | `function stamp(): Proof<number, "pure">`, returns `Date.now()` | exit 0, no diagnostic | exit 0 | exit 0, binary written |
| p2 | `dep.ts`, imported | `function digest(): Effects<string, "clock">`, returns `sha256("a")` from `zttp:crypto` | exit 0, no diagnostic | not run | not run |
| p4 | `handler.ts`, same file | `function stamp(): Proof<number, "pure">`, returns `Date.now()` | exit 1, ZTS500 | exit 0 | exit 1, no binary |
| pa | `handler.ts`, same file | `const stamp = (): Proof<number, "pure"> => { return Date.now(); }` | exit 0, no diagnostic | exit 0 | not run |

The single-module compile does not gate spec errors, so p4 exits 0 there by design (`reportSpecErrors` in `packages/tools/src/precompile_contract.zig`). `zttp build` gates every spec error on the merged contract (`packages/runtime/src/build_command.zig`). The graph compile gates authored spec errors (`refuseSpecErrors`).

The ZTS500 of p4 prints at `handler.ts:5:24`, the handler's line, and not at line 1, where `stamp` is declared. `zts check --json` on p1 reports `"proofCapsules":[]`.

## Cause

Observed in the code:

- `collectDependencyContracts` in `packages/tools/src/precompile_contract.zig` extracts each dependency with `initContractOnly`. That profile sets `source_types = .omitted` (`ModuleAnalysisSession.initContractOnly` in `packages/zts/src/pipeline.zig`).
- `dischargeFunctionCapsules` in `packages/zts/src/contract_builder.zig` runs for a dependency too. It calls `function_specs.dischargeWithStateWriters`, which reads each helper's signature through `functionSignature`. `functionSignature` returns null for `.omitted`, so `collectDeclared` finds no `Proof<...>` and no `Effects<...>`. No helper diagnostic is made.
- `functionSignature` also returns null for a `.var_decl` owner whose initializer is an arrow or a function expression, before it asks the type environment. That is the cause of probe pa, in every file. `functionTypeRef` in `packages/zts/src/type_env.zig` accepts an arrow function.
- `unionDependencyContract` in `packages/zts/src/handler_contract.zig` already copies a dependency's `spec_diagnostics` into the entry contract. `refreshContractSpecDiagnostics` keeps each diagnostic that carries a `function`. The graph compile and `zttp build` gate them. Only the discharge is missing.
- `checkGraphModule` in `packages/tools/src/precompile.zig` type-checks each dependency with `.source_types = .direct` and its file-import signatures, for CHECK and for the graph compile. It runs the verifier when `emit_verify` is set and never runs the flow evaluator. It sets no imported effects, and its session ends before the dependency contracts are extracted.
- Every spec diagnostic is placed at the handler. The CHECK card (`formatFailureSections` in `packages/tools/src/precompile_check.zig`) and the CHECK JSON (`appendSpecDiagnosticsJson`) use the handler's file, line, and column. `reportSpecErrors` prints the handler path for each row, and `zttp build` calls it. `SpecDiagnostic` in `packages/zts/src/contract_types.zig` has no location.

Inferred: after a fix of the discharge alone, a dependency diagnostic would print at the handler's file and line. When it has a cause, its suffix "demoted at line N" would give a line of `dep.ts` without the file name. An agent that reads it edits the wrong file.

## What already exists

- The U3 rule of the F18 residual-gaps plan: a helper that writes module state loses `pure`, `read_only`, and `deterministic`. `dischargeWithStateWriters` takes a `StateWriters` value. `ModuleAnalysisSession.collectStateWriters` builds it from the session's own flow result and verifier, and keeps only frames and writes of flow module 0, the entry. No session API accepts writers from outside.
- The flow evaluator runs once over the whole graph. Each `PersistentWrite` carries its module and a stack of `FunctionRef`, each with a module. `flowModulesForGraph` in `packages/tools/src/precompile_imports.zig` gives a dependency the id of its position in execution order plus one, and borrows `compile_result.parsers[position]`, so the flow nodes are nodes of that parser.
- The verifier writes of each dependency are kept under the same key: `GraphCheck.reported_writes` for CHECK and `MultiModuleBuild.reported_writes` for the graph compile. Both are filled only when `emit_verify` is set. The graph compile loop also appends the entry's writes, so a filter must keep `module == position + 1` and not `module != 0`.
- `collectDependencyContracts` computes `loaded_effects`, the export effects of each dependency in load order. `importedEffectsForLoadedModule` turns them into the imported effects of one module.
- A call to a file import always clears the caller's `pure` and `deterministic` (`effect_inference.zig`, the import-call branch; corrected during U3). `read_only` comes from the imported row. A blocked import merges a lower-bound row, and `CapsuleFacts.holds` in `spec_discharge.zig` refuses every property of a lower-bound row. Missing imported effects therefore fail closed.
- The build refuses two declarations of one top-level name in two modules. An import binding that names the identical export may repeat the name. A `function` name therefore identifies one declared helper in the graph.
- No dependency module in `examples/`, the flow-precision corpus, or the recorded DeepSeek data declares a `Proof<...>` or `Effects<...>` capsule (checked with `git grep` over every `.ts` file that a relative import reaches). The diagnostic corpus under `tests/corpus/check/` holds single-file cases only. U0 lists its goldens that hold a helper capsule diagnostic. The Fable review counted 8; that count is not checked.
- CHECK with `skip_contract` returns before the flow and the dependencies, so it discharges no capsule in any file. `zttp dev` and live reload run the full CHECK. The pi diagnostics tool runs the same CHECK. Re-exports are refused at parse (ZTS002).

## Decision 1: where the dependency discharge runs

Option (a), recommended: a separate pass after the flow evaluation and the merge. One shared function in `packages/tools/src/precompile_contract.zig` serves CHECK and the graph compile. For each dependency it opens a full session with `.source_types = .direct` and the module's file-import signatures, with the verifier and the flow evaluator off. It sets the module's imported effects from `loaded_effects` and builds the module's `StateWriters` from the graph flow result and `reported_writes`. A new session method, `ModuleAnalysisSession.dischargeHelperCapsules(writers)`, calls `function_specs.dischargeWithStateWriters` directly and returns the helper capsule table. The pass does not extract a contract, so it makes no handler-level row. It appends each helper diagnostic to the merged contract with the dependency's file. Dependency contracts stay contract-only, so no other merged field can change. Cost: a second type check of each dependency. U4 measures it.

Option (b): extract each dependency with a full session and authored source types, as the entry is. This needs fewer new functions, but each field of a dependency contract can change, and so can the merged contract and the certificate. This was not measured. In the graph compile the flow runs after the dependency extraction, so the state writers of a dependency need a reorder of `buildMultiModuleContract`.

Option (c): discharge in `checkGraphModule`, which already holds a typed session. That session has no imported effects, so a helper that calls another file gets a lower-bound row. A true `deterministic` or `read_only` capsule on such a helper is then refused. This fails closed but refuses correct code.

Option (d), from the Fable review: `checkGraphModule` records each dependency helper's declared names, line, and column in a side table keyed by function name. `collectDependencyContracts` discharges with that table, its own imported effects, and injected writers. In the graph compile the flow must then run before `collectDependencyContracts`. This removes the second type check. It adds a new builder input and a reorder of `buildMultiModuleContract`, and it splits one discharge over two phases.

The recommendation is (a), because it keeps the change in one new pass. When U4 measures a cost larger than the spread between runs, U4 reports the numbers before the commit, and (d) becomes the fallback.

## Decision 2: the location of a helper capsule diagnostic

Option (a), recommended: each helper capsule diagnostic carries the helper's file, line, and column. This covers ZTS500 and ZTS502 on a helper's `Proof`, ZTS503 to ZTS505 on its `Effects`, and ZTS606. The entry file and dependency files are both covered. The helper ZTS500 message changes from "declared Proof capsule was not discharged by handler proof" to a text that names the helper's own capsule. Today the handler ZTS500 and the helper ZTS500 have the same message. This also closes the second gap in the F18 list. In each corpus golden that holds a helper capsule diagnostic, that row changes its line and column, a helper ZTS500 row also changes its message, and no other row changes.

Option (b): the location as in (a), with the message unchanged.

Option (c): only a dependency diagnostic carries its file and line. An entry helper keeps the handler's line, and the second F18 gap stays open.

Under each option, the CHECK card, the CHECK JSON, `reportSpecErrors`, and the live-reload frame print the row's own file. `writeRestrictionFrame` in `packages/runtime/src/live_reload.zig` prints a source line only when the row's file is the handler's file. Today it prints a line of `handler.ts` under a dependency ZTS310 row too. The contract JSON (`writeSpecDiagnosticsJson`) does not change: `function` already names the helper.

## Decision 3: scope

Option (a), recommended: discharge only what a dependency helper declares, which is `Proof<...>` and `Effects<...>`. ZTS606 stays entry-only. A dependency has no handler, and the handler's own ZTS500 already fires through the imported row, so ZTS606 adds no soundness there. The public-helper rules ZTS610 and ZTS611, and the docs-mode ZTS508, stay entry-only. The `proofCapsules` and `effectCapsules` arrays of `zts check --json` stay entry-only. Each item goes into "Gaps that remain".

Option (b): also run ZTS610, ZTS611, and ZTS508 on dependency exports. Not measured: a probe of an exported dependency helper that calls `env` stopped first at ZTS061 and ZTS400. This option needs its own measurement over every existing graph before a decision.

## Decision 4: arrow-function helpers (probe pa)

Option (a), recommended: U2 fixes `functionSignature` for a `.var_decl` whose initializer is an arrow or a function expression, and asks the type environment for that initializer's signature. A false capsule on an arrow helper then fails in every file. U0 counts the arrow helpers with a capsule in examples and corpora, because each false one becomes a new error.

Option (b): list arrow helpers in "Gaps that remain", and leave them undischarged.

## Decision 5: execution

Option (a), recommended: run U0 to U4 in order. Commit each unit on local `main`, and do not push. Stop after U0 and report when an existing graph would gain a diagnostic, or when a recorded DeepSeek transcript holds a helper capsule row.

Option (b): run U0 only and return the measurements.

## Units

| Unit | Change | Main files | Model | Turn budget |
|---|---|---|---|---|
| U0 | Measurement, no code change. For each multi-module graph, record the `zts check --json` codes and exit status, and the `zts compile --verify --contract` exit status. Record the median wall time of 10 runs of each command on `examples/handler/handler-with-imports.ts` and the flow-precision `sibling-helper-holes` handler. List the goldens with a helper capsule row. Count the arrow helpers with a capsule. Read the 4 files under `packages/pi/src/simulator/testdata` that hold ZTS500, and count the rows that a helper owns | `/tmp/zttp-g1/u0/` only; the answers go into this plan | Opus | not applicable |
| U1 | Decision 2: a location on `SpecDiagnostic`, set for each helper capsule diagnostic and each ZTS606; every printer named in Decision 2 uses it. Under (a), the helper message changes | `packages/zts/src/contract_types.zig`, `function_specs.zig`, `contract_builder.zig`; `packages/tools/src/precompile_check.zig`, `precompile_contract.zig`; `packages/runtime/src/live_reload.zig`; corpus goldens | Sonnet | 40 |
| U2 | Decision 4: arrow-function helpers | `packages/zts/src/function_specs.zig`; tests; corpus cases | Sonnet | 30 |
| U3 | Decision 1: the dependency discharge pass, `dischargeHelperCapsules`, the per-module `StateWriters`, and the two call sites | `packages/tools/src/precompile_contract.zig`, `precompile_check_run.zig`, `precompile_graph_check.zig`; `packages/zts/src/pipeline.zig`; tests in `precompile.zig` and `precompile_check_tests.zig`; one step in `scripts/smoke-v1.sh` | Sonnet | 60 |
| U4 | The census against U0, the timing against U0, `docs/verification.md` section 9, "Cost and purity", and the build-refusal table, the "Gaps that remain" list of the F18 plan, `docs/plans/README.md`, the website check, and the full gate | docs | Opus | not applicable |

Each code unit starts with failing tests. The commit message records that each test failed without the fix.

U1 tests: p4 under `zts check --json` puts the ZTS500 at line 1 and the column of `stamp`, in `handler.ts`, with the literal message of the chosen option. The ZTS606 of `tests/corpus/check/bad/helper_breaks_handler_capsule.ts` moves to the helper's line. A handler-level ZTS500 keeps the handler's line.

U2 tests: pa gives ZTS500 at line 1 of `handler.ts`. An arrow helper with a true capsule, `const double = (x: number): Proof<number, "pure" | "total"> => x * 2`, gives no diagnostic. An arrow helper under `Effects<string, "clock">` that calls `sha256` gives ZTS503.

U3 tests, each on a two-file or three-file graph, through CHECK (`precompile_check_tests.zig`) and the graph compile (`precompile.zig`) with `emit_verify` set:

- p1 gives ZTS500 with `function` `stamp`. The `zts check --json` row has the literal `"file":"dep.ts"` and line 1. The graph compile fails with `error.SpecDiagnosticsRefused`.
- p2 gives ZTS503 and the ZTS505 warning at `dep.ts` line 3, and no ZTS611: the public-helper rules stay entry-only.
- An arrow helper in `dep.ts` with a false capsule gives ZTS500 at its line.
- A dependency helper with a false capsule that no module calls gives ZTS500. The discharge does not depend on reachability.
- A dependency helper `bump(): Proof<number, "pure">` that runs `count = count + 1` on a module binding gives ZTS500 with the write cause. The verifier names this write.
- A dependency helper under `Proof<number, "read_only">` that pushes onto a module array through its parameter, called from the handler, gives ZTS500. Only the flow evaluator finds this write.
- A dependency helper `double(x: number): Proof<number, "pure" | "total">` gives no diagnostic, and the graph compiles.
- A helper in `a.ts` under `Proof<number, "read_only">` that calls a pure export of `b.ts` gives no diagnostic. The same helper under `Proof<number, "pure">` gives ZTS500, because a call to a file import is never pure.
- A helper in `a.ts` under `Proof<number, "deterministic">` that calls an export of `b.ts` that reads the clock gives ZTS500.
- A dependency helper whose `Effects<...>` names a capability that it never reaches gives the ZTS505 warning at its line, and the graph compiles.
- A true `deterministic` capsule on a dependency helper behind a blocked import gives ZTS500 with the lower-bound suggestion. When no source shape blocks an import, U3 records why and drops this test.

`smoke-v1` adds one step: `zttp build` of a two-file project with p1 exits 1, names `dep.ts`, and writes no binary.

Gates for each code unit, unfiltered, with a private `ZIG_LOCAL_CACHE_DIR` and `DEEPSEEK_API_KEY` unset: `zig build test-zts`, `test-zts-cli`, `test-precompile`, `test-flow-census`, `test-contract-golden`, `test-expert-golden`, `test-diagnostic-corpus`, `test-standin`, `test-expert-app`, `test-cli`, `test-zruntime`, `test-proof-swallow`, `test-zts-layering`, `test-module-boundary`, `smoke-v1`, `test`, and `check-spine`. The R7c census in `packages/pi/src/tools/common.zig` must report `differences=0`. After U4, `bash scripts/verify.sh` runs on `main`.

## Risks

- A second type check of each dependency costs compile time. U0 and U4 measure it, as Decision 1 states.
- A dependency whose imports the graph cannot resolve has a lower-bound effect row. Its helpers then cannot discharge a capsule, so a true capsule is refused. This fails closed. U4 lists each such case that the census finds.
- Decision 2 (a) changes model-visible text. A `git grep` for the old message cannot tell a helper row from a handler row, because both rows use one message today. U0 reads the 4 recorded files that hold ZTS500. When U0 finds a helper row, the plan stops before U1, and the owner decides about a re-record. In every case, the offline replay runs before each commit.
- Decision 4 (a) turns a false capsule on an existing arrow helper into an error. U0 counts these helpers first.
- A helper in `a.ts` that calls a writer in `b.ts`, which no handler runs, is not a static writer: `staticWriters` follows calls inside one module. The flow evaluator covers each call that a request runs. This stays a gap.

## Gaps that remain after this plan

- Under Decision 3 (a): ZTS606, ZTS610, ZTS611, and ZTS508 do not run on a dependency helper, and `proofCapsules` and `effectCapsules` list entry helpers only.
- A static writer across modules, as in the last risk.
- Without `--verify`, `zts compile --contract` has no verifier writes. A writer helper that no request runs then keeps its capsule, in the entry and in a dependency. CHECK and `zttp build` verify.
- `specStateFor` in `packages/runtime/src/proofs/spec_diagnostic.zig` matches a row by `spec_name` only. A helper ZTS500 on `pure` therefore marks the handler's `pure` as not discharged in the live-reload HUD. This fails closed. Dependency helper rows make it occur more often.
- The other F18 gaps: a ZTS606 from the implicit default profile is not marked `implicit_default`, a dependency write cause has no file in the property hint, the HUD and the counterexample pipeline do not show a write cause, the over-reports, and a module initialization that never returns.

## Review findings

Codex astra checked the facts of the first draft. Seven claims were wrong or partly wrong, and this draft corrects each:

- The probe handlers store `stamp()` in `t` and return `String(t)`.
- A dependency diagnostic would print at the handler's file and line, not at the handler's file with a dependency line.
- `checkGraphModule` runs the verifier under `emit_verify`. Only the flow evaluator is off.
- Missing imported effects fail closed. Option (c) refuses true capsules. It does not pass false ones.
- A call to a file import clears `pure` even when the import is pure. The U3 test for composed effects now uses `deterministic` and `read_only`.
- An import binding that names the identical export may repeat a top-level name.
- Only the helper ZTS500 changes its message under Decision 2 (a). The other helper rows change location only.

Fable reviewed the reasoning. Each finding and the change:

- F1, arrow helpers are never discharged (observed with probe pa): Decision 4 and U2.
- F2, a text search cannot find a recorded helper row: U0 reads the 4 recorded files.
- F3, the live-reload frame prints a line of `handler.ts` under a dependency location: Decision 2 and U1.
- F4, the ZTS606 scope was undefined: Decision 3 states entry-only.
- F5, a cheaper design exists: Decision 1 (d), the fallback. Decision 1 (a) now calls `dischargeWithStateWriters` directly through a named session method.
- F6, verifier writes exist only under `emit_verify`, and the graph compile also keeps the entry's writes: "What already exists", the U3 tests, and "Gaps that remain".
- F7, `reportSpecErrors` prints the handler path: Decision 2 and U1.
- F8, no other surface passes a false capsule: recorded in "What already exists".
- F9, `specStateFor` matches by name only: "Gaps that remain".
- F10, missing tests: added to U2 and U3.

## U0 results

Measured on 2026-11-06 at `ecff8425` with the Debug build in `/tmp/zttp-g1/out/bin/`. The raw files are in `/tmp/zttp-g1/u0/`.

Multi-module graphs (`graphs.tsv`). No dependency declares a capsule, so U3 must add no diagnostic to any of them:

| Graph | `zts check` | `zts compile --verify --contract` | Codes |
|---|---|---|---|
| `examples/handler/handler-with-imports.ts` | exit 0 | exit 0 | ZTS305 x1 |
| flow-precision `sibling-helper/handler.ts` | exit 1 | exit 1 | ZTS400 x1, ZTS500 x2 |
| flow-precision `sibling-helper-holes/handler.ts` | exit 1 | exit 1 | ZTS400 x1, ZTS500 x4 |
| recorded `sibling-helper-holes` `expected/handler.ts` | exit 0 | exit 0 | ZTS306 x1 |
| recorded `sibling-helper-holes` `initial/handler.ts` | exit 0 | exit 0 | ZTS306 x1 |

Timing (`timing-before.txt`, hyperfine, 10 runs after 2 warm-up runs, load average 0.82). Retired instructions vary less than wall time, so U4 compares both:

| Command | Graph | Wall median | Wall SD | Instructions median | Instructions SD |
|---|---|---|---|---|---|
| check | `handler-with-imports.ts` | 6.36 ms | 0.44 ms | 71,132,622 | 143,530 |
| compile | `handler-with-imports.ts` | 7.25 ms | 0.29 ms | 75,703,652 | 163,425 |
| check | `sibling-helper-holes` | 6.72 ms | 0.35 ms | 73,531,242 | 135,884 |
| compile | `sibling-helper-holes` | 6.84 ms | 0.31 ms | 76,962,390 | 134,950 |

Corpus cases with a spec row that carries a `function` (`helper-goldens.txt`): 7, not the 8 that the Fable review counted. They are `capsule_helper_pushes_module_array_parameter` (ZTS500), `helper_breaks_handler_capsule` (ZTS606), `helper_exceeds_handler_budget` (ZTS607), `helper_pushes_module_array_parameter` (ZTS606), `helper_reaches_capability_outside_effects` (ZTS503, ZTS505), `two_level_helper_pushes_module_array` (ZTS606 x2), and `unreached_capsule_pushes_module_array` (ZTS500). ZTS607 also carries a `function`, so U1 moves every spec row that carries a `function`, ZTS607 included.

Arrow or function-expression helpers with a capsule in tracked `.ts` files: 0. The one match, `tests/corpus/check/bad/exported_arrow_const.ts`, is an arrow `handler` that ZTS609 refuses before the spec stage. ZTS609 refuses an exported function-valued `const`, so an arrow helper with a capsule can only be module-internal.

Recorded DeepSeek data: 4 files under `packages/pi/src/simulator/testdata` contain ZTS500. Each is model reasoning about the handler's own `no_secret_leakage` ZTS500. No file holds a helper capsule row.

The ZTS500 message is defined once, in `specDiagnosticMessage` in `packages/tools/src/precompile_check.zig`. Test expectations in `precompile_check_tests.zig` and `flow_census_gate.zig` repeat it; the `flow_census_gate.zig` rows are handler rows. `packages/runtime/src/proofs/spec_diagnostic.zig` has its own `specDiagnosticMessage`, which prints the suggestion and not this text.

## Findings during execution

- U1: the location is the declaration token, which is the `function` keyword. For `export function` it is the `function` after `export `. A helper ZTS500 whose cause is a clock read has no "demoted at" suffix: a helper's `cause` records only a write to module state. `reportSpecErrors` prints a file and a code, never a line. U1 sets no `Site.file`, so the owned-file path of `Site.clone` and `Site.deinit` gets its test in U3.
- U2: `Date.now()` is not a capability. The first p2 probe, `Effects<number, "crypto">` around `Date.now()`, showed no missed ZTS503: in the entry file it gives only ZTS505. Probe p2 now uses `sha256` under `Effects<string, "clock">` (`/tmp/zttp-g1/p2b`). In the entry file the same helper gives ZTS503, ZTS505, and ZTS611 (`/tmp/zttp-g1/p2c`). The test in `packages/zts/src/typed_frontend_tests.zig` that asserted an arrow helper's capsule is not read now asserts that it is read. An arrow helper with an `Effects<...>` ceiling also gets ZTS623, the rule for a module-internal ceiling, as a `function` helper does.
- U3: a call to a file import clears `deterministic` as well as `pure`, in the entry file too: `importExportVaries` in `packages/zts/src/effect_inference.zig` treats an export of a relative module as varying. Only `read_only` composes across files. The three-file test therefore uses `read_only` for the passing half. The test for a clock reader in a third file cannot tell the clock read from this rule. "What already exists" was wrong to say that `deterministic` comes from the imported row.
- U3: CHECK re-mapped each JSON row after the `already_mapped` boundary against the entry's text. A dependency row placed there, a flow-only ZTS310 from F18 U5 or a helper capsule row from U3, moved to the next line when its column passed the end of the entry line with the same number. Observed: a flow-only write at `dep.ts` 3:23 was reported at line 4. `remapEntryDiagnosticsToSource` in `packages/tools/src/precompile_check_run.zig` now re-maps entry rows only. A verifier ZTS310 in a dependency joins the result before the boundary and was never affected. The U3 implementer first worked around this by putting the false helper first in two tests.
- U3: no source shape that blocks an import was found, so the blocked-import test was not added. The fail-closed path rests on `mergeImportedEffect` and `CapsuleFacts.holds`, read in the code.
- U3: the implementer ran `python3 --version` once, against the rule. It changed no file.
- U3: three fixtures of the `zttp proofs gate` tests (`packages/runtime/src/proofs/pr_gate.zig`) declared `Proof<string, "injection_safe">` on a dependency helper. `injection_safe` is not a helper capsule property, so U3 reports ZTS502, the graph compile refuses, and the command exited 2. The same helper in an entry file got ZTS502 before this plan. The fixtures now declare `"total"`, which each helper holds. A project with an invalid capsule name on a dependency helper now fails the same way.

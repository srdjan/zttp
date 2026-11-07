# Dependency write causes: name a write in another file when it breaks the handler's capsule

The cross-module state writers plan (`2026-11-06-cross-module-state-writers-plan.md`) ranked this gap second in "Other gaps, ranked". After that plan closed, the owner said "keep going" on 2026-11-06. This document is the plan for that gap. Codex astra checked its facts and Fable checked its argument; "Review findings" lists each finding and its resolution. On 2026-11-06 the owner accepted Decisions 1 to 7 with option (a) each. The owner did not answer Decision 8 within the time limit, and Opus took option (a).

## Status

| Unit | Status |
|---|---|
| U0 | Complete |
| U1 | Complete: 18 gates, check-spine, and the census of eleven graphs are unchanged from U0 |
| U2 | Complete: 18 gates and check-spine pass; the census keeps every code and exit status, and four ZTS500 rows change as planned |
| U3 | Complete: two adversarial reviews and the empirical validation; the confirmed findings are fixed in U3a (`8c956f8c`) and U3b (`b998b2f0`); see "U3 results" |

## Reproduction

Observed on 2026-11-06 at `17f5259e` with the Debug build at `/tmp/zttp-g3/out`. The probes are in `/tmp/zttp-g3/probes/`.

Probe pF: `dep.ts` holds `const seen: number[] = [];` and `export function remember(x: number): number { seen.push(x); return x; }`. The handler, under `Proof<Response, "read_only">`, calls `remember(1)`. `zts check` gives ZTS500 at `handler.ts` 3:24:

- message: "declared Proof capsule was not discharged by handler proof (failing spec: read_only)"
- suggestion: "remove writing calls to zttp:cache / zttp:sql, or drop `read_only` from your proof-property set."

The handler makes no cache or SQL call. The cause is the push at `dep.ts` 4:12.

Probe pF1 is the same program in one file. It gives:

- message: "declared Proof capsule was not discharged by handler proof (failing spec: read_only; demoted at line 4:12 by `a write to module state`)"
- suggestion: "line 4 writes module state: copy the value into a local before the write, or move the state to zttp:cache."

Probe pB3: the handler imports `tally` from `a.ts` and does not call it. `a.ts` imports `bump` from `b.ts`, and `bump` runs `count = count + 1` at `b.ts` 4:9. The handler is under `Proof<Response, "deterministic">`. `zts check` gives ZTS500 with the suggestion "remove Date.now(), Math.random(), and performance.now() from the response path." The handler reads no clock. The cause is the write at `b.ts` 4:9: the verifier reports a module-state write in any file of the graph, and that sets `shares_state`, which clears `deterministic`.

Probe pD: `dep.ts` holds `let count = 0;` and the writer `bump`, and a handler with no capsule returns `Response.text(String(bump()))`. `zts check` and `zts compile --verify --contract` both give the default-profile ZTS500. Its suggestion lists `deterministic`, `idempotent`, `pure`, `read_only`, `retry_safe`, `state_isolated`, and `stateless`, and names no write. The graph compile writes that suggestion into the `specDiagnostics` of contract.json. Probe pD1 is the same program in one file, and its suggestion adds "The write to module state at line 4 removes deterministic, idempotent, pure, read_only, retry_safe, state_isolated, stateless. To keep them, copy the value into a local before the write, or move the state to zttp:cache."

The expert loop shows each of these texts to the model. `pi_repair_plan` copies the suggestion into `follow_diagnostic_help.summary`. The model gets a repair that cannot work.

## Cause

`clearSharedStateProperties` in `packages/tools/src/precompile_check_run.zig` clears `pure`, `stateless`, `read_only`, `retry_safe`, `deterministic`, and `idempotent` when `shares_state` holds. `shares_state` holds for a verifier write, for a flow write, and also when the flow evaluator cannot follow the handler (`flowSharesState` includes `cleared()`). `recordStateWrite` records the cause of each property that changed from true to false at that point, and also of `state_isolated`. It records nothing when the driver supplies no `VerifierFacts.state_write`.

Each driver computes `state_write` with `firstEntryWriteCause`. It reads the entry's verifier findings and the flow sites of module 0 only. CHECK calls it whenever `shares_state` holds. The two compile drivers (`packages/tools/src/precompile.zig#compileHandler` and `packages/tools/src/precompile_contract.zig#buildMultiModuleContract`) call it only inside the branch where the flow evaluator found shared state. A verifier-only write, as in pB3, gets no cause in a compile, even in the entry. `PropertyCause` (`packages/zts/src/contract_types.zig`) has a line, a column, and a borrowed snippet, and no file.

With no cause, `appendNotDischarged` in `packages/zts/src/spec_discharge.zig` falls back to `suggestionFor(name)`, the generic text for the property. `implicitDefaultSuggestion` adds its write sentence only when `stateWriteCauseFor` returns a cause.

## What already exists

- Dependency writes with their flow module id: the verifier writes in `GraphCheck.reported_writes` and `MultiModuleBuild.reported_writes`, and the flow `WriteSite` values. `packages/tools/src/precompile_imports.zig#flowIdAtPosition` gives the entry 0 and each dependency its position plus 1. `MultiModuleBuild.reported_writes` also holds the entry's writes under the entry's position plus 1, so a filter must select dependency positions exactly. The node of a write belongs to `compile_result.parsers[position]`, and `packages/tools/src/precompile_imports.zig#flowModulesForGraph` gives the path.
- `GraphCheck.appendDependencyWrite` turns a dependency write into a ZTS310 row with the dependency's file, line, and column. `packages/zts/src/modules/internal/file_resolver.zig#resolve` keeps the form of the path, so `./dep.ts` from `handler.ts` prints as `dep.ts`.
- Helper capsule rows of a dependency already carry a cause in their own file. `packages/zts/src/function_specs.zig#writeCause` gives the line, and `packages/tools/src/precompile_contract.zig#appendCapsuleRows` puts the file in `Site.file`. A cause with no file therefore means "in the file of the diagnostic's site", not "in the entry".
- The state-write snippet is the static literal `state_write_snippet`. A file would be the only allocation of a state-write cause.
- `SpecDiagnostic` is built with a cause at three places: `packages/zts/src/spec_discharge.zig#appendNotDischarged`, `packages/zts/src/spec_discharge.zig#dischargeCapsule`, and `SpecDiagnostic.clone`, which copies the cause shallowly today. `SpecDiagnostic.deinit` and `HandlerContract.deinit` free no cause today, and `recordStateWrite` overwrites the earlier cause.
- The readers of a handler state-write cause: two CHECK printers (`packages/tools/src/precompile_check.zig#specDiagnosticMessageAlloc` and `#formatFailureSections`, each with a copy of the "demoted at" suffix), the ZTS500 suggestion (`stateWriteSuggestion`), the default-profile sentence (`implicitDefaultSuggestion`), and `specStateFor` in `packages/runtime/src/proofs/spec_diagnostic.zig`. `specStateFor` copies the line, the column, and the snippet into the review facts, and the HUD and the ledger message is the suggestion. `causeFor` returns no state-write cause, so `live_reload.zig#LiveReloadState.renderHudInner`, `packages/runtime/src/counterexample_pipeline.zig#buildFromDelta`, and `packages/zts/src/proof_trace.zig#buildTrace` do not read it.
- The dependency fold: `foldDependencyProperties` (called by `GraphCheck.foldProperties` in CHECK and directly in the graph compile) runs after `applyContractFacts`. It clears `pure`, `read_only`, `stateless`, and `retry_safe` when the merged dependency property is false, and more when the dependency facts are not established. By reading `contract_builder.zig#ContractBuilder.computeProperties`, a dependency's `read_only` falls for a cache or SQL write and not for a module-state write. This is probable and U2 test 1 confirms it.

## Decision 1: where the file lives

Option (a), recommended: `PropertyCause` gains `file: ?[]const u8 = null`. Null means the file of the diagnostic's site. A `PropertyCause` value borrows its file. Two holders own it: `PropertyProvenance.state_write`, freed by `HandlerContract.deinit`, and `SpecDiagnostic.cause`, freed by `SpecDiagnostic.deinit`. `recordStateWrite` duplicates the driver's borrowed path and frees the cause that it replaces. `appendNotDischarged`, `dischargeCapsule`, and `SpecDiagnostic.clone` duplicate a non-null file. The doc comment of `PropertyCause` states this rule.

Option (b): store the flow module id in the cause and resolve the path at each printer. The HUD and the ledger have no module list, and `spec_discharge` would need one.

Implementation note, added after acceptance: the contract already backs a borrowed provenance string with `HandlerContract.owned_fault_cause_snippet`, which has a row in `contract_schema.zig`. The state-write file follows that pattern: `HandlerContract.owned_state_write_file` backs `property_provenance.state_write.file`, and `HandlerContract.deinit` frees it. This is the ownership of option (a), with the owner made explicit.

## Decision 2: which write is the cause

Option (a), recommended: a write in the entry stays the cause, as today. When the entry has none, the cause is the first dependency write: the lowest execution position, then the earliest line and column in that module (`packages/zts/src/effect_inference.zig#earlierWrite`), over both the verifier writes and the flow sites. Each candidate is a true cause of `shares_state`.

Option (b): prefer a flow site, which a request makes, over a verifier write that no request runs. pB3 has a verifier write only, so (b) still needs (a) as its fallback.

## Decision 3: the guard against a second cause in a dependency

`recordStateWrite` names a write only for a property that was true just before the write cleared it. For the entry, the entry's effect row has already cleared a property that a cache or SQL write removes, so a write is not named for it. The dependency fold runs later. A dependency that calls `cacheSet` and writes module state would get the write named for `read_only`. Removing the write would leave `read_only` failing.

Option (a), recommended: after the fold, each driver removes from the record every property that the dependency facts also remove. Such a property falls back to its generic suggestion. This also fixes an entry write next to a dependency `cacheSet`, which has the same defect today.

Option (b): keep the guard as it is, and record the defect as a gap.

## Decision 4: the text for a dependency cause

The remedy of the entry text does not work for a dependency write. In pB3, nothing can be copied into a local, and the author cannot act in `handler.ts`. The ZTS310 row of the same write already gives the line-level remedy.

Option (a), recommended: a dependency cause states the rule and two remedies, and names the file with the path of the ZTS310 row.

- message suffix: "(failing spec: read_only; demoted at dep.ts:4:12 by `a write to module state`)"
- suggestion: "`dep.ts` line 4 writes module state, and a module-state write in any imported file removes `read_only`: remove that write, or remove `read_only` from the capsule."
- default profile: "The write to module state at `dep.ts` line 4 removes deterministic, idempotent, pure, read_only, retry_safe, state_isolated, stateless. To keep them, remove that write from `dep.ts`."

An entry cause keeps each current text, so no single-file golden moves.

Option (b): the entry text with a file prefix. Its remedy cannot work for an uncalled writer.

## Decision 5: the compile drivers

Option (a), recommended: one selector replaces `firstEntryWriteCause`. All three drivers call it whenever `shares_state` holds, as CHECK does today. A verifier-only write then gets a cause in a compile too, in the entry and in a dependency. U0 lists each contract golden that this moves.

Option (b): change CHECK only. The graph compile keeps the generic text in contract.json.

## Decision 6: the HUD and the ledger

Option (a), recommended: `specStateFor` copies the line, the column, and the snippet only for a cause with no file. For a dependency cause it leaves them null. The suggestion, which names the file, carries the location. Fable checked that no runtime printer reads these fields and that no digest covers the review facts. The schema does not change.

Option (b): add `sourceFile` to the review facts JSON, which the ledger stores.

## Decision 7: execution

Option (a), recommended: run U0 to U3 in order. Commit each unit on local `main`, and do not push. Stop after U0 and report when a recorded DeepSeek transcript or a golden would change.

## Decision 8: the remedy when the graph has several writes

The Fable review in U3 found this question (finding F1 in "U3 results"). With two writing dependencies, the Decision 4 texts said "remove that write". After that repair, the property still failed, and the cause moved to the other write.

Option (a), recommended: change only the remedy of the two dependency texts, so that it names every write. Each write already has its ZTS310 row. The suggestion ends ": remove every write to module state that a ZTS310 row names, or remove `read_only` from the capsule." The default-profile sentence ends "To keep them, remove every write to module state that a ZTS310 row names."

Option (b): add the count, as in "the first of 2 writes". The selector must then count the writes the same way as the ZTS310 rows, over verifier and flow sites.

Option (c): keep the texts, and record F1 as an accepted risk.

The owner did not answer within the time limit on 2026-11-06. Opus took option (a), in U3b. The one-file texts do not change, because they do not claim that one write is enough.

## Units

| Unit | Change | Main files | Model | Turn budget |
|---|---|---|---|---|
| U0 | Measurement, no code change. Record the `zts check --json` codes and texts of pF, pF1, pB3, pB, pD, pD1, and the five multi-module graphs of the earlier plans. List each test and golden that asserts the generic text for a dependency write, including `packages/tools/src/precompile.zig#test "compileHandler graph gives a dependency write no cause line"`. List each contract golden with a verifier-only entry write (Decision 5). Search the expert and agent-protocol goldens and `packages/pi/src/simulator/testdata` for a multi-module handler ZTS500 | `/tmp/zttp-g3/u0/` only; the answers go into this plan | Opus | not applicable |
| U1 | Decisions 1, 4, and 6: `PropertyCause.file` and its ownership, the dependency texts in `spec_discharge` and in both CHECK printers, and `specStateFor` | `packages/zts/src/contract_types.zig`, `spec_discharge.zig`; `packages/tools/src/precompile_check.zig`, `precompile_check_run.zig` (`recordStateWrite` ownership only); `packages/runtime/src/proofs/spec_diagnostic.zig`; tests beside them | Sonnet | 45 |
| U2 | Decisions 2, 3, and 5: the selector in the three drivers and the guard after the fold | `packages/tools/src/precompile_check_run.zig`, `precompile_contract.zig`, `precompile.zig`, `precompile_graph_check.zig`; tests in `precompile_check_tests.zig` and `precompile.zig` | Sonnet | 50 |
| U3 | Adversarial review and empirical validation of the U1 and U2 diff (see "U3 validation"), then the census against U0, `docs/verification.md`, the gap list of the earlier plan, `docs/plans/README.md`, the website check, and `bash scripts/verify.sh` | docs; a defect that the review or the validation finds goes back to a fix unit with a failing test first | Opus, with Fable and Codex astra as reviewers | not applicable |

Each code unit starts with failing tests. The commit message records that each test failed without the fix, and names each guard.

### U1 tests

Through `spec_discharge` with a contract whose provenance has a cause with a file, through both CHECK printers, through `applyContractFacts`, and through `specStateFor`:

1. A cause with `file = "dep.ts"`, line 4, column 12, on `read_only`: the ZTS500 suggestion is the literal text of Decision 4 (a).
2. The same cause through `specDiagnosticMessageAlloc`: the literal suffix of Decision 4 (a).
3. The same cause through the text card printer (`formatFailureSections`): the same suffix.
4. The default-profile suggestion with that cause: the literal sentence of Decision 4 (a).
5. Guard: a cause with no file keeps each current text in tests 1 to 4.
6. Guard: a dependency helper's capsule row, with `Site.file = "b.ts"` and a cause with no file, keeps its current text.
7. `specStateFor` with a dependency cause gives no source line, column, or snippet. With a cause with no file, it gives the current values.
8. Ownership under `std.testing.allocator`: discharge with a cause that has a file, clone one diagnostic, then free the clone, the diagnostics, and the contract. Call `applyContractFacts` twice with causes that have files. Run `std.testing.checkAllAllocationFailures` over the discharge.

### U2 tests

Literal texts through CHECK (`precompile_check_tests.zig`). The graph compile refuses a failing capsule and prints only the file, the code, and the spec name, so graph compile tests read the default-profile suggestion of the returned contract.

1. pF: the handler ZTS500 has the literal message and suggestion of Decision 4 (a) with `dep.ts` 4:12, and the ZTS310 row of the write has `file` `dep.ts`.
2. pB3: the handler ZTS500 on `deterministic` names `b.ts` 4:9.
3. pD in CHECK and in the graph compile: the default-profile suggestion ends with the literal sentence of Decision 4 (a).
4. A graph compile of a capsule-free graph with an uncalled dependency writer: the suggestion names the write (Decision 5).
5. An entry write and a dependency write in one graph: the entry write is the cause.
6. Two dependencies with writes: the module that runs first is the cause.
7. One dependency with a flow-only write earlier in the source than a verifier write: the flow write is the cause. When no such shape can be built, report it.
8. One dependency that calls `cacheSet` and writes module state, under `Proof<Response, "read_only">`: the generic cache suggestion. The same graph under `Proof<Response, "deterministic">` names the write (Decision 3).
9. Guard: pF1 and pD1 keep their current texts.
10. The test "compileHandler graph gives a dependency write no cause line" changes to assert the dependency cause. The commit message gives the old and the new assertion.

Gates for each code unit, unfiltered, with a private `ZIG_LOCAL_CACHE_DIR` and `DEEPSEEK_API_KEY` unset: `zig build test-zts`, `test-zts-cli`, `test-precompile`, `test-flow-census`, `test-contract-golden`, `test-expert-golden`, `test-agent-protocol`, `test-diagnostic-corpus`, `test-standin`, `test-expert-app`, `test-cli`, `test-zruntime`, `test-proof-swallow`, `test-zts-layering`, `test-module-boundary`, `test-bytecode-identity`, `smoke-v1`, `test`, and `check-spine`. The R7c census in `packages/pi/src/tools/common.zig` must report `differences=0`. Opus reruns each gate from its own empty cache. After U3, `bash scripts/verify.sh` runs on `main`.

### U3 validation

The owner asked on 2026-11-06 to finish with adversarial reviews and empirical validation.

Adversarial review: after U2, Fable and Codex astra each review the combined U1 and U2 diff with a split brief. Each brief gives the diff and the plan, not Opus's conclusions. Fable tries to build a graph where the new text names the wrong write, names a write that is not the cause, or claims a property that does not hold. Codex astra checks ownership on every path that copies, clones, replaces, or frees a cause file, and every driver path that can reach the selector. Each finding gets a probe at the U2 commit. A confirmed finding gets a failing test and a fix unit. A rejected finding gets its reason in this plan.

Empirical validation, by Opus at the U2 commit:

1. The probes pF, pB3, pB, pD, the U2 test shapes, and each reviewer's probe through `zts check --json`, `zts check` (text), `zts compile --verify --contract`, and `zttp build`. Each output is recorded in "U3 results".
2. A repair check: for pF, pB3, and pD, apply the repair that the new text names, and confirm that the named property then holds. A text whose repair does not restore the property is a defect.
3. Mutants, each run against the unfiltered `test-precompile` and `test-zts` steps, and each expected to fail at least one test: the selector takes the last dependency write; the selector prefers a dependency write over an entry write; the selector reads the entry's own id in `MultiModuleBuild.reported_writes` as a dependency; the guard after the fold is removed; one CHECK printer drops the file; `SpecDiagnostic.clone` copies the file shallowly; `recordStateWrite` does not free the replaced file. A surviving mutant gets a test, or its reason in this plan.
4. `zttp dev` on pF with the HUD: the regression line and the review facts show no source line for the dependency cause, and the ledger event is written. Each `zttp dev` probe ends with `pkill` by the binary path.
5. A timing check with `hyperfine -N -i` on graphs 1 and 3 of the U0 census, before and after.

## Risks

- A test or golden that asserts the generic text for a dependency write changes. U0 lists each one, so a change is a fix and not a surprise.
- An owned file on a cause can leak or be freed twice through a copy path that the tests do not run. U1 test 8 runs the discharge, the clone, the replacement, and each allocation failure.
- Decision 3 (a) makes the guard conservative. A dependency whose `pure` falls for any call loses the write as the cause of `pure`, and that row falls back to the generic text.
- Decision 5 (a) moves contract.json text for a single-file handler with an uncalled writer. U0 lists the goldens.
- The cause names one write. A handler can lose a property to several writes, and the text names the first only, as in one file today. After U3b (Decision 8 (a)), the remedy of a dependency text names every write.

## Gaps that remain after this plan

- When the flow evaluator cannot follow the handler (`cleared()`), `shares_state` holds without a write, and the text still names a write when one exists. Removing the write does not restore the property. This is the same in one file.
- The HUD regression line and the counterexample pipeline read `causeFor`, which returns no state-write cause, in one file and across files.
- The entry remedy "move the state to zttp:cache" does not restore `read_only`, because `cacheSet` is classified `.write`. This text is the same in one file.
- The other ranked gaps of the cross-module state writers plan: items 3 to 7.
- An unresolved route dispatch also sets `shares_state` without a write (`GraphCheck` and `runCheckOnParsedSource`). With a dependency write present, the text names the write, and removing it does not restore the property. Fable could not build a shape that types: `const dispatch = found.handler; return dispatch(req);` gives ZTS600 (finding F3).
- The generic `pure` suggestion "remove side effects (virtual-module calls, Date.now, Math.random) from the handler body" also appears when the only side effect is a call into an imported module. The guard of Decision 3 correctly gives that row no write. The text is older than this plan (finding F2).
- In one file, the remedy of the default-profile sentence, "copy the value into a local before the write, or move the state to zttp:cache", names one write when there are several. The text is older than this plan. On 2026-11-06, `git grep` found it in no recorded transcript under `packages/pi/src/simulator/testdata`.

## Review findings

Codex astra (facts):

1. `shares_state` also holds for unknown analysis, and `recordStateWrite` also records `state_isolated`. Folded into "Cause"; the unknown-analysis case is a gap.
2. The compile drivers choose a cause only in the flow branch. This is Decision 5.
3. `MultiModuleBuild.reported_writes` holds the entry's writes under a non-zero id. Folded into "What already exists".
4. A cause with no file already means the dependency's own file for a helper capsule row. Decision 1 now defines null as the site's file, and U1 test 6 is its guard.
5. The graph compile cannot carry literal-message tests. U2 now tests texts through CHECK and the graph compile through the default-profile suggestion of the contract.
6. Allocator tests cover only the paths that they run, and `recordStateWrite` overwrites without freeing. U1 test 8 covers the replacement and each allocation failure.
7. The reader list was incomplete: there are two CHECK printers. U1 test 3 covers the second. The copy, clone, and free sites are in "What already exists" and in Decision 1.

Fable (argument):

1. The entry remedy does not work for a dependency write, and the same output already gives that write two other remedies. Decision 4 (a) now states the rule and removes the line-level remedy.
2. The by-value copies of a cause would free the contract's file a second time. Decision 1 (a) now names the three places that duplicate the file, and U1 test 8 runs the discharge.
3. The guard does not cover a property that the dependency fold also removes. This is Decision 3, with U2 test 8.
4. Missing tests: the order inside one module (U2 test 7), the agreement of the file with the ZTS310 row (U2 test 1), the second printer (U1 test 3), and ownership (U1 test 8).
5. Decision 6 (a) is safe, and (b) is not needed.
6. The recorded multi-file DeepSeek case `sibling-helper-holes` probably does not change. U0 confirms it, and `test-agent-protocol` joins the gates.

## U0 results

Measured on 2026-11-06 at `17f5259e` with `/tmp/zttp-g3/u0/run.sh` and the Debug build at `/tmp/zttp-g3/out`. Codes and exit statuses:

| # | Graph | `zts check` | `zts compile --verify --contract` | Codes |
|---|---|---|---|---|
| 1 | `examples/handler/handler-with-imports.ts` | 0 | 0 | ZTS305 |
| 2 | flow-precision `sibling-helper` | 1 | 1 | ZTS400, ZTS500 |
| 3 | flow-precision `sibling-helper-holes` | 1 | 1 | ZTS400, ZTS500 x2 |
| 4 | recorded `sibling-helper-holes` expected | 0 | 0 | ZTS306 |
| 5 | recorded `sibling-helper-holes` initial | 0 | 0 | ZTS306 |
| 6 | pF | 1 | 1 | ZTS310, ZTS500 |
| 7 | pF1 | 1 | 0 | ZTS310, ZTS500, ZTS606 |
| 8 | pB3 | 1 | 1 | ZTS306, ZTS310, ZTS500 x2 |
| 9 | pB | 1 | 1 | ZTS306, ZTS310, ZTS500 x2 |
| 10 | pD | 1 | 0 | ZTS310, ZTS500 |
| 11 | pD1 | 1 | 0 | ZTS310, ZTS500, ZTS606 x3 |

The ZTS500 texts of rows 6 to 11 are the texts in "Reproduction". The ZTS500 rows of graphs 2 and 3 are on `no_secret_leakage` and `cost_bounded`, so no cause of this plan reaches them. The contract.json of pD has the default-profile suggestion with no write sentence. The contract.json of pD1 has the sentence.

Tests and goldens:

- One test asserts the old behavior for a dependency write: `packages/tools/src/precompile.zig#test "compileHandler graph gives a dependency write no cause line"` asserts `state_write == null`. U2 test 10 changes it.
- Two tests assert a generic text, and both are single-file: `precompile_check_tests.zig#test "the deterministic ZTS500 keeps the Date.now() cause when a write also removed the property"` and `pi_repair_plan.zig#test "repair plan: a spec failure outside the requested goals is reported with a plan and leaves ok true"`. They do not move.
- `test-contract-golden` runs `zts check --contract`, which is CHECK, on single-file fixtures. Decision 5 changes only the compile drivers, so it moves no contract golden.
- No fixture under `packages/tools/tests/fixtures/expert` or `packages/tools/tests/fixtures/contract` has a relative import.
- The multi-file tests of `packages/pi/src/aggregate_proof.zig` and `loop.zig` have no module-state write in a dependency.
- The recorded DeepSeek data has two multi-file cases, `sibling-helper` and `sibling-helper-holes`. Their `lib/settings.ts` files have no module-level `let`, and no recorded file has a ZTS310 or module-state text. No recorded transcript moves.

Side observation: `zts compile --verify --contract` exits 0 for pF1, pD, and pD1, and writes the ZTS500 rows into contract.json. It exits 1 for pF, because the graph compile refuses a failing declared capsule. `zttp build` refuses pF1 with exit 1 and prints the CHECK message, so no binary is built. The difference is in the exit status of `zts compile` only. It is outside this plan.

## U3 results

Commits on local `main`: U1 `e0cb9319`, U2 `410b6356`, U3a `8c956f8c`, U3b `b998b2f0`. Each commit passed the 18 gates and check-spine, and the R7c census reported `differences=0`. The lead reran U1, U2, and U3b from an empty cache. U3a ran on the lead's own cache, and the U3b run from an empty cache covers it again.

### Adversarial review

Fable probed the U1 and U2 diff at `410b6356`. Its probes are in `/tmp/zttp-g3/fable-probes`.

- F1, confirmed and fixed in U3b. With two writing dependencies, the text said "remove that write", and after that repair `read_only` still failed (probes two-deps and flow-first-default). See Decision 8.
- F2, older than this plan: the generic `pure` text. See "Gaps that remain after this plan".
- F3, not built: an unresolved route dispatch with a dependency write. See "Gaps that remain after this plan".
- F4, older than this plan: `zts compile` and `zttp build` print only "<path>: ZTS500 read_only" for a failing declared capsule, and `zttp build` prints an error return trace. No fact differs between surfaces.
- Shapes that behaved correctly: a dependency in a subdirectory, a diamond import, one module under two spellings, an uncalled writer in the entry, a write through an imported array, a write in an arrow of an exported object literal, a write in a `forEach` callback, two writes on one line, a write during module initialization (not a write), a flow-only write in the first module, a helper capsule, four properties under one capsule, `Date.now()` together with a write, a `zttp:cache` write in one dependency and a module-state write in another, and a virtual-module import in an earlier dependency. Six runs of `zts check --json` gave identical output.

Codex astra checked the facts of the same diff, read-only.

- C1, confirmed and fixed in U3a: `refreshContractSpecDiagnostics` leaked the clone of a kept row when the append failed. The leak is older than this plan.
- C2, confirmed and fixed in U3a: `dupeSortedDedupedSpecs` freed only the name of each row that it had copied when a later allocation failed. The leak is older than this plan.
- C3, already a gap: a write named for `state_isolated` when the flow evaluation is also `cleared()`.
- C4, rejected: tests build the expected text with `allocPrint`. Only the path of the temporary fixture is computed. The rest of each text is literal.
- Sound: the ownership of the cause file on every path, the inputs of the selector in the three drivers, the exclusion of the entry's own id in `reported_writes`, the same file in the cause and in the ZTS310 row, the order of the fold and the re-discharge, and determinism.

### Empirical validation

1. Surfaces. pF, pB3, pB, pD, pC2, and pC5 ran through `zts check --json`, text `zts check`, `zts compile --verify --contract`, and `zttp compile`. Each surface that prints the cause gives the same file, line, and text. Text `zts check` prints the path relative to the current directory, as in "demoted at dep.ts:4:12".
2. Repair. For pF, pB3, pB, pD, and pC5, removing the named write makes each named property hold, and each property that the text leaves out stays false for its own reason. In pC5, `idempotent` stays false because the dependency removes `retry_safe`, which shows the guard of Decision 3. After the write is removed, `let` must become `const`, or ZTS604 refuses the binding. After U3b, removing every write in two-deps gives exit 0, and in flow-first-default only `pure` still fails, which the sentence left out.
3. Mutants, each against the unfiltered `test-precompile` and `test-zts` in a worktree at `410b6356`:

| Mutant | Result |
|---|---|
| The selector takes the last write of the chosen module | Survived at `410b6356`. U3b adds "CHECK names the earlier of two writes in one imported file", which kills it (1 of 597 tests fails). |
| The selector takes the module that runs last | Killed by both "runs first" tests |
| The selector prefers a dependency write over an entry write | Killed by three entry-write tests |
| The selector reads the entry's own id in `reported_writes` as a dependency | Survived. Equivalent: each such write is also an entry verifier finding, and the selector takes an entry write before any dependency write, so no driver output can change. |
| The guard after the fold is removed | Killed by "CHECK leaves a property that a dependency removes out of the write sentence of the default profile" |
| The message printer drops the file | Killed by three tests |
| The card printer drops the file | Killed by "formatFailureSections: the card names the file of a cause in an imported file" |
| `SpecDiagnostic.clone` copies the file shallowly | Killed in `test-zts` (double free) |
| `recordStateWrite` does not free the replaced file | Killed in `test-precompile` (leak) |

4. `zttp dev`. On pF, a reload that adds the write to `dep.ts` is refused, and the previous handler keeps serving. The reload prints "demoted at dep.ts:4:12" and the `dep.ts` remedy. The ledger holds one swap event, from the first proof. `zttp dev` refuses pD at start, because its default profile fails. So the HUD and the ledger record only states whose specs pass, and a cause in another file cannot reach them through `zttp dev`. The U1 tests of `specStateFor` cover that path.
5. Timing, with `hyperfine -N -i --warmup 3 --runs 30` at a load average of 8, Debug builds of `17f5259e` and `b998b2f0`. `zts check --json`: graph 1 6.3 ms before and 6.3 ms after, graph 3 6.4 ms and 6.5 ms. `zts compile --verify --contract`: graph 1 6.7 ms and 6.7 ms, graph 3 6.6 ms and 6.8 ms. Each difference is within 0.2 ms, the standard deviation of the runs. Graph 3 has two ZTS500 rows, so it runs the cause path.

### Side observations, older than this plan

- `zts compile` with no output path prints "Missing output path." and exits 0.
- Text `zts check` exits 2 for warnings only, as `docs/cli.md` says, but `zts check --json` exits 0 for the same input.
- The U2 implementer saw `zts compile` hang on its probe pR3. It does not reproduce: the build of `17f5259e` and the build of U2 both exit 1 in 0.02 s.
- The U1 implementer ran `python -` once and the U2 implementer ran `python3 --version` once, against the rule of this repository. Neither changed a file.

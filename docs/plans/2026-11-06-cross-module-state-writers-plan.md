# Cross-module state writers: a helper capsule that calls a writer in another file

The dependency helper capsules plan (`2026-11-06-dependency-helper-capsules-plan.md`) recorded this gap under "Risks" and "Gaps that remain after this plan". After that plan closed, the owner said "keep going" on 2026-11-06. This document is the plan for the next gap. Opus asked the owner twice on 2026-11-06 to accept Decisions 1 to 4 and got no answer. Under the owner's "keep going", Opus proceeded with option (a) of each decision: run U0 to U3, commit each unit on local `main`, and do not push. The owner can revert each unit commit. A Codex astra fact-check and a Fable review ran on the first draft; "Review findings" at the end lists what changed.

## Status

| Unit | Status |
|---|---|
| U0 | Complete: results in "U0 results"; no stop condition applies |
| U1 | Complete: the flag, the export rows, the import record, and the helper text in `packages/zts`; 18 gates passed |
| U2 | Not started |
| U3 | Not started |

## Reproduction

Observed on 2026-11-06 at `5665194a` with the Debug build. The probes are in `/tmp/zttp-g2/probes/`.

Probe pB5, two files:

`b.ts`
```ts
let count = 0;

export function bump(): number {
  count = count + 1;
  return count;
}
```

`handler.ts`
```ts
import { bump } from "./b.ts";

function tally(): Proof<number, "read_only"> {
  return bump();
}

export function handler(req: Request): Proof<Response, "injection_safe"> {
  return Response.text("ok");
}
```

`zts check --json` exits 0. Its only diagnostic is the ZTS310 warning at `b.ts` 4:9. `proofCapsules` reports `tally` with `"read_only":true` and `"discharged":true`. `zttp build` exits 0 and writes a binary. The `read_only` claim on `tally` is false: each call to `tally` writes `count`.

Probe pB6 moves `tally` into a third file, `a.ts`, that the handler imports and does not call. The result is the same: exit 0, no row for `tally`.

Probe pB2 is pB6 with a handler that calls `tally` and returns a plain `Response`. It gives ZTS500 for `tally` at `a.ts` 3:8, because the flow evaluator sees the write on the request path. So the gap is a helper that no request runs.

Probe pB7, found by the Fable review: `b.ts` holds `let count = 0;` and `export const api = { bump: (): number => { count = count + 1; return count; } };`, and the helper `tally(): Proof<number, "read_only">` in `handler.ts` returns `api.bump()`. `zts check` exits 0, and `tally` reports `"read_only":true`. In one file, the same shape gets ZTS500, because a call through a local holder sets `lower_bound`.

## Cause

A helper capsule loses `pure`, `read_only`, and `deterministic` when the helper writes state that outlives a request (`dischargeWithStateWriters` in `packages/zts/src/function_specs.zig`). The writer test has two parts:

- The flow evaluator names each function on the stack of a write during a request. It sees across files, but only on a request path.
- `staticWriters` names each function whose body, or a callee's body, holds a write that the verifier named. It follows `EffectFacts.calleesOf`, which holds call edges inside one module. A call to an import is not an edge.

A call to a file import clears `pure` and `deterministic`. The analyzer charges a relative import the full capability set, whose varying capabilities clear `deterministic`, and then merges the supplied export row (the relative-import branch in `packages/zts/src/effect_inference.zig`; `importExportVaries` answers false for a module that is not built in). `read_only` composes from the export's effect row: `EffectRow.readOnly()` is `!writes and !has_egress`. `writes` is set by an imported export classified `.write`, such as a cache or SQL write, and by an unknown module or a blocked import. An assignment to module state does not set it: the assignment visitor only visits the operands. So the export row of `bump` reads as `read_only`, and `tally` keeps it.

## What already exists

- The verifier writes of each dependency are known before the dependency contracts are collected. CHECK collects them in `GraphCheck.run` (`packages/tools/src/precompile_graph_check.zig`) as `reported_writes`, with the flow module id `position + 1`, before `GraphCheck.collectDependencies`. The graph compile collects them in `packages/tools/src/precompile.zig` before `buildMultiModuleContract`. The CHECK call to `collectDependencyContracts` does not pass them today: `MultiModuleBuild.reported_writes` keeps its empty default there. The graph compile also stores the entry's writes, under `module_index + 1`, so a consumer filters on the exact dependency id.
- `collectDependencyContracts` (`packages/tools/src/precompile_contract.zig`) extracts each dependency in execution order. Each module's export rows (`loaded_effects`) feed the imported effects of each later module and of the entry, through `importedEffectsForLoadedModule`. A module that is not yet in that table answers `.blocked`.
- Export rows are built by `Analyzer.exportEffectsWithReachability`, which `projectEffectFacts` calls inside `buildEffectFacts` during contract extraction. `contract_builder.zig` then clones the finished table. In a contract-only dependency session, `complete()` builds no effect rows, so write nodes given to the session before `extractContract` arrive in time. `exportEffectsWithReachability` already takes one per-function slice, `reaches_recursion`, and patches it into each function export and each holder (`moduleExportEffect` merges the rows of the holder's users). `staticWriters` needs only function bodies and callee edges, which exist before the export rows are built. It is private to `function_specs.zig` today.
- `collectFunctionsIn` records a function only from a `function_decl`, or from a `var_decl` whose initializer is a function. An arrow function inside an object literal is not a recorded function, so `staticWriters` cannot name it, and a holder such as `{ bump: () => ... }` has no user. The verifier does name its write: `sweepForHelpers` enters a function inside an object literal. In one file, a call through such a holder sets `lower_bound` (`markCallThroughHolder`). Through an import it does not (probe pB7).
- `mergeImportedEffect` merges an export row into the caller's row for a call and for a value reference (`chargeImportValue`). A blocked import merges the `incomplete` row, which has `writes` and `lower_bound` set, so a helper over it fails every capsule property today.
- `EffectRow.merge` ANDs `pure` and `deterministic`, unions the capabilities, and ORs each other flag. The fixed point merges the row of each callee and of each function referenced as a value into the caller, and then restores the caller's own `recursive`. So an OR flag on an export row reaches every function that calls or references the import, directly or through a local function.
- The parser refuses `export { } from`, `export * from`, and `import * as`. The module graph refuses an import cycle. An aliased import (`import { bump as b }`) keeps the export name for `ExportEffects.lookup`. A value that a module initializer computes (`export const bumper = makeBumper()`) is a `.blocked` export.
- `dischargeCapsule` (`packages/zts/src/spec_discharge.zig`) picks a suggestion from the `state_write` cause. With no cause, a failing `read_only` gets the generic text "remove writing module calls (zttp:cache / zttp:sql) and egress from the helper."

## Decision 1: the mechanism

Option (a), recommended: a new `EffectRow` flag, for example `writes_module_state`. `merge` ORs it, `eql` compares it, and the `incomplete` row sets it. Each module's export rows set it from that module's verifier writes:

- for a function export, when `staticWriters` names its function;
- for a holder export, when one of its users is a static writer, or when a verifier write sits inside the holder's initializer (probe pB7).

Each later module then gets the flag through the merges that exist. `dischargeWithStateWriters` adds `fe.row.writes_module_state` to its writer test. The seam: the effect facts options carry the module's verifier write nodes, and `exportEffectsWithReachability` takes a `writes_module_state: []const bool` slice beside `reaches_recursion`. `buildEffectFacts` computes that slice with the static-writer closure before it builds the export rows. `collectDependencyContracts` gives each module the `reported_writes` with its own id, and CHECK passes them.

No handler property, effect ceiling, or contract field reads the flag. The flag still has these effects beyond the false proof:

- `EffectRow.eql` sees it. The fixed point uses `eql` to detect convergence, and `pipeline.zig` uses it to refuse a changed import after the effects freeze. A flag that moves along a long chain of local calls can need more rounds. The loop stops at 16 rounds and then marks every row `lower_bound`, which fails closed. Today a chain with no capability converges in one round.
- A value reference to an imported writer sets the flag, as a call does, even with no call (`const f = bump;`). This is a new refusal. It follows the rule that `pure` already applies: holding a function counts as calling it.
- An entry helper with no capsule that reaches an imported writer can now get ZTS606, when the handler's capsule demands `read_only` (the caller-demand check in `contract_builder.zig`).
- A new refusal can change the `test-bytecode-identity` golden, which records refusals, and the contract goldens.

Option (b): the same flag, and `EffectRow.readOnly()` also reads it. The handler's `read_only` then also falls when the handler can reach an imported writer that no request path runs. This can remove a property that the flow evaluator proves today, so it needs its own census. It does not make the helper result more sound than (a).

Option (c): a call to a file import clears `read_only` for each helper, as it already clears `pure` and `deterministic`. This is one line. It refuses each true `read_only` capsule on a helper that calls a sibling export. The earlier plan's U3 test with a `read_only` helper over a clean sibling export would flip from pass to ZTS500.

Option (d): the effect walk finds a module-state write itself and sets the flag on the writer's own row. The walk already visits assignment targets and member callees, and it walks an inline arrow body into its owner's row, so pB7 needs no holder rule. The merges carry the flag, export rows need no patch, and no `reported_writes` reach the session. It also works without `--verify`, so it closes item 5 of "Other gaps". The cost is a second definition of a module-state write beside the verifier's (`objectIsShared` and `isSharedAlias` in `handler_verifier.zig`, and `isMutatingArrayMethod` in `mutating_methods.zig`), or a refactor that moves the verifier's test into one predicate that both call. A walk test narrower than the verifier's reopens a false proof across files; a broader one refuses true capsules.

The recommendation is (a). It closes the false proofs of pB5, pB6, and pB7, and it changes no handler verdict. It keeps the verifier as the one source of the static write set, which the F18 work and U3 of the earlier plan rely on. Option (d) is the better design if the verifier's test moves into a shared predicate first; that refactor is a plan of its own.

## Decision 2: what the new row says

The flag has no source node, so the row has no "demoted at" location. The row prints at the helper, as each helper row does since U1 of the earlier plan. Both options need a new `CapsuleFacts` field and a branch in `dischargeCapsule` before the `lower_bound` branch. Without them, the row gets the generic `read_only` text, which names zttp:cache and zttp:sql and is wrong here.

Option (a), recommended: `FunctionEffect`, not the hot `EffectRow`, records the first import whose merged row carried the flag: its module specifier and export name. The call branch and the value-reference branch set it. The suggestion then reads: "`tally` reaches `bump` from `./b.ts`, which writes module state, so it cannot prove `read_only`: remove `read_only` from the capsule, or stop reaching `bump`." A helper that reaches the writer only through a local function gets the fixed text of option (b). A model that repairs the entry can then find `b.ts`.

Option (b): the fixed text only. "`tally` reaches a function in another file that writes module state, so it cannot prove `read_only`: remove `read_only` from the capsule, or stop reaching the writer."

Neither text offers zttp:cache, because `cacheSet` is classified `.write` and also fails `read_only`. Each says "reaches", because a value reference sets the flag as a call does.

## Decision 3: scope

Option (a), recommended: item 1 of "Other gaps, ranked", with pB5, pB6, and pB7, for entry helpers and dependency helpers, in CHECK, the graph compile, and `zttp build`.

Option (b): also items 2 to 4. Each needs its own probes and tests, so this plan would grow from four units to about seven.

## Decision 4: execution

Option (a), recommended: run U0 to U3 in order. Commit each unit on local `main`, and do not push. Stop after U0 and report when an existing graph or a recorded DeepSeek transcript would gain a diagnostic.

## Units

| Unit | Change | Main files | Model | Turn budget |
|---|---|---|---|---|
| U0 | Measurement, no code change. Run `zts check --json` and `zts compile --verify --contract` on the five multi-module graphs of the earlier plan's "U0 results", and record the codes and exit statuses. List each tracked `.ts` helper with a `read_only` capsule that calls or references an export of a relative module. Record the instruction medians of 10 runs on `handler-with-imports.ts` and `sibling-helper-holes`. Search the recorded DeepSeek data under `packages/pi/src/simulator/testdata` for a helper with a `read_only` capsule. Record the longest chain of local calls in a tracked handler module. Record the codes of the U2 test 8 shape before the change | `/tmp/zttp-g2/u0/` only; the answers go into this plan | Opus | not applicable |
| U1 | The flag, its merge, its `eql`, the `incomplete` row, the export rows with the holder rule, the effect-facts input for the verifier writes of a module, the writer test in `dischargeWithStateWriters`, the `FunctionEffect` import record, and the Decision 2 cause and text | `packages/zts/src/effect_inference.zig`, `function_specs.zig`, `spec_discharge.zig`, `pipeline.zig`, `contract_builder.zig`; tests beside them | Sonnet | 50 |
| U2 | The two call sites: `collectDependencyContracts` gives each module its verifier writes, and CHECK passes `reported_writes` to it. Tests through CHECK and the graph compile, and one step in `scripts/smoke-v1.sh` | `packages/tools/src/precompile_contract.zig`, `precompile_graph_check.zig`; tests in `precompile.zig` and `precompile_check_tests.zig`; `scripts/smoke-v1.sh` | Sonnet | 40 |
| U3 | The census and the timing against U0, `docs/verification.md` section 9, the "Gaps that remain after this plan" list of the earlier plan, `docs/plans/README.md`, the website check, and `bash scripts/verify.sh` | docs | Opus | not applicable |

Each code unit starts with failing tests. The commit message records that each test failed without the fix, and names each test that is a guard and passed before it.

### U1 tests

Through `ModuleAnalysisSession` and the pub functions that the existing `function_specs.zig` and `pipeline_tests.zig` tests use. Object literals use `{ bump: bump }`, because shorthand is ZTS001.

1. A module whose export calls a function that writes a module binding: the export row has the flag set. An export that writes nothing: the flag is clear.
2. A holder export `export const api = { bump: bump }` whose user writes: the flag is set.
3. A holder export whose initializer holds an inline arrow that writes (pB7 shape): the flag is set.
4. An importer whose helper declares `Proof<number, "read_only">` and calls the writer export: ZTS500 on `read_only` with the literal Decision 2 text. The same helper through a local relay function: ZTS500 with the fixed text.
5. A `read_only` helper over a clean export of a module that also holds an unrelated writer: no diagnostic. This shows that the flag is per function and not per module.
6. A helper that holds the imported writer as a value, as `[1].map(bump)` and as `const f = bump;`, and declares `read_only`: ZTS500.
7. The `ImportedEffectsFrozen` check accepts the same writer row twice and refuses a row whose flag differs.
8. Guard: a blocked import gives ZTS500 on a `read_only` helper, before and after the fix.
9. Guard: the `pure` and `deterministic` rows of a helper over a writer export keep their current literal text.
10. A chain of 10 local functions between a `read_only` helper and an imported writer: ZTS500 with the fixed text, and no row of the module is `lower_bound`.

Tests 1 to 4, 6, and 10 fail before the fix. Tests 5, 8, and 9 are guards. Test 7 needs the new field, so it cannot run before the fix.

### U2 tests

Through CHECK (`precompile_check_tests.zig`) and the graph compile (`importFixture`, `CompileGraphFixture` in `precompile.zig`), with verification on:

1. pB5: ZTS500 for `tally` at `handler.ts` 3:1 with the literal message and suggestion; the graph compile fails with `error.SpecDiagnosticsRefused`.
2. pB6: ZTS500 for `tally` at `a.ts` 3:8.
3. pB7: ZTS500 for `tally` at `handler.ts` 3:1.
4. A holder across files, `export const api = { bump: bump }` in `b.ts` and `api.bump()` in the helper: ZTS500.
5. Three files, an `a.ts` helper over a `b.ts` relay over a `c.ts` writer: ZTS500 at `a.ts`.
6. A `read_only` helper over a clean export of a module that also holds an unrelated writer: no diagnostic, and the graph compiles.
7. The handler verdicts of pB5 do not change: `injection_safe` stays discharged.
8. pG and pG2 of "U0 results": an entry helper with no capsule that reaches an imported writer, under a handler capsule that demands `read_only`, with and without a call from the handler: the codes and locations that U0 records for this shape before the change, and the codes after it, as literal lists. This pins the ZTS606 effect.

`scripts/smoke-v1.sh` gains one step: `zttp build` on pB5 exits 1, names `handler.ts`, and writes no binary.

Gates for each code unit, unfiltered, with a private `ZIG_LOCAL_CACHE_DIR` and `DEEPSEEK_API_KEY` unset: `zig build test-zts`, `test-zts-cli`, `test-precompile`, `test-flow-census`, `test-contract-golden`, `test-expert-golden`, `test-diagnostic-corpus`, `test-standin`, `test-expert-app`, `test-cli`, `test-zruntime`, `test-proof-swallow`, `test-zts-layering`, `test-module-boundary`, `test-bytecode-identity`, `smoke-v1`, `test`, and `check-spine`. The R7c census in `packages/pi/src/tools/common.zig` must report `differences=0`. After U3, `bash scripts/verify.sh` runs on `main`.

## Risks

- `EffectRow` is a hot value type. A new flag adds one field to each row and one OR to each merge. U0 and U3 measure the cost.
- A test that compares whole rows with `eql` or a literal row may need the new field. These tests change only where the row now carries a write.
- Without `--verify`, there are no verifier writes, so no export gets the flag from a write in its own module. A blocked import still sets it, through the `incomplete` row. A writer in the same module has the same gap (item 5 below).
- A chain of more than 15 local calls between a helper and an imported writer can stop the fixed point, which then marks every row `lower_bound` and refuses every capsule property of the module. This fails closed. U0 records the longest such chain in the tracked handlers.
- A writer that only the flow evaluator finds, such as a push onto a module array through a parameter, sets no flag. A helper that no request runs and that reaches such a writer in another file keeps its capsule. The same is true in one file today.
- A helper over a writer export gets up to three rows with three different hints: `pure` and `deterministic` keep their current hints, because a file-import call already clears them before the writer test. This is item 2 of "Other gaps", and test 9 of U1 pins it.

## Other gaps, ranked

Each item was probed on 2026-11-06 at `5665194a`. They are outside this plan unless Decision 3 (b) is chosen.

1. This plan: a false `read_only` proof on a helper that calls or holds a module-state writer in another file (pB5, pB6, pB7).
2. Wrong repair hints when a write in a dependency breaks the handler's capsule. Probe pF: a handler under `Proof<Response, "read_only">` calls a dependency function that pushes onto a module array. The ZTS500 suggestion reads "remove writing calls to zttp:cache / zttp:sql". Probe pB3: a handler under `Proof<Response, "deterministic">` fails because of an unused writer in a dependency, and the suggestion reads "remove Date.now(), Math.random(), and performance.now() from the response path". Both hints are model-visible, so the expert loop gets wrong repair advice. `PropertyCause` has no file.
3. The HUD and the ledger mark a handler property as not discharged when a helper fails the same property name. Probe pD2: an unused helper `stamp(): Proof<number, "deterministic">` returns `Date.now()`, and the handler `Proof<Response, "deterministic">` holds. `specStateFor` in `packages/runtime/src/proofs/spec_diagnostic.zig` matches the helper row by `spec_name`. This fails closed, and `zttp build` refuses this program for the helper row.
4. A ZTS606 that the implicit default profile causes has no `implicit_default` mark. Probe pE: three ZTS606 rows, none marked.
5. A fail-open outside the shipped path: `zts compile --contract` without `--verify` writes a contract with no refusal row for a writer helper that no request runs (probe pC). `zttp build` and CHECK verify, so no shipped binary depends on it, and a contract alone is not proof-authoritative. CHECK skips verification only under its internal `skip_contract` option, which returns before the spec stage. Option (d) of Decision 1 would close it.
6. The over-reports, and a module initialization that never returns, from the F18 plan.
7. ZTS606, ZTS610, ZTS611, and ZTS508 on dependency helpers. This is a policy change with a large reach: ZTS610 would ask each dependency export with a nonempty capability set for an `Effects` ceiling.

## Review findings

A Codex astra fact-check and a Fable review ran on the first draft on 2026-11-06. Their reports are in `/tmp/zttp-g2/codex.log` and in the session record. This draft changed as follows.

Codex astra:

- The relative-import charge, not `importExportVaries`, clears `deterministic`. `writes` is also set by an unknown module and a blocked import. `EffectRow.merge` ANDs `pure` and `deterministic`. "Cause" and "What already exists" now say so.
- The export rows are built inside `buildEffectFacts`, so the static-writer closure must run there. Decision 1 names the seam.
- "Nothing else reads the flag" was too strong. Decision 1 (a) now lists the `eql` users, the 16-round limit, the ZTS606 effect, value references, and the goldens. U0, U1 test 7, U2 test 8, and Risks follow.
- The draft text offered zttp:cache, which also fails `read_only`. Decision 2 drops it.
- A blocked import sets the flag without `--verify`. Risks now says so.
- pB2 also changes the handler's return type; ZTS610 counts capabilities; CHECK has an internal `skip_contract`. The text now says so.

Fable:

- F1: an imported holder whose initializer holds an inline arrow writer escaped the draft (probe pB7: `zts check` exits 0, `tally` reports `read_only` true; the one-file shape is refused). Decision 1 (a) now has the holder-initializer rule, and U1 test 3 and U2 test 3 cover it.
- F2: the Decision 2 text had no home; without a cause the row gets the generic hint. Decision 2 and U1 now include `spec_discharge.zig`.
- F3: the blocked-import test passes before the fix. It is now a named guard.
- F4: `{ bump }` is shorthand, ZTS001. The tests use `{ bump: bump }`.
- F5: added the cross-file holder test, the per-function precision test, the `const f = bump;` refusal, and the guard on the `pure` and `deterministic` hints.
- F6: Decision 1 names the seam beside `reaches_recursion`.
- F7: option (d), a write test in the effect walk, is now in Decision 1 with the reason it is not recommended here.
- F8: Decision 2 (a) now names the import, after Fable's middle option.
- F9: item 5 is now called a fail-open.

## U0 results

Measured on 2026-11-06 at `5665194a` with the Debug build in `/tmp/zttp-g2/out/bin/`. The raw files and the script (`run.sh`) are in `/tmp/zttp-g2/u0/`. U3 reruns the same script.

Multi-module graphs (`graphs.tsv`). The codes count the `diagnostics` array of `zts check --json` only, so ZTS500 counts are lower than in the earlier plan, which also counted the spec rows:

| Graph | `zts check` | `zts compile --verify --contract` | Codes |
|---|---|---|---|
| `examples/handler/handler-with-imports.ts` | exit 0 | exit 0 | ZTS305 x1 |
| flow-precision `sibling-helper/handler.ts` | exit 1 | exit 1 | ZTS400 x1, ZTS500 x1 |
| flow-precision `sibling-helper-holes/handler.ts` | exit 1 | exit 1 | ZTS400 x1, ZTS500 x2 |
| recorded `sibling-helper-holes` `expected/handler.ts` | exit 0 | exit 0 | ZTS306 x1 |
| recorded `sibling-helper-holes` `initial/handler.ts` | exit 0 | exit 0 | ZTS306 x1 |

Timing (`timing.txt`, hyperfine, 10 runs after 2 warm-up runs, `-i` because two commands exit 1, load average about 2.2):

| Command | Graph | Instructions median | Instructions SD | Wall median |
|---|---|---|---|---|
| check | `handler-with-imports.ts` | 75,593,659 | 122,398 | 5.98 ms |
| compile | `handler-with-imports.ts` | 80,827,221 | 118,789 | 6.40 ms |
| check | `sibling-helper-holes` | 77,436,212 | 112,796 | 6.10 ms |
| compile | `sibling-helper-holes` | 81,206,654 | 127,453 | 6.25 ms |

Helpers with a `read_only` capsule that call or reference an export of a relative module, in tracked `.ts` files: 0. Three tracked files hold a `read_only` capsule and a relative import, and in each the capsule is on `handler`: the flow-precision `sibling-helper-holes` handler and the two recorded `sibling-helper-holes` handlers.

Recorded DeepSeek data: 5 files under `packages/pi/src/simulator/testdata` contain `read_only`. Each is the handler capsule of `health-holes` or `sibling-helper-holes`, in a handler file or in model output. No file holds a helper with a `read_only` capsule. The stop condition of Decision 4 does not apply.

The longest chain of local calls was not measured: no command reports it. U1 adds a guard test with a chain of 10 local functions between a helper and an imported writer, and asserts that the module rows are not `lower_bound`.

The U2 test 8 shape, before the change (probes `/tmp/zttp-g2/probes/pG` and `pG2`, `b.ts` from pB5, handler under `Proof<Response, "read_only">`, helper `tally(): number` returns `bump()`):

| Probe | Handler calls `tally` | `zts check` | Diagnostics |
|---|---|---|---|
| pG | yes | exit 1 | ZTS310 at `b.ts` 4:9; ZTS500 at `handler.ts` 7:24 (`read_only`); ZTS606 at `handler.ts` 3:1 (`read_only`) |
| pG2 | no | exit 1 | ZTS310 at `b.ts` 4:9; ZTS500 at `handler.ts` 7:24 (`read_only`) |

The handler's `read_only` fails in pG2 too, so pG2 is the shape where the change can add a ZTS606. U2 test 8 covers both probes.

## Findings during execution

- U1: the holder rule of Decision 1 (a) missed a holder that aliases another holder. U1 also sets the flag on a holder whose mentioned bindings (`refs`) hold a writer.
- U1: `staticWriters` moved into `effect_inference.zig` as `writeReach`, the one closure that the capsule discharge and the export rows read. It now follows value edges as well as call edges, so a same-module helper that holds a writer as a value also loses `pure`, `read_only`, and `deterministic`. No golden moved.
- U1: the first version allocated the write-reach table with no write nodes, and the existing test "late export capture failure releases a transferred rate limit namespace" failed, because it compares allocation counts. With no write node, U1 now allocates nothing.
- U1: the U1 implementer ran `python3 --version` once, against the rule. It changed no file. It also went over its turn budget of 50.

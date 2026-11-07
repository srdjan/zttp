# Default-profile ZTS606: mark the row, and give it and the ZTS500 a remedy that works

The cross-module state writers plan (`2026-11-06-cross-module-state-writers-plan.md`) ranked this gap fourth in "Other gaps, ranked". The owner said "keep going" on 2026-11-07, after gap 3 closed with no code change. This document is the plan for gap 4. Fable checked its argument and Codex astra checked its facts; "Review findings" lists each finding and its resolution. The owner did not answer the decision question within 60 seconds on 2026-11-07. Under "keep going", Opus took the recommended options: 1 (a), 2 (a), 3 (c), 4 (a), 5 (a), 6 (a), and 7 (a).

## Status

| Unit | Status |
|---|---|
| U1 | Committed as `110f4cd9` on 2026-11-07 on local main; the 18 gates and `check-spine` passed from an empty cache |
| U2 | Committed as `bad93c63` on 2026-11-07 on local main; the 18 gates and `check-spine` passed from an empty cache |
| U3 | Done on 2026-11-07: reviews, probes, repair checks, mutants, timing, and `verify.sh`; the F1 fix is `37cc075c` |

## Reproduction

Observed on 2026-11-07 at `a31349ca` with the Debug build at `/tmp/zttp-g4/out`. The probes are in `/tmp/zttp-g4/probes/`. In each probe, `stamp` is `function stamp(): number { return Date.now(); }` with no capsule, and the handler returns `Response` with no `Proof<T, P>`. So the default profile is active.

Probe pE: the handler returns `Response.text(String(stamp()))`. `zts check` gives three errors:

- ZTS500 at 5:24, the default-profile row: "it does not hold: deterministic, idempotent, pure", and a suggested capsule of 14 properties.
- ZTS606 at 1:1: "helper breaks a handler-demanded property and carries no Proof<...> capsule (failing spec: pure)", with the suggestion "annotate `stamp` with `Proof<T, "pure">` and satisfy it, or inline the helper into the handler."
- ZTS606 at 1:1, the same for `deterministic`.

The author demanded no property, so "handler-demanded" is false. `check --json` carries no mark on either row, because `implicit_default` is not serialized.

Repair checks on pE:

- The ZTS500 remedy, the suggested capsule on the handler, clears all three rows.
- The ZTS606 remedy, `Proof<number, "pure">` on `stamp`, clears no error. The `pure` row becomes a helper ZTS500 ("remove module calls and clock or RNG reads so the helper stays pure"), and the `deterministic` ZTS606 stays. A helper that reads the clock cannot satisfy that capsule. Inlining `stamp` moves `Date.now()` into the handler, and the default-profile ZTS500 keeps `deterministic`.

Probe pE3: the handler calls `const t = stamp();` and returns `Response.text("ok")`. The handler holds `deterministic`, because the clock value does not reach the response. The default-profile ZTS500 names only `pure`, and its suggested capsule includes `deterministic`. Both ZTS606 rows are present. Repair check: with the suggested capsule, CHECK still gives one error, the ZTS606 for `deterministic`, now an authored row. So the ZTS500 remedy does not work on pE3.

The compile paths:

| Probe | Shape | `zts compile` | `zttp compile --no-attest` |
|---|---|---|---|
| pE | one file | exit 0 | exit 1, "spec 3 error(s)" |
| pE3 | one file | exit 0 | exit 1, "spec 3 error(s)" |
| pEg | `stamp` in `dep.ts`, so no ZTS606 (gap 7) | exit 0 | exit 1, "Aborted: ... has 1 spec error(s) that `zttp check` also reports" |
| pEg2 | `stamp` in the entry, and the entry imports `greet` from `dep.ts` | exit 1, `error.SpecDiagnosticsRefused` | exit 1, "Aborted: handler did not compile", then a Zig error trace from `refuseSpecErrors` |

The graph compile skips a default-profile row, and the doc comment on `refuseSpecErrors` says that the default profile is advisory there. It refuses pEg2 only because the two ZTS606 rows carry no mark. The user of `zttp compile` then sees a Zig error trace in place of the normal refusal message.

## Cause

- `packages/zts/src/contract_builder.zig#ContractBuilder`: `dischargeFunctionCapsules` takes the demanded set from `contract.declared_specs`. When the handler declares no capsule, that list is the v1 profile, and `contract.declared_specs_implicit` is true. `makeMissingCapsule` does not read that flag, so no ZTS606 row has `implicit_default`, and the text says "handler-demanded".
- `packages/zts/src/spec_discharge.zig#dischargeSpecs` builds the suggested capsule of the default-profile ZTS500 from the handler's properties. It leaves out `read_only` when a `zttp:cache` or `zttp:sql` import forbids it, and it reads no helper row. A property that the handler holds but a reachable helper without a capsule breaks is in the suggestion. ZTS606 then refuses it after the author declares it.

## What already exists

- `SpecDiagnostic.implicit_default` in `packages/zts/src/contract_types.zig#SpecDiagnostic`. `clone` copies it, and contract JSON does not carry it.
- Readers of the mark:
  - `packages/tools/src/precompile_contract.zig#reportSpecErrors` with `.authored` skips a marked row. `refuseSpecErrors` uses `.authored` on the graph compile.
  - `packages/runtime/src/proofs/pr_gate.zig#onlyImplicitDefaultSpecErrors`: a side is comparable when every error has the mark. Its doc comment and `docs/proofs-and-receipts.md` say that ZTS606 stops the gate with exit 2.
  - `packages/tools/src/precompile_check.zig#specDiagnosticSubject` returns no subject for a marked row, so the "(failing spec: ...)" suffix is not printed. `specDiagnosticMessage` has default-profile messages for ZTS500 and ZTS501 only.
  - `packages/runtime/src/proofs/spec_diagnostic.zig#specStateFor` reads the mark only for a ZTS500 row. Gap 3 showed that no error row reaches it.
  - `packages/runtime/src/proofs/pr_gate.zig#isImplicitCapsule` reads `declared_specs_implicit`, not the row mark, so the mark does not change it.
  - Several readers act on the kind as well as the mark. The mark alone does not change the ZTS606 text or keep its suffix.
- `zttp build` and `zttp compile` gate every error, marked or not. `packages/runtime/src/build_command.zig#runBuild` calls `checkCapability`, which counts `CheckResult.specErrors` with no test of the mark. For a graph, `runBuild` also calls `reportSpecErrors` with `.every` on the merged contract. Both run before the binary is written. No change here alters that.
- `packages/tools/src/precompile_check.zig#refreshContractSpecDiagnostics` recomputes the handler rows and keeps every row that has a `function`. CHECK (`packages/tools/src/precompile_check_run.zig#runCheckOnlyFromSourceWithPathAllocator`), the single-module compile (`packages/tools/src/precompile.zig#compileHandler`), and the graph compile (`packages/tools/src/precompile_contract.zig#buildMultiModuleContract`) each call it after the ZTS606 rows exist. The builder writes the first ZTS500 before `dischargeFunctionCapsules` runs. The live reload, the PR gate, and the expert loop run CHECK. `compileHandler` runs the refresh before it applies the path facts (`cost_bounded`, `fault_covered`), and it does not run the refresh again (Codex astra finding C3, "Review findings").
- No recorded transcript holds the ZTS606 text or the default-profile text (`git grep` on 2026-11-07). The three corpus goldens with ZTS606 use an authored capsule. The ZTS606 defect seed `helper-breaks-property` uses an authored capsule. No code parses the ZTS606 text. Two generic comparisons use the whole message: `packages/pi/src/aggregate_proof.zig#diagnosticEqual` in the expert veto and `packages/tools/src/edit_simulate.zig#violationKey`. Each compares two runs of the same compiler, so a text change moves both sides.

## Decision 1: the mark

Option (a), recommended: `makeMissingCapsule` sets `implicit_default` from `contract.declared_specs_implicit`. The graph compile then skips the row as it skips the default-profile ZTS500. The PR gate and the text change as Decisions 3 and 4 state.

Option (b): no mark. Only the text changes. The graph compile keeps refusing pEg2, and the PR gate keeps exit 2.

## Decision 2: the graph compile

With option (a) of Decision 1, `zts compile` accepts pEg2, as it accepts pE, pE3, and pEg. `zttp compile` still refuses pEg2, now with the normal "Aborted: ... has 3 spec error(s)" message.

Option (a), recommended: accept this result.

Option (b): the graph compile keeps refusing every ZTS606 by kind.

## Decision 3: the PR gate

With option (a) of Decision 1, `zttp proofs gate` could compare a side whose only errors are the default-profile ZTS500 and default-profile ZTS606 rows. Today it exits 2 on such a side.

The first version of this plan argued that the handler's own properties are sound, so the comparison is safe. Fable's review disproved that argument (finding F1 in "Review findings"). The handler's `deterministic` and `idempotent` facts ignore a branch on a clock value. In probe A8, `stamp()` reads the clock, the handler branches on its result, and `deterministic` is PROVEN. Today the ZTS606 row for `deterministic` is the only error that stops the gate on A8. In pE3, which is sound, the same row stops the gate too. The gate cannot tell the two apart.

Option (a): the gate reads the mark on every row. A8 then gets a behavior verdict that names `deterministic` as kept.

Option (b): the gate keeps exit 2 for every ZTS606, with a check of the kind.

Option (c), recommended: the gate accepts a marked ZTS606 only when the handler's own property of that name is false. Then the row adds nothing to what the default-profile ZTS500 already names. pE becomes comparable. pE3 and A8 keep exit 2, as today. `docs/proofs-and-receipts.md` and the doc comment on `onlyImplicitDefaultSpecErrors` state the rule.

## Decision 4: the text of a default-profile ZTS606

The authored texts do not change.

- Message: "helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: pure)". `specDiagnosticSubject` returns no subject for a marked row before its switch on the kind. It needs an exception for `.missing_capsule`, because that row's `spec_name` is one property. `specDiagnosticMessage` needs a new `.missing_capsule` arm under `implicit_default`.
- Suggestion: "the handler returns no Proof<T, P> capsule, so the default profile demands `pure`, and `stamp` breaks it: declare the narrow Proof<T, P> capsule that the handler's ZTS500 row suggests, or make `stamp` hold `pure` and annotate it with `Proof<T, "pure">`."
- Suggestion when a write to module state is the cause: "the handler returns no Proof<T, P> capsule, so the default profile demands `read_only`, and `bump` reaches a write to module state at line 4: declare the narrow Proof<T, P> capsule that the handler's ZTS500 row suggests, or copy the value into a local before the write." A write gives this text on each of the three rows (`pure`, `read_only`, `deterministic`), with the row's property. The authored text also says "or move the state to zttp:cache". Under the default profile, a `zttp:cache` import gives a ZTS501 for `read_only` (Fable probe A5_cache), so that remedy does not clear the error.

The first version said "declare a Proof<T, P> capsule on the handler that leaves out `pure`". Fable's probe C1 showed that leaving out one property does not clear pE, because `deterministic` and `idempotent` also fail. So the text points at the ZTS500 capsule, which U2 makes correct. This needs a default-profile ZTS500 row next to each marked ZTS606 row. U1 test 9 checks that claim.

"Inline the helper" is not in the default-profile text. It moves the break into the handler, and the default-profile ZTS500 then names the same property. "Copy the value into a local" clears the error by removing the persistence, so it changes behavior. The authored text has the same limit.

Option (a), recommended: these texts.

Option (b): keep the authored texts under the default profile.

## Decision 5: the suggested capsule of the default-profile ZTS500

Option (a), recommended: the suggested capsule leaves out each property that a marked ZTS606 row names. `dischargeSpecs` and `implicitDefaultSuggestion` take an extra parameter, a list of property names to leave out. `refreshContractSpecDiagnostics` passes the `spec_name` of each marked ZTS606 row in the contract. The builder passes an empty list, because no ZTS606 row exists yet. The "it does not hold" list does not change, because it states the handler's own properties.

`compileHandler` must also run the refresh again after it applies the path facts. Today its contract is wrong in two ways. For pE3, the ZTS500 says "does not hold: cost_bounded, fault_covered, pure" while the same contract has `costBounded: true` and `faultCovered: true`. For the clean probe pClean (`export function handler(req: Request): Response { return Response.text("ok"); }`), CHECK gives 0 errors, but the `zts compile --verify --contract` contract has a ZTS500 row "does not hold: cost_bounded, fault_covered". `zttp compile` writes that row into the binary (`grep -a` on the binary at `6af15c69`). The row fails closed, because it claims less than the analysis proved. Without the second refresh, U2 test 4 cannot hold, because the single-module text differs from the CHECK text.

Option (b): no change. The ZTS500 remedy keeps failing on pE3.

## Decision 6: execution

Option (a), recommended: three units in order. A Sonnet implementer does U1 and U2. Opus reviews each diff line by line, reruns the gates from an empty private cache, and commits each unit on local main. Nothing is pushed. U3 is the adversarial review and the empirical validation.

## Units

| Unit | Model | Files | Acceptance | Turn budget |
|---|---|---|---|---|
| U1: mark the row and change its text (Decisions 1 to 4) | Sonnet | `packages/zts/src/contract_builder.zig`, `packages/zts/src/spec_discharge.zig`, `packages/tools/src/precompile_check.zig`, `packages/runtime/src/proofs/pr_gate.zig` (doc comment), tests in `packages/tools/src/precompile_check_tests.zig`, `packages/tools/src/precompile.zig`, and the PR gate tests, `docs/proofs-and-receipts.md`, `docs/verification.md` | U1 tests; the 18 gates of the earlier plans and `check-spine` pass | 60 |
| U2: the suggested capsule and the second refresh (Decision 5) | Sonnet | `packages/zts/src/spec_discharge.zig`, `packages/zts/src/contract_builder.zig`, `packages/tools/src/precompile_check.zig`, `packages/tools/src/precompile.zig`, tests | U2 tests; the same gates | 50 |
| U3: adversarial review and empirical validation | Opus, with Fable and Codex astra | this plan | "U3 validation" | none |

### U1 tests

Write each regression test first, run it, and confirm that it fails for the reason of the gap. A control (a row marked "Control") passes before and after the fix, and the commit message says so. Each expected value is a literal.

1. pE in CHECK: the two ZTS606 rows have the Decision 4 message and suggestion. The ZTS500 row keeps its current literal text.
2. Control: pE with `Proof<Response, "deterministic">` on the handler. The ZTS606 row for `deterministic` keeps the authored message and suggestion.
3. A default-profile handler that calls a helper with no capsule that writes module state: each of the three ZTS606 rows (`pure`, `read_only`, `deterministic`) has the Decision 4 write text with its property and line.
4. The graph compile of pEg2 (`compileHandler` on the two-module graph, verified): no `error.SpecDiagnosticsRefused`. The contract holds the ZTS500 row and the two ZTS606 rows, and each has `implicit_default`.
5. Control: pEg2 with `Proof<Response, "deterministic">` on the handler. The graph compile still returns `error.SpecDiagnosticsRefused`.
6. The PR gate: a default-profile handler that calls a clock helper on both sides, whose response status changes, gets the `breaking` verdict and exit 1, not exit 2. The same handler with a change that does not alter behavior, such as a comment, exits 0. Copy the harness `packages/runtime/src/proofs/pr_gate.zig#gateOverEdit` and the tests "run: an implicit-default handler whose status changes gets a breaking verdict marked implicit", "run: an implicit-default handler with an unchanged behavior is safe", and "run: a declared capsule that fails on both sides still exits 2".
7. Controls: the PR gate on a side with an authored ZTS606 still exits 2. The PR gate on pE3 and on A8 (a helper reads the clock, and the handler branches on its result) still exits 2, because the handler holds `deterministic`, so the marked row for it is not accepted (Decision 3 (c)).
8. The three existing tests that assert the authored text for a default-profile handler change to the Decision 4 text: "check refuses a helper mutation only when the capsule demands state_isolated" (the `bare` half), "a helper that pushes onto its parameter, called with a module array, unproves the read-only family", and "CHECK preserves measured lookup winners shadows and captures" (the `compute` case). The assertions of "a helper module write unproves a narrow capsule that claims the read-only family" use an authored capsule and do not change. Record their old literals in the commit message.
9. Each probe of this plan that has a marked ZTS606 row also has a default-profile ZTS500 row, because the Decision 4 text points at that row: pE, pE3, pEg2, and the write probe of test 3.

### U2 tests

The same rules as for the U1 tests apply to regressions and controls.

1. pE3 in CHECK: the ZTS500 suggestion names "it does not hold: pure", and its capsule leaves out `deterministic`. The literal is the full text.
2. Control, the repair check as a test: pE3 with the U2 suggested capsule gives no spec diagnostic in CHECK. It passes at HEAD too, because the capsule is a literal.
3. Control: pE keeps its ZTS500 literal, because `pure` and `deterministic` are already not in its capsule.
4. The graph compile of a pE3 shape whose entry imports a second module, and the single-module compile of pE3: the same ZTS500 suggestion. `stamp` stays in the entry module. A helper in a dependency gets no ZTS606 (gap 7), so it would not exercise the exclusion list.
5. Control: a handler with a declared capsule gets no change from the new parameter.
6. The single-module compile of pClean (`compileHandler` with the contract): the contract holds no spec diagnostic.
7. "CHECK preserves measured lookup winners shadows and captures": its `capture_contract_suggestion` loses `deterministic`, because its `compute` case has a marked ZTS606 row for `deterministic`.

### U3 validation

1. Fable and Codex astra review the U1 and U2 diffs, with split briefs: Fable gets the argument (Decisions 3 and 5), and Codex astra gets the facts (each reader of the mark, each driver, each text).
2. Probes pE, pE3, pEg, pEg2, and A8 on every surface: `zts check`, `zts check --json`, `zts compile`, `zttp compile --no-attest`, `zttp dev`, and `zttp proofs gate`. `check --json` does not carry the mark, so it shows only the text.
3. The repair check on each probe: apply each remedy that a new text names, then run CHECK again. The remedy passes only when the named property no longer fails.
4. Mutants on the mark, the subject rule, the write text, and the exclusion list. Give each survivor a test, or record why no test can kill it.
5. Timing of `zts check` on the corpus before and after.
6. `bash scripts/verify.sh` from an empty cache.

## Risks

- Decision 3 changes a documented gate result. A wrong argument would let the gate compare a side whose handler property is not sound. Fable checks the argument, and U3 probes it.
- `implicit_default` is transient. A contract read back from JSON loses the mark on a ZTS606 row, as it does on the ZTS500 row today. This plan adds no new difference.
- A golden that holds a default-profile ZTS500 for a program with a helper that breaks a property changes in U2. The scan on 2026-11-07 found no such golden: `handler_without_proof_capsule.diag` and `modules_all.contract.golden.json` hold no ZTS606 row. The full gates in U2 confirm it.
- No recorded transcript holds either text, so no corpus re-record is needed.

## U3 results

Opus, Fable, and Codex astra validated U1 (`110f4cd9`) and U2 (`bad93c63`) on 2026-11-07 with the binaries built at `bad93c63` (`/tmp/zttp-g4/out-u3`) and at `6af15c69` (`/tmp/zttp-g4/out`). The probes are in `/tmp/zttp-g4/u3-probes/` and `/tmp/zttp-g4/u3-fable/`.

- Surfaces (Opus): `zts check` and `zttp compile --no-attest` give the same exit status on pE, pE3, pE3fix, pEg, pEg2, and pClean before and after, so both still refuse every error. The binary of pClean at `6af15c69` embeds the row "does not hold: cost_bounded, fault_covered", and the new binary does not. The new binary holds the phrase only in the empty format string of the runtime template. `zttp dev` refuses pE in its preflight with 3 errors and the new texts. `zttp proofs gate` on a status change of pE exits 2 at `6af15c69` and exits 1 with `breaking` at `bad93c63`. pE3 and A8 still exit 2.
- Repair check (Opus): declaring the capsule that each ZTS500 row suggests gives 0 errors on pE, pEg2, pE3fix, and on 11 Fable probes with a ZTS606 row (A1 to A7, A11, B1, B5). B6 (a helper in a dependency) gets no ZTS606, which is gap 7. Fable repeated the check on 12 more shapes, with the same result except F3.
- Second refresh (Fable): `zts compile --verify --contract` and `zts check --json` give the same spec rows on 16 probes. At `6af15c69` they differ on pClean and pE3.
- Codex astra checked 8 claims: the readers of the mark, the build refusal, the order of the refresh in every driver, the second refresh, the token match, the borrowed names, the docs, and the recorded texts. Seven hold. Claim 7 found three doc sentences that claim more than the code. Opus corrected them: the gate accepts a side with only marked errors except a ZTS606 as stated, only the Effects errors ZTS504 and ZTS506 stop it (the ZTS505 warning does not), and ZTS606 covers a reachable helper in the entry file only.

| Finding | Reviewer | Resolution |
|---|---|---|
| F1, should-fix | Fable | The gate accepted a marked ZTS606 only through the ZTS500 row. Under a `zttp:cache` or `zttp:sql` import the handler's `read_only` failure is in the marked ZTS501 row, so a helper that writes through the store kept exit 2. Fail-closed and older than U1. Fixed: `handlerFailsProperty` also reads a marked ZTS501 row whose property is the same, with a regression test and a control. |
| F2, note | Fable | A clock read inside a nested function, an arrow in an object, or an inline arrow passed to a helper gets no ZTS606, and the handler keeps `deterministic` while the response follows a branch on it (probes h6, h8, h7b). The gate compares those sides at `6af15c69` too. This is the false `deterministic` proof: the three probes join the U3 list of the control-flow determinism plan. |
| F3, note | Fable | When a helper declares its own capsule and fails it (h25), the suggested capsule leaves the helper's authored ZTS500. That row is correct, and the gate's exit 2 is right. No change. |
| F4, note | Fable | "copy the value into a local before the write" clears the errors only with a real copy, such as a leading spread. An alias keeps the write. The authored text and the ZTS310 help use the same words. Recorded under "Gaps that remain after this plan". |
| F5, note | Fable | The same module write gives `exhaustive_returns`, `results_safe`, and `optionals_safe` "---" inline and PROVEN in a helper. Older than this plan. Recorded under "Gaps that remain after this plan". |

Mutants (Opus, in the scratch worktree `/tmp/zttp-g4/wt-mut` at `bad93c63`, unfiltered `test-precompile` or `test-cli`; logs in `/tmp/zttp-g4/mut-logs/`). Seven of ten are killed:

| Mutant | Killed by |
|---|---|
| M1: the ZTS606 row never carries the mark | 6 CHECK tests, for example "a clock helper under the default profile gets default-profile ZTS606 text next to the ZTS500 row" |
| M2: a marked ZTS606 row loses its subject | 6 CHECK tests, for example "check refuses a helper mutation only when the capsule demands state_isolated" |
| M3: the write case uses the authored write text | "a module write in a helper under the default profile gets the default-profile write text on each ZTS606 row" |
| M4: the refresh passes no excluded name | 4 tests, for example "a clock helper whose value the handler drops gets a ZTS500 capsule that leaves out the property of each ZTS606 row" |
| M5: the gate accepts every marked ZTS606 row | "run: a default-profile clock helper whose value the handler drops still exits 2" and "run: a default-profile handler that branches on a clock helper still exits 2" |
| M6: the gate accepts no marked ZTS606 row | "run: a default-profile clock helper that the handler returns gets a breaking verdict when the status changes" and "... is safe when only a comment changes" |
| M7: no second refresh in compileHandler | "compileHandler gives a clock helper the ZTS500 capsule that leaves out the property of each ZTS606 row" and "compileHandler of a handler that holds every default property keeps no spec diagnostic in the contract" |

Three survive, and no test can kill them today:

- M8 (the refresh also excludes the property of an unmarked ZTS606 row): a contract holds marked or unmarked ZTS606 rows, never both, because the mark is `declared_specs_implicit`. With unmarked rows the handler declares a capsule, so no default-profile ZTS500 suggestion is built, and the list is never read.
- M9 (`handlerFailsProperty` also reads a ZTS500 row with a `function`): no marked ZTS500 row has a `function`. The test is a guard against a future helper row with the mark.
- M10 (a substring match instead of an exact token): no name of the v1 profile is a substring of another, so the two matches agree on every possible row.

The F1 fix (`37cc075c`) got two more mutants, both killed: M11 (the ZTS501 line removed) by "run: a default-profile cache helper whose read_only the ZTS501 row names gets a breaking verdict when the status changes", and M12 (every marked ZTS501 row accepted) by "run: a default-profile clock helper under a cache import still exits 2 when the handler holds deterministic".

Timing (Opus): `zts check` over the 149 tracked `.ts` files under `tests/corpus/check/`, three interleaved rounds, both binaries Debug builds from the same command: 0.75, 0.70, and 0.68 s at `6af15c69`, and 0.76, 0.69, and 0.70 s at `bad93c63`. No difference shows at this scale.

`bash scripts/verify.sh` from an empty private cache at `37cc075c`: exit 0, "all per-commit gates passed".

## Gaps that remain after this plan

- Items 5 to 7 of "Other gaps, ranked" in the cross-module state writers plan.
- `zts compile` on one file exits 0 for an authored helper ZTS500 (probe pD2). `zttp compile` refuses it. This is older than this plan.
- "copy the value into a local before the write" (the default-profile write text, the authored write text, and the ZTS310 help) clears the errors only with a real copy, such as a leading spread. An alias keeps the write (U3 finding F4).
- The same module write gives `exhaustive_returns`, `results_safe`, and `optionals_safe` "---" when it is inline in the handler, and PROVEN when it is in a helper (U3 finding F5, probes `i1_write_ret` and `h1_write_ret` in `/tmp/zttp-g4/u3-fable/p/`). One of the two is wrong. It is older than this plan.
- A false `deterministic` proof, found by Fable during the review of this plan and older than it. The control-flow determinism plan (`2026-11-07-control-flow-determinism-plan.md`) fixes it, and its commit waits for the owner's re-record of the DeepSeek corpus. `deterministic` and `idempotent` ignore a branch on a clock value. Probe pA8c at `6af15c69`: the handler declares `Proof<Response, "deterministic" | "read_only">`, reads `const t = Date.now();`, and returns "even" or "odd" on `t % 2 === 0`. `zts check` gives 0 errors with `deterministic` PROVEN, and `zttp compile --no-attest` writes the binary. The binary logs "Proof accepted: weakest edge trusted, 3 disclosed edge(s)". It does not log "Proof cache: enabled", and 30 requests gave 17 "even" and 13 "odd". So the run cache was not observed to serve a stale response. When the server sets `cache_properties` is not measured yet. `docs/verification.md` discloses implicit flow for `no_secret_leakage` only (decision D9 of the flow redesign). In the PR gate, Fable's probe of the inline form gives "Verdict: `equivalent`" for a change that makes the response depend on the clock. This plan does not fix it. Decision 3 (c) keeps the helper form at exit 2.

## Review findings

Fable checked the argument and Codex astra checked the facts, with split briefs, on 2026-11-07 at `6af15c69`. Both used the HEAD binaries and edited no repository file. Fable's probes are in `/tmp/zttp-g4/fable-probes`. The Codex astra sandbox refused scratch writes, so its `zts compile` output and the new git probes were not run there. Opus confirmed F1 and C3 with its own probes.

| Finding | Reviewer | Claim attacked | Resolution |
|---|---|---|---|
| F1, should-fix | Fable | Decision 3: the handler's own properties are sound | Confirmed by probe pA8c. `deterministic` and `idempotent` ignore a branch on a clock value. Decision 3 now recommends option (c), and "Gaps that remain after this plan" records the false proof. |
| F2, note | Fable | Decision 5 passes in every shape | Holds in seven probed shapes: pE3, a helper that calls a helper, a module-state write, a holder object, two helpers, a dependency helper next to an entry helper, and pEg2. U2 test 4 keeps `stamp` in the entry module. |
| F3, should-fix | Fable | Decision 4: "a capsule that leaves out `pure`" | Accepted. Leaving out one property does not clear pE. The text now points at the capsule of the ZTS500 row, and U1 test 9 checks that the row exists. |
| F4, note | Fable | Decision 4 remedies | Accepted. The helper clause says "make `stamp` hold `pure`". The write text is on all three rows. "Copy the value into a local" changes behavior, as the authored text does. The ZTS501 claim is confirmed. |
| F5, note | Fable | Decisions 1 and 2 ship nothing new | Confirmed. The `zttp dev` preflight and `zttp compile` count every error. |
| F6, note | Fable | U1 test 1 needs two edits the plan did not name | Accepted in Decision 4. `check --json` cannot show the mark, so U3 reads only its text. |
| C1 | Codex astra | Cause: "from the handler's properties alone" | Corrected: the suggestion also leaves out `read_only` for a forbidding import. |
| C2 | Codex astra | The reader inventory | Corrected: `packages/runtime/src/proofs/pr_gate.zig#isImplicitCapsule` added, and the readers that act on the kind are named. |
| C3, material | Codex astra | "Each driver calls the refresh last" | Confirmed by Opus on pE3 and pClean. `compileHandler` refreshes before the path facts. U2 adds a second refresh, and U2 test 6 covers pClean. |
| C4, material | Codex astra | The list of tests whose text changes | Corrected: U1 test 8 names a third test, and U2 test 7 covers its suggestion. |
| C5 | Codex astra | "No code keys on the text" | Corrected in "What already exists": no parser, but two whole-message comparisons. |
| C6 | Codex astra | "Each test fails first" | Corrected: regressions and controls are separate. |
| C7 | Codex astra | PR gate test feasibility | Confirmed, with the harness and the three tests to copy in U1 test 6. |
| C8 | Codex astra | The ZTS501 claim | Confirmed on `examples/modules-all/modules_all.ts`. |

## Decision 7: the order of this plan and the false `deterministic` proof

The false `deterministic` proof is a fail-open in CHECK, in the contract, and in the PR gate. This plan is a text fix and a fail-closed refusal. With Decision 3 (c), the two do not depend on each other.

Option (a), recommended: run U1 and U2 of this plan now. While the Sonnet implementer works, Opus probes the false proof at HEAD and writes its plan. That plan gets the same validation and its own decisions.

Option (b): stop this plan, and plan the false proof first.

# Plan 013: An I/O-free handler is fault-covered, and deploy accepts what test accepts

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before you continue. Touch only the files in scope. If a STOP condition occurs, stop and report. When done, update the status row for this plan in `advisor-plans/README.md`.
>
> **Drift check, run first**: `git diff --stat c1ecdf65 -- packages/zts/src/fault_coverage.zig packages/zts/src/contract_types.zig packages/zts/src/contract_json_parser.zig packages/zts/src/path_generator.zig packages/zts/src/proof_trace.zig packages/tools/src/precompile.zig packages/tools/src/precompile_check_run.zig packages/runtime/src/build_command.zig tests/corpus/check/bad/handler_without_proof_capsule.ts docs/verification.md docs/proofs-and-receipts.md`
> If a file in scope changed, compare the Current state facts with the live code. If they do not match, stop and report.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: HIGH (moves the policy hash; needs an owner-run DeepSeek re-record; makes deploy stricter)
- **Depends on**: owner Decisions 16 and 17 (below); the re-record window (owner Decision 2, decision D-012 in `docs/decisions.md`). Run it in the same window as the U2 and U3 units of `docs/plans/2026-10-21-soundness-plan.md`, so that one re-record covers all three hash moves.
- **Category**: bug (completeness)
- **Planned at**: commit `c1ecdf65`, 2026-10-26
- **Source**: release review 2026-10-26, finding H3; earlier record: completeness audit L13

## Why this matters

The first handler in `docs/user-guide.md` ("Handler Shape") has no I/O, and `zttp check` refuses it with ZTS500 because `fault_covered` does not hold. `fault_covered` means every failable I/O site is covered; with zero sites that is true, but the code requires at least one site. Separately, `zttp test` refuses that handler while `zttp deploy` ships it, and `deploy` also ships a handler that breaks its own declared capsule. Users meet a refusal on their first handler and two gates that disagree.

## Owner decisions required

Decision 16: how to fix the zero-site case.
- (a) Zero sites holds vacuously. Bump `path_analyzer_version` from 4 to 5, as the doc comment on it requires, and re-record. **Recommended**: it is the correct meaning, and the U2 and U3 units need the same re-record.
- (b) Leave `fault_covered` out of the default profile only for zero-site handlers. Probably no hash move, but an explicit `fault_covered` claim stays refused and the card still shows `---`.
- (c) Docs only: add capsules to the 7 doc examples. No code change.

Decision 17: what deploy accepts. Decide it after the Step 0 census, which gives the number of repository examples and doc examples that 17 (a) would refuse.
- (a) `deploy` (and `build`, `compile`) refuse when `check` reports any spec error, so one rule decides. This is a breaking change: a handler without a capsule must prove the full default profile, as `docs/proofs-and-receipts.md` already says. On 2026-10-26, 10 of the 12 example handlers without a capsule reported ZTS500 at `c1ecdf65` (`examples/autoloop/handler.ts`, `examples/handler/handler-with-imports.ts`, `examples/handler/secret-leak.ts`, `examples/handler/sugar.ts`, `examples/modules/modules.ts`, `examples/modules/modules_all.ts`, `examples/routing/api-surface.ts`, `examples/routing/guard-flow.ts`, `examples/routing/match-handler.ts`, `examples/routing/router.ts`); `scripts/test-examples.sh` runs them with `serve --test` and never runs `check`, so they pass today. **Recommended, with every example and doc handler that stays refused after Step 1 fixed in this plan.**
- (b) `deploy` refuses only when a declared capsule is not discharged; a handler without a capsule keeps the current production acceptance. Document the difference.

Steps below implement 16 (a) and 17 (a). For 16 (b) or (c), or 17 (b), the executor stops and the planner rewrites the affected steps.

## Current state

- `packages/zts/src/fault_coverage.zig`, `FaultCoverageReport.isCovered`: `return self.covered == self.total_failable and self.total_failable > 0;`. The same `total_failable > 0` rule is in `packages/zts/src/contract_types.zig` (`FaultCoverageInfo.isCovered`) and in the contract decoder in `packages/zts/src/contract_json_parser.zig`.
- The check path sets the property from `report.isClean() and analysis_complete` and then `props.fault_covered = path_analysis.fault_clean` (`packages/tools/src/precompile_check_run.zig`). The compile path sets it only when `total_failable > 0 or !faultAnalysisComplete()` (`packages/tools/src/precompile.zig`); otherwise it stays false.
- `packages/zts/src/proof_trace.zig` writes the summary "No failable I/O sites in this handler yet." with `holds: false`.
- `packages/zts/src/path_generator.zig`: `pub const path_analyzer_version: u32 = 4;` with a doc comment that requires a bump for any change to what fault coverage proves. The version feeds the policy hash (`rule_registry.zig`, `policy-hash.txt`, `scripts/check-meta-drift.sh`) and the `meta` tool output, so the codegen replay in `zig build test-expert-app` goes stale.
- Default profile: `packages/zts/src/contract_builder.zig` uses the full `spec_discharge.v1_spec_names` set (17 names) when no capsule is declared; `dischargeSpecs` in `packages/zts/src/spec_discharge.zig` emits one combined ZTS500.
- Gates: `zttp check`, `zttp test`, and `zttp dev` call `precompile.runCheckOnlyWithOptions`; `totalErrors()` includes `specErrors()`. `zttp deploy` calls `compileHandler` in `packages/runtime/src/build_command.zig`. Its acceptance refusals are compile errors, `verify_failed`, missing bytecode, retired authority, and production acceptance, which requires four properties (`packages/proof-checker/src/policy.zig`); file-system and policy errors also stop it. None of these is a spec diagnostic: the compile path computes spec diagnostics and never gates on them. Reproduced 2026-10-26: a handler that declares `Proof<Response, "deterministic">` and returns `Date.now()` fails `zttp test` and deploys with exit 0.
- The `zttp init` template declares a `Guardrails` capsule, which is why `smoke-getting-started` passes.
- What moves under 16 (a), from reading (measure in Step 4): about 19 expectations in `packages/tools/src/precompile_check_tests.zig` that quote "does not hold: fault_covered"; `tests/corpus/check/bad/handler_without_proof_capsule.{ts,diag}` (it becomes clean; replace its source with one that fails another default property); `tests/corpus/README.md`; `packages/tools/tests/fixtures/contract/plain_ts.contract.golden.json`; `policy-hash.txt`; the five expert goldens; the codegen cassettes.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Setup | `unset DEEPSEEK_API_KEY; export ZIG_LOCAL_CACHE_DIR=<private dir> ZIG_GLOBAL_CACHE_DIR=<private dir>` | none |
| Focused | `zig build test-zts`, `zig build test-precompile`, `zig build test-contract-golden`, `zig build test-diagnostic-corpus`, `zig build test-meta-drift`, `zig build test-standin`, `zig build test-flow-census`, `zig build test-cli`, `zig build test-zruntime` | `0` each, except as noted in Step 4 |
| Replay | `zig build test-expert-app > e.log 2>&1; echo $?` with `DEEPSEEK_API_KEY` unset | non-zero with a stale-cassette failure after Step 1; `0` after the re-record |
| Flows | `zig build smoke-getting-started`, `zig build smoke-v1` | `0` each |
| Aggregate, spine, full gate | `zig build test`, `git add -A && zig build check-spine`, `bash scripts/verify.sh` | `0` each after the re-record |

The DeepSeek recorder and any commit that lowers `expect_first_attempt_green` pins are run by the owner through `!` (the session classifier refuses them). A partial recording runs into staging but cannot activate.

## Scope

**In scope:** the files in the drift check, `packages/tools/src/precompile_check_tests.zig`, `tests/corpus/README.md`, `packages/tools/tests/fixtures/contract/plain_ts.contract.golden.json`, `policy-hash.txt`, the expert goldens, the deploy and build tests in `packages/runtime/src/build_command.zig`, `CHANGELOG.md` (Breaking changes), and, under Decision 17 (a), the example handlers in `examples/` and the handler examples in `docs/user-guide.md`, `docs/typescript.md`, and `docs/verification.md` that stay refused after Step 1, plus `../ZTTP-WEBSITE` statements about what deploy accepts (follow its `AGENTS.md` and run `deno task verify`).

**Out of scope:** the U2 and U3 code (their own spec); the meaning of any other property; `zttp proofs gate` policy.

## Steps

### Step 0: Census for Decision 17

Run `zttp check --json` on every handler under `examples/` that declares no `Proof<` capsule, and on each handler example in `docs/user-guide.md`, `docs/typescript.md`, and `docs/verification.md` (extract each to a scratch file). Record which report ZTS500 and which default properties fail. Repeat the census after Step 1 on a scratch build. Give the owner both lists before Decision 17.

**Verify**: the census lists every file and its failing properties, before and after Step 1.

### Step 1 (Decision 16 a): Zero sites holds

Remove `and self.total_failable > 0` (and its equivalents) from the three `isCovered` sites. In the compile path, set `fault_covered` for every handler from the same rule as the check path. Change the zero-site summary in `proof_trace.zig` to state that the property holds because the handler has no failable I/O site. Bump `path_analyzer_version` to 5 with a one-line reason.

**Verify**: `zttp check` on the "Handler Shape" handler exits 0. `zig build test-zts` exits 0.

### Step 2 (Decision 17 a): One acceptance rule

In `compileHandler` (or the shared compile entry that `deploy`, `build`, and `compile` call), refuse when the compiled contract's spec diagnostics contain an error, and print them the way plan 007 prints them for `test`. Add tests: the `Date.now()` handler with a `deterministic` capsule is refused by deploy; the "Handler Shape" handler deploys.

Under Decision 17 (a), fix every example and doc handler that the Step 0 census still lists after Step 1: declare the narrow capsule it holds, or change it so it holds the default profile. Add a `zttp check` pass over the examples to `scripts/test-examples.sh`, so the examples cannot drift from the acceptance rule again.

**Verify**: `zig build test-cli`, `zig build test-zruntime`, and `zig build test-examples` exit 0; in a scratch project, `zttp test` and `zttp deploy` agree on both handlers.

### Step 3: Regenerate the hashed pins

Run `zig build && ./zig-out/bin/zts describe-rule --hash > policy-hash.txt`, then `bash scripts/update-expert-goldens.sh`, then update every other pin that a failing test names, by copying the printed value. Update `handler_without_proof_capsule` with a source that fails another default property, and regenerate its `.diag` with the corpus tool that `zig build test-diagnostic-corpus` documents.

**Verify**: every focused gate in the table exits 0 except `test-expert-app`, which fails only with a stale cassette.

### Step 4: Measure and hand off the re-record

Report the exact list of changed tests and goldens. Then stop and hand the owner the re-record commands as `!` lines, in one batch with the U2 and U3 hash moves. After the owner records, run every gate in the table.

**Verify**: after the re-record, `zig build test-expert-app`, `zig build test`, `check-spine`, and `bash scripts/verify.sh` exit 0.

### Step 5: Document the change

`docs/verification.md`: `fault_covered` holds when the handler has no failable I/O site. `docs/proofs-and-receipts.md`: deploy refuses a handler that check refuses. `CHANGELOG.md` `[Unreleased]`: list both under Breaking changes with their migration actions (rebuild handlers; declare a narrow capsule for a handler that cannot prove the full default profile).

**Verify**: `test-docs-drift`, `test-doc-links`, and `sh scripts/render-release-notes.sh` against a draft version exit 0.

## Done criteria

- [ ] The "Handler Shape" handler passes check, test, and deploy.
- [ ] Deploy refuses every handler that test refuses.
- [ ] The re-record is done and every gate exits 0.
- [ ] CHANGELOG lists both breaking changes.

## STOP conditions

- The owner has not chosen Decisions 16 and 17, or the re-record window is not open.
- A property other than `fault_covered` changes its verdict on an existing corpus case.
- The replay fails for a reason other than a stale cassette.
- Plan 007 has not landed (Step 2 reuses its printing).

## Maintenance notes

- Side effect of 16 (a), intended: `zttp proofs gate` grades a lost `fault_covered` as critical (`pr_gate.zig`), so adding the first uncovered failable call to an I/O-free handler now fails the gate. That is the correct signal; the CHANGELOG entry must say so.
- The "proof: partial" card label comes from `contract_diff.deriveProofLevel`, which requires `bytecode_verified`; the check path always sets that to false. That is a separate item, not in this plan.

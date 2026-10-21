# Pruning round 2: plan for rounds 2a and 2b

Status: draft plan, 2026-10-21. Implementation is not yet approved.
Source list: [round 2 list](2026-10-20-pruning-round-2-list.md), audited at `294680be`.
The owner chose the recommended option for decisions 1 to 5 of that list with "as recommended".
Those choices are: 1B (rounds 2a and 2b), 2A, 3A, 4A, and 5A.

## Validation

One Fable validation round checked every unit against `303dc3cc` and found ten list claims false.
This revision applies each finding. Rejected list rows: B8 (every sqlite member has a caller).
Corrected list rows: A6, A15, A17, A20, B6, B15, B17, D1, and D5.
U12 is narrowed because most of the resolver is live.

## Constraints

This plan preserves supported handler behavior, public CLI commands, diagnostic identities, wire formats, the semantics and opcode registry hashes, independent acceptance, and request isolation.
Round 2c (A10, A12, A13, A18, and Tier C) is out of scope.
Every deletion first confirms with `git grep -w` over all tracked files that no caller remains.
A unit that finds a live caller stops and reports it. It does not widen the deletion.

Use Zig 0.16.0. Take every verdict from an unfiltered `zig build <step>` run.
Redirect output to a file and read the exit status directly.
Never cite a `-Dtest-filter` run or the status of a pipeline's last command.
Each unit is one commit on local main. Nothing is pushed.

## Baseline

Before unit U1, run `zig build test`, `zig build check-spine`, and `zig build test-zruntime` at the plan's base commit.
Record each exit status in the worklog.
A baseline failure is recorded and is not attributed to this plan.

## Round 2a: false passes, fail-open shapes, and guidance

### U1: gate input floors (A1, A17, A19)

A1: `scripts/check-capability-helpers.sh` and `scripts/check-docs-drift.sh` run `rg ... || true`.
Before the first scan, each script must fail when `command -v rg` fails.
Each script must also fail when `rg --pcre2 -q 'a' <<<'a'` fails.
Keep the `|| true` only for the "no match" exit status 1. Fail on exit status 2.
Add a rejection probe: run each script with a `PATH` that holds a stub `rg` that exits 2, and require failure.

A17: the list's floor claim was false. The script reports 33 suites and the floor is 33.
Keep the floor. U17 raises it to 34 only if it wires `tests/validate/`.
Make a suite that reports zero passed tests fail, even when it also reports zero failures.
Prove the rule with a deliberately empty test file, because no current suite reports zero tests.

A19: route the fixed `"stand-in"` filter in `build/host_tests.zig` through the non-empty selection check in `build/Context.zig`.
A probe that renames the filter to a value that matches no test must fail the step.

Gates: `test-capability-audit`, `test-docs-drift`, `test-examples`, `test-standin`, `test-native-gates`.

### U2: expert proof cannot accept an incomplete analysis (A2)

In `packages/pi/src/aggregate_proof.zig`, `collectCheckDiagnostics` falls back to a `skip_contract` check when the full check returns an error.
When the fallback runs, append one synthetic diagnostic for that file.
Its code is `analysis_incomplete`, its severity is `error`, and its message is the full check's error name.
Its `file` is `common.relativeToRoot(materialized_root, handler_path)`, the same form that `appendCheckDiagnostics` uses.
`diagnosticEqual` compares `file` byte by byte, and the baseline and candidate have different materialized roots. An absolute path would never match.
The baseline and the candidate use the same function. A file that already failed full analysis in the baseline therefore matches, and only a new failure is rejected.
Keep the current behavior that returns the full error when the fallback yields zero diagnostics.

The fallback runs only on a contract-stage error. Front-end errors return normally.
The concrete trigger is `MissingSqlSchema`: a handler with SQL queries and no `sqlite` schema entry.
Add two tests through `prove`.
First: the baseline passes full analysis. The candidate fails it, and every fallback diagnostic is also in the baseline. Give both sides one shared non-halting front-end diagnostic so that the fallback is not empty.
The proof must reject, and the test must assert the code string `analysis_incomplete`. Before the fix, the same test must fail. Record that observation.
Second: both sides fail full analysis the same way. The proof must not reject for that reason alone.

Record this residual in the worklog: when the baseline already failed full analysis, a candidate is accepted on front-end diagnostics alone, because contract and flow analysis never ran on either side.
Also record that the synthetic entry reaches accepted diagnostics and receipts, and that no golden pins receipt diagnostics.

Gates: `test-expert-app`, `test-standin`.

### U3: stand-in evidence uses the production oracle (A3, then B9, which removes A4)

The defect-seed and guard tests call `veto.runVeto` and `veto.runVetoWithSchema`. Production calls `aggregate_proof.prove`.
Move each call site in `standin_range_tests.zig`, `standin_tests.zig`, `transcript.zig`, and `mlx_e2e_test.zig` to `aggregate_proof.prove` or a thin test helper over it.
The seeded-arm tests in `standin_tests.zig` already reach `prove` through `loop.runTurnWith`. The per-seed class test in `standin_range_tests.zig` is the main move.
Keep every assertion about the observed rule code and verdict class.
The seed test "every defect seed reproduces its declared veto class through the real veto" must still observe every seed.

Map each `runVeto` behavior as follows:
- SQL guidance mapping: production never reaches it. Drop it.
- Salvage on reject: `prove` always normalizes candidates. Observe the salvage as a changed `prepared.changes[0].candidate` and a non-empty `rewrite_trace`, as `loop.zig` does.
- A null baseline: use a workspace with no `handler.ts`, which `change_set` marks `.absent`.
- The count of new diagnostics: `prove` returns only the first new code. Keep the direct `edit_simulate.simulate` call where a test needs the count.
- Policy seeds: write `zttp.json` and `policy.json` into the workspace, as `runSeedArm` does.
- The `transcript.zig` proof-card test renders a veto `ui_payload` that production does not build. Rewrite it over what the loop emits, or delete it and record that in the worklog.

When the veto's salvage path is the only difference for a case, record that case in the worklog. Do not change its expectation silently.
Then delete `packages/pi/src/veto.zig`, its import in `tests.zig`, and the README line.
Correct the two solution notes that cite `veto.runVeto`: `difference-is-not-the-claim-and-a-probe-must-compile.md` and `empty-baseline-made-a-file-destroying-edit-prove-clean.md`.
Confirm that the defect-seed coverage gate inside `test-standin` still counts every advertised rule.

Gates: `test-standin`, `test-expert-app`, and `zig build test-expert-mlx-e2e` with no MLX server present. The last one shows that the file compiles. It does not show model behavior.

### U4: analyzer latent fail-open shapes (A7, A8, A9, A15)

A7: the `FlowChecker.properties` default becomes the existing `unproven` constant. A test reads `getProperties()` before `check()` and expects every property false.

A8: in `contract_json_parser.zig`, add a comptime assertion that `PropertiesWire` and `HandlerProperties` have the same field set.
The wire fields are camelCase and the type fields are snake_case. Compare through the existing `snakeToCamel` conversion. Do not change wire names or order.
Prove the assertion with a probe: add a field to `HandlerProperties` on a scratch copy and confirm the build fails.

A9: `contract_diff.propertyLossSeverity` maps names with a string table that defaults to `.info`.
No `.breaking` severity exists. Return `?Severity`, and map null to `.critical` at the `pr_gate.zig` and `upgrade_verifier.zig` call sites.
Keep `pure` and `stateless` as explicit `.info` entries.
Add a comptime check that every bool field of `HandlerProperties` has an explicit entry. `max_io_depth` is not a bool and is excluded.
Callers pass comptime field names, so no golden changes. Preserve the severity of every existing name.

A15: the parser refuses 256 nested blocks with ZTS044, which is below the `proof_ir.max_depth` of 512.
No program that the parser admits reaches the bound in `lower`, so the deep-nesting test runs nothing.
Delete that test. Add a comptime check that the parser's block nesting bound is at or below `proof_ir.max_depth`.
Keep one test that builds an IR deeper than `max_depth` without the parser, if `lower` accepts such an IR. Otherwise record that the bound is unreachable.

Gates: `test-zts`, `test-contract-golden`, `test-proof-review`.

### U5: success results carry complete output (A5, A6, A14)

A5: `zts_cli.zig` writes the JSON envelope with `catch {}` and ignores the `std.c.write` result. Propagate both errors so that the command exits non-zero.

A6: `module_graph_record.zig` ignores a parser-init failure and a parse failure.
Record a parse failure as a `Rejection{specifier, importer, reason}` entry with a new reason constant.
`computeHash` hashes modules only. Extend it to append each rejection entry after the modules.
An empty rejection list appends nothing, so every existing hash stays the same. Record that no golden pins `module_graph_hash`.
Return OOM as an error. Add a test that the hash differs when a parse failure is present.

A14: in `precompile.zig`, a `writeJsonl` failure and a proof-trace serialization failure must fail the operation, not produce a partial success.

Gates: `test-zts-cli`, `test-cli-abuse`, `test-module-graph-record`, `test-agent-protocol`, `test-agent-determinism`, `test-precompile`, `test-contract-golden`.

### U6: proof-swallow gate scope (A11)

Add `path_generator.zig`, `pipeline.zig`, `proof_ir.zig`, and `translation_witness.zig` to the file list in `scripts/check-proof-swallow.sh`.
Add one row to `scripts/proof-swallow.allow` for each discarded error, with the reason that it cannot weaken a verdict.
A site that can weaken a verdict is not allowlisted. Report it and fix it in this unit.
Update the file count in `AGENTS.md` and anywhere `check-docs-drift.sh` reads it.

Gates: `test-proof-swallow`, `test-docs-drift`.

### U7: owner decisions 2 and 3 (A20, A21)

A20 (decision 2A): the debug panic hook exists only when `builtin.mode` is `.Debug` or `.ReleaseSafe`.
In ReleaseFast and ReleaseSmall builds, `--_debug-panic-path` is refused with a clear error, and `ZTTP_DEBUG_PANIC_PATH` is ignored.
Gate all three sites: the environment read in `runtime_cli.zig`, the `std.c.getenv` fallback in `runtime_pool.zig`, and the config copy in `server.zig`.
`server_test.zig` also uses the flag and runs in Debug.
`test-panic-isolation` and `test-module-scope-panic` use the default Debug install and must still pass.
Add a test that the ReleaseFast configuration refuses the flag, using a comptime-selected helper.

A21 (decision 3A): `workspace_read_file` refuses a path that is ignored.
Run `git check-ignore -v -- <relative path>` in the workspace root through the existing `common.runCommand`.
Exit status 0 means ignored: refuse, and name the matching pattern and its source. Exit status 1 means not ignored: read.
Any other result, including a workspace that is not a git repository, applies a fixed deny list: `.env`, `.env.*`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`.
The refusal message does not include file content.
`common.runCommand` runs with an empty environment and no `HOME`, so global git excludes do not apply. State this in the tool's doc comment.
A workspace nested inside a parent repository that ignores it reads every file as ignored. State this too.

Tests must use `IsolatedTmp` from `test_support/tmp.zig`. A `std.testing.tmpDir` workspace sits inside the ignored `.zig-cache`, so every path would read as ignored.
Add tests for an ignored `.env` in a `git init` workspace, a tracked file in the same workspace, and a non-git workspace.

Gates: `test-cli`, `test-server`, `test-panic-isolation`, `test-module-scope-panic`, `test-expert-app`.

### U8: documentation and plan archive (D1 to D8, decision 5A)

D1: correct the statements that a filtered run with zero tests exits 0. They are in `AGENTS.md`, `CONCEPTS.md`, `docs/internals/testing.md`, and two solution notes. Keep the rule "never cite a filtered run".
D2: replace the Python counts in `AGENTS.md` with the measured value, zero. Keep the "No Python" rule.
D3: make the proof-swallow file count consistent (after U6).
D4: the "Measured" column is constant because no `agents.json` gate carries a measurement. The generator can print seconds.
Render the column only when at least one gate carries a measurement. Regenerate with `zig build check-spine -- --write`.
D6: remove the removed build flags from `.claude/skills/zttp-build/SKILL.md`.
D7: reduce the incident narrative in `AGENTS.md` Testing Guidelines to each rule and a link to its `docs/solutions/` note. Keep the allowlist row-count claim that `check-docs-drift.sh` reads.
D8: correct the stale comments listed in the round 2 list.

Decision 5A: create the local tag `pre-round-2-archive` at the commit before the deletion.
Delete each completed plan and worklog in `docs/plans/` that no tracked file outside `docs/plans/` cites.
Keep the P2 to P7 specifications and the disposition ledger, which H6 names as authority. They also have no outside citation.
Also delete `advisor-plans/004-shared-analysis-first-unit.md`, which was promoted. Change its row in `advisor-plans/README.md` to a tag path, as rows 001 and 002 already are.
Update `docs/plans/README.md` to list every remaining file, and record each deleted file and the tag in the worklog.

Gates: `test-doc-links`, `test-docs-drift`, `check-spine`, `test-spine`.

## Round 2b: dead code

Each unit deletes code whose callers the audit checked.
Each unit repeats the `git grep -w` check before it deletes code.

### U9: engine leftovers (B2, B3, B5, B7, A16)

Delete `CodeVersion`, `VersionedFunction`, and `HotReloadManager` and their tests in `bytecode.zig`.
Delete `FunctionBytecodeCompact`, its re-export in `root.zig`, `BytecodeCache.put` and `get`, and their tests.
Keep `BytecodeHeader` and `MAGIC`. Nested functions serialize `FunctionBytecode` through `serializeFunctionBytecode`, so the format does not depend on the deleted struct. Correct the stale `nested_function` comment.
Delete the JIT leftovers: `guard_id_counter`, `nextGuardId`, `profileBackedge`, `recordDeopt`, `tier_count`, `LOOP_THRESHOLD`, and `FUNC_GUARD_ID`, plus the dead parts of `interpreter/perf.zig`.
Keep `backedge_count`, which the deadline check reads. No code reads an inline slot by position.
Delete `serializeBytecodeWithAtoms`, `deserializeBytecodeWithAtoms`, and their test.
B8 is dropped: every public function in `packages/zts/src/sqlite.zig` has a caller.
A16: make the `performance.now` origin initialization in `builtins/date.zig` thread-safe with `std.once` or an atomic.

Gates: `test-zts`, `test-zruntime`, `test-precompile`, `test-meta-drift`.

### U10: deploy renderers (B1)

Delete the AWS and Cloudflare renderers, `DeployTarget`, `RenderOutput`, `costWorstCaseTotal`, `writeDeployReport`, their private helpers, and their tests in `deploy_manifest.zig`.
After the renderers go, measure which `ProvenFacts` fields no code reads. The validation found five: `cost_total`, `fetch_hosts`, `rate_limit_namespace`, `cost_worst_case_total`, and `cost_worst_case_body_limit`.
Delete only the fields that the measurement confirms, and their extraction.
Keep `extractProvenFacts`, `ProvenFacts`, `ProvenRoute`, and `default_cost_body_limit`. Their readers are `proof-review/src/review.zig`, `live_reload.zig`, and `build_command.zig`.
Correct the header comment.

Gates: `test-deploy-manifest`, `test-proof-review`, `test-cli`, `smoke-v1`.

### U11: synchronous GC paths (B4)

Delete `simdSweep`, `scalarSweep`, `GCConfig.simd_sweep`, `allocWithGC`, the root-tracking wrappers, and the unused `RootSet` members.
Replace test uses of `majorGC` with a test helper that runs `runIncrementalGCStep` until the phase is idle. Then delete `majorGC` and `majorGCWithHeap`.
Run `bench-check` before and after, and record both results.

Gates: `test-zts`, `test-zruntime`, `bench-check`.

### U12: legacy module export conversion (B6)

Delete `toModuleExport`, `toModuleExports`, the `ModuleExport` type in `modules/internal/resolver.zig`, and the six unread `exports` constants under `packages/zts/src/modules/`.
Keep the rest of the resolver. `resolve`, `registerVirtualModule*`, and `validateImports` are live in `pipeline.zig`, `precompile.zig`, and `module_graph_record.zig`.
Rewrite the `module_func` wrapping assertion to use `getNativeFn`.
Do not touch the unrelated `ModuleExport` in `flow_interp.zig`.

Gates: `test-zts`, `test-modules`, `test-sdk`, `test-module-governance`, `test-contract-golden`.

### U13: pi dead code (B10, B11)

Delete `proof_enrichment.analyzePatch` and the helpers that only it uses.
Keep `buildUnifiedDiff`, `loadProveSummaryForPatch`, `formatProveSummary`, `propertiesSnapshot`, and `resolveHandlerPath`.
Delete `capturePost` and its types, `witness_key.zig`, `decodeResponseFromRequestDigest`, `Destination.isLocal`, `sessionDirForWorkspace`, `invokeFromCwd`, and `countFailingCode`, with their tests.

Gates: `test-expert-app`, `test-cassette`, `test-recorder-smoke`, `test-simulator`.

### U14: frontend dead code (B12, B13, B16)

Delete the printer `parsed_store` input, `collectDirectRegions`, and their tests. `printer.print` calls `printInput`, so inline the `original_source` path into `print`.
Delete the test-only primitive-annotation API in `parser/type_syntax.zig` and its tests. Keep `Failure`.
Delete `AsiCensus`, its counters, and `tests/asi_census.zig`. Keep `allow_asi`.
Remove the `tests/asi_census.zig` row from `scripts/zts-tiers.allow` and the path citation in `flow_precision_expectations.zig`. The layering gate fails on a tree mismatch.

Gates: `test-zts`, `test-canonicalize`, `test-diagnostic-corpus`.

### U15: flow migration scaffolding (B14, B15)

The harness's unique checks are `unresolved == 0` and `source_errors == 0` over the frozen corpus.
The tools test root imports only `zts` and `zts_cli`, and `FlowChecker` exposes no unresolved count. Work in this order:
1. Add one accessor for the unresolved count to `FlowChecker`, reachable through `zts`.
2. Add both floors to a precision test that `test-precompile` runs.
3. Prove each floor with a probe that adds one unresolved construct and one source error.
4. Delete `flow_shadow_diff.zig`, `flow_shadow_inputs.zig`, the build wiring, the `zts-compiler` import that only the shadow uses, both `agents.json` tasks, the `manual-steps.allow` row, the gate-table rows, and the stale `testing.md` paragraph.

Keep `flow_false_proofs.zig` and `flow_precision_expectations.zig`.
Delete the `FlowChecker` test-only export API with the `ensureHealthy` call inside it, the retired phase scaffolding, and `tagVisits`. The `ensureHealthy` call in `check()` stays.
Rename `Owner.p7` and `Owner.p8` to names of their mechanisms. Only the shadow and one test print print these names.

Gates: `test-zts`, `test-precompile`, `test-flow-census`, `test-step-coverage`, `test-script-reachability`, `check-spine`, `test-docs-drift`.

### U16: tools and runtime leftovers (B17, decision 4A)

Delete `runCheckOnly`. Keep `runCheckOnlyFromSource`.
Delete the nine unused alias imports in `server.zig`. Keep the traversal checks in `server_static.zig`.
`server_static.isCanonicalPathInsideRoot` has no caller anywhere. Do not delete it in this unit. Report it to the owner as a defense check that nothing runs.
Delete the unreachable `--outbound-http` and `--outbound-host` branches and the duplicate `--force-swap` entry in `runtime_cli.zig`.
Delete the dead test helpers in `build_command.zig` and `zruntime_tests.zig`. Name each helper and its caller check in the worklog.
For the unread request count and captured path of the test server in `zruntime_tests.zig`, add an assertion where a test needs it, or delete them. Record the choice.

Gates: `test-precompile`, `test-zts-cli`, `test-server`, `test-zruntime`, `test-cli`, `smoke-v1`.

### U17: empty allowlist and orphan fixtures (B18, B19)

Delete `scripts/flow-census.allow` and its parser in `flow_census_gate.zig`. Any census mismatch must still fail. Prove this with one mismatch probe.
Correct the references in `docs/internals/testing.md` and the header of `build/flow_census.zig`.
Wire `tests/validate/` into `scripts/test-examples.sh` with one `run_tests_with_args` line if its fixtures pass, and raise the suite floor to 34.
If they do not pass, delete the fixtures and correct `CONTRIBUTING.md` and `docs/internals/capabilities.md`.

Gates: `test-flow-census`, `test-examples`, `test-doc-links`, `test-script-reachability`.

## Delivery

Units run in order U1 to U17. A Sonnet subagent implements each unit from this plan and the line-numbered list.
The main session reviews each diff, runs the unit's gates, and commits.
After U8 and after U17, run `zig build test`, `zig build check-spine`, `git diff --check`, and `bash scripts/verify.sh`.
Record the commands, exit statuses, and measured line deltas in the worklog `2026-10-21-pruning-round-2-worklog.md`.

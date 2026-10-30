# Reset worklog, 2026-10-30

This worklog records the execution of the [reset plan](2026-10-30-reset-implementation-plan.md).
The plan is the authority. This file holds evidence, rulings, and deviations.

## Owner decisions

The owner selected the recommended option for each decision on 2026-10-30.

| Decision | Selection | Effect on this run |
|---|---|---|
| 1. Scope | (a) | Phases 0 to 8, 10, and 11 run. Phase 9 units run as Decisions 2, 4, and 5 select |
| 2. Cost fuse | (a) | The code stays. Unit 1b corrects the document. Unit 9g does not run |
| 3. Second checker | (a) | Unit 6b runs |
| 4. One language path | (a) | Unit 9b runs |
| 5. Other class B units | (a) | Each unit that keeps the offline replay green runs. Any other unit waits for a re-record window |
| 6. Archive tags | (a) | The owner pushes the four tags. This run does not push |

The run commits on local `main`, as the owner's standing instructions require. No push or pull request is part of this run.

## Baseline

Base commit: `617243e376beefc439fca4b229a86fe8d2a0b2ba`. Base tree: `aef49967c2b42c03e23451198c2a13e9502acccd`.

## Phase 0

Status: complete at base `617243e3`. The base differs from `1d009062` only by the plan document, so Appendix A and Appendix B stand unchanged. A repeat of the Appendix B command gave 214 sites.

| Step | Result |
|---|---|
| Clean tree | `git status --porcelain` printed nothing on local `main` |
| `bash scripts/verify.sh` | Exit 0 in 1,097 seconds, load average 2.90 at the start |
| `zig build test` | Exit 0 from the warm verify cache; 211 of 211 steps |
| `digest.sh` | Two runs exit 0 and compared equal. `zts check` gave 73 at exit 0 and 142 at exit 1. `zts compile` gave 98 at exit 0 and 117 at exit 1 |
| Surface digests | 38 rows, all exit 0, two runs equal |
| Admission probe table | 80 rows, two runs equal |
| Serve flag cases | 4 rows in the probe table, two runs equal |
| `proof-swallow.allow` | 0 rows for `flow_interp.zig` |

The scratch directory `/private/tmp/claude-501/zttp-reset-20261030` holds `digest.sh`, `surface.sh`, `probe.sh`, and their Phase 0 tables.
The test count of the aggregate is 8492 of 8498 with 6 skipped, from the cold run at `1d009062`. A warm run reports only the steps that ran, so a count comparison needs a cold run.

Probe deviations. The plan asked for one source per form of `AdmissionFailure`. The table holds 19 sources: the 17 `AdmissionKind` forms, a leading comment, and a trailing comment. The forms drop the `import type` prefix of the module graph test, because that prefix makes every raw message the same. Without the prefix `legacy_types_import` starts and answers HTTP 200, so that probe is not a refusal case. The trailing comment form uses an untyped helper, because the raw parser cannot read a typed one. Stderr hashes drop stack trace lines, which carry addresses.

Observed defect rows, with `zts check` at exit 1 for each:

| Source | `serve` result |
|---|---|
| Imported file with a trailing `/* open` | Starts, HTTP 200, body `ok` |
| Imported file with a leading `/* open` | Starts, HTTP 500 |
| Entry file with a trailing `/* open` | Refused |

`nesting_too_deep` now has a source that triggers it: the source from the module graph test.

Appendix B classification: 163 sites are in `test` blocks and 51 are in other functions. Phase 3 classifies the 51 by reading. The production feeders are `run` in `zts_expert_effects.zig`, the load path in `handler_instance.zig`, `renderParseRefusal`, `collectImports`, `runCheckOnParsedSource`, `runGenTests`, `compileHandler`, `compile` and `compileWithOptions`, `extractVirtualContract`, and the parse in `module_graph.zig`.

The advisory `bench-check` did not run. It cannot fail this phase.

## Phase 1

Status: complete at `7e740d75`. Units 1a and 1b are `964d8e9e` and `7e740d75`. `test-doc-links`, `test-docs-drift`, `check-spine`, and `zig build test` each exited 0.
The roadmap section "Reset And Simplification" became a short list. It dropped run measurements and owner quotes that remain only in the tagged worklogs: test counts, "all 13 named checks", and the 186-line growth figure.

## Phase 2

Units 2a and 2b ran in worktrees cut from local `main` at `7e740d75`. Each unit passed its gates on `main` after the cherry-pick: protection check, build, `digest.sh`, each named step, `zig build test`, and `check-spine`.

Unit 2b: `e62a6b28` and `0ed9420f`. 16 of 17 rows are deleted, plus the Appendix A2 items for `autoloop.zig`, `DynamicHeaderOrder`, `ReplayKind`, `TurnEvent.user_approved`, and `project_context.Options`.
Ruling: `setProviderStallTimeout` stays, because `expert_codegen_record.zig` calls it in the recorder path. The census missed that use because the recorder runs inside a gated `test` block, which the census removes.
Ruling: `session_events.AutoloopVerdict.cancelled` stays, because stored journals can carry it.
Ruling: the `zruntime_tests.zig` cached-teardown fixture gains one trivial `handler` function, because its only entry point, `loadCodeWithCachingNoHandler`, is gone. Its assertions do not change.

Unit 2a: `8d9bb6ff` and `fbcccd73`. 18 of 22 rows are deleted. The analyzer and tools commits are squashed into `fbcccd73`, because the analyzer commit alone did not build `tools`.
Ruling: four rows stay as test lookups, because moving each into its tests adds code and removes no production path: `findType`, `findByFeature`, `knownValue`, and `planApplicationBases`.
`result_globals` has one list in `handler_verifier.zig`. The test in `proof_ir.zig` still compares that list with the registry count.

Unit 2c: the helper `expectFunctionSliceRuntimeParity` is now `expectParsedStoreValid`, and its 61 call sites follow. `buildContractOnlyFromParsed` and `FlowWithoutHandler` are gone.
10 of the 11 callers of `buildTestContractForSource` reach `initSoundExtraction` with `.strict = false`, and no expected value moved. The default `strict` mode refuses their fixtures.
Ruling: the eleventh caller, "contract-only extraction without source types preserves verifier properties", calls `initContractOnly` directly, because its source holds `if (5)`, which sound extraction refuses. `buildMultiModuleContract` uses that same profile in production.
Opus also removed `ContractOnlyOptions.select_flow` and `env_public`, which had no production reader. The one test that set them moved to `initSoundExtraction`, with no change to its assertions.

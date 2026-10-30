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

## Phase 3

Status: complete. Units 3a, 3b, and 3c moved every test site in Appendix B to the production parse mode. No expected value moved, no source changed, and no verdict changed. Admission accepted every test source as written, including untyped parameters. The `test "` count of each file stayed equal.

Unit 3a moved 55 sites in `effect_inference.zig`. Unit 3b moved 47 sites in `flow_checker_tests.zig`: the plan counted 46 lines that a text search matched, and the worker counted one more call site. Unit 3c moved the sites of 23 files in one commit per file, and Opus moved the 12 wrapper sites in `interpreter.zig` and `interpreter/trace.zig`.

Ruling: the wrapper `Parser` from `parser/root.zig` reaches admission through `initTyped`, `parseTypedIr`, and `generateParsed`, so those 12 sites moved through a local test helper. No production code changed.
Ruling: `parser.parse()` is the idiom after `initAdmission`, as `pipeline_tests.zig` shows. It delegates to `parseAdmission` and turns a refusal into an error, so a refused source fails the test.

Sites that stay raw in this phase, and the unit that closes each:

| Site | Closed by |
|---|---|
| `compile` in `compiler.zig` | Stays: D-016 names it for semantics corpus fragments |
| `compileWithOptions`, `extractVirtualContract`, `module_graph.zig`, `collectImports`, `renderParseRefusal`, `run` in `zts_expert_effects.zig`, `compileHandler`, `runGenTests`, `runCheckOnParsedSource`, the load path in `handler_instance.zig` | Unit 9b |
| 4 sites in `tests/frontend_fuzz.zig` | Stay: the file fuzzes the raw parser on purpose, and it already has an admission arm |
| Raw tests in `parser/parse.zig` | Unit 9b |

## Phase 4

Status: complete. Unit 4a removed `parse_type_syntax`. The worker replaced 11 reads with `self.admission != null`, removed 34 constant checks, and kept the 2 reachable checks in `selectFunctionGeneric`: `spaced_call_list` and `typed_header`. Opus removed two more redundant checks in review.
The swap is equivalent by reading. `init` and `initExpression` pass no mode. `initAdmission` and `initSourceObserver` pass a mode. `replaySourceAdmission` moves the admission state from the observer to the live parser and then drops the observer.
Ruling: `isPrivateGenericListEligible` stays, because `type_syntax_parser.zig` still calls it.
Ruling: `type_only_module_exclusion` has no assignment left in production. Its removal also removes `error.TypeOnlyModuleLexicallyExcluded` from two fuzz lists, so it goes to unit 9b and not to this unit.
Gates on the working tree before the commit, each exit 0: protection check, build, `digest.sh`, `probe.sh`, `test-zts`, `test-diagnostic-corpus`, `test-contract-golden`, `test-grammar-drift`, `test-meta-drift`, `test-zruntime`, `test-examples`, `test-proof-checker`, `test-proof-swallow`, `zig build test`, and `check-spine`.

## Phase 5

Status: complete at `60eec7d3`. `applyContractFacts` in `precompile_check_run.zig` is the one writer of the 12 contract fields. Each driver fills `ContractFacts` from its own analysis. `compileHandler` keeps its generator and does not call `analyzeHandlerPaths`.
The function runs twice per driver, because each driver has a pass between the verifier facts and the path facts: `refreshContractSpecDiagnostics` in compile and `syncCheckResultProperties` in CHECK. The order stays the same.
Compile used to assign `cost_envelope` when it was null, and CHECK did not. The shared function assigns only a value. Both are the same today, because extraction never sets that field.
`unreachable_code` stays a value that each driver supplies, until unit 9c.
Gates on `main`, each exit 0: protection check, `digest.sh`, `test-precompile`, `test-contract-golden`, `test-agent-protocol`, `test-proof-swallow`, `test-flow-census`, `test-zts`, `test-diagnostic-corpus`, `test-cli`, `test-zruntime`, `test-expert-app`, `zig build test`, and `check-spine`.

## Phase 6

Unit 6a: `8ea63aeb`. `identityFromRuntimeContract` in `artifact_graph.zig` replaces the three copies. Opus made this unit directly, because it is a 13-line function and three call sites. `identityFromContract` stays, because `HandlerContract` is a different type.

Unit 6b: `cf892b54`. The `type_check` option is now the `module_scan` hook, which takes the IR view. `extractCustomResult` and the second type environment are gone. The hook runs after the sound-mode refusal and before the type check, so the order of startup refusals does not change.
Ruling: "source graph uses compiled direct entry types and omits dependency types" read the type environment through the old callback, and the plan's list of kept assertions did not name that test. The hook cannot see the environment, and the contract of that fixture shows no difference between the two source selections. The test keeps its module counts and its read count. A new test, "extractContract applies entry types in a module graph", asserts the entry half through public behavior. "extractContract keeps dependency annotations outside entry typing" already asserted the dependency half.
Three mutants measured this. A dependency on direct types fails only the dependency test. A graph entry on omitted types fails only the new test, so that mutant would have survived without it. The scan before resolution fails only the new test in `runtime_cli.zig`.
Ruling: the two assertions that compared `contract_checker` with the resolved checker went, because they asserted the removed checker. The `Callback` test lost its two assertions on the checker inside the hook, for the same reason.

Unit 6c: `18471824`. `parseServeArgs` returns a `ServeRequest`, and `parseServeFeatureFlags` is gone. An ordinary `serve` start loads `zttp.json` once.
Ruling: the plan assumed that the discovered config can pass down unchanged. Reading showed that `parseServeArgs` and the old policy lookup can anchor at different paths, so a nearer `zttp.json` could supply the policy. `configuredPolicy` keeps that result: it reuses the project only when the project is the nearest manifest of the handler. This added `nearestManifestPath` to `project_config.zig`, a file that the plan did not list.
Ruling: `buildWatchSet` keeps its own discovery, because it runs only with `--watch`.
Behavior change, disclosed: in the `zttp` binary, a flag token in a value position no longer sets the flag, which is the defect that N12 names. Seven cases ran on the `1d009062` binary and on the new binary. Six gave the same result. `zttp serve handler.ts --sqlite --watch` used to start watch mode and now serves without it. The `--eval --watch` and `--eval --prove` cases have equal stderr. The four Phase 0 rows and the probe table did not change.

Unit 6d: `expert_flags` in `app.zig` is the one table of the 18 expert flags, and `lookupExpertFlag` reads it for both parsers. The switch in `parseExpertFlags` has no `else`, so a new tag fails the build until it has an arm. No expected value moved. The surface digests equal Phase 0.

Gates on the working tree before each commit, each exit 0: protection check, build, `digest.sh`, the steps of each unit in the plan's gate table, `zig build test`, and `check-spine`. Units 6b, 6c, and 6d also ran `surface.sh`. Units 6b and 6c also ran `probe.sh`.

## Phase 7

Status: complete. Each unit is motion only. The reviewer compared the sets of lines before and after each split, ignoring indentation. Each difference is a `pub`, an import or alias, a file header, a moved signature, or a call site.

Gate references found before each unit: `check-runtime-purity.sh` for `server.zig`; `check-proof-swallow.sh` and `zts-tiers.allow` for `flow_interp.zig`; no hit for `agent.zig`; two sites in `tooling/release_check.zig` for `build_command.zig`.

Unit 7a: `bfdd2a02`. `server_activation.zig` holds the pre-pool activation block and the swap refusal. `Server.start` calls `activation.activate`. The purity gate scans the new file, and a copy with a direct `zts` import exits 1 and names the file.
Ruling: the attestation-header block in `start` stays, because it runs after pool creation. Moving it needs a second activation call.

Unit 7b: `38985ea8` and `efa9a7d3`. `flow_value.zig` holds the value model and `flow_rules.zig` holds the rule tables. `FlowInterp` stays whole. The swallow gate now lists 34 files and reports 0 unreviewed. A discarded error in either new file exits 1 and names the file. `scripts/proof-swallow.allow` did not change.
Ruling: three anchors in `docs/solutions` moved with their symbols, because `check-spine` refused the old paths.

Unit 7c: `ca14c591`. `agent_bootstrap.zig`, `agent_compaction.zig`, `agent_admission.zig`, and `agent_fork.zig` hold the four blocks. Every moved declaration was already a free function or a type, so no method changed form. `agent.zig` binds the moved names through private aliases, so its 64 tests did not change.
The bootstrap block is 541 lines and not the 321 lines of N15, because the cut is contiguous and takes the receipt helpers with it. `mlx_e2e_test.zig` compiles, which a run with a filter that selects no test confirmed without a model call.

Unit 7d: this commit. `compile_command.zig` and `deploy_command.zig` hold their commands, and `dev_cli.zig` calls them there.
Ruling: the shared artifact pipeline, about 1,000 production lines, stays in `build_command.zig`, because all three commands use it and the plan names three files. A fourth file is possible later.
Ruling: `--no-attest` stays in `build_command.zig`, so `tooling/release_check.zig` reads the same fact from the same file. A copy with that text changed makes the `proof_surface` row of the passport fail.

Gates on the working tree before each commit, each exit 0: protection check, build, `digest.sh`, the steps of each unit in the plan's gate table, `test-module-boundary`, `zig build test`, and `check-spine`. Unit 7d also ran `surface.sh` and `test-release-check`.

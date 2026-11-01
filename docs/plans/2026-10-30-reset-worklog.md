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

## Phase 8

Unit 8a: `75e43452`. The plan's action, a build-time read of `ZTTP_EVIDENCE_PUBLISH`, cannot work. Zig 0.17 caches the configuration, and a hit skips `build.zig`, so the build never sees the variable. The worker measured this: the replay ran only with `--cache-poison=poisoned`. Its fix called `poisonCache`, which disables the configuration cache for every build in the repository, so Opus replaced it.
Ruling: the option `-Devidence-publish=true` reruns the replay and sets the variable on that run step. `scripts/update-convergence.sh` and `scripts/update-coverage.sh` pass it, and these two files were not in the plan's list. An ordinary build keeps both caches.
Probe in a clone with a warm replay: `update-convergence.sh` exit 0, then `update-coverage.sh` exit 0. Control, by the worker at `1ce0c89c`: the same script on the same warm cache exit 1 with `MissingOrDuplicateMarker`.

Unit 8b: this commit. `bytecode_identity_golden.zig` is the `main` of the `test-bytecode-identity` gate, with `has_side_effects = true`, and the aggregate runs it once. `bytecode_identity_golden.txt` did not change. Write mode regenerated a byte-identical golden through the new step.
Three warm-cache probes in a clone each exit 1: a changed handler, a changed import of a handler, and a new handler. Each prints `bytecode identity drift`.
The aggregate test count falls, because 5 collected copies became one gate. A warm run prints no total, so Phase 11 states the count from a cold run.

## Phase 9

Unit 9a (CLI text corrections): `2d461822`. The surface digest moved for two rows only, `zttp-runtime --help` and `zttp expert --help`. Opus made the unit directly, because each correction is one line.
A probe found that the scaffolded extension handler failed `zts compile` with ZTS601. The template now annotates its handler, and `scripts/smoke-v1.sh` compiles the scaffold. `zts compile` exits 0 and prints warning ZTS401, because the scaffold returns a credential in its response. That warning is left as is.

Unit 9c (`unreachable_code` in CHECK): `242f6b52`. The new test failed without the fix on the `verification.unreachable_code` assertion. The digest did not move, and offline replay passed. Opus made the unit directly.

Unit 9d (fetch summary): deferred under Decision 5. The edit passed `test-modules` and `test-docs-drift`. It failed `test-meta-drift` with `builtin_registry_hash` moved, `test-expert-golden` on `zts meta --json`, and `test-expert-app` with 11 cassettes that need a re-record. The cassettes are `health`, `validate-body`, `jwt-auth`, `weather-egress`, `sql-users`, `log-timestamp`, `cache-counter`, `egress-options`, `sibling-helper`, `egress-options-holes`, and `sibling-helper-holes`.
The plan expected that a failure here would be possible. The edit is reverted, and the roadmap carries the row. No recorder ran.

Unit 9b (one language path, Decision 4): this commit. Sonnet implemented, and Opus reviewed the diff line by line. The new test failed without the fix: `expected error.UnterminatedComment, found void` at the `expectError` call, because the graph returned success.
Ruling: the plan names three raw entries. A fourth stays: the raw arm in `loadCodeWithCachingInternal` serves `HandlerSource.inline_code`, which the embedding API documents, and that API is in the protection boundary. D-016 names all four. The `parse.zig` raw tests stay, because they test the entries that stay.
Probe table: 18 of 80 rows moved, each a `<form>/lib` row, and no entry row moved. `unterminated_comment_trailing/lib` was HTTP 200 and `unterminated_comment_leading/lib` was HTTP 500; both now exit 1. The other 16 rows stay exit 1 and now print the admission line in place of a second, less exact message. `legacy_types_import/lib` did not move, because the Phase 0 probe wrote literal Zig text as the specifier, so that row never tested the form. A separate run with `zttp:types` as the specifier refuses at start with the admission line after this unit.
The `-e` table: `any-type`, `comment-trailing`, `comment-leading`, `string-open`, `interface`, `mutable-export`, and `as-cast` now print the admission line and exit 1 with no leak trace.
Review fixes by Opus: `formatAdmissionRefusal` moved to `source_frontend.zig` with a typed parameter, and the graph prints it; two bare blocks dedented; `admitToolSource` returns `void`; a test keeps the typed-to-raw bytecode comparison that the worker dropped with `compileWithOptions`.
Gates, exit 0 unless stated: protection check, `digest.sh`, `surface.sh`, `test-zts`, `test-precompile`, `test-agent-protocol`, `test-module-graph-record`, `test-cli`, `test-zruntime`, `test-server`, `test-expert-app`, `test-diagnostic-corpus`, `test-spine`, `test-proof-swallow`, `test-module-boundary`, `check-semantics-spec.sh`, `zig build test`, `check-spine`. `probe.sh` exits 1 by design, because the moved rows are the accepted rows.
Residual: a parser refusal that is not an admission refusal, such as `const x = ;`, still prints a raw `error: UnexpectedToken`. In a Debug build it also prints a leak trace. The behavior is older than this unit and is the same for a `.ts` entry.

## Phase 10

Legacy removal L0 to L9 ran before this phase, as Decision 13 of that plan selects. It took over units 9e and 9f. Unit 9d stays deferred, and unit 9g did not run.

### 10a. Architecture

`docs/internals/architecture.md` gains the table "Owner of each fact" and the section "Serve Request". It now states the D-016 entries, the 42 `NodeTag` members, the `responses` field, and the `applyContractFacts` writes. Two statements about a custom type checker were false after unit 6b, and the `module_scan` hook replaces them. No row of the target design is deferred.

I checked the facts that the worker could not confirm. `parse.zig` has three `JsParser` constructors, so two untyped entries remain. `applyContractFacts` writes 12 fields, and each driver calls it twice. `buildWatchSet` runs only in the `--watch` branch of the CLI.

The worker changed "the source profiles" to "the core source profile" in `CONCEPTS.md`. `artifact_graph.zig` holds one profile, so I made the same change in `docs/threat-model.md` and `docs/verification.md`.

### 10c. Spec name

The spec is now `docs/spec/zts-model-1.md`, and the eight files outside the plans use the new path. The old name remains only in six dated plans and one file in `advisor-plans/`. The site does not name it.

The title and the relationship line lost "northstar". "Grounded against" stays, because `zts meta --json` reports compiler 0.19.0 and policy 2026.04.2, and no source gives a later grounding date. Section 17 and the archive paths keep the word as history. I replaced the word in the `docs/README.md` description and in the comment in `semantics.zig`.

### 10d. Public forms, variables, and strategy

All eight variables and all eight forms exist. `docs/internals/testing.md` holds a new table of the eight variables, and `docs/cli.md` holds the eight forms. `main` in `tooling/verify.zig` is the stated owner of the `-j1` rule.

The hand-off text was in `docs/plans/2026-10-29-v0.26.0-w-handoff.md`. `CLAUDE.md` did not say how to read the `.value` of `requestJson`, so it gains one sentence. The worker ran `zts check` on both forms: a member read reports ZTS201, and `isDict(v)` with `dictGet` passes.

`STRATEGY.md` has `last_updated: 2026-10-31`. One sentence left: "The current registry and corpus counts need measurement after the Phase 3 removal." Its direction, goals, and priorities did not change. Two of its claims stay untested: the grade of validator repair intents, and "milliseconds".

Two review fixes by Opus:

| Worker text | Measured | Fix |
|---|---|---|
| Replaced `zttp proofs` with `zttp proofs list` | `parseCommand` maps no argument to `.list`, and both forms exit 0 | Both forms are documented |
| "a reader can compare it with `artifactSha256`" | A binary from `zttp compile` prints an all-zero `artifactSha256`, with and without `--no-attest` | The text states the zero value. `docs/roadmap.md` lists the gap as open |

### 10e. Site check

`../ZTTP-WEBSITE` at `100f496` holds nine repository links, and each one resolves. The anchor `docs/roadmap.md#agent-compiler-agenda` stays. The site does not name the old spec path, a removed form, or a moved count, so it gets no commit. It claims released behavior only, and the next release decides its update.

### Gates

The first run failed in `scripts/audit-docs.sh`, which `test-doc-links` and `zig build test` both run. The spec moved down one directory, so its two relative links to `roadmap.md` broke. I corrected both links.

The second run exited 0 for `test-doc-links`, `test-grammar-drift`, `test-idiom-table`, `zig build test` with 214 of 214 steps, and `check-spine`. The first run also exited 0 for `test-docs-drift`, `test-spine`, `test-script-reachability`, and `zig build`. These runs used a warm cache. Phase 11 runs the empty-cache gate.

Open for the owner: `STRATEGY.md` and `docs/provable-reach.md` still cite `pre-rebase:` paths, which resolve only after the push that Decision 6 selects.

### 10b. Root instructions

`AGENTS.md` moved from 27,490 bytes to 22,523 bytes. The generated blocks did not change. The row-count claim for `scripts/unseeded-rules.allow` stays in `AGENTS.md`, so `check-docs-drift.sh` still reads a claim.

Five bullets became seven bullets. Each bullet states rules and links to the file that holds the reason. A clause check over the 136 clauses of the old bullets found 123 unchanged. I read the other 13. Twelve keep their facts, with a changed subject or a split sentence. One lost "decide whether a program is proven", and I restored it in `scripts/AGENTS.md`.

Text that moved:

| Old bullet | Moved text | New file |
|---|---|---|
| Proof swallow | The thirty-four files and their groups | `scripts/AGENTS.md` |
| Proof swallow | A swallow surfaces as a pass, not as a failure | `scripts/AGENTS.md` |
| Proof swallow | A walk with `else => {}` reports a verdict for children it never read | `scripts/AGENTS.md` |
| Proof swallow | The five fail-opens, with three solution links | `packages/zts/AGENTS.md` |
| Proof swallow | The weaker assertion let the class survive in `cacheGet`, `queue.receive`, `sqlOne`, `sqlMany`, and `durable.waitSignal` | `packages/zts/AGENTS.md` |
| Proof swallow | The class also shipped in `packages/pi`, with one solution link | `packages/zts/AGENTS.md` |
| Rule seeds | The list once carried nineteen rows | `packages/pi/AGENTS.md` |
| Rule seeds | How those rows were closed | `packages/pi/AGENTS.md` |
| Rule seeds | A row for a code that nothing constructs is a false advertisement | `packages/pi/AGENTS.md` |
| Rule seeds | `scripts/check-diagnostic-producers.sh` catches that shape, with two solution links | `packages/pi/AGENTS.md` |
| Persistent reads | Why no dataflow rule reaches a persistent read | `packages/modules/AGENTS.md` |
| Persistent reads | Why `argDerivedLabels` cannot close the finding | `packages/modules/AGENTS.md` |
| Persistent reads | `derives_from_args` is for a pass-through, and `returns_from_param` is retired | `packages/modules/AGENTS.md` |
| Persistent reads | `.unknown` moves a verdict to unproven, and `rateCheck` and `uuid` are not this shape | `packages/modules/AGENTS.md` |
| Declassifiers | `mask` uses `mask_visible_max`, which is 4 | `packages/zts/AGENTS.md` |
| Declassifiers | The definition of an unmodified source value | `packages/zts/AGENTS.md` |
| Declassifiers | Why an operation drops the mark | `packages/zts/AGENTS.md` |
| Declassifiers | A runtime `visible` puts the magnitude in the code that computes it | `packages/zts/AGENTS.md` |
| Gate floors | The shapes of an empty gate, and the two scripts that assert a floor, with one solution link | `scripts/AGENTS.md` |
| Gate floors | A full input can still get a weak assertion | `scripts/AGENTS.md` |
| Gate floors | A probe that does not compile runs no check, with one solution link | `scripts/AGENTS.md` |
| Gate floors | What a porous gate is, and the one-edit method | `scripts/AGENTS.md` |
| Gate floors | An open vocabulary gate names its threat, with one solution link. The root keeps the rule | `scripts/AGENTS.md` |
| Gate floors | The aggregate refuses `-Dtest-filter`, and a suite with an empty filter fails | `scripts/AGENTS.md` |

## Phase 11

Status: complete at `5329a60b` on 2026-10-31. The reset is closed.

The gates ran from empty local caches, in the scrubbed environment:

| Check | Result |
|---|---|
| `zig build test` | Exit 0. 8469 of 8475 tests pass, with 6 skipped, on 214 of 214 steps. The skip count equals Phase 0 |
| `bash scripts/verify.sh` | Exit 0 in 1,172 seconds |
| `zig build bench-check -Doptimize=ReleaseFast` | Exit 0 at load 2.2 to 3.2, with geomean 1.00279 and regression 0.00%. This run used a warm cache |
| `zts check` digests | 0 of 215 rows moved |
| `zts compile` digests | 97 of 215 rows moved, and no exit status moved |
| Surface digests | 6 of 38 rows moved, and no exit status moved. The table is identical to the L9 table |

The Phase 0 count was 8492 of 8498, so the net change is 23 fewer tests. I did not reconcile that count test by test.

The plan asks for each difference to trace to a class B unit. The binary at the legacy-removal base `03318b5a` gives the Phase 0 check and compile tables exactly. So no reset unit moved these rows, and each move comes from a class B unit of the legacy removal:

| Rows | Moved at | Change |
|---|---|---|
| 94 compile rows | L6 | `semanticsHash` in `contract.json` |
| 3 compile rows | L6 and L7c | `semanticsHash`, and the removal of the scalar response fields |
| `zts spec-check --help`, `zts spec-hash --help`, `zts spec-render --help` | L6 | The semantics hash and the node census |
| `zttp proofs --help` | L8a | `--no-sign` is gone |
| `zttp-runtime --help`, `zttp expert --help` | Reset 9a | The text corrections of that unit |

I compared the output of the base binary and the final binary for each of the 97 compile rows. That diff has 829 changed lines. They are the `semanticsHash` lines, the scalar response lines, and path lines that name my two scratch directories.

One exit-0 compile row did not move: `examples/handler/handler-with-imports.ts`. Its contract holds an all-zero `semanticsHash` at both commits, so L6 could not move it. That row exposed an older defect: `zttp compile` refuses a multi-module handler. `docs/roadmap.md` lists the defect, and the legacy removal worklog gives the evidence.

`surface.sh` exited 0 against `after-L6`, because L8a replaced that baseline. `digest.sh` exited 1 at its `cmp`, as expected with moved rows, and each assertion before the `cmp` passed.

Evidence republish is not part of this phase. The next release runs `release-provenance`. Unit 9d stays deferred for a re-record window. The owner pushes the four archive tags, as Decision 6 selects.

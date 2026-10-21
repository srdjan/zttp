# Hardening and pruning list, round 2

Status: audit list, 2026-10-20, at `294680be`. This file does not authorize implementation.
Round 1 (H1 to H8, [plan](2026-10-20-hardening-pruning-plan.md)) is complete and excluded here.
Rejected directions from advisory plan 003 and `docs/decisions.md` are also excluded.

## Method and evidence limits

Six read-only audit agents examined six areas: the zts frontend, zts analysis, the engine and modules, tools and runtime, `packages/pi`, and repository gates and docs.
Each agent checked callers with `git grep` over `packages/`, `build/`, `tooling/`, and `scripts/`.
Each agent measured sizes with `wc`, `sed`, or `awk` ranges.
No agent and no main-session step ran a build or a gate. No deletion probe ran.

The main session re-checked ten claims against the source. Column "Chk" marks them with "M".
All ten held. Other rows carry the agent's evidence only and need a probe before deletion.
Line numbers were removed because the spine gate refuses line anchors in tracked docs. The audit baseline is `294680be`.
Line counts are the agents' measurements and are approximate where marked "about".

The gate names come from the AGENTS.md gate table. Each gate is an unfiltered `zig build <step>` run.

## Tier A: hardening (false passes and fail-open shapes)

| ID | Finding | Evidence | Effect | Risk | Gate | Chk |
|---|---|---|---|---|---|---|
| A1 | A missing or non-PCRE2 `rg` makes nine census checks pass | `scripts/check-capability-helpers.sh`, `scripts/check-docs-drift.sh` use `rg ... \|\| true` | The gate prints PASS without a scan. Add a `command -v rg` and PCRE2 floor with a rejection probe | low | `test-capability-audit`, `test-docs-drift` | M |
| A2 | The aggregate proof accepts a candidate whose full analysis failed | `packages/pi/src/aggregate_proof.zig` | On a full-check error, the fallback runs with `skip_contract`. When every fallback diagnostic is in the baseline, no new diagnostic is found and the change is accepted. Correction 2026-10-21: U2 found this path unreachable through `prove` today, because `normalizeCandidates` runs the same check first and rejects with `normalization_failed`. The fix is defense in depth | medium | `test-expert-app`, `test-standin` | M |
| A3 | Stand-in seed and guard evidence tests an oracle that production does not call | `runVeto` callers are only tests (`standin_range_tests.zig`, `standin_tests.zig`, `transcript.zig`, `mlx_e2e_test.zig`); production uses `aggregate_proof.firstNewDiagnostic` | The AGENTS.md defect-seed invariant is backed by a different verdict function. Move the tests to `aggregate_proof.prove`, then delete `veto.zig` (B9) | medium | `test-standin`, `test-expert-app` | M |
| A4 | The veto salvage re-check drops the inline policy | `packages/pi/src/veto.zig` passes `policy_source` to the first `simulate` and not to the salvage `simulate` | A salvaged draft is re-checked against a different policy. Latent, test-only today; A3 removes it | low | `test-standin` | |
| A5 | `zts check --json` can exit 0 with truncated or empty output | `packages/tools/src/zts_cli.zig` writes the envelope with `catch {}` and ignores the `std.c.write` result | An allocation failure gives a success exit status with bad JSON. Use `try` | low | `test-zts-cli`, `test-cli-abuse` | |
| A6 | A parse failure or OOM silently shrinks the module graph record | `packages/tools/src/module_graph_record.zig` | A partial import list feeds the hashed agent identity (`agent_protocol.zig`) with no rejection record | medium | `test-module-graph-record`, `test-agent-protocol`, `test-agent-determinism` | |
| A7 | A new `FlowChecker` reports all six flow properties proven | `packages/zts/src/flow_checker.zig` defaults to `.{}`; `flow_report.zig` defaults are `true`; `unproven` is applied only on one path | Latent: only pass-state checks in `pipeline.zig` prevent it. Default to `unproven` | low | `test-zts` | M |
| A8 | The contract property wire struct is a hand copy of `HandlerProperties` | `contract_json_parser.zig`; seven fields default to `true` (`contract_types.zig`) | A new default-true field missing from the wire struct is claimed proven in every parsed contract. Derive the struct at comptime or assert the field set | low | `test-zts`, `test-contract-golden` | |
| A9 | Unknown property names fall to `.info` severity | `contract_diff.zig` string table | A renamed property silently loses severity in `pr_gate.zig` and `upgrade_verifier.zig`. Make the table exhaustive over `FieldEnum(HandlerProperties)` | low | `test-zts` | |
| A10 | Two return-predicate classifiers disagree | `type_syntax.zig` substring test against the `predicateHeader` parse; pinned at `typed_frontend_tests.zig` | A literal return type `"x is y"` becomes `boolean` (`type_env.zig`). `value\tis\tstring` loses its predicate. This is a behavior fix, not cleanup | medium | `test-zts`, `test-diagnostic-corpus` | |
| A11 | Analysis files outside the proof-swallow gate | `scripts/check-proof-swallow.sh` omits `path_generator.zig`, `pipeline.zig`, `proof_ir.zig`, `translation_witness.zig` (21 catch sites) | `path_generator` decides `fault_covered` and `paths_exhaustive`. The sites the agent read are fail-closed. Add them with reasoned rows | low | `test-proof-swallow` | |
| A12 | Unchecked length casts in ReleaseFast | `string.zig`, `string_builtins.zig`, `array.zig`; default `memory_limit` is 0 | A string between 2 GiB and 4 GiB gets a wrong length with no error | medium | `test-zts`, `test-zruntime` | |
| A13 | Hidden-class growth does not trigger runtime recycling | `runtime_pool.zig` counts only atoms; `builtins/json.zig` | Reordered JSON keys may add classes without bound across requests. Probable; a class-count probe can confirm it | low-medium | `test-zruntime`, `test-server` | |
| A14 | Partial output reported as complete in precompile | `precompile.zig` (`writeJsonl catch {}`, and the proof trace drop on a serialization error) | Generated-test JSONL or the proof trace can be partial in a success result | low | `test-precompile`, `test-contract-golden` | |
| A15 | A test that probably checks nothing | `proof_ir.zig` nests 520 blocks; parser limit is 512 (`parse.zig`); `catch return` exits | Probable vacuous pass. Replace `catch return` with `try` to confirm | low | `test-zts` | |
| A16 | Unsynchronized process globals | `bytecode.zig` `guard_id_counter`; `builtins/date.zig` `performance.now` origin | Data race between worker threads. B5 deletes the first | low | `test-zts` | |
| A17 | The example gate floor is one below the real count | `scripts/test-examples.sh` | Floor 33 against 34 suites; a "0 passed, 0 failed" suite counts as PASS | low | `test-examples` | |
| A18 | `pipeline.flowExportedFunctionNode` is weaker than the facade lookup | `pipeline.zig` against `flow_checker.zig` | Production picks the first match with no `kind` or module check; the facade refuses ambiguity. Tightening fails closed | medium | `test-precompile`, `test-flow-census` | |
| A19 | `test-standin`'s fixed filter bypasses the non-empty selection check | `build/host_tests.zig` | 55 tests match today; a rename would run zero tests silently | low | `test-standin` | |

Owner-policy items, listed under decisions 2 and 3 below: the debug panic hook (A20) and secret file reads by the expert (A21).

- A20: `runtime_cli.zig` reads `ZTTP_DEBUG_PANIC_PATH` in every build and arms `runtime_pool.zig @panic`.
- A21: `pi/src/tools/workspace_read_file.zig` reads gitignored files such as `.env`. The content goes to DeepSeek and the session journal (`persister.zig`).

## Tier B: dead code with checked callers (deletion, low risk unless stated)

| ID | Item | Size | Keep | Gate | Chk |
|---|---|---|---|---|---|
| B1 | AWS and Cloudflare deploy renderers and six unread `ProvenFacts` fields, `deploy_manifest.zig` | about 1,190 of 1,491 lines | `extractProvenFacts`, `ProvenFacts`, `ProvenRoute`, `default_cost_body_limit` | `test-deploy-manifest`, `test-proof-review`, `test-cli` | M |
| B2 | `CodeVersion`, `VersionedFunction`, `HotReloadManager`, `bytecode.zig` | 426 | none | `test-zts` | M |
| B3 | `FunctionBytecodeCompact` and `BytecodeCache.put`/`get` | 383 | `putRaw`, `getRaw`, `BytecodeHeader`, `MAGIC`. Check the `nested_function = 4` comment at `bytecode_cache.zig` before deletion | `test-zts`, `test-zruntime` | M |
| B4 | Synchronous major GC, SIMD and scalar sweep, root-tracking wrappers, `gc.zig` | 158 plus about 100 test lines | tests that use `majorGC` loop `runIncrementalGCStep` instead. Medium risk | `test-zts`, `test-zruntime`, `bench-check` | |
| B5 | JIT leftovers: guard IDs, `profileBackedge`, `recordDeopt`, `tier_count`, `LOOP_THRESHOLD` | about 76 | check that inline slot index 2 is not read by position | `test-zts` | M |
| B6 | Legacy `ModuleExport` conversion and six unread `exports` constants | about 70 | `module_func` test, rewritten with `getNativeFn` | `test-zts`, `test-modules`, `test-sdk`, `test-module-governance` | |
| B7 | `serializeBytecodeWithAtoms` and `deserializeBytecodeWithAtoms` | 40 | the `AndShapes` variants | `test-zts` | |
| B8 | Unused sqlite wrapper members | about 20 | members the bridge and `veto.zig` use | `test-precompile`, `test-zruntime` | |
| B9 | `packages/pi/src/veto.zig` after A3 | 857 | none | `test-standin`, `test-expert-app` | M |
| B10 | `proof_enrichment.analyzePatch` and its helpers | 294 | `buildUnifiedDiff`, `loadProveSummaryForPatch`, `formatProveSummary`, `propertiesSnapshot`, `resolveHandlerPath` | `test-expert-app` | |
| B11 | Small pi dead code: `capturePost`, `witness_key.zig`, `decodeResponseFromRequestDigest`, four test-only helpers | about 170 | none | `test-expert-app`, `test-cassette`, `test-recorder-smoke` | |
| B12 | Printer `parsed_store` input and its region collector | about 330 including tests | `printer.print` | `test-zts`, `test-canonicalize` | |
| B13 | Test-only primitive-annotation API in `type_syntax.zig` | about 120 plus tests | `Failure` | `test-zts` | |
| B14 | The flow shadow harness, which now compares `FlowInterp` with itself | 747 plus build, spine, allowlist, and doc rows | first move its `unresolved == 0` floor into a precision test | `test-flow-census`, `test-precompile`, `test-step-coverage`, `check-spine` | M |
| B15 | `FlowChecker` test-only export API, duplicate `ensureHealthy`, retired flow-interp phase scaffolding, `tagVisits`; rename `Owner.p7`/`.p8` to mechanisms | about 75 | 164 retained flow behavior tests | `test-zts` | |
| B16 | ASI census measurement (`parse.zig`, `tests/asi_census.zig`) | about 165 | `allow_asi` stays live; D-008 is not reopened | `test-zts` | |
| B17 | Tools and runtime leftovers: `runCheckOnly`, five unused `server.zig` aliases, unreachable serve-flag branches, dead test helpers | about 45 | `runCheckOnlyFromSource` (decision 4) | `test-precompile`, `test-server`, `test-cli` | |
| B18 | `scripts/flow-census.allow` has 0 data rows; its parser has eight row-error kinds | 59 lines plus parser code | an empty allowlist already fails on any mismatch. Medium risk | `test-flow-census` | |
| B19 | Orphan fixtures `tests/validate/` | 2 files | wire them into `test-examples.sh` or delete them and fix two doc references | `test-examples`, `test-doc-links` | |

Tier B sums to about 5,400 lines by the agents' measurements. This total is not re-measured.

## Tier C: consolidation (medium risk, needs a plan)

| ID | Item | Size | Constraint | Gate |
|---|---|---|---|---|
| C1 | IR node tags that the parser never produces (`while`, `switch`, `try`, `class`-related, `for_in`, generator and async flags) and their dead arms in about twelve walkers | about 350-400 | changes the semantics registry hash; check whether the proof certificate serializes `NodeTag` | `test-zts`, `test-meta-drift`, `test-flow-census`, `test-proof-checker` |
| C2 | Thirteen opcodes that the compiler never emits, and their interpreter handlers | 152 | changes `opcodeTableHash` and parity tests | `test-zts`, `test-meta-drift` |
| C3 | DeepSeek and local clients share about 240 identical decode lines | about 240 | `validateBaseUrl` really differs | `test-expert-app`, `test-cassette` |
| C4 | Two type parsers: `TypeExprParser` (557 lines, SDK strings, no depth guard) and `type_syntax` | 557 | high risk; check that no hostile text reaches the exported `parseTypeExpr` first | `test-zts`, `test-modules`, `test-contract-golden` |
| C5 | Four quote and template scanners with different end rules in `type_syntax.zig` | not measured | probes must show that diagnostics do not change | `test-zts`, `test-diagnostic-corpus` |
| C6 | Three serve-flag lists; `findPositionalPath` already drifted (`serve --_debug-panic-path /x` takes `/x` as the project); three copies of build-command argument parsing | about 52 | exact CLI behavior | `test-cli`, `smoke-v1` |
| C7 | `precompile.zig`: 13 copies of the stderr print pattern; `compileHandler` repeats path-analysis setup | about 115 | exact stderr text | `test-precompile`, `test-contract-golden` |
| C8 | Drift gates that parse Zig with awk (`check-docs-drift.sh` catalog section, idiom, grammar, canonical style) next to generated `--check` renderers | about 600 shell lines | add `module-spec-render --check` to `test` before deleting shell | `test-docs-drift`, `test-idiom-table`, `test-grammar-drift` |
| C9 | Three gates compile with `zig run` inside `test`; five wrappers repeat a cold-compile fallback; two gate sources sit in `scripts/` | 381 Zig lines, about 50 shell lines | floors and release-probe checks | `test-kernel-safety`, `test-residual-guards-drift`, `test-script-reachability` |
| C10 | Replay keeps a lenient JSON parser and serializer (`null` becomes `undefined`) | about 370 | replay behavior changes | `test-zts`, `test-zruntime` |
| C11 | Four hand-synced module lists | not measured | registration order may feed hashes | `test-module-governance`, `test-contract-golden` |
| C12 | Cassette and simulator tests run twice in aggregate `test` | 87 test runs | keep the standalone steps | `test-cassette`, `test-simulator`, `test` |
| C13 | Small duplicates: `print_mode.emitEntry` against `persister.entryToEvent`, three JSON string escapers, the `normalize` wrapper chain | about 110 | the D-003 stdin wire shape | `test-expert-app`, `test-canonicalize` |

## Tier D: documentation and stale claims

D1. Four copies state that a filtered run exits 0 with zero tests. H3 made that run fail. The copies are at `AGENTS.md`, `CONCEPTS.md`, `docs/internals/testing.md`, and a solutions note.
D2. `AGENTS.md` counts three `.py` files and eleven `python3` scripts. The measured count is zero of each (main session re-checked).
D3. `AGENTS.md` says "seventeen" and later "eleven" for the same file list. The gate lists 17.
D4. The generated gate table has a constant "Measured: not measured" column in 80 of 80 rows (`tooling/agent_spine.zig`).
D5. `docs/plans/` holds 50 files and 22,839 lines. About 9,400 lines are complete plans and worklogs with no outside citation. The G14 precedent deletes them and keeps them at a tag. The index omits 15 files and marks Phase 3 active.
D6. `.claude/skills/zttp-build/SKILL.md` documents removed flags `-Dstudio`, `-Dedge`, `-Dreplay`, and `-Dtest-file`.
D7. `AGENTS.md` holds 5,632 bytes of incident narrative that `docs/solutions/` already holds. Reduce it to rules and links, but keep one allowlist count claim that `check-docs-drift.sh` reads.
D8. Stale comments: `deploy_manifest.zig`, `builtin_modules.zig`, `build/step_coverage.zig` (no workflows exist), and `docs/internals/testing.md` (shadow interpreter).

## Checked and left alone

The agents found these areas sound: sqlite is required by `zttp:sql` and schema validation, and the acceptance kernel is still a dependency-free leaf. Server path traversal checks and request limits are present. Provider responses are bounded and API keys stay out of cassettes. Change-set writes cannot leave the workspace. No removed provider, RPC, orchestration, or agent-handler code remains, and edge, studio, and cloud remain only as deferred messages. `zttp:json` stays separate from `JSON.*` on purpose. No shell pipeline loses its exit status through `| tail`.

## Proposed order

Round 2a: A1 to A9, A11, A14, A15, A17, A19, D1 to D4, D6, D8. These are small fixes that remove false passes and false guidance.
Round 2b: Tier B in this order: B2, B3, B5 to B8, B1, B10 to B17, then B4, B9 after A3, B14, B18, B19.
Round 2c: A10, A12, A13, A18, and Tier C, each as its own planned unit. C1 and C2 change registry identity.
D5 and D7 can go with 2a or 2b.

## Decisions for the owner

Decision 1: scope of the next plan.
Option A: Round 2a only. Option B: Rounds 2a and 2b. Option C: all three rounds.
Recommendation: Option B. Round 2c needs separate plans because C1 and C2 change registry identity.

Decision 2: the debug panic hook (A20).
Option A: compile the hook only into Debug builds and keep the `--_debug-panic-path` flag for the panic-isolation test. Option B: keep it in every build.
Recommendation: Option A, if `scripts/test-panic-isolation.sh` runs a Debug build. A check of that script must come first.

Decision 3: expert reads of gitignored files (A21).
Option A: apply the ignore policy of `workspace_search_text` to `workspace_read_file`. Option B: keep the current reads.
Recommendation: Option A. File content goes to a hosted provider and to the session journal.

Decision 4: the public `precompile` wrappers (B17).
`zts_cli.zig` re-exports `precompile`, so a deletion changes a public Zig API.
Option A: delete `runCheckOnly`, which has zero callers, and keep `runCheckOnlyFromSource`. Option B: delete both and move 48 test calls. Option C: keep both.
Recommendation: Option A.

Decision 5: completed plans (D5).
Option A: delete the uncited completed plans and worklogs and keep them at a tag, as G14 did. Option B: keep them.
Recommendation: Option A.

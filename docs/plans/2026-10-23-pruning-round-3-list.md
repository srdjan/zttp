# Hardening and pruning list, round 3

Status: audit list, 2026-10-23, at `1fcb0734`. This file does not authorize implementation.
Rounds 1 and 2 are excluded ([round 2 list](2026-10-20-pruning-round-2-list.md), [round 2 worklog](2026-10-21-pruning-round-2-worklog.md)).
Round 2 items that are still open keep their round 2 names (A10, A12, A13, A18, C1 to C13).

## Method and evidence limits

Six read-only audit agents examined six areas: the zts frontend, zts analysis, the engine and modules, tools and runtime with the acceptance kernel, `packages/pi`, and gates with docs.
Each agent checked callers with `git grep` or `rg` over `packages/`, `build/`, `tooling/`, `scripts/`, `tests/`, and `examples/`.
The frontend agent and the pi agent ran the prebuilt `zts` and `zttp` binaries on scratch files in `/tmp`. No agent ran `zig build`.
The main session re-checked eight claims against the source: H1, H2, H3, H5, H13, P1, the `std.c.write` count of H12, and the install race H24. Column "Chk" marks them with "M". All eight held.
"Src" names the agent finding ID, for traceability. "PROBABLE" rows need the named probe before an edit.
Line counts are the agents' measurements and are not re-measured. Line numbers are omitted because the spine gate refuses line anchors in tracked docs.

Baseline: `zig build test` with a private cache exited 1 at `1fcb0734`. 9,550 of 9,556 tests passed and 6 were skipped. The one failed step is H24. `zig build test-expert-golden` alone then exited 0.

## Tier H: hardening (live defects, false passes, fail-open shapes)

| ID | Finding | Effect | Status | Risk | Gate | Src | Chk |
|---|---|---|---|---|---|---|---|
| H1 | `parse.zig` `parseNumber` falls back to `parseFloat(...) catch 0.0`. `parseFloat` reads only base 10 and 16 | A `0b` or `0o` literal above i32 becomes 0 at runtime, and the analyzer reports the handler PROVEN. Use the radix logic of `parseExpressionNumber` | CONFIRMED by a `zttp serve` probe | low | `test-zts`, `test-diagnostic-corpus`, `test-zruntime` | F-1 | M |
| H2 | `pi/src/tools/workspace_search_text.zig` runs `rg --hidden` with no secret deny globs and no `ignoredRefusal` | A search returns `.env` lines. The lines go to DeepSeek and the session journal. A21 closed only `workspace_read_file` | CONFIRMED by an `rg` probe | low | `test-expert-app` | X-2 | M |
| H3 | `flow_report.propertyTagForKind` maps diagnostics to 3 goals. `property_goals.supported_goals` admits 5. `pi_goal_check` reads only diagnostics and never the unresolved count | The goals `input_validated` and `pii_contained` can never fail. An unresolved analysis also passes. The autoloop prints the goal as achieved | CONFIRMED by source | medium | `test-expert-app`, `test-standin`, `test-simulator` | G-1 | M |
| H4 | `pi_goal_check` drops a violation that has no location, and drops it on a solver error. `autoloop.parseGoalCheckResult` drops a malformed witness with `catch continue` | A goal violation can give `ok:true`. The receipt can claim that a live witness is defeated | CONFIRMED by source | low | `test-expert-app` | X-4, X-5 | |
| H5 | `builtins/root.zig` stores `Math.PI` under `ctx.atoms.next_id`, which no name owns yet | `Math.PI` probably reads undefined, and the next interned name (probably `hasOwn`) probably reads 3.14159 on `Math`. Probe: a unit test that reads both after builtin init | defect CONFIRMED by source; effect PROBABLE | low | `test-zts` | E-6 | M |
| H6 | The object literal parser drops `get` or `set` before a key that `(` does not follow | `{ get x: 1 }` is accepted as `{ x: 1 }`. `zts normalize` keeps `get`, so the source and the IR disagree | CONFIRMED by a `zts check` probe | low | `test-zts`, `test-diagnostic-corpus` | F-2 | |
| H7 | `aggregate_proof.prove` compares diagnostics without line numbers | A candidate that deletes a handler can pass when its diagnostics are a sub-multiset of the baseline's. Probe: baseline with ZTS500, candidate `""` | PROBABLE | medium | `test-expert-app`, `test-standin` | X-3 | |
| H8 | `context/project_context.zig` walks to `/` when no `.git` exists | `~/AGENTS.md` and `~/CLAUDE.md` go to DeepSeek. Stop at the workspace root | CONFIRMED by source | low | `test-expert-app` | X-7 | |
| H9 | `ReferenceEligibility.legacy_slot` matches a reference by slot only, at four `contract_builder.zig` sites and two `effect_inference.zig` sites | A local whose slot equals an import's atom index is treated as the import. Its literals enter the egress, env, or cache lists. Probe: alias an import to a predefined atom name | PROBABLE | low | `test-zts`, `test-contract-golden`, `test-flow-census` | G-4 | |
| H10 | `precompile --contract` without `--verify` starts `state_isolated` at `true`. Six `HandlerProperties` fields default to `true`. `computeProperties` sets `.canonical = true` for non-strict callers | The contract claims properties that no pass checked. The runtime is safe, because promotion needs a kernel verdict. Probe: `--contract` on a handler that mutates module state | PROBABLE | low | `test-precompile`, `test-contract-golden`, `test-zts` | G-2, G-3 | |
| H11 | `deploy_manifest.extractProvenFacts` drops `env_proven`, `egress_proven`, and `cache_proven` before the review card | A change from literal to dynamic egress probably gives an empty `proofs diff` delta. Probe: `deriveDelta` on two contracts that differ only in `egress.dynamic` | PROBABLE | medium | `test-deploy-manifest`, `test-proof-review`, `test-cli` | T-4 | |
| H12 | About 58 `_ = std.c.write(STDOUT...)` calls ignore the result. `precompile.writeViolationsJsonl` uses `catch {}` and then prints "written to" | A short write, EPIPE, or ENOSPC exits 0 with partial JSON. Merge the three write-all helpers into one. Probe: `zts agent --stdin-json > /dev/full` | ignored result CONFIRMED; partial output PROBABLE | low | `test-zts-cli`, `test-cli-abuse`, `test-agent-protocol`, `test-precompile` | T-5, T-6 | M |
| H13 | `check-kernel-safety.sh` and `check-capability-helpers.sh` feed `xargs` with no input floor | On empty input macOS `xargs` runs nothing and exits 0, so the gate passes without a scan | CONFIRMED by an `xargs` probe | low | `test-kernel-safety`, `test-capability-audit` | R-1, R-2 | M |
| H14 | The `zig fmt --check` route omits `zts_main.zig`, `scripts/kernel_safety_gate.zig`, and `scripts/residual_guard_extract.zig` | An unformatted change there passes `verify` | CONFIRMED | none | `verify`, `test-native-gates` | R-3 | |
| H15 | `check-proof-swallow.sh` omits `contract_diff.zig`, `match_analysis.zig`, `bool_checker.zig`, `behavior_canonical.zig`, `ir_identity.zig`, and probably `strict_checker.zig` | These decide `equivalent`, `safe`, ZTS205, boolean gating, and `canonical`. Add reasoned rows, as A11 did | CONFIRMED | low | `test-proof-swallow` | G-5 | |
| H16 | `codegen.zig` `tryEmitFusedArithMod ... else \|_\|` swallows every error, including `TooManyConstants` after the operands were emitted. An `else => .nop` arm covers future binary operators | Probably 2 extra stack values on a full constant pool. A new operator silently emits `nop`. Probe: 65,535 constants, then `(a+b)%7` | PROBABLE | low | `test-zts`, `test-precompile` | E-7 | |
| H17 | Five `MODULE_STATE_SLOT` literals are typed by hand with no comptime link to `module_slots.Slot`. `json_mod.limits` is a mutable process global. `bytes_mod` and `json_mod` set error Result fields with `catch {}` | A slot drift makes `schemaCompile` return false silently. An out-of-memory Result has no `kind` | CONFIRMED | low | `test-modules`, `test-zts` | E-8, E-9, E-10 | |
| H18 | `agent.zig` tests call `initFromEnv*` 49 times without a chdir, so they lock and recover the repository's own `.zttp` | Probable cause of the intermittent "concurrent first launch" failure from round 2a. Probe: hold a flock on `.zttp/change-set.lock` during `test-expert-app` | PROBABLE | low | `test-expert-app` | X-1 | |
| H19 | `workspace_snapshot` creates `/tmp/zttp-proof-<sec>-<nsec>-<seq>` without exclusive creation and without a pid | A pre-created directory is reused. Probe: pre-create it, then capture | PROBABLE | low | `test-expert-app` | X-6 | |
| H20 | Builtin objects are shared by all requests in one runtime and stay writable. `checkModuleScopeMutation` returns early when the target is not an identifier | `parseInt.x = requestText(req)` probably passes the state isolation check and leaks across requests under reuse. Probe: `zts check`, then two requests | PROBABLE | medium | `test-zts`, `test-zruntime` | E-11 | |
| H21 | The REPL tools `/check`, `/specs`, and `gen_tests` spawn `zig build cli -- ...` in the user's workspace | In a hostile workspace, `/check` runs that workspace's `build.zig`. Outside the ZTTP checkout the tools fail. `zts_cli` is already linked in-process | CONFIRMED | low | `test-expert-app` | X-9 | |
| H22 | `agent_protocol.zig` test "the example evidence check can fail" asserts `!saw_while` | The parser never produces `.while_stmt`, so the assertion cannot fail | CONFIRMED | low | `test-agent-protocol` | F-7 | |
| H23 | SDK `readFileChecked` checks the canonical path and then reads the original path | Check-then-read race. P9 deletes the whole path, which closes it | CONFIRMED | low | `test-sdk` | E-2 | |
| H24 | `build/goldens.zig` `init_preflight` runs `zig-out/bin/zttp` while the install step rewrites it | The baseline failed with `FileNotFound`, and the step passed alone. Probable install-and-run race under Zig 0.17. Probe: two more aggregate runs in a private cache | PROBABLE | low | `test-expert-golden`, `test` | main session | M |

## Tier P: pruning (dead code with checked callers)

| ID | Item | Size | Keep | Gate | Src |
|---|---|---|---|---|---|
| P1 | `server.zig` `StaticFileCache`, `CacheEntry`, `LruNode`, two config fields. The request path never calls `get` or `put` since `b13155d1`. Fix the API reference claim | about 265 | path traversal checks | `test-server`, `test-zruntime`, `test-doc-links` | T-1 |
| P2 | String ropes: `RopeNode`, constructors, 19 `isRope()` sites. The frontend refuses string `+` | about 323 plus 240 test lines | MemTag value 9 reserved | `test-zts`, `test-zruntime`, `test-server`, `bench-check` | E-1 |
| P3 | `ir.zig` `NodeList` and the two-format `IrView` union (39 arms). The parser builds only `IRStore` | about 250 | move 8 tests to `IRStore` | `test-zts`, `test-meta-drift` | F-4 |
| P4 | Hosted-deploy leftovers in `proof-review/review.zig` (`DriftStatus`, `PlanRequiredSummary`, `DeployReview.init`, `RenderOptions`, `region`), and the HUD replay hint for keys that no code reads | about 225 | the review card | `test-proof-review`, `test-cli` | T-2, T-3 |
| P5 | `fault_coverage.zig` external severity overrides | about 140 plus 225 test | | `test-zts`, `test-precompile` | G-6 |
| P6 | `contract_diff` `ReplaySummary`, `classifyWithReplay`, `upgrade_verifier.replay`, `CoverageGap`. Every caller passes `null` | about 175 | runtime `replay_runner.ReplaySummary` | `test-zts`, `test-expert-app` | G-7 |
| P7 | `pipeline.zig` test-only contract extractors that skip flow projection | about 195 | port 3 or 4 tests to `ModuleAnalysisSession` | `test-zts`, `test-precompile` | G-8 |
| P8 | Test-only API sweep, each with zero production callers: parser and type entry points, `printInto(self_check)`, `Options.width`; string, atom, cache, object, and context helpers; `runCheckOnlyFromSource`, `isCanonicalPathInsideRoot`, pool reload, kernel `acceptsSchema`, `skipAll`, `domainDigest`; `importFacts`, `emissionFor`; `pr_gate.no_sign` field; pi `initTmp` and unused imports; dead `system_proven` UI branches | about 850 | each test moves to the production variant | `test-zts`, `test-zruntime`, `test-server`, `test-proof-checker`, `test-proof-checker-purity`, `test-cli`, `test-expert-app` | F-5, F-6, E-13, T-9, T-10, G-11, X-10, X-12 |
| P9 | SDK `readFile` path (production always fails with `FilePathNotAllowed`) and 11 unused `*Checked` capability helpers with their `module_audit` rows | about 170 | the `.filesystem` enum value (hashed) | `test-sdk`, `test-modules`, `test-zts`, `test-capability-audit` | E-2, E-3 |
| P10 | Engine leftovers: the constant-false `get_field_call` fusion and its handler (known wrong for zero-argument calls), the async Promise branch, 17 unused `ClassId` values | about 140 | serialized flag bits | `test-zts`, `test-meta-drift`, `test-zruntime` | E-4, E-5, E-12 |
| P11 | WebSocket `RequestOutcome.transferred`, `fd_owned`, and orphan comments; the test-only AOT override seam | about 97 | | `test-server`, `test-zruntime` | T-7, T-8 |
| P12 | `pi/src/simulator/testdata/empirical/local/`: 16 schema 1 cases that `loadCase` skips as stale | 259 files, 492 lines | the DeepSeek corpus | `test-expert-app`, `test-docs-drift`, `check-spine` | X-8 |
| P13 | `intent_extractor.writeLiteralAsJson`, a third literal writer with different output (`nan`, repeated keys). Use `ir_json_literal.serialize` | about 85 | | `test-zts`, `test-contract-golden` | G-10 |
| P14 | `CostEnvelope.exhaustive`: written and serialized, never read, wire default `true` | about 10 | contract bytes move (decision 3) | `test-contract-golden`, `test-meta-drift` | G-9 |
| P15 | `agent_spine.zig` TypeScript symbol lexer. No document anchors a TypeScript symbol. Refuse that anchor form | about 123 plus 3 fixtures | Zig symbol anchors | `test-spine`, `check-spine` | R-9 |
| P16 | Gate routes: the verify `checkExpertMetadata` route (the golden pins more), and six single-script drift routes that each start one `zig build`. Make them dependencies of `test` after a time measurement | about 25 plus 6 routes | | `test-expert-golden`, `test-meta-drift`, `test-step-coverage`, `verify` | R-7, R-8 |
| P17 | Dead text: `.github/releases/v0.21.0-corrected.md`, two CODEOWNERS rows, the stale run steps of `docs/provable-reach.md`, `scripts/setup.sh` | about 400 | the cited section of `provable-reach.md` | `test-doc-links`, `test-script-reachability` | R-15 |

## Tier K: consolidation (each needs its own plan)

| ID | Item | New facts at HEAD | Constraint | Src |
|---|---|---|---|---|
| C1 | IR tags that the parser never produces | 27 tags, 3 unused `FunctionFlags`, 5 `IrView` accessors, 8 `ir.zig` tests, `emitForLoop` (47 lines) | changes the semantics registry hash | F-8 |
| C2 | Opcodes that the compiler never emits | 15 at HEAD, not 13: `push_i16`, `rot3`, `loop`, `inc`, `dec`, `eq`, `neq`, `tail_call`, `define_global`, five import or export opcodes, `get_field_call` | changes `opcodeTableHash` | E-4 |
| C4 | Two type parsers | `TypeExprParser` is 546 lines with no depth guard; only binding signature strings reach it | high risk | F-4 |
| C5 + K1 | Quote scanners and the legacy-prefix admission layer in `type_syntax.zig` | 13 scanners, about 419 lines. The quirk layer admits `p: { x number }` as `{}` (probed); 16 parity tests are 1,315 lines | high: the corpus may hold such annotations, so a re-record may follow | F-3 |
| A10 | Return-predicate classifiers | a third `" is "` substring copy in `type_env.zig` | behavior fix | |
| C6 | Serve and build argument parsing | `zttp serve a.ts b.ts` probably discovers the project from `a.ts` and serves `b.ts` | exact CLI behavior | |
| C7 | `precompile.zig` repetition | 21 `Writer.Allocating` sites, 110 `debugPrint` calls, 4 `PathGenerator.init` setups | exact stderr text | |
| C8 + K2 | Drift gates that parse Zig with awk | 1,029 shell lines in four scripts; the restriction matrix section is a fifth case (byte-diff golden); `check-proof-ratchet.sh` is a sixth | add `module-spec-render --check` to `test` first | R-4, R-5 |
| C12 + K3 | Tests that run twice | pi: unchanged. tools: `agent_protocol` and `zts_cli` roots probably repeat `precompile` (239 tests) and `canonicalize` (61) | measure aggregate time | R-6 |
| C3, C9, C10, C11, C13 | Provider decode, `zig run` gates, replay JSON, module lists, small duplicates | C3: 19 byte-identical functions. C11: plus 5 slot literals (H17). C13: 4 `nowUnixMs` copies, 3 witness writers, 8 hand escapers | witness bytes are model-visible | X-11 |
| K4 | Two engine JSON parsers (`builtins/json.zig`, `json_mod`) with different `duplicate_key` behavior | | high: user-visible JSON behavior | E-14 |
| A12, A13, A18 | Unchecked casts, hidden-class growth, `flowExportedFunctionNode` | A12 narrowed to `cmp.zig`, 41 casts in `string_builtins.zig`, 51 in `array.zig`. A13 and A18 unchanged | | |

## Tier D: documentation and stale claims

D1. Zig 0.16 text after the 0.17 migration: `CLAUDE.md`, three kernel-safety comments, `docs/internals/testing.md`, the issue template. `perf-baseline.json` records 0.16.0, and `bench-check` does not warn on a toolchain change. This is a probable factor in the open `intArithmetic` shortfall.
D2. `CLAUDE.md` says "mirroring CI" (D-009 removed CI) and "`edge` is compiled out by default" (the code is removed).
D3. `docs/internals/testing.md` exclusion list is incomplete, says "six registry hashes" where the gate prints five, and calls `smoke-v1` a script.
D4. `.agents/skills/zttp-build/SKILL.md` drifted from the `.claude` copy in three hunks. Keep one copy.
D5. The `ledger` help omits `stats`. The `cmdLedger` comment lists commands that do not exist. `canonicalize.zig` comments cite the deleted `pi veto`.
D6. Four verify-only scripts and `module-spec-render --check` have no gate table row.
D7. Completed and uncited plans total 1,313 lines (seven files, including advisor plan 006). Ten plan files are missing from the plans index, and three index statuses are stale.

## Checked and sound

The agents found these sound: server path traversal and request bounds; activation order before pool creation; the kernel leaf boundary; self-extract caps; every persistent-read module export declares `.unknown`; `mask` holds its literal bound; provider response caps; no API key in cassettes; change-set confinement; `FlowInterp` clears all six properties on an unresolved construct; the runtime promotes a property only with a kernel verdict; type nesting depth fails closed; script reachability, step coverage, the non-empty test runner, and the proof-swallow and module-boundary floors work; `docs/cli.md` matches live help.

## Proposed order

Round 3a: H1 to H6, H8, H12 to H15, H17, H21 to H24, and Tier D. These are confirmed defects and small gate fixes.
Round 3b: run the probes of H7, H9 to H11, H16, H18 to H20, then fix each probe that confirms. Then P1 to P17.
Round 3c: Tier K, each as its own planned unit. C1, C2, and P14 change registry or contract identity.

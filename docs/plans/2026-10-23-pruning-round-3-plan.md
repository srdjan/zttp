# Pruning round 3 plan

Status: validated 2026-10-23, at `6c08ad22`, after one Fable round (argument) and one Codex astra round (facts: 153 claims, 6 wrong, 8 imprecise, all corrected below).
Source list: [round 3 list](2026-10-23-pruning-round-3-list.md). IDs H, P, and D refer to that list.
Owner decisions: 1(a) rounds 3a and 3b, 2(a) delete the local corpus and keep it at a tag, 3(a) delete `CostEnvelope.exhaustive`, 4(a) run the REPL analyzer tools in-process. The owner chose all four with "as recommended".
Open owner decision 5 (H20 runtime half) blocks only the H20 item of U9.

## Rules for every unit

- Preserve observable behavior except where a unit names a behavior fix. A behavior fix starts with a test that fails on the current code.
- Before a deletion, re-run `git grep -w <symbol>` over `packages/ build/ tooling/ scripts/ tests/ examples/` and stop if a production caller exists.
- Use a private cache: `ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR` under `/private/tmp/claude-501/`.
- Unset `DEEPSEEK_API_KEY` for every build. Call no model provider.
- Take each verdict from the exit status of an unfiltered named step, written to a file. Never cite a `-Dtest-filter` run or a `| tail` status.
- Run `zig fmt --check` on touched files, then `git add`, then `zig build check-spine`.
- Write tracked docs without `path:line` anchors and without text that looks like a symbol anchor.
- Corpus identity: before a unit that changes model-visible text (tool descriptions, tool output, prompts, defect seeds), grep `packages/pi/src/simulator/testdata/` and the cassette directories for the changed tool name or string, and record the count. Run `test-expert-app` as the first gate of that unit. If the replay fails, stop and report. The owner runs any re-record. Measured 2026-10-23: `pi_goal_check` 0 files, `workspace_search_text` 1.
- Do not change a tool `description`.
- One commit per unit. Never push.

## Round 3a: confirmed defects and small gate fixes

U0. Build race (H24). First commit of the round, because the baseline `zig build test` fails on it.
In Zig 0.17 the build runner resolves an artifact argument to `installed_path` before the generated binary (`lib/compiler/Maker/Step/Run.zig`, the `.artifact` arm). Run the golden and exit checks in `build/goldens.zig` against `getEmittedBin()` through a file argument, so that no check runs the `zig-out` copy. Apply the same change to every other `addRunArtifact` call whose executable is also installed.
Gates: `test-expert-golden`, `test-step-coverage`, then `test`.

U1. Number and accessor literals (H1, H6). File: `packages/zts/src/parser/parse.zig`.
H1: `parseNumber` reads a `0b`, `0o`, or `0x` literal above i32 with the radix logic of `parseExpressionNumber`, and refuses with ZTS012 `invalid_number` where that function refuses. Remove `catch 0.0`.
H6: after the parser consumes `get` or `set` in an object literal, refuse unless `(` follows the key, through the existing refusal path.
Tests first: a 33-bit binary literal and an octal literal evaluate to their values; `{ get x: 1 }` and `{ set x: 1 }` are refused.
Gates: `test-zts`, `test-diagnostic-corpus`, `test-zruntime`.

U2. Expert secret boundary (H2, H8). Files: `packages/pi/src/tools/workspace_search_text.zig`, `workspace_read_file.zig`, `packages/pi/src/context/project_context.zig`.
`ignoredRefusal` applies `isSecretBasename` first and unconditionally, then asks git. Today it consults the basename list only when git cannot answer, so a committed or untracked `.env` is readable.
H2: the search tool refuses an explicit secret or ignored path with the same predicate, and post-filters every result record through `isSecretBasename` on its path. `rg` deny globs may stay as an optimization; they are not the boundary. Apply the post-filter to the non-`rg` fallback too.
H8: the project-context walk stops at the workspace root.
The claim is parity with `workspace_read_file`, not completeness: a literal key inside an admitted source file still reaches the model.
Tests first: a committed `.env` in a git workspace is refused by read and absent from search; a recursive search in a non-git workspace returns no `.env` line; a workspace with no `.git` does not read a parent `AGENTS.md`.
Gates: `test-expert-app` (first), `test-cassette`, `test-standin`.

U3. Goal check verdicts (H3, H4). Files: `packages/pi/src/tools/pi_goal_check.zig`, `pi_repair_plan.zig`, `packages/pi/src/autoloop.zig`.
Today both tools run a bare single-file `FlowChecker` with no import resolution and derive the verdict from diagnostics only.
H3: derive `ok` from the production check that `aggregate_proof` uses (`precompile.runCheckOnlyWithOptions` with `discoverProjectPaths`): a requested goal passes only when its property is proven in that `CheckResult` and its unresolved count is zero. Keep the bare checker only for witness synthesis. Name each unproven goal in the JSON envelope. Do not change the tool description.
H4: count a violation that has no location; on a solver error, count the violation and omit its witness instead of aborting. `parseGoalCheckResult` propagates OutOfMemory and a malformed witness.
Tests first: goal `pii_contained` on a handler that sends `req` to `fetchSync` gives `ok:false`; a handler with a resolvable sibling import and a clean goal gives `ok:true`; a missing import gives `ok:false`.
Gates: `test-expert-app` (first), `test-standin`, `test-simulator`.

U4. Engine registration and module guards (H5, H17). Files: `packages/zts/src/builtins/root.zig`, the five `MODULE_STATE_SLOT` literals (cache, sql, validate, ratelimit, fetch), `builtin_modules.zig`, `json_mod.zig`, `bytes_mod.zig`.
H5: intern `"PI"` and store `Math.PI` under that atom. The analyzer admits `Math.PI` today, so keep it.
H17: add comptime asserts in `builtin_modules.zig` that join each slot literal to `module_slots.Slot`; make `json_mod.limits` a `const` and pass limits to the tests; replace `catch {}` on Result fields with `error.OutOfMemory` propagation.
Tests first: `Math.PI` reads 3.141592653589793 and `Math.hasOwn` reads undefined.
Gates: `test-zts`, `test-modules`, `test-zruntime`.

U5. CLI output integrity (H12, H22). Files: `packages/tools/src/`, `packages/runtime/src/`.
H12: route each ignored `std.c.write` to stdout through the write-all helper of its own package (`posix_util.writeAllFd`, `zts_cli.writeAllFd`, `self_extract.writeAll`) and propagate the error to a non-zero exit. Do not merge helpers across packages. Writes of diagnostics to stderr may stay best effort. `precompile` must `try` both `writeViolationsJsonl` calls, and must print "written to" only after the file write succeeded.
H22: replace the `!saw_while` assertion with a form that the parser produces and no example contains.
Tests first: one machine command writing to `/dev/full` exits non-zero.
Gates: `test-zts-cli`, `test-cli-abuse`, `test-agent-protocol`, `test-precompile`, `test-cli`, `test-expert-golden`, `test-runtime-purity`, `test-module-boundary`.

U6. Gate floors (H13, H14, H15, D1 toolchain report).
H13: pass the file lists of `check-kernel-safety.sh` and `check-capability-helpers.sh` so that an empty list fails, add an input-count floor, and add a probe to `test-gate-floors.sh`.
H14: add `zts_main.zig`, `scripts/kernel_safety_gate.zig`, and `scripts/residual_guard_extract.zig` to the formatting route in `tooling/verification_routes.zig`.
H15: add `contract_diff.zig`, `match_analysis.zig`, `bool_checker.zig`, `behavior_canonical.zig`, `ir_identity.zig`, and `strict_checker.zig` to `check-proof-swallow.sh`. For each swallow that can weaken a verdict, propagate the error. Only a swallow that cannot weaken a verdict gets an allowlist row with its reason. Update the file count and list in AGENTS.md.
D1 part: `bench-check` prints a warning when the baseline's Zig version differs from the running Zig. The warning does not fail the step.
Gates: `test-kernel-safety`, `test-capability-audit`, `test-native-gates`, `test-proof-swallow`, `test-bench-diff`, `test-docs-drift`.

U7. REPL analyzer tools in-process (H21). Files: `packages/pi/src/tools/zts_check.zig`, `pi_specs_status.zig`, `gen_tests.zig`.
Replace the `zig build cli -- ...` child process. For `check`, call `precompile.runCheckOnlyWithOptions` and the `json_diagnostics` writer, as `zts_expert_holes` does; do not call `zts_cli.run`, which writes to fd 1, and do not call `runCheckOnlyFromSource`, which P8 deletes. For gen-tests, call `runGenTestsCommand` with an argv. Keep the output shape of each tool. Keep the routing test that needs one local-only tool.
Tests first: each tool works in a temporary workspace that has no `build.zig`.
Gates: `test-expert-app` (first), `test-runtime-purity`.

U8. Documentation (D1 to D7).
Correct the Zig 0.16 text in `CLAUDE.md`, the three kernel-safety comments, and `docs/internals/testing.md`. The issue template's `0.16.0-rc2` is a ZTTP version: change it to the current `VERSION`. Correct "mirroring CI", the `edge` claim, the `testing.md` exclusion list and hash count, the `ledger` help and comment, and the `pi veto` comments. Keep one `zttp-build` skill copy and symlink the other. List the four verify-only scripts and `module-spec-render --check` in `testing.md`.
D7: tag the current commit as `pre-round-3-archive`. Delete these completed and uncited plans: `docs/plans/2026-10-14-function-value-effects-plan.md`, `2026-10-18-local-release-pipeline.md`, `2026-10-21-quick-fixes-plan.md`, `2026-10-21-pruning-round-2-plan.md`, `2026-10-22-coupling-census-plan.md`, `2026-10-08-minimal-design-audit.md`, and `advisor-plans/006-modular-boundaries.md`. Re-check each with `git grep -F <basename>` outside `docs/plans/` first. Rewrite remaining links to the tag form, record each path and line count in the worklog, and update the plans index. Keep `zttp-evidence-model-implementation-plan.md`.
Gates: `test-docs-drift`, `test-doc-links`, `check-spine`.

Round 3a gate: `zig build test`, `zig build check-spine`, and `bash scripts/verify.sh` on main with a private cache.

## Round 3b: probes, then deletions

U9. Probes (H7, H9, H10, H11, H16, H18, H19, H20). Each probe is a test that encodes the correct behavior.
If the test fails on the current code, the defect is confirmed: apply the fix below in the same unit and keep the test.
If the test passes, record the refutation in the worklog, and keep the test only when it pins a property that no gate pins.
- H7: probe candidate `""` against a baseline with ZTS500. The probe will probably refute, because `collectCheckDiagnostics` returns `full_error` on zero fallback diagnostics. If it confirms, reject a candidate when a baseline root loses its handler export. Record this bound in the worklog: aggregate proof is a no-new-violation gate, so an edit that keeps the export and deletes a route stays admissible; the shrink is visible in `baseline_primary_properties` against `primary_properties` and in the receipt line delta. Add no shrink heuristic.
- H9: switch all seven `.legacy_slot` sites (four in `contract_builder.zig`, two in `effect_inference.zig`, one in `route_resolution.zig`) to `.module_reference`, then delete `.legacy_slot`.
- H10 (tools lane): `state_isolated` starts `false` in `compileHandler`; the six `HandlerProperties` defaults become `false`; `computeProperties` receives the strict-passed bit for `canonical`. Regenerate the contract goldens. Docs state that `false` means unproven, not violated.
- H11 (tools lane, before P4): carry `env_proven`, `egress_proven`, and `cache_proven` into `ReviewFacts` and `deriveDelta`; delete the unread `ProvenFacts` fields `handler_name`, `handler_path`, `checks_passed`, `max_io_depth`, and `checks_buf`.
- H16: catch only the pattern-mismatch error in `tryEmitFusedArithMod`; make the opcode switch exhaustive.
- H18: the 34 `agent.zig` tests that call `initFromEnv*` without directory isolation run in their own temporary directory, with the pattern of the six that already do.
- H19: create the proof scratch directory exclusively and retry on collision.
- H20: the probe is two requests under bounded reuse with `parseInt.x = requestText(req)`. The analyzer fix: `checkModuleScopeMutation` refuses a member or index write whose base is an undeclared global or a module-scope binding, including a one-level alias such as `const m = Math; m.x = v`. The runtime half waits for decision 5.
Gates: the gates named in the list for each item, then `test`.

U10. Runtime, tools, and kernel deletions (P1, P4, P11, and these P8 symbols). Tools lane, after H11.
P4 keeps `region`, because the review card prints it. It deletes `DriftStatus`, `PlanRequiredSummary`, `DeployReview.init` with `InitParams`, `RenderOptions`, the drift and plan-required render, the unused `renderReviewCard` parameters, and the HUD replay hint with `writeReplaySection`, `formatReplayLine`, and the three replay fields.
P8 symbols: `precompile.runCheckOnlyFromSource`, `server_static.isCanonicalPathInsideRoot`, `http_parser.parseRequestLine`, `runtime_pool.reloadHandler` and `reloadHandlerWithPolicy` (keep `reloadSourceGeneration`), `setPoolingPolicy`, `Server.updateContract`, `invalidateContractCaches`, `self_extract.getCleanBinarySize`, `json_util.OwnedSlices`, `dupeRequired`, `dupeOptional`, `guard_report.kindsText`, kernel `policy.acceptsSchema`, `wire.skipAll`, `wire.domainDigest`, `dev_cli.commandInjectsStoredProviders`, and the `pr_gate.Options.no_sign` field (parse and discard the flag, because `scripts/proof-gate.sh` passes it).
P14 also runs in this lane, after H10: delete `CostEnvelope.exhaustive` from the type, writer, parser, and copy, and regenerate the contract goldens with `scripts/update-contract-goldens.sh`.
Gates: `test-server`, `test-zruntime`, `test-proof-review`, `test-cli`, `test-precompile`, `test-proof-checker`, `test-proof-checker-purity`, `test-proof-checker-mutants`, `test-contract-golden`, `test-meta-drift`, `test-doc-links`.

U11. Engine deletions (P2, P9, P10, and these P8 symbols). Keep MemTag value 9, the `.filesystem` capability value, and serialized flag bits.
P2 first test: `zts check` refuses `"a" + b` with a named code. If it is admitted, ropes are live behavior: skip P2 and record it for round 3c.
P9 deletes the SDK `readFile` path, which also closes H23, and the 11 unused `*Checked` helpers with their `module_audit` rows.
P10 deletes the `get_field_call` emitter fusion and its constant flag, but keeps the opcode value with a dispatch arm that traps, because opcode removal belongs to C2. It deletes the async Promise branch and the 18 unassigned `ClassId` values.
P8 symbols: `StringBuilder`, `findByte`, `countByte`, `countCodepoints`, `AtomTable.reset`, `deserializeConstants`, `deserializeFunctionBytecode`, `BytecodeCache.cacheKey`, `object.hasProperty`, `InlineCache.hitRatio`, `getClassWithProperty`, `getPropertyOffset`, `getClassPropertyCount`, `heap.getMark`, `string_builtins.stringLength`, `sse.idFor`, `builtin_modules.findFunction`, `count`, `all`.
Gates: `test-zts`, `test-zruntime`, `test-server`, `test-sdk`, `test-modules`, `test-capability-audit`, `test-meta-drift`. Run `bench-check` twice before and twice after, and compare the local runs, not the baseline file.

U12. Frontend deletions (P3, and these P8 symbols).
P3 deletes `NodeList` and the `IrView` union, and moves its 8 tests to `IRStore`.
P8 symbols: `Parser.parseExpressionPrefix`, `ExpressionProfile` (becomes a bool), `trivia.leadingFor`, `trailingOn`, `TypePool.markNominal`, `IRStore.addLitInt`, `addLitFloat`, `addBinary`, `addUnary`, `addIdentifier`, `getExtra`, `type_syntax.scanAdmissionEndpoint`, `planApplicationBases`, `rollbackUnconfirmed`, `ScopeAnalyzer.getUpvalues`, the `printInto` `self_check` parameter, and `printer.Options.width`.
Gates: `test-zts`, `test-canonicalize`, `test-meta-drift`.

U13. Analysis deletions (P5, P6, P7, P13, and these P8 symbols).
P6 deletes the replay parameter and types, and the tests that supply replay data to `classifyWithReplay`. Remove any proof-swallow row that the deletion orphans.
P8 symbols: `path_generator.importFacts`, `translation_witness.Recorder.emissionFor`.
Gates: `test-zts`, `test-precompile`, `test-contract-golden`, `test-proof-swallow`, `test-expert-app`.

U14. Pi deletions (P12, and these P8 symbols).
P12 reuses the `pre-round-3-archive` tag from U8 and deletes `packages/pi/src/simulator/testdata/empirical/local/`, with the replay-provider path that only that corpus reaches, if one exists.
P8 symbols: `proof_enrichment.initTmp` with its `IsolatedTmp` and `transcript_mod` imports, `ui_payload.getUnsignedOrDefault`, the unused imports `persister` (autoloop), `cassette_client` (`expert_codegen_record`), `transcript_mod` (ledger), `IsolatedTmp` (`zts_expert_holes`), and the dead `system_proven` UI branches in `repl.zig` and `ui_payload.zig`. Keep the `system_proven` field, because the proof-id hash covers it.
Gates: `test-expert-app` (first), `test-cassette`, `test-simulator`, `test-docs-drift`, `check-spine`.

U15. Gate and text deletions (P15, P16, P17).
P15 refuses a TypeScript symbol anchor in the spine and deletes the lexer and its fixtures.
P16 measures the aggregate time with and without the six single-script drift gates inside `test`. If they move under `test`, drop them from the `verify` driver. The `checkExpertMetadata` route also compares `describe-rule --hash` with `policy-hash.txt`; move that comparison into `test-meta-drift` before deleting the route.
Gates: `test-spine`, `check-spine`, `test-step-coverage`, `test-expert-golden`, `test-meta-drift`, `test-doc-links`, `test-script-reachability`, `verify`.

Round 3b gate: `zig build test`, `zig build check-spine`, and `bash scripts/verify.sh` on main with a private cache, then two more `zig build test` runs to check H24 and H18.

## Decision 5 (H20 runtime half)

With no accepted certificate, the runtime reuses one isolate for up to a count of requests (`derivePoolingPolicy` returns `.reuse_bounded_by_count`). Module state already crosses requests under that design. The analyzer fix in U9 stops a builtin write from being PROVEN `state_isolated`, which is the verdict that promotes wider reuse.
Option (a): also freeze builtin objects at runtime init, so an unproven handler cannot write them. Option (b): no runtime change, and the bound is documented.
Recommendation: (b), because the leak class for unproven handlers is the same as for module state and is by design.

## Execution

Opus dispatches each unit to a Sonnet implementer with this plan and the list.
Lanes by area run in separate worktrees created by hand from local main:
- frontend: U1, U12
- pi: U2, U3, U7, U14, and the H7, H18, H19 probes
- engine: U4, U11
- tools and runtime: U5, H11, H10, U10 (with P14)
- analysis: H9, H16, H20 probes, U13
- gates and docs: U0, U6, U8, U15

U0 lands on main first. At most three lanes build at the same time. Opus reviews each diff, cherry-picks it onto main, runs the unit gates on main, and commits.
Results go in `2026-10-23-pruning-round-3-worklog.md`.

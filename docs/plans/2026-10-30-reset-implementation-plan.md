# Reset implementation plan, 2026-10-30

## Authority and status

This document is the plan authority for the 2026-10-30 reset.
It owns the findings review, the target design, the phase order, the verification, and the owner decisions.
The worklog `docs/plans/2026-10-30-reset-worklog.md` records execution and evidence. Phase 0 creates that worklog.
Execution evidence goes into the worklog, not into this document.

Status: revision 3, not approved. No phase has started. The section "Validation record" states what each review covered.
Owner approval of Decision 1 makes this document the active reset authority. Phase 1 then updates the roadmap and the plan index.
The [2026-10-25 reset plan](2026-10-25-reset-implementation-plan.md) stays the record of its completed phases R0 to R13.
This plan does not repeat a finished item from that plan.

## Goal

The reset gives future work a simple and stable base. It adds no feature.
A base is stable when each fact has one producer and each test exercises the production path.
A base is simple when each file has one responsibility and a reader can find each authority in one place.

## Result of the review

The base is healthy, so this plan does not redesign the architecture.
The 2026-10-25 reset landed: `TypeExprParser` and `projectParsedFlow` have no references, and the 185 commits after that reset added one new file in `packages/zts` and `packages/tools`.
The aggregate test passes at HEAD.

The review found one real duality and a set of smaller residues.
The duality is the untyped parser. It still reads `.ts` source that admission refused, and a refused imported file can serve traffic (N1).
The residues are hand-finished contract facts (N4), code that only tests reach (N5, N6), a documented safety feature that the server never arms (N9), and status documents that lag the code (N17).

The plan therefore has one rule. Each task does one of five things: it deletes a duplicate, deletes unreachable code, corrects a false claim, separates the responsibilities of a file, or closes a gap in a verification input.
Any other task is out of scope.

## Preservation contract

The reset preserves current functionality. These outputs are the compatibility boundary:

- The CLI commands, flags, exit codes, and output text of `zttp`, `zttp-runtime`, and `zts`.
- Every diagnostic code, message, and location.
- The contract JSON, the certificate wire format, the agent protocol schema, and the meta payload.
- The output files, standard output, and standard error of `zts compile`.
- The policy hash, the registry hashes, the pins that `check-meta-drift.sh` checks, and the bytecode identity golden.
- The corpus identity and the recorded cassettes. A prompt, seed, tool output, or wire byte change forces a paid DeepSeek re-record.
- Handler behavior at runtime, request isolation in `HandlerPool`, and the path traversal checks in `packages/runtime/src/server_static.zig`.
- The Zig embedding API that `docs/internals/api-reference.md` documents, the curated tier of `packages/zts/src/root.zig`, the exports of `packages/zttp-sdk/src/root.zig`, and each public member of an exported type.
- The leaf boundary of `packages/proof-checker` (decision D-005) and the CHECK traversals (decision D-006). This reset edits no file in `packages/proof-checker`.

Each unit has one of two classes:

- Class A (byte-neutral). The unit must not move any protected output. A stop rule halts the unit when a protected output moves. The implementer records the evidence in the worklog, and the owner decides.
- Class B (owner-gated). The unit moves a protected output by design. It runs only after an owner decision names it. Class B units are in Phase 9 only.

No phase regenerates a golden with an `update-*` script to make a gate pass.
The one exception is a class B unit whose owner decision names the regeneration.

## Baseline and evidence limits

The review read local `main` at `1d009062` (v0.26.0 plus one post-tag commit) on 2026-10-30, on a clean tree.
Release v0.26.0 was published on 2026-10-30.

| Item | Count at `1d009062` | Method |
|---|---|---|
| Aggregate test | exit 0; 211 of 211 steps; 8492 of 8498 tests passed, 6 skipped | `zig build test --summary all`, cold private cache |
| Aggregate wall time | 4 minutes 46 seconds on the cold cache | `time`, one run |
| Tracked files, tracked Zig lines | 1,469, 413,757 | `git ls-files`, `wc -l` |
| Zig lines in `packages/zts` | 209,813 | `wc -l` |
| Zig lines in `packages/pi`, `runtime`, `tools` | 72,994, 52,660, 45,298 | `wc -l` |
| Lines inside top-level `test` blocks, all packages | 141,745 | `awk` over `test "` blocks; test-only files are counted in part |
| Tasks in `agents.json` | 92: 66 aggregate, 18 manual, 4 verify, 4 release | `jq` |
| Gate rows in `AGENTS.md` | 77 | `grep` |
| Files under `scripts/`, allowlist rows | 50, 486 | `git ls-files`, `grep` |
| Files and lines under `docs/plans/` | 58, 24,278 | `git ls-files`, `wc -l` |
| `AGENTS.md`, `CLAUDE.md` | 27,364 and 8,421 bytes | `wc -c` |
| Policy hash prefix `9f85e087` occurs in | 12 tracked files | `git grep -l` |

Evidence limits. Two read-only audits and this review used `git grep`, `wc`, `awk`, and reading.
One cold aggregate test and one private build ran at HEAD. `bash scripts/verify.sh` did not run at HEAD.
Each byte-neutral claim is by reading until its unit gate proves it.
Appendix A and Appendix B hold reproducible inventories at `1d009062`. A count can move before Phase 0; Phase 0 repeats each inventory.
Each item marked "Probable" names the check that confirms it.

## Target design

A future change lands safely when each fact has one place to edit, the tests reach that place through production, a reader can find it, and the gates say what broke.
The stage model of the current architecture meets this need, so the stages stay. Only some owners change.

| Fact or stage | Owner after the reset | What goes away |
|---|---|---|
| Source acceptance | `initAdmission` in `packages/zts/src/parser/parse.zig`, for every source file and every `-e` source (Decision 4) | `parse_type_syntax`, unreachable raw arms, the raw fallback |
| Single-module analysis | `ModuleAnalysisSession` in `packages/zts/src/pipeline.zig` | `FlowWithoutHandler`, the custom `type_check` branch (Decision 3) |
| Contract completion | One function in `packages/tools`, called by both drivers | Hand stamps in `compileHandler` and `runCheckOnParsedSource` |
| Test entry | The production parse mode and the production contract path | Raw-mode analyzer tests, `buildContractOnlyFromParsed` |
| Artifact identity | One function in `packages/runtime/src/artifact_graph.zig` | Three hand-written projections |
| Activation order | `packages/runtime/src/server_activation.zig` | The activation part of `Server.start` |
| Serve request | One parse result from `parseServeArgs` | The raw argv scan, repeated config discovery in an ordinary start |
| Status | `docs/roadmap.md` | History paragraphs in the roadmap, stale plan index rows |
| Agent rules | `AGENTS.md` for the rule, area contracts and solution notes for the history | Incident narrative in root bullets |

The design keeps these items: D-005, D-006, the interpreter as the one execution path, the proof-checker kernel, the agent spine, and each public verb.

## Detailed findings review

Each finding gives the evidence, the effect on future work, the reset action, the preservation risk, and the class.
The labels N1 to N20 are new. F1 to F18 mean the findings of the 2026-10-25 reset. The list is in order of value to the reset goal.
N13 and N16 are withdrawn after validation. They stay in the excluded list with the reason.

### N1. The untyped parser is a second path for `.ts` source that admission refused

Evidence: `selectSourceProfile` in `packages/zts/src/modules/internal/module_graph.zig` prints "TypeScript strip failed" for a terminal admission refusal and then returns `.raw`.
`collectImports` in `packages/tools/src/module_graph_record.zig` falls back in the same way.
A test, "graph source selection bounds every hard admission producer", asserts this fallback for every `AdmissionKind`.

Observed probes at `1d009062`, with a private build of `zttp-runtime`, using a handler that imports `lib.ts`:

| `lib.ts` content | Admission result | Raw fallback result |
|---|---|---|
| A trailing `/* open` | `UnterminatedComment` | `serve` starts and answers HTTP 200 with the helper result |
| A leading `/* open` | `UnterminatedComment` | `serve` starts and answers HTTP 500 |
| 16 other forms | The named refusal | `serve` refuses, with a second and less exact message |

The 16 forms are `any_type`, `as_assertion`, `satisfies_assertion`, `unterminated_string`, `nominal_base_not_scalar`, `interface_declaration`, `type_alias_declaration`, `distinct_type_declaration`, `legacy_types_import`, `default_parameter`, `optional_parameter`, `default_export`, `mutable_export`, `array_type_alias`, `readonly_array_type_alias`, and `void_type`.
For example, `const a: any = 1;` reports "const declarations must have an initializer" as its last message.
The probes did not trigger `nesting_too_deep`. An entry file with a trailing `/* open` is refused.

An audit stated a probable case: an imported `.ts` with `export let` still compiles under `serve`. The probe refutes this case. That form is refused.

The raw path has other production feeders.
`prepareInlineSource` in `packages/runtime/src/cli_shared.zig` keeps `-e` source that admission refused, and the error path later reports it through the raw parser.
`renderParseRefusal` in `packages/runtime/src/runtime_cli.zig` and `extractVirtualContract` in `packages/zts/src/pipeline.zig` also reach it.
`compile` in `packages/zts/src/compiler.zig` initializes the raw parser. `packages/zts/src/semantics_corpus.zig` calls it, and `zts spec-check` depends on that corpus.
No tracked `.js` file exists under `packages`. Virtual branches in `precompile.zig`, `precompile_check_run.zig`, `precompile_gen_tests.zig`, and `zts_expert_effects.zig` have one tracked test literal, `<routing>`.

Effect: one language has two acceptance rules, and 247 lines of `parse.zig` mention `self.admission`. Source that admission refuses can run. A refused file gets a misleading second message.

Action: unit 9b adds a failing test first. Then the graph and the record refuse at admission, inline source reports the admission diagnostic, and `SourceProfile`, `extractVirtualContract`, and the virtual tool branches go.
Three raw entries stay, and decision D-016 names them: `initExpression` for `kernel_identity`, `initSourceObserver`, and `compile` in `compiler.zig` for the fragments of the semantics corpus. These fragments are not source files.

Risk: `serve -e` text and exit status for refused source, and `module_graph_hash` for refused sources.
Class: B. Size: about 13 production files; deleted lines are not measured.

### N2. Analyzer tests still parse in raw mode

Evidence: Appendix B lists 214 raw constructor sites in 38 files outside `parse.zig` and `parser/root.zig`. The largest are `effect_inference.zig` (55) and `flow_checker_tests.zig` (46).
Most sites are tests or test helpers. Some are the production feeders of N1, and these stay until unit 9b.
`parse.zig` has 136 further text sites. These test the raw mode directly, so they also stay until unit 9b.
Decision D-010 covers typed analyzer tests, but the 2026-10-25 reset moved only the private typed mode.

Effect: these tests prove behavior for a mode that no admitted `.ts` source takes.

Action: classify each site in Phase 0. Move each test site to `initAdmission(.compile)`, one file per commit. Rule on each moved expectation in the worklog.
Risk: none to production. A moved expectation stops the commit until Opus rules on it. Whether expectations move is Probable; the R4 method of the 2026-10-25 reset confirms it.
Class: A. Size: 38 files at most.

### N3. `parse_type_syntax` repeats `admission != null`, and 34 checks are constant

Evidence: `initWithProfile` in `packages/zts/src/parser/parse.zig` has four callers. Only `initAdmission` and `initSourceObserver` pass `true` for `parse_type_syntax`, and both also set a mode. The field has 11 reads.
Six functions test the field in a guard that returns early for the raw mode. After the guard, each `self.admission` check has a constant answer:

| Function | Checks after the guard | Checks that raw mode reaches |
|---|---|---|
| `selectFunctionGeneric` | 10 | 2 (one before the guard, one inside it) |
| `selectArrowGeneric` | 9 | 0 |
| `selectErasedTypePrefix` | 6 | 0 |
| `selectExplicitCall` | 5 | 0 |
| `tryConsumeTypeOnlyModule` | 2 | 0 |
| `tryConsumeTypeDeclaration` | 2 | 0 |

The 34 checks are leftovers of the deleted `initTyped`. Their raw arms, such as the `isPrivateGenericListEligible` test, cannot run.
The 2 checks that raw mode reaches stay. They keep the raw return value of `selectFunctionGeneric`.
`isPrivateErasedPrefixListEligible` has one caller, inside such an arm.

Effect: a reader of the type-syntax paths must reason about arms that no input reaches.
Action: replace each read of the field with the `self.admission` test. Delete the field, the 34 constant checks, their raw arms, and the helper.
Risk: none by reading. The bytecode golden and the digests confirm it.
Class: A. Size: 3 files (`parse.zig`, `type_syntax.zig`, `type_syntax_scan.zig`); lines are not measured.

### N4. Two drivers stamp the same contract facts by hand

Evidence: `compileHandler` in `packages/tools/src/precompile.zig` and `runCheckOnParsedSource` in `packages/tools/src/precompile_check_run.zig` each stamp the same 12 contract fields by hand.
The fields are `state_isolated`, `result_safe`, `optional_safe`, `max_io_depth`, `cost_bounded`, `fault_covered`, `cost_envelope`, `behaviors`, `behaviors_exhaustive`, `fault_coverage`, the fault provenance, and the owned snippet.
The two drivers already differ: `VerificationInfo.unreachable_code` is `has_unreachable` in compile and literal `false` in CHECK.

Effect: each new contract fact needs two edits, which breaks D-011. A missed stamp fails closed, because the defaults are false.

Action: add a value type and one function in `packages/tools`. The function applies verifier, path, and fault facts to a contract and takes ownership of the moved values. Each driver fills the value from its own analysis.
`compileHandler` does not call `analyzeHandlerPaths`, because that function destroys its generator and compile needs the generated tests for its JSONL, fault, and counterexample output.
`unreachable_code` stays a value that each driver supplies, so Phase 5 stays byte-neutral.
The `pipeline.zig` header records a move into `zts` as declined, so the function stays in `tools`.

Risk: contract JSON, the contract digest, and the D-006 read order. A move stops the unit. The compile digests cover standard error and both JSONL files.
Class: A; the `unreachable_code` correction is class B (unit 9c). Size: 2 production files and about 40 stamp lines.

### N5. Test-only paths and tests that compare nothing

Evidence: `expectFunctionSliceRuntimeParity` in `packages/zts/src/typed_frontend_tests.zig` discards two parameters and compares `source` with the source that the same parser holds. The file calls it or its wrapper at 61 sites. No second parse exists.
`buildTestContractForSource` in `packages/tools/src/precompile_contract.zig` has 11 callers and reaches `buildContractOnlyFromParsed`. An audit found that `ContractOnlyOptions.select_flow` has no other non-test caller.
`FlowWithoutHandler` is inert by reading, and validation confirmed this. The flow fields default to false, and `computeProperties` sets `deterministic` from the same `findHandlerFunction` result. `pipeline_tests.zig` asserts the same result for both values. This corrects the v0.26.0 hand-off, which said the two values differ in `deterministic`.

Effect: the names claim parity that no test checks, and a contract path exists for tests alone.
Action: rename the helper for what it validates and drop the discarded parameters. Route the 11 tests through `initSoundExtraction`, and delete `buildContractOnlyFromParsed` and its unused options. Delete `FlowWithoutHandler`, its option fields, and the switch.
Risk: the contract digest, checked by `test-contract-golden`.
Class: A. Size: 3 to 4 files; 61 call sites; about 50 lines deleted.

### N6. Dead and test-only public code

Evidence: Appendix A holds a census of 109 public functions with no production reference. It states its method and gives each row a disposition.
39 rows and 274 lines are for deletion in Phase 2. 4 of these rows have no test reference either.
63 rows stay, with a reason. 7 rows belong to units 9b, 9e, or Decision 2.
The census cannot see a name that another function shares, so Appendix A also lists the items that the audits found by reading.
With a null key, `focusedAchieved` reduces to `result.ok`, so deleting it also closes a residual of the v0.26.0 hand-off.

Effect: tests pin paths that production lacks, and a reader follows dead branches.
Action: confirm each row, then delete it and the tests that exercise only that row.
Risk: reflection that a token census cannot see. A build confirms each row, because Zig `@field` on a missing name is a compile error. No row in the delete set is exported from a `root.zig`, is a member of an exported type, or is named in tracked Markdown outside `docs/plans`.
Class: A. Size: 32 files.

### N7. 27 of 69 `NodeTag` values have no producer

Evidence: `parser/ir_children_tests.zig` rows and the R10b worklog entry. An audit counted 314 non-test text matches in 21 files. `addLoop`, `addSwitch`, `addCase`, `addTry`, and `addLabeled` have only test callers (Appendix A).
`irTableHash` and `semanticsHash` read the alphabet. `semanticsHash` reaches `docs/coverage.json`, `session/protocol_identity.zig`, and the cache key.

Effect: every walk carries arms for nodes that no source can produce.
Action: delete the tags, their constructors, and their arms in one unit. A partial deletion is not useful, because exhaustive switches need the arms while the tags exist.
Risk: the semantics hash and the evidence identity.
Class: B (replay status is Probable; unit 9e measures it). Size: 21 files.

### N8. Legacy type-syntax projections keep old stripper quirks

Evidence: `GenericOwnerCompatibility`, `ErasedTypePrefixCompatibility`, `legacy_recorded_span`, `legacy_ordinary_prefix`, and `.legacy_call`. An audit counted 362 production lines that mention them across 5 files.
`<T> { id: 1 }` records the span `T>`. `<T> (1)` is accepted and erased.
Use: 0 of 262 tracked `.ts` files, and no match in recorded test data by a limited grep pattern.

Effect: each new type form must reason about these spellings.
Action: with an owner decision, refuse them at admission under an existing code, then delete the records and policies.
Risk: the grammar hash, diagnostics, and `test-grammar-drift`.
Class: B. Size: 5 production files; about 500 lines by inference.

### N9. The server never arms the runtime cost fuse that the documents claim

Evidence: the field `cost_ceilings` is set only in `packages/runtime/src/zruntime_tests.zig`, in 3 tests. `recordCostFuseIncidents` in `packages/runtime/src/handler_instance.zig` returns at once when the field is null.
The server, the CLI, and the build do not set it, so `zttp` and `zttp-runtime` never record this incident. An embedding caller can set the field through `RuntimeConfig`.
`docs/verification.md` states the fuse without that condition.
`git log` shows `f2bb0719` added the path without server wiring, and `07f36149` and `273d59d8` deleted the derive step as unused.

Effect: a reader trusts a claim that no shipped binary meets. Tests prove a path that the server does not use.

Action: unit 1b corrects `docs/verification.md`. To wire or to delete the fuse is a product choice, so Decision 2 owns it.
Deletion is class B. It removes a config field and the `CostMeter` export of `root.zig`. Unit 9g lists each file. The deletion must keep the authorization assertions in tests that also read the meter.
Risk of the document correction: none to code. The site has no such claim, by `git grep` in `../ZTTP-WEBSITE`.
Class: A for the correction; B for deletion (unit 9g). Size of deletion: 11 code and allowlist files, including the 116 lines of `cost_meter.zig`; the total line change is not measured.

### N10. Artifact identity has three hand-written copies

Evidence: `Server.observedArtifactIdentity` in `packages/runtime/src/server.zig`, a block in `packages/runtime/src/build_command.zig` with the comment "The same projection", and `verifySemantics` in `packages/runtime/src/proofs/bundle.zig` each build the same five fields.
`identityFromContract` in `packages/runtime/src/artifact_graph.zig` covers only `HandlerContract`. Validation confirmed that `view()` and `rawView()` return the same pointer type.

Effect: the input to acceptance has three producers, and an added field can drift.
Action: add one function over the runtime contract view and call it from the three sites.
Risk: an acceptance verdict, only if a copy already differs. By reading, they do not.
Class: A. Size: 4 files and about 15 lines removed.

### N11. The second checker on the serve path can go

Evidence: Decision 8 (a) of the 2026-10-25 reset kept this path as an exception. New evidence: `ExtractContractOptions.type_check` has 1 production setter, `refuseRetiredSourceImports` in `packages/runtime/src/runtime_cli.zig`.
That function reads the IR view for import declarations and then calls `checker.check`. There are 5 test setters.
The path keeps a second type environment and checker, plus `extractCustomResult` in `packages/zts/src/pipeline.zig`, for one import scan.

Effect: the session keeps two of each analysis state for a check that needs only the import list.

Action (Decision 3): replace the `type_check` option with a hook that takes the IR view. The hook has the same call sites as `type_check`: one call for each module, in graph order, during extraction only. A refusal stops the walk at once. Extraction then takes the default route. Delete `extractCustomResult`.
The 5 test setters move to the hook and keep their assertions: extraction-only timing, the module order `shared, left, right, entry`, the stop after `left`, and the contract bytes.

Risk: serve start exit status and messages.
Stop rule: the sound-mode violation must still come before the retired-module refusal, and each kept assertion must hold.
Class: A with a stop rule. Size: 3 production files and 5 test sites; the line change is not measured.

### N12. Serve flags parse twice, and an ordinary start discovers config more than once

Evidence: `parseServeFeatureFlags` scans raw argv, so a flag value can match. `parseServeArgs` is separate. Three wrapper layers exist: `serveCommand`, `serveCommandWithEnviron`, and `serveCommandWithDebugPanicPath`.
`project_config.discover` has 11 production sites, and `discoverConfiguredPolicy` in `packages/runtime/src/serve_policy.zig` adds another discovery in a start.

Effect: a new serve flag has several homes, and one request reads its config more than once.

Action: `parseServeArgs` returns one request that carries the flags. The discovered config passes down the start path, so an ordinary start reads it once. Delete the raw scan.
Two things stay. `parseAppendedServeArgs` takes a smaller flag set. The `ZTTP_DEBUG_PANIC_PATH` read in `packages/runtime/src/runtime_pool.zig` stays, because `serveAppended` injects no value, so that read is the only source for appended binaries in builds with debug hooks.

Risk: the error order for bad config, and `--watch` given as a flag value. The raw scan treats every `--watch` token as a flag, and `serveCommandWithDebugPanicPath` refuses unavailable watch mode before it parses.
Observed at `1d009062`: `zttp-runtime serve -p --watch nothing.ts` exits 1 with the watch refusal, and `zttp serve --pool --watch examples/handler/handler.ts` exits 1 with `InvalidPoolSize`.
Phase 0 records these cases, and unit 6c keeps each result. A pinned behavior change stops the unit for the owner. Tests cover ordinary, appended, and configured-policy starts.
Class: A. Size: 3 to 5 files; the line change is not measured.

### N14. Expert flags live in separate lists

Evidence: `value_taking_flags` (11) and `parseExpertFlags` in `packages/pi/src/app.zig`, `isExpertBareFlag` (7) in `packages/runtime/src/cli_args.zig`, and `expert_help` in `packages/runtime/src/cli_help.zig`.
Effect: each new flag needs hand edits in several lists. `--gate-log` is in `docs/cli.md` and missing from `expert_help`.
Action: one table with name and takes-value, read by both parsers. Help text stays literal; unit 9a adds `--gate-log`.
Risk: flag-order parsing. Class: A. Size: 2 files and 18 entries.

### N15. Files with several responsibilities remain

Evidence, production lines by `awk`:

| File | Production lines | Responsibilities to separate |
|---|---|---|
| `packages/zts/src/flow_interp.zig` | 6,536 | Value model and rule tables, about 1,574 lines, before the `FlowInterp` type |
| `packages/pi/src/agent.zig` | 2,172 | Bootstrap 321, compaction 297, request admission 371, fork and rebuild 196 |
| `packages/runtime/src/server.zig` | 1,477 before the first test | Activation and swap helpers 393 lines, and the activation part of `Server.start` |
| `packages/runtime/src/build_command.zig` | 1,404 | Compile, build, and deploy |

Effect: a reader cannot find the activation order or the flow value model in one place.
Action: code motion only, one commit per file. Zig has no partial struct, so `Parser`, `TypeChecker`, `PathGenerator`, and `ContractBuilder` stay whole.
Risk: gates that read a file by path or text. See [the file split lesson](../solutions/conventions/a-file-split-proven-by-its-graph-broke-the-gates-that-read-it-as-text.md).
A passing gate does not prove that the gate still scans the moved code. So each unit updates the gate input and runs a rejection probe. `check-runtime-purity.sh` has a fixed scan list. `check-proof-swallow.sh` has a fixed file list, and `proof-swallow.allow` has 0 rows for `flow_interp.zig`.
Class: A. Size: 4 files to about 11.

### N17. Status documents lag the code

Evidence:
- `docs/roadmap.md` says "Next work: the v0.26.0 plan", lists Decision 2 as open, and has a 6,515-byte section "Reset And Simplification" of history. Release v0.26.0 is published.
- `docs/plans/README.md` still marks v0.26.0 and the release fixes as "Active authority". Its reset row names the 2026-10-25 plan.
- `docs/zts-formal-spec-northstar-advanced.md` is the normative spec for two gates and the agent protocol, but its name says northstar and its header says "Grounded against ZTS 0.19.0".
- `docs/internals/testing.md` says `scripts/verify.sh` runs `-j1`. `tooling/verify.zig` owns that rule.
- `STRATEGY.md` has `last_updated: 2026-08-31`.
- Eight `ZTTP_*` variables are undocumented: `CODEGEN_LOCAL_RUNTIME`, `CODEGEN_MODEL_REVISION`, `DEBUG_PANIC_PATH`, `EVIDENCE_PUBLISH`, `PROBE_ALLOWED`, `PROBE_DENIED`, `WRITE_BYTECODE_GOLDEN`, and `ZIG_EXE`.
- Eight public forms have no doc hit: `proofs list`, `proofs watch`, `auth status`, `attest`, `init --extension`, `--module-manifest`, `--simulate`, and `--markdown`.
- The hand-off text for `CLAUDE.md` about the `.value` of `requestJson` is not applied.

Effect: an agent cannot find the current authority in one read, and a user cannot find a public form.
Action: Phase 1 fixes status and authority. Phase 10 fixes the rest.
Risk: none to code. `test-doc-links`, `test-docs-drift`, and `check-spine` check links and anchors. The site links to `docs/roadmap.md#agent-compiler-agenda`, so that anchor stays.
Class: A.

### N18. Archived-plan pointers resolve only on this machine

Evidence: 175 lines in tracked Markdown cite paths in tags such as `pre-rebase`, `pre-round-2-archive`, `pre-round-3-archive`, and `pre-reset-archive-2026-10-25`. `git ls-remote --tags origin` lists 56 refs and none of these four tags.

Effect: a fresh clone cannot follow a pointer, and the roadmap and plan index carry 48 of them.
Action: Decision 6. The owner pushes the four tags, or the pointers stay local. The reset does not rewrite the 175 lines.
Risk: a push publishes the archived plans. Class: A; no repository file changes.

### N19. Root instructions are large, and each agent session reads them

Evidence: `AGENTS.md` has 27,364 bytes. "Testing Guidelines" holds 11,642 bytes, and two of its bullets hold 2,661 and 2,507 bytes. The generated gate and area tables hold 12,105 bytes.
Five bullets mix a rule with incident history: proof swallow, gate floors, declassifiers, rule seeds, and persistent reads.

Effect: every agent pays for the history on every turn, and a rule is hard to find in it.
Action: keep each rule as one short bullet with a link. Move the history to the area contract or the existing solution note. Rule text does not weaken: each moved sentence lands in a named file, and the worklog lists the moves.
Risk: `check-docs-drift.sh` reads row-count claims only from `AGENTS.md` and `CLAUDE.md`, and it requires at least one claim. Those claims stay in `AGENTS.md`. `check-spine` reads the generated blocks, which stay.
Class: A.

### N20. Two checks depend on inputs that the build graph does not declare

Evidence: `update-convergence.sh` and `update-coverage.sh` set `ZTTP_EVIDENCE_PUBLISH=1`. The build does not declare that variable as an input, so a warm cache skips the replay and the script fails with `MissingOrDuplicateMarker`. The owner saw this on 2026-10-26.
`packages/tools/src/bytecode_identity_golden.zig` reads handler sources under `examples/` and `tests/corpus/check/good/` at run time and embeds only the golden text. A cached pass after a source edit can therefore be stale. `precompile.zig` imports the test, so five aggregate roots collect it.

Effect: a publish needs an empty cache by convention, and a protection gate can report a stale pass.
Action: make the expert test step rerun when `ZTTP_EVIDENCE_PUBLISH` is set. Move the golden check from a test into a gate executable with `has_side_effects = true`, the pattern of `build/flow_census.zig`. That gate runs once in the aggregate.
Risk: the golden file and its write mode must not change. The aggregate test count falls because 5 collected copies become one gate; the worklog states the new count.
Class: A. Size: 3 to 4 files in `build/`, `agents.json`, and the golden file's Zig source.

### Stale text that needs an owner window

These corrections belong to units 9a and 9d. Each one moves protected text.

- `init_command.zig`: the extension README says to run `zts check` with `--module-manifest`, but `zts check` rejects that flag. `zts compile` accepts it through `precompile_cli.zig`.
- `cli_help.zig`: `expert_help` advertises `zttp proofs export --session`, which `exportCommand` refuses.
- `runtime_help_text` in `runtime_cli.zig` says `zttp attest` and points expert users to `zts`.
- `packages/modules/src/net/fetch.zig`: a summary describes `AgentTurnRefused`, which no code produces. It reaches the model through `agent_protocol_meta.zig`.

### Findings considered and excluded

- N13, provider helpers: withdrawn. Seven helpers have the same text, but they bind different file constants: default URLs, completion paths, `validateBaseUrl` rules, and `reasoning_rule`. `parseSanitizedResponseWithInspection` already delegates to `providers/response_sanitize.zig`, so a sanitize fix does not need two edits.
- N16, moving gate roots out of `packages/tools`: withdrawn. `precompile.zig` imports `flow_false_proofs.zig` and `flow_precision_expectations.zig` as test files, and these import `precompile.zig` back. A move needs a new module design, and it removes the code from the module-boundary scan, which skips `tooling/`. The gain is location only.
- Splitting `expert_codegen_record.zig`: no offline gate runs its live recorder path, so a motion error appears only at the next paid re-record. `check-convergence-emitter.sh` also fixes the producer path to that file.
- Narrowing the embedding API: 18 unused public members of exported types stay, because the preservation contract protects them. Their removal needs its own owner decision and a release note.
- `--module-manifest` as dead code: refuted. An audit called it a dead end, but `runCompileWithArgs` in `precompile_cli.zig` reads and registers manifests. Only the README text is wrong.
- `export let` through `serve`: refuted by probe (see N1).
- `DEEPSEEK_API_KEY` alone turning a test live: refuted at HEAD. The recorder test needs `ZTTP_CODEGEN_RECORD=1`. The common rules still scrub both.
- `instruction_counter.zig` as retired code: refuted. "Retired" means retired CPU instructions. `diagnostic_corpus_gate.zig` uses it.
- F2, F4, F8, and F9 of the 2026-10-25 reset: landed, with no new copies. 5 of 6 `formatDiagnostics` forward one line to the projection.
- The `ModuleAnalysisSession` shape: 27 fields, accepted by that reset's Decision 8. N11 removes only the custom branch.
- 38 `else => {}` in production regions: sampled walks carry `exhaustive:` reasons.
- Splitting `Parser`, `TypeChecker`, `PathGenerator`, and `ContractBuilder`: Zig has no partial struct, so a split is not pure motion.
- One identity for all version constants: each hand-set constant has one owner, and a merge moves the policy hash for no gained fact.
- Fixture dedupe: long fixture line overlap is 1 of 492, 0 of 55, and 28 of 708.
- Porting shell gates to Zig: no defect, and a large risk. D-001 applies to new tooling.
- One expert loop: already true. `runOneTurnWithClient` and the recorder both reach `runTurnWith`.
- Proof surface: `proof_activation.accept` is the one acceptance, and `zttp-bundle-3` is the one bundle format.
- Package dependency order: no cycle. The `witness_replay.setReplayFn` inversion has one setter.
- `sdk` `test_shim.zig`: a required double, because modules cannot import `zts`.
- Process-wide state in pi: the 2026-10-25 reset measured no link to the macOS `-j1` need.
- The six policy pins in `check-meta-drift.sh` and the hash in five expert goldens: a placeholder moves protected files for a small gain.
- Module test coverage for `env`, `crypto`, and `sql`: an audit did not measure it. New test work is out of scope.

## Phases

Each phase is one reviewable unit. A phase with sub-phases commits each sub-phase on its own.
Phases run in numerical order, except for the parallel work named below. The owner can stop after any phase and keep a working base.

| Phase | Findings | Class | Depends on |
|---|---|---|---|
| 0. Baseline and preservation evidence | none | A | clean tree, this plan committed |
| 1. Authority documents | N9 (document), N17 (status part) | A | 0 |
| 2. Delete dead and test-only code | N5, N6 | A | 0 |
| 3. Tests on the production parse mode | N2 | A | 2c |
| 4. One parser flag | N3 | A | 0 |
| 5. One contract finisher | N4 | A | 2c |
| 6. One fact in the runtime and the expert | N10, N11, N12, N14 | A | 2 |
| 7. Motion-only splits | N15 | A | 2, 6a, 6c |
| 8. Build inputs | N20 | A | 0 |
| 9. Owner-gated corrections | N1, N7, N8, N9 (deletion), stale text | B | each selected unit of Phases 2 to 8, and each unit by decision |
| 10. Documentation of the final design | N17, N19 | A | 8, and 9 if it ran |
| 11. Final gate | none | A | 10 |

Parallel work. Units 2a and 2b touch separate packages, so two workers can run them in worktrees cut from local `main`.
Phase 3 and Phase 5 touch separate files after 2c and can also run in parallel.
Phases 4, 7, and 9 run alone, to keep the digest and the motion review exact.
After each cherry-pick, Opus reruns the touched suites on `main`.

Each unit below lists its model, files, acceptance check, and turn budget. A budget is a limit, not an estimate.
At the limit the implementer stops and hands back its status and open items.
"Live source" below means the pathspec `'packages/*' 'build/*' 'build.zig' 'tooling/*' 'scripts/*'`. Exit checks search live source only, so dated plans and this document keep their history.

### Phase 0. Baseline and preservation evidence

Precondition: this plan is committed, and no other session is active.

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| 0a. Baseline | Opus | Worklog only | Mandatory steps exit 0; the worklog holds each result | 30 |

Mandatory steps:

1. Confirm that `git status --porcelain` prints nothing on local `main`. Create the scratch directory, the log directory, and the worklog. Record the base commit and tree hash.
2. Run `bash scripts/verify.sh` once. Record the exit status, the wall time, and the test count and skip count of each named step.
3. Save the script in "Common rules" as `$R/digest.sh`. Record `$R/inputs.z` once. Run `bash $R/digest.sh phase0`, then run `bash $R/digest.sh phase0b`. The second run must exit 0.
4. Record the surface digests. Hash the standard output, standard error, and exit status of `zttp --help`, `zttp help --all`, `zts --help`, `zttp-runtime --help`, and `--help` for each verb in the `commands` tables of `dev_cli.zig` and `zts_cli.zig`. Run them twice and compare.
5. Record the admission probe table. Use 18 sources, one for each form of `AdmissionFailure`. For each source, save the `serve` and `zts check` results for an imported file and for the entry file. Use `/usr/bin/curl < /dev/null`. Stop each server. Find a source that triggers `nesting_too_deep`, or record why none does.
6. Repeat the Appendix A census and the Appendix B inventory, and apply the disposition rules again. A new row needs a disposition before its unit starts.
7. Classify each Appendix B site as test, test helper, or production feeder.
8. Confirm that `scripts/proof-swallow.allow` has 0 rows for `flow_interp.zig`. If a row exists, unit 7b stops for a ruling.
9. Record the serve flag cases. For each case, save standard error and the exit status. The cases are `zttp-runtime serve -p --watch nothing.ts`, `zttp serve --pool --watch examples/handler/handler.ts`, `zttp dev --pool --watch examples/handler/handler.ts`, and `zttp serve --pool --watch` in a directory with an invalid `zttp.json`.

Advisory step, which cannot fail the phase: run `zig build bench-check -Doptimize=fast` with the load average under 4 and record it. The committed baseline is stale for this host (Decision 10 of the 2026-10-25 reset).

If a digest file is lost, rebuild it from a detached worktree at the Phase 0 base.

### Phase 1. Authority documents

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| 1a. Status | Sonnet | `docs/roadmap.md`, `docs/plans/README.md`, `docs/README.md` | One active reset authority in each document | 20 |
| 1b. Fuse claim | Sonnet | `docs/verification.md`, `docs/roadmap.md` | The sentence states that only a caller that sets `cost_ceilings` gets the fuse, and that the server does not set it | 5 |

Unit 1a steps:

1. Name this plan as the reset authority in the roadmap and the plan index. Mark the 2026-10-25 plan complete.
2. Mark v0.26.0 and the release fixes complete in the index. Remove "Next work: the v0.26.0 plan" and the open Decision 2 text.
3. Replace the roadmap section "Reset And Simplification" with a short list of completed work and links. Keep each fact that no other document holds.

Exit check: `git grep -n 'Active authority' docs/plans/README.md` prints only this plan. `git grep -n 'Next work: the' docs/roadmap.md` prints nothing about v0.26.0.

### Phase 2. Delete dead and test-only code

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| 2a. Analyzer and tools | Sonnet | Rows marked 2a in Appendix A, and the list after the appendix table | Each row has no reference in live source; digests equal Phase 0 | 40 |
| 2b. Runtime and expert | Sonnet | Rows marked 2b in Appendix A, and the list after the appendix table | Same | 40 |
| 2c. Test-only contract path and parity names | Sonnet | `typed_frontend_tests.zig`, `precompile_contract.zig`, `pipeline.zig`, `pipeline_tests.zig` | `buildContractOnlyFromParsed` and `FlowWithoutHandler` have no match in live source; no test name or comment claims parity | 40 |

Units 2a and 2b commit by area: interpreter core, parser, analyzer, tools, runtime, and expert.
A test removed in this phase tests only deleted code. The worklog lists each removed test and its reason.
Stop rule: a row that the build still needs goes back to Appendix A with its reason. A deletion that empties a named suite or drops a gate input under its floor stops the unit. `tooling/nonempty_test_runner.zig` and the floor of each gate report this.

### Phase 3. Tests on the production parse mode

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| 3a. `effect_inference.zig` | Sonnet | That file | Each test site uses `initAdmission(.compile)`; test count equal | 30 |
| 3b. `flow_checker_tests.zig` | Sonnet | That file | Same | 30 |
| 3c. Remaining files | Sonnet | Other Appendix B files, one commit per file | Each Appendix B site uses `initAdmission(.compile)` or is a production feeder in the worklog | 60 |

Method: change one file, run its suite, and write each moved expectation in the worklog.
Opus rules on each one. A source that admission refuses stays only if the refusal is what the test asserts.
Stop rule: production code does not change in this phase. A test that needs a production change stops the unit for the owner.

### Phase 4. One parser flag

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| 4a. Remove `parse_type_syntax` | Sonnet | `parser/parse.zig`, `parser/type_syntax.zig`, `parser/type_syntax_scan.zig` | The field has no match in live source; the 34 constant checks are gone; the 2 reachable checks stay; digests and bytecode golden equal Phase 0 | 40 |

Stop rule: any digest or golden difference.

### Phase 5. One contract finisher

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| 5a. One completion function | Sonnet | `precompile.zig`, `precompile_check_run.zig`, one file that `scripts/check-proof-swallow.sh` lists | Neither driver assigns the 12 fields directly; check and compile digests equal Phase 0 | 30 |

Each driver keeps its analysis, its generator, and its output. Only the assignment moves.
Stop rule: any change to the contract digest, the compile digests, or the D-006 read order.

### Phase 6. One fact in the runtime and the expert

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| 6a. Artifact identity (N10) | Sonnet | `artifact_graph.zig`, `server.zig`, `build_command.zig`, `proofs/bundle.zig` | One projection remains | 15 |
| 6b. Second checker (N11, Decision 3) | Sonnet | `runtime_cli.zig`, `pipeline.zig`, `precompile_contract.zig`, `pipeline_tests.zig` | `extractCustomResult` has no match in live source; each kept assertion holds; admission probe table and surface digests equal Phase 0 | 40 |
| 6c. Serve request (N12) | Sonnet | `runtime_cli.zig`, `serve_policy.zig`, `cli_shared.zig`, the matching tests | `parseServeFeatureFlags` has no match in live source; an ordinary start discovers config once, by review | 40 |
| 6d. Expert flags (N14) | Sonnet | `packages/pi/src/app.zig`, `packages/runtime/src/cli_args.zig` | One table; surface digests equal Phase 0 | 15 |

Stop rule for 6b and 6c: a change in the order or text of a startup refusal.

### Phase 7. Motion-only splits

Before each unit, run `git grep -n <file name> -- scripts tooling build agents.json docs/internals` and list each hit in the worklog. A hit that names the moved code is updated in the same commit.

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| 7a. Activation | Sonnet | `server.zig`, new `server_activation.zig`, `scripts/check-runtime-purity.sh` | `Server.start` calls one activation function; the purity gate scans the new file; a scratch copy with `@import("zts")` in the new file fails the gate | 25 |
| 7b. Flow value model | Sonnet | `flow_interp.zig`, new sibling files, `scripts/check-proof-swallow.sh`, `scripts/zts-tiers.allow` | New files are in each list; `scripts/proof-swallow.allow` does not change; a scratch swallow in a new file fails the gate | 25 |
| 7c. Agent | Sonnet | `agent.zig`, new sibling files | The four named blocks left `agent.zig` | 30 |
| 7d. Build command | Sonnet | `build_command.zig`, new sibling files, `tooling/production_branch_metric.zig` if the grep names it | Compile, build, and deploy are in separate files | 25 |

Each commit holds motion only. The only allowed text edits are `pub`, imports, and file header comments, plus the gate inputs that the unit names.
The reviewer runs `git show --color-moved=dimmed-zebra` and reads each line that is not dimmed.

### Phase 8. Build inputs

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| 8a. Publish input | Sonnet | `build/*.zig` | Warm-cache convergence and coverage publishes no longer fail with `MissingOrDuplicateMarker` | 20 |
| 8b. Bytecode golden gate | Sonnet | `build/*.zig`, `packages/tools/src/bytecode_identity_golden.zig`, `packages/tools/src/precompile.zig`, `agents.json`, generated `AGENTS.md` block | One gate run in the aggregate; the mutation probes below fail | 25 |

Probes run on a scratch clone, and each probe's output is discarded.
For 8a: run `scripts/update-convergence.sh` and then `scripts/update-coverage.sh` with a warm cache. Each must complete.
For 8b: with a warm cache, change a handler body, change a file that a handler imports, and add a new handler. Each change must make the gate fail with "bytecode identity drift" or its existing untracked-file error.
Stop rule: a change to `bytecode_identity_golden.txt` or to its digests.

### Phase 9. Owner-gated corrections

Each unit runs only after the decision that names it.
Before each unit, measure with the offline replay: `zig build test-expert-app`.
A unit that fails replay waits for a re-record window under D-012 (Decision 5).

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| 9a. CLI text corrections | Sonnet | `init_command.zig`, `cli_help.zig`, `runtime_cli.zig` (`runtime_help_text`) | Each corrected line matches the behavior; the surface digest moves only for those lines | 15 |
| 9b. One language path (N1, Decision 4) | Opus plans, Sonnet implements | About 13 files | See below | 60 |
| 9c. `unreachable_code` in CHECK | Sonnet | `precompile_check_run.zig`, the 5a function | A test with an unreachable statement fails before and passes after; both drivers supply the same value | 15 |
| 9d. Fetch summary | Sonnet | `packages/modules/src/net/fetch.zig`, generated module spec | `AgentTurnRefused` has no match in live source | 10 |
| 9e. `NodeTag` removal (N7) | Sonnet | 21 files | No unproduced tag remains | 40 |
| 9f. Legacy spellings (N8, Decision 5) | Opus plans, Sonnet implements | 5 production files | Census shows no tracked use; `GenericOwnerCompatibility` has no match in live source | 40 |
| 9g. Fuse deletion (Decision 2, option b) | Sonnet | In `packages/zts/src`: `cost_meter.zig`, `context.zig`, `root.zig`, `module_binding/bridge.zig`, `module_binding/capabilities.zig`, `modules/internal/resolver.zig`. In `packages/runtime/src`: `runtime_config.zig`, `contract_runtime.zig`, `handler_instance.zig`, `zruntime_tests.zig`. Also `scripts/zts-tiers.allow`, `docs/verification.md`, `CHANGELOG.md` | `cost_ceilings` and `CostMeter` have no match in live source; each authorization assertion stays | 25 |

Unit 9b steps:

1. Write the failing test: a handler that imports a `.ts` file with a trailing `/* open` must be refused. Confirm that it fails for this reason.
2. Make `selectSourceProfile` and `collectImports` refuse at admission. Change the test "graph source selection bounds every hard admission producer" to assert the refusal.
3. Report the admission diagnostic for `-e` source that admission refuses.
4. Delete `SourceProfile`, `extractVirtualContract`, `compileWithOptions`, and the virtual tool branches.
5. Keep `compile` in `compiler.zig` for the semantics corpus. Run `bash scripts/check-semantics-spec.sh`.
6. Move the `parse.zig` raw tests to the kept entries, or delete the tests of deleted paths with a reason.
7. Add decision D-016 to `docs/decisions.md`: every source file and every `-e` source passes admission, with the three raw entries named as exceptions.
8. Compare the admission probe table with Phase 0. The moved rows must be the rows that the owner accepted.

The owner runs any re-record. The auto-mode classifier refuses the recorder command for an agent, and the recorder refuses a partial run.
The agent hands over the one-case validation command, then the full command, then the pin diff, as `!` lines. The `zttp-models` skill holds the command forms.

### Phase 10. Documentation of the final design

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| 10a. Architecture | Sonnet | `docs/internals/architecture.md`, `CONCEPTS.md`, `docs/decisions.md` | Each row of the target design table names the real owner; a deferred row is marked deferred | 25 |
| 10b. Root instructions (N19) | Opus | `AGENTS.md`, area `AGENTS.md` files, solution notes | Worklog lists each moved sentence and its new file; `wc -c AGENTS.md` is recorded; row-count claims stay in `AGENTS.md` | 25 |
| 10c. Spec name | Sonnet | `docs/zts-formal-spec-northstar-advanced.md` to `docs/spec/zts-model-1.md`, the 12 files that name it, header | `git grep -n northstar-advanced` prints only dated plans; `test-grammar-drift` and `test-idiom-table` pass | 20 |
| 10d. Public forms, variables, and strategy | Sonnet | `docs/cli.md`, `docs/internals/testing.md`, `CLAUDE.md`, `STRATEGY.md` | Each N17 form and variable has one documented home; `STRATEGY.md` states no false fact about the final design, and its direction does not change | 20 |
| 10e. Site check | Opus | `../ZTTP-WEBSITE`, read only unless a claim is false | Each site link to a moved document still resolves; a false claim gets a local site commit after `deno task verify` | 10 |

Rule: Phase 10 documents what landed. A deferred class B item is listed in the roadmap as open, not as done.
Move a dated plan that the reset closed to a new archive tag only if Decision 6 selects that. The plan index otherwise keeps its row.

### Phase 11. Final gate

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| 11a. Final | Opus | Plan status, worklog, roadmap | All commands below exit 0 | 15 |

Run `bash scripts/verify.sh` from an empty local cache, with the scrubbed environment.
Compare the check, compile, and surface digests with Phase 0. Each difference must trace to a class B unit in the worklog.
Update the plan status. The roadmap states that the reset is closed.
Evidence republish is not part of this phase. `release-provenance` stays a release gate, and the next release runs it.

## Verification

### Common rules

Every phase uses a private cache and an offline environment. These commands run in `bash`:

```bash
R=/private/tmp/claude-501/zttp-reset-20261030
export ZIG_LOCAL_CACHE_DIR="$R/local" ZIG_GLOBAL_CACHE_DIR="$R/global"
for v in $(env | /usr/bin/grep -E '^(ZTTP_|DEEPSEEK_)' | cut -d= -f1); do unset "$v"; done
mkdir -p "$R/logs"
test -z "$(env | /usr/bin/grep -E '^(ZTTP_|DEEPSEEK_)')"
```

Each aggregate must report the Phase 0 skip count, so a live recorder test that starts to run is visible.
Each command writes its output to a log file. The verdict is the direct exit status of the build, not a grep and not the status of a pipe:

```bash
zig build test-zts > "$R/logs/test-zts.log" 2>&1; status=$?; echo "exit=$status"
```

A filtered run (`-Dtest-filter`) is never evidence. "failed command" for a passing step is not a failure; read the Build Summary and the leaf failures.
The implementer runs `git add` before `zig build check-spine`, because the spine reads tracked files only.
A commit runs only after a saved status equals 0.
Documents cite a file or a top-level symbol, never a file and line number.
Workers use worktrees cut from local `main`, a private cache for each worktree, and `command rm`, `command cp`, and `command mv`.

Every class A unit ends with this protection check against the unit base commit:

```bash
git diff --exit-code <unit-base> -- examples packages/tools/tests/fixtures tests/corpus \
  packages/pi/src/simulator/testdata packages/pi/src/prompts \
  packages/pi/src/standin/defect_seeds.zig \
  packages/zts/src/fixtures packages/modules/module-specs tooling/fixtures \
  policy-hash.txt scripts/check-meta-drift.sh docs/convergence.json docs/convergence.md \
  docs/coverage.json docs/coverage.md benchmarks/perf-baseline.json \
  packages/tools/src/bytecode_identity_golden.txt
```

Phase 0 records the input list once. A later unit never rebuilds it:

```bash
git ls-files -z 'tests/corpus/**.ts' 'examples/**.ts' > "$R/inputs.z"
```

Every unit in Phases 2 to 8 runs `bash $R/digest.sh <unit>` after `zig build` exits 0, from the repository root. Phase 0 saves this script:

```bash
# Usage: bash digest.sh <unit>. Run from the repository root after `zig build` exits 0.
set -euo pipefail
R=${R:-/private/tmp/claude-501/zttp-reset-20261030}
ZTS=${ZTS:-./zig-out/bin/zts}
unit=$1; out="$R/digests/$unit"; mkdir -p "$out"; : > "$out/check.txt"; : > "$out/compile.txt"
while IFS= read -r -d '' f; do
  code=0; "$ZTS" check "$f" --json --contract > "$out/o" 2> "$out/e" < /dev/null || code=$?
  so=$(shasum -a 256 < "$out/o" | cut -d' ' -f1)
  se=$(shasum -a 256 < "$out/e" | cut -d' ' -f1)
  printf '%s\t%s\t%s\t%s\n' "$f" "$code" "$so" "$se" >> "$out/check.txt"
  d="$R/c"; command rm -rf "$d"; mkdir -p "$d"
  code=0; "$ZTS" compile --verify --contract "$f" "$d/out.zig" > "$d/stdout" 2> "$d/stderr" < /dev/null || code=$?
  tree=$(cd "$d" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
  printf '%s\t%s\t%s\n' "$f" "$code" "$tree" >> "$out/compile.txt"
done < "$R/inputs.z"
count=$(tr -cd '\0' < "$R/inputs.z" | wc -c)
test "$count" -eq 215
test "$(wc -l < "$out/check.txt")" -eq "$count"
test "$(wc -l < "$out/compile.txt")" -eq "$count"
test "$(cut -f2 "$out/check.txt" | sort -u | tr -d '\n')" = 01
test "$(cut -f2 "$out/compile.txt" | sort -u | tr -d '\n')" = 01
if [ "$unit" != phase0 ]; then
  command cmp "$R/digests/phase0/check.txt" "$out/check.txt"
  command cmp "$R/digests/phase0/compile.txt" "$out/compile.txt"
fi
```

The script stops at the first failed hash, so a failed hash cannot produce a passing digest. The fixed `$R/c` path keeps output paths equal across units.
The script asserts a floor on its own input: 215 inputs, and both exit values in each file. `cmp` then holds each later unit to the Phase 0 exit counts.
The compile loop runs for each input, including refused sources, so refusal output is covered. Measured at `1d009062` with a private build: two full runs were byte-identical and took 23 seconds together. `zts check` gave exit 0 for 73 inputs and exit 1 for 142. `zts compile` gave exit 0 for 98 and exit 1 for 117.

Units 6b, 6c, 6d, 7a, and 7d also compare the surface digests.
Every unit ends with `zig build test` and `zig build check-spine`, both exit 0.
The test count of each named step equals Phase 0, or the worklog explains each change.
`bench-check` fails under host load. Run it only when the load average is under 4, and record the load. It is advisory in every phase.

### Phase gates

| Unit | Exact additional commands, each exit 0 |
|---|---|
| 0a | `bash scripts/verify.sh`; `zig build test-precompile` from an empty cache; `cmp` of each digest pair |
| 1a, 1b | `zig build test-doc-links`; `zig build test-docs-drift` |
| 2a | `zig build test-zts`; `zig build test-precompile`; `zig build test-zts-layering`; `zig build test-module-boundary`; `zig build test-proof-swallow`; `zig build test-cli`; `zig build test-zruntime` |
| 2b | `zig build test-cli`; `zig build test-zruntime`; `zig build test-server`; `zig build test-expert-app`; `zig build test-cassette`; `zig build test-simulator`; `zig build test-standin` |
| 2c | `zig build test-zts`; `zig build test-precompile`; `zig build test-contract-golden`; `zig build test-cli` |
| 3a to 3c | `zig build test-zts`; `zig build test-zts-cli`; `zig build test-diagnostic-corpus`; `zig build test-standin`; `zig build test-precompile`; `zig build test-flow-census` |
| 4a | `zig build test-zts`; `zig build test-diagnostic-corpus`; `zig build test-contract-golden`; `zig build test-grammar-drift`; `zig build test-meta-drift`; `zig build test-zruntime`; `zig build test-examples`; `zig build test-proof-checker`; `zig build test-proof-swallow` |
| 5a | `zig build test-precompile`; `zig build test-contract-golden`; `zig build test-agent-protocol`; `zig build test-proof-swallow`; `zig build test-flow-census`; `zig build test-cli`; `zig build test-zruntime`; `zig build test-expert-app` |
| 6a | `zig build test-zruntime`; `zig build test-server`; `zig build test-cli`; `zig build test-proof-checker` |
| 6b | `zig build test-zts`; `zig build test-precompile`; `zig build test-cli`; `zig build test-zruntime`; `zig build test-server`; `zig build smoke-v1` |
| 6c | `zig build test-cli`; `zig build test-zruntime`; `zig build test-server`; `zig build test-panic-isolation`; `zig build smoke-v1` |
| 6d | `zig build test-cli`; `zig build test-expert`; `zig build test-expert-app` |
| 7a | `zig build test-server`; `zig build test-zruntime`; `zig build test-panic-isolation`; `zig build test-runtime-purity` |
| 7b | `zig build test-zts`; `zig build test-flow-census`; `zig build test-proof-swallow`; `zig build test-zts-layering`; `zig build test-module-boundary` |
| 7c | `zig build test-expert-app`; `zig build test-standin`; `zig build test-cassette`; `zig build test-module-boundary` |
| 7d | `zig build test-cli`; `zig build smoke-v1`; `zig build test-production-branch-metric`; `zig build test-module-boundary` |
| 8a | `zig build test-evidence-marker`; `zig build test-evidence-publish`; `zig build test-convergence-emitter`; `zig build test-expert-app` |
| 8b | `zig build test-step-coverage`; `zig build test-spine`; `zig build test-precompile`; `zig build test-script-reachability`; `zig build test-docs-drift` |
| 9a | `zig build test-cli`; `zig build test-docs-drift`; `bash scripts/verify.sh` |
| 9b | `zig build test-zts`; `zig build test-precompile`; `zig build test-agent-protocol`; `zig build test-module-graph-record`; `zig build test-cli`; `zig build test-zruntime`; `zig build test-server`; `zig build test-expert-app`; `zig build test-diagnostic-corpus`; `zig build test-spine`; `bash scripts/check-semantics-spec.sh`; `bash scripts/verify.sh` |
| 9c | `zig build test-precompile`; `zig build test-contract-golden`; `zig build test-expert-golden`; `zig build test-expert-app` |
| 9d | `zig build test-modules`; `zig build test-docs-drift`; `zig build test-meta-drift`; `zig build test-expert-golden`; `zig build test-expert-app` |
| 9e | `zig build test-zts`; `zig build test-flow-census`; `zig build test-proof-swallow`; `zig build test-meta-drift`; `zig build test-zruntime`; `zig build test-expert-app`; `bash scripts/verify.sh` |
| 9f | `zig build test-zts`; `zig build test-grammar-drift`; `zig build test-diagnostic-corpus`; `zig build test-meta-drift`; `zig build test-expert-app`; `bash scripts/verify.sh` |
| 9g | `zig build test-zruntime`; `zig build test-zts`; `zig build test-modules`; `zig build test-server`; `zig build test-zts-layering`; `zig build test-capability-audit`; `zig build test-doc-links`; `bash scripts/verify.sh` |
| 10a, 10d | `zig build test-doc-links`; `zig build test-docs-drift` |
| 10b | `zig build test-doc-links`; `zig build test-docs-drift`; `zig build test-spine`; `zig build brief -- packages/zts/src/flow_interp.zig` |
| 10c | `zig build test-doc-links`; `zig build test-grammar-drift`; `zig build test-idiom-table`; `zig build test-docs-drift` |
| 10e | `deno task verify` in `../ZTTP-WEBSITE`, only if a site file changes |
| 11a | `bash scripts/verify.sh` from an empty cache; `cmp` of each digest pair, with differences traced |

## Execution rules

Opus dispatches each Sonnet unit with the unit text, the common rules, and the private cache paths.
Opus reviews each diff line by line, runs the unit gates itself, and commits each unit on local `main`.
Claims from an implementer are not evidence.
Commit bodies state that a bug test failed without its fix.
A unit that fails its gates twice goes to a Fable or Codex astra advisor with the evidence before a third attempt.
No push, tag push, provider call, or corpus re-record is authorized by this plan.
No worker edits a file that this plan does not name, except a mechanical reference update that the build requires. The worklog lists each one.

## Owner decisions

Decision 1: scope. What approval authorizes.
- (a) Recommended. Authorize Phases 0 to 8, 10, and 11, all class A. Phase 9 units run only as Decisions 2, 4, and 5 select.
- (b) Authorize Phases 0 to 2 only, then stop for review.
- (c) Authorize no phase. Keep this document as a findings record.

Decision 2: the runtime cost fuse (N9). Unit 1b corrects the claim under every option.
- (a) Recommended. Keep the code. The roadmap lists "wire or delete the fuse" as an open product question. To wire or to delete is a product choice, and the preservation rule favors the path that removes nothing.
- (b) Delete the fuse, its field, and the `CostMeter` export in unit 9g. This is a class B break for any Zig embedder that sets the field. No tracked caller does.
- (c) Wire the fuse. This is new runtime behavior, so it leaves this plan and gets its own plan.

Decision 3: the second checker that Decision 8 (a) of the 2026-10-25 reset kept (N11).
- (a) Recommended. Reopen that decision and run unit 6b.
- (b) Keep the exception. Skip unit 6b.

Decision 4: one language path (N1, unit 9b). This fixes the case where a refused imported file serves traffic.
- (a) Recommended. Run unit 9b in this reset. A refused import fails at start, and each refused form keeps one admission message. If replay fails, the unit waits for the window under Decision 5.
- (b) Run only steps 1 and 2 of unit 9b. The raw parser stays for inline errors.
- (c) Defer unit 9b. The defect stays open in the roadmap.

Decision 5: the other class B units (9a, 9c, 9d, 9e, 9f).
- (a) Recommended. Run each unit that keeps the offline replay green. A unit that fails replay waits for the next D-012 window and goes to the roadmap. Unit 9f also needs the Phase 0 census to show no use.
- (b) Open a window in this reset. All units run, and the owner runs one DeepSeek re-record.
- (c) Defer all of them to the next release.

Decision 6: archive tags (N18).
- (a) Recommended. The owner pushes `pre-rebase`, `pre-round-2-archive`, `pre-round-3-archive`, and `pre-reset-archive-2026-10-25`. This publishes the archived plans. Closed plans of this reset then move to a new archive tag.
- (b) The tags stay local. The plan index keeps its rows, and pointers stay valid only on this machine.

## Validation record

Codex astra (model `gpt-6-astra`, `model_reasoning_effort="xhigh"`, read-only sandbox) reviewed draft 1 at `1d009062`.
It returned 15 findings: 0 Critical, 12 Major, and 3 Minor. All 15 are accepted, and this revision resolves them.

| Label | Severity | What failed in draft 1 | Resolution in this revision |
|---|---|---|---|
| V1 | Major | Deletion of the cost fuse was class A, but `cost_ceilings` is a config field and `CostMeter` is an export | Decision 2 is new. The document correction is unit 1b; deletion is class B unit 9g with its full file list |
| V2 | Major | The count of 35 constant checks was wrong, and 2 checks are reachable in raw mode | N3 has the exact table: 34 removed, 2 kept |
| V3 | Major | N12 deleted a `getenv` that appended binaries need, and omitted `serve_policy.zig` | N12 is narrowed, and the read in `runtime_pool.zig` stays |
| V4 | Major | N13 merged helpers that bind different file constants | N13 is withdrawn |
| V5 | Major | "Offline" had no enforced environment | Common rules scrub `ZTTP_` and `DEEPSEEK_` variables and assert the skip count |
| V6 | Major | The digests merged standard output and error, and the input list could change | Separate hashes, null-delimited frozen inputs, floors, and a wider protection list |
| V7 | Major | N16 moved gate roots that form an import cycle and that the module-boundary scan needs | N16 is withdrawn |
| V8 | Major | N4 reused `analyzeHandlerPaths`, which destroys the generator that compile needs | N4 is one value type and one apply function; compile digests cover the side outputs |
| V9 | Major | N20 changes did not state how a warm cache proves the fix | Unit 8a probes both publishers; unit 8b uses a side-effect gate and three mutation probes |
| V10 | Major | A gate that reads text can pass and scan nothing after a split | Phase 7 inventories hits, updates inputs, and runs rejection probes. The split of `expert_codegen_record.zig` is dropped |
| V11 | Major | N1 named the wrong path, and `zts spec-check` needs raw fragments | The path is corrected, and D-016 names 3 retained raw entries |
| V12 | Major | N6 gave a pointer to a census, not a reviewable list | Appendix A holds all 109 rows and the disposition rules |
| V13 | Minor | The N11 hook did not state its call sites or which test assertions stay | N11 fixes both, and the stop rule includes sound-mode precedence |
| V14 | Minor | Exit checks matched dated plans, and `bench-check` could fail a phase for host load | "Live source" scopes the checks; `bench-check` is advisory |
| V15 | Minor | The N2 counts did not reproduce | Appendix B states the command, and the command gives 214 sites in 38 files |

Codex astra also confirmed by reading: the base commit and totals, the 46 named steps in `agents.json`, the twelve stamps of N4, the inertness of `FlowWithoutHandler`, the five fields of N10, `--module-manifest`, `instruction_counter.zig`, and class B for N7.
It did not run builds, HTTP probes, or publication, and it did not check remote tags or the website.

Codex astra reviewed revision 2 with the same settings. It returned 10 findings: 0 Critical, 3 Major, and 7 Minor.
Opus confirmed each one by reading or by measurement, and revision 3 resolves all 10.

| Label | Severity | What failed in revision 2 | Resolution in revision 3 |
|---|---|---|---|
| W1 | Major | Appendix A deleted 19 rows that the keep rules protect: 17 members of exported types, 1 `modules/root.zig` export, and 1 alias that a solution note names. Appendix A2 deleted the `pathsMatch` compatibility alias | All 19 rows stay, and `pathsMatch` leaves Appendix A2. The preservation contract and the disposition rules now name this case |
| W2 | Major | A failed hash inside `printf` could write a row and exit 0 | `digest.sh` sets `pipefail` and gives each hash its own assignment. A forced `shasum` failure exited 3 |
| W3 | Major | Phase 9 could run before Phases 6 to 8, so an accepted text change would fail a later digest | Phases run in numerical order, and Phase 9 depends on each selected unit of Phases 2 to 8 |
| W4 | Minor | Help digests cannot see how `--watch` behaves as a flag value | Phase 0 records the serve flag cases, and unit 6c keeps each result |
| W5 | Minor | Unit 9g named "N9 files", which is not a full list | Unit 9g lists 13 paths from a reference search |
| W6 | Minor | `ReplayKind` had the wrong location, the N6 file count was low, and one stale-comment item had no source | The location and count are corrected, and the item is removed |
| W7 | Minor | Unit 7b required a count per verdict that no file records | `proof-swallow.allow` has 0 rows for `flow_interp.zig`, so the check is that the file does not change. This replaces the correction that Codex proposed |
| W8 | Minor | No unit owned the stale `STRATEGY.md` | Unit 10d owns it |
| W9 | Minor | The target "1 form" did not match the two observed cases | The row now counts 2 probe cases that start a server |
| W10 | Minor | The scope rule excluded Phases 7 and 8 | The rule names five kinds of task |

Codex astra also confirmed that all 40 distinct `zig build` steps in the phase gates exist and that the protection pathspecs resolve.
It reproduced the N3, N4, N10, N12, and N14 counts and the Appendix totals of revision 2.
It did not run builds, HTTP probes, replay, or mutation probes. It did not check the website, remote tags, external consumers, or each Appendix A reference count.

Opus ran `digest.sh` on all 215 inputs at `1d009062`. The second run compared equal to the first, a changed row exited 1, and a one-file input list exited 1.

A third Codex astra pass, with the same settings, covered only the changes of revision 3. It checked each delete row by symbol and returned 1 finding: 0 Critical, 1 Major, and 0 Minor.

X1 (Major): Appendix A still deleted `IRStore.addSequence`, a public member of a type that `parser/root.zig` exports. The cause was a search in revision 3 that read only `packages/*/src/root.zig`. The row now stays, as the twentieth row that W1 covers. A repeat of the check against all 7 tracked `root.zig` files found no other row.

No review covers the one-row correction for X1. Each Appendix A row stays subject to the Phase 0 repeat and to the build in Phase 2.
The three passes did not run builds, HTTP probes, or replay, and they did not check the website, remote tags, or external consumers.

## Definition of done

The reset is done when the worklog shows each row below at its target, or a recorded decision excuses the row.

| Measure | At `1d009062` | Target | Check |
|---|---|---|---|
| `parse_type_syntax` | 1 field, 11 reads | 0 | `git grep -w` in live source |
| Constant `self.admission` checks in the six functions | 34 | 0 | Review of 4a |
| Raw-mode test sites in Appendix B | 214 sites, less production feeders | 0 test sites | Worklog list |
| Contract fields stamped by hand in the drivers | 12 in each of 2 drivers | 0 | Review of 5a |
| `FlowWithoutHandler`, `buildContractOnlyFromParsed` | present | 0 | `git grep -w` in live source |
| Appendix A rows for deletion | 39 rows, 274 lines | 0, or a recorded reason | Worklog list |
| Cost fuse claim | states a fuse that no binary arms | Correct | Review of 1b |
| Artifact identity projections | 3 | 1 | Review of 6a |
| Custom `type_check` branch | present | 0 (Decision 3) | `git grep -w extractCustomResult` |
| Config discoveries in an ordinary `serve` start | more than 1 | 1 | Review of 6c |
| Imported source that admission refuses and `serve` still starts | 2 probe cases | 0 (Decision 4) | Admission probe table |
| Active reset authorities | 1, stale | 1, current | `git grep` |

Every class A unit passed its protection check, its unit gates, `zig build test`, and `zig build check-spine`.
The final `bash scripts/verify.sh` from an empty local cache passed.
The check, compile, and surface digests are byte-identical to Phase 0, except rows that the worklog traces to a class B unit.
The worklog lists every class B item that waits for a window.

## Appendix A. Public functions with no production reference

Method, at `1d009062`. The corpus is every tracked `.zig` file under `packages/`, except `*_test.zig`, `*_tests.zig`, `tests.zig`, `test_support/`, `test_shim.zig`, and `packages/zttp-sdk`.
The census removes top-level `test` blocks, comment-only lines, and plain re-export lines, then counts identifier tokens.
A row is a `pub fn` whose name occurs once in that corpus. The names `main`, `init`, `deinit`, `format`, `hash`, `eql`, `jsonStringify`, `jsonParse`, `next`, `reset`, `write`, and `read` are excluded, because they can be protocol names.
"Test refs" counts other uses of the name in all tracked Zig.
Limit: a name that two functions share does not appear, and a reflective use does not count. A build confirms the second case.

Disposition rules, in order. Rows in `packages/proof-checker` stay. A row that any `root.zig` exports, or that tracked Markdown outside `docs/plans` names, stays. A public member of a type that a `root.zig` exports by name stays. A name that ends in `ForTest` or `WithFault` stays. A row in a test-support file stays. A row with 10 or more test references stays, because it is a wrapper that tests use, unless it is a plain alias.

| File under `packages/` | Function | Lines | Test refs | Disposition |
|---|---|---|---|---|
| `pi/src/agent.zig` | `isLocal` | 6 | 2 | Delete (2b) |
| `pi/src/agent.zig` | `setProviderStallTimeout` | 6 | 2 | Delete (2b) |
| `pi/src/auto_repair.zig` | `shouldRunLane` | 3 | 4 | Delete (2b) |
| `pi/src/autoloop.zig` | `alwaysFailingGoalCheck` | 7 | 2 | Keep: test support |
| `pi/src/autoloop.zig` | `alwaysOkGoalCheck` | 7 | 1 | Keep: test support |
| `pi/src/autoloop.zig` | `emptyRepairPlan` | 7 | 3 | Keep: test support |
| `pi/src/compaction.zig` | `isSplitTurn` | 3 | 4 | Delete (2b) |
| `pi/src/expert_codegen_eval.zig` | `countFailingCode` | 9 | 2 | Keep: test support |
| `pi/src/expert_codegen_eval.zig` | `firstAttemptGreenPercent` | 4 | 10 | Keep: test support |
| `pi/src/expert_codegen_eval.zig` | `intentPassPercent` | 4 | 12 | Keep: test support |
| `pi/src/expert_codegen_eval.zig` | `rawFirstDraftPassPercent` | 4 | 11 | Keep: test support |
| `pi/src/expert_codegen_record.zig` | `evaluationManifestIdentity` | 8 | 2 | Keep: test support |
| `pi/src/expert_codegen_record.zig` | `responseCount` | 4 | 4 | Keep: test support |
| `pi/src/expert_evidence_identity.zig` | `contentDigestParts` | 10 | 5 | Keep: test support |
| `pi/src/expert_evidence_identity.zig` | `promptPersona` | 5 | 4 | Keep: test support |
| `pi/src/expert_evidence_identity.zig` | `providerSerializedCatalog` | 5 | 5 | Keep: test support |
| `pi/src/expert_evidence_identity.zig` | `resultRun` | 48 | 25 | Keep: test support |
| `pi/src/gate_record.zig` | `failureForRejection` | 18 | 5 | Delete (2b) |
| `pi/src/print_mode.zig` | `runWithClient` | 13 | 5 | Delete (2b) |
| `pi/src/providers/backend.zig` | `requestTimeout` | 5 | 7 | Delete (2b) |
| `pi/src/providers/backend.zig` | `stallTimeout` | 6 | 1 | Delete (2b) |
| `pi/src/providers/cassette_record.zig` | `writeCassette` | 14 | 3 | Keep: test support |
| `pi/src/providers/propose_change_set.zig` | `maybeRemap` | 7 | 12 | Keep: wrapper with many tests |
| `pi/src/session_state.zig` | `lastChangeSetHash` | 6 | 4 | Delete (2b) |
| `pi/src/session/events.zig` | `recoverIncompleteTail` | 4 | 8 | Delete (2b) |
| `pi/src/simulator/recorder.zig` | `captureTurnWorkspace` | 15 | 2 | Keep: test support |
| `pi/src/simulator/recorder.zig` | `runtimeIdentity` | 9 | 4 | Keep: test support |
| `pi/src/simulator/recording_storage.zig` | `promoteWithFault` | 7 | 1 | Keep: test hook |
| `pi/src/standin/defect_seeds.zig` | `countOfClass` | 7 | 1 | Keep: test support |
| `pi/src/standin/playbook.zig` | `hasPlaybook` | 6 | 7 | Keep: test support |
| `pi/src/standin/prompt_grammar.zig` | `totalIn` | 5 | 2 | Keep: test support |
| `pi/src/standin/source_grammar.zig` | `renderEnvSource` | 21 | 1 | Keep: test support |
| `pi/src/standin/source_grammar.zig` | `renderRouteSource` | 44 | 1 | Keep: test support |
| `pi/src/text_buffer.zig` | `renderAlloc` | 10 | 6 | Delete (2b) |
| `pi/src/tools/zts_agent_client.zig` | `errorCode` | 4 | 3 | Delete (2b) |
| `pi/src/tools/zts_agent_client.zig` | `invokeFromCwd` | 7 | 2 | Delete (2b) |
| `pi/src/transcript.zig` | `replaceProjection` | 14 | 5 | Delete (2b) |
| `pi/src/ui_payload.zig` | `guaranteeCounts` | 11 | 6 | Delete (2b) |
| `proof-checker/src/checker.zig` | `buildGuarded` | 62 | 23 | Keep: kernel |
| `proof-checker/src/checker.zig` | `writeSqlPolicy` | 23 | 1 | Keep: kernel |
| `proof-checker/src/proof_system.zig` | `consumerCheckedCount` | 9 | 2 | Keep: kernel |
| `proof-checker/src/verdict.zig` | `developmentOnly` | 7 | 1 | Keep: kernel |
| `runtime/src/artifact_graph.zig` | `moduleBlob` | 64 | 20 | Keep: wrapper with many tests |
| `runtime/src/attest/envelope.zig` | `keyPairFromSeed` | 3 | 20 | Keep: wrapper with many tests |
| `runtime/src/cli_help.zig` | `renderHelpAllForTest` | 4 | 2 | Keep: test hook |
| `runtime/src/handler_instance.zig` | `loadCodeWithCachingNoHandler` | 3 | 1 | Delete (2b) |
| `runtime/src/handler_instance.zig` | `loadHandler` | 3 | 69 | Keep: exported or documented |
| `runtime/src/runtime_pool.zig` | `acquireWorkerRuntime` | 10 | 14 | Keep: wrapper with many tests |
| `runtime/src/server_response.zig` | `formatStaticError` | 3 | 0 | Delete (2b) |
| `tools/src/canonicalize.zig` | `normalizeSource` | 7 | 41 | Keep: wrapper with many tests |
| `tools/src/example_registry.zig` | `findByFeature` | 6 | 4 | Delete (2a) |
| `zts/src/ambient_names.zig` | `findType` | 6 | 8 | Delete (2a) |
| `zts/src/atom_table.zig` | `pruneUnused` | 25 | 0 | Keep: member of exported type |
| `zts/src/behavior_canonical.zig` | `hasLaw` | 7 | 5 | Delete (2a) |
| `zts/src/builtins/math.zig` | `mathSign` | 9 | 2 | Delete (2a) |
| `zts/src/bytecode_cache.zig` | `invalidate` | 8 | 7 | Keep: exported or documented |
| `zts/src/bytecode_opt.zig` | `optimizeBytecode` | 9 | 3 | Keep: exported or documented |
| `zts/src/compiler.zig` | `compileWithOptions` | 56 | 5 | Unit 9b |
| `zts/src/context.zig` | `dropN` | 4 | 0 | Keep: member of exported type |
| `zts/src/context.zig` | `getArg` | 6 | 0 | Keep: member of exported type |
| `zts/src/context.zig` | `getThis` | 4 | 0 | Keep: member of exported type |
| `zts/src/context.zig` | `registerGlobalFunction` | 5 | 3 | Keep: exported or documented |
| `zts/src/context.zig` | `stackDepth` | 3 | 0 | Keep: member of exported type |
| `zts/src/contract_schema.zig` | `diffGaps` | 9 | 1 | Delete (2a) |
| `zts/src/contract_types.zig` | `knownValue` | 6 | 6 | Delete (2a) |
| `zts/src/cost_meter.zig` | `classForName` | 7 | 1 | Decision 2 |
| `zts/src/gc.zig` | `runMajorGCToIdleForTest` | 9 | 3 | Keep: test hook |
| `zts/src/guard_catalog.zig` | `guardsAnyArgument` | 7 | 2 | Delete (2a) |
| `zts/src/handler_contract.zig` | `extractHost` | 18 | 7 | Delete (2a) |
| `zts/src/handler_policy.zig` | `allowsCounting` | 8 | 2 | Delete (2a) |
| `zts/src/handler_policy.zig` | `declaredSectionsFromJson` | 8 | 0 | Delete (2a) |
| `zts/src/http.zig` | `valueToJson` | 6 | 7 | Delete (2a) |
| `zts/src/interpreter/cmp.zig` | `greaterEqual` | 4 | 1 | Delete (2a) |
| `zts/src/interpreter/cmp.zig` | `greaterThan` | 4 | 2 | Delete (2a) |
| `zts/src/interpreter/cmp.zig` | `lessEqual` | 4 | 1 | Delete (2a) |
| `zts/src/module_binding_adapter.zig` | `internalValue` | 3 | 0 | Delete (2a) |
| `zts/src/module_binding/types.zig` | `getNativeFn` | 5 | 2 | Keep: member of exported type |
| `zts/src/module_facts.zig` | `importsModule` | 3 | 4 | Delete (2a) |
| `zts/src/modules/internal/resolver.zig` | `registerVirtualModuleReplay` | 3 | 2 | Keep: exported or documented |
| `zts/src/object.zig` | `isExtensible` | 3 | 2 | Keep: member of exported type |
| `zts/src/object.zig` | `preventExtensions` | 3 | 1 | Keep: member of exported type |
| `zts/src/object.zig` | `setPropertyFast` | 3 | 0 | Keep: member of exported type |
| `zts/src/parser/ir.zig` | `addCase` | 7 | 3 | Unit 9e |
| `zts/src/parser/ir.zig` | `addLabeled` | 3 | 1 | Unit 9e |
| `zts/src/parser/ir.zig` | `addLoop` | 15 | 3 | Unit 9e |
| `zts/src/parser/ir.zig` | `addSequence` | 10 | 0 | Keep: member of exported type |
| `zts/src/parser/ir.zig` | `addSwitch` | 7 | 2 | Unit 9e |
| `zts/src/parser/ir.zig` | `addTry` | 12 | 2 | Unit 9e |
| `zts/src/parser/ir.zig` | `forEachChild` | 38 | 3 | Keep: member of exported type |
| `zts/src/parser/ir.zig` | `initBorrowingSource` | 5 | 2 | Keep: exported or documented |
| `zts/src/parser/type_syntax_store.zig` | `planApplicationBases` | 9 | 6 | Delete (2a) |
| `zts/src/pipeline.zig` | `formatIsoTimestamp` | 16 | 2 | Delete (2a) |
| `zts/src/pool.zig` | `getAvailable` | 9 | 5 | Keep: member of exported type |
| `zts/src/pool.zig` | `getSize` | 3 | 4 | Keep: member of exported type |
| `zts/src/proof_trace.zig` | `isVerifier` | 6 | 4 | Delete (2a) |
| `zts/src/repair_plan.zig` | `closesProperty` | 7 | 1 | Delete (2a) |
| `zts/src/root.zig` | `createContext` | 15 | 3 | Keep: exported or documented |
| `zts/src/root.zig` | `destroyContext` | 12 | 1 | Keep: exported or documented |
| `zts/src/root.zig` | `repairIsImplemented` | 4 | 1 | Keep: exported or documented |
| `zts/src/severity_census.zig` | `collectRows` | 47 | 1 | Keep: test support |
| `zts/src/string.zig` | `flattenWithArena` | 3 | 0 | Delete (2a) |
| `zts/src/string.zig` | `freeSlice` | 3 | 7 | Delete (2a) |
| `zts/src/type_checker.zig` | `absentReceiverOf` | 3 | 0 | Keep: member of exported type |
| `zts/src/type_pool.zig` | `findUnionMemberByDiscriminant` | 19 | 6 | Keep: member of exported type |
| `zts/src/value.zig` | `getPtrAddress` | 3 | 2 | Keep: member of exported type |
| `zts/src/value.zig` | `isNullish` | 3 | 1 | Keep: exported or documented |
| `zts/src/value.zig` | `isSpecial` | 3 | 4 | Keep: member of exported type |
| `zts/src/value.zig` | `isTagged` | 3 | 0 | Keep: member of exported type |
| `zts/src/value.zig` | `toBoolean` | 15 | 27 | Keep: wrapper with many tests |

These items are not public functions, or the census cannot see them. An audit found each one by reading. Phase 0 confirms each with `git grep`.

| Item | File | Unit |
|---|---|---|
| `focus_witness_key`, `focusedAchieved`, `DriveOptions.cancel`, `Cancel` | `pi/src/autoloop.zig` | 2b |
| `DynamicHeaderOrder.evented` | `runtime/src/server_response.zig` | 2b |
| `ReplayKind.violation_drift`, `ReplayKind.system_drift` | `pi/src/ledger.zig` | 2b; keep if the order feeds a hash |
| `TurnEvent.user_approved` | `pi/src/turn.zig` | 2b |
| Three unset `project_context.Options` fields | `pi/src` | 2b |
| `result_globals` second copy of the name list | `zts/src/handler_verifier.zig`, `zts/src/proof_ir.zig` | 2a; the classifiers stay |
| Stale comments: a deleted file in `upgrade_verifier.zig`, a personal path in `pipeline.zig`, and a deleted HTML file in `semantics.zig` | Those files | 2a |

## Appendix B. Raw parser constructor sites

Method, at `1d009062`: `git grep -n -E '(JsParser|[^A-Za-z_]parser\.Parser|[^A-Za-z_]Parser)\.init\(' -- 'packages/*.zig'`, without `parser/parse.zig`, `parser/root.zig`, and `packages/modules/src/net/sse.zig`, which is an unrelated SSE parser.

| File under `packages/` | Sites |
|---|---|
| `zts/src/effect_inference.zig` | 55 |
| `zts/src/flow_checker_tests.zig` | 46 |
| `zts/src/path_generator.zig` | 12 |
| `zts/src/strict_checker.zig` | 11 |
| `zts/src/interpreter.zig` | 11 |
| `zts/src/pipeline_tests.zig` | 8 |
| `zts/src/type_checker.zig` | 7 |
| `zts/src/contract_builder.zig` | 6 |
| `zts/src/ir_json_literal.zig` | 5 |
| `zts/src/handler_verifier.zig` | 5 |
| `zts/src/tests/frontend_fuzz.zig` | 4 |
| `zts/src/parser/ir.zig` | 4 |
| `zts/src/bool_checker.zig` | 4 |
| `zts/src/handler_analyzer.zig` | 3 |
| `zts/src/function_specs.zig` | 3 |
| `zts/src/proof_trace.zig` | 2 |
| `zts/src/proof_ir.zig` | 2 |
| `zts/src/parser/codegen.zig` | 2 |
| `zts/src/module_facts.zig` | 2 |
| `zts/src/compiler.zig` | 2 |
| `tools/src/precompile_contract.zig` | 2 |
| `tools/src/precompile_check_tests.zig` | 2 |
| 16 files with 1 site each: `severity_census`, `property_diagnostics`, `pipeline`, `parser/ir_children_tests`, `modules/internal/module_graph`, `interpreter/trace`, `flow_interp`, `flow_evidence`, `fault_coverage` (zts); `precompile`, `precompile_gen_tests`, `precompile_check_run`, `module_graph_record` (tools); `runtime_cli`, `handler_instance` (runtime); `tools/zts_expert_effects` (pi) | 16 |

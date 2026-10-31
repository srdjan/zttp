# Legacy removal worklog, 2026-10-30

This worklog records the execution of the [legacy removal plan](2026-10-30-legacy-removal-plan.md).
The plan is the authority. This file holds evidence, rulings, and deviations.

## Owner decisions

The owner answered "all a" on 2026-10-30. That answer covers Decisions 1 to 13 in the plan, and Decision 14 from the same message.

| Decision | Selection | Effect on this run |
|---|---|---|
| 1. Generic arrow after a comment | (a) | L4a runs |
| 2. Erased type prefix | (a) | L4b runs |
| 3. Predicate second parse | (a) | L4c runs, with an explicit refusal of an empty narrowing |
| 4. Raw parser, `inline_code`, Zig aliases | (a) | L5 runs. `.inline_code` stays and passes admission |
| 5. Duplicate journal `body` | (a) | L7a runs |
| 6. Ledger rows and `--no-sign` | (a) | L8a keeps both kinds as opaque rows, and removes the payload types and the flag |
| 7. Undocumented runtime paths | (a) | L3e runs |
| 8. Retired provider keys | (a) | L8b keeps `zttp auth revoke claude` and `zttp auth revoke openai`, and removes the rest |
| 9. `canonicalize --json` kind names | (a) | L7b runs, with a release note |
| 10. Scalar response fields | (a) | L7c runs |
| 11. Installer fallback | (a) | L7d runs |
| 12. Tag removal and the moved `semanticsHash` | (a) | L6 runs |
| 13. Order against the reset | (a) | L0 to L9 run before reset Phases 10 and 11 |
| 14. `zttp compile` hash gap | (a) | I measure the tamper effect as separate work after this plan |

The run commits on local `main`, as the owner's standing instructions require. No push or pull request is part of this run.

## Baseline

Base commit: `71173d15`. It differs from `0635cd09`, which the review read, only by the plan document.
`bin-base` in the scratch directory holds the three binaries built at `0635cd09`.

## L0

Status: complete. All checks ran in the scratch directory, and only this worklog, the plan status line, and the plan index changed.

| Check | Result |
|---|---|
| Inputs | 648: the 645 inputs of the review plus the three `block` probes |
| Comparison script, two runs of the base binaries | 0 rows differ at 648 rows |
| Comparison script, base against a build at the base commit | 0 rows moved |
| Stored-data set | Built with the base binaries. Two runs of `stored.sh` match. `zttp proofs verify` exits 0, `GET /` returns 200 with `message` "Hello, World", and `zttp proofs list`, `show`, `diff`, and `export` exit 0 |
| `surface.sh` | Exit 0: identical to the table saved after reset unit 9a |
| `eprobe.sh` | 11 rows saved as `legacy-base` |
| `zig build test`, cold | Exit 0. 8478 of 8484 tests pass, with 6 skipped, on 214 of 214 steps |

The ledger in the stored-data set holds, in order: one `deploy` row, the `perf` and `equivalence` fixtures from `proof_ledger.zig`, and one `deploy` row.

## L1

Status: complete. Units L1a to L1d changed text only. Workers ran in parallel on disjoint paths, and one gate ran over the combined tree before the four commits.

| Check | Result |
|---|---|
| Comment-only check on each Zig and shell file | Exit 0 for L1c and L1d. For L1b it reports `value.zig`, where the difference is a trailing comment on a line with a quote. I read that line, and no code token changed |
| Protection diff, build, `surface.sh`, `test-zruntime`, `zig build test`, `check-spine` | Each exit 0 |
| Comparison script | 0 of 648 rows moved |
| `test-doc-links`, `test-docs-drift` after L1a | Exit 0 |
| `git grep -n -i 'injectDriftNote\|witness_corpus\|witness corpus'` outside plans, solutions, and the changelog | No match |

Text changed by cluster:

| Unit | Files | Lines added | Lines removed |
|---|---|---|---|
| L1a, documents | 8 | 24 | 141 |
| L1b, `packages/zts` | 56 | 205 | 250 |
| L1c, `packages/runtime`, `packages/tools`, `build` | 30 | 72 | 119 |
| L1d, `packages/pi`, `packages/modules`, `scripts`, `tooling` | 31 | 88 | 132 |

Deviations:

- Rows E4, E6, E8, and C16 in `root.zig` and C15 in `capabilities.zig` live in `packages/zts`, so L1b made them. The plan table names other units for those rows.
- Row E19 lists native `Result` fields `ok` and `value`. L1b found no such comment text.
- `AGENTS.md` no longer says that two comments name the old heredoc, because L1c and L1d removed both comments.

Text that the plan did not name:

- `packages/pi/src/simulator/artifact.zig`, `recorder.zig`, `recorder_test.zig`, `tools/workspace_list_files.zig`, and `tools/pi_goal_candidate.zig` said that a tool persists witnesses under `.zttp/witnesses`. No code writes there, and `persist_witnesses` exists only in those comments. The comments now state the current reason to skip `.zttp`.
- `packages/tools/src/proof_checker_mutants.zig` said that the suite runs 195 tests, next to a floor of 231. The comment is gone.
- `packages/tools/tests/fixtures/contract/plain_ts.ts` keeps a comment that names `.zttp/witnesses`, because it is a protected fixture.

Open rows that this review found go to the ledger as E21 to E23.

## L2

Status: complete. Gate exit 0: protection diff, build, `surface.sh`, `eprobe.sh`, `test-zruntime`, `test-expert-app`, `zig build test`, `check-spine`. `zts meta --json` is identical. The comparison script moved 0 of 648 rows.

The first gate run moved one row: `tests/corpus/parse/bad/legacy_types_import.ts`. `zts check` prints the Zig error name on stderr, so renaming the error `LegacyTypesImport` changed protected output. I restored that error name. The Zig tag is `retired_types_import` and the scan function is `containsRetiredTypesImport`, because neither name reaches an output. The error name stays, with this reason.

Names that the worker chose: `in_zts_modules_dir`, `StepCapturingClient` (because `CapturingClient` exists in the same file), `v1_key`, `removed_name`, `removed_query_names`, and `SessionProviderMissing`.

`eprobe.sh` table rows hold a pool timing and leak addresses, so the unit gate normalizes both before it compares. The `parse-error` row of that table shows a `SafeAllocator` leak report on the debug binary at the base commit. This plan did not cause it, and no unit here changes it.

Names that wait for L4 to L8: `legacy_return_kind`, `LegacyReturnKind`, `hasLegacyGuardFacet`, `legacy_ordinary_prefix`, `legacy_call`, `legacy_call_arguments`, `legacy_parameter_projection`, `legacy_start`, `legacy_end`, `legacy_projected_end`, `legacy_capture`, `original_legacy_capture`, `legacy_bound`, `unsupported_legacy_spelling_refusal`.

## L3a

Status: complete. Gate exit 0: protection diff, build, `surface.sh`, `eprobe.sh`, `test-zruntime`, `test-expert-app`, `test-expert`, `test-cassette`, `test-simulator`, `zig build test`, `check-spine`. The comparison script moved 0 of 648 rows.

The new test `journal refuses part_index, body-only results, and string display payloads` failed on the old readers: the `part_index` record loaded. The table stops at its first failure, so that run proved only the first row. The deleted pin test proves that the other two forms loaded before this unit.

Tests that left, each with the behavior that it held:

| Test | Behavior | Now |
|---|---|---|
| `reconstructTranscript preserves legacy display and body payloads` | A string `proof_card` and a body-only `tool_result` loaded | Left on purpose. The new test asserts each refusal |
| `part identity is exclusive to legacy tool use records` | The writer refused `part_index` on other kinds | Left on purpose, because the writer parameter is gone. The new test asserts the read refusal |
| `invalid journal sequence transitions do not poison the writer` | Four part cases and one skipped-entry case | The four part cases left on purpose. `a skipped entry identity is refused without poisoning the writer` keeps the skipped-entry case |

The fixture in `reader recovery and reconstruction preserve additive journal fields` used a body-only record, so it now uses `llm_text`. That test is about unknown keys, and its assertions did not change.

Ruling on the `tool_use` event kind: it stays. `zttp expert --mode json` prints it through `emitEntry` in `print_mode.zig`, so it is a current output. My follow-up to remove it was wrong, and the worker stopped before it edited a file. The journal writer emits `tool_use_batch`, and `reconstructor.zig` refuses a single `tool_use` record, as it did before this unit.

## L3b

Status: complete. Gate exit 0: protection diff, build, `surface.sh`, `eprobe.sh`, the stored-data set, `test-zruntime`, `test-contract-golden`, `test-proof-checker`, `test-proof-checker-mutants`, `test-proof-ratchet`, `test-kernel-safety`, `test-expert-app`, `zig build test`, `check-spine`. The comparison script moved 0 of 648 rows.

The new test `parseFromJson leaves API route collections empty when the arrays are absent` failed on the old parser with `expected 0, found 1`.

The two pin tests left on purpose. They held the synthesis of one response from scalar fields, and of one `application/json` body from `requestSchemaRefs`. Only a hand-made contract older than `sourceIdentity` reaches that behavior.

The backfill also set `request_bodies_dynamic` and `responses_dynamic` on a parsed route. `contract_builder.zig` sets both flags at build time, and `contract_diff.zig` reads each flag with its scalar partner, so no current contract depends on the parsed form.

## L3c

Status: complete. Gate exit 0: protection diff, build, `surface.sh`, `eprobe.sh`, `test-zruntime`, `test-flow-census`, `test-evidence-publish`, `test-evidence-marker`, `test-native-gates`, `test-precompile`, `test-expert-app`, `zig build test`, `check-spine`. `zts meta --json` is identical, so `semanticsHash` did not move and the field in row E22 is outside the hash. The comparison script moved 0 of 648 rows.

The test `the old-checker miss table equals the observed misses` left on purpose. It compared the table with the observed misses, and the table is gone. `every expected property holds` fails on any miss.

`docs/zts-formal-spec-northstar-advanced.md` is a tracked document, so the two "northstar" comments in `semantics.zig` name a current future plan. They stay.

## L3d

Status: complete. Gate exit 0: protection diff, build, `surface.sh`, `eprobe.sh`, the stored-data set, `test-zruntime`, `test-cli`, `test-proof-checker`, `test-proof-checker-mutants`, `test-proof-ratchet`, `test-kernel-safety`, `test-module-boundary`, `zig build test`, `check-spine`. The comparison script moved 0 of 648 rows.

The 3 pin tests failed on the old checks: `expected error.CapabilityMatrixMismatch, found void`, `expected error.PolicyHashMismatch, found void`, and a returned contract in `validate`. They now assert the refusal under new names.

The 6 fixture tests take `stampLiveForTest` or `stampLiveHandlerForTest`, which set the values that the writer stamps. `validate` still runs in each test. In `validate promotes Raw to Validated when integrity checks pass`, the assertion `capabilities == null` became a zero-length matrix, because the fixture now carries a matrix.

`verifyArtifactHash` is unchanged, as row E14 requires.

## L3e

Status: complete. Gate exit 0: protection diff, build, `surface.sh`, `eprobe.sh`, the stored-data set, `test-zruntime`, `test-server`, `test-examples`, `test-expert-app`, `zig build test`, `check-spine`. The comparison script moved 0 of 648 rows.

The new test `a second handler parameter reads undefined` failed on the old path with `expected undefined, found object`. It loads the source through `loadPreparedEval`, because `loadHandler` refuses type annotations on a `<...>` filename.

The fallback in `interpreter/call.zig` returns `error.NotCallable`, which `doCall` already returns for a value that cannot be called. No test reaches that line: it needs a callable object with no native, closure, or bytecode payload, and no public path makes one.

## L3f

Status: complete. Gate exit 0: protection diff, build, `surface.sh`, `eprobe.sh`, `test-zruntime`, `test-expert-app`, `test-simulator`, `test-cassette`, `zig build test`, `check-spine`. The comparison script moved 0 of 648 rows.

The new tests `replay refuses a checkpoint with no request budget` and `replay refuses a checkpoint with no normalized input tokens` failed on the old path: `expected error.ReplayMismatch, found` a successful result. Only those two tests failed in that run: 856 of 858 passed.

An absent field uses the failure of a mismatch: `request_budget_mismatch` and `normalized_input_mismatch`. The decoder still accepts an absent field, so a hand-made recording fails at replay with a named failure. No file under `packages/pi/src/simulator/testdata` changed, and every committed trace holds both fields.

The fixture in `every Chat Completions provider rebuilds its wire digest on replay` now calls `prepareSnapshot` to fill the budget. The digest from the independent body still replaces the prepared digest, so the digest check stays bound to that body. The comments on the two fields in `artifact_contract.zig` now state the replay refusal.

## L4a

Status: complete. Gate exit 0: protection diff, build, `surface.sh`, `eprobe.sh`, `test-zruntime`, `test-server`, `test-precompile`, `test-diagnostic-corpus`, `test-standin`, `test-flow-census`, `test-proof-swallow`, `zig build test`, `check-spine`. `zts meta --json` is identical. The comparison script moved 1 of 648 rows: `_probe/ex/lc.ts`, the allowed row. It now reports one ZTS200.

Correction to row A1: the row named only a generic arrow after a line comment. `rawLooksLikeComparison` reads the raw byte before `<`, so the keyword `return` reached `.legacy_call` too, with no comment. Row A1 also names the selectors, so this unit removed them and all arrow lists use one scanner.

Two forms moved outside the row text, and both forms were ZTS002 on the base binary:

| Form | Base | After | Assignment form on base |
|---|---|---|---|
| `return <T extends string = string>(value: T): T => value;` | ZTS002 | Accepted by parse and types | Accepted |
| `return <T>` newline `(value: T): T => value;` | ZTS002 | Accepted by parse and types | Accepted |

No tracked program uses either form. The new test `CHECK parses a generic arrow after return` holds both.

A generic arrow after a line comment now takes every list that the same arrow takes with no comment. For example, `// note` newline `<T = string>(value: T): T => value` moved from ZTS002 to the ZTS200 of the form with no comment, and `// note` newline `<T> (value: T): T => value` moved from ZTS002 to ZTS208 and ZTS200.

Side probes: 63 programs in the scratch directory ran through `zts check`, `zts compile`, and `zts canonicalize` on both binaries. Only the two forms above moved. The new test `CHECK reads a generic arrow after a line comment like one with no comment` failed on the old path, because the base reports ZTS203 and ZTS200.

`selectFunctionGeneric` keeps the call scanner for a spaced list and for a comment before the name. Those shapes now take policy `.ignored` with a runtime-only header. The generic scanner changed the output of `function id <T = string>(x)`, so the worker reverted that choice.

`observeRecoveryGeneric` now skips the arrow selection after a value byte. The source observer has no expression position, so it reads `id<T>(1)` as a call and any arrow header as a following group.

Tests outside Appendix A changed, because each one named the removed policy and could not compile:

| Test | Change |
|---|---|
| `generic and call finalizers reject incompatible runtime owners` | The `.legacy_call` stanza left |
| `legacy compatibility and explicit calls own distinct shared ranges` | Now `explicit calls own their argument and fragment ranges`. The explicit-call checks stay |
| `ignored and legacy-call policies retain syntax without generic declaration lowering` | Now `ignored policy retains syntax without generic declaration lowering`. The `.legacy_call` block left |
| `line comment arrows keep direct source and owner boundaries` | The refused `<T> (` row is now accepted with one owner |
| `comparison-shaped generic arrow candidates require explicit call grammar` | Now `generic arrow lists after a line comment read like lists with no comment` |

Appendix A tests that took new names: `direct phase three preserves actual call construction`, `nested line-comment arrow retains captures and semantic projection`, and `admission spaced function lists take the ignored policy and runtime headers`.

Ruling on `compatibility_order` in `type_env.zig`: it stays. `replayDirectSignatureEvent` uses it to check that one source offset has one signature owner, and Phase 5 of `populateDirectSourceTypes` reads it. It has no link to `.legacy_call`. Row A1 removes it only when no reader remains.

Defects that this unit did not cause: the ZTS208 message names `T>` for `<T> (value: T)`, because `recorded_span` ends one byte before the opener. The form with no comment reports the same text on the base binary.

## L4b

Status: complete. Gate exit 0: protection diff, build, `surface.sh`, `eprobe.sh`, `test-zts`, `test-zruntime`, `test-server`, `test-precompile`, `test-diagnostic-corpus`, `test-standin`, `test-flow-census`, `test-proof-swallow`, `zig build test`, `check-spine`. `zts meta --json` is identical. The comparison script moved 11 of 648 rows: the 10 rows that the plan allows, and `lc.ts` from L4a. From this unit on, each allow list holds the rows of the earlier units, because the script compares with the base.

The new test `CHECK refuses an erased type prefix with ZTS002 at the angle bracket` failed on the old path: `expected 1, found 0` at `parse_errors`, so the base accepted the form.

Each erased form now reports ZTS002 at the `<`: `<T>(1)`, `<T> (1)`, `<T> { id: 1 }`, the statement `<T> { const a = 1; }`, and those forms inside a group, a call, an array, an object, a binary expression, and an arrow body. Thirty-nine side probes ran through `zts check`, `zts compile`, and `zts canonicalize`. Eight control probes did not move, including `const f = <T>(a) => a;` and `const f = <T>(a: T): T => a;`.

`const x = true ? <T>(a: number) : 2;` was ZTS003 on the base binary and is ZTS002 now. It stays refused.

Correction to my review of this unit: the worker reported that no public path reaches the new branch in `parseArrowFunction`, and 25 of my probes agreed. I replaced the branch with an internal error. `zig build test` then failed, because `const f = <T>(value /* ( */): any => value;` reaches the branch: a comment hides the typed header from the source probe. I restored the ZTS002 branch and added that form as a literal row in the new test.

`populateDirectGenericPhase` now loops over generic owners only, and `GenericProjectionRetention` left, because only the prefix path used `.transient`.

Tests outside Appendix A changed, because each one held a removed form or named a removed symbol:

| Test | Change |
|---|---|
| `direct phase two consumer matrix preserves generics and headers` | Four prefix cases left. Five cases stay |
| `admission header fallback preserves grouped and raw arrow type construction` | One prefix row left. Two rows stay |
| `direct callable generic allocation failures close scopes by construction stage` | Its source now uses generic arrows. The observation floors hold |
| `erased prefix operand scanner is local and preserves lexical delimiters` | Left with the scanner |
| Shared helpers in `typed_frontend_tests.zig` and the checkpoint test in `type_syntax.zig` | Prefix counts left |

`CHECK preserves admitted generic prefixes without function owners` left, because each of its 10 rows held a removed form. In `frontend_fuzz.zig`, the `erased_prefixes` counter and its floor left, and the seed `const value = <T>(1);` stays as a refused input.

Observations that this unit did not cause, on the base binary and now: `function mk(): number { return (value: string): string => value; }` reports no ZTS204. `const isS = (x: unknown): x is string => true;` reports no ZTS211, and the same predicate as a function declaration does. I will measure both after the plan and report them.

## L4c

Status: complete. Gate exit 0: protection diff, build, `surface.sh`, `eprobe.sh`, `test-zts`, `test-zruntime`, `test-server`, `test-precompile`, `test-diagnostic-corpus`, `test-standin`, `test-flow-census`, `test-proof-swallow`, `zig build test`, `check-spine`. `zts meta --json` is identical. The comparison script moved 12 of 648 rows: `_probe/ex/e7.ts` and the 11 rows of the earlier units.

The new test `CHECK refuses an empty predicate narrowing at the token after is` failed on the old path in two ways. For `x is` newline `{ return true; }`, the base reports ZTS204 at `return`, not ZTS003 at the brace. For `x is ` with a trailing space and a newline, the base accepts the program: `expected 1, found 0` diagnostics. On a tree where only the second parse is gone, the first form also reports 0 diagnostics, which confirms the A5 trap.

Correction to the plan: "The A5 trap" says that the old second parse supplied the refusal. That holds only for a header with no literal " is ". A header with that literal, such as `x is ` then a newline, was already an accepted empty narrowing on the base binary. `populateDirectReturn` returned at `.absent`, so the function had no declared return type. This unit closes both shapes.

An empty narrowing now reports ZTS003 `unexpected token` with the suggestion `type annotation`, at the first token after `is`:

| Form | Base | Now |
|---|---|---|
| `x is` newline `{`, and a tab or CRLF variant | ZTS204 | ZTS003 at `{` |
| `x is ` newline `{`, and more trailing spaces | Accepted | ZTS003 at `{` |
| `x is` newline `=> true` | ZTS204 | ZTS003 at `=>` |
| `x is => true` | Accepted | ZTS003 at `=>` |
| `x is /* c */ {`, `x is // c` newline `{` | ZTS000, an internal stop | ZTS003 at `{` |

`x is{ return true; }` keeps ZTS204, because that header is not a predicate. A real narrowing keeps ZTS211, including a tab or a newline after `is`.

`LegacyReturnKind`, `hasLegacyGuardFacet`, `legacy_return_kind`, and `legacy_ordinary_prefix` left, because no reader remained. `validateReturnSyntax` refuses a hand-built record with an empty narrowing. My review changed the `.absent` arm in `populateDirectReturn` from `return` to `error.InvalidReturnSyntax`, because that arm was the fail-open.

Tests outside the L4c rows of Appendix A that changed:

| Test | Change |
|---|---|
| `CHECK preserves typed arrow return forms and parameter refusals` | Four rows for an empty narrowing now assert ZTS003 at the parse stage |

`predicate compatibility range cannot own narrowing nodes` left, because the range left. `direct predicates preserve construction and checker behavior` lost its `empty_narrowing` case, which the new test covers.

Test names that still say "legacy" in `typed_frontend_tests.zig` wait for the L9 list.

Observation that this unit did not cause, on the base binary and now: `function isS(y: unknown): x is string { return true; }` reports 0 errors, because `populateDirectReturn` returns at an unresolved target and the function has no declared return type. I will measure it after the plan and report it with the other two.

## L5a

Status: complete. Gate exit 0: protection diff, build, `surface.sh`, `eprobe.sh`, `test-zts`, `test-modules`, `test-zruntime`, `zig build test`, `check-spine`, and `bash scripts/check-semantics-spec.sh`. `zts meta --json` is identical. The comparison script moved no row beyond the 12 rows of L4.

`compile` now takes the typed entry, so D-016 names three untyped entries. `compile matches the typed path for a fragment with erased annotations` compared one path with itself after this change. It is now `compile erases annotations from a fragment`, which compares the bytes of an annotated fragment and of the same fragment with no annotation.

## L5b

Status: complete. Gate exit 0: protection diff, build, `surface.sh`, `eprobe.sh`, `test-zruntime`, `test-server`, `test-cli`, `test-examples`, `zig build test`, and `check-spine`. `zts meta --json` is identical. The comparison script moved 12 rows, all listed, and 0 unexpected rows.

The pin test failed before the change with `expected error.UnsupportedAnyType, found error.ParseError`. `loadCodeWithCachingInternal` now has one typed entry, and only a `.ts` file gets the type check. D-016 names two untyped entries: `JsParser.initExpression` and `JsParser.initSourceObserver`.

Move that Decision 4 does not name: an inline source with type annotations loaded nothing on the base binary, because the raw parser stopped at the first annotation with `error.UnexpectedToken`. That source now loads, and the runtime does not check its annotations. The plan measured this path, and the pin test asserts the new result with the response body `ok`. `zttp -e` already loads an annotated source unchecked. The annotation adds no runtime behavior, because base loads the same source with its annotations removed. No production code produces `.inline_code`. L9 adds a `CHANGELOG.md` line.

My review made one wrong change and reversed it. I added the type check to `.inline_code` to keep that refusal. That change hung `test-zruntime` for almost five hours in `probeFetchWithRetry`, because `method: 1` failed at load and the deferred `join` waited in `accept`. After a fixture fix, 12 tests failed with `error.SoundModeViolation` or a related type error, because those fixtures load values that the type check refuses so they can reach runtime guards. Decision 4 authorizes admission refusal only, so I removed the type check. The fixture fix stays as its own commit.

The worker's `if (!builtin.is_test)` guard stops the admission log line from failing the test runner, which counts each logged error as a failure.

Renamed tests:

| Old name | New name |
|---|---|
| `prepared evaluation caches bytecode and reload restores raw virtual parsing` | `prepared evaluation caches bytecode and reload refuses an any annotation in virtual source` |
| `prepared evaluation omits authored types while raw virtual and file profiles remain distinct` | `prepared evaluation omits authored types while virtual source refuses any and file profile checks types` |

## L5c

Status: complete. `JsParser.init` and the wrapper `Parser.init` are gone, so D-016's two entries are the only untyped entries. Each test file has its own commit. `parser.parse`, `ParseResult`, `ParseOptions`, `Parser.parse`, and `Parser.parseWithCodegenAllocator` also left, because each one reached the raw entry and no production code called it. `typed_phase` is no longer optional, because only `initTyped` builds the wrapper.

This is a public Zig API move. Decision 4 names the raw entry, and L9 adds a `CHANGELOG.md` line.

The plan said that no expected value moves. Five of the 149 sites could not meet that, so I decided them as follows.

| Site | Reason | Result |
|---|---|---|
| `export default is refused with a named export repair` | The raw text reaches no user. `zts check` prints the admission text | Asserts `error.AdmissionRefused`, `.default_export`, span start 0 |
| `export let is refused with an export const repair` | The same reason | Asserts `error.AdmissionRefused`, `.mutable_export`, span start 0 |
| `unsupported: default parameter` | The same reason | Asserts `error.AdmissionRefused`, `.default_parameter`, span start 22 |
| `fuzz: parser holds its contract on every seed` | The `.parser` target ran the raw entry. `fuzz: direct compile holds its contract on every seed` runs the same seeds through production | Removed |
| `stress: parser holds its contract on generated input` | The same target. Its volume has value | Renamed `stress: direct compile holds its contract on the parser input stream`, with the same seed and 1000 iterations through `.typed_compile` |

`oomParse` and the `.parser` allocation target left for the same reason. `compile_runtime` and `compile_types` sweep the production path.

The worker said that moved tests might now pass for another reason. I measured that with a temporary shadow raw parse of each moved `parse.zig` site, which I removed after the run. The first run reported 0 comparisons because my line map failed to load, so I fixed it and reran. Result over 256 `parse` calls: 180 identical, 69 injected allocation failures, 5 with the same first error and one more recorded error, 1 with the same message under `error.AdmissionRefused`, and 1 artifact, because the shadow parser did not copy `allow_asi`. No first error text changed. The audit reads `parse` calls only.

A normalized comparison shows that the `parse.zig` test move changed only call sites.

Removed `error.InvalidParserPhase` rows, each because the method left: 2 raw rows, 2 `parse` rows in the typed tests, 1 `parseWithCodegenAllocator` row, and 1 more `parse` row in `typed generation failures clean published float and nested function payloads`.

Observation for later pruning: a parser refusal text such as "default exports are not supported" still runs, but `parseAdmission` replaces it with the admission text. So those texts have no reader on a program parse. They are not legacy under this plan's definition, because the parser branch still refuses, and this plan leaves them.

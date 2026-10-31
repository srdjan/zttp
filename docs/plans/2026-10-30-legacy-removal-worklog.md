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

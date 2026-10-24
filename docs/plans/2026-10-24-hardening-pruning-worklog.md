# Hardening and pruning worklog, round 4

## Objective and constraints

The owner requested a ranked list before more features. The list must reduce complexity without losing functionality.
The owner authorized implementation with `go ahead` after accepting the ranked list.
The [implementation plan](2026-10-24-hardening-pruning-plan.md) bounds the work. No Git history rewrite is authorized.
The source baseline is `d7aaf1f4`. Work stays on local `main`, with no push.
Standing decisions in `docs/decisions.md` still apply. Earlier closed findings stay closed unless current evidence contradicts them.

## Completed work

The main agent read the repository map, build graph, dependencies, standing decisions, and earlier pruning records.
Three read-only Sol agents reviewed the expert loop, runtime, and analyzer areas.
The expert-loop agent reported one preliminary concern, then stopped because the model reached capacity.
The main agent tested that concern independently. A `.zttp` symlink caused `NotDir`, and no outside lock appeared.
That concern is excluded from the list.

`zig build check-spine` exited 0 before documentation changes.
A documentation-link probe used an isolated temporary Git repository.
The gate exited 1 for a broken link, but exited 0 for an empty inventory and a failed Perl scanner.
These are confirmed false passes.

The branch metric probe wrote a prefix, then ran the current metric against `build.zig` with redirected stdout.
The metric exited 0 and erased the prefix. The list records this output defect separately from the scanner false pass.

The main agent reviewed the retained agent findings against source and callers.
The completed list contains 16 ranked findings and separates source evidence from observed probes.
The main agent measured 204 removable lines in the unused proof-review printer scaffolding.
The plans index now links the list and this worklog.

## Audit checks before implementation

| Command | Result and scope |
|---|---|
| `zig build test -j1 --summary all` | Exit 0; 212 of 212 steps succeeded; summary reports 9,006 tests passed and six skipped |
| `zig build test-agent-protocol --summary all` | Exit 0; 535 tests passed; the build reported one minute for execution |
| `zig build check-spine test-doc-links` | Exit 0 after the new report files were staged |
| `git diff --cached --check` | Exit 0 |

The aggregate was unfiltered and used existing caches. Its summary is not an independent inventory of unique tests.
The audit did not run `bash scripts/verify.sh`, remote providers, allocation-failure probes, or cross-platform runtime tests.
The aggregate log is `/tmp/zttp-pruning-round-4-test.log`.
The named-suite log is `/tmp/zttp-pruning-round-4-agent-protocol.log`.
The final documentation log is `/tmp/zttp-pruning-round-4-docs.log`.

## Implementation checkpoint

The owner requested a pause and a handoff on 2026-10-24. All three workers stopped, and no build process remains active.
Commit `35c86a84` contains the implementation plan. No production implementation commit exists.
Eight source and build files contain uncommitted work from this run. The initial tree had no user changes.
The work is intentionally paused with incomplete tests. The earlier audit gate does not establish the current tree's correctness.

| Unit | Current state | Remaining work |
|---|---|---|
| U1: reliable check output | Documentation inventory and scanner failures reject. Metric output streams and flush errors propagate. Core named gates passed. | The build also contains a deliberately failing evidence-output probe. Publisher and provenance stdout still need repair. Two other evidence writers remain unprobed. |
| U2: atomic object layouts | `object.zig` reserves storage before class and transition publication. The failure sweep retries through public APIs. The engine root passed. | The complete named `test-zts` step remains red because of U5. `test-zruntime` remains pending. |
| U3: strict replay decoding | Partial array and object failures now count as divergences. The engine root passed these tests and the trailing-input test. | A new argument-serialization failure test has not run. The corresponding production failure handling remains unchanged. |
| U5: complete type parsing | `parseTypeExpr` now checks complete consumption. Its new regression passes. | A legacy parity test fails in `type_syntax_lowering.zig`. The malformed-input cases need an explicit disposition before completion. |
| U8: remove printer scaffolding | `printer.zig` retains `FdWriter` and removes dead types and six tests. `test-proof-review` exited 0. | Required CLI and server integration checks remain pending. |
| Other units | Not started. Read-only preparation examined predicate parsing, opcode consumers, and recording documentation. | Proof-default recording and representation compatibility still need their concrete decisions and evidence. |

The eight changed paths are `build/tooling.zig`, `packages/proof-review/src/printer.zig`, `packages/zts/src/object.zig`, and `packages/zts/src/trace.zig`.
They also include `packages/zts/src/type_pool.zig`, `scripts/audit-docs.sh`, `scripts/test-gate-floors.sh`, and `tooling/production_branch_metric.zig`.
No provider request, empirical recording, dependency addition, branch, worktree, or push occurred.

## Implementation evidence

All build commands below were unfiltered. The main agent ran the commands and read their direct exit statuses.

| Command or probe | Result and scope |
|---|---|
| `bash scripts/test-gate-floors.sh`, before U1 repair | Exit 1: empty documentation inventory incorrectly reported success |
| `zig build test-native-gates`, metric regression | Exit 1 at the lost metric prefix |
| `zig build test-native-gates test-production-branch-metric test-doc-links test-script-reachability` | Exit 0 before the later evidence-output probe was added |
| `zig build test-zts`, first allocation regressions | Exit 1: object retry damaged class metadata; array replay missed divergence; object replay had an invalid initial failure target |
| `zig build test-zts`, corrected replay probes and type-prefix regression | Exit 1: both replay probes missed divergence; type-prefix regression accepted trailing input |
| `zig build test-proof-review` | Exit 0 after dead printer deletion |
| `zig build test-zts test-precompile test-modules test-contract-golden` | Exit 1: only `test-zts` failed, at legacy constructor-order parity. The engine root and other selected steps passed. |
| `zig build test-native-gates`, additional evidence regression | Exit 1 at the lost evidence publisher prefix |
| `git diff --check` at pause | Exit 0 |

The U5 failure is `parsed lowering preserves legacy constructor name order` in `packages/zts/src/type_syntax_lowering.zig`.
`expectParsedLoweringMatchesLegacy` compares a now-rejected legacy result with a direct lowering result. The observed mismatch is expected 65535, found 11.
The main agent has not identified which case triggers the mismatch. The next session must inspect the case before changing expectations.

The new U3 test is `replay rejects argument serialization allocation failure` in `packages/zts/src/trace.zig`.
`replayRecordedEntry` still ignores a null result from `serializeArgsJson`. An allocation-free recorded result can then avoid the decoder failure path.
This is a source finding with an unrun regression, not a confirmed new red result.

The implementation logs are machine-local files under `/tmp/`:
`zttp-round4-u1-red.log`, `zttp-round4-u1-metric-red.log`, `zttp-round4-u1-green.log`, and `zttp-round4-u1-evidence-red.log`.
They also include `zttp-round4-u2-u3-red.log`, `zttp-round4-u3-u5-red.log`, `zttp-round4-engine-green.log`, and `zttp-round4-u8-green.log`.
The filename `engine-green` names the intended check. Its actual exit status is 1, as the table records.

## Next action

The next session owns continuation after the owner resumes work.
The next check is the pending U3 regression and the exact U5 parity case, followed by U1 output repairs and unfiltered named gates.
Production changes remain uncommitted until their units pass the required checks.

# Hardening and pruning worklog, round 4

## Objective and constraints

The owner requested a ranked list before more features. The list must reduce complexity without losing functionality.
The owner authorized implementation with `go ahead` after accepting the ranked list.
The [implementation plan](2026-10-24-hardening-pruning-plan.md) bounds the work. No Git history rewrite is authorized.
The source baseline is `d7aaf1f4`. Work stays on local `main`, with no push.
Standing decisions in `docs/decisions.md` still apply. Earlier closed findings stay closed unless current evidence contradicts them.

## Completed work

Current status, 2026-10-24: the full sequential local verifier and benchmark gate passed after the owner enabled unrestricted execution.
U1 to U11 are committed locally; U12 remains deferred by the owner, and U13 retains the current serialized representations for compatibility.
The final section below records the passing checks and commit map and supersedes the earlier sandbox and commit limits.
The owner's independent `README.md` edit remains outside these commits. Nothing was pushed.

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

## Resumed implementation, 2026-10-24

The owner resumed the handoff and confirmed continuation. This section supersedes the paused checkpoint above.
The source HEAD is still `101d512f` on local `main`. No branch, worktree, dependency, provider request, or push was created.
No workers were used during resumption.

### Implementation and dispositions

| Unit | Result in the working tree | Evidence and remaining limit |
|---|---|---|
| U1 | Documentation inventory and scanner failures reject. The metric and all four evidence commands stream stdout and propagate flush errors. | A valid-fixture probe observed all four evidence commands erase a prefix before repair. The repaired prefix probes and core named gates pass. |
| U2 | Hidden-class metadata, properties, transitions, and sorted indices reserve capacity before publication. | The failure sweep crosses the sorted-property threshold and retries through public property APIs. Unfiltered `test-zts` passes. Runtime integration is limited by the socket sandbox below. |
| U3 | Replay decoding propagates allocation and container failures, checks full consumption, and counts argument-serialization failure as divergence. | The resumed argument probe failed with zero divergences before repair. Container, trailing-input, null/undefined, and allocation regressions pass in `test-zts`. |
| U4 | `reuse_unbounded` release checks hidden-class count as well as atom count. The new class ceiling is 8,192. | Six fixed names add exactly 1,956 classes while atom count stays fixed. The measured pool held 2,226 classes, 266,564 bytes of SoA capacity, and transition-map capacity 4,096. The release regression failed before repair; final runtime integration remains limited by socket permissions. |
| U5 | Binding type expressions require full consumption after whitespace. The public binding-parser regression and signature census pass. | The parity mismatch was `(first: Left, Right)`. Four malformed historical group forms now explicitly require binding rejection while preserving direct admission's exact pool construction and named prefix. No valid signature golden moved. |
| U6 | Return classification and narrowing use validated syntax. Tabs and newlines preserve predicates; a quoted `"x is y"` remains a string literal. | Frontend and CHECK expectations assert the intended type/predicate diagnostics. Empty malformed narrowing keeps its prior refusal path. The changed literal/tab spellings occur in zero empirical corpus files; offline cassette replay passes. |
| U7 | Interned, owned, and arena string construction, plus both concatenation paths, check the signed handler length limit before allocation. | Boundary tests allocate no huge strings. Concatenation tests use a failing allocator and require that no allocation was attempted. SDK, module, and ZTS suites pass. |
| U8 | Unused printer, progress, buffering, clock, and six self-tests are deleted; `FdWriter` remains unchanged. | Caller census finds only live `FdWriter` users in proof CLI and live reload. `test-proof-review` passes. CLI/server integration reaches denied loopback binds. |
| U9 | Identical provider response-field, argument, depth, and name validation is shared in `providers/response_fields.zig`. | The extraction checked both original bodies for equality. Provider-specific transport, reasoning, and envelope recovery remain separate. Cassette replay passes; app, simulator, and recorder network tests are sandbox-limited. |
| U10 | The aggregate runs enclosing roots instead of four complete focused subsets. Named suites remain callable and explicitly classified in `manual-steps.allow`. | Collected inventories show no missing member: precompile 318 and canonicalize 390 within agent protocol 536; cassette 388 and simulator 818 within expert app 925. This removes 1,914 repeated collected entries. No aggregate timing improvement is claimed. |
| U11 | Graph-built executables feed kernel safety, residual extraction, and the metric. The typed module renderer replaces the duplicate shell catalog comparison. | The renderer gate uses the emitted binary path, accepts an isolated valid copy, and rejects its stale catalog. Script floors and direct-script fallback entry points remain. Structural gates pass; residual behavioral evidence needs loopback permission. |
| U12 | Pending, unchanged. | The owner explicitly chose “Leave proof defaults and recordings pending” during resumption. No paid request, credential check, default flip, golden rewrite, or cassette replacement occurred. |
| U13 | Retain the current representations in this round. | `root.zig` publicly exports `Opcode` and bytecode deserialization. `semantics.opcodeDisposition` still publishes `rot3`, `inc`, and `dec` as trusted operations. Their absence from compiler emission is not evidence that deleting their accepted serialized representation preserves embedding behavior. No complete independent confirmation of the audit's fifteen-opcode count is claimed. A later compatibility change must define its admission/version policy and run its census before deletion. |
| U14 | The plans index now follows the completed round 3 worklog and the resumed round 4 state. | Round 3 decision 5 is resolved as (b), and its final gates and later corrections are recorded. No historical findings were deleted. |

The 8,192-class ceiling permits the six-name permutation workload but is below all seven-name permutations (13,699 added classes).
This is a release-time count bound, not a bound on one request's peak allocation or total retained bytes.

### Measurements and inventories

The temporary inventory runner enumerated `builtin.test_functions` from the real named build roots without executing their tests.
The exact root inventories were compared as sets, with a nonempty inventory for each root and zero missing entries for every subset above.
The temporary `build/Context.zig` instrumentation was restored byte-for-byte; no inventory option or runner was added to the repository.
Inventory runs are collection evidence only, not passing behavior gates.
The machine-local inputs and comparison are `/tmp/zttp-round4-inventory-test-*.log` and `/tmp/zttp-round4-inventory-comparison.log`.

Two samples of the direct-script path before changing native ownership, then the emitted-tool path:

| Tool | Before, first/warm seconds | Emitted tool, first/warm seconds |
|---|---|---|
| Kernel safety | 1.63 / 0.11 | 0.08 / 0.06 |
| Residual extraction and shell comparisons | 1.69 / 0.23 | 0.23 / 0.16 |
| Production branch metric | 2.28 / 0.70 | 0.84 / 0.65 |

The first before sample used a fresh local tool cache. The emitted-tool sample excludes its prior graph compilation.
These small samples demonstrate removal of nested compiler startup, not a cold aggregate build speedup.
The logs are `/tmp/zttp-round4-native-before.log` and `/tmp/zttp-round4-native-after.log`.

### Verification after resumption

All named behavior commands were unfiltered. Deliberate test-selection rejection probes inside `test-native-gates` remain part of that gate; their filtered child runs establish no whole-suite verdict.
Both inherited Zig cache variables pointed outside writable roots. Resumed checks set `ZIG_LOCAL_CACHE_DIR=/tmp/zttp-impl-cache` and `ZIG_GLOBAL_CACHE_DIR=/tmp/zttp-zig017-cache`.
The original cache-configuration failures and interrupted combined attempt are not behavior evidence.

| Check | Result |
|---|---|
| `test-zts`, resumed red run | Exit 1: argument serialization reported zero divergences, and the exact malformed group parity case failed. Log: `/tmp/zttp-round4-zts-red.log`. |
| `test-native-gates`, four-writer red probe | Exit 1: all four named evidence prefixes were lost. Log: `/tmp/zttp-round4-stdout-red.log`. |
| Initial U4/U9 check | Exit 1: the new retention test failed with zero recycles, alongside socket-limited integration tests. Log: `/tmp/zttp-round4-u4-u9-red.log`. |
| Core 20-suite command below | Exit 0. Log: `/tmp/zttp-round4-core-final.log`. |
| `zig build test-docs-drift check-spine test-spine test-step-coverage test-script-reachability test-proof-swallow test-doc-links -j4` | Exit 0, including the final stale-catalog rejection probe. Log: `/tmp/zttp-round4-final-structure.log`. |
| `zig build test-zruntime` | Exit 1: 224 passed, 11 failed at socket operations with errno 1. Log: `/tmp/zttp-round4-zruntime.log`. |
| `test-cli`, `test-server` integration during resumption | Socket binding is denied. The first server run had 335 passing tests, two skipped, and five socket failures; CLI reported three socket failures. These are failed suites, not passing gates. Log: `/tmp/zttp-round4-resume-green.log`. |
| Required provider app/simulator/recorder and residual stand-in checks | Their loopback tests fail or abort at denied socket operations. Offline `test-cassette` passes. Logs: `/tmp/zttp-round4-u4-u9-red.log`, `/tmp/zttp-round4-named-gates.log`. |
| `zig build bench-check` | Exit 1: `intArithmetic` measured 18,389,113 ops/s against 21,920,210, a 16.11% shortfall. The gate warns that the committed baseline uses Zig 0.16.0; this run uses 0.17.0. Log: `/tmp/zttp-round4-bench-check.log`. |
| First `bash scripts/verify.sh` | Exit 1 at its unfiltered aggregate: 204/213 steps succeeded; the summary reports 3,435 tests passed, five skipped, nineteen failed, and one crashed. Socket failures affected six roots; the seventh failure was the new fixture's literal marker being counted as a third producer. Log: `/tmp/zttp-round4-verify.log`. |
| Second `bash scripts/verify.sh` | Exit 1 at its unfiltered aggregate: 205/213 steps succeeded, with six failed roots. The summary reports 2,077 tests passed, five skipped, nineteen failed, and one crashed; cache reuse means this is not a unique whole-suite count. All remaining failures and the crash occur at denied socket operations. The driver stops at this route, so later routes did not run. Log: `/tmp/zttp-round4-verify-final.log`. |
| Final named gates after retaining the spec inventory check | Exit 0: `test-docs-drift test-capability-audit test-native-gates test-convergence-emitter check-spine test-doc-links -j4`. This includes rejection of the extra-spec inventory, stale catalog, empty/failed documentation scan, and all stdout-prefix probes. Log: `/tmp/zttp-round4-last-gates.log`. |

The successful core command was:

```sh
zig build test-zts test-precompile test-diagnostic-corpus test-native-gates \
  test-production-branch-metric test-docs-drift test-module-governance \
  test-step-coverage test-proof-swallow test-module-boundary test-sdk \
  test-modules test-cassette test-agent-protocol test-canonicalize \
  test-proof-review test-evidence-publish test-release-provenance \
  test-coverage-union test-kernel-safety -j4
```

Intermediate runs also exposed the predicate expectations that intentionally captured the old misclassification and one temporary test-edit syntax error; these were repaired before the successful core command.
The filenames containing `green` or `final` are labels, not verdicts. Only the recorded exit status establishes a command's result.

The full aggregate exposed an interaction absent from the focused core run: the stdout fixture's literal coverage marker entered the two-site producer/consumer census.
The fixture now receives the publisher's existing exported marker constant as an argument. There is no second marker definition, marker construction workaround, or scanner exception.
The exact two-site rule and its existing gate remain unchanged. The repaired named output gates run again before the final sequential attempt.

Final source review also distinguished the spec-file inventory count from the removed content comparisons.
The renderer checks its known paths but does not inventory extra JSON files. The shell retains the original count invariant, including Git failure propagation.
A fake Git inventory with one extra spec made the new rejection probe fail before restoration (`/tmp/zttp-round4-spec-inventory-red.log`).
The final named gate run after this restoration covers docs drift, capability and inventory probes, native gates, convergence publication, spine, and documentation links.

To distinguish a new regression from the existing benchmark shortfall, an archive of unchanged HEAD was built with the same Zig 0.17.0, with no Git branch, worktree, or repository mutation.
Five interleaved executions of each benchmark binary used the gate's per-benchmark best-rate aggregation.
Unchanged HEAD measured 19,319,938 arithmetic ops/s, already 11.86% below the committed baseline; the working tree measured 19,047,619, a further 1.41% decrease.
Across all thirteen measured benchmarks, changes relative to unchanged HEAD range from -1.41% to +3.37%.
This sample shows no new shortfall above the gate's 8% individual threshold; it does not make the committed-baseline gate pass or isolate the toolchain as the cause.
The comparison is `/tmp/zttp-round4-bench-comparison.json`; its ten raw reports are `/tmp/zttp-round4-bench-{head,working}-{0..4}.json`.
The baseline archive and build are machine-local under `/tmp/zttp-round4-baseline` and `/tmp/zttp-round4-baseline-cache`.

### Commit and environment limits

Automatic isolated local commits were authorized and attempted. Git refused to create `.git/index.lock` with `Operation not permitted`.
A direct `git restore --staged -- packages/pi/src/providers/response_fields.zig` also exited 128 with the same error.
The permission profile makes `.git` read-only and provides no approval escalation. No commit, stash, reset of source files, or history rewrite was performed.
The new response helper was staged before the later index operations were refused; the other changes remain unstaged.
All implementation changes still depend on this working tree. The next session needs this checkout, not just the committed paused worklog.

During full verification, an independent edit added an experimental-software notice to `README.md`.
That file was not edited by this implementation and must be kept separate from its commits.
Implementation whitespace checks exclude that concurrent README edit; the changed Zig files pass `zig fmt --check`.

The socket sandbox is a separate blocker: a listener bind fails with errno 1 before the requested integration scenario can execute.
No test was skipped, weakened, or filtered to turn those failures into a claimed pass.
The remaining completion work is local commits and unfiltered runtime/full verification in an environment that permits repository Git writes and loopback sockets, plus any fixes those real executions reveal.
The committed-baseline benchmark gate also remains red; the comparison above bounds what this implementation's same-toolchain sample establishes. No benchmark baseline was rewritten.

## Full verification with unrestricted execution, 2026-10-24

The owner enabled unrestricted filesystem and network access and requested full verification.
The earlier Git-write and loopback blockers no longer apply. The same implementation bytes that had failed at socket setup now pass the full local driver.
No test, threshold, baseline, or provider recording was changed to obtain the passing result.
The implementation was then committed in the isolated units below, preserving the owner’s README edit and staying on local `main` with no push.

| Command | Result | Machine-local log |
|---|---|---|
| `bash scripts/verify.sh` | Exit 0: unfiltered aggregate, standalone runtime root, optimized binaries, verified handler precompilation, v1 smoke, panic isolation, normalization idempotence, installer archive safety, semantics specification, and formatting all passed. | `/tmp/zttp-round4-unrestricted-verify.log` |
| `zig build bench-check` | Exit 0: nine benchmarks compared, geomean 0.98713, regression 1.29%. The tool still warns that the baseline used Zig 0.16.0 and the current toolchain is 0.17.0. | `/tmp/zttp-round4-unrestricted-bench-check.log` |

Both commands used `ZIG_LOCAL_CACHE_DIR=/tmp/zttp-impl-cache` and `ZIG_GLOBAL_CACHE_DIR=/tmp/zttp-zig017-cache`.
The benchmark ran after the sequential verifier finished, without concurrent compilation.
Its passing result supersedes the earlier benchmark failures for the current run; the earlier measurements remain scoped historical evidence.
The aggregate completed the previously blocked CLI, server, expert-app, recorder, and stand-in tests. The standalone runtime root passed in its own process.
No filtered behavior run was used for a named-suite verdict.

| Unit | Local commit |
|---|---|
| U1: reliable check output | `e20a38ca` |
| U2: atomic object layouts | `53609c59` |
| U3: strict replay decoding | `4a5cc96c` |
| U4: bounded layout retention | `ef3b64ac` |
| U5: complete type parsing | `df97cbbd` |
| U6: one predicate authority | `c9d756b0` |
| U7: representable string lengths | `1ced6f95` |
| U8: printer scaffolding deletion | `cc3874a2` |
| U9: shared provider validation | `f70e85a9` |
| U10: aggregate test routes | `3ac556e6` |
| U11: typed document and native gate ownership | `cf4626a8` |

U14 is the final documentation commit containing this record and the corrected plans index.
U12 remains explicitly pending: proof defaults and paid provider recordings were not run or changed.
U13 retains the existing IR/opcode representations under the compatibility disposition above.
Release-only provenance and publishing checks, cross-platform execution, and real-provider requests were not part of this per-commit verification.

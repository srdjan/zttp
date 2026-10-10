# Minimal design implementation worklog

The user authorized the full scope of `2026-10-08-minimal-design-audit.md`.
The user paused the work on October 9 and resumed it on October 10.
The resumed baseline was clean local `main` at `7912bb56`.

## Constraints and direction

Preserve public output, errors, byte ownership, request isolation, and provider identity.
Keep the producer and acceptance kernel independent.
Use unfiltered named checks and read each build exit status directly.
Work on local `main`. Commit each complete unit locally. Do not push.
The main agent reviews each delegated diff and runs authoritative checks.

## Scope and evidence

| Requirement | Current state | Required evidence |
|---|---|---|
| Remove withdrawn repairs and classify scanner helpers | Committed `da7b7ddf` | Census and required checks passed; withdrawal note retained |
| Remove obsolete WebSocket methods | Committed `838657be` | Export check and required checks passed; historical claim corrected |
| Combine proof JSON writers | Committed `ef322d09` | Exact public output and required checks passed |
| Share receipt lookup | Committed `fbd662d0` | One borrowed lookup; both named checks passed |
| Share catalog field parsing | Committed `82c07a5c` | All five required named checks passed |
| Consolidate query operation boundary | Committed `7dc121c7` | Public schema, alias, error, filtering, and expert checks passed |
| Share runtime invocation policy | Committed `490c0b23` | Server, runtime, and full test checks passed |
| Retire unread latency telemetry | Decision 1 pending | Published API confirmed; reviewed patch awaits a contract decision |
| Give provider configuration one owner | Committed `02f8b22c` | Failure cleanup, atomic restamping, identity, expert, and cassette checks passed |
| Migrate positional check calls | Committed `d05cf864` | All 96 calls migrated; all six required named checks passed |
| Correct compile completeness | Committed `448c3a4f` | Public regression and all four required named checks passed |

## Current work and next action

The main agent owns authoritative checks, review, commits, and this worklog.
The completed receipt unit is commit `fbd662d0`.
The receipt baseline passed with 1127 tests and one skipped test.
The strengthened malformed-identity test passed before the lookup change.
The unfiltered `test-expert-app` and `test-standin` checks passed after the change.
The logs are `/private/tmp/zttp-minimal-receipt-characterization.log` and `/private/tmp/zttp-minimal-receipt.log`.
The lookup returns a borrowed receipt. Autoloop finalization derives both values before any transcript mutation.

Public writer characterization passed before consolidation through `test-zts-cli`.
The tool check batch passed 689 tests and all 58 build steps.
The log is `/private/tmp/zttp-minimal-tools.log`.
The WebSocket and invocation batches each passed 1053 tests with three skipped tests.
Their logs are `/private/tmp/zttp-minimal-websocket.log` and `/private/tmp/zttp-minimal-invocation.log`.

The provider baseline passed 1133 tests with one skipped test.
The query baseline passed 1138 tests with one skipped test.
The catalog baseline passed 2723 tests with one skipped test.
These baselines include characterization before production changes.
The logs use the `zttp-minimal-provider`, `zttp-minimal-query`, and `zttp-minimal-catalog` prefixes under `/private/tmp/`.

The compile regression returned success but falsely marked summarized loop behavior exhaustive.
Check correctly marked the same handler incomplete.
The failing public API regression is in `/private/tmp/zttp-minimal-completeness-red.log`.
Both paths now call one generated-path summary; generation and fault analysis stay separate.
The correction changes contract metadata, not fault judgments or the analyzer version.

The integrated batch began before final provider and query refinements.
The batch compiled an intermediate provider file with shadowed parameter names.
The final provider design removes those constructors.
That failed batch supplies no overall pass claim; later terminal checks cover the corrected source.
The flow census passed all 776 probes.
The separate core batch exited 0: all 45 steps passed, with 3650 tests passed and one skipped.
The log is `/private/tmp/zttp-minimal-core-green.log`.
The mutation check killed 277 non-equivalent mutations and retained nine documented equivalent mutations.
No mutation timed out, failed to compile, or produced a harness error.

Provider review found changes to controlled sessions and recorder policy defaults.
The provider worker restored both behaviors before final validation.
The first provider batch found a shadowed allocator-cleanup variable; the main agent corrected its name.
The cassette step passed 425 tests, while that overall batch exited 1.
The full unfiltered batch exited 0: all 219 steps passed, with 10382 tests passed and six skipped.
The log is `/private/tmp/zttp-minimal-full-green.log`.
The batch includes `test-expert-app`, `test-cassette`, `test-precompile`, `test-zts-cli`, `test-canonicalize`, `test-agent-protocol`, and `test`.
The main agent reviewed all changed code lines and checked formatting.
The final caller batch checks stable committed source after the migration.
The batch exited 0: all seven steps and 607 tests passed.
Its log is `/private/tmp/zttp-minimal-final-callers.log`.
Nine reductions and the completeness correction now have ten isolated local commits.
Four further commits contain the accepted simplifications.
No commit was pushed.

Code review: skipped (ce-code-review unavailable).
The skill requires Python helpers; the repository prohibits Python.
The main agent reviewed every changed code line and checked formatting.
An independent Sol review found no correctness defects in the ten implementation commits.
The reviewer also examined every line of the six later product changes and found no behavioral defects.
The reviewer did not run tests; the main agent owns the reported build results.
The three `ce-simplify-code` passes review reuse, quality, and efficiency.
The efficiency pass found no worthwhile changes.
The reuse pass proposed three changes; the main agent accepted all three.
Commit `32381933` removes the capture wrapper and calls the session method directly.
Commit `1de1d9e7` uses the existing single-argument helper and removes a duplicate catalog count assertion.
Commit `3cafed29` derives the authentication label from the owned transport.
The quality pass proposed four changes; the main agent accepted two and retained two existing designs.
Commit `5db9985e` omits default check options in the holes and browser analysis paths.
The catalog assertion removal is the other accepted quality change.
The retained provider initializer has checked callers that supply authentication for every remote transport.
A new provider-tagged initializer would add a broader data model without a demonstrated behavior defect.
The retained private path summary has two callers with explicit ownership of fault analysis.
Compile reads only generated-path metadata; check fills fault fields before exposing verdicts.
A separate summary type would add another shape without correcting an observed behavior.
The final simplification batch exited 0: all 16 steps passed, with 1545 tests passed and one skipped.
The unfiltered steps were `test-expert-app` and `test-cassette`.
The log is `/private/tmp/zttp-minimal-simplify.log`.
Formatting and `git diff --check` passed after the simplifications.

## Source measurement

The baseline snapshot contains only Zig files from `7912bb56`.
Both measurements use Zig 0.16.0 and the current production branch metric.
The small check parses one file: 45 branches, six functions, and zero parse failures.
The baseline parses 649 files: 71053 branches, 11552 functions, and a combined score of 82605.
The current tree parses 644 files: 70973 branches, 11560 functions, and a combined score of 82533.
The current measurement includes the new provider backend and excludes deleted query wrappers.
The change removes 80 measured branches and adds eight functions; the combined score falls by 72.
This measurement describes source decisions. It does not establish a runtime performance benefit.
The metric includes test helpers defined outside test blocks.
The JSON results are `/private/tmp/zttp-minimal-metric-before.json` and `/private/tmp/zttp-minimal-metric-after.json`.

The final declaration census finds 27 candidates in tracked Zig files.
The main agent repeated the census after the final wrapper removal.
It excludes none of the new provider backend because the backend is now tracked.
The removed repair and WebSocket names no longer occur.
The full list is `/private/tmp/zttp-minimal-census.txt`; candidates outside the selected reductions remain unchanged.

## API decision

Published `v0.21.0` sources expose both obsolete WebSocket methods and `getMetrics`.
The runtime package publishes all source files. External caller usage remains unknown.
The tools package exports `zts_cli.precompile`, including the positional check wrappers.
The positional wrappers remain. All repository callers now use named options.
Decision 1 asks the user whether to remove the ten latency fields and recording code.
The decision preserves operational counters and the acquisition timeout timer.
The reviewed draft is `/private/tmp/zttp-minimal-telemetry.patch`.
The draft removes `avg_wait_ns`, `max_wait_ns`, `avg_exec_ns`, and `max_exec_ns`.
It also removes `wait_p50_ns`, `wait_p95_ns`, `wait_p99_ns`, `exec_p50_ns`, `exec_p95_ns`, and `exec_p99_ns`.
The draft removes latency recording and the sole-use percentile module.
Request identity, operational counters, acquisition timeout, and timer-start failure remain unchanged.
The draft passed formatting and `git apply --check` but has not been applied or tested.
The main agent will apply, test, and commit this unit only after Decision 1 permits removal.

The provider ownership consultation route is unavailable.
The advisor runtime inspector could not identify the parent runtime.
The main agent retains design and verification ownership.
The completion preflight also reports `parent_runtime_unavailable`.
No advisor child ran, and no advisor approval is claimed.

## Remaining action

The user owns Decision 1: remove the ten latency fields and their recording code, or retain the published API.
Removal is the recommendation because tracked callers use only operational counters.
External caller usage remains unknown; removal authorizes the corresponding source API change.
The audit requires this contract decision before removal.
The main agent will apply the reviewed patch and run all three required runtime checks if the user selects removal.
The full audit scope remains open until Decision 1 is resolved.

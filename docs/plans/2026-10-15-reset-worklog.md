# Reset implementation worklog

## Objective and authority

The [reset plan](2026-10-14-reset-implementation-plan.md) owns design, phase order, and acceptance.
This worklog records execution evidence and current work.
The user approved implementation with "reviewd, go ahead, use subagents when possible, verify with astra" on 2026-10-15.
That approval supersedes the plan's earlier planning-only authorization paragraph.

## Constraints

Work stays on local main, with one local commit for each completed phase.
No push, live model recording, corpus replacement, or public format change is authorized.
Current public behavior remains compatible except for the planned sibling-effect correction.
CHECK retains its distinct imported traversals and exact reader observations.
The main agent owns authoritative verification and commits.
Sol workers use high reasoning effort. Astra supplies independent review.

## Starting state

The starting commit is `f917dc0b7320ecd0165e49a274311f77b3290796`.
Its tracked tree is `d3b97c46e4ee5fbd0da9174d4343887fbbbc7e16`.
The reset plan was an untracked document offered and approved by the user.
The untracked `2026-10-14-sibling-module-effects-plan.md` belongs to Claude's earlier session and remains excluded.
No tracked source changes existed when execution started.

## Current work

U1 (compatibility baseline) is complete.
The Sol workers returned frontend and CHECK characterization tests without changing production behavior.
The main agent reviewed every changed source line and corrected the fixture assumptions that Astra identified.
The main agent also owns documentation links and authoritative verification.
The full local gate passed. Git history records the phase commit.
The Sol explorer completed U2 (sibling export effects) load-path review without editing code.
U1 (compatibility baseline) is committed as `ad1aa961`.
Three Sol workers returned effect analysis, contract integration, and CHECK integration for U2 (sibling export effects).
The main agent completed the final corrections, documentation, and authoritative checks.
Astra accepted the final source review. The additional suites, standalone runtime, and full local gate passed.
U2 (sibling export effects) is complete. Git history records the phase commit.
A Sol explorer completed the read-only U3 (analysis lifetime consolidation) review.

## Verification and completion

The first unfiltered focused run exited 1: 3,473 tests passed, one skipped, and one failed.
The failure was an incorrect new fixture, not a production change.
Named return annotations retain their function names and raw trailing spaces.
The corrected unfiltered run exited 0: 3,474 tests passed and one skipped across 34 successful steps.
The diagnostic corpus reported 182 cases and zero failures in the first run.
The logs are `/tmp/zttp-reset-20261015/u1-focused.log` and `/tmp/zttp-reset-20261015/u1-focused-corrected.log`.

Astra reviewed the corrected U1 (compatibility baseline) diff and found no remaining blocking issue.
The review added a typed mismatch contrast and a compilation contrast to strengthen the baseline.
The main agent also added an exact normalized-output fixture through the public normalize function.
The review is source evidence; it does not replace authoritative test results.
The separate spine and formatting checks both exited 0.
The full local gate exited 0, with recording and evidence publication disabled in its environment.
Its log is `/tmp/zttp-reset-20261015/u1-verify.log`.

The prior Claude logs cover the starting tracked tree, not the new characterization tests.
The final documentation checks also exited 0.
Their log is `/tmp/zttp-reset-20261015/u1-docs-final.log`.
U2 (sibling export effects) is complete. U3 through U20 remain unstarted.

## Unresolved questions and next action

No product decision blocks U3 (analysis lifetime consolidation).
The main agent will specify and delegate one session owner after committing U2 (sibling export effects).

## U2 preparation evidence

The Sol explorer confirmed existing loaded-source seams for U2 (sibling export effects).
CHECK can extend `importedFunctionSummary` and its current recursive collector without adding reads.
When the existing type check stops traversal, transitive effects must remain incomplete instead of loading more files.
The two graph contract loops already retain parser IR, shared atoms, roots, and execution order.
They can project export summaries from that loaded state without filesystem access.

Export projection must distinguish functions, function holders, plain data, and missing exports.
Holder effects require final user-function rows as well as the initializer row.
Owned export tables must outlive loader cleanup without retaining borrowed names.
The cache-read and egress bridges remain necessary before U5 (contract effect facts) removes the old summary producer.
The accepted interface distinguishes callable exports, proven data exports, and blocked exports.
Each import outcome uses the module's local binding slot.
The export table owns its names and contains no borrowed parser state.
Contract extraction publishes the table only after every extraction check succeeds.

Legacy import charging remains in place.
New effects can reduce guarantees, but cannot grant new capability or purity claims.
Blocked effects include possible writes and egress, with incomplete analysis recorded explicitly.
An initializer that calls a factory does not establish a non-callable data export.

The main agent captured the current defect through the built CLI before production edits.
A handler calls a sibling that writes through `cacheSet` and declares `read_only` and `retry_safe`.
The command exited 0 and reported both properties as true.
The fixture is `/tmp/zttp-reset-20261015/sibling-writer/`.
The result is `/tmp/zttp-reset-20261015/u2-baseline-writer.json`.
The first attempted fixture used prohibited `void` syntax and therefore supplied no valid writer evidence.
The corrected fixture uses `undefined` and produced no stderr diagnostic.

## U2 review and verification

The first integration run exited 1.
It reported 2,617 passing tests, one skipped test, three failed tests, and one crashed test.
The log is `/tmp/zttp-reset-20261015/u2-integration-first.log`.
One old test expected absent sibling summaries to establish clean effects.
Two new fixtures used unavailable names or unsupported typing and required correction.
The graph test also required correction because merged contracts expose no entry properties.

The main agent rejected a proposed transfer of capsule diagnostics into merged output.
That transfer changed public behavior beyond the approved correction.
The tools graph test now checks merged compatibility.
The pipeline test checks entry properties before merging, through both extraction profiles.
Source review checks the tools loop's use of that same import mapper.

Astra identified incomplete callable rows that still claimed no egress.
The main agent now adds possible writes and egress when an imported row is incomplete.
Known data calls remain refused or incomplete without acquiring a false callable classification.
The new public callback test checks the incomplete egress explanation.

Astra identified a duplicate namespace release after late export-capture failure.
The namespace now has one owner after contract construction.
A measured allocation failure exercises that cleanup path.
The CHECK worker also preserves the final type-health check after every imported flow attempt.
Effects do not borrow a type environment after type setup or flow analysis poisons that environment.

The corrected additional suite run exited 1 because the proof-swallow gate rejected an unexplained default.
It reported 4,025 passing tests and two skipped tests, with 51 of 53 build steps successful.
The log is `/tmp/zttp-reset-20261015/u2-focused-corrected.log`.
The flow census matched all 734 expected verdicts.
The diagnostic corpus passed all 182 cases.
All 33 example suites passed.
The proof-swallow gate requires an explanation for the new conservative default.
Astra also identified name resolution incorrectly blocking holder registration without an atom table.
The main agent added a focused regression before correcting that registration.
The regression uses the standalone parser without an atom table.
The fixture derives its padding from `Atom.FIRST_DYNAMIC` and asserts that the holder name exceeds the predefined range.
The first unfiltered `test-zts` run exited 1 at an incorrect assertion in the new fixture.
Native `Math.random()` clears determinism and purity, but does not add the `random` capability in this analyzer.
The fixture now asserts the established determinism, purity, and holder behavior.
The corrected unfiltered run exited 1 at the intended nondeterminism assertion.
It reported 2,416 passing tests, one skipped test, and one failed test.
Its log is `/tmp/zttp-reset-20261015/u2-null-atoms-red-corrected.log`.
Holder registration now retains the original binding key when no name resolves.
Only export publication requires a resolved name.
The conservative default now explains why unproved shapes remain blocked.
The final additional suite run exited 0.
All 53 steps succeeded, with 4,026 passing tests and two skipped tests.
Its log is `/tmp/zttp-reset-20261015/u2-focused-final.log`.
Astra reviewed the final source diff and found no remaining blocking issue.
That review includes the optional holder name, conservative imported rows, cleanup, and unchanged merged output.
The formatting check and `git diff --check` both exited 0.
The standalone runtime test root exited 0.
Its log is `/tmp/zttp-reset-20261015/u2-zruntime.log`.
The full local gate exited 0.
Its log is `/tmp/zttp-reset-20261015/u2-verify.log`.
The gate passed aggregate tests, standalone runtime tests, optimized builds, precompilation, smoke tests, shell gates, and offline replay.
The main agent added standing review dispositions to the plan authority.
The final documentation and spine checks exited 0.
Their log is `/tmp/zttp-reset-20261015/u2-docs-final.log`.

The main agent repeated the original public CLI probe against the rebuilt analyzer.
CHECK now exits 1 and reports `read_only` and `retry_safe` as false for the sibling cache writer.
The before and after fixtures use the same source files and command.
The corrected result is `/tmp/zttp-reset-20261015/u2-final-writer.json`.

## Frontend measurement baseline

The main agent ran the planned benchmark before the typed parser phases.
Zig reports version `0.16.0`.
The host reports `Darwin 25.6.0 arm64` and `Apple M4 Pro`.
The one-iteration pilot exited 0. All eight fixtures reported success.
The 50-iteration run also exited 0. All eight fixtures reported success.
Only the iteration parameter changed between runs.
The logs are `/tmp/zttp-reset-20261015/frontend-baseline-pilot.json` and `/tmp/zttp-reset-20261015/frontend-baseline.json`.
The harness measures parsing and code generation for its built-in fixtures.
The measurements establish no CHECK latency, imported-analysis cost, or performance improvement.

The 50-iteration observations provide the durable comparison baseline:

| Fixture | Nanoseconds per iteration | Allocated bytes | IR nodes |
|---|---:|---:|---:|
| `tiny_hello` | 7640 | 7218 | 16 |
| `small_arith` | 19160 | 10882 | 48 |
| `medium_object_ops` | 41080 | 23594 | 101 |
| `large_module` | 87340 | 47035 | 214 |
| `explicit_text_joins` | 35300 | 19872 | 86 |
| `member_chains` | 26360 | 14409 | 75 |
| `module_imports` | 21440 | 15188 | 46 |
| `html_component` | 38100 | 25132 | 110 |

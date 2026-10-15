# Reset implementation worklog

## Objective and authority

The [reset plan](2026-10-14-reset-implementation-plan.md) owns findings, design, phase order, and acceptance.
This worklog records current work and execution evidence.
The user approved implementation with "reviewd, go ahead, use subagents when possible, verify with astra" on 2026-10-15.
That approval supersedes the plan's earlier planning-only authorization paragraph.

## Constraints and starting state

Work stays on local main, with one local commit for each completed phase.
No push, live model recording, corpus replacement, or public format change is authorized.
Current public behavior remains compatible except for the planned sibling-effect correction.
The approved root capture phase also binds graph identity to verify override bytes.
CHECK retains its distinct imported traversals and exact reader observations.
The main agent owns review, authoritative verification, integration, and commits.
Each implementation phase uses a fresh Sol high worker. Astra xhigh supplies independent review.

The starting commit is `f917dc0b7320ecd0165e49a274311f77b3290796`.
Its tracked tree is `d3b97c46e4ee5fbd0da9174d4343887fbbbc7e16`.
No tracked source changes existed when execution started.
The reset plan was an untracked document offered and approved by the user.
The untracked `2026-10-14-sibling-module-effects-plan.md` belongs to Claude's earlier session and remains untouched and excluded.

## Current work and next action

U1 through U4 are complete and committed locally.
Every completed phase passed its required checks and Astra source review.
U5 (contract effect facts) passed its required checks and Astra source review; its local commit is next.
U6 through U20 remain unstarted.

The fresh Sol worker `reset_u5_contract_effects` returned the production migration and all assigned source ownership.
The unfiltered baseline passed before that migration.
The main agent completed source review and all required verification.
Astra xhigh accepted the actual U5 diff and final cleanup.
The main agent owns the plan authority, this worklog, checks, and Git writes.

The fresh U6 worker completed read-only preparation and awaits production ownership after the U5 commit.
U6 will first expose the remaining CHECK rereads through a controlled reader before migrating operation helpers.
No product decision blocks the next phase.

## Completed phases

All log names below are relative to `/tmp/zttp-reset-20261015/`.
The full gate disables `DEEPSEEK_API_KEY`, `ZTTP_CODEGEN_RECORD`, and `ZTTP_EVIDENCE_PUBLISH` in its environment.
Each full gate runs aggregate and standalone runtime roots in separate processes.
All named test runs are unfiltered, and their direct exit status supplies the verdict.
Source review does not replace test execution or establish a performance improvement.

| Phase | Local commit | Final additional-suite result | Full gate | Final documentation and spine |
|---|---|---|---|---|
| U1 (compatibility baseline) | `ad1aa961` | `u1-focused-corrected.log`: exit 0, 34 steps, 3,474 pass, 1 skip | `u1-verify.log`: exit 0 | `u1-docs-final.log`: exit 0 |
| U2 (sibling export effects) | `2f1ca7c5` | `u2-focused-final.log`: exit 0, 53 steps, 4,026 pass, 2 skip | `u2-verify.log`: exit 0 | `u2-docs-final.log`: exit 0 |
| U3 (analysis lifetime) | `f4967788` | `u3-focused-third.log`: exit 0, 36 steps, 2,865 pass, 1 skip | `u3-verify.log`: exit 0 | `u3-docs-final.log`: exit 0 |
| U4 (path effect facts) | `a13b1849` | `u4-focused-final.log`: exit 0, 30 steps, 2,854 pass, 1 skip | `u4-verify.log`: exit 0 | `u4-docs-final.log`: exit 0 |
| U5 (contract effect facts) | Pending this phase commit | `u5-focused-final.log`: exit 0, 39 steps, 3,090 pass, 1 skip | `u5-verify.log`: exit 0 | `u5-docs-final.log`: exit 0 |

Formatting and diff checks passed for each completed phase.
The full gates also passed optimized builds, precompilation, smoke tests, shell gates, and offline replay.
U2 also passed its separate standalone runtime command in `u2-zruntime.log`.
U2 and U4 matched all 734 flow probes.
U1 and U2 passed all 182 diagnostic cases.
U2 passed all 33 example suites; the full gates also run those suites.

## Earlier failures and review receipts

The plan authority records accepted design dispositions.
This ledger retains failed execution evidence and its correction.

| Run | Observed result | Correction or evidence limit |
|---|---|---|
| `u1-focused.log` | Exit 1: 3,473 pass, 1 skip, 1 fail | A new fixture lost a named return annotation's function name and trailing spaces. |
| `u2-integration-first.log` | Exit 1: 2,617 pass, 1 skip, 3 fail, 1 crash | One stale expectation and two invalid fixtures required correction. |
| `u2-focused-corrected.log` | Exit 1: 4,025 pass, 2 skip; 51 of 53 steps | The proof-swallow gate required an explanation for a conservative default. |
| `u2-null-atoms-red-corrected.log` | Exit 1: 2,416 pass, 1 skip, 1 fail | The intended nondeterminism assertion exposed missing holder registration without an atom table. |
| `u3-focused-first.log` | Exit 1 during compilation | A nested state type conflicted with the existing private state type. |
| `u3-focused-corrected.log` | Exit 1 during compilation | Five local captures conflicted with the new `facts` method. |
| `u4-zts-first.log` | Exit 1: 8 of 13 steps; 1,083 pass, 1 skip | A capture shadowed `complete`; one allocation-sweep helper call lacked the facts argument. |
| `u4-zts-corrected.log` | Exit 0: 13 steps, 2,428 pass, 1 skip | The corrected analyzer roots passed before broader checks. |
| `u4-focused.log` | Exit 0: 30 steps, 2,853 pass, 1 skip | A later failure probe increased the final passing count by one. |
| `u4-proof-swallow-first.log` | Exit 0 | U4 required no allowlist change. |

The first attempted U2 CLI fixture used prohibited `void` syntax and supplied no writer evidence.
The corrected baseline in `sibling-writer/` incorrectly held `read_only` and `retry_safe` for a sibling cache writer.
The rebuilt analyzer later exited 1 and reported both properties as false for the same files and command.
The result files are `u2-baseline-writer.json` and `u2-final-writer.json`.
The first null-atoms probe also asserted an incorrect `random` capability expectation.
Native `Math.random()` clears purity and determinism without adding that capability in this analyzer.

Astra's U2 review required conservative imported rows, safe namespace ownership, and holder registration without resolved names.
The main agent rejected new capsule arrays in merged output because they changed public behavior.
Merged properties remain null; tests observe entry properties before merging.

Astra's U3 review required resolution facts before custom callbacks and extraction refusal after selected-pass failure.
The final code preserves later callback-specific facts and permits unattempted flow after extraction.
The failure probes restore allocation before checking extraction refusal.

Main and Astra reviews of U4 required immutable slices, a required-name census, and stable heap-backed fixture facts.
Astra also identified allocation before an unmatched lower-level recursion query.
The main agent restored the previous allocation-free false result and added a public failure probe.
Astra accepted the corrected source before the final checks.

## U5 preparation and accepted direction

The Sol explorer `reset_u4_path_facts` mapped contract consumers without edits or builds.
The fresh worker then prepared the implementation design without edits or builds.
Astra reviewed the design with xhigh reasoning.

The first proposal overstated summary redundancy and universal import guards.
First-name handler identity can differ from the selected top-level handler.
Legacy callback traversal, nested targets, and raw-slot precedence also differ from ordinary effect rows.
An existing parsed-source authentication fixture exposes a slot collision that universal guards would change.
The baseline tests now confirm the exact fields under unchanged production code.

The accepted design keeps a completed `ContractEffectSummary` facet inside immutable `EffectFacts`.
The facet retains the exact legacy scalar summary, selected-handler identity, and first-name handler reachability.
The path profile distinguishes an unrequested facet from completed no-handler facts.
The producer releases traversal scratch before publication.
The builder borrows completed facts and clones returned exports.

Reference APIs retain each consumer's existing eligibility and resolution filter.
Existing module-reference guards remain guards; existing raw-slot consumers retain explicit legacy slot matching.
The reset does not silently correct those observable policies.
Main review found that global imports can share a slot and that consumers select different matching records.
The worker added explicit resolution filtering and first-or-last selection to preserve those policies.
Further main review found a function-node versus body-node identity mismatch in the new projection guard.
Main also found that schema-category lookup previously searched all matching slots, unlike the first-match authentication scan.
The worker received both corrections before the first production build.
The authority records the detailed source findings and accepted revisions.

## U5 baseline execution

The first unfiltered run exited 1: 2,433 tests passed, one skipped, and one failed.
The annotated duplicate-handler fixture incorrectly passed raw typed syntax to the JavaScript parser.
The main agent changed that fixture to use source preparation and a full session with its type map.
The main agent also corrected manifest cleanup after registry ownership transfer in a new test.
The log is `u5-baseline-first.log`.

The corrected run also exited 1 with the same test counts.
Its conditional block did not enter the analyzer's declaration list and therefore tested the wrong handler selection.
The main agent replaced the conditional with a bare block and retained the original assertions.
The log is `u5-baseline-corrected.log`.
All other new assertions passed under unchanged production code.
The final baseline run exited 0: all 13 steps succeeded, with 2,434 passing tests and one skipped test.
Its log is `u5-baseline-final.log`.

## U5 production checks

The first unfiltered production run exited 0: all 13 steps succeeded, with 2,440 passing tests and one skipped test.
Its log is `u5-zts-first.log`.
The first broader run exited 1: 37 of 39 steps succeeded, with 3,090 passing tests and one skipped test.
The proof-swallow gate rejected two moved default arms that lacked their scope explanations.
All 734 flow probes matched, and all 182 diagnostic cases passed in that run.
Its log is `u5-focused.log`.

Astra found no additional functional blocker in the source diff.
Main restored explicit legacy-scope explanations without widening the proof-swallow allowlist.
Main also removed unused reverse-selection branches from generic and extension reference APIs.
Import lookup retains both first and last selection because current consumers require both.
The corrected proof-swallow run exited 0 with no unreviewed cases.
Its log is `u5-proof-swallow-corrected.log`.
Astra accepted the final source cleanup and found no remaining source blocker.
Main reviewed every changed source line and retained the separate legacy summary policies.
The corrected broader run exited 0: all 39 steps succeeded, with 3,090 passing tests and one skipped test.
All 734 flow probes matched, and all 182 diagnostic cases passed.
Its log is `u5-focused-final.log`.
The full gate exited 0 with every CI test-job step passing.
Its log is `u5-verify.log`.
It passed the aggregate, separate runtime root, optimized builds, verified precompilation, smoke tests, shell gates, and offline replay.
Final documentation, link, and spine checks exited 0 in `u5-docs-final.log`.
Formatting across all required paths and the diff check also passed.

## U6 preparation

The Sol explorer `reset_u6_source_capture` mapped two production files without edits, builds, or tests.
They are `agent_protocol.zig` and `canonicalize.zig`.
Existing source APIs support the capture change; repair simulation needs a source-based helper.
The authority records root refusal, imported graph rejection, verify overrides, stale guards, and read-before-extension ordering.
The fresh implementation worker `reset_u6_capture_impl` completed read-only preparation and confirmed that bounded design.
Its source ownership remains withheld until U5 completes.
Main measured the pre-U6 CLI override mismatch in `u6-root-baseline/`.
Disk and override requests exited 0 with no protocol error and different source digests, but their graph hashes were equal.
These observations concern identity only; both property responses reported `success:false`.
U6 implementation remains unstarted.

## U7 preparation

The Sol explorer `reset_u4_path_facts` mapped the primitive parser slice without edits, builds, or tests.
The first slice covers one variable binding, primitive annotations, parentheses, and retained raw suffix text.
The authority records ownership, tier boundaries, original spans, and independent runtime comparisons.
Admission diagnostics must retain CHECK collection and compile refusal order before runtime parsing.
Astra identified that direct environment binding does not yet enable the existing checker's initializer enforcement.
U7 proves parser identity and environment lookup; U12 retains checker migration.
Astra accepted a bounded private comparison with complete preflight eligibility and an explicit `out_of_slice` outcome.
The authority records its accepted token boundary, refusal ordering, and previous-token requirements.
U7 implementation remains unstarted.

## U8 preparation

The Sol explorer `reset_u4_path_facts` mapped compound syntax without edits, builds, or tests.
Legacy semantic parsing accepts prefixes and has different array behavior for primitive, named, and generic types.
The authority records those distinctions and requires source-admission characterization before claiming incomplete forms remain accepted.
U8 implementation remains unstarted.

## U9 preparation

The Sol explorer `reset_u4_path_facts` mapped declaration semantics without edits, builds, or tests.
The authority records module-wide alias order, nominal identity, root-only eager lookup, recursive-alias rules, and runtime parity requirements.
Indentation and runtime-name collisions require characterization before the private parser claims compatibility.
U9 implementation remains unstarted.

## Frontend measurement baseline

The main agent measured the planned benchmark before the typed parser phases.
Zig reports `0.16.0`; the host reports `Darwin 25.6.0 arm64` and `Apple M4 Pro`.
The one-iteration pilot and 50-iteration run exited 0. All eight fixtures succeeded.
Only the iteration parameter changed.
The logs are `frontend-baseline-pilot.json` and `frontend-baseline.json`.
The harness measures source preparation, parsing, and code generation.
These observations establish no CHECK latency, imported-analysis cost, or performance improvement.

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

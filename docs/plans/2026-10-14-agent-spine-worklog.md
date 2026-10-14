# Agent spine worklog

## Objective and authority

Install a native Zig spine after the repository audit.
The user selected Option A on 2026-10-14.
Option A replaces the Deno implementation while preserving the spine contract.
The repository starts clean on local `main`.

## Constraints

Use Zig tooling. Preserve existing runtime behavior and gate ownership.
Keep the canonical gate sequential. Commit complete units and never push.
Seek approval before a script expected to exceed two minutes.
Keep temporary audit and migration artifacts under `.context/`.

## Accepted direction

The native gate consumes tasks from the complete live build graph.
The manifest records task policy, while the graph remains the task authority.
The installation adds area contracts, a decision ledger, navigation, and executable rejection evidence.

## Evidence

The audit measured 88 existing build steps: 86 declared steps, install, and uninstall.
The audit reconciled every declared task without extras or duplicates.
The canonical Deno anchor expression found 530 anchors across 46 documents.
Broader native checking also covers ranges and Markdown links.
The configured audit recommends installation.

## Current work

The implementation plan is `2026-10-14-agent-spine-plan.md`.
Native command, spine policy, and source-anchor migration can proceed in separate file sets.
The main agent owns build integration, generated root blocks, review, and final checks.

## Unresolved verification

The installed gate and its rejection probes have not run.
The full canonical gate needs authorization because its recorded runtime exceeds two minutes.
Next action owner: I will dispatch the independent units and review their results.

## Native command complete

The native command lives in `tooling/agent_spine.zig`.
The public command API drives clean, rejected, and restored fixtures.
The main review replaced a vacuous rejection census with observed rejection evidence.
The final suite covers all 12 failure kinds through 35 mutation scenarios.
The main review also fixed nested declaration matching, marker overlap, per-invariant gates, and missing ledger gates.
Git census paths retain their exact names, including whitespace.

The main agent ran unfiltered `zig build test-spine check-spine --summary all`.
All eight tests passed, and the installed spine check passed.
A direct executable probe returned 0, 1, and 0 for clean, unreachable-decision, and restored states.
The rejected run named the exact unreachable decision and its remedy.

The worker measured the six rejection groups at 333 to 561 milliseconds before the final missing-gate probe.
Those measurements describe that fixture revision, rather than the final added scenario.
No timing assertion controls CI correctness.

Next action owner: I will commit the native command, then finish the installation review and canonical gate authorization.

## Installed policy and gate

The manifest classifies all 91 live build steps exactly once.
The ledger records eight standing decisions with source evidence for their dates.
Eight marked area contracts connect ownership and invariants to existing gates.
Ten solution notes have explicit source bindings.
The documentation commit replaces source line citations in 56 files and adds the selected note bindings.
Root instructions and the testing guide also receive stable source references with their installation updates.

The main agent reviewed every changed citation and the native command source.
The review corrected compound citation tails and historical references that crossed from bridge input to checker source.
The review preserves the former transcript helper name as a historical fact.
File references remain when a reliable declaration cannot be recovered.
The checker recognizes complete inline source spans and Markdown link targets, rather than every possible prose citation spelling.

The main agent added a missing-gate probe and rejected self-supersession in the ledger.
The final rejection census covers all 12 failure kinds through 36 mutation scenarios.
The final native suite has nine public behavior tests.
The main agent ran the unfiltered spine suite and installed check after those changes.
All nine tests passed, and the installed check passed.

The main agent also ran documentation drift, documentation links, task coverage, script reachability, and module boundaries.
Each check exited 0.
Task coverage reports 91 steps and 13 manual steps with reasons.
The new manual row covers the interactive navigation command, rather than an omitted verification gate.
Formatting checks and Git whitespace checks exited 0.

A fresh agent reached each selected authority, area, invariant, and gate in two hops.
The drill covered runtime acceptance, flow analysis, and stand-in baseline recovery.
The drill found invalid decision fragments in the first brief output.
The corrected output names the ledger file and decision id without inventing a Markdown fragment.

## Verification still pending

`zig build release-check` exited 1 because release evidence provenance does not match the changed source tree.
Its Release gates row passed, so the build-wiring check found no missing release route.
This installation does not republish release evidence or claim release readiness.

The full canonical script has not run for this installation.
The repository records script runtimes above two minutes.
The user's AGENTS.md instructions require a stop for scripts above that threshold.
Decision 2 is whether to run `bash scripts/verify.sh` now.
That approval authorizes the full local gate and fixes required for this installation, without a push or release.

Next action owner: the user selects Decision 2. I will run the full local gate after approval.

## Full gate approval and stream correction

The user approved Decision 2 with "yes, run".
The main agent ran `bash scripts/verify.sh` against commit `e1f70dc3`.
The script exited 0 and reported that all CI test-job steps passed.

The redirected log exposed a defect in the new command's standard streams.
A small executable probe wrote a prefix before invoking the command through the same regular file descriptor.
The command overwrote that prefix because the default Zig file writer used a positional write at offset zero.
The main agent confirmed the cause in the pinned standard library.

The new build probe first failed with exit 1 and reported that stdout lost earlier output.
The fix uses streaming writers for stdout and stderr.
The same build probe then passed, preserving both prefixes and asserting usage exit 2.
The main agent also ran the nine native tests, installed check, and task coverage successfully.
The stream probe runs under `test-spine` and the aggregate suite.
It introduces no new top-level task or standalone script.

Next action owner: I will repeat the approved full gate after committing the stream correction.

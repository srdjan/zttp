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

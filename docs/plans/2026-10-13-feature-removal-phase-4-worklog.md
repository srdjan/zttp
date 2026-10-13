# Phase 4 worklog

## Objective and authority

The owner selected Phase 4 after the main agent offered a bounded implementation plan.
The owner selected execution with "D12: 1" on 2026-10-13.
That selection authorizes the bounded code change, checks, and offline evidence publication.
Canonical plan: [CHECK facts reuse](2026-10-13-1113-refactor-check-facts-reuse-plan.md).
The inspected baseline is `1bae15bb8b4c7bb36995e698d7e35d9a94b861d4` on local `main`.
The initial tree is clean.

## Accepted direction and constraints

Shared analysis leads the compiler reset. The current retained product and initial wire formats remain compatible.
The completed single-module and multi-module contract owners remain the starting point.
Phase 3 removals supersede the original audit's feature-retention list where the owner accepted a removal.
The main agent owns review, checks, and isolated local commits. The owner owns publication. No push is authorized.
Only Sol high subagents participate. No Python or paid provider run is part of this planning unit.

## Evidence and scope correction

Sol high agents researched the source, prior solutions, and user flows.
The root agent reviewed the completed graph worklog and traced CHECK loading, analysis, path projection, and revision readers.
Both default graph contract producers already use one completed owner.
The new plan does not repeat that work.

CHECK imports have an arbitrary contextual reader, exact written paths, separate traversal policies, and conservative partial results.
A reader can return different bytes on repeated calls. Caching imported files could therefore change public behavior.
The root agent rejected a unified dependency cache and a generic traversal that retained both existing policy sets.
The root agent also rejected a new source-digest authority and wire changes as unnecessary for this unit.

The selected unit reuses CHECK's existing root `ModuleFacts` in path analysis.
Both current facts producers receive the same root IR, atom table, and null manifest registry.
CHECK optimizes that root IR before both consumers use it.
The borrowed-input mechanism already exists in `PathGenerator`.
The nested path operation ends before the facts owner ends.
This removes a duplicate producer without a new owner or an imported-file cache.

The root agent corrected one research premise: `RevisionReader` does not accumulate a proof read set.
The reader selects Git revision bytes. Its contextual paths and calls remain compatibility inputs.
Historical notes about unoptimized CHECK source do not describe the current root preparation.

The recount finds 475 tracked Zig files and 327524 physical lines under `packages/`.
The plan records all eight packages and the measurement scope.
No production-only deletion count or speed improvement was measured.

## Review and verification

The planning run makes no product edits and runs no Zig tests.
Five Sol high document reviewers completed coherence, feasibility, scope, security, and architectural checks.
Three corrections address the reported findings. No proposed fix, user decision about the draft, or advisory finding remains.
The source confirms the publication paths are `docs/convergence.json` and `docs/coverage.json`.
The source also confirms the release script runs the aggregate suite, which already covers the separately listed broad checks.
The corrected plan retains focused checks and one final release run.
The corrected plan adds only the missing reader trace and maps other scenarios to existing public tests.

| Reviewer | Findings | Disposition |
|---|---:|---|
| Coherence | 0 | No correction |
| Feasibility | 1 | Correct publication filenames |
| Scope | 2 | Remove repeated checks and duplicate test additions |
| Security | 0 | No correction |
| Architectural challenge | 0 | No correction |

The main agent checked every finding against the whole plan and current source before applying it.
The planning request permits corrections to the draft's technical and verification sections within its preserved Product Contract.
No new product decision follows from these corrections.
The cross-model runner requires Python and conflicts with the active Sol-only model constraint.
No cross-model review or whole-document peer sweep ran. The five native reviews completed separately.
The Python pack resolver cannot run under the repository constraint. No CE pack configuration exists in this checkout.

External research is unnecessary for this existing input-reuse mechanism.
The confidence check finds no section that needs further research.
The main agent read the final plan and checked each correction against its source.
The final plan SHA-256 is `e321b80b6bf0d7a4418296a87076401d5803eeef8a8efeff7d1a7a793775160c`.
`git diff --check` passes. No product tests ran, and no runtime compatibility result is claimed for the planned change.

## Remaining work and next action

The bounded unit now needs public characterization, facts reuse, review, and the listed checks.
Further imported analysis consolidation, binding semantics, and typed frontend work remain later Phase 4 units.
Current release evidence describes the inspected source baseline, not this new planning commit.
The implementation plan includes offline evidence publication and final release verification when source commits require fresh provenance.
The main agent owns the next action: execute the approved unit and record authoritative evidence.

## Execution checkpoint

Execution starts at `d95fbfe5` on local `main` with a clean tree.
The native engine uses sequential units because all product writes share one file and depend on the previous unit.
A fresh Sol high worker owns the added reader-trace test. The main agent owns the code migration, verification, and local commits.
The execution directory is `/private/tmp/zttp-phase4-exec.lXg12B`.
No push, live recording, provider change, import cache, or new analysis owner is authorized by this unit.

## Characterization checkpoint

The reader-trace test observes three requests for `/virtual/lib.ts` through the public CHECK API.
Its reader supplies a different source version for each request, so a changed binding order or shared read changes the proof outcome.
The main agent reviewed the complete worker diff and retains the existing tests for other behavior.

The initial unfiltered test run fails one new assertion: 188 of 189 tests pass.
The compiled fixture has no narrow proof capsule and therefore receives the default-profile refusal.
The corrected fixture selects its proven properties and expects `fault_covered` to remain false when no failable I/O exists.
Production code remains unchanged during these corrections.

The unfiltered baseline run then passes all 190 tests, including one temporary allocation probe.
The small public CLI fixture also returns exit status 0 for JSON output and contract output.
The baseline probe reports 800 allocations, 368969 allocated bytes, and 3735 retained bytes at CHECK return.
The reader receives three calls. Result cleanup frees every counted byte.
These values describe the fixed small fixture, not peak retention or speed.
The temporary probe is absent from the characterization commit and remains in the private execution directory for the matching post-change measurement.

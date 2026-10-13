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

The bounded source change and focused checks are complete.
Offline evidence publication and the final release script remain pending at this source checkpoint.
Further imported analysis consolidation, binding semantics, and typed frontend work remain later Phase 4 units.
Current release evidence describes the inspected source baseline, not the completed source change.
The implementation plan includes offline evidence publication and final release verification when source commits require fresh provenance.
The main agent owns the next action: publish offline evidence and run the final release script.

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

## Facts reuse checkpoint

The private path operation now requires borrowed root facts and injects them before generator work.
The imported fault collector consumes the same value directly.
The CHECK caller supplies the existing analysis owner's facts.
The main agent reviewed all five added production lines and the replaced collector input.
Both imported traversals and their loading operations remain unchanged.

The unfiltered combined `test-precompile` and `test-zts` run returns exit status 0.
The matching allocation probe reports 795 allocations and 368782 allocated bytes.
That removes five allocations and 187 allocated bytes from this small fixture.
Return retention stays at 3735 bytes, the reader still receives three calls, and result cleanup frees every counted byte.
The probe source, source fixture, options, and measurement method remain fixed between both runs.
The temporary probe is absent from the production commit. These measurements establish neither speed nor peak retention.

## Compatibility and source closure checkpoint

The combined unfiltered CHECK and ZTS run passes 2567 of 2568 tests, with one existing skip.
That run includes the temporary allocation probe. The final source passes all 189 precompile tests without the probe.
Both debug builds return exit status 0.
The fixed public CLI fixture returns exit status 0 before and after the change.
Exact comparisons of its JSON output and serialized contract both return exit status 0.

The compiling wrong-facts mutation removes import records only from the path and fault consumers.
The unfiltered run then passes 171 of 189 tests and fails 18 tests, with exit status 1.
Failures include imported fault counts, unresolved dependency outcomes, routed results, and the new reader count.
The restored control passes all 189 tests, with exit status 0.
This probe distinguishes valid facts from omitted imports. It does not establish complete proof soundness.

Two independent Sol high reviewers inspect compatibility and lifecycle against the frozen source.
Neither reviewer finds a production defect. The lifecycle review confirms equivalent inputs, nested cleanup, owned projections, and unchanged early returns.
The compatibility reviewer finds one gap in the reader test.
If fault scanning runs between the summary reads, the original clean revisions permit that changed order to pass.
The corrected first two revisions include an unrelated helper with an unchecked fetch. Only the final revision remains fault-clean.
The reviewer confirms that the exact fault record rejects the changed order.

A temporary negative probe also adds that helper to the final revision.
The probe compiles and fails only the reader test: 188 of 189 tests pass, with exit status 1.
The unchanged fault assertion expects zero unseen calls and observes two.
The restored final source passes all 189 tests, with exit status 0.
This probe confirms the sentinel's public effect. It does not mutate the traversal order itself.

The main agent's line-by-line scan also corrects ownership in the test reader.
If an extra read returns an error after path insertion, the original error cleanup can free the recorded path twice.
The corrected reader frees the copy only when insertion fails. Its destructor owns every inserted path.
The final source restores the missing final newline and passes the standalone formatter check, with exit status 0.
Temporary probes and mutations remain outside the committed source.

Code review: skipped (ce-code-review unavailable).
The attempted CE review terminates without a completed receipt because its required Python helpers conflict with the repository's Python prohibition.
The [scope rule](/Users/srdjans/.codex/plugins/cache/compound-engineering-plugin/compound-engineering/3.30.5/skills/ce-code-review/references/scope.md) requires:
"Derive deterministic facts once with `scripts/review-scope.py`."
The native reviews and manual diff scan are separate checks. They are not a CE review receipt.

Three Sol high simplification reviewers then inspect the complete final code diff for reuse, quality, and efficiency.
All three return no findings. No simplification edit follows that review.
The main agent rereads the canonical plan and scans every final changed line against its requirements and definition of done.
The code remains explicit, uses the existing borrowed-input mechanism, and keeps the two traversal policies separate.

| Requirement | Source checkpoint evidence |
|---|---|
| R1: preserve public results | Existing public tests, exact CLI JSON and contract comparisons |
| R2: preserve reader calls | Three exact resolved paths, revision-sensitive flow summaries, fault sentinel, unchanged traversal source |
| R3: preserve early stops | Existing public tests and independent review of unchanged returns |
| R4: reuse root facts | Required private argument, direct generator injection, direct fault collector input |
| R5: preserve ownership | Independent lifecycle review, result serialization, testing allocator cleanup |
| R6: preserve failure outcomes | Unfiltered public failure tests, existing allocation failure coverage, full measured cleanup |
| R7: preserve retained boundaries | Only the private CHECK operation and its caller change; compilation, runtime, and wire code stay unchanged |

The canonical plan remains unchanged at SHA-256 `e321b80b6bf0d7a4418296a87076401d5803eeef8a8efeff7d1a7a793775160c`.
The source closure commit precedes evidence publication so generated evidence can bind to a stable source identity.
The final release script owns the remaining aggregate, revision-backed CHECK, standalone runtime, release build, and provenance checks.
Publication commits will change only the four generated evidence files. The final report will state their actual results.
No live model recording or push occurs in this unit.

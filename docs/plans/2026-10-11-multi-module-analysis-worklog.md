# Multi-module analysis worklog

## Objective and authority

The objective is to simplify analysis ownership for imported handlers while preserving documented features and initial wire formats.
The owner selected shared analysis before typed frontend work.
The owner selected the next phase for a bounded implementation plan with "yes, go ahead".
Product implementation requires selection of the concrete plan.
The main agent owns research, planning, review, verification, and local commits. The owner owns publication.

Canonical plan: [Multi-module contract analysis](2026-10-11-1608-refactor-multi-module-contract-analysis-plan.md).
Baseline: `596796b8a0aa46721f4ced18627a7f94e81c3f33` on local `main`.
The prior [single-module worklog](2026-10-11-shared-analysis-worklog.md) records the completed first unit.

## Accepted constraints

Preserve documented features, current pass selection, diagnostics, and initial wire formats.
Preserve declaration refusal for multi-module compilation.
Keep the independent acceptance kernel and runtime isolation unchanged.
Use native Zig errors, stable borrowed storage, and unfiltered named verification steps.
Work on local `main`, commit isolated units, and never push.
Use only Sol high subagents. Do not use Python.

## Evidence and direction

CHECK and compilation use different import semantics.
CHECK has a contextual revision reader, exact written paths, an eight-frame limit, and conservative partial results.
Compilation has strict graph errors, extension resolution, topological order, and optimized IR.
Direct strict-graph reuse would change CHECK verdicts and reads.

`ImportedFile.load` already centralizes construction for CHECK flow summaries and fault scans.
A content-aware cache would add ownership, lookup, and retention without removing an analysis responsibility.
The plan excludes that cache.

Tools and pipeline each produce multi-module contracts from compiled parsers.
Tools runs contract type checking without boolean or strict passes and ignores its diagnostic count.
Pipeline resolves typed and untyped modules differently before contract extraction.
Untyped resolution must remain without type authority until the later contract session.
Custom callbacks retain their existing public extraction branch.

The plan therefore shares default per-module contract analysis before changing CHECK graph ownership.
The new owner retains separate facts when registry inputs differ.
The plan does not claim that CHECK and compilation share one completed graph result.
Full import convergence remains follow-up work.

## Research and review

Sol high agents traced CHECK imports, graph compilation, and applicable repository lessons.
A separate specification-flow pass recommended the contract unit and rejected a CHECK cache as the first simplification.
The main agent inspected producer code, pass selection, fallback options, and cleanup order.
Local repository evidence supplies the implementation authority. No external dependency decision requires web research.

Advisor preflight returned `parent_runtime_unavailable`. No advisor consultation ran.
Five document reviewers completed their checks. One correction was applied; no unresolved review findings remain.
The planning run makes no product edits and runs no Zig tests.
The Python pack resolver and cross-model runner cannot run under the repository's no-Python constraint.
No cross-model corroboration or whole-document peer sweep is claimed.

| Sol high reviewer | Original findings | Final disposition |
|---|---|---|
| Consistency | 0 | No correction |
| Feasibility | 0 | No correction |
| Scope | 0 | No correction |
| Strategic fit | 0 | No correction |
| Architectural challenge | 1 | Applied the effective-map correction |

The architectural reviewer found that the pass matrix selected profiles by typed or untyped source.
An untyped entry can receive an explicit `opts.type_map` and therefore requires type-aware resolution.
The main agent confirmed `frontend.typeMap() orelse opts.type_map` in public extraction and the entry-only selection in the graph producer.
The correction selects profiles by effective map availability and adds an untyped entry with an explicit map to characterization.
This correction preserves the existing requirement for pass selection. It adds no product behavior or new mechanism.
The plan also calls the owner's failure scenario an analysis failure because custom callbacks remain on the compatibility branch.

Original review finding: `Pass matrix drops explicit maps for untyped entries`.
Severity: P1. Confidence: 75. Class: `gated_auto`. Source: the architectural challenge reviewer.
Evidence: the original untyped-entry row selected resolution without a checker; the code selects resolution from map availability.
Disposition: applied under permission to correct the draft's technical and verification sections while preserving the Product Contract.
Final review counts: one applied correction, zero proposed fixes, zero decisions, and zero FYI observations.
Reviewed document: `docs/plans/2026-10-11-1608-refactor-multi-module-contract-analysis-plan.md`.
Final document SHA-256: `ed64ea755b5db47577c94973b4d6b0b5793426085141d155e0ad0cbb9577bad8`.
The main agent read the complete draft and checked the corrected matrix against the source.
Confidence review found no section that required further research.

## Next action

The documentation diff passes `git diff --check`. Product files remain unchanged.
The owner will select the reviewed plan for execution or request a revision.

# Foundation cleanup worklog

## Current objective and authority

The owner selected obsolete refusal branch cleanup with "go ahead" after allocation safety completion.
The current baseline is `d52885de` on local `main`, with a clean tree.
The unit removes eight unused contract facts and the unused refusal wrapper in `retired_authority.zig`.
The eight facts are `durable_contract`, `scope_contract`, `service_contract`, `workflow_contract`, `saga_contract`, `tool_catalog`, `classification_declaration`, and `capability_ceiling`.
The main agent owns review, unfiltered verification, and the isolated local commit.
The owner owns publication. No push is part of this unit.

## Current plan and compatibility boundary

I will confirm that the eight facts have no producers and that `Feature` has no serialized representation.
I will remove each unused enum member, fact field, sentence arm, and refusal branch.
I will also remove the unused `refuse` wrapper.

I will preserve module and project refusals, including the active auth and credentials facts.
I will preserve raw JSON refusal before contract projection and empty compatibility placeholders.

I will review every changed line and run the existing public refusal tests.
I will retain all tests and commit the completed source unit locally.

The verification set is `test-zts`, `test-project-config`, `test-precompile`, `test-cli`, formatting, and the whitespace check.
The CLI suite includes build, activation, live reload, and bundle refusal tests.
The capability ceiling, analysis-owner migration, and raw state API remain separate units.

## Completed allocation unit: objective and authority

The owner selected allocation safety with "go ahead" after the review on 2026-10-13.
The baseline is `1c0b39ad` on local `main`, with a clean tree.
This unit fixes import-scan key cleanup and repeated initialization of `TypeEnvStorage`.
The main agent owns review, verification, and isolated local commits.
The owner owns publication. No push is part of this unit.

## Accepted scope and constraints

Import traversal, reader requests, successful CHECK results, and serialized contracts remain compatible.
Allocation failures must propagate or retain the existing conservative verdict.
`TypeEnvStorage` keeps its in-place API because its environment borrows the pool address.
Repeated initialization must refuse before allocation or mutation.
Initialization after cleanup and retry after a failed first initialization remain valid.
The obsolete refusal branches, capability ceiling, analysis-owner migration, and raw state API remain separate work.

## Plan

First, add allocation-failure evidence through the existing public APIs.
Then, make visited-map insertion retain ownership until insertion succeeds.
Next, reject repeated initialization of live type storage and preserve its original environment.
Finally, review every changed line and run unfiltered checks for each affected package.
Each complete source unit receives an isolated local commit.

## Verification and evidence limits

The baseline passes 189 precompile tests and 2,377 ZTS tests, with one existing skip.
A Zig 0.16 public probe reports a leak after two type-storage initializations and one cleanup.
No current production caller initializes one live storage value twice.
The import-scan findings initially come from source inspection; public failure evidence remains pending.
The verification set includes formatting, `test-precompile`, `test-zts`, and `test-proof-swallow`.
The main agent will measure small failure probes before selecting any larger sweep.
The main agent will use unfiltered named steps as verification evidence.

## Type-storage checkpoint

The type-storage guard refuses repeated initialization before allocation or mutation.
The regression retains the original environment, confirms pool health, and checks that no allocation failure occurs.
The tests also preserve initialization after cleanup and retry after an allocation failure.
The main agent reviewed every changed line and ran the unfiltered `test-zts` step.
That run passes 2,378 of 2,379 tests, with one existing skip and exit status zero.
The standalone formatter check passes. No test was removed.
The main agent owns import-scan cleanup and its tests in `packages/tools/src/precompile.zig`.
The public import-scan measurement remains in progress under `/private/tmp/zttp-check-oom-probe`.
The main agent will measure the public import-scan probe next.

## Public failure checkpoint and scope correction

The first fixture stopped at strict diagnostics and did not reach import scanning.
Its failure sweep exposed diagnostic cleanup leaks but could not establish import-scan behavior.
The corrected fixture reaches one path with zero errors.
Its 523-point allocation sweep exposes the orphaned handler key and exits with status one.
A seven-file fixture reaches one path and makes eight reader calls.
Its 505-point sweep exposes both orphaned visited keys and two diagnostic insertion failures.
The sweeps take less than one second each after compilation.
The two diagnostic failures have the same cause: failed insertion leaves an owned diagnostic without cleanup.
This unit will also free checker diagnostics when insertion into CHECK's diagnostic list fails.
That correction preserves successful outputs, diagnostic counts, and existing failure verdicts.
The correction stays in `packages/tools/src/precompile.zig` and adds no public API or lifecycle state.
The original diagnostic converter and its borrowed fallback remain outside this unit.

## Source and regression checkpoint

Both visited maps reserve capacity before copying a key, then insert without another allocation.
All five checker diagnostic paths free the owned diagnostic when its list insertion fails.
Successful reader requests, diagnostic counts, and serialized forms remain unchanged.
Two new regressions call the public CHECK API and dynamically count their baseline allocation points.
Each regression injects failure at every counted allocation point and checks complete release through its allocator.
The fixtures require one path, zero errors, complete fault analysis, and the exact reader count.
The first regression run used different backing allocators for baseline and failure probes.
That mismatch allowed different resize outcomes and caused two test failures.
The corrected run uses matching arena-backed allocation and passes all 191 precompile tests.
The independent Sol high review reports no actionable ownership finding.
The review confirms that each map insertion proves key absence and each diagnostic failure owns only its uninserted copy.
The regressions inject allocation failures, not resize failures, and do not identify all five diagnostic branches independently.
The main agent owns the two map mutations and final restored checks.

## Final verification and completion

Restoring the original handler-key insertion makes both new regressions fail: 189 of 191 precompile tests pass, with exit status one.
Restoring only the original nested-key insertion makes the nested regression fail: 190 of 191 tests pass, with exit status one.
Both mutations compile. The main agent restores the complete fix after each mutation.
The final unfiltered precompile run passes all 191 tests, with exit status zero.
The type-storage source checkpoint passes 2,378 of 2,379 ZTS tests, with one existing skip and exit status zero.
The final proof-swallow gate passes across 16 files, with no unreviewed error discards.
Both source files pass the formatter check, and the final diff passes the whitespace check.
On physical source lines, production adds 25 lines and removes seven; test code adds 112 lines and removes none.
This unit removes no tests and claims no performance improvement or complete allocation-failure coverage.
The scope closes the two import-key leaks, failed checker diagnostic insertion, and repeated type-storage initialization.
The diagnostic converter's borrowed fallback, resize failures, and separate deletion candidates remain outside this unit.
The bounded allocation-safety unit is complete. No push or release verification occurs.
The main agent owns the next plan for obsolete refusal branches.

## Obsolete refusal branch completion

The eight removed facts had no producers in the repository.
Every typed-contract consumer receives only module facts from `contractFacts`; project configuration uses the retained project facts.
The internal `Feature` type supplies named comparisons and refusal sentences, with no serialized ordinal use.
Raw retired contract fields remain under `rejectRetiredFields`, which runs before projection allocates the current contract.
The deletion preserves every retained sentence and the ordering of every retained predicate.
The source diff deletes 36 production lines and adds none. Test code remains unchanged.

The main agent reviewed the full worker diff and ran the checks independently.
The standalone retired-module test passes, as do all five project-config tests.
The unfiltered ZTS suite passes 2,378 of 2,379 tests, with one skip and exit status zero.
The unfiltered precompile suite passes all 191 tests, with exit status zero.
The unfiltered CLI suite passes 594 of 595 tests, with one skip and no failures or leaks.
The CLI root reaches the public build, activation, reload, and bundle refusal tests through its explicit command anchors.
The formatter and whitespace checks pass. No source or wire format changes outside this deletion occur.

The bounded refusal branch unit is complete. No push or release verification occurs.
The capability ceiling, analysis-owner migration, and raw state API remain separate units.
The main agent owns the next bounded review of the runtime capability ceiling.

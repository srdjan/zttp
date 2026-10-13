# Allocation safety worklog

## Objective and authority

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

## Current work and next action

The type-storage guard refuses repeated initialization before allocation or mutation.
The regression retains the original environment, confirms pool health, and checks that no allocation failure occurs.
The tests also preserve initialization after cleanup and retry after an allocation failure.
The main agent reviewed every changed line and ran the unfiltered `test-zts` step.
That run passes 2,378 of 2,379 tests, with one existing skip and exit status zero.
The standalone formatter check passes. No test was removed.
The main agent owns import-scan cleanup and its tests in `packages/tools/src/precompile.zig`.
The public import-scan measurement remains in progress under `/private/tmp/zttp-check-oom-probe`.
The main agent will measure the public import-scan probe next.

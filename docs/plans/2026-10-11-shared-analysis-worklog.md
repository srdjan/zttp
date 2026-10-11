# Shared analysis worklog

## Objective and authority

The owner approved the bounded shared-analysis plan on 2026-10-11 with "go ahead".
The implementation preserves documented features and current wire formats.
Product source starts at `38a0782f`; local `main` starts this execution at `9d51f401`.
The source drift check exits zero. The initial worktree is clean.

## Constraints

Only `packages/tools/src/precompile.zig` and `packages/zts/src/pipeline.zig` may change product code.
Public extraction fallbacks, wrappers, concrete fields, and path-specific output remain compatible.
Contract-only callers must not gain boolean, strict, or verifier checks.
Compilation retains optional verification and contract-before-flow catalog input.
Checking retains its current catalog input and stage completion.
The AOT early return and missing-handler paths retain their outputs.
Multi-module declarations remain refused. The independent acceptance kernel remains unchanged.
The main agent owns authoritative checks, review, and local commits. No push is authorized.

## Current work

Characterization passes against unchanged production code: `test-precompile` exits zero with 241 of 241 tests passing.
The main agent reviews every changed characterization line and records the fixed digests.
Sol now adds selectable pipeline passes. A second Sol agent prepares coordinator ownership without source edits.
The baseline build and both public CLI commands exit zero.
The small check takes 0.38 seconds. The small compile reports 0.00 seconds at the timer's precision.
These observations do not establish a performance change.
The generated file SHA-256 is `d819b047d71f59bb3e6d87a60e22c659be2eadbb51a5fb23a4ef9869737014ed`.
Baseline logs and the generated file copy are in `/private/tmp/zttp-shared-analysis-*-before.*`.

## Evidence correction

Unsupported syntax does not enter the AOT transpiler error return.
Allocation failure enters that return. Unsupported syntax emits fallback code or records a bailed function.
Characterization must distinguish these paths. The implementation preserves the allocation-error return's existing property projection.

The first characterization run exits one: 238 of 241 tests pass.
Two tool tests use an unsupported catalog fixture. The missing-handler test incorrectly expects compilation to refuse the source.
The actual compiler returns bytecode and a contract without verifier properties.
The worker corrects these expectations before production changes.

The normal AOT test exposes an existing ownership omission in `CompiledHandler.deinit`.
Compilation duplicates `transpiled_source`, but the destructor does not free that duplicate.
The characterization test explicitly frees the duplicate. This unit does not change that existing public cleanup convention.
The AOT allocation-error return has source-reviewed coverage only. No test claims to enter that return.

## Remaining work

Incremental passes must preserve concrete fields and clean up every allocation failure.
One stable coordinator must remove private contract fallback production.
Public output comparisons and all named unfiltered checks must pass.
The main agent will review every changed line and obtain an independent code review.

## Next action

The main agent will review and test the incremental pipeline API before coordinator edits begin.

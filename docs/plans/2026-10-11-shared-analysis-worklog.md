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

## Completed implementation

Characterization passes against unchanged production code: `test-precompile` exits zero with 241 of 241 tests passing.
The main agent reviews every changed characterization line and records the fixed digests.
Selectable pipeline passes now pass `test-zts`: 2748 of 2749 tests pass, with one existing skip.
The main agent reviews every changed pipeline line. The allocation failure sweep reports no leaks.
The catalog test distinguishes accepted catalog input from absent catalog input through the resulting flow property.
Retry tests confirm an induced allocation failure and refuse a second pass attempt.
The coordinator now owns single-module facts, resolution, and selected checks in stable storage.
Private contract operations consume completed analysis. They no longer construct missing analysis.
Contract-only callers own standalone type and flow sessions. Their boolean, strict, and verifier passes remain absent.

The main agent applies a temporary mutation that marks flow complete without its walk.
The unfiltered `test-zts` probe compiles successfully and exits one with four failed tests.
The leaking-flow assertion, accepted-catalog assertion, retry assertion, and existing error-receiver assertion reject the mutation.
The main agent restores the tested implementation. The pipeline source matches commit `7059ab68` exactly.

Coordinator review identifies two compatibility inputs that need exact preservation.
Contract-only flow retains no type-checker binding, although contract extraction owns a completed type session.
Full compile retains `opts.strict` when `TypeMap` is absent. The main agent corrects an overly broad dispatch instruction.
The main agent requests guards against retries that could replace partially initialized objects or reuse refused analysis.
The baseline build and both public CLI commands exit zero.
The small check takes 0.38 seconds. The small compile reports 0.00 seconds at the timer's precision.
These observations do not establish a performance change.
The generated file SHA-256 is `d819b047d71f59bb3e6d87a60e22c659be2eadbb51a5fb23a4ef9869737014ed`.
Baseline logs and the generated file copy are in `/private/tmp/zttp-shared-analysis-*-before.*`.

The post-change check JSON matches the complete baseline JSON through `cmp`, which exits zero.
The generated compiler file matches the complete baseline file through `cmp`, which exits zero.
The generated file retains the same SHA-256. Both public commands exit zero after a fresh `zig build`.
The post-change check takes 0.37 seconds. The compile reports 0.00 seconds at the timer's precision.
The fixture, command options, metadata, and output path remain fixed. These observations do not establish a speed change.
The final comparison after cleanup also matches both files exactly. That check takes 0.39 seconds; compile again reports 0.00 seconds.

## Checks

The main agent runs every named step without a test filter and reads each direct exit status.
All 13 required steps exit zero. The main agent also checks non-empty test counts and gate floors.
Logs use `/private/tmp/zttp-shared-analysis-final-<step>.log`.

| Step | Observed result |
|---|---|
| `test-precompile` | 241 of 241 tests pass |
| `test-zts` | 2748 of 2749 tests pass; one existing skip |
| `test-zts-cli` | 249 of 249 tests pass |
| `test-agent-protocol` | 440 of 440 tests pass |
| `test-module-graph-record` | 20 of 20 tests pass |
| `test-contract-golden` | 14 build steps succeed; 11 golden commands run |
| `test-diagnostic-corpus` | 260 of 260 tests pass; 190 cases run; floor 190; no uncovered codes |
| `test-flow-census` | 252 of 252 tests pass; 776 probes match; floor 776; no fail-open |
| `test-module-boundary` | 85 internal modules; 69 allowed reaches; no added allowlist entry |
| `test-proof-checker` | 285 of 285 tests pass |
| `test-proof-ratchet` | 52 of 52 tests pass |
| `test-cli` | 892 tests pass; one existing skip; no failures, leaks, or logged errors |
| `test-reference-tools` | Nine of nine accepted and hostile cases pass |

The first module boundary run refuses a new `zts.guard_catalog.SectionSet` reference in tools.
The coordinator now uses the existing pipeline field type. The boundary rerun exits zero without an allowlist change.
The final cleanup passes `zig fmt --check` and repeats `test-precompile`: 241 of 241 tests pass.
The contract golden rerun exits zero with all 14 build steps succeeding.
The analyzer CLI rerun exits zero with 249 of 249 tests passing.

## Simplification and independent review

Three Sol reviewers at high effort inspect reuse, quality, and efficiency through `ce-simplify-code`.
The main agent applies one reuse finding: `StageSet.initMany` replaces the duplicate initializer.
The main agent applies two quality findings: narrow extraction options remove ignored inputs, and stale helper names now identify current responsibilities.
The main agent skips three findings.
The existing allocation sweep retains its explicit allocation floor and leak-only acceptance scope.
Compile branches remain separate because the allocation-error return deliberately omits final verifier projection and collected violations.
Early analyzer cleanup would change the accepted ownership design. Peak memory needs measurement before that separate change.

The [ce-code-review skill](/Users/srdjans/.codex/plugins/cache/compound-engineering-plugin/compound-engineering/3.30.4/skills/ce-code-review/SKILL.md) cannot complete its mandatory scope stage under the repository's "No Python" instruction.
Its [scope reference](/Users/srdjans/.codex/plugins/cache/compound-engineering-plugin/compound-engineering/3.30.4/skills/ce-code-review/references/scope.md) requires `scripts/review-scope.py`.
The exact instruction is: "run it directly rather than inspecting the script or probing its `--help`, unless it actually fails with an incompatibility."
The same reference requires Python for `scripts/run-log.py`. No Python runs, and no CE review receipt is claimed.
The invocation returns a terminal failure for this conflict.
Code review: skipped (ce-code-review unavailable).
An independent Sol reviewer at high effort finds no product correctness defect.
The reviewer checks ownership, unwind order, pass completion, caller inputs, early returns, and artifact order against the baseline.
The main agent reviews every changed line and confirms the findings against the source.

Two test limits remain explicit.
The contract-only fixture preserves output properties but cannot detect an extra pass whose result is ignored.
The matching public catalog fixtures preserve their outcomes but cannot detect swapped catalog wiring.
The pipeline catalog test distinguishes catalog inputs through `injection_safe`. Source review confirms the actual coordinator wiring and skipped passes.
The contract-only test name now states the properties it observes. No claim of executed pass instrumentation remains.

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

## Completion

The bounded unit satisfies the approved done criteria within the recorded coverage limits.
The coordinator commit includes this worklog. Earlier isolated commits are `eabeacdd` for characterization and `7059ab68` for selectable passes.
The unit preserves the public compatibility surfaces and fixed artifact baselines. The independent acceptance kernel remains unchanged.
No speed, deletion-size, or runtime improvement claim follows from this unit. No push occurs.

## Next action

The owner owns the next action: review the completed unit and select the next reset phase.

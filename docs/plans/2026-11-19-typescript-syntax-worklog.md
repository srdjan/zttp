# TypeScript syntax migration worklog

The plan authority is [the syntax design](2026-11-15-typescript-syntax-design.md).
This file records execution evidence and open work. It does not change the design.

## Objective and authority

The owner selected Decision 2, option A, on 2026-11-19.
The selection authorizes the four syntax migrations, specification changes, and one new batched model recording window.
The owner runs the model recording. The main agent publishes the resulting evidence afterward.
Work stays on local `main`. No push or deployment is authorized.
Compiler metadata owns intrinsic authority. The migration preserves the interpreter and proof semantics.

## Baseline

Starting commit: `0435bfde`, with compiler source at `8b154522` (`v0.27.1`).
The working tree was clean before execution.
The refreshed plan passed six static reviews, `zig build check-spine`, and unfiltered `zig build test`.
Those checks establish the starting repository, not support for the proposed syntax.
Native execution uses Sol workers at high effort. No external implementation engine or Compound Pack is configured.

## Current work

The declaration study uses ignored files under `demos/typescript-syntax-study/`.
The baseline inventory is complete. Its source census includes packages, examples, corpus files, shell fixtures, documentation, and embedded skills.
Neither responsibility changes compiler behavior. The main agent owns verification, this log, and local commits.
The workers used twelve-turn budgets. The declaration worker received bounded extensions of twelve, eight, and eight turns for reproduced omissions.
The independent review is complete. The main agent reproduced its recursive-union failure and checked the correction.
Baseline capture and the declaration feasibility gate are complete. Intrinsic metadata and external declarations can start next.

## Baseline evidence

The authorization commit is `d78d2775`. The compiler source remains `8b154522`; the earlier plan refresh is `0435bfde`.
These revisions name different layers of the baseline, not different compiler behavior.
`zig build` exited zero, and the rebuilt CLI reports `zts 0.27.1`.

One public `zts check` probe combines all four legacy forms. It exits zero with no diagnostic and seven true properties.
The public `zttp serve --test` flow returns status 200 and the exact body `u1`: one test passes, with none unchecked.
The probe files and JSON output are under `/tmp/zttp-syntax-u1-baseline/`.

The frozen corpus has thirteen active cases. Eleven contain final handler snapshots; all eleven pass source checking with required inputs.
The SQL case passes with its recorded schema. Two cases contain no final handler and are not source-profile refusals.
The census does not replace convergence evidence or claim that every recorded task succeeded.
The raw results are under `/tmp/zttp-syntax-u1-corpus/`.

The cross-module probe confirms a current identity collision through exported function signatures.
Separate nominal declarations named `Id` interchange without a diagnostic. Different nominal names report ZTS203 at the argument.
The control using one declaration passes. Direct file imports of nominal type aliases currently report ZTS065.
The approved identity work must preserve declaration identity through both alias imports and exported signatures.
These literal fixtures are under ignored `demos/typescript-current-baseline/`.

A captured secret in a match arm reports ZTS400 and an undischarged `no_secret_leakage` claim.
A selected arm that reads the clock leaves `deterministic` false and reports ZTS500.
The pure contrast passes with `deterministic` true. Existing runtime, effect, fault, and flow suites remain baseline evidence.

## Declaration evidence

The first study missed finite record splits, optional-field partitions, and general arrays. The main agent reproduced each TypeScript failure.
Further public probes confirmed unknown subjects and bindings for missing fields. Their initial target forms also failed TypeScript.
The corrected projection covers those cases without a runtime helper or interface change.
An independent review also found TS2589 for an admitted recursive union. Pattern-driven checking removes that eager type expansion.
The main agent ran four positive files and seventeen negative files with TypeScript 7.0.2.
All positive files exit zero without diagnostics. Each negative file exits one with its expected diagnostic code.
Three additional fixtures for nested records, renamed bindings, and nested tuples also pass against the corrected declarations.
The exact commands and diagnostics are in ignored `demos/typescript-syntax-study/STUDY.md`.
The authoritative result matrix is `/tmp/zttp-syntax-u1-typescript-final.json`.
The declaration SHA-256 is `e7cdde40b9f81d7c82fd444d00fca0f2e889fd19bb63a01708d0d1329e1f5f0d`.

The projection keeps broad string and general array complements open.
ZTS retains duplicate-arm and unreachable-arm checks, including cases that the external declarations cannot decide.
No compiler, prompt, cassette, policy pin, or published evidence changed during the baseline study.

## Completion boundary

The declaration contract must pass before frontend implementation starts.
Every behavior change needs public evidence and the required unfiltered gates.
A required raw parser entry needs a superseding owner decision under D-016 before cutover.
Owner recording remains an external prerequisite. The migration cannot finish without the recording and evidence publication.

## Next action

The main agent will delegate intrinsic metadata and external declarations, then review the diff and run its owning gates.

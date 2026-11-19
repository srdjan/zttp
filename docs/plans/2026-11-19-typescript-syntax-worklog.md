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

U1 (capture current behavior and migration inputs) starts with two independent responsibilities.
The declaration study owns ignored files under `demos/typescript-syntax-study/`.
The baseline inventory reads source and records evidence outside tracked compiler files.
Neither responsibility changes compiler behavior. The main agent owns verification, this log, and local commits.
U1 has a twelve-turn budget per bounded worker. Workers stop and report open items at that limit.
U2 through U8 remain pending in their declared dependency order.

## Completion boundary

The declaration contract must pass before frontend implementation starts.
Every behavior change needs public evidence and the required unfiltered gates.
A required raw parser entry needs a superseding owner decision under D-016 before cutover.
Owner recording remains an external prerequisite. The migration cannot finish without the recording and evidence publication.

## Next action

The main agent will review the declaration study and baseline inventory before selecting the next unit.

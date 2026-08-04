---
title: Two hole fills in one turn do not compose
date: 2026-08-03
category: logic-errors
module: packages/pi/src/tools/zts_expert_fill_hole.zig
problem_type: logic_error
component: agent_tooling
symptoms:
  - A turn issues two `zts_expert_fill_hole` calls and the applied file still contains a `hole()`.
  - The second fill's coordinates resolve against the original bytes, not against the first fill's result.
  - The agent falls back to `apply_edit` with a whole file, which is the loop holes exist to replace.
root_cause: logic_error
resolution_type: code_fix
severity: medium
related_components:
  - typed_holes
  - expert_loop
tags:
  - pi
  - typed-holes
  - agent-tools
  - composition
applies_when:
  - "Adding a tool that proposes an edit rather than writing it"
  - "Designing a turn that is meant to make several small edits in sequence"
  - "Measuring a hole-mode session against a whole-file one"
---

# Two hole fills in one turn do not compose

## Context

`zts_expert_fill_hole` is the enforcement behind "one hole per turn". Its input
is one expression and one hole's coordinates, and the edit it produces replaces
the bytes of that `hole()` call and nothing else, so the rule stops being an
instruction the model can decline.

That works for one hole. A handler with two holes on two branches cannot be
finished in one turn, and the failure is quiet.

## Problem

The tool *proposes* an edit; it does not write one. Each call re-reads the file
from disk. So a second call in the same turn resolves its coordinates against
the original bytes, with the first hole still unfilled, and the first fill's
result is not in the file it is editing.

Found by recording a hole-mode corpus case. The model diagnosed it in its own
commentary, mid-session:

> The fill_hole tool is working off the on-disk file (which still has hole 1
> unfilled). I need to apply hole 1's verified content to disk first, then fill
> hole 2.

It then fell back to `apply_edit` with a whole file - the subtractive loop holes
exist to replace - and the turn ended with the program still holed. The veto
passed, because a differential check sees no new violation, and only the intent
check caught that the handler did not work.

## Why It Is Quiet

Three things have to line up for this to surface, and normally none of them do:

- The veto is differential. The seed already contained `hole()`, so a fill that
  leaves another one adds no new violation.
- `hole()` is typed `never`, so a holed program still type-checks and still
  proves its properties. That is the feature; here it also means an unfinished
  program looks finished.
- Reaching a hole answers 501, which only a behavioural check notices.

A corpus case with an intent spec catches it. A veto-only case does not.

## Consequences For Measurement

Roadmap item 3 predicts round-trips fall for hole-mode sessions. Measuring that
over multi-hole cases would fold this defect into the number and report a loop
bug as a round-trip cost.

The recorded comparison remains single-hole because it measures the historical
live sessions. Offline development now carries a two-hole seed through two full
turns and proves that both expressions compose.

## Resolution

The loop keeps the proposal-shaped tool and its approval boundary. It applies
exactly one fill per turn, then starts the next turn by reading the newly written
file and publishing a fresh compiler frame. The second fill therefore resolves
against the accepted first fill rather than against a pending snapshot.

`zts_expert_holes` now calls the production analyzer in-process, so that fresh
frame works inside an isolated handler workspace without a local `build.zig`.
The publisher and `zts_expert_fill_hole` also share the same coordinate
definition: the 1-based start of the `hole()` callee. Previously the publisher
reported the opening parenthesis and the fill tool refused that location.

The regression gate runs the real loopback server, agent loop, publisher, fill
tool, veto, approval, and apply path twice. After turn one exactly one hole
remains. After turn two no holes remain and both seeded expressions are on disk.

## Related Issues

- [empty-baseline-made-a-file-destroying-edit-prove-clean](./empty-baseline-made-a-file-destroying-edit-prove-clean.md) - the differential-veto weakness that lets the unfinished program through
- [a gate that counts nothing still reports a pass](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) - why the veto passing here is not evidence
- `docs/roadmap.md` item 3 - the typed-holes item and its measurement
- [docs/convergence.md](../../convergence.md) - where the hole-mode comparison is published

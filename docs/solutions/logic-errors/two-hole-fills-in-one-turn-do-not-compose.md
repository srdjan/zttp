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
resolution_type: documented
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

So the hole arm of the codegen corpus seeds exactly one hole per case, and says
so. That matches what the loop supports today - the persona's rule is one hole
per turn, and the eval gives each case one turn. Multi-hole cases belong in the
comparison once fills compose.

## Fix Direction

Not fixed. The options, in rough order of size:

- Have the tool apply its edit rather than propose it, so the next call reads
  the new bytes. Changes the approval model - the edit becomes a write.
- Keep it proposal-shaped but thread the proposed content through the turn, so a
  second fill resolves against the pending state rather than disk.
- Accept one fill per turn and make the loop carry a holed program to the next
  turn, which is the shape the persona already describes and the eval harness
  does not provide.

Whichever is chosen, the tool should refuse a second fill in a turn it cannot
compose, rather than silently editing the wrong bytes. A refusal naming the
reason is the behaviour the coordinate-staleness path already has.

## Related Issues

- [empty-baseline-made-a-file-destroying-edit-prove-clean](./empty-baseline-made-a-file-destroying-edit-prove-clean.md) - the differential-veto weakness that lets the unfinished program through
- [a gate that counts nothing still reports a pass](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) - why the veto passing here is not evidence
- `docs/roadmap.md` item 3 - the typed-holes item and its measurement
- [docs/convergence.md](../../convergence.md) - where the hole-mode comparison is published

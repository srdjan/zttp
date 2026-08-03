---
title: A label union that never narrows refuses one shape, not the task
date: 2026-08-03
category: logic-errors
module: packages/zts/src/flow_checker.zig (callback labels through zttp:io parallel)
problem_type: logic_error
component: compiler
symptoms:
  - Returning one element of a `parallel()` result trips ZTS400 for what a sibling callback read.
  - The same secret read through a direct `env` call, held in a local, and never returned is clean.
  - Two non-secret callbacks are clean, so the demotion is not "any parallel call taints everything".
  - Reducing the secret to a boolean inside the callback is clean, because no label crosses the boundary.
root_cause: logic_error
resolution_type: documented
severity: medium
related_components:
  - flow_checker
  - virtual_modules
tags:
  - zts
  - flow-analysis
  - taint-labels
  - precision
  - false-positive
applies_when:
  - "Fixing a fail-open by widening what a value carries"
  - "Attaching labels to an aggregate a module returns"
  - "Writing a handler that reads a secret and a non-secret through one module call"
---

# A label union that never narrows refuses one shape, not the task

## Context

The flow checker used to prove `parallel([() => env("SECRET_KEY")])` clean. A
module export answers with its *declared* return labels, and those cannot
describe what a caller's callback produced, so the secret laundered through the
module boundary. That fail-open is written up in
[empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md)
and was closed by making a callback carry what it returns out of the module.

The fix is correct in the direction it was made. This records what it costs in
the other direction, which nothing had written down.

## Problem

The array `parallel()` returns carries the union of every callback's labels, and
indexing it does not narrow back. So this is refused:

```ts
import { env } from "zttp:env";
import { parallel } from "zttp:io";

function readName(): unknown { return env("APP_NAME"); }
function readSecret(): unknown { return env("API_SECRET"); }

function handler(req: Request): Response {
  const values = parallel([readName, readSecret]);
  return Response.json({ name: values[0] });   // ZTS400: secret data flows into response body
}
```

`values[0]` is the app name. It is refused for what `values[1]` read.

## Isolation

Four shapes, run against the analyzer. The verdict column is everything other
than the ZTS500 Spec-narrowing diagnostic, which all four carry:

| Shape | Verdict |
|---|---|
| Direct `env` reads, secret held in a local, only the name returned | clean |
| `parallel([readName, readSecret])`, return `values[0]` only | **ZTS400** |
| `parallel([readName, readRegion])`, both returned | clean |

Row 1 shows the checker can already track a secret read that does not reach the
response. Row 3 shows the demotion is not "a `parallel` call taints its whole
result". What is left is the result array: the labels union across callbacks and
element access does not narrow.

## Why This Is Not A Bug Report

The polarity is the safe one. When the analysis cannot see which element carries
which label, unioning is the only answer that cannot claim a secret is clean -
the rule stated in
[normalize-unions-without-dropping-members](./normalize-unions-without-dropping-members.md).
A checker that narrowed here without evidence would be reintroducing the
fail-open the union was built to close.

The cost is that one shape cannot be written: carrying a secret and a non-secret
across the boundary in one `parallel` call and filtering afterwards.

## The Workarounds, And Which One Is Better

Reading the two values separately is clean, as row 1 shows. That is the obvious
route and it gives up the concurrency.

The better one keeps the `parallel` call and moves the filter inside the
callback, so nothing carrying the label ever crosses:

```ts
function checkApiSecret(): Response {
  const val = env("API_SECRET");
  return Response.json({ present: val !== undefined });   // the raw value stops here
}

const results = parallel([readAppName, checkApiSecret]);
// results[1] carries {present: bool}. No secret label, so no union to narrow.
```

This is not a trick played on the checker. The secret genuinely does not leave
the callback, and the union is empty because there is nothing to union. The
imprecision above is real, and it only bites code that carries a label across a
boundary it did not need to cross.

This document originally claimed no program could be written at all. That was
wrong, and what corrected it was a recording: asked for exactly this task, the
model produced the containment shape above and passed the veto on its first
applied draft, after three `zts_expert_edit_simulate` dry runs.

## Where This Is Pinned

`parallel-secret` in the codegen corpus
(`packages/pi/src/expert_codegen_record.zig`) is the case. It is pinned as a
first-draft *pass*, and what it measures is the containment: whether the model
stops a label at the boundary rather than carrying it across and filtering after.
A build where the union narrows would not change its verdict; a build where the
model stopped finding the containment shape would.

## Related Issues

- [empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md) - the fail-open this widening closed, and the reason the union exists
- [normalize-unions-without-dropping-members](./normalize-unions-without-dropping-members.md) - the polarity rule: when something cannot see, it must widen or fail, never narrow to a pass
- [docs/convergence.md](../../convergence.md) - where the pinned case is published

---
title: A label union that never narrows refuses a clean program
date: 2026-08-03
category: logic-errors
module: packages/zts/src/flow_checker.zig (callback labels through zttp:io parallel)
problem_type: logic_error
component: compiler
symptoms:
  - Returning one element of a `parallel()` result trips ZTS400 for what a sibling callback read.
  - The same secret read through a direct `env` call, held in a local, and never returned is clean.
  - Two non-secret callbacks are clean, so the demotion is not "any parallel call taints everything".
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

# A label union that never narrows refuses a clean program

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

The cost is that a legitimate program cannot be written: reading a secret and a
non-secret through one `parallel` call and returning the non-secret. The
workaround is to read them separately, which row 1 shows is clean.

## Where This Is Pinned

`parallel-secret` in the codegen corpus
(`packages/pi/src/expert_codegen_record.zig`) is pinned as a first-draft failure
on exactly this shape. Unlike the corpus's other pinned failure, the cause is
not the model: no draft can pass it. The case exists so the number moves the day
element access narrows, which is the only kind of case a convergence corpus can
use to see a fence move.

## Related Issues

- [empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md) - the fail-open this widening closed, and the reason the union exists
- [normalize-unions-without-dropping-members](./normalize-unions-without-dropping-members.md) - the polarity rule: when something cannot see, it must widen or fail, never narrow to a pass
- [docs/convergence.md](../../convergence.md) - where the pinned case is published

---
title: A proxy signal carried a proof it never claimed
date: 2026-08-02
category: logic-errors
module: ZigTS flow checker determinism inference
problem_type: logic_error
component: tooling
severity: high
symptoms:
  - "`zts check` reported `deterministic ... PROVEN` for a handler whose GET path returns rows read out of SQLite."
  - "`idempotent` rode along, because it is `deterministic and retry_safe`, so the handler claimed to be safe under at-least-once delivery."
  - "`examples/sql/sql-crud.ts` declared `deterministic` in its `Spec<...>` and the compiler discharged it."
  - "Tightening an unrelated capability row flipped a golden fixture from `deterministic: false` to `deterministic: true`, which is how the hole surfaced."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - documentation
  - testing_framework
tags:
  - zts
  - flow-checker
  - determinism
  - capabilities
  - soundness
  - fail-open
  - proof-boundary
  - compiler-analysis
---

# A proxy signal carried a proof it never claimed

## Problem

`exportReadsVaryingSource` (`packages/zts/src/flow_checker.zig:903`) decided whether a virtual-module call returns a value that can differ between runs. It answered by looking at the export's capability set: `.clock` or `.random` present means varying, anything else means stable.

That is a proxy. It is a good proxy for `Date.now`-shaped non-determinism and no proxy at all for the other kind, a read from state some other request wrote. `zttp:sql` declares `.sqlite` and `.policy_check` and no clock, so `sqlOne` and `sqlMany` answered "stable" and a handler returning a database row proved `deterministic`.

The proxy hid its own gap. `zttp:cache` declared `.clock` at module level for the expiry checks in `cacheGet`, and every export inherited it, so `cacheStats` - which sums counters already held in the store and reads no clock - was demoted correctly for a reason that had nothing to do with why it varies.

## Symptoms

Both of these reported `deterministic ... PROVEN`. The first still did after the capability rows were tightened; the second only started to.

```ts
// 1. rows out of the store - never caught, zttp:sql declares no clock
import { sqlOne } from "zttp:sql";
function handler(req: Request): Response {
    return Response.json({ row: sqlOne("getUser") });
}

// 2. live cache counters - caught only by the module-level .clock it inherited
import { cacheStats } from "zttp:cache";
function handler(req: Request): Response {
    return Response.json({ stats: cacheStats() });
}
```

`examples/sql/sql-crud.ts` shipped with `"deterministic"` in its declared `Spec<...>` on the strength of the first.

## What Didn't Work

**Treating the flipped fixture as a regression in the change that exposed it.** Taking `.clock` off `cacheStats` moved `packages/tools/tests/fixtures/contract/modules_all.ts` from `deterministic: false` to `deterministic: true`, and the obvious reading is that the capability row was wrong. It was not. The row is right and the verdict it used to produce was an accident, so reverting the row would have restored a correct answer by restoring the coincidence that produced it - and left `zttp:sql` exactly as open as before.

**Reaching for `stateful` alone.** `zttp:validate` is `stateful = true`, and its state is a schema registry the handler compiles from literals inside its own run. Demoting `validateJson` would put a false negative on the most common validation path in the language, which is the failure mode the determinism rule had already been rewritten once to avoid (`docs/roadmap.md` item 2b).

## Solution

`stateful` plus a `.read` effect is the test for "another request could have written what this returns" (`packages/zts/src/flow_checker.zig:922`):

```zig
fn exportReadsVaryingSource(
    binding: *const mb.ModuleBinding,
    func: *const mb.FunctionBinding,
) bool {
    if (binding.stateful and func.effect == .read) return true;

    const caps = func.required_capabilities orelse binding.required_capabilities;
    for (caps) |cap| {
        if (cap == .clock or cap == .random) return true;
    }
    return false;
}
```

It selects exactly six exports - `cacheGet`, `cacheStats`, `sqlOne`, `sqlMany`, `getWebSockets`, `deserializeAttachment` - and excludes `zttp:validate`, whose exports are `.none` or `.write`. The `.write`-effect workflow modules are excluded with it: a `durable.step` result is recorded and replayed, so it is identical on every run.

The label still only costs the property when it reaches the response sink (`packages/zts/src/flow_checker.zig:2002`), which is the rule item 2b established. A `sqlMany` result that reaches a log and stops keeps `deterministic`.

Verified on the full gate:

```
>> verify.sh: all CI test-job steps passed
Suites: 43 total, 43 passed, 0 failed
```

The published first-draft veto-pass rate held at 90% (10/11) ([docs/convergence.md](../../convergence.md)); no case in the eleven-case corpus returns a value it read out of a store.

## Why This Works

The capability set answers "what host authority does this export need". Determinism asks "can this value differ between runs". Those questions have the same answer for a clock and different answers for a table, and the code was using one to answer the other.

The two sources are now separate terms in the same function, which is what makes the gap visible: the capability half cannot express state, and the state half cannot express a clock read behind a helper. Neither is a refinement of the other.

This is the same shape as [empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md), one level up. There the defect was reusing a real answer ("carries nothing") for a question never asked. Here it is reusing a real signal (the capability set) as the answer to a question it does not address. In both, the fix is to give the second question its own term rather than let it ride on the first.

## Prevention

**A precision change to an input is a probe of everything downstream that reads it.** The per-export capability rows exist to make ceilings truthful (`docs/roadmap.md` item 7). Their first effect was to break a proof that had been free-riding on the imprecision. Expect that: when a signal gets narrower, every consumer that was accidentally covered by the wide version is now uncovered, and the ones that matter show up as flipped verdicts. Read a flipped verdict as a question about the consumer, not only about the change.

**When a proxy is right for one case and silent for another, name the second case in the code.** The old function's doc comment said "True when calling this export can read a clock or draw randomness" - an accurate description of what it did and no indication that it was standing in for a broader property. A reader checking whether determinism was sound would have found a function that does exactly what it says.

**Probe the position with the real compiler.** The `zttp:sql` hole is two lines and the check is immediate:

```bash
cat > /tmp/probe.ts <<'EOF'
import { sqlOne } from "zttp:sql";
function handler(req: Request): Response {
    return Response.json({ row: sqlOne("getUser") });
}
EOF
./zig-out/bin/zts check /tmp/probe.ts | grep deterministic
# PROVEN here is a fail-open, not a pass
```

**An example that declares a property is a test of that property.** `examples/sql/sql-crud.ts` asserted `deterministic` for two months and the gate agreed with it every run. Examples carrying `Spec<...>` are checked in `scripts/verify.sh`, so they fail loudly when a proof tightens - which is what they are for, and why the fix to the example is part of the fix to the compiler rather than fallout from it.

## Related Issues

- [empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md) - the same fail-open shape in the label half of the flow checker
- [normalize-unions-without-dropping-members](normalize-unions-without-dropping-members.md) - the polarity rule both instantiate: a bounded analysis may lose precision, never an obligation
- `docs/roadmap.md` item 2b - non-determinism as a flow property, the rewrite this rule extends
- `docs/roadmap.md` item 7 - per-export capability rows, the precision change that exposed this
- [docs/proofs-and-receipts.md](../../proofs-and-receipts.md) - defines `deterministic` and `idempotent`, the claims this falsified
- `scripts/check-proof-swallow.sh` - green throughout, and structurally blind here for the same reason as the sibling class: nothing was discarded, a wrong answer was returned

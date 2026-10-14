---
title: A delta against the row hid a clock read behind an exempt one
date: 2026-10-14
category: logic-errors
module: ZigTS effect inference determinism demotion
problem_type: logic_error
component: tooling
severity: high
symptoms:
  - "A handler that discarded a `logInfo` call and then returned `jwtVerify(...)` stayed `deterministic`, so `idempotent` was also derived for it."
  - "The same handler with the `logInfo` line removed was correctly demoted, so a harmless log line turned a refusal into a proof."
  - "Passing a clock-reading export as a callback (`items.map(jwtVerify)`) after a discarded log call kept the function deterministic too."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
tags:
  - zts
  - effect-inference
  - determinism
  - capabilities
  - soundness
  - fail-open
  - compiler-analysis
binds:
  - packages/zts/src/effect_inference.zig
proves: zig build test-zts
---

# A delta against the row hid a clock read behind an exempt one

## Problem

`packages/zts/src/effect_inference.zig` demoted `deterministic` when a call reached `.clock` or `.random`. It decided this from the capabilities that the call added to the caller's effect row, not from the capabilities that the callee reaches. An earlier exempt call could put `.clock` in the row first, and a later clock read then added nothing.

## Symptoms

- A discarded `logInfo(...)` reaches `.clock` (`packages/modules/src/platform/log.zig` declares `.clock, .stderr`). The sink exemption keeps the row deterministic, because the timestamp goes to stderr and stops.
- A later `jwtVerify(t, s)` reaches `.crypto, .clock` (`packages/modules/src/security/auth.zig`). The `.clock` bit was already in the row, so the delta held only `.crypto`, and the row stayed deterministic.
- Each call alone was handled correctly. Only the order "exempt clock call first, real clock call second" produced the false result.

## What Didn't Work

The defect was not visible from the call that it affected. Each site computed `before = row.capabilities`, inserted the callee's set, and tested `row.capabilities.differenceWith(before)`. That code is correct while every bit in the row also carries its consequence. The sink exemption broke that assumption: it inserts `.clock` into the row and deliberately skips the demotion. Review of one site in isolation reads as correct.

The pattern existed at two sites before this session: the direct import call and the declared callback type. An improvement pass then copied it into a third, new site (an imported export passed as a callback argument). The pass's own tests did not cover the order with a preceding log call. A Codex fact-check that judged the pass found it, and a test confirmed it: `zig build test-zts` failed on the new regression test before the fix.

## Solution

At each of the three sites, put the callee's own capabilities into a scratch row. Union that set into the caller's row, then test the scratch set:

```zig
// Before
const before = row.capabilities;
self.insertModuleCapabilities(imported.module, imported.name, row);
const added = row.capabilities.differenceWith(before);
if (added.contains(.clock) or added.contains(.random)) row.deterministic = false;

// After
var reached: EffectRow = .{};
self.insertModuleCapabilities(imported.module, imported.name, &reached);
row.capabilities.setUnion(reached.capabilities);
if (reachesClockOrRandom(reached.capabilities)) row.deterministic = false;
```

The declared-callback site builds a local `CapabilitySet` from the declared effect names in the same way. The shared test is the helper `reachesClockOrRandom` near the top of the file. The regression test is `"a clock read after a discarded log call still demotes determinism"`. It covers the direct-call case and the callback-argument case.

## Why This Works

Whether a call can change between runs is a property of the callee. The state of the caller's row before the call is irrelevant to that property. A delta against accumulated state gives the property of the new item only when every earlier bit in the state carries the same consequence. An exemption that inserts a bit without its consequence breaks that, and the delta then hides every later item that has the same bit.

The fix tests the callee's set directly, so an earlier exemption can no longer change the result for a later call. The sink exemption itself is unchanged: a discarded `logInfo` with no other clock read still keeps the handler deterministic.

## Prevention

- When a check asks "does this item have property P", compute P from the item. Do not compute P as a difference against a set that other rules also write.
- When you add an exemption that inserts a bit and skips its consequence, search for every reader that takes a delta of the same set. Each one now sees an incomplete delta.
- Test an exemption in sequence, not only alone: put the exempt call first, then a call that must still be demoted, and assert the demotion.
- This is a fail-open of the same family as [empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md). A function returned a value that claimed more than it checked. The nearest note on determinism is [a-proxy-signal-carried-a-proof-it-never-claimed](a-proxy-signal-carried-a-proof-it-never-claimed.md). That note covers a wrong capability proxy, not a wrong delta.

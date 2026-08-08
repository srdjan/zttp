---
title: A name inside an intersection weighed nothing
date: 2026-08-09
category: logic-errors
module: ZigTS TypePool intersection-target assignability, TypeEnv alias resolution
problem_type: logic_error
component: tooling
severity: high
symptoms:
  - "`type A = { a: string }; type B = { b: string }; type AB = A & B;` accepted `const v: AB = { a: \"x\" }` with `Types .......... OK`."
  - "The same type written inline as `{ a: string } & { b: string }` rejected the same value. Only the spelling differed."
  - "`zig build test` and `scripts/verify.sh` were both green throughout. No case paired a named intersection member with a value that violated it."
  - "Every handler is affected in principle: `Response & Spec<...>` is how each declared property ceiling is written."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
tags:
  - zts
  - type-system
  - assignability
  - intersection
  - unresolved-name
  - fail-open
  - soundness
  - d1-a1
---

# A name inside an intersection weighed nothing

## Problem

An intersection is a value shape plus obligations, and dropping a member drops a
constraint. `packages/zts/src/type_pool.zig` says so at `addIntersection`, which
deliberately skips dedup past sixteen members rather than lose one.

The target-side loop did not hold that line. It asked assignability about each
member in turn, and an unresolved member answered true.

```zig
// Intersection target: source must be assignable to every member
if (tgt_tag == .t_intersection) {
    for (self.getIntersectionMembers(target)) |member| {
        if (!self.assignableIn(ctx, source, member)) return false;
    }
    return true;
}
```

`resolveType` substitutes an alias name only when the whole annotation matches
it, so a name written inside a compound expression stays a `t_ref` - the
behavior `type_env.zig` pins in "TypeEnv intersection alias type AB = A & B".
An unresolved `t_ref` then falls through to the blanket-true at the bottom of
`assignableIn`, which D1 amendment A1 exists to delete. The member was
discharged rather than checked.

## Symptoms

The two spellings of one type disagreed:

```ts
type A = { a: string };
type B = { b: string };
type AB = A & B;
const v: AB = { a: "x" };          // Types .......... OK      <- wrong

type AB2 = { a: string } & { b: string };
const v2: AB2 = { a: "x" };        // Types .......... FAIL    <- correct
```

Nothing was red. The full gate passed, and the unit tests that cover
intersection construction all pass a value that satisfies every member, so none
of them could see it.

## What Didn't Work

**Reading the fix from the bug report.** The reproduction was reached while
building a regression fixture for a different defect - the 16-member truncation
recorded in
[normalize-unions-without-dropping-members](normalize-unions-without-dropping-members.md).
That report names a member count, so the natural fixture is seventeen members
with the last one violated. Written with named members it accepts everything,
because member two already fails open, and the count never matters. Written with
inline members it rejects correctly on both a fixed and a truncating build,
because the truncation only bites when instantiation changes a member. Neither
version could see either defect. The trap is recorded as its own convention in
[difference is not the claim, and a probe that does not compile is not a probe](../conventions/difference-is-not-the-claim-and-a-probe-must-compile.md).

**Waiting for A1.** The obvious fix is the amendment itself: delete the
blanket-true so an unresolved name is an error. It was applied and measured on
2026-08-04 and deferred, because `Request` and `Response` have no definition in
`TypeEnv` and the durable and queue exports return the coarse `unknown`. Both
are phase 5 work. Waiting meant leaving the fail-open open across two phases.

## Solution

Apply A1's rule at the one site, ahead of the global amendment:

```zig
for (self.getIntersectionMembers(target)) |member| {
    if (self.firstUnresolvedName(member) != null) return false;
    if (!self.assignableIn(ctx, source, member)) return false;
}
```

`firstUnresolvedName` was already in the pool: A1's reporting half landed during
phase 2 so the site that closes it could tell an unresolved name from a real
mismatch. `unionMemberSubsumes` had already used it the same way, refusing to
collapse a union member it could not resolve, which is the precedent this
follows.

The line deletes itself when A1 closes, and its comment says so.

## Why This Works

The polarity is what matters, and it is the rule underneath this whole family:
when an analysis cannot see, it must widen or fail, never narrow to a pass. An
unresolved member is a constraint the checker cannot evaluate. Answering true
discharges it; answering false keeps it, at the cost of rejecting a program the
checker cannot prove. That cost is measurable, and it was measured before the
line shipped.

The narrow cut is safe because the global amendment's failures are somewhere
else entirely. Re-measured on 2026-08-09 by deleting both blanket-true lines and
checking every example directly, global A1 fails seven files, all with `return
type does not match declared return type`: six orchestrators on the coarse
`unknown` and `examples/jsx/jsx-ssr.tsx` on the unresolved `Response`. None is
an intersection member. The site-local rule therefore costs nothing the corpus
can see: 43/43 examples, and a convergence row identical in every field
including `corpusVersion` and `policyHash`.

Count that sweep directly rather than through `scripts/test-examples.sh`. That
script is `set -e`, stops at the third orchestrator, and reports four.

## Prevention

**A fail-open you have decided not to fix yet is pinned, not left silent.** The
test that guards this holds both spellings of the same type and asserts both
reject. It was committed one step earlier asserting the wrong answer on purpose,
with a comment saying to flip it deliberately when the site closed. An unpinned
fail-open is invisible; a pinned one is a test somebody has to change on purpose.

Keep both spellings in the assertion even now that they agree. A regression that
reopens this moves the named case back to zero errors while the inline case
stays green, and only the contrast sees that.

**A deferral comment carries its measurement and its date.** The one at this site
listed three blockers, and its third - "inference does not exist yet" - had been
false since phase 2 task 5 landed inference in `c2ccf441`. Nobody re-ran the
experiment because the comment read as current. A deferral without a date is a
claim that ages into a wrong one.

## Related Issues

- [normalize-unions-without-dropping-members](normalize-unions-without-dropping-members.md) - the same obligation lost to a bounded buffer rather than to an unresolved name, and the doc whose regression fixture led here
- [subsumption-asked-assignability-the-wrong-question](subsumption-asked-assignability-the-wrong-question.md) - the union side of the same blanket-true, and the four member kinds a union must not collapse. Its unresolved-name bullet is this defect's sibling
- [difference-is-not-the-claim-and-a-probe-must-compile](../conventions/difference-is-not-the-claim-and-a-probe-must-compile.md) - why the obvious fixture for either defect reaches neither branch
- [empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md) - the same polarity error in the flow checker: something the analysis could not see, reported as clean
- `packages/zts/src/type_pool.zig` - the guarded loop, and below it the A1 deferral with the 2026-08-09 numbers
- `packages/tools/src/precompile.zig` - the two-spelling test, and the seventeen-member fixture next to it
- Commits `1c794bd8` (pinned as a fail-open), `b77442f1` (the fix and the flip), `43cd6bc0` (the re-measurement at the deferral site)

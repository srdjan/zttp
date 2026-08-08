---
title: Normalize unions without dropping members
date: 2026-07-16
last_updated: 2026-08-05
category: logic-errors
module: ZigTS TypePool union construction and TypeEnv generic instantiation
problem_type: logic_error
component: tooling
symptoms:
  - A union-typed logical operand was falsely rejected by an equivalent flat-union annotation.
  - Nested and direct associative union constructions retained different member shapes.
  - A wide union caller could silently discard members beyond its fixed scratch buffer.
  - A wide generic intersection could drop a trailing constraint and make zttp check accept an invalid value.
root_cause: logic_error
resolution_type: code_fix
severity: high
related_components:
  - testing_framework
tags:
  - zts
  - type-system
  - union-normalization
  - assignability
  - bounded-buffer
  - generic-instantiation
  - intersection
  - soundness
---

# Normalize unions without dropping members

The mechanism this document records was replaced on 2026-08-04. The rule it
states was not. Read the Problem, What Didn't Work, and Prevention sections as
current; read the Solution section as the shipped fix of 2026-07-16, and see
"What replaced the mechanism" and "Intersection instantiation closed the
remaining gap" for where the rule lives in the code today.

## Problem

Logical inference constructs `A && B` and `A || B` from the operand types
(`packages/zts/src/type_checker.zig:2192`). When `A` was already
`string | number`, joining it with `boolean` produced a nested union. Union
assignability then compared that nested node as one source member against the
members of the flat target and rejected the equivalent annotation
`string | number | boolean`.

This was a representation-level false rejection, not a formatting preference:
union is associative, so callers need one flat semantic member sequence.
Normalization also had to retain the constructor's existing identity contract:
passing one `TypeIndex`, including an existing union index, returns that exact
index unchanged (`packages/zts/src/type_pool.zig:494`).

## Symptoms

The proof-first ZigTS run failed with:

```text
Build Summary: 2/4 steps succeeded (1 failed); 1587/1592 tests passed (1 skipped, 4 failed)
```

The end-to-end case reported `expected 0, found 1` for a `string | number`
operand combined with `boolean` and assigned to the exact flat annotation. The
regression now lives at `packages/zts/src/type_checker.zig:4297`.

A caller audit exposed a second losslessness problem. Generic instantiation
copied at most 32 union members, so rebuilding a normalized wide union could
drop every trailing member. The wide regression now verifies all 35 members,
including a literal and a generic application beyond the old boundary
(`packages/zts/src/type_env.zig:1808`).

The same defect remained in the sibling intersection arm. A user-facing
17-member parameter type began with `Box<string>` and ended with
`{ required17: string }`. Instantiating the early generic rebuilt only the first
16 members, so `zttp check` accepted a call that omitted `required17`. The
rejecting fixture records that source shape at
`packages/tools/tests/fixtures/generic-intersection/reject_member_17.ts:3`.

## What Didn't Work

- Constructing a two-member union only in `inferBinaryType` was insufficient
  when either top-level member was already a union. The scoped inference patch
  passed its initial gates, but the later assignability review exposed the
  nested representation gap (session history).
- Duplicating flattening in the logical-operator checker would have fixed only
  one producer. The shared invariant belongs at `TypePool.addUnion`, where match
  analysis, schema types, service responses, and TypeEnv also benefit.
- Treating the 16-entry deduplication scratch array as a maximum would be
  unsound. For a union source, every member is an assignability obligation
  (`packages/zts/src/type_pool.zig:1458`); dropping the seventeenth member can
  turn a rejection into an acceptance.
- Copying only a fixed prefix in TypeEnv was not a safe fallback. Once any early
  generic changed, rebuilding from that prefix changed the represented type.
- Broad generic-instantiation tests and the full repository gate did not prove
  wide intersection soundness. The missing probe needed both a transformation
  before the fixed boundary and a semantically required constraint after it
  (session history).
- A representation-only regression could prove that 17 members survived while
  missing a later checker regression. The public contract also needs a valid
  contrast, a rejecting exit status, and the exact stable diagnostic.

## Solution as shipped on 2026-07-16

`addUnion` used a recursive scan followed by one of two storage paths.
`scanUnionMembers` opened every nested union, counted every leaf, and
deduplicated exact `TypeIndex` values while a 16-entry distinct-member scratch
array was sufficient. Exact index equality was deliberate at the time: it did
not introduce structural comparison or widening.

When every distinct member fit, the constructor stored the deduplicated flat
sequence. If one distinct member remained, it returned that member directly.
That collapsed `string | string` to the primitive `string` index.

When the seventeenth distinct member appeared, the scan stopped deduplicating
but continued counting every flattened leaf. The constructor reserved the
complete raw count and appended every leaf, including duplicates. Overflow
therefore degraded only canonical quality; it never removed a member. That
fallback is the part of the mechanism this document is named after, and it is
the part that later became unnecessary rather than wrong.

Both storage paths applied `fitsU16Range` to the post-normalization stored
count. A two-item top-level input can expand past the compact representation's
limit after a nested union is opened, so the pre-normalization input length is
not a valid capacity check. That guard survived the rewrite and still runs after
normalization, not before (`packages/zts/src/type_pool.zig:543`).

TypeEnv's union-instantiation branch allocates a copy sized to `live.len`,
processes every copied member, and rebuilds from the full slice only when a
member changes (`packages/zts/src/type_env.zig:1010`). Copying first also keeps
the input stable if recursive instantiation grows the pool's shared member list.
Allocation failure poisons a healthy pool with `OutOfMemory`, while preserving
any earlier failure, rather than returning a healthy-looking partial type
(`packages/zts/src/type_env.zig:1011`).

## Why This Works

The nested and direct forms expose the same ordered flat member slice and are
mutually assignable (`packages/zts/src/type_pool.zig:2520`). TypePool does not
intern equivalent multi-member nodes: each construction may still append a new
node (`packages/zts/src/type_pool.zig:546`). Its canonicalization contract is
therefore canonical member shape and semantic equivalence, not identical
`TypeIndex` values.

The single-input fast path runs before traversal, so
`addUnion(&.{existing_union})` preserves exact identity
(`packages/zts/src/type_pool.zig:494`). For multi-input unions, the polarity is
what matters: a bounded or simplifying path may lose canonical quality, and may
never lose a member, because a dropped source member is a dropped assignability
obligation and a dropped obligation turns a rejection into an acceptance.

The ZigTS gate at the time passed:

```text
Build Summary: 4/4 steps succeeded; 1594/1595 tests passed (1 skipped)
test-zts success
+- run test 1594 pass, 1 skip (1595 total) 16s MaxRSS:232M
   +- compile test Debug native cached 63ms MaxRSS:31M
      +- options cached
```

## What replaced the mechanism

Commit `b7f17215` (2026-08-04) rewrote `addUnion` to the seven-step D1 join rule
(`packages/zts/src/type_pool.zig:469`). It flattens on the heap
(`packages/zts/src/type_pool.zig:401`), drops `never` members, dedups by
canonical key through `type_key.structurallyEqual` rather than by pool index
(`packages/zts/src/type_pool.zig:509`), coalesces mutually assignable members to
the first written, drops a member strictly assignable to another, and returns
`never` for zero survivors or the sole survivor for one
(`packages/zts/src/type_pool.zig:536`).

Three claims in the section above are therefore historical, not current:

- **The 16-entry scratch array is gone.** It was the width of a buffer, never a
  language limit, and a schema enum is routinely wider. Normalizing on the heap
  removed the buffer and with it the reason for a cap
  (`packages/zts/src/type_pool.zig:483`).
- **The raw overflow fallback is gone**, because heap-backed structural dedup no
  longer needs a fixed-capacity branch. The former fallback preserved every raw
  leaf, including duplicates; the replacement's wide-dedup regression removes
  duplicate occurrences without imposing a width ceiling
  (`packages/zts/src/type_pool.zig:2559`). D1's separate `never` and strict
  subsumption steps still remove members proven redundant by their own rules
  (`packages/zts/src/type_pool.zig:471`).
- **Exact index equality is no longer the dedup rule.** Two separately built
  `{ id: string }` records were two members of one union under index equality;
  the canonical key sees them as one.

The removed cap propagated outward. `MAX_UNION_MEMBERS` in the checker is now
documented as the width of that file's stack scratch buffers and explicitly not
a limit on union width (`packages/zts/src/type_checker.zig:42`), and the absence
guard's partition moved to the heap because bailing out past sixteen left
exactly the wide enums `addUnion` was changed to represent unnarrowable
(`packages/zts/src/type_checker.zig:2081`).

The rule also survives in code at the sibling constructor. `addIntersection`
still keeps a 16-entry dedup buffer and still takes the lossless raw path past
it, because a dropped target-intersection member is a dropped constraint and an
unsound accept in `isAssignableTo` (`packages/zts/src/type_pool.zig:556` and
`packages/zts/src/type_pool.zig:564`). That is the surviving in-code instance
of the polarity this document names.

## Intersection instantiation closed the remaining gap

The earlier audit correctly identified TypeEnv's `t_intersection` arm as an
unmeasured fixed-prefix rebuild. A real `zttp check` fixture then confirmed the
path was reachable and unsound: omitting the seventeenth required member exited
successfully before the repair.

The arm now duplicates the complete live member slice into allocator-owned
storage before recursive instantiation (`packages/zts/src/type_env.zig:990`).
That copy provides two invariants:

- Every input constraint participates in the rebuild. If no member changes, the
  original `TypeIndex` is preserved; otherwise `addIntersection` receives the
  complete transformed slice (`packages/zts/src/type_env.zig:1000`).
- Recursive instantiation cannot invalidate the loop input by growing the
  TypePool's shared member storage. The temporary copy remains stable until it
  is freed (`packages/zts/src/type_env.zig:991`).

If the snapshot allocation fails, the method returns `null_type_idx` and marks
a previously healthy pool with `OutOfMemory`, without overwriting an earlier
failure (`packages/zts/src/type_env.zig:995`). It never returns a partial or
healthy-looking intersection.

The regression contract covers the failure at four boundaries:

- The unit test instantiates both generic endpoints of a 17-member intersection
  and asserts that all 15 literal constraints, including the last one, survive
  (`packages/zts/src/type_env.zig:1871`).
- A failing allocator isolates snapshot allocation and requires both
  `null_type_idx` and an observable `OutOfMemory` pool failure
  (`packages/zts/src/type_env.zig:1923`).
- The real CLI matrix accepts the complete value and rejects the value missing
  member 17 with exit 1 and an exact `ZTS203` JSON golden (`build.zig:708`). The
  aggregate `test` step depends on that matrix (`build.zig:839`).
- A mutation that restored the 16-member prefix made both the unit regression
  and the rejecting CLI case fail. That proves the gates are sensitive to the
  original truncation rather than merely exercising nearby code.

## Prevention

- Test canonical shape and semantic equivalence separately. Compare flattened
  member slices and both assignability directions; do not assume global node
  interning (`packages/zts/src/type_pool.zig:2520`).
- Preserve constructor identity contracts with a dedicated sole-union-member
  regression (`packages/zts/src/type_pool.zig:2509`).
- Exercise bounded normalization one member past any scratch limit and assert
  that every input obligation survives (`packages/zts/src/type_pool.zig:2543`
  and `packages/zts/src/type_pool.zig:2559`).
- Check capacity after recursive expansion, including a small top-level input
  whose flattened count exceeds the compact range
  (`packages/zts/src/type_pool.zig:2594`).
- Audit downstream member-copy buffers whenever a shared constructor starts
  producing wider canonical nodes. The TypeEnv regression places required data
  and generic applications across the former boundary
  (`packages/zts/src/type_env.zig:1871`).
  Removing a cap at the constructor does not remove the caps its consumers were
  written against: the checker's narrowing partition
  (`packages/zts/src/type_checker.zig:4860`, with its sixteen-member control at
  `packages/zts/src/type_checker.zig:4881`) had to be moved to the heap in a
  later pass for the same reason.
- Keep the inference-level annotation regression alongside pool-level tests so
  representation bugs remain visible as user-facing checker failures
  (`packages/zts/src/type_checker.zig:4297`).
- For wide transformations, place a member that forces rebuilding before the
  former boundary and an independently required obligation after it. Pair the
  rejecting fixture with a valid contrast so blanket rejection cannot satisfy
  the gate (`packages/tools/tests/fixtures/generic-intersection/accept_all_17.ts:3`).
- Snapshot pool-owned member slices before recursive work that may allocate into
  the same pool, and test snapshot allocation failure separately. Cardinality
  and storage lifetime are distinct correctness obligations.

## Related Issues

- [subsumption-asked-assignability-the-wrong-question](subsumption-asked-assignability-the-wrong-question.md) -
  the same constructor, the later chapter: step 5 of the rewritten join rule
  deleted the wider of two records, so a declared two-arm union silently became
  one. The same polarity, one step further in.
- [a-name-inside-an-intersection-weighed-nothing](a-name-inside-an-intersection-weighed-nothing.md) -
  the same obligation lost on the target side, to an unresolved name rather than
  to a bounded buffer. Found while building the regression fixture this document
  asked for: written the obvious way, from the member count named here, that
  fixture reaches neither defect.
- `addIntersection` documents the sibling lossless-overflow rule at
  `packages/zts/src/type_pool.zig:556`.
- `docs/plans/2026-07-30-014-d1-type-system-design.md` section 3 - the seven-step
  join rule that replaced the mechanism described here.
- No existing `docs/solutions/` entry or GitHub issue covered union
  normalization, wide generic instantiation, or this assignability failure when
  this learning was written.

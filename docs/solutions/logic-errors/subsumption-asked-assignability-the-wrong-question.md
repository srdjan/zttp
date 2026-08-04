---
title: Subsumption asked assignability the wrong question
date: 2026-08-04
category: logic-errors
module: ZigTS TypePool union normalization, step 5 subsumption
problem_type: logic_error
component: tooling
severity: high
symptoms:
  - "`type Res = { id: string } | { id: string; error: string }` normalized to the single member `{ id: string }`, so the arm carrying the extra field was deleted."
  - "`zts check --json` published one object schema in `anyOf` where the source declares two, and the error variant vanished from the emitted contract."
  - "Reading `r.error` on a value of the declared union type reported `property does not exist` on a correct program."
  - "`zig build test` stayed green. Every existing case for the step paired a literal with its base or two scalars, so nothing exercised two records in a subtype relation."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
tags:
  - zts
  - type-system
  - union-normalization
  - assignability
  - subsumption
  - width-subtyping
  - type-pool
---

# Subsumption asked assignability the wrong question

## Problem

Union normalization (`TypePool.addUnion`, `packages/zts/src/type_pool.zig`) runs
the seven steps of the D1 join rule. Step 5 drops a member strictly assignable
to another member, so that `"a" | string` collapses to `string`: the literal
describes no value the base type does not. The step answers that question by
calling `isAssignableTo(narrower, wider)` inside `unionMemberSubsumes`
(`packages/zts/src/type_pool.zig:447`).

Between two record types, assignability is width subtyping, and it runs opposite
to intuition. The record with more fields is assignable to the record with
fewer, because every use a value of the narrower type is put to is still valid
on a value that also carries an extra field. So for

```ts
type Res = { id: string } | { id: string; error: string };
```

`isAssignableTo({id, error}, {id})` is true. Step 5 read that as "the wider
record is redundant" and deleted it: the member carrying the extra field, the
one the union exists to distinguish. The declared two-arm union silently became
the single record `{ id: string }`.

## Symptoms

`zts check --json` writes its schema for a type from `getUnionMembers`
(`packages/zts/src/api_schema.zig:194`). The `error` member was already gone
before the schema writer saw the type, so the emitted contract for `Res`
described one object shape where the source declares two.

A handler reading `r.error` on a value typed as `Res` reported "property does
not exist", which is a false rejection of a program that matches its own
declared type.

`zig build test` stayed green throughout. The step's existing coverage paired
only scalars and literals, so nothing exercised two records in a subtype
relation and the gate had no case that could see a member disappear.

## What Didn't Work

Two things that look like they should have caught this, and did not.

**Auditing `isAssignableTo` for correctness.** It is correct. Width subtyping
runs the direction it runs: a record with more fields is assignable to a record
with fewer, by design, matching the TypeScript semantics the checker follows.
Reading the callee clears it, because the defect is not in what `isAssignableTo`
computes. It is in `unionMemberSubsumes` asking that function a question it does
not answer.

**The step's own tests.** Every existing case paired a literal with its base
type, or two scalars. For those, "is `a` assignable to `b`" and "does `a`
describe any value `b` does not" agree, so the tests passed and gave real
confidence about the wrong shape of member. None paired two records, so the one
case that would have caught the deletion never ran.

## Solution

`unionMemberSubsumes` gained a structural exclusion, alongside the intersection,
nominal, and unresolved-name exclusions already there
(`packages/zts/src/type_pool.zig:447` and `:458`):

```zig
fn unionMemberSubsumes(self: *const TypePool, wider: TypeIndex, narrower: TypeIndex) bool {
    if (self.getTag(narrower) == .t_intersection) return false;
    if (self.isStructural(narrower)) return false;   // <- added
    if (self.isNominal(narrower)) return false;
    if (self.firstUnresolvedName(wider) != null) return false;
    if (self.firstUnresolvedName(narrower) != null) return false;
    return self.isAssignableTo(narrower, wider);
}

fn isStructural(self: *const TypePool, idx: TypeIndex) bool {
    const tag = self.getTag(idx) orelse return false;
    return switch (tag) {
        .t_record, .t_array, .t_tuple, .t_function => true,
        else => false,
    };
}
```

A member whose tag is a record, array, tuple, or function is never dropped by
subsumption, whatever `isAssignableTo` reports for it. A literal beside its own
base type still collapses: a literal's tag is `t_literal_string` and its
siblings, never one of the four excluded ones, so that path does not reach
`isStructural` at all.

The regression pairs the fix with a positive control, so it cannot pass on a
build where subsumption was simply switched off
(`packages/zts/src/type_pool.zig:3551`):

```zig
test "a union keeps the wider of two records" {
    const narrow = parseTypeExpr(&pool, allocator, "{ id: string }");
    const wide = parseTypeExpr(&pool, allocator, "{ id: string; error: string }");
    const joined = pool.addUnion(allocator, &.{ narrow, wide });

    try std.testing.expectEqual(TypeTag.t_union, pool.getTag(joined).?);
    try std.testing.expectEqual(@as(usize, 2), pool.getUnionMembers(joined).len);

    // The control: a literal beside its own base still collapses, which is
    // what subsumption is for.
    const collapsed = pool.addUnion(allocator, &.{ pool.idx_string, parseTypeExpr(&pool, allocator, "\"a\"") });
    try std.testing.expectEqual(pool.idx_string, collapsed);
}
```

Without the control assertion the test would pass on a build where subsumption
never fires: it would prove only that the union does not shrink, not that it
shrinks for the right reason.

Gate: `zig build test`, `bash scripts/test-examples.sh` (43/43),
`bash scripts/verify.sh`. Commit `4b08f093`.

## Why This Works

`isAssignableTo(a, b)` answers "can a value of type `a` be used where `b` is
expected". Step 5 is asking something else: "does member `a` describe any value
member `b` does not". For scalars and literals the two answers coincide, and
that agreement is exactly why the step looks correct and why its own tests pass.
For anything with structure they diverge, because assignability there is width
or variance subtyping, and the assignable direction points at the member
carrying more information. That is precisely the member that must survive. It is
the one the union was written to keep.

This is the fourth entry in the exclusion list. The first three were each added
earlier, for a different visible symptom, at the same site, for the same
underlying reason, without that reason being written down anywhere shared:

- An **intersection** member is a value shape plus obligations and is assignable
  to any of its own members. `Effects<string, "env">` resolves to
  `string & { __zttp_effect__: ... }`, so `Effects<string, "env"> | string` lost
  its capability-marker branch and read as though no capability ceiling had been
  declared. The test "a marker on one union branch reports non_literal, not an
  empty set" (`packages/zts/src/type_env.zig:2427`) exists to catch that
  fail-open.
- A **nominal** member carries a brand its base does not, which is the entire
  point of a `distinct type`. Assignable-to-base is true and irrelevant.
- An **unresolved name** answers true in both directions while D1 amendment A1
  is deferred, so `string | SomeAlias` collapsed to whichever member happened to
  be compared second.
- A **record, array, tuple, or function** member is width- or variance-subtyped
  against another of its kind, and the assignable direction is the wider one.
  That is the fourth instance and the subject of this document.

Three separate symptoms had each been patched at the call site without the
shared cause being named, and the fourth arrived anyway. The doc comment above
`unionMemberSubsumes` (`packages/zts/src/type_pool.zig:418`) now states the
general rule, so a fifth structural tag added later has something to check
itself against instead of needing its own adversarial review.

This class differs from
[empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md)
and
[validate-json-strips-the-label-it-was-asked-to-check](../security-issues/validate-json-strips-the-label-it-was-asked-to-check.md).
Those two are about a function whose return value claims more than it checked:
`validateJson` relabels its output from its own contract rather than from the
value it was handed, so a secret survives the call and the label says it did
not. Here `isAssignableTo` mislabels nothing. It answers the question it was
built to answer, correctly, in both directions. The defect is entirely in which
question `unionMemberSubsumes` chose to ask it. Both classes end in the same
place, a compiler analysis reporting a stronger guarantee than the program
holds, but one is a function claiming more than it checked and the other is a
correct function answering a question that was never the right one to ask.

## Prevention

- Pair every "simplify away a member" test with a control that a real member
  survives. Without the control, the test passes on a build where the
  simplification never fires at all, and proves only that nothing shrank.
- Before adding a case to a normalization or simplification suite, check what
  relation the members are in. A suite built entirely from scalars and literals
  cannot distinguish "assignable" from "describes no additional value", because
  those two questions have the same answer for every member it tries. The gap
  appears only once a case pairs two members whose relation is width, depth, or
  variance subtyping: records, arrays, tuples, functions, and anything generic
  over them.
- When a general-purpose relation is reused inside a more specific one, audit
  every tag whose assignability is not answered by identity for the specific
  question. The audit that would have found this reads: for each type tag, does
  "assignable to" mean the same thing as "the target describes every value the
  source can express, and nothing more"? For a scalar, yes. For a record, array,
  tuple, or function, no, and the assignable direction is reversed.
- When the same site collects a third exclusion for what looks like three
  different reasons, write the shared reason at the site. Three had accumulated
  here before the fourth was found by review rather than by anyone recognising
  the pattern.

This was found by an adversarial multi-agent code review of the branch, not by a
test, then confirmed by hand against the built CLI: a handler declaring the
two-arm union and reading `r.error` reported "property does not exist", and a
control handler with an unrelated alias mismatch reported its own error, which
showed the checker was firing at all and the first result was not a silent
no-op.

## Related Issues

- [normalize-unions-without-dropping-members](normalize-unions-without-dropping-members.md) - the same constructor and the same rule, an earlier chapter: a bounded scratch buffer could silently drop trailing members past its cap. The mechanism differs and no longer exists, because commit `b7f17215` rewrote `addUnion` to dedup by canonical key, removed the member cap, and deleted the lossy raw fallback that doc describes. The rule it states survives all of that: a bounded or simplifying path may degrade canonical quality and must never drop a member.
- [a-proxy-signal-carried-a-proof-it-never-claimed](a-proxy-signal-carried-a-proof-it-never-claimed.md) - the closest match by cause rather than by file. A real, correctly computed signal is reused to answer a question it was never designed for, the two questions coincide in the common case, and they diverge in another.
- [testing-effect-instead-of-form-refused-the-canonical-predicate](testing-effect-instead-of-form-refused-the-canonical-predicate.md) - the same conflation one subsystem over, found in the same review pass: an admission check asked whether narrowing machinery produced a result instead of whether the input matched the form it advertised.
- `docs/plans/2026-07-30-014-d1-type-system-design.md` section 3 - the seven-step join rule step 5 belongs to, and the source of the wording the implementation followed.
- `packages/zts/src/api_schema.zig:194` - the consumer that reads `getUnionMembers` into the published contract, and so the path by which a dropped member reached a shipped artifact.
- Commit `4b08f093` - one of eight defects the same review pass found; the others sit in the stripper's angle-bracket scan, call-site generic-argument splitting, readonly-flag propagation, and narrowing scope.

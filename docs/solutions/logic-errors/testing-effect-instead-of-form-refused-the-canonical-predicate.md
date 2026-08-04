---
title: Testing effect instead of form refused the canonical predicate
date: 2026-08-04
category: logic-errors
module: ZigTS type checker, type-predicate admission (ZTS211)
problem_type: logic_error
component: tooling
severity: medium
symptoms:
  - "`ZTS211` fired on `function isObject(x: unknown): x is object { return typeof x === \"object\"; }` and installed no narrowing, though that body is exactly an admitted test."
  - "Every unit test written for the feature passed. All of them narrowed a union-typed parameter, the one case where the wrong question agrees with the right one."
  - "`zig build test` failed on the corpus replay with `docs/coverage.json is stale: it says corpus 04d2e920b07f, 7 of 72; this run measured 04d2e920b07f, 6 of 72`."
  - "`ZTS211` appeared in the `Codes the registry does not carry` list in `docs/coverage.md`, which is where a reader first sees a new diagnostic reaching a corpus draft."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
  - documentation
tags:
  - zts
  - type-checker
  - type-predicates
  - narrowing
  - admission-check
  - false-rejection
  - corpus-replay
---

# Testing effect instead of form refused the canonical predicate

## Problem

A TypeScript type predicate, `function isString(v: string | number): v is string`,
declares a narrowing. Before this work the stripper recorded the `v is T`
annotation and nothing read it, so every call site left the parameter at its
declared type: the predicate asserted a guarantee the checker never checked.

The rule that closes this makes the annotation a claim the checker verifies. A
predicate installs its narrowing only when its body is a single `return` of
tests drawn from the closed narrowing list over the named parameter, combined
with `&&`, `||`, `!`. Any other body keeps the declaration, raises `ZTS211`
(`invalid_type_predicate`), and installs nothing. Installing nothing is the half
that matters: a guard the compiler cannot check is a narrowing the author
asserted and nothing confirmed.

The first implementation of that admission check asked the wrong question, and
it refused the shape the corpus actually writes.

## Symptoms

The canonical predicate over `unknown` was refused:

```ts
function isObject(x: unknown): x is object {
    return typeof x === "object";
}
```

`ZTS211` fired and no narrowing was installed, though the body is exactly the
test a predicate is allowed to be made of.

Every unit test written alongside the feature passed. All of them narrowed a
union-typed parameter, which is the one case the wrong check happened to get
right.

`zig build test` then failed on the corpus replay, not on any unit test:

```text
[proof-coverage] docs/coverage.json is stale: it says corpus 04d2e920b07f, 7 of 72;
this run measured 04d2e920b07f, 6 of 72. Regenerate with `bash scripts/update-coverage.sh`
```

`ZTS211` had started appearing in the `Codes the registry does not carry` list
in `docs/coverage.md`, which is where a reader first sees that a new diagnostic
is live and firing on a corpus draft.

## What Didn't Work

**Deciding admission by asking whether the leaf would produce a narrowing.**
The first version called the checker's existing condition extractor,
`extractNarrowingGuard`, on each leaf of the returned expression and admitted
the leaf only when a guard came out:

```zig
// WRONG - tests the effect, not the form
const guard = self.extractNarrowingGuard(node);
const key = guard.key orelse return false;
return key == bindingKey(param);
```

That conflates two questions: "is this an admitted test" and "does this test
narrow this particular declared type". `typeof x === "object"` fails the second
when `x` is declared `unknown`, because `extractNarrowingGuard` partitions union
members and `unknown` is not a union. There is nothing for it to partition, so
`guard.key` comes back null and the predicate is refused for a reason that has
nothing to do with the shape of its body.

**Reading the green unit suite as evidence.** Every test written for the feature
used a union-typed parameter, the one shape where the wrong question and the
right one agree. A green suite showed the feature worked on the cases it was
tested against, not that the admission rule was correct.

## Solution

The leaf check became syntactic. It matches the form of the test against the
closed narrowing list, over the named parameter, and never asks whether a
narrowing would result (`packages/zts/src/type_checker.zig:1895`):

```zig
fn predicateLeafTestsParam(self: *const TypeChecker, node: NodeIndex, param: ir.BindingRef) bool {
    const tag = self.ir_view.getTag(node) orelse return false;
    switch (tag) {
        // `if (x)` and `if (x.ok)`
        .identifier, .member_access => return self.operandNamesParam(node, param),
        // `Array.isArray(x)`
        .call => { ... },
        // `typeof x === "..."`, `x === undefined`, `x.kind === "..."`,
        // and the `!==` form of each
        .binary_op => { ... },
        // exhaustive: every other expression form is outside the closed
        // narrowing list
        else => return false,
    }
}
```

`operandNamesParam` (`packages/zts/src/type_checker.zig:1935`) recognizes the
three ways an admitted test names its subject - the bare identifier, `typeof` of
it, and a property read off it - by walking to the underlying identifier and
comparing its binding key to the parameter's. It never asks the narrowing
machinery to partition a type.

Commit `4502f613`.

## Why This Works

Admission and narrowing answer separate questions. Admission asks "is this a
test the compiler can verify was performed", which is a question about syntax,
decidable from the node tag and its operands. Narrowing asks "given that this
test was performed, what does the type become", which is a question about the
declared type and decidable only once a type is in scope.

The first implementation ran the second question's machinery and read its answer
as the first question's answer. The two coincide over a union parameter, because
`extractNarrowingGuard` always has members to partition there. They diverge over
`unknown`, which has no members at all. A check that is correct by coincidence
on every tested case and wrong by construction elsewhere is not a check that
missed a case. It is answering a different question than its name claims.

The corpus replay caught it because every unit test supplied the coincidental
case. The replay runs twenty independently drafted handler sessions through the
real compiler and reports which of the 72 advertised rules got exercised, which
is a different source of cases than anything a test author would think to write:
a model reaching for `typeof x === "object"` over an `unknown` parameter is an
ordinary way to write `isObject`, not an adversarial one.

## Prevention

- When an admission check and the mechanism it gates share a code path, confirm
  the check answers "was this form used" and not "did that call happen to
  produce a result". The two look the same only on the input shape where they
  agree.
- Do not read a green unit suite as proof that an admission rule is right when
  every test in it shares the one property that makes the wrong question
  equivalent to the right one. Here that property was a union-typed parameter.
- Probe an admission rule with an input outside its own tests' shared
  assumption. Here that is the same test form over a non-union declared type.
- Regenerate `docs/coverage.md` and `docs/coverage.json` in the same commit as
  any change that moves what the corpus trips, and read the diff. A rule that
  starts appearing in `Codes the registry does not carry` is a new diagnostic
  reaching a draft for the first time, worth checking against the corpus by hand
  rather than trusting the number.

**The same rule also produced a true positive, and it cost a coverage row.** One
draft in `workflow-nested-dispatch-avoidance` writes
`typeof val === "object" && val !== undefined && "status" in val`. The `in`
operator is not in the closed narrowing list, so `ZTS211` refuses that predicate
correctly. Because `zts check --json` reports only the earliest failing phase,
that draft then stops reaching the strict checker, and `ZTS601` - felt on that
one draft and nowhere else in the corpus - stops being tripped. Published
coverage moved from 7 of 72 to 6 of 72 in the same commit. `ZTS601` is not in
the coverage ratchet's baseline, so the drop is recorded rather than gated, and
it describes one corpus draft rather than the rule. A correct new rule shrinking
measured coverage is the expected shape, which is why the page was regenerated
and the number explained in the commit rather than left to drift.

Seven tests sit next to the code, each refusal paired with an accept so none
passes vacuously: an admitted predicate narrows; a body that calls another
function is refused and the missing narrowing shows up as a second error, which
proves the guard was withheld and not merely reported; a bare `true` is refused;
a test over a different parameter is refused; `&&` of two admitted tests is
accepted; a test over an `unknown` parameter is accepted on its form; `in` is
refused. Gate: `zig build test`, `bash scripts/test-examples.sh`,
`bash scripts/verify.sh`.

## Related Issues

- [a-proxy-signal-carried-a-proof-it-never-claimed](a-proxy-signal-carried-a-proof-it-never-claimed.md) - the closest sibling by mechanism: a real, correctly computed signal reused as the answer to a question it was never designed to answer. The polarity is opposite, a false PROVEN rather than a false refusal.
- [a-label-union-that-never-narrows-refuses-a-clean-program](a-label-union-that-never-narrows-refuses-a-clean-program.md) - the same symptom polarity, a conservative checker refusing a clean program, but there the refusal is an accepted cost because removing it would reopen a fail-open. Here it was a defect with a free fix.
- [a-gate-that-counts-nothing-still-reports-a-pass](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) and [difference-is-not-the-claim-and-a-probe-must-compile](../conventions/difference-is-not-the-claim-and-a-probe-must-compile.md) - the umbrella convention, and the mirror image of this case. Both describe a check that reports a pass while verifying nothing. This check held a full input and asked a real question, the wrong one, so it failed loudly on a valid case instead of passing quietly on an invalid one. A red result can fail to mean what it says for the same reason a green one can.
- `docs/plans/2026-08-04-018-zts-advanced-rev4-phase2-plan.md` task 6 - where the form-not-effect rule is stated and the coverage cost recorded.
- `docs/coverage.md` - the published table `ZTS211` moved, and the record of the `ZTS601` row it cost.
- `scripts/check-proof-swallow.sh` - green throughout, and structurally blind here: nothing was discarded, and the gate is built to see a rule that is too permissive, not one that is too strict.

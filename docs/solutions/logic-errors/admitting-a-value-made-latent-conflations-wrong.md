---
title: A distinction no program can express is a distinction the code stops keeping
date: 2026-08-09
category: logic-errors
module: packages/zts (type_pool, type_env, bool_checker, type_checker, strict_checker)
problem_type: logic_error
component: compiler
symptoms:
  - The type-expression parser mapped the identifier `null` to `unknown`, and a test pinned that mapping as correct.
  - "`t_nullable`, which is `T | undefined`, accepted a `t_null` source, so `const x: string | undefined = null` was assignable."
  - "Its printer spelled `T | undefined` as `T | null`, so the first null diagnostic read \"type 'null' is not assignable to type 'string | null'\"."
  - The boolean lattice treated `x !== null` as an absence test and stripped optionality the comparison never established.
  - "`resolveNullableBinding` removed both `t_undefined` and `t_null` from a union, so `v !== undefined` over `string | null | undefined` narrowed to `string`."
root_cause: logic_error
resolution_type: documented
severity: high
related_components:
  - type_system
  - parser
  - flow_analysis
tags:
  - zts
  - type-system
  - null
  - fail-open
  - latent-defect
---

# A distinction no program can express is a distinction the code stops keeping

## Problem

Phase 3 of the `zts-advanced-1` program admitted `null` as source data. The work
was expected to be additive: the runtime already had `JSValue.null_val` and the
`push_null` opcode, and the parser refused the literal in exactly two places. The
actual cost was elsewhere. Five sites had quietly stopped distinguishing `null`
from `undefined`, and each of them was correct only for as long as no program
could produce a `null`.

## Symptoms

- `parseTypeExpr` resolved the identifier `null` to `idx_unknown`, and a test
  asserted that. Every `string | null` annotation therefore resolved to a type
  that accepts everything.
- `t_nullable` is `T | undefined`. Two sites accepted a `t_null` source into it,
  and its printer spelled it `T | null`.
- The boolean checker's `ExprType` lattice has no null member, so it mapped
  `lit_null` to `.undefined` and read `x !== null` as an undefined guard.
- `resolveNullableBinding` stripped both absent values from a union at once.

None of these produced a wrong answer before the change, because no source
program could construct a `t_null` or write a `null` literal. Each was a correct
program with a false comment.

## What Didn't Work

Reading the code for the sites. The two parser refusals are easy to find by
grep; the five conflations are not, because none of them mentions the feature
being added. They were found by admitting the value first and then probing each
direction of the new distinction:

- `const x: string | null = null;` must compile.
- `const x: string = null;` must not.
- `const x: string | undefined = null;` must not - this one was accepted, and
  it is the one the `t_nullable` sites were hiding.
- `v !== undefined` over `string | null | undefined` must leave `string | null`,
  not `string` - checked by calling a `string` parameter with the result and
  requiring the diagnostic.

The diagnostic text is a probe too: the printer bug surfaced only because a real
diagnostic read `type 'null' is not assignable to type 'string | null'` about a
type the author wrote as `string | undefined`.

## Solution

Each site was given the distinction back, and each fix has a test that pins the
direction it restored:

- `resolveIdentType` resolves `null` to `pool.idx_null`. The test that pinned
  the fail-open was rewritten, not deleted, so the pin now asserts the fix.
- `assignableStep` and `TypeEnv.isAssignableTo` refuse a `t_null` source into
  `t_nullable` and keep accepting `t_undefined`.
- The nullable printer says `T | undefined`.
- The boolean lattice answers `.unknown` for `lit_null` rather than
  `.undefined`, and its `x === null` guard extractor was narrowed to
  `lit_undefined` only, leaving null comparisons to the type checker.
- `resolveNullableBinding` became `resolveAbsentBinding(node, kind)` with an
  `AbsentKind` of `.undefined_only`, `.null_only`, or `.either`. Truthiness uses
  `.either` because truthiness excludes both; an explicit comparison uses the
  kind it names.

## Why This Works

A checker that cannot be asked a question does not have to answer it correctly.
While `null` was unreachable from source, every one of these sites was
unfalsifiable: no test could distinguish the conflating implementation from the
distinguishing one, so the conflation survived review, survived the type
digest's pinning, and survived a test suite that grew around it.

Admitting the value is what made the sites reachable. The fix is not one change
in one place - it is one change per site that had been coasting, and the way to
enumerate them is to construct the program that separates the two values and
follow where the answer comes back wrong.

## Prevention

- When admitting a value, a type, or a form the language previously refused,
  budget for the sites that stopped maintaining the distinction rather than for
  the refusal sites. The refusal is one grep; the conflations are not greppable,
  because they never mention the feature.
- Probe each direction of the new distinction separately before writing any fix,
  and record which probe found which site. Three of the five here were found by
  probes, not by reading.
- Read diagnostic text, not just exit codes. A printer that names the wrong type
  is invisible to a test that only counts errors.
- A pinned test over a fail-open is not protection; it is the fail-open with a
  signature. When the fix lands, rewrite the pin to assert the fix rather than
  deleting it, so the direction cannot silently swap back.
- Beware of a narrowing helper that removes more than the guard established.
  `resolveNullableBinding` stripping both absent values was the shape that
  claimed a removal the program never made - the same class as
  [an empty label set claiming a value was clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md)
  and [validateJson stripping the label it was asked to check](../security-issues/validate-json-strips-the-label-it-was-asked-to-check.md).

## Related Issues

- Phase 3 plan and its measured record:
  `docs/plans/2026-08-09-022-zts-advanced-rev4-phase3-plan.md`
- The spec rule the fixes restore: `docs/zts-formal-spec-northstar-advanced.md`
  section 5.3.
- A second finding from the same phase, distinct in shape and not covered here:
  the canonical profile asked only whether a `match` had a `default` arm, so the
  spelling spec 5.5 requires of a closed union - every member covered, no
  `default` - was the spelling it refused. A gate that checks for one marker
  instead of measuring the property will refuse the correct program whenever the
  property can be reached another way.

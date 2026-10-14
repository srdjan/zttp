---
title: The unseen-call scan and the fault coverage checker counted different calls
date: 2026-10-10
category: logic-errors
module: ZigTS fault coverage, unseen-call scan
problem_type: logic_error
component: tooling
symptoms:
  - "A handler that guards a webhook with `if (!verifyWebhookSignature(body, secret, sig)) return 401` lost `fault_covered`, although the failure branch exists."
  - "The same guard with `cacheSet` in the condition also lost `fault_covered`."
  - "The regression appeared when the export audit gave those four exports a failure severity. Before that, the analysis ignored them."
root_cause: logic_error
resolution_type: code_fix
severity: medium
related_components:
  - testing_framework
tags:
  - zts
  - fault-coverage
  - fail-closed
  - unseen-calls
  - failure-severity
  - two-definitions
  - soundness
---

# The unseen-call scan and the fault coverage checker counted different calls

## Problem

Two parts of the fault coverage analysis each decided which failable calls a
path holds. The fault coverage checker counted a call from a path's I/O stubs
and from its path constraints. The unseen-call scan used only the I/O stubs.
A call that only a constraint named was counted and covered by the checker, and
the scan also listed it as unseen. The unseen listing blocked `fault_covered`.

## Symptoms

- `if (!verifyWebhookSignature(body, secret, sig)) return 401; return 200;`
  reported `fault_covered` false, with the guard call as the first unseen call.
- The same shape with `cacheSet` failed in the same way. `signal` and
  `signalAt` return a boolean and have a severity too, so the same mechanism
  applies to them; no test probes them directly.
- The defect stayed hidden until the R4 export audit (F5) gave those exports a
  failure severity. An export with severity `none` is never counted, so before
  F5 the mismatch had no effect.

## What Didn't Work

- The R3 unseen-call scan was designed against the shapes that the R3 plan
  named: a stored result tested with `if (!res.ok)`, and calls inside
  callbacks such as `parallel()`. No probe placed a boolean-returning failable
  call directly in an `if` condition (session history).
- The R4 export audit listed `verifyWebhookSignature`, `cacheSet`, `signal`, and
  `signalAt` as boolean-outcome exports that can fail, and declared their
  severities. The audit checked what each export returns. It did not check in
  which call positions the path walk records a call (session history).
- The code review plan first said that the scan should also accept the call
  site of a `status_is` constraint. A plan review showed that the checker does
  not count `status_is`. A scan set larger than the counted set is a fail-open:
  a call in the scan set but not counted is neither listed as unseen nor
  counted, so nothing blocks the property.

## Solution

`Constraint.countedSite()` (`packages/zts/src/path_generator.zig`) is now
the one definition of a counted call. It returns the `StubInfo` for
`stub_truthy`, `stub_falsy`, `result_ok`, and `result_not_ok`, and null for
every other variant. The switch has no `else` arm, so a new variant must be
classified.

Both consumers use it:

```zig
// FaultCoverageChecker.analyze (packages/zts/src/fault_coverage.zig:281)
const info: StubInfo = c.countedSite() orelse continue;

// PathGenerator.scanUnseenFailableCalls (packages/zts/src/path_generator.zig:590)
for (test_case.constraints) |constraint| {
    const info = constraint.countedSite() orelse continue;
    if (info.call_site == null_node) continue;
    try seen.put(self.allocator, info.call_site, {});
}
```

Tests in `fault_coverage.zig` cover the `verifyWebhookSignature` and `cacheSet`
guards, a call as the first or a later `&&` conjunct, and a call under `||`.
The `||` form gets no constraint, so it stays unseen, and the test asserts
that. A test in `packages/tools/src/pipeline_mutation_tests.zig` proves
`fault_covered` for a guarded handler end to end.

## Why This Works

The walk records a call in `io_seq` only when the call is a `const`
initializer (`.var_decl`, `path_generator.zig`) or a bare statement
(`.expr_stmt`, `path_generator.zig`). A call that is itself the `if` condition is not in
either position. `extractBooleanCallConstraint` (`path_generator.zig`) still gives that call
a `stub_truthy` or `stub_falsy` constraint, with the call node as its
`call_site`, on each branch. The checker reads that constraint, counts the
site, and finds the failure branch. The scan, which read only `io_stubs`, did
not know about the constraint.

With one predicate, the set of calls that the scan treats as walked is exactly
the set that the checker counts. A subset made the scan fail closed on a
covered handler, which is this defect. A superset would make it fail open. A
shared predicate removes both directions at once.

## Prevention

- When two analyses must agree on a set, define the set once and call that
  definition from both. Do not copy a switch. A copied switch drifts when a
  variant is added, and here a variant (`status_is`) had already been added to
  one copy only.
- When an export gets a failure severity, probe a call to it in each syntactic
  position: `const` initializer, bare statement, `if` condition, negated
  condition, `&&` conjunct (first and later), `||` operand, call argument,
  return value, and a callback. A severity change moves the verdict for every
  position the walk does not record. Each probe asserts `unseen_calls` and
  `fault_covered`, not only that the analysis ran.
- Read the direction of a set mismatch before you choose a fix. A scan set
  smaller than the counted set fails closed. A larger one fails open. Make the
  sets equal; do not widen the scan only to clear one symptom.

## Related Issues

- [A missing import entry was conservative for one proof and clean for another](../security-issues/a-missing-import-entry-was-conservative-for-one-proof-and-clean-for-another.md):
  the same unseen-call scan, for calls in imported files.
- [A dispatched route was never walked, so its leak proved clean](../security-issues/a-dispatched-route-was-never-walked-so-its-leak-proved-clean.md):
  a walk that omitted nodes, in the flow checker.
- [A gate can be non-vacuous and still porous](../conventions/a-gate-can-be-non-vacuous-and-still-porous.md):
  why each syntactic position needs its own probe.
- Plan and result: `docs/plans/2026-10-10-code-review-fixes.md` (unit U1, R2).

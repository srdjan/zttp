---
title: A census that matched findings by position let one record stand for two
date: 2026-10-29
category: conventions
module: packages/pi (R7c census over the repair-plan tools), repo-wide (any gate that joins two lists)
problem_type: convention
component: testing_framework
severity: high
applies_when:
  - "Writing a gate that checks every item of one list has a partner in another list"
  - "Joining findings to fixes, errors to plans, or diagnostics to witnesses inside a census"
  - "Citing one gate as the check for several requirements"
  - "Reviewing a gate whose claim is 'every X has a Y'"
tags:
  - gates
  - census
  - fail-open
  - verification
  - probes
  - identity
---

# A census that matched findings by position let one record stand for two

## Context

The R7c census (`test "R7c census: tool diagnostics equal production over tests/corpus"` in `packages/pi/src/tools/common.zig`) was written to hold three claims of the R7c-3 plan (`docs/plans/2026-10-29-v0.26.0-r7c-3-plan.md`): every error that `pi_repair_plan` reports carries a repair plan (R4), a reported error never reads as a pass (R3), and every error carries help text (R8). It ran the corpus cases, asserted a floor of 182, and pinned per-tier plan counts as literals. It passed.

A code review found that it held one of the three claims, and that one only loosely:

- It linked a plan to an error when the plan's edit position equalled the error's line and column. One plan at a site therefore satisfied every error at that site. A secret leak and a credential leak from one sink share a position, so one plan could cover both while the second error had none.
- It never read the tool verdict. A tool that answered `ok: true` beside an error passed.
- It never read the help text. The plan builder fills a missing help text with a fixed fallback summary, so a null help became a plan, and the plan count hid the gap.

A testing reviewer and an independent Codex adversarial pass found it separately. The gate's own author had checked it with a delete-its-input probe (switching off help plans made it fail with 121 unplanned errors). That probe proved the gate was not vacuous. It did not prove the join was right, because the probe removed plans, and a position join fails loudly when plans disappear. It stays silent when plans exist at the right place for the wrong error.

## Guidance

When a gate claims "every X has a Y", join X to Y by an identity that X and Y both carry, not by an attribute they happen to share.

- Prefer an id the producer writes on purpose. In this envelope every plan lists the ids it closes (`"closes":["diag_003"]`), and every reported diagnostic has an id. The census now requires, for each reported error id, a plan whose `closes` contains that id (`PlanRef.closesId` in the census helpers).
- Keep a position join only where no shared id exists, and say why beside it. Flow errors are witnesses, not reported diagnostics, so they carry no `diag_` id; the census keeps the position match for them alone.
- Check each claim the gate is cited for, separately and by its own observable. The census now also fails when production reports an error and the tool result or its JSON says `ok` (R3), and when an error diagnostic has no help text (R8). Each has its own failure list and its own error tag (`CensusFalseOk`, `CensusErrorWithoutHelp`).
- Probe the join, not only the input. A delete-its-input probe shows the gate reads its input. To show the join is right, keep the partners present and break the link: shift every `closes` id by one, or force the verdict to pass, and confirm the gate fails.

## Why This Matters

A join by a shared attribute is a many-to-one match that reads as one-to-one. It passes every case where the attribute is unique, which is most cases, so the gate looks healthy on a large corpus. It fails open exactly where two findings collide, and collisions are where real bugs cluster: one sink with two labels, one line with two refusals. A census that pins counts does not help: a plan that covers two errors adds one to the plan count either way.

A gate cited for three requirements that checks one is worse than a gate cited for one, because the plan and the commit messages then record the other two as verified.

## When to Apply

- Any census or gate whose claim pairs two lists: errors and plans, diagnostics and goldens, rules and producers, findings and fixes.
- Any gate a plan names as the check for more than one requirement: list the requirements and find the line that checks each.
- Any gate whose probes all remove input: add one probe that keeps the input and corrupts the link.

## Examples

Before (simplified from the earlier census): the plan check matched by position, and nothing read `ok` or the help text.

```zig
for (check.json_diagnostics.items) |diag| {
    if (!std.mem.eql(u8, diag.severity, "error")) continue;
    const planned = for (plans) |plan| {
        if (plan.line == diag.line and plan.column == diag.column) break true;
    } else false;
    if (!planned) unplanned_count += 1;
}
```

After: each reported error is linked by the id its plan closes; position stays only for flow witnesses; the verdict and the help text have their own checks.

```zig
for (envelope.error_ids) |id| {
    const planned = for (plans) |plan| {
        if (plan.closesId(id)) break true;
    } else false;
    if (!planned) unplanned_count += 1;
}
// ... flow errors keep the position match; every error must carry help text ...
if (production_errors > 0 and (tool.ok or envelope.ok != false)) false_ok_count += 1;
```

The probes that showed the new checks work, run by hand and not committed: forcing `ok` to true in `pi_repair_plan` gave `false_ok=135`; shifting every `closes` index by one gave 132 errors "with no plan that closes it". Before the fix, neither change would have failed the census.

Related: [a-gate-can-be-non-vacuous-and-still-porous](a-gate-can-be-non-vacuous-and-still-porous.md) (probe a gate by mutating its inputs), [a-gate-that-counts-nothing-still-reports-a-pass](a-gate-that-counts-nothing-still-reports-a-pass.md) (assert a floor), [difference-is-not-the-claim-and-a-probe-must-compile](difference-is-not-the-claim-and-a-probe-must-compile.md) (assert the claim, not a difference).

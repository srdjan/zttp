---
title: A path in a diagnostic message made one refusal read as new
date: 2026-11-01
category: logic-errors
module: pi aggregate proof
problem_type: logic_error
component: tooling
severity: medium
symptoms:
  - "An edit that added no refusal was rejected with ZTS063, because the same refusal on the baseline and the candidate had different text."
  - "A rejection message named a path such as `/tmp/zttp-proof-1793588675-888724000-2/src/handler.ts`, which changes in each run."
  - "Every named gate stayed green, because no test compared the two sides of an aggregate proof through a module graph refusal."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
tags:
  - aggregate-proof
  - diagnostics
  - replay-determinism
  - module-graph
---

# A path in a diagnostic message made one refusal read as new

## Problem

`packages/pi/src/aggregate_proof.zig#prove` checks the baseline in one scratch root and the candidate in another. It rejects an edit when the candidate has a diagnostic that the baseline does not have. A ZTS063 message names each module by its path, so one refusal had different text on the two sides.

The edit was therefore rejected for a refusal that it did not add. The scratch path would also have reached the model, and a replay cannot match a path that changes in each run.

## Symptoms

- The aggregate proof rejected an edit with `ZTS063` when both sides imported the same missing file.
- The rejection text held `/tmp/zttp-proof-...`, and the `file` field beside it held `src/handler.ts`.

## What Didn't Work

- `appendCheckDiagnostics` already made `file` relative to the scratch root. A correct `file` hid the fault, because the path was also in `message`.
- The first fix returned on a link error in `markReachableChanges`. That removed an uncoded `proof_roots_failed` rejection, and the second fault then appeared. The two faults were separate, so I fixed them one at a time.
- The 19 tests rewritten for check parity and each named gate passed with the defect present. Each test runs the check once and reads one result. No test ran two scratch roots. A code review of the routes that reach the model found the defect.

## Solution

`packages/pi/src/aggregate_proof.zig#appendCheckDiagnostics` removes the scratch root from the message as well as from `file`:

```zig
const scratch_prefix = try std.fmt.allocPrint(allocator, "{s}/", .{materialized_root});
defer allocator.free(scratch_prefix);
for (diagnostics) |diagnostic| {
    // `file` is made relative as before.
    const message = try std.mem.replaceOwned(u8, allocator, diagnostic.message, scratch_prefix, "");
    defer allocator.free(message);
    try appendDiagnostic(allocator, out, file, diagnostic.code, diagnostic.severity, message);
}
```

Two tests in the same file pin the behavior through `prove`. An edit passes when both sides carry the same refusal. A new refusal reports the exact text `Module 'src/handler.ts' imports './missing.ts'`, with no scratch path. Both tests failed without the fix.

## Why This Works

`diagnosticEqual` compares `file`, `code`, `severity`, and `message`. Without the scratch root, one refusal has the same text on both sides and in each run.

Each expert tool in `packages/pi/src/tools/common.zig` passes a workspace-relative path to the check, so its messages were already stable. The aggregate proof is the one route that passes a scratch path. A probe through an expert tool therefore cannot show this defect.

## Prevention

When a diagnostic message embeds a path, test it through `prove` with the same refusal on both sides. A comparison of two runs needs each field normalized, not only the field that holds a path by design.

## Related Issues

- [Check parity plan](../../plans/2026-11-01-check-parity-plan.md), unit W5.
- D-018 in [decisions.md](../../decisions.md) records ZTS063.

---
title: A fail-open read off one branch was unreachable from the entry point
date: 2026-10-21
category: conventions
module: packages/pi (aggregate proof), docs/plans (audit lists and their severity claims), repo-wide (any audit that ranks a fail-open)
problem_type: convention
component: testing_framework
severity: medium
applies_when:
  - "An audit or review says a function accepts what it should reject, and the evidence is a read of that function alone"
  - "Ranking a finding as reachable on a production path before any input has reached it"
  - "Writing a regression test for a fail-open through an internal helper because the public entry point would not trigger it"
  - "Turning an audit list into a plan whose units cite the list's severity"
tags:
  - audit
  - fail-open
  - reachability
  - probes
  - plan-review
  - verification
binds:
  - packages/pi/src/aggregate_proof.zig
  - packages/tools/src/canonicalize.zig
---

# A fail-open read off one branch was unreachable from the entry point

## Context

The round 2 pruning audit ranked item A2 as a production fail-open in the
expert's write path. `collectCheckDiagnostics` in
`packages/pi/src/aggregate_proof.zig` runs the full check. When the full check
returns an error, it retries with `skip_contract` and keeps only the fallback
diagnostics. `prove` then rejects an edit only when `firstNewDiagnostic` finds
a candidate diagnostic that the baseline does not have. So a candidate whose
full analysis failed, with only pre-existing fallback diagnostics, reads as
accepted.

The main session read both functions and marked the claim as checked: "traced
the accept path in code; no probe has run". The plan then asked for a test
through `prove`, the public entry point.

The implementer could not build that test. `prove` calls `normalizeCandidates`
before any analysis. `normalizeCandidates` calls
`canonicalize.normalizeSourceWithOptions`, which runs the same check with
`try`. A candidate that makes the full check fail, for example SQL with no
schema (`MissingSqlSchema`), is rejected there with `normalization_failed`. The
fallback branch is never reached. Per the implementer's report, a changed
helper file or an edited schema did not reach it either.

The fix stayed in as defense in depth. It records a failed full analysis as an
`analysis_incomplete` diagnostic. The list row, the worklog, and the commit
message were corrected from "reachable" to "not reachable today".

## Guidance

A read of one function shows that a branch is wrong. It does not show that an
input can reach the branch. Before a finding is called reachable, do these
steps:

1. Name the public entry point that the finding is about. Here that is
   `aggregate_proof.prove`, not `collectCheckDiagnostics`.
2. List every step that runs between that entry point and the wrong branch.
   Look for normalization, admission, schema, or parse steps that call the
   same check earlier.
3. Build one concrete input and run it through the entry point. Assert the
   wrong outcome, including the exact code or verdict string.
4. If no such input exists, record the finding as latent, and give the guard
   that blocks it. Keep the fix only if it costs little and closes the branch
   for a future caller.

A test that calls the internal helper directly is still useful. It pins the
branch's behavior. But it is evidence for "the branch is wrong", not for
"production accepts this".

## Why This Matters

A wrong severity propagates. The audit list fed a plan, the plan fed a
dispatch, and the dispatch prompt told the implementer to "observe the failing
test before the fix". An implementer who trusts the plan may weaken the test
until it passes, and so manufacture the evidence the plan predicted. Here the
implementer reported the contradiction instead.

The same audit had other claims that a read alone could not settle. A
validation round against the source found ten of the list's rows false before
implementation started. The examples include an "unused" resolver that
production calls, a suite floor already equal to the real count, and a depth
bound called unreachable that a parsed program reaches.

## When to Apply

- An audit, review, or plan ranks a fail-open as high severity.
- A subagent reports a fail-open from reading code, with no input observed.
- A regression test cannot be written through the public entry point. That is
  itself evidence that the path may be unreachable.

The inverse failure is in
[a decision over a path that never ran passed every gate](a-decision-over-a-path-that-never-ran-passed-every-gate.md):
there, a path that never ran looked safe because every gate stayed green. Both
notes ask for the same evidence: an input observed on the path.

## Examples

Before, the list row said: "the fallback accepts a candidate whose full analysis
failed. This is the empty-set-means-clean class on the production write path."

After the probe through `prove`, the row says: "unreachable through `prove`
today, because `normalizeCandidates` runs the same check first and rejects with
`normalization_failed`. The fix is defense in depth."

The two retained tests in `aggregate_proof.zig` call `collectCheckDiagnostics`
and `firstNewDiagnostic` directly, and each failed with the fix removed. They pin
the branch, not the entry point: "a failed full analysis is recorded beside the
fallback diagnostics" and "only a new failed full analysis rejects an edit".

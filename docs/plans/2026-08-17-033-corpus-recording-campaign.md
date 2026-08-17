# Corpus recording campaign: get a promoted DeepSeek corpus and publish it

Status: proposed, not started. Written 2026-08-17.

Budget: at most 8 full recording runs. Each run costs roughly 24 minutes of
wall clock and a DeepSeek spend, and sends handler source to DeepSeek.

## Why a campaign rather than another run

Five full runs have been paid for and none promoted. The reasons changed each
time, and each was a real defect found only by paying:

| run | outcome | cause |
|---|---|---|
| 1 | 17/19 staged | 2x `InvalidChangeSetArgs`, evidence destroyed |
| 2 | crashed at case 5 | `SO_RCVTIMEO` sized from the turn budget, EAGAIN panic |
| 3 | 19/19 staged, 6 failures | measured model failures blocked activation |
| 4 | 19/19 staged, 2 failures | same |
| 5 | 19/19 staged, 3 failures | same |

Runs 3, 4 and 5 were complete corpora that the gate discarded. That gate is
changed (`0df610bb`): activation now requires completeness, not success. Under
the current rule **runs 4 and 5 would both have promoted**.

So the campaign is not a search for a lucky draw. It is: take one complete run,
publish it, and spend the remaining budget only on defects that stop a run from
completing.

## Success criteria, in order

1. One run reports `staged=19` with zero recording failures and activates the
   corpus. Verifiable: all 19 directories under
   `packages/pi/src/simulator/testdata/empirical/deepseek/codegen/` show
   `"schema_version":2` in `git status`.
2. `zig build test-expert-app` passes with no stale case.
3. `bash scripts/update-convergence.sh` and `bash scripts/update-coverage.sh`
   regenerate cleanly, and the new convergence row names `deepseek-v4-flash`,
   policy `0f7250ff`, and a first-draft rate read from the cassettes.
4. `zig build test` is green apart from pre-existing unrelated failures.

Criterion 1 is the gate. Criteria 2-4 are mechanical once it holds.

## Stopping rules

Stop and report, without spending the rest of the budget, when any holds:

- **Promoted.** Go to the publish steps. This is the expected exit after run 1.
- **Two consecutive runs fail for the same new reason.** That is a defect, not
  variance. Diagnose it before spending again.
- **Budget exhausted at 8 runs.** Report the failure distribution and stop.

Explicitly NOT a stopping rule: a run that promotes while measuring model
failures. That is the intended outcome, and docs/convergence.md forbids
re-recording until a number flatters.

## Per-run procedure

Precondition each time: clean tree, no uncommitted edits to persona, prompts,
rule text or tool schemas. Any such edit invalidates the comparison and must be
committed and noted first.

```
ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_PROVIDER=deepseek \
ZTTP_CODEGEN_TURN_TIMEOUT_MS=600000 \
zig build test-expert-app -Dtest-filter="record codegen baseline corpus"
```

Read from the run log, in order:

1. `staged=N` from the `RUN raw first-draft` line. `N < 19` means a recording
   failure - the corpus is incomplete and did not activate.
2. `failure case=... kind=...` lines. Kinds `provider`, `timeout`, `decode`,
   `empty_response`, `internal` are recording failures. Kinds `validation` and
   `intent` are measured outcomes and do not block.
3. `activated complete 19-case corpus` confirms promotion.

## Failure playbook

Each entry names what to check first, so a run is not repeated blind.

**`InvalidChangeSetArgs`** (`kind=provider`). Measured at 0.28% per attempt, 3
occurrences in the first 6 runs, none since. The shape and the sanitized body
are now kept: read
`.zig-cache/codegen-record-diagnostics/<run>/<case>.rejected-call-<n>.json`
before re-running. This is the first occurrence that will be explainable;
diagnose it rather than spending the next run immediately. Plan 032 step 3.

**`RequestTimedOut` / `DeepSeekGenerationStalled`** (`kind=timeout`). A stall is
now retried up to three times inside the run; a `RequestTimedOut` means the turn
budget is genuinely spent. If a case times out repeatedly, check whether it is
one case or the ceiling.

**Panic / `AGAIN`.** The socket timeout no longer derives from the turn budget
(`a00821f2`). A recurrence means a second path with the same shape - do not
re-run, find it.

**A case that never staged for a new reason.** Stop. This is the
two-consecutive-runs rule in advance.

## What this campaign deliberately does not do

- **No re-rolling.** A run that completes is published whatever rate it
  measures. Runs are repeated only when a run fails to complete.
- **No prompt, persona or rule edits mid-campaign.** They move the corpus or
  policy identity and make rows non-comparable. Anything learned goes into a
  follow-up, not into the middle of the campaign.
- **No local or Claude corpus work.** Off-headline and out of scope.

## Expected cost

Best case, and the expected one: 1 run, ~24 minutes. Each additional run is
justified only by a completion failure with a named cause. The 8-run ceiling is
a backstop, not a plan to use.

## After promotion

```
zig build test-expert-app          # no stale case
bash scripts/update-convergence.sh
bash scripts/update-coverage.sh
```

Commit the cassettes and both regenerated pages together from a clean tree. The
new row will differ from the published 47% row on both corpus hash and policy
hash - it starts a new comparison series, which is what those columns exist to
record.

## Open question for the reviewer

The corpus now promotes while recording cases the model failed. Runs 4 and 5
measured 2 and 3 such failures, on partly different cases. That means the
published first-draft rate carries sampling noise that the old gate hid by
refusing to publish at all. Is a single run the right basis for a published
row, or should the campaign record two complete runs and publish the one with
the median rate? The second costs one extra run and makes the number more
defensible; the first is what the protocol has always done.

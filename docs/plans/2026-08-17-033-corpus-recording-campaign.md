# Corpus recording campaign: get a promoted DeepSeek corpus and publish it

Status: revised after review, not started. Written 2026-08-17.

The first draft claimed one run would promote and publish. A review found that
false: relaxing the activation gate left two other gates enforcing a perfect
run, both since fixed in `9793296f`. The corrections below come from that
review and are marked where they change what the campaign does.

Budget: at most 8 full recording runs. Each run costs roughly 24 minutes of
wall clock and a DeepSeek spend, and sends handler source to DeepSeek.

## Why a campaign rather than another run

Five full runs have been paid for and none promoted. The reasons changed each
time, and each was a real defect found only by paying:

| run | outcome | cause |
|---|---|---|
| 1 | 17/19 staged | 2x `InvalidChangeSetArgs`, evidence destroyed |
| 2 | crashed at case 5 | `SO_RCVTIMEO` sized from the turn budget, EAGAIN panic |
| 3 | 17/19 staged, 6 failures | 2 recording failures plus measured model failures |
| 4 | 19/19 staged, 2 failures | same |
| 5 | 19/19 staged, 3 failures | same |

Runs 3, 4 and 5 were complete corpora that the gate discarded. Three gates had
to change before that mattered:

- `0df610bb` - activation requires completeness, not success.
- `9793296f` - the publication floors no longer gate on the value of the number
  being published, and the durable-intent test asserts a per-case pin instead
  of demanding a pass from every workflow case.

Only the first had landed when this plan was first written, and the other two
would each have blocked the campaign on its own: the floors demanded a raw
first-draft count and a median that no recorded run has ever produced, and the
durable test would have turned the build red on a corpus that honestly recorded
`workflow-nested-dispatch-avoidance` failing - the case docs/convergence.md
pins as an accepted failure.

Run 3's staged count was 17, not 19; the table above is corrected.

So the campaign is not a search for a lucky draw. It is: take one complete run,
publish it, and spend the remaining budget only on defects that stop a run from
completing.

## Success criteria, in order

1. One run reports `staged=19` with zero recording failures and prints
   `activated complete 19-case corpus`. Verifiable:
   `grep -l '"schema_version":2' packages/pi/src/simulator/testdata/empirical/deepseek/codegen/*/case.json | wc -l`
   equals 19.
2. `zig build test-expert-app` passes with no stale case.
3. Both publish scripts regenerate cleanly, and the new convergence row names
   `deepseek-v4-flash`, the policy hash the replay itself prints (not a
   constant pinned here, which goes stale on any compiler commit), and a
   first-draft rate read from the cassettes.
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

Preconditions each time, all three checked before spending:

1. Clean tree, no uncommitted edits to persona, prompts, rule text or tool
   schemas. Any such edit invalidates the comparison and must be committed and
   noted first.
2. **`zig build` at the campaign commit.** The recorder locates
   `zig-out/bin/zttp` per case AFTER the paid model turn. A stale or missing
   binary makes every runtime-intent case throw `IntentCheckUnavailable` - a
   fully paid, fully quarantined run.
3. **`DEEPSEEK_API_KEY` present.** Without it the gated test returns
   `SkipZigTest` and the build passes while recording nothing. Confirm the
   `corpus start: provider=deepseek ...` line appears before trusting any
   outcome.

```
ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_PROVIDER=deepseek \
ZTTP_CODEGEN_TURN_TIMEOUT_MS=600000 \
zig build test-expert-app -Dtest-filter="record codegen baseline corpus"
```

Read from the run log, in order:

1. `staged=N` from the `RUN raw first-draft` line. `N < 19` means a recording
   failure - the corpus is incomplete and did not activate.
2. `failure case=... kind=...` lines. The kind alone does not say whether a
   failure blocks - `classifyRecordingFailure` maps `InvalidRecordedFlow` and
   `NonDeterministicFlowVersion` to `validation`, and `IntentCheckUnavailable`
   to `intent`, and all three are blocking. Read the error name instead:
   `RecordedEditNotApplied` and `RecordedIntentCheckFailed` are the only
   non-blocking entries. The `quarantined failure kind=...` line, printed
   per case as it happens, marks the blocking ones.
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

**`RuntimeIntentPinMismatch`** after promotion. The recording measured a
durable case differently from its pin. This is not a re-roll trigger: move the
pin in the same commit as the cassettes and say what changed. Expect this on
the first run, because the pins were set before any corpus existed under the
new rule.

**`CoverageRatchetMismatch`.** `deepseek_coverage_baseline` pins ZTS305,
ZTS400, ZTS500, ZTS501, ZTS502, and its own comment says the list was carried
over rather than measured from the current prompts. If a fresh recording stops
tripping one, the replay fails in both bare and publish modes. Re-baseline it
against the new corpus and say so; do not re-record to satisfy it.

**`MixedCorpusIdentity`.** Aborts mid-run with no summary. Stop and diagnose.

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

Order matters. A bare `zig build test-expert-app` runs
`assertCoveragePageCurrent`, and the committed `docs/coverage.json` still
carries the old corpus version, so it fails until the coverage page is
regenerated:

```
bash scripts/update-coverage.sh     # regenerates docs/coverage.{md,json}
bash scripts/update-convergence.sh  # appends the row
zig build test-expert-app           # now expected clean
```

Commit the cassettes and both regenerated pages together from a clean tree. The
new row will differ from the published 47% row on both corpus hash and policy
hash - it starts a new comparison series, which is what those columns exist to
record.

## Resolved: publish from one run

The open question was whether to record two runs and publish the median. No.

The published rate is not a free-standing number - `update-convergence.sh`
re-derives it by replaying the committed cassettes, so only the activated
corpus can ever be the published row. "Record two, publish the median" is
therefore "record two, activate the one whose rate we prefer", which is
selection on outcome: re-rolling in letter, not merely in spirit. A median of
two does not exist in any case; with n = 2 the choice is min or max, and any
rate-dependent rule is the flattering draw.

Sampling noise is real and the honest instrument for it already exists: the
results table is a time series, and successive rows document the variance.

## Already paid for, not yet mined

`.zig-cache/codegen-record-staging/` holds several complete schema-2 staged
corpora from earlier runs. None can be activated: there is no offline
activation path, and the guidance commits since then (`508606db`, `9a5ee533`)
change diagnostics the replay recomputes, so their replays are stale. They
remain useful as measurement - the failure distribution in this plan is drawn
from them - and should be read before any new run is justified.

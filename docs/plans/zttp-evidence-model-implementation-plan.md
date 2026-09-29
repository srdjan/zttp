# zttp evidence model — implementation plan

Status: proposed implementation plan; no repository changes or live model runs performed.
Prepared: 2026-09-29.
Evidence baseline: srdjan/zttp at September 25 commit `50b0a1da3d3a59c94429d88427bf240b61dfe99a`.

The goal is to make release claims reproducible and correctly scoped using the existing recorder, replay harness, deterministic suites, qualification runner, and four published coverage/convergence files.

The unit of evidence is **a recorded sample evaluated by a specific build**. Replaying it creates another evaluation, not another model sample.

## 1. Contract and scope

Keep three claims separate:

| Claim | Denominator | Minimal result |
|---|---|---|
| Compiler diagnostic witnesses | Advertised rules, with applicable subset and exclusions shown separately | Witnessed codes; passing/declared seeds; explicit exceptions |
| Compiler soundness regression checks | Named positive/adversarial probes and executable mutation probes | Pass/fail by claim; mutation outcome census |
| Model diagnostic exposure | Unique case-recordings within a declared configuration and budget | Per-rule case hits; cohort distinct counts; descriptive historical union |
| Agent convergence | All scheduled cases in a complete live cohort | First-proposal quality; final completion; intent and joint success; effort and terminal failures |

Compiler witness coverage and soundness regression checks share the deterministic evidence section, but retain their own denominators. There is no combined coverage or soundness percentage.

Retain:

- `docs/coverage.json` and `docs/coverage.md`.
- `docs/convergence.json` and `docs/convergence.md`.
- Existing marker authorities, flow artifacts, defect seeds, security probes, and qualification records.
- Existing product qualification thresholds as a separate decision policy.
- Git history as the publication history.

Do not add a benchmark service, database, alternative corpus, or new model runner. Do not change compiler behavior to improve the published score. Do not spend model tokens during the reporting repairs.

## 2. September 25 baseline to preserve

| Observation | Current evidence |
|---|---|
| Diagnostic witnesses | 60 of 61 advertised codes; 63 seeds |
| Exclusion | ZTS508, non-default mode |
| Latest transcript exposure | ZTS305, ZTS400, ZTS500, ZTS509 |
| Historical exposure union | Six codes across mixed compiler configurations |
| Raw / assisted first proposal | 14/19 / 14/19 |
| Applied verified edit | 19/19 |
| Runtime intent | 18/18, with 18/19 corpus cases intent-bearing |
| Median consumed round-trips | Four |
| Independent live cohort count | Not established by the current publication counter |
| Independent final workspace check | Not separately reported |

The coverage history contains four publications for this corpus through September 25. The current union counter reports three because it omits the pending publication from its observation statistics once history exists. The September 24–25 repository diff contains no cassette changes.

These are historical observations, not targets that new measurements must reproduce. Preserve old rows and attach corrected interpretations; never fabricate missing historical fields.

## 3. Delivery sequence

| Change | Outcome | Dependency |
|---|---|---|
| PR 1 — Correct reporting semantics | Accurate labels and historical accounting | None |
| PR 2 — Identify samples and publish case evidence | Replays cannot inflate sample size | PR 1 |
| PR 3 — Measure actual completion and valid failure | Final-state evidence; unbiased publication | PR 2 |
| PR 4 — Publish one consistent evaluation | Reproducible JSON/Markdown views from one execution | PRs 2–3 |
| PR 5 — Establish release comparison protocol | Repeatability and improvement claims with explicit limits | PR 4 |

### PR 1 — Correct reporting semantics

Primary files:

- `tooling/coverage_union.zig`
- `scripts/update-coverage.sh`
- `scripts/update-convergence.sh`
- `docs/convergence.md`
- Generated coverage and convergence files

Work:

1. Fix pending-publication accounting: pending data must affect union, count, min/max, and distinct-set statistics consistently.
2. Until recording identities exist, call the count **publications**, never independent runs. Accept an explicit pending publication identity so an already-present publication is not counted twice.
3. Label the broad union **historical diagnostic exposure across configurations**. Display which configurations contributed; do not imply a fixed compiler.
4. Rename the displayed `finalGreens` meaning to **verified edit applied** without rewriting historical values.
5. Rename the displayed median to **median consumed round-trips**. Define first draft as the first submitted proposal, after any prior inspection or simulation.
6. Correct the corpus-hash explanation: `corpusVersion` is model-visible input identity; intent, probes, and thresholds have separate identities.
7. Remove the combined seed/model coverage arithmetic and the unsupported “stable to about one case” claim.
8. Replace stale prose about missing intent scenarios with values derived from the current manifest.
9. Change “exactly one introduced code” to “the declared code was observed introduced” unless the seed gate is deliberately strengthened to assert the full set.

Repository constraint: AGENTS.md requires touched Python tooling to migrate to Zig. Move the touched extraction/rendering logic into one small Zig reporting command, with the existing shell entry points retained. The command is a parser/renderer, not a new benchmark runner. Port behavior before adding new semantics; avoid migrating unrelated scripts.

Acceptance:

- A pending set larger than all historical sets updates the maximum.
- Republishing an already-identified publication does not add another publication.
- A zero-hit set is a valid observation when collector execution is independently established.
- Current Markdown no longer labels publication count as live sample count.
- Historical numerators and denominators remain unchanged.

### PR 2 — Identify samples and publish per-case evidence

Primary files:

- `packages/pi/src/expert_evidence_identity.zig`
- `packages/pi/src/expert_codegen_record.zig`
- Existing flow-artifact metadata under `packages/pi/src/simulator/`
- `packages/pi/src/expert_codegen_eval.zig`
- `tooling/coverage_union.zig`
- Reporting parser/renderer from PR 1

Add only the missing identity:

| Field | Rule |
|---|---|
| `recordingId` | Assigned at live case start; retained across replays, including failed attempts |
| `sampleSetHash` | Ordered case IDs, recording IDs, and artifact digests |
| `evaluationId` | Stable identity for sample set, evaluator source/configuration, metric schema, and observed results |
| `origin` | live_cohort, replay, or mixed_refresh |
| Capture/evaluation times | Separate fields; neither determines sample independence |
| Metric schema version | Explicit version for changed measurement semantics |

Keep the existing invocation `runId` as an execution identifier if useful. Do not use it as sample identity. Exclude invocation timestamps/PIDs from stable evaluation identity. If identical evaluation inputs yield different results, preserve both results and flag nondeterminism rather than overwriting one.

Emit the per-case records already largely present in `observations`: case ID, mode, artifact and recording identities, DraftQuality, applied, intent result, round-trips, and terminal outcome. Collect diagnostic sets per case before folding them into the cohort union; count a rule at most once per case-recording.

Persist capture configuration in the existing artifact metadata. Reuse current persona, catalog, request, compiler, intent, and source identities. Include limits and effective sampling settings; mark server defaults or unavailable model revisions explicitly.

Aggregation:

- Same recording evaluated twice contributes one live sample.
- Same recording evaluated on two compilers creates paired evaluations.
- A partial refresh remains a mixed sample set; unchanged cases are not fresh observations.
- Distinct recording IDs with identical response bytes remain distinct live executions.
- Old evidence without recording identity is legacy/unknown, never assumed independent.
- Group comparable exposure by input, model-facing configuration, compiler evaluation configuration, budget, and metric schema. Keep mixed historical unions descriptive.

Acceptance:

- Replay twice: unchanged sample count and sample-set identity.
- Change evaluator build only: same sample set, different evaluation.
- Re-record one case: exactly one new case-recording.
- Change only intent suite: unchanged model input identity; changed intent evaluation identity.
- Aggregates reproduce exactly from the published per-case records.
- Copying a record with a new publication date cannot increase sample size.

### PR 3 — Measure completion and publish valid failures

Primary files:

- `packages/pi/src/expert_codegen_types.zig`
- `packages/pi/src/expert_codegen_eval.zig`
- `packages/pi/src/expert_codegen_record.zig`
- `packages/pi/src/expert_qualification.zig`
- `packages/pi/src/loop.zig`, only if terminal evidence is not already exposed

Work:

1. Preserve DraftQuality and its derived raw/assisted metrics.
2. Add a final workspace verdict using the existing authoritative compiler path. Check the complete expected artifact set, unresolved holes, and required obligations; a differential “no new violation” result alone is insufficient.
3. Report `applied`, `finalClean`, and `intent` separately. Define joint success as final clean AND runtime intent passed, over declared intent-bearing cases.
4. Distinguish model/output failure, budget exhaustion, provider failure, and harness error. Retain explicit failed case records even when no replayable model artifact was produced.
5. Publish intent coverage as expected/actually checked alongside passes. Do not shrink the task-success denominator when a case fails before producing an artifact.
6. Separate measurement validity from qualification. Remove success-value floors from publication after replacing them with explicit harness checks and known-good controls.
7. Keep the median over consumed round-trips. Show successful/unsuccessful counts and configured limits beside it. Do not claim time-to-success from this value.
8. Preserve regression ratchets in CI. For deliberate comparisons, provide report-only outcome transitions; a changed recorded outcome must not disappear merely because the normal ratchet would fail.
9. If replay feedback diverges, report stale/unevaluable. Do not synthesize a model continuation or treat replay as a new live convergence result.

Acceptance:

- A valid zero-success cohort is retained and publishable.
- A broken intent runner is classified as a harness error, not 0% model competence.
- An applied edit with unresolved holes cannot count as final completion.
- Compiler-clean but intent-wrong output fails joint success.
- Budget exhaustion remains in the scheduled task denominator.
- CI ratchets still reject unexplained regressions.

### PR 4 — Publish a consistent evaluation

Primary files:

- Existing update scripts and the reporting command
- Existing marker validator and `scripts/test-evidence-marker.sh`
- `scripts/check-convergence-emitter.sh`
- `build.zig`
- The four published evidence files

Work:

1. Execute the existing replay once for a publication batch. Feed its two authoritative markers to their respective views.
2. Run deterministic suites separately, binding their outputs to the same source revision and explicit suite identities.
3. Check source identity before execution and immediately before publication. Refuse mixed-source batches.
4. Validate complete subprocess exit status before consuming markers.
5. Derive all summary counts from case records; validate set uniqueness, registry membership, exclusions, and denominators.
6. Stage all four outputs and replace them only after the full batch validates. Preserve the previous outputs on failure; document recoverability if multi-file replacement is interrupted.
7. Update the emitter guard to recognize the shared Zig parser while retaining one producer per evidence class and rejecting synthetic model evidence.
8. Publish deterministic witness results separately from positive/adversarial probes and acceptance-kernel mutations. A suite hash is identity, not evidence that the suite executed.
9. Keep old historical rows under their original metric schema. New final-state metrics are not retroactively “measured.”

Acceptance:

- Both views identify the same model evaluation and sample set.
- A test failure after marker emission publishes nothing.
- A source change during the batch publishes nothing.
- Repeating an identical evaluation is idempotent.
- Removing all collector input fails instrumentation checks, while a healthy zero-hit cohort remains valid.
- Generated Markdown agrees with JSON; no hand-maintained headline counts remain.

### PR 5 — Establish release comparisons

Reuse `scripts/qualify-expert.sh` and `expert_qualification.zig`; retain the existing report-only run records and failed qualification reports.

Before any paid run, freeze the case set, evaluator and model-facing configuration, limits, number of cohorts, primary metric, practical improvement threshold, and comparison method. Costed live execution is a separate release activity.

Two comparison modes:

| Mode | Hold fixed | Allowed conclusion |
|---|---|---|
| Compiler replay | Recorded samples and evaluation contracts | Exact per-case acceptance/diagnostic changes |
| Live agent comparison | Corpus, intent suite, budgets, and declared controls | Change in bounded task success and effort under the compared configurations |

For compiler replay, publish pass→fail, fail→pass, unchanged, and unevaluable cases, with the reason for each changed result. More accepted programs is not automatically a compiler improvement.

For live comparison:

- Start with the existing three complete cohorts as a descriptive repeatability report.
- Publish every scheduled result; never retain only qualified or successful cohorts.
- Give each task equal weight. With complete balanced cohorts, the aggregate is the mean cohort success rate.
- Show cohort counts and range. Three cohorts do not establish a ±one-case stability claim.
- If an inferential claim is needed, plan enough independent paired batches for the desired precision and interleave old/new configurations in randomized order.
- Compute a paired difference interval preserving whole cohorts as the resampling unit. A paired cohort bootstrap requires enough independent batches; otherwise mark the result exploratory.
- Claim improvement only when the prespecified interval clears the prespecified practical threshold. If it does not, report inconclusive.
- Limit all conclusions to the fixed corpus and sampled service configuration. Unknown hosted-model revisions limit causal attribution.
- Do not let CI fail merely because a fresh live draw exposes fewer diagnostic rules. Deterministic replay regressions and stochastic exposure fluctuations are different events.

Acceptance:

- Qualification status cannot filter the published evidence set.
- Provider failures and incomplete captures remain visible.
- Bootstrap/comparison inputs contain distinct scheduled live cohorts, not replay publications.
- Corpus or intent changes produce a new comparison series unless a common subset is explicitly defined and reported separately.
- No release claim is derived from historical-union growth.

## 4. Verification and rollout

At implementation start, resolve the current branch and reread applicable AGENTS.md files; compare it with the pinned September baseline before editing. Confirm actual build target names from `build.zig` rather than assuming new targets exist.

Run focused Zig tests for changed identity, aggregation, and evaluator behavior, then the existing relevant gates: `zig build`, `zig build test-expert-app`, and `zig build test-standin`. Run the affected security/mutation gates when their execution or reporting is changed. Exercise the publication pipeline from a clean checkout. Do not make new live recordings part of routine validation.

Ship PR 1 as the immediate correction. Complete PRs 2–4 before publishing a new release comparison. PR 5 produces the release protocol first; statistical claims wait for the planned live evidence.

Done means:

- The September numbers remain traceable without being reinterpreted as stronger evidence.
- Publication, recording, and evaluation counts cannot be confused.
- Capability witnesses, soundness regression probes, diagnostic exposure, and task completion have explicit separate denominators.
- Legitimate bad outcomes can be published.
- A reader can reproduce each aggregate from case records and identify what changed between releases.
- The implementation remains an extension of the existing zttp machinery.

## 5. Source references

All reviewed against the September 25 baseline:

- [Coverage report](https://github.com/srdjan/zttp/blob/50b0a1da/docs/coverage.md) and [JSON](https://github.com/srdjan/zttp/blob/50b0a1da/docs/coverage.json).
- [Convergence report](https://github.com/srdjan/zttp/blob/50b0a1da/docs/convergence.md) and [JSON](https://github.com/srdjan/zttp/blob/50b0a1da/docs/convergence.json).
- [Coverage union](https://github.com/srdjan/zttp/blob/50b0a1da/tooling/coverage_union.zig).
- [Recorder and replay publisher](https://github.com/srdjan/zttp/blob/50b0a1da/packages/pi/src/expert_codegen_record.zig).
- [Evaluator](https://github.com/srdjan/zttp/blob/50b0a1da/packages/pi/src/expert_codegen_eval.zig) and [evidence identities](https://github.com/srdjan/zttp/blob/50b0a1da/packages/pi/src/expert_evidence_identity.zig).
- [Seed gate](https://github.com/srdjan/zttp/blob/50b0a1da/packages/pi/src/standin_range_tests.zig), [security probes](https://github.com/srdjan/zttp/blob/50b0a1da/packages/pi/src/expert_security_probes.zig), and [checker mutations](https://github.com/srdjan/zttp/blob/50b0a1da/packages/tools/src/proof_checker_mutants.zig).
- [Qualification](https://github.com/srdjan/zttp/blob/50b0a1da/packages/pi/src/expert_qualification.zig) and [runner](https://github.com/srdjan/zttp/blob/50b0a1da/scripts/qualify-expert.sh).
- [Coverage publisher](https://github.com/srdjan/zttp/blob/50b0a1da/scripts/update-coverage.sh), [convergence publisher](https://github.com/srdjan/zttp/blob/50b0a1da/scripts/update-convergence.sh), and [repository instructions](https://github.com/srdjan/zttp/blob/50b0a1da/AGENTS.md).

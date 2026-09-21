# Bounded provable-set reach

This measurement asks whether the default agent can solve a frozen set of tasks within fixed limits.
Every task has a reference program that must pass the same compiler and runtime checks as the generated program.
The report keeps every selected task, including model, transport, budget, and harness failures.

There is no published fresh M3 result yet.
An offline smoke result verifies the harness and does not measure the model.
The [existing convergence corpus](convergence.md) remains a separate measurement.

## Task suite

The suite in `packages/pi/src/expert_reach_corpus.zig` has four functional families.
Each has a whole-handler task and a typed-hole task, for eight task instances.
The two input modes have the same required behavior but provide different amounts of starting code.
Their results must be read separately.

| Family | Required behavior |
|---|---|
| Request-header classification | Classify the exact `x-format` header; reject the wrong method |
| Optional query combination | Combine an optional prefix with a required name; reject a missing name |
| Bounded text preview | Uppercase the first eight characters of the body; reject an empty body or wrong method |
| Seeded label helper | Use the fixed local helper to trim and lowercase a label; reject an empty body or wrong method |

Each task carries exact request and response assertions.
Reference admission runs before provider initialization, including for a one-task pilot.
It requires zero total compiler errors, the task's named proof properties, and passing runtime assertions.
The final candidate goes through the same checks.
An applied edit or a relative veto pass alone does not qualify.

## Holdout boundary

These tasks are separate from the existing 19-case recorded corpus, product examples, persona, skills, and stand-in playbooks.
Reference source stays outside the model's isolated workspace.
Acceptance checks are added only after the agent turn has ended.
This is a repository holdout; it makes no claim about what the provider saw during training.
The result is a count over this suite, not an estimate of reach over every provable program.

Do not use outcomes from this suite to tune the agent and then call another run a new holdout result.
Keep the used suite for regression checks and create a new version for a fresh holdout claim.
Changes to prompts, seeds, required properties, reference programs, or acceptance checks change the corresponding identities.

## Limits and evidence

The first live measurement uses the current product default, `deepseek-v4-flash`, through the existing DeepSeek adapter.
Each task has a 600,000-millisecond authoring ceiling, 18 model round trips, 16 tool calls, and five verification attempts.
These are explicit limits taken from the existing loop and DeepSeek recorder, not measured costs.
The report records the provider's actual request token policy.
Actual token use, elapsed time, and billed cost must come from run evidence; no dollar estimate is published here.

A full reach fraction requires a complete fresh-model report for all eight tasks.
The numerator counts only candidates that pass the absolute proof and runtime checks within budget.
The denominator contains all eight tasks, including failures.
A pilot, deterministic run, replay, or interrupted report cannot publish that fraction.
Failure is a valid measured outcome; missing evidence is not success.

## Running the harness

The repository-only command is `zig build provable-reach`.
Each invocation needs a new output directory.
Its parent directory must already exist.
The command refuses to overwrite an existing run.
The output directory must be outside the source tree, so live source identity can remain clean.

Start with one deterministic task:

```sh
zig build provable-reach -- --smoke --limit 1 --output /tmp/zttp-reach-smoke-one
```

After that complete path works in under a minute, change only the selected count and use a new output directory:

```sh
zig build provable-reach -- --smoke --limit 8 --output /tmp/zttp-reach-smoke-all
```

Reference checks without an agent turn are available separately:

```sh
zig build provable-reach -- --references --output /tmp/zttp-reach-references
```

Live mode requires a clean known source revision, the DeepSeek API credential, and explicit confirmation.
The confirmation flag is an operator assertion that the live run was authorized; it is not a cost estimate or a billing cap.
The initial pilot command is:

```sh
zig build provable-reach -- --live --confirm-live --limit 1 --output /tmp/zttp-reach-live-pilot
```

Review the pilot's retained usage and outcome before authorizing the full eight-task run.
The authoring limits stay the same for the larger run.
Live runs have not been authorized in the M3 implementation session.

Run the offline integrity suite with `zig build test-provable-reach`.
It checks report membership, evidence origin, success evidence, and failure accounting.
The deterministic smoke supplies the separate end-to-end authoring and runtime evidence.

Each output directory contains `report.json` with the full task rows and `summary.json` with counts by input mode and outcome.
The summary's `headline` is null for offline and pilot runs.
`suite.json`, `tasks/`, `references/`, and `seeds/` retain the frozen task inputs and admission evidence.
Each `cases/<task-id>/` directory retains generated source, its manifest, the transcript, compiler and runtime output, and `result.json` with observed usage.
Live cases also retain provider exchanges and response diagnostics under `provider/`.

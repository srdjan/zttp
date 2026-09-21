---
title: "M3: measure bounded provable-set reach"
date: 2026-09-21
type: feat
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# M3: measure bounded provable-set reach

## Goal Capsule

Objective: report how many previously unused, demonstrably solvable tasks the product's default agent completes correctly within a fixed budget.
Means: a separate reference-backed task suite, the production agent loop, and a failure-inclusive report (KTD1).
Authority: the user's M3 selection and DeepSeek-only decision, then this plan and repository rules.
The main agent owns review, verification, and local commits on `main`; do not push.
Implement and verify the offline path first.
Live model runs require a concrete run proposal and separate cost approval.
Ask before a script that exceeds two minutes, as required by the session's AGENTS instructions.

---

## Product Contract

### Summary

Add a bounded reach measurement with reference solutions, executable acceptance checks, fixed task membership, and retained per-task evidence.
Report whole-handler and typed-hole results separately.

### Problem Frame

`STRATEGY.md` identifies provable-set reach as unmeasured.
The existing 19-case corpus reports recorded draft quality and runtime intent, but it has no reference solution for each task.
A past fixed seed became impossible after a correct checker change and appeared as a model failure.
Reference admission must detect that condition before a live run.

### Key Decisions

Use the current product default only (session-settled: user-directed - chosen over a provider comparison to bound the first measurement).
Governs R1.

### Requirements

| ID | Required behavior |
|---|---|
| R1 | Live runs use the repository's current DeepSeek default model and record its exact model ID and request policy. A default change invalidates the selected run configuration. |
| R2 | Each task has a prompt, input mode, initial files, required proof properties, a reference solution, and non-empty runtime acceptance checks. Both reference and candidate must satisfy the same absolute compiler and runtime checks. |
| R3 | Freeze task membership and input, reference, acceptance, and compiler identities before a model run. Reference programs and acceptance files are absent from the model workspace and tool responses. |
| R4 | Reach is the count of fresh candidates that satisfy R2 within the fixed budget divided by every selected task. Retain no-edit, proof, intent, budget, provider, and harness failures. No retry or omission may replace a failed sample. |
| R5 | Distinguish fresh-model, deterministic-harness, and replay evidence. Only a complete fresh run over the frozen suite can publish the full-suite reach fraction. Report mode subtotals as well. |
| R6 | Retain source revision, task and reference hashes, compiler policy, model request identity, budgets, generated files, runtime-check output, and per-case results. A partial or interrupted run is explicitly incomplete. |
| R7 | Validate the complete pipeline on one deterministic task in under a minute before increasing the task count. Change only the selected count when scaling that check. Live pilot and full runs need explicit authorization. |

### Scope Boundaries

The initial design has four task families, each exercised in whole-handler and typed-hole mode: eight task instances.
This is a design limit, not a statistical sample-size claim.
Choose small deterministic request/response families that are absent from the recorded corpus; preserve exact task behavior across modes.
The selected families are request media classification with `zttp:http`, optional query combination, bounded content previews with `zttp:text`, and a seeded deadline helper with `zttp:time`.
Exact fixture values are established by reference admission before the suite is frozen.
Hold them out from the shipped persona, examples, skills, and stand-in playbooks.
Describe this as a repository holdout, with no claim about provider training data.
After inspection or use for tuning, retain its version as regression evidence and require a new suite for a new holdout claim.

Do not change model defaults, compiler rules, the existing convergence corpus, qualification floors, or product behavior.
Provider comparisons and a wider task population are later decisions.
M2's outstanding full local verification remains separate.

---

## Planning Contract

### Key Technical Decisions

KTD1. Keep a separate Zig reach runner and report contract.
Reuse production loop, checker, runtime-intent, capture, and identity APIs where their contracts fit.
Do not reuse the qualification assessor: it hard-codes 19 cases and promotion thresholds, whereas model failures are valid measurement outcomes here.

KTD2. Admit references with the public precompile checker and the real `zttp test` path before provider initialization.
Require zero total errors, a handler contract, and all named task properties.
Use the same check for final candidates; an applied edit alone does not prove absolute correctness.
Reject invalid fixtures as harness failures before live spending.

KTD3. Preserve the existing production limits: 18 model round trips, 16 tool calls, and five verification attempts per task.
Use the existing DeepSeek recording ceiling of 600,000 milliseconds per task.
Record the actual request token policy from the initialized provider; do not invent a dollar estimate.
The deterministic smoke uses these same limits.
The live-run proposal must name the task count and measured pilot usage before a larger run is authorized.

KTD4. Write evidence directly as typed Zig JSON, with a report after each completed case and a final completeness check.
Do not introduce or extend a Python extractor.
Failure rows remain present even when no replayable cassette exists.
Store each run in a new output directory and refuse overwrites.

### High-Level Technical Design

```mermaid
flowchart TB
  A[Frozen task suite] --> B[Check all references]
  B --> C{References pass?}
  C -->|No| D[Refuse live run]
  C -->|Yes| E[Initialize selected model or deterministic client]
  E --> F[Run task in isolated workspace]
  F --> G[Check final compiler properties and runtime behavior]
  G --> H[Retain files and result, including failures]
  H --> I{All selected tasks accounted for?}
  I -->|No| F
  I -->|Yes| J[Validate report and derive fractions]
```

### Source Evidence

`packages/pi/src/expert_codegen_record.zig` owns the existing fixed corpus, live recorder, and failure capture.
`packages/pi/src/expert_codegen_eval.zig` exposes runtime intent checks with captured output.
`packages/pi/src/expert_evidence_identity.zig` provides content and evaluation identities.
`packages/pi/src/expert_qualification.zig` shows the failure-inclusive report pattern.
`packages/pi/src/loop.zig` owns loop limits and the production write path.
`packages/tools/src/precompile.zig` exposes the full checker.
The design follows `docs/solutions/logic-errors/a-stale-cassette-is-loud-and-an-unsatisfiable-seed-is-silent.md` and the gate rules in `AGENTS.md`.

---

## Implementation Units

### U1. Frozen tasks and reference admission

Goal: establish that every selected task is possible and that its acceptance checks distinguish correct behavior from a trivial green handler.
Requirements: R2, R3, R7.
Dependencies: none.
Files: new `packages/pi/src/expert_reach_corpus.zig` with adjacent tests; shared reach types if required.
Approach: define the four task families and paired input modes, with explicit proof requirements and exact runtime assertions.
Validate all reference programs before freezing identities.
Keep task data independent from the existing corpus.

Test scenarios:

- Each reference passes all named properties and every exact runtime assertion.
- The typed-hole seed is incomplete; inserting the reference solution gives the same task behavior as whole-handler mode.
- A constant-success response fails each family's acceptance checks.
- Empty acceptance input, duplicate task IDs, or missing reference data prevents admission.

Verification: unfiltered reference tests pass, and deliberate wrong responses fail for the expected acceptance check.

### U2. Report validation and reach counts

Goal: make the denominator and evidence origin explicit and testable.
Requirements: R3, R4, R5, R6.
Dependencies: U1's task contract; report logic can be authored independently.
Files: new `packages/pi/src/expert_reach_report.zig`, with adjacent tests.
Approach: use closed result and evidence-origin types, validate exact task membership and identities, and derive counts from result rows.
Represent tasks not yet attempted explicitly in checkpoint reports.

Test scenarios:

- A mixed success/failure run retains every task and gives the exact expected numerator and denominator.
- Duplicate, omitted, unknown, or mismatched task identities reject a complete report.
- Replay, deterministic runs, and partial pilots cannot claim a full fresh reach result.
- A success with missing proof, runtime, or artifact evidence is refused.
- Enumerate every failure variant and observe that it remains in the denominator.

Verification: unfiltered report tests pass and deliberate denominator/evidence mutations fail.

### U3. Runner and offline pipeline

Goal: run the selected tasks through the production authoring path and retain reviewable results.
Requirements: R1 through R7.
Dependencies: U1, U2.
Files: new `packages/pi/src/expert_reach.zig` and `expert_reach_main.zig`; `build.zig`; `packages/pi/src/tests.zig`; narrow shared helper changes only if needed.
Approach: expose explicit reference-check, deterministic-smoke, and gated live modes through a repository-only Zig command.
Use isolated task workspaces and the same final evaluator for references and candidates.
Preserve failure artifacts before workspace cleanup, and checkpoint all result rows.
Live mode requires a clean known source revision, the fixed DeepSeek selection, explicit output directory, and confirmation flag.

Test scenarios:

- One deterministic task traverses authoring, proof, runtime checks, and report validation.
- The full deterministic suite changes only task count and retains every result.
- A model error, no edit, wrong response, and exhausted budget produce typed failure rows.
- Reference or acceptance files are absent from model-visible files.
- A missing live confirmation, dirty source, conflicting provider override, or existing output directory fails before a model call.

Verification: measured smoke completes in under one minute; all eight offline task instances pass; unfiltered affected suites and module-boundary checks pass.

### U4. Run guide and measurement handoff

Goal: make the live run concrete and keep the published claims within the evidence.
Requirements: R1, R4 through R7.
Dependencies: U3.
Files: new `docs/provable-reach.md`; `docs/roadmap.md`; `docs/plans/README.md`; `CONCEPTS.md`; `docs/internals/testing.md`; `STRATEGY.md` only when its state claim changes.
Approach: document the exact suite, limits, report locations, holdout boundary, and commands.
Prepare a one-task live pilot proposal; disclose that the actual cost needs measurement.
After approval, retain its usage and failure evidence before proposing the full suite.

Verification: links and documentation gates pass; no offline result is published as model reach.

---

## Verification Contract

Run unfiltered `zig build test-provable-reach` and `zig build test-expert-app` after integration.
Run `zig build test-module-boundary test-docs-drift test-doc-links` for the touched boundaries and documentation.
Run `zig fmt --check` on changed Zig files.
Read build exit codes directly and keep logs outside the tracked tree.
Run a one-task deterministic smoke before the full suite, with the same limits and runtime evaluator.
Observe rejection after deliberate fixture, denominator, and evidence-origin mutations, then restore the files and rerun the affected gate.
If a required check exceeds two minutes, request approval before continuing it.

---

## Definition of Done

The offline implementation is complete when all admitted references pass, the deterministic pipeline works, adversarial report checks reject false claims, affected gates pass, and the run guide names an executable live command.
Each complete unit receives a separate reviewed local commit.
Remove experimental code and temporary fixtures before committing.

M3 itself is complete only after an authorized full fresh run has a retained report covering every task and failure under the frozen identities and budgets.
A low reach result is a valid measurement; an incomplete or invalid report is not.
Live cost and long-running command approval remain pending until the concrete handoff.

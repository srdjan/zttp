# Diagnostic teaching gaps: ZTS500 and the tool the model never calls

Status: proposed, not started. Written 2026-08-17.

## The premise was wrong, and correcting it is the first result

This plan was asked for as "teaching gaps against ZTS404/405 and ZTS200/400/500",
on my earlier report that `egress-options` cycled ZTS404/ZTS405 and
`parallel-secret` cycled ZTS200/400/500. That report was a measurement error. I
had grepped `ZTS\d{3}` across whole transcript files, which counts the model's
own reasoning text alongside anything the veto emitted.

Counted properly, per case, across the run-2 staging directory:

| case | ZTS500 | ZTS400 | ZTS200 | ZTS404 | ZTS405 | recorder's `fail=` |
|---|---|---|---|---|---|---|
| `egress-options` | 47 | 1 | 0 | 7 | 5 | ZTS500 |
| `parallel-secret` | 83 | 66 | 18 | 0 | 0 | ZTS200 |

ZTS500 dominates both by a wide margin, and the recorder's own summary line
agrees for `egress-options`. ZTS404 and ZTS405 are incidental mentions, not the
loop. `egress-options`' prompt contains no secret at all - it fetches a literal
URL with an init object - so a secret-in-URL rule was never the obstacle.

**The gap is ZTS500: handlers declare proof obligations they cannot discharge.**

## What the model actually does

From the `egress-options` transcript, the declared capsule on a handler that
does one fetch:

```
export function handler(req: Request): Proof<Response,
  | "deterministic" | "state_isolated" | "fault_covered" | "result_safe"
  | "optional_safe" | "no_secret_leakage" | "no_credential_leakage"
  | "input_validated" | "pii_contained" | "injection_safe" | "canonical"
  | "cost_bounded"
>
```

Twelve properties. The same shape appears in `durable-order`, `wait-signal` and
`workflow-saga-compensation` at thirteen. The model declares everything it can
name, cannot discharge all of it, and spends its roundtrip budget trying.

## The finding that makes this fixable

`pi_specs_status` already exists and answers exactly the question the looping
model needs answered. Its own header says so: "return the active spec set for a
handler plus the current discharge state of each active spec. The agent reads
this before drafting an edit". It returns `declared_specs`, and per failing
spec a `spec_name` and a `suggestion`.

It is registered and offered (`tool_registry.zig:69`).

Tool invocations counted in the three cases that burned their budgets:

| case | `pi_specs_status` | `pi_repair_plan` | `zts_expert_prove_patch` | `zts_expert_query` |
|---|---|---|---|---|
| `egress-options` | **0** | 0 | 0 | 14 |
| `parallel-secret` | **0** | 0 | 0 | 14 |
| `workflow-queued-call` | **0** | 0 | 0 | 15 |

Zero. In every case. The model spends its budget re-querying discovery and never
once asks which of its declared specs is failing.

Two reasons it would not:

1. The persona's always-sent routing index lists `pi_goal_check`,
   `pi_repair_plan` and `pi_goal_candidate` under "Goal proof and semantic
   repair" (`expert_persona.zig:92-94`). `pi_specs_status` is absent from it.
2. ZTS500's help text is "Either remove the spec name from the Proof<T, P>
   union or fix the handler so the property holds." It states the fork without
   naming which property failed or which tool answers that.

The guidance that does name it - "Start with `pi_specs_status`"
(`expert_workflow.zig:162`) - is not on the path a recorded codegen case takes.

## Interventions, in leverage order

### 1. Route the model to `pi_specs_status`

Add it to the persona routing index, and make ZTS500's help name it. This is the
smallest change with the largest expected effect: the tool, the answer, and the
per-spec suggestion all already exist and are simply never reached.

### 2. Repair intents that cannot repair

ZTS400, ZTS404 and ZTS405 all carry `Repair: insert_guard_before_line`. A guard
does not stop a secret reaching a response body or a URL - the fix is to not send
it, or to move it to a header. An agent that follows the declared repair intent
applies something that cannot clear the diagnostic, which is a loop generator.
These should carry no repair intent rather than a wrong one, unless a correct
primitive exists.

Verify before changing: confirm from a transcript that a wrong intent was
actually followed. `pi_repair_plan` was called zero times in all three cases, so
the harm here is currently theoretical and this is second priority, not first.

### 3. ZTS200 teaches nothing

`type_mismatch` carries a description and no help and no repair. It was mentioned
18 times in `parallel-secret` and is that case's recorded `fail=` code. It needs
help text at minimum.

### 4. The declaration problem itself

Routing to `pi_specs_status` treats over-declaration after the fact. Worth
considering separately, and NOT in this plan without evidence: whether the
default proof profile makes a wide capsule the path of least resistance. ZTS500
also fires when no capsule is present at all ("the default proof profile demands
a property this handler does not hold"), which plausibly teaches "declare more"
as the way out of the first error the model sees.

## Cost: this moves the policy hash

`computePolicyHash` hashes each rule's `help` (`rule_registry.zig:930`) and its
repair intent. So interventions 1, 2 and 3 all move `policy_hash`, which means:

- `policy-hash.txt` and `EXPECTED_POLICY_HASH` in `scripts/check-meta-drift.sh`
  update in the same commit, per that script's own rule.
- Every convergence row published before the change carries the old policy hash
  and is no longer comparable to rows after it - `docs/convergence.md` says two
  rows with different policy hashes are measuring different things.

Adding the tool to the persona routing index alone does NOT move the policy hash.
That argues for sequencing intervention 1 by itself first: it is the highest
leverage, and it is the only one that costs no comparability.

## Success criteria, measurable from a recording

Necessary, in order:

1. `pi_specs_status` invocation count is greater than zero in at least one case
   that trips ZTS500. If it stays zero, routing did not work and nothing
   downstream matters.
2. ZTS500 mentions per failing case drop materially from the 47 and 83 baseline.
3. `egress-options`, `parallel-secret` and `workflow-queued-call` apply an edit
   (`applied=true`) rather than exhausting 18 roundtrips.
4. Raw first-draft pass rises above the 12/19 of run 2.

Criterion 1 is the honest gate. Criteria 3 and 4 are subject to the run-to-run
variance already observed - three cases flipped between runs 1 and 2 with no
change touching them - so a single run cannot confirm them. Treat a single run as
evidence only for criterion 1, which is a behavioural fact rather than a rate.

## Open questions, with a recommendation each

1. **Do intervention 1 alone first, or bundle 1-3?**
   Recommend alone. It is the only one that does not move the policy hash, so
   its effect can be measured against the existing convergence rows. Bundling
   forfeits that comparison to save one recording.

2. **Should ZTS404/405/400 lose their repair intent, or gain a correct one?**
   Recommend lose it, pending evidence. A wrong intent is worse than none, and
   no correct primitive exists for "move this value out of the URL".

3. **Is the default proof profile teaching over-declaration?**
   Recommend investigating before acting. This needs a probe: draft a minimal
   handler with no capsule, read the exact ZTS500 text, and judge whether it
   points toward a minimal capsule or toward a wide one.

## Not in scope

Anything about context size or compaction. Both research agents concluded
independently, and I verified the numbers, that these cases hit the 18-roundtrip
cap (`loop.zig:262`) with peak input at 31,477 tokens against a 1,000,000-token
window - 3% used. They ran out of ideas, not context.

---
title: A stale cassette is loud and an unsatisfiable seed is silent
date: 2026-09-20
category: logic-errors
module: packages/pi/src/expert_codegen_record.zig (codegen corpus holes-mode seeds), packages/zts/src/flow_checker.zig (unknown-label sink clearing)
problem_type: logic_error
component: testing_framework
severity: high
symptoms:
  - "`docs/convergence.md` reported `cache-counter-holes` as applied-no-edit in all three report-only qualification cohorts over corpus `0012ad8ca6d5`, and named it a property of the case."
  - "Every fill that carries the cached counter into the response body - `Response.json({ hits: hits })`, `String(hits)`, `Number(hits)`, `String(Number(hits))` - produces exactly two ZTS500 errors against `no_secret_leakage` and `no_credential_leakage`."
  - "Dropping those two specs from the seed capsule gives zero errors and exit 0 with no other change."
  - "The whole-file sibling `cache-counter` kept passing, because in whole-file mode the model authors its own capsule and can narrow it."
  - "Nothing failed the build. The corpus replayed clean and the case merely recorded a worse outcome, which was then published under the model's name."
root_cause: logic_error
resolution_type: test_fix
related_components:
  - flow_checker
  - virtual_modules
  - typed_holes
  - record_replay
tags:
  - pi
  - typed-holes
  - record-replay
  - model-measurement
  - flow-analysis
  - taint-labels
  - latent-defect
  - convergence
applies_when:
  - "Landing a flow-checker fence that adds `.unknown` or otherwise clears a sink property, and deciding which downstream inputs it can invalidate"
  - "Reading a corpus case that fails identically across cohorts as an agent failure"
  - "Writing a holes-mode corpus seed whose `Proof<...>` capsule the model cannot edit"
  - "Citing `docs/convergence.md` against a qualification floor that authorizes changing the product default"
---

# A stale cassette is loud and an unsatisfiable seed is silent

## Problem

A correct security fence made a corpus case impossible to pass, and because the
case is a fixture whose declared expectation is model *input* rather than model
*output*, nothing failed. The corpus replayed clean, the case recorded a worse
outcome, and `docs/convergence.md` published that outcome as a fact about the
agent for three consecutive qualification cohorts.

## Symptoms

`cache-counter-holes` recorded "applied no edit" in all three report-only
cohorts over corpus `0012ad8ca6d5`, scoring 13/19, 15/19 and 13/19 on raw
first-draft pass against the floor of 14 that
`packages/pi/src/expert_qualification.zig:16` sets for changing the product
default. The page named the case and called it a property of the case rather
than a sample (`docs/convergence.md:32-35`).

The case is a `.mode = .holes` entry (`packages/pi/src/expert_codegen_record.zig:2016`,
mode at `:2047`). Hole mode, per the `Mode` doc comment at `:829-831`, "seeds a
skeleton whose response expressions are `hole()` and asks for them to be filled
one at a time", against whole-file mode, which "hands the agent an empty
workspace and asks for a handler". The skeleton carries the handler signature,
and the signature carries a `Proof<Response, ...>` capsule. Until `3a19cca5`
that capsule named `no_secret_leakage` and `no_credential_leakage`. A capsule in
a seed file is not something the model authors. It is the fixed input of the
task.

Twelve days earlier, `f87f97aa` (2026-09-08, "fix(zts): five store reads assert
ignorance instead of a benign label", an origin/main commit that `afe1dc10`
later merged into local main) changed what that capsule could mean. `cacheGet` now declares
`.return_labels = .{ .internal = true, .unknown = true }`
(`packages/modules/src/data/cache.zig:52`), because a store read hands back
whatever a separate write put there and the read call holds no reference to that
write. At the sink, `checkSinkLabels` does
`if (labels.has(.unknown)) self.clearSinkProperties(sink);`
(`packages/zts/src/flow_checker.zig:1994`), and the `.response` arm of
`clearSinkProperties` sets `no_secret_leakage`, `no_credential_leakage` and
`deterministic` to false without condition (`flow_checker.zig:2202-2208`). Any
fill that carries `hits` into the response body therefore arrives at the sink
carrying `.unknown`, the two leak properties are cleared, and the declared
capsule cannot be discharged: `packages/zts/src/spec_discharge.zig:348-362`
records each declared spec the property block does not hold as
`not_discharged`, which `packages/tools/src/precompile_check.zig:637` renders as
"declared Proof capsule was not discharged by handler proof", code ZTS500.

The fence is correct. The fixture was correct when it was written. On 2026-09-08
the two stopped being compatible, and nothing said so.

## What Didn't Work

**Reading the cohort table as a test of model variance.** The three cohorts were
designed and read as a repeatability measurement, concluding the headline is
"stable to about one case". That reading treats every failing case as part of
the model's spread, and the aggregate cannot distinguish the two populations:
13, 15 and 13 is equally consistent with several cases that never pass plus a
few that flip. A sampling model does not score the same three times unless
something fixed is deciding the outcome. (session history)

**Attributing the whole convergence jump to the analyzer.** The merge that
brought the fence into this tree (`afe1dc10`, 2026-09-20, "Merge origin/main
into local main", a local-main commit which has `f87f97aa` as an ancestor)
moved raw first-draft pass from 8/19 to 13/19, and that jump was attributed to
the analyzer, since
prompts, model and request policy were unchanged. Nothing separated the cases
the label-flow fixes made newly *passable* from the case the `.unknown` rule
made newly *unprovable* in the same merge. A correctness improvement and the
cost it imposed were measured as one number. (session history)

**Trusting that a tightened proof announces itself.** `f87f97aa`'s author did
look for downstream effects and found some: the message records that "the two
recorded DeepSeek corpus replays in expert_codegen_record.zig fail with
StaleCodegenCassette" and narrows the durable module example that "claimed four
properties the compiler can no longer prove for it". Both of those are loud. A
stale cassette is `error.StaleCodegenCassette` returned from
`expert_codegen_record.zig:4773` after printing the re-record command; a module
example sits under a gate. The holes seed is neither.

## Solution

Remove the two specs no fill can discharge from the seed capsule (`3a19cca5`,
2026-09-20, "fix(pi): two corpus cases asked for what they never stated", local
main), and record the reason in the case comment.

```zig
// before: the capsule is fixed input, and two of its specs no fill can discharge
\\function handler(req: Request): Proof<Response, "retry_safe" | "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {

// after (expert_codegen_record.zig:2027)
\\function handler(req: Request): Proof<Response, "retry_safe" | "state_isolated" | "result_safe" | "optional_safe" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
```

Because seed bytes are inside `headlineInputIdentity`, the edit moved the corpus
version from `0012ad8ca6d5` to `e6801afae099` and forced a paid whole-corpus
re-record (`b66b3bca`, 2026-09-20, "test(pi): re-record the corpus against the
two amended cases", local main). That is by design: `recordingRunCanActivate`
(`:2669`) requires `selected == record_corpus.len`, and a filtered run ends in
`error.PartialRecordingQuarantined` with the staged artifact left where it is
(`:3723-3727`).

## Why This Works

The fill the prompt asks for now discharges the nine properties that remain, and
the case measures hole filling instead of measuring an impossible request.

The deeper reason the defect survived is that the recorder's identity hash
cannot see it. `headlineInputIdentity()` hashes each case's name, prompt, seed
files and mode (`expert_codegen_record.zig:961-984`), and `corpusVersion()` is
that hash (`:1045-1047`). The seed's bytes did not change on 2026-09-08. What
changed is whether a program exists that satisfies them, and no hash over bytes
measures satisfiability. The identity detects an edit to the input. It does not
detect a change in what the input means.

So a fence change that reaches a fixed-input fixture produces no error. It
produces a lower number, and a lower number is exactly what a convergence
measurement is allowed to produce.

The recorded turn is the evidence that the agent was right. The pre-fix
generation (`68b522ad...`, ten model calls, four of them
`zts_expert_fill_hole`) tabulates what the model tried at the hole:
`Response.json({ hits: String(hits) })`, refused with two new ZTS500 for the two
leak specs; `Response.json({ hits })`, refused with ZTS001 because object
literal shorthand is outside the profile; and `Response.json({ hits: hits })`,
refused with the same two ZTS500. A fourth fill, `Response.json({ hits:
Number(hits) })`, was sent and answered but is absent from that table: the model
ran out of budget before reading the result and listed the coercion as something
to try next turn. It confirmed the pair through `zts_expert_review_patch`, asked
`pi_repair_plan` for the two leak goals and got no plans and no witnesses, and
ran `pi_goal_check` on the hole-bearing file, which it reported as holding both
leak properties with 0 errors. That last figure is the model's own account: the
recording stores tool results by digest only, so the number is not independently
readable from the artifact, though the mechanism below explains why it is what
it would be. It then wrote: "I hit
the turn's tool-call budget before I could land a fill, so I'm reporting state
rather than claiming an edit", and: "I did not commit any of these - nothing was
written, and I won't claim otherwise." The manifest agrees: `expected_workspace`
carries the same `handler.ts` digest as `initial_workspace`. That is the correct
answer to an unsatisfiable request, and it was scored as a failure three times.

One detail shows why hole mode cannot warn about this on its own. The frame the
model quoted said `undischarged ["cost_bounded","optional_safe","result_safe"]`
and did not name the leak specs. That was accurate for the file as it stood.
`packages/zts/src/contract_builder.zig:940-972` builds a hole summary by
projecting the `not_discharged` and `missing_capsule` diagnostics of the owning
function, and with `hole()` in place nothing flowed into the response, so both
leak properties were proven and no diagnostic named them. Hole mode reports what
the file with the hole owes. It cannot report a property the fill will cost when
that property holds only because the hole flows nothing.

## Prevention

**When a fence tightens, walk it through every fixture that carries the affected
property as fixed input, and re-measure each one against the built compiler
before the next recording.**

The distinction that decides whether a fixture is at risk is who authors the
expectation. In whole-file mode the model writes its own `Proof` capsule, so
when a fence moves the model absorbs it. The whole-file sibling `cache-counter`
says so in its own comment: "Noticing that a store read costs the default
profile and narrowing the Spec accordingly is the model behaviour being
measured; saying it in the prompt would measure instruction-following instead"
(`expert_codegen_record.zig:1767-1770`). In hole mode the capsule is in the seed
bytes, so the same fence turns the case into a request that no program
satisfies.

The practice has three parts.

First, when a change to a binding, a sink rule or a discharge rule can move a
property from held to not held for some program shape, name the property and
search the tree for fixtures that declare it as input rather than produce it as
output. The places to look here are the `.seed_files` of every `.mode = .holes`
case in `expert_codegen_record.zig`, the `module_examples` in
`packages/tools/src/example_registry.zig`, and any documentation example whose
capsule a gate checks. `f87f97aa` did the second of those. It did not do the
first.

Second, for each fixture found, write the fill the prompt asks for, run the
built `zttp check` on it, and read the ZTS500 count:

```bash
mkdir -p /tmp/probe
cat > /tmp/probe/handler.ts <<'PROBE'
import { cacheGet } from "zttp:cache";

function handler(req: Request): Proof<Response, "retry_safe" | "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
  const hits = cacheGet("counters", "hits");
  if (hits === undefined) {
    return Response.json({ hits: "0" });
  }
  return Response.json({ hits: hits });
}
PROBE
./zig-out/bin/zttp check /tmp/probe/handler.ts | grep -c ZTS500
```

Measured in the `3a19cca5` session: 2 for this fill, and 2 for each of
`String(hits)`, `Number(hits)` and `String(Number(hits))` in its place. Remove
`"no_secret_leakage" | "no_credential_leakage"` from the capsule and run the
same command: measured 0, exit 0. A fixture whose every candidate fill scores
the same non-zero count is not measuring the model.

Third, read a case that behaves identically in every cohort as a question about
the case before reading it as a fact about the model.

**The standing example to check first.** `egress-options-holes`
(`expert_codegen_record.zig:2062`) declares the same two leak specs and carries
an upstream payload into the response body. It passes today only because `fetch`
declares `.return_labels = .{ .external = true }`
(`packages/modules/src/net/fetch.zig:69`) rather than `.unknown`, and because
`f87f97aa` touched five store reads only: `cacheGet`, `queue.receive`, `sqlOne`,
`sqlMany` and `durable.waitSignal`. It was measured passing in the
`e6801afae099` recording. One future fence on an egress read breaks it in
exactly the same silent way, so it is the first fixture the rule above should be
run against.

**Which side of the identity a fix lands on decides what it costs.** Seed bytes
and prompts hash into `headlineInputIdentity`, so editing them forces a paid
whole-corpus re-record. An intent spec hashes into `intentSuiteIdentity()`
(`:986`) and not into the corpus version, so a spec edit leaves the committed
recordings replayable. `workflow-saga-compensation` is the precedent:
`5fe52ae5` (2026-09-20, a local-main commit) changed the spec rather than the
prompt and needed no re-record, and that case's
own comment had wrongly claimed one was required. (session history) Prefer the
spec side when both would fix the defect, and find a stale seed before a
recording rather than after three.

## Related Issues

- [empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md) - where `.unknown` and `clearSinkProperties` come from, and the fence this fixture sat downstream of
- [an-export-that-declared-no-labels-answered-clean](../security-issues/an-export-that-declared-no-labels-answered-clean.md) - says state-mediated flow (a cache write then a read) is "not addressed here"; `f87f97aa` has since closed that, so the sentence is stale
- [a-proxy-signal-carried-a-proof-it-never-claimed](a-proxy-signal-carried-a-proof-it-never-claimed.md) - closest neighbour; its Prevention says Spec-carrying fixtures "fail loudly when a proof tightens", which holds for examples and goldens and not for corpus seed capsules, and that belief is what let this defect sit for three cohorts
- [a-gate-that-counts-nothing-still-reports-a-pass](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) - the sibling failure in which a green output is cited as evidence; here the output was a number rather than a pass, and it was cited as a model result
- `AGENTS.md`, the `.unknown` rule for store reads - states the fence and does not name the fixtures that declare the property as fixed input
- `docs/convergence.md:32-49` - the cohort paragraph that first named the case as a property of the case, and its amendment
- `f87f97aa`, `3a19cca5`, `b66b3bca` - the fence, the seed fix, and the re-record. This repository works on local `main` and does not open pull requests, so commits are cited by SHA; of these only `f87f97aa` has reached `origin/main`, and the rest may be rewritten if they are ever rebased.

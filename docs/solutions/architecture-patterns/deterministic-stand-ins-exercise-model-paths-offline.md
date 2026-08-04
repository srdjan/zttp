---
title: Use Deterministic Stand-ins to Exercise Model Paths Offline
date: 2026-08-04
category: architecture-patterns
module: pi
problem_type: architecture_pattern
component: testing_framework
severity: high
applies_when:
  - A paid, rate-limited, or unavailable model blocks verification of the workflow around it
  - Recorder, repair, Veto, or multi-turn tool paths need deterministic regression coverage
  - An offline substitute must preserve production transport, compiler, approval, and persistence boundaries
  - Model-quality measurements must stay separate from harness verification
related_components:
  - provider_transport
  - record_replay
  - deterministic_standin
  - veto_loop
  - typed_holes
tags:
  - deterministic-standin
  - offline-verification
  - provider-transport
  - record-replay
  - veto-repair
  - typed-holes
  - model-measurement
---

# Use Deterministic Stand-ins to Exercise Model Paths Offline

## Context

An `InsufficientCredit` response on 2026-08-03 blocked work on the recorder,
Veto and repair paths, and the typed-hole loop. The model call had become the
only way to reach surrounding production machinery, even when the behavior
under test was deterministic and did not concern model quality.

The dangerous shortcut was to test a parallel implementation. A key-gated test
could skip, a stand-in could call a tool directly, or a scripted hole fill could
bypass the compiler publisher and still report green. Earlier sessions also
found that transcript-wide step counting answered the wrong ask on a second
turn, and that a clean process exit did not prove a live corpus was complete
(session history).

## Guidance

Place the offline seam at the model's choice. Give it a bounded scripted
response, then leave the production boundaries on both sides intact. An unknown
prompt or unreachable state must refuse rather than fall back to a hosted model
or invent an answer.

For recorder coverage, send deterministic Anthropic SSE through the production
client and recording tee, persist the cassette, load it, and replay it. The
loopback smoke test follows that exact path without credentials
(`packages/pi/src/expert_codegen_record.zig:162-224`). The shared local server
knows only how to serve one HTTP response, not how to emulate a provider
(`packages/pi/src/providers/cassette_record.zig:352-404`).

For repair coverage, seed a draft the real Veto rejects. Let the compiler author
the candidate, run that candidate through the full Veto and approval gate, and
apply it through the normal edit boundary. The result distinguishes this from a
model retry, and the regression test requires both rejection and the exact
on-disk repair (`packages/pi/src/loop.zig:200-210`,
`packages/pi/src/standin_tests.zig:183-206`).

For typed holes, make the compiler publisher authoritative. A deterministic
turn must read the current file, call `zts_expert_holes`, parse its frame, call
`zts_expert_fill_hole` at the published coordinate, and apply the proposal
(`packages/pi/src/standin/playbook.zig:327-399`). Fill one site, persist it,
then begin the next turn from the changed file. The two-turn gate proves that
the second frame describes the first accepted fill and that both expressions
compose on disk (`packages/pi/src/standin_tests.zig:344-430`).

Keep failure semantics production-shaped too. The publisher reports a failed
tool result when analysis produces no contract or any compiler errors, instead
of treating either state as an empty hole set
(`packages/pi/src/tools/zts_expert_holes.zig:117-145`). A stale, foreign, or
ambiguous source has no deterministic seed and must be refused
(`packages/pi/src/standin/hole_seeds.zig:65-79`).

Do not publish model-quality claims from these fixtures. Deterministic runs can
prove protocol, path, state-transition, and outcome coverage. First-draft pass
rate, intent rate, round trips, provider behavior, and convergence remain
empirical measurements from live recorded turns.

## Why This Matters

The separation makes routine engineering reproducible and free without
weakening the deployed causal chain. Provider credit can block acquisition of
new empirical evidence, but it cannot block changes to transport capture,
replay, Veto handling, compiler repair, tool schemas, or multi-turn state.

It also prevents the opposite category error. A deterministic proposer is
written to produce declared outcomes, so its green result is evidence about the
machinery and fixtures, never evidence that a model will choose the same path.

## When to Apply

- A regression lives around a model call rather than in the model's judgment.
- The workflow must be exercised without network access, credentials, or credit.
- Later tool calls depend on compiler-authored coordinates or persisted state.
- A fail-closed boundary must remain observable under deterministic input.
- A live evaluation needs a separate, explicitly gated acquisition path.

## Examples

```text
loopback SSE -> production provider parser -> record tee -> cassette on disk
             -> production cassette loader -> replay -> asserted reply
```

```text
read current file -> publish compiler frame -> fill one published site
                  -> Veto and approval -> apply -> begin next turn
```

The first sequence tests recorder fidelity. The second tests deterministic
multi-turn composition. Neither sequence measures a model.

## Related

- [Offline coverage contract](../../coverage.md)
- [Roadmap history and the live-only boundary](../../roadmap.md)
- [A Veto retry read as a new ask and restarted the turn](../integration-issues/a-veto-retry-read-as-a-new-ask-and-restarted-the-turn.md)
- [Two hole fills in one turn do not compose](../logic-errors/two-hole-fills-in-one-turn-do-not-compose.md)
- [Empty baseline made a file-destroying edit prove clean](../logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md)
- [Difference is not the claim and a probe must compile](../conventions/difference-is-not-the-claim-and-a-probe-must-compile.md)

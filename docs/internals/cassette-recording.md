# Recording the codegen cassettes

The published convergence number is a measurement of a live model. It comes
from a corpus of recorded model turns, one cassette per case, replayed offline
by `zig build test-expert-app`. Replay is deterministic, needs no network and
no key, and is what CI runs. Recording is the opposite: it spends real model
time, and for a hosted provider it sends handler source off the machine.

This page states how to record the thirteen current DeepSeek cases. The corpus
lives in `packages/pi/src/expert_codegen_record.zig`.

## When a re-record is owed

A cassette pins the exact request that produced it, under three digests.
`request_context_sha256` covers the provider, the model id, the output and
reserve token budgets, the streaming mode, the request purpose, the cache
policy, the system prompt digest, and the tool schema digest.
`transcript_sha256` covers the conversation the turn had reached, tool results
included. `wire_request_sha256` covers the serialized request body itself.
Replay recomputes all three from the live build and refuses a cassette whose
digests no longer match, reporting `model_context_mismatch` or
`transcript_or_transient_prompt_mismatch` and failing with
`error.StaleCodegenCassette`.

An edit to the expert persona, to any skill or prompt template it embeds from
`packages/pi/src/skills/` and `packages/pi/src/prompts/`, or to any registered
tool's name, description, or input schema makes every cassette stale at once
through the first digest.

The other two are the ones a compiler change reaches, because anything the
compiler publishes into a tool result is part of the transcript: the module
registry payload, the inline handlers in
`packages/tools/src/example_registry.zig` behind `meta.payload.examples`, and
the compiler version string. The compiler version reaches the transcript
through the `zts_expert_query` metadata result. Every version bump therefore
owes a full recording. Bump the version last, and treat the bump and recording
as one change.

Handler files under `examples/` are not embedded and do not stale the corpus.
`example_registry.zig` carries its own inline handlers.

None of this is a defect in the pins. The recorded turn is what one model did
against one prompt, and re-pinning it against a different prompt would publish
a number no run produced.

A cassette can also run out of steps. If a compiler change makes the veto
reject a draft that used to pass, the turn retries and asks for one more model
call than the recording holds. The replay reports `ReplayMismatch` and names
the case.

## Before recording

Finish compiler, persona, protocol, and tool-catalog changes before recording.
Those inputs are part of the request identity, so recording first only creates
artifacts that the completed implementation must reject. A stale replay is the
expected state during a direct cutover.

Replay first. A failing replay tells you which cases are stale and confirms the
harness is sound offline:

```bash
zig build test-expert-app
```

Recording is gated on `ZTTP_CODEGEN_RECORD=1`. A hosted provider additionally
needs its API key **in the environment**: the recorder reads the key with
`getenv`, so a credential stored by `zttp auth` does not satisfy it. Without the
flag, or without the key, the recording test skips silently and the replay test
runs instead.

The recorder can run from an uncommitted source tree. Publication requires the
resulting source and recordings in a clean commit with accepted provenance.

## The command

```bash
ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_PROVIDER=deepseek \
  ZTTP_CODEGEN_TURN_TIMEOUT_MS=600000 \
  zig build test-expert-app -Dtest-filter="record codegen baseline corpus"
```

The recording run must select all thirteen cases. `ZTTP_CODEGEN_ONLY` and
`ZTTP_CODEGEN_LIMIT` cannot activate the current corpus.

### Environment

| Variable | Effect |
|---|---|
| `ZTTP_CODEGEN_RECORD=1` | Required. Without it the recording test skips. |
| `ZTTP_CODEGEN_PROVIDER` | Use `deepseek` for the current corpus. |
| `ZTTP_CODEGEN_MODEL` | Records against a model other than the provider default. |
| `ZTTP_CODEGEN_ONLY` | Records one case by name and leaves every other cassette untouched. |
| `ZTTP_CODEGEN_LIMIT` | Caps the case count, for a cheap small-scale validation before a full run. |
| `ZTTP_CODEGEN_TURN_TIMEOUT_MS` | Per-turn ceiling. Use `600000` for the current DeepSeek recording. |
| `ZTTP_CODEGEN_TOOLS` | Comma-separated allowlist that shrinks the model-facing tool catalog, for non-publishable experiments. It never drops `propose_change_set`, and it fails on a name matching no model-visible tool. |
| `ZTTP_CODEGEN_REPLAY_PROVIDER` | Replays a non-headline corpus. Recording ignores it. |

### The per-turn ceiling

`ZTTP_CODEGEN_TURN_TIMEOUT_MS` exists because a stalled generation is silence
rather than an error, and one stalled case would otherwise take the whole run
with it. The default of 180000 can truncate heavier hosted cases. The current
recording contract requires a 600000-millisecond ceiling.

A turn cut off by the ceiling can never replay. The replay finishes in
milliseconds and asks for one more model call than the recording holds, so the
recorder refuses to promote such a turn rather than emitting an artifact that
fails later as a false divergence. Raise the ceiling for the provider you are
recording against; do not lower it to make a run finish.

## Per provider

### DeepSeek (the default and the headline)

DeepSeek is `models.default_provider`, so a bare `zttp expert` uses
`deepseek-v4-flash` and the published convergence row describes the model a
user actually gets. Re-recording this corpus moves the headline number.

Handler source leaves the machine on a DeepSeek turn.

```bash
export DEEPSEEK_API_KEY=...          # must be in the environment, not just stored
ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_PROVIDER=deepseek \
  ZTTP_CODEGEN_TURN_TIMEOUT_MS=600000 \
  zig build test-expert-app -Dtest-filter="record codegen baseline corpus"
```

Registered models: `deepseek-v4-flash` (default) and `deepseek-v4-pro`.
`DEEPSEEK_BASE_URL` selects a different HTTPS root for a gateway; it must carry
no credential.

Artifacts: `packages/pi/src/simulator/testdata/empirical/deepseek/codegen/`.

### Local artifacts

The sixteen local recordings remain parked historical artifacts. They do not
establish current replay compatibility or current model quality. The fifteen
saved sessions also remain historical and must refuse stale protocol identities.

## Which corpus this repository records

The recording target is one thirteen-case DeepSeek headline corpus. The local
provider remains available for interactive use. This release does not record
a separate local corpus.

## One case, or the whole corpus

Use `ZTTP_CODEGEN_LIMIT=1` only for a small pipeline validation. Discard those
artifacts. Then run the complete corpus with only the limit changed.

`ZTTP_CODEGEN_ONLY=<name>` is also diagnostic only. It cannot replace the
complete thirteen-case recording required after a protocol or language change.

A corpus must not be half re-recorded against two models: the replay asserts
that every cassette names the same model, because two would publish one row
averaging both.

## After recording

Replay offline to confirm the new cassettes are sound, then publish:

```bash
zig build test-expert-app          # must pass with no stale case
bash scripts/update-convergence.sh # appends a row to docs/convergence.md
bash scripts/update-coverage.sh    # rewrites docs/coverage.md
```

Both scripts build `zttp` first, because the intent checks drive the built
binary rather than the engine directly. Both read a single machine-readable
line from the replay: `[codegen-convergence]` and `[proof-coverage]`
respectively. `scripts/check-convergence-emitter.sh` holds each marker to one
producer and one publisher, so neither page can be written from the other's
measurement.

Never edit the generated Markdown or JSON by hand. Both publishers require a
clean tree and a replay marker from clean source. Run them one at a time.
Publish and commit convergence first. Then publish coverage from that clean
convergence commit.

A recording that moves a case's runtime intent outcome also moves its
`expect_committed_intent_pass` pin, and the gate that checks it requires the pin
to move in the same commit as the cassettes.

Publish last. `zig build release-provenance` accepts the two pages only when
every commit after the one they name touches nothing but `docs/coverage.json`,
`docs/coverage.md`, `docs/convergence.json`, and `docs/convergence.md`. So the
cassettes, the pins, and every other source and doc change land first, and the
two publisher runs are the final commits of a release. Publishing earlier costs
one full republish cycle per later commit, and each cycle appends another row to
`docs/convergence.md`.

## See also

- [Convergence](../convergence.md) - the published table and what a row means.
- [Coverage](../coverage.md) - which advertised rules the corpus trips.
- [Test Steps](testing.md) - what each `zig build test*` step runs.

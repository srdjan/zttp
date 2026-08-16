# Recording the codegen cassettes

The published convergence number is a measurement of a live model. It comes
from a corpus of recorded model turns, one cassette per case, replayed offline
by `zig build test-expert-app`. Replay is deterministic, needs no network and
no key, and is what CI runs. Recording is the opposite: it spends real model
time, and for a hosted provider it sends handler source off the machine.

This page states how to re-record that corpus against each supported provider.
The corpus itself lives in `packages/pi/src/expert_codegen_record.zig`, which
also owns both build steps described here.

## When a re-record is owed

A cassette pins the exact request that produced it. Each recorded turn carries
a `request_context_sha256` over the provider, the model id, the output and
reserve token budgets, the streaming mode, the request purpose, the cache
policy, the system prompt digest, and the tool schema digest. Replay recomputes
that digest from the live build and refuses a cassette whose digest no longer
matches, reporting `model_context_mismatch` and failing with
`error.StaleCodegenCassette`.

So an edit to the expert persona, to any embedded skill or example it carries,
or to any registered tool's name, description, or input schema makes every
cassette stale at once. That is not a defect in the pins. The recorded turn is
what one model did against one prompt, and re-pinning it against a different
prompt would publish a number no run produced.

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

Record into a clean tree. Every case runs in its own temporary workspace with
cwd switched to it, but the artifacts are written to the repository, and a row
published from uncommitted work cannot be reproduced from its commit.

## The command

```bash
ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_PROVIDER=<provider> \
  zig build test-expert-app -Dtest-filter="record codegen baseline corpus"
```

`<provider>` is `deepseek`, `local`, `claude`, or `openai`. It defaults to
`local` when unset, which is rarely what a hosted run intends, so set it
explicitly.

### Environment

| Variable | Effect |
|---|---|
| `ZTTP_CODEGEN_RECORD=1` | Required. Without it the recording test skips. |
| `ZTTP_CODEGEN_PROVIDER` | `deepseek`, `local`, `claude`, or `openai`. Defaults to `local`. |
| `ZTTP_CODEGEN_MODEL` | Records against a model other than the provider default. |
| `ZTTP_CODEGEN_ONLY` | Records one case by name and leaves every other cassette untouched. |
| `ZTTP_CODEGEN_LIMIT` | Caps the case count, for a cheap small-scale validation before a full run. |
| `ZTTP_CODEGEN_TURN_TIMEOUT_MS` | Per-turn ceiling. Defaults to 180000. |
| `ZTTP_CODEGEN_LOCAL_RUNTIME` | `name@version` of the local server stack. Local provider only. |
| `ZTTP_CODEGEN_MODEL_REVISION` | Overrides the model revision the recorder otherwise reads from the Hugging Face cache. Local provider only. |
| `ZTTP_CODEGEN_TOOLS` | Comma-separated allowlist that shrinks the model-facing tool catalog, for non-publishable experiments. It never drops `propose_change_set`, and it fails on a name matching no model-visible tool. |
| `ZTTP_CODEGEN_REPLAY_PROVIDER` | Replays a non-headline corpus. Recording ignores it. |

## Qualification is not recording

Qualification measures a candidate without replacing a committed corpus. It
attempts all 19 cases, keeps every generated flow under `.zig-cache`, and emits
one report-only run record. `scripts/qualify-expert.sh` performs three
consecutive runs and passes the records to the typed `expert-qualification`
gate. It refuses filters, a dirty source tree, missing local provenance, and a
run that omits any case.

Every run must reach 19/19 final green, 18/18 runtime intents, at least 14/19
raw model-authored first-draft passes, a median of at most four model round
trips, and zero empty, timeout, decode, provider, or internal failures. All
three runs must bind the same source, model, request policy, prompt, tool
catalog, compiler identities, cohort identities, and local serving provenance.

The wrapper spends three full runs of real model time, so it requires an
explicit confirmation flag. For the current local candidate:

```bash
mlx_lm.server --model mlx-community/Qwen3-8B-4bit --host 127.0.0.1 --port 8080

export ZTTP_CODEGEN_QUALIFY_CONFIRM=1
export ZTTP_CODEGEN_PROVIDER=local
export ZTTP_CODEGEN_MODEL=mlx-community/Qwen3-8B-4bit
export ZTTP_CODEGEN_MODEL_REVISION=<exact-model-revision>
export ZTTP_CODEGEN_MODEL_ARTIFACT_SHA256=<canonical-snapshot-sha256>
export ZTTP_CODEGEN_QUANTIZATION=4-bit
export ZTTP_CODEGEN_CHAT_TEMPLATE_SHA256=<canonical-chat-template-sha256>
export ZTTP_CODEGEN_SERVING_ARGS='mlx_lm.server --model mlx-community/Qwen3-8B-4bit --host 127.0.0.1 --port 8080'
export ZTTP_CODEGEN_HARDWARE="$(uname -m)"
export ZTTP_CODEGEN_OS="$(uname -srv)"
export ZTTP_CODEGEN_PEAK_MEMORY_BYTES=<measured-serving-process-peak>

bash scripts/qualify-expert.sh > /tmp/qwen3-8b-4bit-qualification.json
```

The local request adapter sends no temperature, top-p, or seed override, so the
report records `server-defaults` and a null seed. The exact serving arguments
remain part of the report; secret-shaped serving flags are refused instead of
being logged. A passing report sets `qualified: true` and still
sets `default_change_authorized: false`. Changing either the LFM local-provider
default or the DeepSeek product default is a separate product decision.

### The per-turn ceiling

`ZTTP_CODEGEN_TURN_TIMEOUT_MS` exists because a stalled generation is silence
rather than an error, and one stalled case would otherwise take the whole run
with it. The default of 180000 truncates the heavier hosted cases: the DeepSeek
corpus was recorded at 600000.

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

### Local (MLX)

The local path needs a server on `http://127.0.0.1:8080`, or wherever
`ZTTP_MLX_BASE_URL` points. Both tool flags below are required for LFM2: without
them the server returns its native `[fn(arg='x')]` calls as prose and the agent
loop sees nothing to run.

```bash
mlx_lm.server --model LiquidAI/LFM2.5-2.6B-MLX-8bit --host 127.0.0.1 --port 8080
# or, for the rapid-mlx stack:
rapid-mlx serve LiquidAI/LFM2.5-2.6B-MLX-8bit --port 8080 \
  --enable-auto-tool-choice --tool-call-parser lfm

ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_PROVIDER=local \
  ZTTP_CODEGEN_MODEL=LiquidAI/LFM2.5-2.6B-MLX-8bit \
  ZTTP_CODEGEN_LOCAL_RUNTIME=rapid-mlx@0.12.11 \
  zig build test-expert-app -Dtest-filter="record codegen baseline corpus"
```

`ZTTP_CODEGEN_LOCAL_RUNTIME` is only needed for a server that identifies
neither itself nor its version. MLX-LM names itself in every response
`system_fingerprint`, so a recording against it needs nothing. rapid-mlx sends
no fingerprint and serves no version endpoint, so the identity exists only in
the operator's shell, and the recorder refuses a malformed value rather than
guessing one.

Registered models: `LiquidAI/LFM2.5-2.6B-MLX-8bit` (default) and
`mlx-community/Qwen3-8B-4bit` (qualification candidate).

Artifacts: `packages/pi/src/simulator/testdata/empirical/local/codegen/`.

A failing local case is the measurement, not a reason to reach for a hosted
model. Use the qualification wrapper for a candidate comparison. Use recording
only when deliberately replacing a committed provider corpus.

### Claude

```bash
export ANTHROPIC_API_KEY=...
ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_PROVIDER=claude \
  zig build test-expert-app -Dtest-filter="record codegen baseline corpus"
```

Registered models: `claude-sonnet-4-6` (default), `claude-opus-4-8`,
`claude-sonnet-5`, and `claude-haiku-4-5-20251001`.

Artifacts: `packages/pi/src/simulator/testdata/empirical/codegen/`. The flat
pre-cutover cassettes under `packages/pi/src/providers/testdata/codegen/` are a
frozen baseline and are not re-recorded.

### OpenAI

```bash
export OPENAI_API_KEY=...
ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_PROVIDER=openai \
  zig build test-expert-app -Dtest-filter="record codegen baseline corpus"
```

Registered model: `gpt-4o-mini` (default). `ZTS_OPENAI_BASE_URL` may redirect
the Responses API transport without changing provider or model identity. The
off-registry `ZTS_OPENAI_MODEL` override is rejected; select a model with
`ZTTP_CODEGEN_MODEL`.

Artifacts: `packages/pi/src/simulator/testdata/empirical/openai/codegen/`.

## Which corpus this repository records

This is a project rule, not a limit of the harness. All four providers work.

DeepSeek is the one permitted remote provider and the headline. Local stays
available and is preferred for everything that does not need to move the
headline. The Claude and OpenAI corpora are pre-cutover baselines: they are
measured, not ratcheted, and are not re-recorded here.

## One case, or the whole corpus

`ZTTP_CODEGEN_ONLY=<name>` records a single case and leaves every other
cassette untouched. Use it when one case went stale for its own reason, such as
a compiler change that flipped its veto outcome.

A change to the persona or to any tool schema invalidates the whole corpus at
once, so that one needs a full run. Validate the pipeline first with
`ZTTP_CODEGEN_LIMIT=1` before spending a complete run.

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

Never edit the generated Markdown or JSON by hand. Commit the cassettes and the
regenerated pages together, from a clean tree: `update-convergence.sh` marks a
row `-dirty` when the working tree is not clean, and a number published from
uncommitted work cannot be reproduced from its commit.

## See also

- [Convergence](../convergence.md) - the published table and what a row means.
- [Coverage](../coverage.md) - which advertised rules the corpus trips.
- [Test Steps](testing.md) - what each `zig build test*` step runs.

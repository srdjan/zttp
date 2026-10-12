---
name: zttp-models
description: Use when running zttp expert against DeepSeek or a local MLX-LM server, or when recording or replaying the codegen corpus - provider selection, the default provider, recording locations, API keys, and the turn timeout.
---

# zttp model providers

Two providers exist here: DeepSeek and a developer-managed local MLX-LM server.
The Claude and OpenAI providers were removed; their code, corpora, and fixtures
live at the `pre-rebase` tag.

Start the local server yourself when you want it:

```bash
mlx_lm.server --model LiquidAI/LFM2.5-2.6B-MLX-8bit --host 127.0.0.1 --port 8080
```

`zttp expert --provider local` then selects it for a session, and
`ZTTP_CODEGEN_PROVIDER=local` selects it for recording, which is the recorder's
default when the variable is unset. Local recordings land under
`packages/pi/src/simulator/testdata/empirical/local/codegen/`.

DeepSeek is the one remote provider, added 2026-08-14 by explicit
decision. `--provider deepseek` runs the expert loop against it and
`ZTTP_CODEGEN_PROVIDER=deepseek` records a corpus into
`packages/pi/src/simulator/testdata/empirical/deepseek/codegen/`. Both need
`DEEPSEEK_API_KEY`. Handler source leaves the machine on a DeepSeek turn, which
the destination banner states before the first turn.

DeepSeek is also the headline since 2026-08-14: `models.default_provider` is
`.deepseek`, so a bare `zttp expert` uses `deepseek-v4-flash`, and
`headline_provider` derives from that same constant, so the ratchet and the
published convergence number describe the model a user actually gets. The move
waited on a complete 19-case corpus that replays 19/19 offline and a coverage
baseline measured from it rather than borrowed.

A DeepSeek turn is slower than a local one. `ZTTP_CODEGEN_TURN_TIMEOUT_MS`
defaults to 3 minutes, which truncates the heavier cases; the corpus was
recorded at 600000. A turn cut off by that ceiling can never replay, because the
replay finishes in milliseconds and asks for one more model call than the
recording holds, so the recorder now refuses to promote such a turn instead of
emitting an artifact that fails later as a false divergence.

The same ceiling exists because a stalled local generation is silence rather
than an error and would otherwise take the whole corpus run with it. A failing
local case is the measurement, not a reason to reach for a hosted model.

# InvalidChangeSetArgs: make it diagnosable before deciding anything else

Status: both diagnosis steps landed 2026-08-17. Step 1 named the shape; step 2
keeps the body. Step 3 - choosing a fix - waits on an observed occurrence.

## Why it matters

One occurrence sinks a whole recording. Promotion needs 19/19 applied and 19/19
intent with zero failures, so a single rejected proposal ends a run that is
otherwise complete - which is what happened to run 6, where it was one of only
three failures and the other two were a network timeout and one real model
failure.

Occurrences, counted from the six full-run logs: **3 of 6 runs**, a different
case each time.

| run | case |
|---|---|
| 1 | `workflow-nested-dispatch-avoidance` |
| 3 | `parallel-secret` |
| 6 | `workflow-saga-compensation` |

Runs 2, 4 and 5 were clean. Measured base rate across seven run directories:
3 failures in 1,071 attempts, about 0.28% per attempt. At roughly 150 attempts
per run that is a ~66% chance of a clean run, which matches 4 of 7 observed.

## Truncation is ruled out, conclusively

This was the leading hypothesis and it is wrong. Truncation is classified before
`maybeRemap` ever runs: `packages/pi/src/providers/deepseek/client.zig:546` maps
`finish_reason == "length"` to `OutputTruncated`. The `"max_tokens"` check inside
`remapFailure` (`propose_change_set.zig:23`) is Anthropic-shaped and dead on the
DeepSeek path.

The three failing attempts, read from the metadata diagnostics:

| case | finish_reason | completion_tokens | largest successful attempt in the same case |
|---|---|---|---|
| `workflow-nested-dispatch-avoidance` | `tool_calls` | 652 | 6,677 |
| `parallel-secret` | `tool_calls` | 2,582 | 4,719 |
| `workflow-saga-compensation` | `tool_calls` | 5,674 | 11,160 |

Every failure is a complete response, far under the 32,768 request cap
(`models.zig:125`), and **smaller** than successful attempts in its own case. It
is not truncation and it is not size.

## The actual finding: the failure destroys its own evidence

`maybeRemap` collapses ten distinct rejections into one error
(`propose_change_set.zig:41-58`): an extra key beside `file`/`content`, an extra
top-level key, a duplicate key, a host-authoritative key, a non-string `file`,
an empty `file`, an empty or oversized `changes`, and more. Two shapes can be
excluded - multiple tool calls returns unmapped rather than erroring (line 35),
and truncation is ruled out above. The rest are indistinguishable.

And the body that would settle it is gone. The diagnostics record is
metadata-only by design - `capture_sink.zig:59-61` says it "intentionally
excludes prompts, response content, reasoning, tool arguments" - and the capture
itself refused the response, so no cassette holds it either. The artifact that
explains the failure is destroyed at the moment of failure.

**So no fix can be chosen yet.** Any change beyond diagnosis would be guessing at
which of eight shapes fires.

## Recommendation

Two steps, in order, and nothing else until the first has caught one occurrence.

### 1. Name the rejection shape

Split `remapFailure` into named reasons and carry the reason - an enum tag only,
no content - into the metadata diagnostics beside `error_name`. Touches
`propose_change_set.zig`, the client diagnostic plumbing, and `capture_sink.zig`.
Preserves the metadata-only guarantee exactly.

### 2. Keep the rejected body, capture-side only

On a capture-side rejection, write the sanitized body into the run's existing
quarantine staging directory. This is not a privacy regression: the same bytes
would have been written to a cassette had they validated, and the staging tree
already holds every accepted response. It is what makes the next occurrence
explainable rather than another statistic.

Then decide retry-versus-feedback from one observed body.

**Landed, at the second attempt.** The body goes to
`.zig-cache/codegen-record-diagnostics/<run>/<case>.rejected-call-<n>.json`,
beside the metadata rows rather than in the staging tree, because the staging
tree is swapped wholesale on promotion and a failed run never promotes. The file
is a self-contained envelope: refusal shape, error name, call index and bytes
together.

The first attempt instrumented the wrong branch and cost a run to find out.
`sendTurn` captures before it decodes, and the capture pre-decodes the same
bytes through `cassette_client.replay` to prove the cassette will replay - so a
refused proposal fails at capture, and the client's own decode, which was the
branch carrying both the shape and the quarantine, is never reached. The next
full run sank on two occurrences (`sql-users`, `parallel-secret`) and reported
`change_set_rejection: null` with no body for both. The single diagnostic that
identified this was `parser_warnings: ["capture_rejected_response"]` in those
rows.

The write now lives in `recordModelExchange`, which is where the refusal
actually happens and the only place the bytes still exist. `replayObserved`
carries the shape out, and the recorder retains it so the diagnostics row the
client writes for the same failure can name it too - the client cannot see a
refusal that happened inside the capture call it made. It fires for any
capture-side decode refusal, not only a change-set one, because they all destroy
their evidence the same way.

## Explicitly not doing

**Not retrying in the recorder.** `RecorderModelClient.request` retries only
transport failures (`expert_codegen_record.zig:2131-2148`), pinned by a test at
2218. A malformed proposal is bytes the model chose, and a silent retry that
overwrites the failed call would make replay show a model that never slips -
re-rolling, which `docs/convergence.md:582` forbids.

**Not reclassifying as truncation.** The evidence above refutes it.

**Not loosening `maybeRemap`.** It guards host-authoritative fields; the
empty-baseline incident in `docs/solutions/logic-errors/` is what that guard
exists for.

**Not adding a model-feedback turn yet.** This is the most interesting option and
probably the right end state: the interactive product already survives this
error - `loop.zig:159`'s remediation is display-only (`repl.zig:849`,
`print_mode.zig:180`) and tells the user to "Retry the ask" - so the recorder is
currently stricter than the shipped product. Feeding the rejection back as a
tool-error turn the model corrects, recorded in the cassette and reproduced at
replay, would close that asymmetry without re-rolling. But it is a turn-machine
change, and it should not be built on an undiagnosed failure.

## Success criteria

1. The next occurrence names its shape in the diagnostics.
2. The rejected body is on disk for that occurrence.
3. Only then: a fix chosen against an observed body rather than a hypothesis.

Note that criterion 1 may take several runs to trigger at a 0.28% per-attempt
rate. That is acceptable - the alternative is guessing now.

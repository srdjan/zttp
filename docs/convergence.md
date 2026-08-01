# Convergence

[STRATEGY.md](../STRATEGY.md) claims that the set of programs the agent can
write should converge on the set of programs the compiler can prove. This page
is the measurement of that claim, so the claim has an answer when someone asks
for one.

The headline figure is **first-draft veto-pass rate**: how often the model's
first attempt at a prompt clears the compiler veto with no retries. It is a
counted result over a frozen corpus, not an estimate.

## Results

| Recorded | Corpus | Cases | Model | Policy | First-draft pass | Median round-trips | Intent pass |
|---|---|---|---|---|---|---|---|
| 2026-08-01 | `b28a83a531db` | 11 | claude-sonnet-4-6 | `37a115c262dc` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-01 | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |

Regenerate with `bash scripts/update-convergence.sh`, which appends a row and
rewrites [convergence.json](convergence.json). History is git history on those
two files.

## Reading the table

**Corpus** is the first twelve characters of a hash over the whole corpus:
every prompt, seed file, pinned outcome, and intent spec. Editing any case
changes it by construction, so two rows carrying different corpus versions are
measuring different things and must not be compared. A hand-maintained version
number would have rotted the first time somebody reworded a prompt.

**Policy** is the compiler's rule hash, the same one `policy-hash.txt` pins.
The fence moves: a new rule can lower the pass rate without the model getting
worse, and a precision fix can raise it without the model getting better. A row
without this column would attribute both to the model.

**Model** is the product default, so the number describes what a user actually
gets rather than a tier picked to flatter the result. It is derived from
`request.default_model` rather than written down separately, so the two cannot
drift.

**First-draft pass** is the headline. Retries are excluded on purpose: a rate
that counted them would measure the retry loop's persistence, not the agent's
aim, and every retry loop eventually passes a linter.

**Median round-trips** is what a typical prompt costs to reach green. The
median rather than the mean, so one case that never converges does not set the
number for the other ten.

**Intent pass** is the rate over cases that carry an intent spec, and the
denominator is those cases, not the whole corpus. The veto answers whether a
program is provable; it cannot answer whether the program does what was asked,
and a handler that returns `{ok: true}` for every prompt clears the veto every
time. Without this column the headline could not distinguish converging on
provable from converging on trivial.

## What is not measured yet

Five of the eleven cases - the durable and workflow ones - carry no intent
spec. Executing them needs the durable store and queue the runtime stands up,
and `zttp test` has no offline story for either: `saga()` fails with
`NativeFunctionError` before any assertion runs, and an io stub does not
intercept it. Those cases are veto-checked but not intent-checked, which is why
the intent column reads over 6 rather than over 11. Giving the test runner a
durable backend would close it.

One case, `validate-body`, is pinned as an accepted failure. It is a real
corpus entry, not a broken test: it feeds the gap histogram that ranks which
teaching gap to close next, and the pinned outcome is part of the corpus
version so quietly flipping it would change what the rate means.

## How a run works

The corpus lives in `packages/pi/src/expert_codegen_record.zig`. It has two
modes.

Recording is live and costs tokens. `ZTTP_CODEGEN_RECORD=1` with an API key
drives real expert turns through the real tool registry and tees each
round-trip to a per-case cassette, which is then committed.

Replay is deterministic and free. It reads the committed cassettes and re-runs
the recorded tool calls through the real veto, the real apply path, and the
real metrics. This is what CI runs and what the table above reports. The
replay is also a ratchet: it fails if a compiler change flips a recorded
first-draft outcome, so the rate cannot drift without somebody noticing.

The intent check shells out to the built `zttp test` rather than driving the
engine directly, so it exercises the same runtime a user does instead of a
second copy of it.

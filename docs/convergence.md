# Convergence

[STRATEGY.md](../STRATEGY.md) claims that the set of programs the agent can
write should converge on the set of programs the compiler can prove. This page
is the measurement of that claim, so the claim has an answer when someone asks
for one.

The headline figure is **first-draft veto-pass rate**: how often the model's
first attempt at a prompt clears the compiler veto with no retries. It is a
counted result over a frozen corpus, not an estimate.

## Results

| Recorded | Commit | Corpus | Cases | Model | Policy | First-draft pass | Median round-trips | Intent pass |
|---|---|---|---|---|---|---|---|---|
| 2026-08-01 | `e4a13aee` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `37a115c262dc` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-01 | `847840a4-dirty` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-02 | `57269997` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-02 | `79e9fc86` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-02 | `845025e7` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-02 | `2db4545c` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |

Regenerate with `bash scripts/update-convergence.sh`, which appends a row and
rewrites [convergence.json](convergence.json). History is git history on those
two files.

The last five rows share a corpus and a policy hash and differ only by build.
Between the second and the third, the flow checker stopped proving through
three fail-opens - a call it could not enter, and two shapes of egress options
object it could not read field by field - and gained the ability to walk a
helper imported from a sibling file. The fourth adds one more: a closure passed
as an argument now carries the labels of the value it produces, so a secret
returned from a `map` callback no longer reaches the response unlabelled.

The fifth carries one of each. A callback a module invokes now carries what it
returns out of that module, closing the last of the fail-opens: a module export
answers with its declared return labels, and those cannot describe what a
caller's callback produced, so `parallel([() => env("SECRET_KEY")])` had still
been proving clean. Alongside it, `deterministic` moved from answering whether a
varying value was read to whether one reaches the response, so a handler that
logs a timestamp and returns a constant keeps the property and keeps
`idempotent` with it. That second change is a loosening: strictly more programs
prove than before.

The sixth is a tightening that a precision change forced into the open. The
per-export capability rows reached `zttp:cache` and `zttp:service`, and taking
the clock off `cacheStats` - which sums counters and reads no clock - flipped a
golden fixture's `deterministic` from false to true. The verdict had been right
for an accidental reason: the varying-value label was read off the capability
set, and the module-level `.clock` happened to cover a call returning live
counters. `zttp:sql` declares no clock at all, so the same rule had been proving
`deterministic` for a handler returning database rows. A read from mutable
module state is now its own varying source, which no capability set can express.

None of it adds a rule, so the policy hash cannot separate these rows and the
commit column is what does. The rate held at 90% throughout - six tightenings
and one loosening, and this corpus felt none of them. The replay is a ratchet,
failing if a compiler change flips a recorded first-draft outcome, so that is a
checked result rather than a quiet one. What it also says is that eleven cases
are too few to see a fence move: none of them logs a timestamp, none returns a
row it read from a store, and none writes the shapes the fail-opens hid behind.

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

**Commit** is the build the row was produced from, and it is the column that
covers what the policy hash cannot. The hash is over the rule registry, so a
change to analysis semantics that adds no rule leaves it identical - the
determinism fix that stopped `uuid()` proving `deterministic` moved neither the
policy hash nor the hand-bumped compiler version. Two rows that differ only by
such a fix would otherwise look like the same build measured twice. A row marked
`-dirty` was published from uncommitted work and cannot be reproduced from the
commit alone.

The first two rows are retrofitted: the column was added after they were
published, and each names the commit the run's tree became - `e4a13aee` and
`847840a4`, the two commits git shows touching this file. Both runs were made
from a dirty tree that was committed immediately after, which is why the second
carries the marker. Rows from here on are stamped by the script rather than
reconstructed.

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

One case, `validate-body`, is pinned as an accepted failure, and it is the
reason the rate reads 10/11 rather than 11/11. Its first draft writes
`result.value as Item`, and the subset has no `as`, so the stripper rejects it
(ZTS042). The case still reaches green - the model drops the assertion on retry
- so this is a first-draft failure rather than a broken case.

It is a real corpus entry: it feeds the gap histogram that ranks which teaching
gap to close next, and the pinned outcome is part of the corpus version, so
quietly flipping it would change what the rate means.

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

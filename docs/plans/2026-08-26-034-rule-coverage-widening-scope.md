# Rule coverage widening: scope before spend

Status: scoping only, not started. Written 2026-08-26. No model calls were made
to produce it.

`docs/coverage.md` reports that of the compiler's 72 advertised rules, 2 are
tripped by at least one corpus case. This document says what would change that,
what each option costs, and which of the 70 untripped rules each option reaches.
It proposes no recording run. It exists so that the next one is aimed.

Revised 2026-08-26 after that day's re-record moved the number from 5 to 2. The
revision is not a correction: the count fell because a fresh recording of the
same frozen prompts tripped fewer rules, which is the single most useful thing
this document now says. See "The number is unstable" below.

## What the number counts

A rule counts as tripped when its code appears in a diagnostic box or a
diagnostic tool result inside a recorded cassette transcript
(`expert_codegen_eval.collectCodes`). The count is therefore not "rules the
compiler can enforce" and not "rules a handler can violate". It is "rules the
compiler reported to a model during a recorded session".

That mechanism has a consequence worth stating plainly, because it changes what
kind of work this is. Coverage is reached through the compiler's report, not
through the model's draft. A case whose `seed_files` already contain the
violating construct produces the diagnostic the moment the workspace is checked,
whichever way the model then chooses to write the fix. Coverage is therefore
designable rather than a bet on model habit.

This has not been verified end to end. The claim rests on reading
`collectCodes`, and the step it does not cover is whether a seeded file's
diagnostics reach the transcript in `whole_file` mode without the model choosing
to ask. That is checkable against the stand-in with no API key and no spend, and
it is the first task below for exactly that reason.

The two tripped rules today are `ZTS400` and `ZTS500`.

## The number is unstable

Three recordings of the *same* frozen prompt set, same provider, same model,
have now measured three different coverage numbers. Read from
`git log docs/coverage.json`:

| recorded | tripped | codes |
|---|---|---|
| 2026-08-17 | 4 | `ZTS400` `ZTS500` `ZTS501` `ZTS509` |
| 2026-08-25 | 5 | `ZTS400` `ZTS500` `ZTS501` `ZTS502` `ZTS509` |
| 2026-08-26 | 2 | `ZTS400` `ZTS500` |

The headline input identity is `0012ad8ca6d5` in all three, so nothing about the
prompts, the seeds, or the compiler moved. Five distinct codes appear across the
three runs and only two appear in all of them.

Note the shape: 4, then 5, then 2. This is not a number that has been sliding
and it is not a regression to explain away - it is not monotone at all, because
a rule is counted when the model happens to make the mistake that trips it. The
count measures draft quality inversely, and the 2026-08-26 run also produced the
best intent rate of the three, at 94%.

(An earlier five, recorded 2026-08-16, is excluded above: it was measured over
corpus `19dc67a54ec3`, a different prompt set, so it is not a sample of the same
thing.)

Two consequences, and they are the reason this document exists.

A coverage number taken from one recording is a sample, not a property of the
corpus, and the honest denominator for "what does the corpus exercise" is the
union across runs rather than any single row. Nothing currently computes that
union.

More importantly, the three codes that flicker - `ZTS501`, `ZTS502`, `ZTS509` -
are *proof* that the existing prompts can reach them. No argument is needed about
whether a model would write the violation; one already did, twice. They are the
strongest available case for the seeded approach in step 1: a case that seeds the
violating construct trips its rule every run, turning three codes that currently
come and go into three that hold.

## The 70 untripped rules, partitioned

The partition is by what a case would have to supply, not by rule family. Every
untripped code appears exactly once; the four groups sum to 70.

### Group 0: demonstrated reachable by an earlier recording (3)

`ZTS501` `ZTS502` `ZTS509`

Untripped only as of the 2026-08-26 recording. Each was tripped by at least one
earlier recording of these same prompts, so no new prompt is needed to reach
them. A seeded case would make them hold every run rather than come and go.

### Group A: reachable from a prompt or a seed alone (30)

Nothing new is needed beyond a case. These are constructs a model writes from
ordinary TypeScript habit, or defects a seed file can carry directly.

Canonical profile, 12: `ZTS604` `ZTS608` `ZTS609` `ZTS612` `ZTS621` `ZTS613`
`ZTS614` `ZTS616` `ZTS620` `ZTS624` `ZTS625` `ZTS626`

Types and annotations, 6: `ZTS600` `ZTS601` `ZTS602` `ZTS603` `ZTS605` `ZTS629`

Verification and correctness, 12: `ZTS300` `ZTS301` `ZTS302` `ZTS303` `ZTS304`
`ZTS305` `ZTS306` `ZTS307` `ZTS308` `ZTS309` `ZTS310` `ZTS622`

The canonical-profile twelve deserve their own note. They are exactly the rules
the `canonical-style` skill teaches, and the corpus trips none of them. That is
not a coincidence and it is not harmless: the skill's ZTS612 section carried a
wrong example for as long as it did because no recorded session ever produced a
ZTS612 diagnostic to contradict it. A documentation gate now covers that class
(`scripts/check-canonical-style.sh`), but the gate compares the skill to the
registry. It cannot tell anyone whether the rule fires.

### Group B: reachable, but needs a task shape the corpus does not have (27)

The rule fires on code no current prompt asks anyone to write.

Flow labels and properties, 13: `ZTS401` `ZTS402` `ZTS403` `ZTS404` `ZTS405`
`ZTS406` `ZTS407` `PROP01` `PROP02` `PROP03` `PROP04` `PROP05` `PROP06`

These need a handler that carries a secret, a credential, or unvalidated user
input near a sink. `ZTS400` already trips, so the shape is proven; the other
six sinks are separate prompts, not a wider version of the same one.

Effects and Proof, 11: `ZTS061` `ZTS503` `ZTS504` `ZTS506` `ZTS511` `ZTS512`
`ZTS606` `ZTS607` `ZTS610` `ZTS611` `ZTS623`

These need prompts that ask for declared `Effects<...>` ceilings and `Proof<...>`
capsules on helpers, which no current case does. `ZTS505` is excluded here and
appears in group C for a different reason.

Dictionary and workflow idioms, 3: `ZTS510` `ZTS627` `ZTS628`

`ZTS510` needs a `saga([...])` whose non-last step omits `compensate`. The two
dictionary rules need an entry round trip through `dictEntries` and
`dictFromEntries`.

### Group C: needs configuration or a non-default mode (10)

Policy, 8: `POL001` `POL002` `POL003` `POL004` `POL005` `POL006` `POL007`
`POL008`

Every one of these compares handler behavior against an allow-list that only
exists when `zttp.json` carries a `policy` object with `env`, `egress`, `cache`,
or `sql` arrays (`policy.zig`). No corpus case seeds one. A case can: the
`sql-users` case already seeds `zttp.json`, so the machinery is present and only
the content is missing. Eight rules for what is plausibly two cases, one static
and one dynamic-access, is the best ratio on this page.

Docs mode, 1: `ZTS508` is emitted only under the opt-in docs mode. Reaching it
means recording a case under a non-default mode, which is a change to how a case
is run rather than to what it asks for.

Advisory, 1: `ZTS505` never fails a build. Whether it can be counted at all
depends on whether an advisory reaches the transcript, which is unverified.

## Two levers, and what each costs

**Lever 1: an offline per-rule firing suite.** No such suite exists. Nothing in
the repository asserts that each of the 72 registry rules fires on a handler that
violates it; `PolicyCatalog.rules()` is iterated in exactly two places, both
inside the coverage counter itself. A fixture per rule, checked offline, would
prove the enforcement claim the coverage page is currently read as making. It
needs no API key, no recording, and no model. It does not move the published
coverage number and should not: that number is about the corpus, and this suite
is about the compiler. Both claims are worth having, and conflating them is what
makes 5 of 72 read as worse than it is.

**Lever 2: new corpus cases.** This moves the published number and requires
recording. `docs/plans/2026-08-17-033-corpus-recording-campaign.md` measures a
full run at roughly 24 minutes of wall clock plus a DeepSeek spend, and handler
source leaves the machine on every turn. Adding cases changes `corpusVersion`,
so it is a whole-corpus re-record, not an incremental one.

## Proposed sequence

1. Verify the seeding mechanism against the stand-in: does a `seed_files`
   diagnostic reach the transcript in `whole_file` mode? Free, no model. Every
   estimate below depends on the answer, and if it is no, groups A and C shrink
   to whatever a prompt can coax out of a model and this plan needs rewriting.
2. Build the offline per-rule firing suite (lever 1). Independent of the answer
   to step 1, and it is the artifact that separates "the compiler enforces this"
   from "the corpus exercised this".
3. Draft candidate cases for group C's policy eight and group A's canonical
   twelve, and dry-run them against the stand-in. Still free. This is where the
   case count per rule stops being a guess.
4. Only then decide how many cases to add, and fold the recording into the same
   session that lands the parked `verifiers-fields-pending-record` branch, so one
   run pays for both.

## What is measured and what is not

Measured: the 72-rule denominator and the 2-rule numerator are read from
`docs/coverage.json`, generated from corpus `0012ad8ca6d5`. The three-run
history in "The number is unstable" is read from the coverage pages and the
baseline comment in `expert_codegen_record.zig`, each of which was generated
from its own recording. The partition above
was computed against the registry rather than counted by hand, and every code
appears exactly once. The absence of a per-rule firing suite was established by
search. The policy configuration shape was read from `policy.zig`. The 24-minute
run figure is quoted from plan 033, not re-measured here.

Not measured: how many cases each group needs, what a case costs to author, and
whether a seeded diagnostic reaches the transcript. Step 1 above exists to close
the last of those, and steps 2 and 3 exist to close the first two before anyone
commits to a number.

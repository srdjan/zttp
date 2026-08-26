# Rule coverage widening: scope before spend

Status: scoping only, not started. Written 2026-08-26. No model calls were made
to produce it.

`docs/coverage.md` reports that of the compiler's 72 advertised rules, 2 are
tripped by at least one corpus case. This document says what would change that,
what each option costs, and which of the 70 untripped rules each option reaches.
It proposes no recording run. It exists so that the next one is aimed.

Revised twice on 2026-08-26. First after that day's re-record moved the number
from 5 to 2 - not a correction, but the count falling because a fresh recording
of the same frozen prompts tripped fewer rules, which is the single most useful
thing this document now says. See "The number is unstable" below.

Then a correction, and a load-bearing one: the first draft claimed a case could
guarantee its rule by seeding the violating construct. It cannot. That claim was
this document's central proposal, and refuting it moved the recommended work
from new corpus cases to extending the defect-seed suite. Both the wrong claim
and the check that killed it are kept below.

## What the number counts

A rule counts as tripped when its code appears in a diagnostic box or a
diagnostic tool result inside a recorded cassette transcript
(`expert_codegen_eval.collectCodes`). The count is therefore not "rules the
compiler can enforce" and not "rules a handler can violate". It is "rules the
compiler reported to a model during a recorded session".

An earlier draft of this document argued that a case whose `seed_files` carry
the violating construct would produce the diagnostic whichever way the model
wrote the fix, making coverage designable rather than a bet on model habit.
**That is false, and the check that settles it is below.** It is left here
rather than quietly deleted because it is the obvious idea and the next reader
will have it too.

The veto is differential. `aggregate_proof.firstNewDiagnostic` is a multiset
comparison of candidate diagnostics against a baseline materialized from the
same workspace, so a diagnostic the seed already carried has equal counts on
both sides and is never new. `standin/defect_seeds.zig` documents exactly this
in its own header, as the reason its seed sources must be veto-clean: "a seed
that already carried its own defect would make the defect pre-existing, the bad
draft would pass, and the arm would test nothing while reporting a clean run."
`sibling-helper`, the one corpus case that seeds a file, seeds a clean one - its
codes come from what the model drafts against it.

`collectCodes` accepts a code from three places, and `isDiagnosticResult` names
them: a `zts_expert_review_patch` result, a `zts_check` result, or a failed
`propose_change_set` carrying the veto reject preamble. The first two happen
when the model chooses to ask. The third requires a new diagnostic, which
requires the model to write one.

So every path to a counted code runs through model behaviour. Published coverage
cannot be designed. It can be nudged - a prompt can invite the mistake - and it
can be measured, but a case cannot guarantee its rule.

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
whether a model would write the violation; one already did. Since seeding cannot
pin them, they are instead the clearest example of why the published number needs
a companion that does not depend on a draw - which is lever 1 below.

## The 70 untripped rules, partitioned

The partition is by what a case would have to supply, not by rule family. Every
untripped code appears exactly once; the four groups sum to 70.

### Group 0: demonstrated reachable by an earlier recording (3)

`ZTS501` `ZTS502` `ZTS509`

Untripped only as of the 2026-08-26 recording. Each was tripped by at least one
earlier recording of these same prompts, so no new prompt is needed to reach
them - only a draw that makes the mistake again. Nothing a case can supply will
pin them, which is the whole argument for lever 1.

### Group A: reachable from an ordinary prompt (30)

Nothing new is needed beyond a case whose task invites the construct. These are
things a model writes from ordinary TypeScript habit. Whether any given
recording trips them remains a draw.

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

**Lever 1: extend the defect-seed suite toward per-rule coverage.** This is the
lever, and it already exists in miniature. `packages/pi/src/standin/defect_seeds.zig`
pairs a veto-clean `seed_source` with a `bad_draft` that introduces exactly one
code, and `standin_range_tests.zig` re-derives each seed's class by running the
real veto rather than trusting the declaration. Running `zig build test-standin`
reports it:

```
[standin-gate] defect seeds 6; 5 carry a registry code, 1 do not
[standin-gate] veto classes 6/6 seeds reproduce their declaration
```

Those five are `ZTS303`, `ZTS304`, `ZTS308`, `ZTS604` and `ZTS613` - all of them
in the untripped list below. Five registry rules already have deterministic
offline evidence that they fire; it simply is not the evidence the coverage page
reports, because `replayCorpusTurn` counts only the 19 cassettes.

So the work is extending a working pattern from 6 seeds toward 72, not inventing
a suite. It needs no API key, no recording, and no model. It does not move the
published coverage number and should not: that number is about the corpus, and
this suite is about the compiler. Both claims are worth having, and conflating
them is what makes 2 of 72 read as worse than it is.

The honest ceiling on this lever is worth naming: a defect seed proves a rule
fires on a draft the harness supplies, which is a statement about the compiler
and the veto. It says nothing about whether a model would ever write that
draft. That is the other claim, and only lever 2 measures it.

**Lever 2: new corpus cases.** This moves the published number and requires
recording. `docs/plans/2026-08-17-033-corpus-recording-campaign.md` measures a
full run at roughly 24 minutes of wall clock plus a DeepSeek spend, and handler
source leaves the machine on every turn. Adding cases changes `corpusVersion`,
so it is a whole-corpus re-record, not an incremental one.

## Proposed sequence

Step 1 as originally written - verify whether a seeded diagnostic reaches the
transcript - is done, and the answer was no. It is recorded above rather than
removed, because the negative result is what reshaped the rest of this list.

1. Extend `defect_seeds.zig` past its current six, starting with the twelve
   canonical-profile codes in group A. Two are already covered (`ZTS604`,
   `ZTS613`), so the pattern is proven on exactly this family. Free, no model.
   The existing gate re-derives every class from the real veto, so each new seed
   is checked rather than declared.
2. Publish that suite's count as its own figure, separate from corpus coverage,
   and say in `docs/coverage.md` which question each answers. The current page
   invites one number to be read as both.
3. Compute the union of tripped codes across recordings of one corpus identity.
   Three runs of `0012ad8ca6d5` give 5 where any single row gives 2 to 5.
   Nothing computes this today, and it is the fairer answer to "what does the
   corpus exercise".
4. Only then consider new corpus cases. Group C's policy eight is still the best
   ratio - eight rules for plausibly two cases - and remains a nudge rather than
   a guarantee. Fold any recording into a session that has another reason to
   run.

## What is measured and what is not

Measured: the 72-rule denominator and the 2-rule numerator are read from
`docs/coverage.json`, generated from corpus `0012ad8ca6d5`. The three-run
history in "The number is unstable" is read from the coverage pages and the
baseline comment in `expert_codegen_record.zig`, each of which was generated
from its own recording. The partition above
was computed against the registry rather than counted by hand, and every code
appears exactly once. That a seeded diagnostic does not reach the transcript was
established from `firstNewDiagnostic`, the `defect_seeds.zig` header, and
`sibling-helper`'s clean seed, three independent confirmations. The defect-seed
counts are quoted from a `zig build test-standin` run, not from reading the
file. The policy configuration shape was read from `policy.zig`. The 24-minute
run figure is quoted from plan 033, not re-measured here.

Not measured: how many seeds or cases each group needs, and what one costs to
author. Step 1 above is the cheapest way to find out, because the first few new
defect seeds will price the rest.

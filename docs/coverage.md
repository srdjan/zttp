<!-- Generated file. Do not edit. Run `bash scripts/update-coverage.sh` to regenerate it. -->

# Coverage

What the offline suite proves, and what it does not.

> The offline suite proves two things. The harness is faithful: recorder capture
> and replay, the loop, veto, apply, retry, salvage, compiler repair, and the
> hole loop execute correctly over their declared fixtures. And the
> corpus is load-bearing: of the compiler's 59 advertised rules,
> 3 are tripped by at least one case. It proves nothing about what a
> model will draft. Raw first-draft pass, first-attempt green, median
> round-trips, and intent pass
> exist only as recordings of a live model, an offline run is structurally unable
> to produce or update them, and any figure of that shape that does not carry a
> cassette-derived model column is a defect in
> [convergence.md](convergence.md).

## What runs with no API key

| Path | Offline | How |
|---|---|---|
| Recorder transport and replay | yes | a loopback Anthropic SSE response passes through the production record tee, disk cassette, loader, and replay client |
| Loop, veto, apply | yes | every entry in the declared range, driven through the real server and the real loop |
| Veto retry | yes | defect seeds whose bad draft the veto rejects and whose good draft lands on the retry |
| Salvage-on-reject | yes | canonical-band seeds, asserted against the exact bytes normalizing the draft produces |
| Compiler-authored repair lane | yes | two repairable defect seeds land a verified compiler candidate with no model retry |
| Hole publisher and fill | yes | the in-process compiler publishes the frame, then `zts_expert_fill_hole` proposes one exact-site replacement |
| Multi-turn hole loop | yes | a two-hole seed applies one fill per turn, republishes the changed frame, and finishes with both fills composed |

Only model behavior stays live-only. Creating a new empirical cassette and
publishing first-draft, intent, or round-trip measurements still requires the
named model. Developing and verifying the harness, veto, salvage, repair, and
hole-loop machinery does not.

Recorded 2026-08-27 over corpus `0012ad8ca6d5`. The replay fails
when this page drifts from the run, so it is regenerated in the same commit as
whatever moved it, and `git log docs/coverage.json` is the history.

## Rule coverage

| Rules advertised | Tripped by at least one case | Untripped |
|---|---|---|
| 59 | 3 | 56 |

Tripped: `ZTS400`, `ZTS500`, `ZTS501`

The list above is a fair description of what these prompts ask for and a poor
description of what the compiler proves. It is the mechanical form of an
argument [convergence.md](convergence.md) had been making in prose: a fence no
case stands on cannot move a published number, and nine consecutive rows reading
90% over one corpus is what that looks like from outside.

The previous sentence here counted the tripped rules by family in prose, and it
was wrong the first time the count moved. Nothing in this section restates a
number the generator computes; the codes are printed, and a reader who wants the
breakdown reads them.

Untripped: `ZTS302`, `ZTS303`, `ZTS304`, `ZTS305`, `ZTS306`, `ZTS308`, `ZTS309`, `ZTS310`, `ZTS502`, `ZTS600`, `ZTS629`, `ZTS601`, `ZTS061`, `ZTS602`, `ZTS603`, `ZTS604`, `ZTS605`, `ZTS608`, `ZTS609`, `ZTS610`, `ZTS623`, `ZTS611`, `ZTS612`, `ZTS621`, `ZTS613`, `ZTS614`, `ZTS616`, `ZTS620`, `ZTS622`, `ZTS625`, `ZTS626`, `ZTS627`, `ZTS628`, `ZTS624`, `ZTS606`, `ZTS503`, `ZTS504`, `ZTS505`, `ZTS506`, `ZTS508`, `ZTS607`, `ZTS509`, `ZTS510`, `ZTS511`, `ZTS512`, `POL001`, `POL003`, `POL005`, `POL007`, `ZTS401`, `ZTS402`, `ZTS403`, `ZTS404`, `ZTS405`, `ZTS406`, `ZTS407`

## What this corpus has ever reached

The row above is one draw. The same prompts, seeds, provider, model and
compiler have measured a different set each time they were recorded, because a
rule is counted only when the model happens to make the mistake that trips it.
Across the 14 published runs of corpus `0012ad8ca6d5`, the
tripped set took 5 distinct shapes, the smallest naming
2 rules and the largest 5.

| Union across runs | Smallest single run | Largest single run |
|---|---|---|
| 6 | 2 | 5 |

Ever tripped: `ZTS400`, `ZTS500`, `ZTS501`, `ZTS502`, `ZTS506`, `ZTS509`

This is the fairer answer to "what do these prompts reach", and no single row
can give it. It is computed by `scripts/coverage-union.sh` from
`git log docs/coverage.json`, which is this page's own history; a shallow clone
is refused rather than published as a complete union.

It still measures the model, not the compiler. A rule absent here is one no
recorded draft has ever violated, which is not the same as one the compiler
would let pass - that is the next section.

## Rules observed firing at all

A different question, kept on its own so the two are not read as one figure.
The section above counts rules a recorded model's drafts happened to trip. This
one counts rules the compiler was *observed* rejecting, from the defect-seed
suite in `packages/pi/src/standin/defect_seeds.zig`: each seed pairs a
veto-clean baseline with a draft that introduces exactly one code, and the
stand-in gate re-derives the outcome through the real veto before this number
is printed.

| Rules advertised | Verified firing by a seed | Seeds |
|---|---|---|
| 59 | 58 | 59 |

Verified: `POL001`, `POL003`, `POL005`, `POL007`, `ZTS061`, `ZTS302`, `ZTS303`, `ZTS304`, `ZTS305`, `ZTS306`, `ZTS308`, `ZTS309`, `ZTS310`, `ZTS400`, `ZTS401`, `ZTS402`, `ZTS403`, `ZTS404`, `ZTS405`, `ZTS406`, `ZTS407`, `ZTS500`, `ZTS501`, `ZTS502`, `ZTS503`, `ZTS504`, `ZTS505`, `ZTS506`, `ZTS509`, `ZTS510`, `ZTS511`, `ZTS512`, `ZTS600`, `ZTS601`, `ZTS602`, `ZTS603`, `ZTS604`, `ZTS605`, `ZTS606`, `ZTS607`, `ZTS608`, `ZTS609`, `ZTS610`, `ZTS611`, `ZTS612`, `ZTS613`, `ZTS614`, `ZTS616`, `ZTS620`, `ZTS621`, `ZTS622`, `ZTS623`, `ZTS624`, `ZTS625`, `ZTS626`, `ZTS627`, `ZTS628`, `ZTS629`

No model is involved, so this figure does not move when a recording draws
differently. It also proves less: a seed shows the compiler rejects a draft the
harness supplied, and says nothing about whether a model would ever write one.
That is the question the section above answers, and only a recording can.

Neither number bounds the other. The corpus leaves 55 of the rules
verified here untripped; it trips 0 that no seed covers; and the two
sets share 3. Together they name 58 of the 59
advertised rules, and taking the corpus union above instead of this single run
raises that to 58 - the closest thing to a combined answer this
repository can produce, and still two claims added up rather than one
measurement.

## The rules no seed reaches

One advertised rule of 59 is not verified by a seed: `ZTS508`, because it is
`non-default`. Emitted only under an opt-in mode the veto does not run.

Nothing here is waiting on a seed. The registry once advertised codes no
code path could construct; those were deleted rather than seeded, which is
why this section is now one line instead of a table of seventeen.

The rows live in `scripts/unseeded-rules.allow` with the probe behind each one.
The stand-in gate enforces the list in both directions: an advertised rule that
is neither seeded nor listed fails, and so does a row for a code a seed has
since covered. Neither list can drift from the registry without failing a build.

## Codes the registry does not carry

`ZTS001`, `ZTS202`, `ZTS214`

These are real diagnostics the corpus trips that no `rule_registry` entry
carries - the parser, stripper, bool-checker, and type-checker families. The
policy hash covers the registry, so it cannot see them: a change to any of these
leaves the hash identical while the corpus behaves differently. A coverage count
taken over the registry alone would both understate the corpus and hide that.

## How this page is produced

`zig build test-expert-app` replays the committed cassettes and prints one
`[proof-coverage]` line. `scripts/update-coverage.sh` lifts it, writes
[coverage.json](coverage.json), and renders this page.

The replay carries three floors and a ratchet. The denominator must be credible,
the collector must have read something, and the committed baseline in
`packages/pi/src/expert_codegen_record.zig` must name at least five rules - an
emptied baseline iterates nothing and reports a clean ratchet over no claim. The
ratchet is one-directional and headline-model only: a corpus that grows trips
more and nothing complains, a corpus that stops standing on a fence fails and
names it.

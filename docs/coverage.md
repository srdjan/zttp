<!-- Generated file. Do not edit. Run `bash scripts/update-coverage.sh` to regenerate it. -->

# Coverage

What the offline suite proves, and what it does not.

> The offline suite proves two things. The harness is faithful: recorder capture
> and replay, the loop, veto, apply, retry, salvage, compiler repair, and the
> hole loop execute correctly over their declared fixtures. And the
> corpus is load-bearing: of the compiler's 77 advertised rules,
> 7 are tripped by at least one case. It proves nothing about what a
> model will draft. First-draft pass rate, median round-trips, and intent pass
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

Recorded 2026-08-09 over corpus `04d2e920b07f`. The replay fails
when this page drifts from the run, so it is regenerated in the same commit as
whatever moved it, and `git log docs/coverage.json` is the history.

## Rule coverage

| Rules advertised | Tripped by at least one case | Untripped |
|---|---|---|
| 77 | 7 | 70 |

Tripped: `ZTS305`, `ZTS400`, `ZTS401`, `ZTS407`, `ZTS500`, `ZTS502`, `ZTS600`

The list above is a fair description of what these prompts ask for and a poor
description of what the compiler proves. It is the mechanical form of an
argument [convergence.md](convergence.md) had been making in prose: a fence no
case stands on cannot move a published number, and nine consecutive rows reading
90% over one corpus is what that looks like from outside.

The previous sentence here counted the tripped rules by family in prose, and it
was wrong the first time the count moved. Nothing in this section restates a
number the generator computes; the codes are printed, and a reader who wants the
breakdown reads them.

Untripped: `ZTS300`, `ZTS301`, `ZTS302`, `ZTS303`, `ZTS304`, `ZTS306`, `ZTS307`, `ZTS308`, `ZTS309`, `ZTS310`, `ZTS320`, `ZTS321`, `ZTS501`, `ZTS601`, `ZTS602`, `ZTS603`, `ZTS604`, `ZTS605`, `ZTS608`, `ZTS609`, `ZTS610`, `ZTS623`, `ZTS611`, `ZTS612`, `ZTS621`, `ZTS613`, `ZTS614`, `ZTS615`, `ZTS616`, `ZTS617`, `ZTS618`, `ZTS619`, `ZTS620`, `ZTS622`, `ZTS625`, `ZTS626`, `ZTS627`, `ZTS628`, `ZTS624`, `ZTS606`, `ZTS503`, `ZTS504`, `ZTS505`, `ZTS506`, `ZTS507`, `ZTS508`, `ZTS607`, `ZTS509`, `ZTS510`, `ZTS511`, `ZTS512`, `POL001`, `POL002`, `POL003`, `POL004`, `POL005`, `POL006`, `POL007`, `POL008`, `PROP01`, `PROP02`, `PROP03`, `PROP04`, `PROP05`, `PROP06`, `ZTS402`, `ZTS403`, `ZTS404`, `ZTS405`, `ZTS406`

## Codes the registry does not carry

`ZTS001`, `ZTS002`, `ZTS203`, `ZTS211`

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

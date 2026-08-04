<!-- Generated file. Do not edit. Run `bash scripts/update-coverage.sh` to regenerate it. -->

# Coverage

What the offline suite proves, and what it does not.

> The offline suite proves two things. The harness is faithful: the loop, the
> veto, the apply path, the veto-retry path, salvage-on-reject, and the hole loop
> execute correctly over every entry in the stand-in's declared range. And the
> corpus is load-bearing: of the compiler's 72 advertised rules,
> 5 are tripped by at least one case. It proves nothing about what a
> model will draft. First-draft pass rate, median round-trips, and intent pass
> exist only as recordings of a live model, an offline run is structurally unable
> to produce or update them, and any figure of that shape that does not carry a
> cassette-derived model column is a defect in
> [convergence.md](convergence.md).

## What runs with no API key

| Path | Offline | How |
|---|---|---|
| Loop, veto, apply | yes | every entry in the declared range, driven through the real server and the real loop |
| Veto retry | yes | defect seeds whose bad draft the veto rejects and whose good draft lands on the retry |
| Salvage-on-reject | yes | canonical-band seeds, asserted against the exact bytes normalizing the draft produces |
| Hole fill | yes | a skeleton whose response expression is a hole, filled through the real `zts_expert_fill_hole` |
| Compiler-authored repair lane | no | no seed produces a verified lane candidate yet, so the class carries no enum member |

One path is still live-only, and saying so is the point of writing this down.
The repair lane applies a compiler-authored fix with no model turn, and a
declared class with no seeds would be a gate iterating nothing - the shape every
other gate here exists to avoid. Until a seed exists, this page claims the paths
it lists and no others.

Two fills in one turn do not compose, which is pinned rather than worked around:
`zts_expert_fill_hole` re-reads from disk on every call, so the second is
computed against the original bytes and drops the first. The offline test asserts
exactly that and goes red the day it is fixed.

Recorded 2026-08-04 over corpus `83c9c0c040e8`. The replay fails
when this page drifts from the run, so it is regenerated in the same commit as
whatever moved it, and `git log docs/coverage.json` is the history.

## Rule coverage

| Rules advertised | Tripped by at least one case | Untripped |
|---|---|---|
| 72 | 5 | 67 |

Tripped: `ZTS400`, `ZTS401`, `ZTS407`, `ZTS500`, `ZTS502`

Four flow rules and one spec-discharge rule. That is a fair description of what
these prompts ask for and a poor description of what the compiler proves, and it
is the mechanical form of an argument [convergence.md](convergence.md) had been
making in prose: a fence no case stands on cannot move a published number, and
nine consecutive rows reading 90% over one corpus is what that looks like from
outside.

Untripped: `ZTS300`, `ZTS301`, `ZTS302`, `ZTS303`, `ZTS304`, `ZTS305`, `ZTS306`, `ZTS307`, `ZTS308`, `ZTS309`, `ZTS310`, `ZTS320`, `ZTS321`, `ZTS501`, `ZTS600`, `ZTS601`, `ZTS602`, `ZTS603`, `ZTS604`, `ZTS605`, `ZTS608`, `ZTS609`, `ZTS610`, `ZTS623`, `ZTS611`, `ZTS612`, `ZTS621`, `ZTS613`, `ZTS614`, `ZTS615`, `ZTS616`, `ZTS617`, `ZTS618`, `ZTS619`, `ZTS620`, `ZTS622`, `ZTS606`, `ZTS503`, `ZTS504`, `ZTS505`, `ZTS506`, `ZTS507`, `ZTS508`, `ZTS607`, `ZTS509`, `ZTS510`, `ZTS511`, `ZTS512`, `POL001`, `POL002`, `POL003`, `POL004`, `POL005`, `POL006`, `POL007`, `POL008`, `PROP01`, `PROP02`, `PROP03`, `PROP04`, `PROP05`, `PROP06`, `ZTS402`, `ZTS403`, `ZTS404`, `ZTS405`, `ZTS406`

## Codes the registry does not carry

`ZTS001`, `ZTS002`, `ZTS203`, `ZTS204`

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

#!/usr/bin/env bash
#
# Publish what the offline suite covers.
#
# This is the sibling of update-convergence.sh and deliberately not the same
# script. That one publishes a measurement of a live model, lifted from a
# cassette replay and carrying the model's name. This one publishes a fact about
# the corpus and the compiler: of the rules the compiler advertises, which does
# at least one case trip. The two answer different questions, and a page that
# mixed them would let an offline run look like a model result.
#
# Writes:
#
#   docs/coverage.json  - the latest run, for tooling
#   docs/coverage.md    - the human page
#
# Re-run after growing the corpus, after adding or removing a rule, or when a
# compiler change moves what the corpus reaches.

set -euo pipefail

cd "$(dirname "$0")/.."

json_out="docs/coverage.json"
md_out="docs/coverage.md"

echo ">> replaying the codegen corpus"
# Not anchored to the line start, and the JSON brace is required. The replay
# prints this line unindented when the test passes and indented under a failure
# header when it does not - and "does not" is the whole reason to run this
# script, since a stale page is what fails it. An anchored match worked only in
# the case where regenerating was unnecessary. The brace is what keeps the
# match off the neighbouring "docs/coverage.json is stale" advice line.
line="$(zig build test-expert-app 2>&1 | grep -m1 '\[proof-coverage\] {' || true)"
line="${line#"${line%%\[proof-coverage\]*}"}"

if [[ -z "$line" ]]; then
  echo "error: the replay emitted no [proof-coverage] line" >&2
  echo "Run 'zig build test-expert-app' and read the output; the corpus may be failing." >&2
  exit 1
fi

payload="${line#\[proof-coverage\] }"

# No commit field. convergence.md carries one because its rows accumulate and a
# reader needs to know which build produced each. This page is a single
# current-state answer, and the replay fails when it drifts from the run, so it
# is regenerated in the same commit as whatever moved it. `git log docs/coverage.json`
# is that record exactly, with no field to go stale.
printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["recorded"] = sys.argv[1]
print(json.dumps(d, indent=2))
' "$(date -u +%Y-%m-%d)" > "$json_out"
echo ">> wrote $json_out"

python3 - "$json_out" "$md_out" <<'PY'
import json, sys

json_path, md_path = sys.argv[1], sys.argv[2]
d = json.load(open(json_path))

total = d["rulesTotal"]
tripped = d["tripped"]
untripped = d["untripped"]
off = d["offRegistry"]

def codes(names):
    return ", ".join("`%s`" % n for n in names) if names else "none"

out = f"""<!-- Generated file. Do not edit. Run `bash scripts/update-coverage.sh` to regenerate it. -->

# Coverage

What the offline suite proves, and what it does not.

> The offline suite proves two things. The harness is faithful: recorder capture
> and replay, the loop, veto, apply, retry, salvage, compiler repair, and the
> hole loop execute correctly over their declared fixtures. And the
> corpus is load-bearing: of the compiler's {total} advertised rules,
> {len(tripped)} are tripped by at least one case. It proves nothing about what a
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

Recorded {d["recorded"]} over corpus `{d["corpusVersion"][:12]}`. The replay fails
when this page drifts from the run, so it is regenerated in the same commit as
whatever moved it, and `git log docs/coverage.json` is the history.

## Rule coverage

| Rules advertised | Tripped by at least one case | Untripped |
|---|---|---|
| {total} | {len(tripped)} | {len(untripped)} |

Tripped: {codes(tripped)}

The list above is a fair description of what these prompts ask for and a poor
description of what the compiler proves. It is the mechanical form of an
argument [convergence.md](convergence.md) had been making in prose: a fence no
case stands on cannot move a published number, and nine consecutive rows reading
90% over one corpus is what that looks like from outside.

The previous sentence here counted the tripped rules by family in prose, and it
was wrong the first time the count moved. Nothing in this section restates a
number the generator computes; the codes are printed, and a reader who wants the
breakdown reads them.

Untripped: {codes(untripped)}

## Codes the registry does not carry

{codes(off)}

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
"""

open(md_path, "w").write(out)
print(">> wrote", md_path)
PY

echo ">> done. Review the diff, then commit both files."

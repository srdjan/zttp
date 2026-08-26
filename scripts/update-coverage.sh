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

for filtered_var in ZTTP_CODEGEN_ONLY ZTTP_CODEGEN_LIMIT ZTTP_CODEGEN_TOOLS; do
  if [[ -n "${!filtered_var:-}" ]]; then
    echo "error: $filtered_var makes a coverage run non-publishable" >&2
    exit 1
  fi
done

evidence_tmp="$(mktemp -d "${TMPDIR:-/tmp}/zttp-coverage.XXXXXX")"
cleanup() {
  rm -rf "$evidence_tmp"
}
trap cleanup EXIT HUP INT TERM
replay_log="$evidence_tmp/replay.log"
json_tmp="$evidence_tmp/coverage.json"
md_tmp="$evidence_tmp/coverage.md"

# Intent scenarios invoke the built CLI. A replay without it reports less
# coverage than the declared suite and must not reach the publisher.
echo ">> building zttp (the intent checks drive it)"
zig build

echo ">> replaying the codegen corpus"
# Read evidence only after the whole producer exits successfully. A marker
# printed before a later test failure is not a completed run.
if ! ZTTP_EVIDENCE_PUBLISH=1 zig build test-expert-app >"$replay_log" 2>&1; then
  cat "$replay_log" >&2
  echo "error: the codegen replay failed; generated evidence is unchanged" >&2
  exit 1
fi

if ! payload="$(python3 scripts/extract-evidence-marker.py \
  "$replay_log" '[proof-coverage] ' coverage)"; then
  cat "$replay_log" >&2
  echo "error: the replay emitted no valid complete coverage marker" >&2
  exit 1
fi

read -r marker_commit marker_dirty <<EOF
$(printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["sourceCommit"], "true" if d["sourceDirty"] else "false")
')
EOF
current_commit="$(git rev-parse HEAD 2>/dev/null || true)"
current_dirty=false
if [[ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
  current_dirty=true
fi
if [[ "$current_commit" != "$marker_commit" || "$current_dirty" != "$marker_dirty" ]]; then
  echo "error: source state changed after replay; generated evidence is unchanged" >&2
  exit 1
fi

# The seed suite answers the other question this page has to keep apart: not
# "which rules did a model's drafts trip", but "which rules were observed
# firing at all". It is produced by the stand-in gate, which verifies each seed
# against the real veto before printing, so the marker means the rules were
# observed rather than merely listed.
#
# Deliberately not read through extract-evidence-marker.py: that validates a
# complete publishable model run and requires a runId, provider, model and the
# identity hashes, none of which a compiler-only claim has.
echo ">> verifying the defect-seed suite"
seed_log="$evidence_tmp/standin.log"
if ! zig build test-standin >"$seed_log" 2>&1; then
  cat "$seed_log" >&2
  echo "error: the defect-seed gate failed; generated evidence is unchanged" >&2
  exit 1
fi

seed_lines="$(grep -c '^\[seed-coverage\] ' "$seed_log" || true)"
if [[ "$seed_lines" != "1" ]]; then
  echo "error: expected exactly one [seed-coverage] line, found $seed_lines" >&2
  exit 1
fi
seed_payload="$(sed -n 's/^\[seed-coverage\] //p' "$seed_log")"

# No commit field. convergence.md carries one because its rows accumulate and a
# reader needs to know which build produced each. This page is a single
# current-state answer, and the replay fails when it drifts from the run, so it
# is regenerated in the same commit as whatever moved it. `git log docs/coverage.json`
# is that record exactly, with no field to go stale.
printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["recorded"] = sys.argv[1]
seed = json.loads(sys.argv[2])
for key in ("seedsTotal", "rulesTotal", "verifiedRules", "verified"):
    if key not in seed:
        raise SystemExit("error: seed-coverage marker is missing " + key)
# The two producers must agree on the denominator, or the page would print two
# different totals for one registry.
if seed["rulesTotal"] != d["rulesTotal"]:
    raise SystemExit("error: seed suite and corpus disagree on rulesTotal")
if not seed["verified"]:
    raise SystemExit("error: seed-coverage marker verified nothing")
d["seedSuite"] = {
    "seedsTotal": seed["seedsTotal"],
    "verifiedRules": seed["verifiedRules"],
    "verified": seed["verified"],
}
print(json.dumps(d, indent=2))
' "$(date -u +%Y-%m-%d)" "$seed_payload" > "$json_tmp"

python3 - "$json_tmp" "$md_tmp" <<'PY'
import json, sys

json_path, md_path = sys.argv[1], sys.argv[2]
d = json.load(open(json_path))

total = d["rulesTotal"]
tripped = d["tripped"]
untripped = d["untripped"]
off = d["offRegistry"]

seed = d["seedSuite"]
seed_codes = seed["verified"]
seed_verified = seed["verifiedRules"]
seed_total = seed["seedsTotal"]
seed_only = len([c for c in seed_codes if c in untripped])
corpus_only = len([c for c in tripped if c not in seed_codes])
overlap_count = len(set(tripped) & set(seed_codes))
union_count = len(set(tripped) | set(seed_codes))

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
| {total} | {seed_verified} | {seed_total} |

Verified: {codes(seed_codes)}

No model is involved, so this figure does not move when a recording draws
differently. It also proves less: a seed shows the compiler rejects a draft the
harness supplied, and says nothing about whether a model would ever write one.
That is the question the section above answers, and only a recording can.

Neither number bounds the other. {seed_only} of the rules verified here are
untripped by the corpus, {corpus_only} tripped by the corpus have no seed, and
the two sets share {overlap_count}. Together they name {union_count} of the {total}
advertised rules, which is the closest thing to a combined answer this
repository can currently produce - and it is still two claims added up, not one
measurement.

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

python3 - "$json_tmp" "$md_tmp" <<'PY'
import json, os, sys

with open(sys.argv[1]) as f:
    payload = json.load(f)
if payload.get("complete") is not True or payload.get("completedCases") != 19:
    raise SystemExit("error: rendered coverage JSON lost its completion floor")
if payload.get("rulesTotal", 0) <= 0 or payload.get("rulesTripped", 0) <= 0:
    raise SystemExit("error: rendered coverage JSON counted no rules")
if os.path.getsize(sys.argv[2]) == 0:
    raise SystemExit("error: rendered coverage Markdown is empty")
PY

mv "$json_tmp" "$json_out"
mv "$md_tmp" "$md_out"
echo ">> wrote $json_out and $md_out"
echo ">> done. Review the diff, then commit both files."

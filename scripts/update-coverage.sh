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

# The union across every published run of this corpus identity. A single row is
# a sample: the same prompts, seeds, provider, model and compiler have measured
# 4, 5 and 2 rules on different draws. `scripts/coverage-union.sh` reads
# `git log docs/coverage.json`, which this page already names as its history,
# and refuses a shallow clone rather than publishing a truncated union as a
# complete one. The pending run's own codes are passed in because they are not
# in git yet.
echo ">> unioning this corpus identity across its published runs"
union_version="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["corpusVersion"])')"
union_codes="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["tripped"]))')"
if ! union_payload="$(bash scripts/coverage-union.sh "$union_version" $union_codes)"; then
  echo "error: the corpus union could not be computed; generated evidence is unchanged" >&2
  exit 1
fi

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
for key in ("seedsTotal", "rulesTotal", "verifiedRules", "verified", "unseeded"):
    if key not in seed:
        raise SystemExit("error: seed-coverage marker is missing " + key)
# The two producers must agree on the denominator, or the page would print two
# different totals for one registry.
if seed["rulesTotal"] != d["rulesTotal"]:
    raise SystemExit("error: seed suite and corpus disagree on rulesTotal")
if not seed["verified"]:
    raise SystemExit("error: seed-coverage marker verified nothing")
# The remainder, and why each rule is in it. The stand-in gate refuses to print
# this marker unless every advertised rule is either verified above or carries a
# row, so the two lists partition the registry by construction rather than by
# the renderer trusting them to.
unseeded = seed["unseeded"]
if len(seed["verified"]) + len(unseeded) != seed["rulesTotal"]:
    raise SystemExit("error: seed-coverage verified and unseeded do not partition the registry")
d["seedSuite"] = {
    "seedsTotal": seed["seedsTotal"],
    "verifiedRules": seed["verifiedRules"],
    "verified": seed["verified"],
    "unseeded": unseeded,
}
union = json.loads(sys.argv[3])
if union["corpusVersion"] != d["corpusVersion"]:
    raise SystemExit("error: the union was computed for a different corpus identity")
# The union contains this run by construction, so it can never be smaller.
# A union below the current count means the codes were never merged in.
if union["unionCount"] < d["rulesTripped"]:
    raise SystemExit("error: the union is smaller than the tripped set of this very run")
d["corpusUnion"] = union
print(json.dumps(d, indent=2))
' "$(date -u +%Y-%m-%d)" "$seed_payload" "$union_payload" > "$json_tmp"

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
seed_unseeded = seed["unseeded"]
by_reason = {}
for row in seed_unseeded:
    by_reason.setdefault(row["reason"], []).append(row["code"])
seed_only = len([c for c in seed_codes if c in untripped])
corpus_only = len([c for c in tripped if c not in seed_codes])
overlap_count = len(set(tripped) & set(seed_codes))
union_count = len(set(tripped) | set(seed_codes))

cu = d["corpusUnion"]
union_codes = cu["union"]
union_total = cu["unionCount"]
union_observations = cu["observations"]
union_distinct = cu["distinctSets"]
union_min = cu["smallestSet"]
union_max = cu["largestSet"]
version_short = d["corpusVersion"][:12]
union_all = len(set(union_codes) | set(seed_codes))

def codes(names):
    return ", ".join("`%s`" % n for n in names) if names else "none"

REASON_MEANING = {
    "no-producer": "The registry carries the code and no code path constructs a diagnostic with it, so nothing can emit it",
    "shadowed": "Another checker refuses the construct first, so this rule's diagnostic never reaches the stream",
    "non-default": "Emitted only under an opt-in mode the veto does not run",
}


def render_remainder(rows_by_reason, total, verified):
    """The rules the seed suite does not verify, and why each is out.

    Written to survive its own list shrinking. The first version of this
    section hard-coded three table rows and a sentence about the `no-producer`
    group being load-bearing, which was true when seventeen rules sat in it and
    became nonsense at zero - printing "none" twice and claiming a reader was
    "wrong about 0 of them".
    """
    present = [(r, c) for r, c in rows_by_reason.items() if c]
    present.sort(key=lambda pair: (-len(pair[1]), pair[0]))
    left = total - verified

    if not present:
        return (
            "None. Every one of the %d advertised rules is verified firing by a\n"
            "defect seed." % total
        )

    lines = []
    if left == 1:
        reason, codes_for = present[0]
        lines.append(
            "One advertised rule of %d is not verified by a seed: %s, because it is\n"
            "`%s`. %s.\n" % (total, codes(codes_for), reason, REASON_MEANING[reason])
        )
    else:
        lines.append(
            "The %d advertised rules the section above leaves out, and why each is out.\n"
            "This is not a backlog: a rule is listed here only when writing another\n"
            "seed cannot reach it.\n" % left
        )
        lines.append("| Reason | Rules | What it means |")
        lines.append("|---|---|---|")
        for reason, codes_for in present:
            lines.append("| `%s` | %s | %s |" % (reason, codes(codes_for), REASON_MEANING[reason]))
        lines.append("")

    no_producer = len(rows_by_reason.get("no-producer", []))
    if no_producer:
        lines.append(
            "The `no-producer` group is the load-bearing one. Each of those %d codes is\n"
            "advertised by `zts describe-rule` and counted in the %d denominator every\n"
            "figure on this page divides by, and no seed and no recorded draft can ever\n"
            "trip it. Reading %d of %d as \"%d still to write\" is wrong about them."
            % (no_producer, total, verified, total, left)
        )
    else:
        lines.append(
            "Nothing here is waiting on a seed. The registry once advertised codes no\n"
            "code path could construct; those were deleted rather than seeded, which is\n"
            "why this section is now one line instead of a table of seventeen."
        )

    lines.append("")
    lines.append(
        "The rows live in `scripts/unseeded-rules.allow` with the probe behind each one.\n"
        "The stand-in gate enforces the list in both directions: an advertised rule that\n"
        "is neither seeded nor listed fails, and so does a row for a code a seed has\n"
        "since covered. Neither list can drift from the registry without failing a build."
    )
    return "\n".join(lines)

remainder_section = render_remainder(by_reason, total, seed_verified)

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

## What this corpus has ever reached

The row above is one draw. The same prompts, seeds, provider, model and
compiler have measured a different set each time they were recorded, because a
rule is counted only when the model happens to make the mistake that trips it.
Across the {union_observations} published runs of corpus `{version_short}`, the
tripped set took {union_distinct} distinct shapes, the smallest naming
{union_min} rules and the largest {union_max}.

| Union across runs | Smallest single run | Largest single run |
|---|---|---|
| {union_total} | {union_min} | {union_max} |

Ever tripped: {codes(union_codes)}

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
| {total} | {seed_verified} | {seed_total} |

Verified: {codes(seed_codes)}

No model is involved, so this figure does not move when a recording draws
differently. It also proves less: a seed shows the compiler rejects a draft the
harness supplied, and says nothing about whether a model would ever write one.
That is the question the section above answers, and only a recording can.

Neither number bounds the other. The corpus leaves {seed_only} of the rules
verified here untripped; it trips {corpus_only} that no seed covers; and the two
sets share {overlap_count}. Together they name {union_count} of the {total}
advertised rules, and taking the corpus union above instead of this single run
raises that to {union_all} - the closest thing to a combined answer this
repository can produce, and still two claims added up rather than one
measurement.

## The rules no seed reaches

{remainder_section}

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

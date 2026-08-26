#!/usr/bin/env bash
# scripts/coverage-union.sh
#
# The union of tripped rules across every published coverage run for one corpus
# identity.
#
# A single coverage row is a sample, not a property of the corpus. Three
# recordings of corpus `0012ad8ca6d5` measured 4, 5 and 2 rules with the same
# prompts, the same seeds, the same provider and model and the same compiler,
# because a rule is counted only when the model happens to make the mistake that
# trips it. Any one of those rows understates what these prompts can reach. The
# union does not, and nothing computed it before this script.
#
# The record is `git log docs/coverage.json`, which the coverage page already
# names as its history. This reads exactly that, keeps the entries whose
# `corpusVersion` matches the identity asked for, and unions their `tripped`
# arrays. Codes given on the command line are unioned in too, so a run can
# include the result it is about to publish and is not yet in git.
#
# Usage:
#   bash scripts/coverage-union.sh <corpus-version> [code ...]
#
# Prints one JSON object on stdout.

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf 'coverage union: %s\n' "$1" >&2
  exit 1
}

[[ $# -ge 1 ]] || fail "usage: coverage-union.sh <corpus-version> [code ...]"

version="$1"
shift

[[ "$version" =~ ^[0-9a-f]{64}$ ]] ||
  fail "corpus version must be 64 lowercase hex characters, got '$version'"

# A shallow clone holds a truncated history, so the union it computes is a
# smaller set than the one the repository actually recorded - and it would be
# published as though it were complete. Refuse rather than understate.
if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo true)" != "false" ]]; then
  fail "shallow clone: the history this union is computed from is truncated"
fi

commits="$(git log --format=%H -- docs/coverage.json)"
[[ -n "$commits" ]] ||
  fail "no commit in this history touches docs/coverage.json; there is nothing to union"

# Each historical blob, one JSON document per line, oldest last. A commit whose
# blob does not parse is skipped rather than fatal: the page predates its own
# schema in early history, and refusing there would make this unusable for the
# identity it is actually about.
history_tmp="$(mktemp "${TMPDIR:-/tmp}/zttp-coverage-union.XXXXXX")"
trap 'rm -f "$history_tmp"' EXIT HUP INT TERM
for commit in $commits; do
  git show "$commit:docs/coverage.json" 2>/dev/null >>"$history_tmp" || true
  printf '\n' >>"$history_tmp"
done

python3 - "$version" "$history_tmp" "$@" <<'PY'
import json
import sys

version = sys.argv[1]
history_path = sys.argv[2]
pending = sys.argv[3:]

# One document per non-blank chunk. json.JSONDecoder.raw_decode walks the file
# rather than assuming one object per line, because a pretty-printed blob spans
# many lines.
raw = open(history_path).read()
decoder = json.JSONDecoder()
documents = []
index = 0
while index < len(raw):
    while index < len(raw) and raw[index].isspace():
        index += 1
    if index >= len(raw):
        break
    try:
        value, index = decoder.raw_decode(raw, index)
    except ValueError:
        # Unparseable blob from early history. Skip to the next brace and retry.
        nxt = raw.find("{", index + 1)
        if nxt == -1:
            break
        index = nxt
        continue
    if isinstance(value, dict):
        documents.append(value)

if not documents:
    raise SystemExit("coverage union: no coverage.json blob in history parsed")

matching = [d for d in documents if d.get("corpusVersion") == version]

# Floor. An identity nothing in history carries would otherwise union to just
# the pending codes and read as a complete answer.
if not matching:
    raise SystemExit(
        "coverage union: no published coverage.json carries corpus %s" % version[:12]
    )

sets = []
union = set(pending)
for d in matching:
    tripped = d.get("tripped")
    if not isinstance(tripped, list):
        continue
    codes = tuple(sorted(str(c) for c in tripped))
    sets.append(codes)
    union.update(codes)

if not sets:
    raise SystemExit("coverage union: no entry for this corpus carries a tripped list")

# Distinct sets, not observations: the page is regenerated more often than the
# corpus is recorded, so two commits can publish one recording's result and
# counting commits would overstate how many times this was measured.
distinct = sorted(set(sets))
sizes = sorted(len(s) for s in distinct)

print(
    json.dumps(
        {
            "corpusVersion": version,
            "observations": len(sets),
            "distinctSets": len(distinct),
            "smallestSet": sizes[0],
            "largestSet": sizes[-1],
            "union": sorted(union),
            "unionCount": len(union),
        }
    )
)
PY

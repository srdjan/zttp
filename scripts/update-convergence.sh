#!/usr/bin/env bash
#
# Publish the convergence number.
#
# STRATEGY.md's thesis is that the set of programs the agent can write should
# converge on the set the compiler can prove. First-draft veto-pass rate is the
# literal measurement of that, and until this script existed the number was
# printed to stderr by a test and published nowhere - so the thesis had no
# answer to the obvious rebuttal that any retry loop eventually passes a linter.
#
# This runs the offline cassette replay (deterministic, no network, no key),
# lifts the one machine-readable line it emits, and writes:
#
#   docs/convergence.json  - the latest run, for tooling
#   docs/convergence.md    - the human table, one row appended per run
#
# History is git history on those two files. Every row carries the corpus
# version and the policy hash, so a row recorded before a compiler change is
# never silently compared against one recorded after it.
#
# Re-run after recording a new baseline, or when a compiler change moves the
# rate and you want the published figure to say so.

set -euo pipefail

cd "$(dirname "$0")/.."

json_out="docs/convergence.json"
md_out="docs/convergence.md"

# The intent checks drive the built `zttp`, so build before measuring or the
# run reports `intentChecked: 0` and understates its own coverage.
echo ">> building zttp (the intent checks drive it)"
zig build

echo ">> replaying the codegen corpus"
line="$(zig build test-expert-app 2>&1 | grep -m1 '^\[codegen-convergence\] ' || true)"

if [[ -z "$line" ]]; then
  echo "error: the replay emitted no [codegen-convergence] line" >&2
  echo "Run 'zig build test-expert-app' and read the output; the corpus may be failing." >&2
  exit 1
fi

payload="${line#\[codegen-convergence\] }"

printf '%s\n' "$payload" > "$json_out"
echo ">> wrote $json_out"

recorded="$(date -u +%Y-%m-%d)"

read -r corpus_version cases model policy first_pct first_n median intent_pct intent_pass intent_n <<EOF
$(printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(
    d["corpusVersion"][:12],
    d["corpusCases"],
    d["model"],
    d["policyHash"][:12],
    d["firstDraftPassPercent"],
    d["firstDraftPasses"],
    d["medianRoundtrips"],
    d["intentPassPercent"],
    d["intentPasses"],
    d["intentChecked"],
)
')
EOF

row="| $recorded | \`$corpus_version\` | $cases | $model | \`$policy\` | ${first_pct}% ($first_n/$cases) | $median | ${intent_pct}% ($intent_pass/$intent_n) |"

if ! grep -q '^| Recorded ' "$md_out" 2>/dev/null; then
  echo "error: $md_out has no results table to append to" >&2
  exit 1
fi

# Append below the last existing row of the table.
python3 - "$md_out" "$row" <<'PY'
import sys

path, row = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()

last = max(i for i, l in enumerate(lines) if l.startswith("| "))
if lines[last].strip() == row.strip():
    print(">> table already carries this row; left unchanged")
else:
    lines.insert(last + 1, row)
    open(path, "w").write("\n".join(lines) + "\n")
    print(">> appended a row to", path)
PY

echo ">> done. Review the diff, then commit both files."

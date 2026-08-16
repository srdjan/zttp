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

for filtered_var in ZTTP_CODEGEN_ONLY ZTTP_CODEGEN_LIMIT ZTTP_CODEGEN_TOOLS; do
  if [[ -n "${!filtered_var:-}" ]]; then
    echo "error: $filtered_var makes a convergence run non-publishable" >&2
    exit 1
  fi
done

evidence_tmp="$(mktemp -d "${TMPDIR:-/tmp}/zttp-convergence.XXXXXX")"
cleanup() {
  rm -rf "$evidence_tmp"
}
trap cleanup EXIT HUP INT TERM
replay_log="$evidence_tmp/replay.log"
json_tmp="$evidence_tmp/convergence.json"
md_tmp="$evidence_tmp/convergence.md"

# The intent checks drive the built `zttp`, so build before measuring or the
# run reports `intentChecked: 0` and understates its own coverage.
echo ">> building zttp (the intent checks drive it)"
zig build

echo ">> replaying the codegen corpus"
# Capture the complete producer status before reading its marker. A test can
# print a valid-looking summary and fail later; publishing that line would turn
# a failed run into current evidence.
if ! ZTTP_EVIDENCE_PUBLISH=1 zig build test-expert-app >"$replay_log" 2>&1; then
  cat "$replay_log" >&2
  echo "error: the codegen replay failed; generated evidence is unchanged" >&2
  exit 1
fi

if ! payload="$(python3 scripts/extract-evidence-marker.py \
  "$replay_log" '[codegen-convergence] ' convergence)"; then
  cat "$replay_log" >&2
  echo "error: the replay emitted no valid complete convergence marker" >&2
  exit 1
fi

# The producer binds the source before it hashes the result. Re-read the source
# now and refuse a checkout that moved between replay and publication.
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
commit="${marker_commit:0:8}"
if [[ "$marker_dirty" == true ]]; then
  commit="$commit-dirty"
  echo ">> warning: working tree is dirty; the row will be marked $commit" >&2
fi

printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["commit"] = sys.argv[1]
print(json.dumps(d))
' "$commit" > "$json_tmp"

recorded="$(date -u +%Y-%m-%d)"

read -r corpus_version cases provider model policy raw_pct raw_n first_pct first_n median intent_pct intent_pass intent_n <<EOF
$(printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(
    d["corpusVersion"][:12],
    d["corpusCases"],
    d["provider"],
    d["model"],
    d["policyHash"][:12],
    d["rawFirstDraftPassPercent"],
    d["rawFirstDraftPasses"],
    d["firstAttemptGreenPercent"],
    d["firstAttemptGreens"],
    d["medianRoundtrips"],
    d["intentPassPercent"],
    d["intentPasses"],
    d["intentChecked"],
)
')
EOF

row="| $recorded | \`$commit\` | \`$corpus_version\` | $cases | $provider | $model | \`$policy\` | ${raw_pct}% ($raw_n/$cases) | ${first_pct}% ($first_n/$cases) | $median | ${intent_pct}% ($intent_pass/$intent_n) |"

if ! grep -q '^| Recorded ' "$md_out" 2>/dev/null; then
  echo "error: $md_out has no results table to append to" >&2
  exit 1
fi

cp "$md_out" "$md_tmp"

# The historical table used one overloaded first-draft column. It counted a
# compiler-normalized attempt as a first-draft pass. Keep those values as
# first-attempt green and mark raw model-authored bytes as unmeasured.
python3 - "$md_tmp" <<'PY'
import sys

path = sys.argv[1]
text = open(path).read()
old = """The headline figure is **first-draft veto-pass rate**: how often the model's
first attempt at a prompt clears the compiler veto with no retries. It is a
counted result over a frozen corpus, not an estimate.
"""
new = """The headline figure is **raw first-draft veto-pass rate**: how often the exact
model-authored bytes clear the compiler veto before normalization, repair, or
retry. **First-attempt green** is reported beside it and includes compiler
normalization or repair on that attempt. Both are counted results over a frozen
corpus, not estimates.
"""
if old in text:
    text = text.replace(old, new, 1)
open(path, "w").write(text)
PY

# Append below the last row of the RESULTS table specifically.
#
# The page carries other tables - the model comparison, the hole-mode arms - and
# they sit after the results table. Anchoring on the last `| ` line anywhere in
# the file put the 20-case row at the end of the model-comparison table, where it
# read as a third model. The anchor is the `| Recorded ` header, and the block is
# the contiguous run of rows under it.
python3 - "$md_tmp" "$row" <<'PY'
import sys

path, row = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()

header = next((i for i, l in enumerate(lines) if l.startswith("| Recorded ")), None)
if header is None:
    sys.exit("error: no results table header (`| Recorded `) in " + path)

cells = [cell.strip() for cell in lines[header].strip("|").split("|")]
if "Provider" not in cells:
    model_index = cells.index("Model")
    cells.insert(model_index, "Provider")
    lines[header] = "| " + " | ".join(cells) + " |"

    separators = [cell.strip() for cell in lines[header + 1].strip("|").split("|")]
    separators.insert(model_index, "---")
    lines[header + 1] = "|" + "|".join(separators) + "|"

    i = header + 2
    while i < len(lines) and lines[i].startswith("| "):
        historical = [cell.strip() for cell in lines[i].strip("|").split("|")]
        historical.insert(model_index, "anthropic")
        lines[i] = "| " + " | ".join(historical) + " |"
        i += 1

cells = [cell.strip() for cell in lines[header].strip("|").split("|")]
if "First-draft pass" in cells:
    first_index = cells.index("First-draft pass")
    cells[first_index] = "First-attempt green"
    lines[header] = "| " + " | ".join(cells) + " |"
if "Raw first-draft pass" not in cells:
    first_index = cells.index("First-attempt green")
    cells.insert(first_index, "Raw first-draft pass")
    lines[header] = "| " + " | ".join(cells) + " |"

    separators = [cell.strip() for cell in lines[header + 1].strip("|").split("|")]
    separators.insert(first_index, "---")
    lines[header + 1] = "|" + "|".join(separators) + "|"

    i = header + 2
    while i < len(lines) and lines[i].startswith("| "):
        historical = [cell.strip() for cell in lines[i].strip("|").split("|")]
        historical.insert(first_index, "not measured")
        lines[i] = "| " + " | ".join(historical) + " |"
        i += 1

last = header + 1  # the |---|---| separator
while last + 1 < len(lines) and lines[last + 1].startswith("| "):
    last += 1

block = [l.strip() for l in lines[header + 2 : last + 1]]
if row.strip() in block:
    print(">> table already carries this row; left unchanged")
else:
    lines.insert(last + 1, row)
    open(path, "w").write("\n".join(lines) + "\n")
    print(">> appended a row to", path)
PY

python3 - "$json_tmp" "$md_tmp" <<'PY'
import json, os, sys

with open(sys.argv[1]) as f:
    payload = json.load(f)
if payload.get("complete") is not True or payload.get("completedCases") != 19:
    raise SystemExit("error: rendered convergence JSON lost its completion floor")
if os.path.getsize(sys.argv[2]) == 0:
    raise SystemExit("error: rendered convergence Markdown is empty")
PY

mv "$json_tmp" "$json_out"
mv "$md_tmp" "$md_out"
echo ">> wrote $json_out and $md_out"
echo ">> done. Review the diff, then commit both files."

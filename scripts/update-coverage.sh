#!/usr/bin/env bash
# Publish measured coverage through the native evidence command.

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

if [[ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
  echo "error: coverage publication requires a clean working tree" >&2
  exit 1
fi

evidence_tmp="$(mktemp -d "${TMPDIR:-/tmp}/zttp-coverage.XXXXXX")"
cleanup() {
  rm -rf "$evidence_tmp"
}
trap cleanup EXIT HUP INT TERM
replay_log="$evidence_tmp/replay.log"
seed_log="$evidence_tmp/standin.log"
union_log="$evidence_tmp/union.log"
json_tmp="$evidence_tmp/coverage.json"
md_tmp="$evidence_tmp/coverage.md"

echo ">> building zttp (the intent checks drive it)"
zig build

echo ">> replaying the codegen corpus"
if ! ZTTP_EVIDENCE_PUBLISH=1 zig build test-expert-app >"$replay_log" 2>&1; then
  cat "$replay_log" >&2
  echo "error: the codegen replay failed; generated evidence is unchanged" >&2
  exit 1
fi

echo ">> verifying the defect-seed suite"
if ! zig build test-standin >"$seed_log" 2>&1; then
  cat "$seed_log" >&2
  echo "error: the defect-seed gate failed; generated evidence is unchanged" >&2
  exit 1
fi

# The native reader supplies the validated corpus identity and pending codes.
if ! union_inputs="$(zig build evidence-publish -- coverage-inputs "$replay_log")"; then
  cat "$replay_log" >&2
  echo "error: the replay emitted no valid complete coverage marker" >&2
  exit 1
fi
union_version="$(printf '%s\n' "$union_inputs" | sed -n '1p')"
union_codes="$(printf '%s\n' "$union_inputs" | sed -n '2p')"
if ! union_source_tree_hash="$(git rev-parse HEAD:packages 2>/dev/null)"; then
  echo "error: could not identify the committed packages tree" >&2
  exit 1
fi

echo ">> unioning this corpus identity across its published runs"
if ! zig build coverage-union -- \
  "$union_version" "$union_source_tree_hash" $union_codes >"$union_log" 2>&1; then
  cat "$union_log" >&2
  echo "error: the corpus union could not be computed; generated evidence is unchanged" >&2
  exit 1
fi
current_commit="$(git rev-parse HEAD 2>/dev/null || true)"
current_dirty=false
if [[ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
  current_dirty=true
fi
if ! zig build evidence-publish -- coverage \
  "$replay_log" "$seed_log" "$union_log" "$json_tmp" "$md_tmp" \
  "$(date -u +%Y-%m-%d)" "$current_commit" "$current_dirty"; then
  cat "$replay_log" >&2
  echo "error: the coverage inputs are incomplete or inconsistent" >&2
  exit 1
fi

mv "$json_tmp" "$json_out"
mv "$md_tmp" "$md_out"
echo ">> wrote $json_out and $md_out"
echo ">> done. Review the diff, then commit both files."

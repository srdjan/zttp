#!/usr/bin/env bash
# Publish the measured convergence row through the native evidence command.

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

if [[ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
  echo "error: convergence publication requires a clean working tree" >&2
  exit 1
fi

evidence_tmp="$(mktemp -d "${TMPDIR:-/tmp}/zttp-convergence.XXXXXX")"
cleanup() {
  rm -rf "$evidence_tmp"
}
trap cleanup EXIT HUP INT TERM
replay_log="$evidence_tmp/replay.log"
json_tmp="$evidence_tmp/convergence.json"
md_tmp="$evidence_tmp/convergence.md"

# Intent checks drive the built CLI. Build it before the measurement.
echo ">> building zttp (the intent checks drive it)"
zig build

echo ">> replaying the codegen corpus"
if ! ZTTP_EVIDENCE_PUBLISH=1 zig build test-expert-app >"$replay_log" 2>&1; then
  cat "$replay_log" >&2
  echo "error: the codegen replay failed; generated evidence is unchanged" >&2
  exit 1
fi

# The native command validates one complete marker. It also compares the
# producer's source identity with the source state after the replay.
current_commit="$(git rev-parse HEAD 2>/dev/null || true)"
current_dirty=false
if [[ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
  current_dirty=true
fi
if ! zig build evidence-publish -- convergence \
  "$replay_log" "$json_tmp" "$md_out" "$md_tmp" \
  "$(date -u +%Y-%m-%d)" "$current_commit" "$current_dirty"; then
  cat "$replay_log" >&2
  echo "error: the replay emitted no valid current convergence evidence" >&2
  exit 1
fi

mv "$json_tmp" "$json_out"
mv "$md_tmp" "$md_out"
echo ">> wrote $json_out and $md_out"
echo ">> done. Review the diff, then commit both files."

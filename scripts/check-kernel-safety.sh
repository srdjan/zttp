#!/usr/bin/env bash
# Check the local runtime-safety setting in every acceptance-kernel function.

set -euo pipefail

cd "$(dirname "$0")/.."

# Measured 2026-10-23: 13 kernel source files. BSD xargs runs nothing and exits
# 0 on empty input, so an empty list would pass without a scan. The Zig gate
# keeps its own file floor for a partial list.
minimum_files=13

list="$(mktemp)"
trap 'command rm -f "$list"' EXIT

# Include cached and untracked source files. The latter keeps a newly added
# kernel file inside the gate before it is staged. The Zig parser distinguishes
# function bodies in test blocks and handles signatures that span many lines.
git ls-files -z --cached --others --exclude-standard -- 'packages/proof-checker/src/*.zig' > "$list"

count="$(tr -cd '\0' < "$list" | wc -c | tr -d ' ')"
if [ "$count" -lt "$minimum_files" ]; then
  echo "FAIL: kernel safety gate found $count kernel source files; the floor is $minimum_files" >&2
  exit 1
fi

xargs -0 zig run scripts/kernel_safety_gate.zig -- < "$list"

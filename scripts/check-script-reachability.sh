#!/usr/bin/env bash
# The completed build graph supplies executable script routes. Mentions in
# source, labels, and comments grant no coverage.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -eq 0 ]; then
  exec zig build test-script-reachability
fi
if [ "$#" -ne 2 ]; then
  echo "usage: bash scripts/check-script-reachability.sh [repo-gate route-census]" >&2
  exit 2
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git ls-files -z 'scripts/*.sh' > "$work/scripts.nul"
"$1" script-reachability "$work/scripts.nul" "$2" scripts/manual-scripts.allow

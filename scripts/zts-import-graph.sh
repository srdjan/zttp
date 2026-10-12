#!/usr/bin/env bash
# Report the tracked relative-import graph inside packages/zts.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -eq 1 ]]; then
  [[ -x "$1" ]] || {
    echo "zts import graph: $1 is not executable" >&2
    exit 1
  }
  exec "$1" import-graph
fi
if [[ $# -ne 0 ]]; then
  echo "usage: bash scripts/zts-import-graph.sh [zts-graph-gate]" >&2
  exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
zig build-exe tooling/zts_graph_gate.zig \
  -femit-bin="$work/zts-graph-gate" \
  --cache-dir "$work/cache" \
  --global-cache-dir "$work/global-cache"
"$work/zts-graph-gate" import-graph

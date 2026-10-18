#!/usr/bin/env bash
# Check scripts/release.sh against the release-script rules and their negative fixtures.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -eq 1 ]]; then
  [[ -x "$1" ]] || {
    echo "release workflow: $1 is not executable" >&2
    exit 1
  }
  exec "$1" release-workflow scripts/release.sh
fi
if [[ $# -ne 0 ]]; then
  echo "usage: bash scripts/test-release-workflow.sh [repo-gate]" >&2
  exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
zig build-exe tooling/repo_gate.zig \
  -femit-bin="$work/repo-gate" \
  --cache-dir "$work/cache" \
  --global-cache-dir "$work/global-cache"
"$work/repo-gate" release-workflow scripts/release.sh

#!/usr/bin/env bash
# Check scripts/release.sh against the release-script rules and their negative fixtures.

set -euo pipefail

cd "$(dirname "$0")/.."

# The build step passes the built repo-gate. No other route runs this script.
if [[ $# -ne 1 ]]; then
  echo "usage: bash scripts/test-release-workflow.sh <repo-gate>; run zig build test-release-workflow" >&2
  exit 1
fi
[[ -x "$1" ]] || {
  echo "release workflow: $1 is not executable" >&2
  exit 1
}
exec "$1" release-workflow scripts/release.sh

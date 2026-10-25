#!/usr/bin/env bash
# Check tier assignment, dependency direction, and root reachability for ZTS.

set -euo pipefail

cd "$(dirname "$0")/.."

# The build step passes the built zts-graph-gate. No other route runs this script.
if [[ $# -ne 1 ]]; then
  echo "usage: bash scripts/check-zts-layering.sh <zts-graph-gate>; run zig build test-zts-layering" >&2
  exit 1
fi
[[ -x "$1" ]] || {
  echo "zts layering: $1 is not executable" >&2
  exit 1
}
exec "$1" layering

#!/usr/bin/env bash
# Stable entry point; executable routes live in tooling/verification_routes.zig.
# The native driver starts a separate process per command, including the two
# pool-heavy test roots. No nested build graph combines their teardown.
set -euo pipefail
cd "$(dirname "$0")/.."
case "$#:$*" in
  0:) ;;
  1:--release) ;;
  2:--release-route\ *) ;;
  *) echo "usage: bash scripts/verify.sh [--release | --release-route TASK]" >&2; exit 2 ;;
esac
exec zig build verify -- "$@"

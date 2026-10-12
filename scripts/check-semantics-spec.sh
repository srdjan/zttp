#!/usr/bin/env bash
# Strict semantics/spec gate for release readiness.
#
# spec-check exits non-zero on any structural or differential divergence.
# spec-render --check exits non-zero when docs/spec/semantics.spec.ts is stale.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -x ./zig-out/bin/zts ]; then
  echo "error: ./zig-out/bin/zts is missing; run 'zig build -Doptimize=ReleaseFast' first" >&2
  exit 1
fi

./zig-out/bin/zts spec-check
./zig-out/bin/zts spec-render --check docs/spec/semantics.spec.ts
echo "semantics spec gate OK"

#!/usr/bin/env bash
# scripts/update-contract-goldens.sh
#
# Regenerate the public-contract golden fixtures that `zig build
# test-contract-golden` checks against. These pin the analyzer's observable
# output for ordinary TypeScript and retained virtual modules, plus three
# enumeration commands.
#
# Their purpose is refactor safety: a change that claims to preserve behavior
# must leave every byte here untouched. Run this ONLY after a DELIBERATE
# contract change, and review the diff before committing - a golden that moves
# without an intended reason means the gate just caught a regression.
#
# Each command mirrors an addExpertGolden entry in build/goldens.zig's
# contract_golden_step.
#
# Usage (from anywhere; the script cd's to the repo root):
#   bash scripts/update-contract-goldens.sh

set -euo pipefail

cd "$(dirname "$0")/.."

FIXTURES="packages/tools/tests/fixtures/contract"
ZTS="./zig-out/bin/zts"

echo ">> building zts"
zig build

echo ">> regenerating fixtures under $FIXTURES"

# `check` exits non-zero for handlers carrying warnings; that exit code is part
# of the pinned contract (see build/goldens.zig), so capture stdout regardless.
for pair in \
  "plain_ts.ts:plain_ts" \
  "modules_all.ts:modules_all"
do
  src="${pair%%:*}"
  base="${pair##*:}"
  echo "   check $src"
  "$ZTS" check "$FIXTURES/$src" --json --contract > "$FIXTURES/$base.contract.golden.json" || true
done

for cmd in features modules restrictions; do
  echo "   $cmd --json"
  "$ZTS" "$cmd" --json > "$FIXTURES/$cmd.golden.json"
done

echo ">> done. Review the diff, then run: zig build test-contract-golden"

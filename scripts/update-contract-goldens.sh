#!/usr/bin/env bash
# scripts/update-contract-goldens.sh
#
# Regenerate the public-contract golden fixtures that `zig build
# test-contract-golden` checks against. These pin the analyzer's observable
# output across a handler set spanning distinct analysis paths (plain TS, JSX,
# every virtual module, durable/workflow) plus the three enumeration commands.
#
# Their purpose is refactor safety: a change that claims to preserve behavior
# must leave every byte here untouched. Run this ONLY after a DELIBERATE
# contract change, and review the diff before committing - a golden that moves
# without an intended reason means the gate just caught a regression.
#
# Each command mirrors an addExpertGolden entry in build.zig's
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
# of the pinned contract (see build.zig), so capture stdout regardless.
for pair in \
  "plain_ts.ts:plain_ts" \
  "jsx.tsx:jsx" \
  "modules_all.ts:modules_all" \
  "durable_approval.ts:durable_approval"
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

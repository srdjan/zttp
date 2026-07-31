#!/usr/bin/env bash
# scripts/check-normalize-idempotent.sh
#
# Double-normalize byte-idempotence over the example corpus (spec 4.2.1: "a
# second `normalize` of canonical source MUST produce identical bytes").
#
# Normalization is a fixed-point computation over rewrite rows that compose, so
# a non-confluent or non-idempotent row is the failure mode that matters. This
# gate runs from Phase 0 rather than from the phase that adds the rows, because
# a rewrite that oscillates is far cheaper to find on the pass that introduces
# it than after a table of them exists.
#
# A file `normalize` refuses (not fully canonical) is skipped, not failed: an
# unrewritable construct is a legal program under spec 4.2.1, and this gate is
# about the rewrite relation, not about corpus canonicality.
#
# Usage: bash scripts/check-normalize-idempotent.sh

set -euo pipefail

cd "$(dirname "$0")/.."

ZTS="./zig-out/bin/zts"
if [ ! -x "$ZTS" ]; then
  echo "error: $ZTS not built. Run: zig build" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

checked=0
skipped=0
failed=0

while IFS= read -r -d '' file; do
  # Pass 1: normalize the original into `once`.
  if ! "$ZTS" normalize "$file" > "$work/once" 2>/dev/null; then
    skipped=$((skipped + 1))
    continue
  fi

  # Pass 2: normalize that output into `twice`. Keep the extension so the
  # stripper picks the same mode for both passes.
  case "$file" in
    *.tsx) ext=tsx ;;
    *) ext=ts ;;
  esac
  cp "$work/once" "$work/pass1.$ext"
  if ! "$ZTS" normalize "$work/pass1.$ext" > "$work/twice" 2>/dev/null; then
    echo "FAIL $file: normalize refused its own output" >&2
    failed=$((failed + 1))
    continue
  fi

  if ! cmp -s "$work/once" "$work/twice"; then
    echo "FAIL $file: second normalize changed bytes" >&2
    diff -u "$work/once" "$work/twice" | head -20 >&2 || true
    failed=$((failed + 1))
    continue
  fi

  checked=$((checked + 1))
done < <(git ls-files -z 'examples/*.ts' 'examples/*.tsx' 'examples/**/*.ts' 'examples/**/*.tsx')

if [ "$failed" -gt 0 ]; then
  echo "normalize idempotence: $failed FAILED ($checked ok, $skipped skipped)" >&2
  exit 1
fi

echo "normalize idempotence OK ($checked files, $skipped skipped as not fully canonical)"

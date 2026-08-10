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
# A file `normalize` refuses is skipped, not failed: an unrewritable construct
# is a legal program under spec 4.2.1, and this gate is about the rewrite
# relation, not about corpus canonicality. A skip prints the file and the reason
# normalize gave, because a skip reported without its reason is read as the
# reason the header happens to name. This gate did that: its one skip was
# `examples/sql/sql-crud.ts` failing with `MissingSqlSchema` - a missing
# argument, so the analysis never ran - and the output called it "not fully
# canonical". A handler with a sibling `schema.sql` is now normalized against
# it, which is what `scripts/test-examples.sh` does for the same file.
#
# MIN_CHECKED is the floor on the gate's own input. A glob that stops matching,
# or a corpus that empties, fails here rather than reporting success over
# nothing.
#
# Usage: bash scripts/check-normalize-idempotent.sh

set -euo pipefail

cd "$(dirname "$0")/.."

ZTS="./zig-out/bin/zts"
if [ ! -x "$ZTS" ]; then
  echo "error: $ZTS not built. Run: zig build" >&2
  exit 1
fi

# The count measured on 2026-08-10, after the SQL handler stopped being skipped.
MIN_CHECKED=58

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

checked=0
skipped=0
failed=0

while IFS= read -r -d '' file; do
  # A `zttp:sql` handler is type-checked against its schema. Without one every
  # pass fails and the file cannot be normalized at all.
  schema="$(dirname "$file")/schema.sql"
  if [ -f "$schema" ]; then
    schema_args=(--sql-schema "$schema")
  else
    schema_args=()
  fi

  # Pass 1: normalize the original into `once`.
  if ! "$ZTS" normalize "$file" "${schema_args[@]+"${schema_args[@]}"}" > "$work/once" 2> "$work/err"; then
    reason="$(head -n 1 "$work/err")"
    echo "SKIP $file: ${reason:-normalize refused with no message}" >&2
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
  if ! "$ZTS" normalize "$work/pass1.$ext" "${schema_args[@]+"${schema_args[@]}"}" > "$work/twice" 2>/dev/null; then
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

if [ "$checked" -lt "$MIN_CHECKED" ]; then
  echo "normalize idempotence: checked $checked files, floor is $MIN_CHECKED" >&2
  echo "  the corpus shrank or the file list stopped matching; this gate proves nothing below its floor" >&2
  exit 1
fi

if [ "$skipped" -gt 0 ]; then
  echo "normalize idempotence OK ($checked files, $skipped skipped; each reason above)"
else
  echo "normalize idempotence OK ($checked files, no skips)"
fi

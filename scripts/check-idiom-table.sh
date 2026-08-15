#!/usr/bin/env bash
# scripts/check-idiom-table.sh
#
# Spec 4.2.1 says of its idiom table: "The table is registry-generated and
# drift-gated; this document is its readable view." This is that gate.
#
# It compares the document's table to `packages/zts/src/idiom_registry.zig` row
# for row and column for column, in order. Order is part of the comparison
# because the registry's published `idiom_table_hash` walks the rows in array
# order, so two tables carrying the same rows in different orders are two
# different published tables.
#
# Two conveniences of the readable view are resolved before comparing, and
# nothing else is normalized: a wording difference is drift, which is the point.
#
# Code spans lose their delimiters, because the registry stores bare text. A
# double-backtick span keeps its contents verbatim, since that is how the
# document writes a template literal whose own backticks are part of the value:
# `` `${n}` `` is the string "`${n}`" and not "${n}".
#
# A cell reading exactly "same as above" takes the previous row's value in that
# column. The document may say it and the registry may not: a machine consumer
# reads one row and has no previous row to resolve against.
#
# Floor: the extraction must find at least MIN_ROWS rows on each side before any
# comparison verdict means anything. A table that stops matching the awk range,
# or a registry whose field names change, would otherwise compare an empty list
# against an empty list and pass.
#
# Usage: bash scripts/check-idiom-table.sh

set -euo pipefail

cd "$(dirname "$0")/.."

spec_doc="docs/zts-formal-spec-northstar-advanced.md"
registry_file="packages/zts/src/idiom_registry.zig"

# The row count measured on 2026-08-15 after template interpolation and string
# addition left the language, together with their competing text preferences.
MIN_ROWS=21

fail() {
  printf 'idiom table drift: %s\n' "$1" >&2
  exit 1
}

[[ -f "$spec_doc" ]] || fail "missing $spec_doc"
[[ -f "$registry_file" ]] || fail "missing $registry_file"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The document's table: the rows between the 4.2.1 heading and the next heading,
# minus the header row and the alignment row. Four columns: operation,
# idiomatic, non-idiomatic, precondition.
awk -F '|' '
  # Drop code-span delimiters. A run of two or more backticks opens a span
  # whose contents are copied byte for byte, including single backticks; a
  # lone backtick outside such a span is a delimiter and is dropped.
  function unspan(s,   i, n, c, out, run, verbatim) {
    n = length(s)
    out = ""
    verbatim = 0
    i = 1
    while (i <= n) {
      c = substr(s, i, 1)
      if (c != "`") { out = out c; i++; continue }
      run = 0
      while (i + run <= n && substr(s, i + run, 1) == "`") run++
      if (run >= 2) {
        verbatim = !verbatim
        i += run
      } else if (verbatim) {
        out = out c
        i++
      } else {
        i++
      }
    }
    return out
  }
  function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
  /^#### 4\.2\.1 / { in_table = 1; next }
  /^#{1,4} / && in_table { exit }
  in_table && /^\|/ {
    if ($2 ~ /^ *Operation *$/) next
    if ($2 ~ /^ *-+ *$/) next
    out = ""
    for (i = 2; i <= 5; i++) {
      cell = trim(unspan($i))
      if (cell == "same as above") cell = previous[i]
      previous[i] = cell
      out = out (i == 2 ? "" : "\t") cell
    }
    print out
  }
' "$spec_doc" > "$work/doc.tsv"

# The registry: one record per entry, same four columns in the same order.
awk '
  /^pub const entries = / { in_entries = 1; next }
  in_entries && /^};/ { exit }
  in_entries && /^        \.operation = / { operation = value($0) }
  in_entries && /^        \.idiomatic = / { idiomatic = value($0) }
  in_entries && /^        \.superseded = / { superseded = value($0) }
  in_entries && /^        \.precondition = / {
    printf "%s\t%s\t%s\t%s\n", operation, idiomatic, superseded, value($0)
  }
  function value(line,   s) {
    s = line
    sub(/^[^"]*"/, "", s)
    sub(/",$/, "", s)
    gsub(/\\"/, "\"", s)
    return s
  }
' "$registry_file" > "$work/registry.tsv"

doc_rows=$(wc -l < "$work/doc.tsv" | tr -d ' ')
registry_rows=$(wc -l < "$work/registry.tsv" | tr -d ' ')

[[ "$doc_rows" -ge "$MIN_ROWS" ]] ||
  fail "extracted $doc_rows rows from $spec_doc, floor is $MIN_ROWS; the table markup moved and this gate would compare nothing"
[[ "$registry_rows" -ge "$MIN_ROWS" ]] ||
  fail "extracted $registry_rows rows from $registry_file, floor is $MIN_ROWS; the entry shape moved and this gate would compare nothing"

if ! diff -u "$work/doc.tsv" "$work/registry.tsv" > "$work/diff"; then
  echo "idiom table drift: the document and the registry disagree" >&2
  echo "  - is $spec_doc, + is $registry_file" >&2
  sed -n '3,$p' "$work/diff" >&2
  exit 1
fi

echo "idiom table OK ($registry_rows rows, document and registry identical)"

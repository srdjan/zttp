#!/usr/bin/env bash
# scripts/check-grammar-drift.sh
#
# Spec 4.8 requires `meta.payload.grammar` to publish section 8's productions
# "member for member, registry-generated and drift-gated". This is that gate.
#
# It compares the document's EBNF block to `packages/zts/src/grammar_registry.zig`
# production by production, in document order. Order is part of the comparison:
# the document reads top down, and a client that renders the published grammar
# back out should get the document's shape rather than a permutation of it.
#
# One normalization is applied to the document side and nothing else: a
# production's right-hand side has its continuation lines joined and runs of
# whitespace collapsed to one space, because the document aligns its `::=` for
# reading and the registry stores one line. A wording difference is drift, which
# is the point.
#
# Floor: both extractions must find at least MIN_ROWS productions before any
# verdict means anything. A document whose fence label changes, or a registry
# whose field names change, would otherwise compare an empty list against an
# empty list and pass while checking nothing.
#
# Usage: bash scripts/check-grammar-drift.sh

set -euo pipefail

cd "$(dirname "$0")/.."

spec_doc="docs/zts-formal-spec-northstar-advanced.md"
registry_file="packages/zts/src/grammar_registry.zig"

# The production count measured on 2026-08-12, when phase 7 added the
# `structural` and `nominal` declarations.
MIN_ROWS=71

fail() {
  printf 'grammar drift: %s\n' "$1" >&2
  exit 1
}

[[ -f "$spec_doc" ]] || fail "missing $spec_doc"
[[ -f "$registry_file" ]] || fail "missing $registry_file"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The document: the ebnf fence inside section 8. A production runs from its
# `::=` to the next one, so continuation lines - the aligned alternatives - are
# folded into the production they belong to.
awk '
  /^## 8\. Compact grammar/ { in_section = 1 }
  in_section && /^```ebnf/ { in_block = 1; next }
  in_block && /^```/ { exit }
  !in_block { next }
  function flush() {
    if (name == "") return
    gsub(/[ \t]+/, " ", rhs)
    sub(/^ /, "", rhs)
    sub(/ $/, "", rhs)
    printf "%s\t%s\n", name, rhs
  }
  /::=/ {
    flush()
    idx = index($0, "::=")
    name = substr($0, 1, idx - 1)
    gsub(/^[ \t]+|[ \t]+$/, "", name)
    rhs = substr($0, idx + 3)
    next
  }
  /^[ \t]*$/ { next }
  { rhs = rhs " " $0 }
  END { flush() }
' "$spec_doc" > "$work/doc.tsv"

# The registry: one record per production, in array order. `zig fmt` puts each
# field on its own line, so a row is read as a `.name` line followed by a `.rhs`
# line. `.rhs` is stored already normalized, and a Zig test in the registry fails
# on a row that is not, so this side needs only its escapes undone.
awk '
  /^pub const productions = \[_\]Production\{/ { in_rows = 1; next }
  in_rows && /^};/ { exit }
  in_rows && /\.name = "/ { name = field($0, "name"); next }
  in_rows && /\.rhs = "/ {
    printf "%s\t%s\n", name, field($0, "rhs")
    name = ""
    next
  }
  function field(line, key,   s, i, out, c, esc) {
    i = index(line, "." key " = \"")
    if (i == 0) return ""
    s = substr(line, i + length(key) + 5)
    out = ""
    esc = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (esc) { out = out c; esc = 0; continue }
      if (c == "\\") { esc = 1; continue }
      if (c == "\"") break
      out = out c
    }
    return out
  }
' "$registry_file" > "$work/registry.tsv"

doc_rows=$(wc -l < "$work/doc.tsv" | tr -d ' ')
registry_rows=$(wc -l < "$work/registry.tsv" | tr -d ' ')

[[ "$doc_rows" -ge "$MIN_ROWS" ]] ||
  fail "extracted $doc_rows productions from $spec_doc, floor is $MIN_ROWS; the block markup moved and this gate would compare nothing"
[[ "$registry_rows" -ge "$MIN_ROWS" ]] ||
  fail "extracted $registry_rows productions from $registry_file, floor is $MIN_ROWS; the row shape moved and this gate would compare nothing"

if ! diff -u "$work/doc.tsv" "$work/registry.tsv" > "$work/diff"; then
  echo "grammar drift: the document and the registry disagree" >&2
  echo "  - is $spec_doc, + is $registry_file" >&2
  sed -n '3,$p' "$work/diff" >&2
  exit 1
fi

echo "grammar OK ($registry_rows productions, document and registry identical)"

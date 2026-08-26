#!/usr/bin/env bash
# scripts/check-canonical-style.sh
#
# The `canonical-style` expert skill teaches the one-way profile by example. Its
# before/after pairs restate what the rule registry already says, so the same
# claim lived in two places and drifted: the ZTS612 pair carried
# `const status = ok ? 200 : 500;` as the form to avoid, which is a pure two-way
# selection - the spelling idiom_registry's `idiom.two-way-pure-selection`
# actually prefers, and one that trips no diagnostic at all. The skill taught
# models away from the canonical form and cited a rule that would not fire.
#
# This gate makes that impossible. For every `### Title (ZTSnnn)` section in the
# skill:
#
#   1. every code it cites must exist, either as a rule_registry row or as a
#      restriction_registry `enforced_by` code, and
#   2. when the citing section is a single code and the rule registry carries an
#      `.example` for it, that example must appear verbatim inside the section's
#      `// before` block.
#
# Rule (2) is containment rather than equality so a section may show more than
# one instance of a rule (ZTS620 shows both the `=== true` and `=== false`
# forms), while still pinning the registry's own example as the anchor.
#
# What this gate does NOT cover, so it is not cited for more than it checks: the
# prose "Canonical forms" table, the sections with no ZTS code in the heading,
# and the "Working rules for the agent" list. Those are hand-written and no
# registry field states them. Three of them were wrong at the time this gate was
# written and were fixed by hand in the same commit.
#
# Floor: the extraction must find at least MIN_SECTIONS labelled sections and
# MIN_EXAMPLES registry examples before any verdict means anything. A heading
# style change, or a registry whose field names move, would otherwise compare an
# empty list against an empty list and report a pass.
#
# Usage: bash scripts/check-canonical-style.sh

set -euo pipefail

cd "$(dirname "$0")/.."

skill="packages/pi/src/skills/canonical-style.md"
rules="packages/zts/src/rule_registry.zig"
restrictions="packages/zts/src/restriction_registry.zig"

# Measured 2026-08-26: 10 sections carry a code in the heading, and 9 of the
# codes they cite have a rule_registry example (ZTS054 and ZTS055 are
# restriction codes and carry none).
MIN_SECTIONS=10
MIN_EXAMPLES=9

fail() {
  printf 'canonical-style drift: %s\n' "$1" >&2
  exit 1
}

for f in "$skill" "$rules" "$restrictions"; do
  [[ -f "$f" ]] || fail "missing $f"
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Every code the registries define. rule_registry rows carry `.code = "ZTSnnn"`;
# restriction_registry rows name theirs in `.enforced_by = &.{"ZTSnnn"}`.
{
  grep -oE '\.code = "ZTS[0-9]+"' "$rules" | grep -oE 'ZTS[0-9]+'
  grep -oE '"ZTS[0-9]+"' "$restrictions" | grep -oE 'ZTS[0-9]+'
} | sort -u > "$work/known.txt"

[[ -s "$work/known.txt" ]] ||
  fail "extracted no codes from the registries; the row shape moved and this gate would check nothing"

# The registry's example per code, as CODE<TAB>example. A row with `.example =
# null` contributes nothing.
awk '
  function value(line,   s) {
    s = line
    sub(/^[^"]*"/, "", s)
    sub(/",$/, "", s)
    gsub(/\\"/, "\"", s)
    return s
  }
  /^        \.code = "ZTS[0-9]+",$/ { code = value($0); next }
  /^        \.example = "/ { if (code != "") printf "%s\t%s\n", code, value($0); code = "" }
' "$rules" | sort -u > "$work/examples.tsv"

example_count=$(wc -l < "$work/examples.tsv" | tr -d ' ')
[[ "$example_count" -ge "$MIN_EXAMPLES" ]] ||
  fail "extracted $example_count registry examples, floor is $MIN_EXAMPLES; the row shape moved and this gate would compare nothing"

# Each labelled section: its heading, its codes, and its `// before` block. The
# before block runs from the `// before` marker to the `// after` marker (or the
# closing fence, whichever comes first).
awk '
  function flush() {
    if (heading != "") printf "%s\t%s\t%s\n", heading, codes, before
    heading = ""; codes = ""; before = ""; in_before = 0
  }
  /^### / {
    flush()
    line = $0
    n = 0
    tmp = line
    while (match(tmp, /ZTS[0-9]+/)) {
      c = substr(tmp, RSTART, RLENGTH)
      codes = (codes == "" ? c : codes " " c)
      tmp = substr(tmp, RSTART + RLENGTH)
      n++
    }
    if (n > 0) heading = line
    next
  }
  heading == "" { next }
  /^\/\/ before/ { in_before = 1; next }
  /^\/\/ after/  { in_before = 0; next }
  /^```/         { in_before = 0; next }
  # One record per section: the before block is flattened to a single line so a
  # multi-line block cannot split the record and silently drop the rest of it.
  in_before      { before = (before == "" ? $0 : before " " $0) }
  END { flush() }
' "$skill" > "$work/sections.tsv"

section_count=$(wc -l < "$work/sections.tsv" | tr -d ' ')
[[ "$section_count" -ge "$MIN_SECTIONS" ]] ||
  fail "extracted $section_count labelled sections from $skill, floor is $MIN_SECTIONS; the heading markup moved and this gate would check nothing"

checked_examples=0
while IFS=$'\t' read -r heading codes before; do
  for code in $codes; do
    grep -qx "$code" "$work/known.txt" ||
      fail "$heading cites $code, which no registry row defines"
  done

  # One code in the heading pins one example. A section citing several codes
  # (ZTS054 and ZTS055) shows one combined form and is checked for existence
  # only; saying which example must appear would be an invention, not a claim
  # either registry makes.
  set -- $codes
  [[ $# -eq 1 ]] || continue
  example=$(awk -F'\t' -v c="$1" '$1 == c { print $2; exit }' "$work/examples.tsv")
  [[ -n "$example" ]] || continue

  if [[ "$before" != *"$example"* ]]; then
    {
      echo "canonical-style drift: the before block under"
      echo "  $heading"
      echo "does not contain the rule registry's own example for $1."
      echo "  registry ($rules): $example"
      echo "  skill    ($skill): $before"
      echo "The skill and the registry are describing different code for the same"
      echo "rule. Fix whichever is wrong; do not restate the claim a third way."
    } >&2
    exit 1
  fi
  checked_examples=$((checked_examples + 1))
done < "$work/sections.tsv"

# Second floor: the loop above can walk every section and still compare nothing
# if the before-block extraction silently yields empty strings.
[[ "$checked_examples" -ge "$MIN_EXAMPLES" ]] ||
  fail "compared $checked_examples before blocks against registry examples, floor is $MIN_EXAMPLES; the fence or comment markers moved"

echo "canonical-style OK ($section_count labelled sections, $checked_examples before blocks match their registry example)"

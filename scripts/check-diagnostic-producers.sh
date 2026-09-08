#!/usr/bin/env bash
#
# Every advertised diagnostic variant must have a producer.
#
# `handler_verifier.DiagnosticKind` carried three variants -
# `spec_not_discharged`, `spec_incompatible_with_import`, `spec_unknown_name` -
# that no code path ever constructed. They were not harmless dead surface: each
# named a live code (ZTS500/501/502) that `spec_discharge.zig` emits through a
# DIFFERENT enum, and the rule-coverage gate in packages/pi keys on `rule.code`.
# A row sharing a code with a live producer is permanently satisfied, so the
# mechanism that caught the nineteen-row drift in scripts/unseeded-rules.allow
# could not see this shape at all.
#
# A dead variant in a hashed policy surface is a false advertisement: the
# registry publishes a rule, and no execution order can surface it. The
# allowlist header in scripts/unseeded-rules.allow records seventeen rows
# deleted for exactly that reason.
#
# So this gate asks the question the code-keyed one cannot: does anything
# CONSTRUCT each variant? The registry and the catalog are excluded, because
# naming a variant in a table is what a dead variant does too - the whole point
# is to look for a construction site somewhere else.

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf 'diagnostic producers: %s\n' "$1" >&2
  exit 1
}

# Files that MENTION a variant without producing one. A variant that appears
# only here is dead.
declare -a excluded=(
  packages/zts/src/rule_registry.zig
  packages/zts/src/diagnostic_catalog.zig
)

# Each entry is "<file>:<enum name>".
declare -a enums=(
  "packages/zts/src/handler_verifier.zig:DiagnosticKind"
  "packages/zts/src/flow_checker.zig:DiagnosticKind"
)

# Every tracked .zig file is a candidate producer. `git ls-files -z | xargs -0`
# so a path with a space cannot silently drop out of the scan and shrink the
# very set this gate searches.
scanned_files="$(git ls-files -z 'packages/*.zig' | xargs -0 -n1 echo | grep -c . || true)"
[[ "$scanned_files" -ge 50 ]] || fail "only $scanned_files tracked .zig files under packages/; the file scan is broken, and a search over nothing reports every variant dead or alive at random"

# True when at least one file OUTSIDE the excluded list constructs $1.
has_producer() {
  local variant="$1" hits
  hits="$(git ls-files -z 'packages/*.zig' | xargs -0 grep -lE "\.kind = \.${variant}([^A-Za-z0-9_]|$)" || true)"
  [[ -n "$hits" ]] || return 1
  local f
  while read -r f; do
    [[ -n "$f" ]] || continue
    local skip=0 x
    for x in "${excluded[@]}"; do
      [[ "$f" == "$x" ]] && skip=1
    done
    [[ "$skip" -eq 0 ]] && return 0
  done < <(printf '%s\n' "$hits")
  return 1
}

checked=0
dead=0

for entry in "${enums[@]}"; do
  file="${entry%%:*}"
  enum_name="${entry##*:}"
  [[ -f "$file" ]] || fail "listed file $file does not exist; update this gate"

  # Variant names between `pub const <enum_name> = enum {` and its closing `};`.
  variants="$(
    awk -v name="$enum_name" '
      $0 ~ ("pub const " name " = enum") { inside = 1; next }
      inside && /^};/ { inside = 0 }
      inside && match($0, /^[[:space:]]*[a-z][a-z0-9_]*,/) {
        v = substr($0, RSTART, RLENGTH)
        gsub(/[[:space:],]/, "", v)
        print v
      }
    ' "$file"
  )"

  count="$(printf '%s\n' "$variants" | grep -c . || true)"
  # Floor on this gate's own input. An enum whose variants stopped being
  # extracted answers "every variant has a producer" over an empty set.
  [[ "$count" -ge 5 ]] || fail "extracted only $count variants from $file $enum_name; the parse is broken, and an empty set satisfies the check below while proving nothing"

  while read -r variant; do
    [[ -n "$variant" ]] || continue
    checked=$((checked + 1))
    if ! has_producer "$variant"; then
      printf 'diagnostic producers: %s.%s is advertised and nothing constructs it\n' "$enum_name" "$variant" >&2
      dead=$((dead + 1))
    fi
  done < <(printf '%s\n' "$variants")
done

if [[ "$dead" -gt 0 ]]; then
  printf 'Delete the variant and re-key its registry row on the enum that emits the code, or wire the producer.\n' >&2
  exit 1
fi

printf 'diagnostic producers: OK (%d variants, each constructed outside the registry and catalog)\n' "$checked"

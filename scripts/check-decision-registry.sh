#!/usr/bin/env bash
# scripts/check-decision-registry.sh
#
# `meta.payload.decisions` publishes the kinds a client keys on. One direction
# of that claim is enforced by the compiler: every refusal is written from the
# `decision_registry.Id` enum, so a kind on the wire that the registry does not
# carry does not build.
#
# This is the other direction. A row nothing emits is a kind the protocol
# advertises and never sends - a client writing a branch for it waits forever,
# and the published list reads as larger coverage than the code has. Zig will
# not catch it: an unused pub enum member is not an error.
#
# Every member of `Id` must appear as `.<member>` at a call site outside the
# registry file itself.
#
# Floor: the member count and the searched-file count are both asserted before
# any verdict means anything. A rename of the enum, or a moved emitter, would
# otherwise scan nothing and report success.
#
# Usage: bash scripts/check-decision-registry.sh

set -euo pipefail

cd "$(dirname "$0")/.."

registry="packages/tools/src/decision_registry.zig"

# Measured on 2026-08-12, when the registry was written.
MIN_MEMBERS=10

fail() {
  printf 'decision registry: %s\n' "$1" >&2
  exit 1
}

[[ -f "$registry" ]] || fail "missing $registry"

members="$(
  awk '
    /^pub const Id = enum \{/ { in_enum = 1; next }
    in_enum && /^\};/ { exit }
    in_enum && /^    [a-z_]+,$/ {
      name = $1
      sub(/,$/, "", name)
      print name
    }
  ' "$registry"
)"

member_count="$(printf '%s\n' "$members" | grep -c . || true)"
[[ "$member_count" -ge "$MIN_MEMBERS" ]] ||
  fail "extracted $member_count members from Id, floor is $MIN_MEMBERS; the enum moved and this gate would check nothing"

# Every tracked Zig source except the registry itself. `git ls-files` so a file
# that is not tracked cannot satisfy the gate.
sources_file="$(mktemp)"
trap 'rm -f "$sources_file"' EXIT
git ls-files -z 'packages/*.zig' 'packages/**/*.zig' |
  tr '\0' '\n' |
  grep -v "^${registry}$" > "$sources_file"

source_count="$(grep -c . "$sources_file" || true)"
[[ "$source_count" -ge 50 ]] ||
  fail "found $source_count source files to search, which is too few; the glob moved and this gate would check nothing"

unused=""
while IFS= read -r member; do
  [[ -n "$member" ]] || continue
  if ! tr '\n' '\0' < "$sources_file" | xargs -0 grep -l -- "\.${member}[^a-z_]" > /dev/null 2>&1; then
    unused="${unused}${member}"$'\n'
  fi
done <<< "$members"

if [[ -n "${unused//[[:space:]]/}" ]]; then
  printf 'decision registry: these kinds are published and never emitted:\n' >&2
  printf '%s' "$unused" | sed 's/^/  /' >&2
  printf 'Emit the kind, or delete its row: a client cannot branch on a refusal that never arrives.\n' >&2
  exit 1
fi

echo "decision registry OK ($member_count kinds, each emitted at least once)"

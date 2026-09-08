#!/usr/bin/env bash
#
# Every script in scripts/ must be invoked by something, or say why not.
#
# A gate that nothing runs reports no failures, which is indistinguishable from
# a gate that found none - and the difference only shows up when somebody cites
# it as evidence. scripts/test-zruntime.sh sat in the tree invoking
# `zig test` on packages/runtime/src/zruntime.zig, a file that had been deleted
# in the monorepo restructure; nothing called it, so nothing noticed. The real
# path had become `zig build test-zruntime`, which scripts/verify.sh runs.
#
# This is the same shape as the exclusion that motivated the gate:
# scripts/test-examples.sh was documented as outside `zig build test` and run
# only from verify.sh, so `zig build test` reported a pass while 56 example
# suites went unrun. Being driven by a shell script is a reason to wire the
# script in, not a reason to leave it out.
#
# Enforced in both directions. An unreferenced script with no row in
# scripts/manual-scripts.allow fails, so a gate cannot be written and wired
# nowhere; and a row for a script something now invokes fails, so the list
# shrinks with the tree instead of rotting into fiction.

set -euo pipefail

cd "$(dirname "$0")/.."

allow_file="scripts/manual-scripts.allow"

fail() {
  printf 'script reachability: %s\n' "$1" >&2
  exit 1
}

[[ -f "$allow_file" ]] || fail "missing $allow_file"

# Where an invocation can legitimately come from. A script referenced only by
# itself does not count, which is what makes self-reference in a usage string
# harmless.
search_roots=(build.zig scripts .github)
for root in "${search_roots[@]}"; do
  [[ -e "$root" ]] || fail "search root '$root' does not exist; this gate would look for invocations in fewer places than it claims"
done

# `git ls-files -z | xargs -0` so a path with a space cannot drop out of the
# scan and shrink the set being checked.
scripts_list="$(git ls-files -z 'scripts/*.sh' | xargs -0 -n1 echo)"
script_count="$(printf '%s\n' "$scripts_list" | grep -c . || true)"
# Floor on this gate's own input. Over an empty list every check below passes.
[[ "$script_count" -ge 20 ]] || fail "found only $script_count scripts under scripts/; the file scan is broken and the checks below would pass over nothing"

allowed_rows="$(sed 's/#.*$//' "$allow_file" | grep -v '^[[:space:]]*$' | sed 's/[[:space:]]*$//' || true)"
allowed_names="$(printf '%s\n' "$allowed_rows" | awk '{print $1}' | sort -u)"

is_allowed() {
  printf '%s\n' "$allowed_names" | grep -qx "$1"
}

# True when something other than the script itself, or the allowlist that
# excuses it, names it. Both exclusions matter: a usage string in the script's
# own header is not a caller, and neither is the row in
# scripts/manual-scripts.allow - which lives under scripts/ and would otherwise
# make every allowlisted script look invoked by the file that excuses it.
#
# A mention in docs/ is not a caller either, which is why docs/ is not a search
# root. Documentation describing a command a developer types is exactly the
# manual case this gate asks to have declared, not evidence of automation.
has_caller() {
  local base="$1" hits
  hits="$(grep -rl --fixed-strings "$base" "${search_roots[@]}" 2>/dev/null || true)"
  local f
  while read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$f" == "scripts/$base" ]] && continue
    [[ "$f" == "$allow_file" ]] && continue
    return 0
  done < <(printf '%s\n' "$hits")
  return 1
}

unreferenced=0
stale=0
checked=0

while read -r path; do
  [[ -n "$path" ]] || continue
  base="$(basename "$path")"
  checked=$((checked + 1))
  if has_caller "$base"; then
    if is_allowed "$base"; then
      printf 'script reachability: %s is listed in %s as run by hand, but something invokes it now; delete the row\n' "$base" "$allow_file" >&2
      stale=$((stale + 1))
    fi
  else
    if ! is_allowed "$base"; then
      printf 'script reachability: nothing invokes %s and %s does not say why\n' "$base" "$allow_file" >&2
      unreferenced=$((unreferenced + 1))
    fi
  fi
done < <(printf '%s\n' "$scripts_list")

# A row naming a script that no longer exists is a claim about nothing.
while read -r name; do
  [[ -n "$name" ]] || continue
  [[ -f "scripts/$name" ]] || {
    printf 'script reachability: %s lists %s, which does not exist\n' "$allow_file" "$name" >&2
    stale=$((stale + 1))
  }
done < <(printf '%s\n' "$allowed_names")

if [[ "$unreferenced" -gt 0 || "$stale" -gt 0 ]]; then
  printf 'Wire the script into build.zig or scripts/verify.sh, delete it, or add a row with the reason it is run by hand.\n' >&2
  exit 1
fi

allow_count="$(printf '%s\n' "$allowed_names" | grep -c . || true)"
printf 'script reachability: OK (%d scripts, %d run by hand with a stated reason)\n' "$checked" "$allow_count"

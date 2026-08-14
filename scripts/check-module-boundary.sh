#!/usr/bin/env bash
#
# Module boundary gate.
#
# `packages/zts/src/root.zig` re-exports two tiers: a small curated surface
# (JSValue, Context, strip, ...) and a larger set of internal implementation
# modules that exist only so the in-repo runtime, tools, and pi packages can
# share code. This check counts the second tier from root.zig and prints the
# live number on success, so no count is written down here to go stale.
# The header calls the second tier internal, but nothing enforced it, so every
# consumer reached in freely.
#
# This gate pins the reach. `scripts/module-boundary.allow` lists exactly which
# internal modules each consumer package may name, and the check fails in both
# directions:
#
#   - a new (package, module) pair that is not listed fails, so widening the
#     surface is a deliberate edit rather than a side effect;
#   - a listed pair that nothing uses any more fails, so the allowlist shrinks
#     as the surface does and never rots into fiction.
#
# The curated surface is not gated: reaching for `zts.Context` is the supported
# way to embed the engine. Only the internal tier is counted.
#
# This is the enforcement half of the "curated zts / zts-compiler /
# zts-contracts modules" item. This header used to price the other half at
# "rewiring 36 of the 84 files in packages/zts/src off relative imports". Both
# numbers went stale, and the import rewiring was never the blocker. Run
# `bash scripts/zts-import-graph.sh` for the live figures and
# `docs/plans/2026-08-07-021-zts-three-module-split-plan.md` for what the split
# costs: the package is one cyclic import graph, its engine entry points reach
# every file in it, and a cycle spanning a module line is exactly what makes
# Zig analyze the engine twice and turn one type into two incompatible ones.
# The cycles come first, the import rewiring second. The allowlist freezes the
# surface meanwhile; the physical split stays available.

set -euo pipefail

cd "$(dirname "$0")/.."

allow_file="scripts/module-boundary.allow"
root_file="packages/zts/src/root.zig"

fail() {
  printf 'module boundary: %s\n' "$1" >&2
  exit 1
}

[[ -f "$allow_file" ]] || fail "missing $allow_file"
[[ -f "$root_file" ]] || fail "missing $root_file"

# The internal tier, read from root.zig itself: every `pub const <lowercase> =
# <tier>.<module>;` between the internal banner and the curated banner that
# follows it. Curated entries are UpperCamelCase types or plain functions, and
# are deliberately not matched here.
#
# root.zig used to spell these `= @import("value.zig")`. It is the `zts`
# umbrella now and spells them `= engine.value`, `= compiler.flow_checker`, and
# so on, one per tier module. The pattern moved with it. The floor below is what
# caught the change rather than letting the gate quietly parse nothing: see
# docs/plans/2026-08-07-021-zts-three-module-split-plan.md.
internals="$(
  awk '
    /^\/\/ Internal implementation modules/ { in_section = 1 }
    in_section && /^\/\/ =+$/ && seen_entry { exit }
    in_section && match($0, /^pub const [a-z_][a-z0-9_]* *= (base|contracts|engine|compiler)\./) {
      seen_entry = 1
      line = $0
      sub(/^pub const /, "", line)
      sub(/ *=.*$/, "", line)
      print line
    }
  ' "$root_file" | sort -u
)"

internal_count="$(printf '%s\n' "$internals" | grep -c . || true)"
[[ "$internal_count" -ge 40 ]] ||
  fail "only $internal_count internal modules parsed from $root_file; the file layout changed"

# Every name a file reaches through the `zts` module, whatever it aliased the
# import to. Handles `const zts = @import("zts")`, `const zq = @import("zts")`,
# and the destructured `const compat = @import("zts").compat`.
names_used_in() {
  awk '
    match($0, /@import\("zts"\)\.[A-Za-z_][A-Za-z0-9_]*/) {
      field = substr($0, RSTART + 15, RLENGTH - 15)
      print field
    }
    match($0, /^ *const [A-Za-z_][A-Za-z0-9_]* *= *@import\("zts"\) *;/) {
      line = $0
      sub(/^ *const /, "", line)
      sub(/ *=.*$/, "", line)
      aliases[line] = 1
    }
    {
      for (alias in aliases) {
        rest = $0
        while (match(rest, "(^|[^A-Za-z0-9_.])" alias "\\.[A-Za-z_][A-Za-z0-9_]*")) {
          hit = substr(rest, RSTART, RLENGTH)
          sub(/^[^A-Za-z_]*/, "", hit)
          sub(/^[A-Za-z_][A-Za-z0-9_]*\./, "", hit)
          print hit
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
    }
  ' "$1"
}

# Every tracked Zig file in the package, not only `src/`. Scanning `src/` alone
# left `packages/runtime/bench/*.zig` outside the gate, and those files reach
# zts internals from code `zig build bench` compiles - one of them reached an
# internal no row allowed while the gate still printed OK.
used_pairs="$(
  for pkg in runtime tools pi modules proof-review zttp-sdk; do
    [[ -d "packages/$pkg" ]] || continue
    while IFS= read -r -d '' file; do
      # `git ls-files` still reports an unstaged deletion. Skip paths that are
      # absent from the working tree so a cleanup diff cannot make awk fail
      # noisily while the gate continues with a false-looking success log.
      [[ -f "$file" ]] || continue
      names_used_in "$file"
    done < <(git ls-files -z "packages/$pkg/*.zig") |
      sort -u |
      while IFS= read -r name; do
        printf '%s\n' "$internals" | grep -qx -- "$name" || continue
        printf '%s %s\n' "$pkg" "$name"
      done
  done | sort -u
)"

# Trailing whitespace is stripped after the comment strip, matching
# check-proof-swallow.sh. Without it a row written `pkg name # why` becomes
# `pkg name ` and matches nothing, so the same row is reported as an unallowed
# reach and as a stale allowlist entry at once. Loud, but it names the wrong two
# problems.
allowed_pairs="$(sed 's/#.*$//' "$allow_file" | sed 's/[[:space:]]*$//' | grep -v '^[[:space:]]*$' | sort -u || true)"

new_reach="$(comm -23 <(printf '%s\n' "$used_pairs") <(printf '%s\n' "$allowed_pairs") || true)"
if [[ -n "${new_reach//[[:space:]]/}" ]]; then
  printf 'module boundary: these packages reach a zts internal that %s does not allow:\n' "$allow_file" >&2
  printf '%s\n' "$new_reach" | sed 's/^/  /' >&2
  printf 'Use the curated surface in %s, or add the row deliberately.\n' "$root_file" >&2
  exit 1
fi

stale="$(comm -13 <(printf '%s\n' "$used_pairs") <(printf '%s\n' "$allowed_pairs") || true)"
if [[ -n "${stale//[[:space:]]/}" ]]; then
  printf 'module boundary: %s allows internals nothing uses any more:\n' "$allow_file" >&2
  printf '%s\n' "$stale" | sed 's/^/  /' >&2
  printf 'Delete those rows: the allowlist only ratchets down.\n' >&2
  exit 1
fi

pair_count="$(printf '%s\n' "$used_pairs" | grep -c . || true)"
printf 'module boundary: OK (%s internal modules, %s allowed package reaches)\n' \
  "$internal_count" "$pair_count"

#!/usr/bin/env bash
#
# Fail-open gate for the proof pipeline.
#
# The files listed in `proof_files` below decide whether a program is reported
# as proven. In code like that, a swallowed error or an early return that
# leaves an analysis result weaker than it should be does not surface as a
# failure - it surfaces as a pass. Three such paths shipped: a non-literal
# `Effects<...>` ceiling extracted zero names and read as "no annotation", a
# `zttp-ext:` module contributed no capabilities at all, and a call through an
# unresolvable value left the effect row untouched. Each one moved unproven
# programs into the reported provable set. A taint fail-open in this repo once
# survived fourteen review passes, so this class of defect is proven to evade
# reading the diff.
#
# This gate makes the count reviewable instead of assumed. Every swallow
# pattern in the proof pipeline must appear in `scripts/proof-swallow.allow`
# with a reason, and the check fails in both directions:
#
#   - an unlisted swallow fails, so a new one is a deliberate edit with a
#     written reason rather than a line nobody looked at;
#   - a listed swallow that no longer exists fails, so the allowlist shrinks
#     with the code and never rots into fiction.
#
# Every row is a swallow someone read and found sound. A row whose reason says
# it fails open is a bug, not an exemption: fix it or the count is a lie.
#
# The key is (file, enclosing function, pattern) rather than a line number, so
# the list survives edits above it. Renaming the function invalidates the row,
# which is the point - a rename is when the reason deserves re-reading.

set -euo pipefail

cd "$(dirname "$0")/.."

allow_file="scripts/proof-swallow.allow"

# The analysis pipeline: everything between the parsed IR and the verdict a
# build reports. A file added here without its swallows listed fails the gate,
# which is the intended way to bring new analysis code under review.
proof_files=(
  packages/zts/src/contract_builder.zig
  packages/zts/src/effect_inference.zig
  packages/zts/src/fault_coverage.zig
  packages/zts/src/flow_checker.zig
  packages/zts/src/function_specs.zig
  packages/zts/src/handler_contract.zig
  packages/zts/src/handler_verifier.zig
  packages/zts/src/intent_extractor.zig
  packages/zts/src/spec_discharge.zig
  packages/zts/src/type_checker.zig
  packages/zts/src/type_env.zig
)

fail() {
  printf 'proof swallow: %s\n' "$1" >&2
  exit 1
}

[[ -f "$allow_file" ]] || fail "missing $allow_file"

for f in "${proof_files[@]}"; do
  [[ -f "$f" ]] || fail "listed file $f does not exist; update proof_files in $0"
done

# One row per swallow: "<file> <enclosing fn> <pattern>". `catch` forms that
# discard the error, plus `else => {}` inside a switch, are what turned each of
# the three shipped fail-opens into silence.
found_rows="$(
  for f in "${proof_files[@]}"; do
    awk -v file="$f" '
      # A `test "..."` block runs under the testing allocator and reports its
      # own failures, so a swallow there cannot weaken a build verdict. Entries
      # stay excluded until the next declaration at column zero.
      /^test "/ { in_test = 1; current_fn = "<test>" }
      /^(pub )?fn [A-Za-z_]/ { in_test = 0 }
      match($0, /^[[:space:]]*(pub )?fn [A-Za-z_][A-Za-z0-9_]*/) {
        line = substr($0, RSTART, RLENGTH)
        sub(/^[[:space:]]*(pub )?fn /, "", line)
        if (!in_test) current_fn = line
      }
      in_test { next }
      {
        pattern = ""
        # `catch return error.X` propagates the failure to the caller, which is
        # the outcome this gate wants; only a `catch` that substitutes a value
        # counts as a swallow.
        if ($0 ~ /catch return error\./)       pattern = ""
        else if ($0 ~ /catch \{\}/)            pattern = "catch-empty"
        else if ($0 ~ /catch \|_\| \{\}/)      pattern = "catch-empty"
        else if ($0 ~ /catch return/)          pattern = "catch-return"
        else if ($0 ~ /catch break/)           pattern = "catch-break"
        else if ($0 ~ /catch continue/)        pattern = "catch-continue"
        if (pattern != "") {
          printf "%s %s %s\n", file, (current_fn == "" ? "<file-scope>" : current_fn), pattern
        }
      }
    ' "$f"
  done | sort -u
)"

allowed_rows="$(sed 's/#.*$//' "$allow_file" | grep -v '^[[:space:]]*$' | sed 's/[[:space:]]*$//' | sort -u || true)"

unlisted="$(comm -23 <(printf '%s\n' "$found_rows") <(printf '%s\n' "$allowed_rows") || true)"
if [[ -n "${unlisted//[[:space:]]/}" ]]; then
  printf 'proof swallow: these discard an error in the proof pipeline and %s does not list them:\n' "$allow_file" >&2
  printf '%s\n' "$unlisted" | sed 's/^/  /' >&2
  printf 'Handle the error, or add the row with a reason it cannot weaken a verdict.\n' >&2
  exit 1
fi

stale="$(comm -13 <(printf '%s\n' "$found_rows") <(printf '%s\n' "$allowed_rows") || true)"
if [[ -n "${stale//[[:space:]]/}" ]]; then
  printf 'proof swallow: %s lists swallows that no longer exist:\n' "$allow_file" >&2
  printf '%s\n' "$stale" | sed 's/^/  /' >&2
  printf 'Delete those rows: the allowlist only ratchets down.\n' >&2
  exit 1
fi

row_count="$(printf '%s\n' "$found_rows" | grep -c . || true)"

# ---------------------------------------------------------------------------
# Second scan: silent `else` arms.
#
# This is the shape the `Effects<...>` fail-open actually took.
# `collectLiteralUnionStrings` dispatched on a type tag, handled union / ref /
# string-literal, and sent everything else to `else => {}` - so a computed
# payload returned zero names and read as "no annotation". Nothing about that
# line looked wrong; the bug was in what the arm did not say.
#
# An allowlist is the wrong tool here. Most of these arms are correct - an IR
# walker ignores node kinds with no children - and the justification is about
# which kinds fall through, which belongs beside the arm rather than in a file
# keyed on a function name that renames break. So the marker is inline: an
# `// exhaustive:` comment on the arm or within the three lines above it,
# naming why the ignored cases cannot carry anything this function owes.
#
# Arms that re-raise (`else => return err`, `else => return error.X`) are
# propagation, not silence, and are not counted.
unmarked_arms="$(
  for f in "${proof_files[@]}"; do
    awk -v file="$f" '
      /^test "/ { in_test = 1 }
      /^(pub )?fn [A-Za-z_]/ { in_test = 0 }
      !in_test && /else => (\{\}|return|continue|null)/ &&
      $0 !~ /else => return err[;,]?$/ && $0 !~ /else => return error\./ {
        if (!pending && $0 !~ /\/\/ exhaustive:/) printf "%s:%d: %s\n", file, NR, $0
        pending = 0
        next
      }
      # The reason attaches to the comment block directly above the arm, however
      # long it runs. Any code line between the two breaks the attachment, so a
      # marker cannot drift onto an arm it was not written for.
      /^[[:space:]]*\/\/.*exhaustive:/ { pending = 1; next }
      /^[[:space:]]*\/\// { next }
      /^[[:space:]]*$/ { next }
      { pending = 0 }
    ' "$f"
  done
)"

if [[ -n "${unmarked_arms//[[:space:]]/}" ]]; then
  printf 'proof swallow: these switch arms drop cases in silence and carry no `// exhaustive:` reason:\n' >&2
  printf '%s\n' "$unmarked_arms" | sed 's/^/  /' >&2
  printf 'Name the ignored cases and why this function owes them nothing, or handle them.\n' >&2
  exit 1
fi

arm_count="$(
  for f in "${proof_files[@]}"; do grep -c '// exhaustive:' "$f" || true; done |
    awk '{s += $1} END {print s + 0}'
)"

printf 'proof swallow: OK (%s files, %s reviewed swallows, %s reviewed silent arms, 0 unreviewed)\n' \
  "${#proof_files[@]}" "$row_count" "$arm_count"

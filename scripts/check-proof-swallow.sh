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
# The key is (file, enclosing function, pattern, occurrence) rather than a
# line number. Edits above a function do not invalidate its rows. A second
# catch of the same form in one function gets a new occurrence number. Methods
# with the same name in one file share that sequence; insertion still forces
# review, but can renumber another method's row.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${PROOF_SWALLOW_INTERNAL_PROBE:-}" == 1 && -n "${PROOF_SWALLOW_ROOT:-}" ]]; then
  cd "$PROOF_SWALLOW_ROOT"
else
  cd "$repo_root"
fi

allow_file="scripts/proof-swallow.allow"

# The analysis pipeline: everything between the parsed IR and the verdict a
# build reports. A file added here without its swallows listed fails the gate,
# which is the intended way to bring new analysis code under review.
#
# The list is not bounded by the producer. The consumer-side acceptance kernel
# decides whether a certificate is accepted, and `proof_activation.zig` supplies
# the independently reconstructed graph it decides over - a swallow there
# surfaces as an accepted artifact, which is the same fail-open one rung later.
# Both sat outside this gate while it was cited as covering the proof pipeline.
proof_files=(
  packages/zts/src/contract_builder.zig
  packages/zts/src/effect_inference.zig
  packages/zts/src/fault_coverage.zig
  packages/zts/src/flow_checker.zig
  packages/zts/src/function_specs.zig
  packages/zts/src/handler_contract.zig
  packages/zts/src/handler_verifier.zig
  packages/zts/src/intent_extractor.zig
  packages/zts/src/route_resolution.zig
  packages/zts/src/spec_discharge.zig
  packages/zts/src/type_checker.zig
  packages/zts/src/type_env.zig
  packages/proof-checker/src/checker.zig
  packages/proof-checker/src/capability_policy.zig
  packages/proof-checker/src/wire.zig
  packages/runtime/src/proof_activation.zig
)

fail() {
  printf 'proof swallow: %s\n' "$1" >&2
  exit 1
}

[[ -f "$allow_file" ]] || fail "missing $allow_file"

# A row must belong to a reason block. Repeated rows are errors, not extra
# review: the same allow key cannot explain two different source sites.
if ! awk '
  /^[[:space:]]*#/ { reason = 1; next }
  /^[[:space:]]*$/ { reason = 0; next }
  {
    if (!reason || NF != 3 || $3 !~ /^catch-[a-z]+(@[0-9]+)?$/) {
      printf "proof swallow: allowlist row %d needs a preceding reason and three fields\n", NR > "/dev/stderr"
      exit 1
    }
  }
' "$allow_file"; then
  exit 1
fi

for f in "${proof_files[@]}"; do
  [[ -f "$f" ]] || fail "listed file $f does not exist; update proof_files in $0"
done

# One row per (file, enclosing function, pattern occurrence). Catch blocks and values
# need review too: a poison flag only stops proof if every entry point checks it.
found_rows="$(
  for f in "${proof_files[@]}"; do
    awk -v file="$f" '
      # A `test "..."` block reports its own failures. Resume scanning at any
      # top-level declaration after it, including an inline function or const.
      /^test "/ { in_test = 1; current_fn = "<test>" }
      /^(pub |export |extern |inline )*(fn|const|var|comptime) / { in_test = 0 }
      /^(pub |export |extern |inline )*(const|var|comptime) / { current_fn = "<file-scope>" }
      match($0, /^[[:space:]]*(pub |export |extern |inline )*fn [A-Za-z_][A-Za-z0-9_]*/) {
        line = substr($0, RSTART, RLENGTH)
        sub(/^[[:space:]]*(pub |export |extern |inline )*fn /, "", line)
        if (!in_test) current_fn = line
      }
      in_test { next }
      {
        if ($0 ~ /^[[:space:]]*\/\//) next
        line = $0
        if (gsub(/catch([[:space:]]|$)/, "&", line) > 1) {
          printf "proof swallow: multiple catches on one line at %s:%d; split the line for review\n", file, NR > "/dev/stderr"
          exit 2
        }
        pattern = ""
        # Direct error propagation cannot yield a proof answer. Review an
        # unreachable catch as an invariant claim, because it is not a safe
        # error result when the claimed invariant fails.
        if ($0 ~ /catch return error\./) next
        if ($0 ~ /catch[[:space:]]+unreachable/) pattern = "catch-trap"
        else if ($0 ~ /catch[[:space:]]+return/ || $0 ~ /catch[[:space:]]+\|[^|]+\|[[:space:]]+return/) pattern = "catch-return"
        else if ($0 ~ /catch[[:space:]]+break/) pattern = "catch-break"
        else if ($0 ~ /catch[[:space:]]+continue/) pattern = "catch-continue"
        else if ($0 ~ /catch[[:space:]]+\|[^|]+\|[[:space:]]+switch/) pattern = "catch-switch"
        else if ($0 ~ /catch[[:space:]]+self\.markAllocationFailure\(\)/ || $0 ~ /catch[[:space:]]+@constCast\(self\)\.markAllocationFailure\(\)/) pattern = "catch-poison"
        else if ($0 ~ /catch[[:space:]]+\{/ || $0 ~ /catch[[:space:]]+\|[^|]+\|[[:space:]]+\{/ || $0 ~ /catch[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[[:space:]]+\{/) pattern = "catch-block"
        else if ($0 ~ /catch[[:space:]]*$/) pattern = "catch-multiline"
        else if ($0 ~ /catch[[:space:]]+/) pattern = "catch-value"
        if (pattern != "") {
          key = file SUBSEP current_fn SUBSEP pattern
          seen[key]++
          if (seen[key] > 1) pattern = pattern "@" seen[key]
          printf "%s %s %s\n", file, (current_fn == "" ? "<file-scope>" : current_fn), pattern
        }
      }
    ' "$f"
  done | sort -u
)"

allowed_rows="$(sed 's/#.*$//' "$allow_file" | grep -v '^[[:space:]]*$' | sed 's/[[:space:]]*$//' | sort || true)"
duplicates="$(printf '%s\n' "$allowed_rows" | uniq -d)"
if [[ -n "${duplicates//[[:space:]]/}" ]]; then
  fail "duplicate allowlist rows: $duplicates"
fi

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
# `// exhaustive:` comment on the arm or directly above it,
# naming why the ignored cases cannot carry anything this function owes.
#
# This scan covers no-op arms, early exits, and direct literal or named-value
# fallbacks. Arms that re-raise (`else => return err`, `else => return error.X`)
# are propagation, not silence, and are not counted.
arm_rows="$(
  for f in "${proof_files[@]}"; do
    awk -v file="$f" '
      /^test "/ { in_test = 1 }
      /^(pub |export |extern |inline )*(fn|const|var|comptime) / { in_test = 0 }
      !in_test && /else => (\{\}|return|continue|\.\{|[0-9-]|"|\.|[A-Za-z_][A-Za-z0-9_.]*[,;}])/ &&
      $0 !~ /else => return err[;,]?$/ && $0 !~ /else => return error\./ {
        if (!pending && $0 !~ /\/\/ exhaustive:/)
          printf "unmarked %s:%d: %s\n", file, NR, $0
        else
          printf "reviewed %s:%d\n", file, NR
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
unmarked_arms="$(printf '%s\n' "$arm_rows" | sed -n 's/^unmarked //p')"

if [[ -n "${unmarked_arms//[[:space:]]/}" ]]; then
  printf 'proof swallow: these switch arms drop cases in silence and carry no `// exhaustive:` reason:\n' >&2
  printf '%s\n' "$unmarked_arms" | sed 's/^/  /' >&2
  printf 'Name the ignored cases and why this function owes them nothing, or handle them.\n' >&2
  exit 1
fi

arm_count="$(printf '%s\n' "$arm_rows" | awk '/^reviewed / { count++ } END { print count + 0 }')"

# Change one declared input file in a copy and require the gate to reject it.
# Compile the probe code first, then exercise the same source shape the gate
# will see after a future proof-pipeline edit.
if [[ "${PROOF_SWALLOW_INTERNAL_PROBE:-}" != 1 ]]; then
  probe_dir="$(mktemp -d)"
  trap 'rm -rf "$probe_dir"' EXIT
  git ls-files -z -- "${proof_files[@]}" "$allow_file" |
    xargs -0 -n 1 sh -c '
      mkdir -p "$1/$(dirname "$2")"
      cp "$2" "$1/$2"
    ' _ "$probe_dir"
  cat > "$probe_dir/proof_swallow_probe.zig" <<'EOF'
fn proofSwallowValueProbe() void {
    const result: error{Missing}![]const u8 = error.Missing;
    _ = result catch "fallback";
    const second: error{Missing}![]const u8 = error.Missing;
    _ = second catch "second fallback";
}

fn proofSwallowBlockProbe() void {
    const result: error{Missing}!void = error.Missing;
    _ = result catch {};
}

const ProofSwallowPoisonProbe = struct {
    fn markAllocationFailure(_: *@This()) void {}

    fn proofSwallowPoisonProbe(self: *@This()) void {
        const result: error{Missing}!void = error.Missing;
        _ = result catch self.markAllocationFailure();
    }
};

fn proofSwallowSwitchProbe() void {
    const result: error{Missing}!void = error.Missing;
    _ = result catch |err| switch (err) {
        error.Missing => return,
    };
}

fn proofSwallowMultilineProbe() void {
    const result: error{Missing}!void = error.Missing;
    _ = result catch
        return;
}

fn proofSwallowTrapProbe() void {
    const result: error{Missing}!void = {};
    _ = result catch unreachable;
}

test "proof swallow probe compiles" {
    proofSwallowValueProbe();
    proofSwallowBlockProbe();
    var poison: ProofSwallowPoisonProbe = .{};
    poison.proofSwallowPoisonProbe();
    proofSwallowSwitchProbe();
    proofSwallowMultilineProbe();
    proofSwallowTrapProbe();
}
EOF
  if ! probe_compile="$(zig test "$probe_dir/proof_swallow_probe.zig" 2>&1)"; then
    fail "catch probes do not compile: $probe_compile"
  fi
  cat "$probe_dir/proof_swallow_probe.zig" >> "$probe_dir/packages/zts/src/contract_builder.zig"
  if probe_output="$(PROOF_SWALLOW_ROOT="$probe_dir" PROOF_SWALLOW_INTERNAL_PROBE=1 bash "$repo_root/scripts/check-proof-swallow.sh" 2>&1)"; then
    fail "the catch probes passed without allowlist rows"
  fi
  for expected in \
    "proofSwallowValueProbe catch-value" \
    "proofSwallowValueProbe catch-value@2" \
    "proofSwallowBlockProbe catch-block" \
    "proofSwallowPoisonProbe catch-poison" \
    "proofSwallowSwitchProbe catch-switch" \
    "proofSwallowMultilineProbe catch-multiline" \
    "proofSwallowTrapProbe catch-trap"; do
    if [[ "$probe_output" != *"packages/zts/src/contract_builder.zig $expected"* ]]; then
      fail "the catch probe missed $expected: $probe_output"
    fi
  done

  cat > "$probe_dir/proof_swallow_multiple.zig" <<'EOF'
fn proofSwallowMultipleProbe() void {
    const first: error{Missing}![]const u8 = error.Missing;
    const second: error{Missing}![]const u8 = error.Missing;
    _ = first catch "first"; _ = second catch "second";
}

test "multiple catch probe compiles" {
    proofSwallowMultipleProbe();
}
EOF
  if ! probe_compile="$(zig test "$probe_dir/proof_swallow_multiple.zig" 2>&1)"; then
    fail "multiple-catch probe does not compile: $probe_compile"
  fi
  cat "$probe_dir/proof_swallow_multiple.zig" >> "$probe_dir/packages/zts/src/contract_builder.zig"
  if probe_output="$(PROOF_SWALLOW_ROOT="$probe_dir" PROOF_SWALLOW_INTERNAL_PROBE=1 bash "$repo_root/scripts/check-proof-swallow.sh" 2>&1)"; then
    fail "the multiple-catch probe passed"
  fi
  if [[ "$probe_output" != *"multiple catches on one line"* ]]; then
    fail "the multiple-catch probe failed for another reason: $probe_output"
  fi

  cp "$repo_root/packages/zts/src/contract_builder.zig" "$probe_dir/packages/zts/src/contract_builder.zig"
  cat > "$probe_dir/proof_swallow_arm.zig" <<'EOF'
const ProofSwallowArmKind = enum { known, other };

fn proofSwallowArmProbe(kind: ProofSwallowArmKind) bool {
    return switch (kind) {
        .known => true,
        else => false,
    };
}

test "silent arm probe compiles" {
    _ = proofSwallowArmProbe(.other);
}
EOF
  if ! probe_compile="$(zig test "$probe_dir/proof_swallow_arm.zig" 2>&1)"; then
    fail "silent-arm probe does not compile: $probe_compile"
  fi
  cat "$probe_dir/proof_swallow_arm.zig" >> "$probe_dir/packages/zts/src/contract_builder.zig"
  if probe_output="$(PROOF_SWALLOW_ROOT="$probe_dir" PROOF_SWALLOW_INTERNAL_PROBE=1 bash "$repo_root/scripts/check-proof-swallow.sh" 2>&1)"; then
    fail "the silent-arm probe passed without a reason"
  fi
  if [[ "$probe_output" != *"proof swallow: these switch arms drop cases in silence"* || "$probe_output" != *"else => false"* ]]; then
    fail "the silent-arm probe failed for another reason: $probe_output"
  fi
fi

printf 'proof swallow: OK (%s files, %s reviewed swallows, %s reviewed silent arms, 0 unreviewed)\n' \
  "${#proof_files[@]}" "$row_count" "$arm_count"

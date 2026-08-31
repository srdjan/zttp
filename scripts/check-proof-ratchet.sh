#!/usr/bin/env bash
#
# Trusted-boundary drift gate.
#
# A certificate's assurance grade only means something next to a statement of
# what the consumer re-derived and what it took on the producer's word. That
# statement exists twice: once in `Property.consumerChecked` in the acceptance
# kernel, which decides behavior, and once in docs/verification.md, which is
# what a reader acts on. This gate keeps them the same.
#
# It fails in both directions:
#
#   - a property the kernel re-derives that the documentation still lists as
#     disclosed, which would understate what shipped;
#   - a property the kernel does not re-derive that the documentation does not
#     disclose, which would overstate it. That is the direction that matters.
#
# It also asserts its own inputs are non-empty, because a gate whose corpus
# vanished reports a pass while checking nothing.

set -euo pipefail

cd "$(dirname "$0")/.."

kernel="packages/proof-checker/src/proof_system.zig"
policy="packages/proof-checker/src/policy.zig"
ratchet="packages/runtime/src/proof_ratchet.zig"
doc="docs/verification.md"

fail=0
note() { printf 'proof ratchet: %s\n' "$1" >&2; fail=1; }

for path in "$kernel" "$policy" "$ratchet" "$doc"; do
  [[ -f "$path" ]] || { note "missing $path"; exit 1; }
done

# ---------------------------------------------------------------------------
# Floors. Every count below is meaningless if its input is empty.
# ---------------------------------------------------------------------------
corpus_size="$(grep -c '^        \.name = "' "$ratchet" || true)"
min_corpus=3
if [[ "$corpus_size" -lt "$min_corpus" ]]; then
  note "the ratchet corpus has $corpus_size handler(s), expected at least $min_corpus"
  exit 1
fi

# The property alphabet, read from the enum's own name table so a renamed
# member cannot slip past by not matching a pattern written down here.
properties="$(sed -n 's/^            \.\([a-z_]*\) => "\1",$/\1/p' "$kernel" | sort -u)"
if [[ -z "$properties" ]]; then
  note "found no properties in $kernel - the gate is reading nothing"
  exit 1
fi
property_count="$(printf '%s\n' "$properties" | wc -l | tr -d ' ')"
if [[ "$property_count" -lt 4 ]]; then
  note "found only $property_count properties in $kernel; the alphabet cannot have shrunk that far by accident"
  exit 1
fi

# ---------------------------------------------------------------------------
# Which half each property is in, read from `consumerChecked`.
# ---------------------------------------------------------------------------
body="$(awk '/pub fn consumerChecked\(self: Property\) bool \{/,/^    \}$/' "$kernel")"
[[ -n "$body" ]] || { note "cannot find consumerChecked in $kernel"; exit 1; }

# An arm is a run of bare `.name,` lines terminated by a `=> <value>,` line, or
# a single `.name => <value>,` line. Collect the run, then assign it when the
# arrow arrives; reading the arrow first is what the earlier version of this
# gate got wrong, and it reported every property as checked.
checked=""
disclosed=""
pending=""
while IFS= read -r line; do
  case "$line" in
    *"=>"*)
      inline_name="$(printf '%s' "$line" | sed -n 's/^ *\.\([a-z_][a-z_]*\) *=>.*$/\1/p')"
      [[ -n "$inline_name" ]] && pending="$pending $inline_name"
      case "$line" in
        *"=> true,"*) checked="$checked$pending" ;;
        *"=> false,"*) disclosed="$disclosed$pending" ;;
        *) note "unexpected arm in consumerChecked: $line" ;;
      esac
      pending=""
      ;;
    *)
      name="$(printf '%s' "$line" | sed -n 's/^ *\.\([a-z_][a-z_]*\),$/\1/p')"
      [[ -n "$name" ]] && pending="$pending $name"
      ;;
  esac
done <<< "$(printf '%s\n' "$body" | sed -n '/return switch (self) {/,/};/p')"

if [[ -n "$pending" ]]; then
  note "consumerChecked has a trailing arm with no verdict:$pending"
fi

checked_count=0
for name in $checked; do checked_count=$((checked_count + 1)); done
if [[ "$checked_count" -lt 1 ]]; then
  note "the kernel re-derives no property at all; a checker that checks nothing is not a checker"
  exit 1
fi

# ---------------------------------------------------------------------------
# The documentation has to say the same thing, member for member.
#
# A prose mention is not enough: a promoted property stays mentioned, so a gate
# that only greps for the name reports a pass after the promotion it was
# supposed to catch. The doc carries a marked list instead, and the two sets are
# compared exactly.
# ---------------------------------------------------------------------------
doc_checked="$(awk '/<!-- proof-ratchet: consumer-checked -->/,/<!-- proof-ratchet: disclosed -->/' "$doc" \
  | sed -n 's/^- `\([a-z_][a-z_]*\)`$/\1/p')"
doc_disclosed="$(awk '/<!-- proof-ratchet: disclosed -->/,/<!-- proof-ratchet: end -->/' "$doc" \
  | sed -n 's/^- `\([a-z_][a-z_]*\)`$/\1/p')"

if [[ -z "$doc_checked" && -z "$doc_disclosed" ]]; then
  note "$doc carries no proof-ratchet block; the published boundary is missing"
  exit 1
fi

normalize() { printf '%s\n' $1 | sort -u; }

if ! diff -u <(normalize "$doc_checked") <(normalize "$checked") >/dev/null; then
  note "the consumer-checked set in $doc does not match the kernel:"
  diff -u <(normalize "$doc_checked") <(normalize "$checked") >&2 || true
fi

if ! diff -u <(normalize "$doc_disclosed") <(normalize "$disclosed") >/dev/null; then
  note "the disclosed set in $doc does not match the kernel:"
  diff -u <(normalize "$doc_disclosed") <(normalize "$disclosed") >&2 || true
fi

# Everything the production policy requires and the kernel does not re-derive
# has to appear in the disclosed half: those are the properties an operator is
# relying on today without a consumer check behind them.
for name in $disclosed; do
  if grep -q "\.property = \.$name," "$policy"; then
    if ! printf '%s\n' $doc_disclosed | grep -qx "$name"; then
      note "'$name' is required by the production policy, is not re-derived, and is not in the disclosed list"
    fi
  fi
done

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

printf 'proof ratchet: %d of %d properties re-derived by the consumer; %d handler(s) in the corpus\n' \
  "$checked_count" "$property_count" "$corpus_size"

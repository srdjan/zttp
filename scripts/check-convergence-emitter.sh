#!/usr/bin/env bash
# scripts/check-convergence-emitter.sh
#
# Two markers reach docs through the same mechanism, and they answer different
# questions:
#
#   [codegen-convergence] - a measurement of a live model, carrying its name.
#   [proof-coverage]      - a fact about the corpus and the compiler.
#   [seed-coverage]       - which rules were observed firing at all, from the
#                           defect-seed suite, with no model involved.
#
# Each is printed by the cassette replay and lifted out of the complete
# `test-expert-app` output only after that build succeeds. The publisher
# requires exactly one matching line, but it cannot establish which source
# emitted that line. A second emitter, such as an offline summary that copies a
# format or a debug print left in a harness, could still replace the authority.
# That matters most for the convergence row, where a stand-in number would
# appear under a model's name.
#
# This gate holds each marker to one producer and one consumer, named by path,
# and forbids either publisher from reading the other's marker.
#
# Documentation is excluded from the count. Only code that runs can put a line
# in the build output, so a marker named in a `docs/` page is a description, not
# an emitter, and requiring those pages to stay silent about the mechanism would
# be the wrong trade.
#
# Runs under bash 3.2 (the /bin/bash the build step invokes on macOS): no
# mapfile, no associative arrays.

set -euo pipefail

cd "$(dirname "$0")/.."

self="scripts/check-convergence-emitter.sh"

fail() {
  printf 'convergence emitter: %s\n' "$1" >&2
  exit 1
}

# Every tracked file carrying a marker, minus documentation and minus this file,
# which names both markers in its own text. Documentation is excluded by
# extension rather than by directory: prose that names a marker lives in
# `docs/`, in `advisor-plans/`, and in any plan directory added later, and a
# markdown file cannot print a line into the build output wherever it sits.
sites_for() {
  git ls-files -z |
    xargs -0 sh -c '
      for file do
        [ -f "$file" ] && printf "%s\0" "$file"
      done
    ' sh |
    xargs -0 grep -l -F -e "$1" -- 2>/dev/null |
    grep -v -x -F "$self" |
    grep -v '\.md$' |
    LC_ALL=C sort
}

# One marker: exactly the given producer and consumer, in that order. The
# producer must open a format string with it, so a producer that stopped
# printing does not pass on a comment; the consumer must merely mention it.
check_marker() {
  local marker="$1" producer="$2" consumer="$3"

  local hits
  hits="$(sites_for "$marker")"

  # Floor before the count. An empty result is what a renamed marker, a broken
  # pipeline, and an unreadable tree all look like, and every assertion below
  # would then pass over nothing.
  [[ -n "$hits" ]] || fail "no file carries $marker; the search found nothing to check"

  local count
  count="$(printf '%s\n' "$hits" | grep -c .)"
  if [[ "$count" -ne 2 ]]; then
    printf 'convergence emitter: expected exactly 2 files carrying %s, found %s:\n' "$marker" "$count" >&2
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    fail "a second emitter would be published as though it were the real one"
  fi

  local found_producer found_consumer
  found_producer="$(printf '%s\n' "$hits" | sed -n '1p')"
  found_consumer="$(printf '%s\n' "$hits" | sed -n '2p')"
  [[ "$found_producer" == "$producer" ]] || fail "expected $marker producer $producer, found $found_producer"
  [[ "$found_consumer" == "$consumer" ]] || fail "expected $marker consumer $consumer, found $found_consumer"

  grep -q -F "\"$marker " "$producer" ||
    fail "$producer no longer opens a format string with $marker"
  grep -q -F "$marker" "$consumer" ||
    fail "$consumer no longer reads $marker"
}

convergence_marker='[codegen-convergence]'
coverage_marker='[proof-coverage]'
seed_marker='[seed-coverage]'
convergence_publisher="scripts/update-convergence.sh"
coverage_publisher="scripts/update-coverage.sh"
producer="packages/pi/src/expert_codegen_record.zig"
# The seed figure has its own producer on purpose: it is printed by the gate
# that verifies it, so a marker can only appear after every seed reproduced its
# declared class through the real veto.
seed_producer="packages/pi/src/standin_range_tests.zig"

check_marker "$convergence_marker" "$producer" "$convergence_publisher"
check_marker "$coverage_marker" "$producer" "$coverage_publisher"
check_marker "$seed_marker" "$seed_producer" "$coverage_publisher"

# And neither publisher may read the other's marker. A coverage line has no
# model column to fill, and a convergence line says nothing about what the
# corpus covers; either one lifted into the wrong page is a number answering a
# question nobody asked of it.
if grep -q -F "$coverage_marker" "$convergence_publisher"; then
  fail "$convergence_publisher reads $coverage_marker"
fi
if grep -q -F "$convergence_marker" "$coverage_publisher"; then
  fail "$coverage_publisher reads $convergence_marker"
fi
# The seed figure is a compiler claim with no model in it. A convergence row has
# a model column to fill, so lifting a seed count into that page would publish a
# number about the compiler under a model's name.
if grep -q -F "$seed_marker" "$convergence_publisher"; then
  fail "$convergence_publisher reads $seed_marker"
fi

bash scripts/test-evidence-marker.sh

printf 'convergence emitter OK: %s and %s have one producer (%s); %s has one producer (%s); each has one publisher\n' \
  "$convergence_marker" "$coverage_marker" "$producer" "$seed_marker" "$seed_producer"

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

# Every versioned or new source file carrying a marker, minus documentation and
# this file. Including new files keeps the gate valid before the source commit.
# Documentation is excluded by extension because Markdown cannot emit a line.
sites_for() {
  git ls-files -z --cached --others --exclude-standard |
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
native_consumer="tooling/evidence_publish.zig"
convergence_publisher="scripts/update-convergence.sh"
coverage_publisher="scripts/update-coverage.sh"
producer="packages/pi/src/expert_codegen_record.zig"
# The seed figure has its own producer on purpose: it is printed by the gate
# that verifies it, so a marker can only appear after every seed reproduced its
# declared class through the real veto.
seed_producer="packages/pi/src/standin_range_tests.zig"

check_marker "$convergence_marker" "$producer" "$native_consumer"
check_marker "$coverage_marker" "$producer" "$native_consumer"
check_marker "$seed_marker" "$seed_producer" "$native_consumer"

# Each stable shell must select only its named native publication mode.
grep -q -F 'evidence-publish -- convergence' "$convergence_publisher" ||
  fail "$convergence_publisher no longer selects the convergence publisher"
grep -q -F 'evidence-publish -- coverage' "$coverage_publisher" ||
  fail "$coverage_publisher no longer selects the coverage publisher"
if grep -q -F 'evidence-publish -- coverage' "$convergence_publisher"; then
  fail "$convergence_publisher selects coverage publication"
fi
if grep -q -F 'evidence-publish -- convergence' "$coverage_publisher"; then
  fail "$coverage_publisher selects convergence publication"
fi

printf 'convergence emitter OK: %s and %s have one producer (%s); %s has one producer (%s); all use native consumer %s\n' \
  "$convergence_marker" "$coverage_marker" "$producer" "$seed_marker" "$seed_producer" "$native_consumer"

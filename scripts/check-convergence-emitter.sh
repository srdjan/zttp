#!/usr/bin/env bash
# scripts/check-convergence-emitter.sh
#
# The published convergence row is a measurement of a live model. It reaches
# docs/convergence.md through one path: the cassette replay prints a single
# `[codegen-convergence]` line, and scripts/update-convergence.sh lifts the
# first line matching that marker out of the whole `test-expert-app` output.
#
# The publisher does not check where the line came from. A second emitter - an
# offline coverage summary that copies the format, a debug print left in a
# stand-in harness - would be published into the same table carrying a number no
# model produced. This gate keeps the marker to exactly one producer and one
# consumer, named by path, and keeps the offline coverage marker distinct so the
# two artifacts cannot converge on one format by accident.
#
# Runs under bash 3.2 (the /bin/bash the build step invokes on macOS): no
# mapfile, no associative arrays.

set -euo pipefail

cd "$(dirname "$0")/.."

marker='[codegen-convergence]'
offline_marker='[proof-coverage]'

expected_producer="packages/pi/src/expert_codegen_record.zig"
expected_consumer="scripts/update-convergence.sh"
self="scripts/check-convergence-emitter.sh"

fail() {
  printf 'convergence emitter: %s\n' "$1" >&2
  exit 1
}

# The whole tracked tree, not the two directories the marker lives in today: an
# emitter added anywhere is the case this gate exists for, and narrowing the
# search would make it blind to exactly that. This file carries both markers in
# its own text and is excluded by path.
hits=$(
  git ls-files -z |
    xargs -0 grep -l -F -e "$marker" -- 2>/dev/null |
    grep -v -x -F "$self" |
    LC_ALL=C sort
)

# Floor before any count means anything. An empty result is what a renamed
# marker, a broken pipeline, and an unreadable tree all look like, and every
# assertion below would then pass over nothing.
[[ -n "$hits" ]] || fail "no file carries $marker; the search found nothing to check"

count=$(printf '%s\n' "$hits" | grep -c .)
if [[ "$count" -ne 2 ]]; then
  printf 'convergence emitter: expected exactly 2 files carrying %s, found %s:\n' "$marker" "$count" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  fail "a second emitter would be published as a model measurement"
fi

producer=$(printf '%s\n' "$hits" | sed -n '1p')
consumer=$(printf '%s\n' "$hits" | sed -n '2p')
[[ "$producer" == "$expected_producer" ]] || fail "expected producer $expected_producer, found $producer"
[[ "$consumer" == "$expected_consumer" ]] || fail "expected consumer $expected_consumer, found $consumer"

# The producer prints the line and the consumer greps for it. A producer that
# stopped printing leaves the marker in a comment and passes the count above, so
# require the marker to open a format string rather than merely appear.
grep -q -F "\"$marker " "$expected_producer" ||
  fail "$expected_producer no longer opens a format string with the marker"
grep -q -F "$marker" "$expected_consumer" ||
  fail "$expected_consumer no longer reads the marker"

# The offline coverage artifact publishes under its own marker, and gets the
# same treatment: one producer, and never read by the row publisher. A coverage
# line is a fact about the corpus and the compiler, and an offline run has no
# model column to carry.
offline_hits=$(
  git ls-files -z |
    xargs -0 grep -l -F -e "$offline_marker" -- 2>/dev/null |
    grep -v -x -F "$self" |
    LC_ALL=C sort
)

[[ -n "$offline_hits" ]] || fail "no file carries $offline_marker; the search found nothing to check"

offline_count=$(printf '%s\n' "$offline_hits" | grep -c .)
if [[ "$offline_count" -ne 1 ]]; then
  printf 'convergence emitter: expected exactly 1 file carrying %s, found %s:\n' "$offline_marker" "$offline_count" >&2
  printf '%s\n' "$offline_hits" | sed 's/^/  /' >&2
  fail "a second coverage emitter would publish a second answer to the same question"
fi

[[ "$offline_hits" == "$expected_producer" ]] ||
  fail "expected $offline_marker producer $expected_producer, found $offline_hits"

if grep -q -F "$offline_marker" "$expected_consumer" 2>/dev/null; then
  fail "$expected_consumer reads the offline marker $offline_marker"
fi

printf 'convergence emitter OK: %s produced by %s, read by %s; %s produced by %s, read by nothing\n' \
  "$marker" "$expected_producer" "$expected_consumer" "$offline_marker" "$expected_producer"

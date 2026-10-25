#!/usr/bin/env bash
# Run each version-2 agent operation twice and compare its complete envelope.

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf 'agent determinism: %s\n' "$1" >&2
  exit 1
}

# The build step passes the built native reader first and this build's zts second.
if [[ $# -ne 2 ]]; then
  fail "usage: bash scripts/check-agent-determinism.sh <repo-gate> <zts>; run zig build test-agent-determinism"
fi
REPO_GATE="$1"
ZTS="$2"
[[ -x "$REPO_GATE" ]] || fail "$REPO_GATE is not executable"
[[ -x "$ZTS" ]] || fail "$ZTS is not executable"

FIXTURE=packages/tools/tests/fixtures/contract/plain_ts.ts
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

validate_envelope() {
  local label="$1" path="$2"
  "$REPO_GATE" agent-envelope "$label" "$path"
}

check_op() {
  local label="$1" request="$2"
  local first="$work/$label.first.json" second="$work/$label.second.json"
  printf '%s' "$request" | "$ZTS" agent --stdin-json > "$first" 2>/dev/null
  printf '%s' "$request" | "$ZTS" agent --stdin-json > "$second" 2>/dev/null
  if ! cmp -s "$first" "$second"; then
    diff "$first" "$second" >&2 || true
    fail "$label response is not deterministic"
  fi
  validate_envelope "$label" "$first" ||
    fail "$label response is not a single complete envelope"
  printf '  %-14s deterministic\n' "$label"
}

echo ">> agent transport determinism"

for op in meta features restrictions describe_rule; do
  check_op "$op" "{\"schema_version\":2,\"operation\":\"$op\",\"project_root\":\".\",\"input\":{}}"
done

for op in modules check canonicalize normalize; do
  check_op "$op" "{\"schema_version\":2,\"operation\":\"$op\",\"project_root\":\".\",\"input\":{\"file\":\"$FIXTURE\"}}"
done

check_op negotiation '{"schema_version":1,"operation":"meta","project_root":".","input":{}}'

# An unknown operation still writes a complete error envelope and exits zero.
check_op nope '{"schema_version":2,"operation":"nope","project_root":".","input":{}}'

echo "agent determinism OK"

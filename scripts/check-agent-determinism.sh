#!/usr/bin/env bash
# scripts/check-agent-determinism.sh
#
# Spec 4.8 requires two things of the version-2 transport that a unit test
# cannot observe from inside the process: standard output carries the response
# JSON and nothing else, and array order, diagnostic order, rewrite order, and
# serialized canonical source are deterministic for identical authenticated
# inputs.
#
# So this runs the real binary twice per operation and compares bytes. A
# response that parses but differs between runs - a hash-map iteration leaking
# into an array, a path that varies with the working directory - fails here and
# nowhere else.
#
# Usage (from anywhere; the script cd's to the repo root):
#   bash scripts/check-agent-determinism.sh

set -euo pipefail

cd "$(dirname "$0")/.."

ZTS=./zig-out/bin/zts
FIXTURE=packages/tools/tests/fixtures/contract/plain_ts.ts

[[ -x "$ZTS" ]] || {
  echo "error: $ZTS is missing; run zig build first" >&2
  exit 1
}

fail() {
  printf 'agent determinism: %s\n' "$1" >&2
  exit 1
}

# One operation, run twice. stderr is discarded on purpose: the contract is that
# stdout alone carries the response, so a log line leaking into stdout shows up
# as a parse failure here.
check_op() {
  local label="$1" request="$2"
  local first second
  first=$(printf '%s' "$request" | "$ZTS" agent --stdin-json 2>/dev/null)
  second=$(printf '%s' "$request" | "$ZTS" agent --stdin-json 2>/dev/null)

  if [[ "$first" != "$second" ]]; then
    diff <(printf '%s\n' "$first") <(printf '%s\n' "$second") >&2 || true
    fail "$label response is not deterministic"
  fi

  printf '%s' "$first" | python3 -c "
import json, sys
raw = sys.stdin.read()
doc = json.loads(raw)          # exactly one object, or this raises
if '$label' != 'negotiation':
    assert doc['operation'] == '$label', doc.get('operation')
    assert doc['schema_version'] == 2, doc.get('schema_version')
else:
    assert doc['schema_version_unsupported'] is True
" || fail "$label response is not a single well-formed envelope"

  printf '  %-14s deterministic\n' "$label"
}

echo ">> agent transport determinism"

for op in meta features restrictions describe_rule; do
  check_op "$op" "{\"schema_version\":2,\"operation\":\"$op\",\"project_root\":\".\",\"input\":{}}"
done

# File-bound operations, so the module-graph digest and the diagnostic order are
# in the loop too.
for op in modules check canonicalize normalize; do
  check_op "$op" "{\"schema_version\":2,\"operation\":\"$op\",\"project_root\":\".\",\"input\":{\"file\":\"$FIXTURE\"}}"
done

# The negotiation response is frozen: it must be identical across versions, so
# an unsupported version is checked the same way.
check_op negotiation '{"schema_version":1,"operation":"meta","project_root":".","input":{}}'

# The exit status is part of the contract: a response was produced, so the
# process succeeds even when the envelope reports a protocol error.
set +e
printf '%s' '{"schema_version":2,"operation":"nope","project_root":".","input":{}}' \
  | "$ZTS" agent --stdin-json >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "an unknown operation exited $status; a written response must exit 0"

echo "agent determinism OK"

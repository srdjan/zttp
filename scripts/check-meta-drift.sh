#!/usr/bin/env bash
# Pin the compiler identities that a version-2 meta response publishes.

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf 'meta drift: %s\n' "$1" >&2
  exit 1
}

# The build step passes the native reader first and this build's zts second.
if [[ $# -ne 2 ]]; then
  fail "usage: bash scripts/check-meta-drift.sh <repo-gate> <zts>; run zig build test-meta-drift"
fi
REPO_GATE="$1"
ZTS="$2"
[[ -x "$REPO_GATE" ]] || fail "$REPO_GATE is not executable"
[[ -x "$ZTS" ]] || fail "$ZTS is not executable"

EXPECTED_PROFILE="zts-model-1"
# The public meta operation supplies these measured Phase 3 identities.
# policy-hash.txt is the one committed copy of the policy identity.
EXPECTED_POLICY_HASH="$(tr -d '\r\n' < policy-hash.txt)"
EXPECTED_GRAMMAR_HASH="8c555c6dfe5afb98cf73d034a548dd5f18db5a6b540f334a43f0ac871f4d73be"
EXPECTED_IDIOM_HASH="2a7059a7e3d4747c26af855ebd3a80b9fbb853bc5feb5ea16010bd300a5992db"
EXPECTED_RESTRICTION_HASH="a2c47c9ccf240cc913719f5ba359a2285aa9854f7cc797a801a7a0e036f3ec58"
EXPECTED_BUILTIN_HASH="95f3733d78ea9446e840ec5119582961de47b160f3c78081a8113c1d6a9bd58b"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# policy-hash.txt is the committed copy of the same policy identity.
rule_hash="$("$ZTS" describe-rule --hash)" || fail "describe-rule --hash failed"
[[ "$rule_hash" == "$(tr -d '\r\n' < policy-hash.txt)" ]] ||
  fail "describe-rule --hash ($rule_hash) differs from policy-hash.txt"

printf '{"schema_version":2,"operation":"meta","project_root":".","input":{}}\n' |
  "$ZTS" agent --stdin-json > "$work/meta.json" 2> "$work/err" ||
  fail "the meta operation failed: $(head -n 1 "$work/err")"

args=(
  meta-drift
  "$work/meta.json"
  "$EXPECTED_PROFILE"
  "$EXPECTED_POLICY_HASH"
  "$EXPECTED_GRAMMAR_HASH"
  "$EXPECTED_IDIOM_HASH"
  "$EXPECTED_RESTRICTION_HASH"
  "$EXPECTED_BUILTIN_HASH"
)
"$REPO_GATE" "${args[@]}"

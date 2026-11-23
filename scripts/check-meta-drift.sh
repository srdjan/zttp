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
EXPECTED_GRAMMAR_HASH="2b206d0882f56c873f989a38cf1bc994e41e66a83055fed559e59c131e580f22"
EXPECTED_IDIOM_HASH="04c9c24d9a0c039dad0668fb636c04e7bb4a5ab244da7a45078a218d0f03cbd7"
EXPECTED_RESTRICTION_HASH="1107aa1dd1e1b83d8647ea2d026234650abcff912da55c41ce2e771d41619e45"
EXPECTED_BUILTIN_HASH="dd1f3a41d9768784e22b57bccd982db76e034fac8ccd9b1d46d529ced22122e3"

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

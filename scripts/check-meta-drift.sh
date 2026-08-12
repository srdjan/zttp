#!/usr/bin/env bash
# scripts/check-meta-drift.sh
#
# The four registry identities `meta` publishes, pinned.
#
# A client binds work to these: `policy_hash` says which rule set judged a file,
# `idiom_table_hash` which preference table, `restriction_matrix_hash` which
# refusals, and `builtin_registry_hash` which module surface. A client that
# cached an answer under one of them and receives the same value back is
# entitled to reuse the answer, so a value that moves without anyone meaning it
# to is a silent lie to every such client.
#
# The unit tests inside `zig build test` already compare a live `meta` response
# to the registries it renders from. They cannot catch this: they read both
# sides from the same build, so an edit that changes a registry changes both
# sides together and they still agree. This gate compares a live response to
# values written down here, which is the only place a deliberate change has to
# be typed a second time.
#
# When a hash moves on purpose, update it here IN THE SAME COMMIT as the change
# that moved it, and say in the message what moved and why. That second edit is
# the whole mechanism: it is what makes an unintended move visible.
#
# Floor: the response must parse and carry all four keys before any comparison
# means anything. A `meta` that stopped emitting a hash would otherwise compare
# empty against empty and pass.
#
# Usage: bash scripts/check-meta-drift.sh

set -euo pipefail

cd "$(dirname "$0")/.."

ZTS="./zig-out/bin/zts"
if [ ! -x "$ZTS" ]; then
  echo "error: $ZTS not built. Run: zig build" >&2
  exit 1
fi

# Pinned 2026-08-12, read from the binary built at that commit.
EXPECTED_PROFILE="zts-advanced-1"
EXPECTED_POLICY_HASH="78c9fec96be277836842b2365a249ed26da46f1f0545f36753e33434cc3fd685"
EXPECTED_IDIOM_HASH="483026f3713c7840df6c464df9670bf67789c1cde7544b8af78e854dab14e746"
# Moved when phase 7 refused `type` and `distinct type`: the matrix gained
# `restriction.type-alias` and `restriction.distinct-type`. Before that it
# moved for `|>`, `pipe()`, and `guard()`, and before that for `interface`. Both are changes to what the matrix says rather than to how it is
# rendered. `policy_hash` holds across both, and that is not an oversight: it
# covers the rule rows - code, category, text, repair intent - and this change
# added no rule and edited none. The same ZTS001 that judged a file yesterday
# judges it today, over a form it now refuses.
EXPECTED_RESTRICTION_HASH="292e27ed10df615603d6df48177d9f1657b2531be01d9ce1dd25b6a320959fbe"
# Moved when `zttp:compose` was deleted: the module surface went from 24
# specifiers to 23. `guard` and `pipe` were parser forms wearing a module's
# clothes, so their native implementations never ran, but they were published
# on this surface and a client bound to it must see them leave.
EXPECTED_BUILTIN_HASH="15d94f12e2ceb3a97cc4308f1969950340754a2279f9a0a76358115d2ef9b22e"

fail() {
  printf 'meta drift: %s\n' "$1" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '{"schema_version":2,"operation":"meta","project_root":".","input":{}}\n' |
  "$ZTS" agent --stdin-json > "$work/meta.json" 2> "$work/err" ||
  fail "the meta operation failed: $(head -n 1 "$work/err")"

# One python pass reads every field, so a response missing any of them fails
# here rather than comparing an empty string against a pinned one.
python3 - "$work/meta.json" > "$work/fields" <<'PY' || fail "meta response is missing a field this gate pins"
import json
import sys

with open(sys.argv[1]) as handle:
    payload = json.load(handle)["payload"]

for key in (
    "profile_id",
    "policy_hash",
    "idiom_table_hash",
    "restriction_matrix_hash",
    "builtin_registry_hash",
):
    value = payload[key]
    if not isinstance(value, str) or not value:
        raise SystemExit("empty %s" % key)
    print(value)
PY

{
  read -r got_profile
  read -r got_policy
  read -r got_idiom
  read -r got_restriction
  read -r got_builtin
} < "$work/fields"

check() {
  local name="$1" got="$2" want="$3"
  [[ "$got" == "$want" ]] || fail "$name moved
  published: $got
  pinned:    $want
If the move was intended, update this script in the same commit and say what moved."
}

check "profile_id" "$got_profile" "$EXPECTED_PROFILE"
check "policy_hash" "$got_policy" "$EXPECTED_POLICY_HASH"
check "idiom_table_hash" "$got_idiom" "$EXPECTED_IDIOM_HASH"
check "restriction_matrix_hash" "$got_restriction" "$EXPECTED_RESTRICTION_HASH"
check "builtin_registry_hash" "$got_builtin" "$EXPECTED_BUILTIN_HASH"

echo "meta drift OK (profile $got_profile, 4 registry hashes match their pins)"

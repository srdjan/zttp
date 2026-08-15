#!/usr/bin/env bash
# scripts/check-meta-drift.sh
#
# The core and frontend identities `meta` publishes, pinned.
#
# A client binds work to these: `policy_hash` says which rule set judged a file,
# `grammar_hash` which core syntax, the TSX frontend hash which authored UI
# syntax and lowering target, `idiom_table_hash` which preference table,
# `restriction_matrix_hash` which refusals, and `builtin_registry_hash` which
# module surface. A client that cached an answer under one of them and receives
# the same value back is entitled to reuse the answer, so a value that moves
# without anyone meaning it to is a silent lie to every such client.
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
# Floor: the response must parse and carry every key before any comparison
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

# Pinned 2026-08-15 after phase 7 made text construction explicit. The core
# grammar no longer admits interpolated templates, the idiom table names joins
# as the one text-construction form, and the restriction matrix refuses both
# interpolation and string-valued addition.
EXPECTED_PROFILE="zts-model-1"
EXPECTED_POLICY_HASH="36fbd29e0fe71693d73c8278d3786ffca1eb184da9d3f66b11310bad5033aeb5"
# Moved when template expressions were removed from the core grammar. TSX is a
# separately hashed frontend that lowers into this exact core identity.
EXPECTED_GRAMMAR_HASH="6201baf9b3b206ae89c59443478fc58305935e5142f9a4672a66b71bb2ddc955"
EXPECTED_FRONTEND_PROFILE="zts-tsx-1"
EXPECTED_FRONTEND_GRAMMAR_HASH="80d4ca8ff675262efc2bca83a4bfeb066f36a66a9c5c29bca27d7dce691033db"
EXPECTED_IDIOM_HASH="740830f33b0ea1dd2be2f244e4e978e8d60e9ae4418d53effca305f86244be6e"
EXPECTED_RESTRICTION_HASH="be9e7992e7afb176eb4dbb47638b596204660a6127be9a59cf72a506375b8895"
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
    "grammar_hash",
    "idiom_table_hash",
    "restriction_matrix_hash",
    "builtin_registry_hash",
):
    value = payload[key]
    if not isinstance(value, str) or not value:
        raise SystemExit("empty %s" % key)
    print(value)

frontends = payload["source_frontends"]
if not isinstance(frontends, list) or len(frontends) != 1:
    raise SystemExit("source_frontends must contain exactly one frontend")
frontend = frontends[0]
for key in ("profile_id", "grammar_hash", "target_grammar_hash"):
    value = frontend[key]
    if not isinstance(value, str) or not value:
        raise SystemExit("empty source_frontends[0].%s" % key)
    print(value)
PY

{
  read -r got_profile
  read -r got_policy
  read -r got_grammar
  read -r got_idiom
  read -r got_restriction
  read -r got_builtin
  read -r got_frontend_profile
  read -r got_frontend_grammar
  read -r got_frontend_target_grammar
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
check "grammar_hash" "$got_grammar" "$EXPECTED_GRAMMAR_HASH"
check "source_frontends[0].profile_id" "$got_frontend_profile" "$EXPECTED_FRONTEND_PROFILE"
check "source_frontends[0].grammar_hash" "$got_frontend_grammar" "$EXPECTED_FRONTEND_GRAMMAR_HASH"
check "source_frontends[0].target_grammar_hash" "$got_frontend_target_grammar" "$EXPECTED_GRAMMAR_HASH"
check "idiom_table_hash" "$got_idiom" "$EXPECTED_IDIOM_HASH"
check "restriction_matrix_hash" "$got_restriction" "$EXPECTED_RESTRICTION_HASH"
check "builtin_registry_hash" "$got_builtin" "$EXPECTED_BUILTIN_HASH"

echo "meta drift OK (core $got_profile, frontend $got_frontend_profile, 6 registry hashes match their pins)"

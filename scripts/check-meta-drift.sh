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

# Pinned 2026-08-15 after phase 7 made record construction explicit. The core
# grammar requires a key and value for every field, the match-only shorthand
# idiom is named as such, and the restriction matrix refuses object shorthand
# and computed record keys.
EXPECTED_PROFILE="zts-advanced-1"
EXPECTED_POLICY_HASH="dd420c0ffb35e1b43ea17e4a79765169da292dd2a9417d9819429f0eceb59e3c"
# Moved when JSX was removed from the core grammar. TSX is now a separately
# hashed frontend that lowers into this exact core identity.
EXPECTED_GRAMMAR_HASH="c5caa05447cc6288b9c2ba84055e297ea72681597bd64cada577e3c4a2a3eb0a"
EXPECTED_FRONTEND_PROFILE="zts-tsx-1"
EXPECTED_FRONTEND_GRAMMAR_HASH="a5777bbacf655c8b34abee2e622cf147eac70048ba24bd066db7a907512c0641"
EXPECTED_IDIOM_HASH="acc50fe37ba8bfe6306c5d6db821ef081b6e67f284676765097784d696436ba1"
EXPECTED_RESTRICTION_HASH="9e0ad04b2a8e5c0016e164598e400d7be4ee87fbf92cdabb8b9f6f0a40fc02c8"
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

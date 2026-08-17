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

# Pinned 2026-08-16 after the declared export-boundary rule joined the
# compiler-owned policy registry. ZTS061 adds one verifier rule and makes the
# policy identity cover that cross-module contract requirement.
EXPECTED_PROFILE="zts-model-1"
EXPECTED_POLICY_HASH="a05c98c7d610d7421481812c57dd55140cfd9d7a2eedf9a29569670392e1dc3c"
# TSX is separately identified, and its hash binds the core grammar it lowers
# into, so the declaration cut moves both hashes even though TSX syntax did not.
EXPECTED_GRAMMAR_HASH="8c555c6dfe5afb98cf73d034a548dd5f18db5a6b540f334a43f0ac871f4d73be"
EXPECTED_FRONTEND_PROFILE="zts-tsx-1"
EXPECTED_FRONTEND_GRAMMAR_HASH="7c9617420918404b14782ce11ffff71f3f1c42f967cb2ca656b7109e417d283d"
EXPECTED_IDIOM_HASH="2a7059a7e3d4747c26af855ebd3a80b9fbb853bc5feb5ea16010bd300a5992db"
# The same boundary cut adds `restriction.raw-export-boundary-type`, so the
# generated restriction matrix and the policy registry move together.
EXPECTED_RESTRICTION_HASH="3409f9e0490c698e67dcd1e7a6e3465f0d14c50e0a611bbe9652025e80911f1b"
# Moved 2026-08-17 as the module surface learned to describe itself: parameter
# names, then summaries trimmed to the four modules whose use protocol their
# signatures cannot carry, then return types - which discovery had never
# published for any export, and whose absence three corpus cases failed on. No specifier joined or left; what changed is
# what a caller is told about the ones already there, which is exactly what a
# client caches under this hash. Discovery used to publish `sqlMany` with a name
# and an effect and nothing else, and a model reading that wrote a SELECT
# statement into the argument that takes a registered query name. Summarising
# all 26 modules doubled the discovery payload to 14,616 bytes; four leaves it
# at 11,061 against a 7,213-byte baseline.
EXPECTED_BUILTIN_HASH="a866c20081b735604ce1b0e1253fa5f125275f2bfe4bbbf8e9398e08959e7f2b"

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

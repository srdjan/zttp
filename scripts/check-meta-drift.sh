#!/usr/bin/env bash
# Pin the compiler identities that a version-2 meta response publishes.

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf 'meta drift: %s\n' "$1" >&2
  exit 1
}

# A build step passes the native reader first and this build's zts second.
# A direct invocation uses zig run and the installed development binary.
if [[ $# -eq 2 ]]; then
  REPO_GATE="$1"
  ZTS="$2"
  [[ -x "$REPO_GATE" ]] || fail "$REPO_GATE is not executable"
elif [[ $# -eq 0 ]]; then
  REPO_GATE=""
  ZTS=./zig-out/bin/zts
else
  fail "usage: bash scripts/check-meta-drift.sh [repo-gate zts]"
fi
[[ -x "$ZTS" ]] || fail "$ZTS not built. Run: zig build"

EXPECTED_PROFILE="zts-model-1"
# The public meta operation supplies these measured Phase 3 identities.
EXPECTED_POLICY_HASH="ebb4b2b0a1456b5024a91fe5bfe41a7833c1ac19da923c9e6b7c0c8fa3624f96"
EXPECTED_GRAMMAR_HASH="8c555c6dfe5afb98cf73d034a548dd5f18db5a6b540f334a43f0ac871f4d73be"
EXPECTED_IDIOM_HASH="2a7059a7e3d4747c26af855ebd3a80b9fbb853bc5feb5ea16010bd300a5992db"
EXPECTED_RESTRICTION_HASH="a2c47c9ccf240cc913719f5ba359a2285aa9854f7cc797a801a7a0e036f3ec58"
EXPECTED_BUILTIN_HASH="95f3733d78ea9446e840ec5119582961de47b160f3c78081a8113c1d6a9bd58b"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -z "$REPO_GATE" ]]; then
  REPO_GATE="$work/repo-gate"
  zig build-exe tooling/repo_gate.zig \
    -femit-bin="$REPO_GATE" \
    --cache-dir "$work/cache" \
    --global-cache-dir "$work/global-cache"
fi

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

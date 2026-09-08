#!/usr/bin/env bash
# Assert the deployed runtime carries no expert-agent / model-provider surface.
#
# The pi package (the `zttp expert` agent) embeds the Anthropic/OpenAI HTTP
# client host strings. Those markers must appear ONLY in the developer `zttp`
# binary - never in the deployable `zttp-runtime` template, and never in the
# pi-free `zts` analyzer binary. This turns "pi is not in the runtime" from an
# incidental build property into an enforced invariant: a future edit that wires
# pi_app into runtime_main (or back into zts) fails this check.
#
# Usage: check-runtime-purity.sh <dev-zttp-bin> <runtime-bin> <zts-bin>
#
# `grep -acF` scans the binary directly (no `strings`/binutils dependency, so
# this runs on minimal CI images) and reads the whole file. `|| true` absorbs
# grep's exit 1 on zero matches under `set -e`.
set -eu

dev_bin="$1"
runtime_bin="$2"
zts_bin="$3"

# Markers that exist only in pi's provider HTTP clients, one line per
# `family:marker`. Every provider family with a client under
# packages/pi/src/providers/ must appear here: the floor below is per family, so
# a family with no marker fails instead of being covered by a sibling's.
#
# The list once named only Anthropic and OpenAI - the two providers CLAUDE.md
# forbids here - and omitted DeepSeek, which is the shipped default, and the
# local MLX server. A single-marker floor was satisfied by the legacy strings,
# so the gate printed "runtime purity OK" without ever asserting that the
# provider a user actually gets is absent from the shipped binary.
markers=(
  "anthropic:api.anthropic.com"
  "anthropic:anthropic-version"
  "openai:api.openai.com"
  "deepseek:api.deepseek.com"
  "local:http://127.0.0.1:8080"
)

contains() {
  grep -acF "$2" "$1" || true
}

fail=0

# 0. Floor on the gate's own input: the marker list must name every provider
#    family that has a client, or a family added later is checked by nothing
#    and this gate reports a pass over a binary it never examined for it.
providers_dir="packages/pi/src/providers"
if [ ! -d "$providers_dir" ]; then
  echo "error: '$providers_dir' does not exist - the provider list this gate checks against is gone; update the gate" >&2
  exit 1
fi
declared_families="$(printf '%s\n' "${markers[@]}" | cut -d: -f1 | sort -u)"
for family_dir in "$providers_dir"/*/; do
  family="$(basename "$family_dir")"
  [ "$family" = "testdata" ] && continue
  if ! printf '%s\n' "$declared_families" | grep -qx "$family"; then
    echo "error: provider family '$family' has a client under $providers_dir and no marker in this gate; add one" >&2
    fail=1
  fi
done

# 1. The shipped/analyzer binaries must be clean.
for bin in "$runtime_bin" "$zts_bin"; do
  for entry in "${markers[@]}"; do
    m="${entry#*:}"
    if [ "$(contains "$bin" "$m")" -gt 0 ]; then
      echo "error: '$(basename "$bin")' contains agent/provider marker '$m' - pi linked where it must not be" >&2
      fail=1
    fi
  done
done

# 2. Floor, per family. The dev binary must carry at least one marker for EVERY
#    declared family, not one marker overall. A family whose markers all went
#    stale is a family this gate no longer looks for in the shipped binary,
#    while still printing a pass - and the residual risk the finding named is a
#    partial extraction of one provider path, which is exactly the case a
#    per-family floor sees and a global one does not.
for family in $declared_families; do
  present=0
  for entry in "${markers[@]}"; do
    [ "${entry%%:*}" = "$family" ] || continue
    if [ "$(contains "$dev_bin" "${entry#*:}")" -gt 0 ]; then
      present=$((present + 1))
    fi
  done
  if [ "$present" -eq 0 ]; then
    echo "error: no '$family' markers found in dev binary '$(basename "$dev_bin")' - this gate cannot assert that provider is absent from the shipped binary; update its markers" >&2
    fail=1
  fi
done

# 3. The HTTP server must go through engine_adapter for zts engine types and
#    policy helpers. Other runtime files still have direct engine imports while
#    the larger decoupling work proceeds, but server.zig is now an enforced
#    boundary.
#    A missing input is a failure, not a skip. This was wrapped in
#    `if [ -f ... ]` with no else, so renaming or moving the file made the
#    "enforced boundary" silently stop being enforced - in the very script
#    a-gate-that-counts-nothing-still-reports-a-pass.md cites as the model.
server_src="packages/runtime/src/server.zig"
if [ ! -f "$server_src" ]; then
  echo "error: '$server_src' does not exist - the engine-import boundary this gate enforces has no input; point the gate at the file's new location" >&2
  exit 1
fi
server_boundary_hits="$(grep -nE '@import\("zts"\)|(^|[^[:alnum:]_])zts\.' "$server_src" || true)"
if [ -n "$server_boundary_hits" ]; then
  echo "error: server.zig imports zts directly; use packages/runtime/src/engine_adapter.zig" >&2
  echo "$server_boundary_hits" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "runtime purity OK: no agent/provider surface in $(basename "$runtime_bin") or $(basename "$zts_bin")"
fi
exit "$fail"

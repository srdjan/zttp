#!/usr/bin/env bash
# scripts/verify.sh
#
# One-command local gate that mirrors the `test` job in
# .github/workflows/ci.yml step-for-step, in order, one process per step.
#
# Sequential by design: the build graph may run the pool-heavy `test` and
# `test-zruntime` roots in parallel and reintroduce the macOS teardown TRAP
# that build.zig (see the comment above the test step) warns about. We invoke
# them as separate processes here rather than adding a `verify` build step.
#
# The docs drift and link gates are NOT separate steps here: `test-docs-drift`
# and `test-doc-links` are both dependencies of the `test` step (build.zig), and
# neither is cached, so step 1 already runs them. Do not re-add them.
#
# The format gate is a separate CI job (ci.yml: Check formatting); it is run
# LAST here so a local `bash scripts/verify.sh` still catches formatting drift
# without gating the test suite on it. Note: the repo is fmt-clean only under
# the pinned toolchain (0.16.0, matching CI's ZIG_VERSION); running under a
# nightly `zig` may report spurious drift, so keeping fmt last means the full
# correctness suite always runs first regardless.
#
# Usage (from anywhere; the script cd's to the repo root):
#   bash scripts/verify.sh             # the per-commit gate, run by ci.yml
#   bash scripts/verify.sh --release   # adds the release-only gates
#
# Release-evidence provenance is a RELEASE gate and not a per-commit one. It
# fails until docs/coverage.json and docs/convergence.json are republished from
# a source commit the tree still matches, which every ordinary source commit
# breaks. Running it on every pull request would make main red between a commit
# and the next corpus republish, so only `--release` runs it.

set -euo pipefail

cd "$(dirname "$0")/.."

release_mode=false
for arg in "$@"; do
  case "$arg" in
    --release) release_mode=true ;;
    *)
      echo "usage: bash scripts/verify.sh [--release]" >&2
      exit 2
      ;;
  esac
done

step() {
  printf '\n========================================\n'
  printf '>> %s\n' "$1"
  printf '========================================\n'
}

step "zig build test  (aggregate unit suite)"
if [ "$(uname -s)" = "Darwin" ]; then
  zig build test -j1
else
  zig build test
fi

step "zig build test-zruntime  (standalone runtime root)"
zig build test-zruntime

step "zig build -Doptimize=ReleaseFast  (release binaries)"
zig build -Doptimize=ReleaseFast

step "zig build wasm  (browser proof analyzer)"
zig build wasm

step "zig build smoke-v1  (v1 user-flow smoke)"
zig build smoke-v1

step "zig build test-panic-isolation  (handler panic isolation E2E)"
zig build test-panic-isolation

step "zig build test-cli -Dstudio  (studio workbench unit tests)"
# studio.zig only compiles under -Dstudio, so its unit tests (incl. the
# TRADE_TABLE drift gate) run in no default target. Build the CLI test suite
# with studio enabled so they are actually exercised.
zig build test-cli -Dstudio

step "bash scripts/test-examples.sh  (example handler tests)"
bash scripts/test-examples.sh

step "bash scripts/check-normalize-idempotent.sh  (double-normalize byte-idempotence)"
bash scripts/check-normalize-idempotent.sh

step "bash scripts/check-idiom-table.sh  (spec 4.2.1 table against the registry)"
bash scripts/check-idiom-table.sh

step "bash scripts/check-canonical-style.sh  (the canonical-style skill's examples against the rule registry)"
bash scripts/check-canonical-style.sh

step "bash scripts/check-grammar-drift.sh  (spec section 8 grammar against the registry)"
bash scripts/check-grammar-drift.sh

step "bash scripts/check-decision-registry.sh  (every published decision kind is emitted)"
bash scripts/check-decision-registry.sh

step "bash scripts/check-meta-drift.sh  (meta's registry hashes against their pins)"
bash scripts/check-meta-drift.sh

step "bash scripts/check-agent-determinism.sh  (v2 agent transport determinism)"
bash scripts/check-agent-determinism.sh

step "bash scripts/test-install-archive-safety.sh  (installer archive path safety)"
bash scripts/test-install-archive-safety.sh

step "policy hash unchanged  (ci.yml: Assert policy hash unchanged)"
if [ ! -f policy-hash.txt ]; then
  echo "error: policy-hash.txt is missing - the policy hash baseline must be committed" >&2
  echo "Run: ./zig-out/bin/zts describe-rule --hash > policy-hash.txt" >&2
  exit 1
fi
EXPECTED=$(cat policy-hash.txt)
ACTUAL=$(./zig-out/bin/zts describe-rule --hash)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "error: policy hash mismatch - rules changed without updating policy-hash.txt" >&2
  echo "Expected: $EXPECTED" >&2
  echo "Actual:   $ACTUAL" >&2
  echo "Run: ./zig-out/bin/zts describe-rule --hash > policy-hash.txt" >&2
  exit 1
fi
echo "policy hash OK: $ACTUAL"

step "bash scripts/check-semantics-spec.sh  (strict semantics spec gate)"
bash scripts/check-semantics-spec.sh

step "zts module-spec-render --check  (module specs match the Zig bindings)"
# The bindings are the source of truth; packages/modules/module-specs/*.json is
# generated. This reports every stale path, and treats an unreadable file as
# stale rather than skipping it.
./zig-out/bin/zts module-spec-render --check

step "verify expert subsystem  (ci.yml: Verify expert subsystem)"
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required for the expert-subsystem check (matches ci.yml)" >&2
  exit 1
fi
META=$(./zig-out/bin/zts meta --json)
echo "$META" | jq -e '.rule_count >= 25' >/dev/null
echo "$META" | jq -e '.policy_hash | length == 64' >/dev/null
echo "expert subsystem OK"

if [ "$release_mode" = true ]; then
  step "zig build release-provenance  (clean, current release evidence)"
  zig build release-provenance
fi

step "zig fmt --check build.zig packages/  (ci.yml: Check formatting)"
zig fmt --check build.zig packages/

printf '\n========================================\n'
if [ "$release_mode" = true ]; then
  printf '>> verify.sh: all CI and release gates passed\n'
else
  printf '>> verify.sh: all CI test-job steps passed\n'
fi
printf '========================================\n'

#!/usr/bin/env bash
# Build the zts analyzer as a wasm module and publish it to the official
# website repo under a content-hashed immutable filename.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "Building wasm analyzer (ReleaseSmall)..."
zig build wasm -Doptimize=ReleaseSmall

source_wasm="$repo_root/zig-out/wasm/zts-analyzer.wasm"
python3 "$repo_root/scripts/wasm-playground-publish.py" \
  --website-root "$repo_root/../zttp-website" \
  --wasm "$source_wasm"

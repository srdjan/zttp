#!/usr/bin/env bash
# Build the zts analyzer as a wasm module and publish it to the official
# website repo under a content-hashed immutable filename.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "Building and publishing wasm analyzer (ReleaseSmall)..."
zig build wasm-playground-publish -Doptimize=ReleaseSmall -- \
  --website-root "$repo_root/../zttp-website"

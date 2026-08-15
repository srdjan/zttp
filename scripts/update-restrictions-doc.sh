#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

zig build

generated_doc=$(mktemp "${TMPDIR:-/tmp}/zttp-restrictions.XXXXXX")
trap 'rm -f "$generated_doc"' EXIT

./zig-out/bin/zts restrictions --markdown > "$generated_doc"
mv "$generated_doc" docs/restrictions-to-proofs.md
trap - EXIT

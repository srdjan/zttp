#!/usr/bin/env bash
# scripts/zts-training-export.sh
#
# Emit the sealed ZTS training contract bundle, then verify it on disk.
#
# The exporter itself reads no git state. It spawns no processes and touches no
# ambient input, which is what lets its output be predicted by a unit test
# (see packages/tools/src/training_export.zig). This script is the caller that
# supplies provenance: it resolves HEAD and the worktree state and passes both
# in. A dirty tree is passed through as `dirty` rather than refused here, so the
# refusal happens in exactly one place - the exporter - instead of two that can
# drift apart.
#
# After writing, every digest the manifest claims is recomputed from the file on
# disk and compared. A manifest that names a file it did not write, or claims a
# digest the bytes do not produce, fails here rather than in the consumer.
#
# Floor: the manifest must name at least one file before the digest comparison
# means anything. A manifest whose `files` array failed to render would
# otherwise compare an empty list against an empty list and report success.
#
# Usage: bash scripts/zts-training-export.sh <zts-binary> [--out <dir>]

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <zts-binary> [--out <dir>]" >&2
  exit 2
fi

ZTS_BIN="$1"
shift

OUT_DIR="zig-out/zts-training-export"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      shift
      [ "$#" -gt 0 ] || { echo "--out needs a directory" >&2; exit 2; }
      OUT_DIR="$1"
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [ ! -x "$ZTS_BIN" ]; then
  echo "not an executable: $ZTS_BIN" >&2
  exit 2
fi

COMMIT="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain)" ]; then
  WORKTREE="dirty"
else
  WORKTREE="clean"
fi

echo "zts-training-export: commit ${COMMIT} worktree ${WORKTREE}"

"$ZTS_BIN" zts-training-export \
  --out "$OUT_DIR" \
  --commit "$COMMIT" \
  --worktree "$WORKTREE"

MANIFEST="${OUT_DIR}/manifest.json"
if [ ! -f "$MANIFEST" ]; then
  echo "zts-training-export: no manifest at ${MANIFEST}" >&2
  exit 1
fi

# One "<path> <sha256>" line per entry in the manifest's files array.
ENTRIES="$(
  python3 - "$MANIFEST" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    manifest = json.load(fh)
for entry in manifest["files"]:
    print(entry["path"], entry["sha256"])
PY
)"

COUNT="$(printf '%s\n' "$ENTRIES" | grep -c . || true)"
MIN_FILES=1
if [ "$COUNT" -lt "$MIN_FILES" ]; then
  echo "zts-training-export: manifest names ${COUNT} files, floor is ${MIN_FILES}" >&2
  exit 1
fi

STALE=0
while read -r path claimed; do
  [ -n "$path" ] || continue
  full="${OUT_DIR}/${path}"
  if [ ! -f "$full" ]; then
    echo "  missing: ${path}" >&2
    STALE=1
    continue
  fi
  actual="$(shasum -a 256 "$full" | awk '{print $1}')"
  if [ "$actual" != "$claimed" ]; then
    echo "  digest mismatch: ${path}" >&2
    echo "    manifest: ${claimed}" >&2
    echo "    on disk:  ${actual}" >&2
    STALE=1
  fi
done <<< "$ENTRIES"

if [ "$STALE" -ne 0 ]; then
  echo "zts-training-export: bundle does not match its manifest" >&2
  exit 1
fi

echo "zts-training-export: verified ${COUNT} files against ${MANIFEST}"

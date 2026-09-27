#!/usr/bin/env bash
# Check the local runtime-safety setting in every acceptance-kernel function.

set -euo pipefail

cd "$(dirname "$0")/.."

# Include cached and untracked source files. The latter keeps a newly added
# kernel file inside the gate before it is staged. The Zig parser distinguishes
# function bodies in test blocks and handles signatures that span many lines.
git ls-files -z --cached --others --exclude-standard -- 'packages/proof-checker/src/*.zig' |
  xargs -0 zig run scripts/kernel_safety_gate.zig --

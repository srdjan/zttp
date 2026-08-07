#!/usr/bin/env bash
set -euo pipefail

# `zig build test` reaches this script, so it must resolve the toolchain the
# same way the rest of scripts/ does. A bare `zig` fails the whole gate for a
# caller who invoked the compiler by absolute path or a versioned name.
ZIG="${ZIG:-zig}"

# Enumerate tracked sources with NUL delimiters so paths containing spaces or
# shell metacharacters remain single arguments. Exclude the metric itself so
# checking it in does not move the product baseline it was built to measure.
# The Zig tool owns the empty input and parse-failure floors.
git ls-files -z -- '*.zig' ':!tooling/production_branch_metric.zig' |
  "$ZIG" run tooling/production_branch_metric.zig -- --require-package-floor --paths0-from-stdin "$@"

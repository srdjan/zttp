#!/usr/bin/env bash
set -euo pipefail

# Enumerate tracked sources with NUL delimiters so paths containing spaces or
# shell metacharacters remain single arguments. Exclude the metric itself so
# checking it in does not move the product baseline it was built to measure.
# The Zig tool owns the empty input and parse-failure floors.
git ls-files -z -- '*.zig' ':!tooling/production_branch_metric.zig' |
  zig run tooling/production_branch_metric.zig -- --require-package-floor --paths0-from-stdin "$@"

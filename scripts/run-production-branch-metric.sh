#!/usr/bin/env bash
set -euo pipefail

# The build steps pass the built metric tool: `--tool <path> [metric arguments]`.
# No other route runs this script.
if [[ "${1:-}" != --tool || -z "${2:-}" ]]; then
  echo 'usage: run-production-branch-metric.sh --tool <metric-executable> [metric arguments]; run zig build production-branch-metric' >&2
  exit 2
fi
[[ -x "$2" ]] || {
  echo "production branch metric: $2 is not an executable" >&2
  exit 2
}
metric=("$2")
shift 2

# Enumerate tracked sources with NUL delimiters so paths containing spaces or
# shell metacharacters remain single arguments. Exclude the metric itself so
# checking it in does not move the product baseline it was built to measure.
# The Zig tool owns the empty input and parse-failure floors.
git ls-files -z -- '*.zig' ':!tooling/production_branch_metric.zig' |
  xargs -0 sh -c '
    for file do
      [ -f "$file" ] && printf "%s\0" "$file"
    done
  ' sh |
  "${metric[@]}" --require-package-floor --paths0-from-stdin "$@"

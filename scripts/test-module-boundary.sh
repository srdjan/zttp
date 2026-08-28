#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf 'module boundary test: %s\n' "$1" >&2
  exit 1
}

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
printf '%s\n' 'const zts = @import("zts");' > "$fixture_dir/alias.zig"
printf '%s\n' 'const leaked = zts.handler_analyzer;' > "$fixture_dir/use.zig"

# Batch scanning must reset aliases between files. Add a pair after the real
# runtime files: the first imports zts, while the second only spells the same
# identifier. If aliases leak across the file boundary, handler_analyzer is
# misreported as an undeclared runtime reach.
FIXTURE_ALIAS="$fixture_dir/alias.zig" \
FIXTURE_USE="$fixture_dir/use.zig" \
FIXTURE_MARKER="$fixture_dir/injected-paths" \
bash -c '
  git() {
    command git "$@"
    if [[ "$1" == "ls-files" && "$2" == "-z" && "$3" == "packages/runtime/*.zig" ]]; then
      printf "%s\0%s\0" "$FIXTURE_ALIAS" "$FIXTURE_USE"
      printf "%s\n%s\n" "$FIXTURE_ALIAS" "$FIXTURE_USE" > "$FIXTURE_MARKER"
    fi
  }
  export -f git
  bash scripts/check-module-boundary.sh
' >/dev/null || fail "an alias leaked from one scanned file into the next"

[[ -f "$fixture_dir/injected-paths" ]] ||
  fail "alias-isolation fixture did not intercept runtime enumeration"
[[ "$(wc -l < "$fixture_dir/injected-paths")" -eq 2 ]] ||
  fail "alias-isolation fixture did not append both fixture paths"

# Enumeration failures must be attributed before an incomplete file set can
# turn into an allowlist verdict.
if failure_output="$(
  bash -c '
    git() {
      if [[ "$1" == "ls-files" && "$2" == "-z" && "$3" == "packages/runtime/*.zig" ]]; then
        return 1
      fi
      command git "$@"
    }
    export -f git
    bash scripts/check-module-boundary.sh
  ' 2>&1
)"; then
  fail "injected enumeration failure unexpectedly passed"
fi

case "$failure_output" in
  *"module boundary: failed to enumerate tracked Zig files for runtime"*) ;;
  *)
    printf '%s\n' "$failure_output" >&2
    fail "enumeration failure was not reported at its source"
    ;;
esac

# A scanner error must not be reclassified as an unused allowlist row. Both
# files below carry runtime's spec_discharge reach, so dropping both scans
# reproduces the misleading CI verdict that prompted this regression.
if failure_output="$(
  bash -c '
    awk() {
      local arg
      for arg in "$@"; do
        case "$arg" in
          packages/runtime/src/counterexample_pipeline.zig|packages/runtime/src/witnesses_cli.zig)
            return 1
            ;;
        esac
      done
      command awk "$@"
    }
    export -f awk
    bash scripts/check-module-boundary.sh
  ' 2>&1
)"; then
  fail "injected scanner failure unexpectedly passed"
fi

case "$failure_output" in
  *"module boundary: failed to scan tracked Zig files for runtime"*) ;;
  *)
    printf '%s\n' "$failure_output" >&2
    fail "scanner failure was not reported at its source"
    ;;
esac

bash scripts/check-module-boundary.sh

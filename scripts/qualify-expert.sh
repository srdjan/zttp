#!/usr/bin/env bash
# Run one explicit candidate through three complete, report-only expert cohorts.
#
# This script spends real model time. It never promotes cassettes and never
# edits the local-provider or product default. Redirect stdout outside the
# clean repository to retain the final decision report.

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf 'expert qualification: %s\n' "$1" >&2
  exit 1
}

[[ "${ZTTP_CODEGEN_QUALIFY_CONFIRM:-}" == "1" ]] ||
  fail "set ZTTP_CODEGEN_QUALIFY_CONFIRM=1 after reviewing the three-run model cost"
[[ -n "${ZTTP_CODEGEN_PROVIDER:-}" ]] || fail "ZTTP_CODEGEN_PROVIDER is required"
[[ -n "${ZTTP_CODEGEN_MODEL:-}" ]] || fail "ZTTP_CODEGEN_MODEL is required"
[[ -z "${ZTTP_CODEGEN_RECORD:-}" ]] || fail "ZTTP_CODEGEN_RECORD conflicts with report-only qualification"
[[ -z "${ZTTP_CODEGEN_QUALIFY:-}" ]] || fail "the script owns ZTTP_CODEGEN_QUALIFY"
[[ -z "${ZTTP_CODEGEN_REQUIRE_GREEN:-}" ]] ||
  fail "ZTTP_CODEGEN_REQUIRE_GREEN would hide measured failures"

for filtered_var in ZTTP_CODEGEN_ONLY ZTTP_CODEGEN_LIMIT ZTTP_CODEGEN_TOOLS; do
  [[ -z "${!filtered_var:-}" ]] || fail "$filtered_var makes the denominator incomplete"
done

case "$ZTTP_CODEGEN_PROVIDER" in
  local|claude|openai|deepseek) ;;
  *) fail "unsupported ZTTP_CODEGEN_PROVIDER: $ZTTP_CODEGEN_PROVIDER" ;;
esac

if [[ "$ZTTP_CODEGEN_PROVIDER" == "local" ]]; then
  for required_var in \
    ZTTP_CODEGEN_MODEL_REVISION \
    ZTTP_CODEGEN_MODEL_ARTIFACT_SHA256 \
    ZTTP_CODEGEN_QUANTIZATION \
    ZTTP_CODEGEN_CHAT_TEMPLATE_SHA256 \
    ZTTP_CODEGEN_SERVING_ARGS \
    ZTTP_CODEGEN_HARDWARE \
    ZTTP_CODEGEN_OS \
    ZTTP_CODEGEN_PEAK_MEMORY_BYTES; do
    [[ -n "${!required_var:-}" ]] || fail "$required_var is required for a reproducible local report"
  done
fi

source_commit="$(git rev-parse HEAD 2>/dev/null || true)"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || fail "the source commit is unknown"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] ||
  fail "qualification requires a clean worktree"

run_tmp="$(mktemp -d "${TMPDIR:-/tmp}/zttp-expert-qualification.XXXXXX")"
cleanup() {
  rm -rf "$run_tmp"
}
trap cleanup EXIT HUP INT TERM

echo ">> building zttp for runtime intent checks" >&2
zig build >&2

for run_number in 1 2 3; do
  log="$run_tmp/run-$run_number.log"
  record="$run_tmp/run-$run_number.json"
  echo ">> qualification run $run_number/3: $ZTTP_CODEGEN_PROVIDER/$ZTTP_CODEGEN_MODEL" >&2
  if ! ZTTP_CODEGEN_QUALIFY=1 \
    zig build test-expert-app -Dtest-filter="record codegen baseline corpus" >"$log" 2>&1; then
    cat "$log" >&2
    fail "live run $run_number failed before a complete report was emitted"
  fi
  if ! python3 scripts/extract-expert-qualification-run.py "$log" >"$record"; then
    cat "$log" >&2
    fail "live run $run_number emitted no valid complete report"
  fi
  [[ "$(git rev-parse HEAD 2>/dev/null || true)" == "$source_commit" ]] ||
    fail "source commit changed during qualification"
  [[ -z "$(git status --porcelain --untracked-files=normal)" ]] ||
    fail "worktree changed during qualification"
done

report="$run_tmp/report.json"
status=0
zig build expert-qualification -- \
  "$run_tmp/run-1.json" \
  "$run_tmp/run-2.json" \
  "$run_tmp/run-3.json" >"$report" || status=$?
cat "$report"
if [[ "$status" -ne 0 ]]; then
  echo ">> candidate did not qualify; defaults remain unchanged" >&2
  exit "$status"
fi
echo ">> candidate qualified; changing either default remains a separate product decision" >&2

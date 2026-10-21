#!/usr/bin/env bash
# Rejection probes for the ripgrep floors in check-capability-helpers.sh and
# check-docs-drift.sh. Each gate must fail when rg is unusable. A gate that
# treats a broken scanner as "no match" reports a pass over a corpus it never
# read. Two stubs exercise the two floors: one fails the up-front self-test,
# the other passes the self-test and then exits 2 on every scan.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf 'gate floor test: %s\n' "$1" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'command rm -rf "$work"' EXIT

mkdir "$work/selftest" "$work/scan" "$work/empty"

# The self-test call is the only one that passes -q.
cat > "$work/selftest/rg" <<'STUB'
#!/bin/sh
exit 2
STUB
cat > "$work/scan/rg" <<'STUB'
#!/bin/sh
for arg in "$@"; do
  if [ "$arg" = "-q" ]; then
    exit 0
  fi
done
echo "stub rg: simulated scan error" >&2
exit 2
STUB
chmod +x "$work/selftest/rg" "$work/scan/rg"

# A PATH with no rg: link the tools the gates need, minus rg.
for tool in bash git xargs mktemp rm cat grep sed awk tr wc sort paste dirname env sh; do
  resolved="$(command -v "$tool" || true)"
  [[ -n "$resolved" ]] && ln -s "$resolved" "$work/empty/$tool"
done

expect_failure() {
  local label="$1"
  local path_dir="$2"
  local script="$3"
  local needle="$4"
  local output
  if output="$(PATH="$path_dir:/usr/bin:/bin" bash "$script" 2>&1)"; then
    fail "$label: $script passed with an unusable rg"
  fi
  case "$output" in
    *"$needle"*) ;;
    *) fail "$label: $script failed, but not for the expected reason: $output" ;;
  esac
}

for script in scripts/check-capability-helpers.sh scripts/check-docs-drift.sh; do
  expect_failure "rg exits 2 on the self-test" "$work/selftest" "$script" "PCRE2 self-test failed"
  expect_failure "rg exits 2 on a scan" "$work/scan" "$script" "rg errored"
done

# No rg at all. /usr/bin and /bin may hold a real rg on some hosts, so this
# probe uses only the linked tools.
for script in scripts/check-capability-helpers.sh scripts/check-docs-drift.sh; do
  if output="$(PATH="$work/empty" "$(command -v bash)" "$script" 2>&1)"; then
    fail "missing rg: $script passed with no rg on PATH"
  fi
  case "$output" in
    *"not on PATH"*) ;;
    *) fail "missing rg: $script failed for the wrong reason: $output" ;;
  esac
done

# scripts/test-examples.sh: a suite that reports zero passed tests must fail
# even with zero failures. A fake zttp stands in for the real binary, so the
# probe takes no build and no example input. The control proves the fake is
# accepted when it reports a passing test.
mkdir "$work/examples"
fake="$work/examples/zttp"
cat > "$fake" <<'STUB'
#!/bin/sh
if [ "$1" = "serve" ]; then
  echo "Results: $FAKE_PASSED passed, 0 failed, $FAKE_PASSED total"
fi
exit 0
STUB
chmod +x "$fake"

if control_output="$(FAKE_PASSED=1 bash scripts/test-examples.sh "$fake" 2>&1)"; then
  :
else
  fail "examples control: a suite with one passing test was rejected: $control_output"
fi
if zero_output="$(FAKE_PASSED=0 bash scripts/test-examples.sh "$fake" 2>&1)"; then
  fail "examples: a suite with zero passed tests and zero failures was accepted"
fi
case "$zero_output" in
  *"FAIL  handler/handler.ts (0 passed, 0 failed)"*) ;;
  *) fail "examples: zero-test run failed for the wrong reason: $zero_output" ;;
esac

echo "gate floor test: ok (rg floors in 2 scripts, 3 probes each; examples zero-test probe)"

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

# check-kernel-safety.sh and check-capability-helpers.sh: BSD xargs exits 0
# without running on empty input, so each gate counts its input first. Each
# probe runs a copy of the script in a scratch repository with too few files.
# The capability control proves the same scratch layout passes at the floor.
make_scratch() {
  local dir="$1" count="$2" prefix="$3"
  mkdir -p "$dir/scripts" "$dir/$prefix"
  command cp scripts/check-kernel-safety.sh scripts/check-capability-helpers.sh "$dir/scripts/"
  git -C "$dir" init -q
  local i=0
  while [[ "$i" -lt "$count" ]]; do
    : > "$dir/$prefix/f$i.zig"
    i=$((i + 1))
  done
  git -C "$dir" add -A
}

expect_floor_failure() {
  local label="$1" dir="$2" script="$3"
  local output
  if output="$(cd "$dir" && bash "scripts/$script" 2>&1)"; then
    fail "$label: $script passed with too few input files"
  fi
  case "$output" in
    *"the floor is"*) ;;
    *) fail "$label: $script failed for the wrong reason: $output" ;;
  esac
}

make_scratch "$work/k0" 0 packages/proof-checker/src
make_scratch "$work/k12" 12 packages/proof-checker/src
make_scratch "$work/c0" 0 packages/modules/src
make_scratch "$work/c29" 29 packages/modules/src
make_scratch "$work/c30" 30 packages/modules/src
expect_floor_failure "kernel safety, empty list" "$work/k0" check-kernel-safety.sh
expect_floor_failure "kernel safety, 12 files" "$work/k12" check-kernel-safety.sh
expect_floor_failure "capability helpers, empty list" "$work/c0" check-capability-helpers.sh
expect_floor_failure "capability helpers, 29 files" "$work/c29" check-capability-helpers.sh
if control_output="$(cd "$work/c30" && bash scripts/check-capability-helpers.sh 2>&1)"; then
  :
else
  fail "capability control: 30 empty files were rejected: $control_output"
fi

# audit-docs.sh must reject an empty inventory and every failed scanner.
mkdir "$work/docs-empty" "$work/docs-not-git" "$work/docs-scan" "$work/fake-perl"
git -C "$work/docs-empty" init -q
git -C "$work/docs-scan" init -q
printf '[missing](missing.md)\n' > "$work/docs-scan/README.md"
git -C "$work/docs-scan" add README.md
cat > "$work/fake-perl/perl" <<'STUB'
#!/bin/sh
exit 2
STUB
chmod +x "$work/fake-perl/perl"

expect_docs_failure() {
  local label="$1" dir="$2" path="$3" needle="$4"
  local output
  if output="$(PATH="$path" bash scripts/audit-docs.sh "$dir" 2>&1)"; then
    fail "$label: audit-docs.sh reported success"
  fi
  case "$output" in
    *"$needle"*) ;;
    *) fail "$label: audit-docs.sh failed for the wrong reason: $output" ;;
  esac
}

expect_docs_failure "documentation links, empty inventory" "$work/docs-empty" "$PATH" "no tracked documentation files"
expect_docs_failure "documentation links, failed Git inventory" "$work/docs-not-git" "$PATH" "tracked documentation inventory failed"
expect_docs_failure "documentation links, failed Perl scan" "$work/docs-scan" "$work/fake-perl:$PATH" "Perl link scan failed"

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

echo "gate floor test: ok (scanner and input floors, examples zero-test probe)"

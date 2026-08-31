#!/usr/bin/env bash
#
# Acceptance-kernel boundary and floor gate.
#
# `packages/proof-checker` is the only thing in this repository whose word
# decides whether an artifact may serve production traffic. That is worth
# auditing, and an audit is only cheap while the package stays a leaf. This gate
# pins two things:
#
#   1. The kernel imports nothing but `std` and its own siblings, and reaches no
#      ambient capability: no filesystem, no clock, no process, no network, no
#      signing. A certificate is checked from bytes the caller already holds.
#
#   2. The suite that is cited as evidence for the kernel is not empty. A `zig
#      build test-proof-checker` over a package with no tests reports a pass, so
#      the count is asserted here instead of assumed there.
#
# Both directions fail: a new forbidden import fails, and so does a src file
# that `src/test_root.zig` does not reference or that carries no test at all.

set -euo pipefail

cd "$(dirname "$0")/.."

pkg="packages/proof-checker"
src="$pkg/src"
test_root="$src/test_root.zig"

fail=0
note() { printf 'proof-checker: %s\n' "$1" >&2; fail=1; }

[[ -d "$src" ]] || { note "missing $src"; exit 1; }
[[ -f "$test_root" ]] || { note "missing $test_root"; exit 1; }

# ---------------------------------------------------------------------------
# Floor: the file set the rest of this gate reads must not be empty.
# ---------------------------------------------------------------------------
sources=()
while IFS= read -r -d '' path; do
  case "$path" in
    *.zig) sources+=("$path") ;;
  esac
done < <(git ls-files -z --cached --others --exclude-standard "$src" | sort -z)
# The kernel is small on purpose, but "smaller than this" means the glob broke.
min_sources=6
if [[ ${#sources[@]} -lt $min_sources ]]; then
  note "found ${#sources[@]} source files under $src, expected at least $min_sources - the gate is reading nothing"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Leaf boundary.
# ---------------------------------------------------------------------------
# The package manifest must declare no dependencies at all.
if ! grep -q '\.dependencies = \.{}' "$pkg/build.zig.zon"; then
  note "$pkg/build.zig.zon declares dependencies; the acceptance kernel must stay a leaf"
fi

# Imports: `std` plus sibling files in this directory. Anything else - a package
# name, a relative path that leaves the directory - is a widening of the TCB.
while IFS= read -r line; do
  file="${line%%:*}"
  rest="${line#*:}"
  target="$(printf '%s' "$rest" | sed -n 's/.*@import("\([^"]*\)").*/\1/p')"
  [[ -n "$target" ]] || continue
  case "$target" in
    std) continue ;;
    */*) note "$file imports '$target': the kernel may not reach outside its own directory" ;;
    *.zig)
      if [[ ! -f "$src/$target" ]]; then
        note "$file imports '$target', which is not a sibling of the kernel"
      fi
      ;;
    *) note "$file imports package '$target': the kernel must stay a leaf" ;;
  esac
done < <(grep -n '@import(' "${sources[@]}" || true)

# Ambient capability. SHA-256 is permitted: hashing bytes the caller supplied is
# pure. Signing, I/O, time, and process control are not.
forbidden=(
  'std\.fs\.'
  'std\.process\.'
  'std\.time\.'
  'std\.net\.'
  'std\.Thread'
  'std\.posix'
  'std\.os\.'
  'std\.http'
  'std\.crypto\.sign'
  'std\.crypto\.random'
  'std\.Random'
  'getStdOut'
  'getStdErr'
  'std\.heap\.'
)
for pattern in "${forbidden[@]}"; do
  if hits="$(grep -nE "$pattern" "${sources[@]}" || true)"; [[ -n "$hits" ]]; then
    note "ambient capability '$pattern' reached from the kernel:"
    printf '%s\n' "$hits" >&2
  fi
done

# Allocation. The kernel is allocation-free so a certificate cannot choose how
# much memory a consumer spends.
if hits="$(grep -nE 'std\.mem\.Allocator|allocator' "${sources[@]}" || true)"; [[ -n "$hits" ]]; then
  note "the kernel names an allocator; it is allocation-free by design:"
  printf '%s\n' "$hits" >&2
fi

# ---------------------------------------------------------------------------
# 2. Non-empty suite, and every source in it.
# ---------------------------------------------------------------------------
total_tests=0
for file in "${sources[@]}"; do
  base="$(basename "$file")"
  [[ "$base" == "test_root.zig" ]] && continue

  if ! grep -q "@import(\"$base\")" "$test_root"; then
    note "$base is not referenced by $test_root, so its tests never run"
  fi

  count="$(grep -c '^test "' "$file" || true)"
  if [[ "$base" != "root.zig" && "$count" -eq 0 ]]; then
    note "$base declares no test; the kernel's suite must cover every file in it"
  fi
  total_tests=$((total_tests + count))
done

# The floor itself. Deleting the corpus must fail this gate, not quietly pass it.
min_tests=40
if [[ "$total_tests" -lt "$min_tests" ]]; then
  note "found $total_tests kernel tests, expected at least $min_tests"
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

printf 'proof-checker: leaf boundary holds; %d tests across %d files\n' "$total_tests" "${#sources[@]}"

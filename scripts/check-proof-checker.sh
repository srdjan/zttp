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
# The kernel is small on purpose, but "smaller than this" means the glob broke
# or a file was dropped. The floor is the count on 2026-09-25.
min_sources=14
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
  'std\.Io'
  'std\.log'
  'std\.c\.'
  'std\.atomic'
  '@embedFile'
  '(^|[^A-Za-z0-9_])extern[^A-Za-z0-9_]'
  '^[[:space:]]*(pub )?export '
  '(^|[^A-Za-z0-9_])asm[^A-Za-z0-9_]'
  'threadlocal'
)
for pattern in "${forbidden[@]}"; do
  if hits="$(grep -nE "$pattern" "${sources[@]}" || true)"; [[ -n "$hits" ]]; then
    note "ambient capability '$pattern' reached from the kernel:"
    printf '%s\n' "$hits" >&2
  fi
done

# Mutable statics. A container-level `var` is state shared by every call, which
# makes a verdict depend on the calls before it. zig fmt puts every container
# declaration at column 0, so a column-0 `var` is exactly the top-level form.
if hits="$(grep -nE '^(pub )?var ' "${sources[@]}" || true)"; [[ -n "$hits" ]]; then
  note "the kernel declares a container-level var; it holds no mutable state:"
  printf '%s\n' "$hits" >&2
fi

# Production-only patterns. Tests may print a diagnostic before they fail, so
# these are checked on the lines outside `test` blocks and outside the private
# `fn expect...` assertion helpers those blocks call. zig fmt opens a top-level
# declaration at column 0 and closes it with a bare `}` at column 0, which is
# what the awk below keys on; `zig fmt --check` in verify.sh holds that shape.
# A helper must stay private: a `pub fn expect` is reachable from production.
production_only=(
  'std\.debug\.print'
)
production_lines="$(awk '
  FNR == 1 { in_test = 0 }
  /^test "/ || /^fn expect/ { in_test = 1 }
  !in_test { print FILENAME ":" FNR ":" $0 }
  in_test && /^}/ { in_test = 0 }
' "${sources[@]}")"
# Floor on the filter: it must drop the test lines and keep the rest, or a
# shape change has made it pass everything or check nothing.
production_count="$(printf '%s\n' "$production_lines" | wc -l | tr -d ' ')"
all_count="$(cat "${sources[@]}" | wc -l | tr -d ' ')"
if [[ "$production_count" -ge "$all_count" || "$production_count" -lt $((all_count / 4)) ]]; then
  note "the test-block filter kept $production_count of $all_count lines; it no longer separates tests from production code"
fi
for pattern in "${production_only[@]}"; do
  if hits="$(printf '%s\n' "$production_lines" | grep -E "$pattern" || true)"; [[ -n "$hits" ]]; then
    note "'$pattern' reached from kernel production code:"
    printf '%s\n' "$hits" >&2
  fi
done

# The list above is written in dotted form, so it only sees a capability reached
# as `std.fs.cwd()`. Every one of the fourteen is evaded by a rebinding:
# `const fs = std.fs;` puts `fs.cwd()` beyond `std\.fs\.`, and
# `const s = @import("std");` puts `s.fs.cwd()` beyond all of them. The
# patterns are therefore only sound while `std` is reached through exactly one
# name, so that is what this asserts. The kernel is clean today; this is what
# keeps the fourteen above meaningful rather than decorative.
#
# Two alias targets are permitted, and each is permitted for the same reason the
# capability list already gives: `std.testing` is reachable only from a `test`
# block, and SHA-256 over caller-supplied bytes is pure. Anything else - a bare
# `std`, or a namespace that could reach one of the fourteen - is refused,
# because the alias is where the dotted form disappears.
permitted_aliases='std\.testing|std\.crypto\.hash\.sha2\.Sha256'
if hits="$(grep -nE '^[[:space:]]*(pub )?const [A-Za-z_][A-Za-z0-9_]* = (std|std\.[A-Za-z_][A-Za-z0-9_.]*);' "${sources[@]}" | grep -vE "= ($permitted_aliases);\$" || true)"; [[ -n "$hits" ]]; then
  note "the kernel aliases std or one of its namespaces; the capability patterns above only match the dotted form, so an alias makes them blind:"
  printf '%s\n' "$hits" >&2
fi
# Floor on the line above: the permitted set must actually match something, or a
# rename has turned the alias check into a pattern that refuses nothing and
# passes everything.
if ! grep -qE "= ($permitted_aliases);\$" "${sources[@]}"; then
  note "no permitted std alias matches in the kernel; the alias check is vacuous - update permitted_aliases"
fi
if hits="$(grep -nE '@import\("std"\)' "${sources[@]}" | grep -vE 'const std = @import\("std"\);' || true)"; [[ -n "$hits" ]]; then
  note "the kernel binds @import(\"std\") to a name other than 'std'; reach std through one name so the capability patterns above can see it:"
  printf '%s\n' "$hits" >&2
fi

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
# The count on 2026-09-25 was 274; the margin allows a small consolidation, not
# the loss of a file's worth of tests.
min_tests=265
if [[ "$total_tests" -lt "$min_tests" ]]; then
  note "found $total_tests kernel tests, expected at least $min_tests"
fi

# ---------------------------------------------------------------------------
# 3. Reason-code census.
# ---------------------------------------------------------------------------
# Every public ReasonCode must be named inside at least one kernel test block,
# or carry a row below that states why no input can produce it. A code nothing
# names is either unpinned or unproducible, and `rule_family_mismatch` shipped
# as the second kind. The mutation gate decides whether the naming tests kill
# the guard; this census decides that no code is left without one.
#
# Rows: code, then the mechanism.
unproducible_codes=(
  # ProofSystem has one member, and a validated policy cannot select an empty
  # set, so no certificate can name a proof system the policy excludes.
  unsupported_proof_system
)
verdict_file="$src/verdict.zig"
reason_codes=()
while IFS= read -r code; do reason_codes+=("$code"); done < <(awk '/^pub const ReasonCode = enum/,/^};/' "$verdict_file" | sed -nE 's/^[[:space:]]+([a-z_]+) = [0-9]+,.*/\1/p')
if [[ ${#reason_codes[@]} -lt 50 ]]; then
  note "read ${#reason_codes[@]} ReasonCode members from $verdict_file; the census is reading nothing"
fi
test_block_lines="$(awk '
  FNR == 1 { in_test = 0 }
  /^test "/ { in_test = 1 }
  in_test { print }
  in_test && /^}/ { in_test = 0 }
' "${sources[@]}")"
for code in "${reason_codes[@]}"; do
  allowed=0
  for row in "${unproducible_codes[@]}"; do
    [[ "$row" == "$code" ]] && allowed=1
  done
  named=0
  if grep -qE "\.${code}([^a-z_]|\$)" <<<"$test_block_lines"; then named=1; fi
  if [[ $allowed -eq 1 && $named -eq 1 ]]; then
    note "ReasonCode.$code is allowlisted as unproducible but a test names it; remove the row"
  elif [[ $allowed -eq 0 && $named -eq 0 ]]; then
    note "ReasonCode.$code is named by no kernel test; pin it or allowlist it with the mechanism"
  fi
done
for row in "${unproducible_codes[@]}"; do
  found=0
  for code in "${reason_codes[@]}"; do [[ "$code" == "$row" ]] && found=1; done
  [[ $found -eq 1 ]] || note "unproducible_codes row '$row' is not a ReasonCode member"
done

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

printf 'proof-checker: leaf boundary holds; %d tests across %d files\n' "$total_tests" "${#sources[@]}"

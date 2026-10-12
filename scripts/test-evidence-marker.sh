#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$#" -ne 2 || ! -x "$1" || ! -x "$2" ]]; then
  echo "usage: test-evidence-marker.sh <native-marker-test-binary> <native-publisher-binary>" >&2
  exit 1
fi

marker_test_binary="$1"
publisher_binary="$2"

test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/zttp-evidence-marker.XXXXXX")"
dirty_probe=".zttp-evidence-dirty-probe.$$"
cleanup() {
  rm -rf "$test_tmp"
  rm -f "$dirty_probe"
}
trap cleanup EXIT HUP INT TERM
log="$test_tmp/test.log"

if ! "$marker_test_binary" >"$log" 2>&1; then
  cat "$log" >&2
  echo "evidence marker test: native fixture probes failed" >&2
  exit 1
fi
receipt='[evidence-marker-probes] complete:'
receipt_lines="$(grep -c -F "$receipt" "$log" || true)"
if [[ "$receipt_lines" != "1" ]]; then
  cat "$log" >&2
  echo "evidence marker test: native fixture probes emitted no unique completion receipt" >&2
  exit 1
fi

fixture_payload() {
  local prefix="$1"
  local count payload
  count="$(grep -c -F "$prefix" "$log" || true)"
  if [[ "$count" != "1" ]]; then
    printf 'evidence marker test: expected one %s fixture, found %s\n' \
      "$prefix" "$count" >&2
    exit 1
  fi
  payload="$(grep -F "$prefix" "$log")"
  payload="${payload#*"$prefix"}"
  if [[ -z "$payload" ]]; then
    printf 'evidence marker test: %s fixture is empty\n' "$prefix" >&2
    exit 1
  fi
  printf '%s' "$payload"
}

native_marker() {
  local constant="$1"
  local source="${2:-tooling/evidence_publish.zig}"
  local count marker
  count="$(grep -c -E "^(pub )?const ${constant} = \"[^\"]+ \";$" "$source" || true)"
  if [[ "$count" != "1" ]]; then
    printf 'evidence marker test: expected one %s constant in %s, found %s\n' \
      "$constant" "$source" "$count" >&2
    exit 1
  fi
  marker="$(sed -n "s/^\\(pub \\)\{0,1\}const ${constant} = \"\\(.*\\) \";$/\\2/p" "$source")"
  if [[ -z "$marker" ]]; then
    printf 'evidence marker test: %s constant in %s is empty\n' \
      "$constant" "$source" >&2
    exit 1
  fi
  printf '%s' "$marker"
}

convergence_payload="$(fixture_payload '[evidence-fixture-convergence] ')"
coverage_payload="$(fixture_payload '[evidence-fixture-coverage] ')"
convergence_marker="$(native_marker convergence_marker)"
coverage_marker="$(native_marker coverage_marker)"
seed_marker="$(native_marker seed_marker)"
union_source_count="$(grep -c -E '^const union_marker = @import\("[^"]+"\)\.marker;$' tooling/evidence_publish.zig || true)"
if [[ "$union_source_count" != "1" ]]; then
  printf 'evidence marker test: expected one union marker import, found %s\n' \
    "$union_source_count" >&2
  exit 1
fi
union_source="$(sed -n 's/^const union_marker = @import("\([^"]*\)")\.marker;$/\1/p' tooling/evidence_publish.zig)"
if [[ -z "$union_source" || ! -f "tooling/$union_source" ]]; then
  echo "evidence marker test: union marker source is empty or missing" >&2
  exit 1
fi
union_marker="$(native_marker marker "tooling/$union_source")"

case "$convergence_payload" in
  *'"sourceDirty":true'*) ;;
  *) echo "evidence marker test: convergence fixture has no dirty-state field" >&2; exit 1 ;;
esac
case "$coverage_payload" in
  *'"sourceDirty":true'*) ;;
  *) echo "evidence marker test: coverage fixture has no dirty-state field" >&2; exit 1 ;;
esac
clean_convergence_payload="${convergence_payload/\"sourceDirty\":true/\"sourceDirty\":false}"
clean_coverage_payload="${coverage_payload/\"sourceDirty\":true/\"sourceDirty\":false}"
source_commit="${clean_convergence_payload#*\"sourceCommit\":\"}"
source_commit="${source_commit%%\"*}"
corpus_version="${clean_convergence_payload#*\"corpusVersion\":\"}"
corpus_version="${corpus_version%%\"*}"
if [[ ${#source_commit} -ne 40 || ${#corpus_version} -ne 64 ]]; then
  echo "evidence marker test: clean fixture identities have invalid lengths" >&2
  exit 1
fi
checks=0

# Exercise the native publisher through its public CLI. These fixtures stay in
# the private test directory and use the validator's completed JSON fixtures.
cli_root="$test_tmp/public-cli"
mkdir -p "$cli_root"
public_cli_checks=0
convergence_log="$cli_root/convergence.log"
coverage_log="$cli_root/coverage.log"
seed_log="$cli_root/seed.log"
union_log="$cli_root/union.log"
printf '%s %s\n' "$convergence_marker" "$clean_convergence_payload" > "$convergence_log"
printf '%s %s\n' "$coverage_marker" "$clean_coverage_payload" > "$coverage_log"
printf '%s %s\n' "$seed_marker" \
  '{"seedsTotal":3,"rulesTotal":3,"verifiedRules":2,"verified":["ZTS001","ZTS002"],"unseeded":[{"code":"ZTS003","reason":"non-default"}]}' \
  > "$seed_log"
printf '%s {"corpusVersion":"%s","sourceTreeHash":"%s","observations":1,"distinctSets":1,"smallestSet":2,"largestSet":2,"unionCount":2,"union":["ZTS001","ZTS002"]}\n' \
  "$union_marker" "$corpus_version" "$source_commit" > "$union_log"

convergence_source="$cli_root/convergence-source.md"
printf '%s\n' \
  '# Convergence' \
  '' \
  '## Repeatability' \
  '' \
  'Retired qualification fixture.' \
  '' \
  '## Results' \
  '' \
  '| Recorded | Commit | Corpus | Cases | Provider | Model | Policy | Raw first-draft pass | First-attempt green | Median round-trips | Intent pass |' \
  '|---|---|---|---|---|---|---|---|---|---|---|' \
  '| 2026-10-11 | `aaaaaaaa` | `aaaaaaaaaaaa` | 19 | deepseek | model | `aaaaaaaaaaaa` | 1% (1/19) | 1% (1/19) | 1 | 1% (1/18) |' \
  > "$convergence_source"

valid_convergence_json="$cli_root/valid-convergence.json"
valid_convergence_md="$cli_root/valid-convergence.md"
if ! "$publisher_binary" convergence \
  "$convergence_log" "$valid_convergence_json" \
  "$convergence_source" "$valid_convergence_md" \
  2026-10-12 "$source_commit" false >"$log" 2>&1; then
  cat "$log" >&2
  echo "evidence marker test: valid convergence CLI fixture failed" >&2
  exit 1
fi
if [[ ! -s "$valid_convergence_json" || ! -s "$valid_convergence_md" ]]; then
  echo "evidence marker test: valid convergence CLI fixture wrote an empty output" >&2
  exit 1
fi
if grep -q -F 'Retired qualification fixture.' "$valid_convergence_md"; then
  echo "evidence marker test: convergence retained the qualification section" >&2
  exit 1
fi
public_cli_checks=$((public_cli_checks + 1))

valid_coverage_json="$cli_root/valid-coverage.json"
valid_coverage_md="$cli_root/valid-coverage.md"
if ! "$publisher_binary" coverage \
  "$coverage_log" "$seed_log" "$union_log" \
  "$valid_coverage_json" "$valid_coverage_md" \
  2026-10-12 "$source_commit" false >"$log" 2>&1; then
  cat "$log" >&2
  echo "evidence marker test: valid coverage CLI fixture failed" >&2
  exit 1
fi
if [[ ! -s "$valid_coverage_json" || ! -s "$valid_coverage_md" ]]; then
  echo "evidence marker test: valid coverage CLI fixture wrote an empty output" >&2
  exit 1
fi
public_cli_checks=$((public_cli_checks + 1))

sentinel="$cli_root/unchanged"
printf 'unchanged\n' > "$sentinel"
invalid_convergence_source="$cli_root/invalid-convergence-source.md"
sed 's/| Policy |/| Policy digest |/' \
  "$convergence_source" > "$invalid_convergence_source"
invalid_convergence_json="$cli_root/invalid-convergence.json"
invalid_convergence_md="$cli_root/invalid-convergence.md"
cp "$sentinel" "$invalid_convergence_json"
cp "$sentinel" "$invalid_convergence_md"
if "$publisher_binary" convergence \
  "$convergence_log" "$invalid_convergence_json" \
  "$invalid_convergence_source" "$invalid_convergence_md" \
  2026-10-12 "$source_commit" false >"$log" 2>&1; then
  echo "evidence marker test: malformed convergence header reached publication" >&2
  exit 1
fi
if ! cmp -s "$sentinel" "$invalid_convergence_json" || \
   ! cmp -s "$sentinel" "$invalid_convergence_md"; then
  echo "evidence marker test: malformed convergence header changed an output" >&2
  exit 1
fi
public_cli_checks=$((public_cli_checks + 1))

wrong_union_log="$cli_root/wrong-union.log"
printf '%s {"corpusVersion":"%s","sourceTreeHash":"%s","observations":1,"distinctSets":1,"smallestSet":2,"largestSet":2,"unionCount":2,"union":["ZTS001","ZTS999"]}\n' \
  "$union_marker" "$corpus_version" "$source_commit" > "$wrong_union_log"
invalid_coverage_json="$cli_root/invalid-coverage.json"
invalid_coverage_md="$cli_root/invalid-coverage.md"
cp "$sentinel" "$invalid_coverage_json"
cp "$sentinel" "$invalid_coverage_md"
if "$publisher_binary" coverage \
  "$coverage_log" "$seed_log" "$wrong_union_log" \
  "$invalid_coverage_json" "$invalid_coverage_md" \
  2026-10-12 "$source_commit" false >"$log" 2>&1; then
  echo "evidence marker test: same-count wrong union reached publication" >&2
  exit 1
fi
if ! cmp -s "$sentinel" "$invalid_coverage_json" || \
   ! cmp -s "$sentinel" "$invalid_coverage_md"; then
  echo "evidence marker test: same-count wrong union changed an output" >&2
  exit 1
fi
public_cli_checks=$((public_cli_checks + 1))

for publisher in scripts/update-convergence.sh scripts/update-coverage.sh; do
  for filter_name in ZTTP_CODEGEN_ONLY ZTTP_CODEGEN_LIMIT ZTTP_CODEGEN_TOOLS; do
    if env "$filter_name=probe" bash "$publisher" >"$log" 2>&1; then
      printf 'evidence marker test: %s accepted filtered input through %s\n' \
        "$publisher" "$filter_name" >&2
      exit 1
    fi
    grep -q 'non-publishable' "$log" || {
      printf 'evidence marker test: %s did not explain why %s was refused\n' \
        "$publisher" "$filter_name" >&2
      exit 1
    }
    checks=$((checks + 1))
  done
done

printf 'probe\n' > "$dirty_probe"
for publisher in scripts/update-convergence.sh scripts/update-coverage.sh; do
  if bash "$publisher" >"$log" 2>&1; then
    printf 'evidence marker test: %s accepted a dirty working tree\n' "$publisher" >&2
    exit 1
  fi
  grep -q 'requires a clean working tree' "$log" || {
    printf 'evidence marker test: %s did not explain why dirty source was refused\n' \
      "$publisher" >&2
    exit 1
  }
  checks=$((checks + 1))
done
rm -f "$dirty_probe"

# A complete marker cannot replace evidence after its producer fails. Run
# publisher copies so a broken probe cannot change the repository evidence.
fixture_root="$test_tmp/repository"
before_root="$test_tmp/before"
mkdir -p "$fixture_root/scripts" "$fixture_root/docs" "$before_root"
cp scripts/update-convergence.sh scripts/update-coverage.sh "$fixture_root/scripts/"
for destination in \
  convergence.json convergence.md coverage.json coverage.md; do
  cp "docs/$destination" "$fixture_root/docs/$destination"
  cp "docs/$destination" "$before_root/$destination"
done

fake_bin="$test_tmp/bin"
mkdir -p "$fake_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == "build" && "$#" -eq 1 ]]; then exit 0; fi' \
  'if [[ "${1:-}" == "build" && "${2:-}" == "test-expert-app" ]]; then' \
  '  printf "%s %s\n" "$EVIDENCE_PROBE_CONVERGENCE_MARKER" "$EVIDENCE_PROBE_CONVERGENCE_PAYLOAD"' \
  '  printf "%s %s\n" "$EVIDENCE_PROBE_COVERAGE_MARKER" "$EVIDENCE_PROBE_COVERAGE_PAYLOAD"' \
  '  exit 1' \
  'fi' \
  'if [[ "${1:-}" == "build" && "${2:-}" == "test-standin" ]]; then exit 0; fi' \
  'if [[ "${1:-}" == "build" && "${2:-}" == "coverage-union" ]]; then exit 0; fi' \
  'if [[ "${1:-}" == "build" && "${2:-}" == "evidence-publish" ]]; then' \
  '  : > "$EVIDENCE_PROBE_SENTINEL"' \
  '  if [[ "${4:-}" == "coverage-inputs" ]]; then' \
  '    printf "%s\n%s\n" "$EVIDENCE_PROBE_CORPUS_VERSION" "ZTS001 ZTS002"' \
  '    exit 0' \
  '  fi' \
  '  if [[ "${4:-}" == "convergence" ]]; then' \
  '    printf "changed\n" > "$6"' \
  '    printf "changed\n" > "$8"' \
  '    exit 0' \
  '  fi' \
  '  if [[ "${4:-}" == "coverage" ]]; then' \
  '    printf "changed\n" > "$8"' \
  '    printf "changed\n" > "$9"' \
  '    exit 0' \
  '  fi' \
  'fi' \
  'exit 1' > "$fake_bin/zig"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == "status" ]]; then exit 0; fi' \
  'if [[ "${1:-}" == "rev-parse" && "${2:-}" == "HEAD" ]]; then' \
  '  printf "%s\n" "$EVIDENCE_PROBE_SOURCE_COMMIT"' \
  '  exit 0' \
  'fi' \
  'if [[ "${1:-}" == "rev-parse" && "${2:-}" == "HEAD:packages" ]]; then' \
  '  printf "%s\n" "cccccccccccccccccccccccccccccccccccccccc"' \
  '  exit 0' \
  'fi' \
  'exit 1' > "$fake_bin/git"
chmod +x "$fake_bin/zig" "$fake_bin/git"

producer_checks=0
for publisher in update-convergence.sh update-coverage.sh; do
  sentinel="$test_tmp/$publisher.evidence-publish-called"
  if env \
    PATH="$fake_bin:$PATH" \
    EVIDENCE_PROBE_SENTINEL="$sentinel" \
    EVIDENCE_PROBE_SOURCE_COMMIT="$source_commit" \
    EVIDENCE_PROBE_CONVERGENCE_MARKER="$convergence_marker" \
    EVIDENCE_PROBE_CONVERGENCE_PAYLOAD="$clean_convergence_payload" \
    EVIDENCE_PROBE_COVERAGE_MARKER="$coverage_marker" \
    EVIDENCE_PROBE_COVERAGE_PAYLOAD="$clean_coverage_payload" \
    EVIDENCE_PROBE_CORPUS_VERSION="$corpus_version" \
    bash "$fixture_root/scripts/$publisher" >"$log" 2>&1; then
    publisher_status=0
  else
    publisher_status=$?
  fi
  if [[ "$publisher_status" -eq 0 ]]; then
    printf 'evidence marker test: %s accepted a failed producer\n' "$publisher" >&2
    exit 1
  fi
  grep -q 'codegen replay failed' "$log" || {
    printf 'evidence marker test: %s did not preserve the producer failure\n' \
      "$publisher" >&2
    exit 1
  }
  if [[ -e "$sentinel" ]]; then
    printf 'evidence marker test: %s consumed evidence before producer success\n' \
      "$publisher" >&2
    exit 1
  fi
  for destination in \
    convergence.json convergence.md coverage.json coverage.md; do
    if ! cmp -s "$before_root/$destination" "$fixture_root/docs/$destination"; then
      printf 'evidence marker test: %s changed %s after producer failure\n' \
        "$publisher" "$destination" >&2
      exit 1
    fi
  done
  producer_checks=$((producer_checks + 1))
done

printf 'evidence marker tests OK: native fixture receipt; %s public CLI checks; %s publisher-boundary checks; %s producer-exit checks\n' \
  "$public_cli_checks" "$checks" "$producer_checks"

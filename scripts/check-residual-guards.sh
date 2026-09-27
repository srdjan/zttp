#!/usr/bin/env bash
#
# Residual-guard drift gate.
#
# The consumer catalog owns what can be guarded. The compiler mirrors the
# indexed rows, the enabled-family set states what production admits, the
# stand-in seeds provide measured conversions, and docs/verification.md
# publishes the same boundary. This gate compares all four exactly.

set -euo pipefail

cd "$(dirname "$0")/.."

checker="packages/proof-checker/src/residual.zig"
mirror="packages/zts/src/guard_catalog.zig"
strict="packages/zts/src/strict_checker.zig"
seeds="packages/pi/src/standin/defect_seeds.zig"
evidence_test="packages/pi/src/standin_range_tests.zig"
doc="docs/verification.md"

fail=0
note() { printf 'residual guards: %s\n' "$1" >&2; fail=1; }

for path in "$checker" "$mirror" "$strict" "$seeds" "$evidence_test" "$doc"; do
  [[ -f "$path" ]] || { note "missing $path"; exit 1; }
  [[ -r "$path" ]] || { note "cannot read $path"; exit 1; }
  [[ -s "$path" ]] || { note "$path is empty"; exit 1; }
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

checker_catalog="$tmp_dir/checker-catalog"
checker_doc_catalog="$tmp_dir/checker-doc-catalog"
mirror_catalog="$tmp_dir/mirror-catalog"
checker_enabled="$tmp_dir/checker-enabled"
enabled="$tmp_dir/enabled"
evidence="$tmp_dir/evidence"
doc_catalog="$tmp_dir/doc-catalog"
doc_enabled="$tmp_dir/doc-enabled"
doc_evidence="$tmp_dir/doc-evidence"

# Bind the typed imports to the two declared inputs. Pass the same checker path
# for the AST scan that recovers each published guard_impl constant name.
if ! zig run --dep residual --dep guard_catalog \
  -Mroot=scripts/residual_guard_extract.zig \
  -Mresidual="$checker" -Mguard_catalog="$mirror" -- \
  "$checker" \
  "$checker_catalog" "$checker_doc_catalog" "$mirror_catalog" "$checker_enabled" "$enabled"
then
  note "catalog extraction failed"
  exit 1
fi

while IFS= read -r seed_id; do
  case "$seed_id" in
    dynamic-capability) printf 'env|%s\n' "$seed_id" ;;
    dynamic-capability-egress) printf 'egress|%s\n' "$seed_id" ;;
    dynamic-capability-cache) printf 'cache|%s\n' "$seed_id" ;;
    *) note "ZTS602 seed '$seed_id' has no reviewed guard-family mapping" ;;
  esac
done < <(
  awk '
    /^        \.id = "/ {
      id=$0
      sub(/^.*\.id = "/, "", id)
      sub(/".*$/, "", id)
    }
    /^        \.code = "ZTS602"/ { print id }
  ' "$seeds"
) >"$evidence"

awk '/<!-- residual-guards: catalog -->/,/<!-- residual-guards: enabled -->/' "$doc" \
  | sed -nE 's/^- `([^`]*)`$/\1/p' >"$doc_catalog"
awk '/<!-- residual-guards: enabled -->/,/<!-- residual-guards: evidence -->/' "$doc" \
  | sed -nE 's/^- `([a-z_]+)`$/\1/p' >"$doc_enabled"
awk '/<!-- residual-guards: evidence -->/,/<!-- residual-guards: end -->/' "$doc" \
  | sed -nE 's/^- `([^`]*)`$/\1/p' >"$doc_evidence"

line_count() { wc -l <"$1" | tr -d ' '; }

require_floor() {
  local label="$1" path="$2" minimum="$3" count
  count="$(line_count "$path")"
  if [[ "$count" -lt "$minimum" ]]; then
    note "$label has $count row(s), expected at least $minimum"
  fi
}

require_unique() {
  local label="$1" path="$2" count unique
  count="$(line_count "$path")"
  unique="$(sort -u "$path" | wc -l | tr -d ' ')"
  if [[ "$count" -ne "$unique" ]]; then
    note "$label contains duplicate rows"
  fi
}

compare_exact() {
  local label="$1" expected="$2" actual="$3"
  if ! exact_matches "$expected" "$actual"; then
    note "$label does not match:"
    diff -u "$expected" "$actual" >&2 || true
    return 1
  fi
}

exact_matches() {
  diff -q "$1" "$2" >/dev/null
}

require_floor "checker catalog" "$checker_catalog" 3
require_floor "compiler mirror" "$mirror_catalog" 3
require_floor "checker enabled-family set" "$checker_enabled" 1
require_floor "enabled-family set" "$enabled" 1
require_floor "guard evidence" "$evidence" 1
require_floor "documented catalog" "$doc_catalog" 3
require_floor "documented enabled-family set" "$doc_enabled" 1
require_floor "documented evidence" "$doc_evidence" 1

for item in \
  "checker catalog:$checker_catalog" \
  "compiler mirror:$mirror_catalog" \
  "checker enabled-family set:$checker_enabled" \
  "enabled-family set:$enabled" \
  "guard evidence:$evidence"; do
  require_unique "${item%%:*}" "${item#*:}"
done

compare_exact "compiler mirror and checker catalog" "$checker_catalog" "$mirror_catalog" || true
compare_exact "checker and compiler enabled families" "$checker_enabled" "$enabled" || true
compare_exact "documented catalog and checker guard metadata" "$checker_doc_catalog" "$doc_catalog" || true
compare_exact "documented and enabled families" "$enabled" "$doc_enabled" || true
compare_exact "documented and measured evidence" "$evidence" "$doc_evidence" || true

cut -d '|' -f 1 "$evidence" >"$tmp_dir/evidence-families"
compare_exact "enabled families and evidence families" "$enabled" "$tmp_dir/evidence-families" || true

if [[ "$(grep -c '^pub const classification_enabled = true;$' "$mirror" || true)" -ne 1 ]]; then
  note "production residual classification is not enabled exactly once"
fi
if [[ "$(grep -c '^pub const enabled_families: FamilySet = measured_families;$' "$mirror" || true)" -ne 1 ]]; then
  note "enabled_families is not the measured family set"
fi
if grep -qx 'sql' "$enabled"; then
  note "SQL is enabled even though policy cannot distinguish reads from writes"
fi
if ! grep -q '|sql_\(read\|write\)$' "$checker_catalog"; then
  note "the consumer catalog no longer contains the SQL rows the classifier must reject"
fi

evidence_name='stand-in gate: every enabled guard family has rejection and property-preserving guarded evidence'
if [[ "$(grep -c "test \"$evidence_name\"" "$evidence_test" || true)" -ne 1 ]]; then
  note "the positive and property-preserving evidence test is missing"
fi
for marker in CoveredGuardStillRejected GuardChangedProperties; do
  if ! grep -q "$marker" "$evidence_test"; then
    note "the evidence test no longer checks $marker"
  fi
done
for diagnostic_text in \
  'residual guard env_key requires env.allow' \
  'residual guard egress_endpoint requires egress.allow_endpoints and egress.allow_address_scopes' \
  'residual guard cache_namespace requires cache.allow_namespaces' \
  'when configured, the operation is guarded rather than proven' \
  'zttp check <handler.ts> --contract' \
  'SQL stays literal-only because sql.allow_queries cannot distinguish a read from a write'; do
  if ! grep -Fq "$diagnostic_text" "$strict"; then
    note "the ZTS602 diagnostic contract is missing: $diagnostic_text"
  fi
done

# Deliberate invalidation checks. Read the comparison result from its exit
# status. A probe command that fails and a passing command can both print no
# useful output, so output matching is not a verdict.
cp "$checker_catalog" "$tmp_dir/probe-missing"
sed -i.bak '1d' "$tmp_dir/probe-missing"
rm -f "$tmp_dir/probe-missing.bak"
if exact_matches "$checker_catalog" "$tmp_dir/probe-missing"; then
  note "the missing-row invalidation probe passed"
fi

cp "$checker_catalog" "$tmp_dir/probe-extra"
printf 'zttp:probe|probe|0|env_key\n' >>"$tmp_dir/probe-extra"
if exact_matches "$checker_catalog" "$tmp_dir/probe-extra"; then
  note "the extra-row invalidation probe passed"
fi

if ! grep -Fq 'residual_guards_drift_step.dependOn(&host_test_runs[i].step);' build/host_tests.zig; then
  note "the named gate no longer depends on compiled stand-in evidence"
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

printf 'residual guards: %s catalog rows, %s enabled families, %s measured conversions; docs agree\n' \
  "$(line_count "$checker_catalog")" "$(line_count "$enabled")" "$(line_count "$evidence")"

#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'docs drift: %s\n' "$1" >&2
  exit 1
}

modules_doc="docs/virtual-modules/README.md"
registry_file="packages/zts/src/builtin_modules.zig"

[[ -f "$modules_doc" ]] || fail "missing $modules_doc"
[[ -f "$registry_file" ]] || fail "missing $registry_file"

doc_cell_for() {
  local specifier="$1"
  local column="$2"
  awk -F '|' -v specifier="$specifier" -v column="$column" '
    /^## Module Catalog/ { in_catalog = 1; next }
    /^## / && in_catalog { exit }
    in_catalog && index($2, "`" specifier "`") > 0 {
      cell = $column
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
      print cell
      found = 1
      exit
    }
    END { exit(found ? 0 : 1) }
  ' "$modules_doc"
}

canonical_csv() {
  tr ',' '\n' |
    sed 's/`//g; s/^[[:space:]]*//; s/[[:space:]]*$//' |
    sed '/^$/d; /^none$/d' |
    LC_ALL=C sort |
    paste -sd ',' -
}

spec_field() {
  local spec_file="$1"
  local field="$2"
  awk -v field="$field" '
    index($0, "\"" field "\"") > 0 {
      line = $0
      sub(/^.*:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ' "$spec_file"
}

spec_array_values() {
  local spec_file="$1"
  local field="$2"
  awk -v field="$field" '
    function update_depth(line, tmp) {
      tmp = line
      depth += gsub(/\[/, "", tmp)
      tmp = line
      depth -= gsub(/\]/, "", tmp)
    }
    {
      if (!in_array) {
        if (index($0, "\"" field "\"") == 0) next
        in_array = 1
        update_depth($0)
        line = $0
        sub(/^.*\[/, "", line)
      } else {
        line = $0
        update_depth($0)
      }

      while (match(line, /"[^"]+"/)) {
        value = substr(line, RSTART + 1, RLENGTH - 2)
        if (value != field) print value
        line = substr(line, RSTART + RLENGTH)
      }

      if (depth <= 0) exit
    }
  ' "$spec_file"
}

spec_export_names() {
  local spec_file="$1"
  awk '
    function update_depth(line, tmp) {
      tmp = line
      depth += gsub(/\[/, "", tmp)
      tmp = line
      depth -= gsub(/\]/, "", tmp)
    }
    /"exports"[[:space:]]*:/ {
      in_exports = 1
      update_depth($0)
      next
    }
    in_exports {
      if (match($0, /"name"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        line = $0
        sub(/^.*"name"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/".*$/, "", line)
        print line
      }
      update_depth($0)
      if (depth <= 0) exit
    }
  ' "$spec_file"
}

compare_doc_list() {
  local specifier="$1"
  local label="$2"
  local expected="$3"
  local actual="$4"
  if [[ "$expected" != "$actual" ]]; then
    fail "$modules_doc has $label mismatch for $specifier (expected: ${expected:-none}; actual: ${actual:-none})"
  fi
}

module_count=$(
  awk '
    /pub const builtin_governance_entries/ { in_entries = 1 }
    in_entries && /\.specifier = "zttp:/ { count += 1 }
    in_entries && /^};/ { print count; exit }
  ' "$registry_file"
)

[[ -n "$module_count" ]] || fail "could not count builtin governance entries"

doc_count=$(
  awk '
    /^## Module Catalog/ { in_catalog = 1; next }
    /^## / && in_catalog { exit }
    in_catalog && /^\| `zttp:/ { count += 1 }
    END { print count + 0 }
  ' "$modules_doc"
)

[[ "$doc_count" == "$module_count" ]] ||
  fail "$modules_doc lists $doc_count modules, registry has $module_count"

while IFS= read -r specifier; do
  if ! awk -v specifier="$specifier" '
    /^## Module Catalog/ { in_catalog = 1; next }
    /^## / && in_catalog { exit }
    in_catalog && index($0, "| `" specifier "` |") > 0 { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$modules_doc"; then
    fail "$modules_doc is missing $specifier"
  fi
done < <(
  awk '
    /pub const builtin_governance_entries/ { in_entries = 1 }
    in_entries && /\.specifier = "zttp:/ {
      line = $0
      sub(/^.*\.specifier = "/, "", line)
      sub(/".*$/, "", line)
      print line
    }
    in_entries && /^};/ { exit }
  ' "$registry_file"
)

spec_count=0
while IFS= read -r -d '' spec_file; do
  spec_count=$((spec_count + 1))
  specifier="$(spec_field "$spec_file" "specifier")"
  [[ -n "$specifier" ]] || fail "could not read specifier from $spec_file"

  doc_exports_cell="$(doc_cell_for "$specifier" 3)" ||
    fail "$modules_doc is missing $specifier"
  doc_caps_cell="$(doc_cell_for "$specifier" 4)" ||
    fail "$modules_doc is missing capabilities for $specifier"

  expected_exports="$(spec_export_names "$spec_file" | canonical_csv)"
  actual_exports="$(printf '%s\n' "$doc_exports_cell" | canonical_csv)"
  compare_doc_list "$specifier" "exports" "$expected_exports" "$actual_exports"

  expected_caps="$(spec_array_values "$spec_file" "requiredCapabilities" | canonical_csv)"
  actual_caps="$(printf '%s\n' "$doc_caps_cell" | canonical_csv)"
  compare_doc_list "$specifier" "capabilities" "$expected_caps" "$actual_caps"
done < <(git ls-files -z 'packages/modules/module-specs/*.json')

[[ "$spec_count" == "$module_count" ]] ||
  fail "module specs have $spec_count modules, registry has $module_count"

# ---------------------------------------------------------------------------
# CLI reference coverage.
#
# Every command the two dispatch registries advertise must appear in
# docs/cli.md as `zttp <name>`. Without this, a command can ship, be listed by
# `zttp help --all`, and never reach the reference: doctor, build, compile,
# ratchet, ledger, witnesses, and version each had zero mentions when this gate
# was written. `.unlisted` entries (the deprecated `proof` alias, `help`) are
# exempt, because `help --all` does not advertise them either.
# ---------------------------------------------------------------------------

cli_doc="docs/cli.md"
dev_cli="packages/runtime/src/dev_cli.zig"
zts_cli="packages/tools/src/zts_cli.zig"

[[ -f "$cli_doc" ]] || fail "missing $cli_doc"
[[ -f "$dev_cli" ]] || fail "missing $dev_cli"
[[ -f "$zts_cli" ]] || fail "missing $zts_cli"

listed_commands() {
  awk '
    /^const commands = \[_\]cli_help\.Command\{/ { in_table = 1; next }
    in_table && /^};/ { exit }
    in_table && /\.section = \.unlisted/ { next }
    in_table && match($0, /\.name = "[^"]+"/) {
      field = substr($0, RSTART + 9, RLENGTH - 10)
      print field
    }
  ' "$dev_cli"
  awk '
    /^pub const commands = \[_\]Command\{/ { in_table = 1; next }
    in_table && /^};/ { exit }
    in_table && match($0, /\.name = "[^"]+"/) {
      field = substr($0, RSTART + 9, RLENGTH - 10)
      print field
    }
  ' "$zts_cli"
}

command_count=0
while IFS= read -r command_name; do
  [[ -n "$command_name" ]] || continue
  command_count=$((command_count + 1))
  grep -q -F -- "zttp $command_name" "$cli_doc" ||
    fail "$cli_doc does not document \`zttp $command_name\`"
done < <(listed_commands)

# A registry that stops parsing (renamed table, changed literal) would silently
# pass the loop above with zero iterations.
[[ "$command_count" -ge 40 ]] ||
  fail "only $command_count commands parsed from the dispatch registries; the table format changed"

# ---------------------------------------------------------------------------
# Capability inventory coverage.
#
# docs/internals/capabilities.md splits every built-in into "declares
# capabilities" and "declares none". It is hand-maintained, and zttp:queue and
# zttp:workflow were absent from both halves. Every registry specifier has to
# appear somewhere in the file.
# ---------------------------------------------------------------------------

capabilities_doc="docs/internals/capabilities.md"
[[ -f "$capabilities_doc" ]] || fail "missing $capabilities_doc"

while IFS= read -r specifier; do
  grep -qF -- "\`$specifier\`" "$capabilities_doc" ||
    fail "$capabilities_doc does not list $specifier in either capability inventory"
done < <(
  awk '
    /pub const builtin_governance_entries/ { in_entries = 1 }
    in_entries && /\.specifier = "zttp:/ {
      line = $0
      sub(/^.*\.specifier = "/, "", line)
      sub(/".*$/, "", line)
      print line
    }
    in_entries && /^};/ { exit }
  ' "$registry_file"
)

# ---------------------------------------------------------------------------
# Restriction matrix coverage.
#
# docs/restrictions-to-proofs.md renders packages/zts/src/restriction_registry.zig.
# Nothing regenerated it, so it drifted by 14 rows in both directions: it listed
# canonical-profile rules that were never restrictions, and missed every row
# added after the version-1 freeze. Two counts and a per-row lookup catch that.
# ---------------------------------------------------------------------------

restrictions_doc="docs/restrictions-to-proofs.md"
restrictions_registry="packages/zts/src/restriction_registry.zig"

[[ -f "$restrictions_doc" ]] || fail "missing $restrictions_doc"
[[ -f "$restrictions_registry" ]] || fail "missing $restrictions_registry"

doc_table_rows() {
  awk -v heading="$1" '
    $0 == heading { in_section = 1; next }
    /^## / && in_section { exit }
    in_section && /^\| / && $0 !~ /^\| *Restriction *\|/ && $0 !~ /^\|---/ { count += 1 }
    END { print count + 0 }
  ' "$restrictions_doc"
}

registry_total=$(grep -c '\.id = "restriction\.' "$restrictions_registry")
registry_v1=$(grep -c '\.v1_feature_name = ' "$restrictions_registry")

[[ "$registry_total" -ge 20 ]] ||
  fail "only $registry_total rows parsed from $restrictions_registry; the table format changed"

doc_v1_rows=$(doc_table_rows '## Restrictions With A Named Proof')
doc_rest_rows=$(doc_table_rows '## Further Refused Forms')

[[ "$doc_v1_rows" == "$registry_v1" ]] ||
  fail "$restrictions_doc lists $doc_v1_rows version-1 restrictions, registry has $registry_v1"

[[ $((doc_v1_rows + doc_rest_rows)) == "$registry_total" ]] ||
  fail "$restrictions_doc lists $((doc_v1_rows + doc_rest_rows)) restrictions, registry has $registry_total"

while IFS= read -r feature; do
  grep -qF -- "$feature" "$restrictions_doc" ||
    fail "$restrictions_doc is missing the restriction '$feature'"
done < <(sed -n 's/^ *\.v1_feature_name = "\(.*\)",$/\1/p' "$restrictions_registry")

# ---------------------------------------------------------------------------
# Host test root coverage.
#
# docs/internals/testing.md tables the host_test_roots entries in build.zig and
# names itself stale whenever the two disagree. Nothing enforced that: the doc
# said "Nine host test roots" while build.zig declared twenty-one, and
# test-standin - the root the stand-in filter convention exists for - had no row
# at all. That is the defect docs/solutions/conventions/
# a-gate-that-counts-nothing-still-reports-a-pass.md describes, in a doc rather
# than a gate: a count nothing ties to its source.
# ---------------------------------------------------------------------------

testing_doc="docs/internals/testing.md"
build_file="build.zig"

[[ -f "$testing_doc" ]] || fail "missing $testing_doc"
[[ -f "$build_file" ]] || fail "missing $build_file"

host_root_steps() {
  awk '
    /const host_test_roots = \[_\]HostTestRoot\{/ { in_table = 1; next }
    in_table && /^ *\};/ { exit }
    in_table && match($0, /\.step = "[^"]+"/) {
      print substr($0, RSTART + 9, RLENGTH - 10)
    }
  ' "$build_file"
}

# wc, not `grep -c`: grep exits 1 on no match, and under `set -o pipefail` that
# aborts the script before the floor below can name what went wrong.
build_root_count=$(host_root_steps | wc -l | tr -d '[:space:]')

# A renamed table or changed literal would leave the loop below with zero
# iterations and a doc count of zero to match it.
[[ "$build_root_count" -ge 15 ]] ||
  fail "only $build_root_count host test roots parsed from $build_file; the table format changed"

doc_root_count=$(
  awk '
    index($0, "host_test_roots") > 0 { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && /^\| `test-/ { count += 1 }
    END { print count + 0 }
  ' "$testing_doc"
)

[[ "$doc_root_count" == "$build_root_count" ]] ||
  fail "$testing_doc tables $doc_root_count host test roots, $build_file declares $build_root_count"

while IFS= read -r step_name; do
  [[ -n "$step_name" ]] || continue
  grep -qF -- "\`$step_name\`" "$testing_doc" ||
    fail "$testing_doc is missing the host test root step \`$step_name\`"
done < <(host_root_steps)

# ---------------------------------------------------------------------------
# Prose bans.
#
# Each row is one accumulated one-off, as data rather than as another hand-
# written if/grep block. Fields are tab-separated:
#
#   kind     fixed = literal substring (grep -F), regex = extended (grep -E)
#   pattern  what must not appear
#   paths    space-separated files/directories to search
#   exclude  grep -E pattern for hits to ignore, or "-" for none
#   message  what the author should do instead
#
# Retired when this became a table: a ban on the full path
# "packages/runtime/src/generated/embedded_handler.zig", which the shorter
# "src/generated/embedded_handler.zig" row already covers as a substring. Every
# other row still has a live target - checked when the table was written; the
# only absent file is docs/capabilities.md, which is exactly what its row
# enforces.
# ---------------------------------------------------------------------------

prose_docs="docs README.md CHANGELOG.md SECURITY.md RELEASE_CHECKLIST.md"

prose_bans=(
  "fixed	src/generated/embedded_handler.zig	$prose_docs	-	docs reference obsolete src/generated/embedded_handler.zig"
  "fixed	docs/capabilities.md	$prose_docs	-	docs reference obsolete docs/capabilities.md"
  "fixed	zttp mock --replay	$prose_docs	^docs/proofs-and-receipts.md:	docs advertise unsupported zttp mock --replay"
  "fixed	std.net	docs/internals/architecture.md	-	architecture docs still describe the HTTP server as std.net"
  "fixed	zero external dependencies	docs/internals/architecture.md	-	architecture docs still claim zero external dependencies"
  "fixed	threaded and evented I/O paths	docs/performance.md	-	performance docs still claim evented request path support"
  # Front-door docs must link to the module catalog rather than restate its size,
  # which is how the count drifted before the catalog became generated.
  "regex	[0-9]+[^[:cntrl:]]*\`zttp:\\*\`[^[:cntrl:]]*modules|[0-9]+[^[:cntrl:]]*(native|built-in)[^[:cntrl:]]*modules[^[:cntrl:]]*\`zttp:\\*\`	README.md docs/README.md docs/user-guide.md docs/roadmap.md	-	front-door docs hardcode zttp:* module counts; link to docs/virtual-modules/README.md instead"
)

# Dated plan and decision records under docs/plans/, and everything under
# docs/archive/, are excluded from every row. These bans exist to keep the docs
# a reader is pointed at accurate; a plan that records retiring a path has to be
# able to name the path it retired. The gate proved this the hard way: two rows
# fired on the paragraph in 2026-07-28-001-reset-simplification-plan.md that
# documents this very table.
plans_exclude='^docs/plans/|^docs/archive/'

for row in "${prose_bans[@]}"; do
  IFS=$'\t' read -r kind pattern paths exclude message <<<"$(printf '%b' "$row")"
  case "$kind" in
    fixed) hits="$(grep -R -n -F -- "$pattern" $paths 2>/dev/null || true)" ;;
    regex) hits="$(grep -R -n -E -- "$pattern" $paths 2>/dev/null || true)" ;;
    *) fail "unknown prose ban kind '$kind'" ;;
  esac
  hits="$(printf '%s\n' "$hits" | grep -v -E "$plans_exclude" || true)"
  if [[ "$exclude" != "-" ]]; then
    hits="$(printf '%s\n' "$hits" | grep -v -E "$exclude" || true)"
  fi
  # An all-whitespace result means no hits survived the exclusion.
  if [[ -n "${hits//[[:space:]]/}" ]]; then
    fail "$message"
  fi
done

# The model-1 proof capsules are ambient. A stale `zttp:types` import is
# refused as ZTS053, so no live source, scaffold, skill, or current document
# may teach it. Historical records and the three refusal/negative probes must
# retain the spelling. Count the tracked input first: a successful empty scan
# over an accidentally empty corpus is not evidence.
live_surface_count="$(git ls-files -z | tr -cd '\0' | wc -c | tr -d '[:space:]')"
if (( live_surface_count < 100 )); then
  fail "legacy types-import gate scanned only $live_surface_count tracked files"
fi

legacy_types_hits="$({
  git ls-files -z |
    xargs -0 rg -n -F -- 'zttp:types' 2>/dev/null || true
} | grep -v -E '^(CHANGELOG\.md:|docs/(archive|plans|solutions)/|docs/(convergence|restrictions-to-proofs)\.md:|packages/pi/src/providers/testdata/codegen/|packages/pi/src/simulator/testdata/empirical/|packages/zts/src/(stripper|restriction_registry)\.zig:|packages/tools/src/precompile\.zig:|packages/pi/src/expert_persona\.zig:|scripts/check-docs-drift\.sh:)' || true)"
if [[ -n "${legacy_types_hits//[[:space:]]/}" ]]; then
  printf '%s\n' "$legacy_types_hits" >&2
  fail "live source still references removed zttp:types; use ambient Proof<T, P> and Effects<T, R>"
fi

printf 'docs drift: OK (%s builtin virtual modules)\n' "$module_count"

#!/bin/bash
# Run all example handler tests.
# Exits with code 1 if any test suite fails.
#
# Usage: bash scripts/test-examples.sh [path/to/zttp]
#
# With no argument the script builds the tree itself and uses zig-out/bin/zttp,
# which is how a developer runs it by hand. With a binary path it uses that and
# builds nothing: `zig build test` wires it that way through addFileArg, and a
# nested `zig build` inside a running build would re-enter the build graph.

set -e

ZIG="${ZIG:-zig}"
PASS=0
FAIL=0

if [ "$#" -ge 1 ]; then
    ZTTP="$1"
    if [ ! -x "$ZTTP" ]; then
        echo "error: '$ZTTP' is not an executable; this gate has no binary to exercise the examples with" >&2
        exit 1
    fi
else
    ZTTP="${ZTTP:-zig-out/bin/zttp}"
    # Build once up front, then invoke the produced binary directly. Going
    # through `zig build run --` per suite would re-walk the build graph for
    # every suite.
    echo "Building runtime..."
    $ZIG build
    echo ""
fi

run_tests_with_args() {
    local handler=$1
    local tests=$2
    shift 2
    local name
    name=$(echo "$handler" | sed 's|examples/||')

    local output
    local command_status
    if output=$("$ZTTP" serve "$handler" "$@" --test "$tests" 2>&1); then
        command_status=0
    else
        command_status=$?
    fi

    local results
    results=$(echo "$output" | grep "^Results:" || echo "Results: ? passed, ? failed, ? total")
    local passed
    passed=$(echo "$results" | grep -o '[0-9]* passed' | grep -o '[0-9]*')
    local failed
    failed=$(echo "$results" | grep -o '[0-9]* failed' | grep -o '[0-9]*')

    # A suite that ran no test proves nothing: zero failures over zero tests
    # is not a pass.
    if [ "$command_status" -eq 0 ] && [ "${failed:-1}" = "0" ] && [ "${passed:-0}" -gt 0 ]; then
        echo "  PASS  $name ($passed tests)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name (${passed:-0} passed, ${failed:-?} failed)"
        echo "$output" | grep "FAIL" | head -5 | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
}

# Assert a handler type-checks clean (exit 0, no errors/warnings) under the
# analyzer. Used for examples whose value is the static proof, not runtime I/O.
check_types() {
    local handler=$1
    local name
    name=$(echo "$handler" | sed 's|examples/||')

    if "$ZTTP" check "$handler" --types >/dev/null 2>&1; then
        echo "  PASS  $name (check --types)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name (check --types)"
        "$ZTTP" check "$handler" --types 2>&1 | grep -iE "error|warning" | head -5 | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
}

echo "Example Handler Tests"
echo "====================="
echo ""

# handler/
run_tests_with_args "examples/handler/handler.ts"       "examples/handler/handler-ts.test.jsonl"
run_tests_with_args "examples/handler/sugar.ts"          "examples/handler/sugar.test.jsonl"
run_tests_with_args "examples/handler/feature-probes.ts" "examples/handler/feature-probes.test.jsonl"

# modules/
run_tests_with_args "examples/modules/modules.ts"      "examples/modules/modules.test.jsonl"
run_tests_with_args "examples/modules/modules_all.ts"  "examples/modules/modules_all.test.jsonl"

# fetch/
run_tests_with_args "examples/fetch/weather-forecasts.ts" "examples/fetch/weather-forecasts.test.jsonl"
run_tests_with_args "examples/fetch/weather-app.ts"       "examples/fetch/weather-app.test.jsonl"
run_tests_with_args "examples/fetch/webhook.ts"           "examples/fetch/webhook.test.jsonl"

# routing/
run_tests_with_args "examples/routing/router.ts"         "examples/routing/router.test.jsonl"
run_tests_with_args "examples/routing/guard-flow.ts"  "examples/routing/guard-flow.test.jsonl"
run_tests_with_args "examples/routing/match-handler.ts"  "examples/routing/match-handler.test.jsonl"

# patterns/ - every pattern example must type-check clean; the
# request-dependent handlers additionally get behavioral suites.
while IFS= read -r -d '' h; do
    check_types "$h"
done < <(git ls-files -z -- 'examples/patterns/*.ts')
run_tests_with_args "examples/patterns/validate-external.ts"         "examples/patterns/validate-external.test.jsonl"
run_tests_with_args "examples/patterns/discriminated-union-match.ts" "examples/patterns/discriminated-union-match.test.jsonl"
run_tests_with_args "examples/patterns/derive-types.ts"              "examples/patterns/derive-types.test.jsonl"
run_tests_with_args "examples/patterns/json-and-dict.ts"             "examples/patterns/json-and-dict.test.jsonl"
run_tests_with_args "examples/patterns/result-combinators.ts"      "examples/patterns/result-combinators.test.jsonl"
run_tests_with_args "examples/patterns/bytes-boundary.ts"            "examples/patterns/bytes-boundary.test.jsonl"
run_tests_with_args "examples/patterns/nominal-brand.ts"           "examples/patterns/nominal-brand.test.jsonl"
run_tests_with_args "examples/patterns/boundary-types.ts"          "examples/patterns/boundary-types.test.jsonl"

# validate/
run_tests_with_args "tests/validate/format_handler.ts" "tests/validate/format.test.jsonl"

# sql/ - a zttp:sql handler needs its schema to type-check; assert it proves
# clean (this is the example whose one-arg sqlMany("listTodos") regressed when
# the sql bindings lacked required_arg_count).
if "$ZTTP" check examples/sql/sql-crud.ts --sql-schema examples/sql/schema.sql >/dev/null 2>&1; then
    echo "  PASS  sql/sql-crud.ts (check --sql-schema)"
    PASS=$((PASS + 1))
else
    echo "  FAIL  sql/sql-crud.ts (check --sql-schema)"
    "$ZTTP" check examples/sql/sql-crud.ts --sql-schema examples/sql/schema.sql 2>&1 | grep -iE "error|warning" | head -5 | sed 's/^/        /'
    FAIL=$((FAIL + 1))
fi

# Every example handler must pass `zttp check`: the rule that `zttp test` and
# `zttp deploy` apply. `serve --test` above never runs it, so an example could
# drift from the acceptance rule. Exit 0 is clean and exit 2 is warnings only.
# The files below are not handlers, or exist to show a refusal, or need an
# argument that the loop does not pass.
check_excluded() {
    case "$1" in
        examples/handler/feature-probes.ts) return 0 ;;     # probes forms the profile refuses (ZTS613)
        examples/handler/utils.ts) return 0 ;;              # helper module, has no handler
        examples/handler/secret-leak.ts) return 0 ;;        # shows the ZTS400 refusal
        examples/handler/spec-fails-idempotent.ts) return 0 ;; # shows a declared proof that fails
        examples/autoloop/handler.ts) return 0 ;;           # insecure on purpose, for the repair demo
        examples/modules/modules_all.ts) return 0 ;;        # returns a jwtSign token that flow labels secret (ZTS400)
        examples/sql/sql-crud.ts) return 0 ;;               # needs --sql-schema, checked above
    esac
    return 1
}

while IFS= read -r -d '' h; do
    if check_excluded "$h"; then
        continue
    fi
    name=$(echo "$h" | sed 's|examples/||')
    if "$ZTTP" check "$h" >/dev/null 2>&1; then
        check_status=0
    else
        check_status=$?
    fi
    if [ "$check_status" -eq 0 ] || [ "$check_status" -eq 2 ]; then
        echo "  PASS  $name (check)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name (check, exit $check_status)"
        "$ZTTP" check "$h" 2>&1 | grep -E "\((error)\)|error\[" | head -5 | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
done < <(git ls-files -z -- 'examples/*.ts' 'tests/validate/format_handler.ts')

# `zttp check` writes a zttp.d.ts typings stub into the cwd; drop it.
rm -f zttp.d.ts

echo ""
echo "====================="
echo "Suites: $((PASS + FAIL)) total, $PASS passed, $FAIL failed"

# Floor on this gate's own input. Every suite above is an explicit call, so a
# refactor that drops calls - or an examples/ tree that loses files - leaves
# this script printing "Suites: 0 total, 0 passed, 0 failed" and exiting 0,
# which reads as coverage. The number is a backstop against an emptied run and
# not a target: it equals the current count, so a deleted suite fails the floor.
# Adding a suite leaves the run passing; raise the floor by hand to keep it exact.
# The unfiltered retained example suite measured 33 passing suites in Phase 3; tests/validate added the 34th,
# and the 27 `zttp check` suites added the rest (34 + 27 = 61).
MIN_SUITES=61
if [ "$((PASS + FAIL))" -lt "$MIN_SUITES" ]; then
    echo "error: ran $((PASS + FAIL)) suites, fewer than the floor of $MIN_SUITES - this run checked almost nothing and would otherwise report a pass" >&2
    exit 1
fi

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

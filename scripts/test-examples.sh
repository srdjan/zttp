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
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zttp-examples.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
NEXT_PORT=39000

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
    output=$("$ZTTP" serve "$handler" "$@" --test "$tests" 2>&1) || true

    local results
    results=$(echo "$output" | grep "^Results:" || echo "Results: ? passed, ? failed, ? total")
    local passed
    passed=$(echo "$results" | grep -o '[0-9]* passed' | grep -o '[0-9]*')
    local failed
    failed=$(echo "$results" | grep -o '[0-9]* failed' | grep -o '[0-9]*')

    if [ "${failed:-1}" = "0" ]; then
        echo "  PASS  $name ($passed tests)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name ($failed failed)"
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

check_system() {
    local manifest=$1
    local name
    name=$(echo "$manifest" | sed 's|examples/||')
    local output_dir="$TMP_ROOT/system-link-$PASS-$FAIL"
    local output="$output_dir/output.log"
    mkdir -p "$output_dir"

    if "$ZTTP" link "$manifest" --output-dir "$output_dir" >"$output" 2>&1; then
        echo "  PASS  $name (link)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name (link)"
        grep -iE "error|failed|unresolved" "$output" | head -5 | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
}

start_live_server() {
    local handler=$1
    shift
    LIVE_PORT=$NEXT_PORT
    NEXT_PORT=$((NEXT_PORT + 1))
    LIVE_LOG="$TMP_ROOT/live-$LIVE_PORT.log"
    "$ZTTP" serve "$handler" -p "$LIVE_PORT" "$@" >"$LIVE_LOG" 2>&1 &
    LIVE_PID=$!

    local i
    for i in $(seq 1 50); do
        if curl --max-time 5 -fsS "http://127.0.0.1:$LIVE_PORT/_health" >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$LIVE_PID" 2>/dev/null; then
            return 1
        fi
        sleep 0.1
    done
    return 1
}

stop_live_server() {
    if [ "${LIVE_PID:-}" != "" ] && kill -0 "$LIVE_PID" 2>/dev/null; then
        kill "$LIVE_PID" 2>/dev/null || true
        local i
        for i in $(seq 1 20); do
            if ! kill -0 "$LIVE_PID" 2>/dev/null; then
                wait "$LIVE_PID" 2>/dev/null || true
                return 0
            fi
            sleep 0.1
        done
        kill -KILL "$LIVE_PID" 2>/dev/null || true
        wait "$LIVE_PID" 2>/dev/null || true
        return 1
    fi
    return 0
}

expect_contains() {
    local body=$1
    local needle=$2
    echo "$body" | grep -q "$needle"
}

record_live_result() {
    local name=$1
    local ok=$2
    if [ "$ok" = "0" ]; then
        echo "  PASS  $name (live workflow)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name (live workflow)"
        if [ -f "${LIVE_LOG:-}" ]; then
            head -8 "$LIVE_LOG" | sed 's/^/        /'
        fi
        FAIL=$((FAIL + 1))
    fi
}

run_live_workflow() {
    local name=$1
    local handler=$2
    shift 2
    local ok=1
    if start_live_server "$handler" "$@"; then
        case "$name" in
            workflow/orchestrator.ts)
                local body
                body=$(curl --max-time 5 -fsS "http://127.0.0.1:$LIVE_PORT/" || true)
                expect_contains "$body" '"subStatus":200' && expect_contains "$body" '"from":"greet"' && ok=0
                ;;
            workflow/fanout-orchestrator.ts)
                local body
                body=$(curl --max-time 5 -fsS "http://127.0.0.1:$LIVE_PORT/" || true)
                expect_contains "$body" '"n":3' && expect_contains "$body" '"path":"/a"' && expect_contains "$body" '"path":"/c"' && ok=0
                ;;
            workflow/follow-orchestrator.ts)
                local body
                body=$(curl --max-time 5 -fsS "http://127.0.0.1:$LIVE_PORT/" || true)
                expect_contains "$body" '"from":"greet"' && expect_contains "$body" '"path":"/greet"' && ok=0
                ;;
            workflow/durable-orchestrator.ts)
                local first second
                first=$(curl --max-time 5 -fsS -H 'Idempotency-Key: workflow-demo' "http://127.0.0.1:$LIVE_PORT/" || true)
                second=$(curl --max-time 5 -fsS -H 'Idempotency-Key: workflow-demo' "http://127.0.0.1:$LIVE_PORT/" || true)
                expect_contains "$first" '"orchestrated":true' && expect_contains "$second" '"orchestrated":true' && ok=0
                ;;
            workflow/queued-orchestrator.ts)
                local body
                body=$(curl --max-time 5 -fsS -H 'Idempotency-Key: queued-demo' "http://127.0.0.1:$LIVE_PORT/" || true)
                expect_contains "$body" '"queued":true' && expect_contains "$body" '"path":"/queued"' && ok=0
                ;;
            workflow/dsl-orchestrator.ts)
                local body
                body=$(curl --max-time 5 -fsS -H 'Idempotency-Key: workflow-dsl-demo' "http://127.0.0.1:$LIVE_PORT/" || true)
                expect_contains "$body" '"workflowDsl":true' && expect_contains "$body" '"childBoundary":"workflow.call:greet"' && expect_contains "$body" '"path":"/workflow-dsl"' && ok=0
                ;;
            workflow/wait-signal-orchestrator.ts)
                local pending signaled resumed pending2 scheduled resumed2
                pending=$(curl --max-time 5 -fsS -H 'Idempotency-Key: approval-demo' "http://127.0.0.1:$LIVE_PORT/wait" || true)
                signaled=$(curl --max-time 5 -fsS -H 'Idempotency-Key: approval-demo' "http://127.0.0.1:$LIVE_PORT/signal" || true)
                resumed=$(curl --max-time 5 -fsS -H 'Idempotency-Key: approval-demo' "http://127.0.0.1:$LIVE_PORT/wait" || true)
                pending2=$(curl --max-time 5 -fsS -H 'Idempotency-Key: schedule-demo' "http://127.0.0.1:$LIVE_PORT/wait" || true)
                scheduled=$(curl --max-time 5 -fsS -H 'Idempotency-Key: schedule-demo' "http://127.0.0.1:$LIVE_PORT/schedule" || true)
                resumed2=$(curl --max-time 5 -fsS -H 'Idempotency-Key: schedule-demo' "http://127.0.0.1:$LIVE_PORT/wait" || true)
                expect_contains "$pending" '"type":"signal"' && expect_contains "$signaled" '"delivered":true' && expect_contains "$resumed" '"approved":true' \
                    && expect_contains "$pending2" '"type":"signal"' && expect_contains "$scheduled" '"scheduled":true' && expect_contains "$resumed2" '"approved":true' && ok=0
                ;;
            workflow/timeout-orchestrator.ts)
                local body
                body=$(curl --max-time 5 -fsS -H 'Idempotency-Key: timeout-demo' "http://127.0.0.1:$LIVE_PORT/" || true)
                expect_contains "$body" '"ok":false' && expect_contains "$body" '"error":"timeout"' && ok=0
                ;;
            workflow/scope-orchestrator.ts)
                local body
                body=$(curl --max-time 5 -fsS "http://127.0.0.1:$LIVE_PORT/" || true)
                expect_contains "$body" '"name":"primary"' && expect_contains "$body" '"cached":"cache-entry"' && ok=0
                ;;
            workflow/queued-fanout-orchestrator.ts)
                local body
                body=$(curl --max-time 5 -fsS -H 'Idempotency-Key: queued-fanout-demo' "http://127.0.0.1:$LIVE_PORT/" || true)
                expect_contains "$body" '"n":2' && expect_contains "$body" '"path":"/a"' && expect_contains "$body" '"path":"/b"' && ok=0
                ;;
            workflow/saga-orchestrator.ts)
                local success failed compfail
                success=$(curl --max-time 5 -fsS -H 'Idempotency-Key: saga-demo-ok' "http://127.0.0.1:$LIVE_PORT/" || true)
                failed=$(curl --max-time 5 -sS -H 'Idempotency-Key: saga-demo-fail' "http://127.0.0.1:$LIVE_PORT/fail" || true)
                compfail=$(curl --max-time 5 -sS -H 'Idempotency-Key: saga-demo-compfail' "http://127.0.0.1:$LIVE_PORT/compensation-fails" || true)
                expect_contains "$success" '"ok":true' && expect_contains "$failed" '"compensated":true' && expect_contains "$compfail" '"compensationFailed":"reserve"' && ok=0
                ;;
            workflow/entry-orchestrator.ts)
                local body
                body=$(curl --max-time 5 -fsS -X POST "http://127.0.0.1:$LIVE_PORT/orders" || true)
                expect_contains "$body" '"reservedStatus":200' && expect_contains "$body" '"shippedStatus":200' && ok=0
                ;;
        esac
    fi
    stop_live_server || true
    record_live_result "$name" "$ok"
}

run_workflow_queue_dead_letter_fixture() {
    local durable="$TMP_ROOT/workflow-dead-letter"
    local dead_dir="$durable/workflow-queue/dead"
    local id="item-docs"
    mkdir -p "$dead_dir"
    cat > "$dead_dir/$id.json" <<'JSON'
{"reason":"workflow queue max attempts exceeded","attempts":3,"last_error":"boom","dead_at_ms":1,"source":"example","request_json":"{\"target\":\"greet\",\"method\":\"GET\",\"path\":\"/dead-letter\",\"url\":\"/dead-letter\",\"query\":[],\"headers\":{},\"body\":null,\"attempts\":3,\"lease_until_ms\":0,\"lease_owner\":\"example\",\"created_at_ms\":1,\"updated_at_ms\":1,\"last_error\":\"boom\"}"}
JSON

    local list_output show_output replay_output
    list_output=$("$ZTTP" workflow-queue list --durable "$durable" 2>&1) || true
    show_output=$("$ZTTP" workflow-queue show --durable "$durable" "$id" 2>&1) || true
    replay_output=$("$ZTTP" workflow-queue replay --durable "$durable" "$id" 2>&1) || true

    if echo "$list_output" | grep -q "$id" && \
       echo "$show_output" | grep -q "workflow queue max attempts exceeded" && \
       echo "$replay_output" | grep -q "replayed $id"; then
        echo "  PASS  workflow/dead-letter fixture (workflow-queue replay)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  workflow/dead-letter fixture (workflow-queue replay)"
        echo "$list_output" | head -3 | sed 's/^/        list: /'
        echo "$show_output" | head -3 | sed 's/^/        show: /'
        echo "$replay_output" | head -3 | sed 's/^/        replay: /'
        FAIL=$((FAIL + 1))
    fi
}

echo "Example Handler Tests"
echo "====================="
echo ""

# handler/
run_tests_with_args "examples/handler/handler-full.tsx" "examples/handler/handler.test.jsonl"
run_tests_with_args "examples/handler/handler.ts"       "examples/handler/handler-ts.test.jsonl"
run_tests_with_args "examples/handler/handler.tsx"       "examples/handler/handler-tsx.test.jsonl"
run_tests_with_args "examples/handler/sugar.ts"          "examples/handler/sugar.test.jsonl"
run_tests_with_args "examples/handler/feature-probes.ts" "examples/handler/feature-probes.test.jsonl"

# jsx/
run_tests_with_args "examples/jsx/jsx-simple.tsx"    "examples/jsx/jsx-simple.test.jsonl"
run_tests_with_args "examples/jsx/jsx-component.tsx" "examples/jsx/jsx-component.test.jsonl"
run_tests_with_args "examples/jsx/jsx-ssr.tsx"       "examples/jsx/jsx-ssr.test.jsonl"

# modules/
run_tests_with_args "examples/modules/modules.ts"      "examples/modules/modules.test.jsonl"
run_tests_with_args "examples/modules/modules_all.ts"  "examples/modules/modules_all.test.jsonl"

# parallel/
check_types "examples/parallel/parallel-simple.ts"
check_types "examples/parallel/parallel.ts"

# system/
check_system "examples/system/system.json"
check_system "examples/system/system-static.json"

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
for h in examples/patterns/*.ts; do check_types "$h"; done
run_tests_with_args "examples/patterns/validate-external.ts"         "examples/patterns/validate-external.test.jsonl"
run_tests_with_args "examples/patterns/discriminated-union-match.ts" "examples/patterns/discriminated-union-match.test.jsonl"
run_tests_with_args "examples/patterns/derive-types.ts"              "examples/patterns/derive-types.test.jsonl"
run_tests_with_args "examples/patterns/json-and-dict.ts"             "examples/patterns/json-and-dict.test.jsonl"
run_tests_with_args "examples/patterns/result-combinators.ts"      "examples/patterns/result-combinators.test.jsonl"
run_tests_with_args "examples/patterns/bytes-boundary.ts"            "examples/patterns/bytes-boundary.test.jsonl"
run_tests_with_args "examples/patterns/nominal-brand.ts"           "examples/patterns/nominal-brand.test.jsonl"
run_tests_with_args "examples/patterns/boundary-types.ts"          "examples/patterns/boundary-types.test.jsonl"

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

# workflow/
run_live_workflow "workflow/orchestrator.ts" "examples/workflow/orchestrator.ts" --system examples/workflow/system.json
run_live_workflow "workflow/fanout-orchestrator.ts" "examples/workflow/fanout-orchestrator.ts" --system examples/workflow/system.json
run_live_workflow "workflow/follow-orchestrator.ts" "examples/workflow/follow-orchestrator.ts" --system examples/workflow/system.json
run_live_workflow "workflow/durable-orchestrator.ts" "examples/workflow/durable-orchestrator.ts" --system examples/workflow/system.json --durable "$TMP_ROOT/durable-call"
run_live_workflow "workflow/queued-orchestrator.ts" "examples/workflow/queued-orchestrator.ts" --system examples/workflow/system.json --durable "$TMP_ROOT/durable-queued" --workflow-queue
run_live_workflow "workflow/dsl-orchestrator.ts" "examples/workflow/dsl-orchestrator.ts" --system examples/workflow/system.json --durable "$TMP_ROOT/durable-dsl" --workflow-queue
# dsl-orchestrator is embedded as a canonical few-shot, so its declared Proof<T, P>
# must prove clean. Gate directly on an empty spec_diagnostics array in the
# --json output (catches a ZTS500/ZTS501 over-claim - the exact regression this
# example already hit once with retry_safe/idempotent).
DSL_JSON="$("$ZTTP" check examples/workflow/dsl-orchestrator.ts --system examples/workflow/system.json --json 2>/dev/null)"
if printf '%s' "$DSL_JSON" | grep -q '"spec_diagnostics":\[\]'; then
    echo "  PASS  workflow/dsl-orchestrator.ts (Proof discharge, --json)"
    PASS=$((PASS + 1))
else
    echo "  FAIL  workflow/dsl-orchestrator.ts (Proof discharge: declared capsule not fully proven)"
    printf '%s' "$DSL_JSON" | grep -oE '"spec_diagnostics":\[[^]]*\]' | head -1 | sed 's/^/        /'
    FAIL=$((FAIL + 1))
fi
run_live_workflow "workflow/wait-signal-orchestrator.ts" "examples/workflow/wait-signal-orchestrator.ts" --durable "$TMP_ROOT/durable-signal"
run_live_workflow "workflow/timeout-orchestrator.ts" "examples/workflow/timeout-orchestrator.ts" --durable "$TMP_ROOT/durable-timeout"
run_live_workflow "workflow/scope-orchestrator.ts" "examples/workflow/scope-orchestrator.ts"
run_live_workflow "workflow/queued-fanout-orchestrator.ts" "examples/workflow/queued-fanout-orchestrator.ts" --system examples/workflow/system.json --durable "$TMP_ROOT/durable-queued-fanout" --workflow-queue
run_live_workflow "workflow/saga-orchestrator.ts" "examples/workflow/saga-orchestrator.ts" --system examples/workflow/system.json --durable "$TMP_ROOT/durable-saga"
run_live_workflow "workflow/entry-orchestrator.ts" "examples/workflow/entry-orchestrator.ts" --system examples/workflow/entry-system.json
run_workflow_queue_dead_letter_fixture

# `zttp check` writes a zttp.d.ts typings stub into the cwd; drop it.
rm -f zttp.d.ts

echo ""
echo "====================="
echo "Suites: $((PASS + FAIL)) total, $PASS passed, $FAIL failed"

# Floor on this gate's own input. Every suite above is an explicit call, so a
# refactor that drops calls - or an examples/ tree that loses files - leaves
# this script printing "Suites: 0 total, 0 passed, 0 failed" and exiting 0,
# which reads as coverage. The number is a backstop against an emptied run and
# not a target: set well under the current count so adding a suite never has to
# move it, and a deletion of any real fraction of them does.
MIN_SUITES=40
if [ "$((PASS + FAIL))" -lt "$MIN_SUITES" ]; then
    echo "error: ran $((PASS + FAIL)) suites, fewer than the floor of $MIN_SUITES - this run checked almost nothing and would otherwise report a pass" >&2
    exit 1
fi

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

#!/bin/bash
# E2E test for handler panic isolation (B1).
# Verifies that a panicking handler returns HTTP 500 and the server survives to
# serve subsequent requests. Uses the internal --_debug-panic-path test hook to trigger
# a real panic on a specific request path inside callHandlerGuarded.
#
# Usage: bash scripts/test-panic-isolation.sh [--skip-build] [--zttp PATH]

set -euo pipefail

SKIP_BUILD=0
ZIG="${ZIG:-zig}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZTTP="${ZTTP:-$REPO_ROOT/zig-out/bin/zttp}"
PORT=$((RANDOM % 1000 + 14000))

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --zttp)
            [ "$#" -ge 2 ] || { printf '[panic-isolation] FAIL: --zttp requires a path\n' >&2; exit 1; }
            ZTTP="$2"
            shift 2
            ;;
        *)
            printf '[panic-isolation] FAIL: unknown argument: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zttp-panic.XXXXXX")
APP_DIR="$TMP_DIR/panic-app"
SERVER_LOG="$TMP_DIR/server.log"
SRV_PID=""

cleanup() {
    stop_server
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

stop_server() {
    # `return 0`, not a bare `return`: with no server started the test yields
    # the status of the failed `[ -n ... ]`, and under `set -e` that aborts the
    # EXIT trap before `cleanup` reaches `rm -rf "$TMP_DIR"`.
    [ -n "$SRV_PID" ] || return 0
    kill "$SRV_PID" 2>/dev/null || true
    sleep 0.2
    kill -9 "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
    SRV_PID=""
}

wait_for_server() {
    local port="$1"
    for _ in $(seq 1 25); do
        if /usr/bin/curl -sf "http://127.0.0.1:$port/_health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

step() { printf '\n[panic-isolation] %s\n' "$*"; }
fail() {
    printf '\n[panic-isolation] FAIL: %s\n' "$*" >&2
    if [ -f "$SERVER_LOG" ]; then
        printf '\n[panic-isolation] server log:\n' >&2
        sed -n '1,120p' "$SERVER_LOG" >&2
    fi
    exit 1
}

if [ "$SKIP_BUILD" = "1" ]; then
    step "use existing $ZTTP"
else
    step "build $ZTTP"
    (cd "$REPO_ROOT" && $ZIG build) || fail "zig build failed"
fi
[ -x "$ZTTP" ] || fail "missing $ZTTP after build"

step "init test app"
(cd "$TMP_DIR" && "$ZTTP" init "panic-app" >/dev/null) || fail "init failed"
[ -f "$APP_DIR/src/handler.ts" ] || fail "handler.ts not created by init"

cat > "$APP_DIR/src/handler.ts" <<'HANDLER'

type Guardrails<T> = Proof<T,
    | "deterministic"
    | "no_secret_leakage"
    | "injection_safe"
>;

function handler(req: Request): Guardrails<Response> {
    if (req.method === "GET" && req.path === "/crash") {
        return Response.text("panic injection route");
    }
    if (req.method === "GET" && req.path === "/ok") {
        return Response.text("ok");
    }
    return Response.text("not found", { status: 404 });
}
HANDLER

step "start server on :$PORT with panic injection path /crash"
"$ZTTP" serve "$APP_DIR/src/handler.ts" -p "$PORT" --_debug-panic-path /crash \
    >"$SERVER_LOG" 2>&1 &
SRV_PID=$!

# Wait up to 5s for the server to accept connections.
wait_for_server "$PORT" || fail "server did not become ready on :$PORT within 5s"

step "send panicking request GET /crash - expect HTTP 500"
status=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 "http://127.0.0.1:$PORT/crash")
[ "$status" = "500" ] || fail "expected 500 from /crash, got $status"

step "verify server process survived the panic"
kill -0 "$SRV_PID" 2>/dev/null || fail "server process exited after handler panic"

step "verify subsequent request succeeds (slot rebuilt after quarantine)"
ok_status=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 "http://127.0.0.1:$PORT/ok")
[ "$ok_status" = "200" ] || fail "expected 200 on recovery request, got $ok_status"

stop_server


# Native stack exhaustion checks. Each check runs zttp as a child process so a
# crash fails one check and not this script. The native stack floor makes script
# recursion return CallStackOverflow before the thread stack ends
# (docs/plans/2026-11-14-script-recursion-native-stack-plan.md).
STACK_FAILED=0

stack_pass() { printf '[panic-isolation] PASS: %s\n' "$*"; }
stack_fail() {
    printf '[panic-isolation] FAIL: %s\n' "$*"
    STACK_FAILED=$((STACK_FAILED + 1))
}

# make_stack_app DIR: write the project files shared by the four checks.
# The caller writes DIR/src/handler.ts afterwards.
make_stack_app() {
    mkdir -p "$1/src" "$1/tests"
    printf '%s\n' '{"entry":"src/handler.ts"}' > "$1/zttp.json"
    printf '%s\n' \
        '{"type":"test","name":"serves a text body"}' \
        '{"type":"request","method":"GET","url":"/","headers":{},"body":null}' \
        '{"type":"expect","status":200}' > "$1/tests/handler.test.jsonl"
}

# run_stack_test DIR: run zttp test, set STACK_RC and STACK_OUT.
run_stack_test() {
    STACK_RC=0
    STACK_OUT=$(cd "$1" && "$ZTTP" test "$1/tests/handler.test.jsonl" 2>&1 < /dev/null) || STACK_RC=$?
}

# zttp test prints this whole line when the interpreter refuses a script call.
OVERFLOW_LINE='error: Handler execution failed: error.CallStackOverflow'

step "stack check 1: zttp test on unbounded recursion ends with CallStackOverflow"
UNBOUNDED_DIR="$TMP_DIR/unbounded-app"
make_stack_app "$UNBOUNDED_DIR"
cat > "$UNBOUNDED_DIR/src/handler.ts" <<'HANDLER'
function down(n: number): number { return down(n + 1); }
export function handler(req: Request): Proof<Response, "state_isolated"> { return Response.text(String(down(0))); }
HANDLER
run_stack_test "$UNBOUNDED_DIR"
if [ "$STACK_RC" -ge 128 ]; then
    stack_fail "unbounded recursion: zttp test ended on a signal, exit $STACK_RC"
elif [ "$STACK_RC" != "1" ]; then
    stack_fail "unbounded recursion: expected exit 1, got $STACK_RC"
elif ! printf '%s\n' "$STACK_OUT" | grep -qxF "$OVERFLOW_LINE"; then
    stack_fail "unbounded recursion: exit 1 without the line '$OVERFLOW_LINE'"
else
    stack_pass "unbounded recursion: exit 1 with CallStackOverflow"
fi

step "stack check 2: zttp serve answers 500 on unbounded recursion and survives"
DEEP_DIR="$TMP_DIR/deep-app"
make_stack_app "$DEEP_DIR"
cat > "$DEEP_DIR/src/handler.ts" <<'HANDLER'
function down(n: number): number { return down(n + 1); }
export function handler(req: Request): Proof<Response, "state_isolated"> {
    if (req.path === "/deep") { return Response.text(String(down(0))); }
    return Response.text("ok");
}
HANDLER
DEEP_PORT=$((PORT + 1))
SERVER_LOG="$TMP_DIR/deep-server.log"
"$ZTTP" serve "$DEEP_DIR/src/handler.ts" -p "$DEEP_PORT" >"$SERVER_LOG" 2>&1 < /dev/null &
SRV_PID=$!
if ! wait_for_server "$DEEP_PORT"; then
    stack_fail "serve recursion: server did not become ready on :$DEEP_PORT"
else
    deep_curl=0
    deep_status=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        "http://127.0.0.1:$DEEP_PORT/deep" < /dev/null) || deep_curl=$?
    if kill -0 "$SRV_PID" 2>/dev/null; then deep_alive=alive; else deep_alive=gone; fi
    ok_curl=0
    ok_status=$(/usr/bin/curl -s -o "$TMP_DIR/ok-body" -w "%{http_code}" --max-time 10 \
        "http://127.0.0.1:$DEEP_PORT/ok" < /dev/null) || ok_curl=$?
    ok_body=$(cat "$TMP_DIR/ok-body" 2>/dev/null) || ok_body=""
    if [ "$deep_curl" = "0" ] && [ "$deep_status" = "500" ] && [ "$deep_alive" = "alive" ] \
        && [ "$ok_curl" = "0" ] && [ "$ok_status" = "200" ] && [ "$ok_body" = "ok" ]; then
        stack_pass "serve recursion: /deep 500, server alive, /ok 200 with body ok"
    else
        stack_fail "serve recursion: /deep status ${deep_status:-none} curl $deep_curl, server $deep_alive, /ok status ${ok_status:-none} curl $ok_curl body '${ok_body}'"
    fi
fi
stop_server

step "stack check 3: zttp test on depth 185 with a stringifyJson leaf nested 500 deep"
LEAF_DIR="$TMP_DIR/json-leaf-app"
make_stack_app "$LEAF_DIR"
cat > "$LEAF_DIR/src/handler.ts" <<'HANDLER'
import { stringifyJson } from "zttp:json";
type Tree = number | Tree[];
function build(k: number): Tree { let o: Tree = 1; for (const i of range(k)) { o = [o]; } return o; }
function leaf(): number { const t = build(500); const r = stringifyJson(t); if (!r.ok) { return 0; } const s = r.value; if (typeof s !== "string") { return 0; } return s.length; }
function down(n: number): number { if (n === 0) { return leaf(); } return down(n - 1) + 1; }
export function handler(req: Request): Proof<Response, "state_isolated"> { return Response.text(String(down(185))); }
HANDLER
run_stack_test "$LEAF_DIR"
if [ "$STACK_RC" -ge 128 ]; then
    stack_fail "json leaf: zttp test ended on a signal, exit $STACK_RC"
elif [ "$STACK_RC" = "1" ] && printf '%s\n' "$STACK_OUT" | grep -qxF "$OVERFLOW_LINE"; then
    # Debug: the floor refuses the call before depth 185.
    stack_pass "json leaf: exit 1 with CallStackOverflow"
elif [ "$STACK_RC" = "0" ] && printf '%s\n' "$STACK_OUT" | grep -qxF 'Results: 1 passed, 0 failed, 0 unchecked, 1 total'; then
    # A release build has room for depth 185 and the leaf.
    stack_pass "json leaf: exit 0, the test passed"
else
    stack_fail "json leaf: exit $STACK_RC without the CallStackOverflow line or a full pass"
fi

# Check 4 runs a bounded native leaf at every level of unbounded recursion, so
# the leaf runs just above the floor. The headroom in
# packages/zts/src/stack_floor.zig must leave room for it. The leaves are the
# deepest bounded native calls that were measured: stringifyJson at nesting 500
# (encoder limit 512) and renderToString at 254 nested h() elements.
step "stack check 4: zttp test on unbounded recursion with a native leaf at every level"
LEVEL_FAILED=0
# level_leaf_case NAME: read a leaf() definition from stdin, recurse with it.
level_leaf_case() {
    local name="$1"
    local dir="$TMP_DIR/$name-every-level-app"
    make_stack_app "$dir"
    {
        cat
        printf '%s\n' 'function down(n: number): number { const l = leaf(); return down(n + 1) + l; }'
        printf '%s\n' 'export function handler(req: Request): Proof<Response, "state_isolated"> { return Response.text(String(down(0))); }'
    } > "$dir/src/handler.ts"
    run_stack_test "$dir"
    if [ "$STACK_RC" -ge 128 ]; then
        printf '[panic-isolation] FAIL: %s leaf at every level: ended on a signal, exit %s\n' "$name" "$STACK_RC"
        LEVEL_FAILED=1
    elif [ "$STACK_RC" != "1" ] || ! printf '%s\n' "$STACK_OUT" | grep -qxF "$OVERFLOW_LINE"; then
        printf '[panic-isolation] FAIL: %s leaf at every level: expected exit 1 with CallStackOverflow, got exit %s\n' "$name" "$STACK_RC"
        LEVEL_FAILED=1
    else
        printf '[panic-isolation] PASS: %s leaf at every level: exit 1 with CallStackOverflow\n' "$name"
    fi
}
level_leaf_case json <<'LEAF'
import { stringifyJson } from "zttp:json";
type Tree = number | Tree[];
function build(k: number): Tree { let o: Tree = 1; for (const i of range(k)) { o = [o]; } return o; }
function leaf(): number { const t = build(500); const r = stringifyJson(t); if (!r.ok) { return 0; } const s = r.value; if (typeof s !== "string") { return 0; } return s.length; }
LEAF
level_leaf_case render <<'LEAF'
function leaf(): number { let n = h("b", null, "x"); for (const i of range(254)) { n = h("div", null, n); } const s = renderToString(n); if (s.length > 0) { return 1; } return 0; }
LEAF
if [ "$LEVEL_FAILED" = "0" ]; then
    stack_pass "leaf at every level: json and render both end with CallStackOverflow"
else
    STACK_FAILED=$((STACK_FAILED + 1))
fi

[ "$STACK_FAILED" = "0" ] || fail "$STACK_FAILED of 4 native stack checks failed"

step "PASS: handler panic was isolated, the server recovered, and the four native stack checks passed"
exit 0

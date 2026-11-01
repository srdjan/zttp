#!/bin/bash
# End-to-end smoke test for the v1 user flow:
#   init -> doctor -> check -> build -> run -> deploy -> run.
# Exits non-zero on first failure, with a one-line diagnostic.
#
# Usage: bash scripts/smoke-v1.sh

set -euo pipefail

ZIG="${ZIG:-zig}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZTTP="${ZTTP:-$REPO_ROOT/zig-out/bin/zttp}"
ZTS="${ZTS:-$REPO_ROOT/zig-out/bin/zts}"

# Random ports in the ephemeral range; reduces flake when smoke runs concurrently.
BASE_PORT=$((RANDOM % 1000 + 5000))
BUILD_PORT=$((BASE_PORT + 1))
DEPLOY_PORT=$((BASE_PORT + 2))

TMP_DIR=$(mktemp -d -t zttp-smoke-XXXXXX)
APP_NAME="smoke-app"
APP_DIR="$TMP_DIR/$APP_NAME"
BROKEN_APP_DIR="$TMP_DIR/broken-app"
RUNTIME_BIN="$REPO_ROOT/zig-out/bin/zttp-runtime"
RUNTIME_BAK="$RUNTIME_BIN.smoke-bak"

cleanup() {
    pkill -f "$APP_DIR/.zttp/build/$APP_NAME" 2>/dev/null || true
    pkill -f "$APP_DIR/.zttp/deploy/$APP_NAME" 2>/dev/null || true
    # Restore runtime if the missing-runtime negative test was interrupted.
    [ -e "$RUNTIME_BAK" ] && mv "$RUNTIME_BAK" "$RUNTIME_BIN" 2>/dev/null
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

step() { printf '\n[smoke-v1] %s\n' "$*"; }
fail() { printf '\n[smoke-v1] FAIL: %s\n' "$*" >&2; exit 1; }

# Keep successful smoke steps quiet, but preserve the command's diagnostic when
# a normal user-flow build or deploy fails.
run_captured() {
    local failure_message="$1"
    shift
    local output_path="$TMP_DIR/captured-command-output.log"
    local status=0
    "$@" >"$output_path" 2>&1 || status=$?
    if [ "$status" -ne 0 ]; then
        [ ! -s "$output_path" ] || /bin/cat "$output_path" >&2
        fail "$failure_message"
    fi
}

# Poll URL until reachable (HTTP 2xx) or attempts exhausted, printing the
# response body to stdout. Returns non-zero on exhaustion so callers can
# chain `|| fail "..."` - bash command substitution does not propagate
# `set -e`, so we cannot rely on an inner `fail` to abort the parent.
# Usage: body=$(wait_for_http URL ATTEMPTS) || fail "..."
wait_for_http() {
    local url="$1" attempts="$2"
    for _ in $(seq 1 "$attempts"); do
        if body=$(/usr/bin/curl -sf "$url" 2>/dev/null); then
            printf '%s' "$body"
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# Stop a backgrounded zttp process: kill by PID, sweep stragglers by pattern, wait.
# Usage: stop_bg PID PATTERN
stop_bg() {
    local pid="$1" pattern="$2"
    kill "$pid" 2>/dev/null || true
    pkill -f "$pattern" 2>/dev/null || true
    wait 2>/dev/null || true
}

step "build $ZTTP and zttp-runtime"
(cd "$REPO_ROOT" && $ZIG build) || fail "zig build"
[ -x "$ZTTP" ] || fail "missing $ZTTP after build"

step "diagnostics: successful captures stay quiet and failures explain"
quiet_out=$(run_captured "quiet probe failed" /bin/sh -c 'printf noisy-success-output' 2>&1)
[ -z "$quiet_out" ] || fail "successful captured command leaked output: $quiet_out"
if captured_failure=$(run_captured "diagnostic probe failed" /bin/sh -c 'printf inner-command-diagnostic >&2; exit 23' 2>&1); then
    fail "diagnostic capture probe unexpectedly succeeded"
fi
printf '%s' "$captured_failure" | grep -q "inner-command-diagnostic" || fail "captured failure lost command diagnostic: $captured_failure"
printf '%s' "$captured_failure" | grep -q "diagnostic probe failed" || fail "captured failure lost smoke context: $captured_failure"

step "negative: init rejects path-like project names"
if invalid_out=$(cd "$TMP_DIR" && "$ZTTP" init "../bad-app" 2>&1); then
    fail "init accepted path-like project name"
fi
printf '%s' "$invalid_out" | grep -q "Invalid project name" || fail "init rejection did not explain invalid project name: $invalid_out"

step "negative: build outside a project prints a project diagnostic"
mkdir -p "$TMP_DIR/no-project"
if missing_out=$(cd "$TMP_DIR/no-project" && "$ZTTP" build 2>&1); then
    fail "build succeeded without zttp.json"
fi
printf '%s' "$missing_out" | grep -q "No zttp.json found" || fail "missing-project diagnostic did not mention zttp.json: $missing_out"

step "negative: dev rejects a bad serve flag by its own name before analysis"
# The handler path does not exist: if analysis ran first, the output would be
# the preflight "handler not found" text instead of the flag message.
dev_flag_status=0
dev_flag_out=$(cd "$TMP_DIR/no-project" && "$ZTTP" dev -p abc missing-handler.ts 2>&1 </dev/null) || dev_flag_status=$?
[ "$dev_flag_status" -eq 1 ] || fail "dev -p abc exited $dev_flag_status, expected 1: $dev_flag_out"
dev_flag_want='zttp dev: the port must be a whole number from 0 to 65535 (-p, --port). Run `zttp dev --help` for usage.'
[ "$dev_flag_out" = "$dev_flag_want" ] || fail "dev -p abc printed unexpected text: $dev_flag_out"

step "negative: help for an unknown command is an error"
help_status=0
help_out=$("$ZTTP" help bogus 2>&1 </dev/null) || help_status=$?
[ "$help_status" -eq 1 ] || fail "help bogus exited $help_status, expected 1: $help_out"
help_want="zttp help: unknown command 'bogus'. Run \`zttp help --all\` to list every command."
[ "$help_out" = "$help_want" ] || fail "help bogus printed unexpected text: $help_out"
"$ZTTP" help dev >/dev/null 2>&1 </dev/null || fail "help dev should still succeed"

step "negative: broken handler build fails without emitting an artifact"
(cd "$TMP_DIR" && "$ZTTP" init "broken-app" >/dev/null 2>&1) || fail "init broken-app"
printf 'function handler(req) {\n' > "$BROKEN_APP_DIR/src/handler.ts"
if broken_out=$(cd "$BROKEN_APP_DIR" && "$ZTTP" build 2>&1); then
    fail "build succeeded for syntactically broken handler"
fi
[ ! -e "$BROKEN_APP_DIR/.zttp/build/broken-app" ] || fail "broken handler emitted a build artifact"
printf '%s' "$broken_out" | grep -Eq "Compilation failed|Parse|error" || fail "broken-handler diagnostic was not actionable: $broken_out"

step "negative: a handler with file imports names the missing certificate"
mkdir -p "$TMP_DIR/imports-app"
cp "$REPO_ROOT/examples/handler/handler-with-imports.ts" "$REPO_ROOT/examples/handler/utils.ts" "$TMP_DIR/imports-app/"
imports_status=0
imports_out=$(cd "$TMP_DIR/imports-app" && "$ZTTP" compile handler-with-imports.ts -o imports-bin --no-attest 2>&1 </dev/null) || imports_status=$?
[ "$imports_status" -eq 1 ] || fail "compile with file imports exited $imports_status, expected 1: $imports_out"
[ ! -e "$TMP_DIR/imports-app/imports-bin" ] || fail "refused compile with file imports wrote a binary"
imports_want='Build refused: the compiler builds no proof certificate for a handler with file imports; the artifact would refuse to serve.'
printf '%s\n' "$imports_out" | grep -qxF "$imports_want" || fail "compile with file imports did not name the missing certificate: $imports_out"

step "negative: two modules that bind one top-level name are refused by compile and serve"
mkdir -p "$TMP_DIR/shared-name-app"
cat > "$TMP_DIR/shared-name-app/a.ts" <<'TS'
function label(): string { return "a"; }
export function fromA(): string { return label(); }
TS
cat > "$TMP_DIR/shared-name-app/b.ts" <<'TS'
function label(): string { return "b"; }
export function fromB(): string { return label(); }
TS
cat > "$TMP_DIR/shared-name-app/h.ts" <<'TS'
import { fromA } from "./a.ts";
import { fromB } from "./b.ts";
export function handler(req: Request): Response {
  return Response.text([fromA(), fromB()].join(""));
}
TS
shared_want="Top-level name 'label' is bound in both 'a.ts' and 'b.ts'. Modules share one namespace, so rename one binding."
shared_compile_status=0
shared_compile_out=$(cd "$TMP_DIR/shared-name-app" && "$ZTTP" compile h.ts -o shared-bin --no-attest 2>&1 </dev/null) || shared_compile_status=$?
[ "$shared_compile_status" -eq 1 ] || fail "compile with a shared top-level name exited $shared_compile_status, expected 1: $shared_compile_out"
[ ! -e "$TMP_DIR/shared-name-app/shared-bin" ] || fail "refused compile with a shared top-level name wrote a binary"
grep -qxF -- "$shared_want" <<<"$shared_compile_out" || fail "compile did not name the shared top-level name: $shared_compile_out"
shared_serve_status=0
shared_serve_out=$(cd "$TMP_DIR/shared-name-app" && perl -e 'alarm 60; exec @ARGV' "$ZTTP" serve h.ts -p 0 2>&1 </dev/null) || shared_serve_status=$?
[ "$shared_serve_status" -eq 1 ] || fail "serve with a shared top-level name exited $shared_serve_status, expected 1: $shared_serve_out"
grep -qxF -- "$shared_want" <<<"$shared_serve_out" || fail "serve did not name the shared top-level name: $shared_serve_out"

step "negative: a defect in a dependency is refused by compile for each check"
mkdir -p "$TMP_DIR/dep-check-app"
cat > "$TMP_DIR/dep-check-app/h.ts" <<'TS'
import { value } from "./dep.ts";
export function handler(req: Request): Response {
  return Response.text(String(value()));
}
TS
dep_check_case() {
  dep_name="$1"
  dep_want="$2"
  dep_status=0
  dep_out=$(cd "$TMP_DIR/dep-check-app" && "$ZTTP" compile h.ts -o "dep-bin-$dep_name" --no-attest 2>&1 </dev/null) || dep_status=$?
  [ "$dep_status" -eq 1 ] || fail "compile with a $dep_name defect in a dependency exited $dep_status, expected 1: $dep_out"
  [ ! -e "$TMP_DIR/dep-check-app/dep-bin-$dep_name" ] || fail "refused compile with a $dep_name defect in a dependency wrote a binary"
  grep -qF -- "$dep_want" <<<"$dep_out" || fail "compile with a $dep_name defect in a dependency did not print '$dep_want': $dep_out"
}
cat > "$TMP_DIR/dep-check-app/dep.ts" <<'TS'
export function value(): number {
  if (5) return 1;
  return 2;
}
TS
dep_check_case boolean "error[ZTS100]: boolean context requires a value of type boolean"
cat > "$TMP_DIR/dep-check-app/dep.ts" <<'TS'
export function value(): number {
  const wrong: number = "wrong";
  return wrong;
}
TS
dep_check_case type "type error[ZTS200]: type '\"wrong\"' is not assignable to type 'number'"
cat > "$TMP_DIR/dep-check-app/dep.ts" <<'TS'
export function value() {
  return 1;
}
TS
dep_check_case strict "strict error[ZTS601]: strict ZigTS requires explicit function parameter and return types"
cat > "$TMP_DIR/dep-check-app/dep.ts" <<'TS'
export const value = (): number => 1;
TS
dep_check_case canonical-export "strict error[ZTS609]: exported function-valued const should be an export function declaration"
cat > "$TMP_DIR/dep-check-app/dep.ts" <<'TS'
import { jwtVerify } from "zttp:auth";
export function value(): string {
  const result = jwtVerify("token", "secret");
  return String(result.value);
}
TS
dep_check_case verifier "verify error[ZTS303]: result.value accessed without checking result.ok first"
cat > "$TMP_DIR/dep-check-app/dep.ts" <<'TS'
import { definitelyMissing } from "zttp:sql";
export function value(): number {
  return 1;
}
TS
dep_check_case virtual-import "import error: module 'zttp:sql' does not export 'definitelyMissing'"
cat > "$TMP_DIR/dep-check-app/dep.ts" <<'TS'
assert 1 === 1, "boot";
export function value(): number {
  return 1;
}
TS
dep_check_case top-level-assert "dep.ts: a dependency may not hold a top-level assert, because a failed one leaves the later exports undefined"

step "negative: a string imported from a file is refused where a Response is declared"
mkdir -p "$TMP_DIR/import-type-app"
cat > "$TMP_DIR/import-type-app/h.ts" <<'TS'
import { greet } from "./dep.ts";
export function handler(req: Request): Proof<Response, "state_isolated"> {
  return greet();
}
TS
cat > "$TMP_DIR/import-type-app/dep.ts" <<'TS'
export function greet(): string {
  return "x";
}
TS
import_type_status=0
import_type_out=$(cd "$TMP_DIR/import-type-app" && "$ZTTP" compile h.ts -o import-type-bin --no-attest 2>&1 </dev/null) || import_type_status=$?
[ "$import_type_status" -eq 1 ] || fail "compile of a string imported from a file exited $import_type_status, expected 1: $import_type_out"
[ ! -e "$TMP_DIR/import-type-app/import-type-bin" ] || fail "refused compile of a string imported from a file wrote a binary"
grep -qF -- "type error[ZTS204]: return type does not match declared return type" <<<"$import_type_out" || fail "compile of a string imported from a file did not print the ZTS204 diagnostic: $import_type_out"
cat > "$TMP_DIR/import-type-app/dep.ts" <<'TS'
export function greet(): Response {
  return Response.text("x");
}
TS
import_type_ok_status=0
import_type_ok_out=$(cd "$TMP_DIR/import-type-app" && "$ZTTP" compile h.ts -o import-type-bin --no-attest 2>&1 </dev/null) || import_type_ok_status=$?
[ "$import_type_ok_status" -eq 1 ] || fail "compile of a Response imported from a file exited $import_type_ok_status, expected 1: $import_type_ok_out"
grep -qF -- "Build refused: the compiler builds no proof certificate for a handler with file imports" <<<"$import_type_ok_out" || fail "compile of a Response imported from a file did not reach the missing certificate refusal: $import_type_ok_out"
if grep -qF -- "ZTS204" <<<"$import_type_ok_out"; then fail "compile of a Response imported from a file printed a type error: $import_type_ok_out"; fi
cat > "$TMP_DIR/import-type-app/dep.ts" <<'TS'
export function pick<T>(value: T): T {
  return value;
}
TS
cat > "$TMP_DIR/import-type-app/h.ts" <<'TS'
import { pick } from "./dep.ts";
export function handler(req: Request): Proof<Response, "state_isolated"> {
  return Response.text(String(pick(1)));
}
TS
import_untyped_want="h.ts: import 'pick' has no type that can cross modules. Export a non-generic function or a value with a declared type."
import_untyped_status=0
import_untyped_out=$(cd "$TMP_DIR/import-type-app" && "$ZTTP" compile h.ts -o import-untyped-bin --no-attest 2>&1 </dev/null) || import_untyped_status=$?
[ "$import_untyped_status" -eq 1 ] || fail "compile of a generic function imported from a file exited $import_untyped_status, expected 1: $import_untyped_out"
[ ! -e "$TMP_DIR/import-type-app/import-untyped-bin" ] || fail "refused compile of a generic function imported from a file wrote a binary"
grep -qF -- "$import_untyped_want" <<<"$import_untyped_out" || fail "compile of a generic function imported from a file did not print '$import_untyped_want': $import_untyped_out"

step "negative: a helper mutation stops only a capsule that demands state_isolated"
mkdir -p "$TMP_DIR/helper-state-app"
cat > "$TMP_DIR/helper-state-app/demanded.ts" <<'TS'
let count = 0;
function bump(): number {
  count = count + 1;
  return count;
}
export function handler(req: Request): Proof<Response, "state_isolated"> {
  return Response.text(String(bump()));
}
TS
cat > "$TMP_DIR/helper-state-app/narrow.ts" <<'TS'
let count = 0;
function bump(): number {
  count = count + 1;
  return count;
}
export function handler(req: Request): Proof<Response, "deterministic"> {
  return Response.text(String(bump()));
}
TS
helper_status=0
helper_out=$(cd "$TMP_DIR/helper-state-app" && "$ZTTP" compile demanded.ts -o demanded-bin --no-attest 2>&1 </dev/null) || helper_status=$?
[ "$helper_status" -eq 1 ] || fail "compile of a demanded state_isolated with a mutating helper exited $helper_status, expected 1: $helper_out"
[ ! -e "$TMP_DIR/helper-state-app/demanded-bin" ] || fail "refused compile of a demanded state_isolated wrote a binary"
helper_status=0
helper_out=$(cd "$TMP_DIR/helper-state-app" && "$ZTTP" compile narrow.ts -o narrow-bin --no-attest 2>&1 </dev/null) || helper_status=$?
[ "$helper_status" -eq 0 ] || fail "compile of a capsule without state_isolated exited $helper_status, expected 0: $helper_out"
[ -x "$TMP_DIR/helper-state-app/narrow-bin" ] || fail "compile of a capsule without state_isolated wrote no binary"

step "negative: test prints each error that its summary counts"
cat > "$BROKEN_APP_DIR/src/handler.ts" <<'TS'
import { env } from "zttp:env";
structural RO<T> = Proof<T, "read_only">;
function handler(req: Request): RO<Response> {
  return Response.json({ v: env("API_TOKEN") ?? "" });
}
TS
leak_status=0
leak_out=$(cd "$BROKEN_APP_DIR" && "$ZTTP" test 2>&1 </dev/null) || leak_status=$?
[ "$leak_status" -ne 0 ] || fail "test succeeded for a handler that leaks a secret"
printf '%s' "$leak_out" | grep -q "ZTS400" || fail "test counted a flow error and did not print it: $leak_out"

step "init --extension scaffolds a handler that compiles as its README says"
(cd "$TMP_DIR" && "$ZTTP" init --extension demo-ext >/dev/null) || fail "init --extension"
(cd "$TMP_DIR/demo-ext" && "$ZTS" compile --module-manifest zttp-module.json handler.ts handler.zig >/dev/null 2>&1) ||
    fail "the extension scaffold handler did not compile"

step "init $APP_NAME under $TMP_DIR"
(cd "$TMP_DIR" && "$ZTTP" init "$APP_NAME" >/dev/null) || fail "init"
[ -f "$APP_DIR/zttp.json" ] || fail "no zttp.json after init"
[ -f "$APP_DIR/src/handler.ts" ] || fail "no src/handler.ts after init"
[ -f "$APP_DIR/tests/handler.test.jsonl" ] || fail "no tests/handler.test.jsonl after init"
[ -f "$APP_DIR/README.md" ] || fail "no README.md after init"

cd "$APP_DIR"

step "doctor"
"$ZTTP" doctor >/dev/null || fail "doctor exited non-zero"

step "check"
"$ZTTP" check >/dev/null || fail "check exited non-zero"

step "build emits .zttp/build/$APP_NAME"
run_captured "build exited non-zero" "$ZTTP" build
[ -x "$APP_DIR/.zttp/build/$APP_NAME" ] || fail "build artifact missing or not executable"

step "run build artifact on :$BUILD_PORT and curl /"
"$APP_DIR/.zttp/build/$APP_NAME" -p "$BUILD_PORT" >/dev/null 2>&1 &
BUILD_PID=$!
build_body=$(wait_for_http "http://127.0.0.1:$BUILD_PORT/" 25) || fail "build artifact did not respond on /"
[ -n "$build_body" ] || fail "build artifact returned empty body on /"
stop_bg "$BUILD_PID" "$APP_DIR/.zttp/build/$APP_NAME"

step "negative: deploy without zttp-runtime emits an install hint"
mv "$RUNTIME_BIN" "$RUNTIME_BAK"
missing_runtime_status=0
missing_runtime_out=$("$ZTTP" deploy 2>&1) || missing_runtime_status=$?
mv "$RUNTIME_BAK" "$RUNTIME_BIN"
[ "$missing_runtime_status" -ne 0 ] || fail "deploy succeeded with zttp-runtime missing"
printf '%s' "$missing_runtime_out" | grep -q "zttp-runtime template not found" || fail "missing-runtime diagnostic was not actionable: $missing_runtime_out"
[ ! -e "$APP_DIR/.zttp/deploy/$APP_NAME" ] || fail "deploy artifact was created despite missing runtime"

step "deploy emits .zttp/deploy/$APP_NAME and appends ledger row"
run_captured "deploy exited non-zero" "$ZTTP" deploy
[ -x "$APP_DIR/.zttp/deploy/$APP_NAME" ] || fail "deploy artifact missing or not executable"
[ -s "$APP_DIR/.zttp/proofs.jsonl" ] || fail "proofs.jsonl missing or empty after deploy"
grep -q '"kind":"deploy"' "$APP_DIR/.zttp/proofs.jsonl" || fail "no kind=deploy row in proofs.jsonl"

step "proofs bundle takes the deploy output and verifies with --require-proof"
run_captured "proofs bundle exited non-zero" "$ZTTP" proofs bundle --binary ".zttp/deploy/$APP_NAME" --out bundle
[ -s bundle/handler.contract.json ] || fail "bundle holds no contract"
run_captured "proofs verify --require-proof exited non-zero" "$ZTTP" proofs verify bundle --require-proof

step "negative: proofs bundle names a missing contract path"
missing_contract_status=0
missing_contract_out=$("$ZTTP" proofs bundle --contract nope.json --binary ".zttp/deploy/$APP_NAME" --out bundle2 2>&1) || missing_contract_status=$?
[ "$missing_contract_status" -eq 1 ] || fail "missing --contract exited $missing_contract_status, want 1"
printf '%s' "$missing_contract_out" | grep -q "cannot read contract 'nope.json'" || fail "missing --contract did not name the path: $missing_contract_out"
printf '%s' "$missing_contract_out" | grep -q "stack\|\.zig:" && fail "missing --contract printed a stack trace: $missing_contract_out"

step "run deploy artifact on :$DEPLOY_PORT and curl /"
"$APP_DIR/.zttp/deploy/$APP_NAME" -p "$DEPLOY_PORT" >/dev/null 2>&1 &
DEPLOY_PID=$!
deploy_body=$(wait_for_http "http://127.0.0.1:$DEPLOY_PORT/" 25) || fail "deploy artifact did not respond on /"
[ -n "$deploy_body" ] || fail "deploy artifact returned empty body on /"
stop_bg "$DEPLOY_PID" "$APP_DIR/.zttp/deploy/$APP_NAME"

step "PASS: init -> doctor -> check -> build -> deploy"
exit 0

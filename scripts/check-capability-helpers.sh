#!/bin/bash

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "Capability Helper Audit"
echo "======================="

fail=0

# Floor on this gate's own scanner. A missing rg, or one without PCRE2, would
# leave every scan below empty and report a pass. Exit status 1 from rg means
# no match and is the only status tolerated; any other status fails the gate.
command -v rg >/dev/null 2>&1 || { echo "FAIL: rg (ripgrep) is not on PATH; this gate cannot scan" >&2; exit 1; }
rg --pcre2 -q a <<<a || { echo "FAIL: rg PCRE2 self-test failed; this gate cannot scan" >&2; exit 1; }
rg_error_marker="$(mktemp)"
trap 'command rm -f "$rg_error_marker"' EXIT
export rg_error_marker

# Floor on this gate's input. BSD xargs runs nothing and exits 0 on an empty
# list, so a missing source tree would pass every scan. Measured 2026-10-23: 33
# Zig files under the two roots.
minimum_files=30
file_count="$(git ls-files -- 'packages/modules/src' 'packages/zts/src/modules' | grep -c '\.zig$' || true)"
if [ "$file_count" -lt "$minimum_files" ]; then
    echo "FAIL: found $file_count Zig files to scan; the floor is $minimum_files" >&2
    exit 1
fi

check_pattern() {
    local description="$1"
    local pattern="$2"
    local matches

    matches="$(git ls-files -z -- 'packages/modules/src' 'packages/zts/src/modules' | xargs -0 bash -c 'rg "$@"; status=$?; if [ "$status" -gt 1 ]; then echo "rg exited with status $status" >> "$rg_error_marker"; fi; exit 0' rg_scan -n -H --color never -g '*.zig' "$pattern")"
    if [ -s "$rg_error_marker" ]; then
        echo "FAIL: rg errored while scanning for: $description" >&2
        cat "$rg_error_marker" >&2
        exit 1
    fi
    if [ -n "$matches" ]; then
        echo ""
        echo "FAIL: $description"
        echo "$matches"
        fail=1
    fi
}

check_pattern "direct runtime policy access in virtual modules" 'capability_policy\.'
check_pattern "direct environment reads in virtual modules" 'std\.c\.getenv'
check_pattern "direct filesystem reads in virtual modules" 'file_io\.readFile'
check_pattern "direct SQLite opens in virtual modules" 'Db\.openReadWriteCreate'
check_pattern "direct clock access in virtual modules" 'compat\.realtimeNow(Ms|Ns)'
check_pattern "direct stderr writes in virtual modules" 'std\.c\.write\('
check_pattern "direct HMAC creation in virtual modules" 'HmacSha256\.create'
check_pattern "direct SHA-256 hashing in virtual modules" 'Sha256\.init'
check_pattern "direct callback/sql/websocket state access in virtual modules" 'ctx\.getModuleState\((IoCallbacks|DurableCallbacks|SqlStore|WebSocketCallbacks)'

if [ "$fail" -ne 0 ]; then
    echo ""
    echo "Use shared checked helpers in packages/zts/src/module_binding.zig instead of direct sensitive operations."
    exit 1
fi

echo "PASS: no direct sensitive operations found in packages/modules/src/ or packages/zts/src/modules/"

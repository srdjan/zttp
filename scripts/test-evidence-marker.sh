#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/zttp-evidence-marker.XXXXXX")"
cleanup() {
  rm -rf "$test_tmp"
}
trap cleanup EXIT HUP INT TERM

export ZTTP_EVIDENCE_TEST_LOG="$test_tmp/replay.log"
export ZTTP_EVIDENCE_EXTRACTOR="$PWD/scripts/extract-evidence-marker.py"

checks="$(python3 <<'PY'
import copy
import json
import os
import subprocess

log_path = os.environ["ZTTP_EVIDENCE_TEST_LOG"]
extractor = os.environ["ZTTP_EVIDENCE_EXTRACTOR"]
marker = "[test-evidence] "
digest = "a" * 64

common = {
    "runId": "run-1",
    "complete": True,
    "publishable": True,
    "publicationMode": True,
    "expectedCases": 19,
    "completedCases": 19,
    "corpusCases": 19,
    "provider": "deepseek",
    "model": "deepseek-chat",
    "modelRevision": None,
    "providerRuntime": None,
    "requestPolicy": {
        "maxOutputTokens": 8192,
        "reserveTokens": 32768,
        "stream": False,
        "purpose": "normal",
        "cachePolicy": "enabled",
    },
    "providerToolCount": 12,
    "providerToolBytes": 4096,
    "corpusVersion": digest,
    "headlineInputHash": digest,
    "intentSuiteHash": digest,
    "securityProbeHash": digest,
    "thresholdHash": digest,
    "manifestHash": digest,
    "resultRunHash": digest,
    "promptPersonaHash": digest,
    "providerNeutralCatalogHash": digest,
    "providerSerializedCatalogHash": digest,
    "schemaHash": digest,
    "metaHash": digest,
    "grammarHash": digest,
    "semanticsHash": digest,
    "diagnosticHash": digest,
    "policyHash": digest,
    "sourceCommit": "b" * 40,
    "sourceDirty": True,
}

convergence = common | {
    "rawFirstDraftPassPercent": 73,
    "rawFirstDraftPasses": 14,
    "firstAttemptGreenPercent": 78,
    "firstAttemptGreens": 15,
    "finalGreenPercent": 100,
    "finalGreens": 19,
    "medianRoundtrips": 4,
    "intentPassPercent": 100,
    "intentPasses": 18,
    "intentChecked": 18,
    "emptyResponses": 0,
    "timeoutFailures": 0,
    "decodeFailures": 0,
}
coverage = common | {
    "rulesTotal": 3,
    "rulesTripped": 2,
    "tripped": ["ZTS001", "ZTS002"],
    "untripped": ["ZTS003"],
    "offRegistry": ["ZTS900"],
}

checks = 0


def invoke(kind, payload, expected_ok, lines=1):
    global checks
    encoded = json.dumps(payload, separators=(",", ":"))
    with open(log_path, "w", encoding="utf-8") as log:
        for _ in range(lines):
            log.write(marker + encoded + "\n")
    result = subprocess.run(
        ["python3", extractor, log_path, marker, kind],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if (result.returncode == 0) != expected_ok:
        raise SystemExit(f"{kind} fixture expectation failed: {payload}")
    checks += 1


invoke("convergence", convergence, True)
invoke("coverage", coverage, True)
invoke("convergence", convergence, False, lines=2)

with open(log_path, "w", encoding="utf-8") as log:
    log.write("ordinary test output\n")
missing = subprocess.run(
    ["python3", extractor, log_path, marker, "convergence"],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    check=False,
)
if missing.returncode == 0:
    raise SystemExit("missing marker unexpectedly passed")
checks += 1

for kind, valid in (("convergence", convergence), ("coverage", coverage)):
    for field in valid:
        deleted = copy.deepcopy(valid)
        del deleted[field]
        invoke(kind, deleted, False)
    extra = copy.deepcopy(valid)
    extra["unknown"] = True
    invoke(kind, extra, False)

mutations = []
for field in (
    "corpusVersion",
    "headlineInputHash",
    "intentSuiteHash",
    "securityProbeHash",
    "thresholdHash",
    "manifestHash",
    "resultRunHash",
    "promptPersonaHash",
    "providerNeutralCatalogHash",
    "providerSerializedCatalogHash",
    "schemaHash",
    "metaHash",
    "grammarHash",
    "semanticsHash",
    "diagnosticHash",
    "policyHash",
):
    mutations.append((field, "not-a-digest"))
mutations.extend(
    [
        ("complete", False),
        ("publishable", False),
        ("publicationMode", False),
        ("expectedCases", 0),
        ("completedCases", 18),
        ("corpusCases", "19"),
        ("provider", ""),
        ("model", ""),
        ("modelRevision", ""),
        ("providerRuntime", {"name": "mlx-lm"}),
        ("requestPolicy", {}),
        ("providerToolCount", 0),
        ("providerToolBytes", 0),
        ("sourceCommit", "unknown"),
        ("sourceDirty", "yes"),
    ]
)
for field, value in mutations:
    changed = copy.deepcopy(convergence)
    changed[field] = value
    invoke("convergence", changed, False)

for field, value in (
    ("rawFirstDraftPasses", 16),
    ("rawFirstDraftPassPercent", 74),
    ("firstAttemptGreens", 13),
    ("firstAttemptGreenPercent", 79),
    ("finalGreens", 14),
    ("finalGreenPercent", 99),
    ("medianRoundtrips", 0),
    ("intentPasses", 14),
    ("intentChecked", 12),
    ("intentPassPercent", 99),
    ("emptyResponses", 1),
    ("timeoutFailures", 1),
    ("decodeFailures", 1),
):
    changed = copy.deepcopy(convergence)
    changed[field] = value
    invoke("convergence", changed, False)

for updates in (
    {"rawFirstDraftPasses": 13, "rawFirstDraftPassPercent": 68},
    {"finalGreens": 18, "finalGreenPercent": 94},
    {"medianRoundtrips": 5},
    {"intentPasses": 17, "intentChecked": 18, "intentPassPercent": 94},
    {"intentPasses": 17, "intentChecked": 17, "intentPassPercent": 100},
):
    changed = copy.deepcopy(convergence)
    changed.update(updates)
    invoke("convergence", changed, False)

for field, value in (
    ("rulesTotal", 0),
    ("rulesTripped", 0),
    ("rulesTripped", 1),
    ("tripped", ["ZTS001", "ZTS001"]),
    ("untripped", ["ZTS002"]),
    ("offRegistry", ["ZTS001"]),
):
    changed = copy.deepcopy(coverage)
    changed[field] = value
    invoke("coverage", changed, False)

with open(log_path, "w", encoding="utf-8") as log:
    log.write(marker + "{\n")
malformed = subprocess.run(
    ["python3", extractor, log_path, marker, "convergence"],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    check=False,
)
if malformed.returncode == 0:
    raise SystemExit("malformed JSON unexpectedly passed")
checks += 1

unknown = subprocess.run(
    ["python3", extractor, log_path, marker, "unknown"],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    check=False,
)
if unknown.returncode == 0:
    raise SystemExit("unknown evidence kind unexpectedly passed")
checks += 1

print(checks)
PY
)"

log="$ZTTP_EVIDENCE_TEST_LOG"
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

printf 'evidence marker tests OK: %s checks\n' "$checks"

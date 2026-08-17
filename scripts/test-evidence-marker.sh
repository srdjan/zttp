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

# A measured result publishes whatever it says. Each of these was refused by a
# threshold on the number being published, and each is a value a real run
# produced: across four recorded runs greens ranged 16 to 18, raw 10 to 12,
# intent 15 to 18, and the median was 5 every time. The row already on
# docs/convergence.md - 9 raw, median 5 - was refused by the same thresholds.
for updates in (
    {"rawFirstDraftPasses": 10, "rawFirstDraftPassPercent": 52},
    {"finalGreens": 16, "finalGreenPercent": 84},
    {"medianRoundtrips": 5},
    {"intentPasses": 15, "intentChecked": 18, "intentPassPercent": 83},
):
    changed = copy.deepcopy(convergence)
    changed.update(updates)
    invoke("convergence", changed, True)

# An intent check that never ran is still refused: it is the denominator of the
# published intent rate, so a short count inflates the number rather than
# lowering it.
changed = copy.deepcopy(convergence)
changed.update({"intentPasses": 17, "intentChecked": 17, "intentPassPercent": 100})
invoke("convergence", changed, False)

# All 18 checks ran and all 18 failed. The denominator is intact, so every gate
# above was satisfied and the page published intentPassPercent: 0 as a property
# of the model. Nineteen veto-accepted handlers, none of which does what its
# prompt asked, is a harness fault; so is zero green out of nineteen.
changed = copy.deepcopy(convergence)
changed.update({"intentPasses": 0, "intentChecked": 18, "intentPassPercent": 0})
invoke("convergence", changed, False)
changed = copy.deepcopy(convergence)
changed.update(
    {
        "rawFirstDraftPasses": 0,
        "rawFirstDraftPassPercent": 0,
        "firstAttemptGreens": 0,
        "firstAttemptGreenPercent": 0,
        "finalGreens": 0,
        "finalGreenPercent": 0,
    }
)
invoke("convergence", changed, False)

# And the floors sit below the worst real run, so neither can force a re-record
# until the numbers flatter.
changed = copy.deepcopy(convergence)
changed.update(
    {
        "rawFirstDraftPasses": 1,
        "rawFirstDraftPassPercent": 5,
        "firstAttemptGreens": 1,
        "firstAttemptGreenPercent": 5,
        "finalGreens": 1,
        "finalGreenPercent": 5,
        "intentPasses": 1,
        "intentChecked": 18,
        "intentPassPercent": 5,
    }
)
invoke("convergence", changed, True)

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

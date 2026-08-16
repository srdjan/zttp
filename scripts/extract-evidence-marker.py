#!/usr/bin/env python3
"""Extract and validate one complete evidence marker from a replay log."""

import json
import re
import sys
from typing import Any


HEX64 = re.compile(r"[0-9a-f]{64}")
HEX40 = re.compile(r"[0-9a-f]{40}")

COMMON_FIELDS = {
    "runId",
    "complete",
    "publishable",
    "publicationMode",
    "expectedCases",
    "completedCases",
    "corpusCases",
    "provider",
    "model",
    "modelRevision",
    "providerRuntime",
    "requestPolicy",
    "providerToolCount",
    "providerToolBytes",
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
    "sourceCommit",
    "sourceDirty",
}

DIGEST_FIELDS = {
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
}

CONVERGENCE_FIELDS = {
    "rawFirstDraftPassPercent",
    "rawFirstDraftPasses",
    "firstAttemptGreenPercent",
    "firstAttemptGreens",
    "finalGreenPercent",
    "finalGreens",
    "medianRoundtrips",
    "intentPassPercent",
    "intentPasses",
    "intentChecked",
    "emptyResponses",
    "timeoutFailures",
    "decodeFailures",
}

COVERAGE_FIELDS = {
    "rulesTotal",
    "rulesTripped",
    "tripped",
    "untripped",
    "offRegistry",
}


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def require_exact_fields(payload: dict[str, Any], expected: set[str], kind: str) -> None:
    missing = sorted(expected - payload.keys())
    if missing:
        fail(f"incomplete {kind} marker; missing {', '.join(missing)}")
    extra = sorted(payload.keys() - expected)
    if extra:
        fail(f"unknown {kind} marker field(s): {', '.join(extra)}")


def validate_common(payload: dict[str, Any], kind: str) -> None:
    if payload["complete"] is not True or payload["publishable"] is not True:
        fail(f"{kind} marker is not a complete publishable run")
    if payload["publicationMode"] is not True:
        fail(f"{kind} marker was not emitted for an atomic publication run")
    if not isinstance(payload["runId"], str) or not payload["runId"]:
        fail(f"{kind} marker has no runId")
    if any(
        not is_int(payload[name])
        for name in ("expectedCases", "completedCases", "corpusCases")
    ):
        fail(f"{kind} marker case counts must be integers")
    counts = tuple(
        payload[name] for name in ("expectedCases", "completedCases", "corpusCases")
    )
    if counts != (19, 19, 19):
        fail(f"{kind} marker case floor is {counts}, expected (19, 19, 19)")

    for name in ("provider", "model"):
        if not isinstance(payload[name], str) or not payload[name]:
            fail(f"{kind} marker has no {name} identity")
    model_revision = payload["modelRevision"]
    if model_revision is not None and (
        not isinstance(model_revision, str) or not model_revision
    ):
        fail(f"{kind} marker has an invalid modelRevision")

    provider_runtime = payload["providerRuntime"]
    if provider_runtime is not None:
        if not isinstance(provider_runtime, dict) or set(provider_runtime) != {
            "name",
            "revision",
        }:
            fail(f"{kind} marker has an invalid providerRuntime")
        if any(
            not isinstance(provider_runtime[name], str) or not provider_runtime[name]
            for name in ("name", "revision")
        ):
            fail(f"{kind} marker has an empty providerRuntime identity")

    policy = payload["requestPolicy"]
    if not isinstance(policy, dict) or set(policy) != {
        "maxOutputTokens",
        "reserveTokens",
        "stream",
        "purpose",
        "cachePolicy",
    }:
        fail(f"{kind} marker has an invalid requestPolicy")
    if not is_int(policy["maxOutputTokens"]) or policy["maxOutputTokens"] <= 0:
        fail(f"{kind} marker has an invalid maxOutputTokens")
    if not is_int(policy["reserveTokens"]) or policy["reserveTokens"] <= 0:
        fail(f"{kind} marker has an invalid reserveTokens")
    if not isinstance(policy["stream"], bool):
        fail(f"{kind} marker has a non-boolean stream policy")
    if policy["purpose"] not in {"normal", "summarization"}:
        fail(f"{kind} marker has an unknown request purpose")
    if policy["cachePolicy"] not in {"enabled", "disabled"}:
        fail(f"{kind} marker has an unknown cache policy")

    for name in ("providerToolCount", "providerToolBytes"):
        if not is_int(payload[name]) or payload[name] <= 0:
            fail(f"{kind} marker has an empty {name}")
    for name in DIGEST_FIELDS:
        value = payload[name]
        if not isinstance(value, str) or HEX64.fullmatch(value) is None:
            fail(f"{kind} marker has an invalid {name}")
    if payload["corpusVersion"] != payload["headlineInputHash"]:
        fail(f"{kind} marker corpusVersion is not its headlineInputHash")
    if not isinstance(payload["sourceCommit"], str) or HEX40.fullmatch(
        payload["sourceCommit"]
    ) is None:
        fail(f"{kind} marker has an invalid sourceCommit")
    if not isinstance(payload["sourceDirty"], bool):
        fail(f"{kind} marker has a non-boolean sourceDirty state")


def validate_convergence(payload: dict[str, Any]) -> None:
    for name in CONVERGENCE_FIELDS:
        if not is_int(payload[name]) or payload[name] < 0:
            fail(f"convergence marker has an invalid {name}")

    raw = payload["rawFirstDraftPasses"]
    assisted = payload["firstAttemptGreens"]
    final = payload["finalGreens"]
    if not 0 <= raw <= assisted <= final <= 19:
        fail("convergence marker draft/final counts are inconsistent")
    for count_name, percent_name in (
        ("rawFirstDraftPasses", "rawFirstDraftPassPercent"),
        ("firstAttemptGreens", "firstAttemptGreenPercent"),
        ("finalGreens", "finalGreenPercent"),
    ):
        if payload[percent_name] != payload[count_name] * 100 // 19:
            fail(f"convergence marker {percent_name} disagrees with its count")

    checked = payload["intentChecked"]
    passed = payload["intentPasses"]
    if not 0 <= passed <= checked <= 19:
        fail("convergence marker intent counts are inconsistent")
    expected_intent_percent = 0 if checked == 0 else passed * 100 // checked
    if payload["intentPassPercent"] != expected_intent_percent:
        fail("convergence marker intentPassPercent disagrees with its count")
    if payload["medianRoundtrips"] <= 0:
        fail("convergence marker has no round-trip sample")
    for name in ("emptyResponses", "timeoutFailures", "decodeFailures"):
        if payload[name] != 0:
            fail(f"publishable convergence marker reports {name}")


def validated_code_set(payload: dict[str, Any], name: str) -> set[str]:
    value = payload[name]
    if not isinstance(value, list) or any(
        not isinstance(code, str) or not code for code in value
    ):
        fail(f"coverage marker has an invalid {name} array")
    codes = set(value)
    if len(codes) != len(value):
        fail(f"coverage marker has duplicate codes in {name}")
    return codes


def validate_coverage(payload: dict[str, Any]) -> None:
    for name in ("rulesTotal", "rulesTripped"):
        if not is_int(payload[name]) or payload[name] <= 0:
            fail(f"coverage marker has an invalid {name}")
    tripped = validated_code_set(payload, "tripped")
    untripped = validated_code_set(payload, "untripped")
    off_registry = validated_code_set(payload, "offRegistry")
    if payload["rulesTripped"] != len(tripped):
        fail("coverage marker rulesTripped disagrees with tripped")
    if payload["rulesTotal"] != len(tripped) + len(untripped):
        fail("coverage marker rulesTotal disagrees with its partition")
    if tripped & untripped:
        fail("coverage marker registry partition overlaps")
    if off_registry & (tripped | untripped):
        fail("coverage marker offRegistry overlaps the registry")


def main() -> None:
    if len(sys.argv) != 4:
        fail("usage: extract-evidence-marker.py <log> <marker> <kind>")

    log_path, marker, kind = sys.argv[1:]
    if kind not in {"convergence", "coverage"}:
        fail(f"unknown evidence kind {kind!r}")

    payloads: list[str] = []
    with open(log_path, encoding="utf-8") as replay_log:
        for line in replay_log:
            marker_at = line.find(marker)
            if marker_at >= 0:
                payloads.append(line[marker_at + len(marker) :].strip())

    if len(payloads) != 1:
        fail(f"expected exactly one {marker.strip()} marker, found {len(payloads)}")

    try:
        payload = json.loads(payloads[0])
    except json.JSONDecodeError as error:
        fail(f"{marker.strip()} marker is not JSON: {error.msg}")
    if not isinstance(payload, dict):
        fail(f"{marker.strip()} marker must be a JSON object")

    kind_fields = CONVERGENCE_FIELDS if kind == "convergence" else COVERAGE_FIELDS
    require_exact_fields(payload, COMMON_FIELDS | kind_fields, kind)
    validate_common(payload, kind)
    if kind == "convergence":
        validate_convergence(payload)
    else:
        validate_coverage(payload)

    print(json.dumps(payload, separators=(",", ":")))


if __name__ == "__main__":
    main()

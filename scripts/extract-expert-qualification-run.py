#!/usr/bin/env python3
"""Extract one complete report-only expert qualification run from a build log."""

import json
import sys
from typing import Any


MARKER = "[expert-qualification-run] "

RUN_FIELDS = {
    "schema_version",
    "run_id",
    "result_run_hash",
    "complete",
    "filtered",
    "report_only",
    "default_change_authorized",
    "identity",
    "source",
    "limits",
    "local_provenance",
    "cases",
    "summary",
}

IDENTITY_FIELDS = {
    "provider",
    "model",
    "model_revision",
    "provider_runtime",
    "request_policy",
    "provider_tool_count",
    "provider_tool_bytes",
    "headline_input_hash",
    "intent_suite_hash",
    "security_probe_hash",
    "threshold_hash",
    "manifest_hash",
    "prompt_persona_hash",
    "provider_neutral_catalog_hash",
    "provider_serialized_catalog_hash",
    "schema_hash",
    "meta_hash",
    "grammar_hash",
    "semantics_hash",
    "diagnostic_hash",
    "policy_hash",
}

CASE_FIELDS = {
    "name",
    "artifact_identity",
    "draft_quality",
    "applied",
    "intent",
    "roundtrips",
    "wall_clock_ms",
    "failures",
    "error_names",
    "draft_failure",
}

SUMMARY_FIELDS = {
    "expected_cases",
    "completed_cases",
    "artifact_cases",
    "raw_first_draft_passes",
    "first_attempt_greens",
    "final_greens",
    "intent_passes",
    "intent_checked",
    "median_roundtrips",
    "empty_responses",
    "timeout_failures",
    "decode_failures",
    "provider_failures",
    "intent_failures",
    "validation_failures",
    "internal_failures",
    "wall_clock_ms",
}


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def exact_fields(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    missing = sorted(expected - value.keys())
    extra = sorted(value.keys() - expected)
    if missing:
        fail(f"{label} is missing {', '.join(missing)}")
    if extra:
        fail(f"{label} has unknown fields {', '.join(extra)}")
    return value


def validate(payload: Any) -> dict[str, Any]:
    run = exact_fields(payload, RUN_FIELDS, "qualification run")
    if run["schema_version"] != 1:
        fail("qualification run has an unsupported schema")
    if run["complete"] is not True or run["filtered"] is not False:
        fail("qualification run is incomplete or filtered")
    if run["report_only"] is not True or run["default_change_authorized"] is not False:
        fail("qualification run is not report-only")
    if not isinstance(run["run_id"], str) or not run["run_id"]:
        fail("qualification run has no run id")

    exact_fields(run["identity"], IDENTITY_FIELDS, "qualification identity")
    exact_fields(run["source"], {"commit", "dirty", "known"}, "source identity")
    exact_fields(
        run["limits"],
        {
            "turn_timeout_ms",
            "max_model_roundtrips_per_turn",
            "max_tool_calls_per_turn",
        },
        "request limits",
    )
    summary = exact_fields(run["summary"], SUMMARY_FIELDS, "qualification summary")
    if (summary["expected_cases"], summary["completed_cases"]) != (19, 19):
        fail("qualification summary does not carry the 19-case floor")

    cases = run["cases"]
    if not isinstance(cases, list) or len(cases) != 19:
        fail("qualification run must carry exactly 19 case records")
    names: set[str] = set()
    for index, raw_case in enumerate(cases):
        case = exact_fields(raw_case, CASE_FIELDS, f"case {index + 1}")
        name = case["name"]
        if not isinstance(name, str) or not name or name in names:
            fail("qualification case names must be nonempty and unique")
        names.add(name)
        if not isinstance(case["failures"], list) or not isinstance(case["error_names"], list):
            fail(f"case {name} has malformed failure evidence")
        if len(case["failures"]) != len(case["error_names"]):
            fail(f"case {name} failure evidence is not paired")
    return run


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: extract-expert-qualification-run.py <build-log>")

    payloads: list[str] = []
    with open(sys.argv[1], encoding="utf-8") as log:
        for line in log:
            marker_at = line.find(MARKER)
            if marker_at >= 0:
                payloads.append(line[marker_at + len(MARKER) :].strip())
    if len(payloads) != 1:
        fail(f"expected exactly one qualification marker, found {len(payloads)}")
    try:
        payload = json.loads(payloads[0])
    except json.JSONDecodeError as error:
        fail(f"qualification marker is not JSON: {error.msg}")
    print(json.dumps(validate(payload), separators=(",", ":")))


if __name__ == "__main__":
    main()

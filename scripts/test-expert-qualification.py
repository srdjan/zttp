#!/usr/bin/env python3
"""Boundary tests for the live qualification marker extractor."""

import copy
import importlib.util
import sys
from pathlib import Path


sys.dont_write_bytecode = True


SCRIPT = Path(__file__).with_name("extract-expert-qualification-run.py")
SPEC = importlib.util.spec_from_file_location("expert_qualification_extractor", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("cannot load qualification extractor")
extractor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(extractor)


def fixture() -> dict:
    identity = {field: "value" for field in extractor.IDENTITY_FIELDS}
    identity.update(
        {
            "model_revision": None,
            "provider_runtime": None,
            "request_policy": {},
            "provider_tool_count": 21,
            "provider_tool_bytes": 11775,
        }
    )
    cases = []
    for index in range(19):
        cases.append(
            {
                "name": f"case-{index + 1}",
                "artifact_identity": None,
                "draft_quality": "not_green",
                "applied": False,
                "intent": "not_checked",
                "roundtrips": 0,
                "wall_clock_ms": 1,
                "failures": ["empty_response"],
                "error_names": ["EmptyResponse"],
                "draft_failure": None,
            }
        )
    summary = {field: 0 for field in extractor.SUMMARY_FIELDS}
    summary.update({"expected_cases": 19, "completed_cases": 19})
    return {
        "schema_version": 1,
        "run_id": "run-1",
        "result_run_hash": "a" * 64,
        "complete": True,
        "filtered": False,
        "report_only": True,
        "default_change_authorized": False,
        "identity": identity,
        "source": {"commit": "b" * 40, "dirty": False, "known": True},
        "limits": {
            "turn_timeout_ms": 180000,
            "max_model_roundtrips_per_turn": 18,
            "max_tool_calls_per_turn": 16,
        },
        "local_provenance": None,
        "cases": cases,
        "summary": summary,
    }


checks = 0


def expect_valid(payload: dict) -> None:
    global checks
    extractor.validate(payload)
    checks += 1


def expect_invalid(payload: dict) -> None:
    global checks
    try:
        extractor.validate(payload)
    except SystemExit:
        checks += 1
        return
    raise SystemExit("invalid qualification fixture unexpectedly passed")


valid = fixture()
expect_valid(valid)

changed = copy.deepcopy(valid)
changed["filtered"] = True
expect_invalid(changed)

changed = copy.deepcopy(valid)
changed["unknown"] = True
expect_invalid(changed)

changed = copy.deepcopy(valid)
changed["cases"].pop()
changed["summary"]["completed_cases"] = 18
expect_invalid(changed)

changed = copy.deepcopy(valid)
changed["cases"][1]["name"] = changed["cases"][0]["name"]
expect_invalid(changed)

changed = copy.deepcopy(valid)
changed["cases"][0]["error_names"] = []
expect_invalid(changed)

print(f"expert qualification marker OK: {checks} boundary checks")

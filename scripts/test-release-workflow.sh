#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - .github/workflows/release.yml <<'PY'
from pathlib import Path
import sys

workflow = Path(sys.argv[1])


def find_job(lines: list[str], name: str) -> list[str]:
    marker = f"  {name}:"
    try:
        start = lines.index(marker)
    except ValueError:
        raise SystemExit(f"release workflow: missing {name} job") from None

    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.startswith("  ") and not line.startswith("    ") and line.endswith(":"):
            end = index
            break
    return lines[start:end]


def split_steps(lines: list[str]) -> list[list[str]]:
    steps: list[list[str]] = []
    current: list[str] = []

    for line in lines:
        if line.startswith("      - "):
            if current:
                steps.append(current)
            current = [line]
        elif current:
            current.append(line)
    if current:
        steps.append(current)
    return steps


def validate(lines: list[str]) -> None:
    test_job = find_job(lines, "test")
    os_rows = [line for line in test_job if line.startswith("        os: [")]
    if len(os_rows) != 1:
        raise SystemExit("release workflow: expected one test matrix os row")
    matrix_os = {
        value.strip().strip("'\"")
        for value in os_rows[0].split("[", 1)[1].rsplit("]", 1)[0].split(",")
    }
    if "macos-latest" not in matrix_os:
        raise SystemExit("release workflow: test matrix must include macos-latest")

    benchmark_steps = [
        step
        for step in split_steps(test_job)
        if "        run: zig build bench-check" in step
    ]
    if len(benchmark_steps) != 1:
        raise SystemExit(
            "release workflow: expected exactly one zig build bench-check step"
        )

    benchmark_step = benchmark_steps[0]
    if "        if: ${{ matrix.os == 'macos-latest' }}" not in benchmark_step:
        raise SystemExit(
            "release workflow: advisory bench-check must run on macos-latest"
        )

    if "        continue-on-error: true" not in benchmark_step:
        raise SystemExit(
            "release workflow: machine-local bench-check must be advisory"
        )


# An unnamed step must not inherit continue-on-error from the named step before
# it. This fixture covers the false pass that a name-only step splitter permits.
unnamed_blocking_fixture = """
jobs:
  test:
    strategy:
      matrix:
        os: [macos-latest, ubuntu-latest]
    steps:
      - name: Earlier advisory step
        continue-on-error: true
        run: true
      - id: benchmark
        if: ${{ matrix.os == 'macos-latest' }}
        run: zig build bench-check
""".splitlines()
try:
    validate(unnamed_blocking_fixture)
except SystemExit as error:
    if str(error) != "release workflow: machine-local bench-check must be advisory":
        raise
else:
    raise SystemExit("release workflow: unnamed blocking benchmark fixture passed")

# Keeping the step advisory is insufficient if an always-false condition can
# silently disable the measurement.
disabled_fixture = """
jobs:
  test:
    strategy:
      matrix:
        os: [macos-latest, ubuntu-latest]
    steps:
      - name: Disabled benchmark
        if: false
        continue-on-error: true
        run: zig build bench-check
""".splitlines()
try:
    validate(disabled_fixture)
except SystemExit as error:
    if str(error) != "release workflow: advisory bench-check must run on macos-latest":
        raise
else:
    raise SystemExit("release workflow: disabled benchmark fixture passed")

# A macOS condition on the step is inert when the surrounding job no longer
# schedules a macOS runner.
ubuntu_only_fixture = """
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest]
    steps:
      - name: Advisory benchmark
        if: ${{ matrix.os == 'macos-latest' }}
        continue-on-error: true
        run: zig build bench-check
""".splitlines()
try:
    validate(ubuntu_only_fixture)
except SystemExit as error:
    if str(error) != "release workflow: test matrix must include macos-latest":
        raise
else:
    raise SystemExit("release workflow: ubuntu-only matrix fixture passed")

validate(workflow.read_text(encoding="utf-8").splitlines())

print("release workflow: advisory benchmark gate OK")
PY

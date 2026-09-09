#!/usr/bin/env python3
import argparse
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
from typing import Any


DEFAULT_RUN_COUNT = 5
DEFAULT_REGRESSION_PCT = 8.0
DEFAULT_GEOMEAN_PCT = 3.0
SKIP_REGRESSION_CHECK = {
    "forOfLoop",
    "httpHandler",
    "httpHandlerHeavy",
    "stringConcat",
}


class BenchmarkError(Exception):
    pass


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def command_output(command: list[str], cwd: Path | None = None) -> str:
    completed = subprocess.run(command, cwd=cwd, check=False, text=True, capture_output=True)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"exit {completed.returncode}"
        raise BenchmarkError(f"command failed: {' '.join(command)}: {detail}")
    return completed.stdout.strip()


def benchmark_entries(report: dict[str, Any], label: str) -> dict[str, dict[str, Any]]:
    raw_entries = report.get("benchmarks")
    if not isinstance(raw_entries, list) or not raw_entries:
        raise BenchmarkError(f"{label}: no benchmark entries found")

    entries: dict[str, dict[str, Any]] = {}
    for raw_entry in raw_entries:
        if not isinstance(raw_entry, dict):
            raise BenchmarkError(f"{label}: benchmark entry is not an object")
        name = raw_entry.get("name")
        if not isinstance(name, str) or not name:
            raise BenchmarkError(f"{label}: benchmark entry missing name")
        if name in entries:
            raise BenchmarkError(f"{label}: duplicate benchmark {name}")
        if raw_entry.get("success") is not True:
            raise BenchmarkError(f"{label}: benchmark {name} failed ({raw_entry.get('error')})")
        ops = raw_entry.get("ops_per_sec")
        if isinstance(ops, bool) or not isinstance(ops, (int, float)):
            raise BenchmarkError(f"{label}: benchmark {name} missing ops_per_sec")
        if not math.isfinite(float(ops)) or ops <= 0:
            raise BenchmarkError(f"{label}: benchmark {name} has non-positive ops_per_sec")
        entries[name] = raw_entry
    return entries


def sample_benchmarks(bench_exe: Path, run_count: int = DEFAULT_RUN_COUNT) -> dict[str, Any]:
    if run_count <= 0:
        raise BenchmarkError("run count must be positive")

    first_report: dict[str, Any] | None = None
    first_order: list[str] = []
    best: dict[str, dict[str, Any]] = {}
    expected_names: set[str] | None = None

    for run_index in range(1, run_count + 1):
        try:
            completed = subprocess.run(
                [str(bench_exe), "--json", "--quiet"],
                check=False,
                text=True,
                capture_output=True,
            )
        except OSError as error:
            raise BenchmarkError(f"bench binary not executable: {bench_exe}: {error}") from error
        if completed.returncode != 0:
            detail = completed.stderr.strip() or f"exit {completed.returncode}"
            raise BenchmarkError(f"benchmark run {run_index} failed: {detail}")
        try:
            report = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise BenchmarkError(f"benchmark run {run_index} returned invalid JSON: {error}") from error
        if not isinstance(report, dict):
            raise BenchmarkError(f"benchmark run {run_index}: report is not an object")

        entries = benchmark_entries(report, f"benchmark run {run_index}")
        names = set(entries)
        if expected_names is None:
            expected_names = names
            first_report = report
            first_order = list(entries)
        elif names != expected_names:
            raise BenchmarkError(f"benchmark run {run_index}: benchmark set differs from run 1")

        for name, entry in entries.items():
            previous = best.get(name)
            if previous is None or entry["ops_per_sec"] > previous["ops_per_sec"]:
                best[name] = dict(entry)

    if first_report is None:
        raise BenchmarkError("no benchmark runs completed")
    sampled = dict(first_report)
    sampled["benchmarks"] = [best[name] for name in first_order]
    return sampled


def compare_reports(
    current: dict[str, Any],
    baseline: dict[str, Any],
    regression_limit: float = DEFAULT_REGRESSION_PCT,
    geomean_limit: float = DEFAULT_GEOMEAN_PCT,
) -> tuple[int, float, float]:
    current_entries = benchmark_entries(current, "current")
    baseline_entries = benchmark_entries(baseline, "baseline")
    missing = sorted(set(baseline_entries) - set(current_entries))
    if missing:
        raise BenchmarkError("current: missing baseline benchmarks: " + ", ".join(missing))

    ratios: list[float] = []
    hard_failures: list[str] = []
    for name in sorted(baseline_entries):
        baseline_ops = float(baseline_entries[name]["ops_per_sec"])
        current_ops = float(current_entries[name]["ops_per_sec"])
        if name in SKIP_REGRESSION_CHECK:
            continue
        ratio = current_ops / baseline_ops
        ratios.append(ratio)
        regression_pct = max(0.0, (1.0 - ratio) * 100.0)
        if regression_pct > regression_limit:
            hard_failures.append(
                f"benchmark regression >{regression_limit:g}%: {name} "
                f"current={current_ops:.0f} baseline={baseline_ops:.0f} regression={regression_pct:.2f}%"
            )

    if hard_failures:
        raise BenchmarkError("\n".join(hard_failures))
    if not ratios:
        raise BenchmarkError("no benchmarks left after applying regression-check skip list")

    geomean = math.exp(sum(math.log(ratio) for ratio in ratios) / len(ratios))
    geomean_regression_pct = max(0.0, (1.0 - geomean) * 100.0)
    if geomean_regression_pct > geomean_limit:
        raise BenchmarkError(
            f"geomean regression >{geomean_limit:g}%: geomean={geomean:.5f} "
            f"regression={geomean_regression_pct:.2f}%"
        )
    return len(ratios), geomean, geomean_regression_pct


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, IsADirectoryError) as error:
        raise BenchmarkError(f"{label} benchmark file not found: {path}") from error
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkError(f"{label}: invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise BenchmarkError(f"{label}: report is not an object")
    return value


def ensure_clean_source(repo_root: Path) -> str:
    source_commit = command_output(["git", "rev-parse", "HEAD"], repo_root)
    status = command_output(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"], repo_root
    )
    if status:
        raise BenchmarkError("bench-record requires clean committed source")
    return source_commit


def host_provenance() -> dict[str, str]:
    processor = platform.processor()
    if platform.system() == "Darwin":
        try:
            processor = command_output(["sysctl", "-n", "machdep.cpu.brand_string"])
        except BenchmarkError:
            pass
    return {
        "os": platform.system(),
        "os_release": platform.release(),
        "architecture": platform.machine(),
        "processor": processor or "unknown",
    }


def write_json_atomically(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            json.dump(value, temporary, indent=2)
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_path, 0o644)
        os.replace(temporary_path, path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def record_baseline(
    repo_root: Path,
    baseline_path: Path,
    bench_exe: Path,
    zig_exe: Path,
    run_count: int = DEFAULT_RUN_COUNT,
) -> dict[str, Any]:
    source_commit = ensure_clean_source(repo_root)
    sampled = sample_benchmarks(bench_exe, run_count)
    if ensure_clean_source(repo_root) != source_commit:
        raise BenchmarkError("source commit changed while recording the benchmark baseline")

    zig_version = command_output([str(zig_exe), "version"], repo_root)
    recorded = {
        "schema_version": sampled.get("schema_version", 1),
        "provenance": {
            "source_commit": source_commit,
            "source_dirty": False,
            "zig_version": zig_version,
            "host": host_provenance(),
            "run_count": run_count,
            "aggregation": "per-benchmark best ops_per_sec",
        },
        "benchmarks": sampled["benchmarks"],
    }
    write_json_atomically(baseline_path, recorded)
    return recorded


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Sample, compare, and record zttp benchmarks")
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser("check", help="compare a five-run sample with the baseline")
    check.add_argument("--baseline", required=True, type=Path)
    check.add_argument("--bench", required=True, type=Path)
    check.add_argument("--runs", type=positive_int, default=positive_int(os.environ.get("BENCH_RUNS", "5")))
    check.add_argument(
        "--regression-pct",
        type=positive_float,
        default=positive_float(os.environ.get("BENCH_REGRESSION_PCT", "8.0")),
    )
    check.add_argument(
        "--geomean-pct",
        type=positive_float,
        default=positive_float(os.environ.get("BENCH_GEOMEAN_PCT", "3.0")),
    )

    record = subparsers.add_parser("record", help="atomically record a five-run baseline")
    record.add_argument("--baseline", required=True, type=Path)
    record.add_argument("--bench", required=True, type=Path)
    record.add_argument("--zig", type=Path, default=Path("zig"))
    record.add_argument("--runs", type=positive_int, default=DEFAULT_RUN_COUNT)
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    repo_root = SCRIPT_DIR.parent
    try:
        if args.command == "check":
            baseline = load_json(args.baseline, "baseline")
            current = sample_benchmarks(args.bench, args.runs)
            count, geomean, regression = compare_reports(
                current, baseline, args.regression_pct, args.geomean_pct
            )
            print(
                f"bench-check ok: compared {count} benchmarks, geomean={geomean:.5f}, "
                f"regression={regression:.2f}%"
            )
        else:
            recorded = record_baseline(repo_root, args.baseline, args.bench, args.zig, args.runs)
            provenance = recorded["provenance"]
            print(
                f"bench-record ok: recorded {len(recorded['benchmarks'])} benchmarks from "
                f"{provenance['run_count']} runs at {provenance['source_commit']}"
            )
    except BenchmarkError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


SCRIPT_DIR = Path(__file__).resolve().parent


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

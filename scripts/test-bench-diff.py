#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT_DIR = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("benchmark_tool", SCRIPT_DIR / "benchmark.py")
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load benchmark tool")
benchmark_tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark_tool)


def report(alpha_ops: int, beta_ops: int) -> dict:
    return {
        "schema_version": 1,
        "benchmarks": [
            {"name": "alpha", "success": True, "ops_per_sec": alpha_ops},
            {"name": "beta", "success": True, "ops_per_sec": beta_ops},
        ],
    }


def write_fake_benchmark(root: Path, reports: list[dict]) -> Path:
    reports_path = root / "reports.json"
    reports_path.write_text(json.dumps(reports), encoding="utf-8")
    state_path = root / ".git" / "benchmark-count" if (root / ".git").is_dir() else root / "count"
    executable = root / "fake-bench"
    executable.write_text(
        "#!/usr/bin/env python3\n"
        "import json\n"
        "from pathlib import Path\n"
        f"reports = json.loads(Path({str(reports_path)!r}).read_text())\n"
        f"state = Path({str(state_path)!r})\n"
        "count = int(state.read_text()) if state.exists() else 0\n"
        "state.write_text(str(count + 1))\n"
        "print(json.dumps(reports[count]))\n",
        encoding="utf-8",
    )
    executable.chmod(0o755)
    return executable


class BenchmarkToolTests(unittest.TestCase):
    def test_sampler_runs_five_times_and_keeps_each_benchmark_best(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            bench = write_fake_benchmark(
                root,
                [
                    report(10, 50),
                    report(20, 40),
                    report(30, 30),
                    report(40, 20),
                    report(50, 10),
                ],
            )

            sampled = benchmark_tool.sample_benchmarks(bench)

            self.assertEqual((root / "count").read_text(), "5")
            ops = {entry["name"]: entry["ops_per_sec"] for entry in sampled["benchmarks"]}
            self.assertEqual(ops, {"alpha": 50, "beta": 50})

    def test_sampler_rejects_inconsistent_benchmark_sets(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            inconsistent = report(20, 20)
            inconsistent["benchmarks"].pop()
            bench = write_fake_benchmark(
                root,
                [report(10, 10), inconsistent, report(30, 30), report(40, 40), report(50, 50)],
            )

            with self.assertRaisesRegex(benchmark_tool.BenchmarkError, "benchmark set"):
                benchmark_tool.sample_benchmarks(bench)

    def test_thresholds_and_skip_set_remain_stable(self) -> None:
        self.assertEqual(benchmark_tool.DEFAULT_RUN_COUNT, 5)
        self.assertEqual(benchmark_tool.DEFAULT_REGRESSION_PCT, 8.0)
        self.assertEqual(benchmark_tool.DEFAULT_GEOMEAN_PCT, 3.0)
        self.assertEqual(
            benchmark_tool.SKIP_REGRESSION_CHECK,
            {"forOfLoop", "httpHandler", "httpHandlerHeavy", "stringConcat"},
        )

    def test_record_requires_clean_source_and_writes_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Benchmark Test"], cwd=root, check=True)
            (root / "tracked").write_text("source\n", encoding="utf-8")
            subprocess.run(["git", "add", "tracked"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "fixture"], cwd=root, check=True)

            bench = write_fake_benchmark(root, [report(10, 10)] * 5)
            subprocess.run(["git", "add", "reports.json", "fake-bench"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "benchmark fixture"], cwd=root, check=True)
            zig = root / "zig"
            zig.write_text("#!/bin/sh\necho 0.16.0\n", encoding="utf-8")
            zig.chmod(0o755)
            subprocess.run(["git", "add", "zig"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "toolchain fixture"], cwd=root, check=True)

            baseline = root / "perf-baseline.json"
            benchmark_tool.record_baseline(root, baseline, bench, zig)
            recorded = json.loads(baseline.read_text(encoding="utf-8"))

            expected_commit = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=root, check=True, text=True, capture_output=True
            ).stdout.strip()
            self.assertEqual(recorded["provenance"]["source_commit"], expected_commit)
            self.assertFalse(recorded["provenance"]["source_dirty"])
            self.assertEqual(recorded["provenance"]["zig_version"], "0.16.0")
            self.assertEqual(recorded["provenance"]["run_count"], 5)
            self.assertEqual(recorded["provenance"]["aggregation"], "per-benchmark best ops_per_sec")

            subprocess.run(["git", "add", "perf-baseline.json"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "baseline fixture"], cwd=root, check=True)
            (root / "dirty").write_text("uncommitted\n", encoding="utf-8")
            with self.assertRaisesRegex(benchmark_tool.BenchmarkError, "clean committed source"):
                benchmark_tool.record_baseline(root, baseline, bench, zig)


if __name__ == "__main__":
    unittest.main()

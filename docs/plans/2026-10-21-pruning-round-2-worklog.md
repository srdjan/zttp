# Pruning round 2 worklog

Plan: [pruning round 2](2026-10-21-pruning-round-2-plan.md).
The owner approved implementation of U1 to U17 (decision 6, option A) on 2026-10-21 with "yes".

## Baseline

Commit `303dc3cc`, Zig 0.16.0. The tree held only the uncommitted plan file.

| Command | Exit status |
|---|---|
| `zig build test` | 0 |
| `zig build check-spine` | 0 |
| `zig build test-zruntime` | 0 |

## Units

| Unit | Commit | Gates and exit statuses | Notes |
|---|---|---|---|
| U1 | this commit | `test-capability-audit` 0, `test-docs-drift` 0, `test-examples` 0 (33 of 33 suites), `test-standin` 0, `test-step-coverage` 0, `test-script-reachability` 0, `check-spine` 0, `test` 0, `zig fmt --check` 0 | Probes in `scripts/test-gate-floors.sh` reject an unusable `rg` (three cases per script) and a zero-test suite; each probe failed against the old scripts. A renamed stand-in filter failed `test-standin` with exit status 1, then the filter was restored. The fixed-filter check sits in `Context.addTest`, so it also guards `test-expert-mlx-e2e`, which was not run (needs the operator's MLX server). |

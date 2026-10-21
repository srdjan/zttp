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
| U2 | this commit | `test-expert-app` 0, `test-standin` 0, `test-proof-swallow` 0, `check-spine` 0, `zig fmt --check` 0 | Defense in depth, not a reachable fix. No input reaches the fallback through `prove`: `normalizeCandidates` runs the same check first, and a `MissingSqlSchema` candidate is rejected there with `normalization_failed`. The list claim that A2 was reachable on the production path was wrong and is corrected. The plan's `prove`-level test cannot be built, so the two tests call `collectCheckDiagnostics` and `firstNewDiagnostic` directly. With the fix hunk removed, `test-expert-app` exited 1 with both new tests failing. Residual: a baseline that already failed full analysis accepts a candidate that fails the same way on front-end diagnostics alone. No golden pins receipt diagnostics was not checked. |
| U3 | this commit | `test-standin` 0, `test-expert-app` 0, `test-cassette` 0, `test-simulator` 0, `test-doc-links` 0, `test-docs-drift` 0, `check-spine` 0; `test-expert-mlx-e2e` compiles and exits 1 with `LocalServerUnavailable` (no MLX server; model behavior not shown) | Seed evidence now runs through `aggregate_proof.prove` with the new `test_support/prove_probe.zig`; `veto.zig` (857 lines) is deleted. Seed counts are unchanged: 61 seeds, 61/61 classes, 59 advertised = 58 seed-verified + 1 unseeded. 59 seeds match their declared code exactly through `prove`. `ceiling-never-reached` and `helper-breaks-property` reject first with ZTS306 and ZTS500; each is pinned in `pinned_first_proof_codes`, and the simulator still confirms the declared code. A stale pin fails. Probe: a wrong pinned code failed `test-standin` with exit status 1. The test "renderRich renders a proof_card payload legibly" is deleted because production builds no such payload; rich rendering of a `ui_payload` proof card is now untested. Prose that says "the real veto" in docs and comments is slightly stale and is left for U8. |

# Pruning round 3 worklog

Plan: [round 3 plan](2026-10-23-pruning-round-3-plan.md). List: [round 3 list](2026-10-23-pruning-round-3-list.md).

## Baseline

At `1fcb0734`, `zig build test` with a private cache exited 1: 9,550 of 9,556 tests passed, 6 skipped. The failed step ran `zig-out/bin/zttp` and got `FileNotFound` while the install step rewrote it. `zig build test-expert-golden` alone exited 0.

## Round 3a

| Unit | Commit | Gates and exit statuses | Notes |
|---|---|---|---|
| U0 | this commit | `test-expert-golden` 0, `test` 0, `zig fmt --check` 0 | `build/goldens.zig` now runs `getEmittedBin()` through a file argument in all five run sites. Zig 0.17 resolves an artifact argument to `installed_path` first (`lib/compiler/Maker/Step/Run.zig`, `.artifact` arm); a file argument resolves to the generated path. The race is not reproduced on demand; the evidence is the source read and one failed baseline. The `run` and `cli` steps in `build/artifacts.zig` keep `addRunArtifact`, because a user invokes them on purpose. |
| U6 | `ac972254` | `check-spine` 0, `test-kernel-safety` 0, `test-capability-audit` 0, `test-proof-swallow` 0, `test-bench-diff` 0, `test-docs-drift` 0, `test-native-gates` 0, `test-zts` 0, `test-contract-golden` 0, `test-diagnostic-corpus` 0, `test-precompile` 0, `test-script-reachability` 0, `test-expert-app` 0, `test-flow-census` 0 | H13: both scripts fail below an input floor (13 kernel files, 30 module files), probed in `test-gate-floors.sh`. H14: three files join the formatting route. H15: six files join `check-proof-swallow.sh` (28 files); 42 catch rows and 44 silent-arm markers added. `narrowTypeForPattern` now propagates OutOfMemory into the checker poison flag, and `patternCanMatchType` resolves a named member and keeps a member it cannot judge. D1: `bench-check` warns on a Zig version mismatch and does not fail. |
| U8 | this commit | `check-spine` 0, `test-docs-drift` 0, `test-doc-links` 0, `test-cli` 0, `test-expert-golden` 0, `test-canonicalize` 0, `test-proof-checker-purity` 0, `test-script-reachability` 0, `test-step-coverage` 0 | D1 to D7 as in the plan. The two Zig 0.16.0 safety claims now say "when measured on Zig 0.16.0"; the 0.17.0 behavior without the local setting was not re-measured. |

## U8 archive

Tag `pre-round-3-archive` holds the deleted files. Each line gives the file path and its line count.

- docs/plans/2026-10-14-function-value-effects-plan.md (55 lines)
- docs/plans/2026-10-18-local-release-pipeline.md (283 lines)
- docs/plans/2026-10-21-quick-fixes-plan.md (73 lines)
- docs/plans/2026-10-21-pruning-round-2-plan.md (285 lines)
- docs/plans/2026-10-22-coupling-census-plan.md (192 lines)
- docs/plans/2026-10-08-minimal-design-audit.md (281 lines)
- advisor-plans/006-modular-boundaries.md (144 lines)

The seven files total 1,313 lines. A `git grep -F` of each basename outside `docs/plans/` found no citation, except the `advisor-plans/README.md` row for plan 006. The citations inside `docs/plans/` now use the tag form.

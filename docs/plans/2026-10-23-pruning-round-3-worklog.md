# Pruning round 3 worklog

Plan: [round 3 plan](2026-10-23-pruning-round-3-plan.md). List: [round 3 list](2026-10-23-pruning-round-3-list.md).

## Baseline

At `1fcb0734`, `zig build test` with a private cache exited 1: 9,550 of 9,556 tests passed, 6 skipped. The failed step ran `zig-out/bin/zttp` and got `FileNotFound` while the install step rewrote it. `zig build test-expert-golden` alone exited 0.

## Round 3a

| Unit | Commit | Gates and exit statuses | Notes |
|---|---|---|---|
| U0 | `03c68f48` | `test-expert-golden` 0, `test` 0, `zig fmt --check` 0 | `build/goldens.zig` now runs `getEmittedBin()` through a file argument in all five run sites. Zig 0.17 resolves an artifact argument to `installed_path` first (`lib/compiler/Maker/Step/Run.zig`, `.artifact` arm); a file argument resolves to the generated path. The race is not reproduced on demand; the evidence is the source read and one failed baseline. The `run` and `cli` steps in `build/artifacts.zig` keep `addRunArtifact`, because a user invokes them on purpose. |
| U1 | `5085f2be` | `test-zts` 0, `test-diagnostic-corpus` 0, `test-zruntime` 0, `check-spine` 0 | H1: `parseNumber` hands a literal that is not an i32 to `parseExpressionNumber`, so a decimal float that fails to parse is now refused too. H6: `get` or `set` before a key refuses unless `(` follows. Both tests failed before the fix. The lead added a check that `{ get: 1, set: 2 }` still parses (`bc5a004e`). |
| U4 | `b4221c7e`, `bc5a004e` | `test-zts` 0, `test-modules` 0, `test-zruntime` 0, `test-diagnostic-corpus` 0, `check-spine` 0 | H5: `Math.PI` has its own atom; before the fix the next interned name read 3.14159 on `Math`. H17: a comptime block joins five slot literals to `module_slots.Slot` (probed with a wrong value, which failed to compile); `json_mod.limits` is `const`; every allocation in the two Result error builders propagates (the lead converted the remaining early `Err(undefined)` returns). No test drives the out-of-memory path. |
| U5 | `fd2915fc`, `e701381c` | `test-zts-cli` 0, `test-cli-abuse` 0, `test-agent-protocol` 0, `test-precompile` 0, `test-cli` 0, `test-expert-golden` 0, `test-runtime-purity` 0, `test-module-boundary` 0, `test-proof-review` 0, `test-zruntime` 0, `test-server` 0 | About 62 stdout writes in tools and runtime now fail the command. The tools helper moved to `precompile_util.writeAllFd`; no helper crosses packages. macOS has no `/dev/full`, so the new `test-cli-abuse` case uses a read-only stdout; it failed before the fix. H22 asserts `!saw_break`, probed to fail on a source with `break`. The lead made `proof-review` `FdWriter` report failed and short writes: `zttp proofs --help` with an unwritable stdout exited 0 before and 1 after. A write failure on `--help` or `--version` now exits 1. `runtime_console.zig` stays best effort, because it is the handler `console.log` path. |
| U2 | `54e056b5` | `test-expert-app` 0, `test-cassette` 0, `test-standin` 0, `test-module-boundary` 0 | `isSecretBasename` runs before `git check-ignore` and is shared through `tools/common.zig`. Search refuses an explicit secret or ignored path and post-filters every record by basename. The context walk stops at the nearest `.git` root or the starting directory. Six new tests failed before the fix. The filter reads basenames only, not directory names. |
| U3 | `f3d38e5a`, `b3a8e380` | `test-expert-app` 0, `test-standin` 0, `test-simulator` 0, `test-cassette` 0, `test-module-boundary` 0, `test-runtime-purity` 0 | `unprovenGoals` runs `runCheckOnlyFromSourceWithOptions` on the candidate bytes with `discoverProjectPaths`; the lead added the project policy, as the edit gate passes it. `ok` needs no counted violation and no unproven goal; the envelope gains `unproven`. `pi_repair_plan` follows. `parseGoalCheckResult` propagates errors. The `pii_contained` and missing-import tests failed before the fix. No test reaches the no-location violation. `pi_goal_check` appears in no cassette. |
| U7 | `f8ee4c52` | `test-expert-app` 0, `test-runtime-purity` 0, `test-module-boundary` 0, `test-standin` 0, `test-cassette` 0, `test-simulator` 0 | `zts_check` and `pi_specs_status` call the check in-process and read the SQL schema and policy as the CLI does; `gen_tests` calls `precompile.runGenTests`, because `runGenTestsCommand` exits the process on a missing file. Four tests in a workspace without `build.zig` failed before the fix. The two `pi_specs_status` corpus files replay unchanged. |
| U6 | `3fe3d91d` | `check-spine` 0, `test-kernel-safety` 0, `test-capability-audit` 0, `test-proof-swallow` 0, `test-bench-diff` 0, `test-docs-drift` 0, `test-native-gates` 0, `test-zts` 0, `test-contract-golden` 0, `test-diagnostic-corpus` 0, `test-precompile` 0, `test-script-reachability` 0, `test-expert-app` 0, `test-flow-census` 0 | H13: both scripts fail below an input floor (13 kernel files, 30 module files), probed in `test-gate-floors.sh`. H14: three files join the formatting route. H15: six files join `check-proof-swallow.sh` (28 files); 42 catch rows and 44 silent-arm markers added. `narrowTypeForPattern` now propagates OutOfMemory into the checker poison flag, and `patternCanMatchType` resolves a named member and keeps a member it cannot judge. D1: `bench-check` warns on a Zig version mismatch and does not fail. |
| U8 | `d378efd1` | `check-spine` 0, `test-docs-drift` 0, `test-doc-links` 0, `test-cli` 0, `test-expert-golden` 0, `test-canonicalize` 0, `test-proof-checker-purity` 0, `test-script-reachability` 0, `test-step-coverage` 0 | D1 to D7 as in the plan. The two Zig 0.16.0 safety claims now say "when measured on Zig 0.16.0"; the 0.17.0 behavior without the local setting was not re-measured. |

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

## Round 3a notes

- U6 went beyond the plan in one place. `patternCanMatchType` judged a named member by its tag, so a `match` arm could narrow below the values it can hold. It now resolves the name and keeps a member it cannot judge, which widens an arm type. No probe exposed a wrong result before the change, and no test pins it.
- The U6 implementer ran `python3 --version` and `python3 -c 1` as no-ops. No Python file or invocation was committed.
- The implementer commits in the lane worktrees were cherry-picked onto main, so the hashes above are the main hashes.

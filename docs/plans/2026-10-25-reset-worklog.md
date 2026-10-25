# Reset worklog, 2026-10-25

Plan: [2026-10-25-reset-implementation-plan.md](2026-10-25-reset-implementation-plan.md). The plan owns findings, phases, and acceptance.
This worklog records execution, commands, exit statuses, and stop-rule results.

## Decisions

- 2026-10-25: the owner answered "as recommended". This selects option (a) for Decisions 1 to 5.
- 2026-10-25: the owner chose Decision 6 (a). R0 waited until the concurrent session finished.

## Environment

- Private caches: `ZIG_LOCAL_CACHE_DIR=/private/tmp/claude-501/zttp-reset-20261025/local`, `ZIG_GLOBAL_CACHE_DIR=/private/tmp/claude-501/zttp-reset-20261025/global`.
- `DEEPSEEK_API_KEY` is unset for every run.
- Logs: `/private/tmp/claude-501/zttp-reset-20261025/logs/`.

## R0. Baseline and preservation evidence

- Base commit: `315559e808392d4e579fa182814c3516b0a19c80`. Tree: `4d4153885f67ff2b61101e1882000e9e91586ac8`.
- `git status --porcelain` printed nothing at the base.
- Full gate: `bash scripts/verify.sh` exit 0 after 863 seconds; the log ends with "all per-commit gates passed". Log: `r0-verify.log`.
- Analyzer digests (step 6): `zig build` exit 0. The loop over `git ls-files 'tests/corpus/**.ts' 'examples/**.ts'` digested 215 sources: 69 exit 0, 146 exit 1, 203 distinct digests.
- Determinism (step 7): two runs are byte-identical (`cmp`). The kept file is `/private/tmp/claude-501/zttp-reset-20261025/analyzer-digests.txt`, SHA-256 `dc517607120da3ae21f3ad02afaf5edc99d0fa18405284390c70337967da5b80`. No case is excluded.
- F14 measurement (step 8), first attempt: five `zig build test` runs without `-j1` all exited 0 in 82 to 103 seconds. This is not evidence: run 1 reported 157 cached steps, so most tests did not execute. The repeat uses a fresh local cache for each run.
- F14 measurement, repeat: five `zig build test --summary all` runs, each with a fresh local cache. All exited 0 in 124 to 177 seconds, each with "213/213 steps succeeded; 7765/7771 tests passed (6 skipped)". Process-wide state is therefore not a measured cause of the macOS `-j1` need, and R11c is dropped as the plan specifies. `-j1` stays in `tooling/verify.zig`.
- Counts at the base: aggregate 7765 passed of 7771 (6 skipped); `test-zruntime` 239 passed of 240 (1 skipped); `test-cli` 618 passed, 1 skipped. The ordered `run test` counts are in `/private/tmp/claude-501/zttp-reset-20261025/r0-step-counts.txt` (SHA-256 `c65127e8bb1bdf97db5e3e1512d84288b8e0f6ee358e1cdf70ca264ad11dfef9`).
- Bytecode identity golden (steps 3 to 5): `packages/tools/src/bytecode_identity_golden.zig` and its embedded golden `bytecode_identity_golden.txt`. Each `examples/` and `tests/corpus/check/good` handler compiles through `precompile.compileHandler` with the options of the build command. 63 inputs: 58 digested, 5 refused by name. The floor is 60 inputs, and at least half must be digested. Write mode: `ZTTP_WRITE_BYTECODE_GOLDEN=1` from a fresh cache.
- Determinism: two runs from an empty cache gave the same golden. A one-byte sabotage of a golden line made `test-precompile` and `zig build test` exit 1 with "bytecode identity drift" and the path.
- Limits: the test reads handler sources at run time, so a cached pass after an edit to `examples/` or the corpus can be stale. The test walks directories, so an untracked `.ts` file under those roots fails it. Five aggregate roots analyze `precompile.zig`, so the aggregate runs the test five times (7765 to 7770 tests). The aggregate took 131 seconds after the change, inside the 124 to 177 second range at the base.
- After the cherry-pick: fresh-cache `zig build test` exit 0 (7770/7776 passed, 6 skipped); `zig build check-spine` exit 0; the protection check against `315559e8` exit 0.
- R0 exit: complete. The bytecode golden joins the protection list from R1 on.

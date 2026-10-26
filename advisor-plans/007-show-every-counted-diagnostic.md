# Plan 007: Every error that check, test, and dev count is printed

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before you continue. Touch only the files in scope. If a STOP condition occurs, stop and report. When done, update the status row for this plan in `advisor-plans/README.md`.
>
> **Drift check, run first**: `git diff --stat c1ecdf65 -- packages/tools/src/precompile_check_run.zig packages/tools/src/precompile_check.zig packages/runtime/src/test_command.zig packages/runtime/src/dev_command.zig packages/runtime/src/cli_doctor.zig scripts/smoke-v1.sh`
> If a file in scope changed, compare the Current state facts with the live code. If they do not match, stop and report.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug (usability)
- **Planned at**: commit `c1ecdf65`, 2026-10-26
- **Source**: release review 2026-10-26, finding H4

## Why this matters

`zttp check` prints "1 errors" for a handler that leaks `env("API_TOKEN")` under a `read_only` capsule, but it prints no diagnostic. The ZTS400 appears only in `--json`. `zttp test` and `zttp dev` print "Next: fix the errors above" with no error above. A user cannot see why the build fails. No hashed policy surface and no recorded corpus is involved.

## Current state

Reproduced on 2026-10-26 with the binary built at `c1ecdf65`:
- `zttp check h4.ts` prints `no_secret_leakage ... ---` and "1 errors, 0 warnings" with no diagnostic line. `zttp check h4.ts --json` lists `ZTS400` "secret data flows into response body".
- `zttp test` prints `Pre-test check failed for ...: 1 error(s)`, then `flow     1 error(s)`, then "Next: fix the errors above". The same shape occurs with `spec     1 error(s)` for a spec failure.

Probe source `h4.ts`:

```ts
import { env } from "zttp:env";
structural RO<T> = Proof<T, "read_only">;
function handler(req: Request): RO<Response> {
  return Response.json({ v: env("API_TOKEN") ?? "" });
}
```

Root causes:
1. `packages/tools/src/precompile_check_run.zig`: the flow stage block (after `result.flow_errors = @intCast(checked.flow_error_count);`) has only an `if (json_mode)` branch. The verifier stage just above it has an `else` branch that formats with `checked.verifier.formatDiagnostics(diag_view, &aw.writer)` and prints with `if (!builtin.is_test and buf.items.len > 0) debugPrint("{s}", .{buf.items});`. `FlowChecker.formatDiagnostics` exists in `packages/zts/src/flow_checker.zig`.
2. `packages/tools/src/precompile_check.zig` (function `formatProofCard`) renders compiler IO failures, canonical, policy, and spec diagnostics. Spec diagnostics live in `contract.spec_diagnostics`. The card is printed by `zttp check` and by `zttp dev` only on success.
3. `packages/runtime/src/test_command.zig` and `packages/runtime/src/dev_command.zig` print only `printCheckStageFailures` (in `packages/runtime/src/cli_doctor.zig`) when `check.totalErrors() > 0`. That function prints counts. It computes `spec_errors` as the remainder, so canonical errors are counted as "spec".

Analysis in non-JSON mode prints the sound, type, strict, and verifier diagnostics through `debugPrint`. Probes on 2026-10-26 showed that a recovered admission diagnostic (ZTS613 for `x += 1`) and an unknown-module import error also print in human mode. So root cause 1 is the only gap found among the analysis stages; Step 1 also asks the executor to confirm that no other counted stage lacks a human-mode branch. Spec, canonical, and policy diagnostics reach a user only through `formatProofCard`.

Existing tests of the human card are substring checks in `packages/tools/src/precompile_check_tests.zig` (tests that call `formatProofCard`) and `packages/tools/src/precompile.zig`. `packages/tools/src/zts_cli.zig` calls `formatProofCard` in production code only. No file golden of the card exists. `debugPrint` output is skipped under `builtin.is_test`, so a unit test cannot see it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Setup | `unset DEEPSEEK_API_KEY; export ZIG_LOCAL_CACHE_DIR=<private dir> ZIG_GLOBAL_CACHE_DIR=<private dir>` | none |
| Build | `zig build > build.log 2>&1; echo $?` | `0` |
| Focused tests | `zig build test-precompile > p.log 2>&1; echo $?` | `0` |
| CLI tests | `zig build test-cli > c.log 2>&1; echo $?`, `zig build test-zts-cli > z.log 2>&1; echo $?`, `zig build test-cli-abuse > a.log 2>&1; echo $?` | `0` each |
| Flow smoke | `zig build smoke-v1 > s.log 2>&1; echo $?` | `0` |
| Aggregate | `zig build test > t.log 2>&1; echo $?` | `0` |
| Spine | `git add -A && zig build check-spine > sp.log 2>&1; echo $?` | `0` |
| Full gate | `bash scripts/verify.sh > v.log 2>&1; echo $?` | `0` |

Read each exit status directly. Never pipe `zig build` into `tail` and read `$?`. Never cite a `-Dtest-filter` run as evidence.

## Scope

**In scope:**
- `packages/tools/src/precompile_check_run.zig`: add the human-mode flow branch.
- `packages/runtime/src/test_command.zig`, `packages/runtime/src/dev_command.zig`: print the diagnostic sections on failure.
- `packages/tools/src/precompile_check.zig`: only if Step 2 needs a public helper that prints the canonical, policy, and spec sections without the full card.
- `packages/runtime/src/cli_doctor.zig`: count canonical errors under their own label in `printCheckStageFailures`.
- `scripts/smoke-v1.sh`: one new step.
- `packages/tools/src/precompile_check_tests.zig`: a test for any new helper.

**Out of scope:**
- JSON output shape, diagnostic text, codes, and the registry. They feed hashed surfaces.
- The parse-failure stage lines of the card. Plan 011 owns them.
- `zttp deploy`. It already prints `error[ZTS400]` through `packages/tools/src/precompile_contract.zig`.

## Git/workflow guidance

- Work on local `main`. One commit for this plan. Subject style: short and lowercase, for example `check: print flow diagnostics and the failing sections in test and dev`.
- Do not push.

## Steps

### Step 1: Print flow diagnostics in human mode

In `precompile_check_run.zig`, add an `else` branch to the flow block. Copy the verifier branch shape exactly: an `std.ArrayList(u8)`, an `std.Io.Writer.Allocating`, `checked.flow_checker.formatDiagnostics(diag_view, &aw.writer) catch {};`, and the same `debugPrint` guard. Use the flow checker's `formatDiagnostics` signature as it exists; if it differs from the verifier's, adapt the call and nothing else.

Then read every stage in `precompile_check_run.zig` that adds to `totalErrors()` and confirm that each one has a human-mode render. Report any other stage without one; do not fix it in this plan unless it is a missing `else` branch of the same shape.

**Verify**: build, then `zig-out/bin/zttp check h4.ts > out.txt 2>&1; echo $?` prints `1`, and `grep -c ZTS400 out.txt` prints at least `1`.

### Step 2: Show the failing sections in test and dev

In the failure branch of `test_command.zig` and `dev_command.zig`, print the canonical, policy, and spec diagnostic sections before "Next:". Prefer one shared public function in `precompile_check.zig` that writes those three sections, called both by `formatProofCard` and by the two commands, so the text stays the same. Keep `printCheckStageFailures` as the count summary.

**Verify**: in a scratch project made with `zttp init`, replace `src/handler.ts` with `h4.ts`; `zttp test > t.txt 2>&1; echo $?` prints `1`, and `t.txt` contains `ZTS400`. Replace it with a handler that declares `Proof<Response, "deterministic">` and returns `Response.json({ t: Date.now() })`; `t.txt` contains the ZTS500 spec line.

### Step 3: Label canonical errors

In `printCheckStageFailures`, print canonical errors on their own `canonical` line and remove them from the `spec` remainder. Use the existing canonical error counter on `CheckResult`; if none exists, stop and report.

**Verify**: `zig build test-cli` exits 0.

### Step 4: Add a smoke step

In `scripts/smoke-v1.sh`, after an existing project setup, write the H4 handler and assert that `zttp test` exits non-zero and that its output contains `ZTS400`. Follow the script's existing assertion style.

**Verify**: `zig build smoke-v1` exits 0. Then revert Step 1 locally and confirm the smoke step fails. Restore Step 1.

## Test plan

- New smoke step in `scripts/smoke-v1.sh` (Step 4). It is the only observer of `debugPrint` output.
- If Step 2 adds a helper, add a substring test in `precompile_check_tests.zig` beside the tests that call `formatProofCard`.
- Run every gate in the table.

## Done criteria

- [ ] `zttp check h4.ts` prints ZTS400 in human mode.
- [ ] `zttp test` and `zttp dev` print each failing diagnostic that they count.
- [ ] `zig build test`, `smoke-v1`, `test-precompile`, `test-cli`, `test-zts-cli`, `test-cli-abuse`, `check-spine`, and `bash scripts/verify.sh` exit 0.
- [ ] No file outside the scope list changed.

## STOP conditions

- The flow block or the verifier branch does not match the Current state.
- A change moves `policy-hash.txt`, a contract golden, or the codegen replay (`zig build test-expert-app` fails with a stale cassette).
- A gate fails twice after reasonable local correction.

## Maintenance notes

- Reviewers should confirm that the human output and the JSON output now list the same codes for the probe.
- Deferred: a file golden of the human card.

# Release fixes, 2026-10-26

This plan promotes advisory plans 007 to 014 into the work authority. The
release review of 2026-10-26 at `c1ecdf65` gave the verdict "not ready". Each
unit below closes one or more of its findings. The unit specification is the
advisory plan file; this file records the order, the owner decisions, and the
execution record.

## Units

| Unit | Specification | Finding | Status |
|---|---|---|---|
| 007 | [Every counted diagnostic is printed](../../advisor-plans/007-show-every-counted-diagnostic.md) | H4 | DONE |
| 008 | [The handler deadline fires in callbacks and recursion](../../advisor-plans/008-deadline-on-calls.md) | H2 | TODO |
| 009 | [One rate-limit store per handler pool](../../advisor-plans/009-one-rate-limit-store-per-process.md) | H5 | TODO |
| 010 | [SQL writes wait for a busy writer](../../advisor-plans/010-sqlite-waits-for-a-busy-writer.md) | M7 | TODO |
| 011 | [The documented CLI flows work](../../advisor-plans/011-cli-flows-match-the-docs.md) | M3, M4, M5, low items | TODO |
| 012 | [Claims say what they check](../../advisor-plans/012-claims-say-what-they-check.md) | M1; H1 and M2 interim | TODO |
| 013 | [Vacuous fault coverage and one acceptance rule](../../advisor-plans/013-one-acceptance-rule-and-vacuous-fault-coverage.md) | H3 | TODO; re-record window |
| U2, U3 | [Soundness plan](2026-10-21-soundness-plan.md), sections U2 and U3 | H1, M2 | TODO; re-record window |
| 014 | [Release preparation](../../advisor-plans/014-release-prep-after-fixes.md) | M6 | TODO; last |

Units 007 to 012 run in this order, one at a time, on local `main`. Unit 013,
U2, and U3 share one owner-run DeepSeek re-record. Unit 014 runs last.

## Owner decisions

On 2026-10-26 the owner answered "as recommended" to Decisions 16 to 20:

- 16 (a): a handler with no failable site is fault-covered by vacuous truth; `path_analyzer_version` moves from 4 to 5.
- 17 (a): `deploy` refuses any spec error, as `test` does, after the census in unit 013 Step 0.
- 18 (a): one shared rate-limit store per handler pool, recorded as a documented exception to request isolation.
- 19 (a): an unpinned `zttp verify` exits 0, labels the result unpinned, and writes `keyPinned: false`. The owner accepts that automation which reads only the exit status sees success.
- 20 (a): clear `SO_REUSEPORT` after `listen`; option (b), a hand-built listener with `SO_REUSEADDR` only, is approved as the fallback if (a) fails on Linux.

## Execution record

Each unit appends its commits, gate commands, and exit statuses here.

### 007: every counted diagnostic is printed

Commit `efb3a182` (release fix 007: print flow diagnostics and the failing sections in test and dev). Scope additions beyond the plan list: `packages/tools/src/precompile.zig` (re-export of the new helper) and `scripts/proof-swallow.allow` (row `runCheckOnParsedSource catch-block@13` for the new flow format call, covered by the existing CHECK facade reason).

Gates, each with exit 0: `zig build test-precompile`, `test-cli`, `test-zts-cli`, `test-cli-abuse`, `smoke-v1`, `test-proof-swallow`, `test`, and `git add -A <paths> && zig build check-spine`. With the flow branch reverted, `zig build smoke-v1` exits 1 on the new step. `bash scripts/verify.sh` is left to the coordinator.

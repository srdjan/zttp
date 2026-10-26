# Advisory Plans

Files in this directory are evidence-backed proposals. They are not the
repository's active planning authority.

`docs/roadmap.md` remains the maintained forward-looking document. Before an
advisory plan is implemented, promote its approved delivery unit into a dated
file under `docs/plans/` and reconcile it with the roadmap. Do not execute two
overlapping plans at the same time.

## Saved proposals

| Plan | Title | Priority | Effort | Status |
|---|---|---|---|---|
| 001 | TigerBeetle-inspired predictable performance (`pre-rebase:advisor-plans/001-tigerbeetle-inspired-predictable-performance-plan.md`) | P1 | XL | PROPOSED |
| 002 | Complete the local LFM measurement and default cutover (`pre-rebase:advisor-plans/002-local-lfm-default-cutover-plan.md`) | P1 | L | SUPERSEDED; historical measurement evidence only |
| [003](003-zttp-zts-simplification-audit.md) | Simplify the zttp and zts foundation | P1 | L | DIRECTION ACCEPTED; preserve features and initial wire formats; shared analysis first |
| 004 | Share single-module analysis between check and compile (`pre-round-2-archive:advisor-plans/004-shared-analysis-first-unit.md`) | P1 | M | ACCEPTED 2026-10-11; promoted to docs/plans, completed |
| [005](005-feature-removal-rebase.md) | Remove the features that do not carry the agent-compiler | P1 | XL | Phases 1 to 3 complete; Phase 4 closed by the 2026-10-14 reset (`ad1aa961` to `10115d98`); the 2026-10-25 reset plan is the active authority |
| 006 (`pre-round-3-archive:advisor-plans/006-modular-boundaries.md`) | Make analysis and runtime ownership explicit | P1 | L | COMPLETE 2026-10-22; five phases reviewed, aggregate/full gate passed; isolated `codex/modular-boundaries` worktree |

## Release fixes from the 2026-10-26 release review

The release review of 2026-10-26 at `c1ecdf65` gave the verdict "not ready". Plans 007 to 014 close its findings. Execute them in this order unless a dependency says otherwise. Each plan names its gates and its STOP conditions.

| Plan | Title | Finding | Priority | Effort | Depends on | Status |
|---|---|---|---|---|---|---|
| [007](007-show-every-counted-diagnostic.md) | Every error that check, test, and dev count is printed | H4 | P1 | S | none | DONE |
| [008](008-deadline-on-calls.md) | The handler deadline fires in callbacks and recursion | H2 | P1 | S | none | DONE |
| [009](009-one-rate-limit-store-per-process.md) | zttp:ratelimit counts across every runtime of a handler pool | H5 | P1 | M | Decision 18 | DONE |
| [010](010-sqlite-waits-for-a-busy-writer.md) | Concurrent SQL writes wait for the lock instead of failing | M7 | P2 | S | none | TODO |
| [011](011-cli-flows-match-the-docs.md) | The documented CLI flows work and fail clearly | M3, M4, M5, low items | P2 | M | 007 | TODO |
| [012](012-claims-say-what-they-check.md) | Provenance and security claims say exactly what they check | M1; H1 and M2 interim | P1 | S | none | TODO |
| [013](013-one-acceptance-rule-and-vacuous-fault-coverage.md) | An I/O-free handler is fault-covered, and deploy accepts what test accepts | H3 | P1 | M | Decisions 16 and 17; 007; re-record window | TODO |
| U2 (`docs/plans/2026-10-21-soundness-plan.md`, section U2) | Every literal `env()` name is secret unless the policy lists it in `env.public` | H1 | P1 | M | re-record window | TODO; spec written at `ece05117` with line anchors, so its first step is a drift check against HEAD |
| U3 (`docs/plans/2026-10-21-soundness-plan.md`, section U3) | `mask` declassifies only with a literal bound of 4 or less | M2 | P2 | S | re-record window | TODO; same drift check |
| [014](014-release-prep-after-fixes.md) | The release record matches the code, and the evidence is current | M6 | P1 | S | every selected plan | TODO |

Owner decisions: on 2026-10-26 the owner chose option (a) for Decisions 16 to 20. The units are promoted to `docs/plans/2026-10-26-release-fixes-plan.md`, which holds the execution record.

Dependency notes:
- Plans 007 to 012 move no hashed policy surface and no recorded corpus. They can land before the re-record window.
- Plan 013, U2, and U3 each move the policy hash. Run them in one re-record window (owner Decision 2, decision D-012) so that one owner-run DeepSeek re-record covers all three. The U2 and U3 spec predates Zig 0.17.0 and 216 later commits; its semantics still match the code (`flow_interp.zig` `declaredLabels`, `flow_analyzer_version` 7), but its anchors do not.
- Plan 011 follows plan 007 because both edit `packages/tools/src/precompile_check.zig`. Plan 013 reuses the printing from plan 007.
- Plans 008, 009, 010, and 011 all edit `docs/reliability.md`, and 008 to 011 add tests to `packages/runtime/src/server_test.zig`. Run them in sequence on local `main`, not in parallel worktrees.
- Plan 014 runs last, because `zig build release-provenance` accepts evidence only when nothing but the four evidence files changed after its source commit.

Review record: on 2026-10-26 a Fable critic and a Codex astra fact-checker reviewed these plans. The plans fold in their corrections: plan 009 uses the existing `installSdkModuleState` mechanism instead of a new `Context` field; plan 008 also keeps the timeout identity through JSX components; plan 011 tests the port fix on Linux before adopting it; plan 013 adds an example census before Decision 17; the U2 and U3 rows are added. One correction was rejected after probing: recovered admission diagnostics and import errors already print in human mode, so plan 007 keeps its scope. The dated measurements in plans 008 to 010 (67 s, 20 of 200, 36 of 80) are observations from the 2026-10-26 release-review probes; no transcript is kept in the repository, so each plan's verification step measures them again.

Considered and rejected:
- H3 option (b), leaving `fault_covered` out of the default profile only for zero-site handlers: an explicit `fault_covered` claim would stay refused.
- H5 with a module-level global store in `ratelimit.zig`: it hides shared state from the runtime and shares counters between unrelated test runtimes.
- H5 with a new `Context` field and SDK accessor: the existing pre-install mechanism does the same without a hot-struct change.
- A shared `zttp:cache` in this series: plan 009 documents per-runtime cache semantics instead.
- Hosted CI: removed by decision in commit `78ac1611`; `scripts/release.sh` is the release gate.

Plan 002's cutover half is superseded: the default provider moved to DeepSeek on
2026-08-14. Its measurement half stands. The parked local corpus (16 of 19 cases)
was deleted in round 3 and stays at the `pre-round-3-archive` tag.

Phase 4 starts with [CHECK facts reuse](../docs/plans/2026-10-13-1113-refactor-check-facts-reuse-plan.md).
The plan preserves current reader calls and removes one duplicate root facts producer.
The owner authorized execution with "D12: 1". The worklog (`pre-round-2-archive:docs/plans/2026-10-13-feature-removal-phase-4-worklog.md`) records source checks and remaining release work.
It does not complete loaded-graph convergence or authorize the later typed frontend migration.

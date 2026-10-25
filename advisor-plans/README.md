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

Plan 002's cutover half is superseded: the default provider moved to DeepSeek on
2026-08-14. Its measurement half stands. The parked local corpus (16 of 19 cases)
was deleted in round 3 and stays at the `pre-round-3-archive` tag.

Phase 4 starts with [CHECK facts reuse](../docs/plans/2026-10-13-1113-refactor-check-facts-reuse-plan.md).
The plan preserves current reader calls and removes one duplicate root facts producer.
The owner authorized execution with "D12: 1". The worklog (`pre-round-2-archive:docs/plans/2026-10-13-feature-removal-phase-4-worklog.md`) records source checks and remaining release work.
It does not complete loaded-graph convergence or authorize the later typed frontend migration.

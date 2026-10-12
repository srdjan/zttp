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
| [004](004-shared-analysis-first-unit.md) | Share single-module analysis between check and compile | P1 | M | ACCEPTED 2026-10-11; promoted to docs/plans |
| [005](005-feature-removal-rebase.md) | Remove the features that do not carry the agent-compiler | P1 | XL | PROPOSED 2026-10-11; nine owner decisions open |

Plan 002's cutover half is superseded: the default provider moved to DeepSeek on
2026-08-14. Its measurement half stands, and the local corpus is still parked at
16 of 19 cases.

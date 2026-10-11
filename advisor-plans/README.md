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
| 001 | TigerBeetle-inspired predictable performance | P1 | XL | PROPOSED |
| 002 | Complete the local LFM measurement and default cutover | P1 | L | SUPERSEDED; historical measurement evidence only |
| [003](003-zttp-zts-simplification-audit.md) | Simplify the zttp and zts foundation | P1 | L | DIRECTION ACCEPTED; preserve features and initial wire formats; shared analysis first |
| [004](004-shared-analysis-first-unit.md) | Share single-module analysis between check and compile | P1 | M | PROPOSED; bounded first unit, awaiting implementation approval |

Plan 002's cutover half is superseded: the default provider moved to DeepSeek on
2026-08-14. Its measurement half stands, and the local corpus is still parked at
16 of 19 cases.

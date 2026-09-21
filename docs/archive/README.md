# Archive

Dated records of completed work, superseded plans, and past investigations.
Their technical content is historical. Read them for decisions and evidence;
use maintained docs for current behavior. Links can change when records move.

Claims and unchecked tasks describe the named baseline. Later corrections can
supersede them. Paths, command names, and file layouts have moved since. The
prose bans in
`scripts/check-docs-drift.sh` skip this directory for exactly that reason: a
record that documents retiring a path has to be able to name the path it
retired.

| Directory | Contents |
|---|---|
| `plans/` | Dated implementation plans, design notes, and findings, one file per unit of work. |
| `plans-advisory/` | Read-only advisor passes over the whole repository, with `README.md` as the index and status table. |
| `ideation/` | Exploratory HTML write-ups that preceded a plan. |
| `vision/` | Longer-range direction documents. |
| `spec-explainers/` | The two HTML formal-spec explainers, superseded by `docs/zts-formal-spec-northstar-advanced.md`. |

Three loose files sit at the top level: `IMPROVEMENT_PLAN.md` and
`DEFERRED_VM_LOOP_DEDUPE_PLAN.md`, which were repository-root plan documents,
and `v0.1-v0.2-gap-analysis.md`, which was the only file under
`packages/zts/src/docs/`.

Two files in `plans/` are program records rather than plans, lifted out of
`docs/roadmap.md` on 2026-08-16 when every item in them had closed:

- [the agent-compiler agenda](plans/2026-08-16-028-agent-compiler-agenda-closed.md),
  eight closed items on the convergence thesis.
- [the advanced ZTS language program](plans/2026-08-16-029-zts-advanced-language-program-closed.md),
  phases 0 through 7 and how the four carried risks landed.

Both are worth reading before proposing work in those areas: several entries
record a measurement that did not support the expectation the item was written
on, which is the part a summary would drop.

The 2026-09-21 backlog cleanup moved the remaining closed language phases,
module split, boundary-type increment, local-provider cutover, corpus and
coverage investigations, artifact and guard work, ledger invariant plans,
and bounded rederive records here. Their status notes distinguish delivered
scope from deferred work. The reset ledger is historical; its open questions
are retained in the roadmap.

D1, D2, and D3 remain [design references](../plans/README.md). The custom
agent-handler specification remains a parked proposal there. Recurring bug
classes remain maintained under [solutions](../solutions/).

[Roadmap](../roadmap.md) owns current work status and scheduling. An archived
instruction or unchecked task does not authorize another execution.

# Archive

Dated records of work that is finished. Nothing here is maintained, nothing
here is a gate, and nothing here is guaranteed to describe the current system.
Read it for why a decision was made, never for how the code works today.

Every claim in these files was true when it was written. Paths, command names,
and file layouts have moved since. The prose bans in
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

Still live, and deliberately not archived:

- `docs/plans/2026-07-28-001-reset-simplification-plan.md`, because three items
  across waves 4 and 5 are unfinished. It archives itself once they close;
  `docs/roadmap.md` names what is left.
- The three `zts-advanced-1` companion design documents, D1 to D3. They are
  reference specifications that later phases consume, not plans to execute.
  Their master plan and the executed phase 0 and phase 1 plans are here in
  `plans/`; `docs/roadmap.md` carries the remaining phase map.
- The phase 2 through phase 7 plans, and the local-LFM cutover plan. Each phase
  is closed, but `docs/roadmap.md` links its row to the plan that recorded what
  the phase actually found, so archiving them would break the roadmap's
  evidence trail.
- The completed artifact-level proof-carrying-code plan. Its residual runtime
  guard companion uses the original path as a stable prerequisite reference,
  and the roadmap records that the prerequisite is complete.
- `docs/solutions/`, which agents are pointed at and which is not planning
  residue.

`docs/roadmap.md` is the only forward-looking document in the maintained docs.
When a plan here contradicts it, the roadmap is current and the plan is
history.

# Plans and design references

[Roadmap](../roadmap.md) owns work status, dependencies, next actions, and
completion checks. A file here does not authorize implementation. Update this
index when a plan starts, closes, or moves to the archive.

| Document | Role and status | Work authority |
|---|---|---|
| [Plan 005 Phase 2: runtime and artifact removal](2026-10-12-1109-refactor-feature-removal-phase-two-plan.md) | In execution; scope, decisions, and evidence in the [worklog](2026-10-12-feature-removal-phase-2-worklog.md) | Owner selected Decision 10, "Execute Phase 2" |
| [Plan 005 Phase 1: feature removal](2026-10-11-feature-removal-phase-1.md) | Complete 2026-10-12; G1 to G15 done, results and recounts in the [worklog](2026-10-11-feature-removal-worklog.md) | Owner accepted plan 005 decisions 1 to 9 with "your recommendations" |
| [Multi-module contract analysis](2026-10-11-1608-refactor-multi-module-contract-analysis-plan.md) | Complete 2026-10-11; results and coverage limits in [worklog](2026-10-11-multi-module-analysis-worklog.md) | Owner approved the concrete plan with "yes, execute" |
| [Shared analysis first unit](2026-10-11-shared-analysis-first-unit.md) | Complete 2026-10-11; results and coverage limits in [worklog](2026-10-11-shared-analysis-worklog.md) | Owner approved execution with "go ahead" |
| [Minimal design audit](2026-10-08-minimal-design-audit.md) | Research complete; reductions, compatibility questions, and acceptance checks | User requested simplification discovery; implementation scope remains unselected |
| [M5: release contract for agent handlers](2026-09-27-m5-agent-handler-release-contract.md) | Stopped 2026-10-11 by plan 005 decision 3; A1 to A4 were complete, A5 was not implemented, and Phase 2 removes the M4 and M5 code | Owner accepted the contract on 2026-09-27; plan 005 decision 3 stopped M5 |
| [M5 A5: buffered reference agent](2026-09-28-m5-a5-reference-agent-design.md) | Stopped 2026-10-11 by plan 005 decision 3; the design was accepted 2026-09-28 and never implemented | Owner directed A5 as the next unit on 2026-09-28; plan 005 decision 3 withdrew it |
| [Proof-checker rederive review](2026-09-24-proof-checker-rederive-review.md) | Implemented 2026-09-25; Phases 0 to 4 committed, results and section 7 leftovers at the end of the plan | Owner accepted the plan and answered its four decisions |
| [M4: release contract for scoped tool routes](2026-09-22-m4-release-contract.md) | Accepted 2026-09-22; T1a to T7 complete | Owner accepted the contract on 2026-09-22 |
| [M4 T6: credential injection](2026-09-24-m4-t6-credential-injection-design.md) | Implemented 2026-09-24; U1, U2, and U3 complete | Owner accepted the design and answered its four questions |
| [M4 T5: subject scope and tool-local grants](2026-09-23-m4-t5-scope-and-grants-design.md) | Accepted 2026-09-23; T5a and T5b implemented | Owner accepted the design and answered its four questions |
| [M4 T4: declared-label carriage](2026-09-23-m4-t4-declared-labels-design.md) | Implemented 2026-09-23 | Owner accepted the design and answered its four questions |
| [M4 T3: catalog encoding and artifact binding](2026-09-23-m4-t3-catalog-binding-design.md) | Implemented 2026-09-23 | Owner accepted the design and answered its four questions |
| [M4 T2: tool catalog and schema subset](2026-09-23-m4-t2-tool-catalog-design.md) | Implemented 2026-09-23 | Owner accepted the design and answered its four questions |
| [M4 T1b: connect and handshake deadline](2026-09-23-m4-t1b-connect-deadline-design.md) | Implemented 2026-09-23 | Owner accepted the design and answered its three questions |
| [Flow-checker sinks in callees](2026-10-08-flow-checker-sinks-in-callees.md) | Complete 2026-10-09; census 776/776; follow-up R3 (`fault_covered` for a fixed-URL fetch) needs its own plan | Owner approved on 2026-10-08 |
| [Boolean checks and call arity](2026-10-08-boolean-and-arity-checks.md) | Complete 2026-10-09; shared DeepSeek re-record 12/19 (cohorts 15/19, 13/19) | Owner approved on 2026-10-08 |
| [Tier 1: test and diagnostic discipline](2026-10-07-tier1-test-and-diagnostic-discipline.md) | Complete 2026-10-08; section 8 lists 15 findings for owner decision | Owner approved implementation in plan order on 2026-10-07 |
| [Beni study: retrofit items](2026-10-07-beni-retrofit-study.md) | Research, 2026-10-07; 18 candidate items in four tiers | Owner chose Tier 1 (R1 to R5) for planning on 2026-10-07; no implementation authority |
| [D1: type system](2026-07-30-014-d1-type-system-design.md) | Retained design reference; language phases complete | No new work scheduled |
| [D2: effects and purity](2026-07-30-015-d2-effects-purity-design.md) | Retained design reference; language phases complete | No new work scheduled |
| [D3: canonical form and wire](2026-07-30-016-d3-canonical-form-wire-design.md) | Retained design reference; language phases complete | No new work scheduled |
| [Custom LLM agent handlers](2026-09-19-feat-agent-handler-spec.md) | Proposed; baseline refreshed 2026-09-27 at `e6f33dfc`; its M5 resumption stopped 2026-10-11 by plan 005 decision 3 | M4 delivered its catalog, scope, and credential parts; the M5 contract states the rest |

Plan 005 G14 deleted the completed plans that no tracked file outside `docs/plans/` cites. Each deleted plan stays readable at the `pre-rebase` tag, for example
`pre-rebase:docs/plans/2026-09-28-m5-a4-call-tool-design.md`. The worklog lists every
deleted and kept plan.

Archived execution records (`pre-rebase:docs/archive/README.md`) preserve completed work,
superseded plans, and historical measurements. The reset ledger's remaining
questions are in the roadmap. The product proposal index (`pre-rebase:docs/zttp-next/README.md`)
and [advisory index](../../advisor-plans/README.md) classify separate proposals.

M1 is complete in the backlog cleanup record (`pre-rebase:docs/archive/plans/2026-09-21-active-backlog-cleanup.md`).
M2 is complete in the bounded correctness record (`pre-rebase:docs/archive/plans/2026-09-21-bounded-correctness-assurance.md`). M3 is complete with a retained full fresh report.
The roadmap records the proposed later milestones.

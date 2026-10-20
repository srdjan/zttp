# Plans and design references

[Roadmap](../roadmap.md) owns work status, dependencies, next actions, and
completion checks. A file here does not authorize implementation. Update this
index when a plan starts, closes, or moves to the archive.

| Document | Role and status | Work authority |
|---|---|---|
| [Hardening and pruning](2026-10-20-hardening-pruning-plan.md) | Eight audit findings selected; ordered implementation in progress, 2026-10-20 | Owner selected all findings with "all of them" |
| [P7 request contents and sink evidence](2026-10-20-flow-interp-p7-spec.md) | Active version 7 evaluator, sink evidence and imported snapshots implemented; final acceptance pending | Included in the owner's approval of all hardening and pruning units |
| [Flow checker redesign](2026-10-18-flow-checker-sound-redesign-plan.md) | Draft 2026-10-18, revised after one Codex astra validation round; D9 to D12 decided 2026-10-19; revised after the second validation round | Owner chose Decision 8 Option A; P0 and P1 approved (D13); R16 and P2 approved 2026-10-19 |
| [R16 freeze and P2 evaluator core](2026-10-19-flow-interp-p2-r16-spec.md) | Specification 2026-10-19, revised after one Codex astra validation round | Owner approved R16 and P2 on 2026-10-19 |
| [P3 loops](2026-10-19-flow-interp-p3-spec.md) | Specification 2026-10-19, revised after one Codex astra fact and argument round | Owner approved P3 on 2026-10-19 (D17 A) |
| [P4 calls and captures](2026-10-19-flow-interp-p4-spec.md) | Specification 2026-10-19, revised after two Codex astra rounds | Owner approved P4 on 2026-10-19 (D18 A) |
| [P5 operation edges and callbacks](2026-10-19-flow-interp-p5-spec.md) | Specification 2026-10-19, revised after three Codex astra rounds | Owner approved P5 on 2026-10-19 (D20 A) |
| [Fail-closed guard for flow checker writes](2026-10-18-callback-iteration-writes-plan.md) | Superseded 2026-10-18 before implementation; records the observed false proofs F1 to F6 | Superseded by the redesign plan |
| [Weak test assertion census](2026-10-17-weak-assertion-census-plan.md) | Complete 2026-10-17; 576 rows classified, 127 weak assertions fixed with sabotage evidence; results in the [worklog](2026-10-17-weak-assertion-census-worklog.md) | Owner set the goal to finish Item 4 (the census) |
| [Reset implementation](2026-10-14-reset-implementation-plan.md) | U1–U20 committed locally; final gate and benchmark limits are in the [worklog](2026-10-15-reset-worklog.md) | Owner reviewed the plan and authorized implementation with subagents and Astra verification |
| [Zig agent spine](2026-10-14-agent-spine-plan.md) | Complete 2026-10-14; full local gate passed, with evidence in the [worklog](2026-10-14-agent-spine-worklog.md) | Owner selected Option A and approved the full local gate |
| [Plan 005 Phase 3: language and orchestration removal](2026-10-12-1444-refactor-feature-removal-phase-three-plan.md) | Active 2026-10-12; reviewed sequence and evidence in the [worklog](2026-10-12-feature-removal-phase-3-worklog.md) | Owner authorized Phase 3 and its complete DeepSeek recording with "go ahead with phase 3" |
| [Plan 005 Phase 2: runtime and artifact removal](2026-10-12-1109-refactor-feature-removal-phase-two-plan.md) | Complete 2026-10-12; scope, decisions, and evidence in the [worklog](2026-10-12-feature-removal-phase-2-worklog.md) | Owner selected Decision 10, "Execute Phase 2" |
| [Plan 005 Phase 1: feature removal](2026-10-11-feature-removal-phase-1.md) | Complete 2026-10-12; G1 to G15 done, results and recounts in the [worklog](2026-10-11-feature-removal-worklog.md) | Owner accepted plan 005 decisions 1 to 9 with "your recommendations" |
| [Multi-module contract analysis](2026-10-11-1608-refactor-multi-module-contract-analysis-plan.md) | Complete 2026-10-11; results and coverage limits in [worklog](2026-10-11-multi-module-analysis-worklog.md) | Owner approved the concrete plan with "yes, execute" |
| [Shared analysis first unit](2026-10-11-shared-analysis-first-unit.md) | Complete 2026-10-11; results and coverage limits in [worklog](2026-10-11-shared-analysis-worklog.md) | Owner approved execution with "go ahead" |
| [Minimal design audit](2026-10-08-minimal-design-audit.md) | Research complete; reductions, compatibility questions, and acceptance checks | User requested simplification discovery; implementation scope remains unselected |
| [Proof-checker rederive review](2026-09-24-proof-checker-rederive-review.md) | Implemented 2026-09-25; Phases 0 to 4 committed, results and section 7 leftovers at the end of the plan | Owner accepted the plan and answered its four decisions |
| [M4 T1b: connect and handshake deadline](2026-09-23-m4-t1b-connect-deadline-design.md) | Implemented 2026-09-23 | Owner accepted the design and answered its three questions |
| [Flow-checker sinks in callees](2026-10-08-flow-checker-sinks-in-callees.md) | Complete 2026-10-09; census 776/776; follow-up R3 (`fault_covered` for a fixed-URL fetch) needs its own plan | Owner approved on 2026-10-08 |
| [Boolean checks and call arity](2026-10-08-boolean-and-arity-checks.md) | Complete 2026-10-09; shared DeepSeek re-record 12/19 (cohorts 15/19, 13/19) | Owner approved on 2026-10-08 |
| [Tier 1: test and diagnostic discipline](2026-10-07-tier1-test-and-diagnostic-discipline.md) | Complete 2026-10-08; section 8 lists 15 findings for owner decision | Owner approved implementation in plan order on 2026-10-07 |
| [Beni study: retrofit items](2026-10-07-beni-retrofit-study.md) | Research, 2026-10-07; 18 candidate items in four tiers | Owner chose Tier 1 (R1 to R5) for planning on 2026-10-07; no implementation authority |
| [D1: type system](2026-07-30-014-d1-type-system-design.md) | Retained design reference; language phases complete | No new work scheduled |
| [D2: effects and purity](2026-07-30-015-d2-effects-purity-design.md) | Retained design reference; language phases complete | No new work scheduled |
| [D3: canonical form and wire](2026-07-30-016-d3-canonical-form-wire-design.md) | Retained design reference; language phases complete | No new work scheduled |

Plan 005 G14 deleted the completed plans that no tracked file outside `docs/plans/` cites. Each deleted plan stays readable at the `pre-rebase` tag, for example
`pre-rebase:docs/plans/2026-09-28-m5-a4-call-tool-design.md`. The worklog lists every
deleted and kept plan.

Phase 2 removes nine stopped plans for tool routes and agent handlers.
The `pre-rebase` tag preserves those plans and their original acceptance history.
The Phase 2 worklog records their removal with the retired runtime products.

Archived execution records (`pre-rebase:docs/archive/README.md`) preserve completed work,
superseded plans, and historical measurements. The reset ledger's remaining
questions are in the roadmap. The product proposal index (`pre-rebase:docs/zttp-next/README.md`)
and [advisory index](../../advisor-plans/README.md) classify separate proposals.

M1 is complete in the backlog cleanup record (`pre-rebase:docs/archive/plans/2026-09-21-active-backlog-cleanup.md`).
M2 is complete in the bounded correctness record (`pre-rebase:docs/archive/plans/2026-09-21-bounded-correctness-assurance.md`). M3 is complete with a retained full fresh report.
The roadmap records the proposed later milestones.

# Plans and design references

[Roadmap](../roadmap.md) owns work status, dependencies, next actions, and
completion checks. A file here does not authorize implementation. Update this
index when a plan starts, closes, or moves to the archive.

| Document | Role and status | Work authority |
|---|---|---|
| [v0.26.0: proof trust](2026-10-27-v0.26.0-plan.md) | Active authority for 0.26.0; revision 2 after the audit re-check and one Fable round; execution record in the same file | Owner chose 1(a), 2(a), 3(a) and 4(a) to 8(a) with "as recommended" on 2026-10-27 |
| [v0.26.0 C2 design](2026-10-28-v0.26.0-c2-design.md) | Design for C2a, C2b, R3, and C2c: the consumer re-derives `results_checked` | Owner chose 13(a) and 14(a) on 2026-10-28 |
| [v0.26.0 P1 and R2 design](2026-10-28-v0.26.0-p1r2-design.md) | Design for P1 and R2: four false `equivalent` verdicts of the behavior diff, with Revision 1 from Fable | Owner chose (a) for 17 to 24 and 26 to 29 on 2026-10-28 |
| [v0.26.0 A3 design](2026-10-28-v0.26.0-a3-design.md) | Design for A3 under Decision 31: a read of a value that may be undefined is refused as ZTS309; Revision 1 after Fable | Decisions 32 to 43 wait for the owner |
| [Release fixes, 2026-10-26](2026-10-26-release-fixes-plan.md) | Active authority for the release-review fixes; units 007 to 014, U2, and U3; execution record in the same file | Owner chose option (a) for Decisions 16 to 20 with "as recommended" on 2026-10-26 |
| [Reset implementation, 2026-10-25](2026-10-25-reset-implementation-plan.md) | Reset authority; complete through R13, 2026-10-25; open owner decisions are in the [roadmap](../roadmap.md) | Owner approved R0 to R13 with "as recommended" (Decisions 1 to 5, option a), chose Decision 6 (a), and chose option (a) for Decisions 8 to 11 on 2026-10-26 |
| [Eager recycle rebuild](2026-10-25-eager-recycle-rebuild-plan.md) | Plan 2026-10-25; the worker builds the replacement runtime after the response is sent; this index records no completion | Owner chose Decision 3 option A on 2026-10-25 |
| [Zig book hardening](2026-10-25-zig-book-hardening-plan.md) | Plan 2026-10-25; the worklog records the execution and lists open items (a ZTS200 alias-chain cost and a `bench-check` failure under host load) | Owner chose 1a; slot-buffer reuse waits for the recycle p99 |
| [Zig book hardening worklog](2026-10-25-zig-book-hardening-worklog.md) | Execution record, decisions, and open items for the Zig book hardening plan | Records the owner decisions of that plan |
| [Reset worklog, 2026-10-25](2026-10-25-reset-worklog.md) | Execution record, commands, exit statuses, and the R13b archive list for the 2026-10-25 reset; complete through R13 | Records the owner decisions of the 2026-10-25 reset plan |
| [Hardening and pruning implementation, round 4](2026-10-24-hardening-pruning-plan.md) | Implemented and verified 2026-10-24; U12 deferred, U13 retained for compatibility | Owner authorized execution with `go ahead`; full unrestricted verification passed |
| [Hardening and pruning, round 4](2026-10-24-hardening-pruning-list.md) | Selected audit list: 16 findings; implementation and dispositions are in the worklog | Owner authorized the bounded implementation plan |
| [Hardening and pruning worklog, round 4](2026-10-24-hardening-pruning-worklog.md) | Local commits, passing full verification and benchmark gate, and deferred scope | The final unrestricted verification supersedes the earlier sandbox failures |
| [Pruning round 3 plan](2026-10-23-pruning-round-3-plan.md) | Executed 2026-10-23; U0 to U15 and later corrections recorded; decision 5 resolved as (b); H10 defaults deferred | Owner chose decisions 1(a) to 4(a), then decision 5(b) |
| [Hardening and pruning, round 3](2026-10-23-pruning-round-3-list.md) | Audit list 2026-10-23: 24 hardening, 17 pruning, 12 consolidation, and 7 documentation items; rounds 3a and 3b selected | Owner chose decision 1(a) |
| [Pruning round 3 worklog](2026-10-23-pruning-round-3-worklog.md) | Completed units, final passing aggregate and full gate, owner decisions, and later corrections | Records the owner decisions of the round 3 plan |
| [Captured binding and match paths](2026-10-23-captured-binding-and-match-paths-plan.md) | Done 2026-10-23: T1 to T6 committed; `path_analyzer_version` 4; the DeepSeek re-record is approved (decision 15(a)) and run by the owner; results in the [worklog](2026-10-22-coupling-census-worklog.md) | Owner chose decisions 10(a), 11(a), 12(a) with "as recommended", 13(a) and 14(a) with "as recommended", and 15(a) and 16(a) with "a" |
| [Walker soundness](2026-10-22-walker-soundness-plan.md) | Done 2026-10-22: W1 to W10 committed, W11 records; D14 and D15 fixed by the captured binding plan; the residual gaps are R0 of the v0.26.0 plan | Owner chose decisions 8(a), 5(a), 6(a), 7(a), and 9(a) with "a" |
| Coupling census (`pre-round-3-archive:docs/plans/2026-10-22-coupling-census-plan.md`) | Complete 2026-10-22; U1 to U4 committed, `verify.sh` passed; U5 census confirmed two fail-opens (assert, spread), not fixed; results in the [worklog](2026-10-22-coupling-census-worklog.md) | Owner chose audit decisions 1(a) to 4(a) with "as recommended" |
| [Modular boundaries](2026-10-22-modular-boundaries-plan.md) | Complete, 2026-10-22; all five phases reviewed, focused gates and independent aggregate/full verification passed | Owner approved phased implementation with "go ahead in phases" |
| [Soundness hand-off](2026-10-21-soundness-handoff.md) | Hand-off 2026-10-21: Q1 to Q3, U6 and U1 committed locally; U2 and U3 specified, not validated or implemented | Records the owner decisions D1 to D8 |
| [Soundness plan](2026-10-21-soundness-plan.md) | U6 and U1 complete 2026-10-21; U2 (`env.public`) and U3 (bounded `mask`) approved and specified, validation pending | Owner approved D3(a), D4(a), D5(a) with "approved" and D6(a), D7(a), D8(a) with "as recommended" |
| Quick-fixes plan (`pre-round-3-archive:docs/plans/2026-10-21-quick-fixes-plan.md`) | Complete 2026-10-21; Q1 to Q3 committed locally | Owner chose D1(a) and D2(a) with "yes" |
| [Completeness audit](2026-10-21-completeness-audit.md) | Audit 2026-10-21 with Fable verdicts; groups beyond the quick fixes and soundness are not selected | No implementation authority |
| Pruning round 2 plan (`pre-round-3-archive:docs/plans/2026-10-21-pruning-round-2-plan.md`) | Complete 2026-10-21; U1 to U17 committed locally; results in the worklog (`pre-reset-archive-2026-10-25:docs/plans/2026-10-21-pruning-round-2-worklog.md`) | Owner chose decisions 1B, 2A, 3A, 4A, 5A with "as recommended" and approved implementation (decision 6A) with "yes" |
| Hardening and pruning, round 2 (`pre-reset-archive-2026-10-25:docs/plans/2026-10-20-pruning-round-2-list.md`) | Audit list 2026-10-20: 21 hardening, 19 dead-code, 13 consolidation, and 8 documentation items; selected by the round 2 plan; complete 2026-10-21 | Owner chose decisions 1B, 2A, 3A, 4A, 5A with "as recommended" |
| Hardening and pruning (`pre-reset-archive-2026-10-25:docs/plans/2026-10-20-hardening-pruning-plan.md`) | Complete 2026-10-20; all eight units implemented locally, as the round 2 list records | Owner selected all findings with "all of them" |
| [P7 request contents and sink evidence](2026-10-20-flow-interp-p7-spec.md) | Active version 7 evaluator, sink evidence and imported snapshots implemented; final acceptance pending | Included in the owner's approval of all hardening and pruning units |
| [Flow checker redesign](2026-10-18-flow-checker-sound-redesign-plan.md) | Draft 2026-10-18, revised after one Codex astra validation round; D9 to D12 decided 2026-10-19; revised after the second validation round | Owner chose Decision 8 Option A; P0 and P1 approved (D13); R16 and P2 approved 2026-10-19 |
| [R16 freeze and P2 evaluator core](2026-10-19-flow-interp-p2-r16-spec.md) | Specification 2026-10-19, revised after one Codex astra validation round | Owner approved R16 and P2 on 2026-10-19 |
| [P3 loops](2026-10-19-flow-interp-p3-spec.md) | Specification 2026-10-19, revised after one Codex astra fact and argument round | Owner approved P3 on 2026-10-19 (D17 A) |
| [P4 calls and captures](2026-10-19-flow-interp-p4-spec.md) | Specification 2026-10-19, revised after two Codex astra rounds | Owner approved P4 on 2026-10-19 (D18 A) |
| [P5 operation edges and callbacks](2026-10-19-flow-interp-p5-spec.md) | Specification 2026-10-19, revised after three Codex astra rounds | Owner approved P5 on 2026-10-19 (D20 A) |
| Fail-closed guard for flow checker writes (`pre-round-2-archive:docs/plans/2026-10-18-callback-iteration-writes-plan.md`) | Superseded 2026-10-18 before implementation; records the observed false proofs F1 to F6 | Superseded by the redesign plan |
| Weak test assertion census (`pre-round-2-archive:docs/plans/2026-10-17-weak-assertion-census-plan.md`) | Complete 2026-10-17; 576 rows classified, 127 weak assertions fixed with sabotage evidence; results in the worklog (`pre-round-2-archive:docs/plans/2026-10-17-weak-assertion-census-worklog.md`) | Owner set the goal to finish Item 4 (the census) |
| [Reset implementation, 2026-10-14](2026-10-14-reset-implementation-plan.md) | Complete; no longer the reset authority (superseded by the 2026-10-25 plan); U1–U20 committed locally; final gate and benchmark limits are in the [worklog](2026-10-15-reset-worklog.md) | Owner reviewed the plan and authorized implementation with subagents and Astra verification |
| [Zig agent spine](2026-10-14-agent-spine-plan.md) | Complete 2026-10-14; full local gate passed, with evidence in the [worklog](2026-10-14-agent-spine-worklog.md) | Owner selected Option A and approved the full local gate |
| [Plan 005 Phase 3: language and orchestration removal](2026-10-12-1444-refactor-feature-removal-phase-three-plan.md) | Complete 2026-10-12 to 2026-10-13 (the Phase 4 worklog and the advisor plan 005 row record Phase 3 as complete); reviewed sequence and evidence in the worklog (`pre-round-2-archive:docs/plans/2026-10-12-feature-removal-phase-3-worklog.md`) | Owner authorized Phase 3 and its complete DeepSeek recording with "go ahead with phase 3" |
| [Plan 005 Phase 2: runtime and artifact removal](2026-10-12-1109-refactor-feature-removal-phase-two-plan.md) | Complete 2026-10-12; scope, decisions, and evidence in the worklog (`pre-round-2-archive:docs/plans/2026-10-12-feature-removal-phase-2-worklog.md`) | Owner selected Decision 10, "Execute Phase 2" |
| [Plan 005 Phase 1: feature removal](2026-10-11-feature-removal-phase-1.md) | Complete 2026-10-12; G1 to G15 done, results and recounts in the worklog (`pre-round-2-archive:docs/plans/2026-10-11-feature-removal-worklog.md`) | Owner accepted plan 005 decisions 1 to 9 with "your recommendations" |
| Multi-module contract analysis (`pre-round-2-archive:docs/plans/2026-10-11-1608-refactor-multi-module-contract-analysis-plan.md`) | Complete 2026-10-11; results and coverage limits in worklog (`pre-round-2-archive:docs/plans/2026-10-11-multi-module-analysis-worklog.md`) | Owner approved the concrete plan with "yes, execute" |
| Shared analysis first unit (`pre-round-2-archive:docs/plans/2026-10-11-shared-analysis-first-unit.md`) | Complete 2026-10-11; results and coverage limits in worklog (`pre-round-2-archive:docs/plans/2026-10-11-shared-analysis-worklog.md`) | Owner approved execution with "go ahead" |
| [Fault coverage follow-ups (R4)](2026-10-09-fault-coverage-follow-ups.md) | Complete 2026-10-10 (section 9) | Owner answered D1 to D7 as recommended on 2026-10-10 |
| [Code review fixes for R3 and R4](2026-10-10-code-review-fixes.md) | Done, revision 2; fixes the 10 findings that the review kept | Fable review folded in; the owner decides a re-record if the offline replay fails |
| [Minimal design worklog](2026-10-10-minimal-design-worklog.md) | Complete; all ten reductions and the completeness correction committed on local `main` | The user authorized the full scope of the minimal design audit |
| [CHECK facts reuse](2026-10-13-1113-refactor-check-facts-reuse-plan.md) | First bounded unit of Phase 4; the [advisory index](../../advisor-plans/README.md) names its worklog | Owner authorized execution with "D12: 1" |
| [Recursion through function values](2026-10-16-recursion-through-function-values-plan.md) | Revision 5, validated by a Fable review of revision 4 | No owner decision recorded in the plan |
| [Flow interpreter differential dispositions](2026-10-20-flow-interp-difference-dispositions.md) | Review ledger 2026-10-20; does not approve production cutover | No implementation authority |
| [P6 defenses and nested match patterns](2026-10-20-flow-interp-p6-spec.md) | Specification 2026-10-20, reviewed by Codex astra in six drafts | Owner approved P6 (D21 Option A) and D22 to D25 |
| [Evidence model implementation plan](zttp-evidence-model-implementation-plan.md) | Proposed 2026-09-29; no repository changes were made | No implementation authority |
| Minimal design audit (`pre-round-3-archive:docs/plans/2026-10-08-minimal-design-audit.md`) | Research complete; reductions, compatibility questions, and acceptance checks | User requested simplification discovery; implementation scope remains unselected |
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
`pre-rebase:docs/plans/2026-09-28-m5-a4-call-tool-design.md`. The Phase 1 worklog
(`pre-round-2-archive:docs/plans/2026-10-11-feature-removal-worklog.md`) lists every deleted and kept plan.

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

Pruning round 2 (decision 5A) deleted 15 completed or superseded plans and worklogs that no code, solution note, or kept plan cites as a live link.
Each stays readable at the local `pre-round-2-archive` tag, for example
`pre-round-2-archive:docs/plans/2026-10-11-feature-removal-worklog.md`. The tag marks the commit before the deletion.
The round 2 worklog (`pre-reset-archive-2026-10-25:docs/plans/2026-10-21-pruning-round-2-worklog.md`, section "U8 archive") lists every deleted file.
The 2026-10-14 reset plan and worklog stay as the record of U1 to U20 and of the open benchmark result. The 2026-10-25 reset plan is the active authority.

Pruning round 3 (decision D7) deleted six completed plans that no tracked file outside `docs/plans/` cites, and advisor plan 006.
Each stays readable at the local `pre-round-3-archive` tag, for example
`pre-round-3-archive:docs/plans/2026-10-21-pruning-round-2-plan.md`. The tag marks the commit before the deletion.
The round 3 worklog (`2026-10-23-pruning-round-3-worklog.md`, section "U8 archive") lists every deleted file.

The 2026-10-25 reset (R13b) deleted three completed round 1 and round 2 plans that no tracked file outside `docs/plans/` cites.
Each stays readable at the local `pre-reset-archive-2026-10-25` tag, for example
`pre-reset-archive-2026-10-25:docs/plans/2026-10-20-hardening-pruning-plan.md`. The tag marks the commit before the deletion.
The reset worklog (`2026-10-25-reset-worklog.md`, section "R13b archive") lists each deleted file and each kept file with its reason.

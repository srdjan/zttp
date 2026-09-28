# Plans and design references

[Roadmap](../roadmap.md) owns work status, dependencies, next actions, and
completion checks. A file here does not authorize implementation. Update this
index when a plan starts, closes, or moves to the archive.

| Document | Role and status | Work authority |
|---|---|---|
| [M5: release contract for agent handlers](2026-09-27-m5-agent-handler-release-contract.md) | Accepted 2026-09-27 with decisions 1 to 5; A1 and A2 complete, A3 design note next | Owner accepted the contract on 2026-09-27 |
| [M5 A1: agent entry, admission, and grants](2026-09-27-m5-a1-agent-entry-design.md) | Implemented 2026-09-27; U1 to U4 complete | Owner accepted the design and answered its eight questions |
| [M5 A2: turn state, recorder, and cap](2026-09-27-m5-a2-turn-state-design.md) | Implemented 2026-09-27; U1 to U3 complete | Owner accepted the design and answered its eight questions |
| [M5 A3: SSE framer and strict JSON strings](2026-09-27-m5-a3-sse-framer-design.md) | Accepted 2026-09-28; U1 and U2 now, U3 after A4 | Owner accepted the design and answered its five questions |
| [M5 A4: callTool](2026-09-28-m5-a4-call-tool-design.md) | Proposed 2026-09-28; five questions for the owner | Needs owner answers before code starts |
| [Proof-checker rederive review](2026-09-24-proof-checker-rederive-review.md) | Implemented 2026-09-25; Phases 0 to 4 committed, results and section 7 leftovers at the end of the plan | Owner accepted the plan and answered its four decisions |
| [M4: release contract for scoped tool routes](2026-09-22-m4-release-contract.md) | Accepted 2026-09-22; T1a to T7 complete | Owner accepted the contract on 2026-09-22 |
| [M4 T7: reference tools and documentation](2026-09-24-m4-t7-reference-tools-design.md) | Implemented 2026-09-24; U1 to U3 complete | Owner accepted the design and answered its six questions |
| [M4 T6: credential injection](2026-09-24-m4-t6-credential-injection-design.md) | Implemented 2026-09-24; U1, U2, and U3 complete | Owner accepted the design and answered its four questions |
| [M4 T5: subject scope and tool-local grants](2026-09-23-m4-t5-scope-and-grants-design.md) | Accepted 2026-09-23; T5a and T5b implemented | Owner accepted the design and answered its four questions |
| [M4 T4: declared-label carriage](2026-09-23-m4-t4-declared-labels-design.md) | Implemented 2026-09-23 | Owner accepted the design and answered its four questions |
| [M4 T3: catalog encoding and artifact binding](2026-09-23-m4-t3-catalog-binding-design.md) | Implemented 2026-09-23 | Owner accepted the design and answered its four questions |
| [M4 T2: tool catalog and schema subset](2026-09-23-m4-t2-tool-catalog-design.md) | Implemented 2026-09-23 | Owner accepted the design and answered its four questions |
| [M4 T1b: connect and handshake deadline](2026-09-23-m4-t1b-connect-deadline-design.md) | Implemented 2026-09-23 | Owner accepted the design and answered its three questions |
| [M3: provable-set reach measurement](2026-09-21-0955-feat-provable-set-reach-plan.md) | Complete, 2026-09-21 | User approved pilot and full DeepSeek runs; [8/8 reached](../provable-reach.md#first-full-measurement) |
| [D1: type system](2026-07-30-014-d1-type-system-design.md) | Retained design reference; language phases complete | No new work scheduled |
| [D2: effects and purity](2026-07-30-015-d2-effects-purity-design.md) | Retained design reference; language phases complete | No new work scheduled |
| [D3: canonical form and wire](2026-07-30-016-d3-canonical-form-wire-design.md) | Retained design reference; language phases complete | No new work scheduled |
| [Custom LLM agent handlers](2026-09-19-feat-agent-handler-spec.md) | Proposed; baseline refreshed 2026-09-27 at `e6f33dfc`; resumed by M5 | M4 delivered its catalog, scope, and credential parts; the M5 contract states the rest |

[Archived execution records](../archive/README.md) preserve completed work,
superseded plans, and historical measurements. The reset ledger's remaining
questions are in the roadmap. The [product proposal index](../zttp-next/README.md)
and [advisory index](../../advisor-plans/README.md) classify separate proposals.

M1 is complete in the [backlog cleanup record](../archive/plans/2026-09-21-active-backlog-cleanup.md).
M2 is complete in the [bounded correctness record](../archive/plans/2026-09-21-bounded-correctness-assurance.md). M3 is complete with a retained full fresh report.
The roadmap records the proposed later milestones.

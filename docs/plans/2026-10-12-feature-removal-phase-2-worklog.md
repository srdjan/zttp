# Plan 005 Phase 2 worklog

## Objective and authority

The objective is to remove the tool-route, application-invariant, and consumer-declaration surfaces from the agent-compiler.
The origin is `advisor-plans/005-feature-removal-rebase.md`, Phase 2.
The owner selected Decision 10, "Execute Phase 2", on 2026-10-12.
That answer authorizes the selected removals and the artifact format change from 6 to 7.
The owner selected Decision 11, "Retain exports until Phase 3", on 2026-10-12.
That answer confirms the staged compiler boundary and excludes combined-phase execution or DeepSeek recording.
Phase 1 is complete at baseline `76d38e68` on local `main`.
The initial tree is clean. Thirty-three existing local commits remain unpublished.

## Constraints and scope

Preserve the eight handler properties, independent acceptance, residual guards, signing, attestation, request isolation, and path traversal checks.
Remove payload sections 8, 9, and 10 together. Refuse artifacts from the earlier format.
Keep Phase 3 language, orchestration, system linking, model-visible tool removals, and DeepSeek recording outside this execution.
Do not call a model provider, re-record a corpus, or weaken a surviving gate.
Use Zig errors and public behavior tests. Do not use Python or filtered test evidence.
Work on local `main`, commit isolated units, and never push.
Use only Sol high subagents. The main agent owns verification and canonical commits.

## Research checkpoint

Two Sol high research agents inspect the kernel and runtime dependencies.
The kernel research found that invariant removal also changes certificate layout and requires a certificate schema change.
The main agent will include that necessary internal format change in the implementation plan.
The main agent will confirm whether removing `zttp:ledger` changes frozen replay identity before fixing the execution sequence.
No product file changed and no verification command ran at this checkpoint.

Both source reports confirm an identity conflict in the origin's sequence.
`builtinRegistryHash()` hashes the ledger and tool bindings. Expert recordings and session protocol identities carry that hash.
Removing the tool rules also changes `policyHash`. The frozen corpus does not import either module, but the hashes still change.
Decision 11 asks whether the owner selects retained compiler exports until Phase 3 or combined phases with authorized DeepSeek recording.
The main agent initially proceeded with the recommended safe staging boundary as an explicit planning assumption.
The owner subsequently confirmed that boundary through Decision 11. The main agent will preserve the affected identities and call no provider.

The kernel report requires certificate schema 4 to become 5 alongside payload format 6 to 7.
The eight handler properties and the residual guard catalog remain separate from the three removed sections.
Retired section, graph-member, stage, and reason numbers must remain unused.
Kernel purity, proof-ratchet, and residual-guard checks remain. Their surviving subjects must not become empty.

The main agent read three relevant repository lessons.
`docs/solutions/security-issues/a-damaged-artifact-started-as-a-plain-runtime.md` requires refusal after artifact framing succeeds.
`docs/solutions/conventions/a-file-split-proven-by-its-graph-broke-the-gates-that-read-it-as-text.md` requires maintenance of text consumers and release markers.
`docs/solutions/conventions/a-gate-can-be-non-vacuous-and-still-porous.md` requires probes for surviving verdicts rather than counts of inputs.
The implementation plan will carry those concrete verification obligations.

The runtime follow-up confirms a possible staged boundary without replacement bindings.
Ledger exports return `ledger_unavailable` without installed module state. Tool readers and callbacks refuse without their active grants or state.
The runtime must remove both installation paths and refuse ledger-bearing or tool-bearing artifact construction before certificate encoding.
The compiler still emits `ledger_call`, so the removed kernel node must become a producer refusal, not an omitted proof operation.

Replay requires an additional denial boundary.
`registerVirtualModuleReplay` and durable wrappers can return recorded results without calling the retained binding.
The proposed phase must refuse those imports or use the normal state-free binding instead of replaying a removed operation.
That denial changes no binding metadata. Tests must show that recordings cannot restore a removed ledger effect or tool authority.

Certificate schema 4 is absent from expert and session identities. The vocabulary envelope carries it separately.
Schema 5 therefore needs envelope maintenance, but no recording by itself.
Keeping the compiler registry, rules, specifications, prompts, and provider catalog unchanged permits the existing replay in principle.
The main agent will require an actual offline replay result before claiming compatibility.

Advisor preflight returned `parent_runtime_unavailable`. No advisor consultation ran.
The Python pack resolver cannot run under repository instructions. Planning uses the repository's source and documented solutions.
Agent capacity prevents an additional lessons thread. The main agent owns that search.

## Current and next action

The implementation plan is `2026-10-12-1109-refactor-feature-removal-phase-two-plan.md`.
The dependency research and plan validation are complete. The main agent owns the current action: execute the retired-authority refusal unit.
The main agent will record direct verification results here.

## Plan validation and execution intake

All six Sol high document reviewers returned valid results with no findings, residual concerns, or deferred questions.
The reviewers covered coherence, feasibility, scope, security, product consequences, and adversarial technical assumptions.
The main agent reviewed every result and completed the confidence and contract checks.
The document review applied zero fixes. Zero proposed fixes, decisions, or FYI observations remain from that review.
The cross-model pass did not run because project instructions permit only Sol subagents.
The Python pack resolver remained unavailable. No external corroboration is claimed.

Final plan SHA-256: `5fce7f9c03b16e26c1324e7444d4b74bd8003fd10bb286ae5b15f638778bbd00`.
Execution does not edit the canonical plan body. Progress belongs here and in local commits.
Native execution is selected under the local-main and Sol high constraints.

The first small check passed with direct exit status 0: unfiltered `zig build test-proof-checker --summary all` ran 285 tests.
Unfiltered `zig build test-doc-links --summary all` also returned exit status 0 and reported "documentation links ok".
Both commands ran offline with private caches in `/private/tmp/zttp-phase2.EQ4MJ7`.
No product behavior changed before those baseline checks.

During research, another session edited and committed `CLAUDE.md` and two project skills at `349c7049`.
The main agent preserved those edits. They change no product source or reviewed dependency.
Execution therefore starts from `349c7049`, with only this run's plan and worklog untracked before activation.

## Execution checkpoint

The activation commit is `da036156`. The tree was clean after activation.
The offline baseline `zig build -j2` returned direct exit status 0.
The current policy, built-in registry, and semantics identities match the Phase 1 baselines.
The private execution directory holds the exact metadata output and model-visible source hashes.
The unfiltered `test-expert-app` baseline returned direct exit status 0: 965 tests passed and one was skipped.
Its log confirms all 19 frozen cases replayed from flow artifacts before any product edit.

The U1 worker proposes `packages/tools/src/retired_authority.zig` as the one shared predicate.
Precompile uses the helper directly. Runtime callers reach the same helper through the existing project-configuration surface.
The predicate uses contract facts, proof evidence, and explicit configuration flags. It changes no compiler registry, rule, or binding.
The main agent owns approval of any module-registration seam needed to deny replay substitution.

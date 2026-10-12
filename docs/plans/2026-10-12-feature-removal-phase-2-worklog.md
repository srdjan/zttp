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
The dependency research, plan validation, and retired-authority refusal unit are complete.
The main agent owns the current action: coordinate and review runtime and tooling removal.
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

The main agent reviewed all seven files containing the U1 test-only changes.
The unfiltered red command ran `test-cli`, `test-precompile`, `test-project-config`, and `test-zruntime` with `-j2`.
The command returned direct exit status 1. All four test artifacts compiled successfully.
The current implementation accepted retired build, configuration, source, activation, and bundle facts instead of refusing them.
Precompilation replaced the sentinel output. Replay and durable replay substituted recorded ledger successes.
The direct instance also installed tool state. These observations establish the missing denial boundaries.
The project-discovery test leaked its unexpectedly successful configuration during the red run.
The worker corrected that test cleanup before production edits. The main agent will check the correction in the green run.

The main agent authorized U1 production edits after the red result.
The approved registration seam is `HandlerInstance.installVirtualModules`; ledger and tool use normal state-free bindings there.
The worker must preserve `resolver.zig`, `trace.zig`, compiler metadata, and all recording identities.
A separate read-only agent prepares the U2 deletion census. A kernel worker prepares U3 predecessor tests without production edits.

The U2 census distinguishes the buffered `zttp:sse` binding from the removed agent transport.
The binding has no provider, credential, turn, route, or module state. Decision 11 requires its compiler identity to remain.
No new SSE-import refusal enters the shared predicate.

U3 also reaches the schema pin in `packages/proof-checker/src/policy.zig`.
The kernel worker owns that test-only pin update alongside the planned kernel files.
The main agent found another measured floor in `packages/tools/src/proof_checker_mutants.zig`.
Both kernel gates will use counts measured after subject removal, rather than their former invariant-inclusive baselines.

The main agent reviewed the six kernel files containing the U3 test-only changes.
The unfiltered `test-proof-checker` red command returned direct exit status 1 after successful compilation.
It ran 289 tests: 280 passed and nine failed for the new retirement expectations.
The decoder accepted schema 4, certificate section 11, graph kinds 17 through 20, and proof-IR tag 8.
The schema pins and retired-number checks also failed as expected. No kernel production change preceded that result.

For U1 isolation, the main agent saved the six U3 test files in `kernel-red-snapshot` under the private execution directory.
The main agent temporarily restored their baseline text before running U1 checks. The prepared U3 tests remain intact in that snapshot.
The first U1 implementation check returned direct exit status 1 at compilation.
Zig refused the helper file because both `project_config` and `zts_cli` imported that file directly.
The worker will use the named `project_config` surface and wire that dependency into the two standalone precompile roots.
No behavior verdict follows from that compilation failure.

The removal census is complete. The runtime and tooling workers have prepared disjoint U2 scopes without editing files.
The invariant author, bridges, encoders, report, and drift gate must leave with U3 because retained artifact callers still reach them.
The runtime worker also owns the retired invariant caller in `cli_shared.zig` before project methods leave.

## U1 result

The refusal unit is complete. The main agent reviewed the full diff line by line, including the retired test bodies.
The shared predicate rejects ledger/tool modules, catalogs, authentication, credentials, classification declarations, ceilings, and retired project keys.
Project discovery rejects retired keys by presence, including null values. Build and generated output refuse before writing artifacts.
Activation refuses malformed contracts instead of treating a failed parse as absent authority.
Source startup analyzes the complete module graph before replay, fixture execution, watching, scheduling, or pool initialization.
The source tests cover ledger and tool imports through local dependencies.
Live reload refuses a retired candidate. Ledger and tool bindings receive no installed state and bypass recorded-result wrappers.
Replay and durable replay tests preserve the bindings' absence-of-authority errors for both modules.

The second implementation run compiled successfully but returned exit status 1 on legacy product expectations.
The worker removed sixteen obsolete build tests and nineteen obsolete runtime tests after the main agent examined the failures.
The runtime-policy binding test now uses an ordinary handler. The producer ledger test now requires refusal before certificate construction.
The third unfiltered run returned direct exit status 0 for `test-cli`, `test-precompile`, `test-project-config`, and `test-zruntime`.
The CLI runner reported 805 passed and one skipped, with no failures, leaks, or logged errors.
The other roots reported 212 precompile tests, 39 project tests, and 526 runtime tests passed, with one runtime test skipped.

The module-boundary check returned exit status 0 without allowlist expansion.
The error-discard gate required one new reviewed row for `retiredInputFeature`.
That handler propagates allocation failure and maps all other parse failures to `InvalidContractSection`, which stops activation.
The updated `test-proof-swallow` returned exit status 0 with zero unreviewed sites.
The debug binary build returned exit status 0. Formatting and `git diff --check` passed.
The metadata and specification hash match their exact baselines. All baseline hashes of model-visible source files still match.

The six U3 tests remain saved separately during this isolated U1 check and commit.
The main agent will restore those exact test files for the later coupled format transition.
The next action belongs to the main agent: execute U2 runtime and tooling removal with the prepared ownership split.

## U2 execution checkpoint

U1 is committed locally as `601703e2`. Runtime and tooling removal now run in separate owned scopes.
The tooling cut removes public declaration flags, vocabulary tooling, reference tool examples, and their dedicated build wiring.
The invariant author and artifact drift gate remain until their U3 callers leave.

The runtime review found a credential-option boundary outside the contract predicate.
An ordinary `fetch(url, { credential: "name" })` has no tool catalog or project reference for the predicate to inspect.
The compiler records credential use only within tool or agent routes. Native option parsing must therefore refuse this retained call shape.
Recorded-result substitution can bypass that native refusal, so the refusal must also run before replay and durable wrappers.
The worker proposed normal registration for the complete fetch binding. The main agent's source review rejected that mechanism.
Replay already uses the native path for `fetch`, but it stubs `fetchWithRetry`. Durable recording still relies on its outer wrapper.
Normal registration for the entire binding would remove retained durable behavior. The runtime worker will propose a smaller outer guard.
The advisor preflight again returned `parent_runtime_unavailable`. No consultation or model-provider call ran.

The main agent authorized replay and durable registration overloads with an outer native-function guard.
Existing registrations use an identity guard. Handler registration selects the credential guard only for fetch exports.
The global fetch callback receives the same guard outside its selected wrapper. Compiler bindings and trace identities stay unchanged.

The main agent reviewed the full U2 runtime and tooling diff line by line.
The first unfiltered check returned exit status 1 because four removed-state references remained.
The worker removed those references and all remaining nested-tool branches.
The review also found three ordinary network tests inside the removed credential test block.
The worker preserved retry, bodyless-send, and service-call assertions with the ordinary HTTP test server.
The ordinary replay control moved from the deleted agent replay module into `replay_runner.zig`.

The second unfiltered run passed server, project configuration, precompile, and ZTS CLI checks.
CLI still expected the retired agent round budget in one fixture test. That obsolete expectation will leave.
The separate runtime check returned exit status 1: the credential test expected three response-body matches and found two.
The worker will assert each export's public response shape separately before the main agent repeats that check.
The example census contains 60 surviving TypeScript sources after the approved tool example leaves.
The pipeline mutation floor now names those 60 sources. The corpus floor and mutation checks stay unchanged.
The module-boundary and proof-error-discard checks returned direct exit status 0 without any allowlist change.
The main agent delegated live documentation cleanup separately. No compiler-visible source enters that scope.

## U2 result

The runtime removal unit is complete. It deletes seven dedicated runtime files, vocabulary tooling, and the tool example.
The runtime keeps ordinary routing, fetch, durable execution, queues, buffered SSE, pool isolation, and static path checks.
Credential options refuse before replay and durable substitution. The tests assert each export's exact public error and details.
The final runtime check returned direct exit status 0: 432 tests passed and one was skipped.
The final CLI check returned direct exit status 0: 725 tests passed and one was skipped, with no failures or leaks.
The server, project configuration, precompile, and ZTS CLI checks already passed their second unfiltered run.
The binary build, module-boundary check, and proof-error-discard check returned direct exit status 0.
Current metadata and specification output match the exact baselines. All baseline hashes of model-visible source files still match.
No provider call ran. The compiler export removal remains deferred to Phase 3.
The main agent owns the next action: restore the prepared predecessor tests and execute the coupled codec removal.

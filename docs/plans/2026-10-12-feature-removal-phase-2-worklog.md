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
All four units are complete. Runtime authority, artifact sections, and their unsupported documentation are removed.
The full offline verification script and focused mutation gate pass. The final artifact smoke test passes.
The owner owns the next action: review and publish the local commits. Phase 3 needs separate authorization.

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

## U3 execution checkpoint

U2 is committed locally as `facee936`. The main agent restored the six prepared kernel test files from their exact snapshots.
The kernel worker added separate custom-policy cases that explicitly offer schema 4 to the decoder and checker.
The second unfiltered kernel red run returned direct exit status 1 after successful compilation.
It ran 291 tests: 280 passed and eleven failed for the retirement expectations.
The runtime worker added literal format-6 trailer and bundle cases, plus raw payload tags 8, 9, and 10.
The unfiltered CLI red run compiled successfully and returned direct exit status 1: four new format expectations failed.
The existing reader accepted the format-6 trailer and retired tags. Bundle paths reached corruption instead of format refusal.
The main agent reviewed the test-only diffs and authorized the coupled production changes in the kernel and runtime.
The main agent owns gate maintenance, measured floors, allowlists, verification, and local commits.
The current action is removal of retired artifact sections. Compiler exports and recording identities remain at baseline.

The first smaller-kernel run compiled and ran 189 tests. Only the old wire hash and work-count fixture pins failed.
The main agent measured the new all-sections encoding: 799 bytes, with SHA-256 `163d373677496c96f5edad35f56cce5535d0ecf7f5a942a87ba7fa0b4d1f5f03`.
The system `shasum` command independently confirmed that hash over the captured fixture bytes.
The actual decode counter spent 96 work units. The updated test accepts 96 and refuses 95.
The main agent removed all temporary measurement prints before the next check.
The surviving kernel census contains 13 source files, 189 test blocks, and 71 reason codes.
Both floor gates now require the measured surviving suite. Reason coverage still iterates every surviving reason code.

The first full mutation run found eleven non-equivalent survivors after the retired decoder tests left.
Ten survivors changed public wire behavior. One survivor rejected adjacent positive emission ranges that share a boundary.
The kernel worker restored that behavior coverage through public APIs, without changing production code or mutant exemptions.
The unfiltered kernel suite passed all 195 tests. That mutation run rejected all 160 non-equivalent rows in its incomplete manifest.
Eight existing equivalent rows remained. The run reported no timeout, compilation failure, missing anchor, or harness error.
The final purity floor is 13 files and 195 tests. The reason census still contains 71 members.
The safety gate measured 248 non-test function bodies across 13 files. Its updated floors and ReleaseFast probes passed.
The proof-ratchet root needed the existing project-configuration module import. With that dependency, all 38 tests passed.

The first runtime checks passed the unfiltered CLI, server, and precompile steps.
The CLI reported 685 passed, one skipped, and no failures, leaks, or logged errors.
The standalone runtime step passed 416 tests and skipped one. Retained compiler and contract-golden checks also passed.
The module-boundary gate passed with 59 allowed reaches. Five unused rows left with their retired consumers.
The proof-error-discard gate passed with 176 reviewed swallows, 96 silent arms, and no unreviewed sites.
Six unused rows left with their deleted checks. No replacement exemption entered either allowlist.
Step coverage passed with 87 steps and 12 manual steps. Script reachability passed with 43 scripts and three manual scripts.
The binary build passed. Documentation links, drift, and release checks passed after the nine stopped-plan index links left.

The frozen replay completed all 19 cases offline. The combined expert and documentation command failed only on those stale index links.
The command reported 2259 passed and one skipped across its test roots. No provider call ran.
The final metadata, specification hash, and baseline source hashes still match exactly.

The main agent built an ordinary artifact with format 7. The artifact passed acceptance and served `phase2 ordinary` with HTTP 200.
A copy with literal trailer format 6 returned exit status 1 and rebuild guidance beside a valid source handler.
No pool initialized and no source fallback served that copy. Existing binaries retain their own embedded runtime.

Three omission probes compiled successfully and returned direct exit status 1.
The format-version omission failed three CLI tests. The replay-denial omission failed the ledger and tool replay tests.
The acceptance omission failed ordinary promotion and generation-retirement tests. Each exact source snapshot was restored and compared.
Final restored checks follow the remaining behavior-preserving cleanup.

## Review checkpoint

The main agent reviewed the U3 production diff and deleted code line by line.
The `ce-simplify-code` pass ran reuse, quality, and efficiency reviews through Sol high agents.
The reuse review identified empty fact merges. The quality review identified unused runtime metadata, request-ceiling, and facade paths.
The main agent accepted their bounded removal while preserving compiler and native identities.
The repeated bundle read predates this phase. Its replacement needs separate integrity and allocation-order evidence, so it remains unchanged.
The proposed policy-analysis reuse also needs error-order and source-snapshot evidence. This phase preserves the two existing validation boundaries.

Code review: skipped (ce-code-review unavailable).
The skill requires `review-scope.py` and `run-log.py`; repository instructions prohibit Python.
Native final reviews supplement the main agent's review, but do not supply that skill's receipt.
The completion advisor preflight returned `parent_runtime_unavailable`. No consultation process started.

The artifact review found two pre-existing decoder gaps within the strict-reader requirements.
A payload without section 4 supplied default runtime policy. A short dependency section supplied zero dependencies and ignored trailing bytes.
The main agent confirmed both parse failures through public tests before production changes.
The unfiltered CLI red check compiled successfully: 686 tests passed, one skipped, and two failed without leaks or logged errors.
The reader now requires bytecode and policy section 4. Dependency parsing requires complete count, length, body, and exact section consumption.
Separate positive tests preserve a complete empty dependency section and ordinary policy-bearing payloads.
These fixes change no compiler identity and add no runtime authority.

The runtime review found another pre-pool refusal gap in `SystemRuntime.addHandler`.
Only the primary handler passed the source refusal predicate. A system target could reach its pool with a retired import.
State-free bindings still refused operations, but the plan requires refusal before target pool creation.
The main agent authorized public target and local-dependency refusal tests before adding the same predicate at that shared boundary.
System linking and ordinary workflow dispatch remain within the retained product scope.

The first full verification run found missing helper imports in the benchmark runtime and rollout test roots.
The main agent added their existing project-configuration module dependency. The focused rollout check returned direct exit status 0.
The first full script stopped with direct exit status 130 after those failures were identified.
It supplies no final verification claim. The main agent will rerun the full script after the review fixes pass.

The decoder green check returned direct exit status 0. All 690 CLI tests passed, one skipped, and no failures or leaks appeared.
The artifact reviewer re-read the narrow fixes and confirmed both decoder findings closed. The reviewer found no new issue in that scope.

The system-target red check compiled and returned direct exit status 1: 410 passed, two skipped, and two failed.
Both public calls unexpectedly registered targets. The new guard runs after graph-aware extraction and before projection, allocations, and pool creation.
The green server check returned direct exit status 0: 412 passed and two skipped.
Its direct and dependency cases each test both retained retired modules. The boundary and error-discard gates also passed.
The runtime reviewer re-read the guard and confirmed the original finding closed, with no additional supported bug.
Both final reviews were source-only. The main agent owns their acceptance and all execution evidence.
The final full verification script now runs against the reviewed fixes, with no provider key and private caches.

That run found the same missing named helper in the diagnostic-corpus test root.
The main agent added the existing project-configuration import in `build/corpus.zig` and stopped that script with exit status 130.
A Sol high explorer now checks all build roots that reach the helper. No product rule or recording identity changes for this wiring fix.
The final verification verdict remains pending until the complete script passes.

The build census found two more roots that need the existing `project_config` import: flow census and expert tripwires.
The main agent reviewed and added both contexts. The diagnostic-corpus check returned direct exit status 0.
The main agent also corrected a mistaken mutant removal. V6 tests retained guard coverage, not application invariants.
The restored manifest has 169 rows. The final mutation gate returned direct exit status 0.
All 161 non-equivalent mutations failed. The eight existing equivalence rows survived; no timeout, compilation, matching, or harness error appeared.
The focused flow-census and expert checks returned direct exit status 0: all 231 tests passed.
All 776 flow probes matched, with no fail-open, over-refusal, weak result, or missing verdict.
The final source audit accounts for all 118 removed mutation IDs. Each ID covers a fully retired subject.
The retained capability-call mutation remains adapted to its current source. V6 remains against `GuardVerdicts.ready`.

The simplification pass applied two reuse findings, four quality findings, and zero efficiency findings.
The fourth quality finding was partial: the unused constant left, but the proposed general fact helpers did not enter.
Three suggestions remain outside this phase: general fact helpers, bundle-read consolidation, and policy-analysis reuse.
The main agent reviewed every applied cleanup diff line by line.
The restored CLI check passed 685 tests and skipped one, with no failures, leaks, or logged errors.
The restored server check passed 405 tests and skipped two. The precompiler passed all 212 tests.
The module-boundary and proof-error-discard checks passed again. No ordinary acceptance or replay-denial mutation remains in source.

## Final closure

The per-commit command `bash scripts/verify.sh` returned direct exit status 0 with private caches and no `DEEPSEEK_API_KEY`.
The aggregate suite, standalone runtime suite, ReleaseFast build, verified handler precompilation, smoke tests, panic isolation, repository gates, and formatting passed.
The final mutation gate also returned direct exit status 0: 169 rows, 161 rejected non-equivalent mutations, and eight existing equivalents.
The kernel retains eight properties, the residual catalog, and its 195-test floor. No omission probe remains in product source.

The final ordinary build returned exit status 0 with `--no-attest`. Its trailer carries payload format 7.
The artifact passed acceptance, initialized its pool, and returned HTTP 200 with the exact body `phase2 ordinary`.
The main agent closed the server with exit status 0 after that response.
An otherwise identical copy with trailer format 6 returned exit status 1 and rebuild guidance before pool creation.
The valid source handler beside that copy did not become a fallback.
Public kernel checks also refuse schema 4 and accept schema 5 under the exact compiled schema boundary.

Final metadata and specification outputs match their exact baselines. Every protected source hash matches its baseline.
The nineteen-case authoring corpus replayed offline. No provider ran, and no frozen recording changed.
The only compiler module edits add runtime refusal guards in the resolver and expose their existing registration seam.
Compiler bindings, rules, specifications, prompts, registry order, and provider catalog remain under the Phase 3 boundary.

The main agent reviewed all production changes and removed bodies line by line. Native Sol reviews confirmed the final decoder and runtime fixes.
The worklog records the unavailable code-review and advisor tools above. Those tools supply no completion receipt.
After status closure, documentation links, documentation drift, and release-marker checks returned direct exit status 0; all fourteen tests passed.
U1 is committed as `601703e2`. U2 is committed as `facee936`. U3 is committed as `962eb538`.
U4 records final evidence and updates documentation in a separate local commit. The main agent never pushes.

## Recount method and deletion ledger

The comparison starts at `349c7049`, before Phase 2 activation. It excludes the other session's earlier instruction and skill commit.
The product scope includes `packages/`, `build.zig`, `build/`, `scripts/`, `examples/`, and `tooling/`.
After the review fixes, that scope changes 88 files: 1540 added lines, 28722 removed lines, and 27182 net fewer lines.
It deletes 26 whole files. The source-only subset selects `.zig`, `.sh`, and `.ts` files within that product scope.
That subset changes 79 files: 1526 added lines, 28452 removed lines, and 26926 net fewer lines.
It deletes the 22 source files listed below. These counts include tests and comments; they make no performance claim.
The commands are `git diff --numstat 349c7049 -- <scope>` and `git diff --name-only --diff-filter=D 349c7049 -- <scope>`.
The main agent sums the tab-separated counts with `awk` and counts the complete deletion list.
Every listed removed path exists at the `pre-rebase` tag. The tag check returned direct exit status 0.
The other four product deletions are `examples/tools/README.md`, `declaration.json`, `policy.json`, and `zttp.json`.
All four paths belong to the deleted reference tool application.

| Removed source file | Retired subject |
|---|---|
| `examples/tools/tools.ts` | Reference tool application |
| `packages/proof-checker/src/declaration.zig` | Consumer declaration decoder |
| `packages/proof-checker/src/invariant.zig` | Application invariant kernel |
| `packages/proof-checker/src/tool_catalog.zig` | Tool and agent catalog decoder |
| `packages/runtime/src/credential_store.zig` | Credential installation |
| `packages/runtime/src/invariant_adapter.zig` | Protected adapter binding |
| `packages/runtime/src/invariant_cli.zig` | Invariant CLI and classifier transport |
| `packages/runtime/src/invariant_observer.zig` | Ledger operation observation |
| `packages/runtime/src/proofs/invariant_report.zig` | Invariant status renderer |
| `packages/runtime/src/reference_tools_check.zig` | Reference tool gate |
| `packages/runtime/src/replay_turn.zig` | Agent turn replay |
| `packages/runtime/src/tool_auth.zig` | Tool authentication |
| `packages/runtime/src/turn_recorder.zig` | Agent turn recorder |
| `packages/runtime/src/turn_state.zig` | Agent turn state |
| `packages/tools/src/declaration_encoding_test.zig` | Declaration wire round trip |
| `packages/tools/src/invariant_author.zig` | Invariant author and classifier request |
| `packages/tools/src/invariant_config.zig` | Invariant configuration encoder |
| `packages/tools/src/invariant_drift_gate.zig` | Invariant drift gate |
| `packages/tools/src/tool_catalog_encoding.zig` | Catalog artifact encoder |
| `packages/tools/src/vocab_envelope.zig` | Vocabulary envelope command |
| `packages/tools/src/vocab_envelope_gate.zig` | Vocabulary envelope gate |
| `scripts/check-invariants.sh` | Standalone invariant gate wrapper |

The documentation scope removes twelve whole files: the live consumer guide, its envelope, the envelope plan, and nine stopped subject plans.
Historical citations use `pre-rebase:`. The plan index retains the M4 and M5 acceptance history through the roadmap and historical references.

| Removed documentation file | Retired subject |
|---|---|
| `docs/consumer-contract.md` | Consumer declaration guide |
| `docs/consumer-contract-envelope.json` | Published vocabulary envelope |
| `docs/plans/vocabulary-envelope.md` | Envelope plan |
| `docs/plans/2026-09-19-feat-agent-handler-spec.md` | Agent handler proposal |
| `docs/plans/2026-09-22-m4-release-contract.md` | Tool-route release contract |
| `docs/plans/2026-09-23-m4-t2-tool-catalog-design.md` | Tool catalog design |
| `docs/plans/2026-09-23-m4-t3-catalog-binding-design.md` | Catalog binding design |
| `docs/plans/2026-09-23-m4-t4-declared-labels-design.md` | Declared-label design |
| `docs/plans/2026-09-23-m4-t5-scope-and-grants-design.md` | Tool scope and grants |
| `docs/plans/2026-09-24-m4-t6-credential-injection-design.md` | Credential injection design |
| `docs/plans/2026-09-27-m5-agent-handler-release-contract.md` | Agent release contract |
| `docs/plans/2026-09-28-m5-a5-reference-agent-design.md` | Stopped reference agent design |

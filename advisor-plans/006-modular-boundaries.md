# Plan 006: make analysis and runtime ownership explicit

Status: COMPLETE in the isolated worktree; all five phases independently reviewed and final verification passed on 2026-10-22. Implementation authorized by the owner's “go ahead in phases”.
Planned at: `5e793ead`. Category: architecture. Priority: P1. Effort: L. Risk: high across the entire sequence; each phase has a separate verification boundary.

Implementation workspace: `/Users/srdjans/Code/_TEAMOK/ZTTP-modular-boundaries`, branch `codex/modular-boundaries`.
The advisor reviewed the isolated diff. The implementation scope initially excluded staging and commits; the owner subsequently authorized a local commit with “commit”. Merging, publication, and copying source into the primary checkout remain outside that instruction.

## Why this matters

Several file boundaries still expose a whole runtime owner, repeat immutable import identification, or depend on mutable inputs being installed in a particular order. A handler change can therefore require coordinated edits in analysis, registration, pool lifecycle, and server metadata. These phases give each responsibility a smaller owner while preserving source behavior, diagnostics, contract bytes, registry identity, and independent proof authority.

## Drift and prerequisites

Before phase 1, confirm `git rev-parse --short HEAD` is `5e793ead` and `git status --short` is empty in the implementation workspace. For later phases, inspect the accumulated diff and re-open the cited symbols. Protect all preceding approved phase changes. The advisor controls phase advancement.

Baseline structural checks passed in the primary checkout: `zig build test-module-boundary test-zts-layering test-proof-checker-purity check-spine`. This is not a behavioral baseline. Run the phase's named behavioral suites before editing, retain exit statuses and logs, and compare with the post-change runs.

Read root and area AGENTS.md, docs/decisions.md, .agents/skills/zig-expert/SKILL.md and .agents/skills/zttp-build/SKILL.md. Use native Zig error unions and explicit allocator/borrow lifetimes. No Python, dependency installation, generated-output edits, filter-based acceptance evidence, or unrelated cleanup.

## Standing compatibility boundaries

- D-004: interpreter execution remains the only execution path.
- D-005: proof-checker remains an independent leaf; never reuse producer proof decisions as acceptance authority.
- D-006: CHECK flow and fault traversals retain distinct read order, repeated reads, revision selection, and stopping rules.
- D-007: persistent reads retain unknown provenance.
- Loaded-graph sound extraction and contract-only extraction retain their different authored-type and policy/SQL semantics (H7 in docs/plans/2026-10-20-hardening-pruning-plan.md).
- Preserve existing wire formats, digest preimages, export ordering, diagnostics and public APIs. Internal session misuse may be refused as explicitly approved in phase 1.

## Phase 1: freeze effect-producing dependency inputs

Scope: packages/zts/src/pipeline.zig, its immediate callers in packages/tools/src/precompile.zig if necessary, and directly relevant repo documentation.

Current state: ModuleAnalysisSession.pathEffectFacts (pipeline.zig:943) caches using contract_context.imported_effects; setContractContext/setImportedEffects (:1042–1058) can change those inputs while extraction_state is ready. The session test (:2089) permits requesting cached facts before a setter. Legitimate import assembly happens after complete(), so completion is not the freeze point.

Steps:
1. Characterize current callers and run the phase baseline.
2. Separate effect dependency inputs from later extraction metadata as needed. Refuse imported-effect mutation after any dependent facts have been requested, including an unavailable cached attempt. Preserve pre-publication injection and later verification/dispatch metadata updates where inputs do not change. Prefer a small explicit state transition over a new pass framework or cache revision layer.
3. Add meaningful tests using different imported summaries: pre-publication injection affects the result, late mutation cannot diverge contract/path inputs, and failed fact computation does not reopen mutation. Retain the one-attempt and unavailable behavior.
4. Promote this approved delivery record into docs/plans/2026-10-22-modular-boundaries-plan.md in the isolated worktree; update docs/plans/README.md and docs/roadmap.md narrowly. Record phase status and actual validation there.

Verify before and after: `zig build test-zts`, `zig build test-precompile`, `zig build test-contract-golden`, `zig build test-flow-census`. Run `zig build test-proof-swallow` if affected analysis handling changes. Preserve original golden assertions.

Done: dependency changes cannot invalidate already-published facts, production caller order works, all named suites pass, and diff remains bounded.

## Phase 2: own HTTP state behind a one-way boundary

Scope: packages/runtime/src/handler_instance.zig, runtime_http.zig, runtime_natives.zig, runtime_builtins.zig, runtime_config.zig and a new HTTP state/bindings file if justified; directly affected runtime tests and architecture documentation. Build roots only if a new file needs explicit test anchoring.

Current state: handler_instance.zig imports runtime_http.zig (:23), which imports the instance back (:14). runtime_http.beginBodyRead (:52) edits consumed_body_objects; handler reset/release (:1766, :1797) clears it. runtime_natives (:61, :249) depends on HandlerInstance for header conversion and integer parsing.

Steps:
1. Move pure header/integer helpers to their natural helper owner and remove runtime_natives' reverse import. Preserve behavior exactly.
2. Give HTTP request-lifetime state a concrete owner. It owns consumed-body tracking and borrows context-owned prototype objects; installation and cleanup must preserve builtin-object ownership. HandlerInstance composes it.
3. HTTP implementation receives narrow state/context, configuration, and transport inputs rather than HandlerInstance. Native host recovery may remain in thin HandlerInstance composition adapters. Preserve context-local authorization; no thread-local host fallback or bare state-envelope substitution.
4. Centralize reset/deinit in the HTTP owner; use it from both lifecycle paths.

Verify before and after: `zig build test-zruntime`, `zig build test-server`, `zig build test-panic-isolation`, `zig build test-module-scope-panic`, `zig build test-runtime-purity`, `zig build test-module-boundary`. Keep pool-heavy roots in separate processes as repository guidance requires. Tests must cover body re-read refusal, next-request reuse, and cleanup, using existing meaningful cases where sufficient.

Done: runtime_http and runtime_natives no longer import HandlerInstance; HTTP state has one lifecycle owner; named suites pass. If eliminating the full runtime_http reverse dependency needs a broader transport redesign, report the exact remaining reaches for reviewer adjustment before proceeding.

## Phase 3: reuse immutable import identity

Scope: packages/zts/src/module_facts.zig, type_checker.zig, strict_checker.zig, pipeline.zig and their direct construction callers/tests. Retain flow_interp's mutation-sensitive semantics.

Current state: TypeChecker.resolveImportedExport (:3650) scans import IR using binding slot, kind, named-import kind and original export. StrictChecker.importedFunctionForCallee (:2011) uses raw slots. ModuleFacts.importForReference (:319) already provides explicit eligibility/filter/order policies, but ImportRecord lacks full binding identity.

Steps:
1. Extend the existing import index with sufficient immutable binding/import identity to preserve the type checker's exact lookup policy.
2. Route the type checker through that index, with one ownership path and no duplicate facts construction per call. Preserve consumer-specific eligibility and matching order. Migrate strict's immutable identity only if its existing policy can be preserved directly.
3. Remove the superseded type-checker full-IR scan. Keep reassignment/shadow analysis in flow interpreter and checker-specific conclusions separate.
4. Pin aliases, same-name locals, shadowing, binding-kind differences, and unknown-module contrasts through behavioral tests.

Verify before and after: `zig build test-zts`, `zig build test-precompile`, `zig build test-diagnostic-corpus`, `zig build test-contract-golden`, `zig build test-flow-census`, `zig build test-module-boundary`, `zig build test-zts-layering`.

Done: immutable import identity has one producer, the type checker no longer re-scans imports for each lookup, and existing differing policies and public outputs remain intact.

## Phase 4: separate static descriptors from runtime bindings

Scope: packages/zttp-sdk/src/binding.zig; packages/zts/src/module_binding/types.zig, module_binding_adapter.zig, builtin_modules.zig, module_facts.zig, module_types.zig, type_checker.zig; the smallest new descriptor module and tier/build registration if needed; directly affected modules/registry tests and documentation.

Current state: engine FunctionBinding (:223) combines NativeFn/ModuleFn pointers with metadata. ModuleBinding (:365) combines exports with state callbacks. TypeChecker.resolveImportedExport names the runtime registry's return shape. BindingHasher.foldExport in module_manifest.zig (:283) hashes callback presence; preserve that preimage and all ordering.

Steps:
1. Expose a metadata-only descriptor lookup, initially derived at comptime from existing bindings, and migrate the type checker to it.
2. Establish one semantic descriptor definition shared by SDK and engine registration where compatible; runtime registration pairs descriptor identity with callbacks and state lifecycle. Avoid manually synchronized duplicate semantic tables.
3. Demonstrate a real removed implementation dependency in the chosen static consumer. Do not claim the entire compiler is engine-independent: IR and atom ownership remain engine concerns.
4. Preserve registry identity, hash serialization, callback-envelope validation and authorization. Keep independent acceptance catalog separate. Retain source-compatible declaration adapters where SDK compatibility requires them, without a second runtime semantic authority.

Verify before and after: `zig build test-sdk`, `zig build test-modules`, `zig build test-zts`, `zig build test-module-governance`, `zig build test-capability-audit`, `zig build test-flow-census`, `zig build test-contract-golden`, `zig build test-runtime-purity`, `zig build test-module-boundary`, `zig build test-zts-layering`; runtime suites when registration changes.

Done: the selected static consumer only sees descriptors, descriptor/runtime pair completeness is checked, and hashes, metadata, contracts and authorization behavior are unchanged. This is a bounded first consumer; broad consumer migration follows only after its benefit is verified.

## Phase 5: centralize generation transition ownership

Scope: packages/runtime/src/server.zig, live_reload.zig, runtime_pool.zig, runtime_policy_generation.zig, contract_runtime.zig; a narrow generation owner module if justified, related runtime tests and documentation. proof_activation.zig may be adapted at its call boundary without changing acceptance semantics. Do not edit proof-checker logic.

Current state: live_reload.zig:686–726 stages a contract and policy, replaces the pool, transfers source ownership, rotates source generations, then updates/invalidate server metadata. The source-retirement ordering race is documented at :703. Server.updateContract (:1272), invalidateContractCaches (:1310), and startup (:1738, :1825) coordinate derived state independently. RuntimePolicyGeneration already owns/refcounts policy; reuse it.

Steps:
1. Consolidate server contract/proof/cache/attestation invalidation and derive serving settings through a single explicit operation used by startup and replacement where their semantics agree.
2. Introduce staged generation preparation holding the needed executable/source ownership, contract, optional proof acceptance and derived enforcement metadata. Distinguish source/dev and accepted-artifact evidence.
3. Give the server one replacement operation that coordinates policy/pool installation, source ownership transfer and contract-derived metadata installation with existing lock ordering. Keep fallible preparation before mutation. On refusal retain the active generation. Retire old storage only after existing readers no longer use it; preserve existing request pins and policy refs.
4. Make the watcher submit a prepared candidate instead of directly sequencing pool/server mutation. Keep acceptance-before-pool on startup, guarded-generation live-reload refusal, and certificate-free clearing of proof authority.
5. Add transition tests: failed candidate preserves code/policy/contract; a successful source replacement clears old proof authority and stale routes/cache/attestation; old request references remain valid through replacement/retirement.

Verify before and after: `zig build test-server`, `zig build test-zruntime`, `zig build test-proof-checker`, `zig build test-proof-checker-purity`, `zig build test-proof-ratchet`, `zig build test-proof-swallow`, `zig build test-panic-isolation`. Reuse existing tests and assertions before adding new mechanisms.

Done: one owner sequences replacement and retirement, watcher no longer coordinates independent mutations, rejection retains the current generation, and all named checks pass.

## Final gate and review

After each phase inspect the entire new diff for scope and behavior drift. After all approved phases run `zig build test`, `zig build check-spine`, and `bash scripts/verify.sh` using sequential repository guidance. Capture logs directly and retain each command's exit status; do not report a pipe's last command as a build verdict. Keep changes uncommitted until the owner requests a commit. Record exact passing/failing/skipped checks and any remaining limitations in the active worktree plan.

The advisor independently inspects changes and relevant test assertions before each advance, then re-runs appropriate checks. The advisor alone updates this advisory plan's status.

## Stop conditions

- An unexplained baseline failure blocks parity claims until diagnosed; report it before expanding scope.
- A proposed extraction changes public behavior, wire bytes, registry hashes, proof grades or policy authority: stop for reviewer assessment, do not update goldens to match.
- Required edits exceed the current phase scope, or collide with active soundness work: stop and report concrete paths and rationale.
- Missing dependencies, tools, credentials, or a failing gate that remains unexplained after two reasonable corrections: report exact evidence.
- No performance claims without measurement; no new generic visitor, framework, event bus, or provider abstraction.

## Progress

| Phase | Status |
|---|---|
| 1 Analysis inputs | APPROVED; source/tests reviewed; focused suites, proof-swallow, spine and links pass |
| 2 HTTP owner | APPROVED; source/tests reviewed; runtime, server, panic, purity, boundary, spine and link checks pass |
| 3 Import identity | APPROVED; source/tests reviewed; analyzer, precompile, corpus, goldens, census and structural checks pass |
| 4 Static descriptors | APPROVED; schema, consumer, parity and build-root changes reviewed; named suites, pins, goldens and structural checks pass |
| 5 Generation transition | APPROVED; transition/source ownership/settings and regression assertions reviewed; focused runtime/proof/isolation/structural checks pass |

## Independent final verification

All commands ran against the frozen implementation worktree with Zig 0.16.0 from `/Users/srdjans/.zvm/bin` and exited 0:

- `zig build test -j2 --summary all`: 200/200 build steps succeeded; 9084/9090 tests passed, 6 skipped. CLI: 618 passed, 1 skipped, no failures or leaks. Receipt: `/tmp/zttp-modular-final-test.log`.
- `zig build check-spine --summary all`: 4/4 steps succeeded. Receipt: `/tmp/zttp-modular-final-spine.log`.
- `bash scripts/verify.sh`: all per-commit gates passed, including its sequential aggregate, standalone runtime, ReleaseFast binaries, verified handler precompilation, v1 smoke, isolation, specification, registry and formatting checks. Receipt: `/tmp/zttp-modular-final-verify.log`.
- `zig fmt --check build.zig build/ packages/ tooling/`: passed independently. Receipt: `/tmp/zttp-modular-final-format.log`.

The active delivery record is `docs/plans/2026-10-22-modular-boundaries-plan.md` in the implementation worktree on `codex/modular-boundaries`. The owner authorized a local commit after verification; no product source was copied into the primary checkout. This validates the approved modularity work, without a release-readiness or performance claim.

# Modular boundaries delivery plan

Status: approved for phased implementation by the owner's “go ahead in phases” on 2026-10-22. Complete, 2026-10-22. All five phases are implemented, independently reviewed, and verified by their focused gates, the final aggregate, and the canonical full sequential gate.
Planned at: `5e793ead`. Category: architecture. Priority: P1. Effort: L. Risk: high across the entire sequence; each phase has a separate verification boundary.

Implementation workspace: `/Users/srdjans/Code/_TEAMOK/ZTTP-modular-boundaries`, branch `codex/modular-boundaries`.
The advisor reviews the isolated diff. This plan originally excluded staging and commits; the owner subsequently instructed “commit”, authorizing local staging and a commit in this isolated worktree only. Merging, pushing, publication, and copying source into the primary checkout remain unauthorized.

## Why this matters

Several file boundaries still expose a whole runtime owner, repeat immutable import identification, or depend on mutable inputs being installed in a particular order. A handler change can therefore require coordinated edits in analysis, registration, pool lifecycle, and server metadata. These phases give each responsibility a smaller owner while preserving source behavior, diagnostics, contract bytes, registry identity, and independent proof authority.

## Drift and prerequisites

Before phase 1, confirm `git rev-parse --short HEAD` is `5e793ead` and `git status --short` contains only the expected copied advisory plan. For later phases, inspect the accumulated diff and re-open the cited symbols. Protect all preceding approved phase changes. The advisor controls phase advancement.

Baseline structural checks passed in the primary checkout: `zig build test-module-boundary test-zts-layering test-proof-checker-purity check-spine`. This is not a behavioral baseline. Run the phase's named behavioral suites before editing, retain exit statuses and logs, and compare with the post-change runs.

Read root and area AGENTS.md, docs/decisions.md, .agents/skills/zig-expert/SKILL.md and .agents/skills/zttp-build/SKILL.md. Use native Zig error unions and explicit allocator/borrow lifetimes. No Python, dependency installation, generated-output edits, filter-based acceptance evidence, or unrelated cleanup.

## Standing compatibility boundaries

- D-004: interpreter execution remains the only execution path.
- D-005: proof-checker remains an independent leaf; never reuse producer proof decisions as acceptance authority.
- D-006: CHECK flow and fault traversals retain distinct read order, repeated reads, revision selection, and stopping rules.
- D-007: persistent reads retain unknown provenance.
- Loaded-graph sound extraction and contract-only extraction retain their different authored-type and policy/SQL semantics (H7 in `pre-reset-archive-2026-10-25:docs/plans/2026-10-20-hardening-pruning-plan.md`).
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

After each phase inspect the entire new diff for scope and behavior drift. After all approved phases run `zig build test`, `zig build check-spine`, and `bash scripts/verify.sh` using sequential repository guidance. Capture logs directly and retain each command's exit status; do not report a pipe's last command as a build verdict. Keep changes uncommitted through verification; subsequent local commit authorization is recorded above. Record exact passing/failing/skipped checks and any remaining limitations in the active worktree plan.

The advisor independently inspects changes and relevant test assertions before each advance, then re-runs appropriate checks. The advisor alone updates the source advisory plan's status; this delivery record tracks implementation and validation.

## Stop conditions

- An unexplained baseline failure blocks parity claims until diagnosed; report it before expanding scope.
- A proposed extraction changes public behavior, wire bytes, registry hashes, proof grades or policy authority: stop for reviewer assessment, do not update goldens to match.
- Required edits exceed the current phase scope, or collide with active soundness work: stop and report concrete paths and rationale.
- Missing dependencies, tools, credentials, or a failing gate that remains unexplained after two reasonable corrections: report exact evidence.
- No performance claims without measurement; no new generic visitor, framework, event bus, or provider abstraction.

## Progress

| Phase | Status |
|---|---|
| 1 Analysis inputs | Complete, 2026-10-22; source reviewed and named checks passed |
| 2 HTTP owner | Complete, 2026-10-22; source reviewed and named checks passed |
| 3 Import identity | Complete, 2026-10-22; source reviewed and named checks passed |
| 4 Static descriptors | Complete, 2026-10-22; source reviewed and named checks passed |
| 5 Generation transition | Complete, 2026-10-22; source reviewed and focused checks passed |
| Final delivery verification | Complete, 2026-10-22; independent aggregate, spine, full verification and formatting passed |

## Phase 1 implementation record

The isolated worktree started at `5e793ead`, with only the expected copied
advisory plan untracked. Builds use the installed Zig 0.16.0 toolchain through
`PATH=/Users/srdjans/.zvm/bin:$PATH`; the default login PATH selected Zig 0.17.0
and failed before building repository tests. No toolchain was installed or
repository compatibility changed.

The session now uses its existing path-effect cache state to reject dependency
changes after the first request. Both setters compare ordered slots, result
kinds, and effect rows. Equivalent dependencies permit later verification and
dispatch metadata. An unavailable cached result also freezes dependencies.
Imported summaries remain immutable borrows; the guard does not copy them or
detect mutation through a caller's separate alias.

Tests inject different clean and writing sibling summaries after completion,
then assert the path row and extracted contract agree in all three profiles.
They also check rejected setters leave context unchanged, equivalent rows in
separate storage permit metadata updates, callable/data/blocked kinds and slots
remain distinct, and allocation failure does not reopen dependency mutation.
Production caller order already satisfies this boundary; no caller changes
were needed. Existing golden assertions remain unchanged.

| Unfiltered command | Baseline | After change | Log prefix: `/tmp/zttp-modular-p1-` |
|---|---|---|---|
| `zig build test-zts --summary all` | Exit 0; 2964 passed, 1 skipped | Exit 0; 2966 passed, 1 skipped | `baseline-test-zts.log`, `post-test-zts.log` |
| `zig build test-precompile --summary all` | Exit 0; 277 passed | Exit 0; 277 passed | `baseline-test-precompile.log`, `post-test-precompile.log` |
| `zig build test-contract-golden --summary all` | Exit 0; 8 build steps | Exit 0; 8 build steps | `baseline-test-contract-golden.log`, `post-test-contract-golden.log` |
| `zig build test-flow-census --summary all` | Exit 0; 734/734 probes matched; 277 tests passed | Exit 0; 734/734 matched; 277 tests passed | `baseline-test-flow-census.log`, `post-test-flow-census.log` |
| `zig build test-proof-swallow --summary all` | Not required for baseline | Exit 0; 21 files, 0 unreviewed swallows or silent arms | `post-test-proof-swallow.log` |
| `zig build check-spine --summary all` | Previously passed structural baseline | Exit 0; 4 build steps | `post-check-spine.log` |
| `zig build test-doc-links --summary all` | Not required for baseline | Exit 0; documentation links checked | `post-test-doc-links.log` |

At phase 1 handoff, the aggregate and full sequential verification were reserved
for final delivery after all reviewed phases. Their final receipts appear below;
phase 1 alone did not establish overall repository completion or release readiness.

The advisor independently reviewed phase 1's source, test, and documentation
diff, then passed `test-module-boundary`, `test-zts-layering`, and `check-spine`
with Zig 0.16.0. Reviewer receipt: `/tmp/zttp-modular-review-p1.log` (exit 0).

## Phase 2 implementation record

`runtime_natives` now owns integer parsing and header-atom conversion. The
existing public `HandlerInstance` helper names remain aliases. `runtime_http`
owns a concrete `HttpState` for body consumption and borrowed prototypes; both
reset paths and teardown delegate to it. Constructor registration remains in
the composition layer, and `Context` retains prototype ownership.

HTTP operations receive a borrowed `View` with only context, HTTP state,
allocator, outbound/replay configuration, and a stable backend pointer. Host
recovery and fetch/body native adapters live in `HandlerInstance`. No new module
state slot or SDK envelope layout was introduced. Header-allocation and policy
tests retain their assertions with narrow context/view fixtures; implementation
helpers remain private. Existing single-use tests remain, and a new test keeps
one request object alive across both reset paths and verifies its body is readable
again. Neither HTTP implementations nor native helpers import the instance.

The advisor independently reviewed the production and test diff, including
backend/config projection, native host adapters, prototype lifetime, restored
header fixture bytes, and same-object reuse assertions. No further source
revision was requested.

| Unfiltered command | Baseline | After change | Log prefix: `/tmp/zttp-modular-p2-` |
|---|---|---|---|
| `zig build test-zruntime --summary all` | Exit 0; 239 passed | Exit 0; 240 passed | `baseline-test-zruntime.log`, `post-test-zruntime.log` |
| `zig build test-server --summary all` | Exit 0; 339 passed, 2 skipped | Exit 0; 339 passed, 2 skipped | `baseline-test-server.log`, `post-test-server.log` |
| `zig build test-panic-isolation --summary all` | Exit 0; panic refused and subsequent request succeeded | Exit 0; same recovery assertions passed | `baseline-test-panic-isolation.log`, `post-test-panic-isolation.log` |
| `zig build test-module-scope-panic --summary all` | Exit 0; scope recovery probe passed | Exit 0; scope recovery probe passed | `baseline-test-module-scope-panic.log`, `post-test-module-scope-panic.log` |
| `zig build test-runtime-purity --summary all` | Exit 0; shipped analyzer/runtime clean | Exit 0; shipped analyzer/runtime clean | `baseline-test-runtime-purity.log`, `post-test-runtime-purity.log` |
| `zig build test-module-boundary --summary all` | Exit 0; 71 internal modules, 53 allowed reaches | Exit 0; same counts | `baseline-test-module-boundary.log`, `post-test-module-boundary.log` |
| `zig build check-spine --summary all` | Phase 1 and reviewer receipts passed | Exit 0; 4 build steps | `post-check-spine.log` |
| `zig build test-doc-links --summary all` | Phase 1 receipt passed | Exit 0; documentation links checked | `post-test-doc-links.log` |

## Phase 3 implementation record

`ModuleFacts.ImportRecord` retains import kind and binding kind alongside its
existing slot. Its named-import adapter preserves TypeChecker's exact policy:
match slot and binding kind, ignore scope/local spelling, and continue until a
matching declaration names an existing builtin export. TypeChecker no longer
scans the whole IR on each export lookup.

Sessions pass canonical import facts separately from injected contract
projections. Existing callback and construction order remains unchanged. Where
canonical facts are unavailable, a checker builds one owned fallback before
checking. It selects that inline storage from its current address instead of
retaining a self-pointer. Allocation failure propagates and stays sticky after
the allocator recovers. Public inference before `check` retains its existing
behavior. Strict's ModuleFacts-derived raw-slot cache and flow's
mutation-sensitive lookup remain unchanged.

Diagnostic tests cover borrowed and owned routes, aliases, same-named local
functions, parameter shadows, unknown modules, missing exports before a valid
one, and first-success ordering. Explicit IR contrasts pin import kind and
binding kind while showing scope/local name do not participate. Further tests
cover moving a checked owner, allocation failure, and an injected partial
contract index that must not suppress an imported-export diagnostic.

The advisor independently reviewed the source and tests, including the partial
contract-facts regression and scoped `errdefer` that preserves sticky allocation
failure while propagating the error with `try`. The swallow gate initially
classified the equivalent catch-and-return form as a discarded error; the
correction passed without changing its allowlist. The final unfiltered analyzer
suite was rerun after this correction. No further revision was requested.

The advisor approved reuse of phase 1's unchanged analyzer, precompile,
contract-golden, and flow-census baselines after phase 2. Those receipts remain
under `/tmp/zttp-modular-p1-post-*.log`. Fresh phase 3 baseline logs use
`/tmp/zttp-modular-p3-baseline-` for diagnostic corpus, boundaries, layering,
and proof-swallow. Every baseline command exited 0.

| Unfiltered command | Baseline | After change | Post-change log prefix: `/tmp/zttp-modular-p3-` |
|---|---|---|---|
| `zig build test-zts --summary all` | Phase 1: 2966 passed, 1 skipped | Exit 0; 2971 passed, 1 skipped | `post-test-zts.log` |
| `zig build test-precompile --summary all` | Phase 1: 277 passed | Exit 0; 277 passed | `post-test-precompile.log` |
| `zig build test-diagnostic-corpus --summary all` | 182/182 cases; 295 tests passed | Exit 0; same counts, instruction budget passed | `post-test-diagnostic-corpus.log` |
| `zig build test-contract-golden --summary all` | Phase 1: 8 build steps | Exit 0; 8 build steps, goldens unchanged | `post-test-contract-golden.log` |
| `zig build test-flow-census --summary all` | Phase 1: 734/734 probes; 277 tests passed | Exit 0; same counts | `post-test-flow-census.log` |
| `zig build test-module-boundary --summary all` | 71 internal modules, 53 allowed reaches | Exit 0; same counts | `post-test-module-boundary.log` |
| `zig build test-zts-layering --summary all` | Exit 0; 3 build steps | Exit 0; 3 build steps | `post-test-zts-layering.log` |
| `zig build test-proof-swallow --summary all` | 21 files; 0 unreviewed | Exit 0; same counts, allowlist unchanged | `post-test-proof-swallow.log` |
| `zig build check-spine --summary all` | Earlier phase/reviewer receipts passed | Exit 0; 4 build steps | `post-check-spine.log` |
| `zig build test-doc-links --summary all` | Earlier phase receipts passed | Exit 0; documentation links checked | `post-test-doc-links.log` |

## Phase 4 implementation record

The SDK owns a standard-library-only semantic vocabulary and descriptor schema.
Existing SDK binding names alias the same types, preserving declaration forms
and callback signatures. Compile-time projection reads the original declarations
in registration order and rejects an unclassified source field, a missing source,
or a stale/conflicting callback exclusion. Label projection checks all fields,
including reserved representation bits. The SDK-to-engine adapter retains its
existing reserved-bit sanitization; projection is not a runtime adapter.

The builtin registry generates its metadata table from the original bindings.
ModuleFacts returns a metadata-only export descriptor to TypeChecker, and module
type population uses the same table. Both consumers retain engine dependencies
for IR, atoms, or registry ownership; this is a bounded first consumer migration.
Runtime registration, lifecycle envelopes, registry hash folding and callback
presence flags remain unchanged. Independent acceptance code was not changed.

Tests compare every semantic field, label bit, export count and position across
all 21 builtin modules, requiring every module's export list to be nonempty.
SDK projection tests distinguish inherited capabilities from explicit empty
sets, null from zero required arguments, absent from empty contract sections,
and retain signatures, flags and labels. The schema's coverage tests run through
a separate nonempty standard-library-only root reached by both `test-sdk` and
the aggregate. No new named step or consumer allowlist row was needed.

The first SDK projection test hit Zig's default compile-time branch quota;
public projection entry points now set a sufficient quota. An initial parity
test guessed an export floor above the actual registry size; it was replaced
with the exact module floor and a nonempty export assertion per module. Final
unfiltered suites pass after both corrections; existing assertions and goldens
were preserved.

Fresh phase 4 baselines covered SDK, modules, governance, capability audit and
pinned metadata. Every command exited 0. The advisor approved reuse of phase 3's
unchanged analyzer/flow/golden/boundary receipts. Baseline logs use
`/tmp/zttp-modular-p4-baseline-`. Runtime registration was not changed, so this
phase did not require repeating the standalone runtime behavior suites.

| Unfiltered command | Baseline | After change | Log prefix: `/tmp/zttp-modular-p4-` |
|---|---|---|---|
| `zig build test-sdk --summary all` | Exit 0; 10 passed | Exit 0; 13 passed across two roots | `baseline-test-sdk.log`, `post-test-sdk.log` |
| `zig build test-modules --summary all` | Exit 0; 146 passed | Exit 0; 146 passed | `baseline-test-modules.log`, `post-test-modules.log` |
| `zig build test-zts --summary all` | Phase 3: 2971 passed, 1 skipped | Exit 0; 2972 passed, 1 skipped | `post-test-zts.log` |
| `zig build test-module-governance --summary all` | Exit 0; 4 build steps | Exit 0; 4 build steps | `baseline-test-module-governance.log`, `post-test-module-governance.log` |
| `zig build test-capability-audit --summary all` | Exit 0; 3 build steps | Exit 0; 3 build steps | `baseline-test-capability-audit.log`, `post-test-capability-audit.log` |
| `zig build test-flow-census --summary all` | Phase 3: 734/734 probes; 277 tests | Exit 0; same counts | `post-test-flow-census.log` |
| `zig build test-contract-golden --summary all` | Phase 3: 8 build steps | Exit 0; 8 build steps, goldens unchanged | `post-test-contract-golden.log` |
| `zig build test-runtime-purity --summary all` | Phase 2: shipped binaries clean | Exit 0; shipped binaries clean, 8 build steps | `post-test-runtime-purity.log` |
| `zig build test-module-boundary --summary all` | Phase 3: 71 internal modules, 53 allowed reaches | Exit 0; same counts | `post-test-module-boundary.log` |
| `zig build test-zts-layering --summary all` | Phase 3: 168 files, 698 edges | Exit 0; same counts, 0 cross-tier edges | `post-test-zts-layering.log` |
| `zig build test-meta-drift --summary all` | Exit 0; profile and five registry hashes pinned | Exit 0; same pins | `baseline-test-meta-drift.log`, `post-test-meta-drift.log` |
| `zig build test-proof-swallow --summary all` | Phase 3: 21 files, 0 unreviewed | Exit 0; same counts and allowlist | `post-test-proof-swallow.log` |
| `zig build test-step-coverage --summary all` | Existing graph receipt | Exit 0; 93 steps | `post-test-step-coverage.log` |
| `zig build test-script-reachability --summary all` | Existing graph receipt | Exit 0; 44 scripts | `post-test-script-reachability.log` |
| `zig build check-spine --summary all` | Previous phase receipt | Exit 0; 4 build steps | `post-check-spine.log` |
| `zig build test-doc-links --summary all` | Previous phase receipt | Exit 0; documentation links checked | `post-test-doc-links.log` |
| `zig build test-docs-drift --summary all` | Previous documentation receipt | Exit 0; 21 builtin modules, gate-floor probes passed | `post-test-docs-drift.log` |

The advisor independently reviewed the source, projection tests and build-root
reachability, with no revision requested. Independent `test-sdk`,
`test-step-coverage` and `test-script-reachability` also exited 0: 13 tests,
93 steps and 44 scripts. Reviewer receipt: `/tmp/zttp-modular-review-p4.log`.
The aggregate and full verification were reserved for the advisor after all
approved phases; their final receipts appear below.

## Phase 5 implementation record

The server now prepares and installs a concrete source candidate. Preparation
owns the incoming source and copied filename only after fallible validation and
allocation finish; failure before that point leaves the caller's bytes intact.
The candidate owns its optional validated runtime contract. Its capability policy
borrows the analyzed HandlerContract and configured policy until immediate
installation/deinit. The existing pool policy generation deep-copies that view
before publishing a change. A source candidate carries development analysis,
never artifact acceptance.

One server operation holds the exclusive contract lock across pool replacement,
source transfer/retirement, and contract-derived metadata installation, using
contract-then-runtime-init lock order. Pool policy preparation is the final
fallible step; no mutation occurs on refusal. The watcher submits a candidate
and no longer rotates source buffers or sequences pool and metadata changes.
Initial analyzed contract installation likewise installs policy and metadata
under one server operation.

The server adopts the initial file-loaded source, keeps inline/embedded bytes
borrowed, and owns the active plus one superseded source with each allocation's
original allocator. Source filenames are copied for new generations. Retirement
occurs after the pool stops reading the old backing; server teardown drains
runtime readers before freeing retained source. Checked-out runtimes keep their
compiled executable and refcounted policy until release.

A shared serving-settings derivation accepts only optional proof-checked facts.
Accepted startup invokes it after independent certificate acceptance and before
pool construction. Source installation invokes it without accepted proof and
clears promotion, response cache, attestation, stale routes and fault-explanation
facts. The pool installs its concrete settings under runtime-init before its
generation counter changes. Metadata-only embedding updates also invalidate
warmed fault facts when needed. The separate source-policy index bit, guarded
refusals, policy index selection and public pool wrappers remain intact.

Two new transition tests assert actual outcomes. The main fixture starts with a
temporary file and retains a worker lease. Failed policy preparation preserves
original source pointers, code, policy generation, routes, proof/cache and
attestation. Successful installation changes output, policy and route matching,
clears stale serving metadata, then a contract-free second replacement retires
the original file allocation. The old runtime still executes the old output and
retains its old policy/fault facts. Incoming source uses a separate DebugAllocator
to check allocator provenance and teardown. The second test pins preparation OOM,
no-pool ownership, and actual guarded-pool refusal. Existing refusal assertions
moved to the server owner without weakening them; watcher refusal messages remain
unchanged.

The runtime-purity gate caught direct analyzer imports in the relocated/new test
fixtures. A file-private fixture now constructs the existing adapter's contract
type, and the final unfiltered server/runtime/purity suites passed after that
correction. No adapter export, gate exception or allowlist row was added. The
advisor reviewed production, lock/publication order and transition assertions,
including owned file retirement, with no remaining revision requested.

Every fresh baseline below exited 0. Baseline and final logs use
`/tmp/zttp-modular-p5-baseline-` and `/tmp/zttp-modular-p5-post-`, respectively.
Every final named command exited 0; all builds used Zig 0.16.0 and no filters.

| Unfiltered command | Baseline | After change | Log suffix |
|---|---|---|---|
| `zig build test-server --summary all` | 339 passed, 2 skipped | 343 passed, 2 skipped (two moved tests and two new tests) | `test-server.log` |
| `zig build test-zruntime --summary all` | 240 passed | 240 passed | `test-zruntime.log` |
| `zig build test-proof-checker --summary all` | 199 passed | 199 passed | `test-proof-checker.log` |
| `zig build test-proof-checker-purity --summary all` | 199 tests across 13 files; leaf holds | Same counts and boundary | `test-proof-checker-purity.log` |
| `zig build test-proof-ratchet --summary all` | 43 passed | 43 passed | `test-proof-ratchet.log` |
| `zig build test-proof-swallow --summary all` | 21 files; 0 unreviewed | Same counts and allowlist | `test-proof-swallow.log` |
| `zig build test-panic-isolation --summary all` | 14 build steps; panic/recovery passed | Same recovery assertions | `test-panic-isolation.log` |
| `zig build test-module-scope-panic --summary all` | Phase 2 receipt | Scope recovery passed; 4 build steps | `test-module-scope-panic.log` |
| `zig build test-runtime-purity --summary all` | Phase 4 receipt | Shipped binaries and server import boundary clean; 8 steps | `test-runtime-purity.log` |
| `zig build test-module-boundary --summary all` | Phase 4: 71 internal modules, 53 allowed reaches | Same counts | `test-module-boundary.log` |
| `zig build check-spine --summary all` | Phase 4 receipt | 4 build steps | `check-spine.log` |
| `zig build test-doc-links --summary all` | Phase 4 receipt | Documentation links checked | `test-doc-links.log` |
| `zig build test-docs-drift --summary all` | Phase 4 receipt | 21 builtin modules; gate-floor probes passed | `test-docs-drift.log` |

Production and tests remained frozen through the advisor's final independent
review and verification. At that verification snapshot, changes were uncommitted
in the isolated worktree.
The final receipts below complete this plan's delivery gates; they make no
release-readiness or performance claim.

## Final independent verification

The advisor approved every phase's production, tests and documentation, then ran
the final gates independently against the accumulated isolated-worktree changes.
All commands used Zig 0.16.0 through `PATH=/Users/srdjans/.zvm/bin:$PATH`, with no
test filters. No staging, commits, source copying or primary-worktree edits were
performed by the executor.

| Command or check | Result | Receipt |
|---|---|---|
| `zig build test -j2 --summary all` | Exit 0; 200/200 build steps; 9084/9090 tests passed, 6 skipped. CLI: 618 passed, 1 skipped, 0 failed, 0 leaked | `/tmp/zttp-modular-final-test.log` |
| `zig build check-spine --summary all` | Exit 0; 4/4 build steps | `/tmp/zttp-modular-final-spine.log` |
| `bash scripts/verify.sh` | Exit 0; ended `verify.sh: all per-commit gates passed` | `/tmp/zttp-modular-final-verify.log` |
| Independent formatting check | Passed | `/tmp/zttp-modular-final-format.log` |

The canonical gate included the sequential aggregate and standalone runtime
suite, ReleaseFast binaries, handler verification and contract precompilation,
v1 smoke and panic isolation, normalization, module specifications, identity
pins, transport and installer checks. The full log is the authoritative receipt.
All five phases are complete and reviewed. Public goldens and registry identity
remain unchanged; independent proof acceptance retains its own authority.

---
title: zttp reset implementation plan
type: refactor
date: 2026-10-15
artifact_contract: ce-unified-plan/v1
product_contract_source: user-reset-request
execution: code
---

# zttp reset implementation plan

## Goal Capsule

This document is the sole authority for reset findings, design, phase order, and acceptance.
Its destination is `docs/plans/2026-10-14-reset-implementation-plan.md`.
Earlier audits and plans supply evidence, not additional reset tasks.
Standing decisions in `docs/decisions.md` remain binding.
The roadmap will link here and summarize status.

The reset will give future work fewer analysis owners and direct access to typed syntax.
It will preserve current public behavior and permit internal Zig API changes.
The owner selected the full staged reset instead of retaining type stripping as the final design.

The original planning request authorized only this document.
On 2026-10-15, the user approved implementation: "reviewd, go ahead, use subagents when possible, verify with astra".
That approval authorizes U1 through U20, required documentation, local commits, and independent Astra review.
The implementing agent owns code, documentation, review, and verification.
The user retains publication ownership; this reset authorizes no push or release.

## Product Contract

### Summary

I will consolidate analysis ownership before replacing source stripping and annotation reconstruction.
I will retain the interpreter, independent acceptance kernel, request isolation, and existing durable transaction formats.

### Requirements

R1 (public compatibility): current CLI behavior, handler results, machine protocols, source identities, artifacts, receipts, and supported workflows remain compatible.
Internal Zig APIs may change.

R2 (honest analysis): missing, refused, or incomplete analysis must not become a clean result.
The sibling-effect correction is an explicit exception to preserving existing verdicts.

R3 (current language): the reset preserves the actual admission and refusal rules.
It retains `.ts`, including `.d.ts`, and virtual JavaScript sources.
It does not restore `.js`, `.jsx`, `.tsx`, `.mts`, source `comptime()`, or other removed features.
A user-declared function named `comptime` remains an ordinary function.

R4 (bounded phases): each phase has one review boundary, behavior checks, exact verification, and a completed removal or capability.
No phase relies on an unspecified later cleanup.

R5 (documentation): each implementation phase updates the documentation that describes its changed design.
The final phase reconciles the complete retained documentation.

R6 (one authority): detailed findings, accepted decisions, exclusions, verification, and final review dispositions stay in this document.

### Compatibility boundaries

Artifact format 7, certificate schema 5, and `zttp_pcc_v3 = 3` remain unchanged.
Existing receipt, ledger, journal, protocol, and policy formats remain unchanged.
Historical ledger rows remain readable.
Merged multi-module contracts retain `properties = null`.

CHECK retains its imported flow and fault traversals.
Their paths, call counts, order, depth limits, cycle handling, and revision selection remain compatibility inputs.
The reset preserves `.contract_only` and `.sound_extraction` behavior.
It does not enable dependency type checking where the current profile omits it.

CHECK collects source-admission diagnostics before runtime parsing.
Compilation retains its first-admission-refusal behavior.
The direct frontend preserves these different policies, including mixed-error inputs.
Public `.strip` stage labels and frontend metadata remain compatible.

There is no public strip command in the current analyzer command registry.
The reset must not add one.
The exported Zig `strip` API may change under the accepted internal-interface boundary.

## Detailed findings review

### Baseline and evidence limits

The reviewed commit is `f917dc0b7320ecd0165e49a274311f77b3290796`.
Its tree is `d3b97c46e4ee5fbd0da9174d4343887fbbbc7e16`.
Commit `5322a282` has the same tree.

Claude reported successful final runs of `scripts/verify.sh` and `check-spine`.
The final log endings support that report.
Those logs cover the matching tracked tree.
This review ran no new tests or benchmarks.

Claude later started `docs/plans/2026-10-14-sibling-module-effects-plan.md`.
Claude stopped when its weekly limit was reached.
That document remains an untracked draft, not a completed fix.
This planning task must leave that document untouched.

The package census found 475 tracked Zig files and 328,479 physical lines.
The count includes tests, comments, blank lines, and package build files.
It does not measure removable code or expected performance.

Reproduction:

```sh
git ls-files -z 'packages/**/*.zig' | xargs -0 wc -l
```

Two independent Sol reviews covered analysis/modules and runtime/expert ownership.
A native validation request used `gpt-6-astra` with xhigh reasoning.
The dispatch supplied no separate serving receipt.
The Astra review endorsed the corrected design, with the amendments recorded below.
All reviews were read-only and ran no tests.

### Finding 1: sibling effects can leave CHECK falsely proven

In `effect_inference.zig`, relative imports receive no declared write effect.
The relative-path exemption in `moduleIsKnown` also avoids unknown-module charging.
`ContractBuilder.computeEffectSummary` does not supply the missing sibling behavior.
CHECK installs sibling flow summaries, but those summaries do not repair `read_only` or `retry_safe`.

Claude recorded a cache-writing sibling helper with `retry_safe PROVEN`.
Source inspection confirms the mechanism.
This review did not rerun that probe.

The deployment claim in the sibling draft is too strong.
`mergeModuleContract` does not copy properties, and the merged result leaves properties null.
The reset will test entry analysis before merging.
It will preserve the public merged result.

A separate effect traversal would change CHECK reader observations.
Build analysis must use its loaded graph, not reread working-tree paths.
The correction therefore belongs inside existing loads and a shared pure export-summary projection.

Export summaries must distinguish non-function data, functions, function holders, and unresolved exports.
A raw holder row omits transitive user-function effects and export visibility.
An empty row must not represent an unresolved export.

### Finding 2: module lifecycle has overlapping owners

`packages/tools/src/precompile.zig` defines `SingleModuleAnalysis`.
`packages/zts/src/pipeline.zig` defines phase wrappers and `ModuleContractAnalysis`.
Both manage facts, type sessions, pass states, borrowed checkers, and cleanup.

One pipeline-owned session can replace this overlap.
The session must initialize in final caller storage because checkers retain pointers.
Tools must retain filesystem access, reporting, and command policy.

One owner does not imply one result across unlike profiles.
Resolution facts can use a null registry while contract facts use a manifest registry.
Externally supplied facts can also have a separate owner.
Reuse requires matching IR, atom ownership, registry, and analysis policy.
Custom type-check callbacks retain their current timing.

### Finding 3: effect behavior has several producers

`ContractBuilder.build` creates an effect analyzer.
`PathGenerator.detectRecursionReach` creates another analyzer.
`ContractBuilder.computeEffectSummary` performs another reachability walk.

These producers can disagree about imports, routes, value references, and incomplete calls.
The existing effect row also lacks the cache-read fact used by `stateless`.
Egress classification also reaches properties through the separate summary.

One immutable session result should supply these facts.
Call edges and value-reference edges must remain distinct.
A value reference propagates effects without automatically proving a recursive call.
The incomplete `lower_bound` result remains conservative.

### Finding 4: immutable import facts are a useful foundation

`ModuleFacts` already provides an ordered import index.
Its ordering determines serialized contract order.
Its unfiltered import records support different consumer policies.

The reset will retain this owner and ordering.
A reference-aware accessor will replace repeated raw-slot eligibility checks.
It will preserve binding-kind guards and each consumer's existing import filter.
It will not merge unrelated scope identities or change resolution precision.

### Finding 5: typed-source reconstruction is the main frontend burden

`source_frontend.zig` strips admitted typed source before runtime parsing.
`type_map.zig` records eight kinds of annotations.
`type_env.zig` reconnects annotations through names, occurrence ordinals, and signature offsets.
`type_pool.zig` parses annotation text again.

The stripper already preserves source offsets.
This finding concerns reconstruction joins, not a demonstrated broken source map.

The replacement must retain original type, import, export, and trivia spans.
`printer.zig` preserves raw type interiors.
A resolved TypePool alone cannot reproduce normalized source bytes.

TypePool tags do not define the admitted source grammar.
For example, the internal pool supports `void`, but the source profile refuses that spelling.
The existing type-expression parser can accept a prefix without checking complete consumption.
Compatibility fixtures must establish that behavior before the direct parser replaces it.

### Finding 6: graph discovery and compilation use different parse identities

`modules/internal/module_graph.zig` discovers dependencies without shared atoms.
The module compiler parses in execution order with shared atoms.
Entry compilation can also allocate atoms before graph construction.

Reusing discovery IR directly can change atom and bytecode identities.
The reset will retain these distinct parse events.
It will not introduce a remapping system merely to remove the discovery parse.

The completion target is one typed parser implementation.
It is not one physical parse or read across the whole command.

### Finding 7: machine operations read root source more than once

`agent_protocol.zig` reads root bytes for a digest.
Some CHECK and verify paths then invoke a file-based analysis entry point.
The graph identity can also be constructed through a separate observation.

The repeated reads are confirmed.
A mixed-revision result is probable until a controlled reader test confirms it.
One request should reuse its captured root bytes.
This does not establish an atomic snapshot of all imported files.

### Finding 8: workspace recovery order remains a caller obligation

`change_transaction.zig` requires a lock before recovery.
Pending receipt inspection requires completed recovery.
Loop, autoloop, ledger, and agent paths repeat that order.

A recovered-workspace owner can make the legal sequence explicit.
This is a structural improvement, not a confirmed production race.
Recovery can record durable progress before a later failure.
The replacement must preserve those outcomes instead of promising zero recovery writes.

### Finding 9: retired deployment state retains a live directory helper

The proof-review package still exports retired hosted deployment state.
The runtime ledger needs only `state.ensureStateDir` to create `.zttp`.
Other root references anchor the retired module rather than use its deployment behavior.

Moving that helper into the ledger owner permits a bounded removal.
Historical state files must remain untouched.
Local proof cards, deploy, ledger bytes, and legacy ledger readers must remain functional.

### Findings considered and excluded

The runtime already has explicit response leases, panic quarantine, and policy-generation lifetimes.
The acceptance kernel already remains independent and runs before pool creation.
Those boundaries will remain.

Provider clients repeat exchange logic.
That extraction has no required dependency on this reset, so this plan excludes it.

Unused checker exports and duplicate CLI flag branches are small cleanup candidates.
They do not justify additional reset phases.

Broad environment changes could alter credential timing and handler environments.
This plan excludes them.

SDK and engine binding schemas overlap, but the adapter also separates runtime ABI concerns.
This plan retains that boundary and schedules no schema redesign.

The PI README describes veto as the production write gate.
The active authority is aggregate proof, snapshots, and the change transaction.
The workspace-owner phase will correct that documentation.

No task will recreate removed runtime tiers, hosted products, source features, or general provider frameworks.

## Planning Contract

### First-principles design

A result needs an identifiable source, owner, lifetime, and completion state.
Unknown information must remain different from an empty successful result.
Shared facts can serve several analyses without combining their acceptance rules.
A consumer must derive acceptance independently from producer claims.

The resulting ownership is:

```text
tools: I/O, source snapshots, command profiles, diagnostics and output
  -> parser: runtime IR plus separate typed syntax and original spans
  -> pipeline session: stable analysis storage and completed immutable facts
  -> codegen and producer projections: bytecode, contracts and certificates

artifact bytes
  -> independent consumer reconstruction
  -> proof acceptance
  -> runtime pools and isolated requests

expert proposal
  -> snapshot and aggregate proof
  -> recovered workspace owner
  -> durable commit and session acknowledgement
```

The parser's type syntax uses a separate store and type-name namespace.
Type-only syntax allocates no runtime nodes, atoms, or constants.
The compiler lowers that syntax into the existing TypePool and TypeEnv.
The engine tier must not import compiler-tier type resolution.

Runtime node and atom parity are migration checks.
Unchanged public bytecode, proof, contract, identity, and normalization outputs establish external compatibility.
Parser NodeIndex values are not themselves a public wire contract.

The old frontend remains an explicit production entry point until each caller switches.
The new frontend remains private during its comparison phases.
A failed new parse must never fall back to the old frontend.
Legacy adapters disappear only after every caller migrates.

### Assumptions and defaults

The target remains Zig 0.16.0.
The reset adds no public flag, protocol operation, format version, or source feature.
Performance improvements require measurement; this plan promises none.

The implementation will work on local main when separately authorized.
Each complete phase gets its own local commit.
The implementation must not push.

## Implementation Units

Each numbered unit is one independently reviewable phase.
The verification table supplies exact additional commands.
The common verification applies to every phase.
Documentation changes land with their corresponding implementation.

### U1. Establish the compatibility baseline

I will freeze examples of current admission, refusal, diagnostic order, normalized bytes, contracts, and identities through existing public test roots.
I will cover all eight TypeMap kinds and current source restrictions.
I will include same-line signatures, shadowed names, arrows, predicates, optional parameters, aliases, generics, intersections, and tolerated annotation suffixes.
I will retain existing reader traces and distinguish approved sibling-effect corrections from unchanged expectations.

The census must fail when an admitted annotation kind has no case.
The first implementation phase will link this authority from the roadmap and plan index.

### U2. Correct sibling export effects

I will compute effect results during existing imported-flow loads.
Flow and effect completion will remain independent.
The fault traversal will remain separate.
Build analysis will consume loaded graph sources.

I will resolve export visibility and final transitive effects for callable values and function holders.
I will distinguish known non-callable data from unresolved exports.
Scalar and object data controls will retain their existing value and provenance behavior.
Calling non-callable data will retain its current refusal or incomplete result.

The summary will carry writes, cache reads, egress, capabilities, and incomplete analysis information.
Tests will cover direct calls, aliases, callbacks, holders, two-hop imports, pure helpers, data exports, and missing exports.
Missing files, malformed files, cycles, and depth exhaustion must not establish clean effects.
Revision-reader traces must remain exact.
Entry contracts must reflect the correction before merging.
Merged properties must remain null.

### U3. Consolidate module analysis lifetime

I will replace the overlapping tools lifecycle with one in-place pipeline session.
Tools will retain I/O, reporting, and command policy.
The session will retain explicit one-shot pass states and owned cleanup.

Tests will preserve both extraction profiles, registry-specific facts, callback timing, failed attempts, and returned-result lifetimes.
Allocation failures must not expose successful partial results.
Discovery parses and compilation parses will remain separate.

### U4. Reuse effect facts for path analysis

I will let the session own completed immutable effect facts.
Path analysis will borrow those facts instead of constructing another analyzer.
Call edges, value references, route roots, and incomplete results will retain their meanings.

Tests will compare recursion, callbacks, routes, function holders, and unresolved calls.
I will remove the old path-owned producer after parity passes.

### U5. Reuse effect facts for contract analysis

I will migrate contract effect and reachability queries to the same result.
Cache-read and egress facts will replace their separate summary producers.
Reference-aware ModuleFacts access will preserve consumer filters and binding-kind checks.

Tests will cover slot collisions, local and captured bindings, discarded logs, persistent reads, egress, and capability attribution.
I will remove the old producers only after exact parity, apart from U2's approved corrections.

### U6. Bind machine requests to captured root bytes

I will first add a controlled reader test for changes between digest construction and analysis.
I will pass captured root bytes into the existing source-based operations.
Root graph identity, digest, diagnostics, and analysis will describe the same bytes.

Tests will preserve overrides, stale guards, write-free verification, deterministic responses, and refusal of normalize write mode.
Imported-file observation rules will remain unchanged.
This phase will make no claim of an atomic dependency snapshot.

### U7. Add a direct typed-parser vertical slice

I will extend the existing parser with a separate type-syntax store.
A primitive annotation will reach the existing TypeEnv through a private comparison path.
Runtime allocations and original spans will match the legacy path.

Tests will cover success, incomplete input, allocation failure, nesting limits, and mixed-error precedence.
Production callers will retain the legacy frontend during this phase.

### U8. Add compound type syntax

I will add the compound forms admitted by U1's census.
The forms include current records, arrays, tuples, unions, intersections, literals, template types, and function types.
Internal TypePool tags will not expand admission.

Private comparisons will check resolved meaning, source spans, refusal order, and memory cleanup.
No public caller will switch in this phase.

### U9. Add named, nominal, and recursive declarations

I will parse current structural and nominal declarations into the type store.
Type-only declarations will emit no runtime statement or runtime atom.
Compiler lowering will preserve nominal identity and current recursive-alias rules.

Tests will distinguish accepted recursive aliases from existing refused cycles.
They will cover repeated names, nested scopes, original declaration spans, and cleanup.

### U10. Add generic syntax

I will add current generic parameters, applications, constraints, defaults, and explicit call arguments.
The type namespace will remain separate from runtime atoms.
Existing substitution and refusal behavior will remain authoritative.

Tests will cover nested applications, angle-bracket ambiguity, generic intersections, repeated signatures, and exhaustion.
The new path will remain private.

### U11. Attach every annotation to its semantic owner

I will attach variable types to binding identities.
Parameter annotations will attach to their parameters.
Function nodes will own return types, predicates, and generic parameters.
Call nodes will own explicit type arguments.

The side store will retain raw type-only import and export spans.
Tests will cover every TypeMap kind, same-line functions, shadowed declarations, closures, and predicate parameter identity.

### U12. Migrate type-analysis consumers

I will add syntax-based inputs for TypeEnv, TypeChecker, StrictChecker, and function specifications.
The new inputs will remove reconstruction joins from the new path.
Explicit legacy entry points will remain for callers that have not switched.

Tests will preserve source grammar, nominal types, generic substitution, null versus undefined, and error versus unknown states.
Dependency checking profiles will remain unchanged.
No failed new analysis will retry through legacy reconstruction.

### U13. Migrate proof and printer consumers

I will add syntax-based inputs for contract, effect, and pipeline consumers.
The printer will retain original token, trivia, type, import, and export spans.

Tests will compare normalized bytes, diagnostic stages and spans, contracts, proof IR, source identity, and certificate inputs.
Semantic type equality alone will not satisfy normalization compatibility.
Legacy production entry points will remain until their callers switch.

### U14. Switch CHECK callers

I will switch CHECK and its machine and expert callers to direct typed parsing.
Private differential tests will retain the old frontend as an oracle.
Public stage labels, diagnostic collection, totals, and reader behavior will remain compatible.

Pure siblings and existing recorded flows must retain their verdicts.
Only the explicit U2 corrections may change expected proof results.

### U15. Switch compilation callers

I will switch source compilation and loaded-graph contract producers.
Graph discovery will retain its separate parse and atom policy.
Current dependency type-check profiles will remain unchanged.

Tests will compare runtime results, bytecode, routes, resources, policy identities, residual guards, contracts, and certificate inputs.
Entry properties and merged null properties will receive separate assertions.
Artifact acceptance must still precede pool initialization.

### U16. Switch remaining frontend callers

I will migrate normalization, virtual evaluation, module helpers, benchmarks, and remaining callers from U1's census.
The virtual JavaScript profile will retain its current admission rules.
Normalization will preserve raw type interiors and idempotence.

The phase will finish only when every production caller uses the new frontend.
I will not add a public strip command or a runtime frontend selector.

### U17. Remove reconstruction

I will remove the production stripper, TypeMap joins, and legacy adapters after the caller census reaches zero.
Source classification and original-source views will remain.
The differential oracle will be removed last, while behavior fixtures remain.

I will update affected imports, test roots, source anchors, and allowlists deliberately.
No suppression will be widened merely to pass a gate.
This phase must leave one typed parser implementation.

### U18. Encode recovered workspace ownership

I will introduce an owner that acquires the lock and completes recovery before exposing transaction methods.
I will migrate loop, autoloop, ledger, and agent callers.
Approval policy and aggregate proof will remain in their current owners.

Tests will preserve lock contention, conflict handling, read-set checks, every existing fault outcome, and durable receipt acknowledgement.
Recovery may retain documented durable progress after failure.
Unproved candidate writes and premature acknowledgements must remain impossible.
The PI documentation will identify the actual production write authority.

### U19. Remove retired proof-review state

I will move the directory helper into the existing ledger owner.
Directory creation timing and path behavior will remain unchanged.
After a fresh caller census, I will remove retired state, types, I/O helpers, and force imports that have no remaining use.

Tests will preserve ledger bytes, legacy rows, proof cards, and local deploy.
Existing hosted state files will remain untouched.

### U20. Reconcile the final design and evidence

I will reconcile architecture, type-system, user, verification, testing, and embedding documentation.
The roadmap and plan index will link to this authority.
Older overlapping plans will become historical references without losing completion evidence.
Standing decisions will remain unchanged.

I will run the final checks and record actual results.
I will record performance observations without inventing an improvement target.
I will stop implementation if a public mismatch requires a new feature, format change, or unapproved corpus replacement.

## Verification Contract

### Common checks

Each phase starts with its smallest behavior fixture before broader execution.
New tests use public entry points and simple in-memory readers or stores.
They must join an existing named test root.
A census must reject an empty fixture set or an uncovered declared annotation kind.

Every phase requires:

```sh
zig build test -j1
zig build check-spine
zig fmt --check build.zig build/ packages/ tooling/
bash scripts/verify.sh
```

The full script can exceed two minutes.
The implementing agent must follow the repository's pause rule before starting such a script.
This planning task does not run it.

All named test runs are unfiltered.
A `-Dtest-filter` run supplies no acceptance evidence.
Build exit status supplies the verdict.
Piping a build through `tail` does not preserve that verdict.

Standalone runtime tests run in a separate process after the aggregate.
They must not run concurrently with the pool-heavy aggregate on macOS.

### Exact additional checks by phase

Each cell contains complete commands.
The frontend command below applies to U7 through U17:

```sh
zig build test-zts test-precompile test-zts-cli test-canonicalize test-diagnostic-corpus test-contract-golden test-generic-intersection-cli-matrix test-cli-abuse test-module-boundary test-zts-layering -j1
```

| Phase | Additional commands |
|---|---|
| U1 (compatibility baseline) | `zig build test-zts test-precompile test-diagnostic-corpus test-contract-golden test-agent-protocol test-canonicalize -j1` |
| U2 (sibling export effects) | `zig build test-zts test-precompile test-contract-golden test-flow-census test-diagnostic-corpus test-standin test-expert-app test-examples test-proof-swallow -j1`; then `zig build test-zruntime` |
| U3 (analysis lifetime) | `zig build test-zts test-precompile test-module-graph-record test-contract-golden test-zts-cli test-proof-swallow test-module-boundary test-zts-layering -j1` |
| U4 (path effect facts) | `zig build test-zts test-precompile test-contract-golden test-flow-census test-proof-swallow -j1` |
| U5 (contract effect facts) | `zig build test-zts test-precompile test-contract-golden test-flow-census test-diagnostic-corpus test-capability-audit test-module-boundary test-proof-swallow -j1` |
| U6 (root source capture) | `zig build test-agent-protocol test-module-graph-record test-zts-cli test-precompile test-expert-app -j1`; `bash scripts/check-agent-determinism.sh` |
| U7 (typed vertical slice) | The frontend command above |
| U8 (compound type syntax) | The frontend command above |
| U9 (named and recursive declarations) | The frontend command above |
| U10 (generic syntax) | The frontend command above |
| U11 (annotation ownership) | The frontend command above |
| U12 (type consumers) | The frontend command above |
| U13 (proof and printer consumers) | The frontend command above; `zig build test-proof-checker test-proof-ratchet test-proof-swallow -j1` |
| U14 (CHECK cutover) | The frontend command above; `zig build test-agent-protocol test-standin test-expert-app test-expert-golden -j1` |
| U15 (compilation cutover) | The frontend command above; `zig build test-server test-module-graph-record test-proof-checker test-proof-ratchet test-residual-guards-drift test-examples -j1`; then `zig build test-zruntime`; `zig build -Dhandler=examples/handler/handler.ts -Dverify -Dcontract` |
| U16 (remaining frontend callers) | The frontend command above; `zig build test-agent-protocol test-expert-golden test-expert-app test-compile-bench -j1`; `bash scripts/check-normalize-idempotent.sh` |
| U17 (remove reconstruction) | The frontend command above; `zig build test-expert-golden test-grammar-drift test-meta-drift test-diagnostic-producers test-idiom-table test-canonical-style test-spine test-native-gates -j1`; `bash scripts/check-normalize-idempotent.sh` |
| U18 (workspace ownership) | `zig build test-expert-app test-standin test-simulator test-recorder-smoke test-cassette -j1` |
| U19 (retired state removal) | `zig build test-proof-review test-cli test-docs-drift test-doc-links test-runtime-purity -j1`; `zig build smoke-v1` |
| U20 (final reconciliation) | `zig build test-docs-drift test-doc-links test-spine -j1`; `zig build smoke-getting-started`; `zig build bench-check` |

Frozen corpus replay must remain green.
A corpus failure must not trigger a live model call or automatic rerecord.
An intentional U2 expectation change requires a specific failing case and reviewed correction.
Other golden changes require an explanation within this authority before acceptance.

### Measurements

The existing compile benchmark covers source preparation, parsing, and code generation.
It does not establish full CHECK latency or imported-analysis cost.

The baseline and final frontend measurements use the same pinned toolchain, host, fixtures, and options.
The pilot command is:

```sh
zig build compile-bench -Doptimize=ReleaseFast -- --json --iterations 1
```

After the pilot succeeds, only the iteration parameter changes:

```sh
zig build compile-bench -Doptimize=ReleaseFast -- --json --iterations 50
```

The value 50 is the current harness default, not a performance target.
Any claim about sibling analysis requires a separate measurement of the actual CHECK workload.
`bench-check` supplies runtime benchmark evidence only.
No new speedup or deletion percentage is an acceptance requirement.

## Resolved validation findings

The Astra review required preservation of existing reader traces and graph snapshots.
The plan now computes imported effects during existing loads.

The review rejected the draft's claim about false deployed properties.
The plan now distinguishes pre-merge entry analysis from merged null properties.

The review identified missing cache-read facts, incomplete function-holder rows, and valid data exports.
U2 and U5 now cover those distinctions.

The review required separate graph discovery parses, registry-specific facts, extraction profiles, and callback timing.
U3 and U15 preserve those differences.

The review required raw printer spans, a separate type namespace, and exact diagnostic precedence.
The frontend phases now require those properties.

The review found that early reconstruction deletion would strand legacy callers.
Legacy production entry points now remain until each caller switches.
No failed new parse can fall back.

The review corrected the recovery guarantee.
U18 preserves durable recovery progress and forbids only unproved writes or premature acknowledgements.

The review rejected a literal single-parse completion criterion.
The final criterion is one typed parser implementation with no annotation reconstruction within a parse.

The review required smaller grammar units.
U8, U9, and U10 now separate compound types, named declarations, and generics.

### U2 implementation review dispositions

The effect correction retains legacy capability, purity, and determinism charges for relative imports.
A completed pure sibling must not grant a new capability or purity proof.
Known data retains those charges but does not count as a function value.
An initializer that calls a factory does not establish a data export.
The export projection tests include a local factory that returns a writer.

An incomplete callable row can still contain false `writes` and `has_egress` fields.
Those fields describe only observed effects and cannot establish their absence.
Import charging therefore adds possible writes and egress when a supplied row is incomplete.
The merge retains positive cache-read and recursion facts.
A public CHECK test covers an imported function that calls an unresolved callback.

Conservative egress must not claim an observed outbound call.
The contract retains an internal completeness flag for its immediate proof trace.
The flag does not enter contract JSON or change a format version.
The trace replaces only the incomplete positive egress explanation.
Flow analysis continues to determine the handler's determinism.

Effects must not borrow a poisoned type environment.
A failed type initialization prevents checker construction and nested reads.
Every imported flow attempt checks type health, including attempts that produce no summary.
An unhealthy checker loses its flow summary, and effect analysis receives no type environment.
The existing early stop and separate fault traversal remain unchanged.

Late export capture introduces an allocation failure after contract construction.
The review found that `rate_limit_namespace` still had two owners at that point.
The builder now clears its local namespace after the contract takes ownership.
A measured final-allocation failure exercises namespace cleanup during export capture.
Export projection also has a complete allocation-failure sweep.

A module holder must not require a resolved name for registration.
Without an atom table, that requirement dropped the holder's initializer and could falsely establish determinism and purity.
Registration retains the original binding key, and only export publication requires a name.
The regression uses the standalone parser and derives its padding from `Atom.FIRST_DYNAMIC`.
An unfiltered run confirmed the incorrect determinism result before the registration correction.

Merged contracts must not acquire new capsule diagnostics or declaration arrays for test observation.
The review rejected that change because it altered public output beyond the approved correction.
Tests check entry properties through the shared import mapper before merging, under both extraction profiles.
The tools graph test checks unchanged merged output, and source review checks the tools loop's mapper wiring.
Merged properties remain null.

### U3 implementation constraints

One `ModuleAnalysisSession` will replace the tools owner and `ModuleContractAnalysis`.
The session will initialize in final caller storage and own its analysis storage.
The session will retain separate full, contract-only, and sound-extraction profiles.
Each selected pass will have one attempt, and skipped passes will remain distinct.
Flow can run after contract extraction where the current tools helper requires that order.

Custom extraction callbacks require fresh checker storage and retain their extraction-time execution.
Separate type storage remains necessary when resolution and a custom extraction callback both run.
Externally supplied facts remain borrowed, and registry-specific facts remain distinct.
Returned contracts and transferred export tables must survive all session cleanup.

The private tools helper has one caller, which supplies no type map.
U3 can remove that unused parameter instead of adding a profile option for an unobserved case.
Contract-only analysis will continue to omit source annotations.
Full and sound analysis will retain their existing type-map inputs.

The boolean checker can retain a pointer into temporary checker storage within `resolve`.
Current consumers read stored diagnostics and node types instead of rerunning boolean inference.
U3 will clear the temporary pointer before the resolved result escapes.
The direct `resolve` API will remain available to its current runtime caller.

Graph import mapping precedes custom extraction callbacks.
Before the callback runs, the session will expose resolution facts when no injected or contract facts exist.
The callback will still run before construction of its registry-specific contract facts.
The first Astra review identified and rejected an earlier accessor guard that broke this order.

A failed selected verifier or flow attempt must prevent later contract extraction.
An unattempted selected flow remains available because the contract-only tools path extracts before flow analysis.
Independent allocation-failure probes will restore allocation before checking refusal after each selected pass fails.

### U4 implementation constraints

Path analysis currently uses no manifest registry, type environment, injected module facts, or imported effect rows.
Its completed facts must retain that identity.
Contract facts with different inputs cannot replace the path result.
The session will prepare path facts lazily at the existing path phase.
The existing imported fault scan will finish before effect production starts.

The immutable result will own function names, function metadata, separate call and value edges, and export results.
The result will precompute recursion reachability without retaining analyzer or parser pointers.
The original `row.recursive` flag must remain separate from reachability.
Reachability starts with existing recursive flags and propagates only through call edges.
Function-value edges can carry effects without establishing recursion.

`PathGenerator` will require an explicit complete or unavailable result.
Analyzer or snapshot failure will publish unavailable and preserve conservative recursion handling.
Path generation and reader failures will retain their existing handling.
A complete result with no matching body will remain false.
Inline route bodies will acquire no synthetic function rows.

The session will attempt path analysis once and own any completed result through generator cleanup.
Standalone callers will own explicit facts without adding full type or strict analysis.
Returned fixtures must keep borrowed fact addresses stable.
Each phase will retain the separate handler and route roots, costs, coverage, and reader observations.

The implementation review required read-only slices for published rows, edges, export entries, and export names.
The recursion fixture now checks every expected function name before checking projected results.
The review also restored the lower-level analyzer's allocation-free false result for an unmatched body.
A public failure probe checks that behavior with a nonempty analyzer.
The review establishes no performance improvement for the propagation algorithm.

### U5 preparation findings

Contract extraction needs its own effect result when its inputs differ from the path profile.
Its identity includes IR, atoms, module facts, registry, type environment, and imported effects.
Imported effects arrive after session completion and before extraction.
Custom extraction must build its result after the callback, with the callback's type environment and contract facts.
Contract effect failure must fail extraction instead of publishing the path profile's unavailable outcome.

`ContractBuilder` currently runs an analyzer, two handler reachability walks, a separate summary walk, and export projection.
Handler reachability includes call edges and function-value edges.
Recursion reachability includes only call edges.
Capability attribution must retain direct handler violations, reachable helper violations, and lower-bound refusal.
`scanCallSites` must remain because it extracts concrete resources, routes, schemas, flags, and diagnostic locations.

The initial review overstated summary redundancy.
The first function named `handler` supplies effect rows and helper reachability.
The selected top-level global handler supplies the legacy summary.
An earlier block-local handler can make those identities differ.
The selected summary then supplies write, cache, call, and unknown facts that the first-name row does not contain.

The old summary also records bare ambient `fetchSync` as egress, while effect inference records only a lower bound.
Named callback arguments do not enter that summary, while inline callback bodies can enter it.
Nested local function targets can lack ordinary effect rows.
Raw generic slots and partner slots take precedence over raw user-function slots in that traversal.
U5 must preserve these distinctions in completed facts before removing builder-owned summary production.
Possible egress must demote properties without inventing a concrete outbound endpoint.
The no-handler fallback must retain its current classification of imported functions, including unused imports.

Reference lookups must accept `ir.BindingRef` and retain each consumer's existing eligibility and resolution filter.
Effect inference already excludes local, argument, and upvalue references from import matching.
Some contract, schema, authentication, and router consumers instead match raw slots.
The initial proposal to guard every consumer would change existing parsed-source output and is rejected under R1 (public compatibility).
Those consumers must retain explicit legacy slot matching within this reset.
Captured module imports remain eligible where the current consumer admits them.
Declaration identity remains distinct from import eligibility and includes scope where the existing lookup uses scope.
Global import declarations can share a name atom and slot because declaration collection does not reject that duplication.
Reference accessors must preserve resolution filtering before selecting a matching slot.
For example, router lookup must skip an unresolved import before selecting a later builtin record with the same slot.
The analyzer's import map instead retains the last matching record through overwrite.
The shared accessor must express both selection policies explicitly.
Schema-category lookup must search all eligible matching slots for its category, while authentication scanning retains its first-match behavior.
Export copies must remain valid after session cleanup.

An existing fixture imports `parseBearer as length` and calls a local function whose slot equals that import slot.
Source review shows that the current contract sets bearer authentication metadata through that slot match.
An unfiltered baseline run confirmed this behavior before the accessor migration.
The reset will centralize that policy instead of silently correcting it.

The factory can retain a separate legacy summary facet when ordinary rows answer a different question.
The builder must borrow completed results and stop producing its own analyzer, summary, export table, and repeated reachability walks.
This requirement establishes one result owner, not one physical AST traversal.

The accepted U5 design keeps a completed `ContractEffectSummary` facet inside `EffectFacts`.
The facet retains the exact scalar summary, selected-handler identity, and first-name handler reachability.
The producer releases traversal scratch before publishing the facet.
The path profile marks the contract facet as unrequested.
A completed no-handler facet remains different from an unrequested facet.
The builder requires completed contract facts and combines the no-handler summary with its existing concrete-egress scan.
Astra accepted this revised ownership design through source review.
Baseline characterizations now cover the distinct handler identities, callback traversal, raw-slot precedence, unused imports, and exported helper facts.
The duplicate-handler fixture uses a bare block because the analyzer's declaration collection does not descend conditional blocks.
The typed budget fixture uses source preparation and a full session with its type map.
The unfiltered analyzer root passed before the producer migration.

### U6 preparation findings

`agent_protocol.zig` currently observes the root separately for graph identity, digest, and several operations.
Existing source APIs cover CHECK, canonicalization, normalization, and edit simulation.
`canonicalize.zig` needs a source-based repair simulation helper to remove its internal root reread.
The public CLI helper can retain its file read and delegate to that source helper.

CHECK can use `runCheckOnlyFromSourceWithOptions` with its current JSON mode, null SQL schema path, and other defaults.
Canonicalization can use `collectFromSource`.
Normalization can use `normalizeSource` with the current layout and schema defaults.
Repair simulation must retain proposed content as `content` and captured bytes as `before`.

A captured root owner can retain relative path, absolute path, disk bytes, effective source, digest, and graph.
The effective source borrows disk bytes or a valid verify content override.
Only a string content override changes verify source; other content values remain ignored.
Empty string overrides remain valid, and the disk read cap must not become an override length cap.
Verify must still read disk first and preserve the current missing-file refusal.
Graph identity and the stale guard must use the same effective source as analysis.

A pre-U6 CLI baseline confirms the override identity mismatch.
Disk verification and override verification return different `source_digest` values but the same `module_graph_hash`.
Both transport commands exit 0 with no protocol error; their property verdicts establish no identity correctness.
The retained responses are `disk-result.json` and `override-result.json` in `/tmp/zttp-reset-20261015/u6-root-baseline/`.
The approved U6 scope corrects that mixed identity by hashing the effective root bytes.
The wire schema, property interpretation, and separate imported observations remain compatible.

Current graph construction reads the root before validating its extension.
Missing or oversized JavaScript roots therefore produce `EntryUnreadable`, while readable JavaScript roots produce `UnsupportedSourceExtension`.
Root read failures, including allocation failure during that read, map to `EntryUnreadable` before operation dispatch.
Later allocation failures retain their existing handling.
The captured reader must retain `module_graph_record.max_source_bytes` and leave extension validation to `buildWithEntrySource`.

Imported resolver and existence failures retain their existing graph rejection rows.
A later read failure for an already queued import silently omits that node under the current walker.
The earlier description of all imported read failures as graph rejections was too broad.
U6 preserves both behaviors and must not turn imported failures into universal root refusals.
The source capture reader must not become CHECK's import reader.
Separate dependency graph, summary, and fault observations remain unchanged.
Edit simulation retains its current project-context discovery and proposed-before analysis order.
Captured root bytes do not freeze policy, schema, or imported observations.
Normalize write refusal remains before stale checking and operation dispatch.
A controlled changing-reader test must bind the digest, graph hash, diagnostics, and contract to captured bytes.
The test must also confirm that later disk bytes differ from those captured bytes.
The determinism script must use a `zts` binary built from the completed U6 source.
The full gate's successful release build can supply that binary before the separate script runs.

The captured fixture must reach contract extraction before producing its diagnostic.
An early strict error, such as ZTS621 from a chained ternary, leaves no contract and cannot test contract retention.
A CLI measurement confirms that a fully typed spec-less handler produces ZTS500 while retaining an object contract.
The controlled-reader fixture will use that contract-stage diagnostic and a distinct later disk revision.

### U7 preparation findings

The parser seam is `packages/zts/src/parser/parse.zig`, in variable declaration parsing after binding creation.
The grammar authority is `packages/zts/src/grammar_registry.zig`.
Frozen preparation fixtures live in `packages/zts/src/source_frontend.zig`; CHECK stage fixtures live in `packages/tools/src/precompile.zig`.
`packages/zts/src/type_env.zig` owns environment binding, while `packages/zts/src/type_checker.zig` owns declaration enforcement.

The first direct parser slice can cover one annotated variable binding without changing production callers.
The existing tokenizer supplies the required tokens and reversible lookahead.
The annotation hook belongs after binding declaration and before initializer parsing.
The typed initializer must use the same runtime parser and own a separate syntax store.

The published primitive set is `unknown`, `never`, `undefined`, `null`, `boolean`, `number`, `string`, and `Bytes`.
Parentheses can contain one primitive within the existing nesting limit.
`any` and `void` retain admission refusals; boolean literals belong to the next syntax phase.
Legacy preparation retains suffix text such as `string tolerated_suffix`, while semantic lowering resolves its primitive prefix.
The syntax store must retain both the recognized semantic span and the complete raw annotation span.

The syntax store belongs to the parser's engine tier and must not import the compiler's type pool.
Compiler lowering must map syntax primitives directly to existing pool indices and bind the existing `BindingRef`.
The direct path must use no TypeMap, name ordinal, location join, or type-text parse.
`bindVarType` uses the binding's scope and name atom, rather than its slot alone.
U7 establishes parser identity and direct environment lookup, not initializer enforcement by the existing checker.
The current checker still obtains declaration annotations through name ordinals; U12 owns that consumer migration.
The parser owns store arrays, borrows original bytes, and releases arrays on every exit.
The store must add no runtime atoms, nodes, constants, strings, or scopes.

Independent legacy and direct comparisons need fresh atom tables.
The existing identity helper shares atoms and strips both inputs, so it cannot supply this comparison unchanged.
Comparisons must include runtime nodes, payloads, locations, lists, constants, scopes, bindings, and atom identities.
Type-store allocations remain separate from runtime allocation parity.
Original spans remain half-open byte offsets into unmodified source.

CHECK collects source-admission diagnostics before runtime parsing.
Compilation stops at its first source-admission refusal before runtime parsing.
A later admission refusal can therefore hide an earlier runtime syntax error.
The private comparison path must preserve stage order rather than sort all diagnostics by position.
Admission scanning can reuse token and syntax logic without building a second runtime tree.
A failed direct parse must return its failure without a legacy retry.

Type-token consumption must preserve the previous runtime token used by missing-semicolon diagnostics.
Type nesting needs its own counter because legacy admission counts type delimiters separately from runtime nesting.
Comment interiors need explicit legacy characterization before the private slice admits them.
The legacy type parser does not skip comments as the runtime tokenizer does.
Tolerated suffixes still require admission checks; suffix `any` or `void` must not bypass existing refusals.

Astra's design review bounds U7's private comparison to simple `let` and `const` declarations with one annotated binding.
Other declarations can remain untyped, and initializer tokens must belong to an explicit limited vocabulary.
The preflight scan covers the complete source before declaring that source eligible.
Functions, imports, exports, type declarations, compound annotations, assertions, templates, regexes, and uncharacterized comment interiors return a private `out_of_slice` outcome.
An unsupported annotation position also returns that outcome.
The outcome declines a private comparison and does not authorize a legacy retry or change public admission.

Within that boundary, admission checks recognize type spellings only after a declaration's binding colon.
Runtime identifiers and quoted strings receive no type-admission classification.
Suffix `number void any` reports `any` before `void` in CHECK collection mode.
The scan finds `any` first, then the removed-form pass finds `void`; compilation stops at `any`.
The bounded mixed-error fixture places an untyped broken initializer before the annotated declaration.
Its admission refusal must suppress the earlier runtime failure.

Focused tests must cover primitives, grouping, tolerated suffixes, original error spans, nesting limits, allocation failure, and runtime identity.
Mixed admission and runtime errors must preserve the frozen stage precedence.
Production callers remain on `PreparedSource` until the later cutover phases.

Astra's final proposal review identifies a malformed-input distinction.
Legacy stripping can consume an unmatched opening parenthesis through EOF without an admission refusal.
For `let n: (number;`, the runtime parser then reports its missing semicolon at the binding token.
The private comparison must reproduce that outcome or explicitly decline that malformed shape.
Direct parser failure tests alone do not establish legacy comparison parity.
Lowering must check both pool health and environment health because environment health does not inspect pool poison.
Astra's source review also identifies angle-token ambiguity in initializers.
For U7, private comparisons decline `<` and `>` tokens, including generic calls, before runtime parsing.
The existing `<=` and `>=` operators remain within the bounded vocabulary.
U10 owns generic call syntax; this private restriction changes no production admission rule.
Depth refusal alone does not establish eligibility for the primitive comparison.
The preflight validates the entire annotation through the same grammar with a source-length bound.
Only successful validation retains the original depth diagnostic before the remaining source scan.
Grouped compounds and unclosed groups still decline comparison.

A CLI measurement confirms that lone CR before root `any` reports a legacy cursor column unlike byte-based positioning.
U7 privately declines source containing lone CR while retaining CRLF coverage.
Later production migration must preserve the observed diagnostic policy or obtain explicit approval for a change.

### U8 preparation findings

`packages/zts/src/grammar_registry.zig` publishes compound grammar.
`packages/zts/src/type_pool.zig` owns current semantic parsing and normalization.
`packages/zts/src/stripper.zig` owns current admission and delimiter scanning.
Existing semantic fixtures in TypePool and admission fixtures in the stripper supply separate compatibility evidence.

The compound lowerer must distinguish published syntax, source admission, and legacy semantic prefix parsing.
`TypePool.parseTypeExpr` does not require complete input consumption.
TypePool behavior alone does not establish that source admission accepts an incomplete form.
Each new fixture must therefore check admission before comparing semantic meaning.

Record parsing accepts identifier fields, optional fields, readonly fields, and permissive separators.
Quoted field names can stop semantic parsing and leave an empty record or an earlier field prefix.
Missing colons, missing types, comments, and missing closers can also produce semantic prefixes.
Those behaviors need source-admission characterization before the private path claims compatibility.

Array suffixes depend on the parsed primary.
Primitives and non-identifier primaries receive repeated suffixes; named references receive one suffix, and generic applications leave suffixes unconsumed.
Readonly arrays retain their flag, while legacy lowering discards a tuple's readonly flag.
Tuple syntax can retain that authored flag without changing its resolved legacy meaning.

Intersection binds more tightly than union.
Leading and trailing operators can produce a resolved prefix in the legacy semantic parser.
Exactly two union members containing `undefined` use the nullable representation.
Wider unions use the normal union constructor, with its existing flattening, deduplication, and subsumption.

String literals retain raw escaped text rather than decoded text.
Number literals resolve decimal integer prefixes; decimals and hexadecimal text can therefore produce shorter numeric meanings.
Integers outside the existing literal range become base `number`.
Template types retain literal segments and type slots; an empty template has no semantic type.
Incomplete literals and templates need separate admission characterization.

Function syntax and grouped syntax share a backtracking boundary after the first identifier.
Legacy semantic parsing tolerates some missing separators, closers, arrows, and return types.
Source admission refuses optional function parameters only when its parenthesis depth is positive and its brace depth is zero.
Nested record context can therefore change that refusal; optional record fields remain admitted.
The source frontend also refuses `void`, `Array<T>`, and `ReadonlyArray<T>` outside existing exceptions.
Predicate semantics belong to the later annotation-owner phase.

The engine-tier store can use separate arrays for syntax nodes, member lists, fields, parameters, template parts, and annotations.
Nodes retain original spans; annotations retain complete admitted spans and recognized-prefix ends.
Names, literal text, and template text remain borrowed source spans rather than runtime atoms or copied parser names.
Compiler lowering calls TypePool constructors directly and copies names only when TypePool owns them.
The lowerer must not reconstruct TypeMap or call `parseTypeExpr` on source text.
Named references and generic applications remain outside U8 until their later phases.

Admission scanning remains distinct from semantic prefix parsing.
The legacy scanner tracks delimiter depths and skips comments and quoted text.
Its removed-form scan reports only the first removed form within an annotation.
Template scanning skips complete templates, including slots, so existing refusals do not automatically extend into those slots.
Fixture comparisons must retain this admission scope and the existing CHECK and compilation diagnostic order.

Main measured 45 isolated annotation fixtures through the current CLI during U7 verification.
Each fixture assigns `undefined` to expose admitted types through the existing mismatch diagnostic.
All commands exit 1, but their failure stages differ.
Sources, complete responses, stderr, and an index remain under `/tmp/zttp-reset-20261015/u8-cli-baseline/`.
The table groups 27 fixtures; the directory index contains the full set.

| Measured form | Observed public result |
|---|---|
| Quoted record key | ZTS200 describes an empty record prefix. |
| Missing record colon or type | ZTS200 follows admission. |
| Record comments or omitted separators | ZTS200 follows admission; exact meanings still require baseline assertions. |
| Missing record, function, or array closer | ZTS002 precedes ZTS047. |
| Leading union or intersection operator | ZTS002 precedes ZTS047; semantic-parser tolerance does not establish source admission. |
| Root decimal, hexadecimal, exponent, separator, or large integer annotation | ZTS002 precedes ZTS047. |
| Trailing union or intersection operator | ZTS200 follows admission. |
| Missing function comma, arrow, or return | ZTS200 follows admission. |
| Grouped primitive, function type, or spaced array suffix | ZTS200 follows admission. |
| Comment before array suffix | ZTS200 follows admission. |
| Incomplete template | ZTS002 precedes ZTS047. |
| Empty template | `UnresolvedTypeBinding` propagates through stderr, and the JSON response remains empty. |

The empty-template outcome must remain an error rather than becoming a successful unknown type during consumer migration.
Numeric literals need position-specific fixtures because a root annotation differs from nested or declaration contexts.
U8 starts with legacy-only baseline tests before compound parser changes.
Those tests separate source admission, exact retained text, semantic constructor structure, and visible CLI behavior.
The proposed direct lowerer must compare canonical type encodings rather than only type tags.
Canonical encodings alone do not establish exact representation parity.
The key encoder sorts fields and union members, omits function parameter names, and can equate nullable and union representations.
Baseline tests must also assert exact tags and ordered metadata that later display or analysis can observe.

Nested semantic absence needs its own representation.
Missing record field types, missing function returns, and empty template slots can retain `null_type_idx` children.
An optional annotation root alone cannot represent those cases.
The syntax store and lowerer must distinguish an absent child from an invalid index and from a successful unknown type.

Admission facts need the legacy lexical conditions.
An `any` record member key does not count as an `any` type.
A semantic node scan must not replace those lexical eligibility rules with broader universal refusals.
Additional CLI measurements confirm these lexical and semantic distinctions.
The root optional function type produces ZTS055, while the record-nested form displays a function with a required numeric parameter.
The `any` member key reaches type checking, while an `any` member type produces ZTS041.
Numeric union fixtures display literal 200, decimal prefix 1, hexadecimal prefix 0, and separator prefix 1.
Root `true` also reaches type checking.
An empty template slot displays unknown inside the template; it differs from the entirely empty template's propagated error.
Seven further contrasts confirm that source admission depends on the first raw type byte.
A leading comment leaves the colon intact and produces ZTS002 followed by ZTS047.
A grouped numeric literal and grouped leading union reach type checking, unlike their ungrouped counterparts.
String literals, tuples, and readonly arrays also reach type checking.
Readonly tuple syntax displays the same tuple type without a readonly modifier.

Raw byte boundaries also carry semantic meaning.
The legacy type parser skips whitespace but does not skip comments, and array wrapping requires adjacent `[]` bytes.
Whitespace before each adjacent suffix remains allowed; whitespace between the brackets prevents that suffix from wrapping.
Numeric semantic prefixes can stop inside a single runtime number token.
Template semantic scanning treats escapes differently from the runtime tokenizer.
The shared type parser must retain those distinctions rather than normalize tokens into broader acceptance.

The canonical key depth limit is 64; the source admission limit is 512 delimiter levels.
Matching `AbsentType` or `TypeKeyTooDeep` errors do not prove semantic equality.
An implementation frame budget is a separate limit because modifiers can add frames without adding delimiters.
During private comparisons, implementation exhaustion must decline coverage unless the legacy admission scan itself reports excessive depth.
CHECK baseline assertions belong in existing tools tests; the compiler comparison must not import the tools tier.
Astra accepts legacy-only baseline work before final compound implementation approval.

The baseline census contains eight compound families and 31 semantic quirks.
Each census member needs an observed assertion; matching total counts alone do not establish coverage.
An empty record assertion must check its record tag before checking its field count.
TypePool accessors can otherwise turn an absent or unrelated type into an apparently empty result.

Boundary fixtures must separate source admission from constructor capacity and canonical encoding.
An admitted function type with 15 parameters must retain every parameter name, type, flag, and return type.
The corresponding 16-parameter type must expose `TypePoolCapacityExceeded`, rather than normal semantic absence.
Admitted arrays with 63 and 64 adjacent suffixes must retain every array layer in a healthy pool.
Those fixtures must independently check the canonical encoder's depth boundary.

Each annotation needs separate admission-end and semantic-prefix-end positions.
Runtime cursor synchronization uses the admission end.
Lowering uses stored semantic nodes and spans, without reparsing source text.
Every child reference distinguishes present, absent, and invalid states.
Each present child precedes its parent in node order.
The parser publishes an annotation only after all six arrays succeed.
An error or private exclusion restores all six array lengths.
The comparison checks the ordered reachable representation before optional canonical keys.
Matching key errors never establish equivalent representations.
Nullable selection belongs after child lowering because legacy union parsing inspects TypePool tags, not authored syntax tags.
Two `undefined` members retain the legacy nullable representation.
An intersection that lowers to `undefined` can also trigger that same nullable rule.
The syntax graph retains the authored union, grouping, and ignored modifiers until lowering.
Fields and parameters retain full spans as well as borrowed names and child references.
The explicit admission end remains separate from a trimmed raw span and the semantic-prefix end.
Raw primitive recognition must retain `null` and `undefined` as types rather than unsupported references.
An absent later union or intersection member stops the legacy semantic prefix immediately.
The new parser must not resume that expression at another separator.
Record and tuple early exits still attempt their own optional closer once.
Normal exits must not consume that closer twice or remove an enclosing delimiter before an array suffix.
Pre-publication validation rejects mismatched tags, invalid spans, invalid ranges, and forward or missing child indices.
Rollback must preserve previously published annotations.
An excluded parse also restores its caller cursor; diagnostic preflight can advance its own copy explicitly.
Syntactic grouping can exist while its semantic child remains absent.
That absence must still stop legacy expression and suffix parsing before later constructors run.
Main measured three contrasts containing nested empty groups before an unsupported name, array suffix, or 16-parameter function type.
All three CLI commands exit 1 with empty JSON and propagated `UnresolvedTypeBinding`.
The wide function therefore remains unconstructed instead of producing a capacity error.
Complete receipts remain under `/tmp/zttp-reset-20261015/u8-absence-baseline/`.

The admission oracle must retain distinct legacy scans rather than combine their lexical rules.
The `any` pass skips complete nested templates, while the removed-form pass uses its existing simpler quoted scan.
Main measured nested template text containing a quoted `any`; it reaches ZTS200 without an `any` refusal.
Array and readonly-array spellings remain refused even after a semantically complete primitive prefix.
Measured prefix fixtures produce ZTS058 and ZTS059 with their existing suggestions.
An `any` followed by `Array<string>` produces ZTS041 before ZTS058.
Diagnostic collection stops at source-depth refusal rather than scanning the rest of a separately validated span.
A measured 513-level group followed by `any` produces only ZTS044 at line 2, column 528.

Legacy `any` detection also checks identifier suffixes without a preceding-boundary guard.
The measured `number many` fixture produces ZTS041 at line 2, column 24.
The private oracle must preserve that refusal or explicitly decline the lexical case.
It must never correct that public behavior silently.
A seventh CLI contrast places `any` before the overflowing group.
CHECK still publishes only the fatal ZTS044; its failed preparation discards previously collected rows.
Compile mode retains its separate first-refusal policy.
The seven complete CLI receipts remain under `/tmp/zttp-reset-20261015/u8-admission-extra-baseline/`.
Nested function-type arrows remain single arrow sequences during raw scanning.
Their equals signs must not trigger unmatched-parenthesis handling or consume a generic closing delimiter.
Fatal diagnostic collection and private comparison eligibility remain separate decisions.
Depth refusal must not bypass complete-source preflight or accept a later unsupported function declaration.
The private comparison can decline unclosed or compound depth cases until bounded shared validation covers them.
Retained primitive validation must still check the complete annotation and remaining source after a depth refusal.

Quoted interpolation overflow has a distinct legacy path.
Annotation scanning catches errors from quoted scanning, while ordinary delimiter overflow propagates.
The new frontend must preserve that origin or privately decline it until characterization establishes its recovery output.
It must not apply ordinary fatal-depth projection to every quoted overflow.
Bare empty groups retain consumed spans and group ownership even when their semantic result is absent.
Field and parameter spans must therefore include the complete `()` syntax.

Both private capacity branches need forced rejection probes.
A readonly chain must exhaust frames without reaching the source delimiter limit.
Nested templates must exhaust their temporary stack while each interpolation remains below the legacy brace limit.
Both probes preserve the caller cursor and a nonempty checkpoint across all six arrays.
Allocation sweeps must cover member lists, records, function parameters, templates, and direct lowering constructors.
A second-annotation failure must preserve prior syntax before the owner is destroyed.
The successful comparison path also needs an allocation-failure sweep.
The pinned Zig allocating writer maps capacity allocation errors to `WriteFailed`.
The private key comparison must propagate that operational failure rather than accept matching key errors.
Any private conversion to `OutOfMemory` must state that the encoder uses allocating writers only.
U8 must not change the public key encoder's error contract.

Failure comparisons must execute both relevant sides independently.
A legacy constructor failure must not prevent a test from exercising the direct constructor boundary.
Fifteen-parameter success and direct sixteen-parameter rejection need their own observed assertions.
Allocation failure propagates rather than counting as a matching semantic result.

Template interpolation storage introduces no additional source-language limit.
Legacy quoted scanning bounds braces within each interpolation, rather than sharing one nesting count across every nested template.
An exhausted implementation buffer must produce private exclusion unless the actual legacy admission limit also fires.

U8 now retains all eight compound families through the private syntax store and direct constructor lowerer.
The comparison checks ordered semantic structure before supplementary canonical keys.
The exact tools baseline contains 54 compound fixtures.
Both private budget probes use balanced source and preserve nonempty checkpoints and caller cursors.
The measured allocation sweep preserves earlier syntax and uses one allocator for construction and destruction.
The key wrapper projects allocating-writer failures to `OutOfMemory` only within private comparison.
Production callers still use the legacy frontend.

Astra accepted the final U8 source after the recorded corrections.
The corrected small suites passed 2,690 tests with one skip across 16 build steps.
The frontend gate passed 3,424 tests with one skip across 45 build steps, including all 182 diagnostic cases.
The full repository gate also exited 0.
Receipts remain in `u8-final-bounded-corrected.log`, `u8-focused.log`, and `u8-verify.log` under `/tmp/zttp-reset-20261015/`.
These checks establish private compatibility coverage; they do not establish a production cutover or performance improvement.

### U9 preparation findings

`packages/zts/src/stripper.zig` owns declaration admission; `packages/zts/src/type_env.zig` owns alias population and recursive-alias checks.
`packages/zts/src/type_pool.zig` owns nominal identity; `packages/zts/src/type_checker.zig` owns nominal construction and alias-use diagnostics.
The published declaration grammar lives in `packages/zts/src/grammar_registry.zig`.

The published nominal base grammar lists `number` and `string`, but frozen admission also accepts `boolean`.
Nominal admission compares trimmed base text exactly; comments, suffixes, and other bases produce ZTS048.
Structural declarations can omit an equals sign or body in the legacy scanner; empty bodies later supply no alias.
Semicolons are optional, and multiline unions and intersections can continue across newlines.
Exported type declarations emit no runtime export, and TypeMap does not retain their export status.

Declaration recognition uses a simplified statement boundary.
Outside that boundary, `structural` and `nominal` remain ordinary identifiers.
Source review indicates that indentation can prevent recognition because the boundary check reads the last emitted byte.
A characterization must confirm that behavior before the private parser claims parity.
Main measured 16 declaration fixtures through the legacy CLI.
The sources, full responses, stderr, and direct exit statuses remain under `/tmp/zttp-reset-20261015/u9-declaration-baseline/`.
Every command exits 1, with distinct failure stages.
An unindented root declaration reaches ZTS200 for its deliberately incorrect string initializer.
An unindented declaration inside a function reaches the same type mismatch.
Leading spaces, indentation after a newline, a space after a semicolon, and indentation inside a function instead produce ZTS047.
Those declarations remain runtime input rather than supplying alias meaning.
A function sharing a nominal alias name still produces ZTS214 when called.
The equivalent structural alias collision reaches contract checking with ZTS500 instead.
The direct syntax path must preserve these measured declaration and nominal-call decisions.
Legacy `type`, `distinct type`, and `interface` spellings retain their existing source refusals.
Generic declarations remain deferred until U10 supplies their semantics.

Alias population uses a module-wide namespace and processes declarations in source order, including recognized nested declarations.
Aliases populate before variable and function annotations, while alias declarations themselves lower in source order.
A later declaration replaces an earlier name without a duplicate diagnostic.
Structural and nominal declarations share that namespace and can replace each other or previously registered ABI names.

A bare alias root eagerly captures an existing named alias index.
A missing name becomes a deferred reference, and references inside compound bodies remain deferred.
Thus `A = string; B = A; A = number` retains string meaning for `B`.
The forward form `B = A; A = string; A = number` resolves `B` through the final `A`.
CLI contrasts confirm these semantic outcomes.
The eager form rejects a number with ZTS200 naming `string`.
The forward form rejects a string with ZTS200 naming the retained reference `A`.
The forward form accepts a numeric initializer through type checking and reaches contract checking with ZTS500.
Semantic resolution must therefore remain separate from diagnostic display.
Eager lookup also requires the exact trimmed body, rather than only a semantic reference root.
The measured `B = A tolerated_suffix` form retains deferred `A` meaning after `A` changes from string to number.
Its string initializer produces ZTS200 naming `A`; its numeric initializer reaches ZTS500.
The ignored suffix therefore changes lookup timing without contributing a different type expression.
An unindented nested declaration also supplies module-wide alias meaning to an outer variable.
The direct lowerer must preserve that distinction rather than eagerly resolve every reference.

Nominal identity uses the nominal name and base tag, without a unique declaration identity.
Same-name nominal nodes over the same base remain the same type; different nominal names remain incompatible.
Nominal values remain assignable to their base, while reverse assignment requires the existing annotated construction path.
Production refuses callable nominal constructors, despite older specification prose describing them.
The constructor check uses name-only alias lookup, so runtime-name collisions need a characterization before consumer cutover.
Pool nodes truncate stored name lengths to eight bits, while environment keys retain full names.

Recursive aliases form a finite reference graph without body expansion.
Records, tuples, arrays, and `Dict` guard recursive paths; unions, intersections, nullable types, and function edges do not.
The existing contractivity census marks current alias-map entries after population.
ZTS212 appears when a variable annotation uses a marked alias; an unused invalid alias supplies no diagnostic through that path.
The measured unused cycle reaches contract checking with ZTS500; its used contrast produces ZTS212 at the variable.
The alias walk has 32 path slots, and ordinary reference resolution separately follows at most eight hops.
Repeated declarations affect that census through their final map entries.

The store needs named-reference nodes and declaration records with kind, component spans, full span, source order, and authored scope.
An absent structural body must remain distinct from an absent declaration.
Authored scope supports syntax ownership, while lowering retains the existing module-wide namespace.
Type-only syntax adds no runtime statement, node, binding, atom, constant, or value export.
Following runtime nodes retain original byte offsets.

Compiler lowering must process declarations after ABI registration and preserve root-only eager alias lookup.
It must retain existing nominal construction rules and the existing recursive-alias census.
The syntax lowerer must check both environment and pool health before publishing completed results.
Allocation probes must cover declaration arrays, namespace keys, nominal names, recursive-alias state, and partial initialization cleanup.
Frozen fixtures in the stripper, TypePool, TypeEnv, and checker supply separate admission and semantic evidence.

U9 has four implementation owners: `parser/type_syntax.zig`, `parser/parse.zig`, `typed_frontend_compare.zig`, and `type_env.zig`.
Main retains tools baselines, documentation, verification, and Git operations.
Production callers remain unchanged.

Named-reference nodes borrow name spans.
A seventh store array holds structural and nominal declarations.
Each declaration retains component spans, an optional export span, a complete erased span, source order, and authored scope.
An absent body differs from a present body whose semantic child is absent.
Checkpoints, validation, rollback, and destruction cover all seven arrays.
Declaration publication occurs last, and every failed or excluded parse preserves the caller cursor.

Program and block loops consume type declarations without appending runtime statements.
Other statement positions do not gain declaration recognition.
The parser retains the last erased range to reproduce the legacy boundary byte.
An erased newline remains a newline; another erased byte becomes a space.
Original intervening whitespace still controls the following boundary.
This rule avoids a padded source pass while preserving adjacency and indentation behavior.
Generic declarations remain private exclusions until U10.

Whole-body alias lookup precedes semantic parsing for every spelling, including primitive names.
Source review shows that legacy declaration names can replace `string`, `number`, or another primitive spelling.
The lowerer must query the exact trimmed body before lowering a declaration, nominal base, or annotation root.
Nested compound children do not perform that whole-body lookup.
Grouped and suffixed bodies only match when the complete trimmed body is an existing namespace key.
Four public contrasts now confirm primitive-name collisions and their nested exception.
Declaration and annotation roots reject a string initializer with ZTS200 naming `number` after `structural string = number`.
The nominal contrast rejects its string initializer with ZTS200 naming `UserId`.
The compound contrast still names `string | boolean`, so nested primitive syntax does not use whole-body alias lookup.
Each command exits 1; complete responses remain under `/tmp/zttp-reset-20261015/u9-primitive-alias-baseline/`.

The direct lowerer registers existing module and ABI types before source declarations.
It then applies declarations in source order and lowers annotations after alias finalization.
Named-reference children retain deferred references; exact whole-body matches retain the existing eager lookup.
The proposed `finishTypeAliasPopulation` operation exposes the existing contractivity census.
Legacy population retains its current call position and additive behavior across repeated population calls.
The new operation does not clear either census map.
The fresh direct environment invokes the operation once after its complete declaration batch.

The first U9 slice contains one structural alias and one nominal alias, each with one annotated variable.
That slice checks runtime neutrality, declaration ownership, and direct semantic parity.
Main then runs unfiltered `zig build test-zts -j1 --summary all` before broader implementation.
Main retains the 16 measured CLI contrasts as exact tools baselines.
An explicit case census supplies the complete coverage count; an estimated count supplies no acceptance evidence.
Second-declaration allocation probes preserve earlier syntax, and lowering probes cover names, maps, nominal storage, and annotation publication.

Named array suffixes preserve a distinct legacy prefix rule.
`Alias[][]` retains one array layer, while `(Alias)[][]` retains two layers.
The syntax store must preserve their distinct semantic ends instead of applying the primitive suffix loop universally.
A completed readonly modifier must not consume another suffix after its child has stopped.
Readonly named operands also need their existing implicit `Readonly<Named>` application.
Existing environment projection resolves that application through root unions, intersections, and nullable types.
That projection does not traverse record fields or tuple elements.
Direct lowering must preserve the same traversal boundary without reparsing text or introducing recursive traversal.
An exposed existing postparse operation can retain that behavior while authored generic applications remain outside U9.
An exact whole-body alias hit returns immediately and bypasses postparse projection, matching `resolveType`.
Other roots invoke the existing projection once after their syntax lowers.
Record, tuple, array, and function children retain unresolved implicit applications under that existing traversal boundary.

Six public contrasts confirm these named-type boundaries.
Their ZTS200 messages retain `Alias[]`, `Alias[][]`, `readonly string[]`, `{ field: Readonly<Items> }`, `[Readonly<Items>]`, and `readonly string[] | undefined`.
Each command exits 1 at line 3, column 1.
Complete responses remain under `/tmp/zttp-reset-20261015/u9-named-boundary-baseline/`.

Declaration-only comparison must inspect final alias-map membership and values rather than assume an annotated variable exists.
A missing key differs from a present key whose value is `null_type_idx`.
An empty body supplies no alias, while nonempty syntax with absent meaning can publish a null alias.
Ordered comparison checks nominal flags and names before accepting scalar tags.
It also compares reference names and implicit application bases and ordered arguments.
Separate assertions compare final contractivity flags without expanding recursive reference graphs.
The revised semantic census has 56 named members; an exhaustive fixture table must observe every member.
Its cases cover admission, aliases, nominal identity, readonly projection, suffixes, recursion, limits, comparison, and existing refusals.
Separate invariant tests cover component spans, ownership, runtime neutrality, seven-array rollback, allocation failures, and health.
The public tools baseline now contains 26 measured fixtures across the three recorded directories.

The first U9 slice now retains a node range for each declaration body and annotation.
Exact whole-body alias hits skip those ranges before constructor calls.
Simple declarations lower in source order before the remaining annotation constructors.
The unfiltered analyzer suite passes 2,483 tests with one skip across 13 build steps.
Its receipt is `/tmp/zttp-reset-20261015/u9-first-slice.log`.
Production callers remain unchanged.

Source review found an unenforced ownership invariant in range validation.
Root-only validation can accept a child that references an earlier owner's skipped range.
No parser-produced defect has been reproduced for that shape.
The full U9 stage must reject every cross-owner child and overlapping owner ranges.
Direct-child, indirect-member, and overlapping-range mutations must each fail validation.
Private declaration eligibility also needs its own complete admission checks.
The first-slice preflight can admit primitive prefixes with unsupported suffixes before collecting their declaration diagnostics.
For example, `number any` can propagate `UnsupportedAnyType` instead of producing a private refusal or exclusion.
The full stage must collect declaration diagnostics or decline every uncovered suffix before invoking legacy preparation.
Astra accepted the bounded first-slice fixtures and retained these broader shapes as full-stage requirements.
The unfiltered tools suite also passes all 213 tests, including the 26 exact public declaration fixtures.
Its receipt is `/tmp/zttp-reset-20261015/u9-public-baseline.log`.
Six further public probes now freeze declaration suffixes and empty bodies.
`number any`, `number void`, `number Array<string>`, and `number ReadonlyArray<string>` produce ZTS041, ZTS060, ZTS058, and ZTS059 respectively.
Each suffix diagnostic starts at line 1, column 27.
An empty body and a nonempty `()` body both reach ZTS500 without an annotated use.
Those identical public outcomes do not establish identical alias-map membership.
All six commands exit 1; receipts remain under `/tmp/zttp-reset-20261015/u9-declaration-admission-baseline/`.
The complete public declaration baseline now contains 32 sources.

The first full U9 checkpoint is not accepted.
Source review found the following remaining defects and gaps.

| Condition | Defect or gap | Required verification |
|---|---|---|
| Several declarations share `; structural` on one line | Census fixtures decline before testing their named semantics. | Recognized newline fixtures must parse, lower, and assert their named property. |
| A census row uses `covered_by_named_invariant` | The row records coverage without an assertion. | Every row must execute a concrete property check before coverage records success. |
| Nominal assignment, hop limits, or long names use only equivalence | The probe does not execute the behavior in its name. | Probe assignability, call `resolveRef`, and cross the actual pool-name boundary. |
| A declaration body starts with a number or leading operator | Variable-style admission rejects declaration syntax that legacy admission accepts. | Compare admitted numeric and leading-operator declarations. |
| Blank lines follow a continuation operator | The new previous-byte scan stops earlier than the legacy significant-character scan. | Compare consecutive-newline union and intersection declarations. |
| An earlier declaration or annotation already produced a diagnostic | A later unsupported declaration or private budget can become incorrectly eligible. | Distinct unsupported and budget exclusions must reject regardless of earlier diagnostics. |
| The direct store omits an unused declaration | The oracle visits only direct declarations and can miss the legacy-only alias. | Compare declaration count, order, kind, and final namespace membership in both directions. |

Main also found incomplete erased spans for declarations without semicolons.
The full span must include consumed equals signs and whitespace, even when no body supplies an alias.
Component containment and source-order validation need explicit rejection probes.
These findings describe the unaccepted private checkpoint, not a production frontend change.

Nominal admission has a distinct scan policy.
Structural removed-form scanning must not add `void`, Array, readonly-array, or optional-function refusals to a nominal base.
Seven public nominal contrasts confirm ZTS048 for invalid, empty, and missing bases, with one exception.
A root `any` base reports only ZTS041 at the same source position as the suppressed scalar refusal.
Collect mode removes later diagnostics at an already occupied line and column; compile mode separately stops at the first refusal.
The measured `number any` base reports ZTS041 at column 22 before ZTS048 at column 15.
Those distinct positions retain both diagnostics in collect mode.
All eight commands exit 1; receipts remain under `/tmp/zttp-reset-20261015/u9-nominal-admission-baseline/`.

Declaration names follow raw identifier scanning rather than runtime token categories.
Four public contrasts use `true`, `null`, `undefined`, and `function` as structural alias names.
Each rejects a string initializer with ZTS200 naming `number` at line 2, column 1.
All four commands exit 1; receipts remain under `/tmp/zttp-reset-20261015/u9-keyword-name-baseline/`.
The complete public declaration baseline now contains 44 sources.

Declaration-bearing allocation sweeps remain required beyond the first full checkpoint.
The old annotation-only sweeps do not cover alias keys, nominal names, contractivity maps, or runtime failure after declaration parsing.
Each new sweep must first establish successful expected aliases or annotations before injecting allocation failures.
Four additional public probes confirm admitted numeric, leading-union, and consecutive-newline declaration bodies.
Their mismatch messages retain literal `1`, `number | string`, and the expected intersection of two records.
All four commands exit 1 at type analysis.
Receipts remain under `/tmp/zttp-reset-20261015/u9-body-admission-baseline/`.
The complete public declaration baseline now contains 48 sources.

The corrected small roots pass 2,710 tests with one skip across 16 steps.
That execution includes all 217 precompile tests and the 48 public declaration sources.
Astra still rejects the private checkpoint for five source defects.

| Condition | Remaining defect | Required verification |
|---|---|---|
| Compile mode finds an invalid nominal base | Preflight can return before checking later unsupported source. | Preserve the diagnostic and complete eligibility checks for the entire source. |
| A diagnostic precedes unsupported syntax in one declaration | Diagnostic presence can bypass the syntax exclusion. | Always decline unsupported syntax and private implementation budgets. |
| A comment separates declaration header components | Token lookahead recognizes forms that legacy raw scanning does not recognize. | Check raw whitespace gaps and preserve recognition or decline the form. |
| A present body ends before trailing whitespace | The declaration span omits bytes that legacy consumes. | Compare full spans for newline and trailing-space cases. |
| Whitespace separates a nominal name from its semicolon | The missing-base diagnostic points before the whitespace. | Compare the exact diagnostic position against legacy. |
| A block or collision census row encounters a parser error | The test can count success without the required runtime shape. | Require successful positive parsing and concrete runtime identity; characterize the negative error exactly. |

The final namespace oracle currently reaches no dictionary or generic-parameter types through admitted U9 aliases.
Its explicit exclusions are therefore not demonstrated U9 defects.
U10 must extend the oracle before generic applications and parameters reach that comparison.
Three public header contrasts now freeze comment recognition and the spaced missing-base position.
All commands exit 1; receipts remain under `/tmp/zttp-reset-20261015/u9-header-baseline/`.
The complete public declaration baseline now contains 51 sources.
The next corrected small roots pass 2,713 tests with one skip across 16 steps.
Astra then found that token lookahead can consume a semicolon after an intervening comment.
Legacy stops the declaration before that comment and rejects the standalone semicolon.
Terminator consumption must match the raw whitespace endpoint, not merely the next token kind.
The public newline-comment contrast reports ZTS001 at line 2, column 6 and exits 1.
Its receipt joins `u9-header-baseline/`; the complete declaration baseline now contains 52 sources.
The closed boundary review adds two related requirements.
Nominal-refusal recovery must use the same raw terminator boundary.
The continuation scan must skip whitespace before the equals sign that precedes a trailing `>`.
Legacy absorbs the following statement in `structural A = number = >\nconst value = 1;`.
The private path must preserve that runtime boundary or decline the form.
An unclosed trailing comment must also decline private eligibility before legacy preparation.
The current comparison propagates `UnterminatedComment` for that case; it does not report false equivalence.
The closed review found no further mismatch in ordinary header gaps, identifier shapes, empty bodies, or newline and EOF positions.

Astra accepts the final U9 source after the five earlier blockers and three boundary findings are resolved.
The final probes assert raw spans, runtime semicolon rejection, retained runtime structure, and both admission modes.
The malformed-trivia scan uses a source-bounded tokenizer loop and an explicit progress check.
Source acceptance establishes no execution result; the complete frontend suite and common gate remain required.

### U10 preparation findings

`packages/zts/src/stripper.zig` owns current generic admission and angle-bracket speculation.
`packages/zts/src/type_env.zig` owns parameter lists, alias maps, and application projection.
`packages/zts/src/type_pool.zig` owns application storage and substitution; `packages/zts/src/type_checker.zig` owns inference and constraint enforcement.
The published grammar omits defaults, but the legacy source path admits balanced defaults in function, arrow, and structural parameter lists.

Function declaration generics require `<` immediately after the name, while structural declarations permit intervening whitespace.
Explicit call arguments require the final `>` to touch `(`.
The call probe retains comparison and shift syntax instead of treating every angle pair as type arguments.
Generic declaration scanning handles balanced angles, arrow tokens, and the existing depth limit.
Removed-form scanning still precedes runtime parsing.
Nested generic closers require type-local splitting of `>>` and `>>>`; runtime shift tokens must remain unchanged after failed speculation.

TypeEnv retains at most eight function parameters, alias parameters, and explicit call type arguments.
Its comma splitter silently leaves a ninth item outside that semantic projection.
TypePool itself can retain wider applications, so its storage capacity must not expand TypeEnv admission or projection.
Source-admitted defaults remain semantically ignored, while default syntax still needs authored spans for printing.
Function constraints lower after all parameters enter scope; generic-alias constraints are parsed and discarded.
An `extends` bound can retain an ignored default suffix through existing prefix parsing.

Explicit call arguments skip inference and require the signature's existing argument count.
Inference uses value arguments, not the expected return type, and constraints run after binding.
Substitution enters the existing record, array, union, intersection, tuple, function, nullable, and nested application shapes.
Substitution beyond depth eight returns the inner branch unchanged; unification at the same ceiling leaves parameters unbound.
Pool and environment allocation failures retain their existing sticky health state.

Legacy semantic application parsing can publish a prefix despite missing commas or a missing closing angle.
Source admission must be checked separately before the private path claims those forms remain accepted.
A generic application can leave an array suffix unconsumed.
User aliases require exact arity, while builtin utility applications accept a minimum arity and ignore surplus arguments.
`Dict` has its existing exact two-argument special case.
Application projection enters outer applications, unions, intersections, and nullable wrappers, but omits some nested compound positions.

Generic and non-generic aliases occupy separate maps and can coexist under one name.
Each map retains its own last declaration; a non-generic declaration does not remove a generic declaration.
Source aliases can replace ambient `Proof` and `Effects`, while builtin utilities resolve before user applications.
A complete non-generic alias resolves before a generic parameter scope for bare names.
Nested references can instead reach parameter substitution, making same-name collisions shape-dependent.
Duplicate parameter names resolve to the first matching scope entry.

Repeated function names retain distinct signatures through their opening-parenthesis identities.
Hash-map iteration makes name-only signature maps unsuitable as the new owner identity.
The syntax store needs parameter records with constraint, default, and full spans, plus generic owner and call-argument records.
Named references and application nodes remain engine-tier syntax without compiler imports.
Compiler lowering must use syntax records directly rather than reconstruct TypeMap, name ordinals, offset joins, or type text.
U11 owns final attachment, and U12 owns checker migration; U10 does not establish initializer enforcement.

Generic type syntax adds no runtime nodes, bindings, atoms, constants, strings, or scopes.
Call locations remain at `(` after type-argument consumption.
Comparisons must cover repeated signatures, ignored defaults, distinct constraint policies, namespace collisions, silent truncation, depth exhaustion, and allocation failure.
Existing fixtures in `source_frontend.zig`, TypeEnv, TypePool, the checker, the stripper, and `frontend_fuzz.zig` supply separate evidence.

Main measured 32 public generic contrasts through the legacy CLI.
Every command exits 1, but the failure stages distinguish admission, type analysis, and contract analysis.
Complete sources, responses, stderr, and direct statuses remain under `/tmp/zttp-reset-20261015/u10-generic-baseline/`.

A space before function generic parameters produces ZTS003.
Generic arrows and source-admitted defaults retain their inferred string results.
A spaced structural parameter list resolves its application to a record.
The alias constraint contrast accepts `number` semantically despite an authored `extends string` constraint.
Eight explicit arguments resolve the eighth function parameter, while a ninth parameter remains the reference `I`.
Eight and nine explicit arguments then produce the same ordered ZTS203 and ZTS200 diagnostics for that unresolved parameter.

Generic and non-generic aliases retain both meanings in either declaration order.
A complete alias named `T` before a function parameter named `T` produces ZTS208 and a numeric return mismatch.
Duplicate function parameter names produce ZTS208 and retain `T` in the later mismatch message.
Repeated aliases retain the final declaration within their own namespace.

An ungrouped application followed by `[]` still displays its instantiated record without an array.
The grouped contrast displays unresolved `Box<string>[]`.
Root nested applications and union members project their generic aliases.
Record fields and tuple elements retain `Box<string>` application text.
An adjacent explicit call returns string, while whitespace after its closing angle produces a boolean expression.
Four comparison and shift controls reach ZTS500 with no earlier parse or type failure.

Main measured 21 additional contrasts in `/tmp/zttp-reset-20261015/u10-generic-extra-baseline/`.
All commands exit 1 with complete JSON responses.
Three nested closing angles retain the expected nested record meaning.
A missing comma in an application retains two unresolved arguments, while the analogous call still returns string.
A missing call closer becomes a boolean expression; a missing application closer produces ZTS002 followed by ZTS047.
User alias arity mismatches retain unresolved applications.
Builtin `Partial` ignores surplus arguments and wins over a same-name source generic alias.
Wrong `Dict` arity also retains an unresolved application.
Source declarations replace ambient `Proof` and `Effects` generic meanings.

The forward constraint and nested-comma constraint contrasts produce ZTS209 followed by ZTS200.
An explicit method-call contrast reaches ZTS500 without a type mismatch.
That result establishes admission, but it does not establish method inference or return-type enforcement.

Generic lists retain a narrower refusal scope than ordinary annotations.
An `any` constraint produces ZTS209 followed by ZTS200, and an `any` call argument produces ZTS203 followed by ZTS200.
An `any` default remains ignored and reaches the ordinary string mismatch.
The direct parser must not add preparation refusals for those admitted generic-list positions.
Three further probes distinguish the removed-form scanner from the `any` scanner.
`void` in a constraint produces ZTS060, while `Array<string>` in a default or call argument produces ZTS058.
Those three commands also exit 1; receipts remain under `/tmp/zttp-reset-20261015/u10-generic-refusal-baseline/`.
The complete public generic baseline now contains 56 measured sources across the three directories.

Fourteen further probes confirm raw projection behavior in `/tmp/zttp-reset-20261015/u10-generic-projection-baseline/`.
Quoted commas and comment commas can create two semantic call arguments from one authored argument.
The one-parameter contrasts produce ZTS210 before ZTS200.
A comma inside a parameter comment creates an unbound parameter named `*/`.
`T extends DictKey` accepts numeric inference, while `T extends DictKey = string` produces ZTS209 before ZTS200.
The default suffix prevents the exact `DictKey` special case even though default application remains ignored.
All four name-length contrasts produce the same visible string or string-array mismatch at lengths 32 and 33.
Those results do not establish a visible difference in scope lookup.
The implementation must still preserve existing scope storage and lookup behavior.
The complete public generic baseline now contains 70 measured sources across four directories.

U10 retains the same four implementation files as U9.
Its first slice adds application syntax and private lowering in `type_syntax.zig` and `typed_frontend_compare.zig` only.
An ambient `Proof<Response, "pure">` annotation supplies the first complete path.
Nested closers, application suffixes, rollback, allocation failures, and runtime neutrality complete that slice.
Astra accepted that limited first slice after U9's commit and API refresh.
The full U10 design still requires the following compatibility boundaries.

Application nodes retain a base child and an ordered range of arguments.
Owned arrays retain generic parameters, generic owners, and explicit call arguments.
The final store layout must separate authored parameter spans from their projected semantic fragments.
Parameter records retain names, full spans, constraints, defaults, and distinct legacy semantic-bound spans.
Structural owners identify declarations; provisional function and call owners capture their opening-parenthesis offsets directly.
U11 replaces those captured offsets with final runtime-node ownership.
The parser must not reconstruct owners from text or search names.
Validation, rollback, and destruction cover every added array.

Type-local parsing consumes each closing-angle byte without changing runtime shift tokens.
Failed speculation restores the complete runtime cursor and type-store checkpoint.
Successful speculation preserves the call location at its touching opening parenthesis.
A later runtime body or call failure cancels pending syntax records while retaining legacy parser recovery.
It must not rewind runtime progress to the generic opener.

Authored syntax and legacy semantic projection remain separate.
`splitTopLevelCommas` counts raw bracket bytes without skipping quotes or comments.
Structured argument boundaries cannot replace that projection without changing the measured behavior.
Retained source spans must supply the existing projection without TypeMap reconstruction or a text-resolution fallback.
Defaults and alias constraints can remain opaque when source admission accepts syntax outside semantic type grammar.
Those ignored fragments must not allocate TypePool nodes or introduce new semantic refusals.
Function constraint bounds retain their authored default suffix for legacy prefix resolution.
Exact `DictKey` handling runs before ordinary alias lookup, matching `resolveBound`.

Direct population retains the existing eight-item projections and the separate wider application storage.
All admitted function parameters exist before constraints lower.
Generic scope storage keeps its existing 32-byte names, while declared parameter names remain complete.
Existing lookup order, duplicate-name selection, name truncation, and sticky allocation health remain authoritative.
The direct APIs publish lowered indices and explicit names rather than TypeMap entries or reconstructed annotation text.
A generic owner alone must not create a function signature.
Legacy parameter, return, or predicate annotations must first establish that signature.

Application lowering retains parse-time constructor rules before environment projection.
Exact-two-argument `Dict` uses its existing direct constructor.
Exact-one-argument `Readonly` with an inline record transforms that record even inside another record or tuple.
Other applications retain the existing generic application constructor and root projection boundary.
Exact whole-body alias hits still bypass projection.
No production caller switches during U10.

Source inspection identifies an application rule for semantic absence.
`TypePool.parseGenericApp` stops before appending an argument whose meaning is absent.
It still publishes the application with the preceding arguments.
Private tests must distinguish that result from an absent application or a list that consumes later arguments.
The tests must assert both the retained argument count and the semantic-prefix end.
The legacy parser still attempts one adjacent closing angle after an absent argument stops the list.
Main corrected the first slice to retain that step and added two cases with an adjacent closing angle.

The first application slice remains unaccepted after its initial small-root run.
Two rollback fixtures still expected applications to be excluded, and the proof census used a stale marker spelling.
Main retargeted the exclusions and used the published proof marker constant without weakening the expected property.
All 219 precompile tests pass; the small roots report three failures.

Astra found an additional capacity defect in direct application lowering.
The first slice allocated a semantic reference for every base before lowering its arguments.
Legacy allocates no base reference for direct dictionary and inline readonly constructors.
Ordinary applications allocate their base reference after their arguments.
The extra node and name bytes can move a valid input across the pool's capacity boundary.

Direct lowering must defer base materialization until constructor dispatch.
Validation must require exclusive named-reference bases before a deferred-base mask can select those syntax nodes.
No ordinary child, owner root, or second application can reuse such a base.
Validation must use bounded iteration and explicit scratch ownership without quadratic scans of source-sized node sets.
Capacity tests must compare successful constructors at the exact required capacity and the named failure with one fewer slot.
Node and name deltas must show that direct constructors allocate no unused semantic base.
The bounded correction keeps structural `Store.validate()` allocation free.
`Store.planApplicationBases(allocator)` owns one mask and checks base roles with linear passes over roots and child edges.
`lowerSyntaxStore` owns and releases that plan before it performs semantic construction.
Later syntax additions must extend the plan's root and edge census.
Astra accepts the corrected application-only source after reviewing allocation order, cleanup, base ownership, and capacity probes.
That verdict covers source inspection only; the unfiltered small roots still determine execution acceptance.
The corrected unfiltered small roots now pass 2,725 tests with one skip across 16 steps.
That run executes all thirteen application census rows and the capacity probes.
The full U10 phase still requires generic owners, semantic parameter projection, explicit calls, and its final gates.

An exhaustive semantic census must cover admission, constraints, defaults, arity, scopes, collisions, substitution, inference, limits, rollback, and allocation failures.
Each enum member needs its own observed fixture row.
The full implementation waits for U9's commit, refreshed APIs, and Astra acceptance of the amended design.

The amended design separates authored parameter spans from legacy semantic parameter fragments.
Each parsed semantic fragment owns its own disjoint node range.
The existing raw splitter supplies at most eight semantic entries, including its current treatment of quoted and comment bytes.
The direct parser stores each fragment's recognized prefix without calling a broad text-resolution fallback.
Ignored default and alias-constraint spans remain opaque.
The earlier proposed count of 97 cases is withdrawn until the final fixture table establishes the exact census.

New generic-scope APIs must own scope entry and exit explicitly.
`pushGenericScope` records allocation failure without returning an error, so a wrapper cannot assume that a push succeeded.
A failed push must not make cleanup pop an existing outer scope.
The direct API must check the prior depth and health before publishing an owned scope.
An error union and a recorded prior depth can enforce that ownership without changing legacy callers.

Constraint installation must also preserve legacy indexing after skipped empty names.
Main measured `f<=string,T extends number>` against the ordinary constrained declaration.
The malformed but admitted prefix suppresses the constraint and produces only the ordinary string mismatch.
The control produces ZTS209 before ZTS200.
Both commands exit 1; receipts remain under `/tmp/zttp-reset-20261015/u10-generic-empty-name-baseline/`.
The complete public generic baseline now contains 72 sources across five directories.

U10 has three separate evidence sets.
Complete-source comparisons cover applications, structural generic aliases, untyped generic owners, and untyped explicit calls.
Direct fragment and environment tests cover parameter projection, constraints, defaults, substitution, call arguments, and allocation failure.
The 72 public tools fixtures remain regressions for the unchanged production path.
Those public fixtures do not establish private semantic parity for typed function signatures during U10.

Sources with parameter, return, or predicate annotations remain outside U10's private complete-source comparison.
U10 must not erase those colons or supply their missing annotation owners.
Untyped generic functions and arrows establish syntax, records, offsets, and runtime neutrality only.
Their tests must assert that a generic owner alone creates no function signature.
U11 adds complete typed-source comparisons and final owner attachment.
U12 then migrates checker behavior to those owners.
This boundary replaces the earlier proposal to compare every public generic fixture through the U10 private path.

The proposed scope-entry API returns `!ParsedGenericScope`.
That owning value retains the prior scope depth and the compact generic parameters.
Scope exit accepts the owning value and removes only its corresponding scope.
A failed entry must retain every outer scope and expose the recorded allocation failure.
Direct API tests must preserve empty-name constraint indexing and the existing bounded scope-name storage.

Population retains the existing phase order rather than introducing lexical generic resolution.
All aliases populate first.
Each function generic list then uses an independent scope.
Explicit call arguments resolve outside every function generic scope.
An enclosing function supplies no generic scope to nested owners, body variable annotations, or explicit call arguments.
Tests must distinguish those cases from lexical substitution.

A recorded alias list such as `<>` remains generic even when its projected parameter count is zero.
Publication follows the recorded list, not its projected count.
An empty alias body publishes neither an ordinary alias nor a generic alias.
Two public contrasts confirm that `Box<>` resolves to `number` only with the nonempty body.
Both retain unresolved bare `Box` and exit 1 with two ZTS200 diagnostics.
Receipts remain under `/tmp/zttp-reset-20261015/u10-generic-empty-owner-baseline/`.
The complete public generic baseline now contains 74 sources across six directories.

Astra accepts the amended U10 design, subject to the final U9 API refresh.
Scope entry must undo a successful push if a later allocation fails.
Scope exit must validate its owning value before removing the corresponding scope.
Pending-owner tests must cover `parseBlock` recovery that records an error but still returns a node.
Nominal generic lists remain explicit private exclusions unless a later accepted design adds their distinct legacy behavior.
The ordered comparator must support dictionary and generic-parameter types before new semantic tests reach those tags.
Each census row must execute its named property before recording coverage.
This acceptance covers design and source inspection; implementation and execution remain outstanding.

#### U10 final record and API refresh

The next slices separate authored syntax from the legacy semantic projection.
The store gains six arrays: `generic_parameters`, `projected_generic_parameters`, `semantic_fragments`, `generic_owners`, `authored_call_arguments`, and `explicit_call_arguments`.
Every checkpoint, rollback, destructor, and ownership check covers all six arrays.

An authored parameter retains its raw span, trimmed span, and optional recognized metadata.
Recognized metadata retains the name, `extends`, constraint, equals sign, and default spans.
Recognition failure does not reject a balanced list or change cursor movement.
The authored splitter respects quoted strings and comments.
The independent legacy projection retains raw comma behavior, empty names, and the eight-item limit.
The splitter omits whitespace-only pieces before applying that limit.
A nonempty piece such as `=string` retains its empty parsed name.
Authored empty pieces and projected empty names require separate tests.

A projected parameter retains its raw span, name span, optional legacy bound span, and optional semantic fragment index.
Alias constraints and defaults remain opaque.
A function bound retains its default suffix and owns a semantic fragment.
A semantic fragment retains its raw span, root, node range, and semantic prefix end.
Fragment ranges remain disjoint from declaration bodies, variable annotations, and other fragments.
The application-base plan includes every fragment root and child edge.

A generic owner retains its list span and the authored and projected parameter ranges.
A structural owner identifies its exact declaration index.
Provisional function owners identify the captured opening parenthesis and distinguish declarations from arrows.
A declaration retains its optional generic owner index.
An explicit call retains its touching parenthesis offset, list span, authored argument range, and projected fragment range.
U11 replaces provisional offsets with final runtime node ownership.

`beginParsedGenerics` returns an owning scope with prior depth, token, compact parameters, count, and active state.
The API confirms a successful push and unwinds that push after a later allocation failure.
`endParsedGenerics` checks depth, token, and active state before removing the scope.
The owning value also identifies its exact TypeEnv instance.
Cleanup removes a valid owned scope even after pool or environment poisoning.
Health checks must not return before that cleanup.
`installParsedConstraints` preserves original projection indexes against the compact parameter count.
`resolveParsedGenericParam` calls the existing `GenericScope.resolve`; complete published names cannot bypass its 32-byte storage.
`putParsedGenericAlias` accepts lowered bodies and explicit names.
`putParsedCallTypeArgs` copies at most eight lowered indices.
Every API propagates unhealthy pool or environment state.

Bound lookup tests exact `DictKey` before ordinary aliases.
Other root lookup tests a complete ordinary alias before the owned generic scope.
Stored syntax lowering and existing application projection follow those lookups.
Nested references retain the existing substitution timing.
Semantic fragments parse their exact bounded spans without ordinary annotation admission.
Numeric prefixes, leading operators, `any`, and raw-split partial strings retain legacy prefix behavior.
The whole-list removed-form check remains separate.

Alias publication distinguishes raw absence from semantic absence.
`DeclarationBody.absent` publishes no alias.
A present body such as `()` still publishes a generic alias with a healthy `null_type_idx` body.
The direct publication API must not suppress that entry.
Main measured the applied `()` contrast returning `UnresolvedTypeBinding`, with exit 1 and no JSON response.
The raw-absent contrast returns two ZTS200 diagnostics and exits 1.
The receipts remain in `/tmp/zttp-reset-20261015/u10-generic-null-body-baseline/`.
Direct tests must assert map membership as well as the source result.

Slice A adds structural generic declarations and direct environment APIs in `type_syntax.zig`, `typed_frontend_compare.zig`, and `type_env.zig`.
Its first fixture uses `Box<T extends string = boolean>` with a record body and an `undefined` initializer.
The test asserts numeric field substitution without requiring object initializers outside current private eligibility.
The ordered oracle adds generic-parameter support before those comparisons execute.

Slice A review found that a uniform bracket counter can tighten generic-list admission.
Legacy skips each matching bracket group without interpreting its angle bytes.
Ignored defaults and constraints therefore admit angle operators inside those groups.
Main measured `<T = (left > right)>` and `<T extends { value: Missing > }>` with a numeric alias body.
Both admit the declaration and report only the later numeric assignment mismatch.
The authored scanner must preserve those source boundaries without changing the independent raw projection.

Authored metadata also needs quote-aware equals recognition and arrow-aware nested delimiters.
Main measured `<T extends "a=b" = boolean>` and `<T = Wrap<(x: string) => number, string>>`.
The nested arrow remains one authored parameter, while legacy raw projection produces two semantic parameters.
All four commands exit 1 with ZTS200 at line 2, column 1.
The receipts remain in `/tmp/zttp-reset-20261015/u10-generic-scanner-baseline/`.
The direct API must limit projected items before compacting empty names.
Its tests must distinguish an empty first name followed by eight nonempty names from an eight-item input.
Raw projection retains legacy `u32` counters and their arithmetic policy.
Saturating `u16` counters change the final depth after long quoted delimiter sequences.
The projection census must compare each eligible source against legacy after asserting its named syntax property.
Allocation sweeps must include nonempty semantic fragments, their ownership mask, and lowering cleanup.
The second-declaration sweep alone does not cover those allocations.
Generic openers can share a tokenizer token with another operator byte.
Generic closers can also share `>=` with the following assignment.
The cursor must retain the unconsumed suffix and the full tokenizer state.
Main measured `structural Box<T>=T` and `const value: Box<number>="x"` in separate sources.
Both reach ZTS200 at line 2, column 1, with no earlier diagnostic.
The same scanner baseline directory retains those exit-1 responses.
Legacy bracket scanning can catch an error after recording its admission diagnostic.
An unterminated quoted line inside an ignored generic group is one such case.
Main measured ZTS008 at line 1, column 23; the command exits 1.
The exact receipt is `u10-generic-scanner-baseline/unterminated_quoted_group.json` outside the repository.
Slice A must explicitly decline malformed forms whose recorded diagnostics it does not represent.
The comparison must reject an unexpected nonempty legacy diagnostic list before reporting equivalence.
The later production cutover must preserve the existing diagnostic instead of retaining that private exclusion.
Authored metadata must also isolate angle counters from bracket groups.
Ignored `<` operators inside groups can keep the raw semantic counter open without removing the authored parameter.
The same rule applies inside an outer generic application.
Three measured less-than contrasts project no legacy semantic parameter.
The direct syntax must retain one authored parameter for each contrast.
Their `Box<>` assignments produce only ZTS200 at line 2, column 1.
The scanner baseline directory retains those exit-1 responses.

A regex-shaped ignored default can make runtime tokenization cross the raw generic boundary.
Main measured `structural Box<T = /x> = number; /* tail */` with a later typed assignment.
Legacy reports only the later numeric mismatch and exits 1.
Slice A may explicitly decline that bounded form until the direct cursor supports its raw boundary.
The production cutover must preserve its admission and exact diagnostic behavior.
These private exclusions must not become silent production refusals.
The exclusion guard includes a slash immediately before the final `>`.
Any malformed or over-budget quoted scan must decline comparison before authored splitting can absorb later parameters.
The balanced nested-template probe retains a later `U` parameter beyond the private quoted-scan budget.
Allocation sweeps report invalid scope cleanup as `InvalidParsedGenericOwner`, even when the original failure is allocation exhaustion.

The eight-parameter census initially used the alias `Many`.
Legacy annotation scanning detects the suffix `any` in that name and refuses the annotation.
Main measured ZTS041 at line 2, column 15; the command exits 1.
The receipt is `u10-generic-scanner-baseline/eight_many_name.json` outside the repository.
This result confirms the retained U8 suffix rule, not a generic lowering defect.
The eligible capacity comparison uses `Wide`; a separate regression preserves the `Many` refusal.

Slice B adds `parse.zig` hooks for untyped generic functions, arrows, and explicit calls.
Function capture requires raw adjacency between the name and `<`; tokenizer whitespace skipping cannot authorize a spaced list.
Call speculation retains the separate operator filter and combined depth policy from `looksLikeCallTypeArguments`.
The caller first retains the raw operand classification from `looksLikeComparison`.
Tokenizer operand classes cannot silently replace that source rule.
The call hook runs before Pratt precedence selection and preserves ordinary call precedence and chain-depth accounting.
An admitted explicit call can start inside a combined `<<` token.
The scanner, Pratt hook, and preflight must test the raw opener consistently.
An earlier review incorrectly inferred semantic absence for `id<<string>>(seed)`.
Legacy `splitTopLevelCommas` removes one optional outer angle pair before projecting call arguments.
That source retains authored `<string>` but projects a `string` fragment with primitive string semantics.
The direct projection must preserve that single removal before raw comma splitting.
The same rule applies to function and arrow parameters through each owner's recorded window.
`identity<<T>>(value)` and a dedicated `<<T>>(value) => value` arrow project the name `T`.
Their `<<>>` controls project no parameter and perform no generic scope work.
A structural alias records its outer angles, so `Box<<T>>` still projects the name `<T>`.
One shared span helper removes exactly one optional pair from the applicable recorded span.
The five direct contrasts assert names, exact pool growth, scope cleanup, and no function signature before semantic comparison.
An actual shift remains a non-call and retains ordinary operator parsing.
Variable and export transactions remain open through semicolons and final wrapper nodes.
Outer publication failure removes nested generic owners and explicit calls.
Pending owners reserve records before bodies or value arguments introduce nested owners.
Finalization updates those records after runtime node creation, preserving contiguous range order in the store.
Pending values retain their checkpoint, reserved slot, final record, and active state.
The store exposes explicit reserve, finish, and cancel operations for generic owners and calls.
Options name the balanced list span and projected span separately.
The first Slice B fixture uses one numeric seed and an untyped `identity<T>` declaration.
It asserts capture, ordering, exact parenthesis identity, runtime equivalence, and absence of a function signature.
A recovered-body contrast retains the seed while removing the failed declaration's generic records.
The initial preflight skipped function bodies by brace count and could miss nested annotations or unsupported owners.
Complete-source eligibility must inspect every body before the comparator invokes legacy preparation.
The first fixture uses a narrow bare-parameter and identifier-return policy until later Slice B work expands that policy explicitly.
Direct recovery tests can exercise refused bodies without claiming complete-source equivalence.
Function bound lowering stops before an original projected index reaches the compact parameter count.
The syntax store retains skipped raw bounds without requiring semantic fragments for those bounds.
Otherwise an ignored literal can consume pool capacity, or ignored unsupported syntax can introduce a new refusal.
Pending publication also checks diagnostic allocation health because an unrecorded error leaves the diagnostic count unchanged.
The diagnostic failure probe must observe that condition and confirm owner removal without changing runtime recovery.
Legacy `parenOffsetAfter` skips only spaces, tabs, carriage returns, and line feeds.
A comment between a function's generic list and `(` leaves its legacy signature offset absent.
TypeEnv therefore omits that entry's generic declaration work.
Token-only capture incorrectly attaches the list and constructs generic parameters.
This bounded private slice declines comment gaps in both preflight and the parser hook.
Whitespace positive probes and block-comment and line-comment negative probes establish that boundary.
The production migration must preserve the omitted generic work for admitted comment gaps.
The `function`-to-name gap needs the same raw whitespace restriction in this bounded slice.
A comment there stops legacy named-function handling before the name.
The later generic pass records call arguments at the function parenthesis instead of declaring function parameters.
The production design must retain that projection without creating a runtime call node.
The list-end gap check also rejects an extra closing angle hidden inside a combined tokenizer token.
`function identity<T>>(value){return value;}` must not consume the residual `>` as type syntax.
The negative probes include both header gaps and that residual closer.
Function preflight and capture must share the declaration path's private generic-list eligibility guard.
That guard excludes regex-shaped contents and malformed or over-budget quoted scans before authored splitting.
Function-form probes must retain a later parameter beyond a balanced quoted-scan budget boundary.
The raw-gap parser probes expect `UnexpectedToken`; the diagnostic-allocation probe expects `ParseError`.
The diagnostic probe checks `has_induced_failure` because a failed first allocation does not advance `alloc_index`.
Projected spans retain each legacy recording window rather than a normalized angle-list interior.
Aliases record both angles; function lists and dedicated assignment arrows record the interior.
The general arrow path records through one byte before its whitespace-adjusted cursor.
Arrow classification uses raw source context, including intervening comments, before selecting that recording window.
Main measured `const id = /* gap */ <T> (value: T): T => value` retaining the general window.
The command exits 1 with ZTS208 for `T>` before ZTS200 for the later numeric assignment.
The receipt is `u10-arrow-comment-baseline/assignment_comment.json` outside the repository.
Legacy scanning processes each `=` byte outside skipped strings and comments, including the last byte of compound operators.
The dedicated arrow window therefore also applies after `===`, `+=`, and similar operators ending with `=`.
An equals sign inside a skipped line comment does not select that window.
The parser must distinguish the preceding runtime token from comment contents.
At the first runtime token, the parser must use a defined initial token rather than reading undefined previous-token fields.
Direct first-token and leading-comment arrow probes must establish that boundary without a seeded declaration.

The general angle probe uses the last copied non-whitespace byte, including copied comment text.
Three measured line-comment contrasts establish that separate rule.
Each CLI command exits 1; receipts remain in `/tmp/zttp-reset-20261015/u10-arrow-line-comment-baseline/`.
With `// note` and adjacent `<T>(...)`, legacy records call arguments and reports ZTS203 before ZTS200 on line 3.
With `// note` and spaced `<T> (...)`, legacy leaves the angle bytes and reports ZTS002 at line 2, column 1.
With `// note=` and spaced `<T> (...)`, legacy records general parameters and reports ZTS208 for `T>` before ZTS200.
U10's bounded private path can decline prefix arrows whose general angle probe selects call arguments.
That restriction also covers keyword prefixes such as `return`, whose final raw byte satisfies the legacy operand classification.
The private guard must use the shared raw classification after checking the dedicated assignment window.
The production migration must preserve that projection through the final arrow owner.
Thus `(<T> (value: T): T => value)` retains the semantic parameter name `T>`.
The adjacent arrow and dedicated assignment contrast retain `T`.
Main measured ZTS208 and ZTS200 for the spaced parenthesized arrow, versus one ZTS200 for each control.
All three commands exit 1 with JSON; receipts remain in `/tmp/zttp-reset-20261015/u10-arrow-window-baseline/`.
The public generic table now contains 77 sources, plus the separate propagated-error regression.
Failed speculation restores the full cursor and store checkpoint.
Accepted syntax uses pending records through runtime node and wrapper creation.
Runtime failure removes pending records while preserving parser recovery progress.
A nongeneric enclosing call can fail after a nested generic call publishes its record.
Expression and statement transactions must remove those nested records while retaining syntax from earlier statements.
The same boundaries must cover a failed right operand and a failed final statement node.
Transactions must also detect recovered errors and diagnostic allocation failure.
A recovered `parseBlock` error prevents publication even when the block returns a node.
Variable and export wrappers apply that diagnostic-count check and diagnostic allocation health before retaining nested records.
Generic ownership alone creates no function signature.
An empty function or arrow projection performs no generic scope allocation, matching the legacy early return.
A nonempty projection with no retained names still performs its existing scope work.
Structural generic aliases retain their separate publication policy, including an empty parameter list.
The population order remains aliases, contractivity, independent function scopes, and calls outside every function scope.
The full Slice B census inspects every original body and initializer before complete-source comparison.
The first expanded preflight used recursive calls for nested functions without a scanner budget.
The accepted implementation must use bounded iteration, as the Zig skill requires.
A forced budget probe must decline comparison, while a nonempty nested positive must still compare.
Empty dedicated and spaced general arrow lists need separate projection assertions.
Nested arrows and calls must assert reservation order, final parenthesis locations, and disjoint semantic fragment ownership.
Separate positive probes must nest a call inside a call and an arrow inside an arrow.
Those probes must also assert contiguous authored ranges and balanced independent generic scopes.
Allocation sweeps cover successful comparisons, second-owner rollback, nonempty bounds and call fragments, and preserved outer generic scopes.
Explicit call validation rejects more than eight projected fragments before the lowerer fills its fixed argument array.
The malformed-record probe supplies nine otherwise valid fragments to establish that rejection.
The explicit-call scanner must distinguish a non-call from a private exclusion.
Combined-depth exhaustion must decline comparison before legacy preparation instead of becoming a comparison operator.
Only a non-call outcome can retain the ordinary comparison fallback.
Both slices retain separate complete-source, direct API, and public production evidence.
Astra accepts the final Slice A source after the authored-span, private-exclusion, cursor, projection, and cleanup corrections.
The preceding unfiltered run passed 2,743 tests with one skip across 16 steps.
The final guard run also passed 2,743 tests with one skip across 16 steps.
Its log is `u10-slice-a-final-bounded.log`; all 223 precompile tests pass.
The separate comment-window tools run passes all 224 precompile tests in `u10-arrow-comment-public.log`.

The following receipts cover intermediate U10 slices, not completion of U10.
Each log path is relative to `/tmp/zttp-reset-20261015/`.

| Log | Direct result and scope |
|---|---|
| `u10-first-slice-corrected.log` | Exit 0; 16 steps, 2,725 pass, one skip; application slice. |
| `u10-slice-a-first.log` | Exit 1; invalid assignment syntax in three closer branches. |
| `u10-slice-a-syntax-corrected.log` | Exit 1; two span-width errors; 94 tests pass. |
| `u10-slice-a-width-corrected.log` | Exit 1; 14 steps succeed, 2,729 pass, one skip, five failures; all 220 precompile tests pass. |
| `u10-slice-a-corrected-first.log` | Exit 1; 14 steps succeed, 2,738 pass, one skip, one failure; all 221 precompile tests pass. |
| `u10-slice-a-corrected-second.log` | Exit 0; 16 steps, 2,743 pass, one skip; all 223 precompile tests pass. |
| `u10-slice-a-final-bounded.log` | Exit 0; 16 steps, 2,743 pass, one skip; final Slice A guards. |
| `u10-arrow-comment-public.log` | Exit 0; four steps, 224 precompile tests pass; exact comment-window regression. |
| `u10-b-first.log` | Exit 0; 16 steps, 2,746 pass, one skip; first function fixture; source review still requires corrections. |
| `u10-b-first-corrected.log` | Exit 1; offset-width compilation error; six steps succeed and 94 tests pass. |
| `u10-b-first-width-corrected.log` | Exit 1; 14 steps succeed, 2,748 pass, one skip, one stale raw-gap expectation; all 224 precompile tests pass. |
| `u10-b-first-final.log` | Exit 0; 16 steps, 2,750 pass, one skip; all 224 precompile tests pass; Astra accepts the bounded first function slice. |
| `u10-b-full-first.log` | Exit 1; six of sixteen steps, 94 tests pass; new switch assignments and callback-local offsets fail compilation. |
| `u10-b-full-syntax-corrected.log` | Exit 1; fourteen of sixteen steps, 2,763 pass, one skip, four failures, one crash; all 225 precompile tests pass. |
| `u10-b-full-corrected.log` | Exit 1; fourteen of sixteen steps, 2,774 pass, one skip, three failures; all 225 precompile tests pass. |
| `u10-b-full-projection-corrected.log` | Exit 0; sixteen steps, 2,777 pass, one skip; all 225 precompile tests pass. |
| `u10-b-full-owner-window-corrected.log` | Exit 0; sixteen steps, 2,778 pass, one skip; all 225 precompile tests pass; Astra accepts the final source. |

The corrected run exposed three stale exclusions after private eligibility expanded.
It also exposed an empty group's retained syntax node, a declaration fixture outside its required boundary, and an incorrect runtime error expectation.
An older test accessed an inactive verdict field after comparison operators became eligible.
Main corrected those expectations and replaced that unsafe field access with an exhaustive verdict switch.
Astra also required enclosing rollback transactions, explicit scanner exclusions, and the empty-scope allocation policy described above.
`u10-b-full-corrected.log` passes the new wrapper, diagnostic-allocation, and nested reservation probes.
Its remaining failures expose the optional angle-pair projection and two incorrect fixture expectations.
The empty-scope probe must initialize built-in aliases before it installs the failing allocator.
It must remove unused scope capacity before it tests a required new allocation.
Generic call arguments admit `any`; the ordinary annotation scanner's refusal does not apply to that capture path.
That call contrast must preserve semantic comparison instead of expecting an admission refusal.
Astra accepts the final shared projection helper and its five direct contrasts.
That source acceptance remains separate from the next run's execution result.

The broad frontend run passes 45 steps, with 3,551 passing tests and one skip in `u10-focused.log`.
All 182 diagnostic corpus cases pass, and whole-repository formatting passes.
A daemon restart interrupted `u10-verify.log`; that partial run supplies no full-gate verdict.
The recovered full gate exits 1 in `u10-verify-recovered.exit`.
Its aggregate completes 189 of 191 steps, with 8,275 passing tests and six skips.
The proof-swallow shell gate rejects anonymous catch blocks in `putParsedGenericAlias` and `putParsedCallTypeArgs`.
Main replaces those blocks with native `try` propagation and scoped `errdefer` to retain the allocation-failure flag.
The direct proof-swallow gate then passes without an allowlist change.
Astra accepts the correction after checking the pinned map error set and both error paths.
The other three source files match the accepted snapshot.
The corrected small run exits 0 in `u10-propagation-small.log`: sixteen steps, 2,778 passing tests, and one skip.
All 225 precompile tests pass again.
The corrected full gate exits 0 in `u10-verify-propagation.exit`.
Its log is `u10-verify-propagation.log`.
Aggregate tests, standalone runtime, optimized builds, verified precompilation, smoke tests, offline replay, and specification checks pass.
All 734 flow probes match their expected verdicts; all 182 diagnostic corpus cases pass.
Final documentation, link, and spine checks pass all eight steps in `u10-docs-final.log` with exit 0.
Whole-repository formatting and the diff check also pass after the propagation correction.
U10 is committed locally as `aa5489c2`.

### U11 preparation findings

The combined module and nominal gate passed with 2,859 tests and one skip.
The receipt is `/tmp/zttp-reset-20261015/u11-module-matrix-nominal-diagnostics.log`; its direct exit status is zero.
Astra accepted nominal diagnostic order and found two gaps in the module tests.
The corrected wrapper tests require successful closed-body controls before exact missing-brace failures at EOF.
The rich fixture now requires its final handler owner, exact parameter binding, and both named type roots.
Astra accepts both corrections by source review.
The strengthened gate also exits zero with 2,859 tests and one skip.
The receipt is `/tmp/zttp-reset-20261015/u11-module-probes-corrected.log`.

The arrow candidate needed two corrections before integration.
Legacy-call capture must retain the angle interior, including the nested-angle contrast.
Allocation probes must classify source progress independently of Store contents before asserting complete checkpoints.
The first object-prefix candidate also scanned preceding source while validating its operand endpoint.
The corrected design scans only the operand interval and checks template and regular-expression delimiters.
The arrow gate exits zero with 2,865 tests and one skip.
Its receipt is `/tmp/zttp-reset-20261015/u11-arrow-corrected.log`.
Astra then required a healthy nested-arrow control and exact runtime evidence after a recovered body error.
The corrected probe requires two healthy owners and signatures, a later declaration, and the surviving outer return.
Astra accepts that correction by source review.
The first object integration stopped on four shadowing errors before any object behavior verdict.
Main renamed those bindings; the corrected unfiltered gate remains separate from source acceptance.
The corrected object gate exits zero with 2,870 tests and one skip.
Its receipt is `/tmp/zttp-reset-20261015/u11-object-pilot-arrow-recovery-corrected.log`.
The eight-kind census and initial shadowing probe then pass with 2,872 tests and one skip.
That receipt is `/tmp/zttp-reset-20261015/u11-owner-census.log`.
Astra accepts the exhaustive kind census but finds that the closure probe does not require an actual capture.
The corrected probe follows the inner return to an upvalue and ties its source scope and slot to the annotated local.
The stronger capture assertion still requires execution.

The first named-comment review found two compatibility errors in the candidate.
Before-name comments must pass `scanExplicitCallTypeArguments` before selecting legacy call compatibility.
Balanced angles and adjacency alone incorrectly admit default, logical, and arithmetic spellings that legacy leaves raw.
Refusal restores the complete cursor and syntax checkpoint.

After-list comments suppress generic semantics but do not change the recorded span.
`handleFunctionDeclaration` records the angle interior before it encounters the comment.
The final capture therefore retains actual `<T>` and recorded `T`.
The ignored-function validator and positive probes must check that exact interior.
An independent TypeMap assertion must check provenance instead of assuming that ignored semantics make capture interchangeable.
Main corrected both producer errors and the narrow validator exception.
Three grammar refusals now compare actual legacy parse errors and exact retained locations.
Seeded speculation probes require an unchanged cursor and all seventeen checkpoint fields.
Four positive comment cases compare exact recorded endpoints with the independent legacy TypeMap.
Astra accepts these corrections by source review; the execution gate remains separate.
The corrected gate then passes sixteen steps with 2,882 tests and one skip.
Its receipt is `/tmp/zttp-reset-20261015/u11-named-comments-provenance.log` with direct exit status zero.
The exact closure capture and both named-comment corrections pass execution.

The complete prefix candidate required further corrections before integration.
Assignment capture can stop before whitespace that precedes a parenthesized operand.
Ignored compatibility requires braces; projected compatibility requires parentheses.
The private preflight must recognize the accepted operand shapes instead of permitting an unrestricted token list.
The positive matrix must execute that preflight, and adjacent refusal probes must require the actual parse error.
Recovery probes must identify both later runtime declarations and the retained outer annotation.

An authored empty list does not necessarily have an empty recorded projection.
General spaced `<> (1)` records `>` and creates one legacy generic parameter with that name.
Assignment `<>(1)` retains an empty projection.
Projection must use the recorded span without an authored-empty override.

The existing lowering comparison checks reachable aliases, calls, and variable roots.
Those roots do not expose missing transient generic nodes.
Prefix acceptance therefore also requires independent full ordered pool comparison against legacy construction.
A complex bound makes bound constructors observable in the direct API probe.
An interleaved fixture must exercise generic-owner and prefix ranges together, including an empty projection.
Overlap and gap mutations must fail that mixed census.
Main integrated the corrected prefix candidate after source review.
The finite preflight uses an explicit bounded stack and executes through every positive comparison case.
Main also restored removed-type diagnostics that the revised preflight had discarded.
Root, nested, and statement contrasts compare those diagnostics in both admission modes.
The integrated tests require actual legacy refusal state, recovered runtime declarations, and full ordered pool parity.
Source acceptance and the unfiltered execution verdict remain pending for this complete prefix slice.

The first complete prefix gate exits one with five failing tests across 2,893 tests.
The receipt is `/tmp/zttp-reset-20261015/u11-prefix-complete-first.log`.
Three malformed-record probes expected errors from later checks instead of the guards that rejected their inputs first.
The corrected probes retain local provenance and range checks.
A separate misplaced empty range exercises the global source-order census without violating local span provenance.

Successful prefix scans also need an explicit flag before preflight's final annotation requirement.
The flag changes only after a complete statement or initializer prefix scan succeeds.
Plain untyped source still fails the original comparison admission requirement.

The proposed addition of prefix `any` diagnostics was incorrect.
Legacy generic scanning checks removed forms such as `void`, but does not apply the ordinary annotation's `any` check.
The direct preflight must preserve that distinction.

Measured group and block sources with `any` reach only ZTS500 at contract checking.
The corresponding `void` sources stop with ZTS060 at columns 16 and 2.
Receipts remain under `/tmp/zttp-reset-20261015/u11-prefix-diagnostic-baseline/`.
Root, nested, and statement probes require `void` refusal and `any` equivalence in both admission modes.

The second small gate exits one with two failures and 2,890 passing tests.
Its receipt is `/tmp/zttp-reset-20261015/u11-prefix-complete-corrected.log`.
All three local guard probes, the empty-range census, and deeper nesting refusals pass.
The positive matrix also needs the comparison's syntax-presence check to recognize retained erased prefixes.
That check does not change parser admission.

Astra found that nested group frames admitted another nested prefix beyond the accepted comparison boundary.
Nested group operands now require one number.
Two deeper sources must remain outside private comparison admission.
This bound changes only preflight; the owner model and direct parser retain independent validation.
The final corrected small gate exits zero: sixteen steps succeed, 2,892 tests pass, and one test skips.
Its receipt is `/tmp/zttp-reset-20261015/u11-prefix-complete-diagnostic-parity.log`.
Astra accepts the complete U11 source within its recorded private scope.
The review does not establish execution, consumer semantics, production cutover, or rejection of every descendant substitution within one operand interval.
The broader frontend gate then exits zero: all 45 steps succeed, 3,698 tests pass, and one test skips.
Its receipt is `/tmp/zttp-reset-20261015/u11-focused.log`.
The final U12 refresh exposes the declaration identity gap below before U11 closes.
The bounded amendment requires another small gate, affected frontend checks, and common checks before U11's commit.

Main measured typed parameter contrasts for both function header comment gaps.
Each command exits 1 with ZTS003 before type analysis.
The comment before the name reports line 1, column 37; the comment after the list reports column 36.
Both diagnostics retain the suggestion `')'`.
The normal header reaches ZTS200 at line 2, column 1 for the later numeric assignment.
Receipts remain in `/tmp/zttp-reset-20261015/u11-function-header-baseline/`.
The accepted untyped header cases do not authorize typed parameter admission through those gaps.

The accepted U11 design adds a bounded compatibility projection to the final function's generic owner.
`GenericOwnerCompatibility` distinguishes declaration parameters, ignored declaration parameters, and legacy call arguments.
The call variant retains authored argument and semantic fragment ranges.
The ignored variant performs no generic semantic work.
Neither variant alone creates a fake call node or a function signature.
Ordinary parameter and return annotations still establish their existing signatures.

The compatibility projection retains no second owner identity or stored `legacy_lparen_offset`.
An interim offset facade can read the parameter opener directly from the final function node.
U12 uses one map keyed entirely by node indices for real calls and unmatched function-owned compatibility entries.
Real calls query only actual call nodes.
Node indices must never enter the existing map of source offsets because those numeric domains can collide.

Compatibility arguments populate in source order with real call arguments during the existing call-argument phase.
Ordinary alias resolution, pool construction, map insertion, and health checks remain unchanged.
Validation requires actual function owners and disjoint fragment ranges.
Wrapper failure and diagnostic allocation failure remove every pending compatibility range.
Astra accepts this bounded design for the two specified header gaps and three measured arrow contrasts.
Implementation still requires U10's commit and final API refresh.
The adjacent line-comment arrow uses the call-argument variant on its final arrow node.
The spaced line-comment refusal publishes no owner; the equals-ending comment retains the general declaration projection.
The call-argument variant performs no generic declaration work and retains ordinary typed signatures.

The refreshed comment review confirms separate legacy paths for generic lists and arrow headers.
Comments can change generic-list projection without preventing typed arrow headers.
The measured block-comment arrow reports ZTS208 for `T>`, then ZTS200 for return `T`.
The adjacent line-comment arrow reports ZTS203 for parameter `T`, then ZTS200 for return `T`.
The spaced line-comment source remains raw JSX and publishes no owner.
An equals-ending line comment selects general projection and reports ZTS208, then ZTS200.
Therefore, arrow production needs no comment-based flag that disables typed headers.
Named functions retain their separately measured typed-header refusals through comment gaps.

Astra accepts the remaining generic-arrow refresh without new syntax fields.
The producer confirms the outer arrow through `scanParenthesizedArrowHeader` on a copied cursor after the candidate opener.
The published cursor remains at that opener; reservation follows confirmation.
The typed-only producer no longer needs `cursorStartsBareArrow`; plain JavaScript uses its existing separate lookahead.
Dedicated assignment capture keeps first priority, and general capture keeps its measured whitespace-adjusted window.
Comparison context must pass `scanExplicitCallTypeArguments` before selecting call compatibility.
Adjacency alone does not establish that grammar.
Rejection or exclusion must prevent callable and prefix fallback.
The list-to-opener gap still permits only legacy whitespace.
Whole-source preflight can retain its narrower boundary until U12 migrates signature consumers.

Seven measured refresh cases remain in `/tmp/zttp-reset-20261015/u11-generic-header-refresh-baseline/` after a one-case pilot.
Every command exits 1.
A typed assignment arrow reports ordinary ZTS200; the general spaced arrow reports ZTS208 for `T>`, then ZTS200.
A word-ending comment before `<T = string>` leaves raw JSX and reports ZTS002 at line 2, column 1.
An equals-ending comment with general capture instead reports ordinary ZTS200 at line 3, column 1.
Untyped named functions with one line comment before the name or after the list reach ZTS601.
Their function locations remain line 2, columns 12 and 1, respectively.
Comments in both named-header gaps leave the angle list raw and report ZTS003 at line 1, column 31.
Seven exact public CHECK assertions now retain those outcomes and await the next unfiltered run.
Required direct probes cover shared signature ownership, rejected call grammar, nested return-function arrows, and complete rollback.

The current TypeMap has eight kinds, and the existing census in `source_frontend.zig` covers every kind.
Structural and nominal annotations belong to type declarations without runtime nodes or atoms.
Variable annotations belong to declaration `BindingRef` values.
Parameter annotations need both the parameter node and its declaration binding.
Return types, predicates, and function generic parameters belong to function expression or arrow nodes.
Explicit call arguments belong to the final call node, which exists only after its value arguments parse.
Type-only imports and exports need ordered module records with complete raw spans and no runtime owner.

The function declaration wrapper is not the function node.
Its `VarDecl.init` points to that node, while arrows already have their own node identity.
Nested functions can receive node indices before their enclosing function.
Authored order therefore requires retained spans or an explicit sequence, rather than sorting by node index.
Pending function and call attachments must not publish ownerless records after parse failure.

Existing signatures use the opening parenthesis offset to distinguish repeated names and same-line functions.
Direct function ownership removes that reconstruction join.
Existing variable ordinals count each spelling globally, rather than identifying lexical declarations.
Captured accesses use upvalue identities, while annotations belong to the original declarations.
The store must retain the complete binding; consumers can select their existing identity projection.

Legacy parameter assembly compacts annotated parameters into encounter order.
Unannotated parameters create no hole in that signature array.
Predicate name lookup also uses only annotated parameter names.
These policies need characterization before U12 can claim public compatibility.
Correct source ownership in U11 does not authorize a silent change in consumer diagnostics.
Astra confirms that the checker applies the compacted array to actual parameter positions and call arguments.
Strict checking rejects incomplete signatures, but earlier type diagnostics remain observable in CHECK output.
U12 therefore needs an explicit compatibility projection while retaining exact source owners.
That projection must preserve the annotation-count lower arity bound and the actual-node upper arity bound.
Accurate source owners must remain syntax data until that projection selects semantic bindings.
Binding both the actual annotated parameter and its compacted legacy position would change diagnostics.
The same projection must control predicate indices rather than joining two incompatible binding policies.

A CLI measurement confirms the diagnostic difference that a silent correction would introduce.
For `pick(a, b: string)` called with `(1, "ok")`, CHECK reports ZTS203 against the first call argument.
The same response then reports ZTS601 for the incomplete signature.
The command exits 1; its receipt is `/tmp/zttp-reset-20261015/u11-partial-parameter-baseline/partial.json`.
This observed compatibility requirement does not approve a new signature policy.

The existing census does not prove direct attachment, module raw spans, exported type flags, or attachment rollback.
New fixtures need repeated predicates, a predicate after an unannotated parameter, same-line generic calls, shadowed captures, and failed constructs.
The direct census must enumerate every annotation kind and separately enumerate type-only module records.
It must assert nonzero totals, expected counts, valid owner tags, exact binding identities, and in-range spans.
U11 changes syntax ownership only; U12 retains consumer migration.

The refreshed source review identifies transaction boundaries that require explicit tests.
A variable transaction includes initializer parsing and semicolon acceptance before its annotation publishes.
A function declaration transaction includes wrapper allocation, even after the owned function node exists.
A call transaction includes value arguments, its closing parenthesis, call creation, and final attachment.
Each transaction compares the parser error count because recovered block errors can still return a runtime node.
Rollback retains earlier syntax and runtime recovery progress.
Successful finalization removes provisional owner offsets rather than retaining a second owner identity.

Type-only module spans follow the existing statement-end scan.
Their raw spans start at `import` or `export` and include a semicolon when present.
Without a semicolon, their spans stop before the newline.
Exported structural and nominal declarations retain their declaration export span without a duplicate module record.
The `zttp:types` refusal remains unchanged.

The direct census must independently observe the existing rich fixture's exact counts.
Those counts are one structural, one nominal, two variables, two parameters, one return, and one predicate.
The same fixture has two generic owners and one explicit call.
Additional module fixtures establish ordered module spans and runtime neutrality.
Generic record field names remain requirements until U10 supplies its final API.

Predicate target ownership needs an explicit unresolved state.
Legacy accepts a predicate spelling that names no parameter and still records a boolean return type.
Its semantic population skips the missing target rather than refusing source admission.
Main measured `function guard(value: unknown): missing is string { return true; }` with an ordinary handler.
CHECK reports only the handler's ZTS500 contract refusal and exits 1.
The receipt is `/tmp/zttp-reset-20261015/u11-predicate-target-baseline/unresolved.json`.
U11 must retain the target spelling and either its exact parameter owner or an unresolved tag.
U12 must preserve the existing missing-target projection.

U11 comparison evidence covers runtime parity, direct syntax correspondence, and ordered lowering of individual type roots.
That evidence does not authorize production consumer migration or establish new signature enforcement.
U12 retains semantic compatibility and consumer cutover.

Return classification also needs an explicit compatibility facet.
Legacy classifies the raw substring ` is ` as a type guard, independently of structured predicate parsing.
Thus a quoted return type containing that substring receives a boolean semantic return.
Tab-separated predicate words instead remain an ordinary return annotation.
The direct syntax result must retain the original classification without replacing its structured syntax.
U12 must use that facet before it applies the existing predicate-target projection.
Main measured both contrasts with a `true` return body and an ordinary handler.
The quoted contrast reports only ZTS500; the tab-separated contrast reports ZTS204 at line 1, column 51.
Both commands exit 1; receipts remain in `u11-predicate-target-baseline/` outside the repository.

The accepted return record retains its whole raw span, legacy classification, and structured type or predicate.
An optional `legacy_ordinary_prefix` stores a parser-produced `TypeValue` in a separate owned node range.
That value is required only for a structured predicate with an ordinary legacy classification.
The parser uses the existing engine grammar over the original return spelling during admission.
Its raw span remains the whole return spelling, not only the target token.
U12 consumes the stored root without parsing text again.
Ordinary structural types reuse their existing value; guard-classified returns need no ordinary prefix.
A target named `readonly` distinguishes grammar-based projection from an incorrect synthesized reference.

Function validation must check parameter membership in the actual owned function, as well as parameter tags and bindings.
A resolved predicate target must belong to that same parameter list, including an unannotated target.
Export transactions must include exported constants and their final export wrapper.
Wrapper allocation failure must remove the variable annotation and nested arrow or call syntax from its initializer.

Astra conditionally accepts U11 Stage 1 with those refinements.
The refreshed review finds no remaining design blocker.
Every new `TypeValue` participates in range validation, rollback, and application-base planning.
That census includes predicate narrowing and `legacy_ordinary_prefix`.
The first slice establishes runtime identity, exact owners, individual type lowering, and rollback after recovered body errors.
Implementation release still requires U10's commit, final API refresh, and review of that refreshed specification.

U11 adds `parameter_annotations`, `function_signatures`, `type_only_modules`, and `erased_type_prefixes` to the thirteen arrays from U10.
Every checkpoint, rollback, and destructor covers all seventeen arrays.
Reserve operations use named options and the store's source, rather than accepting another source slice.
An explicit parse-time policy distinguishes opaque structural parameters from callable bound projection before the final owner exists.
Type-only module refusal has a separate `zttp_types` state; it does not extend annotation-grammar failures.

The function body transfers pending signature cleanup to its declaration wrapper exactly once.
Finalizers receive the completed owner and an IR view where runtime ownership applies.
Each finalizer validates its own record while other reserved slots can remain undefined.
Global source validation, runtime-owner validation, and application masks run only after enclosing publication finishes.
Astra conditionally accepts this preliminary API, subject to the required refresh after U10's commit.

The first U11 slice parses variable, parameter, and ordinary return types without expanding the general comparison preflight.
A dedicated comparator checks runtime IR before exact ownership and ordered individual type lowering.
The signature's `source_span` covers its runtime parameter opener through the header, stopping at the body start.
The signature uses its final runtime node as identity; that source interval supplies no reconstruction join.

The declaration body transfers pending cleanup once, and the declaration wrapper retains cleanup through its final allocation.
A nested positive probe must publish the outer signature before the inner signature in authored order.
A recovered outer body must remove completed inner syntax while retaining the earlier variable annotation and runtime recovery progress.
The owner validator must reject incorrect node tags before it reads tagged runtime data.
The first slice retains provisional generic and explicit-call offsets until U11's later owner conversion.

The post-commit refresh confirms these APIs against `aa5489c2` and its thirteen-array Store.
Astra accepts the refreshed U11 API and the bounded first implementation slice with no design blocker.
This acceptance does not establish implementation correctness or complete U11.
The five public baseline tests pass all 230 precompile tests in `u11-public-baseline.log`, with exit 0 across four steps.
Those tests cover eighteen measured sources and assert exact diagnostics, stages, error counts, and contract presence.

The first source review identifies two transaction and ownership gaps.
The shared value parser advances the caller's cursor before variable annotation publication; publication failure can retain that advanced cursor.
The variable wrapper must publish a local cursor copy only after its annotation append succeeds.
Return-only signatures can swap valid function owners because an empty parameter range supplies no membership check.
Owner validation must compare the supplied node's header location with the captured header start, without finding owners through offsets.
The unfiltered `u11-first-slice-red.log` run exits 1 and exposes both failures.
The run reports 2,561 passing tests, one skip, and exactly two failed regressions.

Astra identifies another ownership gap within a function.
Two typed parameters can exchange complete `ParameterOwner` values while membership, binding, and uniqueness checks still pass.
An annotation can also move from a typed parameter to an earlier untyped parameter.
Validation must bound the supplied parameter's annotation between that parameter's location and the following actual parameter's location.
The final parameter uses the signature header bound.
These checks validate supplied owners; they must not find owners through source offsets.
Both negative contrasts require rejection probes before source acceptance.

The corrected first slice publishes the caller's cursor only after annotation storage succeeds.
Function validation checks the supplied node's tag before its location and payload.
Parameter validation retains exact membership, binding, uniqueness, and source-interval checks.
The corrected tests add both parameter-owner contrasts without claiming an earlier executed failure for those contrasts.
Flat, nested, and successful allocation probes compare runtime IR before checking syntax records.
Each comparison uses real local atom tables and separates runtime allocation from the swept syntax allocator.
Astra accepts the corrected first slice in static source review with no remaining blocker within that scope.
The unfiltered `u11-first-slice-corrected.log` run exits 0 across sixteen steps, with 2,794 passing tests and one skip.
All 230 public precompile tests pass, including the eighteen measured U11 sources.
These receipts establish the first slice only; later U11 ownership and admission work remains incomplete.

The final syntax inventory must also retain nominal declarations with generic lists before production cutover.
U10 explicitly excludes those lists from its private comparison scope.
Main measured `nominal Id<T> = string` with an integer assignment to `Id`.
CHECK admits the list and reports ZTS200 at line 2, column 1.
The contrast `nominal Id<T> = T` reports ZTS048 at line 1, column 17.
Both commands exit 1; receipts remain under `u11-nominal-generic-baseline/` outside the repository.
The U11 API refresh must locate this syntax owner while preserving ignored nominal parameters and scalar-base admission.

The producer inventory covers each legacy annotation-recording callsite, not only the eight recorded kinds.
Admitted object-property arrows require final arrow ownership; refused object methods require transaction rollback.
Function expressions, async forms, default exports, and destructuring retain their existing refusals.
Exported named functions and constants retain their outer wrapper transactions.
The concrete fixture specification remains in `/tmp/zttp-reset-20261015/u11-owner-fixture-spec.md` until final API refresh.

The next bounded U11 slice replaces existing generic and call identities without expanding source admission.
`GenericOwnerIdentity` will distinguish exact structural and nominal declaration indices from final function and arrow node indices.
`GenericOwner` will retain explicit capture spans and `GenericOwnerCompatibility` alongside its existing syntax ranges.
`ExplicitCallArguments` will retain its final call node and explicit capture spans instead of `lparen_offset`.
Reserve options will select projection policy before final identity exists and will read only `Store.source`.

`GenericOwnerCompatibility` will distinguish declaration parameters, ignored declaration parameters, and legacy call arguments.
The call variant will retain authored argument and semantic fragment ranges.
Current producers will retain their existing behavior; later slices will admit the recorded compatibility cases.
A finalizer argument will distinguish declaration indices from runtime owners with a required IR view.
Runtime finalizers will validate only their completed record, because enclosing reserved slots can remain undefined.
Global validation will wait until publication finishes.

A declaration transaction will append the declaration before finalizing its reserved generic owner against that declaration's exact back-reference.
The transaction will then validate the completed declaration.
No global validation may run between these operations; any failure will restore the existing complete checkpoint.
Projection policy must distinguish opaque structural parameters from callable bound construction, although both publish declaration-parameter compatibility.
Ignored and legacy-call variants must own only their respective ranges.
Structural bounds and defaults remain opaque; callable bounds retain U10's compact-index fragment construction.
Ignored and legacy-call policies create no bound fragments.
Only legacy-call compatibility owns its additional authored-call and semantic-fragment ranges.
`PendingGenericOwner` must retain its reserve policy until finalization.
Finalization must reject an identity incompatible with that policy, because structural and callable reservations publish the same compatibility tag.
Structural policy permits structural declaration identity; callable policy permits function and arrow identities.
Ignored policy permits the recorded nominal and function identities; legacy-call policy permits function and arrow identities.
No additional persistent identity or policy registry is required.

Tag checks alone cannot reject exchanges between two valid owners.
Call validation must require the supplied `.call` location to equal `list_span.end`.
Current function and arrow producers must supply the opener after their captured list, with only already-admitted whitespace between them.
These checks validate supplied owners without searching for owners.
Global validation must also reject duplicate runtime owners.
Capture spans remain independently validated, including empty and unequal legacy windows.

Function publication will follow declaration-wrapper allocation and validation of `VarDecl.init`.
Arrow publication will follow final arrow creation within its existing enclosing transaction.
Explicit call publication will follow value arguments, the closing parenthesis, and final `.call` allocation.
Recovered diagnostics and wrapper failures will restore the complete syntax checkpoint while retaining runtime recovery progress.
Reservation order will preserve authored order for nested owners.

The private full-store lowerer will receive the actual runtime IR view.
Its temporary legacy call facade will derive a parenthesis key from a supplied, tag-validated call node's location.
The facade will perform no text search or owner reconstruction and will retain no offset identity in syntax records.
Syntax-only lowering tests will reject runtime-owned records instead of inventing an empty IR view.
Allocation probes with fabricated offsets will use actual runtime nodes and IR-aware finalizers.
Wrong-offset probes will become wrong-node and wrong-tag probes.

The first vertical contrast will combine a generic-only `identity` declaration with `identity<string>("ok")` in a typed variable initializer.
The contrast will establish exact wrapper, function, and call ownership, runtime parity, and ordered lowering through the actual IR view.
The contrast will require zero function signatures for the generic-only declaration.
Astra accepts this bounded design with the publication, policy, source-provenance, and range rules stated here.
The corrected first-slice suites pass, so the bounded implementation can proceed.
Required probes cover nested reservations, owner exchanges, incompatible policies, declaration back-references, and shared or unclaimed ranges.
Rollback probes retain an earlier published seed; successful probes check runtime parity before ownership and ordered lowering.
Shared argument ranges must account for real calls and compatibility projections, with exactly one owner per semantic fragment.
Application planning must not visit compatibility roots twice.
This acceptance covers design only and does not accept the forthcoming source or complete U11.

The first generic-owner handoff migrates all API callers and passes formatting and diff checks, but source review identifies a capture regression.
Structural aliases record the complete angle list as their legacy span.
The handoff instead supplies the interior span, so reservation removes an additional optional angle pair.
For `structural Box<<T>> = number;`, the direct projection becomes `T` instead of the required `<T>`.
The correction must retain the complete structural legacy window and exactly one optional-pair removal.
The first unfiltered handoff run exits 1 with two Store capture-shadowing compilation errors.
Only the 94 base and contract tests execute; the affected engine, compiler, and precompile artifacts do not compile.
The next run changes only those capture names so the existing semantic regressions can execute.

Capture validation also requires source relationships, rather than two independently in-range spans alone.
The actual erased span must contain its generic list.
Its start must equal the list's start, and it must contain the legacy recorded window.
Runtime generic provenance must validate the interval from `list_span.end` to the supplied opener.
Using only the actual erased endpoint lets a forged wider span hide intervening runtime source.
The general arrow path erases through whitespace to the opener; dedicated assignment and function paths erase only the angle list.
Each producer must retain its exact actual span independently from its legacy recorded window.

Runtime locations also need explicit bounds and an opening-parenthesis check.
The whitespace helper clamps offsets, so a supplied location beyond EOF can otherwise pass after trailing whitespace.
Function and arrow owners must name an in-range `(`; explicit calls require that byte after their exact offset correspondence check.
Negative probes must cover non-opener and out-of-range locations, widened captures, and unrelated capture spans.

The runtime variant of `GenericOwnerFinal` must contain both the owner and its required `IrView`.
The handoff's separate view parameter unnecessarily reaches declaration parsing, preflight, and fabricated empty-IR test wrappers.
Declaration finalization needs only the completed declaration and exact back-reference.
Removing that parameter and those wrappers preserves mandatory runtime validation while simplifying the API.
The exact function-plus-call fixture must run ordered `compareLowering` against its own prepared source and direct parser.

Ignored and legacy-call owners intentionally retain projected syntax ranges without bound fragments.
Those ranges are syntax data, rather than generic semantic construction.
The private declaration lowerer currently sends every generic owner through generic-alias construction.
For a valid ignored nominal owner, that branch creates generic semantic work and bypasses nominal wrapping.
Current parser admission excludes nominal generic source, but the new direct API still needs correct lowering or an explicit refusal.
The correction will retain ordinary nominal lowering while restricting generic-alias construction to structural declaration-parameter owners.

Successful direct-API probes must cover ignored and legacy-call variants alongside their rejection cases.
Mixed real-call and compatibility ranges must prove unique authored-argument and fragment ownership, with shared and unclaimed mutations rejected.
Source acceptance remains blocked until these bounded corrections, their unfiltered execution, and Astra's final delta review complete.
The shadow-corrected unfiltered run exits 1: fourteen of sixteen steps, 2,798 passing tests, one skip, and one failure.
The existing recorded-window regression exposes the structural `<<T>>` error.
All 232 precompile tests pass, including exact diagnostics, stages, counters, and contract presence for the new arrow and module sources.
This public baseline pass exercises the retained legacy production path and does not accept the new direct owner implementation.

Main reviewed all 1,073 lines of the bounded correction delta.
The correction restores full structural windows, independent arrow erasure, required runtime IR, nominal wrapping, and exact vertical comparison.
Main adds capture-start equality and legacy-window containment with checkpoint-preserving refusal probes.
The unfiltered corrected run exits 0 in `u11-final-owner-corrected.exit`.
All sixteen steps pass, with 2,802 passing tests, one skip, and all 232 precompile tests passing.

Astra's source review identifies one remaining endpoint gap in both runtime validators.
A correct owner can still accept an actual erased span that extends through its opener.
The correction requires actual erasure to end at or before the supplied runtime opener.
The list-to-opener whitespace check remains necessary and unchanged.
Direct function, arrow, and call probes reject widened captures, cancel pending syntax, and compare the complete original checkpoint.
Astra accepts that bounded source correction without another blocker.

The unfiltered endpoint rerun exits 0 in `u11-final-owner-endpoint.exit`.
All sixteen steps pass, including all 232 precompile tests.
Source acceptance and execution cover this bounded owner slice; they do not complete U11.

The follow-on predicate and arrow review remains a proposal until the owner slice completes and Astra validates the refreshed design.
The runtime parser currently recognizes untyped arrows; typed headers require a confirming lookahead before the arrow parser runs.
That lookahead must preserve the existing return scanner's function-type-prefix continuation rule.
A depth-zero arrow can belong to a return function type rather than the outer arrow.
Failed lookahead must retain every cursor field and publish no syntax.

The refreshed header API retains the existing return and signature layouts.
One transactional return parser owns the complete Store checkpoint and a copied cursor.
It rolls back on `.failure`, `.excluded`, and native errors; only complete success publishes either state.
One allocation-free arrow scanner exposes the existing admission scan and function-type continuation rules through a narrow wrapper.
The shared parenthesized-header helper receives each caller's existing list and its `params_alloc` allocator.
The helper must not append through a different allocator because both callers free that list through their stack fallback allocator.

Return raw spans retain the complete interval through `admission_end`, including trailing whitespace.
Legacy named and arrow scanners use that untrimmed interval when they test the exact ` is ` substring.
The shared return parser must not reuse the trimmed raw span from ordinary annotation parsing.
`parseAdmittedTypeValue` can retain the complete raw interval and its separate semantic endpoint.

Astra accepts the refreshed bounded header design with these requirements.
Predicate targets must start at the return interval's first identifier and retain the following `is` spelling.
Containment alone cannot reject a substituted later name.
Arrow cleanup must cancel the pending signature before its outer generic owner.
Rollback assigns array lengths directly, so the opposite order can restore discarded slots.
Successful publication remains signature first and generic owner second.

The first mixed-parameter guard vertical is released before the broader header matrix.

The worker returns the first header vertical and stops edits after formatting and diff checks pass.
Main reviews all 996 lines of that handoff's delta.
Main removes its new source-specific preflight hook and eligibility assertion before execution.
Full signature consumer lowering belongs to U12, so full-store comparison cannot claim that eligibility yet.
The dedicated runtime comparison, ordered individual lowering, exact owners, and four predicate-target mutations remain.
The unfiltered first-header run includes the independently accepted tokenizer helper and the expanded public baselines.

The first-header run exits 0 in `u11-header-first.exit`.
All sixteen steps pass, with 2,809 passing tests, one skip, and all 233 precompile tests passing.
This run executes all twenty-six header cases and the eight new prefix baselines through legacy CHECK.
The isolated tokenizer helper also gains execution evidence in that run.

Astra identifies one remaining producer and validator disagreement for repeated parameter names.
The parser selects the first matching actual parameter, but the validator retains the last matching parameter.
The scope analyzer permits repeated names, so this difference rejects a result that the parser produced.
The correction will stop validation at the first match without changing source ownership or consumer projection.
Main adds a direct repeated-name contrast with runtime parity first and the exact first pattern and binding.
The contrast enters an unfiltered red run before that correction.

The repeated-name probe compiles and exposes that exact failure in `u11-header-repeated-red.log`.
The run exits 1 across eleven successful steps out of thirteen, with 2,576 passing tests, one skip, and one failure.
The failing direct parse returns `InvalidPredicateTarget` from the validator.
Main adds one `break` after the validator records its first match.
Formatting and diff checks pass before the corrected unfiltered run starts.

Astra accepts the corrected first-header source without another blocker in that bounded scope.
The corrected unfiltered run exits 0 in `u11-header-first-corrected.exit`.
All sixteen steps pass, with 2,810 passing tests and one skip.
All 233 precompile tests pass again.
The broader header matrix can now proceed with independent ownership for source changes and comparison tests.

The return-source worker hands back only `type_syntax.zig` and stops edits.
Main reviews all 270 lines of that delta.
Empty narrowing retains the complete whitespace tail after `is`, with absent syntax and zero owned nodes.
The public admitted-value parser now delegates to one parsing core and preserves its existing native exclusion errors.
Three direct API tests cover raw provenance, whole-grammar compatibility, facet mutations, and invalid empty roots or ranges.
Formatting and diff checks pass; source acceptance and execution remain pending until the comparison worker stops.

Astra accepts the frozen return-source delta without a source blocker.
The comparison worker returns its matrix and stops edits; main reviews all 760 delta lines.
Main separates allocation failures by parser progress, independently of retained Store contents, and strengthens the missing-arrow diagnostic assertion.
The first matrix run exits 1 in `u11-header-matrix-first.exit`.
Fourteen of sixteen steps pass, with 2,822 passing tests, one skip, and two failures.
All 233 precompile tests pass.

Both failures expose incorrect probe expectations rather than a parser correction.
Final arrow allocation fails before the variable parser consumes its semicolon; wrapper failures reach EOF.
The allocation case now carries an explicit expected token and location.
The readonly compatibility syntax remains `readonly_modifier` over the `is` reference.
Existing final resolution removes the readonly wrapper for that unrecognized source, so the expected semantic root is the `is` reference.
Ordered individual lowering now compares each root with an independent legacy environment over the identical raw text.

Main also adds exact case counts and complete early-failure checkpoints.
Recovery checks use real atom tables, the actual `after` declaration binding, the retained body block, and its later `return true`.
The checks preserve runtime recovery rather than accepting EOF or a declaration count alone.
Astra finds no additional parser blocker in the bounded matrix, pending these probe corrections and their execution.
Formatting and diff checks pass before the corrected unfiltered run starts.

Astra accepts the corrected bounded header matrix without another blocker.
The corrected run exits 0 in `u11-header-matrix-corrected.exit`.
All sixteen steps pass, with 2,824 passing tests and one skip.
All 233 precompile tests pass again.
Module integration can now start with its smallest vertical; the full U11 census and remaining producers are still pending.

Main measures six return-endpoint contrasts through the unchanged legacy CLI after a one-case pilot.
Both named and arrow returns ending with `value is ` reach only the handler's ZTS500 refusal.
Those admitted predicates have no narrowing type after `is`.
Tab-separated empty narrowing reports ZTS204 at line 1, column 44 for the named function and column 15 for the arrow.
With nonempty `value is string   `, a named function returning `true` reports ZTS211 at line 1, column 1.
The corresponding arrow reaches only the handler's ZTS500 refusal.

Every command exits 1; receipts remain in `/tmp/zttp-reset-20261015/u11-return-endpoint-baseline/`.
The public header table now retains twenty-six cases, including these six outcomes.
Its new assertions await execution after source handoff.
The broader header matrix must preserve empty narrowing through existing absent-root syntax rather than introduce a refusal or replacement type.
U12 must preserve the observed difference between named and arrow predicate verification.

Astra accepts empty narrowing through the existing `TypeValue` model without another type or failure variant.
The narrowed interval must come from the tail after the verified `is` token and contain only whitespace.
Its root is absent, its owned range is empty, and every endpoint remains valid.
Target spelling, binding, and actual parameter membership remain mandatory.
The tab-separated form still requires a separate ordinary compatibility root over its complete return spelling.
That root parses as the reference `value` in the measured source.

The census must distinguish stored values from present roots.
An empty narrowing value claims no other root and cannot satisfy a nonempty-root allocation floor.
Existing nonempty predicate and compatibility allocation probes remain required.
This amendment applies to the later header matrix and does not enlarge the current first vertical.

Main measured eighteen related sources through the existing built analyzer, without rebuilding or contacting a provider.
The one-case pilot and eighteen-case run change only the case limit.
Receipts remain in `/tmp/zttp-reset-20261015/u11-arrow-return-baseline/`.
Typed optional function and arrow parameters report ZTS055 at line 1, column 20.
Untyped optional function and arrow parameters report ZTS003 at the same location, with the suggestion `')'`.
Typed default arrow parameters report ZTS054 at line 1, column 29; typed async arrows report ZTS001 at column 14.

Ordinary, grouped, object-property, call-argument, and nested-return arrows reach only the handler's ZTS500 refusal at line 2, column 17.
Unresolved and quoted arrow predicates reach that same refusal.
Tab-separated ordinary and `readonly` arrow predicates report ZTS204 at line 1, column 15.
The mixed-signature predicate with an untyped target reports ZTS601 at line 1, column 15.
A single-identifier typed arrow reports ZTS047 at line 1, column 14.
The ternary control reaches the handler's ZTS500 refusal.
Every command exits 1; these are diagnostic baselines, not successful handler builds.

Two targeted controls extend the baseline to twenty sources after another one-case pilot and twenty-case recording run.
The parenthesized ternary reaches the handler's ZTS500 refusal.
The return function type without an outer arrow reports ZTS002, `unexpected ')'`, at line 1, column 16.
Both commands exit 1; their complete receipts share the baseline directory.
One additional public test retains all twenty sources and exact ordered diagnostics.
The test also requires the expected stages, error counters, and contract presence through the public CHECK API.
Those stage assertions await execution after the current ownership source handoff.

The proposed next header slice shares parenthesized parameter and return parsing between named functions and arrows.
Single-identifier arrows retain their existing untyped path.
Parameter parsing declares the binding, parses an optional type, creates the pattern, appends the runtime parameter, then attaches its annotation.
Only annotated parameters enter `parameter_annotations`; predicate resolution uses every actual parameter of the current function.
The parser must resolve a predicate target through supplied parameter nodes and their declaration names, without a global name or offset join.
An unresolved target remains valid only when no actual parameter matches its spelling.
Validation must compare the target occurrence's spelling with the supplied actual parameter's declaration name, alongside membership and binding checks.

One transactional return helper will retain the complete raw return span and independent legacy classification.
The exact substring ` is ` selects the legacy guard classification independently from structured predicate grammar.
An ordinary structured predicate requires a separately parsed `legacy_ordinary_prefix` over the complete original span.
The narrowed root and compatibility root must have disjoint ranges and separate application ownership.
Any failure during the second parse must remove both ranges through the same checkpoint.
Validation must recompute the raw ` is ` facet and reject a different stored classification.
An ordinary structured predicate requires its compatibility root; guard predicates and value structures must not contain that root.
Direct mutations must exercise incorrect classification, missing required roots, and forbidden extra roots.

Arrow lookahead must confirm the outer `=>` after any nested return function type.
The assignment path must not treat an unconfirmed colon as sufficient evidence.
The async path can use the same lookahead only to retain its existing refusal; it must publish no syntax.
The grouped-expression path remains separate after failed lookahead.
The lookahead can reuse a small wrapper around `scanAdmissionEnd` with a copied cursor.
That scanner already applies `isFunctionTypePrefix` without allocation or Store mutation.
Lookahead must not parse speculative `TypeValue` records or stop at the first depth-zero function-type arrow.
Private controls must include a parenthesized ternary and a return function type without an outer arrow.
The measured simple ternary alone does not establish those ambiguity boundaries.
Function expressions, methods, destructuring, default parameters, optional parameters, async forms, and default exports retain their measured refusals.

The first vertical source is `const guard = (candidate, marker: unknown): candidate is string => typeof candidate === "string";`.
Its runtime IR must match the legacy parser before syntax assertions run.
The final arrow must own one signature with two actual parameters and one parameter annotation attached to `marker`.
The predicate must target the untyped `candidate` pattern and retain `string` narrowing without an ordinary compatibility root.
The signature interval starts at the parameter opener and ends at the `typeof` body token after `=>`.
An ordinary `echo` arrow will then establish parameter and return roots without a predicate.

Follow-on probes cover named and arrow unresolved targets, quoted guard classification, tab predicates, and the `readonly` compatibility root.
Target mutations cover another actual parameter, an external pattern, an incorrect binding, and false unresolved status.
Allocation sweeps must observe both return ranges, final runtime nodes, signature publication, and enclosing variable and export wrappers.
Recovered body errors must remove pending syntax while retaining an earlier seed and runtime recovery progress.
Astra accepts this preliminary header design with the recorded ambiguity, facet, target, and range checks.
Shared parsing must preserve each caller's binding failures, rest flags, diagnostics, and runtime allocation order.
This design acceptance does not release implementation or accept changing source.
The next header slice still requires an API refresh after the current generic-owner handoff.

The type-only module review identifies missing parser producers for the existing storage, checkpoint, rollback, and source-order checks.
Main measured eighteen module contrasts through the existing built analyzer after a one-case recording pilot.
Receipts remain in `/tmp/zttp-reset-20261015/u11-type-only-module-baseline/`.
Every command exits 1 with one diagnostic; complete JSON and direct statuses remain beside each source.
The rich top-level fixture reaches only the handler's ZTS500 refusal at line 6, column 17.

Nested import and export forms report runtime ZTS002 in both same-line and multiline functions.
Nested block imports also report ZTS002 in both layouts.
Those observations cover whitespace before nested keywords; they do not establish universal nested refusal.
The preliminary top-level-only recommendation was incorrect.
A comment between `import` and `type` reports ZTS002 at line 1, column 1.
A newline between `export type` and `{` reports ZTS002 at that location.
A newline before the import's `type` word remains admitted and reaches the handler's ZTS500 refusal.

The module path can contain a quoted semicolon without ending the erased statement.
A semicolon inside an unrecognized block comment instead leaves trailing runtime text and reports ZTS002 at line 1, column 24.
Semicolonless exports with trailing spaces remain admitted.
The current scanner also erases opaque import bodies and opaque bodies inside export braces.
The new path must retain those observed admission rules without introducing module resolution or stricter grammar.

The `zttp:types` refusal is asymmetric.
A type-only import from that name reports ZTS053 at line 1, column 1.
The same exact quoted name inside the import statement's comment also reports ZTS053.
A type-only export from that name is erased and reaches only the handler's ZTS500 refusal.
The preliminary review's broader import-and-export refusal statement was incorrect; the measured and source-checked rule must remain import-specific.
One additional public CHECK test retains all eighteen module sources; its stage and counter assertions await the source handoff.

A further one-case pilot and twenty-eight-case recording run establish the missing byte-boundary contrasts.
Nested forms immediately after `{` or at column one reach only the handler's ZTS500 refusal.
Indentation prevents erasure and retains the previously recorded runtime refusals.
At top level, one leading space causes ZTS002 at line 1, column 2.
An import immediately after a semicolon is erased; adding one space produces ZTS002 at line 1, column 25.
Adjacent type-only statements also differ: blanking the first semicolon prevents erasure of the second statement.

The saved adjacent import/export source reports ZTS002 at line 1, column 30.
The raw boundary check must model erased spans as spaces while preserving newlines.
The module producer must update `last_erased_type_span` after publication and apply the existing raw boundary helper.
The module slice needs both program and block hooks, conditional on that byte-sensitive boundary.
It must preserve refusal after whitespace and must not infer admission from tokenizer position alone.
The public test now retains all twenty-eight module sources; stage and counter assertions still await execution.

The proposed module scanner returns `not_type_only`, a separate import refusal, or one `TypeOnlyModule` value.
The scanner must preserve raw statement-end behavior, including quoted semicolons, semicolon inclusion, newline exclusion, and trailing spaces.
The scanner must not use tokenizer offsets to infer the raw end or add comment-aware statement termination.
Token-based cursor advancement is also insufficient when the raw endpoint occurs inside a comment.
The saved comment-semicolon source leaves `*/ from ...` after erasure and must retain the measured column-24 refusal.
The hook must resume tokenization at that exact raw endpoint with correct byte, line, column, and runtime lexical state.
It must not tokenize erased opaque bodies into regex, template, or brace state.
A direct next-token contrast must assert the surviving token for the saved source.
Exported structural and nominal declarations must continue through their existing declaration hook without duplicate module records.
The module record contains only its kind and raw span, with no runtime identity or atom.

The parser hook will check the existing raw boundary helper before scanning through a local cursor.
It will append the module record before publishing any cursor change or `last_erased_type_span`.
The hook must preserve the previous runtime token rather than making an erased token the previous token.
Nonmatches, refusals, and allocation failures must restore complete parser and Store checkpoints.
The refusal must remain separate from annotation failures and must never become a runtime module-parser retry.

`ParserCursorCheckpoint` currently omits `last_erased_type_span`, although that field changes later boundary decisions.
The module slice must add the field to checkpoint capture and restoration.
Existing declaration admission already updates that field only after successful parsing and has no later fallible operation.
A rollback probe must first publish a module, then exercise nonmatch, refusal, and append failure with a non-null prior erased span.
The probe must compare the complete parser checkpoint and all Store lengths.
Later public migration also needs the original refusal location after nested error recovery; the preliminary scanner API does not yet settle that state.

Astra accepts the bounded module design with an exact raw-resumption helper and a separate refusal record.
The tokenizer currently has no helper that resumes at an arbitrary erased endpoint without tokenizing the erased body.
The module slice must add one bounded tokenizer helper and explicitly own `tokenizer.zig`.
The helper copies tokenizer state immediately after the import or export keyword, then advances only byte and line position to the raw endpoint.
It preserves template state and restores regex eligibility through existing runtime-token logic; the initial synthetic EOF retains initial regex eligibility.
`Cursor.afterCurrent` then reads the first surviving token from that candidate state.

The scanner's refusal record retains its reason and original `SourceLocation`.
The parser keeps the first refusal in one optional diagnostic field outside syntax rollback and cursor speculation.
Typed root completion must reject that retained refusal before creating a successful program node, including after nested recovery.
Allocation failure retains precedence; no second generic diagnostic or runtime import retry is required.
The private comparator must inspect the retained record for its original location.
U14 will map that record to the existing strip-stage ZTS053 output.

The module design still requires a refreshed API after the current generic-owner handoff.
No module implementation is released by this preliminary design acceptance.

The final module API refresh identifies no layout conflict with the accepted owner or proposed header APIs.
The module record remains `{ kind, raw_span }`.
The scanner returns `not_type_only`, a refusal with its original location, or one module record.
The Store append method validates its span and strict source order before allocation.
Parser refusal handling uses a dedicated internal error, suppresses generic recovery diagnostics, and retains OOM precedence at root completion.

The independent tokenizer helper is released before parser hooks because its file does not overlap the header work.
Main reviews its complete delta after the worker stops edits.
The helper advances byte and LF positions without parsing erased text, then restores regex eligibility from the previous runtime token.
Four focused tests cover exact comment resumption, opaque lexical state, LF positions, and regex predecessor contrasts.
Those tests have source-review evidence only until both source workers stop and the unfiltered suites run.

Astra accepts the final module API refresh with additional source and failure invariants.
One shared raw scanner checks the supplied start, literal keyword boundaries, kind, and exact endpoint.
Local append and global module validation must require exact correspondence with that scanner.
Contextual statement admission remains the parser's responsibility.
Validation must not use `tokenAtOffset`, because opaque erased source can change tokenization before the supplied start.
Local append validation must not inspect unrelated pending syntax records.

One publication-health helper checks the original diagnostic count, diagnostic allocation health, and absence of a retained module refusal.
Every enclosing syntax transaction must use that complete condition.
A recovered nested refusal can otherwise publish a signature because the refusal deliberately adds no generic diagnostic.
The root still rejects the retained refusal before creating a successful program.

Public `parse()` becomes one failure boundary around private `parseProgram()`.
That boundary gives native OOM first priority, then diagnostic OOM, retained refusal, and the original error.
The boundary covers every early return and failures while recording diagnostics.
`parseProgram()` checks retained refusal before allocating the program list or node.
The program location remains line 1, column 1, offset 0.
This private extraction adds no recursion or public API.

Required probes cover leading and module-only erasures, complete rollback with a prior erased span, and exact surviving-token locations.
Nested refusal must retain priority over a later ordinary error; a later native or diagnostic OOM must retain first priority.
Successful comparisons check runtime and atoms before module records.
Header completion remains the prerequisite for module integration.

The first module run exits 1 in `u11-module-first.exit`.
Fourteen of sixteen steps pass, with 2,826 passing tests, one skip, and one stale error expectation.
All 233 precompile tests pass.
The typed diagnostic-allocation probe expects `ParseError`; the accepted root boundary returns `OutOfMemory`.
Main updates that expectation and adds the missing runtime allocation comparison before module metadata checks.
Plain JavaScript bypasses the new typed failure boundary and retains its previous error mapping.
Astra accepts this corrected pilot source; execution remains separate.
The corrected execution exits 0 in `u11-module-first-corrected.exit`.
All sixteen steps pass, with 2,827 passing tests and one skip; all 233 precompile tests pass.
The accepted four-file snapshot is `u11-module-first-accepted/` outside the repository.

Main measures eight lexical module contrasts after a one-case pilot.
All commands exit 1; receipts remain in `/tmp/zttp-reset-20261015/u11-module-lexical-baseline/`.
An unescaped newline in an ordinary quote reports ZTS008 at line 1, column 18.
An escaped newline reaches only the ordinary handler ZTS500 diagnostic.
An interpolation at depth 512 reaches that handler diagnostic; its overflow reports ZTS044 at line 1, column 527.
Nested templates beyond 512 levels still reach the handler diagnostic, so the new fixed stack cannot truncate them as success.
An unterminated quote before a later `zttp:types` import reports only ZTS053 at line 2, column 1.
A quoted newline inside interpolation reports two ZTS008 diagnostics at line 1, column 21 and line 2, column 5.
These measurements bound scanner corrections before broader module acceptance.
The scanner must not erase collected diagnostics or publish a partial endpoint after its own storage limit.

Astra accepts a bounded scanner correction with explicit allocator spill beyond the existing 512 inline frames.
Each frame holds one template's interpolation depth; the scanner uses no recursive calls.
At brace overflow, the scanner records the current location and removes only the failing template frame.
The immediate caller processes the same unconsumed byte, matching legacy error recovery.
An ordinary quote's unescaped LF records its location and remains available to the immediate caller.
Escaped LF remains clean.
Diagnostic deduplication compares source location regardless of kind.
A separate per-scan flag retains diagnostic status even when deduplication appends nothing.

The scanner owns a diagnostic checkpoint and restores appended entries after nonmatch or OOM.
Native allocation failure propagates and produces no endpoint.
A diagnostic-bearing scan returns a complete excluded module span; it never returns a partial span as success.
The parser resumes that complete span and retains private exclusion outside syntax rollback.
The parser publishes no module record for an excluded scan.
Root completion rejects retained exclusion before program allocation, after OOM and retained refusal priority.
Publication health also requires absence of that exclusion.
Local append and global validation use the same fallible scanner and accept only complete, clean, exact records.

U11 comparison excludes diagnostic-bearing module scans; U14 must publish their exact diagnostics before production migration.
Continuation claims cover traversed source and the adjacent measured refusal only.
The private parser does not claim discovery beyond an intervening runtime error.
No second global scanner belongs to this bounded correction.
Required probes cover spill allocation, diagnostic allocation, prior-diagnostic rollback, and all measured lexical contrasts.

Two further measurements extend the lexical corpus to ten cases after another one-case pilot.
An intervening malformed variable still leaves only the later ZTS053 at line 3, column 1 in public CHECK.
U14 must preserve that global admission priority before production migration.
Two saturated template frames report one structured ZTS044 at line 1, column 1041, although stderr prints twice.
The eight-case public test passes all 234 precompile tests in `u11-module-lexical-public.log` with exit 0.
The two additional public assertions await the next unfiltered run.
Sol now owns the bounded scanner correction and full module matrix in the four existing parser and comparison files.

The scanner correction passes all sixteen steps in `u11-module-scanner-correction.log` with exit 0.
That run contains 2,838 passing tests and one skip; all 235 precompile tests pass.
Astra then requires probes that fail after appending a diagnostic and exclude a scan after complete deduplication.
Main adds both controls and removes the duplicate parser allocator field.
The parser uses its Store allocator for module scanning and diagnostic cleanup.
The append-growth probe forces both allocation and resize failure.
Astra accepts the focused corrected source without an algorithmic blocker.

The nominal candidate selects ignored generic parameters while retaining full list spans and exact declaration backlinks.
Its scalar matrix retains ordinary nominal lowering and creates no generic scope or bound fragment.
Main makes allocation rollback depend on source progress, independently of the retained checkpoint.
The successful allocation callback compares its actual runtime parser before syntax metadata.
The combined focused run passes in `u11-nominal-module-corrected.log` with exit 0.
All sixteen steps pass, with 2,846 passing tests, one skip, and all 235 precompile tests.

Astra finds one additional nominal diagnostic boundary after that passing run.
An invalid scalar base hides an earlier removed type form in the generic list.
Five public CLI measurements confirm the correction after a one-case pilot.
Receipts remain in `/tmp/zttp-reset-20261015/u11-nominal-diagnostic-baseline/`; all five commands exit 1.
`void` in the generic list reports ZTS060 before the later ZTS048 for an invalid or absent base.
`any` in an ignored generic list produces no diagnostic; an invalid base still reports ZTS048.
`void` followed by an `any` base reports ZTS060 then ZTS041; location deduplication suppresses the base's ZTS048.
The failed declaration outcome now retains its exact generic-list span while all Store arrays and the cursor roll back.
Preflight checks that span before existing base diagnostics and retains compile-mode first-refusal behavior.
New direct tests check exact kinds and spans in both modes against the independent legacy path.
New public tests retain exact JSON outcomes and stages for all five sources.

Main integrates the broader module matrix after reviewing every changed line.
Its runtime and atom comparison precedes module metadata, and runtime allocation counts remain separate from type allocations.
Its error paths propagate native OOM instead of comparing OOM as a syntax refusal.
Module allocation sweeps classify failure progress independently and compare all seventeen Store lengths.
The clean sweep ends after its second module, which isolates scanner and module publication failures.
The active unfiltered run is `u11-module-matrix-nominal-diagnostics.log`.
The generic-arrow candidate remains outside the repository and still needs source review and integration.

U14 must explicitly transfer or dispose of module diagnostics when it adds typed parsing to the result wrapper.
The current result wrapper initializes only plain JavaScript, whose module diagnostic list remains empty.

The erased-prefix preparation identifies one missing validation field: `operand_span` on `ErasedTypePrefix`.
Grouping returns the inner runtime node and creates no grouping node.
A compound expression records its operator location rather than the grouped operand's opening position.
Existing IR ancestry therefore supplies no independent root that connects the prefix with its operand.
The parser must capture the complete operand interval while retaining the actual returned node as its owner.
That interval supplies validation data, never an attachment identity.

An actual arrow must enter the generic-owner path before erased-prefix reservation.
Expression prefixes finish after their object or grouped operand completes; statement prefixes finish after their block completes.
The general path captures actual erasure through the operand opener and retains its separate legacy recorded window.
The operand interval includes its object, parentheses, or block delimiters.
Local finalization receives the exact parser return and validates only its completed reserved slot.
The pending prefix owns the complete existing Store checkpoint.

The owner validator must check the supplied tag and its location within the operand interval.
Object and block locations must equal their operand start; grouped root locations must lie within their parenthesis interval.
Exchanged owners from disjoint operands must fail; valid nested prefixes can share their returned runtime node.
An interval alone cannot independently reject replacing a compound root with its own descendant inside that interval.
Exact local publication relies on the parser's returned node; the reset must not add an offset-based global node scan.
This evidence limit must remain explicit rather than becoming a broader mutation-resistance claim.

Ignored brace prefixes allocate no projection ranges or generic semantic records.
Parenthesis prefixes retain projected parameters and their bound fragments, including valid empty ranges.
Shared ownership checks must include those projected parameters alongside generic-owner ranges.
Fragment checks and application planning must visit each prefix fragment exactly once.
Private lowering must merge transient prefix declarations with ordinary generic declarations in source order.
No prefix creates a runtime node, atom, binding, signature, or semantic generic owner.

Complete-source eligibility remains limited to the seven accepted forms; bound projection remains direct-API-only.
The restriction must use syntax shape rather than fixture bytes or identifier names.
Wider operand grammar still needs characterization before production cutover; this temporary boundary does not authorize public refusal changes.
The first object-prefix vertical must check runtime parity, exact captures, the actual object owner, and zero prefix-created semantic records.
Owner exchanges and variable-node allocation failure follow before grouped operands and block recovery.
Variable and export wrapper failures must remove completed prefixes; recovered block errors preserve runtime progress while removing pending syntax.

Astra accepts the bounded prefix design with the following amendments.
Implementation still requires refreshed APIs after the current owner, header, and module slices.

Assignment and general paths retain different erasure endpoints.
The assignment path ends actual erasure at the angle list's end and records its interior.
The general path ends actual erasure at the operand opener and records the separately measured legacy window.
Both paths start actual erasure at the angle list's start.
Actual erasure contains the complete list and the legacy window; every span remains within the source.
Only legacy type whitespace can separate the list and operand; comments do not satisfy that check.
Empty windows remain valid, and the two paths retain their measured empty-list differences.

The operand interval ends immediately after its consumed closing delimiter, excluding following whitespace.
Object and block owners retain their exact opening location.
Grouped owners require an admissible expression tag and a location strictly inside their delimiters.
Calls and arrows remain admissible grouped expression roots; only a confirmed generic arrow header bypasses prefix construction.
Invalid indices, statements, declarations, patterns, and helper tags fail before payload access.
After prefix completion, expression parsing continues through the existing member, call, suffix, and operator loop.

Pending prefixes reserve their slot before operand parsing and finalize only that slot.
Global validation waits until all enclosing publication completes.
The projected-parameter census includes prefix ranges, overlaps, gaps, and empty ranges.
Each prefix claims its stored fragment range once.
A separate check confirms that bound references account for that range without duplicate or foreign references.
Application planning already visits all semantic fragments and must not add a second prefix walk.

Transient prefix construction merges with callable generic construction in source order after aliases and their single contractivity check.
Nested prefixes can return the same inner node; their compatibility requires characterization before production cutover.
The unique-owner check must not silently reject an accepted nested form.
The seven measured forms do not establish that wider grammar.

Main measures eight further prefix sources through the unchanged legacy CLI after a one-case pilot.
Adjacent `<T><U>` forms refuse as raw JSX in assignment, grouping, and statement contexts.
Those five commands exit 1 and report ZTS002 at the first prefix.
The nested form `<T>(<U>(1))` reaches only the ordinary handler's ZTS500 refusal.
An inner prefix in an object value and a grouped arrow operand also reach only that handler refusal.
All eight commands exit 1; receipts remain in `/tmp/zttp-reset-20261015/u11-nested-prefix-baseline/`.

Parser source inspection implies that the accepted nested group returns one inner runtime node through both grouping levels.
Therefore, blanket prefix-owner uniqueness cannot serve as a production invariant.
The later prefix refresh must distinguish valid nested operand intervals from exchanged disjoint owners.
Public regression assertions retain these outcomes; their execution remains pending.

Astra accepts a narrower cross-record invariant for the later prefix refresh.
Distinct records retain unique list starts and source order.
Operand intervals must be disjoint or strictly nested; crossing and duplicate intervals fail.
Shared expression owners require both operand boundaries to be strictly nested.
The outer operand must be parenthesized and contain the inner prefix's complete capture.
Each record must independently satisfy its tag, capture, and owner-location checks.

Cross-record checks run only after enclosing reservations complete.

Shared owners retain separate prefix records and separate transient construction in source order.
The nested group retains both `T` and `U` projections.
Outer failure removes both records and their ranges.
These checks do not independently reject same-interval descendant substitution; exact parser-return publication retains that responsibility.
The three new positive receipts remain public baselines until an explicit prefix API refresh expands the seven-form implementation boundary.

The general `<T> extends ...` producer has no established successful runtime owner.
Main measured assignment, grouped, and statement probes of that prefix.
All commands exit 1 with ZTS002, `expected expression`, at `extends`.
The columns are 19, 20, and 5 respectively, all on line 1.
The receipts remain in `/tmp/zttp-reset-20261015/u11-orphan-generic-baseline/`.
Cutover must preserve those diagnostic positions without publishing an ownerless semantic record.
These three probes establish those refusals; they do not prove every possible context is refused.

The same general producer also admits prefixes before braces and parentheses without a function or call owner.
Main measured `<T>{ id: 1 }`, its grouped form, `<T>(1)`, and `<T>{ const value = 1; }`.
All four reach the ordinary handler's ZTS500 refusal without earlier parser or type diagnostics.
All commands exit 1; the receipts remain in `/tmp/zttp-reset-20261015/u11-expression-prefix-baseline/`.
All four normalization commands exit 0 and retain the generic prefix in `canonicalSource`.
The exact normalized bytes remain in the same directory's `*.normalize.json` files.

These prefixes require syntax retention without an invented function or call owner.
Parenthesis prefixes still trigger legacy generic declaration work through a recorded signature offset.
That work creates parameter nodes and resolves bounds even when no function signature follows.
Brace prefixes have no such offset and skip that semantic work.
The direct path must preserve this distinction, including pool-capacity and failure behavior.
U10 can decline these bounded forms until U11 adds the accepted representation.
Astra accepts a separate `ErasedTypePrefix` record class for these prefixes.
Each record retains the actual erased span, exact legacy recorded span, and final expression or block owner.
Its compatibility tag distinguishes ignored parameters from legacy parameter projection.
Parenthesis prefixes reuse U10's projected parameter and fragment ranges for U12's transient declaration work.
Brace prefixes retain no such semantic construction.
Bounded prefix projections need direct API probes without adding sources to the seven measured forms eligible for complete-source comparison.
An actual arrow receives its normal generic owner instead.
The prefix creates no runtime node, atom, binding, function signature, or semantic generic owner.

Prefix publication waits for operand or block completion and every enclosing declaration or export wrapper.
Recovered block errors cancel pending prefix records while retaining runtime progress.
Validation checks exact owner tags, spans, record ranges, rollback, and application-base roots.
A separate census distinguishes erased prefixes from semantic generic owners.
Tests cover both capture paths, empty lists, whitespace, exact owners, transient parameter construction, and failure rollback.

The printer needs the exact legacy recorded span for every generic capture path.
Its region builder skips an empty span, otherwise expands that span by one byte and trims whitespace.
The actual angle span cannot replace that input.
U11 retains these facts; U13 retains printer migration.

Three further empty-list probes reach only the handler's ZTS500 refusal and exit 1.
Their normalization commands exit 0.
The empty object prefix normalizes to `const value = < > { id: 1 };`.
The empty assignment prefix normalizes to `const value = < > (1);`.
The empty general spaced prefix normalizes to `const value = (<>(1));`.
These outputs retain angle tokens even when an empty recorded span creates no opaque printer region.
Exact responses remain in the same baseline directory.

### U12 preparation findings

The final U11 refresh exposes one variable identity gap.
Repeated global declarations receive identical complete `BindingRef` values.
The parser accepts those declarations, and syntax validation does not reject the repeated binding identity.
A binding-keyed annotation map would collapse separate annotations or apply an annotation to a later untyped declaration.
U11 must retain each variable annotation's final declaration node before U12 begins.

The variable owner also retains the independently captured declaration start.
Validation checks the actual `var_decl` tag, complete binding, and runtime location against that captured start.
Tag and binding checks alone cannot distinguish repeated globals.
Global validation rejects absent or duplicate declaration owners while allowing distinct declarations with equal bindings.
Syntax-only callers can retain an explicitly absent runtime owner.

The parser captures its own annotation index before initializer parsing adds nested annotations.
Publication waits for final declaration allocation and healthy parsing.
Existing recovery and enclosing-wrapper transactions remove failed records.
Astra accepts this bounded U11 amendment before the consumer pilot.

The finalizer also validates the local annotation before publishing its owner.
The captured declaration start must precede the annotation and remain inside the source.
These checks validate the supplied owner without searching for another owner.
The wrong-tag probe must pass source bounds before testing the tag guard.
The established type-allocation sweep retains exact seed checkpoints and checks the finalized seed owner after failure.
Its progress classification uses the parser cursor, independently of the Store contents under test.
Astra accepts the completed amendment and bounded probes by source review.
The repeated-global probes establish runtime identity and ownership; U12 retains semantic comparison.
The amended small gate exits zero: sixteen steps succeed, 2,896 tests pass, and one test skips.
Its receipt is `/tmp/zttp-reset-20261015/u11-variable-owners-small.log`.
The final frontend gate exits zero: all 45 steps succeed, 3,702 tests pass, and one test skips.
Its receipt is `/tmp/zttp-reset-20261015/u11-focused-final.log`.
The complete local gate exits zero in `/tmp/zttp-reset-20261015/u11-verify-final.log`.
That script covers aggregate tests, standalone runtime, release binaries, handler compilation, smoke flows, isolation, offline replay, and formatting.
Final documentation checks exit zero: all eight steps succeed in `/tmp/zttp-reset-20261015/u11-docs-final.log`.
Whole-repository formatting and diff checks also pass.
U11 satisfies its source and execution checks and is committed as `f48b8295`.
All six draft-base fingerprints match the committed APIs before U12 integration.

The amended frontend gate exits zero: all 45 steps succeed, 3,702 tests pass, and one test skips.
Its receipt is `/tmp/zttp-reset-20261015/u11-focused-variable-owners.log`.
The first full gate exits one during the aggregate because the documentation scan flags retired-module literals in new rejection logic and fixtures.
The aggregate reports 8,459 passing tests, six skips, and no failing tests.
Its receipt is `/tmp/zttp-reset-20261015/u11-verify.log`; later script steps do not run.

The shared retired-module identity belongs in the existing base module for specifiers.
The compiler's restriction registry cannot supply that identity to the engine tier.
The base module now names the existing built-in prefix and uses that prefix in its existing syntax check.
The retired module name combines that semantic prefix with its module name.
Both frontend matchers and the new fixtures use the shared identity.

Astra accepts this correction by source review.
Existing literal refusal fixtures, diagnostics, registry rows, gates, and allowlists remain unchanged as independent checks.
The correction requires unchanged diagnostic bytes and metadata hashes before broader checks repeat.
The correction gate exits zero: all 27 steps succeed, 2,896 tests pass, and one test skips.
Documentation, metadata, and tier checks pass.
The receipt is `/tmp/zttp-reset-20261015/u11-retired-module-small.log`.

Astra accepts isolated temporary drafting for the ordinary-annotation pilot while U11's final gates run.
Temporary copies cannot affect the frozen repository.
Integration still requires U11's passing checks, local commit, and a refresh against committed APIs.
Any API change requires renewed review.

Four measured sources remain under `/tmp/zttp-reset-20261015/u12-global-binding-baseline/`.
Two valid typed declarations and a typed declaration followed by an untyped declaration reach only ZTS500.
An untyped declaration followed by a bad typed declaration reports ZTS200 on line 2.
Two bad typed declarations report ZTS200 on lines 1 and 2.
Every command exits one; these outcomes preserve distinct type-stage and contract-stage refusals.

The repeated-global regression tests now compare those four sources through private consumer parity and public CHECK output.
The private comparison retains complete ordered pools, owner maps, TypeChecker diagnostics, and StrictChecker diagnostics.
The public comparison retains exact messages, suggestions, locations, order, totals, and absent repair intents.
The shared diagnostic expectation retains line 2, column 1 defaults for the recursive-alias cases.
Astra accepts both test patches by source review; execution remains separate.

The final callable-generic tests assert record presence before semantic absence for ignored and empty records.
Those tests retain each compatibility tag, projected range, actual runtime owner, and zero accumulator events.
Astra accepts the complete source and tests by source review.
The first execution stops before compiler tests because the compact-bound test declares an unused legacy view.
Main removes only that declaration and retains runtime parity and allocation assertions.
The receipt is `/tmp/zttp-reset-20261015/u12-phase-two-small.log`: exit one, thirteen of 21 steps, 1,148 passing tests, and one skip.
The corrected gate also includes the accepted repeated-global regressions.

The corrected gate reports 2,919 passing tests, one skip, and three failures across seventeen of 21 steps.
The public regression incorrectly expects no contract after successful type checking.
The two type-valid baseline responses include proof objects; the two type-error responses omit them.
Explicit per-case contract-presence expectations correct the test without changing production behavior.
Astra accepts that correction and the unused-declaration removal.

The two compiler failures expose the temporary identifier-only restriction for erased prefixes.
Typed parsing refuses bounded prefix lists before population begins.
Earlier bound tests manually reserve and finish Store records against legacy runtime IR.
Those tests prove Store projection and lowering, but they do not prove typed parser admission.
The complete-source U12 cases require an explicit prefix API refresh before that temporary restriction changes.

Astra accepts that bounded refresh within U12.
The legacy balanced-list producer does not require an identifier-only body.
The parser will retain scan eligibility, comparison classification, arrow precedence, operand openers, whitespace gaps, captures, and transactions.
The shared helper also governs private preflight list spelling; its operand limits remain unchanged.
Scalar and compound bounds require real typed parsing, complete ordered population, and preflight comparison.
The seven uncharacterized operand controls and five adjacent-list refusals remain unchanged.
Bound-position `void` and `any` contrasts must retain selective removed-form diagnostics without a blanket `any` refusal.
Defaults and operators in noncomparison prefixes must not inherit explicit-call grammar rejection.
Any new negative expectation for those spellings requires a measured legacy outcome.
This refresh supersedes U11's temporary direct-API-only bound limit without authorizing wider operand grammar or public refusal changes.

The unchanged legacy analyzer measures four additional spellings before the admission tests are written.
`<T extends void>(1)` reports ZTS060 at line 1, column 26.
`<T extends any>(1)`, `<T = string>(1)`, and `<T | U>(1)` reach only ZTS500 at line 1, column 1.
Each source initializes `const value`, and every command exits one.
The complete sources, JSON, stderr, and direct statuses remain under `/tmp/zttp-reset-20261015/u12-prefix-admission-baseline/`.
The new five-case test includes scalar bounds, compound bounds, `any`, defaults, and operators.
Each case requires both preflight modes and direct consumer parity, including the complete ordered type pool.
The `void` contrast requires one admission refusal in both modes.
Astra accepts the final prefix source, five-case comparison, and corrected global contract expectations by source review.
The corrected gate exits zero: all 21 steps succeed, 2,923 tests pass, and one test skips.
All 1,520 compiler tests and 238 precompile tests pass.
The receipt is `/tmp/zttp-reset-20261015/u12-phase-two-prefix-admission-small.log`, with a separate direct exit file.
This result covers callable generic construction, bounded prefix admission, and repeated globals; complete U12 behavior remains pending.
Main then integrates the separately accepted call-construction source while preserving the private observer.
That slice still requires its tests and execution.

The call-test review requires exact positional indices as well as semantic equality.
The complete ordered pool already supplies the common index interpretation.
The positive census also needs a generic-application argument and a real arrow with legacy call compatibility.
The corrected cases retain the stored application, exact base and argument types, final arrow owner, and actual-call query refusal.
Every construction assertion precedes checker execution.

The mutation probes distinguish validation boundaries instead of assuming the latest guard rejects each malformed record.
Reversed actual calls pass Store validation, then reach the merged-order guard.
Reversed compatibility owners fail Store ownership order, while equal cross-stream starts fail capture provenance.
Each population refusal leaves source selection, health, scopes, pool state, and retained maps unchanged.
The seeded allocation sweep requires validation failure, selected failure, prior alias progress, incomplete call publication, and successful completion.
Main reviews all original test lines and the bounded corrections; Astra review and execution remain pending.
Astra accepts the corrected four-case census, construction-first assertions, and executable validation boundaries.
The first call gate exits one with nineteen of 21 steps, 2,925 passing tests, one skip, and one failure.
All positive call cases and the allocation sweep pass.
The refusal assertion assumes an empty generic alias map, but TypeEnv initialization installs built-in proof and effect aliases.
Main replaces that assumption with snapshots of the initial ordinary and generic alias counts.
The check still requires refusal to preserve source selection, health, scopes, pool state, and every retained map.
The receipt is `/tmp/zttp-reset-20261015/u12-phase-three-small.log`, with a separate direct exit file.
The corrected call gate passes all 21 steps with 2,926 tests and one skip.
All 1,523 compiler tests and 238 precompile tests pass.
The receipt is `u12-phase-three-alias-baseline-small.log` with its direct exit file.

The remaining consumer review finds two incorrect fixture assumptions before integration.
The `error` annotation names a reference; the syntax primitive enum does not expose the checker's internal error type.
A present unresolved variable annotation retains `null_type_idx`, then causes the checker's annotation census to fail.
That case must assert `UnresolvedTypeBinding` rather than enter a comparison helper that expects successful checking.
Unknown type information and a refused expression's internal error type require separate consumer observations.

Main measures the original primitive fixture and the nonempty Effects fixture through the unchanged legacy analyzer.
Both commands exit one; the primitive fixture emits no JSON and reports `UnresolvedTypeBinding` on stderr.
The Effects response retains two helper capsules at lines 4 and 8.
The first declares and infers `crypto`; the second declares `clock` and infers no capability.
Both effect capsules discharge, while both proof capsules retain empty declarations and remain undischarged.
The response reports ZTS623 at lines 4 and 8, ZTS500 at line 1, and a ZTS505 warning at line 1.
The full receipts remain under `/tmp/zttp-reset-20261015/u12-consumer-semantics-baseline/`.

The predicate production candidate selects the stored legacy return kind before reading its structure.
Ordinary returns lower their value or compatibility prefix before replay and retain the complete raw return spelling.
Guards replay first, retain boolean and the name marker, and omit raw return metadata.
Optional narrowing requires a resolved target, present root, exact marker provenance, and a match among sixteen annotated names.
The helper reuses only the owner's captured generic set and preserves the existing scope cleanup.
The caller advances the header cursor after the helper returns.

Astra rejects two initial arithmetic catches because those catches discard errors in proof analysis.
Validated raw spans and the complete literal marker match bound the offset additions.
Main replaces the catches with bounded arithmetic and retains false only for absent or mismatched marker provenance.
Astra accepts the corrected predicate production source; tests and execution remain pending.
The candidate remains outside the repository until the preceding call slice passes.

After the call gate passes, main integrates the accepted predicate production and five native growth tests.
Main also integrates the corrected lookup, primitive, strict-signature, call, and nonempty Effects matrices.
These newly integrated slices have no execution verdict yet.
The present-null test requires `UnresolvedTypeBinding` and distinguishes unknown metadata from a refused expression's hidden error type.
The Effects checks compare complete measured capsules, including the repeated-name winner and independent proof and effect discharge fields.
No test treats the source spelling `error` as an internal primitive.

Astra accepts both bounded predicate test corrections after main reviews every changed line.
Nineteen cases retain exact construction before checker execution.
The three missing-target cases contain stored compound record syntax but create no semantic predicate or pool node.
The allocation sweep preserves the nested field's named `T` reference rather than substituting the captured generic parameter.
Two public marker cases retain their measured final LF and complete diagnostic observations.
Main integrates the exact final patch and starts `u12-predicates-native-matrix-small.log` without test filters.
That gate exits one before compiler tests run because one native test calls an unqualified helper inside `TypeEnv`.
Main adds the `TypeEnv` qualifier without changing behavior and starts `u12-predicates-native-matrix-qualified.log`.
Astra accepts the complete integrated U12 source scope, including that correction, with no remaining source blocker.
This source acceptance does not establish an execution verdict.
The corrected gate exits one with 2,934 passing tests, one skip, and five failures.
Four failures occur in compiler tests; the fifth occurs in the public marker stage assertion.
That source defines only `guard`, so the existing CHECK guards skip verifier, flow, and path stages.
Astra accepts removing only those three expected stages; the other ten stages and all diagnostic assertions remain.
The native nesting assertion also uses an unsuitable traversal helper.
That helper follows declaration bodies without visiting each declaration's function-expression node.
Main replaces the assertion with the exact nested declaration's `init` owner after Astra accepts that correction.

Compound record predicate fixtures stop at source parsing before the intended semantic checks.
Main measures four array alternatives through the immutable legacy CLI before selecting replacement fixtures.
Every command exits one and emits JSON, which confirms admission rather than success.
The unresolved target reports only ZTS500; the untyped and seventeenth targets report ZTS601 at column 15.
The captured generic array reports only ZTS500.
Full sources, JSON, stderr, and direct statuses remain under `u12-predicate-compound-baseline/` outside the repository.
Fixture correction must preserve observable compound construction without changing production grammar.
Astra accepts the measured array replacements and the unchanged five allocation observation floors.
The missing-target cases now require stored array roots, nonempty ranges, absent semantic predicates, and unchanged pool size.
The allocation success case requires an array element named `T`, distinct from the captured generic parameter index.
The complete ordered construction comparisons still precede these direct facts.

The remaining lookup failure compares different reporting stages.
Private checking retains two equal `unpublished_ambient_global` diagnostics at 2:25 and 7:25.
Public CHECK removes the first beneath the type error at 2:3 through `dropRepeatsOfTypeErrors`.
Astra accepts adding the first diagnostic only to the private expected list.
Public CHECK assertions remain unchanged.
Main integrates all five test corrections and starts `u12-predicates-native-matrix-fixtures.log` without filters.
That run exits zero with all 21 steps, 2,939 passing tests, and one skip.
All 1,534 compiler tests and 240 precompile tests pass.
The complete predicate census and every allocation observation floor pass.
The accepted native growth and consumer matrices also pass.
The receipt retains the direct process status; prior failed runs remain failed evidence.

The complete frontend command then passes all 45 steps with 3,757 tests and one skip.
The diagnostic corpus runs all 182 cases without failure.
Astra's bounded simplification review finds three worthwhile mechanical changes.
Main reuses the existing map aliases, names the two private functions for their completed scope, and deletes one inaccurate comment.
Main also updates the module documentation to describe both source modes.
The review finds no efficiency change or eligible proof-test reduction.
Broader lowering consolidation lacks exact error and allocation-order equivalence, so that consolidation remains excluded.
The final frontend receipt is `u12-focused-final.log` after these mechanical edits.
That run exits zero with all 45 steps, 3,757 passing tests, and one skip.
All 182 diagnostic corpus cases pass within the existing cost budget.
Whole-repository formatting and `git diff --check` also pass after the final source edits.
The full local script runs as `u12-verify.log` with repository source fixed.
That script exits zero after every required CI-equivalent step passes.
Its scope includes the aggregate suite, standalone runtime, release binaries, verified handler compilation, workflows, offline checks, and formatting.
Main then corrects current architecture descriptions after the independent documentation review.
Those corrections name the bounded comparison preflight and distinguish parser-owned stores from the still-legacy high-level entry.
The final documentation command exits zero across all eight steps in `u12-docs-final.log`.
Astra accepts U12 for local commit with no remaining source or requirement blocker.
Production frontend callers remain legacy, and U13 preparation remains separate from this phase's completion.

Astra's U12 audit identifies remaining comparisons for lexical shadows, captures, call substitution, bounds, compact arity, and forward calls.
Strict comparisons must cover incomplete signatures and fully annotated arrows without return annotations.
Consumer comparisons must retain null, undefined, unknown, errors, and present unresolved annotations as distinct states.
Function specification comparisons must cover nonempty Effects declarations and repeated helpers.
Those comparisons satisfy existing U12 requirements rather than adding reset work.

The proposed API distinguishes omitted, legacy, and direct inputs.
Direct input borrows the syntax store, IR view, and mutable runtime atom-table receiver.
The current `AtomTable.getName` signature requires that mutable receiver.

The proposed retained variable map must use final declaration identity and validate the complete binding.
Complete binding identity alone cannot select the declaration's annotation.
Function and call maps use final runtime node indices.
A tagged function reference distinguishes legacy offsets from direct owners.
Checked query methods reject wrapper nodes as function owners and reject non-call nodes as actual calls.
The function specification API also distinguishes omitted, legacy, and direct inputs explicitly.

Every typed consumer checks environment health before treating missing metadata as absent.

An unselected environment must preserve existing legacy API behavior.
An explicit omitted selection remains different from that initial state and from an empty direct store.
The public direct population entry rejects a repeated selection before mutation.
The existing legacy population entry retains its established repeat behavior.
Astra accepts the amended API and bounded pilot, subject to U11's amendment, checks, and commit.

Eligibility validation leaves the environment and source selection unchanged when it fails.
After successful validation, population reserves the selected mode before lowering.
Lowering failure consumes that selection, and partial results remain unhealthy.
Eligibility refusal must not become an allocation failure.
Existing OOM and pool-capacity flags retain operational failures.

The direct variable map uses the final declaration node and retains the complete binding for validation.
TypeChecker selects the annotation through its actual declaration node.
Its existing active semantic maps remain unchanged.
The annotation census counts authored records, including resolved `null_type_idx` values.
The existing non-null binding increment remains unchanged, so unresolved annotations still fail that census.

Function specification input must match the environment's selected mode.
Both typed branches check environment and pool health before an absent result, including an empty effects table.
Shared compiler-tier helpers can lower syntax ranges into pool nodes.
TypeEnv retains alias resolution, scopes, ordering, and publication to avoid an import cycle.

The proposed first consumer vertical covers ordinary variable, parameter, and value-return annotations.
Its subset check rejects declarations, predicates, generic owners, explicit call arguments, and prefixes before environment mutation.
Production callers retain their legacy entries during that pilot.
The complete U12 implementation still requires the final owner API refresh and Astra validation.

The proposed `DirectSyntaxInput` borrows the Store, runtime IR view, and real runtime atom table.
Explicit omitted, legacy, and direct selections keep empty selected syntax distinct from omitted typing.
Retained variable annotations use final declaration nodes and validate every `BindingRef` field.
Retained function and call maps use final `NodeIndex` keys.
Raw signature annotations retain compact parameter positions and exact original spans.

Zig 0.16's `AutoHashMapUnmanaged` hashes struct fields and uses `std.meta.eql` for equality.
The direct owner maps need no custom hashing implementation.
TypeChecker must still bind a selected declaration type into its existing active semantic maps.
Its direct branch skips variable-name ordinals while retaining downstream expression lookup behavior.
Function specification queries must check runtime tags before selecting the actual function owner.

The first pilot will use this source:

```typescript
const seed: number = 1;
export function helper(value: string): Proof<string, "deterministic"> {
  return value;
}
```

The pilot compares runtime identity, ordered type construction, exact declaration and function owners, checker diagnostics, raw boundary checks, and function specifications.
A negative variable initializer must retain the legacy mismatch.
A retained-map allocation failure must make every consumer reject an unhealthy environment.
The pilot must pass before repeated-name and growth matrices expand its scope.

The scalar pilot is healthy for type resolution but is not a zero-error strict fixture.
The legacy CLI reports one ZTS061 at line 2, column 24, for its raw `string` parameter.
An inline-record parameter with `return value.id` produces no ZTS061 and reaches the unrelated missing-handler ZTS500.
That contrast publishes a discharged helper capsule declaring `deterministic`.
Both commands exit one; the complete receipts remain under `/tmp/zttp-reset-20261015/u12-pilot-boundary-baseline/`.
The pilot compares those exact outcomes instead of assuming which raw spelling the boundary rule rejects.

The bad-seed contrast reports ZTS200 at line 1, column 1, and the same ZTS061 at line 2, column 24.
Its initializer is `"x"`, which is not assignable to `number`.
The public CHECK path retains the strict diagnostic even when type checking also reports a mismatch.
The same baseline directory retains that source and complete response.

The measured variable-arrow source declares `Proof<number, "deterministic">` on its return.
The legacy function specification path receives the variable declaration, whose signature offset is absent.
Its helper capsule therefore has an empty declaration list and `discharged = false`.
Its inferred total, pure, read-only, and deterministic facts remain true.
The effect capsule also retains empty declared and inferred lists with `discharged = false`.
The command exits one with only the unrelated missing-handler ZTS500 diagnostic.

The receipt is `/tmp/zttp-reset-20261015/u12-variable-capsule-baseline/arrow.json`.
Astra requires this declaration-shape eligibility in both legacy and direct function specification paths.
The node-based signature API can still query the actual arrow separately.
Changing function specification eligibility would change public output beyond the reset's accepted exceptions.

The pilot review also identifies three failure and omission corrections.
An allocation failure during validation must poison environment health without selecting a source mode.
An eligibility refusal must leave selection, semantic state, and health unchanged.
Omitted source typing must retain shared module and ABI metadata.
StrictChecker must check its environment and pool at both boundaries, including when no TypeChecker exists.
Astra requires bounded probes for these corrections before pilot execution.

Legacy population must record source use, including an empty TypeMap.
Otherwise, an empty direct store can inherit earlier legacy aliases while reporting zero authored annotations.
Astra accepts a checked legacy entry that preserves the existing population body and proof-swallow ownership.
`populateFromTypeMap` returns `error{TypeSourceAlreadySelected}!void` and rejects an already direct or omitted environment before mutation.
Repeated legacy calls retain their established behavior.
Explicit direct and omitted selections reject earlier legacy population before validation or semantic mutation.
Explicit selection remains single-use; explicit legacy selection can follow the older legacy entry.
The existing fallible callers propagate the misuse error with `try`.
Both mixing directions and empty legacy inputs require bounded controls.

Astra accepts the corrected production source and all seven pilot tests by source review.
Main integrates the exact patches, updates the remaining legacy callers, and registers the new compiler-tier helper.
Formatting and diff checks pass before the unfiltered pilot gate.
That execution result remains separate from source acceptance.

The first pilot stops before consumer compilation because an import shadows the new engine import.
The gate also rejects duplicated error handling and the unstaged helper's absence from its tracked-file census.
Main removes the redundant import, shares binding publication, and stages the helper for that census.
The second run identifies an unreachable error-handler arm and a missing explanation for non-operational validation refusals.
Main separates the population failure policy into one private function and records that explanation.
Astra accepts both bounded corrections without any gate or allowlist change.

The corrected pilot exits zero: all 21 steps succeed, 2,903 tests pass, and one test skips.
All seven new consumer tests run within the compiler root's 1,502 passing tests.
The receipt is `/tmp/zttp-reset-20261015/u12-pilot-error-handler.log`, with a separate direct exit file.
This verdict covers ordinary annotations and the seven bounded tests, not complete U12 behavior or production cutover.

The independent construction review identifies non-generic declarations as the next slice after the ordinary pilot passes.
That slice processes structural and nominal declarations in Store order and finishes contractivity once after the complete loop.
Each declaration preserves the complete-root alias shortcut, parsed-root finishing, immediate alias publication, and operational health checks.
Nominal declarations wrap their lowered body with the existing nominal constructor.
The first fixture compares the ordered pool and both contractivity maps with structural, nominal, and unguarded recursive aliases.
Generic owners, explicit calls, erased prefixes, and predicates remain excluded from that slice.

Main measures both declaration fixtures with the immutable legacy analyzer.
The structural and nominal fixture reaches only the unrelated missing-handler ZTS500 diagnostic.
The unguarded recursive fixture reports ZTS212 followed by ZTS200 at line 2, column 1.
Both commands exit one; `/tmp/zttp-reset-20261015/u12-declaration-consumer-baseline/` retains their complete responses.
The next consumer comparison must preserve these distinct outcomes.

Astra accepts one shared helper for ordinary declaration publication through an exact Store declaration index.
The helper also handles the comparator's nominal declarations with exact ignored-generic backlinks.
Direct eligibility still rejects every generic owner, and the comparator retains its structural-generic branch.
The helper checks environment and pool health before an absent-body return.
The helper retains operational failure independently of the outer driver, without relabelling pool capacity as OOM.
Contractivity remains outside the helper and runs once after the complete declaration loop.

The replacement contrast changes `Loop = Loop` to `Loop = string` before an annotated variable.
The immutable legacy command reaches only missing-handler ZTS500 and exits one.
The final namespace contains no stale noncontractive entry for `Loop`.
The receipt is `/tmp/zttp-reset-20261015/u12-declaration-consumer-baseline/replaced-cycle.json`.
This contrast distinguishes a final namespace check from premature publication after every declaration.

The first declaration candidate shares ordinary publication correctly but its helper error handler repeats the pilot's closed-error-set problem.
The corrected helper keeps health, index, owner, and absent-body guards before the shared population failure handler.
Expected owner refusals then leave health unchanged, while later operational failures remain visible.
Its standalone allocation probe must fail before the pool records an error, so the outer direct driver cannot conceal missing helper protection.
The accepted absent-body source is `structural Empty =;`.

Positive semantic comparisons must install identical module and ABI metadata before population.
Contractivity comparisons must check complete map counts and entries, including indices no current alias reaches.
Negative fixtures must place subsequent declarations at a recognized declaration boundary.
A call-only refusal must contain no generic owner that could independently satisfy the same refusal assertion.
Each of the five forbidden-record cases must prove that its intended record exists before population.

Astra accepts the corrected declaration source and all four new tests by source review.
Main also pairs the standalone probe's pool and environment with the same allocator throughout setup and destruction.
The probe separately checks native capacity failure and environment OOM before an absent-body return.
Astra accepts that bounded test adjustment.
The unfiltered declaration gate exits zero: all 21 steps succeed, 2,907 tests pass, and one test skips.
Its compiler root passes all 1,506 tests, including the four new declaration tests.
The receipt is `/tmp/zttp-reset-20261015/u12-declarations-small.log`, with a separate direct exit file.
This slice establishes non-generic declaration population, not generic construction or production cutover.

The next phase-one slice admits structural generic declarations and ignored nominal generic declarations.
The shared helper validates declaration kind, exact owner backlink, compatibility, and projected range before semantic mutation.
The helper rejects projected counts above `MAX_TYPE_PARAMS` before indexing its fixed array.
Every comparator declaration delegates to that helper, which removes duplicate generic alias construction.

Structural construction retains parameter creation, complete-root alias precedence, body lowering, publication, and scope closure in that order.
Bounds and defaults remain opaque in structural declarations.
Ordinary and generic aliases remain separate namespaces.
An absent body creates no scope or alias.
A present body with zero projected parameters still creates a generic alias.
A present body without semantic meaning retains `null_type_idx` behavior.

Shared error cleanup closes each scope once and checks its inactive state and exact prior depth.
Invalid ownership or depth takes precedence over the original error.
Valid cleanup preserves the original operational error, including native pool capacity.
Moving catch sites into TypeEnv creates new proof-swallow entries even when the original comparator behavior stays unchanged.
The helper therefore uses explicit error-union branches without adding allowances.
The shared cleanup propagates unclassified errors through the scanner's recognized `else => return err` form.
Contractivity still runs once after the complete declaration pass.
Callable generics, calls, prefixes, predicates, and compatibility return prefixes remain outside this slice.

Four measured legacy fixtures remain in `u12-generic-declaration-baseline/` outside the repository.
`combined.ts` covers structural `Box<T>`, ignored nominal `UserId<T>`, and annotated uses.
`collision.ts` keeps ordinary and generic `Box` entries simultaneously.
`empty.ts` distinguishes an absent generic body from `empty-parameters.ts`, which uses a present body and empty parameter list.
All four commands exit 1 with only unrelated missing-handler ZTS500.
The comparison must check complete ordered pools, both alias maps, both contractivity maps, and runtime identity first.
The first compiled generic-declaration run catches a stale direct-only alias fact after the complete oracle comparison passes.
Nested `T` in `{ value: T }` remains a named `t_ref` in both frontends.
Only complete-root spelling uses the generic scope shortcut during declaration resolution.
The corrected fact checks `t_ref` and the exact name `T`; Astra accepts that test-only correction.

The earlier compilation fails when a cleanup return carries bare `anyerror` through captured `errdefer`.
A small Zig 0.16 probe reproduces that condition and compiles with an explicit `anyerror!void` coercion.
The two declaration-helper return sites use that coercion without changing cleanup or error identity.
Astra accepts the correction, and the subsequent unfiltered gate passes all 21 steps.
That run passes 2,917 tests with one skip, including five declaration tests and the seventeen-case public CHECK growth test.

Later callable generics need a retained set of existing parameter indices and constraints.
Re-entering such a set must allocate no pool parameter and intern no name.
The existing parsed scope token continues to validate environment ownership and scope lifetime.
`ParsedGenericSet` retains complete parameter names, indices, constraints, compact count, and its owning environment.
`captureParsedGenericSet` validates an active scope before copying those values without allocation.
`beginParsedGenericUse` validates the environment and count before pushing a scope with a fresh token.
The existing `ParsedGenericScope` and `endParsedGenerics` retain entry, cleanup, and operational health rules.
The retained set borrows only its same live, unmoved environment and pool, not source or syntax storage.

Reuse copies stored constraints with `addConstrainedParam`, without repeating name-based constraint installation.
Duplicate names retain separate indices while lookup still selects the first matching scope entry.
Complete names remain retained, while scope lookup preserves its 32-byte name limit.
Raw-root aliases retain precedence over generic parameters; exact `DictKey` retains its separate bound precedence.
Astra accepts isolated API implementation and public behavior probes before construction-phase integration.
Final-signature assertions remain deferred until actual integration publishes signatures.

Astra accepts the captured-set production source and four corrected API tests.
The duplicate-name probe checks active positional constraints for `string`, `number`, and `boolean` after reuse.
The allocation probe uses one failing allocator throughout pool and environment ownership.
Real scope handles fill actual capacity and close in reverse order after retained OOM.
These findings establish source acceptance; unfiltered execution supplies the behavior verdict.

Constraint construction stops at the compact owner count before any excluded bound fragment lowers.
The caller preserves original projection indices instead of remapping bounds to compact positions.
An empty projected name followed by a named record bound must not construct the excluded record.
Stopping only during later constraint installation cannot undo those extra pool nodes.
Phase two merges callable owners and projected erased prefixes by their list starts.
Ignored and empty projections perform no generic allocation; generic-only owners create no signature accumulator.

Astra accepts callable generic construction and ordinary-header reuse as one atomic slice.
The retained set map stays local to population and uses only final function or arrow nodes.
Construction captures each set while active, closes its scope, then inserts the captured set.
Header roots reuse that set through separate short scopes; variables inherit no callable scope.
The final bucket-order merge copies retained parameters into existing signature accumulators before name publication.
This slice still refuses calls, compatibility calls, predicates, and ordinary compatibility-prefix returns.

The compact-stop fixture retains `T` and `U` at original projected positions zero and two.
Its semantic set compacts those names to positions zero and one.
The bound loop stops before original position two, before any excluded fragment lowers.
A synthetic late-bound fragment must pass complete Store validation before it can probe that consumer boundary.

Transient prefix constraints disappear at scope closure.
A compound-bound comparison must establish prefix construction through the complete ordered pool, without adding retained prefix signatures.
Normal header reuse inherits scope capacity from phase two and usually performs no scope allocation.
The integrated failure sweep must not claim a header-entry allocation failure without observing one.
The accepted API growth probe covers that allocation; integrated probes require real bound, map, and publication failures.
Native pool capacity remains a pool-only failure instead of also marking environment OOM.

Main measures the first interleaved source through the legacy CLI before implementation.
The source combines two parenthesis prefixes with an annotated generic identity function.
The command exits 1 with only ZTS500 at line 1, column 1.
Its source and complete receipts remain in `u12-phase-two-baseline/` outside the repository.

Phase three merges actual calls and compatibility calls by their list starts, outside every function generic scope.
The direct eligibility check must reject reversed or equal call starts before source selection.
The current Store validation does not establish that merged order.
Actual call queries continue to reject function and arrow compatibility owners.
Empty semantic argument ranges publish no call entry.
A nonempty semantic range retains every position, including `null_type_idx`.
Order validation includes empty records and every compatibility record before selection.
The complete map comparison checks exact counts and correspondence in both directions, including compatibility owners and empty omissions.
Astra accepts this phase-three preparation, subject to the final API refresh after phase two.
The refreshed production proposal uses one complete merged-order pass instead of separate scans for each stream.
That pass processes every record and preserves each stream's relative order, so strict output order also proves strict subsequence order.
The proposal removes a generic-owner loop whose current branches all perform no action.
Mandatory Store validation still checks every owner combination before source selection.
Astra accepts the corrected phase-three production source after main reviews every changed line.
That verdict covers source only; integration and unfiltered behavior checks still require the completed phase-two gate.

The header phase merges variables, parameters, and returns by authored spans, rather than processing complete functions consecutively.
Parameter and guard events replay the compatibility map before lowering; ordinary returns lower before that replay.
The final merge copies each retained generic set into its signature without creating another generic index.
Tests must show parameter and return roots using the same phase-two parameter index.

Predicate population first selects the stored legacy return classification.
An ordinary predicate-shaped return lowers only its stored ordinary prefix.
A guard publishes a boolean return and lowers narrowing only when its narrowed root and compact target exist.
Quoted guard-classified values, empty narrowing, and unresolved targets create no semantic predicate.
Target selection uses annotated parameter spellings through the real atoms, preserving the compact legacy parameter projection.
That projection can select a later annotated parameter when the actual target record identifies an earlier untyped parameter.

Astra identifies another guard boundary: the first literal raw ` is ` marker can occur inside a quoted narrowing type.
Structured predicate syntax alone cannot authorize semantic narrowing under that legacy rule.
Before narrowing, the marker's trimmed target and narrowed interval must match the stored predicate separator.
This check validates byte provenance without parsing a type or reconstructing an owner.
A mismatch retains the boolean return without a semantic predicate.

Main measured two legacy CLI fixtures in `u12-predicate-marker-baseline/` outside the repository.
`tab-quoted.ts` uses `candidate\tis "a is b"` and exits 1 with only ZTS500 at line 1, column 1.
`space-quoted.ts` replaces the tab with one space and exits 1 with only ZTS211 at line 1, column 1.
The sources retain identical true-returning bodies.
These observations establish admission and distinct guard behavior, not complete predicate migration.
Direct consumer tests must retain both outcomes and separately assert semantic predicate presence.
Astra accepts the amended predicate preparation, subject to the final generic and call APIs.
Before narrowing, function-name publication means marking the accumulator; both name maps still publish during the final bucket-order merge.
Compact target lookup retains the first match within the first sixteen annotated names.
The consumer matrix must include a target beyond that limit and prove that missing targets construct no narrowing.

The existing name map still supplies undeclared-global inference at `TypeChecker.declaredTypeForBinding`.
Direct annotation attachment must not remove that semantic fallback.
Variable events can retain the existing last-name value through the real runtime atom table without restoring name ordinals.

The consumer census covers TypeEnv, TypeChecker, StrictChecker, and function specifications.
Current reconstruction uses type text, variable name ordinals, signature parenthesis offsets, alias name spans, and call parenthesis offsets.
The variable location map has no current reader; name ordinals supply variable semantics before binding to the actual declaration.
Untyped simple declarations also advance each spelling's ordinal.
Mixed annotated and untyped shadows need characterization before direct binding replaces that selection policy.

Function signatures have exact offset maps and additional name maps.
The name maps overwrite during hash-map iteration, so their winner has no documented source-order rule.
Type predicates and some inference fallbacks still select signatures by name.
Direct owner maps must not silently change those observable selections.
Forward calls, repeated predicates, repeated helpers, and inference fallbacks need measured expectations.

A proposed temporary `AutoHashMapUnmanaged(u32, ir.NodeIndex)` can preserve the old signature map's compatibility order.
The temporary key comes from the final runtime header location, solely to reproduce hash iteration.
Exact owner records attach every annotation; that temporary key performs no attachment or lookup join.
The initial proposal inserted only when the first annotation created its signature accumulator.
Astra found that proposal incorrect: Zig's `getOrPut` can grow the map before it discovers an existing key.
The projection must replay `getOrPut` for every parameter, ordinary return, and guard event that reaches legacy accumulator creation.
Only the first insertion assigns the final owner value; later accesses still reproduce capacity changes.
The temporary projection disappears after the final merge.
Retained semantic maps use only final node indices.
Astra must validate this proposal, including table growth and measured repeated-name contrasts, before U12 implementation.

Astra accepts the corrected mechanism as preliminary U12 design, subject to the final U11 API refresh.
The temporary map must start empty, without preallocation or retained capacity.
Its keys, access sequence, capacity policy, and successful allocations must match the legacy signature map.
Changing the value type changes allocation size but does not change bucket placement under those conditions.
Header-key correspondence still requires exact assertions against completed U11 owners.

| Probe | Required observation |
|---|---|
| Every accumulator event | Compare capacity and complete iteration order after each event, including repeated keys near both growth boundaries. |
| Signature kinds | Cover parameter-only, return-only, guard, anonymous arrow, generic-only, and atom-index-zero function cases. |
| Header correspondence | Compare nested, same-line, generic, and arrow header keys with exact final owners. |
| Returned allocation errors | Refuse incomplete publication after insertion, repeated-key growth, accumulator, or final-merge failure. |
| Successful growth fallback | Observe failed growth returning an existing entry without losing metadata; keep this dedicated probe outside strict failure sweeps. |

The successful standard-library fallback retains the existing entry and returns no allocation error.
Strict allocation sweeps must not falsely classify that successful fallback as a swallowed error.

Astra accepts a bounded private observer for temporary map facts that final metadata cannot expose.
One shared private implementation behind `populateSourceTypes` receives the optional observer; the public wrapper passes null.
Observed tests retain the public path's validation, selection, failure handling, and completion checks.
The observer adds no retained environment field, public selector, alternate population algorithm, or preallocation of the compatibility map.

The existing `direct_accumulator_events` increment remains after successful compatibility access and before owner-map access.
The trace separately counts completed accesses to both maps.
The independent oracle derives events from the real TypeMap instead of assuming two events per function.
The measured string `inner` helper has two typed parameters, which invalidates that assumption.
The trace discovers capacity transitions and compares complete bucket order after every event, including repeated-key growth.

Snapshot pointers expose read-only maps only during each callback.
Test-owned buffers copy keys and defined metadata while those maps remain live.
Private replay calibration can inspect partial maps before destruction.
Tests compare defined signature fields and counted slices, never padding, structure bytes, or undefined tail slots.

Validation OOM remains unselected and unhealthy; postselection OOM consumes selection and blocks consumer acceptance.
Retained publication state establishes failure intervals, not exact allocation sites without calibration.
The dedicated failed-growth probe requires induced allocation failure, successful replay, unchanged map capacity, order, count, and defined metadata.
That probe must complete with healthy metadata and exact retained signatures outside `checkAllAllocationFailures`.
Guard coverage waits for guard admission, and callable coverage waits for the accepted phase-two gate.

The native test review requires six bounded corrections before integration.
Owner-indexed signatures and trace order do not alone establish the final repeated-name winner.
Both complete fallback maps must match the independent legacy maps in ordinary and observed runs.
The atom-zero function and arrow need different signatures, so the fallback assertion identifies the selected owner.
The corrected control also requires the original name to be absent from both maps.

The calibration must explicitly discard a successful replay pointer and continue after a checked failure.
The failed-growth observer must compare complete entries from both maps while those entries remain live.
Compatibility entries include keys and owners; accumulator entries include owners and every defined signature field.
The comparisons retain map order, counts, capacities, and each name-publication marker.
No comparison reads undefined signature slots or structure padding.

The existing event counter increments before the owner-map access and cannot identify completed retention work.
A test-only completion observer counts successful accesses to both maps before classifying the annotation-retention interval.
That sweep enters the accepted shared source-population implementation and retains its validation, selection, failure, and completion checks.
Ordinary public legacy and direct runs still compare the observer-free result first.
The helper uses native error branches and precise switch explanations without changing the gate or allowlist.
Main reviews every correction line; renewed Astra review and execution remain pending.
Astra accepts all six corrections and the completion-only observation through the shared population boundary.
The atom-zero test now checks both parameter counts before reading a parameter slot.
It requires the named signature to use string and the arrow signature to use number.
Both complete fallback signatures must equal the named owner's signature, and the original name must remain absent.
Astra accepts that final guard and the complete native test source.
The test patch remains temporary until predicate admission; execution has not established its failure floors yet.

Current declaration-produced function nodes supply fallback names through their runtime `name_atom` and the runtime atom table.
Arrow nodes supply no legacy return-name fallback.
The direct input must include that atom table; it must not reconstruct names from nearby source text.
A function's atom index of zero must not alone mean that the function has no name.

The parameter compatibility projection retains compacted argument types, the annotation-count lower bound, and the actual-node upper bound.
Strict completeness also uses that compacted count.
An anonymous arrow with all parameters annotated does not require an explicit return annotation under the current rule.
Exported boundary diagnostics inspect original annotation spelling; semantic equality cannot replace the raw span.
Partial signatures skip parameter boundary checks because compacted entries do not map directly to actual parameters.

Function specifications already receive exact effect declaration nodes but convert those nodes into signature offsets.
The syntax path can replace that conversion with an owner query.
Capsule output enters public contracts, so repeated-name selection and raw annotation behavior require explicit fixtures.
The new path retains explicit legacy entry points until caller migration finishes.

Health and absence remain separate.
The current TypeChecker health check does not inspect environment health.
Function specification collection checks environment health only after finding a return type.
Allocation-dropped metadata can therefore resemble an absent declaration in that collection path.
U12 needs failure characterization and explicit health checks before the new syntax path publishes results.
The new path must never retry through legacy reconstruction.

Population order is a compatibility input, separate from final owner identity.
Legacy population completes aliases and contractivity, then constructs all generic declarations, then resolves all explicit call arguments.
Contractivity finalization runs once after the complete declaration pass, not after each declaration.
It next resolves variable, parameter, ordinary return, and guard annotations together in authored source order.
Finally, its temporary signature map supplies the hash iteration order for name fallbacks.
The direct path must retain that construction order without reconstructing annotation owners.

Generic declarations construct parameter indices once, including generic-only owners and applicable erased prefixes.
Later parameter and return resolution uses short scopes that reuse those indices.
Variable annotations inherit no function generic scope.
Real and compatibility call arguments merge in source order during the earlier call phase.
A per-function loop that resolves its annotations before the call phase does not preserve this sequence.
The preliminary U12 proposal requires that correction before design acceptance.

Typing profiles also remain explicit.
Loaded multi-module contracts omit type data for both entry and dependencies.
Imported summaries can attempt dependency type checking and block nested summaries without rejecting graph compilation.
The contract-only profile omits type metadata, while sound extraction uses entry metadata when present.
An empty selected syntax store must remain different from intentionally omitted type data.
The U12 worker must refresh this census after U11 defines the complete owner records.

Main measured seven lookup fixtures through the legacy CLI.
Every command exits 1; failure stages differ.
The complete sources, responses, stderr, and index remain under `/tmp/zttp-reset-20261015/u12-lookup-baseline/`.

Repeated nested forward helpers produce ZTS203 on the second helper's first argument.
The same fixture also produces two ZTS629 diagnostics for unpublished `inner` references.
Repeated predicates produce ZTS211 on the second predicate, then ZTS200 on the later narrowed assignment.
Repeated forward return helpers produce ZTS200 on the first numeric assignment, followed by ZTS629 for an unpublished `make` reference.
These observations freeze outputs; they do not establish valid forward-call semantics.
The first forward-helper candidate used prohibited string addition and was discarded before measuring the retained fixture.
Its response remains separately identified in the index.

Main measured a matrix with six, seven, twelve, and thirteen authored function signatures through the built U10 analyzer.
Each size has plain, one-space prefix, reordered, and same-line layouts.
The one-case pilot passes the measurement checks; the sixteen-case run changes only the case limit.
Every CLI command exits 1 with nonempty JSON diagnostics.
The sources and responses remain in `/tmp/zttp-reset-20261015/u12-growth-baseline/`, indexed by `index-limit-16.json`.

The seven-signature reordered source reports ZTS202 at line 9, column 8, followed by one ZTS629 at line 2, column 3.
Three leading spaces change that source to ZTS203 at line 2, column 9, followed by two ZTS629 diagnostics.
Those ZTS629 diagnostics occur at line 2, column 3, and line 9, column 3.
Only the leading spaces change; both call sites retain their line and column positions.
Sixteen measured prefix lengths, from zero through fifteen, retain both observed outcomes in `index-prefix-shifts.json`.
These measurements establish compatibility outputs, not correct forward-call semantics.

A mixed untyped shadow fixture reaches contract checking without a type diagnostic.
Its negative contrast produces ZTS200 when the inner string annotation receives the number 2.
A shadowed closure fixture also reaches contract checking without a type diagnostic.
Its negative contrast produces ZTS204 when the inner closure declares a numeric return but captures a string.
Those negative contrasts establish that the specific inner annotation and capture paths actually participate in checking.

### U13 preparation findings

The source review identifies printer spans and contract signatures as the direct migration areas.
`proof_ir.zig` has no direct TypeMap dependency.
The worker must refresh these findings after U11 and U12 supply complete syntax owners and consumer APIs.

`printer.zig` prepares source again and converts TypeMap entries into opaque regions.
Generic regions use delimiter arithmetic; declaration regions search for names and semicolons.
Annotations use raw spans, while type-only imports remain ordinary tokens.
The printer trims, sorts, merges, and copies opaque regions verbatim.
Direct syntax inputs must replace reconstruction without changing those region operations or copied bytes.

The refreshed source review finds two compatibility conditions beyond complete erased spans.
The legacy printer skips entries whose recorded spans are empty.
Declaration generic entries retain their angle delimiters, while other generic captures use owner-specific windows.
The current printer widens every nonempty generic entry by one byte at each end before trimming and merging.
Therefore, a complete typed erasure span cannot automatically replace the current opaque region.
The direct design must retain the exact layout projection, including refusals, without reconstructing an owner.

Type-only imports and exports remain ordinary original-source tokens in the existing printer.
Making every module span opaque would preserve different whitespace and change normalized bytes.
The new printer input must retain that token policy unless a separate approved change permits different output.

Main measures six normalization fixtures through the unchanged legacy analyzer after a one-case pilot.
Every command exits zero, converges without rewrites, reports zero residuals, and returns fully canonical output.
The empty prefix becomes `const value = < > (1);` followed by LF.
The empty function list becomes `function f < > (value)` with the existing multiline body layout.
An absent nongeneric declaration becomes `structural Empty =;` followed by LF.
The absent generic declaration retains `structural  Empty<T>  =   ;` and its original LF.
The nonempty generic declaration also retains its original internal whitespace, while the following variable receives normal spacing.
The type-only import becomes `import type { A, B } from "model";` followed by the normally spaced variable.
Complete sources, JSON, stderr, and direct statuses remain under `/tmp/zttp-reset-20261015/u13-printer-baseline/`.
Normalization JSON does not expose printer refusal or its reason, so unchanged bytes do not alone establish successful printing.
The direct printer tests must check that boundary separately.

Main then measures the legacy printer directly through a temporary native Zig harness.
The harness compiles successfully, passes a one-case pilot, then runs fourteen cases with only the case limit changed.
The absent generic declaration refuses with `UnprintableConstruct` and `self_check`.
The commented callable refuses with `UnprintableConstruct` and `comment_position`.
The other twelve cases return exact output bytes.
Those cases include empty lists, adjacent and exported declarations, a declaration without its terminator, complex annotations, and type-only module spacing.
The complete sources, harness, compiler arguments, output JSON lines, and direct statuses remain under `u13-printer-direct-baseline/` outside the repository.
These measurements establish printer behavior independently from normalization fallback.

The preliminary printer proposal does not establish a need for capture-only storage or a completion flag.
Private eligibility restrictions alone do not prove missing metadata.
The first implementation must use existing owner records and state the parser-owned input guarantee.
Store validation checks supplied records, not capture completeness.
The printer must retain carriage-return and token checks before region validation, preserve OOM, and retain global region sorting and merging.
Astra accepts the bounded printer design after the fourteen direct measurements.
The first slice changes only `printer.zig` and retains existing owner records and legacy production callers.
Legacy preparation keeps its current catch-all, including OOM mapped to `strip_failed`.
Direct validation must propagate OOM separately from other validation refusals.
Store validation can allocate indirectly through type-only module rescanning with its retained allocator.

The syntax printer needs complete spans for annotations, generic declarations, call arguments, declarations, and type-only imports and exports.
Each call must select one ownership source.
The existing printer entry remains available until caller migration.
Preparation refusal currently maps to `strip_failed`; allocation failure remains distinct.
Carriage returns remain refused, and empty input remains empty output.
The self-check compares significant tokens and exact comments, with only trailing commas allowed to differ.
Canonicalization retains rewritten bytes when printing refuses.

`ContractBuilder.build` already receives the selected handler node.
Its signature query instead selects `handler` by name before trying a source offset.
That selection supplies declared Proof specifications and capability budgets.
Repeated names can therefore alter contract bytes even when runtime IR remains identical.
The new owner API must preserve measured selection behavior through an explicit compatibility projection.
U13 must not silently replace the name winner with the selected runtime handler.
Main measured two nested-versus-outer handler fixtures through `zts check --json --contract`.
Both commands exit 0 without diagnostics.
The nested handler declares `pure`, and the outer handler declares `deterministic`.
Both source orders report `pure` in `proof.declared_specs`.
The wrapper capsule retains its actual source line in each order.
Complete receipts remain under `/tmp/zttp-reset-20261015/u13-signature-baseline/`.
This command exposes proof JSON; these receipts establish no complete contract or certificate byte comparison.

Hole collection already uses exact effect declarations where available and binding identities for scope types.
Other expected-type queries reconstruct signatures from declaration offsets or function names.
Helper reachability also remains name-based.
Fixtures must characterize repeated helpers, selected handlers, holes, locations, and serialized order before removing those joins.
Missing Proof keeps the strict full profile; nonliteral Effects keeps ZTS511 and its current location.
Unknown capabilities retain their current diagnostics and failure behavior.

`effect_inference.zig` obtains an exact declaration, then converts that owner into a signature offset.
Declared callback effects index the compact signature with the actual parameter position.
U13 must retain U12's compact-parameter projection instead of binding both source and projected positions.
Missing type knowledge leaves an effect lower bound.
A function type without a marker supplies an empty pure row.
Unknown capability data retains the lower bound, while marker allocation failure propagates.
Existing tests cover an untyped callback but do not establish typed callback ceilings or annotation-gap behavior.

Main measures five proposed consumer fixtures through the immutable legacy analyzer.
Every command exits one and emits complete JSON.
The generic callback reports ZTS203 at 2:19 and ZTS204 at 2:3 before proof publication.
The annotation-gap and untyped callbacks each report ZTS601 at 1:13 and ZTS600 at 2:18 before proof publication.
Those receipts establish admission and early diagnostic behavior, not private callback effect rows.
The repeated helper capsules declare `pure` and `deterministic` at lines 1 and 2; both discharge with all four measured proof facts.
Both corresponding effect capsules retain empty declarations and inferred sets without discharge.
The repeated holes occur at 1:36 and 2:49, and both expect `string` through the existing name winner.
The first hole has no scope entry; the second contains `value` with type `string`.
Both repeated-helper fixtures report only ZTS500 at 3:17.
Complete sources, JSON, stderr, and direct statuses remain under `u13-consumer-baseline/` outside the repository.
Private effect facts and complete contract and certificate bytes still need separate observations.

Astra requires authored signature queries to use the selected consumer source, including the name-based hole query.
Omitted source typing must not read authored signatures from the separate semantic environment.
The initial blanket recommendation to return `unknown` for every omitted input is incomplete.
Contract-only extraction installs native ABI signatures without a TypeMap, and ordinary hole lookup reads that shared name map.
A source helper named `isDict` can therefore select the native boolean return signature under the current omitted-TypeMap path.
The exact serialized outcome still requires the private legacy harness.
The bounded proposal permits that name query only when the semantic environment also selects omitted source typing.
Current population guards exclude authored source signatures from that environment.
Other semantic source modes cannot supply authored signatures under an omitted consumer selection.
Nested declaration, capsule, and callback signature queries remain absent under omitted input.
Every supplied environment and pool must remain healthy before lookup or normalization discards its pointer.
Legacy wrappers must recognize an explicitly omitted environment instead of forcing that environment into legacy mode.
Legacy effect options normalize only to legacy or omitted; direct callers select the direct variant explicitly.
The direct analyzer entry must enforce the same selection and health checks as the effect-facts builder.
Direct inputs must match the actual parsed IR and AtomTable, so graph reparsing cannot reuse the original entry Store.
Per-module direct graph selection remains deferred until each module has matching parser-owned input.
Population and extraction failures retain their attempted states.
Serialization after successful extraction remains outside that transaction and cannot retroactively change the completed session.

Pipeline type inputs remain an ownership boundary.
Current extraction prefers the prepared frontend's TypeMap and otherwise selects an option's TypeMap.
The replacement needs explicit omitted, legacy, and direct syntax inputs.
An empty selected store must differ from omitted data, and direct failure must never retry through legacy input.
Full and sound extraction retain selected entry types; contract-only omits them for every loaded graph module.
Session passes retain one-attempt behavior, unavailable path facts, and propagated contract failures.

Contract JSON exposes source identity, budgets, properties, specifications, and diagnostics.
Proof JSON also exposes holes, capsules, expected types, source locations, and scope lists.
Proof IR depends on runtime node identity, child order, handler selection, and structural digests.
Artifact construction hashes the serialized contract bytes.
Certificates include proof evidence, discharged properties, artifact sections, contract digest, and runtime policy digest.
Parity must therefore cover contract and certificate bytes independently of proof IR equality.

The U13 fixture set needs every printer owner with comments and unusual type spacing.
It also needs repeated handlers and helpers with different Proof and Effects annotations.
Callback fixtures must contrast an annotated first parameter with an annotation after an untyped parameter.
Hole fixtures must cover repeated names, nested declarations, and module-level arrows.
Equivalent runtime programs with different type trivia must compare normalized output, runtime IR, bytecode, proof IR, contracts, identities, and certificate inputs.
Error fixtures must distinguish missing Proof, explicit Proof, invalid Effects, unknown capabilities, omitted types, and an empty store.
Allocation failures must prevent partial publication and legacy retry across syntax, printing, marker extraction, effect projection, and certificate construction.

U13 retains production callers in precompile, runtime type resolution, runtime extraction, compiler preparation, and canonicalization.
U14 through U16 own those cutovers.
The frontend command and `test-proof-checker`, `test-proof-ratchet`, and `test-proof-swallow` remain required unfiltered gates.
Contract goldens establish bytes; the proof ratchet checks producer and consumer reconstruction beyond the checker alone.

U12 commits locally as `0b7dc23b` after all required checks and final Astra acceptance.
Astra then accepts the revised U13 consumer design against that committed source.
The native legacy harness retains six complete contracts and confirms the omitted `isDict` boolean winner.
The ordinary omitted helper remains unknown.
The measured callback with a nested generic application retains an empty known row and its ZTS505 warning.
The gap and untyped callbacks retain lower bounds and ZTS512 errors.

Main measures one positive callback through an alias whose complete root contains `Effects<string, "crypto">`.
The callback stays at actual position zero and retains the captured generic bound.
The legacy row infers `crypto`, remains deterministic and read-only, becomes impure, and has no lower bound.
The capsule declares and infers `crypto`, discharges, and emits no diagnostics.
The corrected harness compiles, passes its one-case pilot, and passes all ten cases with only the limit changed.
The temporary compilation first fails because replacement escaping damages a Zig multiline delimiter; that failed receipt remains separate.
Complete sources, compiler arguments, JSON lines, and statuses remain under `u13-legacy-consumer-harness/` outside the repository.
No certificate byte comparison has run at this point.

Main integrates the printer after reviewing every changed line and the bounded allocation-order correction.
The first printer gate fails compilation because Zig does not narrow the captured validation error into the printer's error set.
The corrected switch returns `error.OutOfMemory` explicitly.
The repeated unfiltered `test-zts` gate exits zero across thirteen steps, with 2,703 tests passing and one skip.
Its four direct printer tests pass, including measured outputs, exact refusals, priority, and separate allocation failures.

The consumer source review removes an unintended change to path effects; both input modes retain source-free path analysis.
Analyzer borrowing now restores the original legacy field on success or failure.
Astra finds two completed-checker defects before integration: default options discard signatures, and explicit direct reuse bypasses typed module input.
The corrected reuse helper preserves the existing checker before fallback maps and checks direct capability before allocating temporary facts.
Astra accepts the corrected production patch, printer patch, and runtime certificate test as source reviews.

The first integrated gate passes ZTS, proof-ratchet, CLI, layering, and module-boundary checks.
It records 2,746 passing native tests with one skip; the custom CLI suite records 600 passes and one skip.
The only failed step requires an explanation for a switch that returns no authored type for a non-callable node.
Main adds that exact explanation without changing an allowlist or runtime behavior.
The gate's failure remains distinct from the passing suites.

The runtime test compares two independent parser results and module sessions across two source fixtures.
It compares complete contract bytes, source identities, policy bytes, properties, and complete lowered proof IR.
Both lowered proofs also match the fixed compilation's proof before certificate construction.
The certificate builds use each contract's own inputs and share bytecode, dependencies, and compilation evidence.
Exact certificate bytes and the certificate allocation sweep pass within the CLI suite.
This check establishes contract and certificate-input parity; U15 still owns independent compilation parity.
The broader consumer behavior matrix and graph-profile checks remain pending.

The first consumer test patch initially fails compilation because its relative contract import crosses the existing tier boundary.
Main changes that import to the existing `zts-contracts` export and adds a missing `try` in one assertion.
The corrected unfiltered gate passes 1,537 compiler tests and all 240 precompile tests, but one callback test fails.
That failure precedes effect analysis: exact native type-pool comparison detects different name offsets.
The complete run records 2,946 passes, one skip, and one failure across sixteen of eighteen successful build steps.
The proof-swallow explanation passes its separate gate and this repeated gate without allowance changes.

A temporary native probe confirms both pools contain ninety-five nodes for the generic-first callback source.
Three reference or literal nodes differ only in their name offsets.
Legacy function-type parsing adds each parameter name after its type and before the return type.
Direct lowering currently lowers all child nodes before adding parameter names at the parent node.
The retained name bytes prove this ordering difference; no public effect result has yet been compared for that fixture.
Record fields and template parts also need their native interleaving checked before a general correction is accepted.
The correction must use existing syntax ownership and retain exact pool assertions, operational health, and one-attempt behavior.
The temporary probe, its source, compiler arguments, and direct result remain under `u13-callback-pool-probe/` outside the repository.

The expanded native probe compiles, passes a one-case pilot, then measures eight cases with the same binary.
Function parameters, record fields, template parts, nested combinations, and an absent field expose the same ordering defect.
An absent function return retains equal nodes and names in this probe.
All eight cases complete measurement without an admission or population error.

The backtracking case exposes a separate loss: `const value: (first: Left, Right) = null;` retains eighty-four legacy nodes but eighty-three direct nodes.
The legacy pool retains `Left` and its attempted parameter name before the selected grouped reference.
`SyntaxParser.backtrackGroup` currently rolls those speculative syntax records back.
An event traversal cannot reconstruct records that no longer exist.
Public legacy CHECK admits that type syntax and reports only ZTS200 at 1:1 for assigning null to `first`.
A new admission refusal would therefore change existing behavior.

Main proposes a bounded group record that retains attempted parameters through existing owned arrays.
The proposed lowering traverses attempted children and names without constructing a function type, then lowers the selected grouped child.
Span validation, application masks, nested backtracking, absence, and failure cleanup need independent review before this amendment proceeds.
No production cutover or new source grammar belongs to this correction.
The eight-case receipts and public CHECK result remain under `u13-callback-pool-probe/` outside the repository.

Astra accepts the bounded group amendment and the corrected graph and contract tests as source designs.
The group amendment keeps the selected semantic span unchanged and validates attempted spans against the enclosing raw interval.
Attempted nodes remain in the same owned range and use the existing parameter array.
The lowering must emit attempted parameters without a function constructor before it lowers the selected grouped child.
Nested attempts retain distinct parse occurrences, and failure rollback still covers all seventeen arrays.

Main integrates seven contract fixtures across full and sound extraction profiles.
The fourteen comparisons retain exact runtime stores, atoms, pool facts, contract bytes, and transient capsule and hole fields.
Two additional CLI observations retain the nested hole's expected number at 2:37 and the module arrow's expected unknown at 1:43.
The nested hole keeps function name `outer`; the arrow hole keeps its `value: string` scope.
Both CLI cases report only ZTS500.
The retained sources and JSON remain under `u13-hole-owner-baseline/` outside the repository.

The graph tests compare omitted, legacy, and direct supplied inputs in contract-only sessions for both loaded modules.
All six sessions omit authored types and retain exact module and merged contract bytes.
The public legacy graph callback preserves the prepared entry signature over a fallback map and omits dependency signatures.
Direct graph refusal performs zero dependency reads after a healthy legacy reader control.
The repeated small gate passes 1,539 compiler tests and all 240 precompile tests.
Its only failure remains the known callback pool-order assertion; the graph tests and fourteen contract comparisons pass.
The complete run records 2,948 passes, one skip, and one failure.

### U14 through U16 preparation findings

The source census separates six cutover groups and their public boundaries.
Each implementing worker must refresh this census after U13 defines the final syntax APIs.

| Phase | Caller group | Current boundary |
|---|---|---|
| U14 | CHECK root and imported files in `precompile.zig` | Owned source preparation, parsing, then existing analysis stages. |
| U14 | CLI, machine check and verify, expert CHECK projections | Shared CHECK calls plus captured source and wire projections. |
| U15 | Single-module compilation and runtime source compilation | Typed source preparation, ordered analysis, then bytecode. |
| U15 | Loaded graph discovery, graph compilation, and graph contracts | Separate discovery parses and ordered compilation parses with shared atoms. |
| U16 | Normalization, parse identity, inline evaluation, graph records, generated tests | Distinct refusal and source-profile policies. |
| U16 | Direct Pi tools and compile benchmark | Tool-specific output contracts and the measured frontend boundary. |

CHECK records the public `strip` stage before parsing.
It collects source-admission diagnostics and stops parsing when any recovered admission diagnostic exists.
Parsing precedes virtual import validation.
Boolean, type, and strict analysis finish before their diagnostics publish in that order.
Any error in those stages prevents verifier and flow work.
Contract, policy, paths, trace, specifications, and canonical stages retain their current order.
The direct frontend must retain `strip` as a public stage label.
Compilation instead stops at its first admission refusal.

Imported file loading collapses read, admission, parse, and facts failures into `Unreadable`.
CHECK's summary and fault traversals can observe different dependency revisions.
Existing reader fixtures expect three reads of the same imported path.
A dependency type failure stops nested flow reads and leaves effects blocked without another nested read.
Cutover must retain paths, counts, order, depth, cycles, revision selection, and those early stops.
U6 captures only root bytes and gives no dependency snapshot guarantee.

Machine CHECK must consume `CapturedFile.effective_source` without reopening the root.
Its digest, diagnostic spans, contract location, counts, paths, and properties bind to those same bytes.
Machine verify projects the existing proof trace rather than recomputing verdicts.
The expert path tool uses the machine check envelope.
Direct Pi tools have separate visible failure text, including legacy strip wording.
Their cutover must retain JSON field order, success flags, diagnostics, and error text.

Graph discovery and graph compilation remain separate parse events.
Discovery does not use the shared atom table and stops import discovery when parsing fails.
Compilation reparses in execution order with one shared atom table and string table.
Single-module entry parsing can already allocate atoms before graph construction.
U15 must preserve that ordering rather than reuse discovery IR or reset shared atoms.
Loaded contracts consume graph sources and compilation parser state without rereading working-tree paths.

Single-module compilation uses full analysis with source types and reports boolean, type, then strict failures.
Loaded multi-module compilation uses `contract_only` for every module, including the entry.
Neither entry nor dependencies receive a type environment in that profile.
The existing graph fixture accepts its type, boolean, and strict diagnostics, with equal artifacts under strict and relaxed options.
This source check corrects the earlier preparation claim that loaded entry contracts receive type data.
Entry properties can exist before merging; the merged contract retains null properties.

Compilation parity includes entry and dependency bytecodes, dependency order, verification state, contract bytes, generated tests, violations, summaries, and proof evidence.
Artifact construction derives residual guards, policy identity, contract digest, certificate bytes, and executable graph identity from those outputs.
Runtime contract validation, policy attestation, and semantic proof acceptance all precede pool initialization.
An existing refusal test asserts that the server pool remains null.
The frontend cutover must retain that acceptance order.

Normalization runs CHECK and repairs to a fixed point, then prints once.
Printer refusal retains rewritten bytes, while allocation failure propagates.
Residual diagnostics inspect the emitted bytes.
U16 must retain raw type interiors, comments, refusal reasons, printed and changed flags, rewrite traces, residual spans, and byte idempotence.
The idempotence gate has nonempty floors for checked and printed files.

File TypeScript, raw virtual JavaScript, and typed CLI inline source remain distinct profiles.
Raw angle-bracket virtual names bypass stripping and contain no TypeMap.
CLI `-e` first prepares source as `<eval>.ts`, then loads the result as `<eval>`.
If that preparation fails, the helper copies original bytes and lets the runtime parser report its existing error.
U16 must not make every virtual source typed.
File `.js`, `.jsx`, `.tsx`, and `.mts` refusals remain unchanged.

Machine graph recording treats ordinary admission or parse failure as a tolerant observation.
Allocation failure and unsupported extensions propagate.
Other preparation failures currently use raw parsing; failed parsing adds no imports but retains the module digest.
Resolver failures produce ordered rejection rows, while later queued read failures silently omit a module.
The replacement must preserve that policy without retrying through the legacy frontend.

The four direct Pi callers are `zts_expert_narrow.zig`, `zts_expert_effects.zig`, `pi_goal_check.zig`, and `pi_repair_plan.zig`.
Generated path tests and `ir_identity.zig` also require explicit direct inputs.
The compile benchmark includes source preparation, parsing, IR creation, and code generation.
It excludes boolean, type, strict, and optimization work.
The direct parser must remain inside the same timing and allocation boundary.
Its final pilot and measurement retain the baseline host, toolchain, fixtures, options, and iteration counts.

U14 needs a mixed admission/parser error fixture and a captured-root refusal fixture.
Both must pin stages, diagnostic spans, counts, publication absence, and read observations.
A machine check/verify pair must compare payloads and proof traces over the same captured typed source.
U15 needs typed fanout with a shared dependency to compare atom order, bytecodes, routes, resources, and complete contract bytes.
A loaded-source mutation fixture must prove that bytecode and contracts use the loaded graph bytes.
A guarded graph fixture must compare proof IR, residual guards, policy identity, certificate inputs, and runtime acceptance.
Entry properties and merged null properties need paired assertions.
U16 needs all three virtual profiles, tolerant graph failures, and printer refusal after a successful rewrite.
It also needs exact outputs for the four direct Pi tools and parse identity with type comments and unusual spacing.

Each cutover must census `PreparedSource`, `parserInput`, `typeMap`, `sourceView`, `strip`, source extraction, and legacy printer calls.
Private oracle calls can remain through U16; production legacy calls must reach zero before U17.
The phase table's frontend and additional named gates remain authoritative and unfiltered.

Main closes three previously unmeasured private comparison exclusions through the unchanged legacy analyzer.
Destructuring reports ZTS001 at 1:7.
The `readonly<number>` fixture reaches strict analysis and reports only ZTS629 at 1:29 for unpublished global `y`.
The type comment fixture reports ZTS002 at 1:8 and ZTS047 at 1:7 during parsing.
These private exclusions must not become new admission refusals.

The captured-refusal source contains `any` at 1:14 and includes its final LF.
Public CHECK reports ZTS041 at that position and exits one.
Machine `verify` with the same content override returns `success:false`, nineteen undecided properties, and an empty diagnostics array.
Its process exits zero, and its reported digest equals the captured override digest.
The current `check` operation ignores content overrides, so its capture test must use the existing changing root reader.
The U14 preparation packet's generic machine-diagnostic expectation is incomplete; each operation must preserve its actual wire projection.
The direct changing-reader test still needs execution after the cutover; these CLI observations do not prove disk replacement timing.
The one-case pilot and four-case measurement script exit zero, while each individual command retains its direct status.
Complete sources, requests, results, stderr, and statuses remain under `u14-admission-baseline/` outside the repository.

### U17 preparation findings

The deletion census identifies `stripper.zig`, `type_map.zig`, and the private differential oracle as removal candidates after production callers reach zero.
The worker must refresh that census after U16.
`source_frontend.zig`, source views, diagnostic causes, and semantic type helpers remain necessary.
TypePool, `parseTypeExpr`, TypeEnv, and generic instantiation still serve generated contracts and binding types.
Raw `JsParser.init` remains necessary for virtual JavaScript.
The compatibility parser wrapper is separate from TypeMap reconstruction.

Source classification retains TypeScript files, virtual JavaScript names, and unsupported file extensions.
`.ts` and `.d.ts` remain TypeScript; angle-bracket names remain virtual JavaScript.
Only TypeScript files satisfy `isSupportedFile`.
Original bytes remain the source for identity, spans, and diagnostics.

`Position`, `SourceView`, `HumanDiagnostic`, and UTF-8 rendering helpers currently live inside `stripper.zig`.
Boolean, flow, verifier, type, strict, and diagnostic projection code still use those views.
U17 must relocate those helpers before deleting the scanner.
The source-view methods retain positioning, line extraction, and exact human diagnostic rendering.
Identity mappings for stripped offsets can disappear after every parser consumes original bytes.

The former stripper owns 17 admission kinds, with catalog and JSON mappings.
Their codes, messages, suggestions, positions, row order, collection, and abort behavior remain public contracts.
Shared ZTS008 and ZTS044 mappings also remain exact.
CHECK retains its `strip` stage label after the scanner disappears.
The diagnostic catalog hash includes ordered rows and producer tags.
Renaming `type_stripper` to `parser` would change persisted session and receipt identities.
The minimal migration retains that compatibility tag while moving diagnostic ownership.
U17 must compare the actual catalog hash before and after removal, beyond its existing named gates.

The root can remove scanner and TypeMap embedding aliases after the accepted internal API cut.
Source views, positions, source kinds, classification, and direct admission diagnostics remain curated exports.
`PreparedSource` and its error alias can retain their names if they become direct frontend owners.
Obsolete parser-input, TypeMap, and strip-diagnostic accessors disappear only after their caller census reaches zero.
The reset adds no public strip command or frontend selector.

Root changes remove the base TypeMap import, engine stripper import, and compiler oracle import.
The five analyzer test roots remain; the frontend fuzz root remains live.
Tier rows for TypeMap, stripper, and the oracle disappear, while the source frontend row remains.
The native graph gate also names the stripper as a root and needs a surviving frontend root instead.
The worker must measure graph floors rather than invent replacement counts.
Fourteen currently identified proof-swallow rows become stale when `populateFromTypeMap` disappears.
Other TypeEnv rows need the actual gate result; TypeEnv remains in the gate's proof scope.

Direct behavior fixtures must replace oracle machinery before its removal.
They retain primitives, groups, suffixes, compound families, semantic quirks, error precedence, source locations, runtime identities, and allocation cleanup.
They also retain delimiter depth, parameter packing, and deep-array contrasts.
Only legacy comparison allocation accounting, private exclusions, preparation helpers, and TypeMap extraction disappear.
The fuzz target must validate original spans and owned syntax while retaining its nonempty seed, allocation, accepted, refused, and located floors.
The annotation census and published example evidence must move from TypeMap kinds to exhaustive syntax-owner kinds.
Their negative floors remain required.

Current architecture, TypeScript, feature-detection, and contributor guidance must stop directing readers to deleted files.
Normalization comments, documentation drift checks, native evidence publication, and generated coverage also reference legacy owners.
U17 must update those current references, while U20 reconciles the complete final documentation set.
Historical plans can retain explicitly dated descriptions.

Safe removal first relocates live helpers and migrates direct fixtures.
Legacy adapters disappear before the final oracle, and the scanner and TypeMap files disappear after that oracle.
The final census includes legacy symbols, reconstruction joins, source extraction, and printer inputs.
It distinguishes intentional virtual JavaScript from legacy fallback.
No failed direct typed parse invokes the retired scanner.
The phase table's frontend, registry, native, spine, and normalization gates remain required and unfiltered.

### U18 preparation findings

`change_transaction.zig` owns locking, recovery, source commits, pending receipts, and acknowledgement.
Five production sites repeat lock acquisition and recovery.
They are the expert loop, autoloop, ledger replay, agent startup recovery, and agent receipt reconciliation.
Startup recovery and later reconciliation need separate acquisitions because another writer can commit between those lifetimes.

The current locked methods accept both a lock and a separate workspace root.
Several methods discard the lock value, so the method signature does not bind the root to the lock.
A recovered owner can retain the root and remove that separate method argument.
The owner must reject a prepared change set for another workspace before transaction writes.
Root canonicalization and path refusal order need characterization before selecting the owner's exact acquisition sequence.

Commit rechecks the proof read set before durable preparation and source renames.
The durable receipt precedes source renames, and the applying marker precedes candidate writes.
Recovery plans every target before writing any source candidate.
A third target state prevents writes to all other targets during that recovery attempt.
The loop and autoloop retain aggregate proof, approval, and session persistence in their existing owners.
Session persistence must still precede workspace receipt acknowledgement.

Recovery can make durable progress before returning an error.
Examples include an aborted marker, removed transaction directory, visible candidate bytes, committed receipt, or completed acknowledgement.
The existing transaction tests cover those outcomes, truncated writes, marker combinations, target combinations, and read-set mutation.
U18 must preserve those outcomes rather than promising rollback after every failure.

Current production callers unwind after a failed commit.
A proposed owner state can require closing and reopening after that failure before later transaction methods run.
This proposal needs review against all existing fault outcomes before implementation.
Raw locked helpers can remain private for core tests while production callers use only the recovered owner.
The public owner tests must cover recovery-before-return, lock release on failure, contention, root mismatch, and failed-commit reuse.
Receipt reconciliation also needs a failed-persistence retry fixture that proves acknowledgement never precedes durable session evidence.
The implementing worker must refresh the caller census after U17 because this review precedes the frontend migration.

### U19 preparation findings

The current source census finds no production caller for hosted state entries, loading, saving, or provider types.
The only live state call is `state.ensureStateDir` from `packages/runtime/src/proof_ledger.zig`.
That helper creates `.zttp` before timestamp selection, JSON allocation, serialization, or ledger opening.
It uses threaded I/O with the system allocator and an empty environment.
The helper propagates directory errors and closes its I/O backend on every return.
Moving the helper must preserve that order, relative path, and error behavior.

Ledger reads remain different: they create no directory and return an empty slice for a missing ledger.
Ledger writes retain `.zttp/proofs.jsonl`, exact JSONL bytes, ordered appends, and legacy `perf` and `equivalence` rows.
Local deploy writes the artifact before appending the ledger row.
A ledger failure therefore retains the artifact and prevents the success summary.
Live reload, historical proof commands, proof cards, and review rendering remain live consumers.

The bounded removal candidates are `state.zig`, `types.zig`, and `io_util.zig` under `packages/proof-review/src/`.
Their package exports, package test imports, and the CLI state test import can disappear after the fresh census.
`json_util.zig`, `printer.zig`, `review.zig`, and `spec_diagnostic.zig` remain live.
The proof-review package and its named test step remain necessary.
The `proof-review file_io` allowlist row becomes stale after removal; the runtime row remains necessary.
Separate unused build imports need a fresh consumer census and compile evidence before removal.

Existing ledger and deploy tests cover creation, missing files, ordered rows, legacy decoding, cards, and artifact ordering.
A sentinel fixture should prove that appending an exact proof row leaves existing hosted state bytes unchanged.
U19 must not open, migrate, truncate, or delete `.zttp/deploy-state.json`.
Two live review comments that name hosted state should describe persisted proof facts without changing fields or decoding behavior.
The implementing worker must refresh these findings after U18 before selecting the final removal diff.

### U20 preparation findings

The current documentation explicitly describes the legacy source pipeline in three guides.
`docs/internals/architecture.md` lists stripping before parsing and describes the private primitive comparison separately.
`docs/typescript.md` names the stripper in its introduction, implementation details, and build integration.
`docs/feature-detection.md` assigns type-position refusals and first string diagnostics to the stripper.
Its contributor instructions also direct new tests into that file.

The final documentation must describe actual parser ownership and refusal stages after the production cutover.
The rewrite must retain measured diagnostic order and lexical exceptions rather than promise broader validation.
The current search is a preliminary census, not evidence that those three files contain every final update.
U20 must refresh links, terminology, embedding entry points, test routes, and historical references against the completed source tree.

## Definition of Done

One stable pipeline owner manages each module analysis lifetime.
One immutable effect result serves matching path and contract consumers.
Distinct profiles and registry identities retain distinct results where required.

One typed parser implementation serves production callers.
Type syntax has explicit ownership and original source spans.
Production source annotations require no TypeMap reconstruction.
Existing graph discovery, compilation, and CHECK observation events remain intact.

Machine operations bind root identity and diagnostics to captured root bytes.
Workspace operations use recovered ownership without changing durable formats.
Retired hosted state code has no production dependency.
Existing state files remain untouched.

Public behavior remains compatible except for the explicit sibling-effect correction.
The independent checker, interpreter, request isolation, and persistent-read provenance remain intact.
All required checks pass, and their evidence states its scope.
Documentation describes the final design.
No live model call, corpus replacement, push, or release claim forms part of this reset.

The original planning task ended when this document was saved and reviewed.
The user subsequently authorized implementation through U20.
The implementing agent owns phase completion; the user owns later publication.

### U13 operational tests and lowering review

Main integrates seven operational tests after reviewing every changed line.
The tests retain exact omitted ABI and helper contracts, empty direct selection, source-error precedence, allocation failures, and serialization transaction boundaries.
The contract matrix adds two independently measured error cases, for eighteen full and sound comparisons.
Legacy CHECK reports ZTS511 for a nonliteral effect ceiling and ZTS504 for an unknown capability.
Both diagnostics identify the handler at line 1, column 17; each CLI exits one and also reports ZTS500.
The measurement receipts remain under `u13-effect-error-baseline/` outside the repository.

The first bounded lowering candidate has two source-review blockers.
Its planning buffers have overlapping error cleanup, which can free each buffer twice after a later failure.
Its retained-backtracking test still expects every primitive to be number, although attempted syntax now contains string and boolean.
Main and Astra independently identify the cleanup defect; Astra identifies the stale assertion.
Sol prepares a corrected temporary patch and a planning allocation-failure test.
No defective lowering patch enters the repository.

Main strengthens the eight-case probe to compare every pool array and primitive index.
The revised probe propagates admission and comparison failures through its exit status.
The earlier census remains measurement evidence, not a passing parity gate.

The operational tests initially fail compilation because they call the private contract constructor.
Main replaces that call with the public constructor and borrowed facts, then removes effect facts for the malformed-input control.
No production visibility changes.
Astra also rejects the inline callback fixture because nested function returns retain their existing marker semantics.
Main uses the measured `CryptoValue` alias fixture, which establishes the required capability and a nonempty callback projection.
The backtracking review confirms that an absent parameter child still creates a completed parameter record.
A zero-parameter backtrack therefore loses no completed child construction in the current state machine.

The corrected operational gate passes 2,952 tests with one skip and four failures.
The existing callback pool-order assertion remains red.
Three healthy allocation controls stop at `SoundModeViolation` before injection because their generic return conflicts with a concrete alias.
The effect projection control itself passes and observes the capability.
Sol prepares a source that satisfies both controls before another execution.

Independent review also identifies operational coverage gaps.
Callback marker extraction uses the environment allocator, so injecting only the effect allocator cannot reach that failure.
Extraction must enable export capture and establish a healthy non-null table before checking rollback publication.
Failure totals must count actual failures and distinguish failures before and after effect publication.
The health controls must include environment failure and explicit omitted normalization, beyond a poisoned legacy pool.
Serialization must cover allocation failures after partial output, while retaining a completed extraction and exact subsequent bytes.
These requirements refine the existing operational packet; they add no production behavior.

Astra accepts the corrected lowering source, bounded to the frozen v3 patch.
Main reviews all original and incremental changes, then integrates that exact patch.
The revised owner releases partial allocation once and transfers complete cleanup to the planning function.
The planner requires every name event and name slot before constructor use; it no longer inserts missing names late.
Flat orphan syntax remains part of lowering, which preserves existing partial-parse construction effects.

The strengthened native probe compiles against integrated source and passes a one-case pilot.
The same executable then passes all eight cases, with only the case limit changed.
Every node, field, parameter, member, name, and template-part array matches; all ten primitive indices also match.
The backtracking case now contains 84 nodes on both paths.
These receipts establish exact pool parity for the measured census, not complete frontend acceptance.
The unfiltered named suites and operational corrections remain required.

The unfiltered lowering gate passes the callback regression and all six new parser and lowering tests.
It reports 2,959 passing tests, one skip, and three known operational-fixture failures.
A revised nongeneric fixture then passes a native healthy control against integrated source.
Sound completion, extraction, a single crypto callback row, and a non-null export table all succeed.
The fixture-only correction enters the repository; the remaining operational coverage corrections remain pending.

### U14 review of producer policies

The first refreshed packet incorrectly applies one scan policy to several producers.
Independent source review rejects that simplification because current public diagnostics differ by producer.
Generic, explicit-call, and erased-prefix captures check removed forms without ordinary `any` collection.
Ordinary parameters report `any` even when it names an object member; variable and return scanning exclude that key.
Optional-parameter admission requires raw whitespace between `?` and `:`; untyped and comment-gap forms remain parser errors.
Assertion diagnostics start at the asserted type after raw keyword whitespace and retain the legacy type-start guard.
Mutable-export admission applies to `export let`; `export var` remains a parser error.

Refused declarations retain diagnostics from their internal scans before the declaration refusal.
Type and distinct-type declarations scan generic removed forms, then body `any`, then the declaration keyword refusal.
Interface declarations scan generic removed forms and their extends span, but do not scan body member types for `any`.
Recognition followed only by an endpoint scan would omit those earlier diagnostics.
The correction uses producer-owned spans and does not add a complete-program scanner.

Main measures these cases against the immutable legacy analyzer before production changes.
`u14-admission-policy-baseline/all.jsonl` contains five cases after a one-case pilot.
Export var reports ZTS002 at 1:1; export let reports ZTS057 at 1:1.
Generic, prefix, and call captures report no ZTS041, although later parsing or checking can still refuse them.
`u14-producer-policy-baseline/all.jsonl` contains eleven cases after its separate pilot.
The parameter key reports ZTS041 at 1:26; the variable key reaches handler proof analysis.
Typed optional syntax reports ZTS055 at 1:22; untyped and comment-gap forms report ZTS003 at 1:22.
Spaced assertions report ZTS042 at 1:23 and ZTS043 at 1:30, respectively.
The generic type, distinct-type, and interface fixtures retain each measured diagnostic's exact order and location.

Module lexical continuation also requires a narrower rule than the first packet proposes.
`u14-module-priority-baseline/all.jsonl` contains two cases after its pilot.
A module quoted newline followed by recoverable any reports ZTS008 at 1:18, then ZTS041 at 2:14.
A module quoted newline followed by an ordinary quoted newline reports only the later ZTS008 at 2:20.
Thus recoverable continuation accumulates diagnostics, while the actual later fatal return controls replacement.
A later retired-module refusal retains its separately measured replacement rule.
Astra prepares exact correction sections and string-context probes before the CHECK implementation can start.

### U13 allocation cleanup findings

The complete operational sweep exposes an existing ownership defect in contract capsule cleanup.
The same code exists in committed U12.
After the contract takes a proof summary, local error cleanup remains active during later effect-summary construction.
A later allocation failure therefore frees that summary locally and again through contract cleanup.
Nested string duplication also leaks when the following append cannot allocate.
The sweep reports two leaks and double-free diagnostics in `dischargeFunctionCapsules`.
Sol prepares a bounded ownership correction; the existing public extraction sweep remains the regression evidence.

The serialization sweep also corrects its expected error contract.
The allocating writer maps write-buffer allocation failure to `WriteFailed`; owned-slice allocation can still report `OutOfMemory`.
The test retains both exact errors only when allocation injection causes the failure.
It continues to require completed extraction, healthy analysis storage, and exact subsequent serialization bytes.
No production serialization error mapping changes.

### U14 string contexts and recovery evidence

Main measures seven lexical and recovery controls with the immutable legacy analyzer.
A one-case pilot and the same seven-case script both exit zero.
The ordinary value followed by a retired import reports only ZTS008 at 1:20.
The quoted object key reports only ZTS008 at 1:22; the runtime import reports only ZTS008 at 1:28.
The interpolation and type-span controls instead reach the later retired import and report only ZTS053 at 3:1.
The recovery string reports ZTS008 at 2:6, and the recovery import reports ZTS053 at 2:1.
Exact source bytes and complete outputs remain under `u14-string-context-baseline/` outside the repository.

These outcomes require caller-specific continuation and raw resume positions.
A tokenizer can consume beyond the newline, so recording a diagnostic alone cannot preserve later import recognition.
The dedicated admission profile restores an affected token or span checkpoint and resumes at the bounded legacy endpoint.
Normal parser initializers and ordinary tokenizer behavior remain unchanged.
Recovery returns eligible import, export, and declaration starts to existing statement dispatch.
Publication health also checks retained allocation failure and changes generation when deduplication suppresses an appended diagnostic.

Imported CHECK needs more than replacement parsing and typed module facts.
Its type environment must populate from the imported Store, exact view, and actual atom table.
Its healthy effect analyzer must select the explicit direct source input.
The failed-type path retains omitted typing, blocked effects, and its existing early read stop.
The separate fault and summary traversals retain their paths, revisions, and reader observations.

### U14 accepted implementation boundary

Astra accepts the refreshed CHECK design after the measured producer and lexical corrections.
The accepted temporary packet has SHA-256 `49d7643bd0596092f3fcb07ff56c055d888c868f10e5bc86ab74d8f807e8d019`.
This authority retains the binding requirements below; the temporary packet supplies implementation navigation.
U14 starts only after U13 passes its required checks and receives its local commit.

The existing typed parser owns admission through its existing producers.
No complete-program preflight or second statement grammar becomes a production acceptance rule.
A dedicated admission initializer leaves ordinary `init` and private comparison `initTyped` behavior unchanged.
Original source bytes provide runtime locations, diagnostics, and identities.
The Store retains seventeen arrays.
A separate collector retains diagnostic order, offset deduplication, generation, and caller-specific fatal selection.
Each selected diagnostic changes generation even when deduplication prevents an appended row.
Caught observations remain unselected in compile mode.
Native allocation failures remain distinct from semantic and diagnostic refusals.

The complete admission vocabulary remains fixed:

| Kind | Existing code | Producer boundary |
|---|---|---|
| `any_type` | ZTS041 | Confirmed type spans, under the owning producer's policy. |
| `as_assertion` | ZTS042 | Existing Pratt expression path with the legacy type-start guard. |
| `satisfies_assertion` | ZTS043 | Existing Pratt expression path with exact identifier recognition. |
| `unterminated_string` | ZTS008 | Every committed string consumer, with its caller's continuation policy. |
| `nominal_base_not_scalar` | ZTS048 | Existing nominal exclusion and admission endpoint. |
| `interface_declaration` | ZTS049 | Existing raw declaration recognition and internal scan order. |
| `type_alias_declaration` | ZTS050 | Existing raw declaration recognition and internal scan order. |
| `distinct_type_declaration` | ZTS051 | Existing raw declaration recognition and internal scan order. |
| `legacy_types_import` | ZTS053 | Existing type-only module scan, when reached. |
| `default_parameter` | ZTS054 | Existing header recognition and default-expression boundary. |
| `optional_parameter` | ZTS055 | Header question mark followed by raw whitespace and a colon. |
| `default_export` | ZTS056 | Existing export recognition and underlying declaration boundary. |
| `mutable_export` | ZTS057 | Existing export-let recognition; export-var remains a parser error. |
| `array_type_alias` | ZTS058 | Confirmed type spans under the owning producer's policy. |
| `readonly_array_type_alias` | ZTS059 | Confirmed type spans under the owning producer's policy. |
| `void_type` | ZTS060 | Confirmed type spans under the owning producer's policy. |
| `nesting_too_deep` | ZTS044 | Existing bounded type and module scanners with caller-specific propagation. |

The diagnostic catalog retains codes, messages, suggestions, and the compatibility producer tag `type_stripper`.
Assertions retain the asserted type start after raw keyword whitespace.
Refused declarations retain the outer export location where the existing raw producer uses that location.
Generic, call, prefix, parameter, general-type, nominal, and refused-declaration scans retain their distinct measured policies.
An already recorded assertion refusal survives a later semantic parsing failure in its recovery scan.

Top-level admission recovery follows the existing block recovery model and guarantees token progress.
Recovery returns eligible raw import, export, and declaration starts to the existing statement dispatcher.
It retains raw resume positions when a caught string scan advances tokenization beyond a later eligible producer.
A local publication checkpoint contains error count, diagnostic count, and admission generation.
Publication also requires that the error list has no retained allocation failure.
An earlier diagnostic does not poison a later independent valid statement.
A refused enclosing producer restores all seventeen Store arrays.
No refused outcome publishes a partial program root.

`DirectCheckSource` initializes in final caller storage because its parser borrows its atom table.
It borrows source and path, and owns atoms, parser state, runtime IR, diagnostics, and Store.
Accepted construction validates the Store and final runtime owners before publishing the root.
Parser cleanup precedes atom cleanup.
The owner exposes original-byte source views and typed parsed modules without a TypeMap accessor.

TypeScript CHECK roots use that owner and select explicit direct source typing.
Virtual JavaScript retains its current path until U16; unsupported extensions retain ZTS052.
The public strip stage remains first.
Admission refusal retains only that stage; parse refusal retains strip followed by parse.
Accepted input preserves import validation, optimization, analysis, verification, flow, contract, path, trace, specification, and canonical order.
Optimization retains runtime owner identities, and CHECK rebuilds its IR view at the existing boundary.
No direct refusal retries legacy preparation.

Imported TypeScript files own the same direct source object in stable caller storage.
Read, admission, parse, validation, and facts failures retain the existing `Unreadable` result.
Facts die before the source owner; owned source bytes die last.
Imported type storage and healthy effect analysis both select explicit direct inputs.
The failed-type path retains omitted typing, blocked nested effects, and the early read stop.
Separate summary and fault traversals retain dependency paths, depth, cycles, revisions, and the measured three-read observation.

Machine CHECK retains captured disk bytes and ignores request content overrides.
Machine VERIFY retains its override and its separate output projection.
The captured-any override retains digest `c8b4df16533c13f0566e41167dfd71099034d0660147424605c41ab19be39989`.
CHECK reports ZTS041 at 1:14 and exits one for those bytes.
VERIFY returns process exit zero, false success, nineteen `not_decided` properties, and no diagnostics.
The native admission reader characterization must establish one captured root read before the production CHECK cutover.
It must prove that later replacement disk bytes cannot change the captured digest or diagnostics.

The implementation uses six sequential review slices:

| Slice | Owned files | Exact bounded verification |
|---|---|---|
| Admission records and local policies | `packages/zts/src/parser/type_syntax.zig` | `zig build test-zts -j1`; exhaustive seventeen-kind census, exact policy order, allocation cleanup. |
| Parser producers and recovery | `packages/zts/src/parser/parse.zig`, `packages/zts/src/parser/tokenizer.zig`, `packages/zts/src/parser/type_syntax.zig` | `zig build test-zts test-zts-layering -j1`; all retained lexical controls, recovery, owner identities, and rollback. |
| Stable direct owner | `packages/zts/src/source_frontend.zig`, `packages/zts/src/root.zig` | `zig build test-zts test-module-boundary test-zts-layering -j1`; lifetime, root publication, and validation allocation failures. |
| TypeScript CHECK root | `packages/tools/src/precompile.zig`, `packages/tools/src/json_diagnostics.zig` | `zig build test-precompile test-zts-cli test-agent-protocol -j1`; reader characterization first, then all seventeen public results and exact stages. |
| Imported TypeScript consumers | `packages/tools/src/precompile.zig` | `zig build test-precompile -j1`; separate traversal revisions, three-read observation, and failed-type early stop. |
| Machine and expert projections | `packages/tools/src/agent_protocol.zig`, `packages/pi/src/tools/zts_expert_verify_paths.zig` | `zig build test-agent-protocol test-standin test-expert-app test-expert-golden -j1`; capture, overrides, digest, and separate VERIFY projection. |

Each slice receives source review and its unfiltered bounded checks before its dependent slice starts.
The complete U14 frontend command, phase extras, and common verification still apply at phase completion.
Allocation probes require an empty checkpoint before seed publication.
Only independently observed seed publication permits a later seeded rollback assertion.
A nonempty failure floor must prove that injection reaches work after that seed.
No additional feature, public selector, corpus replacement, or diagnostic format change belongs to this phase.

### U13 final source and focused acceptance

Astra accepts final U13 source without a remaining blocker after the bounded simplification.
The final unfiltered focused command includes the complete frontend set, proof checker, proof ratchet, proof-swallow, and CLI.
All 57 steps pass, with 4,018 native tests and one skip.
The CLI separately reports 600 passes and one skip; its certificate comparisons pass.
All 182 diagnostic corpus cases pass.
Formatting covers build code, packages, and tooling; whitespace checks also pass.
The full local script, final documentation checks, execution audit, and local commit remain required before U13 completes.

The complete local script exits zero after all final U13 source changes.
Its aggregate, standalone runtime, release compilation, verified handler compilation, workflows, offline gates, and formatting pass.
The script does not run the separate release-readiness mode, and this reset makes no release claim.
The final documentation checks and Astra execution audit remain before the local U13 commit.

Final documentation drift, link, and spine checks pass all eight steps.
Astra accepts U13 against the final source and execution receipts without a remaining requirement blocker.
U13 is ready for its exact-path local commit.
The next phase starts with native CHECK and VERIFY reader characterization before any production cutover.

### U14 characterization start

U13 is committed locally as `43beacd7` after all required checks and Astra acceptance.
Main reviews and integrates the two native reader tests after separate Astra source acceptance.
The tests distinguish captured CHECK disk bytes from request overrides and later disk replacement.
VERIFY retains its separate override and nineteen-property projection.
The unfiltered `test-agent-protocol` step establishes their legacy baseline before production changes.
No production CHECK frontend changes occur in this characterization slice.

The native characterization baseline passes all four steps and all 455 protocol tests.
The CHECK test retains its captured digest and ZTS041 at 1:14 while ignoring a distinct valid override and later disk replacement.
The VERIFY test retains the override digest, nineteen ordered undecided results, and no diagnostics after one root read.
These tests establish reader timing and override behavior; the existing immutable CLI receipt supplies process-exit evidence.
This baseline precedes production admission changes.

### U14 bounded classifier review

Astra accepts four caller-selected policies: `general_type`, `parameter_type`, `any_only`, and `removed_only`.
General and parameter policies emit all eligible `any` diagnostics before the first removed-form diagnostic.
General scanning excludes object member keys; parameter scanning includes those keys.
The `any_only` policy also serves refused type and distinct bodies, and interface extends spans.
Generic, explicit-call, and erased-prefix producers select `removed_only`.

Legacy `any` detection advances bytewise and checks only the trailing identifier boundary.
The suffix in `many` and `Many<...>` therefore remains a refusal.
Removed-form detection uses complete identifiers instead.
The bounded classifier validates its supplied span and remains independent of private preflight.
Compile mode stops after its first selected admission refusal.
Caught lexical observations do not select a compile refusal or change publication health.

Caught lexical diagnostics occur during the legacy `any` scan.
The parser integration must preserve that event order before removed-form detection.
A separate lexical list cannot simply precede or follow every `any` diagnostic.
The parser retains responsibility for lexical continuation, propagated failures, and raw resume positions.
The accepted composition takes a confirmed span, its policy, and borrowed ordered caught lexical diagnostics.
The classifier merges caught diagnostics with `any` events by source offset before the removed-form pass.
Equal-offset caught diagnostics keep their encounter order before collector deduplication.
Validation permits only the two lexical kinds, ordered offsets, and contained spans.
Validation also permits the exact endpoint diagnostic `[end,end+1)` for a terminating LF or a caught template-depth opener.
The lexical kind must match the source byte: `unterminated_string` at LF, or `nesting_too_deep` at `{`.
The caller retains the actual endpoint; the caller does not enlarge the span to contain that diagnostic.
The `any` pass resumes an ordinary quote at its unescaped LF and preserves template frame unwinding.
The removed-form pass retains its separate quote-to-end behavior.
Endpoint discovery can reach a propagated depth failure after an earlier eligible `any`.
Compile mode retains the earlier `any`; collect mode reaches and selects the fatal depth failure.
The parser must apply that distinction before selecting a propagated fatal diagnostic.
The local classifier's first-emission rule alone does not establish caller-level compile parity.
The accepted `classifyTypeSpanPrefix` entry shares the any and lexical pass with complete classification.
The prefix entry preserves the selected producer policy and omits only post-completion removed-form detection.
Parameter prefixes retain object-key diagnostics; general prefixes retain their object-key exclusion.
The `removed_only` prefix emits caught lexical diagnostics without adding `any` diagnostics.
No extra phase selector or invalid policy combination is required.

Four immutable CLI cases establish the mixed order in `u14-mixed-type-lexical-baseline/all.jsonl`.
The same measurement runs one case first, then four cases; both measurement commands exit zero.
Each CLI exits one because the source contains a refusal.
General scans retain ZTS041 at 1:14 before ZTS008 at 1:25, or ZTS008 at 1:19 before ZTS041 at 2:4.
Parameter scans retain ZTS041 at 1:19 before ZTS008 at 1:30, or ZTS008 at 1:24 before ZTS041 at 2:4.
These cases contain trailing `void`, but the separate removed-form scan emits no diagnostic after the malformed quote.

Five depth controls remain in `u14-template-depth-boundary-baseline/controls-all.jsonl` after a one-case pilot.
Both measurement commands exit zero; every CLI refusal exits one.
The outer template overflow reports ZTS044 at 1:529 with 512 or 513 repeated braces.
The unclosed 511-brace control reports only ZTS003 at 2:1.
The closed 511-brace control reaches type analysis and reports only ZTS204 at 1:1045.
The nested template control reports ZTS044 at 1:532, then ZTS041 at 1:539.
That nested result establishes caught inner-frame unwinding before the later `any` event.

Template recovery must finish the owned template before returning an inner statement boundary.
Parser brace depth alone does not represent `${` ownership.
The tokenizer's sixteen template slots do not establish equivalence with the legacy bounded template scanner.
The recovery design must use the existing bounded scanner from the known template opener or prove equivalent continuation.
Two immutable controls remain in `u14-template-recovery-baseline/all.jsonl` after a one-case pilot.
Both report only ZTS001 at 1:14 for unsupported interpolation, without the `any` hidden inside that interpolation.
One control contains a function parameter; the other contains a variable declaration in an arrow body.
Both measurement commands exit zero, and both CLI refusals exit one.

### U14 correction of compile observation policy

The earlier first-emitted-diagnostic assumption is incorrect for caller-caught lexical events.
Legacy compilation can continue after those observations and can publish a valid type projection.
CHECK still collects those same observations as admission diagnostics.
The two operations retain distinct caller policies.

The immutable compile measurements remain in `u14-compile-caught-baseline/typed-all.jsonl`.
The program runs one case first, then all four cases; both measurement commands exit zero.
A caught string error followed by `any` selects `UnsupportedAnyType` at 2:4.
An earlier `any` selects `UnsupportedAnyType` at 1:14 before the malformed quote.
A caught-only annotation with numeric value reaches ZTS200 and returns `SoundModeViolation`.
The same annotation with the matching string value compiles successfully and emits 164 bytes of bytecode.
These last two cases use an explicitly typed handler.

The collector adds the accepted `recordCaught` operation for caller-classified caught rows.
Compile mode leaves diagnostic items, generation, fatal state, and stop state unchanged for that operation.
Collect mode delegates that operation to ordinary recoverable recording.
Propagated failures retain fatal selection, and hard admission refusals retain the compile-first rule.
Compile publication health therefore depends on selected admission events, not raw caught-row counts.

The existing `SyntaxParser` already parses the confirmed trimmed span `"open` as the literal `open`.
The admission-aware producer can use `parseAdmittedTypeValue` after the compatible endpoint scan.
This case needs no new type node, legacy retry, or reconstruction fallback.

### U14 recovery boundary refinements

Slice 2 needs the three parser files named in its amended ownership row.
The tokenizer supplies bounded allocation-free resume operations.
Type syntax supplies shared bounded scanning from the existing legacy quote scanner.
The raw module scanner and private strict quote scanner keep their current behavior unless a necessary defect requires a change.

The shared endpoint retains each producer's exact delimiter set and arrow rule.
Variable annotations, named returns, arrow returns, and interface extends do not use one fixed general delimiter set.
Parameter scanning retains `skipParamType` rules, including its distinct comma, parenthesis, default, and brace behavior.
Declaration scanning retains its semicolon and multiline-newline rules.
Quoted-root propagation remains caller-selected: ordinary runtime templates propagate; general and parameter type scanners catch.
Admission scanning does not inherit the private scanner's early unmatched-parenthesis rejection.
For example, legacy general scanning reaches `any` in `(string; any)` rather than stopping at the inner semicolon.
The private wrappers retain their existing strict checks.
Compile mode ignores caught observations before propagated depth; an earlier hard `any` still wins through prefix selection.

Both ordinary template parsing and synchronization must finish an encountered template from its known opener.
A completed runtime template restores the regex state of `template_tail`, because the template is an operand.
It does not restore the state before the template.
The raw resume preserves enclosing tokenizer frames.

The parser records the public error prefix at the first failed top-level dispatch that makes the legacy parser return.
The parser captures that length after it records the unreported statement error.
An error inside a recovered block does not alone establish that boundary.
The full live error list and retained allocation state still govern recovery and local publication health.
When no admission diagnostic wins, the public result exposes only the captured prefix and the first returned parser error.
A later allocation failure retains higher priority.

Four recovery controls remain in `u14-recovery-projection-baseline/boundary-all.jsonl` after a one-case pilot.
Both measurement commands exit zero; each CLI refuses its source with exit one.
The spaced slash control reports only ZTS001 at 1:14.
Removing the space before its import puts that import at the legacy raw boundary and selects ZTS053 at 1:25.
Two failing top-level declarations report only the first ZTS002 at 1:16.
A first parser error followed by a template with a hidden typed function also reports only ZTS002 at 1:16.

Compile producer integration retains two further obligations.
Confirmed compatible raw spans use `parseAdmittedTypeValue` without a private strict endpoint rescan.
Caught module observations do not trigger private lexical exclusion or change compile publication health.
Ordinary `init` and private `initTyped` keep their existing behavior.

### U14 location-free failures

Admission diagnostics and admission failure are separate concepts.
A location-free failure rejects the root even when the projected diagnostic slice is empty.
The returned error remains separate from the last observed diagnostic, which supplies presentation only.
This distinction adds no admission kind and does not change compile publication generation for caught observations.

The immutable controls remain in `u14-location-free-baseline/all.jsonl` after a one-case pilot.
Both measurement commands exit zero; CHECK and compile each exit one for both controls.
A bare unfinished block comment makes CHECK return false success with no diagnostic rows.
A caught string observation before that comment supplies only ZTS008 at 1:19.
The returned compile error remains `UnterminatedComment`, while its presentation retains that earlier ZTS008 location.
The direct frontend must retain the same failure, stage, error count, and optional presentation behavior.

Slice 1 finishes with accepted source and an unfiltered `test-zts test-docs-drift` pass.
All fifteen steps pass, with 2,729 tests and one skip.
The final classifier source SHA-256 is `474fcec813cb28a7b9d6d02bb2c724bcff852df2d9b06d22fb655ebc22d5d83a`.
Astra accepts the bounded Slice 2 design after the exact endpoint, template, error-prefix, and caught-observation corrections.
Its accepted temporary design SHA-256 is `8576b036b995039e355d350edc9c18c18d12cc1a2bb955961400057e398ec107`.
The parser core proceeds outside the repository while the separate location-free producer review completes.

The source census finds only one live semantic location-free error: `UnterminatedComment`.
`UnsupportedAngleBracketAssertion`, `UnclosedTypeAnnotation`, and `UnclosedGeneric` have no producer.
Operational allocation failure remains separate.
Ordinary tokens, parameter types, and general type scans propagate unfinished block-comment errors.
Speculative call and generic scans can decline instead; later committed scanning can still reach the comment.
Interface bodies and template bytes retain their distinct legacy policies.

Seven further contexts remain in `u14-location-free-context-baseline/all.jsonl` after a one-case pilot.
Both measurement commands exit zero.
The complete observed results follow:

| Context | CHECK result | Compile result |
|---|---|---|
| Earlier `any` and `void`, then unfinished comment | Only ZTS060 at 2:15. | `UnsupportedAnyType` at 1:14, before the comment. |
| Earlier parser error, then unfinished comment | No diagnostic rows. | `UnterminatedComment`. |
| Unfinished comment inside a parameter type | No diagnostic rows. | `UnterminatedComment`. |
| Unfinished comment inside a general annotation | No diagnostic rows. | `UnterminatedComment`. |
| Unfinished comment inside a refused interface body | ZTS049 at 1:1. | `InterfaceDeclaration`. |
| Comment bytes inside template text | Analysis reports only ZTS500 at 1:1. | Exit zero after successful compilation. |
| Comment bytes inside template interpolation | Parser reports ZTS001 at 1:14. | Parser refusal after successful source preparation. |

Every CHECK command exits one; compilation exits zero only for the template-text control.
The observation design must distinguish committed events from declined speculation.
Committed Store rollback retains confirmed diagnostic observations and their generation.
Only unconfirmed staged observations can be restored.
Diagnostic commitment can precede complete owner recognition.
Legacy generic scanning reports removed forms before testing the following owner opener.
The diagnostic remains when that later owner test returns a nonmatch.

The one-case receipt `u14-location-free-context-baseline/generic-control.jsonl` confirms that boundary.
For `const x = <void> + 1; /* unfinished`, CHECK reports only ZTS060 at 1:12 after the terminal comment failure.
Compilation stops at `VoidType` at 1:12 before the comment.
Both CLI commands exit one, and the measurement exits zero.

### U14 observation history and assertion recovery

The accepted observation design keeps failure, selected diagnostics, and presentation history separate.
`AdmissionObservationHistory` owns an allocator and one unmanaged list of admission diagnostics.
Its `record` operation deduplicates the complete history by source offset and preserves the first kind at each position.
Its `last` operation derives presentation from the final row; no separate cached last-row field is required.
History allocation failures propagate as native allocation failures.

An ephemeral `AdmissionSink` borrows the collector and an optional observation history.
The sink owns nothing and stores no parser pointer.
The classifier receives that sink by value and emits through it at the existing merged emission points.
Each emitted event records history, then calls the collector's caught, recoverable, or fatal operation.
A duplicate history position still reaches the collector, which retains its generation and selection rules.
Collector-only calls pass null history explicitly.

The parser's one-off producers use the same sink.
Raw scanners do not preload caught arrays into history before classification.
Compile caught rows can enter history without changing collector generation, selected diagnostics, or publication health.
Only unconfirmed speculation can restore a history length checkpoint.
An owner nonmatch cannot remove a diagnostic already committed by legacy generic scanning.

Committed tokenizer observation uses an allocation-free observed-token entry that shares the existing trivia scanner.
Plain token requests and speculative lookahead retain their current behavior.
A pending unfinished-comment observation is read-ahead evidence until the admission parser reaches its committed boundary.
An earlier hard refusal can therefore stop compile mode before that pending comment becomes terminal.
Initial EOF still observes a leading unfinished comment before root publication.

A terminal comment inside a type interrupts the endpoint before removed-form detection.
The producer runs only its owning any and caught prefix before selecting the terminal failure.
Assertion recovery catches semantic endpoint outcomes and retains its prior assertion refusal.
Scanner and observation allocation failures propagate as native OOM.
It uses the separate assertion delimiter preset and any-only classification.
That preset stops at `; , ) ] }`, keeps object braces, and does not impose an outer-arrow stop.

Four assertion controls remain in `u14-assertion-endpoint-baseline/all.jsonl` after a one-case pilot.
Both measurement commands exit zero; every CHECK and compile command exits one.

| Source shape | CHECK diagnostics | Compile result |
|---|---|---|
| `as number` before an unfinished comment | Only ZTS042 at 1:16. | `UnsupportedAsAssertion` at 1:16. |
| `void` annotation interrupted by an unfinished comment | No rows. | `UnterminatedComment`, without `VoidType`. |
| `as number \| void` | Only ZTS042 at 1:16. | `UnsupportedAsAssertion` at 1:16. |
| `as number \| any` before an unfinished comment | ZTS042 at 1:16, then ZTS041 at 1:25. | `UnsupportedAsAssertion` at 1:16. |

Bounded history tests cover A/B/A deduplication, merged emission order, compile generation neutrality, and history allocation failure.
The tokenizer observation remains allocation-free even though history can allocate.

Terminal semantic admission failures project zero or one diagnostic from the final retained observation.
Successful recovered admission exposes the complete selected diagnostic list.
The returned failure remains independent of that presentation row.
For example, replayed fatal A can select failure A while retained history A/B supplies presentation B.
Unsupported source extensions keep their separate mapping, and native OOM retains priority.

### U14 first helper review

The first shared-helper draft remains outside the repository and receives no execution claim.
Main rejects its extra public depth limit, incorrect caught-frame advance, and changed return-type delimiters.
The draft also duplicates the existing quote scanner instead of sharing its core.
Its missing bounded tests prevent integration.
Sol corrects the helper before main starts dependent parser integration.

### U14 tokenizer and observation review

Astra accepts the allocation-free tokenizer observation amendment after source review.
Plain token requests retain the legacy cursor behavior for an unfinished comment.
Observed requests return synthetic EOF and report the actual failure cursor.
The amendment adds no stored tokenizer state, so existing saved state remains complete.
Parser integration still owns commitment of read-ahead evidence.

The first observation helper draft remains outside the repository after two review findings.
Its comment endpoint reports the source length instead of the actual legacy failure cursor.
Its interface-body control lacks the full interface context and therefore tests an object type instead.
Sol corrects both findings before integration.

The corrected helper uses the scanner's actual cursor, including the bare `/*` boundary case.
Its interface control includes the full declaration and starts at the actual extends boundary.
Its fatal replay control keeps failure selection independent of retained presentation history.
Astra accepts those corrections, and main integrates the exact reviewed source.
The helper source SHA-256 is `0157802224c049e783f04760c200383ff6e8b86b64fa8b574a9e931e73e1535a`.

The tokenizer observation gate passes all sixteen steps, with 2,740 tests passed and one skipped.
This receipt covers ordinary token compatibility, observed terminal trivia, and layering.
Production CHECK still uses the legacy frontend at this point.

The first helper gate exits one because a test capture shadows an outer constant.
Only the base and contracts roots execute, with 94 tests passed; dependent roots do not compile.
Main renames that capture to `bare_comment` and restarts the same unfiltered gate.
This correction changes no production behavior.

### U14 admission result boundary

The dedicated parser operation returns a tagged outcome for accepted parsing, recovered admission refusal, parser refusal, or terminal admission failure.
Operational failures and internal errors propagate through its native error union.
The owner switches on the outcome instead of inferring a failure from diagnostic presence.

`AdmissionFailure` retains either the selected diagnostic with its exact span or the unfinished-comment payload with its exact cursor.
The presentation history remains independent of that failure.
A hard compile-mode stop retains its diagnostic identity even when the event uses recoverable recording.
That early stop is a propagated semantic failure, not successful recovery.

Parser refusal retains the saved first failed dispatch and its diagnostic prefix.
Unknown admission helper errors bypass the legacy fallback that creates a generic statement diagnostic.
Ordinary parser initialization and private typed initialization retain their existing behavior.

The corrected observation helper gate passes all sixteen steps, with 2,746 tests passed and one skipped.
Formatting and whitespace checks pass for all three parser files.
The final helper source SHA-256 is `c842dd8871aba5c12643c6bec928a783d729cffccb1b0c177de3cf62c96e27d2`.
No production CHECK caller has switched yet.

### U15 compilation API refresh

Sol refreshes the compilation caller census while U14 remains in progress.
Main reads the complete refreshed packet and the exact source at each changed boundary.
Precompile and graph compilation already own parsers with caller-owned shared atoms.
Those callers need direct compile admission without another owner or parser wrapper.
Only the runtime compatibility parser requires separate parsing and delayed code generation.
The CHECK owner retains its existing API and atom ownership.

Caller order differs and must remain explicit.
Precompile validates virtual imports and detects file imports before optimization.
Graph compilation reparses execution order with the existing shared atom prefix.
Source-authority extraction instead optimizes before detecting file imports.
The refreshed packet must retain each actual order, including graph branches.

Native compilation failures must retain existing preparation error names.
The parser's generic `AdmissionRefused` mapping alone does not establish that compatibility.
The compilation packet needs an exhaustive shared projection from admission failure to the existing preparation error set.
Concrete runtime state errors and this projection remain under Main and Astra review before implementation release.
No U15 production file changes during this preparation.

The final quote-wrapper gate exits zero in `u14-quoted-region-comptime.log`.
All sixteen steps succeed; 2,770 tests pass and one skips.
The derived-capacity probe now observes the required post-caught allocation failure and exact rollback.
The production wrapper and all three focused tests pass with the existing parser suites.
Main also confirms that the final owner test source retains the accepted owner production block exactly.

### U14 final header correction

Main reads all source changes in the first header recovery draft.
Astra and Main identify four defects before integration.
The draft bypasses the parameter endpoint after a rejected pattern.
The draft omits optional markers and repeated default markers during raw recovery.
The draft excludes the enclosing parenthesis from its nesting count.
The draft can change error mapping for non-admission parsers.

Eight immutable controls run after a one-case pilot.
Both scripts exit zero; all eight CHECK operations exit one.
The complete sources and responses remain in `u14-header-recovery-detail-baseline/` outside the repository.

| Control | CHECK diagnostics in order |
| --- | --- |
| Pattern with a default, then `any` | ZTS054 at 1:18, ZTS041 at 1:27 |
| Pattern with `any`, a default, then `any` | ZTS041 at 1:19, ZTS054 at 1:23, ZTS041 at 1:32 |
| Pattern type begins with a comment | Only ZTS041 at 1:42 for the later parameter |
| Pattern type contains a generic comma | Only ZTS041 at 1:43 for the later parameter |
| Pattern type contains a quoted LF | ZTS008 at 1:24, ZTS041 at 2:6 |
| Default tail contains an arrow | ZTS054 at 1:14, ZTS054 at 1:18, ZTS041 at 1:27 |
| Default tail contains equality | ZTS054 at 1:14, ZTS054 at 1:18, ZTS054 at 1:19, ZTS041 at 1:27 |
| Rejected pattern has an optional marker | ZTS055 at 1:17, ZTS041 at 1:31 |

The legacy raw header records every top-level equals byte, including arrow and equality bytes.
That rule differs from the parameter type endpoint and remains explicit.
Main replaces the duplicate type scan with the accepted parameter endpoint and classifier.
The raw synchronizer retains only runtime delimiter and marker handling.
Its nesting sum includes the enclosing parameter parenthesis.
Non-admission parsers return their original errors before admission-specific handling.
Astra accepts this corrected production source before integration.
Its temporary source SHA-256 is `2d791eb04f6a98969e241c11d1480852fbd8a11c53cf9b23f71fb93fcdb858f1`.

The two Sol workers reach their usage limit during preparation.
Main takes ownership of their remaining temporary source, tests, and measurement work.
Astra remains the independent validator.
The user directs Main to continue.

The first attempt to extend public characterization fails in its temporary Ruby generator before any source write.
The shell then runs the unchanged suite, which passes all 245 tests.
That run supplies no evidence for the missing extension.
Main corrects the generator to use the installed Ruby version.
The actual extension passes all four steps and all 245 tests in `u14-header-detail-characterization-v2.log`.

Three nested-block controls run after a separate one-case pilot.
The first preserves the pattern refusal at 1:43 and the later while refusal at 1:64.
The comment variant preserves the pattern refusal at 1:43 and the later while refusal at 1:82.
The later-any variant selects only ZTS041 at 1:77.
Both scripts exit zero; all three CHECK operations exit one.
These controls distinguish local header recovery from an incorrect file-wide error cutoff.

Main retains the earlier parser tests and corrects their remaining witnesses.
The binding allocation test checks retained function scopes, including scopes already popped after failure.
A failure after successful binding creation cannot satisfy the missing-binding witness.
Each binding category must observe a qualifying native allocation failure.
The five retired module fixtures use the existing shared module constant.
The additional header tests check exact ordered diagnostics, compile stopping, depth boundaries, nested errors, and Store rollback.
The temporary parser with tests has SHA-256 `d2c44dfd49db4c50d50fcfbd962fd730aaa0f27b7c8f15a58cd6846c9e32bbf2`.
Its source review and unfiltered execution remain separate acceptance steps.

### U15 measured graph preparation failures

Main reviews the complete temporary graph probe before compilation.
The probe calls the existing `ModuleGraph` and `ModuleCompiler` APIs with owned fixture sources.
A one-case pilot and seven-case run use the same binary and change only the case limit.
Compilation, both runs, and the allocator leak check succeed.
Receipts remain in `u15-module-comment-probe/` outside the repository.

| Existing graph source | Reads and compilation |
| --- | --- |
| Entry import, unfinished trailing comment, final LF | One dependency read; two modules compile with bytecode lengths five and seven. |
| Dependency export, unfinished trailing comment, final LF | One dependency read; two modules compile with bytecode lengths five and thirteen. |
| Closed-comment control with final LF | One dependency read; two modules compile with bytecode lengths five and seven. |
| Bare unfinished comment with LF | No read; one module compiles to one byte. |
| Entry import and unfinished comment without LF | No dependency read; compilation returns `MissingSemicolon`. |
| Dependency export and unfinished comment without LF | One dependency read; compilation returns `MissingSemicolon`. |
| Bare unfinished comment without LF | No read; one module compiles to one byte. |

These measurements confirm that graph preparation failure selects raw source for the complete module.
A direct graph policy must preserve that selection before ordered compilation and shared atom allocation.
Ignoring only the trailing comment does not preserve earlier unstripped annotations.
The refreshed packet's unconditional admission refusal is therefore incomplete.
Astra prepares a bounded graph profile design before U15 implementation release.
Graph discovery also distinguishes initializer allocation failure from errors returned by parsing.
The current initializer propagates allocation failure; the current discovery parse suppresses returned failures.
The replacement must not describe universal allocation propagation as unchanged behavior.

Astra accepts one optional runtime parser phase instead of independent mode and phase fields.
Null selects the existing raw mode; typed phases are ready, attempted, and IR-ready.
Each fallible typed operation consumes its entry phase before work starts.
Existing code-generation outputs identify successful generation.
`InvalidParserPhase` remains the only new state error.
No U15 implementation starts before U14 completes and the graph design receives acceptance.

The final nested-block characterization passes all four steps and all 245 tests in `u14-header-nested-characterization.log`.
The complete public recovery table contains forty controls.
These results precede the production parser cutover.

Main extends the graph probe with two whole-source contrasts.
The new one-case pilot and nine-case run use one binary and change only the case limit.
Compilation, both runs, and the leak check exit zero.
Receipts remain in `u15-module-comment-probe-v2/` outside the repository.

An exported typed variable before an unfinished comment with LF selects raw source for the dependency.
The graph reads the dependency once and retains two modules in dependency-first order.
Compilation returns `MissingSemicolon`; the parser reports the absent initializer at 1:19.
The earlier annotation therefore cannot remain erased after preparation fails.

A compile-caught quoted annotation instead retains successful preparation.
The graph reads the dependency once and compiles both modules with bytecode lengths eleven and thirteen.
This control distinguishes caught observations from a preparation failure.
Neither measurement claims complete bytecode parity; the implementation tests must compare the complete outputs independently.

Astra identifies two stale parser test expectations before integration.
The malformed named generic quote produces terminal `UnterminatedString`, including the seeded allocation sweep.
The rejected call remains a recovered admission refusal.
Main corrects both expectations and adds explicit floors for the eight-case and two-case tables.
Astra accepts the exact correction before integration.
The final parser source with tests has SHA-256 `774ec470a6ca6d5469bebab5eb71707f6876f8ca63d5b5c199ee120595702205`.

Main integrates that exact source and exports the two admission result types from the parser root.
Formatting and whitespace checks pass before execution.
The unfiltered parser and layering gate runs as `u14-parser-integrated-v9.log`.
Production CHECK still uses the legacy frontend during this parser gate.

The first integrated parser gate exits one before behavior tests can run in three roots.
Nine of sixteen steps succeed and all 94 executed tests pass.
The compiler reports constant bindings, two conditional assignment arms, a discarded capture, and a missing test qualifier.
The compiler also rejects direct coercion from `!noreturn` into other error-union payloads.
Main unwraps those nine calls with `try` before their outer returns.
Native allocation errors and admission errors retain their existing propagation.

One temporary text replacement also changes already-qualified test names and fails formatting immediately.
Main reconstructs the exact preceding source and applies a narrower replacement before restarting the gate.
Existing tests retain their previous qualified names.
Astra accepts the complete mechanical correction.
The corrected parser SHA-256 is `4fc9dd00d66222e88896c8c90099f23275471f95d361936108b90f89aff9901b`.
The same unfiltered gate runs as `u14-parser-compile-corrected.log`.

That gate exits one after all roots execute.
Fourteen of sixteen steps succeed; 2,792 tests pass, one skips, and two new tests fail.
The first failure distinguishes a physical source offset from a legacy display column.
The later parameter's `any` starts at byte 39, while legacy CHECK reports column 42.
The parameter scanner rewinds its source position without restoring coordinates when a colon has no recognized type start.
Main keeps the original span at byte 39 and retains column 42 in the public characterization.
The direct frontend needs a separate compatibility rule for presentation.

The other failing test places a comment after the function name.
The intended generic path instead examines the comment between the function keyword and name.
Main corrects that fixture to match the intended producer.
An immutable one-case pilot and two-case run confirm the corrected producer.
At combined depth overflow, CHECK reports only ZTS044 at 1:533.
The adjacent limit control reaches the later quote and reports only ZTS008 at 1:1054.
Both scripts exit zero; both CHECK operations exit one.
The complete sources and results remain in `u14-generic-scanner-order-baseline/` outside the repository.

The test-only corrections retain production behavior and public expected output.
The parser source SHA-256 becomes `ed08897a0c8e24b7772d30601f3af5e56e4f2e4d6ef10e0a834da6df07870961`.
The unfiltered gate runs as `u14-parser-fixtures-corrected.log`.

### U14 parameter presentation compatibility

Five additional immutable controls run after a one-case pilot.
The scripts exit zero and every CHECK operation exits one.
The complete sources and responses remain in `u14-header-coordinate-baseline/` outside the repository.

| Parameter control | Exact CHECK selection |
| --- | --- |
| Ordinary parameter with an unrecognized comment type, then `any` | Only ZTS041 at 1:38 |
| Rejected pattern, colon LF and comment, then `any` | Only ZTS041 at 3:1 |
| Rejected pattern with a comment type, then `void` | Only ZTS060 at physical position 1:40 |
| Rejected pattern, colon LF and comment, another LF, then `any` | Only ZTS041 at 4:1 |
| Ordinary parameter with a comment type, then a default | Only ZTS054 at 1:37 |

Astra confirms that the parameter colon nonmatch restores position but not line or column.
The variable colon guard restores all three values.
Return guards keep the consumed source and coordinates.
Those producers must not acquire the parameter rewind rule.
A constant column adjustment cannot preserve LF cases.
Removed-type diagnostics calculate their positions directly and must bypass cursor drift.

Ordinary parameter nonmatches also need local recovery to the later parameter.
The current draft can fail at the declined colon before it reaches the later `any`.
The bounded correction must retain the original expected-parenthesis failure when no admission diagnostic survives.
Original spans and legacy presentation remain separate concepts.
Astra prepares the minimum producer-local representation before implementation.

The corrected parser gate exits zero in `u14-parser-fixtures-corrected.log`.
All sixteen steps succeed; 2,794 tests pass and one skips.
This result establishes original-span behavior and the accepted recovery rules.
The separate public presentation amendment remains necessary before CHECK cutover.

Main integrates the exact reviewed direct owner and bridge with their final tests.
The accepted source retains the compile-history assertion and calibrated validation allocation control.
Formatting and whitespace checks pass before execution.
The owner gate runs unfiltered parser, module-boundary, and layering steps as `u14-direct-owner-integrated.log`.
Production CHECK still uses the legacy frontend during this gate.

Astra accepts the direct owner design subject to the final tagged parser API.
Failed owner initialization leaves no valid owner for accessors or cleanup.
Allocation tests must assert failed initialization and publication without inspecting cleaned storage.
Validation allocation calibration uses the same parser profile and allocator setup.
The owner handles the parser outcomes with an exhaustive switch, not diagnostic-presence precedence.

Source review finds no producer for the new endpoint tags `malformed` and `implementation_budget` after the comment outcome becomes explicit.
Astra accepts deletion of those two impossible tags.
Main removes them from `AdmissionEndpointResult` while preserving every private endpoint and quote union.
The next parser integration gate covers this bounded API deletion.

Final program rejection can occur without a failed top-level dispatch.
For example, block recovery can retain parser errors while the enclosing function dispatch succeeds.
The final `ParseError` then exposes the full applicable error list without creating a fictitious earlier cutoff.
Only an actual failed top-level dispatch establishes the saved diagnostic prefix.

### U14 first parser integration review

The first production parser draft remains outside the repository after main reads every changed line.
Its optional-marker guard requires a nonempty gap and therefore misses adjacent `name?: T`.
Legacy recognition permits an empty whitespace gap before the colon.

Its interface body uses ordinary declaration classification and propagates unfinished comments.
That policy exposes body `any` and comment failures that legacy interface recognition keeps opaque.
The measured body controls retain only ZTS049.

Its annotation hooks classify a compatible span, then call unchanged private parsers that rescan strict endpoints.
That second scan violates the accepted confirmed-span boundary and the measured caught-literal compile behavior.
The direct producer must retain the confirmed span and use admitted type parsing.

Main's initial module-continuation claim is incorrect.
Retired imports terminate stripping in both modes because the legacy producer returns `LegacyTypesImport` unconditionally.
The measured continuation concerns caught lexical diagnostics inside module scans, not a retired-import refusal.
The direct producer must retain that caught continuation and record retired imports as terminal failures.
The draft's result selection places the module field before the explicit terminal failure and therefore loses the terminal result category.

Main requests a bounded correction design before another parser rewrite.
No parser production draft receives an execution claim or enters production CHECK at this point.

### U14 public allocation projection

Astra distinguishes native owner allocation failure from the existing public CHECK projection.
The parser and direct owner propagate native OOM and complete cleanup.
The current CHECK preparation boundary maps that failure to a strip-only result with one parse error.
The reset preserves that public projection.
Later-stage allocation failures retain their existing boundaries instead of entering a new catch-all.

### U14 complete parser review findings

Astra confirms further blockers in the frozen parser draft.
These findings remain design requirements; no rejected parser source enters the repository.

| Boundary | Observed draft failure | Required behavior |
|---|---|---|
| Private nominal exclusion | Recovery also runs when admission is absent and can erase invalid nominal syntax. | New recovery applies only to the admission initializer. |
| Declaration rollback | History allocation can fail after declaration publication without restoring its Store checkpoint. | Every operational failure restores all seventeen Store arrays. |
| Generic scanning | Private wrappers retain only null or suppression state and lose lexical failure identity. | Admission wrappers share the scanner cores and retain actual observations and propagated failures. |
| Compatibility calls | Removed-form classification precedes the legacy call-grammar decision. | Rejected call grammar produces no new removed-form refusal. |
| Compile stopping | A selected hard event can still scan later types or bodies. | Each producer stops immediately before later work can replace the selected failure. |
| Pending trivia | Read-ahead comment evidence immediately changes publication health. | Cursor state retains pending evidence separately until control reaches that boundary. |
| Raw cursor adoption | Plain token requests can lose a trailing unfinished comment. | Committed adoption fetches the surviving token through the observed entry. |
| Internal errors | Generic statement recovery can convert unknown helper errors into syntax diagnostics. | Explicit error routing propagates operational and internal failures before diagnostic selection. |
| Declaration gaps | Token cursors skip comments that legacy raw recognition does not permit. | Raw whitespace guards establish each recognition boundary. |
| Missing equals | Unconditional alias scanning can treat trailing text as a type body. | Body scanning begins only after an actual equals token. |
| Nominal order | Scalar exclusion omits prior generic and body classification. | Generic removed forms precede body `any`, then scalar refusal, with existing deduplication. |
| Validation ownership | Parser and direct owner both call final runtime-owner validation. | The direct owner validates once before accepted publication. |
| Block recovery progress | A post-failure progress snapshot can skip a later eligible declaration after template recovery. | Admission recovery checks progress against the failed statement's original start. |

The current global module refusal and exclusion fields also need an admission-aware publication policy.
An earlier observation must not poison a later independent valid producer.
Caught compile observations must not become private lexical exclusions or alter selected generation.
Plain and private typed initialization retain their existing policy.

### U14 interface body measurements

The immutable program runs one case first, then three cases, in `u14-interface-body-baseline/`.
Both measurement commands exit zero; all six CHECK and compile commands exit one.

| Body control | CHECK result | Compile result |
|---|---|---|
| Malformed quoted string | ZTS008 at 1:31, then ZTS049 at 1:1. | `InterfaceDeclaration` at 1:1. |
| 512 additional raw braces | Only ZTS044 at 1:529. | `NestingTooDeep` at 1:529. |
| Comment text contains a closing brace | ZTS049 at 1:1, then ZTS041 at 1:36 outside the ended body. | `InterfaceDeclaration` at 1:1. |

Legacy body scanning catches quoted-string failures but propagates raw brace overflow.
It does not recognize comments; braces inside comment text still affect the endpoint.
It does not classify body `any` or create an unfinished-comment failure.

### U14 declaration guard measurements

The immutable program runs one case first, then five cases, in `u14-declaration-guard-baseline/`.
Both measurement commands exit zero; all ten CHECK and compile commands exit one.
Comment gaps after `type`, `distinct`, or `interface` retain only parser ZTS047 at 1:1.
A comment gap after `export` retains only parser ZTS002 at 1:1.
`type Alias any;` retains only ZTS050 at 1:1 because no equals token starts a body.
These controls establish recognition limits instead of treating skipped trivia as raw whitespace.

### U14 declaration recovery measurements

The immutable program runs one case first, then three cases, in `u14-var-admission-baseline/`.
Both measurement commands exit zero; all six CHECK and compile commands exit one.
`var x: any = 1;` retains only ZTS041 at 1:8 before runtime rejection can win.
`var x: number = 1;` retains only parser ZTS001 at 1:1.
A plain `var` followed by a later typed `const` retains only ZTS041 at 1:21.
Admission recovery must retain the already owned declaration's type span without adding a whole-program scanner.

### U14 CHECK characterization execution

Astra accepts characterization v3 after the handler-free stage correction and the compatible public allocation assertion.
Main integrates the test-only source and runs unfiltered `test-precompile` against unchanged production CHECK.
The first run exits one: 241 tests pass, and one routing expectation fails.
Its untyped named handler reaches strict checking and lacks the required explicit signature.
Main corrects only that expectation: six stages for TypeScript, five for virtual JavaScript, and one ZTS601 error.
The corrected routing test requires no verifier execution and no contract.
The template control and existing typed contract fixtures retain complete contract coverage.
Main restarts the same unfiltered gate after the test correction.

The rerun passes all four steps and all 242 precompile tests.
Astra accepts the corrected routing assertions after checking the strict signature requirement.
The final precompile source SHA-256 is `b24d812aa962743f8b62f4e047bcf6bb403b27c7d29284234cc387297d233270`.
Formatting and whitespace checks pass for the touched parser and precompile files.
This receipt still tests the unchanged legacy production CHECK path.

The parser correction design permits two separate temporary scopes after Astra review.
One Sol agent owns admitted-span semantic helpers and later generic scanner observation helpers.
The other Sol agent owns parser integration and producer recovery.
Each corrected source amendment still requires independent review and its bounded gate before dependent integration.

The admitted semantic helper API uses one `AdmittedTypeInput` with a raw span and its admission endpoint.
The helpers read `Store.source`, validate bounds, and share existing annotation, return, and declaration construction.
They do not repeat strict endpoint discovery.
Native failures and excluded outcomes restore all seventeen Store arrays.
Declaration cursor publication occurs only after complete success.
The return helper preserves the complete untrimmed interval and rejects a shorter raw span.

The existing declaration generic scan remains a temporary limitation until the observation-aware core amendment completes.
Generic observations retain each legacy caller's catch policy and commitment boundary.
A failed call probe can retain observations from that actual probe even when its cursor restores.
An unrelated balanced probe cannot publish observations from work the legacy caller never performs.
Removed-form classification still requires the applicable call-grammar acceptance.

All eight interim documentation drift, link, and spine checks pass after the recorded findings and test corrections.

### U14 confirmed-span source review

Main reads every production and test line of the admitted-span helper amendment.
Astra accepts production v2 and all eleven tests before integration.
The tests cover bounds, caught literal prefixes, full return spelling, declaration publication, exclusions, and native allocation rollback.
The seeded allocation test confirms published nodes and annotations before it enables the failing allocator.
Main integrates source SHA-256 `62100782aef25959392a7e763e90eee62676d5342b072206200bafdd3ff42ead` and starts the unfiltered behavior and layering gate.
Strict TypeValue assembly still has its existing implementation; the source shares annotation, return, and declaration construction where stated.
No claim of complete shared semantic assembly replaces that measured source boundary.

The generic observation packet also receives main review and Astra acceptance before temporary implementation.
Its matching-bracket core supplies the interface body entry without a duplicate scanner loop.
The production parser remains outside the repository until every required helper and corrected producer passes review.

### U14 additional var owner controls

The immutable program runs one case first, then four cases, in `u14-var-owner-boundary-baseline/`.
Both measurement commands exit zero; all eight CHECK and compile commands exit one.
Comment gaps after `var` or after its binding name retain ZTS041 at 1:19.
Those gaps therefore differ from the raw whitespace requirements for type declaration keywords.
`var a = 1, b: any = 2;` retains only parser ZTS001 at 1:1.
The reset does not add a declaration-list grammar to change that result.
`var x = value as any;` retains only ZTS042 at 1:18.
Recovery reaches the existing assertion producer, and same-offset deduplication retains that assertion diagnostic.

### U14 generic-specific measurements

The immutable program runs one case first, then seven cases, in `u14-generic-observation-baseline/`.
Both measurement commands exit zero.
Every CHECK command exits one; compilation exits zero only for the two maximum-depth controls.

| Control | CHECK result | Compile result |
|---|---|---|
| Named generic with quoted LF before nonmatch | Only ZTS008 at 1:17. | `UnterminatedString` at 1:17. |
| Call probe with caught LF before a logical operator | Only ZTS008 at 1:26. | Stripping succeeds; parser ZTS001 occurs at 1:17. |
| Named raw angle overflow | Only ZTS044 at 1:523. | `NestingTooDeep` at 1:523. |
| Named angle maximum | Only ZTS500 at 1:1. | Exit zero, with seven bytes of bytecode. |
| Named raw bracket overflow | Only ZTS044 at 1:524. | `NestingTooDeep` at 1:524. |
| Named bracket maximum | Only ZTS500 at 1:1. | Exit zero, with seven bytes of bytecode. |
| Unfinished comment in named generic | No diagnostic rows. | `UnterminatedComment`. |

The quote controls distinguish actual probe observations from later committed traversal.
The depth controls distinguish matching-bracket counters from combined counters in call grammar.
Return-type depth receipts alone do not establish these generic outcomes.

The first admitted-helper gate exits one because a test combines compile-time iteration with runtime continuation.
Thirteen of sixteen steps succeed, with 1,660 tests passed; the engine test root does not compile.
Main changes only that test loop to ordinary runtime iteration and restarts the same unfiltered gate.

Main and Astra review every line of the generic scanner production draft.
The draft preserves valid-input private behavior, quote recovery, caught-row transactions, and shared interface brace scanning.
Its two private wrappers need their original out-of-range guards before the stricter new cores.
Sol corrects that bounded compatibility issue before integration.
Admission entries keep native validation errors for invalid source positions.

### U14 final capture amendments

Astra accepts a confirmed `generic_list: ?Span` input for admitted declarations.
The helper validates header presence, exact start, bounds, and angle spelling before generic reservation.
It resumes its copied cursor at the confirmed endpoint without tokenizing the opaque list.
The strict declaration path retains its existing scanner and eligibility policy.
No suppression flag moves into the stored declaration input; the parser owns admission selection.

Type-only module validation remains structural rather than a second admission decision.
A matching recovered module record can retain caught lexical observations.
The amendment removes only the `encountered_diagnostic` rejection.
It retains retired refusal, exact record equality, and native allocation failure propagation.
Private typed initialization still rejects lexical exclusions through its existing parser policy.
Neither amendment adds a Store array or a frontend mode field.

Pending trivia also retains operational error priority.
Statement recovery propagates its caught native or internal error before committing later read-ahead trivia.
Every observed token fetch replaces pending evidence, including clearing an earlier staged observation.
Raw survivor adoption stages evidence until the enclosing producer finishes publication.
These conditions keep a later comment from replacing OOM or invalidating an earlier valid producer prematurely.

The corrected admitted-span helper gate passes all sixteen steps, with 2,757 tests passed and one skipped.
Its final source SHA-256 is `34d0725116f46cfa4ab6407a9db255ea833fdb157b3073bb88f91bd4f82e88cc`.
This receipt covers the eleven new helper tests and unchanged tier behavior.
The production parser and CHECK caller cutover remain pending.

Astra accepts scanner tests v3 after the missing outcome contrasts and allocation floors are added.
Balanced, call, and brace scans now require observed allocation failures and restore prior caught rows.
The root-template control distinguishes a caught depth failure from terminal raw depth failure.
The call controls distinguish lexical nonmatch, grammar nonmatch, and terminal combined depth.
The tests exercise public scanner entries; private-wrapper controls retain their separate exclusion policy.

Main integrates frozen scanner source `4cbf6e5ecaef504403345cb8936ac2f151e28d79b7a5e124a27fb30ab011c74f` after complete line review.
The first unfiltered gate fails compilation at three rollback statements.
Main adds braces around each conditional `errdefer` without changing rollback behavior.
The same unfiltered behavior and layering gate runs again.

| Scanner receipt | Actual result and scope |
| --- | --- |
| `u14-generic-observation-v3.log` | Exit 1; nine of sixteen steps succeed, and 94 tests pass. Three syntax errors prevent the parser roots from compiling. |
| `u14-generic-observation-braces.log` | Exit 0; all sixteen steps succeed, 2,762 tests pass, and one skips. The corrected scanner and layering checks pass. |

The integrated scanner source SHA-256 is `826ae9fb64951f4df914e2a05a3ca275c5f747221c6eb7b114e16d5d7e022efd`.
Main reads the complete declaration capture production amendment before test review.
The amendment retains the strict scanner path and validates confirmed generic spans before reservation.

Astra clarifies the public CHECK allocation boundary for the direct owner.
CHECK catches only `error.OutOfMemory` from `DirectCheckSource.initInPlace` and returns the existing strip-only failure with one parse error.
The direct owner still returns native errors and cleans every failed initialization.
CHECK propagates internal errors and handles semantic refusals through the tagged outcomes.
Later analysis retains its existing allocation boundaries.
The preparation boundary now includes parser and final validation allocations because the owner performs those operations during initialization.
The existing characterization does not establish allocation-site parity with the earlier parser boundary.
Calibrated owner failures need separate CHECK projection controls before cutover acceptance.

The declaration capture review finds another raw cursor boundary in the admitted body path.
The tokenizer can scan across a caught string newline and consume the declaration terminator.
A later `advanceCursorTo` call cannot restore a cursor that already passed the confirmed endpoint.
The admitted body therefore resumes a tokenizer copy directly at `admission_end` after the equals token.
The strict body path retains its existing token walk.
Exact quoted-body and template-body cursor controls must cover the terminator, line state, and rollback before acceptance.

Astra finds two imported-file requirements during CHECK packet review.
Legacy dependency preparation uses compile admission, while CHECK root preparation uses collect admission.
The direct owner therefore needs explicit operation initializers over one initialization core.
Imported files retain caught compile observations without retry or a second frontend.
Healthy imported effects must receive `type_source = .direct` with the direct environment.
Failed imported typing must receive `.omitted`.
Passing a direct environment through the old `type_env` field invokes legacy normalization and can leave a valid imported effect blocked.
The existing separate traversal and failed-type early-stop requirements remain unchanged.

Astra accepts declaration capture production v2 after the raw body resumption correction.
Tests remain a separate acceptance boundary before integration.
Astra also accepts the tools-local admission JSON adapter.
The adapter maps all seventeen kinds exhaustively through the existing catalog.
It preserves LF-only byte coordinates, the column clamp, static text ownership, and absent offset fields.
Main integrates that adapter and starts unfiltered `test-precompile` before any CHECK caller changes.

The human output boundary uses projected diagnostics and the exact terminal error identity.
The existing human failure summary and test-mode suppression remain required.
The authority does not require byte-identical incidental producer logging or duplicate `std.log` events.
No logging provenance mechanism will be added for that history.
A location-free failure can have no JSON diagnostic while human output retains its terminal error name.
This evidence limit does not establish complete stderr parity.

| JSON adapter receipt | Actual result and scope |
| --- | --- |
| `u14-admission-json.log` | Exit 0; all four steps and all 244 precompile tests pass before CHECK production changes. |

Astra accepts declaration test source v3 after exact endpoint assertions are added.
The tests distinguish a quoted body's LF admission endpoint from its later semicolon terminator.
They assert survivor byte positions, lines, columns, declaration spans, generic backlinks, strict exclusions, and seeded allocation rollback.
Main integrates source SHA-256 `a08370c72707c67934253fd79c041589825c0d0402ded83a34292915961d99ee` after complete line review.
The unfiltered parser and layering gate runs as `u14-declaration-capture-v3.log`.

| Declaration capture receipt | Actual result and scope |
| --- | --- |
| `u14-declaration-capture-v3.log` | Exit 0; all sixteen steps succeed, 2,766 tests pass, and one skips. Exact capture, rollback, strict contrast, and layering checks pass. |

Astra accepts the separate recovered-module source amendment and tests.
The amendment removes only the rejection of a structurally matching record with caught diagnostics.
The tests retain exact-record equality, retired refusal, wrong-kind rejection, wrong-endpoint rejection, and native OOM before append.
Main integrates source SHA-256 `d2800ba17072c380fbe7fa07812311f93bbe1f7b726966bf55148702890ec4cf` after complete line review.
The same unfiltered parser and layering gate runs as `u14-recovered-module-validation.log`.

| Recovered module receipt | Actual result and scope |
| --- | --- |
| `u14-recovered-module-validation.log` | Exit 0; all sixteen steps succeed, 2,767 tests pass, and one skips. Structural recovery, refusal, OOM, and layering checks pass. |

### U14 final parser baseline review

Astra finds two further blockers in the frozen parser predecessor before final integration.
Assertion recovery saves its tokenizer after consuming the asserted type's first token.
A malformed quoted type can move that tokenizer beyond the confirmed LF endpoint.
The correction saves the tokenizer immediately after the assertion keyword and resumes that copy.
It retains the existing type-start guard, committed observations, and compile-mode immediate refusal.

The normal variable, parameter, and return call sites also need their legacy raw type-start guards.
The admission path must not erase a colon followed by a comment or an empty type.
Without that guard, classification can expose an `any` that legacy preparation leaves to runtime parser refusal.
The call-site correction applies only when admission is present.
Plain initialization and private typed initialization retain their existing behavior.

Main measures assertion recovery through the immutable legacy analyzer after a one-case pilot.
Both measurement scripts exit zero; all six CHECK and compile operations exit one.
The sources, requests, output, stderr, and process exits remain in `u14-assertion-recovery-baseline/`.

| Assertion control | CHECK diagnostics in order | Compile failure |
| --- | --- | --- |
| Quoted `as` | ZTS042 at 1:20, ZTS008 at 1:25, ZTS041 at 2:16 | `UnsupportedAsAssertion` at 1:20 |
| Quoted `satisfies` | ZTS043 at 1:27, ZTS008 at 1:32, ZTS041 at 2:16 | `UnsupportedSatisfiesAssertion` at 1:27 |
| Template `as` with a caught string | ZTS042 at 1:20, ZTS008 at 1:29, ZTS041 at 2:18 | `UnsupportedAsAssertion` at 1:20 |

Seven further CHECK controls run after a one-case pilot through the same immutable binary.
Both scripts exit zero, and all seven CHECK processes exit one.
The sources and exact responses remain in `u14-type-start-recovery-baseline/`.

| Raw recognition control | CHECK diagnostics |
| --- | --- |
| `while (true) { const x: any = 1; }` | Only ZTS041 at 1:25 |
| Variable colon followed by a closed comment and `any` | ZTS002 at 1:8, then ZTS047 at 1:7 |
| Parameter colon followed by a closed comment and `any` | ZTS003 at 1:13, expected `')'` |
| Return colon followed by a closed comment and `any` | ZTS003 at 1:13, expected `'{'` |
| Variable colon followed by equals | ZTS002 at 1:8, then ZTS047 at 1:7 |
| Parameter colon followed by closing parenthesis | ZTS003 at 1:13, expected `')'` |
| Return colon followed by `{ return 1; }` | ZTS003 at 2:1, expected `'{'` |

The last fixture is an object-shaped return tail, despite its historical `return-empty` filename.
It is not evidence for a raw type-start guard rejecting an empty return type.

Astra identifies a recovery gap inside skipped runtime braces.
The predecessor's depth filter can skip a supported declaration without dispatching its admission producer.
The measured `while` control confirms that its hidden `any` must still take priority over the runtime parser refusal.
The correction must reuse existing producer dispatch and retain the saved first parser batch.
It must not add a second runtime grammar.

Three binding catches also replace `ScopeAnalyzer.declareBinding` OOM with `TooManyLocals`.
An error list with available capacity can then conceal native OOM from `parseAdmission`.
The admission path must propagate captured OOM before recording the legacy local-limit diagnostic.
The ordinary and private typed paths retain their existing mapping.
A calibrated public parser test must establish diagnostic capacity before inducing the binding allocation failure.

Default and mutable export producers need raw statement-boundary and whitespace-only gap guards.
An indented export or a comment between export keywords must retain the runtime parser path when raw recognition fails.
The admission correction uses the existing boundary helpers and leaves other initialization profiles unchanged.

Two immutable export controls confirm that boundary after a one-case pilot.
Both scripts exit zero, and both CHECK operations exit one.
The indented default export reports parser ZTS001 at 1:9.
The mutable export with a comment between keywords reports parser ZTS001 at 1:12.
Exact sources and responses remain in `u14-export-guard-baseline/`.

Import recovery also needs the legacy alias context.
Only committed normal token consumption changes `admission_in_import`.
Consuming `kw_import` sets the flag; consuming a normal semicolon clears the flag.
The flag suppresses `as` assertions but does not suppress `satisfies`.
Raw adoption preserves the flag, including semicolons inside erased type-only modules.
Strings, templates, newlines, and speculative lookahead do not change it.
`ParserCursorCheckpoint` restores the flag when speculation declines.
Astra accepts this bounded context design.

Nested recovery returns at supported restart heads and uses the existing statement dispatch.
Admission block recovery consumes deeper recovery braces before it accepts its own closing brace.
Ordinary and private typed block behavior remains unchanged.
Astra accepts this mechanism without a second grammar or recursion from synchronization into parser dispatch.

Four immutable context controls run after a one-case pilot.
Both scripts exit zero, and all four CHECK processes exit one.
Exact sources and responses remain in `u14-recovery-context-baseline/`.

| Recovery context | CHECK diagnostics |
| --- | --- |
| Refused namespace import | Only ZTS002 at 1:1 |
| Namespace import with semicolon, then assertion | Only ZTS042 at 2:20 |
| Namespace import without semicolon, then assertion | Only ZTS002 at 1:1 |
| Function with unsupported while, healthy typed const, and later return | Only ZTS001 at 2:3 |

### U14 direct owner API binding

Main accepts the exact owner API binding before temporary implementation starts.
The owner reuses `AdmissionParseOutcome` rather than defining another outcome union.
`initInPlace` uses collect admission; `initCompileInPlace` uses compile admission through the same initialization core.
`acceptedCapabilities` returns one borrowed bundle for the root bridge.
The bundle contains the matching root, IR view, atom pointer, and Store pointer from that owner.
This bridge guarantee does not prevent arbitrary field mutation elsewhere in Zig.
The owner stores no duplicate allocator, root, or IR view.
Main supplies the two parser-root aliases after final parser integration.
The public API contract is fixed while the six remaining parser corrections change internal behavior.
Sol prepares the owner outside the repository; source acceptance and execution remain separate requirements.

Astra accepts the exact owner binding and its production logic separately.
The owner cleans parser state before atoms and publishes acceptance after the complete final validation.
Main reads every production line and the later lifetime comment delta.
The lifetime comment records final storage, borrowed bytes, nonmovable initialized owners, and failed-initialization cleanup.
Tests, validation allocation calibration, and final parser integration remain pending.

Main prepares the CHECK root and imported-file cutover outside the repository.
The frozen production v2 patch SHA-256 is `3bde51eda56bc0159d765260dc01895fdae6efbe1a0f13e74467f51d21830d66`.
It retains the existing characterization tests unchanged.
Root CHECK uses collect admission and maps each explicit owner outcome to its existing stage profile.
Only initialization OOM enters the existing failed preparation projection; internal errors propagate.
Virtual JavaScript retains its untyped legacy preparation until its scheduled cutover.
Accepted TypeScript analysis receives the matching direct Store, including when that Store has no entries.
Imported files use compile admission and release facts before the owner and owned source bytes.
Imported type and effect analysis receive direct input explicitly; failed typing retains omitted effects and blocked nested imports.
The patch preserves separate import traversals and reader calls.
Astra reviews this source before any caller integration or execution.

Astra accepts CHECK production v2 as source, including root projection, imported ownership, and direct type and effect input.
The caller patch remains temporary until parser and owner integration pass their gates.

Main adds eleven public CHECK characterization cases after independent Sol review.
The cases retain exact immutable source bytes, diagnostic text, suggestions, order, positions, and stage profiles.
The new cases pass against the unchanged legacy CHECK implementation.

| Further CHECK characterization receipt | Actual result and scope |
| --- | --- |
| `u14-recovery-characterization.log` | Exit 0; all four steps and all 245 precompile tests pass before caller cutover. The eleven added cases exercise recovery and raw guards. |

### U14 frozen parser correction review

Main reads all 731 lines of the final parser production delta and all 599 lines of its test delta.
Astra independently reviews the same immutable patches.
The initial full source snapshots change during worker correction, so Main reconstructs separate review copies from the immutable patches.
The reconstructed production SHA-256 is `9c5b5c840a8dfb8a3b1b230dd8cfcf43454958e9d3b1cb98e445fbf724df648c`.
The reconstructed test SHA-256 is `e25aee20d5a235a57c8fdb47d7c4823fa6df508accadd73562566313a63952a8`.
Later corrections use new versioned paths and retain all prior review targets.
No rejected parser production snapshot enters the repository.

The source review finds additional bounded corrections.
Rejected aliases must retain their refusal when equals is absent; only an actual equals token starts body scanning.
Interfaces must retain their refusal after a recognized name even when the body is absent.
Post-name comments do not cancel an already recognized refusal or create a body assignment.
Present body observations retain their original order before the declaration refusal.
Five new retired-module fixtures must use the existing constant without changing bytes or widening an allowlist.

The generic compatibility paths must choose their actual legacy scanner before committing observations.
A balanced probe can reach a caught quote after the call grammar already exceeds its earlier combined-depth limit.
Committing that probe adds an observation that legacy execution never reaches.
Named comment compatibility and comparison arrows therefore use the call scanner first.
Dedicated assignment arrows retain their earlier precedence.
Other eligible producers use the balanced scanner, and every producer commits only its selected scanner's rows.
Admission cursor adoption resumes at the confirmed endpoint without tokenizing opaque generic contents.
Private scanner and token-walk behavior remains unchanged.
Astra accepts this bounded correction design.

Nominal scalar refusal must preserve its complete erased interval and raw boundary state.
Legacy preparation skips whitespace before an optional semicolon.
Leaving that semicolon visible can create a new adjacent declaration boundary.
The corrected source must update `last_erased_type_span` after the full interval is known.

Three immutable nominal controls run after a one-case pilot.
Both scripts exit zero, and all three CHECK operations exit one.
The exact sources and responses remain in `u14-nominal-erasure-baseline/`.

| Nominal boundary control | CHECK diagnostics |
| --- | --- |
| Refused nominal followed immediately by `type` | Only ZTS048 at 1:15 |
| Refused nominal followed by newline and `type` | ZTS048 at 1:15, then ZTS050 at 2:1 |
| Healthy nominal followed immediately by `type` | Only parser ZTS047 at 1:23 |

The parameter binding OOM witness also needs a retained-scope check.
Function cleanup can pop the current scope after a later node allocation fails.
A lookup from that scope can falsely claim the parameter binding never existed.
The witness must inspect retained function bindings or establish the exact allocation boundary.
Unrelated OOM at the same cursor must not count as binding failure.

### U14 parameter recovery review

Three immutable header controls run after a one-case pilot.
Both scripts exit zero, and all three CHECK operations exit one.
The sources and exact responses remain in `u14-parameter-recovery-baseline/`.

| Header control | CHECK diagnostics in order |
| --- | --- |
| Unsupported function-expression default, then `y: any` | ZTS054 at 1:14, then ZTS041 at 1:35 |
| Unsupported destructured pattern, then `y: any` | Only ZTS041 at 1:22 |
| Ordinary default, then `y: any` | ZTS054 at 1:14, then ZTS041 at 1:22 |

The draft can leave the header after unsupported runtime syntax and miss later admission events.
Recovery stays in the existing header loop and uses a small raw delimiter synchronizer.
It starts at a saved default tail or rejected pattern boundary, with exact consumed delimiter state.
The synchronizer retains the legacy combined-depth rule for parentheses, braces, and brackets.
It has no angle counter, comment skipping, or regular-expression recognition.
It leaves the next comma or outer closing parenthesis for the existing loop.
Before a default, recovery retains top-level annotation dispatch after a rejected pattern.
Shared quote handling preserves propagated root failure and caught nested-template observations.
Compile hard refusal stops before recovery.
Native and internal errors propagate immediately.
The failed header retains its first applicable parser-error batch and committed admission history.
The complete failed header Store transaction rolls back.
The measured controls must establish ordered diagnostics and absence of completed signature and parameter publication.
Astra accepts these constraints; implementation remains a separate source review.

Main reviews all owner tests and the bridge correction for three actual refusal tags.
Astra accepts the refusal bridge and the calibrated validation allocation probe.
The compile-caught literal test still needs an assertion that the first LF remains in observation history.
Its empty public owner projections then establish suppression rather than loss of evidence.

### U14 declaration gaps and quote reuse

Seven immutable controls run after a one-case pilot.
Both measurement scripts exit zero; every CHECK operation exits one.
Complete sources and responses remain in `u14-declaration-gap-baseline/` outside the repository.

| Source condition | Exact CHECK selection |
| --- | --- |
| Comment after alias name, before `= any` | Only ZTS050 at 1:1 |
| Comment after alias generics, before `= any` | Only ZTS050 at 1:1 |
| Interface name followed by a semicolon | Only ZTS049 at 1:1 |
| Comment after interface name, before a semicolon | Only ZTS049 at 1:1 |
| Invalid nominal base, LF, then `;type` | Only ZTS048 at 1:15 |
| Unfinished comment after alias name | Only ZTS050 at 1:1 |
| Unfinished comment after alias generics | Only ZTS050 at 1:1 |

The parser must not classify a hidden declaration body after a comment gap.
The parser must skip raw whitespace before an optional declaration semicolon.
The nominal correction alone does not cover the shared refused-declaration tail.
Astra identifies that separate omission during source review.

Three further controls run after a separate one-case pilot.
An interface body followed by ` ;type` reports only ZTS049 at 1:1.
An alias body followed by LF and `;type` reports only ZTS050 at 1:1.
An interface body followed by ` ;`, LF, then `type` reports ZTS049 at 1:1 and ZTS050 at 2:1.
Both scripts exit zero; every CHECK operation exits one.
The same receipt directory retains these exact sources and responses.

Astra accepts the thin `scanAdmissionQuotedRegion` design over the existing quote core.
The wrapper preserves exact endpoints and completed scans at EOF.
The wrapper retains nested caught observations before a separate root terminal diagnostic.
Native errors restore the caller's caught-list length.
The wrapper adds no Store, cursor, collector, or frame-budget state.
Source review and execution remain separate acceptance steps.

Astra accepts the corrected compile-history owner assertion and the two public CHECK tests as source changes.
Those CHECK tests cover calibrated validation OOM and compile-caught imported effects with three exact reads.
The owner and CHECK production cutovers remain outside the repository pending parser integration.

Five additional nominal controls run after a one-case pilot.
Comments after a nominal name select only ZTS048 at 1:11.
That result also holds when the comment hides `= any` or has no closing delimiter.
A comment after nominal generics selects only ZTS048 at 1:14.
A comment between the nominal keyword and name instead selects parser ZTS047 at 1:1.
The scripts exit zero; every CHECK operation exits one.
The receipt directory retains the exact sources and responses.

The public recovery table now includes all eighteen additional declaration and header controls.
The three successive characterization runs each pass four steps and all 245 precompile tests.
Their receipts are `u14-declaration-gap-characterization.log`, `u14-declaration-tail-characterization.log`, and `u14-header-nominal-characterization.log`.
The original eleven controls remain unchanged.

Astra accepts quote-wrapper production and the corrected allocation test.
The first test draft can fail before a caught observation changes the list.
The corrected test first completes a prefix and proves its caught observation exists.
The same prefix then precedes nested templates that require later frame growth.
A fresh allocator fails at that calibrated allocation boundary and must restore the seeded list exactly.
The complete allocation sweep remains in place.
The integrated source SHA-256 is `fa53461d30b97a3d8db2d29243724fd2ad85619eea5009e5b914ab73d259f6ca`.
The unfiltered parser and layering gate runs as `u14-quoted-region-v2.log`.

Header recovery must not set a file-wide error cutoff inside a nested function.
Legacy block recovery can collect further applicable errors before the top-level statement returns.
Astra rejects that proposed global cutoff before implementation.
The bounded correction keeps the original header failure local and returns it through the existing outer recovery boundary.
The top-level dispatch retains ownership of its saved applicable error batch.

Astra accepts that local header design and rejects panic-mode suppression.
Nested synchronization can clear panic mode, so suppression would require unrelated recovery changes.
Native errors and diagnostic OOM must propagate before local error-list restoration.
Owned diagnostic messages retain their existing cleanup owner.
A nested-block contrast must prove that later applicable block errors remain visible.
Astra also accepts the nominal raw-header design and the shared declaration-tail correction.

The first quote-wrapper execution exits one in `u14-quoted-region-v2.log`.
Fourteen of sixteen steps succeed; 2,769 tests pass, one skips, and one fails.
The production wrapper tests pass except for the calibrated post-caught allocation expectation.
The test uses thirty-two nested frames, which fit the actual initial capacity on this host.
The expected allocation therefore never occurs.
The correction derives nesting from `ArrayListUnmanaged(LegacyTemplateFrame).growCapacity(1)` instead of a guessed count.
The prefix and exact seeded-list restoration assertions remain unchanged.

The next quote test run exits one in `u14-quoted-region-capacity.log`.
Thirteen of sixteen steps succeed and all 1,660 executed tests pass.
The engine root cannot compile because string repetition requires an explicitly compile-time nesting count.
Main adds `comptime` to the growth calculation and repeats the same unfiltered gate.
The complete source SHA-256 is `00b8f339686b2b8f8fe1f8701740063dc46db5a7a09b0efca58c838ba2559754`.
The receipt is `u14-quoted-region-comptime.log`.

Main rebases the accepted CHECK production patch and two accepted tests onto the current characterization source.
The complete recovery table remains byte-identical after that temporary rebase.
The rebased temporary source SHA-256 is `569aade599f827e3b0908beb8c08a8b70fcdbe81856a95cb68083b7dd2efcb80`.
No production CHECK caller has switched yet.

### U14 parameter presentation measurements and direct owner gate

The integrated direct source owner passes the unfiltered owner gate.
`u14-direct-owner-integrated.log` exits 0 across eighteen steps, with 2,800 tests passed and one skipped.
The gate includes ZTS, module boundaries, and ZTS layering.
Production CHECK still uses the legacy frontend.

Main measures six additional controls before changing presentation coordinates.
The exact sources, requests, standard output, standard error, and statuses remain under `u14-presentation-extra-baseline/` outside the repository.
The one-case pilot initially uses an invalid compile command.
That receipt remains as `pilot-invalid-compile-argv.jsonl`; it supplies no compile evidence.
Main corrects the command to `zts compile <source> <output>`.
The corrected one-case pilot and six-case run use the same script, with only the case limit changed.
Both scripts exit 0; all twelve CHECK and compile operations exit 1 with the measured refusals.

| Control | CHECK observation | Compile observation |
|---|---|---|
| Parameter tab before a comment | ZTS041 at 1:38 | UnsupportedAnyType at 1:38 |
| Parameter CR before a comment | ZTS041 at 1:39 | UnsupportedAnyType at 1:39 |
| Two declined parameter guards | ZTS041 at 1:61 | UnsupportedAnyType at 1:61 |
| Declined parameter with number types | ZTS003 at 1:13, expecting `')'` | The same parser diagnostic |
| Declined variable guard across LF | ZTS041 at 2:36 | UnsupportedAnyType at 2:36 |
| Declined return guard across LF | ZTS041 at 2:45 | UnsupportedAnyType at 2:45 |

Astra identifies another committed cursor operation.
`skipWhitespaceTracked` consumes CR without increasing the column.
Ordinary byte processing increases the column for CR.
A parameter rewind adjustment alone cannot preserve successful prefix positions.

Main measures seven corresponding controls under `u14-tracked-prefix-baseline/` outside the repository.
The one-case pilot and seven-case run use the same script, with only the case limit changed.
Both scripts exit 0; all fourteen CHECK and compile operations exit 1 with the measured refusals.

| Control | CHECK observation | Compile observation |
|---|---|---|
| Parameter CR before any | ZTS041 at 1:15 | UnsupportedAnyType at 1:15 |
| Variable CR before any | ZTS041 at 1:10 | UnsupportedAnyType at 1:10 |
| Return CR before any | ZTS041 at 1:15 | UnsupportedAnyType at 1:15 |
| Optional marker followed by CR | ZTS055 at 1:13, then ZTS041 at 1:16 | OptionalParameter at 1:13 |
| Accepted parameter CR before a later any | ZTS041 at 1:26 | UnsupportedAnyType at 1:26 |
| Declined variable CR before a later any | ZTS041 at 1:45 | UnsupportedAnyType at 1:45 |
| Declined return CR before a later any | ZTS041 at 1:58 | UnsupportedAnyType at 1:58 |

The public characterization table now contains fifty-eight exact controls.
The table includes the previous forty controls, five coordinate controls, and these thirteen additional controls.
`u14-presentation-characterization.log` exits 0 across four steps, with all 245 precompile tests passed against legacy CHECK.
The test asserts its fifty-eight-case floor.

Main prepares a bounded presentation amendment outside the repository.
The amendment separates original spans from optional presentation positions.
The amendment deduplicates raw positions before JSON column clamping and recovered CHECK normalization.
Removed-type producers retain physical positions.
Terminal admission payloads retain the finalized presentation position.
Ordinary declined parameter guards retain the existing expected-`)` error and use the existing local header recovery.

The current amendment covers parameter rewinds, annotation prefixes, and accepted optional-marker prefixes.
Astra identifies more tracked prefixes in existing producers.
The remaining census includes function gaps, assertions, declarations, modules, generic continuations, and runtime assignment preludes.
Each prefix requires the corresponding producer's actual commit or restore rule.
The pending amendment does not authorize CHECK cutover before those requirements and the required gates pass.

### U14 presentation amendment: bounded source and execution acceptance

Astra accepts the bounded presentation amendment by source review.
The accepted frozen source remains under `u14-presentation-candidate/frozen-v2/` outside the repository.
The parser SHA-256 is `4c5ffd3b44dea7ef381d9b417c80c05aced15900d0fced9367442073f34358f9`.
The type-syntax SHA-256 is `75b0183e209c5abb68f46eaa600b1e77bd012afe6647a79b98053b0505695fc9`.
The JSON adapter SHA-256 is `b07dfd5ba4ddb855c33b26449cdfe0b954691d19b998bc9eb85eff473aa6bab8`.

Main integrates that exact source.
`u14-presentation-v2.log` exits 0 across nineteen steps, with 3,049 tests passed and one skipped.
The unfiltered gate covers ZTS, precompile, and layering.
The eighteen parser controls compare physical spans and presentation positions in collect and compile modes.
The helper tests cover composed rewinds, tracked CR handling, mixed-record deduplication, and physical removed-type positions.
Production CHECK remains on the legacy frontend.

Main measures twenty-nine further producer controls under `u14-tracked-producer-baseline/` outside the repository.
The pilot uses one case; the full run changes only the limit to twenty-nine.
Both scripts exit 0, and all fifty-eight CHECK and compile operations return their measured refusals.
The measurements distinguish runtime assignment preludes, function gaps, generic commitments, declaration gaps, module gaps, assertions, and function-type arrows.
Main also measures nine function-type controls under `u14-function-continuation-baseline/` outside the repository.
The pilot uses one case; the full run changes only the limit to nine.
Both scripts exit 0, and all eighteen CHECK and compile operations return their measured refusals.
The complete sources, requests, outputs, and direct statuses remain in those directories.

The public characterization table now contains ninety-four controls.
The extension adds thirty-six distinct controls and removes two exact duplicates within the measurement set.
The first extended gate fails one fixture because the generator loses a literal backslash in an expected suggestion.
`u14-tracked-producer-characterization.log` exits 1, with 244 tests passed and one failed.
This failure changes no production conclusion.
Main restores the exact measured suggestion and starts `u14-tracked-producer-characterization-escaped.log`.
Its verdict remains pending when this record is written.

### U14 remaining presentation design: existing producer boundaries

Astra accepts bounded classification between existing function-type continuation boundaries.
The existing endpoint scanner already recognizes the relevant `=>` boundary.
Before the tracked prefix, the classifier processes the completed source interval with its current presentation context.
The scanner then advances the context across the confirmed whitespace interval.
The final classifier processes the remaining interval.
The removed-type pass processes the full original span once, with physical coordinates.
Depth and comment failures process the remaining prefix without the removed-type pass.
This design adds no event array, scanner, grammar, or callback.

Only variable, named-return, and arrow-return continuations use this tracked whitespace operation.
Interface-extends and assertion continuations retain ordinary advancement.
The implementation must retain caller-owned caught rows and publish each new row once.
Compile mode must stop when the collector selects its first hard refusal.
Semantic failure and native failure must retain committed presentation changes.

Astra also accepts the runtime assignment hook in committed `advance()`.
The hook applies to punctuation tokens whose final source byte is `=`.
The hook excludes `=>` and does not run during tokenizer lookahead or raw erasure.
A header suppresses this hook only when the legacy parameter producer owns that header.
Runtime-only named-comment headers retain the runtime operation.
The header flag requires `defer` restoration and the applicable cursor checkpoint behavior.

The presentation context must follow each producer's actual commitment.
A named-function generic list can commit erasure before runtime owner publication succeeds.
A general generic probe restores its context when its operand check declines.
A runtime cursor restore cannot automatically undo every committed presentation effect.
Saved declaration, module, and nominal-body positions require finalization before a later prefix advances the context.

The two optional source slices on the collector and history remain justified.
They support comparison between explicit positions and physical records without changing the independent helper contract.
Both slices borrow the original source and bind before the first parser row.
The common comparison uses effective raw positions before JSON conversion.
The sink's presentation conversion remains idempotent.

Main prepares the function-type amendment under `u14-presentation-chunks/frozen-v1/` outside the repository.
Astra reviews that source independently.
The amendment and its tests remain temporary until Main integrates them and obtains the required unfiltered verdict.
Remaining producer amendments and the corrected CHECK rebase remain pending.

### U14 function-type amendment: final bounded acceptance

The corrected ninety-four-control legacy baseline passes.
`u14-tracked-producer-characterization-escaped.log` exits 0 across four steps, with all 245 precompile tests passed.
The correction restores the measured suggestion text; it changes no production source.

Astra finds two defects in the first function-type draft.
An optional removed span lacks validation before source indexing.
The allocation test uses only two diagnostics, which fit the initial allocation and cannot establish later failure.
Main corrects both defects before source acceptance.
Four rejection controls require valid bounds, an enclosing start, and the same endpoint before any publication.
A successful wider span confirms that the removed-type pass can inspect an earlier interval.
The allocation test derives the initial list capacity and creates enough distinct diagnostics to exceed it.
The test requires an observed allocation failure after the first interval remains in both retained lists.

Astra accepts the exact corrected source under `u14-presentation-chunks/frozen-v2/` outside the repository.
The parser SHA-256 is `03754b129a3d60849a1e317e9380acfdb0b4f093679590da1a28c81b25961ad3`.
The type-syntax SHA-256 is `346e69bbd861ad7433edb6b895a9b986fa1d897986fbceca0e48a4ee9019b617`.
Main integrates those files.
`u14-presentation-chunks-v2.log` exits 0 across nineteen steps, with 3,053 tests passed and one skipped.
The unfiltered gate covers ZTS, precompile, and layering.
Eight parser controls retain measured positions, diagnostic order, compile skipping of caught rows, and physical removed-type positions.
The helper tests establish retained caller seeds, compile stopping, malformed-span rejection, and allocation failure after publication.

### U14 runtime-only parameter headers

Astra identifies another producer distinction during the runtime prefix review.
The shared header uses `pending_signature` to distinguish typed headers from runtime-only headers.
Its optional, default, and pattern recovery branches do not consistently use that distinction.
A runtime-only header therefore receives diagnostics from a legacy parameter producer that never owned those bytes.

Main measures six controls under `u14-runtime-header-baseline/` outside the repository.
Main measures four additional nongeneric controls under `u14-runtime-header-extra-baseline/` outside the repository.
Each directory retains a one-case pilot and a full run with only the case limit changed.
Both pilots and both full scripts exit 0.
The twenty CHECK and compile operations return the measured refusals.

The nine commented-header controls produce parser diagnostics without admission diagnostics.
Commented default headers produce ParseError.
Commented optional and annotation headers produce UnexpectedToken.
The commented pattern header produces ParseError.
The ordinary typed default control retains ZTS054 followed by ZTS041 in CHECK.
Compile stops at DefaultParameter for that typed control.

The public table now contains 103 distinct controls.
The extension adds nine controls; the ordinary typed default control already exists in the table.
Astra requires admission-only nongeneric header selection from the two original whitespace gaps.
Private `initTyped` behavior remains unchanged.
The existing generic reservation policies retain their own header selection.
Optional and default admission events require a pending signature.
Pattern recovery also requires a pending signature.
Runtime-only headers retain ordinary parser failures and ordinary outer recovery.

Main prepares and integrates a bounded runtime presentation draft for unfiltered validation.
The temporary frozen source is `u14-runtime-presentation/frozen-v1/parse.zig` outside the repository.
Its SHA-256 is `40ea613b56ae7ab92cfe9adfaf077a46845ed9b7f51eb96e6e3e27eb46814ea8`.
The draft also handles runtime assignment prefixes, function gaps, selected generic gaps, return gaps, and assertion prefixes.
Astra reviews the exact source and twenty-two controls in both admission modes.
`u14-runtime-presentation-v1.log` runs the unfiltered ZTS, precompile, and layering gate.
Source acceptance and the gate verdict remain pending when this record is written.
Declaration, module, and other selected generic operand prefixes remain pending.
Production CHECK still uses the legacy frontend.

### U14 runtime presentation corrections and further controls

The first runtime gate confirms the missing function-expression producer.
`u14-runtime-presentation-v1.log` exits 1 across seventeen successful steps.
It reports 3,053 tests passed, one skipped, and one failed.
The failing control retains the measured anonymous function annotation; Main changes no expected public diagnostic.

Astra finds a second defect before that gate completes.
A completed named generic can advance the presentation context and then restore the runtime cursor inside the erased list.
Recovery can then request a position before the context and panic.
Recovery can also dispatch an assertion producer inside that erased list.
A token guard alone cannot establish the correct erased boundary.

The corrected named producer preserves committed erasure independently of runtime owner publication.
The selected whitespace-named scan resumes through the observation-aware raw helper from the exact generic endpoint.
The parser retains the runtime previous token and staged survivor trivia.
A failed owner reservation rolls back Store while preserving the committed cursor and presentation context.
Private parsing and uncommitted compatibility call probes retain their existing restoration rules.
The final accepted cursor uses one token-count increment.

The corrected function-expression path retains the original unsupported diagnostic and its exact error count.
The admission-only helper requires raw whitespace at the applicable legacy header boundaries.
The helper uses the existing generic and header scanners.
A temporary function scope and pending signature support the existing parameter parser.
The helper never parses the body or finishes a function owner.
Cleanup cancels pending signature and generic records before the complete outer Store rollback.
The existing failure selector retains native, internal, and terminal failure priority.

Astra accepts both correction designs.
Main measures four additional controls under `u14-generic-recovery-position-baseline/` outside the repository.
The controls cover generic defaults without an opener, later assignments, function bodies, and recovery after a failed header.
Main measures nine controls under `u14-function-expression-recovery-baseline/` outside the repository.
Those controls cover function-expression admission, ordinary unsupported errors, committed generic erasure, and unfinished survivor comments.
Each directory retains the exact one-case pilot, full run, source, request, output, and direct status.
Both pilots and both full scripts exit 0; all twenty-six CHECK and compile operations return their measured refusals.

The public characterization table now contains 116 distinct controls.
One terminal comment control produces no JSON row and retains one parse error.
The common expected error count preserves all earlier positive counts and fixes that explicit zero-row case at one.
The runtime parser table now contains thirty-four controls, each checked in collect and compile modes.
A separate test requires terminal comment failure after committed erasure, with no fabricated last diagnostic.
A two-mode allocation sweep exercises a function-expression header with an earlier typed parameter and a later rejected parameter.
The sweep requires complete Store cleanup and the global scope after allocation failure and semantic refusal.

The second runtime gate finds a compile error in pending-owner cleanup.
The new optional capture supplies a value where `cancelGenericOwner` requires a pointer.
`u14-runtime-presentation-v2.log` exits 1 across nine successful steps, with 94 tests passed.
Four artifacts fail compilation at that same call; the new behavior tests do not run.
Astra also identifies one erroneous physical span in the new function-expression default fixture.
The fixture selects the initializer assignment instead of the parameter assignment.
Main changes its physical span from `[8,9)` to `[21,22)` and preserves the measured presentation column 22.

Main corrects the pointer capture and freezes the revised source under `u14-runtime-presentation/frozen-v3/` outside the repository.
The parser SHA-256 is `fdf49ba7c2d775a7db7c8b0d47712bc7e24fe48f6d3d2f91b08e6a6582240d87`.
`u14-runtime-presentation-v3.log` runs the unfiltered ZTS, precompile, and layering gate.
Its execution verdict and Astra's final source verdict remain pending when this record is written.
No production CHECK cutover starts during this correction.

### U14 runtime acceptance and declaration follow-up

The runtime presentation amendment passes its unfiltered gate after the two recorded corrections.
`u14-runtime-presentation-v3.log` records exit 0, nineteen steps, 3,056 passed tests, and one skipped test.
Astra xhigh accepts the exact source recorded above.
The public table retains 116 measured controls against production CHECK's legacy path.

Main measures four absent-alias controls against the immutable legacy analyzer.
The receipts reside in `u14-absent-declaration-comment-baseline-v2/` outside the repository.
A one-case pilot precedes the four-case run; both scripts exit 0.
Unused aliases before comments pass CHECK and compile.
Used aliases, including generic aliases, retain ZTS200 at line 2, column 59.
Those failures concern type compatibility, rather than parser recognition.
The fixture handler declares `Proof<Response, "pure">`; broader declarations produce unrelated default-profile failures.

Main also measures thirteen module, export, and generic-operand controls.
The receipts reside in `u14-module-presentation-baseline/` outside the repository.
The pilot and complete scripts exit 0; each recorded CHECK or compile command exits 1.
The controls retain exact input bytes, requests, outputs, and direct process statuses.
The generic list followed by `extends` retains a tracked prefix before the later any diagnostic at column 49.
The caught-plus-retired import selects ZTS053 alone, so parser history needs a separate caught-observation assertion.

The declaration draft retains absent structural aliases before comments and preserves selected declaration prefixes.
Astra finds one draft defect: replacing the copied cursor loses its existing consumption count.
Main preserves that count before adding the survivor token.
Astra finds no Store ownership defect in the production draft.
Final source review and execution remain pending the new boundary, coordinate, and allocation tests.

The first declaration test gate stops at three missing required option fields.
`u14-declaration-presentation-v2.log` records exit 1, sixteen successful steps, and 1,907 passed tests.
The affected engine artifact does not compile, so the new declaration behavior lacks an execution verdict.
Main supplies explicit absent bodies and adds fixed floors for both success tables.
Main also asserts the exact surviving variable declaration and its integer initializer.
Astra accepts `u14-declaration-presentation/frozen-v3b/` as the bounded final source.
Its parser SHA-256 is `9b5d93547b5a10420fc20d1fcbbb898daaaed8bf05f86629e74a01dd0bf5e5bd`.
Its type syntax SHA-256 is `458925c9aa9baaee4182f82122d467f4492a9c26b90f6ab116bb094b2b7a8084`.
The unfiltered replacement gate is `u14-declaration-presentation-v3b.log`.
Its execution remains active when this record is written.

The module draft follows the existing scanner's selected result before committing presentation.
Retired-module and export refusals retain positions from the saved incoming context.
Accepted grouped or brace prefixes commit before fallible owner reservation or operand parsing.
The existing `extends` survivor commits raw erasure without creating a semantic owner.
Astra accepts that bounded insertion design after the thirteen-case measurement.
The selected scanner and whitespace gap remain its recognition authority.
Private typed parsing and explicit-call probes retain their existing behavior.

The module draft contains seventeen two-mode parser controls and a separate caught-history control.
The public recovery table expands from 116 controls to 129 controls.
Astra identifies three parser fixtures that violate the existing retired-module spelling rule.
Main composes those exact source bytes with the existing `retired_types_module` constant.
The draft remains outside the repository until the declaration gate closes.

The corrected declaration gate finds an invalid compatibility-node read in its survivor assertion.
`u14-declaration-presentation-v3b.log` records exit 1, seventeen successful steps, 3,061 passed tests, one skip, and one crash.
The compatibility `IRStore.get` method returns incomplete payloads for complex nodes.
The test reads a variable payload from that incomplete node and aborts.
Main retains the index and reads the payload through `IrView.getVarDecl` instead.
The declaration production source remains unchanged after the earlier cursor correction.
The combined module gate includes this test correction.

The first module gate stops during compilation because one length expression infers `usize` instead of `u32`.
`u14-module-presentation-v3.log` records exit 1, nine successful steps, and 94 passed tests.
Four artifacts fail compilation at the same expression, so the new behavior tests do not run.
Main supplies the explicit `u32` conversion.
The final draft resides in `u14-module-presentation/frozen-v4/` outside the repository.
Its parser SHA-256 is `fd76660cedf7a27c3c4f81b905270cd10b0db305ed97d49008ff8b3cb88a9e04`.
Its precompile SHA-256 is `829b82eb2bfe3c6f6483ce5fd660d29bec7ec8f0fac0ca5ff3be0a7dd5b655a1`.
`u14-module-presentation-v4.log` runs the unfiltered ZTS, precompile, and layering checks.
The receipt includes the corrected declaration survivor test and all 129 public recovery controls.
Production CHECK still uses the legacy frontend during this gate.

Astra accepts the final module source and the corrected declaration assertion.
Astra also accepts the exact CHECK rebase under `u14-check-cutover-candidate/main-rebased-v5/` outside the repository.
Its precompile SHA-256 is `34709408db979bfefbbee48dcbf14a8e168893ee66aaae442b90e8d57452cbda`.
Its JSON adapter SHA-256 is `1938215b9232fd49be010ac1d6f6ef7f06d1637b1049e5025c06311fbb4970d6`.
The rebase retains all 129 distinct recovery sources and all four absent-alias controls.
Main checks the recovery table's source count and uniqueness mechanically.
Astra confirms that the rebase retains every earlier test and adds only the two accepted ownership or import tests.

The recovered CHECK branch finalizes raw positions and deduplicates before JSON conversion.
JSON conversion applies the existing column clamp before recovered-only source normalization.
Terminal CHECK projection remains unnormalized.
The new JSON test distinguishes explicit presentation from physical coordinates and preserves the adapter's independent column clamp.
No cutover execution verdict exists when Astra supplies this source acceptance.

The combined declaration and module amendment passes its unfiltered gate.
`u14-module-presentation-v4.log` records exit 0 and nineteen successful steps.
The gate passes 3,064 tests and skips one test.
The corrected declaration survivor assertion passes through `IrView.getVarDecl`.
All seventeen module controls and the caught-history control pass in both modes.
All 129 public recovery controls and all four absent-alias controls pass against legacy production CHECK.

Main then integrates the source-accepted CHECK rebase without changing those expectations.
Production CHECK now uses direct collect admission for TypeScript roots and compile admission for imported TypeScript.
The original reader traversals remain separate.
`u14-check-cutover-v5.log` runs the first unfiltered precompile gate against that production switch.
Its execution remains active when this record is written.

### U14 first CHECK execution and bounded corrections

`u14-check-cutover-v5.log` records exit 1 and 241 passed tests from 249 tests.
Eight tests fail after the first production CHECK switch.
Three compatibility tests expose unnormalized zero positions after parsing.
The mutation suite reports 48 diagnostics outside source bounds for the same missing normalization boundary.
Main restores source normalization after typed parsing and analysis, while preserving strip-only terminal projection.

The keyword-alias test exposes an identifier-token guard that excludes names already accepted by the semantic declaration parser.
Main reuses the existing lexical predicate for admitted and refused declaration names.
The generic test exposes premature rejection of a whitespace gap before a named function's generic list.
Astra identifies the legacy call scanner as that list's existing owner.
The correction retains a runtime-only header and the measured colon refusal at column 18.
A typed named-header path would change that public behavior.

The type-only module test exposes a false string observation during runtime recovery.
A raw module endpoint stops at a semicolon inside a comment, leaving a surviving star and slash.
The runtime tokenizer then forms a regex token that crosses the real opening quote.
The real closing quote becomes a false opening quote during later runtime tokenization.
An admission observation at that false opener incorrectly selects ZTS008 instead of the saved parser diagnostic.

Main measures four exact recovery contrasts against the immutable analyzer.
`u14-module-recovery-baseline/` retains their sources, requests, outputs, and direct statuses outside the repository.
Its one-case pilot and four-case run complete successfully.
The clean survivor reports ZTS002 at 1:24.
A real later malformed quote reports ZTS008 at 2:20.
A later typed any reports ZTS041 at 2:14.
The nested survivor reports both ZTS002 at 2:24 and ZTS003 at 5:1, with the expected closing brace.
The complete nested parser batch must remain intact.

The added imported-source test also contains incorrect new expectations.
Independent native legacy and direct runs each perform two reads and refuse the original `pure` capsule.
Changing the helper to a pass-through retains that refusal in both runs.
A measured narrow `read_only` capsule succeeds in both runs with two reads and no diagnostic.
Both successful contracts retain complete effects, `pure=false`, and `read_only=true`.
The native source, exact compiler requests, complete logs, and statuses reside in `u14-imported-caught-trace/` outside the repository.
The `original/` and `pass-through/` subdirectories retain both earlier measurement sources and outputs.
Main changes only this newly added test to the measured narrow capsule and two-read trace.
Existing reader characterization remains unchanged.

Main also measures three spaced-function controls against the immutable analyzer.
`u14-spaced-function-baseline/` retains their exact receipts outside the repository.
Its pilot and complete run use the same script, with only the case limit changed.
An unannotated spaced function reaches strict ZTS601 at 1:16.
A gap between the generic list and opener declines at 1:13.
A typed spaced function retains the existing refusal at 1:18.
The direct parser test additionally requires an actual function-expression owner, call arguments, and no typed header signature.

Astra corrects two facts in that new parser test before execution.
The declaration wrapper points to the function-expression initializer that owns the generic list.
The Store retains one authored and one projected parameter before selecting call-argument compatibility.
Main corrects the assertions without changing production.

The next focused CHECK gate records exit 1, with 250 of 251 tests passed.
`u14-check-corrections-v6.log` fails only the new complete nested parser batch.
The proposed admission-only slash traversal avoids the false string but changes runtime recovery.
It allows the nested parser to find the closing brace and removes the required second diagnostic.
Astra withdraws that recovery direction for this complete compatibility boundary.
Main retains the measured two-diagnostic expectation.
The remaining correction must preserve runtime recovery while aligning admission observations separately.

Astra also bounds the new generic allocation test to type allocations.
Runtime allocation can fail after a function owner publishes, so universal rollback is not the transaction's contract.
The revised test keeps runtime allocation healthy and derives the complete seed checkpoint from actual declaration progress.
It compares all seventeen Store arrays after a later type allocation failure.
A positive post-seed failure floor prevents an empty sweep from passing.
The revised parser test remains outside the repository pending the final recovery correction.

Astra accepts the corrected normalization, keyword-name, spaced-list, and measured imported-effect scopes.
Astra confirms that all new public expectations match the retained immutable receipts.
The revised generic allocation sweep also receives source acceptance.
Its runtime allocator stays healthy, and the test independently derives the complete seed checkpoint and function boundary.

The remaining module correction cannot replay full statement parsing under a cursor-only checkpoint.
Statement parsing also changes scope bindings, atoms, constants, and runtime nodes.
A cursor restoration would not undo those changes.
The recovery design must preserve those ownership boundaries and the complete applicable runtime error batch.
No production CHECK expectation changes during this review.

Main measures the complete closed admission vocabulary behind the same lexical divergence.
`u14-recovery-producer-census-baseline/` retains eighteen exact CHECK and compile pairs outside the repository.
The one-case pilot precedes the eighteen-case run; both scripts complete successfully.
The first seventeen controls reach each published admission kind after the failed runtime statement.
The final control retains the location-free unfinished-comment failure with no JSON diagnostic.
The depth control derives its boundary from the current named constant before creating its source.
These measurements rule out a recovery correction that observes only later variables and quotes.
Header, declaration, export, assertion, generic, module, and depth producers need an explicit route through the recovered interval.
The census bounds this closed diagnostic vocabulary, rather than every possible source context.

Astra identifies another requirement for the recovery cursor.
One raw quoted region can overlap two runtime tokens after the lexer diverges.
A recovery observer must retain its progress through that overlap.
Restarting the observer at each runtime token can treat another closing quote as an opening quote.
A producer that starts inside the selected interval must finish through its own existing endpoint.
No new arbitrary scan budget is justified.

Main measures two further nested controls with accepted quoted types after the divergence.
`u14-recovery-erased-quotes-baseline/` retains both exact CHECK and compile pairs outside the repository.
The pilot and complete measurement scripts exit zero.
Both `const live: "const" = 1;` and `const live: "return" = 1;` retain the complete earlier nested parser batch.
Their diagnostics remain ZTS002 at 2:24 and ZTS003 at 5:1.
Legacy admission erases these type quotes before runtime recovery tokenizes the remaining source.
Observing raw admission separately does not itself preserve that erasure effect on runtime token boundaries.
The final recovery design must account for those accepted erasures as well as diagnostic reach.
An observation-only correction therefore remains insufficient for the measured compatibility boundary.

Astra recommends shared producer-only factoring before another implementation attempt.
The observer can reuse binding annotations, assertions, declarations, and modules without full statement dispatch.
Export recognition must precede runtime dispatch in a shared helper.
Raw parameter recovery can share the existing item scanner without creating scopes, bindings, signatures, or runtime nodes.
Return observation can share its endpoint and classification prelude.
Generic observation must share the selected scanner before owner reservation.
These directions remain design work, rather than source or execution acceptance for the final recovery amendment.

### U14 accepted recovery amendment

Astra accepts the following design for the confirmed regex and string divergence.
Normal runtime regex lexing remains unchanged.
Recovery first proves that a runtime string starts at a closing quote of an overlapping raw quoted region.
The proof uses the existing quoted-region scanner.
A preceding regex token alone does not justify suppression.

The admission cursor advances monotonically through the affected interval.
It retains progress when a raw quote or producer crosses a runtime token endpoint.
The runtime cursor retains ordinary recovery behavior independently.
Recovery state persists across a synchronization return until both cursors rejoin.
The observer does not replay statements.
It creates no runtime bindings, nodes, scopes, signatures, or atoms.

Both normal producers and recovery share source-only operations.
Binding annotations reuse their existing collector for all three binding keywords.
Assertions, declarations, modules, and generic selection retain their existing scanner choices.
Export recognition and emission precede runtime dispatch in a shared operation.
Raw parameter observation reuses the existing item recovery scanner without header publication.
Return observation shares its endpoint and classification before semantic construction.

The observer emits exact erased intervals from each owning producer.
Those intervals include markers, accepted generic lists, declarations, and other selected erasures.
The intervals remain ordered and nonoverlapping.
Recovery owns their temporary storage, and synchronous scanner calls borrow it.
Rejoin or parser cleanup frees that storage.
Allocation failures remain native errors.

The runtime string scanner reads erased bytes as spaces and preserves LF bytes.
Ordinary strings use the same scanner core without erased intervals.
Recovery rescans only a proven misaligned string.
If masking extends its endpoint, observation continues before another rescan.
The admission walk never restarts.

Runtime recovery cannot repeat observation for bytes already owned by the admission cursor.
Position deduplication alone cannot prevent an incorrect prefix operation.
The observer retains its presentation context and committed history.
Observer calls restore the real runtime cursor and all seventeen Store arrays.
The observer does not change scopes or parser errors.
A rescan updates the token and tokenizer position without producing IR.
Pending trivia remains provisional until its corrected boundary is reached.

Acceptance requires the closed seventeen-kind census, its location-free comment, and all six module controls.
The complete nested ZTS002 and ZTS003 batch remains fixed.
Allocation tests must observe failures after observation and interval publication.
This design acceptance bounds the confirmed divergence, rather than every possible regex context.
No final recovery implementation or execution acceptance exists yet.

Main starts the accepted recovery amendment outside the repository.
`u14-recovery-erasure-bridge/` retains its exact working source and component receipts.
The temporary tokenizer shares the ordinary string loop with a borrowed erasure view.
The view preserves LF bytes and replaces other erased bytes logically with spaces.
A rescan validates every interval before changing tokenizer state.
The caller must separately prove the misaligned recovery opener.

The first component probe stops because its parameter name shadows the token module.
The corrected probe then stops at one missing explicit integer conversion in a test.
Main corrects both local compile errors before execution.
`tokenizer-pilot-v3.log` records exit 0 and all twenty-two unfiltered component tests passed.
The tests cover quote extension, escaped bytes, LF positions, and validation before mutation.
The component source SHA-256 is `c6f1247a89f4233987577528cb9a491e8ff1d33535501e1a5be1d019f26d811a`.
The source remains outside the repository for Astra review and later parser integration.
This component result does not establish the recovery bridge or U14 acceptance.

Astra accepts the tokenizer component as source only.
Main prepares shared source operations and the recovery owner outside the repository.
Generic candidates carry copied cursors, while normal callers reserve Store records before cursor adoption.
Named early commitment and the general extends case retain their existing ordering.
The observer reuses the parameter item scanner and the shared return collector without runtime publication.

The first temporary unfiltered CHECK run compiles and reaches test 197 before an assertion stops execution.
The recovery seed calls a forward-only tokenizer method from a position beyond its target.
`precompile-temp-v1.log` and its direct exit status retain this failed component integration.
Main corrects the seed with a fresh tokenizer that borrows the same source.
The second temporary CHECK run uses a separate frozen source overlay.
No final recovery acceptance or repository integration exists at this point.

### U14 recovery review and component execution

The corrected temporary CHECK run passes all 252 unfiltered tests in `precompile-temp-v2.log`.
That run includes the closed admission census, location-free comment, and six module controls.
The temporary engine root initially stops at an unnecessary optional unwrap in a newly added alias test.
Main corrects that test expression without changing its expectation.
`engine-temp-v3.log` then records exit 0, with 1,164 passed tests and one skipped test.
Both allocation sweeps pass, including the recovery observation and erasure floors.

Astra finds a separate raw header gap before repository integration.
Tokenizer read-ahead can skip a comment before the raw item scanner runs.
That skip loses a default diagnostic or places the forward-only cursor beyond a raw closing parenthesis.
Main measures four controls through the immutable analyzer after a one-case pilot.
`u14-recovery-header-baseline/` retains exact sources, requests, outputs, and direct statuses.
A default inside the first comment reports ZTS054 at 2:17.
A default inside a later comment reports ZTS054 at 2:28.
A closing parenthesis inside a comment retains ZTS002 at 1:24.
An unfinished comment inside the raw header retains that same parser diagnostic without a comment failure.

The new four-case public test fails against the earlier temporary source.
`precompile-header-red.log` records exit 1, with 252 passed tests and one failed test.
The first case incorrectly reaches parsing instead of selecting the measured strip-only refusal.
Main preserves the measured expectations.
The correction saves each item tokenizer immediately after its opening parenthesis or comma.
The existing raw item scanner runs before a tokenized EOF or closing parenthesis can stop the observer.
Its final resume replaces provisional read-ahead trivia.
Named generic erasure also uses the exact scanned list, separate from tracked presentation whitespace.

Astra accepts those bounded source corrections and all four public expectations.
The frozen parser SHA-256 is `021194f34b50cb5e647d4148eb6eb194d8f1aa9c000474af15211e095c613f86`.
The frozen CHECK source SHA-256 is `138342c374208b331588c2fa3a3717212934dd027e53387dff9ca5dab7636006`.
The tokenizer retains its accepted component hash.
The corrected temporary engine and CHECK gates run sequentially against that frozen source.
Repository integration and final execution acceptance remain pending.

The corrected temporary engine root passes 1,164 tests and skips one in `engine-temp-v4.log`.
The corrected temporary CHECK root passes all 253 tests in `precompile-temp-v4.log`.
Both direct statuses are zero.
The new header test now passes without changed expectations.
The complete nested batch, eighteen-case census, six module controls, and allocation floors also pass.

Main moves two early commitment flags before interval allocation after final line review.
That ordering preserves committed erasure if allocation fails.
Astra accepts this final source correction for integration.
The final parser SHA-256 is `a9274a1dd4f903ba777b98a90a9d334a4c03e0072f5abddb60b6ac514bfd5d63`.
The CHECK and tokenizer hashes remain the frozen hashes above.
Main integrates exactly those three files and starts `u14-frontend-final.log`.
This gate uses the complete unfiltered frontend command from the verification contract.

The integrated frontend gate passes all forty-five steps.
`u14-frontend-final.log` records exit 0, with 3,935 passed tests and one skipped test.
The 182 diagnostic corpus cases also pass.
`u14-extras-docs-final.log` passes all sixty steps, with 1,427 passed tests and one skipped test.
Its scope includes protocol, offline expert, documentation, and spine checks.
Formatting and whitespace checks both record exit 0.

Main removes redundant Store checkpoints from the three source-only generic selectors.
Those selectors no longer publish Store records after the accepted factoring.
Cursor rollback, early commitment, and the observer's complete Store rollback remain intact.
Three duplicate cursor adoption blocks now use the existing helper.
The proof tests remain unchanged.
Astra accepts this bounded simplification before integration.
The final parser SHA-256 becomes `6aec9afad38318bb1d50da3040ed55172a9daadc0692cc0e0708a9128382dd0b`.
The full local script runs against that final source as `u14-verify-final.log`.

The first final script stops during the aggregate because the filesystem has no free space.
`u14-verify-final.log` records exit 1 and explicit LLVM and temporary-file `NoSpaceLeft` errors.
The aggregate reports 93 of 191 steps succeeded, with 3,684 passed tests and one skipped test.
That incomplete run supplies no full-gate acceptance.
Main removes 520 old generated cache directories referenced by this reset task.
The cleanup excludes analyzer executables and retains every source and evidence receipt.
The filesystem then reports 25 GiB available.
The immutable legacy analyzer retains SHA-256 `5cb9af9ec1cd3ca86873327b4e2f503edf436d9d0e23a6dd8b04d04069400d16`.
Main retries the unchanged full script as `u14-verify-final-v2.log`.

The immediate retry stops before the aggregate starts.
Its retained cache manifest points to the removed generated build runner.
`u14-verify-final-v2.log` records `FileNotFound` and exit 1.
Main clears generated cache manifests and retains analyzer binaries, source files, and baseline receipts.
The next unchanged full attempt runs as `u14-verify-final-v3.log`.

### U15 bounded preparation review during final U14 checks

Main prepares the shared failure mapper and delayed runtime generation outside the repository.
Astra accepts the optional phase model and the unchanged seventeen-kind failure mapping.
The original raw API remains separate, and invalid phase calls fail before mutation.
A permitted typed operation consumes its phase before fallible work.
Successful parsing optimizes and validates the matching Store before publishing its root.

Astra finds three existing CodeGen ownership gaps that affect generation failure cleanup.
A float can lose its owner if constant insertion fails.
A nested function can release its constants buffer without releasing completed child payloads.
Local cleanup can remain active after the parent constant list takes ownership.
A later emission failure can then leave a dangling parent entry.
Completed pattern dispatch also needs cleanup with its owning function payload.

The bounded amendment gives each unpublished payload a local owner.
Successful constant insertion transfers ownership exactly once, before later emission.
Failed generation releases the abandoned published tree before clearing CodeGen.
Successful runtime ownership remains unchanged.
The amendment does not change HandlerAnalyzer's existing nonfatal analysis policy.

Temporary public tests compare legacy-prepared and direct bytecode, serialized constants, dynamic atoms, and original type spans.
Allocation probes distinguish parsing, validation, float publication, function publication, and completed dispatch publication.
Independent counters establish validation failure and runtime parsing progress separately.
Source cursor progress remains observable in ReleaseFast.
The mapper expectations come from the retained immutable compiler outputs for all seventeen kinds.
The location-free comment has its own expected error.
Astra accepts the production source and the corrected independent failure counters as source only.
These files remain outside the repository and have no execution acceptance before U14 commits.

Main observes overwritten headers in the third full log before completion.
Two native tools use positional stdout writers, which can overwrite earlier output in a shared regular file.
A bounded native pilot confirms that both plain and append capture lose an earlier sentinel.
The same native command preserves the sentinel when stdout and stderr use a pipe.
`u14-log-capture-pilot/` retains all three logs and direct statuses.
Main stops the incomplete third capture; the process returns 143.
That run supplies no final acceptance.
The fourth full attempt uses pipe capture and the same source, commands, and environment.
Its parent records the script's direct process status separately from the capture operation.
No production source changes for this capture correction.

### U14 final full receipt

`u14-verify-final-v4.log` records the complete pipe-captured script and direct exit 0.
The script ends with `verify.sh: all CI test-job steps passed`.
The aggregate, standalone runtime, ReleaseFast builds, verified handler compilation, smoke workflows, panic isolation, and remaining offline gates pass.
The final formatting step also passes.
The source retains the accepted parser, tokenizer, and CHECK hashes above.
Main runs final documentation, spine, formatting, and whitespace checks before the local commit.
Astra performs the final independent execution audit.

### U14 acceptance and commit readiness

Astra accepts the final U14 execution evidence after reading the complete unfiltered script receipt.
The final documentation and spine gate passes all eight steps in `u14-docs-final.log`.
`u14-fmt-status-final.log` and `u14-diff-status-final.log` both record exit 0.
The final status contains only the eleven owned modified files and the untouched untracked Claude plan.
U14 is complete before its exact-path local commit.
U15 production integration starts only after that commit.

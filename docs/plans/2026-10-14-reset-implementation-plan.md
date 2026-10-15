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

This planning task authorizes only this document.
It does not authorize implementation, other documentation edits, commits, or pushes.
The implementing agent will own later code, documentation, review, and verification.
The user will own authorization to start implementation and any publication.

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
Export copies must remain valid after session cleanup.

An existing fixture imports `parseBearer as length` and calls a local function whose slot equals that import slot.
Source review shows that the current contract sets bearer authentication metadata through that slot match.
A baseline assertion must confirm this behavior before the accessor migration.
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
Baseline characterizations remain necessary before implementation.

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
Verify must still read disk first and preserve the current missing-file refusal.
Graph identity and the stale guard must use the same effective source as analysis.

Current graph construction reads the root before validating its extension.
Missing or oversized JavaScript roots therefore produce `EntryUnreadable`, while readable JavaScript roots produce `UnsupportedSourceExtension`.
Root read failures, including allocation failure during that read, map to `EntryUnreadable` before operation dispatch.
Later allocation failures retain their existing handling.
The captured reader must retain `module_graph_record.max_source_bytes` and leave extension validation to `buildWithEntrySource`.

Imported read failures remain graph rejections and do not become universal root refusals.
The source capture reader must not become CHECK's import reader.
Separate dependency graph, summary, and fault observations remain unchanged.
Normalize write refusal remains before stale checking and operation dispatch.
A controlled changing-reader test must bind the digest, graph hash, diagnostics, and contract to captured bytes.
The test must also confirm that later disk bytes differ from those captured bytes.

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

The planning task ends when this complete document is saved and reviewed.
The user owns authorization to start U1.

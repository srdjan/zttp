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

### U11 preparation findings

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

### U12 preparation findings

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

The planning task ends when this complete document is saved and reviewed.
The user owns authorization to start U1.

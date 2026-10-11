# A simpler foundation for zttp and zts

## Accepted direction

The owner accepted these decisions on 2026-10-11.
Decision 1 preserves every documented current feature.
Decision 2 starts with shared analysis for checking and compilation.
Decision 3 preserves current wire formats during the first phases.
These decisions select the planning direction. They do not authorize product edits.

## Recommendation

Preserve the current product surface while replacing the compiler's internal boundaries in small, measurable steps.
The strongest first target is one analysis result shared by checking, compilation, and contract production.
The strongest larger experiment is a direct typed frontend that replaces source stripping and annotation reconstruction.
Keep the native Zig runtime, bytecode interpreter, and independent acceptance kernel during both changes.

This is a direction audit, not an implementation plan or a defect report.
The audit changed no repository files. No tests or benchmarks ran.
The root agent ran the source metric described in the validation appendix.
The inspected baseline is `38a0782fba69dafb3dec4a0974a828cb2bdca1bf` on local `main`.
The working tree was clean at the start and at the last inspection.

Substantial simplification is possible, but a complete rewrite is not yet justified.
The repository has already removed several expensive alternatives and completed recent consolidation work.
A proposal must identify a current representation or responsibility that disappears after migration.
Moving code into smaller files does not meet that condition.

## Measured scope and evidence limits

The following measurements count tracked Zig files under `packages/`.
Physical lines include comments, tests, blank lines, and package build files.
They measure maintenance scope, not production complexity or removable code.

| Package | Files | Physical lines |
|---|---:|---:|
| zts | 198 | 186,705 |
| pi | 164 | 87,546 |
| runtime | 122 | 84,882 |
| tools | 59 | 55,104 |
| proof-checker | 17 | 13,548 |
| modules | 25 | 8,706 |
| proof-review | 10 | 2,687 |
| zttp-sdk | 21 | 1,855 |
| Total | 616 | 441,033 |

Reproduction command:

```sh
git ls-files -z 'packages/**/*.zig' | xargs -0 wc -l | awk 'NF==2 && $2!="total" {split($2,parts,"/"); n[parts[2]]++; lines[parts[2]]+=$1} END {for(pkg in n) print pkg,n[pkg],lines[pkg]}' | sort
```

Selected current surfaces:

| Surface | Physical lines | Interpretation |
|---|---:|---|
| `flow_checker.zig` | 11,861 | Large proof analysis, including its tests |
| `precompile.zig` | 9,136 | Multiple analysis and compilation entry paths |
| `contract_builder.zig` | 8,397 | Contract extraction and associated tests |
| `type_checker.zig` | 7,928 | Type analysis and associated tests |
| `parser/parse.zig` | 5,872 | Existing expression and statement parser |
| `stripper.zig` | 5,412 | Typed-source scanner and reconstruction metadata |
| `path_generator.zig` | 5,225 | Generated paths, coverage accounting, and tests |
| `interpreter.zig` | 5,010 | Current VM dispatch and tests |
| `comptime.zig` | 2,074 | Restricted constant evaluator using the existing parser |
| `proof_ir.zig` | 1,306 | Deliberately smaller proof representation |
| `tsx_lowerer.zig` | 642 | TSX lowering and tests |
| `translation_witness.zig` | 455 | Relation between parser nodes and final bytecode |
| `type_map.zig` | 256 | Annotation identities and source-coordinate mapping |
| Four `wasm/` policy files | 96 | Fail-closed skeleton, not another execution tier |

Reproduction commands:

```sh
git ls-files -z 'packages/**/*.zig' | xargs -0 wc -l | sort -nr | head -32
wc -l packages/zts/src/comptime.zig packages/zts/src/stripper.zig packages/zts/src/type_map.zig packages/zts/src/tsx_lowerer.zig packages/zts/src/path_generator.zig packages/zts/src/proof_ir.zig packages/zts/src/translation_witness.zig packages/zts/src/wasm/*.zig
```

No deletion percentage, speedup, source coverage, or future line count was measured.
This report supplies none of those projections.
Raw textual branch counts are not used as complexity measurements.

The current architecture document contains stale artifact-format prose.
`packages/runtime/src/self_extract.zig:22` defines format 6, matching `docs/user-guide.md:847`.
`docs/internals/architecture.md:209` still describes format 4.
Source and current public behavior must settle compatibility questions when documents disagree.

## Existing simplifications that must not be proposed again

The JIT tiers are gone.
`packages/zts/src/tests/opcode_parity.zig:7` explains that its corpus now checks one interpreter against expected values.
The archived VM-loop plan describes removed JIT code and cannot justify current work.
The native runtime still executes handlers through bytecode, with selected embedded AOT paths where configured.
`packages/runtime/src/handler_instance.zig:1582` retains that AOT attempt and fallback.

Source preparation already has one owner in `packages/zts/src/source_frontend.zig:1`.
Compile-time evaluation already uses the main parser and IR in `packages/zts/src/comptime.zig:1`.
The remaining separate compile-time value model does not imply a separate parser.

Route resolution already has a shared implementation in `packages/zts/src/route_resolution.zig:1`.
The compiler already shares module facts and has typed phase wrappers in `packages/zts/src/pipeline.zig:1`.
The September work already consolidated schema literals, journal decoding, transaction recovery, and the acceptance kernel.
`docs/plans/2026-10-10-minimal-design-worklog.md` records completion of its ten reductions and the compile-completeness correction.
Those reports are historical evidence, not this audit's test results.

The three public binaries already isolate the expert agent from deployment.
`build/artifacts.zig:35` excludes `pi_app`, deployment commands, and analyzer commands from the runtime template.
Extracting `pi` into another repository would not remove those runtime dependencies because they already do not exist.

## Contracts that define success

The default compatibility baseline is the documented current product, not an unspecified smaller language.
The following contracts remain mandatory unless the owner explicitly selects a product change.

| Contract | Required preservation | Current evidence |
|---|---|---|
| Source profile | Current `.ts` and `.tsx` acceptance, refusal, and source identities | `docs/user-guide.md:492`; `packages/zts/src/source_frontend.zig:16` |
| Types | Generics, recursive aliases, narrowing, `null` versus `undefined`, Result and optional handling | `docs/user-guide.md:511`; `docs/user-guide.md:546` |
| Handler behavior | Request fields, response bodies, headers, statuses, routing, and native calls | `docs/user-guide.md:56`; `docs/user-guide.md:90` |
| Proof honesty | Unknown input never becomes a proven property | `CONCEPTS.md:167`; `docs/solutions/security-issues/empty-label-set-claimed-a-value-was-clean.md` |
| Independent acceptance | Consumer derives obligations and checks the loaded artifact independently | `CONCEPTS.md:78`; `packages/proof-checker/src/checker.zig` |
| Authority separation | Integrity, provenance, property proof, residual guards, and invariant enforcement remain distinct | `docs/user-guide.md:854`; `CONCEPTS.md:121` |
| Request isolation | Arena reset, owned module state, timeout invalidation, panic quarantine, and pool generations | `docs/internals/architecture.md:80`; `packages/runtime/src/handler_instance.zig:2161` |
| Native execution | Local native Zig binaries and current handler execution behavior | `build/artifacts.zig:35`; `packages/zts/src/interpreter.zig:193` |
| Filesystem safety | Static-file path checks remain on the serving path | `packages/runtime/src/server.zig:669`; `packages/runtime/src/server_static.zig:62` |
| Persistence | Durable replay, queue ownership, protected ledger rules, and exact authority-bearing bytes | `docs/user-guide.md:656`; `docs/user-guide.md:700` |
| Tooling | Public command outputs, diagnostic codes and locations, contracts, receipts, and editor protocol | `build/goldens.zig:47`; `build/host_tests.zig:61` |

`docs/consumer-contract.md:26` explicitly separates implemented mechanisms from the proposed consumer contract.
Its three integrated declaration stages are not implemented conformance claims.
A simplification must preserve shipped declaration classification and capability-ceiling behavior without treating every proposal obligation as existing compatibility.

## Ranked opportunities

Effort labels describe change scope, not delivery time.
Medium means a bounded cross-file change; large means a staged subsystem migration.
Confidence measures the source evidence, not a guaranteed benefit from the proposed replacement.

### 1. One graph-analysis result for check and compile

**Category:** architecture and direction. **Impact:** high. **Effort:** large. **Risk:** high. **Confidence:** high for divergence, medium for consolidation cost.

Current checking and compilation choose different analysis paths.
The check-only path shares module facts at `packages/tools/src/precompile.zig:2041` and installs imported summaries at `:2195`.
`compileHandler` branches into `compileMultiModule` before its single-module analysis at `:2674`.
That branch explicitly refuses declarations because the multi-module build performs no flow check.
`compileMultiModule` independently builds and compiles a graph at `:3423`.
`buildContractWithPolicy` accepts optional completed analysis, or constructs missing analysis itself, at `:3594`.

This structure makes feature support and analysis completion depend on the command path.
A new import-aware analysis must reach several coordinators before checking and artifact production agree.
This report does not claim that the current refusal is unsafe.
The refusal is the correct fail-closed response to an incomplete path.

**Simpler design:** one owned graph-analysis result feeds diagnostics, contracts, bytecode generation, and certificate production.
A graph with one module uses the same analysis path as a graph with imports.
The result records completed analyses and explicit unresolved conditions.
Contract production consumes completed facts rather than deciding whether it should run another checker.
Source reading, clocks, configuration loading, and output writing remain outside the analysis core.
Native Zig error unions and explicit allocator ownership remain the failure and memory conventions.

This does not require one visitor or a new generic compiler framework.
The existing `ResolvedModule`, `CheckedModule`, `ModuleFacts`, and route resolver provide the starting pieces.
Stable caller-owned storage must preserve the pointer lifetimes documented at `packages/zts/src/pipeline.zig:103`.

The previous orchestration migration was declined for lack of a concrete consumer at `packages/zts/src/pipeline.zig:18`.
This proposal has a narrower justification: current check/build divergence for imported handlers.
It must first show that shared results remove actual decision paths.
Moving all of `precompile.zig` into `zts` would violate the documented I/O boundary and is not recommended.

**Acceptance checks:** first compare both public paths on single-module handlers, preserving existing outcomes.
Then compare imported helpers, route roots, classification declarations, capability ceilings, unresolved imports, and analysis exhaustion.
Any newly accepted multi-module declaration requires separate behavior review because current compilation refuses it.
The replacement must distinguish unrun, unresolved, refused, and completed analysis states.
A deliberate omitted-analysis mutation must fail before artifact generation.

Required unfiltered steps: `test-precompile`, `test-zts-cli`, `test-agent-protocol`, `test-module-graph-record`, `test-contract-golden`, `test-diagnostic-corpus`, `test-flow-census`, and `test-zts`.
Artifact acceptance also requires `test-proof-checker`, `test-proof-ratchet`, `test-cli`, and `test-reference-tools`.

### 2. Replace typed-source stripping with a direct typed frontend

**Category:** architecture and direction. **Impact:** high potential. **Effort:** large. **Risk:** high. **Confidence:** high for duplicated representation, medium for net reduction.

Typed source currently becomes stripped text plus a `TypeMap`, then parser IR, then reconstructed types.
`packages/zts/src/source_frontend.zig:87` invokes stripping; `:91` applies TSX lowering and composes coordinate edits.
`packages/zts/src/type_map.zig:36` records annotation positions and signature identities separately from parser nodes.
`packages/zts/src/type_env.zig:569` reconnects signatures through those offsets.
`packages/zts/src/type_pool.zig:2164` parses type expressions from source text again.

This design preserves an older untyped parser while surrounding it with increasingly precise typed-source machinery.
Adding syntax can require changes to scanning, source maps, signature matching, parsing, and type reconstruction.
The current profile already uses `structural`, `nominal`, and `match`; it is not a general TypeScript compatibility promise.
`docs/roadmap.md:265` names the actual supported source identities.

**Simpler design:** parse the admitted typed grammar directly into nodes with stable type and source identities.
Attach parameter types, return types, type arguments, and original spans to their owning nodes.
Lower TSX and `comptime` results as nodes, retaining original spans.
Keep the existing runtime IR and bytecode backend during the first migration.
Delete stripping and offset-based type reconstruction only after every parser consumer migrates.

A later resolved core can make direct calls, native calls, route dispatch, and unknown calls explicit.
That core should replace repeated resolution, not merely become another representation each pass must understand.
Do not design a general SSA framework before a concrete operation requires it.
The proof IR remains a separate consumer-oriented projection.

**Acceptance checks:** begin with annotated functions, generics, and two signatures on one source line.
Include repeated nested names, explicit call type arguments, folded constants, and TSX expressions that change offsets.
Compare accepted types, refusal codes, source spans, normalization output, contracts, and runtime results.
Allocation failures and partial parses must release owned memory without emitting partial successful results.
Existing parser and stripper results are compatibility oracles, not proof that all current behavior is correct.
Separate intentional corrections from frontend replacement.

Required unfiltered steps: `test-zts`, `test-precompile`, `test-zts-cli`, `test-canonicalize`, `test-diagnostic-corpus`, and `test-contract-golden`.
Also run `test-comptime-cli-matrix`, `test-generic-intersection-cli-matrix`, `test-examples`, `test-module-boundary`, and `test-zts-layering`.
Compile `wasm` because the browser analyzer is a real second consumer of the frontend.

### 3. Separate binding semantics from runtime implementation pointers

**Category:** architecture and trust modeling. **Impact:** medium to high. **Effort:** medium to large. **Risk:** high. **Confidence:** high for structural coupling.

Binding metadata and runtime callbacks currently occupy the same records.
`packages/zts/src/module_binding/types.zig:395` mixes native pointers, signatures, capabilities, trace behavior, and provenance rules.
The SDK defines parallel metadata in `packages/zttp-sdk/src/binding.zig:201`.
`packages/zts/src/module_binding_adapter.zig:108` adapts those records into engine bindings.
The freestanding analyzer replaces callbacks with stubs at `packages/zts/src/builtin_modules.zig:101`.
`packages/zts/build.zig:66` makes the compiler depend on the engine tier.

The analyzer requires semantic facts but must import a structure that also names executable implementations.
New binding fields cross the SDK, adapter, engine, analyzer projection, specification renderer, and governance checks.
The repeated fields are current evidence of maintenance cost; no runtime overhead is claimed.

**Simpler design:** one pure producer-side semantic descriptor, with a separate runtime implementation record keyed by stable export identity.
The analyzer imports descriptors directly and needs no callback substitution.
The runtime pairs each descriptor with its implementation and state hooks.
An SDK adapter can preserve the current extension surface during migration.
The consumer checker retains independent catalogs and checks; sharing producer decisions across that boundary is forbidden.

Replace compatible provenance flag combinations with an explicit tagged return-origin rule where the current semantics permit it.
Candidate cases are fixed labels, argument-derived data, persistent-state reads, and bounded declassification.
The exact cases need a binding census before selection.
Do not infer persistent-state provenance from arguments, and do not replace unknown provenance with empty labels.
`packages/zts/src/module_binding/types.zig:489` through `:517` states why those distinctions matter.

The first extraction should preserve current labels and serialized identities exactly.
A provenance redesign is a separate change after the descriptor boundary is stable.

**Acceptance checks:** compare every export's signature, capability set, labels, replay behavior, and generated specification.
Probe direct and wrapped secret flow, storage round-trips, and runtime declassification bounds.
The same probes must include safe examples so a universal refusal cannot pass.
Verify that the browser analyzer retains no native state callbacks.

Required unfiltered steps: `test-sdk`, `test-modules`, `test-module-governance`, `test-capability-audit`, `test-manifest-alignment`, and `test-zts`.
Also run `test-flow-census`, `test-contract-golden`, `test-residual-guards-drift`, `test-proof-ratchet-drift`, and the `wasm` build.

### 4. Finish runtime ownership boundaries before changing the VM

**Category:** architecture. **Impact:** medium. **Effort:** large. **Risk:** high. **Confidence:** high for dependency coupling.

The runtime already has an engine adapter, but that adapter mostly exposes implementation types.
`packages/runtime/src/engine_adapter.zig:11` exports `HandlerInstance`, pools, contracts, and runtime configuration.
`packages/runtime/src/handler_instance.zig:23` imports HTTP, workflow, and native-call siblings.
`packages/runtime/src/runtime_http.zig:17`, `packages/runtime/src/runtime_workflow.zig:15`, and `packages/runtime/src/runtime_natives.zig:13` import `handler_instance.zig` back.
These are concrete dependency cycles, not a complaint about file size.

**Simpler design:** let `HandlerInstance` own the execution lifecycle and pass explicit borrowed capabilities to its helpers.
Start with one sibling back-import and the minimum operations that sibling needs.
Preserve synchronous calls and explicit ownership; do not introduce a universal plugin bus.
The HTTP server should consume a request-execution interface and response lifetime contract.
It should not need the engine's complete object model.

Do not replace the interpreter, value representation, hidden classes, or allocator strategy in this phase.
Those changes would expand the behavioral surface before ownership is stable.
The serving path disables collection through `packages/zts/src/context.zig:414`.
That does not prove the collector is unused by other execution modes or unnecessary for retained state.

**Acceptance checks:** exact responses and errors across direct requests, workflow calls, queue calls, replay, and AOT fallback.
Retain response borrowing rules, lease release, timeout invalidation, panic quarantine, and generation pinning.
Run real accept-path tests, not only mocked engine calls.
Preserve static path validation through `packages/runtime/src/server.zig:669` and `packages/runtime/src/server_static.zig:62`.

Required unfiltered steps: `test-server`, `test-zruntime`, `test-cli`, `test-module-scope-panic`, `test-panic-isolation`, and `test-module-boundary`.
The final suite must run sequentially where the repository requires that ordering.

### 5. Define a smaller default product without silently deleting features

**Category:** product direction. **Impact:** potentially high maintenance reduction. **Effort:** decision-dependent. **Risk:** high compatibility risk. **Confidence:** high for separable surfaces, unknown for user demand.

`pi` is a large package, but deployment already excludes it.
Studio and edge are optional in `build/Context.zig:78` and `packages/runtime/src/runtime_features.zig:1`.
Durable workflows, actor queues, tool routes, and ledger invariants are public features in `docs/user-guide.md`.
Moving those features out of the default build can simplify a distribution without simplifying their implementation.
Deleting them reduces maintenance only by removing documented behavior.

**Simpler design:** a stable handler core plus optional product modules with explicit compatibility tests.
The core contains the typed language, native HTTP runtime, built-in capability contracts, deployment artifacts, and independent proof acceptance.
Retain existing features by default during the architectural migration.
An explicitly smaller distribution can then select features without creating a second language profile.

No current usage data establishes which features customers can lose.
Repository size alone cannot answer that product question.
Extracting repositories or replacing the expert agent with a subprocess introduces version agreement and release coordination costs.
That trade needs measured benefits beyond a smaller folder tree.

**Acceptance checks:** every selected distribution builds, rejects unavailable features explicitly, and preserves the same semantics for common supported handlers.
Capability catalogs, module specifications, proof identities, and runtime artifacts must describe the selected distribution honestly.
Features excluded from deployment must not remain advertised as available.
Feature removal requires a migration guide and named lost behavior.

Required checks depend on the selected surface.
The baseline includes `test-expert-app`, `test-cassette`, `test-standin`, `test-cli -Dstudio`, `test-reference-tools`, and `test-zruntime`.
The owner must decide removals before an executor writes a deletion plan.

### 6. Simplify gate machinery only by removing duplicated authority

**Category:** verification and tooling. **Impact:** medium. **Effort:** medium. **Risk:** medium to high. **Confidence:** high for current constraints.

The build already uses a host-test table at `build/host_tests.zig:36`.
`build/step_coverage.zig` checks the actual build graph rather than names alone.
The aggregate deliberately excludes pool-heavy runtime tests; `docs/internals/testing.md:337` explains the measured macOS failure.
`scripts/verify.sh:5` preserves sequential process boundaries for that reason.
A single parallel aggregate would remove an important constraint, not merely boilerplate.

**Simpler design:** retain one declared inventory of obligations and evidence, then derive registration and reporting where appropriate.
Keep independent behavioral checks for claims the inventory cannot establish.
Replace source-text coupling when a changed subsystem exposes a small machine-readable fact directly.
Do not replace every shell gate merely to make tooling uniform.
Touched legacy Python tooling should migrate to Zig under repository policy.

**Acceptance checks:** mutate the gate's inputs and demonstrate the claimed refusal.
Deleting a test root, verdict case, registry row, or required artifact must fail the relevant gate.
A replacement must keep nonempty-input floors and exact behavioral assertions.
It must not use its own manifest as the sole proof that the manifest is complete.

Required unfiltered steps: `test-step-coverage`, `test-script-reachability`, `test-diagnostic-producers`, `test-invariant-gate`, and `test-invariant-drift`.
Retain `test-proof-checker-mutants` and the flow census as adversarial checks over the affected trust boundaries.

## Competing architectures

### Option A: preserve the product and replace internal boundaries

Keep the current language, VM, native modules, runtime, and independent checker.
Converge analysis results, introduce a direct typed frontend, and separate binding metadata from runtime callbacks.
This option has the clearest migration path and permits comparison against current artifacts at each boundary.
It is the recommended architecture.

### Option B: a smaller certified handler product

Retain HTTP handlers, types, native capabilities, contracts, local deployment, and independent acceptance.
Remove selected expert, UI, edge, workflow, or application features after owner selection.
This can remove entire maintenance surfaces, but it changes the product rather than merely simplifying its internals.
The correct feature set cannot be inferred from source size.

### Option C: a new execution kernel

Lower the current typed surface into a smaller explicit core with a new value and execution model.
Keep proof acceptance independent and relate accepted source to the new executable form.
This could reduce inherited JavaScript machinery, but closure behavior, built-ins, modules, replay, and proof translation all require new evidence.
No measured result currently justifies replacing the VM or bytecode format.
This option belongs in a bounded prototype after Option A supplies stable frontend and semantic boundaries.

A direct Zig source backend or WebAssembly backend is also possible in principle.
Neither is a demonstrated simplification here.
Both introduce a new translation boundary and runtime integration work before removing the current implementation.
The existing 96-line WebAssembly policy skeleton is not such a backend.
The browser analyzer is a separate existing consumer and must not be confused with that skeleton.

## Feature preservation and optional removal matrix

| Feature | Recommended treatment | Lost behavior if removed | Required decision or evidence |
|---|---|---|---|
| HTTP handlers and local native binaries | Preserve | Core product disappears | No removal proposed |
| Current typed language and TSX | Preserve; replace frontend internals | Existing handlers require rewrites | Versioned language change if scope narrows |
| Independent acceptance kernel | Preserve | Producer claims become runtime authority | No removal proposed |
| Artifact integrity and attestation | Preserve distinctions | Offline acceptance or provenance workflows disappear | Explicit product decision for any removal |
| Rich contract JSON and diagnostic protocol | Preserve external forms | Editors, automation, goldens, and consumers break | Inventory external consumers first |
| Expert agent | Keep optional and in-tree initially | Compiler-guided generation, repair, sessions, and evidence disappear | Owner selects product scope |
| Studio | Keep optional | Browser proof workbench disappears | Owner selects UI scope |
| Edge runtime | Keep optional | Multiple handlers behind one listener disappear | Owner selects deployment topology |
| Durable workflow and queue dispatch | Preserve | Persistent orchestration and recovery disappear | Owner confirms application requirements |
| Actor queues | Preserve | Process-owned mailbox communication disappears | Owner confirms application requirements |
| Ledger invariants | Preserve | Protected posting checks and independent call coverage disappear | Owner confirms protected-state scope |
| Tool and agent routes | Preserve shipped subset | Catalog, grants, agent entry behavior disappear | Separate shipped behavior from M5 plans |
| Native extension SDK | Preserve | Third-party native module integration disappears | External usage census required |
| AOT fast paths | Keep until measured | Selected precompiled fast paths disappear | Runtime parity and performance measurements |
| Garbage collector | Keep until measured | Non-serving lifecycle behavior may break | Allocation and retained-state measurements |
| Policy WebAssembly skeleton | Small optional cleanup only | Reserved unavailable API disappears | External API decision; no large saving |
| Proposed consumer-contract integration | Do not add during reset | No shipped behavior disappears | Separate product roadmap decision |

## Smallest first proof of simplification

The first experiment should converge analysis for one existing single-module compile path.
It should not begin with a new parser, VM, artifact format, or product cut.

I recommend one shared analysis result consumed by check output and single-module compilation.
A small fixture set should include direct responses, Result refusal, routed secret flow, a safe routed handler, and incomplete path analysis.
Use frozen expected outcomes, not only equality between two potentially incorrect implementations.
A deliberate skipped-flow mutation must fail the routed leak case.
A deliberate incomplete-to-complete mutation must fail the coverage case.

Success requires one coordinator or fallback analysis path to disappear from production.
The result must preserve public outputs, property grades, refusal behavior, and ownership cleanup.
Measure changed production decision points with the existing AST tool before and after.
Count the new code as well as the removed code.
Measure compile time and allocation behavior if the experiment claims either benefit.
No performance claim is required to justify removal of duplicated authority.

First validate the fixture harness with a run that completes in under one minute.
Then widen only the corpus scope.
Any command expected to exceed two minutes requires the owner's approval under repository instructions.
This audit did not start those commands.

## Phased proposal

**Phase 0: select the compatibility boundary.**
The owner confirms preserved features and whether artifact rebuilds may accompany later internal changes.
The executor records public command, source, contract, artifact, and runtime fixtures before production edits.
The executor confirms that deliberate wrong outcomes fail the selected fixtures.

**Phase 1: converge the existing compilation paths.**
The executor introduces one owned analysis result for an existing single-module path.
The executor removes redundant coordination and preserves each analysis's separate state.
After equivalence holds, the executor extends the same result to the existing module graph.
The owner reviews any previously refused program that becomes accepted.

**Phase 2: separate semantic metadata.**
The executor extracts pure binding descriptors and keeps runtime callbacks in the runtime registration layer.
The analyzer's callback-stub projection becomes unnecessary.
Only then does the executor evaluate a tagged provenance representation.
The consumer's independent catalog remains separate throughout.

**Phase 3: prototype the direct typed frontend.**
The executor replaces a small annotated-function slice while targeting the current IR and backend.
The executor compares source spans, types, diagnostics, normalized output, contracts, and execution.
The owner selects broader migration only if the prototype removes representation work and meets the compatibility checks.
The old frontend is deleted after complete migration, not left as a permanent alternate profile.

**Phase 4: finish runtime ownership and measure execution costs.**
The executor removes one proven sibling dependency cycle at a time.
The executor measures allocator retention, AOT benefit, bytecode dispatch, and startup only against named workloads.
The owner selects any VM, GC, or AOT changes from those measurements.

**Phase 5: select optional product cuts.**
The owner decides which public features the product no longer needs.
The executor removes complete selected surfaces and their advertisements in separate compatibility changes.
The executor retains evidence tests for the surviving product.

Each phase has an independent stop condition.
Stop when the replacement adds representation layers without removing an existing authority or ownership burden.
Stop when equivalence requires silently weakening a proof, changing a source profile, or discarding a supported feature.

## Verification commands and limits

These are future acceptance commands, not results from this audit.
Each command names an unfiltered build step.
Capture logs directly and retain each command's exit status.
Do not pipe a build through `tail` and report the pipeline's final status.

Compiler and frontend work:

```sh
zig build test-zts
zig build test-precompile
zig build test-zts-cli
zig build test-agent-protocol
zig build test-module-graph-record
zig build test-contract-golden
zig build test-diagnostic-corpus
zig build test-flow-census
zig build test-canonicalize
zig build test-comptime-cli-matrix
zig build test-generic-intersection-cli-matrix
zig build test-examples
zig build test-module-boundary
zig build test-zts-layering
zig build wasm
```

Binding and proof work:

```sh
zig build test-sdk
zig build test-modules
zig build test-module-governance
zig build test-capability-audit
zig build test-manifest-alignment
zig build test-proof-checker
zig build test-proof-checker-purity
zig build test-proof-checker-mutants
zig build test-proof-ratchet
zig build test-proof-ratchet-drift
zig build test-residual-guards-drift
zig build test-invariant-gate
zig build test-invariant-drift
zig build test-kernel-safety
zig build test-proof-swallow
```

Runtime and product work:

```sh
zig build test-server
zig build test-zruntime
zig build test-cli
zig build test-module-scope-panic
zig build test-panic-isolation
zig build test-reference-tools
zig build test-expert-app
zig build test-cassette
zig build test-standin
zig build test-cli -Dstudio
zig build test-step-coverage
zig build test-script-reachability
zig build test-diagnostic-producers
```

The final integration check remains `bash scripts/verify.sh`, after required approval for its runtime.
Its explicit sequencing is part of the check, especially on macOS.

Existing tests cannot alone establish rewrite equivalence.
`docs/internals/testing.md:359` states that ordinary source coverage is unavailable with the pinned toolchain.
A large test count therefore does not establish complete behavior coverage.
Filtered tests can run zero matching cases and are not evidence.
Contract goldens check selected outputs, not all runtime behavior.
The opcode corpus checks selected interpreter semantics; it no longer compares independent execution tiers.
Generated tests share analysis assumptions with their generator.
A mutually consistent producer and encoder can still generate an incorrect artifact.
The independent checker and pinned wire vectors must remain separate evidence.

Mutation suites establish only the changed decisions their mutations reach.
The gate history demonstrates why a census of verdict cases matters more than a count of test files.
See `docs/solutions/conventions/a-gate-can-be-non-vacuous-and-still-porous.md:197`.
A rewrite needs public negative cases, safe contrasts, and exact expected values at every changed trust boundary.

## Tempting changes to reject now

Do not merge producer proof logic into the acceptance kernel.
The proof IR deliberately models fewer concepts than parser IR at `packages/zts/src/proof_ir.zig:1`.
`packages/zts/src/translation_witness.zig:1` relates that projection to final bytecode.
Those representations serve different trust purposes and are not ordinary duplication.

Do not merge all analysis passes into one visitor.
They have different state, order, and proof obligations, documented at `docs/internals/architecture.md:135`.
Share resolved facts and explicit roots while retaining separate conclusions.

Do not remove the GC because HTTP requests use arenas.
That observation does not measure every retained object lifetime or embedding mode.
Do not resurrect JIT deduplication from a plan whose tiers no longer exist.
Do not claim that extracting `pi` shrinks deployed binaries.
Do not replace the current native runtime with a general JavaScript engine or WebAssembly backend without an explicit compatibility and trust proposal.

Do not remove tests merely because they dominate a large source file.
Remove redundant test mechanisms only after a smaller suite detects the same named incorrect behaviors.
Do not pursue another generic orchestration layer whose only consumer is its own constructor.
Do not implement proposed consumer-contract stages as part of simplifying existing behavior.

## Owner decisions

**Decision 1: compatibility scope. Accepted: Option A.**
Option A preserves every documented current feature and changes internal boundaries. Recommended.
Option B selects a smaller handler product and explicitly removes named features from the matrix.

**Decision 2: first substantial investment. Accepted: Option A.**
Option A starts with shared graph analysis and the bounded proof described above. Recommended.
Option B begins the direct typed frontend experiment first, accepting greater diagnostic and syntax migration risk.
Option C begins a new VM, requiring a separate execution-compatibility study before implementation.

**Decision 3: artifact migration policy. Accepted: Option A.**
Option A preserves current wire formats during the first convergence phases. Recommended.
Option B permits an explicit format change and rebuild requirement when a later replacement needs one.
Old artifacts must never silently acquire new proof authority under either option.

Decisions 1, 2, and 3 are accepted. The repository owner owns the next action: review the bounded implementation plan.

## Root validation appendix

The root agent independently reviewed the principal source findings and supplied the following validation results.
These measurements are attributed to the root agent; the report author did not run them.
The source baseline remained `38a0782fba69dafb3dec4a0974a828cb2bdca1bf` throughout that validation.
No tests or benchmarks ran. The root agent did run the existing source metric.

The root agent first ran the small input:

```sh
zig run tooling/production_branch_metric.zig -- packages/tools/src/precompile_args.zig
```

The command exited 0 and parsed one file without failures.
It reported 45 production branches and six production functions.
The root agent then ran the full input with the same metric:

```sh
bash scripts/run-production-branch-metric.sh --json
```

The command exited 0 and parsed 643 files without failures.
It reported 71,062 production branches and 11,582 production functions.
The combined score was 82,644. The metric separately reported 6,091 test branches.

| Metric scope | Production branches | Production functions |
|---|---:|---:|
| zts | 34,091 | 4,931 |
| runtime | 11,437 | 2,168 |
| tools | 8,368 | 1,202 |
| pi | 11,934 | 2,176 |
| proof-checker | 1,435 | 379 |
| proof-review | 362 | 81 |
| modules | 2,284 | 291 |
| zttp-sdk | 155 | 159 |
| Repository files outside those packages | 996 | 195 |
| Total | 71,062 | 11,582 |

The full metric covers 643 files, including repository files outside the package source census.
The earlier physical-line census covers 616 tracked Zig files under `packages/`.
Those scopes differ and must not be treated as competing measurements of the same input.

These counts are maintenance signals, not reducible amounts, per-function complexity, test coverage, or runtime measurements.
The metric includes test helpers defined outside test blocks in its production count.
No percentage of removable code or predicted performance improvement follows from these results.

The root agent confirmed check/build divergence at `packages/tools/src/precompile.zig:2674`.
The root agent confirmed frontend reconstruction at `packages/zts/src/source_frontend.zig:87`, `packages/zts/src/type_env.zig:569`, and `packages/zts/src/type_pool.zig:2164`.
The root agent confirmed binding metadata coupling, analyzer callback substitution, and the compiler's engine dependency.
The corrected dependency citation is `packages/zts/build.zig:66`.
The SDK binding record begins at `packages/zttp-sdk/src/binding.zig:201`.
The engine mapping begins at `packages/zts/src/module_binding_adapter.zig:108`.

The root agent also confirmed runtime back-imports, deployment exclusion of `pi`, gate sequencing, and the artifact-format discrepancy.
These checks strengthen the architectural evidence but do not establish behavioral equivalence for any proposed replacement.
The report remains advisory. Saving this proposal changes documentation only.

Decisions 1, 2, and 3 are accepted. The repository owner owns the next action: review the bounded implementation plan.

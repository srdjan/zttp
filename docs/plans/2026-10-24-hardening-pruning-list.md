# Hardening and pruning list, round 4

What this repo does: zttp checks restricted TypeScript handlers, compiles accepted handlers, and serves HTTP requests.
The expert loop proposes changes and checks each change before a workspace write.
This audit assumes repeated requests, reused runtime instances, and developer sessions that must preserve source files and receipts.

Status: audit list at source commit `d7aaf1f4`, dated 2026-10-24.
The owner requested discovery before more features. This report makes no production code change and authorizes no later implementation.
The [worklog](2026-10-24-hardening-pruning-worklog.md) records checks and exclusions.
The unfiltered aggregate passed with 212 successful steps. Final documentation link and spine checks also passed.

## Scope and evidence

The audit covers runtime ownership, JSON handling, replay, proof defaults, type parsing, provider decoding, test roots, and repository gates.
The main agent read the build graph, package dependencies, standing decisions, and previous pruning records.
Three read-only Sol agents reviewed separate areas. The main agent checked each retained agent finding against source and callers.
The expert-loop agent stopped after a preliminary report because the model reached capacity.
The main agent checked that report and reviewed provider duplication directly.

An observed finding has an executable probe. A source finding has a specific failure path but no new regression probe.
A deletion candidate needs a current producer census and a comparison before removal.
No claimed saving comes from an estimate. Runtime savings still need measurement.
The tracked report uses file and symbol references because the spine gate rejects source references by line number.

The [round 3 worklog](2026-10-23-pruning-round-3-worklog.md) closes most earlier hardening and deletion work.
The list below retains only current findings and selected open carryovers.
The accepted decisions in [the decision ledger](../decisions.md) remain binding.

## Must fix

### 1. A failed hidden-class allocation can damage the reused context

What this is: `HiddenClassPool` stores object layouts in parallel arrays.
Source: `packages/zts/src/object.zig`, `allocClass` and `addProperty`; `packages/zts/src/builtins/json.zig`, `jsonParse`.

Problem: `allocClass` increments `count` before four fallible appends. An allocation failure can leave the arrays with different lengths.
`addProperty` also publishes class metadata before later allocations finish. A subsequent lookup can use an index without corresponding array entries.
`JSON.parse` returns `undefined` on the original error, so the context can remain available for reuse.

Fix: reserve all required storage before publishing a class or transition. Use infallible appends after reservation.
An allocation-failure test must retry an object operation in the same context and check the exact result.

If skipped: a recoverable allocation failure can become a later bounds failure or unsafe access under unchecked optimization.
Evidence: source review; allocation-failure reproduction remains required.
Reach: class metadata, property storage, transition and sorted indexes, JSON callers, and context reuse tests.
Gates: `test-zts`, `test-zruntime`.

### 2. Runtime reuse does not bound retained object layouts

What this is: a hidden class records property names and their order. The context retains hidden classes across requests.
Source: `packages/zts/src/builtins/json.zig`, `buildClassForAtoms`; `packages/zts/src/object.zig`, `HiddenClassPool`.
The release policy lives in `packages/runtime/src/runtime_pool.zig`, `releaseForRequest`.

Problem: JSON objects with different key orders create different classes. Evicting a JSON cache entry does not free the retained class.
Under `reuse_unbounded`, the pool recycles only when the atom count reaches its threshold.
Permutations of existing names can create more classes without adding atoms.

Fix: include retained class count in the existing recycle decision. Choose the threshold from a small permutation workload and measured retention.
Tests must show class growth with a stable atom count, then confirm pool recycling.

If skipped: repeated input shapes can retain memory until context teardown or allocation failure.
Evidence: source review; retained bytes and request cost need measurement.
Reach: JSON shape creation, pool thresholds, release tests, and pooling limits in `docs/contracts-and-sandboxing.md`.
Gates: `test-zts`, `test-zruntime`, `test-server`, `bench-check`.
Carryover: round 2 A13, hidden-class growth.

### 3. Replay can accept a partial recorded value

What this is: replay converts recorded JSON into engine values, then checks for behavior changes.
Source: `packages/zts/src/trace.zig`, `parseArray`, `parseObject`, and `replayRecordedEntry`.

Problem: array insertion, object registration, atom creation, and property insertion discard allocation errors.
The decoder can return a defined but incomplete value. The caller counts a divergence only for an unexpected `undefined` result.

Fix: propagate decoding failures and reject incomplete consumption. Keep the existing outer JSON validation and replay representation.
Tests must inject allocation failures into arrays and objects, then require an explicit replay failure.

If skipped: replay can report agreement while executing with data that differs from the recording.
Evidence: source review; allocation-failure probes remain required.
Reach: trace decoding, replay stubs, `Date.now`, `Math.random`, and `packages/runtime/src/replay_runner.zig`.
Gates: `test-zts`, `test-zruntime`, `test-server`.
Carryover: round 2 C10, replay JSON; this bounded repair precedes any parser consolidation.

### 4. The documentation link gate passes when its scan fails

What this is: `scripts/audit-docs.sh` checks tracked Markdown links and local anchors.

Problem: an empty tracked inventory reports success. A Perl scanner failure also reports success because process substitution hides the scanner status.
An isolated repository with one broken link exited 1. The same repository exited 0 when its Perl scanner exited 2.
An empty repository also exited 0.

Fix: capture and check the inventory and scanner exit statuses. Require a nonempty checked inventory before success.
Keep the existing link rules. Add rejection probes for empty input and scanner failure.

If skipped: `test-doc-links` can claim a successful check when no link scan completed.
Evidence: observed in temporary repositories. The main agent read each exit status directly.
Reach: `scripts/audit-docs.sh`, gate probes, script reachability, and the build route for `test-doc-links`.
Gates: `test-doc-links`, `test-native-gates`, `test-script-reachability`.

### 5. A metric command overwrites earlier redirected output

What this is: `tooling/production_branch_metric.zig` writes the branch count to standard output.

Problem: `main` uses a positional file writer. When standard output already contains a prefix, the metric replaces that prefix.
The probe wrote `retained-prefix`, then ran the metric against `build.zig`. The command exited 0, but the prefix disappeared.

Fix: use `writerStreaming`, as `tooling/agent_spine.zig` already does. Propagate the final flush error.
Extend the existing stream probe in `build/tooling.zig` to cover the metric.

If skipped: redirected verification logs can lose earlier evidence.
Evidence: observed with the current source. Four other evidence tools use positional stdout writers and need the same probe before classification.
Reach: the metric command, its stream probe, and the stdout audit of evidence publication tools.
Gates: `test-production-branch-metric`, `test-native-gates`.

## Should fix

### 6. The binding type parser ignores trailing input

What this is: `parseTypeExpr` reads type strings from native module signatures.
Source: `packages/zts/src/type_pool.zig`, `parseTypeExpr`; `packages/tools/src/precompile_check.zig`, signature validation.

Problem: `parseTypeExpr` returns `parseUnion()` without requiring the end of the source.
A signature such as `boolean junk` receives the type of its valid prefix. The signature gate accepts that type.
Current production input comes from trusted binding metadata, which limits the exposure.

Fix: skip trailing whitespace, then require complete consumption. Add parser rejection and signature-gate rejection tests.
Preserve valid binding signatures before attempting to remove the second parser.

If skipped: malformed binding metadata can pass validation with different semantics from its complete text.
Evidence: source review; a public signature rejection probe remains required.
Reach: `module_types.populateModuleTypes`, `path_generator.returnsOkRecord`, the signature census, and binding fixtures.
Gates: `test-zts`, `test-modules`, `test-precompile`, `test-contract-golden`.
Related carryover: round 2 C4, two type parsers.

### 7. Predicate parsing has two conflicting authorities

What this is: a type predicate lets a successful check narrow a parameter's type.
Source: `packages/zts/src/parser/type_syntax.zig`, `predicateHeader`; `packages/zts/src/type_env.zig`, `directPredicateMarkerMatches`.

Problem: the parser accepts tabs and newlines around `is`. The environment builder searches only for the literal text ` is `.
A parsed predicate with tabs then loses its narrowing meaning. Existing frontend cases explicitly expect this loss.

Fix: use the validated predicate spans instead of classifying the same text again.
Update the parity cases to require the intended narrowing and preserve diagnostics for malformed predicates.

If skipped: whitespace changes can change type meaning, and both classifiers require maintenance.
Evidence: source and existing test expectations.
Reach: direct return syntax, type environment population, frontend parity tests, and CHECK diagnostics.
Gates: `test-zts`, `test-precompile`, `test-diagnostic-corpus`.
Carryover: round 2 A10, return-predicate classifiers.

### 8. Six proof properties still default to proven

What this is: `HandlerProperties` carries the compiler's property claims.
Source: `packages/zts/src/contract_types.zig`, `HandlerProperties`.

Problem: six fields still default to `true`. A partially initialized value therefore claims a proof before the corresponding pass supplies evidence.
Runtime promotion requires independent acceptance, which limits the authority of these defaults.

Fix: start all six fields at `false` and let completed passes establish them.
This changes the model-visible `holes` list. The owner must select the required real-provider recording work before execution.

If skipped: callers must remember which default claims need correction, and serialized claims can overstate completed analysis.
Evidence: source and the explicit deferral in the round 3 worklog.
Reach: contract construction, JSON defaults, tool output, contract hashes, goldens, and empirical cassettes.
Gates: `test-zts`, `test-precompile`, `test-contract-golden`, `test-expert-app`, `test-cassette`, `test-standin`.
Carryover: round 3 H10, default proof properties. The earlier `state_isolated` and `canonical` caller fixes remain closed.

### 9. String construction does not enforce one representable length

What this is: constructors accept a `usize` length, store a `u32`, and expose a signed `i32` length to handlers.
Source: `packages/zts/src/string.zig`, the three string constructors; `packages/zts/src/interpreter/cmp.zig`, string length handling.

Problem: construction performs unchecked narrowing casts. A value above the signed length limit cannot have a valid handler-visible length.
Values above the storage limit also make unchecked-build metadata inconsistent with the allocation.
This boundary case was not exercised with a large allocation during the audit.

Fix: check one supported maximum before allocation at every constructor. Preserve the existing allocator-error and arena-null conventions.
Test the bound through a small length-check helper, without allocating a huge buffer.

If skipped: oversized engine or SDK input can cause a checked panic or invalid metadata under unchecked optimization.
Evidence: source review; a complete constructor and concatenation census remains necessary.
Reach: interned strings, owned strings, arena strings, concatenation, and SDK entry points.
Gates: `test-zts`, `test-sdk`, `test-modules`, `test-zruntime`.
Carryover: round 2 A12, unchecked length casts.

### 10. Delete the unused proof-review printer scaffolding

What this is: `packages/proof-review/src/printer.zig` contains `Printer`, `Progress`, `BufferedPrinter`, and clock helpers.

Problem: only their own tests use these abstractions. The comments describe removed provisioning and OCI progress flows.
Production callers use `FdWriter` directly.

Fix: delete the unused types, clock helpers, and six tests. Keep `FdWriter` and its error handling.
The measured removable ranges contain 204 lines before the replacement header.

If skipped: dead output and timing abstractions retain tests and obsolete product assumptions.
Evidence: repository-wide caller search, followed by direct review of the whole file and live `FdWriter` callers.
Reach: `printer.zig` and its header. Preserve callers in `proofs_cli.zig` and `live_reload.zig`.
Gates: `test-proof-review`, `test-cli`, `test-server`.

### 11. Share identical provider response validation

What this is: the DeepSeek and local clients decode the same common response fields.
Sources: `packages/pi/src/providers/deepseek/client.zig` and `packages/pi/src/providers/local/client.zig`.

Problem: `optionalString`, `requiredString`, `nonEmpty`, `decodeUsage`, and `optionalTokenCount` have identical bodies.
The clients also duplicate tool-argument and depth validation. A correction to malformed input requires edits in both clients.

Fix: share only identical response-field and validation helpers. Reuse the existing provider directory and common error vocabulary.
Keep provider-specific transport, endpoint validation, reasoning handling, and local tool-envelope recovery separate.

If skipped: input validation can drift between providers, and the same edge cases require duplicate maintenance.
Evidence: direct comparison of the helper bodies and their callers.
Reach: both clients, provider error declarations, response fixtures, cassette decoding, and model-visible tool output.
Gates: `test-expert-app`, `test-cassette`, `test-recorder-smoke`, `test-simulator`.
Carryover: round 2 C3, provider decoding. Require byte-identical outputs and offline replay before completion.

### 12. Stop repeating complete test families in the aggregate

What this is: `build/host_tests.zig` registers standalone roots and makes every root an aggregate dependency.

Problem: `packages/pi/src/tests.zig` imports cassette and simulator test files that standalone roots import again.
`agent_protocol.zig` also imports `precompile.zig` and `canonicalize.zig`, which have separate roots.
This audit's unfiltered `test-agent-protocol` run passed 535 tests and reported one minute for execution.
That measurement establishes the root's cost, not the amount removable from the aggregate.

Fix: compare collected test inventories, then assign each test family one aggregate execution route.
Keep useful standalone steps. Preserve the independent runtime process and nonempty-selection checks.

If skipped: aggregate verification repeats already-covered work, which slows each cleanup cycle.
Evidence: import graph and one named-suite measurement. Exact overlap and aggregate time savings still need measurement.
Reach: aggregate dependencies, host test registration, test-selection probes, `agents.json`, and `docs/internals/testing.md`.
Gates: `test-cassette`, `test-simulator`, `test-agent-protocol`, `test-step-coverage`, `test-spine`, `test`.
Carryover: round 2 C12 and round 3 K3, repeated test roots.

### 13. Replace duplicate generated-document comparisons with their renderer

What this is: `module-spec-render --check` already compares typed bindings with module specifications and the generated catalog.
Sources: `packages/tools/src/module_spec_cli.zig`; `scripts/check-docs-drift.sh`, the initial module-catalog comparison.

Problem: the shell gate independently parses the generated JSON and catalog with `awk`.
The same generated fields therefore have two comparison implementations and two sets of formatting assumptions.

Fix: make the existing renderer check an aggregate dependency, then delete only the redundant catalog extraction.
Keep the unrelated CLI, source census, and documentation checks in the shell gate.

If skipped: generated field changes require synchronized parser edits instead of one typed comparison.
Evidence: source comparison. The renderer currently has a full-verification route, so aggregate coverage must precede deletion.
Reach: renderer route, shell gate, build graph, verification routes, script classification, and docs.
Gates: `test-docs-drift`, `test-module-governance`, `test-step-coverage`, `check-spine`, `test`.
Carryover: round 2 C8, duplicated drift machinery. The other grammar and idiom checks need separate typed comparisons.

### 14. Build native gates through the existing graph

What this is: several scripts compile Zig tools even when the outer Zig build already owns their execution.
Sources: `scripts/check-kernel-safety.sh`, `scripts/check-residual-guards.sh`, and `scripts/run-production-branch-metric.sh`.

Problem: their `zig run` commands repeat compiler setup outside the declared tool graph.
The branch metric already has a build module for its tests. Other native gates already accept build-produced executables.

Fix: pass emitted tool paths from build steps, using the existing native-gate pattern.
Keep direct script entry points where documented. Preserve all file inventories, floors, probes, and script routes.

If skipped: native tool ownership stays split between scripts and build modules, with repeated compilation setup.
Evidence: source graph. Compilation savings need cold and warm measurements before changing the routes.
Reach: `build/tooling.zig`, repository and proof gate wiring, scripts, task classification, and runtime-safety probes.
Gates: `test-native-gates`, `test-kernel-safety`, `test-residual-guards-drift`, `test-production-branch-metric`, `test-script-reachability`, `test-step-coverage`.
Carryover: round 2 C9, nested native gate compilation.

## Nice to have

### 15. Remove unreachable language representations as a separate identity change

What this is: IR tags and bytecode opcodes still represent source forms that the parser refuses or the compiler never emits.
Sources: `packages/zts/src/parser/ir.zig`, `NodeTag`; `packages/zts/src/bytecode.zig`, the opcode enum.

Problem: dead representations retain interpreter arms, verifier rules, proof tables, and walker cases.
The runtime reviewer found 15 opcode names without emitter calls. The main agent did not independently repeat that complete census.

Fix: generate the current producer census first. Remove one proven-dead family and all exact consumers in an isolated unit.
Preserve serialized identities until that unit explicitly updates its formats and hash pins.

If skipped: future changes must continue to distinguish live behavior from retained representations.
Evidence: candidate with checked consumer categories; the complete main-session emission census remains required.
Reach: parser and compiler production, interpreter, verifier, semantic registries, proof tables, fixtures, metadata, and artifact compatibility.
Gates: `test-zts`, `test-meta-drift`, `test-flow-census`, `test-contract-golden`, `test-proof-checker`, `test-zruntime`, `test-cassette`.
Carryovers: round 2 C1, unused IR tags, and C2, unused opcodes. Do not combine these with routine deletion work.

### 16. Reconcile plan statuses with the completed work

What this is: `docs/plans/README.md` lists the current status of earlier pruning work.

Problem: it still says round 3 decision 5 is open and the worklog records only the first unit.
The worklog records the selected decision, completed units, final gates, and later corrections.

Fix: update the index from the worklog. Keep historical findings as dated evidence and link the remaining work to this list.

If skipped: the next cleanup can repeat completed work or treat an accepted decision as unresolved.
Evidence: direct comparison of the index and round 3 worklog.
Reach: the plans index and current audit links. No production behavior or historical plan needs removal.
Gates: `test-doc-links`, `check-spine`.

## Execution order and preservation rules

First: findings 4 and 5 restore reliable check results and logs.
Second: findings 1 to 3 repair runtime failure handling and retained state.
Third: findings 6, 7, and 9 tighten existing boundaries.
Fourth: findings 10 to 14 remove dead scaffolding and repeated work.
Finding 8 needs a separate recording decision. Finding 15 needs a separate compatibility plan.
Finding 16 can accompany the next accepted implementation plan.

Each selected change starts with a failing behavior probe or a measured caller and producer census.
Each unit preserves valid public behavior, error handling, request isolation, and the independent acceptance kernel.
Each unit runs its named gates, the unfiltered aggregate, and `check-spine` before completion.
The complete local verification claim requires `bash scripts/verify.sh`.
This list requests no new framework, provider, configuration system, or architecture layer.
Rebasing here means reducing the design. No Git history rewrite is proposed.

## Exclusions and unresolved investigations

The `.zttp` symlink concern is excluded. The current installed CLI refused the probe with `NotDir` before creating an outside lock.
The probe supports that specific case; it does not establish every transaction path's safety.

The imported-export lookup concern remains an investigation. The analyzer reviewer admitted nested and duplicate exports but did not obtain a false proof.
The relevant function is `packages/zts/src/pipeline.zig`, `flowExportedFunctionNode`.
The next check must demonstrate wrong target selection with a security-property regression before assigning defect status.

The JSON parsers keep their different public semantics. `zttp:json` preserves ordered dictionaries, null, duplicate refusal, and detailed errors.
The `JSON.parse` surface has different behavior. Their existence alone does not justify a merge.

The module registries retain compile-time ordering and completeness checks. No measured simplification justifies weakening those checks.
The accepted bounded reuse behavior for writable builtin objects stays unchanged.
The separate CHECK traversals remain under standing decision D-006.
The annotation admission scanners remain a separate parser project. Their live compatibility paths are not deletion candidates yet.

Verdict: fix partial state and false passes first, then remove dead scaffolding and duplicated execution.
Lean: 204 source lines are identified for deletion before a replacement header; no dependency removal is established.
No total saving is claimed for consolidation or representation removal.

Not checked: every source file, exhaustive transaction attacks, allocation-failure execution, retained-memory measurements, remote providers, and cross-platform runtime behavior.
The audit did not run the full sequential verification driver.
Next action: the owner selects implementation scope; the next implementing agent prepares the corresponding probes and bounded plan.

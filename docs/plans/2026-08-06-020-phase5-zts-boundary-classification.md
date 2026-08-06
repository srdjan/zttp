# Phase 5 ZTS boundary classification

Status: classification complete; migrations pending

Date: 2026-08-06

Snapshot: `main` at `267376fe20c64f482a84d75f06dbb6fdbfca6894`

Parent plan: `docs/plans/2026-08-04-019-code-quality-rebase-plan.md`, Phase 5

## Scope

This record classifies every permitted reach from `runtime`, `tools`, `pi`, and
`proof-review` into the internal tier of `packages/zts/src/root.zig`. It names
the live consumers and the surface they use, then selects the first boundary
migration for a separate reviewable change.

The parent plan measured 102 reaches. Phase 2 removed the dead
`runtime interpreter` reach in commit `9ccea64c`, so this snapshot starts at
101:

| Consumer | Reaches |
|---|---:|
| `runtime` | 32 |
| `tools` | 48 |
| `pi` | 19 |
| `proof-review` | 2 |
| Total | 101 |

This record does not change `packages/zts/src/root.zig`, consumer imports, or
`scripts/module-boundary.allow`. The 101-row count remains the active ceiling
until a later migration deletes rows.

## Method

The inventory uses `scripts/module-boundary.allow` as its row set and checks
each row against live `@import("zts")` access under the corresponding consumer
package. "Used surface" lists the imported module members rather than every
call site. File references name the primary consumer files and are evidence for
the classification, not an exhaustive index of test-only calls.

Each reach has one primary capability:

- `compile`: compiler pipelines, bytecode production, and build-time analysis
- `parse`: parser IR and syntax processing
- `execute`: runtime values, bytecode execution, tracing, and runtime state
- `contract`: contract models, comparison, routing, and service schemas
- `verify/proof`: proof generation, discharge, semantics, and witnesses
- `diagnostics/policy`: diagnostics, registries, repair policy, and governance
- `modules/linking`: module manifests, bindings, resolution, and system linking
- `storage/io`: filesystem, SQLite, and persistence helpers
- `support/types`: shared representation or compatibility helpers

The disposition is `port candidate` for a cohesive engine capability,
`keep internal` for representation and execution machinery, or
`separate owner` for shared platform helpers that do not belong on the stable
ZTS surface.

## Inventory

### Runtime

| Internal module | Capability | Used surface | Primary evidence | Disposition |
|---|---|---|---|---|
| `arena` | support/types | `Arena`, `HybridAllocator` | `packages/runtime/src/handler_instance.zig:154` | keep internal |
| `bool_checker` | diagnostics/policy | `getSourceLine` | `packages/runtime/src/live_reload.zig:1017` | port candidate |
| `builtin_modules` | modules/linking | `all` | `packages/runtime/src/handler_instance.zig:797` | keep internal |
| `builtins` | execute | builtin initialization, JSON conversion, string access, type errors | `packages/runtime/src/handler_instance.zig:29` | keep internal |
| `bytecode` | execute | bytecode, opcodes, handler patterns, line entries | `packages/runtime/src/handler_instance.zig:126` | keep internal |
| `bytecode_cache` | compile | cache keys, slice readers and writers, bytecode serialization | `packages/runtime/src/handler_instance.zig:56` | keep internal |
| `compat` | support/types | clocks, timers, mutexes, and read-write locks | `packages/runtime/src/engine_adapter.zig:22` | separate owner |
| `context` | support/types | `AtomTable`, cost meter | `packages/runtime/src/contract_runtime.zig:17` | keep internal |
| `contract_diff` | contract | diff types, classification, `claimScope`, `diffContracts` | `packages/runtime/src/live_reload.zig:23` | port candidate |
| `counterexample` | verify/proof | witness types, `solve`, `writeJsonl` | `packages/runtime/src/replay_runner.zig:388` | port candidate |
| `equivalence_receipt` | verify/proof | `Verdict`, `sign` | `packages/runtime/src/equivalence_probe_lib.zig:32` | port candidate |
| `file_io` | storage/io | file reads and writes, append, existence and descriptor checks | `packages/runtime/src/handler_instance.zig:103` | separate owner |
| `handler_contract` | contract | contract types, capability matrix, parse and write operations | `packages/runtime/src/contract_runtime.zig:13` | port candidate |
| `handler_policy` | contract | runtime policy types, projection, SQL normalization | `packages/runtime/src/build_command.zig:559` | port candidate |
| `heap` | support/types | `Heap` | `packages/runtime/src/handler_instance.zig:118` | keep internal |
| `http` | execute | response construction, resource rendering, runtime callbacks | `packages/runtime/src/runtime_http.zig:170` | keep internal |
| `json_utils` | support/types | `writeJsonString` | `packages/runtime/src/capsule.zig:18` | separate owner |
| `module_binding` | modules/linking | module handles, capabilities, wrapper checks | `packages/runtime/src/module_scope_panic_probe.zig:7` | keep internal |
| `module_manifest` | modules/linking | `parse` | `packages/runtime/src/init_command.zig:912` | port candidate |
| `modules` | modules/linking | module graph, compiler, resolution, virtual-module callbacks | `packages/runtime/src/handler_instance.zig:711` | keep internal |
| `object` | execute | atoms and predefined-atom lookup | `packages/runtime/src/handler_instance.zig:1158` | keep internal |
| `parser` | parse | `Parser`, `IrView` | `packages/runtime/src/handler_instance.zig:701` | keep internal |
| `perf_receipt` | verify/proof | claims, signing, verification | `packages/runtime/src/perf_probe_lib.zig:30` | port candidate |
| `pipeline` | compile | parsed modules, type storage, resolution, contract extraction | `packages/runtime/src/handler_instance.zig:1037` | keep internal |
| `policy` | diagnostics/policy | denial emission, resource-kind constants | `packages/runtime/src/runtime_http.zig:436` | port candidate |
| `rule_registry` | diagnostics/policy | `policyHash` | `packages/runtime/src/attest/build_receipt.zig:80` | port candidate |
| `security_events` | diagnostics/policy | security event model, global sink, JSON writer | `packages/runtime/src/security_logger.zig:6` | port candidate |
| `spec_discharge` | verify/proof | spec list, cause and suggestion lookup | `packages/runtime/src/witnesses_cli.zig:17` | port candidate |
| `string` | support/types | `RopeNode`, `SliceString` | `packages/runtime/src/runtime_natives.zig:21` | keep internal |
| `system_linker` | modules/linking | `parseSystemConfig` | `packages/runtime/src/in_process_dispatch.zig:113` | port candidate |
| `trace` | storage/io | trace and durable state, parsers, replay wrappers | `packages/runtime/src/durable_executor.zig:127` | keep internal |
| `witness_corpus` | verify/proof | corpus entries, loading, pinning, pruning, synthesis | `packages/runtime/src/witnesses_cli.zig:16` | port candidate |

### Tools

| Internal module | Capability | Used surface | Primary evidence | Disposition |
|---|---|---|---|---|
| `bool_checker` | diagnostics/policy | diagnostic types | `packages/tools/src/json_diagnostics.zig:13` | port candidate |
| `builtin_modules` | modules/linking | builtin catalog, governance entries, specifier lookup | `packages/tools/src/module_audit.zig:8` | port candidate |
| `builtins` | execute | `initBuiltins` | `packages/tools/src/precompile_buildtime.zig:63` | keep internal |
| `bytecode` | execute | `FunctionBytecode` | `packages/tools/src/precompile_buildtime.zig:119` | keep internal |
| `bytecode_cache` | compile | bytecode slice writers and serialization | `packages/tools/src/precompile.zig:1964` | keep internal |
| `compat` | support/types | realtime clock | `packages/tools/src/precompile.zig:1632` | separate owner |
| `context` | support/types | `AtomTable` | `packages/tools/src/transpiler.zig:66` | keep internal |
| `contract_diff` | contract | diff model, proof metadata, comparison and report writers | `packages/tools/src/prove.zig:13` | port candidate |
| `counterexample` | verify/proof | witness types and solver | `packages/tools/src/precompile_check.zig:136` | port candidate |
| `fault_coverage` | verify/proof | `FaultCoverageChecker` | `packages/tools/src/precompile.zig:1065` | port candidate |
| `file_io` | storage/io | file reads and writes, existence, module-graph reads | `packages/tools/src/precompile.zig:150` | separate owner |
| `flow_checker` | verify/proof | diagnostics, defended paths, property mapping | `packages/tools/src/precompile_check.zig:110` | port candidate |
| `handler_contract` | contract | contract and schema types, parsing, merging, JSON writing | `packages/tools/src/precompile.zig:14` | port candidate |
| `handler_policy` | diagnostics/policy | handler and runtime policy, validation, SQL policy | `packages/tools/src/precompile.zig:22` | port candidate |
| `handler_verifier` | verify/proof | diagnostics and handler discovery | `packages/tools/src/precompile.zig:1327` | port candidate |
| `idiom_registry` | diagnostics/policy | idiom catalog, lookup, stable hash | `packages/tools/src/describe_rule.zig:9` | port candidate |
| `json_utils` | support/types | `writeJsonString` | `packages/tools/src/system_rollout.zig:7` | separate owner |
| `manifest_registry` | modules/linking | `Registry` | `packages/tools/src/precompile.zig:600` | port candidate |
| `module_binding` | modules/linking | binding, capability, return, and label types | `packages/tools/src/module_audit.zig:445` | port candidate |
| `module_manifest` | modules/linking | manifest types, parser, registry hash | `packages/tools/src/module_audit.zig:9` | port candidate |
| `module_spec_render` | modules/linking | catalog and module-spec renderers | `packages/tools/src/module_spec_cli.zig:15` | port candidate |
| `modules` | modules/linking | resolver, compiler, graph, replay registration | `packages/tools/src/module_graph_record.zig:20` | keep internal |
| `object` | support/types | `Atom` | `packages/tools/src/precompile.zig:2237` | keep internal |
| `parser` | parse | parser, IR, codegen, node and binding types | `packages/tools/src/transpiler.zig:12` | keep internal |
| `pipeline` | compile | compiler phase values, resolution, checking, contract extraction | `packages/tools/src/precompile.zig:479` | port candidate |
| `proof_trace` | verify/proof | verifier catalog, trace collection and JSON output | `packages/tools/src/precompile.zig:1481` | port candidate |
| `property_diagnostics` | diagnostics/policy | violations, enrichment, JSONL and summary writers | `packages/tools/src/precompile.zig:1813` | port candidate |
| `repair_intent` | diagnostics/policy | `RepairIntent` and parsing | `packages/tools/src/canonicalize.zig:11` | port candidate |
| `repair_validator` | diagnostics/policy | validator catalog and application validation | `packages/tools/src/canonicalize.zig:2983` | port candidate |
| `restriction_registry` | diagnostics/policy | restrictions, lookup, counts, stable hash | `packages/tools/src/agent_protocol.zig:24` | port candidate |
| `route_match` | contract | `pathsMatch` | `packages/tools/src/manifest_alignment.zig:14` | port candidate |
| `rule_registry` | diagnostics/policy | rule catalog, lookup, search, policy hash | `packages/tools/src/describe_rule.zig:8` | port candidate |
| `semantics` | verify/proof | semantic terms, codes, coverage and hashes | `packages/tools/src/semantics_cli.zig:26` | port candidate |
| `semantics_audit` | verify/proof | `encodeRefutation` | `packages/tools/src/smt_solver.zig:241` | port candidate |
| `semantics_check` | verify/proof | check, SMT and audit runners | `packages/tools/src/semantics_cli.zig:103` | port candidate |
| `semantics_corpus` | verify/proof | corpus runner | `packages/tools/src/semantics_cli.zig:104` | port candidate |
| `semantics_render` | verify/proof | TypeScript specification renderer | `packages/tools/src/semantics_cli.zig:58` | port candidate |
| `semantics_smt` | verify/proof | verdict and equivalence encoding | `packages/tools/src/smt_solver.zig:41` | port candidate |
| `service_types` | contract | service context, routes, response variants | `packages/tools/src/precompile.zig:18` | port candidate |
| `spec_discharge` | verify/proof | discharge, spec catalog, import restrictions | `packages/tools/src/precompile_check.zig:383` | port candidate |
| `sql_analysis` | verify/proof | SQL statement analysis | `packages/tools/src/precompile.zig:32` | port candidate |
| `sqlite` | storage/io | `Db`, `Stmt` | `packages/tools/src/precompile.zig:31` | keep internal |
| `strict_checker` | diagnostics/policy | diagnostic types and severity | `packages/tools/src/json_diagnostics.zig:15` | port candidate |
| `string` | support/types | `StringTable` | `packages/tools/src/precompile.zig:2308` | keep internal |
| `system_linker` | modules/linking | system model, parser, linker, reports and contract writing | `packages/tools/src/system_build.zig:12` | port candidate |
| `trace` | execute | request and replay types, parsing, JSON helpers | `packages/tools/src/precompile_prove.zig:49` | port candidate |
| `type_checker` | diagnostics/policy | diagnostic types | `packages/tools/src/json_diagnostics.zig:14` | port candidate |
| `witness_corpus` | verify/proof | corpus paths, persistence, pinning, envelope writing | `packages/tools/src/precompile_check.zig:128` | port candidate |

### Pi

| Internal module | Capability | Used surface | Primary evidence | Disposition |
|---|---|---|---|---|
| `compat` | support/types | monotonic clock | `packages/pi/src/loop.zig:817` | separate owner |
| `context` | compile | `AtomTable` | `packages/pi/src/tools/pi_goal_check.zig:167` | keep internal |
| `contract_diff` | contract | comparison, recommendation, proof-level derivation | `packages/pi/src/proof_enrichment.zig:15` | port candidate |
| `counterexample` | verify/proof | property and witness model, solver, JSONL writer | `packages/pi/src/tools/pi_goal_check.zig:228` | port candidate |
| `effect_inference` | verify/proof | analyzer and function effects | `packages/pi/src/tools/zts_expert_effects.zig:93` | keep internal |
| `file_io` | storage/io | file reads and writes, existence, append | `packages/pi/src/session/events.zig:172` | separate owner |
| `flow_checker` | verify/proof | diagnostics, witnesses, property mapping | `packages/pi/src/tools/pi_repair_plan.zig:296` | keep internal |
| `handler_contract` | contract | `HandlerProperties`, JSON string writing | `packages/pi/src/proof_enrichment.zig:16` | port candidate |
| `handler_verifier` | verify/proof | diagnostics and handler discovery | `packages/pi/src/tools/pi_goal_check.zig:182` | keep internal |
| `json_utils` | support/types | `writeJsonString` | `packages/pi/src/memory_store.zig:110` | separate owner |
| `manifest_registry` | modules/linking | `Registry` | `packages/pi/src/tools/pi_extension_catalog.zig:89` | port candidate |
| `module_manifest` | modules/linking | `parse` | `packages/pi/src/tools/pi_extension_catalog.zig:163` | port candidate |
| `parser` | parse | parser, IR, tokenizer, node and token types | `packages/pi/src/tools/pi_repair_plan.zig:135` | keep internal |
| `repair_intent` | diagnostics/policy | repair intent model and conversion | `packages/pi/src/tools/pi_apply_repair_plan.zig:162` | port candidate |
| `repair_plan` | diagnostics/policy | plan model and diagnostic projection | `packages/pi/src/tools/pi_repair_plan.zig:240` | keep internal |
| `repair_validator` | diagnostics/policy | validator lookup and application validation | `packages/pi/src/tools/pi_apply_repair_plan.zig:166` | port candidate |
| `rule_registry` | diagnostics/policy | rule catalog, lookup, search, policy hash | `packages/pi/src/expert_persona.zig:777` | port candidate |
| `system_linker` | verify/proof | `ProofLevel` | `packages/pi/src/proof_enrichment.zig:908` | port candidate |
| `witness_corpus` | storage/io | corpus entries, storage, selection, counts, pinning | `packages/pi/src/expert_persona.zig:647` | port candidate |

### Proof review

| Internal module | Capability | Used surface | Primary evidence | Disposition |
|---|---|---|---|---|
| `contract_diff` | contract | `ProofLevel` | `packages/proof-review/src/review.zig:40` | port candidate |
| `file_io` | storage/io | file reads and writes | `packages/proof-review/src/state.zig:75` | separate owner |

## Repeated capability clusters

Two internal modules are reached by every consumer: `contract_diff` and
`file_io`. Ten more are reached by three consumers: `compat`, `context`,
`counterexample`, `handler_contract`, `json_utils`, `module_manifest`,
`parser`, `rule_registry`, `system_linker`, and `witness_corpus`.

The repeated reaches fall into these clusters:

| Cluster | Main modules | Consumers | Decision |
|---|---|---|---|
| VM execution | `arena`, `builtins`, `bytecode`, `context`, `heap`, `http`, `object`, `parser`, `string` | runtime, tools, pi | Keep internal. These types expose concrete VM representation, allocation, IR, or execution state. |
| Contract evolution | `handler_contract`, `contract_diff`, `handler_policy`, `route_match`, `service_types` | all four | Curate proof metadata first. Keep the allocator-owning diff model internal until consumers converge on a smaller result. |
| Proof and witnesses | `counterexample`, `proof_trace`, `spec_discharge`, `witness_corpus`, `semantics*` | runtime, tools, pi | Candidate for later ports split by operation. Do not expose the current storage and solver internals as one surface. |
| Diagnostics | checker diagnostic types, `property_diagnostics` | runtime, tools, pi | Candidate for one diagnostic projection ADT. The current parallel checker-specific types should not become separate stable APIs. |
| Policy catalogs | `rule_registry`, `restriction_registry`, `idiom_registry`, `repair_intent`, `repair_validator` | runtime, tools, pi | Candidate for read-only catalog and repair-policy queries. |
| Module metadata | `builtin_modules`, `module_binding`, `module_manifest`, `manifest_registry`, `system_linker` | runtime, tools, pi | Curate manifest and catalog queries. Keep the module compiler, graph, binding wrappers, and resolver internal. |
| Platform helpers | `compat`, `file_io`, `json_utils` | all four | Do not add generic filesystem or clock operations to the stable ZTS API. Decide their owner separately from engine ports. |

The `tools` diagnostic projection is the clearest later consolidation:
`json_diagnostics.zig` reaches `bool_checker`, `flow_checker`,
`handler_verifier`, `strict_checker`, and `type_checker` for parallel
diagnostic types. A single tagged projection could remove five rows, but its
wire-code mapping needs its own behavior matrix before implementation.

## First migration decision

The first migration should curate contract proof metadata without exposing the
full `contract_diff` module.

Add one stable namespace to `packages/zts/src/root.zig`:

```zig
pub const ContractProof = struct {
    pub const Level = contract_diff.ProofLevel;

    pub fn level(contract: *const HandlerContract) Level;
    pub fn claimScope(contract: *const HandlerContract) []const u8;
};
```

`Level` is an enum, `level` returns that enum, and `claimScope` returns one of
the static strings already emitted by `contract_diff`. The port adds no
allocator, ownership transfer, mutable collection, solver, or filesystem
capability.

The migration should replace only these uses:

- `contract_diff.ProofLevel`
- `contract_diff.deriveProofLevel(contract)`
- `contract_diff.claimScope(contract.properties)`

The affected call sites span all four consumers. `proof-review` uses only
`ProofLevel`, so its `proof-review contract_diff` row becomes unused and must
be deleted. Runtime, tools, and pi retain their `contract_diff` rows because
they still use comparison, recommendation, or detailed diff types.

Do not curate `ContractDiff`, `Classification`, diff member arrays, report
writers, or `generateRecommendation` in this migration. Their ownership and
consumer needs remain too broad for the first port. Do not use `file_io` as a
shortcut for shrinking the count; generic filesystem access does not belong
in the stable engine surface.

Expected allowlist result: 100 rows, with no new row.

## Verification

The inventory contains 101 unique consumer-module pairs. A mechanical
comparison against `scripts/module-boundary.allow` found no missing or extra
pair. The per-consumer counts are 32, 48, 19, and 2, matching the boundary
gate.

The snapshot passed:

```sh
zig build test-module-boundary --summary all
zig build test-runtime-purity --summary all
zig build test-doc-links --summary all
git diff --check
```

This change is a documentation-only classification. It changes no executable
behavior, so no unit test was added. The boundary parity check and the three
repository gates replace behavior tests for this unit.

## Acceptance for the next change

A later migration must meet all of these conditions:

- expose only the request, response, and operations used by the selected
  consumer cluster
- migrate one coherent consumer cluster
- delete every allowlist row made unused by the migration
- add no allowlist row
- keep `zig build test-module-boundary` and
  `zig build test-runtime-purity` green
- avoid a physical package split

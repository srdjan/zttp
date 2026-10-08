# Minimal design audit

Status: audit complete. Implementation is not selected by this report.

## Objective and constraints

Reduce unnecessary complexity before adding features. Preserve current functionality, public output, error handling, byte ownership, and request isolation.

The audit starts from local `main` at `3a50539f`. The initial worktree is clean.
The archived reset plan supplies historical questions, not current deletion evidence.
The completed September rederive already simplified schema writing, journal decoding, transaction recovery, and the acceptance kernel.

## Current measurements

The production branch metric parses 647 tracked Zig files with zero parse failures.
It reports 70,090 production branches and 11,397 production functions.
Its combined score is 81,487. This score measures source decisions, not runtime cost or unnecessary complexity.

The small check parses `packages/tools/src/precompile_args.zig` before the repository run.
It reports 45 production branches and six production functions, with zero parse failures.
The full run changes only the input scope.

Commands:

```sh
zig run tooling/production_branch_metric.zig -- packages/tools/src/precompile_args.zig
bash scripts/run-production-branch-metric.sh --json
```

Both commands exit 0. Compiler cache access requires sandbox escalation.
The branch measurement is not a regression test.

## Confirmed reductions

### One writer for the proof JSON envelope

`packages/tools/src/json_diagnostics.zig:288` and `:381` emit successful and failed check results.
Both functions receive the same contract, diagnostics, witness block, and proof trace.
Both functions serialize the same proof fields in the same order.
Only the `success` value differs.

`packages/tools/src/zts_cli.zig:311` and `:314` select these functions after checking the error count.
The failed declaration tests also call the error writer in `packages/tools/src/precompile.zig:7019` and `:7038`.

Use one private envelope writer with an explicit success value.
Keep both public entry points as small wrappers if callers require them.
Preserve field order, omitted optional blocks, raw JSON insertion, and the final newline.
This removes duplicate serialization decisions without adding a general serialization framework.

Risk: low for control flow, but exact output bytes are part of the public contract.
The contract goldens in `build/goldens.zig:47` check successful and failed handlers, exact bytes, and exit codes.
Add public-writer checks for absent contracts and optional blocks before consolidation.
Required unfiltered checks: `zig build test-zts-cli`, `zig build test-precompile`, and `zig build test-contract-golden`.

### Remove withdrawn repair code

`packages/tools/src/canonicalize.zig:170` defines `buildSemicolonRepairs` without a caller.
Its comment explicitly withdraws the repair because source mapping and comment handling can produce incorrect edits.
The active paths use `buildLineRepairs` and `buildSpanRepairs` instead.

Remove the withdrawn implementation. Keep the reason for withdrawal in a solution note if future work needs it.
Do not enable the withdrawn repair as part of cleanup.
Classify the four unreferenced scanner helpers near `canonicalize.zig:1475` separately before removal.

Risk: low for the private implementation because no tracked caller reaches it.
Required unfiltered check: `zig build test-canonicalize`, registered in `build/host_tests.zig:39`.
Also run the public canonicalize command goldens and `zig build test-module-boundary`.

### Remove obsolete WebSocket helper methods

Commit `a89950a2` removed WebSocket support.
`packages/runtime/src/handler_instance.zig:1373` still defines `armRequestDeadlineWithin`.
`packages/runtime/src/runtime_pool.zig:135` still defines `WorkerRuntimeLease.recycleAfterTimeout`.
Neither function has a tracked caller or a reflection reference.

Normal HTTP requests use `armRequestDeadline` at `handler_instance.zig:1367`.
HTTP timeout handling still increments the timeout counter and recycles the slot at `runtime_pool.zig:451`.
Remove only the obsolete methods and their obsolete comments.
Correct the historical test claim in `docs/solutions/tooling-decisions/zig-dead-code-census.md:178` when this cleanup occurs.

Risk: low within the tracked runtime package. Confirm external embedding exports before changing source visibility.
Required unfiltered checks: `zig build test-zruntime` and `zig build test-server`.

### Collect closed catalog fields once

`packages/zts/src/contract_builder.zig:1611`, `:1747`, `:1899`, and `:1973` repeat structural parsing for four catalog objects.
Each reader resolves literal properties, maps names to slots, rejects duplicate or unknown fields, and checks required fields.
The readers serve tool entries, agent entries, agent providers, and agent limits.

Use one local field collector with explicit names, required fields, and refusal tags.
Keep domain value validation in each reader.
Preserve diagnostic order, source nodes, details, and suppression of dependent errors.
This removes repeated object structure checks without combining different domain rules.

Risk: medium because diagnostic order and refusal details are public output.
Existing refusal checks start at `contract_builder.zig:7795`; successful catalog checks start at `:7860`.
Required unfiltered checks: `test-zts`, `test-contract-golden`, `test-diagnostic-corpus`, `test-proof-checker`, and `test-proof-checker-mutants` through `zig build`.

### Use the query tool as the single operation boundary

`packages/pi/src/tools/zts_expert_query.zig:148` dispatches ten operations through separate `ToolDef` records.
`packages/pi/src/tool_registry.zig:53` registers the query tool, not those separate records.
For example, `zts_expert_meta.zig:9` repeats metadata, argument decoding, request JSON construction, and protocol projection.

Make the query tool validate operations and invoke `zts_agent_client` directly.
Keep operation-specific filtering as private helpers where necessary.
Retain all operations, command aliases, envelopes, errors, and the model-facing schema.
Preserve `normalizeTrustedOperation` because slash commands enter through a different argument path.

Risk: medium because existing wrapper validation and error text must remain equivalent.
Required unfiltered check: `zig build test-expert-app`, including catalog, decoder, dispatch, refusal, and end-to-end tool checks.

### Derive properties and proof identity from one receipt lookup

`packages/pi/src/session_state.zig:44` and `:59` independently scan backward for the latest receipt touching a file.
One function returns properties; the other decodes the receipt's transaction identity.
Autoloop and application controls call these derivations repeatedly.

Use one latest-receipt lookup and derive both values from its borrowed result.
Keep wrappers if callers need separate values. Do not add a persistent cache or a second authority.
Refresh the borrowed result after a transcript mutation.
If the latest matching identity is malformed, return no hash rather than selecting an older receipt.

Risk: low with explicit borrowing and unchanged receipt selection.
Required unfiltered checks: `zig build test-expert-app` and `zig build test-standin`.
Preserve latest-receipt, file-scoping, malformed-identity, and projection-isolation checks.

## Larger design candidates

### Share runtime invocation policy while retaining response ownership

`packages/runtime/src/runtime_pool.zig:428` and `:490` repeat acquisition, retry, timeout, panic, and invalid-handler decisions.
The owned path serves replay callers. The borrowed path serves edge and in-process dispatch callers.
Both paths retry invalid handlers with the same limit and recycle or quarantine the same error cases.

One private invocation helper could own the retry and disposal policy.
Keep both public response methods and their distinct ownership rules.
The owned path must clone response bytes before releasing the runtime.
The borrowed path must hold the runtime until `ResponseHandle.deinit`.
Preserve fault-location capture, request identity, timeout counters, and the guarded-call mode.

Risk: medium because incorrect release order can invalidate response bytes.
Existing ownership and timeout tests occur at `server_test.zig:111`, `:253`, and `:293`, and `runtime_pool.zig:1506`.
Required unfiltered checks: `zig build test-server`, `zig build test-zruntime`, and `zig build test`.

### Retire unread latency telemetry only after checking its API

`packages/runtime/src/runtime_pool.zig:40` stores latency counters; `:58` stores percentile trackers.
`getMetrics` at `:801` returns ten latency fields.
Tracked callers only occur in tests and read operational counters rather than latency fields.
The percentile module has no other importer.

The runtime can remove latency recording if its fields have no supported external consumer.
Retain request identity, exhaustion, audit, recycling, panic, and timeout counters.
Retain the acquisition timer because it enforces `acquire_timeout_ms` at `runtime_pool.zig:652`.
Unread telemetry does not establish a performance benefit; that benefit needs measurement.

Risk: low within tracked callers, unknown for external direct imports of the runtime module.
Removing returned fields changes source API and therefore requires a contract decision.
Required unfiltered checks: `zig build test-server`, `zig build test-zruntime`, and `zig build test`.

### Give provider request configuration one owner

`packages/pi/src/agent.zig:305` holds a backend plus owned prompt, tool, endpoint, provider, and model fields.
Constructors at `:396` through `:550` repeat allocation and provider configuration.
Destruction, destination reporting, normal requests, summary requests, and model changes repeat provider selection.

A provider backend record could own common request configuration and its byte lifetimes.
Transport clients would retain provider wire encoding, authentication, endpoint policy, and response decoding.
The session would retain orchestration rather than mirror transport configuration.

Risk: high. Provider identity also serves UI, persistence, deterministic replay, and injected test clients.
The design must preserve those separate roles and atomic model restamping.
Pin constructor failure cleanup and model-change failure behavior before selecting this change.
Required unfiltered checks: `zig build test-expert-app` and `zig build test-cassette`.

### Migrate positional check calls to named options

`packages/tools/src/precompile.zig:1249` and `:1395` adapt positional arguments to the existing `CheckOptions` API.
Canonicalize, the agent protocol, and runtime build commands still use positional wrappers.
Use named options at repository call sites to remove repeated positional configuration.

Do not remove the compatibility wrappers until their external API status is established.
`packages/tools/src/zts_cli.zig:3` publicly re-exports the precompile module.
Risk: low for call migration, unknown for removing externally reachable wrappers.
Required unfiltered checks: `test-precompile`, `test-zts-cli`, `test-canonicalize`, `test-agent-protocol`, `test-expert-app`, and `test` through `zig build`.

## Correctness issue separate from cleanup

The check path uses `analyzeHandlerPaths` at `packages/tools/src/precompile.zig:1334`.
The compile path repeats summary construction around `:2658`.
The check path asks `PathGenerator.pathsExhaustive()`; the compile path reconstructs completeness from the path count at `:2702`.

`packages/zts/src/path_generator.zig:447` explicitly requires consumers to use `pathsExhaustive()`.
That method also accounts for summarized constructs, such as loops and recursion.
The compile predicate can therefore claim exhaustive behavior when the generator summarized a construct.
This is a source-confirmed predicate difference; a public compile/check reproduction remains required.

A shared summary function should accept an already-generated path set.
Keep generation, JSONL emission, and the distinct path and fault walkers in their existing owners.
Correcting the compile verdict changes observable output in the affected case.
Handle the correction as a separate bug fix, not as behavior-preserving cleanup.
Required unfiltered checks: `test-precompile`, `test-zts`, `test-flow-census`, and `test-contract-golden` through `zig build`.

## Declaration census

The identifier census finds 32 function names with only one occurrence in tracked Zig sources.
This result identifies candidates, not 32 authorized deletions.
String-based reflection, external consumers, format compatibility, and documented deferrals need separate checks.
`AtomTable.pruneUnused` is a documented deferral and must remain outside a mechanical cleanup.

The census uses NUL-delimited tracked paths and stores temporary results outside the repository.
Its method follows `docs/solutions/tooling-decisions/zig-dead-code-census.md`.
Repeat the census after each removal because one dead caller can hide other dead functions.

## Boundaries to retain

The proof producer and acceptance kernel remain independent.
Shared proof decisions would let the consumer repeat the producer's mistake.
The flow-sensitive analysis passes retain separate traversal state and ordering.
The journal remains audit authority; the model projection remains replaceable.
Request arenas and runtime pools retain their isolation and timeout behavior.

Collector removal, evaluator unification, and VM-loop consolidation require current measurements and preserved public behavior.
The roadmap records these questions as deferred or measurement-dependent.
This audit does not propose removing working features to make the source smaller.

## Worklog and next action

Completed: source inspection, branch baseline, declaration census, three package audits, caller checks, and review of the reported source.
The report contains six small reductions, four larger or compatibility-dependent candidates, and one separate correctness issue.
No product code or tests changed. No behavior-equivalence claim follows from this audit.
The delegated test attempts were interrupted before completion. They provide no passing-test evidence.

The recommended order starts with private dead code, the proof JSON writer, and the receipt lookup.
Next come catalog field collection, query operation consolidation, and runtime invocation policy.
Provider ownership follows only after its failure and identity contracts are pinned.
Telemetry removal and positional-wrapper deletion wait for external API decisions.
The path-completeness issue needs a public reproduction and a separate correction.

The repository owner selects implementation scope. I will then preserve behavior with the named unfiltered checks and isolated local commits.

## Full declaration census candidates

The following 32 names occur once in tracked Zig sources. Line numbers refer to the audit baseline.
The list includes deferred, externally reachable, and obsolete functions. It is not a deletion ledger.

| Function | Source location |
|---|---|
| addLitString | packages/zts/src/parser/ir.zig:951 |
| armRequestDeadlineWithin | packages/runtime/src/handler_instance.zig:1373 |
| asDraftFailure | packages/pi/src/expert_failure_analysis.zig:36 |
| buildSemicolonRepairs | packages/tools/src/canonicalize.zig:170 |
| caseName | packages/pi/src/simulator/artifact.zig:104 |
| categoryDynamicLabel | packages/zts/src/handler_policy.zig:813 |
| cloneStringSlice | packages/pi/src/ui_payload.zig:538 |
| concatManyWithArena | packages/zts/src/string.zig:1248 |
| concatRopeStringWithArena | packages/zts/src/string.zig:442 |
| connectTimeout | packages/pi/src/providers/http_errors.zig:59 |
| constraintOf | packages/zts/src/type_env.zig:130 |
| emitNotification | packages/pi/src/rpc_mode.zig:876 |
| expectValidJsonLines | packages/pi/src/standin_tests.zig:999 |
| findTopLevelChar | packages/tools/src/canonicalize.zig:1494 |
| installProjectionOwned | packages/pi/src/transcript.zig:251 |
| isMatchExhaustive | packages/zts/src/match_analysis.zig:145 |
| isSimpleIdentifier | packages/tools/src/canonicalize.zig:1486 |
| lineEndOffset | packages/tools/src/canonicalize.zig:1475 |
| parseDiffHunks | packages/pi/src/ui_payload.zig:1437 |
| parseHash32 | packages/pi/src/ui_payload.zig:1291 |
| parseProveSummary | packages/pi/src/ui_payload.zig:1491 |
| parseSystemProofSummary | packages/pi/src/ui_payload.zig:1515 |
| parseViolationDeltaItems | packages/pi/src/ui_payload.zig:1457 |
| pruneUnused | packages/zts/src/atom_table.zig:69 |
| readBytesNoEof | packages/zts/src/bytecode_cache.zig:925 |
| recycleAfterTimeout | packages/runtime/src/runtime_pool.zig:135 |
| resourceNoun | packages/zts/src/guard_catalog.zig:73 |
| restoreNarrowed | packages/zts/src/type_checker.zig:431 |
| scanIdentEnd | packages/tools/src/canonicalize.zig:1479 |
| setReadTimeout | packages/pi/src/providers/http_errors.zig:67 |
| setWriteTimeout | packages/pi/src/providers/http_errors.zig:89 |
| writeProvenProperties | packages/pi/src/repl.zig:1453 |

> Execution approved on 2026-10-11. The owner said "go ahead" after reviewing this bounded plan.
> This file is the accepted implementation plan. Progress belongs in the companion worklog.

# Plan 004 Shared analysis for check and compile

> **Executor instructions**: Promote this advisory plan before implementation. Follow each step after promotion. Touch only listed source files.
>
> **Drift check, run first**: `git diff --exit-code 38a0782fba69dafb3dec4a0974a828cb2bdca1bf -- packages/tools/src/precompile.zig packages/tools/src/precompile_check.zig packages/zts/src/pipeline.zig`
>
> Stop if this command reports product-source drift. Compare every cited symbol before continuing.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: HIGH
- **Depends on**: approval and promotion into `docs/plans/` with a matching `docs/roadmap.md` entry
- **Category**: direction
- **Planned at**: product commit `38a0782fba69dafb3dec4a0974a828cb2bdca1bf` on 2026-10-11
- **Source finding**: `advisor-plans/003-zttp-zts-simplification-audit.md`

## Accepted decisions

Decision 1 preserves all documented features.
Decision 2 starts with shared analysis.
Decision 3 preserves current wire formats during the first phases.
The owner accepted this direction on 2026-10-11. The owner then approved this bounded implementation plan.

## Why this matters

The check and compile coordinators assemble related analysis differently. Contract construction can still create missing facts, type analysis, or flow analysis.

This unit gives single-module analysis one owner. It does not claim that any checker currently runs twice.

The removed responsibility is fallback production inside contract construction. The unit keeps current diagnostics, pass selection, and serialized outputs.

## Current state

`runCheckOnPreparedSource` builds `ModuleFacts`, `ResolvedModule`, imported summaries, and `CheckedModule`. It installs imported summaries at `precompile.zig:2192-2199`.

`compileHandler` resolves without injected `ModuleFacts` at `precompile.zig:2715-2727`. It runs `HandlerVerifier` only when `emit_verify` is true.

`buildContractWithPolicy` builds new `ModuleFacts` at `precompile.zig:3625-3628`. It accepts optional resolved and flow inputs.

If flow is absent, `buildContractWithPolicy` creates it at `precompile.zig:3651-3677`. This fallback installs `contract.tools.items` before flow runs.

The check path supplies precomputed flow without that accepted tool catalog. This unit must retain both existing semantics.

Check uses strict mode, reports policy diagnostics, and can skip contracts. Compile selects strict mode, throws policy failures, and always builds a contract.

Compile also passes `manifest_registry`. Check passes imported summaries and its optional declaration into flow.

`pipeline.zig:103-112` requires caller-owned stable storage for `ModuleFacts`. `CheckedModule` also borrows `ResolvedModule`.

`buildContractForServiceContext` and `buildTestContractForSource` pass no resolved analysis. They can also pass no `TypeMap`.

`extractContractFromParsed` then creates only a type session at `pipeline.zig:518-537`. It does not run boolean, strict, or verifier passes.

`pipeline.zig:18-31` rejects a new `LoweredModule`. The same section keeps file and process input outside `zts`.

`precompile_check.zig:15-43` records check stage completion. Its diagnostic and presentation adapters remain path-specific.

The multi-module branch refuses declarations at `precompile.zig:2674-2680`. This unit preserves that refusal.

## Scope

The executor may modify only these files:

- `packages/zts/src/pipeline.zig`: make existing checked passes selectable and incrementally runnable.
- `packages/tools/src/precompile.zig`: own one stable single-module analysis result and adapt both coordinators.

Do not modify `packages/tools/src/precompile_check.zig`. Its stage set and output ownership are compatibility evidence.

Exclude multi-module analysis, `compileMultiModule`, `buildMultiModuleContract`, and module-graph wire formats. Exclude new declaration support for file imports.

Keep public `extractContractFromParsed` and `extractContract` fallbacks unchanged. Graph, wasm, and external callers retain those compatibility paths.

Exclude typed frontend work, bindings, the VM, proof-checker logic, wire formats, product cuts, and all whole-graph designs.

Preserve all public check and compile wrappers. Preserve current contract bytes, diagnostic codes, diagnostic order, bytecode, proof evidence, and early exits.

## Design boundary

Add a private `SingleModuleAnalysis` coordinator in `precompile.zig`. Initialize it through a pointer in caller-owned storage.

The coordinator owns `ModuleFacts` and selected existing analysis types. It records each selected pass as skipped, unresolved, refused, or completed.

Support full-analysis and contract-only modes. Contract-only mode runs the existing type check, flow, and policy behavior only.

Contract-only mode must not run boolean, strict, or verifier passes. It must work when `TypeMap` is null.

Keep standalone `TypeChecker` and `FlowChecker` instances for contract-only mode.
Do not construct a `ResolvedModule` or `CheckedModule` that falsely claims an omitted phase completed.

Keep `TypeEnvStorage`, parser state, atoms, and prepared source alive outside the coordinator. Document every borrow in the coordinator.

Deinitialize `CheckedModule`, then `ResolvedModule`, then `ModuleFacts`. Use initialization flags for every partial failure path.

Split `CheckedModule` setup from pass execution in `pipeline.zig`. Keep its concrete `verifier` and `flow_checker` fields.

Keep current accessors compatible. Keep `pipeline.check` as the existing default wrapper that runs both passes.

Add narrow methods for verifier execution and flow execution. Reject a repeated pass call through a native Zig error union.

Let flow setup accept an optional `[]const handler_contract.ToolEntry`. Install it before flow runs when the compile contract supplies entries.

The check coordinator leaves the accepted catalog absent. The compile coordinator supplies `contract.tools.items`, matching current behavior.

Do not infer successful properties from a skipped verifier. Keep `result_safe` and `optional_safe` false when `emit_verify` is false.

Separate existing type-session initialization so caller-owned storage can create a real `TypeChecker` when `TypeMap` is null.

If required, add one narrow pipeline helper that extracts with an explicit checker. Preserve the public extraction fallback and its signature.

Split private `buildContractWithPolicy` responsibility into three operations. One extracts, one projects completed flow, and one validates policy inputs.

None may construct private fallback facts, type sessions, resolution, or flow. Public pipeline extraction retains its compatibility fallback.

## Steps

### Step 1: Pin current public outcomes

Add characterization tests beside existing tests in `precompile.zig`. Make each test assert intended values, not only path equality.

Cover default check, `skip_contract`, compile with verification disabled, and compile with verification enabled. Assert exact stage presence and property values.

Cover a missing handler. Preserve the `emit_aot` allocation-error return at `precompile.zig:3014-3050` through source review.
Unsupported syntax does not enter that return. Characterize its normal runtime bail separately.
No bounded public trigger identifies this allocation phase without a fragile allocation ordinal.

Cover contract-only extraction with no `TypeMap`. Use a source that would expose any newly added boolean, strict, or verifier pass.

Review that the AOT allocation-error return keeps its current property projection. Do not align it with the main compile return.

Pin exact diagnostic code order for one refused handler. Pin current compile and check tool-catalog outcomes separately.

Use fixed source paths, `build_time`, and `git_commit` for bytecode and proof comparisons. Record only root-measured stable values.

Assert stable contract fields through existing serialization helpers and goldens. Do not normalize timestamps or authority-bearing bytes.

Stop if exact byte or proof comparison remains clock-dependent after fixed inputs. Report the unstable field instead of weakening the assertion.

Retain these regressions: declaration refusal at line 8357, routed census at line 8426, and route resolution at line 8495.

Retain fault metadata cases at lines 9017 and 9031. Strengthen line 9031 with explicit expected records for both fixtures.

**Accept**: the new tests pass against unchanged production code through unfiltered `zig build test-precompile --summary all`.

### Step 2: Make checked passes selectable

Refactor `CheckedModule` setup, verifier execution, and flow execution. Preserve concrete public fields, defaults, accessors, and current callers.

Add tests for verifier-only, flow-only, both passes, repeated calls, missing handlers, and accepted tool catalogs.

Extend the existing failure sweep near `pipeline.zig:1244`. Cover allocation failure during setup and both selected passes.

Add one skipped-flow mutation probe. It must fail when a completed result is falsely claimed without a flow walk.

Add a safe control that completes flow and keeps the intended clean result. Test public behavior rather than internal counters.

**Accept**: `zig build test-zts --summary all` exits zero. Every injected allocation failure releases all owned memory.

### Step 3: Add stable coordinator ownership

Create `SingleModuleAnalysis` with pointer initialization and reverse-order cleanup. Inject its one `ModuleFacts` into every selected consumer.

Pass each path's current strict, registry, declaration, imported-summary, and policy inputs unchanged.

Map existing early exits to explicit internal states. Do not expose the state vocabulary through public result or wire schemas.

Add full-analysis and contract-only initialization. The contract-only mode owns a real type session without running unrelated checks.

Measure the selected pass matrix from public outcomes. Do not claim resolution for contract-only, missing-handler, or skipped paths.

**Accept**: tests show each selected pass completed. Skipped, unresolved, and refused passes cannot be consumed as complete.

### Step 4: Remove contract fallbacks

Route check and compile through full-analysis mode. Route both private contract helpers through contract-only mode.

Keep compile verification before bytecode generation. Keep compile flow after contract tools exist. Keep check flow before contract projection.

Remove optional analysis production from private `buildContractWithPolicy`. Keep public pipeline extraction fallbacks unchanged.

Preserve the AOT transpiler failure return before final main-branch projection. Preserve missing-handler outputs and earlier exits.

Do not alter `precompile_check.zig`. Do not move file reading, clocks, configuration loading, or output writing into `zts`.

**Accept**: private contract operations contain no fallback production. Public pipeline compatibility fallbacks and characterization outcomes remain unchanged.

### Step 5: Measure one tiny public pipeline

Build the existing `zts` binary with `zig build`. Do not include build time in the pipeline measurement.

Run `./zig-out/bin/zts check --json tests/corpus/check/good/correct_handler.ts` under `/usr/bin/time -p`.

Record its direct exit status, elapsed time, and output. Compare only stable fields that Step 1 identifies.

Run `./zig-out/bin/zts compile --build-time 2026-10-11T00:00:00Z --git-commit 38a0782f tests/corpus/check/good/correct_handler.ts /private/tmp/zttp-shared-analysis-small.zig`.

Run the compile command under `/usr/bin/time -p`. Record its direct exit status, elapsed time, and generated-file digest.

Repeat both commands after the change. Change no fixture path, option, metadata value, or scale parameter.

Stop if either public command takes one minute or more. Do not claim a speed change from these observations.

If the measurement expands, change only the corpus size. Keep the commands, metadata, and comparison method fixed.

**Accept**: both public paths exit zero. Stable output fields and the generated-file digest match their measured baselines.

### Step 6: Run bounded verification

First run `zig build test-precompile --summary all`. Stop and request permission if any required script exceeds two minutes.

Then run these unfiltered steps: `test-zts`, `test-zts-cli`, `test-agent-protocol`, `test-module-graph-record`, and `test-contract-golden`.

Run `test-diagnostic-corpus`, `test-flow-census`, and `test-module-boundary`. Read each command's direct exit status.

Finally run `test-proof-checker`, `test-proof-ratchet`, `test-cli`, and `test-reference-tools`. These checks protect independent acceptance and artifact behavior.

**Accept**: every named step exits zero. No result uses `-Dtest-filter`, pipelines, or truncated command status.

Run each command separately. Preserve sequential execution for the runtime and artifact checks.

```sh
zig build test-precompile --summary all
zig build test-zts --summary all
zig build test-zts-cli --summary all
zig build test-agent-protocol --summary all
zig build test-module-graph-record --summary all
zig build test-contract-golden --summary all
zig build test-diagnostic-corpus --summary all
zig build test-flow-census --summary all
zig build test-module-boundary --summary all
zig build test-proof-checker --summary all
zig build test-proof-ratchet --summary all
zig build test-cli --summary all
zig build test-reference-tools --summary all
```

## Done criteria

The check and compile coordinators consume one owned single-module analysis result. Private contract operations cannot produce missing analysis.

Contract-only helpers consume one owned type and flow result without running boolean, strict, or verifier checks.

All public wrappers retain their signatures and path-specific outputs. Multi-module declarations still return `error.DeclarationNotEnforced`.

Stable baseline digests and fields match exactly. Contract and proof-checker wire formats remain unchanged.

The pass matrix and small measurement make no speed, deletion-size, or runtime-improvement claim.

## STOP conditions

Stop if shared ownership adds another authority without removing contract fallback production.

Stop if contract-only mode runs boolean, strict, or verifier checks. Stop if public pipeline extraction loses its compatibility fallback.

Stop if compile must run verification when `emit_verify` is false. Stop if check must install the compile accepted tool catalog.

Stop if bytecode, proof evidence, contract bytes, diagnostic order, or public stage completion changes.

Stop if the AOT early return or missing-handler path gains final projection that it does not currently perform.

Stop if the change requires multi-module declarations, new wire fields, a `LoweredModule`, or input and output migration into `zts`.

Stop if stable storage cannot satisfy every analyzer borrow. Stop on any leak or allocator-failure cleanup defect.

## Maintenance note

This unit prepares later graph analysis but does not implement it. Measure this unit before selecting another migration phase.

## Review and next action

The main agent reviewed this plan against current source and requested narrower treatment of contract-only callers and early returns.
The source drift check exits zero. The plan preserves those paths and their existing pass selection.
No implementation, behavior tests, or performance benchmarks ran during planning.

The main agent owns the next action: execute this approved plan and record checks in the companion worklog.

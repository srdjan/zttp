# F18 residual gaps: module-state writes the verifier cannot name

The F18 plan (`2026-11-05-f18-module-state-proofs-plan.md`) recorded five residual gaps after H1 to H3. The owner asked for a plan for them on 2026-11-05. This document is that plan. The owner accepted Decision 1 (a), Decision 2 (c), and Decision 3 (a) on 2026-11-05: run U0 to U6, commit each unit on local `main`, and do not push. The owner accepted Decision 4 (b) on 2026-11-05: U2b runs before the U2 commit, and U2 and U2b commit together.

## Status

| Unit | Status |
|---|---|
| U0 | Complete: baseline below |
| U1 | Complete: persistent-write events, phase split, union over passes; 18 evaluator tests and 1 facade test |
| U2 | Implemented; commits with U2b after the gates |
| U2b | Implemented; commits with U2 after the gates |
| U3 | Not started |
| U4 | Not started |
| U5 | Not started |
| U6 | Not started |

## Reproduction

Observed at `bf6ad1c3` with `zts check`. Each handler exits 0 with 0 errors and 0 warnings, and reports `state_isolated`, `deterministic`, and `read_only` PROVEN.

| Probe | Shape | In the residual list |
|---|---|---|
| g1 | `addTo(seen)`, where `addTo` runs `xs.push(1)` on its parameter | Gap 1 |
| g2 | `getStore().items.push(1)`, where `getStore` returns a module record | Gap 2 |
| g2b | `const s = getStore(); s.items.push(1)` | No: new |
| g2c | `const r = rows[0]; r.n = r.n + 1` on a module array of records | No: new |
| p1 | Module-initialization closure counter: `const counter = makeCounter()`, and the returned arrow runs `n = n + 1` | No: new. `state_isolated` PROVEN; the check exits 1 only for other properties |
| p8 | `handler -> viaHelper() -> addTo(seen)` | Gap 1, two levels deep |

`zttp serve` of the g2c shape, which returns `String(r.n)`, answered 1, 2, 3, and 4 to four identical requests. Probes p1 to p9 are from the Fable review on 2026-11-05 and are kept under `/tmp/fable-f18g/`; U1 copies the ones it needs into tests.

## Cause

Observed: the verifier names a shared object only through a chain of member and index accesses that starts at a binding (`memberBase` in `packages/zts/src/handler_verifier.zig#HandlerVerifier`). The binding must be a module binding, an undeclared global, or an alias that a declaration made from a bare identifier (`recordSharedAlias`). A reference obtained through a parameter, a call result, or an element read names no shared binding, so no write through it is tested.

Inferred: each new syntactic shape closes one path and leaves the others. The 2026-10-18 flow-checker record shows the same pattern: three construct-listing plans failed review with new holes. That record is the superseded guard plan at `pre-round-2-archive:docs/plans/2026-10-18-callback-iteration-writes-plan.md`, cited from `docs/plans/2026-10-18-flow-checker-sound-redesign-plan.md`.

## What already exists

- `packages/zts/src/flow_interp.zig` is a heap-aware evaluator. Each value carries the allocation sites it may point at (`origins`) and the functions it may call (`callables`). It models closures, recursion, the module graph, and module initialization. A construct it does not model sets `cleared`, which clears every flow property.
- `analyzeHandler` keeps module state across requests: `projectPersistent` keeps the heap reachable from module bindings, builtins, and captures, and the handler runs until that state stops changing.
- `recordSharedWrite` exists, but it reports only a write into a builtin object when `persistent_globals` is false. In handler mode no write to module state is reported as an event.
- All three `shares_state` writers reach the flow evaluator for a handler that resolves, but each assigns `shares_state` from the verifier only. CHECK calls `runFlow` before the assignment (`packages/tools/src/precompile_check_run.zig`), unless resolution fails or `skip_contract` returns first. The single-module compile assigns `shares_state` and then extracts the contract, which runs flow (`packages/tools/src/precompile.zig`). The graph compile assigns it while `checkGraphModule` runs with flow off, and flow runs later in `buildMultiModuleContract` (`packages/tools/src/precompile_contract.zig`). U2 must move each assignment after the flow run, or join the flow fact at the contract.
- Two array methods do no abstract write: `pop` and `shift` only read the receiver (`array_pop` in `packages/zts/src/flow_rules.zig` and `flow_interp.zig`).
- One abstract write is not a program write. A native export that reads a container joins its result back into the argument (`flow_interp.zig`, the comment "No native export writes into an argument today"). That keeps a future mutating export sound for labels.
- The frozen flow-precision corpus leaves no construct unresolved (`packages/tools/src/flow_precision_expectations.zig`, test "the frozen corpus leaves no construct unresolved and has no source error").
- Capsule facts come from the effect row: `pure`, `read_only`, and `deterministic` in `packages/zts/src/function_specs.zig` read `fe.row`. The row is a monotone join over the call graph (`packages/zts/src/effect_inference.zig`).
- The ZTS500 hint for `deterministic` is a fixed text in `packages/zts/src/spec_discharge.zig`: "remove Date.now(), Math.random(), and performance.now() from the response path."

## Decision 1: how to detect a write to module state

Option (a), recommended: the flow evaluator reports each write to persistent state during a request. A write is persistent when its target site is in the projected entry state of the pass (a module binding, a builtin, a capture, or a site reachable from one), or when it lands in `top_cell` because the target is unknown. A write during module initialization is not an event. An evaluation that is `cleared` counts as a write, because it could not follow the handler. The verifier keeps ZTS310 for the shapes it names, and the evaluator fact joins `shares_state`. This reuses the alias model that the flow verdicts already depend on.

Three rules make option (a) precise enough to use:

- Phase split. An allocation site records whether module initialization or a request made it. Today `allocation_context` holds only the innermost call (`invoke` copies `current_call_node`), so `init -> build() -> makeRow()` and `handler -> build() -> makeRow()` share one site. Probe p9 is a correct handler that would lose `state_isolated` without the split. A request allocation never aliases an initialization allocation at run time, so the split is sound. A request site that a request stores into module state is in the entry state of the next pass.
- Union over passes. The fact is the union of the events of every pass, and each pass tests a write against its own entry state. The entry state grows with each pass, so the last pass sees the largest set.
- Events come from program operations, not from abstract heap writes alone. Each method in `packages/zts/src/mutating_methods.zig` makes an event on its receiver, including `pop` and `shift`, which write nothing in the abstract heap. The conservative write of a container-reading native export makes no event, because no export changes an argument; a `dictGet(TABLE, key)` on a module table must stay read-only.
- Scope. The fact covers the JavaScript heap only. Native stores stay with the effect row: `zttp:cache`, SQL, and the per-pool `zttp:ratelimit` store (D-013). No virtual-module export changes a JavaScript argument in place today (`dict.set` in `packages/zts/src/dict.zig` copies). U6 records that as an invariant in `packages/modules/AGENTS.md`.

Option (b): extend the verifier with per-function summaries of the parameters that a function writes and the shared objects that it returns, and with element and call-result aliases. This is another construct list, the pattern that failed three reviews on 2026-10-18.

Option (c): make module bindings deeply readonly in function bodies, in the type checker. This needs readonly to survive element reads, call results, and parameters. It refuses existing helpers that a handler calls to change module tables, and it can move the convergence numbers.

## Decision 2: helper capsules (gap 3)

Option (c), recommended: each persistent-write event from Decision 1 carries the activation stack at the write. A capsule loses `pure`, `read_only`, and `deterministic` when an event occurred inside it or inside a function that it called, during a handler evaluation. This uses the real arguments: `bump(local)` stays `pure`, and `bump(seen)` fails ZTS500 (probe p7 is accepted today). A capsule that no handler reaches falls back to the bit of option (a). U3 then needs the flow events before capsule discharge, so it runs after U2.

Option (a): add a shared-state bit to the effect row. The bit is set when a function body contains a write that the ZTS310 rule names, and it joins over the call graph like the other row fields. The effect row and the verifier read one predicate, not two copies. Residual: a capsule whose write goes through a parameter, a call result, or an element read keeps its properties, which is the class this plan exists to close.

Option (b): evaluate each capsule function with the flow evaluator, with module state persistent and parameters unknown. This closes every alias shape. A `pure` capsule that writes its own parameter is then refused, which changes what `pure` means. It costs one evaluation per capsule.

## Decision 4: data imports (found during U2)

The flow evaluator follows an import only when the export is a function. `flowExportedFunctionNode` in `packages/zts/src/pipeline.zig` returns no node for `export const LIMIT = 5`, so `flowModulesForGraph` sets `complete` false, and the evaluation records `module_graph_gap`. At bf6ad1c3 such a handler already loses every flow property and `deterministic`, and gets a false ZTS401. Under the U2 rule a cleared evaluation also removes `state_isolated`, `read_only`, `retry_safe`, and `idempotent`, so a handler that compiles today with `Proof<Response, "state_isolated">` fails ZTS500.

Option (b), accepted: U2b follows an `export const` declaration that has an initializer. The evaluator already copies an imported `var_decl` value after the exporting module initializes. A `const` binding never changes, so one copy is exact. The copied value keeps its origins, so a write through it reaches the exporting module's site, and its labels follow it. An `export let` stays a gap, because an import is a live view of a binding that the exporting module can reassign later. A re-export and an export list without a declaration stay gaps.

Option (a): keep the rule. Handlers that import data lose the four extra properties too.

Option (c): ignore `module_graph_gap` for data imports only. The evaluator records the same reason when the module graph could not load at all, so the exception is not sound without new reason codes.

## Decision 3: execution

Option (a), recommended: run U0 to U6 in order and commit each unit on local `main`. Do not push. Stop after U0 when a corpus handler would lose `state_isolated` without a real write to module state, and report the list.

Option (b): run U0 only and return the measurements for review.

## Units

| Unit | Change | Main files | Model | Turn budget |
|---|---|---|---|---|
| U0 | Measurement, no code change. Record each corpus handler's verdicts for `state_isolated` and the six H2 properties. Count the handlers whose evaluation is `cleared` today, and the factory shape of p9 | `/tmp` only; answers go into this plan | Opus | not applicable |
| U1 | Persistent-write events in the flow evaluator: the phase split, the union over passes, and a written over-approximation argument for each heap write path. Each event carries the write node, its module, and the activation stack | `packages/zts/src/flow_interp.zig`, `flow_value.zig`, `flow_report.zig`, `flow_checker.zig` | Sonnet | 60 |
| U2 | The evaluator fact joins `shares_state` on every writer. A finding that the verifier did not make is a ZTS310 warning at the write node in the module that holds it, not at the handler's call | `packages/tools/src/precompile_check_run.zig`, `precompile.zig`, `precompile_graph_check.zig` | Sonnet | 50 |
| U2b | Decision 4 (b): the flow evaluator follows `export const` data imports; an `export let` stays a gap | `packages/zts/src/pipeline.zig`, `packages/tools/src/precompile_imports.zig`, graph tests in `packages/tools/src/precompile.zig` | Sonnet | 40 |
| U3 | Decision 2, after U2 | `packages/zts/src/function_specs.zig`, `spec_discharge.zig`, the CHECK pass order | Sonnet | 50 |
| U4 | The ZTS500 hint names the write to module state and its line when that write removed the property | `packages/zts/src/spec_discharge.zig` and its caller | Sonnet | 40 |
| U5 | Multi-module tests: a dependency that writes its own module array, a handler that pushes onto an imported array, and a handler that passes an imported array to an imported helper that writes its parameter | graph tests in `packages/tools/src/precompile.zig`, `scripts/smoke-v1.sh` if a CLI case is needed | Sonnet | 30 |
| U6 | `docs/verification.md` section 7, this plan, `docs/plans/README.md`, the native-export invariant in `packages/modules/AGENTS.md`, the website check, and the full gate | docs | Opus | not applicable |

Each unit starts with failing tests. U1 tests run the evaluator on g1, g2, g2b, g2c, p1, p8, and `seen.pop()`, and expect one event at the write node. The negative tests expect no event: `dictGet(TABLE, key)` on a module table, a push onto a request-local array, a push onto `seen.slice()`, a read of a module constant, a push during module initialization, a per-request closure (p6), and the factory shapes p3 and p9. U2 tests run `zts check` on the probes and assert the exit status, the ZTS310 warning line, and the literal property verdicts. U3 tests: `bump(seen)` under `Proof<number, "pure" | "read_only">` fails ZTS500, and `bump(local)` passes. U4 tests assert the full hint text for g1 under `Proof<Response, "deterministic">`. U5 asserts the exact line of a write in a dependency module.

U1 must list every write into the abstract heap (`weakWriteSite`, `storeGlobal`, the `top_cell` write in `writeValue`, and each other `heap.put`) and state for each why a write to persistent state cannot pass unreported. The list also covers values with no origin: a `defense_sources` row builds its result with no origin, so U1 asserts that every such row returns a primitive. A reviewer checks the list against the source before U2 starts.

Gates for each unit, unfiltered, with a private `ZIG_LOCAL_CACHE_DIR` and `DEEPSEEK_API_KEY` unset: `zig build test-zts`, `test-zts-cli`, `test-precompile`, `test-flow-census`, `test-contract-golden`, `test-expert-golden`, `test-diagnostic-corpus`, `test-standin`, `test-expert-app`, `test-cli`, `test-zruntime`, `test-proof-swallow`, `test-zts-layering`, `smoke-v1`, `test`, and `check-spine`. `test-precompile` runs the flow-precision corpus. After U2 and after U6, `bash scripts/verify.sh` runs on `main`.

## Risks

- One allocation site stands for every object it creates. The phase split removes the collision between initialization and a request. Two collisions stay: two request allocations behind the same innermost call, and a capture cell, which is one cell for each binding and not for each closure instance. U0 and U2 measure this on the corpus, and each changed verdict is listed with its cause.
- "Cleared counts as a write" changes more verdicts than the new rule alone. Today a cleared evaluation removes `deterministic` but keeps `state_isolated`, `read_only`, and `retry_safe`. After U2 it removes all of them. A step budget, `fixpoint_limit`, `unknown_callee`, and `no_operation_rule` all become shared-state findings. U0 counts these handlers separately.
- An unconditional halt during module initialization ends the evaluation with no completion, and that result is not `cleared`. The handler then proves every property because it never runs. U1 records this case and makes it a finding or explains why the runtime refuses such a program.
- A recorded corpus handler whose verdict or diagnostic text changes fails the offline replay. The corpus then needs a DeepSeek re-record, which the owner runs. U2 runs the offline replay before it commits.
- The evaluator has its own limits (`docs/plans/2026-10-18-flow-checker-sound-redesign-plan.md`). Decision 1 (a) is as sound as the evaluator's heap model. A known evaluator gap becomes a known state gap.
- Compile time can grow by one set lookup for each abstract heap write. This needs to be measured: U2 compares the wall time of the flow-precision corpus step before and after.

## U0 baseline

Measured at `bf6ad1c3` with `zts check --json` over 82 files: the 33 tracked `.ts` files under `examples/`, the 17 files of the flow-precision corpus, and the 30 files of `tests/corpus/check/good/`. The table is `/tmp/zttp-f18g/u0-baseline.tsv`, and `/tmp/zttp-f18g/u0.sh` regenerates it.

- `state_isolated` is true for every handler that reaches the verifier. No file has a ZTS310 finding.
- Six files report no `state_isolated` because they fail before verification or are not handlers: `examples/handler/feature-probes.ts`, `examples/handler/utils.ts`, `examples/sql/sql-crud.ts`, the two `lib/settings.ts` files of the flow-precision corpus, and its `sql-users/handler.ts`.
- Cleared evaluations: `zts check` does not print the count of unresolved constructs. The 48 handlers of the flow-precision corpus have none, because the test "the frozen corpus leaves no construct unresolved and has no source error" asserts it. The count for the 30 files of `tests/corpus/check/good/` is not measured.
- The p9 factory shape is measured after U2: each verdict that differs from this baseline is listed with its cause.

## Findings during execution

- U1: when module initialization never returns (for example `const x = loop()` where `loop` calls itself), the evaluator ends with no completion, no event, and `cleared` false. `zts check` then reports every property PROVEN. `zttp serve` aborts with a stack overflow at load, so no request runs. A module-level `assert false` is different: the evaluator continues, and the runtime refuses the program with `error.PrewarmFailed`. Neither case is in scope for this plan.
- U1 over-reports, which can only remove a property: a capture cell is one cell for each binding; a request object whose site a request stored in module state; a stored `req`; a property write on a function that module initialization made; and writes in code that the evaluator marks unreachable.
- U1: the handler body is not on an event's activation stack. U3 adds the handler itself.
- U1: the `defense_sources` census found 1 row that returns a primitive and 5 that return a container whose site is an origin of every field read. The census covers these rows only, not every value with no origin.
- U2: three handlers that strict code already refuses (`n1_*_keeps_zts309` in `precompile_check_tests.zig`) gain a ZTS500. Each evaluation is cleared with `no_operation_rule` on a `toFixed` call. No case records a write event.
- U2: the expert diagnostics tool (`packages/pi/src/tools/pi_repair_plan.zig`) reads verifier diagnostics from the CHECK observer, and the observer ran before the flow writes were found. The tool then omitted the flow-sourced ZTS310 warning that `zts check` reports. The R7c census in `packages/pi/src/tools/common.zig` found 6 differences, one for each new corpus case. The fix finds the writes before the observer runs and passes the observer the same warnings.
- U2: the ZTS500 hint for a capsule that a module-state write broke still names `Date.now()`, `Math.random()`, and `performance.now()`. U4 replaces it.
- U2b: admission refuses `export let` and `export var` (`error.MutableExport`), and the parser refuses export lists and re-exports (ZTS002). No live-binding export reaches the evaluator, so the `const` test in `flowExportedBindingNode` is a defense only.
- U2b: a graph compile without `-Dverify` now extracts the flow facts, as a single-module compile already did. Before U2b, the graph path lost them because it did not follow `export const saveAlias = save`.
- U2b: a direct `seen.push(1)` on an imported array is a verifier ZTS310 error already, so the U2b write tests use an alias through a helper.

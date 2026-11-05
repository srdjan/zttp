# F18 residual gaps: module-state writes the verifier cannot name

The F18 plan (`2026-11-05-f18-module-state-proofs-plan.md`) recorded five residual gaps after H1 to H3. The owner asked for a plan for them on 2026-11-05. This document is that plan. It is not approved.

## Status

| Unit | Status |
|---|---|
| U0 | Not started |
| U1 | Not started |
| U2 | Not started |
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

## Decision 3: execution

Option (a), recommended: run U0 to U6 in order and commit each unit on local `main`. Do not push. Stop after U0 when a corpus handler would lose `state_isolated` without a real write to module state, and report the list.

Option (b): run U0 only and return the measurements for review.

## Units

| Unit | Change | Main files | Model | Turn budget |
|---|---|---|---|---|
| U0 | Measurement, no code change. Record each corpus handler's verdicts for `state_isolated` and the six H2 properties. Count the handlers whose evaluation is `cleared` today, and the factory shape of p9 | `/tmp` only; answers go into this plan | Opus | not applicable |
| U1 | Persistent-write events in the flow evaluator: the phase split, the union over passes, and a written over-approximation argument for each heap write path. Each event carries the write node, its module, and the activation stack | `packages/zts/src/flow_interp.zig`, `flow_value.zig`, `flow_report.zig`, `flow_checker.zig` | Sonnet | 60 |
| U2 | The evaluator fact joins `shares_state` on every writer. A finding that the verifier did not make is a ZTS310 warning at the write node in the module that holds it, not at the handler's call | `packages/tools/src/precompile_check_run.zig`, `precompile.zig`, `precompile_graph_check.zig` | Sonnet | 50 |
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

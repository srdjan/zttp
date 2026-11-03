# Callback parameters and Result types, 2026-11-02

Status: complete 2026-11-02 on local `main`, units C1, R1, R1b, R2a, R2b, and D. U3 stopped at its entry check; see the execution record. Approved 2026-11-02: the owner chose option (a) of Decision 1 and option (a) of Decision 2 at the end of the builtin result types plan. The approval covers this plan, the fixes, and local commits. It does not cover a push, a provider call, or a re-record.

Decision 1 (a): an annotated callback parameter of a builtin array method must accept the value that the runtime passes, or the call gets ZTS203. Decision 2 (a): give the `zttp:result` combinator callbacks their types, then run the U3 entry check of the [builtin result types plan](2026-11-02-builtin-result-types-plan.md) again.

The reviews found that the Result types of the virtual modules hold false claims today. Typing the combinators on top of those claims would extend them. So this plan first makes the Result types true (R1, R2a), and then types the combinators (R2b).

## Findings

Each probe ran on the `zts` and `zttp` binaries built from `977143a2`. A "false proof" passes `zts check` with every property PROVEN and then faults under `zttp dev`.

- P1 (false proof): `xs.map((s: string) => s.toUpperCase())` over `number[]`. `zttp dev` answers 500 (`map` error `NotCallable`). The same holds for a receiver of type `number[] | string[]`.
- P2: `xs.map(up)` with `function up(s: string): string` over `number[]` passes `zts check`, and so does `xs.filter((s: string) => s.toUpperCase() === "A")`. `xs.map(sha256)` over `number[]` serves `[null,null]`.
- P3: `ok(21)` and `err("x")` have the type `{ ok: boolean; value?: unknown; error?: string; errors?: unknown }`. The parameter of a `mapResult` callback has no type. `unwrapOr(ok(21), 0)` is `unknown`.
- P4 (false proof): after `const r = err(5)`, `if (!r.ok)`, and `if (e !== undefined)` with `const e = r.error`, the call `shout(e)` passes, where `shout(s: string)` returns `s.toUpperCase()`. It faults: "Possible soundness incident ... at 3:10". The direct form `e.toUpperCase()` also faults, at 7:28, but the cause of that form is P9.
- P5 (false proof): `andThen(ok(1), (n) => n + 1)`. The runtime returns `undefined` for a callback result that is not a Result, and a read of `r.error` on it faults.
- P6 (false proof): `collectAll([1, 2])`. The runtime answers `err(undefined)` for an element that is not a Result.
- P7 (false proof): `mapResult({ ok: true, value: 21 }, (n: number) => String(n))`. The checker admits a record literal where a Result is expected, the runtime returns that record unchanged, and a string method on its `value` faults at 5:24.
- P8: the U3 entry check of the builtin result types plan failed. It refused `n * 2` and `n + 1` in the `mapResult` and `andThen` callbacks of `examples/patterns/result-combinators.ts`, and `addOne(iterations) + 1` in the runtime fixture "loadCodeNoHandler supports imported benchmark-style scripts" in `packages/runtime/src/zruntime_tests.zig`. It also added diagnostics to programs that strict mode already refuses, and to two corpus cases that read a `Dict` value.
- P9 (false proof, found during revision 1): a call of a member that the receiver type does not have passes when the receiver is a `number` or `unknown`. `const n: number = 5; n.toUpperCase()` faults at 3:24 with `NotCallable`, and so does `e.toUpperCase()` on the `unknown` error of `requestText`. A record receiver gets ZTS201 for a missing member.

### Cause

- P1 and P2: no check compares a callback's parameter types with the values that the array method passes. `map`, `forEach`, and `reduce` have no function type, so `checkCallArgs` in `packages/zts/src/type_checker.zig#TypeChecker` checks no argument. `filter`, `find`, `findIndex`, `some`, and `every` have the predicate type `() => boolean`. An inline callback reaches the check through `functionExprType`, which drops its parameters, so it always passes. A named predicate with parameters fails `isFunctionAssignable` in `packages/zts/src/type_pool.zig#TypePool` on its parameter count, which refuses valid code.
- P3 to P7: `populateModuleTypes` in `packages/zts/src/module_types.zig` gives every export that returns `.result`, and every `.result` parameter, one shared record with `value?: unknown` and `error?: string`. A `.result_fn` or `.result_list` parameter is the coarse `object`. A Codex census found the `.result` exports in nine modules. Codex reports that only `jwtVerify` returns string errors; R1 confirms each export from its runtime code. The `zttp:result` exports store any value as the error, and the other modules store records, or strings and arrays under `errors`. `sseEvents` declares its own types.
- The combinators in `packages/zts/src/builtins/result.zig` return a value that is not a native Result unchanged. `andThen` and `orElse` turn a callback result that is not Result-like into `undefined`, and `collectAll` answers `err(undefined)` for an element that is not a Result.
- P8: the combinator callbacks have untyped parameters (P3). The runtime fixture loads a script with no handler. That load runs `pipeline.resolve` with `.strict = false`, and the sound-mode checker runs on it.
- P9: `inferMemberAccessType` in `packages/zts/src/type_checker.zig#TypeChecker` reports a missing member only for a record receiver. For any other receiver that is not a union, an array, or a tuple, it returns no type and reports nothing, so a call of the member is not checked.

## Target

- T1 (Decision 1): for a call of `map`, `filter`, `find`, `findIndex`, `forEach`, `some`, `every`, `toSorted`, or `reduce` on an array, a tuple, or a union of arrays, each parameter of the callback argument accepts the value that the runtime passes in its position. A parameter past the passed values accepts `undefined`, or is optional. This holds for an inline callback and for a named function. A callback that breaks it gets ZTS203. A named predicate whose parameters accept the element is no longer refused.
- T2: the `error` field of a Result that a virtual-module export returns has the type of the error value that the runtime stores, and `unknown` where that value has no single type. A census over every export that returns `.result` fails when an export has no error row.
- T3: a `.result` parameter accepts only a marked Result record (`isResultRecord`), so a record literal gets ZTS203. A `.result_fn` callback must return a marked Result record, and a `.result_list` argument must be an array of marked Result records; otherwise ZTS203.
- T4 (Decision 2): the `zttp:result` exports carry the value type and the error type of their Results. An inline combinator callback takes the value type or the error type as its parameter type. An annotated or named callback must accept it, as in T1.
- T5: no new diagnostic code. The refusals use ZTS203, ZTS200, and the existing arithmetic codes.
- T6 (conditional, U3 again): the arithmetic check refuses an operand with no type where `ResolveOptions.strict` is set.

No change to `packages/proof-checker` or to the runtime builtins.

## Design

1. Callback acceptance (C1). A new check in `checkCallArgs` runs before the function-type branch. It finds the array method by name. The receiver is an array, a tuple through `tupleToArrayType`, or a union of arrays, whose element type is the union of the element types. It reads the callback argument's function type: for an inline callback the type that `inferType` gives a function value, with `unknown` for an unannotated parameter; for a named function or an import its signature. The passed values are `(element, index, array)` for `map`, `filter`, `find`, `findIndex`, `forEach`, `some`, and `every`, `(element, element)` for a `toSorted` comparator, and `(accumulator, element, index, array)` for `reduce`. An annotated `reduce` accumulator must accept the seed type (the element type with no seed) and the callback's return type. A parameter past the passed values must be optional or accept `undefined`; this needs a new helper beside `callbackAccepts`, which refuses extra parameters. Message: `callback parameter '<name>' is '<P>', but <method> passes '<V>'`, on the callback argument. Help: `annotate the parameter with the type that the method passes, or remove the annotation`. For the five predicate methods, the existing argument check against `() => boolean` must not refuse a callback that the new check accepts; the predicate's return type is still checked. The executor reads `packages/zts/src/builtins/array.zig` for what a predicate and a comparator must return.
2. Result error types (R1). A table beside `populateModuleTypes` gives the error type of each export that returns `.result`, taken from its runtime `err` paths: `string` where every stored error is a string, and `unknown` otherwise. The census iterates the exports of `builtin_modules.all` and fails on a missing or stale row. An export with its own declared types, such as `sseEvents`, keeps them. A `.result` parameter uses a record with `value?: unknown` and `error?: unknown`, so a Result with any error is accepted as an argument. `requestText`, `requestJson`, and `JSON.tryParse` keep their records.
3. Result argument shapes (R2a). A `.result` parameter needs a marked Result record. A `.result_fn` parameter needs a function whose return type is a marked Result record. A `.result_list` parameter needs an array whose element type is a marked Result record. An argument with no type keeps today's behavior. The message names the export and the expected Result. `ok(x)` gets a Result with the value type of `x` (widened) and the error type `never`. `err(e)` gets the value type `never` and the error type of `e`. `unwrapOr(r, d)` gets the join of the value type of `r` and the widened type of `d`. In these rows `never` counts as a definite type.
4. Result joins (R2a). A join of two marked Result records is one marked Result record whose value type and error type are the joins of the two. It is not a union of records, so field reads keep the Result rules. This applies at every place that `joinTypes` meets two Result records and in the rows below.
5. Combinator types (R2b). A call of a `zttp:result` export, resolved through `resolveImportedExport` so that a local function of the same name keeps its own type:
   - `mapResult(r, f)`: value the return type of `f`, error the error type of `r`.
   - `mapError(r, f)`: value the value type of `r`, error the return type of `f`. Read how `resultMapErr` treats `errors` before the row.
   - `andThen(r, f)`: the join of the Result that `f` returns and a Result with value `never` and the error type of `r`.
   - `orElse(r, f)`: the join of a Result with the value type of `r` and error `never`, and the Result that `f` returns.
   - `collectAll(rs)`: value the array of the joined value types, error the joined error types.
   When a needed type has no type, the call keeps today's record. `bindCallbackElement` binds the parameter of an unannotated inline callback of `mapResult` and `andThen` to the value type, and of `mapError` and `orElse` to the error type. An annotated or named callback must accept that type (the C1 rule, with ZTS203).
6. Untyped arithmetic operand (U3). The change of design item 7 of the builtin result types plan, applied only when `ResolveOptions.strict` is set. The executor confirms that the path that serves and proves a handler runs with `strict` set, and that the `strict = false` runs (`handler_instance.zig` at runtime load, and the contract extraction in `runtime_cli.zig`) do not produce the proof. The entry check of that plan runs again first. U3 proceeds only when each refused operand in `examples/`, `tests/corpus/`, the fixtures, and the offline replay holds a value whose type is unknown at runtime, or sits in a program that strict mode already refuses. A corpus golden whose operand is a `Dict` value may take the new diagnostic. A diagnostic help that suggests a form that U3 refuses, such as the ZTS628 `dictFold` suggestion, stops U3.

### Known new refusals

- An annotated callback parameter that does not accept the element, inline or named: `xs.map((s: string) => ...)` over `number[]`, and `xs.map(sha256)` over `number[]`.
- A read of `r.error` as a `string` when the export's error is not a string, which is most `.result` exports.
- A record literal where a Result is expected, an `andThen` or `orElse` callback that does not return a Result, and a `collectAll` element that is not a Result.
- A combinator callback body that misuses the value type, such as `mapResult(ok(21), (n) => n.toUpperCase())`.

## Units

Every unit runs with a private `ZIG_LOCAL_CACHE_DIR` and with `DEEPSEEK_API_KEY` unset. The executor does not commit. Opus reviews the diff, runs the gates, and commits each unit. The units run in this order, one at a time.

| Unit | Model | Scope | Acceptance | Turn budget |
|---|---|---|---|---|
| C1: callback acceptance | Sonnet | `packages/zts/src/type_checker.zig` and tests | P1 and P2 are refused, a named predicate whose parameter accepts the element is accepted, and the C1 tests fail before and pass after | 40 |
| R1: Result error types | Sonnet | `packages/zts/src/module_types.zig`, a table file in the same tier, the census, and tests | P4 is refused. The census fails when a row is removed | 50 |
| R2a: Result argument shapes, `ok`, `err`, `unwrapOr`, joins | Sonnet | `packages/zts/src/type_checker.zig`, `module_types.zig`, and tests | P5, P6, and P7 are refused. `unwrapOr(ok(21), 0)` is `number` | 50 |
| R2b: combinator types and callbacks | Sonnet | `packages/zts/src/type_checker.zig` and tests | `examples/patterns/result-combinators.ts` gives `n` the type `number` and passes. The R2b tests fail before and pass after | 50 |
| U3: untyped arithmetic operand in strict code | Sonnet | `packages/zts/src/bool_checker.zig`, the strict flag, and tests | Runs only when the entry check passes. The U3 tests fail before and pass after | 40 |
| D: record and docs | Opus | `docs/typescript.md`, `docs/roadmap.md`, `CHANGELOG.md`, `docs/plans/README.md`, this plan, and `../ZTTP-WEBSITE` if a claim changes | `zig build test`, `bash scripts/verify.sh`, and `zig build test-zruntime` exit 0 from an empty cache | Opus |

Gates for each unit: `zig build test-zts`, `test-zts-layering`, `test-diagnostic-corpus`, `test-examples`, `test-cli`, `test-contract-golden`, `test-expert-golden`, `test-expert-app`, `test-proof-swallow`, `test-module-boundary`, `test-zruntime`, `test-precompile`, and `zig fmt --check` on the changed files. R1, R2a, and R2b also run `test-modules` and `test-flow-census`.

## Stop conditions

- The offline replay in `test-expert-app` diverges. The change is then model-visible under D-012, and the approval does not cover a re-record. Stop before the commit and report the case and the diagnostic.
- A change refuses a program in a committed example, fixture, or corpus draft that runs correctly. Stop and hand back the program, the form, and the diagnostic. A golden of a program that strict mode already refuses can take the new diagnostic; say so in the hand-back.
- A runtime result or error value is not clear from the runtime code. Stop and report the export.
- `packages/proof-checker` would need a change.

## Out of scope

- A check of the other arguments of a builtin call (T4 of the builtin result types plan).
- The partly annotated parameter defect: `(v, i: string)` binds the annotation to `v`. Strict mode refuses that form.
- Precise record types for the error values of the other modules. They get `unknown` here.
- P9, the unchecked member call on a receiver that is not a record. Its fix is a new refusal over every program, so it needs its own decision and an entry check. Until then, a precise type for a value closes only the paths that pass the value to a typed position, such as P4. It does not close a method call on the value.
- The other gaps under Current Limitations in `docs/roadmap.md`.

## Validation record

Revision 1, 2026-11-02. A Fable review attacked the design and ran probes, and a Codex (gpt-6-astra, read-only) review checked nine facts. Opus checked the load-bearing claims before acting on them.

- Codex: the `.result` exports in nine modules store records or any value as the error; only `jwtVerify` stores strings. P4 is therefore wider than `err(5)`, and R1 covers every export.
- Codex: `andThen` and `orElse` turn a callback result that is not Result-like into `undefined`, and `collectAll` answers `err(undefined)` for an element that is not a Result. Fable ran both as false proofs (P5, P6). R2a refuses both shapes.
- Codex: the `filter` predicate check passes an inline callback only because `functionExprType` drops its parameters, and it refuses a named predicate with parameters. Opus confirmed it in `isFunctionAssignable`. C1 takes over the parameter check for the five predicate methods.
- Fable: the combinators return a record literal unchanged, so typing `mapResult` from its callback would claim a value that the runtime does not hold (P7, run as a false proof). R2a requires a marked Result at a `.result` parameter.
- Fable: the shared parameter record (`error?: string`) would refuse `mapResult(err(5), f)`; `never` is not definite in `isDefiniteType`; and a join of two Result records is a union that loses the Result marking. Design items 2, 3, and 4 resolve each one.
- Fable: a union of arrays passes P1 as well. C1 covers a union receiver.
- Fable: the corpus cases that read a `Dict` value run correctly and would take the U3 diagnostic, and the ZTS628 suggestion uses an untyped `dictFold` value. Design item 6 states which rule wins.
- Fable: R2 was too large for one unit. It is split into R2a and R2b, and the units run in order.
- Opus, during the revision: a method call on a `number` or an `unknown` value is not checked (P9). The R1 acceptance therefore uses the measured P4 form that passes the error to a `string` parameter.

## Execution record

| Unit | Commit | Result |
|---|---|---|
| C1 | `8bf7322e` | Annotated and named array callbacks must accept what the method passes (ZTS203). P1 and P2 closed |
| R1 | `83136e36` | A module Result's `error` has the type that the runtime stores; 25 rows and a census. P4 closed through a typed position |
| (tests) | `4f56f80e` | The tests in `packages/tools/src/precompile_check.zig` ran in no build step; `test-precompile` now runs them |
| R1b | `d0f0f38c` | `zts check --types` prints the same Result error types |
| R2a | `e2ff5b98` | Result argument shapes, `ok`, `err`, `unwrapOr`, and Result joins. P6 and P7 closed |
| R2b | `da79840f` | Combinator types, combinator callback bindings, annotated callback bindings, and the `errors` field. P5 and P10 closed |
| (golden) | `c486b209` | The bytecode identity golden of the corpus case that R1 rewrote |
| U3 | none | The entry check failed again; see "U3 entry check" below |
| D | this commit | `docs/typescript.md`, `docs/roadmap.md`, `CHANGELOG.md`, the plan index, and this record |

Each unit ran its gates unfiltered with a private cache and no provider key. The offline replay in `test-expert-app` held at every unit, so no change was model-visible.

### Deviations from the plan

- C1: Opus found that the return-only predicate comparison applied to every member call with a `() => X` parameter, so a record method `run(cb: () => number)` accepted a named `g(n: number)` again. The comparison is now limited to the five array predicate methods. Opus also found that a named `reduce` callback skipped the accumulator return check. Both had failing tests first.
- R1: Opus found a second Result builder, `typedResultType`, used for the schema-literal calls of `zttp:validate` and `zttp:decode`, that hardcoded a `string` error. It now reads the same row. The corpus case `result_error_may_be_absent.ts` read a `parseJson` record error as a `string`; it now uses `validateJson`.
- R1b was added by Opus. The `.d.ts` that `zts check --types` writes still claimed `error?: string` for every Result. The fix exposed that the tests of `precompile_check.zig`, including the frozen signature digest, ran in no build step.
- R2a: Opus made a `.result_fn` callback that returns `unknown` or raw JSON a refusal, as a `.result` argument of those types already was.
- R2b: Opus sent the unit back with four findings. A probable false proof (P10): a validate or decode schema failure fills `errors` and leaves `error` absent, yet `r.error` read as `string` after `!r.ok`. The runtime probe could not register a schema, so P10 rests on the code in `validate.zig`. A Result now tracks `errors`, and `error` admits `undefined` where `errors` is not `never`. The combinator parameter check had accepted any annotation where the passed type was `unknown`; it now compares as C1 does. A fully annotated inline callback now binds its parameters before the call checks, because C1's inline `reduce` return check and the P5 check saw no return type for a body that reads a parameter.
- The bytecode identity golden: R1's gate list did not include `test-bytecode-identity`, which failed from R1 until `c486b209`.
- The record-literal refusal: the runtime accepts a record literal shaped like a Result as an `andThen` or `orElse` callback return and as a `collectAll` element (`coerceResultLike`). The checker refuses it, which `docs/typescript.md` states.

### U3 entry check

The entry check failed, so U3 was not built. The executor gated the change on `ResolveOptions.strict`, confirmed that every path that produces a proof or a user-visible verdict runs strict, and ran the built `zts check` on all 264 tracked `.ts` files. `examples/patterns/result-combinators.ts` and the runtime fixture no longer stop it. Three stop conditions held:

- The R7c tool census in `test-expert-app` moves from 124 to 129 diagnostics, the five new diagnostics of the corpus `bad` cases. That is model-visible under D-012, and this approval does not cover a re-record.
- The change refuses `dictFold(d, (acc, value, key) => acc + value, 0)`, the form that the ZTS628 help recommends, because the `dictFold` callback parameters have no type.
- In the A3 precompile fixture, `ps[0].age + ps[1].age` over `ps: P[]` loses its three ZTS309 diagnostics and gets two "no known type" diagnostics instead, because `ps[0].age` has no type.

The refused operands were otherwise acceptable: unannotated parameters in `examples/handler/feature-probes.ts` and `missing_parameter_annotation` (programs that strict mode refuses), and `Dict` values in the `bad` cases `dict_entries_reduce` and `dict_entry_round_trip`. `docs/roadmap.md` records the three blockers.

### Findings outside this plan

- P9 stays open: a call of a member that a `number` or `unknown` receiver does not have passes and faults with `NotCallable`.
- `dictFold(d, f, 0)` refuses a `Dict<string, number>` argument (ZTS203, `expected Dict<unknown, unknown>`), on the binary from before this plan and after it.
- An index read followed by a member read, such as `ps[0].age`, has no type.

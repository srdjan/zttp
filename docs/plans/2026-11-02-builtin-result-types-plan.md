# Builtin result types, 2026-11-02

Status: complete 2026-11-02 on local `main`: U1a, U1b, U2, and U4 done; U3 stopped at its entry check. Validated 2026-11-02 (revision 1). Approved 2026-11-02: the owner chose option (a) of Decision 2, which gives the untyped numeric builtins a type (B1 of the arithmetic operand types plan). The approval covers this plan, the fix, and local commits. It does not cover a push, a provider call, or a re-record.

B1 is wider than the numeric forms. The type checker gives no type to the result of most builtin calls and builtin property reads. A builtin result therefore passes at every typed position, and a handler that uses it wrongly can prove `optionals_safe` and then fault. This plan types the result of each builtin call whose arguments have the types that the runtime reads, and closes the set with a census.

## Findings

Each probe ran on the `zts` and `zttp` binaries built from `c92f8f67`. A probe line assigns one form to `structural Nope = { zz: Bytes };`. A typed form gets ZTS200, and an untyped form gets no diagnostic.

- Census 1 (60 forms): 4 typed (`toSorted`, `findIndex`, `filter`, `some`) and 56 untyped. The untyped forms include `xs.length`, `s.length`, each `Math` method, `Math.PI`, `parseInt`, `parseFloat`, `Number(...)`, each `Number` method, `xs.indexOf`, `xs.includes`, `xs.join`, `xs.slice`, `xs.concat`, `xs.map`, `xs.reduce`, each string method, `String(...)`, `String.fromCharCode`, `JSON.stringify`, `JSON.parse`, `Object.keys`, `Array.isArray`, `Boolean(...)`, `Date.now()`, and `range(3)`.
- Census 2 (20 forms): 8 typed (`requestBody`, `requestText`, `requestJson`, `isDict`, `isBytes`, `toReversed`, `find`, `every`) and 12 untyped, including `renderToString`, `Object.values`, `Object.entries`, `Object.hasOwn`, `Array.of`, `Array.from`, `xs.pop()`, `JSON.tryParse`, the element of `for (const i of range(3))`, and the result of `xs.reduce((acc, v) => acc + v, 0)`. The strict stage admits that `reduce` callback with unannotated parameters.
- Literal receivers are also untyped: `"abc".length` and `[1, 2].length`.
- False proof F1: `const a: string = xs.length;` passes `zts check`. A handler that returns `a.toUpperCase()` proves `optionals_safe`, and `zttp dev` answers 500 with "Possible soundness incident".
- False proof F2: `const token: string = req.headers.get("x-missing");` passes. The runtime returns `undefined` for a missing header, and `token.toUpperCase()` answers 500 with "Possible soundness incident". Three examples call `req.headers.get`: `examples/fetch/webhook.ts`, `examples/fetch/weather-forecasts.ts`, and `examples/routing/api-surface.ts`.

### Cause

`inferCallType` and `inferMemberAccessType` in `packages/zts/src/type_checker.zig#TypeChecker` type a call through a known signature, a record field, a union member, the five `Response` constructors, the request readers, and seven array methods in `inferArrayMethodType`. A builtin namespace such as `Math` is a global with no binding type, a string receiver has no method model, and `.length` is not modeled on a string or an array. Each answers `null_type_idx`. The assignability checks read `null_type_idx` as a pass. The boolean-context check is the exception: it refuses an operand with no type.

### The runtime results

A builtin returns its normal result only when its arguments have the types it reads. `Math.floor` returns `undefined` when it gets no argument or a non-number (`toNumber(arg) orelse return undefined` in `packages/zts/src/builtins/math.zig`). `split` with a non-string separator and `repeat` with an invalid count also return `undefined`. A type for the result is therefore true only under arguments of the right type. Other facts that the rows must follow:

- `range(n)` returns a lazy iterator with no prototype, not an array. Only `for...of` and `.length` read it.
- `reduce` returns the last callback result, or the initial value on an empty array. With no initial value, an empty array throws.
- `concat` returns the receiver's elements and the arguments' elements, so the element type can grow.
- `pop`, `shift`, and `find` return `undefined` on an empty array or no match. `Headers.get` returns `undefined` for a missing header.
- `JSON.parse` returns the parsed value, or `undefined` on invalid text. JSON `null` becomes `undefined`. `JSON.tryParse` returns a Result. `JSON.stringify` returns `undefined` when it cannot serialize the value.
- Only `Math.PI` is installed. The other seven constants in `math_constants` are Zig declarations that the runtime does not install, so `Math.E` reads `undefined`. `Number` has 8 installed constants: `MAX_VALUE`, `MIN_VALUE`, `NaN`, `POSITIVE_INFINITY`, `NEGATIVE_INFINITY`, `MAX_SAFE_INTEGER`, `MIN_SAFE_INTEGER`, and `EPSILON`.
- `console` and the `Result` global are refused in a handler (ZTS629). A typed Result record has no method members (ZTS201).

### The registry to census

`operation_rows` in `packages/zts/src/flow_rules.zig` has 101 rows over 13 scopes. The census C1 checks it against the callable members of the namespace objects, so it does not cover every installed name. The rest is in `runtime_prototype_rows` (`Request.prototype`, `Headers.prototype`), `runtime_global_rows` (`fetchSync`), and the name lists `names` and `runtime_only_names` in `packages/zts/src/known_globals.zig` (for example `Boolean`, `isNaN`, `isFinite`, `performance`, and the Error constructors).

## Target

- T1: a call of a builtin, and a read of an installed builtin constant or of `.length` on a string or array, has a result type when every argument has the type that the runtime reads and the argument count is in the runtime's range. The type is the runtime's result for such arguments. When the runtime can still return `undefined` for such arguments, the type includes `undefined`. When an argument has no type or the wrong type, the result stays untyped, as today.
- T2: a census fails when an installed name has neither a result row nor an allowlist row that states why it stays untyped, or when an allowlist row names a member that has a row.
- T3: the builtin row applies only when the namespace or global identifier's binding kind is `.global` or `.undeclared_global`. A parameter, a local, or an import with the same name keeps its own type.
- T4: no new argument diagnostic. The argument rule in T1 decides only whether the result has a type.
- T5 (U2): a callback's index parameter, the parameters of a `toSorted` comparator, the accumulator and element of a `reduce` callback, and the element of `for...of` over `range(...)` have types. An annotation wins.
- T6 (U3, conditional): the arithmetic check refuses an operand with no type, which the arithmetic operand types plan left open as its T4.

No new diagnostic code. No change to `packages/proof-checker`, to the runtime builtins, or to the rows of `flow_rules.zig`.

## Design

1. A result-row table keyed by scope and name, with the scope strings of `flow_rules.zig`. Each row declares the parameter types that the runtime reads, the accepted argument count, and a result shape. The executor takes each row from the runtime code in `packages/zts/src/builtins/`, `packages/zts/src/http.zig`, and `packages/runtime/src/runtime_http.zig`, and writes the runtime fact beside any row whose result differs from TypeScript's.
2. Result shapes:
   - fixed: `number`, `boolean`, `string`, `string[]`, and the same with `| undefined` where the runtime can return `undefined` for well-typed arguments (`Headers.get`, `repeat`).
   - receiver: the receiver array (`slice`, `splice`, `toReversed`, `toSorted`, `filter`), and the element type with `| undefined` (`pop`, `shift`, `find`).
   - argument: `concat` gives the array of the union of the receiver's and the arguments' element types. `map` gives the array of the callback's return type. `reduce` gives the join of the widened initial value type and the callback's return type; with no initial value, the element type. `Object.keys`, `Object.values`, and `Object.entries` take the record's field names and the union of its field types; for a `Dict` or another argument, the result stays untyped unless the runtime fact gives a type. `Array.of` gives the array of the union of its argument types. `Array.from` gives `string[]` for a string and the same array for an array.
   - Result: `JSON.tryParse` gives the Result record that `requestJson` already uses, with an `unknown` value.
   - existing: a member that the checker already types keeps its type.
   - `JSON.parse` gives `unknown`. `JSON.stringify` gives `string` when its argument's type is one that ZTS213 accepts, and otherwise stays untyped.
   When a shape needs a type that is unknown, the result stays untyped. The result is not `unknown[]`, because `unknown[]` would refuse valid code such as `const vs: number[] = Object.values({ a: 1, b: 2 });`.
3. Receivers. The table lookup widens a literal receiver with `widenLiteral`, and routes a tuple through `tupleToArrayType`. A union receiver such as `string | string[]`, an optional chain such as `s?.length`, and a builtin member read as a value such as `const f = Math.floor;` stay untyped and have allowlist rows.
4. Call sites. In `inferCallType`, after the existing lookups, take the result from the table for a member call on a builtin namespace identifier (T3), on a string or array receiver, or on a `Headers` value, and for a bare global call that no signature or callable binding already answers. Property reads (`.length`, `Math.PI`, the `Number` constants) go through `inferMemberAccessType`. The table does not give a builtin member a function type, so `checkCallArgs` sees nothing new (T4).
5. Census (T2). One test iterates `operation_rows`, `runtime_prototype_rows`, `runtime_global_rows`, `known_globals.names`, `known_globals.runtime_only_names`, the installed constants, and `.length` on a string, an array, and a range iterator. Each needs a row or an allowlist row. Allowlist reasons for a name that a handler cannot reach name the refusal code, for example ZTS629 for `console`. `range` and the `Result.prototype` members are allowlisted with the runtime facts above. The test sits in the compiler tier of `packages/zts/src`, as `scripts/zts-tiers.allow` places `flow_rules.zig` and `type_checker.zig`.
6. Callback parameters (U2). `bindCallbackElement` binds parameter 0 of `map`, `filter`, `find`, `findIndex`, `forEach`, `some`, and `every` today. It also binds the index parameter (`number`) of those seven; both parameters of a `toSorted` comparator (the element type); and the accumulator (the widened initial value type) and the element of a `reduce` callback. The `for...of` element over `range(...)` is `number`. `flatMap` is not installed, so it is left out.
7. Untyped arithmetic operand (U3). In `requireNumeric` and `requireAddable` in `packages/zts/src/bool_checker.zig#BoolChecker`, an operand with no type gets ZTS104 or ZTS106 with the message `operand of '<op>' has no known type; arithmetic requires numbers` (`addition requires numbers` for `+`) and the help `annotate the value with a number type, or narrow it with typeof in an if`. Skip an operand that is itself a binary `-`, `*`, `/`, `%`, `**`, or `+`, or a unary `-`: its own operands carry the check, and the type checker gives a refused or optional `+` no type.

## Tests

Each test asserts the exact code, the exact count, and, for the type rows, the exact ZTS200 message, which names the result type. Literal values only; a table of literal cases is allowed. Each new row fails before its unit (no diagnostic).

- U1a: `xs.length`, `"abc".length`, `s.length`, `Math.floor(n)`, `Math.PI`, `Number.MAX_SAFE_INTEGER`, `parseInt(s, 10)`, `Number(s)`, `Number.isInteger(n)`, `String(n)`, `s.indexOf("b")`, `s.split(",")`, `s.toUpperCase()`, `s.repeat(2)` (names `string | undefined`), `Date.now()`, `renderToString(...)`, and `req.headers.get("x")` (names `string | undefined`). F1 and F2 each get one ZTS200. `Math.floor(s)` with `s: string` stays untyped. A parameter named `Math` keeps its own type. The census passes, and removing one row makes it fail (shown once by hand and recorded).
- U1b: `xs.indexOf(1)`, `xs.includes(1)`, `xs.join(",")`, `xs.slice(0, 1)`, `xs.pop()`, `xs.concat(ys)`, `xs.map(cb)` with a typed `cb`, `xs.reduce(cb, 0)` with a typed `cb`, `JSON.stringify(xs)`, `JSON.parse(s)`, `JSON.tryParse(s)`, `Object.keys(o)`, `Object.values(o)`, `Object.entries(o)`, `Array.isArray(xs)`, `Array.of(1, 2)`, and `Array.from(s)`. `const vs: number[] = Object.values({ a: 1, b: 2 });` stays accepted.
- U2: `xs.reduce((acc, v) => acc + v, 0)` assigned to `Nope` names `number`. The index parameter of `map` names `number`. A `toSorted` comparator parameter names the element type. The `for...of` element over `range(3)` names `number`.
- U3: `p[1] * 2` with an untyped `p` gets one ZTS104. `(x + 1) * 2` with `x: number | undefined` still gets one ZTS106 and no ZTS104. `xs.reduce` over an unannotated callback stays accepted.

### Known new refusals

These programs are wrong and become refused. Each one names a value that can be `undefined`:

- `const first: string = s.split(",")[0];`, because an index read can be `undefined`.
- `const last: number = xs.pop();`
- `const token: string = req.headers.get("x");`
- `const r: string = s.repeat(n);`

`docs/typescript.md` lists them with the guard to write.

## Units

Every unit runs with a private `ZIG_LOCAL_CACHE_DIR` and with `DEEPSEEK_API_KEY` unset. The executor does not commit. Opus reviews the diff, runs the gates, and commits each unit.

| Unit | Model | Scope | Acceptance | Turn budget |
|---|---|---|---|---|
| U1a: fixed rows, properties, globals, string methods, `Headers`, and the census | Sonnet | `packages/zts/src/type_checker.zig`, a table file in the compiler tier if needed, the census test, tests, and any fixture a gate needs | The U1a tests fail before and pass after. `zig build test-zts`, `test-zts-layering`, `test-diagnostic-corpus`, `test-examples`, `test-cli`, `test-contract-golden`, `test-expert-golden`, `test-expert-app`, `test-proof-swallow`, `test-module-boundary`, and `test-zruntime` exit 0 | 60 |
| U1b: receiver and argument shapes | Sonnet | the same files | The U1b tests fail before and pass after. The U1a gates exit 0. The census allowlist shrinks by the rows that U1b types | 50 |
| U2: callback parameter types | Sonnet | `packages/zts/src/type_checker.zig` and tests | The U2 tests fail before and pass after. The U1a gates exit 0 | 40 |
| U3: refuse an untyped arithmetic operand | Sonnet | `packages/zts/src/bool_checker.zig`, tests, and fixtures | Runs only when the U3 entry check passes. The U3 tests fail before and pass after. The U1a gates exit 0 | 40 |
| U4: record and docs | Opus | `docs/typescript.md`, `docs/roadmap.md`, `CHANGELOG.md`, `docs/plans/README.md`, this plan, and `../ZTTP-WEBSITE` if a claim changes | `zig build test` and `bash scripts/verify.sh` exit 0 from an empty cache; `test-zruntime`, `check-spine`, and `test-doc-links` exit 0 | Opus |

U3 entry check: after U2, the executor applies the U3 change in a scratch copy and lists every arithmetic operand with no type in `examples/`, `tests/corpus/`, the test fixtures, and the recorded corpus that the offline replay runs. U3 proceeds only when each listed operand holds a value whose type is unknown at runtime, such as a `Dict` value or a raw JSON value. Otherwise U3 stops and hands back the list. The arithmetic plan's T4 then stays open in the roadmap, with the list.

## Stop conditions

- The offline replay in `test-expert-app` diverges. The change is then model-visible under D-012. Stop before the commit and report the case and the diagnostic.
- A result type refuses a program in a committed example, fixture, or corpus draft that runs correctly. Stop and hand back the program, the form, and the diagnostic. Do not weaken the type. A refusal of a form under "Known new refusals" in a committed program is also a stop, because that program needs an owner decision.
- A runtime result is not clear from the runtime code. Stop and report the member.
- `packages/proof-checker` would need a change.

## Out of scope

- Argument diagnostics for builtins (T4). A builtin call with an argument of the wrong type stays untyped and can still fault; U3 refuses it only at an arithmetic operator.
- A member read on `unknown`, such as `JSON.parse(s).name`, which passes today.
- A union receiver, an optional chain, and a builtin member read as a value (design item 3).
- The types that a `zttp:` virtual module export declares, such as the coarse `object` from `dictEntries`.
- A `reduce` with no initial value on an empty array, which throws.
- The other gaps under Current Limitations in `docs/roadmap.md`.

## Validation record

Revision 1, 2026-11-02. A Fable review attacked the design, and a Codex (gpt-6-astra, read-only) review checked the facts. Opus checked the load-bearing claims before acting on them.

- Codex and Fable: builtins return `undefined` on a wrong argument. Opus confirmed `Math.floor` in `math.zig`. The first draft claimed "the type the runtime produces" with no argument condition. T1 now types a result only under arguments of the right type, so a row makes no false claim, and T4 still adds no argument diagnostic.
- Codex: only `Math.PI` is installed, `range` is an iterator, `concat` and `reduce` can change the element type, and `operation_rows` has 101 rows, not about 137. The shapes and the counts are corrected.
- Fable: `Headers.get` is outside `operation_rows` and untyped. Opus ran F2 under `zttp dev`: 500 "Possible soundness incident". The census now covers the runtime rows and both name lists.
- Fable: the shadowing test in `inferResponseConstructorType` does not see a parameter. Opus confirmed that a parameter named `Math` keeps its own type today. T3 now tests the binding kind.
- Fable: a fixed `unknown[]` for `Object.values` would refuse valid code, literal receivers need widening, `flatMap` is not installed, and U1 was too large for one unit. Each is resolved above. U1 is split into U1a and U1b.
- Fable proposed function types with `unknown` optional parameters, as `inferArrayMethodType` does. Opus did not take it: it adds arity checks against T4, and `FuncParam` has no rest marker for `Math.min`, `concat`, or `push`.

## Execution record

| Unit | Commit | Result |
|---|---|---|
| Plan | `f8698757` | Revision 1, after the Fable and Codex reviews |
| U1a | `cf174f2c` | 64 result rows, a census over 137 members, and F1 and F2 closed. 18 new tests failed on the previous HEAD because no diagnostic was reported |
| U1b | `019cf970` | 21 more rows; the census has 85 rows and 52 skips, with none left for U1b. 30 new tests failed on the previous HEAD |
| U2 | `7cd53c65` | Callback parameter types and the `reduce` accumulator rule. 18 of 23 new tests failed on the previous HEAD |
| U3 | none | The entry check failed; see "U3 entry check" below |
| U4 | this commit | `docs/typescript.md`, `docs/roadmap.md`, `CHANGELOG.md`, the plan index, and this record |

### Deviations from the plan

- U1a: Opus found that the first draft typed `s.split(x)` for any separator. The runtime returns `undefined` for a separator that is not a string, so that was a false proof. A test failed first, and the `split` separator is now `string`.
- U1a: `String(a) + String(b)` gets ZTS105, because both operands now have the type `string`. That refusal is not in the list of known new refusals. The precompile fixture for an unchecked result used the form incidentally; it now uses `.join("")`.
- U1a: T3 tests the binding kind `.undeclared_global` only. A top-level declaration has the kind `.global`, so the plan's `.global` would have let a user's `const Math = ...` take the builtin rows.
- U1b: `Object.values` and `Object.entries` stay untyped, against design item 2. A record can hold a field that its type does not name (the discriminant-test gap in `docs/roadmap.md`), so the declared field types do not bound the values.
- U1b: Opus found that `map` and `reduce` took their result from the callback's return type without a check of the callback's parameters. `strings.map(g)` with `g: (n: number) => number` was typed `number[]`. Three tests failed first. A result now needs each callback parameter to accept what the runtime passes, and two draft tests that asserted the false proof were rewritten.
- U1b: `reduce` with no seed joins the element type and the callback's return type, because a longer array returns the last callback result. `JSON.tryParse` uses a Result record with a `string` error, not the `requestJson` record, whose `value` is a JSON value that refuses member reads. `JSON.stringify` has three tiers: `string` for a type of bounded depth, `string | undefined` for a recursive type, and no type when a part is `unknown`.
- U1b: the termination probe `r4` returned `[n].map(down)[0]` from a `number` function. That read can be `undefined`, the same class as `s.split(",")[0]`, so it is now refused. The probe now returns `[n].map(down)[0] ?? n`, as its sibling probes do. The recursion that the test checks is unchanged.
- U2: the `reduce` accumulator rule is an amendment by Opus. The runtime passes the seed first and each callback result after it. So the accumulator keeps the seed type only when the callback's return type is assignable to it, and a return type that is not gets ZTS200.
- U2: a callback with any annotation binds no parameter. The stored signature holds the annotated parameters without their positions, so `(v, i: string)` binds `string` to `v`. Strict mode refuses that form (ZTS601), so the defect gives a misleading extra ZTS200 and no false proof.

### Findings during execution

- An annotated callback parameter keeps its annotation when the array elements do not fit it. `xs.map((s: string) => s.toUpperCase())` over `number[]` passed `zts check` with every property PROVEN, and `zttp dev` answered 500 (`map` error `NotCallable`). Closing it needs an argument check, which T4 excludes.
- `JSON.stringify` of a record type is `string` on the assumption that a record holds only its declared fields. The serializer gives `undefined` at 512 levels of nesting. A record that holds an undeclared field with a value 512 levels deep breaks that assumption. The extra-field gap in `docs/roadmap.md` is the cause, and closing it closes this case.

### U3 entry check

The entry check failed, so U3 was not built. A Sonnet executor applied the change and ran `zts check` on the 216 `.ts` files under `examples/` and `tests/corpus/`, and the gates. The change refused these operands:

- `examples/patterns/result-combinators.ts`: `n * 2` and `n + 1` in the callbacks of the generic `zttp:result` combinators `mapResult` and `andThen`. The runtime gives a number, and the checker gives the parameter no type. This is a valid program, so the check fails.
- The runtime fixture "loadCodeNoHandler supports imported benchmark-style scripts" in `packages/runtime/src/zruntime_tests.zig`: `addOne(iterations) + 1`, a call of an imported function with an unannotated parameter. The value is always a number.
- `examples/handler/feature-probes.ts` and the corpus case `missing_parameter_annotation`: unannotated parameters in programs that strict mode already refuses.
- The corpus cases `dict_entries_reduce` and `dict_entry_round_trip`: `p[1]`, a `Dict` value from `dictEntries`. These are the only operands whose type is unknown at runtime.

`test-examples`, `test-diagnostic-corpus`, `test-expert-app` (the R7c tool census), and `test-zruntime` failed with the change. Opus restored `packages/zts/src/bool_checker.zig`. The arithmetic plan's T4 stays open in `docs/roadmap.md` with this list.

# Function values and type predicates, 2026-11-02

Status: approved 2026-11-02. The owner chose option (a) of Decision 1: fix the three type checker gaps in the roadmap, with a failing test first, and commit locally. The approval does not cover a push, a provider call, or a re-record.

The probes found four defects, not three. Two of them let a handler that `zts check` accepts fault at runtime on a path the proof calls safe. All four are in `packages/zts/src/type_checker.zig`. One also needs `packages/zts/src/type_env.zig`.

## Findings

Each probe ran on the `zts` and `zttp` binaries built at 2026-11-01 22:29. The commits after that build change only `docs/`.

### F1: a function value has no type

`inferType` in `packages/zts/src/type_checker.zig#TypeChecker` returns `null_type_idx` for an arrow function, and for an identifier bound to a function declaration or to a `const` arrow. Each assignability check reads `null_type_idx` as "unknown, pass". A function value therefore passes at each typed position that does not have its own rule:

| Position | Probe | Today | Expected |
|---|---|---|---|
| `return` from a `number` function | `return (x: number): number => x;` | passes | ZTS204 |
| `return` of a `const` arrow | `const f = (x: number): number => x; return f;` | passes | ZTS204 |
| `return` of a named function | `return g;` | passes | ZTS204 |
| `return` into `number \| undefined` | `return (x: number): number => x;` | passes | ZTS204 |
| `return` of a ternary branch | `return flag ? (x: number): number => x : 1;` | passes | ZTS204 |
| variable annotation | `const n: number = (x: number): number => x;` | passes | ZTS200 |
| variable annotation, named function | `const n: number = g;` | passes | ZTS200 |
| assignment | `n = (x: number): number => x;` | passes | ZTS200 |
| record field | `const b: Box = { n: (x: number): number => x };` | passes | ZTS200 |
| array element | `const a: number[] = [(x: number): number => x];` | passes | ZTS200 |
| tuple element | `const t: [number, string] = [(x: number): number => x, "a"];` | passes | ZTS200 |
| call argument, named function | `take(g)` with `take(n: number)` | passes | ZTS203 |
| call argument, `const` arrow | `take(f)` | passes | ZTS203 |
| call argument, nested in a record | `take({ n: (x: number): number => x })` with `take(b: Box)` | passes | ZTS203 |
| JSON payload | `Response.json({ f: g })` | passes | ZTS213 |
| call argument, arrow literal | `take((x: number): number => x)` | ZTS203 | ZTS203 (unchanged) |

Runtime effect, measured with `zttp dev`. A handler that does `const n: number = g;` and returns `Response.json({ total: n + 1 })` passes `zts check` with 0 errors under `Proof<Response, "deterministic" | "read_only">`. A GET then answers 500 with "Possible soundness incident: the handler faulted on a path proven optional_safe/result_safe". A handler that returns `Response.json({ f: g })` passes and answers 200 with `{"f":{}}`.

### F2: a predicate body is checked for its form only

`predicateTestProves` in `packages/zts/src/type_checker.zig#TypeChecker` admits a predicate when its body is one `return` of admitted tests over the named parameter. It does not compare the type the test proves with the type the predicate claims. Its own comment says so: "The check is on the form of the test".

`function isStr(x: unknown): x is string { return typeof x === "number"; }` is admitted with no diagnostic. A call `if (isStr(v))` with `v: string | number = 7` then narrows `v` to `string`. A handler that calls `v.toUpperCase()` in that branch passes `zts check` with 0 errors, and `zttp dev` answers 500 with the same "Possible soundness incident" message.

Spec section 5.7 (`docs/spec/zts-model-1.md`) says: "No annotation alone can install a false guard." F2 breaks that rule.

Correction: my report of 2026-11-02 said that this predicate on a function declaration gets ZTS211. That was wrong. ZTS211 comes only when the body is not an admitted test, such as `return x > 3;`.

### F3: a predicate outside a module-level function declaration is ignored

`admitTypePredicates` in `packages/zts/src/type_checker.zig#TypeChecker` reads a predicate only on a named module-level function declaration. It skips an arrow function, a function expression, and a declaration nested in a function body. Such a predicate gets no diagnostic, and it narrows nothing at its call sites. These forms pass with 0 type errors:

- a module-level `const isStr = (x: unknown): x is string => typeof x === "number";`
- the same `const` inside a handler body
- a function declaration with a predicate inside a handler body
- an arrow with a predicate passed as a callback argument

The narrowing is absent, so the false claim is not a false proof. It is a claim that the checker drops with no message.

### F4: a predicate that names no parameter is ignored

`function isStr(y: unknown): x is string { ... }` passes with 0 errors. `directPredicateParameterIndex` in `packages/zts/src/type_env.zig#TypeEnv` finds no parameter named `x`, and the caller returns with no predicate and no error. The function becomes an ordinary `boolean` function. It narrows nothing, and it gets no diagnostic.

### What the corpus contains

No tracked `.ts`, `.json`, or `.jsonl` file under `packages/pi/src/simulator/testdata`, `packages/pi/src/standin`, `tests`, or `examples` declares a type predicate, except `tests/corpus/check/bad/unverified_type_predicate.ts`. F2 to F4 therefore cannot move the recorded corpus. F1 can move it if a recorded handler puts a function value at a typed position. The offline replay inside `zig build test-expert-app` measures that.

## Target

- T1: each function value has a function type. A function value at a position whose type admits no function gets the code that position already uses.
- T2: a predicate is admitted only when the type its test proves for the parameter is assignable to the type it claims.
- T3: a predicate on anything but a named module-level function declaration gets ZTS211.
- T4: a predicate that names no parameter gets ZTS211.

No new diagnostic code. No change to the rule registry, the spec text, or `packages/proof-checker`.

## Design

### U1 design (F1)

1. `inferType` of an `.arrow_function` or `.function_expr` returns the type that `argumentTypeForChecking` builds today: `functionExprType` when it is not `null_type_idx`, otherwise a function with no parameters and an `unknown` return. The parameter list stays empty, as `functionExprType` documents. `isFunctionAssignable` accepts a source with fewer parameters, so an empty list never refuses at a function target. The return is compared only when both returns are known.
2. `inferType` of an `.identifier` whose binding has no type and is bound to a function returns the same shape: no parameters, and the signature's return type, or `unknown` when the signature has none. Use the binding's callable signature (`callableSignatureForBinding`) to find it.
3. `argumentTypeForInference` keeps today's result for a function literal. It calls `functionExprType` directly for an arrow or a function expression and does not go through `inferType`. The comment on it explains why: generic inference must still see an unresolved callback as unresolved, to report the call as ambiguous.
4. A call through a function binding keeps its arity from the source signature. `const f = (x: number): number => x; f(1);` must still pass, and `f(1, 2)` must still get ZTS202.

Stop condition: if a step needs a parameter list in the inferred type, stop and hand back. That is a larger change with its own risk to generic inference.

Revision 1, 2026-11-02. The U1 executor reached this stop condition. With an empty parameter list, `const JSON = { stringify: (value) => "ignored" }; JSON.stringify(x)` got a false ZTS202, "expected 0, got 1". The member call reads its arity from the field type, and an empty list looks the same as a declared `() => number`. Opus chose the parameter list. Items 1 and 2 above change as follows, and items 3 and 4 stay:

- The inferred type of a function value has one parameter for each parameter node, up to the `FunctionSig` limit of 16.
- A parameter takes its type from the signature only when the signature has one entry for each parameter node. A signature built from annotations skips an unannotated parameter, so in any other case every parameter is `unknown`.
- A generic signature gives every parameter `unknown` and no return type, so no type parameter reaches an assignability check unresolved.
- `functionExprType` and generic inference keep the empty list.

The parameter list also closes a case that the empty list left open: a function stored in an unannotated record and later assigned to a typed position. The parameter list makes the parameter and arity checks apply at a function target. `(x: number, y: number) => number` is then refused at `(x: number) => number`, and that is the TypeScript verdict too.

### U2 design (F2)

1. Keep `predicateBodyProves` as the form check. After it passes, compute the type that the test proves for the parameter, and admit the predicate only when that type is assignable to `predicate.narrowed`. Otherwise report ZTS211 with the message `type predicate '<name>' claims '<claimed>', but its test proves '<proven>'`.
2. Compute the proven type in a narrow scope (`beginNarrowScope` and `endNarrowScope`), starting from the parameter's declared type. The rules, for the sense `true` of the returned test:
   - `a && b`: install the narrowing of `a` for `true` (as `installBranchNarrowing` does), then take the proven type of `b`.
   - `a || b`: the union of the proven type of `a`, and the proven type of `b` after `a` is installed for `false`.
   - `!a`: the proven type of `a` for the sense `false`.
   - A leaf: the narrowing that `installBranchNarrowing` installs for the parameter. When it installs none, the parameter's current type.
   - A leaf `p === <literal>`, `p === undefined`, or `p === null` (either operand order) proves the type of that literal for `true`. The `!==` form proves it for `false`. The guard extractor does not narrow a bare identifier against a string or number literal today, so this rule keeps the literal predicates valid.
3. Reuse the guard extractors. Do not add a second list of tests.

Expected results, as literal test cases:

| Predicate | Expected |
|---|---|
| `isStr(x: unknown): x is string { return typeof x === "number"; }` | ZTS211 |
| `isStr(x: unknown): x is string { return typeof x === "string"; }` | admitted, narrows |
| `isString(v: string \| number): v is string { return typeof v === "string"; }` | admitted, narrows (existing test) |
| `isText(v: string \| number \| undefined): v is string { return v !== undefined && typeof v === "string"; }` | admitted (existing test) |
| `isA(v: A \| B): v is A { return v.kind === "b"; }` | ZTS211 |
| `isA(v: A \| B): v is A { return v.kind === "a"; }` | admitted, narrows |
| `isNum(v: string \| number): v is number { return !(typeof v === "string"); }` | admitted |
| `isSN(x: unknown): x is string \| number { return typeof x === "string" \|\| typeof x === "number"; }` | admitted |
| `isA(x: string): x is "a" { return x === "a"; }` | admitted |
| `isArr(x: unknown): x is string[] { return Array.isArray(x); }` | ZTS211 |

### U3 design (F3 and F4)

1. `admitTypePredicates` descends into function bodies, arrow functions, and function expressions. A function there whose signature has a `type_predicate` gets ZTS211 with the message `type predicate '<name>' must be a named module-level function declaration`. Use `<anonymous>` when the function has no name. It installs no narrowing, as today.
2. `type_env.zig` records a predicate whose target names no parameter. Add a field to `FunctionSig`, for example `type_predicate_unbound: bool`, set where `directPredicateParameterIndex` returns null. `admitOneTypePredicate` reports ZTS211 with the message `type predicate '<name>' names '<target>', which is not a parameter`, or without the target name when the field cannot carry it.
3. A predicate that F3 refuses does not also get the F4 message. Report one ZTS211 for each predicate.

## Units

Every unit runs with a private `ZIG_LOCAL_CACHE_DIR` and with `DEEPSEEK_API_KEY` unset. Every bug fix starts with a test that fails for the reason of the bug. Tests assert the exact code and count, with literal values. The executor does not commit. Opus reviews the diff, runs the gates, and commits.

| Unit | Model | Files | Acceptance | Turn budget |
|---|---|---|---|---|
| U1: function values get a type (F1) | Sonnet | `packages/zts/src/type_checker.zig`, and test fixtures if a gate needs one | One test for each row of the F1 table fails before the fix and passes after it. `zig build test-zts`, `test-diagnostic-corpus`, `test-examples`, `test-cli`, `test-contract-golden`, `test-expert-golden`, and `test-expert-app` exit 0 | 60 |
| U2: a predicate must prove its claim (F2) | Sonnet | `packages/zts/src/type_checker.zig` | Each row of the U2 table is a test; the ZTS211 rows fail before the fix. The same gates as U1 exit 0 | 50 |
| U3: predicates in other positions (F3, F4) | Sonnet | `packages/zts/src/type_checker.zig`, `packages/zts/src/type_env.zig` | One test for each F3 form and one for F4 fail before the fix. The same gates as U1 exit 0 | 40 |
| U4: record and docs | Opus | `docs/roadmap.md`, `CHANGELOG.md`, `docs/plans/README.md`, this plan, and `../ZTTP-WEBSITE` if a claim changes | `zig build test` and `bash scripts/verify.sh` exit 0 from an empty cache; `check-spine` and `test-doc-links` exit 0 | Opus |

The units run in order, because all three edit `type_checker.zig`.

## Stop conditions

- The offline replay in `test-expert-app` diverges. The change is then model-visible under D-012. Stop before the commit and report the case and the diagnostic.
- A gate refuses a program that is valid TypeScript in the profile and that no row above names. Stop and hand back the program and the diagnostic.
- `packages/proof-checker` would need a change.

## Out of scope

- A parameter list in the inferred type of a function value (see the U1 stop condition).
- Narrowing of a bare identifier against a literal in an `if`. Spec section 5.4 lists it, and the guard extractor does not implement it. This plan uses it only inside a predicate body.
- The three items left open by the 2026-11-01 window: the `--json` stderr line, the import chain depth, and the fault scan limit.

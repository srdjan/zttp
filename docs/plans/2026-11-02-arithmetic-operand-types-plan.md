# Arithmetic operand types, 2026-11-02

Status: complete 2026-11-02 on local `main`, units U1 and U2; see "Execution record" at the end. Approved 2026-11-02: the owner chose option (a) of Decision 1, which fixes arithmetic on a value that may be `undefined`. The approval covers this plan, the fix, and local commits. It does not cover a push, a provider call, or a re-record.

The probes found eight false proofs, not one. In each one, `zts check` proves `optionals_safe`, and `zttp dev` then answers 500 with "Possible soundness incident". Six have one cause: the arithmetic operand check reads a type lattice that cannot name the operand's type, and it passes what it cannot name. The other two (A4, A8) have no operand check, because the unary minus is not checked.

## Findings

Each probe ran on the `zts` and `zttp` binaries built at 2026-11-02 09:20. The last code commit before that build is `62aafb76` (09:06). The commits after it change only documentation. Each handler declares `Proof<Response, "deterministic" | "read_only">`.

| Probe | Shape | `zts check` | `zttp dev` |
|---|---|---|---|
| A1 | `function inc(x: number \| undefined): number { return x + 1; }`, called with `undefined` | 0 errors, `optionals_safe` PROVEN | 500, soundness incident |
| A2 | `const x = pick(false); x * 2`, where `pick` returns `number \| undefined` | same | 500 |
| A3 | `b.n - 1`, where `structural Box = { n?: number }` and `b = {}` | same | 500 |
| A4 | `return -x;` with `x: number \| undefined` | same | 500 |
| A5 | `xs[5] + 1` with `xs: number[] = [1, 2]` | same | 500 |
| A6 | `function twice(v: unknown): number { return v * 2; }`, called with `"a"` | same | 500 |
| A7 | `x + 1` with `x: number \| null`, called with `null` | same | 500 |
| A8 | `return -b;` with `b: boolean`, called with `true` | same | 500 |

These shapes are correct today, and the fix must keep them accepted:

| Probe | Shape | `zttp dev` |
|---|---|---|
| N1 | `x < 1` with `x` undefined | 200 `{"ok":false}`, no fault |
| N2 | `x \| 0` and `~x` with `x` undefined | 200 `{"total":0}` and `{"total":-1}`, no fault |
| N3 | `if (x !== undefined) { return x + 1; }` | 200, correct |
| N4 | `x !== undefined ? x + 1 : 0`, `x !== undefined && x * 2 > 1`, and `xs.map((v: number): number => v * 2)` | 200, correct |

N1 and N2 follow JavaScript conversion and do not fault, so this plan does not change comparisons or bitwise operators.

### Cause

`requireNumeric` and `requireAddable` in `packages/zts/src/bool_checker.zig#BoolChecker` check the operands of `-`, `*`, `/`, `%`, `**`, and `+`. They read the operand type from the checker's own lattice, `ExprType`. The lattice has no member for an optional number or for `null`. An optional number, a `null`-admitting type, and the declared type `unknown` all map to the lattice member `.unknown`. `makeNullable(.number)` answers `.unknown`, and both checks pass `.unknown`. The runtime does fault, but the verifier has already proven `optionals_safe`. The unary minus has no operand check.

One test pins the fail-open. "arithmetic on a parameter declared number is accepted" in `packages/zts/src/pipeline_tests.zig` asserts that `n: number | undefined` and `v: unknown` get no `arithmetic_on_non_numeric` diagnostic.

The type checker knows each of these types. `const v: number = b.n;` and `const w: number = xs[5];` each get ZTS200, "type 'number | undefined' is not assignable to type 'number'". The boolean check already reads that type. `requireBoolean` asks `contextTypeOf(node)` first. `recordContextType` in `packages/zts/src/type_checker.zig#TypeChecker` fills that table while the walk's narrowing is live. The fallback is `inferTypeWithoutDiagnostics`. The 2026-10-08 boolean plan measured that recording removes the false refusals of guarded code.

`pipeline.zig` sets `authoritative_type_checker` whenever a type environment exists. Without one, the lattice alone decides, as today.

### What the corpus contains

No tracked file under `packages/pi/src/simulator/testdata` names ZTS104 or ZTS106. A line search for an index read followed by an arithmetic operator found no match in that corpus, and one in `tests/corpus/check/bad/dict_entry_round_trip.ts` (`p[1] * 2`, where `p` has no type). The search does not see an operand bound to a `const` first. The offline replay inside `zig build test-expert-app` measures the corpus.

## Target

- T1: each operand of `-`, `*`, `/`, `%`, `**`, and of unary `-` that has a type has a type assignable to `number`. Otherwise it gets ZTS104.
- T2: each operand of `+` that has a type has a type assignable to `number`. Otherwise it gets ZTS106. An operand of a `+` node that already has ZTS105 is left to ZTS105.
- T3: the type is the one the type checker saw with its narrowing live. A guard, an early return, a ternary branch, `&&`, `typeof`, a `??` default, or a `match` binding that proves `number` keeps the program accepted.
- T4: an operand with no type (`null_type_idx`) passes, as it does today. This is a disclosed limit (B1 below), not a proof.
- T5: each diagnostic that the lattice decides today keeps its code, location, message, and help, byte for byte. The new check runs only where the lattice answers `.unknown`.

No new diagnostic code. No change to the rule registry, the spec text, comparisons, bitwise operators, or `packages/proof-checker`.

## Design

1. The type checker records each arithmetic operand. In the `.binary_op` arm of `walkExpr` in `packages/zts/src/type_checker.zig#TypeChecker`, after both operands are walked, call `recordContextType` on each operand when the operator is `.add`, `.sub`, `.mul`, `.div`, `.mod`, or `.pow`. In the `.unary_op` arm, record the operand of `.neg`, as the arm already does for `.not`.
2. In `requireNumeric` and `requireAddable` in `packages/zts/src/bool_checker.zig#BoolChecker`, keep every lattice arm unchanged. Change only the `.unknown` arm. When `authoritative_type_checker` is set, read `contextTypeOf(node) orelse inferTypeWithoutDiagnostics(node)`, as `requireBoolean` does. `null_type_idx` passes (T4). A type assignable to `number` passes. Any other type gets the diagnostic in items 3 and 4.
3. ZTS104 message: `'<type>' operand in '<op>' operator; arithmetic requires numbers`, where `<type>` is `formatType` of the operand type. ZTS106 message: `'<type>' operand in '+' operator; addition requires numbers`. The message buffer may grow so that a long type does not drop to the generic fallback text.
4. Help text, by the absent values that the operand type admits:
   - both `null` and `undefined`: `compare with undefined and with null in nested ifs, and compute inside the inner branch`
   - `null` only: `compare with null in an if, and compute inside the branch`
   - `undefined` only: `compare with undefined in an if and compute inside the branch, or supply a default with ??`
   - neither, for example `unknown` or a type parameter: `narrow the value to number first, for example with typeof in an if`
   The `??` advice is not given for a type that admits `null`, because ZTS624 refuses `??` there. One `if` that tests both absent values with `&&` does not narrow today, so the help names nested ifs.
5. In `requireAddable`, skip an operand only when the type checker already reported ZTS105 on that `+` node. Do not use a broader "may be a string" test: `typeMayBeString` answers false for a nullable string, and `(b.s + 1) * 2` with `s?: string` must get ZTS106 (R11).
6. In the `.unary_op` arm of the boolean checker's `walkExpr`, call `requireNumeric(un.operand, "-")` for `.neg`. The lattice then refuses `-b` with `b: boolean` (A8), as it refuses `true * 5` today.
7. Small `pub` helpers on `TypeChecker` are allowed when the boolean checker needs one: for example, which absent values a type admits, or whether a node has ZTS105. `typeMayBeString`, `admitsUndefined`, `removeAbsence`, and `isRefused` exist and are private. `formatType` on the type pool and `env.isAssignableTo` are public.

## Tests

Each test goes through `pipeline.resolve`, as the tests in `packages/zts/src/pipeline_tests.zig` do. Each asserts the exact diagnostic kind and count, with literal values. One row also asserts the full message and help.

Refusals, each failing before the fix:

| Row | Source shape | Expected |
|---|---|---|
| R1 | A1 | one ZTS106 |
| R2 | A2 | one ZTS104 |
| R3 | A3 | one ZTS104 |
| R4 | A4 | one ZTS104 |
| R5 | A5 | one ZTS106 |
| R6 | A6 | one ZTS104 |
| R7 | A7 | one ZTS106 |
| R8 | `(x + 1) * 2` with `x: number \| undefined` | one ZTS106, no ZTS104 |
| R9 | `<T>(v: T): number => v - 1` | one ZTS104 |
| R10 | A8 | one ZTS104 |
| R11 | `(b.s + 1) * 2` with `structural Box = { s?: string }` | one ZTS106, no ZTS104 |

The optional-number and `unknown` rows of "arithmetic on a parameter declared number is accepted" move to the refusal side.

Accepts, which pass before and after the fix: N3, each N4 form, an early return `if (x === undefined) { return 0; } return x + 1;`, `(x ?? 0) + 1`, `if (typeof v === "number") { return v * 2; }` with `v: unknown`, a `for...of` element over `number[]`, a `match` record-pattern binding of type `number`, and `xs.length - 1` (an untyped operand, T4).

One new corpus case, `tests/corpus/check/bad/arith_on_optional_number.ts` with its `.diag` golden, shows the code and location through `zts check` for A1. The gate discovers a case from the `.ts` and `.diag` pair, with no manifest.

### Known refusals

The type checker types these two forms without the narrowing that guards them. It refuses each today with ZTS200 when the value goes to a `number` position. After the fix, it also refuses them with ZTS104 or ZTS106 at an arithmetic operator:

- a ternary that selects a guarded value, for example `(x !== undefined ? x : 0) * 2`. The idiomatic `(x ?? 0) * 2` is accepted.
- a guarded value captured in a closure, for example `xs.map((v: number): number => v * x)` after `if (x === undefined) { return xs; }`. The captured binding is read by a different binding key, so the guard does not reach it.

The tests do not pin these refusals. The roadmap lists them. If the offline replay shows that a recorded draft hits one, the D-012 stop condition applies.

## Units

Every unit runs with a private `ZIG_LOCAL_CACHE_DIR` and with `DEEPSEEK_API_KEY` unset. The executor does not commit. Opus reviews the diff, runs the gates, and commits.

| Unit | Model | Files | Acceptance | Turn budget |
|---|---|---|---|---|
| U1: arithmetic operands take the type checker's type | Sonnet | `packages/zts/src/type_checker.zig`, `packages/zts/src/bool_checker.zig`, `packages/zts/src/pipeline_tests.zig`, the new corpus case, and any fixture a gate needs | R1 to R11 fail before the fix and pass after it. The accept rows pass before and after. `zig build test-zts`, `test-diagnostic-corpus`, `test-examples`, `test-cli`, `test-contract-golden`, `test-expert-golden`, `test-expert-app`, `test-proof-swallow`, and `test-zruntime` exit 0 | 60 |
| U2: record and docs | Opus | `docs/typescript.md`, `docs/roadmap.md`, `CHANGELOG.md`, `docs/plans/README.md`, this plan, and `../ZTTP-WEBSITE` if a claim changes | `zig build test` and `bash scripts/verify.sh` exit 0 from an empty cache; `test-zruntime`, `check-spine`, and `test-doc-links` exit 0 | Opus |

`scripts/test-examples.sh` already accepts one refusal of `examples/handler/feature-probes.ts` (ZTS613). U1 runs `zts check` on that file by hand and reports any new diagnostic, because the gate can hide it.

## Stop conditions

- The offline replay in `test-expert-app` diverges. The change is then model-visible under D-012. Stop before the commit and report the case and the diagnostic.
- The new check refuses a program in a committed example, fixture, or corpus draft that does not fault at runtime, other than the two known refusals. Stop and hand back the program and the diagnostic.
- A diagnostic that the lattice decides today changes its text (T5).
- `packages/proof-checker` would need a change.

## Out of scope

- Comparisons and bitwise operators on a value that may be absent (N1, N2). They do not fault.
- A change to the type checker's inferred type for `+`, for a ternary, or for a captured binding.
- B1, below.
- The other three gaps under Current Limitations in `docs/roadmap.md`.

### B1: untyped numeric forms

Measured 2026-11-02. The type checker gives no type to `xs.length`, `Math.floor(...)`, and `parseInt(...)`. `const a: string = xs.length;` passes `zts check`. A handler that then returns `a.toUpperCase()` proves `optionals_safe`, and `zttp dev` answers 500 "Possible soundness incident". This is the fail-open in `docs/solutions/logic-errors/an-untyped-value-passed-every-typed-position.md`, at forms other than function values. The Fable review also found these forms untyped: `Math.max`, `Math.min`, `Math.abs`, `Math.round`, `Math.PI`, `parseFloat`, `Number(...)`, `str.length`, `str.indexOf`, `str.charCodeAt`, `xs.indexOf`, the `range` element in `for...of`, the index parameter of `map`, and the parameters of an unannotated `reduce` or `sort` callback. Opus has not measured that longer list. To type these forms is a separate plan. When it lands, T4 can become a refusal.

## Validation record

Revision 1, 2026-11-02. A Fable review attacked the design, and a Codex (gpt-6-astra, read-only) review checked the facts. Opus checked each load-bearing claim with a probe before acting on it.

- Fable: refusing an untyped operand (the first T4) would refuse common valid code, because many numeric forms have no type. Opus confirmed `.length`, `Math.floor`, and `parseInt`, and found that an untyped `.length` is itself a runtime false proof (B1). T4 now passes an untyped operand, and B1 is out of scope.
- Fable: the rule that skipped an arithmetic operand was sound only while every inner `+` reports its own fault. Opus confirmed that `(b.s + 1) * 2` gets no diagnostic today. With T4 passing an untyped operand, the skip is not needed and is removed. The `+` skip now depends on ZTS105 itself (item 5), and R11 covers the case.
- Fable: a guarded ternary and a guarded captured value lose their narrowing. Opus confirmed both with ZTS200 probes. They are listed as known refusals.
- Fable: the help text named `??` for a type that admits `null`, and one `&&` test of both absent values does not narrow. Item 4 now gives four help texts.
- Codex: four claims were wrong and are corrected. The lattice does have a `.unknown` member. The pinned test asserts the absence of one diagnostic kind, not of every diagnostic. The commits after the build also change `CHANGELOG.md` and `CONCEPTS.md`. Two probes, A4 and A8, come from the missing unary check, not one.
- Codex: `p` in `tests/corpus/check/bad/dict_entry_round_trip.ts` has no type, because `dictEntries` returns a coarse `object`. With T4 as revised, that case keeps its golden.

## Execution record

| Unit | Commit | Result |
|---|---|---|
| Plan | `f440bcde` | Revision 1, after the Fable and Codex reviews |
| U1 | `c92f8f67` | A1 to A8 closed. 16 new tests; all 16 failed on the previous HEAD because no diagnostic was reported |
| U2 | this commit | `docs/typescript.md`, `docs/roadmap.md`, `CHANGELOG.md`, the plan index, and this record |

### Deviations from the plan

- U1 made `isRefused` `pub` instead of adding a wrapper, and added `absentValuesOf` for the help text. Item 7 allows both.
- U1 edited three files outside its list. The precompile case `r21_arith` (`1 + xs[5]`) was pinned as accepted. It is probe A5, a false proof, so it moved to the refused table with ZTS106. The new corpus case raised the corpus floor in `packages/tools/src/diagnostic_corpus_gate.zig` from 182 to 183, and three R7c census counts in `packages/pi/src/tools/common.zig` by one each.
- Opus removed the plan labels ("R1" to "R11") from the test names. The names now state the behavior only.
- `zts check examples/handler/feature-probes.ts` reports 14 ZTS600, 12 ZTS601, and 2 ZTS613, the same counts as on the previous HEAD, and no ZTS104 or ZTS106.

### Probes after the fix

On the binaries built from `c92f8f67`, A1 to A8 each get one diagnostic: ZTS106 for A1, A5, and A7, and ZTS104 for the other five. Each message names the operand type, for example `'number | undefined' operand in '+' operator; addition requires numbers`. N1, N2, N3, N4, and the guarded forms get no diagnostic.

### Final gate

At `c92f8f67`, each from a new empty `ZIG_LOCAL_CACHE_DIR` and with no provider key: `zig build test` exited 0, `bash scripts/verify.sh` exited 0 with "all per-commit gates passed", and `zig build test-zruntime` exited 0. The offline replay reported 13/13 cases. The host load average was 6.6 to 13 at the end of the run. `bench-check` did not run, because no unit changed runtime code. Nothing was pushed.

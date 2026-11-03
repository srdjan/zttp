# Untyped operands, untyped receivers, Dict keys, and container writes, 2026-11-03

Status: revision 1, 2026-11-03, validated, in execution. On 2026-11-03 the owner chose option (a) of D1, D2, and D3 at the end of the [member access plan](2026-11-03-member-access-and-dict-types-plan.md). Approved 2026-11-03: the owner chose option (a) of Decisions 1, 2, and 3, and approved execution of the units F1, A1, T1, R4, U3, N1, J1, W1, and D on local `main`. No approval covers a push, a provider call, or a re-record.

D1 (a): give the `for...of` loop variable over an array literal a type, apply the other U3 prototype fixes, and run the U3 entry check again with `zig build test`. D2 (a): refuse a member call on a receiver with no type in strict code, with its own entry check. D3 (a): confirm the encoder path, then refuse a Dict key that is not a string with ZTS213.

## Findings

A "false proof" passes `zts check` with every property PROVEN, and then `zttp dev` answers 500 with "Possible soundness incident". Q12c ran on a build of `8cefd021`, Q12d on `2d4e9bcf`, and the others on `02bda09d`. No commit after `2d4e9bcf` changes the checker. Q18 to Q22 come from the validation, and Opus ran each one again on `02bda09d`.

| ID | Program | `zts check` | `zttp dev` |
|---|---|---|---|
| Q12a | `Object.values(o)[0].f(1)` with `o: P` | 0 errors | 500 |
| Q12b | `x.slice(1).trim()` with `x: string \| string[]` | 0 errors | 500 |
| Q12c | `[1, 2].reduce((acc, v) => acc.toFixed(2), "")` | 0 errors | 500 |
| Q12d | `for (const s of [1, 2]) { out = s.toUpperCase(); }` | 0 errors | 500 |
| Q13 | The published `let` example, `for (const n of [1, 2, 3]) { total = total + n; }`, under the U3 prototype | ZTS106 on `n` | not run (false refusal) |
| Q10 | `Response.json(dictSet(dictSet(dictEmpty(), 2, "x"), "k", 1))` | 0 errors | 500, `error.OutOfMemory` from the native `json` function |
| Q14 | `const ys = ["a", "b"]; ys[0] = 5;` then `ys[0].toUpperCase()` | 0 errors | 500 |
| Q15 | `const xs: string[] = ["a"]; const ys: (string \| number)[] = xs; ys.push(5);` then `x.toUpperCase()` for each `x` of `xs` | 0 errors | 500 |
| Q16 | `const xs: number[] = [1]; xs.push("a");` and `xs[0] = "a";` | 0 errors | not run |
| Q17 | `const p: P = { name: "a" }; p.name = 5;` then `p.name.toUpperCase()` with `P = { name: string }` | 0 errors | 500 |
| Q18 | `const r = ok(req.headers.get("x-missing")); if (r.ok) { n = r.value.length + 1; }` | 0 errors | 500 |
| Q19 | `p["name"] = 5;` then `p.name.toUpperCase()` with `p: P` | 0 errors | 500 |
| Q20 | `q.a.name = 7;` then `q.a.name.toUpperCase()` with `q: { a: P }` | 0 errors | 500 |
| Q21 | `const t = ["a", "b"]; t.length = 0;` then `t[0].toUpperCase()` | 0 errors | 500 |
| Q22 | `let d = dictEmpty(); d = dictSet(d, 2, "x"); return Response.json(d);` | 0 errors | 500 |

The validation also found four correct forms that U3 or N1, as written in revision 0, would refuse:

- FR1: `const out = []; ... out.push(item);`. The stand-in seed `clean_collect` and the good draft of the `loop-mutation` seed in `packages/pi/src/standin/defect_seeds.zig` use it. `examples/handler/feature-probes.ts` uses `const fns = [];` with `fns.push`. The binding has no type, so N1 refuses the `push`.
- FR2: `Object.values(o).length - 1`, `Object.values(o).map(...)`, and `u.length` with `u: string | string[]`. Each result has no type, and each is correct on every input.
- FR3: `for (const row of [[1, 2], [3]]) { for (const m of row) { total = total + m; } }`. The literal is `[[1, 2], 3[]]`, so `row` is a union of a tuple and an array. Revision 0 left a union iterable untyped, so U3 refuses `total + m`.
- FR4: `const handler = (req) => Response.text(req.url.trim());` passes strict mode today. ZTS601 does not apply to an anonymous arrow with no annotation at all. U3 and N1 refuse its arithmetic and member calls.

### Cause

- Q12: `reportUnionMemberCall` in `packages/zts/src/type_checker.zig#TypeChecker` returns when the receiver has no type (`null_type_idx`). P9 refuses a member call on `unknown` and on some unions. `reportNonRecordMemberRead` refuses a member that a primitive or an array lacks. Neither reads a receiver with no type.
- The receivers of Q12a to Q12d have no type. They are an `Object.values` element, the result of a call on a union, a `reduce` accumulator, and a loop variable. `Object.values` and `Object.entries` have no result row (`values_unbounded` in `builtin_results.zig`). In Q12c the callback returns `acc.toFixed(2)` on a string, which has no type, so the accumulator stays untyped. A known return that does not fit the seed is ZTS200.
- Q13 and Q12d: `bindForOfElement` binds the loop variable to `number` over `range(...)`, and to the element type over an array type. It does not bind a tuple. An array literal whose element types are all equal infers to an array: `[4, 4]` is `4[]`. Other literals infer to a tuple of literal types: `[1, 2, 3]` is `[1, 2, 3]`. A literal longer than 32 elements is an array of the union. `[]` has no type.
- Q10 and Q22: `writeJsonDepth` in `packages/zts/src/http.zig` fails the whole encode on a Dict key that is not a string, and it returns `RenderError.OutOfMemory`. The encoder of `stringifyJson` in `packages/zts/src/modules/data/json_mod.zig` returns `error.Unencodable`, and the export turns it into an error Result. `firstUnencodable` checks the value type of a Dict and not its key type. In Q22, `let d = dictEmpty()` widens to `Dict<unknown, unknown>`, so no key type is known.
- Q14, Q16, Q17, Q19, Q20, and Q21: the `.assignment` arm of the type checker walk checks a plain write to an identifier against its declared or inferred type. A compound write skips that check. A member write records a receiver that may be absent, and it checks `readonly` only when its object is an identifier. A computed write, such as `xs[0]` or `p["name"]`, has no check. A write to `length` has no check, and a tuple index read keeps its element type after it. The `push`, `unshift`, and `splice` rows in `packages/zts/src/builtin_results.zig#rows` take `.rest = .any`. `pop` and `shift` also change the length of a tuple.
- Q15: an array type is assignable to an array type with a wider element type. A write through the wider alias changes the value that the narrower type describes. A record type has the same property.
- Q18: `isTrackedResultFieldRead` in `packages/zts/src/handler_verifier.zig#HandlerVerifier` gives every `value` read on a tracked Result to ZTS303. ZTS303 proves only that `ok` was checked. So a `value` whose type admits `undefined` is never reported as ZTS309.
- A value with no type passes at most typed positions: an operand, a receiver, an argument, an assignment, and a return. A boolean context refuses it in `packages/zts/src/bool_checker.zig#BoolChecker`. `typeof` does not narrow a binding with no type, because the narrowing reads the current type of the binding first.

### The prototype of the member access plan

The third U3 entry check ran a prototype with a corrected skip. Over the 264 tracked `.ts` files it changed three programs, and each was already refused. `zig build test` then failed for these reasons:

- The published `let` example (Q13).
- `(x + 1) * 2` with `x: number | undefined` got a second diagnostic on the operand of `*`, which is the refused `+`.
- The stand-in seed `missing-annotations` named ZTS106 before its declared ZTS601. The seed has an unannotated parameter in an arithmetic operand.
- The R7c census moved from 126 to 129, and three corpus golden lines were added. D-012 permits both when the replay holds.
- The `isDict` fold case of K1b gained a second ZTS106, on `acc`.

## Target

- Q13 and FR1 to FR3 are accepted, and the U3 entry check runs again.
- Q12a to Q12d are refused in strict code.
- Q10 is refused with ZTS213.
- Under Decision 1 (a), Q14, Q16, Q17, and Q19 to Q21 are refused.
- Under Decision 3 (a), Q18 is refused with ZTS309.

## Design

1. **F1: the loop variable over a tuple.**
   - `bindForOfElement` binds the variable over a tuple to the union of the widened element types. `[1, 2, 3]` binds `number`, and `["a", 1]` binds `string | number`.
   - Over a union of arrays and tuples, the variable is the union of the element types of each member. `row` in FR3 is `[1, 2] | 3[]`, because `widenLiteral` is shallow. So `m` is a number type, and `total + m` is clean.
   - An empty tuple binds nothing. The `range(...)` rule stays.
   - F1 adds no false proof against today, because today the variable has no type and passes. After N1 there is one condition. A tuple passed to a wider array parameter can receive a value of another type (Q15). Then a typed loop variable passes where N1 would refuse an untyped one. Decision 2 names this path.
2. **A1: array literal bindings.** A `const` or `let` binding of an array literal without an annotation widens each element type.
   - When the widened element types are all equal, the binding is an array: `const ys = [4, 5]` is `number[]`, as in TypeScript. Otherwise it is a tuple: `["a", 1]` is `[string, number]`.
   - An empty literal bound without an annotation is `unknown[]`. FR1 then passes: `out.push(item)` accepts any value, and a read yields `unknown | undefined`.
   - A literal index read on such a binding then yields the element type or `undefined`, as for every array. `ys[0] + 1` becomes a refusal (ZTS104). A text search found 12 literal index reads and 2 mutating calls on such bindings in 8 tracked `.ts` files and Zig-embedded sources. The entry check decides.
   - A1 also removes a false refusal: `let zs = [4, 5]; zs = [6, 7];` is ZTS200 today, because `widenLiteral` is shallow.
   - A literal that is not bound, such as the iterable of a `for...of`, keeps its inferred type.
3. **T1: builtin results that have no type.**
   - `Object.values(o)` is `unknown[]`, and `Object.entries(o)` is `[string, unknown][]`. The `values_unbounded` reason in `builtin_results.zig` refuses the union of the field types, because a record can hold a field that its type does not name. `unknown` holds any field.
   - A builtin member read or call on a union of strings, arrays, and tuples is the union of the result of each member, when each member has a row. `u.length` with `u: string | string[]` is `number`, and `u.slice(1)` is `string | string[]`.
   - Then Q12a is refused by P9 or by ZTS309, and Q12b is refused by `reportNonRecordMemberRead`. FR2 passes.
4. **R4: a Result `value` that admits `undefined` (Decision 3).** `isTrackedResultFieldRead` gives a `value` read to ZTS303 only when the value type of the Result excludes `undefined`. A new `pub fn resultValueMayBeAbsent` on `TypeChecker`, beside `resultMayFillErrors`, answers this. Then Q18 gets ZTS309 on `r.value.length`. A `value` read that ZTS303 already refused keeps ZTS303, as for `error` in R3.
5. **The shared skip.** A new `pub fn` on `TypeChecker` answers whether the verifier will report a read as ZTS309.
   - The read must be a key of `absent_receivers`. Its object must not be a Result field that `isTrackedResultFieldRead` gives to ZTS303.
   - That is a member read of `unwrap` or `errors`, of `error` on a Result whose `errors` is `never`, or of `value` on a Result whose value excludes `undefined` (after R4).
   - The function does not test for a tracked Result binding. So its skip set is a subset of what the verifier reports, and nothing is skipped without a diagnostic. A read that the verifier gives to ZTS309 on an untracked Result gets the U3 or N1 diagnostic instead.
   - U3 and N1 call this one function. Each unit's test table holds an R3 case, an R4 case, and the A3 fixture.
6. **The ZTS601 skip.** U3 and N1 skip an identifier bound to a parameter of a function that ZTS601 refuses. ZTS601 refuses a named function whose annotation is not complete, and an anonymous function that annotates only some of its parameters. The rule is `functionNeedsAnnotation` in `packages/zts/src/strict_checker.zig`. U3 moves that rule to one `pub fn` that the strict checker and the skip both call. FR4 has no annotation at all, so ZTS601 does not apply, and U3 and N1 refuse it. The entry check counts FR4 forms.
7. **U3: an arithmetic operand with no type.**
   - On strict paths (`ResolveOptions.strict`), `requireNumeric` and `requireAddable` in `bool_checker.zig` refuse an operand with no type. The kind is ZTS104, or ZTS106 for `+`.
   - The message is "operand has no known type in '<op>'; arithmetic requires numbers". For `+` it ends "addition requires numbers". The help is "give the value a type: annotate it or its source". `typeof` does not narrow a binding with no type, so the help does not name it.
   - U3 skips an operand under the shared skip or the ZTS601 skip. It also skips an operand that is a binary arithmetic expression, a `+`, or a unary minus, because its own operands carry the diagnostic. Each skip looks through parentheses.
   - The early return on `isRefused(add_node)` stays.
8. **N1: a member call on a receiver with no type.**
   - On strict paths (`strict_checker_follows`), `reportUnionMemberCall` refuses a call whose receiver has no type. The kind is ZTS201, and the message is "a member call on a value with no known type; give it a type or narrow it first".
   - N1 skips a receiver that `builtinGlobalName` names, such as `Math`, `JSON`, `Object`, and `Response`, because a builtin namespace has no type by design. It skips the headers of a request (`isRequestHeaders`). It also skips under the shared skip or the ZTS601 skip.
   - A call on a field of an `unknown` value, such as `JSON.parse(s).name.trim()`, is refused, because the field can hold any JSON value.
9. **J1: a Dict key in a JSON payload.**
   - `firstUnencodable` reports a Dict whose key type has a member that is not a string. That is `number`, `boolean`, a literal that is not a string, a record, an array, a tuple, a function, or `Bytes`.
   - A key type of `string`, a string literal, `never`, or `unknown` stays accepted. That is the direction of the rest of the function: it refuses what it knows is wrong.
   - ZTS213 names the Dict type. `JSON.stringify` of such a Dict then has no type through the existing check in `inferType`.
   - Q22 stays open: the `let d = dictEmpty()` idiom from K1a is `Dict<unknown, unknown>`, and a number key reaches the encoder. The roadmap records it.
10. **W1: writes into containers (Decision 1).**
    - A write target is a member `o.f`, a computed member with a string literal key `o["f"]`, or an index `xs[i]`. Its object can be any expression, such as `q.a`.
    - A member write requires the value to be assignable to the declared type of the field in each record member of the receiver type.
    - An index write on an array requires the value to be assignable to the element type. On a tuple, it requires the widened element type at a literal index, and the union of the widened element types at any other index.
    - On a union receiver, the value must fit each member.
    - Each argument of `push` and `unshift` must be assignable to the element type. Each argument of `splice` after the second must be assignable to it.
    - `push`, `pop`, `shift`, `unshift`, and `splice` on a tuple are refused, because a tuple type names its length. A write to `length` on a tuple is refused. The help suggests an array annotation. No in-place `reverse`, `sort`, or `fill` exists: `fill` is ZTS201, and `toReversed` and `toSorted` copy.
    - A value with no type passes, as at an identifier write today. The roadmap records it.
    - The kind is ZTS200 for a write, and ZTS203 for an argument.

## Decision 1: writes into containers (W1)

- (a) Add W1 to this plan, conditional on its entry check. **Recommended**: Q14, Q16, Q17, and Q19 to Q21 share one cause, and F1 types the loop variable from a tuple that a write can change.
- (b) Record these false proofs in the roadmap, and plan W1 later.

## Decision 2: a wider alias of an array or a record (Q15)

- (a) Record Q15 in the roadmap, and decide it in a later plan after W1. **Recommended**: invariance changes assignability for every array and record type, and it needs its own measurement. The roadmap entry names the F1 path: a tuple passed to a wider array parameter, then a typed loop variable over it.
- (b) Add W2 to this plan, conditional on its entry check: a mutable array or record type is assignable only to a type with the same element or field types.

## Decision 3: a Result `value` that admits `undefined` (Q18, R4)

- (a) Add R4 to this plan before U3. **Recommended**: Q18 is a measured false proof in the verifier rule that R3 changed. Without R4, U3 refuses Q18 with "no known type", which hides the cause.
- (b) Record Q18 in the roadmap. U3 then refuses Q18 with its own message, and the shared skip omits the `value` exception.

## Entry checks

Each unit runs an entry check before it writes tests, because each unit changes a type or adds a refusal. The executor builds the parent commit and the prototype to separate prefixes. Then the executor runs `zts check` with both on every tracked `.ts` file.

On the prototype, the executor then runs `zig build test`, `test-zruntime`, `test-examples`, `test-expert-app`, `test-precompile`, `test-diagnostic-corpus`, and `test-standin`. `zig build test` reaches the handler sources in Zig files: the example registry, the stand-in defect seeds, and the pipeline tests.

The hand-back lists each new diagnostic with its file, form, and rule. It also states whether the refused value has one runtime type on every input. For A1 it lists each literal index read that changed its outcome. For U3 and N1 it lists each FR4 form.

## Units

Every unit runs with a private `ZIG_LOCAL_CACHE_DIR` and with `DEEPSEEK_API_KEY` unset. The executor does not commit. Opus reviews the diff, runs the gates, and commits each unit. The units run in this order, one at a time.

| Unit | Model | Scope | Acceptance | Turn budget |
|---|---|---|---|---|
| F1: loop variable over a tuple | Sonnet | `type_checker.zig` and tests | `n` in `for (const n of [1, 2, 3])` is `number`, over `["a", 1]` it is `string \| number`, and `total + m` in FR3 is clean. The F1 tests fail before and pass after | 25 |
| A1: array literal bindings | Sonnet | `type_checker.zig` and tests | Runs only when its entry check passes. `const ys = [4, 5]` is `number[]`, `["a", 1]` is `[string, number]`, and `[]` is `unknown[]`. FR1 passes, and `let zs = [4, 5]; zs = [6, 7];` passes. The A1 tests fail before and pass after | 30 |
| T1: builtin results with no type | Sonnet | `builtin_results.zig`, `type_checker.zig`, and tests | Runs only when its entry check passes. `Object.values(o)` is `unknown[]`, and `u.length` with `u: string \| string[]` is `number`. FR2 passes, and Q12a and Q12b are refused. The T1 tests fail before and pass after | 35 |
| R4: Result `value` that admits `undefined` | Sonnet | `handler_verifier.zig`, `type_checker.zig`, and tests | Decision 3 (a) only, and only when its entry check passes. Q18 gets ZTS309. A `value` read on `ok(1)` stays clean, and the R3 cases keep their diagnostics. The R4 tests fail before and pass after | 30 |
| U3: arithmetic operand with no type | Sonnet | `bool_checker.zig`, `strict_checker.zig`, `pipeline.zig`, the shared skip in `type_checker.zig`, and tests | Runs only when its entry check passes. The published `let` example is clean. The A3 fixture keeps three ZTS309, and the R3 and R4 cases keep ZTS309. `u.n * 2` with `u: unknown` gets ZTS104. The U3 tests fail before and pass after | 40 |
| N1: member call with no receiver type | Sonnet | `type_checker.zig` and tests | Runs only when its entry check passes. Q12c gets ZTS201, and Q12d is refused. `Math.max(1, 2)` and `JSON.stringify(x)` stay clean. The A3, R3, and R4 cases keep ZTS309. The N1 tests fail before and pass after | 40 |
| J1: Dict key in a payload | Sonnet | `type_checker.zig` and tests | Runs only when its entry check passes. Q10 gets ZTS213. A `Dict<string, number>` payload and a `Dict<unknown, unknown>` payload pass. The J1 tests fail before and pass after | 25 |
| W1: writes into containers | Sonnet | `type_checker.zig`, `builtin_results.zig`, and tests | Decision 1 (a) only, and only when its entry check passes. Q14, Q16, Q17, and Q19 to Q21 are refused. `const xs: number[] = []; xs.push(1);`, `p.name = "b";`, and `xs.length = 0` on `number[]` pass. The W1 tests fail before and pass after | 60 |
| D: record and docs | Opus | `docs/typescript.md`, `docs/verification.md`, `docs/roadmap.md`, `CHANGELOG.md`, `docs/plans/README.md`, this plan, the solution note, and `../ZTTP-WEBSITE` if a claim changes | `zig build test`, `bash scripts/verify.sh`, and `zig build test-zruntime` exit 0 from an empty cache | Opus |

Gates for each unit: `zig build test`, `test-zruntime`, `test-examples`, `test-expert-app`, `test-diagnostic-corpus`, `test-bytecode-identity`, `test-residual-guards-drift`, `test-docs-drift`, `test-proof-ratchet-drift`, `test-precompile`, `test-modules`, `test-flow-census`, `test-standin`, `bash scripts/check-proof-swallow.sh`, and `zig fmt --check` on the changed files. Opus runs each step by name and reads each exit status on its own.

## Stop conditions

- The offline replay in `test-expert-app` diverges. The change is then model-visible under D-012. Stop before the commit, and report the case and the diagnostic.
- An entry check refuses a correct program in a committed example, fixture, corpus draft, or Zig-embedded handler source, and the refused value has one runtime type on every input. Stop and hand back the program, the form, and the diagnostic. A refused value from parsed input, from a `Dict<unknown, unknown>`, or of type `unknown` can hold any JSON value: list it and continue. A program that strict mode already refuses: list it and continue.
- A1 changes the outcome of a literal index read in a committed program. Stop. Opus decides between a tuple for that binding shape and an edit of the program.
- A stand-in defect seed names a code other than its declared one. Stop before the commit. Opus decides between a skip and a seed edit. A seed edit moves the offline `content_hash` pin in `packages/pi/src/standin/range.zig`, which the replay does not read.
- A runtime result is not clear from the runtime code. Stop and report the export or member.
- `packages/proof-checker` would need a change.

Under D-012 as clarified on 2026-11-03, a unit may update a corpus bad-case golden or an R7c census count when the replay holds and the new diagnostic is true. The hand-back lists each change.

## Out of scope

- Q15 under Decision 2 (a), with the F1 path that it opens.
- Q22: a `Dict<unknown, V>` payload whose runtime key is not a string, such as `let d = dictEmpty()`.
- The name `RenderError.OutOfMemory` for a non-string Dict key in `http.zig`. An operator sees an out-of-memory error for an encoding refusal. The roadmap records it.
- A value with no type at an assignment, an argument, or a return. U3 and N1 close only the operand and the receiver.
- The other gaps under Current Limitations in `docs/roadmap.md`.

## Validation record

Fable attacked the design with probes on the `02bda09d` binaries. Codex astra checked each repository claim against the source and did not run probes. Opus checked each finding that changed the plan with its own read or probe.

| Finding | Source | Opus check | Result |
|---|---|---|---|
| V1: N1 refuses `out.push(item)` on `const out = []` (FR1) in two stand-in seeds | Fable | Read `clean_collect` and the `loop-mutation` seed. A census probe shows that `out` has no type | A1 types `[]` as `unknown[]` |
| V2: `Object.values(o).length` and `u.length` have no type (FR2) | Fable | Census probe, and the `values_unbounded` reason in `builtin_results.zig` | T1 |
| V3: F1 leaves the inner variable of a nested loop untyped (FR3) | Fable | Census probe: `[[1, 2], [3]]` is `[[1, 2], 3[]]` | F1 covers a union of arrays and tuples |
| V4: "F1 adds no false proof" holds only without Q15 | Fable | Reasoned from Q15 | F1 and Decision 2 state the condition |
| V5: W1 misses `p["name"] = 5`, `q.a.name = 7`, and `t.length = 0` | Fable | Probes: each passes `zts check` and answers 500 (Q19 to Q21) | W1 names the target shapes |
| V6: a Result `value` that admits `undefined` is a false proof | Fable | Probe: Q18 passes and answers 500 | R4 and Decision 3 |
| V7: an unannotated handler arrow passes strict mode (FR4) | Fable | Probe | The entry check counts it |
| V8: J1 leaves `let d = dictEmpty()` open | Fable | Probe: Q22 passes and answers 500 | Out of scope, in the roadmap |
| V9: `let zs = [4, 5]; zs = [6, 7];` is ZTS200 | Fable | Probe | A1 removes it |
| V10: the U3 operand skip must look through parentheses | Fable | Accepted | U3 |
| V11: builtin namespaces have no type, so N1 refuses `Math.max(...)` | Codex | Read `builtinGlobalName` and `inferBuiltinMemberCall` | N1 skips them |
| V12: `pop` and `shift` also change the length of a tuple | Codex | Read `builtin_results.zig` and `builtins/array.zig`. No in-place `reverse`, `sort`, or `fill` exists | W1 refuses all five on a tuple |
| V13: ZTS601 applies to a partly annotated inline arrow | Codex | Read `functionNeedsAnnotation` | The skip calls the same rule |
| V14: `typeof` does not narrow a binding with no type | Codex | Read `currentBindingType` | U3 help text changed |
| V15: a homogeneous literal infers to an array, and `bindForOfElement` handles `range(...)` | Codex | Read the array literal inference | Cause corrected |
| V16: in Q12c the callback return has no type; a known return that does not fit is ZTS200 | Codex | Read `bindSeededAccumulator` | Cause corrected |
| V17: the `stringifyJson` export returns an error Result | Codex | Read `json_mod.zig` | Cause corrected |
| V18: P9 also refuses some union calls, a member write records an absent receiver, and a boolean context refuses no type | Codex | Read the cited functions | Cause corrected |

Opus rejected two findings. Codex said that W1 does not need A1's widening, because the tuple rule already widens. That holds for a tuple. A homogeneous literal is an array of a literal type, such as `4[]`, so `ys[0] = 6` needs the widening. Codex also said that the shared skip claims to predict ZTS309 exactly. Revision 0 already stated that the skip omits the tracked-binding test. Fable confirmed that the skip set is a subset of what the verifier reports.

Codex marked the recorded results of Q12 to Q17 and of the prototype as not checkable from the source. Those results come from Opus probes at the builds that the Findings name. Opus ran the probes of Q18 to Q22 again for this revision.

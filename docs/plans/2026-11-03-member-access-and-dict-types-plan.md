# Member access, string index, and Dict types, 2026-11-03

Status: revision 1, 2026-11-03, validated. Approved 2026-11-03: the owner chose option (a) of Decision 1 and option (a) of Decision 2. The approval covers the units S1, P9, K1a, K1b, R3, the conditional U3, and D, with local commits. On 2026-11-03 the owner chose option (a) of D1, D2, and D3 at the end of the [callback parameters and Result types plan](2026-11-02-callback-and-result-types-plan.md). That approval covers writing and validating this plan. Execution needs a separate approval. No approval covers a push, a provider call, or a re-record.

D1 (a): give the `dictFold` callbacks and `ps[0].age` what U3 needs, then run the U3 entry check again. D2 (a): check a member call on a receiver that is not a record (P9). D3 (a): fix the false `dictFold` refusal in the same plan.

## Findings

Each probe ran on the `zts` and `zttp` binaries built from `48cba1c9`. A "false proof" passes `zts check` with every property PROVEN, and then `zttp dev` answers 500 with "Possible soundness incident". The probe files are under `/tmp/ra/` and `/tmp/fable-review/p/`.

| ID | Program | `zts check` | `zttp dev` |
|---|---|---|---|
| Q1 | `const n = 3;` then `n.toFixed(2) === "3.00"`, capsule `read_only`. `n.toString()` is the same | 0 errors | 500, fault at the call |
| Q2 | `const s: string = "ab"; const c: string = s[0];` then `Response.text(c.toUpperCase())` | 0 errors | 500 |
| Q3 | `const v = dictGet(dictSet(dictEmpty(), "k", 5), "k");` then `Response.text(v.trim())` | 0 errors | 500 |
| Q4 | `const d: Dict<string, number> = dictSet(dictEmpty(), "a", 1);` | ZTS200: `Dict<unknown, unknown>` is not assignable to `Dict<string, number>` | not run (false refusal) |
| Q5 | `dictGet`, `dictHas`, `dictSet`, `dictRemove`, `dictEntries`, `dictMapValues`, `dictFilter`, or `dictFold` with a `Dict<string, number>` argument | ZTS203: expected `Dict<unknown, unknown>`, got `Dict<string, number>` | not run (false refusal) |
| Q6 | The A3 fixture `ps[0].age + ps[1].age` and `ps[2].age` with `ps: P[]`, under the U3 change | two "no known type" errors replace the three ZTS309 errors | not run |
| Q7 | `function pick(x: string \| string[])` with `const c = x[0]; return c.toUpperCase();` | 0 errors | 500 |
| Q8 | `function show(x: P \| string)` with `const a = x.age; return a.toFixed(1);` | 0 errors | 500 (Fable's run) |
| Q9 | `decodeJson("user", "{}")`, then inside `if (!r.ok)` the read `r.error.length + 1` | 0 errors | not run: no schema could be registered |
| Q10 | `Response.json(dictSet(dictSet(dictEmpty(), 2, "x"), "k", 1))` | 0 errors | 500 "Internal Server Error" (Fable's run) |

### Cause

- Q1, Q3, and Q8 (P9): `inferMemberAccessType` in `packages/zts/src/type_checker.zig#TypeChecker` types a builtin constant such as `Math.PI`, a record, a union of records, `length`, and the array methods. For every other receiver, and for a union that holds a record and a primitive, it returns `null_type_idx`. Most checks read `null_type_idx` as a pass; `requireBoolean` is one exception. So a member read or call on `number`, `boolean`, `string`, an array, or `unknown` passes, whatever the member name.
- Q2 and Q7: `inferIndexReadType` gives no type to an index read on a `string`, or on a union that holds a `string`. The interpreter's `get_elem` returns `undefined` for every string receiver. A probe measured `"ab"[0] === undefined` as true.
- Q4 and Q5 (D3): eight `zttp:collections` exports declare their Dict parameter as `.dict`, and `packages/zts/src/module_types.zig` maps `.dict` to `Dict<unknown, unknown>`. `dictEmpty` has no parameter, and `dictFromEntries` takes `.object`. A Dict is invariant in its key. So a Dict whose key type is known, such as `Dict<string, number>`, cannot reach these exports. No tracked `.ts` file annotates a Dict type. The unannotated parameters of a `dictFold` callback have no type today.
- Q6: `inferMemberAccessType` has no case for a receiver that admits `undefined`, such as `P | undefined`. ZTS309 comes from `reportTypedAbsentReads` in `packages/zts/src/handler_verifier.zig`, which runs after the sound-mode stage. `packages/tools/src/precompile_check_run.zig` returns after a sound-mode, type, or strict error. So a U3 refusal hides the ZTS309 of the same read.
- Q9: after R2b, `r.error` admits `undefined` when the Result can fill `errors`. `recordAbsentReceiver` records the `.length` read. But `isTrackedResultFieldRead` in `handler_verifier.zig` leaves every read on `b.value`, `b.error`, or `b.errors` to the Result check (ZTS303), and ZTS303 accepts the read after `!r.ok`. So no check refuses it. R2b opened this gap.
- Q10: `firstUnencodable` checks the value type of a Dict and not its key type. The encoder path is not confirmed.

### Runtime facts

These were read from the code. Q1 to Q3 and Q7 confirm the first two.

- A call of a member that the receiver does not have raises `NotCallable` (`doCall` checks `isCallable`). A read of such a member gives `undefined` (`get_field`).
- `number` and `boolean` have no prototype. Strings and arrays have the members that `packages/zts/src/builtins/root.zig` installs. `length` on a string is handled by the interpreter, and on an array by `JSObject.getProperty`.
- The census in `packages/zts/src/builtin_results.zig` enumerates the installed string and array members in a live context, in both directions. Each member has a row in `rows` or an entry in `skips`. `length` has a row. `find` searches only `rows`.
- A Dict is immutable (`packages/zts/src/dict.zig`). Each change returns a new Dict. A key can be any value, compared with SameValueZero. `dictGet` gives `undefined` for a missing key.
- `dictFold(d, f, init)` calls `f(acc, value, key)` once for each entry in insertion order. The first `acc` is `init`, and each later `acc` is the previous result. It returns the last result, or `init` for an empty Dict.
- `dictMapValues(d, f)` and `dictFilter(d, f)` call `f(value, key)`. `dictFilter` throws a `TypeError` when `f` returns a value that is not a boolean.
- When the first argument is not a Dict, `dictHas` returns `false`, and the other Dict-consuming exports return `undefined`. The three callback exports also return `undefined` when the callback is missing.

## Target

- Q1, Q2, Q3, Q7, Q8, and Q9 are refused.
- Q4 and Q5 are accepted, with the types in Design item 3.
- `dictFold(d, (acc, value, key) => acc + value, 0)` with `d: Dict<string, number>` binds `value` to `number` and passes.
- The A3 fixture keeps its three ZTS309 errors under U3.
- The U3 entry check runs again. U3 is built only when it passes.

## Design

1. **S1: string index.**
   - An index read whose receiver type is `string` gets ZTS201 with the message "an index read on a string yields undefined". The help names `s.charAt(i)` and `s.slice(i, i + 1)`.
   - In a union receiver, a `string` member contributes `undefined` to the read type. So `x[0]` with `x: string | string[]` is `string | undefined`, and ZTS309 refuses an unchecked read on it.
   - `s[0] === undefined` runs correctly today, and S1 refuses it. That is accepted: the read always gives `undefined`.
2. **P9: member access on a receiver that is not a record.**
   - The receiver types are `number`, `boolean`, `string`, an array, a tuple, and a union of these. For a read or a call of a member that the runtime does not install on every member of that union, the access gets ZTS201.
   - The member set is the union of the `rows` and `skips` entries of the string and array scopes in `builtin_results.zig`. `number` and `boolean` have no member. The checker reads those tables through a new lookup function. It does not copy the list. The census keeps the tables equal to what the engine installs.
   - A member read or call on a receiver of declared type `unknown` gets ZTS201 with the message "a member read on an unknown value; narrow it first". `typeof` and `isDict` narrowing still give a typed receiver. The existing messages for a parsed JSON value and a Dict do not change.
   - In a union that holds a record, a member that is not a record contributes `undefined` to the read type, as a record without the field already does. So `x.age` with `x: P | string` is `number | undefined`, and ZTS309 refuses an unchecked read on it.
   - S1 and P9 reuse the `.missing_field` kind (ZTS201) with new messages. A new kind would move the diagnostic catalog hash and its pin.
   - Records, Result records, `Request`, `Response`, `Headers`, and the other named builtin types do not change.
3. **K1a: Dict assignability and the Dict-consuming exports.**
   - Assignability, in `packages/zts/src/type_pool.zig#TypePool`: a Dict whose key type is `never` is assignable to every Dict type. A Dict is assignable to a Dict whose key type is `unknown` when its value type is assignable to the target value type. Otherwise keys stay invariant.
   - The reason: a Dict is immutable, a lookup of a missing key gives `undefined`, and a `never` key holds no entry. So a wider key is sound. The comment in `assignableStep` gives invariance a usability reason (a lookup that cannot succeed should not type-check), and that choice stays for every other key.
   - Call types, next to `resultExportCallType`. Each rule reads the first argument as `Dict<K, V>`. None of these rules refuses an argument.
     - `dictEmpty()` is `Dict<never, never>`.
     - `dictSet(d, k, v)` is `Dict<K | widen(k), V | widen(v)>`. When `K` is `never`, it is `Dict<widen(k), widen(v)>`.
     - `dictGet(d, k)` is `V | undefined`, or `undefined` when `K` is `never`.
     - `dictHas(d, k)` is `boolean`, `dictRemove(d, k)` is `Dict<K, V>`, and `dictEntries(d)` is `[K, V][]`.
     - When the first argument is not a single Dict type, the call keeps the declared return type of the binding.
4. **K1b: Dict callbacks.**
   - An unannotated inline callback of `dictFold` binds its parameters to `(acc, V, K)`. An unannotated inline callback of `dictMapValues` or `dictFilter` binds them to `(V, K)`. An annotated callback must accept those types, or it gets ZTS203, as C1 does for the array methods.
   - `dictMapValues(d, f)` is `Dict<K, R>`, where `R` is the callback return type under the bound parameters, or `unknown`.
   - `dictFilter(d, f)` is `Dict<K, V>`. A callback return that is not assignable to `boolean` gets ZTS203, because the runtime throws.
   - `dictFold(d, f, init)` uses the accumulator rule of a seeded `reduce`. The checker binds `acc` to `widen(init)`, reads the callback return under that binding, and keeps the binding only when that return is known and assignable. The result is that type, or `unknown`.
   - Over a `Dict<unknown, unknown>`, such as a Dict from `isDict`, a callback that does arithmetic on the value gets ZTS104 or ZTS106, because the value is `unknown`. Such a program can run correctly when every value is a number. The refusal is accepted because the value can be any JSON value. The entry check lists each such program.
5. **R3: a read on a Result error that can be absent.** `isTrackedResultFieldRead` stops leaving a read on `b.error` to ZTS303 when the Result type of `b` has an `errors` field that is not `never`. ZTS309 then reports `r.error.length` in Q9. Reads on `b.value` and `b.errors` stay with ZTS303.
6. **U3: an arithmetic operand with no type.** On strict paths only (`ResolveOptions.strict`), `requireNumeric` and `requireAddable` in `packages/zts/src/bool_checker.zig#BoolChecker` refuse an operand that the type checker leaves without a type. They do not refuse an operand that `reportTypedAbsentReads` will report as ZTS309. The skip test is the same predicate that the verifier uses: the operand's read node is a key of `absent_receivers`, and `isTrackedResultFieldRead` is false for it. A path that sets `skip_contract` runs no verifier and gives no proof, so the skip cannot hide a read there.

## Decision 1: goldens and census counts under D-012

A new diagnostic on a `tests/corpus/check/bad` case changes its `.diag` golden, and it can move the R7c census counts in `packages/pi/src/tools/common.zig`. The executor's hand-back for the previous U3 entry check states that the census test was the only failing test in `test-expert-app`, and the offline replay passed.

D-012 says that a change that moves a golden or a pin waits for a re-record window. Its binds and its gate are the prompts, the cassettes, `policy-hash.txt`, `docs/convergence.json`, and `test-expert-app`. The census and the corpus goldens are not in that list. The previous plan's record called the census move model-visible.

- (a) A unit may update a bad-case golden or a census count when the offline replay holds and the new diagnostic is true. The hand-back lists each change. Unit D adds this clarification to D-012 in `docs/decisions.md` and corrects the previous plan's record. **Recommended**: the replay is the gate of D-012, and C1 to R2b already added diagnostics without a re-record.
- (b) Each such change waits for the next re-record window. Each unit that moves a golden or a count then stops before its commit.

## Entry checks

S1, P9, K1b, R3, and U3 each add a refusal. Before the unit is done, the executor runs the built `zts check` on every tracked `.ts` file, with a build of the parent commit for comparison. The hand-back lists each new diagnostic with its file, form, and rule.

Few tracked files call the Dict exports. So K1a and K1b also run these probe programs and report each type and diagnostic: values of two types in one Dict, number keys, `dictGet` on `dictEmpty()`, a union of two Dict types, a Dict from `isDict`, a join of `dictEmpty()` with a typed Dict, and `Response.json` of a Dict.

## Units

Every unit runs with a private `ZIG_LOCAL_CACHE_DIR` and with `DEEPSEEK_API_KEY` unset. The executor does not commit. Opus reviews the diff, runs the gates, and commits each unit. The units run in this order, one at a time.

| Unit | Model | Scope | Acceptance | Turn budget |
|---|---|---|---|---|
| S1: string index | Sonnet | `packages/zts/src/type_checker.zig` and tests | Q2 and Q7 are refused. `s.charAt(0)` and `s.length` pass. The S1 tests fail before and pass after | 30 |
| P9: member access | Sonnet | `type_checker.zig`, a lookup function in `builtin_results.zig`, and tests | Q1, Q3, and Q8 are refused. `s.toUpperCase()`, `xs.map(f)`, `xs.length`, `t.length` on a tuple, `r.f(2)` on a record with a function field, and a `typeof`-narrowed `unknown` pass. The P9 tests fail before and pass after | 50 |
| K1a: Dict assignability and calls | Sonnet | `type_pool.zig`, `type_checker.zig`, and tests | Q4 and Q5 pass with the types in Design item 3. Q3 stays refused. The K1a tests fail before and pass after | 40 |
| K1b: Dict callbacks | Sonnet | `type_checker.zig` and tests | The `dictFold` target passes with `value: number`. An annotated `(v: string)` callback over `Dict<string, number>` gets ZTS203. The K1b tests fail before and pass after | 50 |
| R3: Result error reads | Sonnet | `packages/zts/src/handler_verifier.zig` and tests | Q9 gets ZTS309. A read on `r.value` after `r.ok` and on `r.error` of a `parseJson` Result keep their current diagnostics. The R3 tests fail before and pass after | 30 |
| U3: untyped arithmetic operand | Sonnet | `bool_checker.zig`, the strict flag, and tests | Runs only when its entry check passes. The A3 fixture keeps three ZTS309. The U3 tests fail before and pass after | 40 |
| D: record and docs | Opus | `docs/typescript.md`, `docs/verification.md`, `docs/roadmap.md`, `docs/decisions.md` under Decision 1 (a), `CHANGELOG.md`, `docs/plans/README.md`, both plans, the solution note, and `../ZTTP-WEBSITE` if a claim changes | `zig build test`, `bash scripts/verify.sh`, and `zig build test-zruntime` exit 0 from an empty cache | Opus |

Gates for each unit: `zig build test`, `zig build test-zruntime`, and `zig fmt --check` on the changed files. `zig build test` includes the proof ratchet tests that the per-unit lists of the previous plan left out. Opus also runs these steps by name, so that each exit status is read on its own: `test-examples`, `test-expert-app`, `test-diagnostic-corpus`, `test-bytecode-identity`, `test-residual-guards-drift`, `test-docs-drift`, and `test-proof-ratchet-drift`.

## Stop conditions

- The offline replay in `test-expert-app` diverges. The change is then model-visible under D-012. Stop before the commit and report the case and the diagnostic.
- An entry check refuses a program in a committed example, fixture, or corpus draft that runs correctly, and the refused value has one runtime type on every input. Stop and hand back the program, the form, and the diagnostic. A refused value that comes from parsed input or from a `Dict<unknown, unknown>` can hold any JSON value; list it and continue.
- Under Decision 1 (b), a unit moves a golden or a census count. Stop before the commit.
- A runtime result is not clear from the runtime code. Stop and report the export or member.
- `packages/proof-checker` would need a change.

## Out of scope

- Q10: a ZTS213 refusal of a Dict whose key type is not `string` in `Response.json`. The encoder path must be confirmed first. `docs/roadmap.md` records it.
- A type for `dictFromEntries` from its argument.
- A type for a member read on a receiver that admits `undefined`, such as `ps[0].age`. ZTS309 refuses that read, and U3 skips it.
- A call on the result of an earlier member call on a union receiver, such as `x.slice(1).trim()` with `x: string | string[]`. The first call has no type.
- `q.age` with `q: P | null = null`, which a probe left silent. Its cause is not known.
- Member access on `Request`, `Response`, `Headers`, and the other named builtin types.
- The other gaps under Current Limitations in `docs/roadmap.md`.

## Validation record

Revision 1, 2026-11-03. A Fable review attacked the design and ran probes. A Codex review (`gpt-6-astra`, read-only) checked 47 claims. Opus reran each load-bearing probe on the HEAD binaries.

- Fable: S1 missed a union receiver. Q7 is a false proof; Opus ran it under `zttp dev` and got 500. Design item 1 types a string member of a union as `undefined`.
- Fable: P9 left a union of a record and a primitive open. Q8 passes `zts check`, and Fable's run answered 500. Design item 2 covers it.
- Fable: revision 0 refused `dictSet(dictSet(dictEmpty(), "a", 1), "b", "two")`, a valid program, and `dictGet(dictEmpty(), x)`. The Dict call rules in Design item 3 now refuse no argument.
- Fable: the U3 skip let Q9 pass, because the verifier leaves a Result field read to ZTS303. Opus read `isTrackedResultFieldRead`. R3 is a new unit, and the U3 skip uses the verifier's own predicate.
- Fable: P9 changes the residual guard list in `docs/verification.md`, and a new diagnostic kind would move the catalog hash. Unit D edits that file, the gate list names the drift gates, and S1 and P9 reuse ZTS201.
- Fable: the callback-dependent result types belong in K1b. They moved.
- Fable: Q10 is a 500 that K1 makes easy to refuse. It is out of scope until the encoder path is confirmed.
- Codex: `inferMemberAccessType` also types builtin constants, and `requireBoolean` refuses `null_type_idx`. The Cause section says both.
- Codex: `dictEmpty` and `dictFromEntries` take no `.dict` parameter, `Dict<unknown, number>` already reaches the exports, `dictHas` returns `false` for a non-Dict, and unannotated `dictFold` callback parameters have no type rather than `unknown`. The Cause and Runtime facts sections say each one.
- Codex: the member set is in `rows` and `skips`, and `find` searches only `rows`. Design item 2 reads both.
- Codex: `absent_receivers` is keyed by the read node, not by the receiver. Design item 6 says so.
- Codex: a static `unknown` does not show that a program fails at runtime. The stop condition now separates a value with one runtime type from a value that can hold any JSON value.
- Codex: D-012 freezes goldens and pins, so revision 0's rule needed reconciling. Fable judged the rule consistent with D-012's binds and gate. Decision 1 puts the choice to the owner.

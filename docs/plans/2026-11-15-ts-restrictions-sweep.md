# TS Restrictions Sweep Ledger

Status: 2026-11-15. Binary `zts` 0.27.1, built from commit `bd12ef3f`. This
sweep is read-only. It changed no file except this ledger. It is unit U0 of the
[enforcement plan](2026-11-15-ts-restrictions-enforcement-plan.md).

## Method

Each probe is one small file with a named export. For example, a probe body sits
inside `export function handler(req: Request): Response { ... }`, or a probe is
a raw top-level file. The command is
`/tmp/zts-u0/zts check --json probe.ts < /dev/null`. The sweep reads the
`diagnostics` array. The sweep ignores ZTS305, ZTS306, and ZTS500, because they
appear on almost every probe and hide no result. About 300 probes ran, in
batches by spec section. The sweep walked the grammar of section 8, the MUST,
MUST NOT, and "excludes" rules of sections 5.1 to 5.8, and the rules of sections
6.1 to 6.5.

A probe form is a gap when `zts check` exits 0 for it, or when it reports only a
code that does not name the form. A code that does not name the form is, for
example, ZTS003 "unexpected token" or ZTS047 "statement is not terminated". Type
probes used an exported function parameter, because an unused type is never
checked.

One tool defect cost a re-run. The first runner merged stderr into stdout. The
merge hid every stripper code (ZTS041 to ZTS060) as "accepted". I fixed the
runner and re-ran every batch. All results below come from the fixed runner.

Counts for tracked `.ts` files come from
`git ls-files -z '*.ts' | xargs -0 grep -nE ...`. The sweep read each hit. A hit
in a comment, a type union, a URL, or a CSS string is not a use. For N11 and N12
an awk script flagged candidates, and I read each flag.

Corpus method. The sweep took the active generation of each of the 13 cases. It
checked each `expected/` handler (with the `initial/` files for imports). It
extracted every `propose_change_set` change from the active responses. Each
change carries the full file text, so each is reconstructed exactly. This gave
22 drafts. It also read the 8 `zts_expert_fill_hole` calls. A fill-hole call
carries only an expression, so those are scanned as expressions and are not
whole files. The other tool calls write no source.

## New Gaps

Known gaps are excluded. The rows below are new. "ERR" means the form gets an
error code. "ACCEPT" means exit 0 for the handler probe. Row IDs are for this
ledger only.

| ID  | Spec rule                             | Probe                                                                                                                                                                                                                                     | Observed result                                                                          | Proposed refusal                                                                                  |
| --- | ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| X1  | 5.1, 8 (`TopDecl`)                    | `f();` or `if (true) { }` at top level                                                                                                                                                                                                    | ACCEPT                                                                                   | New code, or ZTS002. See the corpus warning below                                                 |
| X2  | 5.1 (init MUST be pure)               | `const t: number = Date.now();` at top level                                                                                                                                                                                              | ACCEPT                                                                                   | New strict rule                                                                                   |
| X3  | 8 (`Module`)                          | `import { ok } from "zttp:result";` after a declaration                                                                                                                                                                                   | ACCEPT                                                                                   | ZTS002                                                                                            |
| X4  | 5.1                                   | `import ...;` or `export const q = 1;` inside a function body                                                                                                                                                                             | ACCEPT                                                                                   | ZTS002                                                                                            |
| X5  | 5.1                                   | `import type X from "./x.ts";`                                                                                                                                                                                                            | ACCEPT                                                                                   | ZTS002                                                                                            |
| X6  | 5.1                                   | `import { ok } from m;` (non-literal specifier)                                                                                                                                                                                           | ZTS003                                                                                   | Message that names the rule                                                                       |
| X7  | 5.2, 8 (`Bind`)                       | `const a = 1, b = 2;`                                                                                                                                                                                                                     | ZTS047                                                                                   | ZTS001                                                                                            |
| X8  | 5.2, 8                                | `for (const [a, b] of xs)` and `for (const { a } of xs)`                                                                                                                                                                                  | ZTS003                                                                                   | ZTS001 (destructuring)                                                                            |
| X9  | 8 (`Stmt`)                            | `structural L = number;` or `nominal L = number;` in a function                                                                                                                                                                           | ZTS047                                                                                   | New code                                                                                          |
| X10 | 5.2 (arrow only as callback argument) | `const f = (x: number): number => x; f(1)`, a returned arrow, an arrow in a record field, an IIFE, an arrow as a `?:` arm                                                                                                                 | ACCEPT. ZTS608 refuses only a reused helper                                              | New code. The restrictions file recommends "a field that holds an arrow", which the spec excludes |
| X11 | 5.6, 8 (`ArrowParams`)                | `[1].map(<T>(x: T) => x)`                                                                                                                                                                                                                 | ACCEPT                                                                                   | ZTS001                                                                                            |
| X12 | 5.6                                   | `function f<in T>(...)`, `function f<const T>(...)`, a return type `asserts x is string`                                                                                                                                                  | ACCEPT                                                                                   | New code                                                                                          |
| X13 | 5.3 (fields cannot be added)          | `o.z = 1` on a record type with no field `z`                                                                                                                                                                                              | ACCEPT. The read `o.z` gets ZTS201                                                       | ZTS201 on the write                                                                               |
| X14 | 5.2                                   | `const a = 1; const a = 2;` in one scope                                                                                                                                                                                                  | ACCEPT                                                                                   | New code                                                                                          |
| X15 | 5.2                                   | `const n: number = 1; n = 2;`                                                                                                                                                                                                             | ZTS200 "type '2' is not assignable to type '1'"                                          | New code that names `const`                                                                       |
| X16 | 5.3 (identifier key)                  | `{ "a": 1 }` and the type `{ "a": number }`                                                                                                                                                                                               | ACCEPT. The known gap covers only the read `r["a"]`                                      | Same fix as the known read gap                                                                    |
| X17 | 8 (`LValue`)                          | `o.a?.a = 1;` and `(n) = 2;`                                                                                                                                                                                                              | ACCEPT                                                                                   | ZTS001                                                                                            |
| X18 | 5.2, 8 (`RecordExpr`)                 | `{ ...o }` with no explicit field after the spread                                                                                                                                                                                        | ACCEPT                                                                                   | ZTS614                                                                                            |
| X19 | 5.5, 8                                | `else g();` and `for (const k of xs) g();` with no block                                                                                                                                                                                  | ACCEPT. Same family as the known `if` gap                                                | Same fix as the known `if` gap                                                                    |
| X20 | 5.5 (`match` MUST)                    | Two `when 1:` arms, or a `default` on a closed union                                                                                                                                                                                      | ZTS216 warning only, exit 2. Spec: "errors", "MUST NOT include default"                  | Raise ZTS216 to an error                                                                          |
| X21 | 5.5                                   | `for (const k of 5)`                                                                                                                                                                                                                      | ACCEPT. Extends the known fixed-record case (G6)                                         | Same fix as G6                                                                                    |
| X22 | 6.4                                   | `stringifyJson(closure)` and `stringifyJson(d)` with `Dict<number, string>`                                                                                                                                                               | ACCEPT. `Response.json` refuses the same payload with ZTS213                             | ZTS213                                                                                            |
| X23 | 6.5 (closed set)                      | `xs.toReversed()`, `Array.from(xs)`, `Array.of(1)`, `xs.length = 0`                                                                                                                                                                       | ACCEPT. `reverse`, `sort`, `fill`, `at`, `flat`, `keys` get ZTS201                       | ZTS201, ZTS200                                                                                    |
| X24 | 6.5 (signatures)                      | `xs.slice(1)`, `xs.slice()`, `xs.toSorted()`, `xs.join()`, `xs.reduce(f)`, `xs.indexOf(v, i)`, `xs.includes(v, i)`, and a 3-parameter `map` callback                                                                                      | ACCEPT. A 4-parameter callback gets ZTS203                                               | ZTS202                                                                                            |
| X25 | 5.4, 6.5 (`join` takes `string[]`)    | `[1, 2].join("")`                                                                                                                                                                                                                         | ACCEPT                                                                                   | ZTS203                                                                                            |
| X26 | 5.7 (admitted types)                  | A parameter of type `Record<K, V>`, `Map`, `Set`, `bigint`, `symbol`, `Function`, `{}`, `Exclude`, `NonNullable`, `Date`, `RegExp`, `Error`, `this`                                                                                       | ACCEPT. A type name outside the admitted list resolves silently                          | New code. Extends G3 and G7                                                                       |
| X27 | 5.7, 8 (`Type`)                       | `new () => T`, `unique symbol`, tuple element `string?`, named tuple member, tuple rest, `readonly { a: number }`, rest parameter in a function type, a method signature, a call signature, `{ a: number, b: string }` (comma separators) | ACCEPT                                                                                   | New code. Extends G3 and G7                                                                       |
| X28 | 6.2 (`DictKey`)                       | `Dict<boolean, string>` and `Dict<{ a: number }, string>`                                                                                                                                                                                 | ACCEPT                                                                                   | ZTS209                                                                                            |
| X29 | 5.7 (`ScalarType`)                    | `nominal B = boolean;`                                                                                                                                                                                                                    | ACCEPT. Spec allows `number` or `string`. The restrictions file says `boolean` also fits | Owner decision: change the spec or the compiler                                                   |
| X30 | 5.3, 6.5                              | `Object.create(null)`, `Object.defineProperty(o, "a", ...)`, `Object.fromEntries(...)`                                                                                                                                                    | ACCEPT                                                                                   | ZTS201. The restrictions file lists `Object` as ambient, so the spec needs a closed member list   |
| X31 | 6.3 (`byteAt`)                        | `b[0]` and `b.length` on `Bytes`                                                                                                                                                                                                          | ACCEPT                                                                                   | ZTS201                                                                                            |
| X32 | 5.4                                   | `10n`                                                                                                                                                                                                                                     | ZTS047                                                                                   | ZTS012 or ZTS001                                                                                  |

Count: 32 new rows. Rows X1 to X5, X7 to X9, and X15 mix a missing refusal with
an untargeted code. Rows X10, X13, X14, X20, X22, and X23 are the ones that
weaken a proof claim. They are the most important.

Corpus warning for X1. The form is the idiomatic registration pattern. The
corpus cases `validate-body` and `sql-users` write `schemaCompile(...)` and
`sql(...)` at top level. Tracked `.ts` files carry 13 such lines in 10 files. A
refusal of X1 needs a spec change or a re-record. This is an owner decision.

Probes that already refused correctly, so they are not gaps: `unwrap` and
`unwrapErr` (ZTS207), `reverse`, `sort`, `fill`, `at`, `flat`, `keys`,
`entries`, `lastIndexOf`, `reduceRight` (ZTS201), `Array<T>` (ZTS058), `void`
(ZTS060), `any` (ZTS041), `1_000` (ZTS012), `NaN` and `Infinity` (ZTS629),
`x.hasOwnProperty` and `x.toString` (ZTS201), a nested conditional (ZTS621), a
`default` before `when` (ZTS062), `nominal` over an array used in a signature
(ZTS048), and `export { f }` of a local name (ZTS002).

## Candidate Counts

Corpus uses count the 13 finals and the 22 reconstructed drafts. The 8 fill-hole
expressions contain none of the forms.

| ID                                         | Tracked .ts uses   | Corpus uses | Method                                                                                                                                                                                                           |
| ------------------------------------------ | ------------------ | ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| N1 bitwise                                 | 0                  | 0           | grep for `<<`, `>>`, `^`, `~`, `&`, `\|`. All hits were generic closers (3), intersection types (34), URL text, or type unions                                                                                   |
| N2 `**`                                    | 0                  | 0           | grep                                                                                                                                                                                                             |
| N3 `Boolean(x)`, `Number(x)`               | 0                  | 0           | grep                                                                                                                                                                                                             |
| N4 `substring`                             | 0                  | 0           | grep                                                                                                                                                                                                             |
| N5 `Headers`                               | 0                  | 0           | grep                                                                                                                                                                                                             |
| N7 `0b`, `0o`, `.5`                        | 0                  | 0           | grep. 8 `.5` hits are CSS inside a string in `examples/fetch/weather-app.ts`                                                                                                                                     |
| N8 utility types                           | 4 lines in 1 file  | 0           | grep. All are in `examples/patterns/derive-types.ts`                                                                                                                                                             |
| N10 local function                         | 5 lines in 2 files | 0           | grep for an indented `function`. Both files are `tests/corpus/check` cases: `good/nested_functions_with_one_name.ts` and `bad/bool_condition_in_nested_function.ts`                                              |
| N11 parameter reassignment                 | 0                  | 0           | awk over single-line signatures, then reading. Multi-line signatures were not scanned                                                                                                                            |
| N12 shadowing                              | 0                  | 0           | awk flags, then reading. The 2 duplicate `const secret` lines in `examples/modules-all/modules_all.ts` and its fixture sit in sibling blocks, not nested. Sibling arrows that reuse `n` or `e` are not shadowing |
| N13 `concat`                               | 0                  | 0           | grep                                                                                                                                                                                                             |
| N14 empty or bare block                    | 0                  | 0           | grep. 1 line `{` is CSS in a string                                                                                                                                                                              |
| N15 `Number.parseInt`, `Number.parseFloat` | 0                  | 0           | grep                                                                                                                                                                                                             |
| N16 call in assignment target              | 0                  | 0           | grep for `f(...).x =`                                                                                                                                                                                            |

The only candidates with a nonzero count are N8 (4 lines, 1 example) and N10 (5
lines, 2 checker test files). Each hit of N8 and N10 is a deliberate test of the
form. N6, N9, and N17 are deferred and were not re-measured.

Counts for the known gaps in tracked `.ts` files: `forEach`, `pop`, `shift`,
`unshift`, `splice` have 4 lines in 1 file. A `let` without an initializer
has 0. `stringifyJson` has 2 lines in 1 file.

## Corpus Impact

Active generations only. "Draft" is a `propose_change_set` file in a recorded
response. File names are under `<case>/generations/<active>/`.

| Case          | File or draft                                | Form                                     | Fix or candidate that refuses it |
| ------------- | -------------------------------------------- | ---------------------------------------- | -------------------------------- |
| validate-body | `expected/handler.ts`                        | `JSON.stringify` in `schemaCompile(...)` | G4                               |
| validate-body | drafts r2, r3, r4, r6, r8                    | `JSON.stringify` in `schemaCompile(...)` | G4                               |
| validate-body | `expected/handler.ts` and the 5 drafts above | top-level `schemaCompile(...)`           | X1, if adopted                   |
| sql-users     | `expected/handler.ts` and draft r4           | top-level `sql("listUsers", ...)`        | X1, if adopted                   |

Totals. The sweep checked 22 drafts and 13 final files, which is 35 files. Every
final file passes `zts check` today, except two ZTS700 and ZTS306 notes that
come from the missing schema file and an unused import, not from a gap. G4
refuses 5 drafts and 1 final. X1 refuses 6 drafts and 2 finals. The union is 6
drafts and 2 finals. No approved candidate (N1 to N16) refuses a draft or a
final. No other known gap refuses a draft or a final, among the forms the scan
covered (X10, X13, X14, X22 to X25 were not scanned in drafts).

Other notes. The case `weather-egress` has an empty expected workspace, so it
has no final. Its 5 drafts fail today with ZTS056, ZTS002, ZTS026, ZTS001, and
ZTS105, so no planned change adds a new refusal. The case `sibling-helper` keeps
its final in `lib/settings.ts`, and it passes. The `.ts` files in the corpus use
no `match` expression, no higher-order callback, and no `let` without an
initializer.

## Limits

- The sweep did not test semantic rules that need a large program, such as
  proof-property claims, effect rows, or flow labels.
- The sweep did not probe the rules of sections 7, 9 to 17, or the agent
  protocol of section 4.8.
- Type probes covered one position (an exported parameter). A type in a return
  position, a `structural` alias, or a generic argument may behave differently.
- Each probe tests one form. A gap row says nothing about the form inside a
  larger program.
- N11 and N12 counts come from a line-based script and reading. Multi-line
  signatures and arrow parameters that span lines were not scanned.
- The sweep counted tracked `.ts` files only. Zig test strings are not counted.
  The plan reports 61 lines of `JSON.stringify` there.
- The fill-hole calls are expressions, not files. The sweep scanned them by
  reading. A draft that the model proposed through another channel is not in the
  corpus and was not checked.
- Probe results are for build `bd12ef3f`. U1 changes `packages/tools` in
  parallel, and this ledger does not reflect that work.
- N6, N9, and N17 are deferred and were not re-measured.

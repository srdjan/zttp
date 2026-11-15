# TypeScript Restrictions

This file collects every restriction of the `zts-model-1` source profile in
one place. The profile is a constrained language with TypeScript lexical
conventions. It is not a TypeScript dialect, and TypeScript documentation does
not define its semantics.

The normative source is [the zts-model-1 specification](spec/zts-model-1.md),
section 5. [Restrictions to Proofs](restrictions-to-proofs.md) gives the
reason for each restriction and the proof that it unlocks. This file adds the
diagnostic code and the replacement form for each restriction.

The codes in this file come from `zts check` on the build of commit
`a1db8b0b`, run on 2026-11-15. The section
[Spec rules that `zts check` does not enforce](#spec-rules-that-zts-check-does-not-enforce)
lists the gaps that those runs found.

## How To Query The Live Rules

These commands print the rules from the compiler that you run:

```bash
zttp features                 # allowed and blocked constructs
zttp restrictions --json      # the restriction registry, with stable restriction.<slug> ids
zttp describe-rule ZTS613     # one rule record, with its help text
zttp describe-rule --idioms   # advisory idioms; these never fail a build
```

Three layers report restrictions, in this order:

1. The parser and the type stripper report `ZTS0xx` codes.
2. The type checker reports `ZTS1xx` and `ZTS2xx` codes.
3. The strict checker reports `ZTS6xx` codes for the canonical profile.

A layer runs only when the layers before it pass. For example, a `ZTS204`
type error hides a `ZTS624` strict error in the same function. The text output
of `zts check` omits the code for a type-stripper error. Use `--json` to see
the code.

## Source Files And Modules

| Refused form | Code | Write instead |
|---|---|---|
| A `.js`, `.jsx`, `.tsx`, or unknown file extension | ZTS052 | A `.ts` file. Build HTML with `h()` and `renderToString()` |
| `import X from "mod"` (default import) | ZTS002 | `import { x } from "mod"` |
| `import * as X from "mod"` (namespace import) | ZTS002 | Named imports |
| `import "mod"` (side-effect import) | ZTS002 | Named imports |
| `import("mod")` (dynamic import) | ZTS002 | A static named import |
| `export { x } from "mod"` and `export { x }` of an imported name | ZTS002 | Import the original declaration, or export a named wrapper function |
| `export * from "mod"` | ZTS002 | Named exports |
| `export default ...` | ZTS056 | `export function handler(...) { ... }` |
| `export let x = ...` (mutable top-level export) | ZTS057 | `export const`. Keep reassignment inside a function |
| A top-level `let` that is never reassigned | ZTS604 | `const` |
| A handler that writes to a module-scope variable | ZTS310 | Function-local state |
| `import { ... } from "zttp:types"` | ZTS053 | Write `Proof<T, P>` or `Effects<T, R>` directly. Both are ambient |
| An unknown `zttp:` module, or a name that the module does not export | ZTS206, ZTS207 | A module and an export from `packages/zts/src/builtin_modules.zig` |
| `namespace` and `module` declarations | ZTS001 | ES modules |

A module specifier must be a string literal. Relative modules and registered
`zttp:*` or `zttp-ext:*` modules are permitted. Module initialization must be
pure.

## Lexical Rules

| Refused form | Code | Write instead |
|---|---|---|
| An escape outside the closed set, such as `"a\qb"` | ZTS013 | One of `\n \r \t \b \f \v \0 \\ \' \" \` \$ \xNN \uNNNN \u{N..}` |
| A backslash before a real newline | ZTS045 | Join the lines, or write `\n` |
| A string literal that reaches the end of its line | ZTS008 | Close the quote, or write `\n` |
| `0x`, `0b`, or `0o` with no digits, and `1e` with no exponent digits | ZTS012 | Write the digits |
| A legacy octal literal such as `0755` | ZTS012 | `0o755`, or remove the leading zero |
| A character above ASCII in an identifier | ZTS046 | An ASCII identifier |
| A statement with no `;` | ZTS047 | Write the `;`. The profile has no automatic semicolon insertion |

## Declarations And Bindings

| Refused form | Code | Write instead |
|---|---|---|
| `var` | ZTS001 | `const`, or `let` when the binding is reassigned |
| A `let` that is never reassigned | ZTS604 | `const` |
| Object or array declaration destructuring, and destructuring renames | ZTS001 | Bind the source to one name, then read each member into a `const` |
| `class` declarations and `class` expressions | ZTS001 | Plain records and functions |
| `enum` and `const enum` | ZTS001 | A literal union or a discriminated union |
| Decorators (`@decorator`) | ZTS001 | Function composition |
| `implements` and access modifiers (`public`, `private`, `protected`) | ZTS001 | Remove them |
| `interface X { ... }` | ZTS049 | `structural X = { ... };` |
| `type X = ...;` | ZTS050 | `structural X = ...;`. `import type` and `export type { ... }` keep the keyword |
| `distinct type X = string;` | ZTS051 | `nominal X = string;` |
| A `nominal` type over a record, tuple, union, or function | ZTS048 | `nominal` over `string`, `number`, or `boolean`. Use `structural` for other shapes |
| A reused arrow helper, such as `const double = (x) => x * 2;` | ZTS608 | A named `function` declaration |
| An exported function-valued `const` | ZTS609 | `export function name(...) { ... }` |

Declaration merging, open interfaces, and inheritance are excluded.

## Functions And Parameters

| Refused form | Code | Write instead |
|---|---|---|
| Function expressions, named or anonymous | ZTS001 | A function declaration, or an arrow as a direct callback argument |
| Generators (`function*`) and `yield` | ZTS001 | A function that returns an array |
| `async` functions, `await`, and `Promise` | ZTS001 | Synchronous code. Use `fetch` from `zttp:fetch` for outbound I/O |
| A default parameter, such as `limit = 50` | ZTS054 | `limit: number \| undefined`, then `const resolved = limit ?? 50;` in the body |
| Optional parameter shorthand `name?: T` | ZTS055 | `name: T \| undefined` |
| Rest parameters `...args` | ZTS001 | An explicit array parameter |
| Call-site spread `f(...args)` | ZTS616 | Positional arguments |
| A named function without parameter or return annotations | ZTS601 | Annotate every parameter and the return type |
| A call with too few or too many arguments | ZTS202 | Supply every declared argument, and no more |
| `this` and `super` | ZTS001 | Pass the context as an explicit parameter |
| An exported function that reaches a capability with no `Effects<...>` return ceiling | ZTS610 | Declare `Effects<T, R>` on the return type |
| A module-internal function that declares an `Effects<...>` ceiling | ZTS623 | Remove the ceiling |

A direct arrow callback can infer its types from a typed callback position. It
can also declare a leading prefix of the callback parameters. This prefix rule
is the only arity flexibility in the profile.

## Statements And Control Flow

The statement set is: block, `const`, necessary `let`, plain assignment,
expression statement, `if`/`else`, `for...of`, `assert`, `return`, `break`,
`continue`, and local function declaration.

| Refused form | Code | Write instead |
|---|---|---|
| `switch` / `case` | ZTS001 | `match` |
| `while` and `do...while` | ZTS001 | `for...of` over a finite collection |
| C-style `for (;;)` | ZTS001 | `for (const i of range(n))` |
| `for...in` | ZTS001 | `for (const k of Object.keys(obj))` |
| Labeled `break` and `continue` | ZTS001 | A conditional |
| `break` or `continue` outside a loop | ZTS022, ZTS023 | Move the statement into a `for...of` body |
| `throw`, `try`, `catch`, and `finally` | ZTS001 | Return a `Result` or an error `Response` |
| `debugger;` | ZTS001 | Remove the statement |
| An empty statement `;` | ZTS001 | Remove the standalone semicolon |
| A fallback `assert` form | ZTS002 | `if (!predicate) { return fallback; }` |
| A `for...of` body that mutates the collection that it iterates | ZTS622 | Read one collection and build the changed one separately |
| `range(n).map(f)` and other array members on `range(n)` | ZTS201 | `for (const i of range(n))` |

`for...of` evaluates its iterable once and iterates a snapshot. The admitted
iterables are arrays, tuples, strings, `range(n)`, and `Dict` entries. There is
no user-defined iterator protocol.

## Operators And Expressions

| Refused form | Code | Write instead |
|---|---|---|
| `==` and `!=` | ZTS001 | `===` and `!==` |
| `++` and `--`, prefix and postfix | ZTS001 | `x = x + 1` |
| Compound assignment: `+=`, `-=`, `*=`, `/=`, `%=`, `**=`, `&=`, `\|=`, `^=`, `<<=`, `>>=`, `>>>=` | ZTS613 | `x = x + e` |
| Logical assignment: `&&=`, `\|\|=`, `??=` | ZTS001 | `x = x && value` |
| `instanceof` | ZTS001 | A discriminated union with a tag field |
| The `in` operator | ZTS001 | The predicate for the value kind, such as `dictHas` |
| Unary `+` | ZTS001 | Remove it from a number, or parse text with `parseInt` or `parseFloat` |
| Unary `void` | ZTS001 | `undefined`. Evaluate an effect as its own statement |
| `delete` | ZTS001 | A new object literal with only the keys that you keep |
| `new` | ZTS001 | A factory function or an object literal |
| Regex literals and the `RegExp` global | ZTS001 | String methods such as `includes` and `startsWith` |
| Comma and sequence expressions | ZTS003 | Separate statements |
| Template interpolation `` `n=${n}` `` | ZTS001 | `["n=", String(n)].join("")`. A backtick literal with no interpolation is permitted |
| `+` with a string operand | ZTS105 | `[a, String(b)].join("")` |
| `+` with a boolean, optional, or untyped operand | ZTS106 | Narrow or convert the operand first |
| `-`, `*`, `/`, `%`, `**`, or unary `-` on a non-number | ZTS104 | Narrow the operand to `number` first |
| A non-boolean condition in `if`, `assert`, or `?:` | ZTS100 | A boolean expression, such as `x !== undefined` or `n > 0` |
| A non-boolean operand of `&&`, `\|\|`, or `!` | ZTS101, ZTS102 | A boolean expression |
| `\|>`, `pipe()`, and `guard()` | ZTS001 | A direct call `f(a)`. Run guards by early return |
| Optional call `f?.()` | ZTS001 | Check for `undefined`, then call `f()` |
| Optional computed access `xs?.[i]` | ZTS001 | Check for `undefined`, then read `xs[i]` |
| An effectful arm in `a ? b : c` | ZTS612 | Bind the call to a `const` first, or use `match` over the condition |
| A conditional expression as an arm of another conditional | ZTS621 | `match` over one scrutinee, or `if`/`else` |
| A boolean compared to a boolean literal, such as `x === true` | ZTS620 | `x`, or `!x` for `=== false` |

There is no truthiness conversion. A value of type `unknown` cannot enter a
boolean context. `String(value)` is the only conversion from a number or a
boolean to text.

## Records, Arrays, And Strings

| Refused form | Code | Write instead |
|---|---|---|
| Object literal shorthand `{ value }` | ZTS001 | `{ value: value }` |
| Object methods, getters, and setters | ZTS001 | A field that holds an arrow, or an explicit function |
| A computed record key `{ [k]: v }` | ZTS001 | A literal field name, or a `Dict` for dynamic keys |
| A numeric record key `{ 1: "a" }` | ZTS001 | A string key, or an array for dense indices |
| An object spread after an explicit key, or a second spread | ZTS614 | One leading spread: `{ ...base, x: 1 }` |
| Dynamic property access `obj[key]` | ZTS605 | A typed field, a literal key, or a `Dict` |
| `Object.assign`, `Object.freeze`, and `Object.isFrozen` | ZTS001 | Object spread |
| A member that the runtime does not hold, such as `n.toFixed(2)` or `n.toString()` | ZTS201 | `String(n)` |
| A numeric index read on a string, such as `s[0]` | ZTS201 | `s.charAt(i)` or `s.slice(i, i + 1)` |
| A member call on `unknown` or on a value with no known type | ZTS201 | Narrow with `typeof` or `isDict` first |
| A container write whose value does not fit the slot type | ZTS200 | A value of the slot type |
| `push`, `pop`, `shift`, `unshift`, `splice`, or a `length` write on a tuple | ZTS200 | Annotate the binding as an array |
| A write to a `readonly` field | ZTS215 | A new record |

Record shapes are fixed after allocation. `items.push(value)` is the one
growth operation for arrays. An index write past the current length is a
bounds fault, not growth.

## Null, Undefined, And Absence

| Refused form | Code | Write instead |
|---|---|---|
| `null` where the type does not name `null` | ZTS200, ZTS203 | Add `null` to the type, or use `undefined` |
| `??` or `?.` on an operand whose type admits `null`, a generic parameter, or `unknown` | ZTS624 | An explicit `=== null` or `=== undefined` test, or `match` |
| A read of a possibly absent value without a check | ZTS308, ZTS309 | An `if (x !== undefined)` guard, or `??` |
| A call result with an implicit `unknown` type | ZTS600 | Annotate the source, or validate the value |

`undefined` is the absence sentinel. `null` is explicit data, mainly for JSON.
On a concrete type without `null`, `??` and `?.` are the preferred spelling of
absence handling.

## Match

| Refused form | Code | Write instead |
|---|---|---|
| A `default` arm before a `when` arm, or a second `default` arm | ZTS062 | One `default`, after every `when` arm |
| A type-test name below the top level of a pattern, such as `when { v: string }` | ZTS001 | Bind the field and match it in a nested `match` |
| `when _:` | ZTS001 | `default:` |
| A `match` that does not cover every case | ZTS205, ZTS603 | Cover each member, or add `default` for an open domain |
| A `default` arm on a closed union that is already covered | ZTS216 (warning) | Remove the `default` arm |
| A rename to the same name, such as `{ text: text }` in a pattern | ZTS625 | `{ text }` |
| An arm that reads a field off the scrutinee | ZTS626 | Bind the field in the pattern |

Patterns are literals, fixed record patterns, array patterns, and six type
tests: `boolean`, `number`, `string`, `array`, `Dict`, and `Bytes`. `null` and
`undefined` match by their literal patterns.

## Types

| Refused form | Code | Write instead |
|---|---|---|
| `any` in any position | ZTS041 | `unknown` with narrowing, or a precise type |
| `x as T` and `<T>x` | ZTS042 | Narrow with `typeof`, a type predicate, or a decoder |
| `x satisfies T` | ZTS043 | An annotation on the declaration |
| `Array<T>` | ZTS058 | `T[]` |
| `ReadonlyArray<T>` | ZTS059 | `readonly T[]` |
| The `void` type | ZTS060 | `undefined` |
| A raw built-in open type in an exported parameter or return | ZTS061 | A `nominal` or `structural` alias |
| A recursive alias with a cycle that does not pass through a record, tuple, array, or `Dict` | ZTS212 | Put the cycle under one of those constructors |
| A type predicate whose body does not prove the predicate | ZTS211 | A predicate body that checks the claimed type |
| A wrong number of explicit type arguments, or a violated constraint | ZTS210, ZTS209 | Match the declaration |

The admitted types are listed in section 5.7 of the
[specification](spec/zts-model-1.md). The specification also excludes these
type features: higher-rank function types, `keyof`, indexed-access types,
index signatures, type-position `typeof`, conditional types, mapped types,
`infer`, overloads, ambient declarations, generic defaults, and variance
annotations. `zts check` gives none of them a targeted diagnostic. The gap
section below gives the observed behavior.

## Ambient Names And Effects

The closed ambient value namespace is: `Array`, `Boolean`, `Date`, `Headers`,
`JSON`, `Math`, `Number`, `Object`, `Request`, `Response`, `String`, `assert`,
`h`, `hole`, `isBytes`, `isDict`, `parseFloat`, `parseInt`, `range`,
`renderToString`, `requestBody`, `requestJson`, and `requestText`. The `meta`
operation of `zttp agent --stdin-json` publishes this list as
`payload.ambient_names`.

| Refused form | Code | Write instead |
|---|---|---|
| A value name outside the ambient namespace, such as `console`, `process`, `globalThis`, or `Symbol` | ZTS629 | An import from a `zttp:` module |
| `eval`, `Proxy`, and `Reflect` | ZTS001 | A named function, or direct property access |
| A capability call with a dynamic argument, such as a computed env key | ZTS602 | A literal argument, or a policy that names the value |

`Date.now()` and `Math.random()` are admitted. They remove the `deterministic`
property from the handler. When the handler declares no `Proof<T, P>`
capsule, the default proof profile then reports ZTS500.

## Request, Response, And JSON

| Refused form | Code | Write instead |
|---|---|---|
| A Response init member other than `status`, such as `headers` | ZTS203 | `{ status: 201 }`. Response headers are not supported |
| A Response init that is not a record, or a `status` that is not a number | ZTS203 | `Response.text("x", { status: 404 })` |
| `Response.redirect(url, { status: 301 })` | ZTS203 | `Response.redirect(url, 301)` |
| A `Response.json` payload that JSON cannot carry, such as `Dict<number, string>` | ZTS213 | A string-keyed payload |
| A member or index read on the `.value` of `requestJson(req)` | ZTS201 | `decodeJson` with a schema, or `isDict(v)` and `dictGet(v, key)` |

`requestBody(req)` returns `Bytes`. `requestText(req)` and `requestJson(req)`
return a `Result`.

## Limits

The `meta` operation publishes these limits:

| Limit | Value |
|---|---|
| Source file size | 10485760 bytes |
| Request size | 20971520 bytes |
| Modules in one module graph | 1024 |
| Normalization iterations | 64 |
| Type serialization depth | 64 |

The specification limits a generic declaration to eight type parameters. A
declaration with eight type parameters passes `zts check`. Nesting deeper than
the parser limit reports ZTS044.

## Spec Rules That `zts check` Does Not Enforce

Each row is a probe that ran on 2026-11-15. Each probe was one small handler
file. The specification excludes each form, but `zts check` did not refuse it
with a targeted diagnostic.

| Form | Observed result |
|---|---|
| Assignment in expression position, such as `const m = (n = 2);` | Accepted, exit 0 |
| Generic defaults, such as `function f<T = string>(a: T): T` | Accepted, exit 0 |
| Index signatures, such as `{ [k: string]: number }` | Accepted, exit 0, also when used in a signature |
| `JSON.parse` and `JSON.stringify` | Accepted, exit 0 |
| `match` on a call, such as `match (g()) { ... }` | Accepted, exit 0. The specification requires an identifier or a member path |
| `for...of` over a fixed record | Accepted by the type and strict checks |
| `keyof`, mapped types, conditional types, and type-position `typeof` | Accepted when unused. When used in a signature, they cause unrelated ZTS201, ZTS203, or ZTS204 errors |
| `declare`, `abstract class`, and the non-null assertion `x!` | Refused with ZTS047, "statement is not terminated" |
| Overload declarations, tagged templates, and comma expressions | Refused with ZTS003, "unexpected token" |
| The angle-bracket assertion `<number>x` | Refused with ZTS002, "raw JSX is not supported". The registry names ZTS042 |
| A generic declaration with nine type parameters | Refused with ZTS203 on the ninth argument, not with a limit diagnostic |

The specification also requires that the subexpressions of an assignment
target are pure. The probes did not test that rule.

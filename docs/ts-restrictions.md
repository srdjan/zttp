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
type error hides a `ZTS624` strict error in the same function.

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
| An unknown `zttp:` module, or a name that the module does not export | ZTS206, ZTS207 | A module and an export from `packages/zts/src/builtin_modules.zig` |
| `namespace` and `module` declarations | ZTS001 | ES modules |
| An `import` after a declaration | ZTS002 | Move each `import` above the first declaration |
| An `import` or `export` inside a function body | ZTS002 | Move the `import` or `export` to the top level |
| `import type X from "./x.ts";` | ZTS002 | `import type { X } from "./x.ts";` |
| A module specifier that is not a string literal, such as `import { ok } from m;` and `import type { T } from m;` | ZTS003 | A string literal, such as `"./lib.ts"` |

A module specifier must be a string literal. Relative modules and registered
`zttp:*` or `zttp-ext:*` modules are permitted. Module initialization must be
pure.

## Lexical Rules

| Refused form | Code | Write instead |
|---|---|---|
| An escape outside the closed set, such as `"a\qb"` | ZTS013 | One of `\n \r \t \b \f \v \0 \\ \' \" \` \$ \xNN \uNNNN \u{N..}` |
| A backslash before a real newline | ZTS045 | Join the lines, or write `\n` |
| A string literal that reaches the end of its line | ZTS008 | Close the quote, or write `\n` |
| `0x` with no digits, and `1e` with no exponent digits | ZTS012 | Write the digits |
| A binary or octal literal, such as `0b101` and `0o17` | ZTS012 | A decimal or `0x` literal |
| A number with no digit before the point, such as `.5` | ZTS012 | `0.5` |
| A legacy octal literal such as `0755` | ZTS012 | A decimal or `0x` literal |
| A bigint literal, such as `10n` | ZTS012 | The profile has no bigint. Write a `number` literal |
| A numeric separator such as `1_000` | ZTS012 | `1000` |
| A character above ASCII in an identifier | ZTS046 | An ASCII identifier |
| A statement with no `;` | ZTS047 | Write the `;`. The profile has no automatic semicolon insertion |

## Declarations And Bindings

| Refused form | Code | Write instead |
|---|---|---|
| `var` | ZTS001 | `const`, or `let` when the binding is reassigned |
| A `let` that is never reassigned | ZTS604 | `const` |
| Object or array declaration destructuring, and destructuring renames | ZTS001 | Bind the source to one name, then read each member into a `const` |
| A declaration with no initializer, such as `let a: number;` and `const a: number;` | ZTS021 | Write `const a: number = 1;`, or give the `let` an initializer |
| A declaration that binds two names, such as `const a = 1, b = 2;` | ZTS001 | Write one `const` for each name |
| A second declaration of a name in one scope, such as `const a = 1; const a = 2;`, a `function` and a `const` of one name, and an import and a declaration of one name | ZTS019 | A different name |
| An assignment to a `const` binding, such as `const n: number = 1; n = 2;` and `for (const k of xs) { k = 1; }` | ZTS066 | Write `let`, or bind the new value to a new name |
| A reserved word as a value name, such as `const set = 1;`, `function from(): number`, a parameter named `of`, an arrow parameter named `get`, the pattern binding `when { from }`, and `import { dictEmpty as match }` | ZTS067 | Another name. A reserved word stays valid as a record key, a type field, a pattern key, and a member name, such as `{ assert: 1 }`, `when { from: f }`, and `x.assert`. Spec Section 5.2 lists the reserved words |
| `class` declarations and `class` expressions | ZTS001 | Plain records and functions |
| `declare` declarations | ZTS001 | Import the value from a module |
| `abstract class` | ZTS001 | Plain records and functions |
| The non-null assertion `x!` | ZTS001 | Check for `undefined` first, or use `??` |
| A function overload, which is a signature with no body | ZTS001 | One function whose parameter type is a union |
| A tagged template, which is a template literal after an expression | ZTS001 | Call the function with a string argument |
| `enum` and `const enum` | ZTS001 | A literal union or a discriminated union |
| Decorators (`@decorator`) | ZTS001 | Function composition |
| `implements` and access modifiers (`public`, `private`, `protected`) | ZTS001 | Remove them |
| `interface X { ... }` | ZTS049 | `structural X = { ... };` |
| `type X = ...;` | ZTS050 | `structural X = ...;`. `import type` and `export type { ... }` keep the keyword |
| `distinct type X = string;` | ZTS051 | `nominal X = string;` |
| A `nominal` type over a record, tuple, union, or function | ZTS048 | `nominal` over `string`, `number`, or `boolean`. Use `structural` for other shapes |
| A reused arrow helper, such as `const double = (x) => x * 2;` | ZTS608 | A named `function` declaration |
| An exported function-valued `const` | ZTS609 | `export function name(...) { ... }` |
| A nominal type called as a function, such as `Id("a")` | ZTS214 | An annotated declaration: `const x: Id = "a";` |

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
| Type parameters on an arrow, such as `<T>(x: T) => x` | ZTS001 | The arrow without type parameters, or a module-level generic function |
| An empty type parameter, such as `<A, ,B>` and `<A,>` | ZTS001 | Remove the extra comma |
| A duplicate parameter name, such as `function f(a: number, a: number)`, and a duplicate type parameter, such as `function f<T, T>(a: T): T` and `structural Box<T, T> = T;` | ZTS018 | A different name |
| An assignment to a parameter, such as `a = a + 1` for a function parameter and `x = 0` for an arrow parameter | ZTS068 | Bind the new value to a new `const` |
| Call-site spread `f(...args)` | ZTS616 | Positional arguments |
| A named function without parameter or return annotations | ZTS601 | Annotate every parameter and the return type |
| A call with too few or too many arguments | ZTS202 | Supply every declared argument, and no more |
| `this` and `super` | ZTS001 | Pass the context as an explicit parameter |
| An exported function that reaches a capability with no `Effects<...>` return ceiling | ZTS610 | Declare `Effects<T, R>` on the return type |
| A module-internal function that declares an `Effects<...>` ceiling | ZTS623 | Remove the ceiling |
| An `await` outside an async function | ZTS026 | A direct call. Use `fetch` from `zttp:fetch` for outbound I/O |
| A generic call in which no argument fixes a type parameter | ZTS208 | Name the type argument at the call site, such as `f<number>()` |
| An exported helper with no `Proof<...>` capsule, when the handler declares a proof spec | ZTS611 | Declare `Proof<T, "...">` as the return type of the helper |

A direct arrow callback can infer its types from a typed callback position. It
can also declare a leading prefix of the callback parameters. This prefix rule
is the only arity flexibility in the profile.

## Statements And Control Flow

The statement set is: `const`, necessary `let`, plain assignment, expression
statement, `if`/`else`, `for...of`, `assert`, `return`, `break`, `continue`,
and local function declaration. A block is only the body of a function, `if`,
`else`, or `for...of`.

| Refused form | Code | Write instead |
|---|---|---|
| `switch` / `case` | ZTS001 | `match` |
| `while` and `do...while` | ZTS001 | `for...of` over a finite collection |
| `for...in` | ZTS001 | `for (const k of Object.keys(obj))` |
| `throw`, `try`, `catch`, and `finally` | ZTS001 | Return a `Result` or an error `Response` |
| `debugger;` | ZTS001 | Remove the statement |
| An empty statement `;` | ZTS001 | Remove the standalone semicolon |
| A bare block statement, such as `{ const a = 1; }` | ZTS001 | Put its statements in the enclosing block |
| An empty body of `if`, `else`, or `for...of`, such as `if (c) {}` | ZTS001 | Remove the statement, or invert the condition and drop the empty branch |
| A fallback `assert` form | ZTS002 | `if (!predicate) { return fallback; }` |
| A `for...of` body that mutates the collection that it iterates | ZTS622 | Read one collection and build the changed one separately |
| `range(n).map(f)` and other array members on `range(n)` | ZTS201 | `for (const i of range(n))` |
| Destructuring in a `for...of` head | ZTS001 | Bind the element to one name, then read each member in the body |

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
| Bitwise operators `&`, `\|`, `^`, `~`, `<<`, `>>`, and `>>>` | ZTS001 | Arithmetic or a comparison. The profile has no bit operations |
| The `**` operator | ZTS001 | `Math.pow(a, b)` |
| `instanceof` | ZTS001 | A discriminated union with a tag field |
| The `in` operator | ZTS001 | The predicate for the value kind, such as `dictHas` |
| Unary `+` | ZTS001 | Remove it from a number, or parse text with `parseInt` or `parseFloat` |
| Unary `void` | ZTS001 | `undefined`. Evaluate an effect as its own statement |
| `delete` | ZTS001 | A new object literal with only the keys that you keep |
| `new` | ZTS001 | A factory function or an object literal |
| Regex literals and the `RegExp` global | ZTS001 | String methods such as `includes` and `startsWith` |
| A comma expression, such as `(1, 2)` and `f(), g();` | ZTS001 | Write each expression as its own statement |
| Template interpolation `` `n=${n}` `` | ZTS001 | `["n=", String(n)].join("")`. A backtick literal with no interpolation is permitted |
| `+` with a string operand | ZTS105 | `[a, String(b)].join("")` |
| `+` with a boolean, optional, or untyped operand | ZTS106 | Narrow or convert the operand first |
| `-`, `*`, `/`, `%`, or unary `-` on a non-number | ZTS104 | Narrow the operand to `number` first |
| A non-boolean condition in `if`, `assert`, or `?:` | ZTS100 | A boolean expression, such as `x !== undefined` or `n > 0` |
| A non-boolean operand of `&&`, `\|\|`, or `!` | ZTS101, ZTS102 | A boolean expression |
| `\|>` | ZTS001 | A direct call `f(a)`. Run guards by early return |
| Optional call `f?.()` | ZTS001 | Check for `undefined`, then call `f()` |
| Optional computed access `xs?.[i]` | ZTS001 | Check for `undefined`, then read `xs[i]` |
| An effectful arm in `a ? b : c` | ZTS612 | Bind the call to a `const` first, or use `match` over the condition |
| A conditional expression as an arm of another conditional | ZTS621 | `match` over one scrutinee, or `if`/`else` |
| A boolean compared to a boolean literal, such as `x === true` | ZTS620 | `x`, or `!x` for `=== false` |
| Assignment in expression position, such as `const m = (n = 2);`, `a = b = 3;`, and `(a = 2);` | ZTS001 | Write the assignment as its own statement |
| An assignment target that is not a name, a member path, or an index, such as `(n) = 2;` and `o.a?.a = 1;` | ZTS016 | Assign to a name, a member path, or an index |
| A call in an assignment target, such as `mk().n = 2` and `mk().a.n = 2` | ZTS016 | Bind the call result to a `const` first |
| An assignment target whose root is not a name, such as `[1, 2][0] = 5` and `[mk(), b][0].n = 2` | ZTS016 | Bind the value to a `const` first, then assign through the name |

There is no truthiness conversion. A value of type `unknown` cannot enter a
boolean context. `String(value)` is the only conversion from a number or a
boolean to text.

## Records, Arrays, And Strings

| Refused form | Code | Write instead |
|---|---|---|
| Object literal shorthand `{ value }` | ZTS001 | `{ value: value }` |
| Object methods, getters, and setters | ZTS001 | A module-level function |
| A computed record key `{ [k]: v }` | ZTS001 | A literal field name, or a `Dict` for dynamic keys |
| A numeric record key `{ 1: "a" }` | ZTS001 | A string key, or an array for dense indices |
| A quoted record key that is a name, such as `{ "a": 1 }` | ZTS001 | `{ a: 1 }`. A key that is not a name, such as `"Content-Type"`, stays quoted |
| An object spread after an explicit key, or a second spread | ZTS614 | One leading spread: `{ ...base, x: 1 }` |
| An object spread with no explicit field after it, such as `{ ...o }` | ZTS614 | Use `o` itself, or add an explicit field after the spread |
| Dynamic property access `obj[key]` | ZTS605 | A typed field, such as `obj.a`, or a `Dict` read with `dictGet` |
| A string-literal read of a key that is a name, such as `r["a"]` | ZTS605 | `r.a` |
| `Object.assign`, `Object.freeze`, and `Object.isFrozen` | ZTS001 | Object spread |
| A member that the runtime does not hold, such as `n.toFixed(2)` or `n.toString()` | ZTS201 | `String(n)` |
| The array members `forEach`, `pop`, `shift`, `unshift`, `splice`, `toReversed`, and `concat`, and the string member `substring` | ZTS201 | `for...of`, `slice`, or spread `[...a, ...b]` for an array, and `slice` for a string |
| A member that an ambient value does not hold, such as `Object.create`, `Object.defineProperty`, `Object.fromEntries`, `Object.hasOwn`, `Array.from`, `Array.of`, or `h.foo` | ZTS201 | `Object.keys`, `Object.values`, `Object.entries`, object spread, or `for...of` |
| An array member call with an argument list that spec 6.5 does not give, such as `xs.slice(1)`, `xs.slice()`, `xs.toSorted()`, `xs.join()`, `xs.reduce(f)`, or `xs.indexOf(v, i)`, and a callback with a third parameter, such as `xs.map((x, i, all) => x)` | ZTS202 | The arguments of spec 6.5: `xs.slice(start, end)`, `xs.reduce(f, init)`, and a callback `(value, index)` or `(acc, value, index)` |
| `join` on an array of non-strings, such as `[1, 2].join("")` | ZTS203 | Convert each element with `String` first |
| A numeric index read on a string, such as `s[0]` | ZTS201 | `s.charAt(i)` or `s.slice(i, i + 1)` |
| An index read or a `length` read on `Bytes`, such as `b[0]` and `b.length` | ZTS201 | `byteAt(b, i)` or `bytesLength(b)` from `zttp:bytes` |
| A member call on `unknown` or on a value with no known type | ZTS201 | Narrow with `typeof` or `isDict` first |
| A container write whose value does not fit the slot type | ZTS200 | A value of the slot type |
| A write to a field that the type does not declare, such as `o.z = 1` | ZTS201 | Declare the field in the record type, or build a new record with spread |
| `push` on a tuple | ZTS200 | Annotate the binding as an array |
| A write to the `length` of a string, an array, or a tuple | ZTS200 | A new array, built with `slice` or spread |
| A mutating method on a `readonly` array | ZTS215 | A new array, or remove `readonly` from the type |
| A `dictEntries` round trip through `dictFromEntries` that changes only values or drops entries | ZTS627 (advisory) | `dictMapValues(d, f)` or `dictFilter(d, p)` |
| A `reduce` over `dictEntries(d)` | ZTS628 (advisory) | `dictFold(d, f, init)` |

Record shapes are fixed after allocation. `items.push(value)` is the one
growth operation for arrays. An index write past the current length is a
bounds fault, not growth. The two `dictEntries` rows are advisories. An advisory never fails a build.

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
| A rename to the same name, such as `{ text: text }` in a pattern | ZTS625 (advisory) | `{ text }` |
| An arm that reads a field off the scrutinee | ZTS626 (advisory) | Bind the field in the pattern |

An advisory names a better form for code that is already correct. An advisory
never fails a build (spec section 4.2.1).

Patterns are literals, fixed record patterns, array patterns, and six type
tests: `boolean`, `number`, `string`, `array`, `Dict`, and `Bytes`. `null` and
`undefined` match by their literal patterns.

## Types

| Refused form | Code | Write instead |
|---|---|---|
| `any` in any position | ZTS041 | `unknown` with narrowing, or a precise type |
| `x as T` | ZTS042 | Narrow with `typeof`, a type predicate, or a decoder |
| The angle-bracket assertion `<T>x` | ZTS042 | Narrow with `typeof`, a type predicate, or a decoder |
| `x satisfies T` | ZTS043 | An annotation on the declaration |
| `Array<T>` | ZTS058 | `T[]` |
| `ReadonlyArray<T>` | ZTS059 | `readonly T[]` |
| The `void` type | ZTS060 | `undefined` |
| A raw built-in open type in an exported parameter or return | ZTS061 | A `nominal` or `structural` alias |
| A recursive alias with a cycle that does not pass through a record, tuple, array, or `Dict` | ZTS212 | Put the cycle under one of those constructors |
| A type predicate whose body does not prove the predicate | ZTS211 | A predicate body that checks the claimed type |
| A wrong number of explicit type arguments, or a violated constraint | ZTS210, ZTS209 | Match the declaration |
| A ninth type parameter in one generic declaration, such as `function f<A, B, C, D, E, F, G, H, I>(a: A): A` | ZTS028 | Use at most eight type parameters |
| A Dict key type other than string or number, such as `Dict<boolean, string>`, `Dict<undefined, string>`, `Dict<unknown, string>`, and `Dict<string \| undefined, string>` | ZTS209 | Use `string` or `number` as the key type |
| A `structural` or `nominal` declaration inside a function | ZTS002 | Declare the type at the top level |
| A generic default, such as `function f<T = string>(a: T): T` | ZTS001 | Remove the default. Pass the type argument at each use |
| A type-parameter modifier, such as `in`, `out`, or `const` | ZTS001 | Remove the modifier |
| An `asserts` return type | ZTS001 | A type predicate `x is T`, or `assert` in the caller |
| A keyof type, such as `keyof T` | ZTS001 | The key union, such as `"a" \| "b"` |
| An indexed access type, such as `A["a"]` | ZTS001 | The field type |
| An index signature, such as `{ [k: string]: number }` | ZTS001 | `Dict<string, number>` |
| A mapped type, such as `{ [K in "a" \| "b"]: number }` | ZTS001 | The record type |
| A conditional type, such as `T extends string ? number : boolean`, including one that uses infer | ZTS001 | The type that the condition selects |
| A type-position typeof, such as `typeof base` | ZTS001 | The type itself |
| A quoted key in a record type, such as `{ "a": number }` | ZTS001 | The key as a name, such as `{ a: number }` |
| A number literal type that is not an integer in -32768..32767, such as `1.5`, `1e3`, and `40000` | ZTS001 | `number`, or an integer literal type in that range |
| A type form outside the admitted grammar, such as `new () => T`, `unique symbol`, `[string?]`, `[a: string]`, `[...string[]]`, a rest parameter in a function type such as `(...a: string[]) => number`, a method signature such as `{ m(): number }`, a call signature such as `{ (): number }`, and an empty parenthesized type with no arrow, such as `Outer<()>` and `structural E = ();` | ZTS001 | An admitted type form from section 5.7 of the specification |
| An unrecognized type, such as `number number`, an empty type, such as `structural L = ;`, a field with no type, such as `{ x: }`, a missing separator, such as `{ x: number y: string }`, `(x: number y: string) => number`, `B<string number>`, and `[number string]`, a function type with no return type, such as `(x: number) =>`, an unclosed bracket, such as `number [`, an explicit call type argument, such as `f<number number>(1)`, and a generic constraint, such as `T extends number string` | ZTS001 | An admitted type from section 5.7 of the specification |
| A record type with comma separators, such as `{ a: number, b: string }` | ZTS001 | `{ a: number; b: string }` |
| `readonly` on a record type, such as `readonly { a: number }` | ZTS001 | The record type |
| A type name that is not declared, imported, or ambient, such as `Record<K, V>`, `Map`, `Set`, `bigint`, `symbol`, `Function`, `Exclude`, `NonNullable`, `Date`, `RegExp`, `Error`, `object`, and the utility types `Partial<T>`, `Required<T>`, `Pick<T, K>`, `Omit<T, K>`, and `Readonly<T>` | ZTS065 | A declared or imported type, or an ambient type from `meta` |

The admitted types are listed in section 5.7 of the
[specification](spec/zts-model-1.md). The specification also excludes these
type features: higher-rank function types, `keyof`, indexed-access types,
index signatures, type-position `typeof`, conditional types, mapped types,
`infer`, overloads, and ambient declarations. The Types table gives the
refusals of generic defaults, type-parameter modifiers, `asserts` return
types, `keyof`, indexed-access types, index signatures, mapped types,
conditional types, `infer`, type-position `typeof`, and any other text that
follows a type. The Declarations And Bindings table gives the refusals of
overloads and of `declare`. `zts check` gives the other features no targeted
diagnostic. The gap section below gives the observed behavior.

## Admitted Members

The type checker admits these members on an array, on a string, and on each ambient namespace. Each line names one scope. The members are in byte order.

`Array.prototype`: `every`, `filter`, `find`, `findIndex`, `includes`, `indexOf`, `join`, `length`, `map`, `push`, `reduce`, `slice`, `some`, `toSorted`

`String.prototype`: `charAt`, `charCodeAt`, `concat`, `endsWith`, `includes`, `indexOf`, `lastIndexOf`, `length`, `padEnd`, `padStart`, `repeat`, `replace`, `replaceAll`, `slice`, `split`, `startsWith`, `toLowerCase`, `toUpperCase`, `trim`, `trimEnd`, `trimStart`

`Array`: `isArray`

`Date`: `now`

`JSON`: `parse`, `stringify`, `tryParse`

`Math`: `PI`, `abs`, `ceil`, `cos`, `exp`, `floor`, `log`, `max`, `min`, `pow`, `random`, `round`, `sin`, `sqrt`, `tan`, `trunc`

`Number`: `EPSILON`, `MAX_SAFE_INTEGER`, `MAX_VALUE`, `MIN_SAFE_INTEGER`, `MIN_VALUE`, `NEGATIVE_INFINITY`, `NaN`, `POSITIVE_INFINITY`, `isFinite`, `isInteger`, `isNaN`, `parseFloat`, `parseInt`

`Object`: `entries`, `keys`, `values`

`Response`: `html`, `json`, `rawJson`, `redirect`, `text`

`String`: `fromCharCode`

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
| Type parameters in one generic declaration | 8 |

A generic declaration with eight type parameters passes `zts check`. The
parser refuses a ninth type parameter with ZTS028. Nesting deeper than the
parser limit reports ZTS044.

## Spec Rules That `zts check` Does Not Enforce

Each row is a probe that ran on 2026-11-15. Each probe was one small handler
file. The specification excludes each form, but `zts check` did not refuse it
with a targeted diagnostic.

The table also lists each form for which an earlier version of this file gave a
code that the compiler does not report. The Required column gives the code and
the form that the compiler must give. When a fix lands, the row moves to a
refusal table. The gate `zig build test-ts-restrictions` checks each row
against the compiler.

| Form | Observed result | Required |
|---|---|---|
| `JSON.parse` and `JSON.stringify` | Accepted | ZTS629. Use `parseJson` or `stringifyJson` from `zttp:json`, or `decodeJson` from `zttp:decode` |
| `match` on a call, such as `match (g()) { ... }` | Accepted, exit 0. The specification requires an identifier or a member path | A targeted refusal. Bind the value to a `const` first |
| `for...of` over a fixed record | Accepted by the type and strict checks | A targeted refusal. Iterate an array, such as `Object.keys(r)` |
| `import { ... } from "zttp:types"` | Refused with ZTS206 for a value import, and with ZTS053 for `import type` | ZTS053 for both. Write `Proof<T, P>` or `Effects<T, R>` directly. Both are ambient |
| C-style `for (;;)` | Refused with ZTS001 and ZTS002 | ZTS001 only. Write `for (const i of range(n))` |
| Labeled `break` and `continue` | Refused with ZTS001 and ZTS047 | ZTS001 only. Write a conditional |
| `break` or `continue` outside a loop | Refused with ZTS002. The probes do not report ZTS022 or ZTS023 | ZTS022 for `break`, ZTS023 for `continue`. Move the statement into a `for...of` body |
| `pipe()` and `guard()` | Refused with ZTS600 and ZTS629 | ZTS001. Write a direct call `f(a)`. Run guards by early return |
| A write to a `readonly` field | Refused with ZTS200 | ZTS215. Write a new record |
| A `match` that does not cover every case, in a statement or a `const` | Refused with ZTS603 | The same refusal in every position. Cover each member, or add `default` for an open domain |
| A `match` that does not cover every case, as the return value | Refused with ZTS204. The check also reports ZTS205 as a warning | The same refusal in every position. Cover each member, or add `default` for an open domain |
| A body that is not a block, such as `if (c) g();`, `else g();`, and `for (const k of xs) g();` | Accepted, exit 0 | A targeted refusal. Write the body as a block |
| A generic alias argument that breaks the constraint of its parameter, such as `Box<number>` for `structural Box<T extends string> = { value: T };` | Accepted, exit 0 | ZTS209. Pass a type argument that satisfies the constraint |
| `FetchOptions` with no import | Accepted, exit 0. The specification names a module type through `import type` from its module, and `zttp:fetch` exports no type | An `import type` from `zttp:fetch` |
| `DictKey` with no import, such as `<K extends DictKey>` | Accepted, exit 0. The `meta` ambient names do not list it | A published ambient name, or `string \| number` |
| A higher-order callback that calls `push`, or that assigns a captured binding | Accepted, exit 0 | A targeted refusal. Build the result with `for...of` |
| A top-level statement other than a registration call, such as `f();` and `if (c) { f(); }` | Accepted, exit 0 | A targeted refusal. Move the statement into a function. A bare `schemaCompile(...)` or `sql(...)` call with literal arguments stays admitted |
| An arrow outside a callback argument: a `const`-bound arrow, a returned arrow, an arrow in a record field, an immediately called arrow, and an arrow as a `?:` arm | Accepted, exit 0. ZTS608 refuses only a reused helper | A targeted refusal. Write a module-level `function` |
| A top-level initializer with an effect, such as `const t: number = Date.now();` | Accepted, exit 0 | A targeted refusal. Compute the value inside a function |
| `for...of` over a number, such as `for (const k of 5)` | Accepted, exit 0 | A targeted refusal. Iterate an array, a string, or `range(n)` |
| `stringifyJson` of a value that JSON cannot carry, such as a function or a `Dict<number, string>` | Accepted, exit 0. `Response.json` refuses the same payload with ZTS213 | ZTS213. Pass a string-keyed payload |
| A `default` arm on a closed union that is already covered, or a duplicate `when` arm | Accepted, exit 2. The check reports ZTS216 as a warning | ZTS216 as an error. Remove the `default` arm or the duplicate arm |

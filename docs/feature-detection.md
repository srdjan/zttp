# Feature Detection Matrix

This document catalogs all unsupported JavaScript and TypeScript features detected by zttp's fail-fast validation system, organized by detection layer.

## Detection Architecture

zttp validates in two layers:

1. **Parser** (`packages/zts/src/parser/parse.zig`): Reads `.ts` source directly and catches unsupported JavaScript and TypeScript features.
2. **Strict checker** (`packages/zts/src/strict_checker.zig`): Runs after parsing on `zttp check` and `zttp verify-paths`, and enforces the [canonical profile](#canonical-profile-strict-checker).

**Principle**: Each feature should be detected at exactly one layer to avoid duplicate error reporting and ensure consistent error messages regardless of file type.

## TypeScript Type-Position Features

The parser checks these features in TypeScript type positions.

| Feature | Error Type | Suggested Alternative |
|---------|------------|----------------------|
| `any` type (all positions: annotations, assertions, nested) | UnsupportedAnyType | Use specific types (string, number, a record type) or union types |
| `as` type assertion (e.g., `x as string`) | UnsupportedAssertion | Use explicit type narrowing with typeof guards or undefined checks |
| `satisfies` operator (e.g., `x satisfies T`) | UnsupportedAssertion | Use explicit type annotations on declarations |
| A string literal that reaches the end of its line | UnterminatedString | Close the quote, or write the newline as `\n` |

The parser reports an unterminated string as ZTS008 with a line and a column,
including when the string occurs in a type position.

## Lexical Rules

The escape set, the numeric forms, and the identifier character set are closed.
Each of these was accepted silently before and is now refused with a location.

| Form | Code | What it does instead |
|---|---|---|
| `"a\qb"` - an escape outside the closed set | ZTS013 | The set is `\n \r \t \b \f \v \0 \\ \' \" \` \$ \xNN \uNNNN \u{N..}`, in quoted strings and template literals alike |
| A backslash before a real newline | ZTS045 | Join the lines, or write the newline as `\n` |
| `0x` with no digits | ZTS012 | Write the digits |
| `0b101` and `0o17` - a binary or octal literal | ZTS012 | A decimal or `0x` literal |
| `.5` - a number with no digit before the point | ZTS012 | `0.5` |
| `1e`, `1e+` with no exponent digits | ZTS012 | Write the exponent |
| `0755` - a legacy octal literal | ZTS012 | Drop the leading zero for decimal, or write a `0x` literal |
| A character above ASCII outside a string or comment | ZTS046 | The message names the first character by code point. The span covers that character alone. Suggestions give an ASCII replacement for recognized lookalikes. Invalid UTF-8 is reported as the byte. |
| A statement with no `;` | ZTS047 | Write the terminator; this profile has no automatic semicolon insertion |

The last one is a statement-termination rule rather than a lexical one. It has
no mechanical repair today: the one that shipped was withdrawn after a review
found it writing semicolons onto the wrong line and into trailing comments.

## Declaration Rules

| Form | Code | Write instead |
|---|---|---|
| A brand over a record, tuple, union, or function | ZTS048 | Use `Nominal` over `string`, `number`, or `boolean`. Use a transparent `type` alias for other shapes |
| `interface X { ... }` | ZTS049 | `type X = { ... };` |
| A legacy `structural` declaration | ZTS001 | `type X = ...;` |
| A legacy `nominal` declaration or `distinct type X = string;` | ZTS001 or ZTS051 | Declare a unique-symbol brand and use `Nominal<string, typeof brand>` from `zttp:core` |

Run `zts normalize handler.ts` to preview supported legacy migrations.

## Top-Level And Binding Rules

| Form | Code | What it does instead |
|---|---|---|
| A top-level statement other than a bare registration call with literal arguments, such as `f();` and `if (c) { f(); }` | ZTS074 | Move the statement into a function. A bare `schemaCompile(...)` or `sql(...)` call with literal arguments stays |
| A top-level initializer with an effect: a clock, random, or `env` read, a call of an import that declares an effect, a write to module state, or a call of a function whose body the module cannot read | ZTS630 | Compute the value inside a function. Write a registration as a bare statement, not bound to a `const` |
| A top-level initializer that reaches a module declaration at or after it | ZTS630 | Declare the name above the initializer. A function body may name a later declaration, so mutual recursion stays |
| A top-level initializer that passes a function to a call, such as `xs.map((x: number): number => x * 2)` | ZTS630 | Compute the value inside a function. Module initialization does not run a callback |
| An arrow outside a direct call argument: bound, exported, returned, in a record field, immediately called, or a `?:` arm | ZTS072 | A module-level `function`. Pass an arrow only as a direct call argument |
| A function declaration inside a function body or a block | ZTS071 | A module-level function |
| An assignment to a parameter, such as `a = a + 1` | ZTS068 | Bind the new value to a new `const` |
| A declaration of a name that an enclosing or a nested scope, or the module scope, already declares | ZTS069 | A different name. Two sibling blocks may declare one name |
| A `type` declaration that reuses an ambient or imported type name, such as `type Request = number;` | ZTS019 | A different name |

## Operator And Builtin Rules

| Form | Code | What it does instead |
|---|---|---|
| Bitwise operators `&`, `\|`, `^`, `~`, `<<`, `>>`, `>>>` | ZTS001 | The profile has no bit operations. Use arithmetic or a comparison |
| The `**` operator | ZTS001 | `Math.pow(a, b)` |
| `Boolean(x)` | ZTS600, ZTS629 | A comparison, such as `x !== ""` or `n > 0` |
| `Number(x)` with an argument that is not a `string`, and any builtin argument whose type the builtin parameter does not admit, such as `Math.pow(true, 2)` | ZTS203 | Pass the parameter type. `Number(text)` stays the one strict text-to-number parse |
| `Headers` | ZTS629 | Read request headers through `req.headers` |
| `substring`, array `concat`, and `Number.parseInt` or `Number.parseFloat` | ZTS201 | `slice`, spread `[...a, ...b]`, and the globals `parseInt` and `parseFloat` |
| An `Object` member other than `keys`, `values`, and `entries`, such as `Object.fromEntries` | ZTS201 | `Object.keys`, `Object.values`, `Object.entries`, or object spread |
| `Partial<T>`, `Required<T>`, `Pick<T, K>`, `Omit<T, K>`, and `Readonly<T>` | ZTS065 | An explicit `type` declaration and the `readonly` modifier |
| `for...of` over a record, a number, a string, or a `Dict` | ZTS218 | `Object.keys(r)`, `range(n)`, `s.split("")`, or `dictEntries(d)` |
| `FetchOptions` with no import | ZTS065 | `import type { FetchOptions } from "zttp:fetch";` |

## Match Rules

Import `match` from `zttp:core`. The compiler tests each `.with(pattern, callback)`
in order. End a complete chain with `.exhaustive()`, or handle
remaining values with `.otherwise(callback)`.

| Form | Code | Write instead |
|---|---|---|
| A legacy brace match | ZTS001 | The imported `match` call and its fluent arms |
| A legacy `default` arm before a `when` arm, or a second `default` arm | ZTS062 | One `.otherwise(callback)` terminal |
| A nested type test such as `{ v: P.string }` | ZTS001 | Match that field separately with a subject-level descriptor |
| An `.otherwise()` after full coverage or an unreachable `.with()` | ZTS216 | Remove the unreachable branch |
| Incomplete coverage with `.exhaustive()` | ZTS603 | Add the missing arms or use `.otherwise(callback)` |

## Supported Module Syntax

The parser supports ES6 `import`/`export` syntax for built-in virtual modules
(`zttp:*`) and registered extension modules (`zttp-ext:*`). `Proof<T, P>` and
`Effects<T, R>` are ambient type names and require no module import.

### Supported Import Forms

| Syntax | Description |
|--------|-------------|
| `import { x } from "zttp:env"` | Named import (single) |
| `import { x, y, z } from "zttp:crypto"` | Named import (multiple) |
| `import { x as alias } from "zttp:env"` | Named import with alias |
| `import { parseBearer, jwtVerify } from "zttp:auth"` | Auth module imports |
| `import { schemaCompile, validateJson } from "zttp:validate"` | Validation module imports |
| `import { decodeJson, decodeForm } from "zttp:decode"` | Typed ingress module imports |
| `import { cacheGet, cacheSet } from "zttp:cache"` | Cache module imports |
| `import { charge } from "zttp-ext:stripe"` | Registered extension imports |

### Supported Export Forms

| Syntax | Description |
|--------|-------------|
| `export function handler(req) {}` | Named function export |
| `export const version = "1.0"` | Named const export |

### Unsupported Module Forms

These produce helpful error messages directing users to named imports/exports:

| Syntax | Error Message |
|--------|---------------|
| `import X from "mod"` | Default imports not supported; use named imports |
| `import * as X from "mod"` | Namespace imports not supported; use named imports |
| `import "mod"` | Side-effect imports not supported; use named imports |
| `export default function handler() {}` | ZTS056: write a named export such as `export function handler() {}` |
| `export let count = 0` | ZTS057: use `export const`; keep reassignment inside a function activation |
| `export { x } from "mod"` | Re-exports not supported; use named exports |
| `export * from "mod"` | Export star not supported; use named exports |

## Parser Features (54 total)

These are JavaScript and TypeScript language features that are syntactically valid but unsupported in zttp's runtime. All are detected during parsing with helpful error messages following the pattern: "'feature' is not supported; use X instead".

### TypeScript Features (detected by parser)

The parser owns these diagnostics so every `.ts` core input gets the same error
messages.

| Feature | Suggested Alternative |
|---------|----------------------|
| `enum` / `const enum` | Use object literals or discriminated unions |
| `namespace` / `module` | Use ES6 modules |
| `implements` keyword | Use duck typing or runtime checks |
| `@decorator` syntax | Use function composition |
| Access modifiers (`public`, `private`, `protected`) | Use naming conventions (e.g., `_private`) |

### Loop Constructs

| Feature | Suggested Alternative |
|---------|----------------------|
| `while` loops | Use `for-of` with a finite collection |
| `do-while` loops | Use `for-of` with a finite collection |
| `for-in` loops | Use `for-of` to iterate over values |
| C-style `for` loops (init; cond; update) | Use `for (let x of array)` or `for (let i of range(n))` |

### Loop Control Flow

| Feature | Status |
|---------|--------|
| `break` in `for-of` | Supported |
| `continue` in `for-of` | Supported |
| `break` outside loop | Error: "'break' outside of loop" |
| `continue` outside loop | Error: "'continue' outside of loop" |
| Labeled `break`/`continue` | Error: use a conditional instead |

### Error Handling

| Feature | Suggested Alternative |
|---------|----------------------|
| `throw` statement | Use Result types for error handling |
| `try/catch/finally` | Use Result types for error handling |

### Control Flow Statements

| Feature | Suggested Alternative |
|---------|----------------------|
| `switch/case/break` | Use `match` expression instead |

### Classes and OOP

| Feature | Suggested Alternative |
|---------|----------------------|
| `class` declarations (statement context) | Use plain objects and functions |
| `class` expressions (expression context) | Use plain objects and functions |
| `this` keyword | Pass context explicitly as a parameter |
| `super` keyword | Use explicit function calls |
| `new` operator | Use factory functions |

### Variable Declarations

| Feature | Suggested Alternative |
|---------|----------------------|
| `var` keyword (statement context) | Use `let` or `const` |
| `var` keyword (for-loop context) | Use `let` or `const` |

### Equality Operators

| Feature | Suggested Alternative |
|---------|----------------------|
| `==` (loose equality) | Use `===` for strict equality |
| `!=` (loose inequality) | Use `!==` for strict inequality |

### Unary Increment/Decrement

| Feature | Suggested Alternative |
|---------|----------------------|
| `++x` (prefix increment) | Use `x = x + 1` |
| `--x` (prefix decrement) | Use `x = x - 1` |

### Postfix Increment/Decrement

| Feature | Suggested Alternative |
|---------|----------------------|
| `x++` (postfix increment) | Use `x = x + 1` |
| `x--` (postfix decrement) | Use `x = x - 1` |

### Compound Assignment Operators (12 total)

The parser accepts arithmetic and bitwise compound assignments and desugars them to `x = x [op] value`:

`+=`, `-=`, `*=`, `/=`, `%=`, `**=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, `>>>=`

**Canonical profile note:** all twelve emit `ZTS613 canonical_compound_assignment` and must be rewritten to the explicit form `x = x + e`, so a file using any of them fails `zttp check`. See [Canonicalize And Normalize](cli.md#canonicalize-and-normalize) for the full canonical ruleset.

### Unsupported Logical Compound Assignments (3 total)

Logical compound assignments require short-circuit semantics and are not supported:

| Feature | Suggested Alternative |
|---------|----------------------|
| `&&=` | `x = x && value` |
| `\|\|=` | `x = x \|\| value` |
| `??=` | `x = x ?? value` |

### Type-checking Operator

| Feature | Suggested Alternative |
|---------|----------------------|
| `instanceof` | Use discriminated unions with tag property |

### Expression-level Features

| Feature | Suggested Alternative |
|---------|----------------------|
| Regular expressions `/.../ ` | Use string methods |
| Function expressions (named & anonymous) | Use a module-level function declaration, or an arrow as a direct call argument such as `xs.map((x: number): number => x * 2)` |
| `yield` expressions | Generators are not available |
| `delete` operator | Use object spread to omit properties |
| Template interpolation `` `n=${n}` `` | Build a string array with explicit `String(...)` conversions and call `.join("")`. A backtick literal with no interpolation is fine |
| `\|>`, `pipe()`, `guard()` | Write the call directly, as `f(a)` for `a \|> f`; run guards by explicit early return |

### Statement Forms

| Feature | Suggested Alternative |
|---------|----------------------|
| `debugger;` | Remove the statement |
| Empty statement `;` | Remove the standalone semicolon |
| Bare block statement `{ ... }` | Put its statements in the enclosing block |
| Empty body of `if`, `else`, or `for...of`, such as `if (c) {}` | Remove the statement, or invert the condition and drop the empty branch |
| A body that is not a block, such as `if (c) g();` (ZTS070) | Write the body as a block: `if (c) { g(); }` |
| `when _:` catch-all | Write `default:` |

### Global Identifiers

| Feature | Suggested Alternative |
|---------|----------------------|
| `Promise` (as unbound global) | Use Result types or callbacks |
| `RegExp` (as unbound global) | Use string methods |
| `eval` (as unbound global) | Call a named function |
| `Proxy` (as unbound global) | Use plain objects and explicit functions |
| `Reflect` (as unbound global) | Access properties directly |

### Object Literal Forms

| Feature | Suggested Alternative |
|---------|----------------------|
| Shorthand `{ value }` | Name both key and value: `{ value: value }` |
| Object method `{ go() { ... } }` | Write a module-level function |
| Getter `{ get x() { ... } }` | Call an explicit function |
| Setter `{ set x(v) { ... } }` | Call an explicit function |
| Numeric key `{ 1: "a" }` | Use a string key, or an array when the keys are dense indices |

### Object Built-in Methods

| Feature | Suggested Alternative |
|---------|----------------------|
| `Object.assign()` | Use object spread `{...obj1, ...obj2}` |
| `Object.freeze()` | Objects are mutable by design |
| `Object.isFrozen()` | Objects are mutable by design |

## Canonical Profile (Strict Checker)

The strict checker enforces the **canonical ZigTS profile** on every `zttp check` and `zttp verify-paths` run. These rules tighten the language further, removing redundant idioms that compete with an already-canonical form. The goal is one canonical spelling per operation.

| Code | Rule | Canonical replacement |
|------|------|----------------------|
| `ZTS612` | effectful arm in `a ? b : c` | bind the effectful call first, or use `match` over the condition |
| `ZTS621` | conditional nested in a conditional arm | `match` over one scrutinee, or an if/else chain |
| `ZTS613` | compound assignment (`+=`, `-=`, ...) | `x = x + e` |
| `ZTS614` | non-leading object spread `{x: 1, ...base}` | leading spread: `{...base, x: 1}` |
| `ZTS616` | call-site spread `f(...args)` | positional args or widen the helper signature |
| `ZTS054` | default parameter | use `T | undefined` and resolve the default at the start of the body |
| `ZTS055` | optional parameter shorthand | write the parameter type as `T | undefined` |
| `ZTS056` | default export | write a statically named export |
| `ZTS057` | mutable top-level export | use `export const`; keep reassignment activation-local |
| `ZTS058` | `Array<T>` type spelling | write `T[]` |
| `ZTS059` | `ReadonlyArray<T>` type spelling | write `readonly T[]` |
| `ZTS060` | `void` type spelling | write `undefined` |
| `ZTS061` | raw built-in type in an exported parameter or return | declare a scalar brand or transparent alias and name it in the signature |
| `ZTS620` | boolean compared to a boolean literal (`x === true`) | use the boolean directly: `x` (or `!x` for `=== false`) |
| `ZTS622` | the iterated collection is mutated in the loop body (`for (const x of xs) { xs.push(x); }`) | iterate a snapshot: read one collection, build the mutated one separately |

The full reference lives at [Canonicalize And Normalize](cli.md#canonicalize-and-normalize).

Declaration destructuring, including renamed bindings, is outside the core
profile. Bind the source to one name and read fields or indexed elements with
explicit `const` declarations.

## Error Message Pattern

All error messages follow a consistent format:

```
"'<feature>' is not supported; use <alternative> instead"
```

Examples:
- `'class' is not supported; use plain objects and functions instead`
- `'while' loops are not supported; use 'for-of' with a finite collection instead`
- `'throw' is not supported; use Result types for error handling instead`
- `'enum' is not supported; use object literals or discriminated unions instead`

## Adding New Unsupported Features

When adding detection for a new unsupported feature:

1. **Determine Layer**:
   - TypeScript type-position-only syntax (e.g., `any` type) -> Parser type-syntax admission
   - Everything else (JS features, TS keywords that exist as statements) -> Parser

2. **Add Detection Code**:
   - Follow existing error reporting pattern for that layer
   - Include helpful alternative in error message
   - Preserve source location for accurate error reporting

3. **Add Tests**:
   - Add a parser test in `packages/zts/src/parser/parse.zig` or beside the affected type-syntax code.
   - Verify error message content, not just error type

4. **Update This Document**:
   - Add row to appropriate table
   - Update count if adding to parser features

5. **Run Tests**:
   - `zig build test` should pass
   - Manually verify error message quality with test input

## Design Rationale

### Why Two Layers?

**Parser**: Checks TypeScript syntax in annotations, including `any`, and
rejects unsupported statements such as `enum`, `namespace`, and `class`.

**Strict checker**: Applies profile and type-directed rules after parsing,
including implicit globals, avoidable `let`, and invalid uses of a parsed type.

### Why Not Runtime Detection?

Fail-fast at parse time provides:
- Immediate feedback to developers
- Prevents invalid bytecode generation
- Clearer error messages with source context
- No runtime performance overhead

Runtime checks should only exist as defensive programming (e.g., `UnimplementedOpcode`), not primary feature detection.

### Why Move Detection to the Parser?

The parser diagnoses unsupported forms such as `class` and `enum` in accepted
`.ts` input. File extension admission rejects `.js`, `.jsx`, and `.tsx` with
ZTS052 before parsing.

The parser also checks `any` types and `as`/`satisfies` assertions in the original source.

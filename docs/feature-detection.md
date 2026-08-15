# Feature Detection Matrix

This document catalogs all unsupported JavaScript and TypeScript features detected by zttp's fail-fast validation system, organized by detection layer.

## Detection Architecture

zttp validates in three layers:

1. **TypeScript Stripper** (`packages/zts/src/stripper.zig`): Runs first for .ts/.tsx files, catches TypeScript-specific syntax that only exists in type positions
2. **Parser** (`packages/zts/src/parser/parse.zig`): Runs for all files (after stripping for TS), catches unsupported JavaScript and TypeScript features
3. **Strict checker** (`packages/zts/src/strict_checker.zig`): Runs after parsing on `zttp check` and `zttp verify-paths`, and enforces the [canonical profile](#canonical-profile-strict-checker)

**Principle**: Each feature should be detected at exactly one layer to avoid duplicate error reporting and ensure consistent error messages regardless of file type.

## TypeScript Stripper Features

These features exist only in TypeScript type annotation positions that are stripped before parsing. The parser never sees them.

| Feature | Error Type | Suggested Alternative |
|---------|------------|----------------------|
| `any` type (all positions: annotations, assertions, nested) | UnsupportedAnyType | Use specific types (string, number, object) or union types |
| `as` type assertion (e.g., `x as string`) | UnsupportedAssertion | Use explicit type narrowing with typeof guards or undefined checks |
| `satisfies` operator (e.g., `x satisfies T`) | UnsupportedAssertion | Use explicit type annotations on declarations |
| A string literal that reaches the end of its line | UnterminatedString | Close the quote, or write the newline as `\n` |

The stripper runs before the parser, so it is what meets an unterminated string
first. It reports one as ZTS008 with a line and a column - the same code the
parser uses for the same fault.

## Lexical Rules

The escape set, the numeric forms, and the identifier character set are closed.
Each of these was accepted silently before and is now refused with a location.

| Form | Code | What it does instead |
|---|---|---|
| `"a\qb"` - an escape outside the closed set | ZTS013 | The set is `\n \r \t \b \f \v \0 \\ \' \" \` \$ \xNN \uNNNN \u{N..}`, in quoted strings and template literals alike |
| A backslash before a real newline | ZTS045 | Join the lines, or write the newline as `\n` |
| `0x`, `0b`, `0o` with no digits | ZTS012 | Write the digits |
| `1e`, `1e+` with no exponent digits | ZTS012 | Write the exponent |
| `0755` - a legacy octal literal | ZTS012 | `0o755` for octal, or drop the leading zero for decimal |
| A byte above ASCII inside an identifier | ZTS046 | Identifiers are letters, digits, `_` and `$`. Not reported inside a JSX file, where text content reaches the same code path |
| A statement with no `;` | ZTS047 | Write the terminator; this profile has no automatic semicolon insertion |

The last one is a statement-termination rule rather than a lexical one. It has
no mechanical repair today: the one that shipped was withdrawn after a review
found it writing semicolons onto the wrong line and into trailing comments.

## Declaration Rules

| Form | Code | What it does instead |
|---|---|---|
| `nominal Bad = { a: number };` - a nominal base that is not scalar | ZTS048 | A nominal declaration carries scalar identity only, so its base is `string` or `number`. Use `structural` for a record, a tuple, a union, or a function |
| `interface X { ... }` | ZTS049 | Write `structural X = { ... };`. The `export` form is refused the same way |
| `type X = ...;` | ZTS050 | Write `structural X = ...;`. `import type` and `export type { ... }` keep the keyword |
| `distinct type X = string;` | ZTS051 | Write `nominal X = string;` |

The published grammar has always said `ScalarType` at that position; until this
rule existed nothing enforced it, and a nominal type over a record checked
clean. The rule ran on the older `distinct type` spelling too, which shared the
path. That spelling is refused outright now, so its base is no longer reached:
one line gets one diagnostic, and it is the one naming the repair.

`interface` is recognized rather than merely rejected: the body is scanned so
the span is known and the repair is exact, and no type-map entry is recorded,
so nothing downstream resolves it. Open interfaces, `extends`, merging, and
declaration augmentation were never supported and are not repaired into an
alias. The heuristic that made an all-function interface nominal went with the
form - nominal identity now comes only from a `nominal` declaration.

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
| `import { run, step } from "zttp:durable"` | Durable execution imports |
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

### Supported Compound Assignment Operators (12 total)

Arithmetic and bitwise compound assignments are supported and desugar to `x = x [op] value`:

`+=`, `-=`, `*=`, `/=`, `%=`, `**=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, `>>>=`

**Canonical profile note:** the arithmetic compound assignments (`+=`, `-=`, `*=`, `/=`, `%=`, `**=`) emit `ZTS613 canonical_compound_assignment` and must be rewritten to the explicit form `x = x + e`. See [Canonicalize And Normalize](cli.md#canonicalize-and-normalize) for the full canonical ruleset.

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
| Function expressions (named & anonymous) | Use arrow functions `(x) => x * 2` or function declarations |
| `yield` expressions | Generators are not available |
| `delete` operator | Use object spread to omit properties |

### Statement Forms

| Feature | Suggested Alternative |
|---------|----------------------|
| `debugger;` | Remove the statement |
| Empty statement `;` | Remove the standalone semicolon |
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
| Object method `{ go() { ... } }` | Hold an arrow function in the property: `{ go: () => ... }` |
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
| `ZTS615` | complex template interpolation `${getX()}` | hoist into a `const` above the template |
| `ZTS616` | call-site spread `f(...args)` | positional args or widen the helper signature |
| `ZTS054` | default parameter | use `T | undefined` and resolve the default at the start of the body |
| `ZTS055` | optional parameter shorthand | write the parameter type as `T | undefined` |
| `ZTS056` | default export | write a statically named export |
| `ZTS057` | mutable top-level export | use `export const`; keep reassignment activation-local |
| `ZTS058` | `Array<T>` type spelling | write `T[]` |
| `ZTS059` | `ReadonlyArray<T>` type spelling | write `readonly T[]` |
| `ZTS060` | `void` type spelling | write `undefined` |
| `ZTS620` | boolean compared to a boolean literal (`x === true`) | use the boolean directly: `x` (or `!x` for `=== false`) |
| `ZTS622` | the iterated collection is mutated in the loop body (`for (const x of xs) { xs.push(x); }`) | iterate a snapshot: read one collection, build the mutated one separately |

The full reference lives at [Canonicalize And Normalize](cli.md#canonicalize-and-normalize).

Declaration destructuring, including renamed bindings, is outside the core
profile. Bind the source to one name and read fields or indexed elements with
explicit `const` declarations.

## Workflow Proof Guardrails

These diagnostics are not JavaScript feature cuts. They reject workflow shapes
that would otherwise look durable while losing a runtime guarantee.

| Code | Rule | Supported shape |
|------|------|-----------------|
| `ZTS509` | `workflow.call`, `saga`, `fanout`, or `follow` inside a `durable.step()` callback | move the workflow call to durable depth 0 inside `durable.run()` |

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
   - TypeScript type-position-only syntax (e.g., `any` type) -> Stripper
   - Everything else (JS features, TS keywords that exist as statements) -> Parser

2. **Add Detection Code**:
   - Follow existing error reporting pattern for that layer
   - Include helpful alternative in error message
   - Preserve source location for accurate error reporting

3. **Add Tests**:
   - Stripper: Add test in `packages/zts/src/stripper.zig` test section
   - Parser: Add test in `packages/zts/src/parser/parse.zig` test section
   - Verify error message content, not just error type

4. **Update This Document**:
   - Add row to appropriate table
   - Update count if adding to parser features

5. **Run Tests**:
   - `zig build test` should pass
   - Manually verify error message quality with test input

## Design Rationale

### Why Two Layers?

**TypeScript Stripper**: Handles TypeScript syntax that exists only in type annotation positions (e.g., `any` type). These are stripped before parsing, so the parser never sees them.

**Parser**: Handles all other feature detection - both ECMAScript-derived forms and TypeScript keywords that appear as statements (enum, namespace, implements, decorators, access modifiers). Running detection in the parser gives every `.ts` core input the same rich diagnostic.

### Why Not Runtime Detection?

Fail-fast at parse time provides:
- Immediate feedback to developers
- Prevents invalid bytecode generation
- Clearer error messages with source context
- No runtime performance overhead

Runtime checks should only exist as defensive programming (e.g., `UnimplementedOpcode`), not primary feature detection.

### Why Move Detection to the Parser?

Before consolidation, features like `class` and `enum` were split between the stripper and parser. Moving all keyword-level detection to the parser gives accepted `.ts` inputs one diagnostic path with source context and underlines. `.js` and `.jsx` are rejected earlier at the source-frontend boundary with ZTS052.

The features remaining in the stripper are `any` type detection (because `any` only appears in type annotation positions that are stripped before the parser runs) and `as`/`satisfies` assertion rejection (because these are type-position syntax that the parser never sees).

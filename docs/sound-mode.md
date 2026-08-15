# Sound Mode: Type-Directed Analysis

zttp's sound mode uses compile-time type inference to catch bugs across all
operators. The compiler enforces boolean-only control flow, arithmetic type
safety, and tautological comparison detection.

## Boolean-Only Control Flow

Conditions in `if`, `assert`, and `?:` must have type `boolean`. The operands
of `!`, `&&`, and `||` must also be boolean, as must predicate callback results
for array and dictionary operations. There is no general truthiness conversion.

| Value type | In a boolean context | Write instead |
|---|---|---|
| `boolean` | accepted | the value itself |
| optional value | rejected | compare with `undefined` |
| `number` | rejected | compare with `0` |
| `string` | rejected | compare with `""` |
| `undefined` | rejected | remove the dead condition |
| `object` | rejected | test a boolean field or explicit property condition |
| `function` | rejected | call it and use a boolean result |
| `unknown` | rejected | narrow or validate it first |

## What Works

### Optional existence checks

Every `env()`, `cacheGet()`, `parseBearer()`, and `routerMatch()` call returns
an optional type. Compare the result with `undefined`:

```javascript
import { env } from "zttp:env";
import { parseBearer } from "zttp:auth";
import { routerMatch } from "zttp:router";

const token = parseBearer(auth);
if (token !== undefined) { use(token); }

const match = routerMatch(routes, req);
if (match !== undefined) {
    req.params = match.params;
    return match.handler(req);
}

const secret = env("SECRET");
if (secret === undefined) {
    return Response.json({ error: "missing secret" }, { status: 500 });
}
// secret is string here after the early return
```

### Number and string conditions

```javascript
if (count !== 0) { ... }
if (name !== "") { ... }
if (count === 0) { ... }
```

### Logical operators

`&&` and `||` combine boolean operands and produce a boolean.

```javascript
if (count !== 0 && name !== "") { ... }
const val = x ?? fallback;         // use ?? for value defaults (unchanged)
```

### Result discriminants

```javascript
const parsed = validateJson("input", body);
if (!parsed.ok) { return error; }
// parsed.ok is boolean, and parsed.value is available after the guard
```

## What Is Rejected

### Non-boolean values

```javascript
if ({}) { ... }                    // ERROR: object is not boolean
if (result) { ... }                // ERROR: record is not boolean
if (() => true) { ... }            // ERROR: function is not boolean
if (undefined) { ... }             // ERROR: undefined is not boolean
if (count) { ... }                 // ERROR: number is not boolean
```

## Narrowing

Optional narrowing requires an explicit `=== undefined` or `!== undefined`
comparison. Narrowing applies in `if` and `?:` branches, after an early-return
guard, and to the right side of an admitted boolean `&&` or `||` test. `typeof`,
literal discriminants, and validated type predicates keep their specified
narrowing behavior.

```javascript
import { env } from "zttp:env";

const val = env("KEY");            // optional_string
if (val !== undefined) {
    // val is string here
    const upper = val;
}
// val reverts to optional_string here
```

## Nullish coalescing ?? warnings

When the left side of `??` is provably non-nullable, a warning is emitted:

```javascript
42 ?? 0                            // WARNING: LHS is never undefined
env("KEY") ?? "default"            // No warning: env() is optional
```

## == and != are globally banned

The parser rejects `==` and `!=` with a helpful error message suggesting `===` and `!==`.

## Unknown Values Fail Closed

An `unknown` value cannot enter a boolean context. Narrow it with an admitted
type test or validate it before branching. Unchecked bytecode and native
predicate callbacks face the same rule at runtime.

## Type Inference Rules

| Expression | Inferred Type |
|---|---|
| `true`, `false` | boolean |
| `42`, `3.14` | number |
| `"hello"`, `` `template` `` | string |
| `undefined` | undefined |
| `{}`, `[]` | object |
| `() => ...`, `function() {}` | function |
| `===`, `!==`, `<`, `>`, `<=`, `>=`, `in` | boolean |
| `A && B`, `A \|\| B` | boolean |
| non-nullable `A ?? B` | `A` |
| `(T \| undefined) ?? B` | `T \| B` |
| `undefined ?? B` | `B` |
| `+` (string + any) | string |
| `+` (number + number) | number |
| `-`, `*`, `/`, `%`, `**` | number |
| `&`, `\|`, `^`, `<<`, `>>`, `>>>` | number |
| `!` | boolean |
| `-x`, `+x`, `~x` | number |
| `typeof` | string |
| `void` | undefined |
| `const x = expr; ... x` | same as expr |
| reassigned `let x = expr; ... x` | same as expr until reassignment invalidates it |
| `cond ? a : b` | unified type of a and b |
| `match (...) { ... }` | unified arm type (if compatible) |
| `const f = (x) => x > 0; f(1)` | return type of f (boolean) |
| imported virtual-module call | known return type when modeled |
| optional virtual-module return | optional string/object |
| Result property access (`result.ok`) | known property type when modeled |
| Generic alias application (`Result<string>`) | instantiated record type |
| `x !== undefined` where x is optional | narrows to non-optional on the true branch |
| `typeof x === "T"` guard (then-branch) | T (narrowed) |
| `typeof x !== "T"` guard (else-branch) | T (narrowed) |

## Type-Directed Arithmetic Safety

Arithmetic operators (`-`, `*`, `/`, `%`, `**`) require numeric operands. When the compiler can prove an operand is non-numeric, it emits a compile-time error.

### What is rejected

```javascript
"hello" - 1                        // ERROR: 'string' operand in '-'; arithmetic requires numbers
true * 5                           // ERROR: 'boolean' operand in '*'; use (b ? 1 : 0)
undefined / 2                     // ERROR: 'undefined' operand in '/'; result is always NaN
env("TTL") * 1000                 // ERROR: 'optional string' operand in '*'; unwrap with ?? first
{} - 1                            // ERROR: 'object' operand in '-'; objects cannot be used in arithmetic
```

### What works

```javascript
5 - 3                              // OK: number - number
count * 2                          // OK: tracked const number
cacheIncr("ns", "key") * 2        // OK: cacheIncr returns number
parseInt(env("TTL") ?? "60") * 1000  // OK: parseInt returns number, ?? unwraps optional
unknownParam - 1                   // OK: unknown defers to runtime
```

## Type-Directed `+` Safety

The `+` operator accepts `number + number` (addition) and `string + string` (concatenation). Mixing types is an error - use template literals for string interpolation.

### What is rejected

```javascript
42 + "px"                          // ERROR: implicit type coercion; number and string operands
"count: " + 5                     // ERROR: use template literal: `count: ${n}`
true + 1                          // ERROR: 'boolean' operand in '+'
env("X") + "suffix"               // ERROR: 'optional string' operand in '+'
```

### What works

```javascript
1 + 2                              // OK: number + number
"a" + "b"                         // OK: string + string
`count: ${n}`                     // OK: template literal handles conversion
(env("X") ?? "") + "suffix"       // OK: ?? unwraps optional to string
x + 1                             // OK: unknown defers to runtime
```

## Tautological Comparison Detection

The compiler warns when a comparison is always true or always false based on known types.

### typeof tautologies

```javascript
const x = 42;
typeof x === "number"              // WARNING: always true; typeof check unnecessary
typeof x === "string"              // WARNING: always false; this branch is dead code
typeof x !== "number"              // WARNING: always false
```

### undefined tautologies

```javascript
const x = 42;
x === undefined                    // WARNING: always false; value is never undefined
sha256("data") !== undefined       // WARNING: always true; remove the check
env("KEY") === undefined           // No warning: env() returns optional
```

## Diagnostic Reference

**Errors (block compilation):**
- `boolean context requires a value of type boolean` - compare or narrow the value explicitly
- `'<type>' operand in '<op>' operator; arithmetic requires numbers` - non-numeric value in arithmetic
- `implicit type coercion in '+'; number and string operands` - mixed types in addition
- `'<type>' operand in '+' operator` - non-addable type in addition

**Warnings (do not block compilation):**
- `left side of '??' is never undefined` - remove the '??' fallback; it is unreachable
- `tautological typeof comparison: result is always true/false` - typeof check on known type
- `comparison with undefined is always true/false` - undefined check on non-optional value

## Type-Directed Codegen

When the compiler can prove both operands of a binary operation are numbers (or both are strings for `+`), it emits specialized opcodes that skip runtime type dispatch.

| Generic opcode | Specialized opcode | Difference |
|---|---|---|
| `add` | `add_num` | skips string concatenation check |
| `sub` | `sub_num` | skips type coercion slow path |
| `mul` | `mul_num` | skips type coercion slow path |
| `div` | `div_num` | skips type coercion slow path |
| `lt` | `lt_num` | skips general comparison path |
| `gt` | `gt_num` | skips general comparison path |
| `lte` | `lte_num` | skips general comparison path |
| `gte` | `gte_num` | skips general comparison path |
| `add` (string) | `concat_2` | direct string concatenation |

Type-directed codegen is active only in precompiled handlers (`-Dhandler=...`). Dev mode (`zig build run`) uses generic opcodes because the BoolChecker's type annotations are not wired to the dev-mode CodeGen path.

## Runtime Enforcement

The VM applies the boolean-only contract at the conditional jump and logical
NOT opcodes. Array predicates and `dictFilter` apply it at their callback
boundary. Any non-boolean value raises a type error such as
`boolean context requires boolean, got number`. This prevents unchecked
bytecode or native callbacks from recovering JavaScript truthiness behind the
compiler.

# TypeScript Support

zttp includes native TypeScript and TSX support through two features: a type stripper that removes type annotations at load time, and a compile-time evaluator for the `comptime()` function.

Strict ZigTS is the default profile. Named functions must carry explicit
parameter and return annotations, `any` is rejected, capability access
must use compiler-visible literal keys, dynamic computed property access
is rejected unless the key is a literal or const literal alias, and a
`let` binding is only allowed when the binding is actually reassigned.

[TypeScript Patterns In The zts Subset](#typescript-patterns-in-the-zts-subset)
below maps the common TypeScript-tips canon onto this subset.

---

## Type Stripper

The type stripper (`packages/zts/src/stripper.zig`) removes TypeScript syntax before parsing, preserving line/column positions for error reporting by replacing stripped spans with spaces.

### Supported Subset

**Type declarations** (stripped entirely):
- `structural` aliases (including ADT unions)
- `nominal` declarations (nominal/branded types)
- `export structural ...` / `export nominal ...` / `import type ...`

**Type annotations** (stripped in place):
- Variable annotations: `const x: T = ...` or reassigned `let x: T = ...`
- Parameter annotations: `function f(x: T) { ... }`
- Return annotations: `function f(): T { ... }`

**Assertions** (stripped):
- `as` assertions: `value as T`
- `satisfies` assertions: `value satisfies T`

**Basic generics** (stripped):
- Generic params on an alias: `structural Box<T> = ...`
- Generic params on functions: `function id<T>(x: T): T { ... }`
- Generic arrow functions in .ts files: `const id = <T>(x: T): T => x;`

**Generic type aliases** (stripped and type-checked):

Generic type aliases like `type Result<T> = { ok: boolean; value: T }` are stripped at load time and resolved by the type checker. When the alias is used in an annotation (`const x: Result<string>`), the type checker instantiates the body by substituting the type parameters with the provided arguments, producing a concrete record type for structural checking.

```typescript
structural Result<T> = { ok: boolean; value: T; error: string };
structural Pair<A, B> = { first: A; second: B };

const auth: Result<object> = jwtVerify(token, secret);  // checked as { ok: boolean; value: object; error: string }
const pair: Pair<string, number> = { first: "a", second: 1 };
```

Up to 8 type parameters per alias are supported.

**Built-in `Spec<...>` for proof obligations:**

`zttp:types` exposes a built-in generic alias `Spec<S>` that lets the
author narrow which compiler-proven properties their handler must satisfy.
When no `Spec<...>` is present, every supported v1 spec is active by
default; when a `Spec<...>` is present, only the named specs are active.
It is structurally a phantom marker - stripped at runtime, read at
type-check time - and rides the same alias-resolution machinery as
`Result<T>`. Declare a named alias and intersect it on the handler's return
type:

```typescript
import type { Spec } from "zttp:types";

structural Guardrails = Spec<
    | "idempotent"
    | "deterministic"
    | "no_secret_leakage"
    | "injection_safe"
>;

function handler(req: Request): Response & Guardrails {
    return Response.json({ ok: true });
}
```

The verifier walks the return-type intersection, follows the alias to
the `Spec<...>` body, and emits ZTS500 / ZTS501 / ZTS502 diagnostics if
any active spec is not discharged, contradicts an import, or names a
property outside the v1 set. The proof HUD, proof ledger, and
`pi_specs_status` agent tool all read from this annotation.

**Helper capsules with `Proof<T, S>`:**

`Proof<T, S>` is the helper-level companion to `Spec<S>`. It annotates a
helper's return type, resolving to `T` for type checking while carrying
`S` as a proof obligation the compiler discharges against the helper's
own body:

```typescript
import type { Proof } from "zttp:types";

function fullName(u: User): Proof<string, "pure" | "total"> {
    return `${u.first} ${u.last}`;
}
```

The v1 capsule properties are `total` (every path returns a value),
`pure`, `read_only`, and `deterministic`. A helper that declares a
capsule it cannot satisfy fails with ZTS500; an unknown name fails with
ZTS502. Proven and trivially-clean helpers compose into the caller's
proof; an effectful helper with no capsule that breaks a property the
handler's `Spec<...>` demands fails with ZTS606.

**Capability capsules with `Effects<T, S>`:**

`Effects<T, S>` is the capability dual of `Proof<T, S>`. Where a proof
property is a guarantee the compiler discharges, an `Effects<...>`
annotation declares a *ceiling*: the function's inferred effect row may
be no wider than `S`. It resolves to `T` for type checking and carries
`S` - a union of capability names - as the ceiling:

```typescript
import type { Effects } from "zttp:types";

export function loadRegion(): Effects<string, "env"> {
    return env("REGION");
}
```

Placement is a decidable rule, not a style choice: an **exported** function
with a nonempty inferred row must declare a ceiling (ZTS610 when it does
not), and a **module-internal** function must not (ZTS623 when it does).
`loadRegion` is exported above, which is why it carries one. An internal
helper needs no ceiling because the compiler infers its row and the
handler's budget already bounds it.

The capability vocabulary is the runtime capability set: `env`, `clock`,
`random`, `crypto`, `stderr`, `runtime_callback`, `sqlite`,
`filesystem`, `network`, `policy_check`. The check is `inferred ⊆
declared`: a function that reaches a capability outside its ceiling
fails with ZTS503; an unknown capability name fails with ZTS504; a
declared capability the function never reaches is the warning ZTS505.

The same annotation on the handler's return type is a **budget** that
also bounds every helper the handler reaches. A capability the handler
reaches directly outside its budget fails with ZTS506; one a reachable
helper introduces fails with ZTS607, attributed to that helper:

```typescript
function handler(req: Request): Effects<Response, "env" | "clock"> {
    return Response.json({ region: loadRegion() });
}
```

Because the effect marker is distinct from the proof marker, the two
capsules compose - an exported helper can carry both:

```typescript
export function makeToken(u: User): Proof<Effects<string, "crypto">, "total"> {
    return sign(u.id);
}
```

`Effects<...>` declares an explicit contract; `Proof<...>` rides
inference. Both are checked only against facts inferred from real
function bodies - an annotation never substitutes for a proof.

**Docs mode (`--require-export-capsules`):**

`zts check --require-export-capsules` is an opt-in, warning-only mode
that asks every *exported* helper to carry an explicit `Proof<...>`
capsule (ZTS508). It is off by default, never touches non-exported
helpers, and never changes the exit code - it documents a package's
public API surface.

There is no `Effects<...>` counterpart in this mode. ZTS610 refuses an
exported helper with a nonempty inferred row unconditionally and as an
error, so a warning behind a flag would have covered the same helpers.

### Examples

```typescript
// Input
structural User = { id: number; name: string };
let u: User = { id: 1, name: "a" };
function add(a: number, b: number): number { return a + b; }
const x = (foo as number) + 1;

// After stripping
let u         = { id: 1, name: "a" };
function add(a         , b         )          { return a + b; }
const x = (foo          ) + 1;
```

### Unsupported TypeScript Features

These produce clear error messages at strip or parse time:

| Feature | Error Location | Suggested Alternative |
|---------|---------------|----------------------|
| `any` type | Stripper | Use specific types or union types |
| `enum` / `const enum` | Parser | Use object literals or discriminated unions |
| `namespace` / `module` | Parser | Use ES6 modules |
| `implements` | Parser | Use duck typing or runtime checks |
| `@decorator` syntax | Parser | Use function composition |
| Access modifiers (`public`, `private`, `protected`) | Parser | Use naming conventions |

### TSX Handling

`.tsx` selects the versioned `zts-tsx-1` frontend. It strips type annotations,
lowers elements, fragments, attributes, component references, text, and
expression children to ordinary `h(tag, props, ...children)` calls, and then
passes only core syntax to the parser. Its source map composes with the type
stripper map, so diagnostics still point into the authored `.tsx` file.

Angle-bracket type assertions (`<T>expr`) are disallowed in TSX to avoid JSX
ambiguity. `.jsx` is not an alternate frontend and is refused with ZTS052.

---

## Type Checking

The type checker (`packages/zts/src/type_checker.zig`) validates type annotations at build time. It runs after stripping and parsing, before bytecode generation.

### Checked Properties

- Variable declaration types match initializer types
- Function argument types match declared parameter types
- Return values match declared return types
- Property access on known record types (including `readonly` enforcement)
- Virtual module function signatures (argument count and types)
- Discriminated union narrowing in `match` expressions and `if` conditions
- Nominal type safety for `nominal` declarations
- Template literal type pattern matching
- Type guard narrowing (`x is T`) in `if` branches and `assert` statements

### Structural Matching

Object literals are structurally matched against declared alias types. A `{ message: string, count: number }` literal passes as a `ResponseData` alias if the fields match.

A record alias is transparent, whatever the keyword. Nominal identity comes only from a `nominal` declaration, and only over `string` or `number`. `interface` used to be the exception - one whose members were all functions became nominal by a heuristic no declaration expressed - and both the form and the heuristic are gone.

### Optional Narrowing

The type checker narrows nullable types through explicit absence checks.
Functions like `env()`, `cacheGet()`, and `parseBearer()` return optional values
(`T | undefined`). These guard patterns trigger narrowing:

```typescript
const val = env("KEY");

if (val !== undefined) {
    // val is string here (narrowed from string | undefined)
    sha256(val);
}

if (val === undefined) return Response.text("missing");
// val is string here (early return pattern)
```

### Discriminated Union Narrowing

Discriminated unions narrow through `if` conditions on tag fields:

```typescript
structural Result = { kind: "ok", value: string } | { kind: "err", error: string };

if (r.kind === "err") {
    return Response.json({ error: r.error }, { status: 400 });
}
// r is narrowed to { kind: "ok", value: string } from here
r.value.toUpperCase();
```

`match` handles exhaustive branching. `if` handles control flow with early returns. Different tools for different jobs.

### Type Guards and Assert

Type guard functions narrow in `if` branches. The `assert` statement installs permanent forward narrowing:

```typescript
function isString(x: unknown): x is string {
    return typeof x === "string";
}

if (isString(val)) {
    val.toUpperCase();   // narrowed in then-branch
}

assert isString(val);
val.toUpperCase();       // narrowed from here forward

assert isString(name), Response.json({ error: "name required" }, { status: 400 });
```

When `assert` fails with no error expression, the handler halts. With an explicit error expression, that value is returned.

### Nominal Types

`nominal` creates types that prevent accidental cross-assignment:

```typescript
nominal UserId = string;
nominal SessionId = string;

const uid: UserId = UserId("usr_123");     // constructor wraps the base type
const sid: SessionId = SessionId("sess");

function lookup(id: UserId): UserId {
    return id;
}
lookup(uid);    // OK
lookup(sid);    // ERROR: SessionId is not assignable to UserId
lookup("raw");  // ERROR: string is not assignable to UserId

uid.toUpperCase();  // operations unwrap to base type
```

The base must be `string` or `number`. A nominal declaration over a record, a
union, or a function is refused with ZTS048: nominal identity is scalar, and a
record that needs a name is a `structural` alias.

### Structural And Nominal

`structural` and `nominal` are the only declaration keywords. They replaced
`type` and `distinct type`, which are refused with ZTS050 and ZTS051 and carry
the exact repair. `import type` and `export type { ... }` keep the keyword:
each names a declaration made elsewhere rather than making one.

```typescript
structural Point = { x: number; y: number };
structural Boxed<T> = { value: T };

nominal OrderId = string;
nominal RetryCount = number;
```

The older spellings still work. They are removed when the profile cuts over,
and `interface` goes with them.

### Readonly Fields

The `readonly` modifier prevents assignment to record fields:

```typescript
structural Config = { readonly port: number; host: string };
const cfg: Config = { port: 3000, host: "localhost" };
cfg.host = "other";  // OK
cfg.port = 8080;     // ERROR: cannot assign to readonly property
```

`Readonly<T>` marks all fields readonly.

### Utility Types

The object-deriving utility types build a new record type from an existing one,
so a field stays declared in a single source type instead of being copied into
hand-written aliases that drift:

```typescript
structural User = { id: number; name: string; email: string };

structural Summary = Pick<User, "id" | "name">; // keep only id and name
structural Safe = Omit<User, "email">;          // drop email
structural UserPatch = Partial<User>;           // every field optional
structural FullUser = Required<UserPatch>;      // every field required again
```

`Pick<T, Keys>` and `Omit<T, Keys>` filter fields by a string-literal key (or a
union of them); `Partial<T>` makes every field optional and `Required<T>` makes
every field required. They resolve structurally against a named source type or
an inline object literal, alongside `Readonly<T>`.

### Template Literal Types

Template literal types validate string patterns at build time:

```typescript
structural ApiRoute = `/api/${string}`;
const good: ApiRoute = "/api/users";   // OK
const bad: ApiRoute = "/other";        // ERROR
```

### Literal Types and Annotation Semantics

`const` bindings preserve their literal type (`const x = 200` has type `200`). Use `let` only for bindings that are reassigned; strict ZigTS rejects an avoidable `let` with ZTS604.

When a `const` binding has a base primitive annotation, the compiler validates assignability but keeps the narrower literal type:

```typescript
const port: number = 3000;  // type is 3000, validated against number
const bad: number = "oops"; // ERROR: string not assignable to number
```

For union annotations, the declared type is preserved to support exhaustiveness checking in `match` expressions.

### Generic Type Aliases

Generic type aliases (`type Result<T> = { ok: boolean; value: T }`) are instantiated when used in annotations. `Result<string>` resolves to `{ ok: boolean; value: string }` for structural checking. Up to 8 type parameters per alias.

---

## Compile-Time Evaluation

The `comptime()` function (`packages/zts/src/comptime.zig`) evaluates expressions at compile time and replaces them with literal values. It integrates with the type stripper as a pre-parse transformation.

### Usage

```typescript
const x = comptime(1 + 2 * 3);                 // -> const x = 7;
const upper = comptime("hello".toUpperCase()); // -> const upper = "HELLO";
const etag = comptime(hash("content-v1"));     // -> const etag = "a1b2c3d4";
const pi = comptime(Math.PI);                  // -> const pi = 3.141592653589793;
const cfg = comptime({ timeout: 30 });         // -> const cfg = ({timeout:30});
const region = comptime(Env.AWS_REGION);       // -> const region = "us-east-1";
```

### Supported Operations

**Literals**: number, string, boolean, `null`, `undefined`, `NaN`, `Infinity`

**Operators**: `+ - * / % **`, `| & ^ << >> >>>`, `== != === !== < <= > >=`, `&& || ??`, `? :`, `+ - ! ~` (unary)

**Arrays and objects**: `[1, 2, 3]`, `{ a: 1, b: "x" }` (comptime values only)

**Math constants**: `Math.PI`, `Math.E`, `Math.LN2`, `Math.LN10`, `Math.LOG2E`, `Math.LOG10E`, `Math.SQRT2`, `Math.SQRT1_2`

**Math functions**: `abs`, `floor`, `ceil`, `round`, `trunc`, `sqrt`, `cbrt`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `log`, `log2`, `log10`, `exp`, `pow`, `min`, `max`, `sign`, `clz32`, `imul`, `fround`, `hypot`

**String properties**: `length`

**String methods**: `toUpperCase()`, `toLowerCase()`, `trim()`, `trimStart()`, `trimEnd()`, `slice()`, `substring()`, `includes()`, `startsWith()`, `endsWith()`, `indexOf()`, `charAt()`, `split()`, `repeat()`, `replace()`, `replaceAll()`, `padStart()`, `padEnd()`

**Built-in functions**: `parseInt()`, `parseFloat()`, `JSON.parse()`, `hash()` (FNV-1a, returns 8-char hex)

**Environment variables**: `Env.VARNAME` (configured via `StripOptions.comptime_env`)

**Build metadata**: `__BUILD_TIME__`, `__GIT_COMMIT__`, `__VERSION__`

### Disallowed Operations

Variables, arbitrary function calls, `Date.now()`, `Math.random()`, `new`, `this`, `eval`, assignments, loops, closures.

### Error Types

| Error | Description |
|-------|-------------|
| `ComptimeUnsupportedOp` | Operation not supported in comptime context |
| `ComptimeUnknownIdentifier` | Variable/function not whitelisted |
| `ComptimeCallNotAllowed` | Function call not allowed (e.g., `Math.random()`) |
| `ComptimeSyntaxError` | Syntax error in comptime expression |
| `ComptimeDepthExceeded` | Expression nesting too deep (max 64) |
| `ComptimeExpressionTooLong` | Expression exceeds 8KB limit |
| `ComptimeTypeMismatch` | Type error (e.g., string op on number) |

Division by zero is not an error. `comptime(1 / 0)` folds to `Infinity`, the same
value the expression produces at runtime.

### Performance Guards

- Max expression length: 8KB
- Max AST depth: 64

---

## TypeScript Patterns In The zts Subset

The community list ["TypeScript Tips Everyone Should
Know"](https://github.com/AllThingsSmitty/typescript-tips-everyone-should-know)
is good advice for plain TypeScript. This section maps that canon onto the
zts subset and shows what changes when the advice meets a compiler that
enforces it. It assumes the type-system mechanics covered above.

The lens is simple. The subset turns several tips from advice into compiler
guarantees: `any` and `enum` are hard errors, `null` is gone (the single
absent-value sentinel is `undefined`), and `match` does exhaustiveness checking
natively. It adapts a few tips because the underlying construct works
differently here: zts rejects both `as` and `satisfies`, so a conformance
check lives on the declaration instead. And it leaves one construct out by
design: `typeof`-type extraction would derive a type from a value, the inverse
of the contract-first direction the rest of this runtime depends on.

For the full allow and reject list see
[Feature Detection](feature-detection.md). For why each cut exists and what
proof it buys, see [Restrictions to Proofs](restrictions-to-proofs.md).

### Mapping Table

| # | Canon tip | Verdict | zts idiom |
|---|-----------|---------|-------------|
| 1 | Prefer `unknown` over `any` | Enforced | `any` is a hard error; `unknown` plus a type guard is the only path -> [unknown-and-guards.ts](../examples/patterns/unknown-and-guards.ts) |
| 2 | Let type inference do the work | Direct fit | annotate boundaries, infer internals -> [infer-and-generics.ts](../examples/patterns/infer-and-generics.ts) |
| 3 | Prefer `satisfies` over `as` | Adapted | both rejected; annotate the declaration -> [annotate-not-assert.ts](../examples/patterns/annotate-not-assert.ts) |
| 4 | Derive types from values | Partial | `typeof`-extraction absent by design; declare the alias, `const` keeps literals -> [annotate-not-assert.ts](../examples/patterns/annotate-not-assert.ts) |
| 5 | Discriminated unions for impossible states | Direct fit (core) | tagged unions plus `match` narrowing; `undefined`-only sentinel -> [discriminated-union-match.ts](../examples/patterns/discriminated-union-match.ts) |
| 6 | Exhaustive checks with `never` | Adapted (native) | `match` exhaustiveness is native with a required `default` arm; the `never`-helper is unneeded -> [discriminated-union-match.ts](../examples/patterns/discriminated-union-match.ts) |
| 7 | `as const` for config and constants | Adapted | `const` bindings preserve literals automatically; no `as const` -> [literal-types-no-enum.ts](../examples/patterns/literal-types-no-enum.ts) |
| 8 | Type predicates for reusable narrowing | Direct fit | `x is T` guards; pairs with `assert` -> [unknown-and-guards.ts](../examples/patterns/unknown-and-guards.ts) |
| 9 | Build new types from existing (`Pick`/`Omit`/`Partial`) | Direct fit | `Pick`/`Omit`/`Partial`/`Required` derive shapes from a source type, joining `Readonly<T>` -> [derive-types.ts](../examples/patterns/derive-types.ts) |
| 10 | Validate external data at runtime | Direct fit (built-in) | `zttp:validate` plus `zttp:decode` replace Zod -> [validate-external.ts](../examples/patterns/validate-external.ts) |
| 11 | Avoid `enum` | Enforced | `enum` is a hard error; literal unions only -> [literal-types-no-enum.ts](../examples/patterns/literal-types-no-enum.ts) |
| 12 | Generics that infer automatically | Direct fit | generics plus inference (up to 8 params) -> [infer-and-generics.ts](../examples/patterns/infer-and-generics.ts) |
| 13 | Strict compiler options | Adapted | no tsconfig; sound mode plus the canonical profile plus the analyzer are strict by construction ([sound-mode.md](sound-mode.md), [canonicalize and normalize](cli.md#canonicalize-and-normalize)) |
| 14 | Template literal types | Direct fit | template literal types supported -> [literal-types-no-enum.ts](../examples/patterns/literal-types-no-enum.ts) |
| 15 | Type-safe is not runtime-safe | Direct fit (thesis) | proof receipts, contracts, and runtime validation; the restrictions-to-proofs story ([restrictions-to-proofs.md](restrictions-to-proofs.md), the proof-receipt section of [user-guide.md](user-guide.md)) |

A note on the examples. Every tip with a code companion links to a handler under
`examples/patterns/`, and all seven are on disk and compile: each passes
`zttp check --types`, and three (`validate-external`,
`discriminated-union-match`, and `derive-types`) also run as behavioral
suites under `scripts/test-examples.sh`. A few snippets
below are shortened excerpts of those files, or of the matching sections in
[TypeScript](typescript.md) and [User Guide](user-guide.md) that exercise the
same constructs. Every snippet in this document compiles in the subset.

### Enforced

These tips are not advice in zts. The compiler rejects the alternative.

#### 1. Prefer `unknown` over `any`

Idiom: `any` is a hard error, so a value of unknown shape is typed `unknown` and
narrowed with a reusable `x is T` predicate before use.

The stripper rejects the `any` type outright (see the unsupported-features
table in [TypeScript](typescript.md)). That removes the escape hatch the canon
warns about: there is no `any` to drift into. The only way to use a value of
unknown shape is to narrow it. A type-guard function plus an `assert` statement
installs that narrowing:

```typescript
function isString(x: unknown): x is string {
    return typeof x === "string";
}

assert isString(val);
val.toUpperCase();       // narrowed from here forward
```

See [unknown-and-guards.ts](../examples/patterns/unknown-and-guards.ts) and the
"Type Guards and Assert" section of [TypeScript](typescript.md).

#### 11. Avoid `enum`

Idiom: `enum` is a hard error; model the finite set as a string literal union.

The canon lists "avoid enum" as a discipline. zts makes it a parse error: a
finite set of values is a union of string literals joined with `|`, which the
compiler can check for exhaustiveness in a `match`.

```typescript
structural Method = "GET" | "POST" | "DELETE";

const defaultMethod: Method = "GET";
```

Excerpted from [literal-types-no-enum.ts](../examples/patterns/literal-types-no-enum.ts).
The `enum` restriction and the failure class it removes are in
[Restrictions to Proofs](restrictions-to-proofs.md).

### Direct Fit

These tips translate one-to-one. The construct exists and behaves as the canon
describes.

#### 2. Let type inference do the work

Idiom: annotate the boundaries (parameters and return), let inference handle the
internals.

zts requires explicit parameter and return annotations on named functions
(strict ZigTS), which is exactly the canon's "annotate the boundary" advice made
mandatory. Inside the body, locals infer from their initializers, so redundant
local annotations are unnecessary.
See [infer-and-generics.ts](../examples/patterns/infer-and-generics.ts).

#### 5. Discriminated unions for impossible states

Idiom: tag each variant, dispatch with `match`, and let the tag make impossible
states unrepresentable. There is one absent-value sentinel, `undefined`, never
`null`.

```typescript
structural Result = { kind: "ok", value: string } | { kind: "err", error: string };

if (r.kind === "err") {
    return Response.json({ error: r.error }, { status: 400 });
}
// r is narrowed to { kind: "ok", value: string } from here
r.value.toUpperCase();
```

This is the core idiom of the subset, not an add-on: `null` is removed entirely
(see [Restrictions to Proofs](restrictions-to-proofs.md)), so a discriminated
union is the single way to carry "either this or that." Excerpted from the
"Discriminated Union Narrowing" section of [TypeScript](typescript.md); the
companion example is
[discriminated-union-match.ts](../examples/patterns/discriminated-union-match.ts).

#### 8. Type predicates for reusable narrowing

Idiom: a `x is T` predicate is a reusable narrowing function; it pairs with
`assert` for forward narrowing or with `if` for branch narrowing.

```typescript
function isString(x: unknown): x is string {
    return typeof x === "string";
}

if (isString(val)) {
    val.toUpperCase();   // narrowed in then-branch
}
```

The same predicate drives tip 1. See the "Type Guards and Assert" section of
[TypeScript](typescript.md) and
[unknown-and-guards.ts](../examples/patterns/unknown-and-guards.ts).

#### 10. Validate external data at runtime

Idiom: there is no Zod step. Compile a schema by name at the top level with
`zttp:validate`, then gate the handler on the `.ok` of the result before
touching `.value`.

```typescript
import { schemaCompile, validateJson } from "zttp:validate";

schemaCompile("todo", '{"type":"object","required":["title"]}');

function handler(req: Request): Response {
    const parsed = validateJson("todo", req.body);
    if (!parsed.ok) {
        return Response.json({ error: "invalid body" }, { status: 400 });
    }
    return Response.json(parsed.value, { status: 201 });
}
```

The verifier enforces the `.ok`-before-`.value` discipline at build time:
`validateJson` is a Result-producing call, so accessing `.value` on an
unchecked result is a compile error (see [Verification](verification.md)). The
built-in modules `zttp:validate` and `zttp:decode` cover the runtime
validation the canon reaches for a library to do. Excerpted from the "JSON And
Validation" section of [User Guide](user-guide.md); the companion example is
[validate-external.ts](../examples/patterns/validate-external.ts).

Testing note: `zttp:validate` and `zttp:decode` are pure (their result is a
function of their arguments and the compiled schema), so a handler test under
`serve --test` runs them for real without an `io` mock. The
`validate-external.test.jsonl` suite posts a body and asserts the 201/400 path
against the real validator. Effectful modules (`fetch`, `cache`, `sql`, `env`,
random-backed `id`) still need recorded `io` entries to stay deterministic.

#### 12. Generics that infer automatically

Idiom: write one generic helper and reuse it across element types by naming the
type argument at the call site.

A helper such as `first<T>(xs: T[]): T | undefined` is reused as
`first<string>(items)`, and the result type flows into the handler. zts
supports generic function declarations and generic arrow functions, with up to 8
type parameters per alias (see "Generic Type Aliases" in
[TypeScript](typescript.md)). The companion example is
[infer-and-generics.ts](../examples/patterns/infer-and-generics.ts).

#### 14. Template literal types

Idiom: constrain a string to a pattern with a template literal type, checked at
build time.

```typescript
structural ApiRoute = `/api/${string}`;

const defaultRoute: ApiRoute = "/api/health";
```

A value that does not match the pattern is a compile error (the canon's
intent, enforced). Excerpted from
[literal-types-no-enum.ts](../examples/patterns/literal-types-no-enum.ts); see
also "Template Literal Types" in [TypeScript](typescript.md).

#### 9. Build new types from existing (`Pick`/`Omit`/`Partial`/`Required`)

Idiom: the utility-type family derives a related shape from one source type, so
each field stays declared in a single place.

`Pick<T, Keys>` keeps only the named fields, `Omit<T, Keys>` drops them,
`Partial<T>` makes every field optional, and `Required<T>` makes every field
required. They resolve structurally and work against a named source type, not
just an inline object, joining the already-supported `Readonly<T>` (see
"Readonly Fields" in [TypeScript](typescript.md)).

```typescript
structural User = { id: number; name: string; email: string; age: number };
structural Summary = Pick<User, "id" | "name">; // { id: number; name: string }
structural Safe = Omit<User, "email">;          // id, name, age
structural UserPatch = Partial<User>;           // every field optional
```

See [derive-types.ts](../examples/patterns/derive-types.ts). Intersection (`&`)
still composes narrower types where a utility does not fit:
`type WithMeta = Base & { createdAt: string }`.

### Adapted

These tips map to a different construct, because the canonical TypeScript
mechanism is absent or replaced.

#### 3. Prefer `satisfies` over `as`

Idiom: zts rejects both `as` and `satisfies`, so the conformance check moves
onto the declaration. An explicit annotation on a `const` binding is the
assertion-free `satisfies`.

The canon recommends `satisfies` because it checks conformance without widening
the type. zts removes the question by rejecting both assertion forms. The
replacement is to annotate the binding directly: `const config: Config = {...}`
checks the literal against `Config` and keeps its narrow type, which is what
`satisfies` was for.

```typescript
structural Config = { port: number; host: string; readonly version: string };
const config: Config = { port: 8080, host: "0.0.0.0", version: "1.0" };
```

See [annotate-not-assert.ts](../examples/patterns/annotate-not-assert.ts). The
rejection of `as` and `satisfies` is covered in the unsupported-features table
of [TypeScript](typescript.md).

#### 4. Derive types from values

Idiom: `typeof`-type extraction is left out by design, so the type alias is the
declared contract the value is checked against; a `const` binding keeps its
literal type from the annotation without `as const`.

In plain TypeScript you can write `type Config = typeof config` to derive a type
from a value. That direction is not available here, and its absence is the
point: the alias is declared first and the value is checked against it, so the
type stays an independent contract. A type derived from the value it describes
would have nothing left to check. The same
[annotate-not-assert.ts](../examples/patterns/annotate-not-assert.ts) example
shows the declared-alias form, and the rationale is under Deliberately Absent
below.

#### 6. Exhaustive checks with `never`

Idiom: `match` exhaustiveness is native, so the `never`-typed `assertNever`
trick is unnecessary.

In plain TypeScript the standard exhaustiveness guard is a `default` branch that
assigns the discriminant to a `never`-typed parameter (`assertNever(x: never)`),
which stops compiling when a new variant is added. zts checks `match`
exhaustiveness directly, and the canonical profile requires every `match` to
carry a `default` / `when _:` catch-all arm so the unexpected case is always
handled. Full variant coverage satisfies the type-level exhaustiveness check but
does not lift that requirement - it applies to a local discriminant just as much
as a parameter. So the rule is simple: give every `match` a `default` arm, and
the `never`-parameter helper buys nothing. The companion
[discriminated-union-match.ts](../examples/patterns/discriminated-union-match.ts)
dispatches on a parameter, carries a `default` arm, and checks with every
property proven and no warnings.

#### 7. `as const` for config and constants

Idiom: a `const` binding preserves its literal type from the annotation on its
own. No `as const`.

```typescript
// No `as const` here. The annotation pins the literal type on its own.
const defaultMethod: Method = "GET";
const defaultRoute: ApiRoute = "/api/health";
```

`const x = 200` already has type `200`, not `number` (see "Literal Types and
Annotation Semantics" in [TypeScript](typescript.md)), so the `as const`
assertion has nothing to add and is rejected along with the other assertions.
Excerpted from
[literal-types-no-enum.ts](../examples/patterns/literal-types-no-enum.ts).

#### 13. Strict compiler options

This is a philosophy tip, so there is no snippet. zts has no `tsconfig.json`
and no opt-in strictness dial. Strict ZigTS is the default profile: `any` is
rejected, named functions must carry parameter and return annotations,
capability access must use literal keys, and an avoidable `let` is an error.
Layered on top are sound mode (boolean-only control flow, arithmetic, and
comparison diagnostics) and the canonical profile, both strict by construction
rather than by flag. See [Sound Mode](sound-mode.md) and
[Canonicalize And Normalize](cli.md#canonicalize-and-normalize). The canon's "turn on every strict
option" reduces to "the strict options are the only options."

### Type-Safe Is Not Runtime-Safe (Tip 15)

The closing tip of the canon is the thesis of this whole runtime, so it gets
prose rather than a snippet. A passing type check proves shape, not behavior at
the boundary. zts answers that on two fronts. At the boundary, runtime
validation through `zttp:validate` and `zttp:decode` (tip 10) checks the
data that types alone cannot. Above the type system, the
restrictions-to-proofs story turns each language cut into a discharged property
(exhaustive returns, state isolation, no secret leakage, and the rest), and
every build can sign those properties into a proof receipt that a third party
verifies. See [Restrictions to Proofs](restrictions-to-proofs.md) for the
cut-to-proof table and the proof-receipt section of
[User Guide](user-guide.md) for the signed receipts.

### Deliberately Absent

Two constructs a TypeScript author might reach for are missing, and both
absences are choices rather than unfinished work. They are listed here so the
omission reads as deliberate.

`typeof`-type extraction (`type Config = typeof config`) derives a type from a
value. That inverts the relationship the rest of this runtime depends on: a type
is the independent contract a value is checked against, and a contract derived
from the value it describes cannot be violated by that value. The declared-alias
direction (tip 4) keeps the type as the spec and the value as the thing measured
against it, which is the whole point of a checker.

An assertion-form `satisfies` is the operator the subset removed on purpose. `as`
and `satisfies` are both assertions, and rejecting them is what lets an
annotated `const` stand as the single source of truth (tip 3). A `satisfies`
that checks without widening would hand back the narrower-than-declared shape:
the second, drifting type the rejection was meant to eliminate. The ergonomic
saving is real and small; the assertion-free guarantee is the larger thing, and
not worth trading for it.

---

## Implementation Details

### Files

- `packages/zts/src/stripper.zig` - Type stripper with comptime integration
- `packages/zts/src/comptime.zig` - Compile-time expression evaluator (~2000 lines)
- `StripOptions` controls features: `tsx_mode`, `enable_comptime`, `comptime_env`

### Build-Time Integration

The stripper runs as a prepass for `.ts` and `.tsx` sources before zts parsing. Runtime parser receives JS-only output. Enable comptime via `StripOptions.enable_comptime`.

# ZTS advanced formal-spec northstar

**Status:** proposed language and assurance profile  
**Profile name:** `zts-advanced-1`  
**Grounded against:** ZTS 0.18.0, policy 2026.04.2, 2026-07-30  
**Relationship to the earlier northstar:** this document replaces its design
claims, not its historical record. The earlier artifact remains useful context,
but it does not define the advanced profile.

## 1. Decision

ZTS should be a compact application language with a rich type and library
surface, not a small language that forces applications to escape into native
code.

The target is:

> A TypeScript-shaped application surface where every admitted construct has
> one canonical meaning and a local lowering into a much smaller, closed,
> independently checkable execution kernel.

The optimal balance is not the fewest source tokens at any cost. It is the
fewest semantic concepts and competing spellings that still let ordinary
applications express their domain directly.

This profile therefore makes four decisions:

1. Add no new control-flow statements and no new control-flow operators.
2. Complete the existing type system instead of importing TypeScript's
   type-level programming language.
3. Put common application power in pure, typed data abstractions and explicit
   capability modules.
4. Separate language acceptance from proof claims. An accepted program may
   run even when termination or a cost bound is unproved. A proof certificate
   may never hide that gap.

### 1.1 Syntax budget

| Area | Advanced-profile decision |
|---|---|
| New statement keywords | None |
| New control-flow operators | None |
| Restored data literals | `null`, only as an explicit value |
| Added type syntax | Bounded generic parameters with `extends` |
| Added type capability | Sound function generics and contractive recursive aliases |
| Added pure abstractions | `Result<T, E>`, `Dict<K, V>`, immutable `Bytes`, `HtmlNode` |
| Added concurrency model | None; retain explicit `parallel` and `race` |
| Added error channel | None; errors remain ordinary tagged values |

The executable kernel grows only for `null`, `Dict`, and `Bytes`. Generic
constraints, recursive aliases, and `Result` are erased or elaborate to
existing records, unions, calls, and branches.

## 2. Application envelope

`zts-advanced-1` is intended to support these application classes without
checker bypasses or routine native extensions:

- HTTP and JSON APIs, including validation, authentication, CRUD, caching,
  SQL, and outbound calls
- server-rendered HTML and TSX components
- WebSocket and event handlers
- queue consumers and producers
- durable workflows and scheduled jobs
- explicit parallel and racing I/O
- pure collection, text, tree, and domain algorithms
- reusable application modules with typed public contracts

The profile is not intended to provide:

- browser DOM programming
- npm or JavaScript ecosystem compatibility
- prototype or metaclass programming
- dynamic code loading, reflection, `eval`, or `Proxy`
- ambient event-loop scheduling
- exception-driven control flow
- shared mutable process state as an application database
- source compatibility with all TypeScript

An application profile is ready only when representative programs from every
target class compile, run, and verify without:

- `unknown` used to launder a known type
- parser-specific source rewrites such as reversing an ordinary comparison in
  TSX
- native modules introduced only to compensate for a language gap
- unchecked dynamic property access
- trapping operations on attacker-controlled input
- an unexplained or mislabeled proof gap

## 3. Current baseline and the gap

The live compiler already has most of the right shape:

- block-scoped `const` and necessary `let`
- named functions, direct arrow callbacks, lexical closures, and recursion
- records, arrays, tuples, fixed-shape mutation, destructuring, spread,
  templates, optional chaining, and nullish coalescing
- `if`/`else`, `for...of`, `match`, `assert`, `return`, `break`, and
  `continue`
- static named modules and type-only imports
- aliases, interfaces, literals, unions, intersections, tuples, generic
  aliases and functions, `distinct type`, readonly and optional fields, type
  guards, template literal types, and a small utility-type family
- TSX
- explicit `zttp:*` capability modules and structured I/O

The canonical checker is narrower than the parser and the feature catalog. It
also rejects redundant forms such as ternaries, compound assignment, call
spread, default parameters, nested destructuring, non-leading object spread,
and reusable function-valued constants.

The important gaps are not more loop or class syntax:

1. Generic function syntax is accepted, but sound instantiation and inference
   are incomplete.
2. Dynamic keyed data has no supported typed collection. JavaScript `Map` and
   `Set` implementations exist internally but are intentionally not exposed.
3. Runtime `Result` values are not represented by one precise generic ADT
   across the type and module surfaces.
4. Recursive application data cannot be expressed soundly as a recursive
   alias.
5. JSON `null` exists at runtime but cannot be named as source data.
6. Array higher-order functions exist at runtime, but their callback and
   result types are not uniformly modeled.
7. `for...of` and recursive functions invalidate the old claim that every
   execution is bounded by IR-tree depth.
8. The declarative semantics currently covers 10 of 81 IR nodes and 7 of 130
   opcodes. That is a useful verified slice, not a complete language
   semantics.
9. The earlier signed semantics receipt was removed because it had no
   consumer. A future certificate must start from a verifier and trust model,
   not from a producer-only artifact.

The advanced profile treats those facts as its starting point.

## 4. Design laws

Every feature admitted to the profile must satisfy all applicable laws.

### 4.1 One canonical source form

If two constructs express the same operation with no meaningful semantic
difference, keep one.

Examples:

- `match`, not `switch`
- explicit assignment, not compound assignment or increment/decrement
- explicit `T | undefined` resolution in the body, not default parameters
- named reusable functions, not exported or reusable function-valued
  constants
- `type`, not both `type` and `interface`, for application data contracts
- annotations and narrowing, not `as` or `satisfies`
- `Dict`, not computed keys on shape records

### 4.2 Local elaboration

A surface feature should lower locally to a small number of kernel forms. The
lowering must not depend on runtime reflection, prototype lookup, hidden
receiver binding, or ambient scheduling.

### 4.3 Visible control and effects

Every branch, failure path, state write, and external effect must remain
visible in typed IR.

- recoverable failure is `Result<T, E>`
- absence is normally `T | undefined`
- JSON `null` is explicit data, not an implicit optional value
- I/O is a named capability call
- concurrency is an explicit structured operation
- reusable state lives behind a capability, not in a mutable module global

### 4.4 Closed executable semantics

Every source construct admitted to a certified build must map to:

- a specified core operation,
- a specified standard-library intrinsic, or
- a versioned and authenticated external-module contract.

An unknown node, opcode, value kind, callback path, or module call makes the
certified build fail closed.

### 4.5 Proof claims are property-specific

Translation correctness, partial correctness, determinism, totality, cost
bounds, and application policies are different claims.

The compiler must never infer:

- termination from syntax acceptance,
- a cost bound from a runtime fuse,
- module behavior from a self-declared manifest,
- proof from a solver invocation that returned `unknown`,
- end-to-end correctness from a proof over one IR slice.

## 5. Normative source profile

The words MUST, MUST NOT, SHOULD, and MAY are normative in this document.

### 5.1 Modules

The profile permits:

```ts
import { name, other as local } from "./module.ts";
import { fetch } from "zttp:fetch";
import type { Effects, Proof, Spec } from "zttp:types";

export type User = { readonly id: UserId; name: string };
export distinct type UserId = string;
export function loadUser(id: UserId): Result<User, LoadError> { ... }
export const version: string = "1";
```

Rules:

- Imports and exports MUST be statically named.
- A module specifier MUST be a string literal.
- Relative application modules and registered `zttp:*` or `zttp-ext:*`
  modules are permitted.
- Type-only imports are erased.
- Default imports, anonymous default exports, namespace imports, side-effect
  imports, dynamic imports, and export-star forms are excluded.
- Re-exports are excluded. Importing and then exporting a named declaration
  keeps the module graph explicit.
- Module initialization MUST be pure. Handler-reachable mutable module state
  is excluded from the certified profile.
- A top-level value binding MUST use `const`. Reassignment is local to a
  function activation.

### 5.2 Declarations and bindings

The profile permits:

- `const` for every binding that is assigned once
- `let` only when the binding is reassigned
- named function declarations for reusable behavior
- direct arrow expressions only as arguments to typed, finite callback APIs
- one-level object or array destructuring
- one leading object spread followed by explicit fields

It excludes:

- `var`
- nested or rest destructuring
- rest and default parameters
- function expressions
- reusable or exported arrow helpers
- object methods, getters, and setters
- declaration merging

Object literals contain data fields only. Reusable behavior is a named
function with explicit inputs and outputs.

### 5.3 Values

Core values are:

```text
undefined
null
false | true
number
string
Bytes
array and tuple
fixed-shape record
Dict
closure
opaque capability value
```

Rules:

- `undefined` is the ordinary absence sentinel and the representation of an
  omitted optional field.
- `null` is permitted only when its type explicitly contains `null`.
- `null` is primarily for JSON fidelity. It is not assignable to an optional
  `T | undefined` unless the declared type also names `null`.
- `number` has exact IEEE 754 binary64 semantics, including `NaN`, infinities,
  and negative zero. JSON and capability boundaries MUST reject non-finite
  values when their wire format cannot represent them.
- `string` contains valid Unicode and rejects invalid UTF-8 at ingress. The
  observable `length`, indexing, and slicing contract retains ZTS's current
  UTF-16 code-unit model. The formal string library MUST specify the behavior
  of boundaries inside an astral scalar exactly.
- `Bytes` is an immutable sequence of octets. Text conversion is explicit and
  returns `Result` when decoding can fail.
- Record shapes are fixed after allocation. Existing writable fields may be
  updated. Fields cannot be added or deleted dynamically.
- A fixed record key that is a valid identifier MUST use the identifier in a
  literal or type and dot access at a read site. Any other fixed key MUST use a
  string literal and the same string literal in bracket form. Numeric record
  keys are excluded; use a string key or a number-keyed `Dict`.
- Arrays may be locally mutable. Aliased or captured mutation is visible as a
  state effect and may prevent purity, determinism, or isolation proofs.
- `Dict` is immutable and has deterministic insertion-order iteration.
- Function and object equality is identity equality. `Dict` keys are
  `string`, `number`, or a `distinct type` over either.

`null` and `undefined` remain distinct. Optional chaining and `??` follow
TypeScript nullish behavior and therefore test both. Code that needs to
preserve JSON `null` MUST use an explicit comparison or `match`.

### 5.4 Operators and expressions

The profile permits:

- arithmetic, comparison, bitwise, and boolean operators
- strict equality `===` and `!==`
- `typeof` in value position
- direct and optional static member access
- numeric array and tuple indexing
- literal bracket access to a quoted fixed record field
- calls with fixed positional arguments
- array and record literals
- finite array spread
- one leading record spread
- simple template interpolation
- `??`, `?.`, and the pipe operator
- `comptime()` over closed, pure expressions
- `match` expressions
- TSX expressions

The profile excludes:

- loose equality
- implicit numeric or string coercion
- assignment in expression position
- compound and logical assignment
- increment and decrement
- comma and sequence expressions
- ternaries
- call spread
- dynamic record property access
- regex literals and the ambient `RegExp` constructor
- `delete`
- `new`
- `this` and `super`
- `yield`, generators, `async`, `await`, and `Promise`

Template interpolation MUST contain a local, literal, or static property
read. A call or other effectful expression is hoisted to a named `const`.

### 5.5 Control flow

The statement set is:

```text
block
const declaration
necessary let declaration
plain assignment statement
expression statement
if / else
for...of
assert
return
break
continue
local function declaration
```

There is no `switch`, `while`, `do...while`, C-style `for`, `for...in`,
`throw`, `try`, `catch`, or `finally`.

#### `match`

`match` is the only multi-way branch:

```ts
type Command =
  | { kind: "echo"; text: string }
  | { kind: "ping" };

function run(command: Command): string {
  return match (command) {
    when { kind: "echo" }:
      command.text
    when { kind: "ping" }:
      "pong"
  };
}
```

Rules:

- Arms are checked in source order.
- Patterns are literals or fixed record-discriminant patterns.
- A closed literal or discriminated union MUST be covered exactly and SHOULD
  omit `default`.
- An open domain such as `string`, `number`, or `unknown` MUST include
  `default`.
- Duplicate, unreachable, and non-exhaustive arms are errors.
- Each arm narrows the scrutinee for its expression.

#### `assert`

`assert predicate;` installs forward narrowing or halts with a typed runtime
assertion fault.

`assert predicate, fallback;` returns `fallback` from the enclosing function
when the predicate is false. The fallback type MUST be assignable to the
enclosing return type.

Use `assert` for an invariant. Use `Result` for expected failure.

#### `for...of`

`for...of` is the only source loop:

```ts
for (const item of items) {
  if (skip(item)) continue;
  if (done(item)) break;
  consume(item);
}
```

Its semantics are snapshot-finite:

1. Evaluate the iterable once.
2. Fix its ordered iteration sequence and length at loop entry.
3. Iterate each snapshot element at most once.
4. Mutation of the original collection cannot add iterations.

Admitted iterables are arrays, tuples, strings, `range(n)`, `Dict` entries,
and other standard-library values whose contract supplies a finite snapshot.
There is no user-defined iterator protocol.

`range(n)` requires a finite non-negative integer. A certified cost claim also
requires a proven upper bound for `n`.

### 5.6 Functions and recursion

Every named function MUST declare all parameter and return types. A direct
arrow callback MAY infer them from a fully typed callback position.

Generic functions are sound and erased:

```ts
function first<T>(items: readonly T[]): T | undefined {
  return items[0];
}

function getId<T extends { readonly id: string }>(value: T): string {
  return value.id;
}
```

Rules:

- Type arguments are inferred from value arguments.
- Explicit type arguments are permitted when inference is ambiguous.
- A generic declaration has at most eight parameters.
- Constraints are structural bounds composed from admitted types.
- Generic defaults, overload sets, variance annotations, higher-kinded types,
  and runtime type reflection are excluded.
- Every instantiation is checked. An unresolved type never degrades silently
  to `unknown`.

Recursion is an admitted application feature, not automatic evidence of
termination:

- direct and mutual recursion have a specified call semantics,
- translation validation uses step-indexed simulation and does not unroll a
  call tree,
- totality and bounded-cost claims require an acyclic reachable call graph or
  a compiler-proven decreasing argument,
- if no termination argument is found, the program may remain accepted but
  the corresponding proof property is unavailable.

No runtime stack cap may be presented as a termination proof.

### 5.7 Types

The canonical type declaration forms are:

```ts
type Name<T> = Type;
distinct type UserId = string;
```

`interface` is excluded from the advanced canonical profile because record
aliases already provide its admitted behavior. Open interfaces, declaration
merging, inheritance, and `implements` remain excluded.

Admitted types are:

- `unknown`, `never`, `undefined`, `null`, `boolean`, `number`, `string`,
  `Bytes`, `HtmlNode`, `Request`, `Response`, and capability-specific opaque
  types
- boolean, number, and string literals
- arrays, readonly arrays, and fixed tuples
- fixed records with readonly and optional fields
- function types
- unions and intersections
- named aliases and nominal `distinct type`
- generic applications and constrained generic parameters
- template literal types
- `Readonly`, `Pick`, `Omit`, `Partial`, and `Required`
- `Spec`, `Proof`, and `Effects` capsules
- contractive recursive aliases

A recursive alias is contractive when every cycle passes through a record,
tuple, array, `Dict`, or tagged union constructor:

```ts
type JsonValue =
  | null
  | boolean
  | number
  | string
  | readonly JsonValue[]
  | Dict<string, JsonValue>;
```

Direct cycles such as `type Loop = Loop`, negative recursion through a
function parameter, and recursive conditional expansion are errors.

Excluded type features are:

- `any`
- `as`, angle-bracket assertions, and `satisfies`
- `keyof`, indexed-access types, and index signatures
- type-position `typeof`
- conditional, distributive, mapped, and inferred types
- overload declarations
- ambient declarations and namespaces
- enums
- decorators and access modifiers

The type layer is not part of the executable semantic kernel. It has its own
soundness obligation: well-typed surface programs elaborate to well-formed
core programs without erased annotations being used as runtime evidence.

### 5.8 JSX and TSX

TSX is an optional surface elaboration into specified `h` and `Fragment`
operations.

- `HtmlNode` is an opaque immutable virtual-node type.
- `HtmlChild` is `HtmlNode | string | number | boolean | null | undefined |
  readonly HtmlChild[]`.
- Components are named functions.
- Props are fixed records.
- A component returns `HtmlNode`.
- Children are finite arrays of `HtmlChild`.
- Rendered text is escaped by default.
- Raw HTML requires an explicit capability-reviewed API.
- The tokenizer MUST parse ordinary `<`, `<=`, `>`, and `>=` expressions
  inside TSX expression containers. Reversing a comparison to avoid a parser
  ambiguity is not conforming source.
- JSX spread follows the same one-leading-base rule as record spread.

JSX introduces no component lifecycle, ambient state, hooks, class
components, or hidden effect scheduling.

The surface elaborates through these typed intrinsics:

```ts
type HtmlChild =
  | HtmlNode
  | string
  | number
  | boolean
  | null
  | undefined
  | readonly HtmlChild[];

type Component<P> = (
  props: P & { readonly children?: readonly HtmlChild[] },
) => HtmlNode;

jsxElement<P>(
  tag: string | Component<P>,
  props: P | undefined,
  children: readonly HtmlChild[],
): HtmlNode

jsxFragment(children: readonly HtmlChild[]): HtmlNode
renderToString(node: HtmlNode): string
```

The intrinsic names describe the semantics and are not additional source
syntax. `null`, `undefined`, and boolean children render no text. Nested child
arrays flatten in source order. Text and attribute values are escaped.

## 6. Pure application data abstractions

### 6.1 `Result<T, E>`

`Result` is the one recoverable-failure representation:

```ts
type Result<T, E> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: E };
```

The canonical pure operations are:

```ts
ok<T>(value: T): Result<T, never>
err<E>(error: E): Result<never, E>
mapResult<T, U, E>(result: Result<T, E>, f: (value: T) => U): Result<U, E>
mapError<T, E, F>(result: Result<T, E>, f: (error: E) => F): Result<T, F>
andThen<T, U, E, F>(
  result: Result<T, E>,
  f: (value: T) => Result<U, F>,
): Result<U, E | F>
```

The type is predeclared. Constructors and combinators are statically named
imports from the zero-capability `zttp:result` module.

Use `match` or narrowing to consume it. Trapping `unwrap` and `unwrapErr` are
not canonical. A checked extraction after an `ok` guard MAY lower directly to
the value field.

All fallible ingress APIs, decoders, capability calls, text codecs, and
partial collection operations SHOULD return a typed `Result`.

### 6.2 `Dict<K, V>`

`Dict` supplies dynamic keyed data without dynamic record shapes:

```ts
dictEmpty<K extends DictKey, V>(): Dict<K, V>
dictFromEntries<K extends DictKey, V>(
  entries: readonly (readonly [K, V])[]
): Result<Dict<K, V>, DuplicateKey<K>>
dictGet<K extends DictKey, V>(dict: Dict<K, V>, key: K): V | undefined
dictSet<K extends DictKey, V>(dict: Dict<K, V>, key: K, value: V): Dict<K, V>
dictRemove<K extends DictKey, V>(dict: Dict<K, V>, key: K): Dict<K, V>
dictHas<K extends DictKey, V>(dict: Dict<K, V>, key: K): boolean
dictEntries<K extends DictKey, V>(dict: Dict<K, V>): readonly (readonly [K, V])[]
```

`DictKey` is `string | number` or a `distinct type` over one of those bases.

`dictSet` and `dictRemove` return new dictionaries. Iteration order is the
insertion order of the current value. Updating a present key does not move it.
Numeric key equality is SameValueZero: `NaN` equals `NaN`, and negative zero
equals positive zero. String keys compare by scalar sequence. The pure
operations are statically named imports from the zero-capability
`zttp:collections` module.

### 6.3 `Bytes`

`Bytes` prevents text strings from becoming an accidental binary container.
Its pure surface includes length, indexing, slicing, concatenation, equality,
hex, Base64, and UTF-8 codecs.

- Construction validates every octet.
- Values are immutable.
- Indexing is bounds checked.
- Decoding returns `Result`.
- Capability modules declare whether a payload is `string`, `Bytes`, or a
  structured value.
- Pure byte operations are statically named imports from the zero-capability
  `zttp:bytes` module.

### 6.4 JSON

JSON uses the recursive `JsonValue` type from Section 5.7. Object nodes are
`Dict<string, JsonValue>`, not dynamic-shape records.

The canonical boundary is:

```ts
type JsonError =
  | { kind: "invalid-syntax"; offset: number }
  | { kind: "duplicate-key"; key: string; offset: number }
  | { kind: "depth-limit"; limit: number }
  | { kind: "size-limit"; limit: number }
  | { kind: "non-finite-number" }
  | { kind: "cycle" };

decodeJson(text: string): Result<JsonValue, JsonError>
encodeJson<T>(value: T): Result<string, JsonError>
```

Rules:

- decoding validates UTF-8, syntax, depth, and configured input size,
- duplicate object keys are rejected,
- object insertion order follows wire order,
- the checker admits `encodeJson<T>` only when `T` contains JSON scalars,
  arrays, tuples, fixed records, or string-keyed `Dict` values,
- encoding preserves array order, fixed-record declaration order, and
  dictionary insertion order,
- optional `undefined` fields are omitted and `undefined` array elements are
  rejected,
- non-finite numbers and cyclic values are rejected,
- `null` round-trips as data,
- and every failure is a typed `Result`.

The limits are selected by the runtime policy and bound into checked and
certified artifacts. Trapping `JSON.parse`, silent `undefined` on parse
failure, and unchecked `JSON.stringify` are excluded from the canonical
profile. Schema-directed decoders return a precise application type rather
than `unknown`.

### 6.5 Arrays and higher-order functions

The canonical finite operations are fully generic:

```ts
map<T, U>(items: readonly T[], f: (value: T, index: number) => U): U[]
filter<T>(items: readonly T[], f: (value: T, index: number) => boolean): T[]
reduce<T, U>(items: readonly T[], f: (acc: U, value: T, index: number) => U, init: U): U
find<T>(items: readonly T[], f: (value: T, index: number) => boolean): T | undefined
some<T>(items: readonly T[], f: (value: T, index: number) => boolean): boolean
every<T>(items: readonly T[], f: (value: T, index: number) => boolean): boolean
```

Each operation uses snapshot-finite iteration. Its callback MUST be pure. The
checker verifies the callback body and every reachable helper rather than
assuming that an arrow expression is pure. An effectful traversal uses
`for...of`, which keeps sequencing and failure visible without adding
effect-polymorphic callback types.

The canonical source spelling is an intrinsic array method such as
`items.map(f)`. Dispatch is resolved statically from the receiver type and
lowers to an explicit intrinsic such as `arrayMap(items, f)`. It never performs
prototype lookup.

Use a higher-order operation for a direct transformation or fold. Use
`for...of` when the algorithm needs `break`, `continue`, explicit effect
sequencing, or more than one evolving accumulator.

## 7. Effects and structured concurrency

The executable language has no ambient I/O. External behavior enters through
named capability modules.

Every exported module function has a machine-readable contract containing:

- complete input and output types
- required capabilities
- effect row
- deterministic or replay-dependent status
- failure type
- atomicity and retry behavior
- replay behavior
- cost model
- implementation and manifest digests
- publisher or isolation identity

Application-facing capability names remain explicit, including environment,
clock, random, crypto, logging, storage, filesystem, network, policy,
WebSocket, queue, and durable-workflow effects.

Ambient `Date.now`, `performance.now`, random-number generation, console
output, filesystem access, and network access are excluded from the advanced
canonical profile. Their named modules make authority and replay inputs
visible.

### 7.1 Structured I/O

`parallel` and `race` are explicit effect operations, not Promise emulation.

```ts
function loadUser(): Result<User, FetchError> { ... }
function loadOrders(): Result<readonly Order[], FetchError> { ... }

const [user, orders] = parallel([loadUser, loadOrders]);
```

Rules:

- The task list is a finite tuple of named zero-argument functions.
- The result preserves tuple position and each task's precise result type.
- The combined effect row is the union of task effects.
- Replay order, cancellation, timeout, and loser cleanup are part of the
  module contract.
- `race` returns a tagged result that identifies the winner. It does not erase
  result types to `unknown`.
- There is no user-visible Promise, microtask queue, detached task, or
  implicit scheduler.

### 7.2 Minimum application ABI

The profile is not application-complete if its framework modules expose
`object`, `unknown`, or an untagged failure where the application knows a more
precise type. At minimum, the module registry MUST express the following
contracts.

#### HTTP

```ts
type HttpHandler = (request: Request) => Response;

requestBody(request: Request): Bytes
requestText(request: Request): Result<string, BodyError>
requestJson(request: Request): Result<JsonValue, JsonError | BodyError>
responseJson<T>(value: T, status: number): Result<Response, JsonError>
fetch(
  url: string,
  options: FetchOptions,
): Result<Response, FetchError>
```

`responseJson<T>` uses the JSON-encodability rule from Section 6.4. Request
headers, method, URL, route parameters, status, and response headers have
precise fixed or opaque types. Attacker-controlled data enters as `string`,
`Bytes`, `JsonValue`, or a schema-decoded application type, never as silently
trusted `unknown`.

#### WebSocket

```ts
distinct type SocketId = string;

type WebSocketEvent =
  | { kind: "open"; socket: SocketId }
  | { kind: "message"; socket: SocketId; data: string | Bytes }
  | { kind: "close"; socket: SocketId; code: number; reason: string };

type WebSocketCommand =
  | { kind: "send"; socket: SocketId; data: string | Bytes }
  | { kind: "close"; socket: SocketId; code: number; reason: string };

type WebSocketHandler<E> = (
  event: WebSocketEvent,
) => Result<readonly WebSocketCommand[], E>;
```

The runtime executes returned commands at the effect boundary. Broadcast,
attachment, and auto-response APIs use the same `SocketId`, payload, and
typed-error contracts.

#### Queue

```ts
distinct type MessageId = string;
distinct type ReceiptId = string;

type QueueMessage<T> = {
  readonly id: MessageId;
  readonly receipt: ReceiptId;
  readonly attempt: number;
  readonly payload: T;
};

type QueueDecision =
  | { kind: "ack"; receipt: ReceiptId }
  | { kind: "retry"; receipt: ReceiptId; afterMs: number; reason: string }
  | { kind: "dead-letter"; receipt: ReceiptId; reason: string };

send<T>(queue: string, payload: T): Result<MessageId, QueueError>
```

`send<T>` requires a statically JSON-encodable payload. A consumer returns a
`QueueDecision` or calls typed `ack`, `retry`, or dead-letter operations.
Delivery attempt, retry delay, idempotency key, and acknowledgement semantics
are explicit in the module contract and replay trace.

#### Durable workflow

```ts
run<I, O, E>(
  id: string,
  input: I,
  body: (input: I) => Result<O, E>,
): Result<O, E | DurableError>

step<O, E>(
  name: string,
  body: () => Result<O, E>,
): Result<O, E | StepError>
```

Inputs and outputs MUST be statically serializable. Workflow bodies and step
bodies are named functions. The contract defines retry, timeout, cancellation,
signal, compensation, versioning, and replay behavior. A replayed step returns
its recorded typed result without silently running its effect twice.

These are minimum type shapes, not a requirement that every module use these
exact source names. The versioned registry binds each concrete exported name
to one of the specified roles.

## 8. Compact grammar

This grammar describes structure, not lexical details or precedence.
Capitalized names are lexical classes.

```ebnf
Module       ::= Import* TopDecl*

Import       ::= "import" ["type"] "{" ImportNames "}" "from" String ";"
ImportNames  ::= ImportName ("," ImportName)* [","]
ImportName   ::= Ident ["as" Ident]

TopDecl      ::= ["export"] TypeDecl
               | ["export"] DistinctDecl
               | ["export"] FunctionDecl
               | ["export"] TopBindingDecl

TypeDecl     ::= "type" Ident TypeParams? "=" Type ";"
DistinctDecl ::= "distinct" "type" Ident "=" ScalarType ";"
TypeParams   ::= "<" TypeParam ("," TypeParam)* ">"
TypeParam    ::= Ident ["extends" Type]

FunctionDecl ::= "function" Ident TypeParams?
                 "(" Params? ")" ":" Type Block
Params       ::= Param ("," Param)* [","]
Param        ::= Ident ":" Type

TopBindingDecl ::= "const" Bind [":" Type] "=" Expr ";"
BindingDecl  ::= ("const" | "let") Bind [":" Type] "=" Expr ";"
Bind         ::= Ident | ObjectBind | ArrayBind
ObjectBind   ::= "{" BindField ("," BindField)* [","] "}"
BindField    ::= Ident [":" Ident]
               | String ":" Ident
ArrayBind    ::= "[" Ident? ("," Ident?)* "]"

Block        ::= "{" Stmt* "}"
Stmt         ::= BindingDecl
               | FunctionDecl
               | LValue "=" Expr ";"
               | Expr ";"
               | IfStmt
               | "for" "(" ("const" | "let") Bind "of" Expr ")" Block
               | "assert" Expr ["," Expr] ";"
               | "return" [Expr] ";"
               | "break" ";"
               | "continue" ";"
               | Block
IfStmt       ::= "if" "(" Expr ")" Block ["else" (Block | IfStmt)]
LValue       ::= Ident | MemberExpr | IndexExpr

Expr         ::= Literal
               | Ident
               | ArrayExpr
               | RecordExpr
               | Template
               | UnaryExpr
               | BinaryExpr
               | CallExpr
               | MemberExpr
               | IndexExpr
               | MatchExpr
               | ArrowExpr
               | JSXExpr
               | "(" Expr ")"

ArrayExpr    ::= "[" [ArrayItem ("," ArrayItem)* [","]] "]"
ArrayItem    ::= Expr | "..." Expr
RecordExpr   ::= "{" ["..." Expr ","] [RecordField
                  ("," RecordField)* [","]] "}"
RecordField  ::= Ident [":" Expr] | String ":" Expr
PropertyName ::= Ident | String
CallExpr     ::= Expr TypeArgs? "(" [Args] ")"
Args         ::= Expr ("," Expr)* [","]
TypeArgs     ::= "<" Type ("," Type)* ">"
MemberExpr   ::= Expr ("." | "?.") Ident
IndexExpr    ::= Expr "[" Expr "]"
ArrowExpr    ::= "(" [ArrowParams] ")" "=>" (Expr | Block)
ArrowParams  ::= ArrowParam ("," ArrowParam)* [","]
ArrowParam   ::= Ident [":" Type]
MatchExpr    ::= "match" "(" Expr ")" "{"
                  MatchArm+ [DefaultArm] "}"
MatchArm     ::= "when" Pattern ":" Expr [","]
DefaultArm   ::= "default" ":" Expr [","]
Pattern      ::= Literal | "{" PatternFields "}"
PatternFields ::= PatternField ("," PatternField)* [","]
PatternField ::= PropertyName ":" Literal

Type         ::= Primitive
               | LiteralType
               | Ident TypeArgs?
               | Type "[]"
               | "readonly" Type "[]"
               | TupleType
               | RecordType
               | FunctionType
               | Type "|" Type
               | Type "&" Type
               | TemplateLiteralType

Primitive    ::= "unknown" | "never" | "undefined" | "null"
               | "boolean" | "number" | "string" | "Bytes"
LiteralType  ::= String | Number | "true" | "false"
TupleType    ::= ["readonly"] "[" [Type ("," Type)* [","]] "]"
RecordType   ::= "{" [RecordTypeField (";" RecordTypeField)* [";"]] "}"
RecordTypeField ::= ["readonly"] PropertyName ["?"] ":" Type
FunctionType ::= TypeParams? "(" [Params] ")" "=>" Type
ScalarType   ::= "number" | "string"
```

The normative parser specification must define precedence, associativity,
automatic semicolon behavior if any, numeric literals, string escapes, Unicode
identifiers, templates, patterns, and TSX without relying on JavaScript as an
implicit specification.

## 9. Surface elaboration

The advanced surface is intentionally richer than the executable kernel.

| Surface form | Canonical elaboration |
|---|---|
| type annotations and aliases | erased after producing checked type evidence |
| constrained generics | checker instantiation, then erasure |
| contractive recursive aliases | finite named type graph, then erasure |
| `distinct type` | nominal checker identity plus specified base-value constructor |
| optional member access | evaluate receiver once, branch on `null` or `undefined` |
| nullish coalescing | evaluate left once, branch on `null` or `undefined` |
| pipe | direct call with the prior value as the first argument |
| record spread | allocate fixed target shape, copy one base, write explicit fields |
| array spread | finite snapshot concatenation |
| destructuring | temporary binding plus fixed reads |
| `match` | one scrutinee temporary plus ordered tested branches |
| `assert` | branch to continuation or typed halt/return |
| `for...of` | finite snapshot plus index-controlled core loop |
| array higher-order function | typed finite fold with explicit callback call |
| `Result` | tagged record union |
| `Dict` | immutable intrinsic with specified ordering and equality |
| TSX | calls to specified `h` and `Fragment` intrinsics |
| `parallel` / `race` | explicit structured-effect operation |

Each elaboration is validated independently. A surface form does not need its
own SMT theory when its elaboration theorem reduces it to already specified
core behavior.

## 10. Executable semantic kernel

The kernel should be smaller than the parser IR and stable across surface
syntax improvements.

### 10.1 Kernel operations

The kernel needs only:

- constants and local load/store
- lexical block and closure creation
- fixed-arity call and return
- primitive unary and binary operations
- fixed-shape record allocation, field read, and field write
- array allocation, index read, index write, and length
- immutable `Dict` operations
- immutable `Bytes` operations
- conditional branch and jump
- explicit halt and resource fault
- capability call
- structured parallel and race operation

`match`, `for...of`, optional access, pipe, spread, destructuring, JSX,
`Result`, and higher-order array methods are surface or library constructs,
not distinct semantic foundations.

### 10.2 Machine state

An execution configuration is:

```text
<code, environment, heap, call-stack, capabilities, effect-trace, cost>
```

The small-step relation produces one of:

```text
next(configuration)
return(value, effect-trace, cost)
halt(typed-fault, effect-trace, cost)
```

Recoverable application errors are ordinary `Result` values and do not appear
as a fourth control channel.

The semantics MUST define:

- numeric corner cases
- Unicode and byte operations
- evaluation order
- allocation and identity
- aliasing and mutation
- bounds errors
- call-stack behavior
- resource exhaustion
- capability denial
- structured-concurrency cancellation
- observable response and effect traces

### 10.3 Determinism

Pure kernel evaluation is deterministic.

Capability evaluation is deterministic relative to:

- the declared module contract,
- the ordered replay input,
- the runtime policy,
- and the selected resource limits.

An undeclared effect, replay mismatch, contract mismatch, or unknown module
causes a fail-closed runtime or verification result.

## 11. Loops, recursion, and proof scope

The old northstar joined three different questions:

1. Does the compiler preserve the meaning of a construct?
2. Does the program terminate?
3. Can the verifier enumerate every execution state?

The advanced profile separates them.

### 11.1 Translation correctness

Loops and calls are validated by a step-indexed forward simulation or an
equivalent inductive relation. The validation does not unroll the whole
program.

This can prove:

> For every source step represented by the admitted profile, compiled
> execution takes corresponding bytecode and VM steps with the same observable
> result or fault.

It does not by itself prove that either execution terminates.

### 11.2 Totality

A totality claim requires:

- finite snapshot iteration,
- no reachable recursive call cycle, or a proved decreasing measure,
- total called intrinsics under their preconditions,
- and resource bounds sufficient for the proved execution.

Failure to prove totality is not a compiler crash and is not silently accepted
as proof. It is an unavailable property with a precise explanation.

### 11.3 Cost

A cost claim is a symbolic function of input measures and capability-contract
costs.

- a literal tuple may have a constant bound,
- an input array may have a linear bound in its validated length,
- recursion may have a recurrence only when a decrease is proved,
- an unconstrained input produces no finite absolute bound.

A runtime fuse enforces a ceiling. It does not prove the claimed worst case.

## 12. Restriction-to-theorem matrix

Not every restriction is logically necessary for every proof. The profile
keeps some cuts because one explicit form is easier to read and maintain.

| Excluded or constrained feature | Primary boundary protected | Nature of the decision |
|---|---|---|
| `eval`, dynamic import, reflection, `Proxy` | closed program and semantics coverage | essential until a closed dynamic-code model exists |
| ambient async and Promise scheduling | deterministic replay and finite scheduler state | essential until an explicit scheduler is specified |
| mutable live iteration | loop finiteness and stable cost | replaced by snapshot iteration |
| unchecked recursive cycle | totality and bounded cost | recursion runs, but these claims require evidence |
| native module with unbound contract | effect and authority integrity | essential |
| class, prototype, `new`, dynamic `this` | explicit state, dispatch, and effects | canonical simplicity, not a theorem of impossibility |
| throw and try/catch | typed visible failure paths | canonical simplicity; `Result` is the one error form |
| while and C-style for | explicit iteration domain | canonical simplicity plus easier termination analysis |
| `for...in` and dynamic record keys | deterministic order and fixed shape | replaced by `Dict` and explicit key lists |
| regex literal or ambient `RegExp` | predictable resource use and analyzable validation | use string operations or schema validation |
| `any`, assertions, `satisfies` | type evidence integrity | essential to the selected checker model |
| loose equality and implicit coercion | visible type-directed branches | essential to sound narrowing |
| ternary, compound assignment, default/rest parameters | one canonical spelling | language-simplicity choice |
| interface, enum, namespace, decorator | one closed data and module model | language-simplicity choice |
| object methods, getters, setters | explicit functions and effects | language-simplicity choice |

This matrix MUST be generated from the versioned profile registry once that
registry exists. A restriction list that omits the strict canonical rules is
not a complete machine-readable profile.

## 13. Assurance architecture

### 13.1 Three artifacts, not one overloaded receipt

The toolchain may emit:

1. **Build report** - compilation inputs, checks run, warnings, unsupported
   claims, and hashes. It is useful evidence but not proof.
2. **Checked report** - every required audit ran, but some theorem obligations
   may rely on trusted automation or may be inconclusive. It is not a proof
   certificate.
3. **Proof certificate** - every obligation for named properties is present
   and independently accepted under a closed certified profile.

Only the third artifact may use `certified`, `proved`, or
`proof-carrying`.

For a proof certificate:

- the solver or proof checker is available,
- every required obligation is present,
- `proved == total`,
- there are zero unknown, timeout, disabled, malformed, or solver-error
  outcomes,
- every admitted reachable node, opcode, intrinsic, and module boundary is
  covered,
- every declared exclusion and trusted assumption is bound into the artifact,
- and an independent verifier accepts the bundle.

An `unknown` result is not evidence of falsehood, but it is verification
failure for the requested certificate.

### 13.2 The theorem chain

The certificate names every edge and its assurance method:

```text
source bytes
  -> parsed and checked surface
  -> elaborated semantic kernel
  -> optimized kernel IR
  -> bytecode
  -> VM transitions
  -> response and effect observations
```

For each edge, the certificate states one of:

- proved by a named proof object,
- independently translation-validated,
- tested but not proved,
- or trusted as part of the TCB.

No end-to-end label may be stronger than the weakest required edge.

### 13.3 Certificate bundle

The canonical bundle binds:

- profile identifier and complete member registry
- source and resolved module-graph digests
- type-checker, parser, elaborator, optimizer, code generator, and target
  configuration
- semantic-kernel and generated-view digests
- optimized IR and bytecode digests
- VM and runtime-policy digests
- standard-library and native-module contract digests
- native implementation or isolation identities
- capability policy and replay model
- property set and resource bounds
- complete canonical obligation set
- proof objects or constrained solver results
- solver or checker identity and configuration
- explicit assumptions, exclusions, and TCB

Hashes without authenticated retrieval and reconstruction are insufficient.

### 13.4 Independent verification

The verifier:

1. selects the deployment artifact and trust root independently,
2. parses a closed, versioned bundle schema,
3. enforces size, count, depth, time, memory, and output limits,
4. recomputes every artifact digest,
5. reconstructs obligations from authenticated semantics and artifacts,
6. checks exact obligation coverage,
7. checks proof objects with a small kernel or runs constrained canonical SMT
   in an isolated process,
8. rejects missing, extra, unknown, timed-out, or unsupported obligations,
9. checks profile, module, runtime-policy, and deployment identity,
10. verifies provenance only after semantic and bundle checks are complete.

Producer-supplied unrestricted SMT-LIB is never executed directly.

A signature proves provenance, not correctness. The trust policy therefore
defines trusted issuers, pinned or transparent keys, authorization, rotation,
revocation, compromise recovery, freshness, and anti-rollback behavior.
Fetching a key from the same untrusted origin as the bundle does not establish
trust.

### 13.5 Native modules

A native module is either:

- an explicit member of the trusted computing base, with authenticated
  manifest and implementation digests, or
- isolated behind an enforcing process or Wasm boundary whose capabilities
  and observations match the contract.

A self-asserted manifest is not proof. Unknown modules and implementation-to-
manifest mismatches fail closed.

## 14. Readiness gates

The advanced profile is ready to ship only when all gates are true.

### 14.1 Language gate

- One machine-readable registry enumerates grammar features, canonical rules,
  types, intrinsics, value kinds, opcodes, and module forms.
- The parser, checker, documentation, diagnostics, and formal coverage consume
  or validate against that registry.
- Accepted object methods, accessors, or other forms cannot disappear during
  code generation.
- Generic functions instantiate soundly and never fall back to `unknown`.
- `Result`, `Dict`, recursive aliases, `null`, `Bytes`, higher-order arrays,
  and structured-I/O tuples are fully typed.

### 14.2 Application corpus gate

At least one end-to-end application for each target class in Section 2:

- compiles under only `zts-advanced-1`,
- passes type and policy checks,
- runs through its main success and failure flows,
- has boundary and replay tests where effects occur,
- and contains no bypass from the exclusion list in Section 2.

The corpus MUST include:

- recursive JSON or tree data,
- keyed aggregation with `Dict`,
- typed validation failure with `Result`,
- typed parallel I/O,
- a TSX comparison using normal source order,
- mutation during `for...of` proving snapshot behavior,
- accepted structural recursion and a rejected or unproved non-decreasing
  recursion case.

### 14.3 Semantics gate

- Every profile member has an explicit semantic disposition.
- Every reachable core operation and bytecode opcode is specified.
- Generated readable, executable, and proof views are drift-gated per member,
  not only by count.
- Front-end elaboration, optimization, code generation, VM execution, heap
  behavior, and module boundaries are represented in the theorem chain.

### 14.4 Certificate gate

- A real independent consumer exists before certificate production is called
  shipped.
- The consumer reconstructs obligations and binds the exact deployment
  artifact.
- Inconclusive solver results fail certificate issuance and acceptance.
- The module and signer trust models are explicit.
- Hostile-bundle resource limits and solver isolation are tested.

## 15. Feature ledger

### Keep

- `const` plus necessary `let`
- named functions and direct typed callbacks
- lexical closures
- fixed records, arrays, tuples, and limited spread/destructuring
- strict operators, optional chaining, nullish coalescing, and pipe
- `if`, `match`, `assert`, snapshot-finite `for...of`
- static named modules
- aliases, unions, intersections, literals, readonly, optionals, nominal
  types, guards, utility types, and proof/effect capsules
- TSX as pure elaboration
- explicit capability modules and structured I/O

### Add or complete

- sound generic-function inference and instantiation
- limited `extends` constraints
- contractive recursive aliases
- precise `Result<T, E>`
- immutable deterministic `Dict<K, V>`
- immutable `Bytes`
- opaque typed `HtmlNode` and finite `HtmlChild`
- explicit JSON `null`
- a typed, resource-bounded JSON codec
- fully typed finite array operations
- tuple-preserving `parallel` and tagged `race`
- precise minimum HTTP, WebSocket, queue, and durable-workflow ABIs
- snapshot semantics for every finite traversal
- property-specific proof grades and an independent certificate verifier

### Tighten

- reject object methods, getters, and setters at the parser boundary
- treat reusable arrows as named functions
- reject ambient time, random, logging, and I/O
- reject unchecked trapping operations at untrusted boundaries
- make a closed profile registry the source of truth
- distinguish accepted recursion from proved termination
- classify the existing 10-node and 7-opcode semantics as a partial slice
- treat the removed signed receipt as historical, not shipped

### Keep excluded

- classes, inheritance, constructors, prototypes, and dynamic receivers
- exceptions
- ambient async, promises, generators, and detached tasks
- unbounded source loops and user-defined iterators
- dynamic imports, eval, reflection, proxies, and side-effect imports
- loose equality, implicit coercion, mutation shorthand, and assignment
  expressions
- dynamic record keys, deletion, and shape mutation
- regex literals and ambient regex construction
- `any`, type assertions, `satisfies`, and TypeScript type metaprogramming
- enums, namespaces, decorators, interfaces, and overload sets
- mutable module-global application state

## 16. Worked examples

### 16.1 Typed error flow

```ts
import { err, ok } from "zttp:result";

type DivideError = { kind: "division-by-zero" };

function divide(
  numerator: number,
  denominator: number,
): Result<number, DivideError> {
  if (denominator === 0) {
    return err({ kind: "division-by-zero" });
  }

  return ok(numerator / denominator);
}

function describeRatio(numerator: number, denominator: number): string {
  const result = divide(numerator, denominator);
  return match (result) {
    when { ok: true }:
      `ratio ${result.value}`
    when { ok: false }:
      "undefined ratio"
  };
}
```

### 16.2 Keyed aggregation

```ts
import {
  dictEmpty,
  dictGet,
  dictSet,
} from "zttp:collections";

function frequencies(words: readonly string[]): Dict<string, number> {
  let counts = dictEmpty<string, number>();

  for (const word of words) {
    const previous = dictGet(counts, word) ?? 0;
    counts = dictSet(counts, word, previous + 1);
  }

  return counts;
}
```

### 16.3 Recursive application data

```ts
import { dictEntries } from "zttp:collections";

type JsonValue =
  | null
  | boolean
  | number
  | string
  | readonly JsonValue[]
  | Dict<string, JsonValue>;

function depth(value: JsonValue): number {
  if (value === null) {
    return 1;
  }
  if (typeof value === "boolean") {
    return 1;
  }
  if (typeof value === "number") {
    return 1;
  }
  if (typeof value === "string") {
    return 1;
  }

  if (Array.isArray(value)) {
    let maximum = 0;
    for (const child of value) {
      const childDepth = depth(child);
      if (childDepth > maximum) maximum = childDepth;
    }
    return maximum + 1;
  }

  let maximum = 0;
  for (const entry of dictEntries(value)) {
    const childDepth = depth(entry[1]);
    if (childDepth > maximum) maximum = childDepth;
  }
  return maximum + 1;
}
```

This function is accepted. Its totality certificate depends on the checker
proving that recursive calls receive strict subvalues of a finite input.

### 16.4 Explicit effects

```ts
import { env } from "zttp:env";
import { fetch } from "zttp:fetch";
import { parallel } from "zttp:io";
import { err } from "zttp:result";
import type { FetchError } from "zttp:fetch";
import type { Effects } from "zttp:types";

type LoadError =
  | FetchError
  | { kind: "missing-config"; name: string };

function loadUser(): Result<Response, LoadError> {
  const url = env("USER_URL");
  if (url === undefined) {
    return err({ kind: "missing-config", name: "USER_URL" });
  }
  return fetch(url, {});
}

function loadOrders(): Result<Response, LoadError> {
  const url = env("ORDER_URL");
  if (url === undefined) {
    return err({ kind: "missing-config", name: "ORDER_URL" });
  }
  return fetch(url, {});
}

function loadDashboard(): Effects<
  readonly [
    Result<Response, LoadError>,
    Result<Response, LoadError>,
  ],
  "env" | "network"
> {
  return parallel([loadUser, loadOrders]);
}
```

The tuple remains typed. The effect ceiling remains visible. No Promise or
ambient scheduler enters the program.

## 17. Final northstar

The strongest defensible destination is:

> Every accepted ZTS application is checked against one small, versioned
> source profile. Every admitted surface construct elaborates into a closed
> semantic kernel. Every certified property names its assumptions and covers
> every reachable kernel and module operation. A separate verifier rebuilds
> and checks the proof against the exact deployment artifact. Missing coverage
> and inconclusive automation fail closed.

This is more useful than minimizing syntax until applications become awkward,
and more honest than calling a partial or inconclusive check complete.

The language stays small where smallness compounds:

- one data-contract form,
- one recoverable-error form,
- one multi-way branch,
- one source loop,
- one absence convention,
- one dynamic keyed collection,
- one structured-concurrency model,
- one explicit path for effects.

It grows only where application evidence demands real expressive power:

- parametric reuse,
- recursive data,
- typed errors,
- keyed state,
- binary data,
- JSON fidelity,
- and compositional effects.

That is the balance `zts-advanced-1` should preserve.

## Sources inspected

- `docs/zts-formal-spec-northstar.html`
- `docs/zts-formal-spec-design.html`
- `docs/typescript.md`
- `docs/typescript-patterns.md`
- `docs/feature-detection.md`
- `docs/canonical-profile.md`
- `docs/restrictions-to-proofs.md`
- `docs/verification.md`
- `packages/zts/src/parser/ir.zig`
- `packages/zts/src/parser/parse.zig`
- `packages/zts/src/parser/codegen.zig`
- `packages/zts/src/type_pool.zig`
- `packages/zts/src/type_env.zig`
- `packages/zts/src/type_checker.zig`
- `packages/zts/src/strict_checker.zig`
- `packages/zts/src/spec_discharge.zig`
- `packages/zts/src/semantics.zig`
- `packages/zts/src/semantics_check.zig`
- `packages/zts/src/builtins/root.zig`
- `packages/zts/src/builtins/result.zig`
- the live `zts meta`, `features`, `restrictions`, `modules`, and `spec-check`
  JSON surfaces
- representative handlers under `examples/`
- language-design commits `79e93b36`, `5eefe15a`, `8a4d71df`, `f785d45d`,
  and `3b39eec`
- receipt-removal commit `9fb471dd`

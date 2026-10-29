---
name: canonical-style
description: Write handler code in the one-way ZigTS profile. One canonical spelling per operation; the compiler rejects the rest.
---
ZigTS already cuts most of TypeScript. The one-way profile cuts further: for every operation there is exactly one canonical spelling, and the compiler rejects the alternates as ZTS6xx errors. Before writing or rewriting a handler, call `zts_expert_query` with `describe_rule` or `features` for the live rule set rather than answering from memory.

## Canonical forms

| Task | Canonical form |
|---|---|
| Handler / helper declaration | Named `function name(...): Return { ... }` with explicit parameter and return types |
| Local callback | Arrow function only when passed directly as a value |
| Binding | `const` by default; `let` only when reassigned |
| Absent value | `undefined` only |
| Branching | `if`/`else` for guards, `match` for closed alternatives, `c ? a : b` for a two-way choice between pure values |
| Iteration | `for (const item of items)` over a finite collection |
| Errors | `Result<T>` values plus explicit `.ok` checks. See "Result checks" below |
| External effects | `Effects<T, "...">` on public helpers that touch capabilities |
| Proof obligations | Ambient `Proof<T, P>` on handlers and helpers that participate in declared proofs |
| Module imports | Named imports from a literal `zttp:*` or registered `zttp-ext:*` specifier |
| Module exports | Statically named `export function` or `export const`; no default or mutable exports |
| Capability keys | String literals or compiler-visible `const` literal aliases |
| Arithmetic update | `x = x + 1`; never `x += 1` or `x++` |
| Function call args | Positional. No `f(...args)` spread |
| Object spread | Leading position only: `{...base, x: 1}` - never `{x: 1, ...base}` |
| Destructuring | Refused. Bind the source to a name, then read each member explicitly: `const a = obj.a;` |
| Default parameter | Explicit `undefined` check in the body, not `(a: T = default)` |
| Optional parameter | `(a: T | undefined)`, not `(a?: T)` |
| Array type | `T[]` or `readonly T[]`, never `Array<T>` or `ReadonlyArray<T>` |
| Ignored result | Evaluate the call as a statement; use `undefined` for absence, never `void` |
| Match catch-all | `default:`, never `when _:` |
| Inert statements | Remove `debugger;` and standalone `;` statements |
| Text construction | Refused: template interpolation and string `+`. Build a string array with explicit `String(...)` conversions and call `.join("")` |
| Fallback | `??` for nullish defaults. Never `||` unless both operands are boolean |
| Possibly undefined value | Bind it to a `const`, then check `=== undefined` before you read it. Or write `x?.prop` and `x ?? fallback`. An index read `xs[i]` is `T | undefined` |
| Parsed request body | `decodeJson(schema, req.body ?? "")`. Or `isDict(v)`, then `dictGet(v, key)` from `zttp:collections`. Never `v.name` on a parsed JSON value |

Most rows have a corresponding diagnostic and the compiler rejects violations. Truthy `||` fallback is already rejected by the boolean-only operator contract.

## Before / after pairs

### Avoidable `let` (ZTS604)
```ts
// before
let x = 1; return x;

// after
const x = 1; return x;
```

### Arrow helper that is reused (ZTS608)
```ts
// before
const parseUser = (input: Input): User => makeUser(input);

// after
function parseUser(input: Input): User {
  return makeUser(input);
}
```

### Exported function-valued `const` (ZTS609)
```ts
// before
export const handler = (req: Request): Response => Response.json({ok: true});

// after
export function handler(req: Request): Response {
  return Response.json({ok: true});
}
```

### Effectful ternary arm (ZTS612)

A two-way choice between pure values is the canonical spelling, not a form to
avoid: idiom `idiom.two-way-pure-selection` prefers `c ? a : b` over a two-arm
match. `const status = ok ? 200 : 500;` is idiomatic and trips nothing. The rule
fires only when an arm does work rather than naming a value.

```ts
// before
const status = ready ? load() : fallback;

// after - bind the effectful call first
const loaded = load();
const status = pickStatus(ready, loaded, fallback);
// or use match over the condition for an effectful two-way choice
```

### Chained ternary (ZTS621)

A conditional expression may not be an arm of another conditional expression.

```ts
// before
const tier = a ? 1 : b ? 2 : 3;

// after - one scrutinee under match, or an if/else chain in a named function
function pickTier(a: boolean, b: boolean): number {
  if (a) { return 1; }
  if (b) { return 2; }
  return 3;
}
const tier = pickTier(a, b);
```

### Compound assignment (ZTS613)
```ts
// before
count += 1;

// after
count = count + 1;
```

### Non-leading object spread (ZTS614)
```ts
// before
const next = {status: "ok", ...base};

// after
const next = {...base, status: "ok"};
```

### Spread in function call (ZTS616)
```ts
// before
send(...args);

// after
send(args[0], args[1], args[2]);
// or widen the signature: function send(args: SendArgs): Response
```

### Explicit parameter absence (ZTS054 and ZTS055)

Default parameters and `name?: T` are not part of the core profile. Name
absence in the type, pass it explicitly, and resolve any default at the start
of the body.

```ts
function greet(name: string | undefined): string {
  const resolved = name ?? "world";
  return resolved;
}
greet(undefined);
```

### Declaration binding reads
```ts
const user = payload.user;
const name = user.name;
for (const item of items) {
  use(item);
}
```

Do not use object or array declaration destructuring, including renamed
bindings. Bind one source value and read fields or indexed elements explicitly.

### Boolean compared to a boolean literal (ZTS620)
```ts
// before
if (ready === true) { ... }
if (ready === false) { ... }

// after
if (ready) { ... }
if (!ready) { ... }
```
Only flagged when `ready` is statically boolean: `x === true` is exactly `x` and `x === false` is exactly `!x`. For a non-boolean `x` the comparison is an identity check, not a truthiness test, so the rule does not fire there.

## Result checks

The proof accepts one way to use a Result. Keep each Result in one `const` that is bound directly to the call. Check `.ok` with `if (!r.ok)` or `if (r.ok)` in the function that reads it. After the check, pass `r.value`, not `r`.

```ts
const parsed = requestJson(req);
if (!parsed.ok) {
  return Response.json({ error: parsed.error }, { status: 400 });
}
const body = parsed.value;
```

Pass the Result itself only to a `zttp:result` function that takes a Result: `unwrapOr`, `collectAll` with an array literal, and `andThen` or `orElse` with an expression-bodied arrow. Read `.error` only after the failure check, or write `parsed.error ?? fallback`.

Do not use `match`, `=== true`, `isOk()`, or `isErr()` on a Result. Do not copy a Result into another name, return it, store it in an object or an array, or spread it. Do not read `.value` from a call that you did not bind, such as `requestJson(req).value`. A closure needs its own `.ok` check.

## Values that may be undefined (ZTS309)

A field read, index read, spread, or `for...of` on a value whose type admits `undefined` is refused. This covers an index read `xs[0]`, an optional field, a `p?.q` result, an array callback parameter, and a union member that lacks the field. At run time a member read of `undefined` gives `undefined`, so the response drops or misreports the field. A call on `undefined` fails with HTTP 500.

```ts
// before
const user = getUser(); return Response.text(user.name); // user may be undefined

// after
const user = getUser();
if (user === undefined) {
  return Response.json({ error: "not found" }, { status: 404 });
}
return Response.text(user.name);
```

Bind an index read to a `const` first: `const first = ps[0];`, then `if (first === undefined) return ...;`. The check does not cover a read on an `unknown` value, `req.headers`, `req.query`, `req.params`, or a `null` value.

## Reading a parsed JSON value (ZTS201)

The `.value` of `requestJson`, `parseJson`, and `parseJsonBytes` is a JSON value. A field read on it, and any member or index read on a Dict, is refused. Read the body with a schema:

```ts
const parsed = decodeJson("item", req.body ?? "");
if (!parsed.ok) {
  return Response.json({ error: parsed.error }, { status: 400 });
}
const item = parsed.value;
return Response.json({ name: item.name });
```

To read without a schema, check `isDict(v)`, then call `dictGet(v, "name")`, which `zttp:collections` exports. When the fields of a fetch response matter, pass `.text()` to `decodeJson`. Do not read fields from `.json()`.

## Working rules for the agent

1. Always consult live tools for rules and modules. Never answer language or module questions from memory: call `zts_expert_query` with `describe_rule`, `features`, or `modules`.
2. Run `zts_expert_canonicalize` against any file you edit before claiming the edit is done. The veto path rejects anything that introduces new violations.
3. For optimizations, call `zts_expert_query` with `effects` first. Include the proof-card delta in the reply.
4. When the user asks about syntax that is rejected, cite the ZTS code and the canonical form from this skill.

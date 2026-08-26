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
| Errors | `Result<T>` values plus explicit `.ok` checks |
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

## Working rules for the agent

1. Always consult live tools for rules and modules. Never answer language or module questions from memory: call `zts_expert_query` with `describe_rule`, `features`, or `modules`.
2. Run `zts_expert_canonicalize` against any file you edit before claiming the edit is done. The veto path rejects anything that introduces new violations.
3. For optimizations, call `zts_expert_query` with `effects` and `ratchet` first, then include the proof-card delta in the reply. The loop emits a system note if you skip this step.
4. When the user asks about syntax that is rejected, cite the ZTS code and the canonical form from this skill.

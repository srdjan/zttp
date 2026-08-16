# zts-advanced-v2.1

**Status: draft. Nothing here is implemented, and no rule below is enforced by
the compiler.** This file stages the next language increment on top of
`zts-model-1`. More features are coming; each lands as its own section with the
same shape, and a section leaves this file when it either ships or is refused.

Read [zts-formal-spec-northstar-advanced.md](zts-formal-spec-northstar-advanced.md)
first. That document is the northstar for the implemented profile. This one is
narrower: it proposes changes to that profile, states what each buys, and
records the measured cost of adopting it.

Nothing here changes the published identities. `zts-model-1` and `zts-tsx-1`
stay the source profiles until a section ships and the phase that ships it moves
them.

---

## 1. Declared types at the exported boundary

### 1.1 Rule

An exported function's parameter types and return type must be `nominal` or
`structural` declarations. A raw built-in scalar in either position is refused.

```ts
nominal UserId = string;
nominal DisplayName = string;

// refused: both positions are raw
export function greet(name: string): string { ... }

// admitted
export function greet(name: UserId): DisplayName { ... }
```

The brand is erased at comptime. `UserId` is a `string` below the checker, so
the rule adds no representation and costs nothing at runtime. That is the
intent, and section 1.2 records the part of it that does not hold yet.

### 1.2 Blocking prerequisite: `nominal` has no construction path

Measured against the compiler as it stands, not assumed. A nominal value cannot
be produced by any spelling:

| Spelling | Type checker | Runtime |
|---|---|---|
| `const id = UserId("u-1");` | accepted, infers `UserId` | **faults**, `error.NotCallable` |
| `const id: UserId = "u-1";` | **refused**, `type '"u-1"' is not assignable to type 'UserId'` | never reached |

The constructor form is recognized in `type_checker.zig:2717`, which answers the
call's static type from the alias table. Nothing lowers it, so it reaches
codegen as an ordinary call to a name no function defines and the handler faults
at the first request. The annotation form is refused by assignability, which is
the brand working exactly as designed.

The consequence is that `nominal` is consume-only today: it can be declared and
named in a parameter position, and no program can produce a value to pass there.
Zero tracked `.ts` and `.tsx` sources declare one, and every `nominal` test in
`type_checker.zig` asserts a refusal or the constructor's static type. None runs
one.

**This rule cannot ship before that is fixed**, because the rule's whole effect
is to make branded types mandatory at the boundary. Making a consume-only type
mandatory would make every exported function uncallable.

The fix is a lowering decision, and the draft does not pick one:

- lower the constructor to the identity function, so `UserId(x)` compiles to `x`
  and the brand stays purely static; or
- admit the annotation form for a literal whose base type matches, so
  `const id: UserId = "u-1"` checks and no constructor is needed.

The first keeps one visible construction site, which suits an agent reading a
diff. The second removes a call the reader has to know is free. Either closes
the gap; shipping both would give one operation two spellings, which design law
4.2 argues against.

**Resolved by measurement, in favour of the second.** `parser/codegen.zig` holds
`node_types` as an optional, and the only caller of `setNodeTypes` in the tree is
`packages/tools/src/precompile.zig:2026`. Type information reaches the generator
on the precompile path and nowhere else, so a constructor erasure keyed on it
would work under `zttp build` and fault under `zttp dev`. The implementation plan
is
[2026-08-16-030-boundary-types-plan.md](plans/2026-08-16-030-boundary-types-plan.md).

### 1.3 Scope

The rule binds **exported** functions only, in both parameter and return
position. A module-internal function keeps raw built-ins.

This mirrors the split the profile already draws for capability ceilings:
ZTS610 demands an `Effects<...>` on an exported function with a nonempty
inferred row, and ZTS623 refuses one on an internal function, because the
compiler infers the internal row and the handler's budget already bounds it. The
same argument holds for types. An exported signature is a contract another file
reads; an internal one is a detail the checker re-derives at every call site.
Keeping one story about where declarations are owed is worth more than the extra
coverage a whole-program rule would buy.

### 1.4 What counts as raw

Refused in an exported signature:

- the scalars `string`, `number`, `boolean`
- `object` and `unknown`
- an array or readonly array whose element type is one of those: `string[]` is
  refused, `UserId[]` is admitted

Admitted:

- any `nominal` or `structural` declaration, and an array of one
- the fixed application ABI from spec 7.2: `Request`, `Response`, `Bytes`,
  `Dict<K, V>`, `JsonValue`, and `Result<T, E>`. These are the boundary types
  the runtime owns. Requiring an alias over them would break every handler
  signature in the repository and buy no identity the ABI does not already have.
- a literal union such as `"GET" | "POST"`, which already names a closed set.
  The rule exists to close open sets; a literal union is not one.

### 1.5 The `boolean` amendment

`nominal` admits only a `string` or `number` base today. The stripper reports
`nominal_base_not_scalar` on anything else, with the message "a nominal
declaration carries scalar identity only; its base must be `string` or
`number`".

That makes the rule unstatable for `boolean`: a boolean parameter could satisfy
it only by being wrapped in a `structural` record, which forces a record shape on
the most common scalar and reads badly beside a branded string.

This section therefore proposes widening the nominal base set to
`string | number | boolean`, and updating the ZTS048 message with it. The change
is one condition in the stripper's scalar check. It does not widen nominal to
records, tuples, unions, or functions: those keep `structural`, and the reason
ZTS048 exists is unchanged.

### 1.6 Diagnostics

`ZTS000` through `ZTS060` are taken. This section proposes:

| Code | Fires on | Repair |
|---|---|---|
| `ZTS061` | a raw built-in scalar, `object`, `unknown`, or an array of one, in an exported function's parameter or return type | declare a `nominal` or `structural` alias and name it in the signature |

`ZTS048` keeps its code and gains `boolean` in its admitted base set.

`ZTS061` is mechanically repairable only in part. The compiler can name the
position and the base type; it cannot choose the alias name, and a wrong name is
worse than none. The repair intent should therefore carry the position and the
base and ship advisory-only, in the `.none` method class D3 already blesses for
a rewrite that is not an equivalence.

### 1.7 What it buys

Set collapse at the one boundary that composes. Two exported functions taking
`string` are indistinguishable to a caller, to the analyzer, and to the agent;
two taking `UserId` and `DisplayName` are three distinct facts. The type checker
already refuses a cross-nominal assignment and refuses a raw literal where a
nominal is declared, so the identity is enforced the moment it is written. What
this rule adds is that it must be written.

It is also what would give `nominal` its first real consumer. The form has
shipped, is tested, and is used by nothing: the measured cost below finds zero
authored declarations. A type nobody declares is a type whose construction path
nobody noticed was broken, which is how section 1.2 went unobserved.

For the agent specifically: the emittable set for a call argument narrows from
"any string expression" to "an expression of this brand", which is the same
mechanism typed holes use, applied to signatures instead of expressions.

### 1.8 Measured cost

Over the 128 tracked `.ts` and `.tsx` files there are 189 annotated function
declarations, 34 of them exported. Ten exported signatures would trip `ZTS061`.

Two are authored source, both in `examples/handler/utils.ts`:

- `greet(name: string): string`
- `formatJson(data: object): string`

The other eight are recorded model turns inside two corpus cases,
`sibling-helper` and `sibling-helper-holes`, each recorded against both the
DeepSeek and the local provider. Every one is the same signature,
`displayName(name: string): string`, in a `lib/settings.ts` the case's workspace
carries.

**That second number is what gates this section.** A cassette pins the exact
request that produced it, and the veto verdict is part of the recorded turn. A
new rule that fires inside a recorded workspace changes that verdict, so both
cases go stale and neither can be repaired by hand: they need a live re-record
against each provider. See
[Cassette Recording](internals/cassette-recording.md).

So the migration is two edits and a four-artifact re-record, not two edits.
Sequence it with other corpus-invalidating work rather than spending a recording
run on it alone.

Both authored edits also need section 1.2 closed first. `greet` and
`formatJson` take and return values their callers construct from literals, and
today no literal can become a branded value.

### 1.9 Open

- Whether a `structural` alias over a bare scalar (`structural Name = string;`)
  satisfies the rule, or whether a scalar brand must be `nominal`. Admitting the
  structural form is more permissive and gives a second spelling for one
  operation, which design law 4.2 argues against. Refusing it means the rule
  also decides which constructor a scalar brand uses.
- Whether the rule extends to exported `const` declarations, which are the other
  thing a module publishes.
- Whether a generic parameter (`export function first<T>(xs: T[]): T`) is
  admitted. `T` is neither raw nor declared, and a caller instantiating it with
  `string` would route around the rule.
- Whether `ZTS061` belongs in the restriction registry, which would move
  `restriction_matrix_hash` and add a row to
  [Restrictions to Proofs](restrictions-to-proofs.md), or only in the rule
  registry, which moves `policy_hash`. The two identities answer different
  questions and this rule arguably belongs in both.

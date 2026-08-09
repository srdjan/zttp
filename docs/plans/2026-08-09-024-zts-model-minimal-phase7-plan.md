# Phase 7: Model-Minimal ZTS - Direct Cutover Plan

**Goal:** Replace the remaining TypeScript compatibility surface with one
explicit, model-oriented language profile. The result keeps the application
expressiveness Zttp needs while removing equivalent spellings, JavaScript
coercions, parser macros, and declarations whose meaning depends on compiler
heuristics.

**Timing:** Start after phase 6 exits. Phases 4 through 6 keep their current
scope and numbering.

**Exit:** The repository accepts `zts-model-1` core source and the optional
`zts-tsx-1` frontend, every removed form has one diagnostic and one preferred
repair, all tracked source has migrated, the compiler contains no dead runtime
or IR support for the removed forms, and live-model flows meet the convergence
gates in this plan.

**Cutover:** This is a breaking profile change. There is no compatibility
profile, warning period, or dual grammar. Migration support consists of
compiler-authored repairs that produce the new source form before the old
parser and checker paths are deleted.

**Source of truth:**
[zts-formal-spec-northstar-advanced.md](../zts-formal-spec-northstar-advanced.md)
revision 4 remains the semantic base. This plan supersedes its TypeScript
spellings and resolves the migration-policy deferral for `interface`, `|>`,
`pipe()`, and `guard()`.

**Assumptions:** No published compatibility promise requires the old source
grammar. The supported-model set will be frozen before phase 7 starts. Phase 6
will deliver the generated grammar, examples, and decision registries that this
phase extends.

## Locked decisions

| Area | Decision |
|---|---|
| Profile | Publish `zts-model-1` as the only core source profile |
| Type declarations | `structural Name = Type;` and `nominal Name = string;` or `nominal Name = number;` |
| Nominal scope | Scalar identity only. Records, tuples, functions, unions, booleans, generics, and capabilities cannot be declared nominal |
| Compatibility | Direct cutover with no legacy profile |
| Core files | `.ts` only |
| UI frontend | `.tsx` is accepted only through `zts-tsx-1`, then lowered to core |
| Text | Double-quoted literals, `String(value)`, and string-array `join`; no template interpolation or string `+` |
| Conditions | Boolean values only. No general truthiness or operand-returning boolean semantics |
| Proof types | Ambient `Proof<T, P>` and `Effects<T, R>`; remove `Spec` and `zttp:types` |
| Entry point | One unexported named `handler` function |
| Imports and exports | Named forms only. Import aliases stay because real module names collide |
| Runtime | No compatibility lowering for removed syntax after migration |

## Why another reduction is justified

The current profile still spends compiler and model attention on choices that
do not add application power.

The strongest example is truthiness. The formal spec already requires boolean
conditions, boolean-operator operands, and predicate results. The live boolean
checker admits numbers, strings, optional strings, optional objects, and
`unknown`. The type checker narrows an optional value by removing only `null`
or `undefined`, while the runtime also treats `0` and `""` as false. A bare
optional-string condition therefore has different useful readings in the
checker and runtime. Requiring `value !== undefined`, `text !== ""`, or
`count !== 0` removes that ambiguity.

Several other forms disappear before any proof pass can observe them. The
parser lowers `|>`, `pipe()`, and `guard()` into calls and arrows. They are
alternate authoring routes to ordinary control flow, not distinct semantics.
`void` is mutually assignable with `undefined`. `interface` duplicates record
aliases for application data, then adds a hidden exception: an all-function
interface becomes nominal. The `in` operator is accepted but absent from the
formal binary-operator contract. Keeping these forms enlarges the language and
the trusted implementation without enlarging the set of programs Zttp needs.

### Fable validation snapshot

The 2026-08-09 Fable audit covered 85 tracked handler and fixture files: 55
examples, 5 Pi-vendored or model-output files, and 25 tests. It also inspected
24 unique final apply-edit sources from the committed model cassette.

| Finding | Tracked source | Final model source | Decision |
|---|---:|---:|---|
| `interface` declarations | 5, versus 61 `type` aliases | 0 interfaces, 12 aliases | Replace both with `structural` |
| Non-boolean conditions | 11 | 0 | Enforce boolean-only conditions |
| Explicit `undefined` comparisons | 27 | 10 | Keep the explicit form |
| Object shorthand | 47 reviewed uses; 45 in examples and 2 in Pi source | 34 uses in 9 of 24 sources | Remove, but give it an exact mechanical repair |
| TSX | 6 files, all real JSX | 0 | Keep as an optional lowering frontend |
| `.js` and `.jsx` source | 0 | 0 | Reject them |
| Default-exported handler | 2 embedded tests, no tracked handler | 0 | Require an unexported named `handler` |
| `Array<T>` or `ReadonlyArray<T>` | 0 | 0 | Keep only `T[]` and `readonly T[]` |
| Optional-parameter shorthand | 0 | 0 | Use `T | undefined` |
| Destructuring rename | 0 | 0 | Use explicit member reads |
| Fallback `assert` | 1 feature probe | 0 | Use `if` plus early return |

Import aliases are not redundant. The module surface contains a real `send`
collision between `zttp:queue` and `zttp:websocket`, so named imports keep the
`import { send as queueSend }` form.

The audit measures what existing code and recorded models use. It does not by
itself prove that a new dialect will converge. The model gates below separate
first-draft behavior from eventual compiler-guided convergence.

## Core declaration contract

The canonical grammar is:

```text
StructuralDecl ::= "structural" Ident TypeParams? "=" Type ";"
NominalDecl    ::= "nominal" Ident "=" ("string" | "number") ";"
```

Examples:

```ts
structural User = {
  id: UserId;
  name: string;
};

structural Result<T, E> =
  | { ok: true; value: T }
  | { ok: false; error: E };

nominal UserId = string;
nominal RetryCount = number;
```

`structural` creates a transparent alias. Assignability depends only on the
resolved type structure. It introduces no runtime value.

`nominal` creates a distinct scalar identity and a compile-time constructor of
the same name:

```ts
nominal UserId = string;

const id: UserId = UserId(request.params.id);
```

The constructor:

- accepts exactly the declared base type;
- evaluates its argument once;
- returns the unchanged runtime value;
- adds type identity, not validation;
- cannot be called through `import type`.

Two nominal declarations over the same base are not mutually assignable. A
nominal value remains assignable to its base when the existing advanced type
contract permits unwrapping, but the raw base and another nominal identity are
not assignable to it.

`export nominal UserId = string;` exports both the type identity and its
constructor. A normal named import brings both namespaces into scope. An
`import type` brings only the identity. `export structural User = ...;` is a
type-only export, and consumers use `import type`.

The compiler rejects nominal declarations over records, tuples, functions,
unions, generic parameters, `boolean`, capabilities, and other nominal types.
Runtime, extension, and built-in capabilities remain compiler-owned opaque
types. Application source cannot mint one by choosing a declaration spelling.

The following repairs are exact:

```ts
type User = { id: string };
// structural User = { id: string };

interface User { id: string }
// structural User = { id: string };

distinct type UserId = string;
// nominal UserId = string;
```

The interface repair is available only for the closed subset already admitted
as application data. Open interfaces, merging, `extends`, and declaration
augmentation remain unsupported rather than being guessed into an alias.

## Proof and effect types

Proof wrappers become ambient checker types:

```ts
function handler(request: Request): Proof<Response, "no_secret_leakage"> {
  return Response.text("ok");
}
```

`Proof<T, P>` replaces `T & Spec<P>`. `Effects<T, R>` remains the explicit
effect ceiling. Both are checker-only and allocate no runtime object. Remove
`Spec`, the `zttp:types` virtual module, and the repeated source import:

```ts
import type { Spec, Effects } from "zttp:types";
```

The grammar and meta payload identify which names are ambient. Prompts and
examples must not teach the removed import as boilerplate.

## Source frontends

Core compilation accepts `.ts` under `zts-model-1`. It rejects `.js`, `.jsx`,
and JSX tokens in a core source file.

`.tsx` uses `zts-tsx-1`:

1. strip TypeScript types while preserving JSX;
2. lower JSX to the existing `h(...)` representation;
3. pass the lowered source through `zts-model-1`;
4. compose both source maps for diagnostics and proof receipts.

Compiled artifacts record the frontend profile and grammar hashes as well as
the core profile hash. TSX is therefore a distinct source frontend with one
lowering contract, not a second core grammar. After migration, delete JSX
tokens, nodes, and code generation from the core parser. The flow checker
continues to understand the lowered `h(...)` and `renderToString(...)` calls.

## Canonical core syntax

### Keep

- named imports and named exports, including import aliases;
- one unexported named `handler` function;
- top-level `const` and local `let` only for bindings that are reassigned;
- `T[]` and `readonly T[]`;
- optional record fields;
- generic named functions and explicit call-site type arguments when inference
  is insufficient;
- direct calls, numeric `+`, `??`, and static optional member access
  (`value?.field`);
- pure `condition ? whenTrue : whenFalse`, `if`, `match`, and `for...of`;
- `null` and `undefined` as distinct values;
- explicit object properties such as `{ id: id }`;
- double-quoted string literals;
- invariant assertions whose failure is a defect.

Every `if`, `else`, and `for...of` body uses braces. Every statement uses a
semicolon. Match arms end in commas. The only catch-all match arm is
`default:`.

Inline callbacks use a block and an explicit return:

```ts
const names = users.map((user) => {
  return user.name;
});
```

Reusable helpers are named functions. Generic arrows and expression-bodied
arrows are not part of the core profile.

### Remove and repair

| Removed form | Canonical replacement |
|---|---|
| `type X = T` | `structural X = T;` |
| `interface X { ... }` | `structural X = { ... };` |
| `distinct type X = string` | `nominal X = string;` |
| default exports and exported handlers | unexported named `handler` |
| `export let` | top-level `const`, or move mutation into a local scope |
| `Array<T>` and `ReadonlyArray<T>` | `T[]` and `readonly T[]` |
| `void` type | `undefined` |
| `void expression` | evaluate the expression explicitly, then use `undefined` only if a value is required |
| `value?: T` parameter | `value: T | undefined` |
| default parameter | explicit default in the function body |
| declaration destructuring | named binding plus explicit member reads |
| destructuring rename | explicit member read |
| object shorthand `{ id }` | `{ id: id }` |
| computed record key `{ [key]: value }` | `Dict` construction or a fixed key |
| `a |> f`, `pipe(...)`, `guard(...)` | direct calls and explicit guard flow |
| `zttp:compose` | ordinary named functions |
| `in` | the explicit predicate for the value kind, such as `dictHas` |
| unary `+` on a number | the number expression without `+` |
| unary `+` as coercion | an admitted boundary parser; implicit numeric coercion is refused |
| optional call `f?.()` | explicit absence check and direct call |
| optional computed access `value?.[key]` | explicit absence check, then indexed access |
| general truthiness | explicit boolean comparison |
| operand-returning `&&` and `||` | boolean operands and boolean result |
| template interpolation | string-array `join` |
| string `+` | string-array `join` |
| fallback `assert(condition, response)` | `if` plus early return |
| `when _:` | `default:` |
| empty statements and `debugger` | remove them |
| automatic semicolon insertion | explicit semicolons |
| `.js` and `.jsx` source | `.ts`, or `.tsx` through `zts-tsx-1` |

Normal indexed access such as `items[index]` remains. Only its optional
computed variant is removed.

### Boolean-only control flow

Conditions in `if`, `assert`, and `?:`, operands of `!`, `&&`, and `||`, and
predicate callback results have type `boolean`. `&&` and `||` therefore return
`boolean`, not one of their operands.

```ts
if (token !== undefined) {
  useToken(token);
}

if (name !== "") {
  log(name);
}

if (retryCount !== 0) {
  retry();
}
```

A bare condition remains canonical only when its type is already boolean,
including a boolean discriminant such as `result.ok`. The checker never treats
`unknown`, a number, a string, an object, or an optional value as a condition.

### Explicit guard flow

Guard composition becomes ordinary control flow:

```ts
function authorize(request: Request): Response | undefined {
  if (!request.authenticated) {
    return Response.text("unauthorized", { status: 401 });
  }
  return undefined;
}

function handler(request: Request): Response {
  const refused = authorize(request);
  if (refused !== undefined) {
    return refused;
  }
  return route(request);
}
```

Feature detection must inspect this behavior, not the presence of a compose
import. Rate-limit detection, for example, follows the explicit early-return
flow and `cacheIncr` behavior.

### Text construction

`+` is numeric only. Text construction uses explicit parts:

```ts
const message = ["Hello ", name, ". Attempts: ", String(count)].join("");
```

This gives each conversion one meaning. It also avoids the runtime split where
`+` can mean arithmetic or concatenation and template children can stringify a
boolean differently from JSX.

## Compiler and tooling work

### 1. Publish the profile authority

After phase 6 has made grammar, examples, ambient names, and decisions
registry-generated, amend the formal spec with this profile and add
`zts-model-1` and `zts-tsx-1` to those registries. Meta publishes:

- the profile and grammar hash;
- every production and restriction;
- ambient names and constructibility;
- declaration identity and assignability rules;
- one canonical example for each form;
- diagnostic IDs and exact repairs;
- the TSX lowering profile and its hash.

No prompt, SDK, or documentation page carries a hand-written copy of this
contract. They consume generated material or fail the drift gate.

### 2. Add explicit structural and nominal declarations

Update the tokenizer, stripper, type map, type environment, type keys, checker,
canonicalizer, diagnostics, and module import/export path.

`TypeMapKind` gains `structural_decl` and `nominal_decl`. The type environment
uses explicit structural and nominal tables. Remove the interface table and the
all-function-interface nominal heuristic. A nominal constructor participates
in both local and imported value resolution while retaining its type identity.

Tests cover parsing, stripping, source maps, assignability, constructor
evaluation-once behavior, import/export namespaces, cross-module identity,
invalid bases, and exact old-to-new repairs.

### 3. Split TSX from core

Make stripping-with-JSX-preservation and JSX lowering an explicit frontend
pipeline. Compose source maps and include both profile hashes in precompile,
runtime, cache, receipt, and module-graph identities. Delete core JSX parsing
and code generation after every tracked `.tsx` source passes through the new
frontend.

### 4. Migrate the repository before rejection

Migrate examples, tests, fixtures, Pi prompts, canonical examples, scaffolds,
SDK source snippets, module signatures, and user documentation. Generated
files change only through their owning generator.

During this step, recognition-only migration paths may parse a removed form far
enough to emit a bound diagnostic and repair. They do not create core IR. Once
the repository has zero removed forms, switch those paths to refusal and delete
the former runtime, checker, and code-generation machinery.

Exact transformations such as alias keywords, semicolons, braces, array type
spelling, object shorthand, and double-quoted strings apply without a model
turn. Judgment-bearing changes such as guard flow or text decomposition remain
compiler proposals that a model can inspect and simulate.

### 5. Enforce the smaller grammar

Each removed form has:

- one stable diagnostic ID;
- one explanation tied to the violated production or restriction;
- one preferred replacement, or a fail-closed refusal when no exact repair is
  possible;
- a half-open source span and source digest;
- a repair bound to the profile, policy, and module-graph hashes.

The parser must not silently accept an old form and rely on a later checker to
notice it. The semantic registry must cover every reachable node and opcode,
including frontend lowering operations, or record a narrow trusted reason.

### 6. Delete the dead surface

Delete parser precedence and desugaring for `|>`, the `pipe()` and `guard()`
macros, interface resolution, general-truthiness branches, string-add code
paths, runtime template lowering, core JSX nodes, `void` aliases, removed
syntax tests, and the `zttp:compose` and `zttp:types` modules.

The final tree contains no dormant compatibility flag or unused legacy
profile. Tests that only prove removed syntax still works are replaced with
refusal and repair tests.

## Model behavior and onboarding

Models begin with a strong TypeScript prior. They do not update their weights
during a Zttp session, so a custom grammar will initially produce predictable
TypeScript leaks. The first-draft pass rate can fall, especially for smaller
models. Final convergence can still improve because the compiler offers fewer
choices and every rejected form points to one replacement.

The current system already injects the expert skill, live rule snapshots,
canonical normal form, feature and module matrices, and canonical examples.
Phase 6 is scheduled to replace the remaining prose-only grammar, examples,
and decision sections with machine-readable registries. Phase 7 depends on that
work rather than teaching the dialect through another manually maintained
prompt.

The likely easy repairs are declaration keywords, braces, semicolons, and array
type spelling. The likely repeated leaks are object shorthand, declaration
destructuring, concise arrows, template strings, string `+`, truthiness, and
implicit guard composition. The model contract must show those forms in real
handler examples rather than only list them as prohibitions.

Before generation, Pi injects a compact dialect card containing:

1. the profile and grammar hashes;
2. the small set of core rules relevant to the requested task;
3. canonical `structural` and `nominal` declarations;
4. three complete handlers: ordinary JSON, explicit guard flow, and TSX;
5. the exact text-construction and boolean-condition forms.

The loop simulates every draft before apply. Exact repairs apply without
another model turn. Other diagnostics return one canonical alternative and ask
the model to repair only the named span. The project keeps `.ts` and `.tsx`
extensions because a new extension would not teach the grammar and would lose
editor and model priors that remain useful.

Do not fine-tune first. Ship the generated dialect card, exact diagnostics,
simulation, and compiler repair, then collect live failure data. Fine-tuning is
justified only if the same non-mechanical leak remains common after those
controls.

## Verification contract

### Deterministic coverage

Tests must cover:

- structural transparency, recursive aliases, generics, and type-only imports;
- nominal identity, base assignability, constructor evaluation once,
  cross-module imports, and every invalid base;
- boolean-only conditions and operators, including optional strings, empty
  strings, zero, objects, and `unknown`;
- explicit guard flow and behavioral feature detection;
- numeric `+`, rejected string `+`, rejected templates, and canonical `join`;
- core `.ts`, rejected `.js` and `.jsx`, TSX lowering, composed source maps,
  and profile hashes in receipts;
- one exact diagnostic and repair for every removed form;
- zero removed forms in tracked source;
- every reachable node and opcode classified by `spec-check`.

Upgrade `spec-check` before claiming the exit. A green result over a small
fraction of nodes or opcodes is not evidence that the reduced language is
specified. Every reachable item must be specified, translation-validated, or
explicitly trusted with a reason.

### Fable and live-model coverage

Use complete propose, check, repair, prove, execute, and intent flows. Sequence
fixtures and deterministic stand-ins prove the harness path, not model
behavior. Only a recorded live model can publish first-draft, intent, or
round-trip measurements.

Freeze a pre-cutover baseline for the same prompts and models. The current
recorded corpus includes a Sonnet 4.6 row at 100% first-draft pass over 20 cases
with 100% intent pass over 14 intent checks. The existing 16-case tier
comparison also shows why eventual convergence must be separate: Sonnet passed
15 of 16 first drafts and Haiku 4 of 16, while both reached green in all 16
cases.

Run paired pre-cutover and `zts-model-1` flows. Accept the phase only when:

- handler behavior, contracts, effects, labels, proof verdicts, and intent
  results match the pre-cutover cases;
- exact alias and syntax repairs consume no model turn;
- judgment-bearing repairs reach green within two model repair turns;
- every supported model reaches green on every valid case;
- no case reaches green by dropping a requested behavior;
- tracked final source contains zero removed forms;
- replay stays a regression ratchet and never substitutes for a new live row.

Measure first-draft pass, reached-green rate, median model repair turns,
compiler-authored repair share, and intent pass separately. A lower first-draft
rate is acceptable during the cutover only when reached-green and intent stay
at 100% and the failures identify a finite, actionable prompt or diagnostic
gap.

## Delivery order

1. Complete the phase 6 exit and freeze its grammar, meta, and normalization
   hashes.
2. Amend the formal spec and add `zts-model-1`, `zts-tsx-1`, and their generated
   authority.
3. Implement `structural`, `nominal`, and nominal import/export behavior.
4. Split TSX lowering from the core parser and bind both profiles into
   artifacts and receipts.
5. Add exact migration diagnostics and repairs.
6. Migrate all source, prompts, SDK examples, fixtures, and documentation.
7. Enforce the smaller grammar and delete the dead compiler and runtime
   machinery.
8. Run deterministic, Fable, and paired live-model validation.
9. Regenerate owned artifacts and run the full repository gates.

## Required gates

```sh
zig build test-zts
zig build test-precompile
zig build test-canonicalize
zig build test-agent-protocol
zig build test-zruntime
zig build test-simulator
zig build test-contract-golden
zig build test-module-boundary
zig build test-proof-swallow
./zig-out/bin/zts spec-check --json
bash scripts/test-examples.sh
bash scripts/verify.sh
zig build test
```

Run the convergence and coverage generators only when their owned sources have
changed. Never edit their generated Markdown or JSON output by hand.

## Risks and stop conditions

The main product risk is model regression from leaving TypeScript's training
distribution. The mitigation is not a legacy grammar. It is a short generated
dialect card, exact repairs, simulation before apply, and a measured live-model
gate. Stop the cutover if a supported model cannot reach green without dropping
intent after two judgment-bearing repair turns.

The main compiler risk is keeping recognition machinery that accidentally
remains executable. Migration parsing must not construct core IR, and the exit
requires its deletion.

The main proof risk is claiming a smaller trusted language while `spec-check`
covers only a fraction of reachable semantics. The phase cannot exit until the
coverage denominator is the reachable language and every item has an explicit
classification.

The main frontend risk is losing diagnostic locations through two lowering
passes. TSX does not ship until composed source maps point every parser,
checker, and proof diagnostic back to the original `.tsx` span.

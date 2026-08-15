# ZTS advanced formal-spec northstar

**Status:** proposed language and assurance profile  
**Profile name:** `zts-advanced-1`  
**Grounded against:** ZTS 0.18.0, policy 2026.04.2, 2026-07-30  
**Revision:** 4, 2026-07-30. Revision 2 applied the multi-lens design review:
stronger `match`, effect-aware `Result` combinators, a completed pure
standard surface, decidable canonical-choice rules, and a closed
agent-protocol contract. Revision 3 pushed the canonical-form law to "each
thing exactly one way" and added the rewrite table that would have been
needed to enforce it. Revision 4 refines that law to Zig's "there is an
idiomatic way to do it": the table becomes an idiom table, non-idiomatic
spellings stay legal and advisory, and idiom becomes machine-discoverable
because an agent-first language cannot inherit idiom from a community
(Section 4.2).  
**Relationship to the earlier northstar:** this document replaces its design
claims, not its historical record. The earlier artifact remains useful context,
but it does not define the advanced profile.

## 1. Decision

ZTS should be an AI-minimal, agent-first application language whose canonical
source remains readable and maintainable by humans.

The target is:

> An agent can discover the complete language profile, generate one canonical
> TypeScript-lexical source form, receive deterministic machine-actionable
> repairs, and independently check the result. A human can read and maintain
> that same source without decoding an agent-only notation.

AI-minimal does not mean code-golfed source or the fewest characters. It means
the least choice entropy, hidden context, and repair ambiguity consistent with
general application programming:

- one meaning and one preferred spelling for each admitted operation,
- a bounded grammar and type system discoverable from the compiler,
- explicit data, control flow, effects, failure, and capability use,
- deterministic normalization and exact repairs where a mechanical repair is
  safe,
- and structured refusal where the compiler lacks enough semantic information.

The design priority is:

1. reliable agent discovery, generation, repair, and verification,
2. closed semantics and explicit authority,
3. human readability as a hard constraint,
4. application expressiveness justified by a versioned corpus.

ZTS is not a TypeScript compatibility profile. It is a distinct constrained
language that reuses familiar TypeScript lexical and layout conventions when
they preserve one clear meaning. A `.ts` or `.tsx` transport does not imply
that arbitrary TypeScript is accepted.

This profile therefore makes five decisions:

1. Add one constrained pure conditional operator, add no new control-flow
   statements, and remove redundant control-flow shorthand.
2. Complete the existing type system instead of importing TypeScript's
   type-level programming language.
3. Put common application power in pure, typed data abstractions and explicit
   capability modules.
4. Make the versioned compiler-in-the-loop protocol part of the language
   contract rather than optional tooling.
5. Separate language acceptance from proof claims. An accepted program may
   run even when termination or a cost bound is unproved. A proof certificate
   may never hide that gap.

### 1.1 Syntax budget

| Area | Advanced-profile decision |
|---|---|
| New statement keywords | None |
| New control-flow operators | Pure boolean `condition ? value : value` |
| Removed redundant forms | Pipe composition and fallback `assert` |
| Restored data literals | `null`, only as an explicit value |
| Removed parameter syntax | Defaults and `name?: T`; absence is `T | undefined` and resolved in the body |
| Added pattern syntax | Binding fields and type-test patterns in `match` |
| Added type syntax | Bounded generic parameters with `extends` |
| Added type capability | Sound function generics and contractive recursive aliases |
| Added pure abstractions | `Result<T, E>`, `Dict<K, V>`, immutable `Bytes`, `HtmlNode` |
| Added concurrency model | None; retain explicit `parallel` and `race` |
| Added error channel | None; errors remain ordinary tagged values. `Result` combinators are effect-row polymorphic, not a new channel |
| Agent-only source notation | None; machine metadata remains separate JSON |
| Agent protocol | Versioned discovery, diagnostics, repair simulation and application, normalization, and verification |
| Canonical formatting | One deterministic, idempotent human-readable layout |

The executable kernel grows only for `null`, `Dict`, `Bytes`, and array
append. Generic constraints, recursive aliases, `Result`, and the new match
patterns are erased or elaborate to existing records, unions, calls, and
branches.

## 2. Application envelope

The primary product envelope is one complete agent loop. Given a user goal and
no hidden profile knowledge, an agent can:

1. discover the language, policy, modules, effects, restrictions, and tool
   schemas,
2. generate canonical source,
3. resolve and bind its complete module graph,
4. check it through a stable JSON interface,
5. trace each failure to a rule and source span,
6. simulate, validate, and atomically apply any exact mechanical repair,
7. normalize to a deterministic fixed point,
8. recheck and verify the requested properties,
9. or return a structured unsupported result without guessing.

Application breadth is the evidence used to expand or reject language
features. It is not allowed to outrank the integrity of this loop.

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
- undocumented syntax or behavior that an agent must infer from examples
- parser-specific source rewrites such as reversing an ordinary comparison in
  TSX
- native modules introduced only to compensate for a language gap
- unchecked dynamic property access
- trapping operations on attacker-controlled input
- an unexplained or mislabeled proof gap
- manual human correction of profile syntax within the declared agent repair
  budget

## 3. Current baseline and the gap

The live compiler already has most of the right shape:

- block-scoped `const` and necessary `let`
- named functions, direct arrow callbacks, lexical closures, and recursion
- records, arrays, tuples, fixed-shape mutation, explicit member reads, spread,
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
currently rejects forms including ternaries, compound assignment, call spread,
non-leading object spread and
reusable function-valued constants. The advanced profile reassesses each form
under the agent-first decision rule rather than treating every current
restriction as permanent.

The important gaps are not more loop or class syntax:

1. Generic function syntax is accepted, but sound instantiation and inference
   are incomplete.
2. Dynamic keyed data has no supported typed collection. Internal JavaScript
   `Map` and `Set` implementations existed but were never reachable, and have
   since been removed.
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
10. Current return-coverage analysis can label a recursive function `total`,
    and the cost path can label it bounded without a decreasing argument.
11. Current path generation summarizes a `for...of` body once but may label
    the resulting branch skeleton exhaustive.
12. A caller-supplied extension manifest is not yet authenticated and bound to
    a runtime implementation, so its declared effects cannot support a proof.
13. Several current UI and upgrade summaries use proof-certificate language
    for structural or textual evidence that has no independent verifier.
14. The live CLI already exposes JSON metadata, feature and module discovery,
    diagnostics, repair simulation, canonicalization, and normalization, but
    the language profile does not yet bind them into one versioned agent
    protocol.
15. Diagnostic suggestions, exact repair intents, rule descriptions, and
    normalization traces exist across separate surfaces. Their identifiers,
    compatibility rules, and convergence guarantees are not yet one stable
    agent-facing contract.

The advanced profile treats those facts as its starting point.

## 4. Design laws

Every feature admitted to the profile must satisfy all applicable laws.

### 4.1 AI-minimality

A feature is minimal when an agent needs the fewest independent decisions to
use, diagnose, transform, and verify it correctly. Token count alone is not a
minimality measure.

For each proposed feature, the profile must account for:

- how an agent discovers it,
- how many spelling choices it leaves the author,
- what new inference or proof state it adds,
- how failure is identified and repaired,
- and whether the same application need is already expressible by composition.

A familiar TypeScript form SHOULD win when it is equally precise,
deterministic, and verifiable. A ZTS-specific form is justified only when it
materially reduces ambiguity, authority, proof burden, or repair risk.

### 4.2 There is an idiomatic way to do it

For every operation the profile admits, there is one idiomatic way to write
it, and that way is discoverable from the compiler.

This is an existence claim, not a uniqueness claim, and the difference is
deliberate. An earlier formulation of this law demanded that each thing be
expressible exactly one way. That target is unreachable in any language rich
enough to be worth using: a standard library with `map`, `reduce`, and a loop
can express one traversal several ways no matter how the surface is
restricted, and eliminating the redundancy costs more expressiveness than the
uniqueness is worth. Zig's own ethos made the same move, from "only one
obvious way to do things" to "there is an idiomatic way to do it." ZTS
follows it.

The law binds at three levels:

1. **Exclusion.** Where two token-level forms denote the same operation with
   no semantic difference, the profile admits one and rejects the other. A
   rejected form is an error with an exact repair. This is where `switch`,
   compound assignment, `as`, and loose equality live.
2. **Idiom.** Where one operation is reachable through more than one
   composition of admitted forms, one composition is idiomatic. The others
   remain legal: they check, they run, and they mean what they say. They are
   reported as non-idiomatic with the idiomatic form named, at advisory
   severity that never fails a build.
3. **Normalization.** Where the rewrite from a non-idiomatic form to its
   idiom is provably meaning-preserving, `canonicalize` and `normalize`
   perform it, so the author's choice does not survive into the stored
   source. Where it is not provable, the non-idiomatic form stands and the
   advisory remains.

Level 3 is a service, not an obligation. The profile does not require that
every non-idiomatic spelling be mechanically rewritable, because a rewrite
whose precondition cannot be discharged would either change behavior or
block a legal program. What the profile does require is level 2: no
operation lacks a published idiom.

Two words are used precisely throughout this document and are not
interchangeable. **Canonical** describes the output of the formatter and
normalizer, which is unique to the byte and is what identity hashes bind.
**Idiomatic** describes the preferred spelling among admitted alternatives,
which is unique by declaration rather than by exclusion. Canonical source may
still contain a non-idiomatic spelling that no registered rewrite covers.

Examples of level-1 exclusion:

- `match`, not `switch`
- explicit assignment, not compound assignment or increment/decrement
- one pure `?:` two-way value selection; effectful selection uses `if` or
  `match`
- direct named calls, not a custom pipe operator
- `assert` for invariants and `if` plus `return` for expected guards
- named reusable functions, not exported or reusable function-valued
  constants
- `type`, not both `type` and `interface`, for application data contracts
- annotations and narrowing, not `as` or `satisfies`
- `Dict`, not computed keys on shape records

The canonical formatter MUST produce one deterministic, idempotent source
layout. Normalizing canonical source a second time MUST produce identical
bytes.

One adaptation separates this law from its Zig ancestor. A human-facing
language can let idiom live in community convention, style guides, and
reading other people's code. An agent-first language cannot: an agent has no
community and does not read the ecosystem. Idiom that is not machine-readable
is, for the profile's primary consumer, idiom that does not exist. Every
idiom this profile declares MUST therefore be published in the registry and
reachable through `meta`, with a stable identifier, the operation it covers,
its idiomatic spelling, and the non-idiomatic spellings it supersedes. An
agent asks the compiler what the idiomatic form is rather than inferring it
from examples.

#### 4.2.1 The idiom table

Every entry below names one operation, its idiomatic spelling, the
non-idiomatic spellings it supersedes, and the precondition under which a
mechanical rewrite between them preserves meaning.

The precondition governs level 3 only. Where it holds, `canonicalize` and
`normalize` rewrite the non-idiomatic spelling and the author's choice
disappears. Where it does not hold, the idiom still stands and is still
reported, but the source is left alone, because a rewrite that changed
behavior would be worse than a second spelling. `items.indexOf(v) !== -1` is
non-idiomatic on every element type, and is rewritten to `includes` only when
`NaN` cannot distinguish the two equalities.

Rewrites that are emitted carry a registered equivalence validator and are
eligible for automatic application under Section 4.8. The table is
registry-generated and drift-gated; this document is its readable view.

| Operation | Idiomatic spelling | Non-idiomatic | Rewrite precondition |
|---|---|---|---|
| absence default | `x ?? d` | `x === undefined ? d : x`, `x !== undefined ? x : d`, `match (x) { when undefined: d default: x }` | operand type excludes `null` and is neither a generic parameter nor `unknown` |
| absent member read | `x?.f` | `x === undefined ? undefined : x.f` | same as above |
| two-way pure selection | `c ? a : b` | a two-arm `match` over a `boolean` scrutinee whose arms are both pure | none |
| record update | an explicit literal | a leading spread that overrides every field | the spread operand is pure |
| number in text | `` `${n}` `` | `` `${String(n)}` `` | interpolation of a `number` |
| scalar to text | `String(n)` | a template whose entire content is one `number` interpolation | value position outside a template |
| redundant template | the interpolated expression itself | a template whose entire content is one `string` interpolation | value position outside a template, and the interpolation's static type is exactly `string` |
| string concatenation | left-associated `a + b + c` | a template with no literal text and two or more interpolations, all `string` | value position outside a template |
| array concatenation | `[...a, ...b]` | `a.concat(b)` | none |
| membership test | `items.includes(v)` | `items.indexOf(v) !== -1`, `items.indexOf(v) >= 0` | element type excludes `number` (`NaN` distinguishes the two equalities) |
| existence test | `items.some(p)` | `items.find(p) !== undefined` | element type excludes `undefined` |
| dictionary membership test | `dictHas(d, k)` | `dictGet(d, k) !== undefined` | `V` excludes `undefined` |
| Result default | `unwrapOr(r, d)` | `r.ok ? r.value : d`, a two-arm `match` whose arms are the value and a constant | `d` is assignable to `T` |
| Result sequence | `collectAll(rs)` | a `reduce` over `Result` values whose body is `andThen` | the fold has no other accumulator |
| dictionary map | `dictMapValues(d, f)` | an entry round trip through `dictEntries` and `dictFromEntries` that changes only values | the rewrite spans the whole consumption site, including its `Result` handling |
| dictionary filter | `dictFilter(d, p)` | an entry round trip that only drops entries | same as above |
| dictionary fold | `dictFold(d, f, init)` | `dictEntries(d).reduce(...)` | the fold has one accumulator |
| pure single-accumulator fold | `map`, then `filter`, then `some`, then `every`, then `find`, then `findIndex`, then `reduce`: the first that fits | `let` plus `for...of` with no `break`, `continue`, or effect | the body is pure and the loop head is already idiomatic under the element-iteration row |
| pure search loop | `find`, `findIndex`, `some`, or `every`, by what the loop yields and whether its flag starts `false` or `true` | `let` plus `for...of` whose only early exit is `break` | the body is pure, carries one accumulator, uses no `continue`, and the loop head is already idiomatic under the element-iteration row |
| field read | `const id = user.id;`, or `const first = pair[0];` for a tuple | any declaration destructuring pattern | none |
| matched field read | a binding pattern field | a `match` arm that reads the field off the scrutinee | none |
| match binding field name | match shorthand `{ value }` | match pattern `{ value: value }` | none |
| element iteration | `for (const item of items)` | `for...of` over `range(items.length)` whose body only indexes `items` | none |

Three entries are declared preferences rather than derivations, recorded here
so no reader has to infer them:

- `??` and `?.` are idiomatic for `undefined`-absence. The explicit
  comparison is idiomatic wherever they are unavailable: when the operand
  type includes `null` (Section 5.3), when the operand is generic or
  `unknown` and a later instantiation could admit `null`, and in
  `if`-position guards, where the comparison is a narrowing test rather than
  a value selection.
- Array spread is idiomatic for concatenation. `concat` stays in the
  operation set because the live runtime ships it and removing it would
  narrow the baseline, but spread is the familiar TypeScript form under law
  4.1 and generalizes to element-and-array mixtures a two-argument helper
  cannot express, so every `concat` call normalizes to a spread.
- A record spread is idiomatic whenever at least one field is inherited
  unchanged, including when the result type widens the base's type with new
  fields. A spread that overrides every field inherits nothing and is
  rewritten to an explicit literal.

Where a row matches a site, it takes precedence over the branch-selection
rule of Section 5.4, the iteration rule of Section 6.5, and the consumption
procedure of Section 6.1. Those rules choose among forms of equal standing;
this table resolves forms that are not.

Rows compose, so normalization is a fixed-point computation rather than a
single pass: a `let` loop over `dictEntries` becomes a `reduce` by one row
and then `dictFold` by another. Rewrites apply innermost first, so a row that
matches an interpolation fires before a row that matches the enclosing
template, and a row that matches a loop head fires before a row that matches
the loop. The rewrite relation MUST be confluent under that order, including
rows that only become applicable after an earlier rewrite fires: two rewrites
that can match one program reach the same result. Confluence is required of
the relation, not totality of the table, since a row whose precondition fails
emits nothing and leaves a legal non-idiomatic form in place. The profile registry publishes the
maximum pass count, and a second `normalize` of canonical source MUST produce
identical bytes.

A non-idiomatic spelling is never an error and never fails a build. It
checks, runs, and means what it says. The profile reports it at advisory
severity with its idiom named, rewrites it when the rewrite is provable, and
otherwise leaves it in place. This is the cheaper trade in both directions: a
rewrite costs an agent nothing, an advisory costs it one lookup, while an
exclusion would cost a diagnostic, a repair iteration, and a legal program.

### 4.3 Local elaboration

A surface feature should lower locally to a small number of kernel forms. The
lowering must not depend on runtime reflection, prototype lookup, hidden
receiver binding, or ambient scheduling.

### 4.4 Visible control and effects

Every branch, failure path, state write, and external effect must remain
visible in typed IR.

- recoverable failure is `Result<T, E>`
- absence is normally `T | undefined`
- JSON `null` is explicit data, not an implicit optional value
- I/O is a named capability call
- concurrency is an explicit structured operation
- reusable state lives behind a capability, not in a mutable module global

### 4.5 Closed executable semantics

Every source construct admitted to a certified build must map to:

- a specified core operation,
- a specified standard-library intrinsic, or
- a versioned and authenticated external-module contract.

An unknown node, opcode, value kind, callback path, or module call makes the
certified build fail closed.

### 4.6 Proof claims are property-specific

Translation correctness, partial correctness, determinism, totality, cost
bounds, and application policies are different claims.

The compiler must never infer:

- termination from syntax acceptance,
- a cost bound from a runtime fuse,
- module behavior from a self-declared manifest,
- proof from a solver invocation that returned `unknown`,
- end-to-end correctness from a proof over one IR slice.

### 4.7 Human readability is a hard floor

The agent and the human use the same canonical source. ZTS MUST NOT add a
machine-only source encoding, compressed token dialect, positional shorthand,
opaque generated identifiers, or semantics carried only in external metadata.

Canonical source SHOULD preserve:

- domain names rather than synthetic aliases,
- named reusable functions rather than anonymous indirection,
- explicit parameter and return types at public boundaries,
- ordinary block structure and stable indentation,
- intermediate `const` bindings when they make data or effect flow clearer,
- and source-order control flow that can be reviewed without expanding a
  hidden lowering.

Machine detail belongs in versioned JSON. Source remains the durable shared
artifact for agents and humans.

### 4.8 Normative agent protocol

The compiler-in-the-loop interface is part of the advanced language contract.
It is not an optional editor convenience.

The current JSON commands are useful seeds, but their version-1 shapes are not
the advanced protocol. `zts-advanced-1` introduces an explicit version-2
cutover through one canonical CLI transport:

```sh
zts agent --stdin-json
```

The command reads one request object and writes one response object. Existing
commands such as `zts meta --json`, `zts check <file> --json`, and
`zts canonicalize <file> --json --simulate` MAY remain available as explicitly
selected legacy or human-facing interfaces. Their bare arrays and version-1
objects MUST NOT be interpreted as advanced-profile responses.

The request envelope is:

```json
{
  "schema_version": 2,
  "operation": "check",
  "project_root": "/absolute/project/root",
  "input": {
    "file": "dashboard.ts"
  },
  "expected": {
    "profile_id": "zts-advanced-1",
    "policy_hash": "...",
    "module_graph_hash": "..."
  }
}
```

The response envelope is:

```json
{
  "schema_version": 2,
  "operation": "check",
  "profile_id": "zts-advanced-1",
  "compiler_version": "...",
  "policy_version": "...",
  "policy_hash": "...",
  "module_graph_hash": "...",
  "success": false,
  "payload": {},
  "diagnostics": []
}
```

The closed operation set is:

- `meta` for compiler, profile, policy, registry, limits, operation schemas,
  built-in module catalog, idiom table, and verifier discovery,
- `features`, `restrictions`, and `describe_rule` for language discovery,
- `modules` for resolution of one entry file,
- `check` for source, type, effect, policy, and proof diagnostics,
- `canonicalize` for compiler-authored rewrite candidates,
- `simulate_edit` for diagnostic and policy non-regression,
- `apply_repair` for atomic application of exact validated repairs,
- `normalize` for canonical fixed-point validation,
- and `verify` for a set of discovered property identifiers and their
  assurance grades.

`meta.payload.operations` MUST provide the request and response schema for
every operation. `meta.payload.verifiers` MUST enumerate each property
identifier, required inputs, prerequisites, possible assurance grades, and
result schema. An agent never chooses among undocumented verification commands.

The `meta` operation accepts an optional `input.view`. `"full"` is the
default and publishes the complete payload below. `"bootstrap"` publishes
only the complete identity block, grammar and registry hashes, operation identifiers and
input fields, plus the exact request and section list for the full view. The
bootstrap view is the bounded initial agent context; it MUST remain at or
below 8 KiB. This projection does not remove a discovery surface because the
full view remains one explicit `meta` request away.

The full `meta` payload MUST also publish:

- `grammar_hash`: deterministic SHA-256 over every grammar production and its
  enforcement metadata, so a client can bind cached syntax guidance to the
  exact grammar it describes,
- `grammar`: the machine-readable productions of Section 8, member for
  member, registry-generated and drift-gated,
- `source_frontends`: each optional authored-syntax frontend with its profile
  identifier, grammar hash, target core profile and grammar hash, lowering
  target, and machine-readable productions,
- `examples`: one canonical minimal example per admitted surface form,
  registry-generated, so an agent can learn ZTS-specific syntax (`match`,
  `distinct type`, `assert`, `comptime()`, `parallel`) without hidden
  instructions,
- `ambient_names`: the closed table of ambient type and value names from
  Section 6,
- `severities`: the closed diagnostic severity set and the rule that decides
  `success`,
- `idioms`: the Section 4.2.1 table, each entry with a stable identifier, the
  operation it covers, its idiomatic spelling, the non-idiomatic spellings it
  supersedes, and, where a mechanical rewrite exists, that rewrite's
  identifier and equivalence validator,
- `validators`: the registered equivalence validators, each with an
  identifier, the rewrite classes it covers, and its validation method,
- `type_serialization`: the versioned canonical type serialization artifact
  that defines stable type-graph identities (Section 5.4),
- `limits`: resource limits plus the default repair-iteration and tool-call
  budget for the canonical loop,
- and `decisions`: the versioned registry of next-action and
  semantic-decision kinds referenced by unsupported results and explanation
  graphs, each with an identifier and a parameter schema.

A resolved semantic decision re-enters the loop as edited canonical source at
step 2; no separate decision-submission operation exists.

The project root is explicit and canonicalized before any file access. Request
file paths resolve within that root. A relative source-module specifier
resolves against the importing module's canonical directory and MUST remain
within the permitted project boundary. The `modules` operation receives an
entry file and returns:

- the resolved relative module graph and source digests,
- the built-in module registry,
- authenticated `zttp-ext:*` manifests and implementation identities,
- every resolution decision and rejected candidate,
- and one digest of the complete resolved module environment.

Checking, edit simulation, normalization, and verification MUST bind that
complete `module_graph_hash`, not only the context-free built-in catalog.

Within schema version 2, a field cannot be removed, renamed, or given a new
meaning. Optional fields may be added. A breaking change requires a new schema
version selected explicitly by the client. An agent that does not support the
response schema, profile, or identity hashes MUST stop rather than infer a
fallback.

A request with an unsupported `schema_version` receives a minimal response
listing the supported versions. That response shape is frozen: it is identical
across all present and future schema versions, so version negotiation is one
deterministic round trip and the MUST-stop rule always has a recovery path.

Protocol-level failures are not diagnostics. An unknown operation, an
unsupported source extension, an unresolvable or out-of-boundary path, a
malformed request, or an internal fault returns a top-level `error` object with
a stable error code, a message, and the offending request field. The mandatory
diagnostic shape below applies only to source-bound diagnostics.

The `expected` block obeys one rule for every operation: a supplied field that
does not match the recomputed identity fails the request with a stable
staleness error naming the mismatched field and both values. Omitting
`expected` skips the guard. `apply_repair` additionally guarantees that a
mismatch writes nothing.

The agent transport emits only the response JSON on standard output. Logs go
to standard error. Array order, diagnostic order, rewrite order, and serialized
canonical source are deterministic for identical authenticated inputs.

Every diagnostic MUST contain:

- a stable diagnostic code and governing rule identifier,
- severity and success impact. The severity set is closed and
  registry-published: `error` rejects the program, `warning` reports a
  hazard the profile still admits, and `advisory` carries a non-idiomatic
  spelling with its idiom identifier. A response reports `"success": true`
  exactly when it produced no `error` diagnostic, so warnings and advisories
  never fail a build, a check, or the repair loop. Every rule in the registry
  declares the severity it emits, so no severity is admitted by the protocol
  without a rule that uses it,
- source digest plus exact byte span and human line and column,
- a concise message and, when useful, a human explanation,
- effect and proof impact when applicable,
- whether an exact repair is available,
- and either the complete bound mechanical-repair object with its safety
  grade embedded inline, or a structured statement of the semantic decision
  still required. `canonicalize` remains the channel for rewrite candidates
  not attached to a diagnostic.

Prose is never an executable repair. A mechanical repair MUST bind the source
digest, half-open byte span, original span digest or bytes, replacement text,
diagnostic code, rule identifier, repair identifier, equivalence-validator
identity and result, profile identity, policy hash, and module-graph hash. A
diagnostic advertises an exact repair only when a registered equivalence
validator exists for that repair identifier.

Edit simulation establishes diagnostic and policy non-regression. It does not
establish behavioral equivalence. Until a rewrite has a registered equivalence
validator, `canonicalize` and `normalize` MUST report it as a proposed
refactor, not a mechanical repair. A proposed refactor and an unrewritable
advisory are the same state seen from two operations: the source stands, the
preferred form is named, and nothing is applied automatically.

Each `canonicalize` candidate carries a safety grade. An
`equivalence_validated` candidate also carries the named validator, its
authenticated inputs, and its result. Lower grades are never eligible for
automatic application.

The launch validator registry MUST cover at least: layout-only rewrites,
missing-semicolon insertion where the parser admits exactly one insertion
point (the validator is the parser's unique-parse check),
identifier-preserving canonical respellings with a specified local
elaboration, and every rewrite the Section 4.2.1 idiom table emits.
Pre-parse lexical errors carry a dedicated lexical-repair grade
so a file that does not yet parse still has a mechanical exit; no agent or
human hand-fixes profile syntax.

`apply_repair` is stateless and self-contained: it re-runs edit simulation and
equivalence validation internally on the submitted repairs before writing, so
the standalone `simulate_edit` operation is an optional preview, never a
trusted client assertion. One request accepts an ordered set of validated
repairs bound to the same source digest with pairwise non-overlapping spans.
It rechecks every bound identity and span, applies the whole set atomically as
one edit, and returns the new source digest and recomputed complete
module-graph hash. Overlapping spans, cross-digest sets, a mismatch, or a
failed validation reject the whole request and write nothing.

Advanced-profile mechanical normalization MUST be deterministic, terminating,
semantics-preserving, and idempotent. If a rewrite cannot establish those
properties, the compiler rejects it as non-mechanical instead of guessing.

A structured unsupported result is distinct from an invalid program. It names
the unsupported requirement or construct, governing rule when applicable,
source span when available, missing semantic decision or evidence, and allowed
next actions. It never includes a guessed replacement.

The canonical repair loop is bounded:

1. discover the active profile,
2. generate or edit canonical source,
3. resolve and bind the complete module graph,
4. check and classify every diagnostic, collecting the inline bound repairs,
5. optionally preview non-obvious repairs with `simulate_edit`,
6. apply the non-overlapping repair set atomically; `apply_repair`
   revalidates internally,
7. accept the returned post-edit source and module-graph identities,
8. normalize to a fixed point, routing any required rewrite back through
   atomic application,
9. recheck against the latest identities and invoke `verify` with the
   requested property identifiers,
10. stop successfully, or return a structured unsupported result.

`meta.payload.limits` publishes the default maximum repair iterations and
tool calls for the loop; conformance task classes may override the default
inside the 14.2 harness only. Repeated non-advisory diagnostics, stale
edits, a non-convergent normalizer, or an unavailable semantic choice end the
loop explicitly, and each of those four conditions is a machine-detectable response
field, not an inference from response history.

## 5. Normative source profile

The words MUST, MUST NOT, SHOULD, and MAY are normative in this document.

ZTS source is a distinct constrained language with familiar TypeScript lexical
and layout conventions. TypeScript documentation is not an implicit source of
ZTS semantics.

A front end MAY recognize a common noncanonical TypeScript form solely to
produce a targeted diagnostic and the exact canonical alternative. It MUST
NOT silently choose among semantically different lowerings. If there is no
safe alternative, the result names the unsupported construct and the missing
semantic decision.

### 5.1 Modules

The profile permits:

```ts
import { name, other as local } from "./module.ts";
import { fetch } from "zttp:fetch";
import type { Order } from "./order.ts";

export structural User = { readonly id: UserId; name: string };
export nominal UserId = string;
export function loadUser(id: UserId): Result<User, LoadError> { ... }
export const version: string = "1";
```

Rules:

- Imports and exports MUST be statically named.
- A module specifier MUST be a string literal.
- Relative application modules and registered `zttp:*` or `zttp-ext:*`
  modules are permitted.
- Type-only imports are erased.
- Default imports and exports, namespace imports, side-effect
  imports, dynamic imports, and export-star forms are excluded.
- Re-exports are excluded. Importing and then exporting a named declaration
  is also excluded. Consumers import the original declaration, or the module
  author declares an explicit named wrapper with its own type and effect
  contract.
- Module initialization MUST be pure. Handler-reachable mutable module state
  is excluded from the certified profile.
- A top-level value binding MUST use `const`. Reassignment is local to a
  function activation.

### 5.2 Declarations and bindings

The profile permits:

- `const` for every binding that is assigned once
- `let` only when the binding is reassigned
- named function declarations for reusable behavior
- parameters written as `name: Type`, with absence named as `T | undefined`
- direct arrow expressions only as arguments to typed, finite callback APIs
- named bindings followed by explicit member or fixed-tuple index reads
- one leading object spread followed by explicit fields, idiomatic when at
  least one field is inherited unchanged from the base

It excludes:

- `var`
- declaration destructuring and destructuring renames
- rest parameters, default parameters, and optional-parameter shorthand
- function expressions
- reusable or exported arrow helpers
- object methods, getters, and setters
- object literal shorthand and computed record keys
- the `in` operator and unary `+`
- optional calls and optional computed access
- declaration merging

Object literals contain explicit data fields only. Write `{ value: value }`,
not `{ value }`. A fixed-shape record uses literal field names; dynamic keyed
data uses `Dict`. Reusable behavior is a named function with explicit inputs
and outputs.

A default is explicit in the parameter type, call, and function body:

```ts
function pageSize(limit: number | undefined): number {
  const resolvedLimit = limit ?? 50;
  return resolvedLimit;
}
pageSize(undefined);
```

Every call supplies every declared argument. This keeps arity fixed and makes
the absence branch visible to the type checker, verifier, and runtime. The
body may resolve a pure value with `??`, or use explicit `if` flow when the
fallback performs work.

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
  observable `length`, `charAt`, and slicing contract retains ZTS's current
  UTF-16 code-unit model. The formal string library MUST specify the behavior
  of boundaries inside an astral scalar exactly. Numeric bracket indexing of
  strings is excluded.
- `Bytes` is an immutable sequence of octets. Text conversion is explicit and
  returns `Result` when decoding can fail.
- Record shapes are fixed after allocation. Existing writable fields may be
  updated. Fields cannot be added or deleted dynamically.
- A fixed record key that is a valid identifier MUST use the identifier in a
  literal or type and dot access at read and write sites. Any other fixed key
  MUST use a string literal and the same string literal in bracket form at
  read and write sites. Numeric record keys are excluded; use a string key or
  a number-keyed `Dict`.
- Arrays may be locally mutable. `items.push(value)` is the one growth
  operation; it appends in amortized constant time through the kernel append
  operation. Index writes are in-bounds only; writing past the current length
  is a bounds fault, not growth. Aliased or captured mutation is visible as a
  state effect and may prevent purity, determinism, or isolation proofs.
- `Dict` is immutable and has deterministic insertion-order iteration.
- Function and object equality is identity equality. `Dict` keys are
  `string`, `number`, or a `nominal` type over either.
- Array types use `T[]` and `readonly T[]` only. The generic aliases
  `Array<T>` and `ReadonlyArray<T>` are excluded.
- Absence is named `undefined` in both value and type positions. The `void`
  type and unary operator are excluded; an effect whose result is ignored is
  evaluated as its own statement.

`null` and `undefined` remain distinct. Optional chaining and `??` follow
TypeScript nullish behavior and therefore test both. Because that behavior
silently erases the distinction, the rule is compiler-enforced, not
remembered: `??` and `?.` are rejected with a targeted diagnostic and an
exact repair when the static type of the operand includes `null`, or when it
is a generic parameter or `unknown`, since a later instantiation could admit
`null` under source the checker has already accepted. Such a site uses an
explicit `=== null` or `=== undefined` comparison or `match`, so JSON `null`
can never be swallowed by an absence operator.

On concrete types without `null`, `??` and `?.` keep exactly one meaning,
`undefined`-absence handling, and they are the idiomatic spelling of it. An
`undefined` comparison written in value position to select a default or a
member is rewritten to them (Section 4.2.1). The explicit comparison stays
idiomatic in `if`-position guards, where it is a narrowing test rather than a
value selection.

### 5.4 Operators and expressions

The profile permits:

- arithmetic, comparison, bitwise, and boolean operators
- `+` over two `string` operands, yielding `string`, the idiomatic
  concatenation
- strict equality `===` and `!==`
- `typeof` in value position
- direct and optional static member access
- numeric array and tuple indexing
- literal bracket access to a quoted fixed record field
- calls with fixed positional arguments
- array and record literals
- finite array spread
- one leading record spread
- pure template interpolation
- `??` and `?.`
- pure boolean conditional expressions
- `comptime()` over closed, pure expressions
- `match` expressions
- TSX expressions

The profile excludes:

- loose equality
- implicit numeric or string coercion
- unary `+`
- the `in` operator; use the value kind's explicit membership predicate
- assignment in expression position
- compound and logical assignment
- increment and decrement
- comma and sequence expressions
- call spread
- optional calls
- optional computed access
- dynamic record property access
- regex literals and the ambient `RegExp` constructor
- `delete`
- `new`
- `this` and `super`
- `yield`, generators, `async`, `await`, and `Promise`
- unary `void`

Conditions in `if`, `assert`, and `?:`, operands of boolean operators, and
predicate callback results MUST have type `boolean`. There is no general
truthiness conversion.

Narrowing is a closed, normative list. The narrowing tests are: explicit
`===` and `!==` comparison with `undefined`, `null`, or a literal; `typeof`
comparison with a type-name literal; the ambient intrinsic value-kind guards
`Array.isArray`, `isDict`, and `isBytes`; a literal test of a record
discriminant field; a bare read of a boolean record discriminant field; the
negation `!` of any admitted test, which narrows the opposite branches; and a
validated type predicate (Section 5.7). The narrowing positions are: the
branches of `if`/`else`, the branches of `?:`, the arms of `match`, the code
after `assert`, the code after an early `return`/`break`/`continue` guard,
and the right operand of `&&` and `||` over an admitted test. No other
construct narrows. A checked extraction after a discriminant guard (for
example `result.value` after `result.ok === true`, or after
`if (!result.ok) { return ...; }`) is therefore predictable without running
the checker.

`condition ? whenTrue : whenFalse` is the idiomatic two-way pure value
selection. Exactly one branch is evaluated. Both branches MUST be pure and
their result type MUST use the join below. A conditional expression MUST NOT
appear as an arm of another conditional expression, parenthesized or not.
The diagnostic carries an exact repair when a single-scrutinee `match` or a
value-producing `if`/`else` rewrite exists; otherwise it carries a proposed
refactor per Section 4.8, never a guessed rewrite.

Branch selection is a decidable rule rather than a style judgment, so the
idiom for a given shape is looked up, not weighed:

- boolean condition, both branches pure values: `?:`
- boolean condition, either value branch effectful: `match` over the
  condition
- any branch contains statements and no value is selected: `if`
- multi-way value selection over one scrutinee: `match`
- heterogeneous predicate ladder: `if`/`else if`

A `match` over a bare `boolean` scrutinee with pure arms is non-idiomatic and
is rewritten to `?:`. With an effectful arm it is idiomatic, because `?:`
arms MUST be pure and a statement `if` cannot initialize a binding.

The result type is the deterministic join `join(A, B)`:

1. Remove `never`; if both sides were `never`, return `never`, and if one side
   remains, use it.
2. If the types are syntactically identical, use that type. Two unions
   written in different member orders are not syntactically identical and
   fall through to step 3.
3. If both are mutually assignable, use the type of the `whenTrue` branch, a
   syntactic rule a reader can apply without a type-identity oracle.
4. If exactly one type is assignable to the other, use the receiving type.
5. Otherwise form and canonically normalize `A | B`.

Union normalization flattens nested unions, removes `never` and duplicate
canonical type identities, coalesces mutually assignable members to the one
written first, removes a member strictly assignable to another member, and
keeps the remaining members in first-appearance order. Every step is
syntactic, so a reader can compute the normalized union from the source
alone.

Source order is display order only. The canonical type serialization
published through `meta.payload.type_serialization` serializes a union over
its member set, independent of the order in which the members were written,
so `string | number` and `number | string` have one identity and one digest.
That identity keys digests, registry entries, and `Schema<T>` bindings; it
never decides which of two members a reader sees first.
Literals do not widen unless a branch already supplies a receiving wider type.
`null`, `undefined`, distinct types, and generic variables retain their own
identities unless the ordinary assignability rules remove them. A contextual
expected type does not change the join; assignability to it is checked
afterward.

The stable type-graph identity of a type is derived from that canonical
serialization, never from allocation order, and it is an identity rather than
an ordering: no rule in this profile chooses between two types by comparing
their identities. The serialization is a versioned registry artifact
published through `meta.payload.type_serialization`, so an independent
implementation can reproduce every digest.

The pure intrinsic `String(value)` is the explicit conversion from a number or
boolean to text in value position; inside a template, a `number`
interpolation elaborates through the same intrinsic without the wrapper.
Number formatting uses the ECMAScript base-10 shortest-round-trip
representation; negative zero renders as `0`. That intrinsic is the only
scalar-to-text conversion, with those two spellings partitioned by position;
instance `.toString()` conversion is excluded.

Template interpolation MAY contain any pure expression of type `string` or
`number`. A `number` interpolation elaborates through the same implicit
`String` intrinsic as a JSX numeric child; the formatting is fully
deterministic, so the implicit form loses nothing. A `boolean` MUST use
explicit `String(...)`: the JSX child rule renders booleans as no text, so an
implicit boolean conversion would give one value two context-dependent
meanings. An effectful expression MUST be evaluated into a named `const`
before the template so effect order remains visible.

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

Every declaration and statement shown with a trailing semicolon in the grammar
MUST include it. The advanced profile has no automatic semicolon insertion. A
newline never creates a token. A missing semicolon always carries an exact
mechanical repair through the lexical-repair grade of Section 4.8, whose
validator is the parser's unique-parse insertion check, so the strictness
never costs a human or agent a hand edit.

An assignment statement evaluates its target subexpressions left to right and
then the right-hand side. Subexpressions of an assignment target MUST be
pure; an effectful receiver or index is evaluated into a named `const` before
the assignment, the same hoisting rule templates use.

#### `match`

`match` is the only multi-way selection over one scrutinee:

```ts
type Command =
  | { kind: "echo"; text: string }
  | { kind: "ping" };

function run(command: Command): string {
  return match (command) {
    when { kind: "echo", text }:
      text
    when { kind: "ping" }:
      "pong"
  };
}
```

Rules:

- The scrutinee MUST be an identifier or a member path, so every arm has a
  named referent to narrow. A call or other complex expression is bound to a
  `const` first; the diagnostic carries that exact repair.
- Arms are checked in source order. Exactly one arm's expression is
  evaluated.
- Arm expressions MAY be effectful. `match` with effectful named calls in its
  arms is the idiomatic effectful selection form, including for initializing
  a `const` from a two-way effectful choice.
- Patterns are literals, type-test patterns, or fixed record patterns.
- A type-test pattern is one of `boolean`, `number`, `string`, `array`,
  `Dict`, or `Bytes`, covering the closed core value kinds; `null` and
  `undefined` are matched by their literal patterns. Each test lowers to the
  corresponding narrowing test from the Section 5.4 closed list (`typeof`
  for the scalars, `Array.isArray`, `isDict`, or `isBytes`), so
  heterogeneous unions such as `JsonValue` dispatch through `match`.
- A record pattern field is either a discriminant test
  (`kind: "echo"`), a binding of the field under its own name (`text`), or a
  binding under a new name (`value: v`). A binding introduces an arm-scoped
  `const` of the narrowed field type; no double read of the scrutinee is
  needed.
- The binding pattern is the idiomatic way for an arm to read a field of the
  scrutinee: an arm that reads the field off the scrutinee instead is
  rewritten to a binding, and a rename whose new name equals the field name
  is rewritten to the shorthand (Section 4.2.1).
- A closed literal or discriminated union MUST be covered exactly and MUST NOT
  include `default`.
- An open domain such as `string`, `number`, or `unknown` MUST include
  `default`.
- Duplicate, unreachable, and non-exhaustive arms are errors.
- Each arm narrows the scrutinee binding for its expression.

#### `assert`

`assert predicate;` declares an invariant. It installs forward narrowing or
halts with a typed runtime assertion fault.

`assert` has no fallback form. Expected early return uses explicit ordinary
control flow:

```ts
if (!predicate) {
  return fallback;
}
```

Use `Result` when the caller can recover. Use `assert` only for a programmer
invariant whose violation is a typed runtime assertion fault. One direction of
that boundary is decidable and enforced: `assert` on a value whose flow label
is `user_input` or ingress-derived is rejected, and the diagnostic's exact
repair is the `if (!predicate) { return err(...); }` form. Trapping on
attacker-controlled input is never an invariant.

#### `for...of`

`for...of` is the only source loop:

```ts
for (const item of items) {
  if (skip(item)) {
    continue;
  }
  if (done(item)) {
    break;
  }
  consume(item);
}
```

Its semantics are snapshot-finite:

1. Evaluate the iterable once.
2. Snapshot the ordered element values and length at loop entry.
3. Iterate each snapshot element at most once.
4. Later mutation of the original collection cannot add iterations or change
   a value that the loop will observe.

Admitted iterables are arrays, tuples, strings, `range(n)`, `Dict` entries,
and other standard-library values whose contract supplies a finite snapshot.
`range` is an ambient pure intrinsic (Section 6). There is no user-defined
iterator protocol.

`range(n)` requires a finite non-negative integer. A certified cost claim also
requires a proven upper bound for `n`.

### 5.6 Functions and recursion

Every named function MUST declare all parameter and return types. A direct
arrow callback MAY infer them from a fully typed callback position, and MAY
declare any leading prefix of the callback type's parameter list (for
example a two-parameter arrow in a three-parameter `reduce` position). This
prefix rule is the only arity flexibility in the profile; named function
declarations and ordinary calls remain fixed-arity except for trailing
defaults.

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
- A generic declaration has at most eight type parameters; the limit is
  published in the profile registry limits.
- Constraints are structural bounds composed from admitted types.
- Generic parameters exist only on `function` and `type` declarations. A
  function type is always monomorphic, so rank-2 and higher polymorphism is
  inexpressible and inference stays decidable.
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

`distinct type UserId = string;` introduces:

```ts
UserId(value: string): UserId
```

The constructor is pure, total, and represented at runtime by the unchanged
base value. Only that constructor or a function already returning `UserId` can
create the nominal type. A distinct value supports the operations of its base
type, but a raw base value or a different distinct type is not assignable to
it.

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
- `Proof` and `Effects` capsules
- contractive recursive aliases

`Proof<T, P>` and `Effects<T, R>` are checker-only transparent capsules and
ambient type names; they are never imported. They do not allocate or wrap a
runtime value. In ordinary value use, an expression with either capsule has
value type `T`; proof properties and inferred effects are tracked separately
by the checker.

On a function return, `Effects<T, R>` declares an effect ceiling. The checker
requires the inferred row of the body to be a subset of `R`, while callers
receive a value of type `T` and the inferred effect row. Thus `parallel`
returns its tuple value directly, even when a containing function declares an
`Effects<tuple, row>` return contract.

When to declare the ceiling is a decidable rule, not a style choice: an
exported function with a nonempty inferred effect row MUST declare an
`Effects` return ceiling, and a module-internal function MUST NOT. The
diagnostic for a missing or extra ceiling carries an exact repair computed
from the inferred row.

A recursive alias is contractive when every cycle passes through a record,
tuple, array, or `Dict` constructor:

```ts
type JsonValue =
  | null
  | boolean
  | number
  | string
  | readonly JsonValue[]
  | Dict<string, JsonValue>;
```

Union and intersection edges do not guard recursion. Direct cycles such as
`type Loop = Loop`, negative recursion through a function parameter, and
recursive conditional expansion are errors. Recursive aliases are represented
as a finite named type graph. Assignability unfolds guarded nodes with
memoized pair comparison and never expands a cycle into an infinite type.

A function may return a type predicate:

```ts
function isUser(value: unknown): value is User { ... }
```

The checker validates the predicate body before using it for narrowing.
`Array.isArray`, `isDict`, and `isBytes` are specified intrinsic type guards
that narrow a union to the corresponding value-kind members. No annotation
alone can install a false guard.

Excluded type features are:

- `any`
- `as`, angle-bracket assertions, and `satisfies`
- generic parameters on function types (higher-rank polymorphism)
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

TSX is the optional, versioned `zts-tsx-1` source frontend. JSX tokens are not
part of the core grammar. A `.tsx` source is type-stripped, lowered to ordinary
core calls, and only then parsed by the target core profile. A `.ts` source
that contains raw JSX is rejected.

The frontend identity publishes its own grammar hash together with the target
core profile and grammar hash. A cached lowering is reusable only when all of
those identities match.

- `HtmlNode` is an opaque immutable virtual-node type.
- `HtmlChild` is `HtmlNode | string | number | boolean | null | undefined |
  readonly HtmlChild[]`.
- Components are named functions.
- Props are fixed records.
- A component returns `HtmlNode`.
- Children are finite arrays of `HtmlChild`.
- Rendered text is escaped by default.
- Raw HTML requires an explicit capability-reviewed API.
- An expression container is copied as an expression into the lowered core.
  Ordinary `<`, `<=`, `>`, and `>=` expressions inside it therefore retain
  their core meaning. Reversing a comparison to avoid a frontend ambiguity is
  not conforming source.
- JSX spread follows the same one-leading-base rule as record spread.

JSX introduces no component lifecycle, ambient state, hooks, class
components, or hidden effect scheduling.

The surface elaborates through the ambient `h` constructor:

```text
<div a={x}>text {y}</div>  => h("div", { "a": x }, "text", y)
<Component />              => h(Component, null)
<>a {b}</>                  => h(null, null, "a", b)
```

The constructor has the equivalent typed surface:

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
```

`h` is a variadic ambient intrinsic with the conceptual signature
`(string | Component<P> | null, P | null, HtmlChild_0, ..., HtmlChild_n) ->
HtmlNode`. Its variadic tail is an intrinsic contract, not a source-declarable
rest parameter. `renderToString(HtmlNode) -> string` is the corresponding
renderer. `null`, `undefined`, and boolean children render no text. Nested
child arrays flatten in source order. A numeric child elaborates through the
same implicit `String` elaboration as template interpolation (Section 5.4).
Text and attribute values are escaped.

## 6. Application data abstractions

The data values in this section are pure and immutable. An operation itself
is pure unless its callback carries effects, in which case the inferred
effect row carries them (Section 6.1).

One rule separates ambient names from imports, so the split is derivable, not
memorized:

- Ambient type names: the closed profile-level type names — the primitives,
  `Result`, `Dict`, `Bytes`, `HtmlNode`, `Request`, `Response`, `Proof`, and
  `Effects`. These are never imported. A module-defined type (for example
  `FetchError` from `zttp:fetch`) is named through an ordinary `import type`
  from its module.
- Ambient value names: the members of the familiar TypeScript sequence types
  (array and string methods), plus the closed intrinsic set `String`,
  `range`, `Array.isArray`, `isDict`, and `isBytes`. These keep their
  familiar TS spellings under law 4.1; dispatch is static, never prototype
  lookup.
- Everything else is a statically named import. New abstractions with no
  TypeScript-familiar member form (`Result`, `Dict`, `Bytes`, JSON)
  export free functions from their zero-capability modules, and
  capability-bearing operations import from their capability modules where
  the import line carries authority information.

The complete ambient table (types and values) is published through
`meta.payload.ambient_names` and is registry-generated.

### 6.1 `Result<T, E>`

`Result` is the one recoverable-failure representation:

```ts
type Result<T, E> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: E };
```

The admitted operations are:

```ts
ok<T>(value: T): Result<T, never>
err<E>(error: E): Result<never, E>
mapResult<T, U, E>(result: Result<T, E>, f: (value: T) => U): Result<U, E>
mapError<T, E, F>(result: Result<T, E>, f: (error: E) => F): Result<T, F>
andThen<T, U, E, F>(
  result: Result<T, E>,
  f: (value: T) => Result<U, F>,
): Result<U, E | F>
orElse<T, E, F>(
  result: Result<T, E>,
  f: (error: E) => Result<T, F>,
): Result<T, F>
unwrapOr<T, E>(result: Result<T, E>, fallback: T): T
collectAll<T, E>(
  results: readonly Result<T, E>[],
): Result<readonly T[], E>
```

The type is predeclared. Constructors and combinators are statically named
imports from the zero-capability `zttp:result` module. `collectAll` is
first-error: it returns the first `err` in order, matching `andThen`
short-circuit semantics.

The combinator callbacks are effect-row polymorphic. The callback of
`mapResult`, `mapError`, `andThen`, and `orElse` MAY be effectful; the
operation's inferred effect row is the join of the callback's row and its
operands' rows, and each step is exactly one ordered call, so sequencing
stays deterministic and visible in the trace. This differs deliberately from
the array operations of Section 6.5, whose callbacks run once per element:
a per-element effect sequence belongs in `for...of`, while a `Result` chain
is a linear once-per-step sequence the row and the source order both make
manifest.

Consumption is one ordered decision procedure, first match wins, so exactly
one form is idiomatic for any given site:

1. The site's result type is `T` and the error arm supplies a constant of
   type `T`: `unwrapOr`.
2. The site's result type is a `Result`, it is not a defaulting call, and
   the value or the error is transformed by a single expression: a
   combinator chain.
3. The error arm exits the enclosing function: the `ok`-guard early return,
   `if (!result.ok) { return ...; }` followed by direct use of
   `result.value`.
4. Otherwise: `match`, including every continuation whose arms need
   statements.

The order is most specific first, and the clauses are disjoint by
construction: rules 1 and 2 are separated by the site's result type and by
the defaulting test, so a nested `Result<Result<A, B>, E>` cannot satisfy
both. `match` is the residual form, and a site whose result type is neither
`T` nor a `Result` reaches it directly rather than through a `unwrapOr` of a
combinator chain. Every consumption site therefore has exactly one idiomatic
spelling. A `match` whose shape matches an earlier rule is reported
non-idiomatic, and is rewritten to that rule's form where a Section 4.2.1
row's precondition holds.

Trapping `unwrap` and `unwrapErr` are not admitted at all. A checked extraction
after an `ok` guard MAY lower directly to the value field, and the narrowing
rules of Section 5.4 make that extraction predictable.

Every recoverable failure MUST use a typed `Result`. This includes fallible
ingress APIs, decoders, capability calls, text codecs, and partial collection
operations. `undefined` represents absence only. A typed halt represents a
named programmer or resource fault, not a recoverable application error.

### 6.2 `Dict<K, V>`

`Dict` supplies dynamic keyed data without dynamic record shapes:

```ts
type DuplicateKey<K> = {
  readonly kind: "duplicate-key";
  readonly key: K;
};

dictEmpty<K extends DictKey, V>(): Dict<K, V>
dictFromEntries<K extends DictKey, V>(
  entries: readonly (readonly [K, V])[]
): Result<Dict<K, V>, DuplicateKey<K>>
dictGet<K extends DictKey, V>(dict: Dict<K, V>, key: K): V | undefined
dictSet<K extends DictKey, V>(dict: Dict<K, V>, key: K, value: V): Dict<K, V>
dictRemove<K extends DictKey, V>(dict: Dict<K, V>, key: K): Dict<K, V>
dictHas<K extends DictKey, V>(dict: Dict<K, V>, key: K): boolean
dictEntries<K extends DictKey, V>(dict: Dict<K, V>): readonly (readonly [K, V])[]
dictMapValues<K extends DictKey, V, W>(
  dict: Dict<K, V>,
  f: (value: V, key: K) => W,
): Dict<K, W>
dictFilter<K extends DictKey, V>(
  dict: Dict<K, V>,
  f: (value: V, key: K) => boolean,
): Dict<K, V>
dictFold<K extends DictKey, V, U>(
  dict: Dict<K, V>,
  f: (acc: U, value: V, key: K) => U,
  init: U,
): U
```

The bulk operations iterate in insertion order with pure callbacks, preserve
key uniqueness by construction, and return `Dict`, not `Result`, so a
transformation of an existing dictionary never handles an impossible
duplicate-key error and never leaves the type. They are also the idiomatic
spellings of their operations: an entry round trip through `dictEntries` and
`dictFromEntries` is rewritten to `dictMapValues` or `dictFilter`, and a
`reduce` over `dictEntries` is rewritten to `dictFold`, in each case where the
Section 4.2.1 row's precondition holds.

Construction has one idiomatic form per input shape, separated by duplicate
handling rather than by the shape of the source data:

- `comptime(dictFromEntries([...]))` from a literal entry list, where a
  duplicate fails the build.
- `dictFromEntries(entries)` whenever an array of key-value tuples is
  available, including one produced by a `map`, and a duplicate key is an
  error the caller handles.
- `dictEmpty` plus a `dictSet` fold when duplicate keys must merge or
  overwrite rather than fail, which is the only behavior the fold can express
  and `dictFromEntries` cannot.

The two runtime forms are therefore never interchangeable: they differ on
duplicate keys, so choosing between them is a semantic decision about the
data, not a spelling choice.

A static table uses `comptime(dictFromEntries([...]))` over a literal entry
list: the duplicate-key check is discharged at compile time, the expression
fails the build on a duplicate, and its type is the plain `Dict<K, V>`.

`DictKey` is a checker-recognized generic bound, not a source alias. It accepts
`string`, `number`, or a `distinct type` over one of those bases. Nominal keys
compare only within the same `K` instantiation, using the wrapped base value.

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

```ts
type BytesError =
  | { kind: "invalid-octet"; index: number; value: number }
  | { kind: "invalid-encoding"; encoding: string; offset: number }
  | { kind: "invalid-bounds"; start: number; end: number }
  | { kind: "size-limit"; limit: number };

bytesFromOctets(values: readonly number[]): Result<Bytes, BytesError>
bytesLength(value: Bytes): number
byteAt(value: Bytes, index: number): number | undefined
sliceBytes(value: Bytes, start: number, end: number): Result<Bytes, BytesError>
concatBytes(values: readonly Bytes[]): Result<Bytes, BytesError>
encodeUtf8(value: string): Bytes
decodeUtf8(value: Bytes): Result<string, BytesError>
decodeBase64(value: string): Result<Bytes, BytesError>
encodeBase64(value: Bytes): string
```

- Construction validates every octet.
- Values are immutable.
- An out-of-bounds single index returns `undefined`.
- Invalid slice bounds, decoding, or size limits return `Result`.
- Capability modules declare whether a payload is `string`, `Bytes`, or a
  structured value.
- Pure byte operations are statically named imports from the zero-capability
  `zttp:bytes` module.

### 6.4 JSON

JSON uses the recursive `JsonValue` type from Section 5.7. Object nodes are
`Dict<string, JsonValue>`, not dynamic-shape records.

The JSON boundary is:

```ts
type JsonError =
  | { kind: "invalid-syntax"; offset: number }
  | { kind: "duplicate-key"; key: string; offset: number }
  | { kind: "depth-limit"; limit: number }
  | { kind: "size-limit"; limit: number }
  | { kind: "non-finite-number" }
  | { kind: "cycle" };

parseJson(text: string): Result<JsonValue, JsonError>
parseJsonBytes(value: Bytes): Result<JsonValue, JsonError | BytesError>
stringifyJson<T>(value: T): Result<string, JsonError>
```

Rules:

- `parseJson` validates syntax, depth, and configured input size,
- `parseJsonBytes` first validates UTF-8 and then applies the same JSON rules,
- duplicate object keys are rejected,
- object insertion order follows wire order,
- the checker admits `stringifyJson<T>` only when `T` contains JSON scalars,
  arrays, tuples, fixed records, or string-keyed `Dict` values,
- encoding preserves array order, fixed-record declaration order, and
  dictionary insertion order,
- optional `undefined` fields are omitted and `undefined` array elements are
  rejected,
- non-finite numbers and cyclic values are rejected,
- `null` round-trips as data,
- and every failure is a typed `Result`.

The limits are selected by the runtime policy and bound into checked and
certified artifacts. The raw pair are named imports from the zero-capability
`zttp:json` module. Trapping `JSON.parse`, silent `undefined` on parse failure,
and unchecked `JSON.stringify` are excluded from the canonical profile.

Schema-directed decoding remains a separate `zttp:decode` operation:

```ts
decodeJson<T>(
  schema: Schema<T>,
  text: string,
): Result<T, DecodeError | JsonError>
```

`Schema<T>` is an opaque, checker-recognized schema value whose canonical
schema digest is bound to `T` and to the build artifact. The decoder returns a
precise application type rather than `unknown`.

### 6.5 Arrays and higher-order functions

The admitted finite operations have these abstract semantic signatures. This
block specifies types and is not additional source declaration syntax:

```ts
map<T, U>(items: readonly T[], f: (value: T, index: number) => U): U[]
filter<T>(items: readonly T[], f: (value: T, index: number) => boolean): T[]
reduce<T, U>(items: readonly T[], f: (acc: U, value: T, index: number) => U, init: U): U
find<T>(items: readonly T[], f: (value: T, index: number) => boolean): T | undefined
findIndex<T>(items: readonly T[], f: (value: T, index: number) => boolean): number
some<T>(items: readonly T[], f: (value: T, index: number) => boolean): boolean
every<T>(items: readonly T[], f: (value: T, index: number) => boolean): boolean
flatMap<T, U>(items: readonly T[], f: (value: T, index: number) => readonly U[]): U[]
toSorted<T>(items: readonly T[], compare: (a: T, b: T) => number): T[]
slice<T>(items: readonly T[], start: number, end: number): T[]
concat<T>(items: readonly T[], other: readonly T[]): T[]
indexOf<T>(items: readonly T[], value: T): number
includes<T>(items: readonly T[], value: T): boolean
join(items: readonly string[], separator: string): string
```

`toSorted` is non-mutating, its comparator MUST be pure and total over the
element type, and the sort is stable. `indexOf` uses strict equality and
`includes` uses SameValueZero, matching both the live runtime and the `Dict`
key rule of Section 6.2, so they disagree on `NaN` and the rewrite between
them is conditioned accordingly. `includes` is idiomatic for the boolean
question and `indexOf` for the position, so neither is written through the
other (Section 4.2.1). `concat` is admitted but non-idiomatic: array spread
spells the same operation and generalizes further. This closed set is a
superset of the array members the live runtime already ships, so completing
their types (Section 3, gap 6) does not narrow the baseline.

Each operation uses snapshot-finite iteration. Its callback MUST be pure. The
checker verifies the callback body and every reachable helper rather than
assuming that an arrow expression is pure. An effectful traversal uses
`for...of` with `push` accumulation, which keeps per-element sequencing and
failure visible; the once-per-step effect polymorphism of the `Result`
combinators (Section 6.1) does not extend to per-element callbacks.

The idiomatic source spelling is an intrinsic array method such as
`items.map(f)`. Dispatch is resolved statically from the receiver type and
lowers to an explicit intrinsic such as `arrayMap(items, f)`. It never performs
prototype lookup.

The choice between the two iteration forms is decidable, not judgment: a
`for...of` loop whose body is pure, carries one evolving accumulator, and has
no `break` or `continue` is non-idiomatic, and `canonicalize` emits the
rewrite to the equivalent higher-order operation. A loop whose `break` is its
only early exit, which uses no `continue`, and whose body is a pure search is
likewise rewritten: to `find` when it yields the element, `findIndex` when it
yields a position, `some` when it yields a boolean flag starting `false`, and
`every` when it yields one starting `true`.
`for...of` is idiomatic when the algorithm needs `continue`, a `break` that
carries other work, per-element effects, or more than one evolving
accumulator.

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
import { parallel } from "zttp:io";
import type { FetchError } from "zttp:fetch";

function loadUser(): Result<User, FetchError> { ... }
function loadOrders(): Result<readonly Order[], FetchError> { ... }

function loadBoth(): readonly [
  Result<User, FetchError>,
  Result<readonly Order[], FetchError>,
] {
  const [user, orders] = parallel([loadUser, loadOrders]);
  return [user, orders];
}
```

The call sits inside a function body: module initialization MUST be pure
(Section 5.1), so an effect operation never runs at module top level.

Rules:

- The task list is a finite tuple of named zero-argument functions.
- The result preserves tuple position and each task's precise result type.
- The combined effect row is the union of task effects.
- Replay order, cancellation, timeout, and loser cleanup are part of the
  module contract.
- `race` returns a tagged union synthesized from the task tuple. For tasks
  returning `A`, `B`, and `C`, its type is
  `{ winner: 0; value: A } | { winner: 1; value: B } |
  { winner: 2; value: C }`.
- The winner is the first completion event in the governed runtime log.
  Simultaneous completions choose the lowest tuple index. Replay uses the
  recorded winner and ordering.
- Losing tasks are canceled, their cleanup completes, and those events enter
  the trace before `race` returns.
- There is no user-visible Promise, microtask queue, detached task, or
  implicit scheduler.
- `parallel` and `race` are checker-intrinsic special forms. Their result
  types are synthesized per call site from the task tuple and are not
  expressible in the admitted type grammar, which has no variadic or mapped
  types. The module registry represents each with a declared special-form
  role whose contract schema `meta` publishes; they are not ordinary typed
  exports.

### 7.2 Minimum application ABI

The profile is not application-complete if its framework modules expose
`object`, `unknown`, or an untagged failure where the application knows a more
precise type. At minimum, the module registry MUST express the following
contracts.

#### HTTP

```ts
type HttpHandler = (request: Request) => Response;

type FetchOptions = {
  readonly method?:
    | "GET"
    | "POST"
    | "PUT"
    | "PATCH"
    | "DELETE"
    | "HEAD"
    | "OPTIONS";
  readonly headers?: Dict<string, string>;
  readonly body?: string | Bytes;
  readonly timeoutMs?: number;
};

requestBody(request: Request): Bytes
requestText(request: Request): Result<string, BodyError>
requestJson(request: Request): Result<JsonValue, JsonError | BodyError>
responseText(value: string, status: number): Response
responseJson<T>(value: T, status: number): Result<Response, JsonError>
fetch(
  url: string,
  options: FetchOptions,
): Result<Response, FetchError>
```

`responseText` is total: a handler always has an infallible constructor for
the error arm of a fallible one. `responseJson<T>` uses the JSON-encodability
rule from Section 6.4 and is always fallible, with one result type at every
call site. Its residual runtime failures are non-finite numbers, cyclic
values, and the policy-selected size limit of Section 6.4, and the last of
those cannot be discharged from `T` alone, so no payload type buys a total
encoder. One type for one operation is also the cheaper agent contract: the
error arm is always required and never depends on how much the checker can
prove.

Request
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

type QueueHandler<T, E> = (
  message: QueueMessage<T>,
) => Result<QueueDecision, E>;

send<T>(queue: string, payload: T): Result<MessageId, QueueError>
```

`send<T>` requires a statically JSON-encodable payload. A consumer returns a
`QueueDecision` through `QueueHandler`. Delivery attempt, retry delay,
idempotency key, and acknowledgement semantics are explicit in the module
contract and replay trace.

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

This grammar describes admitted structure as a structural over-approximation:
several productions admit forms the normative prose of Section 5 excludes
(for example arrow expressions outside callback argument positions). Legality is defined by the prose rules and
the machine-readable registry together; the registry records, per rule,
whether enforcement happens at parse time or at check time. Unexpanded
leaves such as `Ident`, `String`, `Number`, `Literal`, `Template`, and
`TemplateLiteralType` are lexical or separately specified syntactic classes.

```ebnf
Module       ::= Import* TopDecl*

Import       ::= "import" ["type"] "{" ImportNames "}" "from" String ";"
ImportNames  ::= ImportName ("," ImportName)* [","]
ImportName   ::= Ident ["as" Ident]

TopDecl      ::= ["export"] TypeDecl
               | ["export"] StructuralDecl
               | ["export"] DistinctDecl
               | ["export"] NominalDecl
               | ["export"] FunctionDecl
               | ["export"] TopBindingDecl

TypeDecl     ::= "type" Ident TypeParams? "=" Type ";"
StructuralDecl ::= "structural" Ident TypeParams? "=" Type ";"
DistinctDecl ::= "distinct" "type" Ident "=" ScalarType ";"
NominalDecl  ::= "nominal" Ident "=" ScalarType ";"
TypeParams   ::= "<" TypeParam ("," TypeParam)* ">"
TypeParam    ::= Ident ["extends" Type]

FunctionDecl ::= "function" Ident TypeParams?
                 "(" DeclParams? ")" ":" ReturnType Block
DeclParams   ::= DeclParam ("," DeclParam)* [","]
DeclParam    ::= Ident ":" Type
ValueParams  ::= ValueParam ("," ValueParam)* [","]
ValueParam   ::= Ident ":" Type
ReturnType   ::= Type | TypePredicate
TypePredicate ::= Ident "is" Type

TopBindingDecl ::= "const" Bind [":" Type] "=" Expr ";"
BindingDecl  ::= ("const" | "let") Bind [":" Type] "=" Expr ";"
Bind         ::= Ident

Block        ::= "{" Stmt* "}"
Stmt         ::= BindingDecl
               | FunctionDecl
               | LValue "=" Expr ";"
               | Expr ";"
               | IfStmt
               | "for" "(" ("const" | "let") Bind "of" Expr ")" Block
               | "assert" Expr ";"
               | "return" [Expr] ";"
               | "break" ";"
               | "continue" ";"
               | Block
IfStmt       ::= "if" "(" Expr ")" Block ["else" (Block | IfStmt)]
LValue       ::= Ident
               | AssignableExpr "." Ident
               | AssignableExpr "[" Expr "]"
AssignableExpr ::= PrimaryExpr AssignableSuffix*
AssignableSuffix ::= "." Ident
                   | "[" Expr "]"
                   | TypeArgs? "(" [Args] ")"

Expr         ::= ArrowExpr | ConditionalExpr
ConditionalExpr ::= BinaryExpr ["?" BinaryExpr ":" BinaryExpr]
BinaryExpr   ::= UnaryExpr (BinaryOp UnaryExpr)*
UnaryExpr    ::= UnaryOp UnaryExpr | PostfixExpr
PostfixExpr  ::= PrimaryExpr PostfixSuffix*
PostfixSuffix ::= "." Ident
                | "?." Ident
                | "[" Expr "]"
                | TypeArgs? "(" [Args] ")"
PrimaryExpr  ::= Literal
               | Ident
               | ArrayExpr
               | RecordExpr
               | Template
               | MatchExpr
               | "(" Expr ")"
UnaryOp      ::= "!" | "-" | "~" | "typeof"
BinaryOp     ::= "**" | "*" | "/" | "%"
               | "+" | "-"
               | "<<" | ">>" | ">>>"
               | "<" | "<=" | ">" | ">="
               | "===" | "!=="
               | "&" | "^" | "|"
               | "&&" | "||" | "??"

ArrayExpr    ::= "[" [ArrayItem ("," ArrayItem)* [","]] "]"
ArrayItem    ::= Expr | "..." Expr
RecordExpr   ::= "{" "}"
               | "{" RecordField ("," RecordField)* [","] "}"
               | "{" "..." Expr "," RecordField
                  ("," RecordField)* [","] "}"
RecordField  ::= Ident ":" Expr | String ":" Expr
PropertyName ::= Ident | String
Args         ::= Expr ("," Expr)* [","]
TypeArgs     ::= "<" Type ("," Type)* ">"
ArrowExpr    ::= "(" [ArrowParams] ")" "=>" (Expr | Block)
ArrowParams  ::= ArrowParam ("," ArrowParam)* [","]
ArrowParam   ::= Ident [":" Type]
MatchExpr    ::= "match" "(" Scrutinee ")" "{"
                  MatchArm+ [DefaultArm] "}"
Scrutinee    ::= Ident ("." Ident)*
MatchArm     ::= "when" Pattern ":" Expr
DefaultArm   ::= "default" ":" Expr
Pattern      ::= Literal | TypeTestPattern | "{" PatternFields "}"
TypeTestPattern ::= "boolean" | "number" | "string"
                  | "array" | "Dict" | "Bytes"
PatternFields ::= PatternField ("," PatternField)* [","]
PatternField ::= PropertyName ":" Literal
               | PropertyName ":" Ident
               | Ident

Type         ::= UnionType
UnionType    ::= IntersectionType ("|" IntersectionType)*
IntersectionType ::= PostfixType ("&" PostfixType)*
PostfixType  ::= PrimaryType ("[]")*
               | "readonly" ArrayBaseType "[]"
ArrayBaseType ::= NonTuplePrimaryType | "(" Type ")"
PrimaryType  ::= NonTuplePrimaryType | TupleType
NonTuplePrimaryType ::= Primitive
               | LiteralType
               | Ident TypeArgs?
               | RecordType
               | FunctionType
               | TemplateLiteralType
               | "(" Type ")"

Primitive    ::= "unknown" | "never" | "undefined" | "null"
               | "boolean" | "number" | "string" | "Bytes"
LiteralType  ::= String | Number | "true" | "false"
TupleType    ::= ["readonly"] "[" [Type ("," Type)* [","]] "]"
RecordType   ::= "{" [RecordTypeField (";" RecordTypeField)* [";"]] "}"
RecordTypeField ::= ["readonly"] PropertyName ["?"] ":" Type
FunctionType ::= "(" [ValueParams] ")" "=>" ReturnType
ScalarType   ::= "number" | "string"
```

Postfix operations bind most tightly. Binary precedence, from tightest to
loosest, is exponentiation; multiplication; addition; shifts; comparisons;
strict equality; bitwise AND, XOR, and OR; boolean AND and OR; nullish
coalescing; then the conditional expression. Exponentiation is
right-associative. Every other binary operator is left-associative. The
conditional expression does not nest: neither arm may be a conditional
expression, parenthesized or not, so no associativity question arises.
Parentheses override precedence. An `LValue` cannot contain an
optional-chain suffix.

The complete parser specification must also define numeric literals, string
escapes, Unicode identifiers, templates, patterns, and TSX without relying on
JavaScript as an implicit specification. It MUST implement the explicit
semicolon rule from Section 5.5 and has no automatic semicolon insertion.

## 9. Surface elaboration

The advanced surface is intentionally richer than the executable kernel.

| Surface form | Canonical elaboration |
|---|---|
| type annotations and aliases | erased after producing checked type evidence |
| constrained generics | checker instantiation, then erasure |
| contractive recursive aliases | finite named type graph, then erasure |
| `distinct type` | nominal checker identity plus specified base-value constructor |
| closed compile-time scalar default | optional ingress plus embedded constant selection |
| optional member access | evaluate receiver once, branch on `null` or `undefined` |
| nullish coalescing | evaluate left once, branch on `null` or `undefined` |
| pure conditional expression | evaluate the boolean condition and exactly one branch |
| record spread | allocate fixed target shape, copy one base, write explicit fields |
| array spread | finite snapshot concatenation |
| `match` | ordered tested branches over the named scrutinee |
| `match` binding field | arm-scoped `const` bound from the narrowed scrutinee field |
| `match` type-test pattern | the corresponding value-kind narrowing test from the Section 5.4 closed list |
| `assert` | branch to continuation or typed invariant halt |
| `for...of` | finite snapshot plus index-controlled core loop |
| array higher-order function | typed finite fold with explicit callback call |
| array `push` | kernel append operation |
| `Result` | tagged record union |
| `Result` combinator | one ordered call plus a branch on the tag |
| `Dict` | immutable intrinsic with specified ordering and equality |
| TSX | `h(tag, props, ...children)` calls emitted by `zts-tsx-1` |
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
- array allocation, index read, index write, append, and length
- immutable `Dict` operations
- immutable `Bytes` operations
- conditional branch and jump
- explicit halt and resource fault
- capability call
- structured parallel and race operation

`match`, `for...of`, conditional expressions, optional access, default
parameters, spread, destructuring, TSX, `Result`, and higher-order array
methods are surface or library constructs, not distinct semantic foundations.

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
> result or fault and an equivalent governed effect trace.

Trace equivalence includes capability calls and results, ordering,
cancellation, and cleanup. A permitted refinement MUST be named explicitly and
cannot add authority or observations. For divergence, every finite target
trace prefix must correspond to a source trace prefix, and neither side may
terminate or emit an unmatched effect while the related side diverges.

This simulation does not by itself prove that either execution terminates.

### 11.2 Totality

A totality claim requires:

- finite snapshot iteration,
- no reachable recursive call cycle, or a proved decreasing measure,
- total called intrinsics under their preconditions,
- an authenticated completion, timeout, and retry bound for every reachable
  capability operation,
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
| `any`, type assertions (`as` and angle-bracket forms), `satisfies` | type evidence integrity | essential to the selected checker model |
| loose equality and implicit coercion | visible type-directed branches | essential to sound narrowing |
| effectful `?:`, compound assignment, rest parameters | visible evaluation and one mutation spelling | language-simplicity choice, provisional pending the 14.2 paired-task measurement |
| chained conditional arms | one form per branch shape | exact repair when constructible, else proposed refactor |
| numeric record keys | one keyed-collection model | canonical simplicity; use a string key or a number-keyed `Dict` |
| multiple record spreads | fixed-shape elaboration without field-presence tests | canonical simplicity; write explicit fields over one base |
| fallback `assert` | one explicit early-return spelling | use `if` plus `return` |
| interface, enum, namespace, decorator | one closed data and module model | language-simplicity choice |
| object methods, getters, setters | explicit functions and effects | language-simplicity choice |
| object literal shorthand | record fields name both their key and value | canonical simplicity; write `{ value: value }` |
| computed record key | fixed compiler-visible record shape | replaced by a literal field name or `Dict` |
| `in` operator | one explicit membership predicate per value kind | replaced by `dictHas` or the corresponding value-kind predicate |
| unary `+` | visible numeric conversion | replaced by an admitted boundary parser when the input is text |
| optional call | explicit absence branch before invocation | check for `undefined`, then call directly |
| optional computed access | explicit absence branch before dynamic indexed access | check for `undefined`, then use indexed access |
| `.js` and `.jsx` source files | one typed core and one explicit TSX frontend | language-simplicity choice; use `.ts` or `.tsx` |

Non-idiomatic spellings are absent from this matrix by design. They are not
restrictions and eliminate no failure class: Section 4.2.1 supersedes them
with an idiom and, where provable, rewrites them, but never rejects them. The
matrix is the exclusion set and the idiom table is the preference set. A
machine-readable profile publishes both, and an agent must not read a
non-idiomatic form as a forbidden one.

This matrix MUST be generated from the versioned profile registry once that
registry exists. A restriction list that omits the Section 4.2 level-1
exclusion rules is not a complete machine-readable profile.

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
- `proved_obligation_count == required_obligation_count`,
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
`tested but not proved` may appear as non-required metadata. If a named
property depends on such an edge, the artifact is a checked report at most and
MUST NOT be a proof certificate.

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

### 13.6 Agent explanation graph

Every failed or unavailable property in a build report, checked report, or
certificate attempt MUST expose a machine-readable explanation graph:

```text
requested property
  -> failed obligation
  -> source span and semantic member
  -> governing rule
  -> evidence or failure outcome
  -> admissible repairs or required semantic decision
```

Nodes and edges use stable identifiers from versioned registries. A source
repair is included only when it is mechanically valid, simulation-safe, and
equivalence-validated. Otherwise the graph states exactly what decision or
evidence is missing. A human-readable rendering MUST be derivable from the
same graph.

The explanation graph makes a result diagnosable and repairable. It is not
itself proof and cannot strengthen the grade of its enclosing artifact.

## 14. Readiness gates

The advanced profile is ready to ship only when all gates are true.

### 14.1 Language gate

- One machine-readable registry enumerates grammar features, canonical rules,
  types, intrinsics, value kinds, opcodes, module forms, and language
  operations. A language operation is a registry member naming one thing a
  program can do, such as absence defaulting or element iteration; it is the
  unit the idiom table is keyed by, and it is unrelated to the protocol
  operations of Section 4.8.
- The parser, checker, documentation, diagnostics, and formal coverage consume
  or validate against that registry.
- Every accepted form is registry-backed and code-generated. Object methods,
  getters, and setters are rejected before IR construction rather than
  accepted and then omitted.
- Generic functions instantiate soundly and never fall back to `unknown`.
- `Result`, `Dict`, recursive aliases, `null`, `Bytes`, higher-order arrays,
  and structured-I/O tuples are fully typed.
- The version-2 agent envelope, complete module-graph identity, atomic repair
  application, and unified property verification operation are implemented.
- The `meta` payload publishes the grammar productions, canonical per-form
  examples, ambient-name table, idiom table, validator registry,
  canonical type serialization, default repair budget, and decision-kind
  registry, each registry-generated and drift-gated.
- Every language operation in that registry has a published idiom, and every
  idiom is reachable through `meta`. A language operation with no declared
  idiomatic spelling fails this gate.
- Every rewrite the idiom table emits has a registered equivalence validator
  and a checked precondition, the rewrite relation is confluent, and
  normalization reaches its fixed point within the published pass bound,
  after which a second normalization produces identical bytes. A
  non-idiomatic spelling with no provable rewrite is reported at advisory
  severity and does not fail the gate.
- Version-1 JSON surfaces remain explicitly distinguishable and cannot be
  mistaken for advanced-profile results.

### 14.2 Agent gate

A versioned conformance corpus MUST exercise at least two independently
implemented coding-agent clients in fixed, reproducible environments. The
tasks cover:

- greenfield generation from user intent,
- migration from common TypeScript forms,
- diagnosis of type, effect, policy, and proof failures,
- exact mechanical repair and rejection of unsafe repair,
- behavior-preserving refactoring,
- and explicit recognition of unsupported requirements.

Each client begins with the user task and the bounded `bootstrap` view of the
version-2 `meta` operation through `zts agent --stdin-json`, not hidden syntax
instructions. It must discover every other language fact through the
normative agent protocol. The `grammar` and `examples` payloads of the full
`meta` view are part of that permitted discovery surface.

For every corpus task declared supported:

- the final source is canonical, free of `error` and `warning` diagnostics,
  type-correct, and semantically correct,
- every requested available property verifies,
- the loop converges within the profile's declared repair budget,
- no human corrects profile syntax or interprets an unstructured diagnostic,
- no exact repair is invalid, stale, or changes application semantics,
- and a second normalization produces identical bytes.

For every corpus task declared unsupported, every client must return a
structured unsupported result with no false success or guessed behavior.

The release report publishes first-pass validity, repair iterations, tool
calls, invalid-repair count, semantic-drift count, unsupported-task precision,
and human-intervention count per client. It also publishes a measured
terseness criterion: canonical-source token count and total generation-token
overhead per corpus task against an idiomatic TypeScript baseline, with a
declared acceptable ratio, so mandatory ceremony is a measured cost rather
than an asserted one. Release requires zero invalid exact repairs, zero
semantic drift, zero false success, and zero human syntax intervention across
the corpus.

The corpus also contains paired tasks for every admitted ZTS-specific form and
every excluded high-frequency TypeScript alternative. A custom form or
restriction remains only when it measurably reduces invalid generation or
repair work, or when it is necessary for a named semantic, authority, or proof
property that the familiar alternative cannot preserve.

### 14.3 Human-readability gate

- Agents and humans consume the same canonical source.
- No source construct exists only to transport machine metadata.
- Canonical formatting uses stable indentation and ordinary TypeScript lexical
  conventions.
- Public contracts use explicit types, reusable behavior uses named functions,
  and effectful calls remain visible in source order.
- Compiler-authored repairs preserve existing domain names and do not introduce
  opaque aliases, compressed layout, or needless nesting.
- The representative corpus passes a documented maintainability review by
  readers who did not author the programs.

### 14.4 Application corpus gate

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

### 14.5 Semantics gate

- Every profile member has an explicit semantic disposition.
- Every reachable core operation and bytecode opcode is specified.
- Generated readable, executable, and proof views are drift-gated per member,
  not only by count.
- Front-end elaboration, optimization, code generation, VM execution, heap
  behavior, and module boundaries are represented in the theorem chain.

### 14.6 Certificate gate

- A real independent consumer exists before certificate production is called
  shipped.
- The consumer reconstructs obligations and binds the exact deployment
  artifact.
- Inconclusive solver results fail certificate issuance and acceptance.
- The module and signer trust models are explicit.
- Hostile-bundle resource limits and solver isolation are tested.

## 15. Feature ledger

> Reconciled against the engine on 2026-08-03, across all 29 "Add or complete"
> entries and all 12 "Tighten" entries. Four entries had shipped and were still
> listed as outstanding, and five restrictions were already enforced. A ledger
> entry is a claim about what does not exist yet, so it rots in the one
> direction nobody notices: silently, as the work lands.
>
> Two entries below are open design conflicts rather than unfinished work, and
> are marked as such. Reconcile against engine code rather than against the
> other documents: `docs/internals/agent-protocol-v2.md` was found stale in the
> same pass, still listing three shipped operations as deferred.

### Keep

- `const` plus necessary `let`
- named functions and direct typed callbacks
- lexical closures
- fixed records, arrays, tuples, and limited spread with explicit member reads
- strict operators, optional chaining, and nullish coalescing
- `if`, `match`, `assert`, snapshot-finite `for...of`
- pure boolean conditional expressions, with impure arms rejected as ZTS612 and
  chained forms as ZTS621, both carrying the `replace_ternary_with_if` repair
- static named modules
- aliases, unions, intersections, literals, readonly, optionals, nominal
  types, guards, utility types, and proof/effect capsules
- TSX as pure elaboration
- explicit capability modules and structured I/O
- familiar TypeScript lexical conventions and human-readable block structure
- a machine-readable idiom registry, published with a table hash and reachable
  through `describe-rule --idioms`, so idiom is discoverable rather than
  conventional; the rows themselves are still being filled in
- a versioned agent protocol over `zts agent --stdin-json`: a closed
  eleven-operation set spanning discovery, diagnostics, repair, and
  verification, with schema-version negotiation, a frozen mismatch reply, and a
  byte-determinism gate. Its `meta` payload still names ten deferred sections,
  machine-readably rather than by omission
- deterministic fixed-point normalization and edit simulation, bounded at 64
  iterations and confluent, with idempotence asserted both by unit test and by
  a corpus-wide byte gate; a residual leaves the file unwritten
- property-specific proof grades over the tracked properties, each carrying the
  evidence method that produced it
- rejection of object methods, getters, and setters at the parser boundary
- reusable arrows reported as named functions, with a typed repair
- accepted recursion held distinct from proved termination: recursion runs, and
  the totality and cost claims are downgraded rather than the program refused
- the 10-node, 7-opcode symbolic semantics classified in code as a partial
  slice, not as slice-wide law
- targeted diagnostics for rejected TypeScript forms, each carrying an exact
  alternative, with stable `restriction.<slug>` identifiers

### Add or complete

- sound generic-function inference and instantiation
- limited `extends` constraints
- binding fields and type-test patterns in `match`
- the closed narrowing rule list
- decidable branch-choice and iteration-choice rules
- explicit parameter absence - phase 5's default-parameter support was removed
  in phase 7; ZTS054 and ZTS055 direct both declaration shorthands to
  `T | undefined` plus a visible body-level resolution
- contractive recursive aliases
- precise `Result<T, E>` with effect-row polymorphic combinators,
  `unwrapOr`, `orElse`, and `collectAll`
- immutable deterministic `Dict<K, V>` with bulk operations and
  `comptime()` static tables
- immutable `Bytes`
- the completed array operation set and `push`
- a total `responseText` constructor in the HTTP ABI
- the ambient-name criterion and registry table
- the remaining idiom rows and their rewrites: the registry mechanism ships,
  publishes all 23 current rows with a hash, and reports them as advisory-only
- an ordered `Result` consumption procedure with disjoint clauses
- one `responseJson` result type at every call site
- opaque typed `HtmlNode` and finite `HtmlChild`
- explicit JSON `null` - OPEN CONFLICT, not unfinished work. The engine has
  one absent-value sentinel by design: the parser rejects `null` and the JSON
  codec decodes wire `null` to `undefined`. Satisfying this needs either a
  second sentinel or a JSON-only opaque null, and either splits optional
  narrowing into two lattices. Decide before scheduling
- a typed, resource-bounded JSON codec
- fully typed finite array operations
- tuple-preserving `parallel` and tagged `race`
- precise minimum HTTP, WebSocket, queue, and durable-workflow ABIs
- snapshot semantics for every finite traversal
- an independent certificate verifier: the proof grades themselves ship, but
  the verify path re-checks a signature and re-hashes a manifest, shares its
  code with the producer, reconstructs no obligation, and runs no solver
- stable rule, diagnostic, repair, and explanation-graph identifiers
- an agent conformance corpus with bounded convergence

### Tighten

- reserve `assert` for programmer invariants
- use direct named calls instead of custom pipe syntax - DONE in phase 7. The
  scope was wider than one operator: `|>` was parser syntax, and `pipe()` and
  `guard()` from `zttp:compose` were compile-time forms wearing a module's
  clothes, with native implementations that never executed. All three are
  gone, `|>` reports ZTS001 naming the direct call, and the module with them
- reject ambient time, random, logging, and I/O - OPEN CONFLICT. The engine
  admits these names deliberately and charges a property instead of refusing
  the program: reading a clock is legitimate and costs `deterministic`. That is
  a different model from rejection, not an unapplied restriction, and the two
  should not both stand. One real gap either way: `performance.now` is absent
  from the varying-read set, so it reads a clock and costs nothing
- reject unchecked trapping operations at untrusted boundaries
- make a closed profile registry the source of truth
- identify ZTS as a distinct constrained language rather than imply TypeScript
  source compatibility
- treat the removed signed receipt as historical, not shipped

### Keep excluded

- classes, inheritance, class constructors, `new`, prototypes, and dynamic
  receivers
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
    when { ok: true, value }:
      `ratio ${value}`
    when { ok: false }:
      "undefined ratio"
  };
}
```

The binding field `value` removes the scrutinee double-read, and the numeric
interpolation elaborates through the implicit `String` intrinsic.

### 16.2 Keyed aggregation

```ts
import {
  dictEmpty,
  dictGet,
  dictSet,
} from "zttp:collections";

function frequencies(words: readonly string[]): Dict<string, number> {
  return words.reduce(
    (counts, word) => dictSet(counts, word, (dictGet(counts, word) ?? 0) + 1),
    dictEmpty<string, number>(),
  );
}
```

A pure single-accumulator fold is a `reduce` by the decidable rule of
Section 6.5; the `let` plus `for...of` spelling of the same fold is
non-idiomatic and receives the rewrite. The `dictSet` fold is idiomatic here
for the reason Section 6.2 gives: a repeated word must merge into the running
count rather than fail as a duplicate key, and that is the one behavior
`dictFromEntries` cannot express.

### 16.3 Recursive application data

```ts
import { dictFold } from "zttp:collections";

type JsonValue =
  | null
  | boolean
  | number
  | string
  | readonly JsonValue[]
  | Dict<string, JsonValue>;

function depth(value: JsonValue): number {
  return match (value) {
    when null: 1
    when boolean: 1
    when number: 1
    when string: 1
    when array:
      value.reduce(
        (maximum, child) => {
          const childDepth = depth(child);
          return childDepth > maximum ? childDepth : maximum;
        },
        0,
      ) + 1
    when Dict:
      dictFold(
        value,
        (maximum, child) => {
          const childDepth = depth(child);
          return childDepth > maximum ? childDepth : maximum;
        },
        0,
      ) + 1
  };
}
```

The `null` literal pattern and the five type-test patterns cover the six
value kinds of `JsonValue` exactly, so the `match` is exhaustive without
`default` and each arm narrows `value`.
This function is accepted. Its totality certificate depends on the checker
proving that recursive calls receive strict subvalues of a finite input.

### 16.4 Explicit effects

```ts
import { env } from "zttp:env";
import { fetch } from "zttp:fetch";
import { parallel } from "zttp:io";
import { err } from "zttp:result";
import type { FetchError } from "zttp:fetch";

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

export function loadDashboard(): Effects<
  readonly [
    Result<Response, LoadError>,
    Result<Response, LoadError>,
  ],
  "env" | "network"
> {
  return parallel([loadUser, loadOrders]);
}
```

The tuple remains typed. The effect ceiling remains visible, and its
placement follows the decidable rule of Section 5.7: `loadDashboard` is
exported with a nonempty effect row, so it declares the ceiling; `loadUser`
and `loadOrders` are module-internal, so they do not. `Effects` is ambient
and needs no import. No Promise or ambient scheduler enters the program.

### 16.5 Familiar pure shorthand

```ts
function greeting(name: string, excited: boolean = false): string {
  const punctuation = excited ? "!" : ".";
  return `Hello, ${name}${punctuation}`;
}
```

The default is a closed compile-time scalar, the conditional selects pure
values, and the template preserves direct source order. None introduces a new
kernel operation.

### 16.6 Agent repair sequence

An agent starts from the compiler, not from remembered TypeScript behavior:

```sh
zts agent --stdin-json < request-meta.json
zts agent --stdin-json < request-modules.json
zts agent --stdin-json < request-check.json
zts agent --stdin-json < request-canonicalize.json
zts agent --stdin-json < request-simulate-edit.json
zts agent --stdin-json < request-apply-repair.json
zts agent --stdin-json < request-normalize.json
zts agent --stdin-json < request-recheck.json
zts agent --stdin-json < request-verify.json
```

Each request uses the version-2 envelope and explicit project root. `check`
embeds the complete bound repair object inline for every repairable
diagnostic; `canonicalize` emits the rewrite candidates not attached to a
diagnostic; `simulate_edit` is an optional preview. The agent submits the
non-overlapping repair set unchanged, and `apply_repair` re-runs simulation
and equivalence validation internally before writing, rejecting anything
without a registered validator.

The final check and verification bind the same profile and policy, plus the
latest complete module-graph identity returned after all applied source
changes. If a diagnostic requires a domain decision, the agent returns that
structured decision point instead of synthesizing behavior.

## 17. Final northstar

The strongest defensible destination is:

> An agent can enter with user intent and no hidden ZTS knowledge, discover one
> small versioned profile, produce canonical source, repair it through bounded
> deterministic feedback, and verify the exact result. A human can read,
> review, and maintain that same source. Every admitted construct elaborates
> into a closed semantic kernel, and every certified property is independently
> checked against the exact deployment artifact.

Missing coverage, stale repairs, unsupported semantics, and inconclusive
automation fail closed. They never become guessed source or inflated proof
claims.

The language stays AI-minimal where choice entropy compounds:

- one data-contract form,
- one recoverable-error form,
- one branch form per branch shape, chosen by a decidable rule,
- one published idiom for every admitted operation, reached by normalization
  where a rewrite is provable and by an advisory where it is not,
- one source loop,
- one absence convention,
- one dynamic keyed collection,
- one structured-concurrency model,
- one explicit path for effects,
- one canonical formatting fixed point,
- and one machine-discoverable repair protocol.

It grows only where application evidence demands real expressive power:

- parametric reuse,
- recursive data,
- typed errors,
- keyed state,
- binary data,
- JSON fidelity,
- and compositional effects.

Human readability is not a competing language mode. It is the floor beneath
the agent-first design: familiar lexical forms, explicit names, visible
control, and no machine-only source dialect.

That is the balance `zts-advanced-1` should preserve: minimal uncertainty for
agents, sufficient power for general applications, and durable source for
humans.

## Sources inspected

- `docs/archive/spec-explainers/zts-formal-spec-northstar.html` (then at
  `docs/zts-formal-spec-northstar.html`)
- `docs/archive/spec-explainers/zts-formal-spec-design.html` (then at
  `docs/zts-formal-spec-design.html`)
- `docs/typescript.md`, which has since absorbed `docs/typescript-patterns.md`
- `docs/feature-detection.md`
- `docs/cli.md`, which has since absorbed `docs/canonical-profile.md`
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
- `packages/zts/src/handler_verifier.zig`
- `packages/zts/src/function_specs.zig`
- `packages/zts/src/path_generator.zig`
- `packages/zts/src/repair_intent.zig`
- `packages/zts/src/repair_plan.zig`
- `packages/zts/src/module_manifest.zig`
- `packages/zts/src/contract_builder.zig`
- `packages/zts/src/semantics.zig`
- `packages/zts/src/semantics_check.zig`
- `packages/zts/src/builtins/root.zig`
- `packages/zts/src/builtins/result.zig`
- `packages/tools/src/expert_meta.zig`
- `packages/tools/src/json_diagnostics.zig`
- `packages/tools/src/canonicalize.zig`
- `packages/tools/src/edit_simulate.zig`
- `packages/tools/src/zts_cli.zig`
- `packages/pi/src/skills/zts-expert/SKILL.md`
- `packages/tools/src/precompile.zig`
- the live `zts meta`, `features`, `restrictions`, `modules`, and `spec-check`
  JSON surfaces
- representative handlers under `examples/`
- language-design commits `79e93b36`, `5eefe15a`, `8a4d71df`, `f785d45d`,
  and `3b39eec`
- receipt-removal commit `9fb471dd`

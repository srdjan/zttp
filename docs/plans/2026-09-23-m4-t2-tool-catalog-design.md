# M4 T2 design note: canonical tool catalog and closed schema subset

Status: implemented on 2026-09-23. Accepted by the owner on 2026-09-23, with the recommended answer to
each question in section 8 and the file extension in section 7. This note answers the
condition that proposal A puts on T2 (`A:275-277`): define the closed schema
subset before choosing whether to extend `zttp:validate` or add a catalog
validator. Check C2 of the
[M4 release contract](2026-09-22-m4-release-contract.md) is written against the
approach this note names.

All citations are to local `main` at `108ca3dc`.

## 1. What T2 must deliver

One catalog entry per tool route. Each entry holds a unique public name, a
description, bounded input and output schemas, and the module exports that the
route can reach (`A:252-255`). The build refuses duplicate names and dynamic or
unreadable schemas. The validator refuses unknown fields and duplicate JSON
keys, and it refuses them before it constructs an object (`A:268-280`).

T2 ends at the compiler and the validator core. The runtime does not dispatch
through the catalog until T3 lowers it from the accepted artifact. The
contract assigns that lowering to T3 (release contract, T3), so T2 adds no
runtime path. C2 tests the validator through its public Zig API.

## 2. What exists today

**No tool concept.** The contract has no tool, catalog, or route description.
The only OpenAPI output is `packages/tools/src/openapi_manifest.zig:18`. It
synthesizes response descriptions as `"HTTP N response"` (`:254`), and only
`precompile --openapi` calls it (`precompile.zig:812-834`).

**Routes.** `routerMatch(routes, req)` is the only route source
(`packages/modules/src/http/router.zig:11-21`). The builder reads an object
literal whose keys are `"METHOD /path"` (`contract_builder.zig:2880`, `:3277`,
`parseRouteKey` at `:4488`). It analyzes each value function into its own
`ApiRouteInfo` (`contract_types.zig:440`). A non-literal table sets
`api_routes_dynamic`. `contract.routes` (`RouteInfo`, `contract_types.zig:50`)
is the AOT dispatch table and is not related.

**Schemas.** `schemaCompile(name, schemaJson)` registers a schema
(`validate.zig:16`). The builder reads it only when the name is a string
literal and the schema is a JSON literal or `JSON.stringify(<literal>)`
(`contract_builder.zig:2738`, `:2792`). Otherwise it sets
`api_schemas_dynamic`, which is a flag and not a refusal. A second
registration of a name replaces the first, both in the builder
(`upsertApiSchema`, `:2865`) and at runtime (`validate.zig:174-183`). SQL
registration refuses the same case with `error.DuplicateSqlQueryName`
(`:2781`).

**The validator (`zttp:validate`).** It has a closed keyword allowlist
(`validate.zig:279-300`), but it does not match the subset that T2 needs:

- It does not enforce closed objects. It checks only the declared
  `properties` and ignores other keys (`:691-700`). It refuses the
  `additionalProperties` keyword itself.
- It measures string length in bytes (`:633`, `:636`).
- It has no nesting limit on the schema or on the value (`:346`, `:697`).
- `minimum` and `maximum` go through `jsonToF64`, which accepts non-finite
  values (`:435-441`).
- It parses with the legacy `JSON.parse` path (`decodeJson`, `:194`). That
  parser keeps the last duplicate key (`packages/zts/src/builtins/json.zig:198`,
  and a test pins this at `:635`). It accepts `1e400` as infinity (`:548-554`)
  and turns `null` into `undefined` (`:153-156`), so `type:"null"` can never
  match.

**The strict parser.** `zttp:json` refuses a duplicate key when it reads the
key, before it parses the value (`packages/zts/src/modules/data/json_mod.zig:287-320`).
It refuses non-finite numbers (`:171-176`) and has depth and byte limits
(`:39-45`). It builds the object one key at a time, so a partial object exists
when it finds the duplicate. `requestJson` shares it (`:349`).

**Types to schemas.** `api_schema.zig:19` `schemaFromType` converts a record
type to a schema, but it writes `const` and `prefixItems`, which `zttp:validate`
refuses. The language has no bounded string or bounded array type, so a type
annotation cannot carry `maxLength` or `maxItems`.

**Reachable exports.** The contract records exports per handler, not per route
(`FunctionEntry`, `contract_types.zig:1861`). The walker
`includeReachableFunctionEffects` (`contract_builder.zig:4142`) already starts
at one function and follows the calls it can resolve. It folds the result into
one `EffectSummary`. `behaviors[].io_sequence` is per route, but it covers only
the I/O that the path generator models, and only when enumeration completes.

**Contract JSON.** The parser ignores unknown fields and keeps the last
duplicate key (`json_wire.zig:425-426`, `contract_json_parser.zig:631-633`).
No contract golden checks the `api` section: `test-contract-golden` compares
`zts check --json --contract` output, which holds only `success`, `proof`, and
`diagnostics`.

## 3. The closed schema subset

The subset is what the catalog admits. It is smaller than `zttp:validate` in
some places and larger in others. Every keyword outside this table is refused.
`title` and `description` are allowed and have no effect.

| Construct | Required keywords | Optional keywords | Rule |
|---|---|---|---|
| Object | `type:"object"`, `properties`, `additionalProperties:false` | `required` | Closed. A key that `properties` does not name is refused. Every `required` name must appear in `properties`. |
| String | `type:"string"`, `maxLength` | `minLength`, `enum`, `format` | Length unit is question Q3. `format` is one of the four existing formats (`validate.zig:65-77`). |
| Number | `type:"number"` or `type:"integer"` | `minimum`, `maximum`, `enum` | Values and bounds must be finite. `integer` means a finite whole number. |
| Boolean | `type:"boolean"` | none | |
| Array | `type:"array"`, `items`, `maxItems` | `minItems` | `items` is one schema. There are no tuples. |
| Enum | inside a scalar type | | Members are scalars of the enclosing type. |

These rules also apply:

- **Root.** The input schema root and the output schema root are objects.
- **Required and optional.** A field in `required` must be present. A field not
  in `required` may be absent.
- **Nullability.** `null` is not admitted in version 1. An absent optional
  field expresses "no value". `type` takes one string, as it does today. A
  later subset can add `type:[T,"null"]` without changing any admitted schema.
- **Nesting.** Schema depth and value depth have one fixed maximum, which
  question Q4 sets. The depth of a value can never exceed the depth of the
  schema that admits it, so the build checks the schema, and the validator
  checks the value as a second line.
- **Raw bytes.** Each catalog entry declares `maxInputBytes`. The validator
  refuses a larger input before it reads any token. The build does not derive
  this bound from the schema. A derived bound is B-M3 work (`B:72`).
- **No references.** No `$ref`, `oneOf`, `anyOf`, `allOf`, `not`, `pattern`,
  or `const`.

The same subset applies to the output schema. The validator refuses a result
that does not match it, which is B8.4 (malformed result) at the library level.

## 4. Options

### 4.1 Declaration surface: how a route becomes a tool

**A. A literal catalog call, recommended.** A new export
`toolCatalog(entries)` in a new module `zttp:tool`. The argument must be an
object literal at module scope:

```ts
import { toolCatalog } from "zttp:tool";

toolCatalog({
  lookupOrder: {
    route: "POST /tools/lookup-order",
    description: "Return the status of one order that belongs to the caller.",
    input: "LookupOrderInput",
    output: "LookupOrderOutput",
    maxInputBytes: 4096
  }
});
```

`route` names a key of the handler's `routerMatch` table, and `input` and
`output` name `schemaCompile` registrations. The builder reads it with the
same literal readers it uses for those two calls. The difference is that a
non-literal value is a refusal and not a dynamic flag. At runtime the call is
inert: it returns `undefined` and performs no effect. `routerMatch` does not
change.

**B. A wrapper inside the route table.** `"POST /x": tool({...}, fn)`. This
changes `routerMatch` semantics, because the builder requires each value to
resolve to a function node (`contract_builder.zig:3277`). It also makes the
catalog one field per route, which is harder to read as one closed list.

**C. New declaration syntax.** This changes the parser and the IR. It is too
wide for T2.

### 4.2 Schema source

**A. `schemaCompile` literals, recommended.** The catalog references schemas
by name. The build takes the schema bytes from the literal, checks them
against section 3, and stores them. The validator compiles from the same
bytes, so "schema bytes and validator agree after round trip" is a test of one
input, not a comparison of two generators.

**B. Type annotations through `schemaFromType`.** The language has no bounded
string or array type, so a derived schema can never pass section 3's
`maxLength` and `maxItems` rules. This needs `Text<N>` and `Bounded<T,N>`
first, which is language work outside M4.

### 4.3 Validator placement

**A. A new catalog validator in zts, recommended.** A new file,
`packages/zts/src/tool_schema.zig`, holds three public functions:

- `checkSubset(schema_bytes) -> SubsetResult`. The build calls it. It returns
  a closed refusal enum, one member for each rule in section 3.
- `compile(schema_bytes) -> CompiledToolSchema`. This accepts only bytes that
  passed `checkSubset`.
- `validate(compiled, input_bytes, max_bytes) -> ValidateResult`. It scans
  tokens with `std.json.Scanner` and checks each token against the schema as it
  arrives. It holds a key set for each open object and refuses a duplicate key
  when it reads the key. It refuses an unknown key, a non-finite number, and
  excess depth in the same way. It builds no JS value. T3 constructs the JS
  object only after `validate` accepts. Because this path builds no object,
  it meets "before object construction" more strictly than `json_mod.zig`,
  which already holds a partial object when it finds the duplicate.

`zttp:validate` does not change, so ordinary handlers see no change in
behavior. The build needs `checkSubset` inside zts, and T3 needs `validate`
in the runtime, which is one curated export and one row in
`scripts/module-boundary.allow`.

**B. Extend `zttp:validate` with a strict mode.** This needs a closed-object
check, `minItems`, finite bounds, a depth limit, a new length unit, and a
strict parse. The strict parser is in zts, and `packages/modules` is SDK-pure
and cannot import it. So the parse would stay in zts and the check would run
on JS values that were already constructed, which does not meet A's "before
object construction". It also puts two semantics behind one keyword set. It is
not measured whether `sdk.isObject` is true for the `Dict` that `requestJson`
returns. Option A does not depend on that fact.

### 4.4 Reachable exports per tool

**A. A per-route walk that refuses what it cannot resolve, recommended.**
A sibling of `includeReachableFunctionEffects` starts at the route function
and collects each `(module, export)` pair it reaches, instead of folding
effects. The catalog entry stores the sorted set. This fact becomes T5's
grant, so an under-approximation is a fail-open of the class that AGENTS.md
describes: the list would claim less authority than the code has. For this
reason, when the walk meets a call whose target it cannot resolve to a
function node or to a module export, the build refuses the tool with a named
reason. It does not skip the call.

Before code, one probe for each call shape must show the export in the set:
a direct call, a call through a module-scope helper, an arrow callback passed
to an array method, a function held in a `const`, and a function returned from
a function. Any shape the walk cannot follow becomes an "unresolved call"
refusal, and the probe asserts the refusal.

**B. The handler-wide list.** `FunctionEntry` is a sound over-approximation,
but every tool gets the union of all tools' exports. That is the result
`A:283-284` prohibits, and it makes T5's per-tool grant empty of meaning.

**C. `behaviors[].io_sequence`.** Only I/O that the path generator models, and
only when enumeration completes. It can omit a reached export.

### 4.5 Contract carriage

`HandlerContract` gains `tools: ArrayList(ToolEntry)`, and `version` goes from
18 to 19 (`contract_types.zig:1753`). `ToolEntry` holds the name, route key,
description, input and output schema names and bytes, `maxInputBytes`, and the
reachable export set. The writer emits a `tools` section, and the parser
projects it. The projection refuses a duplicate tool name and a reference to
a schema the section does not hold. The strict canonical encoding and the
digest are T3 (P4), so T2 does not change the global parser options.
OpenAPI and HAL-FORMS projections stay out of scope.

## 5. Build rules under the tool profile

A handler that calls `toolCatalog` is under the tool profile. The build refuses
the handler when:

1. the catalog argument, or any field of it, is not a literal;
2. two entries have the same name, or two entries name the same route;
3. an entry names a route that the `routerMatch` table does not hold, or the
   table itself is dynamic;
4. an entry names a schema that no literal `schemaCompile` registers, or that
   is registered twice (the upsert is kept for ordinary handlers);
5. a schema fails `checkSubset`, with the refusal reason named;
6. `maxInputBytes` is missing, not a positive integer literal, or above a
   ceiling (question Q4);
7. the reachable-export walk meets an unresolved call;
8. a route in the table has no catalog entry, if the owner accepts Q2.

The cross-call read refusal of decision 6 is T5 and is not in this list.

B8.2 (forged nominal value) enters here as a type rule and not a schema rule.
The subset has no nominal construct, and `schemaValueToType`
(`type_checker.zig:982`) gives a decoded value its structural type. A handler
that passes that value where a nominal type is required must be refused by the
type checker. T2 adds the test. If the test shows that the checker admits it,
the fix is in T2's scope.

## 6. Diagnostics and gates

Each refusal in sections 3 and 5 must reach the user with a location. There are
two ways. One ZTS code for each rule adds about fifteen registry codes, and each
one needs a defect seed or an `unseeded-rules.allow` row. One code, "tool
catalog refused", carries a reason tag from one closed enum. The recommended
way is the second. C2's census then iterates that one enum, and one defect
seed trips the code. The code number comes from the registry when work starts.

Check C2 as the release contract states it, specified here:

- **Positive.** A bounded input that the schema admits is accepted. The schema
  bytes are written to contract JSON, parsed back, and compiled again, and the
  new validator gives the same verdict as the first for every case in a fixed
  corpus.
- **Negative.** Each AE21 refusal: a duplicate public name, a dynamic schema, an
  unreadable schema, an unbounded string or array, a schema deeper than the
  maximum, and an unknown input field. The non-stream part of AE5: a duplicate
  key at the root and nested, and malformed JSON, each refused with zero
  construction. B8.2 as section 5 states it. B8.4 as a result that fails the
  output schema.
- **Non-vacuity.** Remove the duplicate-key check, and then the closed-field
  check. Each change must fail a named test in an unfiltered run. Then a census
  over the refusal enum of `checkSubset`, of `validate`, and of the build rules.
  Each member must have a probe that is seen to reject, or an allowlist row
  that states a mechanism.

The steps are `test-zts`, `test-modules`, `test-precompile`, and
`test-contract-golden`. `test-contract-golden` does not see the `api` section
today. T2 adds a tool fixture whose golden holds the refusal diagnostics.
Without it, that step checks nothing about T2.

## 7. Files

This extends the file list in the release contract. It needs owner acceptance,
as T1b's extension did.

| File | Change |
|---|---|
| `packages/zts/src/tool_schema.zig` | New. Subset check, compile, streaming validate. This is the "named new catalog validator" that the contract allows. |
| `packages/zts/src/modules/` (new `zttp:tool` binding) and `builtin_modules.zig` | The inert `toolCatalog` export and its registry row. |
| `packages/modules/module-specs/` and the module catalog table | Regenerated from the new binding, never edited. |
| `packages/zts/src/contract_builder.zig` | Catalog extraction, build rules, per-route export walk. |
| `contract_types.zig`, `contract_json_writer.zig`, `contract_json_parser.zig` | `ToolEntry`, version 19, write and project. |
| The diagnostic registry and `packages/pi/src/standin/defect_seeds.zig` | One code and its seed. |
| `packages/tools/tests/fixtures/contract/` | A tool fixture and its golden. |
| `packages/zts/src/root.zig` and `scripts/module-boundary.allow` | Only if T2 exports `tool_schema` for T3. Otherwise T3 does it. |

`packages/modules/src/security/validate.zig` does not change under option A.

## 8. Questions for the owner

- **Q1. Declaration surface.** A literal `toolCatalog({...})` call in a new
  module `zttp:tool` (4.1 A, recommended), or a wrapper inside the route table
  (4.1 B).
- **Q2. Tool-only handlers.** Under the tool profile, every route in the table
  must be a catalog entry (recommended: it makes T5's grant question one per
  route, with no untooled route in the same artifact), or tool and ordinary
  routes can share one handler.
- **Q3. String length unit.** Unicode scalar values (recommended: the schema is
  also a descriptor, and JSON Schema readers, models among them, read
  `maxLength` that way; `maxInputBytes` bounds memory separately), or UTF-8
  bytes (what `zttp:validate` does today).
- **Q4. Fixed limits.** The maximum nesting depth and the `maxInputBytes`
  ceiling. These are policy values and not measurements. The proposal is depth
  8 and a ceiling of 1 MiB, to change as the owner decides.

These are recommended and are not questions unless the owner objects: the
schema source (4.2 A), a new validator in zts with `zttp:validate` unchanged
(4.3 A), the per-route walk that refuses unresolved calls (4.4 A), no `null` in
version 1, one diagnostic code with a reason enum, and the file extension in
section 7.

## 9. Decisions

The owner answered on 2026-09-23. Q1: the literal `toolCatalog({...})` call in
`zttp:tool`. Q2: a handler under the tool profile is tool-only, so build rule 8
applies. Q3: `maxLength` and `minLength` count Unicode scalar values. Q4: the
maximum nesting depth is 8 and the `maxInputBytes` ceiling is 1 MiB (1048576).
The recommended defaults at the end of section 8 stand.

The owner decided two more points on 2026-09-23. Both surface changes of T2
(the `zttp:tool` module moves the module registry hash, and the new diagnostic
code moves the policy hash) make every recorded DeepSeek cassette stale,
because the expert tool results embed both hashes. The owner authorized one
DeepSeek corpus re-record after all T2 surface changes land. Until then, units
are committed on `main` with only the two `expert_codegen_record` replay tests
red, and each commit message says so.

## 10. Progress

| Unit | Commit | Content |
|---|---|---|
| U1 | `bc8134ef` | `tool_schema.zig`: subset check, compile, streaming validate |
| U2 | `a7965fd2` | inert `zttp:tool` module and the `tool_catalog` category |
| U3 | `86ca93c0` | `ToolEntry`, contract version 19, write and project |
| U4 | `72d80bf6` | builder extraction, build rules, per-route export walk, ZTS513 and its seed |
| U5 | `a289d768` | tool fixtures and B8.2 in the contract goldens |
| fix | `c928f4ba` | a partner manifest export name freed twice on a late parse error |
| fix | `e7b71599` | a golden check reran from cache after its handler fixture changed |
| U5 | `84d0f42b`, `515560ed`, `9f2f4b22` | DeepSeek corpus re-record (19/19 replay), coverage and convergence republished |

## 11. Implementation notes

Three points differ from sections 4 to 6, each found while building.

The reachable-export walk counts an import wherever a reachable body
mentions it, and it walks each module-scope declaration it names. This is
wider than section 4.4 A's call walk and has no "unresolved call" case: a
callback passed by name, an export handed around as a value, and a function
returned from a function are all counted. The walk names every IR tag. A tag
it cannot read refuses the tool as `exports_unanalyzable`, which no admitted
source reaches; the census carries it with that mechanism.

Rule 8 (tool-only) runs only on a catalog with no other refusal. An entry
refused for another reason claims no route, and without this gate the same
defect also reported its route as untooled.

B8.2 holds through the type checker: a validated input field is a `string`,
and passing it where a `nominal OrderId` is required is refused with ZTS203.
Nominal identity comes from an explicit annotation in handler code
(`const id: OrderId = input.id`). The formal spec's `OrderId(value)`
constructor does not exist in the current language (ZTS214). That spec text
is outside T2.

Check C2, measured on `main` after U5: `test-zts`, `test-modules`,
`test-precompile`, and `test-contract-golden` pass unfiltered. Mutation
probes, each restored byte for byte: the duplicate-key and closed-field checks
in `validate` (U1); the duplicate-name and subset checks in the contract
projection (U3); the duplicate-name check, rule 8, import counting, and
module-scope walking in the builder (U4); a broken fixture in the golden step
(U5). Each failed a named test. The census covers `SubsetRefusal` (25
members), `ValidateRefusal` (18), and `ToolCatalogRefusal` (17, one carried
with a mechanism).

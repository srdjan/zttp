# zttp Consumer Contract

> **Version 1.** Every shape in this document is a version-1 surface. A consumer
> declares the version it implements and a producer matches it by equality, never
> by range. This document is a proposal: [Roadmap](roadmap.md#proposal-decisions)
> owns its status, and nothing here describes scheduled work.

This page defines how a downstream application programs against zttp. It covers the
document a consumer writes, the three questions it can ask, the answers it can receive,
and the closed vocabularies that bound all three.

A consumer is any system that wants **zttp to build, prove, or serve a handler** on its
behalf. The first is Metadoor, which authors specifications and invariants and lowers
them into the declaration defined here. The reference producer is this repository.

Conformance language is MUST, MUST NOT, and MAY, per RFC 2119. Every binding requirement
carries a number in section 10 or section 11, and the prose that motivates one names that
number. A MUST with no number is a drafting error: C6 and P14 require each side to name
the case that demonstrates each of its obligations, and an unnumbered requirement cannot
be named by one. Version 1 states no SHOULD: an obligation either binds or it is not an
obligation yet. Section 8.1 is change control rather than conformance and says so where
it stands.

---

## 1. Status

Stated per side, so no reader takes a specified obligation for a shipped one.

**Producer, this repository.** `zts agent --stdin-json` schema 2 is implemented and
carries the adjudication stage: `verify` takes `file`, `properties`, and `content`, and
answers with `file`, `source_digest`, and `results`. Prompt-driven generation is
implemented. Property-goal generation is implemented and drives the five properties the
counterexample solver models. The application invariant specification is the only
consumer document that traverses all three stages; a project-supplied capability policy is
also bound, as executable-graph member kind 8, but it is not authored against this
contract. The acceptance policy is a compile-time value with two presets and no file
format. One of eight consumer obligation properties is re-derived by the acceptance
kernel; the other seven are disclosed.

The declared data-label path of section 9.2 is implemented for the M4 release boundary:
the declaration file (`packages/zts/src/declaration.zig`) reaches every flow check of the
handler through `--declaration`, `-Ddeclaration`, or the `declaration` key in
`zttp.json`, the flow checker enforces its classifications (P9), and the contract (version
20) carries the P8 status of each entry. The declaration does not yet bind as a graph
member; that is M4 T5.

Nothing else in this document is implemented. The declaration document, the admissibility
stage, spec-driven generation, and the published vocabulary envelope are obligations
stated here, not behaviour that exists.

Three earlier claims in this document did not hold against the tree. Each is now stated as
what it actually is rather than as shipped behaviour: the declared-classification path is
obligation P9, the capability ceiling no longer predicts a property (section 4.3 and P3),
and the no-store topology is a named profile rather than a consequence of the default
ceiling (section 8).

**Consumer, Metadoor.** Its engine seam produces code and does not consume this contract.
Its zts adapter is out of tree, carries one commit, and is stale against the current
language profile and module registry: it emits the `zigttp:` specifier prefix, which the
resolver refuses, and names a `compose` module the registry does not hold.

**Consumer, Mighty.** Deferred by decision. Its admission specification addresses the
artifact stage of section 3 and is not designed against here.

---

## 2. Terminology

- **Consumer** - a system that asks this producer to build, prove, or serve a handler.
- **Producer** - the toolchain that answers. This repository is the reference producer.
- **Declaration** - the consumer-authored document defined in section 4. It is the input
  to admissibility, the target of generation, the obligation set for adjudication, and
  the bytes an artifact commits to.
- **Stage** - one of the three questions in section 3.
- **Driveability** - whether the producer can repair toward a property, only check it, or
  not express it. The three answers are `goal_driveable`, `structural`, and `unknown`.
- **Refusal** - an answer that the declaration names something outside a closed
  vocabulary. Distinct from an unproven property, which concerns source rather than
  vocabulary.

[CONCEPTS.md](../CONCEPTS.md) owns Handler Contract, Property, Proof profile, Spec,
Certificate, Acceptance kernel, Assurance grade, Disclosed edge, Residual guard, and
Application invariant. This document uses those terms and does not restate them.

---

## 3. The three stages

A consumer traverses all three. Consumers differ only in which stages they own.

| Stage | Question | Input | Existing mechanism | Declaration integration |
|---|---|---|---|---|
| Admissibility | Can you express this? | declaration | none | not implemented |
| Adjudication | Is this source acceptable? | declaration plus candidate bytes | `verify`, over source and property names | not implemented |
| Acceptance | Is this artifact the one that was declared? | artifact plus certificate | the acceptance kernel, over artifact obligations | not implemented |

The two columns are separate on purpose. `verify` and the acceptance kernel exist and work,
but neither accepts a declaration, compares an interface, enforces a ceiling, or reports per
declaration item. Reading the middle column as the right-hand one is how a reader concludes
that two of the three stages are done. No stage of this contract is implemented.

### 3.1 Two refusals that stay apart, per P6

Admissibility refuses a declaration that names something the producer has no vocabulary
for: an invariant kind outside the catalog, a capability category it does not model, a
property name outside the registry. The remedy is to change the declaration.

Adjudication reports a property it could not establish for the source it was given. The
source is legal and the property is expressible; the code does not carry it. The remedy is
to change the code.

P6 binds a producer not to report one as the other. Collapsing them tells a consumer to
edit the wrong artifact, and a consumer that cannot separate them cannot route the answer
to whoever can act on it.

"Could not prove" is also not one answer. Analysis can exhaust a budget, meet a construct
it does not model, lack a schema, or produce no contract at all, and none of those means
the source lacks the property. P2 carries the taxonomy that keeps them apart, and the
existing `verify` answers already distinguish `unknown_property`, `not_decided`,
`analyzer_proved`, and `analyzer_not_proved`.

Acceptance already honours the same discipline by stopping at a named `SemanticState`
rather than answering a bare no.

### 3.2 The declaration is the spine

What a consumer declares at admissibility is what generation targets, what adjudication
checks against, and what an artifact commits to by digest. One document fills four roles.

Those four roles want different things from the document, which is why P4 separates the
authored form from the canonical one. Admissibility and generation want a form a consumer
iterates on. Adjudication wants a frozen obligation set. The artifact wants bytes that do
not move. A digest over a canonical encoding gives the last two without freezing the first,
and it is the same split `invariant_config.zig` already makes between authored JSON and
bound `ZTINV1` bytes. A digest proves that one document was carried through; it does not
prove that generation targeted every item in it or that adjudication checked each one. P16
is the obligation that carries per-item coverage; P2 only types the admissibility answer.

This generalizes a mechanism that already exists rather than introducing one. The
application invariant specification is authored as JSON, canonicalized to `ZTINV1` bytes,
checked at build time, bound as executable-graph member 17 with its enforcing native
adapter as member 18, and re-checked by the acceptance kernel. It is the only consumer
input that traverses all three stages today. The remaining sections of the declaration
follow its pattern.

---

## 4. The declaration

The declaration is a closed template, not a predicate language. Every field draws from a
vocabulary this repository publishes, so the document cannot state anything the producer
has no way to answer. This is the discipline `packages/tools/src/invariant_config.zig`
already applies to invariants, raised one level.

Version 1 covers the handler boundary and has five sections.

### 4.1 Interface

The routes the handler answers and the shapes it accepts and returns. Bounded by what
`ApiRouteInfo`, reached through `ApiInfo.routes` in
`packages/zts/src/contract_types.zig`, already expresses: method and path pattern,
request schemas, response variants with their status codes, and authentication metadata.
The sibling `RouteInfo` in the same file is the AOT route-table record. It carries
`pattern`, `route_type`, `field`, `status`, `content_type`, and `aot`, and none of the
fields this section draws on.

`ApiInfo` carries `schemas_dynamic` and `routes_dynamic`. Those flags describe a handler,
so they are read at adjudication rather than at admissibility, where no source exists yet.
P10 binds adjudication to fail a handler whose route or schema surface is dynamic against a
declaration that states an interface, because a surface the compiler could not enumerate
cannot be compared to a declared one. This is an unproven interface, not a refused
declaration, and P6 governs which one it is reported as.

A handler whose dynamism is deliberate, such as a gateway or a catch-all proxy, has no
remedy under that reading, because "change the code" is not an answer when the code is
correct. Version 1 does not solve this. A declaration states an interface or it does not,
and a handler that intends a dynamic surface declares no interface and forgoes the
comparison. Section 13 records the missing case.

### 4.2 Properties

The properties the handler must carry, drawn from the seventeen version-1 spec names in
`packages/zts/src/spec_discharge.zig`.

Admissibility classifies each name through `classify` in
`packages/pi/src/property_goals.zig` and answers with one of three values:

- `goal_driveable` - the counterexample solver models this property, so generation can
  aim at a falsifying input and repair toward green.
- `structural` - the compiler computes this property, and generation cannot drive it. It
  is checked, not repaired.
- `unknown` - `classify` recognizes the name as neither a driveable goal nor a boolean
  field of `PropertiesSnapshot`. This is a refusal.

`classify` is not by itself a registry check. Its structural branch accepts any boolean
field of `ui_payload.PropertiesSnapshot`, which is a wider set than the seventeen version-1
spec names: `has_egress` and `post_only` classify as `structural` while being absent from
`v1_specs`. P11 binds admissibility to check a declared property name against `v1_specs` as
well, because `classify` alone will accept a name the declaration has no vocabulary for.

A declaration name is also not always the verifier wire name. The registry spells
`result_safe`; the name a client sends and reads is `results_safe`, mapped in
`packages/zts/src/proof_trace.zig`. P12 binds a producer to translate rather than forward,
and to publish the mapping between the seventeen spec names, the twenty handler property
fields, the verifier wire names, and the eight consumer obligation properties. Those four
sets are not one vocabulary, and an analyzer result must not become a kernel-checked claim
by passing under a similar name.

A structural property that adjudication cannot establish has no automated remedy, because
generation cannot drive it. Version 1 does not answer that with a refusal of the whole
declaration. P13 binds the producer to report it as a disclosed gap, following the disclosed
edge and residual guard pattern the certificate already carries, and C8 binds the consumer
to record which gaps it accepted. A declaration carrying an accepted gap was not proven
entire, and the accepted gap has an owner.

The split between driven and checked is not a design choice.
[Roadmap](roadmap.md#considered-and-refused) records a refusal to widen the autoloop past
solver-backed boolean properties, because the verdicts assume a decidable check.

### 4.3 Capability ceiling

The categories the handler may reach, from the ten in
`packages/zts/src/module_authorization.zig`, and the modules it may import, from the
twenty-seven in `packages/zts/src/builtin_modules.zig`.

The ceiling is a parameter of the declaration, not a fixed rule.

**A ceiling does not determine a property.** A ceiling is an upper bound on what the
handler may reach. It establishes that an operation is permitted, never that one occurs,
so it settles almost no property in either direction. Determinism is the worked case.
`packages/zts/src/contract_builder.zig` states that determinism "answers whether a varying
value reaches the response rather than whether one was read at all, so a handler that logs
a timestamp and answers a constant keeps the property," and the test
`"a clock read that never reaches the response keeps determinism"` in
`packages/zts/src/flow_checker.zig` covers exactly that handler. Its comment names the
capability rule as "the false negative the interim capability rule had to special-case."
Permitting `clock` therefore does not make `deterministic` unprovable, and neither does
reading a clock. Admissibility also runs with no source, so it cannot know which exports
the eventual code reaches.

Exclusions do not run the other way either. Excluding a category generally makes a property
easier to establish rather than harder, so a narrow ceiling is not a source of
unprovability to report.

P3 therefore binds admissibility to answer `requires_source_analysis` for every conclusion
the declaration alone does not determine, and to refuse only an explicit contradiction: a
declared property whose discharge the declared ceiling forbids outright. That set is small
and version 1 expects it to be near empty. Admissibility's value is vocabulary checking
rather than prediction, and a producer that predicts here hands a consumer a refusal the
compiler would not have made, which is also the policy pessimism P6 forbids in the
vocabulary-refusal bucket.

#### Profiles

Version 1 names three ceilings rather than one default. A declaration selects one and MAY
narrow it by module. P15 binds the producer to enforce the selected ceiling.

<!-- BEGIN GENERATED: capability profiles. Edit packages/zts/src/capability_profiles.zig, then run `zig build vocab-envelope-write`. -->

| Profile | Categories | Excluded modules | Requires `read_only` | What it is for |
|---|---|---|---|---|
| `boundary` | `env`, `clock`, `random`, `crypto`, `stderr`, `policy_check` | `zttp:cache`, `zttp:ratelimit` | yes | The no-store handler of section 8 |
| `adapter` | `env`, `clock`, `random`, `crypto`, `stderr`, `policy_check`, `network`, `runtime_callback` | `zttp:cache`, `zttp:ratelimit` | no | The proven adapter of section 9 |
| `ledger` | `env`, `clock`, `random`, `crypto`, `stderr`, `policy_check`, `sqlite` | `zttp:cache`, `zttp:ratelimit`, `zttp:sql` | no | A declaration naming an application invariant, which has nowhere else to live |

<!-- END GENERATED: capability profiles -->

**The no-store property needs two tests, not one.** A category list alone does not deliver
it, and neither does a module list.

The first test is the module list. Twelve module bindings declare `.stateful = true`. Most
fall to a category `boundary` already excludes: `zttp:sql` and `zttp:ledger` need `sqlite`,
the workflow family `zttp:durable`, `zttp:queue`, `zttp:io`, `zttp:scope` and
`zttp:workflow` needs `runtime_callback`, and `zttp:fetch` and `zttp:service` need
`network`. `zttp:cache` does not. It needs only `clock` and `policy_check`, both of which a
boundary handler wants for ordinary reasons, and `cacheGet` hands back a value a separate
write put there, which is why its binding declares `.unknown`. No capability category
excludes it, so `boundary` excludes it by name. `zttp:ratelimit` is excluded by name too,
for the weaker reason that it retains a counter between requests; its result derives from
the limiter's own state rather than from a value some other call stored, which `AGENTS.md`
records as a different shape.

`zttp:validate` needs no capability at all, so no ceiling can exclude it, and it is
correctly not excluded. Its state is a schema registry the handler compiles from literals
in its own run, so it is not a channel through which one request's data reaches another.
The compiler already draws this line rather than leaving it to a reader:
`exportReadsVaryingSource` in `packages/zts/src/flow_checker.zig` keys on `stateful` and a
`.read` effect, which is the precise test for "another request could have written what this
returns," and its comment names `zttp:validate` as the exclusion, because demoting it "would
be a false negative on the most common validation path." A handler that cannot validate its
input cannot carry `input_validated`, so excluding it would cost a goal-driveable property
to prevent nothing.

The second requirement is `read_only`, and it is about effects rather than storage. The two
should not be run together. `schemaCompile` and `schemaDrop` are `.effect = .write`, and the
test `"handler-body registration remains a request-path write"` in
`packages/zts/src/contract_builder.zig` calls `schemaCompile` inside the handler and asserts
that `read_only`, `retry_safe` and `idempotent` all become false. That is a real constraint
and `boundary` keeps it, because section 8 wants no effect outside logging as well as no
store. It is not a no-store test: the module's own documented usage registers schemas at
module scope, where `read_only` holds, and the handler-body form is the discouraged pattern
rather than a storage channel.

So `boundary` carries three requirements and each answers a different question. The category
list bounds what the handler may reach. The module list is what delivers no retained store,
because `cacheGet` returns a value a separate request wrote and no category excludes it.
`read_only` bounds effects. A profile that ran only the category list would report a
no-store handler that stores.

**A category is coarser than a module, and `adapter` shows the cost.** `zttp:fetch` needs
`network` and `runtime_callback` together, so egress alone does not reach a wrapped system,
and `zttp:service` additionally needs `filesystem`. Granting `runtime_callback` also admits
the whole workflow family and every piece of durable state in it. An `adapter` handler is
therefore not a no-store handler that also makes calls. A declaration that wants egress and
nothing else narrows `adapter` by excluding those five modules, and P15 requires
admissibility to report the ceiling it was actually given rather than the one that was
meant.

**The `ledger` profile exists because section 4.4 would otherwise be unreachable.** Both
catalogued invariant kinds, `balance_conservation_v1` and `declared_accounts_v1`, are
predicates over committed posting groups, and `packages/proof-checker/src/checker.zig`
rejects with `invariant_operation_required` when a certificate declares invariants and no
invariant operation was observed. Those operations come from `zttp:ledger`, which needs
`sqlite`. Under `boundary` or `adapter` a declaration could name an invariant that no
artifact could ever discharge. The remedy is the third profile, not a relaxation of the
checker's requirement: an invariant with no operation to constrain is a claim about
nothing, and the checker is right to refuse it. A `ledger` declaration admits `zttp:ledger`
and not `zttp:sql`, which is what a module list is for, and it does not carry `read_only`,
because posting to a ledger is a write.

An absent category is a refusal, never a permissive default. This matches
`packages/proof-checker/src/capability_policy.zig`, which records that an absent list is
not an empty one and neither is a licence. The same holds for an absent module.

### 4.4 Invariants

The application invariants the handler must preserve, from the closed catalog in
`packages/proof-checker/src/invariant.zig`, each with its instance parameters.

A consumer parameterizes an instance, never a predicate. `balance_conservation_v1` takes
a ledger identifier and a currency set. `declared_accounts_v1` takes a matcher set of
exact and prefix rules. The predicate itself is the producer's, dispatched by the linked
native adapter whose manifest is bound as its own graph member.

P5 binds an invariant the catalog cannot express to be reported as `no_enforcement`,
never silently dropped and never contributing to a proven property. The term is taken
from Metadoor's `InvariantProofStatus` rather than invented, so both sides read one word
the same way.

### 4.5 Classifications

The classifications the consumer asserts over data the producer did not produce, each
naming a field and the label it carries. This is the section sections 9.2, P8, P9 and C7
depend on, and without it those obligations name a declaration field that does not exist.

A classification entry names the source it applies to, the field path within that source,
and one label from the flow checker's vocabulary. A consumer declares a field of a wrapped
system's response as `secret`, and from that point the value cannot reach a response body,
a log, or an outbound request without failing the build.

Three properties of this section are not optional, because each is a way the section could
report success while enforcing nothing:

- A field path is matched by the whole path, never by its trailing segment. `User.email`
  and an unrelated `.email` are different fields, and P9 forbids conflating them.
- A declared field that the analysis never saw is reported, per P8. A declaration naming a
  field that never appears enforces nothing while the build passes.
- A malformed entry is a refusal, not a skipped line, per P9. A discarded entry is an enforcement
  the consumer believes it has.

The label vocabulary, the source selector, and whether an entry is required or optional are
version-1 content, not deferred work. P8 and P9 cannot define conformance without them: a
producer cannot report a match against a path grammar nobody wrote, and a consumer cannot
know which labels it may name. They are expressed in the serialization P4 requires, and
they are the reason P4 has to land before P8 and P9 can be tested rather than merely
stated.

Version 1 of that content, as implemented for the M4 release boundary
([T4 design note](plans/2026-09-23-m4-t4-declared-labels-design.md)):

- The declaration is an authored JSON file named by zttp.json's `declaration` key or a
  `--declaration` flag, with `version: 1` and a `classifications` array that must not be
  empty. An unknown field, a duplicate key, or any entry breaking a rule below refuses the
  whole file with a named reason and the entry's index (`packages/zts/src/declaration.zig`).
- Every entry carries `source`, `path`, `label`, `required`, and `reason`, with no defaults.
- The source selector is `fetch:<host>`, a lowercase host that a `fetch` or
  `fetchWithRetry` URL names, or `service:<name>`, a service that `serviceCall` names.
- The path is 1 to 16 dot-separated identifier segments from the root of the response
  body. Version 1 has no wildcards and no array indexes.
- The label is `secret` or `credential`. No other label may be declared: declaring
  `validated` or `internal` would weaken a value rather than protect it.
- An entry applies at its exact path, below it, and at any aggregate above it, and never at
  a sibling; a fetch whose host is not a literal is treated as any declared host.
- After the flow check each entry reports `matched`, `indeterminate`, or `absent`, in the
  contract and in `zts check --json`. A `required` entry that is `absent` fails the build.

### 4.6 Tool catalog (tool profile)

A handler under the tool profile of the M4 release boundary publishes a tool catalog. It
differs from the five sections above in one way: the consumer does not author it. The
compiler derives it from the handler's literal `toolCatalog({...})` declaration, and the
build refuses a catalog it cannot read with ZTS513. The catalog is still carried under P4's
rules - canonical, specified here, and bound by digest as its own executable-graph member,
`tool_catalog = 19` - so a consumer can recompute the digest without the producer's code.

The canonical form is `ZTCAT1`. Integers are little-endian, and every string is UTF-8 with
a u32 byte-length prefix. Every field is always written, so there are no defaults and no
omissions. The two scope fields are the only strings that may be empty: length 0 means that
the entry binds no input field to that identity.

```text
magic            8 bytes  "ZTCAT1\0\0"
schema           u16      2
entry_count      u16      1..64
entry, entry_count times, strictly increasing by name bytes:
  name             string  1..64 bytes
  method           string  1..16 bytes, uppercase ASCII A-Z
  path             string  1..512 bytes, starts with "/"
  description      string  1..4096 bytes
  input_name       string  1..64 bytes
  input_schema     string  canonical schema JSON, 1..65536 bytes
  output_name      string  1..64 bytes
  output_schema    string  canonical schema JSON, 1..65536 bytes
  max_input_bytes  u32     1..1048576
  scope_tenant     string  0 (absent) or 1..64 bytes: the input field bound to the tenant
  scope_subject    string  0 (absent) or 1..64 bytes: the input field bound to the subject
  export_count     u16     0..256
  export, export_count times, strictly increasing by (module, name):
    module           string  1..64 bytes
    name             string  1..64 bytes
trailing bytes: refused
```

Strict increase refuses a duplicate name and a duplicate export. No two entries share a
(method, path) route. Schema 2 added the scope fields, which carry the entry's `scope`
binding (M4 T5); the kernel accepts schema 2 only. The build admits a scope field only when
it names a required top-level string property of the input schema; the kernel checks its
length and encoding. A schema is written in canonical schema JSON: no whitespace; strings
JSON-escaped (`"`, `\`, and bytes below 0x20, with `\u00XX` for those without a short
escape) and every other byte written as it is; keys per node in the order `type`, `title`,
`description`, then for an object `additionalProperties`, `properties`, `required`, for a
string `minLength`, `maxLength`, `format`, `enum`, for a number or integer `minimum`,
`maximum`, `enum`, and for an array `items`, `maxItems`, `minItems`; `title`,
`description`, `format`, `minimum`, `maximum`, and `enum` only when declared, `minLength`
and `minItems` only when not 0, and `required` always; properties, required names, and
string enum members sorted by bytes, number enum members sorted ascending; and a number that
is a whole value below 2^53 in magnitude written as an integer, any other in the shortest
decimal form that reads back to the same double.

The digest is SHA-256 over the ASCII domain `zttp-tool-catalog-v1` followed by the
`ZTCAT1` bytes. The acceptance kernel decodes the bytes itself, recomputes the digest, and
requires exactly one `tool_catalog` graph member with ordinal 0 carrying it
(`packages/proof-checker/src/tool_catalog.zig`). The kernel does not check that a schema is
inside the closed tool schema subset, because that needs an allocating parser; the runtime
compiles every schema from the accepted bytes and refuses to start when one does not
compile.

---

## 5. Generation modes

Two modes over one loop. Both propose source through the same change-set path, both take
the same compiler veto, and both are measured the same way.

| Mode | Input | Status |
|---|---|---|
| Prompt | free text | implemented |
| Property goal | one or more driveable property names | implemented |
| Specification | a declaration | not implemented |

Prompt mode and specification mode differ only in their input. A declaration replaces the
prompt; it does not replace the compiler, and it does not change what a veto means.

Specification mode makes convergence measurable per declaration rather than per prompt.
That figure belongs beside the existing one in [Convergence](convergence.md) and is
subject to the same rule: a published number names the corpus, the model revision, and
the policy hash it was recorded against.

P7 binds a producer implementing specification mode to reuse the existing veto loop. A second
generation path with its own acceptance rules would produce a second, unmeasured
convergence claim.

---

## 6. Published vocabularies

Every closed alphabet the declaration draws on, with the file that owns it. Counts are
stated so a drift gate can check them and a reader can fail the document against the tree.

<!-- BEGIN GENERATED: alphabet counts. Edit the Zig declarations, then run `zig build vocab-envelope-write`. -->

| Alphabet | Members | Source of truth |
|---|---|---|
| Capability categories | 10 | `packages/zts/src/module_authorization.zig` |
| Compiler spec names | 17 | `packages/zts/src/spec_discharge.zig` |
| Handler property boolean fields | 19 | `packages/zts/src/contract_types.zig` |
| Consumer obligation properties | 8 | `packages/proof-checker/src/proof_system.zig` |
| Assurance grades | 5 | `packages/proof-checker/src/verdict.zig` |
| Acceptance stages | 12 | `packages/proof-checker/src/verdict.zig` |
| Reason codes | 92 | `packages/proof-checker/src/verdict.zig` |
| Evidence edge kinds | 6 | `packages/proof-checker/src/certificate.zig` |
| Residual guard kinds | 5 | `packages/proof-checker/src/residual.zig` |
| Residual guard families, catalogued | 4 | `packages/proof-checker/src/residual.zig` |
| Invariant kinds | 2 | `packages/proof-checker/src/invariant.zig` |
| Account matcher tags | 2 | `packages/proof-checker/src/invariant.zig` |
| Executable-graph member kinds | 19 | `packages/proof-checker/src/executable_graph.zig` |
| Virtual modules, in-tree base | 28 | `packages/zts/src/builtin_modules.zig` |
| Virtual modules, effective for this build | 28 | `packages/zts/src/builtin_modules.zig` |
| Residual guard families, enabled | 3 | `packages/proof-checker/src/residual.zig` |
| Goal-driveable properties | 5 | `packages/pi/src/property_goals.zig` |
| Capability profiles | 3 | `packages/zts/src/capability_profiles.zig` |

<!-- END GENERATED: alphabet counts -->

One alphabet sits outside the generated table because it is not a membership.
Diagnostic codes run from ZTS0xx to ZTS7xx, owned by
`packages/zts/src/diagnostic_catalog.zig`. The envelope publishes member lists, and a
range is a claim about numbering rather than a set, so a count here would be a different
kind of statement from every other row. `zts describe-rule` enumerates them.

Two counts need a qualifier before a gate reads them. Virtual modules = 27 counts
`runtime_builtins`, the in-tree base. `all = builtins ++ extension_bindings.all`, so a
build that registers an extension holds more. Residual guard families = 4 counts the
catalog; three are in `enabled_families` today, and `sql` is catalogued but not
release-enabled. In both cases the alphabet and the effective set are different questions,
and P1 binds the envelope to publish both as separate blocks. A consumer pins one of them
and has to be able to tell which.

Pinned identities, each compared by equality:

| Identity | Value | Source |
|---|---|---|
| Certificate schema | 4 | `packages/proof-checker/src/proof_system.zig` |
| Proof system | `zttp_pcc_v3` = 3 | `packages/proof-checker/src/proof_system.zig` |
| Semantics epoch | 1 | `packages/proof-checker/src/proof_system.zig` |
| Handler contract version | 20 | `packages/zts/src/contract_types.zig` |
| Agent protocol schema | 2 | [Agent Protocol v2](internals/agent-protocol-v2.md) |

### 6.1 The vocabulary envelope

These alphabets are published together, in one machine-readable envelope carrying a
contract version, one block per alphabet with its members, and the identity hashes
`zts meta --json` already emits.

**This envelope does not exist.** It is producer obligation P1. It is described here so
the obligation is specific enough to implement and to gate, not because it ships.

---

## 7. Two properties of this contract that are easy to lose

**A consumer calls the checker; it does not reimplement the rules.** The producer's
refusals are published through `zts check`, `zts restrictions`, `zts features`, and
`zts describe-rule`. A consumer holding its own copy of those rules holds a rulebook
where a verdict belonged, and it will drift. This has already happened: the out-of-tree
zts adapter still forbids `null`, which the profile now admits where the type names it,
and it misses declaration destructuring, template interpolation, ZTS613, ZTS614, ZTS616,
and object literal shorthand.

**The producer learns one declaration, not one per consumer.** A consumer lowers its own
intermediate representation into the declaration defined here, and that lowering is the
consumer's code. A producer that learned each consumer's representation would carry one
specification compiler per consumer, which is the coupling this contract exists to
remove.

---

## 8. Topology

Version 1 places the consumer and the producer in separate processes. The consumer holds
persistence and effect authority.

**The handler holds no store under the `boundary` profile, and only under it.** That is a
property of the ceiling section 4.3 names, not of process separation. Separate processes
place no authority anywhere by themselves. `zttp:cache` and `zttp:ratelimit` need nothing
beyond `clock` and `policy_check`, so a category-only ceiling admits both while both hold
state across calls, which is why `boundary` excludes them by name. The `adapter` profile
adds `network` and `runtime_callback`, a network call is itself an effect, and
`runtime_callback` admits the whole workflow family with its durable state, so an adapter
handler is not a no-store, no-effect handler and does not claim to be. A declaration that
wants egress without durable orchestration narrows `adapter` by module, per section 4.3.

The reason is the consumer's own atomicity requirement. Metadoor's decision D-022 has its
state writer persist the permit's idempotency key on the history entry in the same write
as the state change, and its reconciler answers `applied` only when that key is present.
If governed state sits in a producer-owned store and the permit sits in the consumer's
ledger, that single transaction no longer exists and the reconciler loses its only sound
answer. D-020 points the same way: a claim guard is evaluated inside the claim
transaction against the adapter's own rows, and no callback crosses that port.

This is not a reduced producer. All five goal-driveable properties are boundary data
properties: `no_secret_leakage`, `no_credential_leakage`, `injection_safe`,
`input_validated`, and `pii_contained`. A handler that validates input, shapes data, and
constructs a response is where those properties live. Both profiles also make a handler a
deterministic function of its request and the virtual-module responses it received, which
is what makes `--trace` and `-Dreplay` meaningful over either.

A `boundary` handler is not a pure function of its request, and the document should not say
so. It may read `env`, `clock` and `random`, and it may write to `stderr`. What `boundary`
establishes is narrower and worth stating exactly: no retained store, and no effect outside
logging. Retained state, external effect and response determinism are three properties, and
none of them follows from another. `deterministic` in particular is decided by whether a
varying value reaches the response, per section 4.3, not by whether the ceiling admits a
varying source.

The consumer passes the data in. A handler that needs a record receives it in the request
rather than reading it.

### 8.1 The acceptance test for any change to this arrangement

The provider succeeds, the process crashes before recording, a human revokes authority,
and the system restarts. The system must preserve the unknown effect, block automatic
retry, retain the original permit and receipt lineage, and refuse new execution without
current authority.

A `boundary` handler passes this by construction, because it performs no effect that a
crash could leave unrecorded. That comes from the whole profile in section 4.3, the module
exclusions and the `read_only` requirement as well as the six categories, and not from the
categories alone. An
`adapter` handler does not pass it by construction, because a network call is an effect
whose outcome a crash can leave unknown; it passes only where the consumer still owns the
permit and the record, which is what section 8 places there.

This subsection is change control, not conformance. It states what a proposal has to
demonstrate before effect authority moves into the artifact, so it binds a future change
to this document rather than a producer or a consumer, and it carries no P or C number for
that reason.

---

## 9. The proven adapter

A named arrangement, not an addition to the contract: a handler placed in front of a
system the producer cannot analyze. A legacy service, a third-party API, or a runtime in
another language. The handler validates and shapes what goes in, constrains where it may
go, enforces the classifications the consumer declared on what comes back, and interprets
the result. It needs no mechanism this document has not already defined.

It is the shape section 8 describes, applied to a system nobody intends to rewrite. Its
mechanism is the closest to implemented of anything here, but it is not complete: the
capability policy, the address-scope egress check, the `external` label default, and
replay all exist, and the declared-binding input does not reach the flow checker. Open
P9 in section 10 states what that costs. Until P9 is met, the arrangement
available before any obligation in section 10 is met is the constrained-egress half, not
the declared-classification half.

### 9.1 Three levels of claim, which C7 keeps apart

**Unconditional.** The adapter's own handling is proven, to whatever the declaration
required and adjudication established: input validation, injection safety, response
totality, result checking, and no leakage of secrets the adapter itself handled. Egress is
constrained by the capability policy, which checks the address scope a permitted endpoint
resolves to and not only the endpoint, so a permitted name resolving to a link-local
address is refused before a socket is opened. The refusal is conditional on the policy:
`link_local` is a configurable scope, so the check holds only where that scope is not
permitted. The adapter is also a deterministic function of its
request and the virtual-module responses it received, which is what lets `--trace` and
`-Dreplay` reproduce a run. Replay reproduces the recorded wrapped-system response; it
does not call the wrapped system again and establishes nothing about what that system
would answer now.

**Conditional.** Classifications the consumer declares over the wrapped system's response
are enforced. This holds only for what was declared, and only by the names declared.

**Never.** Nothing about the wrapped system's interior is discovered. If it leaks,
corrupts, or mis-authorizes internally, no property in this contract reaches that.

### 9.2 The mechanism, and its default

`zttp:fetch` and `zttp:service` declare `.return_labels = .{ .external = true }`. The
`external` label is not `secret` and not `credential`, so by default a wrapped system's
response reaches a client without violating `no_secret_leakage`. That default is correct:
the producer makes no claim about data it did not produce. It also means the default
stops nothing.

A consumer that knows better declares it. The declaration's classifications section
(section 4.5) names a source, a field path in its response body, and `secret` or
`credential`, and the flow checker enforces it from that point: the value cannot reach a
response body, a log, or an outbound request without failing the build with ZTS400 to
ZTS403, and the diagnostic names the entry. The mechanism is origin tracking
(`packages/zts/src/flow_checker.zig`, M4 T4). A value from a declared source carries its
source and its path from the body root, through `.json()`, `.text()`, `.body`, member
reads, and const aliases. It carries the declared labels of every entry at its path,
below it, and at any aggregate above it. A member read on such a value takes only its own
path's labels, so a sibling field is not labelled. Anything else - a call argument, a
spread, a computed read, a validator - keeps the labels and loses the origin, which widens
labels and never narrows them.

The three ways the earlier short-name mechanism was blind are each closed and each has a
test that fails when the closure is removed: whole-object forwarding carries the field's
labels (P9 condition a); matching compares whole paths from the source root, so an
unrelated `.email`, or the same last segment under another parent, never matches (P9
condition b); and a malformed entry refuses the whole declaration with a named reason (P9
condition c). A fetch whose host is not a literal is treated as any declared host, so a
computed URL cannot escape a declaration. After the flow check every entry reports
`matched`, `indeterminate`, or `absent` (P8), and a `required` entry that is `absent`
fails the build: a declaration naming a field that never appears enforces nothing.

The declaration is enforced at build time. It binds as its own executable-graph member in
M4 T5, when the capability ceiling joins it (P4).
### 9.3 The claim C7 forbids

C7 forbids a consumer to describe this arrangement as making the wrapped system safe. Safety is
compound, and what this produces is implementation evidence about one component.

The claim that survives review names the boundary and the declared set: the adapter's
handling is proven, and these named fields are enforced. Section 11 states this as C7.

### 9.4 Containment is a deployment property

A proven adapter in front of a system does not stop anything else reaching that system.
What the certificate establishes is what the adapter does. Whether another path bypasses
it is arranged in the network and is not visible in any artifact this contract defines. A
consumer that needs exclusive reachability establishes it separately, and C7 forbids reading
it out of an acceptance.

This is the same shape as the standing deployment assumption already recorded for the
protected ledger, where excluding other writers from the store is an assumption nothing in
the artifact verifies.

### 9.5 The first enforcement-map entry

The arrangement is also the worked example of a per-construct enforcement statement, which
P17 binds a target to publish for every construct it is handed.

A target answers on two axes for every construct it is handed. **Status** is one of
`implemented`, `specified`, or `not expressible`. **Enforcement point** is one of `build`,
`runtime`, `build and runtime`, or `none`. Neither axis alone is an answer.

| Construct | Status | Enforcement point |
|---|---|---|
| Declared response field classification | specified | build, once P9 is met |
| Egress endpoint and address scope | implemented | runtime |
| Any property of the wrapped system's interior | not expressible | none |

Two axes rather than one, because one value already produced a false answer here. This
table read "Checked at build" for the first row while nothing checked anything, which is
the exact failure the map exists to prevent, reproduced inside the map. A single value
forces a construct that is specified but unbuilt to borrow the vocabulary of one that
works. Splitting status from enforcement point also lets a construct be checked statically
and guarded at runtime, which a single value cannot express.

A boolean "supported" is not an answer either, because it lets a construct land on a target
that nominally supports its category while enforcing nothing specific about it.

---

## 10. Producer obligations

- **P1.** The producer MUST publish the section 6 vocabularies in one machine-readable
  envelope carrying a contract version, and MUST publish both the in-tree alphabet and the
  effective set for the build, as separate labelled blocks, wherever the two can differ.
  The envelope MUST carry the P12 name mapping. The producer MUST gate it by comparing a
  source-derived inventory against the published one for equality, member by member, and
  the gate MUST fail on a missing input, an empty inventory, and a build in which nothing
  depends on it. A gate that only asks whether the envelope changed is satisfied by an
  unrelated edit, and a count alone misses a substitution. An alphabet a consumer cannot
  enumerate is one it must track by hand, which is not a contract.
- **P2.** The producer MUST accept a declaration at the admissibility stage and answer per
  item. The answer MUST carry driveability and resolution as separate fields, because they
  are separate questions: a `goal_driveable` property can still need source analysis, and so
  can a `structural` one. Driveability is `goal_driveable`, `structural`, or `unknown`.
  Resolution is `admissible`, `requires_source_analysis`, or `refused`. The answer MUST be
  typed, not prose: a stable reason code, the item identifier, the field, the vocabulary it
  fell outside, and the expected identity where one applies, following the diagnostic
  envelope `verify` already carries. The producer MUST state whether one refused item stops
  the remaining checks, and MUST keep these apart as distinct answers: malformed
  declaration, unknown vocabulary, incompatible requirements, timeout, and internal failure.
  Invalid source, failed property and incomplete analysis belong to adjudication, which is
  the stage that holds source; admissibility MUST NOT report them. A consumer cannot write a
  parser against a shape that is named but not typed.
- **P3.** The producer MUST answer `requires_source_analysis` at admissibility for every
  conclusion the declaration alone does not determine, and MUST NOT infer that a declared
  property is unprovable from the capability ceiling. It MAY refuse an explicit
  contradiction, meaning a declared property whose discharge the declared ceiling forbids
  outright. Section 4.3 states why a ceiling settles almost nothing: it bounds what is
  permitted and establishes nothing about what occurs.
- **P4.** The producer MUST bind the declaration's canonical encoding as its own
  executable-graph member, following `invariant_spec`, whose loader in
  `packages/tools/src/invariant_config.zig` reads authored JSON and binds the canonical
  `ZTINV1` bytes. The canonical form MUST be specified well enough that a consumer computes
  the same digest from the same declaration without holding the producer's serializer:
  field order, defaults and omissions, duplicate-key handling, encoding, and size bounds.
  Binding authored bytes instead would make whitespace and key order load-bearing and buys
  no property this obligation needs.
- **P5.** The producer MUST report a declared invariant outside the catalog as
  `no_enforcement`, and MUST NOT let it contribute to any proven property.
- **P6.** The producer MUST keep a refusal distinct from an unproven property, per
  section 3.1, and MUST NOT report a policy pessimism as a vocabulary refusal.
- **P7.** Specification mode MUST reuse the existing veto loop and MUST be measured
  against a named corpus before any convergence figure derived from it is published.
- **P8.** The producer MUST report which declared field classifications matched a field
  the analysis actually saw, and which matched none. A declaration naming a field that
  never appears enforces nothing while the build passes, which is the vacuous-gate shape
  `AGENTS.md` records: a gate whose input is empty reports success and is then cited as
  evidence. An unmatched binding is not necessarily an error, because a field may be
  absent on some paths, but it MUST NOT be silent. The report MUST answer `indeterminate`
  rather than `matched` or `absent` whenever presence cannot be established, which includes
  possible presence. A static checker cannot know whether an opaque remote response carries
  a field the source never names, and two runs of the same source can receive `{}` and
  `{"ssn": "..."}`, so `absent` is a claim about the analysis and never about the data. The
  report MUST cover aliases, computed access, and whole aggregates as their own cases. A
  nonzero match count is not the claim.
- **P9.** The producer MUST enforce declared field classifications in the flow checker,
  and the option that carries them MUST reach the checker rather than the build report
  alone. An implementation satisfies P9 only when it also: refuses or reports
  `indeterminate` for whole-object forwarding of a value carrying declared fields, rather
  than passing it; matches a qualified binding only on the qualified path, never on its
  short name; and refuses a malformed binding entry rather than discarding it. Section 9.2
  records the current state, which meets none of this.
- **P10.** Adjudication MUST fail a handler whose route or schema surface is dynamic
  against a declaration that states an interface, and MUST report it as an unproven
  interface rather than a refused declaration.
- **P11.** Admissibility MUST check a declared property name against the version-1 spec
  registry, and MUST NOT treat `classify` as that check. `classify` accepts any boolean
  field of `PropertiesSnapshot`, which is the wider set.
- **P12.** The producer MUST translate a declaration property name into the verifier wire
  name rather than forwarding it, and MUST publish the mapping between the spec names, the
  handler property fields, the verifier wire names, and the consumer obligation properties.
  An analyzer result MUST NOT become a kernel-checked claim by passing under a similar name.
- **P13.** At adjudication, the producer MUST report a declared property it could not establish as a
  disclosed gap, following the disclosed edge and residual guard pattern the certificate
  already carries. It MUST NOT pass the declaration silently and MUST NOT refuse the whole
  declaration for that reason alone. A gap MUST carry the P2 reason that produced it, so a
  failed property, an incomplete analysis and an internal failure stay apart after
  disclosure. A declaration MAY name a minimum established set, and a producer MUST refuse
  the declaration rather than disclose a gap over a member of it. Without that set an
  all-gap outcome is conforming, which means conformance alone implies no minimum proof.
  A gap MUST also carry what the producer actually attempted, because P13 otherwise governs
  only reporting: an implementation that answers "could not establish" for every property
  without running an analysis satisfies every word of it. Reporting the attempt does not by
  itself impose a floor, and version 1 states none; what it does is make the absence of one
  visible to a consumer rather than indistinguishable from real work.
  Which gaps a consumer then accepts is C8.
- **P14.** The producer MUST demonstrate P1 to P13 and P15 to P17 in its own test suite, and
  MUST name which case demonstrates which obligation. A name is not evidence: each case MUST
  carry a stable identifier, an execution record, and its exact expected outcome, and an
  obligation carrying several distinct requirements MUST have a case per requirement rather
  than one case for the obligation. Evidence MUST include complete vocabulary coverage, a
  malformed input, an empty input, and, for every rejection path a gate can take, a probe
  that provokes that path and confirms the gate fails. One mutation of one gate is not
  coverage. This mirrors C6: a document that binds one side to evidence and not the other
  sets the lower bar where the claims are made.
- **P15.** The producer MUST enforce the declared capability ceiling: the selected profile,
  every narrowing the declaration applied, and the module list as well as the category list.
  It MUST report the ceiling that was actually applied, which is not always the one that was
  meant, because a category admits every module in it. Binding a ceiling into the artifact
  without enforcing it would satisfy every other obligation here while restricting nothing.
- **P16.** Adjudication MUST report, per declaration item, whether that item was checked,
  and with what outcome. A digest binds one document to one artifact and establishes that
  the document did not change; it does not establish that anything read it. An item the
  producer never examined MUST NOT be reported as established, and MUST be distinguishable
  from one that was examined and held. This is what makes section 3.2's four roles more
  than a claim about bytes.
- **P17.** The producer MUST publish the section 9.5 enforcement map for every construct a
  declaration can name, answering on both axes. A construct with no row is unanswered, not
  supported, and P14 MUST carry a case proving the map covers every construct the
  declaration vocabulary admits.

---

## 11. Consumer obligations

- **C1.** A consumer MUST pin every alphabet it reads by equality, and MUST refuse to
  start when an alphabet it reads names a member it does not know. A range admits a member
  whose meaning the consumer has not been taught. The refusal is scoped to what the
  consumer interprets: a member added to an alphabet it never reads is not its concern, and
  reading that as an envelope-wide refusal would stop every consumer on any growth
  anywhere.
- **C2.** A consumer MUST treat an absent capability category as a refusal, never as
  permitting nothing and never as permitting anything.
- **C3.** A consumer MUST obtain language verdicts by calling the producer's checker. It
  MUST NOT maintain its own copy of the producer's refusal rules.
- **C4.** A consumer MUST lower its own representation into the declaration. It MUST NOT
  expect the producer to read that representation.
- **C5.** A consumer MUST declare the contract version it implements, and a producer
  matches it by equality.
- **C6.** A consumer MUST demonstrate C1 to C5, C7 and C8 in its own test suite, and MUST name which
  case demonstrates which obligation. This document states both sides' obligations; it
  carries neither side's evidence.
- **C7.** A consumer operating a proven adapter MUST NOT describe the arrangement as
  making the wrapped system safe. It MUST state the boundary claim and the declared field
  set, MUST keep the three levels of claim in section 9.1 apart when it restates them, and
  MUST NOT present exclusive reachability of the wrapped system as something an acceptance
  established.
- **C8.** A consumer MUST record which disclosed gaps it accepted for a given artifact, and
  MUST NOT treat a declaration carrying an accepted gap as one that was proven entire. An
  accepted gap is a decision with an owner, not an absence.

---

## 12. Versioning and growth

A change that makes a conforming consumer or a conforming artifact non-conforming bumps
the contract version.

An alphabet grows by adding a member and bumping the envelope version. A member is never
renumbered and a retired value is never reused, which is already the stated rule for
`ReasonCode`: the numeric value is the contract and the spelling is the diagnostic.

The invariant catalog grows one kind at a time. A kind carries a wire ordinal, a
predicate version, whether a consumer must see it discharged, and whether it constrains
writes. A kind added without a row in the catalog table fails to compile, which is why
the table is the growth mechanism rather than a convention.

---

## 13. Not in version 1

Named so an omission is not read as permission.

| Excluded | Waits on |
|---|---|
| The full application surface: persistence, governed transitions, durable orchestration, service bindings | A version-1 declaration that is proven end to end first |
| An effect kernel inside the artifact, and the single-process topology | Section 8.1, plus an answer to where Metadoor's decisions D-020 and D-021 place authority once the ledger is inside the artifact |
| The artifact stage as a consumer-facing contract, and Mighty's admission obligations | Mighty returning to scope, and its own unresolved release-unit question |
| Hosted deploy | An accepted hosted scope, lifecycle policy, and control-plane CI |
| Promotion of any disclosed property to consumer-checked | One property or opcode family selected, per [Roadmap](roadmap.md#runtime-and-product-work) |
| Computed SQL resources in a declared ceiling | A policy that distinguishes read from write authority |
| More than one handler under one declaration: handler identities, route ownership, shared invariants, and whether acceptance is per handler or per release | One single-handler declaration proven end to end first. Metadoor is not a single-handler system, so this is a known gap rather than an unnoticed one |
| A declared interface for a handler whose route or schema surface is dynamic by design, such as a gateway | A declaration field that states intended dynamism. Version 1 offers no interface comparison for such a handler and P10 fails it, which is correct but unhelpful |
| Interface comparison rules: whether extra routes are admitted, how overlapping routes resolve, and whether schemas require equality or compatibility | A version-1 declaration that has compared one interface |
| Generation lifecycle: cancellation, retry, progress, resource budgets, and whether a retry resumes | Measurement of the veto loop under a declaration, per P7 |

---

## 14. Future consideration

**The full application surface.** A later declaration could name persistence, governed
transitions, durable orchestration, and service bindings. This is more tractable than it
sounds, because the producer already owns those as virtual modules: `zttp:sql`,
`zttp:durable`, `zttp:workflow`, and `zttp:service`. Such a declaration would name module
operations rather than introduce semantics, and the vocabulary would grow by the same
rule as section 12. The open question is not expressibility. It is that naming the
application structure makes the producer the owner of that structure, which is a product
decision rather than a compiler one.

**The single-process topology.** The consumer's effect kernel could be lowered into the
proven subset. The pieces exist in `zttp:durable`, `zttp:sql`, and `zttp:crypto`. The
obstacle is authority rather than mechanism: Metadoor's D-020 places the claim guard
inside the claim transaction and its D-021 derives rollbackability from the descriptor
kind the permit bound, and both belong wherever the ledger is. A proposal must pass section 8.1 rather than argue
around it.

---

## 15. Sources

- [Agent Protocol v2](internals/agent-protocol-v2.md) - the adjudication transport, its
  closed operation set, the `expected` guard, and version negotiation.
- [zts Expert Contract](internals/zts-expert-contract.md) - the version-1 structured tool
  surface and the metadata envelope this contract extends.
- [Verification](verification.md) - the compile-time checks, the published disclosed
  boundary, and the residual guard catalog.
- [Contracts and Auto-Sandboxing](contracts-and-sandboxing.md) - contract extraction, the
  capability-policy file, and `Proof<T, P>`.
- [Virtual Modules](virtual-modules/README.md) - the module list, exports, capabilities,
  and effects.
- [Roadmap](roadmap.md) - this document's status, and the recorded refusal that bounds
  section 4.2.
- [CONCEPTS.md](../CONCEPTS.md) - the shared vocabulary this document builds on.

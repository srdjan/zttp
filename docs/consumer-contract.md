# zttp Consumer Contract

> **Version 1.** Every shape in this document is a version-1 surface. A consumer
> declares the version it implements and a producer matches it by equality, never
> by range. This document is a proposal: [Roadmap](roadmap.md#proposal-decisions)
> owns its status, and nothing here describes scheduled work.

This page defines how a downstream application programs against zttp. It covers the
document a consumer writes, the three questions it can ask, the answers it can receive,
and the closed vocabularies that bound all three.

A consumer is any system that wants zttp to build, prove, or serve a handler on its
behalf. The first is Metadoor, which authors specifications and invariants and lowers
them into the declaration defined here. The reference producer is this repository.

Conformance language is MUST, MUST NOT, and MAY, per RFC 2119, and applies only to the
obligation sections. Version 1 states no SHOULD: an obligation either binds or it is not
an obligation yet.

---

## 1. Status

Stated per side, so no reader takes a specified obligation for a shipped one.

**Producer, this repository.** `zts agent --stdin-json` schema 2 is implemented and
carries the adjudication stage: `verify` takes `file`, `properties`, and `content`, and
answers with `file`, `source_digest`, and `results`. Prompt-driven generation is
implemented. Property-goal generation is implemented and drives the five properties the
counterexample solver models. The application invariant specification is the only
consumer document bound into the executable graph. The acceptance policy is a compile-time
value with two presets and no file format. One of eight consumer obligation properties is
re-derived by the acceptance kernel; the other seven are disclosed.

Nothing else in this document is implemented. The declaration document, the admissibility
stage, spec-driven generation, and the published vocabulary envelope are obligations
stated here, not behaviour that exists.

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

| Stage | Question | Input | Status |
|---|---|---|---|
| Admissibility | Can you express this? | declaration | not implemented |
| Adjudication | Is this source acceptable? | declaration plus candidate bytes | implemented as `verify` |
| Acceptance | Is this artifact the one that was declared? | artifact plus certificate | implemented |

### 3.1 Two refusals that MUST stay apart

Admissibility refuses a declaration that names something the producer has no vocabulary
for: an invariant kind outside the catalog, a capability category it does not model, a
property name outside the registry. The remedy is to change the declaration.

Adjudication reports a property it could not establish for the source it was given. The
source is legal and the property is expressible; the code does not carry it. The remedy is
to change the code.

A producer MUST NOT report one as the other. Collapsing them tells a consumer to edit the
wrong artifact, and a consumer that cannot separate them cannot route the answer to
whoever can act on it.

Acceptance already honours the same discipline by stopping at a named `SemanticState`
rather than answering a bare no.

### 3.2 The declaration is the spine

What a consumer declares at admissibility is what generation targets, what adjudication
checks against, and what an artifact commits to by digest. One document fills four roles.

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

Version 1 covers the handler boundary and has four sections.

### 4.1 Interface

The routes the handler answers and the shapes it accepts and returns. Bounded by what
`RouteInfo` and `ApiInfo` in `packages/zts/src/contract_types.zig` already express:
method and path pattern, request schemas, response variants with their status codes, and
authentication metadata.

`ApiInfo` carries `schemas_dynamic` and `routes_dynamic`. Those flags describe a handler,
so they are read at adjudication rather than at admissibility, where no source exists yet.
Adjudication MUST fail a handler whose route or schema surface is dynamic against a
declaration that states an interface, because a surface the compiler could not enumerate
cannot be compared to a declared one. This is an unproven interface, not a refused
declaration, and section 3.1 governs which one it is reported as.

### 4.2 Properties

The properties the handler must carry, drawn from the seventeen version-1 spec names in
`packages/zts/src/spec_discharge.zig`.

Admissibility classifies each name through `classify` in
`packages/pi/src/property_goals.zig` and answers with one of three values:

- `goal_driveable` - the counterexample solver models this property, so generation can
  aim at a falsifying input and repair toward green.
- `structural` - the compiler computes this property, and generation cannot drive it. It
  is checked, not repaired.
- `unknown` - the name is outside the registry. This is a refusal.

The split between driven and checked is not a design choice.
[Roadmap](roadmap.md#considered-and-refused) records a refusal to widen the autoloop past
solver-backed boolean properties, because the verdicts assume a decidable check.

### 4.3 Capability ceiling

The categories the handler may reach, from the ten in
`packages/zts/src/module_authorization.zig`, and the modules it may import, from the
twenty-seven in `packages/zts/src/builtin_modules.zig`.

The ceiling is a parameter of the declaration, not a fixed rule. Admissibility reports
which properties survive it: a declaration naming `clock` makes `deterministic`
unprovable, and admissibility MUST say so before any source is generated rather than
letting adjudication discover it.

For version 1 the default ceiling excludes `sqlite`, `network`, `filesystem`, and
`runtime_callback`. Section 8 states why. A declaration MAY narrow or widen the default,
and admissibility reports the consequence either way.

An absent category is a refusal, never a permissive default. This matches
`packages/proof-checker/src/capability_policy.zig`, which records that an absent list is
not an empty one and neither is a licence.

### 4.4 Invariants

The application invariants the handler must preserve, from the closed catalog in
`packages/proof-checker/src/invariant.zig`, each with its instance parameters.

A consumer parameterizes an instance, never a predicate. `balance_conservation_v1` takes
a ledger identifier and a currency set. `declared_accounts_v1` takes a matcher set of
exact and prefix rules. The predicate itself is the producer's, dispatched by the linked
native adapter whose manifest is bound as its own graph member.

An invariant the catalog cannot express MUST be reported as `no_enforcement`. It MUST NOT
be silently dropped and MUST NOT contribute to any proven property. The term is taken
from Metadoor's `InvariantProofStatus` rather than invented, so both sides read one word
the same way.

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

A producer implementing specification mode MUST reuse the existing veto loop. A second
generation path with its own acceptance rules would produce a second, unmeasured
convergence claim.

---

## 6. Published vocabularies

Every closed alphabet the declaration draws on, with the file that owns it. Counts are
stated so a drift gate can check them and a reader can fail the document against the tree.

| Alphabet | Members | Source of truth |
|---|---|---|
| Capability categories | 10 | `packages/zts/src/module_authorization.zig` |
| Virtual modules | 27 | `packages/zts/src/builtin_modules.zig` |
| Compiler spec names | 17 | `packages/zts/src/spec_discharge.zig` |
| Goal-driveable properties | 5 | `packages/pi/src/property_goals.zig` |
| Handler properties | 20 | `packages/zts/src/contract_types.zig` |
| Consumer obligation properties | 8 | `packages/proof-checker/src/proof_system.zig` |
| Assurance grades | 5 | `packages/proof-checker/src/verdict.zig` |
| Acceptance stages | 11 | `packages/proof-checker/src/verdict.zig` |
| Reason codes | 89 | `packages/proof-checker/src/verdict.zig` |
| Evidence edge kinds | 6 | `packages/proof-checker/src/certificate.zig` |
| Residual guard kinds | 5 | `packages/proof-checker/src/residual.zig` |
| Residual guard families | 4 | `packages/proof-checker/src/residual.zig` |
| Invariant kinds | 2 | `packages/proof-checker/src/invariant.zig` |
| Account matcher tags | 2 | `packages/proof-checker/src/invariant.zig` |
| Executable-graph member kinds | 18 | `packages/proof-checker/src/executable_graph.zig` |
| Diagnostic codes | ZTS0xx to ZTS6xx | the policy catalog |

Pinned identities, each compared by equality:

| Identity | Value | Source |
|---|---|---|
| Certificate schema | 4 | `packages/proof-checker/src/proof_system.zig` |
| Proof system | `zttp_pcc_v3` = 3 | `packages/proof-checker/src/proof_system.zig` |
| Semantics epoch | 1 | `packages/proof-checker/src/proof_system.zig` |
| Handler contract version | 18 | `packages/zts/src/contract_types.zig` |
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
persistence and effect authority. The handler holds no store.

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
constructs a response is where those properties live. Such a handler is also a pure
function of its request, which is what makes `--trace` and `-Dreplay` meaningful over it.

The consumer passes the data in. A handler that needs a record receives it in the request
rather than reading it.

### 8.1 The acceptance test for any change to this arrangement

The provider succeeds, the process crashes before recording, a human revokes authority,
and the system restarts. The system must preserve the unknown effect, block automatic
retry, retain the original permit and receipt lineage, and refuse new execution without
current authority.

Version 1 passes this by construction, because the handler performs no effect. Any
proposal that moves effect authority into the artifact MUST demonstrate it instead.

---

## 9. Producer obligations

- **P1.** The producer MUST publish the section 6 vocabularies in one machine-readable
  envelope carrying a contract version, and MUST fail a build in which an alphabet grows
  without the envelope changing. An alphabet a consumer cannot enumerate is one it must
  track by hand, which is not a contract.
- **P2.** The producer MUST accept a declaration at the admissibility stage and answer per
  item, with `goal_driveable`, `structural`, or a refusal naming the field and the
  vocabulary it fell outside.
- **P3.** The producer MUST report, at admissibility, which declared properties are
  unprovable under the declared capability ceiling. Reporting this only at adjudication
  spends a generation run to deliver an answer the declaration already determined.
- **P4.** The producer MUST bind the declaration's exact source bytes as their own
  executable-graph member, following `invariant_spec`. Binding a derived form instead
  leaves a consumer unable to compare a digest it computed itself.
- **P5.** The producer MUST report a declared invariant outside the catalog as
  `no_enforcement`, and MUST NOT let it contribute to any proven property.
- **P6.** The producer MUST keep a refusal distinct from an unproven property, per
  section 3.1.
- **P7.** Specification mode MUST reuse the existing veto loop and MUST be measured
  against a named corpus before any convergence figure derived from it is published.

---

## 10. Consumer obligations

- **C1.** A consumer MUST pin every alphabet it reads by equality, and MUST refuse to
  start when the envelope names a member it does not know. A range admits a member whose
  meaning the consumer has not been taught.
- **C2.** A consumer MUST treat an absent capability category as a refusal, never as
  permitting nothing and never as permitting anything.
- **C3.** A consumer MUST obtain language verdicts by calling the producer's checker. It
  MUST NOT maintain its own copy of the producer's refusal rules.
- **C4.** A consumer MUST lower its own representation into the declaration. It MUST NOT
  expect the producer to read that representation.
- **C5.** A consumer MUST declare the contract version it implements, and a producer
  matches it by equality.
- **C6.** A consumer MUST demonstrate C1 to C5 in its own test suite, and MUST name which
  case demonstrates which obligation. This document states both sides' obligations; it
  carries neither side's evidence.

---

## 11. Versioning and growth

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

## 12. Not in version 1

Named so an omission is not read as permission.

| Excluded | Waits on |
|---|---|
| The full application surface: persistence, governed transitions, durable orchestration, service bindings | A version-1 declaration that is proven end to end first |
| An effect kernel inside the artifact, and the single-process topology | Section 8.1, plus an answer to where Metadoor's decisions D-020 and D-021 place authority once the ledger is inside the artifact |
| The artifact stage as a consumer-facing contract, and Mighty's admission obligations | Mighty returning to scope, and its own unresolved release-unit question |
| Hosted deploy | An accepted hosted scope, lifecycle policy, and control-plane CI |
| Promotion of any disclosed property to consumer-checked | One property or opcode family selected, per [Roadmap](roadmap.md#runtime-and-product-work) |
| Computed SQL resources in a declared ceiling | A policy that distinguishes read from write authority |

---

## 13. Future consideration

**The full application surface.** A later declaration could name persistence, governed
transitions, durable orchestration, and service bindings. This is more tractable than it
sounds, because the producer already owns those as virtual modules: `zttp:sql`,
`zttp:durable`, `zttp:workflow`, and `zttp:service`. Such a declaration would name module
operations rather than introduce semantics, and the vocabulary would grow by the same
rule as section 11. The open question is not expressibility. It is that naming the
application structure makes the producer the owner of that structure, which is a product
decision rather than a compiler one.

**The single-process topology.** The consumer's effect kernel could be lowered into the
proven subset. The pieces exist in `zttp:durable`, `zttp:sql`, and `zttp:crypto`. The
obstacle is authority rather than mechanism: Metadoor's D-020 places the claim guard
inside the claim transaction and its D-021 derives rollbackability from the descriptor
kind the permit bound, and both belong wherever the ledger is. A proposal must pass section 8.1 rather than argue
around it.

---

## 14. Sources

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

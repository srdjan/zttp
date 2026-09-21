# zigts: agent tool extension

Status: parked proposal. [Roadmap](../roadmap.md#proposal-decisions) owns the
release decision. This draft does not authorize implementation. Its title's
use of "complete" describes the draft's coverage, not shipped behavior.

## Draft v0.7 — complete specification

**Supersedes v0.1 to v0.6**, all included in full.

New in v0.7. Part D makes the agent code: a harness is a zigts module that turns an authenticated request into an observation, obtains plans from a planning model, submits them, turns what comes back into typed facts through a quarantined extractor, and answers over the channel. Models are capabilities imported by role, with a label on everything they say. To carry that, a label gains two components (9.1): taints, joined by union, of which the old `input` is one; and marks, joined by intersection, which record a principal's word and a principal's approval. The planner is a sink that accepts no taint, so injected content reaches it only through a listed brand. Consequential routes (36.2) require an approval mark on their arguments, which no model or upstream can produce. Harness loops are bounded folds, so a harness terminates. `tokens` is a sixth cost quantity. Models run in a separate attested VM (38). Sections 5.2, 6, 8, 9, 10, 11, 12, 13, 18, 19, 20, 21, 22, 24, 28, 29 and 32 carry the amendments.

New in v0.6. Part C is rewritten. The primary target is no longer a purpose-built unikernel but the zigts image as the only process in a KVM microVM, launched by libkrun-sev on AMD SEV-SNP and attested to a key broker before it holds any secret; the same image runs under smolvm for development and CI. Sections 21 and 24 follow: the certificate carries a launch measurement and a root filesystem digest and is signed with a key that exists only inside an attested guest, and the trusted computing base names the guest kernel, the hypervisor, the firmware and the broker. Credential attachment moves inside the guest, which is where the documented libkrun-sev flow puts secrets and what makes the host irrelevant to confidentiality. The unikernel is deferred to a measurement in section 31. Parts A and B are unchanged from v0.5.

New in v0.5, from the 2026-09-15 review. Finding numbers refer to that review.

- **Control label** (9.2, 19). A `match` or `filter` joins the label of what it branches on into every binding, capability call and `Failure` inside its arms. This is the implicit-flow rule the earlier drafts lacked; without it a plan could signal one bit per arm to any host it was allowed to call. F1.
- **Routes as origins** (5.2, 9.1). `fetch` takes a structured request against a literal path template, and the template becomes part of the origin, so a relay from one resource to another on the same host is visible to policy. F2.
- **Labelled storage** (7, 9.4). KV namespaces carry a class and writes obey it, so a sensitive value cannot be laundered through a scratch namespace and read back by a later plan. Effects run in order and KV writes are buffered until the invocation succeeds. F4.
- **Cost holes closed** (4, 8, 18). Strings are bounded at the boundary, `fold` allocation is multiplied by the iteration count, byte-work is a costed quantity, and the wall-clock bound is stated as what it is: call count times timeout. F5.
- **Journal** (22). Every capability result is recorded per invocation and replay reads the journal. The earlier claim that inputs determine the result was false for any tool that calls a host. F6.
- **Endorsement and declassification tightened** (9.5, 9.6). Brands are sink-specific and allowlisted; declassification refuses arguments the model influenced and accepts only releasable brands. F8.
- **Bounds stated correctly** (18, 19, 20). `P_max` counts nested nodes, the product of enclosing iteration bounds is capped, and the verifier's cost is quadratic in record width. F9.
- **Budgets charged at the declared maximum** (8, 22). Actual step and call counts are telemetry the model cannot read. F11.
- **Purpose** (9.8). The one addition beyond the review fixes: an observation carries a purpose, origins declare the purposes they may serve, and aggregation rules are predicates over a value's origin set. Cut it if it does not earn its place.

Deferred to research before design in v0.5, and resolved or narrowed in v0.6 (section 32): rooting the attestation chain is resolved by libkrun-sev and a key broker; intra-image isolation becomes a user-space protection-key question; credential scope per observation and a reference model for the verifier remain open.

New in v0.4:

- **Secrets are operations, not values** (sections 5 and 9). The host attaches bound credentials to outbound calls, so secret material normally never enters a tool at all. This removes a whole class of flow violation by construction rather than denying it by policy.
- **Part C, execution targets.** The primary target is a native Zig binary on a unikernel library purpose-built for zigts. WebAssembly is a candidate secondary target after the first release, and section 31 states what must stay true now to keep that option open.

---

# Part A. Tools

## 1. Scope and method

Let zigts express agent tools without weakening any contract the compiler derives.

Add no runtime concept. A tool is a typed pure function; the compiler generates the `handle` wrapper, so zigttp still runs one thing, a zttp handler. Everything else here is an artifact the compiler derives from types, imports and dataflow, never a manifest the author maintains by hand.

Two design rules run through the whole document:

- **A property belongs in the static contract only if it composes mechanically across a call graph.** Section 10 makes that test explicit and says what it excludes.
- **A capability grants an operation, not a value.** Handing a tool the ability to sign is strictly safer than handing it a key, because the key then has no path anywhere. Section 5 applies this to secrets; it is worth applying to anything else that would otherwise be a bearer token.

## 2. Invariants preserved

Tool bodies are const-only and have no ambient effects: every effect is a capability call, and section 7 orders effectful calls. No throw, no async, one unit per file. Every contract is a compiler output, so code and description cannot drift apart. The tool call graph is acyclic.

## 3. Tool shape

```ts
// tools/customer-risk.ts
import { type Result, ok, fail } from "zigttp:core";

export type Input = {
  readonly customerId: CustomerId;
  readonly jurisdictions: Bounded<Jurisdiction, 4>;
};

export type Output = {
  readonly score: RiskScore;
  readonly reasons: Bounded<Reason, 8>;
};

export type Failure =
  | { readonly tag: "not-found" }
  | { readonly tag: "upstream-unavailable" };

/** Score a customer's screening risk across the given jurisdictions. */
export const tool = (input: Input): Result<Output, Failure> => ...
```

Rules:

- exactly one exported `tool` per file, pure, total, returning `Result`;
- `Input`, `Output` and `Failure` are exported and closed (section 4);
- the doc comment on `tool` and on each field is the model-facing description, so prose lives next to the code it describes;
- `Failure` is a closed union, which lets the dispatcher decide retryability without parsing strings.

The compiler emits the `export const handle = (req: Request): Response` wrapper: decode, validate against `Input`, call `tool`, encode. The author writes no transport code, and the validator comes from the type that generated the descriptor, so a tool cannot accept an input its descriptor did not advertise.

## 4. Boundary type grammar

Descriptors must be finite, costs computable and labels attachable per field, so boundary types are a strict subset of what zigts allows internally:

```
Bnd  ::= boolean | number
       | Text<N> | Text<dim>              string with a maximum byte length, absolute or named
       | Literal<primitive>
       | Brand<Bnd, name>                  branded primitive, e.g. CustomerId
       | { readonly k: Bnd, ... }          closed record, no index signatures
       | Bounded<Bnd, N>                   array with a compile-time max length
       | Sized<Bnd, dim>                   array whose length is a named dimension
       | Bnd | Bnd                         literals, or discriminated records
```

Not permitted at the boundary: bare `string`, generics, unconstrained arrays, recursive types, function types, `any`, `unknown`, index signatures, optional fields (write `| null`).

`Text<N>` is a string of at most `N` bytes. It exists for the same reason `Bounded` does: a string of unstated length makes every byte-proportional operation on it, and every allocation of it, uncosted. Kubernetes met this with CEL and now rejects a rule over a string that has no `maxLength`.

`Bounded<T, N>` and `Text<N>` give absolute cost bounds. `Sized<T, d>` and `Text<d>` name a dimension so cost can be a polynomial in `d`, checked at dispatch against the actual input. Internal code keeps the full zigts type system; only the boundary is restricted.

Three consequences carry the rest of this document:

- **Bounded outputs.** Every tool output has a statically known maximum size, strings included, so the cost of anything applied to a tool's result is computable without running it.
- **Closed records.** The field set is finite and known, so a flow summary can be per-field rather than per-value.
- **Values only.** Nothing at a boundary is a handle, pointer or callback, which is what makes the target swap in Part C a change of enforcement rather than a redesign.

## 5. Capability imports

The scope lives in the specifier:

```ts
import { fetch }     from "zigttp:http/api.screening.example.com";
import { get, put }  from "zigttp:kv/customer-risk";
import { sign }      from "zigttp:sign/partner-hmac";
import { now }       from "zigttp:clock";
import { call }      from "zigttp:tool/identity-verify";
```

Three rules make the authority set exactly the import list:

1. **Import-only.** A capability may be called. It may not be assigned, returned, stored in a record, passed as an argument, or closed over.
2. **Static specifiers.** No computed or dynamic import paths.
3. **No re-export.** A module cannot widen a caller's authority.

Authority is therefore a set of strings known at compile time, so the dispatcher's observation-scoped check is a subset test rather than a policy evaluation. Reviewing a tool's power means reading its first ten lines and the route list the compiler derived from them (5.2). And `zigttp:tool/<name>` makes tool-to-tool calls a capability like any other, so a tool that can call other tools says so where it says everything else.

### 5.1 Secrets are operations

There is no `read()` on an API key. Deployment binds a credential to a host, and the runtime attaches it to outbound calls on that host. A tool that calls `fetch` on a bound host is authenticated without ever holding the credential:

```ts
const report = fetch({ get: "/reports/{id}", params: { id } });   // credential attached by the host
```

Where a tool genuinely needs cryptographic material in the payload, it gets the operation instead of the key:

```ts
import { sign } from "zigttp:sign/partner-hmac";
const mac = sign(canonicalBody);          // key never enters the tool
```

The residual case, a tool that needs the raw bytes, uses a separately named and flagged capability:

```ts
import { read } from "zigttp:secret-value/legacy-token";
```

`zigttp:secret-value/*` is reviewed like `zigttp:declassify/*` in section 9.6. It should be rare, and its rarity is visible in the authority set rather than buried in a body.

What this buys: in the common case the `secret/*` origin never appears in a flow summary, because the secret never enters the analyzed program. The policy rules about secrets in section 9.4 become vacuous for most tools rather than load-bearing. A rule you do not need to enforce cannot be enforced incorrectly.

Two host-layer rules make "bound to a host" mean what it says. A credential is attached only over TLS validated for the bound hostname, so a name that resolves somewhere else gets no credential. And `fetch` never follows a redirect with a credential attached: a redirect to another host is a `Failure`, and a redirect within the host is a `Failure` unless the target is in the tool's route list. HTTP clients have leaked credentials on both paths before, and both are cheaper to forbid than to get right.

### 5.2 Routes

`fetch` takes a request, not a string:

```ts
const report = fetch({
  get:    "/reports/{id}",    // literal template
  params: { id },             // branded values fill the template
  query:  { j },              // keys are literals, values are payload
});
```

The template is a literal, so the compiler reads it. The set of (method, template) pairs a tool uses is its route list, derived like the authority set and recorded in the manifest next to it. The host layer encodes parameters and query values itself; a tool never assembles a URL, so whether a byte is structural or payload is decided by the request shape rather than by escaping. Header names are structural; header values are payload and are rejected if they contain control characters.

Routes matter beyond injection. Section 9.1 makes the route part of the origin, so policy can tell `GET /reports/{id}` from `POST /notes/{id}` on the same host. And a credential bound to a host covers every route on it; the route list is the only static statement of which part of that authority a tool exercises, which is what a reviewer needs and what a narrower credential would be scoped to where the upstream supports one (section 32).

The method decides the first split: `get` is a read; anything else is an effect and is scheduled as one (section 7). Effects carry a class, derived by the compiler from method and template and confirmed by review, never declared by the author: reversible, irreversible or consequential (36.2). A reversible route names its compensating route.

A route parameter may be marked `subject`. A `subject` parameter accepts only values that carry the observation's `by/<principal>` mark and no taint (9.4), so the model cannot name a subject and an upstream cannot supply one; subjects come from the request that opened the observation (35.1).

## 6. Derived artifacts

| artifact | derived from | section |
|---|---|---|
| HAL-FORMS template | boundary types and doc comments | 6 |
| JSON Schema | same | 6 |
| input validator | same | 6 |
| authority set | the `zigttp:*` import list | 5 |
| route list | literal request templates | 5.2 |
| effect classes | method and template, confirmed by review | 36.2 |
| cost polynomial | body structure over named dimensions | 8 |
| flow summary | dataflow from sources to sinks | 9 |

The HAL-FORMS template is the primary descriptor. The governance design routes the model through a single generic http tool against resource handlers, so a tool surfaces as a form on a resource rather than as a bespoke function schema. Each `Input` field becomes a form property with its type, constraints and description. JSON Schema is secondary, for hosts that call functions directly.

One source of truth, eight artifacts. The manifest also binds model roles to weights hashes and decoding parameters (section 34); that entry is deployment data rather than a derived artifact, and the certificate records it. The form the model reads and the validator the runtime enforces are provably the same object, which removes a class of attack where a model is told about a narrower interface than the runtime accepts.

## 7. Composition and parallelism

No syntax. Purity plus const-only means the dependency graph is readable off the bindings:

```ts
export const tool = (input: Input): Result<Output, Failure> => {
  const identity = verifyIdentity({ id: input.customerId });   // independent
  const history  = fetchHistory({ id: input.customerId });     // independent
  return combine(identity, history);                           // joins both
};
```

`identity` and `history` share no data, so the compiler schedules them concurrently and the runtime joins at `combine`. The same thing written as a nested `pipe` would serialize, so the style rule is: `const` bindings for independent calls, pipelines for genuine sequences.

Reads schedule freely. Effects do not. A capability call with an effect (`put`, any non-`get` route, anything the capability layer marks as one) runs in binding order after every read it depends on, and two effects never run concurrently. KV writes are buffered and committed at the end of the invocation in binding order, and discarded if the invocation fails, so a failed branch leaves the store untouched. External effects cannot be un-sent; they are journaled (section 22) and the spec claims nothing stronger about them.

Bounded combinators (`map`, `filter`, `reduce`) over `Bounded` or `Sized` inputs are the only iteration at tool level, and a `map` with a pure body parallelizes element-wise.

This is where parallel execution pays in this stack: across a composed tool graph, not inside one handler. It needs a work-stealing DAG scheduler in the runtime and nothing more exotic.

## 8. Cost contract

The compiler emits a polynomial in the input's named dimensions:

```
customer-risk:
  steps = 310 + 74·|jurisdictions|
  work  = 12·|customerId| + 40·|jurisdictions|         bytes moved
  alloc = 8192 + 2048·|jurisdictions|                  bytes
  calls = { http/api.screening.example.com GET /reports/{id}: |jurisdictions|,
            tool/identity-verify: 1 }
  wall  ≤ |jurisdictions|·timeout(http/api.screening…) + timeout(tool/identity-verify)
  depth = 2
```

Cost composes by addition over the call DAG. Bounded inputs give absolute numbers; sized inputs give a function the dispatcher evaluates against the actual request before executing anything.

Pre-flight is arithmetic: evaluate the polynomials, compare to the observation's remaining budgets, refuse before running. The budget is charged the declared maximum, never the observed count. Charging the observed count would hand the model a readout of which arms ran, and the earlier drafts left open which count the observation's remaining budget reflected.

A sixth quantity, `tokens`, exists wherever a model is called; tools never call one, so section 37 defines it with the harness. Four of the five tool quantities hold by construction. `steps` counts basic blocks. `work` counts bytes moved by copies, concatenation, encoding, decoding and comparison, because a basic block that copies a megabyte is not one unit of anything; the EVM's gas schedule mispriced its IO-heavy instructions for years and was repriced after each attack. `alloc` counts arena bytes. `calls` counts capability calls per route. `wall` does not hold by construction: it is `calls` times the per-capability timeout, and the timeout is a deployment number. The earlier "by construction rather than by timeout" was wrong; what holds is a bound on how many times the timeout can be hit.

`steps` and `work` are not wall-clock estimates. They are counts the generated code maintains, identical across execution targets. Section 29 covers how each target enforces them.

### 8.1 Cost table

The compiler derives polynomials from a cost table the platform ships with the compiler version, and the manifest records the table's hash. One row per primitive on `Text` and arrays (a `work` cost per byte or element), one row per capability call (a `steps` constant and a `wall` timeout), one row per basic block. A brand constructor is an ordinary zigts function, so its cost is a polynomial in its argument's `Text` dimension and is charged where the constructor is called. Floating-point operations are charged a constant; the table does not model subnormal slowdowns, and a tool that does heavy float arithmetic on model-supplied numbers should be reviewed for that.

Bounding `steps` and `work` requires no unbounded recursion, no unbounded loops and no unbounded strings. That is a real expressiveness cost and the right trade: a tool that legitimately needs unbounded iteration should be a capability behind `zigttp:http/...`, not a tool body.

## 9. Flow contract

Authority answers what a tool can reach. It does not answer what may travel where. A tool may hold `kv/customer-pii` and `http/telemetry.example.com`, and nothing so far prevents the first reaching the second. For tools driven by model output, where data goes matters more than what is reachable.

Flow analysis is usually hard because of aliasing, mutation and exceptions. zigts removed all three, so propagation is a join over the binding graph, the same structure already producing the parallel schedule in section 7, plus one rule for the single branching form. The analysis is linear in bindings and needs no annotation in the common case.

### 9.1 Labels

```
Origin ::= const                          literals in source
         | input.<field>                  a field of the tool's own Input
         | kv/<namespace>                 namespaces carry a class, see 9.4
         | http/<host> <METHOD> <template>   a route, see 5.2
         | tool/<name>
         | clock
         | secret-value/<name>         rare, see 5.1
         | checked/<Brand>                endorsed, see 9.5
```

An origin is a route rather than a host because the incidents behind the relay rule in 9.4 were mostly same-host: read a private resource, write a public one, one credential. A host-level origin cannot see that flow. A route-level one can.

```
Label  ::= { origins: set of Origin,       joins by union
             taints:  set of Taint,        joins by union
             marks:   set of Mark }        joins by intersection

Taint  ::= taint/input                     plan input, model-controlled
         | taint/upstream/<route>          a response body
         | taint/upstream/kv/<ns>          a read from a namespace not declared trusted
         | taint/model/<role>              a model's output, see 34

Mark   ::= by/<principal>                  came over the authenticated channel from this principal
         | approved/<principal>            this principal approved it through the approval affordance

bottom  = { origins: { }, taints: { }, marks: all }     constants
```

One lattice serves three questions. Confidentiality asks whether the origins may reach a given sink. Integrity asks whether the taints are empty, which says nothing the model or an upstream controls is in the value. Authority asks whether the marks include a principal, which says a human said it or approved it. A value is clean when its taint set is empty. A constant has every mark, so joining with a constant erases nothing. A model's output has no marks, because a model's word carries no principal. Brands clear the taints their policy entry names (9.5); nothing else clears a taint, and nothing adds a mark except the channel and the approval capability (35.4).

Through v0.6 the only taint was `input`, written as an origin. It is now `taint/input`, and every rule that mentioned it applies to every taint.

A signature from `zigttp:sign/*` carries the label of its argument and nothing more. It is derived from a key but is not the key, and releasing it is the purpose of computing it.

### 9.2 Propagation

A binding's label is the union of the labels of everything it reads. A capability call's result carries that capability's origin joined with its arguments' labels. Field-level precision comes from closed records: projecting a field yields that field's label, not the whole record's.

**Control label.** `match` is the only branching form and `filter` the only conditional selection, so the implicit-flow rule has two sites. A `match` establishes a control label equal to the label of its scrutinee; a `filter`, the label of everything its predicate reads. Every binding made inside an arm or body, every capability call issued there, and every `Failure` produced there carries the control label joined in. The result of the `match` or `filter` carries it too. The control label has all three components: a `match` on a tainted discriminant taints every binding, call and `Failure` inside its arms, and a `match` on a marked value keeps the mark only on bindings that already had it. This is Denning's rule from 1977 and the rule CaMeL applies to values assigned under a condition. Without it a tool could call `http/telemetry` in one arm and not the other with constant arguments, and the summary would show `reaches http/telemetry ← { const }` while the host learned the scrutinee.

A `Failure` is a value and carries a label like any other: the control label of the site that produced it, joined with the labels of what that site read. A `not-found` from a sensitive namespace is an existence oracle, and its label says so.

Per tool the compiler records a summary rather than fixed labels, since callers supply different inputs:

```
propagates : Output field  →  set of (Input field | Origin)
reaches    : sink          →  set of (Input field | Origin)
fails      : Failure tag   →  set of (Input field | Origin)
```

That is a dependency matrix over a finite field set, which makes composition in section 19 a transitive closure rather than a re-analysis.

### 9.3 Sinks

Every capability is a source and a sink. Its results carry its origin; its arguments get checked. Sinks divide by position, and the distinction is the whole injection defence:

- **Payload positions** (request bodies, KV values, log fields) are checked for confidentiality: may this label leave to this destination.
- **Structural positions** (route parameters and query keys, KV keys, header names) are checked for integrity: they reject any taint.

The tool's own `Output` and `Failure` are sinks too, since both return to the model.

### 9.4 Default policy

The compiler derives the flow graph. The platform supplies the policy. Certification checks one against the other.

That split matters because the facts live in different places. Which credential belongs to which host, and which KV namespace holds sensitive data, are deployment facts that change without the code changing. The compiler knows neither and needs to know neither.

Defaults, with no annotation anywhere:

| flow | default |
|---|---|
| any taint into a structural position | denied |
| any taint into a `model/planner` context (34) | denied |
| any taint into a `subject` route parameter (5.2) | denied |
| a `subject` parameter without `by/<principal of the observation>` | denied |
| a consequential route (36.2) without `approved/<p>` on its arguments and control label | denied |
| a dual-control route without `approved/<p>` and `approved/<q>`, p ≠ q | denied |
| sensitive `kv/ns` to any `http/*`, to `Output` or to `Failure` | denied |
| `kv/ns` to `kv/ns'` | denied unless class(ns') ⊒ class(ns) |
| `secret-value/*` anywhere | denied without declassification |
| route `r` response body to route `r'`, same host or not | denied unless r' is declared downstream of r |
| anything else | allowed |

Namespaces carry a class from the policy, and the third row is what makes the second one hold. Without it a tool could write a sensitive value to a scratch namespace, allowed under "anything else", and a later plan could read it back with a clean label. Storage is where laundering hides across invocations; Flume and HiStar both label it for that reason.

The route row replaces the host row. Relaying one upstream's data to another is the shape of most exfiltration through a legitimate tool, and the recent cases were same-host: a private repository read and a public one written through one API and one token. The deployment usually knows which relays are intended.

**Public discriminants.** The control label from 9.2 will sometimes deny a tool that branches on a harmless tag; `ok` against `fail` from a sensitive namespace is the usual case. The policy may declare a discriminant public, in which case matching on it raises no control label. The declaration is per component: a tag declared public for taints still carries its origins. The reasoning is FIDES's: a low-capacity type, a boolean or a small enum, leaks at most a few bits per match, and the policy author decides which few bits are acceptable. Declaring one is a policy change and invalidates certificates like any other.

### 9.5 Endorsement through brands

A structural position needs a branded value, and constructing a brand from a raw primitive is the only way to clear a taint:

```ts
const id = CustomerId.from(input.rawId);   // Result<CustomerId, Failure>
// origins { checked/CustomerId }, taints ∅, rather than taints { taint/input }
```

Brands already exist in the boundary grammar, so this adds no syntax. It adds three rules, because a brand constructor is an endorsement point and "total and pure" alone does not make one trustworthy: `(s) => ok(s as CustomerId)` is total and pure and launders everything.

1. A brand constructor reads only its argument. The compiler checks that its body has no capability imports and closes over nothing, so the endorsement decision is a function of the raw value and of nothing else the model controls.
2. A brand names the sinks it endorses for and the taints it clears. `CustomerId` clears `taint/input` at the route parameter `{id}` on `api.screening.example.com` and nowhere else; a brand admitted to a planner context (35.3) clears `taint/upstream/*` and `taint/model/extractor` for that sink and no other. A brand valid for one upstream's path segment is not thereby valid for another's.
3. The policy lists the brands whose constructors have been reviewed. A structural position accepts `checked/<Brand>` only for listed brands, and an unlisted brand's constructor clears nothing. This is the Trusted Types arrangement: the mechanism cannot tell a sanitising policy from a pass-through one, so the browser accepts only policy names the deployment allowlisted after review.

A route parameter built from listed brands cannot carry model-controlled structure, which is path injection closed by typing. It says nothing about whether the model may name that record at all; that is a scope question (section 32), and typing does not answer it.

### 9.6 Declassification

The escape hatch has to exist and has to be visible where everything else is visible:

```ts
import { declassify } from "zigttp:declassify/kv/customer-pii";
```

It removes one named origin from a label, and it appears in the authority set, so a deliberate flow violation shows up in the same list a reviewer and the dispatcher already read. With secrets handled as operations, declassification should now be rare enough that its presence is itself a review trigger.

Two constraints make it robust in the Zdancewic and Myers sense, which is that the attacker decides neither what gets released nor when:

- `declassify` rejects an argument whose label carries any taint, or whose control label does. The model may not choose which record is released by choosing an id, and may not choose whether release happens by steering a `match`. A value reached through a listed brand is fine, since that brand's constructor was reviewed for exactly this.
- `declassify` accepts only values of a brand the policy lists as releasable for that origin: `zigttp:declassify/kv/customer-pii` might accept `RedactedSummary` and nothing else. The brand's constructor is the reviewed statement of what leaves; the origin is the statement of where from. Removing an origin from an arbitrary value released everything derived from it, which is too coarse a "what" to review.

`declassify` still has no plan node (section 24), and a `map` over a declassifying tool is bounded by `N`, so the model bounds how many releases it triggers and never which.

### 9.7 Artifact

```
flow:
  propagates:
    score    ← { input.customerId, tool/identity-verify, http/api.screening… GET /reports/{id} }
    reasons  ← { tool/identity-verify, http/api.screening… GET /reports/{id} }
  reaches:
    http/api.screening… GET /reports/{id}  ← { checked/CustomerId, checked/Jurisdiction }
    Output                                 ← { input.customerId, tool/identity-verify,
                                               http/api.screening… GET /reports/{id} }
  fails:
    not-found            ← { tool/identity-verify }
    upstream-unavailable ← { http/api.screening… GET /reports/{id} }
  taints:
    Output                { taint/input, taint/upstream/GET /reports/{id} }
    GET /reports/{id}     ∅
  marks: none
  endorsements: CustomerId → {id}, Jurisdiction → query j
  declassifications: none
```

No credential appears anywhere in this summary, because none entered the tool. `reasons` carries `tool/identity-verify` although no field of it reads the identity: it is computed inside the `ok` arm, and the control label says so. That is the rule working. A public discriminant on that tool's `Result` tag would remove it, if the deployment decides the tag is harmless.

### 9.8 Purpose

An origin says where data came from. It does not say what it may be used for, and in a screening product that second question is the regulated one: a consumer report may be furnished only for a permissible purpose, and the purpose is a property of the request, not of the data. The generic form is purpose limitation, the rule GDPR states in Article 5(1)(b) and Hippocratic databases implemented as a purpose column in 2002.

The mechanism fits the lattice without changing it:

- The observation carries a `purpose` alongside its authority scope. Purposes form a small deployment-defined lattice.
- The policy maps each origin to the purposes it may serve. A sink is permitted under an observation only if every origin in the value's label permits the observation's purpose.
- An aggregation rule is a predicate over the label as a set, evaluated at the sink: "two or more `identity` origins and any `financial` origin require purpose ≥ `credit-decision`". Individually permissible facts compose into something that needs a higher purpose, and no per-origin rule can say so; the label is exactly the set the predicate needs, because union is the join.
- Verification records `required_purpose(plan)`, the join over sinks of what the rules demand, so the per-invocation check stays a lattice comparison against the live observation and section 20's split survives.

What this cannot see is aggregation across invocations: the model reads one subject per plan and aggregates in its own context. Section 22 adds a disclosure ledger per observation, the set of (route, parameters) pairs already released to `Output`, and evaluates the aggregation predicate over ledger ∪ label rather than label alone. The ledger needs subjects, which is why route parameters are journaled and not just routes.

The statutory duties stay outside the engine. What the engine contributes is the journal: per invocation, which origins served which purpose under which certificate, which is the record those duties ask for.

## 10. What is not in the contract

The filter for anything proposed as a static invariant: **it belongs only if it composes over a call graph by a join or a sum.**

| property | composes | in the contract |
|---|---|---|
| authority | union | yes |
| cost | sum | yes |
| flow labels: origins, taints | union | yes |
| flow labels: marks | intersection | yes |
| purpose requirement | join over sinks | yes |
| tokens | sum | yes |
| determinism | conjunction | yes, implied by purity |
| idempotence | no, depends on callee ordering | no |
| value refinements | no, needs callee preconditions from caller postconditions | no, see below |

Value refinements (`score` is between 0 and 100, `jurisdictions` is non-empty) are worth having, but proving them across composition means deriving verification conditions and discharging them with a solver, which puts a solver in the trusted computing base and ends the ambition of a verifier one person can audit in a sitting.

So refinements are runtime-checked predicates on boundary types. One step of cost, failure is a typed `Failure`, no solver. They also tighten the HAL-FORMS constraints the model reads, which cuts malformed calls before they arrive. Checked, not proven, and the spec says so rather than leaving a stronger reading available to a future reader.

## 11. Restrictions added

| # | restriction | buys |
|---|---|---|
| 54 | Capabilities are import-only, never values | authority set = import list |
| 55 | Static import specifiers only | same |
| 56 | No capability re-export | authority cannot widen via a dependency |
| 57 | Boundary types closed and monomorphic | finite descriptors, computable cost, per-field labels |
| 58 | No unbounded recursion; tool call graph acyclic | terminating cost sum and schedule |
| 59 | Iteration only via bounded combinators over sized inputs | the `steps` polynomial exists |
| 60 | Exactly one exported `tool` per file | one descriptor per unit |
| 61 | Structural sink positions accept no taint | injection closed by typing |
| 62 | Declassification only via `zigttp:declassify/*` | every violation is in the authority set |
| 63 | Brand constructors total and pure | endorsement points are trustworthy |
| 64 | Raw secret material only via `zigttp:secret-value/*` | credentials normally never enter a tool |
| 65 | Only boundary-type values cross a tool boundary; no handles, pointers or callbacks | the target swap in Part C stays a swap |
| 66 | `Text` at the boundary has a maximum length, absolute or named | the `work` and `alloc` polynomials exist |
| 67 | `fetch` takes a structured request against a literal template | route list derivable; encoding is the host's job |
| 68 | Brand constructors read only their argument; brands are sink-specific and allowlisted | endorsement points are trustworthy |
| 69 | `declassify` rejects `input`-influenced arguments and accepts only releasable brands | robust declassification |
| 70 | Effects run in binding order; KV writes are buffered and committed on success | deterministic replay, no partial writes |

Seventeen restrictions for eight derived artifacts, and eight more for harnesses in 36.1. Each one removes a way for the model-facing description and the runtime behaviour to disagree.

## 12. Compiler pipeline

```
tool source
   │
   ├── parse and check restrictions 1..78
   ├── boundary type extraction ──► HAL-FORMS template
   │                              ► JSON Schema
   │                              ► validator
   ├── import analysis ──────────► authority set
   ├── route extraction ─────────► route list, effect classes
   ├── dependency analysis ──────► parallel schedule
   ├── cost analysis ────────────► cost polynomial + fuel instrumentation
   ├── flow analysis ────────────► flow summary
   └── codegen ──────────────────► target artifact + manifest entry
```

Policy checking happens after this, against deployment configuration. A policy change re-checks without recompiling, which matters for certificate invalidation in section 21. Codegen is the only stage that differs by target; everything above it is target-independent, which is the whole content of section 31.

The manifest is a compiler artifact, not a source file. Nothing in it can be edited without editing the code it came from, which is the property that makes it worth signing.

## 13. Worked example

```ts
// tools/customer-risk.ts
import { type Result, ok, fail, match } from "zigttp:core";
import { fetch } from "zigttp:http/api.screening.example.com";
import { call as verifyIdentity } from "zigttp:tool/identity-verify";

export type Input = {
  readonly customerId: Text<64>;
  readonly jurisdictions: Bounded<Text<8>, 4>;
};

export type Output = {
  readonly score: RiskScore;
  readonly reasons: Bounded<Reason, 8>;
};

export type Failure =
  | { readonly tag: "not-found" }
  | { readonly tag: "bad-input" }
  | { readonly tag: "upstream-unavailable" };

/** Score a customer's screening risk across the given jurisdictions. */
export const tool = (input: Input): Result<Output, Failure> => {
  const id = CustomerId.from(input.customerId);
  const js = input.jurisdictions.map(Jurisdiction.from);
  const identity = verifyIdentity({ id });
  const reports  = js.map((j) => fetch({ get: "/reports/{id}", params: { id }, query: { j } }));
  return match(identity, {
    fail: () => fail({ tag: "not-found" } as const),
    ok:   (who) => score(who, reports),
  });
};
```

Two things are absent on purpose. There is no key, because the host attaches it. And `CustomerId.from` is not decoration: without it the route parameter carries `taint/input` into a structural position and restriction 61 rejects the tool at compile time.

Derived with no further input from the author:

```
authority:
  http/api.screening.example.com
  tool/identity-verify
routes:
  http/api.screening.example.com GET /reports/{id}
cost:
  steps = 310 + 74·|jurisdictions|               max 606
  work  = 12·|customerId| + 40·|jurisdictions|   max 928 bytes
  alloc = 8192 + 2048·|jurisdictions|            max 16384 bytes
  calls = { GET /reports/{id}: max 4, tool/identity-verify: 1 }
  wall  ≤ 4·timeout(http/api.screening…) + timeout(tool/identity-verify)
  depth = 2
flow:
  reaches GET /reports/{id}  ← { checked/CustomerId, checked/Jurisdiction }
  reaches Output             ← { input.customerId, tool/identity-verify,
                                 http/api.screening… GET /reports/{id} }
  fails   not-found          ← { tool/identity-verify }
  taints  Output             { taint/input, taint/upstream/GET /reports/{id} }
schedule:
  identity ∥ reports[0..n]  →  score
form:
  HAL-FORMS template on /tools/customer-risk, two properties
```

The dispatcher can refuse this call before execution if the observation's remaining budget is under 606 steps or 928 bytes of work, if its wall budget is under four upstream timeouts, if its granted scope lacks either authority entry, or if its purpose is one `GET /reports/{id}` does not serve. The authority set is two entries, and the missing one is the credential.

---

# Part B. Runtime-constructed tools

## 14. The problem

An agent in session needs something no existing tool provides. Two obvious responses both fail.

**Compile at runtime.** The agent emits zigts source, the runtime compiles it. This puts a compiler in the trusted computing base and lets model output decide what code exists. Every contract survives on paper and none survives in practice, because the thing generating the code is the thing being contained.

**Refuse.** Safe, and reduces the agent to whatever was anticipated at build time.

## 15. The move

Let the agent **compose certified tools**, not write code. It emits a plan, which is data: a typed DAG whose nodes are existing tools plus a small set of total pure combinators.

This works because all four derived properties are closed under composition.

```
authority(plan) =  ⋃ authority(node)            union
cost(plan)      =  Σ cost(node)                 over an acyclic graph
flow(plan)      =  transitive closure of summaries
type(plan)      =  composed boundary types      same grammar as section 4
```

A composed plan cannot reach a capability that was not already reachable, cannot cost more than the sum of things already costed, and cannot create a flow path the closure does not show, explicit or implicit, because the control label composes like any other label. Verifying a plan is a linear pass over a data structure, not a compilation, so the verifier is a few hundred lines rather than a compiler.

The set of certifiable tools is closed under plan composition. That sentence is the security argument; the rest of Part B is the mechanics of making it true.

## 16. Plan grammar

```
Plan   ::= { inputs: [Dim], nodes: [Node], result: NodeRef }

Node   ::= { id, kind, type }

kind   ::= input      i                         plan input by index
         | const      v                         literal of boundary type
         | project    src, key                  field of a record
         | record     { k: NodeRef, ... }       build a closed record
         | brand      src, Brand                endorse through a listed brand constructor
         | call       tool, arg: NodeRef        invoke a certified tool
         | map        over: NodeRef, body: Plan
         | filter     over: NodeRef, body: Plan
         | fold       over: NodeRef, init, body: Plan
         | match      on: NodeRef, arms: { tag: Plan }   arms carry the control label of `on`
         | unwrap     src, onFail: NodeRef      Result to value with a default
```

Eleven node kinds. Every one is total, first-order and non-recursive. There is no lambda, no name binding beyond node references, no loop, no recursion, no string evaluation, and no way to name a capability that is not a tool in the manifest.

`brand` exists because section 9.5 made endorsement the only route from `input` to a structural position. Without it a plan could hand raw plan input to a tool whose own analysis assumed its caller had endorsed. With it, endorsement is a node the verifier can see. A plan may `brand` only through brands the policy lists (9.5), so the agent's endorsement power is exactly the reviewed set.

The grammar is deliberately not Turing complete. That is the property being bought, not a limitation to fix later.

## 17. Typing

Plans use the section 4 boundary grammar unchanged. Each node carries its type; each edge is checked for exact match, with no coercion and no subtyping.

`call` nodes take their input and output types from the manifest, so a plan cannot claim a tool accepts something it does not. `match` must be exhaustive over the union's tags, which makes the cost bound in section 18 a maximum rather than a guess.

## 18. Cost over plans

| kind | steps | alloc |
|---|---|---|
| `input`, `const`, `project`, `unwrap` | 1 | 0 |
| `brand` | cost of the brand constructor | 0 |
| `record` | fields | size of record |
| `call t` | `steps(t)` from manifest | `alloc(t)` |
| `map`, `filter` over `Bounded<T,N>` | `N · steps(body)` | `N · alloc(body)` |
| `fold` over `Bounded<T,N>` | `N · steps(body)` | `N · alloc(body)` |
| `match` | `1 + max over arms` | `max over arms` |

`work` composes like `alloc`: multiplied by `N` under `map`, `filter` and `fold`, the maximum under `match`. `fold` allocates `N · alloc(body)` because the arena is released per invocation, not per iteration; the earlier table said `alloc(body)` and was wrong. `wall` sums `calls` times timeouts as in section 8.

Authority is the union of the `call` nodes' sets; every other kind contributes nothing. Call counts per route sum the same way. Depth is the longest path through `call` nodes.

`N` is always available because restriction 57 forced every tool output to be bounded. Without that restriction this table would need runtime sizes and pre-flight would collapse back into a timeout.

Nesting multiplies. A `map` over `Bounded<_, 64>` whose body is a `map` over `Bounded<_, 64>` costs `64²` times its innermost body, and three levels cost `64³`. The polynomial stays finite and stops meaning anything. So the verifier caps the product of enclosing bounds along any path at `I_max`, an iteration budget set alongside `P_max`, and rejects a plan that exceeds it before computing anything else.

## 19. Flow over plans

Each tool's summary (section 9.2) is a dependency matrix from input fields and origins to output fields and sinks. Composing a plan means taking the transitive closure of those matrices along the DAG in topological order, one pass. Combinator nodes propagate by union; `brand` clears the taints its entry names and adds `checked/<Brand>`; `call` applies the callee's matrix, including its `fails` rows. `match` and `filter` establish a control label exactly as in 9.2, joined into every node of every arm or body, into every sink those nodes reach, and into the node's result.

The policy from section 9.4 then applies to the composed summary, unchanged.

This is the part per-tool checking cannot do. Consider two individually legitimate tools:

```
A : reads kv/customer-pii, returns { profile }        permitted, its namespace is
                                                      sensitive but A sends it nowhere
B : posts its argument to http/telemetry.example.com  permitted, handles nothing sensitive
```

A plan wiring A's output into B passes every per-tool check, because neither tool did anything wrong. The composed closure shows `kv/customer-pii → http/telemetry.example.com` and the policy denies it. Laundering through composition is exactly the attack a capability-only model misses, and the closure is what catches it.

The closure is a boolean matrix product. With labels as bitsets over the origin set and `w` the field count of the widest boundary record, a `call` node costs `O(w²)`, so the analysis is bounded by `P_max · w²`, both statically known. The earlier draft said `P_max · w`, which is not what a matrix product costs.

## 20. Verification

A plan is submitted as a resource, keeping it inside the existing HAL-FORMS dispatcher rather than adding a second control path. `POST /plans` returns a certificate and a form for invoking it.

The verifier makes one pass and checks:

1. every `NodeRef` resolves, and the graph is acyclic;
2. every edge type matches exactly, and `match` arms are exhaustive;
3. every `call` names a tool present in the manifest, at the hash the certificate will record, and every `brand` names a listed brand;
4. `|nodes| ≤ P_max`, counting every node in every nested body, and `depth ≤ D_max`;
5. nested plan bodies recurse to a fixed depth limit, checked before descent, and the product of enclosing iteration bounds along any path is at most `I_max`;
6. the cost polynomials are computable and finite;
7. the composed flow summary, control labels included, satisfies the deployment policy, and the plan's required purpose (9.8) is recorded;
8. every `subject` parameter carries the observation's `by/` mark, and every consequential route carries the `approved/` marks its class requires (36.2) on its arguments and control label, or the plan is refused.

The verifier's own cost is bounded by `P_max · (w² + t)`, with `w` the widest record and `t` the largest boundary type, from the closure in section 19 and the exact type comparison in section 17. That is a polynomial the operator can evaluate, which is the point: the verifier is the one component that runs on unvalidated model output, and a verifier whose cost depends on plan shape in a way nobody stated is an availability hole in the thing meant to close availability holes.

Verification does not check authority against a scope. It records the authority set instead, and the subset test happens per invocation against the observation live at that moment, so a certificate stays valid while the scope it may run under narrows between calls. Purpose is checked the same way. The invoking validator enforces the plan's declared dimensions against the actual inputs, as generated validators do for AOT tools, so a plan that declares a small dimension and receives a large value is refused before pre-flight.

## 21. Certificate

```
plan-hash        content hash of the normalized plan
manifest-hash    tool manifest the plan was checked against
policy-hash      deployment policy the flow check ran against
launch-measure   PSP launch measurement of the guest, see 28.2
rootfs-digest    digest of the image root filesystem, checked by init, see 28.2
verifier-version
authority        { http/…, tool/… }
routes           { http/… GET /…, … }
required-purpose join over sinks, see 9.8
models           role → weights hash, decoding parameters, for every model the plan or harness used, see 34
cost             polynomials in the plan's declared input dimensions: steps, work, alloc, calls, wall
flow             composed summary, control labels included
nodes, depth, iteration product
signature        by the key the broker released for this (launch-measure, rootfs-digest) pair
```

A certificate is invalidated by a manifest or policy change, which is correct in both cases: if a tool's cost, authority or propagation changed, or a namespace became sensitive, every plan built on it must be rechecked. Caching keys on all hashes, so resubmitting a known plan under an unchanged policy and image is a lookup.

This is the artifact that puts runtime-constructed tools on the same audit footing as compiled ones. An AOT tool ships a compiler-derived manifest entry; a runtime tool ships a verifier-derived certificate. Both are signed, both name their inputs, and neither can be edited without changing what it describes. Including both measurements, and signing with a key that exists only inside a guest that presented them, chains the certificate to the attestation in 28.2. A certificate is only meaningful on the image that issued it, and a remote verifier can check that against the broker's registration and log without trusting the node.

## 22. Execution and replay

The plan interpreter evaluates nodes in dependency order and runs independent branches concurrently, exactly as the scheduler does in section 7. Capability access happens only inside `call`, which is where the monotonicity argument in section 15 is enforced rather than asserted.

`plan-hash + manifest-hash + inputs` does not determine the result, because `call` nodes reach hosts, stores and the clock. What determines it is those plus the journal: every capability result is recorded against its node id as it returns, and replay evaluates the same plan with capability calls answered from the journal instead of the world. Durable-execution engines converged on this arrangement, and there is no cheaper one. The journal is audit data with labels of its own, and lives under the same policy as any `kv` namespace. It also records each model output with its role, weights hash and decoding parameters; each entitlement answer with the store's snapshot token; and each approval with the principal and the certificate hash (35).

Effects follow section 7: KV writes are buffered and committed in node-id order when the invocation succeeds, so a failed invocation leaves the store as it found it. Concurrent branches that both fail resolve to the failure of the lowest node id, which keeps replay deterministic at the cost of discarding the other failure; with writes buffered, discarding it loses nothing in the store. External effects already sent are in the journal and are not undone.

The observation is charged the certificate's declared maxima for `steps`, `work`, `alloc`, `calls` and `wall`. The counters the runtime maintains are a backstop that traps on a wrong polynomial and a telemetry source; the model reads neither. The observation also keeps a disclosure ledger for 9.8: the (route, parameters) pairs whose results have reached `Output` so far, which the aggregation predicate is evaluated over.

Determinism depends on fuel being a counted quantity rather than a clock, which section 29 preserves across both targets.

## 23. Lifecycle

```
agent proposes plan
   │
   ├─ verify ──────► certificate      milliseconds, no human
   ├─ invoke ──────► scope check, budget check, run
   ├─ observe ─────► usage counts per plan-hash
   └─ promote ─────► emit zigts source, compile AOT, human review
```

Promotion matters more than it looks. Plan nodes map onto Part A source mechanically: `call` becomes a `zigttp:tool/*` import and a const binding, `brand` becomes a brand constructor, combinators become bounded combinator calls, `match` becomes `match`. A plan that proves itself in use lowers to a normal tool, gets compiled, reviewed and added to the manifest, and from then on costs less and reads better.

Plans are the fast path for novelty. Compilation is the fast path for repetition. The system should drift toward the second, and usage counts per plan-hash say which plans have earned it.

## 24. Trusted computing base

The TCB for runtime tools is the verifier, the plan interpreter, the journal writer, the manifest and the policy, plus whatever the execution target adds (section 29). On the primary target that is the guest kernel and libkrun's init inside the guest; KVM, libkrun-sev and the host kernel for isolation between tenants; the AMD firmware; and the key broker with its policy and its log. The host process is in the TCB for availability and for the channel, not for the confidentiality of secrets, which never reach it. With a harness (Part D) the TCB adds the harness units, the router, the entitlement and approval capabilities, and the model VM's image; the weights are a reviewed artifact with no derived contract behind them. Keeping the verifier small enough for one person to audit in a sitting is what constrains the plan grammar, and any proposal to extend section 16 should be weighed against that budget before anything else.

Still forbidden, with no runtime equivalent:

- naming a capability that is not a manifest tool;
- endorsing through a brand the policy does not list;
- producing a mark: `by/` and `approved/` come only from the channel and the approval capability;
- constructing an import specifier, host, credential name or cache namespace at runtime;
- recursion, unbounded iteration, or plan self-reference;
- evaluating a string as code;
- declassification inside a plan, which is why `zigttp:declassify/*` has no node kind;
- a plan that extends another plan's authority.

Declassification deserves its own line. It is the one operation that deliberately breaks the flow lattice, and letting a model-authored artifact perform it would undo section 9.6 entirely. A plan may use a tool that declassifies, because that tool was reviewed and its summary records what it released. A plan may not declassify on its own account.

When an agent needs something the grammar cannot express, it does not get it. The escalation path is a new AOT tool with human review, which is slower on purpose. A plan language that grows every time an agent is blocked becomes a programming language with none of the guarantees, which is the failure mode this design exists to avoid.

## 25. Where the reflective-calculus work applies

A plan is a program represented as data, and verification inspects its structure before running it. That is the same capability class as tree calculus triage, and the TIM work supplies the useful discipline: a named cost constant per step, and a bound that holds per node rather than per traversal.

None of Part B requires tree calculus. A typed DAG with a linear verifier in Zig is sufficient, simpler and easier to audit, and it is what this spec calls for. The reflective machinery becomes load-bearing only under conditions that do not hold yet:

- plans that rewrite or specialize other plans, where the verifier reasons about a transformation rather than a structure;
- a plan language rich enough to need its own IR and cost semantics rather than a fixed node table;
- specialization before execution, where a plan is constant-folded and pruned against the current observation scope and a tighter cost and flow bound is re-derived from the residual.

The third is the nearest and most useful. It is also where structural inspection stops being a table lookup, which is the moment the earlier work starts paying.

---

# Part C. Execution targets

## 26. Target policy

**Primary: the zigts image as the only process in a KVM microVM, launched by libkrun-sev on AMD SEV-SNP and attested to a key broker before it holds any secret.** This is what the first release ships and what every performance and attestation claim refers to. The image is one static Zig binary holding the verifier, plan interpreter, scheduler, capability layer and journal writer, plus the manifest, policy and cost table, on a read-only root filesystem with nothing else in it.

**Development and CI: the same image under smolvm.** smolvm wraps the generic libkrun variant in a CLI and an embeddable SDK, runs on macOS, Linux and Windows hosts, boots an unpacked rootfs directory as the image, keeps the network off by default and allows egress per named host. That is the tool author's local loop and the CI harness, with the production image unchanged. It is not the production control plane: its own security section says so, its releases are unsigned and carry no provenance, and it builds on forks of libkrun and libkrunfw. CI builds it from a pinned source revision.

**Secondary, after the first release: isolation between tools inside the guest**, either protection-key domains per tool or a Wasm instance per tool. Section 28.5 says why this is cheaper than v0.5 assumed and section 31 says when to decide.

**Deferred: the purpose-built unikernel.** v0.4 and v0.5 made it primary. What it bought, a small syscall surface, no exec and no filesystem, and a measured image, is configuration in a microVM. What it lacked, a hardware boundary between tenants and a documented measurer with a key broker, the microVM brings with it. What it still has over the microVM is boot time and a smaller guest. Section 31 makes that a measurement rather than a belief: the unikernel returns only if the guest kernel, not attestation, turns out to dominate cold start.

## 27. What the marketing claims get wrong

Three corrections, because they affect planning.

**Wasm is not faster than native.** Expect a slowdown against native Zig, commonly in the tens of percent and sometimes approaching 2x, from bounds checking, indirect call checks and restricted ISA access. The efficiency comparisons in vendor material are against containers and VMs, where the real wins are cold start, image size and density. Those are worth having, and none of them is a speed argument. For tools that spend their time waiting on `fetch`, none of them matters much either.

**Wasm isolation is not free of the operating system by itself.** The isolation is independent of the OS only insofar as the runtime is correct, and a production wasm runtime is a large piece of software. The claim should be read as substituting trust in a small unaudited compiler for trust in a large widely-audited runtime, which is a reasonable trade but a trade, not an elimination.

**A microVM is not a unikernel.** A Linux guest kernel, even the trimmed one libkrunfw ships, is a large component. What makes it acceptable is what does not trust it: isolation between tenants rests on KVM and SEV-SNP, and isolation between tools inside the guest rests on the mechanisms in 28.5 or on nothing. Section 28.5 says which, rather than crediting the kernel with a boundary it does not provide.

## 28. Primary target: attested microVM

### 28.1 The image

Contents of the root filesystem, in full:

- `zttp`, one static binary: the host-channel endpoint, plan verifier, plan interpreter, DAG scheduler, capability layer, journal writer, seccomp installer, and the harness units compiled in like tools;
- the manifest, the policy and the cost table, each present by hash;
- nothing else. No shell, no loader, no libc beyond what is linked in.

The filesystem is read-only and integrity-protected, and its digest is the `rootfs-digest` in the certificate. It sits inside an encrypted volume whose key the guest receives only after attestation (28.2). The guest kernel is libkrunfw-sev. libkrun's init unlocks the volume, checks the digest and execs `zttp`, which installs a seccomp allowlist covering the capability set (sockets, memory mapping for arenas, clock, entropy, thread creation for the scheduler, exit) and nothing else. There is no `execve` after that point and no path by which code enters: the image is what was measured.

| v0.5 unikernel choice | microVM mechanism | contract it serves |
|---|---|---|
| syscall surface limited to net, timer, entropy, storage | kernel config with everything else compiled out, plus the seccomp allowlist on `zttp` | authority set has no ambient alternative to route around |
| scheduler is the DAG work-stealer, not general threading | unchanged, inside `zttp`; the guest kernel schedules only `zttp`'s threads | the parallel schedule is the only concurrency, so replay stays deterministic |
| arena per invocation, released whole, no GC | unchanged, inside `zttp`; the VM memory limit is the outer bound | `alloc` is enforceable and bounded |
| no dynamic loading, no `exec`, no filesystem | read-only rootfs of one binary; `execve` and `open` denied after start | nothing can enter the image after it was measured |
| boot measures image, manifest and policy | PSP launch measurement plus rootfs digest, bound at the broker (28.2) | the certificate chains to the thing that issued it |

### 28.2 Boot and attestation

Per VM:

1. The host process launches the VM through libkrun-sev. The AMD Platform Security Processor measures the initial memory, which is the firmware, kernel and init from libkrunfw-sev, and produces the launch measurement.
2. Init runs the key broker protocol: request, nonce challenge, an attestation report from the PSP carrying a freshness hash of the nonce and a fresh guest public key in its report data, response. The broker verifies the AMD certificate chain and compares the launch measurement against the registered workload.
3. On success the broker releases a bundle encrypted to the guest key: the volume passphrase; the expected `rootfs-digest`; the certificate-signing key for this (launch measurement, rootfs digest) pair; the credentials bound to hosts (section 5.1); the journal key.
4. Init unlocks the volume, verifies the digest and execs `zttp`. `zttp` reports ready over vsock and joins the pool.

Two consequences. The host process holds no secrets: credentials, signing key and journal key exist only inside attested guests and at the broker. v0.5 put credential attachment on the host side of the VM boundary; this draft moves it inside, which is where the documented libkrun-sev flow puts secrets and what makes the host irrelevant to confidentiality. And the certificate's measurement is two values, `launch-measure` from the PSP and `rootfs-digest` checked by init, signed by a key the broker released only to that pair. A remote verifier checks the signature against the broker's registration and its release log; it does not need to trust the node.

Registering a workload at the broker, which binds a launch measurement, a rootfs digest, the secrets to release and the policy under which to release them, is the deployment act that replaces "boot measures image, manifest and policy" from v0.5. The broker's release log is the transparency record. The broker is a separate machine and is in the TCB (section 24).

### 28.3 The isolation unit

One VM per observation. Scope, purpose, budgets and the disclosure ledger (section 22) are per observation, so the observation is the unit whose state should live and die with a guest. Plans within an observation run inside its VM. The VM is destroyed at the end of the observation and never reused.

A pool of booted and attested VMs waits for assignment, so an observation's first plan pays a dequeue rather than a boot. Snapshot and restore, which smolvm and Firecracker offer, is not available here: the launch measurement covers initial memory, and restored memory is not measured. Production VMs boot fresh; snapshots stay a development convenience.

### 28.4 The host process

What the host process does, and all of it: embeds libkrun-sev from a pinned stable branch, since `main` is the unstable 2.0 API; runs each VMM inside its own namespaces, as libkrun's security model requires, because guest and VMM share a security context and the VMM proxies for the guest; proxies guest sockets through TSI and applies a destination allowlist derived from the manifest's authority set, a second layer behind the attested capability layer; carries plans, results and journal ciphertext over vsock; pairs each observation VM with the model VM under mutual attestation (38); manages the pool; serves the model-facing HAL-FORMS dispatcher, which sees plans and the results the model is entitled to see and nothing else.

### 28.5 The honest weaknesses

- **Tools within one observation share the `zttp` process.** A memory-safety defect in a certified tool or in the capability layer can cross a tool boundary inside the guest, and no contract in Parts A and B would notice. What changed since v0.5: the process runs in user space, so protection keys are ordinary `pkey_mprotect` calls rather than the ring-0 problem the unikernel had, and the published figure for the same mechanism inside a unikernel is a sub-percent slowdown. Section 31 sequences it.
- **The host sees metadata.** TSI means the VMM sees the destination, size and timing of every outbound connection, though not plaintext. The timing and call-count channels of section 9 are observable to the host exactly as to a remote peer; the control label is the answer, not the VM.
- **Guest kernel defects.** A kernel bug is reachable only from tool code, and its blast radius is the observation's authority, not another tenant's. That is the boundary the unikernel did not have.
- **The broker.** One trusted service decides which measurement receives which secrets. Its policy, its log and its availability are in the TCB and on the critical path of every boot.
- **The firmware.** The PSP and the SEV-SNP firmware are trusted by construction. That is a vendor trust, stated rather than hidden.

## 29. Enforcement map

Where each contract is actually enforced.

| contract | attested microVM (primary) | per-tool sandbox inside the guest (secondary) |
|---|---|---|
| authority | capability layer inside the attested guest; TSI allowlist on the host as a second layer | same; a wasm instance's import table would add a third |
| routes | capability layer builds every request from a template; the host never sees plaintext | same |
| cost `steps`, `work` | counters in generated code | same, plus wasm fuel where used |
| cost `alloc` | arena limit per invocation; VM memory limit as the outer bound | plus a linear memory maximum per instance |
| cost `wall` | per-capability timeouts in the capability layer, hit count bounded by `calls` | same |
| flow | static, compile time | same |
| memory safety | language level in tool code; the `zttp` process is the blast radius | mechanism level per tool |
| isolation between tenants | KVM and SEV-SNP, one VM per observation | same |
| isolation between tools | none beyond the language, until 31.3 | protection keys or an instance per tool |
| secrets | released by the broker into the attested guest only | same |
| replay | journal, encrypted with a broker-released key, shipped to the host | same |
| determinism for replay | counted fuel, no wall clock | same; never epoch interruption |
| models | separate attested model VM, mutual attestation, weights hash in the certificate (38) | same |

Three things are worth extracting from that table.

**Fuel is the same quantity everywhere.** `steps` and `work` are counts the generated code maintains, not time estimates, and wall-clock behaviour is handled by per-capability timeouts. A per-tool wasm sandbox can enforce the same numbers independently, which turns a budget overrun into a trap rather than a slow response.

**Flow gains nothing from the target.** It is a compile-time property with no runtime representation, which is why section 5.1 matters more than any boundary: removing credentials from the program is worth more than any mechanism for watching where they go.

**Attestation binds the certificate to the image and nothing more.** It says which code ran. It does not say the code is correct, which is what Parts A and B are for, and it does not isolate tools from each other, which is what the secondary column is for.

## 30. Portability constraints to hold now

The same image has to run under generic libkrun, libkrun-sev and, if ever needed, Firecracker, and a per-tool sandbox has to stay cheap to add. Five constraints keep that true, and four are already restrictions in Part A:

- **Values only across boundaries** (restriction 65). No handles, pointers or callbacks. Boundary types marshal to a linear-memory ABI without redesign.
- **Capabilities are imports, not values** (restriction 54). An import list maps directly onto a wasm import table. A capability passed as a value would not.
- **Single-threaded tool bodies** (section 7). Parallelism lives in the scheduler across plan nodes, never inside a tool, so no shared-memory threading proposal is needed.
- **Bounded allocation** (restriction 57 and section 8). A linear memory maximum is expressible; an unbounded heap is not.
- **The guest talks to the host over vsock and sockets only.** No virtio-fs, no shared memory, no host paths. This is what lets the smolvm development loop use the production image unchanged.

One thing to watch that is not yet a restriction: the plan interpreter and combinator nodes stay in `zttp`, and only `call` nodes cross into a per-tool sandbox if 31.3 adds one. Crossing is cheap per call and expensive per node, so a plan with many small combinator nodes would be dominated by crossings if the interpreter moved inside a sandbox.

## 31. Sequencing

1. Generic libkrun under smolvm, same image: all six contracts, the development loop, CI. Measure boot, per-node costs, arena high-water marks, and observed plan sizes for `P_max`, `D_max` and `I_max`.
2. libkrun-sev and the broker on the AMD hardware. Measure fresh-boot-plus-attestation latency and size the pool from it. Confirm the broker against libkrun's client: the register-workload and get-key steps are extensions of the reference broker, not part of the base protocol. Sign certificates with the released key and verify one end to end from a machine that trusts only the broker.
3. Only then, per-tool isolation inside the guest: protection keys against a wasm instance per tool, decided on measured crossing costs and on the capability layer audit in section 32.
4. The unikernel only if step 2 shows that guest boot, not attestation, dominates cold start.

Nothing in the first release should depend on 3 or 4 ever happening.

---

## 32. Open questions

- **`P_max`, `D_max`, `I_max`.** Too low and plans cannot express useful compositions; too high and the verifier's worst case grows. Set them from observed plan sizes rather than guesses, which means shipping generous limits with telemetry first.
- **Flow precision.** Field-level summaries plus control labels will produce false positives where a tool's output field does not depend on a sensitive input but the analysis cannot see why. Public discriminants (9.4) handle the common `Result` case. What remains is either finer summaries, whose cost grows with record width, or explicit declassification.
- **Downstream declarations.** The route-to-route rule in 9.4 needs a deployment vocabulary for intended relays. Routes make it finer than the host rule did, which sharpens the question: too coarse and it blocks legitimate enrichment, too fine and it becomes a policy language.
- **Purpose vocabulary.** 9.8 needs a lattice of purposes and a way to write aggregation predicates that a policy author can read. The screening case fixes the first for one deployment; the second is open.
- **Failure taxonomy across composition.** A plan's `Failure` is a union over its `call` nodes' failures, which grows quickly and reaches the model as a wide union. Collapsing it loses retryability information; keeping it wide makes the form harder for a model to use well.
- **Who sees the certificate.** Exposing cost, routes, purpose and flow to the agent helps it compose within limits and also tells it exactly where the limits are. Worth deciding deliberately rather than by default.
- **Capability layer audit.** Inside the guest this is the only unsafe surface and, until 31.3, the only thing standing between two tools. It needs a size budget and a review cadence, both currently unset.

Implementation questions for section 28, to answer in sequencing step 2.

- **Host kernel and firmware.** Which host kernel on the chosen distribution carries SEV-SNP guest launch support, what the BIOS needs enabled, and whether the broker handles the processor generation's certificate chain (Milan against Genoa) without special casing.
- **Which broker.** The reference broker libkrun was demonstrated against, or the Confidential Containers broker. libkrun's client speaks the reference broker's register-workload and get-key extensions; compatibility with anything else is to be verified, not assumed.
- **Binding the rootfs digest.** In this draft init verifies it from the broker's bundle. Whether the digest can instead enter the measured initial memory, so that the PSP measurement covers it directly and the bundle carries one fewer trusted value, depends on what libkrunfw-sev includes in that memory.
- **Attestation latency.** Fresh boot plus the broker round trip is the cold-start number that matters now. Pool size follows from it and from observation arrival rate.
- **Key rotation and revocation.** The signing key is per registered workload. Every image change re-registers; revocation is deregistration at the broker plus the certificate's measurement check. Whether certificates need an expiry as well is open.

Research before design, still open.

- **Credential scope per observation.** The broker releases credentials bound to hosts into the guest; nothing yet bounds which subject the model names on a route. Candidates: the capability layer injects subject parameters from the observation rather than accepting them from the tool; per-observation attenuation by caveated tokens (Biscuit, Macaroons) or token exchange where an upstream supports it. Which upstreams do is the question.
- **A reference model for the verifier.** The plan verifier trusts every manifest summary, and one wrong compiler-derived summary poisons every plan. Two cheap checks are known to work elsewhere: an executable reference model differentially tested against the implementation, and dynamic label propagation in the plan interpreter as a backstop. Whether a proof assistant is worth it for a grammar this small is the question.

Open questions from Part D.

- **Planner-admissible brands.** The vocabulary of types an extractor may produce for a planner decides how much an injected document can steer a harness. It needs a starting list and a review criterion per entry.
- **Extractor schema discipline.** How the extractor is prompted to produce brand-parseable output, and what happens to a harness when it cannot, are harness-author concerns with no compiler behind them yet.
- **Deterministic decoding.** Whether the chosen inference stack can honour fixed decoding parameters bit for bit, which decides whether replay reproduces the model's answer or reads it from the journal.
- **The entitlement store's consistency mode.** Whether a consequential effect needs a fully consistent read against the relationship store, and what that costs at the observation's call rate.
- **The response sink's ledger.** Whether the response to a human needs its own disclosure ledger or shares `Output`'s.

---

# Part D. The harness

In v0.6 the agent was outside the guarantee: it is whatever emits plans, and the runtime sees only the plans. This part makes the agent code. A harness is a zigts module that turns an authenticated request into an observation, obtains plans from a planning model, submits them, turns what comes back into typed facts, and answers over the channel. It is compiled like a tool, carries the same derived artifacts, and lives in the same image. The model becomes a capability the harness imports, with a label on everything it says.

The consequence is that the guarantee moves outward. In v0.6 it stops at `Output`, the value handed to a model the runtime cannot see. With a harness inside, it stops at the channel: nothing leaves the image except through a sink whose policy passed, no consequential effect happens on an argument a human did not supply or approve, and the model influences nothing it was not shown through a reviewed type.

Two rules govern everything below.

1. **The model is a capability, never an enforcer.** Pre-flight is the verifier, the boundary is the capability layer, the audit is the journal. The model sits in none of those and must stay out of them. A model judging its own tool calls is the pattern this design exists to replace.
2. **The planner never sees untrusted data.** The model that emits plans is shown only values with clean integrity. Untrusted content reaches it only after a second, quarantined model call has turned it into a typed value through a reviewed brand. This is the structure CaMeL enforces with an interpreter; here it is a sink policy the compiler checks.

---

## 33. Integrity

Section 9.1 now defines labels with three components. This section says why. Through v0.6 integrity was one taint, `input`, meaning model-controlled, and with the harness inside that is not enough: a response body from `http/<route>` is where prompt injection arrives, a model's output is the model's word and nobody else's, and a human's approval is a fact about a principal that no join should erase by accident. For reading, the label from 9.1 again:

```
Label ::= { origins: set of Origin,       as in 9.1, joins by union
            taints:  set of Taint,        joins by union
            marks:   set of Mark }        joins by intersection

Taint  ::= taint/input                    was `input`; model-controlled plan input
         | taint/upstream/<route>         a response body
         | taint/upstream/kv/<ns>         a read from a namespace not declared trusted
         | taint/model/<role>             a model's output

Mark   ::= by/<principal>                 came over the authenticated channel from this principal
         | approved/<principal>           this principal approved it through the approval affordance
```

A value is clean when its taint set is empty. A constant has every mark, so joining with a constant erases nothing. A model's output has no marks, because a model's word carries no principal. Brands do what they did in 9.5, now for every taint: a listed brand's constructor clears the taints its policy entry names and adds `checked/<Brand>` to the origins. Nothing else clears a taint, and nothing adds a mark except the two capabilities in 35.3 and 35.4.

The control label from 9.2 carries all three components. A `match` on a tainted discriminant taints every binding, call and `Failure` inside its arms; a `match` on a value with marks keeps them only on bindings that also had them. Public discriminants (9.4) still exempt low-capacity tags from raising the control label, and the exemption now applies per component: a tag declared public for taints still carries its origins.

The policy rows over the new components live in 9.4 and are repeated here:

| flow | default |
|---|---|
| any taint into a structural position | denied (generalizes the `input` row) |
| any taint into a `model/planner` context | denied |
| any taint into a `subject` route parameter (5.2) | denied |
| a consequential route (36.2) without `approved/<p>` on its arguments and control label | denied |
| a dual-control route without `approved/<p>` and `approved/<q>`, p ≠ q | denied |
| a `subject` parameter without `by/<principal of the observation>` | denied |
| anything else | as in 9.4 |

The second row is the planner split. It says nothing about which model; it says the planner's context is a sink like a route parameter is a sink, and the same typing that keeps injected structure out of a path keeps injected instructions out of the plan.

---

## 34. Models as capabilities

```ts
import { complete } from "zigttp:model/planner";     // role, not a model
import { complete } from "zigttp:model/extractor";
```

A harness imports models by role. The manifest binds each role to a concrete model by its weights hash and its decoding parameters, and the certificate records the binding (40.4). The custom router in the capability layer resolves a role to an endpoint at runtime; a harness cannot name a model, for the same reason a tool cannot name a host.

`complete` has the type `(ctx: Context<N>) => Result<Text<M>, ModelFailure>` with `N` and `M` from the role's manifest entry. Its label rule is the one rule that matters:

- origins of the result = join of the origins of everything in `ctx`;
- taints of the result = taints of `ctx` ∪ { `taint/model/<role>` };
- marks of the result = ∅.

A model mixes everything it sees, so its output carries everything it saw, and it adds its own taint on top because its word is nobody's. This is the FIDES rule and the reason the planner split is necessary: a planner that saw one upstream body would produce plans that could not touch a structural position anywhere.

Cost gains a dimension. `tokens` is a fifth quantity alongside `steps`, `work`, `alloc`, `calls` and `wall`, bounded per call by `N + M` from the role entry and per observation by the budget. `wall` for a model call is the role's timeout, and it dominates every other wall term in a harness. Decoding parameters are fixed in the manifest; where the model VM supports deterministic decoding the output is reproducible, and in every case it is journaled like any capability result (22), so replay reads the model's answer rather than asking again.

The planner's `Text<M>` result is a plan in source form. `Plan.from` is a brand constructor that parses it or fails; it clears nothing. The plan value keeps `taint/model/planner`, and that is correct: plans are verified, not trusted. Verification (20) is the endorsement of a plan, and the certificate is its `checked` mark.

---

## 35. The harness module

A harness is a zigts unit that exports one function:

```ts
export const run: (req: Request) => Result<Response, Failure>
```

with `Request`, `Response` and `Failure` in the boundary grammar of section 4, and every restriction in section 11 in force. The compiler derives the same artifacts it derives for a tool. The authority set of a harness says which model roles, which stores, which tools and which of the four harness capabilities below it can reach, and a reviewer reads it the same way.

### 35.1 Observe

A request arrives over the authenticated channel, so its fields carry `by/<principal>` and no taints. The harness builds the observation from them: principal, purpose, subjects, budgets. Subjects come from the request, which is what gives a `subject` route parameter its `by/` mark for the rest of the observation.

```ts
import { entitled } from "zigttp:entitlement";
const obs = entitled(req.principal, subjects, req.purpose);
```

`entitled` is the relationship check from the four-gaps document, resolved once here rather than per call. Its answer is journaled with the store's snapshot token so replay reproduces it. A subject discovered later from a tool output has upstream taint and cannot reach a `subject` parameter at all; if a harness needs to act on discovered subjects, it extracts them (35.3) and calls `entitled` again, which is a second journaled decision and a second `by/` mark, not a bypass.

### 35.2 Plan and submit

```ts
import { verify, run as execute } from "zigttp:plans";
const cert = verify(Plan.from(complete(ctx)), obs);
const out  = execute(cert, { accept: BOUND });
```

`verify` is section 20 as a capability. `execute` runs the certified plan and returns values labelled by the certificate at runtime. A harness's own summary is static, so it cannot know a plan's flow in advance; it declares a bound instead. `BOUND` is a constant label: the largest origin set, the largest taint set and the smallest mark set the harness will accept from any plan result, plus a cost ceiling. The compiler uses `BOUND` as the label of `execute`'s result in the harness summary, and the runtime refuses a result whose certificate exceeds it. A harness that wants to see more declares more, and the reviewer sees it in the same ten lines as the imports.

### 35.3 Extract

```ts
import { complete as extract } from "zigttp:model/extractor";
const facts = Verdict.from(extract(context_of(out)));
```

The extractor is the quarantined model. Its context may carry any taint; its output carries all of them plus `taint/model/extractor`, and it is useless until a brand admits it. The brands a policy lists as planner-admissible are the whole of what injected content can ever influence: an enum, a bounded number, a date, a customer id already in the observation's subject set. A free-text brand is not planner-admissible, because a brand that accepts any text is the laundering point 9.5 was tightened to remove.

What remains is stated rather than hidden: an injected document can still steer a planner through a `Verdict` that is one of four tags. That is a capacity argument, the same one FIDES makes for declassifying low-capacity types, and the policy author decides which few bits are acceptable by deciding which brands are on the list.

### 35.4 Approve

```ts
import { approve } from "zigttp:approval";
const approved = approve(req.principal, cert);
```

For a certificate whose routes include a consequential class (36.2), the harness presents the effects, subjects and argument values the certificate names, over the channel, as a HAL-FORMS affordance. The principal's answer returns the certificate with `approved/<principal>` on it and on the argument values it names. `execute` on a certificate with consequential routes and no approval mark is a policy violation the verifier already refused at `verify`, so the harness cannot skip this step by accident. Dual control is a second `approve` from a distinct principal.

This is plan-level approval: once per certified plan, showing everything the plan will do, with concrete arguments, rather than once per action. It closes the gap plan-then-execute leaves open, that injection chooses the arguments of a planned call, because the arguments of a consequential route must carry the mark and a mark cannot come from a model or an upstream.

### 35.5 Loop and respond

Agent loops are unbounded in every framework in use. zigts forbids unbounded iteration, so a harness loop is a `fold` over `Bounded<Step, N>` with `N` in the manifest: the harness makes at most `N` planning rounds and fails with a `budget` tag otherwise. Delegation to another harness is a `call` to a tool, and the call graph is acyclic, so no harness can recurse or converse with another indefinitely. This is the strongest termination guarantee any agent design offers, and it falls out of restriction 56.

The response is a sink. It carries the principal's purpose from the observation and is checked like `Output` in Part A: origins against the purpose (9.8), taints against the channel's policy, and the aggregation predicate against the ledger.

### 35.6 Worked example

```ts
// harness/screening-assistant.ts
import { complete as plan }        from "zigttp:model/planner";
import { complete as extract }     from "zigttp:model/extractor";
import { verify, run as execute }  from "zigttp:plans";
import { entitled }                from "zigttp:entitlement";
import { approve }                 from "zigttp:approval";
import { CustomerId, Plan, Verdict, Summary } from "./brands";

export type Request  = {
  readonly principal: Principal;          // by/<principal>
  readonly purpose:   Purpose;
  readonly customer:  Text<64>;
  readonly question:  Text<2048>;
};
export type Response = { readonly verdict: Verdict; readonly summary: Summary };
export type Failure  = "not-entitled" | "budget" | "denied" | "declined" | "unresolved";

const BOUND = label({
  origins: ["http/api.screening.example.com GET /reports/{id}", "tool/*"],
  taints:  ["taint/upstream/*"],
  marks:   [],
  cost:    { steps: 4000, work: 65536, calls: 12, wall: 30_000 },
});

const STEPS: Bounded<Step, 6> = steps(6);

export const run = (req: Request): Result<Response, Failure> => {
  const id  = CustomerId.from(req.customer);                 // by/<principal>, no taint
  const ent = entitled(req.principal, [id], req.purpose);    // journaled with a snapshot token
  return match(ent, {
    no:  ()    => fail("not-entitled"),
    yes: (obs) => {
      const final = fold(STEPS, initial(req, id), (state, _) =>
        match(state.done, {
          true:  () => state,
          false: () => {
            const cert = verify(Plan.from(plan(state.ctx)), obs);     // ctx is taint-free by policy
            return match(cert.needsApproval, {                        // public discriminant
              true:  () => match(approve(req.principal, cert), {
                             declined: ()  => halt(state, "declined"),
                             approved: (a) => step(state, execute(a, { accept: BOUND })) }),
              false: () => step(state, execute(cert, { accept: BOUND })),
            });
          }}));
      return match(final.done, {
        true:  () => ok({ verdict: final.verdict, summary: final.summary }),
        false: () => fail(final.halted ?? "unresolved"),
      });
    }});
};

// step: extractor turns plan output into branded facts; only those and public tags enter state.ctx
const step = (state: State, out: PlanResult): State =>
  advance(state, Verdict.from(extract(context_of(out))), Summary.from(extract(context_of(out))));
```

What the compiler derives for it, abbreviated:

```
authority:
  model/planner, model/extractor, plans, entitlement, approval
routes:   none of its own; plans are bounded by BOUND
cost:
  steps  ≤ 6·(steps(planner) + 2·steps(extractor) + 4000) + 310
  tokens ≤ 6·(N_planner + M_planner + 2·(N_extractor + M_extractor))
  calls  = { model/planner: 6, model/extractor: 12, plans: 6, entitlement: 1, approval: 6 }
  wall   ≤ 6·(timeout(planner) + 2·timeout(extractor) + 30 s)
flow:
  reaches model/planner ← { by/<principal>, const, checked/Verdict, checked/Summary }   taints ∅
  reaches Response      ← BOUND.origins ∪ { checked/Verdict, checked/Summary }          taints ∅
  fails   not-entitled  ← { entitlement }
  endorsements: Verdict → planner, Summary → planner, CustomerId → subject
```

The line to read is `reaches model/planner`: nothing with a taint reaches the planner, and the reviewer can see that without reading the loop.

---

## 36. Restrictions and effect classes

### 36.1 Restrictions 71 to 78

| # | restriction | what it buys |
|---|---|---|
| 71 | A harness imports models by role; roles bind to weights hashes in the manifest | which model made a decision is attested, not assumed |
| 72 | A `model/planner` context accepts no taint | the planner split holds by typing |
| 73 | Extractor output reaches a planner context or a structural position only through a listed brand; no free-text brand is planner-admissible | injected content influences at most the listed types |
| 74 | A harness loop is a `fold` over `Bounded<Step, N>` with `N` in the manifest | bounded rounds, bounded tokens, guaranteed termination |
| 75 | `execute` declares an accepted label bound; a result above it is refused | the harness summary stays static |
| 76 | Marks come only from the channel and the approval capability; models yield none; constants yield all | a principal's word cannot be manufactured |
| 77 | A consequential route requires `approved/` marks per its class on arguments and control label | injection cannot choose the arguments of an effect |
| 78 | The response is a sink with the observation's purpose and the ledger | the boundary is the channel, not `Output` |

Seventeen restrictions in Part A, eight here.

### 36.2 Effect classes

Section 5.2 splits `get` from effects. Routes gain a class, derived by the compiler from the method and template and confirmed by review, never self-declared:

| class | meaning | requirement |
|---|---|---|
| read | `get` | none |
| reversible | an effect with a declared compensating route | idempotency key from (plan-hash, node id, inputs) |
| irreversible | an effect without one | idempotency key; rate limit per observation |
| consequential | irreversible and material: money, legal notice, records disclosure | `approved/<p>`; dual control where policy says |

Idempotency keys make retries after failure safe; compensating routes let a failed plan unwind where the upstream allows; the rate limit bounds a compromised session's blast radius even after approval. A hint a tool author writes about its own route is not a class; the eBPF helper-contract lesson and the MCP annotation lesson are the same lesson.

---

## 37. Cost and budgets

`tokens` joins the five quantities of section 8. Per model call it is at most `N + M` from the role entry; per plan it is the sum over model calls; per harness it is `N_steps` times the per-round sum. The observation budget gains a `tokens` line and is charged the declared maximum like everything else (22). Actual token counts are telemetry.

The harness's polynomial is in its declared dimensions plus the constants in `BOUND`. A plan's actual cost is dynamic, known only from its certificate, but it is bounded by `BOUND.cost` and refused above it, so the harness's pre-flight is arithmetic over declared numbers exactly as a tool's is.

---

## 38. Placement

The harness runs inside the observation VM (28.3). The question is where the models run.

**Inside the observation VM.** Every guarantee in this part holds; the model is measured with the image. The cost is that encrypted guest memory cannot be shared across VMs, so the weights load into every VM: about 14 GB per observation for a 7B model in bf16, plus load time on every fresh boot (28.3 forbids snapshots), plus CPU inference unless the deployment takes on confidential-GPU hardware.

**A separate attested model VM.** The models run in their own image, measured like any other, registered at the broker with their weights hashes, serving many observations. `zigttp:model/<role>` reaches it over vsock or TLS with mutual attestation: the observation VM presents its certificate-signing key, the model VM presents its measurement, and the router refuses a pairing the manifest does not name. The observation VM stays small and the pool stays cheap. What the harness loses is nothing: the model call has the same label rule, the same journal entry, the same weights hash in the certificate. What the deployment gains is one place to put a GPU.

v0.7 takes the second. The earlier decision to run reasoning inside the certified image is still met: the reasoning is the harness, and the harness is inside. The first option remains available if confidential-GPU hardware is adopted, and nothing in this part changes if it is.

---

## 39. What this part does not close

- **Bounded influence through admitted brands.** An injected document can steer the planner through whatever branded types the policy admits. The capacity is small and stated; it is not zero.
- **Wrong decisions from correct data.** A plan built on clean, entitled, approved values can still be the wrong plan. Approval is the control, and approval can be wrong.
- **The weights.** Provenance, fine-tune lineage and the backdoored-model literature are review items with no compiler behind them. A model update is an image change and forces re-attestation and re-audit, which is the right discipline and is not free.
- **The entitlement store.** The relationship check is data. Its correctness is the compliance record's correctness, and its availability is on the path of every observation.
- **The router.** It is Zig, not zigts, and it falls under the capability-layer audit in section 32.

---

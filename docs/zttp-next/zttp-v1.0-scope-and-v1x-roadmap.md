# zttp: proposed v1.0 scope and v1.x roadmap

**Review date:** September 15, 2026  
**Status:** Recommendation, not an accepted project decision or an implementation report  
**Specification reviewed:** `zigts-tools-extension-v0_6.md`, Draft v0.6, all 32 sections  
**Repository baseline:** `srdjan/zttp`, `main` at `de81726d753f229e6e47ecb78a7b1a14d75fa8de`; README identifies v0.20.0  
**Method:** Static review of the supplied specification, repository documentation, and selected implementation sources. No build or test suite was run. No repository files were changed.

> **Added when this file was tracked, 2026-09-20.** Two of the four header facts
> above no longer describe this tree, and both are left as written because they
> date the review rather than describe the present.
>
> The specification reviewed, `zigts-tools-extension-v0_6.md`, is not in this
> repository. [zigts-tools-extension-v0_7.md](zigts-tools-extension-v0_7.md)
> supersedes it and is. The section references below still resolve, because v0.7
> keeps sections 1 to 32 with their numbering and adds 33 to 39 as a new Part D.
> Part D is outside what this review read, and it is the part that makes the
> agent code: models as capabilities, the harness module, and placement in an
> attested microVM. That is the same territory section 1 below recommends
> deferring, so the recommendation is not answered by Part D, it predates it.
>
> The repository baseline `de81726d753f229e6e47ecb78a7b1a14d75fa8de` is the head
> of `origin/main` and is not an ancestor of local `main`; the two have diverged.
> The README carried `v0.20.0` at that commit and carries no version on this
> line of history, where `build.zig.zon` reads `0.19.0`.

## 1. Recommended release boundary

**Ship developer-authored, compiler-described, resource-exposed tools on the existing zttp execution and artifact-acceptance path. Defer model-authored executable plans and confidential hosting.**

This is a deliberate reduction of the v0.6 first-release guarantee set, not an assertion that the full specification can be implemented by disabling a few features. In particular, v1.0 would trust the operator and host. It would not claim confidentiality from the host, arbitrary untrusted-code isolation, or per-tool native-memory isolation.

The first-release adversary is an untrusted model/caller supplying inputs to reviewed tools. The compiler, runtime, reviewed capability implementations, accepted artifacts, and deployment authority remain trusted to their explicitly disclosed assurance levels.

If hostile-host confidentiality is a mandatory first-customer requirement, the confidential execution track must remain on the release critical path. A native deployment is not an equivalent substitute for that threat model.

### Product definition

> zttp v1.0 lets a developer publish a typed tool as an ordinary zttp handler. The compiler derives its bounded interface, description, reachable capabilities, routes, and supported flow facts. The deployed runtime accepts the artifact, authenticates and scopes the invocation, enforces resource limits, executes only approved capabilities, and returns a bounded result with an auditable invocation record.

Keep the existing developer workflow: `init`, `dev`, `test`, `expert`, and `deploy`. The development agent may continue producing source through the compiler fence. A deployed invocation must not compile model-supplied source.

## 2. Integrate with the project that exists

| Existing foundation | Integration decision |
|---|---|
| `zttp:*` virtual modules and per-export effect/capability metadata | Use the same capability registry and enforcement seams; do not create a parallel `zigttp:*` ecosystem. |
| `structural` and `nominal` declarations | Rewrite normative examples to the current language. Ordinary `type X = ...` is rejected by the documented current profile. |
| `function handler(req)` serving entrypoint | Generate the existing handler shape. The draft's `handle` spelling is not a reason to introduce another runtime entrypoint. |
| `Effects<T, S>` and `Proof<T, P>` | Specify how the stricter tool profile interacts with existing exported-helper ceilings and proof obligations. Inferred tool authority is not a second unrelated effect system. |
| Bytecode compiler/interpreter and self-contained deployment packaging | Keep this backend. Clarify that a native Zig executable can contain the existing engine and precompiled tool bytecode; do not silently add a native tool-code generator. |
| Contract extraction and consumer-owned proof checker | Extend the accepted contract/evidence format. A new compiler-produced summary or signature must not silently become an independently proven property. |
| `resource(data, affordances)` and HAL/HTMX rendering | Add generated HAL-FORMS tool descriptions to this path rather than creating another dispatcher. Existing HAL support does not establish complete HAL-FORMS/schema equivalence. |
| Request arenas, outbound HTTP bridge, trace support | Extend these seams for bounded invocation accounting and capability replay. Avoid a second runtime or tracing subsystem. |

Define a versioned, additive **tool profile**. Apply const-only bodies, bounded iteration, closed boundaries, static capability references, and acyclic calls to that profile and its reachable helper graph. Do not globally invalidate existing ordinary handlers to implement the extension.

The repository's strategy primarily targets developers shipping verified handlers; the platform-owner persona is explicitly secondary/deferred. Runtime plans and the broker/VM control plane expand that product boundary substantially. [R1–R7]

## 3. v1.0 essentials

| Area | Required first-release behavior | Deliberately not required |
|---|---|---|
| Tool unit | One exported tool; explicit Input, Output, Failure; generated handler; closed domain failures; separate bounded platform/admission errors. | Another transport, a second runtime, or a general plugin system. |
| Boundary grammar | Closed records, finite numbers, booleans, literals, explicit null, fixed `Text<N>`, fixed `Bounded<T,N>`, discriminated unions, reviewed nominal constructors. | Named dimensions and arbitrary refinements requiring cross-call proof. |
| Boundary enforcement | Validate incoming requests, capability results, tool-to-tool boundaries where required, outputs, and failures. Cap raw bytes and nesting before expensive decoding. | Assuming a small final Output bounds an upstream response or parser allocation. |
| Descriptors | One canonical type/contract representation generates the runtime validator, JSON Schema projection, and HAL-FORMS description. Define projection limits and Unicode semantics explicitly. | Treating the projections as automatically equivalent merely because they share a generator. |
| Authority | Derive direct and transitive authority; check live observation permissions at the capability boundary. Ban computed capability identities and ambient bypasses in the new profile. | General dynamic capability grants or a new delegation/token platform. |
| HTTP | Literal method/path templates; runtime encoding; endpoint and subject checks; bounded request/response/header sizes; validated TLS for credentials; no redirects in the initial profile. | A general URL builder or automatic retries of externally visible writes. |
| Credentials | Bind credentials in the runtime to approved capabilities; never expose their values to tool code. Expose signing as an operation where an actual integration requires it. | `secret-value/*`, arbitrary user-supplied authorization headers, or general declassification. |
| Observation scope | Trusted invocation context carries principal, tenant/service, allowed subjects/resources, expiry and remaining budgets. Model input cannot author or broaden this context. | Purpose lattices, subject-token exchange, and generic caveated-token infrastructure. |
| Cost | Fixed input/output and call-count maxima where derivable; enforced step/work/memory/byte/deadline ceilings. Reserve public maxima atomically against observation budgets. Distinguish derived bounds from configured runtime ceilings. | Full symbolic cost-polynomial generation, cross-target equivalence, or a static guarantee that every admitted invocation finishes within its reservation. |
| Flow | Conservative provenance and control-dependency propagation over the admitted profile, including Failure and all outbound request positions. Explicit release/downstream rules. Unknown analysis results fail closed. | Maximum precision, a broad declassification language, or a timing/noninterference claim. |
| Composition | Developer-authored, build-time composition with acyclic calls and checked failure handling. Charge transitive budgets once, not once again per nested accounting layer. | Runtime-authored plan resources. |
| Scheduling | Sequential, specified source/effect order. No implicit reordering of I/O. | A work-stealing DAG scheduler. |
| Storage | Read-only labelled namespaces in the new profile. Existing ordinary-handler storage APIs are unchanged. | KV mutation in the new profile until atomic commit, read-your-writes and failure semantics are specified and tested. |
| Replay | A bounded capability transcript sufficient for offline replay of the supported profile; explicit incomplete/unknown outcomes; protected journal data. Reuse existing trace facilities where semantics align. | Crash-resumable distributed execution or exactly-once external effects. |
| Deployment | Current macOS/Linux developer support and self-contained deploy path; explicit trusted-operator threat model; no weaker acceptance bypass for tools. | smolvm/libkrun, AMD SEV-SNP, a broker, guest pools, or per-tool sandboxes as mandatory dependencies. |

### Cost terminology must remain honest

A **derived upper bound** is a compiler/checker claim about admitted computation. A **runtime ceiling** is an enforcement limit that can stop computation. They are not interchangeable. The v1.0 contract must distinguish them, using the existing evidence/acceptance vocabulary rather than presenting a timeout or arena limit as a static proof.

Fixed bounds simplify the release even when some cost inference remains: no named-dimension algebra is needed to publish an absolute route-call maximum or encoded-value maximum. Runtime metering still needs to charge byte-proportional native work and stop before the next external effect when its budget is unavailable.

The current HTTP bridge has a zero-timeout path meaning no timeout. The tool profile must require nonzero finite deadlines rather than inherit an unlimited setting accidentally. [R8]

## 4. Corrections required before implementation

### 4.1 Validation is not subject authorization

Sections 9.5 and 32 correctly distinguish these, but leave subject scope as research. Move the minimum implementation to v1.0.

A valid `CustomerId` may still identify another tenant's customer. The capability boundary must compare it against trusted observation scope or inject a subject chosen from that scope. This does not require Macaroons, Biscuit, or token exchange in the first release; an explicit finite subject allowlist or observation-bound subject is sufficient for the reference workflows.

Also separate provenance from endorsement. A reviewed parser can establish that a string is safe in a particular path slot without establishing that the model did not choose the string. Removing `input` globally and subsequently allowing declassification because the label no longer contains `input` conflates those claims. Retain provenance and represent sink-specific endorsement separately. Defer declassification until this distinction has executable tests.

### 4.2 Make the worked example type-correct

Section 9.5 declares `CustomerId.from` to return `Result<CustomerId, Failure>`. Section 13 passes its return directly to `verifyIdentity` and to route params. The jurisdiction map similarly produces a collection of constructor results, not validated jurisdictions.

The example must explicitly handle those failures and sequence/traverse bounded results before calling a capability. Add a compile-pass reference example and compile-fail mutations. The generated request wrapper does not discharge unchecked internal Results.

Use `zttp:*`, current `structural`/`nominal` syntax, and the current handler/effect conventions. Do not ship documentation whose canonical example the project rejects. [S §§3, 9.5, 13; R6–R7]

### 4.3 Define boundary semantics, not just surface types

The grammar advises `| null` without explicitly listing a null production. It also leaves the mapping from a bounded byte string to the descriptors unspecified.

`Text<N>` is defined in UTF-8 bytes. JSON Schema `maxLength` measures characters, not UTF-8 bytes. For example, a four-byte Unicode scalar can satisfy a character maximum of one while failing `Text<1>`. Specify a byte-length extension/profile rule enforced by the generated validator, and do not claim ordinary third-party JSON Schema validation enforces that extension. Define nested-record/union projection, unknown fields, missing fields, duplicate JSON keys, finite numeric handling, and bounded failure encoding. [S §4 and §6; W1]

Bounds must cover every capability response and intermediate primitive, not only tool Input and Output. Otherwise fetching and parsing a large document before returning a small boolean defeats the cost argument.

### 4.4 Correct purity, ordering and replay claims

An HTTP or mutable-storage read is not a pure function of Input. The useful distinction is pure computation versus explicit capability effects, and deterministic replay against a fixed journal. Section 10's determinism claim should agree with section 22.

Independent const bindings do not prove independent external observations. Reads may depend on preceding writes without a value dependency, and GET classification does not prove that a remote operation is observationally pure. Start sequentially; introduce concurrency only after explicit effect-order/read-consistency semantics and measurements.

A journal entry needs a dynamic execution address, for example:

`invocation ID + call-site path + iteration indexes + capability-call ordinal + attempt`

A static node ID alone repeats inside map/fold bodies. Recording an external effect after it returns also leaves a crash window in which the upstream acted but no result was recorded. Represent that outcome as unknown; do not automatically reissue it. Replay and durable recovery are separate features. [S §§7, 10, 22]

### 4.5 Preserve consumer acceptance and disclosed assurance

The current checker policy explicitly distinguishes its assurance levels. `results_checked`, `no_secret_leakage`, and `capability_bounded` currently enter the production floor at `tested`; bytecode meaning contributes a `trusted` edge. Reusing this checker is essential, but reusing it does not make a new flow matrix independently proven. [R9]

For each new claim, state its evidence grade and acceptance rule, bind it to the executable and policy identities, and supply an adversarial mutation that acceptance rejects. A signature establishes provenance, not semantic correctness. Keep this distinction through later hardware attestation.

### 4.6 Separate internal tool returns from model-visible disclosure

Section 9.4 denies sensitive KV data reaching Output, while section 19 describes a tool returning sensitive data as permitted because it sends it nowhere. These statements need different boundary kinds to coexist.

An internal tool result may retain a sensitive label inside a larger computation. Returning that same value to the model is a disclosure sink. Define separate rules for internal returns, top-level Output/Failure, and any model-facing resource representation. This is needed for authored composition too, not only runtime plans. [S §§9.3–9.4, 19]

## 5. Suggested implementation sequence

These are dependency-ordered milestones, not time estimates. Existing gates remain active throughout.

| Milestone | Work | Evidence needed to close it |
|---|---|---|
| M0 — Compatibility and release contract | Freeze the additive tool profile, naming, entrypoint, threat model, guarantees, failure envelope, and artifact/schema compatibility policy. Reconcile examples with current syntax. | Existing handler examples still pass; normative tool examples have explicit expected acceptance or rejection. |
| M1 — One real bounded tool | Canonical boundary representation; generated handler, HAL-FORMS, JSON Schema and validators; one pure reference tool. | Unicode, null, unknown/missing fields, union tags, numeric limits, oversized payloads and malformed outputs have cross-projection tests. |
| M2 — One real scoped upstream | Structured HTTP adapter on the current capability seam; runtime-bound credentials; observation subject scope; sequential static composition. | Wrong tenant/subject/route denied before send; redirect and header attacks refused; no credential appears in tool values, failures or logs. |
| M3 — Bounded invocation | Finite deadlines, byte limits, native-work metering, arena accounting, route-call counts and atomic observation reservations; explicit platform errors. | Boundary and overflow tests; no over-budget external call; concurrent invocations cannot spend the same remaining observation budget. |
| M4 — Flow and replay | Conservative provenance/control rules, explicit release policy, protected invocation transcripts and offline replay for supported capabilities. | Secret-dependent failure/branch leakage cases refused; input endorsement does not erase subject choice; replay performs zero live external calls and checks call identity/arguments. |
| M5 — Artifact and developer integration | New evidence accepted through the current checker; generated descriptions in the existing resource path; tool-aware expert diagnostics; deployment fixtures. | Tampered bytecode, schema, capability, route, policy or summary bindings are rejected; existing deployment/runtime lifecycle tests remain green; end-to-end agent invocation uses only advertised forms. |

A useful end-to-end reference set is one pure bounded transformation, one observation-scoped authenticated lookup, and one statically composed tool. Add one explicitly approved external write only with a test of ambiguous outcome and no automatic retry.

The existing roadmap's deadline, shutdown, panic-isolation and engine/runtime facade work should be triaged against this serving path before adding a second scheduler or VM pool. Do not turn every historical backlog item into a v1.0 blocker; prioritize defects that undermine the selected deployment contract. [R2]

## 6. Proposed v1.x workstreams

Version labels below express preferred order, not promised dates or a requirement to implement every feature.

| Release/track | Scope | Entry and exit gates |
|---|---|---|
| v1.1 — Richer authored contracts and state | Named dimensions and symbolic costs where fixed bounds prove wasteful; finer field/route flow summaries; labelled transactional KV; richer offline replay. | Measure rejected useful programs and budget waste first. KV requires atomic commit, read-your-writes, isolation/conflict behavior and no label laundering. Cost claims need checked arithmetic and native-operation coverage. |
| v1.2 — Runtime-constructed tools | Part B: typed plan resources, bounded verifier, manifest-bound certificates, sequential interpreter, then promotion to authored tools. | Accepted tool summaries, exact plan/Result typing, internal/public boundary distinction, canonical hashing and cost/flow semantics must already exist. Require differential/reference-model tests, invalid-plan corpus and effect-order semantics. |
| v1.3 — Isolated execution option | Generic microVM adapter and the development/CI path; image construction and explicit host/guest capability boundary. | Run the same contract-conformance corpus; measure cold/warm latency, memory, lifecycle reliability and density. Do not describe ordinary microVM isolation as confidentiality from the operator. |
| v1.4 — Confidential execution option | libkrun-sev/SEV-SNP, broker integration, rootfs integrity, measurement-bound keys/certificates and observation assignment. | Prove broker compatibility, image/digest binding, guest-validated observation identity, credential release scope, key rotation/expiry/revocation and broker-failure behavior on target hardware. Separate this deployment edition from the core language release. |
| Demand-driven policy track | Purpose lattice, aggregation predicates and disclosure ledger. | A concrete deployment defines purpose authorities, subject identity, ledger lifetime and reset semantics. A ledger for one observation must not be represented as preventing aggregation across new observations or external model memory. |
| Measurement-driven research | Work-stealing scheduling, per-tool Wasm/protection keys, native tool codegen, unikernel, reflection and specialization. | Promote only against a measured workload or a required threat boundary. Bounded worker concurrency and specified effects come before work stealing. These are not precommitted releases. |

Part C already records unresolved broker compatibility, rootfs binding, hardware/firmware support and key lifecycle questions. Treat that section as a separate engineering validation program, not ordinary packaging work. The public libkrun attestation walkthrough demonstrates a broker flow but does not verify this draft's complete deployment design. [S §32; W2]

### Part B gates that must not disappear when deferred

Before admitting model-authored plans, define and test:

- Raw input byte/depth limits, type-width limits, origin-set size limits and checked arithmetic, in addition to `P_max`, `D_max`, `I_max`.
- Types for Result-producing calls, brand-constructor failure, map/filter/fold body parameters, accumulator compatibility, exhaustive match and unwrap/default behavior. Do not trust a node's declared type.
- Control and cardinality dependencies for every node kind; effects in iterations and selected arms; explicit effect ordering rather than assuming arbitrary node IDs preserve source order.
- The distinction between a tool's internal labelled result and a model-visible release.
- Dynamic journal addressing, no live I/O during replay, and incomplete/unknown external effect outcomes.
- All certificate identities needed for acceptance: plan normalization, executable/manifest, boundary schema, policy, cost-table/version and verifier semantics. Future attestation evidence must be additive, not a replacement for semantic checking.

A fixed finite plan grammar can still have an expensive parser or verifier when embedded constants, type trees, origin sets or arithmetic intermediates are unbounded. Do not use 'eleven node kinds' or 'a few hundred lines' as an acceptance criterion. Use measurable worst-case bounds and adversarial tests.

## 7. Section-by-section disposition of Draft v0.6

| Section | Proposed disposition |
|---|---|
| 1. Scope and method | v1.0 core, with existing handler generation and an explicit narrower guarantee set. |
| 2. Invariants preserved | v1.0 tool-profile restrictions; do not impose them retroactively on ordinary handlers. Correct pure/effect terminology. |
| 3. Tool shape | v1.0; align syntax, effects and entrypoint; define platform failures separately. |
| 4. Boundary grammar | v1.0 fixed bounds; named dimensions in v1.1. Add explicit null/Unicode/numeric/decoding rules. |
| 5. Capability imports | v1.0 semantics on current registry; calculate effective transitive authority. |
| 5.1. Secrets as operations | v1.0 for bound credentials; raw-secret escape hatch deferred. |
| 5.2. Routes | v1.0, with subject authorization and conservative redirect behavior. |
| 6. Derived artifacts | v1.0 validators/descriptors/authority/routes/basic limits/flow facts; advanced proof claims staged. |
| 7. Composition and parallelism | v1.0 authored sequential composition; state transactions in v1.1; automatic scheduling later. |
| 8. Cost contract | v1.0 hard limits and defensible fixed maxima; symbolic/full static accounting in v1.1. |
| 9.1–9.4. Labels, propagation, sinks, policy | v1.0 conservative admitted subset; refine field precision later without weakening existing denials. |
| 9.5. Endorsement | v1.0, but endorsement does not erase attacker choice or grant subject access. |
| 9.6. Declassification | Deferred; require independent provenance/endorsement and reviewed release contracts. |
| 9.7. Flow artifact | v1.0 versioned subset with explicit evidence grade. |
| 9.8. Purpose | Demand-driven v1.x policy track; not a core v1.0 gate. |
| 10. Static-contract test | Retain; correct determinism and the claim that arbitrary refinement checking costs one step. |
| 11. Restrictions | Publish a profile-local admitted restriction set; do not copy numeric identifiers over the existing rule registry. |
| 12. Compiler pipeline | Integrate into current frontend/contracts/bytecode/acceptance path; no parallel pipeline. |
| 13. Worked example | v1.0 compile-tested golden example with explicit Result handling. |
| 14. Runtime construction problem | Context for v1.2; do not confuse development-time agent source generation with production runtime compilation. |
| 15. Plan composition | v1.2, after composable accepted summaries exist. |
| 16. Plan grammar | v1.2; precisely define each admitted node's semantics. |
| 17. Plan typing | v1.2; inferred/verified node types, not trusted annotations. |
| 18. Plan cost | v1.2; parser/type/origin bounds and checked arithmetic as well as iteration caps. |
| 19. Plan flow | v1.2; fix internal-return versus public-disclosure inconsistency first. |
| 20. Verification | v1.2; bounded reference model and adversarial tests are prerequisites, not later research. |
| 21. Certificate | Existing artifact acceptance in v1.0; plan certificate in v1.2; hardware evidence in confidential track. |
| 22. Execution/replay | v1.0 bounded invocation transcript/offline replay; plan replay in v1.2; recovery guarantees separate. |
| 23. Lifecycle | v1.2 registration/invocation; promotion after real usage justifies it. |
| 24. TCB | v1.0 explicitly states actual current trust boundary; expand only with enabled deployment features. |
| 25. Reflective calculus | Research only; not required for plans or v1.0. |
| 26. Target policy | Replace mandatory confidential first release with current deployment for core v1.0, explicitly changing the threat model. |
| 27. Performance claims | Keep claims conditional and measurement-backed; do not select a backend from generic ratios. |
| 28. Attested microVM | Separate v1.4/Confidential engineering track, with generic isolation evaluated first. |
| 29. Enforcement map | Maintain separate actual-v1.0 and proposed-future tables. Never imply unavailable enforcement. |
| 30. Portability constraints | Preserve value-only boundaries and explicit capabilities now. Apply vsock requirements only to the future VM adapter. |
| 31. Sequencing | Add authored-tools/core-release stages before mandatory VM work. |
| 32. Open questions | Promote minimal subject scope, failure/boundary semantics and evidence checks to v1.0. Make verifier modeling a v1.2 prerequisite. Leave broker/purpose/research questions with their respective tracks. |

## 8. Definition of done for core v1.0

A release candidate is ready only when the following complete path is demonstrated using the packaged artifact:

**author tool → compile/check → generate contract and form → consumer acceptance → authenticate observation → validate and reserve → execute approved bounded capabilities → validate/release result → replay offline**

The negative path is equally important: incorrect subject, forged nominal value, oversized upstream response, malformed result, exhausted budget, secret-dependent Failure, widened transitive capability, changed policy and tampered artifact each fail closed at the documented boundary.

Do not gate this release on a runtime plan language, a purpose lattice, a broker, a VM pool, a new code generator, or a work-stealing scheduler. Do gate it on the truth of the smaller promises it actually makes.

## Sources

**[S] Supplied specification:** `zigts-tools-extension-v0_6.md`, Draft v0.6. Section references above refer to that unmodified attachment.

All repository links below are pinned to the reviewed commit.

- **[R1] README:** https://github.com/srdjan/zttp/blob/de81726d753f229e6e47ecb78a7b1a14d75fa8de/README.md
- **[R2] Roadmap:** https://github.com/srdjan/zttp/blob/de81726d753f229e6e47ecb78a7b1a14d75fa8de/docs/roadmap.md
- **[R3] Strategy:** https://github.com/srdjan/zttp/blob/de81726d753f229e6e47ecb78a7b1a14d75fa8de/STRATEGY.md
- **[R4] Architecture:** https://github.com/srdjan/zttp/blob/de81726d753f229e6e47ecb78a7b1a14d75fa8de/docs/internals/architecture.md
- **[R5] Contracts and sandboxing:** https://github.com/srdjan/zttp/blob/de81726d753f229e6e47ecb78a7b1a14d75fa8de/docs/contracts-and-sandboxing.md
- **[R6] TypeScript support:** https://github.com/srdjan/zttp/blob/de81726d753f229e6e47ecb78a7b1a14d75fa8de/docs/typescript.md
- **[R7] Flow checker source:** https://github.com/srdjan/zttp/blob/de81726d753f229e6e47ecb78a7b1a14d75fa8de/packages/zts/src/flow_checker.zig
- **[R8] HTTP runtime source:** https://github.com/srdjan/zttp/blob/de81726d753f229e6e47ecb78a7b1a14d75fa8de/packages/runtime/src/runtime_http.zig
- **[R9] Consumer checker policy:** https://github.com/srdjan/zttp/blob/de81726d753f229e6e47ecb78a7b1a14d75fa8de/packages/proof-checker/src/policy.zig
- **[W1] JSON Schema validation, string length:** https://json-schema.org/draft/2020-12/json-schema-validation#section-6.3.1
- **[W2] VirTEE libkrun/SEV-SNP attestation walkthrough:** https://virtee.io/attestable-confidential-workloads-libkrun/

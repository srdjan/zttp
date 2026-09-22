# M4: release contract for scoped tool routes

Status: accepted by the owner on 2026-09-22. T1 is in progress.
Baseline: local `main` at `176d81ca`. Roadmap row:
[M4 in the roadmap](../roadmap.md) (`docs/roadmap.md:20`). This document
reconciles proposal A, the
[agent-handler specification](2026-09-19-feat-agent-handler-spec.md), with
proposal B, the
[tool-profile recommendation](../zttp-next/zttp-v1.0-scope-and-v1x-roadmap.md).
The owner accepted this text on 2026-09-22, which authorizes T1 to T7 in order.

## Status and decision record

The product owner accepted three decisions on 2026-09-22.

1. **Scope is the reconciled subset.** M4 delivers one shared tool catalog with
   one canonical schema, per-call subject and tenant scope that no model or caller
   field can set, runtime-bound credential injection that tool code never sees,
   and artifact binding of the catalog through the existing proof checker. No
   second checker is added. Each tool is a buffered ordinary handler route, which
   is B's delivery shape (`B:39-41`). A's streaming, in-handler dispatcher, model
   loop, turn recorder, and stream proof profile are parked as the next boundary.
2. **Threat model.** The model and the caller are untrusted. The operator and the
   host are trusted. M4 makes no claim of confidentiality from the host.
   Confidential execution stays on B's separate v1.4 track (`B:164`).
3. **The tool profile is a profile of the consumer contract.** It uses the same
   declaration and the same vocabulary envelope as
   [the consumer contract](../consumer-contract.md). It is not a separate
   surface. For this reason, producer obligation P9 is a named M4 dependency.

On the same day the owner accepted three more decisions, which answer the open
questions of the first draft.

4. **Identity source.** The runtime verifies an HS256 bearer JWT with a
   deployment-owned key before the handler runs. The `sub` claim sets the
   subject, and a claim that the deployment configuration names sets the tenant.
   The runtime injects both into the call, and the handler cannot read the raw
   claims. The verifier core already exists and refuses an unexpected `alg`
   (`packages/modules/src/security/auth.zig:122-127`, `:299`). It supports HS256
   only (`auth.zig:46-48`), so the issuer and the deployment share one secret.
   M4 accepts this limit and has one identity source. Asymmetric keys and OIDC
   discovery are later work.
5. **Catalog carriage.** The catalog enters the executable graph as a new member
   kind, `tool_catalog = 19`, not inside `contract_bytes = 7`. This follows
   `residual_plan = 16`, which is committed separately so that a mutated plan
   names itself (`packages/proof-checker/src/executable_graph.zig:52-55`), and
   `invariant_spec = 17` (`:57`).
6. **Stored-data tools.** Under the tool profile, the build refuses a tool route
   that reaches a cross-call read: `zttp:cache` reads, `zttp:sql`, `zttp:queue`
   receive, or a durable signal wait. Ordinary handlers are not affected. Such
   tools return with the recipient-scoped release operation of `A:642`, as part
   of the next boundary.

In this document, "A:n" and "B:n" are line references into the two proposals.
B's milestone labels M0 to M5 (`B:142-149`) are local to B. They are not the
roadmap M-series, and this document always writes them as "B-M0" to "B-M5".

## Scope

M4 is one release boundary: a developer publishes a typed tool as an ordinary
handler route, the compiler derives its catalog entry, the artifact binds that
entry, and the runtime scopes, credentials, and bounds each call. The unit of
delivery is a complete buffered response. `HttpResponse` owns one complete body
slice (`packages/runtime/src/http_types.zig:75-79`), so M4 needs no new response
variant.

| Source label | Disposition in M4 |
|---|---|
| A U1, catalog and invocation contract (`A:540`) | In, without stream callbacks. The catalog, strict schema subset, tool-local grants, and artifact binding are M4 work. |
| A U3, credential part only (`A:447-451`, `A:542`) | In. Deployment-owned credential resolution and injection after exact-request authorization, and redirect refusal. Incremental chunk delivery stays parked. |
| A U2, U3 streaming part, U4, U5 (`A:541-544`) | Parked. See "Parked work". |
| B-M0, compatibility and release contract | In. This document is the release contract. The compatibility policy is part of T2 and T3 below. |
| B-M1, one real bounded tool | In, except the HAL-FORMS projection, which the accepted decisions do not name. |
| B-M2, one real scoped upstream | In, except sequential static composition of tools, which the decisions do not name. |
| B-M3, bounded invocation | Partly in. Finite outbound deadlines only. Metering, arena accounting, and atomic observation reservations are parked. |
| B-M4, flow and replay | Out, except declared-label carriage (P9), which decision 3 makes a dependency. Replay and control-dependency rules are parked. |
| B-M5, artifact and developer integration | Partly in. Acceptance through the current checker is in. Tool-aware expert diagnostics and deployment fixtures are parked. |
| B v1.1 to v1.4 and the policy tracks (`B:159-166`) | Out. |

Also out: a tool that reaches a read of cross-call state (cache, SQL, queue,
durable signal). Such reads carry `.unknown` provenance (`A:70`), so no tool that
uses one can reach a proven `no_secret_leakage` verdict. Decision 6 makes the
build refuse it.

## Threat model

The adversary is an untrusted model or caller that supplies inputs to reviewed
tools (`B:33`). Model output, the request body, headers, query, and all content
that an upstream service returns are untrusted data. No such value can select a
tool that the catalog does not hold, set the subject or tenant, widen a grant,
choose a credential, or change an outbound destination.

The trusted set is the operator, the host, the compiler, the acceptance kernel,
the runtime, the reviewed native modules, the deployment configuration, and the
identity source that authenticates the caller. A deployed invocation compiles no
model-supplied source (`B:41`), so M4 runs no untrusted code.

M4 does not claim confidentiality from the host, isolation of untrusted code,
per-tool native-memory isolation (`B:31`), prompt-injection immunity, answer
accuracy, or exactly-once external execution (`A:212-214`). A signature
establishes provenance, not semantic correctness (`B:130`). Existing assurance
grades stay as disclosed: `results_checked`, `no_secret_leakage`, and
`capability_bounded` enter at `tested` (`docs/roadmap.md:67-71`), and M4 does
not raise them.

## Dependencies

| Dependency | Why M4 needs it | Current state |
|---|---|---|
| P9, declared-label carriage (`docs/consumer-contract.md:721-727`) | A tool that wraps an upstream must enforce declared classifications on the upstream response. Decision 3 makes this the tool profile's label path. | Not wired. `parseExternalLabels` (`packages/zts/src/flow_checker.zig:206`) and `setExternalLabels` (`:814`) have no caller outside that file. `--data-labels` reaches `precompile_args.zig:118-119` and the build report boolean (`packages/tools/src/report.zig:102`), not the checker. |
| P8, classification match report (`docs/consumer-contract.md:709-720`) | P9 without P8 reports success for a declared field the analysis never saw. The contract binds them together (`:616`). | Not implemented. |
| P4, canonical declaration encoding (`docs/consumer-contract.md:695-702`) | The catalog is a section of the declaration and binds by digest. P8 and P9 cannot be tested before P4 lands (`:374-377`). | Not implemented. The pattern exists: `invariant_spec = 17` (`packages/proof-checker/src/executable_graph.zig:57`). |
| P15, capability ceiling enforcement (`docs/consumer-contract.md:761-765`) | Tool-local grants are a declared ceiling narrowed per tool. A bound ceiling that nothing enforces restricts nothing. | Not implemented. The `adapter` profile is published (`docs/consumer-contract.md:264`). |
| Zero outbound timeout | B requires finite deadlines (`B:86`). | Open. `outbound_timeout_ms == 0` selects `.none` (`packages/runtime/src/runtime_http.zig:2001`). The default is 10000 (`packages/runtime/src/runtime_config.zig:43`), and the CLI accepts 0 (`packages/runtime/src/runtime_cli.zig:693`). |
| Consumer contract v1 acceptance (`docs/roadmap.md:312`) | Decision 3 puts M4 inside that contract, whose status is "Proposed". | Pending. Owner acceptance of this text accepts P4, P8, P9, and P15 for M4. |

P1, the vocabulary envelope, is met. The envelope is
[consumer-contract-envelope.json](../consumer-contract-envelope.json), derived
from `packages/tools/src/vocab_envelope.zig`, and the gate is
`zig build test-vocab-envelope-drift` (`build.zig:338`). The contract text still
says the envelope does not exist (`docs/consumer-contract.md:48-50`, `:466-467`).
That text is stale; its correction is separate work. If T3 adds an executable-graph
member kind, the published member-kind count changes and T3 must regenerate the
envelope.

Roadmap runtime rows (`docs/roadmap.md:81-90`), as `:78-79` requires: none is an
M4 dependency. Computed SQL guards stay deferred because M4 admits no SQL-backed
leakage claim. Certificate assurance is not needed because M4 claims no new
grade. The "Module gaps" row (`:85`) now has its concrete case: the zero-timeout
fix above. Runtime lifecycle, engine facade, hosted deploy, server rate limiting,
and ledger startup cost are not needed.

B's baseline `de81726d` is now an ancestor of local `main` (checked with
`git merge-base --is-ancestor`), so the divergence note at `B:22-23` no longer
holds. B's code claims need a recheck against local `main`, not a divergence
resolution. This document rechecked only the zero-timeout claim. B's other code
citations need verification before the unit that uses them starts.

## Delivery units

The units are ordered. A unit starts only after the units it depends on are
committed. Unit labels T1 to T7 are local to this document. File lists are the
known owners; a unit that needs another file names it in its commit.

**T1. Finite outbound deadlines.** Depends on nothing. Owned files:
`packages/runtime/src/runtime_http.zig`, `runtime_config.zig`, `runtime_cli.zig`,
and `edge_server.zig` (`:711` parses the same field). A tool-profile artifact
must refuse to start with a zero or absent outbound deadline. Whether ordinary
handlers keep the zero path is a T1 design choice that the commit states.
Completion: check C1.

**T2. Canonical catalog and schema subset.** Depends on nothing. Owned files:
`packages/zts/src/contract_builder.zig`, `contract_types.zig` (`ApiSchemaInfo` at
`:307`), `contract_json_writer.zig`, `contract_json_parser.zig`, and either
`packages/modules/src/security/validate.zig` or a named new catalog validator.
One catalog entry per tool route carries its name, description, bounded input and
output schemas, and reachable module exports (`A:252-255`). It rejects duplicate
names, dynamic schemas, unknown fields, and duplicate JSON keys before object
construction (`A:268-280`). Completion: check C2.

**T3. Declaration encoding and artifact binding.** Depends on T2. Owned files:
a declaration loader under `packages/tools/src/` that follows
`invariant_config.zig`, `packages/proof-checker/src/executable_graph.zig`, the
checker, `packages/runtime/src/contract_runtime.zig`, and the envelope source.
This unit meets P4 for the sections M4 uses. It adds `tool_catalog = 19` to
`MemberKind` and `fromWire`, with a producer that emits it, and regenerates the
envelope (decision 5). The runtime lowers the catalog from
the accepted artifact, not from producer output. A search of
`contract_runtime.zig` finds no tool catalog today. Completion: check C3.

**T4. Declared-label carriage.** Depends on T3. Owned files:
`packages/zts/src/flow_checker.zig`, `packages/tools/src/precompile.zig`, and the
compile-options carrier (its file needs verification). This unit meets P8 and P9,
including the three conditions at `docs/consumer-contract.md:724-727`.
Completion: check C4.

**T5. Subject scope and tool-local grants.** Depends on T3. Owned files:
`packages/zts/src/handler_policy.zig`, `module_authorization.zig`, and the
runtime dispatch path in `contract_runtime.zig`, plus a runtime caller of the
`auth.zig` verifier core. The runtime verifies the bearer JWT and sets subject
and tenant from its claims (decision 4). Each tool route receives only its own
grants, and the build refuses a tool route that reaches a cross-call read
(decision 6). This unit meets P15. Completion: check C5.

**T6. Credential injection.** Depends on T1 and T5. Owned files:
`packages/runtime/src/runtime_http.zig`, `packages/modules/src/net/fetch.zig` and
its module spec, and `runtime_config.zig`. The runtime resolves a
deployment-owned secret reference and injects it only after it authorizes the
exact request. Redirects stay unhandled (`runtime_http.zig:2044`) and never carry
it. A search of `packages/runtime/src` and `packages/modules/src` finds no
resolver or injection step today, as `A:78-79` also records. Completion: check C6.

**T7. Reference tools and documentation.** Depends on T1 to T6. Owned files: a
new directory under `examples/`, its entry in the example suite, and
`docs/user-guide.md`. It holds one pure bounded tool and one scoped,
credentialed upstream lookup (`B:151`). Completion: check C7.

## Completion checks

Every verdict comes from an unfiltered build step with its exit status read
directly, never through a pipe and never from a `-Dtest-filter` run
([AGENTS.md](../../AGENTS.md)). Each gate asserts a floor on its input. A new
gate is shown non-vacuous by a delete-input probe and by mutation of a copy of
its declared inputs, and a verdict enum it reports gets a per-verdict census.
Restore each mutation byte for byte before the next probe.

| Check | Gate or step | Positive case | Negative case | Non-vacuity |
|---|---|---|---|---|
| C1 (T1) | `test-server`, `test-zruntime` | A tool route with a finite deadline answers | Deadline 0 under the tool profile refuses startup; a stalled upstream ends at the deadline | Restore the `.none` branch at `runtime_http.zig:2001`; the new test must fail |
| C2 (T2) | `test-zts`, `test-modules`, `test-precompile`, `test-contract-golden` | AE21 valid bounded input; schema bytes and validator agree after round trip | AE21 rejections; AE5 duplicate keys and invalid JSON (non-stream part); B8.2; B8.4 | Remove the duplicate-key check and the closed-field check in turn; each must fail a test. Census over every refusal reason |
| C3 (T3) | `test-proof-checker`, `test-proof-checker-purity`, `test-zruntime`, `test-vocab-envelope-drift` | An accepted artifact serves its catalog | AE11; B8.8; B8.9 | Mutate one catalog byte in a copy of an accepted artifact; acceptance must refuse. Delete the catalog member; the gate must fail, not pass |
| C4 (T4) | `test-zts`, `test-precompile`, `test-proof-swallow` | A clean value through the same path stays admissible | AE4, asserting `no_secret_leakage` and not a neighbor; AE18 negative cases; AE19; whole-object forwarding, short-name match, and a malformed entry are refused | Return a labelled value directly and confirm refusal, then route it through each export (AGENTS.md method). Empty label file must fail |
| C5 (T5) | `test-zruntime`, `test-capability-audit`, `test-module-boundary` | The trusted subject reads its own resource | AE2; AE3; AE15; B8.1; B8.7; missing policy or identity denies; a bad signature, an unexpected `alg`, or a missing `sub` denies; a tool route that calls a `zttp:cache` read is refused at build | Remove the scope comparison; AE3 must fail. Remove the cross-call refusal; the cache case must fail. Census over each denial reason |
| C6 (T6) | `test-zruntime`, `test-modules`, `test-runtime-purity` | AE17 authorized request carries the credential | AE17 refusals; B8.3; AE6 no-retry half; no credential in values, failures, or logs | Inject before authorization in a probe build; AE17 must fail |
| C7 (T7) | `zig build test`, then `bash scripts/verify.sh` | B's path from author to accepted, scoped, bounded call (`B:230`), without replay | Every applicable B8 case at its documented boundary | The example suite must run the new example; the suite floor at `scripts/test-examples.sh:374` counts suites, not this one, so a probe that breaks the new example must also fail the step |

B's section 8 negative cases have no numbers in B (`B:232`). This document
numbers them in order: B8.1 incorrect subject, B8.2 forged nominal value, B8.3
oversized upstream response, B8.4 malformed result, B8.5 exhausted budget, B8.6
secret-dependent Failure, B8.7 widened transitive capability, B8.8 changed
policy, B8.9 tampered artifact. B8.5 and B8.6 are deferred with B-M3 and B-M4.
B's offline replay step is deferred.

From A's examples (`A:566-588`), M4 applies AE2, AE3, AE4, AE11, AE15, AE17,
AE19, AE21, the non-stream part of AE5, the negative cases of AE18, and the
no-retry half of AE6. AE1, AE7, AE8, AE9, AE10, AE12, AE13, AE14, AE16, AE20,
and the stream and live-dedup parts of AE5 and AE6 are deferred with the parked
work. AE10's single-route budget part is deferred with B-M3.

## Parked work and conditions to resume

Parked: A's U2 (response stream ownership and the turn recorder), U3 incremental
transport, U4 buffered reference agent, and U5 streamed agent and stream proof
profile (`A:541-544`); B-M3 metering and reservations; B-M4 flow, release policy,
and replay; B-M5 expert diagnostics; the HAL-FORMS projection; and sequential
static composition.

The streaming work resumes as the next release boundary only when all of these
hold. M4 is complete under the checks above. The resumed work consumes the T2
catalog and the T3 binding and defines no second catalog, schema, or dispatch
table. A's open decisions for the stream API, the stream proof profile, the first
provider adapter, and deployment limits (`A:639-644`) have recorded answers.
Deployment limits come from measurement, not estimates. A new release contract
states the resumed scope.

## Open questions

None. Decisions 4 to 6 answer the three questions of the first draft.

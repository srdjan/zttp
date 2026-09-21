---
title: Custom LLM Agent Handlers - Specification
type: feat
date: 2026-09-19
last_reviewed: 2026-09-20
product_contract_source: user-request
status: proposed
---

# Custom LLM Agent Handlers - Specification

## Summary

Let an application expose a custom LLM agent through a ZTTP handler. A client
submits a prompt and receives incremental response events. The model can request
only the tools published by that handler. ZTTP validates each request and executes
only a statically bound operation backed by approved built-in modules.

This is a proposed enhancement, not a description of shipped behavior. The user
requirements are streaming responses, ZTTP modules as the only tool authority, and
rejection of all other execution requests. The contracts below specify the
proposed first release. They do not authorize implementation or change the
project's release roadmap.

---

## Goal Capsule

An application developer can serve a useful agent whose external actions stay
within an explicit, reviewable set of permissions. A client can observe progress,
receive partial text, and distinguish completion from interruption or failure.

The model proposes actions. The deployed handler and runtime own execution
authority. A tool catalog, model instruction, or schema alone is not permission.
The trusted boundary includes the accepted application, compiler and checker,
native modules, deployment operator, and authentication system. Model output,
client input, and remote tool content are untrusted data.

The work is complete only when both provider input and client output stream
incrementally through the ordinary handler path. A buffered agent is an internal
delivery milestone, not completion of this enhancement.

---

## Current Baseline

Revalidated on 2026-09-20 against committed local `main` at `e223381e`.
The original source baseline was `2d57147b`.
The feature scope and requirement IDs are unchanged. Streaming responses,
incremental handler fetch, the agent tool catalog, and the turn recorder remain
new work. The main changes since the original baseline are stricter provenance
analysis, exhaustive return analysis, and broader verification gates.

This refresh used source and history inspection. It claims no new runtime
measurements or test results. The 2026-09-21 backlog review checked one later
dependency change: the schema writer and development-agent refactors are now
committed, with completion evidence in the bounded rederive record. Recheck
these paths before implementation.

| Existing surface | Consequence for this enhancement |
| --- | --- |
| `packages/runtime/src/http_types.zig`, `HttpResponse` | A response owns one complete byte slice. It has no stream producer. |
| `packages/runtime/src/server_response.zig`, `buildDynamicResponseHeader` | Ordinary responses use the complete body length for framing. An SSE content type alone cannot produce streaming. |
| `packages/runtime/src/runtime_http.zig`, `readResponseBody` and `fetchSyncResult` | Outbound fetch reads the entire body before constructing a JS response. |
| `packages/runtime/src/studio.zig` and the Studio branch in `server.zig` | Studio has a separate SSE socket path. It is not a public handler stream API. |
| `packages/runtime/src/runtime_pool.zig`, borrowed response handles | Response lifetime retains an isolated runtime. A stream needs an explicit ownership and capacity contract. |
| `packages/zts/src/builtin_modules.zig` | Built-in bindings and module metadata exist. The combined registry also contains extensions, so it cannot define the agent allowlist unchanged. |
| `packages/zts/src/handler_policy.zig`, `RuntimePolicy` and `contractToRuntimePolicy` | The projection enables restrictions and denies dynamic sections without configured grants. A default policy object still has disabled allowlists; dispatch must require the projected and installed generation. |
| `scripts/check-runtime-purity.sh` | The runtime template and analyzer must not link the development agent or its provider clients. The gate now checks every provider family and requires the server boundary input to exist. |
| `packages/modules/src/data/cache.zig`, `packages/modules/src/data/sql.zig`, and the queue/durable bindings | Reads of cross-call stored values now carry `.unknown` provenance. These reads do not establish that the result is safe to disclose. |
| `packages/zttp-sdk/src/binding.zig`, `packages/zts/src/module_binding/types.zig`, and `packages/zts/src/flow_checker.zig` | Identity returns must preserve argument labels. Bounded declassification applies only with literal bounds or supported defaults; other calls retain their input labels. These constraints also apply to new tool and stream bindings. |
| `packages/zts/src/handler_verifier.zig`, `functionAlwaysReturns` | Return analysis is exhaustive over IR tags. A new deferred producer path needs explicit analysis; a response handle does not prove producer completion. |
| `build.zig` and `docs/internals/testing.md` | Example suites now run under the aggregate test step. Diagnostic producers, script reachability, and build-step coverage have separate gates. `test-zruntime` remains standalone. |

The core response, fetch, pool, and Studio streaming surfaces are unchanged from
the original baseline. Fetch already enforces endpoint and resolved-address
restrictions, byte limits, and an exchange deadline, and does not follow redirects.
It still accepts handler-provided headers and has no deployment-owned credential
resolver or injection step.

Existing recorders also do not supply the proposed turn contract.
`packages/runtime/src/trace_request_recorder.zig` captures request/response data
without per-effect acknowledgement; `packages/runtime/src/security_logger.zig`
uses best-effort writes; `packages/runtime/src/proof_audit_ring.zig` records cache
and route decisions. U2 still needs an acknowledged, bounded turn recorder.

The language does not expose general JavaScript async execution. This feature
must fit the admitted language and native callback model. It must not silently
depend on promises, `async` functions, or browser `ReadableStream` support.

`ContractBuilder` and `TypeChecker` now use `ir_json_literal.zig`, delivered in
`6be705a6` and verified in the
[bounded rederive record](../archive/plans/2026-09-20-rederive-implementation-plan.md).
U1 must preserve the existing schema-byte and inferred-type contracts when it
uses that writer.

`ApiSchemaInfo` currently records a name and schema JSON. Contract JSON carries
those schemas, but `packages/runtime/src/contract_runtime.zig` does not carry a
tool catalog or its argument/result validators. U1 must implement that transfer
and acceptance path; serialized API documentation is not executable tool authority.

---

## Product Contract

### Scope

The first release supports one authenticated HTTP request per agent turn,
incremental text, sequential tool execution, and a final success or failure event.
The application owns its prompt, provider adapter, model selection, and selected
tool catalog. Deployment configuration bounds each of these choices.
Client prompt ingress remains a complete bounded JSON body. Streaming in this
release means provider-to-handler input and handler-to-client output.

Persistent conversation storage, automatic reconnection, crash recovery, parallel
tool execution, background jobs, model-generated programs, dynamic tool loading,
third-party tool servers, and provider-hosted tools are deferred. Existing
ordinary handlers retain their current behavior.

The reference application starts with read-only tools. Mutating tools are allowed
by the contract only when their authorization and retry behavior are explicit.
There is no general approval workflow in the first release. An operation that
needs additional approval is unavailable unless the application already has a
trusted way to establish that approval.

### Requirements

#### Request and response

R1. An agent endpoint accepts a bounded JSON prompt request through POST. The
application chooses the route and authenticates the request before any model call.
The version 1 body has exactly `version: 1` and a non-empty `prompt` string.
It accepts no client-supplied tool transcript, model name, provider URL, or grants.

R2. Each request uses a server-created turn identity and trusted invocation
context. Client or model fields cannot set the principal, tenant, policy, or budget.

R3. The response uses versioned SSE events over the POST response. Clients consume
the response stream directly; browser EventSource reconnection is not required.

R4. Text must reach the client before the provider finishes the response. Tool
arguments remain private until fully assembled and validated.

R5. Every accepted stream has one logical terminal outcome. A disconnected client
may miss that event, so the server also records the outcome.

#### Tool identity and dispatch

R6. Each deployed agent has a finite tool catalog fixed at build time. Each public
tool name binds to a reviewed wrapper whose effectful calls reach only the selected
built-in ZTTP exports.

R7. One canonical catalog produces the model tool definitions and dispatch
bindings. Descriptions, argument schemas, result schemas, operation identities,
and resource constraints belong to that catalog.

R8. The runtime rejects unknown tools, duplicate call identities, invalid JSON,
duplicate object keys, unknown fields, and arguments outside the declared schema.
It must not coerce malformed arguments into an executable request.

R9. Tools execute only after the provider has completed a valid tool-call round.
All calls in that round pass structural validation and authorization before the
first call starts.
Authorization and remaining budgets are checked again before each execution.

R10. No model output can select source code, a module import, a native symbol, a
shell command, or an arbitrary callable. A generic evaluation or registry lookup
tool is outside the supported profile.

#### Permissions and information flow

R11. A tool call must satisfy the catalog grant, accepted Handler Contract,
installed runtime policy, residual resource guards, and current user scope.
Missing policy or missing identity denies execution.

R12. Tool wrappers bind resource scope from trusted context where possible. A
schema-valid identifier is still subject to authorization for the named resource.

R13. Provider credentials remain outside prompts, tool results, client events,
and ordinary logs. Model tools cannot read credentials or change provider endpoints.

R14. Data sent to the model, client, or another service must pass the application
release policy for that recipient. Successful schema validation does not remove
secret labels or authorize disclosure.

R15. Prompts, conversation text, and tool results cannot grant permissions.
Instructions found in external content remain data even when the model follows them.

#### Limits and failure

R16. Deployment requires finite limits for execution, bytes, calls, and concurrent
turns. The server checks the relevant budget before starting another external effect.

R17. Disconnect, deadline expiry, capacity exhaustion, and protocol failure stop
new model requests and tool calls. Cancellation closes active transport and
releases owned resources when the active native operation has stopped.

R18. A completed side effect is not rolled back by stream cancellation. An operation
whose outcome cannot be established is reported as unknown, never as not executed.

R19. No automatic retry may repeat a tool effect. Retries require an operation
contract with downstream idempotency or established absence of the effect.

R20. Streaming capacity must not consume the capacity reserved for ordinary
requests. A saturated agent endpoint rejects admission before contacting a provider.

#### Evidence and compatibility

R21. The accepted artifact binds the tool catalog and all reachable wrappers and
stream callbacks. A mismatched catalog, policy, or executable generation cannot serve.

R22. Reports distinguish static Properties, runtime restrictions, observed events,
and unknown outcomes. No report claims to prove model intent, answer accuracy,
prompt-injection immunity, or exactly-once external execution.

R23. The deployed runtime remains independent of `packages/pi`. Existing buffered
response behavior and existing artifact acceptance checks remain available.

### Example flow

A customer submits a question about an order. The handler establishes the customer
identity and publishes `getOrder(orderId)`. The model requests that tool. The
dispatcher validates the call, and the wrapper checks ownership using the trusted
customer identity. A registered SQL query reads the permitted order. A result
projection returns only fields allowed for the model. The model then streams its
answer. An order owned by another customer produces no order data and no SQL write.
This is desired behavior, not a currently proven SQL example. A SQL result now
has unknown provenance, so this flow also depends on the stored-data release
decision below. Ownership checks and field projection alone do not discharge
`no_secret_leakage` or `no_credential_leakage`.

---

## Planning Contract

### KTD1. Keep the custom agent in application code

The reviewed handler owns the bounded model/tool loop. A provider adapter in the
application translates its protocol into normalized text, tool calls, usage, and
terminal outcomes. Native runtime additions provide generic streaming and checked
dispatch primitives. They do not embed provider clients or the development agent.
This preserves R23 and the current runtime-purity boundary.

The first reference application selects one documented provider protocol and
model through deployment configuration. The library contract stays provider
neutral. Additional adapters are not required for the first release. Provider
hosted execution features must be disabled, and unsupported action block types
must fail the adapter. Plain text that resembles a tool call is never dispatchable.

### KTD2. Bind tools statically and advertise a restricted view

A catalog entry contains a unique public name, description, bounded input and
output schemas, static wrapper binding, reachable built-in operation identities,
resource restrictions, and effect/retry classification. It also names which
result fields may go to the model and client. Credentials are not catalog values.

The model receives only names, descriptions, and input schemas for tools permitted
in the current turn. The dispatcher uses the same filtered view. The underlying
catalog is immutable; a model request cannot add a tool. Use an explicit mapping
from public names to checked bindings, not evaluation or dynamic import.

Generate basic type facts from existing module metadata. The developer supplies
resource scope, descriptions, projections, and bounds that metadata cannot infer.
Reject unsupported schema constructs at build time. The admitted schema subset
must define required versus optional fields, nullability, finite numbers, string
length units, collection bounds, nesting bounds, and closed object fields.

The existing `zttp:validate` implementation in
`packages/modules/src/security/validate.zig` rejects `additionalProperties` and
does not enforce closed objects. Its named schema registration, and the current
contract schema upsert, replace an existing name. U1 must reject duplicate catalog
and schema names, dynamic/unreadable schemas, and schemas whose declared bounds
cannot be enforced. Define the closed agent subset explicitly before choosing
whether to extend that validator or add a catalog-specific validator.

Reject duplicate argument keys before converting JSON to ordinary JS objects;
last-key-wins parsing has already lost the evidence. The strict JSON module in
`packages/zts/src/modules/data/json_mod.zig` supplies a relevant parser pattern.
Any reuse must go through the curated module boundary and retain the agent's byte
and nesting limits. Schema validation alone does not establish strict parsing.

Application wrappers can validate and compose approved built-ins. Their complete
call graph participates in ordinary effect and capability analysis. A wrapper
must not gain the union of unrelated tools' grants. Invocation enters a tool-local
scope and restores the outer scope on every exit. Provider transport has a
separate grant unavailable to tool calls.
The existing active-module capability scope covers a native export's host access;
it is not the proposed per-tool grant. Neither that scope nor a default
`RuntimePolicy{}` can substitute for the installed tool-local policy generation.

Identify each built-in operation by module specifier and export name. Reject an
export that cannot enforce the required tool-local scope. Validate the projected
result against its bounded output schema before it reaches the provider. A
projection or validation failure is a tool failure, not an empty successful result.

Preserve the current binding invariants. A pass-through return uses
`derives_from_args`; an identity return without it must fail binding validation.
A read of cross-call state uses `.unknown`, because its arguments do not describe
what an earlier writer stored. Do not copy a benign label onto either shape to
make the new catalog easier to admit.

Catalog identity must bind the dispatch targets that the serving binary actually
uses. Comparing two hashes derived only from the producer's catalog cannot detect
a different linked operation. Follow the independent native-manifest pattern in
`packages/runtime/src/invariant_adapter.zig` where it applies, while preserving
the acceptance kernel's import-free boundary. Matching identity still does not
prove that an operation enforces its declared behavior.

### KTD3. Add generic streaming without new language syntax

Introduce a response variant with a native-managed stream producer and a generic
incremental outbound HTTP interface. Public API spelling is an implementation
design task; no example in this document is claimed to compile today.

The producer executes admitted handler code after stream admission. It can receive
bounded provider chunks and emit bounded client events through native callbacks.
Callbacks execute serially within the request's isolated runtime. No other thread
may enter that runtime while a callback is active. Native I/O waits must observe
the turn deadline and cancellation token.

The response, producer, tool catalog, callback closures, and outbound handles all
belong to one accepted runtime generation. Retain the runtime and its request
arena until the producer and all native operations have stopped. A callback or
handle cannot survive arena reset. Reload affects new requests; it cannot replace
code or permissions within an active turn.

For the first release, reserve a separate bounded pool and worker capacity for
streaming turns. Mark a handler as stream-capable in its accepted artifact before
request dispatch, so the server selects this capacity before invoking the handler.
All requests to that handler use the streaming pool, including requests that
return buffered admission errors. Pool selection cannot depend on the response
variant discovered after execution. An active stream retains a runtime slot.
This is a stated cost,
not a multiplexing claim. A later scheduler may release resources during waits
only after it preserves the same lifetime and isolation contract. Separate pools
do not claim process or machine isolation.

### KTD4. Define the client protocol independently of the provider

Use an SSE envelope with `version`, `turn_id`, monotonic `sequence`, `type`, and
`data`. Schema version 1 is the initial protocol version. JSON encoding must escape
content so model text cannot inject SSE fields or frames.
Each SSE `event` field equals the envelope type; its `data` field contains the
encoded envelope. Response content type is `text/event-stream`. The turn identifier
does not grant permission to read or resume a turn.

| Event type | Meaning and data |
| --- | --- |
| `turn.started` | Admission succeeded; includes the public protocol version. |
| `text.delta` | Incremental user-facing text. It is provisional until completion. |
| `tool.started` | An authorized call is about to execute; public tool name and server-scoped call identity only. |
| `tool.finished` | Call identity and safe success/failure classification. Raw arguments and results are not included by default. |
| `turn.completed` | The provider completed normally with no unresolved tool calls; includes provider-reported usage when available. |
| `turn.failed` | Tagged error, safe message, and whether any effect outcome is unknown. |

`turn.completed` and `turn.failed` are terminal. Do not send further application
events after either. Heartbeat comments carry no model content and do not extend
the absolute deadline. A broken socket can prevent terminal delivery. EOF without
a terminal event means interrupted delivery to the client, even if the server
later records completion. Never claim that writing an event proves client receipt.

Before headers, malformed requests use 400, authentication failures use 401 or
403, oversized requests use 413, principal quotas use 429, and exhausted server
capacity uses 503. After headers, failures use `turn.failed` if the socket permits.
Do not append a second HTTP response or change the status after headers.

The stream uses correct framing for the supported HTTP transport, disables
response caching and content transformation, and requests proxy buffering be
disabled where supported. No Content-Length is derived from a partial body. Do
not claim compatibility with a proxy until the incremental-delivery test passes.
Preserve the current request-parser restrictions while adding stream admission.
Malformed field names, including whitespace before the colon in Content-Length,
must not bypass framing checks. Keep the existing distinction between malformed
method tokens and well-formed methods that the runtime does not implement.

### KTD5. Separate provider assembly from execution

```mermaid
flowchart TD
    A[Authenticate and admit request] --> B[Create isolated turn context]
    B --> C[Send prompt and permitted tool schemas]
    C --> D[Read bounded provider events]
    D --> E{Event kind}
    E -->|Text| F[Apply output policy and emit text delta]
    F --> D
    E -->|Tool fragments| G[Assemble calls without execution]
    G --> D
    E -->|Valid tool round end| H[Validate and authorize complete batch]
    H --> I[Authorize and execute each call in order]
    I --> J[Project bounded results for model]
    J --> C
    E -->|Normal final end| K[Emit completion and release]
    E -->|Error or incomplete end| L[Stop new effects and record failure]
```

Provider network chunks are not message boundaries. The adapter must preserve
UTF-8 sequences, SSE framing, and JSON fragments across arbitrary splits. It
requires an explicit provider completion signal and the matching finish reason;
EOF, output truncation, or malformed frames never authorize pending tool calls.
Reject changes to an assembled call's name or identity and any fragment received
after that call or round has closed.

If a round contains valid and invalid calls, execute none. If all calls are
structurally valid and authorized, execute sequentially in provider order. Stop
the remaining batch on an authorization failure, budget failure, cancellation,
unknown outcome, or tool failure. Earlier effects remain committed. The first release terminates
the turn on these failures; it does not ask the model to repair and retry them.

Assign call identity from turn identity, round ordinal, and the provider call ID.
Reject a duplicate provider ID within a round. A local execution record prevents
the same call from running twice within the live turn. It is not a durable dedup
record and supplies no guarantee across process restart or a new client request.

### KTD6. Bound every wait and retained value

Required configuration covers prompt bytes, provider request and response
bytes, SSE frame bytes, tool-call count, argument bytes and nesting, tool-result
bytes, retained transcript bytes, emitted bytes, queued output bytes, model rounds,
absolute turn deadline, I/O idle deadlines, native operation deadlines, and active
turns per principal and per server. Zero must not mean unlimited in the agent profile.
Limit tool calls per round and open outbound connections as well as total calls.

Check encoded sizes before allocating or sending. Count invalid calls and failed
rounds against attempt budgets. Check provider request size after adding tool
schemas and framing. Do not silently truncate tool JSON, drop unresolved calls,
or discard conversation entries to fit a limit. Return a tagged limit failure.

Backpressure propagates from the client writer to provider reads through bounded
queues. If a queue cannot drain within its deadline, cancel the turn. Reserve
space for terminal bookkeeping so a full content buffer cannot prevent cleanup.
An uninterruptible native call is ineligible for the first tool catalog unless it
has a documented finite bound compatible with the turn deadline. Cancellation
must not free memory still in use by that call.

Provider token limits are requested when supported. Record reported usage as
reported usage. Byte, call, and time ceilings do not prove an exact monetary cost.
Concrete defaults, throughput, memory use, and latency targets need measurement.
The current `cost_bounded` Property concerns module-call multiplicity. It does not
cover native stream parsing, model token consumption, or billed cost. Extend the
analysis before making a broader claim; runtime ceilings remain runtime evidence.

### KTD7. Preserve permissions and proof boundaries at every sink

Use deny-by-default grants for tools and resource names. Bind tenant and principal
outside model arguments. For SQL, keep registered statements and trusted subject
parameters. For HTTP, restrict destination, method, path, headers, body, redirect
behavior, and resolved address scope. A permitted host alone is insufficient.
Bind provider credentials through deployment-owned secret references. Generic
native egress resolves and injects the credential only after authorizing the exact
request. Redirects must not forward it to another destination. This credential
binding is part of U3, not an assumed property of the existing fetch interface.

Tool results are disclosure to the provider. Client text is also a disclosure
sink. Only data already authorized for those recipients enters model context.
Do not rely on a model to redact secrets after it sees them. Output projections
and schema validation retain provenance; they do not automatically declassify.

For stored data, unknown provenance costs a static Property. It is not itself a
runtime denial or a diagnostic that identifies a known secret. The agent still
needs the release checks required by R14. A handler that requires a cleared
Property must be refused by specification discharge or consumer policy. Do not
remove that requirement just to make the SQL example pass. Before exposing stored
results, define the trusted release operation and its evidence, or leave that
tool unavailable under the selected profile.

The `mask` export now declares `declassify_bound_arg`. A model-supplied bound
cannot authorize declassification. A wrapper that exposes this declassification
must fix its bound in reviewed source and separately establish that the recipient may receive
the released data. Being eligible for compiler declassification is not recipient
authorization.

Streaming introduces irreversible output: bytes already sent cannot be recalled.
Any policy that requires the complete answer must buffer that answer or refuse
streaming for that endpoint. Do not advertise token streaming with a whole-answer
policy that can only run after disclosure.

The compiler and acceptance path must cover deferred producers and static tool
wrappers. Unknown effects or unmodelled callbacks cannot acquire a PROVEN Property.
Runtime observations can establish that a particular call was denied or completed;
they do not promote a static Property. Existing attestation headers identify the
accepted artifact, not the truth of the generated answer or completion of a turn.

The existing `fault_covered` check uses HTTP status. A post-header stream failure
can occur after HTTP 200, so a stream cannot acquire that existing global Property
merely by emitting `turn.failed`. Keep admission fault coverage separate from
deferred producer failure handling. The stream contract requires every deferred
critical failure to reach one recorded failure or disconnect outcome, with no
later effect or event. Any new static claim for that contract needs its own
analysis and acceptance support; event tests alone do not establish it.

Likewise, constructing a stream response does not prove eventual completion.
Do not derive a whole-stream `response_total` claim from admission returning a
handle. Before release, define the stream proof profile and disclose unsupported
Properties. A consumer that requires one of those Properties rejects the artifact;
the runtime must not waive it to enable streaming.

Extend the exhaustive return-analysis decisions when adding producer forms.
Include both completing and non-completing paths; no default branch may grant
totality to an unhandled shape.

### KTD8. Make interruption and audit outcomes explicit

Expected application failures use tagged Result values. Native Zig code continues
to use error unions at engine boundaries. The public tags include
`invalid_request`, `unauthorized`, `capacity_exhausted`, `unknown_tool`,
`invalid_arguments`, `tool_denied`, `tool_failed`, `provider_failed`,
`provider_protocol_error`, `budget_exhausted`, `deadline_exceeded`, `cancelled`,
and `outcome_unknown`. Stable tags are separate from diagnostic text.

Before a tool effect, record turn/call identity, catalog and policy identity,
operation, and authorization decision. Afterwards record completion, failure, or
unknown outcome. Logs contain bounded metadata by default, not raw prompts,
credentials, arguments, or results. If required audit recording is unavailable,
stop before the next effect. Do not claim that a post-effect recording failure
means the effect did not happen. Durable audit retention is a deployment concern;
the first release does not promise recovery of an interrupted agent loop.

Add a bounded turn recorder with explicit recording success or failure. A request
completion trace or a best-effort logger cannot supply this contract by itself.
Deployment must configure a supported record sink. Reserve terminal record space
at admission, stop effects on sink failure, and surface sink health separately.
Acknowledgement means the sink accepted the complete record under its declared
retention contract, not that an unchecked log call returned. If deployment requires
durability before effects, acknowledgement must include durable storage completion.
Process loss can still lose pending records unless the configured sink confirms
durable storage; neither process loss nor sink failure establishes non-execution.

---

## Delivery Units

These units define the implementation sequence. They are not permission to begin
coding. Proposed new file names can change when the public API is resolved. Open
prerequisites below must be resolved before the dependent units can be executed.
Acceptance coverage names the final behavior each unit contributes to; full
end-to-end checks run after their dependencies exist.

| Unit | Scope and dependencies | Source and test locations | Acceptance coverage |
| --- | --- | --- | --- |
| U1. Catalog and invocation contract | Establish KTD2, the strict schema/parser subset, tool-local grants, independently checked dispatch identity, and public errors. Carry the catalog through serialization, runtime lowering, and acceptance before exposing dispatch. Revalidate schema extraction after concurrent rederive work; preserve binding invariants. | `packages/zts/src/builtin_modules.zig`, `packages/zts/src/module_binding/`, `packages/zts/src/handler_policy.zig`, `packages/zts/src/contract_builder.zig`, `packages/zts/src/type_checker.zig`, `packages/zts/src/contract_types.zig`, `packages/zts/src/handler_contract.zig`, `packages/zts/src/contract_json_writer.zig`, `packages/zts/src/contract_json_parser.zig`, `packages/runtime/src/contract_runtime.zig`, acceptance under `packages/proof-checker/src/`, `packages/zttp-sdk/src/binding.zig`, and proposed `packages/runtime/src/tool_dispatch.zig`; tests beside these modules. | AE2, AE3, AE4, AE10, AE11, AE18 negative cases, AE19, AE21 |
| U2. Response stream ownership | Add response variant, static admission classification, producer lifecycle, capacity limits, framing, cancellation, and the KTD8 turn recorder. Preserve current parser restrictions. No dependency on provider code. | `packages/runtime/src/http_types.zig`, `packages/runtime/src/http_parser.zig`, `packages/runtime/src/server_response.zig`, `packages/runtime/src/server.zig`, `packages/runtime/src/runtime_pool.zig`, `packages/runtime/src/engine_adapter.zig`, proposed `packages/runtime/src/turn_recorder.zig`; public integration tests in `packages/runtime/src/zruntime_tests.zig`. | AE7, AE8, AE12, AE13, AE20; a deterministic producer also proves client delivery before producer completion. |
| U3. Incremental outbound transport | Add bounded chunk delivery, deadlines, and deployment-owned credential resolution/injection after exact-request authorization. Enforce redirect credential restrictions. Depends on U2 lifecycle contract. | `packages/runtime/src/runtime_http.zig`, `packages/runtime/src/fetch_deadline.zig`, `packages/modules/src/net/fetch.zig`, its module spec, and adjacent tests. | AE1, AE5, AE7, AE9, AE17 |
| U4. Buffered reference agent | Connect U1 to a reviewed application adapter and bounded loop; preserve the pi boundary. Resolve stored-data release before using a SQL/cache tool. This is a test milestone. | New `examples/agent-handler/` source and configuration; parser behavior exercised through `packages/runtime/src/zruntime_tests.zig` with an in-memory or loopback provider. Wire applicable example suites through `scripts/test-examples.sh` and `build.zig`. | AE2 through AE6, AE9, AE10, AE18 |
| U5. Streamed reference agent and evidence | Connect U2/U3/U4, cover deferred code in contracts and artifact acceptance, then document the complete feature. | Handler/compiler verification and contract paths under `packages/zts/src/`; acceptance paths under `packages/proof-checker/src/` and `packages/runtime/src/`; `docs/user-guide.md`, `docs/internals/architecture.md`, `docs/performance.md`, `docs/internals/testing.md`. | All examples below, with real handler and socket paths |

U1's schema/parser design also determines work in
`packages/modules/src/security/validate.zig` and
`packages/zts/src/modules/data/json_mod.zig`, or explicitly named new catalog
validator files. Its AE18 coverage establishes negative provenance behavior.
U4 owns the positive stored-data release tests after that open decision is resolved.

Do not expose a release tool catalog until U1's acceptance and dispatch checks
work together. Do not ship the new response variant until its deferred code is
covered by the existing acceptance boundary. The example application must compile
under the admitted language, without adding general async syntax.

---

## Verification Contract

Use public handler, socket, and module APIs. Test doubles must be simple stores or
deterministic provider peers. Real paid model calls are not CI requirements.
Native unit tests live beside their code and run in under a second individually.
Integration timing uses handshakes rather than guessed sleep intervals.

| Example | Input and expected behavior |
| --- | --- |
| AE1. Actual streaming | A provider sends text and waits for a test signal before finishing. The client receives a text event before releasing that signal. The complete path uses an ordinary handler. Covers R3/R4. |
| AE2. Closed dispatch | Request an unknown name, an extension-only export, an evaluation operation, and an unadvertised built-in. Each is refused with zero tool effects. Covers R6-R10. |
| AE3. Resource scope | Request another tenant's order with a valid ID. Access is denied; no other tenant data reaches the model, client, or logs. Missing policy also denies. Covers R11/R12. |
| AE4. No secret laundering | Pass a labelled secret or credential directly and through validation, projection, serialization, `scope.using`, and a helper wrapper. Assert the corresponding leakage Property and required-policy refusal, not a neighboring Property such as `deterministic`. A clean input through the same path remains admissible. Covers R13/R14/R22. |
| AE5. Complete arguments | Split UTF-8, SSE delimiters, and argument JSON at different byte positions. Send duplicate keys through the actual dispatcher parser. Execute only after valid completion and strict parsing. A truncated or mixed valid/invalid round executes nothing. Covers R8/R9. |
| AE6. At most one live-call execution | Deliver duplicate IDs and duplicate completion signals. No repeated effect occurs. A disconnect after a write and before its response produces an unknown outcome without retry. Covers R18/R19. |
| AE7. Cancellation | Disconnect before a tool starts, during provider reads, during a native call, and during client writes. Start no new effect; release resources only after active work stops. Covers R17. |
| AE8. Capacity and slow clients | Route a stream-capable artifact directly to reserved stream capacity, including authentication failures. Fill its admission and output queues. Extra agent requests are rejected and ordinary requests retain reserved capacity. Memory stays within configured bounds. Covers R16/R20. |
| AE9. Provider failure | Send malformed frames, unsupported action types, excessive bodies, usage without completion, and a truncated tool response. Each yields a tagged failure with no pending calls executed. Covers R9/R16/R22. |
| AE10. Budget and batch order | Exhaust a configured boundary before the next request or tool. No next effect occurs. A failure in a sequential batch stops later calls and preserves earlier effects. Covers R16/R18. |
| AE11. Artifact and scope binding | Alter a schema, wrapper, grant, catalog, or linked dispatch target after acceptance; serving is refused even if the producer's declared catalog is unchanged. Enter one tool and attempt another tool's grant; access is refused. Covers R11/R21. |
| AE12. Lifecycle and compatibility | Reload during a stream, reuse a slot after failure, and send normal buffered/HEAD responses. The old stream keeps its generation; no context leaks; existing response semantics remain correct. Covers R21/R23. |
| AE13. Evidence failure | Fail audit recording before and after a tool effect. The first starts no effect; the second never reports not-executed. No raw credential appears in emitted diagnostics. Covers R13/R18/R22. |
| AE14. Output integrity | Inject newlines and fake SSE delimiters in model text. They remain JSON data. Exactly one logical terminal outcome is recorded and no later application event is emitted. Covers R3/R5. |
| AE15. Untrusted instructions | Put requests to read credentials, change tenant, add a tool, or send data to a new URL in the prompt and tool content. Forced model calls still meet the same denial checks; no instruction changes a grant. Covers R10-R15. |
| AE16. Post-header proof limits | Trigger a critical validation or tool failure after HTTP 200. Record and emit the terminal failure when possible, perform no later effect, and do not claim existing global `fault_covered` or whole-stream `response_total` from admission alone. A consumer requiring an unsupported Property refuses activation. Covers R5/R21/R22. |
| AE17. Provider credentials | Inject a configured credential into an authorized provider request. Refuse a model-selected destination, disallowed path, missing secret binding, and redirect to another destination. No credential reaches tool code, events, or logs. Covers R11/R13/R14. |
| AE18. Stored data provenance | Round-trip secret and credential values through cache, SQL, queue payloads, and durable signals. Assert that raw or projected reads do not establish leakage Properties. Required-policy activation fails; an approved release path needs its own positive and negative recipient-scope tests. Covers R14/R21/R22. |
| AE19. Bounded declassification | Use a model-selected or computed `mask` bound and confirm it preserves the input labels. Compare a supported literal/default bound without treating that compiler result as recipient authorization. Covers R13-R15. |
| AE20. Framing preservation | Send malformed header names, invalid method tokens, and an unsupported valid method before stream admission. Preserve current 400/501 behavior and do not invoke the handler with body bytes from a preceding request. Covers R1/R23. |
| AE21. Catalog schema enforcement | Reject duplicate public names, unreadable/dynamic schemas, unbounded nested values, and unknown object fields. A valid bounded input passes through the same parser and validator. Accepted schema bytes, runtime validators, and dispatch bindings agree after artifact round-trip. Covers R7/R8/R21. |

Run the affected unfiltered module, ZTS, server, SDK, and proof-checker suites.
U1 also needs schema/contract checks through `test-precompile`, `test-zts-cli`,
`test-contract-golden`, and `test-zts-layering`. Run the standalone `test-zruntime`
step for full handler integration. `test-examples` now belongs to `zig build test`;
wire the reference application into its real input set rather than adding an
unreachable example. Filtered runs are development checks, not release evidence.

Preserve `test-runtime-purity`, `test-module-boundary`, `test-capability-audit`,
`test-module-governance`, `test-proof-checker-purity`, `test-proof-ratchet`,
`test-proof-ratchet-drift`, and affected contract/acceptance gates. The runtime-purity
gate now has a floor for every provider family, including DeepSeek and the local
provider. Keep the generic runtime and analyzer clean without weakening those
floors to accommodate an application adapter.

Run `test-proof-swallow` over the producer and the covered consumer/activation
paths. Run `test-diagnostic-producers` for any added diagnostic variant, as well as
the existing seed/allowance checks in `test-standin`. A shared diagnostic code
does not prove that each advertised variant has a producer. New scripts and build
steps must pass `test-script-reachability` and `test-step-coverage`.

A new gate must fail when its corpus is removed or no relevant test runs. For
catalog and acceptance gates, also mutate copies of the declared inputs and
require the built gate to reject the wrong value. Cover each verdict decision
with a probe or an explicit justified exception. Compile the probes, read their
exit status, and assert the named Property. A clean corpus or an identity hash
alone cannot establish that a denial branch is reachable.

Before recording an agent fixture, demonstrate that a hand-authored correct
handler can satisfy its fixed proof profile. A fixture that requires clean
provenance from an unclassified store read is unsatisfiable, not evidence of a
model failure. Regenerate coverage and convergence reports when changes to their
underlying inputs or rule identities require it, using the repository tooling.

Start performance work with a sub-minute deterministic end-to-end run. Confirm
stream delivery, one tool call, final completion, and cleanup before scaling.
Then vary concurrency only, keeping the workload and limits fixed. Measure first
event latency, total turn time, peak memory, retained runtimes, open sockets,
cancellation completion, and the effect on ordinary requests. Choose deployment
defaults from those measurements. No performance target is asserted here.

---

## Open Implementation Decisions

The following are explicit design tasks before dependent implementation units.
They do not prevent review of this specification.

| Decision | Required resolution |
| --- | --- |
| Public stream and catalog API | Before U1/U2, define admitted callback shapes, ownership, Result signatures, schema subset, and compiler recognition. Demonstrate a compile-pass handler and compile-fail misuse cases. |
| Artifact encoding | Before U1 dispatch integration, define catalog serialization, runtime lowering, linked-target comparison, and acceptance. U5 extends this coverage to deferred producers. Version changed wire formats; unknown formats fail closed. |
| Stream proof profile | Before U5 release, define admission versus producer claims, failure coverage, completion, native work bounds, and the consumer policy that accepts the disclosed evidence. |
| Stored-data release | Before U4 exposes SQL/cache or other cross-call results, define a trusted recipient-scoped release operation and its evidence under current `.unknown` handling. Retain required leakage Properties; otherwise keep the tool unavailable under that profile. |
| First provider adapter | Before U4, select one provider protocol and verify its current streaming and tool-call completion semantics against official documentation. Do not infer behavior from a provider-compatible label. |
| Deployment limits | Before release, use the prescribed measurements to set finite defaults and supported concurrency. |
| Authentication integration | Before deploying the reference application, select the trusted identity source and demonstrate tenant-scoped authorization. No anonymous production default is specified. |

The proposed dedicated stream pool trades resource use for a simpler lifetime
contract. If measurements show that this cannot meet the intended workload,
revise the ownership design before release rather than claim unsupported capacity.

---

## Definition of Done

The reference application streams through the public handler path, executes only
its declared module-backed tools, and passes every applicable acceptance example.
Its catalog and deferred code pass artifact acceptance. The example explains
credentials, authorization, limits, interruption, and measured deployment capacity.
Buffered handlers retain their existing behavior, and the runtime-purity gate
remains active. No guarantee exceeds the evidence described in R22.

---

## Sources and Design Constraints

Repository paths in this document are relative to the repository root. Current
architecture is described in `docs/internals/architecture.md`; verification gates
are mapped in `docs/internals/testing.md`. `STRATEGY.md` and `CONCEPTS.md` define
the distinction between the development agent, a Handler, its Contract, and a
Property. This enhancement is an application capability, not a replacement for
the development agent.

The prior failure in
`docs/solutions/security-issues/validate-json-strips-the-label-it-was-asked-to-check.md`
requires explicit tests that validation cannot grant disclosure authority. The
failure in
`docs/solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md`
requires non-empty verification inputs.

The expanded gate obligations follow
`docs/solutions/conventions/a-gate-can-be-non-vacuous-and-still-porous.md`.
The requirement to prove a fixture is satisfiable before recording it follows
`docs/solutions/logic-errors/a-stale-cassette-is-loud-and-an-unsatisfiable-seed-is-silent.md`.

Tool scoping and independent authorization follow
[OWASP Excessive Agency guidance](https://genai.owasp.org/llmrisk/llm062025-excessive-agency/).
The [OWASP AI Agent Security guidance](https://cheatsheetseries.owasp.org/cheatsheets/AI_Agent_Security_Cheat_Sheet.html)
supports explicit budgets, result handling, and action records. These sources
inform the requirements; they do not establish that ZTTP already implements them.

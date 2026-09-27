# M5: release contract for agent handlers

Status: accepted by the owner on 2026-09-27, with decisions 1 to 5 of section 2.
This authorizes A1 to A6 in order. Each unit gets a design note that the owner
accepts before its code starts, as in M4. Two review rounds (a design critique and
a citation check) are folded in.
Baseline: local `main` at `e6f33dfc`. This contract resumes the work that the
[M4 release contract](2026-09-22-m4-release-contract.md) parked, under the
resume conditions of its section "Parked work and conditions to resume". It
consumes the [agent-handler specification](2026-09-19-feat-agent-handler-spec.md)
("A:n" below is a line reference into it) and the delivered M4 surfaces.

## 1. Resume conditions

The M4 contract states four conditions. Two hold, one holds for M5a only, and
one is waived for M5a by decision 5.

1. **M4 is complete.** Holds. T1a to T7 are complete (`docs/roadmap.md`, M4 row).
2. **No second catalog, schema, or dispatch table.** Holds. Every unit below
   consumes the T2 catalog (`ToolEntry`, `packages/zts/src/contract_types.zig:1645`),
   the `ZTCAT1` binding (`packages/tools/src/tool_catalog_encoding.zig`, graph
   member `tool_catalog = 19`), and the tool validator
   (`packages/zts/src/tool_schema.zig:837`). Tool calls from a model resolve
   through `AcceptedCatalog.find` (`packages/runtime/src/contract_runtime.zig:140`).
   The agent's own limits live in its catalog entry, so the artifact binds them.
3. **A's open decisions have recorded answers.** Holds for M5a only. Section 2
   records the catalog and dispatch API, the provider-side framer, the first
   provider adapter, and the order. The client stream API (A:651) and the
   stream proof profile (A:653) are decisions of S1 and S4, and M5b does not
   start until they have recorded answers.
4. **Deployment limits come from measurement.** Not met, and waived for M5a by
   decision 5. A6 produces the measurement.

A new release contract states the resumed scope: this document.

## 2. Decision record

The owner answered decisions 1 to 4 on 2026-09-27 and accepted decision 5 with
the text on the same day.

1. **Order: a buffered agent first.** M5a delivers an agent route that runs a
   bounded model and tool loop and returns one buffered response. A's U4 moves
   from a test milestone to a shippable surface. M5b then adds streaming output
   (A's U2), incremental provider input (A's U3 streaming part), and the stream
   proof profile (A's U5). A:39-41 says a buffered agent is not completion of
   the feature. That remains true: M5a is a release boundary, not feature
   completion.
2. **Dispatch: a native `callTool` through the accepted catalog.** A new
   `zttp:tool` export resolves a tool name in the accepted catalog, validates
   the arguments with the tool validator, enters that tool's grant, calls the
   tool's route function with the caller's verified subject and tenant,
   validates the output, and leaves the grant on every exit. A model can name
   only a tool that the agent entry lists. A4 fixes its signature.
3. **First provider protocol: OpenAI-compatible chat completions.** The
   reference adapter targets the streaming chat-completions protocol with
   `tool_calls` deltas and `finish_reason`. DeepSeek and the local MLX-LM server
   both serve it, and both are permitted providers in this repository. CI uses a
   deterministic loopback peer. Before A5 starts, the adapter's completion
   semantics are checked against the provider's current official documentation,
   not inferred from a compatible label (A:655). M5a requests the streaming
   form and frames the buffered body, so that the delta assembly and its tests
   (AE5, AE9) carry into M5b; only the transport changes there.
4. **Parsing: a native generic SSE framer.** A provider-neutral native export
   splits bytes into bounded SSE events and preserves UTF-8 sequences and frame
   boundaries. Handler code parses each event's JSON with `zttp:json` and owns
   all provider semantics. No provider client enters the runtime, so R23 and the
   runtime-purity gate hold unchanged.
5. **Limits before measurement.** M5a ships with limits that each
   deployment must set, with no default values. A6 measures and then sets the
   defaults. Until A6 closes, the user guide states that no default is measured.

## 3. What the delivered surface already provides

| Spec requirement | Delivered by | Status for M5 |
|---|---|---|
| R6, R7, R8 catalog, schema subset, strict parse | M4 T2, T3 | Reused. `callTool` validates through the same `tool_schema.validate`. |
| R11, R12 scope and grants | M4 T5a, T5b | Reused, with one change: one outer grant is saved and restored (A1). |
| R13 provider credentials | M4 T6 | Reused on the synchronous `fetch` path in M5a. The streaming path needs its own echo refusal (S2). |
| R14 declared labels | M4 T4 | Reused. `callTool` joins its argument labels (A4). |
| R21 artifact binding | M4 T3, T5b | Reused. The agent entry extends `ZTCAT1` (A1). |
| Finite outbound deadline | M4 T1a, T1b | Reused in M5a. A stream needs an idle budget (S2). |

## 4. What the current code blocks

Each item below is a fact at `e6f33dfc` that the M5 units must change. The
spec's baseline table does not list them. Items 1 to 5 came with M4; items 6
to 8 are older.

1. **A tool handler has no place for an agent route.** Every route in a tool
   handler needs a catalog entry (`route_untooled`,
   `packages/zts/src/contract_builder.zig:1535-1540`), and a catalog entry today
   is a tool. A catalogued tool route can call an authorized `fetch`
   (`examples/tools/tools.ts:68-75`), but it runs under a tool grant and a tool
   input schema, not under a provider grant and the R1 prompt shape.
   `checkToolDispatch` (`contract_builder.zig:1977`) also refuses any export
   other than `routerMatch` in the shared dispatch outside the route functions.
2. **The tool grant does not nest.** `ctx.active_tool_grant`
   (`packages/zts/src/context.zig:272`) is one slot. `handler_instance.zig:1460`
   sets it for one handler call and clears it in a `defer`. A nested tool call
   has nowhere to save the outer grant.
3. **No active grant allows every export.** `checkToolGrant` returns at once
   when the slot is null (`packages/zts/src/module_binding/capabilities.zig:89`).
   An agent route that runs with no grant would reach every export its handler
   reaches. The agent route must run under its own grant, never under none.
4. **`toolInput` reads the request body.** `toolInput(name, req)`
   (`packages/modules/src/http/tool.zig:75`) parses `req.body`, and outside a
   tool request it refuses with `not_a_tool_request` (`:78`). A tool called
   from `callTool` needs its input from the call. An agent route has no
   admitted reader for its prompt; every other body reader carries `user_input`.
5. **Identity comes from headers only.** `tool_auth.verifyRequest`
   (`packages/runtime/src/tool_auth.zig:100`) reads the bearer token. A nested
   call must inherit the verified identity of the outer request and must not
   re-verify from model-supplied data.
6. **The server's handler deadline defaults to 30 s.** `timeout_ms` defaults
   to 30000 (`packages/runtime/src/server.zig:1331`), is copied to
   `request_timeout_ms` (`:2443`), and also sets `SO_SNDTIMEO` (`:463-468`).
   A standalone `RuntimeConfig.request_timeout_ms` defaults to 0, which
   disables it (`runtime_config.zig:141-143`). The handler deadline is a
   runtime parameter that the build never sees.
7. **Callbacks escape the Result checks.** `walkExprForRefs`
   (`packages/zts/src/handler_verifier.zig:1024`) does not descend into arrow
   or function expressions. M5a adds no callback form. S4 must close this
   before a stream producer closure exists. The M5a adapter is a loop in the
   route function; M5b's producer form can require a rewrite of it, and A5
   accepts that cost.
8. **`zttp:json` accepts raw control bytes in strings.** Its string reader
   appends every byte that is not a quote or a backslash
   (`packages/zts/src/modules/data/json_mod.zig:188-198`). It refuses duplicate
   keys, but it is not a strict RFC 8259 parser. Tool arguments are still
   checked by `tool_schema.validate`; the adapter's parse of provider events is
   not. A3 fixes this.

Streaming-only facts, owned by M5b: `HttpResponse` carries one complete body
slice, owned or borrowed (`packages/runtime/src/http_types.zig:111-127`);
response framing is `Content-Length` only (`server_response.zig:152-192`), and
handler-set framing headers are dropped (`:124-128`); fetch reads the full body
(`runtime_http.zig:966-981`); the fetch deadline is one fixed wall-clock end
with no idle reset (`fetch_deadline.zig:33-41`); the credential echo refusal
scans the complete body (`runtime_http.zig:933-945`); and each connection
worker serves a whole keep-alive connection synchronously (`server.zig:446-494`),
so a stream holds a worker and a runtime.

## 5. Threat model and disclosures

Unchanged from M4 section "Threat model": the model and the caller are
untrusted; the operator, the host, the compiler, the kernel, the runtime, the
reviewed native modules, the deployment configuration, and the identity source
are trusted. M4 already treats all content an upstream service returns as
untrusted. The provider's response is such content, and M5 gives it a new use:
it selects tool calls. Provider text, tool-call names, tool-call identities,
tool-call arguments, and usage figures are untrusted data. A provider response
can name a listed tool; it cannot add one, change a grant, choose a credential,
or change a destination.

M5 adds one recipient: the provider. The provider request body is a disclosure
sink (R14). The R22 section for agent routes (A5) discloses each of these:

- A tool result that the adapter puts into the next provider request reaches
  the provider with the caller's clearance. There is no model-field projection
  (KTD2); the output schema bounds the shape, and the flow checker decides
  whether a labelled value may reach the provider.
- The prompt is user content sent to the provider by design, so
  `pii_contained` is unmet for an agent route by construction. It is disclosed
  and never required.
- R9's whole-round validation, and the scope of live duplicate refusal, are
  enforced by adapter code plus the runtime parts that A4 names, not by the
  runtime alone.
- A nested tool runs in the agent's runtime and request arena, not in a runtime
  of its own.

M5 claims no prompt-injection immunity, answer accuracy, or exactly-once
execution (A:224-226). Existing assurance grades stay as disclosed.

## 6. M5a delivery units

The units are ordered. A unit starts only after its dependencies are committed
and its design note is accepted. A1's new refusal reasons and A3's new module
move the hashes that the DeepSeek codegen cassettes embed, as T2's did. The
plan budgets one owner-authorized re-record, run once after A4.

**A1. The agent entry, its admission, and grants.** Depends on nothing. Owned
files: `packages/zts/src/contract_types.zig`, `contract_builder.zig`,
`contract_json_writer.zig`, `contract_json_parser.zig`, `handler_policy.zig`,
`module_authorization.zig`, `module_binding/capabilities.zig`, `context.zig`,
`packages/tools/src/tool_catalog_encoding.zig`,
`packages/proof-checker/src/tool_catalog.zig`,
`packages/runtime/src/handler_instance.zig`, `contract_runtime.zig`,
`server.zig`, `tool_auth.zig`, `packages/modules/src/http/tool.zig`, and the
envelope source.

- The `toolCatalog` literal gains an agent entry. It holds the route, the
  names of the tools it may call, its provider grant (endpoint and credential
  name, both required), and its limits: model rounds, tool calls in total and
  per round, argument and result bytes, prompt bytes, and a turn deadline.
  Provider request and response bytes are bounded by the existing outbound
  limits on the provider fetch; the design note states which ones. Every limit
  is required; absence and zero are build refusals. A loopback peer with no key
  still names a credential, bound to a placeholder value.
- `ZTCAT1` moves to schema 4, and the kernel decoder follows. The contract
  version moves by one.
- The runtime admits the agent route as it admits a tool route. It verifies the
  bearer token first (401) and validates the body against the fixed R1 shape,
  `{version: 1, prompt: string}` with the prompt byte bound, before the
  handler runs (400, 413).
- A new `zttp:tool` export reads the admitted prompt. The design note decides
  its return labels. They must keep `user_input` unless there is evidence to
  remove it, and `validated` may join it because the runtime checked R1.
- A new inert `callTool` export is declared, as T2 declared `toolCatalog`, so
  that A4's placement refusal can be tested for the right reason.
- The agent grant admits one egress export, `fetch`, and only with the entry's
  credential name. Under the agent grant, a `fetch` without that credential,
  `fetchWithRetry`, `zttp:io`, `httpRequest`, and every other egress export are
  refused at build and at runtime. "Provider fetch" below means any fetch under
  the agent grant.
- A null grant under an agent handler refuses the call. The grant slot saves
  exactly one outer grant, and a second push is a runtime refusal.
- The runtime refuses to serve when an agent entry's turn deadline, plus a
  margin for terminal bookkeeping, is not below the handler deadline. The A1
  design note (Q7, accepted 2026-09-27) places this check at catalog promotion
  and at the dev catalog install, not in `HandlerInstance.init`, which cannot
  see the accepted catalog in every mode.

The design note decides the literal's shape. Completion: check C-A1.

**A2. The turn state and the turn recorder.** Depends on A1. Owned files: a
new `packages/runtime/src/turn_state.zig`, a new
`packages/runtime/src/turn_recorder.zig`, `runtime_http.zig`,
`packages/modules/src/net/fetch.zig` and its module spec (new refusal tags for a
latched or over-budget fetch), `runtime_config.zig` and `runtime_cli.zig` (the
cap), and `scripts/module-boundary.allow` if the recorder reaches a `zts`
internal module.

- The turn state holds the server-created turn identity, the round ordinal,
  the call identities seen in the turn, the remaining budgets, and a latch.
- Each provider fetch counts one model round. The fetch past the round limit
  is refused before the connection opens.
- The latch closes after `tool_denied`, `tool_failed`, `outcome_unknown`, a
  budget failure, or the deadline. After it closes, every later `callTool` and
  provider fetch in the turn is refused.
- The turn recorder writes a bounded record before each effect and after it.
  At admission it reserves space for the terminal record, and it reports sink
  health separately (KTD8). A sink failure before an effect starts no effect. A
  pre-record with no post-record is `outcome_unknown`, never "not executed"
  (A:526-527). A deadline between two effects is `deadline_exceeded` with no
  unknown outcome.
- The provider fetch is not retried in M5a; A1 refuses the retry paths under
  the agent grant.
- A per-server cap on concurrent agent turns is checked at admission, before
  the first provider call, and a full cap gives 503. It is a server setting, not
  an agent-entry limit, and it has no default until A6.

The design note chooses the sink and the record shape. Prefer the in-tree
fsynced oplog pattern (`DurableState`, `packages/zts/src/trace.zig:1153`, write
and fsync at `:1528-1530`) over the handler-facing `zttp:ledger` store.
Completion: check C-A2.

**A3. The SSE framer and strict JSON strings.** Depends on nothing and can run
beside A1 and A2. Owned files: a new native module under
`packages/modules/src/net/`, its module spec, its row in
`packages/zts/src/builtin_modules.zig`, and
`packages/zts/src/modules/data/json_mod.zig`.

- M5a exposes a total framer over a complete buffered body. It returns the
  list of events (event name, data, id) or a tagged framing failure, with
  per-event and per-body byte bounds. It passes its argument through, so it
  declares `derives_from_args`. S3 adds the incremental form.
- `zttp:json` refuses a raw control byte inside a string, as RFC 8259 section 7
  requires, with a named error and an offset.

Completion: check C-A3.

**A4. `callTool`.** Depends on A1 and A2. Owned files:
`packages/modules/src/http/tool.zig`, its module spec, `server.zig` (to share
the validation and scope steps it runs inline at `:686-859`),
`contract_runtime.zig`, `contract_builder.zig`, and
`packages/zts/src/flow_checker.zig`.

- The signature is `callTool(callId, name, argsJson)`. The runtime composes the
  call identity from the turn identity, the round ordinal, and `callId`, and
  refuses a duplicate within the round. The identity goes into the turn record.
- Each invalid call counts against the call budgets, so a model cannot repeat
  invalid calls until the deadline.
- The return is a `Result`. The error arm carries a tag only: `unknown_tool`,
  `invalid_arguments`, `tool_denied`, `tool_failed`, `budget_exhausted`,
  `deadline_exceeded`, or `outcome_unknown` (A:516-520). No tool body text.
- The name must be in the agent entry's list, not only in the catalog. The
  build refuses `callTool` in any route that is not an agent route, and an agent
  entry named in a tool list.
- The inner call gets a fresh request that holds the subject, the tenant, and
  the pending arguments only, with no prompt body, query, or client header.
  `toolInput` reads the pending arguments. The design note lists each M4 tool
  route field that reads the request and confirms it still works.
- The flow checker computes the ok arm's labels at the call site: the labels of
  `argsJson`, joined with the union of the declared output labels of every tool
  the agent entry lists. The union fails closed: one listed tool with a secret
  output labels every result. A labelled value that goes in comes back out.

The runtime sees one call at a time, so R9's whole-round validation stays in
adapter code. The runtime supplies two parts: the latch stops the rest of a
round after a failure, and the duplicate refusal holds within the round.
Completion: check C-A4.

**A5. The reference agent.** Depends on A1 to A4 and on the provider
documentation check of decision 3. Owned files: a new `examples/agent/`
directory with its `zttp.json`, `policy.json`, and `declaration.json`, its entry
in the example suite, a new build step beside `test-reference-tools`,
`packages/tools/src/report.zig` (the R22 section), and `docs/user-guide.md`.

- The handler holds an OpenAI-compatible adapter that uses `fetch`, the A3
  framer, `zttp:json`, and a bounded `for (const i of range(MAX))` loop with
  `break`. It calls the two M4 reference tools through `callTool`.
- The response body is the KTD4 envelope list, buffered: the same event types,
  `turn_id`, and `sequence` that M5b streams, so M5b changes the framing only.
- The fixed proof profile names its properties in the example's
  `policy.json`: `response_total`, `results_checked`, `no_secret_leakage`,
  `no_credential_leakage`, and `capability_bounded`, the two leakage properties
  at the provider request body and at the client response. Before any fixture is
  recorded, a hand-authored handler must pass it (A:629-633). The design note
  confirms that `policy.json` can require each of these today, or names the
  change that lets it.
- The harness drives a deterministic loopback provider peer and real signed
  requests, as `test-reference-tools` does. At the default 30 s handler deadline
  the reference agent completes against the loopback peer and a fast local
  model only; A6 records the deadlines it ran under.
- The R22 section states static Properties, runtime restrictions, observed
  events, unknown outcomes, and the disclosures of section 5.

Completion: check C-A5.

**A6. Measurement and limits.** Depends on A5. A sub-minute deterministic run
comes first: one prompt, one tool call, one final answer, and cleanup. Then vary
concurrency only. Record turn time, peak memory, retained runtimes, and the
effect on ordinary requests. Choose the default limits and the concurrent-turn
cap from those numbers. A live pilot against the local MLX server comes next,
and a DeepSeek pilot only with the owner's approval of that run. Completion:
check C-A6.

## 7. M5b delivery units

M5b starts after M5a is complete and after S1 and S4 have recorded answers to
their open decisions. Each unit here is stated at the level the spec states it.
Each gets a design note before it starts.

**S1. Response stream ownership.** A's U2: a response variant with a
native-managed producer (A:323-325), producer lifetime, reserved capacity, and
admission before handler dispatch (A:327-348), with framing and deadlines per
A:379-386 and A:428-433. M5 adds three requirements that the spec does not
name: chunked framing on HTTP/1.1, a turn deadline separate from
`request_timeout_ms` and `SO_SNDTIMEO`, and reserved capacity for connection
workers as well as runtimes. Preserve the parser restrictions of AE20. The
design note answers A's stream API decision (A:651).

**S2. Incremental outbound transport.** A's U3 streaming part: chunk delivery,
an idle budget beside the absolute deadline, and an echo refusal that works
across chunks. A rolling hold-back works only for exact-byte matching. It must
hold back one byte less than the longest bound value, check again and flush at
EOF, and state which encoded forms of the value it does not detect. The design
note checks this against the refusal's current matching rules.

**S3. Incremental SSE framer.** The A3 framer takes a chunk and a carried state.

**S4. Stream proof profile.** A's open decision (A:653): admission versus
producer claims, the verifier walk into producer closures (section 4, item 7),
failure coverage that does not reuse the status-based `fault_covered`
(`packages/tools/src/precompile.zig:2645-2655`), and the consumer policy.

**S5. Streamed reference agent and measurement.** A's U5 and the remaining
acceptance examples.

## 8. Completion checks

Every verdict comes from an unfiltered build step with its exit status read
directly. Each new gate asserts a floor on its input, is shown non-vacuous by a
delete-input probe and by mutation of a copy of its declared inputs, and gets a
per-verdict census (AGENTS.md).

| Check | Gate or step | Positive case | Negative case | Non-vacuity |
|---|---|---|---|---|
| C-A1 | `test-zts`, `test-proof-checker`, `test-proof-checker-mutants`, `test-vocab-envelope-drift`, `test-contract-golden`, `test-zruntime` | An agent handler builds; its entry round-trips through `ZTCAT1` schema 4; a signed, well-formed prompt reaches the handler | An unsigned prompt gets 401 and no provider call; a malformed or oversized body gets 400 or 413; a missing or zero limit fails the build; an agent route that reaches a tool's export directly fails the build; a `fetch` without the entry's credential, and `fetchWithRetry`, under the agent grant are refused; a turn deadline not below the handler deadline refuses to start; one mutated agent-entry byte refuses to start | Restore the allow-all on a null slot, and a test must fail. Allow a second grant push, and a test must fail. Census over the new refusal reasons |
| C-A2 | `test-zruntime`, `test-server`, `test-modules` | A turn inside its limits has a pre-record and a post-record per provider fetch | A provider fetch past the round limit is refused; a sink failure before a provider fetch starts no fetch; a deadline between two provider fetches gives `deadline_exceeded` with no second pre-record; a deadline during a fetch gives `outcome_unknown`; after the latch closes, a provider fetch is refused; the cap refuses the next turn with 503 before any provider call | Remove the pre-effect record, and the sink-failure case must fail. Remove the latch, and the latched-fetch case must fail |
| C-A3 | `test-modules`, `test-zts`, `test-module-governance` | A fixed corpus of delimiter forms (LF, CRLF, CR), comment lines, multi-line data, `id`, `event`, and a leading BOM gives the expected events | Oversized event, oversized body, invalid UTF-8, and a final frame with no terminator each give their tag; a raw newline or other control byte in a `zttp:json` string is refused | Census over the framing-failure enum. The corpus must not be empty |
| C-A4 | `test-modules`, `test-zts`, `test-zruntime`, `test-proof-swallow`, `test-capability-audit` | A listed tool runs with the caller's subject and tenant and gets a fresh request | AE2; AE3; AE6 live dedup: a repeated `callId` in one round runs once; AE10 batch half: a failure stops later calls and keeps earlier effects; AE13 for tool effects; a catalog tool that is not in the agent's list; repeated invalid calls exhaust the call budget; a tool whose output fails its schema is `tool_failed`, not an empty success; `callTool` in a tool route fails the build | AE4, asserting `no_secret_leakage` both ways: a labelled tool result returned directly and through `callTool` is refused; a labelled value in the agent handler passed as `argsJson` to an echo tool and then returned is refused; a labelled value in the provider request body is refused. A clean value on each path stays admissible |
| C-A5 | the new step, `zig build test`, `bash scripts/verify.sh`, `test-runtime-purity` | A signed prompt reaches one tool call and one final answer through the loopback peer, and the body is the envelope list | AE5 non-stream part, as an adapter test; AE6 no-retry half; AE9 buffered part; AE11; AE15; AE17; AE19; AE21 | A probe that breaks the example must fail the step. The step fails when it ran no case. A hand-authored handler that sends an `env()` secret in the provider body must be refused under the named profile |
| C-A6 | the measurement record | Numbers recorded with the command, the host, the commit, and the deadlines | Not applicable | Not a gate. The sub-minute run is recorded before any scaled run |

From the spec's examples, M5a applies AE2, AE3, AE4, AE5 (non-stream), AE6
(no-retry half, and live dedup within one round), AE9 (buffered part), AE10,
AE11, AE13, AE15, AE17, AE19, and AE21. M5b applies AE1, AE7, AE8, AE12, AE14,
AE16, AE20, and the stream parts of AE5 and AE9. AE18's positive release path
stays deferred with decision 6 of M4: agent catalogs, like tool catalogs,
refuse cross-call reads.

## 9. Out of scope

Persistent conversations, reconnection, crash recovery of a turn, parallel tool
calls, provider retry, mutating tools without an explicit retry contract,
provider-hosted tools, additional provider adapters, a model-field projection of
tool results, a per-principal turn cap, and a stored-data release operation.
The HAL-FORMS projection and sequential static composition stay parked from M4.

## 10. Open questions

None for the contract. Each unit's design note carries its own questions for the owner.

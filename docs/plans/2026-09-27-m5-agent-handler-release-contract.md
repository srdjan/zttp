# M5: release contract for agent handlers

Status: proposed on 2026-09-27. The owner answered the four scope questions of
section 2 on 2026-09-27. The text as a whole needs owner acceptance before A1
starts. Each unit then gets a design note that the owner accepts, as in M4.
Baseline: local `main` at `e6f33dfc`. This contract resumes the work that the
[M4 release contract](2026-09-22-m4-release-contract.md) parked, under the
resume conditions of its section "Parked work and conditions to resume". It
consumes the [agent-handler specification](2026-09-19-feat-agent-handler-spec.md)
("A:n" below is a line reference into it) and the delivered M4 surfaces.

## 1. Resume conditions

The M4 contract states four conditions. This section records each one.

1. **M4 is complete.** T1a to T7 are complete (`docs/roadmap.md`, M4 row).
2. **No second catalog, schema, or dispatch table.** Every unit below consumes
   the T2 catalog (`ToolEntry`, `packages/zts/src/contract_types.zig:1645`),
   the `ZTCAT1` binding (`packages/tools/src/tool_catalog_encoding.zig`, graph
   member `tool_catalog = 19`), and the strict validator
   (`packages/zts/src/tool_schema.zig:837`). Tool calls from a model resolve
   through `AcceptedCatalog.find` (`packages/runtime/src/contract_runtime.zig:140`).
   Agent limits live in the agent entry only, so the artifact binds them; no
   runtime flag duplicates them.
3. **A's open decisions have recorded answers.** This holds for M5a only.
   Section 2 records the catalog and dispatch API, the provider-side framer, the
   first provider adapter, and the order. The client stream API (A:651) and the
   stream proof profile (A:653) are decisions of S1 and S4, and M5b does not
   start until they have recorded answers. Deployment limits come from
   measurement in A6 and S5.
4. **A new release contract states the resumed scope.** This document.

## 2. Decision record

The owner answered four questions on 2026-09-27.

1. **Order: a buffered agent first.** M5a delivers an agent route that runs a
   bounded model and tool loop and returns one buffered response. A's U4 moves
   from a test milestone to a shippable surface. M5b then adds streaming output
   (A's U2), incremental provider input (A's U3 streaming part), and the stream
   proof profile (A's U5). A:39-41 says a buffered agent is not completion of
   the feature. That remains true: M5a is a release boundary, not feature
   completion.
2. **Dispatch: a native `callTool` through the accepted catalog.** A new
   `zttp:tool` export resolves a tool name in the accepted catalog, validates
   the arguments with the strict tool validator, enters that tool's grant,
   calls the tool's route function with the caller's verified subject and
   tenant, validates the output, and leaves the grant on every exit. A model
   can name only a tool that the agent entry lists. Section 6 fixes its
   signature and its call identity.
3. **First provider protocol: OpenAI-compatible chat completions.** The
   reference adapter targets the streaming chat-completions protocol with
   `tool_calls` deltas and `finish_reason`. DeepSeek and the local MLX-LM server
   both serve it, and both are permitted providers in this repository. CI uses a
   deterministic loopback peer. Before A6, the adapter's completion semantics
   are checked against the provider's current official documentation, not
   inferred from a compatible label (A:655). M5a requests the streaming form and
   frames the buffered body, so that the delta assembly and its tests (AE5, AE9)
   carry into M5b unchanged; only the transport changes there.
4. **Parsing: a native generic SSE framer.** A provider-neutral native export
   splits bytes into bounded SSE events and preserves UTF-8 sequences and frame
   boundaries. Handler code parses each event's JSON with strict `zttp:json`
   and owns all provider semantics. No provider client enters the runtime, so
   R23 and the runtime-purity gate hold unchanged.

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
and 7 are older.

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
   (`packages/modules/src/http/tool.zig:75`) parses `req.body`. A tool called
   from `callTool` needs its input from the call, not from an HTTP body.
5. **Identity comes from headers only.** `tool_auth.verifyRequest`
   (`packages/runtime/src/tool_auth.zig:100`) reads the bearer token. A nested
   call must inherit the verified identity of the outer request and must not
   re-verify from model-supplied data.
6. **The server's handler deadline defaults to 30 s.** `timeout_ms` defaults
   to 30000 (`packages/runtime/src/server.zig:1331`), is copied to
   `request_timeout_ms` (`:2443`), and also sets `SO_SNDTIMEO` (`:463-468`).
   A standalone `RuntimeConfig.request_timeout_ms` defaults to 0, which
   disables it (`runtime_config.zig:141-143`). A multi-round model turn can exceed it. M5a states the turn deadline
   as a value no larger than the handler deadline; M5b separates them.
7. **Callbacks escape the Result checks.** `walkExprForRefs`
   (`packages/zts/src/handler_verifier.zig:1024`) does not descend into arrow
   or function expressions. M5a adds no callback form. S4 must close this
   before a stream producer closure exists. The M5a adapter is a loop in the
   route function; M5b's producer form can require a rewrite of it, and A5
   accepts that cost.

Streaming-only facts, owned by M5b: `HttpResponse` carries one complete body
slice, owned or borrowed
(`packages/runtime/src/http_types.zig:111-127`); response framing is
`Content-Length` only (`server_response.zig:152-192`), and handler-set framing
headers are dropped (`:124-128`); fetch reads the full body
(`runtime_http.zig:966-981`); the fetch deadline is one fixed wall-clock end
with no idle reset (`fetch_deadline.zig:33-41`); the credential echo refusal
scans the complete body (`runtime_http.zig:933-945`); and each connection
worker serves a whole keep-alive connection synchronously (`server.zig:446-494`),
so a stream holds a worker and a runtime.

## 5. Threat model

Unchanged from M4 section "Threat model": the model and the caller are
untrusted; the operator, the host, the compiler, the kernel, the runtime, the
reviewed native modules, the deployment configuration, and the identity source
are trusted. M4 already treats all content an upstream service returns as
untrusted. The provider's response is such content, and M5 gives it a new use:
it selects tool calls. Provider text, tool-call names, tool-call identities, tool-call arguments, and usage
figures are untrusted data. A provider response can name a listed tool; it
cannot add one, change a grant, choose a credential, or change a destination.

M5 adds one recipient: the provider. The provider request body is a disclosure
sink (R14). A tool result that the adapter puts into the next provider request
reaches the provider with the caller's clearance. M5a has no model-field
projection of tool results (KTD2): the output schema bounds the shape, and the
flow checker, not a projection, decides whether a labelled value may reach the
provider. The R22 report for an agent route states this.

M5 claims no prompt-injection immunity, answer accuracy, or exactly-once
execution (A:224-226). Existing assurance grades stay as disclosed.

## 6. M5a delivery units

The units are ordered. A unit starts only after its dependencies are committed
and its design note is accepted.

**A1. The agent entry, its admission, and grants.** Depends on nothing. Owned
files: `packages/zts/src/contract_types.zig`, `contract_builder.zig`,
`packages/tools/src/tool_catalog_encoding.zig`,
`packages/proof-checker/src/tool_catalog.zig`, `packages/zts/src/context.zig`,
`packages/runtime/src/handler_instance.zig`, `contract_runtime.zig`,
`server.zig`, `runtime_http.zig`, and the envelope source.

- The `toolCatalog` literal gains an agent entry. It holds the route, the
  names of the tools it may call, its provider grant (endpoint and credential
  name), and its limits: model rounds, tool calls in total and per round,
  argument and result bytes, prompt bytes, and a turn deadline. Every limit is
  required; absence and zero are build refusals. The build also refuses an
  entry whose rounds times the outbound deadline exceed the turn deadline, or
  whose turn deadline exceeds the handler deadline.
- `ZTCAT1` moves to schema 4, and the kernel decoder follows.
- The runtime admits the agent route as it admits a tool route. It verifies the
  bearer token first (401) and validates the body against the fixed R1 shape,
  `{version: 1, prompt: string}` with the prompt byte bound, before the
  handler runs (400, 413).
- The agent route runs under its provider grant only. A null grant under an
  agent handler refuses the call. The grant slot saves exactly one outer grant.
  A second push is a runtime refusal.
- The build refuses `callTool` in any route that is not an agent route, and an
  agent entry named in a tool list. The agent route is not callable as a tool.
- The provider fetch is recognized by its provider credential. Each injection
  of that credential counts one model round, and the fetch past the round limit
  is refused before the connection opens.

The design note decides the literal's shape. Completion: check C-A1.

**A2. The turn state and the turn recorder.** Depends on A1. Owned files: a
new `packages/runtime/src/turn_state.zig`, a new
`packages/runtime/src/turn_recorder.zig`, and `runtime_http.zig` for the
provider fetch hooks.

- The turn state holds the server-created turn identity, the round ordinal,
  the call identities seen in the turn, the remaining budgets, and a latch.
- The latch closes after `tool_denied`, `tool_failed`, `outcome_unknown`, a
  budget failure, or the deadline. After it closes, every later `callTool` and
  provider fetch in the turn is refused.
- The turn recorder writes a bounded record before each effect and after it.
  The effects are each provider fetch and each tool call. A sink failure before
  an effect starts no effect. A pre-record with no post-record, including one
  left by a deadline, is `outcome_unknown`, never "not executed" (A:526-527).
- The provider fetch is not retried in M5a. The adapter cannot call
  `fetchWithRetry` with the provider credential, because T6 already refuses
  credentials on that path (`packages/modules/src/net/fetch.zig:152-159`).
- A per-server cap on concurrent agent turns is checked at admission, before
  the first provider call, and a full cap gives 503. The value comes from A6.

The design note chooses the sink and the record shape. Prefer the in-tree
fsynced oplog pattern (`DurableState`, `packages/zts/src/trace.zig:1153`, write and fsync at `:1528-1530`) over the
handler-facing `zttp:ledger` store. Completion: check C-A2.

**A3. The SSE framer.** Depends on nothing and can run beside A1 and A2. Owned
files: a new native module under `packages/modules/src/net/`, its module spec,
and its row in `packages/zts/src/builtin_modules.zig`. M5a exposes a total
function over a complete buffered body. It returns the list of events (event
name, data, id) or a tagged framing failure, with per-event and per-body byte
bounds. It passes its argument through, so it declares `derives_from_args`.
S3 adds the incremental form. Completion: check C-A3.

**A4. `callTool`.** Depends on A1 and A2. Owned files:
`packages/modules/src/http/tool.zig`, its module spec, `server.zig` (to share
the validation and scope steps it runs inline at `:686-859`), and
`contract_runtime.zig`.

- The signature is `callTool(callId, name, argsJson)`. The runtime composes the
  call identity from the turn identity, the round ordinal, and `callId`, and
  refuses a duplicate within the turn. The identity goes into the turn record.
- The return is a `Result` whose error tags are the spec's `unknown_tool`,
  `invalid_arguments`, `tool_denied`, `tool_failed`, `budget_exhausted`,
  `deadline_exceeded`, and `outcome_unknown` (A:516-520).
- The name must be in the agent entry's list, not only in the catalog.
- The inner call gets a fresh request that holds the subject, the tenant, and
  the pending arguments only. It holds no prompt body and no client header.
  `toolInput` reads the pending arguments.
- The return labels are the labels of `argsJson`, joined with the union of the
  listed tools' declared output labels. The binding declares
  `derives_from_args`. A labelled value that goes in comes back out.

R9's rule "validate the whole round before the first call" stays in adapter
code: the runtime sees one call at a time. The runtime supplies its parts: the
latch stops the rest of a round after a failure, and the duplicate refusal
holds across the round. The R22 report says that AE5's mixed valid and invalid
round is an adapter test. Completion: check C-A4.

**A5. The reference agent.** Depends on A1 to A4. Owned files: a new
`examples/agent/` directory, its entry in the example suite, a new build step
beside `test-reference-tools`, and `docs/user-guide.md`.

- The handler holds an OpenAI-compatible adapter that uses `fetch`, the A3
  framer, strict `zttp:json`, and a bounded `for (const i of range(MAX))` loop
  with `break`. It calls the two M4 reference tools through `callTool`.
- The fixed proof profile is the one `test-reference-tools` asserts for the
  M4 tools, plus `no_secret_leakage` on the provider request body. Before any
  fixture is recorded, a hand-authored handler must pass it (A:629-633).
- The harness drives a deterministic loopback provider peer and real signed
  requests, as `test-reference-tools` does.
- This unit writes the R22 report section for agent routes: static
  Properties, runtime restrictions, observed events, and unknown outcomes, and
  the disclosure of section 5.

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
native-managed producer, chunked framing on HTTP/1.1, a turn deadline separate
from `request_timeout_ms` and `SO_SNDTIMEO`, reserved capacity for both
connection workers and runtimes, and admission before handler dispatch
(A:327-348). Preserve the parser restrictions of AE20. The design note answers
A's stream API decision (A:651).

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
| C-A1 | `test-zts`, `test-proof-checker`, `test-proof-checker-mutants`, `test-vocab-envelope-drift`, `test-zruntime` | An agent handler builds; its entry round-trips through `ZTCAT1` schema 4; a signed, well-formed prompt reaches the handler | An unsigned prompt gets 401 and no provider call; a malformed or oversized body gets 400 or 413; a missing or zero limit fails the build; a tool route that mentions `callTool` fails the build; an agent route that reaches a tool's export directly fails the build; a provider fetch past the round limit is refused; one mutated agent-entry byte refuses to start | Restore the allow-all on a null slot, and a test must fail. Allow a second grant push, and a test must fail. Census over the new refusal reasons |
| C-A2 | `test-zruntime`, `test-server` | A turn inside its limits completes and has a pre-record and a post-record per effect | AE10; AE13; a deadline between two calls starts no second effect and leaves `outcome_unknown`; after the latch closes, a provider fetch is refused; the cap refuses the next turn with 503 before any provider call | Remove the pre-effect record, and AE13 must fail. Remove the latch, and AE10 must fail |
| C-A3 | `test-modules`, `test-module-governance` | A fixed corpus of delimiter forms (LF, CRLF, CR), comment lines, multi-line data, `id`, `event`, and a leading BOM gives the expected events | Oversized event, oversized body, invalid UTF-8, and a final frame with no terminator each give their tag | Census over the framing-failure enum. The corpus must not be empty |
| C-A4 | `test-modules`, `test-zruntime`, `test-proof-swallow`, `test-capability-audit` | A listed tool runs with the caller's subject and tenant and gets a fresh request | AE2; AE3; AE6 live dedup: a repeated `callId` in one turn runs once; a catalog tool that is not in the agent's list; a tool whose output fails its schema is `tool_failed`, not an empty success | AE4, asserting `no_secret_leakage` both ways: a labelled tool result returned directly and through `callTool` is refused; a labelled value in the agent handler passed as `argsJson` to an echo tool and then returned is refused; a labelled value in the provider request body is refused. A clean value on each path stays admissible |
| C-A5 | the new step, `zig build test`, `bash scripts/verify.sh`, `test-runtime-purity` | A signed prompt reaches one tool call and one final answer through the loopback peer | AE5 non-stream part, as an adapter test; AE6 no-retry half; AE9 buffered part; AE11; AE15; AE17; AE19; AE21 | A probe that breaks the example must fail the step. The step fails when it ran no case |
| C-A6 | the measurement record | Numbers recorded with the command, the host, and the commit | Not applicable | Not a gate. The sub-minute run is recorded before any scaled run |

From the spec's examples, M5a applies AE2, AE3, AE4, AE5 (non-stream), AE6
(no-retry half and live dedup within one turn), AE9 (buffered part), AE10,
AE11, AE13, AE15, AE17, AE19, and AE21. M5b applies AE1, AE7, AE8, AE12, AE14,
AE16, AE20, and the stream parts of AE5 and AE9. AE18's positive release path
stays deferred with decision 6 of M4: agent catalogs, like tool catalogs,
refuse cross-call reads.

## 9. Out of scope

Persistent conversations, reconnection, crash recovery of a turn, parallel tool
calls, provider retry, mutating tools without an explicit retry contract,
provider-hosted tools, additional provider adapters, a model-field projection of
tool results, and a stored-data release operation. The HAL-FORMS projection and
sequential static composition stay parked from M4.

## 10. Open questions

None for the contract. Each unit's design note carries its own questions for the
owner.

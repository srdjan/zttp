# M5 A1 design note: the agent entry, its admission, and grants

Status: accepted by the owner on 2026-09-27, with the recommended answer to each
question in section 8 (section 9 records them). Revised once after a design
critique and a citation check before acceptance. Unit A1 of the
[M5 release contract](2026-09-27-m5-agent-handler-release-contract.md) is
written against the approach this note names; check C-A1 is its completion
check.

All citations are to local `main` at `8f1d70ec`.

## 1. What A1 must deliver

The contract asks for these. An agent entry in the `toolCatalog` literal, with
its route, its tool list, its provider grant, and required limits. `ZTCAT1`
schema 4 and a contract version bump. Admission of the agent route before the
handler runs (401, 400, 413). A prompt reader. An inert `callTool` export. And
grants: under the agent grant the only egress is a `fetch` to the provider
endpoint with the provider credential, the retry paths are refused, a null
grant under an agent handler refuses, one outer grant can be saved, and a turn
deadline that does not fit under the handler deadline refuses to serve.

A1 does not run a tool from an agent. `callTool` stays inert until A4, and the
turn state, round counting, and the recorder are A2.

## 2. What exists today

**The literal.** `buildToolCatalog` (`packages/zts/src/contract_builder.zig:1496`)
reads one module-scope `toolCatalog({...})` call. `readToolEntry` (`:1576`)
accepts the fields `route`, `description`, `input`, `output`, `maxInputBytes`,
and `scope` (`:1485`), the first five required (`:1486`). Each entry claims its
route; when the route table is static and no earlier catalog diagnostic exists,
an unclaimed route is `route_untooled` (`:1531-1542`). Entries reach
`contract.tools` only when no diagnostic was added (`:1550`). Refusals are ZTS513
with a `ToolCatalogRefusal` reason (`packages/zts/src/contract_types.zig:1514-1585`,
28 members). A census test requires each reason to have at least one case or a
stated exemption, and each case to produce exactly one refusal
(`contract_builder.zig:6639`, `:6712`, `:6729`, `:6743`).

**Reach and grants.** `collectToolExports` (`contract_builder.zig:1965`) walks
a route by mention and over-approximates. `checkToolDispatch` (`:1977`) refuses
any export but `zttp:router.routerMatch` in the shared dispatch. The cross-call
read table is at `:1832`. `checkToolFetchCall` (`:2217`) makes a credential
optional; when a call names one, the credential and the URL must be literals
(`:2264`).

**Carriage.** `ToolEntry` is at `contract_types.zig:1645`; the contract version
is 22 (`:2301`). The parser checks only for version 2, to pick its wire form,
and copies the rest (`contract_json_parser.zig:721`, `:738`). The writer emits
tools at `contract_json_writer.zig:263-323`. `ZTCAT1` is schema 3
(`packages/tools/src/tool_catalog_encoding.zig:17-20`); a comptime block refuses
an encoder that disagrees with the kernel (`:22-25`). The kernel decoder accepts
one exact schema (`packages/proof-checker/src/tool_catalog.zig:60`, `:269`); its
layout comment still says schema 2 (`:17`). Schema 2 inserted the scope fields
before the export count; schema 3 appended the credential names
(`tool_catalog_encoding.zig:70`, commit `f67c685a`). Each bump refuses the older
schema.

**Runtime.** `lowerAcceptedCatalog` (`packages/runtime/src/contract_runtime.zig:484-529`)
decodes, compiles both schemas per tool, and `crossCheckToolCatalog` (`:571-592`)
compares names, routes, bounds, scopes, and credentials with the contract. A
mismatch refuses to serve (`server.zig:2078-2110`). On a request, the server
matches the tool route, requires a loaded key (503), verifies the bearer token
(401), validates the input (413, 400), checks scope (403), and calls the handler
with `tool_grant = grantFor(tool)` (`server.zig:695-795`). A route that is not a
tool route runs with a null grant. Startup refuses a missing key only when a
catalog is already active; a dev catalog installed later gets a warning and a
503 per request (`server.zig:1700`, `live_reload.zig:575`).

**Grants at call time.** `ctx.active_tool_grant` (`packages/zts/src/context.zig:272`)
is one slot, set and cleared around one handler call
(`packages/runtime/src/handler_instance.zig:1460-1464`). `checkToolGrant`
returns at once when it is null (`module_binding/capabilities.zig:89`). The
engine `ToolGrant` (`context.zig:98`) has no credential thunk; the runtime view
adds one (`packages/runtime/src/http_types.zig:54`), and the credential check
reads the view, not the slot (`runtime_http.zig:917-928`). The grant is export
level: it admits `fetch` by name and says nothing about the URL.

**Egress and indirect execution.** These module exports send over the network:
`zttp:fetch.fetch`, `zttp:fetch.fetchWithRetry`, `zttp:service.serviceCall`, and
`zttp:io.parallel` and `race`, whose thunks call the wrapped fetch. A `fetch`
with `durable` set is a retry path: it retries every 5xx and a transport failure
(`runtime_http.zig:1292`). `zttp:io` declares only `.runtime_callback`, not
`.network` (`packages/zts/src/modules/workflow/io.zig:44`). `zttp:workflow`'s
`call`, `fanout`, and `follow` dispatch another handler in process, and the
request they build carries no tool grant
(`packages/zts/src/modules/workflow/workflow.zig:45`,
`packages/runtime/src/runtime_workflow.zig:107`). Two ambient natives,
`httpRequest` and `fetchSync` (`handler_instance.zig:498-499`), are refused by
the strict checker through `checkAmbientGlobal` (`packages/zts/src/strict_checker.zig:296`,
`known_globals.zig:14`) but are not gated by a grant at run time. No existing
classification names the whole set.

**Labels.** A binding's `return_labels` apply to the call result, including for
an export with no argument. A binding that declares `validated` sends its result
through `parsedResultLabels`, which clears `user_input` unconditionally
(`packages/zts/src/flow_checker.zig:1599`, `:1815`, `:2729`). `user_input`
without `validated` is what the egress and HTML checks look for
(`flow_checker.zig:67`, `:147`).

**`toolInput`.** It reads the `.body` of whatever object it receives, not the
bytes the runtime admitted (`packages/modules/src/http/tool.zig:75-84`). A
probe run while writing this note (not a tracked test) checked the label path:
a handler that passes `{ body: env("SECRET_KEY") }` to `toolInput` and returns
the value got ZTS400 "secret data flows into response body", as the direct leak
in `examples/handler/secret-leak.ts` does. A1 turns that probe into a test.

**Deadlines.** `HandlerInstance.init` refuses a zero outbound timeout
(`handler_instance.zig:252`); `initFromPool` does the same (`:371`). The
server's handler deadline defaults to 30 s (`server.zig:1331`, copied at
`:2443`); a standalone `RuntimeConfig` defaults it to 0, which disables it
(`runtime_config.zig:141-143`). The runtime config holds the raw catalog bytes,
not the accepted catalog, and `zttp dev` installs its catalog after start
through live reload (`live_reload.zig:600-621`).

**Hashes.** Adding a `zttp:tool` export moved the `frozen_signature_digest`
(`packages/tools/src/precompile_check.zig:1032`), the expert meta golden's
`module_registry_hash`, the module golden, the generated tool spec, the
virtual-modules table, and the language-overview counts (`d59055e6`); the
envelope's binding digests and hashes (`75d716a8`); and `EXPECTED_BUILTIN_HASH`
(`ef4286f0`). The policy hash covers each rule's name, code, category,
description, help, and repair tag (`packages/zts/src/rule_registry.zig:863`).
New `ToolCatalogRefusal` members alone do not move it; editing ZTS513's text
would.

## 3. The agent entry

An agent entry is an entry of the same `toolCatalog` literal that has an `agent`
field in place of `input` and `output`:

```ts
toolCatalog({
  convert: { route: "POST /tools/convert", /* as today */ },
  order_status: { /* as today */ },
  assistant: {
    route: "POST /agent",
    description: "Answer questions about the caller's orders.",
    maxInputBytes: 8192,
    agent: {
      tools: ["convert", "order_status"],
      provider: { endpoint: "https://api.deepseek.com/chat/completions", credential: "provider" },
      limits: {
        rounds: 4,
        toolCalls: 8,
        toolCallsPerRound: 4,
        argumentBytes: 4096,
        resultBytes: 16384,
        turnDeadlineMs: 20000
      }
    }
  }
});
```

`maxInputBytes` is the prompt bound on an agent entry; there is no second
prompt limit. Build rules, each a new `ToolCatalogRefusal` reason under ZTS513
with ZTS513's text unchanged:

- An entry has either `input` and `output` or `agent`, never both and never
  neither. `scope` is not allowed on an agent entry.
- `agent` holds exactly `tools`, `provider`, and `limits`, all literal. `tools`
  is a non-empty array of string literals, each the name of a tool entry in the
  same catalog, with no duplicate and no agent entry. `provider` holds a literal
  `endpoint` and a literal `credential` name; the credential must be a reference
  in `zttp.json` whose endpoint matches, by the existing `firstCredentialBreach`
  rule (`contract_types.zig:1734`). The endpoint is stored in its
  `endpoint.normalize` form.
- Every field of `limits` is required and is an integer literal from 1 to a
  named maximum: `rounds` 64, `toolCalls` 256, `toolCallsPerRound` at most
  `toolCalls`, `argumentBytes` and `resultBytes` at most the 1 MiB input ceiling
  (`tool_schema.max_input_bytes_ceiling`), and `turnDeadlineMs` 600000. These
  maxima are encoding bounds, not recommended values; A6 measures the defaults.
- The agent route's reach is walked like a tool route's. Each `fetch` it reaches
  takes the provider's literal endpoint as its URL and the provider's literal
  credential, and no `durable` option. It may not reach any other member of the
  egress set (section 5), `zttp:workflow` `call`, `fanout`, or `follow`,
  `zttp:queue.send`, `zttp:durable.signal`, any cross-call read, or any tool
  route function: a direct call to a tool's function would run that tool's code
  under the agent grant and outside `callTool`'s validation.
- `callTool` in a tool route is refused. The export exists from A1, inert.
- A tool handler may hold at most one agent entry in M5a (Q5).

The prompt body shape is fixed by the runtime, not declared. It is the schema
`{"type":"object","additionalProperties":false,"required":["version","prompt"],"properties":{"version":{"type":"integer","enum":[1]},"prompt":{"type":"string","minLength":1,"maxLength":N}}}`,
where `N` is the entry's `maxInputBytes`, validated by the tool validator. The
subset requires `maxLength` on every string (`packages/zts/src/tool_schema.zig:544`).
`maxLength` counts Unicode scalar values and a scalar is at least one byte, so
the byte bound on the whole body is always the tighter one.

## 4. Carriage

`ToolEntry` gains an optional `agent` member: the tool names, the provider
endpoint and credential name, and the six limits. For an agent entry the input
and output schema fields are empty and `credentials` is exactly the provider
credential.

`ZTCAT1` moves to schema 4. Each entry now starts with a u8 kind: 0 for a tool,
1 for an agent. A tool entry keeps the schema 3 layout after the kind byte. An
agent entry has the name, method, path, description, and `max_input_bytes`
(the prompt bound) as a tool has, then a u16 count and the tool names, the
provider endpoint, the provider credential name, and the six limits as u32. It
has no schema strings, no scope, and no export list; its grant is carried in
section 5's form. The kernel decoder refuses, each as its own decode error with
a mutant row in `proof_checker_mutants.zon`:

- a kind other than 0 or 1;
- tool names that are not strictly ascending, that name no tool entry, or that
  name an agent;
- an endpoint over `max_endpoint_bytes` or not in normalized form;
- a limit of 0 or above its named maximum;
- `toolCallsPerRound` above `toolCalls`;
- schema 3 input.

Because every agent field has one encoding and every relation is checked, two
byte strings cannot decode to one agent, and a one-byte mutation of any agent
field is either a decode error or a different agent that the cross-check
refuses. `docs/consumer-contract.md` section 4.6 gets the schema 4 layout and
history line, and the stale schema-2 comment in the decoder is corrected.

The contract version moves to 23. The writer emits an `agent` object on an agent
entry only. `crossCheckToolCatalog` compares every agent member. The envelope,
the consumer contract's version table, and `docs/contracts-and-sandboxing.md`
follow, as the v21 to v22 bump did (`5fdf94e8`).

## 5. Egress: build census and runtime refusal

**Build.** A1 adds one closed list, `egress_exports`, next to `cross_call_reads`
in `contract_builder.zig`: `zttp:fetch.fetch`, `zttp:fetch.fetchWithRetry`,
`zttp:service.serviceCall`, `zttp:io.parallel`, and `zttp:io.race`, and one list
`indirect_dispatch_exports`: `zttp:workflow` `call`, `fanout`, and `follow`. A
census test iterates every builtin binding and every installed global native
and requires each of these to be in a list or in an allowlist row that states
why it is neither: a module that declares `.network`; a module whose runtime
callbacks include the fetch executor; a module whose runtime callbacks dispatch
another handler; and an ambient native that performs I/O. A row that no export
matches fails the same test. That makes both lists a census, as AGENTS.md asks
after the cross-call class.

**Runtime.** The export grant cannot see a URL, so the agent grant view carries
three more fields: the normalized provider endpoint, the provider credential
name, and a no-durable flag. Under an agent grant, `runtime_http` refuses before
connect any fetch whose normalized URL is not the endpoint, that does not name
the provider credential, or that sets `durable`. The ambient `httpRequest` and
`fetchSync` refuse whenever any tool or agent grant is active (Q3).

**Outbound bounds.** Provider response bytes are bounded by
`outbound_max_response_bytes`, lowered per call by `max_response_bytes`; the
exchange is bounded by `outbound_timeout_ms`. There is no bound on the request
body a handler sends, so a large transcript is bounded only by the agent's own
code; A2 adds a provider request-byte bound to the turn state. For A2 to report
`outcome_unknown` at the turn deadline without cutting a fetch short, the
startup check of section 6 also requires `outbound_timeout_ms` below
`turnDeadlineMs`.

## 6. Admission, the prompt reader, and grants

**Admission.** The server matches an agent route in `AcceptedCatalog` as it
matches a tool route. It requires a loaded key (503), verifies the bearer token
(401), bounds the body by `maxInputBytes` (413), and validates it against the
constant prompt schema (400), before the handler runs.

**Prompt reader.** A new `zttp:tool` export `agentPrompt()` takes no argument.
It returns `Result<string>` with the admitted prompt, read from bytes the
runtime holds for the current request, and refuses outside an agent request.
Its return label is `user_input` only (Q2). It does not declare `validated`,
because the flow checker would then clear `user_input`, and R1 checks the shape,
which `requestText` also checks without clearing it. `toolInput` under the agent
grant refuses with `not_a_tool_request`: the agent grant carries no input schema.

**Inert `callTool`.** Declared with its final signature, `callTool(callId, name,
argsJson)`, returning `.result`, with `derives_from_args` and no static label
beyond that; A4 computes the ok arm's labels at the call site in the flow
checker, which does not touch the binding. So A4 does not move the binding
digest a second time. Calling it in A1 returns a `not_implemented` refusal.

**One frame stack.** The engine slot and the runtime view are separate objects
with separate readers, and A4 also swaps the request view (subject, tenant, and
pending arguments). A1 makes `HandlerInstance` own one stack of depth 2. Each
frame holds the grant view (export thunk, credential thunk, and the agent
fields of section 5) and the request view. The engine slot is written from the
top frame on every push and pop. A second push while one frame is saved
refuses. The handler-exit `defer` resets the whole stack, and a response that
completes with depth other than 1 is refused as a runtime fault. A test checks
that both readers agree after a push, a pop, and an unwind through an error.

**Null grant.** The refusal is keyed on the handler, not on an installed
catalog. When the handler's contract lists an agent entry (known at instance
init and at each dev live-reload compile), a module call under a null grant
refuses, except `zttp:router.routerMatch`, so an unmatched request still gets
the handler's 404. And a handler whose contract lists any catalog entry serves
503 on every route until an accepted or dev catalog is installed. That closes
the window in which a dev handler runs before live reload installs its catalog,
or after a dev lowering failure, with no grant at all (Q4).

**Turn deadline.** The check runs where the accepted catalog is known: at
promotion (`contract_runtime.zig:420-470`, before the pool is built, which
covers `zttp serve` and the self-extracting binary) and at the dev live-reload
install. It refuses when the handler deadline is 0, when `outbound_timeout_ms`
is not below `turnDeadlineMs`, or when `turnDeadlineMs` plus a margin is not
below the handler deadline. The contract placed this check in
`HandlerInstance.init`; that place cannot see the accepted catalog in every
mode, so this note moves it (Q7). The margin is a named constant, 1000 ms, not a
measured value; A6's sub-minute run measures terminal bookkeeping first and sets
it.

## 7. Files, gates, and hashes

Owned files, from the contract: `contract_types.zig`, `contract_builder.zig`,
`contract_json_writer.zig`, `contract_json_parser.zig`, `handler_policy.zig`,
`module_authorization.zig`, `module_binding/capabilities.zig`, `context.zig`,
`tool_catalog_encoding.zig`, the kernel `tool_catalog.zig`,
`handler_instance.zig`, `contract_runtime.zig`, `server.zig`, `tool_auth.zig`,
`packages/modules/src/http/tool.zig`, and the envelope source. Also needed:
`runtime_http.zig` and `http_types.zig` (the agent grant fields and the ambient
refusal), `runtime_workflow.zig` only if the build refusal needs a runtime twin,
`live_reload.zig` (the dev checks), `proof_checker_mutants.zon`, and
`docs/consumer-contract.md`. `handler_policy.zig` and `module_authorization.zig`
are listed by the contract but hold no tool state; A1 expects to leave them
unchanged.

ZTS513's text stays as it is, so the policy hash does not move. The two new
exports move every pin section 2 lists under "Hashes". Whether that makes DeepSeek
cassettes stale is measured: after the exports land, an unfiltered
`zig build test-expert-app` names every stale cassette. If any is stale, that
step fails until a re-record, which decides Q6.

Gates: `test-zts` (builder census with every new reason, the egress census, and
the `toolInput` label probe as a test), `test-proof-checker` and
`test-proof-checker-mutants` (one mutant row per new decoder guard; the step
runs its committed list and does not discover guards),
`test-vocab-envelope-drift`, `test-contract-golden`, `test-modules`,
`test-module-governance`, `test-expert-app`, `test-zruntime`, `test-server`, and
the full `zig build test` and `scripts/verify.sh` before the unit closes.

C-A1 additions from this note: a credential-free `fetch`, a `fetch` to another
URL, and a `durable` fetch under the agent grant are each refused at build and
at run time; a `workflow.call` in an agent route is refused at build; a dev
handler with a catalog serves 503 before install; both grant readers agree
after push, pop, and unwind.

## 8. Questions for the owner

- **Q1. Literal shape.** An agent is an entry of the same `toolCatalog` literal
  with an `agent` field (recommended: one catalog, one route claim rule, one
  artifact member), or a separate `agentCatalog` declaration.
- **Q2. Prompt label.** `agentPrompt()` returns `user_input` only (recommended:
  it keeps the injection and egress checks live, and blocks none of the
  properties A5 requires), or `user_input` with `validated`, which the flow
  checker turns into `validated` alone.
- **Q3. Ambient egress.** Refuse `httpRequest` and `fetchSync` at run time
  whenever any tool or agent grant is active (recommended: closes the gap for M4
  tool routes too, and the build already refuses them), or only under an agent
  grant.
- **Q4. Null grant.** Key the refusal on the handler's contract, and serve 503
  on every route of a catalog handler until its catalog is installed
  (recommended), or key it on the installed catalog, which leaves the dev window
  open.
- **Q5. One agent per handler.** Allow one agent entry per handler in M5a
  (recommended: the turn state and the concurrency cap are per agent), or
  several.
- **Q6. Re-record timing.** If A1 makes cassettes stale, re-record once at the
  close of A1 and again only if A3 or A4 moves the hashes again (recommended: no
  unit closes with a failing step), or carry the failure until one re-record
  after A4. Each re-record is a whole-corpus DeepSeek run that needs the owner's
  approval of that run.
- **Q7. Deadline check placement.** Move the contract's `HandlerInstance.init`
  check to catalog promotion and the dev install (recommended: the only places
  that see the accepted catalog in every mode), and record the change in the
  contract.
- **Q8. Workflow dispatch from tool routes.** A tool route can reach
  `workflow.call`, `fanout`, and `follow` today, and the dispatched handler runs
  with no grant. A1 refuses these in agent routes. Refuse them in tool routes
  too (recommended: it is the same escape, and no M4 example uses them), or
  leave M4 tool routes as they are and record the gap.

This default is recommended and is not a question unless the owner objects:
the kind byte first in each entry, with the tool layout otherwise unchanged
after it.

## 9. Decisions

The owner accepted the recommended answer to Q1 to Q8 on 2026-09-27, and the
default on the kind byte. For Q6 the owner approved the re-record runs it
names: one at the close of A1 if A1 makes cassettes stale, and another only if
A3 or A4 moves the hashes again. Q7 changes the contract's A1 text; the
contract records it.

## 10. Implementation units

A1 lands in four commits, each with its own tests passing unfiltered.

- **U1. Carriage.** The `agent` member in `ToolEntry`, the builder's reading
  of it and the new refusal reasons with census cases, contract version 23 in
  the writer and parser, `ZTCAT1` schema 4 in the encoder and the kernel
  decoder with one mutant row per new guard, the runtime cross-check, the
  consumer-contract section 4.6 text, and the envelope.
- **U2. Build rules and exports.** The egress and indirect-dispatch lists and
  their census, the agent-route reach rules, the workflow refusal in tool
  routes (Q8), the `callTool` placement refusal, the `agentPrompt` and inert
  `callTool` exports, the `toolInput` label probe as a test, and the hash pins.
- **U3. Runtime.** Agent admission, `agentPrompt`, the frame stack, the agent
  grant fields and their fetch refusals, the ambient refusal (Q3), the
  null-grant refusal and the 503 before install (Q4), and the deadline check at
  promotion and dev install (Q7).
- **U4. Close.** `test-expert-app`; the approved re-record if it is stale, then
  convergence and coverage in that order; the full gate; C-A1 evidence in this
  note.

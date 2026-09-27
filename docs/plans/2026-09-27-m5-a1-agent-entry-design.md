# M5 A1 design note: the agent entry, its admission, and grants

Status: proposed on 2026-09-27. It needs the owner's answers to section 8
before code starts. Unit A1 of the
[M5 release contract](2026-09-27-m5-agent-handler-release-contract.md) is
written against the approach this note names; check C-A1 is its completion
check.

All citations are to local `main` at `8f1d70ec`.

## 1. What A1 must deliver

The contract asks for six things. An agent entry in the `toolCatalog` literal,
with its route, its tool list, its provider grant, and required limits. `ZTCAT1`
schema 4 and a contract version bump. Admission of the agent route before the
handler runs (401, 400, 413). A prompt reader. An inert `callTool` export. And
grants: the agent route runs under a grant that admits one egress export, a
null grant under an agent handler refuses, one outer grant can be saved, and a
turn deadline that does not fit under the handler deadline refuses to serve.

A1 does not run a tool from an agent. `callTool` stays inert until A4, and the
turn state, round counting, and the recorder are A2.

## 2. What exists today

**The literal.** `buildToolCatalog` (`packages/zts/src/contract_builder.zig:1496`)
reads one module-scope `toolCatalog({...})` call. `readToolEntry` (`:1576`)
accepts the fields `route`, `description`, `input`, `output`, `maxInputBytes`,
and `scope` (`:1485`), the first five required (`:1486`). Each entry claims its
route; after all entries, an unclaimed route is `route_untooled` (`:1531-1542`).
Entries reach `contract.tools` only when no diagnostic was added (`:1550`).
Refusals are ZTS513 with a `ToolCatalogRefusal` reason
(`packages/zts/src/contract_types.zig:1514-1585`, 28 members), and a census test
requires each reason to be produced by exactly one case (`contract_builder.zig:6640-6743`).

**Reach and grants.** `collectToolExports` (`contract_builder.zig:1965`) walks
a route by mention and over-approximates. `checkToolDispatch` (`:1977`) refuses
any export but `zttp:router.routerMatch` in the shared dispatch. The cross-call
read table is at `:1832`. `checkToolFetchCall` (`:2217`) requires a literal URL
and a literal `credential` on a plain `fetch`.

**Carriage.** `ToolEntry` is at `contract_types.zig:1645`; the contract version
is 22 (`:2301`) and nothing checks it at parse time
(`contract_json_parser.zig:738`). The writer emits tools at
`contract_json_writer.zig:263-323`. `ZTCAT1` is schema 3
(`packages/tools/src/tool_catalog_encoding.zig:17-20`); a comptime block refuses
an encoder that disagrees with the kernel (`:22-25`). The kernel decoder accepts
one exact schema (`packages/proof-checker/src/tool_catalog.zig:60`, `:269`); its
layout comment still says schema 2 (`:17`). Each schema bump appends fields and
the kernel then refuses the older schema (`:46-51`).

**Runtime.** `lowerAcceptedCatalog` (`packages/runtime/src/contract_runtime.zig:484-529`)
decodes, compiles both schemas per tool, and `crossCheckToolCatalog` (`:571-592`)
compares names, routes, bounds, scopes, and credentials with the contract. A
mismatch refuses to serve (`server.zig:2078-2110`). On a request, the server
matches the tool route, requires a loaded key (503), verifies the bearer token
(401), validates the input (413, 400), checks scope (403), and calls the handler
with `tool_grant = grantFor(tool)` (`server.zig:695-795`). A route that is not a
tool route runs with a null grant.

**Grants at call time.** `ctx.active_tool_grant` (`packages/zts/src/context.zig:272`)
is one slot, set and cleared around one handler call
(`packages/runtime/src/handler_instance.zig:1460-1464`). `checkToolGrant`
returns at once when it is null (`module_binding/capabilities.zig:89`). The
engine `ToolGrant` (`context.zig:98`) has no credential thunk; the runtime view
adds one (`packages/runtime/src/http_types.zig:54`), and the credential check
reads the view, not the slot (`runtime_http.zig:917-928`).

**Egress.** These module exports send over the network: `zttp:fetch.fetch`
(which also carries durable fetch), `zttp:fetch.fetchWithRetry`,
`zttp:service.serviceCall`, and `zttp:io.parallel` and `race`, whose thunks call
the wrapped fetch. `zttp:io` declares only `.runtime_callback`, not `.network`
(`packages/zts/src/modules/workflow/io.zig:44`). Two ambient natives,
`httpRequest` and `fetchSync` (`handler_instance.zig:498-499`), are refused by
the strict checker (`packages/zts/src/strict_checker.zig:1994`, `:2034`) but are
not gated by a grant at run time. No existing classification names the whole set.

**Prompt input.** `toolInput` (`packages/modules/src/http/tool.zig:75-84`) reads
the `.body` of whatever object it receives, not the bytes the runtime admitted.
A probe on 2026-09-27 checked the label path: a handler that passes
`{ body: env("SECRET_KEY") }` to `toolInput` and returns the value gets ZTS400
"secret data flows into response body", the same diagnostic as the direct leak
in `examples/handler/secret-leak.ts`. The label is not laundered. The runtime
point stands: a reader for the prompt should read the admitted bytes.

**Deadlines.** `HandlerInstance.init` refuses only a zero outbound timeout
(`handler_instance.zig:252`, `:375`). The server's handler deadline defaults to
30 s (`server.zig:1331`, copied at `:2443`); a standalone `RuntimeConfig`
defaults it to 0, which disables it (`runtime_config.zig:141-143`). The runtime
config holds the raw catalog bytes, not the accepted catalog, and `zttp dev`
installs its catalog after start through live reload (`live_reload.zig:600-621`).
So `HandlerInstance.init` cannot see an agent entry in every mode.

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
    agent: {
      tools: ["convert", "order_status"],
      provider: { endpoint: "https://api.deepseek.com", credential: "provider" },
      limits: {
        rounds: 4,
        toolCalls: 8,
        toolCallsPerRound: 4,
        argumentBytes: 4096,
        resultBytes: 16384,
        promptBytes: 8192,
        turnDeadlineMs: 20000
      }
    }
  }
});
```

Build rules, each a new `ToolCatalogRefusal` reason under ZTS513:

- An entry has either `input` and `output` or `agent`, never both and never
  neither.
- `agent` holds exactly `tools`, `provider`, and `limits`, all literal. `tools`
  is a non-empty array of string literals, each the name of a tool entry in the
  same catalog, with no duplicate and no agent entry. `provider` holds a literal
  `endpoint` and a literal `credential` name, and the credential must be a
  reference in `zttp.json` whose endpoint matches, by the existing
  `firstCredentialBreach` rule (`contract_types.zig:1734`).
- Every field of `limits` is required and is a positive integer literal. Upper
  bounds: `argumentBytes` and `promptBytes` at most the 1 MiB input ceiling
  (`tool_schema.max_input_bytes_ceiling`), `toolCallsPerRound` at most
  `toolCalls`. `scope` is not allowed on an agent entry; the agent's tools scope
  their own calls.
- The agent route's reach is walked like a tool route's. It may reach
  `zttp:fetch.fetch` only with the provider's literal endpoint and credential.
  It may not reach any other member of the egress set (section 5), any
  cross-call read, or any tool route function: a direct call to a tool's
  function would run that tool's code under the agent grant and outside
  `callTool`'s validation. `callTool` in a tool route is refused (the export
  exists from A1, inert).
- A tool handler may hold at most one agent entry in M5a. This keeps the turn
  state of A2 to one agent per handler; the question is Q5.

The prompt shape is fixed by the runtime, not declared: `{version: 1, prompt:
string}` with `promptBytes` as the bound.

## 4. Carriage

`ToolEntry` gains an optional `agent` member: the tool name list, the provider
endpoint and credential, and the seven limits. For an agent entry the input and
output schema fields are empty; the encoder and the kernel check that an entry
has schemas exactly when it has no agent member.

`ZTCAT1` moves to schema 4 by appending, per entry, a u8 kind (0 tool, 1 agent)
and, for an agent, a u16 count of tool names and the names in catalog order, the
provider endpoint, and the seven limits as u32. The kernel decoder bounds each
field, refuses a tool name that is not an earlier or later tool entry, an agent
listed as a tool, a zero limit, and `toolCallsPerRound` above `toolCalls`, and
then refuses schema 3. `docs/consumer-contract.md` section 4.6 gets the schema 4
history line; the stale schema-2 comment in the decoder is corrected.

The contract version moves to 23; the writer emits an `agent` object on an agent
entry only, so a catalog with no agent keeps its bytes apart from the version.
`crossCheckToolCatalog` compares the agent members. The envelope, the consumer
contract's version table, and `docs/contracts-and-sandboxing.md` follow, as the
v21 to v22 bump did (`5fdf94e8`).

## 5. The egress set

A1 adds one closed list, `egress_exports`, next to `cross_call_reads` in
`contract_builder.zig`: `zttp:fetch.fetch`, `zttp:fetch.fetchWithRetry`,
`zttp:service.serviceCall`, `zttp:io.parallel`, and `zttp:io.race`. A test
iterates every builtin binding and requires each export whose module declares
`.network`, and each `zttp:io` export, to be in the list or in an allowlist row
that states why it is not egress. That turns the list into a census rather than
a memory, which is the lesson of the cross-call class in AGENTS.md.

At run time the agent grant is an export list like a tool grant. Its computation
is the agent route's reach, with the build rules of section 3 already applied,
so under it only `fetch` is an egress export. The ambient `httpRequest` and
`fetchSync` gain a runtime refusal whenever a tool or agent grant is active,
which closes the gap for every catalog handler, not only agents.

## 6. Admission, the prompt reader, and grants

**Admission.** The server matches an agent route in `AcceptedCatalog` as it
matches a tool route. It requires a loaded key (503), verifies the bearer token
(401), bounds the body by `promptBytes` (413), and validates it against the
fixed prompt shape with the tool validator (400), before the handler runs. An
agent handler with no `auth` refuses to start, as a tool handler does
(`server.zig:1700-1721`).

**Prompt reader.** A new `zttp:tool` export `agentPrompt()` takes no argument.
It returns `Result<string>` with the admitted prompt, read from bytes the
runtime holds for the current request, and refuses outside an agent request.
Its return labels are `user_input` joined with `validated` (Q2). A handler
cannot hand it another object, so the `toolInput` shape of section 2 does not
recur.

**Inert `callTool`.** Declared with its final signature and labels so that A4
does not move the binding digest a second time. Calling it in A1 returns a
`not_implemented` refusal. It is refused by the build outside an agent route.

**Grants.** The runtime view and the engine slot become a two-level stack: the
current grant and at most one saved outer grant, each holding the export thunk
and the credential thunk together. `enterNested` saves the current grant and
installs the inner one; a second `enterNested` while one is saved refuses.
`leaveNested` restores on every exit path, including a thrown error. A1 exposes
the stack to A4 and tests it directly; nothing in A1 nests.

**Null grant.** When the accepted catalog holds an agent entry, a module call
with a null grant refuses with a new `tool_grant` reason instead of passing.
Handlers with no agent entry keep today's behavior. The recommendation is to
keep that change narrow in M5a (Q4).

**Turn deadline.** The check runs where the accepted catalog is known: at
promotion (`contract_runtime.zig:420-470`, before the pool is built) and at the
dev live-reload install. It refuses when the handler deadline is 0 or when
`turnDeadlineMs` plus a fixed margin is not below the handler deadline. The
margin is a named constant, 1000 ms, which A6 revisits with measurements.

## 7. Files, diagnostics, gates, and hashes

Owned files, from the contract: `contract_types.zig`, `contract_builder.zig`,
`contract_json_writer.zig`, `contract_json_parser.zig`, `handler_policy.zig`,
`module_authorization.zig`, `module_binding/capabilities.zig`, `context.zig`,
`tool_catalog_encoding.zig`, the kernel `tool_catalog.zig`,
`handler_instance.zig`, `contract_runtime.zig`, `server.zig`, `tool_auth.zig`,
`packages/modules/src/http/tool.zig`, and the envelope source. Also needed:
`runtime_http.zig` and `http_types.zig` (the credential half of the stack),
`live_reload.zig` (the dev install check), and `strict_checker.zig` only if the
ambient refusal needs a hook there. `handler_policy.zig` and
`module_authorization.zig` are listed by the contract but section 2 shows they
hold no tool state; A1 expects to leave them unchanged.

No new ZTS code: every build refusal is a ZTS513 reason, so the policy hash does
not move. The two new exports move the `zttp:tool` binding digest, the module
registry hash, `frozen_signature_digest`, the module golden, the expert meta
golden, the envelope, `EXPECTED_BUILTIN_HASH`, the generated module spec, and the
virtual-modules table, as `d59055e6` and `75d716a8` did. M4 T2 needed a
DeepSeek re-record for a change of this kind. Whether A1's change makes the
cassettes stale is measured, not assumed: after the exports land, an unfiltered
`zig build test-expert-app` names every stale cassette. If any is stale, that
step fails until a re-record, which decides Q6.

Gates: `test-zts` (builder census with every new reason), `test-proof-checker`
and `test-proof-checker-mutants` (new decoder guards need mutant rows),
`test-vocab-envelope-drift`, `test-contract-golden`, `test-modules`,
`test-module-governance`, `test-zruntime`, `test-server`, and the full
`zig build test` and `scripts/verify.sh` before the unit closes.

## 8. Questions for the owner

- **Q1. Literal shape.** An agent is an entry of the same `toolCatalog` literal
  with an `agent` field (recommended: one catalog, one route claim rule, one
  artifact member), or a separate `agentCatalog` declaration.
- **Q2. Prompt labels.** `agentPrompt()` returns `user_input` joined with
  `validated` (recommended: the runtime checked the shape, not the content), or
  `validated` only, which would let a prompt reach sinks that refuse user input
  today.
- **Q3. Ambient egress.** Refuse `httpRequest` and `fetchSync` at run time
  whenever any tool or agent grant is active (recommended: closes the gap for
  M4 tool routes too, and the strict checker already refuses them at build), or
  only under an agent grant.
- **Q4. Null grant.** Refuse a null grant only in handlers with an agent entry
  (recommended for M5a: no change for existing tool handlers), or in every
  handler with a catalog, which would also cover an M4 handler's shared
  dispatch.
- **Q5. One agent per handler.** Allow one agent entry per handler in M5a
  (recommended: the turn state and the concurrency cap are per agent), or
  several.

- **Q6. Re-record timing.** If A1 makes cassettes stale, re-record once at the
  close of A1 and again only if A3 or A4 moves the hashes again (recommended: no
  unit closes with a failing step), or carry the failure until one re-record
  after A4, as the contract first budgeted. Each re-record is a whole-corpus
  DeepSeek run that needs the owner's approval of that run.

These defaults are recommended and are not questions unless the owner objects:
the kind byte and append-only layout of schema 4; the fixed 1000 ms margin until
A6; `callTool` declared inert with its final signature.

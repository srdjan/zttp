# M5 A4 design note: `callTool`

Status: proposed on 2026-09-28. It needs the owner's answers to section 9 before
code starts. Unit A4 of the
[M5 release contract](2026-09-27-m5-agent-handler-release-contract.md) is
written against the approach this note names; check C-A4 is its completion
check.

All citations are to local `main` at `365931a8`.

## 1. What A4 must deliver

The contract (A4, C-A4) asks for these. `callTool(callId, name, argsJson)` runs a
tool the agent entry lists, in the agent's runtime, under that tool's grant, with
a fresh request holding the verified subject, tenant, and the pending arguments
only. It validates the arguments and the output, enforces the call budgets,
refuses a duplicate call identity within a round, records a pre-record and a
post-record per call, and returns a `Result` whose error arm carries a tag only:
`unknown_tool`, `invalid_arguments`, `tool_denied`, `tool_failed`,
`budget_exhausted`, `deadline_exceeded`, or `outcome_unknown`. The flow checker
labels the ok arm with the labels of `argsJson` joined with what the listed
tools can return. A4 also carries the `zttp:fetch` summary and the `error?` and
`details?` return fields that A2 deferred, and the one whole-corpus re-record
the contract budgets, which also covers A3's registration (A3 note, section 5).

## 2. What exists today

**The inert export.** `callTool` has its final signature: three strings,
`effect = .write`, `returns = .result`, `derives_from_args`, no labels
(`packages/modules/src/http/tool.zig:62-71`); its implementation refuses with
`not_implemented` (`:118-120`). `toolInput` reads `args[1].body` from the JS
request it is given after checking the active input schema name (`:98-107`), so a
nested request whose body is the pending arguments reaches it with no change;
`createRequestObject` sets the body, subject, and tenant from the active view
(`packages/runtime/src/handler_instance.zig:1840`, `:1872-1888`).

**Frames.** `frames: [2]Frame`, `Frame{request, pending_args}`, and
`enterNested`, `leaveNested`, `resetFrames`, `checkResponseDepth`
(`handler_instance.zig:157-228`). `enterNested` requires depth 1 and clears the
nested request's `turn` (`:204-211`); the turn stays reachable through
`frames[0]`. `syncFrame` rebuilds the engine grant slot from the top frame
(`:190-202`). The only nested use today is a test (`runtime_http.zig:3090-3148`).

**Grants and the catalog.** `tool_auth.grantFor(*const AcceptedTool)` builds a
tool grant from a pointer that must outlive the call (`tool_auth.zig:185-187`);
`agentGrantFor` puts the `*const AcceptedAgent` in the grant's context
(`:191-203`). `AcceptedAgent.tools` holds names only
(`contract_runtime.zig:140`), and `HandlerInstance` holds no catalog pointer; the
server reads the catalog under the contract lock (`server.zig:727`).

**Routing.** The runtime has no route table. `routerMatch` is module code that
matches a `"METHOD /path"` key in the handler's own JS table and returns
`{handler, params}` (`packages/modules/src/http/router.zig:27-75`), and the
handler calls the match (`examples/tools/tools.ts:111-117`). So native code can
reach a tool's route function only by invoking the handler
(`cached_handler_obj`, `handler_instance.zig:125`, `:1513-1516`, `:1619`) with a
request whose method and path are the tool's. A route with a `:param` segment
needs a concrete path.

**Reusable checks.** `validateToolInput` and `validateToolOutput` take a scratch
allocator, a `*const AcceptedTool`, and bytes, and return a verdict
(`contract_runtime.zig:237`, `:252-259`); `validateToolOutput` has a size limit
(`:246`) and the server applies it to 2xx only (`server.zig:938-963`).
`tool_auth.checkScope` compares a tool's bound input fields with the verified
subject and tenant (`tool_auth.zig:137-157`).

**Turn state.** `TurnState` already has `tool_calls_total`,
`tool_calls_current_round`, the call-identity list (a SHA-256 digest each, with
capacity `toolCalls`), the latch, and the terminal precedence
(`packages/runtime/src/turn_state.zig:19-148`). The recorder has
`Effect.tool_call` and requires a call identity for it
(`turn_recorder.zig:21-24`, `:486-491`); `TerminalTag` already names
`tool_denied` and `tool_failed` (`:37-60`). Its `appendPre` and `appendPost` are
fixed to provider fetches (`:304-344`); `append(Record)` is general (`:263`).

**The flow checker.** `callTool` has no labels, so its result takes the union of
all three arguments' labels through `argDerivedLabels`
(`packages/zts/src/flow_checker.zig:1616-1623`, `:1835-1837`). No tool output
labels exist anywhere: `ToolEntry` has an output schema and no labels
(`contract_types.zig:1793-1826`), and the flow checker runs before the contract
is built and has no catalog (`packages/tools/src/precompile.zig:1721`, `:1807`).
But the flow checker checks every route of the handler, tool routes included,
and a tool route's returned `Response` is a response sink like any other. A handler that
returns an `env()` secret is refused at build with ZTS400 (the probe recorded in
the A1 note, section 2); that the same holds for a tool route reached through
`routerMatch` is what A4's first probe must show.

## 3. The call, step by step

`callTool` gets a zts wrapper with installed state, like `zttp:fetch`
(`packages/zts/src/modules/net/fetch.zig:30-102`), so the module reaches the
runtime through a callback. At lowering, each `AcceptedAgent` resolves its tool
names to `*const AcceptedTool` pointers in the same catalog (Q2).

1. Refuse outside an agent turn, or inside a nested frame (depth must be 1).
2. Refuse if the turn's latch is closed, with its tag, or if the turn deadline
   has passed (`deadline_exceeded`, which closes the latch).
3. Resolve `name` against the agent's tool list; a miss is `unknown_tool`, which
   counts against the call budget and does not close the latch.
4. Count the call: if `tool_calls_total == toolCalls` or
   `tool_calls_current_round == toolCallsPerRound`, refuse with
   `budget_exhausted` and close the latch. Every call that reaches this step
   counts, valid or not.
5. Compose the call identity (SHA-256 of turn identity, round ordinal, and
   `callId`) and refuse a duplicate within the round with `invalid_arguments`.
6. Refuse `argsJson` longer than `argumentBytes` (`budget_exhausted`, closes the
   latch). Validate it with `validateToolInput`; a refusal is
   `invalid_arguments`, which does not close the latch. Apply `checkScope`; a
   mismatch is `tool_denied`, which closes the latch.
7. Write the pre-record (`tool_call`, call identity, the tool name, the
   authorization decision). A sink failure is `recorder_unavailable` and closes
   the latch.
8. `enterNested` with the tool's grant and a fresh request: the tool's method
   and path, `argsJson` as the body, the frame-0 subject and tenant, no headers,
   no query, and no turn. Invoke the handler, which dispatches to the tool's
   route through `routerMatch` under the tool's grant. `leaveNested` on every
   exit.
9. Classify (section 4), validate a 2xx body with `validateToolOutput` and
   against `resultBytes`, write the post-record, and return.

The runtime refuses nothing at step 8 that M4 would not refuse for the same tool
on an HTTP request; the tool runs under its own grant, credential grant, and
ceiling. A fetch inside the tool is a tool effect, not a provider round, because
the nested frame has no turn.

## 4. Outcomes

- **completed:** the tool returned a 2xx response whose body passes
  `validateToolOutput` and fits `resultBytes`. The ok arm is the parsed body.
- **tool_failed:** the tool returned a non-2xx response, or a 2xx body that
  fails output validation or exceeds `resultBytes`. The tool answered, so its
  outcome is established; the latch closes, as the contract requires.
- **outcome_unknown:** the tool did not return: it threw, the handler deadline
  interrupted it, or a runtime fault ended it. Effects inside it may have
  happened, so R18 forbids reporting it as not run. The latch closes.

The error arm carries the tag only. No tool body, argument, or validator detail
reaches the adapter through it.

## 5. Labels

The flow checker gives `callTool`'s ok arm the labels of `argsJson`, joined with
`.external` (Q3). `.external` marks data that crossed a boundary the handler did
not compute, which is what a tool's answer is to the agent. No secret or
credential label is added, and the design rests on one fact that A4 proves with
a probe rather than assumes: every tool the agent lists is a route of the same
handler, the flow checker checks that route's returned `Response` as a
disclosure sink, and so a tool that could return a labelled secret or credential
fails the handler's build before `callTool` can carry it. The probes C-A4 names:

- a tool route that returns an `env()` secret is refused (ZTS400), so the handler
  never reaches an agent that calls it;
- a labelled value in the agent handler passed as `argsJson` to an echo tool and
  then sent to the provider or returned is refused, because the argument labels
  flow through;
- the same paths with clean values stay admissible.

The rule is placed at the call site in `inferCallLabels`, matching module
`tool`, function `callTool`, before the generic argument-derived branch
(`flow_checker.zig:1835`). `flow_checker.zig` is a proof-swallow file, so the
change runs `test-proof-swallow`.

## 6. Build rules

A4 adds one catalog rule: a tool that an agent lists may not have a `:param`
segment in its route, because `callTool` supplies a body, not path parameters
(Q4). It is a new `ToolCatalogRefusal` reason under ZTS513, with its census case.

## 7. The deferred `zttp:fetch` change and the re-record

`zttp:fetch` gains its summary, naming the `AgentTurnRefused` tag set, and the
`error?` and `details?` fields in both return signatures. Then A3's registration
lands (A3 note, section 10, U3). Both move the module hashes; the pins move with
them; and the one whole-corpus DeepSeek re-record runs once, followed by
convergence and coverage in their own commits.

## 8. Files, gates, and cases

Changed: `packages/modules/src/http/tool.zig` and a new zts wrapper for
`zttp:tool`'s state, `packages/zts/src/modules/internal/resolver.zig` or the
equivalent installation point, `handler_instance.zig` (the callback, the nested
call), `contract_runtime.zig` (resolved tool pointers), `turn_state.zig` and
`turn_recorder.zig` (tool records), `packages/zts/src/flow_checker.zig`,
`contract_builder.zig` and `contract_types.zig` (the `:param` rule),
`packages/modules/src/net/fetch.zig` and the pins, and `docs/user-guide.md`.

Gates: `test-modules`, `test-zts`, `test-zruntime`, `test-server`,
`test-proof-swallow`, `test-capability-audit`, `test-contract-golden`,
`test-reference-tools`, `test-module-governance`, the drift scripts,
`test-expert-app` after the re-record, and the full `zig build test` and
`scripts/verify.sh`.

C-A4 cases, through a loopback provider peer and a loopback tool upstream that
count connections and requests:

- AE2: an unknown name, a catalog tool the agent does not list, and an agent
  entry named as a tool each answer `unknown_tool` with zero tool effects;
- AE3: `order_status` with another tenant's `tenant_id` answers `tool_denied`
  and the upstream sees no request;
- AE6 live dedup: a repeated `callId` in one round runs once;
- AE10: a failure mid-round closes the latch, later calls and the next provider
  fetch are refused, and earlier effects stand;
- AE13 for tool effects: a sink failure before a tool call starts no tool
  effect; a failed post-record returns the tool's result and closes the latch;
- repeated invalid calls exhaust the call budget;
- `argumentBytes` and `resultBytes` at and over the bound;
- a non-2xx tool, a 2xx tool that fails output validation, and a tool that
  throws, answering `tool_failed`, `tool_failed`, and `outcome_unknown`;
- a nested fetch inside a tool counts no provider round;
- `callTool` in a tool route fails the build (existing), and a `:param` tool in
  an agent list fails the build;
- the label probes of section 5, asserting `no_secret_leakage`, never a
  neighbour.

A census covers every error tag. Non-vacuity: remove the duplicate check, the
scope check, the budget check, and the label rule in turn, and a test must fail
each time.

## 9. Questions for the owner

- **Q1. Invoking the tool.** Re-invoke the handler with a synthetic request
  whose method and path are the tool's, so `routerMatch` dispatches it under the
  tool's grant (recommended: it is the only route to the function that exists,
  and the tool runs exactly as it does for an HTTP request), or add a native
  route table to the runtime.
- **Q2. Resolve tool pointers at lowering** (recommended: the pointers live as
  long as the accepted catalog, and no lookup happens under the contract lock
  per call), or look the tool up by name on each call.
- **Q3. Result labels.** `argsJson`'s labels joined with `.external`, resting on
  the tool routes' own response checks, proven by probes (recommended), or a
  per-tool summary of each route's return labels in the flow checker, which is
  more precise and much larger.
- **Q4. Refuse `:param` routes in an agent's tool list** (recommended for M5a),
  or fill path parameters from named argument fields.
- **Q5. Which failures close the latch.** `tool_denied`, `tool_failed`,
  `outcome_unknown`, `budget_exhausted`, and `deadline_exceeded` close it;
  `unknown_tool` and `invalid_arguments` do not, so a model can correct a bad
  call within its budget (recommended), or every failure closes it.

These defaults are recommended and are not questions unless the owner objects:
the step order of section 3; every call that reaches step 4 counts against the
budgets; tag-only error arms; a thrown tool is `outcome_unknown`.

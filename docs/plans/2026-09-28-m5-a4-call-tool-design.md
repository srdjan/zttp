# M5 A4 design note: `callTool`

Status: proposed on 2026-09-28. It needs the owner's answers to section 9 before
code starts. Unit A4 of the
[M5 release contract](2026-09-27-m5-agent-handler-release-contract.md) is
written against the approach this note names; check C-A4 is its completion
check.

Code citations are to local `main` at `80877dd6`.

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
handler calls the match (`examples/tools/tools.ts:110-115`). So native code can
reach a tool's route function only by invoking the handler
(`cached_handler_obj`, `handler_instance.zig:125`, `:1513-1516`, `:1619`) with a
request whose method and path are the tool's. A route with a `:param` segment
needs a concrete path. The build already matches each catalog route key to a
resolved function in the handler's route table
(`packages/zts/src/contract_builder.zig:1659-1677`, `:4824-4867`). A4 must
also check at runtime that the synthetic request invokes that function.

The two M4 reference tools read these request fields. The common handler uses
`method` and `url` for `routerMatch`; `path` is its fallback only when `url`
is absent (`packages/modules/src/http/router.zig:35-42`). The synthetic
request sets both `url` and `path`. Each tool uses `toolInput` to read `body`
(`packages/modules/src/http/tool.zig:102-110`):

| Tool route | Fields read for dispatch | Fields read by the tool function |
|---|---|---|
| `convert` (`examples/tools/tools.ts:58-65`) | `method`, `url` | `body` through `toolInput` |
| `order_status` (`examples/tools/tools.ts:87-95`) | `method`, `url` | `body` through `toolInput` |

Neither function reads `query`, `headers`, `path`, `subject`, or `tenant`.
`order_status` reads `tenant_id` from the validated body. The runtime compares
that field with the verified tenant before the function runs
(`packages/runtime/src/tool_auth.zig:131-156`).

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

**The corrected flow checker.** The inert binding still has no static return
labels and declares `derives_from_args` (`packages/modules/src/http/tool.zig:62-73`).
The generic call rule therefore merges all three argument labels today
(`packages/zts/src/flow_checker.zig:2116-2145`). The corrected analyzer also
walks each resolved `routerMatch` route as a request root and joins the return
labels of the routes a dispatch can reach (`flow_checker.zig:1001-1021`,
`:2210-2213`, `:2254-2271`). An unresolved route contributes `.unknown` and
clears the flow proofs (`:2274-2283`). Its tests cover a routed secret and a
dispatch whose routes return different labels (`:5226`, `:5386`).

`ToolEntry` has an output schema but no stored route-return labels
(`contract_types.zig:1793-1826`). The flow check runs before contract construction
(`packages/tools/src/precompile.zig:1721-1729`, `:1807`). A4 must bridge the
accepted catalog's agent-to-tool-to-route mapping into that check. The route
analysis now supplies the return-label summaries; it does not yet connect them
to `callTool`.

## 3. The call, step by step

`callTool` gets a zts wrapper with installed state, like `zttp:fetch`
(`packages/zts/src/modules/net/fetch.zig:30-102`), so the module reaches the
runtime through a callback. At lowering, each `AcceptedAgent` resolves its tool
names to `*const AcceptedTool` pointers in the same catalog (Q2).

1. Refuse outside an agent turn, or inside a nested frame (depth must be 1).
2. Refuse if the turn's latch is closed, with its tag, or if the turn deadline
   has passed (`deadline_exceeded`, which closes the latch).
3. Check and spend the call budget before resolving `name`: if
   `tool_calls_total == toolCalls` or
   `tool_calls_current_round == toolCallsPerRound`, refuse with
   `budget_exhausted` and close the latch. Every admitted attempt counts,
   including an unknown name and invalid arguments.
4. Resolve `name` against the agent's tool list. A miss is `unknown_tool` and
   does not close the latch.
5. Compose the call identity (SHA-256 of turn identity, round ordinal, and
   `callId`) and refuse a duplicate within the round with `invalid_arguments`.
6. Refuse `argsJson` longer than `argumentBytes` (`budget_exhausted`, closes the
   latch). Validate it with `validateToolInput`; a refusal is
   `invalid_arguments`, which does not close the latch. Apply `checkScope`; a
   mismatch is `tool_denied`, which closes the latch.
7. Recheck the deadline. Write the pre-record (`tool_call`, call identity, the
   tool name, the authorization decision). A sink failure is
   `recorder_unavailable` and closes the latch.
8. Immediately after the pre-record succeeds, mark the tool in flight in
   `TurnState`. Then `enterNested` with the tool's grant and a fresh request:
   the tool's method and path, `argsJson` as the body, the frame-0 subject and
   tenant, no headers, no query, and no turn. Invoke the handler, which
   dispatches to the tool's route through `routerMatch` under the tool's
   grant. Recheck the deadline before invoking the handler. A deadline here
   follows the pre-record, so it is `outcome_unknown`. `leaveNested` on every
   exit.
9. Classify (section 4), validate a 2xx body with `validateToolOutput` and
   against `resultBytes`, write the post-record, clear the in-flight marker,
   and return. A deadline or runtime exit before that point leaves the marker
   set for terminal classification.

M4's tool grant, credential grant, and ceiling checks still apply to the
nested call. The turn deadline adds a limit to those checks. A fetch inside
the tool is a tool effect, not a provider round, because
the nested frame has no turn. The fetch path must also read the outer turn's
absolute deadline from frame 0 and cap its connect, handshake, and exchange
timeout to the remaining turn time. It must recheck that deadline before
opening a connection. The current timeout helper reads only the active
request's turn (`packages/runtime/src/runtime_http.zig:46-65`), so the nested
frame would otherwise lose this cap. If that cap ends a fetch, the fetch path
marks the outer turn's tool outcome unknown. A tool route cannot turn that
deadline into `tool_failed` by catching `TimedOut` and returning a 502.

## 4. Outcomes

- **completed:** the tool returned a 2xx response whose body passes
  `validateToolOutput` and fits `resultBytes`. The ok arm is the parsed body.
- **tool_failed:** the tool returned a non-2xx response, or a 2xx body that
  fails output validation or exceeds `resultBytes`. The tool answered, so its
  outcome is established; the latch closes, as the contract requires.
- **outcome_unknown:** the tool did not return: it threw, the turn or handler
  deadline interrupted it, or a runtime fault ended it. Effects inside it may
  have happened, so R18 forbids reporting it as not run. The latch closes.

The terminal path checks the in-flight marker before classing a timeout as
`deadline_exceeded`. A deadline before the tool pre-record has no tool effect
and gives `deadline_exceeded`; a deadline after the pre-record while the tool
is in flight gives `outcome_unknown`, even if the handler is interrupted and
cannot run the normal post-record path. After the handler returns, the call
also checks whether the turn deadline passed or a nested fetch hit the turn
cap before it accepts a 2xx or non-2xx result. Either case is
`outcome_unknown`. The terminal record and latch keep `outcome_unknown` ahead
of `deadline_exceeded`, as A2 already requires.

The error arm carries the tag only. No tool body, argument, or validator detail
reaches the adapter through it.

## 5. Labels

The contract fixes the ok arm's label rule:

`labels(callTool(...).value) = labels(argsJson) ∪ ⋃ routeReturnLabels(tool)`

The union ranges over every tool in the current agent entry's `tools` list,
not only the runtime value of `name`. The model chooses `name`, so a secret
return from any listed tool must label every possible result. The return
labels come from the corrected analyzer's summaries of those tools' route
functions. They include labels from the response payload; the route's own
response sink is still checked. The other arguments, `callId` and `name`, do
not label the ok value. The error arm carries a fixed tag only.

Before the flow check, A4 extracts the agent-to-tool-to-route mapping from the
literal catalog with the same rules the contract builder uses. It resolves
each listed route key to its function in the stable `routerMatch` table and
passes that mapping to the flow checker. The checker computes each route's
return-label summary, joins all listed tools' summaries, and joins that set
with `argsJson` at each `callTool` call site. If a listed route or its function
cannot be resolved, the result carries `.unknown` and the affected proofs
cannot pass. The accepted catalog must use the same mapping, so analysis and
runtime dispatch cannot disagree. This changes call-site inference, not the
inert export's binding or the on-disk tool catalog format.

The C-A4 probes assert `no_secret_leakage` for a labelled tool result returned
directly and through `callTool`, and for a labelled `argsJson` sent through an
echo tool. A second listed tool with a secret result must label a call whose
runtime `name` selects a clean tool. A clean result and clean arguments must
stay admissible. An unresolved listed route must fail closed. The secret
route's own response sink can refuse the build before the `callTool` rule is
used. A separate call-site probe lists two tools. One returns `req.url`,
which carries `user_input` but is admissible in `Response.json`; the other
returns a clean value and is the literal `name` passed to `callTool`. The
agent sends the `callTool` result to an egress URL. The probe asserts
`injection_safe` is unproven at that egress sink. Removing only the
listed-tool union must make this probe fail while the route-root checks stay
enabled.

The rule belongs at the call site in `inferCallLabels`, before the generic
argument-derived branch (`flow_checker.zig:2116-2145`). `flow_checker.zig` is a
proof-swallow file, so the change runs `test-proof-swallow`.

## 6. Build rules

A4 adds one catalog rule: a tool that an agent lists may not have a `:param`
segment in its route, because `callTool` supplies a body, not path parameters
(Q3). It is a new `ToolCatalogRefusal` reason under ZTS513, with its census case.

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
call), `contract_runtime.zig` (resolved tool pointers), `turn_state.zig`
(the in-flight marker), `turn_recorder.zig` (tool records), `server.zig`
(terminal classification), `runtime_http.zig` (the nested fetch deadline),
`packages/zts/src/flow_checker.zig`, `route_resolution.zig`, and
`packages/tools/src/precompile.zig` (the listed-route label mapping),
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
- an unknown name spends one call, and the exhausted budget takes precedence
  over `unknown_tool` on the next attempt;
- `argumentBytes` and `resultBytes` at and over the bound;
- a non-2xx tool, a 2xx tool that fails output validation, and a tool that
  throws, answering `tool_failed`, `tool_failed`, and `outcome_unknown`;
- a nested fetch inside a tool counts no provider round;
- a tool fetch that stalls is stopped by the turn deadline, with
  `outcome_unknown` in the call, latch, and terminal record; a deadline before
  the pre-record gives `deadline_exceeded` and no tool effect;
- a tool that catches the nested fetch's turn-deadline timeout and returns a
  502 still gives `outcome_unknown`;
- each listed M4 tool, reached through `callTool` with its own valid body,
  produces its distinctive response and increments a counter inside its own
  route function. This proves the synthetic request reached `convert` or
  `orderStatus`, not only the handler's fallback or another route;
- `callTool` in a tool route fails the build (existing), and a `:param` tool in
  an agent list fails the build;
- the label probes of section 5, asserting `no_secret_leakage`, never a
  neighbour for secret leakage; the independent `injection_safe` call-site
  probe checks the listed-tool union.

A census covers every error tag. Non-vacuity: remove the duplicate check, the
scope check, the budget check, the in-flight terminal check, the nested fetch
deadline cap, and the listed-tool label union in turn, and a test must fail
each time. The label mutation keeps route-root checks enabled.

## 9. Questions for the owner

- **Q1. Invoking the tool.** Re-invoke the handler with a synthetic request
  whose method and path are the tool's, so `routerMatch` dispatches it under the
  tool's grant (recommended: it is the only route to the function that exists,
  and the tool runs exactly as it does for an HTTP request), or add a native
  route table to the runtime.
- **Q2. Resolve tool pointers at lowering** (recommended: the pointers live as
  long as the accepted catalog, and no lookup happens under the contract lock
  per call), or look the tool up by name on each call.
- **Q3. Refuse `:param` routes in an agent's tool list** (recommended for M5a),
  or fill path parameters from named argument fields.
- **Q4. Which failures close the latch.** `tool_denied`, `tool_failed`,
  `outcome_unknown`, `budget_exhausted`, and `deadline_exceeded` close it;
  `unknown_tool` and `invalid_arguments` do not, so a model can correct a bad
  call within its budget (recommended), or every failure closes it.

The contract fixes the label rule in section 5. These defaults are recommended
and are not questions unless the owner objects: the step order of section 3;
every call that reaches step 3 counts against the budgets; tag-only error
arms; a thrown tool is `outcome_unknown`.

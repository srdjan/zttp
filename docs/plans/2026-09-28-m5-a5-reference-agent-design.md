# M5 A5 design note: the buffered reference agent

Status: accepted for implementation in the next session on 2026-09-28. The
owner directed A5 to be the next implementation unit. The recommended answers
to Q1 to Q3 in section 10 govern that work. Unit A5 of the
[M5 release contract](2026-09-27-m5-agent-handler-release-contract.md) uses
check C-A5. Code references are to local `main` at `2ebab8e1`.

## 1. What A5 must deliver

A signed POST with the admitted version 1 prompt reaches a bounded provider
round, one listed M4 tool, a second provider round, and one final answer. The
handler returns a buffered list of KTD4 envelopes. It uses the accepted tool
catalog, the A3 SSE framer and strict JSON parser, and A4 `callTool`. The
provider and tool effects stay under the A1 grant and A2 turn recorder. A new
loopback check drives the built artifact with real signed requests. The example
and its report disclose what the static analysis, runtime guards, and observed
turn records each establish.

The A5 boundary is a buffered response. It does not claim incremental delivery,
stream cancellation, or a streaming proof profile. Those belong to M5b. A6
measures limits before the project assigns deployment defaults. A5 uses explicit
finite fixture limits and makes no performance claim.

## 2. Delivered surfaces and three gaps

The A1 agent entry binds one provider endpoint, credential, tool list, and
limits. `agentPrompt()` reads the admitted prompt. A2 holds a server-created
turn ID, counts provider fetches, and records effects. A3 exports
`sseEvents(body, bounds)` and strict `parseJson`. A4 executes one listed tool
through `callTool(callId, name, argsJson)` and rechecks its scope, schema,
budget, and deadline. The two reference tools are `convert` and `order_status`
in `examples/tools/tools.ts`.

Three gaps prevent a handler built only from those exports from meeting the
contract:

1. `toolCatalog` is inert at runtime (`packages/modules/src/http/tool.zig`).
   The handler cannot get provider tool definitions from the accepted catalog.
   Copying the descriptions and schemas into adapter code would create a
   second catalog, contrary to R7.
2. `callTool` validates and starts one tool at once. The handler cannot check
   every call in a provider round before the first effect, as R9 requires.
3. The server creates the turn ID in `packages/runtime/src/turn_state.zig`, but
   neither the request object nor `agentPrompt()` exposes it. The handler
   cannot emit KTD4's `turn_id`.

Section 4 adds a small agent-only view and a read-only whole-round preflight.
These extend the file scope named for A5 in the release contract. Section 7
also identifies a proof-policy gap that the contract asks this note to settle.

## 3. Provider protocol decision

The adapter sends one `POST /chat/completions` request with `stream: true`, one
choice requested, the application-selected model, the admitted prompt, and
tool definitions made from the accepted catalog. The request uses the entry's
literal endpoint and credential reference. It sets `maxResponseBytes` on each
fetch. The fetch response and every SSE block are bounded before parsing.
The handler never accepts a provider URL, model name, tool definition, or
credential from the caller or model.

The [DeepSeek chat-completions API](https://api-docs.deepseek.com/api/create-chat-completion/)
documents streamed `delta.tool_calls` indexed by call, argument fragments,
`finish_reason: "tool_calls"`, `finish_reason: "stop"`, and a final
`data: [DONE]` sentinel. Its other finish reasons include `length`,
`content_filter`, `insufficient_system_resource`, and `aborted`. The
[OpenAI Chat Completions reference](https://developers.openai.com/api/reference/resources/chat)
also defines indexed tool-call deltas. The [MLX-LM server guide](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/SERVER.md)
describes a similar API, while its [server implementation](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/server.py)
formats streamed tool calls. The guide does not establish that every local
model emits a usable tool call. A6 must test the selected local model. A5's
deterministic peer exercises both fragmented calls and a complete call in one
delta.

The adapter treats `finish_reason: "tool_calls"` as the only completion of a
tool round and `finish_reason: "stop"` as the only normal final answer. It
requires one terminal chunk for choice index 0 and the `[DONE]` sentinel after
it. EOF or `[DONE]` without that terminal chunk is failure. A usage-only chunk
may follow the terminal chunk and cannot change its outcome. A reason outside
the two admitted values is failure. A legacy `function_call`, an unsupported
tool type, a second choice, a changed completion ID, or a second terminal
signal is failure. No tool runs from a partial round.

The [DeepSeek thinking-mode guide](https://api-docs.deepseek.com/guides/thinking_mode/)
says thinking is enabled by default and requires `reasoning_content` on later
requests that carry tools. The DeepSeek variant therefore sends
`thinking: { type: "disabled" }` on every request. The loopback peer checks that
field. An MLX-LM build omits this DeepSeek-specific field and must use a model
that emits the admitted tool-call form. The response adapter is shared. The
example chooses the request variant in source before the build. A change to
that variant requires a rebuild; the caller and model cannot select it.

The first request and each follow-up carry only the transcript needed for this
turn. The handler retains the assistant tool-call message with the provider's
call IDs and then one tool message per result, using the same IDs. It does not
send a tool result after a failed or unknown call. It does not retry a provider
fetch or a tool effect. Thinking-mode `reasoning_content` is outside this
adapter's transcript contract. A6 must check the request variant and selected
model against the live provider before its pilot.

## 4. Catalog view, turn identity, and whole-round preflight

Add an agent-only `agentContext()` export in `zttp:tool`. It returns the
server-created turn ID, the agent entry's finite limits, and provider function
definitions projected from the accepted catalog. Each definition has the
catalog name, description, and input schema in a `type: "function"` provider
record. It contains no credential value,
scope rule, output schema, subject, or tenant. Its data has no user, secret,
or credential label. `agentPrompt()` remains the prompt reader and keeps its
`user_input` label. A call outside the outer agent frame returns a tagged
failure. The provider definitions are derived from the same accepted entries
that `callTool` resolves, after artifact acceptance. This is a view of the
catalog, not a new source of authority.

Add an agent-only `preflightToolRound(callsJson)` operation. It reads a bounded
JSON array of `{callId, name, argsJson}` records. It uses the same accepted
catalog resolution, strict argument parser, `tool_schema.validate`, and
`tool_auth.checkScope` as `callTool`. It checks the whole array before it
returns success: nonempty, within the remaining total and per-round call
budgets, distinct IDs within the array and from the current round, listed
names, argument byte bounds, schema, and scope. It reads no tool body and
starts no effect. Its Result error has a safe tag only. A failed preflight
closes the adapter turn with `turn.failed`; it cannot authorize a subset of the
round. `callTool` then runs the approved calls in provider order, one at a
time, and repeats its own checks before each effect. Its budget spending,
recording, and latch rules do not change. A later failure stops the remaining
calls. Preflight success is not an execution permit that survives a changed
turn state.

The adapter forms `callsJson` with `stringifyJson` after it has parsed the
provider events. The native preflight parses it strictly again. The repeated
parse is intentional: the native boundary must validate the actual bytes it
will authorize. The new exports use the A4 runtime callback pattern and share
the A4 validation helpers. The build refuses both exports in a tool route.
Adding module exports moves the module binding and vocabulary hashes; A5 must
regenerate the required pins and drift files and account for any affected
codegen fixtures before implementation closes.

## 5. Adapter state and bounded transcript

The handler uses `for (const i of range(MAX))` with `break`, where the literal
loop maximum is at least the agent entry's `rounds` limit. Each iteration
performs at most one provider fetch. The A2 turn state remains the authority
for the round count and deadline. The adapter checks every Result before it
uses `.value` and maps failures to closed, public terminal tags. It never
converts a malformed provider result into an empty success.

For each successful fetch, `sseEvents` frames the complete body. The adapter
requires data events to be JSON chunks or `[DONE]`; it ignores only SSE
comments, which the framer does not return. It parses every JSON chunk with
`parseJson`, checks the record shape, and assembles tool calls by their
numeric `index`. An index has one stable ID, type, and function name;
argument fragments append in arrival order. It refuses gaps, repeated
identity fields with changed values, a missing field at round completion,
fragments after the terminal chunk, and duplicate call IDs. It bounds each
assembled argument by `argumentBytes` during append, before a JSON parse or
tool call. It does not treat `delta.content` as arguments. Text is provisional
until `stop`, but may be represented by buffered `text.delta` envelopes.

On `tool_calls`, the adapter first checks and preflights the entire assembled
round. It then emits `tool.started` immediately before each authorized
`callTool`. It emits `tool.finished` with a safe success or failure class after
the result. It adds only successful schema-bounded tool output to the next
provider request, subject to the flow check at that provider body. On `stop`,
it emits `turn.completed` only if no tool call is pending. Every failure adds
one `turn.failed` and ends the loop. The turn recorder, not the response body,
is the source of effect and unknown-outcome evidence.

The retained memory has finite bounds from the entry's `rounds`,
`toolCalls`, `toolCallsPerRound`, `argumentBytes`, `resultBytes`,
`providerRequestBytes`, prompt `maxInputBytes`, and the fetch and SSE byte
bounds. The adapter checks the size of its next request before `fetch`; the
runtime repeats the `providerRequestBytes` check. The example uses explicit
fixture values within the encoded maxima. Their values are not deployment
defaults and must be selected by measurement in A6.

## 6. Buffered KTD4 response

The HTTP response is one JSON list of envelopes. Each envelope has exactly
`version`, `turn_id`, `sequence`, `type`, and `data`. `version` is 1.
`turn_id` is the server-created ID from `agentContext`. `sequence` starts at
1 and increases by 1 for each envelope in this list. `data` is an object,
serialized with `stringifyJson` or `Response.json`; provider text is never
concatenated into JSON syntax by hand. The event names and safe fields follow
KTD4:

| Type | Data |
| --- | --- |
| `turn.started` | `protocol_version: 1` |
| `text.delta` | `text` |
| `tool.started` | public `name` and server-scoped `call_id` |
| `tool.finished` | `call_id` and safe `status` |
| `turn.completed` | provider `usage` when present, after validation |
| `turn.failed` | safe `tag`, safe `message`, and `outcome_unknown` boolean |

One terminal envelope is last. The list contains no raw arguments, raw tool
results, credential, or reasoning text. M5b serializes these same envelopes
as SSE events with matching `event` and `data` fields; A5 does not set an SSE
content type on its buffered response.

## 7. Fixed proof profile and R22 report

The example's `policy.json` must name `response_total`, `results_checked`,
`no_secret_leakage`, `no_credential_leakage`, and
`capability_bounded` as required properties. Today
`packages/zts/src/handler_policy.zig` accepts only `env`, `egress`, `cache`,
and `sql` at the top level. A `proof` field is refused. The production
consumer policy in `packages/proof-checker/src/policy.zig` requires four of
these properties; its closed `Property` enum does not include
`no_credential_leakage`. A `Proof<Response, ...>` annotation can require the
two leakage properties, but cannot name the other three by those names.

Add a closed `proof.required` list to the example policy and the policy
loader. The build checks each named property against the compiled handler and
accepted artifact: exhaustive return evidence for `response_total`, checked
Result use for `results_checked`, the named flow verdicts for both leakage
properties at provider and client sinks, and the checked declaration ceiling
for `capability_bounded`. Missing evidence refuses the build. The required
list is bound into the artifact and checked again at acceptance; a later edit
to the source policy cannot change the artifact's requirement. The producer
and consumer must use the same closed names and grade floors. Extend the
consumer property alphabet for `no_credential_leakage` as disclosed evidence
at a tested floor, like the other flow property. This does not turn the flow
classifier into a kernel proof. The existing production floors are trusted for
`response_total` and tested for the other three current properties
(`packages/proof-checker/src/policy.zig`). Version any changed certificate or
policy wire format. Refuse an older format if it cannot state the new
requirement.

Before recording a fixture, build a hand-authored positive handler under this
profile. Then send an `env()` secret in the provider body in a copy and
require a refusal of `no_secret_leakage`. Repeat with a credential-labelled
value for `no_credential_leakage`. Test both provider and client sinks and a
clean value through the same paths. `pii_contained` stays outside the profile:
the prompt is sent to the provider by design.

`packages/tools/src/report.zig` adds an R22 agent section with separate
`static_properties`, `runtime_restrictions`, `observed_events`,
`unknown_outcomes`, and `disclosures`. A build report can state the first two
and the planned observation source; it has no observed turn and must mark the
last two unavailable, not zero. The A5 loopback check attaches counts and
terminal tags from the turn recorder as a separate run receipt. Neither report
claims model intent, answer accuracy, prompt-injection immunity, or
exactly-once effects.
The section also states that a tool result sent to the provider uses the
caller clearance, prompt content is disclosed to the provider, whole-round
validation is an adapter plus preflight rule, and nested tools share the
agent runtime and request arena (M5 contract, section 5).

## 8. C-A5 checks and non-vacuity

Add `packages/runtime/src/reference_agent_check.zig` and a new step beside
`test-reference-tools` in `build/runtime_tests.zig`. The step builds
`examples/agent/` with the real `zttp` binary, starts the built artifact with
the signed-token key and placeholder provider credential, and drives a
deterministic loopback provider. Its positive case sends a signed prompt,
receives one tool round and one final text round, and checks every envelope,
sequence, turn ID, tool counter, provider transcript, and terminal record.
Both `convert` and `order_status` get a positive route case; the latter also
uses a loopback order upstream and a verified tenant.

The negative corpus covers AE5 complete arguments and duplicate JSON keys;
AE6 no provider or tool retry and duplicate terminal signals; AE9 malformed
frames, unsupported action type, excess bytes, usage without completion, and
truncated tool output; AE11 altered accepted artifact and a cross-grant
attempt; AE15 untrusted instructions in prompt and tool content; AE17 missing
provider credential, changed destination, and credential echo; AE19 a
model-selected declassification bound; and AE21 a malformed or widened tool
schema. The test checks zero tool effects for every failed preflight and no
later effect after a latched failure. It checks `outcome_unknown` when an effect
may have started and its completion cannot be established.

Every verdict comes from an unfiltered step whose exit status is read
directly. The new step declares its expected case count and fails if it runs
fewer cases. Delete or corrupt the example input in a copy and require the
step to fail. Mutate the provider terminal check, preflight, and policy
requirement separately in a copy and require a named case to fail. Census
each adapter failure tag with a probe or a stated unreachable mechanism.
Run the new step, `zig build test`, `bash scripts/verify.sh`, and
`zig build test-runtime-purity` after implementation. A5 adds no provider
client to the deployed runtime.

## 9. Files and implementation order

The release contract already names `examples/agent/` with `agent.ts`,
`zttp.json`, `policy.json`, `declaration.json`, and a README;
`scripts/test-examples.sh`; `build/runtime_tests.zig`;
`packages/runtime/src/reference_agent_check.zig`;
`packages/tools/src/report.zig`; and `docs/user-guide.md`.

The agent example keeps the two M4 tool routes and their schemas in its one
handler source. The current multi-module build path does not run the flow
check that enforces the declaration (`packages/tools/src/precompile.zig`), so
a local file import is not a safe way to share those routes yet. This is a
source copy between two example artifacts, not a second catalog inside one
artifact. The loopback check compares the canonical names, descriptions, and
input schemas in both artifacts, then exercises both routes. The README
states the maintenance link.

The three API gaps add `packages/modules/src/http/tool.zig`, its module spec,
the zts runtime wrapper and resolver, `packages/runtime/src/handler_instance.zig`,
`packages/runtime/src/contract_runtime.zig`,
`packages/runtime/src/turn_state.zig`,
`packages/zts/src/contract_builder.zig`, and the shared A4 validation path.
The proof profile adds `packages/zts/src/handler_policy.zig`, the contract and
artifact carriage, `packages/runtime/src/build_command.zig`,
`packages/runtime/src/proof_certificate.zig`, and the consumer policy and
checker files under `packages/proof-checker/src/`. Binding and format changes
also require their pin, golden, and vocabulary-envelope updates. Each new
internal zts import outside zts needs a deliberate module-boundary allowance.

Implement the catalog view, turn ID, and preflight first. Then prove the fixed
profile with a hand-authored handler. Add the adapter and buffered envelope
after these compile and runtime paths are established. Add the loopback corpus,
R22 report, and user guide last. Commit each complete unit separately. Do not
run a live DeepSeek pilot in A5; A6 owns that run and its approval.

## 10. Accepted decisions

The owner selected the recommended answer to Q1 to Q3 on 2026-09-28 by
directing this note to be the next implementation unit. The alternatives stay
here to record the choice.

1. **Q1, A5 scope.** Accept the agent-only catalog view, turn ID, and
   whole-round preflight and the wider owned-file list above (recommended),
   or revise R7, R9, and KTD4 in the release contract before A5 code starts.
2. **Q2, proof profile.** Extend `policy.json` with `proof.required`, bind the
   list into the artifact, and add `no_credential_leakage` to the consumer
   property alphabet at a disclosed tested floor (recommended), or revise the
   contract's policy-file and acceptance claim.
3. **Q3, provider mode.** Keep the first adapter on a non-thinking
   chat-completions transcript with `tool_calls` and `stop` as its two admitted
   completion reasons (recommended), or add a provider-specific reasoning
   transcript contract and its fixtures before the adapter is accepted.

These are design choices, not measured deployment values. A6 still owns the
limits and live pilot.

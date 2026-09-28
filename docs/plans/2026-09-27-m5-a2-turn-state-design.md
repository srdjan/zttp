# M5 A2 design note: turn state, the turn recorder, and the turn cap

Status: proposed. It needs the owner's answers to section 8 before code starts.
Unit A2 of the [M5 release contract](2026-09-27-m5-agent-handler-release-contract.md)
is written against the approach this note names; check C-A2 is its completion
check.

All citations are to local `main` at `22d0b2e2`.

## 1. What A2 must deliver

The contract asks for these. A turn state per agent request: a server-created
turn identity, the round ordinal, the call identities seen, the remaining
budgets, and a latch. Each provider fetch counts one model round, and the fetch
past the round limit is refused before the connection opens. The latch closes
after `tool_denied`, `tool_failed`, `outcome_unknown`, a budget failure, or the
deadline, and every later provider fetch in the turn is then refused. A turn
recorder that writes a bounded record before and after each effect, reserves
space for the terminal record at admission, reports sink health, and starts no
effect when the sink fails. A per-server cap on concurrent agent turns, checked
at admission, answering 503 when full, with no default until A6.

A2 counts and records provider fetches only. Tool calls are A4's, which uses
the call-identity and budget fields A2 adds.

## 2. What exists today

**The agent fetch path.** `fetchModuleCallback` (`packages/runtime/src/runtime_http.zig:1315`)
runs `checkAgentFetch` (`:955-975`) first, then replay (`:1326`), durable
(`:1336`), and `fetchSyncResult` (`:1045`), which reaches DNS, credential
authorization, the fetch deadline, and connect (`:1094-1121`). A check placed
after `checkAgentFetch` runs before all of them. Refusals return a status-599
Response with `.error` and `.details` (`createFetchErrorResponse`, `:199-211`);
the agent refusal names are an enum in `runtime_http.zig:937-941`, not in the
`zttp:fetch` binding.

**Outcomes.** Everything returns a Response, so the callback can tell outcomes
apart only by status 599 and the `.error` string. Before any byte is sent:
`InvalidUrl`, `AddressScopeNotAllowed`, `ConnectFailed`, `CredentialRefused`,
`DeadlineUnavailable`, `RequestInitFailed`. During the send: `RequestSendFailed`
or `TimedOut` (`:1151-1167`), which today are not marked unknown although bytes
may have left. A head failure with a credential attached is `OutcomeUnknown`
(`:1171-1175`); an agent fetch always carries its credential. After the head:
`ResponseTooLarge`, `ResponseReadFailed`, `TimedOut`, `CredentialReflected`
(`:1182-1204`), where the provider has acted.

**Deadlines.** The handler deadline sets `ctx.deadline_ns` and an interrupt
flag; the interpreter checks the clock every 1024 back-edges and returns
`error.RequestTimeout`, which the server maps to 504
(`handler_instance.zig:1356-1383`, `interpreter.zig:79-94`, `server.zig:863-866`).
It does not stop a native fetch in progress: only the fetch watchdog bounds it,
with a budget of `outbound_timeout_ms` capped only by a durable step deadline
(`effectiveOutboundTimeoutMs`, `:44-57`).

**Where state can live.** The agent grant view (`http_types.zig:66-70`) holds
the endpoint, credential, and no-durable flag, not the limits. The request view
(`http_types.zig:16-38`) already carries `agent_prompt` and reaches the fetch
path through `rt.active_request` and the frame stack
(`handler_instance.zig:157-226`). The connection arena is reset per request
(`server.zig:470-480`).

**Sinks.** `DurableState` in `packages/zts/src/trace.zig:1153` writes JSONL and
returns only after `write` and `fsync` (`:1528-1531`), but its helpers are
file-private, and it records after the effect, not before
(`makeDurableWrapper`, `:1538-1561`). `zttp:ledger`'s SQLite store is gated to
handler-invoked ledger calls (`module_binding/capabilities.zig:551-559`). No
runtime logger acknowledges a write (`incident_log.zig:29-31`,
`security_logger.zig:90-93`, `trace.zig:195-209`). The runtime may already reach
`trace` and `file_io` (`scripts/module-boundary.allow:83`, `:51`).

**Caps.** `HandlerPool` bounds concurrency with an atomic `in_use` and a CAS
acquire that answers `PoolExhausted`, mapped to 503 (`runtime_pool.zig:38`,
`:621-649`, `server.zig:865`). Server-wide settings live in `ServerConfig`
(`server.zig:1373`), and T1a's zero-refusal pattern runs through
`parseServeArgs` (`runtime_cli.zig:717-721`) and `HandlerInstance.init`.

## 3. Turn state

`packages/runtime/src/turn_state.zig` defines `TurnState`, one per admitted
agent request. The server creates it after admission (`server.zig`, after the
prompt is admitted and before the handler runs), and passes a pointer through a
new `HttpRequestView.turn` field, so it reaches the fetch path through frame 0.
A nested A4 frame carries the tool's request with no turn pointer, so a fetch
inside a tool is a tool effect, not a provider round.

Fields: a 128-bit random turn identity, rendered as 32 hex characters; the
agent's limits, copied from `AcceptedAgent`; the round ordinal; the counts of
tool calls in total and in the current round; a bounded list of call identities
seen (A4 fills it; capacity is `toolCalls`); the turn deadline as an absolute
time; the latch and the tag that closed it; and the recorder handle. It lives in
the connection arena, which outlives the handler call.

**Provider fetch, in order,** placed right after `checkAgentFetch`:

1. If the latch is closed, refuse with its tag.
2. If the turn deadline has passed, close the latch with `deadline_exceeded`
   and refuse. No pre-record is written.
3. If `round == rounds`, close the latch with `budget_exhausted` and refuse.
4. If the request body is larger than `providerRequestBytes` (Q5), close the
   latch with `budget_exhausted` and refuse.
5. Write the pre-record. If the sink refuses, close the latch with
   `recorder_unavailable` and refuse.
6. Increment the round, and set the fetch budget to the smaller of
   `outbound_timeout_ms` and the time left before the turn deadline (Q4).
7. Run the fetch.
8. Classify the outcome (section 4) and write the post-record. A failed
   post-record closes the latch; the fetch's own result is still returned,
   because the effect happened.
9. If the outcome is `outcome_unknown`, close the latch with it.

Every refusal is a status-599 Response with `.error = "AgentTurnRefused"` and
`.details` naming the tag, which the adapter reads like any fetch failure.

## 4. Outcome classification under an agent grant

The fetch path returns a native tag beside the Response, so classification does
not parse strings. Three classes:

- **not_started:** no byte left the host. `InvalidUrl`, `AddressScopeNotAllowed`,
  `ConnectFailed`, `CredentialRefused`, `DeadlineUnavailable`,
  `RequestInitFailed`, and every A1 or A2 refusal.
- **outcome_unknown:** the request may have reached the provider and no complete
  response came back. `RequestSendFailed`, `TimedOut` during the send or before
  the head, and every head failure. Under an agent grant this replaces today's
  plain `RequestSendFailed` and `TimedOut` for these phases; tool fetches keep
  today's codes.
- **completed:** a response head arrived. That includes a success, a non-2xx
  status, `ResponseTooLarge`, `ResponseReadFailed`, a `TimedOut` after the head,
  and `CredentialReflected`. The provider acted; whether the body is usable is
  the adapter's concern. `ResponseReadFailed` and a `TimedOut` after the head
  close the latch with `outcome_unknown`, because the adapter cannot know what
  the provider decided.

## 5. The turn recorder

`packages/runtime/src/turn_recorder.zig` owns one append-only file per server
process, opened with `O_APPEND | O_CREAT`, mode 0600, and an exclusive advisory
lock, like the oplog (`runtime_config.zig:164-217`). A mutex serializes writers.
`append` builds one record, writes it with the same checked-write loop, then
`fsync`s, and returns only after both succeed. It does not reuse `DurableState`,
whose record is written after the effect and whose helpers are private to zts.

**Record.** One JSON line of bounded metadata, at most 512 bytes: format
version, turn identity, sequence within the turn, kind (`admit`, `pre`, `post`,
`terminal`), effect (`provider_fetch`, or A4's `tool_call`), round, call
identity (A4), outcome class or terminal tag, and a monotonic timestamp. No
prompt, argument, result, header, URL path, or credential enters a record. The
agent name and the accepted catalog digest are in the `admit` record.

**Reservation and health.** The log has a byte ceiling from configuration. At
admission the recorder reserves the bytes of one `terminal` record for the turn,
and refuses admission (503) when the reservation does not fit. A pre-record that
would eat into the reserved space of live turns is refused. After the first
failed write or `fsync`, the recorder is unhealthy: every later admission is
refused with 503, and every live turn's next effect is refused with
`recorder_unavailable`. Health is exposed as one line on `/_readiness`.

**Terminal record.** The server writes it after the handler call returns, on
every path, with the terminal tag: `completed` for a 2xx, `failed` with the
latch tag when the latch is closed, `deadline_exceeded` for the handler timeout
(504), and `failed` for any other status. It uses the space reserved at
admission, so a full log cannot prevent it. A crash can still lose it: the
contract claims no recovery of an interrupted turn.

**Configuration.** A new server setting names the log file. A handler whose
accepted catalog holds an agent refuses to start without it; no default path
exists. The byte ceiling is a second setting, required with the first.

## 6. The turn cap

`ServerConfig` gains `max_agent_turns: ?u32`. A handler whose accepted catalog
holds an agent refuses to start when it is unset or zero (decision 5 of the
contract: no default before A6). Admission takes a slot with the pool's CAS
pattern after the prompt is admitted and before the recorder's `admit` record;
a full cap answers 503 "agent turn capacity exhausted" and contacts no provider.
The slot is released in a `defer` after the terminal record, on every path. A
counter of refused admissions sits beside it, as `exhausted_count` does for the
pool.

## 7. Files, gates, and diagnostics

New: `packages/runtime/src/turn_state.zig`, `turn_recorder.zig`. Changed:
`runtime_http.zig` (the fetch hook, the native outcome tag, the fetch budget),
`http_types.zig` (the `turn` field), `server.zig` (creation, cap, terminal
record, readiness), `runtime_config.zig` and `runtime_cli.zig` (the three
settings and their startup refusals), `handler_instance.zig` (frame 0 carries
the turn pointer), and, for Q5, the A1 carriage files and the kernel decoder.
No ZTS code, no module export, and no module hash moves unless Q5 picks the
catalog; even then only the contract version and `ZTCAT1` schema move, which do
not reach the codegen cassettes.

Gates: `test-zruntime`, `test-server`, `test-cli`, `test-module-boundary`,
`test-runtime-purity`, and the full `zig build test` and `scripts/verify.sh`.
With Q5 on the catalog, also `test-zts`, `test-proof-checker`,
`test-proof-checker-mutants`, `test-contract-golden`, and
`test-vocab-envelope-drift`.

C-A2 cases, all through a loopback provider peer that counts accepted
connections: a turn inside its limits has a pre-record and a post-record per
fetch and a terminal record; the fetch past the round limit opens no connection;
a sink failure before a fetch opens no connection and marks the recorder
unhealthy; a deadline between two fetches gives `deadline_exceeded` with no
second pre-record; a peer that accepts and stalls before the head gives
`outcome_unknown` and closes the latch; after the latch closes, a fetch opens no
connection; the cap refuses the next turn with 503 and no connection; an unset
or zero cap, or a missing log setting, refuses to start. Non-vacuity: remove the
pre-record, and the sink-failure case must fail; remove the latch check, and the
latched-fetch case must fail; remove the fetch-budget cap, and the stall case
must outlast the turn deadline.

## 8. Questions for the owner

- **Q1. Sink.** A runtime-owned append-only JSONL file with `write` and `fsync`
  per record (recommended: the smallest thing that acknowledges, with no
  schema, no second writer, and a lock that refuses a second process), or a
  runtime-owned SQLite database with `synchronous = FULL`.
- **Q2. One file per server** (recommended: one lock, one fsync stream, and a
  byte ceiling that is easy to reserve against), or one file per turn.
- **Q3. Send-phase failures become `outcome_unknown` under an agent grant**
  (recommended: bytes may have left, and R18 forbids calling that "not
  executed"), with tool fetches unchanged.
- **Q4. The fetch budget is capped by the time left in the turn**
  (recommended: the handler deadline cannot stop a fetch in progress, so without
  this a fetch can outlive its turn), which can turn a late provider response
  into `outcome_unknown`.
- **Q5. Provider request bytes.** The A1 note left this bound to A2. Add a
  seventh agent limit, `providerRequestBytes`, to the catalog and `ZTCAT1`
  schema 5 (recommended: every agent limit stays bound by the artifact, and the
  cassettes are unaffected), or make it a server setting.
- **Q6. The recorder and the cap are required settings** for a handler with an
  agent, with no defaults (recommended, per contract decision 5), or they get
  defaults now and A6 revises them.

These defaults are recommended and are not questions unless the owner objects:
records hold metadata only, never content; the 512-byte record ceiling; the
128-bit random turn identity; health on `/_readiness`; the terminal record
written by the server on every path.

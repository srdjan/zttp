# M5 A2 design note: turn state, the turn recorder, and the turn cap

Status: proposed on 2026-09-27, revised once after a design critique (run on
Opus; Fable credits were exhausted) and a citation check. It needs the owner's
answers to section 9 before code starts. Unit A2 of the
[M5 release contract](2026-09-27-m5-agent-handler-release-contract.md) is
written against the approach this note names; check C-A2 is its completion
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

A2 counts and records provider fetches only. Tool calls are A4's, which uses the
call-identity and budget fields A2 adds.

## 2. What exists today

**The agent fetch path.** `fetchModuleCallback` (`packages/runtime/src/runtime_http.zig:1315`)
runs `checkAgentFetch` (`:955-975`) first, then replay (`:1326`), durable
(`:1336`), or `fetchAndRecord` (`:1348`), which calls `fetchSyncResult`
(`:613`). A point right after `:1324` precedes all three branches. Replay of
`zttp:fetch.fetch` keeps the real implementation and reaches that point
(`packages/zts/src/modules/internal/resolver.zig:98-100`). A module `fetch`
inside a `zttp:io` thunk also reaches it, and `fetchSyncResult` then detects
collection (`:1050-1052`); A1 refuses `zttp:io` in an agent route at build, and
collection refuses a credentialed fetch at run time (`:1247-1255`).

**Phases and outcomes.** `fetchSyncResult` returns `!JSValue`. Its failures, by
phase:

- Before the connection: argument and policy refusals (`InvalidArgs`,
  `InvalidUrl`, `HostNotAllowed`, `InvalidQuery`, `InvalidMethod`,
  `InvalidBody`, `InvalidHeaders`, `InvalidMaxResponseBytes`,
  `InvalidCredential`, `OutboundHttpDisabled`; `:688-899`, `:1046`), DNS and
  address scope (`AddressScopeNotAllowed`, `ConnectFailed`; `:1094-1097`),
  credential authorization (`CredentialRefused`, `:1105`), and deadline setup
  (`DeadlineUnavailable`, `:1117`). Under an agent grant `checkAgentFetch`
  already refuses most credential cases (`:947-972`).
- The connect (`:1122-1135`): a failed or timed-out connect (`TimedOut` via
  `connectFailCode`, `fetch_deadline.zig:99-100`). DNS, TCP, and TLS traffic can
  already have occurred; the HTTP request has not been sent.
- Request creation and send (`:1146-1167`): `RequestInitFailed`, then
  `RequestSendFailed` or `TimedOut`. Once the send starts, request bytes may
  have reached the provider. Today these are not marked unknown.
- The head (`:1171-1175`): with a credential attached, any head failure is
  `OutcomeUnknown`. An agent fetch always carries its credential.
- The body (`:1178-1212`): `ResponseTooLarge`, `ResponseReadFailed`,
  `TimedOut`, `CredentialReflected`.
- Anywhere: a Zig error that `fetchAndRecord` turns into `InternalError`
  (`:612-615`), which can arise before or after the head.

So an error name does not always say whether the request left. The phase does.

**Deadlines.** The handler deadline sets `ctx.deadline_ns` and an interrupt
flag; the interpreter checks the clock every 1024 back-edges and returns
`error.RequestTimeout`, mapped to 504 (`handler_instance.zig:1356-1383`,
`interpreter.zig:79-94`, `server.zig:863-866`). It does not interrupt a native
fetch. The fetch is bounded by its own deadline: a `poll`-bounded connect, then a
watchdog that shuts the socket during TLS and the exchange
(`outbound_io.zig:60-66`, `:87-94`, `:161-170`; `fetch_deadline.zig:64-79`), with
a budget of `outbound_timeout_ms` capped only by a durable step deadline
(`effectiveOutboundTimeoutMs`, `runtime_http.zig:44-57`). DNS is outside it.

**Where state can live.** The agent grant view (`http_types.zig:66-70`) holds the
endpoint, credential, and no-durable flag, not the limits. The request view
(`http_types.zig:16-38`) carries `agent_prompt` and reaches the fetch path
through `rt.active_request` and the frame stack (`handler_instance.zig:157-226`).
The connection arena is reset per request (`server.zig:470-480`).

**Sinks.** `DurableState` (`packages/zts/src/trace.zig:1153`) writes JSONL and
returns only after `write` and `fsync` (`persistBuffer`, `:1528-1531`). Its
persist methods and `writeAllChecked` (`:1760`) are public; `persistBuffer` and
`fsyncFdChecked` (`:1773`) are not. It has records written before an effect
(`persistStepStart`, `:1384`) as well as after. Its files are one per durable
key, created with `O_CREAT` and mode 0600, locked with a non-blocking exclusive
`flock`, then truncated (`runtime_config.zig:164-202`). It uses plain `fsync`.
`zttp:ledger`'s SQLite store is gated to handler-invoked ledger calls
(`module_binding/capabilities.zig:551-559`). No runtime logger acknowledges a
write.

**Caps.** `HandlerPool` bounds concurrency with an atomic `in_use` and a CAS
acquire that answers `PoolExhausted`, mapped to 503 (`runtime_pool.zig:38`,
`:621-649`, `server.zig:865`). Server settings live in `ServerConfig`
(`server.zig:1373`); T1a's refusal pattern runs through `parseServeArgs`
(`runtime_cli.zig:717-721`).

## 3. Turn state and the provider-fetch hook

`packages/runtime/src/turn_state.zig` defines `TurnState`, one per admitted
agent request. The server creates it after the prompt is admitted and before the
handler runs, in the connection arena, and passes a pointer through a new
`HttpRequestView.turn` field, so it reaches the fetch path through frame 0. A
nested A4 frame carries the tool's request with no turn pointer, so a fetch
inside a tool is a tool effect, not a provider round.

Fields: a 128-bit random turn identity, rendered as 32 hex characters; the
agent's limits, copied from `AcceptedAgent`; the round ordinal; tool calls in
total and in the current round (the per-round count resets when the round
ordinal moves); a bounded list of call identities seen (A4 fills it; capacity is
`toolCalls`); the turn deadline as an absolute monotonic time; the latch, with
the first tag that closed it; and a handle to the recorder.

**The hook, in order,** right after `checkAgentFetch`:

1. If the latch is closed, refuse with its tag.
2. If the turn deadline has passed, close the latch with `deadline_exceeded` and
   refuse.
3. If `round == rounds`, close the latch with `budget_exhausted` and refuse.
4. If the request body is larger than `providerRequestBytes` (Q5), close the
   latch with `budget_exhausted` and refuse.
5. Write the pre-record (section 6). If the sink refuses, close the latch with
   `recorder_unavailable` and refuse. This pre-record then has no post-record,
   which is correct: the fetch did not start.
6. Spend the round: increment it for every attempt that passes step 5, whatever
   the outcome.
7. Set the fetch budget to the smaller of `outbound_timeout_ms` and the time
   left before the turn deadline (Q4).
8. Run the fetch. The fetch path sets a phase marker, `request_started`, on the
   turn immediately before the request write begins, and `head_received` when a
   head arrives.
9. Classify (section 4), write the post-record, and close the latch when the
   class requires it. If the post-record fails, the recorder becomes unhealthy
   and the latch closes with `recorder_unavailable`; the fetch's own result is
   still returned, because the effect may have happened, and nothing records it
   as not executed.

Refusals are a status-599 Response with `.error = "AgentTurnRefused"` and
`.details` naming the tag. The tag set is closed and stable (`deadline_exceeded`,
`budget_exhausted`, `recorder_unavailable`, `outcome_unknown`, and A4's
`tool_denied` and `tool_failed`), and it is documented in the `zttp:fetch`
module spec and the user guide, so an adapter reads a stable name, not a
diagnostic.

**Re-issue.** The runtime never retries. A failure classed `not_started`, or a
`completed` non-2xx response, leaves the latch open, so the adapter may call
`fetch` again, spending another round. That is not an automatic retry: the
adapter chooses it, absence of the earlier effect is established (R19), and
`rounds` bounds it.

## 4. Outcome classification

Classification reads the phase marker, never the error name:

- **not_started:** `request_started` is not set. Every pre-connect refusal, a
  failed or timed-out connect, `RequestInitFailed`, and an `InternalError`
  before the send. The provider has seen no HTTP request; DNS, TCP, or TLS
  traffic may have occurred.
- **outcome_unknown:** `request_started` is set, and the response is not both
  fully received and usable. That covers send failures and timeouts, head
  failures, `ResponseReadFailed`, a `TimedOut` after the head,
  `ResponseTooLarge` (the adapter cannot know which tool calls a truncated body
  held), `CredentialReflected`, and an `InternalError` after the send started.
  It closes the latch with `outcome_unknown`.
- **completed:** a head arrived and the body was read in full within bounds.
  This includes non-2xx statuses; the provider answered, and the adapter decides
  what the answer means.

The post-record carries the class, `head_received`, and the status when there is
one, so the record and the latch tell the same story.

## 5. The terminal outcome

The server writes the terminal record after the handler call returns, on every
path. The tag follows a fixed precedence, highest first:

1. `outcome_unknown`, if the latch ever closed with it;
2. `deadline_exceeded`, if the latch closed with it or the handler timed out
   (504);
3. any other latch tag;
4. `completed` for a 2xx response, `failed` for any other.

So a handler that catches an unknown outcome and returns 200 is still recorded
as `outcome_unknown`, and a fetch cut by the turn budget followed by a 504 is
still `outcome_unknown`.

## 6. The turn recorder

`packages/runtime/src/turn_recorder.zig` is owned by the `Server`, not by a
`HandlerInstance`, so a dev live reload does not reopen it.

**File.** The setting names a directory. At start the recorder creates
`turns-<start-unix-ns>-<pid>.jsonl` with `O_CREAT | O_EXCL | O_APPEND`, mode
0600, takes an exclusive non-blocking `flock`, and `fsync`s the directory. A new
file per process start means a torn last line from a crash is never appended to,
and a zero-downtime restart gets its own file.

**Acknowledgement.** `append` writes one record with a checked write loop and
then makes it durable: `fcntl(F_FULLFSYNC)` on macOS, where `fsync` does not
reach durable media, and `fsync` on Linux. It returns only after both succeed.
"Acknowledged" means exactly that. It does not claim durability against a disk
that lies about its cache.

**Record.** One JSON line of bounded metadata, at most 512 bytes: format
version, turn identity, sequence within the turn, kind (`admit`, `pre`, `post`,
`terminal`), effect (`provider_fetch`, or A4's `tool_call`), round, call identity
(A4), the authorization decision (`pre`), the class, `head_received`, and status
(`post`), the terminal tag (`terminal`), and a monotonic timestamp. The `admit`
record also holds the agent name, the accepted catalog digest, the runtime
policy hash, and a wall-clock time. No prompt, argument, result, header, URL
path, or credential enters a record.

**Ceiling and reservation.** A second setting bounds the file's bytes. At
admission the recorder reserves one terminal record for the turn, and every
check and reservation happens under the recorder mutex. A turn is refused at
admission (503) when the reservation does not fit; a pre-record that would eat
into live turns' reservations is refused. "Reserved" means ceiling accounting
only. It does not preallocate disk, so `ENOSPC`, `EIO`, or a failed flush can
still lose a terminal record; the recorder then becomes unhealthy. When the
ceiling is reached, new turns are refused until restart. Rotation is out of
scope for M5a.

**Health.** After the first failed write or flush the recorder is unhealthy
until the process restarts, because a failed flush leaves the file's state
unknown. While unhealthy, `/_readiness` answers 503 and names the recorder, new
turns are refused with 503, and every live turn's next effect is refused with
`recorder_unavailable`. A failed `admit` record refuses the turn with 503 and
marks the recorder unhealthy.

**Cost.** Each provider round adds two flushes under one mutex, run on the
connection worker that serves the turn, never on the accept thread. The latency
and throughput this costs are not measured. A6 measures them; group commit is the
fallback if they are too high.

**Replay and tests.** Under replay (`zttp test`, and the recorded-trace runner)
the turn state, round counting, latch, and classification run unchanged, and the
recorder writes to an in-memory sink, so a replay needs no recorder setting and
touches no file (Q7).

## 7. The turn cap

`ServerConfig` gains `max_agent_turns`. The cap slot is taken after the prompt
is admitted and before the pool is acquired, with the pool's CAS pattern; a full
cap answers 503 "agent turn capacity exhausted" and contacts no provider. The
slot is released in a `defer` after the terminal record, on every path. Because
an agent turn holds a pool runtime for up to its turn deadline, the server
refuses to start when `max_agent_turns` is not below the pool size minus a
reserve for ordinary requests (R20). The reserve is one runtime until A6 measures
it. A counter of refused admissions sits beside the cap.

## 8. Files, gates, and scope

New: `packages/runtime/src/turn_state.zig`, `turn_recorder.zig`. Changed:
`runtime_http.zig` (the hook, the phase marker, the fetch budget),
`http_types.zig` (the `turn` field), `server.zig` (creation, cap, terminal
record, readiness), `handler_instance.zig` (frame 0 carries the turn),
`runtime_config.zig` and `runtime_cli.zig` (the settings and their refusals),
`packages/modules/module-specs/net/fetch.json` and `docs/user-guide.md` (the tag
set). The contract's A2 list names `runtime_http.zig`, `fetch.zig` and its spec,
`runtime_config.zig`, `runtime_cli.zig`, and the two new files; the other files
here are additions the contract did not foresee, and the contract records them
when this note is accepted. With Q5 on the catalog, A2 also changes A1's
carriage files and the kernel decoder (`ZTCAT1` schema 5, contract version 24);
those move no hash the codegen cassettes embed.

Gates: `test-zruntime`, `test-server`, `test-cli`, `test-modules`,
`test-module-boundary`, `test-runtime-purity`, and the full `zig build test` and
`scripts/verify.sh`. With Q5 on the catalog, also `test-zts`,
`test-proof-checker`, `test-proof-checker-mutants`, `test-contract-golden`, and
`test-vocab-envelope-drift`.

C-A2 cases run through a loopback provider peer that counts accepted connections
and requests, and each asserts that count exactly:

- a turn inside its limits: pre, post, and terminal records in sequence;
- the fetch past the round limit: zero new connections;
- a sink failure before a fetch: zero new connections, readiness 503;
- a post-record failure: the result is still returned, the latch closes, and no
  record says not executed;
- a deadline between two fetches: `deadline_exceeded`, no second pre-record;
- a peer that accepts the request and stalls before the head: `outcome_unknown`
  in the post-record, the latch, and the terminal record;
- a truncated or oversized response: `outcome_unknown`;
- a handler that catches `outcome_unknown` and returns 200: terminal
  `outcome_unknown`;
- after the latch closes: zero new connections;
- the ceiling: a turn whose reservation does not fit gets 503;
- the cap: the next turn gets 503 and zero connections; a cap not below the pool
  size minus the reserve refuses to start;
- replay: the same counts and tags with no file written.

A census covers every refusal tag and every outcome class, each observed by at
least one case. Non-vacuity: remove the pre-record, and the sink-failure case
must fail; remove the latch check, and the latched-fetch case must fail; remove
the fetch-budget cap, and the stall case must outlast the turn deadline; remove
the terminal precedence, and the catch-and-200 case must fail.

## 9. Questions for the owner

- **Q1. Sink.** A runtime-owned append-only JSONL file with a durable flush per
  record (recommended: the smallest thing that acknowledges, with no schema and
  no second writer), or a runtime-owned SQLite database with `synchronous =
  FULL`.
- **Q2. One file per process start** (recommended: a crash never leaves a torn
  line to append to, and a restart never contends for the lock), or one fixed
  file per server.
- **Q3. Classification by phase marker**, with every failure after the request
  write starts classed `outcome_unknown` under an agent grant (recommended:
  forced by R18), tool fetches unchanged.
- **Q4. The fetch budget is capped by the time left in the turn** (recommended:
  forced by R17, because the handler deadline cannot stop a fetch in progress).
- **Q5. Provider request bytes.** Add a seventh agent limit,
  `providerRequestBytes`, to the catalog (`ZTCAT1` schema 5), which keeps every
  agent limit bound by the artifact as the contract's resume condition 2 says
  but pulls A1's carriage files into A2 (recommended), or make it a server
  setting, which keeps A2 runtime-only.
- **Q6. Settings in dev.** `zttp serve` and self-extracting binaries refuse to
  start without the recorder directory, the ceiling, and the cap. `zttp dev`
  uses labelled development values instead: a directory under the project's
  `.zttp/`, a 16 MiB ceiling, and a cap of 1 (recommended: decision 5 binds
  deployments, and an example should run with no flags). These dev values are
  not measured and are never used outside `zttp dev`. Alternatively, dev
  requires the settings too.
- **Q7. Replay uses an in-memory sink** and needs no setting (recommended), or
  replay requires a recorder directory like `serve`.
- **Q8. When the ceiling is reached, new turns are refused until restart**
  (recommended for M5a, with rotation later), or A2 adds rotation now.

These defaults are recommended and are not questions unless the owner objects:
records hold metadata only; the 512-byte record ceiling; the 128-bit random turn
identity; the terminal precedence of section 5; readiness 503 while the recorder
is unhealthy; the pool reserve of one runtime until A6.

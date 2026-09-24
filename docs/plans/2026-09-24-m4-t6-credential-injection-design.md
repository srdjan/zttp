# M4 T6 design note: credential injection

Status: accepted by the owner on 2026-09-24, with the recommended answer to
each question in section 9. U1 and U2 are implemented; U3 is next. Check C6 of the
[M4 release contract](2026-09-22-m4-release-contract.md) is written against
the approach this note names.

All citations are to local `main` at `e877a420`.

## 1. What T6 must deliver

The release contract (scope decision 1, the threat model, T6, and C6) asks for
this. The runtime resolves a deployment-owned secret reference. It injects the
secret into an outbound request only after it authorizes that exact request.
Tool code never sees the value. No value that a model, a caller, or an upstream
supplies can choose a credential or change an outbound destination. Redirects
stay unhandled and never carry the credential.

C6 names AE17, B8.3, and the no-retry half of AE6. AE17 asks for four
refusals: a model-selected destination, a disallowed path, a missing secret
binding, and a redirect to another destination. It also asks that no credential
reaches tool code, events, or logs. B8.3 is an oversized upstream response. The
no-retry half of AE6 is this: a disconnect after a write and before its
response gives an unknown outcome, and nothing retries it. C6 names one probe:
inject before authorization in a probe build, and AE17 must fail.

## 2. What exists today

**A proven handler cannot send an upstream credential.** The only way to get a
secret is `env()`, whose return carries `secret`
(`modules/src/platform/env.zig:23`). A secret in fetch request headers is an
error-severity diagnostic that clears `no_secret_leakage`
(`zts/src/flow_checker.zig:2402-2410`). A secret in the URL, the query, the
body, or an opaque options object is refused the same way (`:2199-2250`). A
caller's own `authorization` header carries `credential`, and forwarding it
clears `no_credential_leakage` (`:2411-2420`). T6 therefore adds the first
supported path, not a second one.

**The handler reaches outbound HTTP through `zttp:fetch` only.** The binding
exports `fetch` and `fetchWithRetry` (`modules/src/net/fetch.zig:30-98`). The
raw `fetchSync` global is refused with help that points to `zttp:fetch`
(`zts/src/strict_checker.zig:1993-1998`), and `httpRequest`
(`runtime/src/handler_instance.zig:689`) is not in the ambient namespace either.
Both exports take a literal URL, which the contract records as an egress
endpoint (`zts/src/contract_builder.zig:2185-2190`).

**One function reaches the wire for almost every call.** `fetchSyncResult`
(`runtime/src/runtime_http.zig:931-1071`) serves `fetch`, each attempt of
`fetchWithRetry`, and each attempt of a durable fetch. It parses the arguments,
authorizes the endpoint (`outboundEndpointViolation`, `:438-472`), checks the
resolved address scope, connects under one deadline, and sends the handler's
headers as `extra_headers` (`:1009-1015`). Two other senders exist. The
`zttp:io` parallel collector records a descriptor (`:1078-1122`), and a worker
thread sends it later (`doFetchWorkerInner`, `:1958`). `httpRequestNative`
(`:2222`) has its own sender. All three set `.redirect_behavior = .unhandled`
(`:1010`, `:2058`, `:2382`), so a 3xx answer goes back to the handler and
nothing follows it.

**Two retry loops resend a request.** `fetchWithRetry` retries a status in its
list, and it retries every non-object result, which includes the network-error
path (`modules/src/net/fetch.zig:172-231`, comment at `:212`). A durable fetch
retries every status of 500 or more, and a transport failure is a 599
(`runtime/src/runtime_http.zig:1418-1436`). Neither loop looks at the method or
asks whether the request reached the upstream. A POST whose connection breaks
after the send is therefore sent again.

**The handler's headers are parsed but not restricted.** `parseFetchInitOptions`
refuses an empty name and a CR or LF, and accepts every other name
(`runtime_http.zig:856-883`). A handler can set `authorization`, `host`, or any
other header.

**The pieces T6 builds on are in place.** The per-call tool grant is on the
context for exactly one handler call (`runtime/src/handler_instance.zig:1457-1464`,
`zts/src/context.zig:265-269`). The build walks each tool route's reach
(`collectToolExports`, `zts/src/contract_builder.zig:1930`) and refuses a walk it
cannot complete (`exports_unanalyzable`). T5a set the pattern for a deployment
secret: zttp.json names an environment variable (`tools/src/project_config.zig:345-361`),
the contract carries the names (`zts/src/contract_json_parser.zig:1051-1064`), the
executable graph binds the contract, and the runtime reads the value at startup
outside the handler's env allow list and zeroes it on release
(`runtime/src/tool_auth.zig:47-83`).

**Trace and durable records hold the handler's arguments, not the wire.** The
trace records the JS arguments and the JS result of `fetchSync`
(`runtime_http.zig:612`). The durable request hash covers the method, the URL,
and the body (`:1403-1405`). A header that the runtime adds after argument
parsing is in neither.

**No test upstream speaks TLS.** Every outbound test in `test-zruntime` uses a
plain-HTTP loopback listener. The only `https://` test is a handshake that the
peer never answers (`runtime/src/zruntime_tests.zig:4320-4337`), and std has no
TLS server.

## 3. The credential reference

zttp.json gains a `credentials` object. Each key is a credential name, and each
value is a reference. The reference holds names and rules, never the secret:

```json
"credentials": {
  "weather": {
    "env": "WEATHER_API_KEY",
    "endpoint": "https://api.weather.example",
    "header": "authorization",
    "scheme": "Bearer",
    "methods": ["GET"],
    "paths": ["/v1/forecast"]
  }
}
```

`env` names the environment variable that holds the value. `endpoint` is one
`scheme://host:port` endpoint in the same canonical form as the egress policy
(`zq.endpoint.normalize`). `header` is the one request header the value goes
into. `scheme` is optional; when present, the header value is the scheme, one
space, and the secret. `methods` is a non-empty list of HTTP methods. `paths` is
a non-empty list of path prefixes, each of which starts with `/`. A prefix
matches at a segment boundary only, so `/v1/forecast` matches
`/v1/forecast/today` and does not match `/v1/forecastx`. The loader refuses an
unknown field, an empty list, a duplicate name, a header outside the token
character set, a header that the runtime sets itself (`host`,
`content-length`, `transfer-encoding`, `connection`), and an endpoint that the
normalizer refuses.

The contract carries every reference, as it carries `toolAuth`, so the
executable graph binds it through the contract member. The contract version
moves from 21 to 22. A deployed artifact reads the references from its accepted
contract and ignores zttp.json, as T5a does for `auth`. An operator who changes
a reference therefore changes the artifact, and acceptance refuses the old
signature (B8.8).

**The value.** The runtime reads each referenced variable once at startup, in a
new `credential_store.zig` next to `tool_auth.zig`. The handler's env allow list
does not apply, and no JS value ever holds the secret. The store zeroes each
value on release. A server with a reference whose variable is unset or empty
does not start (AE17 "missing secret binding"). U1 applies this to every
reference and in every mode, `zttp dev` included: a credential the operator
configured and did not supply is a misconfiguration, and a start that refuses
names it at once. This is stricter than the first draft, which proposed a 503
under `zttp dev` and a refusal only for a credential a tool names.

## 4. Selection: the handler names the credential

A tool names the credential in the fetch options, with a string literal:

```ts
const res = fetch("https://api.weather.example/v1/forecast", {
  credential: "weather",
  query: { lat: input.lat, lon: input.lon }
});
```

The build refuses a `credential` value that is not a string literal, so no
model, caller, or upstream value can choose it. It also refuses a name that
zttp.json does not define, and a call whose literal URL endpoint is not the
reference's endpoint. The walk that lists a route's reachable exports also
collects the credential names the route reaches, by mention. The catalog entry
carries them as the tool's credential grant, so `ZTCAT1` moves from schema 2 to
schema 3. At runtime, a tool can use only the credentials in its own entry. A
helper that two tools share can therefore use, in each tool, only that tool's
grant (AE11 for credentials).

The rejected alternative is injection by destination: every request to a
configured endpoint gets the header. It needs no new option, but the handler
code no longer shows which calls carry authority, a tool that reaches the
endpoint for a different purpose gets the credential too, and the per-tool
grant would need a per-route host extraction that T5 decided not to build
(T5 Q3). Question Q1 asks the owner to choose.

## 5. Authorization of the exact request

The runtime adds the credential in one function, `authorizeCredential`, in
`fetchSyncResult`. The function runs after every existing check (endpoint,
address scope, argument parsing) and before the connect. It checks the final
request that the runtime is about to send, after `buildFetchUrl` appended the
query. It checks, in order:

1. A tool request is active, and the active tool's grant holds the name.
2. The accepted contract holds a reference with that name, and the store holds
   its value.
3. The final URL's canonical endpoint is equal, byte for byte, to the
   reference's endpoint.
4. The method is in the reference's `methods`.
5. The final path matches one of the reference's `paths` at a segment boundary.
   The runtime compares the path in the percent-encoded form that it sends, and
   it refuses a path that holds a `.` or `..` segment or an encoded `/`.
6. No handler header has the reference's header name, compared without case.
   The runtime refuses the request. It does not replace the handler's header,
   because a silent replacement hides an attempt to choose a credential.
7. The scheme is `https`, or the host is an IPv4 or IPv6 loopback literal
   (question Q3).

A refusal returns a 599 fetch error with a new code, `CredentialRefused`, and a
detail that names the check from a closed enum (`not_granted`,
`not_configured`, `endpoint_mismatch`, `method_not_allowed`,
`path_not_allowed`, `header_collision`, `plaintext`). The detail never holds
the value. Only after every check passes does the runtime append the header to
`extra_headers`. The C6 probe moves the append in front of the checks, and every
AE17 refusal test must then fail.

**The other senders.** A credential in the `zttp:io` parallel collector, in
`fetchWithRetry`, in a durable fetch, or in `httpRequest` is refused with
`CredentialRefused` and `path_unsupported`, at runtime in each collector or
loop and at build where the call is visible. This keeps one injection point and
takes both retry loops out of scope. Question Q2 asks the owner to confirm.

**Redirects.** All senders keep `.redirect_behavior = .unhandled`. A 3xx
answer returns to the tool, and nothing sends a second request. The tool cannot
send one to the `Location` either: the URL of every fetch is a literal, and
check 3 refuses an endpoint that is not the reference's.

## 6. Outcome and retry (AE6, no-retry half)

A credentialed request is sent once. When the send completed and no response
head arrived, the fetch error code is a new `OutcomeUnknown`, not
`ResponseHeadFailed` or `TimedOut`. The runtime then knows that the request may
have reached the upstream. A failure before the send completed keeps its
current code. The change applies to credentialed requests only, so the codes of
other fetches do not change. The rule is testable today: the only path that
can carry a credential does not retry (section 5), and the test is a loopback
upstream that reads the request and closes the connection with no answer.

## 7. The value stays out of values, failures, and logs

The value exists in three places only: the store, the header list of one
request, and the TLS or TCP write buffer. It is not in the JS request, the JS
response, a fetch error, the trace (which records the JS arguments), the durable
hash, or a policy event. A test sets the variable to a unique marker, runs the
positive and negative cases with a trace file and the security event log enabled, and
searches the trace, both logs, every response body, and every error detail for
the marker. Every search must find nothing.

**An upstream can echo the value.** An upstream that returns its request
headers puts the credential in the response that the tool reads. The runtime
can refuse a response whose head or body holds the exact value, with
`CredentialReflected`, before any JS value exists. A search of a body up to the
1 MiB default is a linear scan. It does not find an encoded echo (base64, a
hash, or compression that the runtime does not decode). Question Q4 asks
whether T6 adds the refusal with that limit stated, or records the echo as an
upstream trust assumption.

**Oversized response (B8.3).** The existing bound applies unchanged: the
runtime reads at most `max_response_bytes` and answers `ResponseTooLarge`
(`runtime_http.zig:1049-1051`). T6 adds a test that proves the bound holds for a
credentialed request, and that the tool's output validation from T3 then
refuses the tool's own 2xx body if it is too large.

## 8. Units and checks

T6 is about the size of T5a. The proposal is three units, in order:

- **U1, the reference and the store.** zttp.json `credentials`, the strict
  loader, contract version 22, and `credential_store.zig` with startup refusal.
  Owned files: `tools/src/project_config.zig`, the contract type, writer, and
  parser, `runtime/src/runtime_config.zig`, and the new store.
- **U2, selection at build.** The literal `credential` option, the build
  refusals as new `ToolCatalogRefusal` members under ZTS513 (no policy-hash
  move), the per-route credential grant, and `ZTCAT1` schema 3 through the
  kernel decoder and `AcceptedTool`. Owned files: `zts/src/contract_builder.zig`,
  `contract_types.zig`, the catalog encoder, the proof-checker decoder, and
  `runtime/src/contract_runtime.zig`.
- **U3, injection at runtime.** `authorizeCredential`, the header append, the
  refusals on the other senders, `OutcomeUnknown`, and the reflection check if
  Q4 adds it. Owned files: `runtime/src/runtime_http.zig`,
  `modules/src/net/fetch.zig` and its module spec, and the tests.

C6, applied. `test-zruntime`, `test-modules`, and `test-runtime-purity`, each
unfiltered with the exit status read directly, plus `test-proof-checker` and
`test-contract-golden` for U2. Positive: an authorized tool request reaches a
loopback upstream, which records that the header holds the scheme and the
value. Negative: one test per `CredentialRefused` reason; a model-selected
destination (a non-literal `credential`, and a literal URL at another
endpoint), each refused at build; a redirect to a second listener, which
receives nothing; an unset variable, which stops startup; B8.3; `OutcomeUnknown`
with exactly one request at the upstream; and the marker search of section 7.
Probes: inject before authorization, and every AE17 refusal test must fail;
remove the header-collision check, and its test must fail; drop the grant
check, and the second-tool test must fail. A census iterates the refusal enum
and requires one observed refusal for each member. A gate that counts no
credential test must fail, not pass.

## 9. Questions for the owner

- **Q1. Selection.** A literal `credential` name in the fetch options, with a
  per-tool grant collected by the route walk and bound in `ZTCAT1`
  (recommended), or injection by destination with no handler-visible name.
- **Q2. Senders.** Inject on the synchronous `fetch` path only, and refuse a
  credential on `fetchWithRetry`, durable fetch, the `zttp:io` parallel path,
  and `httpRequest` (recommended: one injection point, and no retry loop can
  resend a credentialed write), or cover every sender in T6.
- **Q3. Plaintext.** Require `https`, except an IPv4 or IPv6 loopback literal
  that the reference names explicitly (recommended: a loopback upstream never
  leaves the trusted host, and the C6 tests need it because no in-repo upstream
  speaks TLS), or `https` only, with the positive test moved to a manual check
  against a real TLS upstream.
- **Q4. Reflection.** Refuse an upstream response that holds the exact value,
  with the encoded-echo limit stated (recommended), or record the echo as an
  upstream trust assumption.

These are recommended and are not questions unless the owner objects: the
reference in zttp.json and carried by the contract (the T5a pattern), a header
as the only placement (no credential in a query string), the refusal of a
colliding handler header instead of a replacement, a closed refusal enum in the
599 detail, `OutcomeUnknown` for credentialed requests only, and the three-unit
split.

## 10. Decisions

The owner answered on 2026-09-24 and accepted the recommended answer to each
question. Q1: a tool names its credential with a string literal in the fetch
options, and the route walk collects each tool's credential grant, which
`ZTCAT1` binds. Q2: the runtime injects on the synchronous `fetch` path only,
and refuses a credential on `fetchWithRetry`, durable fetch, the `zttp:io`
parallel path, and `httpRequest`. Q3: a credential requires `https`, except an
IPv4 or IPv6 loopback literal that the reference names explicitly; a host name
that resolves to loopback does not qualify. Q4: the runtime refuses an upstream
response whose head or decoded body holds the exact value, and the
documentation states that an encoded echo is not found. The recommended
defaults at the end of section 9 stand.

Two points stay open. A minimum value length would stop a false
`CredentialReflected` refusal when a short value occurs in a response by
chance. No floor is set until a real credential format gives a reason for one.
U2 adds a field to the `FetchOptions` signature. If that moves the hashes that
the DeepSeek cassettes embed, U2 needs the owner's approval for a corpus
re-record before it lands.

## 11. Progress

| Unit | Commit | Content |
|---|---|---|
| U1 | this commit | The reference, the loader, contract version 22, and the store |
| U2 | this commit | Selection at build, the per-tool grant, and `ZTCAT1` schema 3 |
| U3 | | Injection at runtime, the other senders, `OutcomeUnknown`, reflection |

## 12. U1 implementation notes and evidence

**Shape.** `packages/zts/src/credential_ref.zig` (tier `zts-base`) holds the
reference type, one validator with a `.config` and a `.canonical` form, and a
closed refusal enum of 24 members. zttp.json and the contract parser share it,
so the contract parser refuses any reference the build could not have written:
a non-canonical endpoint, header case, method or path order, name order, a
repeated name, or an empty list. `std.json` already refuses a repeated key in
zttp.json (`DuplicateField`, measured), so a second entry cannot silently
replace the first. The contract carries the references at version 22, only when
one is configured, so a contract without them keeps its earlier bytes. The
contract member of the executable graph binds them. Tools and runtime reach the
module through `handler_contract`, so `scripts/module-boundary.allow` is
unchanged. `packages/runtime/src/credential_store.zig` loads every value at
startup and zeroes it on release; the server refuses to start with
`error.CredentialValueMissing` when a variable is unset or empty. As section 3
now says, this applies to every reference in every mode.

**Gates.** Every verdict below comes from an unfiltered step with its exit status
read directly. `zig build test`: 192 of 192 steps, 8895 of 8901 tests passed, 6
skipped. `test-zruntime`: 426 of 427 passed, 1 skipped. `test-server`: 450 of
452 passed, 2 skipped. `test-zts`: 2317 of 2318 passed, 1 skipped.
`test-project-config` (40 of 40), `test-contract-golden`,
`test-vocab-envelope-drift`, `test-module-boundary`, `zig fmt --check`, and the
docs drift check passed. A census test requires every refusal member to be
observed from a real input.

**Probes.** Each mutation was confirmed present, compiled, and restored with
`/bin/cp -f` and `cmp`. A first attempt at the first probe did not compile
("pointless discard of capture"), so it proved nothing and was redone.

| Mutation | Step | Failing test |
|---|---|---|
| `.` and `..` path segments accepted | `test-zts` | `credential references refuse each rule with its named reason` |
| contract parser skips the set-order check | `test-zts` | `credential references survive a v1 and a v2 round trip, ...` |
| zttp.json `credentials` ignored | `test-project-config` | `project config reads the credential references and refuses a broken one` |
| server ignores a missing value | `test-server` | `a server refuses to start when a credential's variable is unset, ...` |

**Deployed binary.** A project whose zttp.json configures one credential was
built with `zttp build`. Started from an empty directory with the variable
unset, the binary logged `Proof accepted`, then refused: "credential 'weather'
needs environment variable ZTTP_U1_WEATHER_KEY, which is unset or empty;
refusing to serve". It therefore read the reference from its own accepted
contract. With the variable set to a marker value, it served `GET /` with 200,
and neither its log nor the response held the marker.

**Not measured in U1.** A byte change to a reference inside a deployed payload
was not probed; the contract member's binding is covered by the existing C3
checks. No request uses a credential yet: U3 adds injection.

**Found after U1.** The zts layering gate needs a row in `scripts/zts-tiers.allow`
for every tracked file in `packages/zts/src`. It reads tracked files only, and
`credential_ref.zig` was untracked when U1's aggregate run passed, so the gate
did not see it. The next aggregate run failed with "no row for
credential_ref.zig". Commit `d6140e57` adds the row. The U1 gate list above
therefore did not cover that gate.

## 13. U2 implementation notes and evidence

**Selection.** The tool route walk in `contract_builder.zig` now reads every
`zttp:fetch` call it reaches, helpers included. Four new `ToolCatalogRefusal`
members, under ZTS513 with no new code, so the policy hash does not move:

- `fetch_arguments_not_literal`: in a tool route, a `fetch` whose URL is not a
  string literal, whose options are not an object literal, or whose options hold
  a spread or a computed key, and a credentialed `fetch(init)` whose `url` is not
  a string literal.
- `fetch_as_value`: `fetch` named other than as the callee of a call.
- `credential_not_literal`: a `credential` that is not a string literal.
- `credential_sender_unsupported`: a `credential` on `fetchWithRetry`, or beside
  `durable`.

The first two are wider than section 4 said. The runtime reads `credential` from
whatever options object a call receives, so a `fetch(url, parsedInput)` or a
`const f = fetch` would let model input choose among the tool's granted
credentials. The build therefore refuses them in every tool route, credential or
not. A `fetchWithRetry` whose options the build cannot see is not refused here:
U3 refuses a credential on that sender at runtime.

The contract carries each tool's credentials as (name, endpoint) pairs, sorted,
with the endpoint canonical. The parser refuses an unsorted list, a non-canonical
endpoint, and an empty name. `FetchOptions` gains `credential?: string`.

**Against the references.** `firstCredentialBreach` compares each pair with
zttp.json's references: `credential_unknown` when no reference has the name, and
`credential_endpoint_mismatch` when the call's endpoint is not the reference's.
The build path runs it on both compile paths and refuses with
`error.CredentialBreached`, named tool, credential, and reason. A build always
compares, so a tool that names a credential when zttp.json configures none is
refused. A caller with no project context passes null and nothing is compared.
Method and path stay runtime checks (U3).

**Grant binding.** `ZTCAT1` moves to schema 3: each entry ends with its distinct
credential names, strictly increasing. The kernel decoder accepts schema 3 only
and adds `CredentialCountOutOfRange`, `CredentialNameLength`, and
`CredentialsNotOrdered`, each with a refusal case in its census. The runtime keeps
the names on `AcceptedTool` (`allowsCredential`) and refuses to start when the
contract's grant differs from the accepted catalog's. `docs/consumer-contract.md`
carries the new layout.

**Cassettes.** No re-record. `FetchOptions` is built in `module_types.zig`, not
in the binding, so the registry hash does not move, and the new refusal members
do not move the policy hash. Measured: with U2 in place, the aggregate suite
replayed the DeepSeek corpus 19 of 19 from flow artifacts.

**Gates.** Unfiltered, exit status read directly, with every U2 file staged:
`zig build test` 192 of 192 steps, 8902 of 8908 tests passed, 6 skipped;
`test-zruntime` 427 of 428, 1 skipped; `test-server` 451 of 453, 2 skipped;
`test-zts` 2321 of 2322, 1 skipped; `test-proof-checker` 183 of 183;
`test-precompile` 155 of 155; `test-project-config` 41 of 41; `test-cli`,
`test-contract-golden`, `test-vocab-envelope-drift`, `test-module-boundary`, the
zts layering gate, `zig fmt --check`, and the docs drift check passed.

**Probes.** Each mutation was confirmed present, compiled with no error, and
restored with `/bin/cp -f` and `cmp`.

| Mutation | Step | Failing test |
|---|---|---|
| `refuseCredentialBreach` returns at once | `test-cli` | `a project build refuses a tool credential zttp.json does not define` |
| non-literal options not refused | `test-zts` | `a tool catalog is refused for each build rule it breaks` |
| `fetch_as_value` never raised | `test-zts` | `a tool catalog is refused for each build rule it breaks` |
| kernel accepts unordered credential names | `test-proof-checker` | `every refusal case decodes to its exact error` |
| runtime ignores the credential grant in the cross-check | `test-server` | `promotion refuses a contract whose credential grant disagrees with the accepted catalog` |

**Known gaps.** An ordinary (non-tool) handler that passes `credential` is not
refused at build; U3's runtime refuses it, because no tool grant is active.
`zttp check` does not compare the references. `zttp dev` does not either; a
mismatch there surfaces at the call in U3.

# Runtime Limits and Failure Behavior

Reference for limits enforced by the current runtime and the way failures are
reported.

## Request And Resource Limits

| Limit | Default / Value | Notes |
|---|---:|---|
| Request body size | 1 MB | Set with `--max-body-size`. Oversized requests return `413 Payload Too Large`. |
| Request read timeout | 30 seconds | The CLI uses a fixed 30 seconds. Embedders set `ServerConfig.timeout_ms`. Slow client reads return `408 Request Timeout`. |
| Handler execution timeout | 30 seconds | The CLI uses a fixed 30 seconds. Embedders set `ServerConfig.timeout_ms`. The interpreter checks the deadline on loop back-edges and on function calls, including callbacks from native array and dict functions and JSX function components. Slow handlers return `504 Gateway Timeout` and invalidate the pool slot. |
| JavaScript memory | no explicit limit | Set per runtime with `-m` / `--memory`. |
| Runtime pool size | `cpu_count * 2`, clamped 8-128 | Set with `-n` / `--pool`. |
| Connection workers | `cpu_count * 2`, not clamped | A fixed pool, not one thread per connection. Not configurable from the CLI. |
| Accepted connection queue | 4,096 | The server closes a newly accepted connection when the bounded queue is full. |
| Value stack | 1 MB | 131,072 JSValue slots. |
| Call-stack depth | 1,024 frames | Deep recursion raises a typed error. |
| Saved-state depth | 1,024 | Exceeding the cap raises a typed error. |

Memory sizes accept suffixes: `64k`, `1m`, `256mb`, `1g`; a bare number is
bytes.

## Rate Limiting

The server does not enforce a global or per-IP rate limit. Put standalone
servers behind a reverse proxy or load balancer for network-layer limits. Use
`zttp:ratelimit` inside handlers for application-level limits such as per API
key, user, or route. The counters are shared across all runtimes of one handler
pool and survive live reload and runtime recycle. Separate processes do not
share them. `rateCheck` uses a fixed window per key.

## Failure Behavior

- Handler exceptions and engine runtime errors return `500`; the server process
  and other workers keep running. The body is proof-explained rather than a bare
  `Internal Server Error` (see [Proof-Explained 500s](#proof-explained-500s)).
- Allocation failure under an explicit `-m` ceiling returns `500`.
- Stack overflow and call-depth overflow return typed engine errors that fold
  into `500`.
- Request bodies above the fixed limit return `413` before the body is buffered.
- Slow request reads return `408`.
- Handler execution deadlines are checked on loop back-edges and on function
  calls, so recursion and nested callbacks reach them. They return `504` and the
  runtime slot is replaced before it is reused.
- Exhausted runtime pools return `503`.
- Concurrent `zttp:sql` writers wait up to 5 seconds for the SQLite database
  lock. A write that still cannot get the lock returns `500`.
- A handler panic is caught by a setjmp/longjmp boundary around each handler
  invocation, returns `500`, and quarantines the pool slot. The server and other
  workers keep running. A panic in server infrastructure outside that boundary
  still aborts the process.

## Proof-Explained 500s

The runtime maps a fault to the proof chip that guards its class, then attributes
it against what the handler proved.

| Fault class | Trigger | Guarding chips |
|---|---|---|
| Type fault | `TypeError` / `NotCallable`: an un-narrowed optional dereferenced or called, or `.value` read off an unchecked `Result`. | `optional_safe`, `result_safe` |
| Non-Response return | The handler returned something that is not a `Response`. | `exhaustive_returns` |
| Unmapped | Everything else. | none |

When a guarding chip was not proven, that chip is the predicted cause:

```text
This response path was not proven optional_safe. A value was used without narrowing its type. at 12:9
```

When every guarding chip was accepted by the artifact checker and the handler
still faulted, the fault contradicts the accepted proof, and the body says so:

```text
Possible soundness incident: the handler faulted on a path proven optional_safe/result_safe. This should be impossible; please report it.
```

An unmapped fault returns the plain `Internal Server Error` body. The trailing
`line:column` is appended only when the interpreter resolved a source location;
JS-thrown exceptions often carry none.

`--incident-log <file>` is an opt-in JSONL sink for confirmed soundness
incidents. Each is appended as one line through a shared `O_APPEND` fd:

```json
{"kind":"soundness_incident","method":"GET","path":"/users/1","proven":["optional_safe","result_safe"],"detail":"TypeError"}
```

Writing is best-effort and never fails the request path. The always-on error log
is unaffected.

## Access Logs

Request logging is enabled by default and can be disabled with `-q` /
`--quiet` in `serve` and `dev`. Each completed request writes one structured
line to the Zig logger:

```text
access method=GET path=/api status=200 duration_ms=4 request_id=abc-123
```

`request_id` comes from the `X-Request-Id` request header only when it is a
short token-like value; malformed, empty, or oversized values are logged as `-`.

## Health And Readiness Probes

The server answers two built-in paths before the handler and before
upgrade:

| Path | Meaning |
|---|---|
| `/_health` | `200 OK` with body `ok`; always answers if the process is running. |
| `/_readiness` | `200 OK` when the runtime pool has at least one free slot; `503` when all slots are in use. |

Orchestrators (Kubernetes, ECS, Fly.io) should use `/_health` for liveness and
`/_readiness` for readiness checks.

## Graceful Shutdown

On `SIGTERM` or `SIGINT`, the server stops accepting new connections and waits
for in-flight requests to finish, up to the configured request timeout. A second
signal terminates immediately.

Container stop (`docker stop`, `systemctl stop`, ECS task drain) will complete
in-flight requests before the process exits.

## Exit Codes

| Code | Meaning |
|---:|---|
| 0 | Success |
| 1 | Command failed or analyzer found errors |
| 2 | Bad input or analyzer warnings, where the command distinguishes warnings |

Common cases:

- `zttp check` / `zts check`: `0` clean, `1` errors, `2` warning-only.
- `zttp build`: `0` success, `1` build failure.
- `zttp test`: `0` all tests passed, `1` test failure, `2` invalid fixture.

Security-relevant crashes or bypasses should be reported through
[SECURITY.md](../SECURITY.md).

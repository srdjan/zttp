# M4 T1b design note: bounded connect and TLS handshake

Status: accepted and implemented on 2026-09-23. The owner accepted the file
extension, one shared budget, and DNS out of scope (section 6). The result is
recorded under T1b in the [M4 release contract](2026-09-22-m4-release-contract.md).
This note answers the design-note condition of T1b and names the approach that
check C1b is written against.

All `std/` citations are to the Zig 0.16.0 library at
`~/.zvm/0.16.0/lib/std`. Probe programs ran on macOS (Darwin 25.6.0) from a
session scratch directory. They are not committed.

## 1. Problem

T1a made the exchange deadline mandatory. [`FetchDeadline`](../../packages/runtime/src/fetch_deadline.zig)
is a watchdog thread that calls `shutdown` on the socket when `timeout_ms`
passes (`fetch_deadline.zig:37-58`). The caller can arm it only when it has a
stream, and it gets the stream only when `connectTcpOptions` returns. At that
point the TCP connect and the TLS handshake are complete. The three fetch sites
show this order: connect at `runtime_http.zig:990`, `2022`, and `2354`, then
arm at `1020`, `2062`, and `2384`.

The std client cannot bound these two phases itself:

- `ConnectTcpOptions.timeout` exists (`std/http/Client.zig:1442`), but
  `connectTcpOptions` never reads it. It calls `host.connect(io, port,
  .{ .mode = .stream })` without the timeout (`Client.zig:1460`). zttp sets the
  field at `runtime_http.zig:997`, `2029`, and `2361`, and it has no effect.
- If std forwards that timeout in a later release, the Threaded backend panics:
  `netConnectIpPosix` panics with "TODO implement netConnectIpPosix with
  timeout" when `options.timeout != .none` (`std/Io/Threaded.zig:12077`).
- The TLS handshake runs inside `Connection.Tls.create`
  (`Client.zig:304-373`), before `connectTcpOptions` returns. `Tls.create` and
  `Plain.create` are not `pub` (`Client.zig:249`, `304`).

## 2. What is and is not in scope: DNS

The fetch sites resolve the name before the connect, in `resolvedScopeDecision`
(`runtime_http.zig:548-604`). They then connect to the admitted address as a
literal (`runtime_http.zig:992`) and give the original name as `proxied_host`
for SNI (`runtime_http.zig:995`). T1b does not bound that lookup. On Linux the
std resolver has its own bound from `resolv.conf` (`timeout_seconds` and
`attempts`, `std/Io/Threaded.zig:14382-14385`). On macOS it calls blocking
`getaddrinfo` (`Threaded.zig:13708-13730`), which zttp does not bound. On
macOS the literal passed to the connect also goes through `getaddrinfo`,
because the literal fast path is Linux and Windows only
(`Threaded.zig:13498-13523`). A numeric string should not cause a network
query, but this needs verification. The contract text for T1b names only the
connect and the handshake. DNS stays out of scope, and question 3 below asks
the owner to confirm this.

`invariant_cli.zig` connects by name (`invariant_cli.zig:220-227`), so its DNS
runs inside the connect. It is not an owned file of T1b.

## 3. Approaches

| | Mechanism | Bounds | Main risk | Verdict |
|---|---|---|---|---|
| A | Own non-blocking connect, own TLS client, own HTTP/1.1 | connect, handshake, exchange | Replaces the std client at three sites | Works, but too large |
| B | Race `connectTcpOptions` against a timer with `Io.Select`, cancel the loser | connect, handshake | Cancel depends on a process-wide SIGIO handler that zttp does not own | Works only after a process fix |
| C | Vendor a patched `std/http/Client.zig` | connect, handshake | Fork of a 1867-line file on each Zig upgrade | Rejected |
| D | Watchdog without the fd, or abandon the thread | nothing safely | Use-after-free of the stack `Client` | Rejected |
| E | Wrap the Threaded `Io`, override `netConnectIp` (and `netClose`) | connect, handshake, exchange | Depends on two `Io.VTable` entries | Recommended |

### A. Own connect, own TLS, own HTTP

The connect part is simple. `std.posix.poll` is public (`std/posix.zig:1003`),
and `socket`, `fcntl`, `connect`, and `getsockopt` are available as libc
externs (`std/c.zig:10725-10737`). zttp links libc (`link_libc = true` in `build/packages.zig` and the
other `link_libc = true` rows).

The problem is the step after the connect. `RequestOptions.connection` takes
a `*Connection` (`Client.zig:1657`), but a `Connection` made outside the
client is not usable. `writer`, `reader`, `flush`, `end`, and `destroy`
recover the private `Tls` or `Plain` parent with `@fieldParentPtr`
(`Client.zig:425-485`). `ConnectionPool.addUsed` is public (`Client.zig:153`),
but it only links a node and does not help. No public path accepts an external
stream. To use a stream zttp connected itself, zttp must write its own
client: `std.crypto.tls.Client.init` over the stream
(`std/crypto/tls/Client.zig:195`), with the same SNI and CA-bundle options
that `Tls.create` passes (`Client.zig:347-367`), then a request writer and a
response reader. std has parts for the reader: `std.http.Reader` with
`receiveHead` and `bodyReaderDecompressing` (`std/http.zig:315`, `388`,
`471`), `std.http.Decompress` (`std/http.zig:707`), and
`Response.Head.parse` (`Client.zig:520`). Redirects are already unhandled at
the sites (`runtime_http.zig:1003`), so zttp does not lose that. But
`readResponseBody` (`runtime_http.zig:913-925`) and the three sites use the
std `Request` and `Response` types, so all of them change. The size is large
compared with E. Fragility is low for the connect and medium for the reader,
which uses std http internals that move between releases.

### B. Io cancellation

`Io.Select` exists with `concurrent`, `await`, and `cancel`
(`std/Io.zig:1367-1538`). Cancel in Threaded is signal-based: it sends SIGIO
to the blocked worker with `pthread_kill` (`Threaded.zig:1276-1279`). The
handler that makes SIGIO interrupt a syscall is installed in `Threaded.init`
without `SA_RESTART` (`Threaded.zig:1653-1662`). `posixConnect` and
`netReadPosix` turn `EINTR` into `error.Canceled` through `checkCancel`
(`Threaded.zig:11920-11922`, `12610-12612`). `connectTcpOptions` passes
`Canceled` through (`Client.zig:1469`), and its `errdefer` closes the stream
(`Client.zig:1461`).

Probe B (a stalled-handshake peer on loopback, and a SYN to `10.255.255.1`,
300 ms timer, one `Threaded` instance) measured this result: the timer won
at 303 ms, the connect task returned `Canceled`, and no fd leaked. The next
free fd was the same before and after each case.

The risk is the process-wide signal state. `Threaded.deinit` restores the
SIGIO handler it saved at init (`Threaded.zig:1714-1717`). zttp creates
several `Threaded` instances with overlapping lives: one for each handler
instance (`handler_instance.zig:320`) and one for each parallel fetch
(`runtime_http.zig:1970`). zttp's entry points use `std.process.Init.Minimal`
(`main.zig:6`, `cli_main.zig:6`), so std does not install a process-lifetime
handler first (`std/start.zig:699` against `724`). Probe B2 measured it. With
instance A created, then B, then A destroyed, the handler read back as 0
(default). A cancel on B then did not interrupt the blocked connect, and the
process ran until the outer 20 s limit stopped it. On macOS the default SIGIO
action discards the signal. On Linux, signal(7) gives the default action as
terminate, which would kill the process. This was not probed on Linux. B is
safe only if zttp installs its own SIGIO handler before the first `Threaded`,
in `main.zig` and `cli_main.zig`. Those files are not owned by T1b. B also
adds one concurrent task for each fetch, and its cost needs to be measured.

### C. Vendored client

A patch cannot stay small. `Tls.create` is private, and `Request` uses the
private connection types (`Client.zig:425-485`), so the whole 1867-line file
must be copied. A patched connect path must still avoid `.timeout` in
`host.connect`, or it hits the panic at `Threaded.zig:12077`. So C needs the
non-blocking connect of A or E anyway. The licence is MIT
(`~/.zvm/0.16.0/LICENSE`), so copying is allowed with the notice. Each Zig
upgrade then needs a manual merge of std fixes. Rejected: it has the cost of
E plus a fork.

### D. Watchdog without the fd

`ConnectTcpOptions` has no field for a socket from the caller
(`Client.zig:1435-1443`), so a socket created by zttp cannot be passed in. If
zttp abandons a thread that is blocked in `connectTcpOptions`, that thread
still uses the `Client`, which is a stack local freed by `defer
client.deinit()` (`runtime_http.zig:966-970`). This is a use-after-free, and
the fd and thread leak. Rejected.

### E. Io wrapper that overrides the connect

`Io` is a `userdata` pointer and a `*const VTable` (`std/Io.zig:25-26`), and
`netConnectIp` is one vtable entry (`Io.zig:241`). `HostName.connect` reaches
it through the `Io` that the caller gave it (`std/Io/net/HostName.zig:274-283`,
`363-369`, and `std/Io/net.zig:340`). The wrapper is a struct whose first field
is the `Threaded` value. The `Io` it hands out has `userdata = &threaded`, so
every entry that is not overridden gets a valid `*Threaded`. Its vtable is a
copy of `threaded.io().vtable.*` (`Threaded.zig:1806-1809`) with
`netConnectIp` replaced. The override gets its context back with
`@fieldParentPtr` on the `threaded` field.

The override opens the socket with `O_NONBLOCK`, calls `connect`, and uses
`poll` for `POLLOUT` until the fetch deadline. Then it reads `SO_ERROR`,
clears `O_NONBLOCK`, and arms the fetch's `FetchDeadline` on the new fd before
it returns. The fd must be blocking again because Threaded treats `EAGAIN` on
a socket as a bug (`Threaded.zig:12619`). std then runs the TLS handshake on a
socket that the watchdog already covers. When the watchdog shuts the socket
down, the handshake read gets end of stream, and `connectTcpOptions` returns
`TlsInitializationFailed` (`Client.zig:1470`). A poll timeout returns
`error.Timeout`, which is already a `ConnectError` (`Threaded.zig:11932`).

Probe E (300 ms bound, one wrapper) measured these results:

| Case | Result |
|---|---|
| Loopback listener that never accepts, TLS | `TlsInitializationFailed` after 302 ms, watchdog fired |
| Loopback listener with backlog 1 and one held connection, plain | `Timeout` after 300 ms |
| `10.255.255.1:443`, plain | `Timeout` after 301 ms (depends on the local network) |
| fds after all cases | no leak: only the two listeners and the held connection stayed open |

SNI and certificate checks do not change, because std still runs `Tls.create`
with `proxied_host` (`Client.zig:1466`, `347-367`). Pinning becomes stronger:
the override can refuse any address other than the one that
`resolvedScopeDecision` admitted.

Risks and their controls:

- Disarm-before-release. If the handshake fails, `connectTcpOptions` closes
  the fd in its `errdefer` (`Client.zig:1461`) while the watchdog is still
  armed. Another thread can then reuse that fd number before the caller
  disarms. The wrapper must also override `netClose` (`Io.zig:250`) so that
  it disarms and joins the watchdog before it closes an armed fd.
- Budget. `FetchDeadline` starts its clock at `arm` (`fetch_deadline.zig:43`).
  If the connect uses its own timer, the total can be close to two timeouts.
  One absolute deadline for the whole fetch is correct, but that changes
  `fetch_deadline.zig` (question 2).
- Context. `outbound_io_backend` is a `?std.Io.Threaded` value in
  `HandlerInstance` (`handler_instance.zig:136`, `320`, `399`, `468`). The
  wrapper must hold the `Threaded` by value, so that field type changes
  (question 1). This design assumes that one handler instance runs one fetch
  at a time on that backend. This needs verification before the context
  pointer is made a plain field.
- Upgrade fragility. The wrapper depends on the names and signatures of two
  vtable entries, the `Socket` fields (`std/Io/net.zig:1052-1055`), and the
  libc externs. If any of them changes, the build fails at compile time, not
  at run time. The override must fill `Socket.address` from `getsockname`, as
  Threaded does (`Threaded.zig:12086-12087`). IPv6 needs its own `sockaddr`
  and was not probed.

## 4. Recommendation

Use E. It bounds the connect with `poll` and the handshake with the existing
watchdog, with no signals. It keeps the std client, the TLS options, and the
body reader. It also gives one place to check that the connect goes to the
admitted address. Keep B as the fallback only if the owner also accepts a
process-wide SIGIO handler at startup.

## 5. Implementation steps

1. Add the wrapper type (`Threaded` by value, copied vtable, overrides for
   `netConnectIp` and `netClose`, a per-fetch context with the deadline, the
   `FetchDeadline` pointer, and the admitted address). Add unit tests for the
   non-blocking connect on IPv4 and IPv6 loopback.
2. Change `FetchDeadline` to take one absolute deadline for the fetch. Keep
   `arm`'s refusals for a zero timeout and a failed spawn.
3. Change `outbound_io_backend` and `doFetchWorkerInner`'s backend to the
   wrapper. Review note: the parallel path does not share the handler's
   backend. Each `zttp:io` worker creates its own `Threaded`
   (`runtime_http.zig:1970`), so one fetch runs on each worker backend, and
   step 3 must cover both sites. `invariant_cli.zig:185` creates a third
   backend. It moves to the wrapper too unless the owner keeps that name-based
   connect out of T1b (question 3).
4. At the three sites in `runtime_http.zig`, create the `FetchDeadline` before
   `connectTcpOptions`, set the context, remove the later `arm`, and remove
   the unused `.timeout = timeout`. Map `Timeout` and a fired watchdog during
   connect to `TimedOut`. Keep `disarm` before the connection is released.
5. Write C1b in `test-zruntime`:
   - Handshake stall: a loopback listener that never accepts. The TCP connect
     completes from the backlog, and the fetch must end with `TimedOut` near
     the deadline.
   - Connect that is never answered: a listener with `kernel_backlog = 1` and
     one held connection. On macOS the next SYN is not answered (probe:
     pending at the 505 ms bound). On Linux, the accept-queue overflow
     behavior depends on `tcp_abort_on_overflow` and SYN cookies, and it
     needs verification. The test fills the queue in a loop until a raw
     connect stays pending, or it skips with a stated reason. Review note: a
     skip is a check that ran nothing, and AGENTS.md forbids a gate that
     passes on an empty input. A skip must be visible in the step's skip
     count, and the macOS run stays the evidence for this case until a Linux
     method is measured.
   - Ceiling: each test runs the fetch on a thread and waits on an event with
     a ceiling well above the deadline. It fails when the ceiling passes.
   - Mutations: change `poll`'s timeout to infinite, and remove the arm in
     the override. Each mutation must make its test fail at the ceiling. Take
     the verdict from an unfiltered `test-zruntime` run, as AGENTS.md
     requires.
6. Run `zig build test`, `test-zruntime`, `scripts/verify.sh`, and the
   module-boundary gate.

## 6. Open questions for the owner

1. E changes files outside the owned files of T1b: `handler_instance.zig`,
   `fetch_deadline.zig`, and a new wrapper file. Do you accept this
   extension?
2. Should connect, handshake, and exchange share one `timeout_ms` budget
   (recommended), or does each phase get its own?
3. Do you confirm that DNS stays out of T1b, including the name-based connect
   in `invariant_cli.zig`? If not, a bounded resolver is a separate unit.

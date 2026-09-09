---
status: proposed
priority: P1
effort: XL
risk: high
planned_against: bf1470934915af76098c7fc7411d2e01c1498c59
created: 2026-08-07
source_article: https://ixuvo.com/blog/tigerbeetle-core-system-architecture-performance-engineering
primary_reference: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md
---

# TigerBeetle-Inspired Predictable Performance Plan

## Goal, approach, and smallest next step

**Goal:** Make Zttp's runtime performance bounded, measurable, and predictable
under normal load and overload without importing a database architecture into
an HTTP application runtime.

**Approach:** Transfer the article's durable engineering principles, then test
each one against Zttp's actual workload and supported platforms. Preserve the
bounded mechanisms Zttp already has. Measure before changing hot paths. Keep
each accepted change in a separate, reviewable delivery unit.

**Smallest next step:** Implement Delivery Unit 0 only. Add the real-process
performance receipt harness, capture a baseline, and stop for review before any
runtime behavior changes.

## Executive recommendation

The article's most useful lesson for Zttp is not "use io_uring" or "make the
server single-threaded." It is to make resource limits and workload evidence
part of the architecture.

Zttp already applies several of the relevant ideas:

- a fixed 4,096-entry connection queue with fast-fail admission;
- fixed-capacity actor mailbox rings;
- a bounded handler pool with acquisition timeout and HTTP 503 mapping;
- request-scoped arena allocation with bulk reset;
- borrowed response data and `writev` for large responses;
- compact bytecode, NaN-boxed values, inline caches, and bounded runtime
  recycling thresholds.

The plan should therefore concentrate on five verified gaps:

1. Public process-level performance claims are not reproduced by the current
   in-process benchmark suite.
2. The HTTP/1 request path copies every completed request and copies fixed
   `Content-Length` bodies again.
3. Every actor `receive()` scans the entire global in-flight lease set.
4. Runtime memory and retained actor payload bytes can still be unbounded by
   default, so there is no complete startup resource envelope.
5. Graceful-shutdown wakeup uses a permanent 1 ms polling thread.

Two additional hardening candidates are worth probing, but they must not be
implemented without evidence:

- straight-line bytecode may outrun the request deadline because deadline
  polling is concentrated at loop backedges;
- core representation sizes are intentional but not all are frozen by
  compile-time assertions.

## What the article contributes

The article emphasizes static or preallocated resources, direct and batched
I/O, single-threaded state-machine execution, cache-aware data layout, and
compile-time layout checks. TigerBeetle's primary architecture document adds
the important context: its single-thread choice is tied to a highly contended,
write-heavy transaction workload, while its static allocation model derives
worst-case object counts from startup limits.

The following table separates transferable principles from workload-specific
mechanisms.

| Article theme | Zttp decision | Reason |
| --- | --- | --- |
| Every resource has an upper bound | Adopt | This directly improves overload behavior and makes memory planning honest. |
| Preallocate known-capacity hot-path structures | Adopt selectively | Zttp already does this for connection and mailbox rings. Extend only where measurement shows allocation churn or unbounded retention. |
| Measure tail latency, not only throughput | Adopt | An HTTP runtime needs p50, p95, p99, max, error rate, RSS, and saturation evidence. |
| Batch control-plane work | Adopt selectively | Batch due actor-lease reclamation under one lock. Do not batch independent HTTP requests without a proven use case. |
| Keep hot data compact and assert representation invariants | Adopt | Freeze only layouts that are deliberate semantic or serialization contracts. |
| Single-thread the whole service | Reject | Zttp handles independent requests and deliberately uses bounded parallel runtimes. TigerBeetle's contention argument does not transfer. |
| Linux-only `io_uring` and direct I/O | Reject for this plan | Zttp supports macOS and Linux and does not own a database storage engine. The current roadmap also says evented `std.Io` networking is unsupported. |
| Fixed-size request and response records | Reject | HTTP metadata and bodies are variable-sized. Explicit byte ceilings and ownership are the correct analogue. |
| Cross-request batching | Reject pending evidence | It changes latency, ordering, cancellation, and failure behavior. No current workload justifies it. |
| New receipt signing | Reject | Performance evidence needs reproducibility, not a new cryptographic surface. Keep receipts machine-readable and unsigned. |

## Verified current-state evidence

### Performance evidence gap

- `docs/performance.md:5-34` publishes cold-start, RSS, and HTTP throughput
  figures but explicitly says `zig build bench` does not reproduce them.
- `packages/runtime/bench/benchmark.zig:538-567` measures an in-process
  `HandlerInstance`. It does not spawn the user-facing binary, open a real
  socket, drive concurrent requests, sample process RSS, or report request
  latency distributions.
- `tooling/benchmark.zig` uses best-of-five microbench results and excludes
  `httpHandler` and `httpHandlerHeavy` from regression enforcement. This is
  reasonable for microbench noise, but it cannot support public HTTP claims.
- `packages/runtime/src/runtime_pool.zig:87` enables internal pool percentile
  collection only in Debug mode. ReleaseFast tail evidence must therefore come
  from the client-side load harness.

### Request-copy gap

- `packages/runtime/src/server.zig:856-900` grows a request buffer while reading
  from the socket.
- `packages/runtime/src/server.zig:904-914` duplicates the completed request
  into the request allocator and separately retains any pipelined suffix.
- `packages/runtime/src/server.zig:2502-2530` borrows the request line and
  headers from that duplicated request storage.
- `packages/runtime/src/server.zig:2546-2554` allocates and copies a fixed-length
  body a second time.
- Chunked bodies do require decoded storage, so they are not part of the
  zero-copy acceptance criterion.

### Actor lease-scan gap

- `packages/runtime/src/actor_queue.zig:254-281` calls `reclaimExpired()` on
  every receive before dequeuing one message.
- `packages/runtime/src/actor_queue.zig:284-304` holds the global queue mutex
  while walking the entire in-flight map.
- `packages/runtime/src/actor_queue.zig:306-336` reacquires the global mutex for
  each expired message.
- The server shares this queue across pooled runtimes at
  `packages/runtime/src/server.zig:2167-2178`, so unrelated actors contend on
  the same scan.

### Incomplete resource envelope

- `packages/runtime/src/runtime_config.zig:34-38` defaults `memory_limit` to
  zero, meaning no explicit per-runtime ceiling.
- `packages/zts/src/arena.zig:361-443` enforces a combined persistent and arena
  budget only when that limit is nonzero.
- `docs/cli.md:57-67` correctly documents that `-m` is per runtime and defaults
  to unlimited.
- `packages/runtime/src/actor_queue.zig:10-15` caps mailbox count, and each
  mailbox has fixed ring capacity, but `createMessage()` at
  `packages/runtime/src/actor_queue.zig:457-489` duplicates payload bytes with
  no per-message or total retained-byte ceiling.
- `packages/zts/src/pool.zig:14-24` calls `PoolConfig.max_size` the maximum
  runtime count, but `LockFreePool.acquire()` at
  `packages/zts/src/pool.zig:348-373` creates another runtime when all idle
  slots are empty. The HTTP `HandlerPool` places a separate live permit around
  this pool, so this is an embedding API contract issue, not an unbounded HTTP
  server claim.

### Shutdown wakeup gap

- `packages/runtime/src/server.zig:2393-2407` wakes once per millisecond while
  waiting for the process shutdown flag.
- `packages/runtime/src/server.zig:2413-2420` creates this helper thread for the
  full server lifetime.
- Existing graceful-shutdown tests at `packages/runtime/src/server.zig:3423`
  and later provide the behavioral regression surface.

### Candidate deadline gap

- `packages/zts/src/interpreter.zig:77-95` checks the clock every 1,024 loop
  backedges.
- The checks are attached to backward `goto`, `loop`, and `drop_goto` paths at
  `packages/zts/src/interpreter.zig:889-907` and
  `packages/zts/src/interpreter.zig:1784-1795`.
- A long straight-line bytecode sequence may therefore run without a clock
  check. This is a hypothesis until an end-to-end timeout probe reproduces it.

## Prioritized backlog

| Rank | Improvement | Value | Confidence | Effort | Risk |
| ---: | --- | --- | --- | --- | --- |
| 0 | Real-process performance receipts | Foundational | High | L | Medium |
| 1 | Transfer request-buffer ownership and borrow fixed bodies | High | High | M | Medium |
| 2 | Replace global actor lease scans with a due-lease index | High for actor workloads | High | M | Medium |
| 3 | Compute and report a startup resource envelope | High | High | M | Low |
| 4 | Bound retained actor bytes and clarify runtime-pool limits | High | High | M | High because contracts change |
| 5 | Replace the 1 ms shutdown polling thread | Medium | High | M | Medium |
| 6 | Add compile-time representation invariants | Medium correctness value | Medium-high | S | Low |
| 7 | Add sparse instruction deadline polling only if reproduced | High correctness value | Medium | M | Medium-high |

## Scope

### In scope

- `build.zig`
- `packages/runtime/build.zig`
- `packages/runtime/bench/`
- `packages/runtime/src/server.zig`
- `packages/runtime/src/server_test.zig`
- `packages/runtime/src/actor_queue.zig`
- `packages/runtime/src/queue_runtime_callbacks.zig`
- `packages/runtime/src/test_runner.zig`
- `packages/runtime/src/zruntime_tests.zig`
- a new focused actor lease-index module if the implementation stays clearer
  than adding the algorithm to `actor_queue.zig`
- `packages/runtime/src/runtime_config.zig`
- `packages/runtime/src/runtime_pool.zig`
- `packages/runtime/src/runtime_cli.zig`
- `packages/runtime/src/cli_shared.zig`
- `packages/zts/src/pool.zig`
- `packages/zts/src/arena.zig`
- `packages/zts/src/interpreter.zig`, only if Delivery Unit 6 reproduces the
  straight-line timeout gap
- `packages/zts/src/value.zig`
- `packages/zts/src/heap.zig`
- `packages/zts/src/bytecode.zig`
- `packages/zts/src/object.zig`, only if a measured object layout becomes an
  explicit engine contract
- `docs/performance.md`
- `docs/reliability.md`
- `docs/cli.md`
- `docs/roadmap.md`
- `benchmarks/` for schemas and mechanically generated reference receipts

### Out of scope

- an `io_uring`, `O_DIRECT`, or Linux-only network backend;
- replacing bounded worker parallelism with one global runtime thread;
- request coalescing across unrelated clients;
- storage-engine work;
- changing response framing, which already uses a prebuilt fast path and
  `writev` for large bodies;
- changing the existing connection queue or mailbox ring into dynamically
  growing containers;
- performance-receipt signatures;
- hand-editing `CHANGELOG.md`, generated module specs, or benchmark receipts;
- the separate active
  `docs/plans/2026-08-07-021-zts-three-module-split-plan.md`.

## Assumptions and approval gates

1. The target remains macOS and Linux on x86_64 and aarch64 with Zig 0.16.0.
2. The threaded HTTP backend remains the supported production path.
3. Public HTTP behavior, CLI defaults, queue error variants, and embedding API
   semantics are contracts. Delivery Unit 4 must stop for owner approval before
   changing any of them.
4. A performance change must preserve correctness and improve a recorded
   workload. Structural elegance alone is not enough.
5. Per-run receipts are generated artifacts. Generate them through the harness;
   never edit their JSON by hand.
6. No benchmark with uncontrolled host contention becomes a normal CI gate.
7. Work stays local. Do not push, publish, deploy, or mutate a remote.

## Executor preflight

Run these commands before editing:

```bash
cd /Users/srdjans/Code/ZttpHome/zttp
git status --short --branch
git rev-parse HEAD
git diff --exit-code bf1470934915af76098c7fc7411d2e01c1498c59 -- \
  build.zig \
  packages/runtime/build.zig \
  packages/runtime/bench \
  packages/runtime/src/server.zig \
  packages/runtime/src/server_test.zig \
  packages/runtime/src/actor_queue.zig \
  packages/runtime/src/queue_runtime_callbacks.zig \
  packages/runtime/src/test_runner.zig \
  packages/runtime/src/zruntime_tests.zig \
  packages/runtime/src/runtime_config.zig \
  packages/runtime/src/runtime_pool.zig \
  packages/runtime/src/runtime_cli.zig \
  packages/runtime/src/cli_shared.zig \
  packages/zts/src/pool.zig \
  packages/zts/src/arena.zig \
  packages/zts/src/interpreter.zig \
  packages/zts/src/value.zig \
  packages/zts/src/heap.zig \
  packages/zts/src/bytecode.zig \
  packages/zts/src/object.zig \
  docs/performance.md \
  docs/reliability.md \
  docs/cli.md \
  docs/roadmap.md \
  benchmarks
```

Stop and re-plan if an in-scope file changed since the planned commit. Preserve
all unrelated worktree changes. In particular, do not edit, move, or delete
the separate three-module split plan named above.

Before each delivery unit:

```bash
git status --short
bash scripts/verify.sh
```

If the full verification script is already failing, record the exact failing
command and error. Do not mix an unrelated repair into a performance unit
without a separate commit and explanation.

## Delivery Unit 0: Build the performance evidence authority

### Purpose

Create a real-process harness before modifying runtime behavior. This unit is
the prerequisite for every later unit.

### Files

- Add `packages/runtime/bench/server_benchmark.zig`.
- Add `packages/runtime/bench/process_metrics.zig` for platform-specific child
  process sampling.
- Update `packages/runtime/build.zig` to expose the harness module.
- Update `build.zig` with a `bench-server` step that builds the actual optimized
  `zttp` executable and runs the harness against it.
- Add `benchmarks/server-receipt.schema.json`.
- Add `benchmarks/server-workloads.json` as reviewed input, not generated output.
- Add an ignored output directory such as `.zttp/perf/` only if the existing
  ignore policy does not already cover it.

### Design

Represent benchmark selection as a tagged union and handle every case
exhaustively:

```zig
const Workload = union(enum) {
    cold_start: ColdStartConfig,
    steady_json: HttpLoadConfig,
    fixed_upload: HttpLoadConfig,
    handler_cpu: HttpLoadConfig,
    overload: OverloadConfig,
    idle: IdleConfig,
};
```

Keep process launch, sockets, clocks, and RSS sampling at the edges. Keep
percentile calculation, receipt validation, and workload expansion as pure
functions with explicit inputs and outputs.

The harness must:

1. Spawn the user-facing `zttp serve -e ...` path in ReleaseFast mode.
2. Wait for a complete successful HTTP response, not only for a listening
   socket, before recording readiness.
3. Repeat cold starts in fresh processes. Record at least 30 samples.
4. Drive keep-alive and connection-close profiles separately.
5. Exercise concurrency values `1`, resolved runtime-pool size, and twice the
   resolved pool size.
6. Record every request latency in a pre-sized array, then sort once to compute
   p50, p95, p99, and max. The sample count is an explicit upper bound.
7. Record completed requests, HTTP status counts, connection failures,
   timeouts, offered load, achieved throughput, and test duration.
8. Sample RSS from the target child process, not `RUSAGE_CHILDREN`. On Linux,
   read the target PID's `/proc` data. On macOS, use a target-process API such
   as `proc_pid_rusage`. Normalize to bytes.
9. Validate RSS units with a test child that allocates and touches a known
   amount of memory. Reject the adapter if the observed delta is outside a
   broad documented tolerance.
10. Include commit, dirty flag, Zig version, OS, architecture, CPU model,
    logical CPU count, build mode, runtime flags, workload hash, sample count,
    warmup count, duration, and thresholds in every receipt.
11. Write JSON atomically through the harness. Never rely on shell redirection
    for the canonical receipt.
12. Terminate the child cleanly on success, failure, or interrupt and prove no
    benchmark child is left running.

Use a bounded retry loop to select a loopback port and fail with a clear error
after the configured attempts. Do not depend on a globally fixed port.

### Workload matrix

| Profile | Request | Purpose |
| --- | --- | --- |
| `cold_start` | trivial JSON handler, first request | Process launch to first complete response distribution |
| `steady_json` | GET, small JSON response | Common request throughput and tail latency |
| `fixed_upload` | POST with 1 MiB `Content-Length` body | Request copying and peak memory |
| `handler_cpu` | deterministic bounded loop in handler | Pool saturation and execution tail |
| `overload` | offered concurrency above pool and connection queue capacity | Backpressure, errors, timeouts, and recovery |
| `idle` | running server with no traffic | Idle CPU and wakeup evidence for Delivery Unit 5 |

Keep outbound I/O, SQLite, durable workflows, WebSockets, and actor queues out
of the baseline matrix. They need separate profiles because external systems
would obscure the server result.

### Acceptance criteria

- Two runs with the same binary and workload produce schema-valid receipts.
- The receipt identifies dirty trees and never labels them release evidence.
- Cold-start timing includes process spawn and a complete HTTP response.
- RSS belongs to the target PID and passes the known-allocation unit test on
  macOS and Linux.
- Overload results distinguish HTTP errors, connection rejection, and timeout.
- The harness cleans up the server child on all error paths.
- The existing in-process `bench` and `bench-check` steps remain separate and
  unchanged in meaning.
- `bench-server` is advisory and is not added to `scripts/verify.sh`.

### Verification

```bash
zig build test-server
zig build bench -Doptimize=ReleaseFast
zig build bench-check -Doptimize=ReleaseFast
zig build bench-server -Doptimize=ReleaseFast -- \
  --workloads benchmarks/server-workloads.json \
  --output .zttp/perf/baseline-1.json
zig build bench-server -Doptimize=ReleaseFast -- \
  --workloads benchmarks/server-workloads.json \
  --output .zttp/perf/baseline-2.json
git diff --check
```

### Stop condition

Stop after baseline capture. Review the receipt shape, workload duration, and
variance before changing runtime code. If RSS cannot be measured accurately on
both supported operating systems, do not publish RSS claims and do not proceed
with an aggregate child-process substitute.

## Delivery Unit 1: Remove redundant request copies

### Purpose

Transfer ownership of the completed read buffer into the request lifecycle and
borrow fixed-length bodies from it. Preserve chunked decoding and pipelining.

### Files

- `packages/runtime/src/server.zig`
- `packages/runtime/src/server_test.zig`, if the public-facade test root is the
  clearer place for full socket tests

### Design

1. Replace the implicit `[]u8` ownership returned by `readRequestData()` with an
   explicit tagged owner, for example:

   ```zig
   const RequestStorage = union(enum) {
       request_arena: []u8,
       server_owned: []u8,

       fn bytes(self: RequestStorage) []u8 { ... }
       fn deinit(self: *RequestStorage, server_allocator: std.mem.Allocator) void { ... }
   };
   ```

2. When a socket-read `ArrayList` completes a request, transfer its backing
   allocation instead of calling `allocator.dupe()` for the request prefix.
3. Copy only the pipelined suffix into `PendingRequestBytes`, because it must
   survive the current request arena reset.
4. When a request starts entirely from server-owned pending bytes, keep those
   bytes server-owned through handler execution and release them exactly once.
5. Replace the ambiguous optional body ownership with a tagged body:

   ```zig
   const ParsedBody = union(enum) {
       none,
       borrowed: []const u8,
       decoded_chunked: []u8,
   };
   ```

6. Borrow a `Content-Length` body slice from request storage.
7. Allocate only the decoded body for chunked transfer encoding.
8. Keep request storage alive through handler execution, response creation, and
   access logging. Release it after no borrowed method, URL, header, query, or
   body slice remains reachable.

Do not add reference counting. The connection worker already owns the entire
request lifetime, so one lexical owner is enough.

### Regression tests

- a maximum-sized fixed body received through a real socket;
- a fixed body split across several reads;
- two pipelined requests in one read, with a body on the first request;
- a pipelined suffix that becomes the next request's server-owned storage;
- chunked body decoding across many reads;
- malformed `Content-Length` and `Transfer-Encoding` combinations;
- early parse failure and handler failure, proving every owner is released;
- a counting allocator assertion showing that the common fixed-body path no
  longer allocates a second body-sized buffer.

### Performance acceptance

Compare Delivery Unit 0 receipts before and after on the same host:

- `fixed_upload` must not regress throughput, p99, or error rate beyond the
  receipt's predeclared noise threshold;
- the allocation-count test must prove removal of both the whole-request prefix
  duplicate and the fixed-body duplicate;
- peak RSS for the fixed-upload workload should decrease, but noisy RSS alone
  is not a correctness gate;
- all other baseline workloads must stay within their predeclared thresholds.

### Verification

```bash
zig build test-server
zig build test-zruntime
zig build bench-server -Doptimize=ReleaseFast -- \
  --workloads benchmarks/server-workloads.json \
  --output .zttp/perf/request-ownership.json
bash scripts/verify.sh
git diff --check
```

Commit this unit separately from the harness.

## Delivery Unit 2: Replace global actor lease scans

### Purpose

Make actor receive cost depend on leases that are due, not on every in-flight
message in the process.

### Files

- `packages/runtime/src/actor_queue.zig`
- optionally add `packages/runtime/src/actor_lease_index.zig`
- `packages/runtime/src/zruntime_tests.zig` only if a pooled-runtime integration
  test cannot live with the actor queue tests
- `packages/runtime/bench/server_benchmark.zig` for an opt-in actor profile

### Recommended data structure

Use an indexed binary min-heap ordered by `(leased_until_ms, message_id)`.
Store the heap index on `MessageEnvelope` while it is leased. This avoids a
second ID-to-index map and permits O(log n) removal on `ack()` and `nack()`.

Required invariants:

- exactly one heap entry exists for every entry in `inflight`;
- a pending, done, or dead message has no heap index;
- heap order uses message ID as the deterministic tie-breaker;
- mailbox retained count still includes pending and leased messages;
- ack, nack, dead-letter, and deinit remove the heap entry exactly once;
- no expiry path drops a message because a pending ring is temporarily full.

Replace `reclaimExpired()` with `reclaimDue(now_ms, budget)`. Under one global
lock, pop only due entries, remove their in-flight records, and requeue them.
Limit work per receive with an explicit budget, then expose a due-backlog count
for diagnostics and tests. A later call continues reclamation.

Do not use a heap with lazy stale entries. At high acknowledged-message
throughput, stale entries can grow with throughput times lease duration and
reintroduce an unbounded resource.

### Regression tests

- preserve priority delivery;
- preserve ack, nack, retry, and dead-letter outcomes;
- reclaim leases in deadline order with deterministic ID tie-breaking;
- ack and nack remove their heap entries;
- one actor with many unexpired leases does not force another actor's receive
  to inspect all of them;
- the per-receive reclaim budget is honored when many leases expire together;
- concurrent send, receive, ack, and expiry maintain heap and map invariants;
- randomized state-machine tests compare results against a simple reference
  model using a fixed seed printed on failure.

Add a deterministic inspection counter to the test-only index API. Assert that
receiving with `n` unexpired leases performs constant minimum checks rather
than relying only on wall-clock microbenchmarks.

### Verification

```bash
zig build test-zruntime
zig build test-server
zig build bench-server -Doptimize=ReleaseFast -- \
  --profile actor-lease \
  --output .zttp/perf/actor-lease.json
bash scripts/verify.sh
git diff --check
```

### Stop condition

Stop if the indexed structure cannot preserve delivery and retained-capacity
semantics without adding a second source of truth. Correct delivery is more
important than receive throughput.

## Delivery Unit 3: Compute a startup resource envelope

### Purpose

Turn scattered limits into one checked, explainable resource model without
changing defaults yet.

### Files

- Add `packages/runtime/src/resource_envelope.zig`.
- Update `packages/runtime/src/server.zig` to compute the envelope after CPU and
  pool-size resolution and before worker or runtime allocation.
- Update `packages/runtime/src/runtime_config.zig` if a typed input view is
  needed.
- Update `packages/runtime/bench/server_benchmark.zig` to include the envelope
  in receipts.
- Update `docs/reliability.md` and `docs/cli.md`.

### Design

Use an explicit bound type rather than sentinel integers:

```zig
const ByteBound = union(enum) {
    bounded: u64,
    unbounded: UnboundedReason,
    overflow,
};

const UnboundedReason = enum {
    runtime_memory,
    actor_retained_bytes,
    unknown_native_component,
};
```

The pure calculator must use checked arithmetic and report each component,
including:

- resolved connection worker count;
- fixed connection queue capacity;
- resolved runtime pool size;
- per-runtime memory ceiling or `unbounded`;
- runtime arena initial reservation;
- maximum request body, URL, query, header count, and parser header bytes;
- static-cache byte ceiling;
- WebSocket connection ceiling;
- actor mailbox count and per-mailbox item capacity when enabled;
- actor retained-byte budget or `unbounded`;
- outbound response byte ceiling.

Do not label the sum as maximum RSS unless every native allocation is covered.
Report three honest values instead:

1. known startup reservation;
2. known authorized variable bytes;
3. named unbounded or unknown components.

Emit one concise startup summary and include the structured envelope in
performance receipts. If any checked multiplication or addition overflows,
fail startup with a configuration error before allocating resources.

### Tests

- finite input produces the expected component totals;
- zero runtime memory produces `.unbounded(.runtime_memory)`;
- enabled actor queue without a byte budget produces
  `.unbounded(.actor_retained_bytes)`;
- multiplication and addition overflow return `.overflow` and reject startup;
- auto pool and worker counts use the same resolved values as the server;
- the human and JSON renderers exhaustively handle every bound state;
- no secrets, handler source, paths, or request data enter the report.

### Verification

```bash
zig build test-server
zig build test-cli
zig build bench-server -Doptimize=ReleaseFast -- \
  --profile steady_json \
  --output .zttp/perf/resource-envelope.json
bash scripts/verify.sh
git diff --check
```

## Delivery Unit 4: Close unbounded retention contracts

### Approval required

This unit changes external behavior and must not start until the owner approves
the exact defaults and error names.

Recommended decision:

- keep `serve` available without `-m`, but emit a clear unbounded-envelope
  warning;
- add a finite total retained-byte budget whenever `--actor-queue` is enabled;
- make the actor budget configurable and reject sends before allocation when
  the budget is exhausted;
- make `PoolConfig` describe idle capacity honestly and offer a distinct,
  explicit live-runtime ceiling for embedders.

The finite actor-queue default must be selected from Delivery Unit 0 and 2
stress receipts. Do not choose a number only because it is conventional.

### Files

- `packages/runtime/src/runtime_config.zig`
- `packages/runtime/src/runtime_cli.zig`
- `packages/runtime/src/cli_shared.zig`
- `packages/runtime/src/actor_queue.zig`
- `packages/runtime/src/queue_runtime_callbacks.zig`, which maps queue errors
  into `Result`
- `packages/runtime/src/test_runner.zig`
- `packages/runtime/src/zruntime_tests.zig`
- `packages/zts/src/pool.zig`
- `packages/runtime/src/runtime_pool.zig`
- `docs/cli.md`
- `docs/reliability.md`

### Actor retained-byte budget

1. Add `queue_max_retained_bytes` to `RuntimeConfig` and the serve CLI.
2. Account for every owned allocation associated with a message: envelope,
   source, target, payload, reply target, and dead-letter reason.
3. Reserve the full checked amount before duplicating any input bytes.
4. Roll back the reservation on every allocation or enqueue error.
5. Release it exactly once on ack, terminal dead letter cleanup, or queue
   deinitialization.
6. Return a distinct `QueueByteBudgetExceeded` result. Do not collapse it into
   allocator out-of-memory.
7. Add retained message count, retained bytes, byte limit, and rejection count
   to queue metrics without logging payloads or actor-controlled raw names.

Use a small accounting state machine so illegal transitions are
unrepresentable:

```zig
const ByteReservation = union(enum) {
    pending: usize,
    committed: usize,
    released,
};
```

### Pool contract

Choose one direct contract and test it:

- rename the existing concept to `idle_capacity` and add `max_live`, or
- enforce `max_size` as a live cap and add a separate idle-cache size.

The recommended direct cut is `idle_capacity` plus `max_live`. The HTTP
`HandlerPool` should pass the same live limit into both its permit and the
underlying pool so the invariant exists at both layers. `acquire()` must return
a typed exhaustion error instead of silently creating past `max_live`.

Because `PoolConfig` is public, do not perform this rename or semantic cut
without owner approval. Do not add a permanent compatibility alias unless the
project explicitly decides source compatibility is required.

### Tests

- exact actor byte accounting through send, receive, ack, nack, expiry, reply,
  dead letter, and deinit;
- rejection occurs before payload duplication;
- concurrent reservations never exceed the configured total;
- zero and overflowing limits are rejected at CLI boundaries;
- secrets and payloads do not appear in metrics or logs;
- `max_live` concurrent acquisitions succeed up to the limit and the next one
  fails with the expected typed error;
- releasing one runtime permits exactly one new acquisition;
- HTTP saturation still maps pool exhaustion to 503 and readiness behavior is
  unchanged.

### Verification

```bash
zig build test-zts
zig build test-zruntime
zig build test-server
zig build test-cli
zig build bench-server -Doptimize=ReleaseFast -- \
  --profile overload \
  --output .zttp/perf/bounded-overload.json
bash scripts/verify.sh
git diff --check
```

## Delivery Unit 5: Replace shutdown polling with an event

### Purpose

Remove the unconditional 1,000 wakeups per second while preserving prompt,
portable shutdown.

### Files

- `packages/runtime/src/server.zig`
- `packages/runtime/src/server_test.zig`
- optionally add a small `packages/runtime/src/shutdown_wake.zig` if it keeps
  ownership and cleanup isolated

### Recommended design

Create a POSIX socket pair or self-pipe during server startup. Poll the listener
and wake descriptor together. The shutdown path signals the wake descriptor,
and the accept loop drains it and exits. Keep all descriptors server-owned and
close them exactly once.

Requirements:

- the signal-handler path uses only operations documented as async-signal-safe;
- repeated signals are idempotent;
- a full wake pipe does not block the signal path;
- programmatic `Server.shutdown()` uses the same event path;
- accept errors caused by shutdown remain clean termination, not server errors;
- no polling thread or periodic timer remains after the cut;
- macOS and Linux use the same ownership model even if low-level calls differ.

If Zig 0.16's supported I/O APIs cannot express a portable poll plus accept
without reimplementing the server backend, stop. A lower-frequency polling
interval is not an equivalent architectural fix and should be evaluated as a
separate fallback with measured shutdown latency.

### Tests

- SIGTERM interrupts a blocked accept promptly;
- programmatic shutdown interrupts a blocked accept;
- repeated shutdown calls are safe;
- shutdown drains an in-flight request within the grace period;
- startup failure closes both wake descriptors;
- sanitizer or descriptor-count checks show no leaks over repeated server
  lifecycles;
- the idle profile shows no periodic 1 ms CPU wake pattern.

### Verification

```bash
zig build test-server
zig build bench-server -Doptimize=ReleaseFast -- \
  --profile idle \
  --output .zttp/perf/idle-event-wake.json
bash scripts/verify.sh
git diff --check
```

## Delivery Unit 6: Probe deadline coverage before changing it

### Purpose

Determine whether long straight-line bytecode can exceed the configured request
deadline. This unit is a diagnosis gate, not pre-approved implementation.

### Probe

1. Generate a handler with a large but valid straight-line sequence and no loop
   backedge.
2. Serve it through the real `zttp serve` path with a short request timeout.
3. Send a request over a real socket and measure the HTTP result and elapsed
   time.
4. Add contrast cases for a loop-heavy handler and a nested-call-heavy handler.
5. Run ReleaseFast and Debug because instruction cost and current metric paths
   differ.

### Decision

- If the straight-line case respects the deadline, record the evidence and
  close this unit without runtime changes.
- If it exceeds the deadline materially, add a sparse instruction budget or
  dispatch counter that checks the existing interrupt flag at a measured
  interval and reads the clock less frequently.

Keep clock access injected through the existing compatibility boundary. Do not
read wall time from every opcode. Benchmark the no-timeout path, normal timed
handlers, and the reproduced adversarial handler before choosing the polling
interval.

### Acceptance if a fix is needed

- all three probe classes terminate with the documented timeout result;
- the no-timeout hot path has no atomic or clock read added per opcode;
- normal handler throughput and p99 remain within the predeclared receipt
  threshold;
- timeout behavior is deterministic under an injected test clock;
- the interpreter handles the new counter exhaustively across dispatch exits,
  calls, returns, and fused instructions.

### Verification

```bash
zig build test-zts
zig build test-zruntime
zig build test-server
zig build bench-server -Doptimize=ReleaseFast -- \
  --profile handler_cpu \
  --output .zttp/perf/deadline-probe.json
bash scripts/verify.sh
git diff --check
```

### Stop condition

Do not edit the interpreter unless the real server probe reproduces the gap.

## Delivery Unit 7: Freeze deliberate representation invariants

### Purpose

Turn existing representation assumptions into build-time checks. This is
correctness hardening, not a performance claim.

### Files

- `packages/zts/src/value.zig`
- `packages/zts/src/heap.zig`
- `packages/zts/src/bytecode.zig`
- `packages/zts/src/object.zig` only if a measured object layout is deliberately
  made part of the engine contract

### Checks

Add compile-time assertions for invariants already required by the encoding:

- `JSValue` is exactly 8 bytes;
- `MemBlockHeader` is exactly 4 bytes;
- `BytecodeHeader` is exactly 11 bytes;
- `Opcode` is exactly 1 byte;
- bytecode section offsets produced by `FunctionBytecodeCompact` satisfy the
  alignment of constants, upvalues, and line entries;
- pointer payload and alignment assumptions are valid on every supported
  architecture.

Do not freeze the complete `JSObject` size merely because it is observable.
First measure cache behavior and document why a specific size is a contract.
Avoid assertions that block harmless field reordering without protecting a
serialization, pointer-tagging, or hot-cache invariant.

### Verification

```bash
zig build test-zts
zig build test-zruntime
zig build bench -Doptimize=ReleaseFast
bash scripts/verify.sh
git diff --check
```

## Delivery Unit 8: Reconcile claims and publish only supported evidence

### Files

- `docs/performance.md`
- `docs/reliability.md`
- `docs/cli.md`
- `docs/roadmap.md`
- generated reference receipts under `benchmarks/`, if the repository chooses
  to version them

### Work

1. Replace unsupported "current claim" wording with receipt-linked numbers or
   clearly labeled historical evidence.
2. Document exact workload, hardware, commit, runtime flags, sample count, and
   date beside every published number.
3. Document overload outcomes as observed: HTTP status, connection rejection,
   or timeout. Do not collapse them into one error rate.
4. Document the resource envelope and every remaining unbounded component.
5. Document new queue-budget errors and pool semantics only after Delivery Unit
   4 is approved and implemented.
6. Update the roadmap to mark each shipped unit complete and retain only
   genuinely pending work.
7. Keep performance receipts unsigned unless a separate product decision
   reintroduces signing.

If the new harness cannot reproduce the cold-start, RSS, or throughput numbers
currently listed in `docs/performance.md`, remove those numbers or label them as
historical. Do not tune the workload until it produces the desired result.

### Verification

```bash
zig build bench-server -Doptimize=ReleaseFast -- \
  --workloads benchmarks/server-workloads.json \
  --output .zttp/perf/final-1.json
zig build bench-server -Doptimize=ReleaseFast -- \
  --workloads benchmarks/server-workloads.json \
  --output .zttp/perf/final-2.json
zig build bench -Doptimize=ReleaseFast
zig build bench-check -Doptimize=ReleaseFast
bash scripts/verify.sh
git diff --check
```

## Global acceptance criteria

The plan is complete only when all approved units meet these conditions:

- every public performance number links to reproducible receipt metadata;
- request parsing has no whole-request prefix duplicate and no fixed-body
  duplicate;
- actor receive does not scan unexpired global leases;
- startup reports finite bounds and names every unbounded component;
- any approved actor byte limit rejects before allocation and never leaks a
  reservation;
- runtime-pool documentation and behavior use one unambiguous meaning for idle
  and live capacity;
- server idle operation no longer depends on a 1 ms polling thread;
- deadline polling changes exist only if the end-to-end probe required them;
- representation assertions protect only deliberate invariants;
- macOS and Linux behavior remain supported;
- `bash scripts/verify.sh` passes;
- `zig build bench-check -Doptimize=ReleaseFast` passes or has a documented,
  evidence-backed baseline update;
- final real-process receipts pass their predeclared thresholds twice on the
  same controlled host;
- no generated artifact or `CHANGELOG.md` was hand-edited;
- no unrelated worktree change was staged or modified;
- no remote was mutated.

## Global stop conditions

Stop and ask for direction if any of the following occurs:

- a delivery unit requires changing an external default, error contract, or
  public embedding API not explicitly approved;
- the baseline variance is too high to distinguish the expected improvement;
- a proposed zero-copy path cannot prove storage lifetime through handler
  completion;
- actor delivery semantics differ from the reference model;
- the shutdown event design requires dropping macOS or Linux support;
- performance improves only by weakening request limits, timeout behavior,
  isolation, or verification;
- an in-scope file has changed since this plan was grounded;
- standard checks are slow or flaky enough that a reduced gate is needed.

## Suggested local commit sequence

Keep each unit independently reviewable:

1. `perf(runtime): add real-process performance receipts`
2. `perf(server): remove redundant request body copies`
3. `perf(queue): index actor lease deadlines`
4. `feat(runtime): report the startup resource envelope`
5. `feat(queue): bound retained actor bytes`
6. `fix(zts): make runtime pool limits explicit`
7. `perf(server): replace shutdown polling with an event`
8. `fix(zts): enforce deadlines across straight-line execution`, only if the
   probe reproduces the issue
9. `refactor(zts): assert representation invariants`
10. `docs(perf): publish receipt-backed runtime evidence`

Do not combine approval-gated units 5 and 6 merely because they share the
resource-bounds theme.

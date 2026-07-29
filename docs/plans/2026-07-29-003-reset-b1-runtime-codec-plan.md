# Reset B1: Runtime Codec Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the runtime's second hand-written contract wire reader so one codec reads the contract format the product signs and attests.

**Architecture:** `packages/runtime/src/contract_runtime.zig` carries a hand-written `parseContractJson` that walks `std.json.Value` and builds a `RawRuntimeContract` directly. The canonical codec `packages/zts/src/contract_json_parser.zig` already reads the same format into a `HandlerContract`, and `contract_runtime.fromHandlerContract` already projects a `HandlerContract` into a `RawRuntimeContract` for the two live-reload call sites. This plan composes those two existing halves, proves the composition agrees with the hand-written reader on a three-part corpus, then deletes the hand-written reader and its private helpers. No new abstraction is introduced. Nothing below the reader changes.

**Tech Stack:** Zig 0.16.0. No dependencies added.

**Spec:** `docs/plans/2026-07-29-002-reset-b-design.md`, section 3.

## Global Constraints

- Zig 0.16.0. Format with `zig fmt`; the gate runs `zig fmt --check build.zig packages/`.
- Work directly on local `main`. Commit each task separately. Never push.
- Prose in ASD-STE100 Simplified Technical English. No emojis. No em dashes.
- Never use `catch unreachable` for an operation that can genuinely fail.
- The full gate is `bash scripts/verify.sh`. It must exit 0 before any commit that changes Zig sources.
- **Read the recorded exit code, not a tail of the log.** Run it as `bash scripts/verify.sh > /tmp/v.txt 2>&1; echo "EXIT=$?"`. A completion notification reports the wrapper's status, not the script's.
- **Prefer explicit line ranges over name-and-brace heuristics** when deleting code with a script. Scripted deletion by pattern over-deleted five times during Reset A.
- After any change to engine internals, run `zig build bench-check` separately. The `test` step compiles the bench binaries but does not run them.

## Ground truth, measured 2026-07-29 at commit `cee8969a`

Four call sites read a contract into the runtime. Only the first two are in scope:

| Site | Function | Error handling |
| --- | --- | --- |
| `packages/runtime/src/runtime_cli.zig:235` | `parseContractJson` | discards the error value, prints a fixed JSON line, exits 1 |
| `packages/runtime/src/server.zig:2113` | `parseContractJson` | logs `{}` of the error, returns it |
| `packages/runtime/src/live_reload.zig:460` | `fromHandlerContract` | already on the projection path |
| `packages/runtime/src/live_reload.zig:763` | `fromHandlerContract` | already on the projection path |

Neither in-scope call site switches on the error value.

`fromHandlerContract` (`contract_runtime.zig:732-841`) already populates every field of `RuntimeContract`: `env_vars`, `env_dynamic`, `routes`, `routes_dynamic`, `reads_request_state`, `properties`, `durable_workflow_properties`, `websocket`, `capabilities`, `artifact_sha256`, `policy_hash`, `modules`, `cost_envelope`. There is no field gap to close.

The runtime test suite runs in about 5 seconds:

```
$ zig build test-zruntime
EXIT=0
```

### Functions that become orphans

Verified by counting call sites across `packages/`. Every call to each of these is inside the deletion set:

| Function | Lines | Only callers |
| --- | --- | --- |
| `parseContractJson` body | 297-469 | the two in-scope call sites, replaced |
| `routeReadsRequestState` | 471-483 | `parseContractJson` |
| `parseCostEnvelope` | 485-526 | `parseContractJson` |
| `parseBoundValue` | 528-549 | `parseCostEnvelope` |
| `parseBoundProvenanceValue` | 551-565 | `parseBoundValue` |
| `readU32` | 567-572 | `parseCostEnvelope`, `parseBoundValue` |
| `readSandboxHex` | 602-606 | `parseContractJson` |
| `parseCapabilityMatrix` | 608-634 | `parseContractJson` |
| `parseProperties` | 636-666 | `parseContractJson` |
| `parseDurableWorkflowProperties` | 668-682 | `parseContractJson` |
| `getBool` | 684-689 | `parseProperties`, `parseDurableWorkflowProperties`, `parseContractJson` |

The aliases `Bound` (`:14`) and `BoundProvenance` (`:15`) are used only by `parseBoundValue` and `parseBoundProvenanceValue`, so they become orphans too. Zig does not error on an unused top-level `const`, so the compiler will not catch these. Delete them by hand.

### Functions that must survive

`deriveCostCeilings` (574-600) is `pub` and backs `ValidatedRuntimeContract.costCeilings`. `matchPath` (691-713) backs `matchesRoute`. `validateEnvVars` (715-728) is called by the server. All three sit inside the numeric span of the deletion set and must not be swept up.

This is why the deletion in Task 3 is two explicit ranges, not one.

### Divergences predicted by reading both implementations

1. **`reads_request_state` backfill.** `backfillApiRouteCollections` (`contract_json_parser.zig:1794-1804`) synthesizes `request_bodies` entries from `requestSchemaRefs` and ORs `request_bodies_dynamic` with `request_schema_dynamic`. The hand-written `routeReadsRequestState` (`contract_runtime.zig:471`) reads only the raw `requestBodies` and `requestBodiesDynamic` keys. A route with a non-empty `requestSchemaRefs` and an empty `requestBodies` therefore reads as request-dependent through the codec and request-independent through the old reader. Direction: safe. The codec disables the proof cache more often, never less.
2. **Error identity on malformed input.** The codec returns `error.InvalidJson`. The hand-written reader returns `error.InvalidContract` or a `std.json` error. Neither in-scope call site switches on the value. Direction: safe, observable in one log line.
3. **Syntax tolerance.** The codec is a hand-rolled scanner and may accept documents `std.json.parseFromSlice` rejects, such as trailing bytes after the closing brace. Direction: fewer startup failures, not more.

An unpredicted divergence, or any divergence whose direction is unsafe, blocks Task 3.

## File Structure

No files are created or deleted.

- `packages/runtime/src/contract_runtime.zig` — everything happens here. Task 1 adds the composed reader and the differential harness beside the hand-written reader. Task 3 deletes the hand-written reader, its private helpers, and the harness.

Neither `runtime_cli.zig` nor `server.zig` is edited. They call `parseContractJson` by name, and the name keeps its meaning.

---

### Task 1: Prove the composed reader agrees with the hand-written one

**Files:**
- Modify: `packages/runtime/src/contract_runtime.zig` (add one function near `:295`, add the harness and three tests at the end of the test section)

**Interfaces:**
- Consumes: `zq.handler_contract.parseFromJson(allocator, json_bytes) !HandlerContract` (`contract_json_parser.zig:75`), `fromHandlerContract(allocator, *const HandlerContract) !RawRuntimeContract` (`contract_runtime.zig:732`), `zq.writeContractJson(*const HandlerContract, writer) !void` (`handler_contract.zig:110`).
- Produces: `parseContractJsonCanonical(allocator, source) !RawRuntimeContract`, a file-private function that Task 3 renames to `parseContractJson`. Also `expectReadersAgree` and `expectSameRuntimeContract`, both test-only and both deleted in Task 3.

- [ ] **Step 1: Write the failing differential harness and its three corpus tests**

Append to the end of `packages/runtime/src/contract_runtime.zig`.

The comparison helper. It compares every field the runtime reads. The cost envelope is compared through `deriveCostCeilings` because that is the only path by which the runtime consumes it:

```zig
// ---------------------------------------------------------------------------
// Reset B1 differential harness. Temporary: Task 3 deletes this whole block
// together with the hand-written reader it compares against.
// ---------------------------------------------------------------------------

const differential_body_limit: u64 = 1 << 20;

fn expectSameRuntimeContract(want: *const RuntimeContract, got: *const RuntimeContract) !void {
    const t = std.testing;

    try t.expectEqual(want.env_vars.len, got.env_vars.len);
    for (want.env_vars, got.env_vars) |w, g| try t.expectEqualStrings(w, g);
    try t.expectEqual(want.env_dynamic, got.env_dynamic);

    try t.expectEqual(want.routes.len, got.routes.len);
    for (want.routes, got.routes) |w, g| {
        try t.expectEqualStrings(w.method, g.method);
        try t.expectEqualStrings(w.path, g.path);
    }
    try t.expectEqual(want.routes_dynamic, got.routes_dynamic);
    try t.expectEqual(want.reads_request_state, got.reads_request_state);

    try t.expectEqual(want.properties, got.properties);
    try t.expectEqual(want.durable_workflow_properties, got.durable_workflow_properties);
    try t.expectEqual(want.websocket, got.websocket);

    try t.expectEqual(want.capabilities == null, got.capabilities == null);
    if (want.capabilities) |w| {
        const g = got.capabilities.?;
        try t.expectEqualSlices(u8, &w.hash, &g.hash);
        try t.expectEqual(w.len, g.len);
        try t.expectEqualSlices(ModuleCapability, w.items[0..w.len], g.items[0..g.len]);
    }

    try t.expectEqualSlices(u8, &want.artifact_sha256, &got.artifact_sha256);
    try t.expectEqualSlices(u8, &want.policy_hash, &got.policy_hash);

    try t.expectEqual(want.modules.len, got.modules.len);
    for (want.modules, got.modules) |w, g| try t.expectEqualStrings(w, g);

    try t.expectEqual(want.cost_envelope == null, got.cost_envelope == null);
    if (want.cost_envelope) |w| {
        const g = got.cost_envelope.?;
        try t.expectEqual(w.exhaustive, g.exhaustive);
        try t.expectEqual(w.entries.items.len, g.entries.items.len);
        for (w.entries.items, g.entries.items) |we, ge| {
            try t.expectEqualStrings(we.module, ge.module);
        }
    }
    try t.expectEqual(
        deriveCostCeilings(want.cost_envelope, differential_body_limit),
        deriveCostCeilings(got.cost_envelope, differential_body_limit),
    );
}
```

The driver. It deliberately does not compare error identity, because divergence 2 is expected and safe. It does require that the two readers agree on accept versus reject:

```zig
fn expectReadersAgree(allocator: std.mem.Allocator, source: []const u8) !void {
    const legacy_result = parseContractJson(allocator, source);
    const canonical_result = parseContractJsonCanonical(allocator, source);

    if (legacy_result) |legacy_ok| {
        var legacy_mut = legacy_ok;
        defer legacy_mut.deinit();
        var canonical_mut = canonical_result catch |err| {
            std.debug.print("divergence: hand-written accepted, codec rejected with {}\n", .{err});
            return error.ReaderDivergence;
        };
        defer canonical_mut.deinit();
        try expectSameRuntimeContract(&legacy_mut.inner, &canonical_mut.inner);
    } else |legacy_err| {
        if (canonical_result) |canonical_ok| {
            var canonical_mut = canonical_ok;
            canonical_mut.deinit();
            std.debug.print("divergence: hand-written rejected with {}, codec accepted\n", .{legacy_err});
            return error.ReaderDivergence;
        } else |_| {}
    }
}
```

Corpus 1, writer round-trips. This is the wire format by construction. The second case is built specifically to hit predicted divergence 1:

```zig
fn writeAndCompare(allocator: std.mem.Allocator, hc: *const HandlerContract) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try zq.writeContractJson(hc, &aw.writer);
    try expectReadersAgree(allocator, aw.writer.buffered());
}

fn emptyDifferentialContract(allocator: std.mem.Allocator) !HandlerContract {
    return HandlerContract{
        .handler = .{ .path = try allocator.dupe(u8, "handler.ts"), .line = 1, .column = 0 },
        .routes = .empty,
        .modules = .empty,
        .functions = .empty,
        .env = .{ .literal = .empty, .dynamic = false },
        .egress = .{ .hosts = .empty, .urls = .empty, .dynamic = false },
        .cache = .{ .namespaces = .empty, .dynamic = false },
        .sql = .{ .backend = "sqlite", .queries = .empty, .dynamic = false },
        .durable = .{
            .used = false,
            .keys = .{ .literal = .empty, .dynamic = false },
            .steps = .empty,
            .timers = false,
            .signals = .{ .literal = .empty, .dynamic = false },
            .producer_keys = .{ .literal = .empty, .dynamic = false },
        },
        .scope = .{ .used = false, .names = .empty, .dynamic = false, .max_depth = 0 },
        .api = .{
            .schemas = .empty,
            .requests = .{ .schema_refs = .empty, .dynamic = false },
            .auth = .{ .bearer = false, .jwt = false },
            .routes = .empty,
            .schemas_dynamic = false,
            .routes_dynamic = false,
        },
        .verification = null,
        .aot = null,
        .properties = .{
            .pure = false,
            .read_only = true,
            .stateless = false,
            .retry_safe = true,
            .deterministic = true,
            .has_egress = false,
        },
    };
}

test "B1 differential: writer round-trip, populated contract" {
    const allocator = std.testing.allocator;

    var hc = try emptyDifferentialContract(allocator);
    defer hc.deinit(allocator);

    try hc.env.literal.append(allocator, try allocator.dupe(u8, "API_KEY"));
    try hc.modules.append(allocator, try allocator.dupe(u8, "zttp:crypto"));
    hc.durable.workflow.properties.retry_safe = true;
    hc.durable.workflow.properties.idempotent = true;
    hc.durable.workflow.properties.fault_covered = true;
    hc.websocket.on_open = true;
    hc.websocket.on_message = true;
    try hc.api.routes.append(allocator, .{
        .method = try allocator.dupe(u8, "GET"),
        .path = try allocator.dupe(u8, "/users"),
        .request_schema_refs = .empty,
        .request_schema_dynamic = false,
        .requires_bearer = false,
        .requires_jwt = false,
    });

    try writeAndCompare(allocator, &hc);
}

test "B1 differential: writer round-trip, route with requestSchemaRefs only" {
    // Targets predicted divergence 1. `backfillApiRouteCollections` in the
    // codec synthesizes request_bodies from request_schema_refs; the
    // hand-written reader does not look at request_schema_refs at all, so it
    // reports reads_request_state = false where the codec reports true.
    const allocator = std.testing.allocator;

    var hc = try emptyDifferentialContract(allocator);
    defer hc.deinit(allocator);

    var route: zq.handler_contract.ApiRouteInfo = .{
        .method = try allocator.dupe(u8, "POST"),
        .path = try allocator.dupe(u8, "/users"),
        .request_schema_refs = .empty,
        .request_schema_dynamic = false,
        .requires_bearer = false,
        .requires_jwt = false,
    };
    try route.request_schema_refs.append(allocator, try allocator.dupe(u8, "CreateUser"));
    try hc.api.routes.append(allocator, route);

    try writeAndCompare(allocator, &hc);
}
```

Corpus 2, the inline wire samples the existing tests already carry. Do not copy the literals. Each of these tests binds a `const source` and already ends with its own assertions; append one line to the end of each test body, inside the closing brace:

```zig
    try expectReadersAgree(allocator, source);
```

The nine tests, by their line at commit `cee8969a`:

| Line | Test | What its literal covers |
| --- | --- | --- |
| 890 | `parseContractJson extracts websocket event presence flags` | websocket section |
| 927 | `parseContractJson defaults websocket to all-false when section absent` | absent websocket section |
| 963 | `parseContractJson minimal` | every section present and empty |
| 1004 | `parseContractJson reads durable workflow properties` | durable workflow properties |
| 1028 | `parseContractJson with properties and routes` | properties, routes, auth flags |
| 1089 | `parseContractJson flags reads_request_state when a route reads headers` | non-empty `headerParams` |
| 1105 | `parseContractJson flags reads_request_state on dynamic header access` | `headerParamsDynamic` |
| 1419 | `parseContractJson reads sandbox block` | capabilities, artifact hash, policy hash |
| 1486 | `parseContractJson returns null capabilities when sandbox block is absent` | absent sandbox block |

Skip `test "parseContractJson: errdefer ladders close every failure path"` (`:1762`). It drives a `FailingAllocator` and comparing readers under injected allocation failure tests nothing about equivalence.

Each of these tests already has `const allocator = std.testing.allocator;` as its first line, so the appended call needs no other change.

Corpus 3, malformed input:

```zig
test "B1 differential: malformed corpus" {
    const allocator = std.testing.allocator;

    const sources = [_][]const u8{
        "",
        "{}",
        "[]",
        "not json at all",
        \\{"version": 10, "api": {"routes": [{"path": "/x"}], "routesDynamic": false}}
        ,
        \\{"version": 10, "api": {"routes": [{"method": "GET", "path": 7}], "routesDynamic": false}}
        ,
        \\{"version": 10, "env": {"literal": ["A"], "dynamic": false}, "unknownSection": {"a": 1}}
        ,
        \\{"version": 10, "env": {"literal": ["A"], "dynamic": false}
        ,
    };

    for (sources) |source| try expectReadersAgree(allocator, source);
}
```

- [ ] **Step 2: Run the tests and confirm they fail on the missing function**

```bash
zig build test-zruntime > /tmp/b1.txt 2>&1; echo "EXIT=$?"
```

Expected: non-zero exit, with a compile error naming `parseContractJsonCanonical` as undeclared.

If instead the error names `ApiRouteInfo` or `request_schema_refs`, re-derive the correct field name with `git grep -n "pub const ApiRouteInfo" packages/zts/src/contract_types.zig` and fix the corpus 1 test before continuing.

- [ ] **Step 3: Add the composed reader**

Insert immediately after `validate` and before the existing `parseContractJson`, at about `contract_runtime.zig:295`:

```zig
/// Canonical read path: the shared contract codec followed by the runtime
/// projection. It lives beside the hand-written reader only while the
/// differential tests prove the two agree. Task 3 of the B1 plan deletes the
/// hand-written reader and renames this to `parseContractJson`.
fn parseContractJsonCanonical(allocator: std.mem.Allocator, source: []const u8) !RawRuntimeContract {
    var hc = try zq.handler_contract.parseFromJson(allocator, source);
    defer hc.deinit(allocator);
    return fromHandlerContract(allocator, &hc);
}
```

- [ ] **Step 4: Run the tests and record what diverges**

```bash
zig build test-zruntime > /tmp/b1.txt 2>&1; echo "EXIT=$?"
```

Two outcomes are both acceptable at this step:

- EXIT=0. No divergence exists. Note that in the commit message and go to Task 2, which will then be a no-op recorded as such.
- Non-zero, with `error.ReaderDivergence` or a field mismatch. Record the exact failing test name and the printed message. Do not fix anything yet.

Do not "fix" a divergence by loosening `expectSameRuntimeContract`. Task 2 decides each one on its merits.

- [ ] **Step 5: Commit**

The tree may be red at this commit only if the redness is a recorded divergence, and the commit message must say so. A compile error is never acceptable.

```bash
zig fmt packages/runtime/src/contract_runtime.zig
git add packages/runtime/src/contract_runtime.zig
git commit -m "test(runtime): pin the contract reader against the canonical codec

Add the composed codec-plus-projection read path beside the hand-written
reader, and a differential harness that runs both over writer
round-trips, the existing inline wire samples, and a malformed corpus.

This proves the swap before it happens rather than after."
```

---

### Task 2: Decide every divergence the harness reported

**Files:**
- Modify: `packages/runtime/src/contract_runtime.zig` (only if a divergence needs a code change)
- Modify: `docs/plans/2026-07-29-003-reset-b1-runtime-codec-plan.md` (append the findings table below)

**Interfaces:**
- Consumes: the failing test names and messages recorded in Task 1 Step 4.
- Produces: a green `zig build test-zruntime`, and a findings table in this file that Task 3 can be reviewed against.

- [ ] **Step 1: Classify each divergence by direction**

For each divergence, answer two questions in writing, in the findings table below:

1. Which reader is more conservative? A reader is more conservative when it disables an optimization (`reads_request_state = true` disables the proof cache) or refuses input the other accepts.
2. Can the codec's behavior serve a stale response, skip a validation, or start a binary the hand-written reader would have refused? If yes, the direction is unsafe.

An unsafe direction blocks Task 3. Stop and report rather than working around it.

- [ ] **Step 2: Record the findings**

Append this table to this plan file, filled in. One row per divergence, including the three predicted ones whether or not the harness confirmed them:

```markdown
## Findings, Task 2

| # | Divergence | Predicted? | Confirmed by | Direction | Resolution |
| --- | --- | --- | --- | --- | --- |
| 1 | | | | | |
```

For a divergence with a safe direction, the resolution is to accept it and say why in one sentence. For a predicted divergence the harness did not confirm, the resolution is to say the harness did not reach it and whether that is a corpus gap.

- [ ] **Step 3: Make the harness green**

For each accepted safe-direction divergence, narrow the assertion at its exact field and write the reason inline. For the predicted `reads_request_state` case that means, inside `expectSameRuntimeContract`:

```zig
    // B1 finding 1: the codec's `backfillApiRouteCollections` synthesizes
    // request_bodies from request_schema_refs, so it reports
    // reads_request_state = true on routes the hand-written reader called
    // request-independent. Accepted: the codec is the conservative side, and
    // the only consequence is that the proof cache is skipped more often.
    if (want.reads_request_state != got.reads_request_state) {
        try t.expect(got.reads_request_state);
    }
```

Do not delete the assertion. Narrow it, so a future regression in the other direction still fails.

- [ ] **Step 4: Run the tests and verify green**

```bash
zig build test-zruntime > /tmp/b1.txt 2>&1; echo "EXIT=$?"
```

Expected: EXIT=0.

- [ ] **Step 5: Commit**

```bash
zig fmt packages/runtime/src/contract_runtime.zig
git add packages/runtime/src/contract_runtime.zig docs/plans/2026-07-29-003-reset-b1-runtime-codec-plan.md
git commit -m "test(runtime): record and resolve the contract reader divergences

Each divergence between the hand-written reader and the canonical codec
is classified by direction and recorded in the B1 plan. Safe-direction
divergences narrow their assertion at the exact field, with the reason
written down, so a regression in the unsafe direction still fails."
```

---

### Task 3: Delete the hand-written reader

**Files:**
- Modify: `packages/runtime/src/contract_runtime.zig:14-15` (delete two orphan aliases)
- Modify: `packages/runtime/src/contract_runtime.zig:297-572` (delete)
- Modify: `packages/runtime/src/contract_runtime.zig:602-689` (delete)
- Modify: `packages/runtime/src/contract_runtime.zig` (rename the canonical function, delete the harness)

**Interfaces:**
- Consumes: `parseContractJsonCanonical` from Task 1, and a green harness from Task 2.
- Produces: `pub fn parseContractJson(allocator: std.mem.Allocator, source: []const u8) !RawRuntimeContract`, implemented as the codec plus the projection. The name, signature, and error-union shape are unchanged, so `runtime_cli.zig:235` and `server.zig:2113` are not edited.

- [ ] **Step 1: Confirm the line ranges before touching them**

```bash
sed -n '295,300p;467,475p;570,578p;598,612p;686,695p' packages/runtime/src/contract_runtime.zig
```

Expected: `parseContractJson` starting at 297, `routeReadsRequestState` at 471, `readU32` ending at 572, `deriveCostCeilings` starting at 574, `readSandboxHex` at 602, `getBool` ending at 689, `matchPath` at 691.

If the numbers moved, re-derive them:

```bash
awk 'NR>=290 && NR<=730 && /^fn |^pub fn /{print NR": "$0}' packages/runtime/src/contract_runtime.zig
```

Do not edit by line number without confirming. `deriveCostCeilings` and `matchPath` sit inside the numeric span and must survive.

- [ ] **Step 2: Delete the two ranges and the orphan aliases**

Delete lines 602-689, then 297-572, in that order so the earlier deletion does not shift the later range. Then delete these two lines near the top of the file:

```zig
const Bound = zq.handler_contract.Bound;
const BoundProvenance = zq.handler_contract.BoundProvenance;
```

Zig does not error on an unused top-level `const`, so nothing will remind you.

- [ ] **Step 3: Promote the canonical reader**

Change the declaration added in Task 1 to be the public entry point, and drop the temporary wording from its doc comment:

```zig
/// Parse a contract JSON blob into a RuntimeContract: the shared contract
/// codec followed by the runtime projection. The runtime and the analyzer
/// therefore read one wire format through one reader.
pub fn parseContractJson(allocator: std.mem.Allocator, source: []const u8) !RawRuntimeContract {
    var hc = try zq.handler_contract.parseFromJson(allocator, source);
    defer hc.deinit(allocator);
    return fromHandlerContract(allocator, &hc);
}
```

- [ ] **Step 4: Delete the differential harness**

Remove `differential_body_limit`, `expectSameRuntimeContract`, `expectReadersAgree`, `writeAndCompare`, `emptyDifferentialContract`, and the three `test "B1 differential: ..."` blocks. Also remove the nine `try expectReadersAgree(allocator, source);` lines appended to the existing tests in Task 1. They all compare against a reader that no longer exists.

The compiler finds the nine appended lines for you once `expectReadersAgree` is gone, so delete the harness first and let the build enumerate them.

Keep every pre-existing test. The eleven `parseContractJson` tests, including `test "parseContractJson tolerates allocator failure at every step"` (`:1151`) and `test "parseContractJson: errdefer ladders close every failure path"` (`:1762`), now exercise the composed path unchanged. Those two are the allocation-failure gate for the new path, so a failure there is a real leak in the codec, not a stale test.

- [ ] **Step 5: Run the runtime tests**

```bash
zig build test-zruntime > /tmp/b1.txt 2>&1; echo "EXIT=$?"
```

Expected: EXIT=0, with the two allocation-failure ladder tests among those that passed.

If `test "parseContractJson: errdefer ladders close every failure path"` fails, the codec leaks on an out-of-memory unwind path. That is a real defect in `contract_json_parser.zig`. Fix it there; do not weaken the test.

- [ ] **Step 6: Run the full gate**

```bash
bash scripts/verify.sh > /tmp/v.txt 2>&1; echo "EXIT=$?"
zig build bench-check > /tmp/bc.txt 2>&1; echo "EXIT=$?"
```

Expected: EXIT=0 for both. Read the recorded exit code, not a tail of the log.

- [ ] **Step 7: Commit**

```bash
zig fmt packages/runtime/src/contract_runtime.zig
git add packages/runtime/src/contract_runtime.zig
git commit -m "refactor(runtime): read the contract through the canonical codec

Delete the runtime's second hand-written contract reader and its ten
private helpers. parseContractJson is now the shared codec followed by
the existing fromHandlerContract projection, so one reader parses the
format the product signs and attests.

Nothing below the reader changes: the Raw-to-Validated promotion and the
capability, policy, and artifact-hash checks are untouched. The two
allocation-failure ladder tests now cover the composed path."
```

---

### Task 4: Measure what the swap cost

**Files:**
- Modify: `docs/plans/2026-07-29-003-reset-b1-runtime-codec-plan.md` (append the measurements section below)

**Interfaces:**
- Consumes: the merged tree from Task 3.
- Produces: recorded before-and-after numbers for the `zttp-runtime` release binary size and for contract-parse startup. No code changes.

The spec calls this out because `parseFromJson` builds a full `HandlerContract` where the deleted reader built a small struct, and because Zig discards unreferenced declarations, so the codec being importable did not prove it was linked in. Neither number may be estimated.

- [ ] **Step 1: Measure the "before" binary size**

```bash
git stash list  # confirm clean
git checkout cee8969a -- packages/runtime/src/contract_runtime.zig
zig build -Doptimize=ReleaseFast > /tmp/before.txt 2>&1; echo "EXIT=$?"
stat -f '%z bytes  zttp-runtime (before)' zig-out/bin/zttp-runtime
git checkout HEAD -- packages/runtime/src/contract_runtime.zig
```

- [ ] **Step 2: Measure the "after" binary size**

```bash
zig build -Doptimize=ReleaseFast > /tmp/after.txt 2>&1; echo "EXIT=$?"
stat -f '%z bytes  zttp-runtime (after)' zig-out/bin/zttp-runtime
```

- [ ] **Step 3: Measure contract-parse startup**

`runtime_cli.zig`'s `attest` command parses the embedded contract and exits, so it isolates exactly the code path this plan changed. Build a deploy artifact and time it:

```bash
cd "$(mktemp -d)" && cp "$OLDPWD/examples/handler/handler.ts" .
"$OLDPWD/zig-out/bin/zttp" deploy
for i in $(seq 1 20); do ./.zttp/deploy/* attest > /dev/null; done  # warm
time (for i in $(seq 1 100); do ./.zttp/deploy/* attest > /dev/null; done)
```

Run the same 100-iteration loop against a binary built from the "before" tree. Record both wall-clock totals.

- [ ] **Step 4: Record the measurements**

Append to this plan file, filled in with the real numbers:

```markdown
## Measurements, Task 4

| Metric | Before | After | Delta |
| --- | --- | --- | --- |
| `zttp-runtime` ReleaseFast size | | | |
| 100 x `attest` wall clock | | | |

Reading:
```

Write one paragraph reading the numbers. A regression is a finding to report with its number, not automatically a blocker. State plainly whether the swap cost anything measurable.

- [ ] **Step 5: Commit**

```bash
git add docs/plans/2026-07-29-003-reset-b1-runtime-codec-plan.md
git commit -m "docs(plans): record what the B1 codec swap cost

Binary size and contract-parse startup, measured before and after rather
than estimated."
```

---

## Findings, Task 2

Measured 2026-07-29, starting at commit `a4bba5ba`. Six divergences, one predicted and five not. Findings 5 and 6 only became visible after earlier ones were resolved and the comparison could reach further into the contract.

| # | Divergence | Predicted? | Confirmed by | Direction | Resolution |
| --- | --- | --- | --- | --- | --- |
| 1 | Six `properties` flags (`no_secret_leakage`, `no_credential_leakage`, `input_validated`, `pii_contained`, `injection_safe`, `state_isolated`) read `true` through the codec where the hand-written reader reads `false`, on any contract with a missing or partial `properties` block | No | 9 tests | **Unsafe** | Fixed in `d39b17f6`. Both the codec's `parseProperties` baseline and `fromHandlerContract`'s fallback now name every field. |
| 2 | `capabilities` is always non-null through the codec; the hand-written reader returns null when the contract carries no `sandbox` block | No | `parseContractJson with properties and routes` | **Unsafe** | Fixed in `20cc00a9`. `HandlerContract.capabilities` is now optional and the parser sets it only when the sandbox block carries a `capabilities` key. |
| 3 | An all-zero stored `capabilityHash` is recomputed by the hand-written reader and kept as zeros by the codec | No | `B1 differential: writer round-trip, populated contract` | **Unsafe** | Fixed in `20cc00a9`. The codec adopts the runtime's rule: all-zero means "not stamped", so recompute. |
| 4 | `reads_request_state` is true through the codec on a route with `requestSchemaRefs` and no `requestBodies` | Yes | `B1 differential: writer round-trip, route with requestSchemaRefs only` | Safe | Accepted. The assertion is narrowed at that field, with the reason inline, so a regression in the other direction still fails. |
| 5 | The codec never parsed the top-level `modules` array, so `parseFromJson` always returned an empty module list | No | `parseContractJson reads sandbox block` | **Unsafe** | Fixed in `20cc00a9`. The runtime derives the live capability matrix from this list, so an empty one made `verifyCapabilityMatrix` compare a real hash against the empty-set hash. |
| 6 | A route object with a wrong-typed field desynchronizes the codec's scanner and the whole document is rejected, where the hand-written reader silently skipped the route | No | `B1 differential: malformed corpus` | Safe, after a projection fix | Accepted, with the direction pinned by a test. The hand-written reader's silent skip could empty the route table, and `matchesRoute` treats an empty table as "allow everything", so quiet data loss there widens the pre-filter. Separately, `fromHandlerContract` now drops a route with an empty method or path, because one unmatchable entry turns the pre-filter from "allow all" into "reject all". |

### Why 1 is unsafe

`HandlerProperties` (`contract_types.zig`) defaults `no_secret_leakage`, `no_credential_leakage`, `input_validated`, `pii_contained`, `injection_safe`, and `state_isolated` to `true`. `fromHandlerContract` (`contract_runtime.zig:769-776`) falls back with

```zig
const hp = hc.properties orelse HandlerProperties{
    .pure = false, .read_only = false, .stateless = false,
    .retry_safe = false, .deterministic = false, .has_egress = false,
};
```

which names only the six non-defaulted fields, so the other six keep their `true` defaults. "The contract asserted nothing" therefore becomes "six security properties are proven". `state_isolated` also feeds `derivePoolingPolicy`, so `read_only + state_isolated` promotes a handler to TTL runtime reuse on a contract that never proved isolation.

This is a live latent defect on the live-reload path (`live_reload.zig:460`, `:763`) today, independent of B1. It is only rarely reached there because a fresh compile usually produces a non-null `properties`.

### Why 2 and 3 are unsafe, measured

`RuntimeContract.capabilities` being null is the skip signal for `verifyCapabilityMatrix`. `HandlerContract.capabilities` is `CapabilityMatrix = .empty` (`contract_types.zig:1736`), not optional, so the codec path can never produce null. The empty matrix carries an all-zero hash, and finding 3 keeps it zero, while the live-derived matrix hashes to `e3b0c442...`. The check therefore runs and fails.

Measured directly on a contract with no `sandbox` block:

```
hand-written path validated OK
codec path REFUSED with error.CapabilityMatrixMismatch
```

Every deployed binary whose contract has no sandbox block would refuse to serve after the swap. That result is now pinned as `test "B1 differential: a no-sandbox contract must still validate"`.

### Consequence for this plan

The plan's premise was that composing two existing halves is behavior-preserving. Findings 2, 3, and 5 falsified it: the canonical codec was lossy. It dropped the module list outright and could not represent "the contract carried no sandbox block", so the projection had no way to reconstruct distinctions the wire format makes.

Resolved by teaching the codec to say what the wire says, rather than by rebuilding the lost information in the runtime. That keeps one reader, which is the point of B1. The unblocking work is `d39b17f6` and `20cc00a9`.

None of the five defects were introduced by this plan. All five were already in the tree, reachable through `parseFromJson` by every analyzer consumer and through `fromHandlerContract` by the live-reload path. The differential harness is what made them visible.

## Done when

- `packages/runtime/src/contract_runtime.zig` contains exactly one contract reader.
- `runtime_cli.zig` and `server.zig` are unedited.
- The Raw-to-Validated promotion, `verifyCapabilityMatrix`, `verifyPolicyHash`, and `verifyArtifactHash` are unedited.
- `bash scripts/verify.sh` exits 0 and `zig build bench-check` exits 0.
- Both allocation-failure ladder tests pass against the composed path.
- The findings table and the measurements table in this file are filled in.

Then write the B2 plan for the `ModuleFacts` index, per section 4 of the spec.

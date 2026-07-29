# Reset B Design: ModuleFacts and the Canonical Contract Codec

**Status:** done. All three plans executed: B1 (`2026-07-29-003`), B2 (`2026-07-29-004`), B3 (`2026-07-29-005`). Each plan records where it corrected this document. One sub-clause of wave 4 item 0b is out of scope by design and still open: generating `docs/virtual-modules/README.md` from the bindings, as B3 now does for the JSON specs.

**Source:** wave 4 item 0b of `docs/plans/2026-07-28-001-reset-simplification-plan.md`,
which sections 5.5 and 5.6 of that document describe. Reset A
(`docs/plans/2026-07-29-001-wave4-reset-a-fallible-compile-plan.md`) closed wave 4 item 0a
and is done.

**Goal:** Remove the second contract wire reader, build one immutable import and binding
index instead of re-deriving it in seven engine files, and make the Zig module bindings the
source of truth for the module spec JSON.

**Ground truth:** all line numbers and counts in this document were measured at commit
`51a8f6d8` on 2026-07-29.

## 1. Scope

Wave 4 item 0b holds three clauses. All three are in scope, as three plans executed in
order:

| Plan | Clause | Primary file |
| --- | --- | --- |
| B1 | Replace the runtime's hand-written contract reader with the canonical codec plus a runtime projection | `packages/runtime/src/contract_runtime.zig` |
| B2 | Build the immutable `ModuleFacts` index and make `ContractBuilder` consume it | `packages/zts/src/contract_builder.zig` |
| B3 | Make the typed module bindings authoritative and generate `module-specs/*.json` from them | `packages/modules/module-specs/`, `packages/zts/src/module_binding.zig` |

B1 goes first. It is mechanical, it has an exact acceptance test, it closes a drift hazard
on the artifact the product signs, and it touches no file that B2 touches. B2 goes second.
B3 goes last because it is code generation and governance rather than compile correctness,
and because B2 settles where module metadata lives.

Work happens directly on local `main`, one commit per task, as Reset A did. No branch.

## 2. Correction to the reset plan

Section 5.6 of the reset plan asks for "one immutable `ModuleFacts` index built once from
parsed and checked source, with pure projections for routes, effects, capabilities,
workflows, and proof data, replaces both the seven scans and the accumulation."

Section 5.5 of the same document says the opposite about those traversals: "The right fix
is not one grand unified visitor. The passes have genuinely different traversal orders and
state."

Measurement supports section 5.5. `ContractBuilder` is a 45-field mutable accumulator, but
only one part of it is a re-derivable index. `scanImports` (`contract_builder.zig:1136`)
is a pure function of the import declarations, and it is the part duplicated across the
other engine files. `scanCallSites` (`:1240`), `walkScopeDepth` (`:1682`),
`walkWorkflowBlock` (`:1923`), and `scanFunctionNodeForApiFacts` (`:3136`) each carry their
own traversal order and their own state. Merging them is the unified visitor that section
5.5 rejects.

Reset B therefore implements the index-only reading. Part of B2 is an edit to section 5.6
of the reset plan that records this, so the reset document stops asking for something its
own section 5.5 rejects.

## 3. B1: runtime codec unification

### 3.1 Current state

Two independent readers of one on-disk format exist:

- `packages/zts/src/contract_json_parser.zig`, 2,924 lines. The canonical codec.
  `parseFromJson` returns a fully owned `HandlerContract`.
- `packages/runtime/src/contract_runtime.zig`, 1,818 lines. Its `parseContractJson`
  (`:297-713`, about 415 lines) is a second, hand-written reader that builds a
  `RawRuntimeContract` directly from `std.json.Value`. Its doc comment states the design:
  "Extracts only the fields needed at runtime; ignores everything else."

`contract_runtime.zig` already imports `zts` (`:10`), so no new dependency edge is needed.

Four call sites read a contract into the runtime:

| Site | Function called |
| --- | --- |
| `packages/runtime/src/runtime_cli.zig:235` | `parseContractJson` |
| `packages/runtime/src/server.zig:2113` | `parseContractJson` |
| `packages/runtime/src/live_reload.zig:460` | `fromHandlerContract` |
| `packages/runtime/src/live_reload.zig:763` | `fromHandlerContract` |

The projection half of the replacement therefore already exists and is already in
production use. `fromHandlerContract` (`:732`) converts a `HandlerContract` into a
`RawRuntimeContract`.

### 3.2 Target state

`parseContractJson` becomes a composition of the canonical codec and the existing
projection:

```zig
pub fn parseContractJson(allocator: std.mem.Allocator, source: []const u8) !RawRuntimeContract {
    var hc = try zq.handler_contract.parseFromJson(allocator, source);
    defer hc.deinit(allocator);
    return fromHandlerContract(allocator, &hc);
}
```

About 415 hand-written lines are deleted. Four contract entry points collapse to one code
path.

### 3.3 What must not change

The trust boundary below the reader stays exactly as it is. The
`RawRuntimeContract` to `ValidatedRuntimeContract` promotion is a real check, not
ceremony, and every check that hangs off it is preserved unchanged:

- `validate` (`:283`) and `validatedFromInner` (`:266`)
- `verifyCapabilityMatrix`, `verifyPolicyHash`, `verifyArtifactHash`
- `derivePoolingPolicy` (`:76`)
- `validateEnvVars` (`:715`)
- the accessor surface on `ValidatedRuntimeContract` (`:215-262`)

### 3.4 Risk 1: lenience divergence

The hand-written reader is deliberately tolerant. It skips a route whose `method` or `path`
is missing or non-string, and it ignores every field it does not need. The canonical codec
reads far more of the document and may reject or interpret differently what the old reader
tolerated. This matters because the contract is embedded in deployed self-extracting
binaries, so a behavior change here is a change in whether a deployed binary starts.

Decision: preserve current behavior exactly. The codec-plus-projection path must produce a
`RawRuntimeContract` identical to the hand-written one on every input, and must introduce
no new startup failure.

Evidence: a differential test, written and landed as the first task of B1, before any
deletion. It adds the composed reader under a private name, leaves the hand-written reader
in place and public, and runs both over three corpora:

- writer round-trips. A `HandlerContract` is serialized with
  `contract_json_writer.writeContractJson` and fed to both readers. This is the wire format
  by construction. The existing test at `contract_runtime.zig:1337` already uses this shape.
- the contract JSON inline in the existing `parseContractJson` tests, which covers the
  sandbox block, websocket flags, durable workflow properties, routes, and header params.
- a corpus of hand-built malformed contracts covering a missing `env` object, a missing
  `api` object, a route missing `method`, a route with a non-string `path`, an unknown
  top-level section, an empty object, and a truncated document.

Note the four committed goldens in `packages/tools/tests/fixtures/contract/` are NOT valid
input here. They are `check --json --contract` envelopes of the form
`{"success":true,"proof":{...}}`, not the contract.json wire format. They are B2's
acceptance artifact, not B1's.

The test asserts field-identical `RawRuntimeContract` results, and for rejected input that
both readers fail. Three divergences are predicted from reading the two implementations,
and each must be confirmed or refuted by the test before the deletion lands:

1. **`reads_request_state` backfill.** `backfillApiRouteCollections`
   (`contract_json_parser.zig:1794-1804`) synthesizes `request_bodies` entries from
   `requestSchemaRefs` and ORs `request_bodies_dynamic` with `request_schema_dynamic`. The
   hand-written `routeReadsRequestState` (`contract_runtime.zig:471`) reads the raw
   `requestBodies` and `requestBodiesDynamic` keys only. A route with a non-empty
   `requestSchemaRefs` and an empty `requestBodies` therefore reads as request-dependent
   through the codec and request-independent through the old reader. The direction is safe:
   the codec disables the proof cache more often, never less.
2. **Error identity on malformed input.** The codec returns `error.InvalidJson`; the
   hand-written reader returns `error.InvalidContract` or a `std.json` error. Neither call
   site switches on the value: `server.zig:2113` logs it and returns it, `runtime_cli.zig:235`
   discards it. The change is observable in one log line.
3. **Syntax tolerance.** The codec is a hand-rolled scanner and may accept documents that
   `std.json.parseFromSlice` rejects, such as trailing bytes after the closing brace. The
   direction is fewer startup failures, not more.

A divergence whose direction is unsafe blocks the deletion. A safe-direction divergence is
recorded in the plan, and the affected test is updated with the reason written down.

### 3.5 Risk 2: artifact size and cold start

`parseFromJson` allocates a full `HandlerContract` where the old reader allocated a small
struct. Whether this costs bytes in `zttp-runtime` or time at startup is unknown. Zig
discards unreferenced declarations, so the codec being importable does not prove it is
already linked into the runtime binary.

This must be measured, not estimated. The B1 plan records, before and after:

- `zig build -Doptimize=ReleaseFast` binary size for `zttp-runtime`,
- a cold-start timing for a self-extracting binary with an embedded contract.

A regression is a finding to be reported with its number, not automatically a blocker.

## 4. B2: the ModuleFacts index

### 4.1 Current state

Seven engine files derive import and binding information independently. Measured by hits on
`import_decl`:

```
 9  packages/zts/src/path_generator.zig
 7  packages/zts/src/handler_verifier.zig
 5  packages/zts/src/strict_checker.zig
 5  packages/zts/src/flow_checker.zig
 5  packages/zts/src/effect_inference.zig
 5  packages/zts/src/contract_builder.zig
 5  packages/zts/src/bool_checker.zig
```

Inside `ContractBuilder`, `scanImports` populates four fields that are pure functions of the
import declarations and the module binding registry:

- `generic_bindings: std.ArrayList(GenericBinding)` (`:94`, type at `:181`), mapping a local
  slot to `module_specifier`, `binding_name`, contract extraction rules, and contract flags
- `extension_bindings: std.ArrayList(ExtensionBinding)` (`:140`, type at `:192`), the same
  for partner modules, with extraction rules borrowed from the live `ManifestRegistry`
- `modules_list: std.ArrayList([]const u8)` (`:97`)
- `functions_map: std.ArrayList(HandlerContract.FunctionEntry)` (`:98`)

### 4.2 Target state

A new `ModuleFacts` type owns those four things, built once after parse and check, and
immutable after construction. `ContractBuilder` stops deriving them and reads them.

The other traversals are untouched in their order and their state. `scanCallSites`,
`walkScopeDepth`, `walkWorkflowBlock`, and `scanFunctionNodeForApiFacts` keep their private
accumulators. They lose only the import discovery they currently repeat.

The `ModuleFacts` API is designed so the other six consumers can adopt it. None of them
migrate in B2. Their migration is wave 4 item 4 and gets its own plan, because the contract
goldens do not cover their output and each needs its own equivalence evidence.

### 4.3 Ownership and lifetime

`ModuleFacts` holds borrowed extraction rules from the `ManifestRegistry`, exactly as
`ExtensionBinding` does today, so the registry must outlive the facts. Strings that the
contract later owns keep being duped by `ContractBuilder` at the point they enter the
contract, so the existing "all strings in the contract are owned" invariant
(`contract_builder.zig:80-81`) is unchanged.

### 4.4 Acceptance

Byte-identical contract goldens:

```
packages/tools/tests/fixtures/contract/durable_approval.contract.golden.json
packages/tools/tests/fixtures/contract/jsx.contract.golden.json
packages/tools/tests/fixtures/contract/modules_all.contract.golden.json
packages/tools/tests/fixtures/contract/plain_ts.contract.golden.json
```

If a single byte moves, the change is wrong. These goldens were pinned in commit `f77f6531`
for exactly this purpose.

B2 also edits section 5.6 of the reset plan as described in section 2 above.

## 5. B3: descriptors as the source of truth

### 5.1 Current state

24 JSON files live under `packages/modules/module-specs/`, in six category directories.
Each carries `schemaVersion`, `specifier`, `source`, `requiredCapabilities`, and
`exports[{name, effect, returns}]`. They are hand-edited.

Every one of those fields except `source` already exists in the Zig bindings.
`ModuleBinding` declares `specifier` and `required_capabilities`; `FunctionBinding` declares
`name`, `effect`, and `returns`.

Three consumers and tripwires exist today: `packages/tools/src/module_audit.zig`,
`packages/zts/src/manifest_registry.zig`, and the module section of
`scripts/check-docs-drift.sh`, which cross-checks the registry in
`packages/zts/src/builtin_modules.zig` against both `docs/virtual-modules/README.md` and the
JSON spec count.

### 5.2 Target state

The bindings become authoritative. A renderer emits the 24 JSON files from them, with a
`--check` mode as the CI drift gate. This mirrors the existing `spec-render` /
`spec-render --check` pair for the semantics registry
(`packages/zts/src/semantics_render.zig`, `packages/tools/src/semantics_cli.zig:58-74`),
which is the pattern the repository already trusts for generated specs.

`source` is the one field with no binding-side home. It is resolved from the module-to-path
registry in `packages/zts/src/builtin_modules.zig`, which already holds that mapping, rather
than by adding a hand-maintained field to every binding.

`scripts/check-docs-drift.sh` keeps its module section. Its role changes: it stops being the
thing that catches hand-edit drift and becomes the thing that proves the generator ran.

### 5.3 Acceptance

On its first run, the generator must emit output byte-identical to the 24 committed files.
The generator is proven against the current hand-written state before it becomes
authoritative. Only after that does the `--check` gate go into `scripts/verify.sh`.

## 6. Global constraints

Carried forward from Reset A, because they were earned:

- Zig 0.16.0. Format with `zig fmt`; the gate runs `zig fmt --check build.zig packages/`.
- Work directly on local `main`. Commit each task separately. Never push.
- Prose in ASD-STE100 Simplified Technical English. No emojis. No em dashes.
- Never use `catch unreachable` for an operation that can genuinely fail.
- The full gate is `bash scripts/verify.sh`. It must exit 0 before any commit that changes
  Zig sources.
- Read the recorded exit code, not a tail of the log. Run it as
  `bash scripts/verify.sh > /tmp/v.txt 2>&1; echo "EXIT=$?"`. A completion notification
  reports the wrapper's status, not the script's.
- Prefer explicit line ranges over name-and-brace heuristics when deleting code with a
  script.
- After any change to engine internals, run `zig build bench-check` separately. The `test`
  step compiles the bench binaries but does not run them.

## 7. Gates by plan

| Plan | Gate |
| --- | --- |
| B1 | Differential reader equivalence over writer round-trips, the existing inline test contracts, and the malformed corpus; the two allocation-failure ladder tests still green against the composed path; recorded `zttp-runtime` release binary size and cold-start timing, before and after |
| B2 | Byte-identical contract goldens, all four |
| B3 | Generated JSON byte-identical to the 24 committed files on first run, before the `--check` gate is added to `scripts/verify.sh` |
| All | `bash scripts/verify.sh` exit 0, which includes `zig fmt --check` at `scripts/verify.sh:96-97`, plus `zig build bench-check` run separately |

## 8. Explicitly out of scope

- Migrating `path_generator`, `handler_verifier`, `strict_checker`, `flow_checker`,
  `effect_inference`, or `bool_checker` onto `ModuleFacts`. That is wave 4 item 4.
- Moving `precompile.zig`'s orchestration into `pipeline.zig`. That is also wave 4 item 4.
- Any change to the `RawRuntimeContract` to `ValidatedRuntimeContract` promotion or to the
  capability, policy, and artifact-hash checks.
- Merging the call-site, workflow, scope, and API traversals in `contract_builder.zig`. See
  section 2.
- Deleting the module section of `scripts/check-docs-drift.sh`.

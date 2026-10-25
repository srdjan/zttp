# Architecture

zttp is a Zig monorepo with three runtime-facing binaries:

- `zttp`: developer CLI, local server, proof tools, expert mode, deploy.
- `zttp-runtime`: minimal runtime template used by self-contained deploy
  artifacts.
- `zts`: analyzer/compiler CLI for IDEs, CI, and machine integrations.

The deployed runtime does not link the expert agent. The analyzer and runtime
share the same `zts` engine and contract logic.

## Packages

| Path | Role |
|---|---|
| `packages/runtime/` | HTTP server, runtime adapter, CLI, local deploy, proof ledger, and the proof review and card types in `src/proofs/`. |
| `packages/zts/` | Parser, type checker, verifier, bytecode, interpreter, contracts, virtual-module registry. |
| `packages/tools/` | Precompile pipeline and analyzer command registry shared by `zttp` and `zts`. |
| `packages/modules/` | SDK-pure virtual modules and module spec JSON. |
| `packages/zttp-sdk/` | Extension SDK types and helpers for native modules. |
| `packages/proof-checker/` | The consumer acceptance kernel. A leaf: it imports `std` and its own siblings, allocates nothing, and reaches no filesystem, clock, process, network, or signer. It decides whether an artifact may serve. |
| `packages/pi/` | Compiler-in-the-loop expert agent linked into `zttp` only. |

`build.zig` and the files under `build/` wire the packages, build options, tests, smoke checks, and release
steps.

### Split modules

A few large modules are a facade plus files that each own one responsibility. The facade
re-exports every public name, so a caller imports the same file as before.

- `packages/tools/src/precompile.zig` keeps the compile pipeline and the shared types.
  `precompile_cli.zig` holds the `-Dhandler` command line and the generated Zig writers.
  `precompile_check_run.zig` is the CHECK facade, and `precompile_contract.zig` builds the
  contract and policy. `precompile_sql.zig`, `precompile_reports.zig`,
  `precompile_virtual_imports.zig`, and `precompile_stderr.zig` hold the smaller parts.
- `packages/tools/src/agent_protocol.zig` re-exports the protocol. One file owns each operation:
  `agent_protocol_envelope.zig` (operation table, schema hash, envelope), `_request`, `_dispatch`,
  `_meta`, `_simulate`, `_verify`, `_check`, `_canon`, and `_cli`.
- `packages/zts/src/parser/type_syntax.zig` re-exports the type syntax. `type_syntax_store.zig`
  holds the records and the store, `type_syntax_scan.zig` the admission scanners, and
  `type_syntax_parser.zig` the type parser.
- `packages/runtime/src/server_connection_pool.zig` holds `ConnectionPool` and the access-log
  helpers. The static path checks stay in `server_static.zig`.
- `flow_checker.zig`, `pipeline.zig`, and the CHECK facade keep their tests in sibling files
  (`flow_checker_tests.zig`, `pipeline_tests.zig`, `precompile_check_tests.zig`).
- Four leaf modules in `packages/zts/src` hold helpers that several analyzers share, so no analyzer
  imports a peer for one function: `binding_key.zig`, `handler_function.zig`, `ok_record.zig`, and
  `source_line.zig`.

## Request Flow

1. The server parses HTTP input, enforces request limits, and builds a request
   object.
2. A `HandlerPool` slot provides an isolated `ZRuntime`.
3. The runtime compiles or reuses handler bytecode, then invokes
   `function handler(req)`.
4. The handler returns a `Response`.
5. The server validates response headers, writes the response, and releases the
   runtime slot.

Each request runs with isolated runtime state. Request isolation is
arena-based: request-scoped allocations are bulk-reset between requests. The
engine includes a garbage collector, but the default serving configuration
uses the hybrid arena allocator, which disables collection on the serving path
(`Context.setHybridAllocator` in `packages/zts/src/context.zig`).

## Expert Model Context

The expert agent keeps two views of a session. The v4 event journal and raw
`Transcript` entries are append-only proof and audit authority. A separate
projection supplies the model with the latest validated summary plus a retained
suffix of raw entries. Ledger export, proof reconstruction, patch-chain hashes,
and workspace state never derive authority from a summary.

`session/events.zig` decodes event payloads into a typed record whose borrowed
fields belong to one parsed envelope. Journal sequence validation and transcript
reconstruction use exhaustive switches over those records. They retain separate
acceptance rules for legacy parts, session payloads, checkpoints, and version
errors. `Reader` checks framing only. Tail recovery validates complete frames
before it repairs an incomplete tail, then derives the entry sequence.

`RecoveredWorkspace` in `change_transaction.zig` acquires the workspace lock,
recovers pending work, and then exposes writes and pending receipts to the
expert loop. Recovery observes markers in precedence order and validates the
manifest and images before classifying a prepared transaction. A pure planner
checks each target digest before the next target read. It publishes a plan only
after all required observations succeed. One interpreter performs the planned
writes, synchronization, candidate verification, and commit marking. A failed
commit makes the owner unusable until it is closed and reopened. Committed
receipts remain pending until the session records and acknowledges them in
persisted sessions. Workspace-only operation can acknowledge without a
durable session journal.

All provider adapters serialize a shared `ModelRequestSnapshot`. The snapshot
measures system, tools, active history, transient text, framing, wire bytes, and
model limits before transport. Typed tool context policies produce exact,
replayable preview, or structured digest results. No generic byte slice is used
as provider-visible context.

Compaction selection, serialization, file-fact extraction, prompt construction,
and summary validation are pure functions in `packages/pi/src/compaction.zig`.
`AgentSession` owns provider calls and the transactional checkpoint boundary. A
standalone summarizer has no tools or normal history. After validation, the
session flushes pending raw frames, synchronizes a compaction checkpoint, and
installs an already-built projection without allocation. Normal request
admission and one-shot overflow recovery wrap the provider client at the shared
model-call seam, so TTY, print, JSON, and resumed sessions use one policy.

## Execution State Ownership

Each `Context` owns the authorization scope for its current native-module call
Nested calls replace this borrowed scope and restore the parent on return.
Alternating contexts on one worker thread cannot share ambient authority.
A panicked runtime is quarantined. `Context.deinit` clears the scope before
module-state destructors run.

JSON object-shape entries contain pool-local hidden-class indexes. Their cache
therefore belongs to `HiddenClassPool` and has the same lifetime as the indexes
it stores, rather than the lifetime of a worker thread.

`HandlerInstance` composes `runtime_http.HttpState`, which owns body-consumption
tracking and borrows the HTTP prototypes owned by `Context`. Both request reset
and pool release call the state's reset operation before request storage is
reused; teardown releases only the tracking allocation. Constructor registration
stays in the instance's composition layer.

HTTP operations borrow a `runtime_http.View` containing context, HTTP state,
outbound/replay configuration, allocator, and a pointer to the outbound backend.
The backend remains in stable instance storage. Native adapters recover the host
through `Context.host`, and the HTTP implementation reads policy from that
context. HTTP implementations and native helpers do not import the handler
instance. Fetch module state still uses its typed SDK envelope.

## Compiler Pipeline

For a handler source file:

1. Parse original source with the restricted typed grammar, retaining runtime
   IR and parser-owned type syntax with original source spans.
2. Resolve imports, including `zttp:*` virtual modules.
3. Build semantic types from the selected parser-owned syntax.
4. Run type, path, Result/optional, state-isolation, flow, and spec checks.
5. Extract a handler contract and module capability surface.
6. Emit bytecode and optional artifacts such as contract JSON and generated
   tests.

Unsupported language features fail before runtime. See
[Feature Detection](../feature-detection.md) and
[Verification](../verification.md).

The type checker and contract builder share `ir_json_literal.zig` for static
JSON literal output. The helper reads an immutable IR view and uses the caller's
atom resolver. It returns complete owned JSON bytes or no literal, and releases
partial output on refusal or failure. Each caller still recognizes
`JSON.stringify`, handles raw schema strings, and interprets schema types.

### Typed source and semantic types

The parser reads original TypeScript source. It creates runtime IR and a
separate syntax store for annotations, declarations, generic arguments,
signatures, type-only modules, and erased expressions. Type-only syntax creates
no runtime statement or binding. Store records retain original source spans
and refer to final runtime owners when a type belongs to a runtime node.
Failed speculation rolls back the syntax it attempted.

Nodes enter `IRStore` through typed constructors (`addInt`, `addCall`, `addVarDecl`, and so on).
Each constructor packs one payload kind into the compact columns. There is no struct adapter.

`DirectCheckSource` owns source admission and the parser result used by CHECK
and compilation. It keeps parser diagnostics on original source coordinates.
The file-path admission boundary accepts `.ts`; it refuses `.js`, `.jsx`,
and `.tsx` with ZTS052. Virtual JavaScript input has a separate path.
Unsupported TypeScript constructs fail before bytecode generation; the
published subset and diagnostic stages are in [TypeScript Support](../typescript.md)
and [Feature Detection](../feature-detection.md).

`TypeEnv` selects either omitted or direct source typing. Direct population
lowers validated store ranges through `TypePool` and binds semantic types
to final declaration and runtime owners. It retains the authored type
namespace, alias construction order, generic scope, and function signatures.
Omitted typing is used where a contract is extracted without authored source
annotations. A standalone type text, such as a binding signature or an ambient name, goes through
`type_syntax_lowering.parseTypeText`, the same grammar as authored source. `TypePool` holds no
second type parser. Consumers must receive the matching source selection and a
healthy environment and pool.

`ParsedModule.fromTypedExisting` binds a borrowed syntax store to runtime IR
and atoms. Single-module analysis borrows that selection through the life of
the parser result. Graph reparsing supplies a store for each replacement
module. Contract effects use selected source types; path effects use
source-free analysis. The printer takes original source and a completed
parser-owned store so type regions and type-only declarations can be rendered
without changing ordinary token formatting.

### Analysis passes

Step 4 is implemented as four independent IR walkers, each traversing the same
IR tree with its own `switch` over node tags rather than through a shared
visitor framework:

- `handler_verifier.zig` - Response-return and Result-status propagation.
- `bool_checker.zig` - state isolation via flow-sensitive boolean/typeof
  narrowing.
- `flow_checker.zig` - data-label (secret/credential/user_input) taint flow.
- `strict_checker.zig` - additional restriction rules plus literal and
  annotation collection.

They run across two pipeline phases (`bool` and `strict` during resolve,
`verifier` and `flow` after type checking). Three of the four are flow-sensitive
and thread analysis state through descent, so adding a new IR node type requires
updating each relevant walker. A full single-pass visitor unification is
intentionally not attempted: the traversals are not the same traversal.

The checkers share three outputs. Every checker renders its diagnostics through
`diagnostic_projection.writeAll`, which projects each diagnostic and writes it with
`SourceView.writeDiagnostic` under the scope word of its source (`verify `, `strict `, `type `,
or none). Fault coverage keeps its own text form. The property lists that name
`HandlerProperties` fields (`FlowProperties`, `counterexample.PropertyTag`,
`spec_discharge.PropertyField`, the loss-severity and suggestion tables, and others) each call
`HandlerProperties.coverageProblem` or `namesCoverageProblem` in a `comptime` block. A new field
fails the build until every list includes it or excludes it with a reason.

### Module analysis ownership

`ModuleAnalysisSession` owns analysis storage for one parsed module.
The caller initializes the session in its final address.
The session borrows parser IR, atoms, the selected parser-owned syntax store,
registries, and injected module facts.
The session owns type environments, checkers, internal facts, and pass results.

Type-checker export lookup reads the immutable `ModuleFacts` import records.
It matches named imports by slot and binding kind, ignoring scope and local
spelling, and selects the first matching declaration with a builtin export.
Session-owned canonical facts are borrowed when available. A standalone checker
builds one owned fallback index before checking; it selects that storage from
its current address so moving the checker cannot leave a dangling self-pointer.
Injected contract projections remain separate from canonical type-import facts.
Strict checking retains its raw-slot policy, and flow analysis retains its
mutation-sensitive resolution.

The session prepares immutable path effect facts only when path analysis requests them.
Path generators borrow completed facts and never own an effect analyzer.
Path facts use injected sibling effect rows, but no registry, type environment,
or injected module facts. Imported rows are borrowed immutably through fact
preparation and extraction. The first path-fact request freezes these dependency
inputs, including when the cached result is unavailable. Later context updates
may change verification or dispatch metadata while retaining equivalent imported
rows; changing the dependency inputs is refused.
An unavailable effect result makes path coverage report recursion conservatively.

The session builds separate contract effect facts during contract extraction.
These facts retain the selected handler and its property summary.
They also retain reachability from the first function named `handler`.
The session builds these facts after late context and custom type checking are complete.
The contract builder borrows completed module and effect facts.
Contract analysis failures stop extraction and do not become unavailable path facts.

The `full` profile runs resolution for CHECK and single-module compilation.
The `contract_only` profile builds contracts without source annotations.
`extractContract` runs the selected flow pass when it has not run and applies its properties to the contract. A caller cannot publish the default flow properties by forgetting a second step. A source with no handler keeps the defaults for the tools callers, and the one-shot pipeline entry points report every flow property false.
The `sound_extraction` profile resolves soundness before contract extraction.

Each selected pass has one attempt.
Skipped passes remain different from failed or refused passes.
An explicit resolution refusal blocks verifier, flow, and contract extraction.
Completed contracts and transferred export tables own their data after session cleanup.

Sound resolution always uses module facts without a manifest registry.
Contract extraction can use separate facts with a manifest registry.
Injected module facts remain borrowed and authoritative for contract extraction.
A custom extraction callback gets a separate type environment and checker.

### Root source ownership for machine requests

Each file operation owns one `CapturedFile` through response completion.
This owner retains canonical paths, disk bytes, and graph records.
A verify content override borrows its bytes from request storage.
The graph hash, source digest, diagnostic spans, and analysis use the same effective root bytes.
Operation helpers consume those captured bytes, including repair simulation and normalization.

The owner reads disk before selecting a string override or validating the source extension.
The disk size limit applies only to that read; empty string overrides retain their existing meaning.
Imported files retain separate graph, summary, and fault observations.
Root capture leaves simulation context discovery and dependency observations in their existing owners.

## Virtual Modules

The native module registry is the source of truth:

- `packages/zts/src/builtin_modules.zig` lists all built-ins and governance
  entries.
- `packages/modules/module-specs/` stores public module specs.
- `packages/modules/src/root.zig` exposes SDK-pure module bindings.
- Engine-coupled modules stay under `packages/zts/src/modules/`.

`packages/zttp-sdk/src/descriptors.zig` owns the pure semantic vocabulary and
metadata records. The builtin registry projects its declarations into an
ordered descriptor table at compile time. Projection requires every declaration
field to be represented or explicitly classified as a callback/lifecycle hook;
label fields receive the same coverage check. SDK declaration forms remain
compatible, and the SDK-to-engine adapter still sanitizes reserved label bits.
TypeChecker's ModuleFacts lookup and module type population consume descriptors.
Runtime registration and registry hashing continue to use the original bindings,
including callback-presence flags. Parser IR and atom ownership remain engine
dependencies of the compiler.

Every export carries effect and capability metadata used by contract
extraction, runtime sandboxing, and handler property classification. The
current module list is in [Virtual Modules](../virtual-modules/README.md).

## Runtime Policy

Precompiled handlers can carry a contract and derived policy. At startup and
per request, the runtime uses that policy to gate native capabilities such as
env access, cache, SQL, outbound HTTP, filesystem-backed state, and runtime
callbacks.

Computed env keys, egress endpoints, and cache namespaces are represented as
residual obligations. The compiler records them, the acceptance kernel
reconstructs their exact catalog coverage, and the authoritative sink decides
the actual runtime value. SQL stays literal-only. These guard channels never
promote a static Property.

The same contract feeds:

- proof card rendering;
- proof ledger entries;
- `zttp proofs gate`;
- upgrade checks;
- runtime sandbox policy.

## Live Reload

`zttp dev` watches handler and config files. On a valid save it recompiles
the handler. With `--prove`, the new contract is diffed against the previous
contract before the handler pool is swapped. Compilation failures keep the
currently serving handler active.

The watcher submits a prepared source candidate to the server. The candidate
owns its source, copied filename and optional runtime contract. Its capability
policy borrows the analyzed contract and configured policy through immediate
installation/deinit; the pool deep-copies that policy before publishing it.
The server holds its exclusive contract lock across pool replacement, source
transfer/retirement, and metadata installation, in contract-then-runtime-init
lock order. Preparation and pool policy copying finish before any mutation;
failure keeps the current source, policy and metadata together.

The server owns the active and one superseded source allocation, each with its
original allocator. It adopts initial file-loaded bytes, leaves inline and
embedded inputs borrowed, and retires older backing only after the pool stops
reading it. Teardown drains the pool before freeing retained source. Existing
runtime leases retain their compiled executable and refcounted policy.

A source transition clears the prior certificate promotion, cached responses,
attestation and stale route filter. Source analysis supplies no proof acceptance.
One serving-settings derivation supplies pooling, fault-explanation facts and
cache eligibility from accepted proof facts at startup; a source transition
passes no accepted proof. The pool installs changed settings under its runtime
initialization lock before publishing the generation counter, so newly acquired
runtimes cannot retain the old artifact's fault-explanation facts. The separate
source-policy index requirement remains intact.

A capability policy named by `zttp.json` joins the watch set and is read again
for every candidate, so tightening it blocks newly forbidden code without a
restart. A candidate that violates the current policy, and a policy that cannot
be read, both keep the previous handler serving.

A generation with residual guards cannot use the certificate-free live-swap
path. A candidate that adds or strands a guard is refused, so the old executable,
contract, residual plan, policy, and in-flight request pins remain together.

## Deploy Artifact

`zttp deploy` builds a self-contained local binary under
`.zttp/deploy/<project-name>`. The output starts with the `zttp-runtime`
template and appends a payload in format 7. The payload contains bytecode, dependency
bytecode, contract JSON, runtime policy, a proof certificate, and optional JWS
attestation. `self_extract.zig` validates the trailer, loads the payload, and
starts the runtime. The payload version is checked for equality and an unknown
section is refused: a section this reader does not know is a malformed artifact,
not a future one.

The certificate is schema 5 under `zttp_pcc_v3 = 3`. Attestations use
`zttp-attest-v4`, and proof bundles use `zttp-bundle-3`.
The runtime refuses schema 4 and format 6 with rebuild guidance.
An existing self-contained binary keeps the runtime that it embeds.

Attestation signs the contract, bytecode, policy, and capability hashes, plus
the root of the artifact's executable graph. The running server emits proof
headers and serves `/.well-known/zttp-attest`; `zttp verify <url>` validates the
receipt, and reports provenance only, because the endpoint returns a claim
rather than the artifact.

## Activation

Startup runs four stages before a handler pool exists, in this order:

1. **Contract binding.** The embedded contract must bind to the artifact this
   process loaded: bytecode hash, policy hash, capability matrix, source
   identity, grammar, and semantics.
2. **Runtime policy attestation.** When a JWS is present, the exact section-4
   bytes and the executable-graph root must match the signed claims.
3. **Proof acceptance.** `artifact_graph.zig` rebuilds the executable-graph
   inventory from the sections just loaded; `proof_activation.zig` hands it and
   the embedded certificate to the acceptance kernel; `contract_runtime.promote`
   turns only the properties that cleared the active policy floor into a
   `ProofCheckedContract`. Unrequired or below-floor claims remain false. A
   deployed artifact that fails any of this does not serve. For a guarded
   artifact, the same check independently decodes the exact runtime-policy bytes
   and requires exact residual coverage.
4. **Pool init and prewarm.** Only now, so a refused artifact never has a warm
   runtime.

Only a `ProofCheckedContract` drives the proof response cache, unbounded runtime
reuse, and the result and optional fault-explanation facts.
`ValidatedRuntimeContract` - integrity without acceptance - drives
env validation and route pre-filtering and nothing that is unsound if a compiler
claim is wrong. A dev server, a live-reload swap, and a `-Dhandler` build have
no artifact and no certificate, so they get no promotion at all.

## Testing And Governance

Important gates (`bash scripts/verify.sh` runs the full local gate in one command; the individual steps below are for focused runs):

```bash
bash scripts/verify.sh             # full local gate
zig build test
zig build test-zts
zig build test-zruntime
zig build test-module-governance
zig build test-residual-guards-drift
zig build test-capability-audit
zig build test-docs-drift test-doc-links
bash scripts/test-examples.sh
```

Module governance checks keep the registry, specs, and docs from drifting.

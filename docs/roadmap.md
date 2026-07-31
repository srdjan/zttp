# Roadmap

The one forward-looking document in the maintained docs. It records the current
support boundary, what the implementation does not cover, and the work that is
planned but not built. Shipped changes live in `../CHANGELOG.md`; current user
behavior lives in [User Guide](user-guide.md).

## Supported Now

- macOS and Linux on x86_64 and aarch64.
- Zig `0.16.0` as declared by `build.zig.zon`.
- Threaded HTTP/1.1 server with per-request runtime isolation and decoded
  `Content-Length` or `Transfer-Encoding: chunked` request bodies.
- Restricted JS/TS/TSX handler execution through `zts`.
- WebSocket gateway support with parsed peer close-code metadata.
- The five core `zttp` commands: `init`, `dev`, `test`, `expert`, `deploy`.
- Local self-contained deploy artifacts with default-on attestation.
- Compile-time checks for response paths, Result and optional handling,
  state isolation, active specs, flow properties, contracts, and module policy.
- Built-in `zttp:*` virtual modules listed in
  [Virtual Modules](virtual-modules/README.md).
- Optional Studio and edge runtime builds via `-Dstudio` and `-Dedge`.

## Current Limitations

- Hosted cloud deploy is not part of the current CLI surface. `deploy` builds a
  local binary, `deploy --cloud` parses and rejects with a "not available in
  this beta" message, and the account verbs (`login`, `logout`, `review`,
  `grants`, `revoke-grant`) are not dispatched at all.
- The runtime uses the threaded HTTP server path. The evented `std.Io`
  networking path is not a supported request backend.
- Handlers receive raw `multipart/form-data` bodies from the HTTP server. Use
  `decodeFormMultipart` from `zttp:decode` or handler-owned parsing when a
  handler accepts multipart input.
- There is no scrape-able `/metrics` endpoint. `/_health` and `/_readiness`
  return bare status codes.
- Windows is not supported.

## Runtime And Product Work

- Close the remaining runtime lifecycle verification gaps before hosted deploy
  claims: broader accept-path coverage for deadlines, graceful shutdown, probes,
  and panic isolation; hosted request-timeout policy; and shutdown
  thread-safety semantics.
- Finish the engine-to-runtime boundary refactor by routing runtime calls
  through a strict facade and exposing stable runtime-facing engine types. The
  file split landed (`handler_instance.zig` owns `HandlerInstance`;
  `zruntime_tests.zig` is the test root), but six import cycles remain between
  the instance and the sibling files its methods moved into.
- Keep near-term module work limited to table-stakes gaps: fetch resilience,
  capability surfacing, and build-feature diagnostics. Cloud-adapter modules
  stay in a separate evaluated track.
- Keep `zttp help --all` and `packages/zts/src/builtin_modules.zig` as the
  sources of truth for CLI and module docs. `packages/modules/module-specs/` is
  not one of them: it is generated from the typed Zig module bindings by
  `zttp module-spec-render`, and `--check` gates it in `scripts/verify.sh`. Edit
  the binding, then regenerate.
- Add server-level rate limiting only if the standalone server becomes a
  first-class unproxied deployment target. Application limits are handled with
  `zttp:ratelimit`.
- Promote hosted deploy only after the control-plane path has CI smoke coverage
  and user-facing commands appear in default docs.

## The zts-advanced-1 Language Program

Implement the `zts-advanced-1` language profile incrementally on the existing
engine, keeping `scripts/verify.sh` green at every phase boundary. The source
spec is [zts-formal-spec-northstar-advanced.md](zts-formal-spec-northstar-advanced.md)
revision 4. The certificate and verifier stack (spec 13.3-13.4) and the
two-client conformance lab (14.2) are outside this program.

Three ground rules survive from phase to phase: the engine stays
interpreter-only with no kernel growth except where the spec names it; each
admitted form adds its semantics-registry rules in the same phase, so
`spec-check` stays green by construction; and no `meta` payload is ever
hand-written, because a hand-written payload is another drift gate.

Phases 0 and 1 are done. The executed plans and the program's decision log are
in [docs/archive/plans/](archive/README.md).

| Phase | Scope | Exit |
|---|---|---|
| 2. Type-system rock | Sound generic inference and instantiation per D1, constraints and explicit type arguments before inference; the closed narrowing list including negation, bare discriminant reads, and the `isDict`/`isBytes` value-kind guards; canonical type serialization per D3. | Generic functions instantiate soundly and never fall back to `unknown` over a frozen signature corpus covering every virtual-module export; narrowing conformance tests; stable type digests. |
| 3. Source `null`, recursive aliases, match upgrades | `null` as explicit data with the `??`/`?.`-rejected-on-null diagnostic and its repair; contractive recursive aliases over a finite type graph with memoized unfolding; match binding fields, rename and shorthand bindings, type-test patterns, and effectful arms with exactly-one-arm evaluation. | `JsonValue` minus the Dict arm compiles; exhaustiveness over null, literals, and type tests. |
| 4. Dict, JSON, Result completion | `Dict` and `zttp:collections` with persistent semantics, SameValueZero keys, and insertion order; `zttp:json` with a closed error taxonomy and policy-driven limits; `zttp:result` completion (`unwrapOr`, `orElse`, `collectAll`) with effect-row-polymorphic combinators per D2. | Dict determinism and SameValueZero tests; JSON round-trip and limit tests; `collectAll` first-error test. |
| 5. Bytes, ABI re-typing, defaults, Effects ceiling | `Bytes` and `zttp:bytes`; the HTTP, WebSocket, queue, and durable ABIs re-typed to the spec's 7.2 shapes including total `responseText`; trailing scalar default parameters; the decidable `Effects`-ceiling rule with repairs computed from the inferred row. | fetch, websocket, and queue examples re-typed; ceiling-rule repair tests. |
| 6. Full idiom table, validators, gate-complete protocol | The remaining idiom rows; equivalence validators per D3's method taxonomy, with any row lacking a registered validator shipping advisory-only; fixed-point normalization with a published pass bound; batch `apply_repair` and multi-property `verify`; the full registry-generated meta payload set. | Double-normalize byte-identity over the whole corpus; atomic `apply_repair` rejection tests; meta drift gates wired into `scripts/verify.sh`. |

Three design documents own the decisions the phases consume. Two of them also
retire an interim marker left in the code by phase 0:

- [D1 type system](plans/2026-07-30-014-d1-type-system-design.md) - assignability,
  generic inference, narrowing dataflow, join and union normalization, canonical
  type serialization. Unblocks phases 2, 3, and 4; retires `// D1-interim`.
- [D2 effects and purity](plans/2026-07-30-015-d2-effects-purity-design.md) -
  the effect-row atom set and its capability mapping, row inference and join, the
  purity predicate, and `Proof<T, P>`'s property domain. Unblocks phases 4 and 5;
  retires `// D2-interim`.
- [D3 canonical form and wire](plans/2026-07-30-016-d3-canonical-form-wire-design.md) -
  the lexical grammar, the canonical formatter, digest pre-images, protocol
  payload schemas, and the equivalence-validator taxonomy. Unblocks phase 6.

Four risks carry across phases. The generics retrofit in phase 2 has a long
tail, mitigated by the frozen signature corpus and by ordering constraints
before inference. Normalization in phase 6 may not be confluent, mitigated by
running the double-normalize property test from day one and falling back to
advisory-only rows. Hand-written meta payloads would multiply drift gates, which
is why the ground rule above bans them. Silent decisions leaking into wire
formats is why D1 lands before phase 2, D2 before phase 4, and D3's digest
section before the phase-1 hash freeze.

Two spelling decisions stay unresolved: the no-ASI flip waits for phase 6 and
its unique-parse-insertion validator, because the live parser has `return`-ASI
today; and the pipe operator (`|>`) and `interface` both stay shipped until the
D workstream produces a migration policy for removing published surface.

## Reset And Simplification

The reset ledger is
[2026-07-28-001-reset-simplification-plan.md](plans/2026-07-28-001-reset-simplification-plan.md).
Waves 0 through 3 and wave 6 are executed, and waves 4 and 5 are done except
for three items:

- Shared IR shape helpers (wave 4, item 4). The shared import and binding index
  shipped as `packages/zts/src/module_facts.zig` and all six analyzers adopted
  it. The shape-helper library is deferred, and the orchestration move is closed
  as declined: it had an architectural justification and no performance or
  correctness one, and it needed an IO boundary inside `pipeline.zig` that does
  not exist. Revisit only with a concrete consumer for a fourth `LoweredModule`
  phase, such as a build cache or incremental compile.
- The collector's role (wave 5, item 3). Inverted by the wave 0 RSS
  measurement. The memory defect it started from was found, fixed, and closed by
  a two-hour soak (per-runtime lifetime arena), but what the collector still
  earns has not been measured. No GC code is deleted until the remaining growth
  is attributed.
- `comptime.zig` unification (wave 5, item 4). Replacing its separate tokenizer,
  parser, and value model with evaluation over the main IR after parse would
  delete roughly 1,800 lines and structurally resolve the `==` inconsistency. It
  needs more comptime tests first.

VM-loop dedupe stays deferred behind the FaaS hardening, engine facade, and
measurement gates. The standalone plan is
[Deferred VM Loop Dedupe Plan](archive/DEFERRED_VM_LOOP_DEDUPE_PLAN.md).

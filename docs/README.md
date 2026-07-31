# Documentation

These docs describe the current codebase. Release history lives in
`CHANGELOG.md`, and [Roadmap](roadmap.md) is the only forward-looking document
here. Finished plans live under [archive](archive/README.md).

## Start Here

- [User Guide](user-guide.md) - the single user guide for install, first
  project, handler API, routing, JSON, JS/TS/TSX, virtual modules, tests,
  deploy, proof receipts, and troubleshooting.
- [CLI Reference](cli.md) - core commands, advanced analyzer commands,
  proof-ledger commands, expert mode, and machine-readable output.
- [Virtual Modules](virtual-modules/README.md) - complete current `zttp:*`
  module list, exports, capabilities, effects, and runtime requirements.
- [Durable Workflows](durable-workflows.md) - durable run/step/signal,
  workflow queue, dead-letter handling, proof receipts, and replay boundaries.
- [Roadmap](roadmap.md) - supported platforms, current limitations, planned
  runtime work, the `zts-advanced-1` language program, and what remains of the
  reset.

## Reference

- [Contracts and Auto-Sandboxing](contracts-and-sandboxing.md) - handler
  contracts, least-privilege runtime policy, OpenAPI/SDK emit, replay,
  upgrade checks, and `Spec<...>`.
- [Verification](verification.md) - compile-time handler checks.
- [TypeScript](typescript.md) - type stripping, type checking, TSX, and
  `comptime()`.
- [TypeScript Patterns](typescript.md#typescript-patterns-in-the-zts-subset) -
  the "TypeScript Tips Everyone Should Know" canon mapped onto the zts subset.
- [Feature Detection](feature-detection.md) - allowed and rejected language
  features.
- [Restrictions to Proofs](restrictions-to-proofs.md) - why each language cut
  exists.
- [Sound Mode](sound-mode.md) - type-directed truthiness, arithmetic, and
  comparison diagnostics.
- [Canonicalize And Normalize](cli.md#canonicalize-and-normalize) - canonical
  ZigTS rules and `zttp normalize`.
- [Proofs and Receipts](proofs-and-receipts.md) - the proof card, the
  counterexample block, the persisted witness corpus, and the pull-request
  proof gate.
- [Edge Runtime](edge.md) - optional in-process multi-handler router.
- [Performance](performance.md) - current benchmark claims and tuning notes.
- [Reliability](reliability.md) - limits, failure behavior, and exit codes.
- [Threat Model](threat-model.md) - current trust boundaries and non-goals.

## Internals

- [Architecture](internals/architecture.md) - runtime, engine, request flow,
  contracts, and deploy architecture.
- [Zig Embedding API](internals/api-reference.md) - advanced Zig embedding and
  native function extension notes.
- [Module Capabilities](internals/capabilities.md) - built-in module
  capability governance.
- [Semantics Verification](internals/semantics-verification.md) - the five
  `spec-check` mechanisms, the SMT layer, the exclusion audit, and the
  generated spec artifacts.
- [Test Steps](internals/testing.md) - what `zig build test` includes and
  excludes, and why the zruntime suite is standalone.
- [zts Expert Contract](internals/zts-expert-contract.md) - stable
  structured-tool output used by compiler-in-the-loop workflows.
- [zts-advanced-1 Formal Spec](zts-formal-spec-northstar-advanced.md) - the
  north-star language specification the roadmap's language program implements.
  It describes the target profile, not today's compiler.

## Archive

[docs/archive/](archive/README.md) holds dated records of finished work. It is
unmaintained by design and describes the system as it was, not as it is.

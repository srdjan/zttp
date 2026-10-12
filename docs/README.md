# Documentation

These docs describe the current codebase. Release history lives in
`CHANGELOG.md`, and [Roadmap](roadmap.md) owns work status and scheduling.
The [plan index](plans/README.md) identifies active work, retained design
references, and parked proposals. A plan can define a design; the roadmap
states its status, dependencies, next action, and completion checks. Finished
and superseded execution records live in the `pre-rebase` git tag, under
`pre-rebase:docs/archive/`. Repository-level
[advisory plans](../advisor-plans/README.md) require a decision before execution.

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
  runtime work, artifact-assurance ratchets, local-model qualification, and
  what remains of the reset.
- [First Durable Workflow](tutorials/first-durable-workflow.md) - run the
  durable workflow examples from a clean checkout and inspect replay state.
- [Convergence](convergence.md) - the measured first-draft veto-pass rate over
  the frozen prompt corpus, with the corpus version and policy hash each figure
  was recorded against.
- [Coverage](coverage.md) - which of the compiler's advertised rules the corpus
  actually trips, and what the offline suite does and does not prove.

## Reference

- [Contracts and Auto-Sandboxing](contracts-and-sandboxing.md) - handler
  contracts, least-privilege runtime policy, replay,
  upgrade checks, and `Proof<T, P>`.
- [Verification](verification.md) - compile-time handler checks.
- [TypeScript](typescript.md) - type stripping, type checking, TSX, and
  `comptime()`.
- [TypeScript Patterns](typescript.md#typescript-patterns-in-the-zts-subset) -
  the "TypeScript Tips Everyone Should Know" canon mapped onto the zts subset.
- [Feature Detection](feature-detection.md) - allowed and rejected language
  features.
- [Restrictions to Proofs](restrictions-to-proofs.md) - why each language cut
  exists.
- [Sound Mode](typescript.md#sound-mode) - boolean-only control flow, arithmetic, and
  comparison diagnostics.
- [Canonicalize And Normalize](cli.md#canonicalize-and-normalize) - canonical
  ZigTS rules and `zttp normalize`.
- [Proofs and Receipts](proofs-and-receipts.md) - the proof card, the
  counterexample block, the persisted witness corpus, and the pull-request
  proof gate.
- [Performance](performance.md) - current benchmark claims and tuning notes.
- [Reliability](reliability.md) - limits, failure behavior, and exit codes.
- [Threat Model](threat-model.md) - current trust boundaries and non-goals.
- [Consumer Contract](consumer-contract.md) - proposed: the declaration a downstream
  application writes, the admissibility, adjudication, and acceptance stages, and the
  closed vocabularies both sides pin. [Roadmap](roadmap.md#proposal-decisions) owns its
  status.

## Internals

- [Architecture](internals/architecture.md) - runtime, engine, request flow,
  contracts, and deploy architecture.
- [Zig Embedding API](internals/api-reference.md) - advanced Zig embedding and
  native function extension notes.
- [Module Capabilities](internals/capabilities.md) - built-in module
  capability governance.
- [Semantics Verification](internals/semantics-verification.md) - the four
  `spec-check` mechanisms, the soundness boundary, and the generated spec
  artifacts.
- [Test Steps](internals/testing.md) - what `zig build test` includes and
  excludes, and why the zruntime suite is standalone.
- [Cassette Recording](internals/cassette-recording.md) - when a codegen
  cassette goes stale, how to re-record the corpus against DeepSeek or a local
  MLX server, and how to republish the convergence and
  coverage pages.
- [zts Expert Contract](internals/zts-expert-contract.md) - stable
  structured-tool output used by compiler-in-the-loop workflows.
- [Agent Protocol v2](internals/agent-protocol-v2.md) - the
  `zts agent --stdin-json` request and response envelope, its closed operation
  set, and version negotiation.
- [zts-model-1 Formal Spec](zts-formal-spec-northstar-advanced.md) - the
  language-design and assurance northstar for `zts-model-1`. Compiler-owned
  registries define the implemented surface, and some target-level design text
  remains beyond the live compiler. Artifact-level certificate acceptance now
  ships with disclosed tested and trusted edges; the spec's stronger target is
  not a claim that those residual edges have been eliminated.

## Solutions

[docs/solutions/](solutions/) holds categorized records of past bugs and
engineering problems, searchable by YAML frontmatter (`module`, `tags`,
`problem_type`). Unlike the archive, these describe classes that recur, so they
stay maintained.

## Archive

The `pre-rebase` git tag holds dated records of finished work under
`pre-rebase:docs/archive/`. They are unmaintained by design and describe the
system as it was, not as it is.

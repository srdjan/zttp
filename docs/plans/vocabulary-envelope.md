# Plan: the published vocabulary envelope and its drift gate (P1)

Status: in progress. Owner: this repository. Obligation: P1 in
[consumer-contract.md](../consumer-contract.md), with P12's name mapping folded in.

## Why

Section 6 of the consumer contract states sixteen closed alphabets and five pinned
identities as literal counts in prose. Nothing checks them. Three review rounds have now
hand-verified those counts, and each round found claims that had drifted from the tree.
A document that makes roughly sixty checkable claims with no mechanical connection to the
source will keep being wrong. This replaces the reviewers with a gate.

## Ground truth established before writing code

- `ModuleMetadata.nativeBindingDigest` is in the **curated** tier of
  `packages/zts/src/root.zig` (line 761), wrapping `module_manifest.bindingDigest`
  (line 351). No `scripts/module-boundary.allow` row is needed to reach it.
- `bindingDigest` folds the semantic fields of a binding (specifier, name, exports,
  summary, required capabilities, stateful, state init/deinit presence, contract section,
  sandboxable, comptime_only, self_managed_io) under the domain separator
  `"zttp-native-module-surface-v2"`, and deliberately excludes function addresses as
  build-layout noise. It is public and unpublished: nothing in `expert_meta.zig` emits it.
- `packages/tools` imports neither `zttp_proof_checker` nor `pi`. Twelve of the sixteen
  alphabets live in the proof checker, so a `zts_cli` subcommand cannot see them.
- `packages/tools/src/invariant_drift_gate.zig` is the precedent: a standalone executable
  under `tools` that imports `zts` **and** `zttp_proof_checker`, wired in `build.zig`
  (lines 293-310) as its own run step. The proof checker's leaf rule in
  `scripts/check-proof-checker.sh` constrains what the kernel imports, not who imports it,
  so this does not violate it.
- `packages/pi/src/property_goals.zig` owns `supported_goals` and is not importable from
  `tools`. `invariant_drift_gate.zig` sets the precedent for this too: "a surface that is
  data is imported and compared as a value; a surface that is code is text-scanned."
  The goal-driveable alphabet is text-scanned.
- `spec-render [--out] [--check]` and `module-spec-render [--check]` are the established
  generate-and-check pair. The envelope follows their shape.

## Deliverables

1. `packages/tools/src/vocab_envelope.zig` - builds the envelope value and serializes it.
2. `packages/tools/src/vocab_envelope_gate.zig` - standalone executable. `--out <path>`
   writes, `--check` compares, and every invocation runs mutation probes.
3. `docs/consumer-contract-envelope.json` - the generated artifact a consumer reads.
4. `build.zig` - a `test-vocab-envelope` step, and a row in `scripts/verify.sh`.
5. Capability profiles encoded in Zig. Section 4.3 currently defines `boundary`,
   `adapter` and `ledger` in prose only, so the document is their only source. A gate
   cannot check prose. The Zig definition becomes authoritative and section 4.3 is
   rendered from it.

## Envelope contents

Per P1 and P12:

- `contract_version`, `envelope_version`.
- One block per alphabet, each carrying its members by name and ordinal where it has one.
- Both the in-tree base and the effective set wherever they can differ: virtual modules
  (`runtime_builtins` versus `all = builtins ++ extension_bindings.all`) and residual
  guard families (catalogued versus `enabled_families`).
- `binding_digest` per virtual module, from `nativeBindingDigest`. This is what closes the
  section 12 hole where a member's meaning changes while its name and ordinal hold still.
- The P12 name mapping across the spec names, the handler property fields, the verifier
  wire names, and the consumer obligation properties.
- The pinned identities, plus the existing `policy_hash` and `module_registry_hash`.

## The gate's floor

P1 requires the gate to fail on a missing input, an empty inventory, and a build in which
nothing depends on it. `AGENTS.md` requires more than that: count per verdict, not per
input, and prove the census is complete.

- Every alphabet block asserts a nonzero member count before any comparison runs.
- A missing or unparseable `docs/consumer-contract-envelope.json` is a failure, never a
  skip.
- Comparison is member-by-member equality in both directions, so an addition, a removal
  and a substitution each fail. A count alone would miss the substitution.
- One in-memory mutation probe per alphabet, mutating a copy held in this process and
  re-checking, each naming the check it expects to reject it. Probes never touch the
  working tree.
- The build step depends on the compiled artifact, so a build in which nothing depends on
  the gate fails to link rather than silently passing.

## Order of work

Per the repository's scaling rule, a vertical slice first.

1. Slice: the gate executable, `--out` and `--check`, three alphabets chosen to cover all
   three source kinds - capability categories (`zts` enum), consumer obligation properties
   (`zttp_proof_checker` enum), virtual modules with `binding_digest` (`zts` data plus a
   derived hash). One mutation probe. Build wiring. Verify the whole pipeline runs and
   that the probe fails the gate when it should.
2. Scale: the remaining alphabets and the pinned identities. Only the alphabet list
   changes, not the mechanism.
3. Render section 4.3's profile table and section 6's counts from the envelope, so the
   prose stops being a second source.

## Out of scope

Per-rule semantic digests for the 89 reason codes and the 17 spec names. No per-rule digest
precedent exists; `rule_registry.zig`'s `policyHash()` hashes rule metadata rather than
decision logic, and the logic is distributed across the flow checker's generic algorithm
and per-module declarative facts. That is research-shaped work and waits on an observed
incident of silent semantic drift, per the repository's rule against building on a guess.

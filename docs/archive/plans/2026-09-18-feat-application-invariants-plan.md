# ZTTP Application Invariants

Archive status, reviewed 2026-09-21: Implemented foundation at `f0d8c5e8`,
followed by the closed invariant catalog delivery. The full repository gate
subsequently passed at `9be65e0d`, as recorded in the bounded rederive record.
The pending validation and broken-link statements below describe the earlier
checkpoint. Current work status is in [Roadmap](../../roadmap.md).

This is the implemented foundation, through commit `f0d8c5e8`. The next work is
defined in [ZTTP Invariant Kind Catalog](2026-09-18-feat-invariant-kind-catalog-plan.md).
That plan adds a closed catalog and replaces the invariant feature's Python
tooling under the current `AGENTS.md` rule. General predicates remain deferred.

## Purpose

Implement the approved balance-conservation invariant on the existing consumer
acceptance kernel. Developers confirm a structured specification. Deterministic
builds consume that specification; model output cannot authorize an artifact.

For each declared ledger and currency, signed account balances sum to zero
after every committed posting group. Conservation does not establish correct
recipients, authorization, sufficient funds, or correct business amounts.

## Implementation

1. Add a versioned balance-conservation specification, exact amount boundary,
   and protected ledger configuration. Amounts cross the handler boundary as
   canonical signed integer strings, with checked native arithmetic.
2. Add `zttp:ledger` with atomic posting and committed balance reads. Entries
   and idempotency records commit together. Restrict the protected store to
   this module, including general SQLite and file access paths. Validate an
   existing baseline under write exclusion; unreadable is never empty.
3. Add independently checked invariant evidence beside existing properties
   and resource guards. Bind specification, ledger schema, sink identity,
   operation coverage, and policy to the executable artifact. Reject missing,
   forged, unsupported, or incomplete evidence. Preserve the disclosed native
   adapter and deployment isolation assumptions.
4. Integrate accepted evidence with startup and guarded generations. A failed
   reload preserves the previous generation. Expose coverage, runtime readiness,
   and each posting result separately. Add deterministic authoring and optional
   advisory Jev classification without a model dependency in acceptance.

## Validation

Start with a balanced transfer, an unbalanced transfer with unchanged state,
a rejected storage bypass, and a tampered specification. Extend to currency
separation, canonical amounts, overflow, retries, conflicting keys, concurrent
writers, interrupted commits, restart, invalid baselines, imported and unresolved
calls, omitted operations, and mismatched sink or policy identities. Secret labels
must survive results and errors. Required evidence gates have non-empty inputs
and reject missing and extra records.

Run affected module, SDK, compiler, checker, artifact, and runtime suites. Retain
proof-checker purity, proof ratchet, capability, module governance, boundary,
proof-swallow, and stand-in gates. Run `test-zruntime` separately.

## Boundaries

The first release supports local protected SQLite ledgers and the closed
`balance_conservation_v1` template. General predicates, distributed stores,
currency conversion, and automatic migration are deferred. Existing algebraic
law metadata keeps its name. Work on local main and commit complete isolated
units; do not push or include pre-existing user changes.

## Implementation status

The specification, protected ledger, compiler evidence, independent bytecode
observation, consumer checks, artifact activation, status reporting, and advisory
authoring tool are implemented. Artifact format 4 and certificate schema 4
reject their predecessors. The first release requires direct ledger imports in
a built artifact. It refuses source serving, unchecked reload, and system
manifests. The public pool reload API also preserves the accepted generation.

Runtime and build outputs cannot share the configured ledger or its SQLite
sidecars. The ledger must be outside the durable output directory. The native
adapter, SQLite, and exclusion of external writers remain trust assumptions.
Baseline validation runs when each handler instance opens its store. Its cost
on a large ledger needs measurement. The performance review identified repeated
statement preparation during posting, queries for each posting during baseline
validation, and repeated scans as the pool grows. Account updates already use
the net delta for each distinct account. Statement reuse and validation once per
generation are deferred until measurements justify the added state and trust
boundary. Runtime initialization is serialized within a pool, but a new
instance's exclusive validation lock can conflict with active posting.
The independent observer also has operand-dependent stack rules. Changes to
the bytecode instruction set must keep those rules and their regressions in
step with the verifier.

The implementation run for `f0d8c5e8` passed the affected acceptance, CLI, server,
compiler, module, and runtime tests and built the browser analyzer. A built
artifact passed posting, retry, restart,
interrupted-write recovery, invalid-baseline, changed-evidence, and output-path
collision checks. Review regressions covered fused calls, branches before ledger
calls, duplicate accounts at the amount limit, posting-hash tampering, sidecar
access, and refused reloads. These are historical results. The plan refresh at
`6ad648ae` inspected source and did not run tests.

Full repository validation remains pending. The new module changes the tool
request bytes, so the committed model replay corpus requires a fresh provider
capture. Historical model responses were not rewritten. The release build
reached the 110-second execution limit. Both longer runs need approval under
the repository's two-minute script rule. The pre-existing deletion of
`docs/zts-advanced-v2.1.md` also leaves an unrelated documentation link broken.

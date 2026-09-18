# ZTTP Application Invariants

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

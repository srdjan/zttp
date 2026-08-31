---
title: Bind proof authority into the signed executable root
date: 2026-08-31
category: security-issues
module: proof acceptance
problem_type: security_issue
component: runtime
symptoms:
  - "Changing certificate evidence could preserve the signed executable root."
  - "Malformed evidence, proof IR, and translation witnesses could receive an accepted grade."
  - "Runtime promotion exposed compiler claims that had not cleared consumer policy."
root_cause: missing_validation
resolution_type: code_fix
severity: critical
related_components:
  - proof checker
  - executable graph
  - contract runtime
  - native module identity
tags:
  - proof-certificate
  - artifact-integrity
  - fail-closed
  - assurance-grade
  - runtime-promotion
---

# Bind proof authority into the signed executable root

## Problem

The executable graph committed to the proof IR digest but not to the rest of
the certificate. Evidence edges, translation witnesses, trusted inventory, and
solver queries could change while the signed root stayed fixed. The checker
also accepted several malformed combinations, and runtime promotion copied all
compiler claims after policy acceptance instead of only the properties the
consumer accepted.

These were one trust-boundary class: an authority-bearing value either sat
outside the commitment or received more authority than the consumer had
validated.

## Solution

Certificate schema version 2 adds two explicit identities:

- One proof IR function is marked as the compiler-selected handler. Totality is
  reconstructed for that function, not the first function in source order.
- The executable graph has a required `proof_certificate` member. Its digest
  folds every canonical certificate byte.

The certificate contains the executable root and the graph contains the
certificate digest, so a direct hash would be recursive. The commitment
normalizes exactly those two 32-byte self-reference slots to zero. All other
bytes participate. The producer encodes a zeroed provisional certificate,
computes its certificate digest, inserts that digest into the graph, computes
the executable root, and performs the final canonical encoding. Startup and
the checker independently repeat the normalized fold.

The checker now also:

- rejects proved evidence without a permitted kernel rule;
- validates both directions of every proof IR parent-child relation and
  enforces the configured maximum depth;
- validates every active containing witness range, not only adjacent ranges;
- binds solver results to the query's obligation and query kind;
- caps each affected property at its declared trusted dependency;
- counts tested evidence and trusted inventory used by the accepted chain;
- records a grade and policy verdict per property.

Runtime promotion consumes the per-property verdicts. A contract claim that
was unrequired, not established, or below the policy floor cannot enable
caching, pooling, result-check elision, state isolation, or workflow promises.

Native module identities now use one central canonical serialization of the
complete declared surface, including per-export capabilities, signatures,
traceability, return labels, contract metadata, laws, and module state metadata.

## Regression method

The regression probes mutate the authority-bearing field while preserving the
previously signed material, then assert refusal on the real activation path.
Additional probes construct ruleless proved evidence, mismatched solver
queries, malformed proof trees, excessive depth, and non-adjacent interval
overlap. The handler-entry regression compiles a source file with an empty
helper before a valid exported handler and reaches production acceptance.

## Assumptions

- This is a direct schema cutover. Version 1 certificates are rejected and
  must be rebuilt. No compatibility parser retains the old trust model.
- Trusted opcode semantics remain disclosed rather than re-derived. Therefore
  `response_total` and the overall production result are capped at `trusted`
  until the checker validates opcode meaning itself.
- A module implementation address is a build-layout detail and is not part of
  its public authority surface. The native versus sandboxed implementation
  path is committed because that choice changes enforcement.

## Prevention

- Put every value that can grant runtime authority under a signed commitment.
- Normalize only unavoidable self-references, and test that every other section
  changes the commitment.
- Carry per-property verdicts across policy and runtime boundaries. Do not turn
  aggregate acceptance into permission for unrelated claims.
- Probe malformed certificates directly. A gate over successful fixtures does
  not establish rejection behavior.

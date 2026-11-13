# Graded proof headers, short root guidance, and a gate record, 2026-11-12

A fresh-eyes review of 2026-11-12 proposed 16 enhancements, E1 to E16. On
2026-11-12 the owner answered "as recommended" to two decisions. Decision 1
(a) started E2, which connects the soundness-incident channel. Decision 2 (a)
asked for one plan for E1 and E6 and for the start of the E9 record. This plan
records those units. The review report is not in the repository.

## Decisions

Decision 1 (a): E2 connects the soundness-incident channel. The incident
recorder and the 500 body read the same facts: the compiler's claims in the
validated contract. A deployed binary accepts `--incident-log`. Commit: `335abac4`.

Decision 2 (a): this plan. It holds E1 (grade every published claim with the
checker verdict), E6 (one description of the build steps and a short root
`AGENTS.md`), and the first part of E9 (a record of each gate run).

Decision 3 (a), approved 2026-11-13: U2 below runs after U1, with a new
attestation version.

Decision 4 (a), approved 2026-11-13: run U1, U3, U4, and U6. U1 and U3 change
different files, so they run in parallel with separate Zig caches.

Decision 5 (a), approved 2026-11-13: the 500 bodies, the incident log line,
and the incident-log JSON key say "claimed" instead of "proven", with a
changelog entry.

Decision 6 (a), approved 2026-11-13: the unreachable proof cache and pooling
tiers stay recorded here. A separate plan investigates them later.

## Facts that the units depend on

The server builds the `Zttp-Proofs` header in `packages/runtime/src/server.zig`
from `contract.properties()`. These are the compiler's claims. The startup log
line `Proven:` prints the same claims. The checker verdict is in
`server.proof_checked` and in the `pcc.verdict.PropertyVerdicts` of the
assessment. `zttp proofs verify` prints the properties that the checker derived
again on its `Checked:` line, through `writeCheckedList` in
`packages/runtime/src/proofs/bundle.zig`.

The signed build receipt holds `property_summary`. `build_receipt.zig` makes it
with `header_strings.formatProofChips` over the claims, before any checker
verdict exists. `zttp verify <url>` prints that signed value. It does not read
the `Zttp-Proofs` header.

The root `AGENTS.md` gate table is a generated block. `renderGates` in
`tooling/agent_spine.zig` writes it from `agents.json`. Two tasks in
`agents.json` carry `"always": true`.

`tooling/verify.zig` runs each route of `tooling/verification_routes.zig` as a
separate process and exits at the first failure. It records nothing. `.zttp/`
is ignored by git.

## Units

### U1: graded `Zttp-Proofs` header and startup log (E1, first step)

- Model: Sonnet.
- Files: `packages/runtime/src/attest/header_strings.zig`,
  `packages/runtime/src/server.zig`, `packages/runtime/src/contract_runtime.zig`,
  `packages/runtime/src/server_test.zig`, `docs/proofs-and-receipts.md`,
  `docs/user-guide.md`.
- Turn budget: 60.

`ProofCheckedContract` keeps only the accepted chips. It drops the
`PropertyVerdicts` and their marks for properties derived again, so U1 adds the
verdicts to it. The accepted chips already map each chip to its kernel
property, so a chip is in `claimed=` when the compiler claims it and the
accepted chips do not hold it.

The value separates groups with `; ` and names with `, `. An empty group is
left out. A value with no group is not sent.

The header keeps its name. Its value names three disjoint groups in this
order: `checked=` lists the properties that the checker derived again,
`accepted=` lists the other properties that the checker accepted, and
`claimed=` lists the compiler claims that the checker did not accept. A
property is in the highest group that it reaches. The first two groups use the
names of `pcc.proof_system.Property`, the same words as `zttp proofs verify`.
The `claimed=` group uses the chip names of `chip_field_names`. A server
without an accepted certificate sends only `claimed=`. The startup log replaces
`Proven:` with three lines: `Checked:`, `Accepted:`, and `Claimed:`.

The signed `property_summary` does not change. The producer signs it before a
consumer verdict exists. The documents say that the header grade is a
statement of the running binary.

Acceptance check: a server test with literal expected values, for one
artifact whose verdicts accept `read_only`, `deterministic`, `state_isolated`,
and `results_checked`, with `results_checked` derived again. The test asserts
the full header line. It fails before the change. Then `zig build test-server`,
`zig build test-proof-ratchet-drift`, and `bash scripts/verify.sh` pass.

### U2: the attestation value only at the well-known path (E1, second step)

Decision 3 (a) approved it. It starts after U1 is committed, because both units
change the header code. Today each response carries the full `Zttp-Attest` value.
The review measured 2,069 bytes for that line and 2,393 header bytes for an
11-byte body. The change sends a short digest in the header and the full value
at `/.well-known/zttp-attest`. It changes the attestation wire. It follows the
equality rule of "Format cutover" in `docs/verification.md` and needs a new
attestation version.

Decision 3 options: (a) do U2 after U1, with a new attestation version.
(b) keep the full value in each response. Recommendation: (a).

- Model: Sonnet.
- Files: `packages/runtime/src/attest/envelope.zig`,
  `packages/runtime/src/attest/header_strings.zig`,
  `packages/runtime/src/server.zig`, `packages/runtime/src/server_response.zig`,
  `packages/runtime/src/verify_cli.zig`, and the documents that name
  `zttp-attest-v4` or describe `zttp verify`: `docs/cli.md`,
  `docs/user-guide.md`, `docs/verification.md`, `docs/threat-model.md`,
  `docs/internals/architecture.md`, `docs/contracts-and-sandboxing.md`.
- Turn budget: 80.

The response header becomes `Zttp-Attest: sha256=<64 lowercase hex>`. The hex
is the SHA-256 of the compact JWS bytes. The JWS stays in the `attest` member
of `/.well-known/zttp-attest`. `envelope.version_tag` becomes `zttp-attest-v5`.
A `zttp-attest-v4` receipt is refused with `UnsupportedAttestationVersion`.

`zttp verify <url>` reads the digest from the response to `<url>`. Then it
fetches `/.well-known/zttp-attest` from the same origin, without redirects. It
requires `v` to equal `envelope.version_tag` and the SHA-256 of `attest` to
equal the header digest. Then it verifies the JWS as before. A header that
holds a JWS, the old form, gets the existing "rebuild the artifact" message. A
digest mismatch gets its own message and exit code 3.

Acceptance check: tests with literal values for the new header line, for the
v4 refusal, and for a pure verifier function over a header value and a
document body. That function covers a match, a digest mismatch, the old header
form, and a wrong `v`. Then `zig build test-server`, `zig build test-cli`, and
`bash scripts/verify.sh` pass. The lead probes a deployed binary with
`zttp verify <url>` and measures the header bytes of one response.

### U3: the gate table leaves the root `AGENTS.md` (E6)

- Model: Sonnet.
- Files: `tooling/agent_spine.zig`, `AGENTS.md` (regenerated),
  `docs/internals/testing.md`, `scripts/check-docs-drift.sh`.
- Turn budget: 60.

`renderGates` writes only the tasks that carry `"always": true`, and one
sentence: run `zig build brief -- <path>` before a change, because it lists
the gates for that path. `docs/internals/testing.md` keeps only what the build
graph cannot say. `check-docs-drift.sh` drops the checks that bound the removed
copies.

The agent-spine convention was read on 2026-11-13. It requires that a generated
block agree with `agents.json`. It does not require every gate in the root
file.

Acceptance check: the byte count of the root `AGENTS.md`, before and after.
`zig build check-spine`, `zig build test-spine`, `zig build test-docs-drift`,
and `bash scripts/verify.sh` pass.

### U4: the history sentences leave the root `AGENTS.md` (E6)

- Model: Opus, directly. The edit needs judgment about each sentence.
- Files: `AGENTS.md`, the area `AGENTS.md` files.
- Turn budget: 40.

Each root sentence that tells the history of a past defect moves to the area
file that owns the code, or to its solution record. The rule stays in the root
file.

Acceptance check: the byte count of the root `AGENTS.md`. `zig build
check-spine` and `zig build test-spine` pass.

### U5: a record of each gate run (E9, first part)

- Model: Opus, directly. The change is in one file.
- File: `tooling/verify.zig`.
- Turn budget: 30.

After each route, the runner appends one JSON line to `.zttp/gate-ledger.jsonl`
in the repository root: the time, the commit, the route label, the exit code,
and the duration in milliseconds. A failure to write the line prints a warning
and does not change the exit status.

Acceptance check: one `zig build verify` run writes one line for each route
that it ran. The second part of E9, the review of steps that never fail, waits
until the owner asks for it.

Complete 2026-11-12 (`a3823825`). `bash scripts/verify.sh` passed with an empty
cache and added one line for each of its 10 per-commit routes. The `exit`
field is `null` when the child did not exit. The commit field comes from `git
describe` and carries a `-dirty` suffix when the tree has changes.

### U6: closing validation

- Model: Fable and Codex astra review; Opus probes and fixes.
- Files: none planned. A confirmed finding gets its own unit.
- Turn budget: 40 for Opus.

After U1, U2, U3, and U4, Fable and Codex astra review the combined diff of E2
(`335abac4`), U1, U2, U3, U4, and U5, with split briefs. Each brief gives the diff
and this plan, not the conclusions of Opus. Opus probes each finding at the
commit. A confirmed finding gets a failing test and a fix. A rejected finding
gets its reason in this plan. The probes cover a deployed binary, `zttp dev`,
and `zttp serve`, with and without `--incident-log`, and a client that reads
the `Zttp-Proofs` header.

### Status, 2026-11-13

U1 is `9c068be4`, U2 is `0ecd316e`, U3 is `397175ef`, and U4 is `099a8975`.
The root `AGENTS.md` went from 31,364 to 21,808 bytes. A deployed binary from
the `zttp init` template sent 463 header bytes for a 65-byte body, and the
`Zttp-Attest` line was 86 bytes.

U6 findings. Fable reviewed E2, U1, and U2. Codex astra reviewed U3, U4, U5,
and the U2 verifier.

- The production policy accepts only `response_total`, `results_checked`, and
  `no_secret_leakage`. The documented header example could not occur.
  Fixed in `ccb985b6`: the document shows the deployed value, and the test
  uses the production verdict shape.
- The well-known receipt said `max-age=3600`. After a redeploy, a shared cache
  could make `zttp verify` refuse a valid server. Both reviewers found it.
  Fixed in `ccb985b6`: `Cache-Control: no-cache` on both sides.
- `zig build brief -- <path>` lists only the gates bound to the path. It
  omitted `bench-check` for `server.zig` and `smoke-getting-started` for
  `docs/user-guide.md`. Fixed in `571ad967`: the root sentence says so, and the
  path brief names `zig build brief` for every gate.
- Two `verify` runs could write ledger lines at one offset. Fixed in
  `ae427d20` with an exclusive file lock.
- A solution note described the removed host-root check. Fixed in `571ad967`.
- CHANGELOG.md had no entry for the wire changes. Fixed in `ccb985b6`.
- Rejected: a `compress` or `zstd` receipt would reach `unreachable` in the
  verifier. A run against a fake endpoint showed that the Zig client refuses
  the encoding first, with `HttpContentEncodingUnsupported` and exit 5.
- Rejected: `zttp verify` on the well-known URL reports "not attested". This
  is older than U2. The receipt is not a handler response.
- Open, with no test: the network path of `zttp verify` has no automated test.
  A fake endpoint showed exit 3 on a mismatch. The equality of the 500 body and
  the incident line rests on probes of a deployed binary and `zttp dev`.
- The 500 body, the incident log line, and the JSON key said "proven" for
  facts that the header grades as `claimed=`. Decision 5 (a) changes them.
- Observation, older than this plan: the production policy never accepts
  `deterministic`, `read_only`, or `state_isolated`, and `acceptedProperties`
  never sets `pure`. A deployed binary therefore never enables the proof cache,
  and its pooling policy is always `reuse_bounded_by_count`. The startup log of
  the `zttp init` deploy showed exactly that. Decision 6 (a) leaves it for a
  separate plan.

## Order

U5 is complete. U1 and U3 run in parallel. U2 follows U1, and U4 follows U3,
because each pair changes the same files. One `bash scripts/verify.sh` run
covers each pair of commits. U6 runs last.

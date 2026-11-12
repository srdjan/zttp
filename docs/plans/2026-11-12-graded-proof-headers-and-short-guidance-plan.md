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

Decision 3 is open: U2 below changes the attestation wire. It waits for the
owner.

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
  `packages/runtime/src/server.zig`, `docs/proofs-and-receipts.md`,
  `docs/user-guide.md`.
- Turn budget: 60.

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

Waits for Decision 3. Today each response carries the full `Zttp-Attest` value.
The review measured 2,069 bytes for that line and 2,393 header bytes for an
11-byte body. The change sends a short digest in the header and the full value
at `/.well-known/zttp-attest`. It changes the attestation wire. It follows the
equality rule of "Format cutover" in `docs/verification.md` and needs a new
attestation version.

Decision 3 options: (a) do U2 after U1, with a new attestation version.
(b) keep the full value in each response. Recommendation: (a).

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

Before the edit, the implementer reads the root-file rule of the agent-spine
convention. If that rule requires the full table, the implementer stops and
reports.

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

After U1, U3, and U4, Fable and Codex astra review the combined diff of E2
(`335abac4`), U1, U3, U4, and U5, with split briefs. Each brief gives the diff
and this plan, not the conclusions of Opus. Opus probes each finding at the
commit. A confirmed finding gets a failing test and a fix. A rejected finding
gets its reason in this plan. The probes cover a deployed binary, `zttp dev`,
and `zttp serve`, with and without `--incident-log`, and a client that reads
the `Zttp-Proofs` header.

## Order

U5 is complete. Then U1, U3, U4, and U6. U2 waits for Decision 3.

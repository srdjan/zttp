# Minimal design implementation worklog

The user authorized the full scope of `2026-10-08-minimal-design-audit.md`.
The user paused the work on October 9 and resumed it on October 10.
The resumed baseline is local `main` at `7912bb56`. The worktree is clean.

## Constraints and direction

Preserve public output, errors, byte ownership, request isolation, and provider identity.
Keep the producer and acceptance kernel independent.
Use unfiltered named checks and read each build exit status directly.
Work on local `main`. Commit each complete unit locally. Do not push.
The main agent reviews each delegated diff and runs authoritative checks.

## Scope and evidence

| Requirement | Current state | Required evidence |
|---|---|---|
| Remove withdrawn repairs and classify scanner helpers | Delegated tool cleanup | Caller census, canonicalize goldens, test-canonicalize, test-module-boundary |
| Remove obsolete WebSocket methods | API research in progress | Export check, test-zruntime, test-server, corrected census note |
| Combine proof JSON writers | Delegated tool cleanup | Public writer characterization, test-zts-cli, test-precompile, test-contract-golden |
| Share receipt lookup | Complete and checked | One borrowed lookup; both named checks passed |
| Share catalog field parsing | Pending | Diagnostic ordering and details, test-zts, test-contract-golden, test-diagnostic-corpus, test-proof-checker, test-proof-checker-mutants |
| Consolidate query operation boundary | Research in progress | Schema, aliases, errors, filtering, test-expert-app |
| Share runtime invocation policy | Pending | Owned bytes, borrowed lease, faults, identities, counters, test-server, test-zruntime, test |
| Retire unread latency telemetry | External API check in progress | Supported API decision, operational counters, acquisition timer, runtime checks |
| Give provider configuration one owner | Research in progress | Failure cleanup, atomic model restamping, identity and replay, test-expert-app, test-cassette |
| Migrate positional check calls | API research in progress | Named options, compatibility exports, six named audit checks |
| Correct compile completeness | Predicate difference remains | Public compile/check reproduction, shared generated-path summary, test-precompile, test-zts, test-flow-census, test-contract-golden |

## Current work and next action

Tool cleanup owns `canonicalize.zig` and `json_diagnostics.zig`.
Runtime and provider research agents perform read-only inspection.
The main agent owns the receipt lookup and this worklog.
The receipt baseline passed with 1127 tests and one skipped test.
The strengthened malformed-identity test passed before the lookup change.
The unfiltered `test-expert-app` and `test-standin` checks passed after the change.
The logs are `/private/tmp/zttp-minimal-receipt-characterization.log` and `/private/tmp/zttp-minimal-receipt.log`.
The lookup returns a borrowed receipt. Autoloop finalization derives both values before any transcript mutation.

Public writer characterization passed before consolidation through `test-zts-cli`.
The tool checks now run against the consolidated writer and private dead-code removal.
The main agent will review their exit status and commit each unit separately.

## API decision

Published `v0.21.0` sources expose both obsolete WebSocket methods and `getMetrics`.
The runtime package publishes all source files. External caller usage remains unknown.
The tools package exports `zts_cli.precompile`, including the positional check wrappers.
The positional wrappers will remain. Repository callers will use named options.
Decision 1 asks the user whether to remove the ten latency fields and recording code.
The decision preserves operational counters and the acquisition timeout timer.

The provider ownership consultation route is unavailable.
The advisor runtime inspector could not identify the parent runtime.
The main agent retains design and verification ownership.

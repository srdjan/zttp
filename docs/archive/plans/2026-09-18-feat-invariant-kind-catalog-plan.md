# ZTTP Invariant Kind Catalog

Archive status, reviewed 2026-09-21: Implemented. Delivery from `d571a6ed`
through `0df4e7f2` added per-kind metadata, schema 2, Zig authoring and drift
tooling, linked-adapter evidence, declared-account enforcement, and status
reporting. Current behavior is in the verification guide. The baseline and
intended steps below describe the original plan. Current work status is in
[Roadmap](../../roadmap.md).

## Purpose and original baseline

Extend the implemented balance invariant with a closed catalog over the protected
ledger. Developers select a supported kind and review its canonical description.
Deterministic builds consume the confirmed specification. Jev can suggest a kind;
it cannot verify an arbitrary sentence or authorize an artifact.

Refreshed against `6ad648ae` on 2026-09-19. The changes since the foundation commit
`f0d8c5e8` are this catalog plan and the No Python rule in `AGENTS.md`. The catalog
was not implemented at that baseline. This plan continues
[ZTTP Application Invariants](2026-09-18-feat-application-invariants-plan.md).
It preserves that plan's exclusion of general predicates and automatic migration.
This refresh used source inspection, not new test results.

The original implementation had one kind, `balance_conservation_v1`, and two
operations, `post` and `balance`. These are separate catalogs. The kernel owns
specification schema 1 and a fixed adapter identity in
`packages/proof-checker/src/invariant.zig`. The native module enforces conservation
without a kind selector. Its configuration receives ledger, currencies and the
specification digest from `HandlerInstance.installLedgerModuleState` in
`packages/runtime/src/handler_instance.zig`.

The proof checker already compares declared operations with independent bytecode
observations. `packages/runtime/src/proofs/invariant_report.zig` already separates
coverage, native trust and runtime readiness. Extend these paths. Do not replace
them with a new generic verification system.

## Admission criterion

A protected store must own atomic commit, writer isolation, replay idempotence,
and baseline validation. `packages/modules/src/data/ledger.zig` supplies these
through `executePost`, `checkIdempotency` and `bootstrapOrValidate`. This argument
depends on the existing native adapter, SQLite and deployment trust assumptions.
It does not prove arbitrary handler logic.

A kind must specify both its write check and its baseline check. A group predicate
runs before the transaction from the posting group alone. A state predicate runs
inside the transaction against the final per-account balances before commit.
Conservation is the existing group predicate. This release adds only
`declared_accounts_v1`, also a group predicate. It does not add a state-predicate
framework before a supported kind needs one.

The catalog gate must establish agreement between supported kinds, descriptions,
native dispatch and adapter identities. Predicate correctness still needs
behavior tests. A hash of a descriptor does not prove that its implementation
checks the predicate.

## Technical decisions

### Supported kinds and configured kinds

The adapter's supported set and an application's configured set are different.
Conservation remains mandatory. Both v1 and v2 specifications must include it;
a v2 specification can add declared accounts. The CLI lists conservation as
required and declared accounts as optional. Idempotence and atomicity remain
module guarantees, not selectable kinds.

The kernel retains its import-free boundary. Keep its accepted kind descriptions
and versions beside `Kind`. Keep the native dispatch table in the modules package,
which currently depends only on the SDK. Compare the independent definitions in
a host Zig gate. Do not make the checker import the native module or the SDK.

The adapter digest binds the native supported-kind manifest, predicate semantic
versions, mandatory kinds, ledger schema and operation identities. The runtime
must obtain that manifest from the linked native adapter. It must compare it with
the consumer's expected manifest before opening the store. The artifact graph
binds this checked identity. Deriving both sides only from the specification or
from the checker's own table would not detect a missing native implementation.
The separate specification digest binds the exact selected kinds and parameters.

The native dispatch table must drive the checks used by posting and baseline
validation. Adding a name to an unused table is not evidence of enforcement.
Unknown or unsupported configured kinds fail closed. A predicate implementation
change requires a semantic version or implementation identity change.

### Specification and storage compatibility

Keep the v1 decoder and its exact canonical bytes and digest. Existing v1 JSON
must still build a conservation-only artifact that can open its existing ledger.
Add specification schema 2 with common ledger and currency fields plus a sorted,
length-delimited list of kind payloads. Conservation has no extra payload;
declared accounts carries its matchers. Keep one specification graph member.

Reject duplicate or unknown kinds, missing conservation, malformed lengths,
trailing data, non-canonical record order and oversize specifications. Retain the
current bounded specification size and zero-copy checker decoding. Use a distinct
v2 digest domain. Expand `InvariantVerdicts.kind_bits` to `u32` and check supported
ordinals before shifting. Carry those bits through runtime and proof reports.

The artifact envelope and certificate are currently version 4. The new spec uses
the existing bounded section and digest fields; do not change those outer formats
unless their wire layout changes. A changed adapter identity invalidates evidence
bound to the old adapter when assessed by the new consumer. Require a rebuild;
do not silently substitute a new identity for an old certificate.

`ledger_meta.invariant_digest` binds a store to its exact specification.
Changing kinds, matchers, currencies or encoding from v1 to v2 must refuse an
existing mismatched store without changing it. A new v2 specification can create
a fresh store. Reopening a store with that same v2 specification must validate
its baseline. Adding a kind to an existing store requires a separate migration
plan. Startup must never rewrite metadata to make a mismatch pass.

### Declared accounts

Define account patterns as a closed union of exact matches and prefix matches.
An exact matcher accepts only the same account bytes. A prefix matcher accepts
an account that starts with its non-empty prefix, including the prefix itself.
Matching is case-sensitive over valid UTF-8 bytes, with no normalization, regex,
wildcards or locale rules. For example, prefix `asset:` accepts `asset:cash` and
refuses `assets:cash`. An empty prefix is invalid.

The payload requires a non-empty matcher list. Canonicalize by matcher tag and
then byte value; reject duplicates. Validate matcher text with the existing
non-empty, NUL-free UTF-8 boundary. The bounded spec size limits the payload.
Require every entry to match at least one rule, including zero amounts and
entries that cancel on the same account. Refuse the whole posting before any
write if one entry fails. Return a stable domain error through the existing
Result API.

Baseline validation checks historical entry accounts and materialized balance
accounts under the existing exclusive transaction. Checking non-zero balances
alone would miss a forbidden account whose net balance is zero. Retain posting
hash, conservation, schema, currency and materialized-balance checks. `balance`
remains a read API and does not become an account authorization check.

### Authoring and evidence claims

`zttp invariant list` prints the supported kinds, required status and canonical
descriptions. `zttp invariant author` requires explicit kind selection. A sentence
alone cannot produce a candidate. Emit the original sentence, canonical meanings,
`requiresReview`, advisory status and the structured candidate. Never save an
accepted specification or claim that the sentence has been proved.

`reviewed_against` belongs in the review output, outside the accepted candidate.
It identifies the canonical kind descriptions and versions shown for human review.
It does not prove that a person reviewed them. Keep legacy v1 `statement` input
readable as an annotation. All executable constraints belong in canonical
structured fields.

Keep Jev opt-in and outside build, check, acceptance and serving. Inject the
advisory transport at the host tooling boundary, following the pure/host split
used by `packages/tools/src/smt_solver.zig`. Send only the supplied sentence and
public catalog criteria in the request body. The API key is used only for
transport authentication. No source, ledger data or credential value enters model
state or logs. Unsupported, malformed, unavailable or conflicting advice produces
no advisory candidate. An explicit selection without Jev can produce a candidate,
but cannot establish that the sentence means the same thing. Verify the provider
protocol against its official documentation when implementing the transport.

Coverage counts call sites, not calls that executed. The current checker refuses
an empty operation set but accepts a balance-only artifact. This is a missing
write-applicability report, not a demonstrated conservation failure. Retain
read-only serving after successful baseline validation. Report each configured
kind as `vacuous` when it has no observed write site; otherwise report write-site
coverage. Neither state claims that a posting occurred. Keep store readiness in a
separate field. Continue to refuse a configured artifact with no ledger operation.

```text
Explicit selection -> candidate -> human review -> confirmed specification
                                                   |
                        deterministic build -------+
                                  |
                 artifact + certificate + spec
                                  |
          independent call observation + consumer identity checks
                                  |
             linked native manifest check -> baseline validation
                                  |
               installed store -> checked atomic postings
```

## Implementation units

Retain these IDs when refining the plan. Execute U2, U1, U7, U3, U4, U5, U6 and U8
in that order. U7 replaces the gate before adapter changes invalidate its current
fixed-string checks. Extend that gate with each later unit. Keep affected tests
and documentation current in each commit; U8 completes the user-facing reports.
Each unit must leave the conservation path usable. Do not advertise kind 2 until
its codec, native enforcement and consumer checks are wired.

### U2: Define kind metadata

Add canonical descriptions, semantic versions, required status and write
applicability beside `Kind` in `packages/proof-checker/src/invariant.zig`.
Derive the offered list from these rows. Keep the operation catalog separate.
Test non-empty metadata, unique wire identities and exhaustive enum coverage.

### U1: Replace Python authoring

Add the developer CLI command through `packages/runtime/src/dev_cli.zig`, its help
through `cli_help.zig`, and a host authoring module in `packages/tools/src/`.
Expose the command tests through the developer CLI test root in `cli_main.zig`.
Replace the Python self-test dependency in `build.zig`, then delete
`scripts/invariant-author.py`. Do not add HTTP dependencies to the pure checker,
ZTS analyzer or runtime-only binary.

Test list output, missing selection, unknown kind, invalid parameters, stable
candidate output and the distinction between a candidate and an accepted spec.
Use an injected transport to test Jev failures and request data boundaries without
network calls. A sentence such as "accounts cannot be overdrawn" without explicit
selection must not become a conservation candidate.

### U3: Add the versioned payload set

Extend the kernel codec and `packages/tools/src/invariant_config.zig` together.
Normalize both schemas to one internal view while preserving v1 bytes. Cover JSON
unknown fields, canonical sort order, bounds, duplicate records and digest
separation. Check artifact section handling, graph membership, checker verdicts
and report fields. Test v1 compatibility and malformed v2 bytes through public
parsing and acceptance APIs. Keep unsupported kinds rejected until U5.

### U4: Bind the linked adapter

Add native manifest and dispatch metadata in `packages/modules/src/data/ledger.zig`
and expose it through `packages/zts/src/modules/data/ledger.zig`. Pass selected
payloads through `HandlerInstance.installLedgerModuleState` into owned native
configuration; retain allocator cleanup on every failure. Update
`packages/runtime/src/artifact_graph.zig` and the producer/consumer integration to
bind the linked adapter as specified above. The graph currently receives only the
specification digest. Add an explicit adapter digest input, computed and checked
independently by the build and activation paths.

Test a mismatched native manifest, missing kind support, changed predicate version,
old adapter certificate and incomplete configuration. All must fail before store
creation or mutation. Rebuild a v1 fixture and confirm its unchanged store digest
is accepted. Preserve the checker's import-free build.

### U5: Add declared accounts end to end

Add the second enum/metadata row, tagged payload, CLI parameters, native dispatch
entry and baseline check as one complete unit. Keep conservation mandatory.
Update module descriptions, generated specifications and their governed hashes
when the public module contract changes.

Test exact and prefix matching, case differences, UTF-8, invalid matcher text,
duplicates, forbidden zero-value entries and cancelling entries. A refused group
must leave entries, balances and the idempotency record unchanged. Reopen a valid
v2 store, refuse a same-spec store with a forbidden historical or balance account,
and refuse a changed spec without rewriting ledger metadata. Use valid fixtures
that reach the account check, not an earlier hash or metadata failure.

### U6: Report write applicability

Extend `checkInvariantCoverage`, `InvariantVerdicts` and `InvariantStatus` with
per-kind write applicability. Keep exact operation/witness/observation comparison.
Test read-only coverage with `vacuous` write status, write-site coverage, empty
operations and forged or omitted witnesses. A declared write that is absent from
independent observation must reject, not remove the vacuous status.

### U7: Replace and extend the drift gate

Replace the Python body of `scripts/check-invariants.sh` with a host Zig command
wired to `zig build test-invariant-drift`. A shell wrapper may only invoke that
command. Preserve the existing compiler, operation catalog, native export/effect,
observer, proof IR tag, adapter graph, documentation and compiled-test checks.
Add checks for current kind metadata and authoring output. U3, U4 and U5 extend
this gate with versioned payload, native dispatch and manifest checks as those
surfaces appear. Comparing only the new four surfaces would lose current
operation-coverage protection.

The current gate reads fourteen named inputs. Make missing, empty or unparsed
inputs fail explicitly. Test deletion and mutation of each independent input,
including authoring and build wiring. Keep compiled suite dependencies in
`build.zig`; finding a test name in a source file does not prove the test ran.
Remove invariant-related Python invocations from the build. Repository-wide
Python removal remains outside this feature.

### U8: Complete reports and documentation

Extend the existing summary with configured kind names, write applicability,
trusted native enforcement, independent call-site coverage and baseline status.
Always state that external writer exclusion is a deployment assumption that the
checker does not verify. Offline proof reports must keep baseline status as
`not checked`; only live validated instances can report readiness.

Update `docs/verification.md`, `docs/user-guide.md` and `CONCEPTS.md`, including
v1 compatibility, v2 fresh-store requirements and the Jev boundary. Test exact
status values for unconfigured, rejected, offline, read-only and ready write-capable
artifacts. No output may label arbitrary prose as verified.

## Validation and completion

During implementation, start with a small end-to-end case: author an explicit
candidate, build it, start a fresh store, accept a balanced declared posting and
refuse an undeclared one without state change. Then cover restart, read-only
status, changed adapter identity and invalid baseline. Preserve existing retry,
conflicting-key, overflow, currency separation, concurrent-write, interrupted-commit,
storage-bypass, output-path and secret-label regressions.

Run the affected module, SDK, compiler, checker, artifact, developer CLI and runtime
suites. Retain proof-checker purity, capability, module governance, module boundary,
proof-swallow, proof ratchet, stand-in and invariant drift gates. Run
`zig build test-zruntime` separately. Build the browser analyzer to check the pure
boundary. Every new gate must have a non-empty input floor and a failure probe.
Use behavior through public APIs rather than tests of private helpers alone.

The predecessor records incomplete full-repository validation: model replay
fixtures need a fresh provider capture after module tool changes, and the release
build hit the execution limit. Historical model responses must not be rewritten
as if newly captured. These remain pending until rerun; this refresh grants no
permission for long scripts or live provider captures. The unrelated deleted
`docs/zts-advanced-v2.1.md` remains outside this work.

Completion requires the full candidate-to-runtime path, enforced account rules,
unchanged v1 store compatibility, truthful status output, no invariant Python
tooling, and recorded verification results. Work on local main. Commit complete
isolated units, leave pre-existing user changes alone and do not push.

## Boundaries and measurements

New protected stores, general predicates, distributed transactions, currency
conversion, temporal rules, migration tooling, account floors and transfer topology
remain deferred. Program-shape constraints need flow or operand analysis and do
not become ledger kinds. Existing algebraic law metadata keeps its name.

Baseline validation still runs per handler instance under an exclusive lock.
Posting prepares statements repeatedly, and baseline validation scans stored
postings. Measure startup, pool expansion and posting cost on a small workload
before scaling. Change only the scale parameter between comparable runs. Measure
the added account-check cost before adding a third kind. Do not assume a generated
catalog resolves lock contention or permits validation once per generation.

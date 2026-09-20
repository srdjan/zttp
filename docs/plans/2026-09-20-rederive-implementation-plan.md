# Bounded rederive implementation

Status: approved by the user, with revalidation required before implementation.

## Revalidation

The discovery report was measured at `afe1dc10`. This plan was revalidated on
2026-09-20 at `40f52332` on local `main`, with a clean working tree and Zig
0.16.0. The five implementation targets have no changes between those commits:
`contract_builder.zig`, `type_checker.zig`, `session/events.zig`,
`session/reconstructor.zig`, and `change_transaction.zig`.

The expert replay failures from discovery are resolved by intervening work.
The unfiltered `zig build test-expert-app -j1 --summary all` now exits 0:
1,059 passed and one skipped. Do not change or refresh the empirical recordings
as part of this work.

The AST counter's nine tests pass. Its small-input check reports 10 branch
points and one function for `identifier.zig`. The full tracked baseline reports
588 files, 61,431 branch points, 9,918 functions, and zero parse failures.
This is a custom decision score, not source coverage or standard cyclomatic
complexity. It excludes inline test bodies but includes top-level test helpers.

| Target files | Branch points before | Functions before |
|---|---:|---:|
| contract builder and type checker | 3,486 | 286 |
| event persistence and reconstruction | 611 | 62 |
| workspace transaction | 223 | 41 |

The plan remains applicable. Implement each phase only after its prerequisite
tests can reject an incorrect replacement. Keep native Zig error unions,
explicit allocators, byte ownership, package layering, and the single source
write authority. Commit each complete isolated unit on local `main`. Do not push.

## Phase 0: establish the current baseline

Run the complete unfiltered aggregate suite. The repository's two-minute rule
requires user approval for a longer run. Correct the stale references to a v3
journal: the current event and metadata schemas are v4, with `ZTE4` frames.
Keep the older rebase plan as historical evidence.

## Phases 1 and 2: schema literal contract and shared writer

First pin the public behavior of the duplicated IR literal writer. Test integer
and float literals, negative values, booleans, null, escaped strings, nested
arrays and objects, quoted and bare keys, dynamic inputs, computed keys, spreads,
calls, shadowed `JSON`, and malformed raw schema strings. Use accepted contrasts
for rejected inputs. Assert emitted contract schema bytes and inferred types.
Map current tests before adding cases. Add allocation-failure verification for
the owned result. Demonstrate that deliberate changes to the selected decision
families make these tests fail, then restore the source.

Derive one small writer from that contract. Its inputs are an immutable IR view,
a node, an explicit atom resolver, and an allocator. Its output is a complete
owned JSON slice or no readable literal. No partial output may escape. Preserve
current order, whitespace, number rendering, and failure semantics.

Keep raw-string schema validation and schema-to-type projection in their current
callers. Do not merge `extractSchemaJson`: the contract builder validates raw
JSON at a different point from the type checker.

Verification: unfiltered `test-zts`, `test-zts-cli`, `test-precompile`,
`test-contract-golden`, `test-zts-layering`, `test-module-boundary`, and
`test-proof-swallow`. Count the new helper as well as both callers. Retain the
mechanical replacement only if the combined score falls and behavior holds.
Do not claim a delta before measuring it.

## Phase 3: typed journal decoding and exhaustive application

First establish an enum-driven census for all 13 event kinds. Each kind must
have encoding, decoding, identity classification, and either transcript
application or an explicit session-only disposition. Pin all nine transcript
kinds, legacy tool-use parts, batches, optional UI payloads, additive fields,
invalid entry/part transitions, checkpoints at the next entry boundary,
checksum corruption, incomplete-tail recovery, and allocation ownership.

Derive a pure typed envelope decoder and exhaustive sequence/projection fold.
Keep frame reads, locking, append, synchronization, and incomplete-tail repair
at the I/O boundary. Preserve schema 4 and the exact frame and receipt bytes.
Preserve compatibility and error distinctions between the existing entry
points. Raw journal and transcript entries remain proof and audit authority;
model projection is replaceable and never supplies that authority.

Compiler exhaustiveness and behavior decide acceptance. A higher branch count
is acceptable if the typed boundary removes independent string dispatch.
Demonstrate that tests detect selected wrong kind, identity, and projection
decisions. Compare wire bytes and public reconstruction before and after.

Verification: unfiltered `test-expert-app`, `test-cassette`, `test-simulator`,
`test-standin`, and `test-module-boundary`.

## Phase 4: pure transaction recovery planning

First pin the current marker precedence, including combinations currently
tolerated. Add mixed existing/new-file transactions, repeated recovery, failure
during recovery, and durable acknowledgement retry. Exercise the durable effect
families: manifest/image/receipt writes, stage writes, marker writes, rename,
file synchronization, and directory synchronization. Use simple fault injection.
Assert exact final source and receipt state. Every validation or third-state
conflict must perform zero source writes.

Derive a typed classification of current journal state and a pure recovery
decision from validated expected/observed digests. The existing locked module
interprets the plan and remains the sole source-write authority. Preserve
roll-forward recovery, nonblocking workspace exclusion, full proof read-set
rechecks, all-target validation before writes, synchronization order, marker
formats, and pending receipts until session acknowledgement.

Do not reject a previously accepted marker combination merely to simplify the
type. Such a change requires separate evidence and authorization.

Verification: unfiltered `test-expert-app`, `test-simulator`, and
`test-module-boundary`, plus deliberate mutations of the decision families
covered by the new matrix. Report the measured branch score; do not require a
type-driven change to reduce it.

## Conditional discovery items

The discovery report's phase 5 was conditional on selecting server shutdown or
certificate decoder work. Neither is selected by this plan. Leave their current
implementation unchanged. Their identified grace-expiry and four decode-error
probe gaps remain prerequisites for any later rederive in those areas.

The flow sink classifier and metric redesign were additional discovery ideas,
not selected implementation phases. Do not widen this change to include them.

## Integration and completion evidence

Update architecture and testing documentation to describe the actual resulting
boundaries. Mark completed items in this plan with commands and observed results.
Retain the historical baseline. Do not change generated convergence or coverage
pages by hand.

The main agent reviews every delegated diff and runs the verification commands.
Run `bash scripts/verify.sh` as the final integration gate, with permission for
execution beyond two minutes. No filtered run counts as acceptance evidence.
Do not sum overlapping suites into a repository test count.

Completion requires all selected phases, tested failure behavior, measured
schema branch reduction, unchanged journal/source authority contracts, a green
full gate, isolated local commits, and a clean working tree. Any unresolved
item must remain explicit rather than being reported as complete.

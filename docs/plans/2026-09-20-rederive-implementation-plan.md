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

## Execution record

Phase 0: the focused expert baseline and documentation gates pass. The full
aggregate and final gate still require permission to exceed two minutes.

Phase 1: the public schema matrix now checks exact literal bytes, raw JSON
retention, inferred string/number/boolean/array types, dynamic values and
spreads, malformed input, and JSON shadowing. Its first unfiltered run exposed
one leaked writer allocation on partial-output refusal. Both writer wrappers
now defer cleanup of the buffer owner. The same unfiltered combined
`test-zts test-precompile test-zts-cli -j1 --summary all` run exits 0 with
2,499 passed and one skipped. Two deliberate mutations were then tested with
unfiltered suites. Inverted boolean output failed the exact-byte precompile
test. Suppressed stringify schema projection failed the inferred-type and
binding tests in `test-zts`. Both mutations were restored before extraction.

Phase 2: both callers now use `ir_json_literal.zig`. Their separate atom
resolvers and raw-schema handling remain. The helper tests supported output,
refusal, malformed properties, resolver use, and every allocation failure.
The unfiltered `test-zts -j1 --summary all` run exits 0 with 2,216 passed and
one skipped. The combined `test-precompile test-zts-cli test-contract-golden
test-zts-layering test-module-boundary test-proof-swallow -j1 --summary all`
run exits 0 with 288 passed and all gates green. Including the new helper,
branch points fall from 3,486 to 3,439; functions change from 286 to 287. The
combined custom score falls from 3,772 to 3,726. These are source measurements,
not runtime or coverage claims.

Phases 3 and 4 prerequisites: the full event-kind and recovery matrices pass
under unfiltered `test-expert-app -j1 --summary all`: 1,092 passed and one
skipped. The journal allocation sweep exposed a display-text leak when UI
payload parsing failed; cleanup now covers that error. The matrices also pin
opaque session payloads, version errors, and conflict versus read-error order.
Deliberate wrong-kind, part-gap, projection-file, marker-precedence, and
third-state-write changes caused 11 relevant tests to fail. All mutations
were restored and checked against the committed prerequisite files.

After these prerequisites, the journal files measure 652 branch points and
73 functions. The recovery file measures 286 branch points and 54 functions.
The increase from discovery includes fault hooks and top-level test helpers.
Use these additional baselines when comparing the structural replacements.

Phase 3: `DecodedEnvelope` owns the parsed JSON; `DecodedRecord` holds borrowed
typed fields. Journal sequence and transcript/projection application now use
exhaustive switches. The consumer policy preserves the different acceptance
rules of journal recovery and reconstruction. Framing and write order are
unchanged. The main review and an independent read-only review found no
compatibility regression. Zig does not enforce borrowed lifetimes; current
callers copy retained data before releasing the envelope.

Phase 4: marker observation retains its short-circuit order. The pure staged
planner rejects a target conflict before the next target read and publishes
only after all actions are known. The effect interpreter handles every action
explicitly. Incomplete publication returns an error in all build modes. Direct
tests distinguish keeping a candidate from rewriting it, including equal
baseline and candidate digests. Mutations that rewrote candidates and removed
the completion check failed all three new planner tests.

Removing one case from each journal fold and adding an unhandled recovery action
produced three compiler exhaustiveness errors. All probes were restored, and
SHA-256 checks confirmed the reviewed PI source before final suite execution.
The unfiltered `test-expert-app test-cassette -j1 --summary all` run exits 0:
1,095 expert tests pass with one skipped, and 421 cassette tests pass. The
`test-simulator test-standin test-module-boundary -j1 --summary all` run exits 0:
930 simulator tests and 56 stand-in tests pass; the boundary gate passes.

After the structural replacements, the journal files measure 519 branch points
and 80 functions, down from 652 and 73 after prerequisites. Recovery measures
325 branch points and 61 functions, up from 286 and 54 after prerequisites.
No runtime speed or source coverage improvement is claimed.

Additional integration checks: the final committed schema tests pass again
with 2,216 passed and one skipped. `test-zruntime -j1 --summary all` exits 0
with 411 passed and one skipped. `zig build wasm --summary all` exits 0.
The full aggregate and `scripts/verify.sh` remain outstanding until their
complete runs finish within the time limit or longer execution is approved.

Further integration checks pass: `test-cli -Dstudio -j1 --summary all` reports
776 passed and one skipped, with no failures, leaks, or logged errors.
`test-panic-isolation -j1 --summary all` passes all 14 build steps, including
top-level and nested handler recovery. `smoke-v1 --summary all` passes the
init, doctor, check, build, deploy, and HTTP request checks. The final named
documentation drift and link gates pass.

The individual verification scripts for normalization, idiom tables, canonical
style, grammar, decision producers, metadata pins, agent determinism, installer
archive safety, proof-checker boundaries, diagnostic producers, proof ratchets,
residual guards, and semantics all exit 0. Normalization checks 60 files with
no skips; 55 are printed and five JSX inputs retain their original layout.
The semantics gate proves all 14 SMT equivalences and refutes all four excluded
laws with Z3. Generated module specifications match, the policy hash matches
its committed pin, and the expert metadata assertions pass.

The final aggregate attempt and the ReleaseFast build each remained active at
the two-minute limit and were stopped. Neither produced a complete build
summary. They are incomplete checks, not established functional failures.
The full `bash scripts/verify.sh` gate has not run. Approval for execution
beyond two minutes remains pending under the user-supplied session instruction.
The individual green checks above do not replace these outstanding commands.

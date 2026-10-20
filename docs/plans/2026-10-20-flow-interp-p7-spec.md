# Flow redesign P7–P9: request contents, persistent heaps and evidence

Source checkpoint: P7 and P8 implemented; P9 compatibility acceptance is in progress,
2026-10-20. The production facade now delegates to the interpreter. The old
verdict walk and label-family summary producer have been removed locally.
The owner selected all units of the hardening and pruning plan; acceptance
remains conditional on the gates below.

The semantic authorities are the round 3 requirements in
[the redesign plan](2026-10-18-flow-checker-sound-redesign-plan.md) and D22–D25 in
[the P6 specification](2026-10-20-flow-interp-p6-spec.md). The owner explicitly
selected the strict egress policy when differential testing exposed two
incorrect weather-egress claims. Only that example's `injection_safe` and
`pii_contained` claims were removed; `input_validated` remains required. The
frozen floor is now 48 handlers and 214 required bits. Historical 216-bit
reports and recorded generation snapshots retain their original contents.

## Request and sink model

`analyzeHandler` seeds ordinary heap sites for the request, headers and query.
Their summary cells carry `user_input`; the named authorization header also
carries `credential`. Named reads distinguish accept from authorization, while
dynamic reads and serialization include every possible field. Aliases, local
calls, callbacks and containers move these origins through the existing value
and heap domain. Request body, method, URL and path are scalar fields. Headers
and query are mutable objects; routing creates its own params container.

The runtime prototype roster has explicit transfers for request text/json and
headers get/has/set/append/delete, with a bidirectional nonempty census.
Request body readers read only body, never the authorization-bearing whole
request. Headers use case-insensitive keys and weak updates. The separately
installed `fetchSync` global has its own runtime transfer and replay identity.
Unknown native operations remain unresolved.

Logs and external URL/query/body/headers/options are observed when evaluated.
Only root completions produce response sinks. Constructing and discarding an
HTML response creates no response event. Response helpers model the runtime's
body/status fields and discarded init headers; structural response records
retain their actual headers. HTML checks inspect the current body and possible
content type, including body/header mutations after construction. The P6
property/sink table decides which defense each sink accepts.

`flow_report.zig` contains the shared public report schema. It decides no
verdict. The production checker reexports those types while the new evaluator
builds its own properties, diagnostics, defended paths and witness capsules.

## Heap-bound validation and named guards

`validateObject` returns a Result whose value aliases the input. A schema view
watches the transitive heap cells and their finite generations; it decorates
the checked view rather than the raw alias or every field of the Result.
Named, dynamic and aliased writes invalidate watched views even when labels
stay unchanged. Generations saturate; a saturated view cannot prove safety.
A copied primitive can keep an established fact after its former container is
mutated. A raw selection key is a separate contributor and never inherits the
container's validation. Watchers include values already reachable through the
unknown-target cell.

Defense bits establish safety; optional guard provenance supplies only the
name shown in a defended card. A common guard survives aliases and unchanged
movement. Different guards at a join clear the name while retaining a defense
that holds on every exposed contributor. Clean literals are neutral. A path
whose guard cannot be named receives no invented guarded card. Containment
cards require an observed source family and no governed exposed sink.

## Imported modules and persistence

One evaluator borrows retained parser/atom/capture snapshots through the whole
analysis. Bodies, allocation sites and captures use checked module identities;
property names are canonicalized by spelling. Actual runtime globals are
shared unqualified name cells, and import initialization copies the current
exported global value. This deliberately follows code generation rather than
assuming live isolated ES-module bindings. Replaced or ambiguous named handler
entries clear the result instead of analyzing a stale lexical body as proof.

Module initialization runs in the loader's original order. Initializer return
values are discarded, but completion heaps, immediate sinks and writes survive.
The outer invocation fixpoint projects every location reachable from module
and shared builtin roots, including scalar roots, nested objects and closure
capture cells. Each invocation seeds a fresh request. Sinks from every pass
remain visible, one root budget covers all work, and iteration/budget limits
clear claims. The old fixed label-family imported summaries cannot represent
these alias and heap effects and must be removed at cutover.

Source owners preserve D-006's exact imported read/traversal/type-failure
behavior. The independent imported fault reader stays physically separate.
No imported local node index is projected as a root source node: diagnostics
use the root callsite plus imported location help; events retain source module
and endpoint identity.

## Constructive evidence

A state carries immutable request constraints and ordered tracked I/O calls.
The pure evidence helper reads existing provenance and never evaluates code a
second time. Supported branch predicates constrain the path before a sink can
execute. Joins keep a complete capsule only when every joined path agrees;
unsupported predicates, imprecise callable selection, loop/recursive summary
revisits and ambiguous operation candidates decline constructive evidence.
They still contribute conservative flow verdicts.

Exact request field provenance requires an unchanged named request field on
every receiver alternative. Exact object I/O provenance watches mutations.
Absent fields, dynamic/index reads and conflicting alternatives drop exact
provenance. A finite callee-selection fact also prevents a possible but
unselected function from supplying an internal-sink witness.

The first handler invocation keeps the module initialization I/O prefix because
runtime replay installs its stubs before loading the module. Later persistent
passes represent additional requests and cannot emit a one-request witness.
Audited replay-pure exports are omitted from synthetic stub calls and exact
I/O origins: they run through the real replay fallback, preserving native
Dict/Bytes brands and nested callback I/O. Other tracked calls preserve exact
sequence indices, including unused sibling calls.

Witness completeness is also a data-local fact. An imprecise element or
possibly absent field cannot turn an over-approximated label into a concrete
leak demonstration. A real, failable replay-pure Result does not establish
that its payload exists for the synthetic input. These limitations decline
only the capsule, leaving the conservative diagnostic and property intact.
The public proof-card adapter requires the capsule and rechecks its candidate;
it never fabricates a default request when evidence is absent. Containment
text names the sinks governed by the individual property.

Before attaching a capsule, solve it and validate the concrete candidate
against every retained constraint. Path and full URL, exact HTTP status and
optional presence remain distinct predicates. An unsupported or contradictory
capsule stays absent; a warning alone does not establish an executable trace.
The public witness JSON shape is unchanged. The additional exact constraint
tags require an explicit vocabulary disposition at the analyzer cutover.

## Acceptance and remaining work

The version 7 facade is active locally and the old verdict walk is removed.
All 164 retained legacy flow tests and three facade tests pass, including
explicit dispositions for unsupported legacy fabricated witnesses. Main-session
runtime replay passes for direct authorization and native branded Bytes/Dict
values before a secret leak. The unfiltered integration-10 compiler, CHECK,
agent-protocol, diagnostic and contract gates pass.

Expanded report 08 checks 1,024 inputs and 4,952 property rows: 48 frozen
handlers/214 required bits, 38 unsafe fixtures (33 refused/five unproven), four
contrasts and 734 flow-census cases. No expectation misses, unresolved
operations or source errors remain. Unchanged source graphs preserve all
4,917 comparable outcomes; 35 rows from seven revised recorded source graphs
are classified separately as changed inputs. Their outcomes also remain
identical, without establishing semantic equivalence of the revised sources.
All 101 public counterexample cards match supported raw capsules;
646 diagnostics include cases with no constructive witness. This runner does
not establish runtime validity for every candidate.

CHECK retains exact per-read source/capture owners. The owner approved the
compiler's pure extensionless `.ts` selection while preserving independent
flow/fault traversals, explicit reader paths/order, revision selection and
type-failure stopping. Merged multi-module contracts continue to omit flow
claims; the unused compiled-graph adapter is removed.

A complete 13-case DeepSeek re-record reached green and passed declared
runtime intent in every case, with 11 first-attempt passes. Original
generations remain byte-identical. The owner approved truthful zero registry
coverage for this draw. The implemented checks calibrate the actual collector
through all three diagnostic paths against all 59 registry rules and a
negative transcript, with rejection probes for no-op and false-positive
collectors. Exact 13-case execution, artifact and model floors accompany an
explicit measured-zero baseline and both off-registry diagnostics. The native
marker, publisher and union suites pass their unfiltered targeted checks;
generated prose no longer claims this zero-hit draw exercises a registry rule.
The main-session publication-mode aggregate passes with direct exit status 0,
including all 13 offline replays and their intent checks. Ordinary full
verification and canonical publication follow this source checkpoint; their
results are recorded in the generated-evidence commits.

The final aggregate, full sequential verifier and canonical convergence,
coverage and provenance publication still govern P9 completion. No release
acceptance is claimed before those gates finish.

# Flow checker redesign: an over-approximating abstract interpreter

Status: draft, revised after one validation round (Codex astra facts and soundness), 2026-10-18. Owner chose Decision 8 Option A:
document the known false proofs (commit `82832b27`) and plan a redesign.
Implementation needs separate owner approval.

Evidence: [the superseded guard plan](2026-10-18-callback-iteration-writes-plan.md)
records every observed false proof (F1 to F6) and the three validation rounds.
Probes are in `/tmp/zttp-probe/` and `/tmp/zttp-probe2/`; P0 moves them into
the repository.

## Goal and soundness claim

For every handler the analyzer accepts, and every concrete run of it, if a
value carrying label L reaches a sink that L forbids, the analyzer reports it
or leaves the matching property unproven. The scope of "carrying" is explicit
data flow: a value computed from, stored with, or copied from a labelled
value. Implicit flow (a branch chosen by a secret) is out of scope; see D9.

The claim holds when every construct the parser admits has a transfer function
that over-approximates its concrete effect on the abstract state below. The
"Construct table" names that function for each construct. A construct with no
row clears every flow property.

## Facts that shape the design

From the three code maps of 2026-10-18 (citations are to
`packages/zts/src/flow_checker.zig` at `82832b27` unless named):

- The parser refuses `while`, `do`, C-style `for`, `for-in`, `switch`, `try`,
  `throw`, and destructuring (`parser/parse.zig` 1932-1959, 2052, 3922, 3973).
  The only loop is `for...of`.
- Today two walkers share the work: `inferLabels` computes labels and enters
  callee bodies; `scanExprSinks` finds sinks and does not enter callee bodies.
  Conditions, assertion expressions, and several other positions get only the
  second. This split is the cause of the condition-call hole.
- `walkStmt` walks `if` branches in sequence with shared state, and walks a
  `for...of` body once. Simple assignment replaces labels.
- Walk state is not reset between walks; `binding_value_nodes` appends on every
  re-walk; parameter labels are not restored after a frame.
- Request identity (`request_carriers`) is lost through ternary, match,
  containers, and returns. Callables chosen by an expression are not resolved.
- Multi-module builds skip flow analysis (`packages/tools/src/precompile.zig`
  `buildMultiModuleContract`, `initContractOnly` without `select_flow`).
- The acceptance kernel does not re-check `no_secret_leakage`; it trusts the
  producer (`packages/proof-checker/src/proof_system.zig` 92-110).
- Persistent-state readers without `.unknown`: `cacheIncr` (observed false
  proof, listed in the known-limits table), `cacheStats`, `cacheDelete`,
  `rateReset`, `sqlExec` (binding metadata only; some return counters or key
  presence, not stored payloads). `fetchWithRetry` is not an egress sink
  (inferred from the code). P1 probes each.
- A failed `assert cond, msg` returns `msg` as a 200 response body
  (`parser/codegen.zig` 1970, `runtime/src/handler_instance.zig` 1668); observed
  leaking a secret on 2026-10-18.
- Headers passed to a response helper do not reach the client: a secret in
  `Response.text("ok", { headers: ... })` was not sent (observed 2026-10-18).
  Other response header paths exist in the runtime (`handler_instance.zig`
  1705, 1740); P1 checks whether a handler can reach them.
- A module-level container written with request data fails at runtime with
  `error.ArenaObjectEscape` (observed 2026-10-18), so request data does not
  persist across requests through it. Values that are not arena objects (for
  example an `env` string) are not covered by that observation.
- `LabelSet` is 16 bits: ten named fields and six reserved bits.
- Match patterns bind fields of the discriminant, although declaration and
  parameter destructuring are refused.
- Today parameter labels are not restored after a frame; value nodes and
  carriers are.
- The current rule (`flow_checker.zig` 65) requires a `flow_analyzer_version`
  bump for every change of sinks, labels, or binding verdicts.

## Abstract domain

An abstract value `V` has four parts:

- `labels: LabelSet`, ordered so that every taint bit ascends and `validated`
  descends. Join is `mergeConditional`. `mergeValues` combines operands of one
  expression; it is monotone in that order.
- `carrier: {request, headers}` subset: which request objects the value may be.
- `origins`: a set of allocation sites (array and object literal nodes, and
  one site per call that returns a fresh container) plus `top`. `top` means
  "any container the analysis cannot name".
- `callables`: a set of closures plus `top`. A closure is a function node
  (local, nested, or imported export) and the environment locations it
  captures. Two instances of one function with different captures are
  different closures, or one closure whose captured locations are joined.

Containers hold full values: a heap cell is a `V`, so a request, a closure, or
a nested container stored in an array keeps its carrier, callables, and
origins. A spread copies the source cells' values into the new site. A sink
check on a container value inspects every cell reachable from its origins.

Captured bindings are locations. A binding that a closure captures and that
the program reassigns is a heap location: updates to it are weak unless the
analysis shows one activation, and a read through the closure joins it.

The abstract state `S` has three parts:

- `env`: binding key to `V`. Updates to a binding are strong (bindings are not
  aliased in this dialect: no destructuring, no `arguments`, no references).
- `heap`: allocation site to `V` (the join of everything stored in it). Updates
  are weak (join), because one site stands for every object it creates.
  The `top` cell holds every write whose target origin includes `top`; a read
  from any container joins the `top` cell.
- `completions`: for each way a path can end (fallthrough, `return`, a failed
  `assert`, a native exception from a builtin), the join of the value and the
  full state at that point. A path that returns keeps its heap writes; the
  caller joins every completion's state, not only the fallthrough state.
  A failed `assert` at the handler root is a response completion whose value
  is the message.

Unreachable state is a separate bottom element. The label bottom used for
accumulation has `validated` set (so a join with it changes nothing); a clean
literal does not. Joins accumulate fixpoints; `mergeValues` combines operands
inside one expression only.

Module-level containers persist between invocations of the handler in one
runtime. The handler's entry state therefore joins, for every module-level
site, its initializer and every write to it from any reachable function: an
outer fixpoint over invocations.

Termination: every part is a finite lattice of bounded height (16 label bits,
2 carrier bits, finite sites and functions per program, finite bindings), and
every transfer function is monotone, so each fixpoint below ends. The pass
bound stays (`max_fixpoint_passes`); on exhaustion the analysis clears every
flow property, as now.

## Construct table

One evaluator, `eval(expr, S) -> (V, S)`, replaces the pair `inferLabels` and
`scanExprSinks`. It checks sinks at the call that is the sink, records writes
where they occur, and enters callee bodies, in every position. `exec(stmt, S)`
replaces `walkStmt`.

| Construct | Transfer function |
|---|---|
| literal | empty labels, no carrier, no origin |
| array or object literal | the site `s` of this literal node; `heap[s] = join(heap[s], elements, properties, spread copies)` (never a reset, because one site stands for every evaluation, in loops and recursion too); value has origin `{s}` |
| identifier | `env[key]`; an unrecorded global or capture: `unknown` |
| member, computed, optional read | the object's labels joined with the full `V` of `heap[o]` for every origin `o`; a read through `top` joins every cell that may alias (every site whose value escaped to an unknown place) and the `top` cell; `headers` of a request carrier gives a headers carrier; `authorization` of a headers carrier adds `credential` |
| binary and unary operators | `mergeValues` of the operand labels |
| `&&`, `||`, `??` | left evaluated; right evaluated in a copy of the state; the result state is the join of the state after the left alone and after both; the value is the join of both operands |
| ternary, match | condition evaluated for its effects and sinks; each arm evaluated in a copy of `S`; the result value and state are the joins; match pattern field bindings get the full `V` of the matched field (the discriminant's cells) |
| assignment to a binding | strong update of `env`, or a weak update when the binding is a captured location |
| compound assignment (if the IR can hold one) | read the target, `mergeValues` with the value, write the target |
| assignment to a member or element | for each origin `o` of the target object: `heap[o] = join(heap[o], value)`; `top` origin writes the `top` cell; computed key labels join into the written value |
| `push`, `unshift`, `splice`, `pop`, `shift`, and the other mutating names | arguments written into the receiver's cells as member writes; `pop` and `shift` return the full `V` of the receiver's cells (carriers, callables, origins); `splice` returns a fresh site holding those values |
| call of a local function | inline the body with parameters bound, and restore the caller's bindings afterwards (labels too, which today are not restored); the caller's state is the join of the callee's completion states; the value is the join of its return values; recursion and cycles through callbacks share one bounded worklist |
| call of a callable set | join over every member; `top` member: unresolved (clear every flow property) |
| call of an imported export with a summary | apply the summary, including its parameter heap writes and return aliasing (P8) |
| array method with a callback | a loop: `S_head = join(S_in, S_after_callback)` until stable; element parameter = join of the receiver's cells; index parameter = clean; array parameter = the receiver value; `reduce` accumulator = join of the initial value and earlier results; the method's result follows its own rule (map: results; filter, find, toSorted, slice: receiver cells) |
| module export with a callback | the same loop; every callback parameter = join of the non-callback arguments, their cells, and earlier results |
| Result method with a callback, including `match` with an object of callbacks | the same loop over the callbacks found in the argument, direct, named, or in an object literal |
| virtual module call without a callback | the binding's declared labels, `derives_from_args`, declassification, as now; persistent-state readers carry `unknown` |
| `if` | condition evaluated; then and else executed in copies of `S`; the fallthrough state is the join of the branches that fall through; a branch that ends adds its state to `completions` |
| `for...of` | iterable evaluated; loop variable = join of the iterable's cells; `S_head = join(S_in, S_after_body)` until stable |
| `return` | `returned = join(returned, value)`; the path ends; at the handler root, the response sink is checked on the value |
| `assert` | condition evaluated; the message evaluated in a copy of the state; a failed assert with a message is a `return` of the message from the containing function (in a helper, the caller receives it; at the handler root, the response sink checks it); an assert without a message is a halt completion |
| string methods (`split`, `slice`, `substring`, `trim`, `replace`, and the rest of `isStringMethod`) | result labels are the receiver's and the arguments' labels; `split` returns a fresh site holding them |
| Result constructors, combinators, and extractors (the free functions in `zttp:result` and the Result methods) | a Result value is a container whose cells hold the `ok` and `err` payloads; combinators keep the untouched payload (`mapResult(err(secret), f)` keeps the secret) and run callbacks as below |
| `Array.from(source, f)` | elements from the source's cells, or, for a string source, characters carrying the string's labels; `f` as an array-method callback with that element value |
| var declaration | strong update of `env` with the initializer value |
| function declaration or expression | a callable value; its body runs only when called |
| any other tag | clear every flow property |

The `exec` and `eval` arms use exhaustive `switch` statements on the IR tag
with no `else` arm, so a new tag fails to compile until it has a row.

Sinks are unchanged in meaning (the table in `checkSinkLabels`), with these
additions: `fetchWithRetry` is an egress sink; `Response.rawJson` gets the
same HTML and label checks as the other helpers (today it gets only the
generic label check); a failed `assert` at the handler root is a response.
Helper headers stay out of scope because they do not reach the client
(observed); any other response header path P1 finds becomes a sink.

Virtual module summaries. Every export that takes a callback, stores a value,
or returns a value derived from stored state states it in its binding: whether
it invokes or retains a callback, which arguments it stores, and which return
value can alias an argument or stored state. `routerMatch`, which returns a
wrapper around a route handler, is the first case. An export without that
metadata that receives a callback or container is treated as retaining it:
its later reads carry `unknown`, and an unknown callback is unresolved.

## Implementation strategy

D10 below decides between a rewrite in place and a new file. The plan assumes
the recommendation: a new file `packages/zts/src/flow_interp.zig` beside the
current checker, with the same output types (`FlowProperties`, diagnostics,
defended paths, witnesses), switched in only when it passes the differential
gate in P9.

## Phases

Each phase is one or more commits with its own tests. Following the rule at
`flow_checker.zig` 65, every phase that changes a verdict raises
`flow_analyzer_version` and re-pins the policy hash. The DeepSeek re-record
and the evidence republish run before each release, not after each phase.

P0 (semantic fixtures). Add every observed false-proof shape (F1 to F6 of the
superseded plan, plus the `assert` message) as a permanent fixture, as Zig
tests beside the checker following the existing flow-test helpers. Each
fixture states its semantic expectation: the property is refused or
unproven. A second, separate table records which fixtures the current
checker still proves falsely; a test asserts that table exactly, so it can
only shrink and an improvement updates it in the same commit. A fixture leaves
that table when its expectation holds, and it is never deleted. Each fixture
names the runtime observation (`zttp serve` and request) in a comment where
one was made. The fixtures run through both the direct helpers and the typed
pipeline, because the direct helpers have no type checker.

P1 (binding and sink fixes, independent of the redesign). Probe, then fix:
`.unknown` on persistent-state readers that lack it; `fetchWithRetry` as an
egress sink; `rawJson` response check; a probe that shows whether response
headers reach the client. Follow AGENTS.md: assert `no_secret_leakage` in the
round-trip test, not `deterministic`.

P2 (abstract domain and evaluator core). `V`, `S`, join, the evaluator for
expressions without calls, and `exec` for blocks, declarations, assignment,
`if`, and `return`. Unit tests per transfer function.

P3 (loops). `for...of` fixpoint.

P4 (calls). Local functions, recursion fixpoint, callable sets, unresolved
calls, route dispatch, captures.

P5 (heap). Allocation sites, member reads and writes, mutating methods.

P6 (callbacks). Array methods, module exports, Result methods, the reduce
accumulator.

P7 (request identity and sinks). Carriers in `V`, all sinks, HTML facts,
defended paths, witnesses, `recordContainedSecrets`.

P8 (imported summaries and multi-module builds). Summaries carry parameter
heap writes, return aliasing, and carriers. Decide with a probe what a
multi-module build claims today, and make it run the interpreter or claim no
flow property.

P9 (switch). The switch criterion is the semantic expectations, not
agreement with the old checker: every P0 fixture meets its expectation, every
construct-table row has its over-approximation test, the census and corpus
results match their stated expectations, and refused versus unproven is
distinguished. Agreement with the old checker is regression evidence only:
run both over the flow census, the diagnostic corpus, `test-examples`, and the
codegen corpus handlers, and classify every difference against the
expectations. A case the new checker proves and the old one refused may be a
legitimate improvement (for example explicit-flow policy, D9) or a defect;
each needs a written reason. A case the new checker refuses and the old one
proved is a P0 shape or an over-refusal reported to the owner. Then switch the
pipeline, raise `flow_analyzer_version`, re-pin the policy hash in the eleven
files, delete the old checker, re-record the corpus with DeepSeek, republish
convergence and coverage, and run `release-provenance` and `verify.sh`.

## Validation of the claim

- Every construct table row has a unit test that shows the over-approximation
  on a concrete case and a contrast that still proves.
- The P0 fixtures become refusal tests after P9.
- A new census over the IR tag enum asserts that every tag has an `exec` or
  `eval` arm that is not "clear every flow property", or an allowlist row with
  the reason. A second census iterates the builtin and virtual-module
  operations (string methods, array methods, Result functions, module
  exports) and requires a transfer rule or binding metadata for each. Both
  are new; the existing flow census generates source probes and stays.
- Sabotage: for each phase, revert its core transfer function and show its
  tests fail.

## Decisions for the owner

D9 (implicit flow). Option A (recommended): explicit flow only, documented in
`docs/proofs-and-receipts.md`. A branch chosen by a secret does not count as a
leak. Option B: track a control label and join it into every sink under a
branch; this refuses every handler that compares a token, which includes most
authentication handlers.

D10 (where the interpreter lives). Option A (recommended): a new file beside
the current checker with a differential gate before the switch. Option B:
rewrite `flow_checker.zig` in place; less duplicated code, no differential
baseline.

D11 (release while the redesign is in progress). Option A (recommended): P1
ships in the next patch release with the known-limits section; the redesign
ships when P9 passes. Option B: no release until P9.

## Risks

- Over-refusal from weak heap updates and callback loops. P9 measures it on
  the corpus and the census before the switch.
- Size: the current checker has 5090 lines before its tests (3623 after
  blank and comment lines). The interpreter replaces most of it.
- Each validation round so far found holes the previous design did not
  cover. The construct table and the two operation censuses are the defence;
  any new hole found during implementation becomes a P0 fixture first.
- Witness and counterexample output (`counterexample.solve`) depends on the
  walk order and the constraint stack. P7 must keep the witness format, and
  the contract goldens show any change.

## Owner decisions, 2026-10-19

The owner answered "as recommended": D9 Option A (explicit flow only), D10
Option A (new `flow_interp.zig` with a differential baseline), D11 Option A
(P1 in the next patch release; the redesign when P9 passes), D12 Option A (a
second validation round before implementation approval).

## Round 2 revisions, 2026-10-19

The second round (two Codex astra reviews; Fable was out of credits) found
gaps in the argument. Five of its examples leaked under `zttp serve` on
2026-10-19 and are now in the known-limits table (`e1b01ef3`):
`unescapeHtml(escapeHtml(req.url))`, `Array.from(secret, f)`,
`[req].pop()` before reading `authorization`, a failed `assert` in a helper,
and `Response.json(req.headers)`. These sections override earlier text where
they differ.

R1 (operational claim). PROVEN(P) implies that no reachable execution
produces a forbidden explicit-flow event for P. An event is a value carrying a
label that P forbids arriving at a sink that P names. "Carrying" includes
every value computed from a labelled value: a computed key
(`["a", "b"][secret.length % 2]`), a comparison result, a length. One
property-to-sink matrix, generated from the checker's own table, is the
single source; `docs/proofs-and-receipts.md` is rendered from it and states
that control and termination channels are excluded (D9). The current docs say
`injection_safe` covers SQL and HTML sinks, while the checker covers HTML and
egress; the matrix resolves that difference before P9.

R2 (defenses separate from provenance). `validated` is replaced by
sink-specific defense facts (for example `html_escaped`, `schema_checked`)
that sit beside the provenance labels instead of clearing them. Each
operation states whether it preserves, establishes, or removes each defense.
`unescapeHtml` removes `html_escaped`; `replace`, `replaceAll`, and any
operation that can reintroduce markup characters remove it unless the rule
proves otherwise; `escapeHtml` establishes it. The sink checks provenance and
the defense together.

R3 (operation-edge matrix). The operation census covers every runtime
registration (array, string, JSON, Object, Number, Math, Date, Error, global
functions, Result runtime methods) and every virtual-module export, and marks
which ones the typed profile admits. For each admitted operation it states,
per argument and callback position: what is read, what is written, what is
allocated, what is returned (full `V`), and the callback parameter vector
(for example `toSorted` passes two elements; `reduce` without an initial value
starts with a receiver element). An operation with no row clears every flow
property. Heap-to-scalar operations (`JSON.stringify`, `join`, `Object.keys`
and the like) read every reachable cell. Sabotage removes one edge at a time
and requires a test to fail.

R4 (request and headers contents). A request and its `headers` are synthetic
containers with labelled cells (`authorization` carries `credential`; every
header and field carries `user_input`). Serialization, enumeration, and
dynamic reads go through those cells.

R5 (module metadata). Bindings that exempt computed facts from
`derives_from_args` (`timingSafeEqual`, `verifyWebhookSignature`,
`bytesLength`, `dictHas`, and `nanoid`'s length argument) get dependency
summaries under R1, or a policy exception listed in the matrix. `rateCheck`
and `schemaDrop` are classified against stored state.

R6 (finite abstract locations). Capture locations, allocation sites, and
call contexts are bounded: a location is a static site plus a bounded
context. Completion slots hold `env x heap` snapshots, not full states, so
the state is not recursive. Captured locations survive calls; only callee
frame bindings are restored. With weak updates and joins, every fixpoint
ascends a finite lattice. The pass cap remains a fail-closed exit, not the
termination argument.

R7 (persistence by reachability). The outer fixpoint over handler
invocations starts from module bindings and follows every reachable location,
object, and closure, wherever it was allocated. Persistent scalars count:
the arena-escape check rejects arena pointers only, so request-derived numbers
and booleans can persist. Request-local state is reset between iterations.

R8 (fixtures that cannot be weakened). Each P0 fixture's expectation is fixed
in the fixture itself, independent of the table of current false proofs; a
change to an expectation needs a reason in the commit. The expectation is
"the property is not proven"; refused or unproven are both accepted unless the
fixture names a diagnostic.

R9 (no production change before P9). P2 to P8 run in shadow only. P8 may
remove unsupported claims from multi-module builds; it may not select the new
interpreter. P1 may only keep or remove proofs; any proof that P1 adds needs
an explicit review.

R10 (policy-hash pins). The pin destinations are the files that the
regeneration and drift checks enforce (nine tracked files hold the current
hash), not a fixed list of eleven.

## Round 3 revisions, 2026-10-19

The third round (Codex astra, P2 to P9 only) found no new construct whose
rule misses explicit flow. It found policy and precision gaps. These sections
override earlier text where they differ.

R11 (declassification is a stated policy). `mask(secret, 4)` sends four bytes
of the secret, which R1 counts as carrying it. Declassification stays only as
an explicit, bounded exception in the property-to-sink matrix: which export,
which labels it removes, the bound on what it discloses, and the literal-bound
condition that exists today. D14 decides whether `mask` keeps that exception.

R12 (defenses are per sink). The matrix states, for each property and each
sink, which defense the sink requires. Passing a validator is not a sink
defense by itself: `schema_checked` does not make a string safe as a URL, a
header, or HTML. `Response.json` and `rawJson` do not remove secret or
credential provenance, and neither is HTML escaping. Where no defense exists
for a sink (for example a request-chosen egress URL), `injection_safe` is not
proven for that flow.

R13 (defense lattice). A defense holds for a value only if it holds for every
alternative at a join and every contributor in a combination. Bottom
(unreachable) holds every defense; a clean literal holds a defense only if the
sink's rule says literals are safe. Structural validation evidence (for
example from `validateObject`, which returns the same object) is bound to the
validated heap cells and is removed by any possible write to them, including
writes through `top`. Paired tests cover an unchanged and a mutated validated
object.

R14 (field-sensitive cells). Each allocation site has one cell per known
property name plus one summary cell for unknown names. A static read
(`headers.accept`) reads its own cell and the summary cell; a dynamic read,
serialization, or enumeration reads every cell. R4's request and headers
containers use the same cells, so `accept` does not take `authorization`'s
credential label. Locations reachable from module roots persist (R7); only
locations shown to be request-local reset.

R15 (phase dependencies). New order: P2 builds the location scheme, cells,
and the evaluator core with heap reads and writes; P3 loops; P4 calls,
captures, and recursion; P5 operation-edge rules (R3) and callbacks; P6
defenses (R2, R12, R13); P7 request contents and sinks (R4); P8 persistence
(R7) and imported summaries; P9 switch. Each phase states the conservative
behavior of every operation that a later phase owns (clear every flow
property), and has direct abstract-state tests before P7 adds sinks.

R16 (precision is part of the switch). Before P2 starts, freeze a set of
representative handlers (the examples, the codegen corpus handlers, and
handwritten authenticated handlers) with the properties each must prove.
P9 requires those expectations, the R3 edge tests, the defense transition
tests, and the persistence tests. Every difference from the old checker,
including a newly unproven property, needs a written disposition before the
switch.

## Decision for the owner: D14 (mask)

Option A (recommended): keep `mask` as the only declassification exception,
bounded to a literal count, listed in the matrix and documented as disclosing
up to that many bytes. Option B: remove the exception; `mask` keeps the
labels, so a masked secret in a response or log is refused.

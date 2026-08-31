---
name: zttp
last_updated: 2026-08-31
---

# zttp Strategy

Why this product exists, who it serves, and how we know it is working. What is
built, what is planned, and what is refused as a feature decision live in
[docs/roadmap.md](docs/roadmap.md); release history lives in
[CHANGELOG.md](CHANGELOG.md).

## The category

zttp is an agent-compiler. That is one system with four parts engineered against
each other: a restricted language with bounded static analyses, an AI coding agent
whose goal and feedback use the proof vocabulary, a consumer-owned artifact checker,
and a runtime that activates only accepted artifacts. The defining property is
convergence: the set of programs the agent can write approaches the set of programs
the compiler can prove. The agent authors inside a compiler fence. Deployment adds a
second boundary: an independent checker decides which compiler claims meet consumer
policy before the runtime may use them.

The term never travels without that definition. On its own, "agent-compiler" misreads
as "a compiler for agents", which is the opposite of the claim.

## Target problem

AI agents now write a large share of the code that ships. The tools that check that
code have not changed. A linter gives advice about an unbounded language; the model
routes around it, and "no findings" proves nothing. A test suite covers the paths a
person thought to write. So a solo developer ships a handler they did not write,
checked by tools that cannot vouch for it. "It worked when I tried it" is the whole
guarantee. A real proof normally costs more than writing the code by hand, so nobody
buys one.

The deeper problem is architectural. Every current tool bolts an agent onto a checker,
or a checker onto an agent. In the first shape the checker is heuristic and post-hoc.
In the second, the compiler is a passive oracle that returns error strings into an
unbounded search. In both shapes the agent can emit programs the checker cannot judge,
because the language admits them. The failure is not in the model and not in the
checker. It is in the boundary between them.

## Our approach

We do not bolt an agent onto a compiler. We engineer the language, compiler, agent,
artifact checker, and runtime against the same closed identities and property
vocabulary.

The language is restricted on purpose. zts removes the constructs that make analysis
undecidable: classes, async, try/catch, regex, `==`, `while`, `this`, `new`. Each
removal buys a proof. `null` is not one of them: it is admitted as explicit data and
permitted only where the declared type names it, held apart from the `undefined`
absence sentinel so neither can stand in for the other. The analyzer walks every path
of every handler and terminates in milliseconds. "No findings" is a theorem over the
whole handler, not a sample of it.

The agent lives inside the fence. The model in `zttp expert` has exactly one write
path, and the compiler sits on it. Every draft is simulated before it touches disk. A
draft that adds violations is vetoed. On a veto, the compiler first tries to save the
draft itself: it canonicalizes the source and re-simulates. If that fails, it composes
a typed repair plan and applies it with no model call; the session records that edit as
compiler-authored. For five safety properties the loop runs with no model at all: the
compiler plans, applies, verifies, and rolls back on regression. The compiler does not
check the agent's work after the fact. It co-authors the work.

Feedback is typed data, not prose. A failed proof names the property and carries a
specific remedy. A failed property produces a concrete counterexample: a real request
plus I/O stubs, stored in the same trace format the runtime records, so the witness
replays against the production engine with no translation. Goal, feedback, repair, and
reward all speak the proof system's vocabulary.

The design property this converges on: the set of programs the agent can write
approaches the set of programs the compiler can prove. One direction holds today by
construction, because the agent cannot land a draft the compiler rejects. The other
direction, that the agent can reach everything the compiler can prove, is open. We
measure the gap. We do not claim it is closed.

## Who it's for

**Primary:** the solo developer or indie builder who ships serverless or edge
functions with no PM, no QA, and no SRE. They already let an AI write the handler.
What they cannot get anywhere else is a machine that vouches for the result. They hire
zttp for the fence, not for a runtime with an agent attached. The surface they touch
is `zttp expert`; the thing they buy is the boundary around it. They do not become a
verification expert, and the verdict arrives in milliseconds rather than through a
review process they do not have.

**Secondary, deferred:** the platform owner who must vouch that a deploy is safe on
someone else's behalf. The trust artifacts that persona needs (signed proof receipts,
`verify <url>`, `/.well-known/zttp-attest`) ship and are on by default, but we do not
design for that persona yet.

## State of the evidence

A strategy that sells verdicts must grade itself the same way.

What holds today, by construction: the single fenced write path; the veto with
canonicalize-and-salvage; the model-free repair lane; the autoloop with rollback on
regression; replayable counterexamples; and registry hashes that bind every agent
response to the exact rule, idiom, and restriction set in force. Deployed artifacts
carry a closed certificate over the complete executable graph. A leaf checker
reconstructs obligations, validates bounded evidence, and promotes only properties
that meet consumer policy before pool initialization. The wire protocol's
proof operations (`verify` and `simulate_edit`) ship, so an outside client completes a
propose, simulate, verify cycle with no in-process access. PI's aggregate change-set
transaction is the only source-write authority: it proves the simultaneous overlay,
checks the complete proof read set, and records one crash-consistent receipt. Capability
ceilings are declared per export rather than per module. First-draft pass, median
round-trips, and intent pass are published per row and dated in
[docs/convergence.md](docs/convergence.md), each carrying the corpus version and policy
hash it was measured under, and `zttp ledger stats` aggregates the same metrics per
workspace.

What is thin: six of the validator registry's fifteen repair intents grade as mechanical
repairs, so most rewrites still ship as proposed refactors an outside client must judge
for itself. The canonical formatter refuses JSX and TSX, five of the 58 corpus files, and
a refused file keeps the layout its author wrote. The convergence corpus is 19 cases and
the latest recording trips 3 of the compiler's 59 advertised rules. Across recordings
of the same corpus it has ever tripped 6. The deterministic defect-seed suite verifies
58 of 59 rules independently of model behavior, so those figures must remain separate.

What is unmeasured: provable-set reach, the convergence metric itself. Given a reference
suite of programs the compiler certifies green, the fraction the agent reproduces to
green inside a fixed budget is one hundred percent minus the convergence gap, and nothing
computes it today. The eval corpus is recorded once and replayed, so it cannot be tuned
against without leaking the benchmark, and growing it is the binding constraint on every
number this section cites.

Counts behind each of these live in
[the closed agenda](docs/archive/plans/2026-08-16-028-agent-compiler-agenda-closed.md)
and in what [the roadmap](docs/roadmap.md#agent-compiler-agenda) still carries open,
each beside the file that owns it, so a reader can recount rather than trust a number
that rots here.

## Key metrics

Stated in three tiers, so a reader knows which numbers exist today.

**Measurable now.**

- **First-draft-correct rate** - share of agent drafts that clear the veto with no
  retry. This is the most direct reading of convergence: how often the raw emission is
  already inside the provable set. Published with its caveats, never bare.
- **Compiler-authored apply ratio** - share of applied edits the compiler authored with
  zero model calls. The counter already exists in the session summary and needs
  aggregation, not new plumbing. This is the primary symbiosis health number: it rises
  as the compiler takes over authorship.
- **Repair totality** - how many diagnostic rules carry a typed repair, and how many of
  those intents lower to an executable edit. The compiler-side convergence proxy, and
  countable today.
- **Round-trips to first green proof** - median model round-trips to a fully proven
  handler. `zttp ledger stats` aggregates it per workspace, and each convergence row
  publishes the corpus median.
- **Proven-path ratio** - fraction of a shipped handler's response paths covered by a
  proof rather than `unproven`. `ledger stats` reports the median. It never stands
  alone: a handler that returns 501 on every path is fully green, so this pairs with a
  functional acceptance check.

**Needs a measurement home.**

- **Provable-set reach** - the convergence metric. Given a reference suite of programs
  the compiler certifies green, each with a task spec, the fraction the agent
  reproduces to green inside a fixed budget. One hundred percent minus this is the
  convergence gap. Nothing measures it today.
- **Fence-breach rate** - share of agent-applied edits that re-verify with zero *total*
  violations, not only zero new ones. By construction this sits near one. Any deviation
  is a soundness incident, not a quality dip.

**Guardrails.**

- **Cold-start p50** - a performance floor, never a headline; lives in `zttp-bench`.
- **Verifier soundness** - adversarial and known-unsafe corpora stay red across
  releases. A taint fail-open once survived fourteen review passes, which is why this
  is a standing process metric rather than a fixed defect.

## Tracks

Four tracks carry the thesis. The fifth carries what the thesis produces.

### 1. Fence soundness and precision

Per-export capability rows, fail-closed effect ceilings, an adversarial soundness
corpus, wider counterexample and witness coverage.

_Why it serves the approach:_ the fence is only worth living inside if it is sound and
tight. A false green poisons today's verdict, and it would poison any future training
label built on the same signal.

### 2. Evidence and measurement

The measurement home: held-out task families with executable acceptance tests, a
published first-draft-correct number carrying its caveats, ledger aggregation, and the
convergence-gap harness.

_Why it serves the approach:_ the product sells verdicts over vibes. A strategy that
cannot grade itself to the same standard is a vibe.

### 3. Authoring, not judging

Move the compiler from judging output to constructing the frame the agent fills: typed
holes, richer typed feedback, per-hole authoring in place of whole-file regeneration.

_Why it serves the approach:_ every other track improves how well convergence is
measured or enforced. This one changes the mechanism. When the compiler supplies the
shape, the agent's emittable set per step collapses to one typed expression in a known
context, and convergence stops being statistical.

### 4. Repair totality

Grow the executable repair set toward a total classification: every rule either carries
a deterministic repair or is explicitly marked judgment-required.

_Why it serves the approach:_ each mechanical repair moves authorship from the model to
the compiler and pulls a rejected program into the provable set with no model tokens.

### 5. Proof carrier (supporting)

Runtime and deploy footprint: witness replay fidelity, independent certificate
acceptance, attestation on by default, small self-contained artifacts, and the
cold-start floor.

_Why it serves the approach:_ a proof needs a place to be true and a way to travel. The
consumer checker keeps producer verdicts from becoming runtime authority by
serialization alone. The runtime can still falsify the compiler, because witnesses
replay against the real engine in the format the compiler wrote them. Work lands in
this track when it serves replay, artifact acceptance, attestation, or carrying proven
handlers. Feature parity with general-purpose runtimes is refused.

## Not working on

- **Full Node/V8 language fidelity** - the permanent non-goal; it is what makes these
  proofs intractable everywhere else.
- **Any unproven escape hatch.** No mode ships unrestricted code behind a warning
  label. Veto exhaustion ends the turn; it never ships the draft. The moment an
  unproven path is convenient, the category claim is gone.
- **Re-admitting restricted constructs under adoption pressure.** Each restriction maps
  to a proof it unlocks, so re-admitting a construct un-ships proofs. The restrictions
  are the product, not a limitation to grow out of.
- **A general-purpose coding agent.** `zttp expert` does not compete on breadth. It
  wins inside the fence, and only there.
- **Learned checkers in the verdict path.** No model-as-judge ever gates a ship. The
  verdict stays deterministic and total.
- **Publishing unmeasured or stale numbers.** No number leaves the repo without a
  versioned eval behind it.
- **A local-model training flywheel** - deferred, not refused. The narrow grammar is a
  real reason to think a small model could author inside the fence, but that is a
  hypothesis with no measurement behind it. Track 2 builds the gate that would decide
  it.
- **The team / platform-owner persona as headline** - the trust artifacts they need
  ship and are on by default, but they stay a supporting feature.

## Marketing

**One-liner:** The agent writes only what the compiler can prove.

**Support line:** When the agent fails, the compiler writes the fix itself.

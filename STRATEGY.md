---
name: zttp
last_updated: 2026-08-01
---

# zttp Strategy

Why this product exists, who it serves, and how we know it is working. What is
built, what is planned, and what is refused as a feature decision live in
[docs/roadmap.md](docs/roadmap.md); release history lives in
[CHANGELOG.md](CHANGELOG.md).

## The category

zttp is an agent-compiler. That is one system with three parts engineered against
each other: a restricted language whose safety and correctness properties are
decidable, a proof engine that is total over that language, and an AI coding agent
whose goal, feedback, repair, and reward are all expressed in the proof system's
vocabulary. The defining property is convergence: the set of programs the agent can
write approaches the set of programs the compiler can prove. The agent does not write
code and then check it. It authors inside a fence, and the fence is load-bearing for
everything else. The runtime exists to carry what the compiler proves: it replays the
compiler's counterexamples, runs the proven handler, and ships it as one attested
binary.

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

We do not bolt an agent onto a compiler. We engineer three artifacts against each
other: a restricted language, a proof engine that is total over it, and an agent that
can only author inside the proof boundary.

The language is restricted on purpose. zts removes the constructs that make analysis
undecidable: classes, async, try/catch, regex, `==`, `null`, `while`, `this`, `new`.
Each removal buys a proof. The analyzer walks every path of every handler and
terminates in milliseconds. "No findings" is a theorem over the whole handler, not a
sample of it.

The agent lives inside the fence. The model in `zttp expert` has exactly one write
path, and the compiler sits on it. Every draft is simulated before it touches disk. A
draft that adds violations is vetoed. On a veto, the compiler first tries to save the
draft itself: it canonicalizes the source and re-simulates. If that fails, it composes
a typed repair plan and applies it with no model call; the session records that edit as
compiler-authored. For three safety properties the loop runs with no model at all: the
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
response to the exact rule, idiom, and restriction set in force.

What is thin: the stable wire protocol is missing its three agent verbs, so an outside
client can ask what is wrong but cannot ask the compiler to simulate, repair, or
verify. On that wire every rewrite is graded a proposed refactor and none is a
mechanical repair. Mechanical repair exists only inside the agent package, and only a
minority of the typed repair intents lower to a real source edit. No canonical
formatter exists, so every rewrite splices byte spans. Capability ceilings are declared
per module rather than per export, so every ceiling is coarser than the code it
describes.

What is unmeasured: the headline metrics have no honest denominator yet. The session
ledger is local, per-workspace, and empty by default. The one agent number we ever
published is stale. The current eval corpus checks compiler compliance, not intent, and
it is recorded once and replayed, so it cannot be tuned against without leaking the
benchmark. Fixing the scoreboard is a track, not a footnote.

Counts behind each of these live in
[the agent-compiler agenda](docs/roadmap.md#agent-compiler-agenda), each beside the
file that owns it, so a reader can recount rather than trust a number that rots here.

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

**Needs a measurement home.**

- **Provable-set reach** - the convergence metric. Given a reference suite of programs
  the compiler certifies green, each with a task spec, the fraction the agent
  reproduces to green inside a fixed budget. One hundred percent minus this is the
  convergence gap. Nothing measures it today.
- **Fence-breach rate** - share of agent-applied edits that re-verify with zero *total*
  violations, not only zero new ones. By construction this sits near one. Any deviation
  is a soundness incident, not a quality dip.
- **Round-trips to first green proof** - median model round-trips to a fully proven
  handler. Honest only once ledger aggregation exists.
- **Proven-path ratio** - fraction of a shipped handler's response paths covered by a
  proof rather than `unproven`. It never stands alone: a handler that returns 501 on
  every path is fully green, so this pairs with a functional acceptance check.

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

Runtime and deploy footprint: witness replay fidelity, attestation on by default, small
self-contained artifacts, the cold-start floor.

_Why it serves the approach:_ a proof needs a place to be true and a way to travel. The
runtime is the only part of the system that can falsify the compiler, because witnesses
replay against the real engine in the format the compiler wrote them. It is also how a
proven handler ships. Work lands in this track when it serves replay, attestation, or
carrying proven handlers. Feature parity with general-purpose runtimes is refused.

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

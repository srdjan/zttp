# Expert interface options

Status: proposal. No code changes. Prepared 2026-11-14 at commit `939cb2ee`.

## Answer

I recommend Option A, the proof loop in the terminal, as the primary interface.
Option A gives code that is generated, tested, and proven in 3 steps. Today the
same result takes 5 steps. Option A adds no runtime and stays in the single
`zttp` binary.

The product is the proof loop, not the surface. The loop has six interactions
(F1 to F6, below). Four of them work in the terminal. The same interactions
carry over to a later surface.

Pi Durable fits best as the base of a second surface: a local browser studio
(Option B) or background proof jobs (Option D). Pi Durable should sit above the
Zig change-set transaction. It should not replace the Zig expert loop. The
section "Where Pi Durable fits" gives the reasons.

## Evidence

### What zttp has today

These are observations from the code and the docs at `939cb2ee`.

- `zttp expert` is a Zig REPL in `packages/pi`. It has resume, `/fork`,
  `/tree`, `/compact`, a session journal, and change-set receipts.
- On a pass, the developer sees every normalized diff and one aggregate proof
  card, and approves once (`docs/user-guide.md#how-a-turn-runs`).
- The expert has `workspace_gen_tests`, which writes a JSONL suite from proven
  paths. No expert tool runs that suite. Tests run later through `zttp test`.
- `zttp agent --stdin-json` is read-only by design. Source writes belong to the
  aggregate change-set transaction in PI (`docs/internals/agent-protocol-v2.md`).
- `zttp expert --print` runs one message headless. Its approval policy is
  `auto_approve` with `--yes`, otherwise `auto_reject`
  (`packages/pi/src/loop.zig#resolveApprovalFn`). It cannot pause for a
  decision.
- `zttp dev` redraws the proof card on each save.
- `zttp ledger stats` reports the expert success rate and the median round
  trips to a first green proof. This workspace has no session with a summary,
  so no baseline exists yet.

Step count today, from intent to code that is generated, tested, and proven:

| Step | Action |
|---|---|
| 1 | Run `zttp expert` |
| 2 | Type the intent |
| 3 | Approve the change set |
| 4 | Ask for tests, or run `zttp gen-tests` |
| 5 | Run `zttp test` |

The tests do not gate the approval in step 3. I counted these steps from the
docs. Nobody measured them with users.

### What the research found

A research agent surveyed eight families of agent interfaces on 2026-11-14. It
used web search summaries only. Many sources are third-party blogs. The
appendix lists the key sources.

1. No vendor publishes retention data for any family of agent interfaces.
2. No surveyed product shows proof obligations or certificates as a primary
   interface. The closest pattern is the Lean 4 Infoview, which shows the open
   goals at the cursor.
3. Verification tools such as Harmonic Aristotle return output only after an
   independent checker accepts it. The interaction is submit, wait, receive.
4. Agents under a checker weaken the goal to pass. The AxDafny reviewer exists
   to refuse that shortcut.
5. Plan-first tools overload review. Thoughtworks found that Kiro turned one
   small bug fix into 4 user stories and 16 acceptance criteria.
6. Rewind in current tools misses side effects. Claude Code does not track Bash
   changes. Replit does not roll back the database by default.
7. Background agents move the bottleneck to the review queue.
8. App builders get their fast feedback from a live preview. They also report
   bug loops that burn credits.
9. Protocols such as ACP and AG-UI let one agent core serve many editors.
   VS Code has no native ACP support.

A secondary source reports a Stack Overflow 2026 survey result: 48% of
developers trust AI output only when they can verify it. The sources disagree
on other figures from that survey, so treat the survey figures as unconfirmed.

## The proof loop: six interactions

The interactions are ranked by user value and retention impact. Each one names
one retention mechanism.

### F1: Result card with tests in the transaction

**Pain point.** A developer assembles "is this done?" from three outputs: the
diff, the proof card, and a later `zttp test` run. The tests do not gate the
approval.

**Solution.** The host runs the project test suite inside the change-set
transaction, after the proof and before the approval prompt. One card shows the
verdict, the chip delta, the test count, and the diff for each file. The chip
delta compares the chips with the last green checkpoint. For a refactor intent,
the card shows the `zttp prove-behavior` equivalence verdict in place of the
test count. Refused drafts collapse into one attempt line above the card.

- Steps to value: 1.
- Key interaction: one key approves the change set.

**Retention hook.**

- Mechanism: variable reward.
- How it works: the chip delta differs for each change. A newly proven property
  shows green. A lost property shows red, at the top of the card.
- Habit trigger: each intent ends in a card. The developer returns to see what
  the next change proves.

**Cognitive load.**

- Decisions eliminated: which command to run next, whether the tests still
  pass, whether a property regressed.
- Default behavior: approval is offered when the verdict and the tests are
  green. `--yes` keeps its current behavior.
- Visual hierarchy: the verdict line first, then the chip delta, then the test
  count, then the diffs, collapsed.

### F2: Contract card

**Pain point.** The developer finds a wrong direction only after code appears.
Markdown specs overload review (finding 5). An agent can weaken the goal to
pass the checker (finding 4).

**Solution.** Before it writes code, the expert shows a contract card of one
screen at most. The card lists the routes, the required proof chips, the env
and egress rows, and example request and response pairs. The developer accepts
with one key or edits one line. The host then holds the change set to the card.
A missing required chip or an unapproved contract change refuses the change
set. The expert shows the card only when the intent changes the contract.

- Steps to value: 1, and 0 when the contract does not change.
- Key interaction: one key accepts the contract.

**Retention hook.**

- Mechanism: investment.
- How it works: each accepted card adds goals and test rows to the project. The
  next session starts from a stronger contract. The first draft then has more
  constraints to satisfy and fewer ways to go wrong.
- Habit trigger: a request for a new route or a new property.

**Cognitive load.**

- Decisions eliminated: which properties to require, which tests to write. The
  expert proposes both.
- Default behavior: the developer accepts the proposed card as written.
- Visual hierarchy: the required chips first, because the host enforces them.

### F3: Green checkpoints

**Pain point.** A rewind can land in a broken state or miss side effects
(finding 6). A developer who can lose a working state stops experimenting.

**Solution.** Each approved change set is a checkpoint with its receipt. The
timeline lists green checkpoints only, each with its chips. The developer
rewinds source and session to one checkpoint, or forks from it to try another
approach. This feature joins the existing `/fork`, `/tree`, and change-set
receipts in one view. A rewind does not restore SQLite rows, and the timeline
says so.

- Steps to value: 2 (open the timeline, choose a checkpoint).
- Key interaction: choose a checkpoint.

**Retention hook.**

- Mechanism: loss aversion, used to remove a fear and not to trap the user.
- How it works: a proven state cannot be lost, so a new try costs nothing.
- Habit trigger: a failed attempt or a new idea.

**Cognitive load.**

- Decisions eliminated: whether a past state is safe to return to. Every listed
  state is proven.
- Default behavior: a rewind restores source and conversation together.
- Visual hierarchy: the chip set of each checkpoint, because it tells the
  developer what each state proves.

### F4: Request playground

**Pain point.** App builders give a live preview (finding 8). An HTTP handler
has no visual preview, so the developer leaves the expert to run `curl`.

**Solution.** When `zttp dev` runs, the result card sends the contract's
example requests to the dev server and shows each response. The developer can
type a new request. One key saves the request and its response as a test row.

- Steps to value: 1.
- Key interaction: one key saves a request as a test.

**Retention hook.**

- Mechanism: investment.
- How it works: each saved request becomes a regression test that F1 runs on
  every later change.
- Habit trigger: a doubt about the behavior of a route.

**Cognitive load.**

- Decisions eliminated: how to build the request. The contract prefills it.
- Default behavior: the examples run after each approval.
- Visual hierarchy: the status code and the difference from the expected body.

### F5: Durable proof jobs

**Pain point.** A long `--goal` run holds a terminal. A closed laptop or a
crash interrupts it. Whether the Zig session resumes a run that a kill stopped
mid-turn is unconfirmed. The check is `kill -9` during a turn, then
`zttp expert --resume`.

**Solution.** `zttp expert run "<intent>"` submits a job and prints its id. A
background process runs the job on Pi Durable. The job ends with a proven and
tested change set that waits for approval, or with a refusal report. A macOS
notification announces the end. The job writes no source before approval.

- Steps to value: 3 (submit, accept the contract, approve).
- Key interaction: approve the finished card.

**Retention hook.**

- Mechanism: progress.
- How it works: the job view shows the obligations proven and the obligations
  that remain, as the Lean Infoview shows open goals.
- Habit trigger: the notification.

**Cognitive load.**

- Decisions eliminated: when to check on the run.
- Default behavior: the job waits for approval and never applies a change.
- Visual hierarchy: the count of remaining obligations.

### F6: Proof race

**Pain point.** One draft can circle on a hard proof. App-builder users report
bug loops that burn credits (finding 8).

**Solution.** After a set number of refused drafts, the expert offers a race.
It forks several candidates from the last green checkpoint. The compiler ranks
them by verdict, chips, and tests. The card shows the winner, and the other
candidates stay one key away. The race is off by default.

- Steps to value: 1 (accept the race).
- Key interaction: accept the race.

**Retention hook.**

- Mechanism: variable reward.
- How it works: the developer sees which approach the compiler proved. The race
  is opt-in and has a token budget.
- Habit trigger: a stuck loop.

**Cognitive load.**

- Decisions eliminated: choosing between drafts by reading them.
- Default behavior: off. The candidate count and the trigger threshold need
  measurement against the convergence corpus before they get defaults.
- Visual hierarchy: the chips of the winner.

## Four surface options

All four options use the same proof loop. They differ in where the developer
meets it.

### Option A: Proof loop in the terminal

The existing `zttp expert` REPL gets F1 to F4. F4 uses the `zttp dev` server
when it runs. F5 and F6 are out of scope.

- Steps to code that is generated, tested, and proven: 3 (start with the
  intent, accept the contract, approve). The count is 2 when the contract does
  not change.
- Pi Durable role: none.
- Cost: smallest. All Zig, one binary, and the existing journal, fork, tree, and
  receipts. A persona or tool change moves the codegen corpus identity and
  forces a re-record.
- Risk: a terminal limits how much evidence the developer can browse, such as
  path coverage and flow labels.

### Option B: Proof Studio in the browser

`zttp dev` opens a local page. The intent and the contract card are on the
left. The code is in the center, with obligation markers at the cursor, as in
the Lean Infoview. The result card is on the right. The playground and the
checkpoint timeline are below. Option B hosts F1 to F6.

- Steps: 3.
- Pi Durable role: core. Pi Durable holds the conversations and streams
  `viewState()` to the page. Its forks serve F3 and F6, and its task graph
  serves F5. The Zig expert stays the authority through a new expert RPC mode.
- Cost: largest. Option B needs a Deno companion with HTMX 4 views, the RPC
  mode in Zig, and a second install. The "All Zig" rule puts the companion in a
  separate repository, as with `../ZTTP-WEBSITE`.
- Risk: Pi Durable is experimental, and its API changes without notice. One
  process owns a storage. The developer must keep a second window open.

### Option C: Editor host over ACP

`zttp expert --acp` speaks the Agent Client Protocol. Zed and JetBrains host it
natively. Other editors need adapters. The editor shows the diffs and accepts
each hunk. The proof card travels as tool-call content.

- Steps: 3, plus any accept steps for each hunk that the editor adds.
- Pi Durable role: none.
- Cost: medium. ACP JSON-RPC in Zig, over the same RPC mode.
- Risk: ACP has no place for a proof card or a chip delta, so the evidence
  becomes plain markdown. VS Code has no native ACP support. The host editors
  decide the interface.

### Option D: Background proof jobs

F5 and F6 become the primary interaction. The developer submits jobs, reads a
job list, gets a notification, and approves the result card in the terminal.

- Steps: 3.
- Pi Durable role: core. It runs durable jobs, resumes after a kill, and forks
  the race candidates.
- Cost: medium. Option D needs a Deno daemon like the deferred watcher, and the
  RPC mode.
- Risk: the review queue becomes the bottleneck (finding 7). The launchd
  restart was never measured (`../../../pi-durable/WATCHER_DEFERRED.md`).
  Interactive steering is weaker than in Option A.

### Comparison

| | A: terminal | B: studio | C: ACP editor | D: jobs |
|---|---|---|---|---|
| Steps to generated, tested, proven | 3 (2) | 3 | 3 or more | 3 |
| Interactions hosted | F1-F4 | F1-F6 | F1-F3 | F1-F3, F5, F6 |
| Pi Durable | none | core | none | core |
| New runtime | none | Deno | none | Deno |
| Needs expert RPC mode | no | yes | yes | yes |
| Proof evidence space | one card | full panel | markdown only | one card |

### Shared enabler: expert RPC mode

Options B, C, and D need a long-lived expert process that pauses for decisions.
The process reads and writes JSON lines. It accepts an intent, a contract
decision, a change-set decision, and an abort. It emits the turn events. It
keeps the Zig change-set transaction as the only writer of source. The current
`--print --mode json` is not enough, because it cannot pause (see "What zttp
has today").

## Where Pi Durable fits

Pi Durable adds three things that the Zig expert does not have today. It keeps
in-flight tool calls safe across a kill: the prototype proved this with SIGKILL
tests T1 to T3. It streams committed state to any client through `watch()`. It
runs many conversations and child tasks under one task graph.

Pi Durable should not replace the Zig expert loop, for four reasons:

1. The protocol is read-only by design. A Pi Durable loop must still call the
   Zig change-set transaction for every write.
2. The convergence corpus is recorded against the Zig loop. A new loop orphans
   that evidence until a full re-record.
3. The Zig expert already has a session journal, fork, tree, and compaction. A
   second loop duplicates them.
4. The repository rule is "All Zig". Pi Durable is TypeScript on Deno.

Pi Durable therefore belongs in a companion process outside this repository.
That process drives the expert RPC mode and owns the browser state or the job
state.

Evidence limits for Pi Durable: the prototype tested a kill during a faux model
request only. A kill during a DeepSeek request, a host crash, compaction,
several clients, and long runs are not tested.

## Measurement plan

No baseline exists, so I will measure before any build.

1. Baseline: run the current REPL on a small fixed set of real intents. Record
   the steps, the time to a first tested green change, and `zttp ledger stats`.
2. Prototype F1 and F2 in Option A. Run the same intents with the same model.
3. Compare the step counts, the time, the success rate, and the round trips to
   a first green proof.
4. Retention needs real users over weeks. The signal is returning sessions for
   each developer for each week. No local data source records that today.

## Decisions

**D1: Primary interface.**

- (a) Option A, the proof loop in the terminal. Recommended.
- (b) Option B, Proof Studio in the browser.
- (c) Option C, editor host over ACP.
- (d) Option D, background proof jobs.

**D2: Place of Pi Durable.**

- (a) A companion repository that drives a new expert RPC mode. The Zig
  transaction stays the only writer. Recommended, and used only when D1 or a
  later surface needs it.
- (b) Replace the Zig expert loop with a Pi Durable loop in TypeScript. This
  needs an exception to "All Zig" and a corpus re-record.
- (c) Do not use Pi Durable now.

**D3: Test gate in F1.**

- (a) A failing test refuses the change set, as a failed proof does.
  Recommended.
- (b) The card shows test results, but the developer can approve a red run.

## Appendix: key sources

The research agent took each claim from a search result summary. It did not
fetch these pages.

- Claude Code checkpointing: https://code.claude.com/docs/en/checkpointing
- Kiro specs: https://kiro.dev/docs/specs/
- Thoughtworks on spec-driven tools:
  https://www.martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html
- Lean 4 VS Code manual:
  https://github.com/leanprover/vscode-lean4/blob/master/vscode-lean4/manual/manual.md
- Lean Copilot: https://arxiv.org/html/2404.12534v2
- AxDafny: https://arxiv.org/pdf/2606.32007
- Replit checkpoints: https://docs.replit.com/learn/build-with-agent
- AG-UI: https://docs.ag-ui.com/introduction
- ACP overview: https://www.morphllm.com/agent-client-protocol
- Stack Overflow 2026 survey:
  https://stackoverflow.blog/2026/10/06/the-results-of-the-2026-developer-survey-are-here/

# Beni study: features, compiler, and retrofit items for ZTTP

Date: 2026-10-07. Subject: <https://github.com/canassa/beni> at commit `b0318f4`.
ZTTP baseline: commit `6a0f5577`.

## Answer

Beni is an ML-family language that compiles to JavaScript. Its compiler is
about 152,000 lines of Zig. Beni and ZTTP share a goal: a closed language
where the compiler refuses unsafe programs. Beni has no proofs, flow labels,
contracts, durable workflows, or server HTTP. ZTTP should not copy beni's
language. ZTTP should copy four things:

1. The test and diagnostic discipline: golden diagnostic files, fuzzing, and
   gates that fail when they match nothing.
2. The `match` exhaustiveness algorithm (Maranget), with missing-case examples.
3. The structured-concurrency rules of the fiber runtime, for `zttp:io`,
   `zttp:scope`, `zttp:workflow`, and `zttp:durable`.
4. Compiled schema validators that report typed issues with a path.

The on-disk analysis cache and parallel checking are also strong. They need
a measurement of where a cold `zts` run spends its time before any plan.

Section 4 gives 18 retrofit items in three tiers. Section 7 gives the
decisions for the owner.

## 1. Method and evidence limits

Six research agents read the beni clone and the ZTTP tree. Five studied beni:
language, frontend, checker, backend and runtime, and tests and process. One
mapped the matching ZTTP subsystems. No agent built or ran beni or ZTTP.

Every beni speed or size number in this file is beni's own claim. I did not
measure any of them. I checked these ZTTP facts myself in code:

- ZTTP has no `std.testing.fuzz` test (zero matches).
- The module sources have 44 `throwError` or `TypeError` sites.
- `packages/zts` has no analysis threads. The only thread use is a test in
  `bytecode.zig:1418`.
- `match_analysis.zig:169` (`patternFullyCoversType`) requires one arm to
  cover each whole union member. It does not combine coverage across arms.
- Handler sources are read by `packages/zts/src/file_io.zig:7`. It reads
  chunks until end of file. See correction C1.

## 2. Beni feature inventory

Status words: "built" means that code and a corpus fixture with an expected
output exist. "Spec" means that only a design document exists.

### 2.1 Language

| Feature | What it does | Status | ZTTP fit |
|---|---|---|---|
| Hindley-Milner inference | Annotations are optional. The checker infers the most general type. | Built | Low. ZTTP checks only annotated code, by design. |
| Custom types (ADTs) | `type Shape = Circle Float \| Rect Float Float` | Built | ZTTP has closed unions. |
| Exhaustive `case` | A missing constructor is an error, with an example of the missing case. A dead arm is an error. A work budget applies, and running out of it is an error. | Built | High (R1). |
| Immutable records | `{ user \| age = 1 }` update. Fields are sorted, so one record type has one shape. | Built | ZTTP has records. |
| No null, undefined, or exceptions | `Maybe` and `Result` are ordinary types. The language has no throw. | Built | ZTTP has the same posture. Its module exports still throw (R8). |
| `?` postfix | `e?` unwraps `Result` or `Maybe`, or returns early from the enclosing definition. It is refused inside a lambda. | Built | Medium (R16). ZTTP has no equivalent. |
| No currying | Calls are saturated. `f a _ c` is an explicit partial application. | Built | Low. TS calls are already n-ary. |
| Pipe `▷` and bind `←` | `x ← f a` passes the rest of the block as a callback (scoped resources). | Built | Low. ZTTP removed `\|>` and `pipe()`. |
| List patterns | `[ x, …rest ]`, `[ …init, last ]` | Built | Medium. These feed R1. |
| Tuples, unit `⊤`, empty type `⊥` | Fixed-arity tuples. A statement must have type unit. | Built | Low. |
| Unicode operators | One spelling each. An ASCII form is refused with a rewrite. | Built | Low. |
| Typed interpolation | `"${x}"` only for String, Int, Float, Bool, Char, with a known type | Built | Medium (R16). ZTTP refuses interpolation. |
| No shadowing; fixed operator set | No user-defined operators | Built | ZTTP is close already. |
| Static dispatch | `v.add w` is `Vec.add v w`. `where a.add : a, a → a` constraints use dictionary passing. | Built | Low. zts-model-1 has no methods. |
| Derived `eq` and `compare` | Structural, derived when absent. `==` on a type that holds a function is refused. | Built | Medium. Same shape as the ZTS213 JSON check. |
| `Debug` | `Debug.log` and `Debug.todo`. A release build that reaches `Debug` is refused. | Built | Medium. Cheap guarantee. |

### 2.2 Effects and the fiber runtime

| Feature | What it does | Status | ZTTP fit |
|---|---|---|---|
| Functions without `async` ("colorless") | The checker infers `pure`, `impure`, or `suspends` for each function. Only suspending functions get a CPS transform. A call that does not park costs one comparison. | Built | Medium. The ZTTP VM owns its stack and needs no CPS. |
| Effect summaries | Inferred and published in the module interface. Visible through `dump`. | Built | High (R14). |
| `sync` boundary | A callback marked `sync` must not suspend. The error names the call chain. | Built | High (R14). |
| Structured fibers | `spawn`, `join`, `scope`. A child is cancelled when its parent ends. | Built | High (R6). |
| Cancellation | Delivered only at a suspension point. Finalisers run last-first and cannot be interrupted. | Built | High (R6). |
| `race` and `timeout` | Losers are cancelled, and their cleanup finishes before the answer returns. | Built | High (R6). ZTTP `race` is first success in array order. |
| `par`, `parOk`, bounded `forEach` | Fail-fast: the first error cancels its siblings. The concurrency bound is a parameter. | Built | High (R6). ZTTP has a fixed cap of 8. |
| `retry`, `repeat`, `Schedule` | A schedule is an immutable value with a pure `step` function. | Built | High (R7). ZTTP retries only in `fetchWithRetry`. |
| Virtual clock | One clock slot per fiber. Sleepers wake deterministically in tests. | Built | High (R7). Fits `trace.zig` replay. |
| `Ref`, `Deferred`, `Duration` | Mutable cell with `sync` update. One-shot promise. Opaque duration. | Built | Low. |
| Defect handling | A JS throw is fatal. Every root scope closes. A program that can never wake exits 1. | Built | Medium. |
| `Semaphore`, `Queue`, `Latch`, `Trace`, `Log` | Concurrency primitives and logging | Spec | Low. |

### 2.3 Schemas

| Feature | What it does | Status | ZTTP fit |
|---|---|---|---|
| `schema` declarations | One declaration gives two types: `Item.Type` and `Item.Encoded`. Field modifiers are `as`, `optional`, `nullable`, `via`, and `tagged` unions. | Built | High (R9). |
| Runners | `parse`, `print`, `decode`, `encode`, `read`, `write`, each returning `Result (List Issue) a` | Built | High (R9). |
| Issue shape | Path, direction, endpoint, one of 12 codes, message, input | Built | High (R9). |
| Guarantees | No exception escapes, every failure has a path, depth is bounded, the unknown-key policy is explicit, both directions are total | Built | High (R9). |
| Two engines | An interpreter written in beni, and generated code for each declaration. A differential test compares them. | Built | High (R9). |
| Defaults, checks, JSON Schema output, generators | Later stages S5 to S12 | Spec | Low. |

### 2.4 Platforms and host boundary

| Feature | What it does | Status | ZTTP fit |
|---|---|---|---|
| Platform packages | Only a platform may write `foreign` bindings to JS. A user module cannot import `Js`. | Built | ZTTP has `ModuleBinding` already. |
| Build checks on bindings | Admitted shape, exact export names, free identifiers covered, arity equals evidence count plus declared arity | Built | Medium (R8). |
| Failure rule | Each documented host failure is caught by name and becomes a constructor. Any other error is a defect. A catch-all is a defect. | Built (review rule plus fixtures, not a compiler check) | High (R8). |
| Platforms | `node` (CLI only, no HTTP server), `browser`, `browser-tea` | Built | Low. |

### 2.5 Markup, UI, and web

| Feature | What it does | Status | ZTTP fit |
|---|---|---|---|
| Typed JSX | Checked against a platform vocabulary of 112 elements. Unknown attributes, `on*` strings, and `script` are refused. Text holes are never HTML. | Built | Medium (R16). ZTTP checks TSX only as `h()` calls. |
| Template compilation | Clone a template once, then patch only changed holes | Built | Low. ZTTP renders on the server only. |
| The Elm Architecture | `Cmd` with keyed policies, `Sub`, `Tea.application` | Built | Low. |
| URL parser and builder | Typed parser combinators | Built | Low to medium for server routes. |
| Browser HTTP | `Http.request` waits in a fiber, returns `Result`, decodes with schemas | Built | Low. |

### 2.6 Tools

| Feature | What it does | Status | ZTTP fit |
|---|---|---|---|
| `new`, `build`, `serve`, `check`, `fmt`, `dump` | `serve` rebuilds and reloads on save | Built | ZTTP has `init` and `dev`. |
| `dump --stage=...` | Prints tokens, AST, BIR, interface, raw records, types, graph, or dispatch. No ids or positions by default. | Built | Medium (R13). |
| `--jobs=n` | Output is byte-identical for every n | Built | Medium (R12). |
| `--self-profile` | Chrome trace plus counters | Built | High (R10). |
| `--diagnostics=json` | Full diagnostic JSON | Built | ZTTP has `--json`. |
| Exit codes | 0 clean, 1 error diagnostic, 2 usage or I/O failure | Built | Low. |
| Packages, LSP, `beni test`, user docs | | Not built | |

## 3. Beni compiler implementation

**Layout.** Tokens, AST, BIR, and the JS IR are struct-of-arrays columns
(`MultiArrayList`) with `u32` indices and one `extra: []u32` sidecar. This
follows `std.zig.Ast` and Zir. A token is 13 bytes and holds no length. Lists
are reserved from measured ratios, so a typical file never grows a list.

**Interning.** The tokenizer hashes identifier bytes while it scans. Each
worker has a local pool. The pools merge in file order, so ids do not depend
on scheduling. Beni found and fixed a bug in which a worker-order merge
changed diagnostics under load.

**Allocation.** A single-thread bump arena with no atomics holds scratch
data. Front-end outputs belong to the session allocator, per file.

**Parallelism.** Each wave spawns threads that take file indices from one
atomic counter. Modules are checked on a DAG scheduler. The thread count is
bounded by the DAG width and by work size. An import cycle falls back to one
thread. A test asserts byte-identical output for `--jobs=1` and `--jobs=8`.

**Cache.** Three artifact kinds: front-end artifact, checked-module entry,
and an embedded pre-checked core pack. A module key includes each direct
import's interface hash and a "dependency digest". The digest covers the
facts that dependents read but the interface omits. This gives early cutoff:
beni reports that one comment in a leaf module had re-checked 624 of 634
modules under the old key. In safe builds, each cross-module read records its
kind. A read that the key does not cover is an internal error. Errors are
never cached. A bad cache file is always a miss.

**Checker.** Constraints are generated per binding group, then solved with
union-find over one flat type array. Generalisation uses ranks. A failed node
gets an `err` type that unifies with anything, so one mistake gives one
message. One function emits all diagnostics and marks the declaration as
failed; later phases skip failed declarations. Exhaustiveness is Maranget's
algorithm with list length splits, witness rendering, and a step budget.

**Backend.** Declaration reachability runs before lowering, so dead code is
never lowered. Pattern matches compile to decision trees. Release builds add
constant propagation, inlining, renaming, and minification. Dev builds emit
source maps. Polymorphism uses dictionary passing, not monomorphisation.

**Diagnostics.** A diagnostic is data (code, span, context, expected). Text is
rendered later by one function, in Elm's register: title, what the compiler
looked at, the two types, a hint. The parser never reports two errors at one
offset, stays silent while it recovers, and asserts in safe builds that each
loop consumes a token. A Unicode lookalike table names confusable characters.

**Tests.** 1,924 fixture files in `tests/corpus/`. A fixture's sibling file
holds the full expected output: the AST, the full diagnostic JSON, the
interface, the formatter output, or the program stdout. One environment
variable rewrites the expected files. A `bad/` fixture with no expected file
fails. A filter that matches no fixture fails. The `gates` step refuses
filters. Each test has a budget of retired instructions. The formatter test
asserts a fixed point, the same AST, and the same comments.

**Process.** Plans and design documents are normative. Every defect gets a
fixture, and the author stashes the fix to prove the fixture fails without
it. Beni has no CI that runs its gates; ZTTP's `scripts/verify.sh` is
stronger here.

## 4. Retrofit items

Each item gives the beni source, the ZTTP state, and the first step. "Value"
and "risk" are my judgement from the evidence above, not measurements.

### Tier 1: test and diagnostic discipline (low risk, independent)

**R1 (Maranget exhaustiveness for `match`).** Replace the per-arm rule in
`match_analysis.zig` (377 lines) with a pattern matrix. A record field that
tests a discriminant (`kind: "echo"`) becomes a constructor of the closed
union. A type test (`string`, `Dict`, and so on) becomes one alternative of a
finite set. Report a source-syntax example of each missing case. Report the
first redundant arm. Treat budget exhaustion as an error, never a pass.
Beni source: `src/check/Exhaustive.zig`. ZTTP today: coverage split across
arms is not recognized, no example is given, and redundant arms are not found.
First step: collect current `match` warnings over the examples and the
recorded corpora to size the change.

**R2 (golden diagnostic corpus).** Add `tests/corpus/{parse,check}/{good,bad}/`
with one `.ts` file and one full-JSON `.diag` file per case. A missing
`.diag` fails. One variable rewrites the goldens. A filter that matches no
case fails. Then add a ratchet: every advertised ZTS code has a golden case.
ZTTP today: 14 `.ts` files in `tests/verify/`, checked by grep. This turns
the AGENTS.md rule "never cite a `-Dtest-filter` run" into a mechanical
refusal.

**R3 (fuzzing).** Add `std.testing.fuzz` contract tests for the tokenizer,
parser, and type checker: no panic, all spans in bounds, every loop
terminates. Run only the seed corpus in the gate. Add byte-mutation sweeps for
`proof-checker` `wire.zig` and the bytecode cache serializer. Add a corpus
mutation run that requires a diagnostic and never a crash, hang, or internal
error. Beni notes that the Zig 0.16 `-ffuzz` mode did not work for it and
used a PRNG stress loop instead. That needs to be checked on ZTTP's toolchain.

**R4 (diagnostic pipeline).** Make diagnostics data and render them later
through one function. Add a poisoned error type so one mistake gives one
message. Mark a failed declaration so later passes skip it. In the parser,
add the two dampers, a safe-build progress assertion, and a depth guard.
Render a span, not one caret. Adopt the "what, where, why, hint" text shape.
Add a Unicode lookalike table to ZTS046. ZTTP keeps its numeric codes.

**R5 (test budgets and abuse tests).** Give each test and corpus case a
budget in retired instructions, so slow tests fail independent of machine
load. On macOS this needs a `getrusage` fallback; beni uses Linux perf
counters. Add ratio tests that check cost(2n)/cost(n) for the parser, type
checker, and flow checker. Add CLI abuse tests: hostile input must give an
exact exit code, a normal exit and not a signal, and no partial output.

### Tier 2: runtime and module semantics

**R6 (structured-concurrency rules).** Specify these rules for `zttp:io`,
`zttp:scope`, and `zttp:workflow`. Cancellation reaches work only at a
blocking point. Finalisers run last-first and cannot be interrupted. `race`
and `timeout` return only after the losers' cleanup has run. `race` returns
the first to finish, not the first success in array order. Bounded `forEach`
takes the bound as a parameter. Fail-fast `parOk` cancels its siblings.
ZTTP today: fetches run on OS threads that block, with a cap of 8. Real
cancellation of a blocked fetch needs a design check in `runtime_http.zig`.

**R7 (`Schedule` and a virtual clock).** Make a retry policy a pure value
with a `step` function over attempt, elapsed time, and input. A pure step
records and replays deterministically, so it fits `zttp:durable` and
`trace.zig`. Generalize `fetchWithRetry` into a retry for durable steps. Add
a virtual clock for tests and replay.

**R8 (typed failures at the module boundary).** Give each `zttp:*` binding a
closed error enum. Convert the documented failures among the 44 throw sites
in `packages/modules/src` into `Result` returns. Return a tagged `Result` from
`fetch` in place of status 599. For each capability, add a test that forces
each documented failure and asserts the value. An unknown error is a defect,
never a string. Without try/catch, each throw aborts the handler today.

**R9 (compiled schema validators).** Compile each schema into one specialized
validator, as bytecode or as a Zig plan, in place of the runtime tree
interpreter in `validate.zig`. Issues carry a path. Depth is checked before
descent. The unknown-key policy is explicit. `FirstError` and `AllErrors`
modes exist. Keep the interpreter as a reference and add a differential test.
Later, derive a schema from a TS type alias, so one declaration gives both
the input type and the validated type. Risk: the flow-label transfer must
come from the same plan, or the `validateJson` laundering class returns.

### Tier 3: compiler infrastructure (measure first)

**R10 (measure a cold `zts` run).** Before R11 to R13, measure instructions
and page faults per phase for a cold `zts check` and a `zttp dev` rebuild.
Add `--self-profile` (Chrome trace) and counters that tests can assert, for
example "zero files parsed on a warm run". Beni found that its in-process
benchmark undercounted the real process by about 1.9 times. Add a cold
single-process line to `zig build compile-bench`.

**R11 (content-keyed analysis cache).** Cache parse and analysis results on
disk under a content key. Use an interface hash plus a dependency digest for
early cutoff. Ship it only together with a covered-read self-check, because a
cached PROVEN verdict that its key does not fully cover is the "returns more
than it checked" class in AGENTS.md. Never cache errors. A bad entry is a
miss. Serialized results must hold no ids and must be ordered by text.

**R12 (parallel analysis with determinism rules).** Parse and check modules
on a DAG scheduler. Merge interned names in file order. Write results into
per-index slots. Add a `--jobs=1` against `--jobs=N` byte-diff test. This
is useful only if R10 shows that multi-module analysis time matters.

**R13 (dump commands).** Add `zts dump --stage=tokens|ir|types|labels|effects|bytecode`
with no ids and no positions by default. Use the dumps as goldens for flow
and label decisions, so tests do not reach into internals.

**R14 (effect summaries and a "must not block" check).** `effect_inference.zig`
already computes an effect row per function. Publish the rows through R13 and
in the module interface. Add a boundary check: a callback that must not block
(for example, inside a determinism-sensitive or durable body) is refused, and
the error names the call chain. A larger design option is to infer flow
labels through per-export summaries in place of hand-declared `return_labels`.
That changes how PROVEN is computed and needs the AGENTS.md probe method first.

**R15 (backend).** Compute declaration reachability before bytecode
generation, so a self-contained binary carries no dead code. Compile `match`
to a decision tree (this shares the matrix with R1). Use checker purity facts
to drop dead bindings. Put a source position on every IR node, so runtime
errors can map to source.

### Tier 4: optional language and tool surface

**R16 (language surface).** Candidates: a postfix `?` for `Result` with a
defined return target; typed interpolation for primitives only; TSX typed
against an element vocabulary with `on*` strings refused; a release build
that refuses debug-only calls. Each change moves the prompt and the corpus
identity, so each one forces a corpus re-record.

**R17 (formatter invariants).** For any rewrite of user files (`zttp
normalize`, the expert-loop edits in `packages/pi`), assert a fixed point,
the same IR, and the same comments. AGENTS.md records a file-destroying edit
that this invariant would have caught.

**R18 (small process items).** A `tests/pending/` directory for fixtures that
fail on purpose until a fix lands. A source-reading lint that refuses a
HashMap keyed by a dense id unless an allowlist row gives a reason. A
hint-only file read for the `readFileAlloc` sites (see C1).

## 5. Items not recommended

- Hindley-Milner inference and let-generalization: ZTTP checks annotated code
  by design, and the change is a checker rewrite.
- Static dispatch, `where` clauses, and dictionary passing: zts-model-1 has
  no methods.
- CPS transform and twin function bodies: the VM owns its stack, so a park
  can save frames directly.
- No currying, `_` placeholders, `▷`, `←`, Unicode operators: ZTTP removed
  pipes and keeps TS syntax.
- Clone-once DOM templates, TEA, client routing, JS renaming and
  minification: these are browser concerns.
- Struct-of-arrays token array and per-worker interning: only after R10 shows
  front-end cost.
- `mmap` for cache entries: beni measured it slower than `read`.

## 6. Corrections to agent reports

**C1.** The frontend agent called the Zig 0.16 `readFileAlloc` crash (a file
that grows during the read) a direct risk to ZTTP. That is wrong for handler
sources: `file_io.zig:7` reads chunks until end of file. The risk is probable
for about 15 `readFileAlloc` sites in `packages/pi`, `tooling/`, `build/`,
and `scripts/`. A test that appends to a file during the read confirms it.

**C2.** The testing agent found that beni's own skill file says "CI runs both
suites on every commit". Beni's workflows run no gates. Beni's quality
depends on a local rule.

## 7. Decisions for the owner

Answered 2026-10-07: D1 (a), D2 (a), D3 (a). The owner chose Tier 1 for the
next plan. That answer authorizes a plan, not implementation.

**D1 (first tier to plan).**
Options: (a) Tier 1, items R1 to R5; (b) Tier 2, items R6 to R9;
(c) R10 measurement first.
Recommendation: (a). The items are independent, low risk, and each one makes
later work safer. R1 and R2 can start together.

**D2 (language-surface items in R16).**
Options: (a) defer all of them; (b) plan `?` only; (c) plan all of them.
Recommendation: (a). Each item forces a corpus re-record.

**D3 (flow labels through inferred summaries, part of R14).**
Options: (a) record as a research item only; (b) plan a probe study now.
Recommendation: (a), until R2 and R3 exist to catch a PROVEN regression.

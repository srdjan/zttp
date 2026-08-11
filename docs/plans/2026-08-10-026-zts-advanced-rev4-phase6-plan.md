# Phase 6: Idiom Table, Validators, and the Gate-Complete Protocol - Implementation Plan

**Goal:** Make the idiom table a channel rather than a data structure, give the
rewrites that ship an equivalence method that runs, and close the parts of the
agent protocol that `meta` itself reports as absent. The canonical formatter is
the piece everything else in this phase waits on, and it is the largest single
cost in the language program.

**Exit (from the roadmap):** double-normalize byte-identity over the whole
corpus; atomic `apply_repair` rejection tests; meta drift gates wired into
`scripts/verify.sh`.

**Source of truth:** `docs/zts-formal-spec-northstar-advanced.md` revision 4,
sections 4.2.1, 4.8, 5.5, and 8; and
[D3 canonical form and wire](2026-07-30-016-d3-canonical-form-wire-design.md)
sections 1, 2, 4, 5, 6, and 7, which own every decision this phase consumes.

## Scope decisions, stated before the tasks

**Two of the three exit clauses are already met, and this plan says so rather
than re-planning them.** `apply_repair` refuses an ungraded intent, a stale
snapshot, an overlapping set, and an edit its own law does not discharge, each
without touching the file, and four tests in `agent_protocol.zig` pin exactly
that. The meta drift gates run today as unit tests inside `zig build test`,
which `scripts/verify.sh` runs, plus `scripts/check-agent-determinism.sh`, which
runs the real binary twice per operation and compares bytes. What is genuinely
open in the exit sentence is byte-identity over the whole corpus, and that waits
on the formatter. Task 14 states the other two as re-confirmed rather than
claiming them as new work.

**The protocol's operation set is not this phase's work either.** The roadmap
line reads "batch `apply_repair` and multi-property `verify`" as though both
were unbuilt. All eleven operations are implemented: `apply_repair` takes a
repair array and validates each repair against its own law on the edit it
produced, and `verify` takes a property list plus an optional content override
that closes the propose, simulate, verify cycle with no write. What is left of
D3 section 6 is the ten rows in `agent_protocol.deferred_sections`, and those
are tasks 9 through 11.

**M3 rows do not become implemented in this phase, and the reason is recorded
rather than assumed.** Kernel-IR identity elaborates both sides to the semantic
kernel and compares. The spec's own section 10 defers the kernel's operational
semantics, so there is nothing to elaborate into. The three M3 rows stay
`planned`, which keeps them advisory-only and out of `repair_available`, and
that is D3's published fallback rather than a gap. Phase 6 delivers M1, which
the formatter unblocks, and M2, which needs only an IR comparison.

**The canonical formatter fails closed and is enabled per construct.** There is
no printer anywhere today and the parser retains no trivia. A partial printer
that emits near-canonical bytes would make the byte-identity claim false while
every gate reported green, so the printer refuses what it does not cover and
`normalize --write` declines with it.

## Ground truth measured on 2026-08-10

| Assumed | Measured | Consequence |
|---|---|---|
| "The remaining idiom rows" is a short tail | `idiom_registry.zig` carries 18 rows; spec 4.2.1's table has 24. The six absent are two-way pure selection, record update, `Result` default, `Result` sequence, pure single-accumulator fold, and pure search loop | Four of the six describe forms the language now has, since phase 4 closed `Result`. The rows are addable as table data in one task, ahead of any rewrite for them |
| The idiom rows report | Three report: `dictionary map` and `dictionary filter` share ZTS627, `dictionary fold` is ZTS628, and `element iteration` is ZTS619. The other fifteen are table-only. Measured through the built binary: `a.concat(b)` and `items.indexOf(v) !== -1` produce no diagnostic at all | The channel is three rows wide, and widening it is a per-row analysis cost this phase does not pay in full. What it does pay is making the channel correct for the rows that use it |
| The advisory severity is inert | It is not. The three dict rows emit `.advisory` directly. The comment in `strict_checker.zig`'s own test - "No rule emits an advisory until the idiom channel is wired" - is stale and was written before phase 4 | The channel exists. The correction is which rows use it, not whether it works |
| The one idiom row with a wired rewrite reports as an advisory | ZTS619 reports at `canonicalSeverity()`, which returns `.err` unconditionally | The single idiom row that can be mechanically repaired fails the build, which spec 4.2.1 forbids in the same paragraph that admits the row: a non-idiomatic spelling "is never an error and never fails a build" |
| An advisory cannot change a verdict | `countBand` and `collectCanonicalResidualDiagnostics` filter by code, and `isCanonicalProfileName` admits every rule whose name starts with `canonical_`. So an advisory keeps `residual` above zero, which makes `fully_canonical` false, which makes `normalize --write` decline the file | An advisory that never fails a build does refuse a write. Two different questions are being answered by one count, and task 3 splits them |
| Every idiom row names its rewrite | One of the 18 does: `drop_unused_index_alias` for `element iteration`. Of the 17 `RepairIntent` members, 16 repair a restriction rather than realize a row | The idiom rewrite lane is one row wide, and `findByRewriteRule` exists to map exactly that one back |
| The validator registry is unbuilt | `repair_validator.zig` carries one row per intent: six `.implemented` under M4, seven `.planned` (three M3, two M2, two M5), and four `.not_applicable`. Only an `.implemented` row may set `repair_available` | The two M2 rows are the cheap ones, and one of them is the single wired idiom row. M1's row set is empty until the formatter exists |
| D3 section 5's repair vocabulary collapsed | It did not. `parseRepairs` builds a line-keyed `canonicalize.Refactor`, and the apply path refuses a multi-line replacement with "a replacement spanning lines needs the span-keyed path" | The collapse is open, and it is what `meta`'s `diagnostic_span` row is waiting on: a diagnostic publishes a line and a column and no byte range |
| `meta`'s gaps must be inventoried | `meta` publishes them. Ten `deferred_sections` rows: seven marked phase 6 (`grammar`, `examples`, `decisions`, `diagnostic_span`, `contract_body`, `extension_manifests`, `repair_budget`), two marked earlier phases (`ambient_names` at phase 4, `type_serialization` at phase 2), and `rule_severity`, recorded as a question no registry can answer because severity is chosen per emission site | The phase's meta task list is machine-readable. The two slipped rows are now unblocked: `known_globals.names` is the ambient table and `type_key.typeDigest` is the canonical type serialization |
| The maximum normalize pass count needs publishing | `canonicalize.max_normalize_iterations` is 64 and `meta.limits.normalize_iterations` publishes it, with a test asserting the published value is the constant the code enforces | Spec 4.2.1's "the profile registry publishes the maximum pass count" is met. What `limits` still lacks is the repair-iteration and tool-call budget, which is a loop policy nothing implements |
| The double-normalize gate covers the corpus | 57 files checked, 1 skipped. The skip is `examples/sql/sql-crud.ts`, and it fails with `MissingSqlSchema` because the file needs `--sql-schema`, not because normalize found an unrewritable construct. The gate prints "skipped as not fully canonical" | The gate's only skip is reported with the wrong reason. This is the class `AGENTS.md` names, in miniature: the count is honest and the explanation is not, and a reader takes the explanation |
| Confluence is asserted, not verified | The harness exists in `canonicalize.zig`, restricts the loop to one row kind at a time so a critical pair is observable, and `known_non_joining` is empty. It fails both on an unlisted non-joining pair and on a listed pair that starts joining | Adding rows re-runs it for free, and a new row that does not join is a build failure rather than a runtime surprise |
| The six lexical divergences are open the way D3 describes them | Measured one at a time on the built binary. `"a\qb"`, `0755`, `0x`, and a backslash before a real newline all parse clean. An unterminated string is caught by the type stripper as `error.UnterminatedString` before the parser sees it, and `zts check --json` answers `{"success":false,"diagnostics":[]}`. A non-ASCII identifier produces three cascading parse errors | Four are silent acceptances. The unterminated string is worse than D3 recorded: it is a failure that names nothing on the machine channel. The non-ASCII case is the token-run degradation D3 described |
| The lexical tightenings need new error kinds | The kinds exist. `ErrorKind` already carries `unterminated_string` (ZTS008), `invalid_escape_sequence` (ZTS013), `invalid_number` (ZTS012), and `unexpected_character` (ZTS040), and `parse.zig` already emits `invalid_number` for a numeric separator | Most of the work is emitting a kind that exists from a site that today accepts, not minting codes. A new code is minted only where an existing kind would name the wrong fault |
| ASI is one site | `parse.zig:1072` is the `return` case D3 named. `parse.zig:3438` accepts an implicit semicolon after `}` or at a newline generally, and a handler written with no statement semicolons parses clean today | Removal touches statement termination, not only `return`. The repair must insert a semicolon anywhere a statement ends, and the corpus must be measured before the flip rather than discovered by it |
| No formatter exists | Confirmed. No printer over the IR anywhere, and `grep trivia packages/zts/src/parser/*.zig` is empty: the IR discards comments | Trivia retention is the first task of the formatter and every layout rule depends on it |

Free diagnostic codes: ZTS045 upward in the parser band; ZTS207 and ZTS214
upward in the type-checker band; ZTS513 upward in the contract band; ZTS629
upward in the canonical band.

## Global constraints

- The engine stays interpreter-only. Nothing in this phase adds a value kind.
- Each admitted form adds its semantics-registry rules in the same task. The IR
  alphabet is pinned at 82 named `NodeTag`s and the opcode alphabet at 130; a
  task that trips either moves or acknowledges the pin in the same commit.
- No `meta` payload content is hand-written. Every new key is generated from a
  registry, and a registry that mirrors a document gets a drift gate in the same
  task that adds it.
- Every task: `zig fmt` on touched files, tests in `test "..."` blocks next to
  the code, the named test step run before and after, one commit per task, never
  push.
- Phase boundary gate: `bash scripts/verify.sh` green, `zig build test` green,
  `bash scripts/test-examples.sh` green.
- A gate asserts a floor on its own input before any count it reports means
  anything, it asserts the value expected rather than a difference from the
  values excluded, and a probe's verdict is read from the build's exit status
  rather than from a grep over its output.
- A rewrite is advertised only when a registered validator with
  `.implemented` status discharges it. Naming a method is not having one.

---

### Task 1: the idempotence gate's floor and its one skip

**Files:** `scripts/check-normalize-idempotent.sh`.

The gate checks 57 files and skips one, and the skip is wrong about itself:
`examples/sql/sql-crud.ts` fails with `MissingSqlSchema`, which is a missing
command-line argument, and the gate reports "skipped as not fully canonical".
Every later task in this phase is measured through this gate, so its floor is
fixed before anything moves.

Three changes. A file that needs a schema is run with its schema rather than
skipped, using the same discovery `scripts/test-examples.sh` already does. A
skip prints the file and the reason `normalize` gave, so a silent class change
cannot hide inside the count. And the gate asserts a minimum checked count, so
a glob that stops matching fails rather than reporting success over nothing.

This is first because it is the map: it is a test, and what it says after the
formatter lands is the phase's own measurement.

**Tests:** deleting the `examples/` glob's match set fails the gate rather than
passing it; a file that normalize refuses names its reason in the output; the
checked count is at least the count measured today; the gate passes with zero
skips, or each remaining skip names a reason that is not a missing argument.

### Task 2: the six missing idiom rows, and the table's drift gate

**Files:** `packages/zts/src/idiom_registry.zig`,
`docs/zts-formal-spec-northstar-advanced.md` if the table needs a correction,
a new `scripts/check-idiom-table.sh`, `build.zig`, `scripts/verify.sh`.

Spec 4.2.1 has 24 rows and the registry has 18. The six added here are two-way
pure selection, record update, `Result` default, `Result` sequence, pure
single-accumulator fold, and pure search loop, each with the spec's own
operation, idiomatic spelling, superseded spellings, and precondition, and each
with `rewrite_rule` null, because no rewrite implements them. A row with no
rewrite is advisory-only, which the registry's own header already states.

The spec says the table "is registry-generated and drift-gated" and no gate
exists. The gate compares the document's table to the registry row for row and
column for column, in the shape `scripts/check-docs-drift.sh` already uses for
the Module Catalog. Its floor: deleting a registry row fails, deleting a
document row fails, and an empty extraction fails rather than passing over
nothing.

`idiom_table_hash` moves in this task, since the pre-image walks every row. The
published value is re-pinned in the same commit.

**Tests:** the registry carries 24 rows and every one has a non-empty operation,
idiomatic spelling, superseded list, and precondition; the ids stay unique and
keep the `idiom.` prefix; `tableHash` changes when a row changes and is stable
across calls; the drift gate fails when a row's precondition text differs
between the document and the registry; the drift gate fails on an empty
extraction.

### Task 3: the idiom channel - advisory severity, and the two measures

**Files:** `packages/zts/src/strict_checker.zig`,
`packages/tools/src/canonicalize.zig`, `packages/zts/src/rule_registry.zig`.

Two defects, and they are the same defect seen from two sides.

**ZTS619 reports at error.** It is the one idiom row with a wired rewrite, and
spec 4.2.1 says a non-idiomatic spelling never fails a build. It moves to
`.advisory`, which is where the three dict rows already are. `canonicalSeverity`
keeps returning `.err` for the restriction rules, which are refusals and not
preferences.

**One count answers two questions.** `countBand` measures progress inside the
normalize loop, and `collectCanonicalResidualDiagnostics` decides
`fully_canonical`, which decides whether `--check` fails and whether `--write`
writes. Both count band membership by rule name. The result is that an advisory
that cannot fail a build does refuse a write.

The split: the progress measure counts every band diagnostic, advisories
included, because a rewrite that clears an advisory has made progress and the
loop must not read it as a stall. The canonicality verdict counts only band
diagnostics at `.err`, because only `.err` may fail a check - which is what
`strict_checker.Severity`'s own documentation already says, and what the
verdict has not been doing.

The consequence is stated rather than discovered: a file carrying an idiom
advisory whose precondition fails is canonical, is written by `--write`, and
still reports its advisory through `check`. That is spec 4.2.1's own position -
the row stands, the source is left alone, the author hears about it.

**Tests:** a handler whose only canonical diagnostic is an idiom advisory exits
0 from `zts check`, is reported `fully_canonical`, and is written by
`normalize --write`; the advisory is still present in `check --json` with its
code; a handler with a restriction error is not canonical and is not written; a
file whose advisory has a wired rewrite still converges, so the progress measure
did not stop seeing it; the error count is unchanged by an injected advisory.

### Task 4: one repair vocabulary, span-keyed

**Files:** `packages/tools/src/canonicalize.zig`,
`packages/tools/src/agent_protocol.zig`, `packages/zts/src/repair_intent.zig`,
`packages/pi/src/tools/repair_apply.zig`,
`packages/pi/src/tools/zts_expert_ast_rewrite.zig`.

D3 section 5's `Repair`: a typed intent, an optional idiom id, a half-open byte
span into the source the digest covers, the original snapshot, the replacement,
and an optional validator reference. The line-keyed `Refactor` and its string
`kind` retire, which removes both the "line-keyed takes absolute priority"
scheduling rule and the no-newline restriction on replacements.

`original` stays required on the wire. It is the client's snapshot, re-validated
against the file as it stands, and an absent one would make the staleness check
skip silently, which is the single thing the field exists for.

Two properties are preserved and re-checked rather than assumed: `applyRefactors`
refuses two rewrites that overlap, and the normalize loop's one-row-at-a-time
restriction is what makes a critical pair observable in the confluence harness.
A span-keyed apply must keep both, and the harness is the test that says it did.

**Tests:** a multi-line replacement applies rather than being refused; two
repairs whose spans overlap are refused, and two on the same line whose spans do
not overlap both apply; a moved snapshot still refuses with `stale_repair`; the
confluence harness passes unchanged; a repair round-trips from `canonicalize`
through `simulate_edit` to `apply_repair` with no field lost.

### Task 5: diagnostic byte spans

**Files:** `packages/tools/src/json_diagnostics.zig`,
`packages/zts/src/diagnostic_projection.zig`, the diagnostic producers,
`packages/tools/src/agent_protocol.zig`.

Every diagnostic publishes a half-open byte span in addition to its line and
column, which is what spec 4.8's diagnostic shape requires and what the
`diagnostic_span` deferral names. The offsets come from the same source bytes
the digest covers, so a client can bind a repair to a diagnostic without
re-deriving anything.

The `deferred_sections` row for `diagnostic_span` comes out in this task, and
`meta`'s key set moves with it.

**Tests:** every producer's diagnostic carries a span whose end is at or after
its start and whose bytes are inside the file; the span's start agrees with the
line and column it also reports; a diagnostic on the last byte of a file does
not run past the end; `meta` no longer defers `diagnostic_span`, and the drift
test that reads the live payload agrees.

### Task 6: trivia retention

**Files:** `packages/zts/src/parser/ir.zig`, `packages/zts/src/parser/parse.zig`,
`packages/zts/src/parser/token.zig`.

The parser retains comments, their byte spans, and their attachment points, plus
the blank-line runs between top-level declarations. Nothing consumes this yet.
It lands alone because every layout rule in the next task depends on it, and
because a trivia model that is wrong is far cheaper to find against a
round-trip test than against a printer.

The IR alphabet is pinned. Trivia is a side table keyed by node rather than a
node kind, so the pin does not move; if the implementation finds otherwise, the
pin moves in this commit with the reason.

**Tests:** a line comment above a declaration attaches to that declaration and
not to the one before; a trailing comment attaches to its own line; a block
comment's bytes are retained verbatim; two blank lines between declarations are
retained as a run rather than as two facts; a file with no comments produces an
empty trivia table and no allocation growth per parse.

Two of this task's expectations did not survive measurement, and the shape
changed with them.

**The parser is the wrong place to retain trivia, for two reasons neither of
which is style.** The tokenizer backtracks: `saveState` and `restoreState`
re-scan the same bytes, so a sink filled inside `skipWhitespaceAndComments`
would record a comment once per lookahead and need a high-water mark to undo
what the design created. And `Parser.initWithProfile` returns the parser by
value after consuming the first token, so a sink pointer taken inside it either
dangles or misses the leading trivia of the file.

What landed instead is `parser/trivia.zig`, which drives the tokenizer over the
source a second time and reads the gaps between consecutive tokens. That is
exact rather than approximate, and it is the reason the pass rides the tokenizer
at all: the bytes between one token's end and the next token's start are
whitespace and comments by construction, so the gap scanner needs no string,
template, or regex handling to avoid reading `"// not a comment"` as a comment.
A byte scanner would have deleted half a string literal, and there is a test
that says so.

**Attachment is a query, not a field.** The IR pin is not moved and no node
grows a pointer: a node carries the byte span of the token that opened it, so
"the comments directly above this node" and "the comment on this node's line"
are both answerable from the trivia list and the node's own offset.
`leadingFor` and `trailingOn` are those two queries.

One limitation is named rather than left to be found: a bare tokenizer run is
not in JSX mode, since only the parser turns that on, so a gap inside JSX text
is reported as whitespace. No layout rule reads JSX text yet, and the printer
will need its own answer when it covers JSX.

The gate under all of it is that the tests run at all. The first probe of them
passed while asserting nonsense, because the probe's own edit did not match the
text it meant to change - the test file was never recompiled. Re-probed against
the actual assertion, the suite fails and names
`trivia.test.two blank lines are one run, not two facts`, which is what makes
the passing run mean something.

### Task 7: the canonical formatter, fail closed

**Files:** a new `packages/zts/src/printer.zig`,
`packages/tools/src/canonicalize.zig`, `packages/tools/src/zts_cli.zig`.

An IR-to-source printer under D3 section 2's layout rules: two-space indent, 80
column soft target, double quotes, semicolons always, trailing commas in
multi-line lists only, one blank line between top-level declarations, records
and arrays on one line when they fit, one `match` arm per line, binary chains
breaking before the operator, import specifier order preserved, comments never
reflowed.

It refuses with `error.UnprintableConstruct` for any construct it does not
cover, and `normalize --write` declines with it. Coverage is widened construct
by construct, and the corpus is the measurement: a file the printer refuses is
named in the gate output rather than skipped silently.

The rules were chosen to match the repository's existing sources so the corpus
does not churn. Whether that holds is measured in this task rather than
asserted, and a rule that would rewrite the corpus is either justified in the
plan or changed.

**Tests:** printing a parsed file and re-parsing it yields the same IR modulo
positions and trivia, over every tracked source file; printing twice is byte
identical; a construct outside coverage returns `UnprintableConstruct` rather
than approximate bytes; a comment survives a print and stays attached to the
same declaration; the corpus churn measurement is recorded, file count and line
count.

Four of this task's expectations did not survive measurement.

**The IR cannot print this repository's sources, because it does not hold
them.** `stripper.strip` blanks every type annotation before `JsParser` sees
the text, so the parsed IR is type-erased. A printer over it would delete every
`: T`, every `type` and `interface` declaration, and the `import type` clause of
23 of the 58 tracked example files - and `TypeMapKind` has no member for a
type-only import, so that last loss is not recoverable from the side table
either. What landed prints from the token stream of the source as written, plus
the trivia pass from task 6 and the stripper's type map. Every token is carried
through verbatim and only the whitespace between tokens is decided, so
annotations, `import type`, `0xff`, and a template literal's interior survive by
construction rather than by a rule that remembers them.

**Fail closed is enforced rather than declared.** The printer re-lexes its own
output and compares the token sequence, and the comment sequence, against its
input; a mismatch is `error.UnprintableConstruct`, not a written file. The one
difference the layout rules may make - a trailing comma before a closer - is
normalized on both sides before the comparison. Two hazards the token
comparison cannot see are refused up front instead: a statement that ends
without `;`, and a newline after `return`, `break`, `continue`, or `throw`,
both of which ASI terminates where a printer would close them up.

**Types are opaque, which is a rule this plan did not have.** A type
annotation, a type argument list, and a whole type declaration print as the
bytes the author wrote. The stripper already decided where each starts and
stops; re-deciding it here would be a second answer to a settled question. The
canonical form of this phase therefore does not canonicalize type layout, the
same way it does not reflow a comment. It also takes the `<` ambiguity out of
the layout engine: a `<` the stripper did not record is a comparison and prints
spaced like one.

**Two of D3 section 2's layout rules were wrong about the corpus they cite, and
one was silent about a case the corpus is full of.**

| Rule as written | Measured | What shipped |
|---|---|---|
| 2-space indent, "chosen to match the repo's existing `.ts` sources" | 52 of 58 corpus files are 4-space | The rule stands and the corpus moved to it, which is the decision recorded here rather than left implicit: the canonical form is normative and the corpus is its output. Docs fences already lean 2-space, 289 lines to 260 |
| "exactly one blank line between top-level declarations" | Applied literally this inserts a blank between every consecutive `import` | Changed: a blank-line run collapses to one and is preserved where the author put one; none at file start, exactly one newline at file end |
| `match`: one arm per line | Arms carry no separator at all - `when P:` and `default:` are what end the previous arm, and the rewriter's own output uses commas | Both shapes lay out; splitting the body on commas the way a list is split put every arm of the corpus onto one line, which is how the shape was found |
| (silent) | The corpus is full of `Response.json({ ... })` and `resource(order, { ... })` | Added: a call hugs a record, array, or block in its last argument, keeping the brackets on the call's line. Without it the same content is indented twice for two lines of punctuation. It hugs only when the arguments before it are plain: `f({ ... }, { ... })` would otherwise open the second record on the line the first one already fills |

**Corpus measurement, 2026-08-11.** 58 tracked files, 2331 lines. 53 print, 5
refuse, and every refusal is the same construct: JSX and TSX, which a bare
tokenizer run cannot read because only the parser turns JSX mode on. Of the 53,
6 were already canonical, 4 are left in the author's layout because they need a
rewrite that would delete what they demonstrate, and 42 were reformatted: 556
lines added, 459 removed, dominated by the 4-to-2-space reflow. The diagnostic
code multiset of `zts check` is identical before and after printing for 49 of
53; the four that differ are the rewrite loop's own doing (a canonical-band code
it cleared, and one `ZTS500` the cleared ternary unmasked), not the layout's.

`scripts/check-normalize-idempotent.sh` names each unprinted file and carries a
ceiling of 5 that may fall and may not rise, next to the floor of 58 it already
had. Double-normalize byte-identity holds over all 58, printer included: the
phase's exit clause.

### Task 8: the M1 and M2 validators

**Files:** `packages/zts/src/repair_validator.zig`,
`packages/tools/src/agent_protocol.zig`.

M1 prints both sides with the task 7 printer and compares bytes. M2 parses both
sides and compares the IR trees modulo source positions and trivia. Both are
mechanical once their inputs exist, and both are independent of any particular
rewrite, which is the point: a validator that reused a rewrite's own scanner
would re-derive the same wrong answer and agree with itself.

`flatten_destructure` and `drop_unused_index_alias` move from `.planned` to
`.implemented` under M2, which makes the one wired idiom row gradable and
therefore eligible for `apply_repair`. The three M3 rows stay `.planned` with the
kernel deferral recorded on the row rather than in prose only. The two M5 rows
stay advisory-only by construction.

**Tests:** M2 accepts a rewrite that changes bytes and not structure and rejects
one that changes structure; M1 accepts a layout-only difference and rejects a
token change; a `.planned` row cannot set `repair_available`, asserted by
walking the table rather than by naming one row; `apply_repair` now accepts
`drop_unused_index_alias` and still refuses an intent whose row is `.planned`;
the coverage test that proves the intent enum and the row table cannot drift
still passes.

### Task 9: the three meta rows that already have a source

**Files:** `packages/tools/src/agent_protocol.zig`,
`packages/zts/src/known_globals.zig`, `packages/zts/src/type_key.zig`.

`ambient_names` is generated from `known_globals.names`, which is the closed
ambient table section 6 describes and which now carries the phase 4 and phase 5
additions. `type_serialization` is generated from `type_key`'s canonical type
serialization, published with its version so a client can tell whether the
type-graph identities it cached still apply. Both rows are marked in
`deferred_sections` as waiting on phases that have closed, so both are stale
deferrals rather than missing mechanisms.

`repair_budget` is different and is decided here rather than carried: the
repair-iteration and tool-call budget is a loop policy no code implements, so
either the policy lands with a number the loop enforces, or the row stays
deferred with that sentence. Publishing a budget nothing enforces is the shape
this repository has been bitten by, and the existing test that asserts
`limits.repair_iterations` is absent is what would have to be deleted to do it.

**Tests:** `ambient_names` lists every entry in `known_globals.names` and
nothing else, so adding a global without publishing it fails; `type_serialization`
carries a version and the digest algorithm, and two independently parsed
identical types serialize identically; the `deferred_sections` list shrinks by
exactly the rows this task closes; `meta`'s advertised key set and its emitted
key set still agree key for key.

### Task 10: the grammar and examples registries

**Files:** a new `packages/zts/src/grammar_registry.zig`, a new
`packages/zts/src/example_registry.zig`, `packages/tools/src/agent_protocol.zig`,
`scripts/check-docs-drift.sh` or a sibling gate, `build.zig`.

`grammar` publishes spec section 8's productions member for member, from a
registry, drift-gated against the document. The section is an over-approximation
by its own preamble: several productions admit forms the prose excludes, and the
registry records per production whether enforcement happens at parse time or at
check time, which is what makes the published grammar usable rather than
misleading.

`examples` publishes one canonical minimal example per admitted surface form, so
an agent can learn `match`, `distinct type`, `assert`, `comptime()`, and
`parallel` from the protocol rather than from hidden instructions. The examples
are checked source: each one is compiled by the test that publishes it, so an
example that stops being legal fails the build rather than teaching a form the
compiler refuses.

**Tests:** every production in the document appears in the registry and the
reverse; a production whose enforcement point is wrong fails the gate; every
published example parses, checks, and exercises the form it names; deleting a
form's example fails rather than shrinking the list silently; the drift gate
fails on an empty extraction.

### Task 11: decisions, contract body, and extension manifests

**Files:** a new `packages/zts/src/decision_registry.zig`,
`packages/tools/src/agent_protocol.zig`,
`packages/zts/src/handler_contract.zig` or the contract serializer,
`packages/tools/src/module_graph_record.zig`.

Three remaining `deferred_sections` rows, in ascending order of cost.

`decisions` is the versioned registry of next-action and semantic-decision kinds
that unsupported results and explanation graphs reference, each with an
identifier and a parameter schema. The kinds exist as strings at their emission
sites today; this makes them data.

`contract_body` needs a snake_case contract serializer. `writeContractJson`
emits mixed-case version 1 keys, so `check` publishes `contract_available` and
sends the client elsewhere for the body. Version 1's shape is frozen and stays
frozen: the version 2 serializer is a second writer over the same contract, not
a rename of the first.

`extension_manifests` needs an authenticated `zttp-ext:` manifest. Nothing
authenticates one today, so every extension specifier reports unavailable and
the list is empty. If authentication is larger than this phase, the row stays
deferred with a measured reason and the note names the phase that closes it -
which is the same discipline the row already follows, not a retreat.

**Tests:** every decision kind emitted anywhere resolves to a registry row, and
a row nothing emits fails the same test; the version 2 contract body round-trips
through a parser and carries only snake_case keys; version 1's output is byte
identical to what it emits today; an extension specifier with no authenticated
manifest is reported unavailable rather than omitted.

### Task 12: the lexical tightenings

**Files:** `packages/zts/src/parser/tokenizer.zig`,
`packages/zts/src/parser/parse.zig`, `packages/zts/src/stripper.zig`,
`packages/tools/src/json_diagnostics.zig`.

D3 section 1's six divergences become errors. The error kinds mostly exist, so
the work is emitting them from sites that today accept.

A backslash before a real newline inside a string yields a literal newline;
it becomes an error. An unknown escape copies its byte; it becomes
`invalid_escape_sequence`, which closes the escape set. `0x` with no digits and
`1e` with no exponent become `invalid_number`. `0755` becomes an error naming
legacy octal, because leading-zero-then-digits is ambiguous to every reader; the
message names the fault even where the code is reused. A non-ASCII byte inside
an identifier is reported once per run rather than degrading into three
cascading parse errors.

The unterminated string is the one that is worse than D3 recorded. The type
stripper raises `error.UnterminatedString` before the parser runs, and
`zts check --json` answers `success:false` with an empty diagnostics array: a
machine client is told the file failed and told nothing about why. The stripper
reports it as a located diagnostic with the existing ZTS008 code.

A new code is minted only where an existing kind would name the wrong fault, and
each mint says which kind it rejected and why. Free from ZTS045 upward.

**Tests:** each of the six forms reports its own code and a location; the
non-ASCII case reports once rather than three times; `check --json` never
answers `success:false` with an empty diagnostics array, asserted as a property
over every fixture rather than for the one input that motivated it; a legal
escape, a legal hex literal, and a legal exponent still parse; the corpus is
unaffected, measured rather than assumed.

### Task 13: ASI removal

**Files:** `packages/zts/src/parser/parse.zig`,
`packages/zts/src/parser/token.zig`, `packages/tools/src/canonicalize.zig`,
`packages/zts/src/rule_registry.zig`, tracked source under `examples/`.

Spec 5.5 mandates no automatic semicolon insertion. Two sites implement it, not
one: the `return` case, and the general acceptance of an implicit semicolon
after a closing brace or at a newline. A handler written with no statement
semicolons parses clean today, so this is a statement-termination change.

The order is forced. First measure: count the tracked files and statements that
rely on insertion, before changing anything, because that number decides whether
the flip is mechanical or a migration. Then the repair: a semicolon-insertion
rewrite whose equivalence is discharged by M2, which is the unique-parse
argument the spec makes and which task 8 makes available. Then the refusal, so
no program is left without a mechanical fix. The seven never-produced `jsx_*`
token kinds and the never-produced `newline` kind are deleted with it.

**Tests:** a statement with no terminating semicolon is refused, with the
insertion repair attached; applying that repair produces a file whose IR is
identical to what the ASI parse produced, which is the unique-parse property
stated as a test rather than as prose; `return` on its own line is refused with
the same repair rather than silently yielding a bare return; the whole corpus
checks clean after the migration; the deleted token kinds are unreferenced,
verified by the build rather than by a grep.

### Task 14: the exit gate

**Files:** `scripts/check-normalize-idempotent.sh`, a new
`scripts/check-meta-drift.sh`, `scripts/verify.sh`, `docs/coverage.md`,
`docs/convergence.md`, `docs/roadmap.md`.

The roadmap's exit sentence, made executable, with its input floor asserted
before its verdict means anything.

**Byte-identity over the whole corpus.** With the formatter total over the
corpus, the idempotence gate runs with zero skips, or each remaining skip names
a construct the printer refuses and that construct is listed. The floor: the
checked count is asserted, deleting the input fails the gate, and a file whose
second normalize changes one byte fails it.

**Atomic `apply_repair` rejection.** Re-confirmed rather than newly built: the
four existing tests are run against the span-keyed vocabulary task 4 introduced,
since a vocabulary change is exactly what would break them quietly. A rejected
set leaves the file byte identical, asserted against the file's digest and not
against its length.

**Meta drift gates in `scripts/verify.sh`.** The unit tests that compare the
live `meta` response to the registries already run inside `zig build test`. What
this adds is the gate over the registry hashes themselves: `policy_hash`,
`idiom_table_hash`, `restriction_matrix_hash`, and `builtin_registry_hash` are
read from a live response and compared to pinned values, so a registry edit that
nobody meant to publish fails here. The floor: deleting a registry row changes
the hash and fails the gate, which is the probe, and it is read from the exit
status.

`docs/coverage.md` and `docs/convergence.md` are regenerated in the same commit
as whatever changes them. The roadmap's phase 6 row is closed with what the
phase actually delivered, including anything it left open with its reason.

---

## Risks

The formatter is the largest single cost in the language program and it can fail
closed indefinitely if trivia attachment is subtly wrong: the printer would
refuse constructs forever while every gate stayed green, because a refused file
is a skip rather than a failure. The defense is task 1's floor and task 14's
zero-skip requirement, which turn a permanent refusal into a visible one.

Splitting the canonical count into a progress measure and a verdict is a change
to what `--check` fails on, which is a CI gate for anyone using it. A rule
misclassified as advisory would silently stop failing builds. The floor is a
table test that asserts each rule's severity by name, so a restriction that
becomes an advisory fails the test rather than the user.

The span-keyed vocabulary collapse touches every producer and every consumer of
a repair, including the two in `packages/pi`, where no proof-swallow gate
exists. The staleness check is the defense and its floor is that a moved
snapshot still refuses; the class that destroyed a file in `pi` before was an
empty baseline proving an edit clean, and the same shape here would be an empty
span proving an apply safe.

ASI removal changes what the parser accepts for source nobody edited, and the
corpus is the measurement. The repair lands before the refusal for exactly this
reason, and the pre-flip count is recorded in the plan rather than discovered
during it.

Adding six idiom rows re-runs the confluence harness over a larger pair set. A
new row that does not join is a build failure by construction, and the repair is
a rule change rather than a fixture: `known_non_joining` is empty today and the
harness fails on a listed pair that starts joining, so the list can only shrink.

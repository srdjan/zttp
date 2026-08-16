# Advanced ZTS language program: the closed phases

Archived 2026-08-16, lifted verbatim from `docs/roadmap.md`.

Phases 0 through 7 of the advanced language program are done. Each phase below
records what the work actually found, including the places a measurement did not
support the expectation the plan was written on, which is why the text is kept
instead of a line saying "done".

`docs/roadmap.md` keeps what still binds: the three ground rules, the D1 to D3
design documents the phases consume, and the settled migration policy.

Counts and file names below were true when each phase closed. Read them for why
a decision was made, never for how the code works today.

## Phase narratives

Phase 2 met its exit against the frozen signature corpus: 24 modules and 90
exports, every emitted signature parsing with no fallback to `unknown`, and
pinned digests. Assignability amendment A1, which makes an unresolved name an
error rather than `true`, was the one piece of its scope left open, and it is
closed. It had been deferred to phase 5 on the reading that it needed the ABI
types and the durable and queue exports retyped; re-measuring found three causes
and only one of them was that.

A name nested in a compound type never resolved, because the pool holds no alias
table: `getOne(): Todo` checked and `getTodos(): Todo[]` did not. `durable.run`
returns its callback's type, which `ReturnKind` cannot spell, so it declared the
coarse `unknown`. And `Response.json()` inferred nothing, so the handler return
check has been passing by never running - a fact the fail-open kept invisible.
The three fixes are `TypePool.RefResolver`, `FunctionBinding.returns_from_param`,
and `abi_types.zig`. Zero of 55 examples report the A1 signal now.

What that leaves for phase 5 is the ABI itself rather than A1. `abi_types.zig`
describes today's shipped `Response`, not spec section 7.2, which renames the
constructors to `responseJson<T>: Result<Response, JsonError>` and types the
request side over `Bytes`, `Dict`, and `JsonValue` - none of which exist before
phases 3 and 4.

Phase 3 met its exit: `JsonValue` minus the Dict arm compiles, and the `null`
literal pattern plus the four type tests cover it with no `default`, which
dropping one arm undoes. Four things it found are worth carrying forward.

`null` needed no kernel work - `push_null` and `JSValue.null_val` have shipped
all along - but it needed the two sentinels held apart in four places that had
quietly conflated them: the type parser mapped the identifier `null` to
`unknown` behind a pinned test, the nullable node accepted a `null` source, its
printer spelled `T | undefined` as `T | null`, and the boolean lattice treated
`x !== null` as an absence test that strips optionality. Admitting `null`
turned each of those from harmless into wrong.

Contractivity was the only missing piece of recursive aliases. The alias graph
and amendment A2's assumption set already carried them: the spec's `JsonValue`
compiled, assignability terminated, and match and join over it did too. What
was missing was the refusal, and `type Loop = Loop` reported a type mismatch
rather than the cycle.

The strict profile demanded a `default` arm on every match, so the spelling
spec 5.5 requires of a closed union - every member covered, no default - was
the spelling it refused. It measures coverage now.

The exit's own example is not the spec's: capsule discharge does not admit a
recursive helper, so a handler that declares a `Spec` cannot call one.
`examples/patterns/recursive-json-value.ts` therefore walks one level and the
recursive fold is pinned as a type-checker test. That limit is the next thing
this program touches on the proof side, not the type side.

Phase 4 is closed, and its plan is
[docs/plans/2026-08-09-023-zts-advanced-rev4-phase4-plan.md](../../plans/2026-08-09-023-zts-advanced-rev4-phase4-plan.md).
`Dict<K, V>` is a runtime class of its own, since a JS object is hidden-class
shaped and cannot hold an arbitrary key, a number key, or an insertion order.
Entries live in the object's own slots so the GC traces them through the walk it
already runs; lookup is a linear scan and copy-on-set is quadratic over the fold
construction form, both recorded as measured-when-it-matters rather than
optimized on a guess.

Two things the behavioral suite found that serving a handler by hand did not: a
Dict built outside the request arena leaks per request, and the parser's
duplicate-key failure borrowed a key it had already freed. The suite is also
what forced the twelve new exports to carry the audited `replay_pure` opt-in -
without it a handler test sees `undefined` from every one of them, because a
replay stub with no recorded I/O returns exactly that.

The `unwrap` refusal this phase planned turned out to exist already: the
modelled `Result` is a record with no methods, so `r.unwrap()` reports
`property does not exist on type`. The rule was written, measured against the
corpus, and deleted. The same measurement found that `r.unwrapOr(d)` is refused
too, which spec 6.1 admits - the deferred `zttp:result` track is what supplies
it, as a free function rather than a method.

That track closed the phase, and three of its findings are worth carrying.

Effect-row polymorphism needed no mechanism. The combinators declare `.none`
and reach nothing themselves; the join comes from `effect_inference` already
walking a callback argument into the enclosing row. Both directions are pinned,
because a combinator that always contributed its callback's worst case would
satisfy a test that only checked the effectful one.

`zttp:collections` and `zttp:json` were laundering data labels. Neither
declared `return_labels`, and an export that declares nothing answers the empty
set, so a secret put into a `Dict` and read back out reached the response with
`no_secret_leakage` PROVEN. `FunctionBinding.derives_from_args` is the repair -
`parsedResultLabels` without the `user_input` discharge, so "the data passes
through" and "and validating clears `user_input`" stay separable claims.

Sweeping the rest of the registry rather than reasoning about which modules look
like security boundaries found twenty-one more, across six modules: every export
that takes a value and returns something built from it, `slugify` and `urlEncode`
alongside `sha256` and `base64Encode`. One survived - `escapeHtml`, because it
declares `validated` and had been fixed already. Regenerating the goldens after
the sweep moved a checked-in contract fixture from "the value stays contained"
to a flow chain ending in the response body, which is what the fixture had
always done.

Spec 6.2's `comptime(dictFromEntries([...]))` does not land, for a reason the
plan did not anticipate. Reaching a module export from the comptime evaluator
would be a small addition; the obstacle is that the channel emits source text,
and a `Dict` has no literal spelling to emit - which spec 6.2 says itself, since
construction is a module call. The form fails the build rather than evaluating
to something else, which is the part that had to be checked: it exists for a
duplicate-key discharge, so a silent answer would be worse than none.

Phase 5 is closed, and its plan is
[docs/plans/2026-08-09-025-zts-advanced-rev4-phase5-plan.md](../../plans/2026-08-09-025-zts-advanced-rev4-phase5-plan.md).
Four of its ten tasks found an expectation that measurement did not support,
and each is recorded there beside the work rather than resolved silently.

The exit gate is `examples/patterns/bytes-boundary.ts`: a body read as `Bytes`,
decoded, parsed with `parseJsonBytes`, dispatched through the six type tests
including `when Bytes:`, labelled by a helper with a trailing default, and
returned through a constructor the encodability rule admits. Its floor was
probed rather than assumed. Changing the default's value fails exactly one test;
dropping the ceiling from the exported helper the handler never calls raises
ZTS610, which reported nothing before this phase; deleting that helper leaves
the file clean.

The first floor probe did not fail, and that is the finding worth carrying.
Replacing the omitted argument with the default's own value spelled explicitly
left every test passing, because the assertion was on the value produced rather
than on the omission producing it. A test that pins a default by naming the
default's value passes for a program that never selects a default. What
distinguishes them is changing the default itself, which is the probe that
belongs in the gate.

Phase 6 is done, and its plan, amended throughout with what each task actually
found, is
[docs/plans/2026-08-10-026-zts-advanced-rev4-phase6-plan.md](../../plans/2026-08-10-026-zts-advanced-rev4-phase6-plan.md).

The canonical formatter exists and prints 53 of the 58 corpus files; the five it
refuses are JSX and TSX, and the idempotence gate names each one rather than
counting it as coverage. Double-normalize byte-identity holds over all 58. The
idiom table is the spec's full 24 rows, the advisory channel no longer decides a
build, and the validator registry grades under M4. M2 was deleted mid-phase after
measuring that it discharged nothing, and returned when ASI removal gave it a
consumer; its one row went back to `.planned` when the semicolon repair was
withdrawn, so six rows are gradable today and all six are M4.

`meta` went from ten `deferred_sections` rows to three, and the three that
remain are decisions rather than schedules: an authenticated `zttp-ext:`
manifest needs a trust policy with issuers, key pinning, rotation, and
revocation; per-rule severity is chosen at each emission site, so no table can
answer it; and the repair budget is a client's loop policy that nothing here
enforces. What closed carries its own gates - section 8's grammar is drift-gated
against the document, every admitted surface form has a compiled example, and
every decision kind a refusal can carry is emitted somewhere.

Two rules the spec had always stated became true of the compiler this phase.
The six lexical divergences of D3 section 1 now report with a code and a
location, including an unterminated string, which used to answer `success:false`
with an empty diagnostics array. And spec 5.5's no-ASI rule holds: the corpus
needed no migration, measured at 0 of 58 files before anything changed. The
semicolon repair that landed with it was withdrawn days later, when a review
found it reading line numbers from a stripped parse, writing the `;` into
trailing comments, and certifying meaning-changing edits as equivalences.

Writing the per-form examples found five defects, three of which made an
advertised admitted form unwritable: `let` was refused in every exported handler
and its annotation was ignored, an object spread contributed its operand's name
instead of its fields, a used destructured binding read as unused, and a
template literal type was not assignable to `string`.

Phase 7's compiler cutover is implemented. `structural` and scalar `nominal`
are the only declaration spellings, boolean contexts accept only booleans,
text construction uses explicit `join` or `String`, and TSX lowers through the
`zts-tsx-1` frontend before the `zts-model-1` core parses it. The compact grammar
publishes 66 admitted productions and the idiom registry publishes 18 legal
preferences; removed forms live only in the restriction registry. Source
profile and grammar identity now flow through contracts, caches, receipts,
attestations, capsules, and Pi session evidence.

Two findings came out of that slice. `distinct type Bad = { a: number };`
checked clean, while the published grammar has said `ScalarType` at that
position since the registry was written and marked the row `parse_time` - the
grammar was right and nothing enforced it. Both spellings now refuse a
non-scalar base with ZTS048, located at the base rather than the declaration.
And the example registry's evidence model cannot see a keyword: `structural`
and `type` share the `type_alias` map kind by construction, so a kind-based row
would have been satisfied by an example that wrote `type` throughout. Both new
rows carry source-text evidence with that reason, and swapping the keyword in
the example fails the gate.

`interface` is the first form phase 7 removes, and it is gone in both halves.
Five tracked files declared one, all plain records, so the migration to
`structural` changed no contract golden. The form is now refused with ZTS049,
recognition-only in the sense the plan asks for - the body is scanned so the
span is known and the repair is exact, and no type-map entry is recorded, so
the resolution side could be deleted rather than left dormant. What went with
it is the heuristic that made an all-function interface nominal, which is the
hidden exception the plan names: an identity no declaration expressed, minted
by counting a record's fields. Nominal identity now comes only from a `nominal`
declaration over `string` or `number`.

`restriction.interface` left the unenforced set with it. It had carried the
note "blocked on the migration policy the D workstream owes" and now names
ZTS049, so the count of rows with no rule code behind them fell from three to
two. That moved `restriction_matrix_hash` and not `policy_hash`, which is the
distinction those two identities exist to draw: what the matrix says changed,
and the rule set that judges a file did not.

`|>`, `pipe()`, and `guard()` went next, and the module under them with them.
Two examples used the operator, so the migration was two files: a direct call
in one, and explicit early-return guard flow in the other, pinned by comparing
`zts check --json` before and after - identical properties, identical
proofTrace verdicts, identical diagnostic codes. The operator now reports
ZTS001 naming the direct call, at the operator's own span. It keeps its
precedence row so it is recognized there rather than falling out as an
unexpected token wherever the expression happens to end, and it builds no IR.

`zttp:compose` is deleted, taking the module surface from 24 specifiers to 23 at
that point; later phases grew it back, and `zttp modules` is the live count.
Its two exports were compile-time forms wearing a module's clothes: the parser
replaced every use, so the native implementations shipped and never ran. What
went with them is 313 lines of parser desugaring - the guard-chain lowering
that synthesized an arrow function with generated bindings, the `pipe()` call
fold, and the two import-tracked binding slots that armed both.

The comptime profile had its own branch refusing `|>` with `unexpected_token`,
which is gone: there is one refusal now, in both profiles. That costs one thing
worth recording. `mapParserError` folds the whole `unsupported_feature` kind
into `ComptimeError.UnknownIdentifier`, so `comptime("a |> f")` now reports an
unknown identifier and sends the reader looking for a typo. The mapping is
equally wrong for `new` and `while` on the rows beside it and predates this
change; correcting it means re-pinning every row that reaches it.

`type` and `distinct type` went next, and with them the declaration keywords
are settled: `structural` and `nominal` are the only spellings. 65 declarations
across 50 tracked handlers migrated, plus 88 in Zig-embedded test sources, and
all 65 were top-level and unexported, so the rewrite was one shape. `import
type` and `export type { ... }` keep the keyword - each names a declaration
made elsewhere rather than making one, and the stripper handles both before the
declaration path. The old spellings report ZTS050 and ZTS051 at the
declaration's span with the exact repair, recognition-only and recording no
type-map entry.

Two files a keyword sweep must not take, both caught by their own gates and
both the same lesson: a `.ts` file is not necessarily zts source.
`generateTypeDefs` emits `zttp.d.ts` for `tsc`, which has no `structural`
keyword. The other is a digest-pinned recorded model turn, where an edit is an
edit to the measurement.

Boolean-only control flow is now enforced by the checker and runtime. `if`,
conditional expressions, `!`, `&&`, `||`, assertions, and collection
predicates require a boolean. Optional and unknown values fail closed instead
of participating in truthiness, so absence must be written explicitly as
`value === undefined` or `value !== undefined`. The internal witness tags keep
their existing names, but they are now derived from explicit comparisons or a
module result whose declared return type is boolean. The published core profile
is `zts-model-1`; optional and unknown values do not regain truthiness through
a compatibility path.

The source frontend is now one owned boundary, and file identity is explicit:
`.ts` enters the core, `.tsx` enters the TSX lowering frontend, and `.js`,
`.jsx`, and unknown extensions fail with ZTS052. Valid TSX is lowered to
ordinary `h(...)` calls before parsing; its offset map composes with TypeScript
stripping, so both malformed-tag diagnostics and later core diagnostics point
back to the authored file. The core tokenizer, parser, IR, checkers, and
bytecode generator no longer contain a JSX mode or JSX-specific nodes.

Proof and effect capsules are ambient now. `Proof<T, P>` replaces the old
intersection marker, `Effects<T, R>` keeps its ceiling role, and the synthetic
proof-type module is gone. A stale import reports ZTS053 rather than being
silently erased. The raw event and provider recordings remain historical; live
source, examples, scaffolds, diagnostics, and owned goldens use the ambient
forms.

Parameter defaults and optional-parameter shorthand are also gone. ZTS054
directs `name: T = value` to `name: T | undefined` plus a visible resolution at
the start of the body, and ZTS055 directs `name?: T` to the same explicit union.
The raw parser refuses both forms after source preparation, and the former
minimum-arity, type-check, IR flag, and bytecode-default paths were deleted.
Calls now supply every fixed positional argument, including explicit
`undefined` when selecting a body-level fallback.

Module declarations now have one public spelling as well. ZTS056 refuses every
default export in favor of a statically named declaration, and ZTS057 refuses
`export let` because mutable state is activation-local. The raw parser no
longer builds a default export node or a mutable export declaration, and the
last live default handler fixture now uses `export function handler`.

The type vocabulary has one spelling per array and absence shape. ZTS058 and
ZTS059 replace the generic array aliases with `T[]` and `readonly T[]`, and
ZTS060 replaces the `void` type with `undefined`. Unary `void` is an explicit
ZTS001 refusal because preserving an effectful operand requires a statement,
not a token substitution. The alias normalization and unary IR/bytecode paths
were deleted after the authored-source gates went green.

Statement syntax now has no inert forms and one catch-all spelling. `debugger;`
and standalone empty statements are ZTS001 refusals with removal guidance, and
`when _:` is refused in favor of `default:`. Their parser IR and bytecode nodes
were deleted once the front-door refusal tests passed.

The post-cutover DeepSeek corpus was recorded live and replay-validated on
2026-08-16. It contains 19 promoted flows: 9 passed on the first draft, all 19
reached green, all 13 intent-bearing cases preserved declared intent, and the
median successful flow used 5 round trips. Compaction occurred in the long
cases and is replayed through the same request controller used in production.
Promotion required a green result, so failed live samples could not replace an
active artifact. These measurements replace the stale pre-cutover cassettes
rather than rewriting their answers.

That result closes phase 7's convergence exit without a compatibility profile
or a relaxed checker. The language, identity, diagnostic, classification, and
live-model cuts are complete; future protocol and repair work can improve the
first-draft rate without weakening this boundary.

The last thing the compose import held up was rate limiting. `detectRateLimiting`
required that import plus a `cacheIncr` call, and no handler in the repository
ever satisfied both, so `rate_limiting` and the deploy manifest's
`rate_limit_namespace` had never once been produced by a compile and no test
asserted they could be. Meanwhile `zttp:ratelimit` had declared a
`rate_limit_key` extraction on `rateCheck`'s first argument all along, and
`getCategoryTarget` mapped that category to null. The detection answers from
the primitive now, and three tests give it the floor it never had.

| Phase | Scope | Exit |
|---|---|---|
| 4. Dict, JSON, Result completion | `Dict` and `zttp:collections` with persistent semantics, SameValueZero keys, and insertion order; `zttp:json` with a closed error taxonomy and policy-driven limits; `zttp:result` completion (`unwrapOr`, `orElse`, `collectAll`) with effect-row-polymorphic combinators per D2. | Dict determinism and SameValueZero tests; JSON round-trip and limit tests; `collectAll` first-error test. **Done.** |
| 5. Bytes, ABI re-typing, defaults, Effects ceiling | [`Bytes` and `zttp:bytes`](../../plans/2026-08-09-025-zts-advanced-rev4-phase5-plan.md); the HTTP, queue, and durable ABIs re-typed to the spec's 7.2 shapes including total `responseText` (the WebSocket subsystem was removed rather than re-typed); trailing scalar default parameters; the decidable `Effects`-ceiling rule with repairs computed from the inferred row. | fetch and queue examples re-typed; ceiling-rule repair tests. **Done**, with the function-type ceiling landed for the empty row and blocked for a nonempty one - a function type whose return carries a capsule does not survive the checker, which is a type-representation fix recorded in the plan. |
| 6. Full idiom table, validators, gate-complete protocol | [The remaining idiom rows](../../plans/2026-08-10-026-zts-advanced-rev4-phase6-plan.md); equivalence validators per D3's method taxonomy, with any row lacking a registered validator shipping advisory-only; fixed-point normalization with a published pass bound; batch `apply_repair` and multi-property `verify`; the full registry-generated meta payload set. | Double-normalize byte-identity over the whole corpus; atomic `apply_repair` rejection tests; meta drift gates wired into `scripts/verify.sh`. **Done.** The current model-minimal idiom table is 18 rows. Six validator rows are gradable, all under M4; the M2 row went back to `.planned` when the semicolon repair was withdrawn. `deferred_sections` fell from ten rows to three, and the three that remain are decisions rather than schedules - an authenticated extension manifest needs a trust policy, and per-rule severity and the repair budget are questions no registry here can answer. Spec 5.5's no-ASI rule holds; the semicolon repair that shipped with it was withdrawn in the same phase after a review found it unsound, so a program that needs terminators is refused with a location and fixed by hand. |
| 7. Model-minimal direct cutover | [`zts-model-1` and `zts-tsx-1`](../../plans/2026-08-09-024-zts-model-minimal-phase7-plan.md); explicit `structural` and scalar `nominal` declarations; boolean-only control flow; one canonical syntax for modules, parameters, objects, callbacks, guards, and text; TSX as a lowering frontend rather than core syntax. | **Done.** Zero removed forms in tracked source; every removed form has one diagnostic and repair or refusal; `spec-check` classifies all 69 nodes and 127 opcodes; 19 of 19 post-cutover DeepSeek flows reached green, 13 of 13 intent-bearing flows preserved intent, 9 of 19 passed on the first draft, and the median was 5 round trips. |

## How the four carried risks landed

Four risks were carried across the phases. The generics retrofit in phase 2 had
the long tail the plan named, and the frozen signature corpus is what bounded it;
what the corpus could not bound was A1, and the sweep over every example is what
bounded that instead - seven failures, each traced to a cause before any of them
was fixed. Normalization in phase 6 may not be confluent, mitigated by running
the double-normalize property test from day one and falling back to
advisory-only rows. Hand-written meta payloads would multiply drift gates, which
is why the program's ground rules ban them. Silent decisions leaking into wire
formats is why D1 lands before phase 2, D2 before phase 4, and D3's digest
section before the phase-1 hash freeze.

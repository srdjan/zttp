# Phase 4: Dict and JSON - Implementation Plan

**Goal:** Give the profile its dynamic keyed data and its JSON boundary.
`Dict<K, V>` as a real value kind with deterministic iteration and
SameValueZero key equality, `zttp:collections` over it, and `zttp:json` with a
closed error taxonomy and limits that come from somewhere rather than from a
constant in the parser.

**Exit (from the roadmap):** Dict determinism and SameValueZero tests; JSON
round-trip and limit tests.

**Scope decision.** The roadmap's phase 4 has a third track - `zttp:result`
completion with effect-row-polymorphic combinators - and it is deferred to its
own session. Dict is the dependency the other two share: JSON object nodes are
`Dict<string, JsonValue>`, `JsonValue`'s remaining arm is the Dict one, and the
`when Dict:` type test phase 3 refused by name arrives with the type. `Result`
completion depends on neither. The roadmap's `collectAll` first-error exit row
therefore stays open at the end of this phase, and the plan says so rather than
quietly narrowing the exit.

One piece of the Result track does land here, because it is independent of the
module: spec 6.1 excludes trapping `unwrap` and `unwrapErr`, which ship today as
`Result` prototype methods. They stay shipped and the canonical profile refuses
them, which is the precedent the roadmap set for the pipe operator and
`interface` - removing published surface waits for the D workstream's migration
policy.

**Source of truth:** `docs/zts-formal-spec-northstar-advanced.md` revision 4,
sections 6.1 (the `unwrap` exclusion only), 6.2, 6.4, and 5.7's `JsonValue`.

## Ground truth measured on 2026-08-09

| Assumed | Measured | Consequence |
|---|---|---|
| `Dict` can reuse the object model | `ClassId` reserves `map = 10` and `set = 11`, and neither is implemented - only `weak_map` and `weak_set` have storage. A JS object is hidden-class shaped, so an arbitrary key, a number key, and insertion order are all outside what it represents | `Dict` is a new runtime class kind with its own storage, not an object with a different tag |
| `zttp:collections` is an SDK module like `zttp:text` | The SDK's `ReturnKind` has `boolean`, `number`, `string`, `object`, `undefined`, `unknown`, `optional_string`, `optional_object`, `result` - and no `dict`. A module under `packages/modules/src/` reaches the engine only through the SDK, which cannot mint a class | `zttp:collections` lands beside the workflow modules in `packages/zts/src/modules/`, which is the tier for engine-coupled modules, and `ReturnKind` gains `dict` |
| JSON needs a parser | `builtins/json.zig` has one: `parseJsonValue`, plus `jsonParse`, `jsonTryParse`, and `jsonStringify` | The parser is reusable. What it lacks is the taxonomy - every failure is `error.InvalidJson` with no offset - plus duplicate-key rejection, a size limit, and Dict object nodes |
| Limits come from the runtime policy | `policy.zig` is an authorization policy over actors and resources. The JSON depth limit is `MAX_JSON_DEPTH: u16 = 512`, a constant in the builtin | "Policy-driven limits" has no home. The smallest honest one is a limits struct the runtime supplies, defaulting to today's 512, threaded to the parser rather than read from a global |
| `comptime` can evaluate `dictFromEntries` | `ComptimeValue` is number, string, boolean, null, undefined, NaN, infinity, array, object. There is no dict case | The spec's static-table form, `comptime(dictFromEntries([...]))`, needs a comptime dict value. Task 7 decides it on cost, and the runtime form works either way |
| `Result` is a record union at runtime | It is a native class: `ClassId.result` with three slots and a prototype carrying `isOk`, `unwrap`, `unwrapOr`, `map`, `mapErr`, `andThen`, `match` | The `unwrap` refusal is a profile rule over a call site, not a change to the value |
| `JsonValue` is blocked on Dict | Phase 3 landed `null` and the four type tests, and the alias compiles without its Dict arm | Only the arm and its type test are left |

Two further facts that decide where new code goes:

`semantics.zig` pins the IR alphabet at 82 named `NodeTag`s and the opcode
alphabet at 130. A Dict literal has no syntax - construction is a module call -
so this phase adds no node. Any opcode it adds trips the second pin and must
take a rule or be acknowledged in the same commit.

Free diagnostic codes: ZTS206, ZTS207, and ZTS213 upward in the type-checker
band; ZTS627 upward in the canonical-profile band.

## Status

Tasks 1 through 5 are done, task 8 is closed by measurement rather than by a
rule, and task 9's example and behavioral suite are in
`examples/patterns/json-and-dict.ts`.

The deferred `zttp:result` track is done. Eight exports in
`packages/zts/src/modules/data/result_mod.zig`, the roadmap's `collectAll`
first-error row pinned both as a unit test and as a behavioral row in
`examples/patterns/result-combinators.ts`. Effect-row polymorphism needed no
mechanism: the exports reach nothing themselves and `effect_inference` already
walks a callback argument into the enclosing row, which is now measured in both
directions rather than assumed.

Landing it uncovered one thing that had to come first. `zttp:collections` and
`zttp:json` declared no `return_labels`, and an export that declares nothing
answers the empty set - so a secret put into a Dict and read back out reached
the response with `no_secret_leakage` PROVEN. `FunctionBinding.derives_from_args`
is the repair, and `zttp:result` carries it from the start. The class is wider
than the three modules: `sha256` and `base64Encode` launder a secret the same
way today, probed and left open.

Task 6 landed the Dict idiom rows. ZTS627 covers both destinations of one
shape - an entry round trip goes to `dictMapValues` or to `dictFilter`, chosen
by what the transform does - and ZTS628 is the `reduce` over `dictEntries`. The
preconditions are enforced rather than described: a callback that computes a
new key is outside the map row and reports nothing, and so is an undecidable
one.

Task 7 is decided and does not land. The reason is not the one the plan
expected: reaching a module export from `evalCall` would be small, but the
comptime channel emits source text and a `Dict` has no spelling to emit.

Phase 4 is closed.

## Global constraints

- The engine stays interpreter-only. `Dict` is the value kind spec 5.3 names,
  so it is growth the spec asks for; nothing else is.
- Each admitted form adds its semantics-registry rules in the same task.
- No `meta` payload content is hand-written.
- Every task: `zig fmt` on touched files, tests in `test "..."` blocks next to
  the code, the named test step run before and after, one commit per task,
  never push.
- Phase boundary gate: `bash scripts/verify.sh` green, `zig build test` green,
  `bash scripts/test-examples.sh` green.
- A gate asserts a floor on its own input before its count means anything, and a
  probe's verdict is read from the build's exit status.

---

### Task 1: the `Dict` value

**Files:** `object.zig` (class id, slot meaning), a new `dict.zig` beside it,
`gc.zig` (tracing), `value.zig` (`isDict`), `interpreter.zig` if a call path
needs it.

`ClassId.dict` with storage of its own: an insertion-ordered entry vector plus a
hash index over it. `dictSet` and `dictRemove` return a new value, so the
storage is immutable after construction; updating a present key rewrites its
value in the copy and leaves its position, which is what "updating a present key
does not move it" means.

Key equality is SameValueZero on numbers - `NaN` equals `NaN`, `-0` equals `+0`
- and scalar-sequence equality on strings. A nominal key compares as its base
value and only within one `K` instantiation, which is a checker-side rule
(task 3), not a runtime one.

Copying on every `set` is the honest first implementation and it is quadratic
over a fold. The plan does not guess a better one: the fold form
(`dictEmpty` plus `dictSet`) is one of the three spec-named construction shapes,
so if it is too slow the cost shows up in `zig build bench` and structural
sharing is a measured follow-up, not a speculative first move.

**Tests:** insertion order survives set, remove, and update; updating a present
key does not move it; `NaN` finds a `NaN` key; `-0` and `+0` are one key; a
string key with an astral scalar round-trips; two dicts built in different
orders are not equal by iteration order.


**Measured while landing this.** A Dict built from `ctx.allocator` inside a
request leaks: the request arena is what reclaims per-request values, and
nothing else frees an object the GC never rooted. Serving the handler by hand
never showed it - the behavioral test suite did, because the test runner
allocates and destroys a runtime per case and reports the leak. Dict creation
goes through `ctx.createDict`, which picks the arena the way `createArray` and
`createObject` already do.

### Task 2: `Dict` in the type system

**Files:** `type_pool.zig` (`t_dict`, printing, canonical key, assignability),
`type_env.zig` (`Dict<K, V>` resolution, the `DictKey` bound), `type_key.zig`.

`t_dict` carries its key and value types. `Dict<K, V>` resolves like a generic
application over the two. `DictKey` is a checker-recognized bound accepting
`string`, `number`, and a `distinct type` over either - it is not a source
alias, so it is refused as a type name and recognized only in `extends`
position.

Assignability is invariant in the key and covariant in the value, which is what
a persistent read-mostly map admits. The canonical key gets a `t_dict` encoding
so two independently built `Dict<string, number>` share a digest, and a `Dict`
inside a recursive alias unfolds through the same memoized path phase 3 uses.

**Tests:** `Dict<string, number>` and a second one built separately share a key;
`Dict<string, number>` is not assignable to `Dict<number, number>`;
`Dict<string, "a">` is assignable to `Dict<string, string>`; `DictKey` refused
as a type name; a `distinct type` over `string` is admitted as a key and a
`boolean` is not.

### Task 3: `zttp:collections`

**Files:** new `packages/zts/src/modules/data/collections.zig`,
`builtin_modules.zig`, `packages/zttp-sdk/src/binding.zig` (`ReturnKind.dict`),
`module_types.zig`.

The ten exports of spec 6.2, zero capabilities, every one pure:
`dictEmpty`, `dictFromEntries`, `dictGet`, `dictSet`, `dictRemove`, `dictHas`,
`dictEntries`, `dictMapValues`, `dictFilter`, `dictFold`.

`dictFromEntries` returns `Result<Dict<K, V>, DuplicateKey<K>>`; the bulk
operations return `Dict` and never `Result`, because a transformation of an
existing dictionary cannot produce a duplicate. The three callback-taking
exports run their callback once per entry in insertion order.

**Tests:** `dictFromEntries` rejects a duplicate with the key in the error;
`dictMapValues` preserves order and arity; `dictFilter` preserves order;
`dictFold` sees insertion order; `dictGet` of an absent key is `undefined`, not
an error; every export's declared signature parses in the frozen-signature gate
phase 2 built.


**Every export is `replay_pure`.** The handler-test runner installs replay
stubs instead of real module functions, and a stub with no recorded I/O returns
`undefined` - so without the opt-in, a test of a Dict handler sees `undefined`
from all ten exports. The opt-in is audited rather than inferred, and it holds
here by construction: each export reads only its arguments.

### Task 4: `isDict`, the `Dict` type test, and `JsonValue`'s last arm

**Files:** `type_checker.zig`, `match_analysis.zig`, `parse.zig`,
`bool_checker.zig`.

`isDict` joins `Array.isArray` as a specified intrinsic guard, narrowing a union
to its `Dict` members. `when Dict:` stops reporting the phase-4 deferral and
lowers to it, which is the last of spec 5.5's six type tests except `Bytes`.
`JsonValue` gains `| Dict<string, JsonValue>` and stays contractive, since
`Dict` is one of the constructors that guards a cycle - task 2 adds it to the
guard set the contractivity walk stops at.

**Tests:** the six-arm `JsonValue` match of spec 16.3 is exhaustive without a
`default`; dropping the Dict arm makes it non-exhaustive; `isDict` narrows in
the arm it guards and not in the others; `when Bytes:` still names phase 5.

### Task 5: `zttp:json`

**Files:** new `packages/zts/src/modules/data/json_mod.zig`,
`builtins/json.zig` (taxonomy, limits, Dict nodes), `builtin_modules.zig`.

`parseJson(text): Result<JsonValue, JsonError>` and
`stringifyJson<T>(value): Result<string, JsonError>`. `parseJsonBytes` waits for
`Bytes` in phase 5 and is not declared here, because a declared export whose
type does not exist is the fail-open the frozen-signature gate exists to catch.

The parser's single `error.InvalidJson` splits into the spec's closed taxonomy -
`invalid-syntax` with an offset, `duplicate-key` with the key and offset,
`depth-limit`, `size-limit`, `non-finite-number`, `cycle` - and object nodes
become `Dict<string, JsonValue>` in wire order. Duplicate keys are rejected
rather than last-wins.

Limits stop being a constant in the parser: a `JsonLimits` struct with depth and
input size, supplied by the runtime, defaulting to today's 512 depth. The
default is preserved exactly so this task changes the taxonomy and not the
accepted language.

`stringifyJson<T>` is admitted only when `T` is made of JSON scalars, arrays,
tuples, fixed records, and string-keyed `Dict`. Optional `undefined` fields are
omitted; an `undefined` array element, a non-finite number, and a cycle are
each a typed error.

**Tests:** round trip over each value kind including `null` and a nested Dict;
key order is wire order; a duplicate key is refused with its key; depth over the
limit reports `depth-limit` and not `invalid-syntax`; input over the size limit
reports `size-limit`; `NaN` is refused by `stringifyJson`; a record with an
optional `undefined` field omits it; `stringifyJson` of a function-valued field
is refused by the checker rather than at runtime.


**The coarse binding surface bites here, and the language answers it.** A
`Result`-returning export types its payload as `unknown`, so a parsed document
cannot be handed straight to a `Dict` parameter. The repair is the one spec 5.7
names: narrow with `isDict` first. That guard now refines `unknown` to
`Dict<unknown, unknown>`, which is what an intrinsic type guard is for - the
union case partitions members, and a value with no members would otherwise be
unusable at exactly the site the guard was written for.

**A second leak, in the parser's own error path**: the duplicate-key failure
borrowed the decoded key it had just freed. Fixed by copying it into the
parser, truncated rather than kept alive past its owner.

### Task 6: the two Dict idiom rows

**Files:** `idiom_registry.zig`, `strict_checker.zig`, `rule_registry.zig`,
`describe_rule.zig`.

Spec 6.2 names two rewrites: an entry round trip through `dictEntries` and
`dictFromEntries` becomes `dictMapValues` or `dictFilter`, and a `reduce` over
`dictEntries` becomes `dictFold`. Both are advisory, which is the idiom
channel's severity, and both carry the precondition the row states.

**Tests:** each row fires on its non-idiomatic spelling and stays silent on the
idiomatic one; a round trip that changes the key set is not rewritten to
`dictMapValues`, since that row's precondition does not hold.

### Task 7: the static table, decided on cost

**Files:** `comptime.zig` if it lands.

Spec 6.2's third construction form is `comptime(dictFromEntries([...]))`, whose
duplicate check is discharged at build time. It needs a dict case in
`ComptimeValue` and an evaluator for the call.

This task is a decision, not a commitment: if the dict case is a small addition
to the existing value model it lands, and if it needs the comptime evaluator to
reach module exports it does not, and the runtime `dictFromEntries` covers the
same programs at a runtime check. Whichever way it goes, the reason is recorded
at the site and in this plan.


**Decided: it does not land, and for a reason neither branch anticipated.**
Reaching a module export would indeed be a small addition to `evalCall`, whose
identifier arm admits a closed set of three names. That is not the obstacle.

The obstacle is that this channel's output is source text. `comptime` is
evaluated in the stripper: `ComptimeEvaluator.evaluate` produces a
`ComptimeValue`, `emitLiteral` writes it back as a literal, and the stripper
splices it over the span the author wrote. Every value the model holds has a
spelling. A `Dict` has none - spec 6.2 says so itself, construction is a module
call - so a `ComptimeValue.dict` case could only be emitted as
`dictFromEntries([...])`, the expression it started from.

The two ways out are both larger than this task. Giving `Dict` a literal syntax
adds an IR node against a spec that says it has none, and against this phase's
own pin on the node alphabet. Making `comptime` yield a runtime value rather
than text is a different mechanism from the one that exists.

So the runtime `dictFromEntries` covers the same programs at a runtime check,
and the spec form fails the build rather than evaluating to something else -
which is the part that had to be checked rather than assumed, because the form
exists for a duplicate-key check and an answer that looked like it had run
would be worse than no answer. `StripError.ComptimeEvaluationFailed`, pinned in
`stripper.zig`; the enumeration behind "a Dict has no spelling" is pinned in
`comptime.zig` against `emitLiteral` itself.

### Task 8: `unwrap` and `unwrapErr` refused in the profile

**Files:** `strict_checker.zig`, `rule_registry.zig`, `describe_rule.zig`,
`diagnostic_projection.zig`.

ZTS627 reports a call to `unwrap` or `unwrapErr` on a `Result`, with the repair
being the ok-guard early return (`if (!r.ok) { return ...; }`) or `match`. The
methods stay callable; the profile is what refuses them, exactly as spec 6.1
frames it - the trapping extraction is not admitted, and the value is unchanged.

**Tests:** `r.unwrap()` reports with its repair; `r.unwrapOr(d)` does not, since
spec 6.1 admits it as consumption rule 1; the ok-guard form reports nothing.


**Measured, and closed without a rule.** The type checker already refuses
`r.unwrap()`: the modelled `Result` is a record with `ok`, `value`, `error`,
and `errors`, and no methods at all, so a method call on it reports
`property does not exist on type`. A ZTS627 would have duplicated a refusal
that exists and failed in exactly the same place, so it was written, measured
against the corpus, and deleted.

The same measurement found the opposite half: `r.unwrapOr(d)` is refused too,
and spec 6.1 admits it as consumption rule 1. That is not a rule to add here -
spec 6.1 wants `unwrapOr` as a free function from `zttp:result`, which is the
deferred track's job. It is recorded so the deferral is a known gap rather than
a surprise.

### Task 9: the exit gate

**Files:** a new example under `examples/patterns/`, plus the tests that pin it.

The gate is the roadmap's exit sentence made executable: a handler that parses
JSON into a `JsonValue`, walks it with the six-arm `match`, and re-serializes.
It asserts determinism (two parses of the same text iterate identically),
SameValueZero (a `NaN` key and a `-0` key each find their entry), round trip
(parse then stringify is byte-identical for a canonical input), and the two
limits (depth and size each report their own error).

The gate asserts a floor on its own input: an empty document and a zero-limit
configuration each fail rather than passing over nothing.

`docs/coverage.md` and `docs/convergence.md` are regenerated in the same commit
as whatever changes them.

---

## Risks

The Dict value is the first new runtime class this program adds, and the GC is
where a new class kind is most likely to be wrong in a way tests do not see. Its
tracing is written with the entry vector and the hash index both reachable, and
the soak the wave-0 measurement used is the check that finds a missed edge.

Copy-on-set is quadratic over the fold construction form. It is the honest first
implementation and the bench is what decides whether it stays.

The JSON taxonomy is a behavior change dressed as a refactor: every failure that
was `InvalidJson` becomes one of six, and a caller matching on the old shape
sees a different error. The limits keep their current values in the same commit
so the accepted language does not move at the same time as the reporting.

`stringifyJson<T>`'s admission rule is a type-level check over an arbitrary `T`,
which is the piece most likely to be a fail-open: a `T` the rule cannot decide
must be refused rather than admitted, and the test for it passes a function-
valued field rather than trusting the walk to have covered every tag.

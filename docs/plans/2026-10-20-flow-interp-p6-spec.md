# Flow redesign: P6 defenses and nested match patterns

Status: specification for implementation, 2026-10-20. The owner approved P6
(D21 Option A) and its policy (D22, D23, D24 Option A, D25 Option B). Parent
documents: [the redesign plan](2026-10-18-flow-checker-sound-redesign-plan.md)
(R2, R12, R13, R15) and [the P5 specification](2026-10-19-flow-interp-p5-spec.md).
P6 extends `packages/zts/src/flow_interp.zig` (commit `a7a82689`). It runs in
shadow: no verdict and no policy hash moves (R9).

Codex astra reviewed six drafts. Round 6 found no soundness defect and two
mutations that their tests could not catch; tests 9 and 13 now catch them. Round 1 found that `JSON.parse` kept schema
evidence for a structure that no validator saw; that `jwtVerify` validates no
claim, so it is not a schema source; that the sink predicate read a value
without its heap cells; that every export result holds an allocation origin,
so an origin condition on a source failed for every realistic argument; and
five test defects. Round 2 found that `String.fromCharCode` kept
`schema_checked` (a validated `38` becomes `&` in a form body), and that P5
passed a callback index as `clean` although R1 counts a position as carrying.
Round 3 found that `replace` can decode validated text, and that P5 method
dispatch joins the labels of a value that cannot be called, which removed the
defense from the usual list-building pattern. Round 4 found that callback
results of a non-source export kept their defenses. This version keeps the
fix for each of those findings.

Rounds 1 to 5 also found a family of paths in which request data decides
which author characters appear: a slice bound computed from escaped text cuts
`onerror=alert(1)` out of an author literal, a sort orders author markup by
request content, and a request-derived length truncates an author array.
Drafts 2 to 5 added choice rules for these paths, and each round found
another path that the rules missed. The owner chose D25 Option B: the claim
of `html_escaped` is narrowed (see "What `html_escaped` claims") and the
choice rules are removed. One part of a round 1 finding is rejected, with its
reason under "Schema evidence".

## Scope

P6 replaces the `validated` label bit with defense facts that sit beside the
provenance labels (R2), states for each operation whether it keeps or removes
each defense, and records which defense each sink requires (R12). It also
binds nested record patterns and array patterns in `match`, the two
constructs that P2 left with owner P6. It lands as two commits, in this order:

- P6a: nested record patterns and array patterns in `match`. `Phase` and
  `Owner` lose `p6`.
- P6b: the defense domain, the operation edges, the defense sources, census
  C3, and the sink requirement table.

These stay with a later owner:

- the sinks themselves, and the request and headers contents (P7). P6 adds
  the requirement table and a predicate that P7 calls; it checks no sink;
- the text in `docs/proofs-and-receipts.md` that states the D24 and D25
  limits (P7, when it renders the matrix);
- defense evidence bound to heap cells for a validator that returns the
  object it was given (R13). D23 defers it: one allocation site stands for
  many objects, so marking the cells of a site would vouch for objects that
  were never checked. `validateObject` and `decodeQuery`, which take an
  object, establish nothing;
- export summaries that keep a defense through a pass-through export such as
  `dictGet` (P8). Until then such an export removes every defense.

## Facts

Paths are under `packages/` unless named.

- `LabelSet` (`zts/src/module_binding/types.zig`) has the bit `validated`.
  `mergeValues` treats a contributor without `user_input` as neutral for it;
  `mergeConditional` (the P2 join) ANDs it. Nine exports declare it in
  `return_labels`: `escapeHtml` (`modules/src/platform/text.zig`),
  `validateJson`, `validateObject`, `coerceJson`
  (`modules/src/security/validate.zig`), `decodeJson`, `decodeForm`,
  `decodeQuery`, `decodeFormMultipart` (`modules/src/security/decode.zig`),
  and `jwtVerify` (`modules/src/security/auth.zig`, with `credential`).
- `flow_interp.zig` never removes a label for `validated` (P5b), but
  `declaredLabels` copies the declared bit into the result, so P5 test 35
  expects `validated` on `validateObject("n", {})`.
- `escapeHtml` replaces `&` `<` `>` `"` `'` with `&amp;` `&lt;` `&gt;`
  `&quot;` `&#39;` (`text.zig` `escapeHtmlImpl`). `unescapeHtml` reverses it
  and declares `derives_from_args`.
- A cut of escaped text can leave a partial character reference such as
  `&lt` or `&quo`. In HTML text and in a quoted attribute value, a browser
  decodes a reference to a character of data or leaves it as text. It never
  makes a tag or ends the quoted value. So a cut, a pick, or an order of
  escaped characters produces no markup from those characters.
- `renderToString` (`zts/src/http.zig` `renderNode`) escapes `& < >` in the
  text children of an ordinary element. It writes the tag name, the
  attribute names, and the children of `script` and `style` unescaped (D22).
  An escaped tag name such as `img src=x onerror=alert(1)` holds no escaped
  character.
- `validateObject(name, value)` with `coerce = false` returns `value` itself
  in its Result (`validate.zig` `decodeObject`). `decodeQuery` takes an
  object the same way. The other validators and decoders take strings and
  build their payload by parsing; each answers an `err` Result when an
  argument is not a string (`sdk.extractString ... orelse resultErr`).
- `jwtVerify` checks the signature and the `exp` and `nbf` claims, then
  returns the parsed claims with no schema check (`auth.zig` 100-175).
- A JSON string can spell `<` as `\u003c`, which `escapeHtml` leaves as it is
  and `JSON.parse` turns into `<`. A string that a schema accepts as
  `{"type": "string"}` can hold any JSON text, so `JSON.parse` of it builds
  a structure that no schema checked.
- `JSON.stringify` adds a `"` before and after a string. A `"` next to
  escaped text can end a quoted attribute, so the text after it is markup.
- `Object.keys` and `Object.entries` return property names. No export
  escapes a property name.
- `String.fromCharCode` makes a character from a number, so
  `String.fromCharCode(60)` is `<`.
- P5 `storedRead` and `writeValue` merge the labels of the key of a computed
  read or write (`Key.dynamic`) into the value, and the labels of the
  receiver into every read and write.
- Every export result in P5 holds an allocation origin (`evalExportCall`
  joins the result container into the value), and so does a value read out
  of a builtin result, because a container that a call allocates holds its
  self value in its summary. An argument condition on origins therefore
  fails for `escapeHtml(text)` whenever `text` came from a call.
- A match array pattern (`parser/parse.zig` `parseMatchArrayPattern`) holds
  element patterns and holes (`null_node`). Code generation
  (`parser/codegen.zig` `emitArrayPatternBindings`) binds only through an
  element that is a record or array pattern, and reads element `i` with
  `get_elem` and the integer `i`. A record pattern field binds only when it
  is an identifier or a nested pattern; a nested pattern reads the field with
  `get_field` and binds through it (`emitRecordPatternBindings`).
- `bindPattern` (`flow_interp.zig`) records owner P6 for a nested record or
  array pattern in a field, and for an array pattern as the arm pattern.
  `tagPlan` gives `array_pattern` `.later = .p6` and `match_pattern`
  `.handled`.

## Rules: nested match patterns (P6a)

`bindPattern(pattern, v, st)`:

- record pattern: for each field whose value is an identifier or a nested
  record or array pattern, `field = readValue(st, v, .{ .name = key })`. An
  identifier binds `field`; a nested pattern calls
  `bindPattern(nested, field, st)`. A field whose value is anything else
  reads nothing and binds nothing.
- array pattern: for each element that is a record or array pattern,
  `elem = readValue(st, v, .index)` and `bindPattern(element, elem, st)`.
  Every other element, and a hole, reads nothing and binds nothing.
  `Key.index` reads the summary, as a numeric-literal read does.
- a type test, a literal, and the default bind nothing.

`tagPlan(.array_pattern)` becomes `.handled`, as `match_pattern` already
is. `Phase` becomes `enum { p7, p8 }`, `Owner` loses `p6`, and
`ownerOfPhase` loses its arm. The tag census print line loses `p6`.

## Rules: defenses (P6b)

### The domain

`Defense` is an enum with two members: `html_escaped` and `schema_checked`.
`Defenses` is a `packed struct(u8)` with one bool per member, both `false`
by default. `Value` gains `defenses: Defenses = .{}`. `Flow` is a struct of
`labels: LabelSet` and `defenses: Defenses`: what a value carries, without
its origins and callables.

A value or flow is *exposed* when its labels hold `user_input` or `unknown`.
A defense fact on a value that is not exposed means nothing, so the
canonical form has `defenses == .{}` when the value is not exposed. Every
constructor and every join keeps values canonical, and `valueEql` compares
`defenses`.

The default is `false`, so a construct that forgets to compute defenses
removes them. That costs precision and never soundness.

`combineDefenses(a, b)` takes two flows and gives the defenses of a value
built from both as data, at a join or in a combination (R13):

- if `a` is not exposed, the result is the defenses of `b`;
- if `b` is not exposed, the result is the defenses of `a`;
- otherwise the result is the AND of the two.

This is the lattice order: a value that is not exposed holds every defense
(bottom and a clean literal hold every defense, because no sink in the D24
table refuses a literal), and among exposed values fewer defenses is higher.
Every transfer function below is monotone in that order, so the fixpoints of
P3 and P4 still end.

### What `html_escaped` claims

`html_escaped` on an exposed value claims this: every character of the value
that came from request data passed `escapeHtml`, and no later operation
turned an escaped character back into markup. The claim is about request
characters only (D25 Option B). It says nothing about which author
characters appear in the value, where, how often, or in what order.

So request data can still decide author markup through a position, a count,
or an order, and the value keeps `html_escaped`. For example,
`"<img src=x onerror=alert(1)>".slice(escapeHtml(u).length)` holds
`html_escaped`, and the length of `u` decides which part of the author tag
appears. That is a stated limit, beside the implicit-flow limit (D9) and the
HTML context limit (D24). A program that makes such a choice by control flow
(`if`, a loop count) is under D9 already, and P6 does not try to separate
the two.

Under this claim, the operations that cut, pick, read at a position, or
order keep `html_escaped`: a cut of escaped text holds only escaped request
characters (see the partial-reference fact), and the author characters that
a choice brings in are outside the claim. The operations that remove
`html_escaped` are the ones that make or reinterpret characters: the edges
in "Operation edges", `unescapeHtml` and every other export that is not a
source, and a combination with an exposed value that does not hold it.

The positions themselves still carry labels (R1). A computed key, a slice
bound, and a callback index carry the labels of the data that computed them,
and the result of the read or the rule holds those labels. Defenses of those
inputs combine as data, so a raw request value used as a key or a bound
removes the defense from the result, as its labels already make the result
exposed.

### Method dispatch

P5a joins the labels of the user candidate (`storedRead(r, name)`) into the
result of every method call, even when that value holds no callable. For an
array whose summary holds raw request data, this removes the defense from
`items.map((x) => "<li>" + escapeHtml(x) + "</li>").join("")`, the usual way
to build an HTML list. A user candidate that holds no callable and neither
`top` flag cannot be called: the runtime fails with `NotCallable` and returns
no value. So P6 joins the user candidate's flow into the result only when it
holds a callable or `callables_top`. The builtin candidates and their rules
are unchanged.

### The callback index

The index parameter of a callback is a position in the receiver. P5 passes it
as `clean`, which breaks R1: a receiver built as `[...u.split(",")]` has a
request-derived length, so the index carries `user_input`. P6 passes a new
`Param` variant, `structure`: the labels of `deepFlow` of the receiver at the
loop head, with `defenses = .{}`. The receiver's own labels are not enough,
because a spread copies request-derived elements into a receiver whose own
labels are clean. The variant applies to `map`, `filter`, `find`, `forEach`,
`every`, `some`, `findIndex`, `reduce`, and `Array.from` (where the receiver
is the source argument).

### Schema evidence

`schema_checked` certifies that the request-controlled part of a value passed
a schema validator and was not reinterpreted afterwards. It does not claim
that the value still satisfies the schema. So a combination with author data
keeps it, and an operation that reinterprets text as structure or as other
characters removes it: `JSON.parse`, `JSON.tryParse`, `replace`,
`replaceAll`, `String.fromCharCode`, the request readers, and every export
that is not a source row.

Codex round 1 proposed removing `schema_checked` at every operation that
changes a value, with `"x"` appended to a validated enum member as the
example. That part is rejected: the sinks that accept `schema_checked`
(D24) ask whether request data passed validation (`input_validated`) and
whether it is constrained before it is sent in a body, and an author suffix
adds no request-controlled content. The rule would also remove the defense
from `JSON.stringify(validated)`, which is how a handler sends validated data
in an egress body. The `JSON.parse` part of the finding is accepted.

### The `validated` bit

No value in `flow_interp.zig` carries `validated`. `declaredLabels` removes
it from the declared set, and the export's defense comes from the defense
source table below. `mergeValues` and `mergeConditional` keep their meaning
for every other bit.

### Where defenses flow

Defenses travel with the value. These constructs must compute the defenses
of their result from their contributors, in the same places where they
combine labels:

- the join of two values (`joinValue`), and so every `if`, ternary, `match`,
  `&&`, `||`, `??`, loop head, call result, and completion join:
  `combineDefenses`;
- every binary and unary operator, `+` included: `combineDefenses` over the
  operands;
- a property read: the cell value combined as data with the receiver, and
  for `Key.dynamic` also with the key, in the place where `storedRead`
  merges their labels;
- a write: the stored value combined as data with the receiver, and for
  `Key.dynamic` also with the key, in the place where `writeValue` merges
  their labels. A weak write joins, so a raw value written into a cell
  removes the defense from every later read of that cell;
- a spread copy, an element or array parameter of a callback, and a
  callback result: the values as they are;
- `reach` and `deepLabels`: `combineDefenses` over every value they reach.
  `deepLabels` becomes `deepFlow`, which returns a `Flow`;
- `allocate` takes the `Flow` of the value it returns, so a container value
  does not lose the defenses that its contents keep.

### Operation edges

`OperationRow` gains one field with no default value, so every `rowsOf` call
states it: `defense: DefenseEdge`, with the members

- `keep`: the rule's `L` keeps its defenses;
- `drop_html`: `L` loses `html_escaped` and keeps `schema_checked`;
- `drop_all`: `L` loses both.

`L` is the flow that `applyRule` builds from the receiver and everything the
arguments reach (`deepFlow`), combined as data with `combineDefenses`, in the
place where it now computes `mergeValues(r.labels, arg_labels)`. The edge
applies to `L`, and every value that the rule builds from `L` uses the
result. A value that a rule moves as it is (a callback result of `map`, a
value that `entries` pairs with its key) keeps its own defenses.

The rows whose edge is not `keep`:

| Row | Edge | Reason |
|---|---|---|
| `String.prototype.replace`, `replaceAll` | `drop_all` | the replacement can bring back markup (R2), and `replaceAll("%26", "&")` decodes validated text |
| `String.fromCharCode` | `drop_all` | makes a character from a number: a validated `38` becomes `&` |
| `JSON.stringify` | `drop_html` | adds `"` next to the text |
| `JSON.parse`, `JSON.tryParse` | `drop_all` | `\u003c` becomes `<`, and the structure was never checked |
| `Object.keys`, `Object.entries` | `drop_html` | property names are never escaped |
| `renderToString` | `drop_html` | tag names, attribute names, and `script` children are not escaped |
| `requestBody`, `requestText`, `requestJson` | `drop_all` | fresh request data |

These are twelve rows. Every other row is `keep`, the nine `no_rule` rows
included (they record an unresolved operation, so the edge has no effect).

### Defense sources

A table `defense_sources` has one row for each export whose binding declares
`validated`:

| Export | Establishes | Keeps from its input | Removes |
|---|---|---|---|
| `zttp:text` `escapeHtml` | `html_escaped` | `schema_checked` | nothing |
| `zttp:validate` `validateJson`, `coerceJson` | `schema_checked` | nothing | `html_escaped` |
| `zttp:decode` `decodeJson`, `decodeForm`, `decodeFormMultipart` | `schema_checked` | nothing | `html_escaped` |
| `zttp:validate` `validateObject` | nothing: returns the object it was given (R13 deferred) | | |
| `zttp:decode` `decodeQuery` | nothing: takes an object, and R13 evidence for an object argument is deferred | | |
| `zttp:auth` `jwtVerify` | nothing: authenticates the token, and validates no claim | | |

A row that establishes nothing carries its reason as a string. `jwtVerify`
was in the D23 list; the runtime shows that it checks no claim, so it moves
to a row without a defense, which only removes proofs.

The condition for a row that establishes a defense is static, not a property
of the abstract arguments: every parameter that the binding declares is a
`string`. Census C3 checks it. The origins of `R` are not consulted, because
a string argument holds no cells, and each of these exports answers an `err`
Result or `undefined` at runtime when an argument is not a string. The
self value that every call result holds in its summary would otherwise make
the condition fail for every realistic argument.

In `evalExportCall`, a source row that establishes a defense builds:

- `held` and `shown`: the labels `E` of P5b, with no origin, no callable,
  and no flag, and the defenses of `deepFlow(R)` minus what the row removes,
  plus what it establishes, made canonical;
- the container value with the same flow (`allocate` takes it).

Every other export, `mask` and the rows without a defense included, keeps the
P5b `held` with `defenses = .{}` for `held`, `shown`, and the container, and
clears the defenses of the callback results (`results`) before it joins them
into the contents and the value. An export may transform its input
(`unescapeHtml`, `truncate`) or choose among entries by a callback
(`dictFilter`), and the binding cannot say that it does not. The export
still writes its result into the arguments (P5b), so that write removes the
defenses of the argument cells it reaches. Provenance does not change: no
source row removes a label, so a validated request value keeps `user_input`
(D23).

### The sink requirement table

The table states, for each sink and each property that request data decides,
which defense the sink accepts (R12, D24):

```zig
pub const InputSink = enum { response_html, response_other, response_init, log, egress_url, egress_body, egress_headers, egress_opaque };
pub const InputProperty = enum { input_validated, injection_safe, pii_contained };
pub const Requirement = union(enum) { not_governed, defense: Defense, no_defense };
pub fn requirement(sink: InputSink, property: InputProperty) Requirement;
pub fn inputAccepted(reached: Flow, sink: InputSink, property: InputProperty) bool;
```

`requirement` is an exhaustive switch with no `else` arm:

| Sink | `input_validated` | `injection_safe` | `pii_contained` |
|---|---|---|---|
| `response_html` (the body of `Response.html`) | not governed | `html_escaped` | not governed |
| `response_other` (the body of another helper) | not governed | not governed | not governed |
| `response_init` (the second argument of a helper) | not governed | not governed | not governed |
| `log` | not governed | not governed | not governed |
| `egress_url` | `schema_checked` | no defense | no defense |
| `egress_body` | `schema_checked` | `schema_checked` | no defense |
| `egress_headers` | `schema_checked` | no defense | no defense |
| `egress_opaque` | `schema_checked` | no defense | no defense |

`inputAccepted(reached, s, p)` is true when `reached` is not exposed, or the
requirement is `not_governed`, or it is `defense = d` and `reached.defenses`
holds `d`. It is false for `no_defense` on an exposed flow. Its argument is
the `deepFlow` of the value that reaches the sink, in the state at the sink,
never the value alone: a container with clean surface labels can hold request
data in its cells, and a validated value keeps its own defense after an alias
writes raw data into a cell. The doc comment says so, and P7 calls it only
that way.

The doc comment of the table states two limits. `html_escaped` covers HTML
text and quoted attribute values; a URL attribute such as
`href="javascript:..."` and a script context are outside it (D24). And it
covers request characters, not author characters that request data selects
(D25). `egress_opaque` is the options object that a call passes by name, so
it takes the strictest row of the three egress fields.

### Census C3

A test checks `defense_sources` against the bindings in both directions:
every export that `findExport` finds with `return_labels.validated` has a
row, and every row names such an export. Every row that establishes a defense
names an export whose declared parameters are all `string`, and every row
without a defense has a non-empty reason. The test also compares the whole
table with an expected mapping written in the test (each export, what it
establishes, keeps, and removes), so a row with a wrong defense fails even
when its parameters are strings. Probes, each of which must fail with an
error that names the cause: remove one row; add a row for an export without
`validated` (`unescapeHtml`); give `validateObject` a defense; give
`jwtVerify` `schema_checked`. The test asserts a floor of nine rows.

C1 gains one check: the rows whose edge is not `keep` are exactly the twelve
in the operation edge table, with those edges. A probe that changes the edge
of `replace` to `keep` must fail.

## Tests

The sources are internal evaluator fixtures, as in P5. `u` is seeded
`user_input`, `s` `secret`. A seed may also be a hand-built primitive `Value`
with labels and defenses and no origin. Each test that expects a defense has
a contrast without it. A test that checks a defense checks the exact defense
set, not one member. P6a:

1. A nested record pattern binds its field:
   `match (x) { when { a: { b: v } }: v default: "c" }` with `x = { a: { b: s } }`
   is secret, and with `x = { a: { b: "c", z: s } }` it is clean.
2. An array pattern binds through an element record pattern:
   `match (x) { when [{ k: v }]: v default: "c" }` with `x = [{ k: s }]` is
   secret, and with `x = [{ k: "c" }]` it is clean.
3. A record field that holds an array pattern, and an array element that
   holds an array pattern, bind: `when { a: [{ b: v }] }: v` and
   `when [[{ b: v }]]: v`, each secret with `s` in the bound place and clean
   with `"c"` there.
4. A hole and a literal element bind nothing, and the arm still evaluates;
   neither records an unresolved node.
5. The tag census has no `p6` column, and no tag has `.later = .p6`.

P6b:

6. `escapeHtml(u)` is exposed, has exactly `{html_escaped}`, and keeps
   `user_input`. `u` holds no defense. `escapeHtml(t)` with
   `t = u.split(",")[0]` (an exposed value with an origin) also has exactly
   `{html_escaped}`, and `inputAccepted(deepFlow(result), response_html,
   injection_safe)` is true for it.
7. A combination keeps a defense only when every exposed contributor holds
   it: `"<p>" + escapeHtml(u) + "</p>"` holds `html_escaped`;
   `escapeHtml(u) + u` does not.
8. A join keeps a defense when the other side is not exposed:
   `c ? escapeHtml(u) : "x"` holds it; `c ? escapeHtml(u) : u` does not.
9. Operations with the edge `keep` keep the defenses of `L`. With
   `e = escapeHtml(u)`, each of these has `user_input` and exactly
   `{html_escaped}`: `e.toUpperCase()`, `e.trim()`, `"<b>".concat(e)`,
   `e.slice(0, 3)`, `e.split(",")[0]`, `(e + "<").charAt(1)`,
   `e.padStart(9, "<")`, `e.charCodeAt(0)`, `[e, "<b>"].join("")`,
   `[e, "<b>"][0]`, `[e, "<img>"].toSorted()[0]`, `[e, "<img>"].pop()`,
   `[e, "<b>"].filter((x) => true).join("")`, and
   `[e, "<b>"].splice(0, 1).join("")`. A raw argument removes the defense:
   `e.slice(u.length)` holds none. A seed `v` with exactly `{schema_checked}`
   gives `v.slice(1)` exactly `{schema_checked}`, and `v.slice(u.length)`
   none. `replace` and `replaceAll` remove both defenses from `e` and from
   `v`. A container keeps the flow of its rule: `Array.from(u, (c) =>
   escapeHtml(c))` has a `deepFlow` with `user_input` and no defense, because
   the container takes the raw flow of `u` while its elements are escaped.
10. The D25 limit: `"<img src=x onerror=alert(1)>".slice(n)` with
    `n = escapeHtml(u).length` holds `user_input` and exactly
    `{html_escaped}`; with `n = u.length` it holds none; with `n = 1` it is
    not exposed. This test records the limit; a later phase that narrows it
    changes the test.
11. A computed key combines as data: with `o = { k: escapeHtml(u) }`, `o[u]`
    holds `user_input` and no defense, `o[escapeHtml(u)]` holds exactly
    `{html_escaped}`, and `o["k"]` holds exactly `{html_escaped}`. After a
    computed write `o[u] = escapeHtml(u)`, a read `o.k` holds no defense;
    after `o["z"] = escapeHtml(u)` it holds exactly `{html_escaped}`.
12. The callback index carries the receiver's structure: for each of `map`,
    `filter`, `find`, `forEach`, `every`, `some`, `findIndex`, `reduce`, and
    `Array.from`, a callback that writes `"c".charAt(i)` into an outer cell
    over a receiver built as `[...u.split(",")]` makes that cell hold
    `user_input`; over `["c", "c"]` the cell holds no `user_input`.
    `Array.from(escapeHtml(u), (c, i) => "c".charAt(i)).join("")` holds
    `user_input`, and `Array.from(escapeHtml(u), (c) => c).join("")` holds
    exactly `{html_escaped}`.
13. Method dispatch adds the user candidate only when it can be called:
    with `a = [u]`, `a.map((x) => "<li>" + escapeHtml(x) + "</li>").join("")`
    holds exactly `{html_escaped}`. With `a = [() => u]`, `a.map(() => "c")`
    carries `user_input`, because the stored function runs as P5 requires;
    with `a = [() => "c"]` it does not. The flow of a callable candidate joins
    the result even when its body returns a clean value: after `a = []` and
    `a[s] = () => "c"`, `a.map(() => "c")` carries `secret` and no defense.
14. A non-source export clears the defenses of its callback results: each of
    the seven callback exports, given a callback that returns `escapeHtml(u)`
    or a seed with `{schema_checked}`, returns a value whose `deepFlow` holds
    no defense, for example `dictFold(dictSet(dictEmpty(), "k", "c"), () =>
    escapeHtml(u), "")`.
15. `unescapeHtml(escapeHtml(u))` holds no defense (R2), and neither does
    `truncate(escapeHtml(u), 3)`.
16. `String.fromCharCode(n)` with a seed `n` that holds both defenses holds
    neither; `escapeHtml(u).charCodeAt(0)` keeps exactly `{html_escaped}`.
17. `JSON.stringify(v)` with a seed `v` that holds both defenses has exactly
    `{schema_checked}`; `JSON.parse(v)` holds neither.
18. `Object.keys(o).join("")` and `Object.entries(o).join("")` lose
    `html_escaped` for `o = { k: escapeHtml(u) }`; `Object.values(o).join("")`
    keeps it.
19. `renderToString(h("p", {}, escapeHtml(u)))` holds no `html_escaped`.
20. Each source that establishes `schema_checked` gives exactly
    `{schema_checked}` on its result and on a read of `.value`:
    `validateJson("n", u)`, `coerceJson`, `decodeJson`, `decodeForm`, and
    `decodeFormMultipart`, each also with a seed argument that holds
    `{html_escaped}` and no origin. Each keeps `user_input`.
21. A row without a defense establishes nothing on its immediate result:
    `validateObject("n", u)`, `validateObject("n", { k: u })`,
    `decodeQuery("n", { k: u })`, and `jwtVerify(u, "k")` hold no defense.
    `jwtVerify` keeps `credential`.
22. A write into a validated result removes the defense for later reads: a
    write of `u` into `validateJson("n", u).value.x` makes a later read of
    `.x` lose `schema_checked`; the unwritten contrast keeps it.
23. A defense survives a call, a loop, and a callback: a helper that returns
    `escapeHtml(x)`, a `for...of` over `[escapeHtml(u)]`, and
    `[u].map((x) => escapeHtml(x)).join("")` keep it;
    `[u].map((x) => x).join("")` does not.
24. Canonical form and exposure: `escapeHtml("c")` is not exposed and has
    `defenses == .{}`; `Value.top` is exposed; a join of `Value.top` with
    `escapeHtml(u)` holds no defense, and a combination of a seed with only
    `unknown` and `escapeHtml(u)` holds none.
25. No value carries `validated`: `validateJson("n", u)`, its `.value`, and
    `escapeHtml(u)` have `labels.validated == false`. P5 test 35 changes its
    contrast to expect `{}` for `validateObject("n", {})`.
26. A loop that makes a value exposed converges: `let x = escapeHtml("c");
    for (const y of [u]) { x = x + escapeHtml(y); }` holds `html_escaped`,
    and with `x = x + y` it does not.
27. `requirement` matches the table for every pair: the test iterates both
    enums and compares each entry with an expected table written in the
    test. `inputAccepted` on `deepFlow`:
    - true for `escapeHtml(u)` at `response_html` and `injection_safe`, and
      false there for a flow with only `{schema_checked}`;
    - true for a `{schema_checked}` flow at `egress_url` and
      `input_validated`, false there for `injection_safe`, and false at
      `egress_body` for a flow with only `{html_escaped}`;
    - true at `egress_body` for both properties with `{schema_checked}`;
    - false for every exposed flow at every egress sink for `pii_contained`;
    - true for a flow that is not exposed at every pair, false for a flow
      with only `unknown` and no defense at every pair that needs a
      defense, and true for raw `u` at every `not_governed` pair;
    - false for the `deepFlow` of `{ body: u }` at `egress_body` and
      `input_validated`, and false for the `deepFlow` of a validated
      `.value` after an alias writes `u` into one of its cells.
28. Census C3 and the C1 edge check, with their probes.

## Mutations

Each mutation alone must fail a named test.

| Mutation | Test |
|---|---|
| A nested record pattern binds nothing | 1 |
| An array pattern element is read with the receiver instead of `.index` | 2 |
| A nested array pattern in a record field binds nothing | 3 |
| A nested array pattern in an array element binds nothing | 3 |
| `combineDefenses` ORs two exposed values | 8 |
| `combineDefenses` ANDs when one side is not exposed | 7 |
| `applyRule` builds `L` from the receiver alone | 9 |
| `allocate` ignores the flow it is given and returns a clean container | 9 |
| `replace` has the edge `drop_html` | 9 |
| A computed read ignores the defenses of the key | 11 |
| A computed write ignores the defenses of the key | 11 |
| The callback index is `clean` | 12 |
| The callback index carries only the receiver's own labels | 12 |
| Dispatch joins a user candidate that holds no callable | 13 |
| Dispatch skips a user candidate that holds a callable | 13 |
| Dispatch runs a callable candidate and omits its flow | 13 |
| A non-source export keeps the defenses of its callback results | 14 |
| A non-source export keeps the defenses of `R` | 15 |
| `String.fromCharCode` has the edge `drop_html` | 16 |
| `JSON.stringify` has the edge `keep` | 17 |
| `JSON.parse` has the edge `drop_html` | 17 |
| `Object.keys` has the edge `keep` | 18 |
| `renderToString` has the edge `keep` | 19 |
| A validator keeps `html_escaped` | 20 |
| `escapeHtml` also establishes `schema_checked` | 6, 28 |
| A source row consults the origins of `R` | 6 |
| `jwtVerify` establishes `schema_checked` | 21, 28 |
| Drop the canonical form | 24 |
| `unknown` does not count as exposed | 24, 27 |
| `declaredLabels` keeps `validated` | 25 |
| `egress_url` accepts `schema_checked` for `injection_safe` | 27 |
| `inputAccepted` accepts either defense for any `defense` requirement | 27 |
| Remove one `defense_sources` row | 28 |

## Existing tests

- P5 test 35: the contrast expects `{}`, because `validated` is gone.
- The test in the P4 section that expects owner P6 for a nested pattern
  expects a resolved result that binds the nested field.
- The tag census line loses `p6`.
- A P5 test whose expected labels came only from the user candidate of a
  method call that holds no callable (the P5c report calls these masked
  fixtures) changes its expectation, and the commit message names each such
  test. A test whose expectation comes from the rule itself stays.
- A P5c test that passes an index to a callback over a receiver whose cells
  carry a label now sees that label on the index.

## Verification

For each commit, run in this order, and read each exit status:

1. `zig fmt --check packages/zts/src/flow_interp.zig`
2. `zig build test-zts`
3. `zig build test-proof-swallow`
4. `zig build test-zts-layering`
5. `zig build check-spine`
6. `zig build test-doc-links`

Then run each mutation of that commit on a copy and confirm that its named
test fails with a test failure, not a compile error. The reviewer runs
`scripts/verify.sh` before each commit.

# Flow redesign: P5 operation edges and callbacks

Status: specification for implementation, 2026-10-19. The owner approved P5
(D20 Option A). Parent documents:
[the redesign plan](2026-10-18-flow-checker-sound-redesign-plan.md) (R3, R5,
R14, R15), [the P2 specification](2026-10-19-flow-interp-p2-r16-spec.md),
[the P3 specification](2026-10-19-flow-interp-p3-spec.md), and
[the P4 specification](2026-10-19-flow-interp-p4-spec.md). P5 extends
`packages/zts/src/flow_interp.zig` (commit `942eac41`). It runs in shadow: no
verdict and no policy hash moves (R9).

Codex astra reviewed two drafts. Round 1 found that Result methods are
reachable, that `Response` and request objects carry native methods, that six
Math calls compile to opcodes even under a user `Math`, that binding metadata
cannot detect a callback parameter, and eight argument gaps (splice selector
labels, callee labels on callback results, nested containers without a
location, the `top` flags through `reach`, capability labels, label removal by
`validated`, the meaning of `unknown`, and a callback census that cannot see a
missing row). Round 2 confirmed those fixes except three, and found new ones:
a native function value had no location, the presumed-call result dropped the
flags of callback results, and an implicit flag blocked namespace dispatch. It
also found that every allocated container counted as a possible Result, that
an export summary restored a declassified label, and nine test and mutation
defects. Round 3 confirmed those fixes and found five more: a native function
copied by a spread lost its shared-object origin, the dynamic-read rule also
flagged element scans, a nested-write fixture could not see its mutation,
the `mask` test dropped a declared label, and C1 did not check the global
functions. This version resolves every finding. The `mask` exception stays,
because the owner decided it (D14).

## Scope

P5 gives every builtin operation and every virtual-module export a transfer
rule, or an explicit row that clears the result. It replaces the two P4 rules
that name P5 as owner: a call through a property, and a call whose callee
holds no function. It lands as three commits, in this order:

- P5a: the dispatch of a call through a property, the builtin globals and
  namespaces, and every builtin operation that takes no callback. The builtin
  census (C1) lands here.
- P5b: calls of imported virtual-module exports, with the presumed-call rule.
- P5c: callbacks with precise rows: array methods, `Array.from`, the seven
  module exports that call a function, and `h` with `renderToString`.

These stay with a later owner:

- defenses: `validated` keeps its bit until P6 replaces it (R2). P5 never uses
  it to remove a label;
- sinks, and the contents of the request and its headers (P7, R4). P5 does not
  check a sink. A call on a request or headers site records owner P7;
- module state, imports from user modules, and writes to a shared runtime
  object (P8).

`unknown` keeps its P2 meaning: a value with `unknown` may carry any label.
P7 treats a sink that `unknown` reaches as unproven for every property. So a
result that carries `unknown` is sound without an unresolved record.

## Facts

Cited from two code maps and two Codex reviews of 2026-10-19. Paths are under
`packages/zts/src/` unless they start with `packages/`.

- Builtins are registered in `builtins/root.zig` `initBuiltins` (112).
  - `Array.prototype` (312-333): push, pop, shift, unshift, splice, indexOf,
    includes, join, slice, concat, map, filter, reduce, forEach, every, some,
    find, findIndex, toSorted, toReversed. `sort`, `reverse`, `fill`, and
    `flatMap` do not exist.
  - `String.prototype` (341-363): charAt, charCodeAt, indexOf, lastIndexOf,
    startsWith, endsWith, includes, slice, substring, toLowerCase, toUpperCase,
    trim, trimStart, trimEnd, split, repeat, padStart, padEnd, concat, replace,
    replaceAll. No string method takes a callback (`string_builtins.zig`
    718-770).
  - `Result.prototype` (369-378): isOk, isErr, unwrap, unwrapOr, unwrapErr,
    map, mapErr, andThen, match. Native Results from `ok`, `err`,
    `collectAll`, the request readers, `JSON.tryParse`, and the decode and
    validate exports carry it (`builtins/helpers.zig` 80). The type checker
    refuses most calls, but not all: `JSON.tryParse` has no return signature,
    an optional call skips the check, and prepared evaluation omits the type
    environment (`type_checker.zig` 1369, 2593, 3710;
    `packages/runtime/src/handler_instance.zig` 806).
  - Namespaces: Math (122-141), JSON (144-148: parse, tryParse, stringify),
    Object (151-156: keys, values, entries, hasOwn), Number (185-209), Response
    (268-279: json, text, html, redirect, rawJson; also callable), Date (`now`,
    303-309), Array (334-338: isArray, from, of), String (364-366:
    fromCharCode). `Math.PI` is stored under an atom that was never interned
    (140).
  - Global functions (211-259, 283-300): parseFloat, parseInt, isDict,
    isBytes, range, hole, requestBody, requestText, requestJson, h,
    renderToString. `String` and `Number` are callable.
- A native function is an extensible object: a handler can write a property
  of `parseInt` and read it back (`object.zig` 1721). The builtin objects are
  shared by every request in one runtime.
- The strict checker refuses an `undeclared_global` that is not in
  `known_globals.names` (`strict_checker.zig` 347-360). That list holds Array,
  Boolean, Date, Headers, JSON, Math, Number, Object, Request, Response,
  String, assert, h, hole, isBytes, isDict, parseFloat, parseInt, range,
  renderToString, requestBody, requestJson, requestText. Boolean is not
  registered. The serving runtime installs Request and Headers; a direct call
  of Headers, Request, or Response makes an object with native methods
  (`packages/runtime/src/runtime_http.zig` 257).
- A builtin namespace read is an `identifier` with binding kind
  `undeclared_global` (`parser/scope.zig` 330-338). A user top-level
  declaration of the same name has kind `global` and replaces the builtin in
  the shared global table (`interpreter.zig` 1239-1258).
- `x.name(...)` compiles to the receiver, `get_field_ic name`, the arguments,
  and `call_method` (`codegen.zig` 1019-1066). The read searches own
  properties first, then the prototype chain (`object.zig` 1889-1919), so a
  user property beats a builtin method. Array `length`, Result core fields,
  and range `length` are read first. Arrays carry `array_prototype`. A plain
  object, a function, a vnode, a Dict, Bytes, and a range iterator have no
  methods (`http.zig` 463, `object.zig` 2149, 2247). Dict and Bytes are
  objects. A string searches `string_prototype`. Any other primitive reads
  `undefined`, and the call fails with `NotCallable`.
- Request, `Response` objects, and fetch results have `text` and `json`;
  their headers have `get`, `set`, `append`, `has`, and `delete`
  (`packages/runtime/src/handler_instance.zig` 413,
  `packages/runtime/src/runtime_http.zig` 52, 211, 353).
- `o["m"](...)` compiles to a property read and a plain `call` with `this`
  undefined, not `call_method` (`codegen.zig` 1117). `o?.[k]()` and `g?.()`
  are refused (`parse.zig` 5315). A computed record key is refused (5800).
- An optional call is `call(optional_chain(r, m), args)`. Code generation
  tests `r` before the property read, the arguments, and the call
  (`parse.zig` 5312, `codegen.zig` 1030).
- `tryEmitMathBuiltin` (`codegen.zig` 1162-1228) runs before the optional
  test. It compiles a callee that is a `member_access` or an `optional_chain`
  whose object is an identifier named `Math` of kind `global` or
  `undeclared_global`, with property `floor`, `ceil`, `round`, or `abs` and
  one argument, or `min` or `max` and two, to an opcode. The receiver is not
  read. A `computed_access` callee is not compiled this way.
- Callbacks run synchronously with `this` undefined (`helpers.zig` 120).
  map, filter, forEach, every, some, find, and findIndex take the callback in
  argument 0 and pass `(element, index, array)`; reduce takes the callback in
  argument 0 and the initial value in argument 1, and passes `(acc, element,
  index, array)`; toSorted passes `(a, b)` and can call it many times per
  element; `Array.from` takes the callback in argument 1 and passes
  `(element, index)` (`builtins/array.zig` 70, 660-852). Array loops read the
  length once and read each index again, so a callback that writes the
  receiver can see its own writes.
- push and unshift return the new length. pop and shift return a receiver
  element. splice returns a fresh array of the removed elements. slice,
  concat, toReversed, toSorted, map, and filter return a fresh array. concat
  flattens array arguments one level.
- The only builtin that keeps a callback is `h` (`http.zig` 438-478). It
  stores a function component in the vnode, and `renderToString` calls it
  later with `props` after it sets `props.children` (540-570).
- `hole()` throws (`builtins/number.zig` 321-326). The parser refuses
  `try`, so no accepted source catches it (`parse.zig` 1951).
- Imports: an `import_decl` holds `module_idx` (a string constant) and a list
  of `import_specifier` nodes (`ir.zig` 486-497). A specifier has
  `imported_atom` and `local_binding`, with no link to its declaration. The
  local binding has kind `global` (`parse.zig` 4670-4692).
  `builtin_modules.findExport(specifier, name)` (`builtin_modules.zig`
  153-164) finds an export by its imported name. There are 21 modules and 89
  exports. No native export writes into an argument container; a callback it
  runs can (`packages/modules/src/security/validate.zig` 193,
  `decode.zig` 96; `dict.zig` 91 allocates a fresh Dict).
- The binding cannot say that a parameter is a callback: the seven exports
  that call a function declare that parameter as `.object`
  (`collections.zig` 47, `result_mod.zig` 59). Each takes the callback in
  argument 1. dictMapValues and dictFilter pass `(value, key)`; dictFold
  passes `(acc, value, key)` and takes the initial value in argument 2
  (`collections.zig` 241-293); mapResult, mapError, andThen, and orElse pass
  the payload. routerMatch returns a function stored in its argument
  (`router.zig` 53, 63), and dictGet can return a stored function.
- The old checker adds `nondeterministic` to an export's labels when its
  module is stateful and the export's effect is `.read`, or when its
  capabilities (`func.required_capabilities orelse
  binding.required_capabilities`; an explicit empty list does not inherit)
  include clock or random (`flow_checker.zig` 1375-1386). It refines `env`
  with a string-literal argument read through `getStringIdx` and `getString`,
  keeping `secret` when the name holds, case-insensitively, `SECRET`,
  `PASSWORD`, `PASSWD`, `KEY`, `TOKEN`, `PRIVATE`, `CREDENTIAL`, or `AUTH`,
  and giving `config` otherwise (4484-4507).
- A census can resolve a name through `ctx.atoms`, read it with
  `ctx.getGlobal` (`context.zig` 750), enumerate an object with
  `JSObject.propertyIterator` (`object.zig` 2461), and test a property with
  `JSValue.isCallable` (`value.zig` 346; `isFunction` excludes natives).
  Tests can run `initBuiltins` on a context (`builtins/number.zig` 475).

## Rules

### Sites

Four site kinds are added. The first three have `node` = the call node, and
stand for every container the call makes, including nested ones:

- `allocated_array`: an array that a builtin returns (split, slice, concat,
  toReversed, toSorted, map, filter, splice, Object.keys, values, entries,
  Array.of, Array.from).
- `allocated_any`: a container that may be an array, a record, a Dict, Bytes,
  or a native Result (JSON.parse, JSON.tryParse, the request readers, range,
  h, and every export result except fetch).
- `native`: a container that holds native methods (a `Response` static
  result, a fetch or fetchWithRetry result).

The summary of each of these sites always holds its self value (a value whose
only origin is the site), so a nested container has a location and a write to
it lands in the site.

The fourth kind, `builtin`, has `node` = an atom. It stands for the shared
runtime objects reached under that name: a namespace object (`JSON`), a
global function (`parseInt`), a namespace member (`stringify`), a prototype
method read as a value (`slice`), or an export read as a value. One atom may
name several such objects, and one site stands for all of them.

### Native values

A native function value is `{origins: {builtin(atom)}, callables_top}`. It
has a location, so a write to one of its properties goes through the normal
write rule, and a write through any `builtin` origin records P8 because the
object is shared by every request.

The implicit native value of a static name `N` is `{origins: {builtin(N)},
callables_top}`. The implicit native value of any other access is
`{origins: {builtin(any)}, origins_top, callables_top}`, where `any` is a
reserved atom (0) that stands for every shared runtime object. Both carry a
`builtin` origin, so a write through a copied native function records P8.

An access to the cells of a `builtin` or `native` site adds the implicit
native value: a static read adds that of its name, and a dynamic read, a
scan (`readAll`, a spread snapshot, `reach`) adds that of any access. This
holds when the heap has no entry for the site. A scan of any other site adds
nothing: it reads elements, not properties by name.

A value may be an array when an origin is an array-literal site, an
`allocated_array` or `allocated_any` site, or when `origins_top` is set. A
value may be a native Result when an origin is an `allocated_any` site or
`origins_top` is set. A value may hold native methods when an origin is a
`builtin`, `native`, request, or headers site, or `origins_top` is set. Every
value may be a string, because a join does not keep a primitive alternative.

### Reach

`reach(st, vs)` is the join of every value reachable from `vs`: the values
themselves and, transitively, every cell of every origin (named cells and the
summary, skipping capture sites), plus `top_cell`, plus the implicit native
value of each `builtin` and `native` origin. A worklist of visited sites ends
the walk on a cycle and also follows origins found through `top_cell`. When a
reached value has `origins_top`, the result has `origins_top` and joins every
non-capture cell of the heap. Labels combine with `mergeValues`, because the
operation reads them together. Origins and callables are unions, and
`origins_top` and `callables_top` are ORed. `deep(st, vs)` is the label set of
`reach(st, vs)`.

### Property reads

`storedRead(st, o, N)` is the P2 `readValue`: the cells only, without the
implicit native value. `readValue` in P5 is `storedRead` joined with the
implicit native value of `N` when one of these holds:

- `N` is a `String.prototype` name;
- `N` is an `Array.prototype` name and `o` may be an array;
- `N` is a `Result.prototype` name and `o` may be a native Result;
- `o` may hold native methods.

A `callables_top` stored in a cell always survives. A computed read whose key
is not a literal joins the implicit native value of any access, because the
key may name a method. A computed read whose key is a numeric literal reads
every cell as P2 does and adds nothing beyond the site rule above, because no
method name is numeric.
`readAll` stays a scan: it does not go through the computed-read rule. A match
record-pattern binding of field `N` follows `readValue`.

### Calls through a property

The callee is a `member_access`, an `optional_chain`, or a `computed_access`.

The six Math opcodes come first. Copy the condition of `tryEmitMathBuiltin`
exactly, and cite it in a comment: a `member_access` or `optional_chain`
callee whose object is an identifier named `Math` of kind `global` or
`undeclared_global`, with property `floor`, `ceil`, `round`, or `abs` and one
argument, or `min` or `max` and two. The call is a scalar with the
arguments' labels. The receiver is not evaluated, and an optional callee has
no skip path.

A computed key that is a string literal is a static name: the runtime reads
the same property and calls it with `this` undefined, and the dot-call rule
over-approximates that. A dynamic key, or a receiver with `origins_top`,
records `unknown_callee` and returns `top`.

For any other static name `N`, the receiver `r` and the arguments are
evaluated in order (a call-site spread is refused as in P4). The candidates
are:

1. user functions: `u = storedRead(st, r, N)`. If `u.callables_top`, record
   `unknown_callee` and return `top`. Each function in `u.callables` runs as a
   P4 callee;
2. the string rule for `N`, when `N` is a `String.prototype` name;
3. the array rule for `N`, when `N` is an `Array.prototype` name and `r` may
   be an array;
4. a `Result.prototype` name when `r` may be a native Result: no rule. Record
   `no_operation_rule`;
5. the namespace rule for `(namespace, N)` for each `builtin` origin of `r`
   whose atom names a namespace; any other `builtin` origin has no rule;
6. a `native` origin: no rule. Record `no_operation_rule`;
7. a request or headers origin: record P7.

A candidate with no rule records `no_operation_rule` and the call returns
`top`. When there are no candidates, the runtime fails with `NotCallable`;
the call records `no_operation_rule` and returns `top`, so the rule does not
depend on the completeness of the kind tests. Otherwise each candidate runs
from the state after the arguments, as P4 runs callables: the value is the
join of the candidate values, the state is the join of their states, and
`u.labels` (which holds `r.labels`) joins the value.

An `optional_chain` callee skips the property read, the arguments, and the
call when the receiver is nullish. The skip state is a clone taken after the
receiver and before the arguments. The state after the call is the join of
the skip state and the call state; the value joins `clean`.

### Builtin rules

`r` is the receiver, `as` the argument values, `L = r.labels ∪ deep(st, as)`.
"Fresh array of E" uses the call's `allocated_array` site, joins `E` and the
self value into its summary, and returns the self value with labels `L`.

| Operation | Rule |
|---|---|
| every string method except split | scalar with `L` |
| split | fresh array of `labelled(L)` |
| push, unshift | each argument is written into `r` as `writeValue(st, r, dynamic clean, a)`; scalar with `L ∪ deep(st, [r])` |
| pop, shift | `readAll(r)` |
| splice | read `readAll(r)` first; then write `labelled(labels of start and deleteCount)` and every item from argument 2 on into `r` as push writes them; fresh array of the first read, with `L` |
| indexOf, includes, join | scalar with `L ∪ deep(st, [r])` |
| slice, toReversed, toSorted without arguments | fresh array of `readAll(r)` |
| concat | fresh array of `readAll(r)`, every argument, and `readAll` of every argument |
| JSON.stringify, Object.hasOwn, Array.isArray, every Number function, every Math function except random, String.fromCharCode | scalar with `deep(st, as)` |
| Math.random, Date.now | scalar with `nondeterministic` |
| JSON.parse, JSON.tryParse | the call's `allocated_any` site; its summary holds `labelled(deep(st, as))` and the self value; the value is the self value with labels `deep(st, as)` |
| Object.keys | fresh array of `labelled(deep(st, as))` |
| Object.values | fresh array of `readAll(as[0])` |
| Object.entries | fresh array of `readAll(as[0])` and `labelled(deep(st, as))` |
| Array.of | fresh array of every argument |
| Response.json, text, html, redirect, rawJson | the call's `native` site; its summary holds `reach(st, as)` and the self value; the value is the self value with labels `deep(st, as)` |
| String(x), Number(x), parseInt, parseFloat, isDict, isBytes | scalar with `deep(st, as)` |
| range(n) | the call's `allocated_any` site holding `labelled(deep(st, as))` and the self value |
| requestBody, requestText, requestJson | as JSON.parse (P7 adds the request contents) |
| hole() | as a P4 call that never returns: `st.reachable = false`, the value is `clean`, and the bindings stay for the rest of the expression |
| map, filter, reduce, forEach, every, some, find, findIndex, toSorted with an argument, Array.from, h, renderToString | P5a: record `no_operation_rule`. P5c replaces each row |
| any other function-valued registered name | record `no_operation_rule` |

A property of a namespace that is not a function (a Number constant) reads as
the implicit native value. That is conservative, and it covers the
uninterned `Math.PI` atom.

### Builtin globals

An `identifier` with kind `undeclared_global`:

- a namespace name reads as `{origins: {builtin(atom)}}`. `String`, `Number`,
  and `Response` add `callables_top`, because each is also a function;
- a global function name reads as its native function value. A call whose
  callee is that identifier uses the global-function row above, before the
  callee is evaluated;
- Boolean, Headers, and Request record `no_operation_rule` and read `top`;
- any other name records `refused_by_strict` (the strict checker refuses it)
  and reads `top`.

A direct call of `Response`, or of a namespace that is not callable, follows
the P4 rules on its value: `callables_top` records `unknown_callee`, and no
callable records `no_operation_rule`.

### Virtual-module exports (P5b)

The import table is built once, like `buildModuleFunctions`. It scans every
`import_decl`, reads its module path from `module_idx`, and for each
`import_specifier` maps the local binding atom to the module path and the
`imported_atom`. A module binding resolves to an export when exactly one
declaration binds its local atom (the P4 count, which already counts an
import), that declaration is an import specifier from a `zttp:` path,
`findExport(path, name of imported_atom)` finds the export, and no assignment
targets the local atom. A local binding of the same name has its own binding
kind and never reaches this lookup. An import from a user module, an atom
with no name, or a failed lookup records P8.

A read of a resolved export that is not a callee is its native function value
under the imported atom. A call whose callee is a resolved export identifier
is evaluated before the callee, with arguments `as`:

1. `R = reach(st, as)`.
2. The labels `E` are `R.labels ∪ return_labels`, with `nondeterministic`
   added as the old checker adds it. `env` with a string-literal first
   argument replaces `return_labels` with the `refineEnvLabels` result. No
   other rule removes a label: `validated` joins as a bit and discharges
   nothing until P6. R1 counts a fact computed from an argument as carrying
   it, so an export without `derives_from_args` (for example
   `timingSafeEqual`, `dictHas`) carries `R.labels` too. Policy exceptions
   for such facts belong to the property-to-sink matrix before P9 (R5).
3. Declassification (D14): for an export with `declassify_bound_arg`, when
   that argument node is a literal and `R` has no origin, no callable, and
   neither `top` flag, `E` is the union of `return_labels` and
   `R.labels` without the `declassifies` labels. Otherwise nothing is removed. The summary in step 5
   then holds `labelled(E)` in place of `R`, so no later read restores a
   removed label.
4. Presumed calls: the binding cannot say which parameter is a callback, so
   every function in `R.callables` runs as a callback loop (below) whose
   every parameter is `R` joined with the results so far. `R.callables_top`
   records `unknown_callee`. The precise P5c rows replace this step for the
   seven callback exports, and a missing precise row falls back to it.
5. The result is the call's site (`native` for fetch and fetchWithRetry,
   `allocated_any` otherwise). Its summary holds `R`, the loop results, and
   the self value. The value is the join, with `joinValue`, of `R` with its
   labels replaced by `E`, the loop results, and the self value with labels
   `E`. So it keeps every origin, callable, and `top` flag of `R` and of the
   results. An export can return an argument, a value stored in one, or a
   callback result (validateObject, dictGet, routerMatch, dictFold), and this
   covers each case.
6. The result value is also written, weakly, into the summary of every origin
   of `R`. No native export writes into an argument today, and this keeps a
   future one sound at the cost of precision between containers passed to one
   call.

### Callbacks (P5c)

A callback loop takes the callback value `f`, a parameter vector computed
from the loop head, and an optional accumulator. `f.callables_top` records
`unknown_callee`. Empty `f.callables`, including a missing callback argument,
records `no_operation_rule`.

The head starts as the state after the arguments. Each pass computes the
parameters from the head, runs every function of `f` as a P4 callee, joins
their states into the head (`heap` and `top_cell`; `env` stays the caller's),
and joins their values, each with `f.labels`, into the result set. The loop
stops when the head and the result set stop changing (`stateEql` and
`optValueEql`, which compare the labels, origins, callables, and both flags),
checked before the cap `max_loop_passes`; the cap records `fixpoint_limit`.
The head after the loop includes the state before it, because a callback can
run zero times. The parameters read from the head on every pass, so a
callback that writes the receiver sees its writes.

| Operation | Callback | Parameters | Result |
|---|---|---|---|
| map | arg 0 | `readAll(r)`, clean, `r` | fresh array of the results |
| filter, find | arg 0 | `readAll(r)`, clean, `r` | `readAll(r)` at the final head, with the results' labels; filter in a fresh array |
| forEach | arg 0 | `readAll(r)`, clean, `r` | clean |
| every, some, findIndex | arg 0 | `readAll(r)`, clean, `r` | scalar with `deep(r)` and the results' labels |
| reduce | arg 0 | acc, `readAll(r)`, clean, `r` | acc |
| toSorted(cmp) | arg 0 | `readAll(r)`, `readAll(r)` | fresh array of `readAll(r)`, with the results' labels |
| Array.from(src, f) | arg 1 | `readAll(src)` joined with `labelled(src.labels)`, clean | fresh array of the results; without `f`, of the parameter |
| dictMapValues, dictFilter | arg 1 | `readAll(d)`, `labelled(deep(d))` | the export result, with the results in its summary and value |
| dictFold | arg 1 | acc, `readAll(d)`, `labelled(deep(d))` | the export result joined with acc |
| mapResult, mapError, andThen, orElse | arg 1 | `readAll(r)` | the export result, with the results in its summary and value |

For reduce, acc starts as argument 1, or as `readAll(r)` when there is none.
For dictFold, acc starts as argument 2. acc joins every result. Every
array-method result value also carries `L` from the builtin rules. The
Result.prototype callback methods (map, mapErr, andThen, match on a native
Result) keep their `no_operation_rule` row.

`h(tag, props, ...children)` returns the call's `allocated_any` site; its
summary holds `reach(st, as)` and the self value. `renderToString(v)`
computes `reach(st, [v])`. When that holds a callable or `callables_top`, it
records `no_operation_rule` (a component runs later and mutates `props`).
Otherwise it is a scalar with `deep(st, [v])`.

### Owners

`Phase` loses `p5` and `Owner` loses `p5`. `Owner` gains `no_operation_rule`:
an operation with no rule (R3).

### Census

C1 (builtins). A test runs `initBuiltins` on a context. It has two parts.

Globals: for every name in `known_globals.names` that `ctx.getGlobal` finds,
a callable value must be a global-function row or a callable namespace
(String, Number, Response), and every global-function row must name such a
callable global. A probe that removes one global-function row must fail.

Properties: for every namespace object found that way, and for the objects
`array_prototype`, `string_prototype`, and `result_prototype`, it enumerates
the own properties with `propertyIterator`. Every property for which
`isCallable` holds must have a row in the operation table (a rule or an
explicit `no_operation_rule` row with a reason), and every row must name such
a property. The test asserts a floor on the
number of enumerated properties, and a probe that removes one row must fail
it. After P5c the only `no_operation_rule` rows with a callback reason are
the Result.prototype methods. The HTTP objects of the serving runtime are
outside the zts package; every method on a `native`, request, or headers
origin records `no_operation_rule` or P7.

C2 (exports). The presumed-call rule makes a missing precise row sound, so
the census checks the precise table only: every row names an export that
`findExport` finds, and each row has a test whose secret reaches the result
only through the callback's capture.

## Tests

Each test is an evaluator fixture. A secret test uses `expectSecret` with a
contrast that proves with a literal in place of the secret. A test of an
owner, a label other than `secret`, a callable, or bottom asserts directly
through `analyzeSource` or `Harness`. `s` is seeded secret.

P5a:

1. A user method runs:
   `function f(s) { const o = { m: () => s }; return o.m(); }`.
2. The string candidate runs beside a user method:
   `function f(s) { const o = { slice: () => "c" }; return o.slice(s); }`
   returns the secret.
3. A string method carries its arguments: `function f(s) { return
   "a".concat(s); }`, and its receiver: `s.slice(1)`.
4. `function f(s) { const p = s.split(","); return p[0]; }` is secret.
5. `function f(s) { const xs = []; xs.push(s); return xs[0]; }` is secret.
6. `function f(s) { return [s].pop(); }` is secret.
7. `function f(s) { const a = ["A", "B"]; a.splice(s, 1); return a[0]; }`
   is secret, and splice writes its items.
8. join, indexOf, and includes on `[s]` carry the secret.
9. concat copies an array argument's elements:
   `function f(s) { const g = () => s; const a = [].concat([g]); const h =
   a["0"]; return h(); }` is secret.
10. JSON.stringify of `{ x: s }` is secret; a field read of `JSON.parse(s)`
    is secret; `const p = JSON.parse("[[1]]"); const q = p["0"]; q["0"] = s;
    return p["0"]["0"];` is secret, and `q` has a named origin and no
    `origins_top`.
11. `function f(s) { const o = {}; o[s] = "x"; return Object.keys(o)[0]; }`
    is secret; Object.values and Object.entries of `{ x: s }` are secret.
12. `function f(s) { const o = { ...Response }; const g = o.json; return
    g(); }` records `unknown_callee`.
13. A call on a receiver with `origins_top` records `unknown_callee`.
14. A dynamic method key records `unknown_callee`.
15. `function f(s) { let x = s; const o = { slice: () => "c" };
    o?.slice(x = "c"); return x; }` is secret (the skip path keeps `x`).
16. A write to `Math.x` records P8; so does `const g = parseInt; g.x = s;`.
17. An unknown global records `refused_by_strict`.
18. `function f(s) { return hole() + s; }` has no returned value, no
    completion, and an unreachable exit.
19. `Math.random()` carries `nondeterministic`.
20. A callback method records `no_operation_rule` (until P5c).
21. Property reads: `o.handler` of an object literal has no `callables_top`;
    `o.slice` has it; a stored `callables_top` survives a read of any name.
22. A user global `Math` with a clean `floor` still gives `Math.floor(s)` the
    secret.
23. A method call on a `Response.json(...)` result records
    `no_operation_rule`.
24. `JSON.stringify({ x: 1 })` stays resolved and clean.
25. Reserved: the `allocated_array` test is 51, because `map` is the only name
    shared by `Array.prototype` and `Result.prototype`, and P5a refuses it.
26. Census C1, with a probe that removes one row and fails.

P5b:

27. An identity export (`unescapeHtml(s)`) carries the secret.
28. A fact export carries a nested secret: `dictHas({ x: s }, "x")`.
29. `mask(s, 4)` has no `secret` and has `internal`, and so does
    `String(mask(s, 4))`; `mask(s, n)` with a parameter keeps `secret`.
30. `env("API_KEY")` is secret; `env("PORT")` is config.
31. `validateObject(o)` aliases `o`: a write through the result is read back
    from `o` with a shallow read.
32. `dictGet(dictSet(d, "k", g), "k")` returns a callable that runs.
33. `routerMatch` returns a route handler that runs.
34. A persistent-state reader carries `unknown`; `uuid()` carries
    `nondeterministic`.
35. A validating export keeps `user_input`.
36. An export with no precise row, given a closure that captures `s`, returns
    the secret through the presumed call.
37. `dictFold(d, () => Number, 0)(s)` with no precise row is not resolved to
    a clean result: the presumed-call result keeps `callables_top`.
38. `const r = dictSet(dictEmpty(), "k", "c"); const q = r["k"]; q["x"] = s;
    return r["k"]["x"];` is secret, and `q` has a named origin and no
    `origins_top`.
39. An import from a user module records P8.

P5c:

40. `function f(s) { return [s].map((x) => x)[0]; }` is secret.
41. `function f(s) { return ["c"].filter(() => s)[0]; }` is secret.
42. `function f(s) { const a = ["c"]; const out = a.map((x) => { a.push(s);
    return x; }); return out["0"]; }` is secret (a later pass sees the push).
43. `function f(s) { return [s].reduce((acc, value) => value, "c"); }` is
    secret.
44. toSorted's comparator sees two elements.
45. `function f(s) { const o = { x: "c" }; Array.from(s, (x) => { o.x = x;
    return "c"; }); return o.x; }` is secret.
46. Each of the seven callback exports runs its callback, with a secret that
    only the callback's capture holds.
47. A callback with `callables_top` records `unknown_callee`.
48. The loop records how many passes it needed; a cap of one fewer records
    `fixpoint_limit`, and a cap equal to the need converges.
49. renderToString of a vnode with a component records `no_operation_rule`;
    with only strings it carries their labels; a write into `v.children` is
    rendered.
50. A recursive call through a callback converges.
51. `function f(s) { return s.split(",").map((x) => x)[0]; }` stays resolved
    and is secret: an `allocated_array` is not a possible Result.

## Mutations

Each mutation alone must fail a named test.

| Mutation | Test |
|---|---|
| Run only the user candidates of a method call | 2 |
| Drop the argument labels from a string method | 3 |
| Skip the push write | 5 |
| Return clean from pop | 6 |
| Skip the splice selector write | 7 |
| Read the receiver shallowly in join | 8 |
| Skip the argument cells in concat | 9 |
| Read JSON.stringify's argument shallowly | 10 |
| Drop the self value from an allocated summary | 10, 38 |
| Drop the implicit native value from a snapshot | 12 |
| Resolve a call on an `origins_top` receiver | 13 |
| Drop the skip path of an optional call | 15 |
| Give a native function value no origin | 16 |
| Drop the implicit native value from a read of a String.prototype name | 21 |
| Follow the user `Math.floor` | 22 |
| Read the implicit native value in candidate 1 | 24 |
| Treat `allocated_array` as a possible Result | 51 |
| Drop a census row (a property row, and a global-function row) | 26 |
| Use shallow argument labels in an export call | 28 |
| Keep `R` in a declassified summary | 29 |
| Drop the argument origins from an export result | 31 |
| Drop the argument callables from an export result | 32 |
| Drop the capability `nondeterministic` | 34 |
| Clear `user_input` on a validating export | 35 |
| Skip the presumed call | 36 |
| Drop the result flags from a presumed-call result | 37 |
| Skip the loop fixpoint (one pass only) | 42 |
| Drop the accumulator join | 43 |
| Drop the predicate labels from filter | 41 |
| Drop the callables check in renderToString | 49 |

## Existing tests

The P5 changes move these P4 tests in `flow_interp.zig`:

- "a function declaration binds in statement order" (about line 2540): the
  forward read of `g` follows the new global rule; assert the owner the rule
  gives for its binding kind;
- the two tests that expect owner P5 for a call with no callable (about 2579
  and 3429) expect `no_operation_rule`;
- "a call through a property is P5's" (about 3380): the object and literal
  computed calls resolve; the `map` call records `no_operation_rule` in P5a
  and returns the secret in P5c;
- "a method read into a variable is an unknown callee" (about 3409) stays;
- the tag census (about 3722) loses the P5 phase column.

## Verification

For each commit, run in this order, and read each exit status:

1. `zig fmt --check packages/zts/src/flow_interp.zig`
2. `zig build test-zts`
3. `zig build test-proof-swallow`
4. `zig build test-zts-layering`
5. `zig build check-spine`

Then run each mutation of that commit on a copy and confirm that its named
test fails. The reviewer runs `scripts/verify.sh` before each commit.

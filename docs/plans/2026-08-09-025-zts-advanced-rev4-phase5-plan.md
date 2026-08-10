# Phase 5: Bytes, ABI Re-typing, Defaults, and the Effects Ceiling - Implementation Plan

**Goal:** Give the profile its binary value and its typed framework boundary.
`Bytes` as a real value kind with an immutable pure surface, `zttp:bytes` over
it, the HTTP, WebSocket, queue, and durable ABIs re-typed to the shapes spec
section 7.2 requires, trailing scalar default parameters, and the parts of the
decidable `Effects` ceiling rule that measurement shows are still open.

**Exit (from the roadmap):** fetch, websocket, and queue examples re-typed;
ceiling-rule repair tests.

**Source of truth:** `docs/zts-formal-spec-northstar-advanced.md` revision 4,
sections 6.3, 7.2, 5.2's default-parameter paragraph, and 5.7's ceiling
sentence; plus
[D2 effects and purity](2026-07-30-015-d2-effects-purity-design.md) sections 4
and 5, which own the ceiling decisions this phase consumes.

## Scope decisions, stated before the tasks

**The ceiling rule is mostly shipped, and this plan says so rather than
re-planning it.** The roadmap's phase 5 line reads "the decidable `Effects`-
ceiling rule with repairs computed from the inferred row" as though it were
unbuilt. It is built: both halves report at severity `error`, always on, with
the repair computed from the row. Task 9 is what measurement left over, and it
is two named gaps rather than a track.

**`Response.json` does not become fallible in this phase, and the reason is
recorded rather than assumed.** Spec 7.2 requires `responseJson<T>` to return
`Result<Response, JsonError>` with one result type at every call site. Making
the shipped global fallible rewrites the return statement of every handler in
the repository. Removing or reshaping published surface is what phase 7's direct
cutover is for, and that is the precedent already set for `unwrap`, `|>`, and
`interface`. What this phase does instead is the half that costs no migration
and closes a real hole: the encodability failure that today throws out of
`Response.json` becomes a compile-time refusal wherever `T` decides it. The
residual - the size limit, which no payload type discharges - stays a runtime
fault, and the spec MUST stays partly open with its closing pinned to phase 7.
The plan states this rather than narrowing the exit quietly.

**`zttp:crypto`'s string base64 and `zttp:bytes`'s binary base64 both ship.**
Spec 6.3 puts `encodeBase64` and `decodeBase64` in the zero-capability bytes
module over `Bytes`. `zttp:crypto` already ships `base64Encode` and
`base64Decode` over strings, both marked `.pure` with an `inverse_of` law. The
two pairs are the same operation over different domains; the string pair is
transport encoding for text and the binary pair is the one spec 6.3 names.
Deduplication is phase 7's, for the same reason as the paragraph above.

## Ground truth measured on 2026-08-09

| Assumed | Measured | Consequence |
|---|---|---|
| `Bytes` can reuse the typed-array machinery | `ClassId` reserves `typed_array = 7` and `object.zig:177` interns the name `Uint8Array`, and neither has storage, a constructor, or a builtin file. `new` is outside the subset, so no typed array is constructible from source at all | `Bytes` is a new runtime class kind with its own immutable storage, on the pattern `dict = 24` set in phase 4 - not a wrapper over an unimplemented reservation |
| `Bytes` is a parameterized type like `Dict` | `TypeTag` carries `t_dict` with a key and a value, but `Bytes` has no parameters and cannot contain a cycle | `Bytes` is a pool primitive with an `idx_bytes` slot beside `idx_string`, not a constructor - and it is **not** added to the contractivity guard set phase 3 and 4 built, because nothing recurses through it |
| The binding surface can already describe a `Bytes` export | `ReturnKind` has ten members and no `bytes`; `param_types` reuses the same enum | `ReturnKind.bytes` is the one-line widening `dict` needed in phase 4, and every `zttp:bytes` export types through it |
| `when Bytes:` is an unimplemented gap | It is refused by name at `parse.zig:1255` with a message naming this phase, `TypeTestKind` has five members, and `ir.zig:507` carries the comment that `Bytes` joins in phase 5. A test pins the refusal | The deferral is a wired site. Task 4 removes one branch, adds the sixth member, and flips the test from refusal to lowering |
| `abi_types.zig` describes the HTTP ABI | It registers exactly one type - `Response`, a nominal record of four fields - and `RESPONSE_CONSTRUCTORS` names four constructors. There is no `Request` type anywhere: `Request` is a `known_globals` name that resolves to a bare `t_ref` | The request side of spec 7.2 is a first typing, not a re-typing. The three request readers have nothing to be declared against yet |
| `Response.json` is total | `http.zig:226` calls `try valueToJsonString`, so a non-encodable payload propagates a Zig error and throws. The subset has no `try/catch` | The failure spec 7.2 wants a `Result` for already exists, with no admitted way to handle it. That is the concrete argument for the encodability check, not a style preference |
| The four constructors are the whole surface | `Response.rawJson` is a fifth. `object.Atom.rawJson` exists, `contract_builder.zig:3723` handles it, `handler_analyzer.zig` matches it in four places, and `RESPONSE_CONSTRUCTORS` omits it | The checker does not know a constructor the contract builder does. Task 5 types it or refuses it; leaving it unlisted is the fail-open shape this repository has been bitten by |
| `fetch` is untyped and needs a signature | `module_types.zig:164` already special-cases `zttp:fetch`.`fetch` with a hand-built response record, and truncates its parameter list to one, so the `init` argument types as nothing at all | `FetchOptions` replaces a special case rather than adding one. One special case is also the argument for the general mechanism task 5 builds |
| Module signatures are coarse by necessity | They are coarse by mechanism: `returnKindToTs` maps the ten-member enum to text and `parseTypeExpr` parses that text into the pool, and the frozen-signature gate runs the whole pipeline over every export today | A per-export declared signature is an override on the text step of a pipeline that already exists and is already gated, not a new channel |
| Default parameters are unimplemented | The parser stores the default on the parameter's pattern element (`ir.zig:582`), `has_default_params` sits on the function, and `strict_checker.zig:881` reports ZTS617 at `.err`. `codegen.zig:1815` records only `arg_count = func.params_count`, and no site reads `default_value` for a parameter | The form parses and is refused. What does not exist is the lowering. `frame.zig:129` fills every missing local with `undefined`, so reversing ZTS617 on its own would make every declared default silently vanish |
| ZTS617 is what a caller hits | Measured on a two-line handler through `zts check`: an omitted argument reports `wrong number of arguments: expected 1, got 0` from the type checker and the canonical band reports OK on that run. Supply every argument and ZTS617 fires instead | Two rules refuse this form and they are ordered, with the arity rule first. A task that only reverses ZTS617 moves nothing an author can observe |
| The decidable ceiling rule is this phase's work | It shipped. `precompile_check.zig:293` reports ZTS610 for the exported half with a repair computed from the inferred row, `:317` reports ZTS623 for the internal half, both at severity `error`, both unconditional | What is left is narrow and is task 9. Both halves additionally require `cap.handler_reachable`, a qualifier spec 5.7 does not contain |
| D2's I3 is done | An unresolvable callee sets `EffectRow.lower_bound` and reports ZTS512 instead of contributing every capability, which is the fail-closed marker D2 asked for. No `FunctionType` carries a declared ceiling anywhere in `type_pool.zig` | The marker landed and the mechanism did not. A typed callback cannot contribute its declared row, and a capsule-free function type does not yet mean the empty row |

Two further facts that decide where new code goes:

`semantics.zig` pins the IR alphabet at 82 named `NodeTag`s and the opcode
alphabet at 130. `Bytes` construction is a module call and has no literal
spelling, so the bytes tracks add no node - the same argument phase 4 made for
`Dict`, and the same argument that killed its comptime task. Default parameters
are different: they change lowering, and whether that lowering needs an opcode
is the first thing task 8 decides. Either way the pin is moved or acknowledged
in the same commit that trips it.

Free diagnostic codes: ZTS207 and ZTS213 upward in the type-checker band;
ZTS513 upward in the contract band; ZTS629 upward in the canonical band.

## Global constraints

- The engine stays interpreter-only. `Bytes` is the value kind spec 6.3 names,
  so it is growth the spec asks for; nothing else is.
- Each admitted form adds its semantics-registry rules in the same task.
- No `meta` payload content is hand-written. `packages/modules/module-specs/`
  and the Module Catalog table are regenerated from the bindings, never edited.
- Every task: `zig fmt` on touched files, tests in `test "..."` blocks next to
  the code, the named test step run before and after, one commit per task,
  never push.
- Phase boundary gate: `bash scripts/verify.sh` green, `zig build test` green,
  `bash scripts/test-examples.sh` green.
- A gate asserts a floor on its own input before its count means anything, and a
  probe's verdict is read from the build's exit status.
- Every new module export is probed for the laundering class before its task
  closes: return a labelled value through it and confirm the diagnostic
  survives. `derives_from_args` is the declaration, and an export that declares
  nothing answers the empty set.

---

### Task 1: the `Bytes` value

**Files:** `object.zig` (class id), a new `bytes.zig` beside `dict.zig`,
`gc.zig` (tracing), `value.zig` (`isBytes`), `context.zig` (`createBytes`).

`ClassId.bytes` with an immutable octet buffer of its own. Every operation spec
6.3 names returns a new value or a scalar, so the storage is written once at
construction and never mutated, which makes tracing a single edge rather than
the entry-vector-plus-index pair `Dict` needed.

Construction validates every octet: a `bytesFromOctets` input element that is
not an integer in `[0, 255]` is `invalid-octet` with its index and its value,
not a truncation. Equality is content equality over the buffer.

Allocation goes through `ctx.createBytes`, which picks the request arena the way
`createDict`, `createArray`, and `createObject` do. This is not a precaution:
phase 4 measured a `Dict` built from `ctx.allocator` inside a request leaking,
invisible when serving by hand and caught only by the behavioral runner that
builds and destroys a runtime per case.

**Tests:** an octet outside `[0, 255]` is refused with its index; a fractional
octet is refused rather than truncated; two independently built buffers with the
same octets are equal; a slice does not alias its source after the source is
collected; the behavioral runner reports no leak for a handler that builds bytes
per request.

### Task 2: `Bytes` in the type system and the binding surface

**Files:** `type_pool.zig` (`t_bytes`, `idx_bytes`, printing, canonical key,
assignability), `type_env.zig` (the `Bytes` type name), `type_key.zig`,
`packages/zttp-sdk/src/binding.zig` (`ReturnKind.bytes`), `module_types.zig`.

`Bytes` is a primitive with its own pool slot, resolved from the identifier
`Bytes` the way `number` and `string` are resolved. It is assignable only to
itself and to `unknown`; in particular it is not assignable to `object`, which
is the check the request side of task 5 depends on, and a `string` is not
assignable to it, which is the confusion spec 6.3 exists to prevent.

It does not join the contractivity guard set, and the reason measured on
2026-08-09 is stronger than the one written here first. `Bytes` is a leaf that
names no type, so no cycle can pass through it in either direction: it can
neither guard a cycle nor close one. Adding `.t_bytes` to `reachesUnguarded`'s
guard list changes no program. The guard set is left alone because the edit is
inert, not because the edit would admit something.

`ReturnKind.bytes` and its `returnKindToTs` row make the frozen-signature gate
cover every `zttp:bytes` export by construction.

**Tests:** `Bytes` resolves from its identifier and prints as `Bytes`; a `string`
is not assignable to `Bytes` and the reverse holds too; `Bytes` is not assignable
to `object`; a brand over `Bytes` is assignable to `Bytes` and not the reverse,
which is the only way the same-tag rule is reached at all - a plain `Bytes` is a
singleton index and settles by identity first; two independently parsed `Bytes`
share a canonical digest; a record-guarded alias carrying a `Bytes` field is
accepted while `type B = Bytes | B` is still refused.

Two expectations written here before measurement did not hold, recorded rather
than forced. The ZTS212 test - "a recursive alias whose only cycle passes
through `Bytes`" - is unwritable for the leaf reason above. And the
frozen-signature digest does not move in this task: it is computed from the
text each export's declared kinds emit, and no binding declares `.bytes` until
task 3. The digest moves there. What lands here instead is a test that walks
the `ReturnKind` enum itself, so a kind whose `returnKindToTs` row does not
parse fails when the kind is added rather than when an export first uses it.

### Task 3: `zttp:bytes`

**Files:** new `packages/zts/src/modules/data/bytes_mod.zig`,
`builtin_modules.zig`, `module_types.zig`.

The nine exports of spec 6.3, zero capabilities, every one pure:
`bytesFromOctets`, `bytesLength`, `byteAt`, `sliceBytes`, `concatBytes`,
`encodeUtf8`, `decodeUtf8`, `decodeBase64`, `encodeBase64`.

The module lands in the engine tier beside `collections.zig` and `json_mod.zig`
for the reason phase 4 measured: a module under `packages/modules/src/` reaches
the engine only through the SDK, and the SDK cannot mint a class.

`BytesError` is the closed taxonomy spec 6.3 names - `invalid-octet` with index
and value, `invalid-encoding` with encoding and offset, `invalid-bounds` with
start and end, `size-limit` with the limit. `byteAt` out of range is `undefined`
rather than an error, and the three `Result`-returning exports are the ones the
spec marks fallible and no others: an infallible operation that returns a
`Result` costs every call site a guard for a branch that cannot be taken.

Every export is `derives_from_args` except `bytesLength` and `byteAt`, whose
results are facts about the argument rather than data from it - which is the
distinction `FunctionBinding.derives_from_args` documents and the one the
sweep in `b5f8a7d2` was needed to correct across twenty-one exports.

Every export is `replay_pure`, audited rather than inferred: each reads only its
arguments. Without the opt-in, the handler-test runner installs a stub that
returns `undefined` for all nine.

**Tests:** UTF-8 round-trips including an astral scalar; `decodeUtf8` of an
invalid sequence reports `invalid-encoding` with its offset and not
`invalid-octet`; base64 round-trips and rejects a bad alphabet; `sliceBytes` with
start after end reports `invalid-bounds` with both; `byteAt` past the end is
`undefined`; `concatBytes` of an empty list is the empty value; the laundering
probe - a secret through `encodeBase64` still reports.

### Task 4: `isBytes`, the `when Bytes:` type test, and `parseJsonBytes`

**Files:** `type_checker.zig`, `match_analysis.zig`, `parser/parse.zig`,
`parser/ir.zig`, `bool_checker.zig`, `modules/data/json_mod.zig`.

`isBytes` joins `Array.isArray` and `isDict` as a specified intrinsic guard,
narrowing a union to its `Bytes` members and refining `unknown` to `Bytes` -
the same refinement phase 4 had to add for `isDict`, and for the same reason: a
`Result`-returning export types its payload as `unknown`, so the guard is
written at exactly the site where a member-less union would be unusable.

`TypeTestKind` gains `bytes`, `parse.zig:1255` stops refusing the pattern and
lowers it, and the test that pins the refusal becomes the test that pins the
lowering. This completes spec 5.5's six type tests.

`parseJsonBytes` is declared in `zttp:json` now that its parameter type exists.
Phase 4 left it out deliberately, because a declared export whose type does not
exist is the fail-open the frozen-signature gate is for.

**Tests:** `when Bytes:` lowers and narrows in the arm it guards and not in the
others; a union of the six kinds is exhaustive without a `default`, and dropping
the `Bytes` arm undoes that; `isBytes` refines `unknown`; `parseJsonBytes` over
UTF-8 bytes agrees with `parseJson` over the same text; `parseJsonBytes` over
invalid UTF-8 reports `invalid-encoding` and not `invalid-syntax`.

### Task 5: the HTTP ABI - `Request`, the readers, and the declared-signature mechanism

**Files:** `abi_types.zig`, `packages/zttp-sdk/src/binding.zig`,
`module_types.zig`, `http.zig`, `type_checker.zig`.

Three pieces, in this order.

**A declared signature on a binding.** `FunctionBinding` gains an optional
signature text. `returnKindToTs` consults it before falling back to the coarse
enum, so `parseTypeExpr` builds the precise type from source the binding owns.
This is an override on a pipeline that ships and is gated, and it retires
`module_types.zig`'s `is_fetch` special case as its first customer. The
frozen-signature gate covers it by construction, and its "no fallback to
`unknown`" assertion is what stops a mistyped signature from degrading quietly.

**`Request` gets a type.** Today it is a `known_globals` name resolving to a
bare `t_ref`, so every property read off a request answers nothing. It becomes a
nominal record with the fields the runtime actually sets, read off the runtime
rather than guessed, exactly as `Response` was built. Route parameters, headers,
method, and URL get precise or opaque types; nothing enters as `unknown`.

**The readers and the constructors.** `requestBody`, `requestText`, and
`requestJson` are declared with the spec's types, the second and third fallible
with `BodyError`. `Response.text` is bound to the total `responseText` role, and
`Response.json` gains the encodability check: its argument is admitted only when
its type satisfies the section 6.4 rule `stringifyJson<T>` already implements,
so a payload that would throw is refused at compile time wherever `T` decides
it. `Response.rawJson` is typed rather than left off the list; a constructor the
contract builder knows and the checker does not is a gap in the wrong direction.

**Tests:** a header read off a `Request` types; `Response.json` of a
function-valued or `Bytes` field is refused by the checker rather than at
runtime; `Response.json` of an encodable record still passes; `rawJson`
appears in `RESPONSE_CONSTRUCTORS` and types; a binding with a declared
signature parses with no fallback to `unknown`; the corpus digest is re-pinned;
the three readers type and refuse a non-`Request` argument, and their error
taxonomy is pinned at run time.

Four expectations written here before measurement did not hold, recorded rather
than forced.

A `Request` **is** assignable to `object`. `object` means object-like and a
request is an object; refusing would make every `object`-typed parameter reject
a request for no property the caller could name. The brand still refuses a
`Response`, a `Bytes`, and a record carrying one of its fields.

`requestJson`'s error arm cannot be spelled as `JsonError | BodyError`. The
checker's `Result` is one fixed record shared by every fallible export, with
`value: unknown` and no type parameters, so `Result<string, BodyError>` and
`Result<JsonValue, JsonError | BodyError>` both collapse to it. The runtime
error records carry the spec's taxonomy exactly and are pinned by test there.
The precise spelling waits on the parameterized `Result` that phase 7's cutover
brings, alongside `responseJson`, which is deferred there already.

`BodyError` has no definition in spec 7.2 - the section names the type and
never lists its members. Two are chosen here and recorded at the site:
`absent`, because the runtime writes `undefined` for a request without a body,
and `invalid-encoding` with the encoding and offset, reusing the shape
`zttp:bytes` uses for the same failure, because nothing upstream validates that
a body is UTF-8.

The encodability rule runs the opposite way from spec 6.4's phrasing. The spec
admits only scalars, arrays, tuples, records, and string-keyed `Dict`; the
checker refuses what is definitely wrong and stays quiet otherwise. The
difference is `unknown`, which the strict reading rejects and which is what a
`Result` payload and a parsed document type as today - so the strict reading
would refuse `Response.json(parsed.value)` in every handler that has one.

### Task 6: `zttp:fetch` re-typed

**Files:** `packages/modules/src/net/fetch.zig`, `module_types.zig`,
`examples/fetch/*.ts`.

`FetchOptions` as spec 7.2 spells it: a literal-union method, `Dict<string,
string>` headers, a `string | Bytes` body, and a numeric timeout, every field
optional. `fetch` returns `Result<Response, FetchError>` with a closed error
taxonomy rather than the hand-built response record `module_types.zig` supplies
today, and the parameter truncation that made `init` type as nothing goes away
with the special case.

`fetchWithRetry` keeps its third argument and gets the same treatment. Its
`return_labels` stay `.external`, which is correct and unaffected: a response
body is data from the host, not from the arguments.

The three `examples/fetch/` handlers are re-typed in the same commit, since they
are half of the roadmap's exit sentence.

**Tests:** an options object with a bad method literal is refused; a `Bytes`
body is admitted and a number body is not, measured through `fetchSync` because
the replay path stubs `fetch` before its init is parsed; `FetchOptions` names
what the runtime reads and not `timeoutMs`; the three examples check clean and
their recorded I/O fixtures still replay.

`FetchOptions` is not section 7.2's shape verbatim, and every difference is
measured against `runtime_http.zig` rather than chosen.

`timeoutMs` is absent: the spec names it and nothing reads it, so declaring it
would type a value that does nothing.

`query`, `maxResponseBytes`, and `durable` are present and the spec omits all
three. Each ships and each is read. `query` in particular is what keeps an
egress host a compile-time literal while its values vary per request, which is
the property `examples/fetch/weather-app.ts` exists to prove.

`headers` is the opaque `object` where the spec writes `Dict<string, string>`.
The runtime walks an object's properties and has no Dict path, so the spec's
type would refuse the object-literal form every handler uses and admit a Dict
the runtime would ignore - wrong in both directions at once. Aligning the two
ends is a runtime change and belongs with the phase 7 pass that also closes
`timeoutMs`.

`body` is `string | Bytes`, the spec's own type, and it was a lie until this
task: the runtime answered `InvalidBody` for a Bytes. It accepts one now.

The return stays the precise response record rather than `Result<Response,
FetchError>`, for the reason already recorded under task 5: the checker's
`Result` has no type parameters, so both arms collapse. Phase 7's parameterized
`Result` is where that lands, alongside `responseJson` and `requestJson`.

### Task 7: WebSocket and queue re-typed

**Files:** `packages/modules/src/net/websocket.zig`,
`packages/zts/src/modules/workflow/queue.zig`, `type_env.zig`,
`examples/websocket/chat.ts`.

`SocketId`, `MessageId`, and `ReceiptId` as distinct types over `string`, using
the `distinct type` mechanism `type_env.zig` already resolves. `WebSocketEvent`
and `WebSocketCommand` as the tagged unions spec 7.2 names, with `string | Bytes`
payloads now that `Bytes` exists. `QueueMessage<T>` and `QueueDecision` likewise,
and `send<T>` requiring a statically JSON-encodable payload - the same
encodability rule task 5 wires into `Response.json`, applied at a second site,
which is the check that it generalizes rather than special-cases.

The six `zttp:websocket` exports currently declare `.object` receivers and
`.string` payloads. Each gets its declared signature. The per-export capability
rows stay exactly as they are: that audit is done and this task does not reopen
it.

`examples/websocket/chat.ts` is re-typed in the same commit. It is the other
half of the exit sentence, and it is the only websocket example, which the exit
gate has to say out loud rather than imply breadth it does not have.

**Tests:** a `SocketId` is not interchangeable with a bare `string` and a
`MessageId` is not interchangeable with a `SocketId`; a command union missing an
arm is non-exhaustive; `send<T>` of a function-valued payload is refused;
`chat.ts` checks clean.

### Task 8: trailing scalar defaults

**Files:** `parser/codegen.zig`, `type_checker.zig` (arity),
`strict_checker.zig` (ZTS617 reversal), `rule_registry.zig`,
`packages/tools/src/canonicalize.zig` (the retired rewriter),
`contract_types.zig` (recorded arity), `semantics.zig` if an opcode lands.

The order is forced by measurement and is the point of this task. Reversing
ZTS617 first would leave the arity error in front of the author and, once that
too were relaxed, would make every declared default evaluate to `undefined`.

**Lowering first.** The default expression is already stored on the parameter's
pattern element. It must be accepted by `comptime()`, be assignable to the
declared parameter type, and produce only `null`, a boolean, a finite number, a
string, or a distinct type over number or string - spec 5.2's list, enforced
rather than described. Arrays, records, `Bytes`, `Dict`, closures, and
capabilities are refused, which is what keeps the form free of allocation,
effect, and resource order. The evaluated constant is embedded and selected
before body entry, so omission and an explicit `undefined` both select it and
the body sees the declared non-optional type. Whether the selection needs an
opcode or composes from existing ones is decided here, and the semantics pin is
moved or acknowledged in the same commit.

**Arity second.** Minimum and maximum arity are recorded on the checked
declaration and in the module registry - the same pair `FunctionSig` already
carries for module exports through `required_param_count`. A call may omit only
trailing defaulted positions. Viewed through a fixed-arity function type,
omission is not inferred from the type alone.

**The refusal last.** Non-trailing defaults, rest parameters, and
runtime-evaluated defaults stay refused. ZTS617 narrows from "default parameter
values are not part of canonical ZigTS" to those three cases, keeping its code
and changing its description, help, and repair. The canonicalizer's
`lift_default_to_body` rewriter retires with the rule that drove it, and its
removal is the check that no other rule depended on it.

**Tests:** an omitted trailing argument sees the declared default and a supplied
one overrides it; an explicit `undefined` selects the default; a non-trailing
default is refused; a default that is a record, an array, or a call is refused;
a default not assignable to the declared parameter type is refused; a call
omitting a non-defaulted position still reports the arity error; the recorded
minimum and maximum arity appear in the contract; the canonical corpus trips the
narrowed ZTS617 on its three remaining cases and is silent on the admitted form.

### Task 9: the ceiling rule's two open halves

**Files:** `packages/tools/src/precompile_check.zig`, `contract_builder.zig`,
`effect_inference.zig`, `type_pool.zig`, `type_env.zig`, `rule_registry.zig`.

**The reachability qualifier.** Both halves of the rule test
`cap.handler_reachable`. Spec 5.7 says "an exported function with a nonempty
inferred effect row MUST declare" with no such condition, so an exported helper
the handler never calls declares nothing and reports nothing today. The
qualifier comes off. If dropping it turns out to fire on shapes the corpus
contains for a defensible reason, that reason is recorded at the site and in
this plan - it is not restored silently.

**Function-type ceilings.** D2 section 4's I3 has two parts and the second did
not land. A `FunctionType` whose return type is `Effects<T, R>` declares that any
value of that type performs at most `R`, and a function type with no capsule
declares the empty row - a pure callback, which is spec 6.5's "its callback MUST
be pure" made representable. A call through a parameter or a function-typed value
contributes that type's row instead of setting `lower_bound`, and assigning a
function into a function-typed position checks row subset in the same direction
as every other ceiling. `lower_bound` and ZTS512 stay for the genuinely
unresolvable callee, which is the fail-closed answer and stays fail-closed.

**ZTS507 and ZTS508.** D2 section 5 asked for the docs-mode warnings to collapse
into the always-on rule. Measurement says ZTS610 now covers what ZTS507 warns
about, so this is a deletion rather than a merge - unless the two differ on some
input, in which case the difference is what justifies keeping both and is
recorded. Either way `--require-export-capsules` and its help text end this task
consistent with what the rules actually do.

**Tests:** an exported helper with a nonempty row that the handler never calls
reports ZTS610 with the repair computed from its row; a pure-typed callback
parameter rejects an effectful function assigned to it; a callback parameter
typed `Effects<T, "clock">` contributes clock and not the whole set; a genuinely
unresolvable callee still sets `lower_bound` and reports ZTS512; the ceiling
repair text names the exact capabilities and parses back as a valid annotation.

### Task 10: the exit gate

**Files:** a new example under `examples/patterns/`, plus the tests that pin it,
`docs/coverage.md`, `docs/convergence.md`.

The gate is the roadmap's exit sentence made executable, and its input floor is
asserted before its verdict means anything.

One handler that reads a request body as `Bytes`, decodes it as UTF-8, parses it
with `parseJsonBytes`, dispatches on the six-arm `match` including `when Bytes:`,
calls a helper with a trailing defaulted parameter, and returns through a
constructor whose payload the encodability rule admits. It declares an `Effects`
ceiling that the inferred row makes mandatory, and a second exported helper that
the handler does not call declares one too - which is the observable for task 9's
first half and would report nothing before it.

The re-typed `examples/fetch/`, `examples/websocket/chat.ts`, and the queue
example are the roadmap's named exit and are checked in the same gate. The gate
says plainly that websocket coverage is one example, because a count is what a
reader will assume otherwise.

Floor assertions: an empty body and a zero-length octet list each fail rather
than passing over nothing; deleting the defaulted call from the example makes the
default test fail; deleting the unreached exported helper makes the ZTS610 row
disappear. A probe's verdict is read from the build's exit status, not from a
grep over its output.

`docs/coverage.md` and `docs/convergence.md` are regenerated in the same commit
as whatever changes them.

---

## Risks

`Bytes` is the second new runtime class this program adds, and the GC is where a
new class kind is most likely to be wrong in a way tests do not see. Its buffer
is one edge rather than `Dict`'s two, which makes it the easier case, and the
same soak that checked `Dict` checks it.

The declared-signature mechanism in task 5 is the piece with the widest blast
radius. It changes how every module export's type is built, and a mistyped
signature degrades to `unknown` exactly where the checker stops asking
questions. The frozen-signature gate's "no fallback to `unknown`" assertion is
the defense, and it must be confirmed to still hold over the widened path rather
than assumed to - a gate whose input changed shape is a gate whose floor needs
re-checking.

Task 8's lowering is the one place in this phase where a silent wrong answer is
possible rather than a loud one. A default that evaluates to `undefined` looks
like an omitted optional argument at every downstream site, and the arity rule is
what has kept that unobservable so far. The test that an omitted argument sees
the declared value is therefore written before the lowering, and it must fail
first.

Dropping `handler_reachable` in task 9 widens an always-on error rule over the
whole corpus at once. If it fires broadly, the honest reading is that the corpus
has exported helpers with real rows and no ceilings, and the repair is computed,
so the fix is mechanical. If it fires on something the repair cannot express,
that is a finding about the repair and gets recorded rather than suppressed.

Re-typing the four ABI surfaces changes what the checker refuses in handlers
nobody edited. `examples/` is the measurement, and a break there is the intended
signal rather than an accident - but the phase-boundary gate has to run
`scripts/test-examples.sh`, not just `zig build test`, for that signal to arrive.

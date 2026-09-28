# M5 A3 design note: the SSE framer and strict JSON strings

Status: accepted by the owner on 2026-09-28, with the recommended answer to each
question in section 8 (section 9 records them). Revised once before acceptance
after a design critique (run on Opus; Fable credits were exhausted) and a
citation check. Unit A3 of the
[M5 release contract](2026-09-27-m5-agent-handler-release-contract.md) is
written against the approach this note names; check C-A3 is its completion
check.

All citations are to local `main` at `0985de29`.

## 1. What A3 must deliver

The contract (decision 4, A3, C-A3) asks for a provider-neutral native module
that splits a complete buffered body into SSE events, each with an event name,
data, and id, or answers a tagged framing failure, with per-event and per-body
byte bounds. It passes its argument through, so it declares `derives_from_args`.
M5b adds an incremental form. And `zttp:json` must refuse a raw control byte
inside a string, as RFC 8259 section 7 requires, with a named error and an
offset.

C-A3's corpus: LF, CRLF, and CR line endings, comment lines, multi-line data,
`id`, `event`, and a leading BOM. Its failure tags: oversized event, oversized
body, invalid UTF-8, and a final frame with no terminator.

## 2. What exists today

**No SSE parser** exists in the runtime or modules tree; Studio only writes SSE
(`packages/runtime/src/studio.zig:151`, `:210`, `:491-497`). The provider parsers
in `packages/pi/src/providers/*/sse_parser.zig` cannot be reused: the
`zttp-modules` package imports only `zttp-sdk` (`packages/modules/build.zig`).
The OpenAI parser also splits on LF only, keeping an interior lone CR in the
line and stripping a trailing one, dispatches an unterminated final record, and
has no id, BOM handling, or bounds (`openai/sse_parser.zig:75-91`).

**Module shape.** `zttp:tool` (`packages/modules/src/http/tool.zig:26-123`) is a
template for a Result export with a closed `Refusal` enum; `text.zig:17-27`
shows pure exports with `derives_from_args`. There is no array return kind
(`packages/zttp-sdk/src/binding.zig:20-39`), so the record shape goes in the
export's `signature` text, as `ledger.zig:97-107` does. Arrays and records are
built with `createArray`, `arrayPush`, `createObject`, and `objectSet`, and a
tagged error with `resultErrValue` (`zttp-sdk/src/root.zig:69-90`,
`ratelimit.zig:238-252`). The SDK test shim stubs array and object building
(`zttp-sdk/src/test_shim.zig:124`, `:205-230`), so the framer's core must be a
pure Zig function with a thin JS layer.

**Registration and pins.** A new module takes entries in
`packages/modules/src/root.zig`, `packages/zts/src/builtin_modules.zig`
(`runtime_builtins`, `builtin_governance_entries`, and the last-entry test at
`:421`), the generated spec and virtual-modules table (`zts module-spec-render`),
and `docs/internals/capabilities.md`. It moves `EXPECTED_BUILTIN_HASH`, the
expert and module goldens, the frozen signature digest, the language-overview
counts, and the module count in `docs/consumer-contract.md` (`:629-630`; the
qualifier at `:643` already says 27 and is stale). The envelope gains the new
module's binding digest, and its registry hash moves; existing digests do not
(`packages/tools/src/vocab_envelope.zig:231`). The registry hash enters the
compiler metadata identity the codegen corpus checks
(`packages/pi/src/expert_codegen_record.zig:4161`), so the DeepSeek cassettes go
stale, as they did in A1. The policy hash does not move.

**`zttp:json`.** `readString` appends every byte that is not a quote or a
backslash (`packages/zts/src/modules/data/json_mod.zig:181-246`, at `:195`); keys
and values both go through it. The error taxonomy is a closed union in spec 6.4
(`docs/zts-formal-spec-northstar-advanced.md:1577-1583`); `invalid-syntax`
already carries an offset (`json_mod.zig:388-424`). `requestJson` shares this
parser (`packages/zts/src/http.zig:18`, `:114-120`). The ambient `JSON.parse`
already refuses bytes below 0x20 (`builtins/json.zig:349`, `:388`, `:415`,
`:454`; tested at `:626`).

## 3. The module

`zttp:sse`, file `packages/modules/src/net/sse.zig`, one export:

```ts
sseEvents(body: string, bounds: { maxBodyBytes: number; maxBlockBytes: number; maxEvents: number })
  : Result<{ event: string; data: string; id: string }[], { tag: string; offset: number }>
```

It declares no capability, `effect = .none`, `laws = .pure`,
`replay_pure = true`, and `derives_from_args`. `failure_severity = .critical`,
because an adapter that ignores a framing failure would act on a partial
provider answer.

**Parsing** follows WHATWG HTML section 9.2, "Parsing an event stream" and
"Interpreting an event stream": one leading U+FEFF is skipped; a line ends at
CRLF, LF, or a lone CR; an empty line dispatches; a line starting with `:` is a
comment; a field is the text before the first colon and the value is the text
after it, minus one leading space; a line with no colon is a field with an empty
value; `event` sets the type, `data` appends the value and a LF, and `id` sets
the last event id unless the value contains U+0000. `id:` with an empty value
resets the last event id to the empty string, which is the same output as no id
ever set. On dispatch, an empty data buffer dispatches nothing; otherwise one
trailing LF is removed, the type defaults to `message`, and the event carries
the last event id, which persists across events as WHATWG says.

**Three deliberate differences from WHATWG** (Q1):

- Invalid UTF-8 is refused with `invalid_utf8`, where WHATWG replaces it with
  U+FFFD. A replacement would hand the adapter a string the provider did not
  send. Whether a zts string can hold invalid UTF-8 is checked first; if it
  cannot, the tag is unreachable from JS, and the census carries a row that
  names that mechanism, with the tag still tested at the Zig core.
- A stream that ends inside an event block is refused with
  `unterminated_event`, where WHATWG discards the block silently. It is defined
  by parser state at end of input: refused when the current line is not empty
  (a comment line included), or when any field line has come after the last
  blank line, whether or not it carried data. A final lone CR ends a line, as it
  does mid-stream. A terminated block that dispatches nothing, such as
  `event: x` followed by a blank line, is not refused.
- `retry` is ignored, where WHATWG uses a digits-only value as the reconnection
  time. A buffered body has no connection to re-establish.

**Bounds.** One `bounds` object, every field an integer from 1 to a named
encoding maximum, not a recommended value: `maxBodyBytes` (8 MiB) bounds the
input; `maxBlockBytes` (8 MiB) bounds the raw bytes of one event block, from its
first line through its blank line, comments and ignored fields included, so it
bounds data, name, and id together (KTD6's "SSE frame bytes"); `maxEvents`
(65536) bounds the number of dispatched events. A value outside its range
answers `invalid_bound`.

**Output size.** The output is bounded by the body. The event name, data, and
id are substrings of it, each id value becomes one JS string when it is set and
is shared by every later event that carries it, and the event count is bounded
by `maxEvents`. So a large `id` followed by many small events does not multiply
the output.

**Failures** are the error arm `{ tag, offset }`, where `offset` counts bytes
from the start of `body`, a BOM included, and is a byte offset, not an index in
zts string units. The first failure in this order wins: `invalid_bound`,
`body_too_large`, then the first in scan order of `block_too_large`,
`too_many_events`, `invalid_utf8`, and `unterminated_event`. The offset of a
block failure is the block's first byte. The tag set is closed.

**Labels.** The ok arm's events and the error arm's offset both derive from
`body`, so both carry its labels. The bound values join through the argument
union, which can only add labels. A provider response is `.external` at the
source and stays `.external` through the framer.

**What the framer does not decide.** `data: [DONE]` comes out as an ordinary
`message` event; recognizing completion stays in the adapter (KTD5). A stream
truncated after a complete event passes the framer, so the adapter must still
require the provider's explicit completion. A JSON error body on a 4xx is not
an SSE stream and fails as `unterminated_event`, so the adapter checks status
and content type before framing.

## 4. `zttp:json` control bytes

`readString` refuses any byte from 0x00 to 0x1F with `invalid-syntax` at that
byte's offset, in keys and values alike (Q3). 0x20 and DEL (0x7F) stay accepted,
as RFC 8259 allows. This needs no change to spec 6.4's closed union, and the
binding does not change, so no hash moves for this half. Every consumer of
`readString` gets the same refusal: `parseJson`, `requestJson`, and whatever
else reaches it, which the implementation enumerates and tests (Q4). Raw
invalid UTF-8 inside a JSON string (RFC 8259 section 8.1) is a separate gap and
stays out of scope here; it is recorded as a finding.

## 5. Order of landing and the re-record

The json half and the framer's pure Zig core move no hash, so they land first.
The module's registration (the binding, the builtin entries, the generated
spec, and the pins) is A3's last commit, and it lands after A4 closes. The one
whole-corpus re-record the contract budgets then runs once and covers A3's new
module and A4's deferred `zttp:fetch` signature change. No step is red at any
commit (Q5).

## 6. Files and gates

New: `packages/modules/src/net/sse.zig`, its generated spec. Changed:
`packages/modules/src/root.zig`, `packages/zts/src/builtin_modules.zig`,
`packages/zts/src/modules/data/json_mod.zig`, `docs/virtual-modules/README.md`,
`docs/internals/capabilities.md`, `docs/consumer-contract.md` (the count, and the
stale qualifier), every pin section 2 lists, and one sentence in spec 6.4 that a
raw control byte in a string is `invalid-syntax`.

Gates: `test-modules`, `test-zts`, `test-module-governance`,
`test-capability-audit`, `test-contract-golden`, `test-vocab-envelope-drift`,
`test-reference-tools` (the M4 tools parse JSON), the docs and meta drift
scripts, `test-expert-app` after the re-record, and the full `zig build test`
and `scripts/verify.sh`.

C-A3 cases: a corpus covering every rule of section 3, including LF, CRLF, and
CR line endings, a CR at the end of a line followed by LF (one line end, not
two), comments, multi-line data, `event`, `id` persistence, `id:` empty, an id
containing U+0000, a field with no colon, one leading space removed and a second
kept, `retry` ignored, a data-less dispatch, and a leading BOM; each
`unterminated_event` case (a trailing comment with no newline, a trailing field
block with data, one with only `event:`, one with only `id:`) and the
terminated non-dispatching block that is not refused; every failure tag at its
exact offset, and the failure order; a large id followed by many small events,
asserting that the output shares the id string; the empty corpus fails the test
(floor). A census over the tag enum. The label probe: a secret-labelled body
through `sseEvents`, returned directly and through the error arm's `offset`, is
refused at the response. For `zttp:json`: every byte from 0x00 to 0x1F in a key
and in a value is refused at its offset, 0x20 and 0x7F are accepted, escaped
forms still parse, and `requestJson` refuses a body with a raw newline inside a
string. Non-vacuity: remove the UTF-8 check, the unterminated check, the event
count check, and the control-byte check in turn, and a test must fail each time.

## 7. Out of scope

The incremental form (S3), `retry`, raw invalid UTF-8 inside JSON strings, and
any provider semantics: the framer knows nothing of chat completions.

## 8. Questions for the owner

- **Q1. The three WHATWG differences.** Refuse invalid UTF-8 and an unterminated
  final block, and ignore `retry` (recommended: C-A3 names the first two, each
  silent WHATWG repair would hide a provider fault, and a buffered body has no
  reconnection), or follow WHATWG exactly.
- **Q2. Where the framing bounds live.** KTD6 asks for provider response bytes
  and SSE frame bytes as deployment configuration, and M5a binds its other agent
  limits in the artifact. Today the agent limits bind the request size only, and
  `outbound_max_response_bytes` (`runtime_config.zig:54`, default 1 MiB) has no
  upper limit when it is parsed. Recommended for M5a: `sseEvents` takes its
  bounds from the caller, the reference adapter passes the same constant as the
  fetch's `maxResponseBytes` and as `maxBodyBytes`, and the user guide states
  that the fetch cap must not exceed the framer's ceiling; this is disclosed as
  an interim gap, and A6 decides whether `providerResponseBytes` and
  `sseBlockBytes` join the agent limits. The alternative is to add both limits
  to the catalog now (`ZTCAT1` schema 6), with a build rule that the adapter's
  literals do not exceed them.
- **Q3. Control bytes are `invalid-syntax`** at their offset (recommended: RFC
  8259's grammar makes them syntax errors, and spec 6.4 stays closed), or a new
  error kind.
- **Q4. Every `readString` consumer refuses raw control bytes**, `requestJson`
  included (recommended: the same RFC fix; today they accept a malformed body),
  or `zttp:json` gets a separate strict reader and the others keep today's
  behavior.
- **Q5. One re-record, after A4.** A3's registration lands after A4 closes, and
  the contract's one budgeted run covers both (recommended: one paid run, and no
  commit leaves a step red), or A3 registers now and re-records at its close,
  with a second run after A4.

These defaults are recommended and are not questions unless the owner objects:
the name `zttp:sse` and the export `sseEvents`; the `bounds` object; the closed
tag set and its order; the `{ tag, offset }` error shape; WHATWG id persistence
and the `message` default; the 65536 event maximum and the 8 MiB byte maxima as
encoding bounds.

## 9. Decisions

The owner accepted the recommended answer to Q1 to Q5 on 2026-09-28, and the
defaults listed after them.

## 10. Implementation units

- **U1. Strict JSON strings.** Section 4, with its tests. Moves no hash.
- **U2. The framer core.** Section 3 as a pure Zig core in
  `packages/modules/src/net/sse.zig` with its corpus, census, and probes, tested
  through `test-modules` but not yet registered as a builtin. Moves no hash.
- **U3. Registration.** After A4 closes: the binding and its JS layer, the
  builtin entries, the generated spec, the pins, and the label probe through
  JS; then the one whole-corpus re-record, which also covers A4's deferred
  `zttp:fetch` signature change; then C-A3 evidence.

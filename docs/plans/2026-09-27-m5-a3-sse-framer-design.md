# M5 A3 design note: the SSE framer and strict JSON strings

Status: proposed on 2026-09-27. It needs the owner's answers to section 7
before code starts. Unit A3 of the
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
`zttp-modules` package imports only `zttp-sdk` (`packages/modules/build.zig`),
and the OpenAI parser treats a lone CR as data, dispatches an unterminated final
record, and has no id, BOM handling, or bounds (`openai/sse_parser.zig:75-91`).

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
expert and module goldens, the envelope's binding digests and registry hash, the
frozen signature digest, the language-overview counts, and the module count in
`docs/consumer-contract.md` (`:629-630`; the qualifier at `:643` already says 27
and is stale). The DeepSeek cassettes embed the registry hash, so they go stale.
The policy hash does not move.

**`zttp:json`.** `readString` appends every byte that is not a quote or a
backslash (`packages/zts/src/modules/data/json_mod.zig:181-246`, at `:195`). The
error taxonomy is a closed union in spec 6.4
(`docs/zts-formal-spec-northstar-advanced.md:1577-1583`); `invalid-syntax`
already carries an offset (`json_mod.zig:388-424`). `requestJson` shares this
parser (`packages/zts/src/http.zig:18`, `:114-120`). The ambient `JSON.parse`
already refuses bytes below 0x20 (`builtins/json.zig:349`, `:388`, `:415`,
`:454`). No example or test passes a raw control byte to either reader.

## 3. The module

`zttp:sse`, file `packages/modules/src/net/sse.zig`, one export:

```ts
sseEvents(body: string, maxEventBytes: number, maxBodyBytes: number)
  : Result<{ event: string; data: string; id: string }[], { tag: string; offset: number }>
```

It declares no capability, `effect = .none`, `laws = .pure`,
`replay_pure = true`, `failure_severity = .critical`, and `derives_from_args`.

**Parsing** follows WHATWG HTML section 9.2, "Parsing an event stream" and
"Interpreting an event stream": one leading U+FEFF is skipped; a line ends at
CRLF, LF, or a lone CR; an empty line dispatches; a line starting with `:` is a
comment; a field is the text before the first colon and the value is the text
after it, minus one leading space; a line with no colon is a field with an empty
value; `event` sets the type, `data` appends the value and a LF, `id` sets the
last event id unless the value contains U+0000, and `retry` and unknown fields
are ignored. On dispatch, an empty data buffer dispatches nothing; otherwise one
trailing LF is removed, the type defaults to `message`, and the event carries
the last event id, which persists across events as WHATWG says.

**Two deliberate differences from WHATWG,** both named by C-A3 (Q1):

- Invalid UTF-8 is refused with `invalid_utf8` and the byte offset, where WHATWG
  replaces it with U+FFFD. A replacement would hand the adapter a string that
  the provider did not send.
- Bytes after the last dispatch that are not only line endings or comments are
  refused with `unterminated_event`, where WHATWG discards them silently. A
  silent discard would hide a truncated provider stream.

**Bounds.** `maxBodyBytes` bounds the input and `maxEventBytes` bounds each
event's data. Each must be an integer from 1 to a named maximum of 8 MiB, an
encoding bound, not a recommended value. The body is checked before any parsing
(`body_too_large`); each event is checked as its data grows (`event_too_large`),
so no allocation exceeds the bound. Arguments outside their range answer
`invalid_bound`.

**Failures** are the error arm `{ tag, offset }`, where `offset` is the byte
position in `body`. The tag set is closed: `invalid_bound`, `body_too_large`,
`event_too_large`, `invalid_utf8`, `unterminated_event`.

**Labels.** The result derives from the argument, so it carries the labels of
`body`. A provider response is `.external` at the source, and it stays
`.external` through the framer. The contract's probe applies: a labelled body
must still be labelled after `sseEvents`.

## 4. `zttp:json` control bytes

`readString` refuses any byte below 0x20 with `invalid-syntax` at that byte's
offset (Q3). That needs no change to spec 6.4's closed union, and the binding
does not change, so no hash moves for this half. `requestJson` gets the same
refusal, because it shares the parser (Q4).

## 5. Files and gates

New: `packages/modules/src/net/sse.zig`, its generated spec. Changed:
`packages/modules/src/root.zig`, `packages/zts/src/builtin_modules.zig`,
`packages/zts/src/modules/data/json_mod.zig`,
`docs/virtual-modules/README.md`, `docs/internals/capabilities.md`,
`docs/consumer-contract.md` (the count, and the stale qualifier), and every pin
section 2 lists. `docs/zts-formal-spec-northstar-advanced.md` gets one sentence
in 6.4 that a raw control byte in a string is `invalid-syntax`.

Gates: `test-modules`, `test-zts`, `test-module-governance`,
`test-capability-audit`, `test-contract-golden`, `test-vocab-envelope-drift`,
the docs and meta drift scripts, `test-expert-app` after the re-record (Q5), and
the full `zig build test` and `scripts/verify.sh`.

C-A3 cases: a fixed corpus covering each rule of section 3, including LF, CRLF,
and CR line endings, a CRLF split so that CR ends one chunk of the body and LF
starts the next line, comments, multi-line data, `event`, `id` persistence, an
id containing U+0000, a field with no colon, one leading space removed and a
second kept, a data-less dispatch, and a leading BOM; each failure tag at its
exact offset; the empty corpus fails the test (floor). A census over the tag
enum. The label probe: a `.external` body through `sseEvents` still carries
`.external`, and a secret-labelled body through it is still refused at the
response. For `zttp:json`: every byte from 0x00 to 0x1F inside a string is
refused at its offset, escaped forms still parse, and `requestJson` refuses a
body with a raw newline inside a string. Non-vacuity: remove the UTF-8 check,
the unterminated check, and the control-byte check in turn, and a test must fail
each time.

## 6. Out of scope

The incremental form (S3), `retry` handling, and any provider semantics: the
framer knows nothing of chat completions.

## 7. Questions for the owner

- **Q1. The two WHATWG differences.** Refuse invalid UTF-8 and an unterminated
  final event (recommended: C-A3 names both, and each silent WHATWG repair
  would hide a provider fault), or follow WHATWG exactly.
- **Q2. Bounds as arguments** from the adapter, each 1 to 8 MiB (recommended:
  the adapter knows its provider, and the build cannot see a response size), or
  fixed constants in the module.
- **Q3. Control bytes are `invalid-syntax`** at their offset (recommended: RFC
  8259's grammar makes them syntax errors, and spec 6.4 stays closed), or a new
  error kind.
- **Q4. `requestJson` refuses raw control bytes too** (recommended: the same RFC
  fix; today it accepts a malformed body), or `zttp:json` gets a separate strict
  reader and `requestJson` keeps today's behavior.
- **Q5. Re-record timing.** The new module makes the DeepSeek cassettes stale.
  Re-record at the close of A3 and again after A4 (recommended: no unit closes
  with a failing step, as for A1), or carry the failure until one re-record
  after A4. Each run is a whole-corpus DeepSeek run under the approval already
  given for A3 and A4.

These defaults are recommended and are not questions unless the owner objects:
the name `zttp:sse` and the export `sseEvents`; the closed tag set; the
`{ tag, offset }` error shape; WHATWG id persistence and the `message` default.

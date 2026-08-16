# Agent Protocol, Schema Version 2

`zts agent --stdin-json` is the version-2 agent protocol transport. It reads one
request object from standard input and writes one response object to standard
output. Logs go to standard error. The process exits 0 whenever it wrote a
response, including a response carrying a protocol error: the envelope carries
the verdict, not the exit status.

Every other analyzer command is version 1. Their bare arrays and version-1
objects are legacy or human-facing interfaces, and an agent must not read them as
advanced-profile responses. See [zts-expert-contract.md](zts-expert-contract.md)
for those shapes.

Normative source: `docs/zts-formal-spec-northstar-advanced.md` section 4.8.
Payload design: `docs/plans/2026-07-30-016-d3-canonical-form-wire-design.md`
sections 3 and 6.

## Envelope

Request:

```json
{
  "schema_version": 2,
  "operation": "check",
  "project_root": "/absolute/project/root",
  "input": { "file": "src/handler.ts" },
  "expected": {
    "profile_id": "zts-model-1",
    "policy_hash": "...",
    "module_graph_hash": "..."
  }
}
```

Response:

```json
{
  "schema_version": 2,
  "operation": "check",
  "profile_id": "zts-model-1",
  "compiler_version": "0.18.0",
  "policy_version": "2026.04.2",
  "policy_hash": "...",
  "module_graph_hash": "...",
  "success": true,
  "payload": {},
  "diagnostics": [],
  "error": null
}
```

`error` is present only on a protocol-level failure. The identity block is
present on every response, including error responses, so a client that hit a
staleness or boundary failure has the current values to recover with.

`success` is exactly "produced no error diagnostic". Warnings and advisories
never fail a check, a build, or the repair loop.

`module_graph_hash` depends on the operation. A file-bound operation binds the
digest of the environment it actually read; every other operation binds the
context-free digest, which is the built-in registry with an empty module set.

## Operations

Send `meta` first. New coding-agent sessions use
`{"view":"bootstrap"}` to receive a bounded identity and operation index.
Use `{"view":"full"}` or `{}` to receive the complete registries, grammar,
examples, and deferred-section inventory. The bootstrap response includes the
exact full-view request and section list, so it is a projection rather than a
second metadata contract.

| Operation | Status | `input` fields | Note |
|---|---|---|---|
| `meta` | implemented | `view` | `bootstrap` or `full`; default `full` |
| `features` | implemented | - | |
| `restrictions` | implemented | - | |
| `describe_rule` | implemented | `rule` | |
| `modules` | implemented | `file` | |
| `check` | implemented | `file` | |
| `canonicalize` | implemented | `file`, `simulate` | |
| `normalize` | implemented | `file`, `write` | `write: true` is refused |
| `simulate_edit` | implemented | `file`, `repairs` | |
| `verify` | implemented | `file`, `properties`, `content` | `content` verifies supplied bytes without a write |

Every operation in the closed set is implemented as of 2026-08-03. The
`operation_not_implemented` code stays in the protocol because the set is closed
and a future member may land deferred: such an operation answers
`operation_not_implemented`, never `unknown_operation`, since it is a named
member of the spec's set and saying otherwise would be false. Read the status
column from `agent_protocol.zig` rather than from here - this table was stale for
three operations until it was reconciled.

The protocol is read-only. Source writes belong to PI's aggregate change-set
transaction, which proves the complete overlay, checks its full read set, and
emits one durable receipt. The removed `apply_repair` operation is rejected as
an unknown operation so it cannot bypass that authority.

## Version negotiation

A request naming any `schema_version` other than 2 receives a frozen response:

```json
{
  "schema_version_unsupported": true,
  "supported_schema_versions": [2],
  "compiler_version": "0.18.0"
}
```

Three keys, no envelope, no diagnostics. This shape is identical across all
present and future schema versions, so version discovery is one deterministic
round trip. Negotiation runs before the operation is even read, so a client of
any version reaches it without needing to be understood.

## The `expected` guard

One rule for every operation: a supplied field that does not match the
recomputed identity fails the request with `identity_mismatch`, naming the
mismatched field and both values, so a client re-binds without a second round
trip. Omitting `expected` skips the guard; an empty object is the same as
omitting it.

The three bindable fields are `profile_id`, `policy_hash`, and
`module_graph_hash`. Any other key is `malformed_request`: silently skipping a
misspelled guard field would report success for a request the client believed was
guarded.

The guard runs after identity computation and before the operation does any
work.

## Protocol errors

Protocol-level failures are not diagnostics. They name a request field, never a
source span. The code set is closed and published in `meta.payload.error_codes`.

| Code | Meaning |
|---|---|
| `unknown_operation` | not a member of the version-2 operation set |
| `operation_not_implemented` | a member of the set this compiler does not serve yet |
| `malformed_request` | missing or wrongly typed request field |
| `unsupported_schema_version` | reserved; negotiation answers first |
| `project_root_unresolvable` | `project_root` does not resolve to an existing directory |
| `path_outside_project_root` | a request path escapes the root |
| `file_unreadable` | the entry file could not be read |
| `unsupported_source_extension` | `input.file` does not use `.ts` or `.tsx` |
| `identity_mismatch` | an `expected` field is stale |
| `internal_error` | a limit or fault inside the compiler |

## Diagnostics

Each entry in `diagnostics` carries `code`, `rule_id`, `severity`, `message`,
`file`, `source_digest`, `line`, `column`, `byte_offset`, `span`, `suggestion`,
and `repair_available`.

`file` is project-relative. `source_digest` is the SHA-256 of the raw bytes the
offsets index into. `rule_id` is null for the ZTS0xx parser band and the ZTS2xx
type-checker band, which are real codes outside the policy-hashed registry.

`span` is the half-open byte range of the token the diagnostic points at, in
those same bytes. `start == end` is a point rather than a range, which is what a
producer that has an offset but no extent reports.

`repair_available` is true exactly when that diagnostic instance carries a
repair intent whose validator row is implemented. Seven of the registry's 17
rows qualify: six declared-law rewrites under M4 and the pure chained-ternary
slice under M3. The checker may leave an instance intent null when its
precondition is not proven. The validator re-derives the rewrite from the
original and requires the candidate to match the exact diagnostic-bound splice.
A `canonicalize` candidate or `normalize` rewrite grades
`mechanical_repair` under the same condition and `proposed_refactor` otherwise,
read from that registry rather than from a constant.

Five rows remain `.planned`. `replace_effectful_ternary_with_match` waits for a
kernel that models branch effects and evaluation order. `lead_with_spread`
cannot move even a collision-free nonempty literal spread while object insertion
order is observable. The two M5 rows remain advisory-only. `insert_semicolon`
remains planned under M2. That repair shipped and was withdrawn after review found it
unsound - it took line numbers from a parse of the stripped source, built its
replacement from a trimmed line, and was certified by a parse identity that read
both sides under the ASI grammar this compiler no longer ships. Nothing
advertises or applies it while the row stays `.planned`.

## Deferred sections

`meta.payload.deferred_sections` names every payload section spec 4.8 requires
that no registry can generate today, with the phase that builds it or the
measurement that says why it cannot exist. A client reads one machine-readable
list instead of discovering absence key by key. Nothing is stubbed with prose:
a section that cannot be generated is absent.

Two entries are findings rather than schedules. `rule_severity` says severity is
chosen at each emission site, not stored per rule: `handler_verifier` emits
ZTS305 as a warning and ZTS500 as an error from one category, so no table can
answer what severity a rule emits, and `describe_rule` publishes none rather
than a derived guess. `repair_budget` says the repair-iteration and tool-call
budget is a client's loop policy: nothing in this compiler runs that loop, so a
number published here would be enforced by nobody. Every other entry names the
phase that builds it.

`grammar` publishes spec section 8 production for production, in document
order, and `scripts/check-grammar-drift.sh` compares the registry behind it to
the document itself with a floor under both extractions. Section 8 is a
structural over-approximation by its own preamble, so every row also carries
where its enforcement happens: `parse_time` when the parser admits exactly the
production, `check_time` when the parser admits more and a later pass refuses
the excess. A `check_time` row names the rule that refuses - a registry code
where one exists, and otherwise a note naming the band that answers, which today
is `StructuralDecl` and ZTS212. Each enforcement point was measured by running
`zts check` on a program that exercises the wider form, not reasoned about.

`decisions` publishes the kinds a client keys on, with a version, the response
fields that carry each one, and the next action it admits - `fix_the_request`,
`reread_the_file`, `narrow_the_repair_set`, `choose_a_graded_intent`, or
`no_mechanical_repair`. Those were what each refusal's message had been saying
in prose. Every refusal is now written from the registry's enum, so a kind on
the wire and a kind published here cannot differ, and
`scripts/check-decision-registry.sh` enforces the other direction: a published
kind that nothing emits fails, because a client writing a branch for it would
wait forever. A refusal on the wire carries `reason` and `next_action` together.

What is not published, measured rather than assumed: spec 13.6's explanation
graph, which no build report emits, and any semantic-decision kind, since
nothing here asks a client to choose a semantic. Both join the registry when
they land, and the version moves with them.

`examples` publishes one canonical minimal example per admitted surface form,
keyed to the same feature table the `features` operation publishes and compared
to it in both directions, so an admitted form with no example fails and an
example naming no admitted form fails. Each example is a whole handler rather
than a snippet, is run through the same check `zts check` runs and must report
nothing at any severity, and carries evidence that it exercises the form it
names - a node tag or a type-map kind wherever either records the form, and a
source match only for the pipe, `comptime()`, `readonly`, and template literal
types, which leave no trace after parsing or stripping.

Writing those examples found four defects, all now fixed: ZTS604 fired on every
`let` in an exported function, an annotated `let` took its initializer's literal
type, an object spread contributed its operand's name instead of its fields to
both the inferred type and the dead-variable rule, and a template literal type
was not assignable to `string`.

`ambient_names` and `type_serialization` were stale deferrals whose mechanisms
had landed in earlier phases, and both now ship. `ambient_names` publishes the
type and value names a handler writes without importing them; every type row is
resolved through the checker's own entry by a gate, so a published name is a
name the compiler admits. Two names spec section 6 lists are absent, measured
rather than assumed: `Result` is declared or imported rather than ambient, and
`HtmlNode` exists nowhere in the compiler - JSX is typed through `h` and
`renderToString`. `type_serialization` publishes the canonical type
serialization's version, digest algorithm, and depth bound, which is what a
client needs before it caches a type digest and compares it to a later one.

`extension_manifests` is the one worth knowing about early: no `zttp-ext:`
manifest is authenticated yet, so every extension specifier is reported under
`rejected` rather than silently resolved, and the `extensions` list is empty.

## Determinism

Response JSON on stdout, one object, trailing newline. Logs on stderr. Array
order, diagnostic order, and rewrite order are deterministic for identical
inputs. `scripts/check-agent-determinism.sh` runs every operation twice against
the built binary and compares bytes; it is wired into `scripts/verify.sh`.

## Example

```sh
echo '{"schema_version":2,"operation":"meta","project_root":".","input":{}}' \
  | zts agent --stdin-json

echo '{"schema_version":2,"operation":"check","project_root":".","input":{"file":"src/handler.ts"}}' \
  | zts agent --stdin-json
```

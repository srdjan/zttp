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
    "profile_id": "zts-advanced-1",
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
  "profile_id": "zts-advanced-1",
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

Send `meta` first. Its payload publishes this table, the identity hashes, and the
sections this compiler does not yet generate.

| Operation | Status | `input` fields | Note |
|---|---|---|---|
| `meta` | implemented | - | |
| `features` | implemented | - | |
| `restrictions` | implemented | - | |
| `describe_rule` | implemented | `rule` | |
| `modules` | implemented | `file` | |
| `check` | implemented | `file` | |
| `canonicalize` | implemented | `file`, `simulate` | |
| `normalize` | implemented | `file`, `write` | `write: true` is refused |
| `simulate_edit` | implemented | `file`, `repairs` | |
| `apply_repair` | implemented | `file`, `repairs` | |
| `verify` | implemented | `file`, `properties`, `content` | `content` verifies supplied bytes without a write |

Every operation in the closed set is implemented as of 2026-08-03. The
`operation_not_implemented` code stays in the protocol because the set is closed
and a future member may land deferred: such an operation answers
`operation_not_implemented`, never `unknown_operation`, since it is a named
member of the spec's set and saying otherwise would be false. Read the status
column from `agent_protocol.zig` rather than from here - this table was stale for
three operations until it was reconciled.

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
| `identity_mismatch` | an `expected` field is stale |
| `internal_error` | a limit or fault inside the compiler |

## Diagnostics

Each entry in `diagnostics` carries `code`, `rule_id`, `severity`, `message`,
`file`, `source_digest`, `line`, `column`, `byte_offset`, `suggestion`, and
`repair_available`.

`file` is project-relative. `source_digest` is the SHA-256 of the raw bytes the
offsets index into. `rule_id` is null for the ZTS0xx parser band and the ZTS2xx
type-checker band, which are real codes outside the policy-hashed registry.

Two absences are deliberate in this version, and both appear in
`meta.payload.deferred_sections`:

- **no `span`.** No producer computes a half-open byte range, so a diagnostic
  publishes the exact start as `byte_offset` rather than inventing an end.
- **`repair_available` is uniformly false.** Spec 4.8 permits advertising an
  exact repair only where a registered equivalence validator exists, and that
  registry does not exist yet.

For the same reason, every `canonicalize` candidate and every `normalize`
rewrite grades `proposed_refactor`. Nothing on this wire is a mechanical repair
yet.

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

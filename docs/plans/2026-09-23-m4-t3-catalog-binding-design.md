# M4 T3 design note: canonical catalog encoding and artifact binding

Status: implemented on 2026-09-23. Accepted by the owner on 2026-09-23, with the
recommended answer to each question in section 7 and the file extension in section 6. Check C3 of the
[M4 release contract](2026-09-22-m4-release-contract.md) is written against
the approach this note names.

All citations are to local `main` at `9737a648`.

## 1. What T3 must deliver

The release contract asks for four things (release contract, T3). The
catalog gets a canonical encoding that meets P4 for the sections M4 uses
(`docs/consumer-contract.md:695-702`). It binds as a new executable-graph
member, `tool_catalog = 19`, with a producer that emits it (decision 5). The
envelope is regenerated. The runtime lowers the catalog from the accepted
artifact, not from producer output.

C3 asks that an accepted artifact serve its catalog, that AE11, B8.8, and B8.9
fail closed, that mutating one catalog byte in a copy of an accepted artifact
makes acceptance refuse, and that deleting the member fails the gate.

## 2. What exists today

**The catalog is already covered, but not by name.** T2 writes
`HandlerContract.tools` into the contract JSON
(`contract_json_writer.zig:265`), and the contract bytes are graph member
`contract_bytes = 7` (`runtime/src/artifact_graph.zig:246-248`). A tampered
catalog byte therefore already moves the contract digest, and acceptance
refuses with `graph_member_digest_mismatch`. What is missing is a commitment
that names the catalog, a decoder the kernel runs on it, and a runtime that
uses it: `fromHandlerContract` never reads `hc.tools`, and `hc` is freed at
`contract_runtime.zig:477`.

**The member model.** A graph member is `{kind, ordinal, digest}` and carries
no bytes (`executable_graph.zig:121-135`). The root commits to every member in
(kind, ordinal) order (`:157-212`). `required()` is an exhaustive switch
(`:89-118`), so a new kind must name its arm. The runtime rebuilds the graph
from the sections it loaded, not from the producer's list
(`proof_activation.zig:5-6`), and `bindExecutableGraph`
(`checker.zig:1344-1466`) refuses a missing, extra, or mismatched member
before any semantic stage.

**The precedent, `invariant_spec = 17`.** Authored JSON is encoded into
canonical `ZTINV1` bytes by `packages/tools/src/invariant_config.zig`, which
ends by running the kernel's own decoder over its output
(`invariant_config.zig:163-176`). The bytes ship as their own artifact section
(`self_extract.zig:417-418`). The certificate identity carries a domain-separated
digest (`invariant.zig:580-593`, identity bytes 160..192). The kernel decodes
the bytes, recomputes the digest, and requires exactly one member
(`checker.zig:389-499`).

**The kernel constraint.** `scripts/check-proof-checker.sh` forbids the token
`allocator` anywhere in `packages/proof-checker`, forbids package imports, and
limits `std` use. A kernel decoder must be zero-copy over a byte slice, as
`invariant.zig` is. `tool_schema.zig` allocates, so the kernel cannot use it.

**The request path.** Route pre-filtering already refuses an unknown route
with 404 before the handler (`server.zig:674-682`). At that point the body is
fully read and bounded by `max_body_size` (`:926`, 413 at `:562-564`), and no
JS value exists yet: the Request object is built later
(`handler_instance.zig:1494`). This is where a tool input validator belongs.

**Dev mode.** `zttp dev` runs from producer output and has no accepted
artifact: `proof_checked` is null (`server.zig:1551`), and the proof cache,
unbounded reuse, and invariants are off or refused there (`:1762-1783`).

**The tension with P4.** The consumer contract defines the declaration as a
consumer-authored document with five sections: interface, properties,
capability ceiling, invariants, and classifications
(`docs/consumer-contract.md:72-74`, `:156`). It has no tool-catalog section.
The T2 catalog is derived by the compiler from handler source. The release
contract nevertheless calls the catalog "a section of the declaration"
(release contract, P4 row).

## 3. Canonical encoding: `ZTCAT1`

A binary layout, because the kernel must decode it without allocation. All
integers are little-endian. Every string is UTF-8 with a u32 length prefix.
There are no defaults and no optional fields: every field is written, so there
is nothing to omit.

```text
magic            8 bytes  "ZTCAT1\0\0"
schema           u16      1
entry_count      u16      1..64
entry, entry_count times, sorted by name bytes, names unique:
  name             string  1..64 bytes
  method           string  1..16 bytes, uppercase ASCII
  path             string  1..512 bytes, starts with "/"
  description      string  1..4096 bytes
  input_name       string  1..64 bytes
  input_schema     string  canonical schema JSON, 1..65536 bytes
  output_name      string  1..64 bytes
  output_schema    string  canonical schema JSON, 1..65536 bytes
  max_input_bytes  u32     1..1048576
  export_count     u16     0..256
  export, export_count times, sorted by (module, name), unique:
    module           string  1..64 bytes
    name             string  1..64 bytes
trailing bytes: refused
```

Routes are unique across entries: two entries with the same (method, path)
are refused. The route key splits into method and path at encode time, so the
runtime matches routes without parsing a key string.

**Canonical schema JSON.** `tool_schema.zig` gains a `canonicalize` function
that writes a compiled schema back out with keys in a fixed order, no
whitespace, and integers without a fraction or exponent. The encoder
canonicalizes both schemas, then compiles the canonical text again and
requires the same verdicts on the fixed corpus of the T2 round-trip test.
Canonicalizing twice gives the same bytes. Authored whitespace and key order
therefore cannot move the digest, which is what P4 rules out
(`docs/consumer-contract.md:701-702`).

**Digest.** The digest is domain-separated SHA-256 over the whole encoding,
with the domain `zttp-tool-catalog-v1`, following `invariant.zig:580-593`.

**Specification.** A reader must be able to compute the same digest without
the producer's code (P4). The layout above, the key order of canonical schema
JSON, and the domain string go into `docs/consumer-contract.md` as the
catalog's canonical form.

## 4. Binding and acceptance

**Producer.** `ZTCAT1` bytes are built from `HandlerContract.tools` in the
build pipeline and shipped as a new self-extracting section, `tool_catalog`,
next to the invariant section. `artifact_graph.build` adds
`collector.add(.tool_catalog, 0, digest)` when the catalog is non-empty. A
handler without a catalog has no section and no member, as a handler without
an invariant has neither today.

**Kernel.** `packages/proof-checker/src/tool_catalog.zig` decodes `ZTCAT1`
zero-copy and refuses everything section 3 refuses. A new checker stage
receives the section bytes through `Inputs`, decodes them, recomputes the
digest, and requires exactly one `.tool_catalog` member with ordinal 0 and
that digest. New reason codes are `tool_catalog_undecodable`,
`tool_catalog_digest_mismatch`, and `tool_catalog_member_missing`, the last
covering both a section with no member and a member with no section. The
kernel does not re-check the schema subset, because that needs an
allocating parser. The runtime compiles every schema from the accepted bytes
and refuses to start if one does not compile (section 5), so an out-of-subset
schema still cannot serve.

**No certificate schema change (recommended).** `invariant_spec` also
carries its digest in the certificate identity. A graph member already puts
its digest under the executable root, and the runtime rebuilds the member
from the bytes it loaded, so a changed byte fails at artifact binding
without an identity field. Adding one would move the certificate schema from
4 to 5, a pinned identity in the envelope, for no new refusal.

**Cross-check against the contract.** The catalog also stays in the contract
JSON, which tooling and diagnostics read. The runtime compares the contract's
tool list with the accepted catalog by name, route, and byte bound, and
refuses to start on a difference. This is AE11's "serving is refused even if
the producer's declared catalog is unchanged": the accepted catalog wins, and
disagreement is a refusal, not a merge.

**Members of the negative cases.** AE11 (a changed schema, grant, catalog, or
dispatch target after acceptance) is a changed catalog byte or a changed
contract byte; both fail at artifact binding. B8.9 (a tampered artifact) is
the same refusal for any member. B8.8 (a changed policy) is a changed
`runtime_policy_bytes` member, which already fails; T3 adds a test that names
it. AE11's cross-tool grant half is T5.

## 5. Runtime lowering

`ProofCheckedContract` gains the accepted catalog. `promote` fills it from the
section bytes that passed acceptance: it decodes `ZTCAT1`, compiles every
schema with `tool_schema.compile`, and splits nothing, because the encoding
already holds method and path apart. A compile failure refuses to start.
Reaching `tool_schema` from runtime needs one curated export in
`packages/zts/src/root.zig` and one row in `scripts/module-boundary.allow`.

What the runtime does with the catalog in T3 is question Q3. The
recommendation is input and output validation on tool routes. The request
path matches a tool route after route pre-filtering, validates the body with
`tool_schema.validate` against the accepted schema and byte bound, and
answers 413 for `too_large` and 400 with the refusal reason for every other
refusal, before a JS value exists. After the handler returns, it validates a
JSON response body against the output schema and answers 500 on a mismatch,
which is B8.4 at runtime. Identity, scope, and grants stay in T5.

## 6. Files

| File | Change |
|---|---|
| `packages/zts/src/tool_schema.zig` | `canonicalize` |
| `packages/tools/src/tool_catalog_encoding.zig` (new) | `ZTCAT1` encoder from `ToolEntry`, ending with the kernel decoder |
| `packages/proof-checker/src/executable_graph.zig` | `tool_catalog = 19`, `fromWire`, `required()` arm |
| `packages/proof-checker/src/tool_catalog.zig` (new), `checker.zig`, `verdict.zig`, `test_root.zig` | zero-copy decoder, stage, reason codes |
| `packages/runtime/src/self_extract.zig`, `artifact_graph.zig`, `proof_activation.zig`, `build_command.zig`, `runtime_config.zig` | section, member, graph inputs |
| `packages/runtime/src/contract_runtime.zig`, `server.zig` | lowering, cross-check, validation on the request path |
| `packages/zts/src/root.zig`, `scripts/module-boundary.allow` | curated `tool_schema` export |
| `packages/tools/src/vocab_envelope.zig`, `docs/consumer-contract-envelope.json`, `docs/consumer-contract.md` | regenerated counts; the catalog's canonical form |

This extends the file list in the release contract with `self_extract.zig`,
`artifact_graph.zig`, `build_command.zig`, `runtime_config.zig`, `server.zig`,
`verdict.zig`, and `tool_schema.zig`, and it needs owner acceptance as T1b's
and T2's extensions did. The release contract's "declaration loader under
`packages/tools/src/`" is question Q1.

## 7. Questions for the owner

- **Q1. Catalog source and the declaration loader.** The catalog stays
  compiler-derived and is canonicalized as `ZTCAT1` (recommended). The
  authored declaration file and its loader move to T4 and T5, where authored
  input exists: T4's classifications and T5's capability ceiling. The option
  is to add an authored declaration file with a catalog section in T3, which
  the build compares against the derived catalog.
- **Q2. Certificate identity.** Bind by graph member only, with no identity
  field and no certificate schema bump (recommended), or also add an identity
  digest as `invariant_spec` has, which moves the certificate schema from 4 to 5.
- **Q3. Runtime use in T3.** Lower, cross-check, and validate tool inputs and
  outputs on the request path (recommended), or lower and cross-check only
  and leave all request-path use to T5.
- **Q4. Dev mode.** `zttp dev` validates tool routes from the producer's
  catalog with the same code, and makes no acceptance claim (recommended), so
  a developer sees the 400 and 413 answers before deploy. The option is to
  validate only an accepted catalog, as the proof cache and invariants do,
  which leaves dev without input validation on tool routes.

These are recommended and are not questions unless the owner objects: the
binary `ZTCAT1` layout and its bounds (section 3), canonical schema JSON
from `tool_schema.canonicalize`, a section and member only for a non-empty
catalog, three new reason codes, and the file extension in section 6.

## 8. Decisions

The owner answered on 2026-09-23. Q1: the catalog stays compiler-derived and is
canonicalized as `ZTCAT1`; the authored declaration file and its loader move
to T4 and T5. Q2: the catalog binds as graph member `tool_catalog = 19` only,
with no certificate identity field and no certificate schema change. Q3: the
runtime lowers the accepted catalog, cross-checks it against the contract, and
validates tool-route inputs and JSON outputs on the request path. Q4: `zttp
dev` runs the same validation on the producer's catalog and makes no
acceptance claim. The recommended defaults at the end of section 7 stand.

## 9. Progress

| Unit | Commit | Content |
|---|---|---|
| U1 | `0395453f` | `tool_schema.canonicalize` |
| U2 | `5a7f3093` | kernel: member 19, zero-copy `ZTCAT1` decoder, checker stage, reason codes, envelope counts |
| U3 | `723b1081` | tools: `ZTCAT1` encoder from `ToolEntry` |
| U4 | `854515f4` | runtime: section 9, graph member, activation inputs, lowering, cross-check |
| U5 | `1105318e` | request path: input and output validation, dev mode |
| U6 | `2c6053f6` | the `ZTCAT1` canonical form in the consumer contract (section 4.6) |

## 10. Implementation notes and C3 evidence

Three points differ from sections 3 to 5, each found while building. The
compiled schema tree kept no `title` or `description`, so canonicalization
records them as annotations beside the tree and writes them back: they are
what a model is told about a field. Dev mode lowers the producer's catalog by
encoding it with the build's own encoder and lowering it with the accepted
path's code, so both modes run one validator. A 2xx tool body larger than 1 MiB
is refused rather than passed, because an output the check never read is not
one it admitted.

C3, measured on `main`. Positive: a real compile of the tool fixture is
accepted with one `tool_catalog` member whose digest is the shipped section's,
and `promote` lowers `ping`, `POST`, `/tools/ping`, 256. A deployed binary of
the same fixture (`zttp deploy`, run on a local port) logged "Proof accepted"
and answered `{}` with 200, `{"x":1}` with 400 `unknown_field`, a 302-byte body
with 413 `too_large`, an absent body with 400 `invalid_json`, and an unknown
route with 404. Negative: one changed catalog byte in a copy of an accepted
artifact is refused at artifact binding (`graph_member_digest_mismatch`), a
deleted catalog section is refused (`graph_member_missing`), a changed runtime
policy member is refused (B8.8), and a contract tool list that disagrees with
the accepted catalog refuses to start (AE11). Census: all 18 `DecodeError`
members and all three `tool_catalog_*` reason codes are observed. Mutation
probes, each on a genuine compile and restored byte for byte: a duplicate name
let through by the decoder, the kernel's digest comparison, the catalog digest
in the runtime's graph inputs, the shipped section, the promote cross-check,
the canonical schema in the encoder, the property sort in `canonicalize`, and
the request-path input and output checks; each failed a named test.

One measurement hazard was found and is recorded in the session memory: while
an agent worktree existed, the shared zig cache served stale compiles of a
path-dependency package to `main`, so a probe there passed without testing
anything. Every probe above was rerun after the worktree was removed, with the
compile line showing `success`.

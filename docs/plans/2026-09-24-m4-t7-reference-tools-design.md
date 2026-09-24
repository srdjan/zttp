# M4 T7 design note: reference tools and documentation

Status: accepted by the owner on 2026-09-24, with the recommended answer to
each question in section 5. Implementation is in progress.
Check C7 of the [M4 release contract](2026-09-22-m4-release-contract.md) is
written against the approach this note names.

All citations are to local `main` at `05648515`.

## 1. What T7 must deliver

The release contract asks for a new directory under `examples/`, its entry in
the example suite, and a section of `docs/user-guide.md`. The directory holds
two reference tools: one pure bounded tool, and one scoped, credentialed
upstream lookup (`B:151`). Check C7 asks for proposal B's path from author to
an accepted, scoped, bounded call, without replay, and for every applicable
B8 case at its documented boundary. The applicable cases are B8.1 incorrect
subject, B8.2 forged nominal value, B8.3 oversized upstream response, B8.4
malformed result, B8.7 widened transitive capability, B8.8 changed policy, and
B8.9 tampered artifact. B8.5 and B8.6 are deferred. C7's non-vacuity rule: a
probe that breaks the new example must fail the step, because the suite floor
in `scripts/test-examples.sh:374` counts suites and not this one.

## 2. What exists today

Each part of the path is tested on its own. A real compile of a tool handler
reaches acceptance (`packages/runtime/src/build_command.zig:2714`); a changed
catalog byte and a deleted catalog are refused at binding (`:2753`, `:2775`);
the server request path verifies, scopes, validates, and injects
(`packages/runtime/src/server.zig`, the tool tests). T3, T5, and U1 of T6
checked a deployed binary by hand. No script or build step runs a packaged
tool artifact end to end, and no example uses `zttp:tool`.

The example suite cannot carry C7 as it is. It runs `zttp serve <handler>
--test <file.jsonl>` (`scripts/test-examples.sh:36-60`), and the JSONL runner
answers every module call from the recorded `io` rows
(`packages/runtime/src/test_runner.zig:1-15`). That is replay, which C7
excludes, and it does not pass through the tool gate (token, scope, catalog
validation, credential injection).

## 3. The examples

`examples/tools/` is one project: `zttp.json`, one handler with a
`toolCatalog` of two tools, and a README.

- **`convert`**, the pure bounded tool. It converts a temperature between
  units. The input is a closed object with a bounded number and a unit enum;
  the output is a closed object. It reaches no module that does I/O.
- **`order_status`**, the scoped, credentialed lookup. The catalog `scope`
  binds the input's `tenant_id` to the verified tenant. The tool calls
  `fetch("<endpoint>/v1/orders", { credential: "orders", query: ... })` and
  returns a bounded summary. zttp.json declares `auth` and the `orders`
  credential reference.

## 4. The harness

A new Zig build step, `test-reference-tools`, runs one Zig program against the
built `zttp` binary. It builds the example with `zttp build`, starts the
artifact from an empty directory with the key and credential variables set,
serves a loopback upstream, signs HS256 tokens itself, and sends real HTTP
requests. The positive case is one accepted `convert` call and one
`order_status` call that the upstream receives with the injected header. The
negative cases run at the boundary each one names:

| Case | Boundary | Expected |
|---|---|---|
| B8.1 incorrect subject | request | a token for another tenant gets 403 before the handler runs |
| B8.2 forged nominal value | build | a copy of the handler that forges a nominal is refused |
| B8.3 oversized upstream response | request | the upstream answers over the bound; the tool gets `ResponseTooLarge` and answers its declared error |
| B8.4 malformed result | request | the upstream answers a shape the output schema refuses; 500 `tool output refused` |
| B8.7 widened capability | build | a copy that reaches one more export than its ceiling is refused |
| B8.8 changed policy | start | a copy of the artifact with one declaration byte changed refuses to start |
| B8.9 tampered artifact | start | a copy with one catalog byte changed refuses to start |

The step joins `zig build test` and `scripts/verify.sh`. It asserts a floor:
it fails when it ran no case. Probes: break the example's scope field, and the
B8.1 case must fail; remove the credential from zttp.json, and the build case
must fail.

## 5. Questions for the owner

- **Q1. Harness.** A Zig build step that drives the packaged artifact over real
  sockets (recommended: the repository's rule is that new tooling is Zig, and
  it needs no `openssl` or second server process), or a shell addition to
  `test-examples.sh` that uses `curl`, `openssl` for the tokens, and a second
  `zttp serve` as the upstream.
- **Q2. Upstream endpoint.** The example names a fixed loopback endpoint
  (`http://127.0.0.1:39460`), which the harness serves, so the example runs as
  written and the README says how to point it at an `https` upstream
  (recommended), or the example names an `https` endpoint and the harness
  builds a rewritten copy.
- **Q3. B8 coverage.** Run all seven applicable cases against the example at
  their own boundary, as in the table (recommended), or run the four request
  and start cases live and cite the existing build tests for B8.2 and B8.7.
- **Q4. Documentation.** A new user-guide section, "Tool routes", that walks
  through the example: catalog, token and scope, declaration and ceiling,
  credentials (recommended); the credential detail stays in
  `docs/contracts-and-sandboxing.md` and the guide links to it. Or one section
  in `docs/contracts-and-sandboxing.md` only.

## 6. Decisions

The owner answered on 2026-09-24 and accepted the recommended answer to each
question. Q1: a Zig build step, `test-reference-tools`, drives the packaged
artifact over real sockets. Q2: the example names the fixed loopback endpoint
`http://127.0.0.1:39460`, and the README says how to use an `https` upstream.
Q3: all seven applicable B8 cases run against the example at their own
boundary. Q4: a new "Tool routes" section in `docs/user-guide.md`, which links
to the credential detail in `docs/contracts-and-sandboxing.md`.

## 7. Found while building the example: a tool cannot read its input

The example built and its artifact served: a request with no token got 401 and
a token for another tenant got 403. But every valid call answered 400 from the
handler. The catalog requires a closed object (`additionalProperties: false`),
and `zttp:validate` refuses that keyword (`validate.zig:283-299`), so
`schemaCompile` returns `false` for every catalog schema and `validateJson`
with that name fails. Measured on `zttp serve`: the same schema without the
keyword compiled and validated. The fixtures in
`packages/tools/tests/fixtures/contract/` have the same shape, and no test ran
them. `zttp check` and `zttp build` proved the handler anyway.

The owner decided on 2026-09-24:

- **Q5. Tool input.** A new export in `zttp:tool`, `toolInput(req, name)`,
  returns a `Result` whose value type comes from the catalog schema `name`.
  The value is built from the bytes the gate already validated against the
  active tool's input schema, with the gate's own rules, so no second validator
  can disagree with the first. If the new export moves a hash the DeepSeek
  cassettes embed, the corpus re-record waits for the owner's approval.
- **Q6. Build check.** The build refuses a `schemaCompile` literal that
  `zttp:validate` cannot compile, and names the keyword.

The owner refined Q6 on 2026-09-24. A catalog schema needs
`additionalProperties: false`, which `zttp:validate` cannot compile, so a
refusal of every such `schemaCompile` literal would refuse every tool handler.
The build refuses the call that would fail instead: a `validateJson`,
`validateObject`, `coerceJson`, or `decodeJson` call that names a schema
`zttp:validate` cannot compile, and a `schemaCompile` literal it cannot compile
that no catalog entry names. A catalog-only schema stays legal.

## 8. Units

- **U1, `toolInput`.** The export is `toolInput(name, req)`, with the name
  first as in `validateJson(name, json)`, because every schema-name mechanism
  (the type checker's typed `Result`, the contract builder's request schema,
  the path generator's bounds) reads argument 0. The binding declares
  `returns = .result`, `failure_severity = .critical`,
  `return_labels.validated`, and a `request_schema` extraction, so labels,
  result tracking, fault coverage, and `input_validated` follow from the
  fields. The runtime answers `ok` only when a tool gate validated this
  request against the input schema `name`: the tool grant carries the name,
  and a new SDK bridge call reads it. The build refuses a `toolInput` whose
  name is not the calling route's catalog input, as a new
  `ToolCatalogRefusal` member under ZTS513.
- **U2, the `schemaCompile` check** of the refined Q6. The builder cannot
  import `zttp:validate`, so it keeps its own keyword list, and a test pins
  the list to `validate.zig`'s.
- **U3, the example, the harness, and the documentation**, as sections 3
  and 4 describe, with `toolInput` in place of `validateJson`.

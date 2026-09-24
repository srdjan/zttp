# M4 T7 design note: reference tools and documentation

Status: accepted by the owner on 2026-09-24, with the recommended answer to
each question in section 5. U1 to U3 are implemented, so T7 is complete; the
evidence is in section 9.
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

## 9. Implementation notes and evidence

| Unit | Commit | Content |
|---|---|---|
| U1 | `d59055e6` | `toolInput(name, req)` and its build refusal |
| U2 | `ef4286f0`, `55de49a0`, `bc11a423` | ZTS514, the `schemaCompile` check |
| Corpus | `0ce1d45d`, `dbf32d0f`, `d055a981`, `75d716a8` | the approved DeepSeek re-record, coverage, convergence |
| U3 | this commit | `examples/tools`, `test-reference-tools`, the user guide |

**U1.** The grant carries the accepted catalog's `input_name`, and a new SDK
bridge call, `zttpSdkActiveToolInputSchema`, reads it. `toolInput` answers
`ok` only when the gate validated the current request against exactly that
name; otherwise the error names `not_a_tool_request` or `schema_mismatch`. The
binding declares the fields `validateJson` declares, so labels, result
tracking, fault coverage, and `input_validated` follow; the three name lists
the analyzers keep (type checker, path generator, request-schema
classification) name it too. The build refuses a `toolInput` whose name is
not a literal or not the route's catalog input (two `ToolCatalogRefusal`
members under ZTS513, with census cases).

**U2.** `validate_keywords.zig` (zts-base) holds the builder's copy of
`zttp:validate`'s keyword list, which `validate.zig` now exposes as
`supported_keywords`; a test in `builtin_modules.zig` pins the two together.
ZTS514 refuses each `validateJson`, `validateObject`, `coerceJson`, or
`decodeJson` call that names a schema `zttp:validate` cannot compile, and such
a `schemaCompile` literal that nothing reads unless a tool catalog names it.
A defect seed trips it through the real veto. The two nominal fixtures under
`packages/tools/tests/fixtures/contract/` read their input with `toolInput`;
their `validateJson` had failed on every input. `check-proof-swallow.sh`
caught a `catch continue` in the first version of the check, which would have
skipped a schema that failed to parse; it now propagates.

**Hashes and the corpus.** U1 moved the module registry hash and U2 the policy
hash; the module spec, the contract and expert goldens, the frozen signature
digest, the language overview counts, the stand-in range hash, and both pins
in `check-meta-drift.sh` moved with them. U1's own gate run was `zig build
test`, which does not run `check-meta-drift.sh`, so U1 left the module hash pin
stale and U2 corrected it. The owner approved the re-record. A one-case run
validated the pipeline in 29 s; the full run recorded 19/19 against
`deepseek-v4-flash` at a 600000 ms turn ceiling in 559 s, with raw first-draft
pass 14/19, first-attempt green 14/19, and reached green 19/19. The replay
reproduces 19/19 from flow artifacts.

**U3.** The example needed two things the design did not list: a `policy.json`
that names the upstream endpoint with the `loopback` address scope (a handler
that makes outbound requests connects nowhere without an address scope), and
`--outbound-host 127.0.0.1` on the artifact, which makes no outbound request
unless the operator allows it. Both are in the README. `zttp build` wraps the
`zttp-runtime` it finds beside its own binary, so the harness installs the two
built binaries side by side in its work directory.

`zig build test-reference-tools` builds the example with `zttp build`, starts
the artifact from an empty directory, serves the loopback upstream on 39460,
signs HS256 tokens, and sends real requests. It runs nine cases and fails
when it ran fewer than it declares: `convert`; `order_status`, whose upstream
receives `Authorization: Bearer <value>` and the query; B8.1 (403, and the
upstream receives nothing); B8.3 (502 `ResponseTooLarge`); B8.4 (500 `tool
output refused`); B8.2 and B8.7 (a mutated copy refused at build, with
`expected OrderId, got string` and `module_excluded_by_declaration
zttp:crypto`); and B8.8 and B8.9 (one byte of the declaration's `zttp:crypto`
or the catalog's `convert` description changed and the payload CRC recomputed;
the artifact refuses to serve with `graph_member_digest_mismatch`). A mutation
that finds nothing to change fails its case. `zig build test` depends on the
step.

**Gates.** Every verdict below comes from an unfiltered step with its exit status read directly, with every U3 file staged. `bash scripts/verify.sh` passed ("all CI test-job steps passed"). `zig build test`: 194 of 194 steps, 8916 of 8922 tests passed, 6 skipped. `test-zruntime`: 444 of 445, 1 skipped. `test-server`: 456 of 458, 2 skipped. `test-zts`: 2324 of 2325, 1 skipped. `test-modules`: 138 of 138. `test-standin`: 56 of 56. `test-reference-tools`: 9 of 9 cases. The first two `verify.sh` runs failed on gates `zig build test` does not run, and each failure was a real gap: `check-proof-swallow.sh` (the U2 swallow, fixed in `55de49a0`), `policy-hash.txt` (pinned in `bc11a423`), and the vocabulary envelope (regenerated in ``75d716a8``).

**Probes.** Each mutation was confirmed present, compiled, and restored with
`/bin/cp -f` and `cmp`. One U1 probe did not compile on the first attempt and
was redone.

| Mutation | Step | Failing test or case |
|---|---|---|
| `toolInput` skips the name comparison | `test-zruntime` | `toolInput answers ok only for the schema the gate validated` |
| the build skips the `toolInput` mismatch | `test-zts` | `a tool catalog is refused for each build rule it breaks` |
| ZTS514 not raised for a validation call | `test-zts` | `a schema zttp:validate cannot compile is refused where a call would fail, and legal in a catalog` |
| the example's catalog loses its `scope` | `test-reference-tools` | B8.1 (200 instead of 403; the upstream saw the request) |
| zttp.json renames the `orders` credential | `test-reference-tools` | the build refuses the example; 0 of 1 cases |
| the tamper cases change no byte | `test-reference-tools` | B8.8 and B8.9 (the artifact served) |
| a harness error stops the run early | `test-reference-tools` | the floor: "ran 1 cases, fewer than the 9 this check declares" |

**Not measured.** The harness uses a fixed upstream port, 39460, because the
example names it; two concurrent runs on one host would collide. No case runs
against a real TLS upstream. The build-time cases B8.2 and B8.7 edit
`tools.ts` by exact text; an edit to those lines of the example fails the
case as "the mutation found nothing to change", not silently.

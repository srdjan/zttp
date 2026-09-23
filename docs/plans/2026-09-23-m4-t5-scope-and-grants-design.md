# M4 T5 design note: subject scope and tool-local grants

Status: accepted by the owner on 2026-09-23, with the recommended answer to
each question in section 9. T5a is in progress; T5b follows. Check C5 of the
[M4 release contract](2026-09-22-m4-release-contract.md) is written against
the approach this note names.

All citations are to local `main` at `660aaf8e`.

## 1. What T5 must deliver

The release contract (T5, decisions 4 and 6, C5) asks for six things. The
runtime verifies an HS256 bearer JWT with a deployment-owned key before the
handler runs, sets the subject from `sub` and the tenant from a configured
claim, injects both, and the handler cannot read the raw claims. A call is
scoped: a caller cannot reach another tenant's resource with a valid
identifier (AE3), and a missing policy or identity denies. Each tool receives
only its own grants, so a tool cannot use another tool's authority (AE11,
B8.7), and a declared capability ceiling is enforced and reported (P15). Under
the tool profile the build refuses a tool route that reaches a cross-call read
(decision 6). T4 also moved the declaration's graph binding here, to land with
the ceiling section (T4 decision Q3).

C5 names AE2, AE3, AE15, B8.1, and B8.7, a census over each denial reason, and
two probes: remove the scope comparison and AE3 must fail; remove the
cross-call refusal and the cache case must fail.

## 2. What exists today

**The verifier cannot be called from the runtime.** `jwtVerifyImpl`
(`modules/src/security/auth.zig:100-177`) is private, takes a module handle and
JS arguments, and returns a JS `Result`; its clock and HMAC go through module
capability checks. The logic is right for T5: it checks the header algorithm
(`validateHs256Header`, `:299-326`, which refuses a missing or non-HS256 `alg`),
compares the signature in constant time, and refuses `exp` and `nbf` outside
the window. It checks no `sub`, `iss`, or `aud`, and allows no skew.

**The runtime holds no auth secret.** `RuntimeConfig`
(`runtime/src/runtime_config.zig:34-119`) has no key field. Handlers read
secrets only through `env()`, which the capability policy gates.

**The request path has the hook.** T3 matches a tool route and validates its
body after route pre-filtering (`server.zig:685-709`), before the proof cache
and any JS value. The proof cache already skips a request that carries an
`Authorization` header (`proof_adapter.zig:131-140`), so cached answers cannot
cross subjects. The native fast path runs after this point, so a check here
covers it.

**The handler sees the raw token.** `createRequestObject` copies every header,
`authorization` included, into the JS Request (`handler_instance.zig:1813-1818`).
The Request type has no identity field (`abi_types.zig:152-177`), and the flow
checker labels every `req.*` read `user_input` (`flow_checker.zig:961-962`).

**No capability check depends on the tool.** The resource allow lists are one
`RuntimePolicy` per context (`handler_policy.zig:153-208`, `context.zig:222`),
and module categories are fixed per export at compile time
(`module_binding/capabilities.zig:63-93`). Every tool in a handler therefore
shares one grant set, the union. The runtime knows which tool it is serving
(`tool_route`, `server.zig:688-691`) but does not pass it into the call, and
`AcceptedTool` drops the reachable exports (`contract_runtime.zig:66-73`).

**P15 is not implemented.** The three profiles (`boundary`, `adapter`,
`ledger`) exist only as published data (`tools/src/vocab_envelope.zig:368-406`,
`docs/consumer-contract.md:254-267`), and the declaration has no ceiling field.

**Decision 6's marker is incomplete.** Five exports declare `.unknown`:
`cacheGet`, `sqlOne`, `sqlMany`, `queue.receive`, and `durable.waitSignal`. But
`cacheIncr`, `cacheStats`, and `sqlExec` also read stored state without it, and
decision 6 names "zttp:cache reads" and "zttp:sql" as a whole.

## 3. Proposed split

T5 is about twice the size of T3. The proposal is two units, in order (question
Q1):

- **T5a, runtime identity, scope, and grants.** Sections 4 to 7. Needs no
  change to the declaration.
- **T5b, the declaration's ceiling and binding.** Section 8: the capability
  ceiling section (P15), the declaration's canonical form, and graph member 20.

Each closes with its own checks from C5, and T6 depends on T5a only.

## 4. Identity (T5a)

**Verifier.** A pure function, `auth.verifyHs256(allocator, token, key, now_s)`,
extracted from `jwtVerifyImpl` with `std.json` in place of the JS parse. It
returns the claims or one reason from a closed enum: `malformed`,
`unsupported_alg`, `bad_signature`, `expired`, `not_yet_valid`, `missing_sub`,
`missing_tenant`, `claim_not_string`. `jwtVerifyImpl` wraps it, so the handler
export and the runtime share one verifier.

**Configuration.** zttp.json gains an `auth` object: `keyEnv`, the name of the
environment variable that holds the HS256 key, and `tenantClaim`, the claim that
names the tenant. The runtime reads the key from its own environment at startup,
outside the handler's env allow list, and refuses to start a tool handler when
`auth` is missing or the variable is empty: a missing identity source denies
(question Q4).

**Check.** On every request to a tool handler, after route matching and before
input validation, the runtime reads `Authorization: Bearer <token>` and
verifies it. A missing header or a refusal answers 401 with the reason, before
any JS value exists.

**Injection.** The JS Request gains `subject` and `tenant`, both `string`, set
only from verified claims, and the type checker learns both fields. For a tool
handler the `authorization` header is removed from the Request, so the handler
cannot decode the claims itself. The flow checker gives `req.subject` and
`req.tenant` no `user_input` label: they come from the verifier, not the caller.

## 5. Scope (T5a)

A schema-valid identifier can still name another tenant's resource (roadmap
section 4.1). Injection alone leaves the comparison to handler code, and C5 asks
for a comparison the platform owns. The proposal (question Q2): a catalog entry
gains an optional `scope` field that binds input fields to the identity.

```ts
toolCatalog({
  lookupOrder: {
    route: "POST /tools/lookup-order",
    description: "Return the status of one order that belongs to the caller.",
    input: "LookupOrderInput", output: "LookupOrderOutput", maxInputBytes: 4096,
    scope: { tenant: "tenant_id" }
  }
});
```

The build refuses a `scope` field name that is not a required top-level string
property of the input schema. After input validation the runtime compares each
bound field with the verified value and answers 403 on a difference, before the
handler runs. The binding is part of the entry, so it travels in the catalog:
`ZTCAT1` gains a scope list and its schema moves from 1 to 2.

## 6. Tool-local grants (T5a)

The grant of a tool is its reachable-export set from T2, which the build proves
per route and the artifact binds in member 19. The runtime keeps the set on
`AcceptedTool` and sets the active tool on the context for the duration of the
call. The module call wrapper then refuses a call to an export outside the
active tool's set, with a named denial, before the export runs. A helper shared
by two tools can therefore do, in each, only what that tool's own set allows.
This is export-level authority; the resource allow lists stay per handler
(question Q3).

## 7. Cross-call reads (T5a, decision 6)

The builder refuses a tool whose reachable exports include a cross-call read,
as a new `ToolCatalogRefusal` member, `cross_call_read`, under ZTS513. The
refusal list follows decision 6's wording: every `zttp:cache` read (`cacheGet`,
`cacheIncr`, `cacheStats`), every `zttp:sql` export, `queue.receive`, and
`durable.waitSignal`. A test requires every export that declares `.unknown` to
be on the list, so a new cross-call read cannot be added without it. A new enum
member does not move the policy hash; the ZTS513 rule text does not change.

## 8. The declaration's ceiling and binding (T5b)

**Ceiling section.** The declaration gains `ceiling`: one profile name
(`boundary`, `adapter`, `ledger`) and an optional list of modules to exclude.
Its version moves to 2; version 1 files stay valid and mean no ceiling.

**Enforcement.** At build, the handler's capability matrix must be inside the
profile's categories, no imported module may be excluded by the profile or the
narrowing, and a profile that requires `read_only` refuses a handler that does
not prove it. At runtime, the module wrapper refuses a category outside the
ceiling. The applied ceiling is written into the contract (P15's report).

**Binding.** The declaration's canonical form, `ZTDCL1`, is a binary layout like
`ZTCAT1`: the classifications and the ceiling, sorted and bounded, with a
domain-separated digest. It ships as payload section 10 and binds as graph
member `declaration = 20`, decoded by a zero-copy kernel decoder, following T3
line by line.

## 9. Questions for the owner

- **Q1. Split.** T5a (identity, scope, grants, cross-call refusal) and then T5b
  (ceiling and binding), each with its own checks (recommended), or one unit.
- **Q2. Scope mechanism.** A catalog `scope` field that binds input fields to
  the subject or tenant, compared by the runtime before the handler
  (recommended: the comparison is the platform's, as C5 requires), or injection
  only, with scoping left to handler code.
- **Q3. Grant granularity.** Export-level per tool, from the proven
  reachable-export set, with the resource allow lists per handler
  (recommended), or also per-tool egress hosts, which needs per-route host
  extraction.
- **Q4. Key source.** zttp.json `auth.keyEnv` naming an environment variable
  read by the runtime at startup, with a tool handler refused when it is absent
  (recommended), or a key file path.

These are recommended and are not questions unless the owner objects: the
verifier's refusal enum and 401 on any refusal, `req.subject` and `req.tenant`
as trusted strings with no `user_input` label, the `authorization` header
removed from a tool handler's Request, `ZTCAT1` schema 2 for the scope list, the
cross-call list following decision 6's wording with a `.unknown` census test,
and a declaration version 2 that keeps version 1 valid.

## 10. Decisions

The owner answered on 2026-09-23. Q1: T5 splits into T5a (identity, scope,
grants, cross-call refusal) and T5b (ceiling and binding). Q2: a catalog
`scope` field binds input fields to the verified identity, and the runtime
compares them before the handler. Q3: grants are export-level per tool, from
the proven reachable-export set; resource allow lists stay per handler. Q4: the
key comes from the environment variable zttp.json's `auth.keyEnv` names, and a
tool handler refuses to start without it. The recommended defaults at the end of
section 9 stand.

## 11. Progress (T5a)

| Unit | Commit | Content |
|---|---|---|
| U1 | pending | pure `auth.verifyHs256` with a closed refusal enum; `jwtVerify` wraps it |
| U2 | pending | catalog `scope` field, `ZTCAT1` schema 2, `cross_call_read` refusal, `AcceptedTool` keeps scope and exports |
| U3 | pending | runtime: `auth` config, 401 verification, `req.subject`/`req.tenant`, header removal, 403 scope comparison, per-tool export grants |
| U4 | pending | AE2, AE3, AE15, B8.1, B8.7 end to end, census, probes, docs |

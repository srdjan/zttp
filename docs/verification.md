# Compile-Time Handler Verification

zttp can statically prove your handler function is correct at compile time. Enabled via `-Dverify` at build time, zero cost when disabled.

## Usage

```bash
# Build with verification
zig build -Dhandler=handler.ts -Dverify

# Combine with other flags
zig build -Dhandler=handler.ts -Dverify -Doptimize=fast
```

Verification runs after parsing and before bytecode generation. If any error-severity diagnostic is found, the build fails with a non-zero exit code. Warnings are reported but do not fail the build.

## Why This Works

zttp's JavaScript subset bans most sources of non-trivial control flow:

- No `while`/`do-while` (no back-edges)
- No `try`/`catch` (no exceptional paths)
- No `goto`, no labeled statements

`break` and `continue` are allowed within `for-of` loops. Both are forward jumps only (break jumps past the loop end, continue jumps to the next iteration) and do not introduce back-edges, so the verification invariant holds.

The only control flow is: `if`/`else` (forward branching), `match` (exhaustive forward branching), `for-of` (bounded iteration with `break`/`continue`), `assert` (guard with early return), and `return` (function exit). The IR tree IS the control flow graph. Verification is a recursive tree walk, not a fixpoint dataflow analysis.

## Checks

### 1. Exhaustive Response Returns

Every code path through the handler must return a Response. The verifier recursively determines whether each statement always, never, or sometimes returns:

- `return` - always returns
- `if` without `else` - sometimes (even if the then-branch returns)
- `if`/`else` where both branches return - always returns
- `for-of` - never (iterable could be empty)
- `var_decl`, `expr_stmt` - never returns

**Triggers when:** the handler body does not always return on every code path.

```
verify error[ZTS302]: not all code paths return a Response
  --> handler.ts:2:17
   |
  2 | function handler(req) {
   |                 ^
   = help: ensure every branch (if/else, match/default) ends with a return statement
```

**Fix:** add `else` clauses, `match` default arms, or trailing return statements.

### 2. Result Checking

Values from Result-producing virtual module calls (`jwtVerify`, `validateJson`, `validateObject`, `coerceJson`, `decodeJson`, `decodeForm`, `decodeQuery`, `decodeFormMultipart`) must have `.ok` checked before `.value` or `.unwrap()` is accessed.

The verifier tracks result bindings through the control flow tree:

```javascript
import { jwtVerify } from "zttp:auth";

function handler(req) {
    const token = req.headers.authorization;
    const result = jwtVerify(token, secret, "HS256");

    // ERROR: accessing result.value without checking result.ok
    return Response.json(result.unwrap());
}
```

```
verify error[ZTS303]: result.value accessed without checking result.ok first
  --> handler.ts:7:28
   |
  7 |     return Response.json(result.unwrap());
   |                            ^
   = help: check result.ok before accessing result.value:
           if (result.ok) { ... result.value ... }
```

**Recognized patterns for .ok checks:**

- `if (result.ok) { ... }` - direct boolean discriminant
- `if (result.isOk()) { ... }` - method call
- `if (result.ok === true) { ... }` - strict equality
- `if (!result.ok) { return ...; }` - negated early return (code after is safe)
- `if (result.isErr()) { return ...; }` - error early return

### 3. Unreachable Code

Statements after an unconditional return in a block. Severity: warning.

```
verify warning[ZTS304]: unreachable code after return statement
  --> handler.ts:4:5
   |
  4 |     const x = 42;
   |     ^
   = help: remove the unreachable code, or restructure the control flow
```

### 4. Unused Variables

Declared variables that are never referenced. Severity: warning. Suppress by prefixing the name with `_`.

The check is scope-aware: a variable used only in a nested scope that shadows an outer declaration does not count as a use of the outer binding.

```
verify warning[ZTS305]: unused variable 'temp'
  --> handler.ts:3:11
   |
  3 |     const temp = computeValue();
   |           ^
   = help: remove the variable, or prefix with _ to suppress: _temp
```

### 5. Non-Exhaustive Match

Match expressions without a `default` arm are rejected by strict ZigTS (ZTS603) unless the type checker can prove that the arms cover every value of the matched type. A closed type is covered by arms alone, and several arms may split one case. An open type such as `string`, `number`, `unknown`, or `T[]` needs a `default` arm. The help text names the first missing case.

```
strict error[ZTS603]: match expression must be exhaustive in strict ZigTS
  --> handler.ts:5:12
   |
  5 |     return match (command) {
   |            ^
   = help: missing case: when { kind: "c" }. Add an arm for it, or add a 'default:' arm.
```

A `default` arm after full coverage of a closed type, and any arm that no value can reach, is the warning ZTS216 (`default arm is unreachable` or `match arm is unreachable`). The type checker reports ZTS205 for the same missing case when the strict check does not run. A match that is not proved exhaustive has the type of its arms or `undefined`.

### 6. Exhaustive Optional Handling

Four virtual module functions return optional values (`T | undefined`):

- `env("KEY")` - returns `string | undefined`
- `cacheGet("ns", "key")` - returns `string | undefined`
- `parseBearer(header)` - returns `string | undefined`
- `routerMatch(routes, req)` - returns `object | undefined`

The verifier tracks these optional bindings and requires them to be narrowed
before use. Using an optional value as a function argument, object property
value, numeric operand, or string-array element without first checking for
`undefined` is an error.

```javascript
import { env } from "zttp:env";

function handler(req) {
    const appName = env("APP_NAME");

    // ERROR: optional value used without checking for undefined
    return Response.json({ app: appName });
}
```

```
verify error[ZTS308]: optional value used without checking for undefined
  --> handler.ts:6:30
   |
  6 |     return Response.json({ app: appName });
   |                              ^
   = help: check before use: if (val !== undefined) { ... }
           or provide a default: val ?? "fallback"
```

Property access on an un-narrowed `optional_object` (from `routerMatch`) is also an error:

```
verify error[ZTS309]: property access on optional value without checking for undefined
```

**Recognized narrowing patterns:**

- `if (val !== undefined) { ... }` - explicit check narrows in then-branch
- `if (val === undefined) { return ...; }` - explicit check with early return
- `const x = env("KEY") ?? "default"` - nullish coalesce resolves at declaration
- `val = "override"` - reassignment to non-optional clears tracking
- `val?.prop` - optional chaining is safe (not flagged)

### 7. State Isolation (Cross-Request Safety)

The verifier detects module-scope variable mutations inside the handler body. Since handlers are re-invoked per request with fresh scope, mutating a module-level `let` binding would leak state between requests.

The check walks all assignment nodes in the handler body. If the target is an identifier whose binding has a scope_id less than the handler's scope_id (meaning it's declared at module level), the verifier emits a `module_scope_mutation` error.

```typescript
// ERROR: handler mutates module-scope variable
let counter = 0;

function handler(req: Request): Response {
    counter = counter + 1;  // verify error: module_scope_mutation
    return Response.json({ count: counter });
}
```

Fix: use `const` for module-level declarations, or move mutable state to `zttp:cache`.

A member or index write gets the same error when its base is a builtin such as `Math` or `parseInt`, a module-scope binding, or a local initialized from one of them. The check follows one level of alias. It does not follow an alias through a call or a member chain.

The runtime does not freeze builtin objects. A handler with no accepted certificate runs on `.reuse_bounded_by_count`: one runtime serves up to a fixed count of requests. State that such a handler writes, in a module-scope binding or in a builtin object, can cross requests within that count. The check above keeps that handler from proving `state_isolated`, which is the property that allows wider reuse.

The result feeds into `HandlerProperties.state_isolated`. When no module-scope mutations are detected, `state_isolated` is proven true, enabling safe multi-tenant handler sharing. A contract built without `precompile --verify` leaves `state_isolated` false. `false` on any property means unproven, not violated.

### 8. Author-Declared Proof Discharge

The verifier resolves the handler's active spec set and discharges each
name against the classified `HandlerProperties`. When the handler declares
no `Proof<T, P>`, every supported v1 spec is active by default. A
`Proof<T, P>` on the handler return type narrows the active set to exactly
the names in the annotation. The machinery lives in `spec_discharge.zig`
and runs after the analyzer pipeline so it has access to the full property
set plus the imported module list.

```typescript
structural Guardrails<T> = Proof<T, "idempotent" | "deterministic">;

function handler(req: Request): Guardrails<Response> {
    return Response.json({ now: Date.now() });
}
```

Three diagnostic codes:

- **ZTS500 - spec_not_discharged**: the corresponding property field is
  false. Cause-only specs (`deterministic`, `read_only`, `retry_safe`,
  `idempotent`, `state_isolated`, `fault_covered`, `pure`, `stateless`,
  `result_safe`, `optional_safe`, `canonical`, `cost_bounded`) include a
  per-property `Try:` suggestion. Counterexample-rich specs
  (`no_secret_leakage`, `no_credential_leakage`, `input_validated`,
  `pii_contained`, `injection_safe`) include a falsifying request body.
  `cost_bounded` discharges when the worst-path module-call count has a
  finite envelope; its suggestion points at literal arrays, `range(n)`,
  `.slice(0, k)`, SQL `LIMIT n`, or schema `maxItems`.
- **ZTS501 - spec_incompatible_with_import**: the spec contradicts an
  imported module. v1 fires for `Proof<Response, "read_only">` against
  `zttp:cache` or `zttp:sql`. ZTS500 is suppressed for the same
  name so the agent does not enter repair against a contradiction.
- **ZTS502 - spec_unknown_name**: the declared name is not in the v1
  set.

Diagnostics are stored on `HandlerContract.spec_diagnostics`. Surfaces:
the live HUD, the proof ledger
(`declaredSpecs: [{name, discharged, diagnosticCode?,
diagnosticMessage?, sourceLine?, sourceColumn?, sourceSnippet?}]` per
swap event; the diagnostic fields appear only on failed specs),
`zts check --json` (`declared_specs` as the effective active set and
`spec_diagnostics` arrays), and the `pi_specs_status` agent tool. See
[user-guide.md](user-guide.md#author-declared-proofs) for the author-side
view.

### 9. Proof-Carrying Functions

Spec discharge also runs per helper. A `Proof<T, "...">` annotation on a
helper's return type is discharged against the facts effect inference
and path-return analysis prove about that function (`function_specs.zig`),
for the v1 capsule set `total`, `pure`, `read_only`, `deterministic`.
Helper failures reuse ZTS500 / ZTS502, each carrying a `function`
attribution. A helper that breaks a property the handler's `Proof<T, P>`
demands while carrying no capsule for it gets **ZTS606 -
missing_capsule**: the proof cannot compose across that call boundary.
`computeProperties` intersects the handler's classified properties with
its call-graph-composed effect row, so a property the handler claims
also accounts for every helper it transitively calls. `zts check
--json` adds a `proofCapsules` array; see
[zts-expert-contract.md](internals/zts-expert-contract.md).

For relative imports, effect analysis uses the sibling's exported value and its transitive effects.
Writes can block `read_only` and `retry_safe`. Cache reads can block `stateless`.
Egress includes outbound calls that a sibling makes.
Missing files, missing exports, parse failures, cycles, and depth limits leave effects incomplete.
Incomplete effects cannot establish an absence of writes or egress.
With incomplete effects, `has_egress` reports possible egress. The proof trace identifies the incomplete analysis.

CHECK computes these effects during its existing imported-flow reads.
CHECK retains a separate fault traversal, with its existing read order and stopping rules.
Graph extraction uses the loaded compilation parsers and makes no additional reads for effect summaries.
The entry contract receives these facts before merging. The merged contract retains null aggregate properties.
Legacy capability and purity charging remains conservative for relative imports.

Counterexample-rich specs additionally feed a persistent on-disk
corpus. Each falsifying input the analyzer materialises is written
under `.zttp/witnesses/<short_hash>/` so the same logical leak does
not need to be rediscovered next session. See
[Witness Corpus](proofs-and-receipts.md#witness-corpus)
for layout.

A witness drives each `fetch` that a
branch tests to the response the branch needs: status 503 behind `!res.ok`
or `res.status !== 200`, status 200 on the success side, and a status that
takes the branch for any other status comparison. A witness written before
this rule keeps its old stub, because the corpus does not rewrite a known
witness. Delete its entry to record it again.

### 10. Capability Capsules

`Effects<T, "...">` is the capability dual of `Proof<T, "...">`. Where a
proof property declares a guarantee, an `Effects<...>` annotation
declares a *ceiling*: the function's inferred capability row may be no
wider than the named set. Discharge is the inverse direction of proof
discharge - checked `inferred ⊆ declared` against the row
`effect_inference.zig` computes from real call sites. A reached
capability outside the ceiling is **ZTS503**, an unknown capability name
is **ZTS504**, and a declared-but-unreached capability is the warning
**ZTS505**. The vocabulary is the runtime capability set (`env`,
`clock`, `crypto`, `network`, ...).

The same annotation on the handler's return type is a **budget** that
bounds every reachable helper. A capability the handler reaches directly
outside the budget is **ZTS506**; one a reachable helper introduces is
**ZTS607**, attributed to that helper by `contract_builder.zig`.
The declared budget is recorded in `contract.json` under
`sandbox.declaredBudget`. `zts check --json` adds an `effectCapsules`
array alongside `proofCapsules`.

Where a ceiling goes is decidable rather than optional: an exported function
with a nonempty inferred row must declare one (ZTS610), and a module-internal
function must not (ZTS623), because the compiler infers the internal row and
the handler's budget already bounds it.
The budget and every ceiling are discharged only against inferred facts
from real function bodies, never an assumed claim. The opt-in
`zts check --require-export-capsules` docs mode additionally warns
(**ZTS508**) when an exported helper carries no `Proof<...>` capsule.

### Runtime Optimizations from Verification

Some verified facts control runtime behavior, but they cross different trust
boundaries:

- **Route pre-filtering**: integrity-validated, statically enumerated routes reject non-matching requests at the HTTP layer before entering JS (`contract_runtime.zig`).
- **Response memoization**: only an accepted deployed certificate can promote `deterministic` and `read_only` for this purpose. The shipped production policy accepts neither property, so this cache remains off today. A future policy must also require a contract showing that the handler reads no request headers or body. The cache key is method plus URL, so header/body-dependent handlers are excluded. Cached responses include an `X-Zttp-Proof-Cache: hit` header (`proof_adapter.zig`). Development, live reload, and `-Dhandler` execution carry no accepted artifact certificate and do not activate this cache.

Both rely on the same property that makes verification tractable: the IR tree is the control flow graph, with no back-edges and no exceptions.

## Exhaustive Path Analysis

A contract build (`-Dcontract`) runs compile-time exhaustive path enumeration and fault coverage analysis.

### Path Generator

The `PathGenerator` (`packages/zts/src/path_generator.zig`) walks the handler's IR tree, forking at every branch point (`if`/`match`) and I/O success/failure boundary. Each fork produces a test case representing one complete execution path through the handler. This exploits the same property that makes verification tractable: the IR tree IS the control flow graph (no back-edges).

For Result-producing calls (`jwtVerify`, `validateJson`, `decodeJson`, etc.), the generator forks into both the `ok: true` and `ok: false` paths. For optional-producing calls (`env`, `cacheGet`, etc.), it forks into defined and `undefined` paths. For `fetch` and `fetchWithRetry`, `res.ok` forks the same way: the generator reads the export's declared return type, and a record with a required `ok: boolean` field, on an export that has a failure severity, makes `res.ok` a success or failure fork. The generated test stubs the failing fetch with a 503 response and the succeeding fetch with a 200. A comparison of `res.status` with a number literal (`!== 200`, `=== 200`, or the same with the literal on the left) forks the same way, because it is the complement of `ok` (`ok` is a status from 200 to 299, and `fetch` does not follow redirects, so a 3xx reaches the handler). A comparison that leaves some non-2xx status on the success side, such as `>= 300`, `>= 400`, or `=== 404`, is an ordinary branch and is not a fork: the generated test stubs the call with a status that takes the branch, and the failure path still needs a `res.ok` check. A status first read into a `const` is not recognized.

### Fault Coverage Analysis

The `FaultCoverageChecker` (`packages/zts/src/fault_coverage.zig`) analyzes the generated paths against `FailureSeverity` annotations on each virtual module function:

| Severity | Functions | Meaning |
|----------|-----------|---------|
| `critical` | `jwtVerify`, `validateJson`, `validateObject`, `coerceJson`, `decodeJson`, `decodeForm`, `decodeQuery`, `decodeFormMultipart`, `verifyWebhookSignature`, `rateCheck` | Auth, validation, signature, and rate-limit failures must not produce 2xx |
| `expected` | `cacheGet`, `env`, `cacheSet` | Cache misses and missing env vars are normal degradation. A failed `cacheSet` can leave an earlier value in place. |
| `upstream` | `fetch`, `fetchWithRetry` | An external service failure. These calls return the fetch response record. The `res.ok` and status forks cover them. A 2xx answer can be an intended fallback. |

The checker warns when a critical I/O failure path (e.g., `jwtVerify` returning `{ok: false}`) produces a 2xx response. This is a structural pattern overwhelmingly correlated with bugs. Cache misses returning 200 are correctly classified as graceful degradation and do not trigger warnings.

A function with severity `none` is not counted. That is not a claim that the
function cannot fail. `severity_census.zig` lists each exception with its
reason. For example, validation calls count a missing schema where the schema
is used.

Every call to a failable function counts as its own site, keyed by call site. Two calls to `jwtVerify` are two sites, and a failure path for one does not cover the other. `fault_covered` is proven only when all of these hold:

- every counted site has a failure path (a branch on its failure, or a `??` fallback on an optional export);
- no failable call sits where the walk cannot see it: inside a nested function or callback, inside a helper, inline in an expression, as a call argument, as a `match` scrutinee, or in a branch that does not return. The analysis fails closed on such a call: the property is unproven, and the trace names the first call;
- every import that is not a builtin module was scanned and holds no failable call. A sibling file imported with `./` or `../` is scanned whole, with its own imports in turn. An unreadable or unparsable file, a chain deeper than eight files, a bare package specifier, and a partner module each block the property, because no failure model reaches them. The browser analyzer has no filesystem, so any relative import blocks there. The trace names the import line and the file;
- the enumerated paths are exhaustive (a loop walked once, recursion, or a path limit makes them a summary, which blocks the property);
- an `&&` condition counts every way it can be false. `if (!auth.ok && req.method === "POST") return 401;` falls through when the check fails on a GET too, so that path is enumerated, and a 2xx on it is a critical warning. A failable call tested by a later conjunct can have failed even when short-circuit evaluation skips the test, so that case is enumerated as well;
- no critical failure path returns 2xx.

A 2xx fallback on an upstream failure does not block the property. It is reported in `upstreamFallbackSites` and the proof trace summary.

A handler that proved `fault_covered` under an earlier analysis can lose it
when a `fetch` moves into a callback. The upgrade verifier
(`upgrade_verifier.zig`) classifies a lost `fault_covered` as a critical
regression. The policy hash includes the path analysis version. An older
contract no longer matches and is rebuilt.

Results appear in:
- `contract.json` under the `faultCoverage` section
- `HandlerProperties.fault_covered` flag
- Deployment manifest tags (`zttp:faultCovered`)

### Cost Envelope (Multiplicity)

The banned back-edge constructs (`while`, `do...while`, `for(;;)`, recursion)
buy more than termination: they make the worst-path resource cost of a handler
statically computable. `PathGenerator.buildCostEnvelope` folds the multiplicity
of every module call along the enumerated paths into a per-module `CostEnvelope`
(`packages/zts/src/contract_types.zig`). Each bound is a symbolic `Bound`:

- `constant` - exactly `n` calls on the worst path.
- `linear` - `base + coefficient * |source|` calls, where `|source|` is the
  length of one request-derived collection an I/O call loops over. The bound
  carries the loop's source location and the collection name, so a handler that
  calls `sqlOne` inside `for (const id of ids)` reports `1 + 1*|ids|` rather than
  the old `max_io_depth` undercount of `2` (which walked the loop body once).
- `unbounded` - no expressible bound (an unidentifiable iterable, or two dynamic
  collections on one path), carrying the offending loop's location.

The envelope is written to `contract.json` under `costEnvelope` and covered by
the `Zttp-Attest` JWS signature. `HandlerProperties.max_io_depth` is set
only when the total bound is constant, else `null`.

A `linear` or `unbounded` bound is dischargeable to `constant` by sizing the
loop source: iterate a literal array, a `range(n)` literal, `Object.keys` of an
object literal, a `.slice(0, k)`, a SQL statement ending in `LIMIT n`, or a
field of a `zttp:validate` schema that declares `maxItems`. When the total
bound is constant or linear with exhaustive path enumeration, the
`cost_bounded` property holds and `Proof<Response, "cost_bounded">` discharges against it;
otherwise the proof card's counterexample names the loop and the discharge
lever.

Two things make the total unbounded whatever the loops say. A function value
that is used as a value anywhere in the module - stored in a record or an
array, returned, assigned to a `let`, bound to a second name, or passed to a
user function or to an unlisted import - can be called with no edge in the
call graph, so recursion through it is invisible. The module then proves no
`total` capsule and no `cost_bounded`, and the diagnostic names the first such
site. A reference to a relative import counts as such a site when the
imported module has one of its own, or when its result is unknown. A function value is not an escape when it is declared once and called by
name, passed as the first argument of `map`, `filter`, `forEach`, `reduce`,
`some`, `every`, `find`, `findIndex`, `flatMap`, or `sort`, passed as the
callback argument of `mapResult`, `andThen`, `mapError`, or `orElse`, or held
as a value of a route table that only `routerMatch` reads. A callback argument
is closed only when it is an inline function, an import, or a module-level
function: a function declared inside another function has no call-graph edge,
so passing it to `map` is an escape. The handler also loses `cost_bounded` when
its effect row is a lower bound, for example when it calls a closure declared
in its own body.

Results appear in:
- `contract.json` under `costEnvelope`, plus the honest `properties.maxIoDepth`
- The `cost_bounded` proof chip and `Proof<Response, "cost_bounded">` discharge
- The `contract_diff` cost lane: widening a bound to `unbounded` is breaking, a
  bounded widening (`constant` to `linear`) is additive; this reaches
  `prove-behavior` and `proofs gate`
- Deployment manifest tags (`zttp:costClass`, `zttp:costBound`,
  `zttp:costSource`, `zttp:costWorstCase` evaluated at `--max-body-size`)
  and the `kind=deploy` receipt
- A runtime cost fuse: the interpreter counts module calls per request at the
  capability-enforcement chokepoint and, on an excess over the proven envelope,
  records a `cost_bounded` soundness incident (log-only, with the arena
  high-water as evidence; it never alters the response)

## Artifact-Level Proof-Carrying Code

Everything above is what the compiler establishes about a handler. This section
is about what a consumer establishes about the artifact that ships.

The difference matters because the compiler is the producer. It can be wrong,
it can be an older build than the one that ran, and it can be replaced. A
runtime that reads its verdict and believes it has checked nothing. So a
deployed artifact now carries a certificate, and the runtime checks it with an
independent kernel before it serves a request.

### Five separate answers

These are reported as distinct states, never collapsed into one word:

| State | What it means |
|---|---|
| `parsed` | The certificate decoded within its resource bounds. Nothing about the artifact is established. |
| `integrity_verified` | Every member of the executable graph the consumer recomputed matches the certificate, the complete certificate commitment matches its graph member, and the root over them matches too. |
| `proof_checked` | The reconstructed obligations equal the supplied ones, and every obligation carries evidence the consumer checked or explicitly graded. |
| `policy_accepted` | The checked result meets this consumer's required properties, epochs, and minimum grades. |
| Provenance | Orthogonal: `absent`, `unchecked`, `signature_verified`, or `trusted_origin`. It never raises or lowers a semantic state. |

The Zig `Assessment.outcome` is either `accepted` or `rejected`. An accepted
outcome has a grade and the certificate's development flag. A rejected outcome
has a rejection, the stage it reached, and an optional development flag. The
flag is absent when certificate decoding did not return an identity. A rejection
at `proof_checked` can have a grade or no grade. A rejection at an earlier stage
has no grade. Provenance, work spent, property verdicts, disclosed edge count,
and guard verdicts remain on `Assessment`. A rejection can report completed
work.

Each property verdict is one of `none`, `graded`, or `accepted`. The latter two
carry a grade. An accepted property therefore always has a grade. The public
`gradeFor` and `accepted` methods report these values.

A signature says who signed. It does not say what was signed is safe. An
unsigned artifact whose certificate this consumer accepts is accepted; a signed
artifact whose certificate fails is not.

### The executable graph

The artifact commitment covers every byte and identity that can affect what runs:
the entry module's bytecode, each dependency module in load order, every
function in every module, every constant pool, the module specifiers in declared
order, the native-module binding identities, the contract, the runtime policy,
the source profiles, the grammar, the semantics registry, the capability matrix,
the proof IR, and every authority-bearing certificate section. Order is part of
the commitment. The certificate fold normalizes only its executable-root slot
and its own graph-member digest, which makes the cycle finite without excluding
evidence, translation witnesses, trusted edges, or solver queries.

A native-module identity uses a canonical serialization of the complete binding
surface. Module and per-export capabilities, declared signatures,
trace and replay flags, return labels, contract extraction rules, state model,
and algebraic laws all move the executable root when they change.

The producer builds this inventory from the section bytes it is about to embed.
The consumer rebuilds it from the section bytes it just loaded. Neither reads
the other's list; the comparison is only worth anything because the two
derivations are independent.

### Assurance grades

A certificate is a chain, and a chain is as strong as its weakest link. Every
obligation is graded by the weakest edge that was actually used, and the
artifact's grade is the weakest across the properties the policy required:

| Grade | Meaning |
|---|---|
| `proved` | A small-kernel rule the consumer re-ran itself over the proof IR. |
| `translation_validated` | The consumer also re-related the proof IR to the final bytecode: emissions nest without partially overlapping, and every jump lands on the start of the member it names. |
| `solver_assumed` | An isolated solver, run outside the kernel, discharged a reconstructed query. No answer means inconclusive, and inconclusive is a rejection. |
| `tested` | A finite corpus exercised it. Disclosed by the producer, not checked by the consumer. |
| `trusted` | Declared, with a reason. Disclosed, not checked. |

A grade describes the check that ran. It does not describe what the chain still
rests on, so every result also reports how many edges the certificate disclosed
rather than the consumer checked. The runtime's acceptance line and
`zttp proofs verify` both print the count next to the grade.

### What is not checked, said out loud

- **The bytes at the witness offsets.** The consumer checks that the translation
  witnesses hold together - ranges nest, jumps land on member starts, rewrite
  spans add up - not that the bytes at those offsets decode to the instructions
  the witnesses describe. That edge is disclosed as `trusted` in every
  certificate's own inventory and is counted in every result. Closing it means
  giving the kernel the opcode encoding, which is a data coupling to the engine
  that can drift silently; disclosing it is the honest interim.
- **Three of the four production-floor properties.** `results_checked`,
  `no_secret_leakage`, and `capability_bounded` are disclosed as `tested`: the
  compiler discharged them and the repository's corpus exercises the analyses
  that do so, but this consumer did not re-run them. Only `response_total` is
  re-derived by the consumer today. Reducing that list one family at a time is
  the ratchet's job.

### The residual boundary, in full

Which properties the consumer re-derives, and which it accepts on the producer's
word. `scripts/check-proof-ratchet.sh` compares this list against
`Property.consumerChecked` in the acceptance kernel and fails in both
directions, so it cannot drift from what shipped.

<!-- proof-ratchet: consumer-checked -->
- `response_total`
<!-- proof-ratchet: disclosed -->
- `results_checked`
- `no_secret_leakage`
- `state_isolated`
- `deterministic`
- `read_only`
- `retry_safe`
- `capability_bounded`
<!-- proof-ratchet: end -->

Promoting one is the unit of work that shrinks this list: it means adding the
property's members to the proof IR and its rule to the kernel, not relabelling
the edge. `results_checked` is the next one - the result-binding dataflow is the
smallest analysis the kernel does not yet model, and it is the property with the
most direct security consequence after totality.

### Residual runtime guard boundary

A computed environment key, egress endpoint, or cache namespace can compile
only when the configured capability policy declares its section. The compiler
records a residual obligation. The consumer reconstructs the obligation from
its own catalog, binds the exact serialized policy bytes, and requires exact
coverage before activation. SQL remains literal-only because
`sql.allow_queries` cannot distinguish a read from a write.

Guard coverage is not a Property. Producer property facts, consumer guard
coverage, and live allow or deny decisions are three separate channels. A
covered operation must leave the proven Property set unchanged. At runtime, the
actual resource is checked at the authoritative sink against the installed
policy generation.

The machine-marked boundary below is checked by
`scripts/check-residual-guards.sh`. Catalog order is significant because the
proof IR carries the row index. The same gate checks the compiler mirror, the
enabled families, and the stand-in conversions in both directions.

<!-- residual-guards: catalog -->
- `zttp:env|env|0|env_key|identifier_exact_v1|env|env_read|env_read_v1=1`
- `zttp:fetch|fetch|0|egress_endpoint|endpoint_v1|egress|egress_connect|egress_connect_v1=1`
- `zttp:fetch|fetchWithRetry|0|egress_endpoint|endpoint_v1|egress|egress_connect|egress_connect_v1=1`
- `zttp:cache|cacheGet|0|cache_namespace|identifier_exact_v1|cache|cache_operation|cache_operation_v1=1`
- `zttp:cache|cacheSet|0|cache_namespace|identifier_exact_v1|cache|cache_operation|cache_operation_v1=1`
- `zttp:cache|cacheDelete|0|cache_namespace|identifier_exact_v1|cache|cache_operation|cache_operation_v1=1`
- `zttp:cache|cacheIncr|0|cache_namespace|identifier_exact_v1|cache|cache_operation|cache_operation_v1=1`
- `zttp:cache|cacheStats|0|cache_namespace|identifier_exact_v1|cache|cache_operation|cache_operation_v1=1`
- `zttp:sql|sqlOne|0|sql_read|identifier_exact_v1|sql|sql_execute|sql_execute_v1=1`
- `zttp:sql|sqlMany|0|sql_read|identifier_exact_v1|sql|sql_execute|sql_execute_v1=1`
- `zttp:sql|sqlExec|0|sql_write|identifier_exact_v1|sql|sql_execute|sql_execute_v1=1`
<!-- residual-guards: enabled -->
- `env`
- `egress`
- `cache`
<!-- residual-guards: evidence -->
- `env|dynamic-capability`
- `egress|dynamic-capability-egress`
- `cache|dynamic-capability-cache`
<!-- residual-guards: end -->

Each policy category accepts at most 256 entries. Exact membership lookup uses
an immutable sorted index and takes at most nine comparisons at that maximum.
The serialized policy is capped at 256 KiB. Non-endpoint identifiers are capped
at 255 bytes and normalized endpoints at 512 bytes.

### What proof acceptance unlocks, and what it does not

Only a proof-checked contract drives behavior that is unsound if a claim is
wrong: the proof response cache, unbounded runtime reuse, and the result and
optional safety shortcuts. An artifact
whose certificate is missing or refused does not serve at all.

A development server, a live-reload swap, and a `-Dhandler` build carry no
artifact and no certificate, so they get none of those. That is the same rule
seen from the other side, not an exemption: there is no consumer, so there is
nothing checked, so nothing is promoted.

A guarded installed generation is not eligible for the certificate-free live
swap path. A candidate that would add or strand a residual guard is refused and
the previous generation stays active.

Nothing about acceptance relaxes a runtime control. Bytecode structural
verification, capability enforcement, request isolation, authorization, limits,
leases, and live policy checks are mandatory before and after. A certificate is
a reason to run a handler, not a reason to stop checking it.

### Checking an artifact yourself

```bash
zttp proofs bundle --binary ./my-service --out bundle
zttp proofs verify bundle --require-proof
```

The bundle carries the certificate as its own component. `verify` reports
integrity and proof as separate lines, and `--require-proof` turns "nothing to
check" into a non-zero exit for a caller that needs the stronger state.

`zttp verify <url>` is a different command with a different answer: it checks a
signature over a claim an endpoint returns. The endpoint does not return the
artifact, so that command reports provenance and says so.

### Format cutover

Production accepts certificate schema `5` and proof system `zttp_pcc_v3 = 3`
only. The self-extract payload is format 7, the attestation envelope is
`zttp-attest-v4`, and the proof bundle is `zttp-bundle-3`. Every identity is
checked for equality rather than a lower bound. Schema 4 and format 6 are
refused with a rebuild diagnostic. The runtime does not reinterpret them.

## Running Tests

```bash
zig build test-diagnostic-corpus
```

The golden diagnostic corpus in `tests/corpus/` pins the diagnostics and the
analysis stages for each handler file. `zig build test` runs it. The format is
in `tests/corpus/README.md`.

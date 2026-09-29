# User Guide

zttp runs TypeScript and TSX HTTP handlers from a single Zig
binary. The language surface is intentionally restricted so the compiler can
prove handler properties before and during local development.

## Install

Install a release build:

```bash
curl -fsSL https://raw.githubusercontent.com/srdjan/zigttp/main/install.sh | sh
zttp --help
```

Build from source with Zig `0.16.0`:

```bash
git clone https://github.com/srdjan/zigttp.git
cd zigttp
zig build -Doptimize=ReleaseFast
./zig-out/bin/zttp --help
```

## First Project

```bash
zttp init my-app
cd my-app
zttp dev
```

The scaffold writes `zttp.json`, `src/handler.ts` or `src/handler.tsx`, and
starter tests. `zttp dev` reads the project config, starts the local server,
watches the handler, and prints a proof card on every save.

Run tests and build a local deploy artifact:

```bash
zttp test
zttp deploy
./.zttp/deploy/my-app
```

`deploy` verifies the handler, emits a self-contained binary, writes
`.zttp/proofs.jsonl`, and signs a proof receipt unless `--no-attest` is
passed.

For a one-file experiment:

```bash
zttp serve -e "function handler(req) { return Response.json({ ok: true }) }"
zttp serve examples/handler/handler.ts -p 3000
```

## Handler Shape

A handler is a function named `handler` that receives a request and returns a
`Response`.

```ts
function handler(req: Request): Response {
    if (req.path === "/health") {
        return Response.json({ ok: true });
    }
    return Response.text("Not Found", { status: 404 });
}
```

Request fields used by examples:

| Field | Meaning |
|---|---|
| `req.method` | HTTP method, for example `GET` or `POST`. |
| `req.url` | Raw URL path and query as received by the server. |
| `req.path` | Path without query string. |
| `req.query` | Query string object when available. |
| `req.headers` | Lowercase header map. |
| `req.body` | Decoded request body, typed `string \| undefined`: the runtime writes `undefined` when the request carries none, so narrow it (`req.body ?? ""`) before passing it where a `string` is wanted. `Content-Length` and HTTP/1.1 chunked request bodies are accepted. |
| `req.params` | Route parameters, when a router has assigned them. |

Response helpers:

```ts
Response.text("ok")
Response.json({ ok: true }, { status: 201 })
Response.html("<h1>Hello</h1>")
```

## Routing

Small handlers can branch directly:

```ts
function handler(req: Request): Response {
    if (req.method === "GET" && req.path === "/todos") {
        return Response.json({ items: [] });
    }
    if (req.method === "POST" && req.path === "/todos") {
        const body = JSON.parse(req.body ?? "{}");
        return Response.json({ title: body.title }, { status: 201 });
    }
    return Response.text("Not Found", { status: 404 });
}
```

Use `zttp:router` when you need path parameters:

```ts
import { routerMatch } from "zttp:router";

function handler(req: Request): Response {
    const routes = { "GET /users/:id": true };
    const match = routerMatch(routes, req);
    if (match !== undefined) {
        return Response.json({ id: match.params.id });
    }
    return Response.text("Not Found", { status: 404 });
}
```

For multi-handler routing behind one listener, see [Edge Runtime](edge.md).

## JSON And Validation

Use normal `JSON.parse` and `Response.json` for basic JSON. Use
`zttp:validate` or `zttp:decode` when the handler needs schema-backed
validation.

```ts
import { schemaCompile, validateJson } from "zttp:validate";

schemaCompile("todo", '{"type":"object","required":["title"]}');

function handler(req: Request): Response {
    const parsed = validateJson("todo", req.body ?? "");
    if (!parsed.ok) {
        return Response.json({ error: "invalid body" }, { status: 400 });
    }
    return Response.json(parsed.value, { status: 201 });
}
```

Result-producing virtual-module calls must be checked before `.value` access.
Optional-producing calls must be narrowed before use. The verifier enforces both
patterns.

## Tool Routes

A tool route is an HTTP route that a model or an agent can call, with a closed
input, a closed output, and a caller the runtime has verified. The handler
declares its tools with `toolCatalog` from `zttp:tool`, and the runtime checks
every tool request before and after the handler runs. `examples/tools/` is a
complete project with two tools; this section walks through it.

**The catalog.** Call `toolCatalog` once at module scope with an object
literal. Each entry names a `routerMatch` route, a description, an input and an
output schema registered with `schemaCompile`, and `maxInputBytes`. Every route
in the table must have an entry. Tool schemas use a closed subset: every object
has `"additionalProperties": false`, every string has `maxLength`, and every
array has `maxItems`. The build refuses a catalog that breaks a rule (ZTS513).

```ts
import { toolCatalog, toolInput } from "zttp:tool";

toolCatalog({
  convert: {
    route: "POST /tools/convert",
    description: "Convert a temperature between Celsius, Fahrenheit, and Kelvin.",
    input: "ConvertInput",
    output: "ConvertOutput",
    maxInputBytes: 128
  }
});
```

**The input.** Before the handler runs, the runtime refuses an input that is
larger than `maxInputBytes` (413) or that the input schema refuses (400). The
tool reads the validated input with `toolInput(name, req)`, which returns a
`Result` whose value type comes from the schema. It answers `ok` only on a tool
request that the runtime validated against exactly that schema, and the build
refuses a `toolInput` that names another schema than the route's own input.
`zttp:validate` cannot compile a closed catalog schema, so do not read a tool
input with `validateJson`; the build refuses that call (ZTS514).

```ts
function convert(req: Request): Response {
  const parsed = toolInput("ConvertInput", req);
  if (!parsed.ok) {
    return Response.json({ error: "invalid input" }, { status: 400 });
  }
  const input = parsed.value;
  return Response.json({ value: fromCelsius(toCelsius(input.value, input.from), input.to), unit: input.to });
}
```

**The output.** The runtime validates every 2xx answer of a tool against the
output schema and answers 500 `tool output refused` when the schema refuses it.
Non-2xx answers pass unchanged.

**The caller.** A tool request carries a bearer token, an HS256 JWT. zttp.json
names the environment variable that holds the key and the claim that holds the
tenant:

```json
"auth": { "keyEnv": "TOOLS_JWT_KEY", "tenantClaim": "tenant" }
```

A request with no token, a bad signature, an unexpected `alg`, an expired
token, or no `sub` or tenant claim gets 401 before the handler runs. The handler receives
`req.subject` and `req.tenant` from the verified claims, and the request it sees
has no `authorization` header. A catalog `scope` binds an input field to the
verified identity, and a request whose field differs gets 403:

```ts
scope: { tenant: "tenant_id" }
```

**The grant and the ceiling.** Each tool may call only the module exports its
own route reaches, which the build lists into the catalog. A tool may not read
state that a separate call wrote (`zttp:cache` reads, `zttp:sql`, `zttp:queue`
receive, a durable signal wait). A declaration file can also set a capability
ceiling that the whole handler must stay inside; `examples/tools` uses the
`adapter` profile and excludes `zttp:crypto`. The catalog and the declaration
are bound into the built artifact, and an artifact whose bound sections change
refuses to start.

**Credentials.** A tool can call an upstream with a credential that its code
never sees. zttp.json names each credential and the requests it may go into,
and the tool names it with a string literal in the `fetch` options. See
[Outbound credentials](contracts-and-sandboxing.md#outbound-credentials) for the
reference format, the checks the runtime makes before it adds the header, and
the refusals.

**Build and run.** `zttp build` emits a self-contained binary. It refuses to
start when the key variable or a credential variable is unset or empty. A tool
that calls an upstream also needs an egress policy that names the endpoint and
an address scope, and the operator allows outbound requests with
`--outbound-http` or `--outbound-host`.
`zig build test-reference-tools` builds `examples/tools`, runs the binary, and
checks the positive path and each boundary case with real requests.

### Agent turns

An admitted agent request has a turn deadline and a round budget. Each provider
fetch attempt consumes one round after the recorder accepts its pre-record.
The runtime also checks `providerRequestBytes` before that record. It never
retries a provider fetch automatically.

A refused fetch returns status 599, `error: "AgentTurnRefused"`, and one stable
`details` tag: `deadline_exceeded`, `budget_exhausted`,
`recorder_unavailable`, `outcome_unknown`, `tool_denied`, or `tool_failed`.
The last two tags are reserved for tool dispatch. The first refusal closes the
turn. Later provider fetches return that same tag without a new connection.
A failure after the request write starts is `outcome_unknown` unless the full
response is usable. A complete non-2xx response leaves the turn open.

For agent handlers, `zttp serve` and self-contained binaries require
`--agent-turn-recorder-dir <DIR>`, `--agent-turn-recorder-max-bytes <SIZE>`, and
`--max-agent-turns <COUNT>`. The cap must be positive and less than the pool size
minus one. A full cap returns 503. The recorder writes metadata only, reserves
space for each terminal record, and flushes each record before it returns.
After a write or flush failure, `/_readiness` returns 503 and names the recorder.
Restart the process after recorder failure or when its byte ceiling is reached.

An agent handler can call `callTool(callId, name, argsJson)` from `zttp:tool`.
`name` must be in that agent entry's `tools` list. The call runs the tool's
route in the same runtime under that tool's grant. The tool receives a new
request with the verified subject and tenant and `argsJson` as its body. The
request has no client headers, query, or agent prompt. `toolInput` reads the
validated arguments from that body.

Each admitted call spends one tool call from the turn and round budgets before
the runtime resolves `name`. Invalid arguments and unknown names also spend a
call. A repeated `callId` in one round is refused. The runtime records the
call before it runs the tool and records its outcome after it returns. A tool
that does not return, including one interrupted by the turn deadline, gives
`outcome_unknown`. A non-2xx response or a response that fails the tool's
output schema gives `tool_failed`. The error arm contains only a tag:
`unknown_tool`, `invalid_arguments`, `tool_denied`, `tool_failed`,
`budget_exhausted`, `deadline_exceeded`, or `outcome_unknown`.

The verifier labels a successful `callTool` value with the labels of
`argsJson` and the union of the return labels of every tool that the agent
entry lists. `callId` and `name` do not label that value. If it cannot resolve
a listed tool route, it does not prove the affected flow properties.

Use `sseEvents(body, bounds)` from `zttp:sse` to frame a buffered event stream
from a provider. Set positive `maxBodyBytes`, `maxBlockBytes`, and `maxEvents`
bounds. The success arm contains an array of `{ event, data, id }` records.
The error arm contains a `tag` and byte `offset`, including
`unterminated_event` when the body ends inside an event block. Check `ok`
before reading the events. The framer does not retry or read from a socket.

`zttp dev` uses unmeasured development values: `<project>/.zttp/turns`, 16 MiB,
and one concurrent turn. Its default pool has at least three slots; an explicit
smaller pool is refused for an agent handler. These values do not apply to
serve or deployed binaries. Replay uses an in-memory recorder and needs no
recorder settings. Agent traces without transport phase metadata replay as
`outcome_unknown`.

## Application Invariants

An application invariant states what must remain true after a committed state
change. Two templates are supported. `balance_conservation_v1`: for each
declared currency in one ledger, all signed account balances sum to zero. Every
specification must declare it. `declared_accounts_v1`: every entry account in
every committed posting group matches at least one rule you declare, each rule
either an exact account or a non-empty prefix. It is optional. Neither proves
correct recipients, authorization, sufficient funds, or correct business
amounts.

Add both paths to `zttp.json`. Paths are relative to that file:

```json
{
  "entry": "src/handler.ts",
  "invariants": "invariant.json",
  "ledger": "ledger.sqlite"
}
```

Review and save the structured claim in `invariant.json`:

```json
{
  "version": 1,
  "kind": "balance_conservation_v1",
  "statement": "The sum of all balances in this ledger is zero",
  "ledger": "main",
  "currencies": [{ "code": "USD", "scale": 2 }]
}
```

The structured fields define the claim. `statement` is a human annotation.
Currency codes must contain three uppercase ASCII letters. Scale is between
0 and 18. Scale 2 means that `"100"` represents one major unit. Currencies are
checked separately. There is no conversion between currencies.

To declare more than balance conservation, use `"version": 2`, which lists the
templates in `kinds` and lets each carry its own fields:

```json
{
  "version": 2,
  "ledger": "main",
  "currencies": [{ "code": "USD", "scale": 2 }],
  "kinds": [
    { "kind": "balance_conservation_v1" },
    { "kind": "declared_accounts_v1",
      "accounts": [{ "exact": "clearing:main" }, { "prefix": "asset:" }] }
  ]
}
```

Account matching is case-sensitive over bytes, with no wildcard, no regular
expression and no normalization: the prefix `asset:` admits `asset:cash` and
`asset:` itself, and refuses `assets:cash`. A posting naming an undeclared
account is refused whole, with the tag `undeclared_account`, before anything is
written, and a zero-amount entry or a pair that cancels on one account is
checked like any other. An existing store that already holds an undeclared
account does not open.

Use the protected module for every posting:

```ts
import { post } from "zttp:ledger";

export function handler(req: Request): Proof<Response, "state_isolated"> {
    const result = post({
        ledger: "main",
        currency: "USD",
        idempotencyKey: req.url,
        entries: [
            { account: "cash", amount: "100" },
            { account: "clearing", amount: "-100" }
        ]
    });
    if (!result.ok) {
        return Response.text("posting refused", { status: 400 });
    }
    return Response.text(result.value.replayed ? "replayed" : "posted");
}
```

This example uses the URL as the retry key. A real application must select a
stable key for each business operation. A retry with the same key and ordered
entries returns `{ replayed: true }`. Reuse with different entries returns an
`idempotency_conflict` error. The key is scoped to the ledger and currency.

`balance(ledger, currency, account)` returns `Result<string>`. An account with
no postings has balance `"0"`. Amounts and returned balances are canonical
signed decimal integer strings in the signed 64-bit range. Numbers, leading
zeros, `+1`, `-0`, fractions, and exponent notation are refused. Group totals use
checked signed 128-bit arithmetic. Each account balance must remain in the
signed 64-bit range. An unbalanced or overflowing posting leaves no committed
entries, balance changes, or retry record.

Expected failures are Results with an `error.tag`, such as `unbalanced`,
`balance_overflow`, `idempotency_conflict`, or `storage_busy`. A busy transaction
can be retried with the same key. Balance results carry a secret label. Both
exports preserve argument labels. A handler that declares `no_secret_leakage`
cannot expose a labelled result through its response.

Build the project, then select the protected store on the target host:

```bash
zttp build
./.zttp/build/my-app --ledger /srv/my-app/ledger.sqlite
```

The artifact carries the exact specification. Startup checks its certificate
and operation coverage, then validates the stored schema, configuration,
posting groups, and materialized balances under a write lock. Only then can
the runtime serve requests. A new empty store starts with zero balances.
An unreadable or invalid existing store is refused. A changed specification
cannot reopen the old store. Automatic migration is not supported.

Adding a kind is a changed specification. A selection beyond balance
conservation is written under invariant wire schema 2, which hashes under its
own domain, so it never matches the digest a store recorded under balance
conservation alone. Declare `declared_accounts_v1` against a fresh store. A
specification that names balance conservation alone is unaffected: it encodes
the bytes it always did and reopens the store it has been using.

Upgrading zttp can change the adapter manifest by itself, without any edit to
your specification. An artifact built by an older zttp is then refused at
startup at artifact binding, because the serving binary recomputes the adapter
member and the executable graph no longer matches, and must be rebuilt with the
new zttp. The store is unaffected, because `ledger_meta.invariant_digest` binds
the specification digest and not the adapter digest.

`zttp proofs verify` prints one invariant status line for an accepted
artifact, and startup prints the same line, from the same renderer, once a
configured invariant is installed. It reads write applicability first, then
the declared kinds by name, then coverage over protected call sites with its
write and read split, then that native enforcement is a trusted assumption,
then the ledger baseline. `covered` write applicability means a covered call
site can modify ledger state; `vacuous` means none can, which reports an
absence rather than a failure. Baseline reads `not checked` in a bundle
report, because that report opens no store, and reports validation only from
an instance that opened one. Every
line ends by saying that keeping other writers off the store is a deployment
assumption the checker does not verify. None of it says a predicate was
proven, because acceptance never examines one.

This release requires a built artifact for an invariant project. Source
`serve`, `dev`, and certificate-free live replacement are refused. Rebuild and
restart after a change. Analyzer success alone does not establish invariant
coverage or store readiness. Only direct calls through a ledger import are supported. Local aliases and
indirect ledger calls are refused when the artifact is built. Invariant
artifacts also refuse `--system`: separately loaded handlers do not carry the
main artifact's invariant coverage.

General SQLite and SDK file access cannot open the protected database or its
journal files. Startup also rejects log paths that share those files and a
ledger inside the durable output directory. Create the parent directories for
configured storage and log paths before startup.
The host must prevent external writers, filesystem aliases that bypass these
path checks (including hard links), and
filesystem replacement while the application runs. The guarantee depends on
the native ledger adapter, SQLite transactions, and this deployment isolation.
It is separate from a static handler property and from resource-policy guards.
See [Verification](verification.md#application-invariants) for the checked evidence.

To see which invariant kinds exist and draft a candidate:

```bash
zttp invariant list
zttp invariant author --kind balance_conservation_v1 --ledger main --currency USD:2
zttp invariant author --kind balance_conservation_v1 --kind declared_accounts_v1 \
  --ledger main --currency USD:2 \
  --account-exact clearing:main --account-prefix asset:
```

`--kind` is required and repeatable, and the selection must name
`balance_conservation_v1`. A plain-language sentence names no predicate, so
there is no path from a sentence alone to a candidate. Pass the sentence with
`--statement` to record it beside the candidate as an annotation. Repeat
`--account-exact` and `--account-prefix` to fill the declared account set;
either flag needs `--kind declared_accounts_v1`, and that kind needs at least
one of them. Review the result and save only its `candidate` object as the
configured invariant JSON.

Add `--advise` to send only the sentence, and the catalog's published
descriptions, to TypeSafe Jev for advisory template selection. This requires
`--statement` and `TYPESAFE_API_KEY`. A missing, malformed, or disagreeing
answer produces no candidate. Jev confidence is not proof. Builds, certificate
checks, and posting acceptance never call a model. Live Jev classification
quality and latency need to be measured for your statements.

## TypeScript Source Profile

zts supports a practical server-side TypeScript subset and rejects constructs that
weaken analysis. Commonly rejected constructs include `var`, `while`, `class`,
`try/catch`, implicit globals, and unsupported module forms.

Handler files use `.ts`. A handler containing JSX uses `.tsx` and enters the
versioned TSX frontend. `.js`, `.jsx`, and unknown file extensions are refused
with ZTS052 so source identity always selects one explicit frontend. Inline
`-e` snippets remain virtual source and do not claim a file extension.

Use:

- `const` by default, `let` only when reassigned.
- `for...of` loops.
- `if`/`else` and `match` for branching.
- Explicit Result and optional checks.
- Ambient `Proof<T, P>` and `Effects<T, R>` annotations with no import.

### Match Patterns

A `match` arm takes a literal, a record pattern, an array pattern, or a type
test. The six type tests are `boolean`, `number`, `string`, `array`, `Dict`,
and `Bytes`.

A record pattern field is one of three things: a discriminant test, a binding
of the field under its own name, or a binding under a new name. A binding is an
arm-scoped `const` that carries the field's narrowed type, so an arm reads the
field by naming it in the pattern rather than off the scrutinee.

```ts
structural Command =
    | { kind: "echo"; text: string }
    | { kind: "ping" };

function run(command: Command): string {
    return match (command) {
        when { kind: "echo", text }: text
        when { kind: "ping" }: "pong"
    };
}
```

A union covered member by member is exhaustive and needs no `default`; an open
domain such as `string` or `number` needs one. Exactly one arm's expression is
evaluated, and an arm expression may be effectful.

### `null`

`null` is data, not an absence sentinel. It is admitted only where the declared
type names it, so `const x: string | null = null;` is accepted and
`const x: string | undefined = null;` is not. `undefined` remains the absence
sentinel and the representation of an omitted optional field.

Because `??` and `?.` test both values alike, they are refused (ZTS624) on an
operand whose static type admits `null`, and on a generic parameter or
`unknown`, where a later instantiation could admit it. Compare explicitly with
`=== null` or `=== undefined`, or take the value apart with `match`. On a
concrete type without `null` both operators keep their single meaning and stay
the idiomatic spelling of it.

A recursive type alias must be contractive: every cycle passes through a
record, tuple, or array constructor. `structural JsonValue = null | boolean |
number | string | readonly JsonValue[]` is admitted; `structural Loop = Loop`
and `structural U = number | U` are refused (ZTS212), because a union edge does
not guard recursion.

### Author-Declared Proofs

```ts
structural Safe<T> = Proof<T, "deterministic" | "state_isolated">;

function handler(req: Request): Safe<Response> {
    return Response.json({ ok: true });
}
```

References:

- [TypeScript](typescript.md)
- [Feature Detection](feature-detection.md)
- [Restrictions to Proofs](restrictions-to-proofs.md)
- [Canonicalize And Normalize](cli.md#canonicalize-and-normalize)
- [Sound Mode](sound-mode.md)

## JSX And TSX

TSX handlers can render server-side HTML without a build step.

```tsx
function Page(props) {
    return (
        <html>
            <body><h1>{props.title}</h1></body>
        </html>
    );
}

function handler(req: Request): Response {
    return Response.html(renderToString(<Page title="Hello" />));
}
```

Use the `htmx` template for an HTML-first scaffold:

```bash
zttp init htmx-app --template htmx
cd htmx-app
zttp dev
```

See `examples/jsx/` and `examples/handler/handler-full.tsx`.

## Hypermedia Resources

`resource(data, affordances)` is a global that returns one value the runtime
renders two ways, chosen by the request's `Accept` header. Services that ask for
`application/hal+json` (or `application/json`) receive a HAL document; browsers
that ask for `text/html` receive HTML. This is the v1 beta hypermedia primitive:
one affordance declaration drives both HAL for services and HTMX controls for
users.

```ts
function handler(req: Request): Response {
    const order = { id: 42, total: 1999, status: "pending" };
    return resource(order, {
        self: { href: "/orders/42" },
        pay: { href: "/orders/42/pay", method: "POST", title: "Pay now",
               target: "#order", swap: "outerHTML" },
        cancel: { href: "/orders/42", method: "DELETE", title: "Cancel" },
    });
}
```

Each affordance is keyed by its link relation. `href` is required; `method`,
`title`, `target`, `swap`, and `fields` are optional. An affordance with no
`method` (or `GET`/`HEAD`) is a navigation link; any other method is a write
action.

The rendering follows from the affordance shape:

| Accept | Output |
|---|---|
| `application/hal+json` or `application/json` | HAL: data plus `_links` (navigation) and `_templates` (write actions, with `fields` as `properties`). |
| `text/html` with `HX-Request: true` | An HTMX fragment: a `<dl>` of the scalar data, then `<a>` links and `<button hx-post>`/`hx-delete` controls carrying `hx-target`/`hx-swap`. |
| `text/html` without `HX-Request` | The same fragment wrapped in a full page that loads htmx. |

```bash
zttp serve examples/hypermedia/order.ts -p 3000
curl -H 'Accept: application/hal+json' http://127.0.0.1:3000/orders/42
curl -H 'Accept: text/html' -H 'HX-Request: true' http://127.0.0.1:3000/orders/42
```

See `examples/hypermedia/order.ts`. For an interactive walkthrough of HATEOAS
and HAL with this resource (a live order workflow whose affordances change with
state), open [hypermedia-explainer.html](hypermedia-explainer.html) in a browser.

## Workflow Orchestration

`zttp:workflow` dispatches from a top-level orchestrator to co-located
handlers loaded from `--system <file>`. The system manifest is strict for
workflow use: every local handler `path` must be readable at startup, and
relative paths use the same rule as the proof tools: a path that exists from the
current working directory is used as-is, otherwise it is resolved from the
manifest directory.

```ts
import { call, fanout, follow, saga } from "zttp:workflow";
```

`call(name, init?)` dispatches by handler name. `follow(resource, rel, init?)`
resolves a `resource()` affordance by relation and dispatches by the proven
bundle route. `fanout(calls)` aggregates multiple co-located calls in declaration
order. `saga(steps)` runs durable do/compensate steps.

Inside `run()` from `zttp:durable`, workflow dispatches snapshot plain
`{status, headers, body}` records into the oplog and rebuild real `Response`
objects during replay, so completed child calls are not re-dispatched. Existing
oplogs use the internal `workflow.parallel#N` key for `fanout()` records for
compatibility.

Queue-mediated workflow dispatch is opt-in with `--workflow-queue` and requires
both `--durable <dir>` and `--system <file>`. In that mode, durable top-level
`call`, `follow`, and `fanout` write child requests to `<durable>/workflow-queue`
before dispatch, lease queued items while they run, and write completed response
parts under `done/` before the parent durable step result is persisted. If the
process stops before the parent step completes, durable recovery re-enters the
run and resumes from the queue result or retries the leased item after its lease
expires. Child handlers should be idempotent because a process crash after a
child side effect but before its queue result is written can re-run that child.
`saga()` is not supported with `--workflow-queue`; keep queue-mediated handler
communication at top-level durable `call`, `follow`, or `fanout` boundaries.

The analyzer records durable workflow proof properties separately from the
handler-wide property chips. Receipts, deploy manifests, and proof traces expose
`durableWorkflowProofLevel`, `durableWorkflowRetrySafe`,
`durableWorkflowIdempotent`, `durableWorkflowFaultCovered`, and
`proofTrace.durable_workflow_*` so replay guarantees are visible in the same
artifacts you already inspect. See [Durable Workflows](durable-workflows.md) and
[First Durable Workflow](tutorials/first-durable-workflow.md).

## Actor Queues

`zttp:queue` provides opt-in in-process actor mailboxes for handlers that need
to exchange work without sharing JS runtime state. Enable the server-owned
in-memory queue with `--actor-queue`.

```ts
import { send, request, receive, ack, nack, reply } from "zttp:queue";

function handler(req) {
  const sent = send("worker", { kind: "resize", image: "hero.jpg" });
  if (!sent.ok) return Response.json({ error: sent.error }, { status: 503 });

  const inbox = receive("worker");
  if (!inbox.ok) return Response.json({ error: inbox.error }, { status: 503 });
  if (inbox.value === undefined) return Response.json({ queued: sent.value });

  const msg = inbox.value;
  const done = ack(msg.id);
  return Response.json({ id: msg.id, payload: msg.payload, acked: done.ok });
}
```

`send(target, payload)` stores a JSON snapshot of `payload` and returns
`Result<string>` with the message id. `request(target, payload)` also sets the
current actor as the reply target. `receive(actor?)` leases one message and
returns a `Result` whose `.value` is `undefined` when no message is available;
the default actor is `main`. A leased message
stays retained until `ack(id)` deletes it or `nack(id, reason?)` requeues it.
After the configured attempt limit, `nack()` moves the message to the in-memory
dead-letter set and releases the actor mailbox slot; dead letters are retained
outside mailbox capacity. `reply(id, payload)` sends a high-priority response to
the original message's reply actor and sets `correlationId`.

The current backend is process-local memory. It survives handler VM reset,
timeout invalidation, and panic quarantine because payloads are owned by the
queue, not the JS heap. It does not survive process restart; use
`--workflow-queue` for the existing durable workflow child-dispatch queue.

## Virtual Modules

Virtual modules are native Zig APIs exposed through `import { ... } from
"zttp:*"`. The current module list and runtime requirements are in
[Virtual Modules](virtual-modules/README.md).

Common runtime flags:

| Need | Flag |
|---|---|
| SQLite queries | `--sqlite <file>` |
| Outbound HTTP | `--outbound-http` or `--outbound-host <host>` |
| Durable workflows | `--durable <dir>` |
| Service registry and in-process workflow bundle | `--system <file>` |
| Queue-mediated durable workflow dispatch | `--workflow-queue` |
| In-memory actor mailboxes | `--actor-queue` |
| Skip env startup check in development | `--no-env-check` |

## Compile-Time Proofs

`zttp dev`, `zttp test`, `zttp check`, and build-time precompile paths run
the analyzer. It checks:

- every path returns a `Response`;
- Result and optional values are checked before access;
- unreachable code and unused values are reported;
- module-scope mutations that can leak request state are rejected;
- declared `Proof<T, P>` obligations are discharged;
- virtual-module imports derive a least-privilege runtime policy;
- a capability policy named by the `policy` entry in `zttp.json` is enforced
  against the handler, and a policy that cannot be read stops the command
  instead of producing an unrestricted verdict;
- computed environment keys, egress endpoints, and cache namespaces are
  admitted only when that policy declares the matching section. They become
  residual guards, not proven Properties. Computed SQL names remain rejected
  because the policy cannot distinguish reads from writes;
- flow checks catch secret, credential, validation, injection, and PII issues
  where enough structure is visible.

The proof card shows the current verdict and the property chips. See
[Proofs and Receipts](proofs-and-receipts.md#reading-the-proof-card),
[Verification](verification.md), and
[Contracts and Auto-Sandboxing](contracts-and-sandboxing.md).

## Tests And Replay

Declarative tests are JSONL files. A scaffolded project writes a starter file
under `tests/`.

```bash
zttp test
zttp serve --test tests/handler.test.jsonl src/handler.ts
zig build -Dhandler=src/handler.ts -Dtest-file=tests/handler.test.jsonl
```

Ordinary fixtures use `test`, `request`, optional `io`, and `expect` rows. A
durable workflow fixture can opt into one shared scenario backend by making a
`runtime` row the first row:

```jsonl
{"type":"runtime","durable":true,"workflowQueue":false}
{"type":"test","name":"the order completes"}
{"type":"request","method":"POST","url":"/","headers":{"idempotency-key":"order-1"},"body":null}
{"type":"expect","status":201}
{"type":"expect-run","runKey":"order-1","complete":true}
{"type":"expect-event","runKey":"order-1","kind":"step_start","name":"reserve"}
{"type":"expect-event","runKey":"order-1","kind":"step_result","name":"reserve","resultContains":"reserved"}
{"type":"expect-signals","count":0}
```

Scenario tests share a private durable store but create a fresh handler and
replay state for every request. Assertion rows are strict: every run needs at
least one ordered event, queue mode needs `expect-queue` evidence and a system
manifest, and malformed, duplicate, extra, or unconsumed evidence fails the
fixture. Supported event kinds are `step_start`, `step_result`, `wait_signal`,
and `resume_signal`.

Record and replay handler I/O:

```bash
zttp serve --trace traces.jsonl src/handler.ts
zttp serve --replay traces.jsonl src/handler.ts
zig build -Dhandler=src/handler.ts -Dreplay=traces.jsonl
```

Persisted counterexamples live in the witness corpus and can be inspected with
`zttp witnesses`. See [Witness Corpus](proofs-and-receipts.md#witness-corpus).

## Deploy And Verify

```bash
zttp deploy
./.zttp/deploy/my-app -p 8080
zttp verify http://127.0.0.1:8080
```

The running server emits `Zttp-Proofs` and `Zttp-Attest` headers and serves
`/.well-known/zttp-attest`. `zttp verify <url>` validates the signed
attestation from another machine. Use `zttp proofs` to inspect local ledger
entries and `zttp proofs gate` for pull-request checks.

A deployed artifact carries a proof certificate, and the server checks it with
an independent kernel before it accepts a request. If the certificate is
missing, does not describe the bytes that were loaded, or does not meet the
production policy, the process refuses to serve and says at which stage and for
what reason. That check happens before any runtime is warmed, so a refused
artifact never has a handler ready.

Production artifacts use certificate schema `4`, proof system
`zttp_pcc_v3 = 3`, self-extract format `6`, attestation
`zttp-attest-v4`, and bundle format `zttp-bundle-3`. Immediate predecessor
formats are refused with a rebuild instruction. A guarded artifact must also
have exact residual-plan and runtime-policy coverage before startup. Guarded
installed generations cannot use the certificate-free live-swap path.

Two commands answer two different questions:

```bash
# Provenance: who signed a claim about this deployment.
zttp verify http://127.0.0.1:8080

# Proof: does this exact artifact satisfy the required properties.
zttp proofs bundle --contract .zttp/deploy/handler.contract.json \
  --binary .zttp/deploy/my-app --out bundle
zttp proofs verify bundle --require-proof
```

`zttp verify` reads a signed claim from a live endpoint. The endpoint returns
the claim, not the artifact, so that command reports provenance only. Proof and
policy acceptance are established against the artifact itself, which is what
`zttp proofs verify` does. Integrity and proof are printed as separate lines
because they are separate answers: matching hashes say the bundle holds the
bytes the manifest names, and nothing more.

Proof acceptance is also what unlocks the proof response cache, unbounded
runtime reuse, and the durable-workflow guarantees. A dev server has no
artifact and no certificate, so it runs without them; that is deliberate, not a
gap. See [docs/verification.md](verification.md) for what each assurance grade
means and for the list of edges the consumer discloses rather than checks.

## Expert Mode

`zttp expert` is the compiler-in-the-loop coding agent. It proposes edits and
routes every one through the same compiler checks before they land. DeepSeek is
the current default. The developer-managed local MLX-LM provider, Claude, and
OpenAI are available through explicit `--provider` selection.

### What a turn sends

Expert mode is a coding agent, so it reads your code to work on it. Nothing is
sent when the session starts: the first request carries your prompt, the agent
persona, and the tool schemas.

Source crosses the wire when the model calls a tool that returns it. Three do:
`workspace_read_file` returns a file's contents, `workspace_search_text` returns
matching lines, and `propose_change_set` carries the complete source candidates
the model just wrote. The compiler's
veto verdict comes back as a tool result and can quote diagnostics with source
spans.

`workspace_search_text` treats its query as literal text. It searches one named
file when ripgrep is unavailable or its output limit is reached. It refuses a
recursive fallback because that path cannot apply ripgrep's ignore rules.

Each result is appended to the raw session journal. The provider sees a bounded
active projection: file reads are UTF-8-safe pages with an explicit range and
completeness flag, searches and file lists carry deterministic continuation
metadata, and process output is a bounded head/tail digest with omitted-byte
counts. Raw tool output remains available to the host and journal. It is never
cut into an ambiguous partial value before entering model context.

Every request is measured before transport, including the system prompt, tool
schemas, active history, transient retry text, provider framing, response
reserve, and exact wire bytes. The default soft input target is 40,000 tokens.
The hard limit is the active model's context window minus the configured
reserve. Output tokens are clamped to the capacity left after input.

Files the model never asks for are never sent. There is no repository scan and
no upfront upload, and the examples baked into the persona are this repository's
own, not yours.

The interactive banner states the resolved destination before your first turn.
To keep requests on the machine, start MLX-LM separately and select local:

```bash
mlx_lm.server --model LiquidAI/LFM2.5-2.6B-MLX-8bit --host 127.0.0.1 --port 8080
zttp expert --provider local
```

`ZTTP_MLX_BASE_URL` defaults to `http://127.0.0.1:8080`. It accepts only a
credential-free HTTP loopback root: `localhost`, `127.0.0.1`, or `::1`, with no
path, query, or fragment. Zttp checks `/health` and `/v1/models` before creating
a session, but it never starts, stops, or replaces the server. It does not retry
through another provider after a local failure.

The local adapter was tested with MLX-LM 0.31.3 and model revision
`b372ebbb518c0e81617e25d8824427dd9ee1f08c`. The model has a 131,072-token
context window; zttp requests at most 8,192 output tokens and otherwise uses the
model-shipped generation defaults.

### Qualifying an expert model

Model qualification is a repository maintenance operation, not a runtime
setting. Run it only after the compiler, persona, protocol, and static tool
catalog are frozen. `scripts/qualify-expert.sh` performs three complete live
19-case runs, retains failures in the denominator, and emits a report that
binds the exact model, runtime, request limits, source revision, prompt,
provider serialization, compiler identities, and evaluation cohorts.

The quality bar is 19/19 final green, 18/18 runtime intents, at least 14/19 raw
first-draft passes, median round trips no higher than four, and no empty,
timeout, decode, provider, or internal failures in each run. A local run also
requires model artifact, quantization, chat-template, serving-argument,
hardware, OS, and peak-memory evidence. See
[Recording the codegen cassettes](internals/cassette-recording.md) for the exact
command and environment.

Qualification is report-only. It neither promotes cassettes nor changes the
LFM local-provider default or the DeepSeek product default. A passing candidate
report is input to a separate product decision.

### How a turn runs

1. You state a goal in plain English.
2. The agent gathers compiler facts through the strict `zts_expert_query`
   operation union and uses separate proof tools where a verdict is required.
3. It authors complete source for one or more files and submits one ordered
   `propose_change_set` proposal.
4. Before any write, the host normalizes the whole source overlay, proves it
   once, and records every proof input in a read set. A draft that introduces a
   violation is rejected and the agent retries.
5. On a pass you see every normalized diff plus one aggregate proof card and
   approve or reject once. `--yes` approves every verified change set;
   `--no-edit` blocks writes entirely.
6. The host rechecks the full read set and commits under a workspace lock and
   crash-recovery journal. The agent never writes source files itself.

The static model prefix contains 21 tools. The six schema-v2 discovery views
and four focused compiler projections share the `zts_expert_query` ADT;
normalization, proof, repair, and change-set application remain distinct
authorities. Exact provider serialization is pinned in tests: 11,502 bytes for
OpenAI, 11,203 for Anthropic, and 11,775 for the DeepSeek/local chat shape.
The pre-cutover prefixes were 19,722, 19,199, and 20,177 bytes respectively,
so every supported provider stays beyond the 40% reduction gate.

### Context compaction

When a normal request crosses the soft target, expert mode summarizes safe
older turns before making that request. It prefers whole user turns, never cuts
between a tool call and its result, and preserves an oversized or unresolved
current turn exactly. If protected input cannot fit the model's hard limit, the
request fails before network I/O.

The summary call uses the active provider and model in isolation: one user
message, a fixed summary prompt, no tools, no normal transcript, bounded output,
and no prompt-cache write. The returned Markdown must contain Goal,
Constraints & Preferences, Progress with Done/In Progress/Blocked, Key
Decisions, Next Steps, and Critical Context. The host derives read and modified
file blocks from typed tool calls rather than trusting model-authored file facts.

Raw session entries remain append-only for proof reconstruction and ledger
export. A successful summary is stored as a checksummed v4 compaction
checkpoint, then installed as the provider-visible projection. Resume and fork
preserve both the raw ancestry and the active projection. A provider
`PromptTooLong` response can compact and retry that exact pending model call
once; the turn is not restarted and effects are not repeated.

Run `/compact` manually, or add an optional focus that cannot replace the fixed
summary contract:

```text
/compact
/compact retain the deployment decision and pending verification commands
```

Compaction settings use built-in defaults, then
`$HOME/.zttp/settings.json`, then `<cwd>/.zttp/settings.json`:

```json
{
  "compaction": {
    "enabled": true,
    "maxInputTokens": 40000,
    "reserveTokens": 16384,
    "keepRecentTokens": 20000
  }
}
```

Disabling automatic compaction leaves manual `/compact` available and keeps
hard request admission enabled. Unknown keys, invalid values, and malformed
JSON reject the named file. Settings files cannot contain provider credentials.

```bash
zttp expert                                      # current DeepSeek default
zttp expert --provider local                     # local LFM
zttp expert --provider openai                    # explicit OpenAI
zttp expert --provider deepseek                  # explicit DeepSeek
zttp expert --yes                                # apply edits without prompting
zttp expert --no-edit                            # read-only analysis, no writes
zttp expert --resume                             # continue last session
zttp expert --provider claude --model claude-sonnet-4-6
zttp expert --print "add a GET /health route"
zttp expert --handler src/handler.ts --goal no_secret_leakage
```

Provider resolution is explicit launch flags, then stored resume or fork
identity, then the current DeepSeek default. Cloud keys never select a provider. A new
session stores its provider and model; resume restores both, fork inherits both,
and `/new` keeps the process provider and current model. An explicit launch
override is disclosed and persisted. To resume a session from another provider,
restart with `--provider` and optional `--model`.

Sessions also bind the stable expert persona, schema-v2 compiler registries,
and the exact ordered model tool catalog. If any of those authorities changes,
resume and fork refuse the stale session and leave its files untouched. Start a
new session instead; old model reasoning is never silently restamped under the
new protocol.

`--model <id>` selects only within the active provider. It never infers or
changes the provider. `/model` and RPC `model.set` follow the same rule and
persist the choice atomically. Claude defaults to `claude-sonnet-4-6`; OpenAI
defaults to `gpt-4o-mini`; DeepSeek defaults to `deepseek-v4-flash`. The
compiler-only `--goal` workflow rejects `--provider` and `--model` and does not
check model readiness.

Pass `--yes` to apply every verified edit without a confirmation prompt; the
approval policy is persisted through `--resume`.
Pass `--no-edit` to allow analysis and file reads while blocking all writes.

`--print` runs one non-interactive turn and encodes the outcome in its exit
code, so a CI job can branch on `$?` without parsing output: `0` an edit was
applied or a clean text answer was returned, `1` a hard error, `2` the compiler
veto was not satisfied within the attempt budget, `3` a turn budget was
exhausted (round-trips, tool calls, or the wall-clock limit), `4` an edit was
verified but the approval prompt rejected it.

`zttp auth claude`, `zttp auth openai`, and `zttp auth deepseek` store cloud keys
in `~/.zttp/providers.json` with mode `0600`. A shell-set `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, or `DEEPSEEK_API_KEY` overrides the stored value, and the key
is validated only after its cloud provider is resolved. `DEEPSEEK_BASE_URL`
points DeepSeek at another HTTPS root; plain HTTP is refused.

When your request is ambiguous - the right edit depends on a choice you have not
made - the agent asks one clarifying question instead of guessing. Answer it on
the next line and it proceeds with your choice. Type `/ledger` at any point to
see the session metrics: turns, model round-trips, verified edits, round-trips
to the first proven edit, and the share of proof guarantees the final handler
discharges.

## Troubleshooting

**The server says no handler was provided.**

Run inside a project with `zttp.json`, pass a handler path, or use `-e`:

```bash
zttp serve src/handler.ts
zttp serve -e "function handler(req) { return Response.text('ok') }"
```

**An env var check fails at startup.**

Set the required variable, remove the literal `env("NAME")` use, or pass
`--no-env-check` for local development.

**A Result or optional access fails verification.**

Check `.ok` before `.value`, or narrow the optional before use:

```ts
const token = parseBearer(req.headers.authorization ?? "");
if (token === undefined) return Response.text("Unauthorized", { status: 401 });
```

**A language feature is rejected.**

Run `zttp restrictions` or see [Restrictions to Proofs](restrictions-to-proofs.md)
for the reason and supported replacement.

**A request returns 500.**

The process stays up. Read the response body first: a type fault or a
non-Response return names the proof chip that guards it and, when the
interpreter resolved one, the faulting `line:column`. If no chip is named, check
stderr, memory limits, stack depth, and any virtual-module runtime requirements.
See [Reliability](reliability.md#proof-explained-500s).

**A port is already in use.**

Choose another port:

```bash
zttp dev -p 3001
zttp serve -p 8081 src/handler.ts
```

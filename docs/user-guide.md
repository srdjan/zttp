# User Guide

zttp runs JavaScript, TypeScript, and TSX HTTP handlers from a single Zig
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

## JavaScript And TypeScript

zts supports a practical server-side JS/TS subset and rejects constructs that
weaken analysis. Commonly rejected constructs include `var`, `while`, `class`,
`try/catch`, implicit globals, and unsupported module forms.

Use:

- `const` by default, `let` only when reassigned.
- `for...of` loops.
- `if`/`else` and `match` for branching.
- Explicit Result and optional checks.
- Type-only imports from `zttp:types` for proof annotations.

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
record, tuple, or array constructor. `type JsonValue = null | boolean | number
| string | readonly JsonValue[]` is admitted; `type Loop = Loop` and
`type U = number | U` are refused (ZTS212), because a union edge does not guard
recursion.

### Author-Declared Specs

```ts
import type { Spec } from "zttp:types";

structural Safe = Spec<"deterministic" | "state_isolated">;

function handler(req: Request): Response & Safe {
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
- declared `Spec<...>` obligations are discharged;
- virtual-module imports derive a least-privilege runtime policy;
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
matching lines, and `apply_edit` carries a full proposed file - though that
content is what the model just wrote. The compiler's
veto verdict comes back as a tool result and can quote diagnostics with source
spans.

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

### How a turn runs

1. You state a goal in plain English.
2. The agent gathers facts with read-only tools before proposing anything.
3. It authors a complete file and submits one `apply_edit` proposal.
4. Before any write, the host compiler veto counts violations the draft introduces relative to the
   file's current contents. A draft that adds none passes; one that adds any is
   rejected and the agent retries.
5. On a pass you see a proof card and approve or reject. `--yes` approves every
   verified edit; `--no-edit` blocks writes entirely.
6. The host writes the file. The agent never writes to disk itself.

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
export. A successful summary is stored as a checksummed v3 compaction
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
